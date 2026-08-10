param(
    [ValidateSet("Vanilla", "JAM", "FNV", "FNV-JAM", "FO3", "Fallout3", "TTW", "TTW-JAM")]
    [string]$Style = "TTW",
    # Campaign is the character-creation decision. Style remains for backward
    # compatible shortcuts such as -Style TTW-JAM.
    [string]$Campaign = "",
    [Alias("WithJam")]
    [switch]$EnableJam,
    [string]$TtwRoot = "",
    [string]$Fallout3Data = "",
    [string]$FalloutNewVegasData = "",
    [string]$JamRoot = "",
    [string[]]$Mod = @(),
    [Alias("Layer")]
    [string[]]$ModLayer = @(),
    [switch]$UseManagedMods,
    [string]$ProfileDirectory = "",
    [string]$BinaryRoot = "",
    # The normal player launcher resolves the configured stable runtime from
    # local/paths.json. A non-default, non-lab runtime is an explicit
    # engineering decision.
    [switch]$AllowExperimentalRuntime,
    [ValidateSet("Auto", "RequireAll")]
    [string]$DlcPolicy = "Auto",
    [switch]$ShowChoices,
    [switch]$DryRun,
    [switch]$Wait,
    [switch]$AllowDuplicate,
    [switch]$SkipMenu,
    [switch]$NewGame,
    # Normal play has no automatic cutoff. Pass -1 only for the campaign's
    # versioned diagnostic policy, or a positive value for an explicit limit.
    [double]$OpeningVideoSeconds = 0,
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

function Get-OpenNVCinematicPolicy {
    param(
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [Parameter(Mandatory=$true)][string]$Campaign
    )

    $catalogPath = Join-Path $RepositoryRoot "catalog/opennv-cinematic-policy.json"
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        return $null
    }

    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    foreach ($policy in @($catalog.policies)) {
        if ($null -eq $policy -or [string]::IsNullOrWhiteSpace([string]$policy.asset)) {
            continue
        }
        if (@($policy.campaigns) -notcontains $Campaign) {
            continue
        }
        $seconds = [double]$policy.maxSeconds
        if ($seconds -le 0) {
            continue
        }
        return [pscustomobject]@{
            id = [string]$policy.id
            asset = [string]$policy.asset
            maxSeconds = $seconds
            description = [string]$policy.description
        }
    }

    return $null
}

if ($ShowChoices) {
    @"
OpenNV campaign chooser

  Clickable launcher:     .\scripts\Start-OpenNVLauncher.ps1
  Fallout 3 vanilla:  -Campaign Fallout3
  New Vegas vanilla:  -Campaign NewVegas
  New Vegas + JAM:    -Campaign NewVegas -EnableJam
  TTW:                -Campaign TTW
  TTW + JAM:          -Campaign TTW -EnableJam

Choose the campaign before making a character. TTW is one Capital Wasteland-to-
Mojave character; standalone Fallout 3 and New Vegas saves do not cross over.
JAM is optional for New Vegas and TTW and can be added later, but keep saves
made with JAM in the JAM launch profile. Standalone FO3 remains vanilla.
Standalone games auto-detect owned DLC; TTW requires the full official DLC set.
"@ | Write-Host
    return
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ($OpeningVideoSeconds -lt -1) {
    throw "-OpeningVideoSeconds must be -1 (use campaign policy), 0 (no automatic cutoff), or a positive number."
}
if ([string]::IsNullOrWhiteSpace($BinaryRoot)) {
    $playerRuntimeRoot = Resolve-NikamiOpenMWRuntimeRoot
    $BinaryRoot = $playerRuntimeRoot
}
$BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
if (-not $AllowExperimentalRuntime) {
    $playerRuntimeRoot = Resolve-NikamiOpenMWRuntimeRoot
}
else {
    # An explicitly authorized runtime must not depend on the configured
    # default path being present. It is still subject to the lab/download
    # quarantine checks below.
    $playerRuntimeRoot = $BinaryRoot
}
$binaryRootFull = [IO.Path]::GetFullPath($BinaryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$playerRuntimeFull = [IO.Path]::GetFullPath($playerRuntimeRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$labRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "local/labs")).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if ($binaryRootFull.StartsWith($labRuntimeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "A local/labs runtime is quarantined and can never be used by the player launcher: $BinaryRoot"
}
if ($binaryRootFull -match '(?i)(^|[\\/])downloads([\\/]|$)') {
    throw "A Downloads runtime is not a stable launcher dependency: $BinaryRoot"
}
if (-not $AllowExperimentalRuntime -and -not $binaryRootFull.Equals($playerRuntimeFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The player launcher is pinned to $playerRuntimeRoot. Promote a tested runtime there, or pass -AllowExperimentalRuntime with an explicit non-lab BinaryRoot for engineering work."
}
$ResourcesRoot = Resolve-NikamiOpenMWResourcesRoot -ParameterValue (Join-Path $BinaryRoot "resources")

$styleMap = @{
    "Vanilla" = [pscustomobject]@{ Campaign = "NewVegas"; Jam = $false; Display = "New Vegas vanilla" }
    "FNV" = [pscustomobject]@{ Campaign = "NewVegas"; Jam = $false; Display = "New Vegas vanilla" }
    "JAM" = [pscustomobject]@{ Campaign = "NewVegas"; Jam = $true; Display = "New Vegas + JAM" }
    "FNV-JAM" = [pscustomobject]@{ Campaign = "NewVegas"; Jam = $true; Display = "New Vegas + JAM" }
    "FO3" = [pscustomobject]@{ Campaign = "Fallout3"; Jam = $false; Display = "Fallout 3 vanilla" }
    "Fallout3" = [pscustomobject]@{ Campaign = "Fallout3"; Jam = $false; Display = "Fallout 3 vanilla" }
    "TTW" = [pscustomobject]@{ Campaign = "TTW"; Jam = $false; Display = "Tale of Two Wastelands" }
    "TTW-JAM" = [pscustomobject]@{ Campaign = "TTW"; Jam = $true; Display = "Tale of Two Wastelands + JAM" }
}
$selection = $styleMap[$Style]
$styleWasExplicit = $PSBoundParameters.ContainsKey("Style")
$jamWasExplicit = $PSBoundParameters.ContainsKey("EnableJam")

if (-not [string]::IsNullOrWhiteSpace($Campaign)) {
    $campaignName = switch -Regex ($Campaign.Trim()) {
        '^(?i)(newvegas|fnv)$' { "NewVegas"; break }
        '^(?i)(fallout3|fo3)$' { "Fallout3"; break }
        '^(?i)ttw$' { "TTW"; break }
        default { throw "Unknown campaign '$Campaign'. Use NewVegas, Fallout3 (or FO3), or TTW." }
    }
    $requestedJam = if ($jamWasExplicit) { [bool]$EnableJam } elseif ($styleWasExplicit) { [bool]$selection.Jam } else { $false }
    if ($campaignName -eq "Fallout3" -and $requestedJam) {
        throw "JAM is an FNV/TTW module. Standalone Fallout 3 remains vanilla; choose -Campaign TTW -EnableJam for a Capital Wasteland character with JAM."
    }
    if ($styleWasExplicit -and ($selection.Campaign -ne $campaignName -or $selection.Jam -ne $requestedJam)) {
        throw "-Style $Style conflicts with -Campaign $Campaign$(if ($jamWasExplicit) { ' / -EnableJam' } else { '' }). Pick one campaign selection or make both agree."
    }
    $selection = [pscustomobject]@{
        Campaign = $campaignName
        Jam = $requestedJam
        Display = switch ($campaignName) {
            "NewVegas" { if ($requestedJam) { "New Vegas + JAM" } else { "New Vegas vanilla" } }
            "Fallout3" { "Fallout 3 vanilla" }
            default { if ($requestedJam) { "Tale of Two Wastelands + JAM" } else { "Tale of Two Wastelands" } }
        }
    }
}
elseif ($jamWasExplicit) {
    if ($selection.Campaign -eq "Fallout3" -and $EnableJam) {
        throw "JAM is an FNV/TTW module. Standalone Fallout 3 remains vanilla; choose -Campaign TTW -EnableJam for a Capital Wasteland character with JAM."
    }
    $selection = [pscustomobject]@{
        Campaign = $selection.Campaign
        Jam = [bool]$EnableJam
        Display = if ($selection.Campaign -eq "TTW") {
            if ($EnableJam) { "Tale of Two Wastelands + JAM" } else { "Tale of Two Wastelands" }
        }
        elseif ($selection.Campaign -eq "Fallout3") { "Fallout 3 vanilla" }
        elseif ($EnableJam) { "New Vegas + JAM" } else { "New Vegas vanilla" }
    }
}

$withJam = [bool]$selection.Jam
$withTtw = $selection.Campaign -eq "TTW"
$withFo3 = $selection.Campaign -eq "Fallout3"
$requestedModules = [Collections.Generic.List[string]]::new()
foreach ($moduleId in $Mod) {
    if (-not [string]::IsNullOrWhiteSpace($moduleId)) { $requestedModules.Add($moduleId) }
}
if ($UseManagedMods) {
    . (Join-Path $PSScriptRoot "OpenNVModManager.ps1")
    foreach ($moduleId in @(Get-OpenNVManagedSelection -Campaign $selection.Campaign)) {
        if (-not $requestedModules.Contains($moduleId)) { $requestedModules.Add($moduleId) }
    }
}
if ($withJam -and -not $requestedModules.Contains("jam")) {
    # Every JAM launch is resolved through the immutable depot, even when the
    # user selected it through a legacy style shortcut rather than -Mod jam.
    $requestedModules.Add("jam")
}
$modSelection = $null
if ($requestedModules.Count -gt 0 -or $ModLayer.Count -gt 0) {
    . (Join-Path $PSScriptRoot "OpenNVModManager.ps1")
    $modCatalog = Get-OpenNVModCatalog
    $modSelection = Resolve-OpenNVModSelection `
        -Catalog $modCatalog `
        -Campaign $selection.Campaign `
        -Module $requestedModules.ToArray() `
        -Layer $ModLayer
    if (-not $modSelection.ready) {
        $details = @($modSelection.blockedModules | ForEach-Object { "$($_.id): $($_.status) ($($_.detail))" }) -join "; "
        throw "The requested OpenNV mod layer is not compatible yet: $details"
    }
    if ($modSelection.includeJam) { $withJam = $true }
    $selectedJam = @($modSelection.validatedModules | Where-Object { $_.id -eq "jam" })
    if ($selectedJam.Count -gt 0) {
        $registeredJamRoot = [string]$selectedJam[0].sourcePath
        if (-not [string]::IsNullOrWhiteSpace($JamRoot)) {
            $requestedJamRoot = [IO.Path]::GetFullPath($JamRoot)
            if (-not $requestedJamRoot.TrimEnd('\\', '/') -ieq $registeredJamRoot.TrimEnd('\\', '/')) {
                throw "-JamRoot must be the registered hash-locked JAM depot path: $registeredJamRoot"
            }
        }
        $JamRoot = $registeredJamRoot
    }
}
$styleDisplay = switch ($selection.Campaign) {
    "NewVegas" { if ($withJam) { "New Vegas + JAM" } else { "New Vegas vanilla" } }
    "Fallout3" { "Fallout 3 vanilla" }
    default { if ($withJam) { "Tale of Two Wastelands + JAM" } else { "Tale of Two Wastelands" } }
}
$cinematicPolicy = Get-OpenNVCinematicPolicy -RepositoryRoot $repoRoot -Campaign $selection.Campaign
$openingVideoPolicySeconds = if ($OpeningVideoSeconds -ge 0) { $OpeningVideoSeconds } elseif ($null -ne $cinematicPolicy) { $cinematicPolicy.maxSeconds } else { 0 }
if ($AllowPartialInstall -and -not $withTtw) {
    throw "-AllowPartialInstall only applies to a TTW style."
}

if ($withTtw) {
    $initializer = Join-Path $PSScriptRoot "Initialize-TTWCompatibilityProfile.ps1"
    $initializerArguments = @{
        TtwRoot = $TtwRoot
        Fallout3Data = $Fallout3Data
        FalloutNewVegasData = $FalloutNewVegasData
        JamRoot = $JamRoot
        IncludeJam = $withJam
        ProfileDirectory = $ProfileDirectory
        BinaryRoot = $BinaryRoot
    }
    if ($DryRun) { $initializerArguments.DryRun = $true }
    if ($AllowPartialInstall) { $initializerArguments.AllowPartialInstall = $true }
    if ($ForceProfileConfig) { $initializerArguments.Force = $true }
}
elseif ($withFo3) {
    $initializer = Join-Path $PSScriptRoot "Initialize-OpenFO3BaseProfile.ps1"
    $initializerArguments = @{
        Fallout3Data = $Fallout3Data
        ProfileDirectory = $ProfileDirectory
        BinaryRoot = $BinaryRoot
        DlcPolicy = $DlcPolicy
    }
    if ($DryRun) { $initializerArguments.DryRun = $true }
    if ($ForceProfileConfig) { $initializerArguments.Force = $true }
}
else {
    $initializer = Join-Path $PSScriptRoot "Initialize-OpenNVBaseProfile.ps1"
    $initializerArguments = @{
        FalloutNewVegasData = $FalloutNewVegasData
        JamRoot = $JamRoot
        IncludeJam = $withJam
        ProfileDirectory = $ProfileDirectory
        BinaryRoot = $BinaryRoot
        DlcPolicy = $DlcPolicy
    }
    if ($DryRun) { $initializerArguments.DryRun = $true }
    if ($ForceProfileConfig) { $initializerArguments.Force = $true }
}

if (-not (Test-Path -LiteralPath $initializer -PathType Leaf)) {
    throw "Missing OpenNV initializer: $initializer"
}
# The launcher owns generated openmw.cfg files under profiles/.  It may refresh
# an older generated file after preserving it, but it will still refuse a
# manually customized configuration unless the caller explicitly passes
# -ForceProfileConfig.
if (-not $DryRun) { $initializerArguments.UpgradeGeneratedProfile = $true }
$profile = & $initializer @initializerArguments
if (-not $profile.launchable -and -not $DryRun) {
    throw "The selected $styleDisplay profile is not launchable: $($profile.installReasons -join '; ')"
}

$binary = Join-Path $BinaryRoot "openmw.exe"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "Missing OpenNV executable: $binary"
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
Write-Host "OpenNV style: $styleDisplay"
Write-Host "Campaign:     $($selection.Campaign)"
Write-Host "Character:    campaign is chosen at character creation; never load a save across New Vegas, Fallout 3, and TTW."
if ($withTtw) {
    Write-Host "TTW path:     one Capital Wasteland-to-Mojave character; stock TTW begins on the Fallout 3 side."
}
if ($withJam) {
    Write-Host "JAM:          enabled. This campaign shares its save store with the non-JAM profile; keep any JAM save in a JAM launch thereafter."
}
elseif ($withFo3) {
    Write-Host "JAM:          standalone Fallout 3 stays vanilla. For the Capital Wasteland with JAM, create a TTW character with -Campaign TTW -EnableJam."
}
else {
    Write-Host "JAM:          disabled. Add it later with -Campaign $($selection.Campaign) -EnableJam; it will use this campaign's save store."
}
if ($null -ne $modSelection) {
    Write-Host "Mods:         $($modSelection.requestedModuleIds -join ', ')"
}
Write-Host "Runtime:      $BinaryRoot"
Write-Host "Profile:      $($profile.profileDirectory)"
if ($profile.PSObject.Properties.Name -contains "profileConfigState" -and
    [string]$profile.profileConfigState -ne "current") {
    Write-Host "Profile config: $($profile.profileConfigState). The launcher will refresh only its own generated openmw.cfg and retain a backup."
}
Write-Host "Content:      $($profile.content -join ' -> ')"
if ($null -ne $cinematicPolicy -and $openingVideoPolicySeconds -gt 0) {
    Write-Host "Opening video: $($cinematicPolicy.asset), capped at $openingVideoPolicySeconds seconds ($($cinematicPolicy.id))."
}
if ($profile.PSObject.Properties.Name -contains "unavailableDlc" -and @($profile.unavailableDlc).Count -gt 0) {
    Write-Host "DLC:          ownership-aware; not mounted: $($profile.unavailableDlc -join ', ')"
}
Write-Host "Command:      $commandLine"
Write-Host "Safety:       source game/mod contents and directory entries remain untouched; campaigns have separate saves and only JAM variants share their campaign store."
if ($withTtw -and -not $profile.installComplete) {
    Write-Warning "TTW is using source-archive compatibility mode, not a full official installer output."
}

if ($DryRun) {
    Write-Host "Dry run only; not starting OpenNV."
    exit 0
}

$processName = [IO.Path]::GetFileNameWithoutExtension($binary)
if (-not $AllowDuplicate -and (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
    throw "$processName is already running. Close it first or pass -AllowDuplicate."
}

Clear-NikamiWorldViewerRuntimeEnvironment
$previousDebugLevel = [Environment]::GetEnvironmentVariable("OPENMW_DEBUG_LEVEL", "Process")
$previousPresentationVideoMatch = [Environment]::GetEnvironmentVariable("OPENNV_PRESENTATION_VIDEO_MATCH", "Process")
$previousPresentationVideoSeconds = [Environment]::GetEnvironmentVariable("OPENNV_PRESENTATION_VIDEO_MAX_SECONDS", "Process")
try {
    [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", $OpenMWLogLevel, "Process")
    if ($null -ne $cinematicPolicy -and $openingVideoPolicySeconds -gt 0) {
        [Environment]::SetEnvironmentVariable("OPENNV_PRESENTATION_VIDEO_MATCH", $cinematicPolicy.asset, "Process")
        [Environment]::SetEnvironmentVariable("OPENNV_PRESENTATION_VIDEO_MAX_SECONDS", [string]$openingVideoPolicySeconds, "Process")
    }
    $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $binary) -PassThru
}
finally {
    [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", $previousDebugLevel, "Process")
    [Environment]::SetEnvironmentVariable("OPENNV_PRESENTATION_VIDEO_MATCH", $previousPresentationVideoMatch, "Process")
    [Environment]::SetEnvironmentVariable("OPENNV_PRESENTATION_VIDEO_MAX_SECONDS", $previousPresentationVideoSeconds, "Process")
}

Write-Host "Started PID $($process.Id)."
if ($Wait) {
    $process.WaitForExit()
    Write-Host "$processName exited with code $($process.ExitCode)."
    exit $process.ExitCode
}
