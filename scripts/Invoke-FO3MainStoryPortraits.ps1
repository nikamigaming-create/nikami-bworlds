param(
    [string]$OutputRoot = "D:\code\nikami-worlds\run\fo3-main-story-portraits",
    [string]$MinePath = "D:\code\nikami-worlds\tmp\fo3-main-story-mine\fallout3.actor-cast.esm4-mined.json",
    [string]$BinaryRoot = "D:\code\nikami-worlds-fnv-parity\local\openmw-vats-live",
    [int]$MinIndex = 1,
    [int]$MaxIndex = 28,
    [int]$MaxGroups = 0,
    [string[]]$SetEnv = @(),
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = "D:\code\nikami-worlds-fnv-parity\scripts\Invoke-RealWorldScreenshots.ps1"
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

# Core named cast encountered directly along Fallout 3's base-game main quest.
# President Eden is represented by his authored master-control eye because the
# character has no humanoid ACHR. Liberty Prime is the authored CREA placement.
$actors = @(
    New-Actor 1  "Dad"                  "dad"                 "0x19d09"
    New-Actor 2  "Amata"                "amata"               "0x282d4"
    New-Actor 3  "Overseer Alphonse"    "overseer-alphonse"   "0x2d4bc"
    New-Actor 4  "Jonas"                "jonas"               "0x99344"
    New-Actor 5  "Butch DeLoria"        "butch-deloria"       "0x2a4e8"
    New-Actor 6  "Colin Moriarty"       "colin-moriarty"      "0x03b3c"
    New-Actor 7  "Lucas Simms"          "lucas-simms"         "0x03b46"
    New-Actor 8  "Silver"                "silver"              "0x9ea7a"
    New-Actor 9  "Three Dog"             "three-dog"           "0x23943"
    New-Actor 10 "Doctor Li"             "doctor-li"           "0x19fc5"
    New-Actor 11 "Janice Kaplinski"      "janice-kaplinski"    "0x19fc6"
    New-Actor 12 "Daniel Agincourt"      "daniel-agincourt"    "0x1ccba"
    New-Actor 13 "Alex Dargon"           "alex-dargon"         "0x1ccab"
    New-Actor 14 "Garza"                 "garza"               "0x1e764"
    New-Actor 15 "Stanislaus Braun"      "stanislaus-braun"    "0xbd694"
    New-Actor 16 "Betty"                 "betty"               "0x25098"
    New-Actor 17 "Mayor MacCready"       "mayor-maccready"     "0x0313b"
    New-Actor 18 "Joseph"                "joseph"              "0x03a13"
    New-Actor 19 "Fawkes"                "fawkes"              "0x2d9cf"
    New-Actor 20 "Elder Lyons"           "elder-lyons"         "0x210e6"
    New-Actor 21 "Sentinel Sarah Lyons"  "sentinel-lyons"      "0x1d44f"
    New-Actor 22 "Scribe Rothchild"      "scribe-rothchild"    "0x1f0c7"
    New-Actor 23 "Star Paladin Cross"    "star-paladin-cross"  "0x62735"
    New-Actor 24 "Paladin Kodiak"        "paladin-kodiak"      "0x210ea"
    New-Actor 25 "Colonel Autumn"        "colonel-autumn"      "0x1b52c"
    New-Actor 26 "Anna Holt"             "anna-holt"           "0x38df6"
    New-Actor 27 "Liberty Prime"         "liberty-prime"       "0x5fd25"
    New-Actor 28 "President Eden"        "president-eden"      "0x03401"
)
$actors = @($actors | Where-Object { $_.index -ge $MinIndex -and $_.index -le $MaxIndex })

$mine = Get-Content -Raw -LiteralPath $MinePath | ConvertFrom-Json
$placements = @{}
foreach ($candidate in @($mine.topCastCandidates)) {
    $placements[(ConvertTo-RawHex ([string]$candidate.ref))] = $candidate
}

$resolved = New-Object System.Collections.Generic.List[object]
foreach ($actor in $actors) {
    $actorRef = ConvertTo-RawHex $actor.ref
    if (-not $placements.ContainsKey($actorRef)) {
        throw "No authored Fallout 3 placement found for $($actor.name) ($($actor.ref))."
    }
    $placement = $placements[$actorRef]
    $pos = @($placement.pos)
    $isExterior = [bool]$placement.cell.isExterior
    $gridX = if ($isExterior) { [int][Math]::Floor(([double]$pos[0]) / 4096.0) } else { 0 }
    $gridY = if ($isExterior) { [int][Math]::Floor(([double]$pos[1]) / 4096.0) } else { 0 }
    $worldspace = if ($isExterior) { [string]$placement.cell.parentWorld } else { "" }
    $startCell = if ($isExterior) {
        ConvertTo-RuntimeForm ([string]$placement.cell.id)
    } else {
        [string]$placement.cell.editorId
    }
    if (-not $isExterior -and [string]::IsNullOrWhiteSpace($startCell)) {
        throw "Interior placement has no editor ID for $($actor.name) ($($actor.ref))."
    }
    $groupKey = if ($isExterior) {
        "exterior:{0}:{1}:{2}:{3}" -f $worldspace, $placement.cell.id, $gridX, $gridY
    } else {
        "interior:$startCell"
    }
    $resolved.Add([pscustomobject][ordered]@{
        index = $actor.index
        name = $actor.name
        slug = $actor.slug
        runtimeRef = ConvertTo-RuntimeForm $actor.ref
        runtimeBase = ConvertTo-RuntimeForm ([string]$placement.base)
        pos = $pos
        isExterior = $isExterior
        worldspace = $worldspace
        gridX = $gridX
        gridY = $gridY
        startCell = $startCell
        groupKey = $groupKey
        output = Join-Path $pngRoot ("{0:d2}-{1}.png" -f $actor.index, $actor.slug)
    }) | Out-Null
}

$rows = New-Object System.Collections.Generic.List[object]
$groupsRun = 0
# Run one portrait subject per native process. This keeps another story actor
# in the same authored cell from becoming a foreground occluder and gives the
# renderer one unambiguous base record for proof-target part assembly.
foreach ($group in @($resolved.ToArray() | Group-Object index)) {
    $pending = @($group.Group | Where-Object { $Overwrite -or -not (Test-Path -LiteralPath $_.output -PathType Leaf) })
    foreach ($existing in @($group.Group | Where-Object { -not $Overwrite -and (Test-Path -LiteralPath $_.output -PathType Leaf) })) {
        $rows.Add([pscustomobject][ordered]@{
            index = $existing.index; name = $existing.name; reference = $existing.runtimeRef
            cell = $existing.groupKey; output = $existing.output; status = "existing"; source = $null; log = $null
        }) | Out-Null
    }
    if ($pending.Count -eq 0) { continue }
    if ($MaxGroups -gt 0 -and $groupsRun -ge $MaxGroups) { break }
    $groupsRun++

    $anchor = $pending[0]
    $safeGroup = ($anchor.groupKey -replace '[^A-Za-z0-9._-]+', '-')
    $env = @(
        "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=0",
        "OPENMW_WORLD_VIEWER_RENDER_DISABLED_ACTORS=1",
        "OPENMW_PROOF_HIDE_PLAYER_VISUAL=1",
        "OPENMW_PROOF_HIDE_GUI=1",
        "OPENMW_WORLD_VIEWER_START_DRY=1",
        "OPENMW_WORLD_VIEWER_START_POS_X=$($anchor.pos[0])",
        "OPENMW_WORLD_VIEWER_START_POS_Y=$($anchor.pos[1])",
        "OPENMW_WORLD_VIEWER_START_POS_Z=$($anchor.pos[2])",
        "OPENMW_PROOF_SAY_FRAME=1",
        "OPENMW_FNV_PROOF_TARGET_NPC=$($anchor.runtimeBase)",
        # Spawn each NPC from its authored base record. Several FO3 main-quest
        # references are corpses or furniture-scripted quest variants; using
        # the same base preserves the real race, face, inventory and equipment
        # while giving the portrait pass a clean native idle in the same cell.
        "OPENMW_PROOF_SAY_ACTORS=$(@($pending.runtimeBase) -join ',')",
        "OPENMW_PROOF_ACTOR_BATCH_FORCE_BASE_SPAWN=1",
        "OPENMW_PROOF_PLACE_ACTOR_IF_MISSING=1",
        "OPENMW_PROOF_HIDE_EXISTING_ACTOR_BASE=1",
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
        "OPENMW_PROOF_STAGE_ACTOR=1",
        "OPENMW_PROOF_ACTOR_STAGE_X=$($anchor.pos[0])",
        "OPENMW_PROOF_ACTOR_STAGE_Y=$($anchor.pos[1])",
        "OPENMW_PROOF_ACTOR_STAGE_Z=$($anchor.pos[2])",
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
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_MARGIN=0.08",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_DISTANCE_SCALE=0.82",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_FIT_PADDING=0.9",
        "OPENMW_PROOF_ACTOR_VIEW_USE_ACTOR_FACING=1",
        "OPENMW_PROOF_ACTOR_VIEW_FALLOUT_FRONT=1",
        "OPENMW_PROOF_ACTOR_VIEW_USE_HEAD_POSE_AXIS=1",
        "OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST=0",
        "OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST_GATE_ONLY=0",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_RAYCAST=0",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_RAYCAST_RINGS=2",
        "OPENMW_PROOF_ACTOR_VIEW_FRONT_DISTANCE=96",
        "OPENMW_PROOF_ACTOR_VIEW_OFFSET_Z=105",
        "OPENMW_PROOF_ACTOR_VIEW_TARGET_Z=100",
        "OPENMW_PROOF_ACTOR_VIEW_REQUIRE_HUMAN_POSE=1",
        "OPENMW_PROOF_REQUIRE_ACTOR_FOR_SCREENSHOT=1",
        "OPENMW_PROOF_ACTOR_RESOLVE_RETRY_FRAMES=30"
    )
    if (-not $anchor.isExterior) {
        # Interior portraits use the neutral FO3 image space for repeatability.
        # Exteriors must retain the worldspace's authored climate/image-space;
        # forcing an unrelated record there can collapse saturation to grayscale.
        $env += "OPENMW_FNV_PROOF_IMAGE_SPACE_ID=FormId:0x1000160"
    }
    if ($anchor.isExterior) {
        $env += @(
            "OPENMW_WORLD_VIEWER_START_WORLDSPACE=$(ConvertTo-RuntimeForm $anchor.worldspace)",
            "OPENMW_WORLD_VIEWER_START_GRID_X=$($anchor.gridX)",
            "OPENMW_WORLD_VIEWER_START_GRID_Y=$($anchor.gridY)",
            "OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS=1"
        )
    }
    $env += @($SetEnv)

    Write-Host "Capturing $(@($pending.name) -join ', ') in $($anchor.groupKey)"
    Push-Location "D:\code\nikami-worlds-fnv-parity"
    try {
        $runnerResult = @(& $runner `
            -WorldId fallout3 `
            -Mode flat `
            -NoCatalogStart `
            -SkipMenu `
            -StartCell $anchor.startCell `
            -OutputRoot (Join-Path $caseRoot $safeGroup) `
            -RunSeconds 30 `
            -CaptureSeconds 12 `
            -EngineScreenshotFrames "180" `
            -ExpectedScreenshotCount $pending.Count `
            -NativeScreenshotWaitSeconds 20 `
            -CrashReportSettleSeconds 1 `
            -SetEnv $env `
            -BinaryRoot $BinaryRoot `
            -BackgroundWindow)
    }
    finally {
        Pop-Location
    }

    $last = $runnerResult[-1]
    $logPath = [string]$last.logPath
    $saved = @()
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $logText = Get-Content -Raw -LiteralPath $logPath
        $saved = @([regex]::Matches($logText, '(?m)([A-Za-z]:[^\r\n]*?screenshot\d+\.png) has been saved') |
            ForEach-Object { $_.Groups[1].Value })
    }

    for ($i = 0; $i -lt $pending.Count; $i++) {
        $actor = $pending[$i]
        $source = if ($i -lt $saved.Count) { [string]$saved[$i] } else { "" }
        $status = "missing-screenshot"
        if (-not [string]::IsNullOrWhiteSpace($source) -and (Test-Path -LiteralPath $source -PathType Leaf)) {
            Copy-Item -LiteralPath $source -Destination $actor.output -Force
            $status = "captured"
        }
        $rows.Add([pscustomobject][ordered]@{
            index = $actor.index; name = $actor.name; reference = $actor.runtimeRef; base = $actor.runtimeBase
            cell = $actor.groupKey; output = $actor.output; status = $status; source = $source; log = $logPath
        }) | Out-Null
    }

    [pscustomobject][ordered]@{
        schema = "nikami-fo3-main-story-portraits/v1"
        generatedAt = (Get-Date).ToString("o")
        expected = $actors.Count
        captured = @(Get-ChildItem -LiteralPath $pngRoot -Filter '*.png').Count
        rows = @($rows.ToArray() | Sort-Object index)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot "index.json") -Encoding UTF8
}

$summary = [pscustomobject][ordered]@{
    schema = "nikami-fo3-main-story-portraits/v1"
    generatedAt = (Get-Date).ToString("o")
    expected = $actors.Count
    captured = @(Get-ChildItem -LiteralPath $pngRoot -Filter '*.png').Count
    rows = @($rows.ToArray() | Sort-Object index)
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot "index.json") -Encoding UTF8
$summary
