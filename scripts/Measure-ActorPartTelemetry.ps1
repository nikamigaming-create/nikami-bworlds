param(
    [string[]]$Path = @(),
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/actor-part-telemetry.jsonl",
    [switch]$IncludeManifests,
    [switch]$NoWrite
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
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Add-RowsFromManifest(
    [string]$ManifestPath,
    [System.Collections.Generic.List[object]]$Rows,
    [bool]$Optional = $false
) {
    $resolvedManifest = Resolve-RepoRelativePath $ManifestPath
    if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }

    $manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
    $logPath = [string](Get-PropertyValue $manifest "logPath")
    if ([string]::IsNullOrWhiteSpace($logPath)) {
        if ($Optional) { return }
        throw "Manifest has no logPath: $ManifestPath"
    }
    $resolvedLog = Resolve-RepoRelativePath $logPath
    if (-not (Test-Path -LiteralPath $resolvedLog -PathType Leaf)) {
        if ($Optional) { return }
        throw "OpenMW log not found: $logPath"
    }

    Add-RowFromLog -LogPath $resolvedLog -Rows $Rows -Manifest $manifest -ManifestPath $resolvedManifest
}

function Add-RowFromLog(
    [string]$LogPath,
    [System.Collections.Generic.List[object]]$Rows,
    $Manifest = $null,
    [string]$ManifestPath = $null
) {
    $resolvedLog = Resolve-RepoRelativePath $LogPath
    if (-not (Test-Path -LiteralPath $resolvedLog -PathType Leaf)) {
        throw "OpenMW log not found: $LogPath"
    }

    $worldId = $null
    $startCell = $null
    $startSlice = $null
    if ($null -ne $Manifest) {
        $worldId = [string](Get-PropertyValue $Manifest "worldId")
        $startCell = [string](Get-PropertyValue $Manifest "startCell")
        $startSlice = [string](Get-PropertyValue $Manifest "startSlice")
    }

    $constructionAttachmentBounds = 0
    $runtimePart3dSpace = 0
    $runtimeLiveSurfaceFrame = 0
    $runtimePartAttachmentMatrix = 0
    $runtimeHandGeometryBoundsAudit = 0
    $runtimeActorHandGeometryAudit = 0
    $runtimeWeaponIk = 0
    $runtimeFrameRigRefresh = 0
    $runtimeWeaponMeshTelemetry = 0
    $runtimeGateSamples = New-Object System.Collections.Generic.List[string]
    $constructionSamples = New-Object System.Collections.Generic.List[string]

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $resolvedLog) {
        ++$lineNumber
        if ($line -match "FNV/ESM4 diag: attachment bounds ") {
            ++$constructionAttachmentBounds
            if ($constructionSamples.Count -lt 8) {
                $constructionSamples.Add("line ${lineNumber}: $line") | Out-Null
            }
        }
        if ($line -match "gate=runtime-fnv-part-3d-space") {
            ++$runtimePart3dSpace
            if ($runtimeGateSamples.Count -lt 8) {
                $runtimeGateSamples.Add("line ${lineNumber}: runtime-fnv-part-3d-space") | Out-Null
            }
        }
        if ($line -match "gate=runtime-fnv-live-surface-frame") {
            ++$runtimeLiveSurfaceFrame
            if ($runtimeGateSamples.Count -lt 8) {
                $runtimeGateSamples.Add("line ${lineNumber}: runtime-fnv-live-surface-frame") | Out-Null
            }
        }
        if ($line -match "gate=runtime-fnv-part-attachment-matrix") {
            ++$runtimePartAttachmentMatrix
            if ($runtimeGateSamples.Count -lt 8) {
                $runtimeGateSamples.Add("line ${lineNumber}: runtime-fnv-part-attachment-matrix") | Out-Null
            }
        }
        if ($line -match "FNV/ESM4 HAND GEOMETRY BOUNDS AUDIT ") {
            ++$runtimeHandGeometryBoundsAudit
            if ($runtimeGateSamples.Count -lt 8) {
                $runtimeGateSamples.Add("line ${lineNumber}: runtime-fnv-hand-geometry-bounds-audit") | Out-Null
            }
        }
        if ($line -match "FNV/ESM4 ACTOR HAND GEOMETRY AUDIT ") {
            ++$runtimeActorHandGeometryAudit
            if ($runtimeGateSamples.Count -lt 8) {
                $runtimeGateSamples.Add("line ${lineNumber}: runtime-fnv-actor-hand-geometry-audit") | Out-Null
            }
        }
        if ($line -match "gate=runtime-fnv-weapon-ik") {
            ++$runtimeWeaponIk
            if ($runtimeGateSamples.Count -lt 8) {
                $runtimeGateSamples.Add("line ${lineNumber}: runtime-fnv-weapon-ik") | Out-Null
            }
        }
        if ($line -match "gate=runtime-fnv-frame-rig-refresh") {
            ++$runtimeFrameRigRefresh
            if ($runtimeGateSamples.Count -lt 8) {
                $runtimeGateSamples.Add("line ${lineNumber}: runtime-fnv-frame-rig-refresh") | Out-Null
            }
        }
        if ($line -match "World viewer actor weapon mesh ledger:.*phase=runtime.*gate=actor-weapon-mesh-telemetry") {
            ++$runtimeWeaponMeshTelemetry
            if ($runtimeGateSamples.Count -lt 8) {
                $runtimeGateSamples.Add("line ${lineNumber}: actor-weapon-mesh-telemetry") | Out-Null
            }
        }
    }

    $runtimeFrameCount = $runtimePart3dSpace + $runtimeLiveSurfaceFrame + $runtimePartAttachmentMatrix +
        $runtimeHandGeometryBoundsAudit + $runtimeActorHandGeometryAudit + $runtimeWeaponIk +
        $runtimeFrameRigRefresh + $runtimeWeaponMeshTelemetry
    $runtimeFrameLevelCount = $runtimeLiveSurfaceFrame + $runtimePartAttachmentMatrix +
        $runtimeHandGeometryBoundsAudit + $runtimeActorHandGeometryAudit + $runtimeWeaponIk +
        $runtimeFrameRigRefresh + $runtimeWeaponMeshTelemetry
    $status = "pass"
    [string[]]$failureClasses = @()
    [string[]]$warningClasses = @()
    $reason = "runtime-part-telemetry-present"
    if ($runtimeFrameCount -eq 0 -and $constructionAttachmentBounds -gt 0) {
        $status = "fail"
        $failureClasses = @("actor-runtime-gap")
        $reason = "construction-attachment-telemetry-only"
    }
    elseif ($runtimeFrameCount -eq 0) {
        $status = "questionable"
        $warningClasses = @("actor-runtime-gap")
        $reason = "no-part-telemetry-seen"
    }
    elseif ($runtimeFrameLevelCount -eq 0) {
        $status = "questionable"
        $warningClasses = @("actor-runtime-gap")
        $reason = "part-space-without-frame-telemetry"
    }

    $Rows.Add([pscustomobject][ordered]@{
        schemaVersion = 1
        measuredAt = (Get-Date).ToString("o")
        worldId = $worldId
        evidenceKind = "actor-part-telemetry"
        status = $status
        failureClasses = $failureClasses
        warningClasses = $warningClasses
        manifest = Convert-ToForwardSlash $ManifestPath
        log = Convert-ToForwardSlash $resolvedLog
        startCell = $startCell
        startSlice = $startSlice
        reason = $reason
        constructionAttachmentBounds = $constructionAttachmentBounds
        runtimePart3dSpace = $runtimePart3dSpace
        runtimeLiveSurfaceFrame = $runtimeLiveSurfaceFrame
        runtimePartAttachmentMatrix = $runtimePartAttachmentMatrix
        runtimeHandGeometryBoundsAudit = $runtimeHandGeometryBoundsAudit
        runtimeActorHandGeometryAudit = $runtimeActorHandGeometryAudit
        runtimeWeaponIk = $runtimeWeaponIk
        runtimeFrameRigRefresh = $runtimeFrameRigRefresh
        runtimeWeaponMeshTelemetry = $runtimeWeaponMeshTelemetry
        runtimeFrameCount = $runtimeFrameCount
        runtimeFrameLevelCount = $runtimeFrameLevelCount
        runtimeGateSamples = @($runtimeGateSamples.ToArray())
        constructionSamples = @($constructionSamples.ToArray())
    }) | Out-Null
}

$allInputPaths = @($Path)
if ($allInputPaths.Count -eq 0 -and $ManifestPath.Count -eq 0 -and -not $IncludeManifests) {
    $IncludeManifests = $true
}

$rows = New-Object System.Collections.Generic.List[object]
$hasExplicitInput = ($allInputPaths.Count -gt 0 -or @($ManifestPath).Count -gt 0)

if ($IncludeManifests -and -not $hasExplicitInput) {
    $manifestRootPath = Resolve-RepoRelativePath $ManifestRoot
    if (Test-Path -LiteralPath $manifestRootPath) {
        $manifestFiles = Get-ChildItem -LiteralPath $manifestRootPath -Recurse -File -Filter "manifest.json" |
            Sort-Object LastWriteTime
        foreach ($manifestFile in $manifestFiles) {
            Add-RowsFromManifest -ManifestPath $manifestFile.FullName -Rows $rows -Optional $true
        }
    }
}

foreach ($manifestPathEntry in @($ManifestPath)) {
    if ([string]::IsNullOrWhiteSpace($manifestPathEntry)) {
        continue
    }
    Add-RowsFromManifest -ManifestPath $manifestPathEntry -Rows $rows
}

foreach ($inputPath in @($allInputPaths)) {
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        continue
    }
    Add-RowFromLog -LogPath $inputPath -Rows $rows
}

if (-not $NoWrite) {
    $resolvedOutput = Resolve-RepoRelativePath $OutputPath
    $outputDir = Split-Path -Parent $resolvedOutput
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    if (Test-Path -LiteralPath $resolvedOutput) {
        Remove-Item -LiteralPath $resolvedOutput -Force
    }
    New-Item -ItemType File -Path $resolvedOutput -Force | Out-Null
    foreach ($row in @($rows.ToArray())) {
        ($row | ConvertTo-Json -Depth 10 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No actor part telemetry rows found."
}
else {
    @($rows.ToArray()) |
        Select-Object worldId, status, reason, constructionAttachmentBounds, runtimeFrameCount, runtimeFrameLevelCount, runtimePart3dSpace, runtimeLiveSurfaceFrame, runtimePartAttachmentMatrix, runtimeHandGeometryBoundsAudit, runtimeActorHandGeometryAudit, runtimeFrameRigRefresh, runtimeWeaponMeshTelemetry |
        Format-Table -AutoSize
}

if (-not $NoWrite) {
    Write-Host "Wrote actor part telemetry ledger: $OutputPath"
}
