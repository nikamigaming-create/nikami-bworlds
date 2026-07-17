param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$auditPath = Join-Path $PSScriptRoot "Invoke-FNVInteractionAudit.ps1"
$failures = [Collections.Generic.List[string]]::new()

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failures.Add($Message) | Out-Null }
}

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $auditPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Contract ($parseErrors.Count -eq 0) "PowerShell parse failure: $auditPath"

$source = Get-Content -LiteralPath $auditPath -Raw
foreach ($required in @(
    'FNV/ESM4 fog proof: mode=authored-fnam',
    'authoredFogState',
    'authoredFnamActive',
    'nearMatchesGoodsprings',
    'farMatchesGoodsprings',
    'powerMatchesGoodsprings',
    'rangeMatchesGoodsprings',
    'denominatorMatchesRange',
    'WTHR/FNAM'
)) {
    Assert-Contract ($source.Contains($required)) "Authored-fog gate is missing '$required'."
}
Assert-Contract ($source -match '\$passed[\s\S]*?-and \$authoredFogPass') `
    "Interaction audit does not make authored FNAM fog a pass gate."
Assert-Contract ($source.Contains('$expectedFogFar = 150000.0 + ((120000.0 - 150000.0) * $fogDayStrength)')) `
    "Goodsprings day/night far distances are not pinned to 120000/150000."
Assert-Contract ($source.Contains('$expectedFogNear = 10.0 * $fogDayStrength')) `
    "Goodsprings day/night near distances are not pinned to 10/0."
Assert-Contract ($source.Contains('$expectedFogPower = 0.5')) `
    "Goodsprings fog power is not pinned to 0.5."

if ($failures.Count -ne 0) {
    Write-Host "FNV authored-fog contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "FNV authored-fog contract passed (FNAM selection, retail sampling, renderer denominator)."
