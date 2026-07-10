param(
    [string[]]$Path = @(),
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/actor-face-attachment-telemetry.jsonl",
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

function Convert-ToBool01([string]$Text) {
    return [string]::Equals($Text, "1", [StringComparison]::Ordinal)
}

function Convert-ToIntOrZero([string]$Text) {
    $value = 0
    if ([int]::TryParse($Text, [ref]$value)) {
        return $value
    }
    return 0
}

function Test-IsHeadModel([string]$Model) {
    return $Model -match "(?i)(^|[/\\])headhuman\.nif$|(^|[/\\])headmale|(^|[/\\])headfemale"
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

    $attachmentPattern = "FNV/ESM4 diag: attachment bounds (?<model>\S+) for (?<actor>.+?) parent=(?<parent>.+?) center=.*?headRelative=(?<headRelative>[01]) faceTight=(?<faceTight>[01]) faceAxisChecked=(?<faceAxisChecked>[01]) faceAxisReason=(?<faceAxisReason>\S+) verdict=(?<verdict>\S+)"
    $faceDrawablePattern = "FNV/ESM4 FACE DRAWABLE AUDIT (?<actor>.+?) model=(?<model>.+?) phase=(?<phase>\S+) drawable='(?<drawable>[^']*)' kind=(?<kind>\S+) .*?drawableVertices=(?<drawableVertices>\d+) sourceName='(?<sourceName>[^']*)' sourceVertices=(?<sourceVertices>\d+) .*?renderName='(?<renderName>[^']*)' renderVertices=(?<renderVertices>\d+) .*?renderValid=(?<renderValid>[01]).*?sourceValid=(?<sourceValid>[01])"
    $faceCheckPattern = "FNV/ESM4 FACE CHECK (?<actor>[^:]+): (?<status>.+)$"

    $attachmentRows = New-Object System.Collections.Generic.List[object]
    $drawableRows = New-Object System.Collections.Generic.List[object]
    $faceCheckRows = New-Object System.Collections.Generic.List[object]
    $samples = New-Object System.Collections.Generic.List[object]

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $resolvedLog) {
        ++$lineNumber

        $attachmentMatch = [regex]::Match($line, $attachmentPattern)
        if ($attachmentMatch.Success) {
            $verdict = [string]$attachmentMatch.Groups["verdict"].Value
            $entry = [pscustomobject][ordered]@{
                line = $lineNumber
                actor = [string]$attachmentMatch.Groups["actor"].Value
                model = [string]$attachmentMatch.Groups["model"].Value
                parent = [string]$attachmentMatch.Groups["parent"].Value
                headRelative = Convert-ToBool01 $attachmentMatch.Groups["headRelative"].Value
                faceTight = Convert-ToBool01 $attachmentMatch.Groups["faceTight"].Value
                faceAxisChecked = Convert-ToBool01 $attachmentMatch.Groups["faceAxisChecked"].Value
                faceAxisReason = [string]$attachmentMatch.Groups["faceAxisReason"].Value
                verdict = $verdict
                headModel = Test-IsHeadModel ([string]$attachmentMatch.Groups["model"].Value)
            }
            $attachmentRows.Add($entry) | Out-Null
            if ($samples.Count -lt 10 -and ($entry.headModel -or $entry.faceTight -or $verdict -ne "OK")) {
                $samples.Add($entry) | Out-Null
            }
            continue
        }

        $drawableMatch = [regex]::Match($line, $faceDrawablePattern)
        if ($drawableMatch.Success) {
            $model = [string]$drawableMatch.Groups["model"].Value
            $renderValid = Convert-ToBool01 $drawableMatch.Groups["renderValid"].Value
            $sourceValid = Convert-ToBool01 $drawableMatch.Groups["sourceValid"].Value
            $renderVertices = Convert-ToIntOrZero $drawableMatch.Groups["renderVertices"].Value
            $sourceVertices = Convert-ToIntOrZero $drawableMatch.Groups["sourceVertices"].Value
            $headModel = Test-IsHeadModel $model
            $renderSource = ""
            if ($line -match "\brenderSource=(?<renderSource>\S+)") {
                $renderSource = [string]$Matches["renderSource"]
            }
            $renderInspectable = -not [string]::IsNullOrWhiteSpace($renderSource) -and
                $renderSource -notmatch "(?i)^(missing|none|null)"
            $riggedHeadRenderGap = $headModel -and $sourceValid -and $sourceVertices -gt 0 -and
                (-not $renderValid -or $renderVertices -eq 0)
            $entry = [pscustomobject][ordered]@{
                line = $lineNumber
                actor = [string]$drawableMatch.Groups["actor"].Value
                model = $model
                phase = [string]$drawableMatch.Groups["phase"].Value
                drawable = [string]$drawableMatch.Groups["drawable"].Value
                kind = [string]$drawableMatch.Groups["kind"].Value
                drawableVertices = Convert-ToIntOrZero $drawableMatch.Groups["drawableVertices"].Value
                sourceName = [string]$drawableMatch.Groups["sourceName"].Value
                sourceVertices = $sourceVertices
                renderSource = $renderSource
                renderInspectable = $renderInspectable
                renderName = [string]$drawableMatch.Groups["renderName"].Value
                renderVertices = $renderVertices
                renderValid = $renderValid
                sourceValid = $sourceValid
                headModel = $headModel
                riggedHeadRenderGap = $riggedHeadRenderGap
            }
            $drawableRows.Add($entry) | Out-Null
            if ($samples.Count -lt 10 -and ($entry.headModel -or $entry.riggedHeadRenderGap)) {
                $samples.Add($entry) | Out-Null
            }
            continue
        }

        $faceCheckMatch = [regex]::Match($line, $faceCheckPattern)
        if ($faceCheckMatch.Success) {
            $statusText = [string]$faceCheckMatch.Groups["status"].Value
            $badFaceCheck = $statusText -match "(?i)\b(MISSING|EMPTY|BAD|FAILED|SUSPECT)\b"
            $entry = [pscustomobject][ordered]@{
                line = $lineNumber
                actor = [string]$faceCheckMatch.Groups["actor"].Value
                statusText = $statusText
                badFaceCheck = $badFaceCheck
            }
            $faceCheckRows.Add($entry) | Out-Null
            if ($samples.Count -lt 10 -and $badFaceCheck) {
                $samples.Add($entry) | Out-Null
            }
        }
    }

    $attachmentSamples = @($attachmentRows.ToArray())
    $drawableSamples = @($drawableRows.ToArray())
    $faceChecks = @($faceCheckRows.ToArray())
    $headDrawableRows = @($drawableSamples | Where-Object { [bool]$_.headModel })
    $riggedHeadRenderGapRows = @($drawableSamples | Where-Object { [bool]$_.riggedHeadRenderGap })
    $headRigRenderInspectableRows = @($headDrawableRows | Where-Object {
        [bool]$_.renderInspectable -and [bool]$_.renderValid -and [int]$_.renderVertices -gt 0
    })
    $faceDrawableRenderGapRows = @($drawableSamples | Where-Object {
        -not [bool]$_.renderValid -and [int]$_.sourceVertices -gt 0
    })
    $suspectAttachmentRows = @($attachmentSamples | Where-Object {
        -not [string]::Equals([string]$_.verdict, "OK", [StringComparison]::OrdinalIgnoreCase)
    })
    $badFaceCheckRows = @($faceChecks | Where-Object { [bool]$_.badFaceCheck })

    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    $status = "pass"
    $reason = "face-attachment-telemetry-present"

    if ($drawableSamples.Count -eq 0 -and $attachmentSamples.Count -eq 0 -and $faceChecks.Count -eq 0) {
        $status = "questionable"
        $warningClasses.Add("actor-runtime-gap") | Out-Null
        $reason = "no-face-attachment-telemetry-seen"
    }
    elseif ($riggedHeadRenderGapRows.Count -gt 0) {
        $status = "fail"
        $failureClasses.Add("actor-head-render-gap") | Out-Null
        $reason = "rigged-head-source-geometry-present-but-render-geometry-missing"
    }
    elseif ($suspectAttachmentRows.Count -gt 0 -or $badFaceCheckRows.Count -gt 0) {
        $status = "fail"
        $failureClasses.Add("actor-part-missing") | Out-Null
        $reason = "face-attachment-or-face-check-failed"
    }
    elseif ($faceDrawableRenderGapRows.Count -gt 0) {
        $status = "questionable"
        $warningClasses.Add("actor-render-gap") | Out-Null
        $reason = "face-drawable-source-geometry-present-but-render-geometry-missing"
    }

    $Rows.Add([pscustomobject][ordered]@{
        schemaVersion = 1
        measuredAt = (Get-Date).ToString("o")
        worldId = $worldId
        evidenceKind = "actor-face-attachment-telemetry"
        status = $status
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        manifest = Convert-ToForwardSlash $ManifestPath
        log = Convert-ToForwardSlash $resolvedLog
        startCell = $startCell
        startSlice = $startSlice
        reason = $reason
        attachmentBoundsCount = $attachmentSamples.Count
        suspectAttachmentBoundsCount = $suspectAttachmentRows.Count
        faceDrawableAuditCount = $drawableSamples.Count
        headDrawableAuditCount = $headDrawableRows.Count
        headRigRenderInspectableCount = $headRigRenderInspectableRows.Count
        riggedHeadRenderGapCount = $riggedHeadRenderGapRows.Count
        faceDrawableRenderGapCount = $faceDrawableRenderGapRows.Count
        faceCheckCount = $faceChecks.Count
        badFaceCheckCount = $badFaceCheckRows.Count
        samples = @($samples.ToArray())
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
        ($row | ConvertTo-Json -Depth 12 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No actor face attachment telemetry rows found."
}
else {
    @($rows.ToArray()) |
        Select-Object worldId, status, reason, attachmentBoundsCount, faceDrawableAuditCount, headDrawableAuditCount, riggedHeadRenderGapCount, faceCheckCount |
        Format-Table -AutoSize
}

if (-not $NoWrite) {
    Write-Host "Wrote actor face attachment telemetry ledger: $OutputPath"
}
