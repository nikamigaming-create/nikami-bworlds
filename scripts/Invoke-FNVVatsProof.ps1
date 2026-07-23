[CmdletBinding()]
param(
    [string]$EngineRoot = "D:\code\nikami-openmw-save330-integrated",
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$ParityRoot = "D:\code\nikami-worlds-fnv-parity",
    [string]$SavePath = "C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\Save 331     Goodsprings  00 17 36.fos",
    [string]$TargetName = "Young Bighorner",
    [string]$OutputRoot = "",
    [int]$TimeoutSeconds = 180,
    [int]$CaptureStep = 3,
    [switch]$RequireWitnessResponse,
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
    $OutputRoot = Join-Path $WorldsRoot "run\fnv-vats-scripted-$stamp"
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
$videoPath = Join-Path $OutputRoot "OpenMW-FNV-VATS-scripted-proof.mp4"
$reportPath = Join-Path $OutputRoot "proof-report.json"
$envNames = @(
    "OPENMW_FNV_VATS_PROOF",
    "OPENMW_FNV_VATS_PROOF_TARGET",
    "OPENMW_FNV_VATS_PROOF_CAPTURE_STEP",
    "OPENMW_FNV_VATS_PROOF_REQUIRE_WITNESSES",
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
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_TARGET", $TargetName, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_CAPTURE_STEP", [string][Math]::Max(1, $CaptureStep), "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_VATS_PROOF_REQUIRE_WITNESSES",
        $(if ($RequireWitnessResponse) { "1" } else { $null }), "Process")
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
$resultLine = @($logText -split "`r?`n" | Where-Object { $_ -match 'FNV VATS proof: result=' } | Select-Object -Last 1)
$screenshots = @(Get-ChildItem -LiteralPath $screenshotDir -Filter "*.png" | Sort-Object Name)
$requiredProofPatterns = [ordered]@{
    nativeSaveLoaded = 'FNV VATS proof: stage=targeting'
    bodyShader = 'FNV VATS: skinned highlight enabled=1 rigs=[1-9][0-9]*'
    selectedLimb = 'FNV VATS proof: stage=limb-selected bodyPart=(?!Torso)'
    authoredWindUp = 'FNV VATS weapon visual: .*prepared=1'
    authoredMuzzleFlash = 'FNV combat muzzle flash: .*authoredFlag=1 .*spawned=1'
    shooterCamera = 'FNV VATS camera: execution phase=shooter'
    impactCamera = 'FNV VATS camera: execution phase=impact'
    twoShotsCompleted = 'FNV VATS execution: phase=end interrupted=0 .*shotsFired=2'
    damageAggroCamera = 'FNV VATS proof: result=pass .*damaged=1 aggro=1 .*cameraRestored=1'
}
if ($RequireWitnessResponse) {
    $requiredProofPatterns.witnessResponse = 'FNV VATS proof: result=pass .*witnessResponse=1'
}
$proofGates = [ordered]@{}
foreach ($gate in $requiredProofPatterns.GetEnumerator()) {
    $proofGates[$gate.Key] = [bool]($logText -match $gate.Value)
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
    target = $TargetName
    exitCode = $exitCode
    resultLine = if ($resultLine.Count -eq 1) { $resultLine[0] } else { $null }
    gates = $proofGates
    screenshotCount = $screenshots.Count
    stdout = $stdoutLog
    stderr = $stderrLog
    video = if (Test-Path -LiteralPath $videoPath) { $videoPath } else { $null }
}
Write-Utf8NoBom $reportPath @(($report | ConvertTo-Json -Depth 4))

if (-not $passed) {
    throw "Scripted VATS proof failed. See $reportPath and $stdoutLog"
}
if ($screenshots.Count -lt 10) {
    throw "VATS behavior passed, but native capture produced only $($screenshots.Count) frames."
}

if (-not $KeepFrames -and (Test-Path -LiteralPath $videoPath)) {
    # Preserve representative native frames for visual auditing while avoiding hundreds of redundant PNGs.
    $keep = @($screenshots[0], $screenshots[[Math]::Floor($screenshots.Count / 2)], $screenshots[-1])
    foreach ($frame in $screenshots) {
        if ($keep.FullName -notcontains $frame.FullName) { Remove-Item -LiteralPath $frame.FullName }
    }
}

$report | ConvertTo-Json -Depth 4
