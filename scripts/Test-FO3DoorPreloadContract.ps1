param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "Invoke-FO3InteractionAudit.ps1"
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
Assert-Contract ($parseErrors.Count -eq 0) "FO3 interaction audit does not parse."

$source = Get-Content -LiteralPath $runner -Raw
foreach ($required in @(
    'OPENMW_WORLD_VIEWER_DOOR_PRELOAD_TELEMETRY = "1"',
    'config/door-preload',
    'phase=requested format=esm4 door=FormId:0x1003a23 destCell=FormId:0x1003a35',
    'phase=complete format=esm4 door=FormId:0x1003a23 destCell=FormId:0x1003a35',
    'completeBeforeActivation'
)) {
    Assert-Contract ($source.Contains($required)) "FO3 door-preload contract is missing: $required"
}
Assert-Contract ($source -match '\$doorPreloadComplete\.Index -lt \$doorActivation\.Index') `
    "FO3 door-preload contract does not require completion before activation."
Assert-Contract ($source -match '"--config", \$doorPreloadConfig,\s*\r?\n\s*"--config", \$sessionConfig') `
    "FO3 audit does not place an isolated per-run writable config after immutable door settings."
Assert-Contract ($source -match '"--user-data", \$sessionUserData') `
    "FO3 audit does not isolate per-run user data."
Assert-Contract ($source -match 'CreateNoWindow\s*=\s*\$true') `
    "FO3 interaction audit is not background-only."
Assert-Contract ($source -notmatch 'SetForegroundWindow|ShowWindowAsync|user32\.dll') `
    "FO3 interaction audit contains forbidden foreground/window control."

if ($failures.Count -gt 0) {
    Write-Host "FO3 door-preload contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "FO3 door-preload contract passed."
