# Cvi.Data.ps1 - loads the extracted ECC configuration and master data into one dataset.
# Every table here is what an extract from the source system would deliver
# (SE16 / table download of T077D, T077K, TB001, NRIV, KNA1, LFA1, ADRC, KNVK, BUT000, CVI links).

function Get-CviText {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim()
}

function Import-CviTable {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Extract file not found: $Path"
    }
    $rows = @(Import-Csv -LiteralPath $Path)
    return $rows
}

function Import-CviOptionalTable {
    # Files a consultant creates by editing in the tool, rather than by extracting from ECC.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Import-Csv -LiteralPath $Path)
}

function ConvertTo-CviLookup {
    param([object[]]$Rows, [string]$KeyColumn)
    $map = @{}
    foreach ($r in $Rows) {
        $k = Get-CviText $r.$KeyColumn
        if ($k -ne '' -and -not $map.ContainsKey($k)) { $map[$k] = $r }
    }
    return $map
}

function Get-CviDataset {
    param([string]$Root)

    $cfg    = Join-Path $Root 'data\config'
    $master = Join-Path $Root 'data\master'
    $notes  = Join-Path $Root 'data\notes'

    $settingsRows = Import-CviTable (Join-Path $cfg 'CVI_SETTINGS.csv')
    $settings = @{}
    foreach ($s in $settingsRows) { $settings[(Get-CviText $s.KEY)] = (Get-CviText $s.VALUE) }

    $data = [ordered]@{
        Root            = $Root
        Settings        = $settings
        SettingRows     = $settingsRows
        CustAccountGrp  = Import-CviTable (Join-Path $cfg 'T077D.csv')
        VendAccountGrp  = Import-CviTable (Join-Path $cfg 'T077K.csv')
        BpGrouping      = Import-CviTable (Join-Path $cfg 'TB001.csv')
        CustToBp        = Import-CviTable (Join-Path $cfg 'CVI_CUST_TO_BP1.csv')
        VendToBp        = Import-CviTable (Join-Path $cfg 'CVI_VEND_TO_BP1.csv')
        NumberRanges    = Import-CviTable (Join-Path $cfg 'NRIV.csv')
        Countries       = Import-CviTable (Join-Path $cfg 'T005.csv')
        Titles          = Import-CviTable (Join-Path $cfg 'TSAD3.csv')
        CustLinks       = Import-CviTable (Join-Path $cfg 'CVI_CUST_LINK.csv')
        VendLinks       = Import-CviTable (Join-Path $cfg 'CVI_VEND_LINK.csv')
        Customers       = Import-CviTable (Join-Path $master 'KNA1.csv')
        Vendors         = Import-CviTable (Join-Path $master 'LFA1.csv')
        Addresses       = Import-CviTable (Join-Path $master 'ADRC.csv')
        Contacts        = Import-CviTable (Join-Path $master 'KNVK.csv')
        BusinessPartner = Import-CviTable (Join-Path $master 'BUT000.csv')
        SapNotes        = Import-CviTable (Join-Path $notes 'sap_notes.csv')
    }

    $data.RangeOverrides = Import-CviOptionalTable (Join-Path $cfg 'CVI_BP_RANGE_OVERRIDES.csv')
    $data.RangeOverrideMap = @{}
    foreach ($o in $data.RangeOverrides) {
        $id = Get-CviText $o.ID
        if ($id -ne '') { $data.RangeOverrideMap[$id] = $o }
    }

    $data.AddressByNumber   = ConvertTo-CviLookup $data.Addresses 'ADDRNUMBER'
    $data.CountryByKey      = ConvertTo-CviLookup $data.Countries 'LAND1'
    $data.GroupingByKey     = ConvertTo-CviLookup $data.BpGrouping 'GROUPING'
    $data.CustGrpByKey      = ConvertTo-CviLookup $data.CustAccountGrp 'KTOKD'
    $data.VendGrpByKey      = ConvertTo-CviLookup $data.VendAccountGrp 'KTOKK'
    $data.BpByPartner       = ConvertTo-CviLookup $data.BusinessPartner 'PARTNER'

    $data.CustGroupingMap = @{}
    foreach ($m in $data.CustToBp) { $data.CustGroupingMap[(Get-CviText $m.KTOKD)] = (Get-CviText $m.GROUPING) }
    $data.VendGroupingMap = @{}
    foreach ($m in $data.VendToBp) { $data.VendGroupingMap[(Get-CviText $m.KTOKK)] = (Get-CviText $m.GROUPING) }

    $data.CustLinkMap = @{}
    foreach ($l in $data.CustLinks) { $data.CustLinkMap[(Get-CviText $l.KUNNR)] = (Get-CviText $l.PARTNER) }
    $data.VendLinkMap = @{}
    foreach ($l in $data.VendLinks) { $data.VendLinkMap[(Get-CviText $l.LIFNR)] = (Get-CviText $l.PARTNER) }

    $data.TitleTexts = @()
    foreach ($t in $data.Titles) { $data.TitleTexts += (Get-CviText $t.TEXT) }

    # A single normalised view over customers and vendors keeps every master-data
    # rule from being written twice.
    $records = New-Object System.Collections.ArrayList
    foreach ($c in $data.Customers) {
        $grp = Get-CviText $c.KTOKD
        $accRow = $null
        if ($data.CustGrpByKey.ContainsKey($grp)) { $accRow = $data.CustGrpByKey[$grp] }
        $oneTime = $false
        if ($accRow -and (Get-CviText $accRow.XCPDK) -eq 'X') { $oneTime = $true }
        $grouping = ''
        if ($data.CustGroupingMap.ContainsKey($grp)) { $grouping = $data.CustGroupingMap[$grp] }
        $null = $records.Add([pscustomobject]@{
            Object       = 'CUSTOMER'
            Table        = 'KNA1'
            Display      = 'Customer'
            Key          = Get-CviText $c.KUNNR
            AccountGroup = $grp
            AccountText  = $(if ($accRow) { Get-CviText $accRow.TXT30 } else { '' })
            TypeHint     = $(if ($accRow) { Get-CviText $accRow.PARTNER_TYPE_HINT } else { '' })
            Grouping     = $grouping
            OneTime      = $oneTime
            Name         = Get-CviText $c.NAME1
            SearchTerm   = Get-CviText $c.SORTL
            AddressNo    = Get-CviText $c.ADRNR
            Country      = Get-CviText $c.LAND1
            Language     = Get-CviText $c.SPRAS
            Title        = Get-CviText $c.ANRED
            TaxNumber    = Get-CviText $c.STCD1
            VatNumber    = Get-CviText $c.STCEG
            Deleted      = ((Get-CviText $c.LOEVM) -eq 'X')
            LinkedBp     = $(if ($data.CustLinkMap.ContainsKey((Get-CviText $c.KUNNR))) { $data.CustLinkMap[(Get-CviText $c.KUNNR)] } else { '' })
        })
    }
    foreach ($v in $data.Vendors) {
        $grp = Get-CviText $v.KTOKK
        $accRow = $null
        if ($data.VendGrpByKey.ContainsKey($grp)) { $accRow = $data.VendGrpByKey[$grp] }
        $oneTime = $false
        if ($accRow -and (Get-CviText $accRow.XCPDK) -eq 'X') { $oneTime = $true }
        $grouping = ''
        if ($data.VendGroupingMap.ContainsKey($grp)) { $grouping = $data.VendGroupingMap[$grp] }
        $null = $records.Add([pscustomobject]@{
            Object       = 'VENDOR'
            Table        = 'LFA1'
            Display      = 'Vendor'
            Key          = Get-CviText $v.LIFNR
            AccountGroup = $grp
            AccountText  = $(if ($accRow) { Get-CviText $accRow.TXT30 } else { '' })
            TypeHint     = $(if ($accRow) { Get-CviText $accRow.PARTNER_TYPE_HINT } else { '' })
            Grouping     = $grouping
            OneTime      = $oneTime
            Name         = Get-CviText $v.NAME1
            SearchTerm   = Get-CviText $v.SORTL
            AddressNo    = Get-CviText $v.ADRNR
            Country      = Get-CviText $v.LAND1
            Language     = Get-CviText $v.SPRAS
            Title        = Get-CviText $v.ANRED
            TaxNumber    = Get-CviText $v.STCD1
            VatNumber    = Get-CviText $v.STCEG
            Deleted      = ((Get-CviText $v.LOEVM) -eq 'X')
            LinkedBp     = $(if ($data.VendLinkMap.ContainsKey((Get-CviText $v.LIFNR))) { $data.VendLinkMap[(Get-CviText $v.LIFNR)] } else { '' })
        })
    }
    $data.Records = @($records)

    return $data
}
