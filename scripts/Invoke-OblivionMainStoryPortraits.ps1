param(
    [string]$OutputRoot = "D:\code\nikami-worlds\run\oblivion-main-story-portraits",
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
$seedPath = Join-Path (Split-Path $PSScriptRoot -Parent) "catalog\world-walker.seed.json"
$pngRoot = Join-Path $OutputRoot "png"
$caseRoot = Join-Path $OutputRoot "captures"
New-Item -ItemType Directory -Force -Path $pngRoot, $caseRoot | Out-Null

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

# These base records, ACHR references, cells, and coordinates are read from the
# installed Oblivion.esm with export_esm4_catalog.py. The roster follows named
# people encountered across the original game's base main quest.
$actors = @(
    New-Actor 1  "Emperor Uriel Septim" "emperor-uriel-septim" "0x32a18" "0x23f2e" "ImperialDungeon01"                   $false -535.1440 1157.0109 489.1314
    New-Actor 2  "Baurus"               "baurus"               "0x32a17" "0x23f2a" "ImperialDungeon01"                   $false -512.7917 1194.6314 514.0368
    New-Actor 3  "Jauffre"              "jauffre"              "0x1cb98" "0x23999" "WeynonPrioryHouse"                   $false 346.0506  -257.2416 -146.9054
    New-Actor 4  "Brother Martin"       "brother-martin"       "0x1e745" "0x33907" "KvatchChapelofAkatosh"               $false 1239.2404 -3.1332   -1152.0019
    New-Actor 5  "Mankar Camoran"       "mankar-camoran"       "0x3392d" "0x33908" "LakeArriusShrineDagon"               $false 6024.7519 -1404.2574 -492.7660
    New-Actor 6  "Tar-Meena"            "tar-meena"            "0x34ebc" "0x34eb2" "ICArcaneUniversityMysticArchives"    $false 10.6075   86.4414   -236.0729
    New-Actor 7  "High Chancellor Ocato" "high-chancellor-ocato" "0x1469a" "0x14699" "ICPalaceElderCouncilChambers"         $false -496.1174 363.7604  -95.9999
    New-Actor 8  "Ruma Camoran"         "ruma-camoran"         "0x1fb2e" "0x2952d" "LakeArriusShrineDagon"               $false 6188.0    -1272.0   -492.7660
    New-Actor 9  "Raven Camoran"        "raven-camoran"        "0x22ccc" "0xabb5"  "ImperialSewersElvenGardens02"        $false -15.8851  2829.9206 6062.0791
    New-Actor 10 "Captain Renault"      "captain-renault"      "0x32a15" "0x2349f" "ImperialDungeon01"                   $false -477.1016 1144.0639 487.4056
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
        "OPENMW_WORLD_VIEWER_AUTOPLAY_NPC_IDLE=1",
        "OPENMW_WORLD_VIEWER_NPC_ANIMATION_SOURCES=meshes/characters/_male/idle.kf",
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
        "OPENMW_ESM4_IDLE_ARM_RELAX_IK=1",
        "OPENMW_WORLD_VIEWER_PORTRAIT_ACTOR_FILL=1",
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
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_MARGIN=0.05",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_DISTANCE_SCALE=1.0",
        "OPENMW_PROOF_ACTOR_VIEW_FULL_BODY_FIT_PADDING=0.9",
        "OPENMW_PROOF_ACTOR_VIEW_USE_ACTOR_FACING=1",
        "OPENMW_PROOF_ACTOR_VIEW_USE_HEAD_POSE_AXIS=1",
        "OPENMW_PROOF_ACTOR_VIEW_VISIBILITY_RAYCAST=0",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_RAYCAST=0",
        "OPENMW_PROOF_ACTOR_VIEW_ORBIT_DEGREES=0",
        "OPENMW_PROOF_ACTOR_VIEW_FRONT_DISTANCE=96",
        "OPENMW_PROOF_ACTOR_VIEW_OFFSET_Z=105",
        "OPENMW_PROOF_ACTOR_VIEW_TARGET_Z=100",
        "OPENMW_PROOF_REQUIRE_ACTOR_FOR_SCREENSHOT=1",
        "OPENMW_PROOF_ACTOR_RESOLVE_RETRY_FRAMES=30",
        "OPENMW_WORLD_VIEWER_START_WORLDSPACE=",
        "OPENMW_WORLD_VIEWER_START_GRID_X=",
        "OPENMW_WORLD_VIEWER_START_GRID_Y="
    )
    $env += @($SetEnv)

    Write-Host "Capturing $($actor.name) in $($actor.startCell)"
    @(& $runner `
        -WorldId oblivion `
        -SeedPath $seedPath `
        -BinaryRoot $BinaryRoot `
        -ProofRoot $case `
        -RunSeconds $RunSeconds `
        -VideoWidth 1920 `
        -VideoHeight 1080 `
        -ScreenshotFrames "999999" `
        -StartCellOverride $actor.startCell `
        -StartPosX ([double]$actor.pos[0]) `
        -StartPosY ([double]$actor.pos[1]) `
        -StartPosZ ([double]$actor.pos[2]) `
        -StartGridX $actor.gridX `
        -StartGridY $actor.gridY `
        -Esm4GridRadius 0 `
        -FocusActor $actor.runtimeRef `
        -AllowOsgUpdateTraversal `
        -StripOsgUpdateCallbackClass @("NifOsg::", "InitWorldSpaceParticlesCallback") `
        -KeepOsgUpdateCallbackPath "SceneUtil::Skeleton/Bip01" `
        -NoTelemetry `
        -WaitForProcessExit:$WaitForProcessExit `
        -SetEnv $env) | Out-Null

    $manifestPath = Get-ChildItem -LiteralPath $case -Filter manifest.json -Recurse -File |
        Sort-Object LastWriteTimeUtc, FullName | Select-Object -Last 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        throw "Oblivion portrait runner did not write a manifest for $($actor.name)."
    }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $result = @($manifest.results)[0]
    $source = [string]$result.screenshot
    $status = [string]$result.status
    $processLog = [string]$result.processLog
    $currentRunRoot = Split-Path -Parent $manifestPath
    $nativeSource = Get-ChildItem -LiteralPath $currentRunRoot -Filter "screenshot*.png" -Recurse -File |
        Where-Object { $_.FullName -match '[\\/]oblivion[\\/]userdata[\\/]screenshots[\\/]' } |
        Sort-Object LastWriteTimeUtc, FullName | Select-Object -Last 1 -ExpandProperty FullName
    if (-not [string]::IsNullOrWhiteSpace($nativeSource)) {
        $source = $nativeSource
        $status = "screenshot"
    }
    $equipmentVerified = $false
    if (-not [string]::IsNullOrWhiteSpace($processLog) -and (Test-Path -LiteralPath $processLog -PathType Leaf)) {
        $equipmentLine = Select-String -LiteralPath $processLog -Pattern 'ESM4 diag: TES4 equipment gate .* clothed=(\d+)' |
            Select-Object -Last 1
        if ($null -ne $equipmentLine -and $equipmentLine.Matches.Count -gt 0) {
            $equipmentVerified = $equipmentLine.Matches[0].Groups[1].Value -eq '1'
        }
    }
    if (-not $equipmentVerified) {
        $status = "rejected-undressed"
    }
    if ($status -eq "screenshot" -and -not [string]::IsNullOrWhiteSpace($source) -and
        (Test-Path -LiteralPath $source -PathType Leaf)) {
        Copy-Item -LiteralPath $source -Destination $actor.output -Force
        $status = "captured"
    }
    $rows.Add([pscustomobject][ordered]@{
        index = $actor.index; name = $actor.name; reference = $actor.runtimeRef; base = $actor.runtimeBase
        cell = $actor.startCell; output = $actor.output; status = $status; source = $source
        log = $processLog; equipmentVerified = $equipmentVerified
    }) | Out-Null
}

$ledger = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    worldId = "oblivion"
    rosterCount = 10
    requestedRange = @($MinIndex, $MaxIndex)
    outputRoot = $OutputRoot
    rows = @($rows.ToArray())
}
$ledgerPath = Join-Path $OutputRoot "ledger.json"
$ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ledgerPath -Encoding utf8
$ledger
