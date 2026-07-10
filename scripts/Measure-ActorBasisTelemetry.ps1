param(
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/actor-basis-telemetry.jsonl",
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
    return ($Path -replace "\\", "/")
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

function Get-TextArray($Value) {
    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    return @($text)
}

function Test-AuditRequested($Manifest) {
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($entry in Get-TextArray (Get-PropertyValue $Manifest "environmentOverrides")) {
        $all.Add($entry) | Out-Null
    }
    foreach ($entry in Get-TextArray (Get-PropertyValue $Manifest "processEnvironment")) {
        $all.Add($entry) | Out-Null
    }
    $policy = Get-PropertyValue $Manifest "actorAnimationPolicy"
    $environment = Get-PropertyValue $policy "environment"
    if ($null -ne $environment) {
        foreach ($property in @($environment.PSObject.Properties)) {
            $all.Add(("{0}={1}" -f $property.Name, $property.Value)) | Out-Null
        }
    }
    foreach ($entry in @($all.ToArray())) {
        if ($entry -match "^(OPENMW_FNV_ACTOR_BASIS_AUDIT|OPENMW_ESM4_ACTOR_BASIS_AUDIT)=" -and $entry -notmatch "=0$") {
            return $true
        }
    }
    return $false
}

function Add-UniqueText([System.Collections.Generic.List[string]]$List, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    if (-not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function Get-ManifestPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($ManifestPath)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        $resolved = Resolve-RepoRelativePath $path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Manifest not found: $path"
        }
        $paths.Add($resolved) | Out-Null
    }
    if ($paths.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($ManifestRoot)) {
        $root = Resolve-RepoRelativePath $ManifestRoot
        if (Test-Path -LiteralPath $root -PathType Container) {
            foreach ($manifest in @(Get-ChildItem -LiteralPath $root -Recurse -Filter "manifest.json" -File)) {
                $paths.Add($manifest.FullName) | Out-Null
            }
        }
    }
    return @($paths.ToArray())
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($manifestPathItem in Get-ManifestPaths) {
    $manifest = Get-Content -LiteralPath $manifestPathItem -Raw | ConvertFrom-Json
    $logPath = [string](Get-PropertyValue $manifest "logPath")
    $auditRequested = Test-AuditRequested $manifest
    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    $callbackAuditCount = 0
    $manualAuditCount = 0
    $largeRotationDeltaCount = 0
    $headNeckLargeRotationDeltaCount = 0
    $maxRotationDeltaDegrees = 0.0
    $maxRotationDeltaBone = ""
    $sampleBones = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($logPath) -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        foreach ($line in Get-Content -LiteralPath $logPath) {
            if ($line -notmatch "FNV/ESM4 ACTOR BASIS") {
                continue
            }
            if ($line -match "ACTOR BASIS CALLBACK AUDIT") {
                ++$callbackAuditCount
            }
            elseif ($line -match "ACTOR BASIS AUDIT") {
                ++$manualAuditCount
            }
            $bone = ""
            if ($line -match "bone=(?<bone>.+?)\s+appliedHasRotation=") {
                $bone = [string]$matches["bone"]
                Add-UniqueText -List $sampleBones -Value $bone
            }
            $rotationDelta = 0.0
            if ($line -match "rotationDeltaDegrees=(?<value>[-+0-9.eE]+)") {
                $rotationDelta = [double]::Parse([string]$matches["value"], [System.Globalization.CultureInfo]::InvariantCulture)
            }
            if ($rotationDelta -gt $maxRotationDeltaDegrees) {
                $maxRotationDeltaDegrees = $rotationDelta
                $maxRotationDeltaBone = $bone
            }
            if ($rotationDelta -ge 45.0) {
                ++$largeRotationDeltaCount
                if ($bone -match "(?i)(neck|head)") {
                    ++$headNeckLargeRotationDeltaCount
                }
            }
        }
    }
    elseif ($auditRequested) {
        Add-UniqueText -List $failureClasses -Value "actor-runtime-gap"
    }

    $basisAuditCount = $callbackAuditCount + $manualAuditCount
    $status = "pass"
    $reason = "actor-basis-audit-not-requested"
    if ($auditRequested -and $basisAuditCount -eq 0) {
        $status = "fail"
        $reason = "actor-basis-audit-requested-but-missing"
        Add-UniqueText -List $failureClasses -Value "actor-runtime-gap"
        Add-UniqueText -List $warningClasses -Value "actor-basis-audit-gap"
    }
    elseif ($basisAuditCount -gt 0 -and $largeRotationDeltaCount -gt 0) {
        $status = "questionable"
        $reason = "actor-basis-large-rotation-delta"
        Add-UniqueText -List $warningClasses -Value "actor-basis-large-delta"
    }
    elseif ($basisAuditCount -gt 0) {
        $reason = "actor-basis-audit-present"
    }

    $rows.Add([pscustomobject][ordered]@{
        schemaVersion = 1
        assessedAt = (Get-Date).ToString("o")
        worldId = [string](Get-PropertyValue $manifest "worldId")
        evidenceKind = "actor-basis-telemetry"
        status = $status
        reason = $reason
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        manifest = Convert-ToForwardSlash $manifestPathItem
        log = Convert-ToForwardSlash $logPath
        startCell = [string](Get-PropertyValue $manifest "startCell")
        auditRequested = $auditRequested
        basisAuditCount = $basisAuditCount
        callbackAuditCount = $callbackAuditCount
        manualAuditCount = $manualAuditCount
        largeRotationDeltaCount = $largeRotationDeltaCount
        headNeckLargeRotationDeltaCount = $headNeckLargeRotationDeltaCount
        maxRotationDeltaDegrees = [Math]::Round($maxRotationDeltaDegrees, 3)
        maxRotationDeltaBone = $maxRotationDeltaBone
        sampledBones = @($sampleBones.ToArray() | Select-Object -First 24)
    }) | Out-Null
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
    foreach ($row in @($rows.ToArray())) {
        ($row | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII
    }
}

@($rows.ToArray()) |
    Select-Object worldId, status, reason, auditRequested, basisAuditCount, callbackAuditCount, largeRotationDeltaCount, headNeckLargeRotationDeltaCount, maxRotationDeltaDegrees, maxRotationDeltaBone, @{ Name = "warningClasses"; Expression = { @($_.warningClasses) -join "," } } |
    Format-Table -Wrap -AutoSize

if (-not $NoWrite) {
    Write-Host "Wrote actor basis telemetry ledger: $OutputPath"
}
