param(
    [string]$OutputRoot = "D:\code\nikami-worlds\run\skyrim-main-story-portraits",
    [string]$BinaryRoot = "D:\code\nikami-worlds\local\openmw-fo4guard",
    [int]$MinIndex = 1,
    [int]$MaxIndex = 10,
    [int]$MaxActors = 0,
    [int]$RunSeconds = 40,
    [double]$StageZOffset = 0,
    [string[]]$SetEnv = @(),
    [switch]$WaitForProcessExit,
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "Invoke-FlatWorldScreenshots.ps1"
$pngRoot = Join-Path $OutputRoot "png"
$caseRoot = Join-Path $OutputRoot "captures"
New-Item -ItemType Directory -Force -Path $pngRoot, $caseRoot | Out-Null

# Skyrim VR remains intentionally excluded from the global world-walker
# promotion contract. This task is a narrower actor-proof run, so derive a
# one-world seed locally without changing catalog/world-walker.seed.json.
$globalSeedPath = Join-Path (Split-Path $PSScriptRoot -Parent) "catalog\world-walker.seed.json"
$portraitSeedPath = Join-Path $OutputRoot "skyrim-portrait-world-walker.seed.json"
$globalSeed = Get-Content -Raw -LiteralPath $globalSeedPath | ConvertFrom-Json
$skyrimWorld = @($globalSeed.worlds | Where-Object { $_.id -eq "skyrim_vr" })[0]
if ($null -eq $skyrimWorld) { throw "The global world-walker seed has no skyrim_vr profile." }
$skyrimWorld.readyForWorldWalker = $true
$skyrimWorld.excludedByContract = $false
[pscustomobject][ordered]@{
    schemaVersion = $globalSeed.schemaVersion
    generatedAt = (Get-Date).ToString("o")
    scope = "skyrim-main-story-actor-proofs"
    worlds = @($skyrimWorld)
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $portraitSeedPath -Encoding utf8

function ConvertTo-RuntimeForm([string]$RawForm) {
    $value = [Convert]::ToUInt32(($RawForm -replace '^0x', ''), 16)
    "FormId:0x{0:x}" -f (0x01000000 -bor ($value -band 0x00ffffff))
}

function New-Actor(
    [int]$Index, [string]$Name, [string]$Slug, [string]$Ref, [string]$Base,
    [string]$Cell, [bool]$Exterior, [double]$X, [double]$Y, [double]$Z
) {
    [pscustomobject][ordered]@{
        index = $Index
        name = $Name
        slug = $Slug
        runtimeRef = ConvertTo-RuntimeForm $Ref
        runtimeBase = ConvertTo-RuntimeForm $Base
        startCell = $Cell
        isExterior = $Exterior
        pos = @($X, $Y, $Z)
        gridX = if ($Exterior) { [int][Math]::Floor($X / 4096.0) } else { 0 }
        gridY = if ($Exterior) { [int][Math]::Floor($Y / 4096.0) } else { 0 }
        output = Join-Path $pngRoot ("{0:d2}-{1}.png" -f $Index, $Slug)
    }
}

# Base records, ACHR references, cells, and coordinates are read from the local
# Skyrim.esm through export_esm4_catalog.py. These are authored main-quest
# placements; no display-name or bone-name inference is used at capture time.
$actors = @(
    New-Actor 1  "Ralof"            "ralof"            "0x2bf9e" "0x2bf9d" "FormId:0x1000d74"          $true  19840.7734  -79532.5     8450.6201
    New-Actor 2  "Hadvar"           "hadvar"           "0x2bfa2" "0x2bf9f" "FormId:0x1000d74"          $true  20044.3301  -79478.7578  8473.9150
    New-Actor 3  "General Tullius"  "general-tullius"  "0x198ba" "0x1327e" "SolitudeCastleDour"         $false 235.8144    -14.8970     288.0001
    New-Actor 4  "Ulfric Stormcloak" "ulfric-stormcloak" "0x1b131" "0x1414d" "WindhelmPalaceoftheKings"   $false -2400.0     -1552.0      56.0
    New-Actor 5  "Jarl Balgruuf"    "jarl-balgruuf"    "0x1a677" "0x13bbd" "WhiterunDragonsreach"       $false 112.0       2640.0       -16.0
    New-Actor 6  "Delphine"         "delphine"         "0x13485" "0x13478" "RiverwoodSleepingGiantInn"  $false -495.1869   155.0037     0.0
    New-Actor 7  "Esbern"           "esbern"           "0x19dfd" "0x13358" "RiftenEsbernsVault"         $false 1918.1277   -2281.7439   -350.6012
    New-Actor 8  "Arngeir"          "arngeir"          "0x886b3" "0x2c6c7" "HighHrothgar"               $false -1280.0     -416.0       -896.0
    New-Actor 9  "Paarthurnax"      "paarthurnax"      "0x3c57d" "0x3c57c" "FormId:0x10009749"          $true  52083.1602  -53090.6680  37944.4531
    New-Actor 10 "Alduin"           "alduin"           "0x32da0" "0x32d9d" "KynesgroveBurialMound08"    $true  147781.4844 14147.0840   -7110.0557
) | Where-Object { $_.index -ge $MinIndex -and $_.index -le $MaxIndex }

$rows = New-Object System.Collections.Generic.List[object]
$actorsRun = 0
foreach ($actor in @($actors | Sort-Object index)) {
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
        "OPENMW_WORLD_VIEWER_ALLOW_MISSING_SKIN_BONES=1",
        "OPENMW_WORLD_VIEWER_ENABLE_SKIN_PARTITION_FALLBACK=1",
        "OPENMW_WORLD_VIEWER_GENERATE_MISSING_BS_NORMALS=1",
        "OPENMW_WORLD_VIEWER_ATTACH_STATIC_SKELETON_PARTS=1",
        "OPENMW_WORLD_VIEWER_DISABLE_TES5_UNSTABLE_FACE_SURFACE_QUARANTINE=1",
        "OPENMW_ESM4_IDLE_ARM_RELAX_IK=1",
        "OPENMW_WORLD_VIEWER_REQUIRE_CAMERA_SETTLED=",
        "OPENMW_WORLD_VIEWER_START_DRY=1",
        "OPENMW_FNV_BOOTSTRAP_HOUR=12",
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
        "OPENMW_PROOF_STAGE_ACTOR=1",
        "OPENMW_PROOF_ACTOR_STAGE_X=$($actor.pos[0])",
        "OPENMW_PROOF_ACTOR_STAGE_Y=$($actor.pos[1])",
        "OPENMW_PROOF_ACTOR_STAGE_Z=$([double]$actor.pos[2] + $StageZOffset)",
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
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_DISTANCE_SCALE=$(if ($actor.index -ge 9) { 0.65 } else { 1.0 })",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_FIT_PADDING=0.9",
        "OPENMW_PROOF_ACTOR_VIEW_USE_ACTOR_FACING=1",
        "OPENMW_PROOF_ACTOR_VIEW_USE_HEAD_POSE_AXIS=1",
        "OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST=0",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_RAYCAST=0",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_DEGREES=$(if ($actor.index -ge 9) { 210 } else { 270 })",
        "OPENMW_PROOF_ACTOR_VIEW_FRONT_DISTANCE=96",
        "OPENMW_PROOF_ACTOR_VIEW_OFFSET_Z=105",
        "OPENMW_PROOF_ACTOR_VIEW_TARGET_Z=100",
        "OPENMW_PROOF_REQUIRE_ACTOR_FOR_SCREENSHOT=1",
        "OPENMW_PROOF_ACTOR_RESOLVE_RETRY_FRAMES=30"
    )
    if ($actor.isExterior) {
        $env += @(
            "OPENMW_WORLD_VIEWER_START_WORLDSPACE=$(ConvertTo-RuntimeForm '0x3c')",
            "OPENMW_WORLD_VIEWER_START_GRID_X=$($actor.gridX)",
            "OPENMW_WORLD_VIEWER_START_GRID_Y=$($actor.gridY)",
            "OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS=1"
        )
    }
    else {
        # The generic Skyrim catalog start is an exterior Riverwood anchor.
        # Explicitly clear that inherited location so the named interior CELL
        # wins instead of loading Tamriel grid 0,0 at the actor's local coords.
        $env += @(
            "OPENMW_WORLD_VIEWER_START_WORLDSPACE=",
            "OPENMW_WORLD_VIEWER_START_GRID_X=",
            "OPENMW_WORLD_VIEWER_START_GRID_Y="
        )
    }
    $env += @($SetEnv)

    Write-Host "Capturing $($actor.name) in $($actor.startCell)"
    @(& $runner `
        -WorldId skyrim_vr `
        -SeedPath $portraitSeedPath `
        -BinaryRoot $BinaryRoot `
        -ProofRoot $case `
        -RunSeconds $RunSeconds `
        -ScreenshotFrames "999999" `
        -StartCellOverride $actor.startCell `
        -StartPosX ([double]$actor.pos[0]) `
        -StartPosY ([double]$actor.pos[1]) `
        -StartPosZ ([double]$actor.pos[2]) `
        -StartGridX $actor.gridX `
        -StartGridY $actor.gridY `
        -Esm4GridRadius $(if ($actor.isExterior) { 1 } else { 0 }) `
        -FocusActor $actor.runtimeRef `
        -AllowOsgUpdateTraversal `
        -StripOsgUpdateCallbackClass @("NifOsg::", "InitWorldSpaceParticlesCallback") `
        -KeepOsgUpdateCallbackPath "SceneUtil::Skeleton/NPC" `
        -NoTelemetry `
        -WaitForProcessExit:$WaitForProcessExit `
        -SetEnv $env) | Out-Null

    $manifestPath = Get-ChildItem -LiteralPath $case -Filter manifest.json -Recurse -File |
        Sort-Object LastWriteTimeUtc, FullName | Select-Object -Last 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        throw "Skyrim portrait runner did not write a manifest for $($actor.name)."
    }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $result = @($manifest.results)[0]
    $source = [string]$result.screenshot
    $status = [string]$result.status
    $currentRunRoot = Split-Path -Parent $manifestPath
    $nativeSource = Get-ChildItem -LiteralPath $currentRunRoot -Filter "screenshot*.png" -Recurse -File |
        Where-Object { $_.FullName -match '[\\/]skyrim_vr[\\/]userdata[\\/]screenshots[\\/]' } |
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
        index = $actor.index; name = $actor.name; reference = $actor.runtimeRef; base = $actor.runtimeBase
        cell = $actor.startCell; output = $actor.output; status = $status; source = $source
        log = [string]$result.processLog
    }) | Out-Null
}

$ledger = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    worldId = "skyrim_vr"
    rosterCount = 10
    requestedRange = @($MinIndex, $MaxIndex)
    outputRoot = $OutputRoot
    rows = @($rows.ToArray())
}
$ledgerPath = Join-Path $OutputRoot "ledger.json"
$ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ledgerPath -Encoding utf8
$ledger
