param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$planPath = Join-Path $repoRoot "catalog\fnv-playability-recovery-plan.json"
$docPath = Join-Path $repoRoot "docs\fnv-playability-recovery-20260807.md"
$auditorPath = Join-Path $PSScriptRoot "Get-FNVPlayabilityRecoveryState.ps1"
$ownershipPath = Join-Path $PSScriptRoot "Test-FNVGameplaySourceOwnership.ps1"
$failures = [Collections.Generic.List[string]]::new()

function Assert-Recovery([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failures.Add($Message) | Out-Null }
}

foreach ($path in @($planPath, $docPath, $auditorPath, $ownershipPath)) {
    Assert-Recovery (Test-Path -LiteralPath $path -PathType Leaf) "Missing recovery artifact: $path"
}

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $auditorPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Recovery ($parseErrors.Count -eq 0) "Recovery provenance auditor does not parse."

$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
Assert-Recovery ([string]$plan.schema -eq "nikami-fnv-playability-recovery/v1") "Unexpected recovery schema."
Assert-Recovery ([string]$plan.timing.policy -eq "observable-state-first-with-minimum-settle") `
    "Recovery timing is not observation-first."
$initialCandidates = @("babcda4f57", "41fc45f2e5", "b1c0b2d841", "5fb9e4e0aa", "483127f6d2", "843e916fb9")
$candidateCommits = @($plan.candidateLadder | ForEach-Object { [string]$_.commit })
Assert-Recovery ($candidateCommits.Count -ge $initialCandidates.Count) `
    "Recovery candidate ladder must retain the six initial commits."
foreach ($commit in $initialCandidates) {
    Assert-Recovery ($candidateCommits -contains $commit) "Recovery candidate ladder lost initial commit: $commit"
}
Assert-Recovery ([int]$plan.sustainedSessionMinutes -ge 20) "Sustained session gate is shorter than 20 minutes."
Assert-Recovery (-not [bool]$plan.captureContract.windowsAppControlAllowed) "Windows app control is allowed."
Assert-Recovery (-not [bool]$plan.captureContract.foregroundInputAllowed) "Foreground input is allowed."
Assert-Recovery (-not [bool]$plan.captureContract.concurrentRetailAndOpenMWAllowed) `
    "Concurrent retail/OpenMW capture is allowed."

$timing = $plan.timing.transitions
Assert-Recovery ([int]$timing.pipBoyRaise.minimumSettleMs -ge 750) "Pip-Boy raise settles too quickly."
Assert-Recovery ([int]$timing.pipBoyLower.minimumSettleMs -ge 750) "Pip-Boy lower settles too quickly."
Assert-Recovery ([int]$timing.drawHolster.minimumSettleMs -ge 750) "Draw/holster settles too quickly."
Assert-Recovery ([int]$timing.cellTransition.timeoutMs -ge 20000) "Cell transition timeout is too short."

$source = Get-Content -LiteralPath $auditorPath -Raw
foreach ($needle in @(
    "readOnly = `$true",
    "Refusing to overwrite recovery state",
    "Get-FileHash -LiteralPath `$binary",
    "forbiddenEnvironment",
    "runtime-manifest.json"
)) {
    Assert-Recovery ($source.Contains($needle)) "Provenance auditor is missing contract text: $needle"
}
Assert-Recovery ($source -notmatch 'Start-Process|SetForegroundWindow|SendInput|AppActivate') `
    "Read-only provenance auditor contains a launch or forbidden app-control path."

$ownershipSource = Get-Content -LiteralPath $ownershipPath -Raw
foreach ($needle in @(
    "Normal GUI is independent of proof environment",
    "Engine has no save-specific production route",
    "Shared bindings have no hard-coded Fallout defaults",
    "ADS FOV is not hard-coded",
    "Pip-Boy screen is not generated in engine code",
    "Pip-Boy controls are not synthesized in engine code",
    "Normal stores contain no synthetic Fallout proof records",
    "Pip-Boy routing names authored menu assets",
    "Summary telemetry does not enable per-frame trace",
    "No frozen Pip-Boy KF time"
)) {
    Assert-Recovery ($ownershipSource.Contains($needle)) "Source ownership audit is missing: $needle"
}
Assert-Recovery ($ownershipSource -notmatch 'Start-Process|SetForegroundWindow|SendInput|AppActivate') `
    "Source ownership audit contains a launch or forbidden app-control path."

if ($failures.Count -gt 0) {
    Write-Host "FNV playability recovery contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "FNV playability recovery contract passed."
