# Cvi.Actions.ps1 - turns a finding into something somebody can act on without retyping it.

function Get-CviCheck {
    param($Report, [string]$CheckId)
    foreach ($c in $Report.Checks) { if ($c.Id -eq $CheckId) { return $c } }
    return $null
}

function New-CviFixPack {
    param($Report, [string]$CheckId, [string]$OutDir)

    $check = Get-CviCheck -Report $Report -CheckId $CheckId
    if (-not $check) { throw "Unknown check '$CheckId'." }
    if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

    $rows = @()
    foreach ($e in $check.Evidence) {
        $rows += [pscustomobject]@{
            CHECK      = $check.Id
            SEVERITY   = $check.Severity
            CATEGORY   = $check.Category
            OBJECT     = $e.Object
            TABLE      = $e.Table
            KEY        = $e.Key
            FIELD      = $e.Field
            VALUE      = $e.Value
            FINDING    = $e.Detail
            ACTION     = $e.Proposal
            # The decision taken on the page. A worklist that carries what the object should
            # become is something the person doing the correction can work straight from.
            CHANGE_TO  = $e.Choice
            OWNER      = ''
            STATUS     = $(if ((Get-CviText $e.Choice) -ne '') { 'DECIDED' } else { 'OPEN' })
        }
    }

    $csvPath = Join-Path $OutDir ("{0}_worklist.csv" -f $check.Id)
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    } else {
        'CHECK,SEVERITY,CATEGORY,OBJECT,TABLE,KEY,FIELD,VALUE,FINDING,ACTION,CHANGE_TO,OWNER,STATUS' | Out-File -LiteralPath $csvPath -Encoding utf8
    }

    $md = @()
    $md += "# $($check.Id) - $($check.Title)"
    $md += ''
    $md += "**Severity:** $($check.Severity)  |  **Category:** $($check.Category)  |  **Layer:** $($check.Layer)  |  **Affected:** $($check.Count)"
    $md += ''
    $md += '## What the tool found'
    $md += $check.Summary
    $md += ''
    $md += '## Why it matters'
    $md += $check.Why
    $md += ''
    $md += '## What to do'
    $md += $check.Fix
    $md += ''
    $md += '## Where'
    $md += '```'
    $md += $check.ImgPath
    $md += '```'
    $md += ''
    $md += "## Worklist"
    $decided = @($rows | Where-Object { (Get-CviText $_.CHANGE_TO) -ne '' }).Count
    $md += "See ``$([IO.Path]::GetFileName($csvPath))`` - $($rows.Count) row(s), one per affected object, with OWNER and STATUS columns to track the correction."
    $md += ''
    $md += "$decided of $($rows.Count) row(s) carry a decision in CHANGE_TO - what that object should become. The rest are still open."
    if ($check.RecordedBy) {
        $md += ''
        $md += "## Recorded"
        $md += "$($check.Id) was marked done by $($check.RecordedBy) on $($check.RecordedAt). That is a record that somebody took it on, not evidence that the system was corrected - the check will fail again on the next extract if the data is still wrong."
    }
    $mdPath = Join-Path $OutDir ("{0}_instructions.md" -f $check.Id)
    ($md -join [Environment]::NewLine) | Out-File -LiteralPath $mdPath -Encoding utf8

    return [pscustomobject]@{
        CheckId = $check.Id
        Rows    = $rows.Count
        Files   = @([IO.Path]::GetFileName($csvPath), [IO.Path]::GetFileName($mdPath))
        OutDir  = (Resolve-Path -LiteralPath $OutDir).Path
    }
}

function New-CviFullPack {
    param($Report, [string]$OutDir)

    if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }
    $files = @()
    $failing = @($Report.Checks | Where-Object { $_.Status -eq 'FAIL' })

    foreach ($c in $failing) {
        $pack = New-CviFixPack -Report $Report -CheckId $c.Id -OutDir $OutDir
        $files += $pack.Files
    }

    # One flat summary that a project manager can filter and assign.
    $summary = @()
    foreach ($c in $Report.Checks) {
        $summary += [pscustomobject]@{
            CHECK    = $c.Id
            TITLE    = $c.Title
            CATEGORY = $c.Category
            LAYER    = $c.Layer
            SEVERITY = $c.Severity
            STATUS   = $c.Status
            AFFECTED = $c.Count
            SUMMARY  = $c.Summary
            OWNER    = ''
            DUE      = ''
        }
    }
    $summaryPath = Join-Path $OutDir 'CVI_READINESS_SUMMARY.csv'
    $summary | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8
    $files += 'CVI_READINESS_SUMMARY.csv'

    # The configuration task list, in the order the work has to happen.
    $tasks = @()
    $tasks += "# CVI configuration task list - $($Report.SystemId)/$($Report.Client)"
    $tasks += ''
    $tasks += "Generated $($Report.GeneratedAt). Readiness score $($Report.Score)/100 - $($Report.Gate)."
    $tasks += ''
    foreach ($grp in @('Configuration','SAP Notes','Judgment','Master data')) {
        $inGroup = @($failing | Where-Object { $_.Category -eq $grp })
        if ($inGroup.Count -eq 0) { continue }
        $tasks += "## $grp"
        $tasks += ''
        foreach ($c in $inGroup) {
            $tasks += "- [ ] **$($c.Id) ($($c.Severity))** $($c.Title) - $($c.Summary)"
            $tasks += "      Path: $($c.ImgPath)"
            $tasks += "      Worklist: $($c.Id)_worklist.csv"
        }
        $tasks += ''
    }
    $tasksPath = Join-Path $OutDir 'CVI_TASK_LIST.md'
    ($tasks -join [Environment]::NewLine) | Out-File -LiteralPath $tasksPath -Encoding utf8
    $files += 'CVI_TASK_LIST.md'

    $numbers = New-CviNumberRangeProposal -Report $Report -OutDir $OutDir
    $files += $numbers.Files

    $jsonPath = Join-Path $OutDir 'cvi_report.json'
    ($Report | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $jsonPath -Encoding utf8
    $files += 'cvi_report.json'

    return [pscustomobject]@{
        CheckId = 'ALL'
        Rows    = ($failing | Measure-Object -Property Count -Sum).Sum
        Files   = @($files | Sort-Object -Unique)
        OutDir  = (Resolve-Path -LiteralPath $OutDir).Path
    }
}
