param(
    [switch]$DryRun,
    [switch]$Wait,
    [string]$LoadSavegame = "",
    [string]$FnvRoot = "",
    [string]$BinaryRoot = "",
    [string]$BridgeRoot = "",
    [switch]$AllowCandidateRuntime,
    [switch]$Background,
    [switch]$DisableNavigationMesh,
    [switch]$ForceOpenGlSwapchain,
    [switch]$UseRepoOpenXRSimulator,
    [string]$SimulatorDataDirectory = "",
    [ValidateSet("INFO", "VERBOSE")]
    [string]$LogLevel = "INFO",
    [ValidateSet("default", "legacy", "shaders compatibility", "shaders")]
    [string]$LightingMethod = "default",
    [ValidateRange(0, 100000)]
    [int]$AutoCaptureFrames = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")
. (Join-Path $PSScriptRoot "FNVSaveProfile.ps1")

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
if ($AllowCandidateRuntime -and [string]::IsNullOrWhiteSpace($BinaryRoot)) {
    throw "Candidate runtime mode requires -BinaryRoot so the exact staged VR package is explicit."
}
$runtimeResolution = @{ ParameterValue = $BinaryRoot }
if (-not $AllowCandidateRuntime) {
    $runtimeResolution.RequireCurrent = $true
}
$BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot @runtimeResolution
$ResourcesRoot = if ($AllowCandidateRuntime) {
    Join-Path $BinaryRoot "resources"
} else {
    Resolve-NikamiOpenMWResourcesRoot -RequireCurrent
}
if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
    $BridgeRoot = Join-Path $repoRoot "local\fnv-parity-vr-live"
}
$BridgeRoot = Get-NormalizedPath $BridgeRoot

$repoSimulatorManifest = Join-Path $repoRoot "local\openxr-simulator\openxr_simulator.json"
if ($UseRepoOpenXRSimulator) {
    if (-not (Test-Path -LiteralPath $repoSimulatorManifest -PathType Leaf)) {
        throw "Repo-local OpenXR Simulator is not built. Run scripts\Build-OpenXRSimulator.ps1 first."
    }
    $simulatorManifest = Get-Content -LiteralPath $repoSimulatorManifest -Raw | ConvertFrom-Json
    $simulatorLibrary = [string]$simulatorManifest.runtime.library_path
    if ([string]::IsNullOrWhiteSpace($simulatorLibrary) -or
        -not (Test-Path -LiteralPath $simulatorLibrary -PathType Leaf)) {
        throw "Repo-local OpenXR Simulator manifest has no usable runtime library: $repoSimulatorManifest"
    }
    if ([string]::IsNullOrWhiteSpace($SimulatorDataDirectory)) {
        $SimulatorDataDirectory = Join-Path $BridgeRoot "openxr-simulator"
    }
    $SimulatorDataDirectory = Get-NormalizedPath $SimulatorDataDirectory
    $repoRootNormalized = Get-NormalizedPath $repoRoot
    if (-not $SimulatorDataDirectory.StartsWith($repoRootNormalized, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SimulatorDataDirectory must stay inside this repository: $SimulatorDataDirectory"
    }
}

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
if ($AllowCandidateRuntime) {
    $candidateManifestPath = Join-Path $BinaryRoot "candidate-runtime-manifest.json"
    if (-not (Test-Path -LiteralPath $candidateManifestPath -PathType Leaf)) {
        throw "Candidate runtime use requires its immutable candidate manifest: $candidateManifestPath"
    }
    $candidateManifest = Get-Content -Raw -LiteralPath $candidateManifestPath | ConvertFrom-Json
    if (-not [bool]$candidateManifest.build.vrEnabled -or
        [string]::IsNullOrWhiteSpace([string]$candidateManifest.runtime.openmwVrSha256)) {
        throw "Candidate runtime is not declared as a VR package: $candidateManifestPath"
    }
    $actualVrSha256 = (Get-FileHash -LiteralPath $parityExe -Algorithm SHA256).Hash
    if ($actualVrSha256 -ine [string]$candidateManifest.runtime.openmwVrSha256) {
        throw "Candidate OpenMW VR hash differs from its manifest: $parityExe"
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

if ($DisableNavigationMesh) {
    $bridgeSettings = Join-Path $bridgeConfig "settings.cfg"
    $settingsText = [IO.File]::ReadAllText($bridgeSettings)
    if ($settingsText -match '(?ms)^\[Navigator\](.*?)(?=^\[|\z)') {
        $navigatorSection = $Matches[0]
        if ($navigatorSection -match '(?m)^enable\s*=') {
            $settingsText = $settingsText.Replace($navigatorSection,
                [Text.RegularExpressions.Regex]::Replace($navigatorSection, '(?m)^enable\s*=.*$', 'enable = false'))
        } else {
            $settingsText = $settingsText.Replace($navigatorSection, $navigatorSection.TrimEnd() + "`r`nenable = false`r`n")
        }
    } else {
        $settingsText = $settingsText.TrimEnd() + "`r`n`r`n[Navigator]`r`nenable = false`r`n"
    }
    [IO.File]::WriteAllText($bridgeSettings, $settingsText, [Text.UTF8Encoding]::new($false))
}

if ($ForceOpenGlSwapchain) {
    $bridgeSettings = Join-Path $bridgeConfig "settings.cfg"
    $settingsText = [IO.File]::ReadAllText($bridgeSettings)
    if ($settingsText -match '(?ms)^\[VR Debug\](.*?)(?=^\[|\z)') {
        $vrDebugSection = $Matches[0]
        if ($vrDebugSection -match '(?m)^disable XR_KHR_D3D11_enable\s*=') {
            $settingsText = $settingsText.Replace($vrDebugSection,
                [Text.RegularExpressions.Regex]::Replace($vrDebugSection,
                    '(?m)^disable XR_KHR_D3D11_enable\s*=.*$', 'disable XR_KHR_D3D11_enable = true'))
        } else {
            $settingsText = $settingsText.Replace($vrDebugSection,
                $vrDebugSection.TrimEnd() + "`r`ndisable XR_KHR_D3D11_enable = true`r`n")
        }
    } else {
        $settingsText = $settingsText.TrimEnd() + "`r`n`r`n[VR Debug]`r`ndisable XR_KHR_D3D11_enable = true`r`n"
    }
    [IO.File]::WriteAllText($bridgeSettings, $settingsText, [Text.UTF8Encoding]::new($false))
}

if ($LightingMethod -ne "default") {
    # Keep this strictly per-run: VR itself still owns the required shader setting,
    # while this selects the engine's compatible lighting implementation for diagnosis.
    $bridgeSettings = Join-Path $bridgeConfig "settings.cfg"
    $settingsText = [IO.File]::ReadAllText($bridgeSettings)
    if ($settingsText -match '(?ms)^\[Shaders\](.*?)(?=^\[|\z)') {
        $shaderSection = $Matches[0]
        if ($shaderSection -match '(?m)^lighting method\s*=') {
            $settingsText = $settingsText.Replace($shaderSection,
                [Text.RegularExpressions.Regex]::Replace($shaderSection,
                    '(?m)^lighting method\s*=.*$', "lighting method = $LightingMethod"))
        } else {
            $settingsText = $settingsText.Replace($shaderSection,
                $shaderSection.TrimEnd() + "`r`nlighting method = $LightingMethod`r`n")
        }
    } else {
        $settingsText = $settingsText.TrimEnd() + "`r`n`r`n[Shaders]`r`nlighting method = $LightingMethod`r`n"
    }
    [IO.File]::WriteAllText($bridgeSettings, $settingsText, [Text.UTF8Encoding]::new($false))
}

if (-not [string]::IsNullOrWhiteSpace($LoadSavegame)) {
    $orderedProfile = New-FNVSaveOrderedProfile `
        -SavePath $LoadSavegame `
        -SourceProfileDirectory $madsConfig `
        -DestinationProfileDirectory $bridgeConfig
    Write-Host "Masters: $($orderedProfile.Masters -join ' -> ')"
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

# The established normal runtime uses the default BS program and does not ship
# the later skin program. Validate the shader program shared by both packages.
foreach ($shader in @("shaders\compatibility\bs\default.vert", "shaders\compatibility\bs\default.frag")) {
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
if ($AutoCaptureFrames -gt 0) {
    $argsList.Add("debugimage")
}
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
    "OPENMW_FNV_VR_DEBUG_SNAPSHOT_AUTO_FRAMES",
    "OPENMW_BACKGROUND_LAUNCH",
    "XR_RUNTIME_JSON",
    "OPENXR_SIMULATOR_DATA_DIR"
)) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

Push-Location $BridgeRoot
try {
    $env:OPENMW_STARTUP_SCRIPT = $disabledStartupScript
    $env:OPENMW_BACKGROUND_LAUNCH = "0"
    $env:OPENMW_DEBUG_LEVEL = $LogLevel
    $env:OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = "0"
    $env:OPENMW_FNVXR_RETAIL_SURFACE = "0"
    $env:OPENMW_FNV_VR_DEBUG_SNAPSHOT_AUTO_FRAMES = $AutoCaptureFrames.ToString([Globalization.CultureInfo]::InvariantCulture)
    $env:OPENMW_BACKGROUND_LAUNCH = if ($Background) { "1" } else { "0" }
    if ($UseRepoOpenXRSimulator) {
        New-Item -ItemType Directory -Path $SimulatorDataDirectory -Force | Out-Null
        $env:XR_RUNTIME_JSON = $repoSimulatorManifest
        $env:OPENXR_SIMULATOR_DATA_DIR = $SimulatorDataDirectory
        Write-Host "OpenXR: repo-local simulator (per-process; Windows active runtime unchanged)"
        Write-Host "Simulator data: $SimulatorDataDirectory"
    }
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
