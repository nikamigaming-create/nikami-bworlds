param(
    [switch]$DryRun,
    [switch]$Wait,
    [string]$LoadSavegame = "",
    [string]$FnvRoot = "",
    [string]$BinaryRoot = "",
    [string]$BridgeRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

function Get-NormalizedPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-OrCreateJunction([string]$Path, [string]$Target) {
    $targetPath = Get-NormalizedPath $Target
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        $targets = @($item.Target | ForEach-Object { Get-NormalizedPath ([string]$_) })
        if ($item.LinkType -ne "Junction" -or $targets -inotcontains $targetPath) {
            throw "VR bridge path already exists with the wrong target: $Path"
        }
        return
    }
    New-Item -ItemType Junction -Path $Path -Target $targetPath | Out-Null
}

function Assert-OrCreateHardLink([string]$Path, [string]$Target) {
    if (Test-Path -LiteralPath $Path) {
        $left = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
        $right = (Get-FileHash -Algorithm SHA256 -LiteralPath $Target).Hash
        if ($left -cne $right) {
            throw "VR bridge launcher differs from Mads's launcher: $Path"
        }
        return
    }
    New-Item -ItemType HardLink -Path $Path -Target $Target | Out-Null
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$FnvRoot = Resolve-NikamiPath `
    -ParameterValue $FnvRoot `
    -EnvName "NIKAMI_FNV_ROOT" `
    -ConfigName "fnvRoot" `
    -Required `
    -Description "Mads-calibrated FNV/OpenMW VR root"
$BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$ResourcesRoot = Resolve-NikamiOpenMWResourcesRoot
if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
    $BridgeRoot = Join-Path $repoRoot "local\fnv-parity-vr-live"
}
$BridgeRoot = Get-NormalizedPath $BridgeRoot

$madsLauncher = Join-Path $FnvRoot "run_vr.bat"
$madsConfig = Join-Path $FnvRoot "openmw-config"
$madsData = Join-Path $madsConfig "data"
$parityExe = Join-Path $BinaryRoot "openmw_vr.exe"
$parityResources = Join-Path $BinaryRoot "resources"

foreach ($required in @($madsLauncher, $madsConfig, $madsData, $parityExe, $parityResources)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required FNV VR input: $required"
    }
}
if ((Get-NormalizedPath $parityResources) -ine (Get-NormalizedPath $ResourcesRoot)) {
    throw "Parity binary and resources must come from the same packaged runtime."
}

$running = @(Get-Process -Name "openmw_vr" -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    throw "openmw_vr is already running. Close it before preparing or launching another FNV VR session."
}

$bridgeBuildRoot = Join-Path $BridgeRoot "openmw-source\MSVC2022_64"
$bridgeRelease = Join-Path $bridgeBuildRoot "Release"
$bridgeConfig = Join-Path $BridgeRoot "openmw-config"
$bridgeData = Join-Path $bridgeConfig "data"
$bridgeLauncher = Join-Path $BridgeRoot "run_vr.bat"
$bridgeSaves = Join-Path $bridgeConfig "saves\player - 1"
$disabledStartupScript = Join-Path $bridgeConfig "natural-play-no-startup-script.txt"

New-Item -ItemType Directory -Path $BridgeRoot, $bridgeBuildRoot, $bridgeConfig, $bridgeSaves -Force | Out-Null
Assert-OrCreateJunction -Path $bridgeRelease -Target $BinaryRoot
Assert-OrCreateJunction -Path $bridgeData -Target $madsData
Assert-OrCreateHardLink -Path $bridgeLauncher -Target $madsLauncher

foreach ($name in @("openmw.cfg", "settings.cfg", "input_v3.xml", "player_storage.bin", "global_storage.bin", "shaders.yaml")) {
    $source = Join-Path $madsConfig $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing Mads VR configuration input: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $bridgeConfig $name) -Force
}

$bridgeOpenmwConfig = Join-Path $bridgeConfig "openmw.cfg"
$configText = [IO.File]::ReadAllText($bridgeOpenmwConfig)
if ($configText -notmatch '(?m)^resources=.*$') {
    throw "Mads VR configuration has no resources entry: $bridgeOpenmwConfig"
}
$resourceValue = (Get-NormalizedPath $ResourcesRoot).Replace('\', '/')
$configText = [Text.RegularExpressions.Regex]::Replace(
    $configText,
    '(?m)^resources=.*$',
    "resources=$resourceValue",
    [Text.RegularExpressions.RegexOptions]::None,
    [TimeSpan]::FromSeconds(1))
[IO.File]::WriteAllText($bridgeOpenmwConfig, $configText, [Text.UTF8Encoding]::new($false))

# Mads's VR calibration is authoritative for hands, controls, and menu projection, but the
# active-grid object-paging path is not yet part of the FNV acceptance baseline.  Keeping it
# enabled can let cached paged nodes suppress the live chairs, crates, and scenery when the
# player crosses a cell boundary.  Apply this one graphics safety override after every copy so
# a new launch cannot silently restore the broken setting.
$bridgeSettings = Join-Path $bridgeConfig "settings.cfg"
$settingsText = [IO.File]::ReadAllText($bridgeSettings)
if ($settingsText -notmatch '(?m)^object paging active grid\s*=.*$') {
    throw "Mads VR settings have no active-grid paging entry: $bridgeSettings"
}
$settingsText = [Text.RegularExpressions.Regex]::Replace(
    $settingsText,
    '(?m)^object paging active grid\s*=.*$',
    'object paging active grid = false',
    [Text.RegularExpressions.RegexOptions]::None,
    [TimeSpan]::FromSeconds(1))
[IO.File]::WriteAllText($bridgeSettings, $settingsText, [Text.UTF8Encoding]::new($false))

foreach ($shader in @("shaders\compatibility\bs\skin.vert", "shaders\compatibility\bs\skin.frag")) {
    if (-not (Test-Path -LiteralPath (Join-Path $ResourcesRoot $shader) -PathType Leaf)) {
        throw "Parity VR resources are incomplete: missing $shader"
    }
}
if (Test-Path -LiteralPath $disabledStartupScript) {
    throw "Reserved no-injection startup path unexpectedly exists: $disabledStartupScript"
}

$argsList = [Collections.Generic.List[string]]::new()
if ($DryRun) {
    $argsList.Add("dryrun")
}
$argsList.Add("nopause")
if ([string]::IsNullOrWhiteSpace($LoadSavegame)) {
    $argsList.Add("nosave")
} else {
    $savePath = Get-NormalizedPath $LoadSavegame
    if (-not (Test-Path -LiteralPath $savePath -PathType Leaf)) {
        throw "Requested FNV VR save does not exist: $savePath"
    }
    $argsList.Add("savefile")
    $argsList.Add($savePath)
}

Write-Host "FNV VR runtime: current parity build with Mads's unchanged VR calibration"
Write-Host "Exe:     $parityExe"
Write-Host "Config:  $bridgeConfig"
Write-Host "Start:   $(if ([string]::IsNullOrWhiteSpace($LoadSavegame)) { 'fresh authored Goodsprings' } else { $LoadSavegame })"
Write-Host "Safety:  no generic main menu, no proof save, no startup script"

$savedEnvironment = @{}
foreach ($name in @(
    "OPENMW_STARTUP_SCRIPT",
    "OPENMW_BACKGROUND_LAUNCH",
    "OPENMW_DEBUG_LEVEL",
    "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY",
    "OPENMW_FNVXR_RETAIL_SURFACE",
    "OPENMW_FNV_VR_DEBUG_SNAPSHOT_AUTO_FRAMES"
)) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

Push-Location $BridgeRoot
try {
    $env:OPENMW_STARTUP_SCRIPT = $disabledStartupScript
    $env:OPENMW_BACKGROUND_LAUNCH = "0"
    $env:OPENMW_DEBUG_LEVEL = "INFO"
    $env:OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = "0"
    $env:OPENMW_FNVXR_RETAIL_SURFACE = "0"
    $env:OPENMW_FNV_VR_DEBUG_SNAPSHOT_AUTO_FRAMES = "0"
    & $env:ComSpec /d /c run_vr.bat @($argsList.ToArray())
    $launcherExitCode = $LASTEXITCODE
}
finally {
    Pop-Location
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
}

if ($DryRun) {
    if ($launcherExitCode -ne 0) {
        throw "FNV parity VR dry run failed with code $launcherExitCode"
    }
    exit 0
}

$live = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -ieq "openmw_vr.exe" -and $_.CommandLine -notmatch '^--crash-monitor'
})
if ($live.Count -eq 0) {
    throw "FNV parity VR did not remain running. See $bridgeConfig\openmw.log"
}
if ($launcherExitCode -ne 0) {
    Write-Warning "Mads's batch monitor returned $launcherExitCode after launch, but the parity VR process is alive."
}

Write-Host "FNV parity VR is running as PID $($live[0].ProcessId)."
if ($Wait) {
    $process = Get-Process -Id $live[0].ProcessId
    $process.WaitForExit()
    exit $process.ExitCode
}

# The batch helper can return a non-zero monitor status even after the real VR
# process is confirmed alive. Do not leak that stale native exit code to callers.
exit 0
