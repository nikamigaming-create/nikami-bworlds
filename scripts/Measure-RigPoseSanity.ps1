param(
    [string[]]$Path = @(),
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/rig-pose-sanity.jsonl",
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
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Convert-ToDouble([string]$Text) {
    return [double]::Parse($Text, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Convert-Vector3([string]$Text) {
    $parts = @($Text.Split(",") | ForEach-Object { $_.Trim() })
    if ($parts.Count -ne 3) {
        throw "Expected a 3-value vector, got '$Text'"
    }
    return @(
        Convert-ToDouble $parts[0]
        Convert-ToDouble $parts[1]
        Convert-ToDouble $parts[2]
    )
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
        if ($Optional) {
            return
        }
        throw "Manifest has no logPath: $ManifestPath"
    }
    $resolvedLog = Resolve-RepoRelativePath $logPath
    if (-not (Test-Path -LiteralPath $resolvedLog -PathType Leaf)) {
        if ($Optional) {
            return
        }
    }
    Add-RowsFromLog -LogPath $resolvedLog -Rows $Rows -Manifest $manifest -ManifestPath $resolvedManifest
}

function Add-RowsFromLog(
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

    $pattern = "FNV/ESM4 diag: Fallout RigGeometry '([^']+)' pose sanity vertices=(\d+) sourceExtent=\(([^)]*)\) skinnedExtent=\(([^)]*)\) sourceCenter=\(([^)]*)\) skinnedCenter=\(([^)]*)\) sourceDiag=([^\s]+) skinnedDiag=([^\s]+) centerDelta=([^\s]+) extentRatio=([^\s]+) maxVertexDelta=([^\s]+) maxVertex=(\d+) outlierVertices=(\d+) outlierRadius=([^\s]+) verdict=(OK|BAD) reason=([^\s]+)"
    $fallbackPattern = "FNV/ESM4 diag: Fallout RigGeometry '([^']+)' auto skinning fallback=source reason=([^\s]+)"
    $pendingFallbacks = @{}
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $resolvedLog) {
        ++$lineNumber
        $fallbackMatch = [regex]::Match($line, $fallbackPattern)
        if ($fallbackMatch.Success) {
            $pendingFallbacks[$fallbackMatch.Groups[1].Value] = [pscustomobject][ordered]@{
                line = $lineNumber
                reason = $fallbackMatch.Groups[2].Value
            }
            continue
        }

        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) {
            continue
        }

        $rigName = $match.Groups[1].Value
        $sourceDiag = Convert-ToDouble $match.Groups[7].Value
        $skinnedDiag = Convert-ToDouble $match.Groups[8].Value
        $centerDelta = Convert-ToDouble $match.Groups[9].Value
        $extentRatio = Convert-ToDouble $match.Groups[10].Value
        $maxVertexDelta = Convert-ToDouble $match.Groups[11].Value
        $outlierVertices = [int]$match.Groups[13].Value
        $reason = $match.Groups[16].Value
        $lowerRigName = $rigName.ToLowerInvariant()
        $animatedHandBindOffset = $reason -eq "center" `
            -and $lowerRigName.Contains("hand") `
            -and $extentRatio -le 2.25 `
            -and $maxVertexDelta -le [Math]::Max(64.0, $sourceDiag * 3.25) `
            -and $outlierVertices -eq 0
        $animatedHumanLimbPose = $reason -eq "extent" `
            -and $lowerRigName.Contains("arm") `
            -and $centerDelta -le 24.0 `
            -and $maxVertexDelta -le [Math]::Max(96.0, $sourceDiag * 0.8) `
            -and $skinnedDiag -le [Math]::Max(96.0, $sourceDiag * 1.5) `
            -and $outlierVertices -eq 0
        $animatedHumanHeadPose = $reason -eq "extent" `
            -and $lowerRigName.Contains("head") `
            -and $centerDelta -le 12.0 `
            -and $maxVertexDelta -le [Math]::Max(32.0, $sourceDiag * 3.0) `
            -and $skinnedDiag -le [Math]::Max(32.0, $sourceDiag * 4.0) `
            -and $outlierVertices -eq 0
        $animatedCreaturePose = $reason -eq "extent" `
            -and ($lowerRigName.Contains("crow") -or $lowerRigName.Contains("bighorner") -or $lowerRigName.Contains("brahmin")) `
            -and $centerDelta -le [Math]::Max(16.0, $sourceDiag * 0.25) `
            -and $maxVertexDelta -le [Math]::Max(96.0, $sourceDiag * 0.75) `
            -and $skinnedDiag -le [Math]::Max(96.0, $sourceDiag * 1.5) `
            -and $outlierVertices -eq 0
        $fallback = $null
        if ($pendingFallbacks.ContainsKey($rigName)) {
            $fallback = $pendingFallbacks[$rigName]
            $pendingFallbacks.Remove($rigName)
        }
        $verdict = $match.Groups[15].Value
        $poseAccepted = $animatedHandBindOffset -or $animatedHumanLimbPose -or $animatedHumanHeadPose -or $animatedCreaturePose
        $status = if ($verdict -eq "OK" -or $poseAccepted) { "pass" } elseif ($null -ne $fallback) { "questionable" } else { "fail" }
        [string[]]$failureClasses = @()
        if ($status -eq "fail") {
            $failureClasses = @("actor-pose-invalid")
        }
        [string[]]$warningClasses = @()
        if ($status -eq "questionable") {
            $warningClasses = @("actor-runtime-gap")
        }
        $row = [pscustomobject][ordered]@{
            schemaVersion = 1
            measuredAt = (Get-Date).ToString("o")
            worldId = $worldId
            evidenceKind = "rig-pose-sanity"
            status = $status
            failureClasses = $failureClasses
            warningClasses = $warningClasses
            manifest = Convert-ToForwardSlash $ManifestPath
            log = Convert-ToForwardSlash $resolvedLog
            logLine = $lineNumber
            startCell = $startCell
            startSlice = $startSlice
            rigName = $rigName
            vertices = [int]$match.Groups[2].Value
            sourceExtent = Convert-Vector3 $match.Groups[3].Value
            skinnedExtent = Convert-Vector3 $match.Groups[4].Value
            sourceCenter = Convert-Vector3 $match.Groups[5].Value
            skinnedCenter = Convert-Vector3 $match.Groups[6].Value
            sourceDiag = $sourceDiag
            skinnedDiag = $skinnedDiag
            centerDelta = $centerDelta
            extentRatio = $extentRatio
            maxVertexDelta = $maxVertexDelta
            maxVertex = [int]$match.Groups[12].Value
            outlierVertices = $outlierVertices
            outlierRadius = Convert-ToDouble $match.Groups[14].Value
            verdict = $verdict
            reason = $reason
            poseClassification = if ($animatedHandBindOffset) {
                "animated-hand-bind-offset"
            } elseif ($animatedHumanLimbPose) {
                "animated-human-limb-pose"
            } elseif ($animatedHumanHeadPose) {
                "animated-human-head-pose"
            } elseif ($animatedCreaturePose) {
                "animated-creature-pose"
            } else {
                "source-relative-pose-sanity"
            }
            autoFallbackSource = $null -ne $fallback
            autoFallbackReason = if ($null -ne $fallback) { [string]$fallback.reason } else { $null }
            autoFallbackLogLine = if ($null -ne $fallback) { [int]$fallback.line } else { $null }
        }
        $Rows.Add($row) | Out-Null
    }
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
    Add-RowsFromLog -LogPath $inputPath -Rows $rows
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
        ($row | ConvertTo-Json -Depth 12 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No rig pose sanity rows found."
}
else {
    @($rows.ToArray()) |
        Select-Object worldId, status, rigName, reason, centerDelta, extentRatio, maxVertexDelta, logLine |
        Format-Table -AutoSize
}

if (-not $NoWrite) {
    Write-Host "Wrote rig pose sanity ledger: $OutputPath"
}
