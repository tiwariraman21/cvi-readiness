# Cvi.Rules.ps1 - the deterministic rule layer.
# Every check returns a result object, whether it passes or fails, so the report can
# show what was verified and not only what broke.

$script:EvidenceCap = 60

function New-CviCheck {
    param(
        [string]$Id,
        [string]$Title,
        [string]$Category,
        [string]$Severity,
        [string]$Why,
        [string]$Fix,
        [string]$ImgPath,
        [object[]]$Evidence,
        [string]$PassSummary,
        [string]$FailSummary,
        [string]$ActionId,
        [string]$ActionLabel,
        [string]$ActionKind,
        [switch]$NotApplicable,
        [string]$NotApplicableReason
    )
    $ev = @($Evidence | Where-Object { $_ })
    $status = 'PASS'
    $summary = $PassSummary
    if ($NotApplicable) {
        $status = 'NA'
        $summary = $NotApplicableReason
    } elseif ($ev.Count -gt 0) {
        $status = 'FAIL'
        $summary = $FailSummary -replace '\{n\}', $ev.Count
    }
    [pscustomobject]@{
        Id           = $Id
        Title        = $Title
        Category     = $Category
        Severity     = $Severity
        Layer        = 'RULE'
        Status       = $status
        Summary      = $summary
        Why          = $Why
        Fix          = $Fix
        ImgPath      = $ImgPath
        Count        = $ev.Count
        Evidence     = @($ev | Select-Object -First $script:EvidenceCap)
        Truncated    = ($ev.Count -gt $script:EvidenceCap)
        ActionId     = $ActionId
        ActionLabel  = $ActionLabel
        ActionKind   = $ActionKind
        Confidence   = $null
        Rationale    = $null
        # Filled in by the decision overlay when somebody records the check as taken on.
        RecordedBy   = $null
        RecordedAt   = $null
    }
}

function New-CviEvidence {
    # Findings name the business object - Customer, Vendor, Contact person - because that is
    # what the people reading the report work with. The underlying table is carried alongside
    # so the technical reader keeps it.
    param([string]$Object, [string]$Key, [string]$Field, [string]$Value, [string]$Detail, [string]$Proposal, [string]$Table)
    if ($Table -eq '') {
        switch ($Object) {
            'Customer'       { $Table = 'KNA1' }
            'Vendor'         { $Table = 'LFA1' }
            'Contact person' { $Table = 'KNVK' }
            default          { $Table = $Object }
        }
    }
    [pscustomobject]@{
        Object   = $Object
        Table    = $Table
        Key      = $Key
        Field    = $Field
        Value    = $Value
        Detail   = $Detail
        Proposal = $Proposal
        # What this object could become, and what somebody chose. Both are filled in by the
        # decision overlay after the rules have run.
        Options  = @()
        Choice   = ''
    }
}

function Save-CviNoteStatus {
    # Records against data\config\CVI_NOTE_STATUS.csv that somebody has confirmed a note is
    # implemented. Nothing here reaches SNOTE or any SAP system: implementing a note is done
    # in the system and this only stops the report asking for it again. The catalog under
    # data\notes stays as seeded, so a confirmation can always be told apart from an
    # extracted status and can always be reset.
    param([string]$Root, [object[]]$Notes)

    $path = Join-Path $Root 'data\config\CVI_NOTE_STATUS.csv'
    $existing = @{}
    if (Test-Path -LiteralPath $path) {
        foreach ($row in @(Import-Csv -LiteralPath $path)) {
            $id = Get-CviText $row.NOTE
            if ($id -ne '') { $existing[$id] = $row }
        }
    }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    foreach ($n in $Notes) {
        $id = (Get-CviText $n.note) -replace '[^0-9]', ''
        if ($id -eq '') { throw 'A note number is required.' }
        $status = (Get-CviText $n.status).ToUpperInvariant()
        if ($status -eq '') { $status = 'IMPLEMENTED' }
        if ($status -ne 'IMPLEMENTED' -and $status -ne 'NOT_IMPLEMENTED') {
            throw "Unknown status '$status' for note $id - use IMPLEMENTED or NOT_IMPLEMENTED."
        }
        # A note being put back on the list is a removal, not a row saying 'not implemented':
        # the catalog's own status then applies again.
        if ($status -eq 'NOT_IMPLEMENTED') {
            $null = $existing.Remove($id)
            continue
        }
        $by = Get-CviText $n.by
        if ($by -eq '') { $by = Get-CviText $env:USERNAME }
        if ($by -eq '') { $by = 'unknown' }
        $existing[$id] = [pscustomobject]@{
            NOTE         = $id
            STATUS       = $status
            CONFIRMED_BY = $by
            CONFIRMED_AT = $stamp
        }
    }

    $rows = @($existing.Values | Sort-Object NOTE)
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    } else {
        'NOTE,STATUS,CONFIRMED_BY,CONFIRMED_AT' | Out-File -LiteralPath $path -Encoding utf8
    }
    return $rows.Count
}

function Clear-CviNoteStatus {
    param([string]$Root)
    $path = Join-Path $Root 'data\config\CVI_NOTE_STATUS.csv'
    'NOTE,STATUS,CONFIRMED_BY,CONFIRMED_AT' | Out-File -LiteralPath $path -Encoding utf8
    return 0
}

function Get-CviReleaseCode {
    # Turns a release string into one comparable number - 'S/4HANA 2025 FPS01' -> 2025,
    # 'S/4HANA 1709' -> 1709 - so a note's release window can be compared against the
    # target release of the conversion. The feature pack level is deliberately ignored:
    # the catalog works at release granularity. Returns 0 when there is no S/4HANA
    # release in the string at all ('ECC 6.0 EHP7 SP12', an empty cell), and the caller
    # then leaves the note in scope - a note shown that did not need to be costs a
    # Launchpad lookup, a note silently hidden costs a missed correction.
    param([string]$Release)
    $m = [regex]::Match((Get-CviText $Release), '\b(1[5-9]\d\d|2[0-9]\d\d)\b')
    if (-not $m.Success) { return 0 }
    return [int]$m.Groups[1].Value
}

function Get-CviReleaseWindowText {
    param([int]$From, [int]$To)
    if ($From -gt 0 -and $To -gt 0) { return "target release $From to $To" }
    if ($From -gt 0) { return "target release $From and later" }
    if ($To -gt 0) { return "target release up to $To" }
    return 'every target release'
}

function Get-CviRange {
    param($Data, [string]$Object, [string]$RangeNo)
    foreach ($r in $Data.NumberRanges) {
        if ((Get-CviText $r.OBJECT) -eq $Object -and (Get-CviText $r.RANGE_NO) -eq $RangeNo) { return $r }
    }
    return $null
}

function Test-CviInRange {
    param([string]$Number, [string]$From, [string]$To)
    if ($Number -eq '' -or $From -eq '' -or $To -eq '') { return $true }
    $n = $Number.PadLeft(10, '0')
    $f = $From.PadLeft(10, '0')
    $t = $To.PadLeft(10, '0')
    return (([string]::CompareOrdinal($n, $f) -ge 0) -and ([string]::CompareOrdinal($n, $t) -le 0))
}

function Test-CviPattern {
    param([string]$Value, [string]$Pattern)
    if ($Pattern -eq '') { return $true }
    return ($Value -cmatch $Pattern)
}

function Invoke-CviRules {
    param($Data)

    $checks = New-Object System.Collections.ArrayList
    $set = $Data.Settings
    $strategy = ''
    if ($set.ContainsKey('NUMBER_STRATEGY')) { $strategy = $set['NUMBER_STRATEGY'] }

    # ---------------------------------------------------------------- configuration

    # CFG-01 / CFG-02 - account groups in use without a BP grouping assignment.
    $custUsed = @{}
    foreach ($r in $Data.Records) { if ($r.Object -eq 'CUSTOMER') { $custUsed[$r.AccountGroup] = $true } }
    $ev = @()
    foreach ($g in $Data.CustAccountGrp) {
        $k = Get-CviText $g.KTOKD
        if (-not $Data.CustGroupingMap.ContainsKey($k) -or $Data.CustGroupingMap[$k] -eq '') {
            $inUse = 0
            foreach ($r in $Data.Records) { if ($r.Object -eq 'CUSTOMER' -and $r.AccountGroup -eq $k) { $inUse++ } }
            $ev += New-CviEvidence 'T077D' $k 'GROUPING' '' "$($g.TXT30) - $inUse customer(s) carry this account group" 'Assign a BP grouping in CVI customising'
        }
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-01' -Title 'Every customer account group has a BP grouping' -Category 'Configuration' -Severity 'BLOCKER' `
        -Why 'The synchronisation determines the BP grouping from the account group. An unmapped account group aborts the conversion for every record that uses it.' `
        -Fix 'Maintain the account group to BP grouping assignment for the listed account groups before the mass synchronisation run.' `
        -ImgPath 'SPRO > Cross-Application Components > Master Data Synchronization > Customer/Vendor Integration > Business Partner Settings > Settings for Customer Integration > Field Assignment for Customer Integration > Assign Keys > Define Number Assignment for Direction Customer to BP' `
        -Evidence $ev -PassSummary 'All customer account groups are assigned to a BP grouping.' -FailSummary '{n} customer account group(s) have no BP grouping assignment.' `
        -ActionId 'CFG-01' -ActionLabel 'Generate mapping proposal' -ActionKind 'config'))

    $ev = @()
    foreach ($g in $Data.VendAccountGrp) {
        $k = Get-CviText $g.KTOKK
        if (-not $Data.VendGroupingMap.ContainsKey($k) -or $Data.VendGroupingMap[$k] -eq '') {
            $inUse = 0
            foreach ($r in $Data.Records) { if ($r.Object -eq 'VENDOR' -and $r.AccountGroup -eq $k) { $inUse++ } }
            $ev += New-CviEvidence 'T077K' $k 'GROUPING' '' "$($g.TXT30) - $inUse vendor(s) carry this account group" 'Assign a BP grouping in CVI customising'
        }
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-02' -Title 'Every vendor account group has a BP grouping' -Category 'Configuration' -Severity 'BLOCKER' `
        -Why 'Same mechanism as the customer side - an unmapped vendor account group stops the vendor synchronisation.' `
        -Fix 'Maintain the vendor account group to BP grouping assignment for the listed account groups.' `
        -ImgPath 'SPRO > Cross-Application Components > Master Data Synchronization > Customer/Vendor Integration > Business Partner Settings > Settings for Vendor Integration > Field Assignment for Vendor Integration > Assign Keys > Define Number Assignment for Direction Vendor to BP' `
        -Evidence $ev -PassSummary 'All vendor account groups are assigned to a BP grouping.' -FailSummary '{n} vendor account group(s) have no BP grouping assignment.' `
        -ActionId 'CFG-02' -ActionLabel 'Generate mapping proposal' -ActionKind 'config'))

    # CFG-03 - mapping points at a grouping that does not exist.
    $ev = @()
    foreach ($m in $Data.CustToBp) {
        $grp = Get-CviText $m.GROUPING
        if ($grp -ne '' -and -not $Data.GroupingByKey.ContainsKey($grp)) {
            $ev += New-CviEvidence 'CVI_CUST_TO_BP1' (Get-CviText $m.KTOKD) 'GROUPING' $grp 'BP grouping does not exist in TB001' 'Create the grouping or correct the assignment'
        }
    }
    foreach ($m in $Data.VendToBp) {
        $grp = Get-CviText $m.GROUPING
        if ($grp -ne '' -and -not $Data.GroupingByKey.ContainsKey($grp)) {
            $ev += New-CviEvidence 'CVI_VEND_TO_BP1' (Get-CviText $m.KTOKK) 'GROUPING' $grp 'BP grouping does not exist in TB001' 'Create the grouping or correct the assignment'
        }
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-03' -Title 'Assigned BP groupings exist' -Category 'Configuration' -Severity 'BLOCKER' `
        -Why 'A mapping that points at a grouping which was never created in TB001 fails at runtime with a grouping-not-found error.' `
        -Fix 'Create the missing BP grouping with its number range, or repoint the account group at an existing grouping.' `
        -ImgPath 'SPRO > Cross-Application Components > SAP Business Partner > Business Partner > Basic Settings > Number Ranges and Groupings > Define Groupings and Assign Number Ranges' `
        -Evidence $ev -PassSummary 'Every assigned BP grouping exists in TB001.' -FailSummary '{n} assignment(s) point at a BP grouping that does not exist.' `
        -ActionId 'CFG-03' -ActionLabel 'Generate grouping worklist' -ActionKind 'config'))

    # CFG-04 - synchronisation direction.
    $direction = ''
    if ($set.ContainsKey('SYNC_DIRECTION')) { $direction = $set['SYNC_DIRECTION'] }
    $ev = @()
    if ($direction -notmatch '^(CUSTOMER_TO_BP|VENDOR_TO_BP|CUST_VEND_TO_BP)$') {
        $ev += New-CviEvidence 'CVI_SETTINGS' 'SYNC_DIRECTION' 'VALUE' $direction 'The conversion needs the legacy record to drive the BP, not the other way round' 'Set the active direction to Customer/Vendor to BP'
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-04' -Title 'Synchronisation direction is customer/vendor to BP' -Category 'Configuration' -Severity 'BLOCKER' `
        -Why 'With the direction set the other way the load cockpit finds nothing to convert - the legacy records are the leading objects during a conversion.' `
        -Fix 'Activate the customer to BP and vendor to BP directions (PPO and synchronisation objects) before starting the load.' `
        -ImgPath 'SPRO > Cross-Application Components > Master Data Synchronization > Synchronization Control > Synchronization Control > Activate Synchronization Options' `
        -Evidence $ev -PassSummary "Active direction is '$direction'." -FailSummary 'The active synchronisation direction is not usable for a conversion.' `
        -ActionId 'CFG-04' -ActionLabel 'Add to config task list' -ActionKind 'config'))

    # CFG-05 - a customer and a vendor that would claim the same BP number.
    $ev = @()
    if ($strategy -eq 'SAME_NUMBER') {
        $byNumber = @{}
        foreach ($r in $Data.Records) {
            $grpRow = $null
            if ($r.Grouping -ne '' -and $Data.GroupingByKey.ContainsKey($r.Grouping)) { $grpRow = $Data.GroupingByKey[$r.Grouping] }
            if (-not $grpRow) { continue }
            if ((Get-CviText $grpRow.EXTERNAL) -ne 'X') { continue }
            if (-not $byNumber.ContainsKey($r.Key)) { $byNumber[$r.Key] = @() }
            $byNumber[$r.Key] += $r
        }
        foreach ($k in ($byNumber.Keys | Sort-Object)) {
            $hits = @($byNumber[$k])
            if ($hits.Count -lt 2) { continue }
            $objects = @($hits | ForEach-Object { $_.Object } | Sort-Object -Unique)
            if ($objects.Count -lt 2) { continue }
            $names = ($hits | ForEach-Object { "$($_.Display) $($_.Name)" }) -join ' | '
            $ev += New-CviEvidence 'BP NUMBER' $k 'PARTNER' $k "Both a customer and a vendor would be created as BP $k : $names" 'Decide one BP for both roles, or move one side to a different number range'
        }
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-05' -Title 'No BP number collision between customers and vendors' -Category 'Configuration' -Severity 'BLOCKER' `
        -Why 'Under a same-number strategy the legacy key becomes the BP key. A customer and a vendor carrying the same number collide - the second one fails, or silently lands on the first BP.' `
        -Fix 'For genuine one-entity cases link both roles to a single BP on purpose. For unrelated records move one side onto its own external number range.' `
        -ImgPath 'SPRO > Cross-Application Components > SAP Business Partner > Business Partner > Basic Settings > Number Ranges and Groupings' `
        -Evidence $ev -PassSummary 'No customer and vendor claim the same BP number.' -FailSummary '{n} number(s) are claimed by both a customer and a vendor.' `
        -ActionId 'CFG-05' -ActionLabel 'Export collision list' -ActionKind 'config'))

    # CFG-06 - source numbers outside the external BP range of their grouping.
    $ev = @()
    if ($strategy -eq 'SAME_NUMBER') {
        foreach ($r in $Data.Records) {
            if ($r.Grouping -eq '' -or -not $Data.GroupingByKey.ContainsKey($r.Grouping)) { continue }
            $grpRow = $Data.GroupingByKey[$r.Grouping]
            if ((Get-CviText $grpRow.EXTERNAL) -ne 'X') { continue }
            $rangeNo = Get-CviText $grpRow.NUMBER_RANGE
            $range = Get-CviRange $Data 'BU_PARTNER' $rangeNo
            if (-not $range) { continue }
            $from = Get-CviText $range.FROM_NUMBER
            $to   = Get-CviText $range.TO_NUMBER
            if ($to -match '[A-Z]') { continue }   # catch-all alphanumeric range
            if (-not (Test-CviInRange $r.Key $from $to)) {
                $ev += New-CviEvidence $r.Display $r.Key 'BP number range' $r.Key "Grouping $($r.Grouping) uses BU_PARTNER range $rangeNo ($from-$to)" "Edit range $rangeNo to cover this number, or add an interval that does"
            }
        }
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-06' -Title 'Legacy numbers fit the external BP number range' -Category 'Configuration' -Severity 'HIGH' `
        -Why 'A same-number conversion writes the legacy key as the BP key. If the key sits outside the grouping''s external interval the BP creation is rejected number by number.' `
        -Fix 'Edit the interval of the BP number range to cover the numbers, or add an interval that does.' `
        -ImgPath 'SNRO / SPRO > ... > Define Number Ranges (object BU_PARTNER)' `
        -Evidence $ev -PassSummary 'All legacy numbers fall inside the external BP interval of their grouping.' -FailSummary '{n} record(s) fall outside the BP number range of their grouping.' `
        -ActionId 'CFG-06' -ActionLabel 'Export out-of-range list' -ActionKind 'config'))

    # CFG-07 - one-time account groups must land on a one-time grouping.
    $ev = @()
    foreach ($g in $Data.CustAccountGrp) {
        $k = Get-CviText $g.KTOKD
        if ((Get-CviText $g.XCPDK) -ne 'X') { continue }
        if (-not $Data.CustGroupingMap.ContainsKey($k)) { continue }
        $grp = $Data.CustGroupingMap[$k]
        if ($grp -eq '' -or -not $Data.GroupingByKey.ContainsKey($grp)) { continue }
        if ((Get-CviText $Data.GroupingByKey[$grp].ONE_TIME) -ne 'X') {
            $ev += New-CviEvidence 'T077D' $k 'GROUPING' $grp "One-time account group '$($g.TXT30)' maps to grouping $grp which is not flagged as one-time" 'Map to a one-time BP grouping'
        }
    }
    foreach ($g in $Data.VendAccountGrp) {
        $k = Get-CviText $g.KTOKK
        if ((Get-CviText $g.XCPDK) -ne 'X') { continue }
        if (-not $Data.VendGroupingMap.ContainsKey($k)) { continue }
        $grp = $Data.VendGroupingMap[$k]
        if ($grp -eq '' -or -not $Data.GroupingByKey.ContainsKey($grp)) { continue }
        if ((Get-CviText $Data.GroupingByKey[$grp].ONE_TIME) -ne 'X') {
            $ev += New-CviEvidence 'T077K' $k 'GROUPING' $grp "One-time account group '$($g.TXT30)' maps to grouping $grp which is not flagged as one-time" 'Map to a one-time BP grouping'
        }
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-07' -Title 'One-time accounts map to a one-time BP grouping' -Category 'Configuration' -Severity 'HIGH' `
        -Why 'One-time (CPD) accounts hold no real address of their own. Converting them into normal BPs produces incomplete partners and address errors in PPO.' `
        -Fix 'Point the one-time account groups at a BP grouping that is flagged for one-time partners.' `
        -ImgPath 'SPRO > Cross-Application Components > SAP Business Partner > Business Partner > Basic Settings > Number Ranges and Groupings > Define Groupings and Assign Number Ranges' `
        -Evidence $ev -PassSummary 'One-time account groups map to one-time BP groupings.' -FailSummary '{n} one-time account group(s) map to a normal BP grouping.' `
        -ActionId 'CFG-07' -ActionLabel 'Add to config task list' -ActionKind 'config'))

    # CFG-08 - internal grouping under a same-number strategy.
    $ev = @()
    if ($strategy -eq 'SAME_NUMBER') {
        $used = @{}
        foreach ($r in $Data.Records) { if ($r.Grouping -ne '') { $used[$r.Grouping] = $true } }
        foreach ($grp in ($used.Keys | Sort-Object)) {
            if (-not $Data.GroupingByKey.ContainsKey($grp)) { continue }
            if ((Get-CviText $Data.GroupingByKey[$grp].EXTERNAL) -ne 'X') {
                $ev += New-CviEvidence 'TB001' $grp 'EXTERNAL' '' 'Grouping uses internal numbering while the project decided to keep legacy numbers' 'Flag the grouping for external number assignment'
            }
        }
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-08' -Title 'Groupings use external numbering for a same-number conversion' -Category 'Configuration' -Severity 'HIGH' `
        -Why 'An internally numbered grouping issues fresh BP numbers, so the legacy key is lost even though the project planned to keep it.' `
        -Fix 'Set external number assignment on the groupings used by the conversion, or change the documented number strategy.' `
        -ImgPath 'SPRO > ... > Define Groupings and Assign Number Ranges' `
        -Evidence $ev -PassSummary 'All groupings in scope are set to external number assignment.' -FailSummary '{n} grouping(s) would issue new BP numbers instead of keeping the legacy key.' `
        -ActionId 'CFG-08' -ActionLabel 'Add to config task list' -ActionKind 'config'))

    # CFG-09 - standard address usage.
    $ev = @()
    $stdAddr = ''
    if ($set.ContainsKey('STANDARD_ADDRESS_USAGE')) { $stdAddr = $set['STANDARD_ADDRESS_USAGE'] }
    if ($stdAddr -ne 'X') {
        $ev += New-CviEvidence 'CVI_SETTINGS' 'STANDARD_ADDRESS_USAGE' 'VALUE' $stdAddr 'Address usage for the BP standard address is not maintained' 'Maintain the standard address usage before the load'
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-09' -Title 'Standard address usage is maintained' -Category 'Configuration' -Severity 'MEDIUM' `
        -Why 'Without the address usage the synchronisation creates BPs whose address is not marked as the standard one, which breaks output determination and address-dependent pricing later.' `
        -Fix 'Maintain the address usage (XXDEFAULT) for the BP address types used by the conversion.' `
        -ImgPath 'SPRO > Cross-Application Components > SAP Business Partner > Business Partner > Basic Settings > Address Determination' `
        -Evidence $ev -PassSummary 'Standard address usage is maintained.' -FailSummary 'Standard address usage is not maintained.' `
        -ActionId 'CFG-09' -ActionLabel 'Add to config task list' -ActionKind 'config'))

    # CFG-10 - tax number transfer.
    $ev = @()
    $taxSetting = ''
    if ($set.ContainsKey('TAX_NUMBER_TRANSFER')) { $taxSetting = $set['TAX_NUMBER_TRANSFER'] }
    $withTax = @($Data.Records | Where-Object { $_.TaxNumber -ne '' -or $_.VatNumber -ne '' })
    if ($taxSetting -ne 'X' -and $withTax.Count -gt 0) {
        $ev += New-CviEvidence 'CVI_SETTINGS' 'TAX_NUMBER_TRANSFER' 'VALUE' $taxSetting "$($withTax.Count) record(s) carry a tax or VAT number that would not be transferred" 'Map the tax number categories for the BP'
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-10' -Title 'Tax number categories are mapped' -Category 'Configuration' -Severity 'HIGH' `
        -Why 'Tax numbers held in KNA1/LFA1 only reach the BP if the tax number categories are mapped. Missing tax numbers surface much later, in invoicing and statutory reporting.' `
        -Fix 'Maintain the tax number categories and their assignment before the mass synchronisation.' `
        -ImgPath 'SPRO > Cross-Application Components > SAP Business Partner > Business Partner > Basic Settings > Tax Numbers > Define Tax Number Categories' `
        -Evidence $ev -PassSummary 'Tax number transfer is configured.' -FailSummary 'Tax numbers exist in the master data but the transfer is not configured.' `
        -ActionId 'CFG-10' -ActionLabel 'Add to config task list' -ActionKind 'config'))

    # CFG-11 - duplicate check during the mass run.
    $ev = @()
    $dup = ''
    if ($set.ContainsKey('DUPLICATE_CHECK')) { $dup = $set['DUPLICATE_CHECK'] }
    if ($dup -eq 'X') {
        $ev += New-CviEvidence 'CVI_SETTINGS' 'DUPLICATE_CHECK' 'VALUE' 'X' "The BP duplicate check runs for every one of the $($Data.Records.Count) records in scope" 'Deactivate for the mass run and re-activate afterwards'
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-11' -Title 'BP duplicate check is off for the mass run' -Category 'Configuration' -Severity 'MEDIUM' `
        -Why 'The duplicate check fires per record and turns a load that should take hours into one that takes days, without adding value during a conversion.' `
        -Fix 'Deactivate the duplicate check for the conversion run and switch it back on before go-live.' `
        -ImgPath 'SPRO > Cross-Application Components > SAP Business Partner > Business Partner > Basic Settings > Duplicate Check' `
        -Evidence $ev -PassSummary 'The duplicate check is not active for the mass run.' -FailSummary 'The BP duplicate check is active and will slow the mass synchronisation.' `
        -ActionId 'CFG-11' -ActionLabel 'Add to config task list' -ActionKind 'config'))

    # CFG-12 - post-processing office.
    $ev = @()
    foreach ($proc in @('CVI_01','CVI_02','CVI_03')) {
        $key = "PPO_ACTIVE_$proc"
        $val = ''
        if ($set.ContainsKey($key)) { $val = $set[$key] }
        if ($val -ne 'X') {
            $ev += New-CviEvidence 'CVI_SETTINGS' $key 'VALUE' $val "Post-processing is not active for process $proc - errors in that process will not be recorded" 'Activate PPO for the process'
        }
    }
    $contactSync = ''
    if ($set.ContainsKey('CONTACT_PERSON_SYNC')) { $contactSync = $set['CONTACT_PERSON_SYNC'] }
    if ($contactSync -ne 'X') {
        $ev = @($ev | Where-Object { $_.Key -ne 'PPO_ACTIVE_CVI_03' })
    }
    $null = $checks.Add((New-CviCheck -Id 'CFG-12' -Title 'Post-processing office is active for the CVI processes in scope' -Category 'Configuration' -Severity 'MEDIUM' `
        -Why 'PPO is where failed records land. Without it a mass run reports a count of failures with no worklist to correct them from.' `
        -Fix 'Activate post-processing for each CVI process that is in scope, and give the data team access to transaction MDS_PPO2.' `
        -ImgPath 'SPRO > Cross-Application Components > Master Data Synchronization > Synchronization Control > Synchronization Control > Activate PPO Requests for Platform Objects in the Dialog' `
        -Evidence $ev -PassSummary 'PPO is active for every CVI process in scope.' -FailSummary 'PPO is inactive for {n} CVI process(es) in scope.' `
        -ActionId 'CFG-12' -ActionLabel 'Add to config task list' -ActionKind 'config'))

    # ---------------------------------------------------------------- master data

    $addrMissing = @()
    $noCountry   = @()
    $noRegion    = @()
    $badPostal   = @()
    $noName      = @()
    $noSearch    = @()
    $badTitle    = @()
    $noLang      = @()
    $badTax      = @()
    $deleted     = @()

    foreach ($r in $Data.Records) {
        if ($r.Name -eq '') {
            $noName += New-CviEvidence $r.Display $r.Key 'NAME1' '' "Account group $($r.AccountGroup)" 'Maintain the name before the conversion'
        }
        if ($r.SearchTerm -eq '' -and -not $r.OneTime) {
            $noSearch += New-CviEvidence $r.Display $r.Key 'SORTL' '' "$($r.Name)" 'Derive the search term from the name'
        }
        if ($r.Language -eq '') {
            $noLang += New-CviEvidence $r.Display $r.Key 'SPRAS' '' "$($r.Name)" 'Default to the country language'
        }
        if ($r.Title -ne '' -and ($Data.TitleTexts -notcontains $r.Title)) {
            $badTitle += New-CviEvidence $r.Display $r.Key 'ANRED' $r.Title "$($r.Name) - no BP title in TSAD3 matches this form of address" 'Map the form of address to a BP title key'
        }
        if ($r.Deleted) {
            $deleted += New-CviEvidence $r.Display $r.Key 'LOEVM' 'X' "$($r.Name)" 'Confirm whether the record should be converted or excluded'
        }

        $addr = $null
        if ($r.AddressNo -ne '' -and $Data.AddressByNumber.ContainsKey($r.AddressNo)) { $addr = $Data.AddressByNumber[$r.AddressNo] }
        if (-not $addr) {
            $addrMissing += New-CviEvidence $r.Display $r.Key 'ADRNR' $r.AddressNo "$($r.Name) - no ADRC entry for this address number" 'Repair the address reference or create the address'
        } elseif (-not $r.OneTime) {
            $country = Get-CviText $addr.COUNTRY
            if ($country -eq '') {
                $noCountry += New-CviEvidence $r.Display $r.Key 'COUNTRY' '' "$($r.Name) - address $($r.AddressNo) has no country" 'Maintain the country key'
            } else {
                $cRow = $null
                if ($Data.CountryByKey.ContainsKey($country)) { $cRow = $Data.CountryByKey[$country] }
                if ($cRow) {
                    if ((Get-CviText $cRow.REGION_REQUIRED) -eq 'X' -and (Get-CviText $addr.REGION) -eq '') {
                        $noRegion += New-CviEvidence $r.Display $r.Key 'REGION' '' "$($r.Name) - $($cRow.NAME) requires a region" 'Derive the region from the city or postal code'
                    }
                    $pc = Get-CviText $addr.POST_CODE1
                    if ($pc -ne '' -and -not (Test-CviPattern $pc (Get-CviText $cRow.POSTCODE_REGEX))) {
                        $badPostal += New-CviEvidence $r.Display $r.Key 'POST_CODE1' $pc "$($r.Name) - not a valid $($cRow.NAME) postal code" 'Correct the postal code'
                    }
                }
            }
        }

        if ($r.TaxNumber -ne '' -and $r.Country -ne '' -and $Data.CountryByKey.ContainsKey($r.Country)) {
            $cRow = $Data.CountryByKey[$r.Country]
            if (-not (Test-CviPattern $r.TaxNumber (Get-CviText $cRow.TAX_REGEX))) {
                $badTax += New-CviEvidence $r.Display $r.Key 'STCD1' $r.TaxNumber "$($r.Name) - not a valid $($cRow.TAX_NAME) for $($cRow.NAME)" 'Correct the tax number'
            }
        }
    }

    $null = $checks.Add((New-CviCheck -Id 'MD-01' -Title 'Every record has a resolvable address' -Category 'Master data' -Severity 'BLOCKER' `
        -Why 'The BP is created together with its address. A dangling address number stops the record and fills PPO with address errors.' `
        -Fix 'Recreate the missing ADRC entries or repoint the records at a valid address.' -ImgPath 'Transaction XD02 / MK02 - address tab' `
        -Evidence $addrMissing -PassSummary 'All address references resolve.' -FailSummary '{n} record(s) point at an address that does not exist.' `
        -ActionId 'MD-01' -ActionLabel 'Export correction worklist' -ActionKind 'masterdata'))

    $null = $checks.Add((New-CviCheck -Id 'MD-02' -Title 'Address country is filled' -Category 'Master data' -Severity 'BLOCKER' `
        -Why 'The country key is mandatory on the BP address. Records without it are rejected outright.' `
        -Fix 'Maintain the country key on the listed addresses.' -ImgPath 'Transaction XD02 / MK02 - address tab' `
        -Evidence $noCountry -PassSummary 'Every address carries a country key.' -FailSummary '{n} address(es) have no country key.' `
        -ActionId 'MD-02' -ActionLabel 'Export correction worklist' -ActionKind 'masterdata'))

    $null = $checks.Add((New-CviCheck -Id 'MD-03' -Title 'Region is filled where the country requires it' -Category 'Master data' -Severity 'HIGH' `
        -Why 'For countries with a mandatory region the BP address check rejects the record. This is the single largest source of PPO entries in most CVI runs.' `
        -Fix 'Derive the region from the city or postal code and update the addresses in a mass run before the conversion.' -ImgPath 'Transaction XD02 / MK02 - address tab' `
        -Evidence $noRegion -PassSummary 'Region is filled wherever it is required.' -FailSummary '{n} address(es) are missing a mandatory region.' `
        -ActionId 'MD-03' -ActionLabel 'Export correction worklist' -ActionKind 'masterdata'))

    $null = $checks.Add((New-CviCheck -Id 'MD-04' -Title 'Postal codes match the country format' -Category 'Master data' -Severity 'MEDIUM' `
        -Why 'S/4HANA validates the postal code against the country. Values that ECC tolerated are rejected on the BP.' `
        -Fix 'Correct the postal codes, or relax the country check if the data is genuinely correct.' -ImgPath 'Transaction XD02 / MK02 - address tab' `
        -Evidence $badPostal -PassSummary 'All postal codes match their country format.' -FailSummary '{n} postal code(s) do not match the country format.' `
        -ActionId 'MD-04' -ActionLabel 'Export correction worklist' -ActionKind 'masterdata'))

    $null = $checks.Add((New-CviCheck -Id 'MD-05' -Title 'Name is filled' -Category 'Master data' -Severity 'BLOCKER' `
        -Why 'A BP cannot be created without a name. These records fail immediately.' `
        -Fix 'Maintain the name, or exclude the record from the conversion scope if it is dead data.' -ImgPath 'Transaction XD02 / MK02' `
        -Evidence $noName -PassSummary 'Every record has a name.' -FailSummary '{n} record(s) have no name.' `
        -ActionId 'MD-05' -ActionLabel 'Export correction worklist' -ActionKind 'masterdata'))

    $null = $checks.Add((New-CviCheck -Id 'MD-06' -Title 'Search term is filled' -Category 'Master data' -Severity 'MEDIUM' `
        -Why 'The search term is a required BP field. Records without it stop in PPO even though nothing is really wrong with them.' `
        -Fix 'Fill the search term - deriving it from the first word of the name is normally accepted.' -ImgPath 'Transaction XD02 / MK02' `
        -Evidence $noSearch -PassSummary 'Every record has a search term.' -FailSummary '{n} record(s) have no search term.' `
        -ActionId 'MD-06' -ActionLabel 'Export correction worklist' -ActionKind 'masterdata'))

    $null = $checks.Add((New-CviCheck -Id 'MD-07' -Title 'Form of address maps to a BP title' -Category 'Master data' -Severity 'MEDIUM' `
        -Why 'The BP title is a key, not free text. A form of address with no matching title key is dropped or rejected.' `
        -Fix 'Extend the title table or map the legacy forms of address onto existing title keys.' -ImgPath 'SPRO > ... > SAP Business Partner > Basic Settings > Business Partner Titles' `
        -Evidence $badTitle -PassSummary 'Every form of address maps to a BP title.' -FailSummary '{n} record(s) carry a form of address with no BP title.' `
        -ActionId 'MD-07' -ActionLabel 'Export correction worklist' -ActionKind 'masterdata'))

    $null = $checks.Add((New-CviCheck -Id 'MD-08' -Title 'Language key is filled' -Category 'Master data' -Severity 'MEDIUM' `
        -Why 'The language key drives correspondence and is mandatory on the BP.' `
        -Fix 'Default the language from the country of the address.' -ImgPath 'Transaction XD02 / MK02' `
        -Evidence $noLang -PassSummary 'Every record has a language key.' -FailSummary '{n} record(s) have no language key.' `
        -ActionId 'MD-08' -ActionLabel 'Export correction worklist' -ActionKind 'masterdata'))

    $null = $checks.Add((New-CviCheck -Id 'MD-09' -Title 'Tax numbers match the country format' -Category 'Master data' -Severity 'HIGH' `
        -Why 'The BP validates tax numbers per category and country. A malformed number blocks the record and, if forced through, breaks statutory reporting.' `
        -Fix 'Correct the tax numbers against the country format before the load.' -ImgPath 'Transaction XD02 / MK02 - control tab' `
        -Evidence $badTax -PassSummary 'All tax numbers match their country format.' -FailSummary '{n} tax number(s) do not match the country format.' `
        -ActionId 'MD-09' -ActionLabel 'Export correction worklist' -ActionKind 'masterdata'))

    $null = $checks.Add((New-CviCheck -Id 'MD-10' -Title 'Records flagged for deletion are out of scope' -Category 'Master data' -Severity 'LOW' `
        -Why 'Deletion-flagged records are still converted unless they are excluded, which carries dead master data into the new system.' `
        -Fix 'Confirm the exclusion list with the business and archive rather than convert.' -ImgPath 'Transaction XD05 / MK05' `
        -Evidence $deleted -PassSummary 'No deletion-flagged records are in scope.' -FailSummary '{n} deletion-flagged record(s) are still in scope.' `
        -ActionId 'MD-10' -ActionLabel 'Export exclusion list' -ActionKind 'masterdata'))

    # MD-11 - contact persons.
    $ev = @()
    foreach ($c in $Data.Contacts) {
        $parnr = Get-CviText $c.PARNR
        $last  = Get-CviText $c.NAME1
        $func  = Get-CviText $c.PAFKT
        $adr   = Get-CviText $c.ADRNR
        if ($last -eq '') {
            $ev += New-CviEvidence 'Contact person' $parnr 'NAME1' '' "Contact of customer $($c.KUNNR) has no last name" 'Maintain the last name'
        }
        if ($func -eq '') {
            $ev += New-CviEvidence 'Contact person' $parnr 'PAFKT' '' "Contact of customer $($c.KUNNR) has no contact person function" 'Maintain the function so the BP relationship can be typed'
        }
        if ($adr -ne '' -and -not $Data.AddressByNumber.ContainsKey($adr)) {
            $ev += New-CviEvidence 'Contact person' $parnr 'ADRNR' $adr "Contact of customer $($c.KUNNR) points at a missing address" 'Repair the address reference'
        }
    }
    $null = $checks.Add((New-CviCheck -Id 'MD-11' -Title 'Contact persons are complete' -Category 'Master data' -Severity 'MEDIUM' `
        -Why 'Contact persons become person BPs plus a relationship. Missing last name, function or address stops the relationship from being built.' `
        -Fix 'Complete the contact person records, or descope contact person synchronisation.' -ImgPath 'Transaction VAP2 / XD02 - contact persons' `
        -Evidence $ev -PassSummary 'All contact persons are complete.' -FailSummary '{n} contact person defect(s) found.' `
        -ActionId 'MD-11' -ActionLabel 'Export correction worklist' -ActionKind 'masterdata'))

    # MD-12 - already linked records whose BP has drifted.
    $ev = @()
    foreach ($r in $Data.Records) {
        if ($r.LinkedBp -eq '') { continue }
        if (-not $Data.BpByPartner.ContainsKey($r.LinkedBp)) {
            $ev += New-CviEvidence $r.Display $r.Key 'PARTNER' $r.LinkedBp 'The CVI link points at a business partner that does not exist' 'Repair or delete the link entry'
            continue
        }
        $bp = $Data.BpByPartner[$r.LinkedBp]
        $bpName = Get-CviText $bp.NAME_ORG1
        if ($bpName -eq '') {
            $bpName = (((Get-CviText $bp.NAME_FIRST) + ' ' + (Get-CviText $bp.NAME_LAST))).Trim()
        }
        if ($bpName -ne $r.Name -and $r.Name -ne '') {
            $ev += New-CviEvidence $r.Display $r.Key 'NAME1' $r.Name "Linked BP $($r.LinkedBp) carries '$bpName'" 'Decide which side is leading and re-synchronise'
        }
    }
    $null = $checks.Add((New-CviCheck -Id 'MD-12' -Title 'Already converted records still match their BP' -Category 'Master data' -Severity 'MEDIUM' `
        -Why 'Records converted in an earlier trial run drift apart from their BP. The delta run will either overwrite the corrected side or leave the two permanently inconsistent.' `
        -Fix 'Decide the leading side per record and re-run the synchronisation for the drifted entries.' -ImgPath 'Transaction MDS_LOAD_COCKPIT' `
        -Evidence $ev -PassSummary 'Linked records match their business partner.' -FailSummary '{n} linked record(s) no longer match their business partner.' `
        -ActionId 'MD-12' -ActionLabel 'Export drift list' -ActionKind 'masterdata'))

    # ---------------------------------------------------------------- SAP Notes

    $triggers = @{}
    $triggers['ALWAYS'] = $true
    if (@($Data.Records | Where-Object { $_.OneTime }).Count -gt 0) { $triggers['ONE_TIME_ACCOUNTS'] = $true }
    if ($Data.Contacts.Count -gt 0 -and $contactSync -eq 'X') { $triggers['CONTACT_PERSONS'] = $true }
    if ($set['PPO_ACTIVE_CVI_01'] -eq 'X' -or $set['PPO_ACTIVE_CVI_02'] -eq 'X') { $triggers['PPO_ACTIVE'] = $true }
    if ($strategy -eq 'SAME_NUMBER') { $triggers['SAME_NUMBER_STRATEGY'] = $true }
    if ($dup -eq 'X') { $triggers['DUPLICATE_CHECK_ACTIVE'] = $true }
    if ($withTax.Count -gt 0) { $triggers['TAX_NUMBERS'] = $true }
    if (@($Data.Records | Where-Object { $_.TypeHint -eq 'PERSON' }).Count -gt 0) { $triggers['EMPLOYEE_VENDORS'] = $true }
    $unmappedCount = 0
    foreach ($c in $checks) { if ($c.Id -eq 'CFG-01' -or $c.Id -eq 'CFG-02') { $unmappedCount += $c.Count } }
    if ($unmappedCount -gt 0) { $triggers['UNMAPPED_ACCOUNT_GROUPS'] = $true }

    $targetRelease = Get-CviText $set['TARGET_RELEASE']
    $targetCode = Get-CviReleaseCode $targetRelease

    $ev = @()
    $outOfWindow = @()
    $confirmedHere = @()
    foreach ($n in $Data.SapNotes) {
        $when = Get-CviText $n.APPLIES_WHEN
        if (-not $triggers.ContainsKey($when)) { continue }

        # The catalog carries the status as extracted; a confirmation ticked in the report
        # overlays it. Reading the overlay here rather than writing it back into the catalog
        # keeps the seed and the consultant's decisions separable.
        $noteId = Get-CviText $n.NOTE
        $status = Get-CviText $n.STATUS
        if ($Data.NoteStatusMap.ContainsKey($noteId)) {
            $ovr = $Data.NoteStatusMap[$noteId]
            $ovrStatus = Get-CviText $ovr.STATUS
            if ($ovrStatus -ne '') {
                $status = $ovrStatus
                if ($ovrStatus -eq 'IMPLEMENTED') {
                    $who = Get-CviText $ovr.CONFIRMED_BY
                    $confirmedHere += $(if ($who -ne '') { "$noteId (by $who)" } else { $noteId })
                }
            }
        }
        if ($status -eq 'IMPLEMENTED') { continue }

        $from = Get-CviReleaseCode $n.RELEASE_FROM
        $to   = Get-CviReleaseCode $n.RELEASE_TO
        if ($targetCode -gt 0 -and (($from -gt 0 -and $targetCode -lt $from) -or ($to -gt 0 -and $targetCode -gt $to))) {
            $outOfWindow += (Get-CviText $n.NOTE)
            continue
        }
        $verified = Get-CviText $n.VERIFIED
        $suffix = ''
        if ($verified -ne 'Y') { $suffix = ' (catalog entry not yet verified against SAP ONE Support)' }
        $window = Get-CviReleaseWindowText $from $to
        $ev += New-CviEvidence 'SAP Note' (Get-CviText $n.NOTE) (Get-CviText $n.CRITICALITY) (Get-CviText $n.COMPONENT) ((Get-CviText $n.TOPIC) + $suffix) "Applies because: $when; $window"
    }

    $noteWhy = 'The notes below are the ones the catalog marks as relevant for the situation actually found in this system and for the target release of this conversion, rather than the full list somebody has to read through by hand.'
    if ($targetCode -le 0) {
        $noteWhy += " No S/4HANA release could be read from TARGET_RELEASE ('$targetRelease'), so the release window was not applied and every note matching the situation is listed."
    } elseif ($outOfWindow.Count -gt 0) {
        $noteWhy += " $($outOfWindow.Count) further note(s) match the situation but sit outside the $targetRelease release window and are not listed: $($outOfWindow -join ', '). The window is part of the unverified seed - widen it in the catalog if the Launchpad says the note still applies."
    }
    if ($confirmedHere.Count -gt 0) {
        $noteWhy += " $($confirmedHere.Count) note(s) were marked implemented from this report and are no longer listed: $($confirmedHere -join ', '). That is a record of somebody's confirmation, not evidence from the system - the note is implemented in SNOTE, and 'Reset confirmations' puts these back on the list."
    }

    $null = $checks.Add((New-CviCheck -Id 'NOTE-01' -Title 'Applicable SAP Notes are implemented' -Category 'SAP Notes' -Severity 'HIGH' `
        -Why $noteWhy `
        -Fix "Check each note in SAP ONE Support for $targetRelease and implement or confirm it. The catalog ships as a seed and must be verified - it is not a substitute for the Launchpad." `
        -ImgPath 'Transaction SNOTE / SAP ONE Support Launchpad' `
        -Evidence $ev -PassSummary 'No outstanding notes for the situation found in this system.' -FailSummary '{n} applicable note(s) are not recorded as implemented.' `
        -ActionId 'NOTE-01' -ActionLabel 'Export note worklist' -ActionKind 'note'))

    return @($checks)
}

function Get-CviScore {
    # Share of the weighted checks that passed, rather than a fixed deduction from 100.
    # A flat deduction bottoms out at zero as soon as a handful of blockers appear, which
    # makes two very different systems look identical.
    param([object[]]$Checks)
    $weights = @{ 'BLOCKER' = 14; 'HIGH' = 7; 'MEDIUM' = 3; 'LOW' = 1 }
    $possible = 0; $lost = 0
    foreach ($c in $Checks) {
        if ($c.Status -eq 'NA') { continue }
        $w = 3
        if ($weights.ContainsKey($c.Severity)) { $w = $weights[$c.Severity] }
        $possible += $w
        # Only a check that is still failing loses its weight. A check recorded as DONE earns
        # it, which is the whole point of recording one - and why the header has to say how
        # much of the score is on somebody's word rather than on the extract.
        if ($c.Status -eq 'FAIL') { $lost += $w }
    }
    if ($possible -le 0) { return 100 }
    return [int][math]::Round(100 * (1 - ($lost / [double]$possible)))
}
