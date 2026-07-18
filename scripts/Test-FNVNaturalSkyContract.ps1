param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$catalogPath = Join-Path $repoRoot "catalog\flat-world-proof-starts.json"
$naturalProofPath = Join-Path $PSScriptRoot "Invoke-FNVNaturalSkyProof.ps1"
$slotProofPath = Join-Path $PSScriptRoot "Invoke-FNVSingleProcessSkyProof.ps1"
$walkaroundPath = Join-Path $PSScriptRoot "Start-FalloutWalkaround.ps1"
$interactionAuditPath = Join-Path $PSScriptRoot "Invoke-FNVInteractionAudit.ps1"
$worldViewerPathsPath = Join-Path $PSScriptRoot "WorldViewerPaths.ps1"
$failures = [Collections.Generic.List[string]]::new()

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failures.Add($Message) | Out-Null }
}

foreach ($path in @($naturalProofPath, $slotProofPath, $walkaroundPath, $interactionAuditPath, $worldViewerPathsPath)) {
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
    'atmosphereActive',
    'boundedEvidenceSelfConsistent',
    'boundedEvidenceMatchesLaunch',
    'preLaunchFreshness',
    'postRunFreshness',
    'inheritedSkyEnvironmentCleared',
    'boundedInputEvidence'
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
foreach ($required in @(
    'New-NikamiOpenMWBoundedInputEvidence',
    'Assert-NikamiOpenMWBoundedInputEvidence',
    'Get-NikamiOpenMWBoundedInputEvidenceLogLines'
)) {
    Assert-Contract ($walkaroundSource.Contains($required)) `
        "Interactive walkaround does not record bounded input evidence with '$required'."
}
Assert-Contract ($walkaroundSource.LastIndexOf('-VerifyCurrent') -ge 0 -and
    $walkaroundSource.LastIndexOf('-VerifyCurrent') -lt $walkaroundSource.IndexOf('$process = Start-Process')) `
    "Interactive walkaround does not verify bounded-input freshness immediately before launch."

$interactionSource = Get-Content -LiteralPath $interactionAuditPath -Raw
foreach ($required in @(
    'naturalSkyState',
    'authoredRegionWeather',
    'noWeatherForce',
    'fourCloudLayersMapped',
    'authoredCloudTextureActive',
    'atmosphereActive',
    'exteriorReturnPassed',
    'boundedInputEvidence',
    'resourceVersionContract',
    'configurationContract',
    'officialCorpusContract',
    'boundedInputFreshnessChecks',
    'environmentIsolationStatus'
)) {
    Assert-Contract ($interactionSource.Contains($required)) `
        "Interior-return audit is missing the natural-sky check '$required'."
}
Assert-Contract ($interactionSource -match '\$passed[\s\S]*?-and \$naturalSkyPass') `
    "Interior-return audit does not make natural sky state a pass gate."
Assert-Contract ($interactionSource -match '\$passed[\s\S]*?-and \$boundedEvidenceSelfConsistent[\s\S]*?-and \$preLaunchFreshness -and \$postRunFreshness') `
    "Interior-return audit does not gate bounded evidence and pre/post freshness."
Assert-Contract ($interactionSource -notmatch '(?m)^\s*(resourcesSha256|configurationSha256|dataSha256)\s*=') `
    "Interior-return audit still overstates a generic full-input SHA-256."

$pathsSource = Get-Content -LiteralPath $worldViewerPathsPath -Raw
foreach ($required in @(
    'OPENMW_FNV_PROOF_',
    'OPENMW_FNV_ENABLE_SKY_SHADER_PROPERTIES',
    'OPENMW_FNV_NATIVE_CLOUD_OPACITY',
    'OPENMW_FNV_SKY_MESH_SCALE',
    'OPENMW_FNV_SKY_MISSING_LOG',
    'OPENMW_FNV_SKY_TARGET_RADIUS',
    'nikami-openmw-bounded-input-evidence/v1',
    'expectedBytes',
    'observedBytes',
    'expectedSha256',
    'hashVerification = "not-observed"',
    'bounded-input-evidence-not-full-effective-input-provenance',
    'full resources tree is not hashed',
    'FNVR.esp is not hashed',
    'loose overlay files are not hashed',
    'shared UI data are not hashed',
    'catalog/fnv-parity-denominators.json',
    'Assert-NikamiOpenMWBoundedInputEvidence'
)) {
    Assert-Contract ($pathsSource.Contains($required)) `
        "Shared launcher contract is missing '$required'."
}

# Synthetic unit proof: no real launcher or game process is invoked.
. $worldViewerPathsPath
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("nikami-fnv-launch-contract-" + [Guid]::NewGuid().ToString("N"))
try {
    $resources = New-Item -ItemType Directory -Path (Join-Path $fixture "resources") -Force
    $data = New-Item -ItemType Directory -Path (Join-Path $fixture "data") -Force
    $exe = Join-Path $fixture "openmw.exe"; $config = Join-Path $fixture "openmw.cfg"
    $master = Join-Path $data "Synthetic.esm"; $archive = Join-Path $data "Synthetic.bsa"
    Set-Content $exe "exe"; Set-Content (Join-Path $resources "version") "resources"
    [IO.File]::WriteAllText($master, "master", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($archive, "archive", [Text.Encoding]::ASCII)
    Set-Content $config @("data=$data", "content=Synthetic.esm", "fallback-archive=Synthetic.bsa")
    $denominator = Join-Path $fixture "denominators.json"
    [ordered]@{
        schema = "nikami-fnv-parity-denominators/v1"; scopeId = "synthetic"
        officialMasters = @([ordered]@{ name = "Synthetic.esm"; bytes = (Get-Item $master).Length; sha256 = (Get-FileHash $master).Hash })
        officialArchives = @([ordered]@{ name = "Synthetic.bsa"; bytes = (Get-Item $archive).Length; sha256 = (Get-FileHash $archive).Hash })
    } | ConvertTo-Json -Depth 5 | Set-Content $denominator
    $args = @{ Executable=$exe; ResourcesRoot=$resources; ConfigurationPath=@($config);
        DataConfigPath=$config; DataRoot=@($data); DenominatorPath=$denominator; AllowSyntheticDenominator=$true }
    $evidence = New-NikamiOpenMWBoundedInputEvidence @args
    Assert-Contract ([bool](Assert-NikamiOpenMWBoundedInputEvidence -Evidence $evidence @args -VerifyCurrent)) `
        "Synthetic bounded input evidence did not validate."
    Assert-Contract ($evidence.officialCorpusContract.officialFiles[0].hashVerification -eq "not-observed") `
        "Expected official SHA-256 was mislabeled as observed."
    [IO.File]::WriteAllText($master, "MASTER", [Text.Encoding]::ASCII)
    Assert-Contract ([bool](Assert-NikamiOpenMWBoundedInputEvidence -Evidence $evidence @args -VerifyCurrent)) `
        "Fast bounded verification rejected a same-size mutation it does not claim to hash."
    $fullHashRejected = $false
    try { [void](Assert-NikamiOpenMWBoundedInputEvidence -Evidence $evidence @args -VerifyOfficialDataHashes) } `
        catch { $fullHashRejected = $true }
    Assert-Contract $fullHashRejected "Explicit full official-file hash verification missed a same-size mutation."
    Set-Content (Join-Path $resources "version") "changed"
    $rejected = $false
    try { [void](Assert-NikamiOpenMWBoundedInputEvidence -Evidence $evidence @args -VerifyCurrent) } catch { $rejected = $true }
    Assert-Contract $rejected "Changed resource version did not invalidate bounded evidence freshness."
    $evidence.configurationContract.contractSha256 = $null; $rejected = $false
    try { [void](Assert-NikamiOpenMWBoundedInputEvidence -Evidence $evidence @args) } catch { $rejected = $true }
    Assert-Contract $rejected "Missing configuration contract did not fail closed."
}
finally { if (Test-Path $fixture) { Remove-Item $fixture -Recurse -Force } }

$names = @("OPENMW_FNV_PROOF_WEATHER_ID", "OPENMW_FNV_SKY_MESH_SCALE", "OPENMW_FNV_INTERACTION_AUDIT")
$original = @{}; foreach ($name in $names) { $original[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }
try {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, "stale", "Process") }
    $previous = @{}; Clear-NikamiFnvSkyRuntimeEnvironment $previous
    Assert-Contract ($null -eq $env:OPENMW_FNV_PROOF_WEATHER_ID -and $null -eq $env:OPENMW_FNV_SKY_MESH_SCALE) `
        "Sky scrubber retained stale proof/tuning state."
    Assert-Contract ($env:OPENMW_FNV_INTERACTION_AUDIT -eq "stale") "Sky scrubber removed unrelated FNV state."
}
finally { foreach ($entry in $original.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process") } }

if ($failures.Count -ne 0) {
    Write-Host "FNV natural-sky contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "FNV natural-sky contract passed (isolated sky environment, bounded input evidence, natural four-view gate)."
