# Cvi.Numbers.ps1 - number range analysis and target proposal.
#
# Three passes:
#   1. the ECC source ranges (DEBITOR, KREDITOR) against what the master data actually uses
#   2. the BP ranges as they stand today (BU_PARTNER) against what the mapping would send them
#   3. a proposed target design, one row per grouping, with the interval to create or edit
#
# Under a same-number strategy the legacy key becomes the BP key, so a BP interval has to
# cover the number band of every account group routed into its grouping. That is the whole
# arithmetic - the rest is deciding what to do when it does not.

$script:NumBlock = 100000   # proposals are rounded outward to this block for readable intervals

function Test-CviNumeric {
    param([string]$Value)
    return ($Value -match '^[0-9]+$')
}

function ConvertTo-CviNum {
    param([string]$Value)
    if (-not (Test-CviNumeric $Value)) { return $null }
    return [uint64]$Value
}

function Format-CviNum {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ('{0:D10}' -f [uint64]$Value)
}

function Get-CviRangeStats {
    # Number band actually occupied by a set of records.
    param([object[]]$Records)
    $min = $null; $max = $null; $nonNumeric = 0
    foreach ($r in $Records) {
        $n = ConvertTo-CviNum $r.Key
        if ($null -eq $n) { $nonNumeric++; continue }
        if ($null -eq $min -or $n -lt $min) { $min = $n }
        if ($null -eq $max -or $n -gt $max) { $max = $n }
    }
    return [pscustomobject]@{ Min = $min; Max = $max; NonNumeric = $nonNumeric }
}

function New-CviProposedInterval {
    # Cover the used band and round outward to a whole block, then guarantee headroom so the
    # interval does not have to be touched again the first time the business adds customers.
    # Only used where the account group has no source interval to inherit from.
    param([uint64]$Min, [uint64]$Max)
    $block = [uint64]$script:NumBlock
    $from = [uint64]([math]::Floor($Min / $block) * $block)
    $to = [uint64]((([math]::Floor($Max / $block)) + 1) * $block - 1)
    $headroom = $to - $Max
    if ($headroom -lt ($block / 5)) { $to = $to + $block }
    return [pscustomobject]@{ From = $from; To = $to; Headroom = ($to - $Max) }
}

function Get-CviGroupingSourceIntervals {
    # The number band a grouping has to cover is the union of the source intervals of the
    # account groups routed into it - not a box drawn round the numbers that happen to exist
    # today. Inheriting the client's own intervals keeps the proposal inside a design the
    # business already agreed, and makes a scattered grouping visible as separate intervals
    # rather than one interval swallowing everything in between.
    param($Data, [object[]]$Records)

    $seen = @{}
    foreach ($r in $Records) {
        $numkr = ''; $object = ''
        if ($r.Object -eq 'CUSTOMER' -and $Data.CustGrpByKey.ContainsKey($r.AccountGroup)) {
            $numkr = Get-CviText $Data.CustGrpByKey[$r.AccountGroup].NUMKR; $object = 'DEBITOR'
        } elseif ($r.Object -eq 'VENDOR' -and $Data.VendGrpByKey.ContainsKey($r.AccountGroup)) {
            $numkr = Get-CviText $Data.VendGrpByKey[$r.AccountGroup].NUMKR; $object = 'KREDITOR'
        }
        $key = "$object|$numkr"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = [pscustomobject]@{ Object = $object; RangeNo = $numkr; Groups = @(); Records = @() }
        }
        if ($seen[$key].Groups -notcontains "$($r.Display) $($r.AccountGroup)") {
            $seen[$key].Groups += "$($r.Display) $($r.AccountGroup)"
        }
        $seen[$key].Records += $r
    }

    $intervals = @()
    foreach ($k in $seen.Keys) {
        $entry = $seen[$k]
        $from = $null; $to = $null; $inherited = ''
        if ($entry.Object -ne '' -and $entry.RangeNo -ne '') {
            $nr = Get-CviRange $Data $entry.Object $entry.RangeNo
            if ($nr) {
                $from = ConvertTo-CviNum (Get-CviText $nr.FROM_NUMBER)
                $to   = ConvertTo-CviNum (Get-CviText $nr.TO_NUMBER)
                $inherited = "$($entry.Object) $($entry.RangeNo)"
            }
        }
        if ($null -eq $from -or $null -eq $to) {
            $stats = Get-CviRangeStats $entry.Records
            if ($null -eq $stats.Min) { continue }
            $iv = New-CviProposedInterval -Min $stats.Min -Max $stats.Max
            $from = $iv.From; $to = $iv.To
            $inherited = 'derived from the numbers in use'
        }
        $intervals += [pscustomobject]@{ From = $from; To = $to; Groups = $entry.Groups; Inherited = $inherited }
    }

    # Merge intervals that touch or overlap - a band split across two adjacent source ranges
    # is still one band.
    $sorted = @($intervals | Sort-Object From)
    $merged = @()
    foreach ($iv in $sorted) {
        if ($merged.Count -eq 0) { $merged += $iv; continue }
        $last = $merged[$merged.Count - 1]
        if ($iv.From -le ($last.To + 1)) {
            if ($iv.To -gt $last.To) { $last.To = $iv.To }
            foreach ($g in $iv.Groups) { if ($last.Groups -notcontains $g) { $last.Groups += $g } }
            if ($last.Inherited -notlike "*$($iv.Inherited)*") { $last.Inherited = "$($last.Inherited) + $($iv.Inherited)" }
        } else {
            $merged += $iv
        }
    }
    return @($merged)
}

function Get-CviNumberPlan {
    param($Data)

    $strategy = ''
    if ($Data.Settings.ContainsKey('NUMBER_STRATEGY')) { $strategy = $Data.Settings['NUMBER_STRATEGY'] }
    $sameNumber = ($strategy -eq 'SAME_NUMBER')

    # ---------------------------------------------------------------- 1. ECC source ranges

    $sourceRows = @()
    foreach ($nr in $Data.NumberRanges) {
        $object = Get-CviText $nr.OBJECT
        if ($object -ne 'DEBITOR' -and $object -ne 'KREDITOR') { continue }
        $rangeNo = Get-CviText $nr.RANGE_NO
        $from = ConvertTo-CviNum (Get-CviText $nr.FROM_NUMBER)
        $to   = ConvertTo-CviNum (Get-CviText $nr.TO_NUMBER)
        $external = ((Get-CviText $nr.EXTERNAL) -eq 'X')
        $current = ConvertTo-CviNum (Get-CviText $nr.CURRENT_NUMBER)

        if ($object -eq 'DEBITOR') {
            $groups = @($Data.CustAccountGrp | Where-Object { (Get-CviText $_.NUMKR) -eq $rangeNo } | ForEach-Object { Get-CviText $_.KTOKD })
            $objectName = 'CUSTOMER'
        } else {
            $groups = @($Data.VendAccountGrp | Where-Object { (Get-CviText $_.NUMKR) -eq $rangeNo } | ForEach-Object { Get-CviText $_.KTOKK })
            $objectName = 'VENDOR'
        }
        $records = @($Data.Records | Where-Object { $_.Object -eq $objectName -and $groups -contains $_.AccountGroup })
        $stats = Get-CviRangeStats $records

        $outside = 0
        foreach ($r in $records) {
            $n = ConvertTo-CviNum $r.Key
            if ($null -eq $n -or $null -eq $from -or $null -eq $to) { continue }
            if ($n -lt $from -or $n -gt $to) { $outside++ }
        }

        $remaining = $null
        $usedPct = $null
        if (-not $external -and $null -ne $to -and $null -ne $current) {
            $remaining = $to - $current
            if ($null -ne $from -and $to -gt $from) {
                $usedPct = [math]::Round(100 * (($current - $from) / [double]($to - $from)), 1)
            }
        }

        $status = 'OK'; $note = 'Interval covers every record that uses it.'
        if ($records.Count -eq 0) {
            $status = 'UNUSED'; $note = 'No master record uses this interval - confirm before carrying it into the target.'
        } elseif ($outside -gt 0) {
            $status = 'OUT OF RANGE'; $note = "$outside record(s) sit outside the interval they were supposedly numbered from."
        } elseif ($null -ne $remaining -and $null -ne $to -and $null -ne $from -and $remaining -lt (($to - $from) / 10)) {
            $status = 'NEARLY FULL'; $note = "Only $remaining number(s) left before the interval is exhausted."
        }

        $sourceRows += [pscustomobject]@{
            Object        = $object
            RangeNo       = $rangeNo
            From          = Format-CviNum $from
            To            = Format-CviNum $to
            External      = $external
            Current       = Format-CviNum $current
            AccountGroups = ($groups -join ', ')
            Records       = $records.Count
            MinUsed       = Format-CviNum $stats.Min
            MaxUsed       = Format-CviNum $stats.Max
            Outside       = $outside
            Remaining     = $remaining
            UsedPct       = $usedPct
            Status        = $status
            Note          = $note
        }
    }

    # ---------------------------------------------------------------- 2. BP ranges today

    $bpRows = @()
    $groupingUsage = @{}
    foreach ($r in $Data.Records) {
        if ($r.Grouping -eq '') { continue }
        if (-not $groupingUsage.ContainsKey($r.Grouping)) { $groupingUsage[$r.Grouping] = @() }
        $groupingUsage[$r.Grouping] += $r
    }

    foreach ($g in $Data.BpGrouping) {
        $grouping = Get-CviText $g.GROUPING
        $rangeNo = Get-CviText $g.NUMBER_RANGE
        $external = ((Get-CviText $g.EXTERNAL) -eq 'X')
        $nr = Get-CviRange $Data 'BU_PARTNER' $rangeNo

        $records = @()
        if ($groupingUsage.ContainsKey($grouping)) { $records = @($groupingUsage[$grouping]) }
        $stats = Get-CviRangeStats $records

        $from = $null; $to = $null; $alphaTo = $false
        if ($nr) {
            $from = ConvertTo-CviNum (Get-CviText $nr.FROM_NUMBER)
            $to   = ConvertTo-CviNum (Get-CviText $nr.TO_NUMBER)
            if (-not (Test-CviNumeric (Get-CviText $nr.TO_NUMBER))) { $alphaTo = $true }
        }

        $outside = 0
        if ($sameNumber -and $external -and $null -ne $from -and $null -ne $to) {
            foreach ($r in $records) {
                $n = ConvertTo-CviNum $r.Key
                if ($null -eq $n) { continue }
                if ($n -lt $from -or $n -gt $to) { $outside++ }
            }
        }

        $sourceGroups = @($records | ForEach-Object { "$($_.Display) $($_.AccountGroup)" } | Sort-Object -Unique)

        $status = 'OK'; $note = 'Interval covers the records routed into this grouping.'
        if (-not $nr) {
            $status = 'NO RANGE'; $note = "Grouping references number range '$rangeNo', which is not defined for object BU_PARTNER."
        } elseif ($records.Count -eq 0) {
            $status = 'UNUSED'; $note = 'No record is routed into this grouping by the current mapping.'
        } elseif ($alphaTo) {
            $status = 'CATCH-ALL'; $note = 'Alphanumeric interval - it accepts anything, so it cannot fail, but it also enforces nothing.'
        } elseif ($outside -gt 0) {
            $status = 'TOO NARROW'; $note = "$outside record(s) fall outside this interval and would be rejected one by one."
        } elseif (-not $external -and $sameNumber) {
            $status = 'INTERNAL'; $note = 'Internal numbering issues fresh BP numbers, so the legacy key is not kept.'
        }

        $bpRows += [pscustomobject]@{
            Grouping      = $grouping
            Text          = Get-CviText $g.TEXT
            RangeNo       = $rangeNo
            From          = Format-CviNum $from
            To            = Format-CviNum $to
            RawTo         = $(if ($nr) { Get-CviText $nr.TO_NUMBER } else { '' })
            External      = $external
            OneTime       = ((Get-CviText $g.ONE_TIME) -eq 'X')
            Records       = $records.Count
            MinUsed       = Format-CviNum $stats.Min
            MaxUsed       = Format-CviNum $stats.Max
            Outside       = $outside
            AccountGroups = ($sourceGroups -join ', ')
            Status        = $status
            Note          = $note
        }
    }

    # ---------------------------------------------------------------- 3. proposed target design

    # Numbers claimed by both a customer and a vendor - they cannot both become a BP of that
    # number, so they are called out separately rather than folded into an interval.
    $collisions = @()
    $byNumber = @{}
    foreach ($r in $Data.Records) {
        if (-not $byNumber.ContainsKey($r.Key)) { $byNumber[$r.Key] = @() }
        $byNumber[$r.Key] += $r
    }
    foreach ($k in ($byNumber.Keys | Sort-Object)) {
        $hits = @($byNumber[$k])
        $objects = @($hits | ForEach-Object { $_.Object } | Sort-Object -Unique)
        if ($objects.Count -lt 2) { continue }
        $collisions += [pscustomobject]@{
            Number    = $k
            Groupings = (@($hits | ForEach-Object { $_.Grouping } | Sort-Object -Unique) -join ', ')
            Names     = (@($hits | ForEach-Object { "$($_.Display) $($_.Name)" }) -join ' | ')
        }
    }
    $collisionNumbers = @{}
    foreach ($c in $collisions) { $collisionNumbers[$c.Number] = $true }

    $proposals = @()

    foreach ($row in ($bpRows | Where-Object { $_.Records -gt 0 })) {
        $records = @($groupingUsage[$row.Grouping])
        # @(...) is required: a one-element return is unrolled to a scalar by the pipeline,
        # which silently drops every grouping that needs only a single interval.
        $intervals = @(Get-CviGroupingSourceIntervals -Data $Data -Records $records)
        if ($intervals.Count -eq 0) { continue }

        $curFrom = ConvertTo-CviNum $row.From
        $curTo   = ConvertTo-CviNum $row.To
        $partCount = $intervals.Count

        for ($i = 0; $i -lt $partCount; $i++) {
            $iv = $intervals[$i]
            $inInterval = @($records | Where-Object {
                $n = ConvertTo-CviNum $_.Key
                ($null -ne $n) -and ($n -ge $iv.From) -and ($n -le $iv.To)
            })
            $stats = Get-CviRangeStats $inInterval
            $maxUsed = $iv.To
            if ($null -ne $stats.Max) { $maxUsed = $stats.Max }

            $rangeNo = $row.RangeNo
            $action = 'KEEP'
            $rationale = "Interval $($row.From)-$($row.To) already covers the $($inInterval.Count) record(s) in this band."

            if ($i -gt 0) {
                $action = 'ADD INTERVAL'
                $rangeNo = '(new)'
                $rationale = "Grouping $($row.Grouping) is fed by account groups from separate number bands, so one interval cannot cover it. This band comes from $($iv.Inherited) via $(($iv.Groups) -join ', '). Either add a second interval on a free two-character key, or route those account groups to a grouping of their own."
            } elseif ($row.Status -eq 'NO RANGE') {
                $action = 'CREATE'
                $rationale = "Number range '$($row.RangeNo)' is not defined for BU_PARTNER. Create it covering the band inherited from $($iv.Inherited)."
            } elseif ($row.Status -eq 'INTERNAL') {
                $action = 'SET EXTERNAL'
                $rationale = "Grouping numbers internally while the project decided on $strategy, so the legacy key would be discarded. Set external assignment on the interval inherited from $($iv.Inherited)."
            } elseif ($row.Status -eq 'CATCH-ALL') {
                $action = 'TIGHTEN'
                $rationale = "Interval ends at '$($row.RawTo)' and accepts any value. Tightening it to $($iv.Inherited) turns a silent mis-route into an error at load time."
            } elseif ($null -eq $curFrom -or $null -eq $curTo -or $curFrom -gt $iv.From -or $curTo -lt $iv.To) {
                $action = 'EDIT INTERVAL'
                $rationale = "$($row.Outside) of $($records.Count) record(s) in this grouping fall outside $($row.From)-$($row.To). Change the interval to the band inherited from $($iv.Inherited), which runs $(Format-CviNum $iv.From)-$(Format-CviNum $iv.To)."
            }

            if ($i -gt 0) {
                $rationale += " Re-routing $(($iv.Groups) -join ', ') to its own grouping removes the need for this interval entirely."
            }

            $hasCollision = $false
            foreach ($r in $inInterval) { if ($collisionNumbers.ContainsKey($r.Key)) { $hasCollision = $true } }
            if ($hasCollision) {
                $action = 'RESOLVE COLLISION'
                $rationale += ' Numbers in this band are claimed by both a customer and a vendor - decide one BP carrying both roles, or move one side to its own interval, before the interval is transported.'
            }

            $proposals += [pscustomobject]@{
                Id            = "$($row.Grouping)#$($i + 1)"
                Scope         = 'BU_PARTNER'
                Grouping      = $row.Grouping
                Text          = $row.Text
                Part          = $(if ($partCount -gt 1) { "$($i + 1) of $partCount" } else { '' })
                AccountGroups = (($iv.Groups) -join ', ')
                Records       = $inInterval.Count
                UsedFrom      = Format-CviNum $stats.Min
                UsedTo        = Format-CviNum $stats.Max
                CurrentRange  = $(if ($row.RangeNo -ne '' -and $row.From -ne '') { "$($row.RangeNo): $($row.From)-$($row.To)" } else { $row.RangeNo })
                RangeNo       = $rangeNo
                From          = Format-CviNum $iv.From
                To            = Format-CviNum $iv.To
                External      = $($row.External -or $sameNumber)
                Headroom      = [uint64]($iv.To - $maxUsed)
                Action        = $action
                Rationale     = $rationale
                Editable      = $true
                Edited        = $false
                BaseRangeNo   = $rangeNo
                BaseFrom      = Format-CviNum $iv.From
                BaseTo        = Format-CviNum $iv.To
                Valid         = $true
                ValidationNote = ''
                Confirmed     = $false
                Note          = ''
            }
        }
    }

    # Account groups with no grouping at all still carry records, and those records still need
    # a number band. Propose the grouping and its interval together.
    $unmapped = @()
    foreach ($g in $Data.CustAccountGrp) {
        $k = Get-CviText $g.KTOKD
        if ($Data.CustGroupingMap.ContainsKey($k) -and $Data.CustGroupingMap[$k] -ne '') { continue }
        $unmapped += [pscustomobject]@{ Object = 'CUSTOMER'; Group = $k; Text = (Get-CviText $g.TXT30); Table = 'T077D'; Display = 'Customer' }
    }
    foreach ($g in $Data.VendAccountGrp) {
        $k = Get-CviText $g.KTOKK
        if ($Data.VendGroupingMap.ContainsKey($k) -and $Data.VendGroupingMap[$k] -ne '') { continue }
        $unmapped += [pscustomobject]@{ Object = 'VENDOR'; Group = $k; Text = (Get-CviText $g.TXT30); Table = 'T077K'; Display = 'Vendor' }
    }

    foreach ($u in $unmapped) {
        $records = @($Data.Records | Where-Object { $_.Object -eq $u.Object -and $_.AccountGroup -eq $u.Group })
        if ($records.Count -eq 0) { continue }
        $stats = Get-CviRangeStats $records
        if ($null -eq $stats.Min) { continue }
        $intervals = @(Get-CviGroupingSourceIntervals -Data $Data -Records $records)
        if ($intervals.Count -eq 0) { continue }
        $iv = $intervals[0]

        $newGrouping = $u.Group
        if ($Data.GroupingByKey.ContainsKey($newGrouping)) { $newGrouping = ('Z' + $u.Group.Substring(0, [math]::Min(3, $u.Group.Length))) }

        $proposals += [pscustomobject]@{
            Id            = "$newGrouping#1"
            Scope         = 'BU_PARTNER'
            Grouping      = $newGrouping
            Text          = "$($u.Text) business partner"
            Part          = ''
            AccountGroups = "$($u.Display) $($u.Group)"
            Records       = $records.Count
            UsedFrom      = Format-CviNum $stats.Min
            UsedTo        = Format-CviNum $stats.Max
            CurrentRange  = '(none)'
            RangeNo       = $newGrouping
            From          = Format-CviNum $iv.From
            To            = Format-CviNum $iv.To
            External      = $sameNumber
            Headroom      = [uint64]($iv.To - $stats.Max)
            Action        = 'CREATE GROUPING'
            Rationale     = "Account group $($u.Group) ('$($u.Text)') has $($records.Count) record(s) and no BP grouping at all. Create the grouping and give it the interval it already numbers from ($($iv.Inherited)), so the keys carry over unchanged."
            Editable      = $true
            Edited        = $false
            BaseRangeNo   = $newGrouping
            BaseFrom      = Format-CviNum $iv.From
            BaseTo        = Format-CviNum $iv.To
            Valid         = $true
            ValidationNote = ''
            Confirmed     = $false
            Note          = ''
        }
    }

    # Internal ranges for partners created after go-live, kept clear of every converted band.
    $allStats = Get-CviRangeStats $Data.Records
    $internalRows = @($Data.NumberRanges | Where-Object { (Get-CviText $_.OBJECT) -eq 'BU_PARTNER' -and (Get-CviText $_.EXTERNAL) -ne 'X' })
    foreach ($ir in $internalRows) {
        $from = ConvertTo-CviNum (Get-CviText $ir.FROM_NUMBER)
        $to   = ConvertTo-CviNum (Get-CviText $ir.TO_NUMBER)
        $clash = $false
        if ($null -ne $from -and $null -ne $allStats.Max -and $from -le $allStats.Max) { $clash = $true }
        $proposals += [pscustomobject]@{
            Id            = "INT#$(Get-CviText $ir.RANGE_NO)"
            Scope         = 'BU_PARTNER (new partners)'
            Grouping      = '(internal)'
            Text          = 'Partners created after go-live'
            Part          = ''
            AccountGroups = ''
            Records       = 0
            UsedFrom      = ''
            UsedTo        = ''
            CurrentRange  = "$(Get-CviText $ir.RANGE_NO): $(Format-CviNum $from)-$(Format-CviNum $to)"
            RangeNo       = Get-CviText $ir.RANGE_NO
            From          = Format-CviNum $from
            To            = Format-CviNum $to
            External      = $false
            Headroom      = $(if ($null -ne $to -and $null -ne $from) { [uint64]($to - $from) } else { [uint64]0 })
            Action        = $(if ($clash) { 'MOVE' } else { 'KEEP' })
            Rationale     = $(if ($clash) {
                "Internal interval starts at $(Format-CviNum $from), at or below the highest converted number $(Format-CviNum $allStats.Max). Move it clear of the converted bands so a new partner can never take a number a conversion still needs."
            } else {
                "Internal interval sits clear of every converted band (highest converted number is $(Format-CviNum $allStats.Max)), so new partners cannot collide with converted ones."
            })
            Editable      = $true
            Edited        = $false
            BaseRangeNo   = Get-CviText $ir.RANGE_NO
            BaseFrom      = Format-CviNum $from
            BaseTo        = Format-CviNum $to
            Valid         = $true
            ValidationNote = ''
            Confirmed     = $false
            Note          = ''
        }
    }

    # ---------------------------------------------------------------- edits made in the tool
    #
    # A consultant who knows the client's numbering can overrule any proposed interval. The
    # edit is kept in data\config\CVI_BP_RANGE_OVERRIDES.csv and re-applied on every run, and
    # it is re-checked exactly like a proposed one - an edit that no longer covers its records
    # is flagged rather than trusted.

    $editedCount = 0
    $invalidCount = 0
    foreach ($p in $proposals) {
        $ov = $null
        if ($Data.RangeOverrideMap.ContainsKey($p.Id)) { $ov = $Data.RangeOverrideMap[$p.Id] }
        if ($ov) {
            $ovFrom = Get-CviText $ov.FROM_NUMBER
            $ovTo   = Get-CviText $ov.TO_NUMBER
            $ovRange = Get-CviText $ov.RANGE_NO
            if ($ovRange -ne '') { $p.RangeNo = $ovRange }
            if ($ovFrom -ne '')  { $p.From = $ovFrom.PadLeft(10, '0') }
            if ($ovTo -ne '')    { $p.To = $ovTo.PadLeft(10, '0') }
            $p.External = ((Get-CviText $ov.EXTERNAL) -eq 'X')
            $p.Confirmed = ((Get-CviText $ov.CONFIRMED) -eq 'X')
            $p.Note = Get-CviText $ov.NOTE
            $changed = ($p.RangeNo -ne $p.BaseRangeNo) -or ($p.From -ne $p.BaseFrom) -or ($p.To -ne $p.BaseTo)
            if ($changed) {
                $p.Edited = $true
                $editedCount++
                $noteBit = ''
                if ($p.Note -ne '') { $noteBit = ": $($p.Note)" }
                $p.Rationale = "Edited in the tool$noteBit. The tool proposed $($p.BaseRangeNo): $($p.BaseFrom)-$($p.BaseTo)."
                $p.Action = 'EDITED'
            }
        }

        # Re-check every interval, edited or not.
        $from = ConvertTo-CviNum $p.From
        $to   = ConvertTo-CviNum $p.To
        $usedFrom = ConvertTo-CviNum $p.UsedFrom
        $usedTo   = ConvertTo-CviNum $p.UsedTo
        if ($null -eq $from -or $null -eq $to) {
            $p.Valid = $false
            $p.ValidationNote = 'From and To must both be numbers.'
        } elseif ($from -gt $to) {
            $p.Valid = $false
            $p.ValidationNote = 'From is higher than To.'
        } elseif ($null -ne $usedFrom -and $null -ne $usedTo -and ($from -gt $usedFrom -or $to -lt $usedTo)) {
            $p.Valid = $false
            $p.ValidationNote = "Interval does not cover the numbers in use ($($p.UsedFrom)-$($p.UsedTo)) - those records would be rejected."
        } else {
            $p.Valid = $true
            $p.ValidationNote = ''
            if ($null -ne $usedTo) { $p.Headroom = [uint64]($to - $usedTo) }
            elseif ($null -ne $from) { $p.Headroom = [uint64]($to - $from) }
        }
        if (-not $p.Valid) {
            $invalidCount++
            $p.Headroom = [uint64]0   # headroom is meaningless while the interval misses records
        }
    }

    # Overlap between the proposed external intervals.
    $overlaps = @()
    $external = @($proposals | Where-Object { $_.External -and $_.From -ne '' } | Sort-Object From)
    for ($i = 0; $i -lt $external.Count - 1; $i++) {
        $a = $external[$i]; $b = $external[$i + 1]
        $aTo = ConvertTo-CviNum $a.To; $bFrom = ConvertTo-CviNum $b.From
        if ($null -eq $aTo -or $null -eq $bFrom) { continue }
        if ($bFrom -le $aTo) {
            $overlaps += [pscustomobject]@{
                Left  = "$($a.Grouping) ($($a.From)-$($a.To))"
                Right = "$($b.Grouping) ($($b.From)-$($b.To))"
                Note  = 'Two groupings would accept the same numbers. Either they describe the same partners and should be one grouping, or one interval has to move.'
            }
        }
    }

    $issues = @()
    $issues += @($sourceRows | Where-Object { $_.Status -ne 'OK' }).Count
    $conflictCount = @($bpRows | Where-Object { $_.Status -eq 'TOO NARROW' -or $_.Status -eq 'NO RANGE' -or $_.Status -eq 'INTERNAL' }).Count

    return [pscustomobject]@{
        Strategy        = $strategy
        SameNumber      = $sameNumber
        SourceRanges    = @($sourceRows)
        BpRanges        = @($bpRows)
        Proposals       = @($proposals)
        Collisions      = @($collisions)
        Overlaps        = @($overlaps)
        Counts          = [pscustomobject]@{
            SourceRanges     = $sourceRows.Count
            SourceIssues     = $issues[0]
            BpRanges         = $bpRows.Count
            BpIssues         = $conflictCount
            Proposals        = $proposals.Count
            Changes          = @($proposals | Where-Object { $_.Action -ne 'KEEP' }).Count
            Edited           = $editedCount
            Invalid          = $invalidCount
            Confirmed        = @($proposals | Where-Object { $_.Confirmed }).Count
            Collisions       = $collisions.Count
            Overlaps         = $overlaps.Count
            RecordsCovered   = @($Data.Records | Where-Object { $_.Grouping -ne '' }).Count
            RecordsTotal     = $Data.Records.Count
        }
    }
}

function Save-CviRangeOverrides {
    # Merge the edits coming from the page into data\config\CVI_BP_RANGE_OVERRIDES.csv.
    # Existing edits for rows that were not touched are kept.
    param([string]$Root, [object[]]$Overrides)

    $path = Join-Path $Root 'data\config\CVI_BP_RANGE_OVERRIDES.csv'
    $existing = @{}
    if (Test-Path -LiteralPath $path) {
        foreach ($row in @(Import-Csv -LiteralPath $path)) {
            $id = Get-CviText $row.ID
            if ($id -ne '') { $existing[$id] = $row }
        }
    }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    foreach ($o in $Overrides) {
        $id = Get-CviText $o.id
        if ($id -eq '') { continue }
        $from = (Get-CviText $o.from) -replace '[^0-9]', ''
        $to   = (Get-CviText $o.to)   -replace '[^0-9]', ''
        $existing[$id] = [pscustomobject]@{
            ID          = $id
            GROUPING    = Get-CviText $o.grouping
            RANGE_NO    = Get-CviText $o.rangeNo
            FROM_NUMBER = $(if ($from -ne '') { $from.PadLeft(10, '0') } else { '' })
            TO_NUMBER   = $(if ($to -ne '')   { $to.PadLeft(10, '0') }   else { '' })
            EXTERNAL    = $(if ($o.external) { 'X' } else { '' })
            CONFIRMED   = $(if ($o.confirmed) { 'X' } else { '' })
            NOTE        = Get-CviText $o.note
            UPDATED     = $stamp
        }
    }

    $rows = @($existing.Values | Sort-Object ID)
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    } else {
        'ID,GROUPING,RANGE_NO,FROM_NUMBER,TO_NUMBER,EXTERNAL,CONFIRMED,NOTE,UPDATED' | Out-File -LiteralPath $path -Encoding utf8
    }
    return $rows.Count
}

function Clear-CviRangeOverrides {
    param([string]$Root)
    $path = Join-Path $Root 'data\config\CVI_BP_RANGE_OVERRIDES.csv'
    'ID,GROUPING,RANGE_NO,FROM_NUMBER,TO_NUMBER,EXTERNAL,CONFIRMED,NOTE,UPDATED' | Out-File -LiteralPath $path -Encoding utf8
    return 0
}

function New-CviNumberRangeProposal {
    # Writes the proposal as a table to work from and a page to hand over.
    param($Report, [string]$OutDir)

    if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }
    $plan = $Report.NumberPlan
    $files = @()

    $rows = @()
    foreach ($p in $plan.Proposals) {
        $rows += [pscustomobject]@{
            SCOPE          = $p.Scope
            GROUPING       = $p.Grouping
            PART           = $p.Part
            DESCRIPTION    = $p.Text
            ACCOUNT_GROUPS = $p.AccountGroups
            RECORDS        = $p.Records
            USED_FROM      = $p.UsedFrom
            USED_TO        = $p.UsedTo
            CURRENT_RANGE  = $p.CurrentRange
            PROPOSED_RANGE = $p.RangeNo
            PROPOSED_FROM  = $p.From
            PROPOSED_TO    = $p.To
            EXTERNAL       = $(if ($p.External) { 'X' } else { '' })
            HEADROOM       = $p.Headroom
            ACTION         = $p.Action
            EDITED         = $(if ($p.Edited) { 'X' } else { '' })
            VALID          = $(if ($p.Valid) { 'X' } else { '' })
            VALIDATION     = $p.ValidationNote
            RATIONALE      = $p.Rationale
            OWNER          = ''
            STATUS         = 'OPEN'
        }
    }
    $csvPath = Join-Path $OutDir 'CVI_NUMBER_RANGE_PROPOSAL.csv'
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $files += 'CVI_NUMBER_RANGE_PROPOSAL.csv'

    $srcPath = Join-Path $OutDir 'CVI_SOURCE_NUMBER_RANGES.csv'
    $plan.SourceRanges | Export-Csv -LiteralPath $srcPath -NoTypeInformation -Encoding UTF8
    $files += 'CVI_SOURCE_NUMBER_RANGES.csv'

    $md = @()
    $md += "# Proposed BP number range design - $($Report.SystemId)/$($Report.Client)"
    $md += ''
    $md += "$($Report.SourceRelease) to $($Report.TargetRelease). Strategy: $($plan.Strategy). Generated $($Report.GeneratedAt)."
    $md += ''
    $md += "$($plan.Counts.RecordsCovered) of $($plan.Counts.RecordsTotal) records are routed to a grouping by the current mapping. $($plan.Counts.Changes) of $($plan.Counts.Proposals) intervals need a change."
    $md += ''
    $md += '## Proposed intervals'
    $md += ''
    $md += '| Grouping | Sources | Records | Used band | Current | Proposed | Ext | Action |'
    $md += '|---|---|---|---|---|---|---|---|'
    foreach ($p in $plan.Proposals) {
        $ext = ''
        if ($p.External) { $ext = 'X' }
        $used = ''
        if ($p.UsedFrom -ne '') { $used = "$($p.UsedFrom)-$($p.UsedTo)" }
        $name = $p.Grouping
        if ($p.Part -ne '') { $name = "$($p.Grouping) (interval $($p.Part))" }
        $md += "| $name | $($p.AccountGroups) | $($p.Records) | $used | $($p.CurrentRange) | $($p.RangeNo): $($p.From)-$($p.To) | $ext | **$($p.Action)** |"
    }
    $md += ''
    $md += '## Why each change'
    $md += ''
    foreach ($p in ($plan.Proposals | Where-Object { $_.Action -ne 'KEEP' })) {
        $md += "- **$($p.Grouping) - $($p.Action)** ($($p.RangeNo): $($p.From)-$($p.To)): $($p.Rationale)"
    }
    if ($plan.Collisions.Count -gt 0) {
        $md += ''
        $md += '## Numbers claimed by both a customer and a vendor'
        $md += ''
        $md += 'Each of these becomes one BP number. Decide a single partner with both roles, or move one side to its own interval.'
        $md += ''
        foreach ($c in $plan.Collisions) { $md += "- $($c.Number) - $($c.Names) (grouping $($c.Groupings))" }
    }
    if ($plan.Overlaps.Count -gt 0) {
        $md += ''
        $md += '## Overlapping proposed intervals'
        $md += ''
        foreach ($o in $plan.Overlaps) { $md += "- $($o.Left) overlaps $($o.Right). $($o.Note)" }
    }
    $md += ''
    $md += '## How to apply'
    $md += ''
    $md += '1. `SNRO` object `BU_PARTNER` - create or change each interval above (external where the Ext column is marked).'
    $md += '2. `SPRO` > Cross-Application Components > SAP Business Partner > Business Partner > Basic Settings > Number Ranges and Groupings > Define Groupings and Assign Number Ranges - assign each interval to its grouping.'
    $md += '3. `SPRO` > ... > Customer/Vendor Integration > Define Number Assignment for Direction Customer/Vendor to BP - route each account group into its grouping.'
    $md += '4. Re-run this tool. CFG-05, CFG-06 and CFG-08 are the checks that confirm the design holds.'

    $mdPath = Join-Path $OutDir 'CVI_NUMBER_RANGE_PLAN.md'
    ($md -join [Environment]::NewLine) | Out-File -LiteralPath $mdPath -Encoding utf8
    $files += 'CVI_NUMBER_RANGE_PLAN.md'

    return [pscustomobject]@{
        CheckId = 'NUMBERS'
        Rows    = $rows.Count
        Files   = @($files)
        OutDir  = (Resolve-Path -LiteralPath $OutDir).Path
    }
}
