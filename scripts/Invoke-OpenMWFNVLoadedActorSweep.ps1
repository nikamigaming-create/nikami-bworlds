param(
    [string]$OutputRoot = "run/openmw-fnv-loaded-actor-sweep",
    [int]$Offset = 0,
    [int]$Limit = 0,
    [int]$PoseFrames = 12,
    [int]$PoseStartDelayFrames = 12,
    [int]$NeutralFrames = 18,
    [int]$ActorTimeoutFrames = 1200,
    [string[]]$PoseGroups = @(
        'idle',
        'walkforward',
        'runforward',
        'walkback',
        'walkleft',
        'walkright',
        'turnleft',
        'turnright',
        'idle2',
        'weaponpose',
        'attack1',
        'attack2',
        'attack3',
        'reload',
        'equip',
        'unequip'
    ),
    [int]$TimeoutMinutes = 720,
    [switch]$BackgroundWindow,
    [switch]$IncludeRawPlayerBase,
    [switch]$RepresentativeVisualTypes,
    [switch]$AllLoadedActorBases,
    [switch]$AllAvailablePoses,
    [switch]$PriorityOrder,
    [switch]$SidecarMode,
    [string]$SidecarSharedMemoryName = '',
    [string[]]$SidecarActionIds = @(),
    [string[]]$SetEnv = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function ConvertTo-SafeFileToken([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'unnamed' }
    $token = $Value -replace '[^A-Za-z0-9._-]+', '-'
    $token = $token.Trim('-')
    if ([string]::IsNullOrWhiteSpace($token)) { return 'unnamed' }
    return $token
}

$representativeMode = -not $AllLoadedActorBases
if ($RepresentativeVisualTypes -and $AllLoadedActorBases) {
    throw 'RepresentativeVisualTypes and AllLoadedActorBases are mutually exclusive.'
}
if ($AllAvailablePoses -and $SidecarMode) {
    throw 'AllAvailablePoses cannot be combined with SidecarMode; sidecar actions are an explicit retail cross-product.'
}
if ($AllAvailablePoses -and $PSBoundParameters.ContainsKey('PoseGroups')) {
    throw 'AllAvailablePoses and PoseGroups are mutually exclusive.'
}
if ($representativeMode -and -not $PSBoundParameters.ContainsKey('PoseGroups')) {
    $PoseGroups = @('stand', 'kneel', 'prone', 'walk', 'talk', 'shoot', 'wave')
}
if ($Offset -lt 0) { throw 'Offset must be zero or greater.' }
if ($Limit -lt 0) { throw 'Limit must be zero or greater; zero means every loaded actor.' }
if ($PoseFrames -lt 1) { throw 'PoseFrames must be at least one.' }
if ($PoseStartDelayFrames -lt 0) { throw 'PoseStartDelayFrames must be zero or greater.' }
if ($NeutralFrames -lt 1) { throw 'NeutralFrames must be at least one.' }
if ($ActorTimeoutFrames -lt 1) { throw 'ActorTimeoutFrames must be at least one.' }
if ($TimeoutMinutes -lt 1) { throw 'TimeoutMinutes must be at least one.' }
$rawPoseGroups = @($PoseGroups)
if ($SidecarMode -and @($rawPoseGroups | Where-Object {
    [string]::IsNullOrWhiteSpace($_)
}).Count -gt 0) {
    throw 'Sidecar PoseGroups must not contain blank entries.'
}
if ($AllAvailablePoses) {
    $PoseGroups = @()
} elseif ($SidecarMode) {
    $PoseGroups = @($rawPoseGroups)
} else {
    $PoseGroups = @($rawPoseGroups | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
if (-not $AllAvailablePoses -and $PoseGroups.Count -eq 0) {
    throw 'At least one pose group is required unless AllAvailablePoses is selected.'
}
if ($SidecarMode) {
    if ($SidecarSharedMemoryName.Length -gt 180 -or
        $SidecarSharedMemoryName -notmatch '^Local\\[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'SidecarSharedMemoryName must name the coordinator-owned Local\\ NKSC mapping.'
    }
    $SidecarActionIds = @($SidecarActionIds)
    if ($SidecarActionIds.Count -lt 1 -or $SidecarActionIds.Count -gt 64 -or
        $SidecarActionIds.Count -ne $PoseGroups.Count) {
        throw 'SidecarActionIds must contain 1..64 entries and match PoseGroups exactly.'
    }
    $seenActionIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($actionId in $SidecarActionIds) {
        if ($actionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$' -or
            -not $seenActionIds.Add($actionId)) {
            throw "SidecarActionIds contains an unsafe or duplicate id '$actionId'."
        }
    }
    foreach ($poseGroup in $PoseGroups) {
        if ($poseGroup -notmatch '^[A-Za-z0-9_.-]{1,127}$') {
            throw "Sidecar PoseGroups contains an unsafe group token '$poseGroup'."
        }
    }
    $reservedSidecarEnvironment = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    [void]$reservedSidecarEnvironment.Add('OPENMW_FNV_SIDECAR_SHARED_MEMORY_NAME')
    [void]$reservedSidecarEnvironment.Add('OPENMW_FNV_SIDECAR_ACTION_IDS')
    foreach ($name in @(
        'OPENMW_PROOF_ACTOR_BATCH_ALL_LOADED',
        'OPENMW_PROOF_ACTOR_BATCH_AUTO_FRAMES',
        'OPENMW_PROOF_ACTOR_BATCH_OFFSET',
        'OPENMW_PROOF_ACTOR_BATCH_LIMIT',
        'OPENMW_PROOF_ACTOR_ROSTER_JSON',
        'OPENMW_PROOF_ACTOR_BATCH_FIRST_FRAME',
        'OPENMW_PROOF_ACTOR_BATCH_FRAMES_PER_ACTOR',
        'OPENMW_PROOF_ACTOR_BATCH_WARMUP_FRAMES',
        'OPENMW_PROOF_ACTOR_BATCH_EXIT_AFTER_COMPLETE',
        'OPENMW_PROOF_ACTOR_BATCH_EXIT_DELAY_FRAMES',
        'OPENMW_PROOF_ACTOR_BATCH_REPRESENTATIVE_VISUAL_TYPES',
        'OPENMW_PROOF_ACTOR_BATCH_PRIORITY_ORDER',
        'OPENMW_PROOF_ACTOR_POSE_ALL_AVAILABLE',
        'OPENMW_PROOF_ACTOR_BATCH_EXCLUDE_RAW_PLAYER_BASE',
        'OPENMW_PROOF_ACTOR_POSE_GROUPS',
        'OPENMW_PROOF_ACTOR_POSE_FRAMES',
        'OPENMW_PROOF_ACTOR_POSE_START_DELAY_FRAMES',
        'OPENMW_PROOF_ACTOR_POSE_NEUTRAL_FRAMES',
        'OPENMW_PROOF_ACTOR_PHASE_TIMEOUT_FRAMES'
    )) { [void]$reservedSidecarEnvironment.Add($name) }
    foreach ($entry in $SetEnv) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            throw 'SetEnv entries must be nonempty NAME=value strings.'
        }
        $separator = $entry.IndexOf('=')
        if ($separator -lt 1) {
            throw "SetEnv entry '$entry' must use NAME=value syntax."
        }
        $name = $entry.Substring(0, $separator)
        if ($reservedSidecarEnvironment.Contains($name)) {
            throw "SetEnv must not override coordinator-owned sidecar variable '$name'."
        }
    }
}

# The engine excludes the raw ESM4 `Player` base before representative grouping and offset/limit slicing.
# This keeps offsets deterministic in both complete-roster and representative-visual-type modes.
$effectiveOffset = $Offset

$outputRootAbs = Resolve-RepoRelativePath $OutputRoot
New-Item -ItemType Directory -Force -Path $outputRootAbs | Out-Null
$sessionTag = Get-Date -Format 'yyyyMMdd-HHmmss'
$rosterPath = Join-Path $outputRootAbs ("loaded-actor-roster-$sessionTag.json")
$progressPath = Join-Path $outputRootAbs ("sweep-progress-$sessionTag.json")
$finalLogPath = Join-Path $outputRootAbs ("openmw-actor-sweep-$sessionTag.log")
$screenRoot = Join-Path $outputRootAbs ("screens-$sessionTag")
New-Item -ItemType Directory -Force -Path $screenRoot | Out-Null

$poseWindowFrames = ($PoseGroups.Count + 2) * $PoseFrames + $NeutralFrames
$firstScreenshotFrame = [Math]::Max(240, 90 + $poseWindowFrames + 60)
$framesPerActor = [Math]::Max(120, $poseWindowFrames + 90)

$env = @(
    'OPENMW_PROOF_ACTOR_BATCH_ALL_LOADED=1',
    'OPENMW_PROOF_ACTOR_BATCH_AUTO_FRAMES=1',
    "OPENMW_PROOF_ACTOR_BATCH_OFFSET=$effectiveOffset",
    "OPENMW_PROOF_ACTOR_BATCH_LIMIT=$Limit",
    "OPENMW_PROOF_ACTOR_ROSTER_JSON=$rosterPath",
    "OPENMW_PROOF_ACTOR_BATCH_FIRST_FRAME=$firstScreenshotFrame",
    "OPENMW_PROOF_ACTOR_BATCH_FRAMES_PER_ACTOR=$framesPerActor",
    "OPENMW_PROOF_ACTOR_BATCH_WARMUP_FRAMES=$framesPerActor",
    'OPENMW_PROOF_ACTOR_BATCH_EXIT_AFTER_COMPLETE=1',
    'OPENMW_PROOF_ACTOR_BATCH_EXIT_DELAY_FRAMES=30',
    'OPENMW_PROOF_ACTOR_BATCH_FORCE_BASE_SPAWN=1',
    'OPENMW_PROOF_PLACE_ACTOR_IF_MISSING=1',
    "OPENMW_PROOF_ACTOR_POSE_GROUPS=$($PoseGroups -join ',')",
    "OPENMW_PROOF_ACTOR_POSE_FRAMES=$PoseFrames",
    "OPENMW_PROOF_ACTOR_POSE_START_DELAY_FRAMES=$PoseStartDelayFrames",
    "OPENMW_PROOF_ACTOR_POSE_NEUTRAL_FRAMES=$NeutralFrames",
    "OPENMW_PROOF_ACTOR_PHASE_TIMEOUT_FRAMES=$ActorTimeoutFrames",
    'OPENMW_PROOF_HIDE_GUI=1',
    'OPENMW_PROOF_HIDE_PLAYER_VISUAL=1',
    'OPENMW_FNV_PROOF_DISABLE_HEAD_TRACKING=1',
    'OPENMW_FNV_DISABLE_AI_PACKAGES=1',
    'OPENMW_FNV_DISABLE_PACKAGE_PROCEDURE=1',
    'OPENMW_FNV_DISABLE_PACKAGE_PREPLACEMENT=1',
    'OPENMW_WORLD_VIEWER_START_DRY=1',
    'OPENMW_WORLD_VIEWER_START_POS_X=-65306.37890625',
    'OPENMW_WORLD_VIEWER_START_POS_Y=-2088.551025390625',
    'OPENMW_WORLD_VIEWER_START_POS_Z=8384',
    'OPENMW_WORLD_VIEWER_START_ROT_X=0',
    'OPENMW_WORLD_VIEWER_START_ROT_Y=0',
    'OPENMW_WORLD_VIEWER_START_ROT_Z=5.639382362365723',
    'OPENMW_PROOF_SAY_FRAME=90',
    'OPENMW_PROOF_SUPPRESS_ACTOR_AI=1',
    'OPENMW_PROOF_DISABLE_ACTOR_COLLISION=1',
    'OPENMW_PROOF_STAGE_ACTOR=1',
    'OPENMW_PROOF_ACTOR_STAGE_X=-65306.37890625',
    'OPENMW_PROOF_ACTOR_STAGE_Y=-2088.551025390625',
    'OPENMW_PROOF_ACTOR_STAGE_Z=8384',
    'OPENMW_PROOF_ACTOR_STAGE_ROT_X=0',
    'OPENMW_PROOF_ACTOR_STAGE_ROT_Y=0',
    'OPENMW_PROOF_ACTOR_STAGE_ROT_Z=5.639382362365723',
    'OPENMW_PROOF_PIN_STAGED_ACTOR=1',
    'OPENMW_PROOF_ALIGN_PLAYER_TO_ACTOR=1',
    'OPENMW_PROOF_ACTOR_VIEW_STATIC_CAMERA=1',
    'OPENMW_PROOF_ACTOR_VIEW_EARLY_ALIGN=1',
    'OPENMW_PROOF_ACTOR_VIEW_REPLAY_RETAIL_ABSOLUTE_CAMERA=0',
    'OPENMW_PROOF_ACTOR_VIEW_USE_RENDER_BOUNDS=1',
    'OPENMW_PROOF_ACTOR_VIEW_USE_FACE_BOUNDS=1',
    'OPENMW_PROOF_ACTOR_VIEW_FULL_BODY=1',
    'OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_MARGIN=0.04',
    'OPENMW_PROOF_ACTOR_VIEW_MIN_FULL_BODY_SCREEN_WIDTH=0.15',
    'OPENMW_PROOF_ACTOR_VIEW_MIN_FULL_BODY_SCREEN_HEIGHT=0.15',
    'OPENMW_PROOF_ACTOR_VIEW_MIN_FULL_BODY_SCREEN_AREA=0.03',
    'OPENMW_PROOF_ACTOR_VIEW_CREATURE_AUTO_FIT=1',
    'OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST=1',
    'OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST_GATE_ONLY=1',
    'OPENMW_PROOF_ACTOR_VIEW_REQUIRE_HUMAN_POSE=1',
    'OPENMW_PROOF_ACTOR_VIEW_USE_ACTOR_FACING=1',
    'OPENMW_PROOF_ACTOR_VIEW_USE_HEAD_POSE_AXIS=1',
    'OPENMW_PROOF_ACTOR_VIEW_FRONT_DISTANCE=150',
    'OPENMW_PROOF_ACTOR_VIEW_OFFSET_Z=120',
    'OPENMW_PROOF_ACTOR_VIEW_TARGET_Z=120',
    'OPENMW_PROOF_REQUIRE_ACTOR_FOR_SCREENSHOT=1',
    'OPENMW_PROOF_ACTOR_RESOLVE_RETRY_FRAMES=1',
    'OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=1'
) + @($SetEnv)
if ($representativeMode) {
    $env += 'OPENMW_PROOF_ACTOR_BATCH_REPRESENTATIVE_VISUAL_TYPES=1'
}
if ($AllAvailablePoses) { $env += 'OPENMW_PROOF_ACTOR_POSE_ALL_AVAILABLE=1' }
if ($PriorityOrder) { $env += 'OPENMW_PROOF_ACTOR_BATCH_PRIORITY_ORDER=1' }
if (-not $IncludeRawPlayerBase) {
    $env += 'OPENMW_PROOF_ACTOR_BATCH_EXCLUDE_RAW_PLAYER_BASE=1'
}
if ($SidecarMode) {
    $env += "OPENMW_FNV_SIDECAR_SHARED_MEMORY_NAME=$SidecarSharedMemoryName"
    $env += "OPENMW_FNV_SIDECAR_ACTION_IDS=$($SidecarActionIds -join ',')"
}

$runner = Join-Path $PSScriptRoot 'Invoke-RealWorldScreenshots.ps1'
Write-Host "Launching one OpenMW actor process. offset=$Offset effectiveOffset=$effectiveOffset limit=$Limit poseGroups=$($PoseGroups.Count) allAvailablePoses=$([bool]$AllAvailablePoses) priorityOrder=$([bool]$PriorityOrder) representativeVisualTypes=$representativeMode rawPlayerIncluded=$([bool]$IncludeRawPlayerBase)"
$runnerArgs = @{
    WorldId = 'fallout_new_vegas'
    Mode = 'flat'
    SeedPath = Join-Path $repoRoot 'catalog\world-walker.seed.json'
    StartsPath = Join-Path $repoRoot 'catalog\flat-world-proof-starts.json'
    ActorAnimationPolicyPath = Join-Path $repoRoot 'catalog\actor-animation-policy.json'
    NoCatalogStart = $true
    SkipMenu = $true
    StartCell = 'Goodsprings'
    OutputRoot = $outputRootAbs
    RunSeconds = 30
    CaptureSeconds = @(1)
    EngineScreenshotFrames = '1'
    ExpectedScreenshotCount = 1
    NativeScreenshotWaitSeconds = 300
    CrashReportSettleSeconds = 1
    ExtraArgs = @('--no-sound')
    SetEnv = $env
    KeepRunning = $true
}
if ($BackgroundWindow) { $runnerArgs.BackgroundWindow = $true }
$runnerOutput = @(& $runner @runnerArgs)
$run = $runnerOutput[-1]
if ($null -eq $run.pid) { throw 'The OpenMW runner did not return a process id.' }

$processId = [int]$run.pid
$profileLogPath = Join-Path ([string]$run.profileDirectory) 'openmw.log'
$startedAt = Get-Date
$lastSelected = -1
$lastPoseComplete = -1
$lastScreenshotCount = 0
$roster = $null
$sidecarCompleteLogged = $false
$sidecarCompleteGeneration = $null
$sidecarFailureLogLine = $null
$sidecarCompletionObservedAt = $null
$sidecarForcedStop = $false
Write-Host "OpenMW PID $processId is running; waiting for its completion contract."

try {
while ($true) {
    if ($null -eq $roster -and (Test-Path -LiteralPath $rosterPath -PathType Leaf)) {
        try { $roster = Get-Content -LiteralPath $rosterPath -Raw | ConvertFrom-Json } catch { $roster = $null }
    }
    if (Test-Path -LiteralPath $profileLogPath -PathType Leaf) {
        $tail = @(Get-Content -LiteralPath $profileLogPath -Tail 500)
        foreach ($line in $tail) {
            if ($SidecarMode -and $line -match 'FNV sidecar OpenMW: sequence complete generation=([0-9]+)') {
                $sidecarCompleteLogged = $true
                $sidecarCompleteGeneration = [uint64]$Matches[1]
                if ($null -eq $sidecarCompletionObservedAt) { $sidecarCompletionObservedAt = Get-Date }
            }
            if ($SidecarMode -and $line -match 'FNV sidecar OpenMW: fail-closed code=') {
                $sidecarFailureLogLine = [string]$line
            }
            if ($line -match 'proof batch: selected actor index=([0-9]+)') {
                $index = [int]$Matches[1]
                if ($index -gt $lastSelected) {
                    $lastSelected = $index
                    Write-Host "Actor $($index + 1) selected."
                }
            }
            if ($line -match 'actor pose cycle: actorIndex=([0-9]+).*status=complete') {
                $index = [int]$Matches[1]
                if ($index -gt $lastPoseComplete) {
                    $lastPoseComplete = $index
                    Write-Host "Actor $($index + 1) pose cycle complete."
                }
            }
        }
        $savedCount = @($tail | Where-Object { $_ -match 'screenshot[0-9]+\.(?:png|jpg|jpeg|tga|bmp) has been saved' }).Count
        if ($savedCount -gt $lastScreenshotCount) { $lastScreenshotCount = $savedCount }
    }
    if ($null -ne $sidecarFailureLogLine) {
        throw "OpenMW endpoint published a fail-closed sidecar error: $sidecarFailureLogLine"
    }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) { break }
    if (((Get-Date) - $startedAt).TotalMinutes -ge $TimeoutMinutes) {
        throw "Actor sweep exceeded its $TimeoutMinutes minute watchdog. PID $processId remains available for inspection."
    }
    if ($SidecarMode -and $sidecarCompleteLogged -and
        ((Get-Date) - $sidecarCompletionObservedAt).TotalSeconds -ge 30) {
        # NKSC completion is proven by the coordinator from the shared header.
        # OPENMW_PROOF_ACTOR_BATCH_EXIT_AFTER_COMPLETE promises a natural exit.
        # A process still alive after this grace period is cleaned up, but the
        # runner records that fact and the coordinator remains the evidence gate.
        Stop-Process -Id $processId -ErrorAction SilentlyContinue
        Wait-Process -Id $processId -Timeout 30 -ErrorAction SilentlyContinue
        if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            throw "OpenMW did not exit after NKSC completion and resisted bounded cleanup; PID $processId remains alive."
        }
        $sidecarForcedStop = $true
        break
    }
    [pscustomobject][ordered]@{
        schema = 'nikami-fnv-actor-sweep-progress/v1'
        updatedAt = (Get-Date).ToString('o')
        pid = $processId
        total = if ($null -ne $roster) { [int]$roster.selectedCount } else { $null }
        selectedIndex = $lastSelected
        poseCompleteIndex = $lastPoseComplete
        elapsedSeconds = [int]((Get-Date) - $startedAt).TotalSeconds
        status = 'running'
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $progressPath -Encoding UTF8
    Start-Sleep -Seconds 2
}

if (-not (Test-Path -LiteralPath $profileLogPath -PathType Leaf)) {
    throw "The completed actor sweep has no runtime log: $profileLogPath"
}
# The process can exit between the final polling intervals. Re-scan the durable
# log before deciding whether the endpoint published its completion contract.
if ($SidecarMode -and -not $sidecarCompleteLogged) {
    $completionMatches = @(Select-String -LiteralPath $profileLogPath `
        -Pattern 'FNV sidecar OpenMW: sequence complete generation=([0-9]+)')
    if ($completionMatches.Count -gt 0 -and
        $completionMatches[-1].Line -match 'generation=([0-9]+)') {
        $sidecarCompleteLogged = $true
        $sidecarCompleteGeneration = [uint64]$Matches[1]
    }
}
if ($SidecarMode -and $null -eq $sidecarFailureLogLine) {
    $failureMatch = Select-String -LiteralPath $profileLogPath `
        -Pattern 'FNV sidecar OpenMW: fail-closed code=' | Select-Object -Last 1
    if ($null -ne $failureMatch) { $sidecarFailureLogLine = [string]$failureMatch.Line }
}
Copy-Item -LiteralPath $profileLogPath -Destination $finalLogPath -Force
if (-not (Test-Path -LiteralPath $rosterPath -PathType Leaf)) {
    throw "The completed actor sweep did not write its roster contract: $rosterPath"
}
$roster = Get-Content -LiteralPath $rosterPath -Raw | ConvertFrom-Json
$actors = @($roster.actors)

if ($SidecarMode) {
    if ($null -ne $sidecarFailureLogLine) {
        throw "OpenMW endpoint published a fail-closed sidecar error: $sidecarFailureLogLine"
    }
    if (-not $sidecarCompleteLogged) {
        throw 'The OpenMW process exited before its NKSC completion publication was logged.'
    }
    $expectedGeneration = [uint64]$actors.Count * [uint64]$SidecarActionIds.Count
    if ([uint64]$sidecarCompleteGeneration -ne $expectedGeneration) {
        throw "OpenMW completion generation is $sidecarCompleteGeneration; expected $expectedGeneration."
    }
    [pscustomobject][ordered]@{
        schema = 'nikami-openmw-fnv-sidecar-lane/v1'
        sidecarMode = $true
        pid = $processId
        roster = $rosterPath
        log = $finalLogPath
        selectedCount = [int]$roster.selectedCount
        actionIds = @($SidecarActionIds)
        processCount = 1
        runtimeContractProvenByRunner = $false
        forcedStopAfterCompletionLog = $sidecarForcedStop
        status = if ($sidecarForcedStop) {
            'endpoint-complete-log-observed-forced-process-cleanup-awaiting-coordinator-header-gate'
        } else { 'endpoint-complete-log-observed-natural-exit-awaiting-coordinator-header-gate' }
    }
    return
}

$captures = [System.Collections.Generic.List[object]]::new()
$poseByIndex = @{}
$actionGates = [System.Collections.Generic.List[object]]::new()
$phaseGates = @{}
$nativeStateByIndex = @{}
$currentActorIndex = $null
$pendingCapture = $null
foreach ($line in [System.IO.File]::ReadLines($finalLogPath)) {
    if ($line -match 'proof batch: selected actor index=([0-9]+) target="([^"]+)"') {
        $currentActorIndex = [int]$Matches[1]
        continue
    }
    if ($line -match 'actor pose cycle: actorIndex=([0-9]+).*requested=([0-9]+) played=([0-9]+) deferred=([0-9]+) skipped=([0-9]+).*status=complete') {
        $poseByIndex[[int]$Matches[1]] = [pscustomobject][ordered]@{
            requested = [int]$Matches[2]
            played = [int]$Matches[3]
            deferred = [int]$Matches[4]
            skipped = [int]$Matches[5]
            status = 'pass'
            reason = ''
        }
        continue
    }
    if ($line -match 'actor pose transport gate: actorIndex=([0-9]+) target="([^"]+)" poseIndex=([0-9]+) group="([^"]*)" resolvedGroup="([^"]*)" available=([01]) played=([01]) controllerMask=0x([0-9a-fA-F]+) activeMask=0x([0-9a-fA-F]+) start=([^ ]+) stop=([^ ]+) role=(standalone|composite-only) exact=1 gate=transport-only status=(pass|fail)') {
        $actionGates.Add([pscustomobject][ordered]@{
            schema = 'nikami-fnv-actor-action-transport-gate/v1'
            gateKind = 'transport-only'
            actorIndex = [int]$Matches[1]
            target = [string]$Matches[2]
            actionIndex = [int]$Matches[3]
            group = [string]$Matches[4]
            resolvedGroup = [string]$Matches[5]
            available = $Matches[6] -eq '1'
            playAccepted = $Matches[7] -eq '1'
            controllerMask = [Convert]::ToInt32($Matches[8], 16)
            activeMask = [Convert]::ToInt32($Matches[9], 16)
            startTime = [double]::Parse($Matches[10], [Globalization.CultureInfo]::InvariantCulture)
            stopTime = [double]::Parse($Matches[11], [Globalization.CultureInfo]::InvariantCulture)
            role = [string]$Matches[12]
            transportAccepted = $Matches[13] -eq 'pass'
            exact = $true
            status = [string]$Matches[13]
        }) | Out-Null
        continue
    }
    if ($line -match 'actor mechanics action gate: actorIndex=([0-9]+) target="([^"]+)" poseIndex=([0-9]+) semantic=primary group="([^"]*)" control=attackingOrSpell directGroupInjection=0 exact=1 gate=production-character-controller status=(pass|fail)') {
        $actionGates.Add([pscustomobject][ordered]@{
            schema = 'nikami-fnv-actor-action-mechanics-gate/v1'
            gateKind = 'production-character-controller'
            actorIndex = [int]$Matches[1]
            target = [string]$Matches[2]
            actionIndex = [int]$Matches[3]
            group = [string]$Matches[4]
            resolvedGroup = [string]$Matches[4]
            available = $Matches[5] -eq 'pass'
            playAccepted = $Matches[5] -eq 'pass'
            controllerMask = 0
            activeMask = 0
            startTime = 0.0
            stopTime = 0.0
            role = 'production-mechanics'
            transportAccepted = $Matches[5] -eq 'pass'
            exact = $true
            status = [string]$Matches[5]
        }) | Out-Null
        continue
    }
    if ($line -match 'actor phase gate: actorIndex=([0-9]+) target="([^"]+)".*requested=([0-9]+) played=([0-9]+) deferred=([0-9]+) skipped=([0-9]+) status=fail reason=([a-z0-9-]+)') {
        $phase = [pscustomobject][ordered]@{
            actorIndex = [int]$Matches[1]
            target = [string]$Matches[2]
            requested = [int]$Matches[3]
            played = [int]$Matches[4]
            deferred = [int]$Matches[5]
            skipped = [int]$Matches[6]
            status = 'fail'
            reason = [string]$Matches[7]
        }
        $phaseGates[$phase.actorIndex] = $phase
        $poseByIndex[$phase.actorIndex] = $phase
        continue
    }
    if ($line -match 'actor native state gate: actorIndex=([0-9]+) target="([^"]+)" type=(NPC_|CREA) lower="([^"]*)" torso="([^"]*)" leftArm="([^"]*)" rightArm="([^"]*)" visibleDrawables=([0-9]+) visibleRigs=([0-9]+) resolvedRigs=([0-9]+) bonesResolved=([01]) bonesFinite=([01]) uprightRatio=([^ ]+) status=(pass|fail) reason=([a-z0-9-]+)') {
        $nativeStateByIndex[[int]$Matches[1]] = [pscustomobject][ordered]@{
            schema = 'nikami-fnv-actor-native-state-gate/v1'
            target = [string]$Matches[2]
            type = [string]$Matches[3]
            lowerGroup = [string]$Matches[4]
            torsoGroup = [string]$Matches[5]
            leftArmGroup = [string]$Matches[6]
            rightArmGroup = [string]$Matches[7]
            visibleDrawables = [int]$Matches[8]
            visibleRigs = [int]$Matches[9]
            resolvedRigs = [int]$Matches[10]
            bonesResolved = $Matches[11] -eq '1'
            bonesFinite = $Matches[12] -eq '1'
            uprightRatio = [double]::Parse($Matches[13], [Globalization.CultureInfo]::InvariantCulture)
            status = [string]$Matches[14]
            reason = [string]$Matches[15]
        }
        continue
    }
    if ($line -match 'queuing GUI-inclusive native screenshot at frame ([0-9]+)') {
        if ($null -eq $currentActorIndex) { throw 'A screenshot was queued before an actor index was selected.' }
        $pendingCapture = [pscustomobject][ordered]@{
            actorIndex = [int]$currentActorIndex
            frame = [int]$Matches[1]
        }
        continue
    }
    if ($line -match '(?<path>[A-Za-z]:[\\/].*?screenshot[0-9]+\.(?:png|jpg|jpeg|tga|bmp)) has been saved') {
        if ($null -eq $pendingCapture) { continue }
        $captures.Add([pscustomobject][ordered]@{
            actorIndex = [int]$pendingCapture.actorIndex
            frame = [int]$pendingCapture.frame
            nativePath = [System.IO.Path]::GetFullPath(($Matches.path -replace '/', '\'))
        }) | Out-Null
        $pendingCapture = $null
    }
}

if ($captures.Count -ne $actors.Count) {
    throw "Actor screenshot contract expected $($actors.Count) captures and found $($captures.Count)."
}
if ($poseByIndex.Count -ne $actors.Count) {
    throw "Actor pose contract expected $($actors.Count) completed cycles and found $($poseByIndex.Count)."
}
if ($nativeStateByIndex.Count -ne $actors.Count) {
    throw "Actor native-state contract expected $($actors.Count) gates and found $($nativeStateByIndex.Count)."
}

$rows = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $actors.Count; ++$index) {
    $actor = $actors[$index]
    $capture = @($captures | Where-Object { [int]$_.actorIndex -eq $index })
    if ($capture.Count -ne 1) { throw "Actor index $index has $($capture.Count) captures instead of one." }
    if (-not (Test-Path -LiteralPath ([string]$capture[0].nativePath) -PathType Leaf)) {
        throw "Actor index $index native screenshot is missing: $($capture[0].nativePath)"
    }
    $nameToken = ConvertTo-SafeFileToken ([string]$actor.editorId)
    $extension = [System.IO.Path]::GetExtension([string]$capture[0].nativePath)
    $destination = Join-Path $screenRoot ('{0:D5}-{1}-front-full-body{2}' -f ($index + 1), $nameToken, $extension)
    Copy-Item -LiteralPath ([string]$capture[0].nativePath) -Destination $destination -Force
    $pose = $poseByIndex[$index]
    $nativeState = $nativeStateByIndex[$index]
    $actions = @($actionGates | Where-Object { [int]$_.actorIndex -eq $index } |
        Sort-Object actionIndex)
    if ($actions.Count -ne [int]$pose.requested -and $pose.status -eq 'pass') {
        throw "Actor index $index action-gate contract expected $($pose.requested) rows and found $($actions.Count)."
    }
    $priorityRankProperty = $actor.PSObject.Properties['priorityRank']
    $priorityScoreProperty = $actor.PSObject.Properties['priorityScore']
    $rows.Add([pscustomobject][ordered]@{
        index = $index
        type = [string]$actor.type
        form = [string]$actor.form
        editorId = [string]$actor.editorId
        name = [string]$actor.name
        visualSignature = [string]$actor.visualSignature
        selectedWeapon = [string]$actor.selectedWeapon
        representativeOfCount = [int]$actor.representativeOfCount
        representativeScore = [int]$actor.representativeScore
        priorityRank = if ($null -ne $priorityRankProperty) { [int]$priorityRankProperty.Value } else { 0 }
        priorityScore = if ($null -ne $priorityScoreProperty) { [long]$priorityScoreProperty.Value } else { 0 }
        shotKind = 'front-full-body'
        frame = [int]$capture[0].frame
        screenshot = $destination
        nativeScreenshot = [string]$capture[0].nativePath
        posesRequested = [int]$pose.requested
        posesPlayed = [int]$pose.played
        posesDeferred = [int]$pose.deferred
        posesSkipped = [int]$pose.skipped
        phaseStatus = [string]$pose.status
        phaseFailure = [string]$pose.reason
        nativeStateStatus = [string]$nativeState.status
        nativeStateFailure = [string]$nativeState.reason
        nativeState = $nativeState
        actionFailures = @($actions | Where-Object { $_.status -ne 'pass' }).Count
        actions = $actions
    }) | Out-Null
}

$indexPath = Join-Path $outputRootAbs ("actor-sweep-index-$sessionTag.json")
$actionGatePath = Join-Path $outputRootAbs ("actor-action-gates-$sessionTag.jsonl")
$actionGateLines = @($actionGates | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
[System.IO.File]::WriteAllLines($actionGatePath, $actionGateLines, [Text.UTF8Encoding]::new($false))
$failedActorCount = @($rows | Where-Object {
    $_.phaseStatus -ne 'pass' -or $_.nativeStateStatus -ne 'pass' -or $_.actionFailures -gt 0
}).Count
[pscustomobject][ordered]@{
    schema = 'nikami-openmw-fnv-loaded-actor-sweep/v2'
    createdAt = (Get-Date).ToString('o')
    processCount = 1
    pid = $processId
    roster = $rosterPath
    log = $finalLogPath
    screens = $screenRoot
    actionGates = $actionGatePath
    poseGroups = @($PoseGroups)
    allAvailablePoses = [bool]$AllAvailablePoses
    priorityOrder = [bool]$PriorityOrder
    offset = $Offset
    effectiveOffset = $effectiveOffset
    representativeVisualTypes = $representativeMode
    allLoadedActorBases = [bool]$AllLoadedActorBases
    distinctVisualTypes = if ($representativeMode) { [int]$roster.distinctVisualTypes } else { $null }
    rawPlayerBaseIncluded = [bool]$IncludeRawPlayerBase
    rawPlayerBasePolicy = if ($IncludeRawPlayerBase) { 'included-explicitly' } else { 'excluded-form-0x00000007' }
    limit = $Limit
    rows = @($rows)
    failedActorCount = $failedActorCount
    status = if ($failedActorCount -eq 0) { 'complete' } else { 'complete-with-failures' }
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $indexPath -Encoding UTF8

[pscustomobject][ordered]@{
    index = $indexPath
    roster = $rosterPath
    log = $finalLogPath
    screens = $screenRoot
    actionGates = $actionGatePath
    count = $rows.Count
    failedActorCount = $failedActorCount
    processCount = 1
    status = if ($failedActorCount -eq 0) { 'complete' } else { 'complete-with-failures' }
}
}
finally {
    # KeepRunning deliberately transfers ownership of this exact PID to this
    # wrapper. Any exception or Stop-Job cancellation must not orphan OpenMW or
    # leave the proof profile locked for the next one-launch run.
    $remainingProcess = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -ne $remainingProcess) {
        Stop-Process -Id $processId -ErrorAction SilentlyContinue
        Wait-Process -Id $processId -Timeout 30 -ErrorAction SilentlyContinue
        if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            Write-Warning "OpenMW PID $processId resisted runner-owned cleanup."
        }
    }
}
