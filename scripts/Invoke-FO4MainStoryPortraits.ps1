param(
    [string]$OutputRoot = "D:\code\nikami-worlds\run\fo4-main-story-portraits",
    [string]$MinePath = "D:\code\nikami-worlds\tmp\fo4-top10-mine\fallout4.actor-cast.esm4-mined.json",
    [string]$BinaryRoot = "D:\code\nikami-worlds\local\openmw-fo4guard",
    [int]$MinIndex = 1,
    [int]$MaxIndex = 10,
    [int]$MaxActors = 0,
    [string[]]$SetEnv = @(),
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "Invoke-FlatWorldScreenshots.ps1"
$pngRoot = Join-Path $OutputRoot "png"
$caseRoot = Join-Path $OutputRoot "captures"
New-Item -ItemType Directory -Force -Path $pngRoot, $caseRoot | Out-Null

function New-Actor([int]$Index, [string]$Name, [string]$Slug, [string]$Ref) {
    [pscustomobject][ordered]@{
        index = $Index
        name = $Name
        slug = $Slug
        ref = $Ref.ToLowerInvariant()
    }
}

function ConvertTo-RuntimeForm([string]$RawForm) {
    $value = [Convert]::ToUInt32(($RawForm -replace '^0x', ''), 16)
    "FormId:0x{0:x}" -f (0x01000000 -bor ($value -band 0x00ffffff))
}

function ConvertTo-RawHex([string]$RawForm) {
    $value = [Convert]::ToUInt32(($RawForm -replace '^0x', ''), 16)
    "0x{0:x}" -f $value
}

# Named characters encountered across Fallout 4's base-game main quest.
$actors = @(
    New-Actor 1  "Vault-Tec Rep"   "vault-tec-rep"  "0xabfa0"
    New-Actor 2  "Codsworth"       "codsworth"      "0x1ca7d"
    New-Actor 3  "Preston Garvey"  "preston-garvey" "0x1a4d7"
    New-Actor 4  "Sturges"         "sturges"        "0x1a4d8"
    New-Actor 5  "Mama Murphy"     "mama-murphy"    "0x1a4d9"
    New-Actor 6  "Piper Wright"    "piper-wright"   "0x2f1f"
    New-Actor 7  "Nick Valentine"  "nick-valentine" "0x2f25"
    New-Actor 8  "Conrad Kellogg"  "conrad-kellogg" "0x9bc71"
    New-Actor 9  "Brian Virgil"    "brian-virgil"   "0x6b505"
    New-Actor 10 "Father (Shaun)"  "father-shaun"   "0x5c337"
) | Where-Object { $_.index -ge $MinIndex -and $_.index -le $MaxIndex }

$mine = Get-Content -Raw -LiteralPath $MinePath | ConvertFrom-Json
$placements = @{}
foreach ($candidate in @($mine.topCastCandidates)) {
    $placements[(ConvertTo-RawHex ([string]$candidate.ref))] = $candidate
}

$resolved = New-Object System.Collections.Generic.List[object]
foreach ($actor in $actors) {
    $rawRef = ConvertTo-RawHex $actor.ref
    if (-not $placements.ContainsKey($rawRef)) {
        throw "No authored Fallout 4 placement found for $($actor.name) ($rawRef)."
    }
    $placement = $placements[$rawRef]
    $pos = @($placement.pos)
    if ($actor.index -eq 1) {
        # His authored MQ101 doorway marker is inside the Vault-Tec booth and
        # blocks a frontal portrait. Keep him in PrewarSanctuaryExt01 but stage
        # him on the adjacent open lawn.
        $pos = @(([double]$pos[0]), (([double]$pos[1]) - 350.0), ([double]$pos[2]))
    }
    elseif ($actor.index -ge 3 -and $actor.index -le 5) {
        # Use the center of the survivors' authored cluster (between the Jun
        # Long and Mama Murphy placements), away from Preston's obstructed
        # east-side camera line and the central exhibit.
        $pos = @(600.0, 25.0, 640.0)
    }
    elseif ($actor.index -eq 8) {
        # Kellogg's disabled quest marker is tucked behind the Fort Hagen
        # machinery. Stage him on the nearby authored synth floor position.
        $pos = @(-48.0, -12.0, -768.0)
    }
    $isExterior = [bool]$placement.cell.isExterior
    $gridX = if ($isExterior) { [int][Math]::Floor(([double]$pos[0]) / 4096.0) } else { 0 }
    $gridY = if ($isExterior) { [int][Math]::Floor(([double]$pos[1]) / 4096.0) } else { 0 }
    $worldspace = if ($isExterior) { [string]$placement.cell.parentWorld } else { "" }
    $startCell = [string]$placement.cell.editorId
    if ($actor.index -eq 2) {
        # The actor mine resolves Codsworth through a persistent parent CELL;
        # the authored named cell used by the proven lit baseline is SanctuaryExt02.
        $startCell = "SanctuaryExt02"
        $worldspace = "0x3c"
        $gridX = -20
        $gridY = 22
    }
    elseif ([string]::IsNullOrWhiteSpace($startCell)) {
        $startCell = ConvertTo-RuntimeForm ([string]$placement.cell.id)
    }

    $resolved.Add([pscustomobject][ordered]@{
        index = $actor.index
        name = $actor.name
        slug = $actor.slug
        runtimeRef = ConvertTo-RuntimeForm $rawRef
        runtimeBase = ConvertTo-RuntimeForm ([string]$placement.base)
        pos = $pos
        isExterior = $isExterior
        worldspace = $worldspace
        gridX = $gridX
        gridY = $gridY
        startCell = $startCell
        orbitDegrees = 90
        output = Join-Path $pngRoot ("{0:d2}-{1}.png" -f $actor.index, $actor.slug)
    }) | Out-Null
}

$rows = New-Object System.Collections.Generic.List[object]
$actorsRun = 0
foreach ($actor in @($resolved.ToArray() | Sort-Object index)) {
    if (-not $Overwrite -and (Test-Path -LiteralPath $actor.output -PathType Leaf)) {
        $rows.Add([pscustomobject][ordered]@{
            index = $actor.index; name = $actor.name; reference = $actor.runtimeRef
            cell = $actor.startCell; output = $actor.output; status = "existing"; source = $null; log = $null
        }) | Out-Null
        continue
    }
    if ($MaxActors -gt 0 -and $actorsRun -ge $MaxActors) { break }
    $actorsRun++

    $case = Join-Path $caseRoot ("{0:d2}-{1}" -f $actor.index, $actor.slug)
    $env = @(
        "OPENMW_PROOF_HIDE_PLAYER_VISUAL=1",
        "OPENMW_PROOF_HIDE_GUI=1",
        "OPENMW_WORLD_VIEWER_HIDE_DIAGNOSTIC_MODELS=1",
        "OPENMW_WORLD_VIEWER_REQUIRE_CAMERA_SETTLED=",
        "OPENMW_WORLD_VIEWER_START_DRY=1",
        "OPENMW_FNV_BOOTSTRAP_HOUR=12",
        "OPENMW_WORLD_VIEWER_RENDER_DISABLED_ACTORS=",
        "OPENMW_WORLD_VIEWER_DISABLE_TES5_UNSTABLE_FACE_SURFACE_QUARANTINE=1",
        "OPENMW_WORLD_VIEWER_FO4_MISSING_BONE_NEAREST_BIND=1",
        "OPENMW_PROOF_SAY_FRAME=1",
        "OPENMW_PROOF_SAY_ACTOR=$($actor.runtimeBase)",
        "OPENMW_PROOF_SAY_ACTORS=$($actor.runtimeBase)",
        "OPENMW_PROOF_PLACE_ACTOR_IF_MISSING=1",
        "OPENMW_PROOF_ACTOR_BATCH_AUTO_FRAMES=1",
        "OPENMW_PROOF_ACTOR_BATCH_FIRST_FRAME=180",
        "OPENMW_PROOF_ACTOR_BATCH_FRAMES_PER_ACTOR=150",
        "OPENMW_PROOF_ACTOR_BATCH_WARMUP_FRAMES=100",
        "OPENMW_PROOF_ACTOR_BATCH_EXIT_AFTER_COMPLETE=1",
        "OPENMW_PROOF_ACTOR_BATCH_EXIT_DELAY_FRAMES=1",
        "OPENMW_PROOF_SUPPRESS_ACTOR_AI=1",
        "OPENMW_FNV_DISABLE_AI_PACKAGES=1",
        "OPENMW_PROOF_REVIVE_ACTOR=1",
        "OPENMW_PROOF_DISABLE_ACTOR_COLLISION=1",
        "OPENMW_FNV_PROOF_DISABLE_HEAD_TRACKING=1",
        "OPENMW_FNV_IDLE_ARM_RELAX_IK=1",
        "OPENMW_PROOF_STAGE_ACTOR=1",
        "OPENMW_PROOF_ACTOR_STAGE_X=$($actor.pos[0])",
        "OPENMW_PROOF_ACTOR_STAGE_Y=$($actor.pos[1])",
        "OPENMW_PROOF_ACTOR_STAGE_Z=$($actor.pos[2])",
        "OPENMW_PROOF_ACTOR_STAGE_ROT_X=0",
        "OPENMW_PROOF_ACTOR_STAGE_ROT_Y=0",
        "OPENMW_PROOF_ACTOR_STAGE_ROT_Z=0",
        "OPENMW_PROOF_PIN_STAGED_ACTOR=1",
        "OPENMW_PROOF_ALIGN_PLAYER_TO_ACTOR=1",
        "OPENMW_PROOF_ACTOR_VIEW_STATIC_CAMERA=1",
        "OPENMW_PROOF_ACTOR_VIEW_EARLY_ALIGN=1",
        "OPENMW_PROOF_ACTOR_VIEW_USE_RENDER_BOUNDS=1",
        "OPENMW_PROOF_ACTOR_VIEW_USE_FACE_BOUNDS=1",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY=1",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_MARGIN=0.03",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_DISTANCE_SCALE=1.0",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_FIT_PADDING=0.9",
        "OPENMW_PROOF_ACTOR_VIEW_USE_ACTOR_FACING=1",
        "OPENMW_PROOF_ACTOR_VIEW_FALLOUT_FRONT=1",
        "OPENMW_PROOF_ACTOR_VIEW_USE_HEAD_POSE_AXIS=1",
        "OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST=0",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_RAYCAST=0",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_RAYCAST_RINGS=4",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_RAYCAST_STEP_DEGREES=35",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_RAYCAST_INCLUDE_REVERSE=1",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_DEGREES=$($actor.orbitDegrees)",
        "OPENMW_PROOF_ACTOR_VIEW_FRONT_DISTANCE=96",
        "OPENMW_PROOF_ACTOR_VIEW_OFFSET_Z=105",
        "OPENMW_PROOF_ACTOR_VIEW_TARGET_Z=100",
        "OPENMW_PROOF_REQUIRE_ACTOR_FOR_SCREENSHOT=1",
        "OPENMW_PROOF_ACTOR_RESOLVE_RETRY_FRAMES=30"
    )
    if ($actor.isExterior) {
        $env += @(
            "OPENMW_WORLD_VIEWER_START_WORLDSPACE=$(ConvertTo-RuntimeForm $actor.worldspace)",
            "OPENMW_WORLD_VIEWER_START_GRID_X=$($actor.gridX)",
            "OPENMW_WORLD_VIEWER_START_GRID_Y=$($actor.gridY)",
            "OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS=1"
        )
    }
    if ($actor.index -in @(6, 7, 10)) {
        # These authored interiors leave the camera-facing side of the actor
        # nearly unlit. The local light-model floor feeds FO4's native skin
        # shader and preserves the original textures/materials.
        $env += "OPENMW_WORLD_VIEWER_PORTRAIT_ACTOR_FILL=1"
    }
    if ($actor.index -eq 9) {
        # Virgil's authored cave camera line clips the left wall. Keep the
        # intact super-mutant rig in its authored cell and use the nearest
        # unobstructed absolute camera found from the mined placement.
        $env += @(
            "OPENMW_FNV_IDLE_ARM_RELAX_IK=",
            "OPENMW_PROOF_ACTOR_VIEW_REPLAY_RETAIL_ABSOLUTE_CAMERA=1",
            "OPENMW_PROOF_ACTOR_VIEW_RETAIL_CAMERA_X=1941.0",
            "OPENMW_PROOF_ACTOR_VIEW_RETAIL_CAMERA_Y=3253.0",
            "OPENMW_PROOF_ACTOR_VIEW_RETAIL_CAMERA_Z=297.7"
        )
    }
    $env += @($SetEnv)

    Write-Host "Capturing $($actor.name) in $($actor.startCell)"
    # The engine actor batch owns portrait timing. Keep the generic harness
    # frame beyond the batch's clean-exit point so it never emits a stale
    # booth/debug candidate.
    $runnerResult = @(& $runner `
        -WorldId fallout4 `
        -BinaryRoot $BinaryRoot `
        -ProofRoot $case `
        -RunSeconds 40 `
        -ScreenshotFrames "999999" `
        -StartCellOverride $actor.startCell `
        -StartPosX ([double]$actor.pos[0]) `
        -StartPosY ([double]$actor.pos[1]) `
        -StartPosZ ([double]$actor.pos[2]) `
        -StartGridX $actor.gridX `
        -StartGridY $actor.gridY `
        -Esm4GridRadius $(if ($actor.isExterior) { 1 } else { 0 }) `
        -FocusActor $actor.runtimeRef `
        -NoTelemetry `
        -SetEnv $env)

    $manifestPath = Get-ChildItem -LiteralPath $case -Filter manifest.json -Recurse -File |
        Sort-Object LastWriteTimeUtc, FullName | Select-Object -Last 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        throw "Fallout 4 portrait runner did not write a manifest for $($actor.name)."
    }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $result = @($manifest.results)[0]
    $source = [string]$result.screenshot
    $status = [string]$result.status
    # The generic harness candidate is taken on a fixed early frame. Prefer
    # the engine's actor-batch capture, which is emitted only after staging and
    # portrait-camera alignment complete.
    $currentRunRoot = Split-Path -Parent $manifestPath
    $nativeSource = Get-ChildItem -LiteralPath $currentRunRoot -Filter "screenshot*.png" -Recurse -File |
        Where-Object { $_.FullName -match '[\\/]fallout4[\\/]userdata[\\/]screenshots[\\/]' } |
        Sort-Object LastWriteTimeUtc, FullName | Select-Object -Last 1 -ExpandProperty FullName
    if (-not [string]::IsNullOrWhiteSpace($nativeSource)) {
        $source = $nativeSource
        $status = "screenshot"
    }
    if ($status -eq "screenshot" -and -not [string]::IsNullOrWhiteSpace($source) -and
        (Test-Path -LiteralPath $source -PathType Leaf)) {
        Copy-Item -LiteralPath $source -Destination $actor.output -Force
        $status = "captured"
    }
    $rows.Add([pscustomobject][ordered]@{
        index = $actor.index
        name = $actor.name
        reference = $actor.runtimeRef
        base = $actor.runtimeBase
        cell = $actor.startCell
        output = $actor.output
        status = $status
        source = $source
        log = [string]$result.processLog
    }) | Out-Null
}

$ledger = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    worldId = "fallout4"
    rosterCount = 10
    requestedRange = @($MinIndex, $MaxIndex)
    outputRoot = $OutputRoot
    rows = @($rows.ToArray())
}
$ledgerPath = Join-Path $OutputRoot "ledger.json"
$ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ledgerPath -Encoding utf8
$ledger
