param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "Invoke-FNVInteractionAudit.ps1"
$failures = New-Object System.Collections.Generic.List[string]
function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message) | Out-Null
    }
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $runner, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Contract ($parseErrors.Count -eq 0) "FNV interaction audit does not parse."

$source = Get-Content -LiteralPath $runner -Raw
foreach ($required in @(
    'OPENMW_WORLD_VIEWER_DOOR_PRELOAD_TELEMETRY = "1"',
    'config/door-preload',
    'phase=requested format=esm4 door=FormId:0x110636f destCell=FormId:0x1106185',
    'phase=complete format=esm4 door=FormId:0x110636f destCell=FormId:0x1106185',
    'completeBeforeActivation',
    'driven-subsystem-harness'
)) {
    Assert-Contract ($source.Contains($required)) "Door-preload contract is missing: $required"
}
$preloadSettings = Get-Content -LiteralPath (
    Join-Path (Split-Path -Parent $PSScriptRoot) "config\door-preload\settings.cfg") -Raw
foreach ($requiredSetting in @(
    'preload enabled = true',
    'preload doors = true',
    'preload distance = 32768',
    'preload instances = true',
    'preload cell cache min = 8',
    'preload cell cache max = 128'
)) {
    Assert-Contract ($preloadSettings.Contains($requiredSetting)) `
        "Door-preload settings are missing: $requiredSetting"
}
Assert-Contract ($source -match '\$doorPreloadComplete\.Index -lt \$doorActivation\.Index') `
    "Door-preload contract does not require completion before activation."
Assert-Contract ($source -match '"--config", \$doorPreloadConfig,\s*\r?\n\s*"--config", \$sessionConfig') `
    "FNV audit does not place an isolated per-run writable config after immutable door settings."
Assert-Contract ($source -match '"--user-data", \$sessionUserData') `
    "FNV audit does not isolate per-run user data."
Assert-Contract ($source -match 'CreateNoWindow\s*=\s*\$true') `
    "Door-preload audit is not background-only."
Assert-Contract ($source -notmatch 'SetForegroundWindow|ShowWindowAsync|user32\.dll') `
    "Door-preload audit contains forbidden foreground/window control."

if ($failures.Count -gt 0) {
    Write-Host "FNV door-preload contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "FNV door-preload contract passed."
