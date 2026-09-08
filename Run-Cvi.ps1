<#
.SYNOPSIS
    CVI Readiness Analyzer - checks an ECC customer/vendor landscape for business partner
    conversion readiness and returns an actionable report.

.DESCRIPTION
    Reads the extracted configuration and master data under .\data, runs the deterministic
    rule layer and the judgment layer, and either serves the report as a local web app
    (default) or prints it to the console.

.EXAMPLE
    .\Run-Cvi.ps1
    Runs the analysis and opens the report in the browser at http://localhost:8787/

.EXAMPLE
    .\Run-Cvi.ps1 -Console
    Prints the report to the terminal and exits.

.EXAMPLE
    .\Run-Cvi.ps1 -Console -Export
    Prints the report and writes every worklist and the task list into .\out
#>
[CmdletBinding()]
param(
    [int]$Port = 8787,
    [switch]$Console,
    [switch]$Export,
    [switch]$LocalJudge,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

. (Join-Path $root 'src\Cvi.Data.ps1')
. (Join-Path $root 'src\Cvi.Rules.ps1')
. (Join-Path $root 'src\Cvi.AiJudge.ps1')
. (Join-Path $root 'src\Cvi.Numbers.ps1')
. (Join-Path $root 'src\Cvi.Analyze.ps1')
. (Join-Path $root 'src\Cvi.Actions.ps1')
. (Join-Path $root 'src\Cvi.Chat.ps1')
. (Join-Path $root 'src\Cvi.Send.ps1')
. (Join-Path $root 'src\Cvi.Server.ps1')

function Write-CviConsoleReport {
    param($Report)

    $sevColor = @{ 'BLOCKER' = 'Red'; 'HIGH' = 'DarkYellow'; 'MEDIUM' = 'Yellow'; 'LOW' = 'DarkGray' }

    Write-Host ''
    Write-Host '  CVI READINESS REPORT' -ForegroundColor White
    Write-Host "  $($Report.SystemId)/$($Report.Client)  |  $($Report.SourceRelease) -> $($Report.TargetRelease)  |  $($Report.Strategy) strategy"
    Write-Host "  Generated $($Report.GeneratedAt) in $($Report.DurationMs) ms  |  judgment layer: $($Report.AiMode)" -ForegroundColor DarkGray
    Write-Host ''

    $filled = [int][math]::Round($Report.Score / 4)
    $bar = ('#' * $filled) + ('.' * (25 - $filled))
    $gateColor = 'Green'
    if ($Report.Gate -eq 'NOT READY') { $gateColor = 'Red' } elseif ($Report.Gate -eq 'READY WITH ACTIONS') { $gateColor = 'Yellow' }
    Write-Host "  Score  [$bar] $($Report.Score)/100   " -NoNewline
    Write-Host $Report.Gate -ForegroundColor $gateColor
    $c = $Report.Counts
    Write-Host "  $($c.Blocker) blocker  $($c.High) high  $($c.Medium) medium  $($c.Low) low  |  $($c.Passed) checks passed of $($c.Checks)"
    Write-Host "  Scope: $($c.Customers) customers, $($c.Vendors) vendors, $($c.Contacts) contact persons, $($c.AccountGroups) account groups, $($c.Groupings) BP groupings"
    Write-Host "  $($c.Affected) object(s) need attention across $($c.Failed) failing check(s); $($c.Candidates) candidate(s) went through the judgment layer"
    Write-Host ''

    foreach ($check in $Report.Checks) {
        if ($check.Status -ne 'FAIL') { continue }
        $color = 'Yellow'
        if ($sevColor.ContainsKey($check.Severity)) { $color = $sevColor[$check.Severity] }
        Write-Host "  [$($check.Severity)] $($check.Id)  $($check.Title)" -ForegroundColor $color
        Write-Host "      $($check.Summary)"
        $shown = 0
        foreach ($e in $check.Evidence) {
            if ($shown -ge 4) { break }
            Write-Host "        - $($e.Object) $($e.Key) $($e.Field) $($e.Value) : $($e.Detail)" -ForegroundColor DarkGray
            $shown++
        }
        if ($check.Count -gt $shown) {
            Write-Host "        ... and $($check.Count - $shown) more" -ForegroundColor DarkGray
        }
        Write-Host "      Fix: $($check.Fix)" -ForegroundColor DarkGray
        Write-Host ''
    }

    $passed = @($Report.Checks | Where-Object { $_.Status -eq 'PASS' })
    if ($passed.Count -gt 0) {
        Write-Host "  Passed: $((($passed | ForEach-Object { $_.Id }) -join ', '))" -ForegroundColor DarkGreen
        Write-Host ''
    }
}

if ($Console) {
    $report = Invoke-CviAnalysis -Root $root -ForceLocalJudge:$LocalJudge
    Write-CviConsoleReport -Report $report
    if ($Export) {
        $outDir = Join-Path $root 'out'
        $pack = New-CviFullPack -Report $report -OutDir $outDir
        Write-Host "  Wrote $($pack.Files.Count) file(s) to $($pack.OutDir)" -ForegroundColor Cyan
        Write-Host ''
    }
    return
}

Start-CviServer -Root $root -Port $Port -ForceLocalJudge:$LocalJudge -NoBrowser:$NoBrowser
