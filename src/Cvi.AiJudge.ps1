# Cvi.AiJudge.ps1 - the judgment layer.
#
# Rules answer "does this value satisfy the constraint". They cannot answer
# "are these two records the same company", "is this master record really a person",
# or "does this account-group-to-grouping mapping make business sense". Those are the
# questions a consultant currently answers by eye on a sample. This layer proposes the
# candidates deterministically and then judges them - through the Claude API when
# ANTHROPIC_API_KEY is available, otherwise through a local heuristic judge that
# returns the same verdict shape so the report is never blocked on connectivity.

$script:LegalSuffixes = @(
    'LTD','LIMITED','PVT','PRIVATE','PLC','INC','INCORPORATED','LLC','LLP','CORP','CORPORATION',
    'GMBH','MBH','AG','KG','SAS','SARL','SA','BV','NV','PTE','KK','KABUSHIKI','SPA','SRL','OY','AB',
    'CO','COMPANY','GROUP','HOLDINGS','HOLDING','INTERNATIONAL','GLOBAL','THE','AND'
)

$script:PersonTitles = @('Mr.','Ms.','Mrs.','Dr.','Prof.','Herr','Frau','Mr','Ms')

function Get-CviNormalizedName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $n = $Name.ToUpperInvariant()
    $n = $n -replace '[^A-Z0-9 ]', ' '
    $n = $n -replace '\s+', ' '
    return $n.Trim()
}

function Get-CviNameTokens {
    param([string]$Name)
    $norm = Get-CviNormalizedName $Name
    if ($norm -eq '') { return @() }
    $tokens = @()
    foreach ($t in ($norm -split ' ')) {
        if ($t -eq '') { continue }
        if ($script:LegalSuffixes -contains $t) { continue }
        $tokens += $t
    }
    return $tokens
}

function Get-CviNameSimilarity {
    param([string]$A, [string]$B)
    $ta = Get-CviNameTokens $A
    $tb = Get-CviNameTokens $B
    if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return 0.0 }
    $setA = @{}; foreach ($t in $ta) { $setA[$t] = $true }
    $setB = @{}; foreach ($t in $tb) { $setB[$t] = $true }
    $inter = 0
    foreach ($k in $setA.Keys) { if ($setB.ContainsKey($k)) { $inter++ } }
    $union = $setA.Count + $setB.Count - $inter
    if ($union -le 0) { return 0.0 }
    return [math]::Round($inter / [double]$union, 3)
}

function Test-CviLooksLikePerson {
    # A supporting signal only - a two-word name with no legal form and no plural noun.
    # Company names like "Silverpeak Instruments" or "Cobalt Energy Systems" fail it,
    # which is the point: this must never be the sole reason to reclassify a record.
    param([string]$Name, [string]$Title)
    $norm = Get-CviNormalizedName $Name
    if ($norm -eq '') { return $false }
    $raw = @($norm -split ' ' | Where-Object { $_ -ne '' })
    if ($raw.Count -ne 2) { return $false }
    foreach ($t in $raw) {
        if ($script:LegalSuffixes -contains $t) { return $false }
        if ($t.Length -gt 3 -and $t.EndsWith('S')) { return $false }
    }
    return $true
}

function Get-CviAddressKey {
    param($Data, [string]$AddressNo)
    if ($AddressNo -eq '' -or -not $Data.AddressByNumber.ContainsKey($AddressNo)) { return '' }
    $a = $Data.AddressByNumber[$AddressNo]
    $parts = @((Get-CviText $a.STREET), (Get-CviText $a.CITY1), (Get-CviText $a.POST_CODE1), (Get-CviText $a.COUNTRY))
    return (Get-CviNormalizedName ($parts -join ' '))
}

function Get-CviCandidates {
    param($Data)

    $cands = New-Object System.Collections.ArrayList
    $records = @($Data.Records | Where-Object { -not $_.OneTime -and $_.Name -ne '' })

    # Pairs that may be one legal entity or one duplicated entity.
    $byTax = @{}
    foreach ($r in $records) {
        foreach ($t in @($r.TaxNumber, $r.VatNumber)) {
            $tt = ($t -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
            if ($tt -eq '') { continue }
            if (-not $byTax.ContainsKey($tt)) { $byTax[$tt] = @() }
            $byTax[$tt] += $r
        }
    }

    $seenPair = @{}
    function Add-Pair {
        param($A, $B, [string]$Reason, $Bag, $Seen, $Ds)
        $ids = @("$($A.Table):$($A.Key)", "$($B.Table):$($B.Key)") | Sort-Object
        $pk = $ids -join '>'
        if ($Seen.ContainsKey($pk)) { return }
        $Seen[$pk] = $true
        $kind = 'DUPLICATE'
        if ($A.Object -ne $B.Object) { $kind = 'CUSTOMER_VENDOR_PAIR' }
        $null = $Bag.Add([pscustomobject]@{
            Type        = $kind
            PairKey     = $pk
            LeftTable   = $A.Display; LeftKey  = $A.Key;  LeftName  = $A.Name
            RightTable  = $B.Display; RightKey = $B.Key;  RightName = $B.Name
            LeftAddress = (Get-CviAddressKey $Ds $A.AddressNo)
            RightAddress= (Get-CviAddressKey $Ds $B.AddressNo)
            LeftTax     = "$($A.TaxNumber) $($A.VatNumber)".Trim()
            RightTax    = "$($B.TaxNumber) $($B.VatNumber)".Trim()
            LeftGroup   = $A.AccountGroup
            RightGroup  = $B.AccountGroup
            NameSim     = (Get-CviNameSimilarity $A.Name $B.Name)
            Reason      = $Reason
        })
    }

    foreach ($k in $byTax.Keys) {
        $grp = @($byTax[$k])
        if ($grp.Count -lt 2) { continue }
        for ($i = 0; $i -lt $grp.Count; $i++) {
            for ($j = $i + 1; $j -lt $grp.Count; $j++) {
                Add-Pair $grp[$i] $grp[$j] 'identical tax or VAT number' $cands $seenPair $Data
            }
        }
    }

    $byAddr = @{}
    foreach ($r in $records) {
        $ak = Get-CviAddressKey $Data $r.AddressNo
        if ($ak -eq '') { continue }
        if (-not $byAddr.ContainsKey($ak)) { $byAddr[$ak] = @() }
        $byAddr[$ak] += $r
    }
    foreach ($k in $byAddr.Keys) {
        $grp = @($byAddr[$k])
        if ($grp.Count -lt 2) { continue }
        for ($i = 0; $i -lt $grp.Count; $i++) {
            for ($j = $i + 1; $j -lt $grp.Count; $j++) {
                if ((Get-CviNameSimilarity $grp[$i].Name $grp[$j].Name) -lt 0.34) { continue }
                Add-Pair $grp[$i] $grp[$j] 'same address and similar name' $cands $seenPair $Data
            }
        }
    }

    # Records that the source system already treats as natural persons - through the account
    # group type or through a personal form of address - while their BP grouping creates
    # organisations. The "does the name read like a person" test is deliberately only a
    # confidence signal: on its own it mistakes short company names for people.
    foreach ($r in $records) {
        if ($r.Grouping -eq '' -or -not $Data.GroupingByKey.ContainsKey($r.Grouping)) { continue }
        $grpText = Get-CviText $Data.GroupingByKey[$r.Grouping].TEXT
        $declaredPerson = ($r.TypeHint -eq 'PERSON') -or ($script:PersonTitles -contains $r.Title)
        $looksPerson = Test-CviLooksLikePerson $r.Name $r.Title
        $groupingIsPerson = ($grpText -match '(?i)person|employee')
        if ($declaredPerson -and -not $groupingIsPerson) {
            $null = $cands.Add([pscustomobject]@{
                Type        = 'PARTNER_TYPE'
                PairKey     = "$($r.Table):$($r.Key)"
                LeftTable   = $r.Display; LeftKey = $r.Key; LeftName = $r.Name
                RightTable  = 'TB001';    RightKey = $r.Grouping; RightName = $grpText
                LeftGroup   = $r.AccountGroup
                RightGroup  = $r.Grouping
                LeftTitle   = $r.Title
                AccountText = $r.AccountText
                TypeHint    = $r.TypeHint
                LooksPerson = $looksPerson
                Reason      = $(if ($r.TypeHint -eq 'PERSON') { 'account group is a person account group' } else { "personal form of address '$($r.Title)'" })
            })
        }
    }

    # Account group to grouping assignments whose business meaning does not line up.
    foreach ($m in $Data.CustToBp) {
        $ag = Get-CviText $m.KTOKD; $grp = Get-CviText $m.GROUPING
        if (-not $Data.CustGrpByKey.ContainsKey($ag) -or -not $Data.GroupingByKey.ContainsKey($grp)) { continue }
        $null = $cands.Add([pscustomobject]@{
            Type        = 'MAPPING_SEMANTICS'
            PairKey     = "T077D:$ag"
            LeftTable   = 'T077D'; LeftKey = $ag; LeftName = (Get-CviText $Data.CustGrpByKey[$ag].TXT30)
            RightTable  = 'TB001'; RightKey = $grp; RightName = (Get-CviText $Data.GroupingByKey[$grp].TEXT)
            TypeHint    = (Get-CviText $Data.CustGrpByKey[$ag].PARTNER_TYPE_HINT)
            Reason      = 'account group to BP grouping assignment'
        })
    }
    foreach ($m in $Data.VendToBp) {
        $ag = Get-CviText $m.KTOKK; $grp = Get-CviText $m.GROUPING
        if (-not $Data.VendGrpByKey.ContainsKey($ag) -or -not $Data.GroupingByKey.ContainsKey($grp)) { continue }
        $null = $cands.Add([pscustomobject]@{
            Type        = 'MAPPING_SEMANTICS'
            PairKey     = "T077K:$ag"
            LeftTable   = 'T077K'; LeftKey = $ag; LeftName = (Get-CviText $Data.VendGrpByKey[$ag].TXT30)
            RightTable  = 'TB001'; RightKey = $grp; RightName = (Get-CviText $Data.GroupingByKey[$grp].TEXT)
            TypeHint    = (Get-CviText $Data.VendGrpByKey[$ag].PARTNER_TYPE_HINT)
            Reason      = 'account group to BP grouping assignment'
        })
    }

    return @($cands)
}

# ---------------------------------------------------------------- local judge

function Invoke-CviLocalJudge {
    param([object[]]$Candidates)
    $out = @()
    foreach ($c in $Candidates) {
        $verdict = 'NO_ACTION'; $conf = 0.5; $why = ''
        switch ($c.Type) {
            'CUSTOMER_VENDOR_PAIR' {
                $taxSame = ($c.LeftTax -ne '' -and ($c.LeftTax -replace '[^A-Za-z0-9]','').ToUpperInvariant() -eq ($c.RightTax -replace '[^A-Za-z0-9]','').ToUpperInvariant())
                $addrSame = ($c.LeftAddress -ne '' -and $c.LeftAddress -eq $c.RightAddress)
                $score = (0.5 * [int]$taxSame) + (0.35 * $c.NameSim) + (0.15 * [int]$addrSame)
                if ($score -ge 0.7) {
                    $verdict = 'ONE_BUSINESS_PARTNER'; $conf = [math]::Min(0.95, 0.55 + $score / 2)
                    $why = 'The tax identity, the name and the address all point at a single legal entity that trades in both directions. Converting it as two business partners duplicates the entity in S/4HANA.'
                } elseif ($score -ge 0.45) {
                    $verdict = 'REVIEW'; $conf = 0.6
                    $why = 'The two records overlap enough to be the same entity but not conclusively - a data owner should confirm before they are merged onto one business partner.'
                } else {
                    $verdict = 'NO_ACTION'; $conf = 0.7
                    $why = 'The overlap is weak; treating these as separate business partners is the safer reading.'
                }
                if ($taxSame) { $why += ' The shared tax registration is the strongest signal here.' }
            }
            'DUPLICATE' {
                $taxSame = ($c.LeftTax -ne '' -and ($c.LeftTax -replace '[^A-Za-z0-9]','').ToUpperInvariant() -eq ($c.RightTax -replace '[^A-Za-z0-9]','').ToUpperInvariant())
                $addrSame = ($c.LeftAddress -ne '' -and $c.LeftAddress -eq $c.RightAddress)
                $score = (0.45 * [int]$taxSame) + (0.4 * $c.NameSim) + (0.15 * [int]$addrSame)
                if ($score -ge 0.7) {
                    $verdict = 'DUPLICATE'; $conf = [math]::Min(0.95, 0.55 + $score / 2)
                    $why = 'The two records describe the same organisation under different keys. Converting both creates two business partners that then have to be merged after go-live, which is far more expensive than deciding now.'
                } elseif ($score -ge 0.45) {
                    $verdict = 'REVIEW'; $conf = 0.6
                    $why = 'Strong resemblance, but the differences could also be two genuine sites of one group. Confirm with the data owner.'
                } else {
                    $verdict = 'NO_ACTION'; $conf = 0.7
                    $why = 'The similarity is explained by a shared address or a common word in the name rather than by identity.'
                }
            }
            'PARTNER_TYPE' {
                $verdict = 'PERSON_EXPECTED'; $conf = 0.7
                $why = "The source record is a natural person ($($c.Reason)) but grouping $($c.RightKey) ('$($c.RightName)') creates organisation business partners. The BP would carry the person's name in the organisation name field, which breaks name search, correspondence and personal data handling."
                if ($c.TypeHint -eq 'PERSON') {
                    $conf = 0.85
                    $why += ' The account group itself is a person account group, so the mismatch sits in the mapping rather than in the data.'
                }
                if ($c.LooksPerson) {
                    $conf = [math]::Min(0.93, $conf + 0.06)
                    $why += ' The name itself also reads as a given name and a family name.'
                }
            }
            'MAPPING_SEMANTICS' {
                $left = "$($c.LeftName)".ToUpperInvariant()
                $right = "$($c.RightName)".ToUpperInvariant()
                $mismatch = $false
                # One-time handling is already decided deterministically by CFG-07, so it is
                # left out here rather than reported twice under two different lenses.
                foreach ($concept in @('EMPLOYEE','INTERCOMPANY','IMPORT','PROSPECT')) {
                    if ($left -like "*$concept*" -and $right -notlike "*$concept*") { $mismatch = $true }
                }
                if ($c.TypeHint -eq 'PERSON' -and $right -notmatch 'PERSON|EMPLOYEE') { $mismatch = $true }
                if ($mismatch) {
                    $verdict = 'REVIEW'; $conf = 0.66
                    $why = "Account group '$($c.LeftName)' is being folded into grouping '$($c.RightName)'. The two describe different kinds of partner, so the resulting BPs lose the distinction the account group was carrying - number ranges, roles and authorisations all inherit from the grouping."
                } else {
                    $verdict = 'NO_ACTION'; $conf = 0.8
                    $why = 'The account group and the grouping describe the same kind of partner.'
                }
            }
        }
        $out += [pscustomobject]@{
            PairKey    = $c.PairKey
            Verdict    = $verdict
            Confidence = [math]::Round($conf, 2)
            Rationale  = $why
        }
    }
    return $out
}

# ---------------------------------------------------------------- Claude judge

function Invoke-CviClaudeJudge {
    param([object[]]$Candidates, [string]$ApiKey, [string]$Model = 'claude-opus-5')

    $payloadItems = @()
    foreach ($c in $Candidates) {
        $payloadItems += [ordered]@{
            id       = $c.PairKey
            type     = $c.Type
            left     = "$($c.LeftTable) $($c.LeftKey) '$($c.LeftName)' group=$($c.LeftGroup) tax='$($c.LeftTax)' address='$($c.LeftAddress)'"
            right    = "$($c.RightTable) $($c.RightKey) '$($c.RightName)' group=$($c.RightGroup) tax='$($c.RightTax)' address='$($c.RightAddress)'"
            hint     = "$($c.Reason); name similarity $($c.NameSim); account group type hint '$($c.TypeHint)'"
        }
    }

    $system = @'
You are an SAP master data consultant reviewing candidates for a customer/vendor
integration (CVI) run ahead of an ECC to S/4HANA conversion. For each candidate return
one verdict object. Allowed verdicts:
  CUSTOMER_VENDOR_PAIR -> ONE_BUSINESS_PARTNER | REVIEW | NO_ACTION
  DUPLICATE            -> DUPLICATE | REVIEW | NO_ACTION
  PARTNER_TYPE         -> PERSON_EXPECTED | REVIEW | NO_ACTION
  MAPPING_SEMANTICS    -> REVIEW | NO_ACTION
Judge conservatively: prefer REVIEW over a confident merge when the evidence is thin.
Respond with JSON only, no prose and no code fences, in the shape:
{"verdicts":[{"id":"...","verdict":"...","confidence":0.0,"rationale":"one or two sentences"}]}
'@

    $body = [ordered]@{
        model      = $Model
        max_tokens = 8000
        system     = $system
        messages   = @(@{ role = 'user'; content = ('Candidates:' + [Environment]::NewLine + (ConvertTo-Json $payloadItems -Depth 6)) })
    }

    $json = ConvertTo-Json $body -Depth 8
    $headers = @{
        'x-api-key'         = $ApiKey
        'anthropic-version' = '2023-06-01'
        'content-type'      = 'application/json'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' -Method Post -Headers $headers `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json' -TimeoutSec 180

    if ($resp.stop_reason -eq 'refusal') { throw 'The model declined to answer this request.' }

    $text = ''
    foreach ($block in $resp.content) { if ($block.type -eq 'text') { $text += $block.text } }
    $text = $text.Trim()
    if ($text -match '(?s)\{.*\}') { $text = $Matches[0] }
    $parsed = $text | ConvertFrom-Json

    $out = @()
    foreach ($v in $parsed.verdicts) {
        $out += [pscustomobject]@{
            PairKey    = [string]$v.id
            Verdict    = [string]$v.verdict
            Confidence = [double]$v.confidence
            Rationale  = [string]$v.rationale
        }
    }
    return $out
}

function Invoke-CviJudgment {
    param($Data, [switch]$ForceLocal)

    $candidates = @(Get-CviCandidates $Data)
    $mode = 'local heuristic judge'
    $modeDetail = 'No ANTHROPIC_API_KEY in the environment, so candidates were judged locally.'
    $verdicts = @()

    $key = $env:ANTHROPIC_API_KEY
    if (-not $ForceLocal -and $key -and $candidates.Count -gt 0) {
        try {
            $verdicts = Invoke-CviClaudeJudge -Candidates $candidates -ApiKey $key
            $mode = 'claude-opus-5'
            $modeDetail = 'Candidates were judged by Claude through the Messages API.'
        } catch {
            $verdicts = @()
            $modeDetail = "Claude call failed ($($_.Exception.Message)); fell back to the local heuristic judge."
        }
    }
    if ($verdicts.Count -eq 0) {
        $verdicts = @(Invoke-CviLocalJudge -Candidates $candidates)
        if ($mode -ne 'local heuristic judge') { $mode = 'local heuristic judge' }
    }

    $byKey = @{}
    foreach ($v in $verdicts) { $byKey[$v.PairKey] = $v }

    $pairEv = @(); $dupEv = @(); $typeEv = @(); $mapEv = @()
    foreach ($c in $candidates) {
        $v = $null
        if ($byKey.ContainsKey($c.PairKey)) { $v = $byKey[$c.PairKey] }
        if (-not $v) { continue }
        if ($v.Verdict -eq 'NO_ACTION') { continue }
        $conf = [math]::Round([double]$v.Confidence, 2)
        switch ($c.Type) {
            'CUSTOMER_VENDOR_PAIR' {
                $pairEv += New-CviEvidence $c.LeftTable $c.LeftKey $v.Verdict "conf $conf" `
                    "$($c.LeftName) <-> $($c.RightTable) $($c.RightKey) $($c.RightName). $($v.Rationale)" `
                    'Convert onto one business partner carrying both the customer and the supplier role'
            }
            'DUPLICATE' {
                $dupEv += New-CviEvidence $c.LeftTable $c.LeftKey $v.Verdict "conf $conf" `
                    "$($c.LeftName) <-> $($c.RightTable) $($c.RightKey) $($c.RightName). $($v.Rationale)" `
                    'Decide a surviving record before the conversion rather than merging BPs afterwards'
            }
            'PARTNER_TYPE' {
                $typeEv += New-CviEvidence $c.LeftTable $c.LeftKey $v.Verdict "conf $conf" `
                    "$($c.LeftName) is mapped to grouping $($c.RightKey) ($($c.RightName)). $($v.Rationale)" `
                    'Route this account group to a person BP grouping'
            }
            'MAPPING_SEMANTICS' {
                $mapEv += New-CviEvidence $c.LeftTable $c.LeftKey $v.Verdict "conf $conf" `
                    "'$($c.LeftName)' -> grouping $($c.RightKey) '$($c.RightName)'. $($v.Rationale)" `
                    'Confirm the assignment with the process owner or split the grouping'
            }
        }
    }

    $checks = @()
    $checks += New-CviCheck -Id 'AI-01' -Title 'Customers and vendors that are one legal entity' -Category 'Judgment' -Severity 'HIGH' `
        -Why 'A company that both buys and sells appears twice in ECC. In the BP model it should be one partner with two roles. Converting it as two partners is the single most common irreversible mistake in a CVI run.' `
        -Fix 'Link both roles to one BP before the mass run for the confirmed pairs, and put the rest in front of a data owner.' `
        -ImgPath 'Transaction MDS_LOAD_COCKPIT / BP role assignment' `
        -Evidence $pairEv -PassSummary 'No customer/vendor pair looks like a single legal entity.' -FailSummary '{n} customer/vendor pair(s) look like one legal entity.' `
        -ActionId 'AI-01' -ActionLabel 'Export merge worklist' -ActionKind 'judgment'

    $checks += New-CviCheck -Id 'AI-02' -Title 'Duplicate records inside one object' -Category 'Judgment' -Severity 'HIGH' `
        -Why 'Duplicates that survive the conversion become duplicate business partners. Cleaning them up afterwards means merging live transactional history.' `
        -Fix 'Agree a surviving record per group and mark the others for exclusion before the load.' `
        -ImgPath 'Transaction XD05 / MK05 and the BP duplicate check' `
        -Evidence $dupEv -PassSummary 'No duplicate records were identified.' -FailSummary '{n} probable duplicate pair(s) found.' `
        -ActionId 'AI-02' -ActionLabel 'Export duplicate worklist' -ActionKind 'judgment'

    $checks += New-CviCheck -Id 'AI-03' -Title 'Person records routed to an organisation grouping' -Category 'Judgment' -Severity 'MEDIUM' `
        -Why 'Employees and other natural persons converted under an organisation grouping end up with a person name in the organisation name field - it breaks search, correspondence and personal data handling.' `
        -Fix 'Route the affected account groups to a grouping that creates person business partners.' `
        -ImgPath 'SPRO > ... > Define Number Assignment for Direction Customer/Vendor to BP' `
        -Evidence $typeEv -PassSummary 'No person records are routed to an organisation grouping.' -FailSummary '{n} record(s) look like natural persons under an organisation grouping.' `
        -ActionId 'AI-03' -ActionLabel 'Export partner type worklist' -ActionKind 'judgment'

    $checks += New-CviCheck -Id 'AI-04' -Title 'Account group to grouping assignments make business sense' -Category 'Judgment' -Severity 'MEDIUM' `
        -Why 'A mapping can be complete and still wrong. Folding distinct account groups into one grouping quietly discards the distinction the business was relying on.' `
        -Fix 'Review the flagged assignments with the process owner before the configuration is transported.' `
        -ImgPath 'SPRO > ... > Define Number Assignment for Direction Customer/Vendor to BP' `
        -Evidence $mapEv -PassSummary 'All assignments are semantically consistent.' -FailSummary '{n} assignment(s) fold an account group into a grouping with a different meaning.' `
        -ActionId 'AI-04' -ActionLabel 'Export mapping review list' -ActionKind 'judgment'

    foreach ($c in $checks) { $c.Layer = 'JUDGMENT' }

    return @{
        Checks         = @($checks)
        Mode           = $mode
        ModeDetail     = $modeDetail
        CandidateCount = $candidates.Count
    }
}
