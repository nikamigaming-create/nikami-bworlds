[CmdletBinding()]
param(
    [string]$RoutePath = "",
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$BinaryRoot = "D:\code\nikami-worlds\local\openmw-ttw-compat",
    [string]$TtwRoot = "D:\Modlists\fnv\mods\Tale of Two Wastelands - OpenMW",
    [string]$Fallout3Data = "D:\SteamLibrary\steamapps\common\Fallout 3 goty\Data",
    [string]$FalloutNewVegasData = "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data",
    [ValidateRange(0, 120)]
    [int]$OpeningVideoSeconds = 26,
    [ValidateRange(0, 30)]
    [double]$DefaultChoiceDelaySeconds = 1,
    [ValidateRange(30, 900)]
    [int]$TimeoutSeconds = 360,
    [string]$OutputRoot = ""
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

function Save-And-ClearOpenNVRouteEnvironment {
    $previous = @{}
    $names = @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ } | Where-Object {
        $_.StartsWith("OPENMW_COMPAT_ROUTE_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith("OPENMW_COMPAT_TELEMETRY_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith("OPENMW_WORLD_VIEWER_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith("OPENMW_PROOF_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith("OPENMW_FNV_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith("OPENMW_PLAYABLE_SESSION_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith("OPENMW_CAPTURE_VIDEO_", [StringComparison]::OrdinalIgnoreCase) -or
        $_.Equals("OPENMW_AUTHORED_DEFAULT_CHOICE_DELAY_SECONDS", [StringComparison]::OrdinalIgnoreCase) -or
        $_.Equals("OPENMW_AUTHORED_START_TELEMETRY", [StringComparison]::OrdinalIgnoreCase) -or
        $_.Equals("OPENMW_STARTUP_SCRIPT", [StringComparison]::OrdinalIgnoreCase) -or
        $_.Equals("OPENMW_DEBUG_LEVEL", [StringComparison]::OrdinalIgnoreCase)
    })
    # The runner is intentionally unattended.  Preserve and then override this
    # switch even when it was absent from the caller's environment so an engine
    # failure is recorded in the log instead of leaving a fatal-dialog window
    # waiting for forbidden foreground interaction.
    if ($names -notcontains "OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG") {
        $names += "OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG"
    }
    foreach ($name in $names) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    return $previous
}

function Restore-Environment {
    param([Parameter(Mandatory=$true)][hashtable]$Values)

    foreach ($entry in $Values.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$BinaryRoot = [IO.Path]::GetFullPath($BinaryRoot)
$TtwRoot = [IO.Path]::GetFullPath($TtwRoot)
$Fallout3Data = [IO.Path]::GetFullPath($Fallout3Data)
$FalloutNewVegasData = [IO.Path]::GetFullPath($FalloutNewVegasData)
if ([string]::IsNullOrWhiteSpace($RoutePath)) {
    $RoutePath = Join-Path $WorldsRoot "catalog\opennv-authored-ttw-nursery-route.json"
}
$RoutePath = [IO.Path]::GetFullPath($RoutePath)

foreach ($directory in @($WorldsRoot, $BinaryRoot, $TtwRoot, $Fallout3Data, $FalloutNewVegasData)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Missing required authored-route directory: $directory"
    }
}
foreach ($file in @($RoutePath, (Join-Path $BinaryRoot "openmw.exe"), (Join-Path $WorldsRoot "scripts\Initialize-TTWCompatibilityProfile.ps1"))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing required authored-route file: $file"
    }
}

$route = Get-Content -LiteralPath $RoutePath -Raw | ConvertFrom-Json
if ([string]$route.schema -ne "opennv-authored-route/v1" -or [string]::IsNullOrWhiteSpace([string]$route.id) -or @($route.steps).Count -eq 0) {
    throw "The route manifest is not an opennv-authored-route/v1 document with an id and steps: $RoutePath"
}

$running = @(Get-Process -Name "openmw" -ErrorAction SilentlyContinue)
if ($running.Count -ne 0) {
    throw "Refusing to overlap authored-route telemetry with an existing OpenMW process: $($running.Id -join ', ')"
}

$stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $WorldsRoot "run\opennv-authored-route-$($route.id)-$stamp"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing authored-route evidence directory: $OutputRoot"
}

$profileDirectory = Join-Path $WorldsRoot "profiles\_verification\authored-route-$stamp"
$campaignUserdata = Join-Path $WorldsRoot "profiles\_verification\_campaigns\authored-route-$stamp\userdata"
$reportPath = Join-Path $OutputRoot "route-report.json"
$stdoutPath = Join-Path $OutputRoot "openmw.stdout.log"
$stderrPath = Join-Path $OutputRoot "openmw.stderr.log"
$planPath = Join-Path $OutputRoot "plan.json"
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

$profile = & (Join-Path $WorldsRoot "scripts\Initialize-TTWCompatibilityProfile.ps1") `
    -TtwRoot $TtwRoot `
    -Fallout3Data $Fallout3Data `
    -FalloutNewVegasData $FalloutNewVegasData `
    -ProfileDirectory $profileDirectory `
    -CampaignUserdataDirectory $campaignUserdata `
    -BinaryRoot $BinaryRoot `
    -Force
if (-not [bool]$profile.launchable) {
    throw "The isolated TTW route profile is not launchable: $($profile.installReasons -join '; ')"
}

$binary = Join-Path $profile.runtimeRoot "openmw.exe"
$plan = [ordered]@{
    schema = "opennv-authored-route-plan/v1"
    route = [string]$route.id
    routePath = $RoutePath
    reportPath = $reportPath
    profileDirectory = [string]$profile.profileDirectory
    campaignUserdataDirectory = $campaignUserdata
    openingVideoSeconds = $OpeningVideoSeconds
    defaultChoiceDelaySeconds = $DefaultChoiceDelaySeconds
    guarantees = @(
        "Starts the normal --skip-menu --new-game path with the generated TTW profile.",
        "Does not pass a start-cell override, set a quest stage, or inject a player level.",
        "The route only calls engine-internal, manifest-declared normal World movement and class activation actions.",
        "Does not capture a window, focus or activate a window, click, send input, or modify licensed game data."
    )
}
[IO.File]::WriteAllText($planPath, (($plan | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

$previousEnvironment = Save-And-ClearOpenNVRouteEnvironment
$process = $null
try {
    [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", "INFO", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_COMPAT_ROUTE_PATH", $RoutePath, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_COMPAT_ROUTE_REPORT_PATH", $reportPath, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_COMPAT_ROUTE_EXIT_AFTER_WRITE", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_AUTHORED_DEFAULT_CHOICE_DELAY_SECONDS", $DefaultChoiceDelaySeconds.ToString("0.###", [Globalization.CultureInfo]::InvariantCulture), "Process")
    if ($OpeningVideoSeconds -gt 0) {
        [Environment]::SetEnvironmentVariable("OPENMW_CAPTURE_VIDEO_MATCH", "Fallout INTRO Vsk.bik", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_CAPTURE_VIDEO_MAX_SECONDS", [string]$OpeningVideoSeconds, "Process")
    }

    $arguments = @(
        "--replace", "config",
        "--config", [string]$profile.profileDirectory,
        "--resources", [string]$profile.resourcesRoot,
        "--skip-menu", "--new-game"
    )
    $argumentLine = ($arguments | ForEach-Object { Quote-OpenNVArgument $_ }) -join " "
    # A normal game window is required for the renderer, but this runner never
    # focuses, moves, clicks, or sends input to it. The process exits itself
    # when the declared route report is written.
    $process = Start-Process -FilePath $binary -ArgumentList $argumentLine `
        -WorkingDirectory (Split-Path -Parent $binary) -WindowStyle Normal `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "OpenNV authored-route telemetry timed out after $TimeoutSeconds seconds; stopped only isolated test PID $($process.Id)."
    }
}
finally {
    Restore-Environment -Values $previousEnvironment
}

if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    throw "OpenNV exited without a route report. Inspect $stdoutPath and $stderrPath."
}
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
if ([string]$report.schema -ne "opennv-authored-route-report/v1") {
    throw "Unexpected authored-route report schema: $($report.schema)"
}

[pscustomobject]@{
    schema = "opennv-authored-route-result/v1"
    route = [string]$route.id
    exitCode = $process.ExitCode
    outputRoot = $OutputRoot
    reportPath = $reportPath
    status = $report.status
    resultDetail = $report.resultDetail
    steps = @($report.steps)
    launch = [ordered]@{
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
    }
} | ConvertTo-Json -Depth 10

if ([string]$report.status -ne "pass") {
    throw "The declared authored route did not pass. See $reportPath"
}
