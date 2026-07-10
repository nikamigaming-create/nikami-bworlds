param(
    [string[]]$Path = @(),
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$PolicyPath = "catalog/screenshot-evidence-policy.json",
    [string]$OutputPath = "run/audit/actor-render-live-telemetry.jsonl",
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

function Convert-ToDoubleOrNull([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $value = 0.0
    if ([double]::TryParse($Text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return $value
    }
    return $null
}

function Convert-ToBool01([string]$Text) {
    return [string]::Equals($Text, "1", [StringComparison]::Ordinal)
}

function Normalize-ActorIdentity([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $text = $Value.Trim()
    while ($text.Length -ge 2 -and $text.StartsWith('"', [StringComparison]::Ordinal) -and $text.EndsWith('"', [StringComparison]::Ordinal)) {
        $text = $text.Substring(1, $text.Length - 2).Trim()
    }
    return $text
}

function Test-IsPlayerIdentity([string]$Value) {
    return [string]::Equals((Normalize-ActorIdentity $Value), "Player", [StringComparison]::OrdinalIgnoreCase)
}

function Get-RenderLiveStats([object[]]$Rows) {
    $sampleRows = @($Rows)
    $rowCount = $sampleRows.Count
    $renderValidCount = @($sampleRows | Where-Object { [bool]$_.renderValid }).Count
    $renderGoodCount = @($sampleRows | Where-Object { [bool]$_.renderGood }).Count
    $renderInvalidCount = @($sampleRows | Where-Object { -not [bool]$_.renderValid }).Count
    $sourceGoodCount = @($sampleRows | Where-Object { [bool]$_.sourceGood }).Count
    $liveValidCount = @($sampleRows | Where-Object { [bool]$_.liveValid }).Count
    $liveGoodCount = @($sampleRows | Where-Object { [bool]$_.liveGood }).Count
    $renderInvalidRatio = if ($rowCount -gt 0) { [Math]::Round(([double]$renderInvalidCount / [double]$rowCount), 4) } else { 0.0 }

    return [pscustomobject][ordered]@{
        rowCount = $rowCount
        renderValidCount = $renderValidCount
        renderGoodCount = $renderGoodCount
        renderInvalidCount = $renderInvalidCount
        renderInvalidRatio = $renderInvalidRatio
        sourceGoodCount = $sourceGoodCount
        liveValidCount = $liveValidCount
        liveGoodCount = $liveGoodCount
    }
}

function Get-RenderLiveClassification($Stats, $Policy) {
    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    $status = "pass"
    $reason = "render-live-telemetry-ok"

    if ([int]$Stats.rowCount -eq 0) {
        $status = "fail"
        $failureClasses.Add("actor-runtime-gap") | Out-Null
        $reason = "no-render-live-telemetry-seen"
    }
    elseif ([int]$Stats.liveValidCount -lt [int]$Policy.minimumGoodLiveRows) {
        $status = "fail"
        $failureClasses.Add("actor-live-skinning-missing") | Out-Null
        $reason = "insufficient-live-current-pose-geometry"
    }
    elseif ([int]$Stats.liveGoodCount -lt [int]$Policy.minimumGoodLiveRows) {
        $status = "fail"
        $failureClasses.Add("actor-live-skinning-detached") | Out-Null
        $reason = "live-current-pose-geometry-not-near-attachment"
    }
    elseif ([double]$Stats.renderInvalidRatio -ge [double]$Policy.renderInvalidFailureRatio) {
        $status = "fail"
        $failureClasses.Add("actor-render-live-split") | Out-Null
        $reason = "live-current-pose-geometry-valid-but-render-geometry-invalid"
    }
    elseif ([double]$Stats.renderInvalidRatio -ge [double]$Policy.renderInvalidWarningRatio) {
        $status = "questionable"
        $warningClasses.Add("actor-render-live-transition") | Out-Null
        $reason = "live-current-pose-geometry-valid-while-render-geometry-transitions-between-invalid-and-valid"
    }
    elseif ([int]$Stats.renderGoodCount -eq 0) {
        $status = "fail"
        $failureClasses.Add("actor-render-gap") | Out-Null
        $reason = "no-good-render-geometry-samples"
    }

    return [pscustomobject][ordered]@{
        status = $status
        reason = $reason
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
    }
}

function Get-Policy {
    $resolvedPolicy = Resolve-RepoRelativePath $PolicyPath
    if (-not (Test-Path -LiteralPath $resolvedPolicy -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            maxGoodDistance = 32.0
            minimumGoodLiveRows = 2
            renderInvalidWarningRatio = 0.25
            renderInvalidFailureRatio = 0.75
        }
    }

    $policy = Get-Content -LiteralPath $resolvedPolicy -Raw | ConvertFrom-Json
    $ledgerPolicy = Get-PropertyValue $policy "actorRenderLiveLedger"
    if ($null -eq $ledgerPolicy) {
        return [pscustomobject][ordered]@{
            maxGoodDistance = 32.0
            minimumGoodLiveRows = 2
            renderInvalidWarningRatio = 0.25
            renderInvalidFailureRatio = 0.75
        }
    }

    $maxGoodDistance = Get-PropertyValue $ledgerPolicy "maxGoodDistance"
    $minimumGoodLiveRows = Get-PropertyValue $ledgerPolicy "minimumGoodLiveRows"
    $renderInvalidFailureRatio = Get-PropertyValue $ledgerPolicy "renderInvalidFailureRatio"
    $renderInvalidWarningRatio = Get-PropertyValue $ledgerPolicy "renderInvalidWarningRatio"
    return [pscustomobject][ordered]@{
        maxGoodDistance = if ($null -ne $maxGoodDistance) { [double]$maxGoodDistance } else { 32.0 }
        minimumGoodLiveRows = if ($null -ne $minimumGoodLiveRows) { [int]$minimumGoodLiveRows } else { 2 }
        renderInvalidWarningRatio = if ($null -ne $renderInvalidWarningRatio) { [double]$renderInvalidWarningRatio } else { 0.25 }
        renderInvalidFailureRatio = if ($null -ne $renderInvalidFailureRatio) { [double]$renderInvalidFailureRatio } else { 0.75 }
    }
}

function Test-GoodDistance($Distance, [double]$MaxDistance) {
    if ($null -eq $Distance) {
        return $false
    }
    $distanceValue = [double]$Distance
    return ($distanceValue -ge 0.0 -and $distanceValue -le $MaxDistance)
}

function Add-RowsFromManifest(
    [string]$ManifestPath,
    [System.Collections.Generic.List[object]]$Rows,
    [bool]$Optional = $false,
    $Policy
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

    Add-RowFromLog -LogPath $resolvedLog -Rows $Rows -Manifest $manifest -ManifestPath $resolvedManifest -Policy $Policy
}

function Add-Sample(
    [System.Collections.Generic.List[object]]$Samples,
    [int]$LineNumber,
    [string]$Kind,
    [string]$Actor,
    [string]$Side,
    [string]$Part,
    [string]$Drawable,
    [bool]$RenderValid,
    $RenderDistance,
    [bool]$SourceValid,
    $SourceDistance,
    [bool]$LiveValid,
    $LiveDistance,
    [bool]$RenderGood,
    [bool]$SourceGood,
    [bool]$LiveGood
) {
    $Samples.Add([pscustomobject][ordered]@{
        line = $LineNumber
        kind = $Kind
        actor = $Actor
        side = $Side
        part = $Part
        drawable = $Drawable
        renderValid = $RenderValid
        renderDistance = $RenderDistance
        renderGood = $RenderGood
        sourceValid = $SourceValid
        sourceDistance = $SourceDistance
        sourceGood = $SourceGood
        liveValid = $LiveValid
        liveDistance = $LiveDistance
        liveGood = $LiveGood
    }) | Out-Null
}

function Add-RowFromLog(
    [string]$LogPath,
    [System.Collections.Generic.List[object]]$Rows,
    $Manifest = $null,
    [string]$ManifestPath = $null,
    $Policy
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

    $actorPattern = "FNV/ESM4 ACTOR HAND GEOMETRY AUDIT (?<actor>.+?) sampleIndex=(?<sampleIndex>\d+) .*?drawable='(?<drawable>[^']*)'.*?side=(?<side>\w+) fnvPartAncestor='(?<part>[^']*)'.*?renderValid=(?<renderValid>[01]).*?renderDistance=(?<renderDistance>[-+0-9.eE]+) sourceValid=(?<sourceValid>[01]).*?sourceDistance=(?<sourceDistance>[-+0-9.eE]+) liveValid=(?<liveValid>[01]).*?liveDistance=(?<liveDistance>[-+0-9.eE]+)"
    $boundsPattern = "FNV/ESM4 HAND GEOMETRY BOUNDS AUDIT (?<actor>.+?) part='(?<part>[^']*)' class=(?<side>\w+) sampleIndex=(?<sampleIndex>\d+) .*?drawable='(?<drawable>[^']*)'.*?renderValid=(?<renderValid>[01]).*?renderPathDistance=(?<renderDistance>[-+0-9.eE]+) sourceValid=(?<sourceValid>[01]).*?sourcePathDistance=(?<sourceDistance>[-+0-9.eE]+) liveValid=(?<liveValid>[01]).*?livePathDistance=(?<liveDistance>[-+0-9.eE]+)"

    $samples = New-Object System.Collections.Generic.List[object]
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $resolvedLog) {
        ++$lineNumber

        $kind = $null
        $match = [regex]::Match($line, $actorPattern)
        if ($match.Success) {
            $kind = "actor-hand-geometry"
        }
        else {
            $match = [regex]::Match($line, $boundsPattern)
            if ($match.Success) {
                $kind = "hand-geometry-bounds"
            }
        }
        if (-not $match.Success) {
            continue
        }

        $renderDistance = Convert-ToDoubleOrNull $match.Groups["renderDistance"].Value
        $sourceDistance = Convert-ToDoubleOrNull $match.Groups["sourceDistance"].Value
        $liveDistance = Convert-ToDoubleOrNull $match.Groups["liveDistance"].Value
        $renderValid = Convert-ToBool01 $match.Groups["renderValid"].Value
        $sourceValid = Convert-ToBool01 $match.Groups["sourceValid"].Value
        $liveValid = Convert-ToBool01 $match.Groups["liveValid"].Value
        $renderGood = ($renderValid -and (Test-GoodDistance $renderDistance $Policy.maxGoodDistance))
        $sourceGood = ($sourceValid -and (Test-GoodDistance $sourceDistance $Policy.maxGoodDistance))
        $liveGood = ($liveValid -and (Test-GoodDistance $liveDistance $Policy.maxGoodDistance))

        Add-Sample `
            -Samples $samples `
            -LineNumber $lineNumber `
            -Kind $kind `
            -Actor ([string]$match.Groups["actor"].Value) `
            -Side ([string]$match.Groups["side"].Value) `
            -Part ([string]$match.Groups["part"].Value) `
            -Drawable ([string]$match.Groups["drawable"].Value) `
            -RenderValid $renderValid `
            -RenderDistance $renderDistance `
            -SourceValid $sourceValid `
            -SourceDistance $sourceDistance `
            -LiveValid $liveValid `
            -LiveDistance $liveDistance `
            -RenderGood $renderGood `
            -SourceGood $sourceGood `
            -LiveGood $liveGood
    }

    $sampleRows = @($samples.ToArray())
    $nonPlayerRows = @($sampleRows | Where-Object { -not (Test-IsPlayerIdentity ([string]$_.actor)) })
    $targetRows = @(if ($nonPlayerRows.Count -gt 0) { @($nonPlayerRows) } else { @($sampleRows) })
    $nonTargetRows = @(if ($nonPlayerRows.Count -gt 0) {
        $sampleRows | Where-Object { Test-IsPlayerIdentity ([string]$_.actor) }
    })

    $allStats = Get-RenderLiveStats -Rows @($sampleRows)
    $targetStats = Get-RenderLiveStats -Rows @($targetRows)
    $nonTargetStats = Get-RenderLiveStats -Rows @($nonTargetRows)
    $classification = Get-RenderLiveClassification -Stats $targetStats -Policy $Policy
    $nonTargetClassification = if ($nonTargetRows.Count -gt 0) {
        Get-RenderLiveClassification -Stats $nonTargetStats -Policy $Policy
    }
    else {
        [pscustomobject][ordered]@{
            status = "none"
            reason = "no-non-target-render-live-rows"
            failureClasses = @()
            warningClasses = @()
        }
    }

    $sampleSummary = @($targetRows | Select-Object -First 12)
    $nonTargetSampleSummary = @($nonTargetRows | Select-Object -First 6)
    $Rows.Add([pscustomobject][ordered]@{
        schemaVersion = 1
        measuredAt = (Get-Date).ToString("o")
        worldId = $worldId
        evidenceKind = "actor-render-live-telemetry"
        status = [string]$classification.status
        failureClasses = @($classification.failureClasses)
        warningClasses = @($classification.warningClasses)
        manifest = Convert-ToForwardSlash $ManifestPath
        log = Convert-ToForwardSlash $resolvedLog
        startCell = $startCell
        startSlice = $startSlice
        reason = [string]$classification.reason
        maxGoodDistance = [double]$Policy.maxGoodDistance
        minimumGoodLiveRows = [int]$Policy.minimumGoodLiveRows
        renderInvalidWarningRatio = [double]$Policy.renderInvalidWarningRatio
        renderInvalidFailureRatio = [double]$Policy.renderInvalidFailureRatio
        rowCount = [int]$targetStats.rowCount
        renderValidCount = [int]$targetStats.renderValidCount
        renderGoodCount = [int]$targetStats.renderGoodCount
        renderInvalidCount = [int]$targetStats.renderInvalidCount
        renderInvalidRatio = [double]$targetStats.renderInvalidRatio
        sourceGoodCount = [int]$targetStats.sourceGoodCount
        liveValidCount = [int]$targetStats.liveValidCount
        liveGoodCount = [int]$targetStats.liveGoodCount
        targetRowCount = [int]$targetStats.rowCount
        targetRenderGoodCount = [int]$targetStats.renderGoodCount
        targetRenderInvalidCount = [int]$targetStats.renderInvalidCount
        targetRenderInvalidRatio = [double]$targetStats.renderInvalidRatio
        targetSourceGoodCount = [int]$targetStats.sourceGoodCount
        targetLiveGoodCount = [int]$targetStats.liveGoodCount
        nonTargetRowCount = [int]$nonTargetStats.rowCount
        nonTargetStatus = [string]$nonTargetClassification.status
        nonTargetReason = [string]$nonTargetClassification.reason
        nonTargetFailureClasses = @($nonTargetClassification.failureClasses)
        nonTargetWarningClasses = @($nonTargetClassification.warningClasses)
        nonTargetRenderGoodCount = [int]$nonTargetStats.renderGoodCount
        nonTargetRenderInvalidCount = [int]$nonTargetStats.renderInvalidCount
        nonTargetRenderInvalidRatio = [double]$nonTargetStats.renderInvalidRatio
        nonTargetSourceGoodCount = [int]$nonTargetStats.sourceGoodCount
        nonTargetLiveGoodCount = [int]$nonTargetStats.liveGoodCount
        allRowCount = [int]$allStats.rowCount
        allRenderGoodCount = [int]$allStats.renderGoodCount
        allRenderInvalidCount = [int]$allStats.renderInvalidCount
        allRenderInvalidRatio = [double]$allStats.renderInvalidRatio
        allSourceGoodCount = [int]$allStats.sourceGoodCount
        allLiveGoodCount = [int]$allStats.liveGoodCount
        samples = @($sampleSummary)
        nonTargetSamples = @($nonTargetSampleSummary)
    }) | Out-Null
}

$policy = Get-Policy
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
            Add-RowsFromManifest -ManifestPath $manifestFile.FullName -Rows $rows -Optional $true -Policy $policy
        }
    }
}

foreach ($manifestPathEntry in @($ManifestPath)) {
    if ([string]::IsNullOrWhiteSpace($manifestPathEntry)) {
        continue
    }
    Add-RowsFromManifest -ManifestPath $manifestPathEntry -Rows $rows -Policy $policy
}

foreach ($inputPath in @($allInputPaths)) {
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        continue
    }
    Add-RowFromLog -LogPath $inputPath -Rows $rows -Policy $policy
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
    Write-Host "No actor render/live telemetry rows found."
}
else {
    @($rows.ToArray()) |
        Select-Object worldId, status, reason, rowCount, renderGoodCount, renderInvalidRatio, sourceGoodCount, liveGoodCount |
        Format-Table -AutoSize
}

if (-not $NoWrite) {
    Write-Host "Wrote actor render/live telemetry ledger: $OutputPath"
}
