[CmdletBinding()]
param(
    [string]$ComparisonPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save330-vs-save341-inventory.json',
    [string]$Save341DenominatorPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save341-inventory-denominator.json',
    [string]$Save330FixturePath = 'D:\code\nikami-worlds\local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos',
    [string]$Save341FixturePath = 'D:\code\nikami-worlds\local\retail-pipboy-fixtures\NikamiCleanPipBoyOracle-20260802.fos',
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
$expectedCountMismatch = @('0x00004241', '0x00015169', '0x000CB05C')

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

function Require-FormId {
    param([AllowNull()][object]$Value, [string]$Path)
    if ([string]$Value -notmatch '^0x[0-9A-Fa-f]{8}$') {
        throw "$Path is not a canonical FormID: '$Value'"
    }
}

function Require-Text {
    param([AllowNull()][object]$Value, [string]$Path)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Path must be non-empty"
    }
}

function Write-JsonUtf8NoBom {
    param([string]$Path, [AllowNull()][object]$Value)
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10), $utf8NoBom)
}

function Assert-IdSet {
    param([AllowNull()][object]$Actual, [string[]]$Expected, [string]$Path)
    $actualIds = @($Actual | ForEach-Object { [string]$_ } | Sort-Object)
    $expectedIds = @($Expected | Sort-Object)
    if (($actualIds -join ',') -cne ($expectedIds -join ',')) {
        throw "$Path does not match the expected FormID set. Actual=$($actualIds -join ',') Expected=$($expectedIds -join ',')"
    }
}

if (-not (Test-Path -LiteralPath $ComparisonPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $Save341DenominatorPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $Save330FixturePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $Save341FixturePath -PathType Leaf)) {
    throw 'A05 validation requires the comparison, Save341 denominator, and both immutable fixtures'
}

$save330File = Get-Item -LiteralPath $Save330FixturePath
$save341File = Get-Item -LiteralPath $Save341FixturePath
if ([int64]$save330File.Length -ne $save330Bytes -or
    (Get-FileHash -LiteralPath $Save330FixturePath -Algorithm SHA256).Hash -ine $save330Hash) {
    throw 'immutable Save330 fixture hash/size mismatch'
}
if ([int64]$save341File.Length -ne $save341Bytes -or
    (Get-FileHash -LiteralPath $Save341FixturePath -Algorithm SHA256).Hash -ine $save341Hash) {
    throw 'immutable Save341 fixture hash/size mismatch'
}

$comparison = Get-Content -LiteralPath $ComparisonPath -Raw | ConvertFrom-Json
$denominator = Get-Content -LiteralPath $Save341DenominatorPath -Raw | ConvertFrom-Json
if ([string](Get-Prop -Object $comparison -Name 'schema' -Path 'comparison') -ne 'nikami-fnv-save330-vs-save341-inventory/v1') {
    throw 'comparison.schema is not the A05 schema'
}
if ([string](Get-Prop -Object $comparison -Name 'status' -Path 'comparison') -ne 'inventory-comparison-complete') {
    throw 'comparison.status is not inventory-comparison-complete'
}
if ([string](Get-Prop -Object $denominator -Name 'schema' -Path 'save341Denominator') -ne 'nikami-fnv-real-save341-retail-inventory-denominator/v1') {
    throw 'Save341 denominator schema is unexpected'
}
if ([string](Get-Prop -Object $denominator -Name 'status' -Path 'save341Denominator') -ne 'retail-oracle-inventory-snapshot') {
    throw 'Save341 denominator status is unexpected'
}

$comparisonSources = Get-Prop -Object $comparison -Name 'sources' -Path 'comparison'
$source330 = Get-Prop -Object $comparisonSources -Name 'save330' -Path 'comparison.sources'
$source330Fixture = Get-Prop -Object $source330 -Name 'fixture' -Path 'comparison.sources.save330'
if ([int64](Get-Prop -Object $source330Fixture -Name 'bytes' -Path 'comparison.sources.save330.fixture') -ne $save330Bytes -or
    [string](Get-Prop -Object $source330Fixture -Name 'sha256' -Path 'comparison.sources.save330.fixture') -ine $save330Hash) {
    throw 'comparison Save330 source hash/size mismatch'
}
$source341 = Get-Prop -Object $comparisonSources -Name 'save341' -Path 'comparison.sources'
$source341Fixture = Get-Prop -Object $source341 -Name 'fixture' -Path 'comparison.sources.save341'
if ([int64](Get-Prop -Object $source341Fixture -Name 'bytes' -Path 'comparison.sources.save341.fixture') -ne $save341Bytes -or
    [string](Get-Prop -Object $source341Fixture -Name 'sha256' -Path 'comparison.sources.save341.fixture') -ine $save341Hash) {
    throw 'comparison Save341 source hash/size mismatch'
}
$telemetrySource = Get-Prop -Object $source341 -Name 'telemetry' -Path 'comparison.sources.save341'
$telemetryPath = [string](Get-Prop -Object $telemetrySource -Name 'path' -Path 'comparison.sources.save341.telemetry')
if (-not (Test-Path -LiteralPath $telemetryPath -PathType Leaf)) {
    throw "comparison telemetry source is missing: $telemetryPath"
}
$telemetryFile = Get-Item -LiteralPath $telemetryPath
if ([int64](Get-Prop -Object $telemetrySource -Name 'bytes' -Path 'comparison.sources.save341.telemetry') -ne [int64]$telemetryFile.Length -or
    [string](Get-Prop -Object $telemetrySource -Name 'sha256' -Path 'comparison.sources.save341.telemetry') -ine (Get-FileHash -LiteralPath $telemetryPath -Algorithm SHA256).Hash) {
    throw 'comparison telemetry provenance hash/size mismatch'
}

$profile = Get-Prop -Object $comparison -Name 'contentProfile' -Path 'comparison'
Assert-IdSet -Actual (Get-Array -Object $profile -Name 'files' -Path 'comparison.contentProfile') -Expected $expectedMasters -Path 'comparison.contentProfile.files'

$denSource = Get-Prop -Object $denominator -Name 'source' -Path 'save341Denominator'
$denFixture = Get-Prop -Object $denSource -Name 'fixture' -Path 'save341Denominator.source'
if ([int64](Get-Prop -Object $denFixture -Name 'bytes' -Path 'save341Denominator.source.fixture') -ne $save341Bytes -or
    [string](Get-Prop -Object $denFixture -Name 'sha256' -Path 'save341Denominator.source.fixture') -ine $save341Hash) {
    throw 'Save341 denominator fixture provenance hash/size mismatch'
}
$selection = Get-Prop -Object $denSource -Name 'selection' -Path 'save341Denominator.source'
Require-Text -Value (Get-Prop -Object $selection -Name 'rule' -Path 'save341Denominator.source.selection') -Path 'save341Denominator.source.selection.rule'
if ([int](Get-Prop -Object $selection -Name 'frame' -Path 'save341Denominator.source.selection') -ne 2) {
    throw 'Save341 denominator did not select the deterministic first frame-2 snapshot'
}

$denInventory = Get-Prop -Object $denominator -Name 'inventory' -Path 'save341Denominator'
$denRows = Get-Array -Object $denInventory -Name 'rows' -Path 'save341Denominator.inventory'
if ($denRows.Count -ne 21 -or
    [int](Get-Prop -Object $denInventory -Name 'distinctRecords' -Path 'save341Denominator.inventory') -ne 21 -or
    [int](Get-Prop -Object $denInventory -Name 'positiveRecords' -Path 'save341Denominator.inventory') -ne 21 -or
    [int64](Get-Prop -Object $denInventory -Name 'totalCount' -Path 'save341Denominator.inventory') -ne 152) {
    throw 'Save341 denominator totals are not the frozen 21-row/152-item oracle'
}
$denById = @{}
foreach ($row in $denRows) {
    $formId = [string](Get-Prop -Object $row -Name 'formId' -Path 'save341Denominator.inventory.rows')
    Require-FormId -Value $formId -Path 'save341Denominator.inventory.rows.formId'
    if ($denById.ContainsKey($formId)) {
        throw "duplicate Save341 denominator FormID: $formId"
    }
    [void](Get-Prop -Object $row -Name 'type' -Path "save341Denominator.inventory.$formId")
    if ([int64](Get-Prop -Object $row -Name 'count' -Path "save341Denominator.inventory.$formId") -le 0) {
        throw "Save341 denominator row $formId is non-positive"
    }
    [void](Get-Prop -Object $row -Name 'worn' -Path "save341Denominator.inventory.$formId")
    $provenance = Get-Prop -Object $row -Name 'provenance' -Path "save341Denominator.inventory.$formId"
    if ([string](Get-Prop -Object $provenance -Name 'kind' -Path "save341Denominator.inventory.$formId.provenance") -ne 'retail-oracle-telemetry') {
        throw "Save341 denominator row $formId has the wrong provenance kind"
    }
    $denById[$formId] = $row
}

$rows = Get-Array -Object $comparison -Name 'rows' -Path 'comparison'
$byFormId = Get-Prop -Object $comparison -Name 'byFormId' -Path 'comparison'
if ($rows.Count -ne 50 -or @($byFormId.PSObject.Properties).Count -ne 50) {
    throw "comparison must contain exactly 50 union rows and keyed entries"
}
$seen = @{}
$derived = [ordered]@{
    common = [Collections.Generic.List[string]]::new()
    save330Only = [Collections.Generic.List[string]]::new()
    save341Only = [Collections.Generic.List[string]]::new()
    countMismatch = [Collections.Generic.List[string]]::new()
    equippedMismatch = [Collections.Generic.List[string]]::new()
}
$save330Total = [int64]0
$save341Total = [int64]0
foreach ($row in $rows) {
    $formId = [string](Get-Prop -Object $row -Name 'formId' -Path 'comparison.rows')
    Require-FormId -Value $formId -Path 'comparison.rows.formId'
    if ($seen.ContainsKey($formId)) {
        throw "duplicate comparison row FormID: $formId"
    }
    $seen[$formId] = $true
    $keyedProperty = $byFormId.PSObject.Properties[$formId]
    if ($null -eq $keyedProperty) {
        throw "comparison.byFormId is missing $formId"
    }
    $keyed = $keyedProperty.Value
    if ([string](Get-Prop -Object $keyed -Name 'formId' -Path "comparison.byFormId.$formId") -ine $formId) {
        throw "comparison.byFormId.$formId has a mismatched row FormID"
    }
    $record = Get-Prop -Object $row -Name 'record' -Path "comparison.rows.$formId"
    if ($null -eq $record) {
        throw "comparison row $formId is missing official record identity"
    }
    Require-Text -Value (Get-Prop -Object $record -Name 'editorId' -Path "comparison.rows.$formId.record") -Path "comparison.rows.$formId.record.editorId"
    Require-Text -Value (Get-Prop -Object $record -Name 'displayName' -Path "comparison.rows.$formId.record") -Path "comparison.rows.$formId.record.displayName"

    $save330 = Get-Prop -Object $row -Name 'save330' -Path "comparison.rows.$formId"
    $save341 = Get-Prop -Object $row -Name 'save341' -Path "comparison.rows.$formId"
    $has330 = [bool](Get-Prop -Object $save330 -Name 'present' -Path "comparison.rows.$formId.save330")
    $has341 = [bool](Get-Prop -Object $save341 -Name 'present' -Path "comparison.rows.$formId.save341")
    $classification = @((Get-Array -Object $row -Name 'classification' -Path "comparison.rows.$formId"))
    if ($has330) {
        $count330 = [int64](Get-Prop -Object $save330 -Name 'count' -Path "comparison.rows.$formId.save330")
        if ($count330 -le 0) {
            throw "Save330 comparison count is non-positive for $formId"
        }
        $save330Total += $count330
        $eq330 = Get-Prop -Object $save330 -Name 'equipped' -Path "comparison.rows.$formId.save330"
        [void](Get-Prop -Object $eq330 -Name 'wornVisual' -Path "comparison.rows.$formId.save330.equipped")
        $prov330 = Get-Prop -Object $save330 -Name 'provenance' -Path "comparison.rows.$formId.save330"
        if ([string](Get-Prop -Object $prov330 -Name 'kind' -Path "comparison.rows.$formId.save330.provenance") -ne 'normalized-inventory-join') {
            throw "Save330 comparison provenance kind is invalid for $formId"
        }
    }
    if ($has341) {
        $count341 = [int64](Get-Prop -Object $save341 -Name 'count' -Path "comparison.rows.$formId.save341")
        if ($count341 -le 0) {
            throw "Save341 comparison count is non-positive for $formId"
        }
        $save341Total += $count341
        if (-not $denById.ContainsKey($formId) -or $count341 -ne [int64](Get-Prop -Object $denById[$formId] -Name 'count' -Path "save341Denominator.$formId")) {
            throw "Save341 comparison row $formId does not match the frozen denominator"
        }
        $eq341 = Get-Prop -Object $save341 -Name 'equipped' -Path "comparison.rows.$formId.save341"
        [void](Get-Prop -Object $eq341 -Name 'wornVisual' -Path "comparison.rows.$formId.save341.equipped")
        $prov341 = Get-Prop -Object $save341 -Name 'provenance' -Path "comparison.rows.$formId.save341"
        if ([string](Get-Prop -Object $prov341 -Name 'kind' -Path "comparison.rows.$formId.save341.provenance") -ne 'retail-oracle-telemetry') {
            throw "Save341 comparison provenance kind is invalid for $formId"
        }
    }
    $expectedClassification = [Collections.Generic.List[string]]::new()
    if ($has330 -and $has341) {
        $expectedClassification.Add('common')
        $derived.common.Add($formId)
        if ([int64](Get-Prop -Object $save330 -Name 'count' -Path "comparison.rows.$formId.save330") -ne [int64](Get-Prop -Object $save341 -Name 'count' -Path "comparison.rows.$formId.save341")) {
            $expectedClassification.Add('countMismatch')
            $derived.countMismatch.Add($formId)
        }
        if ([bool](Get-Prop -Object (Get-Prop -Object $save330 -Name 'equipped' -Path "comparison.rows.$formId.save330") -Name 'wornVisual' -Path "comparison.rows.$formId.save330.equipped") -ne
            [bool](Get-Prop -Object (Get-Prop -Object $save341 -Name 'equipped' -Path "comparison.rows.$formId.save341") -Name 'wornVisual' -Path "comparison.rows.$formId.save341.equipped")) {
            $expectedClassification.Add('equippedMismatch')
            $derived.equippedMismatch.Add($formId)
        }
    }
    elseif ($has330) {
        $expectedClassification.Add('save330Only')
        $derived.save330Only.Add($formId)
    }
    else {
        $expectedClassification.Add('save341Only')
        $derived.save341Only.Add($formId)
    }
    Assert-IdSet -Actual $classification -Expected @($expectedClassification) -Path "comparison.rows.$formId.classification"
}

if ($save330Total -ne 788 -or $save341Total -ne 152) {
    throw "comparison denominator totals changed: Save330=$save330Total Save341=$save341Total"
}
$classifications = Get-Prop -Object $comparison -Name 'classifications' -Path 'comparison'
foreach ($name in @('common', 'save330Only', 'save341Only', 'countMismatch', 'equippedMismatch')) {
    Assert-IdSet -Actual (Get-Array -Object $classifications -Name $name -Path "comparison.classifications") -Expected @($derived.$name) -Path "comparison.classifications.$name"
}
Assert-IdSet -Actual $derived.common -Expected @($denById.Keys) -Path 'comparison.common'
Assert-IdSet -Actual $derived.countMismatch -Expected $expectedCountMismatch -Path 'comparison.countMismatch'
Assert-IdSet -Actual $derived.equippedMismatch -Expected @() -Path 'comparison.equippedMismatch'
if ($derived.save330Only.Count -ne 29 -or $derived.save341Only.Count -ne 0) {
    throw "comparison only-side counts changed: Save330Only=$($derived.save330Only.Count) Save341Only=$($derived.save341Only.Count)"
}

$denominators = Get-Prop -Object $comparison -Name 'denominators' -Path 'comparison'
if ([int](Get-Prop -Object $denominators -Name 'save330DistinctRecords' -Path 'comparison.denominators') -ne 50 -or
    [int](Get-Prop -Object $denominators -Name 'save341DistinctRecords' -Path 'comparison.denominators') -ne 21 -or
    [int64](Get-Prop -Object $denominators -Name 'save330TotalCount' -Path 'comparison.denominators') -ne 788 -or
    [int64](Get-Prop -Object $denominators -Name 'save341TotalCount' -Path 'comparison.denominators') -ne 152) {
    throw 'comparison.denominators are not the validated Save330/Save341 totals'
}

$report = [ordered]@{
    schema = 'nikami-fnv-real-save-a05-validation/v1'
    status = 'pass'
    comparison = [IO.Path]::GetFullPath($ComparisonPath)
    save341Denominator = [IO.Path]::GetFullPath($Save341DenominatorPath)
    save330DistinctRecords = 50
    save341DistinctRecords = 21
    common = $derived.common.Count
    save330Only = $derived.save330Only.Count
    save341Only = $derived.save341Only.Count
    countMismatch = $derived.countMismatch.Count
    equippedMismatch = $derived.equippedMismatch.Count
    save330TotalCount = $save330Total
    save341TotalCount = $save341Total
}
Write-JsonUtf8NoBom -Path $ReportPath -Value $report
[pscustomobject]$report | ConvertTo-Json -Depth 10
