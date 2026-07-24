param(
    [string]$OutputRoot = "D:\code\nikami-worlds\run\fnv-main-story-portraits",
    [string]$MinePath = "D:\code\nikami-worlds\tmp\fnv-main-story-full-mine\fallout_new_vegas.actor-cast.esm4-mined.json",
    [string]$BinaryRoot = "D:\code\nikami-worlds-fnv-parity\local\openmw-vats-live",
    [int]$MinIndex = 1,
    [int]$MaxIndex = 39,
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

$actors = @(
    New-Actor 1  "Doc Mitchell"              "doc-mitchell"       "0x104c0f"
    New-Actor 2  "Trudy"                     "trudy"              "0x104c6d"
    New-Actor 3  "Victor"                    "victor"             "0x1073e8"
    New-Actor 4  "Johnson Nash"              "johnson-nash"       "0x0e2882"
    New-Actor 5  "Deputy Beagle"             "deputy-beagle"      "0x0d7f59"
    New-Actor 6  "Manny Vargas"              "manny-vargas"       "0x09649b"
    New-Actor 7  "Jessup"                    "jessup"             "0x10c0bf"
    New-Actor 8  "Benny"                     "benny"              "0x101ca0"
    New-Actor 9  "Swank"                     "swank"              "0x115f07"
    New-Actor 10 "Yes Man"                   "yes-man"            "0x1164fa"
    New-Actor 11 "Mr. House"                 "mr-house"           "0x14b095"
    New-Actor 12 "Ambassador Dennis Crocker" "ambassador-crocker" "0x116840"
    New-Actor 13 "Colonel Cassandra Moore"   "colonel-moore"      "0x1206fe"
    New-Actor 14 "The King"                  "the-king"           "0x10d8e0"
    New-Actor 15 "Pacer"                     "pacer"              "0x10e0ce"
    New-Actor 16 "Colonel James Hsu"         "colonel-hsu"        "0x0eea78"
    New-Actor 17 "Liza O'Malley"             "liza-omalley"       "0x117e7a"
    New-Actor 18 "Ranger Grant"              "ranger-grant"       "0x13721f"
    New-Actor 19 "President Kimball"         "president-kimball"  "0x12fcd2"
    New-Actor 20 "General Lee Oliver"        "general-oliver"     "0x134db4"
    New-Actor 21 "Vulpes Inculta"            "vulpes-inculta"     "0x13bf5b"
    New-Actor 22 "Alerio"                    "alerio"             "0x13a5ff"
    New-Actor 23 "Cursor Lucullus"           "cursor-lucullus"    "0x12fcb4"
    New-Actor 24 "Caesar"                    "caesar"             "0x121ff0"
    New-Actor 25 "Lucius"                    "lucius"             "0x11fc9e"
    New-Actor 26 "Cato Hostilius"            "cato-hostilius"     "0x13f372"
    New-Actor 27 "Legate Lanius"             "legate-lanius"      "0x137a9d"
    New-Actor 28 "Pearl"                     "pearl"              "0x0ff26b"
    New-Actor 29 "Loyal"                     "loyal"              "0x0ff26a"
    New-Actor 30 "Papa Khan"                 "papa-khan"          "0x140e54"
    New-Actor 31 "Regis"                     "regis"              "0x140e73"
    New-Actor 32 "Karl"                      "karl"               "0x140e71"
    New-Actor 33 "Nero"                      "nero"               "0x112dc9"
    New-Actor 34 "Big Sal"                   "big-sal"            "0x11267a"
    New-Actor 35 "Cachino"                   "cachino"            "0x11118d"
    New-Actor 36 "Marjorie"                  "marjorie"           "0x10d4f1"
    New-Actor 37 "Mortimer"                  "mortimer"           "0x10d4f2"
    New-Actor 38 "Elder McNamara"            "elder-mcnamara"     "0x0e2f87"
    New-Actor 39 "Head Paladin Hardin"       "paladin-hardin"     "0x0e2f88"
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
        throw "No authored placement found for $($actor.name) ($($actor.ref))."
    }
    $placement = $placements[$actorRef]
    $pos = @($placement.pos)
    $isExterior = [bool]$placement.cell.isExterior
    $gridX = if ($isExterior) { [int][Math]::Floor(([double]$pos[0]) / 4096.0) } else { 0 }
    $gridY = if ($isExterior) { [int][Math]::Floor(([double]$pos[1]) / 4096.0) } else { 0 }
    $worldspace = if ($isExterior) { [string]$placement.cell.parentWorld } else { "" }
    # Start authored child worldspaces in their exact CELL. Starting every exterior
    # through Goodsprings leaves Fort/Strip actors resolved while the camera remains
    # in Mojave-space coordinates, producing below-terrain captures.
    $startCell = if ($isExterior) {
        ConvertTo-RuntimeForm ([string]$placement.cell.id)
    } else {
        [string]$placement.cell.editorId
    }
    if (-not $isExterior -and [string]::IsNullOrWhiteSpace($startCell)) {
        throw "Interior placement has no editor ID for $($actor.name) ($($actor.ref))."
    }
    $groupKey = if ($isExterior) {
        "exterior:{0}:{1}:{2}" -f $worldspace, $gridX, $gridY
    } else {
        "interior:$startCell"
    }
    $resolved.Add([pscustomobject][ordered]@{
        index = $actor.index
        name = $actor.name
        slug = $actor.slug
        rawRef = $actorRef
        runtimeRef = ConvertTo-RuntimeForm $actor.ref
        placement = $placement
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

$groups = @($resolved.ToArray() | Group-Object groupKey)
$rows = New-Object System.Collections.Generic.List[object]
$groupsRun = 0
foreach ($group in $groups) {
    $pending = @($group.Group | Where-Object { $Overwrite -or -not (Test-Path -LiteralPath $_.output -PathType Leaf) })
    foreach ($existing in @($group.Group | Where-Object { -not $Overwrite -and (Test-Path -LiteralPath $_.output -PathType Leaf) })) {
        $rows.Add([pscustomobject][ordered]@{
            index = $existing.index; name = $existing.name; reference = $existing.runtimeRef
            cell = $existing.groupKey; output = $existing.output; status = "existing"; source = $null; log = $null
        }) | Out-Null
    }
    if ($pending.Count -eq 0) {
        continue
    }
    if ($MaxGroups -gt 0 -and $groupsRun -ge $MaxGroups) {
        break
    }
    $groupsRun++

    $anchor = $pending[0]
    $safeGroup = ($anchor.groupKey -replace '[^A-Za-z0-9._-]+', '-')
    $env = @(
        "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=1",
        "OPENMW_WORLD_VIEWER_RENDER_DISABLED_ACTORS=1",
        "OPENMW_FNV_PROOF_IMAGE_SPACE_ID=FormId:0x108809d",
        "OPENMW_PROOF_HIDE_PLAYER_VISUAL=1",
        "OPENMW_PROOF_HIDE_GUI=1",
        "OPENMW_WORLD_VIEWER_START_DRY=1",
        "OPENMW_WORLD_VIEWER_START_POS_X=$($anchor.pos[0])",
        "OPENMW_WORLD_VIEWER_START_POS_Y=$($anchor.pos[1])",
        "OPENMW_WORLD_VIEWER_START_POS_Z=$($anchor.pos[2])",
        "OPENMW_PROOF_SAY_FRAME=1",
        "OPENMW_PROOF_SAY_ACTORS=$(@($pending.runtimeRef) -join ',')",
        "OPENMW_PROOF_ACTOR_BATCH_AUTO_FRAMES=1",
        "OPENMW_PROOF_ACTOR_BATCH_FIRST_FRAME=180",
        "OPENMW_PROOF_ACTOR_BATCH_FRAMES_PER_ACTOR=150",
        "OPENMW_PROOF_ACTOR_BATCH_WARMUP_FRAMES=100",
        "OPENMW_PROOF_ACTOR_BATCH_EXIT_AFTER_COMPLETE=1",
        "OPENMW_PROOF_ACTOR_BATCH_EXIT_DELAY_FRAMES=120",
        "OPENMW_PROOF_SUPPRESS_ACTOR_AI=1",
        "OPENMW_PROOF_DISABLE_ACTOR_COLLISION=1",
        "OPENMW_FNV_PROOF_DISABLE_HEAD_TRACKING=1",
        "OPENMW_PROOF_ALIGN_PLAYER_TO_ACTOR=1",
        "OPENMW_PROOF_ACTOR_VIEW_STATIC_CAMERA=1",
        "OPENMW_PROOF_ACTOR_VIEW_EARLY_ALIGN=1",
        "OPENMW_PROOF_ACTOR_VIEW_USE_RENDER_BOUNDS=1",
        "OPENMW_PROOF_ACTOR_VIEW_USE_FACE_BOUNDS=1",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY=1",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_MARGIN=0.12",
        "OPENMW_PROOF_ACTOR_VIEW_USE_ACTOR_FACING=1",
        "OPENMW_PROOF_ACTOR_VIEW_USE_HEAD_POSE_AXIS=1",
        "OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST=1",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_RAYCAST=1",
        "OPENMW_PROOF_ACTOR_VIEW_FRONT_DISTANCE=130",
        "OPENMW_PROOF_ACTOR_VIEW_OFFSET_Z=105",
        "OPENMW_PROOF_ACTOR_VIEW_TARGET_Z=100",
        "OPENMW_PROOF_REQUIRE_ACTOR_FOR_SCREENSHOT=1",
        "OPENMW_PROOF_ACTOR_RESOLVE_RETRY_FRAMES=1"
    )
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
            -WorldId fallout_new_vegas `
            -Mode flat `
            -NoCatalogStart `
            -SkipMenu `
            -StartCell $anchor.startCell `
            -OutputRoot (Join-Path $caseRoot $safeGroup) `
            -RunSeconds 45 `
            -CaptureSeconds 44 `
            -EngineScreenshotFrames "180" `
            -ExpectedScreenshotCount $pending.Count `
            -NativeScreenshotWaitSeconds 45 `
            -CrashReportSettleSeconds 1 `
            -ExtraArgs "--no-sound" `
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
            index = $actor.index; name = $actor.name; reference = $actor.runtimeRef
            cell = $actor.groupKey; output = $actor.output; status = $status; source = $source; log = $logPath
        }) | Out-Null
    }

    [pscustomobject][ordered]@{
        schema = "nikami-fnv-main-story-portraits/v1"
        generatedAt = (Get-Date).ToString("o")
        expected = $actors.Count
        captured = @(Get-ChildItem -LiteralPath $pngRoot -Filter '*.png').Count
        rows = @($rows.ToArray() | Sort-Object index)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot "index.json") -Encoding UTF8
}

$summary = [pscustomobject][ordered]@{
    schema = "nikami-fnv-main-story-portraits/v1"
    generatedAt = (Get-Date).ToString("o")
    expected = $actors.Count
    captured = @(Get-ChildItem -LiteralPath $pngRoot -Filter '*.png').Count
    rows = @($rows.ToArray() | Sort-Object index)
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot "index.json") -Encoding UTF8
$summary
