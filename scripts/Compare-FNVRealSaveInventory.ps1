[CmdletBinding()]
param(
    [string]$Save330JoinPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save330-inventory-join.json',
    [string]$Save341TelemetryPath = 'D:\code\nikami-worlds\run\retail-pipboy-clean-save341-20260802-091809\retail\retail-pipboy-state.jsonl',
    [string]$Save341FixturePath = 'D:\code\nikami-worlds\local\retail-pipboy-fixtures\NikamiCleanPipBoyOracle-20260802.fos',
    [string]$Save341DenominatorPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save341-inventory-denominator.json',
    [string]$OutputPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save330-vs-save341-inventory.json',
    [string]$ReportPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save330-vs-save341-inventory-validation.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$save330Bytes = [int64]3395328
$save330Hash = '07DBDD2D7C4ABE3160628E5463A9603A40F4271042C1DA1B89F1C4A4F7DBD81F'
$save341Bytes = [int64]1978137
$save341Hash = 'D33A0303D103D94417870B1EEDBA39C08A2E1884D730104DCFB5D59074CD8CF5'
$expectedMasters = @(
    'FalloutNV.esm',
    'DeadMoney.esm',
    'HonestHearts.esm',
    'OldWorldBlues.esm',
    'LonesomeRoad.esm',
    'TribalPack.esm',
    'MercenaryPack.esm',
    'ClassicPack.esm',
    'CaravanPack.esm',
    'GunRunnersArsenal.esm'
)

function Get-Prop {
    param([AllowNull()][object]$Object, [string]$Name, [string]$Path)
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        throw "$Path is missing required property '$Name'"
    }
    return $Object.PSObject.Properties[$Name].Value
}

function Get-Array {
    param([AllowNull()][object]$Object, [string]$Name, [string]$Path)
    $value = Get-Prop -Object $Object -Name $Name -Path $Path
    if ($null -eq $value) {
        return ,@()
    }
    return ,@($value)
}

function Require-Text {
    param([AllowNull()][object]$Value, [string]$Path, [switch]$AllowEmpty)
    if ($null -eq $Value -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string]$Value))) {
        throw "$Path must be a non-empty string"
    }
}

function Require-FormId {
    param([AllowNull()][object]$Value, [string]$Path)
    if ([string]$Value -notmatch '^0x[0-9A-Fa-f]{8}$') {
        throw "$Path is not a canonical FormID: '$Value'"
    }
}

function Write-JsonUtf8NoBom {
    param([string]$Path, [AllowNull()][object]$Value, [int]$Depth = 20)
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth $Depth), $utf8NoBom)
}

function Get-CanonicalFormId {
    param([AllowNull()][object]$Value, [string]$Path)
    $number = [int64]$Value
    if ($number -lt 0 -or $number -gt [uint32]::MaxValue) {
        throw "$Path is outside the uint32 FormID range: $number"
    }
    return ('0x{0:X8}' -f [uint32]$number)
}

function Get-NumericFormId {
    param([string]$FormId, [string]$Path)
    Require-FormId -Value $FormId -Path $Path
    return [uint64]::Parse($FormId.Substring(2), [Globalization.NumberStyles]::AllowHexSpecifier, [Globalization.CultureInfo]::InvariantCulture)
}

if (-not (Test-Path -LiteralPath $Save330JoinPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $Save341TelemetryPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $Save341FixturePath -PathType Leaf)) {
    throw 'A05 requires the completed Save330 join, the preserved Save341 retail telemetry, and the immutable Save341 fixture'
}

$save341File = Get-Item -LiteralPath $Save341FixturePath
if ([int64]$save341File.Length -ne $save341Bytes) {
    throw "immutable Save341 byte count mismatch: $($save341File.Length)"
}
if ((Get-FileHash -LiteralPath $Save341FixturePath -Algorithm SHA256).Hash -ine $save341Hash) {
    throw 'immutable Save341 SHA-256 mismatch'
}

$join = Get-Content -LiteralPath $Save330JoinPath -Raw | ConvertFrom-Json
if ([string](Get-Prop -Object $join -Name 'schema' -Path 'save330Join') -ne 'nikami-fnv-save-inventory-join/v1') {
    throw 'Save330 join has an unexpected schema'
}
if ([string](Get-Prop -Object $join -Name 'status' -Path 'save330Join') -ne 'resolved-official-inventory-join') {
    throw 'Save330 join is not the resolved official inventory join'
}
$save330Source = Get-Prop -Object $join -Name 'source' -Path 'save330Join'
if ([int64](Get-Prop -Object $save330Source -Name 'bytes' -Path 'save330Join.source') -ne $save330Bytes -or
    [string](Get-Prop -Object $save330Source -Name 'sha256' -Path 'save330Join.source') -ine $save330Hash) {
    throw 'Save330 join source does not match the immutable canonical Save330 fixture'
}
$profile = Get-Prop -Object $join -Name 'contentProfile' -Path 'save330Join'
$profileFiles = Get-Array -Object $profile -Name 'contentFiles' -Path 'save330Join.contentProfile'
if ($profileFiles.Count -ne $expectedMasters.Count) {
    throw 'Save330 join content profile does not contain exactly ten official masters'
}
for ($index = 0; $index -lt $expectedMasters.Count; $index++) {
    if ([string](Get-Prop -Object $profileFiles[$index] -Name 'name' -Path "save330Join.contentProfile.contentFiles[$index]") -ine $expectedMasters[$index]) {
        throw "Save330 join content profile order mismatch at index $index"
    }
}

$save330Rows = Get-Array -Object $join -Name 'rows' -Path 'save330Join'
if ($save330Rows.Count -ne 50) {
    throw "A05 requires the completed 50-row Save330 join; found $($save330Rows.Count)"
}
$save330ById = @{}
foreach ($row in $save330Rows) {
    $formId = [string](Get-Prop -Object $row -Name 'formId' -Path 'save330Join.rows')
    Require-FormId -Value $formId -Path 'save330Join.rows.formId'
    if ($save330ById.ContainsKey($formId)) {
        throw "duplicate Save330 join FormID: $formId"
    }
    $count = [int64](Get-Prop -Object $row -Name 'count' -Path "save330Join.rows.$formId")
    if ($count -le 0) {
        throw "Save330 join row $formId has a non-positive count"
    }
    $record = Get-Prop -Object $row -Name 'record' -Path "save330Join.rows.$formId"
    $recordProvenance = Get-Prop -Object $record -Name 'provenance' -Path "save330Join.rows.$formId.record"
    $recordFormId = [string](Get-Prop -Object $recordProvenance -Name 'formId' -Path "save330Join.rows.$formId.record.provenance")
    if ($recordFormId -ine $formId) {
        throw "Save330 record provenance FormID does not match row $formId"
    }
    $equipped = Get-Prop -Object $row -Name 'equipped' -Path "save330Join.rows.$formId"
    $worn = [bool](Get-Prop -Object $equipped -Name 'wornVisual' -Path "save330Join.rows.$formId.equipped")
    $sources = Get-Array -Object $row -Name 'sourceContributions' -Path "save330Join.rows.$formId"
    if ($sources.Count -eq 0) {
        throw "Save330 join row $formId has no source contributions"
    }
    $save330ById[$formId] = [ordered]@{
        row = $row
        count = $count
        wornVisual = $worn
        sourceContributions = $sources
    }
}

$telemetryItem = Get-Item -LiteralPath $Save341TelemetryPath
$telemetryHash = (Get-FileHash -LiteralPath $Save341TelemetryPath -Algorithm SHA256).Hash
$selectedEvent = $null
$selectedInventory = $null
$selectedLineNumber = 0
$lineNumber = 0
foreach ($line in [IO.File]::ReadLines($Save341TelemetryPath)) {
    $lineNumber++
    if ($line -notmatch '"event":"retail-pipboy-snapshot"') {
        continue
    }
    $event = $line | ConvertFrom-Json
    $player = $event.PSObject.Properties['player']
    if ($null -eq $player -or $null -eq $player.Value) {
        continue
    }
    $inventoryProperty = $player.Value.PSObject.Properties['inventory']
    if ($null -eq $inventoryProperty -or $null -eq $inventoryProperty.Value) {
        continue
    }
    $inventory = $inventoryProperty.Value
    if (-not [bool](Get-Prop -Object $inventory -Name 'available' -Path "telemetry.line$lineNumber.player.inventory")) {
        continue
    }
    $items = Get-Array -Object $inventory -Name 'items' -Path "telemetry.line$lineNumber.player.inventory"
    $distinct = [int](Get-Prop -Object $inventory -Name 'distinctRecords' -Path "telemetry.line$lineNumber.player.inventory")
    $truncated = [bool](Get-Prop -Object $inventory -Name 'truncated' -Path "telemetry.line$lineNumber.player.inventory")
    $positive = @($items | Where-Object { [int64](Get-Prop -Object $_ -Name 'count' -Path "telemetry.line$lineNumber.player.inventory.items") -gt 0 })
    if (-not $truncated -and $distinct -eq 21 -and $items.Count -eq 21 -and $positive.Count -eq 21) {
        $selectedEvent = $event
        $selectedInventory = $inventory
        $selectedLineNumber = $lineNumber
        break
    }
}
if ($null -eq $selectedEvent) {
    throw 'No complete, non-truncated 21-row Save341 retail inventory snapshot was found'
}

$save341Rows = Get-Array -Object $selectedInventory -Name 'items' -Path 'save341.inventory'
$save341ById = @{}
$save341DenominatorRows = [Collections.Generic.List[object]]::new()
$itemIndex = 0
foreach ($item in $save341Rows) {
    $formId = Get-CanonicalFormId -Value (Get-Prop -Object $item -Name 'form' -Path "save341.inventory.items[$itemIndex]") -Path "save341.inventory.items[$itemIndex].form"
    if ($save341ById.ContainsKey($formId)) {
        throw "duplicate Save341 retail FormID: $formId"
    }
    $count = [int64](Get-Prop -Object $item -Name 'count' -Path "save341.inventory.items[$itemIndex]")
    if ($count -le 0) {
        throw "Save341 retail row $formId has a non-positive count"
    }
    $type = [int](Get-Prop -Object $item -Name 'type' -Path "save341.inventory.items[$itemIndex]")
    $worn = [bool](Get-Prop -Object $item -Name 'worn' -Path "save341.inventory.items[$itemIndex]")
    $rowSource = [ordered]@{
        kind = 'retail-oracle-telemetry'
        path = [IO.Path]::GetFullPath($Save341TelemetryPath)
        line = $selectedLineNumber
        event = [string](Get-Prop -Object $selectedEvent -Name 'event' -Path "telemetry.line$selectedLineNumber")
        schema = [string](Get-Prop -Object $selectedEvent -Name 'schema' -Path "telemetry.line$selectedLineNumber")
        frame = [int](Get-Prop -Object $selectedEvent -Name 'frame' -Path "telemetry.line$selectedLineNumber")
        label = [string](Get-Prop -Object $selectedEvent -Name 'label' -Path "telemetry.line$selectedLineNumber")
        fieldPath = "player.inventory.items[$itemIndex]"
        fixture = [ordered]@{
            path = [IO.Path]::GetFullPath($Save341FixturePath)
            bytes = $save341Bytes
            sha256 = $save341Hash
        }
    }
    $save341ById[$formId] = [ordered]@{
        formId = $formId
        count = $count
        worn = $worn
        type = $type
        source = $rowSource
    }
    $save341DenominatorRows.Add([ordered]@{
        formId = $formId
        type = $type
        count = $count
        worn = $worn
        provenance = $rowSource
    })
    $itemIndex++
}

$save341Denominator = [ordered]@{
    schema = 'nikami-fnv-real-save341-retail-inventory-denominator/v1'
    status = 'retail-oracle-inventory-snapshot'
    source = [ordered]@{
        fixture = [ordered]@{
            path = [IO.Path]::GetFullPath($Save341FixturePath)
            bytes = $save341Bytes
            sha256 = $save341Hash
        }
        telemetry = [ordered]@{
            path = [IO.Path]::GetFullPath($Save341TelemetryPath)
            bytes = [int64]$telemetryItem.Length
            sha256 = $telemetryHash
        }
        selection = [ordered]@{
            event = [string](Get-Prop -Object $selectedEvent -Name 'event' -Path "telemetry.line$selectedLineNumber")
            schema = [string](Get-Prop -Object $selectedEvent -Name 'schema' -Path "telemetry.line$selectedLineNumber")
            line = $selectedLineNumber
            frame = [int](Get-Prop -Object $selectedEvent -Name 'frame' -Path "telemetry.line$selectedLineNumber")
            label = [string](Get-Prop -Object $selectedEvent -Name 'label' -Path "telemetry.line$selectedLineNumber")
            rule = 'first available, non-truncated snapshot with distinctRecords=21 and 21 positive item rows'
        }
    }
    inventory = [ordered]@{
        distinctRecords = $save341Rows.Count
        positiveRecords = $save341Rows.Count
        totalCount = [int64](($save341Rows | Measure-Object -Property count -Sum).Sum)
        rows = @($save341DenominatorRows)
    }
}
Write-JsonUtf8NoBom -Path $Save341DenominatorPath -Value $save341Denominator -Depth 20

$allIds = @($save330ById.Keys + $save341ById.Keys | Sort-Object -Unique)
$rows = [Collections.Generic.List[object]]::new()
$byFormId = [ordered]@{}
$categories = [ordered]@{
    common = [Collections.Generic.List[string]]::new()
    save330Only = [Collections.Generic.List[string]]::new()
    save341Only = [Collections.Generic.List[string]]::new()
    countMismatch = [Collections.Generic.List[string]]::new()
    equippedMismatch = [Collections.Generic.List[string]]::new()
}
$save330TotalCount = [int64]0
$save341TotalCount = [int64]0
foreach ($id in $save330ById.Keys) {
    $save330TotalCount += [int64]$save330ById[$id].count
}
foreach ($id in $save341ById.Keys) {
    $save341TotalCount += [int64]$save341ById[$id].count
}

foreach ($formId in $allIds) {
    $has330 = $save330ById.ContainsKey($formId)
    $has341 = $save341ById.ContainsKey($formId)
    $classification = [Collections.Generic.List[string]]::new()
    $record = $null
    if ($has330) {
        $record = $save330ById[$formId].row.record
    }
    if ($has330 -and $has341) {
        $classification.Add('common')
        $categories.common.Add($formId)
        if ([int64]$save330ById[$formId].count -ne [int64]$save341ById[$formId].count) {
            $classification.Add('countMismatch')
            $categories.countMismatch.Add($formId)
        }
        if ([bool]$save330ById[$formId].wornVisual -ne [bool]$save341ById[$formId].worn) {
            $classification.Add('equippedMismatch')
            $categories.equippedMismatch.Add($formId)
        }
    }
    elseif ($has330) {
        $classification.Add('save330Only')
        $categories.save330Only.Add($formId)
    }
    else {
        $classification.Add('save341Only')
        $categories.save341Only.Add($formId)
    }

    $save330Side = [ordered]@{
        present = $has330
    }
    if ($has330) {
        $save330Side.count = [int64]$save330ById[$formId].count
        $save330Side.equipped = [ordered]@{
            wornVisual = [bool]$save330ById[$formId].wornVisual
            sourceKind = 'normalized-FalloutSaveLoadPlan'
        }
        $save330Side.provenance = [ordered]@{
            kind = 'normalized-inventory-join'
            path = [IO.Path]::GetFullPath($Save330JoinPath)
            formId = $formId
            sourceContributions = $save330ById[$formId].sourceContributions
        }
    }

    $save341Side = [ordered]@{
        present = $has341
    }
    if ($has341) {
        $save341Side.count = [int64]$save341ById[$formId].count
        $save341Side.equipped = [ordered]@{
            wornVisual = [bool]$save341ById[$formId].worn
            sourceKind = 'retail-oracle-telemetry'
        }
        $save341Side.provenance = $save341ById[$formId].source
        $save341Side.type = [int]$save341ById[$formId].type
    }

    $comparisonRow = [ordered]@{
        formId = $formId
        record = $record
        save330 = $save330Side
        save341 = $save341Side
        classification = @($classification)
    }
    $rows.Add($comparisonRow)
    $byFormId[$formId] = $comparisonRow
}

$comparison = [ordered]@{
    schema = 'nikami-fnv-save330-vs-save341-inventory/v1'
    status = 'inventory-comparison-complete'
    sources = [ordered]@{
        save330 = [ordered]@{
            fixture = [ordered]@{
                path = [IO.Path]::GetFullPath([string](Get-Prop -Object $save330Source -Name 'path' -Path 'save330Join.source'))
                bytes = $save330Bytes
                sha256 = $save330Hash
            }
            inventoryJoin = [IO.Path]::GetFullPath($Save330JoinPath)
        }
        save341 = [ordered]@{
            fixture = [ordered]@{
                path = [IO.Path]::GetFullPath($Save341FixturePath)
                bytes = $save341Bytes
                sha256 = $save341Hash
            }
            inventoryDenominator = [IO.Path]::GetFullPath($Save341DenominatorPath)
            telemetry = [ordered]@{
                path = [IO.Path]::GetFullPath($Save341TelemetryPath)
                bytes = [int64]$telemetryItem.Length
                sha256 = $telemetryHash
            }
        }
    }
    contentProfile = [ordered]@{
        files = @($expectedMasters)
        provenance = [string](Get-Prop -Object $profile -Name 'path' -Path 'save330Join.contentProfile')
    }
    denominators = [ordered]@{
        save330DistinctRecords = $save330ById.Count
        save330PositiveRecords = $save330ById.Count
        save330TotalCount = $save330TotalCount
        save341DistinctRecords = $save341ById.Count
        save341PositiveRecords = $save341ById.Count
        save341TotalCount = $save341TotalCount
    }
    classifications = [ordered]@{
        common = @($categories.common)
        save330Only = @($categories.save330Only)
        save341Only = @($categories.save341Only)
        countMismatch = @($categories.countMismatch)
        equippedMismatch = @($categories.equippedMismatch)
    }
    rows = @($rows)
    byFormId = $byFormId
}
Write-JsonUtf8NoBom -Path $OutputPath -Value $comparison -Depth 30

$report = [ordered]@{
    schema = 'nikami-fnv-real-save-a05-validation/v1'
    status = 'pass'
    comparison = [IO.Path]::GetFullPath($OutputPath)
    save341Denominator = [IO.Path]::GetFullPath($Save341DenominatorPath)
    save330DistinctRecords = $save330ById.Count
    save341DistinctRecords = $save341ById.Count
    common = $categories.common.Count
    save330Only = $categories.save330Only.Count
    save341Only = $categories.save341Only.Count
    countMismatch = $categories.countMismatch.Count
    equippedMismatch = $categories.equippedMismatch.Count
    save330TotalCount = $save330TotalCount
    save341TotalCount = $save341TotalCount
}
Write-JsonUtf8NoBom -Path $ReportPath -Value $report -Depth 10
[pscustomobject]$report | ConvertTo-Json -Depth 10
