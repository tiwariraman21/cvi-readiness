# Cvi.Excel.ps1 - writes a real .xlsx workbook with nothing installed.
#
# An xlsx is a zip of XML parts, and .NET can write both, so this builds the package directly
# rather than driving Excel through COM. That keeps the promise the rest of the tool makes -
# Windows PowerShell 5.1 and .NET only - and means the export works on a build agent, on a
# locked-down laptop, and on a machine where Excel was never installed.
#
# Every cell is written as an inline string, never as a number. SAP keys are zero-padded
# (0000100004), and a numeric cell would silently drop the padding and hand back 100004 -
# a key that matches nothing in the system the workbook is meant to be worked against.

function ConvertTo-CviXmlText {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;')
    # Control characters are not legal in XML 1.0 and make Excel declare the file corrupt.
    return ($s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
}

function Get-CviColumnLetter {
    param([int]$Index)   # 1 -> A, 26 -> Z, 27 -> AA
    $letters = ''
    $i = $Index
    while ($i -gt 0) {
        $rem = ($i - 1) % 26
        $letters = [char](65 + $rem) + $letters
        $i = [int](($i - $rem - 1) / 26)
    }
    return $letters
}

function Get-CviSheetName {
    # Excel rejects > 31 characters and the characters below, and silently repairs duplicates.
    param([string]$Name, [hashtable]$Taken)
    $n = ($Name -replace '[\[\]\:\*\?\/\\]', '-')
    if ($n.Length -gt 31) { $n = $n.Substring(0, 31) }
    if ($n -eq '') { $n = 'Sheet' }
    $base = $n; $i = 2
    while ($Taken.ContainsKey($n.ToLowerInvariant())) {
        $suffix = "_$i"
        $n = $base.Substring(0, [math]::Min($base.Length, 31 - $suffix.Length)) + $suffix
        $i++
    }
    $Taken[$n.ToLowerInvariant()] = $true
    return $n
}

function New-CviSheetXml {
    # Rows is an array of string arrays. RowStyles carries the style index per row, so a row
    # that failed a check can be shaded without the caller building XML itself.
    param([object[]]$Rows, [int[]]$RowStyles, [int]$FreezeHeader = 1)

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    $null = $sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')

    if ($FreezeHeader -gt 0) {
        $null = $sb.Append('<sheetViews><sheetView workbookViewId="0">')
        $null = $sb.Append('<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>')
        $null = $sb.Append('</sheetView></sheetViews>')
    }

    # Column widths from the widest value actually present, capped so one long finding text
    # does not push every other column off the screen.
    $widest = @{}
    foreach ($row in $Rows) {
        for ($i = 0; $i -lt $row.Count; $i++) {
            $len = ([string]$row[$i]).Length
            if (-not $widest.ContainsKey($i) -or $len -gt $widest[$i]) { $widest[$i] = $len }
        }
    }
    if ($widest.Count -gt 0) {
        $null = $sb.Append('<cols>')
        foreach ($i in ($widest.Keys | Sort-Object)) {
            $w = [math]::Min([math]::Max($widest[$i] + 2, 9), 60)
            $null = $sb.Append(('<col min="{0}" max="{0}" width="{1}" customWidth="1"/>' -f ($i + 1), $w))
        }
        $null = $sb.Append('</cols>')
    }

    $null = $sb.Append('<sheetData>')
    for ($r = 0; $r -lt $Rows.Count; $r++) {
        $row = $Rows[$r]
        $style = 0
        if ($RowStyles -and $r -lt $RowStyles.Count) { $style = $RowStyles[$r] }
        $null = $sb.Append(('<row r="{0}">' -f ($r + 1)))
        for ($c = 0; $c -lt $row.Count; $c++) {
            $text = ConvertTo-CviXmlText ([string]$row[$c])
            if ($text -eq '') { continue }   # an empty cell needs no element at all
            $ref = (Get-CviColumnLetter ($c + 1)) + ($r + 1)
            $null = $sb.Append(('<c r="{0}" s="{1}" t="inlineStr"><is><t xml:space="preserve">{2}</t></is></c>' -f $ref, $style, $text))
        }
        $null = $sb.Append('</row>')
    }
    $null = $sb.Append('</sheetData>')

    if ($FreezeHeader -gt 0 -and $Rows.Count -gt 1) {
        $lastCol = Get-CviColumnLetter ([math]::Max($Rows[0].Count, 1))
        $null = $sb.Append(('<autoFilter ref="A1:{0}{1}"/>' -f $lastCol, $Rows.Count))
    }
    $null = $sb.Append('</worksheet>')
    return $sb.ToString()
}

function Get-CviStylesXml {
    # 0 plain, 1 header, 2 row carrying a finding, 3 bold label on the summary sheet.
    # Fill 0 must be 'none' and fill 1 must be 'gray125' - Excel assumes both and renumbers
    # everything after them if they are missing.
    return @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="4">
<font><sz val="11"/><name val="Calibri"/></font>
<font><b/><sz val="11"/><name val="Calibri"/><color rgb="FFFFFFFF"/></font>
<font><sz val="11"/><name val="Calibri"/><color rgb="FF7B3A00"/></font>
<font><b/><sz val="11"/><name val="Calibri"/></font>
</fonts>
<fills count="4">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF44546A"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="4">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
<xf numFmtId="0" fontId="2" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>
</cellXfs>
</styleSheet>
'@
}

function New-CviXlsx {
    # Sheets: ordered list of @{ Name = '...'; Rows = @(@('a','b'), ...); RowStyles = @(1,0,...) }
    param([string]$Path, [object[]]$Sheets)

    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

    $taken = @{}
    $names = @()
    foreach ($s in $Sheets) { $names += Get-CviSheetName -Name $s.Name -Taken $taken }

    $ct = New-Object System.Text.StringBuilder
    $null = $ct.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    $null = $ct.Append('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
    $null = $ct.Append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
    $null = $ct.Append('<Default Extension="xml" ContentType="application/xml"/>')
    $null = $ct.Append('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
    $null = $ct.Append('<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')
    for ($i = 1; $i -le $Sheets.Count; $i++) {
        $null = $ct.Append(('<Override PartName="/xl/worksheets/sheet{0}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' -f $i))
    }
    $null = $ct.Append('</Types>')

    $rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
        '</Relationships>'

    $wb = New-Object System.Text.StringBuilder
    $null = $wb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    $null = $wb.Append('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>')
    for ($i = 1; $i -le $Sheets.Count; $i++) {
        $null = $wb.Append(('<sheet name="{0}" sheetId="{1}" r:id="rId{1}"/>' -f (ConvertTo-CviXmlText $names[$i - 1]), $i))
    }
    $null = $wb.Append('</sheets></workbook>')

    $wbRels = New-Object System.Text.StringBuilder
    $null = $wbRels.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    $null = $wbRels.Append('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')
    for ($i = 1; $i -le $Sheets.Count; $i++) {
        $null = $wbRels.Append(('<Relationship Id="rId{0}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{0}.xml"/>' -f $i))
    }
    $null = $wbRels.Append(('<Relationship Id="rId{0}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' -f ($Sheets.Count + 1)))
    $null = $wbRels.Append('</Relationships>')

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM: Excel will not open a part that has one
            function Write-Part($archive, $name, $content) {
                $entry = $archive.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
                $sw = New-Object System.IO.StreamWriter($entry.Open(), $utf8)
                try { $sw.Write($content) } finally { $sw.Dispose() }
            }
            Write-Part $zip '[Content_Types].xml' $ct.ToString()
            Write-Part $zip '_rels/.rels' $rootRels
            Write-Part $zip 'xl/workbook.xml' $wb.ToString()
            Write-Part $zip 'xl/_rels/workbook.xml.rels' $wbRels.ToString()
            Write-Part $zip 'xl/styles.xml' (Get-CviStylesXml)
            for ($i = 1; $i -le $Sheets.Count; $i++) {
                $s = $Sheets[$i - 1]
                $xml = New-CviSheetXml -Rows @($s.Rows) -RowStyles @($s.RowStyles) -FreezeHeader $(if ($s.ContainsKey('FreezeHeader')) { $s.FreezeHeader } else { 1 })
                Write-Part $zip ("xl/worksheets/sheet{0}.xml" -f $i) $xml
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }

    return $Path
}

# ---------------------------------------------------------------- the master data workbook

function New-CviMasterDataWorkbook {
    # One sheet per extracted master data table, with the findings against each record on the
    # record's own row - so the person correcting the data sees the problem next to the field,
    # rather than in a separate list they have to join by hand.
    param([string]$Root, $Report, [string]$OutDir)

    if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }
    $data = Get-CviDataset -Root $Root

    # Findings indexed by the table and key they are about. A record can fail several checks,
    # so every finding is kept rather than the first one winning.
    $byKey = @{}
    foreach ($c in $Report.Checks) {
        if ($c.Status -eq 'PASS' -or $c.Status -eq 'NA') { continue }
        foreach ($e in $c.Evidence) {
            $t = Get-CviText $e.Table
            $k = Get-CviText $e.Key
            if ($t -eq '' -or $k -eq '') { continue }
            $mk = "$t|$k"
            if (-not $byKey.ContainsKey($mk)) { $byKey[$mk] = @() }
            $byKey[$mk] += [pscustomobject]@{
                Check    = $c.Id
                Severity = $c.Severity
                Status   = $c.Status
                Field    = Get-CviText $e.Field
                Detail   = Get-CviText $e.Detail
                Choice   = Get-CviText $e.Choice
            }
        }
    }

    $tables = @(
        @{ Name = 'KNA1';   Key = 'KUNNR';      Rows = $data.Customers;       Title = 'Customer master' },
        @{ Name = 'LFA1';   Key = 'LIFNR';      Rows = $data.Vendors;         Title = 'Vendor master' },
        @{ Name = 'ADRC';   Key = 'ADDRNUMBER'; Rows = $data.Addresses;       Title = 'Addresses' },
        @{ Name = 'KNVK';   Key = 'PARNR';      Rows = $data.Contacts;        Title = 'Contact persons' },
        @{ Name = 'BUT000'; Key = 'PARTNER';    Rows = $data.BusinessPartner; Title = 'Business partners' }
    )

    $sheets = @()
    $stats = @()

    foreach ($t in $tables) {
        $src = @($t.Rows)
        $cols = @()
        if ($src.Count -gt 0) { $cols = @($src[0].PSObject.Properties.Name) }

        $header = @($cols) + @('CHECKS', 'SEVERITY', 'FINDING', 'CHANGE_TO')
        $rows = @(, $header)
        $styles = @(1)
        $flagged = 0

        foreach ($r in $src) {
            $line = @()
            foreach ($col in $cols) { $line += (Get-CviText $r.$col) }
            $key = Get-CviText $r.($t.Key)
            $hits = @()
            if ($byKey.ContainsKey("$($t.Name)|$key")) { $hits = @($byKey["$($t.Name)|$key"]) }

            if ($hits.Count -gt 0) {
                $flagged++
                $line += (($hits | ForEach-Object { $_.Check } | Select-Object -Unique) -join ', ')
                # The worst severity on the row, so a sort puts the blockers at the top.
                $order = @{ 'BLOCKER' = 0; 'HIGH' = 1; 'MEDIUM' = 2; 'LOW' = 3 }
                $worst = ($hits | Sort-Object { $order[$_.Severity] } | Select-Object -First 1).Severity
                $line += $worst
                $line += (($hits | ForEach-Object { "$($_.Check) $($_.Field): $($_.Detail)" }) -join ' | ')
                $line += (($hits | Where-Object { $_.Choice -ne '' } | ForEach-Object { "$($_.Field)=$($_.Choice)" }) -join ' | ')
                $styles += 2
            } else {
                $line += @('', '', '', '')
                $styles += 0
            }
            $rows += , $line
        }

        $sheets += @{ Name = $t.Name; Rows = $rows; RowStyles = $styles }
        $stats += [pscustomobject]@{ Table = $t.Name; Title = $t.Title; Total = $src.Count; Flagged = $flagged }
    }

    # ---- summary sheet, built last so it can report what the data sheets came to
    $c = $Report.Counts
    $sum = @()
    $sumStyles = @()
    $sum += , @('CVI readiness - master data export');                                   $sumStyles += 3
    $sum += , @('');                                                                     $sumStyles += 0
    $sum += , @('System',          "$($Report.SystemId)/$($Report.Client)");              $sumStyles += 0
    $sum += , @('Conversion',      "$($Report.SourceRelease) to $($Report.TargetRelease)"); $sumStyles += 0
    $sum += , @('Number strategy', $Report.Strategy);                                     $sumStyles += 0
    $sum += , @('Analysed',        $Report.GeneratedAt);                                  $sumStyles += 0
    $sum += , @('Judgment layer',  $Report.AiMode);                                       $sumStyles += 0
    $sum += , @('Score',           "$($Report.Score)/100");                               $sumStyles += 0
    $sum += , @('Gate',            $Report.Gate);                                         $sumStyles += 0
    $sum += , @('');                                                                      $sumStyles += 0
    if ($c.Done -gt 0) {
        $sum += , @('Recorded as done', "$($c.Done) check(s) counted in that score are recorded as done by a user, not verified against this extract"); $sumStyles += 2
        $sum += , @('');                                                                  $sumStyles += 0
    }
    $sum += , @('Sheet', 'Contents', 'Records', 'Records with a finding');                $sumStyles += 1
    foreach ($s in $stats) {
        $sum += , @($s.Table, $s.Title, [string]$s.Total, [string]$s.Flagged);            $sumStyles += 0
    }
    $sum += , @('');                                                                      $sumStyles += 0
    $sum += , @('Check', 'Title', 'Category', 'Severity', 'Status', 'Objects', 'Recorded by', 'Recorded at'); $sumStyles += 1
    foreach ($chk in $Report.Checks) {
        if ($chk.Status -eq 'NA') { continue }
        $sum += , @($chk.Id, $chk.Title, $chk.Category, $chk.Severity, $chk.Status, [string]$chk.Count, [string]$chk.RecordedBy, [string]$chk.RecordedAt)
        $sumStyles += $(if ($chk.Status -eq 'FAIL' -or $chk.Status -eq 'DONE') { 2 } else { 0 })
    }

    # The summary is a report, not a table: an autofilter over mixed blocks reads as a bug.
    $sheets = @(@{ Name = 'Summary'; Rows = $sum; RowStyles = $sumStyles; FreezeHeader = 0 }) + $sheets

    $path = Join-Path $OutDir 'CVI_MASTER_DATA.xlsx'
    $null = New-CviXlsx -Path $path -Sheets $sheets

    return [pscustomobject]@{
        CheckId = 'MASTERDATA'
        File    = 'CVI_MASTER_DATA.xlsx'
        Files   = @('CVI_MASTER_DATA.xlsx')
        OutDir  = $OutDir
        Sheets  = @($sheets | ForEach-Object { $_.Name })
        Rows    = (@($stats | Measure-Object -Property Total -Sum).Sum)
        Flagged = (@($stats | Measure-Object -Property Flagged -Sum).Sum)
        Stats   = $stats
    }
}
