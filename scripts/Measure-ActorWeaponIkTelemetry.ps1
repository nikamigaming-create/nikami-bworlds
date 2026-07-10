param(
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/actor-weapon-ik-telemetry.jsonl",
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

function Select-TextValue([string]$Line, [string]$Name) {
    $quoted = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "=""(?<value>[^""]*)""")
    if ($quoted.Success) { return $quoted.Groups["value"].Value }
    $plain = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "=(?<value>\S+)")
    if ($plain.Success) { return $plain.Groups["value"].Value }
    return $null
}

function Select-NumberValue([string]$Line, [string]$Name) {
    $text = Select-TextValue -Line $Line -Name $Name
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $value = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return [Math]::Round($value, 4)
    }
    return $null
}

function Select-BoolValue([string]$Line, [string]$Name) {
    $text = Select-TextValue -Line $Line -Name $Name
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    if ($text -eq "1" -or $text -eq "true" -or $text -eq "True") { return $true }
    if ($text -eq "0" -or $text -eq "false" -or $text -eq "False") { return $false }
    return $null
}

function Select-NumberPair([string]$Line, [string]$Name) {
    $match = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "=\(\s*(?<a>[-+0-9.eE]+)\s*,\s*(?<b>[-+0-9.eE]+)\s*\)")
    if (-not $match.Success) { return $null }
    return [pscustomobject][ordered]@{
        x = [Math]::Round(([double]::Parse($match.Groups["a"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
        y = [Math]::Round(([double]::Parse($match.Groups["b"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
    }
}

function Select-NumberQuad([string]$Line, [string]$Name) {
    $match = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "=\(\s*(?<a>[-+0-9.eE]+)\s*,\s*(?<b>[-+0-9.eE]+)\s*,\s*(?<c>[-+0-9.eE]+)\s*,\s*(?<d>[-+0-9.eE]+)\s*\)")
    if (-not $match.Success) { return $null }
    return [pscustomobject][ordered]@{
        rightForward = [Math]::Round(([double]::Parse($match.Groups["a"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
        rightPalm = [Math]::Round(([double]::Parse($match.Groups["b"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
        leftForward = [Math]::Round(([double]::Parse($match.Groups["c"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
        leftPalm = [Math]::Round(([double]::Parse($match.Groups["d"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
    }
}

function Select-Vector3([string]$Line, [string]$Name) {
    $match = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "=\(\s*(?<x>[-+0-9.eE]+)\s*,\s*(?<y>[-+0-9.eE]+)\s*,\s*(?<z>[-+0-9.eE]+)\s*\)")
    if (-not $match.Success) { return $null }
    return [pscustomobject][ordered]@{
        x = [Math]::Round(([double]::Parse($match.Groups["x"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
        y = [Math]::Round(([double]::Parse($match.Groups["y"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
        z = [Math]::Round(([double]::Parse($match.Groups["z"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
    }
}

function Add-UniqueText([System.Collections.Generic.List[string]]$List, [string]$Value) {
    if (-not [string]::IsNullOrWhiteSpace($Value) -and -not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function New-WeaponIkRow([string]$Line, [int]$LineNumber, $Manifest, [string]$ManifestPath, [string]$LogPath) {
    $actorMatch = [regex]::Match($Line, "actor=(?<actor>.+?)\s+ref=")
    if (-not $actorMatch.Success) { return $null }

    $targetDistancesAfter = Select-NumberPair -Line $Line -Name "targetDistancesAfter"
    $gripDistancesAfter = Select-NumberPair -Line $Line -Name "weaponGripDistancesAfter"
    $fabrikErrors = Select-NumberPair -Line $Line -Name "fabrikErrors"
    $handForwardAngles = Select-NumberPair -Line $Line -Name "handForwardAngles"
    $handOrientationCandidates = Select-TextValue -Line $Line -Name "handOrientationCandidates"
    $handOrientationErrors = Select-NumberQuad -Line $Line -Name "handOrientationErrors"
    $reachable = Select-NumberPair -Line $Line -Name "reachable"
    $runtime = Select-TextValue -Line $Line -Name "runtime"
    $handsUncrossed = Select-BoolValue -Line $Line -Name "handsUncrossed"
    $weaponAimAfter = Select-NumberValue -Line $Line -Name "weaponAimAngleAfter"
    $weaponGripSpanAfter = Select-NumberValue -Line $Line -Name "weaponGripSpanAfter"

    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]

    if ($runtime -eq "loaded-pending-runtime") {
        Add-UniqueText $warningClasses "weapon-ik-runtime-pending"
    }
    elseif (-not [string]::Equals($runtime, "runtime-supported", [StringComparison]::OrdinalIgnoreCase)) {
        Add-UniqueText $warningClasses "weapon-ik-runtime-unknown"
    }

    if ($null -ne $handsUncrossed -and -not $handsUncrossed) {
        Add-UniqueText $failureClasses "weapon-ik-hands-crossed"
    }
    if ($null -ne $weaponAimAfter -and $weaponAimAfter -gt 12.0) {
        Add-UniqueText $failureClasses "weapon-ik-aim-error"
    }
    if ($null -ne $targetDistancesAfter -and ($targetDistancesAfter.x -gt 16.0 -or $targetDistancesAfter.y -gt 16.0)) {
        Add-UniqueText $failureClasses "weapon-ik-target-error"
    }
    if ($null -ne $fabrikErrors -and ($fabrikErrors.x -gt 16.0 -or $fabrikErrors.y -gt 16.0)) {
        Add-UniqueText $failureClasses "weapon-ik-fabrik-error"
    }
    if ($null -ne $gripDistancesAfter) {
        if ($gripDistancesAfter.x -gt 2.75 -or $gripDistancesAfter.y -lt 7.0 -or $gripDistancesAfter.y -gt 34.0) {
            Add-UniqueText $failureClasses "weapon-ik-grip-distance"
        }
    }
    if ($null -ne $weaponGripSpanAfter -and ($weaponGripSpanAfter -lt 7.0 -or $weaponGripSpanAfter -gt 34.0)) {
        Add-UniqueText $failureClasses "weapon-ik-grip-span"
    }
    if ($null -ne $reachable -and ($reachable.x -eq 0.0 -or $reachable.y -eq 0.0)) {
        Add-UniqueText $warningClasses "weapon-ik-target-unreachable"
    }

    $usesExplicitHandOrientation = $false
    if (-not [string]::IsNullOrWhiteSpace($handOrientationCandidates)) {
        $usesExplicitHandOrientation = $handOrientationCandidates -notmatch "preserve-bind-roll"
    }
    if ($usesExplicitHandOrientation -and $null -ne $handOrientationErrors) {
        $maxForwardError = @($handOrientationErrors.rightForward, $handOrientationErrors.leftForward) | Measure-Object -Maximum
        $maxPalmError = @($handOrientationErrors.rightPalm, $handOrientationErrors.leftPalm) | Measure-Object -Maximum
        if ($maxForwardError.Maximum -gt 75.0 -or $maxPalmError.Maximum -gt 55.0) {
            Add-UniqueText $warningClasses "weapon-ik-hand-orientation-error"
        }
    }
    elseif ($null -ne $handForwardAngles -and ($handForwardAngles.x -gt 135.0 -or $handForwardAngles.y -gt 135.0)) {
        Add-UniqueText $warningClasses "weapon-ik-hand-axis-twist"
    }

    $status = "pass"
    if ($failureClasses.Count -gt 0) {
        $status = "fail"
    }
    elseif ($warningClasses.Count -gt 0) {
        $status = "questionable"
    }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        measuredAt = (Get-Date).ToString("o")
        worldId = [string](Get-PropertyValue $Manifest "worldId")
        evidenceKind = "actor-weapon-ik-telemetry"
        status = $status
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        manifest = Convert-ToForwardSlash $ManifestPath
        log = Convert-ToForwardSlash $LogPath
        startCell = [string](Get-PropertyValue $Manifest "startCell")
        startSlice = [string](Get-PropertyValue $Manifest "startSlice")
        line = $LineNumber
        actor = $actorMatch.Groups["actor"].Value.Trim()
        ref = Select-TextValue -Line $Line -Name "ref"
        sample = Select-NumberValue -Line $Line -Name "sample"
        weapon = Select-TextValue -Line $Line -Name "weapon"
        targetStyle = Select-TextValue -Line $Line -Name "targetStyle"
        runtime = $runtime
        rightTarget = Select-Vector3 -Line $Line -Name "rightTarget"
        leftTarget = Select-Vector3 -Line $Line -Name "leftTarget"
        weaponAimAngleBefore = Select-NumberValue -Line $Line -Name "weaponAimAngleBefore"
        weaponAimAngleAfter = $weaponAimAfter
        targetDistancesBefore = Select-NumberPair -Line $Line -Name "targetDistancesBefore"
        targetDistancesAfter = $targetDistancesAfter
        weaponGripDistancesAfter = $gripDistancesAfter
        weaponGripSpanAfter = $weaponGripSpanAfter
        fabrikErrors = $fabrikErrors
        reachable = $reachable
        handsUncrossed = $handsUncrossed
        handForwardAngles = $handForwardAngles
        handOrientationCandidates = $handOrientationCandidates
        handOrientationErrors = $handOrientationErrors
        usesExplicitHandOrientation = $usesExplicitHandOrientation
        rawLine = $Line
    }
}

function Get-ManifestPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($ManifestPath)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $resolved = Resolve-RepoRelativePath $path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Manifest not found: $path"
        }
        $paths.Add($resolved) | Out-Null
    }
    if (($paths.Count -eq 0 -or $IncludeManifests) -and -not [string]::IsNullOrWhiteSpace($ManifestRoot)) {
        $root = Resolve-RepoRelativePath $ManifestRoot
        if (Test-Path -LiteralPath $root -PathType Container) {
            foreach ($manifest in @(Get-ChildItem -LiteralPath $root -Recurse -Filter "manifest.json" -File)) {
                $paths.Add($manifest.FullName) | Out-Null
            }
        }
    }
    return @($paths.ToArray() | Sort-Object -Unique)
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($manifestPathItem in Get-ManifestPaths) {
    $manifest = Get-Content -LiteralPath $manifestPathItem -Raw | ConvertFrom-Json
    $logPath = [string](Get-PropertyValue $manifest "logPath")
    if ([string]::IsNullOrWhiteSpace($logPath) -or -not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        continue
    }

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $logPath) {
        ++$lineNumber
        if ($line -notmatch "FNV/ESM4 telemetry: weapon IK frame") {
            continue
        }
        $row = New-WeaponIkRow -Line $line -LineNumber $lineNumber -Manifest $manifest -ManifestPath $manifestPathItem -LogPath $logPath
        if ($null -ne $row) {
            $rows.Add($row) | Out-Null
        }
    }
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
    Write-Host "No actor weapon IK telemetry rows found."
}
else {
    @($rows.ToArray()) |
        Group-Object worldId, actor, status |
        ForEach-Object {
            [pscustomobject][ordered]@{
                worldId = $_.Group[0].worldId
                actor = $_.Group[0].actor
                status = $_.Group[0].status
                count = $_.Count
                maxAimAfter = [Math]::Round((@($_.Group) | ForEach-Object { $_.weaponAimAngleAfter } | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum, 3)
                maxRightTargetAfter = [Math]::Round((@($_.Group) | ForEach-Object { if ($null -ne $_.targetDistancesAfter) { $_.targetDistancesAfter.x } } | Measure-Object -Maximum).Maximum, 3)
                maxLeftTargetAfter = [Math]::Round((@($_.Group) | ForEach-Object { if ($null -ne $_.targetDistancesAfter) { $_.targetDistancesAfter.y } } | Measure-Object -Maximum).Maximum, 3)
                maxHandForwardAngle = [Math]::Round((@($_.Group) | ForEach-Object {
                    if ($null -ne $_.handForwardAngles) { @($_.handForwardAngles.x, $_.handForwardAngles.y) }
                } | Measure-Object -Maximum).Maximum, 3)
                maxHandOrientationForwardError = [Math]::Round((@($_.Group) | ForEach-Object {
                    if ($null -ne $_.handOrientationErrors) { @($_.handOrientationErrors.rightForward, $_.handOrientationErrors.leftForward) }
                } | Measure-Object -Maximum).Maximum, 3)
                maxHandOrientationPalmError = [Math]::Round((@($_.Group) | ForEach-Object {
                    if ($null -ne $_.handOrientationErrors) { @($_.handOrientationErrors.rightPalm, $_.handOrientationErrors.leftPalm) }
                } | Measure-Object -Maximum).Maximum, 3)
            }
        } |
        Sort-Object worldId, actor, status |
        Format-Table -AutoSize
    if (-not $NoWrite) {
        Write-Host "Wrote actor weapon IK telemetry ledger: $OutputPath"
    }
}
