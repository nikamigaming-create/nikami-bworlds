param(
    [string[]]$WorldId = @("morrowind"),
    [ValidateSet("flat", "vr")]
    [string]$Mode = "flat",
    [string]$SeedPath = "catalog/world-walker.seed.json",
    [string]$StartsPath = "catalog/flat-world-proof-starts.json",
    [string]$ActorAnimationPolicyPath = "catalog/actor-animation-policy.json",
    [string]$OutputRoot = "run/real-world-screenshots",
    [int]$RunSeconds = 30,
    [int[]]$CaptureSeconds = @(12, 24),
    [string[]]$InputEvent = @(),
    [switch]$SkipMenu,
    [switch]$NewGame,
    [string]$StartCell = "",
    [string]$StartSlice = "",
    [string]$EngineScreenshotFrames = "180",
    [int]$EngineScreenshotReadyFrames = -1,
    [int]$CrashReportSettleSeconds = 2,
    [switch]$NoEngineScreenshot,
    [string[]]$ExtraArgs = @(),
    [string[]]$SetEnv = @(),
    [string]$BinaryRoot = "",
    [switch]$NoCatalogStart,
    [switch]$UseActorAnimationPolicyEnvironment,
    [switch]$EnableSound,
    [switch]$ShowGui,
    [switch]$BackgroundWindow,
    [switch]$AllowWindowCaptureFallback,
    [switch]$AllowDuplicate,
    [switch]$KeepRunning,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

function Quote-CommandArg([string]$Arg) {
    if ($Arg -match '[\s"]') {
        return '"' + ($Arg -replace '"', '\"') + '"'
    }
    return $Arg
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

function Get-ObjectArray($Value) {
    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array]) {
        return @($Value)
    }
    return @($Value)
}

function Test-TextListContains($Value, [string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }
    foreach ($entry in Get-TextArray $Value) {
        if ([string]::Equals($entry, $Text, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-NameStartsWithAnyPrefix([string]$Name, [string[]]$AllowedPrefixes) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    foreach ($prefix in @($AllowedPrefixes)) {
        if ([string]::IsNullOrWhiteSpace($prefix)) {
            continue
        }
        if ($Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-CatalogAllowedEnvironmentPrefixes($StartsCatalog) {
    $defaults = Get-PropertyValue $StartsCatalog "defaults"
    $environmentPolicy = Get-PropertyValue $defaults "environmentPolicy"
    $prefixes = @(Get-TextArray (Get-PropertyValue $environmentPolicy "allowedPrefixes"))
    if ($prefixes.Count -eq 0) {
        throw "Flat-world starts catalog must define defaults.environmentPolicy.allowedPrefixes."
    }

    return $prefixes
}

function ConvertTo-ScopedEnvironmentOverrides([string[]]$Assignments) {
    $overrides = New-Object System.Collections.Generic.List[object]
    foreach ($assignment in @($Assignments)) {
        if ([string]::IsNullOrWhiteSpace($assignment)) {
            continue
        }

        $separator = $assignment.IndexOf("=")
        if ($separator -lt 1) {
            throw "-SetEnv expects NAME=VALUE, got: $assignment"
        }

        $name = $assignment.Substring(0, $separator).Trim()
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "-SetEnv has an invalid environment variable name: $name"
        }

        $overrides.Add([pscustomobject][ordered]@{
            name = $name
            value = $assignment.Substring($separator + 1)
        }) | Out-Null
    }

    return @($overrides.ToArray())
}

function Set-ScopedProcessEnvValue([hashtable]$PreviousEnvironment, [System.Collections.Generic.List[string]]$AppliedEnvironment, [string]$Name, $Value) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }
    if (-not $PreviousEnvironment.ContainsKey($Name)) {
        $PreviousEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
    }

    $prefix = "$Name="
    for ($i = $AppliedEnvironment.Count - 1; $i -ge 0; --$i) {
        if (([string]$AppliedEnvironment[$i]).StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $AppliedEnvironment.RemoveAt($i)
        }
    }

    $text = if ($null -eq $Value) { $null } else { [string]$Value }
    if ([string]::IsNullOrWhiteSpace($text)) {
        [Environment]::SetEnvironmentVariable($Name, $null, "Process")
        return
    }

    [Environment]::SetEnvironmentVariable($Name, $text, "Process")
    $AppliedEnvironment.Add("$Name=$text") | Out-Null
}

function Restore-ScopedProcessEnvironment([hashtable]$PreviousEnvironment) {
    foreach ($entry in $PreviousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

function Clear-ScopedNikamiWorldViewerRuntimeEnvironment([hashtable]$PreviousEnvironment, [System.Collections.Generic.List[string]]$AppliedEnvironment, [string[]]$AllowedPrefixes) {
    $keys = @([Environment]::GetEnvironmentVariables("Process").Keys)
    foreach ($key in $keys) {
        $name = [string]$key
        if (Test-NameStartsWithAnyPrefix -Name $name -AllowedPrefixes $AllowedPrefixes) {
            Set-ScopedProcessEnvValue -PreviousEnvironment $PreviousEnvironment -AppliedEnvironment $AppliedEnvironment -Name $name -Value $null
        }
    }
}

function Format-InvariantEnvironmentNumber($Value) {
    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        return ([double]$Value).ToString("R", [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return [string]$Value
}

function Set-ScopedProcessEnvNumber([hashtable]$PreviousEnvironment, [System.Collections.Generic.List[string]]$AppliedEnvironment, [string]$Name, $Value) {
    if ($null -eq $Value) {
        return
    }

    $text = Format-InvariantEnvironmentNumber $Value
    Set-ScopedProcessEnvValue -PreviousEnvironment $PreviousEnvironment -AppliedEnvironment $AppliedEnvironment -Name $Name -Value $text
}

function Set-ScopedProcessEnvNumberList([hashtable]$PreviousEnvironment, [System.Collections.Generic.List[string]]$AppliedEnvironment, [string]$Name, [object[]]$Values) {
    if ($null -eq $Values -or $Values.Count -eq 0) {
        return
    }

    $text = (@($Values) | ForEach-Object { Format-InvariantEnvironmentNumber $_ }) -join ","
    Set-ScopedProcessEnvValue -PreviousEnvironment $PreviousEnvironment -AppliedEnvironment $AppliedEnvironment -Name $Name -Value $text
}

function Merge-CatalogPropertyObject($Base, $Overlay) {
    $map = [ordered]@{}
    foreach ($source in @($Base, $Overlay)) {
        if ($null -eq $source) {
            continue
        }
        foreach ($property in @($source.PSObject.Properties)) {
            $map[[string]$property.Name] = $property.Value
        }
    }
    if ($map.Count -eq 0) {
        return $null
    }

    return [pscustomobject]$map
}

function New-MergedCatalogStartSpec($WorldSpec, $SliceSpec, [string]$SliceId) {
    $map = [ordered]@{}
    foreach ($property in @($WorldSpec.PSObject.Properties)) {
        $name = [string]$property.Name
        if ($name -eq "slices") {
            continue
        }
        $map[$name] = $property.Value
    }

    if ($null -ne $SliceSpec) {
        foreach ($property in @($SliceSpec.PSObject.Properties)) {
            $map[[string]$property.Name] = $property.Value
        }
    }

    foreach ($mergedProperty in @("environment", "presentation", "capture")) {
        $mergedValue = Merge-CatalogPropertyObject (Get-PropertyValue $WorldSpec $mergedProperty) (Get-PropertyValue $SliceSpec $mergedProperty)
        if ($null -ne $mergedValue) {
            $map[$mergedProperty] = $mergedValue
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SliceId)) {
        $map["sliceId"] = $SliceId
    }

    return [pscustomobject]$map
}

function Get-CatalogStartSpec($StartsCatalog, [string]$Id, [string]$SliceId = "") {
    if ($null -eq $StartsCatalog -or $null -eq $StartsCatalog.worlds) {
        return $null
    }

    $property = $StartsCatalog.worlds.PSObject.Properties[$Id]
    if ($null -eq $property) {
        return $null
    }

    $worldSpec = $property.Value
    if ([string]::IsNullOrWhiteSpace($SliceId)) {
        return New-MergedCatalogStartSpec -WorldSpec $worldSpec -SliceSpec $null -SliceId ""
    }

    $slices = Get-PropertyValue $worldSpec "slices"
    if ($null -eq $slices) {
        throw "Flat-world starts catalog entry '$Id' has no slices. Requested slice '$SliceId'."
    }

    $sliceProperty = $slices.PSObject.Properties[$SliceId]
    if ($null -eq $sliceProperty) {
        $knownSlices = @($slices.PSObject.Properties | ForEach-Object { $_.Name }) -join ", "
        throw "Flat-world starts catalog entry '$Id' has no slice '$SliceId'. Known slices: $knownSlices"
    }

    return New-MergedCatalogStartSpec -WorldSpec $worldSpec -SliceSpec $sliceProperty.Value -SliceId $SliceId
}

function Get-IntArray($Value) {
    if ($null -eq $Value) {
        return @()
    }
    $values = if ($Value -is [System.Array]) { @($Value) } else { @($Value) }
    $result = New-Object System.Collections.Generic.List[int]
    foreach ($entry in $values) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry)) {
            continue
        }
        $result.Add([int]$entry) | Out-Null
    }
    return @($result.ToArray())
}

function Get-CatalogDefaultCaptureSpec($StartsCatalog) {
    if ($null -eq $StartsCatalog) {
        return $null
    }

    $defaults = Get-PropertyValue $StartsCatalog "defaults"
    if ($null -eq $defaults) {
        return $null
    }

    $capture = Get-PropertyValue $defaults "capture"
    $map = [ordered]@{}
    if ($null -ne $capture) {
        foreach ($property in @($capture.PSObject.Properties)) {
            $map[[string]$property.Name] = $property.Value
        }
    }

    $legacyRunSeconds = Get-PropertyValue $defaults "runSeconds"
    if (-not $map.Contains("runSeconds") -and $null -ne $legacyRunSeconds) {
        $map["runSeconds"] = $legacyRunSeconds
    }

    $legacyScreenshotFrames = Get-PropertyValue $defaults "screenshotFrames"
    if (-not $map.Contains("engineScreenshotFrames") -and -not [string]::IsNullOrWhiteSpace([string]$legacyScreenshotFrames)) {
        $map["engineScreenshotFrames"] = $legacyScreenshotFrames
    }

    if ($map.Count -eq 0) {
        return $null
    }

    return [pscustomobject]$map
}

function Resolve-CatalogCaptureSpec($StartsCatalog, $StartSpec) {
    $defaultCapture = Get-CatalogDefaultCaptureSpec $StartsCatalog
    $startCapture = Get-PropertyValue $StartSpec "capture"
    return Merge-CatalogPropertyObject $defaultCapture $startCapture
}

function Test-ParameterWasSupplied([System.Collections.IDictionary]$BoundParameters, [string]$Name) {
    return ($null -ne $BoundParameters -and @($BoundParameters.Keys) -contains $Name)
}

function Resolve-RealWorldCaptureConfig {
    param(
        [object]$Capture,
        [System.Collections.IDictionary]$BoundParameters,
        [int]$DefaultRunSeconds,
        [int[]]$DefaultCaptureSeconds,
        [string]$DefaultEngineScreenshotFrames,
        [int]$DefaultEngineScreenshotReadyFrames,
        [int]$DefaultCrashReportSettleSeconds,
        [bool]$DefaultNoEngineScreenshot
    )

    $resolvedRunSeconds = $DefaultRunSeconds
    $resolvedCaptureSeconds = @($DefaultCaptureSeconds)
    $resolvedEngineScreenshotFrames = $DefaultEngineScreenshotFrames
    $resolvedEngineScreenshotReadyFrames = $DefaultEngineScreenshotReadyFrames
    $resolvedCrashReportSettleSeconds = $DefaultCrashReportSettleSeconds
    $resolvedExpectedScreenshotCount = $null
    $resolvedNoEngineScreenshot = $DefaultNoEngineScreenshot

    if ($null -ne $Capture) {
        $catalogRunSeconds = Get-PropertyValue $Capture "runSeconds"
        if (-not (Test-ParameterWasSupplied $BoundParameters "RunSeconds") -and $null -ne $catalogRunSeconds) {
            $resolvedRunSeconds = [int]$catalogRunSeconds
        }

        $catalogCaptureSeconds = @(Get-IntArray (Get-PropertyValue $Capture "captureSeconds"))
        if (-not (Test-ParameterWasSupplied $BoundParameters "CaptureSeconds") -and $catalogCaptureSeconds.Count -gt 0) {
            $resolvedCaptureSeconds = @($catalogCaptureSeconds)
        }

        $catalogEngineScreenshotFrames = [string](Get-PropertyValue $Capture "engineScreenshotFrames")
        if (-not (Test-ParameterWasSupplied $BoundParameters "EngineScreenshotFrames") -and -not [string]::IsNullOrWhiteSpace($catalogEngineScreenshotFrames)) {
            $resolvedEngineScreenshotFrames = $catalogEngineScreenshotFrames
        }

        $catalogEngineScreenshotEnabled = Get-PropertyValue $Capture "engineScreenshotEnabled"
        if (-not (Test-ParameterWasSupplied $BoundParameters "NoEngineScreenshot") -and $null -ne $catalogEngineScreenshotEnabled) {
            $resolvedNoEngineScreenshot = -not [bool]$catalogEngineScreenshotEnabled
        }

        $catalogEngineScreenshotReadyFrames = Get-PropertyValue $Capture "engineScreenshotReadyFrames"
        if (-not (Test-ParameterWasSupplied $BoundParameters "EngineScreenshotReadyFrames") -and $null -ne $catalogEngineScreenshotReadyFrames) {
            $resolvedEngineScreenshotReadyFrames = [int]$catalogEngineScreenshotReadyFrames
        }

        $catalogCrashReportSettleSeconds = Get-PropertyValue $Capture "crashReportSettleSeconds"
        if (-not (Test-ParameterWasSupplied $BoundParameters "CrashReportSettleSeconds") -and $null -ne $catalogCrashReportSettleSeconds) {
            $resolvedCrashReportSettleSeconds = [int]$catalogCrashReportSettleSeconds
        }

        $catalogExpectedScreenshotCount = Get-PropertyValue $Capture "expectedScreenshotCount"
        if ($null -ne $catalogExpectedScreenshotCount) {
            $resolvedExpectedScreenshotCount = [int]$catalogExpectedScreenshotCount
        }
    }

    if ($resolvedRunSeconds -le 0) {
        throw "Resolved capture runSeconds must be positive."
    }
    if ($resolvedCrashReportSettleSeconds -lt 0) {
        throw "Resolved capture crashReportSettleSeconds must be zero or positive."
    }
    if ($null -ne $resolvedExpectedScreenshotCount -and $resolvedExpectedScreenshotCount -le 0) {
        throw "Resolved capture expectedScreenshotCount must be positive."
    }
    foreach ($captureSecond in @($resolvedCaptureSeconds)) {
        if ($captureSecond -lt 0) {
            throw "Resolved capture captureSeconds must be zero or positive."
        }
        if ($captureSecond -gt $resolvedRunSeconds) {
            throw "Resolved capture second $captureSecond exceeds runSeconds $resolvedRunSeconds."
        }
    }

    $engineScreenshotEnabled = -not $resolvedNoEngineScreenshot -and -not [string]::IsNullOrWhiteSpace($resolvedEngineScreenshotFrames)
    return [pscustomobject][ordered]@{
        runSeconds = [int]$resolvedRunSeconds
        captureSeconds = @($resolvedCaptureSeconds)
        noEngineScreenshot = [bool]$resolvedNoEngineScreenshot
        engineScreenshotEnabled = [bool]$engineScreenshotEnabled
        engineScreenshotFrames = if ($engineScreenshotEnabled) { $resolvedEngineScreenshotFrames } else { $null }
        engineScreenshotReadyFrames = if ($engineScreenshotEnabled -and $resolvedEngineScreenshotReadyFrames -ge 0) { [int]$resolvedEngineScreenshotReadyFrames } else { $null }
        crashReportSettleSeconds = [int]$resolvedCrashReportSettleSeconds
        expectedScreenshotCount = if ($null -ne $resolvedExpectedScreenshotCount) { [int]$resolvedExpectedScreenshotCount } else { $null }
    }
}

function Get-ActorAnimationWorldPolicy($PolicyCatalog, [string]$Id) {
    if ($null -eq $PolicyCatalog -or $null -eq $PolicyCatalog.worlds) {
        return $null
    }

    $property = $PolicyCatalog.worlds.PSObject.Properties[$Id]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Apply-CatalogStartSpec {
    param(
        [object]$Spec,
        [hashtable]$PreviousEnvironment,
        [System.Collections.Generic.List[string]]$AppliedEnvironment
    )

    if ($null -eq $Spec) {
        return
    }

    $anchor = Get-PropertyValue $Spec "anchor"
    if ($null -eq $anchor) {
        return
    }

    $position = Get-PropertyValue $anchor "position"
    if ($null -ne $position) {
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_POS_X" (Get-PropertyValue $position "x")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_POS_Y" (Get-PropertyValue $position "y")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_POS_Z" (Get-PropertyValue $position "z")
    }

    $rotation = Get-PropertyValue $anchor "rotation"
    if ($null -ne $rotation) {
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_ROT_X" (Get-PropertyValue $rotation "x")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_ROT_Y" (Get-PropertyValue $rotation "y")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_ROT_Z" (Get-PropertyValue $rotation "z")
    }

    $exteriorLocation = Get-PropertyValue $anchor "exteriorLocation"
    if ($null -ne $exteriorLocation) {
        Set-ScopedProcessEnvValue $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_WORLDSPACE" (Get-PropertyValue $exteriorLocation "worldspace")
        $grid = Get-PropertyValue $exteriorLocation "grid"
        if ($null -ne $grid) {
            Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_GRID_X" (Get-PropertyValue $grid "x")
            Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_GRID_Y" (Get-PropertyValue $grid "y")
        }
    }

    if ([bool](Get-PropertyValue $anchor "dry")) {
        Set-ScopedProcessEnvValue $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_DRY" "1"
    }

    $esm4GridRadius = Get-PropertyValue $Spec "esm4GridRadius"
    if ($null -ne $esm4GridRadius) {
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS" $esm4GridRadius
    }

    $camera = Get-PropertyValue $anchor "camera"
    if ($null -ne $camera) {
        Set-ScopedProcessEnvValue $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_MODE" (Get-PropertyValue $camera "mode")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_DISTANCE" (Get-PropertyValue $camera "distance")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_PITCH" (Get-PropertyValue $camera "pitch")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_YAW" (Get-PropertyValue $camera "yaw")
        $cameraPosition = Get-PropertyValue $camera "position"
        if ($null -ne $cameraPosition) {
            Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_POS_X" (Get-PropertyValue $cameraPosition "x")
            Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Y" (Get-PropertyValue $cameraPosition "y")
            Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Z" (Get-PropertyValue $cameraPosition "z")
        }
        $cameraTarget = Get-PropertyValue $camera "target"
        if ($null -ne $cameraTarget) {
            Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_X" (Get-PropertyValue $cameraTarget "x")
            Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Y" (Get-PropertyValue $cameraTarget "y")
            Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Z" (Get-PropertyValue $cameraTarget "z")
        }

        if ([bool](Get-PropertyValue $camera "orbitRaycast")) {
            Set-ScopedProcessEnvValue $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_RAYCAST" "1"
        }
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_SAMPLES" (Get-PropertyValue $camera "orbitSamples")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_RADIUS" (Get-PropertyValue $camera "orbitRadius")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_HEIGHT" (Get-PropertyValue $camera "orbitHeight")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_CLEARANCE" (Get-PropertyValue $camera "orbitClearance")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_MIN_HIT_DISTANCE" (Get-PropertyValue $camera "orbitMinHitDistance")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_MIN_GROUND_HEIGHT" (Get-PropertyValue $camera "orbitMinGroundHeight")
        Set-ScopedProcessEnvNumber $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_GROUND_RAY_DISTANCE" (Get-PropertyValue $camera "orbitGroundRayDistance")

        $cameraSequence = @(Get-ObjectArray (Get-PropertyValue $camera "sequence"))
        if ($cameraSequence.Count -gt 0) {
            $frames = New-Object System.Collections.Generic.List[object]
            $eyeX = New-Object System.Collections.Generic.List[object]
            $eyeY = New-Object System.Collections.Generic.List[object]
            $eyeZ = New-Object System.Collections.Generic.List[object]
            $targetX = New-Object System.Collections.Generic.List[object]
            $targetY = New-Object System.Collections.Generic.List[object]
            $targetZ = New-Object System.Collections.Generic.List[object]

            foreach ($keyframe in $cameraSequence) {
                $frame = Get-PropertyValue $keyframe "frame"
                $eye = Get-PropertyValue $keyframe "position"
                $targetPoint = Get-PropertyValue $keyframe "target"
                if ($null -eq $frame -or $null -eq $eye -or $null -eq $targetPoint) {
                    throw "Camera sequence entries require frame, position, and target."
                }

                $frames.Add([int]$frame) | Out-Null
                $eyeX.Add((Get-PropertyValue $eye "x")) | Out-Null
                $eyeY.Add((Get-PropertyValue $eye "y")) | Out-Null
                $eyeZ.Add((Get-PropertyValue $eye "z")) | Out-Null
                $targetX.Add((Get-PropertyValue $targetPoint "x")) | Out-Null
                $targetY.Add((Get-PropertyValue $targetPoint "y")) | Out-Null
                $targetZ.Add((Get-PropertyValue $targetPoint "z")) | Out-Null
            }

            Set-ScopedProcessEnvNumberList $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_FRAMES" $frames.ToArray()
            Set-ScopedProcessEnvNumberList $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_EYE_X" $eyeX.ToArray()
            Set-ScopedProcessEnvNumberList $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_EYE_Y" $eyeY.ToArray()
            Set-ScopedProcessEnvNumberList $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_EYE_Z" $eyeZ.ToArray()
            Set-ScopedProcessEnvNumberList $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_TARGET_X" $targetX.ToArray()
            Set-ScopedProcessEnvNumberList $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_TARGET_Y" $targetY.ToArray()
            Set-ScopedProcessEnvNumberList $PreviousEnvironment $AppliedEnvironment "OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_TARGET_Z" $targetZ.ToArray()
        }
    }
}

function Resolve-CatalogPresentationPolicy {
    param(
        [object]$StartsCatalog,
        [object]$Spec,
        [object]$World,
        [bool]$ShowGuiOverride
    )

    $defaults = Get-PropertyValue $StartsCatalog "defaults"
    $defaultPresentation = Get-PropertyValue $defaults "presentation"
    $specPresentation = Get-PropertyValue $Spec "presentation"
    $supportTier = [string](Get-PropertyValue $World "supportTier")
    $track = [string](Get-PropertyValue $World "track")

    $hideGui = $false
    $hideReason = ""

    $defaultHideGui = Get-PropertyValue $defaultPresentation "hideGui"
    if ($null -ne $defaultHideGui) {
        $hideGui = [bool]$defaultHideGui
        $hideReason = "catalog-default"
    }
    if (Test-TextListContains (Get-PropertyValue $defaultPresentation "hideGuiForSupportTiers") $supportTier) {
        $hideGui = $true
        $hideReason = "supportTier:$supportTier"
    }
    if (Test-TextListContains (Get-PropertyValue $defaultPresentation "hideGuiForTracks") $track) {
        $hideGui = $true
        $hideReason = "track:$track"
    }

    $specHideGui = Get-PropertyValue $specPresentation "hideGui"
    if ($null -ne $specHideGui) {
        $hideGui = [bool]$specHideGui
        $hideReason = "world-start"
    }
    if ($ShowGuiOverride) {
        $hideGui = $false
        $hideReason = "parameter-show-gui"
    }

    $forceClearLoadingGui = $false
    $defaultForceClear = Get-PropertyValue $defaultPresentation "forceClearLoadingGui"
    if ($null -ne $defaultForceClear) {
        $forceClearLoadingGui = [bool]$defaultForceClear
    }
    if ($hideGui -and [bool](Get-PropertyValue $defaultPresentation "forceClearLoadingGuiWhenGuiHidden")) {
        $forceClearLoadingGui = $true
    }
    $specForceClear = Get-PropertyValue $specPresentation "forceClearLoadingGui"
    if ($null -ne $specForceClear) {
        $forceClearLoadingGui = [bool]$specForceClear
    }
    if ($ShowGuiOverride -and $null -eq $specForceClear) {
        $forceClearLoadingGui = $false
    }

    return [pscustomobject][ordered]@{
        hideGui = $hideGui
        forceClearLoadingGui = $forceClearLoadingGui
        reason = $hideReason
        supportTier = $supportTier
        track = $track
    }
}

function Apply-PresentationPolicy {
    param(
        [object]$Policy,
        [hashtable]$PreviousEnvironment,
        [System.Collections.Generic.List[string]]$AppliedEnvironment
    )

    if ($null -eq $Policy) {
        return
    }
    if ([bool](Get-PropertyValue $Policy "hideGui")) {
        Set-ScopedProcessEnvValue -PreviousEnvironment $PreviousEnvironment -AppliedEnvironment $AppliedEnvironment -Name "OPENMW_PROOF_HIDE_GUI" -Value "1"
    }
    if ([bool](Get-PropertyValue $Policy "forceClearLoadingGui")) {
        Set-ScopedProcessEnvValue -PreviousEnvironment $PreviousEnvironment -AppliedEnvironment $AppliedEnvironment -Name "OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI" -Value "1"
    }
}

function Apply-CatalogEnvironmentSpec {
    param(
        [object]$Spec,
        [hashtable]$PreviousEnvironment,
        [System.Collections.Generic.List[string]]$AppliedEnvironment,
        [string[]]$AllowedPrefixes,
        [string]$SourceName = "catalog"
    )

    if ($null -eq $Spec) {
        return
    }

    foreach ($property in @($Spec.PSObject.Properties)) {
        $name = [string]$property.Name
        if (-not (Test-NameStartsWithAnyPrefix -Name $name -AllowedPrefixes $AllowedPrefixes)) {
            throw "$SourceName environment variable '$name' is not allowed by defaults.environmentPolicy.allowedPrefixes."
        }

        $value = $property.Value
        if ($value -is [bool]) {
            $value = if ([bool]$value) { "1" } else { $null }
        }
        Set-ScopedProcessEnvValue -PreviousEnvironment $PreviousEnvironment -AppliedEnvironment $AppliedEnvironment -Name $name -Value $value
    }
}

function Apply-ScopedEnvironmentOverrides {
    param(
        [object[]]$Overrides,
        [hashtable]$PreviousEnvironment,
        [System.Collections.Generic.List[string]]$AppliedEnvironment,
        [string[]]$AllowedPrefixes,
        [string]$SourceName = "Command-line -SetEnv"
    )

    foreach ($override in @($Overrides)) {
        $name = [string]$override.name
        if (-not (Test-NameStartsWithAnyPrefix -Name $name -AllowedPrefixes $AllowedPrefixes)) {
            throw "$SourceName environment variable '$name' is not allowed by defaults.environmentPolicy.allowedPrefixes."
        }

        Set-ScopedProcessEnvValue -PreviousEnvironment $PreviousEnvironment -AppliedEnvironment $AppliedEnvironment -Name $name -Value $override.value
    }
}

function Add-RealGameAutomationType {
    if ("Nikami.RealGameAutomation" -as [type]) {
        return
    }

    Add-Type -ReferencedAssemblies @("System.dll", "System.Drawing.dll") -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Nikami
{
    public static class RealGameAutomation
    {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        private static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);

        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

        private struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const uint KEYEVENTF_SCANCODE = 0x0008;

        public static IntPtr FindMainWindow(int processId)
        {
            IntPtr result = IntPtr.Zero;
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                uint windowProcessId;
                GetWindowThreadProcessId(hWnd, out windowProcessId);
                if (windowProcessId != (uint)processId || !IsWindowVisible(hWnd))
                    return true;

                StringBuilder title = new StringBuilder(512);
                GetWindowText(hWnd, title, title.Capacity);
                if (title.Length == 0)
                    return true;

                result = hWnd;
                return false;
            }, IntPtr.Zero);

            return result;
        }

        public static void BringToFront(IntPtr hWnd)
        {
            ShowWindow(hWnd, 9);
            SetForegroundWindow(hWnd);
        }

        public static void SendVirtualKey(ushort virtualKey)
        {
            if (virtualKey > byte.MaxValue)
                throw new ArgumentOutOfRangeException("virtualKey");

            keybd_event((byte)virtualKey, 0, 0, UIntPtr.Zero);
            Thread.Sleep(50);
            keybd_event((byte)virtualKey, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        }

        public static void HoldVirtualKey(ushort virtualKey, int milliseconds)
        {
            if (virtualKey > byte.MaxValue)
                throw new ArgumentOutOfRangeException("virtualKey");
            if (milliseconds < 0)
                throw new ArgumentOutOfRangeException("milliseconds");

            keybd_event((byte)virtualKey, 0, 0, UIntPtr.Zero);
            try
            {
                Thread.Sleep(milliseconds);
            }
            finally
            {
                keybd_event((byte)virtualKey, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
            }
        }

        public static void SendScanCode(ushort scanCode)
        {
            if (scanCode > byte.MaxValue)
                throw new ArgumentOutOfRangeException("scanCode");

            keybd_event(0, (byte)scanCode, KEYEVENTF_SCANCODE, UIntPtr.Zero);
            Thread.Sleep(50);
            keybd_event(0, (byte)scanCode, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
        }

        public static void HoldScanCode(ushort scanCode, int milliseconds)
        {
            if (scanCode > byte.MaxValue)
                throw new ArgumentOutOfRangeException("scanCode");
            if (milliseconds < 0)
                throw new ArgumentOutOfRangeException("milliseconds");

            keybd_event(0, (byte)scanCode, KEYEVENTF_SCANCODE, UIntPtr.Zero);
            try
            {
                Thread.Sleep(milliseconds);
            }
            finally
            {
                keybd_event(0, (byte)scanCode, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
            }
        }

        public static void CaptureWindowToPng(IntPtr hWnd, string path)
        {
            RECT rect;
            if (!GetWindowRect(hWnd, out rect))
                throw new InvalidOperationException("GetWindowRect failed.");

            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;
            if (width <= 0 || height <= 0)
                throw new InvalidOperationException("Window rectangle is empty.");

            using (Bitmap bitmap = new Bitmap(width, height))
            {
                using (Graphics graphics = Graphics.FromImage(bitmap))
                {
                    bool printed = false;
                    IntPtr hdc = graphics.GetHdc();
                    try
                    {
                        printed = PrintWindow(hWnd, hdc, 0);
                    }
                    finally
                    {
                        graphics.ReleaseHdc(hdc);
                    }

                    if (!printed)
                        graphics.CopyFromScreen(rect.Left, rect.Top, 0, 0, new Size(width, height));
                }
                bitmap.Save(path, ImageFormat.Png);
            }
        }
    }
}
"@
}

function Wait-ForMainWindow($Process, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $Process.Refresh()
        if ($Process.HasExited) {
            return [IntPtr]::Zero
        }
        $handle = [Nikami.RealGameAutomation]::FindMainWindow($Process.Id)
        if ($handle -ne [IntPtr]::Zero) {
            return $handle
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    return [IntPtr]::Zero
}

function Focus-GameWindow($Process, [IntPtr]$Window) {
    [Nikami.RealGameAutomation]::BringToFront($Window)
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shell.AppActivate($Process.Id) | Out-Null
    }
    catch {
        Write-Verbose "AppActivate failed for PID $($Process.Id): $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 350
}

function Convert-IntegerLiteral([string]$Value) {
    $trimmed = $Value.Trim()
    if ($trimmed -match '^0x[0-9a-fA-F]+$') {
        return [Convert]::ToInt32($trimmed.Substring(2), 16)
    }

    return [int]$trimmed
}

function Send-GameText($Process, [IntPtr]$Window, [string]$Text) {
    Focus-GameWindow -Process $Process -Window $Window
    $shell = New-Object -ComObject WScript.Shell
    $shell.SendKeys($Text)
    Start-Sleep -Milliseconds 100
}

function Split-HoldInputValue([string]$Value, [string]$Event) {
    $separator = $Value.IndexOf(":")
    if ($separator -lt 0) {
        throw "Input event '$event' must use <code>:<seconds> for hold events."
    }

    $code = $Value.Substring(0, $separator).Trim()
    $seconds = [double]$Value.Substring($separator + 1)
    if ([string]::IsNullOrWhiteSpace($code) -or $seconds -lt 0) {
        throw "Input event '$event' has an invalid hold value."
    }

    [pscustomobject]@{
        Code = $code
        Milliseconds = [int]($seconds * 1000)
    }
}

function Invoke-GameInputEvents($Process, [IntPtr]$Window, [string[]]$Events) {
    foreach ($event in $Events) {
        if ([string]::IsNullOrWhiteSpace($event)) {
            continue
        }

        $separator = $event.IndexOf(":")
        if ($separator -lt 0) {
            throw "Input event '$event' must be one of wait:<seconds>, text:<value>, scan:<value>, scanhold:<value>:<seconds>, vk:<value>, or vkhold:<value>:<seconds>."
        }

        $kind = $event.Substring(0, $separator).Trim().ToLowerInvariant()
        $value = $event.Substring($separator + 1)
        switch ($kind) {
            "wait" {
                Start-Sleep -Milliseconds ([int]([double]$value * 1000))
            }
            "text" {
                Send-GameText -Process $Process -Window $Window -Text $value
            }
            "scan" {
                Focus-GameWindow -Process $Process -Window $Window
                [Nikami.RealGameAutomation]::SendScanCode([uint16](Convert-IntegerLiteral $value))
                Start-Sleep -Milliseconds 100
            }
            "scanhold" {
                $hold = Split-HoldInputValue -Value $value -Event $event
                Focus-GameWindow -Process $Process -Window $Window
                [Nikami.RealGameAutomation]::HoldScanCode([uint16](Convert-IntegerLiteral $hold.Code), [int]$hold.Milliseconds)
                Start-Sleep -Milliseconds 100
            }
            "vk" {
                Focus-GameWindow -Process $Process -Window $Window
                [Nikami.RealGameAutomation]::SendVirtualKey([uint16](Convert-IntegerLiteral $value))
                Start-Sleep -Milliseconds 100
            }
            "vkhold" {
                $hold = Split-HoldInputValue -Value $value -Event $event
                Focus-GameWindow -Process $Process -Window $Window
                [Nikami.RealGameAutomation]::HoldVirtualKey([uint16](Convert-IntegerLiteral $hold.Code), [int]$hold.Milliseconds)
                Start-Sleep -Milliseconds 100
            }
            default {
                throw "Unknown input event kind '$kind' in '$event'."
            }
        }
    }
}

function Invoke-NativeScreenshotAction($Process, [IntPtr]$Window) {
    Focus-GameWindow -Process $Process -Window $Window
    [Nikami.RealGameAutomation]::SendScanCode(0x58)
    Start-Sleep -Milliseconds 150
    [Nikami.RealGameAutomation]::SendVirtualKey(0x7B)
}

function Invoke-WindowScreenshotFallback($Process, [IntPtr]$Window, [string]$Destination) {
    $Process.Refresh()
    if ($Process.HasExited) {
        throw "Process exited before fallback window capture."
    }
    $freshWindow = [Nikami.RealGameAutomation]::FindMainWindow($Process.Id)
    if ($freshWindow -ne [IntPtr]::Zero) {
        $Window = $freshWindow
    }
    if ($Window -eq [IntPtr]::Zero) {
        throw "No visible process window for fallback capture."
    }
    Focus-GameWindow -Process $Process -Window $Window
    Start-Sleep -Milliseconds 150
    [Nikami.RealGameAutomation]::CaptureWindowToPng($Window, $Destination)
    return (Wait-ForStableFile -Path $Destination -TimeoutSeconds 5)
}

function Get-RegexValue([string]$Text, [string]$Pattern) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }

    if ($match.Groups["value"].Success) {
        return $match.Groups["value"].Value.Trim()
    }

    return $match.Groups[1].Value.Trim()
}

function Convert-HexProcessIdToInt([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $text = $Value.Trim()
    if ($text.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) {
        $text = $text.Substring(2)
    }

    try {
        return [Convert]::ToInt32($text, 16)
    }
    catch {
        return $null
    }
}

function Get-WindowsCrashReports {
    param(
        [string]$ProcessPath,
        [string]$ProcessName,
        [int]$ProcessId,
        [datetime]$StartTime,
        [datetime]$EndTime
    )

    if ($null -eq (Get-Command Get-WinEvent -ErrorAction SilentlyContinue)) {
        return @()
    }

    $reports = New-Object System.Collections.Generic.List[object]
    $queryStart = $StartTime.AddSeconds(-5)
    $queryEnd = $EndTime.AddSeconds(15)
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = "Application"
            StartTime = $queryStart
            EndTime = $queryEnd
        } -ErrorAction SilentlyContinue
    }
    catch {
        return @()
    }

    $normalizedProcessPath = if ([string]::IsNullOrWhiteSpace($ProcessPath)) { "" } else { $ProcessPath.ToLowerInvariant() }
    $normalizedProcessName = if ([string]::IsNullOrWhiteSpace($ProcessName)) { "" } else { $ProcessName.ToLowerInvariant() }

    foreach ($event in @($events | Sort-Object TimeCreated)) {
        $message = [string]$event.Message
        if ([string]::IsNullOrWhiteSpace($message)) {
            continue
        }

        $lowerMessage = $message.ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($normalizedProcessPath) -and $lowerMessage -notlike "*$normalizedProcessPath*" -and $lowerMessage -notlike "*$normalizedProcessName*") {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($normalizedProcessPath) -and -not [string]::IsNullOrWhiteSpace($normalizedProcessName) -and $lowerMessage -notlike "*$normalizedProcessName*") {
            continue
        }

        $faultingProcessIdText = Get-RegexValue -Text $message -Pattern "Faulting process id:\s*(?<value>0x[0-9a-fA-F]+|[0-9a-fA-F]+)"
        $faultingProcessId = Convert-HexProcessIdToInt $faultingProcessIdText
        if ($null -ne $faultingProcessId -and $ProcessId -gt 0 -and $faultingProcessId -ne $ProcessId) {
            continue
        }

        $reports.Add([pscustomobject][ordered]@{
            timeCreated = $event.TimeCreated.ToString("o")
            providerName = [string]$event.ProviderName
            eventId = [int]$event.Id
            eventName = Get-RegexValue -Text $message -Pattern "Event Name:\s*(?<value>\S+)"
            reportId = Get-RegexValue -Text $message -Pattern "Report Id:\s*(?<value>[0-9a-fA-F-]+)"
            faultingModule = Get-RegexValue -Text $message -Pattern "Faulting module name:\s*(?<value>[^,\r\n]+)|P4:\s*(?<value>[^\r\n]+)"
            exceptionCode = Get-RegexValue -Text $message -Pattern "Exception code:\s*(?<value>0x[0-9a-fA-F]+|[0-9a-fA-F]+)|P8:\s*(?<value>[^\r\n]+)"
            exceptionOffset = Get-RegexValue -Text $message -Pattern "Fault offset:\s*(?<value>0x[0-9a-fA-F]+|[0-9a-fA-F]+)|P7:\s*(?<value>[^\r\n]+)"
            exceptionData = Get-RegexValue -Text $message -Pattern "P9:\s*(?<value>[^\r\n]+)"
            faultingProcessId = $faultingProcessId
            bucketId = Get-RegexValue -Text $message -Pattern "Hashed bucket:\s*(?<value>[0-9a-fA-F]+)"
            legacyBucketId = Get-RegexValue -Text $message -Pattern "Fault bucket\s+(?<value>\d+)"
            reportArchivePath = Get-RegexValue -Text $message -Pattern "These files may be available here:\s*(?<value>.+)"
        }) | Out-Null
    }

    return @($reports.ToArray())
}

function Get-OpenMWCrashDumpReports {
    param(
        [string[]]$Roots,
        [datetime]$StartTime,
        [datetime]$EndTime
    )

    $reports = New-Object System.Collections.Generic.List[object]
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $queryStart = $StartTime.AddSeconds(-5)
    $queryEnd = $EndTime.AddSeconds(15)

    foreach ($root in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -LiteralPath $root -File -Filter "openmw-crash*.dmp" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $queryStart -and $_.LastWriteTime -le $queryEnd } |
            Sort-Object LastWriteTime |
            ForEach-Object {
                if (-not $seen.Add($_.FullName)) {
                    return
                }
                $reports.Add([pscustomobject][ordered]@{
                    source = "openmw-crash-dump"
                    path = $_.FullName
                    length = $_.Length
                    lastWriteTime = $_.LastWriteTime.ToString("o")
                }) | Out-Null
            }
    }

    return @($reports.ToArray())
}

function Get-WorldById($Seed, [string]$Id) {
    return @($Seed.worlds | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Resolve-OpenMWConfigPathValue([string]$ProfileDirectory, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Value.Trim())
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return $expanded
    }

    return (Join-Path $ProfileDirectory $expanded)
}

function Get-OpenMWScreenshotDirectory($World) {
    $profileDirectory = [string]$World.profileDirectory
    $configPath = Join-Path $profileDirectory "openmw.cfg"
    $userData = $null

    if (Test-Path -LiteralPath $configPath) {
        foreach ($line in Get-Content -LiteralPath $configPath) {
            if ($line -match '^\s*user-data\s*=\s*(.+?)\s*$') {
                $userData = Resolve-OpenMWConfigPathValue -ProfileDirectory $profileDirectory -Value $matches[1]
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($userData)) {
        $userData = Join-Path $profileDirectory "userdata"
    }

    return (Join-Path $userData "screenshots")
}

function Get-NativeScreenshotFiles([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $Directory -File |
        Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|tga|bmp)$' })
}

function Wait-ForStableFile([string]$Path, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastStamp = $null
    $stableSince = $null

    do {
        if (-not (Test-Path -LiteralPath $Path)) {
            Start-Sleep -Milliseconds 250
            continue
        }

        $item = Get-Item -LiteralPath $Path
        $stamp = "$($item.Length):$($item.LastWriteTimeUtc.Ticks)"
        if ($stamp -eq $lastStamp) {
            if ($null -eq $stableSince) {
                $stableSince = Get-Date
            }
            elseif (((Get-Date) - $stableSince).TotalMilliseconds -ge 750) {
                return $item
            }
        }
        else {
            $lastStamp = $stamp
            $stableSince = $null
        }

        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    return (Get-Item -LiteralPath $Path)
}

function Wait-ForNativeScreenshots([string]$Directory, [datetime]$Since, [hashtable]$KnownFiles, [int]$TimeoutSeconds, [int]$ExpectedCount = 1) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $bestCandidates = @()
    if ($ExpectedCount -lt 1) {
        $ExpectedCount = 1
    }
    do {
        $candidates = @(Get-NativeScreenshotFiles -Directory $Directory |
            Where-Object { -not $KnownFiles.ContainsKey($_.FullName) -and $_.LastWriteTime -ge $Since.AddSeconds(-2) } |
            Sort-Object LastWriteTime, Name)
        if ($candidates.Count -gt 0) {
            $bestCandidates = @($candidates)
            if ($candidates.Count -lt $ExpectedCount) {
                Start-Sleep -Milliseconds 250
                continue
            }
            $stableFiles = New-Object System.Collections.Generic.List[object]
            foreach ($candidate in $candidates) {
                $stableFiles.Add((Wait-ForStableFile -Path $candidate.FullName -TimeoutSeconds $TimeoutSeconds)) | Out-Null
            }
            return @($stableFiles.ToArray())
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    if ($bestCandidates.Count -gt 0) {
        $stableFiles = New-Object System.Collections.Generic.List[object]
        foreach ($candidate in $bestCandidates) {
            $stableFiles.Add((Wait-ForStableFile -Path $candidate.FullName -TimeoutSeconds $TimeoutSeconds)) | Out-Null
        }
        return @($stableFiles.ToArray())
    }

    return @()
}

function Wait-ForNativeScreenshot([string]$Directory, [datetime]$Since, [hashtable]$KnownFiles, [int]$TimeoutSeconds) {
    $screenshots = @(Wait-ForNativeScreenshots -Directory $Directory -Since $Since -KnownFiles $KnownFiles -TimeoutSeconds $TimeoutSeconds)
    if ($screenshots.Count -eq 0) {
        return $null
    }

    return $screenshots[0]
}

function Get-ImageDimensions([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    $image = [System.Drawing.Image]::FromFile($Path)
    try {
        return [pscustomobject]@{
            Width = [int]$image.Width
            Height = [int]$image.Height
        }
    }
    finally {
        $image.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $SeedPath)) {
    throw "Missing world walker seed: $SeedPath. Run scripts/New-WorldWalkerSeed.ps1 first."
}

$seed = Get-Content -LiteralPath $SeedPath -Raw | ConvertFrom-Json
$startsCatalog = $null
if (-not [string]::IsNullOrWhiteSpace($StartsPath) -and (Test-Path -LiteralPath $StartsPath)) {
    $startsCatalog = Get-Content -LiteralPath $StartsPath -Raw | ConvertFrom-Json
}
$allowedEnvironmentPrefixes = Get-CatalogAllowedEnvironmentPrefixes -StartsCatalog $startsCatalog
$processEnvironmentOverrides = @(ConvertTo-ScopedEnvironmentOverrides -Assignments $SetEnv)
if ($NoCatalogStart -and -not [string]::IsNullOrWhiteSpace($StartSlice)) {
    throw "-StartSlice requires catalog start selection; remove -NoCatalogStart or omit -StartSlice."
}
if (-not [string]::IsNullOrWhiteSpace($StartCell) -and -not [string]::IsNullOrWhiteSpace($StartSlice)) {
    throw "-StartCell and -StartSlice cannot be combined. Put alternate cells in catalog/flat-world-proof-starts.json slices."
}
$actorAnimationPolicy = $null
if ($UseActorAnimationPolicyEnvironment) {
    if (-not (Test-Path -LiteralPath $ActorAnimationPolicyPath)) {
        throw "Missing actor animation policy: $ActorAnimationPolicyPath"
    }
    $actorAnimationPolicy = Get-Content -LiteralPath $ActorAnimationPolicyPath -Raw | ConvertFrom-Json
}
$binaryRootPath = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$resourcesRoot = Resolve-NikamiOpenMWResourcesRoot -ParameterValue (Join-Path $binaryRootPath "resources")
$binaryName = if ($Mode -eq "flat") { "openmw.exe" } else { "openmw_vr.exe" }
$binary = Join-Path $binaryRootPath $binaryName
if (-not (Test-Path -LiteralPath $binary)) {
    throw "Missing repo-local OpenMW binary: $binary"
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$absOutputRoot = Resolve-NikamiRepoRelativePath -Path $OutputRoot
New-Item -ItemType Directory -Force -Path $absOutputRoot | Out-Null

Add-RealGameAutomationType

$results = New-Object System.Collections.Generic.List[object]
foreach ($id in $WorldId) {
    $world = Get-WorldById -Seed $seed -Id $id
    if ($null -eq $world) {
        $known = @($seed.worlds | ForEach-Object { $_.id }) -join ", "
        throw "Unknown world id '$id'. Known ids: $known"
    }
    if ($world.readyForWorldWalker -ne $true) {
        throw "World '$id' is not ready for the world walker. installStatus=$($world.installStatus) profileStatus=$($world.profileStatus)"
    }
    if (-not $world.profileDirectory -or -not (Test-Path -LiteralPath $world.profileDirectory)) {
        throw "${id}: missing generated profile directory $($world.profileDirectory)"
    }

    $runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $worldOutput = Join-Path $absOutputRoot "$id-$runStamp"
    $screensDir = Join-Path $worldOutput "screenshots"
    New-Item -ItemType Directory -Force -Path $screensDir | Out-Null
    $nativeScreensDir = Get-OpenMWScreenshotDirectory -World $world
    New-Item -ItemType Directory -Force -Path $nativeScreensDir | Out-Null
    $catalogStartSpec = $null
    $effectiveStartCell = $StartCell
    $useCatalogStart = -not $NoCatalogStart `
        -and [string]::IsNullOrWhiteSpace($StartCell) `
        -and -not $NewGame
    if ($useCatalogStart) {
        $catalogStartSpec = Get-CatalogStartSpec -StartsCatalog $startsCatalog -Id $id -SliceId $StartSlice
        $catalogStartCell = if ($null -ne $catalogStartSpec) { [string](Get-PropertyValue $catalogStartSpec "startCell") } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($catalogStartCell)) {
            $effectiveStartCell = $catalogStartCell
        }
    }
    $catalogInputEvents = if ($null -ne $catalogStartSpec) {
        @(Get-TextArray (Get-PropertyValue $catalogStartSpec "inputEvents"))
    } else {
        @()
    }
    $effectiveInputEvents = @($catalogInputEvents + $InputEvent)
    $captureSpec = if ($null -ne $catalogStartSpec) { Resolve-CatalogCaptureSpec -StartsCatalog $startsCatalog -StartSpec $catalogStartSpec } else { $null }
    $captureConfig = Resolve-RealWorldCaptureConfig `
        -Capture $captureSpec `
        -BoundParameters $PSBoundParameters `
        -DefaultRunSeconds $RunSeconds `
        -DefaultCaptureSeconds $CaptureSeconds `
        -DefaultEngineScreenshotFrames $EngineScreenshotFrames `
        -DefaultEngineScreenshotReadyFrames $EngineScreenshotReadyFrames `
        -DefaultCrashReportSettleSeconds $CrashReportSettleSeconds `
        -DefaultNoEngineScreenshot ([bool]$NoEngineScreenshot)
    $effectiveRunSeconds = [int]$captureConfig.runSeconds
    $effectiveCaptureSeconds = @($captureConfig.captureSeconds)
    $effectiveEngineScreenshotFrames = $captureConfig.engineScreenshotFrames
    $effectiveEngineScreenshotReadyFrames = if ($null -ne $captureConfig.engineScreenshotReadyFrames) { [int]$captureConfig.engineScreenshotReadyFrames } else { -1 }
    $effectiveCrashReportSettleSeconds = [int]$captureConfig.crashReportSettleSeconds
    $effectiveExpectedScreenshotCount = if ($null -ne $captureConfig.expectedScreenshotCount) { [int]$captureConfig.expectedScreenshotCount } else { $null }
    $engineScreenshotEnabled = [bool]$captureConfig.engineScreenshotEnabled
    $effectiveSkipMenu = $SkipMenu -or ($null -ne $catalogStartSpec)
    $actorAnimationWorldPolicy = $null
    $actorAnimationEnvironment = $null
    if ($UseActorAnimationPolicyEnvironment) {
        $actorAnimationWorldPolicy = Get-ActorAnimationWorldPolicy -PolicyCatalog $actorAnimationPolicy -Id $id
        if ($null -eq $actorAnimationWorldPolicy) {
            throw "Actor animation policy has no world entry for '$id'."
        }
        $actorAnimationEnvironment = Get-PropertyValue $actorAnimationWorldPolicy "engineEnvironment"
        if ($null -eq $actorAnimationEnvironment) {
            throw "Actor animation policy '$id' has no engineEnvironment."
        }
    }

    $argsList = New-Object System.Collections.Generic.List[string]
    $argsList.Add("--replace")
    $argsList.Add("config")
    $argsList.Add("--config")
    $argsList.Add([string]$world.profileDirectory)
    $argsList.Add("--resources")
    $argsList.Add($resourcesRoot)
    if ($effectiveSkipMenu) {
        $argsList.Add("--skip-menu")
    }
    if ($NewGame) {
        $argsList.Add("--new-game")
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveStartCell)) {
        $argsList.Add("--start")
        $argsList.Add($effectiveStartCell)
    }
    $defaultCatalogExtraArgs = @(Get-TextArray (Get-PropertyValue (Get-PropertyValue $startsCatalog "defaults") "extraArgs"))
    $startCatalogExtraArgs = if ($null -ne $catalogStartSpec) { @(Get-TextArray (Get-PropertyValue $catalogStartSpec "extraArgs")) } else { @() }
    $effectiveExtraArgs = @($defaultCatalogExtraArgs + $startCatalogExtraArgs + $ExtraArgs)
    if ($EnableSound) {
        $effectiveExtraArgs = @($effectiveExtraArgs | Where-Object {
            -not ([string]$_).StartsWith("--no-sound", [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $catalogScriptRun = if ($null -ne $catalogStartSpec) { [string](Get-PropertyValue $catalogStartSpec "scriptRun") } else { "" }
    $resolvedCatalogScriptRun = $null
    if (-not [string]::IsNullOrWhiteSpace($catalogScriptRun)) {
        $resolvedCatalogScriptRun = Resolve-NikamiRepoRelativePath -Path $catalogScriptRun
        if (-not (Test-Path -LiteralPath $resolvedCatalogScriptRun -PathType Leaf)) {
            throw "Flat-world start scriptRun does not exist: $resolvedCatalogScriptRun"
        }
        $argsList.Add("--script-run")
        $argsList.Add($resolvedCatalogScriptRun)
    }
    foreach ($arg in $effectiveExtraArgs) {
        if (-not [string]::IsNullOrWhiteSpace($arg)) {
            $argsList.Add($arg)
        }
    }

    $argumentLine = ($argsList.ToArray() | ForEach-Object { Quote-CommandArg $_ }) -join " "
    $commandLine = "$(Quote-CommandArg $binary) $argumentLine"
    Write-Host ""
    Write-Host "[$id] $($world.displayName)"
    Write-Host "Command: $commandLine"
    if ($engineScreenshotEnabled) {
        Write-Host "Capture: in-engine scheduled native screenshot frame(s): $effectiveEngineScreenshotFrames."
    }
    else {
        Write-Host "Capture: OpenMW native screenshot action (F12)."
    }
    if ($BackgroundWindow) {
        Write-Host "Presentation: launch hidden and do not request foreground focus."
    }
    $presentationPolicy = Resolve-CatalogPresentationPolicy -StartsCatalog $startsCatalog -Spec $catalogStartSpec -World $world -ShowGuiOverride ([bool]$ShowGui)

    $manifest = [ordered]@{
        schemaVersion = 1
        worldId = $id
        displayName = [string]$world.displayName
        mode = $Mode
        createdAt = (Get-Date).ToString("o")
        outputDirectory = $worldOutput
        binary = $binary
        resources = $resourcesRoot
        profileDirectory = [string]$world.profileDirectory
        nativeScreenshotDirectory = $nativeScreensDir
        commandLine = $commandLine
        startCell = $effectiveStartCell
        startSlice = if ($null -ne $catalogStartSpec) { Get-PropertyValue $catalogStartSpec "sliceId" } else { $null }
        runSeconds = $effectiveRunSeconds
        captureSeconds = @($effectiveCaptureSeconds)
        extraArgs = @($effectiveExtraArgs)
        soundEnabled = [bool]$EnableSound
        backgroundWindow = [bool]$BackgroundWindow
        scriptRun = $resolvedCatalogScriptRun
        engineScreenshotEnabled = [bool]$engineScreenshotEnabled
        engineScreenshotFrames = if ($engineScreenshotEnabled) { $effectiveEngineScreenshotFrames } else { $null }
        engineScreenshotReadyFrames = if ($engineScreenshotEnabled -and $effectiveEngineScreenshotReadyFrames -ge 0) { $effectiveEngineScreenshotReadyFrames } else { $null }
        crashReportSettleSeconds = $effectiveCrashReportSettleSeconds
        expectedScreenshotCount = $effectiveExpectedScreenshotCount
        catalogStart = if ($null -ne $catalogStartSpec) {
            [ordered]@{
                startsPath = $StartsPath
                sliceId = Get-PropertyValue $catalogStartSpec "sliceId"
                label = [string](Get-PropertyValue $catalogStartSpec "label")
                startCell = [string](Get-PropertyValue $catalogStartSpec "startCell")
                environment = Get-PropertyValue $catalogStartSpec "environment"
                anchor = Get-PropertyValue $catalogStartSpec "anchor"
                presentation = Get-PropertyValue $catalogStartSpec "presentation"
                capture = Get-PropertyValue $catalogStartSpec "capture"
                validation = Get-PropertyValue $catalogStartSpec "validation"
                scriptRun = $catalogScriptRun
            }
        } else { $null }
        actorAnimationPolicy = if ($UseActorAnimationPolicyEnvironment) {
            [ordered]@{
                policyPath = $ActorAnimationPolicyPath
                environment = $actorAnimationEnvironment
            }
        } else { $null }
        environmentOverrides = @($processEnvironmentOverrides | ForEach-Object { "$($_.name)=$($_.value)" })
        logPath = $null
        presentationPolicy = $presentationPolicy
        processEnvironment = @()
        inputEvents = @($effectiveInputEvents)
        windowFocus = [ordered]@{
            required = [bool]((-not $engineScreenshotEnabled) -or $effectiveInputEvents.Count -gt 0)
            used = $false
            reason = if ($engineScreenshotEnabled -and $effectiveInputEvents.Count -eq 0) {
                "scheduled native capture requires no foreground input"
            } else {
                "native screenshot action or explicit input events require foreground input"
            }
        }
        validationEvidence = $null
        guardrails = @(
            "repo-local-openmw-runtime",
            "real-profile-launch",
            "proof-env-cleared",
            "native-openmw-screenshot",
            $(if ([bool](Get-PropertyValue $presentationPolicy "hideGui")) { "gui-hidden-by-catalog-policy" }),
            $(if ($AllowWindowCaptureFallback) { "window-screenshot-fallback-explicit" } else { "no-external-screen-capture" }),
            "no-capsules",
            "no-actor-staging",
            "no-material-forcing"
        )
        screenshots = @()
        captureAttempts = @()
        windowScreenshotFallbackErrors = @()
        crashReports = @()
        processTermination = $null
        status = "not-run"
    }

    if ($DryRun) {
        $manifest.status = "dry-run"
        $manifestPath = Join-Path $worldOutput "manifest.json"
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding ASCII
        Write-Host "Dry run only. Manifest: $manifestPath"
        $results.Add([pscustomobject]$manifest) | Out-Null
        continue
    }

    $processName = [System.IO.Path]::GetFileNameWithoutExtension($binary)
    if (-not $AllowDuplicate -and (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        throw "$processName is already running. Close it first or pass -AllowDuplicate."
    }

    $previousEnvironment = @{}
    $appliedEnvironment = [System.Collections.Generic.List[string]]::new()
    Clear-ScopedNikamiWorldViewerRuntimeEnvironment -PreviousEnvironment $previousEnvironment -AppliedEnvironment $appliedEnvironment -AllowedPrefixes $allowedEnvironmentPrefixes
    if ($null -ne $catalogStartSpec) {
        Apply-CatalogStartSpec -Spec $catalogStartSpec -PreviousEnvironment $previousEnvironment -AppliedEnvironment $appliedEnvironment
        Apply-CatalogEnvironmentSpec -Spec (Get-PropertyValue $catalogStartSpec "environment") -PreviousEnvironment $previousEnvironment -AppliedEnvironment $appliedEnvironment -AllowedPrefixes $allowedEnvironmentPrefixes -SourceName "Flat-world start"
    }
    if ($UseActorAnimationPolicyEnvironment) {
        Apply-CatalogEnvironmentSpec -Spec $actorAnimationEnvironment -PreviousEnvironment $previousEnvironment -AppliedEnvironment $appliedEnvironment -AllowedPrefixes $allowedEnvironmentPrefixes -SourceName "Actor animation policy"
    }
    Apply-PresentationPolicy -Policy $presentationPolicy -PreviousEnvironment $previousEnvironment -AppliedEnvironment $appliedEnvironment
    Apply-ScopedEnvironmentOverrides -Overrides $processEnvironmentOverrides -PreviousEnvironment $previousEnvironment -AppliedEnvironment $appliedEnvironment -AllowedPrefixes $allowedEnvironmentPrefixes
    if ($engineScreenshotEnabled) {
        Set-ScopedProcessEnvValue -PreviousEnvironment $previousEnvironment -AppliedEnvironment $appliedEnvironment -Name "OPENMW_PROOF_SCREENSHOT_FRAME" -Value $effectiveEngineScreenshotFrames
        if ($effectiveEngineScreenshotReadyFrames -ge 0) {
            Set-ScopedProcessEnvNumber -PreviousEnvironment $previousEnvironment -AppliedEnvironment $appliedEnvironment -Name "OPENMW_PROOF_SCREENSHOT_READY_FRAMES" -Value $effectiveEngineScreenshotReadyFrames
        }
    }
    $manifest.processEnvironment = @($appliedEnvironment.ToArray())

    $process = $null
    $processStartedAt = $null
    $knownNativeScreenshots = @{}
    Get-NativeScreenshotFiles -Directory $nativeScreensDir | ForEach-Object {
        $knownNativeScreenshots[$_.FullName] = $true
    }
    try {
        $processStartedAt = Get-Date
        $startParameters = @{
            FilePath = $binary
            ArgumentList = $argumentLine
            WorkingDirectory = (Split-Path -Parent $binary)
            PassThru = $true
        }
        if ($BackgroundWindow) {
            # A minimized OpenGL surface can yield valid PNG files containing
            # only black pixels. Hidden windows continue rendering native
            # engine screenshots without foreground focus or OS input.
            $startParameters.WindowStyle = "Hidden"
        }
        $process = Start-Process @startParameters
        $manifest.status = "started"
        $manifest.pid = $process.Id
        Write-Host "Started PID $($process.Id)."

        $window = Wait-ForMainWindow -Process $process -TimeoutSeconds ([Math]::Min(20, [Math]::Max(3, $effectiveRunSeconds)))
        if ($window -eq [IntPtr]::Zero -and (-not $BackgroundWindow -or $process.HasExited)) {
            $manifest.status = if ($process.HasExited) { "exited-before-window" } else { "no-window" }
        }
        else {
            if ($window -eq [IntPtr]::Zero) {
                Write-Host "Hidden render surface has no discoverable window handle; native scheduled capture will continue without focus."
            }
            elseif ($manifest.windowFocus.required) {
                Focus-GameWindow -Process $process -Window $window
                $manifest.windowFocus.used = $true
            }
            else {
                Write-Host "Leaving the game window in the background; scheduled native capture needs no input focus."
            }
            $startedAt = Get-Date

            if ($effectiveInputEvents.Count -gt 0) {
                if ($window -eq [IntPtr]::Zero) {
                    throw "Hidden background capture cannot apply input events without a window handle."
                }
                Write-Host "Applying real input events: $($effectiveInputEvents -join ', ')"
                Invoke-GameInputEvents -Process $process -Window $window -Events $effectiveInputEvents
            }

            $captures = @($effectiveCaptureSeconds | Sort-Object -Unique)
            if ($captures.Count -eq 0) {
                $captures = @([Math]::Min(10, $effectiveRunSeconds))
            }

            foreach ($captureSecond in $captures) {
                while (-not $process.HasExited -and ((Get-Date) - $startedAt).TotalSeconds -lt $captureSecond) {
                    Start-Sleep -Milliseconds 250
                }
                if ($process.HasExited) {
                    break
                }

                $requestedAt = if ($engineScreenshotEnabled) { $processStartedAt } else { Get-Date }
                $captureAttempt = [ordered]@{
                    captureSecond = [int]$captureSecond
                    requestedAt = $requestedAt.ToString("o")
                    method = if ($engineScreenshotEnabled) { "scheduled-native-screenshot" } else { "native-screenshot-action" }
                    status = "requested"
                    source = $null
                    path = $null
                    nativePath = $null
                    width = $null
                    height = $null
                    screenshotCount = 0
                    message = $null
                }
                if (-not $engineScreenshotEnabled) {
                    if ($window -eq [IntPtr]::Zero) {
                        throw "Hidden background capture requires scheduled native engine screenshots."
                    }
                    Invoke-NativeScreenshotAction -Process $process -Window $window
                }
                $expectedScreenshotsForAttempt = 1
                if ($engineScreenshotEnabled -and $null -ne $effectiveExpectedScreenshotCount) {
                    $alreadyCapturedNative = @($manifest.screenshots | Where-Object { $_.source -eq "openmw-native-screenshot" }).Count
                    $expectedScreenshotsForAttempt = [Math]::Max(1, [int]$effectiveExpectedScreenshotCount - $alreadyCapturedNative)
                }
                $nativeScreenshots = @(Wait-ForNativeScreenshots -Directory $nativeScreensDir -Since $requestedAt -KnownFiles $knownNativeScreenshots -TimeoutSeconds 10 -ExpectedCount $expectedScreenshotsForAttempt)
                if ($nativeScreenshots.Count -eq 0) {
                    if ($engineScreenshotEnabled) {
                        Write-Warning "No scheduled native OpenMW screenshot appeared for $id by t=$captureSecond seconds."
                    }
                    else {
                        Write-Warning "No native OpenMW screenshot appeared for $id at t=$captureSecond seconds."
                    }
                    $captureAttempt.status = "no-native-screenshot"
                    $captureAttempt.message = "No native OpenMW screenshot appeared by t=$captureSecond seconds."
                    if (-not $AllowWindowCaptureFallback) {
                        $manifest.captureAttempts += $captureAttempt
                        continue
                    }

                    try {
                        $screenPath = Join-Path $screensDir ("{0}.t{1:D3}.window.png" -f $id, [int]$captureSecond)
                        $windowScreenshot = Invoke-WindowScreenshotFallback -Process $process -Window $window -Destination $screenPath
                        $dimensions = Get-ImageDimensions -Path $windowScreenshot.FullName
                        $captureAttempt.status = "captured-window-fallback"
                        $captureAttempt.source = "window-screenshot-fallback"
                        $captureAttempt.path = $windowScreenshot.FullName
                        $captureAttempt.width = $dimensions.Width
                        $captureAttempt.height = $dimensions.Height
                        $manifest.screenshots += [ordered]@{
                            path = $windowScreenshot.FullName
                            nativePath = $null
                            source = "window-screenshot-fallback"
                            captureSecond = [int]$captureSecond
                            width = $dimensions.Width
                            height = $dimensions.Height
                        }
                        Write-Host "Captured fallback game-window screenshot: $screenPath"
                    }
                    catch {
                        $message = "Fallback game-window screenshot failed for $id at t=$captureSecond seconds: $($_.Exception.Message)"
                        Write-Warning $message
                        $captureAttempt.status = "fallback-failed"
                        $captureAttempt.message = $message
                        $manifest.windowScreenshotFallbackErrors += $message
                    }
                    $manifest.captureAttempts += $captureAttempt
                    continue
                }

                $firstScreenPath = $null
                $firstNativePath = $null
                $firstDimensions = $null
                $copyIndex = 0
                foreach ($nativeScreenshot in $nativeScreenshots) {
                    $copyIndex += 1
                    $knownNativeScreenshots[$nativeScreenshot.FullName] = $true
                    $copySuffix = if ($nativeScreenshots.Count -eq 1) { "" } else { ".n{0:D2}" -f $copyIndex }
                    $screenPath = Join-Path $screensDir ("{0}.t{1:D3}{2}{3}" -f $id, [int]$captureSecond, $copySuffix, $nativeScreenshot.Extension)
                    Copy-Item -LiteralPath $nativeScreenshot.FullName -Destination $screenPath -Force
                    $dimensions = Get-ImageDimensions -Path $screenPath
                    if ($null -eq $firstScreenPath) {
                        $firstScreenPath = $screenPath
                        $firstNativePath = $nativeScreenshot.FullName
                        $firstDimensions = $dimensions
                    }
                    $manifest.screenshots += [ordered]@{
                        path = $screenPath
                        nativePath = $nativeScreenshot.FullName
                        source = "openmw-native-screenshot"
                        captureSecond = [int]$captureSecond
                        width = $dimensions.Width
                        height = $dimensions.Height
                    }
                    Write-Host "Captured native OpenMW screenshot: $screenPath"
                }
                $captureAttempt.status = "captured-native"
                $captureAttempt.source = "openmw-native-screenshot"
                $captureAttempt.path = $firstScreenPath
                $captureAttempt.nativePath = $firstNativePath
                $captureAttempt.width = $firstDimensions.Width
                $captureAttempt.height = $firstDimensions.Height
                $captureAttempt.screenshotCount = [int]$nativeScreenshots.Count
                $captureAttempt.message = "Captured $($nativeScreenshots.Count) native OpenMW screenshot(s) by t=$captureSecond seconds."
                $manifest.captureAttempts += $captureAttempt
            }

            $sources = @($manifest.screenshots | ForEach-Object { $_.source } | Select-Object -Unique)
            if ($sources -contains "openmw-native-screenshot") {
                $manifest.status = "captured-native"
                $validation = if ($null -ne $catalogStartSpec) {
                    Get-PropertyValue $catalogStartSpec "validation"
                } else { $null }
                if ($true -eq (Get-PropertyValue $validation "visualReviewRequired")) {
                    $manifest.status = "captured-native-review-required"
                }
            }
            elseif ($sources -contains "window-screenshot-fallback") {
                $manifest.status = "captured-window-fallback"
            }
            else {
                $manifest.status = "no-native-screenshot"
            }
        }
    }
    finally {
        if (-not $KeepRunning -and $null -ne $process -and -not $process.HasExited) {
            $manifest.processTermination = [ordered]@{
                requestedByHarness = $true
                requestedAt = (Get-Date).ToString("o")
                closeMainWindowSent = $false
                shutdownGraceSeconds = 10
                forceKilled = $false
                exitedAfterRequest = $false
            }
            $manifest.processTermination.closeMainWindowSent = [bool]$process.CloseMainWindow()
            $shutdownGraceSeconds = [int]$manifest.processTermination.shutdownGraceSeconds
            for ($shutdownWaitSecond = 0; $shutdownWaitSecond -lt $shutdownGraceSeconds; $shutdownWaitSecond++) {
                Start-Sleep -Seconds 1
                $process.Refresh()
                if ($process.HasExited) {
                    break
                }
            }
            if (-not $process.HasExited) {
                $manifest.processTermination.forceKilled = $true
                $process.Kill()
                $process.WaitForExit(5000) | Out-Null
                $process.Refresh()
            }
            $manifest.processTermination.exitedAfterRequest = [bool]$process.HasExited
        }

        if ($null -ne $process) {
            $process.Refresh()
            if ($process.HasExited) {
                $manifest.exitCode = $process.ExitCode
                if ($process.ExitCode -ne 0 -and $null -ne $processStartedAt) {
                    if ($effectiveCrashReportSettleSeconds -gt 0) {
                        Start-Sleep -Seconds $effectiveCrashReportSettleSeconds
                    }
                    $crashReportEnd = Get-Date
                    $crashReports = New-Object System.Collections.Generic.List[object]
                    foreach ($report in @(Get-WindowsCrashReports -ProcessPath $binary -ProcessName ([System.IO.Path]::GetFileName($binary)) -ProcessId $process.Id -StartTime $processStartedAt -EndTime $crashReportEnd)) {
                        $crashReports.Add($report) | Out-Null
                    }
                    $nativeScreensRoot = if ([string]::IsNullOrWhiteSpace($nativeScreensDir)) { "" } else { Split-Path -Parent $nativeScreensDir }
                    foreach ($report in @(Get-OpenMWCrashDumpReports -Roots @([string]$world.profileDirectory, $nativeScreensRoot, $worldOutput) -StartTime $processStartedAt -EndTime $crashReportEnd)) {
                        $crashReports.Add($report) | Out-Null
                    }
                    $manifest.crashReports = @($crashReports.ToArray())
                }
            }
        }

        $profileLogPath = Join-Path ([string]$world.profileDirectory) "openmw.log"
        if (Test-Path -LiteralPath $profileLogPath) {
            $runLogPath = Join-Path $worldOutput "openmw.log"
            Copy-Item -LiteralPath $profileLogPath -Destination $runLogPath -Force
            $manifest.logPath = $runLogPath
        }

        $validation = if ($null -ne $catalogStartSpec) {
            Get-PropertyValue $catalogStartSpec "validation"
        } else { $null }
        if ($null -ne $validation) {
            $validationFailures = [System.Collections.Generic.List[string]]::new()
            $expectedActor = [string](Get-PropertyValue $validation "expectedActor")
            $requireActorFramingTelemetry = $true -eq (Get-PropertyValue $validation "requireActorFramingTelemetry")
            $requirePortraitAcceptanceTelemetry = $true -eq (Get-PropertyValue $validation "requirePortraitAcceptanceTelemetry")
            $actorObserved = $null
            $actorFramingPassed = $null
            $portraitAcceptanceCount = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$manifest.logPath) -and (Test-Path -LiteralPath $manifest.logPath)) {
                $runLogText = Get-Content -LiteralPath $manifest.logPath -Raw
                if (-not [string]::IsNullOrWhiteSpace($expectedActor)) {
                    $actorObserved = [bool]($runLogText -match ('npc="' + [regex]::Escape($expectedActor) + '"'))
                    if (-not $actorObserved) {
                        $validationFailures.Add("expected actor '$expectedActor' was not present in the structured runtime ledger") | Out-Null
                    }
                }
                if ($requireActorFramingTelemetry) {
                    $actorFramingPassed = [bool]($runLogText -match 'World viewer actor framing:.*status=pass')
                    if (-not $actorFramingPassed) {
                        $validationFailures.Add("no passing actor-framing telemetry was recorded") | Out-Null
                    }
                }
                if ($requirePortraitAcceptanceTelemetry) {
                    $portraitAcceptanceCount = [regex]::Matches(
                        $runLogText,
                        'World viewer portrait capture accepted:.*status=pass'
                    ).Count
                    $capturedNativeCount = @($manifest.screenshots | Where-Object { $_.source -eq "openmw-native-screenshot" }).Count
                    if ($portraitAcceptanceCount -ne $capturedNativeCount) {
                        $validationFailures.Add(
                            "portrait acceptance telemetry count $portraitAcceptanceCount does not match native screenshot count $capturedNativeCount"
                        ) | Out-Null
                    }
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($expectedActor) -or $requireActorFramingTelemetry -or $requirePortraitAcceptanceTelemetry) {
                $validationFailures.Add("runtime log required by actor-aware validation is missing") | Out-Null
            }
            $manifest.validationEvidence = [ordered]@{
                expectedActor = if ([string]::IsNullOrWhiteSpace($expectedActor)) { $null } else { $expectedActor }
                actorObserved = $actorObserved
                actorFramingTelemetryRequired = [bool]$requireActorFramingTelemetry
                actorFramingPassed = $actorFramingPassed
                portraitAcceptanceTelemetryRequired = [bool]$requirePortraitAcceptanceTelemetry
                portraitAcceptanceCount = $portraitAcceptanceCount
                failures = @($validationFailures.ToArray())
                status = if ($validationFailures.Count -eq 0) { "pass" } else { "fail" }
            }
            if ($validationFailures.Count -gt 0 -and $manifest.screenshots.Count -gt 0) {
                $manifest.status = "rejected-native-validation"
            }
        }

        $manifest.completedAt = (Get-Date).ToString("o")
        $manifestPath = Join-Path $worldOutput "manifest.json"
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding ASCII
        Write-Host "Manifest: $manifestPath"
        Restore-ScopedProcessEnvironment -PreviousEnvironment $previousEnvironment
    }

    $results.Add([pscustomobject]$manifest) | Out-Null
}

$results
