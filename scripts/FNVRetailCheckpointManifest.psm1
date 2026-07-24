Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FNVCheckpointSchema = 'nikami-fnv-retail-checkpoint/v1'
$script:FNVCheckpointRuntime = 'FalloutNV-1.4.0.525'
$script:FNVCheckpointGenerationPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$'
$script:FNVCheckpointSha256Pattern = '^[0-9A-Fa-f]{64}$'

$script:FNVCheckpointRequiredActorChannels = @(
    'plugin-qualified-identity'
    'cell-world'
    'transform'
    'velocity'
    'path-target'
    'ai-package-procedure'
    'animation-group-key-phase-tween'
    'equipment'
    'combat'
    'dialogue'
    'visual-root-geometry-alpha-shader-material-texture'
)

$script:FNVCheckpointRequiredFrameChannels = @(
    'camera'
    'time'
    'weather'
    'frame-state-sha256'
    'screenshot-sha256'
    'generation-id'
)

$script:FNVCheckpointVisualHardFailureCategories = @(
    'missing-loaded-actor'
    'unexpected-loaded-actor'
    'missing-actor-root'
    'missing-required-geometry'
    'unexpected-alpha-visibility'
    'geometry-signature-mismatch'
    'shader-signature-mismatch'
    'material-signature-mismatch'
    'texture-signature-mismatch'
)

# These are deliberately category-sized paths. Exporters may add finer entries,
# but none of these roots may disappear merely because a reader is unfinished.
$script:FNVCheckpointRequiredLedgerPaths = @(
    '/snapshot/player/identity'
    '/snapshot/player/level'
    '/snapshot/player/xp'
    '/snapshot/player/actorValues'
    '/snapshot/player/limbs'
    '/snapshot/player/perks'
    '/snapshot/player/inventory'
    '/snapshot/player/location'
    '/snapshot/player/factions'
    '/snapshot/player/reputation'
    '/snapshot/quests/stages'
    '/snapshot/quests/objectives'
    '/snapshot/quests/variables'
    '/snapshot/globals'
    '/snapshot/timeWeather'
    '/snapshot/mapMarkers'
    '/snapshot/worldChanges/doors'
    '/snapshot/worldChanges/containers'
    '/snapshot/worldChanges/actors'
    '/snapshot/worldChanges/unloaded'
    '/snapshot/worldChanges/dynamicForms'
    '/trace/loadedActors/identity'
    '/trace/loadedActors/cellTransform'
    '/trace/loadedActors/velocityPath'
    '/trace/loadedActors/aiPackageProcedure'
    '/trace/loadedActors/animation'
    '/trace/loadedActors/equipment'
    '/trace/loadedActors/combatDialogue'
    '/trace/loadedActors/visual'
    '/trace/frame/camera'
    '/trace/frame/timeWeather'
    '/trace/frame/hashesScreenshots'
)

function Get-FNVCheckpointProperty {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-FNVCheckpointHasProperty {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Add-FNVCheckpointFailure {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $Failures.Add("${Path}: $Message") | Out-Null
}

function Test-FNVCheckpointJsonInteger {
    param([AllowNull()][object]$Value)

    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Test-FNVCheckpointJsonNumber {
    param([AllowNull()][object]$Value)

    return (Test-FNVCheckpointJsonInteger $Value) -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
}

function Test-FNVCheckpointUtcTimestamp {
    param([AllowNull()][object]$Value)

    if ($Value -isnot [string] -or $Value -notmatch 'Z$') { return $false }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed) -and $parsed.Offset -eq [TimeSpan]::Zero
}

function Assert-FNVCheckpointRequiredProperties {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string[]]$Names,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )

    if ($null -eq $Object) {
        Add-FNVCheckpointFailure $Failures $Path 'is missing or null'
        return
    }
    foreach ($name in $Names) {
        if (-not (Test-FNVCheckpointHasProperty $Object $name)) {
            Add-FNVCheckpointFailure $Failures $Path "is missing required property '$name'"
        }
    }
}

function Assert-FNVCheckpointAllowedProperties {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string[]]$Names,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )

    if ($null -eq $Object) { return }
    foreach ($property in @($Object.PSObject.Properties)) {
        if ($Names -notcontains [string]$property.Name) {
            Add-FNVCheckpointFailure $Failures $Path "contains unknown property '$($property.Name)'"
        }
    }
}

function Assert-FNVCheckpointString {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures,

        [string]$Pattern = '',

        [switch]$AllowEmpty
    )

    if ($Value -isnot [string]) {
        Add-FNVCheckpointFailure $Failures $Path 'must be a JSON string'
        return
    }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string]$Value)) {
        Add-FNVCheckpointFailure $Failures $Path 'must not be empty'
        return
    }
    if (-not [string]::IsNullOrEmpty($Pattern) -and [string]$Value -notmatch $Pattern) {
        Add-FNVCheckpointFailure $Failures $Path "does not match required pattern '$Pattern'"
    }
}

function Assert-FNVCheckpointRawFloat {
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )

    Assert-FNVCheckpointRequiredProperties $Value @('value', 'bitsHex') $Path $Failures
    Assert-FNVCheckpointAllowedProperties $Value @('value', 'bitsHex') $Path $Failures
    if ($null -eq $Value) { return }

    $bitsText = Get-FNVCheckpointProperty $Value 'bitsHex'
    $displayValue = Get-FNVCheckpointProperty $Value 'value'
    if ($bitsText -isnot [string] -or [string]$bitsText -notmatch '^0[xX](?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{16})$') {
        Add-FNVCheckpointFailure $Failures "$Path/bitsHex" 'must contain exactly 8 or 16 hexadecimal IEEE-754 bytes'
        return
    }

    try {
        if ([string]$bitsText -match '^0[xX][0-9A-Fa-f]{8}$') {
            $bits = [Convert]::ToUInt32(([string]$bitsText).Substring(2), 16)
            $decoded = [BitConverter]::ToSingle([BitConverter]::GetBytes($bits), 0)
            $nonFinite = [single]::IsNaN($decoded) -or [single]::IsInfinity($decoded)
            if ($nonFinite) {
                if ($null -ne $displayValue) {
                    Add-FNVCheckpointFailure $Failures "$Path/value" 'must be null when bitsHex encodes NaN or infinity'
                }
            }
            elseif ($null -eq $displayValue -or -not (Test-FNVCheckpointJsonNumber $displayValue)) {
                Add-FNVCheckpointFailure $Failures "$Path/value" 'must be a number when bitsHex encodes a finite float32'
            }
            else {
                $displayBits = [BitConverter]::ToUInt32(
                    [BitConverter]::GetBytes([single]$displayValue), 0)
                $negativeZeroDisplay = $bits -eq [uint32]2147483648 -and [double]$displayValue -eq 0
                if ($displayBits -ne $bits -and -not $negativeZeroDisplay) {
                    Add-FNVCheckpointFailure $Failures "$Path/value" `
                        "does not round-trip to authoritative float32 bits $bitsText"
                }
            }
        }
        else {
            $bits = [Convert]::ToUInt64(([string]$bitsText).Substring(2), 16)
            $decoded = [BitConverter]::ToDouble([BitConverter]::GetBytes($bits), 0)
            $nonFinite = [double]::IsNaN($decoded) -or [double]::IsInfinity($decoded)
            if ($nonFinite) {
                if ($null -ne $displayValue) {
                    Add-FNVCheckpointFailure $Failures "$Path/value" 'must be null when bitsHex encodes NaN or infinity'
                }
            }
            elseif ($null -eq $displayValue -or -not (Test-FNVCheckpointJsonNumber $displayValue)) {
                Add-FNVCheckpointFailure $Failures "$Path/value" 'must be a number when bitsHex encodes a finite float64'
            }
            else {
                $displayBits = [BitConverter]::ToUInt64(
                    [BitConverter]::GetBytes([double]$displayValue), 0)
                $negativeZeroDisplay = $bits -eq [uint64]9223372036854775808 -and [double]$displayValue -eq 0
                if ($displayBits -ne $bits -and -not $negativeZeroDisplay) {
                    Add-FNVCheckpointFailure $Failures "$Path/value" `
                        "does not round-trip to authoritative float64 bits $bitsText"
                }
            }
        }
    }
    catch {
        Add-FNVCheckpointFailure $Failures $Path "could not decode bitsHex: $($_.Exception.Message)"
    }
}

function Assert-FNVCheckpointFormKey {
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, object]]$Plugins,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )

    $kind = Get-FNVCheckpointProperty $Value 'kind'
    if ($kind -eq 'plugin') {
        $allowed = @('kind', 'originPlugin', 'localFormId', 'winningPlugin', 'runtimeFormId')
        Assert-FNVCheckpointRequiredProperties $Value $allowed $Path $Failures
        Assert-FNVCheckpointAllowedProperties $Value $allowed $Path $Failures

        $origin = [string](Get-FNVCheckpointProperty $Value 'originPlugin')
        $winner = [string](Get-FNVCheckpointProperty $Value 'winningPlugin')
        $local = Get-FNVCheckpointProperty $Value 'localFormId'
        $runtime = Get-FNVCheckpointProperty $Value 'runtimeFormId'
        Assert-FNVCheckpointString $origin "$Path/originPlugin" $Failures
        Assert-FNVCheckpointString $winner "$Path/winningPlugin" $Failures
        Assert-FNVCheckpointString $local "$Path/localFormId" $Failures '^0[xX][0-9A-Fa-f]{6}$'
        Assert-FNVCheckpointString $runtime "$Path/runtimeFormId" $Failures '^0[xX][0-9A-Fa-f]{8}$'

        if (-not $Plugins.ContainsKey($origin)) {
            Add-FNVCheckpointFailure $Failures "$Path/originPlugin" "does not name a plugin in identity.loadOrder"
        }
        if (-not $Plugins.ContainsKey($winner)) {
            Add-FNVCheckpointFailure $Failures "$Path/winningPlugin" "does not name a plugin in identity.loadOrder"
        }
        if ($Plugins.ContainsKey($origin) -and $Plugins.ContainsKey($winner)) {
            $originIndex = [int](Get-FNVCheckpointProperty $Plugins[$origin] 'index')
            $winnerIndex = [int](Get-FNVCheckpointProperty $Plugins[$winner] 'index')
            if ($winnerIndex -lt $originIndex) {
                Add-FNVCheckpointFailure $Failures "$Path/winningPlugin" `
                    'cannot precede the origin plugin in the ordered load order'
            }
            if ($local -is [string] -and [string]$local -match '^0[xX][0-9A-Fa-f]{6}$' -and
                $runtime -is [string] -and [string]$runtime -match '^0[xX][0-9A-Fa-f]{8}$') {
                $runtimeNumber = [Convert]::ToUInt32(([string]$runtime).Substring(2), 16)
                $localNumber = [Convert]::ToUInt32(([string]$local).Substring(2), 16)
                $expected = [uint32]((([uint64]$originIndex) -shl 24) -bor [uint64]$localNumber)
                if ($runtimeNumber -ne $expected) {
                    Add-FNVCheckpointFailure $Failures "$Path/runtimeFormId" `
                        "does not equal origin load index plus local FormID (expected 0x$('{0:X8}' -f $expected))"
                }
            }
        }
    }
    elseif ($kind -eq 'dynamic') {
        $allowed = @('kind', 'runtimeFormId', 'saveDynamicId', 'baseForm')
        Assert-FNVCheckpointRequiredProperties $Value $allowed $Path $Failures
        Assert-FNVCheckpointAllowedProperties $Value $allowed $Path $Failures
        Assert-FNVCheckpointString (Get-FNVCheckpointProperty $Value 'runtimeFormId') `
            "$Path/runtimeFormId" $Failures '^0[xX][fF]{2}[0-9A-Fa-f]{6}$'
        Assert-FNVCheckpointString (Get-FNVCheckpointProperty $Value 'saveDynamicId') `
            "$Path/saveDynamicId" $Failures '^0[xX][0-9A-Fa-f]{6}$'
        $runtime = Get-FNVCheckpointProperty $Value 'runtimeFormId'
        $saveDynamicId = Get-FNVCheckpointProperty $Value 'saveDynamicId'
        if ($runtime -is [string] -and [string]$runtime -match '^0[xX][fF]{2}[0-9A-Fa-f]{6}$' -and
            $saveDynamicId -is [string] -and [string]$saveDynamicId -match '^0[xX][0-9A-Fa-f]{6}$') {
            $runtimeLow = [Convert]::ToUInt32(([string]$runtime).Substring(4), 16)
            $saveLocal = [Convert]::ToUInt32(([string]$saveDynamicId).Substring(2), 16)
            if ($runtimeLow -ne $saveLocal) {
                Add-FNVCheckpointFailure $Failures "$Path/saveDynamicId" `
                    'must equal the low 24 bits of runtimeFormId'
            }
        }
        $baseForm = Get-FNVCheckpointProperty $Value 'baseForm'
        if ($null -eq $baseForm -or (Get-FNVCheckpointProperty $baseForm 'kind') -ne 'plugin') {
            Add-FNVCheckpointFailure $Failures "$Path/baseForm" 'must be a plugin-qualified base FormKey'
        }
        else {
            Assert-FNVCheckpointFormKey $baseForm "$Path/baseForm" $Plugins $Failures
        }
    }
    else {
        Add-FNVCheckpointFailure $Failures "$Path/kind" "must be 'plugin' or 'dynamic'"
    }
}

function Assert-FNVCheckpointEmbeddedValues {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, object]]$Plugins,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
        $index = 0
        foreach ($item in @($Value)) {
            Assert-FNVCheckpointEmbeddedValues $item "$Path/$index" $Plugins $Failures
            ++$index
        }
        return
    }
    if ($Value -isnot [pscustomobject]) { return }

    $kind = Get-FNVCheckpointProperty $Value 'kind'
    if ($kind -eq 'plugin' -or $kind -eq 'dynamic') {
        Assert-FNVCheckpointFormKey $Value $Path $Plugins $Failures
        return
    }
    if (Test-FNVCheckpointHasProperty $Value 'bitsHex') {
        Assert-FNVCheckpointRawFloat $Value $Path $Failures
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        $escapedName = ([string]$property.Name).Replace('~', '~0').Replace('/', '~1')
        Assert-FNVCheckpointEmbeddedValues $property.Value "$Path/$escapedName" $Plugins $Failures
    }
}

function Assert-FNVCheckpointRequiredSet {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string[]]$Required,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -isnot [Collections.IEnumerable]) {
        Add-FNVCheckpointFailure $Failures $Path 'must be a JSON array'
        return
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) {
            Add-FNVCheckpointFailure $Failures $Path 'contains a non-string or empty item'
            continue
        }
        if (-not $seen.Add([string]$item)) {
            Add-FNVCheckpointFailure $Failures $Path "contains duplicate item '$item'"
        }
        if ($Required -notcontains [string]$item) {
            Add-FNVCheckpointFailure $Failures $Path "contains unknown item '$item'"
        }
    }
    foreach ($item in $Required) {
        if (-not $seen.Contains($item)) {
            Add-FNVCheckpointFailure $Failures $Path "is missing required item '$item'"
        }
    }
}

function Get-FNVRetailCheckpointRequiredLedgerPaths {
    [CmdletBinding()]
    param()

    return @($script:FNVCheckpointRequiredLedgerPaths)
}

function Assert-FNVRetailCheckpointManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [switch]$VerifyArtifactFiles
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "FNV retail checkpoint manifest does not exist: $fullPath"
    }

    try {
        $document = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "FNV retail checkpoint manifest is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $document -or $document -isnot [pscustomobject]) {
        throw 'FNV retail checkpoint manifest root must be a JSON object.'
    }

    $failures = [Collections.Generic.List[string]]::new()
    $topLevel = @(
        'schema', 'complete', 'capture', 'identity', 'artifacts', 'snapshot',
        'temporalEvidence', 'mappingLedger', 'coverage', 'hardFailures'
    )
    Assert-FNVCheckpointRequiredProperties $document $topLevel '/' $failures
    Assert-FNVCheckpointAllowedProperties $document $topLevel '/' $failures

    if ((Get-FNVCheckpointProperty $document 'schema') -ne $script:FNVCheckpointSchema) {
        Add-FNVCheckpointFailure $failures '/schema' `
            "must equal '$script:FNVCheckpointSchema'"
    }
    $complete = Get-FNVCheckpointProperty $document 'complete'
    if ($complete -isnot [bool]) {
        Add-FNVCheckpointFailure $failures '/complete' 'must be a JSON boolean'
        $complete = $false
    }

    $capture = Get-FNVCheckpointProperty $document 'capture'
    $captureProperties = @(
        'checkpointId', 'generationId', 'runtime', 'oracleBuild', 'capturedAtUtc',
        'postLoadFrame', 'save'
    )
    Assert-FNVCheckpointRequiredProperties $capture $captureProperties '/capture' $failures
    Assert-FNVCheckpointAllowedProperties $capture $captureProperties '/capture' $failures
    $checkpointId = Get-FNVCheckpointProperty $capture 'checkpointId'
    $generationId = Get-FNVCheckpointProperty $capture 'generationId'
    Assert-FNVCheckpointString $checkpointId '/capture/checkpointId' $failures `
        $script:FNVCheckpointGenerationPattern
    Assert-FNVCheckpointString $generationId '/capture/generationId' $failures `
        $script:FNVCheckpointGenerationPattern
    if ((Get-FNVCheckpointProperty $capture 'runtime') -ne $script:FNVCheckpointRuntime) {
        Add-FNVCheckpointFailure $failures '/capture/runtime' `
            "must equal '$script:FNVCheckpointRuntime'"
    }
    Assert-FNVCheckpointString (Get-FNVCheckpointProperty $capture 'oracleBuild') `
        '/capture/oracleBuild' $failures
    if (-not (Test-FNVCheckpointUtcTimestamp (Get-FNVCheckpointProperty $capture 'capturedAtUtc'))) {
        Add-FNVCheckpointFailure $failures '/capture/capturedAtUtc' `
            'must be an ISO-8601 UTC timestamp ending in Z'
    }
    $postLoadFrame = Get-FNVCheckpointProperty $capture 'postLoadFrame'
    if (-not (Test-FNVCheckpointJsonInteger $postLoadFrame) -or [int64]$postLoadFrame -lt 0) {
        Add-FNVCheckpointFailure $failures '/capture/postLoadFrame' 'must be a nonnegative JSON integer'
    }

    $save = Get-FNVCheckpointProperty $capture 'save'
    $saveProperties = @(
        'requestedName', 'slot', 'path', 'bytes', 'sha256', 'lastWriteUtc',
        'postLoadSucceeded'
    )
    Assert-FNVCheckpointRequiredProperties $save $saveProperties '/capture/save' $failures
    Assert-FNVCheckpointAllowedProperties $save $saveProperties '/capture/save' $failures
    if ((Get-FNVCheckpointProperty $save 'requestedName') -cne 'Save 330') {
        Add-FNVCheckpointFailure $failures '/capture/save/requestedName' `
            "must exactly equal 'Save 330'"
    }
    if (-not (Test-FNVCheckpointJsonInteger (Get-FNVCheckpointProperty $save 'slot')) -or
        [int64](Get-FNVCheckpointProperty $save 'slot') -ne 330) {
        Add-FNVCheckpointFailure $failures '/capture/save/slot' 'must be JSON integer 330'
    }
    $savePath = Get-FNVCheckpointProperty $save 'path'
    Assert-FNVCheckpointString $savePath '/capture/save/path' $failures '(?i)\.fos$'
    if ($savePath -is [string] -and -not [IO.Path]::IsPathRooted([string]$savePath)) {
        Add-FNVCheckpointFailure $failures '/capture/save/path' `
            'must be the absolute retail .fos path loaded by Save 330'
    }
    $saveBytes = Get-FNVCheckpointProperty $save 'bytes'
    if (-not (Test-FNVCheckpointJsonInteger $saveBytes) -or [int64]$saveBytes -lt 1) {
        Add-FNVCheckpointFailure $failures '/capture/save/bytes' 'must be a positive JSON integer'
    }
    Assert-FNVCheckpointString (Get-FNVCheckpointProperty $save 'sha256') `
        '/capture/save/sha256' $failures $script:FNVCheckpointSha256Pattern
    if (-not (Test-FNVCheckpointUtcTimestamp (Get-FNVCheckpointProperty $save 'lastWriteUtc'))) {
        Add-FNVCheckpointFailure $failures '/capture/save/lastWriteUtc' `
            'must be an ISO-8601 UTC timestamp ending in Z'
    }
    if ((Get-FNVCheckpointProperty $save 'postLoadSucceeded') -isnot [bool] -or
        -not [bool](Get-FNVCheckpointProperty $save 'postLoadSucceeded')) {
        Add-FNVCheckpointFailure $failures '/capture/save/postLoadSucceeded' `
            'must be JSON boolean true from successful PostLoadGame'
    }

    $identity = Get-FNVCheckpointProperty $document 'identity'
    $identityProperties = @('formKeyModel', 'dynamicFormModel', 'loadOrder')
    Assert-FNVCheckpointRequiredProperties $identity $identityProperties '/identity' $failures
    Assert-FNVCheckpointAllowedProperties $identity $identityProperties '/identity' $failures
    if ((Get-FNVCheckpointProperty $identity 'formKeyModel') -ne 'plugin+local-form-id/v1') {
        Add-FNVCheckpointFailure $failures '/identity/formKeyModel' `
            "must equal 'plugin+local-form-id/v1'"
    }
    if ((Get-FNVCheckpointProperty $identity 'dynamicFormModel') -ne 'save-scoped-dynamic/v1') {
        Add-FNVCheckpointFailure $failures '/identity/dynamicFormModel' `
            "must equal 'save-scoped-dynamic/v1'"
    }
    $loadOrderValue = Get-FNVCheckpointProperty $identity 'loadOrder'
    $loadOrder = @($loadOrderValue)
    if ($loadOrderValue -is [string] -or $loadOrder.Count -eq 0) {
        Add-FNVCheckpointFailure $failures '/identity/loadOrder' `
            'must be a nonempty ordered JSON array'
    }
    if ($loadOrder.Count -gt 255) {
        Add-FNVCheckpointFailure $failures '/identity/loadOrder' 'cannot contain more than 255 plugins'
    }
    $plugins = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $loadOrder.Count; ++$index) {
        $pluginEntry = $loadOrder[$index]
        $pluginPath = "/identity/loadOrder/$index"
        $pluginProperties = @('index', 'plugin', 'bytes', 'sha256')
        Assert-FNVCheckpointRequiredProperties $pluginEntry $pluginProperties $pluginPath $failures
        Assert-FNVCheckpointAllowedProperties $pluginEntry $pluginProperties $pluginPath $failures
        $declaredIndex = Get-FNVCheckpointProperty $pluginEntry 'index'
        if (-not (Test-FNVCheckpointJsonInteger $declaredIndex) -or [int64]$declaredIndex -ne $index) {
            Add-FNVCheckpointFailure $failures "$pluginPath/index" `
                "must equal its zero-based array position $index"
        }
        $pluginName = Get-FNVCheckpointProperty $pluginEntry 'plugin'
        Assert-FNVCheckpointString $pluginName "$pluginPath/plugin" $failures '(?i)\.(esm|esp)$'
        if ($pluginName -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$pluginName)) {
            if ($plugins.ContainsKey([string]$pluginName)) {
                Add-FNVCheckpointFailure $failures "$pluginPath/plugin" `
                    "duplicates load-order plugin '$pluginName'"
            }
            else {
                $plugins.Add([string]$pluginName, $pluginEntry)
            }
        }
        $pluginBytes = Get-FNVCheckpointProperty $pluginEntry 'bytes'
        if (-not (Test-FNVCheckpointJsonInteger $pluginBytes) -or [int64]$pluginBytes -lt 1) {
            Add-FNVCheckpointFailure $failures "$pluginPath/bytes" 'must be a positive JSON integer'
        }
        Assert-FNVCheckpointString (Get-FNVCheckpointProperty $pluginEntry 'sha256') `
            "$pluginPath/sha256" $failures $script:FNVCheckpointSha256Pattern
    }

    $artifactsValue = Get-FNVCheckpointProperty $document 'artifacts'
    $artifacts = @($artifactsValue)
    if ($artifactsValue -is [string] -or $artifacts.Count -lt 3) {
        Add-FNVCheckpointFailure $failures '/artifacts' `
            'must be an array containing a trace and at least two screenshots'
    }
    $artifactById = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)
    $artifactPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $artifactKinds = @('snapshot-payload', 'trace', 'screenshot', 'visual-index', 'supplemental')
    $verifiedArtifactCount = 0
    $manifestDirectory = [IO.Path]::GetDirectoryName($fullPath)
    $manifestDirectoryPrefix = $manifestDirectory.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    for ($index = 0; $index -lt $artifacts.Count; ++$index) {
        $artifact = $artifacts[$index]
        $artifactPath = "/artifacts/$index"
        $artifactProperties = @(
            'id', 'kind', 'path', 'bytes', 'sha256', 'generationId', 'mediaType', 'retailFrame'
        )
        Assert-FNVCheckpointRequiredProperties $artifact `
            @('id', 'kind', 'path', 'bytes', 'sha256', 'generationId', 'mediaType') `
            $artifactPath $failures
        Assert-FNVCheckpointAllowedProperties $artifact $artifactProperties $artifactPath $failures
        $artifactId = Get-FNVCheckpointProperty $artifact 'id'
        Assert-FNVCheckpointString $artifactId "$artifactPath/id" $failures `
            $script:FNVCheckpointGenerationPattern
        if ($artifactId -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$artifactId)) {
            if ($artifactById.ContainsKey([string]$artifactId)) {
                Add-FNVCheckpointFailure $failures "$artifactPath/id" `
                    "duplicates artifact id '$artifactId'"
            }
            else {
                $artifactById.Add([string]$artifactId, $artifact)
            }
        }
        $kind = Get-FNVCheckpointProperty $artifact 'kind'
        if ($kind -isnot [string] -or $artifactKinds -notcontains [string]$kind) {
            Add-FNVCheckpointFailure $failures "$artifactPath/kind" 'is not a supported artifact kind'
        }
        $relativePath = Get-FNVCheckpointProperty $artifact 'path'
        Assert-FNVCheckpointString $relativePath "$artifactPath/path" $failures
        $portablePath = $false
        if ($relativePath -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$relativePath)) {
            $segments = @(([string]$relativePath) -split '[\\/]')
            $portablePath = -not [IO.Path]::IsPathRooted([string]$relativePath) -and
                $segments -notcontains '..' -and $segments -notcontains '.' -and
                $segments -notcontains ''
            if (-not $portablePath) {
                Add-FNVCheckpointFailure $failures "$artifactPath/path" `
                    'must be a normalized relative path without empty, dot, or parent segments'
            }
            elseif (-not $artifactPaths.Add([string]$relativePath)) {
                Add-FNVCheckpointFailure $failures "$artifactPath/path" `
                    "duplicates artifact path '$relativePath'"
            }
        }
        $artifactBytes = Get-FNVCheckpointProperty $artifact 'bytes'
        if (-not (Test-FNVCheckpointJsonInteger $artifactBytes) -or [int64]$artifactBytes -lt 1) {
            Add-FNVCheckpointFailure $failures "$artifactPath/bytes" 'must be a positive JSON integer'
        }
        $artifactSha = Get-FNVCheckpointProperty $artifact 'sha256'
        Assert-FNVCheckpointString $artifactSha "$artifactPath/sha256" $failures `
            $script:FNVCheckpointSha256Pattern
        if ((Get-FNVCheckpointProperty $artifact 'generationId') -cne $generationId) {
            Add-FNVCheckpointFailure $failures "$artifactPath/generationId" `
                'must exactly match capture.generationId'
        }
        Assert-FNVCheckpointString (Get-FNVCheckpointProperty $artifact 'mediaType') `
            "$artifactPath/mediaType" $failures
        if ($kind -eq 'screenshot') {
            $retailFrame = Get-FNVCheckpointProperty $artifact 'retailFrame'
            if (-not (Test-FNVCheckpointJsonInteger $retailFrame) -or [int64]$retailFrame -lt 0) {
                Add-FNVCheckpointFailure $failures "$artifactPath/retailFrame" `
                    'is required for screenshots and must be a nonnegative JSON integer'
            }
        }

        if ($VerifyArtifactFiles -and $portablePath) {
            $artifactFullPath = [IO.Path]::GetFullPath((Join-Path $manifestDirectory ([string]$relativePath)))
            if (-not $artifactFullPath.StartsWith(
                $manifestDirectoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Add-FNVCheckpointFailure $failures "$artifactPath/path" `
                    'resolves outside the manifest directory'
            }
            elseif (-not (Test-Path -LiteralPath $artifactFullPath -PathType Leaf)) {
                Add-FNVCheckpointFailure $failures "$artifactPath/path" `
                    "does not exist at '$artifactFullPath'"
            }
            else {
                $file = Get-Item -LiteralPath $artifactFullPath
                if ((Test-FNVCheckpointJsonInteger $artifactBytes) -and
                    [int64]$file.Length -ne [int64]$artifactBytes) {
                    Add-FNVCheckpointFailure $failures "$artifactPath/bytes" `
                        "does not match artifact file length $($file.Length)"
                }
                $observedSha = (Get-FileHash -LiteralPath $artifactFullPath -Algorithm SHA256).Hash
                if ($artifactSha -is [string] -and $observedSha -cne ([string]$artifactSha).ToUpperInvariant()) {
                    Add-FNVCheckpointFailure $failures "$artifactPath/sha256" `
                        "does not match artifact file SHA-256 $observedSha"
                }
                ++$verifiedArtifactCount
            }
        }
    }
    if (@($artifacts | Where-Object { (Get-FNVCheckpointProperty $_ 'kind') -eq 'trace' }).Count -lt 1) {
        Add-FNVCheckpointFailure $failures '/artifacts' 'does not contain a trace artifact'
    }
    if (@($artifacts | Where-Object { (Get-FNVCheckpointProperty $_ 'kind') -eq 'screenshot' }).Count -lt 2) {
        Add-FNVCheckpointFailure $failures '/artifacts' 'does not contain at least two screenshot artifacts'
    }

    $snapshot = Get-FNVCheckpointProperty $document 'snapshot'
    Assert-FNVCheckpointRequiredProperties $snapshot @('player', 'timeWeather') '/snapshot' $failures
    $player = Get-FNVCheckpointProperty $snapshot 'player'
    Assert-FNVCheckpointRequiredProperties $player @('reference', 'base', 'location') `
        '/snapshot/player' $failures
    foreach ($formName in @('reference', 'base')) {
        $formValue = Get-FNVCheckpointProperty $player $formName
        if ($null -eq $formValue -or $formValue -isnot [pscustomobject]) {
            Add-FNVCheckpointFailure $failures "/snapshot/player/$formName" `
                'must be a plugin-qualified or save-scoped dynamic FormKey'
        }
    }
    $location = Get-FNVCheckpointProperty $player 'location'
    Assert-FNVCheckpointRequiredProperties $location `
        @('cell', 'worldSpace', 'position', 'rotation') '/snapshot/player/location' $failures
    foreach ($vectorName in @('position', 'rotation')) {
        $vector = Get-FNVCheckpointProperty $location $vectorName
        Assert-FNVCheckpointRequiredProperties $vector @('x', 'y', 'z') `
            "/snapshot/player/location/$vectorName" $failures
        foreach ($axis in @('x', 'y', 'z')) {
            $component = Get-FNVCheckpointProperty $vector $axis
            if ($null -eq $component -or $component -isnot [pscustomobject] -or
                -not (Test-FNVCheckpointHasProperty $component 'bitsHex')) {
                Add-FNVCheckpointFailure $failures `
                    "/snapshot/player/location/$vectorName/$axis" `
                    'must be a raw float32 object with value and bitsHex'
            }
        }
    }
    $timeWeather = Get-FNVCheckpointProperty $snapshot 'timeWeather'
    Assert-FNVCheckpointRequiredProperties $timeWeather @('gameHour', 'timeScale', 'currentWeather') `
        '/snapshot/timeWeather' $failures
    foreach ($floatName in @('gameHour', 'timeScale')) {
        $floatValue = Get-FNVCheckpointProperty $timeWeather $floatName
        if ($null -eq $floatValue -or $floatValue -isnot [pscustomobject] -or
            -not (Test-FNVCheckpointHasProperty $floatValue 'bitsHex')) {
            Add-FNVCheckpointFailure $failures "/snapshot/timeWeather/$floatName" `
                'must be a raw float32 object with value and bitsHex'
        }
    }
    Assert-FNVCheckpointEmbeddedValues $snapshot '/snapshot' $plugins $failures

    $temporal = Get-FNVCheckpointProperty $document 'temporalEvidence'
    $temporalProperties = @(
        'schema', 'durationSeconds', 'sampleCount', 'sampleClock', 'coverageComplete',
        'traceArtifactId', 'screenshotArtifactIds', 'frameHashAlgorithm',
        'actorEnumeration', 'requiredActorChannels', 'requiredFrameChannels',
        'visualHardFailCategories', 'frameEvidence'
    )
    Assert-FNVCheckpointRequiredProperties $temporal $temporalProperties `
        '/temporalEvidence' $failures
    Assert-FNVCheckpointAllowedProperties $temporal $temporalProperties `
        '/temporalEvidence' $failures
    if ((Get-FNVCheckpointProperty $temporal 'schema') -ne 'nikami-fnv-retail-trace/v1') {
        Add-FNVCheckpointFailure $failures '/temporalEvidence/schema' `
            "must equal 'nikami-fnv-retail-trace/v1'"
    }
    $duration = Get-FNVCheckpointProperty $temporal 'durationSeconds'
    if (-not (Test-FNVCheckpointJsonNumber $duration) -or [double]$duration -lt 3) {
        Add-FNVCheckpointFailure $failures '/temporalEvidence/durationSeconds' `
            'must be a number of at least 3 seconds'
    }
    $sampleCount = Get-FNVCheckpointProperty $temporal 'sampleCount'
    if (-not (Test-FNVCheckpointJsonInteger $sampleCount) -or [int64]$sampleCount -lt 2) {
        Add-FNVCheckpointFailure $failures '/temporalEvidence/sampleCount' `
            'must be a JSON integer of at least 2'
    }
    if ((Get-FNVCheckpointProperty $temporal 'sampleClock') -ne 'retail-main-loop') {
        Add-FNVCheckpointFailure $failures '/temporalEvidence/sampleClock' `
            "must equal 'retail-main-loop'"
    }
    $coverageComplete = Get-FNVCheckpointProperty $temporal 'coverageComplete'
    if ($coverageComplete -isnot [bool]) {
        Add-FNVCheckpointFailure $failures '/temporalEvidence/coverageComplete' `
            'must be a JSON boolean'
        $coverageComplete = $false
    }
    if ((Get-FNVCheckpointProperty $temporal 'frameHashAlgorithm') -cne 'sha256') {
        Add-FNVCheckpointFailure $failures '/temporalEvidence/frameHashAlgorithm' `
            "must exactly equal 'sha256'"
    }
    Assert-FNVCheckpointRequiredSet `
        (Get-FNVCheckpointProperty $temporal 'requiredActorChannels') `
        $script:FNVCheckpointRequiredActorChannels `
        '/temporalEvidence/requiredActorChannels' $failures
    Assert-FNVCheckpointRequiredSet `
        (Get-FNVCheckpointProperty $temporal 'requiredFrameChannels') `
        $script:FNVCheckpointRequiredFrameChannels `
        '/temporalEvidence/requiredFrameChannels' $failures
    Assert-FNVCheckpointRequiredSet `
        (Get-FNVCheckpointProperty $temporal 'visualHardFailCategories') `
        $script:FNVCheckpointVisualHardFailureCategories `
        '/temporalEvidence/visualHardFailCategories' $failures

    $enumeration = Get-FNVCheckpointProperty $temporal 'actorEnumeration'
    $enumerationProperties = @(
        'source', 'includePlayer', 'loadedCellLocking', 'deduplicateByReference',
        'missingActorDisposition'
    )
    Assert-FNVCheckpointRequiredProperties $enumeration $enumerationProperties `
        '/temporalEvidence/actorEnumeration' $failures
    Assert-FNVCheckpointAllowedProperties $enumeration $enumerationProperties `
        '/temporalEvidence/actorEnumeration' $failures
    $enumerationConstants = [ordered]@{
        source = 'loaded-cells-plus-process-lists'
        includePlayer = $true
        loadedCellLocking = $true
        deduplicateByReference = $true
        missingActorDisposition = 'hard-fail'
    }
    foreach ($entry in $enumerationConstants.GetEnumerator()) {
        $actual = Get-FNVCheckpointProperty $enumeration $entry.Key
        if ($actual -is [bool] -or $entry.Value -is [bool]) {
            if ($actual -isnot [bool] -or $actual -ne $entry.Value) {
                Add-FNVCheckpointFailure $failures `
                    "/temporalEvidence/actorEnumeration/$($entry.Key)" `
                    "must be JSON value '$($entry.Value)'"
            }
        }
        elseif ($actual -cne $entry.Value) {
            Add-FNVCheckpointFailure $failures `
                "/temporalEvidence/actorEnumeration/$($entry.Key)" `
                "must exactly equal '$($entry.Value)'"
        }
    }

    $traceArtifactId = Get-FNVCheckpointProperty $temporal 'traceArtifactId'
    Assert-FNVCheckpointString $traceArtifactId '/temporalEvidence/traceArtifactId' $failures
    if ($traceArtifactId -is [string] -and $artifactById.ContainsKey([string]$traceArtifactId)) {
        if ((Get-FNVCheckpointProperty $artifactById[[string]$traceArtifactId] 'kind') -ne 'trace') {
            Add-FNVCheckpointFailure $failures '/temporalEvidence/traceArtifactId' `
                'must reference an artifact whose kind is trace'
        }
    }
    elseif ($traceArtifactId -is [string]) {
        Add-FNVCheckpointFailure $failures '/temporalEvidence/traceArtifactId' `
            "references unknown artifact '$traceArtifactId'"
    }

    $screenshotIdsValue = Get-FNVCheckpointProperty $temporal 'screenshotArtifactIds'
    $screenshotIds = @($screenshotIdsValue)
    if ($screenshotIdsValue -is [string] -or $screenshotIds.Count -lt 2) {
        Add-FNVCheckpointFailure $failures '/temporalEvidence/screenshotArtifactIds' `
            'must be an array with at least two screenshot artifact ids'
    }
    $screenshotIdSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($screenshotId in $screenshotIds) {
        if ($screenshotId -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$screenshotId)) {
            Add-FNVCheckpointFailure $failures '/temporalEvidence/screenshotArtifactIds' `
                'contains a non-string or empty artifact id'
            continue
        }
        if (-not $screenshotIdSet.Add([string]$screenshotId)) {
            Add-FNVCheckpointFailure $failures '/temporalEvidence/screenshotArtifactIds' `
                "contains duplicate artifact id '$screenshotId'"
        }
        if (-not $artifactById.ContainsKey([string]$screenshotId)) {
            Add-FNVCheckpointFailure $failures '/temporalEvidence/screenshotArtifactIds' `
                "references unknown artifact '$screenshotId'"
        }
        elseif ((Get-FNVCheckpointProperty $artifactById[[string]$screenshotId] 'kind') -ne 'screenshot') {
            Add-FNVCheckpointFailure $failures '/temporalEvidence/screenshotArtifactIds' `
                "artifact '$screenshotId' is not a screenshot"
        }
    }

    $frameEvidenceValue = Get-FNVCheckpointProperty $temporal 'frameEvidence'
    $frameEvidence = @($frameEvidenceValue)
    if ($frameEvidenceValue -is [string] -or $frameEvidence.Count -lt 2) {
        Add-FNVCheckpointFailure $failures '/temporalEvidence/frameEvidence' `
            'must be an ordered array with at least two synchronized frames'
    }
    if ((Test-FNVCheckpointJsonInteger $sampleCount) -and [int64]$sampleCount -lt $frameEvidence.Count) {
        Add-FNVCheckpointFailure $failures '/temporalEvidence/sampleCount' `
            'cannot be less than frameEvidence count'
    }
    $frameSet = [Collections.Generic.HashSet[int64]]::new()
    $previousFrame = [int64]-1
    for ($index = 0; $index -lt $frameEvidence.Count; ++$index) {
        $frame = $frameEvidence[$index]
        $framePath = "/temporalEvidence/frameEvidence/$index"
        $frameProperties = @(
            'retailFrame', 'generationId', 'frameStateSha256', 'screenshotArtifactId'
        )
        Assert-FNVCheckpointRequiredProperties $frame $frameProperties $framePath $failures
        Assert-FNVCheckpointAllowedProperties $frame $frameProperties $framePath $failures
        $retailFrame = Get-FNVCheckpointProperty $frame 'retailFrame'
        if (-not (Test-FNVCheckpointJsonInteger $retailFrame) -or [int64]$retailFrame -lt 0) {
            Add-FNVCheckpointFailure $failures "$framePath/retailFrame" `
                'must be a nonnegative JSON integer'
        }
        else {
            $frameNumber = [int64]$retailFrame
            if (-not $frameSet.Add($frameNumber)) {
                Add-FNVCheckpointFailure $failures "$framePath/retailFrame" `
                    "duplicates retail frame $frameNumber"
            }
            if ($index -gt 0 -and $frameNumber -le $previousFrame) {
                Add-FNVCheckpointFailure $failures "$framePath/retailFrame" `
                    'must be strictly greater than the preceding synchronized frame'
            }
            $previousFrame = $frameNumber
        }
        if ((Get-FNVCheckpointProperty $frame 'generationId') -cne $generationId) {
            Add-FNVCheckpointFailure $failures "$framePath/generationId" `
                'must exactly match capture.generationId'
        }
        Assert-FNVCheckpointString (Get-FNVCheckpointProperty $frame 'frameStateSha256') `
            "$framePath/frameStateSha256" $failures $script:FNVCheckpointSha256Pattern
        $screenshotId = Get-FNVCheckpointProperty $frame 'screenshotArtifactId'
        Assert-FNVCheckpointString $screenshotId "$framePath/screenshotArtifactId" $failures
        if ($index -lt $screenshotIds.Count -and $screenshotId -cne $screenshotIds[$index]) {
            Add-FNVCheckpointFailure $failures "$framePath/screenshotArtifactId" `
                'must match screenshotArtifactIds at the same ordinal'
        }
        if ($screenshotId -is [string] -and $artifactById.ContainsKey([string]$screenshotId)) {
            $screenshotArtifact = $artifactById[[string]$screenshotId]
            if ((Get-FNVCheckpointProperty $screenshotArtifact 'kind') -ne 'screenshot') {
                Add-FNVCheckpointFailure $failures "$framePath/screenshotArtifactId" `
                    "artifact '$screenshotId' is not a screenshot"
            }
            elseif ((Test-FNVCheckpointJsonInteger $retailFrame) -and
                [int64](Get-FNVCheckpointProperty $screenshotArtifact 'retailFrame') -ne [int64]$retailFrame) {
                Add-FNVCheckpointFailure $failures "$framePath/screenshotArtifactId" `
                    "artifact '$screenshotId' does not carry retail frame $retailFrame"
            }
        }
        elseif ($screenshotId -is [string]) {
            Add-FNVCheckpointFailure $failures "$framePath/screenshotArtifactId" `
                "references unknown artifact '$screenshotId'"
        }
    }
    if ($frameEvidence.Count -ne $screenshotIds.Count) {
        Add-FNVCheckpointFailure $failures '/temporalEvidence' `
            'frameEvidence and screenshotArtifactIds must have identical counts'
    }

    $mappingValue = Get-FNVCheckpointProperty $document 'mappingLedger'
    $mapping = @($mappingValue)
    if ($mappingValue -is [string] -or $mapping.Count -eq 0) {
        Add-FNVCheckpointFailure $failures '/mappingLedger' 'must be a nonempty JSON array'
    }
    $ledgerByPath = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)
    $mappedRequired = 0
    $partialRequired = 0
    $uncoveredRequired = 0
    $requiredFields = 0
    $mappingStatuses = @('mapped', 'partial', 'uncovered')
    $sourceConfidences = @('proven', 'canary', 'offline-parser', 'unreadable')
    $compareModes = @(
        'raw-bits', 'exact', 'semantic', 'ordered-set', 'artifact-hash',
        'visual-signature', 'uncovered'
    )
    for ($index = 0; $index -lt $mapping.Count; ++$index) {
        $entry = $mapping[$index]
        $entryPath = "/mappingLedger/$index"
        $entryProperties = @(
            'retailPath', 'required', 'status', 'source', 'openMw', 'compare', 'blocker'
        )
        Assert-FNVCheckpointRequiredProperties $entry $entryProperties $entryPath $failures
        Assert-FNVCheckpointAllowedProperties $entry $entryProperties $entryPath $failures
        $retailPath = Get-FNVCheckpointProperty $entry 'retailPath'
        Assert-FNVCheckpointString $retailPath "$entryPath/retailPath" $failures `
            '^/(?:[^/~]|~[01])+(?:/(?:[^/~]|~[01])+)*$'
        if ($retailPath -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$retailPath)) {
            if ($ledgerByPath.ContainsKey([string]$retailPath)) {
                Add-FNVCheckpointFailure $failures "$entryPath/retailPath" `
                    "duplicates ledger path '$retailPath'"
            }
            else {
                $ledgerByPath.Add([string]$retailPath, $entry)
            }
        }
        $isRequired = Get-FNVCheckpointProperty $entry 'required'
        if ($isRequired -isnot [bool]) {
            Add-FNVCheckpointFailure $failures "$entryPath/required" 'must be a JSON boolean'
            $isRequired = $false
        }
        $status = Get-FNVCheckpointProperty $entry 'status'
        if ($status -isnot [string] -or $mappingStatuses -notcontains [string]$status) {
            Add-FNVCheckpointFailure $failures "$entryPath/status" `
                "must be mapped, partial, or uncovered"
        }
        if ($isRequired) {
            ++$requiredFields
            switch ([string]$status) {
                'mapped' { ++$mappedRequired }
                'partial' { ++$partialRequired }
                'uncovered' { ++$uncoveredRequired }
            }
        }
        $source = Get-FNVCheckpointProperty $entry 'source'
        Assert-FNVCheckpointRequiredProperties $source @('reader', 'confidence') `
            "$entryPath/source" $failures
        Assert-FNVCheckpointAllowedProperties $source @('reader', 'confidence') `
            "$entryPath/source" $failures
        $reader = Get-FNVCheckpointProperty $source 'reader'
        if ($null -ne $reader -and ($reader -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$reader))) {
            Add-FNVCheckpointFailure $failures "$entryPath/source/reader" `
                'must be null or a nonempty string'
        }
        $confidence = Get-FNVCheckpointProperty $source 'confidence'
        if ($confidence -isnot [string] -or $sourceConfidences -notcontains [string]$confidence) {
            Add-FNVCheckpointFailure $failures "$entryPath/source/confidence" `
                'must be proven, canary, offline-parser, or unreadable'
        }
        if ($status -eq 'mapped' -and $confidence -eq 'unreadable') {
            Add-FNVCheckpointFailure $failures "$entryPath/status" `
                'cannot be mapped when the retail source is unreadable'
        }
        $openMw = Get-FNVCheckpointProperty $entry 'openMw'
        Assert-FNVCheckpointRequiredProperties $openMw @('target', 'writer') `
            "$entryPath/openMw" $failures
        Assert-FNVCheckpointAllowedProperties $openMw @('target', 'writer') `
            "$entryPath/openMw" $failures
        $target = Get-FNVCheckpointProperty $openMw 'target'
        $writer = Get-FNVCheckpointProperty $openMw 'writer'
        if ($status -eq 'mapped') {
            if ($target -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$target)) {
                Add-FNVCheckpointFailure $failures "$entryPath/openMw/target" `
                    'must identify the OpenMW target when status is mapped'
            }
            if ($writer -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$writer)) {
                Add-FNVCheckpointFailure $failures "$entryPath/openMw/writer" `
                    'must identify the OpenMW writer/importer when status is mapped'
            }
        }
        foreach ($pair in @(@('target', $target), @('writer', $writer))) {
            if ($null -ne $pair[1] -and ($pair[1] -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$pair[1]))) {
                Add-FNVCheckpointFailure $failures "$entryPath/openMw/$($pair[0])" `
                    'must be null or a nonempty string'
            }
        }
        $compare = Get-FNVCheckpointProperty $entry 'compare'
        Assert-FNVCheckpointRequiredProperties $compare @('mode') "$entryPath/compare" $failures
        Assert-FNVCheckpointAllowedProperties $compare @('mode') "$entryPath/compare" $failures
        $compareMode = Get-FNVCheckpointProperty $compare 'mode'
        if ($compareMode -isnot [string] -or $compareModes -notcontains [string]$compareMode) {
            Add-FNVCheckpointFailure $failures "$entryPath/compare/mode" `
                'is not a supported comparison mode'
        }
        if ($status -eq 'mapped' -and $compareMode -eq 'uncovered') {
            Add-FNVCheckpointFailure $failures "$entryPath/compare/mode" `
                'cannot be uncovered when status is mapped'
        }
        $blocker = Get-FNVCheckpointProperty $entry 'blocker'
        if ($status -eq 'partial' -or $status -eq 'uncovered') {
            if ($blocker -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$blocker)) {
                Add-FNVCheckpointFailure $failures "$entryPath/blocker" `
                    'must explain every partial or uncovered mapping'
            }
        }
        elseif ($null -ne $blocker -and ($blocker -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$blocker))) {
            Add-FNVCheckpointFailure $failures "$entryPath/blocker" `
                'must be null or a nonempty string'
        }
    }
    foreach ($requiredPath in $script:FNVCheckpointRequiredLedgerPaths) {
        if (-not $ledgerByPath.ContainsKey($requiredPath)) {
            Add-FNVCheckpointFailure $failures '/mappingLedger' `
                "is missing required coverage path '$requiredPath'"
        }
        elseif ((Get-FNVCheckpointProperty $ledgerByPath[$requiredPath] 'required') -isnot [bool] -or
            -not [bool](Get-FNVCheckpointProperty $ledgerByPath[$requiredPath] 'required')) {
            Add-FNVCheckpointFailure $failures '/mappingLedger' `
                "coverage path '$requiredPath' must be marked required:true"
        }
    }

    $coverage = Get-FNVCheckpointProperty $document 'coverage'
    $coverageProperties = @(
        'requiredFields', 'mappedRequiredFields', 'partialRequiredFields',
        'uncoveredRequiredFields'
    )
    Assert-FNVCheckpointRequiredProperties $coverage $coverageProperties '/coverage' $failures
    Assert-FNVCheckpointAllowedProperties $coverage $coverageProperties '/coverage' $failures
    $expectedCoverage = [ordered]@{
        requiredFields = $requiredFields
        mappedRequiredFields = $mappedRequired
        partialRequiredFields = $partialRequired
        uncoveredRequiredFields = $uncoveredRequired
    }
    foreach ($entry in $expectedCoverage.GetEnumerator()) {
        $actual = Get-FNVCheckpointProperty $coverage $entry.Key
        if (-not (Test-FNVCheckpointJsonInteger $actual) -or [int64]$actual -ne $entry.Value) {
            Add-FNVCheckpointFailure $failures "/coverage/$($entry.Key)" `
                "must equal recomputed value $($entry.Value)"
        }
    }

    $hardFailuresValue = Get-FNVCheckpointProperty $document 'hardFailures'
    $hardFailures = @($hardFailuresValue)
    if ($hardFailuresValue -is [string]) {
        Add-FNVCheckpointFailure $failures '/hardFailures' 'must be a JSON array'
    }
    for ($index = 0; $index -lt $hardFailures.Count; ++$index) {
        $failure = $hardFailures[$index]
        $failurePath = "/hardFailures/$index"
        Assert-FNVCheckpointRequiredProperties $failure @('category', 'path', 'message') `
            $failurePath $failures
        Assert-FNVCheckpointAllowedProperties $failure `
            @('category', 'path', 'message', 'retailFrame', 'actor') $failurePath $failures
        $category = Get-FNVCheckpointProperty $failure 'category'
        if ($category -isnot [string] -or
            $script:FNVCheckpointVisualHardFailureCategories -notcontains [string]$category) {
            Add-FNVCheckpointFailure $failures "$failurePath/category" `
                'is not a declared visual hard-failure category'
        }
        Assert-FNVCheckpointString (Get-FNVCheckpointProperty $failure 'path') `
            "$failurePath/path" $failures
        Assert-FNVCheckpointString (Get-FNVCheckpointProperty $failure 'message') `
            "$failurePath/message" $failures
        if (Test-FNVCheckpointHasProperty $failure 'retailFrame') {
            $retailFrame = Get-FNVCheckpointProperty $failure 'retailFrame'
            if (-not (Test-FNVCheckpointJsonInteger $retailFrame) -or [int64]$retailFrame -lt 0) {
                Add-FNVCheckpointFailure $failures "$failurePath/retailFrame" `
                    'must be a nonnegative JSON integer'
            }
        }
        if (Test-FNVCheckpointHasProperty $failure 'actor') {
            $failureActor = Get-FNVCheckpointProperty $failure 'actor'
            if ($null -eq $failureActor -or $failureActor -isnot [pscustomobject]) {
                Add-FNVCheckpointFailure $failures "$failurePath/actor" `
                    'must be a plugin-qualified or save-scoped dynamic FormKey'
            }
            else {
                Assert-FNVCheckpointFormKey $failureActor "$failurePath/actor" $plugins $failures
            }
        }
    }

    $requiredGapCount = $partialRequired + $uncoveredRequired
    if ($complete -and $requiredGapCount -gt 0) {
        Add-FNVCheckpointFailure $failures '/complete' `
            "cannot be true while $requiredGapCount required mapping entries are partial or uncovered"
    }
    if ($complete -and -not $coverageComplete) {
        Add-FNVCheckpointFailure $failures '/complete' `
            'cannot be true while temporalEvidence.coverageComplete is false'
    }
    if ($complete -and $hardFailures.Count -gt 0) {
        Add-FNVCheckpointFailure $failures '/complete' `
            "cannot be true while $($hardFailures.Count) visual hard failures exist"
    }

    if ($failures.Count -gt 0) {
        throw "FNV retail checkpoint manifest validation failed:`n - $($failures -join "`n - ")"
    }

    return [pscustomobject][ordered]@{
        schema = $script:FNVCheckpointSchema
        checkpointId = [string]$checkpointId
        generationId = [string]$generationId
        complete = [bool]$complete
        requiredFields = $requiredFields
        mappedRequiredFields = $mappedRequired
        partialRequiredFields = $partialRequired
        uncoveredRequiredFields = $uncoveredRequired
        artifactCount = $artifacts.Count
        verifiedArtifactCount = $verifiedArtifactCount
        status = 'valid'
    }
}

Export-ModuleMember -Function @(
    'Assert-FNVRetailCheckpointManifest',
    'Get-FNVRetailCheckpointRequiredLedgerPaths'
)
