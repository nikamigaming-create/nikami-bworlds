param(
    [string]$TtwRoot = "",
    [string]$Fallout3Data = "",
    [string]$FalloutNewVegasData = "",
    [string]$JamRoot = "",
    [Alias("WithJam")]
    [switch]$IncludeJam,
    [string]$ProfileDirectory = "",
    [string]$BinaryRoot = "",
    [switch]$DryRun,
    [switch]$Wait,
    [switch]$AllowDuplicate,
    [switch]$SkipMenu,
    [switch]$NewGame,
    [ValidateSet("ERROR", "WARNING", "INFO", "VERBOSE", "DEBUG")]
    [string]$OpenMWLogLevel = "WARNING",
    [string]$LoadSavegame = "",
    [string]$StartCell = "",
    [string[]]$ExtraArgs = @(),
    [switch]$AllowPartialInstall,
    [switch]$ForceProfileConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

function Quote-CommandArg {
    param([Parameter(Mandatory=$true)][string]$Arg)

    if ($Arg -match '[\s"]') {
        return '"' + ($Arg -replace '"', '\"') + '"'
    }
    return $Arg
}

if ($AllowPartialInstall -and -not $DryRun) {
    throw "A partial TTW install may only be inspected with -DryRun. The launcher will not start an incomplete TTW asset set."
}

if ([string]::IsNullOrWhiteSpace($BinaryRoot)) {
    # TTW uses its own packaged parser-compatibility runtime. Do not change the
    # global OpenMW runtime default used by the other world profiles.
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $BinaryRoot = Join-Path $repoRoot "local/openmw-ttw-compat"
}
$BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$ResourcesRoot = Resolve-NikamiOpenMWResourcesRoot -ParameterValue (Join-Path $BinaryRoot "resources")

$initializer = Join-Path $PSScriptRoot "Initialize-TTWCompatibilityProfile.ps1"
if (-not (Test-Path -LiteralPath $initializer -PathType Leaf)) {
    throw "Missing TTW compatibility initializer: $initializer"
}
$initializerArguments = @{
    TtwRoot = $TtwRoot
    Fallout3Data = $Fallout3Data
    FalloutNewVegasData = $FalloutNewVegasData
    JamRoot = $JamRoot
    IncludeJam = $IncludeJam
    ProfileDirectory = $ProfileDirectory
    BinaryRoot = $BinaryRoot
}
if ($DryRun) { $initializerArguments.DryRun = $true }
if ($AllowPartialInstall) { $initializerArguments.AllowPartialInstall = $true }
if ($ForceProfileConfig) { $initializerArguments.Force = $true }
$profile = & $initializer @initializerArguments

if (-not $profile.launchable -and -not $DryRun) {
    throw "TTW source is incomplete: $($profile.installReasons -join '; ')"
}

$binary = Join-Path $BinaryRoot "openmw.exe"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "Missing OpenMW executable: $binary"
}

$argsList = [Collections.Generic.List[string]]::new()
$argsList.Add("--replace")
$argsList.Add("config")
$argsList.Add("--config")
$argsList.Add([string]$profile.profileDirectory)
$argsList.Add("--resources")
$argsList.Add($ResourcesRoot)
if ($SkipMenu) { $argsList.Add("--skip-menu") }
if ($NewGame) { $argsList.Add("--new-game") }
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

$argumentLine = ($argsList.ToArray() | ForEach-Object { Quote-CommandArg $_ }) -join " "
$commandLine = "$(Quote-CommandArg $binary) $argumentLine"
Write-Host "World:     Tale of Two Wastelands [FNV compatibility layer]"
Write-Host "Runtime:   $BinaryRoot"
Write-Host "Resources: $ResourcesRoot"
Write-Host "Profile:   $($profile.profileDirectory)"
Write-Host "Content:   $($profile.content -join ' -> ')"
Write-Host "Mode:      $($profile.launchMode)"
Write-Host "JAM:       $(if ($profile.jamEnabled) { 'enabled' } else { 'disabled' })"
if ($profile.jamEnabled) {
    Write-Host "JAM rule:  keep saves made with JAM in the JAM launch profile."
}
else {
    Write-Host "JAM rule:  it can be added later with -IncludeJam; both variants share the TTW campaign save store."
}
Write-Host "Command:   $commandLine"
Write-Host "Safety:    source contents and directory entries stay untouched; campaign saves and profile-local data stay under profiles/."
if (-not $profile.installComplete) {
    Write-Warning "Launching the tested source-archive compatibility mode, not a full official TTW installer output."
}

if ($DryRun) {
    Write-Host "Dry run only; not starting OpenMW."
    exit 0
}

$processName = [IO.Path]::GetFileNameWithoutExtension($binary)
if (-not $AllowDuplicate -and (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
    throw "$processName is already running. Close it first or pass -AllowDuplicate."
}

Clear-NikamiWorldViewerRuntimeEnvironment
$previousDebugLevel = [Environment]::GetEnvironmentVariable("OPENMW_DEBUG_LEVEL", "Process")
try {
    [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", $OpenMWLogLevel, "Process")
    $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $binary) -PassThru
}
finally {
    [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", $previousDebugLevel, "Process")
}

Write-Host "Started PID $($process.Id)."
if ($Wait) {
    $process.WaitForExit()
    Write-Host "$processName exited with code $($process.ExitCode)."
    exit $process.ExitCode
}
