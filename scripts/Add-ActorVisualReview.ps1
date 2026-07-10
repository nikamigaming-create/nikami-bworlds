param(
    [Parameter(Mandatory=$true)]
    [string]$ManifestPath,
    [ValidateSet("pass", "questionable", "fail")]
    [string]$Status = "questionable",
    [string[]]$FailureClass = @(),
    [string[]]$WarningClass = @(),
    [string]$Notes = "",
    [string]$ContractPath = "catalog/world-audit-contract.json",
    [string]$OutputPath = "run/audit/actor-visual-review.jsonl",
    [switch]$Append
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Convert-ToForwardSlash([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    return ([System.IO.Path]::GetFullPath($Path) -replace "\\", "/")
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

$resolvedManifest = Resolve-RepoRelativePath $ManifestPath
if (-not (Test-Path -LiteralPath $resolvedManifest)) {
    throw "Manifest not found: $ManifestPath"
}
$resolvedContract = Resolve-RepoRelativePath $ContractPath
if (-not (Test-Path -LiteralPath $resolvedContract)) {
    throw "Audit contract not found: $ContractPath"
}
$contract = Get-Content -LiteralPath $resolvedContract -Raw | ConvertFrom-Json
$knownFailureClasses = @($contract.failureClasses | ForEach-Object { [string]$_ })
$knownWarningClasses = @($contract.warningClasses | ForEach-Object { [string]$_ })
if ($Status -eq "fail" -and @($FailureClass).Count -eq 0) {
    throw "Failing visual review rows must declare at least one failure class."
}
foreach ($class in @($FailureClass)) {
    if ($knownFailureClasses -notcontains [string]$class) {
        throw "Unknown visual review failure class '$class'. Add it to $ContractPath first."
    }
}
foreach ($class in @($WarningClass)) {
    if ($knownWarningClasses -notcontains [string]$class) {
        throw "Unknown visual review warning class '$class'. Add it to $ContractPath first."
    }
}
$manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
$screenshotPath = $null
foreach ($screenshot in @((Get-PropertyValue $manifest "screenshots"))) {
    $path = [string](Get-PropertyValue $screenshot "path")
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $screenshotPath = $path
        break
    }
}

$row = [pscustomobject][ordered]@{
    schemaVersion = 1
    assessedAt = (Get-Date).ToString("o")
    worldId = [string](Get-PropertyValue $manifest "worldId")
    evidenceKind = "actor-visual-review"
    status = $Status
    failureClasses = @($FailureClass)
    warningClasses = @($WarningClass)
    manifest = Convert-ToForwardSlash $resolvedManifest
    log = Convert-ToForwardSlash ([string](Get-PropertyValue $manifest "logPath"))
    image = Convert-ToForwardSlash $screenshotPath
    startCell = [string](Get-PropertyValue $manifest "startCell")
    notes = $Notes
}

$resolvedOutput = Resolve-RepoRelativePath $OutputPath
$outputDir = Split-Path -Parent $resolvedOutput
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}
if (-not $Append -and (Test-Path -LiteralPath $resolvedOutput)) {
    Remove-Item -LiteralPath $resolvedOutput -Force
}
($row | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII

$row | Select-Object worldId, status, @{ Name = "failureClasses"; Expression = { @($_.failureClasses) -join "," } }, image, notes |
    Format-List
Write-Host "Wrote actor visual review ledger: $OutputPath"
