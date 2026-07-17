param(
    [Alias('MatrixPath')]
    [string]$RosterPath = "catalog/fnv-goodsprings-actor-roster.json",
    [string]$RuntimeRoot = "local/xnvse-retail-oracle",
    [string]$PluginDll = "local/xnvse-retail-oracle/plugins/nvse_retail_oracle.dll",
    [string]$SaveFixture = "run/retail-oracle/checkpoints/NikamiOracleEasyPeteSeated.fos",
    [string]$RunId = ("fnv-goodsprings-full-telemetry-" + (Get-Date -Format "yyyyMMdd-HHmmss")),
    [string]$OutputRoot = "run/retail-oracle",
    [int]$SampleEvery = 30,
    [int]$BatchSettleFrames = 90,
    [int]$TimeoutSeconds = 300,
    [switch]$VisibleGame
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

function Convert-FormId([string]$Form) {
    if ($Form -match '^0[xX]([0-9a-fA-F]+)$') {
        return [Convert]::ToUInt32($Matches[1], 16)
    }
    return [Convert]::ToUInt32($Form, 10)
}

$rosterFile = Resolve-AbsolutePath $RosterPath
$rosterImporter = Join-Path $PSScriptRoot 'Import-FNVGoodspringsActorRoster.ps1'
$runner = Join-Path $PSScriptRoot 'Invoke-FNVRetailOracle.ps1'
$contactSheetScript = Join-Path $PSScriptRoot 'New-ScreenshotContactSheet.ps1'
foreach ($required in @($rosterFile, $rosterImporter, (Resolve-AbsolutePath $PluginDll),
        (Resolve-AbsolutePath $SaveFixture), $runner, $contactSheetScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing Goodsprings full-telemetry dependency: $required"
    }
}
if ($SampleEvery -lt 1 -or $BatchSettleFrames -lt 1) {
    throw 'SampleEvery and BatchSettleFrames must be positive.'
}

. $rosterImporter
$rosterDocument = Get-Content -LiteralPath $rosterFile -Raw | ConvertFrom-Json
if ($null -eq $rosterDocument.retailProofVolume) {
    throw 'Canonical Goodsprings roster does not declare retailProofVolume.'
}
$proofVolume = $rosterDocument.retailProofVolume
$proofTargetPosition = @($proofVolume.targetPosition)
$proofPlayerPosition = @($proofVolume.playerParkingPosition)
if ([string]$proofVolume.mode -ne 'authored-reference-shared-exterior' -or
    $proofTargetPosition.Count -ne 3 -or $proofPlayerPosition.Count -ne 3 -or
    $null -eq $proofVolume.minimumCameraHeightAboveSurface -or
    $null -eq $proofVolume.minimumAimHeightAboveSurface -or
    [float]$proofVolume.minimumCameraHeightAboveSurface -lt
        [float]$proofVolume.minimumAimHeightAboveSurface -or
    [string]::IsNullOrWhiteSpace([string]$proofVolume.anchorRef)) {
    throw 'Canonical Goodsprings retailProofVolume is incomplete or uses an unsupported mode.'
}
$targets = @(Import-FNVGoodspringsActorRoster -Path $rosterFile)
$rosterSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $rosterFile).Hash.ToLowerInvariant()
$targetForms = @($targets | ForEach-Object { [string]$_.authoredRef })
$baseForms = @($targets | ForEach-Object { [string]$_.base })

$outputDirectory = Resolve-AbsolutePath (Join-Path $OutputRoot $RunId)
if (Test-Path -LiteralPath $outputDirectory) {
    throw "Refusing to overwrite an existing Goodsprings telemetry run: $outputDirectory"
}
New-Item -ItemType Directory -Path $outputDirectory | Out-Null
$jsonl = Join-Path $outputDirectory 'retail-all-actors.jsonl'
$screens = Join-Path $outputDirectory 'screenshots'
# The runner timeout is the wall-clock authority. A count-derived frame cap
# previously ended an otherwise live 300-second run after only ~107 seconds
# when one target stalled. Keep a very generous frame guard so it cannot
# preempt any sane retail frame rate; strict 37/37 validation still rejects a
# timeout or an explicitly incomplete runtime event.
$expectedCaptureFrames = $targets.Count * ($BatchSettleFrames + 60)
$wallClockFrameGuard = $TimeoutSeconds * 1000
$maxFrames = [Math]::Max(600, [Math]::Max($expectedCaptureFrames, $wallClockFrameGuard))
$enableParents = @(
    @($targets | ForEach-Object { [string]$_.enableParent } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    '0x105d4c'
    '0x11d9a5'
) | Select-Object -Unique

# This is deliberately one runner invocation and therefore one FalloutNV.exe
# process. Every real authored reference is activated, moved into the same
# roster-proven exterior volume, captured, and released before the next target.
# No synthetic reference is created and no inventory item is substituted.
$run = & $runner `
    -RuntimeRoot (Resolve-AbsolutePath $RuntimeRoot) `
    -PluginDll (Resolve-AbsolutePath $PluginDll) `
    -OutputPath $jsonl `
    -ScreenshotDirectory $screens `
    -BatchTargetForm $targetForms `
    -BatchExpectedBaseForm $baseForms `
    -BatchEnableParentForm $enableParents `
    -BatchEnableTargets `
    -BatchProofStaging `
    -BatchProofAnchorForm ([string]$proofVolume.anchorRef) `
    -BatchProofTargetX ([float]$proofTargetPosition[0]) `
    -BatchProofTargetY ([float]$proofTargetPosition[1]) `
    -BatchProofTargetZ ([float]$proofTargetPosition[2]) `
    -BatchProofTargetYaw ([float]$proofVolume.targetYawRadians) `
    -BatchProofPlayerX ([float]$proofPlayerPosition[0]) `
    -BatchProofPlayerY ([float]$proofPlayerPosition[1]) `
    -BatchProofPlayerZ ([float]$proofPlayerPosition[2]) `
    -BatchProofMinimumCameraHeight ([float]$proofVolume.minimumCameraHeightAboveSurface) `
    -BatchProofMinimumAimHeight ([float]$proofVolume.minimumAimHeightAboveSurface) `
    -BatchProofInitializationFrames ([int]$proofVolume.initializationFrames) `
    -BatchProofTargetSettleFrames ([int]$proofVolume.targetSettleFrames) `
    -BatchSettleFrames $BatchSettleFrames `
    -BatchAdvanceFrames 3 `
    -PortraitDistance 110 `
    -CameraShotKind front-full-body `
    -FullBodyDistanceScale 1.6 `
    -BatchForceWeaponOut `
    -BatchWeaponProbeFrames 12 `
    -SaveFixture (Resolve-AbsolutePath $SaveFixture) `
    -BeforeFrame 5 `
    -CommandFrame 10 `
    -AfterFrame 15 `
    -MaxFrames $maxFrames `
    -SampleEvery $SampleEvery `
    -TimeoutSeconds $TimeoutSeconds `
    -VisibleGame:$VisibleGame `
    -BackgroundDataMode `
    -CaptureAnimation

if ((Get-FileHash -Algorithm SHA256 -LiteralPath $rosterFile).Hash.ToLowerInvariant() -ne $rosterSha256) {
    throw 'Canonical Goodsprings roster changed during retail capture.'
}
$capturedScreenshots = @($run.screenshots)
if ($capturedScreenshots.Count -ne $targets.Count) {
    throw "Retail screenshot contract expected exactly $($targets.Count) screenshots; captured $($capturedScreenshots.Count)."
}
$screenshotByReference = @{}
foreach ($screenshotPath in $capturedScreenshots) {
    $leaf = [System.IO.Path]::GetFileName([string]$screenshotPath)
    if ($leaf -notmatch '^frame-target-([0-9a-fA-F]{8})\.bmp$') {
        throw "Retail screenshot does not carry a target-form key: $screenshotPath"
    }
    $key = [Convert]::ToUInt32($Matches[1], 16)
    if ($screenshotByReference.ContainsKey($key)) {
        throw ("Retail screenshot contract produced duplicate target key 0x{0:x8}." -f $key)
    }
    $screenshotByReference[$key] = [System.IO.Path]::GetFullPath([string]$screenshotPath)
}

$screenshotEvents = @($run.validation.screenshots)
if ($screenshotEvents.Count -ne $targets.Count) {
    throw "Retail screenshot telemetry expected exactly $($targets.Count) keyed events; captured $($screenshotEvents.Count)."
}
$screenshotEventByReference = @{}
foreach ($screenshotEvent in $screenshotEvents) {
    $key = Convert-FormId ([string]$screenshotEvent.targetForm)
    if ($screenshotEventByReference.ContainsKey($key)) {
        throw ("Retail screenshot telemetry produced duplicate target key 0x{0:x8}." -f $key)
    }
    $screenshotEventByReference[$key] = $screenshotEvent
}

$eventStatsByReference = @{}
foreach ($line in [System.IO.File]::ReadLines($jsonl)) {
    if ($line -notmatch '"event":"(?<event>npc-appearance|target-appearance|portrait-camera-set|batch-weapon-state|actor-frame|actor-geometry|actor-geometry-status|actor-geometry-node-status|actor-geometry-fault|capture-fault)"') { continue }
    $event = [string]$Matches.event
    # Read only the top-level keys; actor-geometry can carry a very large vertex
    # array and must not be deserialized merely to count its target record.
    if ($line -notmatch '"refForm":(?<refForm>[0-9]+)') { continue }
    $referenceKey = [uint32]$Matches.refForm
    if (-not $eventStatsByReference.ContainsKey($referenceKey)) {
        $eventStatsByReference[$referenceKey] = [ordered]@{
            appearanceEvents = 0
            portraitEvents = 0
            actorFrames = 0
            geometryShapes = 0
            geometrySummaryEvents = 0
            geometryStatusEvents = 0
            geometryPointerReadFailures = 0
            geometryDataReadFailures = 0
            geometryInvalidDataLayouts = 0
            geometryVertexReadFailures = 0
            geometryTraversalFaults = 0
            captureFaults = 0
            cameraFocusKind = $null
            cameraShotKind = $null
            cameraBoundValid = $false
            cameraBoundRadius = 0.0
            weaponStateEvents = 0
            weaponStateStatus = $null
            weaponRequired = $false
            weaponForm = 0
            weaponOut = $false
        }
    }
    $stats = $eventStatsByReference[$referenceKey]
    switch ($event) {
        { $_ -in @('npc-appearance', 'target-appearance') } { ++$stats.appearanceEvents; break }
        'portrait-camera-set' {
            ++$stats.portraitEvents
            if ($line -match '"focusKind":"(?<focusKind>[^"]+)"') {
                $stats.cameraFocusKind = [string]$Matches.focusKind
            }
            if ($line -match '"shotKind":"(?<shotKind>[^"]+)"') {
                $stats.cameraShotKind = [string]$Matches.shotKind
            }
            if ($line -match '"worldBound":\{"valid":(?<valid>true|false),(?:"source":"[^"]+",)?"center":\[[^\]]+\],"radius":(?<radius>[-+0-9.eE]+)') {
                $stats.cameraBoundValid = [string]$Matches.valid -eq 'true'
                $stats.cameraBoundRadius = [double]::Parse(
                    [string]$Matches.radius, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            break
        }
        'batch-weapon-state' {
            ++$stats.weaponStateEvents
            if ($line -match '"status":"(?<status>[^"]+)"') {
                $stats.weaponStateStatus = [string]$Matches.status
            }
            if ($line -match '"weaponRequired":(?<required>true|false)') {
                $stats.weaponRequired = [string]$Matches.required -eq 'true'
            }
            if ($line -match '"weaponForm":(?<form>[0-9]+)') {
                $stats.weaponForm = [uint32]$Matches.form
            }
            if ($line -match '"weaponOut":(?<out>true|false)') {
                $stats.weaponOut = [string]$Matches.out -eq 'true'
            }
            break
        }
        'actor-frame' { ++$stats.actorFrames; break }
        'actor-geometry' { ++$stats.geometryShapes; break }
        'actor-geometry-status' {
            ++$stats.geometrySummaryEvents
            ++$stats.geometryStatusEvents
            foreach ($counter in @(
                @{ Json = 'pointerReadFailures'; Stat = 'geometryPointerReadFailures' }
                @{ Json = 'dataReadFailures'; Stat = 'geometryDataReadFailures' }
                @{ Json = 'invalidDataLayouts'; Stat = 'geometryInvalidDataLayouts' }
                @{ Json = 'vertexReadFailures'; Stat = 'geometryVertexReadFailures' }
            )) {
                if ($line -match ('"' + $counter.Json + '":(?<count>[0-9]+)')) {
                    $stats[$counter.Stat] += [int]$Matches.count
                }
            }
            if ($line -match '"traversalFault":true') { ++$stats.geometryTraversalFaults }
            break
        }
        { $_ -in @('actor-geometry-node-status', 'actor-geometry-fault') } {
            ++$stats.geometryStatusEvents
            break
        }
        'capture-fault' { ++$stats.captureFaults; break }
    }
}
$rows = foreach ($target in $targets) {
    $reference = Convert-FormId ([string]$target.authoredRef)
    $base = Convert-FormId ([string]$target.base)
    if (-not $screenshotByReference.ContainsKey($reference) -or
        -not $screenshotEventByReference.ContainsKey($reference)) {
        throw ("Retail screenshot contract is missing target key 0x{0:x8} ({1})." -f $reference, $target.id)
    }
    $shotEvent = $screenshotEventByReference[$reference]
    $stats = if ($eventStatsByReference.ContainsKey($reference)) {
        $eventStatsByReference[$reference]
    }
    else {
        [ordered]@{
            appearanceEvents = 0; portraitEvents = 0; actorFrames = 0; geometryShapes = 0
            geometrySummaryEvents = 0; geometryStatusEvents = 0
            geometryPointerReadFailures = 0; geometryDataReadFailures = 0
            geometryInvalidDataLayouts = 0; geometryVertexReadFailures = 0
            geometryTraversalFaults = 0
            captureFaults = 0; cameraFocusKind = $null; cameraShotKind = $null
            cameraBoundValid = $false; cameraBoundRadius = 0.0
            weaponStateEvents = 0; weaponStateStatus = $null; weaponRequired = $false
            weaponForm = 0; weaponOut = $false
        }
    }
    $authoredRef = ('0x{0:x8}' -f $reference)
    $baseForm = ('0x{0:x8}' -f $base)
    [pscustomobject][ordered]@{
        captureId = ('{0}::front-full-body' -f [string]$target.id)
        targetId = [string]$target.id
        id = [string]$target.id
        category = [string]$target.category
        authoredRef = $authoredRef
        actualRuntimeRef = $authoredRef
        reference = $authoredRef
        base = $baseForm
        expectedBase = $baseForm
        identityMode = 'authored-reference'
        shotKind = 'front-full-body'
        requestedFrame = [int]$shotEvent.frame
        actualFrame = [int]$shotEvent.frame
        screenshot = [string]$screenshotByReference[$reference]
        appearanceEvents = [int]$stats.appearanceEvents
        portraitEvents = [int]$stats.portraitEvents
        actorFrames = [int]$stats.actorFrames
        geometryShapes = [int]$stats.geometryShapes
        geometrySummaryEvents = [int]$stats.geometrySummaryEvents
        geometryStatusEvents = [int]$stats.geometryStatusEvents
        geometryPointerReadFailures = [int]$stats.geometryPointerReadFailures
        geometryDataReadFailures = [int]$stats.geometryDataReadFailures
        geometryInvalidDataLayouts = [int]$stats.geometryInvalidDataLayouts
        geometryVertexReadFailures = [int]$stats.geometryVertexReadFailures
        geometryTraversalFaults = [int]$stats.geometryTraversalFaults
        captureFaults = [int]$stats.captureFaults
        cameraFocusKind = $stats.cameraFocusKind
        cameraShotKind = $stats.cameraShotKind
        cameraBoundValid = [bool]$stats.cameraBoundValid
        cameraBoundRadius = [double]$stats.cameraBoundRadius
        weaponStateEvents = [int]$stats.weaponStateEvents
        weaponStateStatus = $stats.weaponStateStatus
        weaponRequired = [bool]$stats.weaponRequired
        weaponForm = ('0x{0:x8}' -f [uint32]$stats.weaponForm)
        weaponOut = [bool]$stats.weaponOut
        passed = $stats.appearanceEvents -eq 1 -and $stats.portraitEvents -eq 1 -and
            $stats.cameraShotKind -eq 'front-full-body' -and $stats.cameraBoundValid -and
            $stats.cameraBoundRadius -gt 0 -and $stats.weaponStateEvents -eq 1 -and
            $stats.weaponStateStatus -in @('passed', 'not-applicable') -and
            (-not $stats.weaponRequired -or ($stats.weaponOut -and $stats.weaponForm -ne 0)) -and
            $stats.actorFrames -ge 2 -and $stats.geometryShapes -ge 1 -and
            $stats.geometrySummaryEvents -ge 1 -and $stats.geometryPointerReadFailures -eq 0 -and
            $stats.geometryDataReadFailures -eq 0 -and $stats.geometryInvalidDataLayouts -eq 0 -and
            $stats.geometryVertexReadFailures -eq 0 -and $stats.geometryTraversalFaults -eq 0 -and
            $stats.captureFaults -eq 0
    }
}
$failed = @($rows | Where-Object { -not $_.passed })
$contactSheet = Join-Path $outputDirectory 'retail-contact-sheet.png'
& $contactSheetScript -ManifestPath $run.runManifest -OutputPath $contactSheet -Columns 5 | Out-Null
$oracleRunManifestDocument = Get-Content -LiteralPath $run.runManifest -Raw | ConvertFrom-Json
if ($null -eq $oracleRunManifestDocument.evidence -or
    $null -eq $oracleRunManifestDocument.evidence.capture -or
    @($oracleRunManifestDocument.evidence.screenshots).Count -ne $targets.Count) {
    throw 'Retail oracle run manifest lacks complete immutable capture evidence.'
}

$telemetryManifest = [pscustomobject][ordered]@{
    schema = 'nikami-fnv-goodsprings-full-telemetry/v2'
    runId = $RunId
    processCount = 1
    passiveCapture = $false
    captureStaging = 'real-authored-reference-shared-proof-volume'
    retailProofVolume = $proofVolume
    canonicalShotKind = 'front-full-body'
    canonicalRoster = $rosterFile
    canonicalRosterSha256 = $rosterSha256
    targetCount = $targets.Count
    sampleEvery = $SampleEvery
    batchSettleFrames = $BatchSettleFrames
    maxFrames = $maxFrames
    jsonl = $jsonl
    oracleManifest = $run.runManifest
    contactSheet = $contactSheet
    evidence = $oracleRunManifestDocument.evidence
    screenshots = @($rows | ForEach-Object {
        [pscustomobject][ordered]@{
            captureId = $_.captureId
            targetId = $_.targetId
            authoredRef = $_.authoredRef
            actualRuntimeRef = $_.actualRuntimeRef
            base = $_.base
            identityMode = $_.identityMode
            shotKind = $_.shotKind
            requestedFrame = $_.requestedFrame
            actualFrame = $_.actualFrame
            path = $_.screenshot
        }
    })
    oracleScreenshots = @($run.screenshots)
    rows = @($rows)
    failed = @($failed | ForEach-Object { $_.id })
}
$telemetryManifestPath = Join-Path $outputDirectory 'full-telemetry-manifest.json'
[System.IO.File]::WriteAllText(
    $telemetryManifestPath,
    ($telemetryManifest | ConvertTo-Json -Depth 8),
    [System.Text.UTF8Encoding]::new($false))
if ($failed.Count -gt 0) {
    throw "Goodsprings full retail telemetry is incomplete for $($failed.Count) target(s): $($failed.id -join ', ')"
}

[pscustomobject][ordered]@{
    schema = 'nikami-fnv-goodsprings-full-telemetry-run/v2'
    runId = $RunId
    targetCount = $targets.Count
    processCount = 1
    output = $jsonl
    manifest = $telemetryManifestPath
    contactSheet = $contactSheet
    screenshots = @($run.screenshots)
    status = 'retail-canonical-full-body-telemetry-complete'
}
