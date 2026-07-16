param(
    [string]$OutputRoot = "run/openmw-fnv-loaded-actor-sweep",
    [int]$Offset = 0,
    [int]$Limit = 0,
    [int]$PoseFrames = 12,
    [int]$PoseStartDelayFrames = 12,
    [int]$NeutralFrames = 18,
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
if ($representativeMode -and -not $PSBoundParameters.ContainsKey('PoseGroups')) {
    $PoseGroups = @('stand', 'kneel', 'prone', 'walk', 'talk', 'shoot', 'wave')
}
if ($Offset -lt 0) { throw 'Offset must be zero or greater.' }
if ($Limit -lt 0) { throw 'Limit must be zero or greater; zero means every loaded actor.' }
if ($PoseFrames -lt 1) { throw 'PoseFrames must be at least one.' }
if ($PoseStartDelayFrames -lt 0) { throw 'PoseStartDelayFrames must be zero or greater.' }
if ($NeutralFrames -lt 1) { throw 'NeutralFrames must be at least one.' }
if ($TimeoutMinutes -lt 1) { throw 'TimeoutMinutes must be at least one.' }
$PoseGroups = @($PoseGroups | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($PoseGroups.Count -eq 0) { throw 'At least one pose group is required.' }

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
    $env += 'OPENMW_PROOF_ACTOR_REPRESENTATIVE_POSES=1'
}
if (-not $IncludeRawPlayerBase) {
    $env += 'OPENMW_PROOF_ACTOR_BATCH_EXCLUDE_RAW_PLAYER_BASE=1'
}

$runner = Join-Path $PSScriptRoot 'Invoke-RealWorldScreenshots.ps1'
Write-Host "Launching one OpenMW actor process. offset=$Offset effectiveOffset=$effectiveOffset limit=$Limit poseGroups=$($PoseGroups.Count) representativeVisualTypes=$representativeMode rawPlayerIncluded=$([bool]$IncludeRawPlayerBase)"
$runnerArgs = @{
    WorldId = 'fallout_new_vegas'
    Mode = 'flat'
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
Write-Host "OpenMW PID $processId is running; waiting for its completion contract."

while ($true) {
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) { break }
    if (((Get-Date) - $startedAt).TotalMinutes -ge $TimeoutMinutes) {
        throw "Actor sweep exceeded its $TimeoutMinutes minute watchdog. PID $processId remains available for inspection."
    }

    if ($null -eq $roster -and (Test-Path -LiteralPath $rosterPath -PathType Leaf)) {
        try { $roster = Get-Content -LiteralPath $rosterPath -Raw | ConvertFrom-Json } catch { $roster = $null }
    }
    if (Test-Path -LiteralPath $profileLogPath -PathType Leaf) {
        $tail = @(Get-Content -LiteralPath $profileLogPath -Tail 500)
        foreach ($line in $tail) {
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
Copy-Item -LiteralPath $profileLogPath -Destination $finalLogPath -Force
if (-not (Test-Path -LiteralPath $rosterPath -PathType Leaf)) {
    throw "The completed actor sweep did not write its roster contract: $rosterPath"
}
$roster = Get-Content -LiteralPath $rosterPath -Raw | ConvertFrom-Json
$actors = @($roster.actors)

$captures = [System.Collections.Generic.List[object]]::new()
$poseByIndex = @{}
$currentActorIndex = $null
$pendingCapture = $null
foreach ($line in [System.IO.File]::ReadLines($finalLogPath)) {
    if ($line -match 'proof batch: selected actor index=([0-9]+) target="([^"]+)"') {
        $currentActorIndex = [int]$Matches[1]
        continue
    }
    if ($line -match 'actor pose cycle: actorIndex=([0-9]+).*requested=([0-9]+) played=([0-9]+) skipped=([0-9]+).*status=complete') {
        $poseByIndex[[int]$Matches[1]] = [pscustomobject][ordered]@{
            requested = [int]$Matches[2]
            played = [int]$Matches[3]
            skipped = [int]$Matches[4]
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
        shotKind = 'front-full-body'
        frame = [int]$capture[0].frame
        screenshot = $destination
        nativeScreenshot = [string]$capture[0].nativePath
        posesRequested = [int]$pose.requested
        posesPlayed = [int]$pose.played
        posesSkipped = [int]$pose.skipped
    }) | Out-Null
}

$indexPath = Join-Path $outputRootAbs ("actor-sweep-index-$sessionTag.json")
[pscustomobject][ordered]@{
    schema = 'nikami-openmw-fnv-loaded-actor-sweep/v1'
    createdAt = (Get-Date).ToString('o')
    processCount = 1
    pid = $processId
    roster = $rosterPath
    log = $finalLogPath
    screens = $screenRoot
    poseGroups = @($PoseGroups)
    offset = $Offset
    effectiveOffset = $effectiveOffset
    representativeVisualTypes = $representativeMode
    allLoadedActorBases = [bool]$AllLoadedActorBases
    distinctVisualTypes = if ($representativeMode) { [int]$roster.distinctVisualTypes } else { $null }
    rawPlayerBaseIncluded = [bool]$IncludeRawPlayerBase
    rawPlayerBasePolicy = if ($IncludeRawPlayerBase) { 'included-explicitly' } else { 'excluded-form-0x00000007' }
    limit = $Limit
    rows = @($rows)
    status = 'complete'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $indexPath -Encoding UTF8

[pscustomobject][ordered]@{
    index = $indexPath
    roster = $rosterPath
    log = $finalLogPath
    screens = $screenRoot
    count = $rows.Count
    processCount = 1
    status = 'complete'
}
