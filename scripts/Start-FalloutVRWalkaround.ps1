param(
    [ValidateSet("fallout3", "fallout_new_vegas")]
    [string]$WorldId = "fallout3",
    [switch]$DryRun,
    [switch]$Wait,
    [switch]$Diagnostics,
    [switch]$AllowDuplicate,
    [string]$BinaryRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

function Quote-CommandArg([string]$Arg) {
    if ($Arg -match '[\s"]') { return '"' + ($Arg -replace '"', '\"') + '"' }
    return $Arg
}

function Get-ProfileValue([string]$ConfigPath, [string]$Key) {
    foreach ($line in Get-Content -LiteralPath $ConfigPath) {
        if ($line -match ('^\s*' + [Regex]::Escape($Key) + '\s*=\s*(.+?)\s*$')) {
            return $Matches[1].Trim('"')
        }
    }
    return $null
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$seedPath = Join-Path $repoRoot "catalog/world-walker.seed.json"
$startsPath = Join-Path $repoRoot "catalog/flat-world-proof-starts.json"
$seed = Get-Content -LiteralPath $seedPath -Raw | ConvertFrom-Json
$world = @($seed.worlds | Where-Object { $_.id -eq $WorldId } | Select-Object -First 1)
if (-not $world -or $world.readyForWorldWalker -ne $true) {
    throw "World '$WorldId' is not ready for a walkaround."
}

$starts = Get-Content -LiteralPath $startsPath -Raw | ConvertFrom-Json
$worldStart = $starts.worlds.$WorldId
if ($null -eq $worldStart) { throw "No start contract exists for '$WorldId'." }
$sliceName = if ($WorldId -eq "fallout3") {
    "megaton-entrance-lucas-actor-walkaround"
} else {
    "goodsprings-settler-actor-walkaround"
}
$slice = $worldStart.slices.$sliceName
if ($null -eq $slice) { throw "Missing walkaround slice '$sliceName'." }
$anchor = $slice.anchor

$runtimeRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$resourcesRoot = Resolve-NikamiOpenMWResourcesRoot
$binary = Join-Path $runtimeRoot "openmw_vr.exe"
$profile = [IO.Path]::GetFullPath([string]$world.profileDirectory)
$playableBaseline = Join-Path $repoRoot "config/playable-baseline"
$doorPreload = Join-Path $repoRoot "config/door-preload"
$resourcesVersion = Join-Path $resourcesRoot "version"
foreach ($required in @($binary, $resourcesRoot, $resourcesVersion, $profile, $playableBaseline, $doorPreload)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing VR walkaround dependency: $required" }
}

$sessionStamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss-fff", [Globalization.CultureInfo]::InvariantCulture)
$sessionRoot = Join-Path $repoRoot ("run/interactive-fallout-vr/{0}/{1}-{2}" -f $WorldId, $sessionStamp, $PID)
$sessionConfig = Join-Path $sessionRoot "config"
$sessionUserData = Join-Path $sessionRoot "user-data"

$morrowindConfig = Join-Path $repoRoot "profiles/morrowind/openmw.cfg"
$morrowindData = Get-ProfileValue $morrowindConfig "data"
if ([string]::IsNullOrWhiteSpace($morrowindData) -or -not (Test-Path -LiteralPath $morrowindData)) {
    throw "Unable to resolve the shared OpenMW UI data from $morrowindConfig"
}
$morrowindData = [IO.Path]::GetFullPath($morrowindData)

$openXrRuntime = $null
foreach ($registryPath in @(
    "HKLM:\SOFTWARE\Khronos\OpenXR\1",
    "HKCU:\SOFTWARE\Khronos\OpenXR\1"
)) {
    if (Test-Path -LiteralPath $registryPath) {
        $candidate = (Get-ItemProperty -LiteralPath $registryPath -Name ActiveRuntime -ErrorAction SilentlyContinue).ActiveRuntime
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $openXrRuntime = [string]$candidate; break }
    }
}
if ([string]::IsNullOrWhiteSpace($openXrRuntime)) {
    throw "No active OpenXR runtime is registered. Start SteamVR, Meta Link, or your headset runtime first."
}

$environment = [ordered]@{
    OPENMW_WORLD_VIEWER_START_POS_X = [string]$anchor.position.x
    OPENMW_WORLD_VIEWER_START_POS_Y = [string]$anchor.position.y
    OPENMW_WORLD_VIEWER_START_POS_Z = [string]$anchor.position.z
    OPENMW_WORLD_VIEWER_START_ROT_X = [string]$anchor.rotation.x
    OPENMW_WORLD_VIEWER_START_ROT_Y = [string]$anchor.rotation.y
    OPENMW_WORLD_VIEWER_START_ROT_Z = [string]$anchor.rotation.z
    OPENMW_WORLD_VIEWER_START_CAMERA_MODE = "firstperson"
    OPENMW_WORLD_VIEWER_START_CAMERA_DISTANCE = "0"
    OPENMW_WORLD_VIEWER_START_CAMERA_PITCH = [string]$anchor.camera.pitch
    OPENMW_WORLD_VIEWER_START_CAMERA_YAW = [string]$anchor.camera.yaw
    OPENMW_WORLD_VIEWER_START_CAMERA_NUDGE_DISTANCE = "0"
    OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = if ($Diagnostics) { "1" } else { "0" }
    OPENMW_WORLD_VIEWER_TELEMETRY = if ($Diagnostics) { "1" } else { "0" }
    OPENMW_DEBUG_LEVEL = if ($Diagnostics) { "VERBOSE" } else { "INFO" }
    OPENMW_PLAYABLE_SESSION_BACKGROUND = "0"
    OPENMW_PLAYABLE_START_HOUR = if ($WorldId -eq "fallout3") { "12" } else { "14.45" }
    OPENMW_FNV_BOOTSTRAP_HOUR = if ($WorldId -eq "fallout3") { "12" } else { "14.45" }
    OPENMW_ESM4_PLAYER_NPC = "Player"
    OPENMW_ESM4_PLAYER_OUTFIT = if ($WorldId -eq "fallout3") { "VaultSuit101" } else { "VaultSuit21" }
    OPENMW_FNV_VR_THUMBSTICK_MOVE_SCALE = "2.75"
    OPENMW_FNV_VR_THUMBSTICK_WALK_SCALE = "1.15"
    OPENMW_FNV_VR_THUMBSTICK_JOG_SCALE = "1.75"
    OPENMW_FNV_VR_THUMBSTICK_RUN_SCALE = "2.75"
    OPENMW_FNV_VR_MOVE_ACCEL = "10.0"
    OPENMW_FNV_VR_MOVE_DECEL = "14.0"
}

$arguments = @(
    "--replace", "config",
    "--config", $profile,
    "--config", $playableBaseline,
    "--config", $doorPreload,
    "--config", $sessionConfig,
    "--user-data", $sessionUserData,
    "--resources", $resourcesRoot,
    "--data", $morrowindData,
    "--fallback-archive", "Morrowind.bsa",
    "--skip-menu",
    "--start", [string]$worldStart.startCell
)
$argumentLine = ($arguments | ForEach-Object { Quote-CommandArg ([string]$_) }) -join " "

Write-Host "Interactive Fallout VR session"
Write-Host "World:   $($world.displayName) [$WorldId]"
Write-Host "Spawn:   $($worldStart.startCell) at ($($anchor.position.x), $($anchor.position.y), $($anchor.position.z))"
Write-Host "Exe:     $binary"
Write-Host "Profile: $profile"
Write-Host "OpenXR:  $openXrRuntime"
Write-Host "Session: $sessionRoot"
Write-Host "Command: $(Quote-CommandArg $binary) $argumentLine"
Write-Host "Diagnostics: $(if ($Diagnostics) { 'on' } else { 'off' })"

if ($DryRun) {
    Write-Host "Dry run only; not starting OpenMW VR."
    exit 0
}

if (-not $AllowDuplicate -and (Get-Process -Name openmw,openmw_vr -ErrorAction SilentlyContinue)) {
    throw "OpenMW is already running. Close it first or pass -AllowDuplicate."
}

# The profile, baseline, and door-preload directories are immutable inputs. Put every writable OpenMW artifact in a
# unique run directory so a headset session cannot poison the next run or dirty a shared repository config.
New-Item -ItemType Directory -Path $sessionConfig, $sessionUserData -Force | Out-Null
Set-Content -LiteralPath (Join-Path $sessionConfig "openmw.cfg") `
    -Value ('user-data="{0}"' -f ($sessionUserData -replace '\\', '/')) -Encoding utf8
$resourceVersionLines = @(Get-Content -LiteralPath $resourcesVersion)
$sessionManifest = [ordered]@{
    schema = "nikami-fallout-vr-session/v1"
    worldId = $WorldId
    world = [string]$world.displayName
    startCell = [string]$worldStart.startCell
    createdAtUtc = [DateTime]::UtcNow.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    executable = $binary -replace "\\", "/"
    executableSha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    resources = $resourcesRoot -replace "\\", "/"
    resourcesVersion = $resourceVersionLines
    openXrRuntime = $openXrRuntime -replace "\\", "/"
    diagnostics = [bool]$Diagnostics
    configDirectory = $sessionConfig -replace "\\", "/"
    userDataDirectory = $sessionUserData -replace "\\", "/"
    command = @($binary) + $arguments
}
$sessionManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $sessionRoot "session.json") -Encoding utf8

# A playable session must not inherit any proof-only actor selection, pose,
# AI suppression, or authored-audit mutation from a previous harness run.
$runtimePrefixes = @(
    "OPENMW_WORLD_VIEWER_",
    "OPENMW_PROOF_",
    "OPENMW_FNV_",
    "OPENMW_ESM4_",
    "OPENMW_PLAYABLE_",
    "OPENMW_AUTHORED_"
)
foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
    if ($runtimePrefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) {
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
}
Clear-NikamiWorldViewerRuntimeEnvironment
foreach ($entry in $environment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
}

$process = Start-Process -FilePath $binary -ArgumentList $argumentLine `
    -WorkingDirectory $runtimeRoot -PassThru
Write-Host "Started OpenMW VR PID $($process.Id). The session remains open until you exit the game."

if ($Wait) {
    $process.WaitForExit()
    Write-Host "openmw_vr exited with code $($process.ExitCode)."
    exit $process.ExitCode
}
