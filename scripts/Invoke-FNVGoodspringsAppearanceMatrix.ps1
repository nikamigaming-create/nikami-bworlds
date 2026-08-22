param(
    [string]$MatrixPath = "catalog/fnv-goodsprings-retail-matrix.json",
    [string]$RuntimeRoot = "local/xnvse-retail-oracle",
    [string]$PluginDll = "local/xnvse-retail-oracle/plugins/nvse_retail_oracle.dll",
    [string]$SaveFixture = "run/retail-oracle/checkpoints/NikamiOracleEasyPeteSeated.fos",
    [string]$RunId = ("fnv-goodsprings-appearance-" + (Get-Date -Format "yyyyMMdd-HHmmss")),
    [string]$OutputRoot = "run/retail-oracle",
    [switch]$StageReferences,
    [string[]]$TargetId = @(),
    [ValidateSet('front-portrait', 'front-full-body')]
    [string]$CameraShotKind = 'front-portrait',
    [ValidateRange(32, 512)]
    [float]$PortraitDistance = 70,
    [ValidateRange(1, 8)]
    [float]$FullBodyDistanceScale = 2.9
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

function Resolve-AbsolutePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function ConvertTo-RetailFormId([string]$Text) {
    if ($Text -notmatch '^0[xX][0-9a-fA-F]{1,8}$') {
        throw "Invalid retail form ID: $Text"
    }
    return [Convert]::ToUInt32($Text.Substring(2), 16)
}

function ConvertFrom-RetailStateLine([string]$Line) {
    if ($Line -match '"event":"actor-geometry"') {
        # The immutable JSONL keeps every final vertex for forensic evidence.
        # The state contract needs only hashes, bounds, and transforms, so avoid
        # materializing those large arrays in PowerShell.
        $verticesMarker = ',"vertices":['
        $verticesIndex = $Line.LastIndexOf($verticesMarker, [StringComparison]::Ordinal)
        if ($verticesIndex -lt 0) {
            throw 'actor-geometry telemetry has no vertices payload boundary.'
        }
        return (($Line.Substring(0, $verticesIndex) + '}') | ConvertFrom-Json)
    }
    return ($Line | ConvertFrom-Json)
}

$matrixFile = Resolve-AbsolutePath $MatrixPath
$outputDirectory = Resolve-AbsolutePath (Join-Path $OutputRoot $RunId)
$runner = Join-Path $PSScriptRoot "Invoke-FNVRetailOracle.ps1"
$comparator = Join-Path $PSScriptRoot "compare_fnv_goodsprings_appearance.py"
$contactSheetScript = Join-Path $PSScriptRoot "New-ScreenshotContactSheet.ps1"

foreach ($required in @($matrixFile, (Resolve-AbsolutePath $PluginDll), (Resolve-AbsolutePath $SaveFixture),
        $runner, $comparator, $contactSheetScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing Goodsprings appearance-matrix dependency: $required"
    }
}
if (Test-Path -LiteralPath $outputDirectory) {
    throw "Refusing to overwrite an existing Goodsprings matrix run: $outputDirectory"
}
New-Item -ItemType Directory -Path $outputDirectory | Out-Null

$matrix = Get-Content -LiteralPath $matrixFile -Raw | ConvertFrom-Json
$targetFilter = @{}
foreach ($filterId in $TargetId) {
    if (-not [string]::IsNullOrWhiteSpace($filterId)) {
        $targetFilter[$filterId] = $true
    }
}
$humanoids = @($matrix.targets | Where-Object {
    $_.category -like "*humanoid" -and ($targetFilter.Count -eq 0 -or $targetFilter.ContainsKey([string]$_.id))
})
if ($targetFilter.Count -eq 0 -and $humanoids.Count -ne [int]$matrix.scope.humanoidCount) {
    throw "Matrix humanoid count does not match its declared scope."
}

$captureByTarget = @{}
$groupRuns = @()
$groups = @($humanoids | Group-Object { $_.cell.form })
for ($groupIndex = 0; $groupIndex -lt $groups.Count; ++$groupIndex) {
    $group = $groups[$groupIndex]
    $targets = @($group.Group)
    $cellLabel = if (-not [string]::IsNullOrWhiteSpace([string]$targets[0].cell.editorId)) {
        [string]$targets[0].cell.editorId
    } else {
        [string]$targets[0].cell.form
    }
    $safeCellLabel = ($cellLabel -replace '[^A-Za-z0-9_-]', '-').ToLowerInvariant()
    $groupLabel = "{0:D2}-{1}" -f ($groupIndex + 1), $safeCellLabel
    $jsonl = Join-Path $outputDirectory "$groupLabel.jsonl"
    $screens = Join-Path $outputDirectory "$groupLabel-screens"
    $forms = @($targets | ForEach-Object { [string]$_.reference.form })
    $baseForms = @($targets | ForEach-Object { [string]$_.base.form })
    $enableParents = @($targets | ForEach-Object { [string]$_.authoredPlacement.enableParent } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $runnerArguments = @{
        RuntimeRoot = Resolve-AbsolutePath $RuntimeRoot
        PluginDll = Resolve-AbsolutePath $PluginDll
        OutputPath = $jsonl
        ScreenshotDirectory = $screens
        BatchTargetForm = $forms
        BatchExpectedBaseForm = $baseForms
        BatchEnableParentForm = $enableParents
        BatchMoveToTargets = $true
        BatchSettleFrames = 90
        BatchAdvanceFrames = 3
        PortraitDistance = $PortraitDistance
        CameraShotKind = $CameraShotKind
        FullBodyDistanceScale = $FullBodyDistanceScale
        CaptureAnimation = $true
        RequireAppearanceTelemetry = $true
        SaveFixture = Resolve-AbsolutePath $SaveFixture
        BeforeFrame = 5
        CommandFrame = 10
        AfterFrame = 15
        MaxFrames = [Math]::Max(200, $targets.Count * 140)
        SampleEvery = 1
        TimeoutSeconds = [Math]::Min(300, [Math]::Max(90, 45 + ($targets.Count * 22)))
        BackgroundDataMode = $true
    }
    if ($StageReferences) {
        $runnerArguments.BatchEnableTargets = $true
    }
    $run = & $runner @runnerArguments
    $events = @([System.IO.File]::ReadLines($jsonl) | ForEach-Object {
        ConvertFrom-RetailStateLine $_
    })
    $cameraEvents = @($events | Where-Object { $_.event -eq 'portrait-camera-set' })
    $backBufferEvents = @($events | Where-Object {
        $_.event -eq 'scheduled-backbuffer-capture' -and [bool]$_.accepted
    })
    if ($cameraEvents.Count -ne $targets.Count -or $backBufferEvents.Count -ne $targets.Count -or
        @($cameraEvents | Where-Object { -not [bool]$_.fovSetting.readable }).Count -ne 0) {
        throw "Retail portrait capture omitted live transform, native projection, or FOV-setting telemetry."
    }

    $targetStates = @()
    foreach ($target in $targets) {
        $targetForm = ConvertTo-RetailFormId ([string]$target.reference.form)
        $targetCamera = @($cameraEvents | Where-Object { [uint32]$_.refForm -eq $targetForm })
        $targetBackBuffer = @($backBufferEvents | Where-Object { [uint32]$_.targetForm -eq $targetForm })
        if ($targetCamera.Count -ne 1 -or $targetBackBuffer.Count -ne 1 -or
            $null -eq $targetCamera[0].referenceTransform) {
            throw "Retail portrait state is not uniquely keyed to $($target.id)."
        }

        $geometryStatus = @($events | Where-Object {
            $_.event -eq 'actor-geometry-status' -and [uint32]$_.refForm -eq $targetForm
        })
        $geometry = @($events | Where-Object {
            $_.event -eq 'actor-geometry' -and [uint32]$_.refForm -eq $targetForm -and [bool]$_.complete
        })
        $requiredGeometry = @($geometry | Where-Object {
            ([string]$_.name -eq 'FaceGenFace' -and [int]$_.vertexCount -eq 1211) -or
            ([string]$_.name -eq 'FaceGenHairNoHat' -and [int]$_.vertexCount -gt 0)
        })
        if ($geometryStatus.Count -ne 1 -or [bool]$geometryStatus[0].traversalFault -or
            [int]$geometryStatus[0].pointerReadFailures -ne 0 -or
            [int]$geometryStatus[0].dataReadFailures -ne 0 -or
            [int]$geometryStatus[0].invalidDataLayouts -ne 0 -or
            [int]$geometryStatus[0].vertexReadFailures -ne 0 -or
            [int]$geometryStatus[0].emittedShapes -ne $geometry.Count -or
            $requiredGeometry.Count -ne 2) {
            throw "Retail portrait capture omitted complete final head/hair geometry for $($target.id)."
        }
        if ([string]$target.id -eq 'trudy' -and
            @($requiredGeometry | Where-Object {
                [string]$_.name -eq 'FaceGenHairNoHat' -and [int]$_.vertexCount -eq 962
            }).Count -ne 1) {
            throw 'Retail Trudy hair geometry no longer matches the confirmed 962-vertex runtime mesh.'
        }

        $actorFrames = @($events | Where-Object {
            $_.event -eq 'actor-frame' -and [uint32]$_.refForm -eq $targetForm -and
            [uint32]$_.frame -le [uint32]$targetBackBuffer[0].frame
        } | Sort-Object { [uint32]$_.frame })
        $pose = $actorFrames | Select-Object -Last 1
        if ($null -eq $pose) {
            throw "Retail portrait capture omitted actor pose telemetry for $($target.id)."
        }
        $activeSequences = @($pose.animDataSequences | Where-Object { $null -ne $_ })
        $poseBones = @($pose.bones | Where-Object {
            [string]$_.name -in @(
                'Bip01 L UpperArm', 'Bip01 L Forearm', 'Bip01 R UpperArm', 'Bip01 R Forearm')
        })
        if ($activeSequences.Count -lt 1 -or
            @($activeSequences | Where-Object {
                [string]$_.file -ieq 'Characters\_Male\Locomotion\mtidle.kf'
            }).Count -ne 1 -or
            @($poseBones.name | Select-Object -Unique).Count -ne 4) {
            throw "Retail portrait capture omitted the active idle phase or arm-bone pose for $($target.id)."
        }

        $nativeProjection = $targetBackBuffer[0].projection
        $directProjection = $null -ne $nativeProjection -and
            [bool]$nativeProjection.finite -and [bool]$nativeProjection.perspective -and
            [bool]$nativeProjection.aspectMatchesBackbuffer -and
            [double]$nativeProjection.fovYRadians -gt 0 -and
            [double]$nativeProjection.fovYRadians -lt [Math]::PI -and
            @($nativeProjection.matrix).Count -eq 16
        if ($directProjection) {
            $projection = [pscustomobject][ordered]@{
                status = 'resolved'
                exact = $true
                source = 'd3d9-fixed-function-state'
                confidence = 'direct-runtime'
                fovYRadians = [double]$nativeProjection.fovYRadians
                fovYDegrees = [double]$nativeProjection.fovYRadians * 180.0 / [Math]::PI
                aspect = [double]$nativeProjection.aspect
                matrix = @($nativeProjection.matrix)
                viewport = $targetBackBuffer[0].viewport
            }
        } else {
            $worldFovDegrees = [double]$targetCamera[0].fovSetting.degrees
            if ([double]::IsNaN($worldFovDegrees) -or
                [double]::IsInfinity($worldFovDegrees) -or
                $worldFovDegrees -le 0 -or $worldFovDegrees -ge 180) {
                throw "Retail fDefaultWorldFOV is not a finite perspective angle for $($target.id)."
            }
            $backBufferWidth = [uint32]$targetBackBuffer[0].backbuffer.width
            $backBufferHeight = [uint32]$targetBackBuffer[0].backbuffer.height
            if ($backBufferWidth -lt 1 -or $backBufferHeight -lt 1) {
                throw "Retail portrait backbuffer dimensions are invalid for $($target.id)."
            }
            $aspect = [double]$backBufferWidth / [double]$backBufferHeight
            $fovXRadians = $worldFovDegrees * [Math]::PI / 180.0
            $fovYRadians = 2.0 * [Math]::Atan([Math]::Tan($fovXRadians / 2.0) / $aspect)
            $projection = [pscustomobject][ordered]@{
                status = 'provisional'
                exact = $false
                source = 'retail-ini-setting+native-backbuffer-aspect'
                confidence = 'horizontal-fov-hypothesis'
                fovYRadians = $fovYRadians
                fovYDegrees = $fovYRadians * 180.0 / [Math]::PI
                aspect = $aspect
                matrix = $null
                viewport = $targetBackBuffer[0].viewport
                sourceSetting = [pscustomobject][ordered]@{
                    name = [string]$targetCamera[0].fovSetting.name
                    degrees = $worldFovDegrees
                    interpretation = 'horizontal-hypothesis'
                    collection = [string]$targetCamera[0].fovSetting.source
                }
                directProbe = $nativeProjection
            }
        }

        $targetStates += [pscustomobject][ordered]@{
            schema = 'opennv-retail-actor-shot-state/v1'
            target = [pscustomobject][ordered]@{
                id = [string]$target.id
                referenceForm = [string]$target.reference.form
                baseForm = [string]$target.base.form
            }
            shotKind = $CameraShotKind
            captureFrame = [uint32]$targetBackBuffer[0].frame
            referenceTransform = $targetCamera[0].referenceTransform
            camera = [pscustomobject][ordered]@{
                position = $targetCamera[0].camera
                rotation = $targetCamera[0].rotation
                aim = $targetCamera[0].aim
                distance = $targetCamera[0].cameraDistance
                lineDistance = $targetCamera[0].cameraLineDistance
                projection = $projection
            }
            pose = [pscustomobject][ordered]@{
                frame = $pose.frame
                position = $pose.position
                rotation = $pose.rotation
                footIkAvailable = $pose.footIkAvailable
                footIkEnabled = $pose.footIkEnabled
                activeSequences = @($activeSequences | Select-Object file, state, cycle, weight,
                    frequency, begin, end, last, lastScaled, offset, start, group)
                armBones = @($poseBones | Select-Object name, parentName, runtimeFlags, transform)
            }
            geometry = [pscustomobject][ordered]@{
                status = $geometryStatus[0]
                shapes = @($requiredGeometry | Select-Object name, parentName, runtimeType,
                    vertexCount, fnv1a32, dataBound, measuredBounds, transform)
            }
        }
    }
    $groupRuns += [pscustomobject][ordered]@{
        label = $groupLabel
        cell = $group.Name
        targets = @($targets.id)
        output = $jsonl
        runManifest = $run.runManifest
        screenshots = @($run.screenshots)
        proofCrops = @($run.portraitProofCrops)
        states = $targetStates
    }
    foreach ($target in $targets) {
        $captureByTarget[[string]$target.id] = $jsonl
    }
}

$reportPath = Join-Path $outputDirectory "appearance-differential.json"
$compareArguments = @("--matrix", $matrixFile, "--out", $reportPath)
foreach ($target in $humanoids) {
    $compareArguments += @("--capture", "$($target.id)=$($captureByTarget[[string]$target.id])")
}
& python $comparator @compareArguments
if ($LASTEXITCODE -ne 0) {
    throw "Goodsprings appearance comparator exited with code $LASTEXITCODE."
}
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$humanoidIds = @($humanoids.id)
$failedHumanoids = @($report.rows | Where-Object {
    $_.id -in $humanoidIds -and $_.status -ne "passed"
})
if ($failedHumanoids.Count -gt 0) {
    throw "Goodsprings authored-to-retail differential failed for $($failedHumanoids.Count) humanoid(s)."
}

$allStates = @($groupRuns | ForEach-Object { @($_.states) })
if ($allStates.Count -ne $humanoids.Count) {
    throw "Retail state-contract count does not match the selected target count."
}
$exactProjectionCount = @($allStates | Where-Object { [bool]$_.camera.projection.exact }).Count
$stateContractPath = Join-Path $outputDirectory 'retail-state-contract.json'
$stateContract = [pscustomobject][ordered]@{
    schema = 'opennv-retail-actor-state-contract/v1'
    source = [pscustomobject][ordered]@{
        runtime = 'FalloutNV-1.4.0.525'
        capture = 'xNVSE schedule + native Direct3D 9 backbuffer'
        windowsAppControlUsed = $false
        foregroundInputInjected = $false
    }
    shotKind = $CameraShotKind
    stateCount = $allStates.Count
    exactProjectionCount = $exactProjectionCount
    exactProjectionResolved = $exactProjectionCount -eq $allStates.Count
    states = $allStates
}
[IO.File]::WriteAllText(
    $stateContractPath,
    ($stateContract | ConvertTo-Json -Depth 20),
    [Text.UTF8Encoding]::new($false))

$contactSheet = Join-Path $outputDirectory "retail-contact-sheet.png"
& $contactSheetScript -ManifestPath $reportPath -OutputPath $contactSheet -Columns 4 | Out-Null

[pscustomobject][ordered]@{
    schema = "nikami-fnv-goodsprings-appearance-run/v1"
    runId = $RunId
    cameraShotKind = $CameraShotKind
    portraitDistance = $PortraitDistance
    fullBodyDistanceScale = $FullBodyDistanceScale
    stagedReferences = [bool]$StageReferences
    targetCount = $humanoids.Count
    groupCount = $groups.Count
    passed = $humanoids.Count
    exactProjectionCount = $exactProjectionCount
    exactProjectionResolved = $exactProjectionCount -eq $allStates.Count
    groups = $groupRuns
    report = $reportPath
    stateContract = $stateContractPath
    contactSheet = $contactSheet
    status = "retail-traits-passed-pixels-captured-review-required"
}
