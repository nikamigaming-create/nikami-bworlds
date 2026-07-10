param(
    [string]$RunDir = "",
    [switch]$Latest,
    [switch]$FailedOnly,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-TextArray($Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text)
}

function Convert-ToForwardSlash([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return ($Path -replace "\\", "/")
}

function Select-LatestRunDir {
    $root = Resolve-RepoRelativePath "run/proof-harness-sweeps"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Proof harness sweep root not found: $root"
    }
    $latestDir = Get-ChildItem -LiteralPath $root -Directory |
        Sort-Object Name |
        Select-Object -Last 1
    if ($null -eq $latestDir) {
        throw "No proof harness sweep runs found under $root"
    }
    return $latestDir.FullName
}

if ([string]::IsNullOrWhiteSpace($RunDir) -or $Latest) {
    $RunDir = Select-LatestRunDir
}

$resolvedRunDir = Resolve-RepoRelativePath $RunDir
if (-not (Test-Path -LiteralPath $resolvedRunDir -PathType Container)) {
    throw "Proof harness sweep run directory not found: $RunDir"
}

$proofStatusLedger = Join-Path $resolvedRunDir "actor-proof-status.jsonl"
if (-not (Test-Path -LiteralPath $proofStatusLedger -PathType Leaf)) {
    throw "Actor proof status ledger not found: $proofStatusLedger"
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($line in Get-Content -LiteralPath $proofStatusLedger) {
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }
    $row = $line | ConvertFrom-Json
    $status = [string](Get-PropertyValue $row "proofStatus")
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = [string](Get-PropertyValue $row "status")
    }
    if ($FailedOnly -and [string]::Equals($status, "pass", [StringComparison]::OrdinalIgnoreCase)) {
        continue
    }
    $skinningMode = [string](Get-PropertyValue $row "skinningMode")
    if ([string]::IsNullOrWhiteSpace($skinningMode)) {
        $skinningMode = [string](Get-PropertyValue $row "effectiveSkinningMode")
    }
    $rows.Add([pscustomobject][ordered]@{
        worldId = [string](Get-PropertyValue $row "worldId")
        skinningMode = $skinningMode
        proofStatus = $status
        runtimeStatus = [string](Get-PropertyValue $row "runtimeStatus")
        rigPoseStatus = [string](Get-PropertyValue $row "rigPoseStatus")
        partTelemetryStatus = [string](Get-PropertyValue $row "partTelemetryStatus")
        renderLiveStatus = [string](Get-PropertyValue $row "renderLiveStatus")
        faceAttachmentStatus = [string](Get-PropertyValue $row "faceAttachmentStatus")
        actorBasisStatus = [string](Get-PropertyValue $row "actorBasisStatus")
        rootAttachmentStatus = [string](Get-PropertyValue $row "rootAttachmentStatus")
        visualReviewStatus = [string](Get-PropertyValue $row "visualReviewStatus")
        failureClasses = @(Get-TextArray (Get-PropertyValue $row "failureClasses")) -join ","
        warningClasses = @(Get-TextArray (Get-PropertyValue $row "warningClasses")) -join ","
        manifest = Convert-ToForwardSlash ([string](Get-PropertyValue $row "manifest"))
        image = Convert-ToForwardSlash ([string](Get-PropertyValue $row "image"))
    }) | Out-Null
}

if ($Json) {
    @($rows.ToArray()) | ConvertTo-Json -Depth 8
    return
}

Write-Host "Proof harness sweep: $resolvedRunDir"
$sortedRows = @($rows.ToArray()) | Sort-Object worldId, skinningMode
$sortedRows |
    Format-Table worldId, skinningMode, proofStatus, runtimeStatus, rigPoseStatus, partTelemetryStatus, renderLiveStatus, faceAttachmentStatus, actorBasisStatus, rootAttachmentStatus, visualReviewStatus -AutoSize

$attentionRows = @($sortedRows | Where-Object { -not [string]::Equals([string]$_.proofStatus, "pass", [StringComparison]::OrdinalIgnoreCase) })
if ($attentionRows.Count -gt 0) {
    Write-Host ""
    Write-Host "Rows needing attention:"
    foreach ($row in $attentionRows) {
        Write-Host ("- {0} {1}: failures={2}; warnings={3}" -f $row.worldId, $row.skinningMode, $row.failureClasses, $row.warningClasses)
        Write-Host ("  manifest={0}" -f $row.manifest)
        Write-Host ("  image={0}" -f $row.image)
    }
}
