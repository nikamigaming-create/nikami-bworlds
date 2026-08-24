[CmdletBinding()]
param(
    [ValidateSet("All", "Retail", "OpenMW", "Godot")]
    [string]$Target = "All",
    [ValidateSet("Jam", "FirstSmoke", "ChetObservation", "ChetPersistent", "ChetTransaction", "ChetPersistence", "Canyon", "Opening", "TestMap", "PipBoy", "PipBoyVR", "Terminal", "RealSave", "ActorObservation", "GodotActorReview", "GodotRoute", "GodotCinematics", "GodotPortraits")]
    [string]$Scenario = "Jam",
    [ValidateSet("TTW", "NewVegas")]
    [string]$OpeningCampaign = "TTW",
    [switch]$RuntimeReady,
    [switch]$RequireIdle,
    [string]$WorldsRoot = "",
    [string]$GodotBinary = "",
    [string]$ParityRoot = "",
    [string]$EngineRoot = "",
    [string]$RetailShadowRoot = "",
    [string]$JamRoot = "",
    [string]$JamArchive = "",
    [string]$OpeningRuntimeRoot = "",
    [string]$OpeningTtwRoot = "",
    [string]$OpeningNewVegasData = "",
    [string]$OpeningAudioDevice = "",
    [string]$SavePath = "",
    [string]$ActorPlanRoot = "",
    [string]$ActorCorpusRoot = "",
    [string]$ActorCaptureJobKey = "",
    [string]$ActorOracleSeedRoot = "",
    [string]$ActorOraclePluginDll = "",
    [string]$ActorSaveFixture = "",
    [string]$ActorGameRoot = "D:\SteamLibrary\steamapps\common\Fallout New Vegas",
    [string]$OpenNvRoot = "",
    [string]$ActorReviewScene = "",
    [ValidateSet("save330-cold-load-settle-v1", "save330-reload-idempotence-v1", "save330-pipboy-map-selection-v1", "save330-pipboy-map-travel-v1", "save330-pipboy-rejection-matrix-v1", "save330-travel-persistence-v1", "save330-pipboy-inventory-v1", "save330-pipboy-weapon-selection-v1", "save330-pipboy-radio-stations-v1")]
    [string]$RealSaveRouteId = "save330-cold-load-settle-v1",
    [ValidateRange(5, 600)]
    [int]$RealSaveCaptureSeconds = 30,
    [ValidateRange(52, 90)]
    [int]$TerminalCaptureSeconds = 55,
    [string]$OutputRoot = "",
    [switch]$InteractiveHandoff
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($WorldsRoot)) {
    $WorldsRoot = Split-Path -Parent $PSScriptRoot
}
$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
if ([string]::IsNullOrWhiteSpace($ParityRoot)) {
    # The current repository owns the retail oracle alongside its capture
    # scripts. Keep the preflight checkout-relative when no legacy parity
    # checkout is supplied.
    $ParityRoot = $WorldsRoot
}

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")
if ([string]::IsNullOrWhiteSpace($SavePath)) {
    $SavePath = if ($Scenario -eq "RealSave") {
        Join-Path $WorldsRoot "local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos"
    }
    elseif ($Scenario -in @("FirstSmoke", "ChetObservation", "ChetPersistent", "ChetTransaction", "ChetPersistence")) {
        Join-Path $WorldsRoot "profiles\fallout_new_vegas\userdata\saves\ - 1\Autosave.omwsave"
    }
    else { "" }
}
if ($Target -ne "Godot" -and $Scenario -ne "ActorObservation" -and
    [string]::IsNullOrWhiteSpace($OpeningRuntimeRoot)) {
    $pipBoyRuntimeRoot = Join-Path $WorldsRoot "local\openmw-testmap-fnv-clean-20260801-080000"
    if ($Scenario -eq "PipBoy" -and (Test-Path -LiteralPath (Join-Path $pipBoyRuntimeRoot "openmw.exe") -PathType Leaf)) {
        $OpeningRuntimeRoot = $pipBoyRuntimeRoot
    }
    else {
        $OpeningRuntimeRoot = Resolve-NikamiOpenMWRuntimeRoot
    }
}
if ($Target -ne "Godot" -and $Scenario -ne "ActorObservation") {
    $OpeningRuntimeRoot = [IO.Path]::GetFullPath($OpeningRuntimeRoot)
}

# Pip-Boy and opening checks need the installed FNV Data root. Resolve it
# from an explicit parameter/env/local config first; otherwise inspect the
# configured FNV OpenMW profile rather than assuming a particular drive.
if ($Target -ne "Godot" -and [string]::IsNullOrWhiteSpace($OpeningNewVegasData)) {
    $OpeningNewVegasData = Resolve-NikamiPath `
        -EnvName "NIKAMI_FALLOUT_NEW_VEGAS_DATA" `
        -ConfigName "falloutNewVegasData" `
        -Description "Fallout: New Vegas Data directory"

    if ([string]::IsNullOrWhiteSpace($OpeningNewVegasData)) {
        $fnvRoot = Resolve-NikamiPath -EnvName "NIKAMI_FNV_ROOT" -ConfigName "fnvRoot"
        $profileConfig = if ([string]::IsNullOrWhiteSpace($fnvRoot)) { "" } else {
            Join-Path $fnvRoot "openmw-config\\openmw.cfg"
        }
        if (-not [string]::IsNullOrWhiteSpace($profileConfig) -and
            (Test-Path -LiteralPath $profileConfig -PathType Leaf)) {
            foreach ($line in Get-Content -LiteralPath $profileConfig) {
                if ($line -notmatch '^\s*data\s*=\s*(?<path>.+?)\s*$') { continue }
                $candidate = $Matches.path.Trim().Trim('"')
                if (Test-Path -LiteralPath (Join-Path $candidate "FalloutNV.esm") -PathType Leaf) {
                    $OpeningNewVegasData = $candidate
                    break
                }
            }
        }
    }
}
if (-not [string]::IsNullOrWhiteSpace($OpeningNewVegasData)) {
    $OpeningNewVegasData = [IO.Path]::GetFullPath($OpeningNewVegasData)
}

if (($Scenario -in @("GodotActorReview", "GodotRoute", "GodotCinematics", "GodotPortraits")) -ne ($Target -eq "Godot")) {
    throw "GodotRoute and GodotCinematics are dedicated Godot lanes. Use -Target Godot."
}

if ($Scenario -eq "RealSave" -and $Target -eq "All") {
    throw "RealSave is a single-engine lane. Run Retail and OpenMW as separate sequential captures."
}
if ($Scenario -eq "ActorObservation" -and $Target -ne "Retail") {
    throw "ActorObservation is a retail-only lane. Use -Target Retail."
}
if ($Scenario -eq "Terminal" -and $Target -ne "OpenMW") {
    throw "Terminal interaction is an OpenMW-only lane. Use -Target OpenMW."
}
if ($Scenario -eq "PipBoyVR" -and $Target -ne "OpenMW") {
    throw "PipBoyVR is an OpenMW-only native OpenXR lane. Use -Target OpenMW."
}
if ($Scenario -in @("FirstSmoke", "ChetObservation", "ChetPersistent", "ChetTransaction", "ChetPersistence") -and $Target -ne "OpenMW") {
    throw "FirstSmoke and Chet persistent routes are OpenMW-only lanes. Use -Target OpenMW."
}
if ($Scenario -eq "Canyon" -and $Target -ne "OpenMW") {
    throw "Canyon is an OpenMW-only lane. Use -Target OpenMW."
}
if ($Scenario -eq "RealSave" -and $InteractiveHandoff -and $Target -eq "Retail") {
    throw "Interactive handoff is restricted to the playable OpenMW lane."
}
if ($Scenario -eq "RealSave" -and $OutputRoot -and (Test-Path -LiteralPath $OutputRoot)) {
    throw "Refusing to reuse an existing RealSave output root: $OutputRoot"
}

$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail) {
    $checks.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $Passed
        detail = $Detail
    })
}

function Test-File([string]$Name, [string]$Path) {
    $exists = -not [string]::IsNullOrWhiteSpace($Path) -and
        (Test-Path -LiteralPath $Path -PathType Leaf)
    Add-Check $Name $exists $(if ($exists -or -not [string]::IsNullOrWhiteSpace($Path)) { $Path } else { "not configured" })
    return $exists
}

function Test-Directory([string]$Name, [string]$Path) {
    $exists = -not [string]::IsNullOrWhiteSpace($Path) -and
        (Test-Path -LiteralPath $Path -PathType Container)
    Add-Check $Name $exists $(if ($exists -or -not [string]::IsNullOrWhiteSpace($Path)) { $Path } else { "not configured" })
    return $exists
}

function Test-PowerShellParse([string]$Path) {
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$null, [ref]$parseErrors)
    Add-Check "PowerShell parses: $([IO.Path]::GetFileName($Path))" `
        ($parseErrors.Count -eq 0) `
        ($(if ($parseErrors.Count -eq 0) {
            $Path
        } else {
            ($parseErrors | ForEach-Object Message) -join "; "
        }))
}

$catalogPath = Join-Path $WorldsRoot "catalog\fnv-jam-background-capture-recipes.json"
$runbookPath = Join-Path $WorldsRoot "docs\fnv-jam-background-capture.md"
$entryPointPath = Join-Path $WorldsRoot "scripts\Invoke-FNVJamBackgroundCapture.ps1"
$preflightPath = Join-Path $WorldsRoot "scripts\Test-FNVJamBackgroundCapture.ps1"
$retailRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVJamFullRetailRehearsal.ps1"
$openMwRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVJamSprintProof.ps1"
$firstSmokeRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVFirstSmokeCapture.ps1"
$canyonRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVCanyonCrawlCapture.ps1"
$retailOpeningRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-RetailTTWOpeningCapture.ps1"
$retailTtwLayerInitializerPath = Join-Path $WorldsRoot "scripts\Initialize-TTWRetailCompatibilityLayer.ps1"
$retailTtwLayerManifestPath = Join-Path $WorldsRoot "local\ttw-retail-compat\compatibility-layer.json"
$openingRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVOpeningCapture.ps1"
$testMapRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVTestMapDiagnostic.ps1"
$pipBoyRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVPipBoyShowcaseCapture.ps1"
$pipBoyVrRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVPipBoyVRCapture.ps1"
$vrStartRunnerPath = Join-Path $WorldsRoot "scripts\Start-FNVParityVRExisting.ps1"
$vrHeadPosePath = Join-Path $WorldsRoot "scripts\Invoke-OpenXRSimulatorHeadPose.ps1"
$vrControllerPosePath = Join-Path $WorldsRoot "scripts\Invoke-OpenXRSimulatorControllerPose.ps1"
$vrNativeFramePath = Join-Path $WorldsRoot "scripts\Request-OpenXRSimulatorNativeEyeFrame.ps1"
$terminalRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVTerminalCapture.ps1"
$retailPipBoyRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVRetailPipBoyStateCapture.ps1"
$realSaveRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVRealSaveCapture.ps1"
$actorObservationRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVActorObservationCapture.ps1"
$actorObservationQueuePath = Join-Path $WorldsRoot "scripts\Invoke-FNVActorObservationQueue.ps1"
$actorReviewRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-OpenNVActorReviewCapture.ps1"
$ttwInitializerPath = Join-Path $WorldsRoot "scripts\Initialize-TTWCompatibilityProfile.ps1"
$newVegasInitializerPath = Join-Path $WorldsRoot "scripts\Initialize-OpenNVBaseProfile.ps1"
$oracleSourcePath = if ([string]::IsNullOrWhiteSpace($ParityRoot)) { $null } else {
    Join-Path $ParityRoot "oracles\xnvse\nvse_retail_oracle\main.cpp"
}
$oracleRuntimeManifestPath = if ([string]::IsNullOrWhiteSpace($ParityRoot)) { $null } else {
    Join-Path $ParityRoot "local\xnvse-retail-oracle\oracle-runtime-manifest.json"
}
$oracleDllPath = if ([string]::IsNullOrWhiteSpace($ParityRoot)) { $null } else {
    Join-Path $ParityRoot "local\xnvse-retail-oracle\plugins\nvse_retail_oracle.dll"
}

if ($Scenario -eq 'ActorObservation') {
    function Resolve-ActorPreflightPath([string]$Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
        return [IO.Path]::GetFullPath((Join-Path $WorldsRoot $Path))
    }

    $actorPlanDirectory = Resolve-ActorPreflightPath $ActorPlanRoot
    $actorCorpusDirectory = Resolve-ActorPreflightPath $ActorCorpusRoot
    $actorSeedDirectory = Resolve-ActorPreflightPath $ActorOracleSeedRoot
    $actorPluginPath = Resolve-ActorPreflightPath $ActorOraclePluginDll
    $actorSavePath = Resolve-ActorPreflightPath $ActorSaveFixture
    $actorGameDirectory = Resolve-ActorPreflightPath $ActorGameRoot
    $actorPlanManifestPath = if ($actorPlanDirectory) {
        Join-Path $actorPlanDirectory 'manifest.json'
    } else { '' }
    $actorCorpusManifestPath = if ($actorCorpusDirectory) {
        Join-Path $actorCorpusDirectory 'manifest.json'
    } else { '' }
    $actorJobsPath = if ($actorPlanDirectory) {
        Join-Path $actorPlanDirectory 'capture-jobs.jsonl'
    } else { '' }
    $actorAppearancePath = if ($actorCorpusDirectory) {
        Join-Path $actorCorpusDirectory 'appearance-review.jsonl'
    } else { '' }
    $actorSeedManifestPath = if ($actorSeedDirectory) {
        Join-Path $actorSeedDirectory 'oracle-runtime-manifest.json'
    } else { '' }

    Add-Check 'ActorObservation is restricted to retail' ($Target -eq 'Retail') "target=$Target"
    Add-Check 'ActorObservation CaptureJobKey is canonical' `
        ($ActorCaptureJobKey -match '^[^:]+\.(?:esm|esp):[0-9a-fA-F]{6}$') `
        $ActorCaptureJobKey
    foreach ($tool in @('ffmpeg', 'ffprobe')) {
        $toolCommand = Get-Command $tool -ErrorAction SilentlyContinue | Select-Object -First 1
        Add-Check "ActorObservation tool is available: $tool" ($null -ne $toolCommand) `
            $(if ($null -ne $toolCommand) { $toolCommand.Source } else { 'missing' })
    }
    [void](Test-Directory 'Actor capture plan directory exists' $actorPlanDirectory)
    [void](Test-Directory 'Actor parity corpus directory exists' $actorCorpusDirectory)
    [void](Test-Directory 'Actor oracle seed runtime exists' $actorSeedDirectory)
    [void](Test-Directory 'Retail game root exists' $actorGameDirectory)
    foreach ($file in @($actorObservationRunnerPath, $actorObservationQueuePath,
            $oracleSourcePath, $catalogPath,
            $runbookPath, $entryPointPath, $preflightPath, $actorPlanManifestPath,
            $actorCorpusManifestPath, $actorJobsPath, $actorAppearancePath,
            $actorSeedManifestPath, $actorPluginPath, $actorSavePath,
            $(if ($actorGameDirectory) { Join-Path $actorGameDirectory 'FalloutNV.exe' } else { '' }))) {
        [void](Test-File "ActorObservation input exists: $([IO.Path]::GetFileName($file))" $file)
    }
    foreach ($script in @($entryPointPath, $preflightPath, $actorObservationRunnerPath,
            $actorObservationQueuePath)) {
        if (Test-Path -LiteralPath $script -PathType Leaf) { Test-PowerShellParse $script }
    }
    $actorRunnerText = (Get-Content -Raw -LiteralPath $actorObservationRunnerPath `
        -ErrorAction SilentlyContinue) + [Environment]::NewLine +
        (Get-Content -Raw -LiteralPath $actorObservationQueuePath -ErrorAction SilentlyContinue)
    foreach ($forbidden in @('AppActivate', 'SetForegroundWindow', 'BringWindowToTop',
            'SetFocus', 'SendInput', 'Invoke-FNVRetailJamInput')) {
        Add-Check "ActorObservation runner excludes $forbidden" `
            ($actorRunnerText -notmatch [regex]::Escape($forbidden)) $actorObservationRunnerPath
    }
    Add-Check 'ActorObservation output does not already exist' `
        ([string]::IsNullOrWhiteSpace($OutputRoot) -or -not (Test-Path -LiteralPath $OutputRoot)) `
        $(if ($OutputRoot) { $OutputRoot } else { 'automatic unique output' })

    try {
        $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
        $recipes = @($catalog.actorObservationRecipes | Where-Object {
            [string]$_.id -eq 'fnv-official-actor-retail-observation-v1'
        })
        Add-Check 'ActorObservation recipe is uniquely declared' ($recipes.Count -eq 1) $catalogPath
        if ($recipes.Count -eq 1) {
            Add-Check 'ActorObservation recipe forbids app control and foreground input' `
                (-not [bool]$recipes[0].windowsAppControlUsed -and
                    -not [bool]$recipes[0].foregroundRequired -and
                    -not [bool]$catalog.policy.windowsAppControlAllowed -and
                    -not [bool]$catalog.policy.injectedWindowsInputAllowed) `
                ([string]$recipes[0].captureMethod)
            Add-Check 'ActorObservation recipe declares the canonical queue runner' `
                ([string]$recipes[0].queueRunner -ceq
                    'scripts/Invoke-FNVActorObservationQueue.ps1') `
                ([string]$recipes[0].queueRunner)
            $timeline = @($recipes[0].capturePolicy.shotTimeline)
            $timelineSlots = @($timeline | ForEach-Object { [string]$_.slot })
            $shotFrames = @($timeline | ForEach-Object { @($_.screenshotFrames) })
            $recordTypeMappings = @(
                $recipes[0].capturePolicy.shotKindOverridesByRecordType.PSObject.Properties
            )
            $resolvedShotSets = @($recordTypeMappings | ForEach-Object {
                $mapping = $_
                $resolvedKinds = @($timeline | ForEach-Object {
                    $slot = [string]$_.slot
                    $override = @($mapping.Value.PSObject.Properties | Where-Object {
                        [string]$_.Name -ceq $slot
                    })
                    if ($override.Count -eq 1) { [string]$override[0].Value } else { $slot }
                })
                [pscustomobject]@{ recordType = [string]$mapping.Name; kinds = $resolvedKinds }
            })
            $validResolvedShotSets = @($resolvedShotSets | Where-Object {
                $_.kinds.Count -eq $timeline.Count -and
                @($_.kinds | Sort-Object -Unique).Count -eq $_.kinds.Count
            })
            Add-Check 'ActorObservation recipe declares a unique record-aware shot timeline' `
                ($timeline.Count -gt 0 -and
                    @($timelineSlots | Sort-Object -Unique).Count -eq $timelineSlots.Count -and
                    @($shotFrames | Sort-Object -Unique).Count -eq $shotFrames.Count -and
                    $recordTypeMappings.Count -eq 2 -and
                    ((@($recordTypeMappings.Name | Sort-Object) -join ',') -ceq 'CREA,NPC_') -and
                    $validResolvedShotSets.Count -eq $recordTypeMappings.Count) `
                (($resolvedShotSets | ForEach-Object {
                    "$($_.recordType)=[$($_.kinds -join ',')]"
                }) -join '; ')
            Add-Check 'ActorObservation recipe declares a bounded motion-video policy' `
                (@($resolvedShotSets | Where-Object {
                    @($_.kinds | Where-Object {
                        [string]$_ -ceq [string]$recipes[0].capturePolicy.motionVideo.shotKind
                    }).Count -eq 1
                }).Count -eq $resolvedShotSets.Count -and
                    [int]$recipes[0].capturePolicy.motionVideo.timelineFrameRate -gt 0 -and
                    [int]$recipes[0].capturePolicy.motionVideo.outputFrameRate -gt 0) `
                ([string]$recipes[0].capturePolicy.motionVideo.file)
            $telemetryPolicy = $recipes[0].telemetryPolicy
            Add-Check 'ActorObservation recipe requires frame-bound skeleton, skin-palette, and appearance snapshots' `
                ([string]$telemetryPolicy.visualSnapshotEvent -ceq 'actor-visual-snapshot' -and
                    [string]$telemetryPolicy.visualSnapshotFaultEvent -ceq
                        'actor-visual-snapshot-fault' -and
                    [int]$telemetryPolicy.requiredVisualSnapshotsPerSourceFrame -eq 1 -and
                    [int]$telemetryPolicy.requiredAppearanceSnapshots -eq 1 -and
                    [bool]$telemetryPolicy.requireSkinPalettesForSkinnedGeometry -and
                    [int]$telemetryPolicy.skinPaletteComponentsPerRegister -gt 0 -and
                    [int]$telemetryPolicy.skinPaletteBytesPerComponent -gt 0 -and
                    [int]$telemetryPolicy.skinPaletteMaximumBytesPerShape -gt 0 -and
                    [string]$telemetryPolicy.surfaceContract.event -ceq
                        'actor-surface-contract' -and
                    [string]$telemetryPolicy.surfaceContract.targetTexturesEvent -ceq
                        'actor-draw-contract-target-textures' -and
                    [int]$telemetryPolicy.surfaceContract.renderFrameLead -gt 0 -and
                    [int]$telemetryPolicy.surfaceContract.textureStageCount -gt 0 -and
                    [int]$telemetryPolicy.surfaceContract.textureStageCount -le 16 -and
                    [int]$telemetryPolicy.surfaceContract.maximumShaderBytes -gt 0 -and
                    [int]$telemetryPolicy.surfaceContract.matrixElementCount -eq 16 -and
                    [double]$telemetryPolicy.surfaceContract.matrixTolerance -gt 0 -and
                    [bool]$telemetryPolicy.surfaceContract.requireBackBufferDimensions -and
                    [double]$telemetryPolicy.surfaceContract.normalizedDepthMinimum -lt
                        [double]$telemetryPolicy.surfaceContract.normalizedDepthMaximum -and
                    [string]$telemetryPolicy.drawContractDiagnostic.event -ceq
                        'actor-draw-contract' -and
                    [string]$telemetryPolicy.drawContractDiagnostic.targetTexturesEvent -ceq
                        'actor-draw-contract-target-textures' -and
                    [int]$telemetryPolicy.drawContractDiagnostic.renderFrameLead -gt 0 -and
                    [int]$telemetryPolicy.drawContractDiagnostic.textureStageCount -gt 0 -and
                    [int]$telemetryPolicy.drawContractDiagnostic.textureStageCount -le 16 -and
                    [int]$telemetryPolicy.drawContractDiagnostic.maximumRecordsPerSourceFrame -gt 0 -and
                    [int]$telemetryPolicy.drawContractDiagnostic.vertexShaderRegisterCount -gt 0 -and
                    [int]$telemetryPolicy.drawContractDiagnostic.vertexShaderRegisterCount -le 256 -and
                    [int]$telemetryPolicy.drawContractDiagnostic.maximumShaderBytes -gt 0 -and
                    [int]$telemetryPolicy.drawContractDiagnostic.maximumBufferBytesPerRecord -gt 0 -and
                    [int]$telemetryPolicy.minimumNamedNodesPerSnapshot -gt 0 -and
                    [int]$telemetryPolicy.cameraMatrixElementCount -eq 16 -and
                    [int]$telemetryPolicy.cameraWorldRotationElementCount -eq 9 -and
                    [int]$telemetryPolicy.cameraWorldTranslationElementCount -eq 3 -and
                    [int]$telemetryPolicy.cameraFrustumElementCount -eq 7 -and
                    [int]$telemetryPolicy.cameraViewportElementCount -eq 4 -and
                    [bool]$telemetryPolicy.requireExactPerspectiveProjection -and
                    [int64]$telemetryPolicy.maximumJsonlBytes -gt 0) `
                ([string]$telemetryPolicy.visualSnapshotEvent)
        }
    }
    catch {
        Add-Check 'ActorObservation recipe catalog parses' $false $_.Exception.Message
    }

    try {
        $planManifest = Get-Content -Raw -LiteralPath $actorPlanManifestPath | ConvertFrom-Json
        $corpusManifest = Get-Content -Raw -LiteralPath $actorCorpusManifestPath | ConvertFrom-Json
        Add-Check 'Actor capture plan schema is canonical' `
            ([string]$planManifest.schema -ceq 'opennv-actor-capture-plan/v1') $actorPlanManifestPath
        Add-Check 'Actor parity corpus schema is canonical' `
            ([string]$corpusManifest.schema -ceq 'opennv-actor-parity-corpus/v1') $actorCorpusManifestPath
        Add-Check 'Actor plan is bound to the supplied appearance ledger' `
            ([string]$planManifest.sourceCorpus.appearanceReviewSha256 -ceq
                [string]$corpusManifest.outputs.appearanceReview.sha256) `
            ([string]$planManifest.sourceCorpus.appearanceReviewSha256)
        foreach ($binding in @(
                [pscustomobject]@{ Path = $actorJobsPath; Entry = $planManifest.outputs.jobs; Label = 'capture jobs' },
                [pscustomobject]@{ Path = $actorAppearancePath; Entry = $corpusManifest.outputs.appearanceReview; Label = 'appearance review' }
            )) {
            $actualBytes = if (Test-Path -LiteralPath $binding.Path -PathType Leaf) {
                (Get-Item -LiteralPath $binding.Path).Length
            } else { -1 }
            $actualHash = if ($actualBytes -ge 0) {
                (Get-FileHash -LiteralPath $binding.Path -Algorithm SHA256).Hash.ToLowerInvariant()
            } else { '' }
            Add-Check "ActorObservation $($binding.Label) matches manifest" `
                ($actualBytes -eq [int64]$binding.Entry.bytes -and
                    $actualHash -ceq [string]$binding.Entry.sha256) $binding.Path
        }
        $jobCount = if (Test-Path -LiteralPath $actorJobsPath -PathType Leaf) {
            @([IO.File]::ReadLines($actorJobsPath) | Where-Object {
                $_ -match ('"captureJobKey":"' + [regex]::Escape($ActorCaptureJobKey) + '"')
            }).Count
        } else { 0 }
        Add-Check 'ActorObservation job key resolves exactly once' ($jobCount -eq 1) $ActorCaptureJobKey
    }
    catch {
        Add-Check 'ActorObservation plan and corpus parse' $false $_.Exception.Message
    }

    if ($RuntimeReady -and (Test-Path -LiteralPath $actorSeedManifestPath -PathType Leaf)) {
        try {
            $seedManifest = Get-Content -Raw -LiteralPath $actorSeedManifestPath | ConvertFrom-Json
            foreach ($entryName in @('loader', 'steamLoader', 'core')) {
                $entry = $seedManifest.files.$entryName
                $source = Join-Path $actorSeedDirectory ([string]$entry.path)
                $actualHash = if (Test-Path -LiteralPath $source -PathType Leaf) {
                    (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
                } else { '' }
                Add-Check "ActorObservation seed $entryName matches manifest" `
                    ($actualHash -ceq [string]$entry.sha256) $source
            }
        }
        catch {
            Add-Check 'ActorObservation seed runtime manifest parses' $false $_.Exception.Message
        }
    }
    if ($RequireIdle) {
        $active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match '^(FalloutNV|nvse_loader|openmw|Godot.*)$'
        })
        Add-Check 'ActorObservation capture engines are idle' ($active.Count -eq 0) `
            $(if ($active.Count -eq 0) { 'idle' } else { ($active.ProcessName -join ', ') })
    }
    $failed = @($checks | Where-Object { -not $_.passed })
    $result = [pscustomobject][ordered]@{
        schema = 'nikami-fnv-jam-background-capture-preflight/v1'
        status = if ($failed.Count -eq 0) { 'pass' } else { 'fail' }
        target = $Target
        scenario = $Scenario
        runtimeReadyChecked = [bool]$RuntimeReady
        idleChecked = [bool]$RequireIdle
        passedChecks = $checks.Count - $failed.Count
        failedChecks = $failed.Count
        checks = @($checks)
    }
    $result
    if ($failed.Count -ne 0) {
        throw "ActorObservation background-capture preflight failed $($failed.Count) check(s): " +
            (($failed | ForEach-Object name) -join '; ')
    }
    return
}

if ($Scenario -eq 'GodotActorReview') {
    $openNvDirectory = if ([string]::IsNullOrWhiteSpace($OpenNvRoot)) { '' } else {
        [IO.Path]::GetFullPath($OpenNvRoot)
    }
    $reviewScenePath = if ([string]::IsNullOrWhiteSpace($ActorReviewScene)) { '' } else {
        [IO.Path]::GetFullPath($ActorReviewScene)
    }
    $runtimeProjectPath = if ($openNvDirectory) {
        Join-Path $openNvDirectory 'runtime\project.godot'
    } else { '' }
    $runtimeProjectFile = if ($openNvDirectory) {
        Join-Path $openNvDirectory 'runtime\OpenNV.csproj'
    } else { '' }
    $GodotBinary = Resolve-NikamiPath `
        -ParameterValue $GodotBinary `
        -EnvName 'NIKAMI_GODOT_BINARY' `
        -ConfigName 'godotBinary'
    if ([string]::IsNullOrWhiteSpace($GodotBinary)) {
        $godotCommand = Get-Command godot4, godot -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $godotCommand) { $GodotBinary = $godotCommand.Source }
    }

    Add-Check 'GodotActorReview is restricted to Godot' ($Target -eq 'Godot') "target=$Target"
    [void](Test-Directory 'OpenNV checkout exists' $openNvDirectory)
    foreach ($path in @($actorReviewRunnerPath, $runtimeProjectPath, $runtimeProjectFile,
            $reviewScenePath, $catalogPath, $runbookPath, $entryPointPath, $preflightPath)) {
        [void](Test-File "GodotActorReview input exists: $([IO.Path]::GetFileName($path))" $path)
    }
    Add-Check 'GodotActorReview output does not already exist' `
        ([string]::IsNullOrWhiteSpace($OutputRoot) -or -not (Test-Path -LiteralPath $OutputRoot)) `
        $(if ($OutputRoot) { $OutputRoot } else { 'automatic unique output' })
    foreach ($script in @($entryPointPath, $preflightPath, $actorReviewRunnerPath)) {
        if (Test-Path -LiteralPath $script -PathType Leaf) { Test-PowerShellParse $script }
    }
    $runnerText = Get-Content -Raw -LiteralPath $actorReviewRunnerPath -ErrorAction SilentlyContinue
    foreach ($forbidden in @('AppActivate', 'SetForegroundWindow', 'BringWindowToTop',
            'SetFocus', 'SendInput', 'Computer Use')) {
        Add-Check "GodotActorReview runner excludes $forbidden" `
            ($runnerText -notmatch [regex]::Escape($forbidden)) $actorReviewRunnerPath
    }
    Add-Check 'GodotActorReview uses engine-owned viewport capture' `
        ($runnerText -match 'Godot engine-owned viewport PNGs' -and
            $runnerText -match '--actor-review-scene' -and
            $runnerText -match '--capture-root') `
        $actorReviewRunnerPath
    try {
        $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
        $recipes = @($catalog.actorObservationRecipes | Where-Object {
            [string]$_.id -eq 'opennv-godot-owned-actor-review-v1'
        })
        Add-Check 'GodotActorReview recipe is uniquely declared' ($recipes.Count -eq 1) $catalogPath
        if ($recipes.Count -eq 1) {
            Add-Check 'GodotActorReview recipe forbids app control and parity claims' `
                (-not [bool]$recipes[0].windowsAppControlUsed -and
                    -not [bool]$recipes[0].foregroundRequired -and
                    [string]$recipes[0].acceptedCaptureStatus -ceq 'captured-pending-parity') `
                ([string]$recipes[0].captureMethod)
        }
    }
    catch {
        Add-Check 'GodotActorReview recipe catalog parses' $false $_.Exception.Message
    }
    try {
        $scene = Get-Content -Raw -LiteralPath $reviewScenePath | ConvertFrom-Json
        Add-Check 'GodotActorReview scene is a compiled pending owned-data actor' `
            ([string]$scene.schema -ceq 'opennv-actor-review-scene/v1' -and
                [string]$scene.status -ceq
                    'compiled-retail-observed-pending-godot-capture' -and
                [string]$scene.recordType -cin @('NPC_', 'CREA')) `
            ([string]$scene.reviewKey)
        $contractPath = [IO.Path]::GetFullPath([string]$scene.retailContract.path)
        $contractHash = if (Test-Path -LiteralPath $contractPath -PathType Leaf) {
            (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant()
        } else { '' }
        Add-Check 'GodotActorReview retail contract matches its scene binding' `
            ($contractHash -cne '' -and $contractHash -ceq [string]$scene.retailContract.sha256) `
            $contractPath
        if ($contractHash -cne '') {
            $contract = Get-Content -Raw -LiteralPath $contractPath | ConvertFrom-Json
            $shots = @($contract.retail.shots)
            $samples = @($shots | ForEach-Object { @($_.samples) })
            Add-Check 'GodotActorReview requires exact per-frame retail final-eye and skin-palette evidence' `
                ([string]$contract.schema -ceq 'opennv-actor-review-contract/v4' -and
                    [string]$scene.retailContract.projectionStatus -ceq
                        'exact-retail-final-eye-d3d9-perspective' -and
                    $shots.Count -gt 0 -and $samples.Count -gt 0 -and
                    @($shots | Where-Object {
                        -not [bool]$_.projection.exact -or
                        [string]$_.projection.status -cne
                            'exact-retail-final-eye-d3d9-perspective'
                    }).Count -eq 0 -and
                    @($samples | Where-Object {
                        $null -eq $_.camera -or
                        [string]$_.camera.eventSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                        @($_.camera.frustum).Count -ne 7 -or
                        @($_.camera.viewport).Count -ne 4 -or
                        @($_.camera.worldToClipMatrix).Count -ne 16 -or
                        @($_.camera.projectionMatrix).Count -ne 16 -or
                        @($_.camera.world.rotation).Count -ne 9 -or
                        @($_.camera.world.translation).Count -ne 3 -or
                        [double]$_.camera.fovYRadians -le 0 -or
                        $null -eq $_.camera.surfaceContract -or
                        [string]$_.camera.surfaceContract.eventSha256 -cnotmatch
                            '^[0-9a-f]{64}$' -or
                        -not [bool]$_.camera.surfaceContract.renderTarget.matchesBackBufferDimensions -or
                        @($_.camera.surfaceContract.frustum).Count -ne 7 -or
                        @($_.camera.surfaceContract.worldMatrix).Count -ne 16 -or
                        @($_.camera.surfaceContract.viewMatrix).Count -ne 16 -or
                        @($_.camera.surfaceContract.projectionMatrix).Count -ne 16 -or
                        @($_.camera.surfaceContract.worldToClipMatrix).Count -ne 16 -or
                        $null -eq $_.camera.cullingObservation -or
                        @($_.camera.cullingObservation.frustum).Count -ne 7 -or
                        @($_.camera.cullingObservation.projectionMatrix).Count -ne 16 -or
                        [string]$_.skinPalette.finalProjectionEventSha256 -cne
                            [string]$_.camera.surfaceContract.eventSha256 -or
                        -not [bool]$_.skinPalette.frameBoundToSourceBackbuffer -or
                        [int]$_.skinPalette.summary.capturedPalettes -le 0 -or
                        [int]$_.skinPalette.summary.invalidPalettes -ne 0 -or
                        [bool]$_.skinPalette.summary.traversalTruncated -or
                        @($_.skinPalette.instances | Where-Object {
                            [string]$_.status -ceq 'captured'
                        }).Count -ne [int]$_.skinPalette.summary.capturedPalettes
                    }).Count -eq 0) `
                $contractPath
        }
    }
    catch {
        Add-Check 'GodotActorReview scene parses' $false $_.Exception.Message
    }
    if ($RuntimeReady) {
        [void](Test-File 'Godot .NET executable exists' $GodotBinary)
        Add-Check 'dotnet is available' ($null -ne (Get-Command dotnet -ErrorAction SilentlyContinue)) `
            'dotnet'
    }
    if ($RequireIdle) {
        $active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match '^(Godot.*|openmw|FalloutNV|nvse_loader)$'
        })
        Add-Check 'GodotActorReview capture engines are idle' ($active.Count -eq 0) `
            $(if ($active.Count -eq 0) { 'idle' } else { ($active.ProcessName -join ', ') })
    }
    $passed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
    $result = [ordered]@{
        schema = 'nikami-fnv-jam-background-capture-preflight/v1'
        passed = $passed
        target = $Target
        scenario = $Scenario
        runtimeReadyChecked = [bool]$RuntimeReady
        idleChecked = [bool]$RequireIdle
        checks = @($checks)
    }
    $result | ConvertTo-Json -Depth 8
    if (-not $passed) { throw 'GodotActorReview background-capture preflight failed.' }
    return
}

if ($Scenario -in @("GodotRoute", "GodotCinematics", "GodotPortraits")) {
	$isCinematic = $Scenario -eq "GodotCinematics"
	$isPortrait = $Scenario -eq "GodotPortraits"
	$godotRunnerPath = Join-Path $WorldsRoot $(if ($isPortrait) { "scripts\Invoke-OpenNVFamousPeopleCapture.ps1" } elseif ($isCinematic) { "scripts\Invoke-OpenNVCinematicReelCapture.ps1" } else { "scripts\Invoke-OpenNVGodotShowcaseCapture.ps1" })
    $godotProjectPath = Join-Path $WorldsRoot "godot-fnv\project.godot"
	$godotRoutePath = Join-Path $WorldsRoot $(if ($isCinematic -or $isPortrait) { "godot-fnv\generated\cinematics\scene-pack.json" } else { "godot-fnv\generated\world\goodsprings-strip-road-route.json" })
    $godotActorManifestPath = Join-Path $WorldsRoot "godot-fnv\generated\actors\goodsprings-strip-dense-road-v1\actor-manifest.json"
    $GodotBinary = Resolve-NikamiPath `
        -ParameterValue $GodotBinary `
        -EnvName "NIKAMI_GODOT_BINARY" `
        -ConfigName "godotBinary"
    if ([string]::IsNullOrWhiteSpace($GodotBinary)) {
        $godotCommand = Get-Command godot4, godot -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $godotCommand) {
            $GodotBinary = $godotCommand.Source
        }
    }
    foreach ($path in @($catalogPath, $runbookPath, $entryPointPath, $preflightPath,
        $godotRunnerPath, $godotProjectPath, $godotRoutePath, $godotActorManifestPath)) {
        [void](Test-File "Canonical Godot route input exists: $([IO.Path]::GetFileName($path))" $path)
    }
    Test-PowerShellParse $entryPointPath
    Test-PowerShellParse $preflightPath
    Test-PowerShellParse $godotRunnerPath
    try {
        $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
		$recipeId = if ($isPortrait) { 'opennv-godot-famous-people-v1' } elseif ($isCinematic) { 'opennv-godot-four-scenes-60fps-v1' } else { 'opennv-godot-goodsprings-strip-v1' }
        $recipe = @($catalog.godotRecipes | Where-Object id -eq $recipeId)
        Add-Check "Godot route recipe is uniquely declared" ($recipe.Count -eq 1) $catalogPath
        if ($recipe.Count -eq 1) {
            Add-Check "Godot route recipe forbids Windows app control" `
                (-not [bool]$recipe[0].windowsAppControlUsed -and -not [bool]$catalog.policy.windowsAppControlAllowed) `
                ([string]$recipe[0].captureMethod)
        }
    }
    catch {
        Add-Check "Godot route recipe catalog parses" $false $_.Exception.Message
    }
    $runnerText = Get-Content -Raw -LiteralPath $godotRunnerPath -ErrorAction SilentlyContinue
    $forbidden = @('AppActivate', 'SetForegroundWindow', 'BringWindowToTop', 'SetFocus', 'SendInput', 'Computer Use')
    Add-Check "Godot route runner contains no forbidden app-control mechanism" `
        (@($forbidden | Where-Object { $runnerText -match [regex]::Escape($_) }).Count -eq 0) $godotRunnerPath
	$driverDeclared = if ($isPortrait) {
		$runnerText -match 'FNV_GODOT_PORTRAIT_REEL' -and $runnerText -match 'native-source-frames'
	} elseif ($isCinematic) {
        $runnerText -match 'FNV_GODOT_CINEMATIC_REEL' -and $runnerText -match "'60'" -and
            $runnerText -match '--write-movie' -and $runnerText -match '--fixed-fps'
    } else {
        $runnerText -match 'FNV_GODOT_SELF_DRIVE' -and $runnerText -match 'FNV_GODOT_LONG_ROUTE'
    }
	$captureBoundaryDeclared = if ($isPortrait) { $runnerText -match 'Godot-native framebuffer portraits' } elseif ($isCinematic) { $runnerText -match 'Godot native fixed-step 60 FPS movie writer' } else {
        $runnerText -match 'MainWindowTitle' -and $runnerText -match 'MainWindowHandle' -and $runnerText -match 'hwnd=0x'
    }
    Add-Check "Godot route uses its declared native capture boundary" `
        ($driverDeclared -and $captureBoundaryDeclared) $godotRunnerPath
    if ($RuntimeReady) {
        [void](Test-File "Godot executable exists" $GodotBinary)
        Add-Check "ffmpeg is available" ($null -ne (Get-Command ffmpeg -ErrorAction SilentlyContinue)) "ffmpeg"
        Add-Check "ffprobe is available" ($null -ne (Get-Command ffprobe -ErrorAction SilentlyContinue)) "ffprobe"
    }
    if ($RequireIdle) {
        $active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match '^(Godot.*|openmw|FalloutNV|nvse_loader)$'
        })
        Add-Check "Godot route capture engines are idle" ($active.Count -eq 0) `
            ($(if ($active.Count -eq 0) { 'idle' } else { ($active.ProcessName -join ', ') }))
    }
    $passed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
    $result = [ordered]@{
        schema = 'nikami-fnv-jam-background-capture-preflight/v1'
        passed = $passed
        target = $Target
        scenario = $Scenario
        runtimeReadyChecked = [bool]$RuntimeReady
        idleChecked = [bool]$RequireIdle
        checks = @($checks)
    }
    $result | ConvertTo-Json -Depth 8
    if (-not $passed) { throw 'Godot route background-capture preflight failed.' }
    return
}

$canonicalFiles = [Collections.Generic.List[string]]::new()
foreach ($path in @($catalogPath, $runbookPath, $entryPointPath, $preflightPath)) {
    $canonicalFiles.Add($path)
}
if ($Scenario -eq "Jam") {
    foreach ($path in @($retailRunnerPath, $openMwRunnerPath, $oracleSourcePath)) {
        $canonicalFiles.Add($path)
    }
}
elseif ($Scenario -eq "Opening") {
    $openingFiles = [Collections.Generic.List[string]]::new()
    if ($Target -in @("All", "Retail")) {
        foreach ($path in @($retailOpeningRunnerPath, $retailTtwLayerInitializerPath, $oracleSourcePath)) {
            $openingFiles.Add($path)
        }
    }
    if ($Target -in @("All", "OpenMW")) {
        $openingInitializerPath = if ($OpeningCampaign -eq "TTW") {
            $ttwInitializerPath
        } else {
            $newVegasInitializerPath
        }
        foreach ($path in @($openingRunnerPath, $openingInitializerPath)) {
            $openingFiles.Add($path)
        }
    }
    foreach ($path in $openingFiles) {
        $canonicalFiles.Add($path)
    }
}
elseif ($Scenario -eq "PipBoy") {
    if ($Target -in @("All", "Retail")) {
        foreach ($path in @($retailPipBoyRunnerPath, $oracleSourcePath)) {
            $canonicalFiles.Add($path)
        }
    }
    if ($Target -in @("All", "OpenMW")) {
        foreach ($path in @($pipBoyRunnerPath, $newVegasInitializerPath)) {
            $canonicalFiles.Add($path)
        }
    }
}
elseif ($Scenario -eq "PipBoyVR") {
    foreach ($path in @($pipBoyVrRunnerPath, $vrStartRunnerPath, $vrHeadPosePath, $vrControllerPosePath, $vrNativeFramePath)) {
        $canonicalFiles.Add($path)
    }
}
elseif ($Scenario -eq "Terminal") {
    foreach ($path in @($terminalRunnerPath, $newVegasInitializerPath)) {
        $canonicalFiles.Add($path)
    }
}
elseif ($Scenario -eq "RealSave") {
    $canonicalFiles.Add($realSaveRunnerPath)
    if ($Target -eq "Retail") {
        $canonicalFiles.Add($oracleSourcePath)
    }
    if ($Target -eq "OpenMW") {
        $canonicalFiles.Add($newVegasInitializerPath)
    }
}
elseif ($Scenario -eq "FirstSmoke") {
    $canonicalFiles.Add($firstSmokeRunnerPath)
}
elseif ($Scenario -eq "ChetObservation") {
    $canonicalFiles.Add($firstSmokeRunnerPath)
}
elseif ($Scenario -eq "ChetPersistent") {
    $canonicalFiles.Add($firstSmokeRunnerPath)
}
elseif ($Scenario -eq "ChetPersistence") {
    $canonicalFiles.Add($firstSmokeRunnerPath)
}
elseif ($Scenario -eq "Canyon") {
    $canonicalFiles.Add($canyonRunnerPath)
}
else {
    $canonicalFiles.Add($testMapRunnerPath)
}
foreach ($path in $canonicalFiles) {
    [void](Test-File "Canonical file exists: $([IO.Path]::GetFileName($path))" $path)
}

$catalog = $null
try {
    $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
    Add-Check "Recipe catalog parses" $true $catalogPath
}
catch {
    Add-Check "Recipe catalog parses" $false $_.Exception.Message
}

if ($null -ne $catalog) {
    Add-Check "Recipe schema is canonical" `
        ($catalog.schema -eq "nikami-fnv-jam-background-capture-recipes/v1" -and
            $catalog.status -eq "canonical") `
        "$($catalog.schema); status=$($catalog.status)"
    Add-Check "Windows app control forbidden" `
        (-not [bool]$catalog.policy.windowsAppControlAllowed) `
        "windowsAppControlAllowed=$($catalog.policy.windowsAppControlAllowed)"
    Add-Check "Foreground activation forbidden" `
        (-not [bool]$catalog.policy.foregroundActivationAllowed) `
        "foregroundActivationAllowed=$($catalog.policy.foregroundActivationAllowed)"
    Add-Check "Injected Windows input forbidden" `
        (-not [bool]$catalog.policy.injectedWindowsInputAllowed) `
        "injectedWindowsInputAllowed=$($catalog.policy.injectedWindowsInputAllowed)"
    if ($Scenario -eq "TestMap") {
        Add-Check "TestMap diagnostic is restricted to OpenMW" `
            ($Target -eq "OpenMW") "target=$Target"
    }
    if ($Scenario -eq "PipBoy") {
        Add-Check "Pip-Boy capture selects one engine" `
            ($Target -in @("Retail", "OpenMW")) "target=$Target"
    }
    if ($Scenario -eq "PipBoyVR") {
        Add-Check "PipBoyVR capture is restricted to OpenMW" `
            ($Target -eq "OpenMW") "target=$Target"
        $pipBoyVrRunnerText = Get-Content -Raw -LiteralPath $pipBoyVrRunnerPath -ErrorAction SilentlyContinue
        foreach ($forbidden in @("AppActivate", "SetForegroundWindow", "BringWindowToTop", "SetFocus", "SendInput")) {
            Add-Check "PipBoyVR runner excludes $forbidden" `
                ($pipBoyVrRunnerText -notmatch [regex]::Escape($forbidden)) $pipBoyVrRunnerPath
        }
        Add-Check "PipBoyVR runner declares native OpenXR capture and retained telemetry" `
            ($pipBoyVrRunnerText -match 'projection-eye native frame API' -and
                $pipBoyVrRunnerText -match 'sourceFramesRetained = \$true' -and
                $pipBoyVrRunnerText -match 'telemetryRetained = \$true' -and
                $pipBoyVrRunnerText -match 'windowsAppControlUsed = \$false' -and
                $pipBoyVrRunnerText -match 'foregroundInputInjected = \$false') $pipBoyVrRunnerPath
    }
    if ($Scenario -eq "FirstSmoke") {
        Add-Check "FirstSmoke is restricted to OpenMW" ($Target -eq "OpenMW") "target=$Target"
        [void](Test-File "FirstSmoke native save exists" $SavePath)
        [void](Test-File "FirstSmoke runtime manifest exists" (Join-Path $OpeningRuntimeRoot "runtime-manifest.json"))
        $firstSmokeText = Get-Content -Raw -LiteralPath $firstSmokeRunnerPath -ErrorAction SilentlyContinue
        foreach ($forbidden in @("AppActivate", "SetForegroundWindow", "BringWindowToTop", "SetFocus", "SendInput")) {
            Add-Check "FirstSmoke runner excludes $forbidden" `
                ($firstSmokeText -notmatch [regex]::Escape($forbidden)) $firstSmokeRunnerPath
        }
        Add-Check "FirstSmoke runner declares engine-owned no-control capture" `
            ($firstSmokeText -match 'OPENMW_FNV_FIRST_SMOKE' -and
                $firstSmokeText -match 'windowsAppControlUsed = \$false' -and
                $firstSmokeText -match 'foregroundInputInjected = \$false') $firstSmokeRunnerPath
    }
    if ($Scenario -eq "ChetObservation") {
        Add-Check "ChetObservation is restricted to OpenMW" ($Target -eq "OpenMW") "target=$Target"
        [void](Test-File "ChetObservation native save exists" $SavePath)
        [void](Test-File "ChetObservation candidate runtime manifest exists" (Join-Path $OpeningRuntimeRoot "candidate-runtime-manifest.json"))
        $chetRunnerText = Get-Content -Raw -LiteralPath $firstSmokeRunnerPath -ErrorAction SilentlyContinue
        foreach ($forbidden in @("AppActivate", "SetForegroundWindow", "BringWindowToTop", "SetFocus", "SendInput")) {
            Add-Check "ChetObservation runner excludes $forbidden" `
                ($chetRunnerText -notmatch [regex]::Escape($forbidden)) $firstSmokeRunnerPath
        }
        Add-Check "ChetObservation runner declares engine-owned no-control capture" `
            ($chetRunnerText -match 'OPENMW_FNV_R2_CHET_OBSERVATION' -and
                $chetRunnerText -match 'windowsAppControlUsed = \$false' -and
                $chetRunnerText -match 'foregroundInputInjected = \$false') $firstSmokeRunnerPath
    }
    if ($Scenario -eq "ChetPersistent") {
        Add-Check "ChetPersistent is restricted to OpenMW" ($Target -eq "OpenMW") "target=$Target"
        [void](Test-File "ChetPersistent native save exists" $SavePath)
        [void](Test-File "ChetPersistent candidate runtime manifest exists" (Join-Path $OpeningRuntimeRoot "candidate-runtime-manifest.json"))
        $chetPersistentRunnerText = Get-Content -Raw -LiteralPath $firstSmokeRunnerPath -ErrorAction SilentlyContinue
        foreach ($forbidden in @("AppActivate", "SetForegroundWindow", "BringWindowToTop", "SetFocus", "SendInput")) {
            Add-Check "ChetPersistent runner excludes $forbidden" `
                ($chetPersistentRunnerText -notmatch [regex]::Escape($forbidden)) $firstSmokeRunnerPath
        }
        Add-Check "ChetPersistent runner declares engine-owned no-control capture" `
            ($chetPersistentRunnerText -match 'OPENMW_FNV_R2_GOODSPRINGS_PERSISTENT' -and
                $chetPersistentRunnerText -match 'windowsAppControlUsed = \$false' -and
                $chetPersistentRunnerText -match 'foregroundInputInjected = \$false') $firstSmokeRunnerPath
    }
    if ($Scenario -eq "ChetTransaction") {
        Add-Check "ChetTransaction is restricted to OpenMW" ($Target -eq "OpenMW") "target=$Target"
        [void](Test-File "ChetTransaction native save exists" $SavePath)
        [void](Test-File "ChetTransaction candidate runtime manifest exists" (Join-Path $OpeningRuntimeRoot "candidate-runtime-manifest.json"))
        $chetTransactionRunnerText = Get-Content -Raw -LiteralPath $firstSmokeRunnerPath -ErrorAction SilentlyContinue
        foreach ($forbidden in @("AppActivate", "SetForegroundWindow", "BringWindowToTop", "SetFocus", "SendInput")) {
            Add-Check "ChetTransaction runner excludes $forbidden" `
                ($chetTransactionRunnerText -notmatch [regex]::Escape($forbidden)) $firstSmokeRunnerPath
        }
        Add-Check "ChetTransaction runner declares engine-owned no-control capture" `
            ($chetTransactionRunnerText -match 'OPENMW_FNV_R2_GOODSPRINGS_TRANSACTION' -and
                $chetTransactionRunnerText -match 'windowsAppControlUsed = \$false' -and
                $chetTransactionRunnerText -match 'foregroundInputInjected = \$false') $firstSmokeRunnerPath
    }
    if ($Scenario -eq "ChetPersistence") {
        Add-Check "ChetPersistence is restricted to OpenMW" ($Target -eq "OpenMW") "target=$Target"
        [void](Test-File "ChetPersistence native save exists" $SavePath)
        [void](Test-File "ChetPersistence candidate runtime manifest exists" (Join-Path $OpeningRuntimeRoot "candidate-runtime-manifest.json"))
        $chetPersistenceRunnerText = Get-Content -Raw -LiteralPath $firstSmokeRunnerPath -ErrorAction SilentlyContinue
        foreach ($forbidden in @("AppActivate", "SetForegroundWindow", "BringWindowToTop", "SetFocus", "SendInput")) {
            Add-Check "ChetPersistence runner excludes $forbidden" `
                ($chetPersistenceRunnerText -notmatch [regex]::Escape($forbidden)) $firstSmokeRunnerPath
        }
        Add-Check "ChetPersistence runner declares production save and cold reload" `
            ($chetPersistenceRunnerText -match 'OPENMW_FNV_R2_GOODSPRINGS_PERSISTENCE_SAVE' -and
                $chetPersistenceRunnerText -match 'OPENMW_FNV_R2_GOODSPRINGS_PERSISTENCE_RELOAD' -and
                $chetPersistenceRunnerText -match 'windowsAppControlUsed = \$false') $firstSmokeRunnerPath
    }
    if ($Scenario -eq "Canyon") {
        Add-Check "Canyon is restricted to OpenMW" ($Target -eq "OpenMW") "target=$Target"
        [void](Test-File "Canyon runtime manifest exists" (Join-Path $OpeningRuntimeRoot "runtime-manifest.json"))
        $canyonText = Get-Content -Raw -LiteralPath $canyonRunnerPath -ErrorAction SilentlyContinue
        foreach ($forbidden in @("AppActivate", "SetForegroundWindow", "BringWindowToTop", "SetFocus", "SendInput")) {
            Add-Check "Canyon runner excludes $forbidden" `
                ($canyonText -notmatch [regex]::Escape($forbidden)) $canyonRunnerPath
        }
        Add-Check "Canyon runner uses authored Zion NPC and no-control evidence" `
            ($canyonText -match 'NVDLC02ZionCanyon' -and $canyonText -match 'NVDLC02Joshua' -and
                $canyonText -match 'forcedActorsUsed=\$false' -and
                $canyonText -match 'foregroundInputInjected=\$false') $canyonRunnerPath
    }
    if ($Scenario -eq "Terminal") {
        Add-Check "Terminal capture is restricted to OpenMW" `
            ($Target -eq "OpenMW") "target=$Target"
    }
    $selectedRecipes = @($(if ($Scenario -eq "Jam") { $catalog.recipes } elseif ($Scenario -eq "Opening") {
        @($catalog.openingRecipes | Where-Object {
            ($Target -eq "All" -or $_.target -eq $Target) -and
            ((-not $_.PSObject.Properties.Match("campaign")) -or [string]$_.campaign -eq $OpeningCampaign)
        })
    } elseif ($Scenario -eq "PipBoy") {
        @($catalog.showcaseRecipes | Where-Object {
            $_.target -eq $Target -and [string]$_.id -ne 'opennv-vr-pipboy-weapons-native-v1'
        })
    } elseif ($Scenario -eq "PipBoyVR") {
        @($catalog.showcaseRecipes | Where-Object {
            $_.target -eq $Target -and [string]$_.id -eq 'opennv-vr-pipboy-weapons-native-v1'
        })
    } elseif ($Scenario -eq "Terminal") {
        @($catalog.terminalRecipes | Where-Object { $_.target -eq $Target })
    } elseif ($Scenario -eq "RealSave") {
        @($catalog.realSaveRecipes | Where-Object {
            $_.target -eq $Target
        })
    } elseif ($Scenario -eq "FirstSmoke") {
        @($catalog.firstSmokeRecipes | Where-Object { $_.target -eq $Target })
    } elseif ($Scenario -eq "ChetObservation") {
        @($catalog.r2ChetRecipes | Where-Object { $_.target -eq $Target })
    } elseif ($Scenario -eq "ChetPersistent") {
        @($catalog.r2PersistentRecipes | Where-Object { $_.target -eq $Target })
    } elseif ($Scenario -eq "ChetTransaction") {
        @($catalog.r2TransactionRecipes | Where-Object { $_.target -eq $Target })
    } elseif ($Scenario -eq "ChetPersistence") {
        @($catalog.r2PersistenceRecipes | Where-Object { $_.target -eq $Target })
    } elseif ($Scenario -eq "Canyon") {
        @($catalog.canyonRecipes | Where-Object { $_.target -eq $Target })
    } else {
        @($catalog.diagnosticRecipes | Where-Object {
            [string]$_.id -eq "opennv-testmap01-clean-native-v1" -and $_.target -eq $Target
        })
    }))
    $expectedRecipeCount = if ($Scenario -eq "Jam") {
        2
    }
    elseif ($Scenario -eq "TestMap") {
        if ($Target -eq "OpenMW") { 1 } else { 0 }
    }
    elseif ($Scenario -eq "PipBoy") {
        if ($Target -in @("Retail", "OpenMW")) { 1 } else { 0 }
    }
    elseif ($Scenario -eq "PipBoyVR") {
        if ($Target -eq "OpenMW") { 1 } else { 0 }
    }
    elseif ($Scenario -eq "Terminal") {
        if ($Target -eq "OpenMW") { 1 } else { 0 }
    }
    elseif ($Scenario -eq "RealSave") {
        if ($Target -eq "OpenMW") { 2 } elseif ($Target -eq "Retail") { 1 } else { 0 }
    }
    elseif ($Scenario -eq "FirstSmoke") {
        if ($Target -eq "OpenMW") { 1 } else { 0 }
    }
    elseif ($Scenario -eq "ChetObservation") {
        if ($Target -eq "OpenMW") { 1 } else { 0 }
    }
    elseif ($Scenario -eq "ChetPersistent") {
        if ($Target -eq "OpenMW") { 1 } else { 0 }
    }
    elseif ($Scenario -eq "ChetTransaction") {
        if ($Target -eq "OpenMW") { 1 } else { 0 }
    }
    elseif ($Scenario -eq "ChetPersistence") {
        if ($Target -eq "OpenMW") { 1 } else { 0 }
    }
    elseif ($Scenario -eq "Canyon") {
        if ($Target -eq "OpenMW") { 1 } else { 0 }
    }
    elseif ($OpeningCampaign -eq "NewVegas") {
        # Standalone New Vegas has both the ordinary authored opening proof and
        # the longer, manifest-routed Vit-o-matic/SPECIAL proof. Retail is not
        # a supported standalone-New-Vegas opening target.
        if ($Target -eq "Retail") { 0 } else { 2 }
    }
    elseif ($Target -eq "All") {
        2
    }
    elseif ($Scenario -eq "Opening") {
        1
    }
    Add-Check "$Scenario scenario declares the expected canonical recipe count" `
        ($selectedRecipes.Count -eq $expectedRecipeCount) `
        (($selectedRecipes | ForEach-Object id) -join ", ")
    foreach ($recipe in $selectedRecipes) {
        $runnerPath = Join-Path $WorldsRoot ([string]$recipe.runner)
        Add-Check "$Scenario recipe runner exists: $($recipe.id)" `
            (Test-Path -LiteralPath $runnerPath -PathType Leaf) $runnerPath
        Add-Check "$Scenario recipe names a capture method: $($recipe.id)" `
            (-not [string]::IsNullOrWhiteSpace([string]$recipe.captureMethod)) `
            ([string]$recipe.captureMethod)
    }

    if ($Scenario -eq "Jam") {
        foreach ($anchor in $catalog.knownGoodEvidence.PSObject.Properties) {
            $anchorRoot = Join-Path $WorldsRoot ([string]$anchor.Value)
            $anchorExists = Test-Path -LiteralPath $anchorRoot -PathType Container
            Add-Check "Known-good anchor exists: $($anchor.Name)" `
                $anchorExists $anchorRoot
            if ($anchorExists) {
                $anchorSummaryName = if ($anchor.Name -eq "sideBySide") {
                    "side-by-side-proof-manifest.json"
                } else {
                    "background-capture-summary.json"
                }
                $anchorSummary = Join-Path $anchorRoot $anchorSummaryName
                $summaryExists = Test-Path -LiteralPath $anchorSummary -PathType Leaf
                Add-Check "Known-good anchor has canonical summary: $($anchor.Name)" `
                    $summaryExists $anchorSummary
                if ($summaryExists) {
                    try {
                        $knownGood =
                            Get-Content -Raw -LiteralPath $anchorSummary |
                            ConvertFrom-Json
                        $knownGoodPolicy = if ($anchor.Name -eq "sideBySide") {
                            $knownGood.capturePolicy
                        } else {
                            $knownGood.policy
                        }
                        $policyPassed = $knownGood.status -eq "pass" -and
                            -not [bool]$knownGoodPolicy.windowsAppControlUsed -and
                            -not [bool]$knownGoodPolicy.foregroundActivationUsed -and
                            -not [bool]$knownGoodPolicy.foregroundInputInjected
                        Add-Check "Known-good anchor passes no-control policy: $($anchor.Name)" `
                            $policyPassed $anchorSummary
                    }
                    catch {
                        Add-Check "Known-good anchor passes no-control policy: $($anchor.Name)" `
                            $false $_.Exception.Message
                    }
                }
            }
        }
    }
}

 $scriptsToParse = [Collections.Generic.List[string]]::new()
foreach ($script in @($entryPointPath, $preflightPath)) {
    $scriptsToParse.Add($script)
}
if ($Scenario -eq "Jam") {
    foreach ($script in @($retailRunnerPath, $openMwRunnerPath)) { $scriptsToParse.Add($script) }
}
elseif ($Scenario -eq "Opening") {
    if ($Target -in @("All", "Retail")) {
        foreach ($script in @($retailOpeningRunnerPath, $retailTtwLayerInitializerPath)) { $scriptsToParse.Add($script) }
    }
    if ($Target -in @("All", "OpenMW")) {
        foreach ($script in @($openingRunnerPath, $ttwInitializerPath)) { $scriptsToParse.Add($script) }
    }
}
elseif ($Scenario -eq "PipBoy") {
    if ($Target -eq "Retail") { $scriptsToParse.Add($retailPipBoyRunnerPath) }
    else { $scriptsToParse.Add($pipBoyRunnerPath) }
}
elseif ($Scenario -eq "PipBoyVR") {
    foreach ($script in @($pipBoyVrRunnerPath, $vrStartRunnerPath, $vrHeadPosePath, $vrControllerPosePath, $vrNativeFramePath)) {
        $scriptsToParse.Add($script)
    }
}
elseif ($Scenario -eq "Terminal") {
    $scriptsToParse.Add($terminalRunnerPath)
}
elseif ($Scenario -eq "RealSave") {
    $scriptsToParse.Add($realSaveRunnerPath)
}
elseif ($Scenario -eq "FirstSmoke") {
    $scriptsToParse.Add($firstSmokeRunnerPath)
}
elseif ($Scenario -eq "ChetPersistent") {
    $scriptsToParse.Add($firstSmokeRunnerPath)
}
elseif ($Scenario -eq "ChetTransaction") {
    $scriptsToParse.Add($firstSmokeRunnerPath)
}
elseif ($Scenario -eq "ChetPersistence") {
    $scriptsToParse.Add($firstSmokeRunnerPath)
}
elseif ($Scenario -eq "Canyon") {
    $scriptsToParse.Add($canyonRunnerPath)
}
else {
    $scriptsToParse.Add($testMapRunnerPath)
}
foreach ($script in $scriptsToParse) {
    if (Test-Path -LiteralPath $script -PathType Leaf) {
        Test-PowerShellParse $script
    }
}

if (Test-Path -LiteralPath $entryPointPath -PathType Leaf) {
    $entryText = Get-Content -Raw -LiteralPath $entryPointPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "Entry point excludes $forbidden" `
            ($entryText -notmatch [regex]::Escape($forbidden)) `
            $entryPointPath
    }
    if ($Scenario -eq "Jam") {
        Add-Check "OpenMW invocation forces SelfDrive" `
            ($entryText -match '(?s)Invoke-FNVJamSprintProof.*?-SelfDrive') `
            $entryPointPath
    }
    elseif ($Scenario -eq "Opening") {
        $retailRoutePresent = $entryText -match 'Invoke-RetailTTWOpeningCapture'
        $openMwRoutePresent = $entryText -match 'Invoke-OpenNVOpeningCapture'
        $expectedRoutePresent =
            (($Target -notin @("All", "Retail")) -or $retailRoutePresent) -and
            (($Target -notin @("All", "OpenMW")) -or $openMwRoutePresent)
        Add-Check "Opening invocation routes to the declared opening runner" `
            $expectedRoutePresent `
            $entryPointPath
    }
    elseif ($Scenario -eq "PipBoy") {
        $expectedPipBoyRoute = if ($Target -eq "Retail") {
            $entryText -match 'Invoke-FNVRetailPipBoyStateCapture'
        } else {
            $entryText -match 'Invoke-OpenNVPipBoyShowcaseCapture'
        }
        Add-Check "Pip-Boy invocation routes to the declared showcase runner" `
            $expectedPipBoyRoute `
            $entryPointPath
    }
    elseif ($Scenario -eq "PipBoyVR") {
        Add-Check "PipBoyVR invocation routes to the declared native OpenXR runner" `
            ($Target -eq "OpenMW" -and $entryText -match 'Invoke-OpenNVPipBoyVRCapture' -and
                $entryText -match '\$Scenario\s+-eq\s+"PipBoyVR"') `
            $entryPointPath
    }
    elseif ($Scenario -eq "Terminal") {
        Add-Check "Terminal invocation routes to the declared OpenMW runner" `
            ($Target -eq "OpenMW" -and $entryText -match 'Invoke-OpenNVTerminalCapture' -and
                $entryText -match '\$Scenario\s+-eq\s+"Terminal"') `
            $entryPointPath
    }
    elseif ($Scenario -eq "RealSave") {
        $realSaveRoutePresent = $entryText -match 'Invoke-FNVRealSaveCapture'
        Add-Check "RealSave invocation routes to the declared real-save runner" `
            ($realSaveRoutePresent -and
                $entryText -match '\$Scenario\s+-eq\s+"RealSave"' -and
                $entryText -match '(?s)&\s+\$preflight.*?-RuntimeReady.*?-RequireIdle') `
            $entryPointPath
    }
    elseif ($Scenario -eq "FirstSmoke") {
        Add-Check "FirstSmoke invocation routes to the declared OpenMW runner" `
            ($Target -eq "OpenMW" -and $entryText -match 'Invoke-OpenNVFirstSmokeCapture' -and
                $entryText -match '\$Scenario\s+-eq\s+"FirstSmoke"') `
            $entryPointPath
    }
    elseif ($Scenario -eq "ChetObservation") {
        Add-Check "ChetObservation invocation routes to the declared OpenMW runner" `
            ($Target -eq "OpenMW" -and $entryText -match 'Invoke-OpenNVFirstSmokeCapture' -and
                $entryText -match '\$Scenario\s+-eq\s+"ChetObservation"' -and
                $entryText -match 'Route ChetObservation') `
            $entryPointPath
    }
    elseif ($Scenario -eq "ChetPersistent") {
        Add-Check "ChetPersistent invocation routes to the declared OpenMW runner" `
            ($Target -eq "OpenMW" -and $entryText -match 'Invoke-OpenNVFirstSmokeCapture' -and
                $entryText -match '\$Scenario\s+-eq\s+"ChetPersistent"' -and
                $entryText -match 'Route ChetPersistent') `
            $entryPointPath
    }
    elseif ($Scenario -eq "ChetTransaction") {
        Add-Check "ChetTransaction invocation routes to the declared OpenMW runner" `
            ($Target -eq "OpenMW" -and $entryText -match 'Invoke-OpenNVFirstSmokeCapture' -and
                $entryText -match '\$Scenario\s+-eq\s+"ChetTransaction"' -and
                $entryText -match 'Route ChetTransaction') `
            $entryPointPath
    }
    elseif ($Scenario -eq "ChetPersistence") {
        Add-Check "ChetPersistence invocation runs save and reload through the declared OpenMW runner" `
            ($Target -eq "OpenMW" -and $entryText -match 'Invoke-OpenNVFirstSmokeCapture' -and
                $entryText -match '\$Scenario\s+-eq\s+"ChetPersistence"' -and
                $entryText -match 'Route ChetPersistenceSave' -and $entryText -match 'Route ChetPersistenceReload') `
            $entryPointPath
    }
    elseif ($Scenario -eq "Canyon") {
        Add-Check "Canyon invocation routes to the declared OpenMW runner" `
            ($Target -eq "OpenMW" -and $entryText -match 'Invoke-OpenNVCanyonCrawlCapture' -and
                $entryText -match '\$Scenario\s+-eq\s+"Canyon"') `
            $entryPointPath
    }
    elseif ($Scenario -eq "TestMap") {
        Add-Check "TestMap invocation routes to the declared diagnostic runner" `
            ($Target -eq "OpenMW" -and $entryText -match 'Invoke-OpenNVTestMapDiagnostic') `
            $entryPointPath
    }
}

if ($Scenario -eq "Jam" -and $Target -in @("All", "Retail")) {
    if (Test-Path -LiteralPath $retailRunnerPath -PathType Leaf) {
        $retailText = Get-Content -Raw -LiteralPath $retailRunnerPath
        Add-Check "Retail schedules background polling" `
            ($retailText -match 'EnableBackgroundInputPolling') $retailRunnerPath
        Add-Check "Retail uses native HoldKey and ReleaseKey" `
            ($retailText -match 'HoldKey' -and $retailText -match 'ReleaseKey') `
            $retailRunnerPath
        Add-Check "Retail supports dense native video frames" `
            ($retailText -match '\[switch\]\$RecordVideo' -and
                $retailText -match 'retail-d3d9-backbuffer-bmp-sequence') `
            $retailRunnerPath
        foreach ($forbidden in @(
            "AppActivate", "SetForegroundWindow", "BringWindowToTop",
            "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
        )) {
            Add-Check "Retail runner excludes $forbidden" `
                ($retailText -notmatch [regex]::Escape($forbidden)) `
                $retailRunnerPath
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($oracleSourcePath) -and
        (Test-Path -LiteralPath $oracleSourcePath -PathType Leaf)) {
        $oracleText = Get-Content -Raw -LiteralPath $oracleSourcePath
        Add-Check "Oracle selects only DirectInput keyboard" `
            ($oracleText -match 'GET_DIDEVICE_TYPE\(result\.deviceType\)\s*==\s*DI8DEVTYPE_KEYBOARD') `
            $oracleSourcePath
        Add-Check "Oracle requests background nonexclusive keyboard" `
            ($oracleText -match 'DISCL_BACKGROUND\s*\|\s*DISCL_NONEXCLUSIVE') `
            $oracleSourcePath
        Add-Check "Oracle reports reconfiguration explicitly" `
            ($oracleText -match '\\"reconfigured\\"') $oracleSourcePath
        Add-Check "Oracle returns before touching non-keyboard devices" `
            ($oracleText -match '(?s)if\s*\(!result\.selected\).*?return result;.*?device->Unacquire\(\)') `
            $oracleSourcePath
        Add-Check "Oracle supports schedules larger than 4096 bytes" `
            ($oracleText -match 'maxEnvironmentValueLength\s*=\s*1024\s*\*\s*1024' -and
                $oracleText -match 'GetEnvironmentVariableA\(name,\s*nullptr,\s*0\)') `
            $oracleSourcePath
    }

    $runtimeManifestExists =
        Test-File "Oracle runtime manifest exists" $oracleRuntimeManifestPath
    $runtimeDllExists =
        Test-File "Oracle runtime DLL exists" $oracleDllPath
    if ($runtimeManifestExists -and $runtimeDllExists) {
        try {
            $runtimeManifest =
                Get-Content -Raw -LiteralPath $oracleRuntimeManifestPath |
                ConvertFrom-Json
            $expectedHash = [string]$runtimeManifest.files.plugin.sha256
            $actualHash =
                (Get-FileHash -LiteralPath $oracleDllPath -Algorithm SHA256).
                Hash.ToLowerInvariant()
            Add-Check "Oracle DLL matches runtime manifest" `
                ($actualHash -eq $expectedHash.ToLowerInvariant()) `
                "expected=$expectedHash actual=$actualHash"
        }
        catch {
            Add-Check "Oracle DLL matches runtime manifest" $false `
                $_.Exception.Message
        }
    }
}

if ($Scenario -eq "Jam" -and $Target -in @("All", "OpenMW") -and
    (Test-Path -LiteralPath $openMwRunnerPath -PathType Leaf)) {
    $openMwText = Get-Content -Raw -LiteralPath $openMwRunnerPath
    Add-Check "Full OpenMW proof refuses non-SelfDrive runs" `
        ($openMwText -match '(?s)\$FullProofDrive\s+-and\s+-not\s+\$SelfDrive.*?throw') `
        $openMwRunnerPath
    Add-Check "OpenMW report records app-control flags" `
        ($openMwText -match 'windowsAppControlUsed' -and
            $openMwText -match 'foregroundActivationUsed' -and
            $openMwText -match 'foregroundInputInjected') `
        $openMwRunnerPath
}

if ($Scenario -eq "Opening" -and $Target -in @("All", "Retail") -and
    (Test-Path -LiteralPath $retailOpeningRunnerPath -PathType Leaf)) {
    $retailOpeningText = Get-Content -Raw -LiteralPath $retailOpeningRunnerPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "Retail TTW opening runner excludes $forbidden" `
            ($retailOpeningText -notmatch [regex]::Escape($forbidden)) `
            $retailOpeningRunnerPath
    }
    Add-Check "Retail TTW opening runner awaits a native NewGame event" `
        ($retailOpeningText -match 'AwaitNewGame' -and
            $retailOpeningText -match 'new-game-observed') `
        $retailOpeningRunnerPath
    Add-Check "Retail TTW opening runner schedules StartNewCharacter and native D3D frames" `
        ($retailOpeningText -match '\$\{MenuStartGameLoopFrame\}:StartNewCharacter' -and
            $retailOpeningText -match 'scheduled-backbuffer-capture') `
        $retailOpeningRunnerPath
    $retailOracleText = Get-Content -Raw -LiteralPath $oracleSourcePath
    Add-Check "Retail oracle exposes StartNewCharacter through live New and Yes control API boundaries" `
        ($retailOracleText -match 'StartNewCharacter' -and
            $retailOracleText -match 'startMenuVisible' -and
            $retailOracleText -match 'menuPresent' -and
            $retailOracleText -match 'option\.tile == action\.actionTile' -and
            $retailOracleText -match 'dispatchStartMenuListBoxEnter\(\s*readiness\.menu, 0xE4, confirmation\.yesTile\)' -and
            $retailOracleText -match 'StartMenu\.HandleSpecialKeyInput\(kEnter\)' -and
            $retailOracleText -match 'specialKeyHandled' -and
            $retailOracleText -match 'selected == confirmation\.yesTile' -and
            $retailOracleText -match 'start-new-character-new-api-dispatch' -and
            $retailOracleText -match 'start-new-character-confirmation-api-dispatch' -and
            $retailOracleText -match 'xNVSE buffered menu-input queue' -and
            $retailOracleText -match 'desktopInputUsed\\":false' -and
            $retailOracleText -notmatch 'SendInput' -and
            $retailOracleText -match 'sStartMenuNewGameActionName = "New"' -and
            $retailOracleText -match 'sStartMenuNewGameListIndex = 1\.f') `
        $oracleSourcePath
    Add-Check "Retail TTW opening runner composes base Data with the TTW overlay" `
        ($retailOpeningText -match 'baseDataRoot' -and
            $retailOpeningText -match 'TTW overlay') `
        $retailOpeningRunnerPath
}

if ($Scenario -eq "Opening" -and $Target -in @("All", "OpenMW") -and
    (Test-Path -LiteralPath $openingRunnerPath -PathType Leaf)) {
    $openingText = Get-Content -Raw -LiteralPath $openingRunnerPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "Opening runner excludes $forbidden" `
            ($openingText -notmatch [regex]::Escape($forbidden)) `
            $openingRunnerPath
    }
    Add-Check "Opening runner uses exact-title capture" `
        ($openingText -match 'title=OpenMW') $openingRunnerPath
    Add-Check "Opening runner prevents focus-loss minimization without foreground control" `
        ($openingText -match 'minimize on focus loss' -and
            $openingText -match 'Get-VideoVisualEvidence' -and
            $openingText -match 'changingVisibleFrames') $openingRunnerPath
    Add-Check "Opening runner records a DirectShow audio stream" `
        ($openingText -match 'audio=\$AudioDevice' -and $openingText -match 'Stereo Mix') `
        $openingRunnerPath
    Add-Check "Opening runner uses authored video capture markers" `
        ($openingText -match 'OPENMW_CAPTURE_VIDEO_READY_PATH' -and
            $openingText -match 'OPENMW_CAPTURE_VIDEO_GO_PATH') `
        $openingRunnerPath
    Add-Check "Opening runner validates the declared TTW data-layer contract" `
        ($openingText -match 'Assert-OpenNVTtwLayerContract' -and
            $openingText -match 'dataLayerContract') `
        $openingRunnerPath
    if (Test-Path -LiteralPath $ttwInitializerPath -PathType Leaf) {
        $ttwInitializerText = Get-Content -Raw -LiteralPath $ttwInitializerPath
        Add-Check "TTW profile declares an ordered base-plus-overlay data union" `
            ($ttwInitializerText -match 'dataLayers' -and
                $ttwInitializerText -match 'ttw-generated-overlay' -and
                $ttwInitializerText -match 'low-to-high precedence') `
            $ttwInitializerPath
        Add-Check "TTW profile verifies TTW-owned and base fallback assets" `
            ($ttwInitializerText -match 'Resolve-TtwLayeredFile' -and
                $ttwInitializerText -match 'Fallout - Voices1\.bsa' -and
                $ttwInitializerText -match 'TaleOfTwoWastelands - Textures\.bsa') `
            $ttwInitializerPath
    }
}

if ($Scenario -eq "PipBoy" -and $Target -eq "OpenMW" -and
    (Test-Path -LiteralPath $pipBoyRunnerPath -PathType Leaf)) {
    $pipBoyText = Get-Content -Raw -LiteralPath $pipBoyRunnerPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "Pip-Boy showcase runner excludes $forbidden" `
            ($pipBoyText -notmatch [regex]::Escape($forbidden)) `
            $pipBoyRunnerPath
    }
    Add-Check "Pip-Boy showcase uses normal New Game plus final TestMap placement" `
        ($pipBoyText -match '"--skip-menu", "--new-game"' -and
            $pipBoyText -match 'OPENMW_FNV_GAMEPLAY_START_WORLDSPACE') `
        $pipBoyRunnerPath
    Add-Check "Pip-Boy showcase retains four native UI frames and an exact-title transport" `
        ($pipBoyText -match 'ScreenCaptureHandler' -and
            $pipBoyText -match 'title=OpenMW' -and
            $pipBoyText -match 'PipBoy-live-panel-collage\.png') `
        $pipBoyRunnerPath
    Add-Check "Pip-Boy showcase asserts authored Fallout inventory data without fallbacks" `
        ($pipBoyText -match 'authoredFalloutDataLoadoutObserved' -and
            $pipBoyText -match 'fallbackInventoryRecordsAbsent') `
        $pipBoyRunnerPath
    Add-Check "Pip-Boy showcase records no-control policy fields" `
        ($pipBoyText -match 'windowsAppControlUsed\s*=\s*\$false' -and
            $pipBoyText -match 'foregroundActivationUsed\s*=\s*\$false' -and
            $pipBoyText -match 'foregroundInputInjected\s*=\s*\$false') `
        $pipBoyRunnerPath
}

if ($Scenario -eq "Terminal" -and $Target -eq "OpenMW" -and
    (Test-Path -LiteralPath $terminalRunnerPath -PathType Leaf)) {
    $terminalText = Get-Content -Raw -LiteralPath $terminalRunnerPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "Terminal runner excludes $forbidden" `
            ($terminalText -notmatch [regex]::Escape($forbidden)) $terminalRunnerPath
    }
    Add-Check "Terminal runner stages visibly then dispatches ordinary faced-object Activate" `
        ($terminalText -match 'OPENMW_SELF_DRIVE_INPUT_SCRIPT' -and
            $terminalText -match 'stage-near-form' -and $terminalText -match 'activate-faced-form' -and
            $terminalText -notmatch '"[0-9]+,activate-form,' -and $terminalText -match 'FalloutNV\.esm') $terminalRunnerPath
    Add-Check "Terminal runner paces actions and retains native frames plus exact-title video" `
        ($terminalText -match '12000,screenshot' -and $terminalText -match '16000,activate-faced-form' -and
            $terminalText -match 'title=OpenMW' -and $terminalText -match 'Terminal-\{0:D2\}-native\.png') $terminalRunnerPath
    Add-Check "Terminal validator rejects direct activation and requires physical camera restoration" `
        ($terminalText -match 'directActivationObserved' -and $terminalText -match 'physicalCameraEntryCount' -and
            $terminalText -match 'cameraRestorationCount' -and $terminalText -match 'ordinaryActivationTargetObserved') `
        $terminalRunnerPath
    Add-Check "Terminal runner records OpenMW-only and no-control policy fields" `
        ($terminalText -match 'retailEngineLaunched\s*=\s*\$false' -and
            $terminalText -match 'windowsAppControlUsed\s*=\s*\$false' -and
            $terminalText -match 'foregroundActivationUsed\s*=\s*\$false' -and
            $terminalText -match 'foregroundInputInjected\s*=\s*\$false') $terminalRunnerPath
}

if ($Scenario -eq "RealSave" -and (Test-Path -LiteralPath $realSaveRunnerPath -PathType Leaf)) {
    $realSaveText = Get-Content -Raw -LiteralPath $realSaveRunnerPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "RealSave runner excludes $forbidden" `
            ($realSaveText -notmatch [regex]::Escape($forbidden)) $realSaveRunnerPath
    }
    Add-Check "RealSave OpenMW route uses ordinary load-savegame" `
        ($realSaveText -match '"--load-savegame"' -and
            $realSaveText -notmatch '"--start"' -and
            $realSaveText -notmatch '"--new-game"') $realSaveRunnerPath
    Add-Check "RealSave runner excludes synthetic/bootstrap state" `
        ($realSaveText -notmatch 'TestMap01' -and
            $realSaveText -notmatch 'OPENMW_FNV_BOOTSTRAP' -and
            $realSaveText -notmatch 'OPENMW_FNV_GAMEPLAY_START_WORLDSPACE' -and
            $realSaveText -notmatch 'executeInConsole') $realSaveRunnerPath
    Add-Check "RealSave runner retains native frame, telemetry, and exact-title video" `
        ($realSaveText -match 'ScreenCaptureHandler' -and
            $realSaveText -match 'OPENMW_PROOF_SCREENSHOT_READY_FRAMES' -and
            $realSaveText -match 'OPENMW_WORLD_VIEWER_TELEMETRY' -and
            $realSaveText -match 'title=OpenMW') $realSaveRunnerPath
    Add-Check "RealSave runner records no-control policy fields" `
        ($realSaveText -match 'windowsAppControlUsed\s*=\s*\$false' -and
            $realSaveText -match 'foregroundActivationUsed\s*=\s*\$false' -and
            $realSaveText -match 'foregroundInputInjected\s*=\s*\$false') $realSaveRunnerPath
}

if ($Scenario -eq "TestMap" -and $Target -eq "OpenMW" -and
    (Test-Path -LiteralPath $testMapRunnerPath -PathType Leaf)) {
    $testMapText = Get-Content -Raw -LiteralPath $testMapRunnerPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "TestMap runner excludes $forbidden" `
            ($testMapText -notmatch [regex]::Escape($forbidden)) `
            $testMapRunnerPath
    }
    Add-Check "TestMap runner uses an explicit diagnostic-only start cell" `
        ($testMapText -match '"--start", "TestMap01"' -and
            $testMapText -match 'diagnosticOnly\s*=\s*\$true') `
        $testMapRunnerPath
    Add-Check "TestMap runner retains a native OpenMW framebuffer frame" `
        ($testMapText -match 'OPENMW_PROOF_SCREENSHOT_FRAME' -and
            $testMapText -match 'ScreenCaptureHandler native framebuffer screenshot') `
        $testMapRunnerPath
    Add-Check "TestMap runner records no-control policy fields" `
        ($testMapText -match 'windowsAppControlUsed\s*=\s*\$false' -and
            $testMapText -match 'foregroundActivationUsed\s*=\s*\$false' -and
            $testMapText -match 'foregroundInputInjected\s*=\s*\$false') `
        $testMapRunnerPath
}

if (Test-Path -LiteralPath $runbookPath -PathType Leaf) {
    $runbookText = Get-Content -Raw -LiteralPath $runbookPath
    foreach ($requiredText in @(
        "retail FNV", "OpenMW", "DI8DEVTYPE_KEYBOARD",
        "reconfigured=false", "Invoke-FNVJamBackgroundCapture.ps1",
        "Test-FNVJamBackgroundCapture.ps1"
    )) {
        Add-Check "Runbook contains '$requiredText'" `
            ($runbookText -match [regex]::Escape($requiredText)) $runbookPath
    }
}

if ($RuntimeReady) {
    foreach ($tool in @("ffmpeg", "ffprobe")) {
        $command = Get-Command $tool -ErrorAction SilentlyContinue |
            Select-Object -First 1
        Add-Check "$tool is available" ($null -ne $command) `
            $(if ($null -ne $command) { $command.Source } else { "not on PATH" })
    }
    if ($Scenario -eq "Jam") {
    [void](Test-File "Shared native save exists" $SavePath)

    if ($Target -in @("All", "Retail")) {
        $retailShadowReady = Test-Directory "Retail shadow root exists" $RetailShadowRoot
        if ($retailShadowReady) {
            foreach ($file in @(
                "FalloutNV.exe",
                "Data\nvse\plugins\jip_nvse.dll",
                "Data\nvse\plugins\johnnyguitar.dll",
                "Data\nvse\plugins\kNVSE.dll",
                "Data\nvse\plugins\nvse_stewie_tweaks.dll",
                "Data\nvse\plugins\ui_organizer.dll"
            )) {
                [void](Test-File "Retail runtime file exists: $file" `
                    (Join-Path $RetailShadowRoot $file))
            }
        }
    }

    if ($Target -in @("All", "OpenMW")) {
        [void](Test-File "OpenMW binary exists" `
            (Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\openmw.exe"))
        [void](Test-Directory "OpenMW resources exist" `
            (Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\resources"))
        $cmakeCache =
            Join-Path $EngineRoot "MSVC2022_64\CMakeCache.txt"
        $cmakeCacheExists =
            Test-File "OpenMW CMake cache exists" $cmakeCache
        if ($cmakeCacheExists) {
            $myGuiLibraryEntry = Select-String -LiteralPath $cmakeCache `
                -Pattern '^MyGUI_LIBRARY:FILEPATH=(?<path>.+)$' |
                Select-Object -First 1
            Add-Check "OpenMW CMake cache declares MyGUI" `
                ($null -ne $myGuiLibraryEntry) $cmakeCache
            $osgVersionEntry = Select-String -LiteralPath $cmakeCache `
                -Pattern '^OPENSCENEGRAPH_VERSION:INTERNAL=(?<version>.+)$' |
                Select-Object -First 1
            Add-Check "OpenMW CMake cache declares OSG version" `
                ($null -ne $osgVersionEntry) $cmakeCache
            if ($null -ne $myGuiLibraryEntry -and $null -ne $osgVersionEntry) {
                $myGuiLibrary =
                    $myGuiLibraryEntry.Matches[0].Groups["path"].Value
                $dependencyRoot =
                    Split-Path -Parent (Split-Path -Parent $myGuiLibrary)
                $myGuiRuntimeCandidates = @(
                    (Join-Path $dependencyRoot "bin\Release\MyGUIEngine.dll"),
                    (Join-Path $dependencyRoot "bin\MyGUIEngine.dll")
                )
                $myGuiRuntime = @($myGuiRuntimeCandidates | Where-Object {
                    Test-Path -LiteralPath $_ -PathType Leaf
                } | Select-Object -First 1)
                Add-Check "Matching OpenMW MyGUI runtime exists" `
                    ($myGuiRuntime.Count -eq 1) `
                    ($myGuiRuntimeCandidates -join ", ")

                $osgVersion =
                    $osgVersionEntry.Matches[0].Groups["version"].Value
                $osgPluginPath = Join-Path $dependencyRoot `
                    "plugins\osgPlugins-$osgVersion"
                [void](Test-Directory `
                    "Matching OpenMW OSG plugin directory exists" `
                    $osgPluginPath)
                foreach ($pluginName in @(
                    "osgdb_bmp.dll",
                    "osgdb_dae.dll",
                    "osgdb_dds.dll",
                    "osgdb_freetype.dll",
                    "osgdb_jpeg.dll",
                    "osgdb_osg.dll",
                    "osgdb_png.dll",
                    "osgdb_serializers_osg.dll",
                    "osgdb_tga.dll"
                )) {
                    [void](Test-File `
                        "Matching OpenMW OSG plugin exists: $pluginName" `
                        (Join-Path $osgPluginPath $pluginName))
                }
            }
        }
        [void](Test-File "Untouched JAM ESP exists" `
            (Join-Path $JamRoot "JustAssortedMods.esp"))
        [void](Test-File "Published JAM archive exists" $JamArchive)
        [void](Test-File "OpenMW JAM provider exists" `
            (Join-Path $EngineRoot `
                "MSVC2022_64\RelWithDebInfo\resources\vfs\scripts\omw\fnv\compat\jam_sprint.lua"))
    }
    }
    elseif ($Scenario -eq "Opening") {
        if ($Target -in @("All", "Retail")) {
            [void](Test-File "Retail TTW opening executable exists" `
                "D:\SteamLibrary\steamapps\common\Fallout New Vegas\FalloutNV.exe")
            [void](Test-Directory "Retail TTW opening base Data root exists" `
                "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data")
            [void](Test-File "Retail TTW opening retains base FNV voices archive" `
                "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data\Fallout - Voices1.bsa")
            [void](Test-Directory "Retail TTW opening content root exists" $OpeningTtwRoot)
            foreach ($asset in @(
                "FalloutNV.esm",
                "Fallout3.esm",
                "TaleOfTwoWastelands.esm",
                "YUPTTW.esm",
                "Video\Fallout INTRO Vsk.bik"
            )) {
                [void](Test-File "Retail TTW opening asset exists: $asset" `
                    (Join-Path $OpeningTtwRoot $asset))
            }
            [void](Test-File "Retail TTW opening oracle manifest exists" `
                $oracleRuntimeManifestPath)
            [void](Test-File "Retail TTW opening oracle DLL exists" $oracleDllPath)
            [void](Test-File "Retail TTW compatibility-layer manifest exists" `
                $retailTtwLayerManifestPath)
            if (Test-Path -LiteralPath $retailTtwLayerManifestPath -PathType Leaf) {
                try {
                    $retailTtwLayer = Get-Content -LiteralPath $retailTtwLayerManifestPath -Raw | ConvertFrom-Json
                    Add-Check "Retail TTW compatibility-layer schema is current" `
                        ([string]$retailTtwLayer.schema -eq 'opennv-ttw-retail-compat-layer/v1') `
                        ([string]$retailTtwLayer.schema)
                    foreach ($entry in @($retailTtwLayer.plugins)) {
                        $pluginPath = Join-Path (Split-Path -Parent $retailTtwLayerManifestPath) ([string]$entry.path)
                        $pluginExists = Test-Path -LiteralPath $pluginPath -PathType Leaf
                        $hashMatches = $pluginExists -and
                            ((Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq
                                ([string]$entry.sha256).ToLowerInvariant())
                        Add-Check "Retail TTW compatibility plugin is present and pinned: $($entry.id)" `
                            $hashMatches $pluginPath
                    }
                }
                catch {
                    Add-Check "Retail TTW compatibility-layer manifest parses" $false $_.Exception.Message
                }
            }
        }

        if ($Target -in @("All", "OpenMW")) {
        [void](Test-File "Deployed OpenNV opening binary exists" `
            (Join-Path $OpeningRuntimeRoot "openmw.exe"))
        [void](Test-Directory "Deployed OpenNV opening resources exist" `
            (Join-Path $OpeningRuntimeRoot "resources"))
        foreach ($plugin in @("osgdb_dds.dll", "osgdb_png.dll", "osgdb_freetype.dll")) {
            [void](Test-File "Deployed OpenNV OSG plugin exists: $plugin" `
                (Join-Path $OpeningRuntimeRoot (Join-Path "osgPlugins-3.6.5" $plugin)))
        }
        if ($OpeningCampaign -eq "NewVegas") {
            [void](Test-File "Standalone New Vegas opening profile initializer exists" $newVegasInitializerPath)
            [void](Test-Directory "Standalone New Vegas Data root exists" $OpeningNewVegasData)
            [void](Test-File "Standalone New Vegas opening master exists" `
                (Join-Path $OpeningNewVegasData "FalloutNV.esm"))
            [void](Test-File "Standalone New Vegas authored opening Bink exists" `
                (Join-Path $OpeningNewVegasData "Video\FNVIntro.bik"))
        }
        [void](Test-File "TTW opening profile initializer exists" $ttwInitializerPath)
        [void](Test-Directory "TTW opening content root exists" $OpeningTtwRoot)
        [void](Test-File "TTW authored opening Bink exists" `
            (Join-Path $OpeningTtwRoot "Video\Fallout INTRO Vsk.bik"))
        [void](Test-File "Fallout 3 opening master exists" `
            "D:\SteamLibrary\steamapps\common\Fallout 3 goty\Data\Fallout3.esm")
        [void](Test-File "New Vegas opening master exists" `
            "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data\FalloutNV.esm")

        try {
            $layerPreflightProfile = Join-Path $WorldsRoot "profiles\_verification\_preflight-ttw-layer-contract"
            $layerPreflightCampaign = Join-Path $WorldsRoot "profiles\_verification\_campaigns\_preflight-ttw-layer-contract\userdata"
            $layerPreflight = & $ttwInitializerPath `
                -TtwRoot $OpeningTtwRoot `
                -Fallout3Data "D:\SteamLibrary\steamapps\common\Fallout 3 goty\Data" `
                -FalloutNewVegasData "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data" `
                -ProfileDirectory $layerPreflightProfile `
                -CampaignUserdataDirectory $layerPreflightCampaign `
                -BinaryRoot $OpeningRuntimeRoot `
                -DryRun
            $expectedLayerIds = @(
                "fallout3-base",
                "fallout-new-vegas-base",
                "fallout3-archive-aliases",
                "ttw-generated-overlay"
            )
            $actualLayerIds = @($layerPreflight.dataLayers |
                Sort-Object { [int]$_.priority } |
                ForEach-Object { [string]$_.id })
            Add-Check "TTW OpenMW dry-run declares the retail-equivalent data union" `
                (($actualLayerIds -join '|') -eq ($expectedLayerIds -join '|')) `
                ($actualLayerIds -join ' -> ')
            $resolvedAssets = @($layerPreflight.resolvedLayeredAssets)
            $ttwResolved = @($resolvedAssets | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.expectedProviderLayerId)
            })
            Add-Check "TTW OpenMW dry-run resolves authored assets from the TTW overlay" `
                ($ttwResolved.Count -ge 7 -and
                    @($ttwResolved | Where-Object {
                        [string]$_.providerLayerId -ne [string]$_.expectedProviderLayerId
                    }).Count -eq 0) `
                (@($ttwResolved | ForEach-Object { "$($_.id)=$($_.providerLayerId)" }) -join '; ')
            $baseFallbacks = @($resolvedAssets | Where-Object {
                [string]::IsNullOrWhiteSpace([string]$_.expectedProviderLayerId)
            })
            Add-Check "TTW OpenMW dry-run preserves required base fallback archives" `
                ($baseFallbacks.Count -ge 2 -and
                    @($baseFallbacks | Where-Object {
                        -not (Test-Path -LiteralPath ([string]$_.providerPath) -PathType Leaf)
                    }).Count -eq 0) `
                (@($baseFallbacks | ForEach-Object { "$($_.id)=$($_.providerLayerId)" }) -join '; ')
        }
        catch {
            Add-Check "TTW OpenMW dry-run validates the data-layer union" $false $_.Exception.Message
        }

        $deviceText = ""
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $deviceText = ((& ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1) | Out-String)
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        Add-Check "DirectShow opening audio device is available" `
            ($deviceText -match [regex]::Escape('"' + $OpeningAudioDevice + '" (audio)')) `
            $OpeningAudioDevice
        }
    }
    elseif ($Scenario -eq "PipBoy") {
        if ($Target -eq "Retail") {
            [void](Test-File "Retail FalloutNV binary exists" `
                (Join-Path (Split-Path -Parent $OpeningNewVegasData) "FalloutNV.exe"))
            [void](Test-File "Retail Pip-Boy oracle DLL exists" $oracleDllPath)
            [void](Test-File "Retail Pip-Boy save fixture exists" $SavePath)
        }
        else {
            # The live Pip-Boy panel run uses the same isolated standalone FNV
            # runtime as TestMap01, but reaches it after normal New Game.
            [void](Test-File "Deployed OpenNV Pip-Boy binary exists" `
                (Join-Path $OpeningRuntimeRoot "openmw.exe"))
            [void](Test-Directory "Deployed OpenNV Pip-Boy resources exist" `
                (Join-Path $OpeningRuntimeRoot "resources"))
            foreach ($plugin in @("osgdb_dds.dll", "osgdb_png.dll", "osgdb_freetype.dll")) {
                [void](Test-File "Deployed OpenNV Pip-Boy OSG plugin exists: $plugin" `
                    (Join-Path $OpeningRuntimeRoot (Join-Path "osgPlugins-3.6.5" $plugin)))
            }
            [void](Test-File "Standalone New Vegas Pip-Boy profile initializer exists" $newVegasInitializerPath)
            [void](Test-Directory "Standalone New Vegas Pip-Boy Data root exists" $OpeningNewVegasData)
            [void](Test-File "Standalone New Vegas Pip-Boy master exists" `
                (Join-Path $OpeningNewVegasData "FalloutNV.esm"))
        }
    }
    elseif ($Scenario -eq "PipBoyVR") {
        [void](Test-File "Deployed OpenMW VR binary exists" `
            (Join-Path $OpeningRuntimeRoot "openmw_vr.exe"))
        $vrRuntimeManifest = if (Test-Path -LiteralPath (Join-Path $OpeningRuntimeRoot "candidate-runtime-manifest.json") -PathType Leaf) {
            Join-Path $OpeningRuntimeRoot "candidate-runtime-manifest.json"
        } else {
            Join-Path $OpeningRuntimeRoot "runtime-manifest.json"
        }
        [void](Test-File "Deployed OpenMW VR runtime manifest exists" $vrRuntimeManifest)
        [void](Test-Directory "Deployed OpenMW VR resources exist" `
            (Join-Path $OpeningRuntimeRoot "resources"))
        foreach ($plugin in @("osgdb_bmp.dll", "osgdb_dds.dll", "osgdb_png.dll", "osgdb_freetype.dll")) {
            [void](Test-File "Deployed OpenMW VR OSG plugin exists: $plugin" `
                (Join-Path $OpeningRuntimeRoot (Join-Path "osgPlugins-3.6.5" $plugin)))
        }
        [void](Test-Directory "Standalone New Vegas VR Data root exists" $OpeningNewVegasData)
        [void](Test-File "Standalone New Vegas VR master exists" `
            (Join-Path $OpeningNewVegasData "FalloutNV.esm"))
        Add-Check "ffmpeg is available for OpenMW VR native-frame encoding" `
            ($null -ne (Get-Command ffmpeg -ErrorAction SilentlyContinue)) "ffmpeg"
        Add-Check "ffprobe is available for OpenMW VR media validation" `
            ($null -ne (Get-Command ffprobe -ErrorAction SilentlyContinue)) "ffprobe"
        if ($OutputRoot) {
            Add-Check "PipBoyVR output root is unused" (-not (Test-Path -LiteralPath $OutputRoot)) $OutputRoot
        }
    }
    elseif ($Scenario -eq "Terminal") {
        Add-Check "Terminal capture duration is bounded" `
            ($TerminalCaptureSeconds -ge 52 -and $TerminalCaptureSeconds -le 90) ([string]$TerminalCaptureSeconds)
        [void](Test-File "Deployed OpenNV Terminal binary exists" (Join-Path $OpeningRuntimeRoot "openmw.exe"))
        [void](Test-Directory "Deployed OpenNV Terminal resources exist" (Join-Path $OpeningRuntimeRoot "resources"))
        foreach ($plugin in @("osgdb_bmp.dll", "osgdb_dae.dll", "osgdb_dds.dll", "osgdb_freetype.dll",
            "osgdb_jpeg.dll", "osgdb_osg.dll", "osgdb_png.dll", "osgdb_serializers_osg.dll", "osgdb_tga.dll")) {
            [void](Test-File "Deployed OpenNV Terminal OSG plugin exists: $plugin" `
                (Join-Path $OpeningRuntimeRoot (Join-Path "osgPlugins-3.6.5" $plugin)))
        }
        [void](Test-File "Standalone New Vegas Terminal profile initializer exists" $newVegasInitializerPath)
        [void](Test-Directory "Standalone New Vegas Terminal Data root exists" $OpeningNewVegasData)
        [void](Test-File "Standalone New Vegas Terminal master exists" (Join-Path $OpeningNewVegasData "FalloutNV.esm"))
        if ($OutputRoot) {
            Add-Check "Terminal output root is unused" (-not (Test-Path -LiteralPath $OutputRoot)) $OutputRoot
        }
    }
    elseif ($Scenario -eq "RealSave") {
        $expectedSaveBytes = 3395328L
        $expectedSaveSha256 = "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f"
        $saveExists = Test-File "Immutable Save330 fixture exists" $SavePath
        if ($saveExists) {
            $saveFile = Get-Item -LiteralPath $SavePath
            $actualSaveSha256 = (Get-FileHash -LiteralPath $SavePath -Algorithm SHA256).Hash.ToLowerInvariant()
            Add-Check "Immutable Save330 fixture size is pinned" `
                ([long]$saveFile.Length -eq $expectedSaveBytes) `
                "expected=$expectedSaveBytes actual=$($saveFile.Length)"
            Add-Check "Immutable Save330 fixture SHA-256 is pinned" `
                ($actualSaveSha256 -eq $expectedSaveSha256) `
                "expected=$expectedSaveSha256 actual=$actualSaveSha256"
        }
        Add-Check "RealSave route ID is bounded" `
            ($RealSaveRouteId -in @("save330-cold-load-settle-v1", "save330-reload-idempotence-v1", "save330-pipboy-map-selection-v1", "save330-pipboy-map-travel-v1", "save330-pipboy-rejection-matrix-v1", "save330-travel-persistence-v1", "save330-pipboy-inventory-v1", "save330-pipboy-weapon-selection-v1", "save330-pipboy-radio-stations-v1")) $RealSaveRouteId
        if ($RealSaveRouteId -in @("save330-reload-idempotence-v1", "save330-pipboy-map-selection-v1", "save330-pipboy-map-travel-v1", "save330-pipboy-rejection-matrix-v1", "save330-travel-persistence-v1", "save330-pipboy-inventory-v1", "save330-pipboy-weapon-selection-v1", "save330-pipboy-radio-stations-v1")) {
            Add-Check "RealSave selected production route is OpenMW-only" `
                ($Target -eq "OpenMW") $Target
        }
        Add-Check "RealSave capture duration is bounded" `
            ($RealSaveCaptureSeconds -ge 5 -and $RealSaveCaptureSeconds -le 600) `
            ([string]$RealSaveCaptureSeconds)
        if ($Target -eq "Retail") {
            [void](Test-File "Retail FalloutNV binary exists for RealSave" `
                (Join-Path (Split-Path -Parent $OpeningNewVegasData) "FalloutNV.exe"))
            [void](Test-File "Retail RealSave oracle DLL exists" $oracleDllPath)
            [void](Test-File "Retail RealSave oracle runner exists" `
                (Join-Path $WorldsRoot "scripts\Invoke-FNVRetailOracle.ps1"))
        }
        elseif ($Target -eq "OpenMW") {
            [void](Test-File "Deployed OpenMW RealSave binary exists" `
                (Join-Path $OpeningRuntimeRoot "openmw.exe"))
            [void](Test-Directory "Deployed OpenMW RealSave resources exist" `
                (Join-Path $OpeningRuntimeRoot "resources"))
            [void](Test-File "Standalone New Vegas RealSave profile initializer exists" $newVegasInitializerPath)
            [void](Test-Directory "Standalone New Vegas RealSave Data root exists" $OpeningNewVegasData)
            [void](Test-File "Standalone New Vegas RealSave master exists" `
                (Join-Path $OpeningNewVegasData "FalloutNV.esm"))
            if ($RealSaveRouteId -eq "save330-pipboy-radio-stations-v1") {
                $deviceText = ""
                $previousErrorActionPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = "Continue"
                    $deviceText = ((& ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1) | Out-String)
                }
                finally { $ErrorActionPreference = $previousErrorActionPreference }
                Add-Check "RealSave radio DirectShow audio device is available" `
                    ($deviceText -match [regex]::Escape('"' + $OpeningAudioDevice + '" (audio)')) `
                    $OpeningAudioDevice
            }
        }
        if ($OutputRoot) {
            Add-Check "RealSave output root is unused" `
                (-not (Test-Path -LiteralPath $OutputRoot)) $OutputRoot
        }
    }
    elseif ($Scenario -eq "TestMap") {
        # TestMap01 is a standalone FNV renderer diagnostic. It does not pull
        # TTW, retail, or Morrowind assets into the profile.
        [void](Test-File "Deployed OpenNV TestMap binary exists" `
            (Join-Path $OpeningRuntimeRoot "openmw.exe"))
        [void](Test-Directory "Deployed OpenNV TestMap resources exist" `
            (Join-Path $OpeningRuntimeRoot "resources"))
        foreach ($plugin in @("osgdb_dds.dll", "osgdb_png.dll", "osgdb_freetype.dll")) {
            [void](Test-File "Deployed OpenNV TestMap OSG plugin exists: $plugin" `
                (Join-Path $OpeningRuntimeRoot (Join-Path "osgPlugins-3.6.5" $plugin)))
        }
        [void](Test-File "Standalone New Vegas TestMap profile initializer exists" $newVegasInitializerPath)
        [void](Test-Directory "Standalone New Vegas TestMap Data root exists" $OpeningNewVegasData)
        [void](Test-File "Standalone New Vegas TestMap master exists" `
            (Join-Path $OpeningNewVegasData "FalloutNV.esm"))
    }
}

if ($RequireIdle) {
    $processNames = if ($Target -eq "Retail") {
        @("FalloutNV", "nvse_loader")
    } elseif ($Target -eq "OpenMW") {
        @("openmw", "openmw_vr")
    } else {
        @("FalloutNV", "nvse_loader", "openmw", "openmw_vr")
    }
    $running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
    Add-Check "Capture engines are idle" ($running.Count -eq 0) `
        $(if ($running.Count -eq 0) {
            "none"
        } else {
            ($running | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ", "
        })
}

$failed = @($checks | Where-Object { -not $_.passed })
$result = [pscustomobject][ordered]@{
    schema = "nikami-fnv-jam-background-capture-preflight/v1"
    status = if ($failed.Count -eq 0) { "pass" } else { "fail" }
    target = $Target
    scenario = $Scenario
    runtimeReadyChecked = [bool]$RuntimeReady
    idleChecked = [bool]$RequireIdle
    passedChecks = $checks.Count - $failed.Count
    failedChecks = $failed.Count
    checks = @($checks)
}
$result
if ($failed.Count -ne 0) {
    throw "FNV/JAM background-capture preflight failed $($failed.Count) check(s): " +
        (($failed | ForEach-Object name) -join "; ")
}
