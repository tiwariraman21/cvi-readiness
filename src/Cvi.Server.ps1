# Cvi.Server.ps1 - a small loopback HTTP server built on TcpListener.
# TcpListener is used rather than HttpListener because binding a loopback socket needs no
# URL ACL registration and therefore no elevated shell.

function Get-CviMimeType {
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css'  { return 'text/css; charset=utf-8' }
        '.js'   { return 'application/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.csv'  { return 'text/csv; charset=utf-8' }
        '.md'   { return 'text/markdown; charset=utf-8' }
        default { return 'application/octet-stream' }
    }
}

function Write-CviResponse {
    param($Stream, [int]$Status, [string]$ContentType, [byte[]]$Body, [hashtable]$ExtraHeaders)
    $reason = @{ 200 = 'OK'; 400 = 'Bad Request'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 500 = 'Internal Server Error' }[$Status]
    if (-not $reason) { $reason = 'OK' }
    if (-not $Body) { $Body = New-Object byte[] 0 }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("HTTP/1.1 $Status $reason")
    $null = $sb.AppendLine("Content-Type: $ContentType")
    $null = $sb.AppendLine("Content-Length: $($Body.Length)")
    $null = $sb.AppendLine('Cache-Control: no-store')
    $null = $sb.AppendLine('Connection: close')
    if ($ExtraHeaders) {
        foreach ($k in $ExtraHeaders.Keys) { $null = $sb.AppendLine("$k`: $($ExtraHeaders[$k])") }
    }
    $null = $sb.AppendLine()
    $head = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Stream.Write($head, 0, $head.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Write-CviJson {
    param($Stream, $Object, [int]$Status = 200)
    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    Write-CviResponse -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
}

function Read-CviRequest {
    param($Stream)
    $buffer = New-Object byte[] 16384
    $ms = New-Object System.IO.MemoryStream
    $headerText = ''
    $headerEnd = -1
    while ($true) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $ms.Write($buffer, 0, $read)
        $headerText = [Text.Encoding]::ASCII.GetString($ms.ToArray())
        $headerEnd = $headerText.IndexOf("`r`n`r`n")
        if ($headerEnd -ge 0) { break }
        if ($ms.Length -gt 262144) { break }
    }
    if ($headerEnd -lt 0) { return $null }

    $raw = $ms.ToArray()
    $head = $headerText.Substring(0, $headerEnd)
    $lines = $head -split "`r`n"
    $parts = $lines[0] -split ' '
    if ($parts.Count -lt 2) { return $null }

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $idx = $lines[$i].IndexOf(':')
        if ($idx -gt 0) { $headers[$lines[$i].Substring(0, $idx).Trim().ToLowerInvariant()] = $lines[$i].Substring($idx + 1).Trim() }
    }

    $bodyStart = $headerEnd + 4
    $body = ''
    $len = 0
    if ($headers.ContainsKey('content-length')) { [void][int]::TryParse($headers['content-length'], [ref]$len) }
    if ($len -gt 0) {
        $have = $raw.Length - $bodyStart
        $bodyBytes = New-Object byte[] $len
        $copy = [math]::Min($have, $len)
        if ($copy -gt 0) { [Array]::Copy($raw, $bodyStart, $bodyBytes, 0, $copy) }
        $offset = $copy
        while ($offset -lt $len) {
            $read = $Stream.Read($bodyBytes, $offset, $len - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
        $body = [Text.Encoding]::UTF8.GetString($bodyBytes)
    }

    $target = $parts[1]
    $path = $target
    $query = @{}
    $qIdx = $target.IndexOf('?')
    if ($qIdx -ge 0) {
        $path = $target.Substring(0, $qIdx)
        foreach ($pair in ($target.Substring($qIdx + 1) -split '&')) {
            if ($pair -eq '') { continue }
            $kv = $pair -split '=', 2
            $k = [Uri]::UnescapeDataString($kv[0])
            $v = ''
            if ($kv.Count -gt 1) { $v = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
            $query[$k] = $v
        }
    }

    return [pscustomobject]@{
        Method  = $parts[0].ToUpperInvariant()
        Path    = $path
        Query   = $query
        Headers = $headers
        Body    = $body
    }
}

function Write-CviLog {
    param([string]$OutDir, [string]$Message)
    try {
        $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath (Join-Path $OutDir 'server.log') -Value $line -Encoding UTF8
    } catch { }
}

function Start-CviServer {
    param([string]$Root, [int]$Port = 8787, [switch]$ForceLocalJudge, [switch]$NoBrowser)

    $webDir = Join-Path $Root 'web'
    $outDir = Join-Path $Root 'out'
    if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }

    Write-Host 'Running the first analysis...' -ForegroundColor Cyan
    $report = Invoke-CviAnalysis -Root $Root -ForceLocalJudge:$ForceLocalJudge

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
    } catch {
        throw "Could not bind port $Port : $($_.Exception.Message)"
    }

    $url = "http://localhost:$Port/"
    Write-Host ''
    Write-Host "  CVI Readiness Analyzer is running at $url" -ForegroundColor Green
    Write-Host "  Score $($report.Score)/100 - $($report.Gate) - judgment layer: $($report.AiMode)"
    Write-Host '  Press Ctrl+C in this window to stop.' -ForegroundColor DarkGray
    Write-Host ''
    if (-not $NoBrowser) { Start-Process $url | Out-Null }

    Write-CviLog $outDir "server started on port $Port"

    $running = $true
    while ($running) {
        $client = $null
        try {
            # Nothing a single request does may take the server down - a stopped server looks
            # to the user like buttons that quietly do nothing.
            $client = $listener.AcceptTcpClient()
            $client.ReceiveTimeout = 15000
            $client.SendTimeout = 15000
            $stream = $client.GetStream()
            $req = Read-CviRequest -Stream $stream
            if (-not $req) { continue }

            switch -Regex ($req.Path) {

                '^/$|^/index\.html$' {
                    $file = Join-Path $webDir 'index.html'
                    Write-CviResponse -Stream $stream -Status 200 -ContentType 'text/html; charset=utf-8' -Body ([IO.File]::ReadAllBytes($file))
                    break
                }

                '^/numbers$|^/numbers\.html$' {
                    $file = Join-Path $webDir 'numbers.html'
                    Write-CviResponse -Stream $stream -Status 200 -ContentType 'text/html; charset=utf-8' -Body ([IO.File]::ReadAllBytes($file))
                    break
                }

                '^/(app\.js|numbers\.js|chat\.js|styles\.css)$' {
                    $name = $req.Path.TrimStart('/')
                    $file = Join-Path $webDir $name
                    if (Test-Path -LiteralPath $file) {
                        Write-CviResponse -Stream $stream -Status 200 -ContentType (Get-CviMimeType $file) -Body ([IO.File]::ReadAllBytes($file))
                    } else {
                        Write-CviResponse -Stream $stream -Status 404 -ContentType 'text/plain' -Body ([Text.Encoding]::UTF8.GetBytes('not found'))
                    }
                    break
                }

                '^/api/report$' {
                    Write-CviJson -Stream $stream -Object $report
                    break
                }

                '^/api/analyze$' {
                    Write-Host ("[{0}] re-running analysis" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray
                    $report = Invoke-CviAnalysis -Root $Root -ForceLocalJudge:$ForceLocalJudge
                    Write-CviJson -Stream $stream -Object $report
                    break
                }

                '^/api/fixpack$' {
                    $checkId = ''
                    if ($req.Query.ContainsKey('check')) { $checkId = $req.Query['check'] }
                    try {
                        if ($checkId -eq 'ALL') {
                            $pack = New-CviFullPack -Report $report -OutDir $outDir
                        } elseif ($checkId -eq 'NUMBERS') {
                            $pack = New-CviNumberRangeProposal -Report $report -OutDir $outDir
                        } else {
                            $pack = New-CviFixPack -Report $report -CheckId $checkId -OutDir $outDir
                        }
                        Write-Host ("[{0}] fix pack generated for {1} -> {2} file(s)" -f (Get-Date -Format 'HH:mm:ss'), $checkId, $pack.Files.Count) -ForegroundColor DarkGray
                        Write-CviJson -Stream $stream -Object ([pscustomobject]@{
                            ok      = $true
                            checkId = $pack.CheckId
                            rows    = $pack.Rows
                            files   = @($pack.Files)
                            outDir  = $pack.OutDir
                        })
                    } catch {
                        Write-CviJson -Stream $stream -Status 400 -Object ([pscustomobject]@{ ok = $false; error = $_.Exception.Message })
                    }
                    break
                }

                '^/api/numbers/save$|^/api/numbers/reset$' {
                    if ($req.Method -ne 'POST') {
                        Write-CviResponse -Stream $stream -Status 405 -ContentType 'text/plain' -Body ([Text.Encoding]::UTF8.GetBytes('POST only'))
                        break
                    }
                    try {
                        if ($req.Path -eq '/api/numbers/reset') {
                            $kept = Clear-CviRangeOverrides -Root $Root
                        } else {
                            $payload = $null
                            if ($req.Body -ne '') { $payload = $req.Body | ConvertFrom-Json }
                            $overrides = @()
                            if ($payload -and $payload.overrides) { $overrides = @($payload.overrides) }
                            $kept = Save-CviRangeOverrides -Root $Root -Overrides $overrides
                        }
                        # Re-run so the edited intervals are re-checked like proposed ones.
                        $report = Invoke-CviAnalysis -Root $Root -ForceLocalJudge:$ForceLocalJudge
                        Write-Host ("[{0}] number range edits saved ({1} override rows)" -f (Get-Date -Format 'HH:mm:ss'), $kept) -ForegroundColor DarkGray
                        Write-CviJson -Stream $stream -Object ([pscustomobject]@{ ok = $true; overrides = $kept; report = $report })
                    } catch {
                        Write-CviJson -Stream $stream -Status 400 -Object ([pscustomobject]@{ ok = $false; error = $_.Exception.Message })
                    }
                    break
                }

                '^/api/numbers/send$' {
                    if ($req.Method -ne 'POST') {
                        Write-CviResponse -Stream $stream -Status 405 -ContentType 'text/plain' -Body ([Text.Encoding]::UTF8.GetBytes('POST only'))
                        break
                    }
                    try {
                        $push = $false
                        if ($req.Body -ne '') {
                            $payload = $req.Body | ConvertFrom-Json
                            if ($payload -and $payload.push) { $push = [bool]$payload.push }
                        }
                        $pack = New-CviSystemPackage -Report $report -OutDir $outDir
                        $target = Get-CviTargetSystem -Root $Root
                        $posted = $false
                        $message = "Package written for $($pack.Intervals) confirmed interval(s)."

                        if ($push) {
                            if (-not $pack.Readiness.Ready) {
                                $message = 'Not pushed - the confirmed set did not pass its checks.'
                            } else {
                                $result = Send-CviToSystem -Report $report -Root $Root -PayloadPath $pack.PayloadPath
                                $posted = $result.Posted
                                $message = $result.Message
                                Write-CviLog $outDir "push to target: posted=$posted - $message"
                            }
                        }

                        Write-Host ("[{0}] send package: {1} interval(s), ready={2}, pushed={3}" -f (Get-Date -Format 'HH:mm:ss'), $pack.Intervals, $pack.Readiness.Ready, $posted) -ForegroundColor DarkGray
                        Write-CviJson -Stream $stream -Object ([pscustomobject]@{
                            ok        = $true
                            ready     = $pack.Readiness.Ready
                            blockers  = @($pack.Readiness.Blockers)
                            warnings  = @($pack.Readiness.Warnings)
                            intervals = $pack.Intervals
                            mappings  = $pack.Mappings
                            files     = @($pack.Files)
                            sendDir   = $pack.SendDir
                            posted    = $posted
                            message   = $message
                            target    = [pscustomobject]@{
                                enabled  = $target.Enabled
                                systemId = $target.SystemId
                                baseUrl  = $target.BaseUrl
                                note     = $target.Note
                            }
                        })
                    } catch {
                        Write-CviJson -Stream $stream -Status 400 -Object ([pscustomobject]@{ ok = $false; error = $_.Exception.Message })
                    }
                    break
                }

                '^/api/chat$' {
                    if ($req.Method -ne 'POST') {
                        Write-CviResponse -Stream $stream -Status 405 -ContentType 'text/plain' -Body ([Text.Encoding]::UTF8.GetBytes('POST only'))
                        break
                    }
                    try {
                        $payload = $null
                        if ($req.Body -ne '') { $payload = $req.Body | ConvertFrom-Json }
                        $msg = ''
                        $hist = @()
                        if ($payload) {
                            $msg = [string]$payload.message
                            if ($payload.history) { $hist = @($payload.history) }
                        }
                        $answer = Invoke-CviChat -Report $report -Message $msg -History $hist -ForceLocal:$ForceLocalJudge
                        Write-Host ("[{0}] chat: {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor DarkGray
                        Write-CviJson -Stream $stream -Object ([pscustomobject]@{
                            ok     = $true
                            answer = $answer.Answer
                            mode   = $answer.Mode
                            refs   = @($answer.Refs)
                        })
                    } catch {
                        Write-CviJson -Stream $stream -Status 400 -Object ([pscustomobject]@{ ok = $false; error = $_.Exception.Message })
                    }
                    break
                }

                '^/api/files$' {
                    $items = @()
                    foreach ($f in (Get-ChildItem -LiteralPath $outDir -File | Sort-Object Name)) {
                        $items += [pscustomobject]@{ name = $f.Name; size = $f.Length; modified = $f.LastWriteTime.ToString('HH:mm:ss') }
                    }
                    Write-CviJson -Stream $stream -Object ([pscustomobject]@{ ok = $true; outDir = $outDir; files = @($items) })
                    break
                }

                '^/api/download$' {
                    $name = ''
                    if ($req.Query.ContainsKey('file')) { $name = $req.Query['file'] }
                    # Only plain names, optionally one level down into the send package.
                    if ($name -notmatch '^(send\\)?[A-Za-z0-9_.\-]+$') {
                        Write-CviResponse -Stream $stream -Status 400 -ContentType 'text/plain' -Body ([Text.Encoding]::UTF8.GetBytes('bad file name'))
                        break
                    }
                    $file = Join-Path $outDir $name
                    if (-not (Test-Path -LiteralPath $file)) {
                        Write-CviResponse -Stream $stream -Status 404 -ContentType 'text/plain' -Body ([Text.Encoding]::UTF8.GetBytes('not found'))
                        break
                    }
                    # Served as an attachment so a click saves the worklist instead of
                    # navigating to a page of raw CSV.
                    Write-CviResponse -Stream $stream -Status 200 -ContentType (Get-CviMimeType $file) `
                        -Body ([IO.File]::ReadAllBytes($file)) `
                        -ExtraHeaders @{ 'Content-Disposition' = "attachment; filename=`"$([IO.Path]::GetFileName($name))`"" }
                    break
                }

                '^/api/shutdown$' {
                    Write-CviJson -Stream $stream -Object ([pscustomobject]@{ ok = $true })
                    $running = $false
                    break
                }

                default {
                    Write-CviResponse -Stream $stream -Status 404 -ContentType 'text/plain' -Body ([Text.Encoding]::UTF8.GetBytes('not found'))
                }
            }
        } catch {
            Write-Host "request error: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-CviLog $outDir "request error on $($req.Path): $($_.Exception.Message)"
        } finally {
            if ($client) { try { $client.Close() } catch {} }
        }
    }

    $listener.Stop()
    Write-CviLog $outDir 'server stopped'
    Write-Host 'Server stopped.' -ForegroundColor DarkGray
}
