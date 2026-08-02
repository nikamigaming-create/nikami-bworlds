[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$BinaryRoot = "",
    [string]$FalloutNewVegasData = "",
    [ValidateSet("Auto", "RequireAll")]
    [string]$DlcPolicy = "Auto",
    # TestMap01's installed FalloutNV.esm worldspace. This is a final
    # developer placement after normal new-game initialization, never --start.
    [string]$TestMapWorldspace = "FormId:0x010d703c",
    [int]$TestMapGridX = -3,
    [int]$TestMapGridY = 6,
    [ValidateSet("ERROR", "WARNING", "INFO", "VERBOSE", "DEBUG")]
    [string]$OpenMWLogLevel = "INFO",
    [switch]$Wait,
    [switch]$AllowDuplicate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Quote-OpenNVArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }
    return '"' + ($Argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$repoScripts = Join-Path $WorldsRoot "scripts"
. (Join-Path $repoScripts "WorldViewerPaths.ps1")

if ([string]::IsNullOrWhiteSpace($BinaryRoot)) {
    $BinaryRoot = Join-Path $WorldsRoot "local\openmw-testmap-fnv-clean-20260801-080000"
}
$BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$binary = Join-Path $BinaryRoot "openmw.exe"
$initializer = Join-Path $repoScripts "Initialize-OpenNVBaseProfile.ps1"
foreach ($path in @($binary, $initializer)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing TestMap gameplay launcher requirement: $path"
    }
}

if (-not $AllowDuplicate -and @(Get-Process -Name "openmw" -ErrorAction SilentlyContinue).Count -ne 0) {
    throw "OpenMW is already running. Close that session before starting an isolated TestMap gameplay run."
}

$stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
$sessionName = "newvegas-testmap-gameplay-$stamp"
$profileDirectory = Join-Path $WorldsRoot (Join-Path "profiles\_gameplay" $sessionName)
$campaignUserdataDirectory = Join-Path $WorldsRoot (Join-Path "profiles\_campaigns" (Join-Path $sessionName "userdata"))

# The initializer writes a one-run profile (including a fresh FNV input_v3.xml)
# and mounts only the official New Vegas content selected by the frozen policy.
$profile = & $initializer `
    -FalloutNewVegasData $FalloutNewVegasData `
    -ProfileDirectory $profileDirectory `
    -CampaignUserdataDirectory $campaignUserdataDirectory `
    -BinaryRoot $BinaryRoot `
    -DlcPolicy $DlcPolicy `
    -Force
if (-not [bool]$profile.launchable) {
    throw "The isolated TestMap gameplay profile is not launchable: $($profile.installReasons -join '; ')"
}

$arguments = @(
    "--replace", "config",
    "--config", [string]$profile.profileDirectory,
    "--resources", [string]$profile.resourcesRoot,
    "--skip-menu", "--new-game"
)
$argumentLine = ($arguments | ForEach-Object { Quote-OpenNVArgument $_ }) -join " "

Write-Host "Starting an interactive normal-player TestMap01 session."
Write-Host "Profile: $($profile.profileDirectory)"
Write-Host "Log:     $(Join-Path ([string]$profile.profileDirectory) 'openmw.log')"
Write-Host "Controls: WASD move; E activate/pick up; Tab Pip-Boy; F POV; V VATS; R reload; left mouse fire."
Write-Host "Placement: TestMap01 grid ($TestMapGridX, $TestMapGridY) after normal New Game initialization."

Clear-NikamiWorldViewerRuntimeEnvironment
$previousEnvironment = @{}
foreach ($name in @(
    "OPENMW_DEBUG_LEVEL",
    "OPENMW_FNV_GAMEPLAY_START_WORLDSPACE",
    "OPENMW_FNV_GAMEPLAY_START_GRID_X",
    "OPENMW_FNV_GAMEPLAY_START_GRID_Y"
)) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

try {
    [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", $OpenMWLogLevel, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_GAMEPLAY_START_WORLDSPACE", $TestMapWorldspace, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_GAMEPLAY_START_GRID_X", [string]$TestMapGridX, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_GAMEPLAY_START_GRID_Y", [string]$TestMapGridY, "Process")
    # This is the user-facing interactive game window, not a background proof
    # process. It receives ordinary keyboard and mouse input from the player.
    $process = Start-Process -FilePath $binary -ArgumentList $argumentLine `
        -WorkingDirectory (Split-Path -Parent $binary) -WindowStyle Normal -PassThru
}
finally {
    foreach ($entry in $previousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

$result = [pscustomobject][ordered]@{
    status = "started"
    pid = $process.Id
    binary = $binary
    profileDirectory = [string]$profile.profileDirectory
    userdataDirectory = $campaignUserdataDirectory
    logPath = Join-Path ([string]$profile.profileDirectory) "openmw.log"
    arguments = $arguments
    normalNewGame = $true
    finalDeveloperPlacement = [ordered]@{
        worldspace = $TestMapWorldspace
        grid = @($TestMapGridX, $TestMapGridY)
    }
}

if ($Wait) {
    $process.WaitForExit()
    $result | Add-Member -NotePropertyName exitCode -NotePropertyValue $process.ExitCode
}

$result
