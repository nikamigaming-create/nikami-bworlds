param(
    [string]$WorldId = "fallout_new_vegas",
    [ValidateSet("flat", "vr")]
    [string]$Mode = "flat",
    [switch]$DryRun,
    [switch]$Wait,
    [switch]$AllowDuplicate,
    [switch]$SkipMenu,
    [switch]$NewGame,
    [string]$LoadSavegame = "",
    [string]$StartCell = "",
    [string[]]$ExtraArgs = @(),
    [string]$SeedPath = "catalog/world-walker.seed.json",
    [string]$BinaryRoot = "",
    [string]$ProfileDirectory = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

if ($Mode -eq "vr" -and $WorldId -eq "fallout_new_vegas") {
    $fnvVrLauncher = Join-Path $PSScriptRoot "Start-FNVParityVRExisting.ps1"
    if (-not (Test-Path -LiteralPath $fnvVrLauncher -PathType Leaf)) {
        throw "Missing calibrated FNV VR launcher: $fnvVrLauncher"
    }

    $fnvVrParameters = @{}
    if ($DryRun) {
        $fnvVrParameters.DryRun = $true
    }
    if ($Wait) {
        $fnvVrParameters.Wait = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($LoadSavegame)) {
        $fnvVrParameters.LoadSavegame = $LoadSavegame
    }
    if (-not [string]::IsNullOrWhiteSpace($BinaryRoot)) {
        $fnvVrParameters.BinaryRoot = $BinaryRoot
    }

    & $fnvVrLauncher @fnvVrParameters
    return
}

function Quote-CommandArg([string]$Arg) {
    if ($Arg -match '[\s"]') {
        return '"' + ($Arg -replace '"', '\"') + '"'
    }
    return $Arg
}

if (-not (Test-Path -LiteralPath $SeedPath)) {
    throw "Missing world walker seed: $SeedPath. Run scripts/New-WorldWalkerSeed.ps1 first."
}

$seed = Get-Content -LiteralPath $SeedPath -Raw | ConvertFrom-Json
$world = @($seed.worlds | Where-Object { $_.id -eq $WorldId } | Select-Object -First 1)

if (-not $world) {
    $known = @($seed.worlds | ForEach-Object { $_.id }) -join ", "
    throw "Unknown world id '$WorldId'. Known ids: $known"
}

if ($world.readyForWorldWalker -ne $true) {
    throw "World '$WorldId' is not ready for the world walker. installStatus=$($world.installStatus) profileStatus=$($world.profileStatus)"
}

$BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot -RequireCurrent
$ResourcesRoot = Resolve-NikamiOpenMWResourcesRoot -RequireCurrent

$profileDirectory = if ([string]::IsNullOrWhiteSpace($ProfileDirectory)) {
    [string]$world.profileDirectory
}
else {
    [IO.Path]::GetFullPath($ProfileDirectory)
}
$profilesRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\profiles"))
$profilesPrefix = $profilesRoot.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $profileDirectory.StartsWith($profilesPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Profile directory must remain under $profilesRoot. Requested: $profileDirectory"
}
if (-not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
    throw "Missing profile directory for '$WorldId': $profileDirectory"
}

$binaryName = if ($Mode -eq "flat") { "openmw.exe" } else { "openmw_vr.exe" }
$binary = Join-Path $BinaryRoot $binaryName
if (-not (Test-Path -LiteralPath $binary)) {
    throw "Missing existing OpenMW binary: $binary"
}

$argsList = New-Object System.Collections.Generic.List[string]
$argsList.Add("--replace")
$argsList.Add("config")
$argsList.Add("--config")
$argsList.Add($profileDirectory)
$argsList.Add("--resources")
$argsList.Add($ResourcesRoot)

if ($SkipMenu) {
    $argsList.Add("--skip-menu")
}
if ($NewGame) {
    $argsList.Add("--new-game")
}
if (-not [string]::IsNullOrWhiteSpace($LoadSavegame)) {
    $savePath = [IO.Path]::GetFullPath($LoadSavegame)
    if (-not (Test-Path -LiteralPath $savePath -PathType Leaf)) {
        throw "Requested save does not exist: $savePath"
    }
    $argsList.Add("--load-savegame")
    $argsList.Add($savePath)
}
if (-not [string]::IsNullOrWhiteSpace($StartCell)) {
    $argsList.Add("--start")
    $argsList.Add($StartCell)
}
foreach ($arg in $ExtraArgs) {
    if (-not [string]::IsNullOrWhiteSpace($arg)) {
        $argsList.Add($arg)
    }
}

$workingDirectory = Split-Path -Parent $binary
$argumentLine = ($argsList.ToArray() | ForEach-Object { Quote-CommandArg $_ }) -join " "
$commandLine = "$(Quote-CommandArg $binary) $argumentLine"

Write-Host "World:   $($world.displayName) [$WorldId]"
Write-Host "Mode:    $Mode"
Write-Host "Exe:     $binary"
Write-Host "Resources: $ResourcesRoot"
Write-Host "Profile: $profileDirectory"
$profileConfig = Join-Path $profileDirectory "openmw.cfg"
if (Test-Path -LiteralPath $profileConfig -PathType Leaf) {
    $contentFiles = @(Get-NikamiOpenMWConfigValues -ConfigPath $profileConfig -Key "content")
    if ($contentFiles.Count -gt 0) {
        Write-Host "Content: $($contentFiles -join ' -> ')"
    }
}
Write-Host "Command: $commandLine"
Write-Host "Runtime: real OpenMW profile launch; proof/viewer environment is cleared before start."

if ($DryRun) {
    Write-Host "Dry run only; not starting OpenMW."
    exit 0
}

$processName = [System.IO.Path]::GetFileNameWithoutExtension($binary)
if (-not $AllowDuplicate -and (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
    throw "$processName is already running. Close it first or pass -AllowDuplicate."
}

Clear-NikamiWorldViewerRuntimeEnvironment
$previousDebugLevel = $env:OPENMW_DEBUG_LEVEL
try {
    $env:OPENMW_DEBUG_LEVEL = "INFO"
    $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory $workingDirectory -PassThru
}
finally {
    $env:OPENMW_DEBUG_LEVEL = $previousDebugLevel
}
Write-Host "Started PID $($process.Id)."

if ($Wait) {
    $process.WaitForExit()
    Write-Host "$processName exited with code $($process.ExitCode)."
    exit $process.ExitCode
}
