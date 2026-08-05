[CmdletBinding()]
param(
    [string]$DenominatorPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save330-player-denominator.json',
    [string]$JoinPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save330-inventory-join.json',
    [string]$SavePath = 'D:\code\nikami-worlds\local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos',
    [string]$ReportPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save330-a04-validation.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$expectedBytes = [int64]3395328
$expectedHash = '07DBDD2D7C4ABE3160628E5463A9603A40F4271042C1DA1B89F1C4A4F7DBD81F'
$expectedMasters = @('FalloutNV.esm', 'DeadMoney.esm', 'HonestHearts.esm', 'OldWorldBlues.esm', 'LonesomeRoad.esm', 'TribalPack.esm', 'MercenaryPack.esm', 'ClassicPack.esm', 'CaravanPack.esm', 'GunRunnersArsenal.esm')
$families = @('WEAP', 'ARMO', 'CLOT', 'AMMO', 'ALCH', 'INGR', 'MISC', 'KEYM', 'BOOK')

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

function Require-Range {
    param([AllowNull()][object]$Range, [string]$Path)
    $offset = [int64](Get-Prop -Object $Range -Name 'offset' -Path $Path)
    $bytes = [int64](Get-Prop -Object $Range -Name 'bytes' -Path $Path)
    if ($offset -lt 0 -or $bytes -le 0 -or $offset -gt ($expectedBytes - $bytes)) {
        throw "$Path is outside the immutable save: offset=$offset bytes=$bytes"
    }
}

function Require-SaveProvenance {
    param([AllowNull()][object]$Provenance, [string]$Path)
    if ([string](Get-Prop -Object $Provenance -Name 'kind' -Path $Path) -ne 'save-bytes') {
        throw "$Path.kind must be save-bytes"
    }
    Require-Range -Range (Get-Prop -Object $Provenance -Name 'range' -Path $Path) -Path "$Path.range"
}

if (-not (Test-Path -LiteralPath $DenominatorPath -PathType Leaf) -or -not (Test-Path -LiteralPath $JoinPath -PathType Leaf) -or -not (Test-Path -LiteralPath $SavePath -PathType Leaf)) {
    throw 'A04 requires the denominator, inventory join, and immutable Save330 fixture'
}

$denominator = Get-Content -LiteralPath $DenominatorPath -Raw | ConvertFrom-Json
$join = Get-Content -LiteralPath $JoinPath -Raw | ConvertFrom-Json
$saveItem = Get-Item -LiteralPath $SavePath
if ([int64]$saveItem.Length -ne $expectedBytes) {
    throw "immutable Save330 byte count mismatch: $($saveItem.Length)"
}
if ((Get-FileHash -LiteralPath $SavePath -Algorithm SHA256).Hash -ine $expectedHash) {
    throw 'immutable Save330 SHA-256 mismatch'
}

if ([string](Get-Prop -Object $join -Name 'schema' -Path 'join') -ne 'nikami-fnv-save-inventory-join/v1') {
    throw 'join.schema is not the A04 schema'
}
if ([string](Get-Prop -Object $join -Name 'status' -Path 'join') -ne 'resolved-official-inventory-join') {
    throw 'join.status is not resolved-official-inventory-join'
}
$source = Get-Prop -Object $join -Name 'source' -Path 'join'
if ([int64](Get-Prop -Object $source -Name 'bytes' -Path 'join.source') -ne $expectedBytes -or [string](Get-Prop -Object $source -Name 'sha256' -Path 'join.source') -ine $expectedHash) {
    throw 'join source hash/size does not match immutable Save330'
}
$profile = Get-Prop -Object $join -Name 'contentProfile' -Path 'join'
$profileFiles = Get-Array -Object $profile -Name 'contentFiles' -Path 'join.contentProfile'
if ($profileFiles.Count -ne $expectedMasters.Count) {
    throw 'join content profile does not contain exactly ten master files'
}
for ($index = 0; $index -lt $expectedMasters.Count; $index++) {
    if ([string](Get-Prop -Object $profileFiles[$index] -Name 'name' -Path "join.contentProfile.contentFiles[$index]") -ine $expectedMasters[$index]) {
        throw "join content profile order mismatch at index $index"
    }
}

$denRows = Get-Array -Object (Get-Prop -Object $denominator -Name 'inventory' -Path 'denominator') -Name 'finalTotals' -Path 'denominator.inventory'
if ($denRows.Count -ne 50) {
    throw "A03 denominator row count changed: $($denRows.Count)"
}
$denById = @{}
foreach ($row in $denRows) {
    $formId = [string](Get-Prop -Object $row -Name 'formId' -Path 'denominator.inventory.finalTotals')
    Require-FormId -Value $formId -Path 'denominator.inventory.finalTotals.formId'
    if ($denById.ContainsKey($formId)) {
        throw "duplicate denominator FormID: $formId"
    }
    $denById[$formId] = $row
}

$unresolved = Get-Array -Object $join -Name 'unresolved' -Path 'join'
if ($unresolved.Count -ne 0) {
    throw "A04 has unresolved rows: $($unresolved.Count)"
}
$rows = Get-Array -Object $join -Name 'rows' -Path 'join'
if ($rows.Count -ne $denRows.Count) {
    throw "A04 row count $($rows.Count) does not equal A03 denominator count $($denRows.Count)"
}
$seen = @{}
foreach ($row in $rows) {
    $rowPath = "join.rows[$($seen.Count)]"
    $formId = [string](Get-Prop -Object $row -Name 'formId' -Path $rowPath)
    Require-FormId -Value $formId -Path "$rowPath.formId"
    if ($seen.ContainsKey($formId)) {
        throw "duplicate joined FormID: $formId"
    }
    $seen[$formId] = $true
    if (-not $denById.ContainsKey($formId)) {
        throw "joined positive FormID is absent from A03 denominator: $formId"
    }
    $count = [int64](Get-Prop -Object $row -Name 'count' -Path $rowPath)
    $denCount = [int64](Get-Prop -Object $denById[$formId] -Name 'count' -Path "denominator.$formId")
    if ($count -le 0 -or $count -ne $denCount) {
        throw "$rowPath.count=$count does not match denominator count=$denCount"
    }
    $record = Get-Prop -Object $row -Name 'record' -Path $rowPath
    $family = [string](Get-Prop -Object $record -Name 'family' -Path "$rowPath.record")
    if ($families -notcontains $family) {
        throw "$rowPath.record.family '$family' is not a supported winning record family"
    }
    Require-Text -Value (Get-Prop -Object $record -Name 'editorId' -Path "$rowPath.record") -Path "$rowPath.record.editorId"
    Require-Text -Value (Get-Prop -Object $record -Name 'displayName' -Path "$rowPath.record") -Path "$rowPath.record.displayName"
    Require-Text -Value (Get-Prop -Object $record -Name 'icon' -Path "$rowPath.record") -Path "$rowPath.record.icon" -AllowEmpty
    $contentFile = [string](Get-Prop -Object $record -Name 'contentFile' -Path "$rowPath.record")
    if ($expectedMasters -notcontains $contentFile) {
        throw "$rowPath.record.contentFile '$contentFile' is outside the frozen ten-master corpus"
    }
    $recordProvenance = Get-Prop -Object $record -Name 'provenance' -Path "$rowPath.record"
    if ([string](Get-Prop -Object $recordProvenance -Name 'kind' -Path "$rowPath.record.provenance") -ne 'content-record' -or [string](Get-Prop -Object $recordProvenance -Name 'contentFile' -Path "$rowPath.record.provenance") -ne $contentFile) {
        throw "$rowPath.record.provenance does not identify the winning content record"
    }
    Require-FormId -Value (Get-Prop -Object $recordProvenance -Name 'formId' -Path "$rowPath.record.provenance") -Path "$rowPath.record.provenance.formId"
    if ([string](Get-Prop -Object $recordProvenance -Name 'formId' -Path "$rowPath.record.provenance") -ine $formId) {
        throw "$rowPath.record.provenance.formId does not match row FormID"
    }

    $sources = Get-Array -Object $row -Name 'sourceContributions' -Path $rowPath
    if ($sources.Count -eq 0) {
        throw "$rowPath.sourceContributions is empty"
    }
    [int64]$sourceSum = 0
    foreach ($sourceRow in $sources) {
        $sourcePath = "$rowPath.sourceContributions"
        Require-FormId -Value (Get-Prop -Object $sourceRow -Name 'record' -Path $sourcePath) -Path "$sourcePath.record"
        $sourceSum += [int64](Get-Prop -Object $sourceRow -Name 'delta' -Path $sourcePath)
        if ([bool](Get-Prop -Object $sourceRow -Name 'fromSave' -Path $sourcePath)) {
            Require-Range -Range (Get-Prop -Object $sourceRow -Name 'range' -Path $sourcePath) -Path "$sourcePath.range"
            Require-Range -Range (Get-Prop -Object $sourceRow -Name 'formIdRange' -Path $sourcePath) -Path "$sourcePath.formIdRange"
        }
        else {
            $sourceProvenance = Get-Prop -Object $sourceRow -Name 'provenance' -Path $sourcePath
            if ([string](Get-Prop -Object $sourceProvenance -Name 'kind' -Path "$sourcePath.provenance") -ne 'content-record') {
                throw "$sourcePath.provenance must identify authored content"
            }
        }
    }
    if ($sourceSum -ne $count) {
        throw "$rowPath source contribution sum $sourceSum does not equal count $count"
    }

    $equipped = Get-Prop -Object $row -Name 'equipped' -Path $rowPath
    [void](Get-Prop -Object $equipped -Name 'wornVisual' -Path "$rowPath.equipped")
    [void](Get-Array -Object $equipped -Name 'hotkeySlots' -Path "$rowPath.equipped")
    [void](Get-Array -Object $equipped -Name 'ammoSelections' -Path "$rowPath.equipped")
    $condition = Get-Prop -Object $row -Name 'condition' -Path $rowPath
    foreach ($conditionRow in (Get-Array -Object $condition -Name 'stacks' -Path "$rowPath.condition")) {
        Require-Range -Range (Get-Prop -Object $conditionRow -Name 'sourceRange' -Path "$rowPath.condition") -Path "$rowPath.condition.sourceRange"
        Require-SaveProvenance -Provenance (Get-Prop -Object $conditionRow -Name 'provenance' -Path "$rowPath.condition") -Path "$rowPath.condition.provenance"
        $health = [double](Get-Prop -Object $conditionRow -Name 'health' -Path "$rowPath.condition")
        if ([double]::IsNaN($health) -or [double]::IsInfinity($health) -or $health -lt 0) {
            throw "$rowPath.condition.health is invalid"
        }
    }

    $weapon = Get-Prop -Object $row -Name 'weapon' -Path $rowPath
    $clipSize = Get-Prop -Object $weapon -Name 'clipSize' -Path "$rowPath.weapon"
    if ($family -eq 'WEAP') {
        if ($null -eq $clipSize -or [int64]$clipSize -lt 0) {
            throw "$rowPath.weapon.clipSize is missing for a WEAP row"
        }
    }
    $ammo = Get-Prop -Object $weapon -Name 'ammo' -Path "$rowPath.weapon"
    if ($null -ne $ammo) {
        Require-FormId -Value (Get-Prop -Object $ammo -Name 'formId' -Path "$rowPath.weapon.ammo") -Path "$rowPath.weapon.ammo.formId"
        Require-Text -Value (Get-Prop -Object $ammo -Name 'contentFile' -Path "$rowPath.weapon.ammo") -Path "$rowPath.weapon.ammo.contentFile"
    }
    foreach ($ammoListRow in (Get-Array -Object $weapon -Name 'ammoList' -Path "$rowPath.weapon")) {
        Require-FormId -Value (Get-Prop -Object $ammoListRow -Name 'formId' -Path "$rowPath.weapon.ammoList") -Path "$rowPath.weapon.ammoList.formId"
        Require-Text -Value (Get-Prop -Object $ammoListRow -Name 'contentFile' -Path "$rowPath.weapon.ammoList") -Path "$rowPath.weapon.ammoList.contentFile"
    }
    $alch = Get-Prop -Object $row -Name 'alch' -Path $rowPath
    foreach ($effect in (Get-Array -Object $alch -Name 'effectReferences' -Path "$rowPath.alch")) {
        Require-FormId -Value (Get-Prop -Object $effect -Name 'formId' -Path "$rowPath.alch.effectReferences") -Path "$rowPath.alch.effectReferences.formId"
        Require-Text -Value (Get-Prop -Object $effect -Name 'contentFile' -Path "$rowPath.alch.effectReferences") -Path "$rowPath.alch.effectReferences.contentFile"
    }
}
if ($seen.Count -ne $denRows.Count) {
    throw 'A04 did not join every positive A03 inventory row'
}

$familyCounts = [ordered]@{}
foreach ($family in ($rows | ForEach-Object { $_.record.family } | Sort-Object -Unique)) {
    $familyCounts[$family] = @($rows | Where-Object { $_.record.family -eq $family }).Count
}
$report = [ordered]@{
    schema = 'nikami-fnv-real-save-a04-validation/v1'
    status = 'pass'
    join = [IO.Path]::GetFullPath($JoinPath)
    immutableSave = [IO.Path]::GetFullPath($SavePath)
    rows = $rows.Count
    unresolved = $unresolved.Count
    familyCounts = $familyCounts
}
$reportDirectory = Split-Path -Parent $ReportPath
if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
    New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 8), $utf8NoBom)
[pscustomobject]$report | ConvertTo-Json -Depth 8
