# Cvi.Analyze.ps1 - runs both layers and assembles the report object the UI and the CLI share.

function Invoke-CviAnalysis {
    param([string]$Root, [switch]$ForceLocalJudge)

    $started = Get-Date
    $data = Get-CviDataset -Root $Root
    $ruleChecks = Invoke-CviRules -Data $data
    $judgment = Invoke-CviJudgment -Data $data -ForceLocal:$ForceLocalJudge

    # The rules produce the state of the data; the overlay adds what people decided about it.
    # In that order, so a decision can never change what a check found.
    $checks = Add-CviDecisionState -Data $data -Checks (@($ruleChecks) + @($judgment.Checks))
    $score = Get-CviScore -Checks $checks
    $numberPlan = Get-CviNumberPlan -Data $data

    $sev = @{ 'BLOCKER' = 0; 'HIGH' = 0; 'MEDIUM' = 0; 'LOW' = 0 }
    $passed = 0; $na = 0; $affected = 0; $done = 0; $doneObjects = 0; $doneBlockers = 0
    foreach ($c in $checks) {
        if ($c.Status -eq 'PASS') { $passed++; continue }
        if ($c.Status -eq 'NA')   { $na++; continue }
        if ($c.Status -eq 'DONE') {
            $done++
            $doneObjects += $c.Count
            if ($c.Severity -eq 'BLOCKER') { $doneBlockers++ }
            continue
        }
        $sev[$c.Severity] = $sev[$c.Severity] + 1
        $affected += $c.Count
    }

    # A recorded check stops blocking the gate, because that is what recording it is for.
    # It is never silent about it: the gate carries the count, and so does the header.
    $gate = 'READY'
    if ($sev['BLOCKER'] -gt 0) { $gate = 'NOT READY' }
    elseif (($sev['HIGH'] + $sev['MEDIUM'] + $sev['LOW']) -gt 0) { $gate = 'READY WITH ACTIONS' }
    if ($done -gt 0 -and $gate -ne 'NOT READY') { $gate = "$gate (ON RECORD)" }

    $set = $data.Settings
    $customers = @($data.Records | Where-Object { $_.Object -eq 'CUSTOMER' }).Count
    $vendors   = @($data.Records | Where-Object { $_.Object -eq 'VENDOR' }).Count

    $order = @{ 'BLOCKER' = 0; 'HIGH' = 1; 'MEDIUM' = 2; 'LOW' = 3 }
    $sorted = @($checks | Sort-Object `
        @{ Expression = { if ($_.Status -eq 'FAIL') { 0 } elseif ($_.Status -eq 'DONE') { 1 } elseif ($_.Status -eq 'NA') { 2 } else { 3 } } }, `
        @{ Expression = { $order[$_.Severity] } }, `
        @{ Expression = { $_.Id } })

    [pscustomobject]@{
        GeneratedAt   = $started.ToString('yyyy-MM-dd HH:mm:ss')
        DurationMs    = [int]((Get-Date) - $started).TotalMilliseconds
        SystemId      = $set['SYSTEM_ID']
        Client        = $set['CLIENT']
        SourceRelease = $set['SOURCE_RELEASE']
        TargetRelease = $set['TARGET_RELEASE']
        Strategy      = $set['NUMBER_STRATEGY']
        Score         = $score
        Gate          = $gate
        AiMode        = $judgment.Mode
        AiDetail      = $judgment.ModeDetail
        # How many notes somebody ticked off in the report. The page needs it to keep the note
        # card on screen once every note is confirmed - the check passes and would otherwise be
        # hidden with the rest of the passed checks, taking the only way to undo with it.
        NoteConfirmations = @($data.NoteStatus).Count
        Counts        = [pscustomobject]@{
            Blocker       = $sev['BLOCKER']
            High          = $sev['HIGH']
            Medium        = $sev['MEDIUM']
            Low           = $sev['LOW']
            Failed        = $sev['BLOCKER'] + $sev['HIGH'] + $sev['MEDIUM'] + $sev['LOW']
            Passed        = $passed
            Done          = $done
            DoneObjects   = $doneObjects
            DoneBlockers  = $doneBlockers
            NotApplicable = $na
            Checks        = $checks.Count
            Affected      = $affected
            Customers     = $customers
            Vendors       = $vendors
            Contacts      = $data.Contacts.Count
            Addresses     = $data.Addresses.Count
            AccountGroups = $data.CustAccountGrp.Count + $data.VendAccountGrp.Count
            Groupings     = $data.BpGrouping.Count
            Candidates    = $judgment.CandidateCount
        }
        Checks        = $sorted
        NumberPlan    = $numberPlan
    }
}
