Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$auditPath = Join-Path $PSScriptRoot "Invoke-FNVInteractionAudit.ps1"
$source = Get-Content -LiteralPath $auditPath -Raw

Assert-Contract ($source -match 'OPENMW_DEBUG_LEVEL\s*=\s*"VERBOSE"') `
    "The hidden interaction audit does not expose furniture lifecycle logs."
Assert-Contract ($source -match 'retained active furniture claim package=') `
    "The interaction audit does not require Easy Pete's retained furniture claim."
Assert-Contract ($source -match "CharacterController playing idle for FormId:0x1104c80 group 'chairsit'") `
    "The interaction audit does not require Easy Pete's chairsit replay."
Assert-Contract ($source -match '\$claim\.Index -le \$doorExitActivation\.Index') `
    "The furniture claim is not ordered after the saloon exit activation."
Assert-Contract ($source -match '\$exteriorReturn\.Index -gt \$idle\.Index') `
    "The chairsit replay is not ordered before the exterior-return gate."
Assert-Contract ($source -match '-and \$authoredFogPass -and \$furnitureReloadPass') `
    "Furniture reload is not a mandatory interaction-audit pass gate."
Assert-Contract ($source -match 'furnitureReload\s*=\s*\[ordered\]') `
    "The interaction manifest does not report the furniture reload gate."

Write-Output "FNV furniture reload contract: PASS"
