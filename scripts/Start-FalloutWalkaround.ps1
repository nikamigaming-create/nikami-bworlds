param(
    [ValidateSet("fallout_new_vegas", "fallout3")]
    [string]$WorldId = "fallout_new_vegas",
    [switch]$DryRun,
    [switch]$Wait,
    [switch]$Diagnostics,
    [switch]$AllowDuplicate,
    [string]$StartSlice = "",
    [string]$BinaryRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

function Quote-CommandArg([string]$Arg) {
    if ($Arg -match '[\s"]') {
        return '"' + ($Arg -replace '"', '\"') + '"'
    }
    return $Arg
}

function Get-RequiredProperty($Object, [string]$Name, [string]$Context) {
    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
        throw "Missing $Context.$Name"
    }
    return $Object.$Name
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$seedPath = Join-Path $repoRoot "catalog/world-walker.seed.json"
$startsPath = Join-Path $repoRoot "catalog/flat-world-proof-starts.json"

if (-not (Test-Path -LiteralPath $seedPath)) {
    throw "Missing world walker seed: $seedPath. Run scripts/New-WorldWalkerSeed.ps1 first."
}
if (-not (Test-Path -LiteralPath $startsPath)) {
    throw "Missing walkaround catalog: $startsPath"
}

$seed = Get-Content -LiteralPath $seedPath -Raw | ConvertFrom-Json
$world = @($seed.worlds | Where-Object { $_.id -eq $WorldId } | Select-Object -First 1)
if (-not $world -or $world.readyForWorldWalker -ne $true) {
    throw "World '$WorldId' is not ready for an interactive walkaround."
}

$starts = Get-Content -LiteralPath $startsPath -Raw | ConvertFrom-Json
$worldStart = Get-RequiredProperty $starts.worlds $WorldId "worlds"
$sliceName = if (-not [string]::IsNullOrWhiteSpace($StartSlice)) {
    $StartSlice
} elseif ($WorldId -eq "fallout_new_vegas") {
    "goodsprings-settler-actor-walkaround"
} else {
    "megaton-entrance-lucas-actor-walkaround"
}
$slice = Get-RequiredProperty $worldStart.slices $sliceName "$WorldId.slices"
$anchor = Get-RequiredProperty $slice "anchor" $sliceName
$position = Get-RequiredProperty $anchor "position" "$sliceName.anchor"
$rotation = Get-RequiredProperty $anchor "rotation" "$sliceName.anchor"
$camera = Get-RequiredProperty $anchor "camera" "$sliceName.anchor"
$startCell = if ($slice.PSObject.Properties.Name -contains "startCell") {
    [string](Get-RequiredProperty $slice "startCell" $sliceName)
} else {
    [string](Get-RequiredProperty $worldStart "startCell" $WorldId)
}

$runtimeRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$resourcesRoot = Resolve-NikamiOpenMWResourcesRoot
$binary = Join-Path $runtimeRoot "openmw.exe"
if (-not (Test-Path -LiteralPath $binary)) {
    throw "Missing OpenMW binary: $binary"
}

$environment = [ordered]@{
    OPENMW_WORLD_VIEWER_START_POS_X = [string]$position.x
    OPENMW_WORLD_VIEWER_START_POS_Y = [string]$position.y
    OPENMW_WORLD_VIEWER_START_POS_Z = [string]$position.z
    OPENMW_WORLD_VIEWER_START_ROT_X = [string]$rotation.x
    OPENMW_WORLD_VIEWER_START_ROT_Y = [string]$rotation.y
    OPENMW_WORLD_VIEWER_START_ROT_Z = [string]$rotation.z
    OPENMW_WORLD_VIEWER_START_CAMERA_MODE = [string]$camera.mode
    OPENMW_WORLD_VIEWER_START_CAMERA_DISTANCE = [string]$camera.distance
    OPENMW_WORLD_VIEWER_START_CAMERA_PITCH = [string]$camera.pitch
    OPENMW_WORLD_VIEWER_START_CAMERA_YAW = [string]$camera.yaw
    OPENMW_WORLD_VIEWER_START_CAMERA_NUDGE_DISTANCE = "0"
}

if ($worldStart.PSObject.Properties.Name -contains "environment") {
    foreach ($property in $worldStart.environment.PSObject.Properties) {
        $environment[[string]$property.Name] = [string]$property.Value
    }
}

# Keep the walkaround on the authored region-weather path. A deterministic hour
# is useful for a repeatable spawn, but forcing WTHR or image space here would
# stop this from representing ordinary gameplay and can thrash the weather state.
if ($WorldId -eq "fallout_new_vegas") {
    $environment["OPENMW_FNV_BOOTSTRAP_HOUR"] = "14.45"
    $environment.Remove("OPENMW_FNV_PROOF_WEATHER_ID")
    $environment.Remove("OPENMW_FNV_PROOF_IMAGE_SPACE_ID")
}

# Proof slices enable high-volume actor telemetry in the shared catalog. Keep
# normal interactive play clean and make diagnostics an explicit opt-in.
$environment["OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY"] = if ($Diagnostics) { "1" } else { "0" }

$argsList = @(
    "--replace", "config",
    "--config", [string]$world.profileDirectory,
    "--resources", $resourcesRoot,
    "--skip-menu",
    "--start", $startCell
)
$argumentLine = ($argsList | ForEach-Object { Quote-CommandArg $_ }) -join " "
$boundedInputEvidence = $null
if ($WorldId -eq "fallout_new_vegas") {
    $profileDirectory = (Resolve-Path -LiteralPath ([string]$world.profileDirectory)).Path
    $profileConfig = Join-Path $profileDirectory "openmw.cfg"
    $configurationPaths = @(Get-NikamiOpenMWConfigurationInputPaths -ConfigDirectory @($profileDirectory) `
        -AdditionalFile @($seedPath, $startsPath))
    $dataRoots = @(Get-NikamiOpenMWDataRootsFromConfig -ConfigPath $profileConfig)
    $boundedInputEvidence = New-NikamiOpenMWBoundedInputEvidence -Executable $binary -ResourcesRoot $resourcesRoot `
        -ConfigurationPath $configurationPaths -DataConfigPath $profileConfig -DataRoot $dataRoots
    [void](Assert-NikamiOpenMWBoundedInputEvidence -Evidence $boundedInputEvidence -Executable $binary `
        -ResourcesRoot $resourcesRoot -ConfigurationPath $configurationPaths `
        -DataConfigPath $profileConfig -DataRoot $dataRoots)
}

Write-Host "Interactive Fallout world session"
Write-Host "World:   $($world.displayName) [$WorldId]"
Write-Host "Slice:   $sliceName"
Write-Host "Spawn:   $startCell at ($($position.x), $($position.y), $($position.z)); neighboring cells stream normally"
Write-Host "Camera:  $($camera.mode); live keyboard and mouse input"
Write-Host "Weather: natural authored region weather (no forced WTHR or image space)"
Write-Host "Exe:     $binary"
Write-Host "Profile: $($world.profileDirectory)"
Write-Host "Command: $(Quote-CommandArg $binary) $argumentLine"
Write-Host "Environment:"
foreach ($entry in $environment.GetEnumerator()) {
    Write-Host "  $($entry.Key)=$($entry.Value)"
}
if ($null -ne $boundedInputEvidence) {
    foreach ($line in @(Get-NikamiOpenMWBoundedInputEvidenceLogLines -Evidence $boundedInputEvidence)) { Write-Host $line }
}

if ($DryRun) {
    if ($null -ne $boundedInputEvidence) { Write-Host "Bounded input freshness: not-run (dry run; no launch)." }
    Write-Host "Dry run only; not starting OpenMW."
    exit 0
}

$processName = [System.IO.Path]::GetFileNameWithoutExtension($binary)
if (-not $AllowDuplicate -and (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
    throw "$processName is already running. Close it first or pass -AllowDuplicate."
}

Clear-NikamiWorldViewerRuntimeEnvironment
foreach ($entry in $environment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
}
if ($null -ne $boundedInputEvidence) {
    [void](Assert-NikamiOpenMWBoundedInputEvidence -Evidence $boundedInputEvidence -Executable $binary `
        -ResourcesRoot $resourcesRoot -ConfigurationPath $configurationPaths `
        -DataConfigPath $profileConfig -DataRoot $dataRoots -VerifyCurrent)
    Write-Host "Bounded input freshness: pass (verified immediately before launch)."
}

$process = Start-Process -FilePath $binary -ArgumentList $argumentLine `
    -WorkingDirectory (Split-Path -Parent $binary) -PassThru
Write-Host "Started PID $($process.Id). The session remains open until you exit the game."

if ($Wait) {
    $process.WaitForExit()
    Write-Host "$processName exited with code $($process.ExitCode)."
    exit $process.ExitCode
}
