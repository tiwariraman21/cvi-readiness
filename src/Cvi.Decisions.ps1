# Cvi.Decisions.ps1 - what a consultant decides about a finding, and the record that they did.
#
# Two separate things live here, and they are deliberately not the same thing:
#
#   the choice   - per affected object, what that object should become. Written into the fix
#                  pack so the worklist carries the decision rather than just the problem.
#   the record   - per check, that somebody has taken it on. The check then reads DONE, which
#                  is NOT the same as PASS: PASS means the extract itself is clean, DONE means
#                  a person said they would handle it. Nothing here changes an SAP system, and
#                  a DONE check goes back to failing the moment the data is re-extracted and
#                  still broken - because DONE is only ever an overlay on the real result.

function Get-CviGroupingOptions {
    param($Data, [switch]$OneTimeOnly)
    $opts = @()
    foreach ($g in $Data.BpGrouping) {
        $key = Get-CviText $g.GROUPING
        if ($key -eq '') { continue }
        if ($OneTimeOnly -and (Get-CviText $g.ONE_TIME) -ne 'X') { continue }
        $opts += [pscustomobject]@{ Value = $key; Label = "$key - $(Get-CviText $g.TEXT)" }
    }
    return @($opts)
}

function Get-CviTitleOptions {
    param($Data)
    $opts = @()
    foreach ($t in $Data.Titles) {
        $key = Get-CviText $t.TITLE
        if ($key -eq '') { continue }
        $opts += [pscustomobject]@{ Value = $key; Label = "$key - $(Get-CviText $t.TEXT)" }
    }
    return @($opts)
}

function New-CviOptionSet {
    param([string[]]$Pairs)
    # 'VALUE|Label shown in the dropdown'
    $opts = @()
    foreach ($p in $Pairs) {
        $bits = $p -split '\|', 2
        $opts += [pscustomobject]@{ Value = $bits[0]; Label = $(if ($bits.Count -gt 1) { $bits[1] } else { $bits[0] }) }
    }
    return @($opts)
}

function Get-CviDecisionOptions {
    # The choices offered for one affected object. Where the extract holds the set of valid
    # values - BP groupings, BP titles - the dropdown is built from it, so it can never offer
    # a value the target system would reject. Where no such table exists (a region, a postal
    # code, a tax number) there is no list to build and the row takes a typed value instead:
    # inventing a list of plausible-looking values would be worse than asking.
    param($Data, $Check, $Evidence)

    switch ($Check.Id) {
        'CFG-01' { return Get-CviGroupingOptions -Data $Data }
        'CFG-02' { return Get-CviGroupingOptions -Data $Data }
        'CFG-07' {
            $oneTime = Get-CviGroupingOptions -Data $Data -OneTimeOnly
            if ($oneTime.Count -gt 0) { return $oneTime }
            # Nothing in TB001 is flagged one-time, so the only honest choice is to make one.
            return New-CviOptionSet @('CREATE_ONE_TIME_GROUPING|Create a one-time BP grouping first')
        }
        'AI-03'  { return Get-CviGroupingOptions -Data $Data }
        'AI-04'  { return Get-CviGroupingOptions -Data $Data }
        'MD-07'  { return Get-CviTitleOptions -Data $Data }

        'CFG-05' { return New-CviOptionSet @(
            'LINK_ONE_BP|One legal entity - link both roles to a single BP',
            'MOVE_VENDOR|Unrelated - move the vendor onto its own external range',
            'MOVE_CUSTOMER|Unrelated - move the customer onto its own external range') }

        'CFG-06' { return New-CviOptionSet @(
            'ADD_INTERVAL|Add an interval that covers this number',
            'EDIT_INTERVAL|Edit the existing interval',
            'KEEP|Keep as it is') }

        'CFG-10' { return New-CviOptionSet @(
            'MAP_TAX_CATEGORIES|Maintain the tax number categories before the run',
            'DESCOPE_TAX_NUMBERS|Descope tax numbers from the conversion') }

        'CFG-11' { return New-CviOptionSet @(
            'DEACTIVATE_FOR_RUN|Switch the duplicate check off for the mass run',
            'LEAVE_ACTIVE|Leave it on and accept the runtime') }

        'MD-01'  { return New-CviOptionSet @(
            'RECREATE_ADDRESS|Recreate the missing ADRC entry',
            'REPOINT_ADDRESS|Repoint the record at an existing address',
            'EXCLUDE_RECORD|Exclude the record from the conversion') }

        'MD-10'  { return New-CviOptionSet @(
            'EXCLUDE|Archive rather than convert',
            'CONVERT_ANYWAY|Convert it - the deletion flag is wrong') }

        'MD-11'  { return New-CviOptionSet @(
            'COMPLETE_RECORD|Complete the contact person record',
            'DESCOPE_CONTACTS|Descope contact person synchronisation') }

        'MD-12'  { return New-CviOptionSet @(
            'SOURCE_LEADING|The customer/vendor record is leading - re-synchronise',
            'BP_LEADING|The business partner is leading - correct the source') }

        'AI-01'  { return New-CviOptionSet @(
            'ONE_BP_TWO_ROLES|Confirmed one entity - one BP carrying both roles',
            'KEEP_SEPARATE|Not the same entity - convert as two BPs',
            'REVIEW|Send to a data owner to decide') }

        'AI-02'  { return New-CviOptionSet @(
            'KEEP_THIS|This record survives',
            'EXCLUDE_THIS|This record is the duplicate - exclude it',
            'REVIEW|Send to a data owner to decide') }

        'NOTE-01' { return New-CviOptionSet @(
            'IMPLEMENTED|Implemented in the system',
            'NOT_IMPLEMENTED|Still outstanding') }
    }

    # MD-03 region, MD-04 postal code, MD-06 search term, MD-08 language, MD-09 tax number:
    # the correct value is a value, not a choice from a list the extract happens to carry.
    if (@('MD-03', 'MD-04', 'MD-06', 'MD-08', 'MD-09') -contains $Check.Id) { return @() }

    return New-CviOptionSet @(
        'CORRECT|Correct it before the run',
        'EXCLUDE|Take it out of scope',
        'ACCEPT|Accept as it is')
}

function Get-CviDecisionKey {
    param([string]$CheckId, $Evidence)
    return ('{0}|{1}|{2}' -f $CheckId, (Get-CviText $Evidence.Key), (Get-CviText $Evidence.Field))
}

function Add-CviDecisionState {
    # Lays the stored choices and the DONE records over the checks the rules just produced.
    # The rules never see any of this: re-extract the data and the underlying result is
    # unchanged, which is what keeps a recorded decision from masking a real regression.
    param($Data, [object[]]$Checks)

    foreach ($check in $Checks) {
        foreach ($e in $check.Evidence) {
            $e.Options = @(Get-CviDecisionOptions -Data $Data -Check $check -Evidence $e)
            $k = Get-CviDecisionKey -CheckId $check.Id -Evidence $e
            if ($Data.DecisionMap.ContainsKey($k)) {
                $e.Choice = Get-CviText $Data.DecisionMap[$k].CHOICE
            }
        }

        if ($Data.CheckStatusMap.ContainsKey($check.Id)) {
            $row = $Data.CheckStatusMap[$check.Id]
            if ((Get-CviText $row.STATUS) -eq 'DONE') {
                # A check that already passes on the data is left alone: marking a passing
                # check 'done' would quietly downgrade a real pass into a claim.
                if ($check.Status -eq 'FAIL') {
                    $check.Status     = 'DONE'
                    $check.RecordedBy = Get-CviText $row.RECORDED_BY
                    $check.RecordedAt = Get-CviText $row.RECORDED_AT
                    $check.Summary    = "Recorded as done by $($check.RecordedBy) on $($check.RecordedAt). $($check.Count) object(s) were still failing when it was recorded - the data has not been re-extracted since."
                }
            }
        }
    }
    return @($Checks)
}

# ---------------------------------------------------------------- persistence

function Save-CviDecisions {
    # One row per affected object, merged into data\config\CVI_DECISIONS.csv.
    param([string]$Root, [string]$CheckId, [object[]]$Decisions)

    $path = Join-Path $Root 'data\config\CVI_DECISIONS.csv'
    $existing = [ordered]@{}
    if (Test-Path -LiteralPath $path) {
        foreach ($row in @(Import-Csv -LiteralPath $path)) {
            $k = '{0}|{1}|{2}' -f (Get-CviText $row.CHECK_ID), (Get-CviText $row.OBJECT_KEY), (Get-CviText $row.FIELD)
            $existing[$k] = $row
        }
    }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $by = Get-CviText $env:USERNAME
    if ($by -eq '') { $by = 'unknown' }

    foreach ($d in $Decisions) {
        $check = Get-CviText $d.checkId
        if ($check -eq '') { $check = $CheckId }
        if ($check -eq '') { throw 'A check id is required.' }
        $key = Get-CviText $d.key
        $field = Get-CviText $d.field
        $choice = Get-CviText $d.choice
        $k = '{0}|{1}|{2}' -f $check, $key, $field
        # Clearing a dropdown back to blank removes the decision rather than storing an
        # empty one, so 'no decision yet' and 'decided nothing' stay distinguishable.
        if ($choice -eq '') { $null = $existing.Remove($k); continue }
        $existing[$k] = [pscustomobject]@{
            CHECK_ID   = $check
            OBJECT_KEY = $key
            FIELD      = $field
            CHOICE     = $choice
            DECIDED_BY = $by
            DECIDED_AT = $stamp
        }
    }

    $rows = @($existing.Values)
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    } else {
        'CHECK_ID,OBJECT_KEY,FIELD,CHOICE,DECIDED_BY,DECIDED_AT' | Out-File -LiteralPath $path -Encoding utf8
    }
    return $rows.Count
}

function Save-CviCheckDone {
    param([string]$Root, [string]$CheckId, [int]$Rows)

    $id = Get-CviText $CheckId
    if ($id -eq '' -or $id -eq 'ALL' -or $id -eq 'NUMBERS') { throw "'$CheckId' is not a single check." }

    $path = Join-Path $Root 'data\config\CVI_CHECK_STATUS.csv'
    $existing = [ordered]@{}
    if (Test-Path -LiteralPath $path) {
        foreach ($row in @(Import-Csv -LiteralPath $path)) {
            $k = Get-CviText $row.CHECK_ID
            if ($k -ne '') { $existing[$k] = $row }
        }
    }
    $by = Get-CviText $env:USERNAME
    if ($by -eq '') { $by = 'unknown' }
    $existing[$id] = [pscustomobject]@{
        CHECK_ID    = $id
        STATUS      = 'DONE'
        RECORDED_BY = $by
        RECORDED_AT = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ROWS        = $Rows
    }
    @($existing.Values) | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    return $existing.Count
}

function Remove-CviCheckDone {
    param([string]$Root, [string]$CheckId)

    $path = Join-Path $Root 'data\config\CVI_CHECK_STATUS.csv'
    $rows = @()
    if (Test-Path -LiteralPath $path) {
        $rows = @(Import-Csv -LiteralPath $path | Where-Object { (Get-CviText $_.CHECK_ID) -ne (Get-CviText $CheckId) })
    }
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    } else {
        'CHECK_ID,STATUS,RECORDED_BY,RECORDED_AT,ROWS' | Out-File -LiteralPath $path -Encoding utf8
    }
    return $rows.Count
}
