param(
    [switch]$DryRun,
    [switch]$NoPause = $true,
    [switch]$EnableRetailSidecar,
    [switch]$Diagnostics,
    [switch]$AllowForeground,
    [switch]$KeepSavePosition,
    [ValidateRange(0.0, 23.9999)]
    [double]$StartHour = 14.45,
    [ValidateRange(0, 100000)]
    [int]$AutoCaptureFrames = 0,
    [string]$FnvRoot = "",
    [string[]]$RunArgs = @()
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

$FnvRoot = Resolve-NikamiPath `
    -ParameterValue $FnvRoot `
    -EnvName "NIKAMI_FNV_ROOT" `
    -ConfigName "fnvRoot" `
    -Required `
    -Description "calibrated FNV/OpenMW VR root"

$launcher = Join-Path $FnvRoot "run_vr.bat"
$exe = Join-Path $FnvRoot "openmw-source\MSVC2022_64\Release\openmw_vr.exe"
$baselineStartupScript = Join-Path (Split-Path -Parent $PSScriptRoot) "config\starts\fnv-level-one-goodsprings.txt"

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Missing FNV VR launcher: $launcher"
}

if (-not (Test-Path -LiteralPath $exe)) {
    throw "Missing existing OpenMW VR binary: $exe"
}

if (-not $KeepSavePosition -and -not (Test-Path -LiteralPath $baselineStartupScript)) {
    throw "Missing FNV playable baseline start script: $baselineStartupScript"
}

$argsList = New-Object System.Collections.Generic.List[string]
if ($DryRun) {
    $argsList.Add("dryrun")
}
if ($NoPause) {
    $argsList.Add("nopause")
}
if ($AutoCaptureFrames -gt 0) {
    $argsList.Add("debugimage")
}
foreach ($arg in $RunArgs) {
    if (-not [string]::IsNullOrWhiteSpace($arg)) {
        $argsList.Add($arg)
    }
}

Push-Location $FnvRoot
$previousRetailSurface = $env:OPENMW_FNVXR_RETAIL_SURFACE
$previousDebugLevel = $env:OPENMW_DEBUG_LEVEL
$previousActorTelemetry = $env:OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY
$previousAutoCaptureFrames = $env:OPENMW_FNV_VR_DEBUG_SNAPSHOT_AUTO_FRAMES
$previousBackgroundLaunch = $env:OPENMW_BACKGROUND_LAUNCH
$previousStartupScript = $env:OPENMW_STARTUP_SCRIPT
$previousPlayableStartHour = $env:OPENMW_PLAYABLE_START_HOUR
try {
    $env:OPENMW_FNVXR_RETAIL_SURFACE = if ($EnableRetailSidecar) { "1" } else { "0" }
    $env:OPENMW_DEBUG_LEVEL = if ($Diagnostics) { "VERBOSE" } else { "INFO" }
    $env:OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = if ($Diagnostics) { "1" } else { "0" }
    $env:OPENMW_FNV_VR_DEBUG_SNAPSHOT_AUTO_FRAMES = if ($AutoCaptureFrames -gt 0) {
        $AutoCaptureFrames.ToString([Globalization.CultureInfo]::InvariantCulture)
    } else {
        "0"
    }
    $env:OPENMW_BACKGROUND_LAUNCH = if ($AllowForeground) { "0" } else { "1" }
    $env:OPENMW_STARTUP_SCRIPT = if ($KeepSavePosition) { $null } else { $baselineStartupScript }
    $env:OPENMW_PLAYABLE_START_HOUR = $StartHour.ToString([Globalization.CultureInfo]::InvariantCulture)
    & cmd /c run_vr.bat @($argsList.ToArray())
    if ($LASTEXITCODE -ne 0) {
        throw "run_vr.bat exited with code $LASTEXITCODE"
    }
}
finally {
    $env:OPENMW_FNVXR_RETAIL_SURFACE = $previousRetailSurface
    $env:OPENMW_DEBUG_LEVEL = $previousDebugLevel
    $env:OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = $previousActorTelemetry
    $env:OPENMW_FNV_VR_DEBUG_SNAPSHOT_AUTO_FRAMES = $previousAutoCaptureFrames
    $env:OPENMW_BACKGROUND_LAUNCH = $previousBackgroundLaunch
    $env:OPENMW_STARTUP_SCRIPT = $previousStartupScript
    $env:OPENMW_PLAYABLE_START_HOUR = $previousPlayableStartHour
    Pop-Location
}
