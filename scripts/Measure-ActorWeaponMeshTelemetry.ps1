param(
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/actor-weapon-mesh-telemetry.jsonl",
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

function Add-UniqueText([System.Collections.Generic.List[string]]$List, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    if (-not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function New-Vec3([double]$X, [double]$Y, [double]$Z) {
    [pscustomobject][ordered]@{
        x = [Math]::Round($X, 4)
        y = [Math]::Round($Y, 4)
        z = [Math]::Round($Z, 4)
    }
}

function Length-Vec3($Value) {
    if ($null -eq $Value) {
        return $null
    }
    return [Math]::Round([Math]::Sqrt($Value.x * $Value.x + $Value.y * $Value.y + $Value.z * $Value.z), 4)
}

function ConvertTo-Vector($Matches, [string]$Prefix) {
    return New-Vec3 `
        ([double]::Parse([string]$Matches["${Prefix}x"], [System.Globalization.CultureInfo]::InvariantCulture)) `
        ([double]::Parse([string]$Matches["${Prefix}y"], [System.Globalization.CultureInfo]::InvariantCulture)) `
        ([double]::Parse([string]$Matches["${Prefix}z"], [System.Globalization.CultureInfo]::InvariantCulture))
}

$script:VectorPattern = "\(\s*(?<{0}x>[-+0-9.eE]+)\s*,\s*(?<{0}y>[-+0-9.eE]+)\s*,\s*(?<{0}z>[-+0-9.eE]+)\s*\)"

function Select-VectorFromLine([string]$Line, [string]$Name, [string]$Prefix) {
    $pattern = [string]::Format($script:VectorPattern, $Prefix)
    $match = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "\s*=\s*" + $pattern)
    if (-not $match.Success) {
        return $null
    }
    return ConvertTo-Vector $match.Groups $Prefix
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

function Select-IntValue([string]$Line, [string]$Name) {
    $value = Select-NumberValue -Line $Line -Name $Name
    if ($null -eq $value) { return $null }
    return [int]$value
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
    [pscustomobject][ordered]@{
        right = [Math]::Round(([double]::Parse($match.Groups["a"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
        left = [Math]::Round(([double]::Parse($match.Groups["b"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
    }
}

function Select-NumberTriplet([string]$Line, [string]$Name) {
    $match = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "=\(\s*(?<a>[-+0-9.eE]+)\s*,\s*(?<b>[-+0-9.eE]+)\s*,\s*(?<c>[-+0-9.eE]+)\s*\)")
    if (-not $match.Success) { return $null }
    [pscustomobject][ordered]@{
        forward = [Math]::Round(([double]::Parse($match.Groups["a"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
        right = [Math]::Round(([double]::Parse($match.Groups["b"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
        up = [Math]::Round(([double]::Parse($match.Groups["c"].Value, [System.Globalization.CultureInfo]::InvariantCulture)), 4)
    }
}

function Test-ActorTelemetryRequested($Manifest) {
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($entry in Get-TextArray (Get-PropertyValue $Manifest "environmentOverrides")) {
        $entries.Add($entry) | Out-Null
    }
    foreach ($entry in Get-TextArray (Get-PropertyValue $Manifest "processEnvironment")) {
        $entries.Add($entry) | Out-Null
    }
    foreach ($entry in @($entries.ToArray())) {
        if ($entry -match "^(OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY|OPENMW_WORLD_VIEWER_TELEMETRY)=" -and $entry -notmatch "=0$") {
            return $true
        }
    }
    return $false
}

function Test-WeaponMeshExpected($Manifest) {
    $worldId = [string](Get-PropertyValue $Manifest "worldId")
    if (-not [string]::Equals($worldId, "fallout_new_vegas", [StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::Equals($worldId, "fallout3", [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    return Test-ActorTelemetryRequested $Manifest
}

function New-WeaponMeshAuditRow([string]$Line, [int]$LineNumber) {
    $localExtent = Select-VectorFromLine -Line $Line -Name "localExtent" -Prefix "localExtent"
    $centerFromAttach = Select-VectorFromLine -Line $Line -Name "centerFromAttach" -Prefix "centerFromAttach"
    $originFromAttach = Select-VectorFromLine -Line $Line -Name "originFromAttach" -Prefix "originFromAttach"
    $centerActorAxes = Select-NumberTriplet -Line $Line -Name "centerActorAxes"
    $majorActorDots = Select-NumberTriplet -Line $Line -Name "majorActorDots"
    $handToVisibleCenter = Select-NumberPair -Line $Line -Name "handToVisibleCenter"

    [pscustomobject][ordered]@{
        line = $LineNumber
        ref = Select-TextValue -Line $Line -Name "ref"
        phase = Select-TextValue -Line $Line -Name "phase"
        model = Select-TextValue -Line $Line -Name "model"
        preferredBone = Select-TextValue -Line $Line -Name "preferredBone"
        attachNode = Select-TextValue -Line $Line -Name "attachNode"
        attachedNode = Select-TextValue -Line $Line -Name "attachedNode"
        valid = Select-BoolValue -Line $Line -Name "valid"
        drawables = Select-IntValue -Line $Line -Name "drawables"
        geometries = Select-IntValue -Line $Line -Name "geometries"
        rigGeometries = Select-IntValue -Line $Line -Name "rigGeometries"
        vertices = Select-IntValue -Line $Line -Name "vertices"
        localCenter = Select-VectorFromLine -Line $Line -Name "localCenter" -Prefix "localCenter"
        localExtent = $localExtent
        localExtentLength = Length-Vec3 $localExtent
        localMajorAxis = Select-TextValue -Line $Line -Name "localMajorAxis"
        worldCenter = Select-VectorFromLine -Line $Line -Name "worldCenter" -Prefix "worldCenter"
        attachOrigin = Select-VectorFromLine -Line $Line -Name "attachOrigin" -Prefix "attachOrigin"
        attachedOrigin = Select-VectorFromLine -Line $Line -Name "attachedOrigin" -Prefix "attachedOrigin"
        centerFromAttach = $centerFromAttach
        centerFromAttachLength = Length-Vec3 $centerFromAttach
        originFromAttach = $originFromAttach
        originFromAttachLength = Length-Vec3 $originFromAttach
        centerActorAxes = $centerActorAxes
        majorWorld = Select-VectorFromLine -Line $Line -Name "majorWorld" -Prefix "majorWorld"
        majorActorDots = $majorActorDots
        rightHand = Select-VectorFromLine -Line $Line -Name "rightHand" -Prefix "rightHand"
        leftHand = Select-VectorFromLine -Line $Line -Name "leftHand" -Prefix "leftHand"
        weaponFrame = Select-VectorFromLine -Line $Line -Name "weaponFrame" -Prefix "weaponFrame"
        handToVisibleCenter = $handToVisibleCenter
        weaponFrameToVisibleCenter = Select-NumberValue -Line $Line -Name "weaponFrameToVisibleCenter"
        rawLine = $Line
    }
}

function Test-IsLongGunWeaponRow($Row) {
    $text = (([string]$Row.model) + " " + ([string]$Row.localMajorAxis)).ToLowerInvariant()
    if ($text -match "2hand|rifle|shotgun|sniper|launcher|minigun|varmint") {
        return $true
    }
    if ($null -ne $Row.localExtent -and $Row.localExtent.x -gt 42.0 -and $Row.localExtent.x -gt ($Row.localExtent.y * 2.0)) {
        return $true
    }
    return $false
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
    $auditExpected = Test-WeaponMeshExpected $manifest
    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    $weaponRows = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace($logPath) -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $logPath) {
            ++$lineNumber
            if ($line -notmatch "World viewer actor weapon mesh ledger:") {
                continue
            }
            $weaponRows.Add((New-WeaponMeshAuditRow -Line $line -LineNumber $lineNumber)) | Out-Null
        }
    }
    elseif ($auditExpected) {
        Add-UniqueText -List $failureClasses -Value "actor-runtime-gap"
    }

    $runtimeWeaponRows = @($weaponRows.ToArray() | Where-Object {
        [string]::Equals([string]$_.phase, "runtime", [StringComparison]::OrdinalIgnoreCase)
    })
    $scoredWeaponRows = if ($runtimeWeaponRows.Count -gt 0) { @($runtimeWeaponRows) } else { @($weaponRows.ToArray()) }

    foreach ($row in @($scoredWeaponRows)) {
        if ($null -eq $row.valid -or -not $row.valid -or $row.geometries -le 0 -or $row.vertices -le 0) {
            Add-UniqueText -List $failureClasses -Value "actor-weapon-mesh-invalid"
        }
        if ($null -ne $row.localExtentLength -and $row.localExtentLength -lt 1.0) {
            Add-UniqueText -List $failureClasses -Value "actor-weapon-mesh-degenerate"
        }
        if ($null -ne $row.centerFromAttachLength) {
            if ($row.centerFromAttachLength -gt 120.0) {
                Add-UniqueText -List $failureClasses -Value "actor-weapon-visible-center-detached"
            }
            elseif ($row.centerFromAttachLength -gt 55.0) {
                Add-UniqueText -List $warningClasses -Value "actor-weapon-visible-center-far"
            }
        }
        if ($null -ne $row.weaponFrameToVisibleCenter) {
            if ($row.weaponFrameToVisibleCenter -gt 90.0) {
                Add-UniqueText -List $failureClasses -Value "actor-weapon-frame-detached"
            }
            elseif ($row.weaponFrameToVisibleCenter -gt 45.0) {
                Add-UniqueText -List $warningClasses -Value "actor-weapon-frame-far"
            }
        }
        if ($null -ne $row.handToVisibleCenter) {
            if ((Test-IsLongGunWeaponRow $row) -and $row.handToVisibleCenter.left -gt 48.0) {
                Add-UniqueText -List $failureClasses -Value "actor-long-gun-offhand-detached"
            }
            if ($row.handToVisibleCenter.right -gt 70.0 -and $row.handToVisibleCenter.left -gt 70.0) {
                Add-UniqueText -List $failureClasses -Value "actor-weapon-hands-detached"
            }
            elseif ($row.handToVisibleCenter.right -gt 48.0 -and $row.handToVisibleCenter.left -gt 48.0) {
                Add-UniqueText -List $warningClasses -Value "actor-weapon-hands-far"
            }
        }
        if ($null -ne $row.majorActorDots) {
            $horizontal = [Math]::Max([Math]::Abs($row.majorActorDots.forward), [Math]::Abs($row.majorActorDots.right))
            if ([Math]::Abs($row.majorActorDots.up) -gt 0.65 -and $horizontal -lt 0.6) {
                if (Test-IsLongGunWeaponRow $row) {
                    Add-UniqueText -List $failureClasses -Value "actor-long-gun-major-axis-vertical"
                }
                else {
                    Add-UniqueText -List $warningClasses -Value "actor-weapon-major-axis-vertical"
                }
            }
        }
    }

    if ($auditExpected -and $weaponRows.Count -eq 0) {
        Add-UniqueText -List $failureClasses -Value "actor-weapon-mesh-telemetry-gap"
        Add-UniqueText -List $warningClasses -Value "actor-weapon-mesh-audit-missing"
    }

    $status = "pass"
    $reason = "actor-weapon-mesh-audit-not-expected"
    if ($failureClasses.Count -gt 0) {
        $status = "fail"
        $reason = "actor-weapon-mesh-spatial-failure"
    }
    elseif ($warningClasses.Count -gt 0) {
        $status = "questionable"
        $reason = "actor-weapon-mesh-spatial-questionable"
    }
    elseif ($weaponRows.Count -gt 0) {
        $reason = "actor-weapon-mesh-audit-present"
    }

    $rows.Add([pscustomobject][ordered]@{
        schemaVersion = 1
        assessedAt = (Get-Date).ToString("o")
        worldId = [string](Get-PropertyValue $manifest "worldId")
        evidenceKind = "actor-weapon-mesh-telemetry"
        status = $status
        reason = $reason
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        manifest = Convert-ToForwardSlash $manifestPathItem
        log = Convert-ToForwardSlash $logPath
        startCell = [string](Get-PropertyValue $manifest "startCell")
        startSlice = [string](Get-PropertyValue $manifest "startSlice")
        auditExpected = $auditExpected
        weaponMeshRowCount = $weaponRows.Count
        runtimeWeaponMeshRowCount = $runtimeWeaponRows.Count
        weaponRows = @($weaponRows.ToArray())
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
        ($row | ConvertTo-Json -Depth 10 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII
    }
}

@($rows.ToArray()) |
    Select-Object worldId, status, reason, auditExpected, weaponMeshRowCount, runtimeWeaponMeshRowCount, @{ Name = "failureClasses"; Expression = { @($_.failureClasses) -join "," } }, @{ Name = "warningClasses"; Expression = { @($_.warningClasses) -join "," } } |
    Format-Table -Wrap -AutoSize

if (-not $NoWrite) {
    Write-Host "Wrote actor weapon mesh telemetry ledger: $OutputPath"
}
