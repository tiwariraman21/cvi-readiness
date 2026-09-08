# Cvi.Chat.ps1 - the assistant behind the chat panel.
#
# Same arrangement as the judgment layer: Claude answers when ANTHROPIC_API_KEY is set,
# and a local answerer takes over when it is not. The local one is not a language model -
# it matches the question against the report and reads real findings back. It says so, so
# nobody mistakes a lookup for an opinion.
#
# Both answer strictly from the report that is loaded. Neither invents SAP behaviour, and
# neither has a connection to a live system.

function Get-CviChatContext {
    # A compact digest of the loaded report - what the model is allowed to answer from.
    param($Report)

    $c = $Report.Counts
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add("SYSTEM: $($Report.SystemId)/$($Report.Client), $($Report.SourceRelease) to $($Report.TargetRelease), number strategy $($Report.Strategy).")
    $null = $lines.Add("READINESS: score $($Report.Score)/100 (share of weighted checks passed), gate '$($Report.Gate)'. Analysed $($Report.GeneratedAt).")
    $null = $lines.Add("COUNTS: $($c.Blocker) blocker, $($c.High) high, $($c.Medium) medium, $($c.Low) low; $($c.Passed) of $($c.Checks) checks passed; $($c.Affected) objects affected.")
    $null = $lines.Add("SCOPE: $($c.Customers) customers, $($c.Vendors) vendors, $($c.Contacts) contact persons, $($c.AccountGroups) account groups, $($c.Groupings) BP groupings.")
    $null = $lines.Add('')
    $null = $lines.Add('FAILING CHECKS')

    foreach ($check in $Report.Checks) {
        if ($check.Status -ne 'FAIL') { continue }
        $null = $lines.Add("[$($check.Severity)] $($check.Id) - $($check.Title) ($($check.Category), $($check.Layer) layer, $($check.Count) object(s))")
        $null = $lines.Add("  finding: $($check.Summary)")
        $null = $lines.Add("  why: $($check.Why)")
        $null = $lines.Add("  fix: $($check.Fix)")
        $null = $lines.Add("  where: $($check.ImgPath)")
        $shown = 0
        foreach ($e in $check.Evidence) {
            if ($shown -ge 6) { break }
            $null = $lines.Add("  evidence: $($e.Object) $($e.Key) $($e.Field) $($e.Value) - $($e.Detail)")
            $shown++
        }
        if ($check.Count -gt $shown) { $null = $lines.Add("  (and $($check.Count - $shown) more of the same)") }
    }

    $passed = @($Report.Checks | Where-Object { $_.Status -eq 'PASS' } | ForEach-Object { "$($_.Id) $($_.Title)" })
    $null = $lines.Add('')
    $null = $lines.Add("PASSING CHECKS: $($passed -join '; ')")

    $plan = $Report.NumberPlan
    if ($plan) {
        $null = $lines.Add('')
        $null = $lines.Add("NUMBER RANGES: $($plan.Counts.SourceRanges) ECC intervals ($($plan.Counts.SourceIssues) flagged), $($plan.Counts.BpRanges) BP intervals ($($plan.Counts.BpIssues) unusable), $($plan.Counts.Changes) of $($plan.Counts.Proposals) proposed intervals need a change.")
        foreach ($p in $plan.Proposals) {
            $part = ''
            if ($p.Part -ne '') { $part = " (interval $($p.Part))" }
            $null = $lines.Add("  $($p.Grouping)$part sources=$($p.AccountGroups) records=$($p.Records) current=$($p.CurrentRange) proposed=$($p.RangeNo): $($p.From)-$($p.To) action=$($p.Action). $($p.Rationale)")
        }
        foreach ($col in $plan.Collisions) {
            $null = $lines.Add("  COLLISION $($col.Number): $($col.Names) (grouping $($col.Groupings))")
        }
        foreach ($o in $plan.Overlaps) {
            $null = $lines.Add("  OVERLAP $($o.Left) with $($o.Right)")
        }
    }

    return ($lines -join [Environment]::NewLine)
}

# ---------------------------------------------------------------- Claude

function Invoke-CviChatClaude {
    param($Report, [string]$Message, [object[]]$History, [string]$ApiKey, [string]$Model = 'claude-opus-5')

    $context = Get-CviChatContext -Report $Report
    $system = @"
You are an assistant inside a CVI (Customer/Vendor Integration) readiness tool used ahead of
an ECC to S/4HANA conversion. A consultant is asking about the report below.

Rules:
- Answer only from the report. If it does not contain the answer, say so and say what would.
- Name the check IDs (CFG-01, MD-03, AI-02, NOTE-01) and the affected keys when they apply.
- Be concrete and short. A few sentences or a short list, not an essay.
- You cannot see or change the SAP system, and you cannot run the tool. Do not imply otherwise.
- The SAP Note catalog in this tool is an unverified seed. Never state what a note says;
  say it must be confirmed in SAP ONE Support.
- Plain text with '- ' bullets. No markdown headings, no tables, no code fences.

REPORT
$context
"@

    $messages = @()
    foreach ($h in $History) {
        $role = [string]$h.role
        if ($role -ne 'user' -and $role -ne 'assistant') { continue }
        $messages += @{ role = $role; content = [string]$h.content }
    }
    $messages += @{ role = 'user'; content = $Message }

    $body = [ordered]@{
        model      = $Model
        max_tokens = 4000
        system     = $system
        messages   = $messages
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
    if ($text -eq '') { throw 'Empty response.' }
    return $text
}

# ---------------------------------------------------------------- local answerer

function Format-CviCheckAnswer {
    param($Check, [int]$MaxEvidence = 6)
    $lines = @()
    $lines += "$($Check.Id) - $($Check.Title) [$($Check.Severity), $($Check.Status)]"
    $lines += $Check.Summary
    $lines += ''
    $lines += "Why it matters: $($Check.Why)"
    $lines += "What to do: $($Check.Fix)"
    $lines += "Where: $($Check.ImgPath)"
    if ($Check.Evidence.Count -gt 0) {
        $lines += ''
        $lines += 'Affected:'
        $shown = 0
        foreach ($e in $Check.Evidence) {
            if ($shown -ge $MaxEvidence) { break }
            $bits = @($e.Object, $e.Key, $e.Field, $e.Value) | Where-Object { $_ -ne '' }
            $lines += "- $($bits -join ' ') : $($e.Detail)"
            $shown++
        }
        if ($Check.Count -gt $shown) { $lines += "- ...and $($Check.Count - $shown) more" }
    }
    return ($lines -join [Environment]::NewLine)
}

function Invoke-CviChatLocal {
    param($Report, [string]$Message)

    $q = $Message.ToUpperInvariant()
    $refs = @()
    $failing = @($Report.Checks | Where-Object { $_.Status -eq 'FAIL' })
    $plan = $Report.NumberPlan

    # A check named directly wins over everything else.
    $idMatches = [regex]::Matches($q, '(CFG|MD|AI|NOTE)-\s?0*(\d+)')
    if ($idMatches.Count -gt 0) {
        $parts = @()
        foreach ($m in $idMatches) {
            $id = "$($m.Groups[1].Value)-$('{0:D2}' -f [int]$m.Groups[2].Value)"
            $check = $Report.Checks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if ($check) {
                $refs += $check.Id
                $parts += Format-CviCheckAnswer -Check $check
            } else {
                $parts += "There is no check $id in this report."
            }
        }
        return @{ Answer = ($parts -join ([Environment]::NewLine + [Environment]::NewLine)); Refs = $refs }
    }

    # A record key named directly - find every finding it appears in.
    $keyMatch = [regex]::Match($Message, '\b\d{6,10}\b')
    if ($keyMatch.Success) {
        $key = $keyMatch.Value.PadLeft(10, '0')
        $hits = @()
        foreach ($check in $Report.Checks) {
            foreach ($e in $check.Evidence) {
                if ($e.Key -eq $key -or $e.Key -eq $keyMatch.Value -or $e.Detail -like "*$key*") {
                    $hits += "- $($check.Id) [$($check.Severity)] $($check.Title): $($e.Detail)"
                    if ($refs -notcontains $check.Id) { $refs += $check.Id }
                    break
                }
            }
        }
        if ($hits.Count -gt 0) {
            $answer = "$key appears in $($hits.Count) finding(s):" + [Environment]::NewLine + ($hits -join [Environment]::NewLine)
            return @{ Answer = $answer; Refs = $refs }
        }
        return @{ Answer = "$key does not appear in any finding. Either it is clean, or it is not in the extract under .\data."; Refs = @() }
    }

    $has = { param($words) foreach ($w in $words) { if ($q -like "*$w*") { return $true } } return $false }

    # Priority / where to start.
    if ((& $has @('FIRST','PRIORIT','START','ORDER','NEXT STEP','WHAT SHOULD','WHERE DO I','PLAN'))) {
        $blockers = @($failing | Where-Object { $_.Severity -eq 'BLOCKER' })
        $highs = @($failing | Where-Object { $_.Severity -eq 'HIGH' })
        $lines = @("The gate is '$($Report.Gate)' at $($Report.Score)/100, so the order is fixed by severity.")
        $lines += ''
        $lines += "Clear these $($blockers.Count) blocker(s) before the mass run - nothing else matters until they are done:"
        foreach ($b in $blockers) { $lines += "- $($b.Id) $($b.Title) ($($b.Count) object(s))"; $refs += $b.Id }
        $lines += ''
        $lines += "Then the $($highs.Count) high finding(s), which fail records or lose data rather than stopping the run:"
        foreach ($h in $highs) { $lines += "- $($h.Id) $($h.Title) ($($h.Count) object(s))"; $refs += $h.Id }
        $lines += ''
        $lines += 'The medium and low findings are post-processing volume - they are worth clearing before go-live, not before the run.'
        return @{ Answer = ($lines -join [Environment]::NewLine); Refs = $refs }
    }

    # Number ranges.
    if ((& $has @('NUMBER RANGE','NUMBER-RANGE','INTERVAL','NRIV','SNRO','RANGE','NUMBERING'))) {
        if (-not $plan) { return @{ Answer = 'This report has no number range plan.'; Refs = @() } }
        $lines = @("$($plan.Counts.SourceRanges) ECC intervals were checked ($($plan.Counts.SourceIssues) flagged) and $($plan.Counts.BpRanges) BP intervals ($($plan.Counts.BpIssues) unusable as they stand). $($plan.Counts.Changes) of $($plan.Counts.Proposals) proposed intervals need a change.")
        $lines += ''
        foreach ($p in ($plan.Proposals | Where-Object { $_.Action -ne 'KEEP' })) {
            $part = ''
            if ($p.Part -ne '') { $part = " (interval $($p.Part))" }
            $lines += "- $($p.Grouping)$part -> $($p.RangeNo): $($p.From)-$($p.To) [$($p.Action)]"
        }
        if ($plan.Collisions.Count -gt 0) {
            $lines += ''
            $lines += "$($plan.Collisions.Count) number(s) are claimed by both a customer and a vendor:"
            foreach ($col in $plan.Collisions) { $lines += "- $($col.Number): $($col.Names)" }
        }
        if ($plan.Overlaps.Count -gt 0) {
            $lines += ''
            $lines += "$($plan.Overlaps.Count) proposed interval(s) overlap:"
            foreach ($o in $plan.Overlaps) { $lines += "- $($o.Left) overlaps $($o.Right)" }
        }
        $lines += ''
        $lines += 'The full proposal with rationale is on the Number ranges page.'
        return @{ Answer = ($lines -join [Environment]::NewLine); Refs = @('CFG-05','CFG-06') }
    }

    # Score and gate.
    if ((& $has @('SCORE','READY','GATE','HOW BAD','SUMMAR','OVERVIEW','STATUS'))) {
        $c = $Report.Counts
        $lines = @("$($Report.SystemId)/$($Report.Client) scores $($Report.Score)/100 and the gate is '$($Report.Gate)'.")
        $lines += "The score is the share of the weighted checks that passed - blocker 14, high 7, medium 3, low 1 - not a deduction from 100."
        $lines += ''
        $lines += "- $($c.Blocker) blocker, $($c.High) high, $($c.Medium) medium, $($c.Low) low"
        $lines += "- $($c.Passed) of $($c.Checks) checks passed"
        $lines += "- $($c.Affected) object(s) need attention across $($c.Failed) failing check(s)"
        $lines += "- scope: $($c.Customers) customers, $($c.Vendors) vendors, $($c.Contacts) contact persons"
        $lines += ''
        $lines += "Any blocker at all means NOT READY, regardless of the score."
        return @{ Answer = ($lines -join [Environment]::NewLine); Refs = @() }
    }

    # Topic shortcuts - each maps to the checks that own that topic.
    $topics = @(
        @{ Words = @('DUPLICATE','MERGE','SAME COMPANY','ONE LEGAL','TWICE'); Ids = @('AI-01','AI-02') },
        @{ Words = @('PERSON','EMPLOYEE','NATURAL PERSON','INDIVIDUAL'); Ids = @('AI-03') },
        @{ Words = @('MAPPING','GROUPING','ACCOUNT GROUP'); Ids = @('CFG-01','CFG-02','AI-04') },
        @{ Words = @('NOTE','SNOTE','LAUNCHPAD','OSS'); Ids = @('NOTE-01') },
        @{ Words = @('ADDRESS','REGION','POSTAL','POST CODE','COUNTRY','ADRC'); Ids = @('MD-01','MD-02','MD-03','MD-04') },
        @{ Words = @('TAX','GSTIN','VAT','STCD1','EIN'); Ids = @('MD-09','CFG-10') },
        @{ Words = @('ONE-TIME','ONE TIME','CPD'); Ids = @('CFG-07') },
        @{ Words = @('CONTACT','KNVK','PARTNER FUNCTION'); Ids = @('MD-11') },
        @{ Words = @('PPO','POST-PROCESSING','POST PROCESSING','MDS_PPO'); Ids = @('CFG-12') },
        @{ Words = @('COLLISION','OVERLAP','SAME NUMBER'); Ids = @('CFG-05') },
        @{ Words = @('DELET','ARCHIV','LOEVM'); Ids = @('MD-10') },
        @{ Words = @('DRIFT','ALREADY CONVERTED','TRIAL RUN','LINKED'); Ids = @('MD-12') },
        @{ Words = @('NAME','SEARCH TERM','SORTL','LANGUAGE','TITLE','ANRED'); Ids = @('MD-05','MD-06','MD-07','MD-08') },
        @{ Words = @('DUPLICATE CHECK','PERFORMANCE','SLOW','RUNTIME'); Ids = @('CFG-11') }
    )
    foreach ($t in $topics) {
        if (& $has $t.Words) {
            $parts = @()
            foreach ($id in $t.Ids) {
                $check = $Report.Checks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
                if (-not $check) { continue }
                $refs += $id
                if ($check.Status -eq 'PASS') {
                    $parts += "$($check.Id) - $($check.Title): passed. $($check.Summary)"
                } else {
                    $parts += Format-CviCheckAnswer -Check $check -MaxEvidence 4
                }
            }
            if ($parts.Count -gt 0) {
                return @{ Answer = ($parts -join ([Environment]::NewLine + [Environment]::NewLine)); Refs = $refs }
            }
        }
    }

    # What passed.
    if ((& $has @('PASS','CLEAN','OK','GOOD','FINE'))) {
        $passed = @($Report.Checks | Where-Object { $_.Status -eq 'PASS' })
        $lines = @("$($passed.Count) check(s) passed:")
        foreach ($p in $passed) { $lines += "- $($p.Id) $($p.Title): $($p.Summary)" }
        return @{ Answer = ($lines -join [Environment]::NewLine); Refs = @() }
    }

    # Fall back to the worst findings plus a nudge about what can be asked.
    $lines = @("I could not match that to the report. The local answerer looks things up rather than reasoning about them - set ANTHROPIC_API_KEY and restart to get Claude answering instead.")
    $lines += ''
    $lines += 'The heaviest findings right now:'
    foreach ($f in ($failing | Select-Object -First 5)) {
        $lines += "- $($f.Id) [$($f.Severity)] $($f.Title) - $($f.Count) object(s)"
        $refs += $f.Id
    }
    $lines += ''
    $lines += 'Try: "what should I fix first", "explain CFG-06", "what is wrong with 0000100004", "number ranges", "duplicates", "SAP notes", "what passed".'
    return @{ Answer = ($lines -join [Environment]::NewLine); Refs = $refs }
}

function Invoke-CviChat {
    param($Report, [string]$Message, [object[]]$History, [switch]$ForceLocal)

    $message = ([string]$Message).Trim()
    if ($message -eq '') { return [pscustomobject]@{ Answer = 'Ask me something about this report.'; Mode = 'local'; Refs = @() } }
    if ($message.Length -gt 4000) { $message = $message.Substring(0, 4000) }

    $key = $env:ANTHROPIC_API_KEY
    if (-not $ForceLocal -and $key) {
        try {
            $answer = Invoke-CviChatClaude -Report $Report -Message $message -History $History -ApiKey $key
            return [pscustomobject]@{ Answer = $answer; Mode = 'claude-opus-5'; Refs = @() }
        } catch {
            $local = Invoke-CviChatLocal -Report $Report -Message $message
            return [pscustomobject]@{
                Answer = "The Claude call failed ($($_.Exception.Message)), so this is the local answerer:" + [Environment]::NewLine + [Environment]::NewLine + $local.Answer
                Mode   = 'local (Claude unavailable)'
                Refs   = @($local.Refs)
            }
        }
    }

    $local = Invoke-CviChatLocal -Report $Report -Message $message
    return [pscustomobject]@{ Answer = $local.Answer; Mode = 'local answerer'; Refs = @($local.Refs) }
}
