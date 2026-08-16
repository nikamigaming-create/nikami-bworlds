param(
    [switch]$DryRun,
    [switch]$Wait,
    [string]$LoadSavegame = "",
    [string]$FnvRoot = "",
    [string]$BinaryRoot = "",
    [string]$BridgeRoot = "",
    [switch]$AllowCandidateRuntime,
    [switch]$DiagnosticCandidate,
    [switch]$Background,
    [switch]$DisableNavigationMesh,
    [switch]$ForceOpenGlSwapchain,
    [switch]$UseRepoOpenXRSimulator,
    [switch]$UseLegacyVrCalibration,
    [switch]$StaticizedHandDiagnostics,
    [switch]$ControllerPoseDiagnostics,
    [switch]$InteractionProofLoadout,
    [string]$PipBoyRttCapturePath = "",
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
if ($DiagnosticCandidate -and -not $AllowCandidateRuntime) {
    throw "-DiagnosticCandidate is only valid with an explicitly selected candidate runtime."
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

$madsConfig = Join-Path $FnvRoot "openmw-config"
$parityExe = Join-Path $BinaryRoot "openmw_vr.exe"
$parityResources = Join-Path $BinaryRoot "resources"

foreach ($required in @($madsConfig, $parityExe, $parityResources)) {
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
    $requiredReleaseStatus = "flat-and-vr-simulator-verified"
    if ([string]$candidateManifest.status -ine $requiredReleaseStatus -and -not $DiagnosticCandidate) {
        throw "Candidate runtime is not release-verified (status '$($candidateManifest.status)'). Refusing a normal VR launch. Use -DiagnosticCandidate only for unattended repair work; publish paired flat and simulator-VR evidence before player testing."
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
$bridgeSaves = Join-Path $bridgeConfig "saves\player - 1"
$disabledStartupScript = Join-Path $bridgeConfig "natural-play-no-startup-script.txt"

New-Item -ItemType Directory -Path $BridgeRoot, $bridgeBuildRoot, $bridgeConfig, $bridgeSaves -Force | Out-Null
Assert-OrCreateJunction -Path $bridgeRelease -Target $BinaryRoot

$madsOpenmwConfig = Join-Path $madsConfig "openmw.cfg"
$madsInput = Join-Path $madsConfig "input_v3.xml"
foreach ($requiredConfig in @($madsOpenmwConfig, $madsInput)) {
    if (-not (Test-Path -LiteralPath $requiredConfig -PathType Leaf)) {
        throw "Missing Mads VR configuration input: $requiredConfig"
    }
}
$sourceDataEntries = @(
    [Text.RegularExpressions.Regex]::Matches([IO.File]::ReadAllText($madsOpenmwConfig), '(?m)^data=(.+)$') |
        ForEach-Object { $_.Groups[1].Value.Trim() } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ "FalloutNV.esm") -PathType Leaf }
)
if ($sourceDataEntries.Count -ne 1) {
    throw "VR launch must resolve exactly one Fallout New Vegas Data directory from its source profile; found $($sourceDataEntries.Count)."
}

# The old VR profile is a Morrowind-era working profile.  Its inherited VFS,
# settings, and storage can replace FNV textures (including binding stars to
# world meshes).  Generate the same isolated FNV profile used by flat proof,
# then retain only the controller map. The legacy [VR] calibration can be
# explicitly enabled for comparison, but is never inherited by default.
# All generated paths are repository-relative to this launch.
$profileKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($BridgeRoot))).Substring(0, 16).ToLowerInvariant()
$generatedProfile = Join-Path $repoRoot "profiles\_verification\vr-launch-$profileKey"
$generatedCampaign = Join-Path $repoRoot "profiles\_verification\_campaigns\vr-launch-$profileKey\userdata"
$profileInitializer = Join-Path $PSScriptRoot "Initialize-OpenNVBaseProfile.ps1"
$generated = & $profileInitializer `
    -FalloutNewVegasData $sourceDataEntries[0] `
    -ProfileDirectory $generatedProfile `
    -CampaignUserdataDirectory $generatedCampaign `
    -BinaryRoot $BinaryRoot `
    -Force
if (-not [bool]$generated.launchable) {
    throw "Could not prepare isolated FNV VR profile: $generatedProfile"
}
foreach ($name in @("openmw.cfg", "settings.cfg")) {
    Copy-Item -LiteralPath (Join-Path $generatedProfile $name) -Destination (Join-Path $bridgeConfig $name) -Force
}
Copy-Item -LiteralPath $madsInput -Destination (Join-Path $bridgeConfig "input_v3.xml") -Force
if ($UseLegacyVrCalibration) {
    $madsSettings = Join-Path $madsConfig "settings.cfg"
    if (-not (Test-Path -LiteralPath $madsSettings -PathType Leaf)) {
        throw "Missing optional legacy VR calibration source: $madsSettings"
    }
    $legacyVrSection = [Text.RegularExpressions.Regex]::Match(
        [IO.File]::ReadAllText($madsSettings), '(?ms)^\[VR\]\s*.*?(?=^\[|\z)').Value.Trim()
    if (-not [string]::IsNullOrWhiteSpace($legacyVrSection)) {
        [IO.File]::AppendAllText(
            (Join-Path $bridgeConfig "settings.cfg"),
            [Environment]::NewLine + [Environment]::NewLine + $legacyVrSection + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false))
    }
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
# The generated profile has exactly one validated FNV mount.  Reject any
# unexpected addition instead of rewriting mount order at launch time.
$generatedDataEntries = @(
    [Text.RegularExpressions.Regex]::Matches($configText, '(?m)^data=(.+)$') |
        ForEach-Object { $_.Groups[1].Value.Trim() }
)
if ($generatedDataEntries.Count -ne 1 -or
    -not (Test-Path -LiteralPath (Join-Path $generatedDataEntries[0] "FalloutNV.esm") -PathType Leaf)) {
    throw "Generated VR profile must contain exactly one valid Fallout New Vegas Data mount."
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

$openMwArguments = [Collections.Generic.List[string]]::new()
$openMwArguments.Add("--replace")
$openMwArguments.Add("config")
$openMwArguments.Add("--config")
$openMwArguments.Add($bridgeConfig)
$openMwArguments.Add("--resources")
$openMwArguments.Add($parityResources)
$openMwArguments.Add("--user-data")
$openMwArguments.Add($bridgeConfig)
$openMwArguments.Add("--skip-menu")
if ([string]::IsNullOrWhiteSpace($LoadSavegame)) {
    $openMwArguments.Add("--start")
    $openMwArguments.Add("Goodsprings")
} else {
    $savePath = Get-NormalizedPath $LoadSavegame
    if (-not (Test-Path -LiteralPath $savePath -PathType Leaf)) {
        throw "Requested FNV VR save does not exist: $savePath"
    }
    $openMwArguments.Add("--load-savegame")
    $openMwArguments.Add($savePath)
}

Write-Host "FNV VR runtime: staged executable with an isolated FNV profile"
Write-Host "Exe:     $parityExe"
Write-Host "Config:  $bridgeConfig"
Write-Host "Start:   $(if ([string]::IsNullOrWhiteSpace($LoadSavegame)) { 'fresh authored Goodsprings' } else { $LoadSavegame })"
Write-Host "Safety:  no generic main menu, no proof save, no startup script"
if ($DiagnosticCandidate) {
    Write-Warning "Diagnostic candidate only: this runtime is not eligible for player testing."
}

$launch = $null
$savedEnvironment = @{}
$vrRigDefaults = [ordered]@{
    OPENMW_FNV_PIPBOY_ROT_X = "0"
    OPENMW_FNV_PIPBOY_ROT_Y = "0"
    OPENMW_FNV_PIPBOY_ROT_Z = "90"
    OPENMW_FNV_PIPBOY_OFFSET_X = "-3"
    OPENMW_FNV_PIPBOY_OFFSET_Y = "-13"
    OPENMW_FNV_PIPBOY_OFFSET_Z = "-6.5"
    OPENMW_FNV_PIPBOY_SOCKET_MODEL_X = "17.0616"
    OPENMW_FNV_RIGHT_PIPBOY_CALIBRATION = "0"
    OPENMW_FNV_HAND_ROT_X = "90"
    OPENMW_FNV_HAND_ROT_Y = "0"
    OPENMW_FNV_HAND_ROT_Z = "0"
    OPENMW_FNV_HAND_OFFSET_X = "0"
    OPENMW_FNV_HAND_OFFSET_Y = "0"
    OPENMW_FNV_HAND_OFFSET_Z = "0"
    OPENMW_FNV_LEFT_HAND_ROT_Y = "-90"
    OPENMW_FNV_RIGHT_HAND_ROT_Y = "90"
    OPENMW_FNV_LEFT_HAND_ROT_Z = "-25"
    OPENMW_FNV_RIGHT_HAND_ROT_Z = "25"
    OPENMW_FNV_LEFT_HAND_SOCKET_X = "1.5"
    OPENMW_FNV_LEFT_HAND_SOCKET_Y = "-2"
    OPENMW_FNV_LEFT_HAND_SOCKET_Z = "-2"
    OPENMW_FNV_RIGHT_HAND_SOCKET_X = "1.5"
    OPENMW_FNV_RIGHT_HAND_SOCKET_Y = "-2"
    OPENMW_FNV_RIGHT_HAND_SOCKET_Z = "-2"
    OPENMW_FNV_LEFT_HAND_SOLVE_ROLL = "-5"
    OPENMW_FNV_RIGHT_HAND_SOLVE_ROLL = "-5"
    OPENMW_FNV_VR_HAND_SKINNING_MODE = "invBindThenSkeleton"
    OPENMW_FNV_VR_FINGER_CURL_ENABLE = "1"
    OPENMW_FNV_VR_INDEX_CURL_DEGREES = "55"
    OPENMW_FNV_VR_GRIP_CURL_DEGREES = "68"
    OPENMW_FNV_VR_THUMB_CURL_DEGREES = "42"
    OPENMW_FNV_VR_FINGER_CHAIN_POSE = "1"
    OPENMW_FNV_VR_GRIP_FALLBACK_TO_TRIGGER = "1"
}
foreach ($name in @(
    "OPENMW_STARTUP_SCRIPT",
    "OPENMW_BACKGROUND_LAUNCH",
    "OPENMW_DEBUG_LEVEL",
    "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY",
    "OPENMW_FNVXR_RETAIL_SURFACE",
    "OPENMW_FNV_VR_DEBUG_SNAPSHOT_AUTO_FRAMES",
    "OPENMW_FNV_VR_STATICIZED_HANDS",
    "OPENMW_FNV_VR_CONTROLLER_DEBUG_AXES",
    "OPENMW_FNV_VR_HAND_TRACKING_LOG",
    "XR_RUNTIME_JSON",
    "OPENXR_SIMULATOR_DATA_DIR",
    "OPENXR_SIMULATOR_LOG_PATH",
    "OPENXR_SIMULATOR_HEADLESS",
    "OPENXR_SIMULATOR_DESKTOP_PREVIEW"
)) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}
# A previous developer launcher can leave FNV/VR tuning in the parent shell.
# Do not let an opaque inherited override change this reproducible profile.
$inheritedFnvOverrides = @(Get-ChildItem Env: | Where-Object {
    $_.Name -like "OPENMW_FNV_*" -or $_.Name -like "OPENMW_FNVXR_*"
})
foreach ($entry in $inheritedFnvOverrides) {
    if (-not $savedEnvironment.ContainsKey($entry.Name)) {
        $savedEnvironment[$entry.Name] = [string]$entry.Value
    }
    [Environment]::SetEnvironmentVariable($entry.Name, $null, "Process")
}
foreach ($name in $vrRigDefaults.Keys) {
    if (-not $savedEnvironment.ContainsKey($name)) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
}

Push-Location $BridgeRoot
try {
    $env:OPENMW_STARTUP_SCRIPT = $disabledStartupScript
    $env:OPENMW_BACKGROUND_LAUNCH = "0"
    $env:OPENMW_DEBUG_LEVEL = $LogLevel
    $env:OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = "0"
    $env:OPENMW_FNVXR_RETAIL_SURFACE = "0"
    $env:OPENMW_FNV_VR_DEBUG_SNAPSHOT_AUTO_FRAMES = $AutoCaptureFrames.ToString([Globalization.CultureInfo]::InvariantCulture)
    $env:OPENMW_FNV_VR_STATICIZED_HANDS = if ($StaticizedHandDiagnostics) { "1" } else { "0" }
    $env:OPENMW_FNV_VR_CONTROLLER_DEBUG_AXES = if ($ControllerPoseDiagnostics) { "1" } else { "0" }
    $env:OPENMW_FNV_VR_HAND_TRACKING_LOG = if ($ControllerPoseDiagnostics) { "1" } else { "0" }
    foreach ($entry in $vrRigDefaults.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
    if ($InteractionProofLoadout) {
        # Populate the normal player InventoryStore with named FalloutNV.esm
        # records, without enabling the flat showcase scheduler or fake items.
        $env:OPENMW_FNV_PIPBOY_SHOWCASE_LOADOUT = "1"
    }
    if (-not [string]::IsNullOrWhiteSpace($PipBoyRttCapturePath)) {
        $resolvedRttCapturePath = [IO.Path]::GetFullPath($PipBoyRttCapturePath)
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($resolvedRttCapturePath)) -Force | Out-Null
        $env:OPENMW_FNV_PIPBOY_RTT_CAPTURE_PATH = $resolvedRttCapturePath
    }
    $env:OPENMW_BACKGROUND_LAUNCH = if ($Background) { "1" } else { "0" }
    if ($UseRepoOpenXRSimulator) {
        New-Item -ItemType Directory -Path $SimulatorDataDirectory -Force | Out-Null
        $env:XR_RUNTIME_JSON = $repoSimulatorManifest
        $env:OPENXR_SIMULATOR_DATA_DIR = $SimulatorDataDirectory
        $env:OPENXR_SIMULATOR_LOG_PATH = Join-Path $SimulatorDataDirectory "runtime.log"
        $env:OPENXR_SIMULATOR_HEADLESS = "1"
        $env:OPENXR_SIMULATOR_DESKTOP_PREVIEW = "1"
        Write-Host "OpenXR: repo-local simulator (per-process; Windows active runtime unchanged)"
        Write-Host "Simulator data: $SimulatorDataDirectory"
    }
    if ($StaticizedHandDiagnostics) {
        Write-Warning "Hand mesh normalization diagnostic enabled for this isolated simulator launch."
    }
    if ($ControllerPoseDiagnostics) {
        Write-Warning "Controller transform diagnostic enabled for this isolated simulator launch."
    }
    if ($DryRun) {
        Write-Host "Command: $parityExe $($openMwArguments -join ' ')"
        $launcherExitCode = 0
    } else {
        $launch = Start-Process -FilePath $parityExe `
            -ArgumentList @($openMwArguments.ToArray()) `
            -WorkingDirectory $BinaryRoot `
            -PassThru
        $launcherExitCode = 0
        Write-Host "Launching OpenMW VR directly (no legacy batch environment): PID $($launch.Id)."
    }
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

$logPath = Join-Path $bridgeConfig "openmw.log"
$readyDeadline = (Get-Date).AddSeconds(45)
$rigReady = $false
do {
    $live = Get-Process -Id $launch.Id -ErrorAction SilentlyContinue
    if ($null -eq $live) {
        throw "FNV parity VR exited before its tracked rig became ready. See $logPath"
    }
    if ((Test-Path -LiteralPath $logPath -PathType Leaf) -and
        (Select-String -LiteralPath $logPath -Pattern 'OpenMW VR player rig status=ready' -Quiet)) {
        $rigReady = $true
        break
    }
    Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt $readyDeadline)
if (-not $rigReady) {
    throw "FNV parity VR started but did not report its tracked hand/Pip-Boy rig ready within 45 seconds. See $logPath"
}
Write-Host "FNV parity VR tracked rig is ready as PID $($launch.Id)."
if ($Wait) {
    $process = Get-Process -Id $launch.Id
    $process.WaitForExit()
    exit $process.ExitCode
}

# The batch helper can return a non-zero monitor status even after the real VR
# process is confirmed alive. Do not leak that stale native exit code to callers.
exit 0
