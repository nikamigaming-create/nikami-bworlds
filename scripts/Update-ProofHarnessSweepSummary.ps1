param(
    [Parameter(Mandatory=$true)]
    [string]$RunDir,
    [string]$ActorVisualReviewPath = "run/audit/actor-visual-review.jsonl"
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

function Read-JsonlRows([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $rows.Add(($line | ConvertFrom-Json)) | Out-Null
    }
    return @($rows.ToArray())
}

$resolvedRunDir = Resolve-RepoRelativePath $RunDir
if (-not (Test-Path -LiteralPath $resolvedRunDir -PathType Container)) {
    throw "Proof harness sweep run directory not found: $RunDir"
}

$jsonPath = Join-Path $resolvedRunDir "proof-harness-sweep.json"
if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
    throw "Proof harness sweep manifest not found: $jsonPath"
}

$summary = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
$actorLedger = Join-Path $resolvedRunDir "actor-runtime-warnings.jsonl"
if (-not (Test-Path -LiteralPath $actorLedger -PathType Leaf)) {
    throw "Actor runtime warning ledger not found: $actorLedger"
}

$rigLedgers = @((Get-ChildItem -LiteralPath $resolvedRunDir -Filter "rig-pose-sanity*.jsonl" -File) |
    ForEach-Object { $_.FullName })
if ($rigLedgers.Count -eq 0) {
    throw "No rig pose sanity ledgers found in $resolvedRunDir"
}

$proofStatusLedger = Join-Path $resolvedRunDir "actor-proof-status.jsonl"
$partTelemetryLedger = Join-Path $resolvedRunDir "actor-part-telemetry.jsonl"
$renderLiveTelemetryLedger = Join-Path $resolvedRunDir "actor-render-live-telemetry.jsonl"
$faceAttachmentTelemetryLedger = Join-Path $resolvedRunDir "actor-face-attachment-telemetry.jsonl"
$basisTelemetryLedger = Join-Path $resolvedRunDir "actor-basis-telemetry.jsonl"
$rootAttachmentTelemetryLedger = Join-Path $resolvedRunDir "actor-root-attachment-telemetry.jsonl"
$weaponMeshTelemetryLedger = Join-Path $resolvedRunDir "actor-weapon-mesh-telemetry.jsonl"
$manifestPaths = @(@((Get-PropertyValue $summary "rows")) | ForEach-Object { [string]$_.manifestPath } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

foreach ($manifestPath in @($manifestPaths)) {
    $contactSheet = Join-Path (Split-Path -Parent $manifestPath) "contact-sheet.png"
    & (Join-Path $PSScriptRoot "New-ScreenshotContactSheet.ps1") -ManifestPath $manifestPath -OutputPath $contactSheet | Out-Null
}

& (Join-Path $PSScriptRoot "Measure-ActorPartTelemetry.ps1") `
    -ManifestPath @($manifestPaths) `
    -OutputPath $partTelemetryLedger

& (Join-Path $PSScriptRoot "Measure-ActorRenderLiveTelemetry.ps1") `
    -ManifestPath @($manifestPaths) `
    -OutputPath $renderLiveTelemetryLedger

& (Join-Path $PSScriptRoot "Measure-ActorFaceAttachmentTelemetry.ps1") `
    -ManifestPath @($manifestPaths) `
    -OutputPath $faceAttachmentTelemetryLedger

& (Join-Path $PSScriptRoot "Measure-ActorBasisTelemetry.ps1") `
    -ManifestPath @($manifestPaths) `
    -OutputPath $basisTelemetryLedger

& (Join-Path $PSScriptRoot "Measure-ActorRootAttachmentTelemetry.ps1") `
    -ManifestPath @($manifestPaths) `
    -OutputPath $rootAttachmentTelemetryLedger

& (Join-Path $PSScriptRoot "Measure-ActorWeaponMeshTelemetry.ps1") `
    -ManifestPath @($manifestPaths) `
    -OutputPath $weaponMeshTelemetryLedger

& (Join-Path $PSScriptRoot "Measure-ActorProofStatus.ps1") `
    -ActorRuntimePath @($actorLedger) `
    -ActorVisualReviewPath $ActorVisualReviewPath `
    -RigPoseSanityPath @($rigLedgers) `
    -ActorPartTelemetryPath @($partTelemetryLedger) `
    -ActorRenderLivePath @($renderLiveTelemetryLedger) `
    -ActorFaceAttachmentPath @($faceAttachmentTelemetryLedger) `
    -ActorBasisTelemetryPath @($basisTelemetryLedger) `
    -ActorRootAttachmentTelemetryPath @($rootAttachmentTelemetryLedger) `
    -ActorWeaponMeshTelemetryPath @($weaponMeshTelemetryLedger) `
    -OutputPath $proofStatusLedger

$proofStatusRows = @(Read-JsonlRows -Path $proofStatusLedger)
$promotable = $false
if ($proofStatusRows.Count -gt 0 -and @($proofStatusRows | Where-Object { [string](Get-PropertyValue $_ "status") -ne "pass" }).Count -eq 0) {
    $promotable = $true
}

if ($null -eq (Get-PropertyValue $summary "measure")) {
    $summary | Add-Member -Force -NotePropertyName measure -NotePropertyValue ([pscustomobject]@{})
}
$summary.measure | Add-Member -Force -NotePropertyName actorProofStatus -NotePropertyValue $proofStatusLedger
$summary.measure | Add-Member -Force -NotePropertyName actorPartTelemetry -NotePropertyValue $partTelemetryLedger
$summary.measure | Add-Member -Force -NotePropertyName actorRenderLiveTelemetry -NotePropertyValue $renderLiveTelemetryLedger
$summary.measure | Add-Member -Force -NotePropertyName actorFaceAttachmentTelemetry -NotePropertyValue $faceAttachmentTelemetryLedger
$summary.measure | Add-Member -Force -NotePropertyName actorBasisTelemetry -NotePropertyValue $basisTelemetryLedger
$summary.measure | Add-Member -Force -NotePropertyName actorRootAttachmentTelemetry -NotePropertyValue $rootAttachmentTelemetryLedger
$summary.measure | Add-Member -Force -NotePropertyName actorWeaponMeshTelemetry -NotePropertyValue $weaponMeshTelemetryLedger
$summary | Add-Member -Force -NotePropertyName actorProofStatus -NotePropertyValue @($proofStatusRows)
$summary | Add-Member -Force -NotePropertyName promotable -NotePropertyValue $promotable
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$markdownPath = Join-Path $resolvedRunDir "summary.md"
$markdown = New-Object System.Collections.Generic.List[string]
$markdown.Add("# Proof Harness Sweep") | Out-Null
$markdown.Add("") | Out-Null
$markdown.Add("Sweep: $([string](Get-PropertyValue $summary "sweep"))") | Out-Null
$markdown.Add("Dry run: $([bool](Get-PropertyValue $summary "dryRun"))") | Out-Null
$markdown.Add("") | Out-Null
$markdown.Add("| World | Slice | Skinning | Status | Manifest |") | Out-Null
$markdown.Add("| --- | --- | --- | --- | --- |") | Out-Null
foreach ($row in @((Get-PropertyValue $summary "rows"))) {
    $markdown.Add("| $($row.worldId) | $($row.startSlice) | $($row.skinningMode) | $($row.status) | $($row.manifestPath) |") | Out-Null
}
$markdown.Add("") | Out-Null
if ($proofStatusRows.Count -gt 0) {
    $markdown.Add("| World | Skinning | Proof | Runtime | Rig Pose | Part Telemetry | Render/Live | Face | Basis | Root | Weapon Mesh | Visual | Failures | Warnings |") | Out-Null
    $markdown.Add("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |") | Out-Null
    foreach ($row in @($proofStatusRows)) {
        $failures = @(Get-TextArray (Get-PropertyValue $row "failureClasses")) -join ","
        $warnings = @(Get-TextArray (Get-PropertyValue $row "warningClasses")) -join ","
        $markdown.Add("| $($row.worldId) | $($row.effectiveSkinningMode) | $($row.status) | $($row.runtimeStatus) | $($row.rigPoseStatus) | $($row.partTelemetryStatus) | $($row.renderLiveStatus) | $($row.faceAttachmentStatus) | $($row.actorBasisStatus) | $($row.rootAttachmentStatus) | $($row.weaponMeshStatus) | $($row.visualReviewStatus) | $failures | $warnings |") | Out-Null
    }
    $markdown.Add("") | Out-Null
}
$markdown.Add("Promotion: $promotable. $([string](Get-PropertyValue $summary "promotionRule"))") | Out-Null
$markdown | Set-Content -LiteralPath $markdownPath -Encoding UTF8

[pscustomobject][ordered]@{
    runDir = $resolvedRunDir
    actorProofStatus = $proofStatusLedger
    actorRootAttachmentTelemetry = $rootAttachmentTelemetryLedger
    actorWeaponMeshTelemetry = $weaponMeshTelemetryLedger
    summary = $markdownPath
    promotable = $promotable
    rows = @($proofStatusRows)
}
