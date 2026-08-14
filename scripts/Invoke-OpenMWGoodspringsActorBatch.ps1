param(
    [Alias('MatrixPath')]
    [string]$RosterPath = "catalog/fnv-goodsprings-actor-roster.json",
    [string]$OutputRoot = "run/openmw-goodsprings-actor-batch",
    [string[]]$TargetId = @(),
    [int]$FirstScreenshotFrame = 180,
    [int]$FramesPerActor = 60,
    [string[]]$SetEnv = @(),
    [switch]$MeshExportOnly,
    [switch]$SkeletalExportOnly,
    [string]$MeshExportRoot = "",
    [string]$BinaryRoot = ""
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
    # Canonical compiler IDs use a zero-based load-order index in the high
    # byte. OpenMW reserves runtime index zero, so retain the plugin identity
    # and shift that index by one instead of forcing every ref into FalloutNV.
    $canonicalIndex = ([uint64]$value -shr 24) -band 0xff
    $runtimeIndex = $canonicalIndex + 1
    if ($runtimeIndex -gt 0xff) { throw "Runtime plugin index overflow: $OpenMwForm" }
    $runtimeValue = (($runtimeIndex -shl 24) -bor ([uint64]$value -band 0x00ffffff))
    return ("FormId:0x{0:x}" -f $runtimeValue)
}

function ConvertTo-CanonicalForm([string]$Form) {
    if ($Form -notmatch '0x([0-9a-fA-F]+)') { throw "Invalid canonical form id: $Form" }
    return ('0x{0:x8}' -f [Convert]::ToUInt32($Matches[1], 16))
}

function ConvertTo-ActualRuntimeRef([string]$PointerToken) {
    if ($PointerToken -match '^object0x([0-9a-fA-F]+)$') {
        return ('FormId:0x{0:x}' -f [Convert]::ToUInt32($Matches[1], 16))
    }
    return $PointerToken
}

if ((ConvertTo-FnvRuntimeForm '0x00000001') -ne 'FormId:0x1000001' -or
    (ConvertTo-FnvRuntimeForm '0x0400bf34') -ne 'FormId:0x500bf34' -or
    (ConvertTo-CanonicalForm '0x0400bf34') -ne '0x0400bf34') {
    throw 'Canonical/OpenNV load-order FormID mapping self-test failed.'
}

$rosterFile = Resolve-RepoRelativePath $RosterPath
$rosterImporter = Join-Path $PSScriptRoot 'Import-FNVGoodspringsActorRoster.ps1'
if (-not (Test-Path -LiteralPath $rosterImporter -PathType Leaf)) {
    throw "Missing canonical Goodsprings roster importer: $rosterImporter"
}
$outputRootAbs = Resolve-RepoRelativePath $OutputRoot
New-Item -ItemType Directory -Force -Path $outputRootAbs | Out-Null
$rosterDocument = Get-Content -LiteralPath $rosterFile -Raw | ConvertFrom-Json
if ([string]$rosterDocument.schema -eq 'nikami-fnv-actor-roster/v1') {
    $canonicalTargets = @($rosterDocument.targets)
    if ([int]$rosterDocument.targetCount -ne $canonicalTargets.Count -or $canonicalTargets.Count -lt 1) {
        throw "Dynamic actor roster count mismatch: declared $($rosterDocument.targetCount), found $($canonicalTargets.Count)."
    }
} else {
    . $rosterImporter
    $canonicalTargets = @(Import-FNVGoodspringsActorRoster -Path $rosterFile)
}
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
if ($MeshExportOnly -or $SkeletalExportOnly) {
    # A complex facegen/skeleton can legitimately spend much longer than one
    # scheduled frame resolving its post-skin drawable. Keep this a watchdog,
    # not a false failure that discards a nearly complete mesh-only batch.
    $runSeconds = [Math]::Max(1200, $runSeconds)
}

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

if ($MeshExportOnly -or $SkeletalExportOnly) {
    if ([string]::IsNullOrWhiteSpace($MeshExportRoot)) {
        $MeshExportRoot = Join-Path $outputRootAbs 'meshes'
    }
    $meshRootAbs = Resolve-RepoRelativePath $MeshExportRoot
    New-Item -ItemType Directory -Path $meshRootAbs -Force | Out-Null

    # Several legacy portrait switches test getenv() rather than their parsed
    # boolean value, so appending '=0' still activates them. Strip them from a
    # data-only run; retain alignment solely to drive one post-cull frame.
    $dataOnlyPortraitPrefixes = @(
        'OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=',
        'OPENMW_WORLD_VIEWER_MESH_LOAD_TELEMETRY=',
        'OPENMW_WORLD_VIEWER_MATERIAL_TELEMETRY=',
        'OPENMW_FNV_PART_MATRIX_AUDIT=',
        'OPENMW_PROOF_SNAP_ACTOR_TO_RENDER_GROUND=',
        'OPENMW_PROOF_ACTOR_VIEW_FULL_BODY=',
        'OPENMW_PROOF_ACTOR_VIEW_USE_RENDER_BOUNDS=',
        'OPENMW_PROOF_ACTOR_VIEW_USE_FACE_BOUNDS=',
        'OPENMW_PROOF_ACTOR_VIEW_MIN_FULL_BODY_SCREEN_WIDTH=',
        'OPENMW_PROOF_ACTOR_VIEW_MIN_FULL_BODY_SCREEN_HEIGHT=',
        'OPENMW_PROOF_ACTOR_VIEW_MIN_FULL_BODY_SCREEN_AREA=',
        'OPENMW_PROOF_ACTOR_VIEW_REQUIRE_HUMAN_POSE=',
        'OPENMW_PROOF_ACTOR_VIEW_USE_HEAD_POSE_AXIS='
    )
    $env = @($env | Where-Object {
        $assignment = $_
        -not ($dataOnlyPortraitPrefixes | Where-Object { $assignment.StartsWith($_) })
    })

    $env += @(
        "OPENMW_OPENNV_ACTOR_EXPORT_ROOT=$meshRootAbs",
        "OPENMW_OPENNV_ACTOR_EXPORT_NO_SCREENSHOT=1",
        "OPENMW_OPENNV_ACTOR_EXPORT_EXIT_AFTER_BATCH=1",
        # The staging pedestal is a serializer, not a combat encounter. A
        # hostile creature otherwise attacks/kills the player, opens the
        # loading GUI, and strands the completion-driven batch on that actor.
        "OPENMW_PROOF_GOD_MODE=1",
        "OPENMW_PROOF_SUPPRESS_ACTOR_AI=1",
        "OPENMW_PROOF_PIN_STAGED_ACTOR=1",
        "OPENMW_PROOF_DISABLE_ACTOR_COLLISION=1",
        # Keep the drawable/cull-readiness barrier. Without it a cold creature
        # skeleton can be serialized on its staging frame before RigGeometry
        # has initialized, yielding a syntactically valid 16-byte empty file.
        # NO_SCREENSHOT bypasses only portrait framing, not this asset gate.
        "OPENMW_PROOF_REQUIRE_ACTOR_FOR_SCREENSHOT=1",
        # These are proof-camera acceptance gates, not asset-readiness gates.
        # Data-only exports must accept authored dead/sleeping/seated poses and
        # actors occluded from the unused portrait camera.
        "OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST=0",
        "OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST_GATE_ONLY=0",
        "OPENMW_PROOF_ACTOR_POSE_ALL_AVAILABLE=0",
        "OPENMW_PROOF_SCREENSHOT_FRAME=$($frames -join ',')",
        "OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG=1"
    )

    $runLeaf = Split-Path -Leaf $outputRootAbs
    $profileRoot = Join-Path $repoRoot "profiles/_verification/$runLeaf"
    $campaignUserdata = Join-Path $profileRoot 'userdata'
    $initializer = Join-Path $PSScriptRoot 'Initialize-OpenNVBaseProfile.ps1'
    $profile = & $initializer `
        -ProfileDirectory $profileRoot `
        -CampaignUserdataDirectory $campaignUserdata `
        -BinaryRoot $BinaryRoot `
        -Force
    $binary = Join-Path ([string]$profile.runtimeRoot) 'openmw.exe'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw "Missing OpenNV executable: $binary"
    }

    function Quote-ActorExportArgument([string]$Argument) {
        if ($Argument -match '[\s"]') { return '"' + ($Argument -replace '"', '\"') + '"' }
        return $Argument
    }

    $arguments = @(
        '--replace', 'config',
        '--config', [string]$profile.profileDirectory,
        '--resources', [string]$profile.resourcesRoot,
        '--skip-menu', '--start', 'Goodsprings', '--no-sound'
    )
    $argumentLine = ($arguments | ForEach-Object { Quote-ActorExportArgument $_ }) -join ' '
    $previousEnvironment = @{}
    try {
        foreach ($assignment in $env) {
            $split = $assignment.IndexOf('=')
            if ($split -le 0) { throw "Invalid actor export environment assignment: $assignment" }
            $name = $assignment.Substring(0, $split)
            $value = $assignment.Substring($split + 1)
            if (-not $previousEnvironment.ContainsKey($name)) {
                $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
        Write-Host "Exporting $($targets.Count) Goodsprings actors in one OpenNV process (native screenshots disabled)."
        $process = Start-Process -FilePath $binary -ArgumentList $argumentLine `
            -WorkingDirectory (Split-Path -Parent $binary) -WindowStyle Hidden -PassThru
        if (-not $process.WaitForExit($runSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "OpenNV actor mesh export timed out after $runSeconds seconds; stopped PID $($process.Id)."
        }
        if ($process.ExitCode -ne 0) {
            throw "OpenNV actor mesh export exited with code $($process.ExitCode)."
        }
    }
    finally {
        foreach ($name in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }

    $meshFiles = @()
    if (-not $SkeletalExportOnly) {
        $meshFiles = @(Get-ChildItem -LiteralPath $meshRootAbs -Filter 'actor-*.obj' -File |
            Where-Object { $_.Length -gt 128 } | Sort-Object Name)
        if ($meshFiles.Count -ne $targets.Count) {
            throw "Actor mesh export expected $($targets.Count) nonempty OBJ files; found $($meshFiles.Count) in $meshRootAbs."
        }
    }
    $skeletalFiles = @(Get-ChildItem -LiteralPath $meshRootAbs -Filter 'actor-*.onvskel' -File |
        Where-Object { $_.Length -gt 16 } | Sort-Object Name)
    if ($skeletalFiles.Count -ne $targets.Count) {
        throw "Actor mesh export expected $($targets.Count) nonempty ONVSKEL1 files; found $($skeletalFiles.Count) in $meshRootAbs."
    }
    $nativeScreenshots = @(Get-ChildItem -LiteralPath $campaignUserdata -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^screenshot[0-9]+\.' })
    if ($nativeScreenshots.Count -ne 0) {
        throw "Mesh-only export unexpectedly created $($nativeScreenshots.Count) native screenshot(s)."
    }
    $rows = for ($i = 0; $i -lt $targets.Count; ++$i) {
        [ordered]@{
            index = $i
            id = [string]$targets[$i].id
            category = [string]$targets[$i].category
            authoredRef = ConvertTo-CanonicalForm ([string]$targets[$i].authoredRef)
            base = ConvertTo-CanonicalForm ([string]$targets[$i].base)
            obj = if ($SkeletalExportOnly) { $null } else { $meshFiles[$i].FullName }
            mtl = if ($SkeletalExportOnly) { $null } else { [IO.Path]::ChangeExtension($meshFiles[$i].FullName, '.mtl') }
            skeletal = $skeletalFiles[$i].FullName
            sha256 = if ($SkeletalExportOnly) { $null } else { (Get-FileHash -Algorithm SHA256 -LiteralPath $meshFiles[$i].FullName).Hash.ToLowerInvariant() }
            skeletalSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $skeletalFiles[$i].FullName).Hash.ToLowerInvariant()
        }
    }
    $reportPath = Join-Path $outputRootAbs 'actor-mesh-export.json'
    $report = [ordered]@{
        schema = if ($SkeletalExportOnly) { 'opennv-godot-skeletal-only-actor-export/v1' } else { 'opennv-godot-skeletal-actor-export/v2' }
        status = 'pass'
        rosterPath = $rosterFile
        rosterSha256 = $rosterSha256
        targetCount = $targets.Count
        processExitCode = $process.ExitCode
        nativeScreenshotCount = 0
        meshRoot = $meshRootAbs
        actors = @($rows)
    }
    [IO.File]::WriteAllText($reportPath, (($report | ConvertTo-Json -Depth 7) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ status = 'pass'; outputDirectory = $outputRootAbs; reportPath = $reportPath; meshRoot = $meshRootAbs; actorCount = $targets.Count }
    return
}

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
