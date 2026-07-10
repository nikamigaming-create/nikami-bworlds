param(
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/actor-root-attachment-telemetry.jsonl",
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

function Add-UniqueText([System.Collections.Generic.List[string]]$List, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    if (-not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function ConvertTo-Vector($Matches, [string]$Prefix) {
    return [pscustomobject][ordered]@{
        x = [double]::Parse([string]$Matches["${Prefix}x"], [System.Globalization.CultureInfo]::InvariantCulture)
        y = [double]::Parse([string]$Matches["${Prefix}y"], [System.Globalization.CultureInfo]::InvariantCulture)
        z = [double]::Parse([string]$Matches["${Prefix}z"], [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

function Select-VectorFromLine([string]$Line, [string]$Name, [string]$Prefix) {
    $pattern = [string]::Format($script:VectorPattern, $Prefix)
    $match = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "\s*=\s*" + $pattern)
    if (-not $match.Success) {
        return $null
    }
    return ConvertTo-Vector $match.Groups $Prefix
}

function Test-AuditRequested($Manifest) {
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($entry in Get-TextArray (Get-PropertyValue $Manifest "environmentOverrides")) {
        $entries.Add($entry) | Out-Null
    }
    foreach ($entry in Get-TextArray (Get-PropertyValue $Manifest "processEnvironment")) {
        $entries.Add($entry) | Out-Null
    }
    foreach ($entry in @($entries.ToArray())) {
        if ($entry -match "^(OPENMW_FNV_ROOT_ATTACHMENT_AUDIT|OPENMW_ESM4_ROOT_ATTACHMENT_AUDIT)=" -and $entry -notmatch "=0$") {
            return $true
        }
    }
    return $false
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

$script:VectorPattern = "\(\s*(?<{0}x>[-+0-9.eE]+)\s*,\s*(?<{0}y>[-+0-9.eE]+)\s*,\s*(?<{0}z>[-+0-9.eE]+)\s*\)"
$rows = New-Object System.Collections.Generic.List[object]
foreach ($manifestPathItem in Get-ManifestPaths) {
    $manifest = Get-Content -LiteralPath $manifestPathItem -Raw | ConvertFrom-Json
    $logPath = [string](Get-PropertyValue $manifest "logPath")
    $auditRequested = Test-AuditRequested $manifest
    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    $auditRows = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace($logPath) -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        foreach ($line in Get-Content -LiteralPath $logPath) {
            if ($line -notmatch "FNV/ESM4 ACTOR ROOT ATTACHMENT AUDIT") {
                continue
            }
            $head = Select-VectorFromLine -Line $line -Name "head" -Prefix "head"
            $pelvis = Select-VectorFromLine -Line $line -Name "pelvis" -Prefix "pelvis"
            $headMinus = Select-VectorFromLine -Line $line -Name "headMinusPelvis" -Prefix "headMinus"
            $footMinus = Select-VectorFromLine -Line $line -Name "footMidMinusPelvis" -Prefix "footMinus"
            $rootBasisZ = Select-VectorFromLine -Line $line -Name "rootBasisZ" -Prefix "rootBasisZ"
            $bip01BasisZ = Select-VectorFromLine -Line $line -Name "bip01BasisZ" -Prefix "bip01BasisZ"
            $handednessMatch = [regex]::Match($line, "rootHandedness\s*=\s*(?<handedness>[-+0-9.eE]+)")
            if ($null -ne $head -and $null -ne $pelvis -and $null -ne $headMinus -and $null -ne $footMinus -and $handednessMatch.Success) {
                $auditRows.Add([pscustomobject][ordered]@{
                    head = $head
                    pelvis = $pelvis
                    headMinusPelvis = $headMinus
                    footMidMinusPelvis = $footMinus
                    rootBasisZ = $rootBasisZ
                    bip01BasisZ = $bip01BasisZ
                    rootHandedness = [double]::Parse([string]$handednessMatch.Groups["handedness"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
                }) | Out-Null
            }
        }
    }
    elseif ($auditRequested) {
        Add-UniqueText -List $failureClasses -Value "actor-runtime-gap"
    }

    $rootAuditCount = $auditRows.Count
    $headBelowPelvisCount = @($auditRows.ToArray() | Where-Object { $_.headMinusPelvis.z -le 0 }).Count
    $feetAbovePelvisCount = @($auditRows.ToArray() | Where-Object { $_.footMidMinusPelvis.z -ge 0 }).Count
    $negativeHandednessCount = @($auditRows.ToArray() | Where-Object { $_.rootHandedness -lt 0 }).Count
    $averageHeadMinusPelvisZ = $null
    $averageFootMidMinusPelvisZ = $null
    if ($rootAuditCount -gt 0) {
        $averageHeadMinusPelvisZ = [Math]::Round((@($auditRows.ToArray()) | ForEach-Object { $_.headMinusPelvis.z } | Measure-Object -Average).Average, 3)
        $averageFootMidMinusPelvisZ = [Math]::Round((@($auditRows.ToArray()) | ForEach-Object { $_.footMidMinusPelvis.z } | Measure-Object -Average).Average, 3)
    }

    $status = "pass"
    $reason = "actor-root-attachment-audit-not-requested"
    if ($auditRequested -and $rootAuditCount -eq 0) {
        $status = "fail"
        $reason = "actor-root-attachment-audit-requested-but-missing"
        Add-UniqueText -List $failureClasses -Value "actor-runtime-gap"
        Add-UniqueText -List $warningClasses -Value "actor-root-attachment-audit-gap"
    }
    elseif ($rootAuditCount -gt 0 -and ($headBelowPelvisCount -gt 0 -or $feetAbovePelvisCount -gt 0 -or $negativeHandednessCount -gt 0)) {
        $status = "questionable"
        $reason = "actor-root-orientation-questionable"
        Add-UniqueText -List $warningClasses -Value "actor-root-orientation-gap"
    }
    elseif ($rootAuditCount -gt 0) {
        $reason = "actor-root-attachment-audit-present"
    }

    $rows.Add([pscustomobject][ordered]@{
        schemaVersion = 1
        assessedAt = (Get-Date).ToString("o")
        worldId = [string](Get-PropertyValue $manifest "worldId")
        evidenceKind = "actor-root-attachment-telemetry"
        status = $status
        reason = $reason
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        manifest = Convert-ToForwardSlash $manifestPathItem
        log = Convert-ToForwardSlash $logPath
        startCell = [string](Get-PropertyValue $manifest "startCell")
        auditRequested = $auditRequested
        rootAuditCount = $rootAuditCount
        headBelowPelvisCount = $headBelowPelvisCount
        feetAbovePelvisCount = $feetAbovePelvisCount
        negativeHandednessCount = $negativeHandednessCount
        averageHeadMinusPelvisZ = $averageHeadMinusPelvisZ
        averageFootMidMinusPelvisZ = $averageFootMidMinusPelvisZ
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
    Select-Object worldId, status, reason, auditRequested, rootAuditCount, headBelowPelvisCount, feetAbovePelvisCount, negativeHandednessCount, averageHeadMinusPelvisZ, averageFootMidMinusPelvisZ, @{ Name = "warningClasses"; Expression = { @($_.warningClasses) -join "," } } |
    Format-Table -Wrap -AutoSize

if (-not $NoWrite) {
    Write-Host "Wrote actor root attachment telemetry ledger: $OutputPath"
}
