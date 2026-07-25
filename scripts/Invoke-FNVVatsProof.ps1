[CmdletBinding()]
param(
    [ValidateSet("Vats", "OrdinaryRanged", "OrdinaryMelee")]
    [string]$Mode = "Vats",
    [string]$EngineRoot = "D:\code\nikami-openmw-save330-integrated",
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$ParityRoot = "D:\code\nikami-worlds-fnv-parity",
    [string]$SavePath = "C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\Save 331     Goodsprings  00 17 36.fos",
    [string]$TargetName = "Young Bighorner",
    [string]$TargetReference = "",
    [string]$TargetStartCell = "Goodsprings",
    [double]$TargetX = [double]::NaN,
    [double]$TargetY = [double]::NaN,
    [double]$TargetZ = [double]::NaN,
    [double]$TargetYaw = [double]::NaN,
    [double]$TargetDistance = 512,
    [string]$WeaponFormId = "0x0000434f",
    [string]$OutputRoot = "",
    [int]$TimeoutSeconds = 180,
    [int]$CaptureStep = 3,
    [switch]$RequireWitnessResponse,
    [switch]$RequireKill,
    [switch]$SkipBuild,
    [switch]$SkipUnitTests,
    [switch]$KeepFrames
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Quote-Arg([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
    [IO.File]::WriteAllLines($Path, $Lines, [Text.UTF8Encoding]::new($false))
}

$binary = Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\openmw.exe"
$engineResources = Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\resources"
$profileConfig = Join-Path $WorldsRoot "profiles\fallout_new_vegas"
$baselineConfig = Join-Path $ParityRoot "config\playable-baseline"
$graphicsConfig = Join-Path $ParityRoot "config\fnv-playable-graphics"

if ($Mode -eq "OrdinaryMelee" -and $WeaponFormId -eq "0x0000434f") {
    $WeaponFormId = "0x0000421c"
}
$engineProofMode = switch ($Mode) {
    "OrdinaryRanged" { "ordinary-ranged" }
    "OrdinaryMelee" { "ordinary-melee" }
    default { "vats" }
}

if (-not $SkipBuild) {
    & cmake --build (Join-Path $EngineRoot "MSVC2022_64") --config RelWithDebInfo `
        --target openmw openmw-tests components-tests -- /m:6
    if ($LASTEXITCODE -ne 0) { throw "FNV VATS proof build failed with exit code $LASTEXITCODE." }
}
if (-not $SkipUnitTests) {
    & (Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\openmw-tests.exe") `
        --gtest_filter=FalloutWeaponAnimationTest.*:FalloutCombatTest.*
    if ($LASTEXITCODE -ne 0) { throw "FNV VATS mechanics tests failed with exit code $LASTEXITCODE." }
    & (Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\components-tests.exe") `
        --gtest_filter=SceneUtilRigGeometry.*
    if ($LASTEXITCODE -ne 0) { throw "FNV VATS shader tests failed with exit code $LASTEXITCODE." }
}
foreach ($required in @($binary, $engineResources, $SavePath, $profileConfig, $baselineConfig, $graphicsConfig)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required VATS proof input is missing: $required" }
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputRoot = Join-Path $WorldsRoot "run\fnv-combat-$engineProofMode-scripted-$stamp"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$configDir = Join-Path $OutputRoot "config"
$userDataDir = Join-Path $OutputRoot "userdata"
$dataLocalDir = Join-Path $userDataDir "data"
$screenshotDir = Join-Path $userDataDir "screenshots"
New-Item -ItemType Directory -Force -Path $configDir, $dataLocalDir, $screenshotDir | Out-Null

$forwardUserData = $userDataDir.Replace('\', '/')
$forwardDataLocal = $dataLocalDir.Replace('\', '/')
Write-Utf8NoBom (Join-Path $configDir "openmw.cfg") @(
    "user-data=$forwardUserData"
    "data-local=$forwardDataLocal"
    "replace=content"
    "content=FalloutNV.esm"
    "content=DeadMoney.esm"
    "content=HonestHearts.esm"
    "content=OldWorldBlues.esm"
    "content=LonesomeRoad.esm"
    "content=TribalPack.esm"
    "content=MercenaryPack.esm"
    "content=ClassicPack.esm"
    "content=CaravanPack.esm"
    "content=GunRunnersArsenal.esm"
)

Write-Utf8NoBom (Join-Path $configDir "settings.cfg") @(
    "[Video]"
    "resolution x = 1280"
    "resolution y = 720"
    "fullscreen = false"
    "window border = false"
    "vsync mode = 0"
    "framerate limit = 60"
    ""
    "[Input]"
    "grab cursor = false"
    ""
    "[GUI]"
    "subtitles = true"
    ""
    "[General]"
    "screenshot format = png"
    "notify on saved screenshot = false"
)
$profileShaderSettings = Join-Path $profileConfig "shaders.yaml"
if (Test-Path -LiteralPath $profileShaderSettings) {
    Copy-Item -LiteralPath $profileShaderSettings -Destination (Join-Path $configDir "shaders.yaml") -Force
}

$stdoutLog = Join-Path $OutputRoot "stdout.log"
$stderrLog = Join-Path $OutputRoot "stderr.log"
$videoPath = Join-Path $OutputRoot "OpenMW-FNV-$Mode-scripted-proof.mp4"
$reportPath = Join-Path $OutputRoot "proof-report.json"
$envNames = @(
    "OPENMW_FNV_VATS_PROOF",
    "OPENMW_FNV_VATS_PROOF_MODE",
    "OPENMW_FNV_VATS_PROOF_TARGET",
    "OPENMW_FNV_VATS_PROOF_TARGET_REF",
    "OPENMW_FNV_VATS_PROOF_START_CELL",
    "OPENMW_FNV_VATS_PROOF_TARGET_X",
    "OPENMW_FNV_VATS_PROOF_TARGET_Y",
    "OPENMW_FNV_VATS_PROOF_TARGET_Z",
    "OPENMW_FNV_VATS_PROOF_TARGET_YAW",
    "OPENMW_FNV_VATS_PROOF_TARGET_DISTANCE",
    "OPENMW_FNV_VATS_PROOF_WEAPON",
    "OPENMW_FNV_VATS_PROOF_CAPTURE_STEP",
    "OPENMW_FNV_VATS_PROOF_REQUIRE_WITNESSES",
    "OPENMW_FNV_VATS_PROOF_REQUIRE_KILL",
    "OPENMW_PLAYABLE_SESSION_BACKGROUND",
    "OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG",
    "OPENMW_FNV_SAVE_TRACE"
)
$previousEnvironment = @{}
foreach ($name in $envNames) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

$process = $null
$exitCode = $null
try {
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_MODE", $engineProofMode, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_TARGET", $TargetName, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_TARGET_REF",
        $(if ([string]::IsNullOrWhiteSpace($TargetReference)) { $null } else { $TargetReference }), "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_START_CELL", $TargetStartCell, "Process")
    $targetCoordinates = @($TargetX, $TargetY, $TargetZ, $TargetYaw)
    $configuredCoordinates = @($targetCoordinates | Where-Object { -not [double]::IsNaN($_) }).Count
    if ($configuredCoordinates -ne 0 -and $configuredCoordinates -ne 4) {
        throw "TargetX, TargetY, TargetZ, and TargetYaw must be supplied together."
    }
    if ($configuredCoordinates -eq 4) {
        $invariant = [System.Globalization.CultureInfo]::InvariantCulture
        [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_TARGET_X", $TargetX.ToString("R", $invariant), "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_TARGET_Y", $TargetY.ToString("R", $invariant), "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_TARGET_Z", $TargetZ.ToString("R", $invariant), "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_TARGET_YAW", $TargetYaw.ToString("R", $invariant), "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_TARGET_DISTANCE", $TargetDistance.ToString("R", $invariant), "Process")
    }
    else {
        foreach ($name in @(
            "OPENMW_FNV_VATS_PROOF_TARGET_X",
            "OPENMW_FNV_VATS_PROOF_TARGET_Y",
            "OPENMW_FNV_VATS_PROOF_TARGET_Z",
            "OPENMW_FNV_VATS_PROOF_TARGET_YAW",
            "OPENMW_FNV_VATS_PROOF_TARGET_DISTANCE"
        )) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_WEAPON", $WeaponFormId, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_CAPTURE_STEP", [string][Math]::Max(1, $CaptureStep), "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_REQUIRE_WITNESSES",
        $(if ($RequireWitnessResponse) { "1" } else { $null }), "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_REQUIRE_KILL",
        $(if ($RequireKill) { "1" } else { $null }), "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_PLAYABLE_SESSION_BACKGROUND", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_SAVE_TRACE", "1", "Process")

    $arguments = @(
        "--replace", "config",
        "--config", $profileConfig,
        "--config", $baselineConfig,
        "--config", $graphicsConfig,
        "--config", $configDir,
        "--user-data", $userDataDir,
        "--data-local", $dataLocalDir,
        "--resources", $engineResources,
        "--skip-menu",
        "--load-savegame", $SavePath,
        "--no-sound"
    )
    $argumentLine = ($arguments | ForEach-Object { Quote-Arg $_ }) -join " "
    $process = Start-Process -FilePath $binary -ArgumentList $argumentLine `
        -WorkingDirectory (Split-Path -Parent $binary) -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
    }
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        throw "VATS proof timed out after $TimeoutSeconds seconds. Only proof PID $($process.Id) was stopped."
    }
    $process.WaitForExit()
    $process.Refresh()
    $exitCode = $process.ExitCode
}
finally {
    foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], "Process")
    }
}

$logText = if (Test-Path -LiteralPath $stdoutLog) { Get-Content -LiteralPath $stdoutLog -Raw } else { "" }
$resultPattern = if ($Mode -eq "Vats") {
    'FNV VATS proof: result='
}
else {
    'FNV ordinary combat proof: result='
}
$resultLine = @($logText -split "`r?`n" | Where-Object { $_ -match $resultPattern } | Select-Object -Last 1)
$screenshots = @(Get-ChildItem -LiteralPath $screenshotDir -Filter "*.png" | Sort-Object Name)
$enemyActorPattern = 'object0x[0-9a-f]+'
if ($TargetReference -match '^0[xX]0*([0-9a-fA-F]+)$') {
    $enemyActorPattern = 'object0x0*' + [regex]::Escape($Matches[1])
}
$enemyRangedReturnFirePattern =
    '(?:FNV moving projectile impact: actor=' + $enemyActorPattern +
    ' .*target=object@0x1 \(NPC, "Player"\)|FNV combat actor impact: attacker=' +
    $enemyActorPattern + ' .*target=object@0x1 \(NPC, "Player"\) .*healthDamage=[1-9])'
$enemyMeleeBackPattern =
    'FNV combat melee: actor=' + $enemyActorPattern +
    ' .*actorHit=1 .*target=object@0x1 \(NPC, "Player"\) .*status=pass'
$enemyRetaliationPattern =
    '(?:' + $enemyRangedReturnFirePattern + '|' + $enemyMeleeBackPattern + ')'
$requiredProofPatterns = if ($Mode -eq "Vats") {
    [ordered]@{
        nativeSaveLoaded = 'FNV VATS proof: stage=targeting'
        bodyShader = 'FNV VATS: skinned highlight enabled=1 rigs=[1-9][0-9]*'
        selectedLimb = 'FNV VATS proof: stage=limb-selected bodyPart=(?!Torso)'
        authoredWindUp = 'FNV VATS weapon visual: .*prepared=1'
        authoredMuzzleFlash = 'FNV combat muzzle flash: .*authoredFlag=1 .*node=ProjectileNode .*spawned=1'
        shooterCamera = 'FNV VATS camera: execution phase=shooter'
        impactCamera = 'FNV VATS camera: execution phase=impact'
        exact10mmSelected = 'FNV VATS proof weapon selected: form=0x[0-9a-f]*434f name=10mm Pistol'
        fourShotsCompleted = 'FNV VATS execution: phase=end interrupted=0 .*shotsFired=4'
        combatTownAggroCamera = 'FNV VATS proof: result=pass .*damaged=1 .*aggro=1 .*hostileWitnesses=[1-9][0-9]* .*cameraRestored=1'
    }
}
elseif ($Mode -eq "OrdinaryRanged") {
    [ordered]@{
        exact10mmSelected = 'FNV combat proof weapon selected: form=0x[0-9a-f]*434f name=10mm Pistol .*mode=ordinary-ranged'
        exact10mmFirstPersonPose = 'FNV first-person animation: actor=Player semantic=idle .*overlay=meshes/characters/_1stperson/1hpaim\.kf weapon=Weap10mmPistol bound=1'
        normalUseInput = 'FNV player use input: down=1 attack=1 .*vatsPhase=0'
        playerMuzzleFlash = 'FNV combat muzzle flash: actor=object@0x1 .*authoredFlag=1 .*spawned=1'
        playerShot = 'FNV combat shot: actor=object@0x1 .*weapon=FormId:0x[0-9a-f]*434f .*status=pass'
        exact10mmNoTracer = 'FNV combat shot: actor=object@0x1 .*projectile=FormId:0x[0-9a-f]*2cd5f .*authoredHitscan=1 tracerChance=0 movingProjectiles=0 hitscanTracers=0 .*status=pass'
        enemyRetaliation = $enemyRetaliationPattern
        reciprocalDamage = 'FNV ordinary combat proof: result=pass mode=ordinary-ranged .*targetDamaged=1 .*playerDamaged=1'
    }
}
else {
    [ordered]@{
        exactBaseballBatSelected = 'FNV combat proof weapon selected: form=0x[0-9a-f]*421c name=Baseball Bat .*mode=ordinary-melee'
        normalUseInput = 'FNV player use input: down=1 attack=1 .*vatsPhase=0'
        playerMeleeHit = 'FNV combat melee: actor=object@0x1 .*weapon=FormId:0x[0-9a-f]*421c .*actorHit=1 .*target=object0x[0-9a-f]+ .*status=pass'
        enemyMeleeBack = $enemyMeleeBackPattern
        reciprocalDamage = 'FNV ordinary combat proof: result=pass mode=ordinary-melee .*targetDamaged=1 .*playerDamaged=1'
    }
}
if (-not [string]::IsNullOrWhiteSpace($TargetReference)) {
    $requiredProofPatterns.exactAuthoredTarget = if ($Mode -eq "Vats") {
        'FNV VATS proof: exact authored target selected ref=FormId:0x[0-9a-f]+ name=' + [regex]::Escape($TargetName)
    }
    else {
        'FNV ordinary combat proof: exact authored target acquired ref=FormId:0x[0-9a-f]+ name=' +
            [regex]::Escape($TargetName)
    }
}
if ($RequireWitnessResponse) {
    $requiredProofPatterns.witnessResponse = 'FNV VATS proof: result=pass .*witnessResponse=1'
}
if ($RequireKill) {
    $requiredProofPatterns.killed = 'FNV VATS proof: result=pass .*killed=1'
}
$proofGates = [ordered]@{}
foreach ($gate in $requiredProofPatterns.GetEnumerator()) {
    $proofGates[$gate.Key] = [bool]($logText -match $gate.Value)
}
$proofObservations = [ordered]@{
    enemyRangedReturnFire = [bool]($logText -match $enemyRangedReturnFirePattern)
    enemyMeleeBack = [bool]($logText -match $enemyMeleeBackPattern)
}
$passed = ($null -eq $exitCode -or $exitCode -eq 0) `
    -and $resultLine.Count -eq 1 -and $resultLine[0] -match 'result=pass' `
    -and @($proofGates.Values | Where-Object { -not $_ }).Count -eq 0

$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($null -ne $ffmpeg -and $screenshots.Count -gt 1) {
    $concatPath = Join-Path $OutputRoot "frames.txt"
    $concatLines = @($screenshots | ForEach-Object {
        "file '$($_.FullName.Replace("'", "'\''"))'`nduration 0.05"
    }) + "file '$($screenshots[-1].FullName.Replace("'", "'\''"))'"
    Write-Utf8NoBom $concatPath $concatLines
    & $ffmpeg.Source -hide_banner -loglevel error -y -f concat -safe 0 -i $concatPath `
        -vf "fps=20,format=yuv420p" -c:v libx264 -crf 18 -movflags +faststart $videoPath
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed to encode the scripted VATS proof." }
}

$report = [ordered]@{
    passed = $passed
    mode = $Mode
    target = $TargetName
    targetReference = $TargetReference
    exitCode = $exitCode
    resultLine = if ($resultLine.Count -eq 1) { $resultLine[0] } else { $null }
    gates = $proofGates
    observations = $proofObservations
    screenshotCount = $screenshots.Count
    stdout = $stdoutLog
    stderr = $stderrLog
    video = if (Test-Path -LiteralPath $videoPath) { $videoPath } else { $null }
}
Write-Utf8NoBom $reportPath @(($report | ConvertTo-Json -Depth 4))

if (-not $passed) {
    throw "Scripted $Mode combat proof failed. See $reportPath and $stdoutLog"
}
if ($screenshots.Count -lt 10) {
    throw "$Mode combat behavior passed, but native capture produced only $($screenshots.Count) frames."
}

if (-not $KeepFrames -and (Test-Path -LiteralPath $videoPath)) {
    # Preserve representative native frames for visual auditing while avoiding hundreds of redundant PNGs.
    $keep = @($screenshots[0], $screenshots[[Math]::Floor($screenshots.Count / 2)], $screenshots[-1])
    foreach ($frame in $screenshots) {
        if ($keep.FullName -notcontains $frame.FullName) { Remove-Item -LiteralPath $frame.FullName }
    }
}

$report | ConvertTo-Json -Depth 4
