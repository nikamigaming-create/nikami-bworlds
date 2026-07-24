Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FNVRetailCheckpointManifest.psm1') -Force

$script:PairSchema = 'nikami-fnv-retail-openmw-checkpoint-pair/v1'
$script:PairTokenPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$'
$script:PairSha256Pattern = '^[0-9A-Fa-f]{64}$'
$script:PairRequiredLedgerPaths = @(Get-FNVRetailCheckpointRequiredLedgerPaths)
$script:PairToleranceNames = @(
    'frameSyncSecondsMaximum'
    'positionAbsoluteMaximum'
    'rotationRadiansMaximum'
    'scaleAbsoluteMaximum'
    'velocityAbsoluteMaximum'
    'targetPositionAbsoluteMaximum'
    'animationPhaseMaximum'
    'animationTweenMaximum'
    'conditionAbsoluteMaximum'
    'alphaAbsoluteMaximum'
    'cameraPositionAbsoluteMaximum'
    'cameraRotationRadiansMaximum'
    'fovAbsoluteMaximum'
    'gameHourMaximum'
    'timeScaleMaximum'
    'weatherTransitionMaximum'
    'pixelMaeMaximum'
    'pixelRmseMaximum'
)

function Get-PairProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    Write-Output -NoEnumerate $property.Value
}

function Get-PairArray {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return ,([object[]]@()) }
    return ,([object[]]@($Value))
}

function Test-PairHasProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Add-PairFailure {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    $Failures.Add("${Path}: $Message") | Out-Null
}

function Test-PairJsonInteger {
    param([AllowNull()][object]$Value)
    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Test-PairJsonNumber {
    param([AllowNull()][object]$Value)
    return (Test-PairJsonInteger $Value) -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]
}

function Assert-PairRequiredProperties {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    if ($null -eq $Object) {
        Add-PairFailure $Failures $Path 'is missing or null'
        return
    }
    foreach ($name in $Names) {
        if (-not (Test-PairHasProperty $Object $name)) {
            Add-PairFailure $Failures $Path "is missing required field '$name'"
        }
    }
}

function Assert-PairAllowedProperties {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    if ($null -eq $Object) { return }
    foreach ($property in @($Object.PSObject.Properties)) {
        if ($Names -notcontains [string]$property.Name) {
            Add-PairFailure $Failures $Path "contains unknown field '$($property.Name)'"
        }
    }
}

function Assert-PairString {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures,
        [string]$Pattern = '',
        [switch]$AllowNull
    )
    if ($null -eq $Value -and $AllowNull) { return }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        Add-PairFailure $Failures $Path 'must be a nonempty JSON string'
        return
    }
    if (-not [string]::IsNullOrEmpty($Pattern) -and [string]$Value -notmatch $Pattern) {
        Add-PairFailure $Failures $Path "does not match required pattern '$Pattern'"
    }
}

function Get-PairRawFloat {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    Assert-PairRequiredProperties $Value @('value', 'bitsHex') $Path $Failures
    Assert-PairAllowedProperties $Value @('value', 'bitsHex') $Path $Failures
    if ($null -eq $Value) { return [double]0 }
    $bitsText = Get-PairProperty $Value 'bitsHex'
    $display = Get-PairProperty $Value 'value'
    if ($bitsText -isnot [string] -or [string]$bitsText -notmatch '^0[xX][0-9A-Fa-f]{8}$') {
        Add-PairFailure $Failures "$Path/bitsHex" 'must be an exact float32 bit pattern'
        return [double]0
    }
    try {
        $bits = [Convert]::ToUInt32(([string]$bitsText).Substring(2), 16)
        $decoded = [BitConverter]::ToSingle([BitConverter]::GetBytes($bits), 0)
        if ([single]::IsNaN($decoded) -or [single]::IsInfinity($decoded)) {
            Add-PairFailure $Failures $Path 'contains a non-finite float and cannot be compared'
            return [double]0
        }
        if ($null -eq $display -or -not (Test-PairJsonNumber $display)) {
            Add-PairFailure $Failures "$Path/value" 'must be numeric for a finite float32'
        }
        else {
            $displayBits = [BitConverter]::ToUInt32([BitConverter]::GetBytes([single]$display), 0)
            $negativeZero = $bits -eq [uint32]2147483648 -and [double]$display -eq 0
            if ($displayBits -ne $bits -and -not $negativeZero) {
                Add-PairFailure $Failures "$Path/value" `
                    "does not round-trip to authoritative bits $bitsText"
            }
        }
        return [double]$decoded
    }
    catch {
        Add-PairFailure $Failures $Path "could not decode float32 bits: $($_.Exception.Message)"
        return [double]0
    }
}

function Get-PairVector3 {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures,
        [switch]$AllowNull
    )
    if ($null -eq $Value -and $AllowNull) { return $null }
    Assert-PairRequiredProperties $Value @('x', 'y', 'z') $Path $Failures
    Assert-PairAllowedProperties $Value @('x', 'y', 'z') $Path $Failures
    if ($null -eq $Value) { return [double[]](0, 0, 0) }
    return [double[]]@(
        (Get-PairRawFloat (Get-PairProperty $Value 'x') "$Path/x" $Failures),
        (Get-PairRawFloat (Get-PairProperty $Value 'y') "$Path/y" $Failures),
        (Get-PairRawFloat (Get-PairProperty $Value 'z') "$Path/z" $Failures)
    )
}

function Get-PairFormKeyIdentity {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, object]]$Plugins,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures,
        [switch]$AllowNull
    )
    if ($null -eq $Value -and $AllowNull) { return $null }
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        Add-PairFailure $Failures $Path 'must be an explicit FormKey object'
        return $null
    }
    $kind = Get-PairProperty $Value 'kind'
    if ($kind -eq 'plugin') {
        $properties = @('kind', 'originPlugin', 'localFormId', 'winningPlugin', 'runtimeFormId')
        Assert-PairRequiredProperties $Value $properties $Path $Failures
        Assert-PairAllowedProperties $Value $properties $Path $Failures
        $origin = Get-PairProperty $Value 'originPlugin'
        $local = Get-PairProperty $Value 'localFormId'
        $winner = Get-PairProperty $Value 'winningPlugin'
        $runtime = Get-PairProperty $Value 'runtimeFormId'
        Assert-PairString $origin "$Path/originPlugin" $Failures
        Assert-PairString $local "$Path/localFormId" $Failures '^0[xX][0-9A-Fa-f]{6}$'
        Assert-PairString $winner "$Path/winningPlugin" $Failures
        Assert-PairString $runtime "$Path/runtimeFormId" $Failures '^0[xX][0-9A-Fa-f]{8}$'
        if ($origin -is [string] -and -not $Plugins.ContainsKey([string]$origin)) {
            Add-PairFailure $Failures "$Path/originPlugin" 'is absent from the ordered load order'
        }
        if ($winner -is [string] -and -not $Plugins.ContainsKey([string]$winner)) {
            Add-PairFailure $Failures "$Path/winningPlugin" 'is absent from the ordered load order'
        }
        if ($origin -is [string] -and $Plugins.ContainsKey([string]$origin) -and
            $winner -is [string] -and $Plugins.ContainsKey([string]$winner)) {
            $originIndex = [int](Get-PairProperty $Plugins[[string]$origin] 'index')
            $winnerIndex = [int](Get-PairProperty $Plugins[[string]$winner] 'index')
            if ($winnerIndex -lt $originIndex) {
                Add-PairFailure $Failures "$Path/winningPlugin" 'precedes its origin plugin'
            }
            if ($local -is [string] -and [string]$local -match '^0[xX][0-9A-Fa-f]{6}$' -and
                $runtime -is [string] -and [string]$runtime -match '^0[xX][0-9A-Fa-f]{8}$') {
                $localNumber = [Convert]::ToUInt32(([string]$local).Substring(2), 16)
                $runtimeNumber = [Convert]::ToUInt32(([string]$runtime).Substring(2), 16)
                $expected = [uint32]((([uint64]$originIndex) -shl 24) -bor [uint64]$localNumber)
                if ($runtimeNumber -ne $expected) {
                    Add-PairFailure $Failures "$Path/runtimeFormId" `
                        "does not match origin index and local FormID (expected 0x$('{0:X8}' -f $expected))"
                }
            }
        }
        return 'plugin|{0}|{1}|{2}' -f ([string]$origin).ToLowerInvariant(),
            ([string]$local).ToUpperInvariant(), ([string]$winner).ToLowerInvariant()
    }
    if ($kind -eq 'dynamic') {
        $properties = @('kind', 'runtimeFormId', 'saveDynamicId', 'baseForm')
        Assert-PairRequiredProperties $Value $properties $Path $Failures
        Assert-PairAllowedProperties $Value $properties $Path $Failures
        $runtime = Get-PairProperty $Value 'runtimeFormId'
        $dynamicId = Get-PairProperty $Value 'saveDynamicId'
        Assert-PairString $runtime "$Path/runtimeFormId" $Failures '^0[xX][fF]{2}[0-9A-Fa-f]{6}$'
        Assert-PairString $dynamicId "$Path/saveDynamicId" $Failures '^0[xX][0-9A-Fa-f]{6}$'
        if ($runtime -is [string] -and [string]$runtime -match '^0[xX][fF]{2}[0-9A-Fa-f]{6}$' -and
            $dynamicId -is [string] -and [string]$dynamicId -match '^0[xX][0-9A-Fa-f]{6}$') {
            $runtimeLow = [Convert]::ToUInt32(([string]$runtime).Substring(4), 16)
            $dynamicLow = [Convert]::ToUInt32(([string]$dynamicId).Substring(2), 16)
            if ($runtimeLow -ne $dynamicLow) {
                Add-PairFailure $Failures "$Path/saveDynamicId" 'does not match runtimeFormId low 24 bits'
            }
        }
        $baseValue = Get-PairProperty $Value 'baseForm'
        if ((Get-PairProperty $baseValue 'kind') -ne 'plugin') {
            Add-PairFailure $Failures "$Path/baseForm" 'must be a plugin-qualified base FormKey'
        }
        $baseIdentity = Get-PairFormKeyIdentity $baseValue "$Path/baseForm" $Plugins $Failures
        return 'dynamic|{0}|{1}' -f ([string]$dynamicId).ToUpperInvariant(), $baseIdentity
    }
    Add-PairFailure $Failures "$Path/kind" "must be 'plugin' or 'dynamic'"
    return $null
}

function Get-PairPluginMap {
    param(
        [AllowNull()][object]$LoadOrderValue,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    $loadOrder = Get-PairArray $LoadOrderValue
    if ($LoadOrderValue -is [string] -or $loadOrder.Count -eq 0 -or $loadOrder.Count -gt 255) {
        Add-PairFailure $Failures '/loadOrder' 'must contain 1 to 255 ordered plugin records'
    }
    $plugins = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $loadOrder.Count; ++$index) {
        $entry = $loadOrder[$index]
        $path = "/loadOrder/$index"
        $properties = @('index', 'plugin', 'bytes', 'sha256')
        Assert-PairRequiredProperties $entry $properties $path $Failures
        Assert-PairAllowedProperties $entry $properties $path $Failures
        $declaredIndex = Get-PairProperty $entry 'index'
        if (-not (Test-PairJsonInteger $declaredIndex) -or [int64]$declaredIndex -ne $index) {
            Add-PairFailure $Failures "$path/index" "must equal ordered position $index"
        }
        $plugin = Get-PairProperty $entry 'plugin'
        Assert-PairString $plugin "$path/plugin" $Failures '\.[eE][sS][mMpP]$'
        if ($plugin -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$plugin)) {
            if ($plugins.ContainsKey([string]$plugin)) {
                Add-PairFailure $Failures "$path/plugin" "duplicates plugin '$plugin'"
            }
            else { $plugins.Add([string]$plugin, $entry) }
        }
        $bytes = Get-PairProperty $entry 'bytes'
        if (-not (Test-PairJsonInteger $bytes) -or [int64]$bytes -lt 1) {
            Add-PairFailure $Failures "$path/bytes" 'must be a positive JSON integer'
        }
        Assert-PairString (Get-PairProperty $entry 'sha256') "$path/sha256" $Failures `
            $script:PairSha256Pattern
    }
    return $plugins
}

function Get-PairTolerances {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    Assert-PairRequiredProperties $Value $script:PairToleranceNames '/tolerances' $Failures
    Assert-PairAllowedProperties $Value $script:PairToleranceNames '/tolerances' $Failures
    $result = [ordered]@{}
    foreach ($name in $script:PairToleranceNames) {
        $number = Get-PairProperty $Value $name
        if (-not (Test-PairJsonNumber $number) -or [double]$number -lt 0 -or
            [double]::IsNaN([double]$number) -or [double]::IsInfinity([double]$number)) {
            Add-PairFailure $Failures "/tolerances/$name" 'must be a finite nonnegative number'
            $result[$name] = [double]0
        }
        else { $result[$name] = [double]$number }
    }
    foreach ($bounded in @('animationPhaseMaximum', 'alphaAbsoluteMaximum',
        'weatherTransitionMaximum', 'pixelMaeMaximum', 'pixelRmseMaximum')) {
        $maximum = if ($bounded -eq 'animationPhaseMaximum') { 0.5 } else { 1.0 }
        if ([double]$result[$bounded] -gt $maximum) {
            Add-PairFailure $Failures "/tolerances/$bounded" "cannot exceed $maximum"
        }
    }
    if ([double]$result.gameHourMaximum -gt 12) {
        Add-PairFailure $Failures '/tolerances/gameHourMaximum' 'cannot exceed 12 hours'
    }
    return [pscustomobject]$result
}

function Assert-PairCoverageLedger {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    $entries = Get-PairArray $Value
    if ($Value -is [string] -or $entries.Count -eq 0) {
        Add-PairFailure $Failures '/coverageLedger' 'must be a nonempty JSON array'
    }
    $byPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $entries.Count; ++$index) {
        $entry = $entries[$index]
        $path = "/coverageLedger/$index"
        $properties = @('retailPath', 'required', 'status', 'retail', 'openMw', 'compareMode', 'blocker')
        Assert-PairRequiredProperties $entry $properties $path $Failures
        Assert-PairAllowedProperties $entry $properties $path $Failures
        $retailPath = Get-PairProperty $entry 'retailPath'
        Assert-PairString $retailPath "$path/retailPath" $Failures `
            '^/(?:[^/~]|~[01])+(?:/(?:[^/~]|~[01])+)*$'
        if ($retailPath -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$retailPath)) {
            if ($byPath.ContainsKey([string]$retailPath)) {
                Add-PairFailure $Failures "$path/retailPath" "duplicates '$retailPath'"
            }
            else { $byPath.Add([string]$retailPath, $entry) }
        }
        if ((Get-PairProperty $entry 'required') -isnot [bool] -or
            -not [bool](Get-PairProperty $entry 'required')) {
            Add-PairFailure $Failures "$path/required" 'must be JSON boolean true'
        }
        if ((Get-PairProperty $entry 'status') -cne 'mapped') {
            Add-PairFailure $Failures "$path/status" 'must be mapped for paired parity'
        }
        if ($null -ne (Get-PairProperty $entry 'blocker')) {
            Add-PairFailure $Failures "$path/blocker" 'must be null for a mapped parity entry'
        }
        $compareModes = @('raw-bits', 'exact', 'semantic', 'ordered-set', 'artifact-hash', 'visual-signature')
        if ($compareModes -notcontains [string](Get-PairProperty $entry 'compareMode')) {
            Add-PairFailure $Failures "$path/compareMode" 'is not a supported compare mode'
        }
        foreach ($lane in @('retail', 'openMw')) {
            $bytes = Get-PairProperty $entry $lane
            Assert-PairRequiredProperties $bytes @('observedBytes', 'mappedBytes', 'unmappedBytes') `
                "$path/$lane" $Failures
            Assert-PairAllowedProperties $bytes @('observedBytes', 'mappedBytes', 'unmappedBytes') `
                "$path/$lane" $Failures
            $values = @{}
            foreach ($name in @('observedBytes', 'mappedBytes', 'unmappedBytes')) {
                $number = Get-PairProperty $bytes $name
                if (-not (Test-PairJsonInteger $number) -or [int64]$number -lt 0) {
                    Add-PairFailure $Failures "$path/$lane/$name" 'must be a nonnegative JSON integer'
                    $values[$name] = [int64]0
                }
                else { $values[$name] = [int64]$number }
            }
            if ($values.observedBytes -ne $values.mappedBytes + $values.unmappedBytes) {
                Add-PairFailure $Failures "$path/$lane" `
                    'observedBytes must equal mappedBytes plus unmappedBytes'
            }
            if ($values.unmappedBytes -ne 0) {
                Add-PairFailure $Failures "$path/$lane/unmappedBytes" `
                    'must be zero; unmapped bytes fail paired parity'
            }
        }
    }
    foreach ($requiredPath in $script:PairRequiredLedgerPaths) {
        if (-not $byPath.ContainsKey($requiredPath)) {
            Add-PairFailure $Failures '/coverageLedger' "is missing required category '$requiredPath'"
        }
    }
    if ($byPath.Count -ne $script:PairRequiredLedgerPaths.Count) {
        Add-PairFailure $Failures '/coverageLedger' `
            "must contain exactly the $($script:PairRequiredLedgerPaths.Count) canonical categories"
    }
}

function Convert-PairEquipment {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, object]]$Plugins,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    $items = Get-PairArray $Value
    if ($null -eq $Value -or $Value -is [string]) {
        Add-PairFailure $Failures $Path 'must be a JSON array'
    }
    $result = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $items.Count; ++$index) {
        $item = $items[$index]
        $itemPath = "$Path/$index"
        $properties = @('instanceId', 'form', 'slot', 'count', 'condition', 'equipped')
        Assert-PairRequiredProperties $item $properties $itemPath $Failures
        Assert-PairAllowedProperties $item $properties $itemPath $Failures
        $instanceId = Get-PairProperty $item 'instanceId'
        Assert-PairString $instanceId "$itemPath/instanceId" $Failures $script:PairTokenPattern
        $form = Get-PairFormKeyIdentity (Get-PairProperty $item 'form') "$itemPath/form" $Plugins $Failures
        $slot = Get-PairProperty $item 'slot'
        Assert-PairString $slot "$itemPath/slot" $Failures
        $count = Get-PairProperty $item 'count'
        if (-not (Test-PairJsonInteger $count) -or [int64]$count -lt 1) {
            Add-PairFailure $Failures "$itemPath/count" 'must be a positive JSON integer'
            $count = 0
        }
        $condition = Get-PairRawFloat (Get-PairProperty $item 'condition') "$itemPath/condition" $Failures
        $equipped = Get-PairProperty $item 'equipped'
        if ($equipped -isnot [bool]) {
            Add-PairFailure $Failures "$itemPath/equipped" 'must be a JSON boolean'
            $equipped = $false
        }
        if ($instanceId -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$instanceId)) {
            if ($result.ContainsKey([string]$instanceId)) {
                Add-PairFailure $Failures "$itemPath/instanceId" "duplicates '$instanceId'"
            }
            else {
                $result.Add([string]$instanceId, [pscustomobject][ordered]@{
                    form = $form; slot = [string]$slot; count = [int64]$count
                    condition = [double]$condition; equipped = [bool]$equipped
                })
            }
        }
    }
    return $result
}

function Convert-PairVisual {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    Assert-PairRequiredProperties $Value @('rootPresent', 'parts') $Path $Failures
    Assert-PairAllowedProperties $Value @('rootPresent', 'parts') $Path $Failures
    $rootPresent = Get-PairProperty $Value 'rootPresent'
    if ($rootPresent -isnot [bool]) {
        Add-PairFailure $Failures "$Path/rootPresent" 'must be a JSON boolean'
        $rootPresent = $false
    }
    if (-not $rootPresent) {
        Add-PairFailure $Failures "$Path/rootPresent" 'is false; a missing actor root is a hard failure'
    }
    $partsValue = Get-PairProperty $Value 'parts'
    $parts = Get-PairArray $partsValue
    if ($partsValue -is [string] -or $parts.Count -eq 0) {
        Add-PairFailure $Failures "$Path/parts" 'must contain at least one required geometry part'
    }
    $result = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $parts.Count; ++$index) {
        $part = $parts[$index]
        $partPath = "$Path/parts/$index"
        $properties = @(
            'partId', 'present', 'effectiveAlpha', 'geometrySha256', 'shaderSha256',
            'materialSha256', 'textureSha256'
        )
        Assert-PairRequiredProperties $part $properties $partPath $Failures
        Assert-PairAllowedProperties $part $properties $partPath $Failures
        $partId = Get-PairProperty $part 'partId'
        Assert-PairString $partId "$partPath/partId" $Failures $script:PairTokenPattern
        $present = Get-PairProperty $part 'present'
        if ($present -isnot [bool]) {
            Add-PairFailure $Failures "$partPath/present" 'must be a JSON boolean'
            $present = $false
        }
        if (-not $present) {
            Add-PairFailure $Failures "$partPath/present" 'is false; missing geometry is a hard failure'
        }
        $alpha = Get-PairRawFloat (Get-PairProperty $part 'effectiveAlpha') `
            "$partPath/effectiveAlpha" $Failures
        $hashes = [ordered]@{}
        foreach ($name in @('geometrySha256', 'shaderSha256', 'materialSha256', 'textureSha256')) {
            $hash = Get-PairProperty $part $name
            Assert-PairString $hash "$partPath/$name" $Failures $script:PairSha256Pattern
            $hashes[$name] = if ($hash -is [string]) { ([string]$hash).ToUpperInvariant() } else { '' }
        }
        if ($partId -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$partId)) {
            if ($result.ContainsKey([string]$partId)) {
                Add-PairFailure $Failures "$partPath/partId" "duplicates '$partId'"
            }
            else {
                $result.Add([string]$partId, [pscustomobject][ordered]@{
                    present = [bool]$present; alpha = [double]$alpha
                    geometrySha256 = $hashes.geometrySha256
                    shaderSha256 = $hashes.shaderSha256
                    materialSha256 = $hashes.materialSha256
                    textureSha256 = $hashes.textureSha256
                })
            }
        }
    }
    return [pscustomobject][ordered]@{ rootPresent = [bool]$rootPresent; parts = $result }
}

function Convert-PairActor {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, object]]$Plugins,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    $properties = @(
        'reference', 'base', 'actorKind', 'cell', 'worldSpace', 'transform',
        'velocity', 'pathTarget', 'pathTargetReference', 'ai', 'animation',
        'equipment', 'combat', 'dialogue', 'visual'
    )
    Assert-PairRequiredProperties $Value $properties $Path $Failures
    Assert-PairAllowedProperties $Value $properties $Path $Failures
    $reference = Get-PairFormKeyIdentity (Get-PairProperty $Value 'reference') `
        "$Path/reference" $Plugins $Failures
    $base = Get-PairFormKeyIdentity (Get-PairProperty $Value 'base') "$Path/base" $Plugins $Failures
    $actorKind = Get-PairProperty $Value 'actorKind'
    if (@('player', 'npc', 'creature') -notcontains [string]$actorKind) {
        Add-PairFailure $Failures "$Path/actorKind" 'must be player, npc, or creature'
    }
    $cell = Get-PairFormKeyIdentity (Get-PairProperty $Value 'cell') "$Path/cell" `
        $Plugins $Failures -AllowNull
    $worldSpace = Get-PairFormKeyIdentity (Get-PairProperty $Value 'worldSpace') `
        "$Path/worldSpace" $Plugins $Failures -AllowNull
    $transform = Get-PairProperty $Value 'transform'
    Assert-PairRequiredProperties $transform @('position', 'rotation', 'scale') "$Path/transform" $Failures
    Assert-PairAllowedProperties $transform @('position', 'rotation', 'scale') "$Path/transform" $Failures
    $position = Get-PairVector3 (Get-PairProperty $transform 'position') `
        "$Path/transform/position" $Failures
    $rotation = Get-PairVector3 (Get-PairProperty $transform 'rotation') `
        "$Path/transform/rotation" $Failures
    $scale = Get-PairRawFloat (Get-PairProperty $transform 'scale') `
        "$Path/transform/scale" $Failures
    $velocity = Get-PairVector3 (Get-PairProperty $Value 'velocity') "$Path/velocity" $Failures
    $pathTarget = Get-PairVector3 (Get-PairProperty $Value 'pathTarget') `
        "$Path/pathTarget" $Failures -AllowNull
    $pathTargetReference = Get-PairFormKeyIdentity `
        (Get-PairProperty $Value 'pathTargetReference') "$Path/pathTargetReference" `
        $Plugins $Failures -AllowNull

    $ai = Get-PairProperty $Value 'ai'
    Assert-PairRequiredProperties $ai @('package', 'procedure', 'target') "$Path/ai" $Failures
    Assert-PairAllowedProperties $ai @('package', 'procedure', 'target') "$Path/ai" $Failures
    $aiPackage = Get-PairFormKeyIdentity (Get-PairProperty $ai 'package') `
        "$Path/ai/package" $Plugins $Failures -AllowNull
    $aiProcedure = Get-PairProperty $ai 'procedure'
    if ($null -ne $aiProcedure) { Assert-PairString $aiProcedure "$Path/ai/procedure" $Failures }
    $aiTarget = Get-PairFormKeyIdentity (Get-PairProperty $ai 'target') `
        "$Path/ai/target" $Plugins $Failures -AllowNull

    $animation = Get-PairProperty $Value 'animation'
    Assert-PairRequiredProperties $animation @('group', 'key', 'phase', 'tween') `
        "$Path/animation" $Failures
    Assert-PairAllowedProperties $animation @('group', 'key', 'phase', 'tween') `
        "$Path/animation" $Failures
    $animationGroup = Get-PairProperty $animation 'group'
    $animationKey = Get-PairProperty $animation 'key'
    Assert-PairString $animationGroup "$Path/animation/group" $Failures
    Assert-PairString $animationKey "$Path/animation/key" $Failures
    $animationPhase = Get-PairRawFloat (Get-PairProperty $animation 'phase') `
        "$Path/animation/phase" $Failures
    $animationTween = Get-PairRawFloat (Get-PairProperty $animation 'tween') `
        "$Path/animation/tween" $Failures

    $equipment = Convert-PairEquipment (Get-PairProperty $Value 'equipment') `
        "$Path/equipment" $Plugins $Failures
    $combat = Get-PairProperty $Value 'combat'
    Assert-PairRequiredProperties $combat @('inCombat', 'target', 'lifeState') "$Path/combat" $Failures
    Assert-PairAllowedProperties $combat @('inCombat', 'target', 'lifeState') "$Path/combat" $Failures
    $inCombat = Get-PairProperty $combat 'inCombat'
    if ($inCombat -isnot [bool]) {
        Add-PairFailure $Failures "$Path/combat/inCombat" 'must be a JSON boolean'
        $inCombat = $false
    }
    $combatTarget = Get-PairFormKeyIdentity (Get-PairProperty $combat 'target') `
        "$Path/combat/target" $Plugins $Failures -AllowNull
    $lifeState = Get-PairProperty $combat 'lifeState'
    Assert-PairString $lifeState "$Path/combat/lifeState" $Failures

    $dialogue = Get-PairProperty $Value 'dialogue'
    Assert-PairRequiredProperties $dialogue @('active', 'partner', 'topic') "$Path/dialogue" $Failures
    Assert-PairAllowedProperties $dialogue @('active', 'partner', 'topic') "$Path/dialogue" $Failures
    $dialogueActive = Get-PairProperty $dialogue 'active'
    if ($dialogueActive -isnot [bool]) {
        Add-PairFailure $Failures "$Path/dialogue/active" 'must be a JSON boolean'
        $dialogueActive = $false
    }
    $dialoguePartner = Get-PairFormKeyIdentity (Get-PairProperty $dialogue 'partner') `
        "$Path/dialogue/partner" $Plugins $Failures -AllowNull
    $dialogueTopic = Get-PairFormKeyIdentity (Get-PairProperty $dialogue 'topic') `
        "$Path/dialogue/topic" $Plugins $Failures -AllowNull
    $visual = Convert-PairVisual (Get-PairProperty $Value 'visual') "$Path/visual" $Failures

    return [pscustomobject][ordered]@{
        id = $reference; base = $base; actorKind = [string]$actorKind
        cell = $cell; worldSpace = $worldSpace; position = $position; rotation = $rotation
        scale = [double]$scale
        velocity = $velocity; pathTarget = $pathTarget; pathTargetReference = $pathTargetReference
        aiPackage = $aiPackage; aiProcedure = $aiProcedure; aiTarget = $aiTarget
        animationGroup = [string]$animationGroup; animationKey = [string]$animationKey
        animationPhase = [double]$animationPhase; animationTween = [double]$animationTween
        equipment = $equipment; inCombat = [bool]$inCombat; combatTarget = $combatTarget
        lifeState = [string]$lifeState; dialogueActive = [bool]$dialogueActive
        dialoguePartner = $dialoguePartner; dialogueTopic = $dialogueTopic; visual = $visual
    }
}

function Convert-PairFrame {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$GenerationId,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, object]]$Plugins,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, object]]$Artifacts,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    $properties = @(
        'sampleId', 'elapsedSeconds', 'generationId', 'sourceFrame', 'frameStateSha256',
        'screenshotArtifactId', 'actors', 'camera', 'timeWeather'
    )
    Assert-PairRequiredProperties $Value $properties $Path $Failures
    Assert-PairAllowedProperties $Value $properties $Path $Failures
    $sampleId = Get-PairProperty $Value 'sampleId'
    Assert-PairString $sampleId "$Path/sampleId" $Failures $script:PairTokenPattern
    $elapsed = Get-PairProperty $Value 'elapsedSeconds'
    if (-not (Test-PairJsonNumber $elapsed) -or [double]$elapsed -lt 0) {
        Add-PairFailure $Failures "$Path/elapsedSeconds" 'must be a nonnegative number'
        $elapsed = 0
    }
    if ((Get-PairProperty $Value 'generationId') -cne $GenerationId) {
        Add-PairFailure $Failures "$Path/generationId" 'does not match its endpoint generationId'
    }
    $sourceFrame = Get-PairProperty $Value 'sourceFrame'
    if (-not (Test-PairJsonInteger $sourceFrame) -or [int64]$sourceFrame -lt 0) {
        Add-PairFailure $Failures "$Path/sourceFrame" 'must be a nonnegative JSON integer'
        $sourceFrame = 0
    }
    Assert-PairString (Get-PairProperty $Value 'frameStateSha256') `
        "$Path/frameStateSha256" $Failures $script:PairSha256Pattern
    $screenshotId = Get-PairProperty $Value 'screenshotArtifactId'
    Assert-PairString $screenshotId "$Path/screenshotArtifactId" $Failures $script:PairTokenPattern
    $screenshotPath = $null
    if ($screenshotId -is [string] -and $Artifacts.ContainsKey([string]$screenshotId)) {
        $artifact = $Artifacts[[string]$screenshotId]
        if ((Get-PairProperty $artifact 'kind') -ne 'screenshot') {
            Add-PairFailure $Failures "$Path/screenshotArtifactId" 'does not reference a screenshot artifact'
        }
        if ((Get-PairProperty $artifact 'sampleId') -cne $sampleId) {
            Add-PairFailure $Failures "$Path/screenshotArtifactId" `
                'references a screenshot from a different synchronization sample'
        }
        $screenshotPath = Get-PairProperty $artifact '_fullPath'
    }
    elseif ($screenshotId -is [string]) {
        Add-PairFailure $Failures "$Path/screenshotArtifactId" "references missing artifact '$screenshotId'"
    }

    $actorsValue = Get-PairProperty $Value 'actors'
    $actors = Get-PairArray $actorsValue
    if ($actorsValue -is [string] -or $actors.Count -eq 0) {
        Add-PairFailure $Failures "$Path/actors" 'must contain the complete loaded actor/creature set'
    }
    $actorMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $actors.Count; ++$index) {
        $actor = Convert-PairActor $actors[$index] "$Path/actors/$index" $Plugins $Failures
        if (-not [string]::IsNullOrWhiteSpace([string]$actor.id)) {
            if ($actorMap.ContainsKey([string]$actor.id)) {
                Add-PairFailure $Failures "$Path/actors/$index/reference" `
                    "duplicates loaded actor identity '$($actor.id)'"
            }
            else { $actorMap.Add([string]$actor.id, $actor) }
        }
    }

    $camera = Get-PairProperty $Value 'camera'
    Assert-PairRequiredProperties $camera @('position', 'rotation', 'fovDegrees') "$Path/camera" $Failures
    Assert-PairAllowedProperties $camera @('position', 'rotation', 'fovDegrees') "$Path/camera" $Failures
    $cameraPosition = Get-PairVector3 (Get-PairProperty $camera 'position') `
        "$Path/camera/position" $Failures
    $cameraRotation = Get-PairVector3 (Get-PairProperty $camera 'rotation') `
        "$Path/camera/rotation" $Failures
    $fov = Get-PairRawFloat (Get-PairProperty $camera 'fovDegrees') "$Path/camera/fovDegrees" $Failures

    $timeWeather = Get-PairProperty $Value 'timeWeather'
    $timeProperties = @('gameHour', 'timeScale', 'currentWeather', 'previousWeather', 'transition')
    Assert-PairRequiredProperties $timeWeather $timeProperties "$Path/timeWeather" $Failures
    Assert-PairAllowedProperties $timeWeather $timeProperties "$Path/timeWeather" $Failures
    $gameHour = Get-PairRawFloat (Get-PairProperty $timeWeather 'gameHour') `
        "$Path/timeWeather/gameHour" $Failures
    $timeScale = Get-PairRawFloat (Get-PairProperty $timeWeather 'timeScale') `
        "$Path/timeWeather/timeScale" $Failures
    $currentWeather = Get-PairFormKeyIdentity (Get-PairProperty $timeWeather 'currentWeather') `
        "$Path/timeWeather/currentWeather" $Plugins $Failures -AllowNull
    $previousWeather = Get-PairFormKeyIdentity (Get-PairProperty $timeWeather 'previousWeather') `
        "$Path/timeWeather/previousWeather" $Plugins $Failures -AllowNull
    $weatherTransition = Get-PairRawFloat (Get-PairProperty $timeWeather 'transition') `
        "$Path/timeWeather/transition" $Failures

    return [pscustomobject][ordered]@{
        sampleId = [string]$sampleId; elapsed = [double]$elapsed; sourceFrame = [int64]$sourceFrame
        screenshotPath = [string]$screenshotPath; actors = $actorMap
        cameraPosition = $cameraPosition; cameraRotation = $cameraRotation; fov = [double]$fov
        gameHour = [double]$gameHour; timeScale = [double]$timeScale
        currentWeather = $currentWeather; previousWeather = $previousWeather
        weatherTransition = [double]$weatherTransition
    }
}

function Convert-PairEndpoint {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Lane,
        [Parameter(Mandatory)][string]$PairDirectory,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, object]]$Plugins,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    $path = "/$Lane"
    $properties = @('generationId', 'traceArtifactId', 'artifacts', 'frames')
    Assert-PairRequiredProperties $Value $properties $path $Failures
    Assert-PairAllowedProperties $Value $properties $path $Failures
    $generationId = Get-PairProperty $Value 'generationId'
    Assert-PairString $generationId "$path/generationId" $Failures $script:PairTokenPattern
    $artifactValues = Get-PairProperty $Value 'artifacts'
    $artifacts = Get-PairArray $artifactValues
    if ($artifactValues -is [string] -or $artifacts.Count -lt 3) {
        Add-PairFailure $Failures "$path/artifacts" 'must contain a trace and at least two screenshots'
    }
    $artifactMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $artifactPathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pairDirectoryPrefix = $PairDirectory.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    for ($index = 0; $index -lt $artifacts.Count; ++$index) {
        $artifact = $artifacts[$index]
        $artifactPath = "$path/artifacts/$index"
        $properties = @('id', 'kind', 'path', 'bytes', 'sha256', 'generationId', 'mediaType', 'sampleId')
        Assert-PairRequiredProperties $artifact `
            @('id', 'kind', 'path', 'bytes', 'sha256', 'generationId', 'mediaType') `
            $artifactPath $Failures
        Assert-PairAllowedProperties $artifact $properties $artifactPath $Failures
        $id = Get-PairProperty $artifact 'id'
        Assert-PairString $id "$artifactPath/id" $Failures $script:PairTokenPattern
        $kind = Get-PairProperty $artifact 'kind'
        if (@('trace', 'screenshot') -notcontains [string]$kind) {
            Add-PairFailure $Failures "$artifactPath/kind" 'must be trace or screenshot'
        }
        if ((Get-PairProperty $artifact 'generationId') -cne $generationId) {
            Add-PairFailure $Failures "$artifactPath/generationId" 'does not match endpoint generationId'
        }
        if ($kind -eq 'screenshot') {
            Assert-PairString (Get-PairProperty $artifact 'sampleId') "$artifactPath/sampleId" `
                $Failures $script:PairTokenPattern
        }
        $relative = Get-PairProperty $artifact 'path'
        Assert-PairString $relative "$artifactPath/path" $Failures
        $portable = $false
        $fullArtifactPath = $null
        if ($relative -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$relative)) {
            $segments = @(([string]$relative) -split '[\\/]')
            $portable = -not [IO.Path]::IsPathRooted([string]$relative) -and
                $segments -notcontains '' -and $segments -notcontains '.' -and $segments -notcontains '..'
            if (-not $portable) {
                Add-PairFailure $Failures "$artifactPath/path" `
                    'must be a normalized relative path without traversal'
            }
            elseif (-not $artifactPathSet.Add([string]$relative)) {
                Add-PairFailure $Failures "$artifactPath/path" "duplicates '$relative'"
            }
            else {
                $fullArtifactPath = [IO.Path]::GetFullPath((Join-Path $PairDirectory ([string]$relative)))
                $normalizedRelative = ([string]$relative).Replace('\', '/').ToLowerInvariant()
                $expectedLanePrefix = $Lane.ToLowerInvariant() + '/'
                if (-not $normalizedRelative.StartsWith(
                    $expectedLanePrefix, [StringComparison]::Ordinal)) {
                    Add-PairFailure $Failures "$artifactPath/path" `
                        "must remain under the endpoint directory '$expectedLanePrefix'"
                }
                if (-not $fullArtifactPath.StartsWith($pairDirectoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    Add-PairFailure $Failures "$artifactPath/path" 'resolves outside the pair directory'
                    $portable = $false
                }
            }
        }
        $bytes = Get-PairProperty $artifact 'bytes'
        if (-not (Test-PairJsonInteger $bytes) -or [int64]$bytes -lt 1) {
            Add-PairFailure $Failures "$artifactPath/bytes" 'must be a positive JSON integer'
        }
        $sha = Get-PairProperty $artifact 'sha256'
        Assert-PairString $sha "$artifactPath/sha256" $Failures $script:PairSha256Pattern
        Assert-PairString (Get-PairProperty $artifact 'mediaType') "$artifactPath/mediaType" $Failures
        $mediaType = Get-PairProperty $artifact 'mediaType'
        if ($kind -eq 'screenshot' -and
            ($mediaType -isnot [string] -or -not ([string]$mediaType).StartsWith('image/', [StringComparison]::OrdinalIgnoreCase))) {
            Add-PairFailure $Failures "$artifactPath/mediaType" `
                'must be an image media type for a screenshot artifact'
        }
        if ($portable) {
            if (-not (Test-Path -LiteralPath $fullArtifactPath -PathType Leaf)) {
                Add-PairFailure $Failures "$artifactPath/path" "artifact is missing at '$fullArtifactPath'"
            }
            else {
                $file = Get-Item -LiteralPath $fullArtifactPath
                if ((Test-PairJsonInteger $bytes) -and [int64]$file.Length -ne [int64]$bytes) {
                    Add-PairFailure $Failures "$artifactPath/bytes" `
                        "does not match file length $($file.Length)"
                }
                $observedSha = (Get-FileHash -LiteralPath $fullArtifactPath -Algorithm SHA256).Hash
                if ($sha -is [string] -and $observedSha -cne ([string]$sha).ToUpperInvariant()) {
                    Add-PairFailure $Failures "$artifactPath/sha256" `
                        "does not match file SHA-256 $observedSha"
                }
            }
        }
        if ($id -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$id)) {
            if ($artifactMap.ContainsKey([string]$id)) {
                Add-PairFailure $Failures "$artifactPath/id" "duplicates '$id'"
            }
            else {
                $normalizedArtifact = [pscustomobject][ordered]@{}
                foreach ($property in @($artifact.PSObject.Properties)) {
                    $normalizedArtifact | Add-Member -NotePropertyName $property.Name `
                        -NotePropertyValue $property.Value
                }
                $normalizedArtifact | Add-Member -NotePropertyName '_fullPath' `
                    -NotePropertyValue $fullArtifactPath
                $artifactMap.Add([string]$id, $normalizedArtifact)
            }
        }
    }
    $traceId = Get-PairProperty $Value 'traceArtifactId'
    Assert-PairString $traceId "$path/traceArtifactId" $Failures $script:PairTokenPattern
    if ($traceId -is [string] -and $artifactMap.ContainsKey([string]$traceId)) {
        if ((Get-PairProperty $artifactMap[[string]$traceId] 'kind') -ne 'trace') {
            Add-PairFailure $Failures "$path/traceArtifactId" 'does not reference a trace artifact'
        }
    }
    elseif ($traceId -is [string]) {
        Add-PairFailure $Failures "$path/traceArtifactId" "references missing artifact '$traceId'"
    }

    $frameValues = Get-PairProperty $Value 'frames'
    $frames = Get-PairArray $frameValues
    if ($frameValues -is [string] -or $frames.Count -lt 2) {
        Add-PairFailure $Failures "$path/frames" 'must contain at least two synchronized frames'
    }
    $frameMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $orderedFrames = [Collections.Generic.List[object]]::new()
    $previousElapsed = [double]-1
    for ($index = 0; $index -lt $frames.Count; ++$index) {
        $frame = Convert-PairFrame $frames[$index] "$path/frames/$index" `
            ([string]$generationId) $Plugins $artifactMap $Failures
        if ($index -gt 0 -and $frame.elapsed -le $previousElapsed) {
            Add-PairFailure $Failures "$path/frames/$index/elapsedSeconds" `
                'must be strictly greater than the preceding frame'
        }
        $previousElapsed = $frame.elapsed
        if (-not [string]::IsNullOrWhiteSpace([string]$frame.sampleId)) {
            if ($frameMap.ContainsKey([string]$frame.sampleId)) {
                Add-PairFailure $Failures "$path/frames/$index/sampleId" `
                    "duplicates '$($frame.sampleId)'"
            }
            else { $frameMap.Add([string]$frame.sampleId, $frame) }
        }
        $orderedFrames.Add($frame) | Out-Null
    }
    if ($orderedFrames.Count -ge 2 -and
        ($orderedFrames[$orderedFrames.Count - 1].elapsed - $orderedFrames[0].elapsed) -lt 3) {
        Add-PairFailure $Failures "$path/frames" 'must span at least three seconds'
    }
    return [pscustomobject][ordered]@{
        generationId = [string]$generationId; artifacts = $artifactMap
        frames = $frameMap; orderedFrames = $orderedFrames
    }
}

function Compare-PairExact {
    param(
        [AllowNull()][object]$Retail,
        [AllowNull()][object]$OpenMw,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    if ($null -eq $Retail -and $null -eq $OpenMw) { return }
    if ($null -eq $Retail -or $null -eq $OpenMw -or [string]$Retail -cne [string]$OpenMw) {
        Add-PairFailure $Failures $Path "retail '$Retail' does not equal OpenMW '$OpenMw'"
    }
}

function Compare-PairScalar {
    param(
        [double]$Retail,
        [double]$OpenMw,
        [double]$Tolerance,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures,
        [switch]$CyclicUnit,
        [double]$Cycle = 0
    )
    $delta = [Math]::Abs($Retail - $OpenMw)
    if ($CyclicUnit) {
        $delta %= 1.0
        $delta = [Math]::Min($delta, 1.0 - $delta)
    }
    elseif ($Cycle -gt 0) {
        $delta %= $Cycle
        $delta = [Math]::Min($delta, $Cycle - $delta)
    }
    if ($delta -gt $Tolerance) {
        Add-PairFailure $Failures $Path `
            "absolute delta $delta exceeds tolerance $Tolerance (retail=$Retail, OpenMW=$OpenMw)"
    }
}

function Compare-PairVector {
    param(
        [AllowNull()][double[]]$Retail,
        [AllowNull()][double[]]$OpenMw,
        [double]$Tolerance,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures,
        [switch]$Angles
    )
    if ($null -eq $Retail -and $null -eq $OpenMw) { return }
    if ($null -eq $Retail -or $null -eq $OpenMw) {
        Add-PairFailure $Failures $Path 'is null in only one endpoint'
        return
    }
    foreach ($index in 0..2) {
        $delta = [Math]::Abs($Retail[$index] - $OpenMw[$index])
        if ($Angles) {
            $cycle = 2 * [Math]::PI
            $delta %= $cycle
            $delta = [Math]::Min($delta, $cycle - $delta)
        }
        if ($delta -gt $Tolerance) {
            Add-PairFailure $Failures "$Path/$(@('x','y','z')[$index])" `
                "absolute delta $delta exceeds tolerance $Tolerance"
        }
    }
}

function Compare-PairDictionarySets {
    param(
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, object]]$Retail,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, object]]$OpenMw,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EntityName,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    foreach ($key in $Retail.Keys) {
        if (-not $OpenMw.ContainsKey($key)) {
            Add-PairFailure $Failures $Path "OpenMW is missing $EntityName '$key'"
        }
    }
    foreach ($key in $OpenMw.Keys) {
        if (-not $Retail.ContainsKey($key)) {
            Add-PairFailure $Failures $Path "OpenMW has unexpected $EntityName '$key'"
        }
    }
}

function Compare-PairActor {
    param(
        [Parameter(Mandatory)][object]$Retail,
        [Parameter(Mandatory)][object]$OpenMw,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Tolerances,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    Compare-PairExact $Retail.base $OpenMw.base "$Path/base" $Failures
    Compare-PairExact $Retail.actorKind $OpenMw.actorKind "$Path/actorKind" $Failures
    Compare-PairExact $Retail.cell $OpenMw.cell "$Path/cell" $Failures
    Compare-PairExact $Retail.worldSpace $OpenMw.worldSpace "$Path/worldSpace" $Failures
    Compare-PairVector $Retail.position $OpenMw.position $Tolerances.positionAbsoluteMaximum `
        "$Path/transform/position" $Failures
    Compare-PairVector $Retail.rotation $OpenMw.rotation $Tolerances.rotationRadiansMaximum `
        "$Path/transform/rotation" $Failures -Angles
    Compare-PairScalar $Retail.scale $OpenMw.scale $Tolerances.scaleAbsoluteMaximum `
        "$Path/transform/scale" $Failures
    Compare-PairVector $Retail.velocity $OpenMw.velocity $Tolerances.velocityAbsoluteMaximum `
        "$Path/velocity" $Failures
    Compare-PairVector $Retail.pathTarget $OpenMw.pathTarget $Tolerances.targetPositionAbsoluteMaximum `
        "$Path/pathTarget" $Failures
    Compare-PairExact $Retail.pathTargetReference $OpenMw.pathTargetReference `
        "$Path/pathTargetReference" $Failures
    Compare-PairExact $Retail.aiPackage $OpenMw.aiPackage "$Path/ai/package" $Failures
    Compare-PairExact $Retail.aiProcedure $OpenMw.aiProcedure "$Path/ai/procedure" $Failures
    Compare-PairExact $Retail.aiTarget $OpenMw.aiTarget "$Path/ai/target" $Failures
    Compare-PairExact $Retail.animationGroup $OpenMw.animationGroup "$Path/animation/group" $Failures
    Compare-PairExact $Retail.animationKey $OpenMw.animationKey "$Path/animation/key" $Failures
    Compare-PairScalar $Retail.animationPhase $OpenMw.animationPhase `
        $Tolerances.animationPhaseMaximum "$Path/animation/phase" $Failures -CyclicUnit
    Compare-PairScalar $Retail.animationTween $OpenMw.animationTween `
        $Tolerances.animationTweenMaximum "$Path/animation/tween" $Failures

    Compare-PairDictionarySets $Retail.equipment $OpenMw.equipment "$Path/equipment" `
        'equipment instance' $Failures
    foreach ($instanceId in $Retail.equipment.Keys) {
        if (-not $OpenMw.equipment.ContainsKey($instanceId)) { continue }
        $retailItem = $Retail.equipment[$instanceId]
        $openMwItem = $OpenMw.equipment[$instanceId]
        $itemPath = "$Path/equipment/$instanceId"
        Compare-PairExact $retailItem.form $openMwItem.form "$itemPath/form" $Failures
        Compare-PairExact $retailItem.slot $openMwItem.slot "$itemPath/slot" $Failures
        Compare-PairExact $retailItem.count $openMwItem.count "$itemPath/count" $Failures
        Compare-PairScalar $retailItem.condition $openMwItem.condition `
            $Tolerances.conditionAbsoluteMaximum "$itemPath/condition" $Failures
        Compare-PairExact $retailItem.equipped $openMwItem.equipped "$itemPath/equipped" $Failures
    }
    Compare-PairExact $Retail.inCombat $OpenMw.inCombat "$Path/combat/inCombat" $Failures
    Compare-PairExact $Retail.combatTarget $OpenMw.combatTarget "$Path/combat/target" $Failures
    Compare-PairExact $Retail.lifeState $OpenMw.lifeState "$Path/combat/lifeState" $Failures
    Compare-PairExact $Retail.dialogueActive $OpenMw.dialogueActive "$Path/dialogue/active" $Failures
    Compare-PairExact $Retail.dialoguePartner $OpenMw.dialoguePartner "$Path/dialogue/partner" $Failures
    Compare-PairExact $Retail.dialogueTopic $OpenMw.dialogueTopic "$Path/dialogue/topic" $Failures
    if (-not $Retail.visual.rootPresent -or -not $OpenMw.visual.rootPresent) {
        Add-PairFailure $Failures "$Path/visual/rootPresent" 'missing actor root is a hard failure'
    }
    Compare-PairDictionarySets $Retail.visual.parts $OpenMw.visual.parts "$Path/visual/parts" `
        'geometry part' $Failures
    foreach ($partId in $Retail.visual.parts.Keys) {
        if (-not $OpenMw.visual.parts.ContainsKey($partId)) { continue }
        $retailPart = $Retail.visual.parts[$partId]
        $openMwPart = $OpenMw.visual.parts[$partId]
        $partPath = "$Path/visual/parts/$partId"
        if (-not $retailPart.present -or -not $openMwPart.present) {
            Add-PairFailure $Failures "$partPath/present" 'missing geometry is a hard failure'
        }
        Compare-PairScalar $retailPart.alpha $openMwPart.alpha $Tolerances.alphaAbsoluteMaximum `
            "$partPath/effectiveAlpha" $Failures
        foreach ($name in @('geometrySha256', 'shaderSha256', 'materialSha256', 'textureSha256')) {
            Compare-PairExact $retailPart.$name $openMwPart.$name "$partPath/$name" $Failures
        }
    }
}

function Compare-PairScreenshot {
    param(
        [Parameter(Mandatory)][string]$RetailPath,
        [Parameter(Mandatory)][string]$OpenMwPath,
        [double]$MaeMaximum,
        [double]$RmseMaximum,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )
    if ([string]::IsNullOrWhiteSpace($RetailPath) -or [string]::IsNullOrWhiteSpace($OpenMwPath)) {
        Add-PairFailure $Failures $Path 'is missing one or both synchronized screenshot artifacts'
        return $null
    }
    if ([string]::Equals(
        [IO.Path]::GetFullPath($RetailPath), [IO.Path]::GetFullPath($OpenMwPath),
        [StringComparison]::OrdinalIgnoreCase)) {
        Add-PairFailure $Failures $Path 'retail and OpenMW screenshots resolve to the same artifact'
        return $null
    }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $retailImage = [Drawing.Bitmap]::FromFile($RetailPath)
        $openMwImage = [Drawing.Bitmap]::FromFile($OpenMwPath)
        try {
            if ($retailImage.Width -ne $openMwImage.Width -or $retailImage.Height -ne $openMwImage.Height) {
                Add-PairFailure $Failures $Path `
                    "image dimensions differ: retail $($retailImage.Width)x$($retailImage.Height), OpenMW $($openMwImage.Width)x$($openMwImage.Height)"
                return $null
            }
            $absoluteSum = [double]0
            $squareSum = [double]0
            $sampleCount = [int64]$retailImage.Width * [int64]$retailImage.Height * 4
            for ($y = 0; $y -lt $retailImage.Height; ++$y) {
                for ($x = 0; $x -lt $retailImage.Width; ++$x) {
                    $a = $retailImage.GetPixel($x, $y)
                    $b = $openMwImage.GetPixel($x, $y)
                    foreach ($delta in @(
                        ([int]$a.R - [int]$b.R), ([int]$a.G - [int]$b.G),
                        ([int]$a.B - [int]$b.B), ([int]$a.A - [int]$b.A))) {
                        $absoluteSum += [Math]::Abs($delta)
                        $squareSum += [double]$delta * [double]$delta
                    }
                }
            }
            $mae = $absoluteSum / ($sampleCount * 255.0)
            $rmse = [Math]::Sqrt($squareSum / $sampleCount) / 255.0
            if ($mae -gt $MaeMaximum) {
                Add-PairFailure $Failures "$Path/pixelMae" `
                    "value $mae exceeds tolerance $MaeMaximum"
            }
            if ($rmse -gt $RmseMaximum) {
                Add-PairFailure $Failures "$Path/pixelRmse" `
                    "value $rmse exceeds tolerance $RmseMaximum"
            }
            return [pscustomobject][ordered]@{ pixelMae = $mae; pixelRmse = $rmse }
        }
        finally {
            $retailImage.Dispose()
            $openMwImage.Dispose()
        }
    }
    catch {
        Add-PairFailure $Failures $Path "could not decode synchronized images: $($_.Exception.Message)"
        return $null
    }
}

function Compare-FNVRetailOpenMWCheckpointPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "FNV checkpoint pair does not exist: $fullPath"
    }
    try { $document = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json }
    catch { throw "FNV checkpoint pair is not valid JSON: $($_.Exception.Message)" }
    if ($null -eq $document -or $document -isnot [pscustomobject]) {
        throw 'FNV checkpoint pair root must be a JSON object.'
    }
    $failures = [Collections.Generic.List[string]]::new()
    $topProperties = @('schema', 'pairId', 'loadOrder', 'tolerances', 'coverageLedger', 'retail', 'openMw')
    Assert-PairRequiredProperties $document $topProperties '/' $failures
    Assert-PairAllowedProperties $document $topProperties '/' $failures
    if ((Get-PairProperty $document 'schema') -ne $script:PairSchema) {
        Add-PairFailure $failures '/schema' "must equal '$script:PairSchema'"
    }
    $pairId = Get-PairProperty $document 'pairId'
    Assert-PairString $pairId '/pairId' $failures $script:PairTokenPattern
    $plugins = Get-PairPluginMap (Get-PairProperty $document 'loadOrder') $failures
    $tolerances = Get-PairTolerances (Get-PairProperty $document 'tolerances') $failures
    Assert-PairCoverageLedger (Get-PairProperty $document 'coverageLedger') $failures
    $pairDirectory = [IO.Path]::GetDirectoryName($fullPath)
    $retail = Convert-PairEndpoint (Get-PairProperty $document 'retail') 'retail' `
        $pairDirectory $plugins $failures
    $openMw = Convert-PairEndpoint (Get-PairProperty $document 'openMw') 'openMw' `
        $pairDirectory $plugins $failures
    if ($retail.generationId -ceq $openMw.generationId) {
        Add-PairFailure $failures '/openMw/generationId' `
            'must be distinct from the retail generationId'
    }

    Compare-PairDictionarySets $retail.frames $openMw.frames '/frames' 'synchronized sample' $failures
    $comparedFrames = 0
    $comparedActorSamples = 0
    $visualMetrics = [Collections.Generic.List[object]]::new()
    foreach ($sampleId in $retail.frames.Keys) {
        if (-not $openMw.frames.ContainsKey($sampleId)) { continue }
        ++$comparedFrames
        $retailFrame = $retail.frames[$sampleId]
        $openMwFrame = $openMw.frames[$sampleId]
        $framePath = "/frames/$sampleId"
        Compare-PairScalar $retailFrame.elapsed $openMwFrame.elapsed `
            $tolerances.frameSyncSecondsMaximum "$framePath/elapsedSeconds" $failures
        Compare-PairDictionarySets $retailFrame.actors $openMwFrame.actors `
            "$framePath/actors" 'loaded actor/creature' $failures
        foreach ($actorId in $retailFrame.actors.Keys) {
            if (-not $openMwFrame.actors.ContainsKey($actorId)) { continue }
            ++$comparedActorSamples
            Compare-PairActor $retailFrame.actors[$actorId] $openMwFrame.actors[$actorId] `
                "$framePath/actors/$actorId" $tolerances $failures
        }
        Compare-PairVector $retailFrame.cameraPosition $openMwFrame.cameraPosition `
            $tolerances.cameraPositionAbsoluteMaximum "$framePath/camera/position" $failures
        Compare-PairVector $retailFrame.cameraRotation $openMwFrame.cameraRotation `
            $tolerances.cameraRotationRadiansMaximum "$framePath/camera/rotation" $failures -Angles
        Compare-PairScalar $retailFrame.fov $openMwFrame.fov $tolerances.fovAbsoluteMaximum `
            "$framePath/camera/fovDegrees" $failures
        Compare-PairScalar $retailFrame.gameHour $openMwFrame.gameHour `
            $tolerances.gameHourMaximum "$framePath/timeWeather/gameHour" $failures -Cycle 24
        Compare-PairScalar $retailFrame.timeScale $openMwFrame.timeScale `
            $tolerances.timeScaleMaximum "$framePath/timeWeather/timeScale" $failures
        Compare-PairExact $retailFrame.currentWeather $openMwFrame.currentWeather `
            "$framePath/timeWeather/currentWeather" $failures
        Compare-PairExact $retailFrame.previousWeather $openMwFrame.previousWeather `
            "$framePath/timeWeather/previousWeather" $failures
        Compare-PairScalar $retailFrame.weatherTransition $openMwFrame.weatherTransition `
            $tolerances.weatherTransitionMaximum "$framePath/timeWeather/transition" $failures
        $metrics = Compare-PairScreenshot $retailFrame.screenshotPath $openMwFrame.screenshotPath `
            $tolerances.pixelMaeMaximum $tolerances.pixelRmseMaximum `
            "$framePath/screenshot" $failures
        if ($null -ne $metrics) {
            $visualMetrics.Add([pscustomobject][ordered]@{
                sampleId = $sampleId; pixelMae = $metrics.pixelMae; pixelRmse = $metrics.pixelRmse
            }) | Out-Null
        }
    }
    if ($failures.Count -gt 0) {
        throw "FNV retail/OpenMW checkpoint comparison failed:`n - $($failures -join "`n - ")"
    }
    return [pscustomobject][ordered]@{
        schema = 'nikami-fnv-retail-openmw-checkpoint-comparison-result/v1'
        pairId = [string]$pairId
        status = 'pass'
        comparedFrames = $comparedFrames
        comparedActorSamples = $comparedActorSamples
        coverageCategories = $script:PairRequiredLedgerPaths.Count
        visualMetrics = @($visualMetrics)
    }
}

Export-ModuleMember -Function 'Compare-FNVRetailOpenMWCheckpointPair'
