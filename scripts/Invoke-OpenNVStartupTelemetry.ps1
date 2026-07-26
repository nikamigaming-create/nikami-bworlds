param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Fallout3", "NewVegas")]
    [string]$Campaign,
    [string]$Fallout3Data = "",
    [string]$FalloutNewVegasData = "",
    [string]$BinaryRoot = "",
    [string]$Scenario = "",
    [string[]]$RequiredQuest = @(),
    [ValidateRange(1, 3600)]
    [int]$Frame = 120,
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Quote-OpenNVArgument {
    param([Parameter(Mandatory=$true)][string]$Argument)

    if ($Argument -match '[\s"]') {
        return '"' + ($Argument -replace '"', '\"') + '"'
    }
    return $Argument
}

function Clear-AuthenticStartOverrides {
    $names = @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ } | Where-Object {
        $_.StartsWith("OPENMW_WORLD_VIEWER_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith("OPENMW_PROOF_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith("OPENMW_COMPAT_TELEMETRY_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith("OPENMW_FNV_BOOTSTRAP_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith("OPENMW_PLAYABLE_SESSION_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.Equals("OPENMW_STARTUP_SCRIPT", [StringComparison]::OrdinalIgnoreCase)
    })
    $previous = @{}
    foreach ($name in $names) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    return $previous
}

function Restore-ProcessEnvironment {
    param([Parameter(Mandatory=$true)][hashtable]$Values)

    foreach ($name in $Values.Keys) {
        [Environment]::SetEnvironmentVariable($name, $Values[$name], "Process")
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$safeTimestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$safeCampaign = if ($Campaign -eq "Fallout3") { "fallout3" } else { "newvegas" }
$scenarioName = if ([string]::IsNullOrWhiteSpace($Scenario)) { "$safeCampaign-authentic-new-game" } else { $Scenario }
$verificationRoot = Join-Path $repoRoot "profiles/_verification/$safeCampaign-$safeTimestamp"
$campaignUserdata = Join-Path $repoRoot "profiles/_verification/_campaigns/$safeCampaign-$safeTimestamp/userdata"
$reportRoot = Join-Path $repoRoot "run/opennv-startup-telemetry/$safeCampaign-$safeTimestamp"
$reportPath = Join-Path $reportRoot "telemetry.json"

New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null

if ($Campaign -eq "Fallout3") {
    $initializer = Join-Path $PSScriptRoot "Initialize-OpenFO3BaseProfile.ps1"
    $initializerArguments = @{
        Fallout3Data = $Fallout3Data
        ProfileDirectory = $verificationRoot
        CampaignUserdataDirectory = $campaignUserdata
        BinaryRoot = $BinaryRoot
        Force = $true
    }
}
else {
    $initializer = Join-Path $PSScriptRoot "Initialize-OpenNVBaseProfile.ps1"
    $initializerArguments = @{
        FalloutNewVegasData = $FalloutNewVegasData
        ProfileDirectory = $verificationRoot
        CampaignUserdataDirectory = $campaignUserdata
        BinaryRoot = $BinaryRoot
        Force = $true
    }
}

$profile = & $initializer @initializerArguments
$binary = Join-Path $profile.runtimeRoot "openmw.exe"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "Missing OpenNV executable: $binary"
}

$arguments = @(
    "--replace", "config",
    "--config", [string]$profile.profileDirectory,
    "--resources", [string]$profile.resourcesRoot,
    "--skip-menu", "--new-game"
)
$argumentLine = ($arguments | ForEach-Object { Quote-OpenNVArgument $_ }) -join " "

$plan = [ordered]@{
    schema = "opennv-authentic-start-plan/v1"
    scenario = $scenarioName
    campaign = $Campaign
    command = "$binary $argumentLine"
    profileDirectory = $profile.profileDirectory
    campaignUserdataDirectory = $campaignUserdata
    telemetryPath = $reportPath
    requiredQuests = @($RequiredQuest)
    guarantees = @(
        "Starts a new game through the engine's normal --skip-menu --new-game path.",
        "Does not pass --start or any start-cell override.",
        "Clears proof, bootstrap, scripted-start, and force-level environment overrides for this child process.",
        "Uses an isolated generated profile and campaign userdata directory.",
        "Does not capture a window, send foreground input, or modify licensed game directories."
    )
}
[IO.File]::WriteAllText((Join-Path $reportRoot "plan.json"), (($plan | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

$previousEnvironment = Clear-AuthenticStartOverrides
$previousEnvironment["OPENMW_DEBUG_LEVEL"] = [Environment]::GetEnvironmentVariable("OPENMW_DEBUG_LEVEL", "Process")
try {
    [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", "INFO", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_COMPAT_TELEMETRY_PATH", $reportPath, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_COMPAT_TELEMETRY_SCENARIO", $scenarioName, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_COMPAT_TELEMETRY_REQUIRED_QUESTS", ($RequiredQuest -join ','), "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_COMPAT_TELEMETRY_FRAME", [string]$Frame, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_COMPAT_TELEMETRY_EXIT_AFTER_WRITE", "1", "Process")

    $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $binary) -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "OpenNV startup telemetry timed out after $TimeoutSeconds seconds; stopped isolated test PID $($process.Id)."
    }
}
finally {
    Restore-ProcessEnvironment -Values $previousEnvironment
}

if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    throw "OpenNV exited without writing startup telemetry. Check the isolated profile at $verificationRoot."
}

$telemetry = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
if ([string]$telemetry.schema -cne "opennv-compat-telemetry/v1") {
    throw "Unsupported OpenNV telemetry schema in ${reportPath}: $($telemetry.schema)"
}

[pscustomobject]@{
    schema = "opennv-authentic-start-result/v1"
    campaign = $Campaign
    scenario = $scenarioName
    exitCode = $process.ExitCode
    profileDirectory = $verificationRoot
    reportPath = $reportPath
    result = $telemetry.result
    gaps = @($telemetry.gaps)
    player = $telemetry.player
    chargenState = $telemetry.chargenState
    quests = @($telemetry.quests)
    launch = $telemetry.launch
} | ConvertTo-Json -Depth 8
