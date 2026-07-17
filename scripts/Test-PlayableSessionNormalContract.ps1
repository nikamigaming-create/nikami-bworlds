param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$catalogPath = Join-Path $repoRoot "catalog\playable-session-baselines.json"
$runnerPath = Join-Path $PSScriptRoot "Invoke-PlayableSessionBaseline.ps1"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message) | Out-Null
    }
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $runnerPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Contract ($parseErrors.Count -eq 0) "Playable-session runner does not parse."

$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$fnv = $catalog.worlds.fallout_new_vegas
Assert-Contract ([bool]$fnv.normalSession) "FNV is not marked as a normal session."
Assert-Contract (-not [bool]$fnv.neutralizeActor) "FNV still neutralizes Easy Pete."
Assert-Contract (-not [bool]$fnv.dryStart) "FNV still requests a dry proof cell."
Assert-Contract (-not [bool]$fnv.visualPromotionReady) `
    "FNV visual promotion is green despite retained acceptance blockers."
Assert-Contract (@($fnv.knownAcceptanceBlockers).Count -gt 0) `
    "FNV does not list its retained acceptance blockers."

$forbiddenCatalogEnvironment = @(
    "OPENMW_ESM4_PLAYER_NPC",
    "OPENMW_FNV_PLAYER_NPC",
    "OPENMW_ESM4_PLAYER_OUTFIT",
    "OPENMW_FNV_PLAYER_OUTFIT",
    "OPENMW_ESM4_PLAYER_HEADGEAR",
    "OPENMW_FNV_PLAYER_HEADGEAR",
    "OPENMW_FNV_PROOF_WEATHER_ID",
    "OPENMW_FNV_PROOF_IMAGE_SPACE_ID",
    "OPENMW_FNV_PROCEDURE_HOUR",
    "OPENMW_FNV_BOOTSTRAP_HOUR"
    "OPENMW_FNV_BOOTSTRAP_LEVEL1_COURIER"
)
$environmentNames = @($fnv.environment.PSObject.Properties.Name)
foreach ($name in $forbiddenCatalogEnvironment) {
    Assert-Contract ($environmentNames -notcontains $name) `
        "FNV normal-session catalog still contains $name."
}
Assert-Contract ([string]$fnv.environment.OPENMW_PLAYABLE_START_HOUR -eq "14.45") `
    "FNV normal-session package time is not driven through the world clock."

$runnerSource = Get-Content -LiteralPath $runnerPath -Raw
foreach ($required in @(
    'OPENMW_WORLD_VIEWER_START_DRY"] = "0"',
    'OPENMW_PLAYABLE_SESSION_NEUTRALIZE_ACTOR"] = "0"',
    'using native player visual proxy Player',
    'normalSessionRuntimePass',
    'effectiveEnvironment'
)) {
    Assert-Contract ($runnerSource.Contains($required)) "Runner is missing normal-session contract text: $required"
}
Assert-Contract ($runnerSource.Contains('config/door-preload')) `
    "Normal-session runner does not apply the authored door-preload config layer."
Assert-Contract ($runnerSource.Contains('config/fnv-playable-graphics')) `
    "Normal-session runner does not apply the FNV distant-world graphics layer."
Assert-Contract ($runnerSource -match 'if \(\$id -eq "fallout_new_vegas"\)[\s\S]*?\$argsList \+= @\("--config", \$fnvPlayableGraphicsConfig\)') `
    "FNV graphics layer is not scoped to the FNV session."
Assert-Contract ($runnerSource -match '\$argsList \+= @\("--config", \$sessionConfigDirectory\)') `
    "Playable-session runner does not finish with an isolated per-run writable config."
Assert-Contract ($runnerSource -match '\$argsList \+= @\("--user-data", \$sessionUserData\)') `
    "Playable-session runner does not isolate per-run user data."
Assert-Contract ($runnerSource -match '-WindowStyle Hidden') `
    "Playable-session runner does not require a hidden process."
Assert-Contract ($runnerSource -notmatch 'SetForegroundWindow|ShowWindowAsync|user32\.dll') `
    "Playable-session runner contains forbidden foreground/window control."

if ($failures.Count -gt 0) {
    Write-Host "Normal-session contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "FNV normal-session contract passed."
