param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$catalogPath = Join-Path $repoRoot "catalog\flat-world-proof-starts.json"
$naturalProofPath = Join-Path $PSScriptRoot "Invoke-FNVNaturalSkyProof.ps1"
$slotProofPath = Join-Path $PSScriptRoot "Invoke-FNVSingleProcessSkyProof.ps1"
$walkaroundPath = Join-Path $PSScriptRoot "Start-FalloutWalkaround.ps1"
$interactionAuditPath = Join-Path $PSScriptRoot "Invoke-FNVInteractionAudit.ps1"
$failures = [Collections.Generic.List[string]]::new()

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failures.Add($Message) | Out-Null }
}

foreach ($path in @($naturalProofPath, $slotProofPath, $walkaroundPath, $interactionAuditPath)) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-Contract ($parseErrors.Count -eq 0) "PowerShell parse failure: $path"
}

$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$fnvEnvironmentNames = @($catalog.worlds.fallout_new_vegas.environment.PSObject.Properties.Name)
Assert-Contract ($fnvEnvironmentNames -notcontains "OPENMW_FNV_PROOF_WEATHER_ID") `
    "The base FNV proof start still forces a weather slot."

$naturalSource = Get-Content -LiteralPath $naturalProofPath -Raw
foreach ($required in @(
    'OPENMW_FNV_PROOF_WEATHER_ID=',
    'OPENMW_FNV_PROOF_IMAGE_SPACE_ID=',
    'OPENMW_WORLD_VIEWER_CAMERA_ANGLE_SEQUENCE_FRAMES=',
    'nativeCardinalCaptures',
    'naturalWeatherSelected',
    'noWeatherForce',
    'fourCloudLayersMapped',
    'authoredCloudTextureActive',
    'atmosphereActive'
)) {
    Assert-Contract ($naturalSource.Contains($required)) "Natural-sky gate is missing '$required'."
}
Assert-Contract ($naturalSource -notmatch 'OPENMW_FNV_PROOF_WEATHER_ID=(?:0|1)["'']') `
    "Natural-sky proof uses a numeric weather-slot override."

$slotSource = Get-Content -LiteralPath $slotProofPath -Raw
Assert-Contract ($slotSource.Contains('OPENMW_FNV_PROOF_WEATHER_ID=FormId:0x11237d7')) `
    "Six-slot sky proof does not force the authored Goodsprings WTHR by FormID."
Assert-Contract ($slotSource -notmatch 'OPENMW_FNV_PROOF_WEATHER_ID=(?:0|1)["'']') `
    "Six-slot sky proof still uses a numeric manager slot."

$walkaroundSource = Get-Content -LiteralPath $walkaroundPath -Raw
Assert-Contract ($walkaroundSource.Contains('natural authored region weather')) `
    "Interactive walkaround does not describe its natural-weather contract."
Assert-Contract ($walkaroundSource -notmatch '\$environment\["OPENMW_FNV_PROOF_WEATHER_ID"\]\s*=') `
    "Interactive walkaround still assigns a forced weather."
Assert-Contract ($walkaroundSource -notmatch '\$environment\["OPENMW_FNV_PROOF_IMAGE_SPACE_ID"\]\s*=') `
    "Interactive walkaround still assigns a forced image space."

$interactionSource = Get-Content -LiteralPath $interactionAuditPath -Raw
foreach ($required in @(
    'naturalSkyState',
    'authoredRegionWeather',
    'noWeatherForce',
    'fourCloudLayersMapped',
    'authoredCloudTextureActive',
    'atmosphereActive',
    'exteriorReturnPassed'
)) {
    Assert-Contract ($interactionSource.Contains($required)) `
        "Interior-return audit is missing the natural-sky check '$required'."
}
Assert-Contract ($interactionSource -match '\$passed[\s\S]*?-and \$naturalSkyPass') `
    "Interior-return audit does not make natural sky state a pass gate."

if ($failures.Count -ne 0) {
    Write-Host "FNV natural-sky contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "FNV natural-sky contract passed (natural base, authored explicit proof, four-view gate)."
