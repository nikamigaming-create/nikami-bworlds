[CmdletBinding()]
param(
    [string]$ControlPlanePath = "catalog/fnv-parity-control-plane.json",
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "FNVParityCoverage.psm1") -Force
$coverage = Get-FNVParityCoverage -ControlPlanePath $ControlPlanePath

if ($AsJson) {
    $coverage | ConvertTo-Json -Depth 10
    exit 0
}

Write-Host ("FNV certified parity: {0:N2}%" -f $coverage.certifiedParityPct)
Write-Host ("Balanced axis progress (diagnostic): {0:N2}%" -f $coverage.balancedAxisProgressPct)
Write-Host ("Known capability cases complete: {0}/{1} ({2:N2}%); open: {3}" -f `
    $coverage.capabilityCases.complete, $coverage.capabilityCases.total, $coverage.capabilityCases.pct, `
    $coverage.capabilityCases.open)
Write-Host ("Capability inventory frozen: {0}" -f $coverage.capabilityInventoryComplete)
Write-Host ("Formal FNV product subsystems: {0}/{1} ({2:N2}%)" -f `
    $coverage.formalFNVProductSubsystems.complete, $coverage.formalFNVProductSubsystems.total, `
    $coverage.formalFNVProductSubsystems.pct)
Write-Host ""
Write-Host "Certified axes:"
foreach ($axis in $coverage.axes) {
    Write-Host (" - {0}: {1:N2}% (cases {2}/{3}; weakest content family {4:N4}%; accepted micro-total {5}/{6}; observed {7})" -f `
        $axis.name, $axis.certifiedAxisPct, $axis.completeCapabilityCases, $axis.totalCapabilityCases, `
        $axis.minimumAcceptedContentFamilyPct, $axis.acceptedContentInstances, $axis.totalContentInstances, `
        $axis.observedContentInstances)
}

Write-Host ""
Write-Host "Known capability maturity:"
foreach ($state in $coverage.maturity) {
    Write-Host (" - {0}: {1}" -f $state.state, $state.count)
}

if (-not $coverage.releaseReady) {
    Write-Host ""
    Write-Host "Release status: NOT READY. Partial or observed slices do not earn certified parity credit."
}
