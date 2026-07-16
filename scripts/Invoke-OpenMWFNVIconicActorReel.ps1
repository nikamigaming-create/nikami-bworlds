param(
    [string]$OutputRoot = 'run/openmw-fnv-iconic-actor-reel',
    [int]$PoseFrames = 12,
    [int]$PoseStartDelayFrames = 12,
    [int]$NeutralFrames = 18,
    [string[]]$PoseGroups = @('stand', 'kneel', 'walk', 'talk', 'shoot', 'wave'),
    [int]$TimeoutMinutes = 15,
    [switch]$BackgroundWindow,
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
    $token = ($Value -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($token)) { return 'unnamed' }
    return $token
}

if ($PoseFrames -lt 1) { throw 'PoseFrames must be at least one.' }
if ($PoseStartDelayFrames -lt 0) { throw 'PoseStartDelayFrames must be zero or greater.' }
if ($NeutralFrames -lt 1) { throw 'NeutralFrames must be at least one.' }
if ($TimeoutMinutes -lt 1) { throw 'TimeoutMinutes must be at least one.' }
$PoseGroups = @($PoseGroups | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($PoseGroups.Count -eq 0) { throw 'At least one pose group is required.' }
if ($PoseGroups -contains 'prone') {
    throw 'The proof reel refuses the old floor-sleep surrogate. A real prone animation must be proven before prone can be requested.'
}

$actors = @(
    [pscustomobject]@{ label='Easy Pete'; category='human'; form='FormId:0x1104c7f'; editorId='GSEasyPete' },
    [pscustomobject]@{ label='Sunny Smiles'; category='human'; form='FormId:0x1104e84'; editorId='GSSunnySmiles' },
    [pscustomobject]@{ label='Doc Mitchell'; category='human'; form='FormId:0x1104c0c'; editorId='DocMitchell' },
    [pscustomobject]@{ label='Benny'; category='human'; form='FormId:0x1101c9b'; editorId='Benny' },
    [pscustomobject]@{ label='Caesar'; category='human'; form='FormId:0x1121fef'; editorId='FortCaesar' },
    [pscustomobject]@{ label='Boone'; category='human'; form='FormId:0x1092bd2'; editorId='CraigBoone' },
    [pscustomobject]@{ label='Veronica'; category='human'; form='FormId:0x10e32aa'; editorId='Veronica' },
    [pscustomobject]@{ label='Cass'; category='human'; form='FormId:0x1133fdd'; editorId='RoseofSharonCassidy' },
    [pscustomobject]@{ label='Raul'; category='human'; form='FormId:0x10e60ef'; editorId='RaulTejada' },
    [pscustomobject]@{ label='Legate Lanius'; category='human'; form='FormId:0x11300aa'; editorId='VHDLegionLegateLanius' },
    [pscustomobject]@{ label='Lily'; category='creature'; form='FormId:0x113d834'; editorId='Lily' },
    [pscustomobject]@{ label='Rex'; category='creature'; form='FormId:0x1118e71'; editorId='Rex' },
    [pscustomobject]@{ label='Deathclaw'; category='creature'; form='FormId:0x101cf9a'; editorId='CrDeathClaw' },
    [pscustomobject]@{ label='Cazador'; category='creature'; form='FormId:0x10e584d'; editorId='NVCrCazador' },
    [pscustomobject]@{ label='Nightstalker'; category='creature'; form='FormId:0x1119e50'; editorId='NVCrNightStalker' },
    [pscustomobject]@{ label='Gecko'; category='creature'; form='FormId:0x110cd73'; editorId='NVCrGecko' },
    [pscustomobject]@{ label='Bighorner'; category='creature'; form='FormId:0x1108020'; editorId='NVCrBigHorner' },
    [pscustomobject]@{ label='Radscorpion'; category='creature'; form='FormId:0x1135b9b'; editorId='VCrRadscorpionTier1TypeA' },
    [pscustomobject]@{ label='Victor'; category='robot'; form='FormId:0x1103dfd'; editorId='Victor' },
    [pscustomobject]@{ label='Protectron'; category='robot'; form='FormId:0x101cf8f'; editorId='CrProtectron' },
    [pscustomobject]@{ label='Mister Gutsy'; category='robot'; form='FormId:0x1021ebd'; editorId='CrMisterGutsy' },
    [pscustomobject]@{ label='Sentry Bot'; category='robot'; form='FormId:0x101cf8a'; editorId='CrSentryBotGL' },
    [pscustomobject]@{ label='Brotherhood power armor'; category='power-armor'; form='FormId:0x10181da'; editorId='BrotherhoodOfSteel1GunAAM' }
)

$outputRootAbs = Resolve-RepoRelativePath $OutputRoot
New-Item -ItemType Directory -Force -Path $outputRootAbs | Out-Null
$sessionTag = Get-Date -Format 'yyyyMMdd-HHmmss'
$screenRoot = Join-Path $outputRootAbs ("screens-$sessionTag")
$progressPath = Join-Path $outputRootAbs ("reel-progress-$sessionTag.json")
$finalLogPath = Join-Path $outputRootAbs ("openmw-iconic-reel-$sessionTag.log")
New-Item -ItemType Directory -Force -Path $screenRoot | Out-Null

$poseWindowFrames = ($PoseGroups.Count + 2) * $PoseFrames + $NeutralFrames
$firstScreenshotFrame = [Math]::Max(240, 90 + $poseWindowFrames + 60)
$framesPerActor = [Math]::Max(120, $poseWindowFrames + 90)
$targets = @($actors | ForEach-Object { [string]$_.form })

$env = @(
    "OPENMW_PROOF_SAY_ACTORS=$($targets -join ',')",
    'OPENMW_PROOF_ACTOR_BATCH_AUTO_FRAMES=1',
    "OPENMW_PROOF_ACTOR_BATCH_FIRST_FRAME=$firstScreenshotFrame",
    "OPENMW_PROOF_ACTOR_BATCH_FRAMES_PER_ACTOR=$framesPerActor",
    "OPENMW_PROOF_ACTOR_BATCH_WARMUP_FRAMES=$framesPerActor",
    'OPENMW_PROOF_ACTOR_BATCH_EXIT_AFTER_COMPLETE=1',
    'OPENMW_PROOF_ACTOR_BATCH_EXIT_DELAY_FRAMES=30',
    'OPENMW_PROOF_ACTOR_BATCH_FORCE_BASE_SPAWN=1',
    'OPENMW_PROOF_PLACE_ACTOR_IF_MISSING=1',
    'OPENMW_PROOF_ACTOR_REPRESENTATIVE_POSES=1',
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

Write-Host "Iconic reel: $($actors.Count) subjects, one OpenMW process, poses=$($PoseGroups -join ',')."
for ($index = 0; $index -lt $actors.Count; ++$index) {
    Write-Host ('  {0:D2}. [{1}] {2} ({3})' -f ($index + 1), $actors[$index].category, $actors[$index].label, $actors[$index].form)
}

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

$runner = Join-Path $PSScriptRoot 'Invoke-RealWorldScreenshots.ps1'
$runnerOutput = @(& $runner @runnerArgs)
$run = $runnerOutput[-1]
if ($null -eq $run.pid) { throw 'The OpenMW runner did not return a process id.' }
$processId = [int]$run.pid
$profileLogPath = Join-Path ([string]$run.profileDirectory) 'openmw.log'
$startedAt = Get-Date
$lastSelected = -1
$lastPoseComplete = -1
Write-Host "OpenMW PID $processId is running. The visible reel will exit after all $($actors.Count) front captures."

while ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
    if (((Get-Date) - $startedAt).TotalMinutes -ge $TimeoutMinutes) {
        throw "Iconic reel exceeded its $TimeoutMinutes minute watchdog. PID $processId remains available for inspection."
    }
    if (Test-Path -LiteralPath $profileLogPath -PathType Leaf) {
        $tail = @(Get-Content -LiteralPath $profileLogPath -Tail 600)
        foreach ($line in $tail) {
            if ($line -match 'proof batch: selected actor index=([0-9]+)') {
                $index = [int]$Matches[1]
                if ($index -gt $lastSelected) {
                    $lastSelected = $index
                    Write-Host ('Selected {0:D2}/{1:D2}: {2}' -f ($index + 1), $actors.Count, $actors[$index].label)
                }
            }
            if ($line -match 'actor pose cycle: actorIndex=([0-9]+).*status=complete') {
                $index = [int]$Matches[1]
                if ($index -gt $lastPoseComplete) {
                    $lastPoseComplete = $index
                    Write-Host ('Pose cycle complete {0:D2}/{1:D2}: {2}' -f ($index + 1), $actors.Count, $actors[$index].label)
                }
            }
        }
    }
    [pscustomobject][ordered]@{
        schema = 'nikami-fnv-iconic-reel-progress/v1'
        updatedAt = (Get-Date).ToString('o')
        pid = $processId
        total = $actors.Count
        selectedIndex = $lastSelected
        poseCompleteIndex = $lastPoseComplete
        status = 'running'
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $progressPath -Encoding UTF8
    Start-Sleep -Milliseconds 500
}

if (-not (Test-Path -LiteralPath $profileLogPath -PathType Leaf)) {
    throw "The completed iconic reel has no runtime log: $profileLogPath"
}
Copy-Item -LiteralPath $profileLogPath -Destination $finalLogPath -Force

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
        $poseByIndex[[int]$Matches[1]] = [pscustomobject]@{ requested=[int]$Matches[2]; played=[int]$Matches[3]; skipped=[int]$Matches[4] }
        continue
    }
    if ($line -match 'queuing GUI-inclusive native screenshot at frame ([0-9]+)') {
        if ($null -ne $currentActorIndex) {
            $pendingCapture = [pscustomobject]@{ actorIndex=[int]$currentActorIndex; frame=[int]$Matches[1] }
        }
        continue
    }
    if ($line -match '(?<path>[A-Za-z]:[\\/].*?screenshot[0-9]+\.(?:png|jpg|jpeg|tga|bmp)) has been saved') {
        if ($null -eq $pendingCapture) { continue }
        $captures.Add([pscustomobject]@{
            actorIndex = [int]$pendingCapture.actorIndex
            frame = [int]$pendingCapture.frame
            nativePath = [System.IO.Path]::GetFullPath(($Matches.path -replace '/', '\'))
        }) | Out-Null
        $pendingCapture = $null
    }
}

if ($captures.Count -ne $actors.Count) {
    throw "Iconic reel expected $($actors.Count) captures and found $($captures.Count)."
}
if ($poseByIndex.Count -ne $actors.Count) {
    throw "Iconic reel expected $($actors.Count) completed pose cycles and found $($poseByIndex.Count)."
}

$rows = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $actors.Count; ++$index) {
    $capture = @($captures | Where-Object { [int]$_.actorIndex -eq $index })
    if ($capture.Count -ne 1) { throw "Actor index $index has $($capture.Count) captures instead of one." }
    if (-not (Test-Path -LiteralPath ([string]$capture[0].nativePath) -PathType Leaf)) {
        throw "Actor index $index native screenshot is missing: $($capture[0].nativePath)"
    }
    $extension = [System.IO.Path]::GetExtension([string]$capture[0].nativePath)
    $destination = Join-Path $screenRoot ('{0:D2}-{1}-front-full-body{2}' -f ($index + 1), (ConvertTo-SafeFileToken $actors[$index].label), $extension)
    Copy-Item -LiteralPath ([string]$capture[0].nativePath) -Destination $destination -Force
    $pose = $poseByIndex[$index]
    $rows.Add([pscustomobject][ordered]@{
        index = $index
        label = $actors[$index].label
        category = $actors[$index].category
        form = $actors[$index].form
        editorId = $actors[$index].editorId
        shotKind = 'front-full-body'
        frame = [int]$capture[0].frame
        screenshot = $destination
        nativeScreenshot = [string]$capture[0].nativePath
        posesRequested = [int]$pose.requested
        posesPlayed = [int]$pose.played
        posesSkipped = [int]$pose.skipped
    }) | Out-Null
}

$indexPath = Join-Path $outputRootAbs ("iconic-reel-index-$sessionTag.json")
[pscustomobject][ordered]@{
    schema = 'nikami-openmw-fnv-iconic-actor-reel/v1'
    createdAt = (Get-Date).ToString('o')
    processCount = 1
    pid = $processId
    log = $finalLogPath
    screens = $screenRoot
    poseGroups = @($PoseGroups)
    forbiddenSurrogate = 'floorsleepdynamicidle'
    rows = @($rows)
    status = 'complete'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $indexPath -Encoding UTF8

[pscustomobject][ordered]@{
    index = $indexPath
    log = $finalLogPath
    screens = $screenRoot
    count = $rows.Count
    processCount = 1
    status = 'complete'
}
