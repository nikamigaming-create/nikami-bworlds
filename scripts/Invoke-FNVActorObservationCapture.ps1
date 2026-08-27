[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PlanRoot,
    [Parameter(Mandatory)]
    [string]$CorpusRoot,
    [Parameter(Mandatory)]
    [ValidatePattern('^[^:]+\.(?:esm|esp):[0-9a-fA-F]{6}$')]
    [string]$CaptureJobKey,
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [Parameter(Mandatory)]
    [string]$OracleSeedRoot,
    [Parameter(Mandatory)]
    [string]$OraclePluginDll,
    [Parameter(Mandatory)]
    [string]$SaveFixture,
    [string]$GalleryShotPath = '',
    [string]$OpenNvRoot = '',
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas',
    [string]$WorldsRoot = '',
    [int]$TimeoutSeconds = 0,
    [switch]$ActorDrawContractDiagnostic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorldsRoot)) {
    $WorldsRoot = Split-Path -Parent $PSScriptRoot
}
$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)

function Resolve-ObservationPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $WorldsRoot $Path))
}

function Get-LowerSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertFrom-CanonicalHexUInt32([string]$Value, [string]$Label) {
    if ($Value -cnotmatch '^0x[0-9A-Fa-f]{8}$') {
        throw "$Label is not one canonical unsigned hexadecimal value: $Value"
    }
    return [Convert]::ToUInt32($Value.Substring(2), 16)
}

function Assert-ManifestFile([string]$Root, [object]$Entry, [string]$Label) {
    $path = Join-Path $Root ([string]$Entry.file)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing $Label file: $path"
    }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -ne [int64]$Entry.bytes) {
        throw "$Label byte count differs from its immutable manifest: $path"
    }
    $actualHash = Get-LowerSha256 $path
    if ($actualHash -cne [string]$Entry.sha256) {
        throw "$Label SHA-256 differs from its immutable manifest: $path"
    }
    return $path
}

function Write-ImmutableJson([string]$Path, [object]$Value, [int]$Depth = 20) {
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite immutable JSON: $Path"
    }
    $json = ($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Write-CurrentJson([string]$Path, [object]$Value, [int]$Depth = 20) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $temporary = $resolved + '.new'
    $json = ($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $resolved -Force
}

function Resolve-ContainedPath(
    [string]$Root,
    [string]$RelativePath,
    [string]$Label
) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Label must be a nonempty relative path."
    }
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $resolved = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $RelativePath))
    $requiredPrefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith(
            $requiredPrefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its declared root: $RelativePath"
    }
    return $resolved
}

function Get-FileEvidence([string]$Path, [string]$Kind) {
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject][ordered]@{
        kind = $Kind
        path = $item.FullName
        bytes = $item.Length
        sha256 = Get-LowerSha256 $item.FullName
    }
}

function Assert-FileDescriptor([object]$Descriptor, [string]$Label) {
    if ($null -eq $Descriptor -or
        [string]::IsNullOrWhiteSpace([string]$Descriptor.path) -or
        [int64]$Descriptor.bytes -lt 1 -or
        [string]$Descriptor.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Label descriptor is incomplete."
    }
    $path = [IO.Path]::GetFullPath([string]$Descriptor.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$Label descriptor path is missing: $path"
    }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -ne [int64]$Descriptor.bytes -or
        (Get-LowerSha256 $path) -cne [string]$Descriptor.sha256) {
        throw "$Label differs from its immutable descriptor: $path"
    }
    return $path
}

function Test-FiniteNumberArray([object[]]$Values, [int]$ExpectedCount) {
    if ($Values.Count -ne $ExpectedCount) { return $false }
    foreach ($value in $Values) {
        try { $number = [double]$value } catch { return $false }
        if (-not [double]::IsFinite($number)) { return $false }
    }
    return $true
}

function Test-PortraitCameraContract(
    [object]$Event,
    [string]$ExpectedShotKind,
    [double]$ExpectedCorridorClearance
) {
    $corridor = $Event.cameraCorridor
    return [string]$Event.shotKind -ceq $ExpectedShotKind -and
        -not [string]::IsNullOrWhiteSpace([string]$Event.focusKind) -and
        (Test-FiniteNumberArray @($Event.headForwardXY) 2) -and
        (Test-FiniteNumberArray @($Event.cameraDirectionXY) 2) -and
        [bool]$Event.worldBound.valid -and
        [double]::IsFinite([double]$Event.worldBound.radius) -and
        [double]$Event.worldBound.radius -gt 0.0 -and
        $null -ne $corridor -and
        [double]$corridor.clearanceGameUnits -eq $ExpectedCorridorClearance -and
        [double]::IsFinite([double]$corridor.stopDistance) -and
        [double]$corridor.stopDistance -gt 0.0 -and
        (Test-FiniteNumberArray @($corridor.start) 3) -and
        (Test-FiniteNumberArray @($corridor.end) 3) -and
        (-not [bool]$corridor.passed -or
            ([bool]$corridor.outsideWorldBound -and
                [bool]$corridor.filterAvailable -and
                [bool]$corridor.tesAvailable -and
                [bool]$corridor.invoked -and
                -not [bool]$corridor.faulted -and
                [bool]$corridor.fractionValid -and
                -not [bool]$corridor.hit))
}

function ConvertTo-StableFormKey([uint32]$FormId, [object[]]$RuntimePlugins) {
    if ($FormId -eq 0) { return $null }
    $pluginIndex = [int](($FormId -shr 24) -band 0xff)
    if ($pluginIndex -lt 0 -or $pluginIndex -ge $RuntimePlugins.Count) { return $null }
    $pluginName = [string]$RuntimePlugins[$pluginIndex].name
    if ([string]::IsNullOrWhiteSpace($pluginName)) { return $null }
    return '{0}:{1:x6}' -f $pluginName, ($FormId -band 0x00ffffff)
}

function Assert-AuthoredLiveLocation([object[]]$PoseSamples, [object]$GalleryShot) {
    if ($PoseSamples.Count -lt 1) {
        throw 'Retail authored-reference capture has no actor pose samples for live-location validation.'
    }
    $expectedAuthoredCellForm = [Convert]::ToUInt32(
        [string]$GalleryShot.actor.cellFormId, 16)
    $expectedInterior = [string]$GalleryShot.locationClass -ceq 'interior'
    $expectedWorldSpaceForm = $null
    if ($null -ne $GalleryShot.PSObject.Properties['scene'] -and
        $null -ne $GalleryShot.scene -and
        $null -ne $GalleryShot.scene.PSObject.Properties['worldspaceFormId'] -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$GalleryShot.scene.worldspaceFormId)) {
        $expectedWorldSpaceForm = [Convert]::ToUInt32(
            [string]$GalleryShot.scene.worldspaceFormId, 16)
    }
    $locationSamples = [Collections.Generic.List[object]]::new()
    foreach ($actorFrame in $PoseSamples) {
        $locationProperty = $actorFrame.PSObject.Properties['location']
        if ($null -eq $locationProperty -or $null -eq $locationProperty.Value) {
            throw "Retail authored actor pose frame $($actorFrame.frame) has no live location."
        }
        $location = $locationProperty.Value
        $parentCellForm = [uint32]$location.parentCellForm
        $persistentCellForm = [uint32]$location.persistentCellForm
        $parentWorldSpaceForm = [uint32]$location.parentWorldSpaceForm
        $persistentWorldSpaceForm = [uint32]$location.persistentWorldSpaceForm
        $worldSpaceForm = [uint32]$location.worldSpaceForm
        $interior = [bool]$location.interior
        $coordinates = $location.parentCellCoordinates
        $resolvedWorldSpaceForm = if ($persistentWorldSpaceForm -ne 0) {
            $persistentWorldSpaceForm
        } else { $parentWorldSpaceForm }
        if ($parentCellForm -eq 0 -or
            (($worldSpaceForm -eq 0) -ne $interior) -or
            $worldSpaceForm -ne $resolvedWorldSpaceForm -or
            (($persistentCellForm -eq 0) -ne
                ($persistentWorldSpaceForm -eq 0)) -or
            ($null -ne $coordinates -and
                (@($coordinates).Count -ne 2 -or
                    @($coordinates | Where-Object {
                        $_ -isnot [byte] -and $_ -isnot [sbyte] -and
                        $_ -isnot [int16] -and $_ -isnot [uint16] -and
                        $_ -isnot [int32] -and $_ -isnot [uint32] -and
                        $_ -isnot [int64] -and $_ -isnot [uint64]
                    }).Count -ne 0))) {
            throw "Retail authored actor pose frame $($actorFrame.frame) has an inconsistent live CELL/WRLD relationship."
        }
        [void]$locationSamples.Add([pscustomobject][ordered]@{
            parentCellForm = $parentCellForm
            persistentCellForm = $persistentCellForm
            parentWorldSpaceForm = $parentWorldSpaceForm
            persistentWorldSpaceForm = $persistentWorldSpaceForm
            worldSpaceForm = $worldSpaceForm
            interior = $interior
            parentCellCoordinates = if ($null -eq $coordinates) {
                $null
            } else { @($coordinates | ForEach-Object { [int]$_ }) }
        })
    }
    $locationIdentities = @($locationSamples | ForEach-Object {
        $_ | ConvertTo-Json -Depth 4 -Compress
    } | Sort-Object -Unique)
    if ($locationIdentities.Count -ne 1) {
        throw 'Retail authored actor live CELL/WRLD identity changed during capture.'
    }
    $liveLocation = $locationSamples[0]
    $declaredCellObserved = [uint32]$liveLocation.parentCellForm -eq
        $expectedAuthoredCellForm -or
        [uint32]$liveLocation.persistentCellForm -eq $expectedAuthoredCellForm
    if ([bool]$liveLocation.interior -ne $expectedInterior -or
        -not $declaredCellObserved -or
        ($expectedInterior -and [uint32]$liveLocation.worldSpaceForm -ne 0) -or
        (-not $expectedInterior -and [uint32]$liveLocation.worldSpaceForm -eq 0) -or
        ($null -ne $expectedWorldSpaceForm -and
            [uint32]$liveLocation.worldSpaceForm -ne
                [uint32]$expectedWorldSpaceForm)) {
        throw 'Retail authored actor live CELL/WRLD identity differs from the gallery location contract.'
    }
    return [pscustomobject][ordered]@{
        stable = $true
        sampleCount = $locationSamples.Count
        expectedAuthoredCellForm = $expectedAuthoredCellForm
        expectedWorldSpaceForm = $expectedWorldSpaceForm
        expectedInterior = $expectedInterior
        parentCellForm = [uint32]$liveLocation.parentCellForm
        persistentCellForm = [uint32]$liveLocation.persistentCellForm
        parentWorldSpaceForm = [uint32]$liveLocation.parentWorldSpaceForm
        persistentWorldSpaceForm = [uint32]$liveLocation.persistentWorldSpaceForm
        worldSpaceForm = [uint32]$liveLocation.worldSpaceForm
        interior = [bool]$liveLocation.interior
        parentCellCoordinates = $liveLocation.parentCellCoordinates
    }
}

$planDirectory = Resolve-ObservationPath $PlanRoot
$corpusDirectory = Resolve-ObservationPath $CorpusRoot
$outputDirectory = Resolve-ObservationPath $OutputRoot
$seedDirectory = Resolve-ObservationPath $OracleSeedRoot
$pluginSource = Resolve-ObservationPath $OraclePluginDll
$saveSource = Resolve-ObservationPath $SaveFixture
$galleryShotSource = if ([string]::IsNullOrWhiteSpace($GalleryShotPath)) {
    ''
} else { Resolve-ObservationPath $GalleryShotPath }
$openNvDirectory = if ([string]::IsNullOrWhiteSpace($OpenNvRoot)) {
    ''
} else { Resolve-ObservationPath $OpenNvRoot }
$gameDirectory = Resolve-ObservationPath $GameRoot
$catalogPath = Join-Path $WorldsRoot 'catalog\fnv-jam-background-capture-recipes.json'
$oracleRunner = Join-Path $PSScriptRoot 'Invoke-FNVRetailOracle.ps1'

foreach ($directory in @($planDirectory, $corpusDirectory, $seedDirectory, $gameDirectory)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Missing actor-observation directory: $directory"
    }
}
foreach ($file in @($pluginSource, $saveSource, $catalogPath, $oracleRunner)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing actor-observation file: $file"
    }
}
if (-not [string]::IsNullOrWhiteSpace($galleryShotSource) -and
    -not (Test-Path -LiteralPath $galleryShotSource -PathType Leaf)) {
    throw "Missing authored gallery-shot contract: $galleryShotSource"
}
if ([IO.Path]::GetExtension($saveSource) -ine '.fos') {
    throw "SaveFixture must be a legally owned Fallout: New Vegas .fos file: $saveSource"
}
if (Test-Path -LiteralPath $outputDirectory) {
    throw "Refusing to overwrite an existing actor-observation output: $outputDirectory"
}

$catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
$recipes = @($catalog.actorObservationRecipes | Where-Object {
    [string]$_.id -eq 'fnv-official-actor-retail-observation-v1'
})
if ($recipes.Count -ne 1) {
    throw 'The canonical retail actor-observation recipe is missing or duplicated.'
}
$recipe = $recipes[0]
$policy = $recipe.capturePolicy
$activeRuntimePolicy = $policy.activeRuntime
$telemetryPolicy = $recipe.telemetryPolicy
$faceGenAnimationPolicy = $telemetryPolicy.faceGenAnimation
$surfaceContractPolicy = $telemetryPolicy.surfaceContract
$imageSpacePolicy = $telemetryPolicy.imageSpaceShaderInputs
$imageSpaceTracePolicy = $telemetryPolicy.imageSpacePipelineTrace
$drawContractPolicy = $telemetryPolicy.drawContractDiagnostic
if ([string]$activeRuntimePolicy.schema -cne
        'nikami-xnvse-active-runtime/v1' -or
    [string]::IsNullOrWhiteSpace([string]$activeRuntimePolicy.relativeDirectory) -or
    [IO.Path]::IsPathRooted([string]$activeRuntimePolicy.relativeDirectory) -or
    [IO.Path]::GetFileName([string]$activeRuntimePolicy.manifestFile) -cne
        [string]$activeRuntimePolicy.manifestFile -or
    [IO.Path]::GetFileName([string]$activeRuntimePolicy.pluginDirectory) -cne
        [string]$activeRuntimePolicy.pluginDirectory -or
    [IO.Path]::GetFileName([string]$activeRuntimePolicy.pluginFile) -cne
        [string]$activeRuntimePolicy.pluginFile -or
    [IO.Path]::GetFileName([string]$activeRuntimePolicy.evidenceDirectory) -cne
        [string]$activeRuntimePolicy.evidenceDirectory) {
    throw 'The actor-observation active-runtime policy is incomplete or invalid.'
}
if ([string]$telemetryPolicy.mode -cne 'compact-actor-pose-sample' -or
    [string]$telemetryPolicy.poseEvent -cne 'actor-pose-sample' -or
    [string]$telemetryPolicy.visualSnapshotEvent -cne 'actor-visual-snapshot' -or
    [string]$telemetryPolicy.visualSnapshotFaultEvent -cne 'actor-visual-snapshot-fault' -or
    [int]$telemetryPolicy.requiredVisualSnapshotsPerSourceFrame -ne 1 -or
    [int]$telemetryPolicy.requiredAppearanceSnapshots -ne 1 -or
    [int]$telemetryPolicy.appearanceMaximumEventBytes -lt 1 -or
    -not [bool]$telemetryPolicy.requireSkinPalettesForSkinnedGeometry -or
    [int]$telemetryPolicy.skinPaletteComponentsPerRegister -lt 1 -or
    [int]$telemetryPolicy.skinPaletteBytesPerComponent -lt 1 -or
    [int]$telemetryPolicy.skinPaletteMaximumBytesPerShape -lt 1 -or
    $null -eq $faceGenAnimationPolicy -or
    @($faceGenAnimationPolicy.requiredRecordTypes).Count -lt 1 -or
    [int]$faceGenAnimationPolicy.emotionWeightCount -lt 1 -or
    [int]$faceGenAnimationPolicy.movementWeightCount -lt 1 -or
    [int]$faceGenAnimationPolicy.phonemeWeightCount -lt 1 -or
    [int]$telemetryPolicy.minimumNamedNodesPerSnapshot -lt 1 -or
    [int]$telemetryPolicy.minimumPoseSamples -lt 2 -or
    [int]$telemetryPolicy.cameraMatrixElementCount -ne 16 -or
    [int]$telemetryPolicy.cameraWorldRotationElementCount -ne 9 -or
    [int]$telemetryPolicy.cameraWorldTranslationElementCount -ne 3 -or
    [int]$telemetryPolicy.cameraFrustumElementCount -ne 7 -or
    [int]$telemetryPolicy.cameraViewportElementCount -ne 4 -or
    -not [bool]$telemetryPolicy.requireExactPerspectiveProjection -or
    [int64]$telemetryPolicy.maximumJsonlBytes -lt 1 -or
    @($telemetryPolicy.forbiddenEvents).Count -lt 1) {
    throw 'The actor-observation telemetry policy is incomplete or invalid.'
}
if ($null -eq $surfaceContractPolicy -or
    [string]$surfaceContractPolicy.event -cne 'actor-surface-contract' -or
    [string]$surfaceContractPolicy.targetTexturesEvent -cne
        'actor-draw-contract-target-textures' -or
    [int]$surfaceContractPolicy.renderFrameLead -lt 1 -or
    [int]$surfaceContractPolicy.maximumRecordsPerSourceFrame -lt 1 -or
    [int]$surfaceContractPolicy.textureStageCount -lt 1 -or
    [int]$surfaceContractPolicy.textureStageCount -gt 16 -or
    [int]$surfaceContractPolicy.maximumShaderBytes -lt 1 -or
    [int]$surfaceContractPolicy.matrixElementCount -ne 16 -or
    [double]$surfaceContractPolicy.matrixTolerance -le 0 -or
    -not [bool]$surfaceContractPolicy.requireBackBufferDimensions -or
    [double]$surfaceContractPolicy.normalizedDepthMinimum -ge
        [double]$surfaceContractPolicy.normalizedDepthMaximum) {
    throw 'The actor surface-contract policy is incomplete or invalid.'
}
$semanticFocusRules = @($surfaceContractPolicy.semanticFocusRules)
if ($semanticFocusRules.Count -lt 1 -or
    @($semanticFocusRules | Where-Object {
        $offset = [double]$_.detailAimOffsetGameUnits
        [string]::IsNullOrWhiteSpace([string]$_.kind) -or
            [string]$_.match -cnotin @('exact', 'prefix') -or
            [string]::IsNullOrWhiteSpace([string]$_.value) -or
            [string]$_.kind -match '[,;]' -or
            [string]$_.value -match '[,;]' -or
            [double]::IsNaN($offset) -or [double]::IsInfinity($offset)
    }).Count -ne 0 -or
    @($semanticFocusRules | ForEach-Object {
        "$([string]$_.match)|$([string]$_.value)"
    } | Sort-Object -Unique).Count -ne $semanticFocusRules.Count) {
    throw 'The actor semantic-focus rule policy is incomplete, invalid, or duplicated.'
}
$semanticFocusRulesEncoded = @($semanticFocusRules | ForEach-Object {
    $offsetText = ([double]$_.detailAimOffsetGameUnits).ToString(
        'R', [Globalization.CultureInfo]::InvariantCulture)
    "$([string]$_.kind),$([string]$_.match),$([string]$_.value),$offsetText"
}) -join ';'
if ($null -eq $imageSpacePolicy -or
    [string]$imageSpacePolicy.event -cne 'image-space-shader-constants' -or
    [string]$imageSpacePolicy.path -cne 'hdr-cinematic' -or
    [int]$imageSpacePolicy.expectedShaderByteCount -lt 1 -or
    [uint32]$imageSpacePolicy.expectedShaderFnv1a32 -eq 0 -or
    @($imageSpacePolicy.inputTextureStages).Count -ne 2 -or
    @($imageSpacePolicy.inputTextureStages | Sort-Object -Unique).Count -ne 2 -or
    @($imageSpacePolicy.inputTextureStages |
        Where-Object { [int]$_ -lt 0 -or [int]$_ -ge 16 }).Count -ne 0 -or
    [int]$imageSpacePolicy.renderFrameLead -lt 1 -or
    [int]$imageSpacePolicy.renderFrameLead -ne
        [int]$surfaceContractPolicy.renderFrameLead -or
    [int]$imageSpacePolicy.maximumBytesPerInput -lt 1 -or
    -not [bool]$imageSpacePolicy.requireCanonicalRows -or
    -not [bool]$imageSpacePolicy.requireImmutableArtifacts) {
    throw 'The actor image-space shader-input policy is incomplete or invalid.'
}
if ($null -eq $imageSpaceTracePolicy -or
    [string]$imageSpaceTracePolicy.event -cne 'image-space-pipeline-trace' -or
    [int]$imageSpaceTracePolicy.renderFrameLead -lt 1 -or
    [int]$imageSpaceTracePolicy.renderFrameLead -ne
        [int]$imageSpacePolicy.renderFrameLead -or
    @($imageSpaceTracePolicy.pixelShaderFnv1a32).Count -lt 1 -or
    @($imageSpaceTracePolicy.pixelShaderFnv1a32 | Sort-Object -Unique).Count -ne
        @($imageSpaceTracePolicy.pixelShaderFnv1a32).Count -or
    @($imageSpaceTracePolicy.pixelShaderFnv1a32 |
        Where-Object { [uint64]$_ -eq 0 -or [uint64]$_ -gt [uint32]::MaxValue }).Count -ne 0 -or
    [int]$imageSpaceTracePolicy.maximumRecords -lt 1 -or
    [int]$imageSpaceTracePolicy.minimumRecords -lt 1 -or
    [int]$imageSpaceTracePolicy.minimumRecords -gt
        [int]$imageSpaceTracePolicy.maximumRecords -or
    [int]$imageSpaceTracePolicy.textureStageCount -lt 1 -or
    [int]$imageSpaceTracePolicy.textureStageCount -gt 16 -or
    [int]$imageSpaceTracePolicy.vertexShaderRegisterCount -lt 1 -or
    [int]$imageSpaceTracePolicy.vertexShaderRegisterCount -gt 256 -or
    [int]$imageSpaceTracePolicy.pixelShaderRegisterCount -lt 1 -or
    [int]$imageSpaceTracePolicy.pixelShaderRegisterCount -gt 224 -or
    [int]$imageSpaceTracePolicy.maximumShaderBytes -lt 1 -or
    [int]$imageSpaceTracePolicy.maximumVertexBytes -lt 1) {
    throw 'The actor image-space pipeline-trace policy is incomplete or invalid.'
}
if ($null -eq $drawContractPolicy -or
    [string]$drawContractPolicy.event -cne 'actor-draw-contract' -or
    [string]$drawContractPolicy.targetTexturesEvent -cne
        'actor-draw-contract-target-textures' -or
    [string]$drawContractPolicy.boundTextureArtifactsEvent -cne
        'actor-draw-contract-bound-textures' -or
    [int]$drawContractPolicy.renderFrameLead -lt 1 -or
    [int]$drawContractPolicy.textureStageCount -lt 1 -or
    [int]$drawContractPolicy.textureStageCount -gt 16 -or
    [int]$drawContractPolicy.maximumRecordsPerSourceFrame -lt 1 -or
    [int]$drawContractPolicy.vertexShaderRegisterCount -lt 1 -or
    [int]$drawContractPolicy.vertexShaderRegisterCount -gt 256 -or
    [int]$drawContractPolicy.pixelShaderRegisterCount -lt 1 -or
    [int]$drawContractPolicy.pixelShaderRegisterCount -gt 224 -or
    [int]$drawContractPolicy.maximumShaderBytes -lt 1 -or
    [int]$drawContractPolicy.maximumBufferBytesPerRecord -lt 1 -or
    [int]$drawContractPolicy.maximumTextureBytesPerArtifact -lt 1) {
    throw 'The actor draw-contract diagnostic policy is incomplete or invalid.'
}
if ($TimeoutSeconds -le 0) {
    $TimeoutSeconds = [int]$policy.timeoutSeconds
}

$planManifestPath = Join-Path $planDirectory 'manifest.json'
$corpusManifestPath = Join-Path $corpusDirectory 'manifest.json'
foreach ($manifestPath in @($planManifestPath, $corpusManifestPath)) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Missing immutable actor manifest: $manifestPath"
    }
}
$planManifest = Get-Content -Raw -LiteralPath $planManifestPath | ConvertFrom-Json
$corpusManifest = Get-Content -Raw -LiteralPath $corpusManifestPath | ConvertFrom-Json
if ([string]$planManifest.schema -cne 'opennv-actor-capture-plan/v1' -or
    [string]$corpusManifest.schema -cne 'opennv-actor-parity-corpus/v1') {
    throw 'Actor plan or corpus schema is not canonical v1.'
}
$jobsPath = Assert-ManifestFile $planDirectory $planManifest.outputs.jobs 'capture jobs'
$appearancePath = Assert-ManifestFile $corpusDirectory $corpusManifest.outputs.appearanceReview `
    'appearance review ledger'
if ([string]$planManifest.sourceCorpus.appearanceReviewSha256 -cne
    [string]$corpusManifest.outputs.appearanceReview.sha256) {
    throw 'Capture plan is not bound to the supplied appearance-review ledger.'
}

$jobMatches = [Collections.Generic.List[object]]::new()
foreach ($line in [IO.File]::ReadLines($jobsPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $row = $line | ConvertFrom-Json
    if ([string]$row.captureJobKey -ceq $CaptureJobKey) {
        $jobMatches.Add($row)
    }
}
if ($jobMatches.Count -ne 1) {
    throw "CaptureJobKey '$CaptureJobKey' matched $($jobMatches.Count) plan rows."
}
$job = $jobMatches[0]
if ([string]$job.recordType -notin @('NPC_', 'CREA') -or
    [string]$job.baseRuntimeFormId -notmatch '^[0-9a-fA-F]{8}$') {
    throw "Capture job '$CaptureJobKey' has an invalid actor type or runtime FormID."
}

$galleryShot = $null
$retailGrassCaptureEnabled = $false
$retailGrassPolicy = $null
$runtimeConfigurationPath = ''
$galleryPresentationShotKinds = @()
$authoredSceneEditorId = ''
$authoredReferenceMode = -not [string]::IsNullOrWhiteSpace($galleryShotSource)
if ($authoredReferenceMode) {
    $galleryShot = Get-Content -Raw -LiteralPath $galleryShotSource | ConvertFrom-Json
    if ([string]$galleryShot.schema -cne 'opennv-gallery-capture-shot/v1' -or
        [string]$galleryShot.status -cne 'owned-authored-capture-request' -or
        [string]::IsNullOrWhiteSpace([string]$galleryShot.id) -or
        [int]$galleryShot.ordinal -lt 1 -or
        [string]::IsNullOrWhiteSpace([string]$galleryShot.locationId) -or
        [string]$galleryShot.referenceFormId -notmatch '^[0-9a-fA-F]{8}$' -or
        [string]$galleryShot.baseFormId -notmatch '^[0-9a-fA-F]{8}$' -or
        [string]$galleryShot.actor.cellFormId -notmatch '^[0-9a-fA-F]{8}$' -or
        [string]$galleryShot.scene.cellFormId -notmatch '^[0-9a-fA-F]{8}$' -or
        [string]$galleryShot.locationClass -cnotin @('interior', 'exterior') -or
        [bool]$galleryShot.scene.interior -ne
            ([string]$galleryShot.locationClass -ceq 'interior') -or
        ([bool]$galleryShot.scene.interior -and
            $null -ne $galleryShot.scene.worldspaceFormId) -or
        (-not [bool]$galleryShot.scene.interior -and
            [string]$galleryShot.scene.worldspaceFormId -notmatch
                '^[0-9a-fA-F]{8}$') -or
        [string]$galleryShot.enableState.mode -cnotin
            @('authored', 'proof-enable-initially-disabled')) {
        throw "Authored gallery capture-shot contract is incomplete or invalid: $galleryShotSource"
    }
    if ([string]$galleryShot.baseFormId -cne [string]$job.baseRuntimeFormId -or
        [string]$galleryShot.recordType -cne [string]$job.recordType) {
        throw 'Authored gallery shot and immutable actor capture job identify different bases.'
    }
    if ([string]::IsNullOrWhiteSpace($openNvDirectory) -or
        -not (Test-Path -LiteralPath $openNvDirectory -PathType Container)) {
        throw 'Authored-reference capture requires the current OpenNV root.'
    }
    $declaredRuntimeConfigurationPath = Assert-FileDescriptor `
        $galleryShot.runtimeConfiguration 'Gallery runtime configuration'
    $runtimeConfigurationPath = Join-Path $openNvDirectory `
        'runtime\config\open-nv-runtime-v1.json'
    if ([IO.Path]::GetFullPath($declaredRuntimeConfigurationPath) -cne
        [IO.Path]::GetFullPath($runtimeConfigurationPath)) {
        throw 'Gallery capture shot names another OpenNV runtime configuration.'
    }
    $runtimeConfiguration = Get-Content -Raw -LiteralPath $runtimeConfigurationPath |
        ConvertFrom-Json
    $declaredGalleryPath = Assert-FileDescriptor `
        $galleryShot.gallery 'Gallery recipe'
    $expectedGalleryPath = Join-Path $openNvDirectory (
        'content\recipes\' + [string]$runtimeConfiguration.tooling.recipeFiles.gallery)
    if ([IO.Path]::GetFullPath($declaredGalleryPath) -cne
        [IO.Path]::GetFullPath($expectedGalleryPath)) {
        throw 'Gallery capture shot names another declarative gallery recipe.'
    }
    $galleryRecipe = Get-Content -Raw -LiteralPath $declaredGalleryPath |
        ConvertFrom-Json
    $galleryLocationMatches = @($galleryRecipe.locations | Where-Object {
        [string]$_.id -ceq [string]$galleryShot.locationId
    })
    if ($galleryLocationMatches.Count -ne 1) {
        throw 'Gallery capture shot does not resolve exactly one declarative location.'
    }
    if ([string]$galleryShot.locationClass -ceq 'exterior') {
        $authoredSceneEditorId = [string]$galleryLocationMatches[0].retailLoadEditorId
        if ([string]::IsNullOrWhiteSpace($authoredSceneEditorId) -or
            $authoredSceneEditorId -match '["\r\n]') {
            throw 'Exterior gallery location has no safe declarative CELL EditorID.'
        }
    }
    if ([string]$galleryShot.locationClass -ceq 'exterior') {
        $retailGrassPolicy = $runtimeConfiguration.contentCompiler.retailGrass
        $retailGrassCapturePolicy = $retailGrassPolicy.capture
        $galleryPresentationSelection =
            $runtimeConfiguration.capture.gallery.retailPresentationSelection
        $galleryPresentationShotKinds = @(
            $galleryPresentationSelection.candidateShotKinds |
                ForEach-Object { [string]$_ })
        if ([string]$runtimeConfiguration.schema -cne 'opennv-runtime-configuration/v1' -or
            [string]$retailGrassPolicy.schema -cne
                'opennv-retail-grass-compiler-contract/v1' -or
            [string]$retailGrassCapturePolicy.schema -cne
                'opennv-retail-grass-capture-contract/v1' -or
            [string]$retailGrassCapturePolicy.event -cne 'texture-sampler-contract' -or
            [string]$galleryPresentationSelection.schema -cne
                'opennv-gallery-presentation-selection/v1' -or
            $galleryPresentationShotKinds.Count -lt 1 -or
            @($galleryPresentationShotKinds | Sort-Object -Unique).Count -ne
                $galleryPresentationShotKinds.Count -or
            [int]$retailGrassPolicy.texture.widthPixels -lt 1 -or
            [int]$retailGrassPolicy.texture.heightPixels -lt 1 -or
            [int]$retailGrassPolicy.texture.levelCount -lt 1 -or
            [uint32]$retailGrassPolicy.texture.d3d9Format -eq 0 -or
            [int]$retailGrassCapturePolicy.textureStageCount -lt 1 -or
            [int]$retailGrassCapturePolicy.maximumCandidates -lt 1 -or
            [int]$retailGrassCapturePolicy.maximumRecords -lt 1 -or
            [int]$retailGrassCapturePolicy.maximumShaderBytes -lt 1 -or
            [int]$retailGrassCapturePolicy.maximumVertexBufferBytes -lt 1 -or
            [int]$retailGrassCapturePolicy.minimumMatchingRecords -lt 1 -or
            [int]$retailGrassCapturePolicy.requiredMatchedResourceCount -lt 1 -or
            -not [bool]$retailGrassCapturePolicy.requireEveryObservedMesh -or
            [int]$retailGrassPolicy.shader.vertexConstantRegisterCount -lt 1 -or
            [int]$retailGrassPolicy.shader.pixelConstantRegisterCount -lt 1 -or
            @($retailGrassPolicy.meshes).Count -lt 1) {
            throw 'OpenNV retail grass capture contract is incomplete or invalid.'
        }
        [void](ConvertFrom-CanonicalHexUInt32 `
            ([string]$retailGrassPolicy.texture.fnv1a32) 'Retail grass texture hash')
        [void](ConvertFrom-CanonicalHexUInt32 `
            ([string]$retailGrassPolicy.texture.topLevelFnv1a32) `
            'Retail grass top-level texture hash')
        [void](ConvertFrom-CanonicalHexUInt32 `
            ([string]$retailGrassPolicy.shader.vertexFnv1a32) `
            'Retail grass vertex shader hash')
        [void](ConvertFrom-CanonicalHexUInt32 `
            ([string]$retailGrassPolicy.shader.pixelFnv1a32) `
            'Retail grass pixel shader hash')
        $retailGrassCaptureEnabled = $true
    }
}

$expectedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($key in @($job.expectedReviewKeys)) {
    if (-not $expectedKeys.Add([string]$key)) {
        throw "Capture job '$CaptureJobKey' contains a duplicate expected review key."
    }
}
$reviewRows = [Collections.Generic.List[object]]::new()
foreach ($line in [IO.File]::ReadLines($appearancePath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $row = $line | ConvertFrom-Json
    if ($expectedKeys.Contains([string]$row.reviewKey)) {
        $reviewRows.Add($row)
    }
}
if ($reviewRows.Count -ne $expectedKeys.Count -or
    $reviewRows.Count -ne [int]$job.expectedOutcomeCount) {
    throw "Capture job '$CaptureJobKey' does not resolve its complete expected review set."
}
foreach ($row in $reviewRows) {
    if ([string]$row.baseFormKey -cne [string]$job.baseFormKey -or
        [string]$row.baseRuntimeFormId -cne [string]$job.baseRuntimeFormId -or
        [string]$row.recordType -cne [string]$job.recordType) {
        throw "Review row '$($row.reviewKey)' does not belong to '$CaptureJobKey'."
    }
}

$requiredShotKinds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($row in $reviewRows) {
    $rowShots = @($row.requiredShots | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    foreach ($shotKind in $rowShots) { [void]$requiredShotKinds.Add($shotKind) }
}
$shotTimeline = @($policy.shotTimeline)
if ($shotTimeline.Count -lt 1 -or $null -eq $policy.shotKindOverridesByRecordType) {
    throw 'Actor-observation capture policy declares no record-aware review timeline.'
}
$recordTypeMappings = @($policy.shotKindOverridesByRecordType.PSObject.Properties |
    Where-Object { [string]$_.Name -ceq [string]$job.recordType })
if ($recordTypeMappings.Count -ne 1) {
    throw "Actor-observation capture policy does not map record type '$($job.recordType)'."
}
$recordTypeMapping = $recordTypeMappings[0].Value
$runtimeForm = ([string]$job.baseRuntimeFormId).ToUpperInvariant()
$targetRuntimeForm = if ($authoredReferenceMode) {
    ([string]$galleryShot.referenceFormId).ToUpperInvariant()
} else { $runtimeForm }
$shots = [Collections.Generic.List[object]]::new()
$authoredReferencePolicy = if ($authoredReferenceMode) {
    $policy.authoredReferenceCapture
} else { $null }
$frameOffset = 0
$renderEnvironmentFrame = 0
$authoredSceneLoadFrame = 0
$authoredReferenceMoveFrame = 0
$authoredReferenceEnableFrame = 0
$authoredRuntimeState = $null
if ($authoredReferenceMode) {
    if ($null -eq $authoredReferencePolicy -or
        [int]$authoredReferencePolicy.enableFrame -lt 1 -or
        [int]$authoredReferencePolicy.loadFrame -le
            [int]$authoredReferencePolicy.enableFrame -or
        [int]$authoredReferencePolicy.minimumStreamingSettleFrames -lt 1 -or
        [string]$authoredReferencePolicy.interiorLoadMode -cne
            'authored-reference' -or
        [string]$authoredReferencePolicy.exteriorLoadMode -cne
            'scene-editor-id-then-authored-reference' -or
        [string]::IsNullOrWhiteSpace([string]$authoredReferencePolicy.captureMethod)) {
        throw 'Actor-observation authored-reference policy is incomplete or invalid.'
    }
    $runtimeStateMatches = @(
        $authoredReferencePolicy.runtimeStateByReferenceFormId.PSObject.Properties |
            Where-Object { [string]$_.Name -ceq $targetRuntimeForm })
    if ($runtimeStateMatches.Count -gt 1) {
        throw 'Authored-reference runtime-state map contains duplicate reference FormIDs.'
    }
    if ($runtimeStateMatches.Count -eq 1) {
        $authoredRuntimeState = $runtimeStateMatches[0].Value
        $runtimeStateProvenance = $authoredRuntimeState.provenance
        $runtimeStateSourceMatches = @($corpusManifest.inputs | Where-Object {
            [string]$_.file -ceq [string]$runtimeStateProvenance.sourceFile
        })
        $derivedGameHour = [double]$runtimeStateProvenance.packageStartHour +
            ([double]$runtimeStateProvenance.packageDurationHours / 2.0)
        if ([string]$authoredRuntimeState.mode -cne
                'game-hour-from-owned-package-midpoint' -or
            [int]$authoredRuntimeState.frame -lt 1 -or
            [int]$authoredRuntimeState.frame -ge
                [int]$authoredReferencePolicy.loadFrame -or
            [int]$authoredRuntimeState.evaluatePackageFrame -ne
                [int]$authoredReferencePolicy.loadFrame -or
            [double]$authoredRuntimeState.gameHour -lt 0.0 -or
            [double]$authoredRuntimeState.gameHour -ge 24.0 -or
            [double]$authoredRuntimeState.gameHour -ne $derivedGameHour -or
            [string]$runtimeStateProvenance.sourceFile -cne 'FalloutNV.esm' -or
            $runtimeStateSourceMatches.Count -ne 1 -or
            [string]$runtimeStateProvenance.sourceFileSha256 -cne
                [string]$runtimeStateSourceMatches[0].sha256 -or
            [string]$runtimeStateProvenance.packageFormId -notmatch
                '^[0-9a-fA-F]{8}$' -or
            [string]::IsNullOrWhiteSpace(
                [string]$runtimeStateProvenance.packageEditorId) -or
            [string]$runtimeStateProvenance.selection -cne 'midpoint') {
            throw 'Authored-reference runtime state is not a complete owned-package midpoint contract.'
        }
    }
    $firstConfiguredSetFrame = [int](
        @($shotTimeline | ForEach-Object { [int]$_.setFrame } | Sort-Object)[0]
    )
    $authoredSceneLoadFrame = [int]$authoredReferencePolicy.loadFrame
    $authoredReferenceMoveFrame = $authoredSceneLoadFrame
    $authoredReferenceEnableFrame = [int]$authoredReferencePolicy.enableFrame
    if ([string]$galleryShot.locationClass -ceq 'exterior') {
        if ($null -ne $authoredRuntimeState) {
            $authoredSceneLoadFrame =
                [int]$authoredRuntimeState.evaluatePackageFrame +
                [int]$authoredReferencePolicy.minimumStreamingSettleFrames
        }
        $authoredReferenceMoveFrame = $authoredSceneLoadFrame +
            [int]$authoredReferencePolicy.minimumStreamingSettleFrames
        $authoredReferenceEnableFrame = $authoredReferenceMoveFrame -
            ([int]$authoredReferencePolicy.loadFrame -
                [int]$authoredReferencePolicy.enableFrame)
    }
    $minimumAuthoredSetFrame = $authoredReferenceMoveFrame +
        [int]$authoredReferencePolicy.minimumStreamingSettleFrames
    $renderEnvironmentFrame = $minimumAuthoredSetFrame
    $frameOffset = [Math]::Max(0, $minimumAuthoredSetFrame - $firstConfiguredSetFrame)
}
foreach ($timelineShot in $shotTimeline) {
    $slot = [string]$timelineShot.slot
    if ([string]::IsNullOrWhiteSpace($slot)) {
        throw 'Actor-observation review timeline contains an empty shot slot.'
    }
    $slotOverrides = @($recordTypeMapping.PSObject.Properties |
        Where-Object { [string]$_.Name -ceq $slot })
    if ($slotOverrides.Count -gt 1) {
        throw "Actor-observation shot slot '$slot' has duplicate record-type overrides."
    }
    $shotKind = if ($slotOverrides.Count -eq 1) { [string]$slotOverrides[0].Value } else { $slot }
    $shots.Add([pscustomobject][ordered]@{
        kind = $shotKind
        setFrame = [int]$timelineShot.setFrame + $frameOffset
        screenshotFrames = @($timelineShot.screenshotFrames | ForEach-Object {
            [int]$_ + $frameOffset
        })
        reviewRequired = if ($null -ne $timelineShot.PSObject.Properties['reviewRequired']) {
            [bool]$timelineShot.reviewRequired
        } else { $true }
    })
}
$captureMaxFrames = [int]$policy.maxFrames + $frameOffset
$captureAfterFrame = [int]$policy.afterFrame + $frameOffset
$configuredShotKinds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$screenshotFrames = [Collections.Generic.List[int]]::new()
$shotFrameKinds = [Collections.Generic.Dictionary[int,string]]::new()
$shotFrameReviewRequired = [Collections.Generic.Dictionary[int,bool]]::new()
foreach ($shot in $shots) {
    $shotKind = [string]$shot.kind
    $setFrame = [int]$shot.setFrame
    $frames = @($shot.screenshotFrames | ForEach-Object { [int]$_ })
    if ([string]::IsNullOrWhiteSpace($shotKind) -or
        -not $configuredShotKinds.Add($shotKind) -or $frames.Count -lt 1 -or
        $setFrame -le ([int]$policy.stageFrame + $frameOffset)) {
        throw 'Actor-observation review shots contain an invalid or duplicate shot declaration.'
    }
    foreach ($frame in $frames) {
        if ($frame -le $setFrame -or $frame -gt $captureMaxFrames -or
            $shotFrameKinds.ContainsKey($frame)) {
            throw "Actor-observation screenshot frame '$frame' is invalid or duplicated."
        }
        $screenshotFrames.Add($frame)
        $shotFrameKinds.Add($frame, $shotKind)
        $shotFrameReviewRequired.Add($frame, [bool]$shot.reviewRequired)
    }
}
$configuredRequiredShotKinds = @($shots | Where-Object {
    [bool]$_.reviewRequired
} | ForEach-Object { [string]$_.kind } | Sort-Object -Unique)
if (($configuredRequiredShotKinds -join "`n") -cne
    (@($requiredShotKinds | Sort-Object) -join "`n")) {
    throw 'Configured retail shot kinds do not exactly cover the immutable review ledger.'
}
$motionPolicy = $policy.motionVideo
$motionShots = @($shots | Where-Object { [string]$_.kind -ceq [string]$motionPolicy.shotKind })
if ($motionShots.Count -ne 1 -or @($motionShots[0].screenshotFrames).Count -lt 2 -or
    [int]$motionPolicy.timelineFrameRate -lt 1 -or
    [int]$motionPolicy.tailDurationFrames -lt 1 -or
    [int]$motionPolicy.outputFrameRate -lt 1 -or
    [int]$motionPolicy.crf -lt 0 -or
    [string]::IsNullOrWhiteSpace([string]$motionPolicy.file)) {
    throw 'Actor-observation motion-video policy is incomplete or invalid.'
}
$imageSpaceSourceFrame = [int](@($screenshotFrames | Sort-Object)[0])
$textureSamplerSourceFrames = @()
if ($retailGrassCaptureEnabled) {
    $presentationSourceFrames = [Collections.Generic.List[int]]::new()
    $seenPresentationSourceFrames = [Collections.Generic.HashSet[int]]::new()
    foreach ($candidateShotKind in $galleryPresentationShotKinds) {
        $presentationShots = @($shots | Where-Object {
            [string]$_.kind -ceq $candidateShotKind
        })
        if ($presentationShots.Count -eq 0) {
            continue
        }
        if ($presentationShots.Count -ne 1 -or
            @($presentationShots[0].screenshotFrames).Count -lt 1) {
            throw "Retail grass capture candidate '$candidateShotKind' has no source frame."
        }
        $candidateSourceFrame = [int](@(
            $presentationShots[0].screenshotFrames | ForEach-Object { [int]$_ } |
                Sort-Object
        )[0])
        if ($seenPresentationSourceFrames.Add($candidateSourceFrame)) {
            $presentationSourceFrames.Add($candidateSourceFrame)
        }
    }
    if ($presentationSourceFrames.Count -lt 1) {
        throw 'Retail grass capture resolved no presentation source frames.'
    }
    $textureSamplerSourceFrames = @($presentationSourceFrames | Sort-Object)
}
$ffmpeg = Get-Command ffmpeg -ErrorAction Stop | Select-Object -First 1
$ffprobe = Get-Command ffprobe -ErrorAction Stop | Select-Object -First 1

$expectedPluginNames = @($recipe.officialPlugins | ForEach-Object { [string]$_ })
$corpusInputs = @($corpusManifest.inputs | Sort-Object { [int]$_.loadOrderIndex })
$corpusPluginNames = @($corpusInputs | ForEach-Object { [string]$_.file })
if (($expectedPluginNames -join "`n") -cne ($corpusPluginNames -join "`n")) {
    throw 'Recipe official plugin order differs from the immutable corpus.'
}
$stackText = ($corpusInputs | ForEach-Object {
    '{0}:{1}:{2}' -f [int]$_.loadOrderIndex, [string]$_.file, [string]$_.sha256
}) -join "`n"
$stackBytes = [Text.UTF8Encoding]::new($false).GetBytes($stackText + "`n")
$officialPluginStackSha256 = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($stackBytes)).ToLowerInvariant()

New-Item -ItemType Directory -Path $outputDirectory | Out-Null
$seedManifestPath = Join-Path $seedDirectory 'oracle-runtime-manifest.json'
if (-not (Test-Path -LiteralPath $seedManifestPath -PathType Leaf)) {
    throw "Missing seed oracle runtime manifest: $seedManifestPath"
}
$seedManifest = Get-Content -Raw -LiteralPath $seedManifestPath | ConvertFrom-Json
$pluginSourceHash = Get-LowerSha256 $pluginSource
$runtimeDirectory = Resolve-ContainedPath `
    $WorldsRoot ([string]$activeRuntimePolicy.relativeDirectory) `
    'Actor-observation active runtime'
$runtimePluginDirectory = Resolve-ContainedPath `
    $runtimeDirectory ([string]$activeRuntimePolicy.pluginDirectory) `
    'Actor-observation active plugin directory'
$runtimePluginPath = Resolve-ContainedPath `
    $runtimePluginDirectory ([string]$activeRuntimePolicy.pluginFile) `
    'Actor-observation active plugin'
$runtimeManifestPath = Resolve-ContainedPath `
    $runtimeDirectory ([string]$activeRuntimePolicy.manifestFile) `
    'Actor-observation active runtime manifest'
$runtimeFiles = [ordered]@{}
foreach ($entryName in @('loader', 'steamLoader', 'core')) {
    $entry = $seedManifest.files.$entryName
    $source = Join-Path $seedDirectory ([string]$entry.path)
    if ((Get-LowerSha256 $source) -cne [string]$entry.sha256) {
        throw "Seed oracle runtime file differs from its manifest: $source"
    }
    $runtimeFiles[$entryName] = [ordered]@{
        path = [string]$entry.path
        sha256 = [string]$entry.sha256
    }
}
$runtimeFiles['plugin'] = [ordered]@{
    path = ([string]$activeRuntimePolicy.pluginDirectory + '/' +
        [string]$activeRuntimePolicy.pluginFile)
    sha256 = $pluginSourceHash
}
$expectedRuntimeManifest = [ordered]@{
    schema = [string]$activeRuntimePolicy.schema
    overlay = $seedManifest.overlay
    files = $runtimeFiles
}
$runtimeCurrent = Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf
if ($runtimeCurrent) {
    $existingRuntimeManifest = Get-Content -Raw -LiteralPath $runtimeManifestPath |
        ConvertFrom-Json
    $runtimeCurrent =
        [string]$existingRuntimeManifest.schema -ceq
            [string]$expectedRuntimeManifest.schema -and
        [string]$existingRuntimeManifest.overlay.replayedTree -ceq
            [string]$expectedRuntimeManifest.overlay.replayedTree
    if ($runtimeCurrent) {
        foreach ($entryName in @('loader', 'steamLoader', 'core', 'plugin')) {
            $entry = $expectedRuntimeManifest.files.$entryName
            $path = Resolve-ContainedPath `
                $runtimeDirectory ([string]$entry.path) `
                "Actor-observation active runtime $entryName"
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                (Get-LowerSha256 $path) -cne [string]$entry.sha256) {
                $runtimeCurrent = $false
                break
            }
        }
    }
}
if (-not $runtimeCurrent) {
    $activeEngines = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '^(FalloutNV|nvse_loader)$'
    })
    if ($activeEngines.Count -ne 0) {
        throw "Cannot refresh the active actor-observation runtime while retail is running: " +
            ($activeEngines.ProcessName -join ', ')
    }
    New-Item -ItemType Directory -Path $runtimePluginDirectory -Force | Out-Null
    foreach ($entryName in @('loader', 'steamLoader', 'core')) {
        $entry = $seedManifest.files.$entryName
        Copy-Item -LiteralPath (Join-Path $seedDirectory ([string]$entry.path)) `
            -Destination (Resolve-ContainedPath `
                $runtimeDirectory ([string]$entry.path) `
                "Actor-observation active runtime $entryName") -Force
    }
    Copy-Item -LiteralPath $pluginSource -Destination $runtimePluginPath -Force
    Write-CurrentJson $runtimeManifestPath $expectedRuntimeManifest
}
foreach ($entryName in @('loader', 'steamLoader', 'core', 'plugin')) {
    $entry = $expectedRuntimeManifest.files.$entryName
    $path = Resolve-ContainedPath `
        $runtimeDirectory ([string]$entry.path) `
        "Actor-observation active runtime $entryName"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-LowerSha256 $path) -cne [string]$entry.sha256) {
        throw "Active actor-observation runtime file differs after refresh: $path"
    }
}

$retailDirectory = Join-Path $outputDirectory 'retail'
New-Item -ItemType Directory -Path $retailDirectory | Out-Null
$runtimeEvidenceDirectory = Resolve-ContainedPath `
    $retailDirectory ([string]$activeRuntimePolicy.evidenceDirectory) `
    'Actor-observation runtime evidence directory'
New-Item -ItemType Directory -Path $runtimeEvidenceDirectory | Out-Null
$runtimeEvidencePluginPath = Resolve-ContainedPath `
    $runtimeEvidenceDirectory ([string]$activeRuntimePolicy.pluginFile) `
    'Actor-observation retained plugin evidence'
$runtimeEvidenceManifestPath = Resolve-ContainedPath `
    $runtimeEvidenceDirectory ([string]$activeRuntimePolicy.manifestFile) `
    'Actor-observation retained runtime manifest'
Copy-Item -LiteralPath $runtimePluginPath -Destination $runtimeEvidencePluginPath
Copy-Item -LiteralPath $runtimeManifestPath -Destination $runtimeEvidenceManifestPath
$drawArtifactDirectory = Join-Path $retailDirectory 'actor-draw-contract'
if ($ActorDrawContractDiagnostic) {
    New-Item -ItemType Directory -Path $drawArtifactDirectory | Out-Null
}
$imageSpaceArtifactDirectory = Join-Path $retailDirectory 'image-space-shader-inputs'
New-Item -ItemType Directory -Path $imageSpaceArtifactDirectory | Out-Null
$jsonlPath = Join-Path $retailDirectory 'actor-observation.jsonl'
$screensDirectory = Join-Path $retailDirectory 'native-d3d9-frames'
$scheduledCommands = @(if ($authoredReferenceMode) {
    $commands = [Collections.Generic.List[string]]::new()
    if ($null -ne $authoredRuntimeState) {
        $gameHourText = ([double]$authoredRuntimeState.gameHour).ToString(
            [Globalization.CultureInfo]::InvariantCulture)
        $commands.Add(
            ('{0}:set gamehour to {1}' -f
                [int]$authoredRuntimeState.frame,
                $gameHourText))
        $commands.Add(
            ('{0}@0x{1}:evp' -f
                [int]$authoredRuntimeState.evaluatePackageFrame,
                $targetRuntimeForm))
    }
    if ([string]$galleryShot.locationClass -ceq 'exterior') {
        $commands.Add(
            ('{0}:coc "{1}"' -f
                $authoredSceneLoadFrame,
                $authoredSceneEditorId))
    }
    if ([string]$galleryShot.enableState.mode -ceq 'proof-enable-initially-disabled') {
        $commands.Add(
            ('{0}@0x{1}:Enable' -f
                $authoredReferenceEnableFrame,
                $targetRuntimeForm))
    }
    $commands.Add(
        ('{0}:player.moveto {1}' -f
            $authoredReferenceMoveFrame,
            $targetRuntimeForm))
    @($commands)
} else {
    $distanceText = ([double]$policy.stageDistance).ToString(
        [Globalization.CultureInfo]::InvariantCulture)
    @(
        '{0}:SpawnActor {1}' -f [int]$policy.spawnFrame, $runtimeForm
        '{0}:ResolveSpawnedActor' -f [int]$policy.resolveFrame
        '{0}@0xffffffff:StageInFrontOfPlayer {1}' -f
            [int]$policy.stageFrame,
            $distanceText
    )
})
$scheduledCommands += @($shots | ForEach-Object {
    '{0}:SetReviewShot {1}' -f [int]$_.setFrame, [string]$_.kind
})
$oracleArguments = @{
    GameRoot = $gameDirectory
    RuntimeRoot = $runtimeDirectory
    PluginDll = $runtimePluginPath
    OutputPath = $jsonlPath
    SaveFixture = $saveSource
    QuestForm = @()
    GlobalForm = @()
    Command = @()
    ScheduledCommand = $scheduledCommands
    BeforeFrame = [int]$policy.beforeFrame
    CommandFrame = [int]$policy.commandFrame
    AfterFrame = $captureAfterFrame
    MaxFrames = $captureMaxFrames
    RenderEnvironmentFrame = $renderEnvironmentFrame
    TimeoutSeconds = $TimeoutSeconds
    SampleEvery = [int]$policy.sampleEvery
    TargetForm = "0x$targetRuntimeForm"
    ExpectedTargetBaseForm = if ($authoredReferenceMode) { "0x$runtimeForm" } else { '0' }
    SpawnBaseCapture = -not $authoredReferenceMode
    CaptureAnimation = $true
    TargetAnimationOnly = $true
    CompactActorTelemetry = $true
    ActorAppearanceMaximumEventBytes =
        [int]$telemetryPolicy.appearanceMaximumEventBytes
    CaptureActorSkinPalettes = $true
    ActorSkinPaletteMaximumBytesPerShape =
        [int]$telemetryPolicy.skinPaletteMaximumBytesPerShape
    CaptureActorSurfaceContract = $true
    ActorSurfaceMaximumShaderBytes =
        [int]$surfaceContractPolicy.maximumShaderBytes
    ActorSurfaceTextureStageCount =
        [int]$surfaceContractPolicy.textureStageCount
    ActorSurfaceRenderFrameLead =
        [int]$surfaceContractPolicy.renderFrameLead
    ActorSurfaceMaximumRecordsPerSourceFrame =
        [int]$surfaceContractPolicy.maximumRecordsPerSourceFrame
    CaptureActorDrawContract = [bool]$ActorDrawContractDiagnostic
    ActorDrawMaximumRecordsPerSourceFrame = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.maximumRecordsPerSourceFrame
    } else { 0 }
    ActorDrawVertexShaderRegisterCount = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.vertexShaderRegisterCount
    } else { 0 }
    ActorDrawPixelShaderRegisterCount = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.pixelShaderRegisterCount
    } else { 0 }
    ActorDrawMaximumShaderBytes = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.maximumShaderBytes
    } else { 0 }
    ActorDrawTextureStageCount = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.textureStageCount
    } else { 0 }
    ActorDrawRenderFrameLead = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.renderFrameLead
    } else { 0 }
    ActorDrawMaximumBufferBytesPerRecord = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.maximumBufferBytesPerRecord
    } else { 0 }
    ActorDrawMaximumTextureBytesPerArtifact = if ($ActorDrawContractDiagnostic) {
        [int]$drawContractPolicy.maximumTextureBytesPerArtifact
    } else { 0 }
    ActorDrawArtifactDirectory = if ($ActorDrawContractDiagnostic) {
        $drawArtifactDirectory
    } else { '' }
    CaptureTextureSamplerContract = $retailGrassCaptureEnabled
    TextureSamplerSourceFrame = @($textureSamplerSourceFrames)
    TextureSamplerRenderFrameLead = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.draw.renderFrameLead
    } else { 0 }
    TextureSamplerTargetWidth = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.texture.widthPixels
    } else { 0 }
    TextureSamplerTargetHeight = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.texture.heightPixels
    } else { 0 }
    TextureSamplerTargetLevelCount = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.texture.levelCount
    } else { 0 }
    TextureSamplerTargetFormat = if ($retailGrassCaptureEnabled) {
        [uint32]$retailGrassPolicy.texture.d3d9Format
    } else { [uint32]0 }
    TextureSamplerTargetFnv1a32 = if ($retailGrassCaptureEnabled) {
        ConvertFrom-CanonicalHexUInt32 `
            ([string]$retailGrassPolicy.texture.fnv1a32) 'Retail grass texture hash'
    } else { [uint32]0 }
    TextureSamplerTargetTopLevelFnv1a32 = if ($retailGrassCaptureEnabled) {
        ConvertFrom-CanonicalHexUInt32 `
            ([string]$retailGrassPolicy.texture.topLevelFnv1a32) `
            'Retail grass top-level texture hash'
    } else { [uint32]0 }
    TextureSamplerTextureStageCount = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.capture.textureStageCount
    } else { 0 }
    TextureSamplerMaximumCandidates = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.capture.maximumCandidates
    } else { 0 }
    TextureSamplerMaximumRecords = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.capture.maximumRecords
    } else { 0 }
    TextureSamplerMaximumShaderBytes = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.capture.maximumShaderBytes
    } else { 0 }
    TextureSamplerVertexShaderRegisterCount = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.shader.vertexConstantRegisterCount
    } else { 0 }
    TextureSamplerPixelShaderRegisterCount = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.shader.pixelConstantRegisterCount
    } else { 0 }
    TextureSamplerMaximumVertexBufferBytes = if ($retailGrassCaptureEnabled) {
        [int]$retailGrassPolicy.capture.maximumVertexBufferBytes
    } else { 0 }
    CaptureImageSpaceShaderInputs = $true
    ImageSpaceExpectedShaderByteCount =
        [int]$imageSpacePolicy.expectedShaderByteCount
    ImageSpaceExpectedShaderFnv1a32 =
        [uint32]$imageSpacePolicy.expectedShaderFnv1a32
    ImageSpaceInputTextureStage =
        @($imageSpacePolicy.inputTextureStages | ForEach-Object { [int]$_ })
    ImageSpaceMaximumBytesPerInput =
        [int]$imageSpacePolicy.maximumBytesPerInput
    ImageSpaceSourceFrame = $imageSpaceSourceFrame
    ImageSpaceRenderFrameLead = [int]$imageSpacePolicy.renderFrameLead
    ImageSpaceArtifactDirectory = $imageSpaceArtifactDirectory
    CaptureImageSpacePipelineTrace = $true
    ImageSpaceTracePixelShaderFnv1a32 =
        @($imageSpaceTracePolicy.pixelShaderFnv1a32 | ForEach-Object { [uint32]$_ })
    ImageSpaceTraceMaximumRecords = [int]$imageSpaceTracePolicy.maximumRecords
    ImageSpaceTraceTextureStageCount = [int]$imageSpaceTracePolicy.textureStageCount
    ImageSpaceTraceVertexShaderRegisterCount =
        [int]$imageSpaceTracePolicy.vertexShaderRegisterCount
    ImageSpaceTracePixelShaderRegisterCount =
        [int]$imageSpaceTracePolicy.pixelShaderRegisterCount
    ImageSpaceTraceMaximumShaderBytes = [int]$imageSpaceTracePolicy.maximumShaderBytes
    ImageSpaceTraceMaximumVertexBytes = [int]$imageSpaceTracePolicy.maximumVertexBytes
    PrepareActorFrame = $captureMaxFrames
    EquipActorFrame = $captureMaxFrames
    ScreenshotFrame = @($screenshotFrames | Sort-Object)
    ScreenshotDirectory = $screensDirectory
    PortraitCamera = $true
    PortraitDistance = [float]$policy.portraitDistance
    CameraCorridorClearanceGameUnits =
        [float]$policy.cameraCorridorClearanceGameUnits
    PortraitSemanticFocusRules = $semanticFocusRulesEncoded
    CameraShotKind = [string]$shots[0].kind
    ExpectedCameraShotKind = @($shots | ForEach-Object { [string]$_.kind })
    FullBodyDistanceScale = [float]$policy.fullBodyDistanceScale
    RequireAppearanceTelemetry = [string]$job.recordType -eq 'NPC_'
    BackgroundDataMode = $true
}
$oracleRun = & $oracleRunner @oracleArguments

$events = @([IO.File]::ReadLines($jsonlPath) | ForEach-Object {
    if (-not [string]::IsNullOrWhiteSpace($_)) { $_ | ConvertFrom-Json }
})
$startEvents = @($events | Where-Object { [string]$_.event -eq 'start' })
if ($startEvents.Count -ne 1 -or -not [bool]$startEvents[0].compactActorTelemetry -or
    [int]$startEvents[0].renderEnvironmentFrame -ne $renderEnvironmentFrame -or
    [int]$startEvents[0].actorAppearanceMaximumEventBytes -ne
        [int]$telemetryPolicy.appearanceMaximumEventBytes -or
    -not [bool]$startEvents[0].captureActorSkinPalettes -or
    [int]$startEvents[0].actorSkinPaletteMaximumBytesPerShape -ne
        [int]$telemetryPolicy.skinPaletteMaximumBytesPerShape -or
    -not [bool]$startEvents[0].captureActorSurfaceContract -or
    [int]$startEvents[0].actorSurfaceMaximumShaderBytes -ne
        [int]$surfaceContractPolicy.maximumShaderBytes -or
    [int]$startEvents[0].actorSurfaceTextureStageCount -ne
        [int]$surfaceContractPolicy.textureStageCount -or
    [int]$startEvents[0].actorSurfaceRenderFrameLead -ne
        [int]$surfaceContractPolicy.renderFrameLead -or
    [int]$startEvents[0].actorSurfaceMaximumRecordsPerSourceFrame -ne
        [int]$surfaceContractPolicy.maximumRecordsPerSourceFrame -or
    [string]$startEvents[0].portraitSemanticFocusRules -cne
        $semanticFocusRulesEncoded -or
    [double]$startEvents[0].cameraCorridorClearanceGameUnits -ne
        [double]$policy.cameraCorridorClearanceGameUnits -or
    [bool]$startEvents[0].captureActorDrawContract -ne
        [bool]$ActorDrawContractDiagnostic -or
    [bool]$startEvents[0].captureTextureSamplerContract -ne
        [bool]$retailGrassCaptureEnabled -or
    ($retailGrassCaptureEnabled -and
        ((@($startEvents[0].textureSamplerSourceFrames) -join ',') -cne
            (@($textureSamplerSourceFrames) -join ',') -or
        [int]$startEvents[0].textureSamplerRenderFrameLead -ne
            [int]$retailGrassPolicy.draw.renderFrameLead -or
        [int]$startEvents[0].textureSamplerTargetWidth -ne
            [int]$retailGrassPolicy.texture.widthPixels -or
        [int]$startEvents[0].textureSamplerTargetHeight -ne
            [int]$retailGrassPolicy.texture.heightPixels -or
        [int]$startEvents[0].textureSamplerTargetLevelCount -ne
            [int]$retailGrassPolicy.texture.levelCount -or
        [uint32]$startEvents[0].textureSamplerTargetFormat -ne
            [uint32]$retailGrassPolicy.texture.d3d9Format -or
        [int]$startEvents[0].textureSamplerTextureStageCount -ne
            [int]$retailGrassPolicy.capture.textureStageCount -or
        [int]$startEvents[0].textureSamplerMaximumCandidates -ne
            [int]$retailGrassPolicy.capture.maximumCandidates -or
        [int]$startEvents[0].textureSamplerMaximumRecords -ne
            [int]$retailGrassPolicy.capture.maximumRecords -or
        [int]$startEvents[0].textureSamplerMaximumShaderBytes -ne
            [int]$retailGrassPolicy.capture.maximumShaderBytes -or
        [int]$startEvents[0].textureSamplerVertexShaderRegisterCount -ne
            [int]$retailGrassPolicy.shader.vertexConstantRegisterCount -or
        [int]$startEvents[0].textureSamplerPixelShaderRegisterCount -ne
            [int]$retailGrassPolicy.shader.pixelConstantRegisterCount -or
        [int]$startEvents[0].textureSamplerMaximumVertexBufferBytes -ne
            [int]$retailGrassPolicy.capture.maximumVertexBufferBytes)) -or
    -not [bool]$startEvents[0].captureImageSpaceShaderInputs -or
    [int]$startEvents[0].imageSpaceExpectedShaderByteCount -ne
        [int]$imageSpacePolicy.expectedShaderByteCount -or
    [uint32]$startEvents[0].imageSpaceExpectedShaderFnv1a32 -ne
        [uint32]$imageSpacePolicy.expectedShaderFnv1a32 -or
    (@($startEvents[0].imageSpaceInputTextureStages) -join ',') -cne
        (@($imageSpacePolicy.inputTextureStages) -join ',') -or
    [int]$startEvents[0].imageSpaceMaximumBytesPerInput -ne
        [int]$imageSpacePolicy.maximumBytesPerInput -or
    [int]$startEvents[0].imageSpaceSourceFrame -ne $imageSpaceSourceFrame -or
    [int]$startEvents[0].imageSpaceRenderFrameLead -ne
        [int]$imageSpacePolicy.renderFrameLead -or
    ($ActorDrawContractDiagnostic -and
        ([int]$startEvents[0].actorDrawVertexShaderRegisterCount -ne
            [int]$drawContractPolicy.vertexShaderRegisterCount -or
        [int]$startEvents[0].actorDrawPixelShaderRegisterCount -ne
            [int]$drawContractPolicy.pixelShaderRegisterCount -or
        [int]$startEvents[0].actorDrawMaximumTextureBytesPerArtifact -ne
            [int]$drawContractPolicy.maximumTextureBytesPerArtifact))) {
    throw 'Retail actor observation did not confirm compact actor and configured skin-palette telemetry.'
}
$liveLocationSummary = $null
if ($authoredReferenceMode) {
    $authoredReferenceForm = [Convert]::ToUInt32(
        [string]$galleryShot.referenceFormId, 16)
    $authoredLocationPoseSamples = @($events | Where-Object {
        [string]$_.event -ceq [string]$telemetryPolicy.poseEvent -and
        [uint32]$_.refForm -eq $authoredReferenceForm
    })
    $liveLocationSummary = Assert-AuthoredLiveLocation `
        $authoredLocationPoseSamples $galleryShot
}
$textureSamplerEvents = @($events | Where-Object {
    [string]$_.event -eq 'texture-sampler-contract'
})
$retailGrassCaptureSummary = $null
if ($retailGrassCaptureEnabled) {
    if ($textureSamplerEvents.Count -ne 1) {
        throw "Exterior retail capture retained $($textureSamplerEvents.Count) grass sampler events; expected one."
    }
    $textureSamplerEvent = $textureSamplerEvents[0]
    $target = $textureSamplerEvent.target
    $expectedTextureHash = ('d3d9-fnv1a32:{0:x8}' -f
        (ConvertFrom-CanonicalHexUInt32 `
            ([string]$retailGrassPolicy.texture.fnv1a32) 'Retail grass texture hash'))
    $expectedTopLevelHash = ('d3d9-fnv1a32:{0:x8}' -f
        (ConvertFrom-CanonicalHexUInt32 `
            ([string]$retailGrassPolicy.texture.topLevelFnv1a32) `
            'Retail grass top-level texture hash'))
    $expectedVertexShader = ConvertFrom-CanonicalHexUInt32 `
        ([string]$retailGrassPolicy.shader.vertexFnv1a32) `
        'Retail grass vertex shader hash'
    $expectedPixelShader = ConvertFrom-CanonicalHexUInt32 `
        ([string]$retailGrassPolicy.shader.pixelFnv1a32) `
        'Retail grass pixel shader hash'
    $expectedBatchVertexCounts = @($retailGrassPolicy.meshes | ForEach-Object {
        [int]$_.sourceVertices * [int]$retailGrassPolicy.shader.instanceCapacity
    } | Sort-Object -Unique)
    $retainedGrassRecords = @($textureSamplerEvent.records)
    $candidateGrassFrames = [Collections.Generic.List[object]]::new()
    foreach ($sourceFrame in $textureSamplerSourceFrames) {
        $grassRecords = @($retainedGrassRecords | Where-Object {
            [int]$_.sourceFrame -eq $sourceFrame -and
            [uint32]$_.vertexShader.fnv1a32 -eq $expectedVertexShader -and
            [uint32]$_.pixelShader.fnv1a32 -eq $expectedPixelShader
        })
        $actualBatchVertexCounts = @($grassRecords | ForEach-Object {
            [int]$_.vertexCount
        } | Sort-Object -Unique)
        if ($grassRecords.Count -lt
                [int]$retailGrassPolicy.capture.minimumMatchingRecords -or
            $grassRecords.Count -ge
                [int]$retailGrassPolicy.capture.maximumRecords -or
            @($actualBatchVertexCounts | Where-Object {
                $_ -notin $expectedBatchVertexCounts
            }).Count -ne 0) {
            throw "Exterior retail grass draw stream failed at candidate source frame $sourceFrame."
        }
        $candidateGrassFrames.Add([pscustomobject][ordered]@{
            shotKind = [string]$shotFrameKinds[$sourceFrame]
            sourceFrame = $sourceFrame
            matchingRecordCount = $grassRecords.Count
            actualBatchVertexCounts = @($actualBatchVertexCounts)
            records = @($grassRecords)
        })
    }
    if ([int]$textureSamplerEvent.sourceFrame -ne
            [int]$textureSamplerSourceFrames[-1] -or
        (@($textureSamplerEvent.sourceFrames) -join ',') -cne
            (@($textureSamplerSourceFrames) -join ',') -or
        [int]$textureSamplerEvent.renderFrameLead -ne
            [int]$retailGrassPolicy.draw.renderFrameLead -or
        [int]$target.width -ne [int]$retailGrassPolicy.texture.widthPixels -or
        [int]$target.height -ne [int]$retailGrassPolicy.texture.heightPixels -or
        [int]$target.levelCount -ne [int]$retailGrassPolicy.texture.levelCount -or
        [uint32]$target.format -ne [uint32]$retailGrassPolicy.texture.d3d9Format -or
        [string]$target.contentHash -cne $expectedTextureHash -or
        [string]$target.topLevelHash -cne $expectedTopLevelHash -or
        [int]$textureSamplerEvent.matchedResourceCount -ne
            [int]$retailGrassPolicy.capture.requiredMatchedResourceCount -or
        [bool]$textureSamplerEvent.candidateLimitReached -or
        @($retainedGrassRecords | Where-Object {
            [int]$_.sourceFrame -notin $textureSamplerSourceFrames
        }).Count -ne 0 -or
        $retainedGrassRecords.Count -ge
            ([int]$retailGrassPolicy.capture.maximumRecords *
                $textureSamplerSourceFrames.Count)) {
        throw 'Exterior retail grass draw stream failed its configured texture, shader, record, or owned-mesh coverage contract.'
    }
    $retailGrassCaptureSummary = [ordered]@{
        schema = [string]$retailGrassPolicy.capture.schema
        event = [string]$retailGrassPolicy.capture.event
        runtimeConfiguration = Get-FileEvidence `
            $runtimeConfigurationPath 'open-nv-runtime-configuration'
        candidateShotKinds = @($galleryPresentationShotKinds)
        sourceFrames = @($textureSamplerSourceFrames)
        renderFrameLead = [int]$textureSamplerEvent.renderFrameLead
        matchedResourceCount = [int]$textureSamplerEvent.matchedResourceCount
        retainedRecordCount = $retainedGrassRecords.Count
        expectedBatchVertexCounts = @($expectedBatchVertexCounts)
        candidateFrames = @($candidateGrassFrames)
        candidateLimitReached = [bool]$textureSamplerEvent.candidateLimitReached
        texture = $target
    }
}
elseif ($textureSamplerEvents.Count -ne 0) {
    throw 'Non-exterior actor observation unexpectedly retained a grass sampler event.'
}
$unexpectedDiagnosticEvents = @($events | Where-Object {
    [string]$_.event -in @($telemetryPolicy.forbiddenEvents)
})
if ($unexpectedDiagnosticEvents.Count -ne 0) {
    throw "Compact actor observation retained $($unexpectedDiagnosticEvents.Count) unrelated diagnostic event(s)."
}
$stackEvents = @($events | Where-Object { [string]$_.event -eq 'runtime-plugin-stack' })
if ($stackEvents.Count -ne 1 -or -not [bool]$stackEvents[0].readable) {
    throw 'Retail did not retain one readable runtime plugin stack.'
}
$runtimePlugins = @($stackEvents[0].plugins)
if ($runtimePlugins.Count -ne $expectedPluginNames.Count) {
    throw "Retail loaded $($runtimePlugins.Count) plugins; expected $($expectedPluginNames.Count)."
}
for ($index = 0; $index -lt $expectedPluginNames.Count; ++$index) {
    $plugin = $runtimePlugins[$index]
    if (-not [bool]$plugin.readable -or [int]$plugin.loadOrderIndex -ne $index -or
        [int]$plugin.modIndex -ne $index -or
        [string]$plugin.name -cne $expectedPluginNames[$index]) {
        throw "Retail plugin stack differs at index $index; expected '$($expectedPluginNames[$index])'."
    }
}
$templateEvents = @($events | Where-Object { [string]$_.event -eq 'actor-template-observation' })
$portraitEvents = @($events | Where-Object { [string]$_.event -eq 'portrait-camera-set' })
$sourceFrameCameraEvents = @($events | Where-Object {
    [string]$_.event -eq 'portrait-camera-source-frame'
})
$cameraEvents = @($events | Where-Object { [string]$_.event -eq 'review-camera-observation' })
if ($templateEvents.Count -ne 1) {
    throw "Expected one actor-template-observation, got $($templateEvents.Count)."
}
if ($portraitEvents.Count -ne $shots.Count) {
    throw "Retail capture retained $($portraitEvents.Count) camera sets; expected $($shots.Count)."
}
for ($shotIndex = 0; $shotIndex -lt $shots.Count; ++$shotIndex) {
    if (-not (Test-PortraitCameraContract $portraitEvents[$shotIndex] `
            ([string]$shots[$shotIndex].kind) `
            ([double]$policy.cameraCorridorClearanceGameUnits))) {
        throw "Retail camera set $shotIndex does not match the configured shot sequence."
    }
}
$orderedScreenshotFrames = @($screenshotFrames | Sort-Object)
if ($cameraEvents.Count -ne $orderedScreenshotFrames.Count -or
    $sourceFrameCameraEvents.Count -ne $orderedScreenshotFrames.Count) {
    throw "Retail capture retained $($cameraEvents.Count) camera observations; expected $($orderedScreenshotFrames.Count)."
}
for ($cameraIndex = 0; $cameraIndex -lt $cameraEvents.Count; ++$cameraIndex) {
    $cameraEvent = $cameraEvents[$cameraIndex]
    $expectedFrame = [int]$orderedScreenshotFrames[$cameraIndex]
    $cameraWorld = $cameraEvent.cameraWorld
    $viewMatrix = @($cameraEvent.viewMatrix)
    $projectionMatrix = @($cameraEvent.projectionMatrix)
    $frustum = @($cameraEvent.frustum)
    $viewport = @($cameraEvent.viewport)
    $sourceFrameCameraEvent = $sourceFrameCameraEvents[$cameraIndex]
    if ([int]$cameraEvent.frame -ne $expectedFrame -or
        [string]$cameraEvent.shotKind -cne [string]$shotFrameKinds[$expectedFrame] -or
        -not [bool]$cameraEvent.readable -or
        -not [bool]$cameraEvent.projectionExact -or
        $null -eq $cameraWorld -or
        -not (Test-FiniteNumberArray @($cameraWorld.rotation) `
            ([int]$telemetryPolicy.cameraWorldRotationElementCount)) -or
        -not (Test-FiniteNumberArray @($cameraWorld.translation) `
            ([int]$telemetryPolicy.cameraWorldTranslationElementCount)) -or
        -not [double]::IsFinite([double]$cameraWorld.scale) -or
        [double]$cameraWorld.scale -le 0.0 -or
        -not (Test-FiniteNumberArray $viewMatrix `
            ([int]$telemetryPolicy.cameraMatrixElementCount)) -or
        -not (Test-FiniteNumberArray $projectionMatrix `
            ([int]$telemetryPolicy.cameraMatrixElementCount)) -or
        -not (Test-FiniteNumberArray $frustum `
            ([int]$telemetryPolicy.cameraFrustumElementCount)) -or
        -not (Test-FiniteNumberArray $viewport `
            ([int]$telemetryPolicy.cameraViewportElementCount)) -or
        -not [double]::IsFinite([double]$cameraEvent.fovYRadians) -or
        [double]$cameraEvent.fovYRadians -le 0.0 -or
        [double]$frustum[0] -ge [double]$frustum[1] -or
        [double]$frustum[3] -ge [double]$frustum[2] -or
        [double]$frustum[4] -le 0.0 -or
        [double]$frustum[5] -le [double]$frustum[4] -or
        [int]$frustum[6] -ne 0 -or
        [int]$sourceFrameCameraEvent.frame -ne $expectedFrame -or
        -not (Test-PortraitCameraContract $sourceFrameCameraEvent `
            ([string]$shotFrameKinds[$expectedFrame]) `
            ([double]$policy.cameraCorridorClearanceGameUnits))) {
        throw "Retail camera observation $cameraIndex does not match frame $expectedFrame and its configured shot."
    }
}
$observedReference = [uint32]$templateEvents[0].referenceForm
$requestedRuntimeForm = [Convert]::ToUInt32($runtimeForm, 16)
$requestedTargetRuntimeForm = [Convert]::ToUInt32($targetRuntimeForm, 16)
$templateObservation = $templateEvents[0]
$runtimeBaseFormTypeProperty =
    $telemetryPolicy.recordTypeRuntimeFormTypes.PSObject.Properties[[string]$job.recordType]
if ($null -eq $runtimeBaseFormTypeProperty) {
    throw "Retail telemetry policy has no runtime form type for '$($job.recordType)'."
}
$expectedRuntimeBaseType = [int]$runtimeBaseFormTypeProperty.Value
$observedRuntimeBase = [uint32]$templateObservation.runtimeBaseForm
$runtimeBaseTemporary = [bool]$templateObservation.runtimeBaseTemporary
$temporaryRuntimeFormIndex = [int]$telemetryPolicy.temporaryRuntimeFormIndex
$runtimeLineage = $templateObservation.leveledExtra
if (-not [bool]$templateObservation.baseReadable -or
    [uint32]$templateObservation.requestedBaseForm -ne $requestedTargetRuntimeForm -or
    [uint32]$templateObservation.referenceForm -ne $observedReference -or
    ($authoredReferenceMode -and $observedReference -ne $requestedTargetRuntimeForm) -or
    $observedRuntimeBase -eq 0 -or
    [int]$templateObservation.runtimeBaseType -ne $expectedRuntimeBaseType) {
    throw 'Retail actor template observation does not bind the requested target, observed reference, and runtime base.'
}
if ($runtimeBaseTemporary) {
    if ([int]$templateObservation.runtimeBaseModIndex -ne $temporaryRuntimeFormIndex -or
        $null -eq $runtimeLineage -or -not [bool]$runtimeLineage.readable -or
        [uint32]$runtimeLineage.baseForm -ne $requestedRuntimeForm -or
        [uint32]$runtimeLineage.form -eq 0) {
        throw 'Retail temporary actor base has no complete stable leveled lineage.'
    }
}
elseif ($observedRuntimeBase -ne $requestedRuntimeForm -or
    [int]$templateObservation.runtimeBaseModIndex -eq $temporaryRuntimeFormIndex) {
    throw 'Retail stable actor base differs from the requested base.'
}
$snapshotFaults = @($events | Where-Object {
    [string]$_.event -eq [string]$telemetryPolicy.visualSnapshotFaultEvent
})
if ($snapshotFaults.Count -ne 0) {
    throw "Retail actor observation reported $($snapshotFaults.Count) visual-snapshot fault(s)."
}
$visualSnapshots = @($events | Where-Object {
    [string]$_.event -eq [string]$telemetryPolicy.visualSnapshotEvent
})
$expectedSnapshotCount = $orderedScreenshotFrames.Count *
    [int]$telemetryPolicy.requiredVisualSnapshotsPerSourceFrame
if ($visualSnapshots.Count -ne $expectedSnapshotCount) {
    throw "Retail capture retained $($visualSnapshots.Count) actor visual snapshots; expected $expectedSnapshotCount."
}
$appearanceSnapshots = [Collections.Generic.List[object]]::new()
$snapshotSummaries = [Collections.Generic.List[object]]::new()
foreach ($expectedFrame in $orderedScreenshotFrames) {
    $frameSnapshots = @($visualSnapshots | Where-Object {
        [int]$_.requestedFrame -eq [int]$expectedFrame
    })
    if ($frameSnapshots.Count -ne [int]$telemetryPolicy.requiredVisualSnapshotsPerSourceFrame) {
        throw "Retail frame $expectedFrame does not have exactly one actor visual snapshot."
    }
    $snapshot = $frameSnapshots[0]
    $nodes = @($snapshot.nodes)
    if ([int]$snapshot.frame -ne [int]$expectedFrame -or
        [uint32]$snapshot.refForm -ne $observedReference -or
        [uint32]$snapshot.baseForm -ne $observedRuntimeBase -or
        $null -eq $snapshot.rootWorld -or
        $nodes.Count -lt [int]$telemetryPolicy.minimumNamedNodesPerSnapshot) {
        throw "Retail actor visual snapshot for frame $expectedFrame has invalid actor, root, or named-node identity."
    }
    foreach ($node in $nodes) {
        if ([string]::IsNullOrWhiteSpace([string]$node.name) -or
            [string]::IsNullOrWhiteSpace([string]$node.nodePath) -or
            $null -eq $node.transform -or
            @($node.transform.localRotation).Count -ne 9 -or
            @($node.transform.localTranslation).Count -ne 3 -or
            @($node.transform.worldRotation).Count -ne 9 -or
            @($node.transform.worldTranslation).Count -ne 3) {
            throw "Retail actor visual snapshot for frame $expectedFrame contains an incomplete named-node transform."
        }
    }
    if (@($nodes.nodePath | Sort-Object -Unique).Count -ne $nodes.Count) {
        throw "Retail actor visual snapshot for frame $expectedFrame contains duplicate node paths."
    }
    $facialRuntime = $snapshot.facialRuntime
    $requiresFacialRuntime = [string]$job.recordType -cin
        @($faceGenAnimationPolicy.requiredRecordTypes)
    if ($requiresFacialRuntime) {
        $facialGroups = [ordered]@{
            emotionWeights = [int]$faceGenAnimationPolicy.emotionWeightCount
            movementWeights = [int]$faceGenAnimationPolicy.movementWeightCount
            phonemeWeights = [int]$faceGenAnimationPolicy.phonemeWeightCount
        }
        if ($null -eq $facialRuntime -or
            -not [bool]$facialRuntime.animationDataAvailable) {
            throw "Retail actor visual snapshot for frame $expectedFrame omitted required FaceGen animation data."
        }
        foreach ($facialGroup in $facialGroups.GetEnumerator()) {
            $weights = $facialRuntime.([string]$facialGroup.Key)
            if ($null -eq $weights -or -not [bool]$weights.complete -or
                [int]$weights.sourceCount -lt [int]$facialGroup.Value -or
                -not (Test-FiniteNumberArray @($weights.values) ([int]$facialGroup.Value))) {
                throw "Retail actor visual snapshot for frame $expectedFrame has incomplete $($facialGroup.Key)."
            }
        }
    }
    $skinPalettes = @($snapshot.skinPalettes)
    $skinPaletteCapture = $snapshot.skinPaletteCapture
    if ($null -eq $skinPaletteCapture -or [bool]$skinPaletteCapture.traversalTruncated -or
        [int]$skinPaletteCapture.invalidPalettes -ne 0 -or
        [int]$skinPaletteCapture.skinInstances -ne $skinPalettes.Count -or
        [int]$skinPaletteCapture.capturedPalettes +
            [int]$skinPaletteCapture.notRenderCached -ne $skinPalettes.Count) {
        throw "Retail actor visual snapshot for frame $expectedFrame has incomplete skin-palette traversal."
    }
    foreach ($palette in $skinPalettes) {
        if ([string]$palette.status -ceq 'not-render-cached') {
            if ([int64]$palette.matrixCount -ne 0 -or
                [int64]$palette.registersPerMatrix -ne 0 -or
                [int64]$palette.allocatedBytes -ne 0 -or
                [int64]$palette.matrixBytes -ne 0) {
                throw "Retail actor visual snapshot for frame $expectedFrame has inconsistent uncached skin data at $($palette.nodePath)."
            }
            continue
        }
        $matrixFloatCount = [int64]$palette.matrixCount *
            [int64]$palette.registersPerMatrix *
            [int64]$telemetryPolicy.skinPaletteComponentsPerRegister
        if ([string]$palette.status -cne 'captured' -or
            [string]::IsNullOrWhiteSpace([string]$palette.nodePath) -or
            [int]$palette.componentsPerRegister -ne
                [int]$telemetryPolicy.skinPaletteComponentsPerRegister -or
            [int64]$palette.matrixBytes -ne $matrixFloatCount *
                [int64]$telemetryPolicy.skinPaletteBytesPerComponent -or
            [int64]$palette.matrixBytes -gt
                [int64]$telemetryPolicy.skinPaletteMaximumBytesPerShape -or
            [int64]$palette.allocatedBytes -lt [int64]$palette.matrixBytes -or
            @($palette.bones).Count -ne [int64]$palette.matrixCount -or
            -not (Test-FiniteNumberArray @($palette.matrices) $matrixFloatCount)) {
            throw "Retail actor visual snapshot for frame $expectedFrame contains an invalid skin palette at $($palette.nodePath)."
        }
    }
    if (@($skinPalettes.nodePath | Sort-Object -Unique).Count -ne $skinPalettes.Count) {
        throw "Retail actor visual snapshot for frame $expectedFrame contains duplicate skin-palette node paths."
    }
    if ($null -ne $snapshot.appearance) {
        $appearanceSnapshots.Add($snapshot)
    }
    $snapshotSummaries.Add([pscustomobject][ordered]@{
        frame = [int]$snapshot.frame
        requestedFrame = [int]$snapshot.requestedFrame
        shotKind = [string]$shotFrameKinds[[int]$expectedFrame]
        namedNodeCount = $nodes.Count
        geometryCandidateCount = [int]$skinPaletteCapture.geometryCandidates
        skinPaletteCount = $skinPalettes.Count
        cachedSkinPaletteCount = [int]$skinPaletteCapture.capturedPalettes
        uncachedSkinInstanceCount = [int]$skinPaletteCapture.notRenderCached
        facialRuntimeRequired = $requiresFacialRuntime
        facialRuntimeAvailable = $null -ne $facialRuntime -and
            [bool]$facialRuntime.animationDataAvailable
        facialRuntimeComplete = $null -ne $facialRuntime -and
            [bool]$facialRuntime.emotionWeights.complete -and
            [bool]$facialRuntime.movementWeights.complete -and
            [bool]$facialRuntime.phonemeWeights.complete
        appearanceRetained = $null -ne $snapshot.appearance
        appearanceComplete = $null -ne $snapshot.appearance -and
            [bool]$snapshot.appearance.complete
        appearanceRenderPartCount = if ($null -ne $snapshot.appearance) {
            @($snapshot.appearance.renderParts).Count
        } else { 0 }
    })
}
if ($appearanceSnapshots.Count -ne [int]$telemetryPolicy.requiredAppearanceSnapshots) {
    throw "Retail capture retained $($appearanceSnapshots.Count) appearance snapshots; expected exactly one."
}
$appearanceSnapshot = $appearanceSnapshots[0].appearance
$appearanceFrame = [int]$appearanceSnapshots[0].frame
if ([string]$appearanceSnapshot.schema -cne [string]$telemetryPolicy.appearanceSchema) {
    throw "Retail appearance snapshot schema '$($appearanceSnapshot.schema)' does not match '$($telemetryPolicy.appearanceSchema)'."
}
if ([bool]$appearanceSnapshot.truncated -or
    @($appearanceSnapshot.renderParts).Count -lt 1) {
    throw 'Retail appearance snapshot is truncated or contains no resolved render parts.'
}
$requiredVisibleParts = @($appearanceSnapshot.renderParts | Where-Object {
    [bool]$_.required -and [bool]$_.attached -and [bool]$_.drawable -and [bool]$_.visible
})
foreach ($part in $requiredVisibleParts) {
    if ([string]::IsNullOrWhiteSpace([string]$part.geometryName) -or
        [string]::IsNullOrWhiteSpace([string]$part.visualNodePath)) {
        throw 'Retail appearance contains a required visible part without exact geometry identity.'
    }
    foreach ($snapshot in $visualSnapshots) {
        $matches = @($snapshot.nodes | Where-Object {
            [string]$_.nodePath -ceq [string]$part.visualNodePath -and
            [string]$_.name -ceq [string]$part.geometryName
        })
        if ($matches.Count -ne 1) {
            throw "Retail frame $($snapshot.frame) does not bind appearance part '$($part.geometryName)' at '$($part.visualNodePath)' exactly once."
        }
    }
}
$appearancePoseEvents = @($events | Where-Object {
    [string]$_.event -ceq [string]$telemetryPolicy.poseEvent -and
    [int]$_.frame -eq $appearanceFrame
})
if ($appearancePoseEvents.Count -ne 1) {
    throw "Retail appearance frame $appearanceFrame does not have exactly one pose sample."
}
$equippedWeapon = $appearanceSnapshot.equippedWeapon
if ($null -eq $equippedWeapon) {
    throw 'Retail appearance snapshot has no equipped-weapon contract.'
}
$equippedWeaponState = [string]$equippedWeapon.state
$equippedWeaponRenderState = [string]$equippedWeapon.renderState
if ($null -eq $equippedWeapon.PSObject.Properties['weaponOut'] -or
    $equippedWeapon.weaponOut -isnot [bool]) {
    throw 'Retail equipped-weapon contract has no Boolean weaponOut state.'
}
$equippedWeaponOut = [bool]$equippedWeapon.weaponOut
$equippedWeaponNodeProperty = $equippedWeapon.PSObject.Properties['nodePresent']
if ($null -eq $equippedWeaponNodeProperty -or
    $equippedWeaponNodeProperty.Value -isnot [bool]) {
    throw 'Retail equipped-weapon contract has no Boolean nodePresent state.'
}
$equippedWeaponNodePresent = [bool]$equippedWeaponNodeProperty.Value
$equippedWeaponModelPath = [string]$equippedWeapon.modelPath
$canonicalEquippedWeaponModelPath = $equippedWeaponModelPath.Trim().Replace('\', '/').ToLowerInvariant()
$equippedWeaponModelPathIsCanonical = -not [string]::IsNullOrEmpty($equippedWeaponModelPath) -and
    $canonicalEquippedWeaponModelPath -ceq $equippedWeaponModelPath -and
    $canonicalEquippedWeaponModelPath.EndsWith('.nif', [StringComparison]::Ordinal) -and
    -not $canonicalEquippedWeaponModelPath.StartsWith('/', [StringComparison]::Ordinal) -and
    -not $canonicalEquippedWeaponModelPath.Contains('../', [StringComparison]::Ordinal)
$equippedWeaponFormText = [string]$equippedWeapon.sourceFormId
if ($equippedWeaponFormText -notmatch '^0x[0-9A-F]{8}$') {
    throw "Retail equipped-weapon FormID '$equippedWeaponFormText' is not canonical."
}
$equippedWeaponForm = [Convert]::ToUInt32($equippedWeaponFormText.Substring(2), 16)
$poseWeaponOutProperty = $appearancePoseEvents[0].PSObject.Properties['weaponOut']
if ($null -eq $poseWeaponOutProperty -or $poseWeaponOutProperty.Value -isnot [bool]) {
    throw "Retail pose at appearance frame $appearanceFrame has no Boolean weaponOut state."
}
$poseWeaponOut = [bool]$poseWeaponOutProperty.Value
$poseWeaponForm = [uint32]$appearancePoseEvents[0].weaponForm
$visibleWeaponParts = @($appearanceSnapshot.renderParts | Where-Object {
    [string]$_.role -ceq 'weapon' -and [bool]$_.visible
})
switch -CaseSensitive ($equippedWeaponState) {
    'none' {
        if ($equippedWeaponForm -ne 0 -or $poseWeaponForm -ne 0 -or
            $equippedWeaponRenderState -cne 'not-applicable' -or
            $equippedWeaponOut -ne $poseWeaponOut -or
            $equippedWeaponNodePresent -or
            -not [string]::IsNullOrEmpty($equippedWeaponModelPath) -or
            $visibleWeaponParts.Count -ne 0) {
            throw 'Retail no-weapon appearance state disagrees with the live pose or render parts.'
        }
    }
    'equipped' {
        if ($equippedWeaponForm -eq 0 -or $poseWeaponForm -ne $equippedWeaponForm -or
            $equippedWeaponOut -ne $poseWeaponOut) {
            throw 'Retail equipped-weapon appearance disagrees with the same-frame live pose.'
        }
        switch -CaseSensitive ($equippedWeaponRenderState) {
            'visible-source-bound' {
                $matchingWeaponParts = @($visibleWeaponParts | Where-Object {
                    [string]$_.sourceFormId -ceq $equippedWeaponFormText -and
                    [string]$_.modelPath -ceq $equippedWeaponModelPath -and
                    [bool]$_.required -and [bool]$_.attached -and [bool]$_.drawable
                })
                if (-not $equippedWeaponNodePresent -or
                    -not $equippedWeaponModelPathIsCanonical -or
                    $matchingWeaponParts.Count -lt 1) {
                    throw 'Retail equipped-weapon appearance does not have one authoritative visible runtime attachment.'
                }
            }
            'not-visible-at-frame' {
                if ($equippedWeaponOut -or $visibleWeaponParts.Count -ne 0) {
                    throw 'Retail nonvisible equipped-weapon state disagrees with the same-frame pose or render parts.'
                }
                if (-not [string]::IsNullOrEmpty($equippedWeaponModelPath) -and
                    -not $equippedWeaponModelPathIsCanonical) {
                    throw 'Retail nonvisible equipped-weapon model path is not canonical.'
                }
            }
            'unreadable' {
                if ([bool]$appearanceSnapshot.complete) {
                    throw 'Retail appearance cannot be complete when equipped-weapon render state is unreadable.'
                }
            }
            default {
                throw "Retail appearance has unknown equipped-weapon render state '$equippedWeaponRenderState'."
            }
        }
    }
    'unreadable' {
        if ($equippedWeaponRenderState -cne 'unreadable' -or
            [bool]$appearanceSnapshot.complete) {
            throw 'Retail appearance cannot be complete when equipped-weapon state is unreadable.'
        }
    }
    default {
        throw "Retail appearance has unknown equipped-weapon state '$equippedWeaponState'."
    }
}
$appearanceFaults = @($appearanceSnapshot.faults | ForEach-Object { [string]$_ })
if (($appearanceFaults.Count -eq 0) -ne [bool]$appearanceSnapshot.complete -or
    @($appearanceFaults | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne 0 -or
    @($appearanceFaults | Sort-Object -Unique).Count -ne $appearanceFaults.Count) {
    throw 'Retail appearance snapshot completeness and fault codes disagree.'
}
$appearanceEvidenceStatus = if ([bool]$appearanceSnapshot.complete) {
    'complete'
} else {
    'incomplete-runtime-attachment-evidence'
}
$surfaceContractEvents = @($events | Where-Object {
    [string]$_.event -eq [string]$surfaceContractPolicy.event
})
$drawTargetEvents = @($events | Where-Object {
    [string]$_.event -eq [string]$surfaceContractPolicy.targetTexturesEvent
})
$drawTargetFaults = @($events | Where-Object {
    [string]$_.event -eq 'actor-draw-contract-target-textures-fault'
})
$drawTargets = @($drawTargetEvents[0].textures)
if ($drawTargetFaults.Count -ne 0 -or $drawTargetEvents.Count -ne 1 -or
    $drawTargets.Count -lt 1 -or $drawTargets.Count -gt
        [int]$surfaceContractPolicy.maximumRecordsPerSourceFrame -or
    @($drawTargets | Where-Object {
        [string]::IsNullOrWhiteSpace([string]$_.path) -or
            @($_.geometryNames).Count -lt 1 -or
            @($_.visualNodePaths).Count -lt 1 -or
            $_.PSObject.Properties.Name -notcontains 'semanticFocusSurface' -or
            $_.PSObject.Properties.Name -notcontains 'semanticFocusExclusive'
    }).Count -ne 0 -or
    @($drawTargets | Where-Object { [bool]$_.semanticFocusExclusive }).Count -lt 1) {
    throw 'Actor surface capture did not retain one nonempty target-texture registry.'
}
if ($surfaceContractEvents.Count -ne $orderedScreenshotFrames.Count) {
    throw "Actor surface capture retained $($surfaceContractEvents.Count) source-frame events; expected $($orderedScreenshotFrames.Count)."
}
$surfaceFrameSummaries = [Collections.Generic.List[object]]::new()
$matrixTolerance = [double]$surfaceContractPolicy.matrixTolerance
$visibleSurfaceFrameCount = 0
$semanticFocusSurfaceFrameCount = 0
foreach ($expectedFrame in $orderedScreenshotFrames) {
    $frameEvents = @($surfaceContractEvents | Where-Object {
        [int]$_.sourceFrame -eq [int]$expectedFrame
    })
    if ($frameEvents.Count -ne 1) {
        throw "Actor surface contract frame $expectedFrame is missing or duplicated."
    }
    $surfaceEvent = $frameEvents[0]
    $surfaces = @($surfaceEvent.surfaces)
    if ([int]$surfaceEvent.frame -ne [int]$expectedFrame -or
        [int]$surfaceEvent.renderFrameLead -ne
            [int]$surfaceContractPolicy.renderFrameLead -or
        -not [bool]$surfaceEvent.targetTexturesReady -or
        [int]$surfaceEvent.maximumRecords -ne
            [int]$surfaceContractPolicy.maximumRecordsPerSourceFrame -or
        [int]$surfaceEvent.captureCount -lt 0 -or
        [int]$surfaceEvent.captureCount -gt
            [int]$surfaceContractPolicy.maximumRecordsPerSourceFrame -or
        [int]$surfaceEvent.captureCount -ne $surfaces.Count) {
        throw "Actor surface contract frame $expectedFrame has an invalid captured-surface cardinality."
    }
    if ([int]$surfaceEvent.captureCount -eq 0) {
        if (-not $authoredReferenceMode) {
            throw "Actor surface contract frame $expectedFrame is missing one captured surface."
        }
        $surfaceFrameSummaries.Add([pscustomobject][ordered]@{
            sourceFrame = [int]$expectedFrame
            shotKind = [string]$shotFrameKinds[[int]$expectedFrame]
            reviewRequired = [bool]$shotFrameReviewRequired[[int]$expectedFrame]
            status = 'no-final-eye-actor-draw'
            renderFrame = $null
            texture = $null
            vertexShaderFnv1a32 = $null
            backBufferWidth = $null
            backBufferHeight = $null
            projection = $null
            verticalFovRadians = $null
            semanticFocusSurface = $false
            surfaces = @()
            excludedAuxiliarySurfaces = @()
        })
        continue
    }
    $surfaceSummaries = [Collections.Generic.List[object]]::new()
    $excludedAuxiliarySurfaceSummaries = [Collections.Generic.List[object]]::new()
    $frameHasSemanticFocusSurface = $false
    $representativeProjection = $null
    $representativeBackBuffer = $null
    $representativeSurface = $null
    foreach ($surface in $surfaces) {
        $transforms = $surface.fixedFunctionTransforms
        $projection = @($transforms.projection)
        $renderTarget = $surface.renderTarget
        $targetDescription = $renderTarget.renderTargetDescription
        $backBufferDescription = $renderTarget.backBufferDescription
        $viewport = $renderTarget.viewport
        $scissor = $renderTarget.scissor
        $matrixElementCount = [int]$surfaceContractPolicy.matrixElementCount
        $worldTransformFinite = Test-FiniteNumberArray `
            -Values @($transforms.world) -ExpectedCount $matrixElementCount
        $viewTransformFinite = Test-FiniteNumberArray `
            -Values @($transforms.view) -ExpectedCount $matrixElementCount
        $projectionTransformFinite = Test-FiniteNumberArray `
            -Values $projection -ExpectedCount $matrixElementCount
        $matchedTexture = $surface.matchedTexture
        $isSemanticFocusSurface = [bool]$matchedTexture.semanticFocusExclusive
        $skinnedActorShader = [bool]$surface.vertexShader.hasBonesParameter -and
            [bool]$surface.vertexShader.hasSkinModelViewProjectionParameter
        $expectedRenderClass = if ($isSemanticFocusSurface) {
            'semantic-focus'
        } else { 'skinned-actor' }
        if ([int]$surface.sourceFrame -ne [int]$expectedFrame -or
            [int]$surface.renderFrame -ne [int]$expectedFrame -
                [int]$surfaceContractPolicy.renderFrameLead -or
            [string]::IsNullOrWhiteSpace([string]$matchedTexture.path) -or
            @($matchedTexture.roles).Count -lt 1 -or
            @($matchedTexture.geometryNames).Count -lt 1 -or
            @($matchedTexture.visualNodePaths).Count -lt 1 -or
            @($matchedTexture.semantics).Count -lt 1 -or
            $matchedTexture.PSObject.Properties.Name -notcontains
                'semanticFocusSurface' -or
            $matchedTexture.PSObject.Properties.Name -notcontains
                'semanticFocusExclusive' -or
            [int]$surface.vertexShader.getResult -ne 0 -or
            [int]$surface.vertexShader.getFunctionResult -ne 0 -or
            [int]$surface.vertexShader.byteCount -le 0 -or
            [uint32]$surface.vertexShader.fnv1a32 -eq 0 -or
            [int]$transforms.worldResult -ne 0 -or
            [int]$transforms.viewResult -ne 0 -or
            [int]$transforms.projectionResult -ne 0 -or
            -not $worldTransformFinite -or
            -not $viewTransformFinite -or
            -not $projectionTransformFinite -or
            [int]$renderTarget.renderTargetResult -ne 0 -or
            [int]$renderTarget.renderTargetDescriptionResult -ne 0 -or
            [int]$renderTarget.backBufferResult -ne 0 -or
            [int]$renderTarget.backBufferDescriptionResult -ne 0 -or
            [int]$renderTarget.renderTargetIdentityResult -ne 0 -or
            [int]$renderTarget.backBufferIdentityResult -ne 0 -or
            -not [bool]$renderTarget.matchesBackBufferDimensions -or
            [int]$targetDescription.width -le 0 -or
            [int]$targetDescription.height -le 0 -or
            [int]$targetDescription.width -ne [int]$backBufferDescription.width -or
            [int]$targetDescription.height -ne [int]$backBufferDescription.height -or
            [int]$viewport.getResult -ne 0 -or
            [int]$viewport.x -ne 0 -or [int]$viewport.y -ne 0 -or
            [int]$viewport.width -ne [int]$targetDescription.width -or
            [int]$viewport.height -ne [int]$targetDescription.height -or
            [Math]::Abs([double]$viewport.minimumZ -
                [double]$surfaceContractPolicy.normalizedDepthMinimum) -gt $matrixTolerance -or
            [Math]::Abs([double]$viewport.maximumZ -
                [double]$surfaceContractPolicy.normalizedDepthMaximum) -gt $matrixTolerance -or
            [int]$scissor.getResult -ne 0 -or
            [int]$scissor.left -ne 0 -or [int]$scissor.top -ne 0 -or
            [int]$scissor.right -ne [int]$targetDescription.width -or
            [int]$scissor.bottom -ne [int]$targetDescription.height) {
            throw "Actor surface contract frame $expectedFrame contains an incomplete final-eye skinned source-resolution scene-color draw."
        }
        $isPerspectiveSceneDraw = [double]$projection[0] -gt 0 -and
            [double]$projection[5] -gt 0 -and
            [Math]::Abs([double]$projection[11] -
                [double]$surfaceContractPolicy.perspectiveWTerm) -le $matrixTolerance -and
            [Math]::Abs([double]$projection[15] -
                [double]$surfaceContractPolicy.homogeneousBottomRight) -le $matrixTolerance
        if (-not $isPerspectiveSceneDraw) {
            # Matching actor textures can be rebound by a later orthographic
            # glow/image-space pass. Retain that observation, but do not mistake
            # it for the actor's perspective scene-color draw.
            $excludedAuxiliarySurfaceSummaries.Add([pscustomobject][ordered]@{
                renderFrame = [int]$surface.renderFrame
                renderClass = [string]$surface.renderClass
                texture = [string]$matchedTexture.path
                roles = @($matchedTexture.roles)
                geometryNames = @($matchedTexture.geometryNames)
                visualNodePaths = @($matchedTexture.visualNodePaths)
                semantics = @($matchedTexture.semantics)
                projection = @($projection)
                exclusion = 'non-perspective-auxiliary-texture-rebind'
            })
            continue
        }
        if ([string]$surface.renderClass -cne $expectedRenderClass -or
            (-not $skinnedActorShader -and -not $isSemanticFocusSurface)) {
            throw "Actor surface contract frame $expectedFrame contains a perspective draw with an invalid actor render class."
        }
        $frameHasSemanticFocusSurface = $frameHasSemanticFocusSurface -or
            $isSemanticFocusSurface
        $surfaceSummaries.Add([pscustomobject][ordered]@{
            renderFrame = [int]$surface.renderFrame
            renderClass = [string]$surface.renderClass
            texture = [string]$matchedTexture.path
            roles = @($matchedTexture.roles)
            geometryNames = @($matchedTexture.geometryNames)
            visualNodePaths = @($matchedTexture.visualNodePaths)
            semantics = @($matchedTexture.semantics)
            semanticFocusSurface = [bool]$matchedTexture.semanticFocusSurface
            semanticFocusExclusive = $isSemanticFocusSurface
            vertexShaderFnv1a32 = [uint32]$surface.vertexShader.fnv1a32
            skinnedActorShader = $skinnedActorShader
        })
        if ($null -eq $representativeProjection) {
            $representativeProjection = @($projection)
            $representativeBackBuffer = $backBufferDescription
            $representativeSurface = $surface
        }
    }
    if ($surfaceSummaries.Count -eq 0) {
        if (-not $authoredReferenceMode) {
            throw "Actor surface contract frame $expectedFrame has no perspective scene-color actor draw."
        }
        $surfaceFrameSummaries.Add([pscustomobject][ordered]@{
            sourceFrame = [int]$expectedFrame
            shotKind = [string]$shotFrameKinds[[int]$expectedFrame]
            reviewRequired = [bool]$shotFrameReviewRequired[[int]$expectedFrame]
            status = 'no-final-eye-actor-draw'
            renderFrame = $null
            texture = $null
            vertexShaderFnv1a32 = $null
            backBufferWidth = $null
            backBufferHeight = $null
            projection = $null
            verticalFovRadians = $null
            semanticFocusSurface = $false
            surfaces = @()
            excludedAuxiliarySurfaces = @($excludedAuxiliarySurfaceSummaries)
        })
        continue
    }
    $surfaceFrameSummaries.Add([pscustomobject][ordered]@{
        sourceFrame = [int]$expectedFrame
        shotKind = [string]$shotFrameKinds[[int]$expectedFrame]
        reviewRequired = [bool]$shotFrameReviewRequired[[int]$expectedFrame]
        status = if ($frameHasSemanticFocusSurface) {
            'visible-final-eye-semantic-focus-draw'
        } else { 'visible-final-eye-actor-draw-without-semantic-focus' }
        renderFrame = [int]$representativeSurface.renderFrame
        texture = [string]$representativeSurface.matchedTexture.path
        vertexShaderFnv1a32 = [uint32]$representativeSurface.vertexShader.fnv1a32
        backBufferWidth = [int]$representativeBackBuffer.width
        backBufferHeight = [int]$representativeBackBuffer.height
        projection = @($representativeProjection)
        verticalFovRadians = 2.0 * [Math]::Atan(
            1.0 / [double]$representativeProjection[5])
        semanticFocusSurface = $frameHasSemanticFocusSurface
        surfaces = @($surfaceSummaries)
        excludedAuxiliarySurfaces = @($excludedAuxiliarySurfaceSummaries)
    })
    ++$visibleSurfaceFrameCount
    if ($frameHasSemanticFocusSurface) {
        ++$semanticFocusSurfaceFrameCount
    }
}
if ($authoredReferenceMode -and $visibleSurfaceFrameCount -lt 1) {
    throw 'Authored-reference capture has no visible final-eye actor presentation candidate.'
}
if ($semanticFocusSurfaceFrameCount -lt 1) {
    throw 'Actor capture has no final-eye draw from the configured semantic focus subtree.'
}
$surfaceContractSummary = [pscustomobject][ordered]@{
    finalEyeSourceResolutionSceneColorRequired = $true
    acceptedRenderClasses = @('skinned-actor', 'semantic-focus')
    semanticFocusSurfaceRequired = $true
    semanticFocusRules = @($semanticFocusRules)
    targetTextureCount = @($drawTargetEvents[0].textures).Count
    renderFrameLead = [int]$surfaceContractPolicy.renderFrameLead
    visibleSourceFrameCount = $visibleSurfaceFrameCount
    semanticFocusSourceFrameCount = $semanticFocusSurfaceFrameCount
    occludedSourceFrameCount = $orderedScreenshotFrames.Count - $visibleSurfaceFrameCount
    sourceFrames = @($surfaceFrameSummaries)
}
$imageSpaceEvents = @($events | Where-Object {
    [string]$_.event -eq [string]$imageSpacePolicy.event
})
if ($imageSpaceEvents.Count -ne 1) {
    throw "Retail actor observation requires exactly one image-space shader-input event."
}
$imageSpaceEvent = $imageSpaceEvents[0]
$imageSpaceRegisters = @($imageSpaceEvent.registers)
$imageSpaceInputs = @($imageSpaceEvent.inputTextures)
if ([int]$imageSpaceEvent.frame -le 0 -or
    [int]$imageSpaceEvent.byteCount -ne [int]$imageSpacePolicy.expectedShaderByteCount -or
    [uint32]$imageSpaceEvent.fnv1a32 -ne [uint32]$imageSpacePolicy.expectedShaderFnv1a32 -or
    [string]$imageSpaceEvent.path -cne [string]$imageSpacePolicy.path -or
    [int]$imageSpaceEvent.getConstantsResult -ne 0 -or
    -not [bool]$imageSpaceEvent.inputCaptureEnabled -or
    [int]$imageSpaceEvent.expectedShaderByteCount -ne
        [int]$imageSpacePolicy.expectedShaderByteCount -or
    [uint32]$imageSpaceEvent.expectedShaderFnv1a32 -ne
        [uint32]$imageSpacePolicy.expectedShaderFnv1a32 -or
    [int]$imageSpaceEvent.sourceFrame -ne $imageSpaceSourceFrame -or
    [int]$imageSpaceEvent.renderFrame -ne
        ($imageSpaceSourceFrame - [int]$imageSpacePolicy.renderFrameLead) -or
    [int]$imageSpaceEvent.renderFrameLead -ne
        [int]$imageSpacePolicy.renderFrameLead -or
    [int]$imageSpaceEvent.srgbWrite.getResult -ne 0 -or
    $imageSpaceRegisters.Count -ne 24 -or
    $imageSpaceInputs.Count -ne @($imageSpacePolicy.inputTextureStages).Count) {
    throw 'Retail image-space shader identity, constants, or input count differs from policy.'
}
foreach ($register in $imageSpaceRegisters) {
    if (-not (Test-FiniteNumberArray -Values @($register) -ExpectedCount 4)) {
        throw 'Retail image-space shader constants contain an incomplete register.'
    }
}
$imageSpaceDirectoryPrefix = $imageSpaceArtifactDirectory.TrimEnd(
    [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) +
    [IO.Path]::DirectorySeparatorChar
$imageSpaceInputSummary = [Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $imageSpaceInputs.Count; $index++) {
    $input = $imageSpaceInputs[$index]
    $expectedStage = [int]@($imageSpacePolicy.inputTextureStages)[$index]
    $description = $input.description
    $artifact = $input.artifact
    $artifactPath = [IO.Path]::GetFullPath([string]$artifact.path)
    $canonicalBytes = [int64]$input.canonicalBytes
    if ([int]$input.ordinal -ne $index -or
        [int]$input.stage -ne $expectedStage -or
        [int]$input.getTextureResult -ne 0 -or
        [int]$input.levelDescriptionResult -ne 0 -or
        [int]$input.getSurfaceResult -ne 0 -or
        [int]$input.createSystemSurfaceResult -ne 0 -or
        [int]$input.copyResult -ne 0 -or
        [int]$input.lockResult -ne 0 -or
        [int]$input.allocationResult -ne 0 -or
        [int]$input.unlockResult -ne 0 -or
        [int]$input.srgbTexture.getResult -ne 0 -or
        [int]$input.levelCount -lt 1 -or
        [int]$description.width -lt 1 -or [int]$description.height -lt 1 -or
        [int]$description.format -eq 0 -or
        [int]$input.rowBytes -lt 1 -or [int]$input.rowCount -lt 1 -or
        $canonicalBytes -ne ([int64]$input.rowBytes * [int64]$input.rowCount) -or
        $canonicalBytes -gt [int64]$imageSpacePolicy.maximumBytesPerInput -or
        -not [bool]$input.layoutResolved -or
        -not [bool]$input.withinConfiguredBound -or
        -not [bool]$input.captured -or
        [uint32]$input.fnv1a32 -eq 0 -or
        -not [bool]$artifact.written -or
        [int64]$artifact.bytes -ne $canonicalBytes -or
        [uint32]$artifact.fnv1a32 -ne [uint32]$input.fnv1a32 -or
        -not $artifactPath.StartsWith(
            $imageSpaceDirectoryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
        (Get-Item -LiteralPath $artifactPath).Length -ne $canonicalBytes) {
        throw "Retail image-space shader input stage $expectedStage is incomplete or outside its immutable bound."
    }
    $imageSpaceInputSummary.Add([pscustomobject][ordered]@{
        ordinal = $index
        stage = $expectedStage
        width = [int]$description.width
        height = [int]$description.height
        format = [int]$description.format
        srgbTexture = [int]$input.srgbTexture.enabled
        canonicalBytes = $canonicalBytes
        fnv1a32 = [uint32]$input.fnv1a32
        artifact = $artifactPath
    })
}
if (@(Get-ChildItem -LiteralPath $imageSpaceArtifactDirectory -File).Count -ne
    $imageSpaceInputs.Count) {
    throw 'Retail image-space artifact directory does not contain exactly one file per configured input.'
}
$imageSpaceSummary = [pscustomobject][ordered]@{
    sourceFrame = [int]$imageSpaceEvent.sourceFrame
    renderFrame = [int]$imageSpaceEvent.renderFrame
    renderFrameLead = [int]$imageSpaceEvent.renderFrameLead
    path = [string]$imageSpaceEvent.path
    shaderByteCount = [int]$imageSpaceEvent.byteCount
    shaderFnv1a32 = [uint32]$imageSpaceEvent.fnv1a32
    srgbWrite = [int]$imageSpaceEvent.srgbWrite.enabled
    inputs = @($imageSpaceInputSummary)
}
$imageSpaceTraceEvents = @($events | Where-Object {
    [string]$_.event -eq [string]$imageSpaceTracePolicy.event
})
if ($imageSpaceTraceEvents.Count -ne 1) {
    throw 'Retail actor observation requires exactly one image-space pipeline trace.'
}
$imageSpaceTrace = $imageSpaceTraceEvents[0]
$traceRecords = @($imageSpaceTrace.records)
$configuredTraceHashes = @($imageSpaceTrace.configuredPixelShaderFnv1a32 |
    ForEach-Object { [uint32]$_ })
$expectedTraceHashes = @($imageSpaceTracePolicy.pixelShaderFnv1a32 |
    ForEach-Object { [uint32]$_ })
if ([int]$imageSpaceTrace.frame -ne $imageSpaceSourceFrame -or
    [int]$imageSpaceTrace.sourceFrame -ne $imageSpaceSourceFrame -or
    [int]$imageSpaceTrace.renderFrame -ne
        ($imageSpaceSourceFrame - [int]$imageSpaceTracePolicy.renderFrameLead) -or
    [int]$imageSpaceTrace.renderFrameLead -ne
        [int]$imageSpaceTracePolicy.renderFrameLead -or
    [int]$imageSpaceTrace.maximumRecords -ne
        [int]$imageSpaceTracePolicy.maximumRecords -or
    ($configuredTraceHashes -join ',') -cne ($expectedTraceHashes -join ',') -or
    $traceRecords.Count -lt [int]$imageSpaceTracePolicy.minimumRecords -or
    $traceRecords.Count -gt [int]$imageSpaceTracePolicy.maximumRecords -or
    @($traceRecords.ordinal | Sort-Object -Unique).Count -ne $traceRecords.Count) {
    throw 'Retail image-space pipeline trace framing, shader set, or bounds differ from policy.'
}
$imageSpaceTraceSummaryRecords = [Collections.Generic.List[object]]::new()
foreach ($record in $traceRecords) {
    $pixelShader = $record.pixelShader
    $pixelConstants = $record.pixelConstants
    $vertexShader = $record.vertexShader
    $vertexConstants = $record.vertexConstants
    $renderTarget = $record.renderTarget
    $targetDescription = $renderTarget.description
    $viewport = $record.viewport
    $scissor = $record.scissor
    $textures = @($record.textures)
    $upVertexBytes = $record.upVertexBytes
    $pixelHash = [uint32]$pixelShader.fnv1a32
    $pixelRegisterCount = [int]$pixelConstants.registerCount
    $vertexRegisterCount = [int]$vertexConstants.registerCount
    $upVertexValues = @($upVertexBytes.values)
    if ([int]$record.sourceFrame -ne $imageSpaceSourceFrame -or
        [int]$record.renderFrame -ne
            ($imageSpaceSourceFrame - [int]$imageSpaceTracePolicy.renderFrameLead) -or
        [string]::IsNullOrWhiteSpace([string]$record.drawMethod) -or
        [int]$record.primitiveCount -lt 1 -or [int]$record.vertexCount -lt 1 -or
        $expectedTraceHashes -notcontains $pixelHash -or
        [int]$pixelShader.byteCount -lt 1 -or
        [int]$pixelShader.byteCount -gt [int]$imageSpaceTracePolicy.maximumShaderBytes -or
        [int]$pixelConstants.getResult -ne 0 -or
        $pixelRegisterCount -ne [int]$imageSpaceTracePolicy.pixelShaderRegisterCount -or
        -not (Test-FiniteNumberArray -Values @($pixelConstants.values) `
            -ExpectedCount ($pixelRegisterCount * 4)) -or
        [int]$vertexShader.getResult -ne 0 -or
        [int]$vertexShader.getFunctionResult -ne 0 -or
        [int]$vertexShader.byteCount -lt 1 -or
        [int]$vertexShader.byteCount -gt [int]$imageSpaceTracePolicy.maximumShaderBytes -or
        [uint32]$vertexShader.fnv1a32 -eq 0 -or
        [int]$vertexConstants.getResult -ne 0 -or
        $vertexRegisterCount -ne [int]$imageSpaceTracePolicy.vertexShaderRegisterCount -or
        -not (Test-FiniteNumberArray -Values @($vertexConstants.values) `
            -ExpectedCount ($vertexRegisterCount * 4)) -or
        [int]$record.colorSpaceState.srgbWriteResult -ne 0 -or
        [int]$renderTarget.getResult -ne 0 -or
        [int]$renderTarget.descriptionResult -ne 0 -or
        [int]$targetDescription.width -lt 1 -or
        [int]$targetDescription.height -lt 1 -or
        [int]$targetDescription.format -eq 0 -or
        [int]$viewport.getResult -ne 0 -or
        [int]$viewport.width -ne [int]$targetDescription.width -or
        [int]$viewport.height -ne [int]$targetDescription.height -or
        [int]$scissor.getResult -ne 0 -or
        $textures.Count -ne [int]$imageSpaceTracePolicy.textureStageCount -or
        @($textures | Where-Object {
            [int]$_.stage -lt 0 -or
            [int]$_.stage -ge [int]$imageSpaceTracePolicy.textureStageCount -or
            [int]$_.sampler.addressUResult -ne 0 -or
            [int]$_.sampler.addressVResult -ne 0 -or
            [int]$_.sampler.magFilterResult -ne 0 -or
            [int]$_.sampler.minFilterResult -ne 0 -or
            [int]$_.sampler.mipFilterResult -ne 0 -or
            [int]$_.sampler.srgbTextureResult -ne 0
        }).Count -ne 0 -or
        [int]$upVertexBytes.byteCount -ne $upVertexValues.Count -or
        [int]$upVertexBytes.byteCount -gt [int]$imageSpaceTracePolicy.maximumVertexBytes -or
        ($upVertexValues.Count -gt 0 -and [uint32]$upVertexBytes.fnv1a32 -eq 0)) {
        throw "Retail image-space pipeline trace record $($record.ordinal) is incomplete or outside its declared bounds."
    }
    $imageSpaceTraceSummaryRecords.Add([pscustomobject][ordered]@{
        ordinal = [int]$record.ordinal
        drawMethod = [string]$record.drawMethod
        primitiveType = [int]$record.primitiveType
        primitiveCount = [int]$record.primitiveCount
        pixelShaderByteCount = [int]$pixelShader.byteCount
        pixelShaderFnv1a32 = $pixelHash
        vertexShaderFnv1a32 = [uint32]$vertexShader.fnv1a32
        renderTargetWidth = [int]$targetDescription.width
        renderTargetHeight = [int]$targetDescription.height
        renderTargetFormat = [int]$targetDescription.format
        srgbWrite = [int]$record.colorSpaceState.srgbWrite
        textureDescriptions = @($textures | ForEach-Object {
            [pscustomobject][ordered]@{
                stage = [int]$_.stage
                bound = [int]$_.getResult -eq 0 -and [int]$_.resourceType -ne 0
                width = [int]$_.description.width
                height = [int]$_.description.height
                format = [int]$_.description.format
                srgbTexture = [int]$_.sampler.srgbTexture
            }
        })
        upVertexBytes = [int]$upVertexBytes.byteCount
    })
}
if (@($imageSpaceTraceSummaryRecords.pixelShaderFnv1a32) -notcontains
    [uint32]$imageSpacePolicy.expectedShaderFnv1a32) {
    throw 'Retail image-space pipeline trace did not retain the configured final HDR shader draw.'
}
$imageSpacePipelineTraceSummary = [pscustomobject][ordered]@{
    sourceFrame = [int]$imageSpaceTrace.sourceFrame
    renderFrame = [int]$imageSpaceTrace.renderFrame
    renderFrameLead = [int]$imageSpaceTrace.renderFrameLead
    configuredPixelShaderFnv1a32 = @($configuredTraceHashes)
    records = @($imageSpaceTraceSummaryRecords)
}
$drawContractSummary = $null
$drawContractEvents = @($events | Where-Object {
    [string]$_.event -eq [string]$drawContractPolicy.event
})
if ($ActorDrawContractDiagnostic) {
    $retainedTargetTextureArtifacts = 0
    foreach ($texture in @($drawTargetEvents[0].textures)) {
        $artifact = $texture.artifact
        if (-not [bool]$artifact.written) {
            continue
        }
        $artifactPath = [IO.Path]::GetFullPath([string]$artifact.path)
        if ([int]$texture.width -le 0 -or [int]$texture.height -le 0 -or
            [int]$texture.levelCount -le 0 -or @($texture.levels).Count -ne
                [int]$texture.levelCount -or
            -not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
            -not $artifactPath.StartsWith(
                [IO.Path]::GetFullPath($drawArtifactDirectory) +
                    [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase) -or
            (Get-Item -LiteralPath $artifactPath).Length -ne [int64]$artifact.bytes -or
            [int64]$artifact.bytes -gt
                [int64]$drawContractPolicy.maximumTextureBytesPerArtifact) {
            throw "Actor draw-contract target texture artifact is incomplete: $artifactPath"
        }
        ++$retainedTargetTextureArtifacts
    }
    if ($retainedTargetTextureArtifacts -lt 1) {
        throw 'Actor draw-contract diagnostic retained no bounded target-texture artifact.'
    }
    $boundTextureArtifactEvents = @($events | Where-Object {
        [string]$_.event -eq [string]$drawContractPolicy.boundTextureArtifactsEvent
    })
    $retainedBoundTextureArtifacts = 0
    foreach ($textureEvent in $boundTextureArtifactEvents) {
        if ([int]$textureEvent.sourceFrame -notin $orderedScreenshotFrames) {
            throw 'Actor draw-contract bound-texture artifact has an undeclared source frame.'
        }
        foreach ($texture in @($textureEvent.textures)) {
            $artifact = $texture.artifact
            $artifactPath = [IO.Path]::GetFullPath([string]$artifact.path)
            if ([int]$texture.width -le 0 -or [int]$texture.height -le 0 -or
                [int]$texture.levelCount -le 0 -or @($texture.levels).Count -ne
                    [int]$texture.levelCount -or -not [bool]$artifact.written -or
                -not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
                -not $artifactPath.StartsWith(
                    [IO.Path]::GetFullPath($drawArtifactDirectory) +
                        [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase) -or
                (Get-Item -LiteralPath $artifactPath).Length -ne [int64]$artifact.bytes -or
                [int64]$artifact.bytes -gt
                    [int64]$drawContractPolicy.maximumTextureBytesPerArtifact) {
                throw "Actor draw-contract bound texture artifact is incomplete: $artifactPath"
            }
            ++$retainedBoundTextureArtifacts
        }
    }
    if ($retainedBoundTextureArtifacts -lt 1) {
        throw 'Actor draw-contract diagnostic retained no bounded live sampler artifact.'
    }
    if ($drawContractEvents.Count -ne $orderedScreenshotFrames.Count) {
        throw "Actor draw-contract diagnostic retained $($drawContractEvents.Count) source-frame events; expected $($orderedScreenshotFrames.Count)."
    }
    $drawFrameSummaries = [Collections.Generic.List[object]]::new()
    foreach ($expectedFrame in $orderedScreenshotFrames) {
        $frameEvents = @($drawContractEvents | Where-Object {
            [int]$_.sourceFrame -eq [int]$expectedFrame
        })
        if ($frameEvents.Count -ne 1) {
            throw "Actor draw-contract diagnostic frame $expectedFrame is missing or duplicated."
        }
        $drawEvent = $frameEvents[0]
        $records = @($drawEvent.records)
        if ([int]$drawEvent.frame -ne [int]$expectedFrame -or
            [int]$drawEvent.renderFrameLead -ne
                [int]$drawContractPolicy.renderFrameLead -or
            -not [bool]$drawEvent.targetTexturesReady -or
            [int]$drawEvent.maximumRecords -ne
                [int]$drawContractPolicy.maximumRecordsPerSourceFrame -or
            $records.Count -lt 1 -or $records.Count -gt
                [int]$drawContractPolicy.maximumRecordsPerSourceFrame) {
            throw "Actor draw-contract diagnostic frame $expectedFrame has invalid timing, registry, or record count."
        }
        $completeShaderRecords = 0
        $sourceResolutionRecords = 0
        $surfaceShaderRecords = 0
        $surfaceShaderHash = [uint32](@($surfaceContractEvents | Where-Object {
            [int]$_.sourceFrame -eq [int]$expectedFrame
        })[0].surface.vertexShader.fnv1a32)
        foreach ($record in $records) {
            $constants = @($record.vertexConstants.values)
            $pixelConstants = @($record.pixelConstants.values)
            $recordTarget = $record.renderTarget
            if ([int]$record.sourceFrame -ne [int]$expectedFrame -or
                [int]$record.renderFrame -ne [int]$expectedFrame -
                    [int]$drawContractPolicy.renderFrameLead -or
                [string]::IsNullOrWhiteSpace([string]$record.matchedTexture.path) -or
                [int]$record.vertexConstants.registerCount -ne
                    [int]$drawContractPolicy.vertexShaderRegisterCount -or
                $constants.Count -ne
                    [int]$drawContractPolicy.vertexShaderRegisterCount * 4 -or
                [int]$record.pixelConstants.registerCount -ne
                    [int]$drawContractPolicy.pixelShaderRegisterCount -or
                $pixelConstants.Count -ne
                    [int]$drawContractPolicy.pixelShaderRegisterCount * 4 -or
                [int]$recordTarget.renderTargetResult -ne 0 -or
                [int]$recordTarget.renderTargetDescriptionResult -ne 0 -or
                [int]$recordTarget.backBufferResult -ne 0 -or
                [int]$recordTarget.backBufferDescriptionResult -ne 0 -or
                [int]$recordTarget.renderTargetIdentityResult -ne 0 -or
                [int]$recordTarget.backBufferIdentityResult -ne 0) {
                throw "Actor draw-contract diagnostic frame $expectedFrame contains an invalid draw record."
            }
            if ([bool]$recordTarget.matchesBackBufferDimensions) {
                ++$sourceResolutionRecords
                if ([uint32]$record.vertexShader.fnv1a32 -eq $surfaceShaderHash) {
                    ++$surfaceShaderRecords
                }
            }
            if ([int]$record.vertexShader.getResult -eq 0 -and
                [int]$record.vertexShader.getFunctionResult -eq 0 -and
                [int]$record.vertexShader.byteCount -gt 0 -and
                [bool]$record.vertexShader.artifact.written -and
                [int]$record.vertexConstants.getResult -eq 0 -and
                [int]$record.pixelShader.getResult -eq 0 -and
                [int]$record.pixelShader.getFunctionResult -eq 0 -and
                [int]$record.pixelShader.byteCount -gt 0 -and
                [bool]$record.pixelShader.artifact.written -and
                [int]$record.pixelConstants.getResult -eq 0 -and
                @($record.vertexDeclaration.elements).Count -gt 0) {
                $shaderPath = [IO.Path]::GetFullPath([string]$record.vertexShader.artifact.path)
                $pixelShaderPath = [IO.Path]::GetFullPath([string]$record.pixelShader.artifact.path)
                if (-not (Test-Path -LiteralPath $shaderPath -PathType Leaf) -or
                    -not $shaderPath.StartsWith(
                        [IO.Path]::GetFullPath($drawArtifactDirectory) +
                            [IO.Path]::DirectorySeparatorChar,
                        [StringComparison]::OrdinalIgnoreCase) -or
                    (Get-Item -LiteralPath $shaderPath).Length -ne
                        [int64]$record.vertexShader.artifact.bytes -or
                    -not (Test-Path -LiteralPath $pixelShaderPath -PathType Leaf) -or
                    -not $pixelShaderPath.StartsWith(
                        [IO.Path]::GetFullPath($drawArtifactDirectory) +
                            [IO.Path]::DirectorySeparatorChar,
                        [StringComparison]::OrdinalIgnoreCase) -or
                    (Get-Item -LiteralPath $pixelShaderPath).Length -ne
                        [int64]$record.pixelShader.artifact.bytes) {
                    throw "Actor draw-contract shader artifact is missing or outside its immutable directory: $shaderPath"
                }
                ++$completeShaderRecords
            }
        }
        if ($completeShaderRecords -lt 1 -or $sourceResolutionRecords -lt 1 -or
            $surfaceShaderRecords -lt 1) {
            throw "Actor draw-contract diagnostic frame $expectedFrame contains no complete replayable copy of its final-eye surface draw."
        }
        $drawFrameSummaries.Add([pscustomobject][ordered]@{
            sourceFrame = [int]$expectedFrame
            renderFrame = [int]$expectedFrame -
                [int]$drawContractPolicy.renderFrameLead
            recordCount = $records.Count
            completeShaderRecordCount = $completeShaderRecords
            sourceResolutionRecordCount = $sourceResolutionRecords
            surfaceShaderRecordCount = $surfaceShaderRecords
            vertexBufferArtifacts = @($records | Where-Object {
                [bool]$_.vertexBuffer.artifact.written
            }).Count
            indexBufferArtifacts = @($records | Where-Object {
                [bool]$_.indexBuffer.artifact.written
            }).Count
        })
    }
    $drawContractSummary = [pscustomobject][ordered]@{
        targetTextureArtifacts = $retainedTargetTextureArtifacts
        boundTextureArtifacts = $retainedBoundTextureArtifacts
        diagnosticOnly = $true
        targetTextureCount = @($drawTargetEvents[0].textures).Count
        renderFrameLead = [int]$drawContractPolicy.renderFrameLead
        sourceFrames = @($drawFrameSummaries)
    }
}
elseif ($drawContractEvents.Count -ne 0) {
    throw 'Actor draw-contract events were retained without the explicit diagnostic switch.'
}
$actorFrames = @($events | Where-Object {
    [string]$_.event -eq [string]$telemetryPolicy.poseEvent -and
        [uint32]$_.refForm -eq $observedReference
})
if ($actorFrames.Count -lt [int]$telemetryPolicy.minimumPoseSamples) {
    throw 'Retail capture did not retain enough target-actor animation frames.'
}
if (@($actorFrames | Where-Object {
        [uint32]$_.baseForm -ne $observedRuntimeBase
    }).Count -ne 0) {
    throw 'Retail target-actor pose samples changed runtime base identity.'
}
$jsonlBytes = (Get-Item -LiteralPath $jsonlPath).Length
if ($jsonlBytes -gt [int64]$telemetryPolicy.maximumJsonlBytes) {
    throw "Compact actor telemetry is $jsonlBytes bytes; policy maximum is $($telemetryPolicy.maximumJsonlBytes)."
}
$scheduledEvents = @($events | Where-Object { [string]$_.event -eq 'scheduled-console-command' })
if ($scheduledEvents.Count -ne $scheduledCommands.Count -or
    @($scheduledEvents | Where-Object { -not [bool]$_.accepted }).Count -ne 0) {
    throw 'Actor observation did not accept its complete in-process schedule.'
}

$observedStableForms = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$leveledExtra = $templateEvents[0].leveledExtra
foreach ($runtimeSourceForm in @(
    [uint32]$leveledExtra.form,
    [uint32]$templateEvents[0].templateActorForm,
    [uint32]$templateEvents[0].subtypeTemplateForm
)) {
    if ($runtimeSourceForm -eq 0 -or $runtimeSourceForm -eq $requestedRuntimeForm) { continue }
    $stableForm = ConvertTo-StableFormKey $runtimeSourceForm $runtimePlugins
    if ($null -ne $stableForm) { [void]$observedStableForms.Add($stableForm) }
}

$classificationCandidates = [Collections.Generic.List[object]]::new()
$classificationMethod = 'pending-insufficient-runtime-lineage'
if ($reviewRows.Count -eq 1) {
    $classificationCandidates.Add($reviewRows[0])
    $classificationMethod = 'single-declared-outcome-with-validated-runtime-identity'
}
elseif ($observedStableForms.Count -gt 0) {
    foreach ($row in $reviewRows) {
        $rowForms = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($source in @($row.categorySources.PSObject.Properties.Value)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$source)) {
                [void]$rowForms.Add([string]$source)
            }
        }
        foreach ($path in @($row.templateSelectionPaths)) {
            foreach ($source in @($path)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$source)) {
                    [void]$rowForms.Add([string]$source)
                }
            }
        }
        $matchesEveryObservedForm = $true
        foreach ($observedForm in $observedStableForms) {
            if (-not $rowForms.Contains($observedForm)) {
                $matchesEveryObservedForm = $false
                break
            }
        }
        if ($matchesEveryObservedForm) { $classificationCandidates.Add($row) }
    }
    $classificationMethod = 'observed-runtime-lineage-to-declared-template-path'
}
$classifiedReviewKey = if ($classificationCandidates.Count -eq 1) {
    [string]$classificationCandidates[0].reviewKey
} else { $null }
$classificationComplete = $null -ne $classifiedReviewKey
$observationStatus = if ($classificationComplete -and
    $appearanceEvidenceStatus -ceq 'complete') {
    'captured-classified-runtime-observation'
} elseif ($classificationComplete) {
    'captured-classified-incomplete-appearance-evidence'
} else {
    'captured-unclassified-runtime-observation'
}

$motionFrameFiles = [Collections.Generic.List[object]]::new()
foreach ($frame in @($motionShots[0].screenshotFrames | ForEach-Object { [int]$_ })) {
    $expectedName = 'frame-{0:D6}.bmp' -f $frame
    $matches = @($oracleRun.screenshots | Where-Object {
        [IO.Path]::GetFileName([string]$_) -ceq $expectedName
    })
    if ($matches.Count -ne 1) {
        throw "Idle-motion source frame '$expectedName' was not retained exactly once."
    }
    $motionFrameFiles.Add([pscustomobject]@{ frame = $frame; path = [string]$matches[0] })
}
$motionConcatPath = Join-Path $retailDirectory 'idle-motion-source-frames.ffconcat'
$motionConcatLines = [Collections.Generic.List[string]]::new()
$timelineFrameRate = [double]$motionPolicy.timelineFrameRate
for ($frameIndex = 0; $frameIndex -lt $motionFrameFiles.Count; ++$frameIndex) {
    $sourcePath = [string]$motionFrameFiles[$frameIndex].path
    if ($sourcePath.Contains("'")) {
        throw "Idle-motion source path cannot be represented safely in ffconcat: $sourcePath"
    }
    $motionConcatLines.Add("file '$($sourcePath.Replace('\', '/'))'")
    $durationFrames = if ($frameIndex + 1 -lt $motionFrameFiles.Count) {
        [int]$motionFrameFiles[$frameIndex + 1].frame - [int]$motionFrameFiles[$frameIndex].frame
    } else {
        [int]$motionPolicy.tailDurationFrames
    }
    if ($durationFrames -lt 1) { throw 'Idle-motion source frames are not strictly increasing.' }
    $duration = [double]$durationFrames / $timelineFrameRate
    $motionConcatLines.Add('duration ' + $duration.ToString(
        '0.000000000', [Globalization.CultureInfo]::InvariantCulture))
}
$lastMotionPath = [string]$motionFrameFiles[-1].path
$motionConcatLines.Add("file '$($lastMotionPath.Replace('\', '/'))'")
[IO.File]::WriteAllLines(
    $motionConcatPath, $motionConcatLines, [Text.UTF8Encoding]::new($false))
$motionVideoPath = Join-Path $retailDirectory ([string]$motionPolicy.file)
$ffmpegArguments = @(
    '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'concat', '-safe', '0', '-i', $motionConcatPath,
    '-an', '-c:v', [string]$motionPolicy.codec,
    '-preset', [string]$motionPolicy.preset,
    '-crf', [string][int]$motionPolicy.crf,
    '-pix_fmt', [string]$motionPolicy.pixelFormat,
    '-r', [string][int]$motionPolicy.outputFrameRate,
    '-movflags', [string]$motionPolicy.movFlags,
    $motionVideoPath
)
& $ffmpeg.Source @ffmpegArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $motionVideoPath -PathType Leaf)) {
    throw 'ffmpeg failed to encode the retail idle-motion clip.'
}
$probeJson = (& $ffprobe.Source -v error -select_streams v:0 `
    -show_entries 'stream=codec_name,width,height,avg_frame_rate:format=duration' `
    -of json -- $motionVideoPath) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) { throw 'ffprobe failed to inspect the retail idle-motion clip.' }
$motionProbe = $probeJson | ConvertFrom-Json
$motionVideoStreams = @($motionProbe.streams)
if ($motionVideoStreams.Count -ne 1 -or [int]$motionVideoStreams[0].width -lt 1 -or
    [int]$motionVideoStreams[0].height -lt 1 -or [double]$motionProbe.format.duration -le 0) {
    throw 'Retail idle-motion clip lacks one valid video stream and positive duration.'
}
$motionVideoEvidence = [ordered]@{
    file = Get-FileEvidence $motionVideoPath 'retail-idle-motion-video'
    sourceManifest = Get-FileEvidence $motionConcatPath 'retail-idle-motion-source-manifest'
    sourceFrames = @($motionFrameFiles)
    timelineFrameRate = [int]$motionPolicy.timelineFrameRate
    outputFrameRate = [int]$motionPolicy.outputFrameRate
    codec = [string]$motionVideoStreams[0].codec_name
    width = [int]$motionVideoStreams[0].width
    height = [int]$motionVideoStreams[0].height
    durationSeconds = [double]$motionProbe.format.duration
}

$artifacts = [Collections.Generic.List[object]]::new()
foreach ($artifact in @($runtimeEvidencePluginPath, $runtimeEvidenceManifestPath,
        $jsonlPath, [string]$oracleRun.runManifest) +
    @($oracleRun.screenshots) + @($oracleRun.portraitProofCrops) +
    @($motionConcatPath, $motionVideoPath)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$artifact) -and
        (Test-Path -LiteralPath $artifact -PathType Leaf)) {
        $artifacts.Add((Get-FileEvidence $artifact 'retail-actor-observation'))
    }
}
if ($ActorDrawContractDiagnostic) {
    foreach ($artifact in Get-ChildItem -LiteralPath $drawArtifactDirectory -File) {
        $artifacts.Add((Get-FileEvidence $artifact.FullName 'retail-actor-draw-contract'))
    }
}
foreach ($artifact in Get-ChildItem -LiteralPath $imageSpaceArtifactDirectory -File) {
    $artifacts.Add((Get-FileEvidence $artifact.FullName 'retail-image-space-shader-input'))
}
$reportPath = Join-Path $retailDirectory 'actor-observation-report.json'
$report = [ordered]@{
    schema = 'nikami-fnv-actor-observation/v1'
    status = $observationStatus
    captureJob = $job
    expectedReviewRows = @($reviewRows)
    classifiedReviewKey = $classifiedReviewKey
    classification = [ordered]@{
        complete = $classificationComplete
        method = $classificationMethod
        observedStableForms = @($observedStableForms | Sort-Object)
        candidateReviewKeys = @($classificationCandidates | ForEach-Object { [string]$_.reviewKey })
    }
    evidencePolicy = [ordered]@{
        inventoryIsNotVisualEvidence = $true
        planGenerationIsNotVisualEvidence = $true
        noReviewRowPassed = $true
        runtimeSignatureClassificationPending = -not $classificationComplete
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
    }
    provenance = [ordered]@{
        planManifest = Get-FileEvidence $planManifestPath 'actor-capture-plan-manifest'
        corpusManifest = Get-FileEvidence $corpusManifestPath 'actor-parity-corpus-manifest'
        captureJobs = Get-FileEvidence $jobsPath 'actor-capture-jobs'
        appearanceReview = Get-FileEvidence $appearancePath 'actor-appearance-review-ledger'
        officialPluginStackSha256 = $officialPluginStackSha256
        officialPluginStack = @($corpusInputs)
        galleryShot = if ($authoredReferenceMode) {
            Get-FileEvidence $galleryShotSource 'owned-gallery-capture-shot-contract'
        } else { $null }
        runtimeConfiguration = if ($authoredReferenceMode) {
            Get-FileEvidence $runtimeConfigurationPath 'open-nv-runtime-configuration'
        } else { $null }
        activeRuntimeManifest = Get-FileEvidence `
            $runtimeEvidenceManifestPath 'actor-observation-active-runtime-manifest'
        oraclePlugin = Get-FileEvidence `
            $runtimeEvidencePluginPath 'retail-oracle-plugin'
    }
    runtime = [ordered]@{
        plugins = @($runtimePlugins)
        requestedBaseRuntimeFormId = $runtimeForm
        requestedTargetRuntimeFormId = $targetRuntimeForm
        targetReferenceFormId = '{0:x8}' -f $observedReference
        spawnedReferenceFormId = if ($authoredReferenceMode) {
            $null
        } else { '{0:x8}' -f $observedReference }
        placementMode = if ($authoredReferenceMode) {
            'owned-authored-reference-preserved'
        } else { 'spawned-proof-reference' }
        templateObservation = $templateEvents[0]
        cameraPlacements = @($portraitEvents)
        sourceFrameCameraContracts = @($sourceFrameCameraEvents)
        cameras = @($cameraEvents)
        animationFrameCount = $actorFrames.Count
        animationFirstFrame = [int]$actorFrames[0].frame
        animationLastFrame = [int]$actorFrames[-1].frame
        animationTelemetry = [string]$telemetryPolicy.mode
        liveLocation = $liveLocationSummary
        visualSnapshotEvent = [string]$telemetryPolicy.visualSnapshotEvent
        visualSnapshots = @($snapshotSummaries)
        skinPalettePolicy = [ordered]@{
            requiredForSkinnedGeometry =
                [bool]$telemetryPolicy.requireSkinPalettesForSkinnedGeometry
            componentsPerRegister =
                [int]$telemetryPolicy.skinPaletteComponentsPerRegister
            bytesPerComponent = [int]$telemetryPolicy.skinPaletteBytesPerComponent
            maximumBytesPerShape =
                [int]$telemetryPolicy.skinPaletteMaximumBytesPerShape
        }
        surfaceContract = $surfaceContractSummary
        imageSpaceShaderInputs = $imageSpaceSummary
        imageSpacePipelineTrace = $imageSpacePipelineTraceSummary
        drawContractDiagnostic = $drawContractSummary
        appearanceEvidenceStatus = $appearanceEvidenceStatus
        appearanceEvidenceFaults = $appearanceFaults
        appearanceSnapshot = $appearanceSnapshot
        telemetryBytes = $jsonlBytes
        telemetryMaximumBytes = [int64]$telemetryPolicy.maximumJsonlBytes
    }
    capture = [ordered]@{
        method = if ($authoredReferenceMode) {
            [string]$authoredReferencePolicy.captureMethod
        } else { [string]$recipe.captureMethod }
        scheduledCommands = $scheduledCommands
        authoredReference = if ($authoredReferenceMode) {
            [ordered]@{
                galleryShotId = [string]$galleryShot.id
                ordinal = [int]$galleryShot.ordinal
                locationId = [string]$galleryShot.locationId
                referenceFormId = [string]$galleryShot.referenceFormId
                baseFormId = [string]$galleryShot.baseFormId
                actor = [ordered]@{
                    cellFormId = [string]$galleryShot.actor.cellFormId
                }
                scene = [ordered]@{
                    cellFormId = [string]$galleryShot.scene.cellFormId
                    worldspaceFormId = $galleryShot.scene.worldspaceFormId
                    interior = [bool]$galleryShot.scene.interior
                }
                locationClass = [string]$galleryShot.locationClass
                enableStateMode = [string]$galleryShot.enableState.mode
                frameOffset = $frameOffset
                renderEnvironmentFrame = $renderEnvironmentFrame
                sceneEditorId = if ([string]$galleryShot.locationClass -ceq
                    'exterior') { $authoredSceneEditorId } else { $null }
                sceneLoadFrame = if ([string]$galleryShot.locationClass -ceq
                    'exterior') {
                    $authoredSceneLoadFrame
                } else { $null }
                referenceMoveFrame = $authoredReferenceMoveFrame
                runtimeState = $authoredRuntimeState
                minimumStreamingSettleFrames =
                    [int]$authoredReferencePolicy.minimumStreamingSettleFrames
                actorTransformMutated = $false
            }
        } else { $null }
        shots = @($shots)
        sourceFrames = @($oracleRun.screenshots)
        proofCrops = @($oracleRun.portraitProofCrops)
        motionVideo = $motionVideoEvidence
        retailGrass = $retailGrassCaptureSummary
        oracleRunManifest = [string]$oracleRun.runManifest
    }
    artifacts = @($artifacts)
}
Write-ImmutableJson $reportPath $report 30

[pscustomobject][ordered]@{
    schema = 'nikami-fnv-actor-observation-run/v1'
    status = [string]$report.status
    report = $reportPath
    captureJobKey = $CaptureJobKey
    targetReferenceFormId = $report.runtime.targetReferenceFormId
    spawnedReferenceFormId = $report.runtime.spawnedReferenceFormId
    artifacts = @($artifacts) + @(Get-FileEvidence $reportPath 'actor-observation-report')
    capture = [pscustomobject][ordered]@{
        method = [string]$report.capture.method
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
    }
}
