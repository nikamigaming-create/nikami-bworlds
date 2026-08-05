[CmdletBinding()]
param(
    [string]$DenominatorPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save330-player-denominator.json',
    [string]$SavePath = 'D:\code\nikami-worlds\local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos',
    [string]$ReportPath = 'D:\code\nikami-worlds\run\fnv-real-save-campaign\save330-a03-validation.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedSaveBytes = [int64]3395328
$expectedSaveSha256 = '07DBDD2D7C4ABE3160628E5463A9603A40F4271042C1DA1B89F1C4A4F7DBD81F'
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

function Get-RequiredProperty {
    param([AllowNull()][object]$Object, [string]$Name, [string]$Path)
    if ($null -eq $Object) {
        throw "$Path is null; required property '$Name' is absent"
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Path is missing required property '$Name'"
    }
    return $property.Value
}

function Get-RequiredArray {
    param([AllowNull()][object]$Object, [string]$Name, [string]$Path)
    $value = Get-RequiredProperty -Object $Object -Name $Name -Path $Path
    if ($null -eq $value) {
        return ,@()
    }
    return ,@($value)
}

function Assert-Text {
    param([AllowNull()][object]$Value, [string]$Path, [switch]$AllowEmpty)
    if ($null -eq $Value) {
        throw "$Path must be a string"
    }
    $text = [string]$Value
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($text)) {
        throw "$Path must not be empty"
    }
}

function Assert-Equal {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected, [string]$Path, [switch]$IgnoreCase)
    $equal = if ($IgnoreCase) {
        [string]::Equals([string]$Actual, [string]$Expected, [StringComparison]::OrdinalIgnoreCase)
    }
    else {
        $Actual -eq $Expected
    }
    if (-not $equal) {
        throw "$Path expected '$Expected' but found '$Actual'"
    }
}

function Convert-ToInt64 {
    param([AllowNull()][object]$Value, [string]$Path)
    try {
        return [int64]$Value
    }
    catch {
        throw "$Path must be an integer; found '$Value'"
    }
}

function Assert-Range {
    param([AllowNull()][object]$Range, [string]$Path, [int64]$SourceBytes)
    $offset = Convert-ToInt64 -Value (Get-RequiredProperty -Object $Range -Name 'offset' -Path $Path) -Path "$Path.offset"
    $bytes = Convert-ToInt64 -Value (Get-RequiredProperty -Object $Range -Name 'bytes' -Path $Path) -Path "$Path.bytes"
    if ($offset -lt 0 -or $bytes -le 0 -or $offset -gt ($SourceBytes - $bytes)) {
        throw "$Path is outside the immutable save: offset=$offset bytes=$bytes sourceBytes=$SourceBytes"
    }
}

function Assert-Provenance {
    param(
        [AllowNull()][object]$Provenance,
        [string]$Path,
        [int64]$SourceBytes,
        [string[]]$AllowedKinds = @('save-bytes', 'content-record', 'content-profile')
    )
    $kind = [string](Get-RequiredProperty -Object $Provenance -Name 'kind' -Path $Path)
    if ($AllowedKinds -notcontains $kind) {
        throw "$Path.kind '$kind' is not one of [$($AllowedKinds -join ', ')]"
    }
    switch ($kind) {
        'save-bytes' {
            $range = Get-RequiredProperty -Object $Provenance -Name 'range' -Path $Path
            Assert-Range -Range $range -Path "$Path.range" -SourceBytes $SourceBytes
        }
        'content-record' {
            Assert-Text -Value (Get-RequiredProperty -Object $Provenance -Name 'contentFile' -Path $Path) -Path "$Path.contentFile"
        }
        'content-profile' {
            Assert-Text -Value (Get-RequiredProperty -Object $Provenance -Name 'path' -Path $Path) -Path "$Path.path"
        }
    }
}

function Assert-ValueWithProvenance {
    param(
        [AllowNull()][object]$Object,
        [string]$Path,
        [int64]$SourceBytes,
        [string[]]$AllowedKinds = @('save-bytes', 'content-record', 'content-profile')
    )
    [void](Get-RequiredProperty -Object $Object -Name 'value' -Path $Path)
    $provenance = Get-RequiredProperty -Object $Object -Name 'provenance' -Path $Path
    Assert-Provenance -Provenance $provenance -Path "$Path.provenance" -SourceBytes $SourceBytes -AllowedKinds $AllowedKinds
}

function Assert-FormIdValue {
    param(
        [AllowNull()][object]$Object,
        [string]$Path,
        [int64]$SourceBytes,
        [string[]]$AllowedKinds = @('save-bytes', 'content-record')
    )
    $value = [string](Get-RequiredProperty -Object $Object -Name 'value' -Path $Path)
    if ($value -notmatch '^0x[0-9A-Fa-f]{8}$') {
        throw "$Path.value is not a canonical FormID: '$value'"
    }
    Assert-ValueWithProvenance -Object $Object -Path $Path -SourceBytes $SourceBytes -AllowedKinds $AllowedKinds
}

function Assert-NonNegativeNumber {
    param([AllowNull()][object]$Value, [string]$Path)
    try {
        $number = [double]$Value
    }
    catch {
        throw "$Path must be numeric; found '$Value'"
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw "$Path must be finite"
    }
    if ($number -lt 0) {
        throw "$Path must be non-negative; found '$number'"
    }
}

function Assert-RowProvenance {
    param([AllowNull()][object]$Row, [string]$Path, [int64]$SourceBytes)
    $provenance = Get-RequiredProperty -Object $Row -Name 'provenance' -Path $Path
    Assert-Provenance -Provenance $provenance -Path "$Path.provenance" -SourceBytes $SourceBytes -AllowedKinds @('save-bytes')
}

if (-not (Test-Path -LiteralPath $DenominatorPath -PathType Leaf)) {
    throw "A03 denominator does not exist: $DenominatorPath"
}
if (-not (Test-Path -LiteralPath $SavePath -PathType Leaf)) {
    throw "A03 immutable save does not exist: $SavePath"
}

$denominator = Get-Content -LiteralPath $DenominatorPath -Raw | ConvertFrom-Json
$saveItem = Get-Item -LiteralPath $SavePath
$actualSaveBytes = [int64]$saveItem.Length
$actualSaveSha256 = (Get-FileHash -LiteralPath $SavePath -Algorithm SHA256).Hash.ToUpperInvariant()

Assert-Equal -Actual $actualSaveBytes -Expected $expectedSaveBytes -Path 'save.bytes'
Assert-Equal -Actual $actualSaveSha256 -Expected $expectedSaveSha256 -Path 'save.sha256' -IgnoreCase
Assert-Equal -Actual (Get-RequiredProperty -Object $denominator -Name 'schema' -Path 'root') -Expected 'nikami-fnv-save-player-denominator/v2' -Path 'root.schema'
Assert-Equal -Actual (Get-RequiredProperty -Object $denominator -Name 'status' -Path 'root') -Expected 'normalized-save-denominator' -Path 'root.status'

$source = Get-RequiredProperty -Object $denominator -Name 'source' -Path 'root'
$sourcePath = [string](Get-RequiredProperty -Object $source -Name 'path' -Path 'root.source')
Assert-Equal -Actual ([IO.Path]::GetFullPath($sourcePath)) -Expected ([IO.Path]::GetFullPath($SavePath)) -Path 'root.source.path' -IgnoreCase
Assert-Equal -Actual (Convert-ToInt64 -Value (Get-RequiredProperty -Object $source -Name 'bytes' -Path 'root.source') -Path 'root.source.bytes') -Expected $expectedSaveBytes -Path 'root.source.bytes'
Assert-Equal -Actual (Get-RequiredProperty -Object $source -Name 'sha256' -Path 'root.source') -Expected $expectedSaveSha256 -Path 'root.source.sha256' -IgnoreCase

$profile = Get-RequiredProperty -Object $denominator -Name 'contentProfile' -Path 'root'
Assert-Text -Value (Get-RequiredProperty -Object $profile -Name 'path' -Path 'root.contentProfile') -Path 'root.contentProfile.path'
$profileProvenance = Get-RequiredProperty -Object $profile -Name 'provenance' -Path 'root.contentProfile'
Assert-Provenance -Provenance $profileProvenance -Path 'root.contentProfile.provenance' -SourceBytes $expectedSaveBytes -AllowedKinds @('content-profile')
$profileFiles = Get-RequiredArray -Object $profile -Name 'contentFiles' -Path 'root.contentProfile'
Assert-Equal -Actual $profileFiles.Count -Expected $expectedMasters.Count -Path 'root.contentProfile.contentFiles.count'
for ($index = 0; $index -lt $expectedMasters.Count; $index++) {
    $file = $profileFiles[$index]
    $filePath = "root.contentProfile.contentFiles[$index]"
    Assert-Equal -Actual (Convert-ToInt64 -Value (Get-RequiredProperty -Object $file -Name 'loadOrder' -Path $filePath) -Path "$filePath.loadOrder") -Expected $index -Path "$filePath.loadOrder"
    Assert-Equal -Actual (Get-RequiredProperty -Object $file -Name 'name' -Path $filePath) -Expected $expectedMasters[$index] -Path "$filePath.name" -IgnoreCase
}

$masters = Get-RequiredArray -Object $denominator -Name 'masters' -Path 'root'
Assert-Equal -Actual $masters.Count -Expected $expectedMasters.Count -Path 'root.masters.count'
for ($index = 0; $index -lt $expectedMasters.Count; $index++) {
    $master = $masters[$index]
    $masterPath = "root.masters[$index]"
    Assert-Equal -Actual (Get-RequiredProperty -Object $master -Name 'name' -Path $masterPath) -Expected $expectedMasters[$index] -Path "$masterPath.name" -IgnoreCase
    Assert-RowProvenance -Row $master -Path $masterPath -SourceBytes $expectedSaveBytes
}

$loadPlan = Get-RequiredProperty -Object $denominator -Name 'normalizedLoadPlan' -Path 'root'
Assert-Equal -Actual (Get-RequiredProperty -Object $loadPlan -Name 'status' -Path 'root.normalizedLoadPlan') -Expected 'resolved' -Path 'root.normalizedLoadPlan.status'
$uncoveredState = Get-RequiredArray -Object $loadPlan -Name 'uncoveredState' -Path 'root.normalizedLoadPlan'
foreach ($state in $uncoveredState) {
    Assert-Text -Value $state -Path 'root.normalizedLoadPlan.uncoveredState'
}

$player = Get-RequiredProperty -Object $denominator -Name 'player' -Path 'root'
Assert-FormIdValue -Object (Get-RequiredProperty -Object $player -Name 'baseRecord' -Path 'root.player') -Path 'root.player.baseRecord' -SourceBytes $expectedSaveBytes -AllowedKinds @('content-record')
Assert-FormIdValue -Object (Get-RequiredProperty -Object $player -Name 'referenceRecord' -Path 'root.player') -Path 'root.player.referenceRecord' -SourceBytes $expectedSaveBytes -AllowedKinds @('content-record')
foreach ($name in @('saveNumber', 'level', 'processLevel', 'weaponDrawn', 'currentWeaponAction', 'referenceChangeFlags')) {
    $value = Get-RequiredProperty -Object $player -Name $name -Path 'root.player'
    Assert-ValueWithProvenance -Object $value -Path "root.player.$name" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
}
foreach ($name in @('name', 'karmaTitle', 'locationLabel', 'playTimeLabel')) {
    $value = Get-RequiredProperty -Object $player -Name $name -Path 'root.player'
    Assert-Text -Value (Get-RequiredProperty -Object $value -Name 'value' -Path "root.player.$name") -Path "root.player.$name.value" -AllowEmpty
    Assert-ValueWithProvenance -Object $value -Path "root.player.$name" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
}
Assert-Range -Range (Get-RequiredProperty -Object $player -Name 'referencePayloadRange' -Path 'root.player') -Path 'root.player.referencePayloadRange' -SourceBytes $expectedSaveBytes

$transform = Get-RequiredProperty -Object $denominator -Name 'transform' -Path 'root'
$cell = Get-RequiredProperty -Object $transform -Name 'cellOrWorldspace' -Path 'root.transform'
Assert-FormIdValue -Object $cell -Path 'root.transform.cellOrWorldspace' -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
Assert-Text -Value (Get-RequiredProperty -Object $cell -Name 'recordFamily' -Path 'root.transform.cellOrWorldspace') -Path 'root.transform.cellOrWorldspace.recordFamily'
foreach ($name in @('position', 'rotationRadians')) {
    $values = Get-RequiredArray -Object $transform -Name $name -Path 'root.transform'
    Assert-Equal -Actual $values.Count -Expected 3 -Path "root.transform.$name.count"
    for ($index = 0; $index -lt $values.Count; $index++) {
        Assert-ValueWithProvenance -Object $values[$index] -Path "root.transform.$name[$index]" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
    }
}

$camera = Get-RequiredProperty -Object $denominator -Name 'camera' -Path 'root'
foreach ($name in @('firstPersonMode', 'firstPerson', 'firstPersonModelFov', 'worldFov')) {
    $value = Get-RequiredProperty -Object $camera -Name $name -Path 'root.camera'
    Assert-ValueWithProvenance -Object $value -Path "root.camera.$name" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
}

$scene = Get-RequiredProperty -Object $denominator -Name 'scene' -Path 'root'
foreach ($name in @('gameHour', 'lastUpdateHour', 'weatherPercent')) {
    $value = Get-RequiredProperty -Object $scene -Name $name -Path 'root.scene'
    Assert-ValueWithProvenance -Object $value -Path "root.scene.$name" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
}
foreach ($name in @('currentWeather', 'defaultWeather')) {
    $value = Get-RequiredProperty -Object $scene -Name $name -Path 'root.scene'
    Assert-FormIdValue -Object $value -Path "root.scene.$name" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
}
Assert-Range -Range (Get-RequiredProperty -Object $scene -Name 'payloadRange' -Path 'root.scene') -Path 'root.scene.payloadRange' -SourceBytes $expectedSaveBytes

$inventory = Get-RequiredProperty -Object $denominator -Name 'inventory' -Path 'root'
$finalTotals = Get-RequiredArray -Object $inventory -Name 'finalTotals' -Path 'root.inventory'
$contributions = Get-RequiredArray -Object $inventory -Name 'contributions' -Path 'root.inventory'
$conditionedStacks = Get-RequiredArray -Object $inventory -Name 'conditionedStacks' -Path 'root.inventory'
Assert-Equal -Actual $finalTotals.Count -Expected 50 -Path 'root.inventory.finalTotals.count'
Assert-Equal -Actual $contributions.Count -Expected 52 -Path 'root.inventory.contributions.count'
Assert-Equal -Actual $conditionedStacks.Count -Expected 24 -Path 'root.inventory.conditionedStacks.count'

for ($rowIndex = 0; $rowIndex -lt $finalTotals.Count; $rowIndex++) {
    $row = $finalTotals[$rowIndex]
    $rowPath = "root.inventory.finalTotals[$rowIndex]"
    $formId = [string](Get-RequiredProperty -Object $row -Name 'formId' -Path $rowPath)
    if ($formId -notmatch '^0x[0-9A-Fa-f]{8}$') {
        throw "$rowPath.formId is not a canonical FormID: '$formId'"
    }
    $count = Convert-ToInt64 -Value (Get-RequiredProperty -Object $row -Name 'count' -Path $rowPath) -Path "$rowPath.count"
    if ($count -le 0) {
        throw "$rowPath.count must be positive"
    }
    $rowProvenance = Get-RequiredArray -Object $row -Name 'provenance' -Path $rowPath
    if ($rowProvenance.Count -eq 0) {
        throw "$rowPath.provenance must prove at least one normalized contribution"
    }
    [int64]$sum = 0
    foreach ($provenance in $rowProvenance) {
        $kind = [string](Get-RequiredProperty -Object $provenance -Name 'kind' -Path "$rowPath.provenance")
        $delta = Convert-ToInt64 -Value (Get-RequiredProperty -Object $provenance -Name 'delta' -Path "$rowPath.provenance") -Path "$rowPath.provenance.delta"
        $sum += $delta
        if ($kind -eq 'save-bytes') {
            $sourceFormId = [string](Get-RequiredProperty -Object $provenance -Name 'sourceFormId' -Path "$rowPath.provenance")
            if ($sourceFormId -notmatch '^0x[0-9A-Fa-f]{8}$') {
                throw "$rowPath.provenance.sourceFormId is not a canonical FormID"
            }
            Assert-Range -Range (Get-RequiredProperty -Object $provenance -Name 'range' -Path "$rowPath.provenance") -Path "$rowPath.provenance.range" -SourceBytes $expectedSaveBytes
            Assert-Range -Range (Get-RequiredProperty -Object $provenance -Name 'formIdRange' -Path "$rowPath.provenance") -Path "$rowPath.provenance.formIdRange" -SourceBytes $expectedSaveBytes
        }
        elseif ($kind -eq 'content-record') {
            Assert-Text -Value (Get-RequiredProperty -Object $provenance -Name 'contentFile' -Path "$rowPath.provenance") -Path "$rowPath.provenance.contentFile"
            $sourceFormId = [string](Get-RequiredProperty -Object $provenance -Name 'formId' -Path "$rowPath.provenance")
            if ($sourceFormId -notmatch '^0x[0-9A-Fa-f]{8}$') {
                throw "$rowPath.provenance.formId is not a canonical FormID"
            }
        }
        else {
            throw "$rowPath.provenance.kind '$kind' is not a normalized inventory provenance kind"
        }
    }
    if ($sum -ne $count) {
        throw "$rowPath.count=$count does not equal its provenance delta sum=$sum"
    }
}

for ($rowIndex = 0; $rowIndex -lt $contributions.Count; $rowIndex++) {
    $row = $contributions[$rowIndex]
    $rowPath = "root.inventory.contributions[$rowIndex]"
    foreach ($name in @('record', 'sourceRecord')) {
        $formId = [string](Get-RequiredProperty -Object $row -Name $name -Path $rowPath)
        if ($formId -notmatch '^0x[0-9A-Fa-f]{8}$') {
            throw "$rowPath.$name is not a canonical FormID"
        }
    }
    [void](Convert-ToInt64 -Value (Get-RequiredProperty -Object $row -Name 'delta' -Path $rowPath) -Path "$rowPath.delta")
    $fromSave = [bool](Get-RequiredProperty -Object $row -Name 'fromSave' -Path $rowPath)
    if ($fromSave) {
        Assert-Range -Range (Get-RequiredProperty -Object $row -Name 'range' -Path $rowPath) -Path "$rowPath.range" -SourceBytes $expectedSaveBytes
        Assert-Range -Range (Get-RequiredProperty -Object $row -Name 'formIdRange' -Path $rowPath) -Path "$rowPath.formIdRange" -SourceBytes $expectedSaveBytes
    }
    else {
        Assert-Provenance -Provenance (Get-RequiredProperty -Object $row -Name 'provenance' -Path $rowPath) -Path "$rowPath.provenance" -SourceBytes $expectedSaveBytes -AllowedKinds @('content-record')
    }
}

for ($rowIndex = 0; $rowIndex -lt $conditionedStacks.Count; $rowIndex++) {
    $row = $conditionedStacks[$rowIndex]
    $rowPath = "root.inventory.conditionedStacks[$rowIndex]"
    $formId = [string](Get-RequiredProperty -Object $row -Name 'formId' -Path $rowPath)
    if ($formId -notmatch '^0x[0-9A-Fa-f]{8}$') {
        throw "$rowPath.formId is not a canonical FormID"
    }
    [void](Convert-ToInt64 -Value (Get-RequiredProperty -Object $row -Name 'count' -Path $rowPath) -Path "$rowPath.count")
    Assert-NonNegativeNumber -Value (Get-RequiredProperty -Object $row -Name 'health' -Path $rowPath) -Path "$rowPath.health"
    Assert-RowProvenance -Row $row -Path $rowPath -SourceBytes $expectedSaveBytes
}

$equipped = Get-RequiredProperty -Object $denominator -Name 'equippedRows' -Path 'root'
$worn = Get-RequiredArray -Object $equipped -Name 'wornVisualItems' -Path 'root.equippedRows'
$hotkeys = Get-RequiredArray -Object $equipped -Name 'hotkeys' -Path 'root.equippedRows'
$ammoSelections = Get-RequiredArray -Object $equipped -Name 'ammoSelections' -Path 'root.equippedRows'
Assert-Equal -Actual $worn.Count -Expected 3 -Path 'root.equippedRows.wornVisualItems.count'
Assert-Equal -Actual $hotkeys.Count -Expected 0 -Path 'root.equippedRows.hotkeys.count'
Assert-Equal -Actual $ammoSelections.Count -Expected 0 -Path 'root.equippedRows.ammoSelections.count'
for ($rowIndex = 0; $rowIndex -lt $worn.Count; $rowIndex++) {
    $row = $worn[$rowIndex]
    $rowPath = "root.equippedRows.wornVisualItems[$rowIndex]"
    $formId = [string](Get-RequiredProperty -Object $row -Name 'formId' -Path $rowPath)
    if ($formId -notmatch '^0x[0-9A-Fa-f]{8}$') {
        throw "$rowPath.formId is not a canonical FormID"
    }
    Assert-Range -Range (Get-RequiredProperty -Object $row -Name 'sourceRange' -Path $rowPath) -Path "$rowPath.sourceRange" -SourceBytes $expectedSaveBytes
    Assert-RowProvenance -Row $row -Path $rowPath -SourceBytes $expectedSaveBytes
}
$weaponState = Get-RequiredProperty -Object $equipped -Name 'weaponState' -Path 'root.equippedRows'
foreach ($name in @('drawn', 'currentAction', 'currentActionSourceOffset')) {
    [void](Get-RequiredProperty -Object $weaponState -Name $name -Path 'root.equippedRows.weaponState')
}
Assert-RowProvenance -Row $weaponState -Path 'root.equippedRows.weaponState' -SourceBytes $expectedSaveBytes

$actorValues = Get-RequiredProperty -Object $denominator -Name 'actorValues' -Path 'root'
$modifiers = Get-RequiredArray -Object $actorValues -Name 'modifiers' -Path 'root.actorValues'
Assert-Equal -Actual $modifiers.Count -Expected 1 -Path 'root.actorValues.modifiers.count'
for ($rowIndex = 0; $rowIndex -lt $modifiers.Count; $rowIndex++) {
    $row = $modifiers[$rowIndex]
    $rowPath = "root.actorValues.modifiers[$rowIndex]"
    [void](Convert-ToInt64 -Value (Get-RequiredProperty -Object $row -Name 'actorValue' -Path $rowPath) -Path "$rowPath.actorValue")
    Assert-NonNegativeNumber -Value (Get-RequiredProperty -Object $row -Name 'modifier' -Path $rowPath) -Path "$rowPath.modifier"
    $kind = [string](Get-RequiredProperty -Object $row -Name 'kind' -Path $rowPath)
    if (@('permanent', 'damage', 'temporary') -notcontains $kind) {
        throw "$rowPath.kind '$kind' is not a normalized actor-value modifier kind"
    }
    [void](Convert-ToInt64 -Value (Get-RequiredProperty -Object $row -Name 'sourceOffset' -Path $rowPath) -Path "$rowPath.sourceOffset")
    Assert-RowProvenance -Row $row -Path $rowPath -SourceBytes $expectedSaveBytes
}

$actorArrays = Get-RequiredProperty -Object $actorValues -Name 'arrays' -Path 'root.actorValues'
foreach ($name in @('unidentified244', 'permanent378', 'unidentified4B0')) {
    $array = Get-RequiredArray -Object $actorArrays -Name $name -Path 'root.actorValues.arrays'
    Assert-Equal -Actual $array.Count -Expected 77 -Path "root.actorValues.arrays.$name.count"
    for ($index = 0; $index -lt $array.Count; $index++) {
        $sample = Get-RequiredProperty -Object $array[$index] -Name 'sample' -Path "root.actorValues.arrays.$name[$index]"
        Assert-ValueWithProvenance -Object $sample -Path "root.actorValues.arrays.$name[$index].sample" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
    }
}

$globals = Get-RequiredArray -Object $denominator -Name 'globals' -Path 'root'
Assert-Equal -Actual $globals.Count -Expected 200 -Path 'root.globals.count'
for ($rowIndex = 0; $rowIndex -lt $globals.Count; $rowIndex++) {
    $row = $globals[$rowIndex]
    $rowPath = "root.globals[$rowIndex]"
    $formId = [string](Get-RequiredProperty -Object $row -Name 'formId' -Path $rowPath)
    if ($formId -notmatch '^0x[0-9A-Fa-f]{8}$') {
        throw "$rowPath.formId is not a canonical FormID"
    }
    $value = Get-RequiredProperty -Object $row -Name 'value' -Path $rowPath
    Assert-ValueWithProvenance -Object $value -Path "$rowPath.value" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
    Assert-Range -Range (Get-RequiredProperty -Object $row -Name 'entryRange' -Path $rowPath) -Path "$rowPath.entryRange" -SourceBytes $expectedSaveBytes
    Assert-Range -Range (Get-RequiredProperty -Object $row -Name 'formIdRange' -Path $rowPath) -Path "$rowPath.formIdRange" -SourceBytes $expectedSaveBytes
}

$quest = Get-RequiredProperty -Object $denominator -Name 'questProgress' -Path 'root'
Assert-Equal -Actual (Get-RequiredProperty -Object $quest -Name 'status' -Path 'root.questProgress') -Expected 'normalized' -Path 'root.questProgress.status'
$activeQuest = Get-RequiredProperty -Object $quest -Name 'activeQuest' -Path 'root.questProgress'
if ($null -ne $activeQuest) {
    Assert-FormIdValue -Object $activeQuest -Path 'root.questProgress.activeQuest' -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
}
$stages = Get-RequiredArray -Object $quest -Name 'stages' -Path 'root.questProgress'
$objectives = Get-RequiredArray -Object $quest -Name 'objectives' -Path 'root.questProgress'
Assert-Equal -Actual $stages.Count -Expected 0 -Path 'root.questProgress.stages.count'
Assert-Equal -Actual $objectives.Count -Expected 4 -Path 'root.questProgress.objectives.count'
for ($rowIndex = 0; $rowIndex -lt $stages.Count; $rowIndex++) {
    $row = $stages[$rowIndex]
    $rowPath = "root.questProgress.stages[$rowIndex]"
    $questValue = Get-RequiredProperty -Object $row -Name 'quest' -Path $rowPath
    Assert-FormIdValue -Object $questValue -Path "$rowPath.quest" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
    foreach ($name in @('stage', 'logEntry')) {
        $value = Get-RequiredProperty -Object $row -Name $name -Path $rowPath
        Assert-ValueWithProvenance -Object $value -Path "$rowPath.$name" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
    }
    Assert-Range -Range (Get-RequiredProperty -Object $row -Name 'entryRange' -Path $rowPath) -Path "$rowPath.entryRange" -SourceBytes $expectedSaveBytes
}
for ($rowIndex = 0; $rowIndex -lt $objectives.Count; $rowIndex++) {
    $row = $objectives[$rowIndex]
    $rowPath = "root.questProgress.objectives[$rowIndex]"
    $questValue = Get-RequiredProperty -Object $row -Name 'quest' -Path $rowPath
    Assert-FormIdValue -Object $questValue -Path "$rowPath.quest" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
    $value = Get-RequiredProperty -Object $row -Name 'objective' -Path $rowPath
    Assert-ValueWithProvenance -Object $value -Path "$rowPath.objective" -SourceBytes $expectedSaveBytes -AllowedKinds @('save-bytes')
    Assert-Range -Range (Get-RequiredProperty -Object $row -Name 'entryRange' -Path $rowPath) -Path "$rowPath.entryRange" -SourceBytes $expectedSaveBytes
}

$markers = Get-RequiredProperty -Object $denominator -Name 'discoveredMarkerStates' -Path 'root'
Assert-Equal -Actual (Get-RequiredProperty -Object $markers -Name 'status' -Path 'root.discoveredMarkerStates') -Expected 'unsupported' -Path 'root.discoveredMarkerStates.status'
$markerReason = [string](Get-RequiredProperty -Object $markers -Name 'reason' -Path 'root.discoveredMarkerStates')
Assert-Text -Value $markerReason -Path 'root.discoveredMarkerStates.reason'
if ($markerReason -notmatch 'no plugin-default' -or $markerReason -notmatch 'unlock-all') {
    throw 'root.discoveredMarkerStates.reason does not explicitly reject guessed or unlock-all marker state'
}

$opaqueRanges = Get-RequiredArray -Object $denominator -Name 'unsupportedOpaqueRanges' -Path 'root'
Assert-Equal -Actual $opaqueRanges.Count -Expected 6600 -Path 'root.unsupportedOpaqueRanges.count'
$opaqueBytes = Convert-ToInt64 -Value (Get-RequiredProperty -Object $denominator -Name 'unsupportedOpaqueBytes' -Path 'root') -Path 'root.unsupportedOpaqueBytes'
[int64]$opaqueSum = 0
for ($rowIndex = 0; $rowIndex -lt $opaqueRanges.Count; $rowIndex++) {
    $row = $opaqueRanges[$rowIndex]
    $rowPath = "root.unsupportedOpaqueRanges[$rowIndex]"
    $range = Get-RequiredProperty -Object $row -Name 'range' -Path $rowPath
    Assert-Range -Range $range -Path "$rowPath.range" -SourceBytes $expectedSaveBytes
    Assert-RowProvenance -Row $row -Path $rowPath -SourceBytes $expectedSaveBytes
    $opaqueSum += Convert-ToInt64 -Value (Get-RequiredProperty -Object $range -Name 'bytes' -Path "$rowPath.range") -Path "$rowPath.range.bytes"
}
Assert-Equal -Actual $opaqueSum -Expected $opaqueBytes -Path 'root.unsupportedOpaqueBytes.sum'
Assert-Equal -Actual $opaqueBytes -Expected 2685310 -Path 'root.unsupportedOpaqueBytes'

$report = [ordered]@{
    schema = 'nikami-fnv-real-save-a03-validation/v1'
    status = 'pass'
    denominator = [IO.Path]::GetFullPath($DenominatorPath)
    immutableSave = [IO.Path]::GetFullPath($SavePath)
    saveBytes = $actualSaveBytes
    saveSha256 = $actualSaveSha256
    counts = [ordered]@{
        masters = $masters.Count
        inventoryFinalTotals = $finalTotals.Count
        inventoryContributions = $contributions.Count
        conditionedStacks = $conditionedStacks.Count
        wornVisualItems = $worn.Count
        hotkeys = $hotkeys.Count
        ammoSelections = $ammoSelections.Count
        actorValueModifiers = $modifiers.Count
        actorValueSamples = 231
        globals = $globals.Count
        questStages = $stages.Count
        questObjectives = $objectives.Count
        unsupportedOpaqueRanges = $opaqueRanges.Count
        unsupportedOpaqueBytes = $opaqueBytes
    }
}

$reportDirectory = Split-Path -Parent $ReportPath
if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
    New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 8), $utf8NoBom)
[pscustomobject]$report | ConvertTo-Json -Depth 8
