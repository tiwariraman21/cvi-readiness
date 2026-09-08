# Cvi.Send.ps1 - hand the confirmed number ranges over to the target system.
#
# Two stages, deliberately separate:
#   1. the consultant confirms individual intervals on the page (stored per interval)
#   2. the confirmed set is checked, then written as a package the target system can take
#
# The package is the deliverable. A direct push exists but is off unless a target system is
# configured in data\config\CVI_TARGET_SYSTEM.csv, and it never stores credentials - those
# come from CVI_SAP_USER and CVI_SAP_PASSWORD in the environment.

function Get-CviTargetSystem {
    param([string]$Root)
    $path = Join-Path $Root 'data\config\CVI_TARGET_SYSTEM.csv'
    $row = $null
    if (Test-Path -LiteralPath $path) { $row = @(Import-Csv -LiteralPath $path) | Select-Object -First 1 }
    if (-not $row) {
        return [pscustomobject]@{ Enabled = $false; SystemId = ''; BaseUrl = ''; Client = ''; Note = 'No target system is configured.' }
    }
    $enabled = ((Get-CviText $row.ENABLED) -eq 'X') -and ((Get-CviText $row.BASE_URL) -ne '')
    $note = ''
    if (-not $enabled) { $note = 'A target system is listed but not enabled, or has no base URL.' }
    if ($enabled -and (-not $env:CVI_SAP_USER -or -not $env:CVI_SAP_PASSWORD)) {
        $enabled = $false
        $note = 'The target system is enabled but CVI_SAP_USER / CVI_SAP_PASSWORD are not set in the environment.'
    }
    [pscustomobject]@{
        Enabled  = $enabled
        SystemId = Get-CviText $row.SYSTEM_ID
        BaseUrl  = Get-CviText $row.BASE_URL
        Client   = Get-CviText $row.CLIENT
        Note     = $note
    }
}

function Test-CviSendReadiness {
    # What must hold before a confirmed set is worth handing over. Each blocker names the
    # interval it belongs to, so it can be fixed on the page and re-confirmed.
    param($Report)

    $plan = $Report.NumberPlan
    $confirmed = @($plan.Proposals | Where-Object { $_.Confirmed })
    $blockers = @()

    if ($confirmed.Count -eq 0) {
        $blockers += 'Nothing is confirmed yet - tick Confirm on the intervals to send.'
    }

    foreach ($p in $confirmed) {
        if (-not $p.Valid) {
            $blockers += "$($p.Grouping) ($($p.RangeNo): $($p.From)-$($p.To)) is confirmed but does not cover its records: $($p.ValidationNote)"
        }
        if ($p.RangeNo -eq '(new)' -or $p.RangeNo -eq '') {
            $blockers += "$($p.Grouping) has no number range key - replace '(new)' with the two-character key to create in SNRO."
        }
    }

    # Two confirmed intervals must not accept the same number.
    $sorted = @($confirmed | Where-Object { $_.External } | Sort-Object From)
    for ($i = 0; $i -lt $sorted.Count - 1; $i++) {
        $a = $sorted[$i]; $b = $sorted[$i + 1]
        $aTo = ConvertTo-CviNum $a.To; $bFrom = ConvertTo-CviNum $b.From
        if ($null -eq $aTo -or $null -eq $bFrom) { continue }
        if ($bFrom -le $aTo) {
            $blockers += "$($a.Grouping) ($($a.From)-$($a.To)) and $($b.Grouping) ($($b.From)-$($b.To)) are both confirmed and overlap."
        }
    }

    # Number collisions are a data decision, not an interval one - they are reported as a
    # warning so the send is not silently blocked on something intervals cannot fix.
    $warnings = @()
    if ($plan.Collisions.Count -gt 0) {
        $warnings += "$($plan.Collisions.Count) number(s) are claimed by both a customer and a vendor. The intervals can be created, but those records still need one BP with both roles."
    }
    $unconfirmed = @($plan.Proposals | Where-Object { -not $_.Confirmed -and $_.Action -ne 'KEEP' })
    if ($unconfirmed.Count -gt 0) {
        $warnings += "$($unconfirmed.Count) interval(s) still need a change but are not confirmed - they are not in this package."
    }

    return [pscustomobject]@{
        Ready     = ($blockers.Count -eq 0)
        Blockers  = @($blockers)
        Warnings  = @($warnings)
        Confirmed = @($confirmed)
    }
}

function New-CviSystemPackage {
    # The files the target system takes: intervals, groupings, account group mapping, and a
    # runbook naming the transaction for each one.
    param($Report, [string]$OutDir)

    $sendDir = Join-Path $OutDir 'send'
    if (-not (Test-Path -LiteralPath $sendDir)) { $null = New-Item -ItemType Directory -Path $sendDir -Force }

    $readiness = Test-CviSendReadiness -Report $Report
    $confirmed = @($readiness.Confirmed)
    $files = @()
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    # 1. Number range intervals - the fields SNRO maintains for object BU_PARTNER.
    $intervals = @()
    foreach ($p in $confirmed) {
        $intervals += [pscustomobject]@{
            OBJECT         = 'BU_PARTNER'
            SUBOBJECT      = ''
            NR             = $p.RangeNo
            FROM_NUMBER    = $p.From
            TO_NUMBER      = $p.To
            CURRENT_NUMBER = ''
            EXTERNAL       = $(if ($p.External) { 'X' } else { '' })
            GROUPING       = $p.Grouping
            SOURCE         = $p.AccountGroups
        }
    }
    $p1 = Join-Path $sendDir 'BU_PARTNER_INTERVALS.csv'
    $intervals | Export-Csv -LiteralPath $p1 -NoTypeInformation -Encoding UTF8
    $files += 'send\BU_PARTNER_INTERVALS.csv'

    # 2. Grouping to interval assignment - view V_TB001.
    $groupings = @()
    foreach ($p in $confirmed) {
        if ($p.Grouping -eq '(internal)') { continue }
        $groupings += [pscustomobject]@{
            GROUPING     = $p.Grouping
            TEXT         = $p.Text
            NUMBER_RANGE = $p.RangeNo
            EXTERNAL     = $(if ($p.External) { 'X' } else { '' })
            INT_STD      = ''
            EXT_STD      = ''
            ACTION       = $p.Action
        }
    }
    $p2 = Join-Path $sendDir 'TB001_GROUPINGS.csv'
    $groupings | Export-Csv -LiteralPath $p2 -NoTypeInformation -Encoding UTF8
    $files += 'send\TB001_GROUPINGS.csv'

    # 3. Account group to grouping assignment - the CVI customising this all serves.
    $mapping = @()
    foreach ($p in $confirmed) {
        if ($p.AccountGroups -eq '') { continue }
        foreach ($src in ($p.AccountGroups -split ',')) {
            $bits = @($src.Trim() -split '\s+')
            if ($bits.Count -lt 2) { continue }
            $mapping += [pscustomobject]@{
                OBJECT        = $bits[0].ToUpperInvariant()
                ACCOUNT_GROUP = $bits[1]
                GROUPING      = $p.Grouping
                NUMBER_RANGE  = $p.RangeNo
            }
        }
    }
    $p3 = Join-Path $sendDir 'CVI_ACCOUNT_GROUP_MAPPING.csv'
    $mapping | Export-Csv -LiteralPath $p3 -NoTypeInformation -Encoding UTF8
    $files += 'send\CVI_ACCOUNT_GROUP_MAPPING.csv'

    # 4. The same content as one payload, for a system that takes it over an interface.
    $payload = [ordered]@{
        source       = "$($Report.SystemId)/$($Report.Client)"
        targetRelease = $Report.TargetRelease
        strategy     = $Report.Strategy
        generatedAt  = $stamp
        intervals    = @($intervals)
        groupings    = @($groupings)
        mapping      = @($mapping)
    }
    $p4 = Join-Path $sendDir 'payload.json'
    ($payload | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $p4 -Encoding utf8
    $files += 'send\payload.json'

    # 5. The runbook.
    $md = @()
    $md += "# Applying the confirmed number ranges - $($Report.SystemId)/$($Report.Client)"
    $md += ''
    $md += "Generated $stamp. $($confirmed.Count) confirmed interval(s). Target release $($Report.TargetRelease), strategy $($Report.Strategy)."
    $md += ''
    if ($readiness.Blockers.Count -gt 0) {
        $md += '## Not ready to apply'
        $md += ''
        foreach ($b in $readiness.Blockers) { $md += "- $b" }
        $md += ''
    }
    if ($readiness.Warnings.Count -gt 0) {
        $md += '## Read before applying'
        $md += ''
        foreach ($w in $readiness.Warnings) { $md += "- $w" }
        $md += ''
    }
    $md += '## Confirmed intervals'
    $md += ''
    $md += '| Grouping | Range | From | To | Ext | Sources | Action |'
    $md += '|---|---|---|---|---|---|---|'
    foreach ($p in $confirmed) {
        $ext = ''
        if ($p.External) { $ext = 'X' }
        $md += "| $($p.Grouping) | $($p.RangeNo) | $($p.From) | $($p.To) | $ext | $($p.AccountGroups) | $($p.Action) |"
    }
    $md += ''
    $md += '## Order of application'
    $md += ''
    $md += '1. `SNRO` - object `BU_PARTNER`. Create or change each interval from `BU_PARTNER_INTERVALS.csv`. External where the Ext column is marked.'
    $md += '2. `SM30` view `V_TB001` (or SPRO > Cross-Application Components > SAP Business Partner > Business Partner > Basic Settings > Number Ranges and Groupings > Define Groupings and Assign Number Ranges) - apply `TB001_GROUPINGS.csv`.'
    $md += '3. SPRO > ... > Customer/Vendor Integration > Define Number Assignment for Direction Customer/Vendor to BP - apply `CVI_ACCOUNT_GROUP_MAPPING.csv`.'
    $md += '4. Record all three in one transport request and move it with the rest of the CVI customising.'
    $md += '5. Re-run this tool against a fresh extract. CFG-05, CFG-06 and CFG-08 confirm the design landed.'
    $md += ''
    $md += 'Number range intervals are not always transported - check whether this landscape moves them by transport or maintains them per system, and apply step 1 in each system if it is the latter.'
    $p5 = Join-Path $sendDir 'APPLY_RUNBOOK.md'
    ($md -join [Environment]::NewLine) | Out-File -LiteralPath $p5 -Encoding utf8
    $files += 'send\APPLY_RUNBOOK.md'

    return [pscustomobject]@{
        Files     = @($files)
        Intervals = $intervals.Count
        Mappings  = $mapping.Count
        Readiness = $readiness
        SendDir   = (Resolve-Path -LiteralPath $sendDir).Path
        PayloadPath = $p4
    }
}

function Send-CviToSystem {
    # Only reached when a target is configured, enabled, credentials are in the environment,
    # and the caller asked for a push explicitly.
    param($Report, [string]$Root, [string]$PayloadPath)

    $target = Get-CviTargetSystem -Root $Root
    if (-not $target.Enabled) {
        return [pscustomobject]@{ Posted = $false; Message = $target.Note }
    }

    $body = Get-Content -LiteralPath $PayloadPath -Raw
    $pair = "$($env:CVI_SAP_USER):$($env:CVI_SAP_PASSWORD)"
    $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{ 'Authorization' = "Basic $auth"; 'Content-Type' = 'application/json' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        $resp = Invoke-RestMethod -Uri $target.BaseUrl -Method Post -Headers $headers `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
        return [pscustomobject]@{
            Posted  = $true
            Message = "Posted to $($target.SystemId) at $($target.BaseUrl)."
            Response = ($resp | ConvertTo-Json -Depth 5 -Compress)
        }
    } catch {
        return [pscustomobject]@{ Posted = $false; Message = "Post to $($target.BaseUrl) failed: $($_.Exception.Message)" }
    }
}
