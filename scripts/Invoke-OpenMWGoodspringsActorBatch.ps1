param(
    [Alias('MatrixPath')]
    [string]$RosterPath = "catalog/fnv-goodsprings-actor-roster.json",
    [string]$OutputRoot = "run/openmw-goodsprings-actor-batch",
    [string[]]$TargetId = @(),
    [int]$FirstScreenshotFrame = 180,
    [int]$FramesPerActor = 60,
    [string[]]$SetEnv = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function ConvertTo-FnvRuntimeForm([string]$OpenMwForm) {
    if ($OpenMwForm -notmatch '0x([0-9a-fA-F]+)') {
        return $OpenMwForm
    }
    $value = [Convert]::ToUInt32($Matches[1], 16)
    return ("FormId:0x{0:x}" -f (0x01000000 -bor ($value -band 0x00ffffff)))
}

function ConvertTo-CanonicalForm([string]$Form) {
    if ($Form -notmatch '0x([0-9a-fA-F]+)') { throw "Invalid canonical form id: $Form" }
    return ('0x{0:x8}' -f ([Convert]::ToUInt32($Matches[1], 16) -band 0x00ffffff))
}

function ConvertTo-ActualRuntimeRef([string]$PointerToken) {
    if ($PointerToken -match '^object0x([0-9a-fA-F]+)$') {
        return ('FormId:0x{0:x}' -f [Convert]::ToUInt32($Matches[1], 16))
    }
    return $PointerToken
}

$rosterFile = Resolve-RepoRelativePath $RosterPath
$rosterImporter = Join-Path $PSScriptRoot 'Import-FNVGoodspringsActorRoster.ps1'
if (-not (Test-Path -LiteralPath $rosterImporter -PathType Leaf)) {
    throw "Missing canonical Goodsprings roster importer: $rosterImporter"
}
. $rosterImporter
$outputRootAbs = Resolve-RepoRelativePath $OutputRoot
New-Item -ItemType Directory -Force -Path $outputRootAbs | Out-Null
$canonicalTargets = @(Import-FNVGoodspringsActorRoster -Path $rosterFile)
$rosterSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $rosterFile).Hash.ToLowerInvariant()

$filter = @{}
foreach ($id in $TargetId) {
    if (-not [string]::IsNullOrWhiteSpace($id)) { $filter[$id] = $true }
}
$knownTargetIds = @{}
foreach ($target in $canonicalTargets) { $knownTargetIds[[string]$target.id] = $true }
$unknownTargetIds = @($filter.Keys | Where-Object { -not $knownTargetIds.ContainsKey([string]$_) })
if ($unknownTargetIds.Count -gt 0) {
    throw "Unknown canonical Goodsprings target id(s): $($unknownTargetIds -join ', ')"
}
$targets = @($canonicalTargets | Where-Object { $filter.Count -eq 0 -or $filter.ContainsKey([string]$_.id) })
if ($targets.Count -eq 0) { throw "No Goodsprings actor targets selected." }

# resolveProofActor searches active and inactive WorldModel references. Always
# select the canonical authored reference so stageProofActorForCamera moves that
# exact Ptr into the proof cell. Base forms are expected-base metadata only and
# must never drive primary identity resolution.
$actorForms = @($targets | ForEach-Object { ConvertTo-FnvRuntimeForm ([string]$_.authoredRef) })
$runtimeBaseForms = @($targets | ForEach-Object { ConvertTo-FnvRuntimeForm ([string]$_.base) })
$frames = for ($i = 0; $i -lt $targets.Count; ++$i) { $FirstScreenshotFrame + $i * $FramesPerActor }
$orbits = @($targets | ForEach-Object { 0 })
$distances = @($targets | ForEach-Object {
    if ([string]$_.category -like '*robot') { 400 }
    elseif ([string]$_.category -like '*creature') { 220 }
    else { 200 }
})
$lastFrame = [int]$frames[-1]
# Native capture is completion-driven below, so this is a watchdog rather than
# an assumed 30-fps shutdown time. Heavy actor/material telemetry can reduce
# startup and staging throughput substantially on a full-roster run.
$runSeconds = [Math]::Max(60, [int][Math]::Ceiling($lastFrame / 10.0) + 45)

$env = @(
    "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=1",
    "OPENMW_WORLD_VIEWER_MESH_LOAD_TELEMETRY=1",
    "OPENMW_WORLD_VIEWER_MATERIAL_TELEMETRY=1",
    "OPENMW_FNV_PART_MATRIX_AUDIT=1",
    "OPENMW_PROOF_HIDE_PLAYER_VISUAL=1",
    "OPENMW_WORLD_VIEWER_START_DRY=1",
    # Keep the OpenMW sweep in the same authored Goodsprings proof volume as
    # the retail oracle. Using one transform removes environment and pose drift
    # from the parity comparison; the engine's visibility-ray gate raises the
    # same semantic-front camera when the road crest hides a low creature.
    "OPENMW_WORLD_VIEWER_START_POS_X=-65306.37890625",
    "OPENMW_WORLD_VIEWER_START_POS_Y=-2088.551025390625",
    "OPENMW_WORLD_VIEWER_START_POS_Z=8384",
    "OPENMW_WORLD_VIEWER_START_ROT_X=0",
    "OPENMW_WORLD_VIEWER_START_ROT_Y=0",
    "OPENMW_WORLD_VIEWER_START_ROT_Z=5.639382362365723",
    "OPENMW_PROOF_SAY_FRAME=120",
    "OPENMW_PROOF_SAY_ACTORS=$($actorForms -join ',')",
    "OPENMW_PROOF_STAGE_ACTOR=1",
    "OPENMW_PROOF_ACTOR_STAGE_X=-65306.37890625",
    "OPENMW_PROOF_ACTOR_STAGE_Y=-2088.551025390625",
    "OPENMW_PROOF_ACTOR_STAGE_Z=8384",
    "OPENMW_PROOF_ACTOR_STAGE_ROT_X=0",
    "OPENMW_PROOF_ACTOR_STAGE_ROT_Y=0",
    "OPENMW_PROOF_ACTOR_STAGE_ROT_Z=5.639382362365723",
    "OPENMW_PROOF_SNAP_ACTOR_TO_RENDER_GROUND=1",
    "OPENMW_PROOF_ALIGN_PLAYER_TO_ACTOR=1",
    "OPENMW_PROOF_ACTOR_VIEW_STATIC_CAMERA=1",
    # The actor-frame camera position exposed by retail is the stale third-person
    # camera, not the live portrait transform that produced the proof image.
    # Keep the semantic-front/assembled-bounds camera active for the canonical
    # sweep; replaying that stale position produces a top-down back-side shot.
    "OPENMW_PROOF_ACTOR_VIEW_REPLAY_RETAIL_ABSOLUTE_CAMERA=0",
    "OPENMW_PROOF_ACTOR_VIEW_USE_RENDER_BOUNDS=1",
    "OPENMW_PROOF_ACTOR_VIEW_USE_FACE_BOUNDS=1",
    "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY=1",
    "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_MARGIN=0.04",
    "OPENMW_PROOF_ACTOR_VIEW_MIN_FULL_BODY_SCREEN_WIDTH=0.15",
    "OPENMW_PROOF_ACTOR_VIEW_MIN_FULL_BODY_SCREEN_HEIGHT=0.15",
    "OPENMW_PROOF_ACTOR_VIEW_MIN_FULL_BODY_SCREEN_AREA=0.03",
    # CREA4 spans tiny ravens, humanoid robots, and creatures wider than the old
    # fixed distance. Let the engine fit each assembled render box to the active
    # retail projection instead of baking a species-specific camera table here.
    "OPENMW_PROOF_ACTOR_VIEW_CREATURE_AUTO_FIT=1",
    "OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST=1",
    "OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST_GATE_ONLY=1",
    "OPENMW_PROOF_ACTOR_VIEW_REQUIRE_HUMAN_POSE=1",
    "OPENMW_PROOF_ACTOR_VIEW_USE_ACTOR_FACING=1",
    "OPENMW_PROOF_ACTOR_VIEW_USE_HEAD_POSE_AXIS=1",
    "OPENMW_PROOF_ACTOR_VIEW_FRONT_DISTANCE=150",
    "OPENMW_PROOF_ACTOR_VIEW_FRONT_DISTANCES=$($distances -join ',')",
    "OPENMW_PROOF_ACTOR_VIEW_OFFSET_Z=120",
    "OPENMW_PROOF_ACTOR_VIEW_TARGET_Z=120",
    "OPENMW_PROOF_ACTOR_VIEW_ORBIT_DEGREES=$($orbits -join ',')",
    "OPENMW_PROOF_ACTOR_BATCH_WARMUP_FRAMES=30",
    # Enumerate the exact groups assembled for each authored actor. The engine
    # plays those names verbatim and gates capture on completion; no shared
    # pose aliases, forced draw state, or fabricated gameplay actions enter the
    # proof.
    "OPENMW_PROOF_ACTOR_POSE_ALL_AVAILABLE=1",
    "OPENMW_PROOF_ACTOR_POSE_START_DELAY_FRAMES=1",
    "OPENMW_PROOF_ACTOR_POSE_FRAMES=1",
    "OPENMW_PROOF_REQUIRE_ACTOR_FOR_SCREENSHOT=1",
    "OPENMW_PROOF_ACTOR_RESOLVE_RETRY_FRAMES=1"
) + @($SetEnv)

$runner = Join-Path $PSScriptRoot "Invoke-RealWorldScreenshots.ps1"
Write-Host "Capturing $($targets.Count) Goodsprings actors in one OpenMW process."
$runnerOutput = @(& $runner `
    -WorldId fallout_new_vegas `
    -Mode flat `
    -NoCatalogStart `
    -SkipMenu `
    -StartCell Goodsprings `
    -OutputRoot $outputRootAbs `
    -RunSeconds $runSeconds `
    -CaptureSeconds 1 `
    -EngineScreenshotFrames ($frames -join ',') `
    -ExpectedScreenshotCount $targets.Count `
    -NativeScreenshotWaitSeconds $runSeconds `
    -CrashReportSettleSeconds 1 `
    -ExtraArgs "--no-sound" `
    -SetEnv $env)

$last = $runnerOutput[-1]
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $rosterFile).Hash.ToLowerInvariant() -ne $rosterSha256) {
    throw 'Canonical Goodsprings roster changed during OpenMW capture.'
}
$outputDirectory = [string]$last.outputDirectory
$manifestPath = Join-Path $outputDirectory "manifest.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$screenshots = @($manifest.screenshots)
if ($screenshots.Count -ne $targets.Count) {
    throw "OpenMW screenshot contract expected exactly $($targets.Count) screenshots; captured $($screenshots.Count)."
}

function ConvertTo-NormalizedPathKey([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return [System.IO.Path]::GetFullPath(($Path -replace '/', '\')).ToLowerInvariant()
}

# The runner deliberately harvests every native screenshot at the end of the
# one-process run. Do not pair those files by copied filename: the copied names
# all share one capture second and lexical ordering drifts at n10/n2. Instead,
# join the engine's frame->native-path log records to manifest.nativePath.
$captureRecords = New-Object System.Collections.Generic.List[object]
$pendingCaptures = [System.Collections.Generic.Queue[object]]::new()
$actualActorByIndex = @{}
$currentActorIndex = $null
foreach ($line in [System.IO.File]::ReadLines([string]$last.logPath)) {
    if ($line -match 'proof batch: selected actor index=([0-9]+) target="([^"]+)"') {
        $currentActorIndex = [int]$Matches[1]
        if ($currentActorIndex -lt 0 -or $currentActorIndex -ge $targets.Count) {
            throw "OpenMW selected an out-of-contract actor index: $currentActorIndex"
        }
        continue
    }
    if ($null -ne $currentActorIndex -and
        $line -match 'proof: staged actor target="[^"]+".* ptr=(object(?:0x[0-9a-fA-F]+|@0x[0-9a-fA-F]+)) \(') {
        if (-not $actualActorByIndex.ContainsKey($currentActorIndex)) {
            $actualActorByIndex[$currentActorIndex] = ConvertTo-ActualRuntimeRef ([string]$Matches[1])
        }
        continue
    }
    if ($line -match 'queuing GUI-inclusive native screenshot at frame ([0-9]+)') {
        if ($null -eq $currentActorIndex) {
            throw "OpenMW queued a screenshot before selecting a canonical proof actor."
        }
        $pendingCaptures.Enqueue([pscustomobject][ordered]@{
            actualFrame = [int]$Matches[1]
            actorIndex = [int]$currentActorIndex
        })
        continue
    }
    if ($line -match '(?<path>[A-Za-z]:[\\/].*?screenshot[0-9]+\.(?:png|jpg|jpeg|tga|bmp)) has been saved') {
        if ($pendingCaptures.Count -eq 0) {
            throw "OpenMW saved a native screenshot without a preceding keyed frame record: $($Matches.path)"
        }
        $pendingCapture = $pendingCaptures.Dequeue()
        $captureRecords.Add([pscustomobject][ordered]@{
            actualFrame = [int]$pendingCapture.actualFrame
            actorIndex = [int]$pendingCapture.actorIndex
            nativePath = [System.IO.Path]::GetFullPath(($Matches.path -replace '/', '\'))
        }) | Out-Null
    }
}
if ($pendingCaptures.Count -ne 0 -or $captureRecords.Count -ne $targets.Count) {
    throw "OpenMW frame/path telemetry expected exactly $($targets.Count) complete records; found $($captureRecords.Count) complete and $($pendingCaptures.Count) unsaved."
}
if ($actualActorByIndex.Count -ne $targets.Count) {
    $missingActorIndices = @(0..($targets.Count - 1) | Where-Object { -not $actualActorByIndex.ContainsKey($_) })
    throw "OpenMW actor identity telemetry expected $($targets.Count) staged actors; found $($actualActorByIndex.Count). Missing indices: $($missingActorIndices -join ', ')."
}

$screenshotByNativePath = @{}
foreach ($screenshot in $screenshots) {
    if ([string]$screenshot.source -ne 'openmw-native-screenshot') {
        throw "OpenMW actor batch requires native screenshots; found source '$($screenshot.source)'."
    }
    $key = ConvertTo-NormalizedPathKey ([string]$screenshot.nativePath)
    if ([string]::IsNullOrWhiteSpace($key) -or $screenshotByNativePath.ContainsKey($key)) {
        throw "OpenMW screenshot manifest contains a missing or duplicate native-path key: $($screenshot.nativePath)"
    }
    $screenshotByNativePath[$key] = $screenshot
}

$seenActualFrames = @{}
$previousActualFrame = $null
$rows = for ($i = 0; $i -lt $targets.Count; ++$i) {
    $requestedFrame = [int]$frames[$i]
    $captureRecord = $captureRecords[$i]
    $actualFrame = [int]$captureRecord.actualFrame
    if ([int]$captureRecord.actorIndex -ne $i) {
        throw "OpenMW screenshot actor-order mismatch for $($targets[$i].id): expected actor index $i, queued index $($captureRecord.actorIndex)."
    }
    if ($actualFrame -lt $requestedFrame) {
        throw "OpenMW screenshot was queued before its requested frame for $($targets[$i].id): requested $requestedFrame, queued $actualFrame."
    }
    if ($seenActualFrames.ContainsKey($actualFrame)) {
        throw "OpenMW screenshot frame $actualFrame was ambiguously reused by $($targets[$i].id) and $($seenActualFrames[$actualFrame])."
    }
    if ($null -ne $previousActualFrame -and $actualFrame -le [int]$previousActualFrame) {
        throw "OpenMW screenshot frames are nonmonotonic for $($targets[$i].id): previous $previousActualFrame, queued $actualFrame."
    }
    if ($i + 1 -lt $targets.Count -and $actualFrame -ge [int]$frames[$i + 1]) {
        throw "OpenMW screenshot crossed into the next actor window for $($targets[$i].id): queued $actualFrame, next window starts $($frames[$i + 1])."
    }
    $seenActualFrames[$actualFrame] = [string]$targets[$i].id
    $previousActualFrame = $actualFrame
    $frameDrift = $actualFrame - $requestedFrame
    $nativePathKey = ConvertTo-NormalizedPathKey ([string]$captureRecord.nativePath)
    if (-not $screenshotByNativePath.ContainsKey($nativePathKey)) {
        throw "OpenMW screenshot manifest has no entry for logged native path: $($captureRecord.nativePath)"
    }
    $screenshot = $screenshotByNativePath[$nativePathKey]
    $authoredRef = ConvertTo-CanonicalForm ([string]$targets[$i].authoredRef)
    $authoredRuntimeRef = ConvertTo-FnvRuntimeForm ([string]$targets[$i].authoredRef)
    $actualRuntimeRef = [string]$actualActorByIndex[$i]
    $identityMatchesAuthored = [string]::Equals(
        $actualRuntimeRef, $authoredRuntimeRef, [System.StringComparison]::OrdinalIgnoreCase)
    $identityMode = if ($identityMatchesAuthored) { 'authored-reference' }
        elseif ($actualRuntimeRef.StartsWith('object@', [System.StringComparison]::OrdinalIgnoreCase)) {
            'unexpected-synthetic-reference'
        }
        else { 'unexpected-reference-mismatch' }
    [pscustomobject][ordered]@{
        index = $i + 1
        captureId = ('{0}::front-full-body' -f [string]$targets[$i].id)
        targetId = [string]$targets[$i].id
        id = [string]$targets[$i].id
        category = [string]$targets[$i].category
        authoredRef = $authoredRef
        actualRuntimeRef = $actualRuntimeRef
        reference = $authoredRuntimeRef
        base = ConvertTo-CanonicalForm ([string]$targets[$i].base)
        runtimeBase = $runtimeBaseForms[$i]
        identityMode = $identityMode
        identityMatchesAuthored = $identityMatchesAuthored
        shotKind = 'front-full-body'
        requestedFrame = $requestedFrame
        actualFrame = $actualFrame
        frameDrift = $frameDrift
        screenshotFrame = $actualFrame
        screenshot = [string]$screenshot.path
        screenshotNativePath = [string]$screenshot.nativePath
    }
}
$identityFailures = @($rows | Where-Object { -not $_.identityMatchesAuthored })
if ($identityFailures.Count -gt 0) {
    throw "OpenMW authored-reference identity contract failed for: $($identityFailures.targetId -join ', ')"
}

$indexPath = Join-Path $outputRootAbs "batch-index.json"
[pscustomobject][ordered]@{
    schema = "nikami-openmw-goodsprings-actor-batch/v2"
    createdAt = (Get-Date).ToString("o")
    processCount = 1
    canonicalRoster = $rosterFile
    canonicalRosterSha256 = $rosterSha256
    identityMode = 'authored-reference'
    canonicalShotKind = 'front-full-body'
    manifest = $manifestPath
    log = [string]$last.logPath
    rows = @($rows)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $indexPath -Encoding UTF8

[pscustomobject][ordered]@{
    index = $indexPath
    count = $targets.Count
    screenshots = $screenshots.Count
    processCount = 1
    status = [string]$last.status
}
