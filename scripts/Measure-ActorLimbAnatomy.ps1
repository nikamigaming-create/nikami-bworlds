param(
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/actor-limb-anatomy.jsonl",
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

function New-Vec3([double]$X, [double]$Y, [double]$Z) {
    [pscustomobject][ordered]@{ x = $X; y = $Y; z = $Z }
}

function Sub-Vec3($A, $B) { New-Vec3 ($A.x - $B.x) ($A.y - $B.y) ($A.z - $B.z) }
function Length-Vec3($A) { [Math]::Sqrt($A.x * $A.x + $A.y * $A.y + $A.z * $A.z) }
function Distance-Vec3($A, $B) { Length-Vec3 (Sub-Vec3 $A $B) }
function HorizontalDistance-Vec3($A, $B) {
    $dx = $A.x - $B.x
    $dy = $A.y - $B.y
    return [Math]::Sqrt($dx * $dx + $dy * $dy)
}

function Test-FiniteVec3($Value) {
    return $null -ne $Value `
        -and -not [double]::IsNaN([double]$Value.x) `
        -and -not [double]::IsNaN([double]$Value.y) `
        -and -not [double]::IsNaN([double]$Value.z) `
        -and -not [double]::IsInfinity([double]$Value.x) `
        -and -not [double]::IsInfinity([double]$Value.y) `
        -and -not [double]::IsInfinity([double]$Value.z)
}

function Get-AngleDegrees($A, $B) {
    $aLength = Length-Vec3 $A
    $bLength = Length-Vec3 $B
    if ($aLength -le 0.000001 -or $bLength -le 0.000001) {
        return 180.0
    }
    $dot = (($A.x * $B.x) + ($A.y * $B.y) + ($A.z * $B.z)) / ($aLength * $bLength)
    $dot = [Math]::Max(-1.0, [Math]::Min(1.0, $dot))
    return [Math]::Acos($dot) * 180.0 / [Math]::PI
}

function Round-Number([double]$Value) {
    return [Math]::Round($Value, 4)
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
    return New-Vec3 `
        ([double]::Parse([string]$Matches["${Prefix}x"], [System.Globalization.CultureInfo]::InvariantCulture)) `
        ([double]::Parse([string]$Matches["${Prefix}y"], [System.Globalization.CultureInfo]::InvariantCulture)) `
        ([double]::Parse([string]$Matches["${Prefix}z"], [System.Globalization.CultureInfo]::InvariantCulture))
}

$script:VectorPattern = "\(\s*(?<{0}x>[-+0-9.eE]+|nan)\s*,\s*(?<{0}y>[-+0-9.eE]+|nan)\s*,\s*(?<{0}z>[-+0-9.eE]+|nan)\s*\)"

function Select-VectorFromLine([string]$Line, [string]$Name, [string]$Prefix) {
    $pattern = [string]::Format($script:VectorPattern, $Prefix)
    $match = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "\s*=\s*" + $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }
    if ($match.Groups["${Prefix}x"].Value -eq "nan" -or $match.Groups["${Prefix}y"].Value -eq "nan" -or $match.Groups["${Prefix}z"].Value -eq "nan") {
        return New-Vec3 ([double]::NaN) ([double]::NaN) ([double]::NaN)
    }
    return ConvertTo-Vector $match.Groups $Prefix
}

function Select-NumberFromLine([string]$Line, [string]$Name) {
    $match = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "\s*=\s*(?<value>[-+0-9.eE]+)")
    if (-not $match.Success) {
        return $null
    }
    return [double]::Parse($match.Groups["value"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Select-TokenFromLine([string]$Line, [string]$Name) {
    $match = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "\s*=\s*(?<value>[^\s]+)")
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups["value"].Value
}

function Get-ActiveAnimationContext([string]$Line, [int]$LineNumber) {
    $sampleMatch = [regex]::Match($Line, " sample=(?<sample>\d+)")
    $groupsMatch = [regex]::Match($Line, " activeGroups=\[(?<groups>.*)\]")
    $activeGroups = if ($groupsMatch.Success) { $groupsMatch.Groups["groups"].Value } else { "" }
    $primaryMatch = [regex]::Match($activeGroups, "(?<blendMask>\d+):(?<group>[^@\s]+)@t=(?<time>[-+0-9.eE]+).*?(?:src=(?<source>[^|]+))?")

    [pscustomobject][ordered]@{
        line = $LineNumber
        sample = if ($sampleMatch.Success) { [int]$sampleMatch.Groups["sample"].Value } else { $null }
        activeGroups = $activeGroups
        primaryBlendMask = if ($primaryMatch.Success) { [int]$primaryMatch.Groups["blendMask"].Value } else { $null }
        primaryGroup = if ($primaryMatch.Success) { $primaryMatch.Groups["group"].Value } else { $null }
        primaryTime = if ($primaryMatch.Success) {
            [double]::Parse($primaryMatch.Groups["time"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        } else { $null }
        primarySource = if ($primaryMatch.Success) { $primaryMatch.Groups["source"].Value.Trim() } else { $null }
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

function New-LimbAnatomyRow(
    $Manifest,
    [string]$ManifestPath,
    [string]$LogPath,
    [int]$LineNumber,
    [string]$Actor,
    [hashtable]$Bones,
    $AnimationContext = $null
) {
    $required = @(
        "head", "pelvis",
        "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftHand", "rightHand",
        "leftThigh", "rightThigh", "leftKnee", "rightKnee", "leftFoot", "rightFoot"
    )
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $required) {
        if (-not $Bones.ContainsKey($name) -or -not (Test-FiniteVec3 $Bones[$name])) {
            $missing.Add($name) | Out-Null
        }
    }

    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    if ($missing.Count -gt 0) {
        Add-UniqueText -List $failureClasses -Value "actor-limb-anatomy-invalid"
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            measuredAt = (Get-Date).ToString("o")
            worldId = [string](Get-PropertyValue $Manifest "worldId")
            evidenceKind = "actor-limb-anatomy"
            status = "fail"
            failureClasses = @($failureClasses.ToArray())
            warningClasses = @($warningClasses.ToArray())
            manifest = Convert-ToForwardSlash $ManifestPath
            log = Convert-ToForwardSlash $LogPath
            logLine = $LineNumber
            animationStateLine = if ($null -ne $AnimationContext) { $AnimationContext.line } else { $null }
            animationSample = if ($null -ne $AnimationContext) { $AnimationContext.sample } else { $null }
            activeGroups = if ($null -ne $AnimationContext) { $AnimationContext.activeGroups } else { $null }
            animationBlendMask = if ($null -ne $AnimationContext) { $AnimationContext.primaryBlendMask } else { $null }
            animationGroup = if ($null -ne $AnimationContext) { $AnimationContext.primaryGroup } else { $null }
            animationTime = if ($null -ne $AnimationContext) { $AnimationContext.primaryTime } else { $null }
            animationSource = if ($null -ne $AnimationContext) { $AnimationContext.primarySource } else { $null }
            startCell = [string](Get-PropertyValue $Manifest "startCell")
            startSlice = [string](Get-PropertyValue $Manifest "startSlice")
            actor = $Actor
            verdict = "BAD"
            reason = "missing_bone"
            missingBones = @($missing.ToArray())
        }
    }

    $head = $Bones["head"]
    $pelvis = $Bones["pelvis"]
    $leftShoulder = $Bones["leftShoulder"]
    $rightShoulder = $Bones["rightShoulder"]
    $leftElbow = $Bones["leftElbow"]
    $rightElbow = $Bones["rightElbow"]
    $leftHand = $Bones["leftHand"]
    $rightHand = $Bones["rightHand"]
    $leftThigh = $Bones["leftThigh"]
    $rightThigh = $Bones["rightThigh"]
    $leftKnee = $Bones["leftKnee"]
    $rightKnee = $Bones["rightKnee"]
    $leftFoot = $Bones["leftFoot"]
    $rightFoot = $Bones["rightFoot"]

    $shoulderSpan = Distance-Vec3 $leftShoulder $rightShoulder
    $hipSpan = Distance-Vec3 $leftThigh $rightThigh
    $elbowSpan = Distance-Vec3 $leftElbow $rightElbow
    $handSpan = Distance-Vec3 $leftHand $rightHand
    $kneeSpan = Distance-Vec3 $leftKnee $rightKnee
    $footSpread = Distance-Vec3 $leftFoot $rightFoot
    $leftUpperArm = Distance-Vec3 $leftShoulder $leftElbow
    $rightUpperArm = Distance-Vec3 $rightShoulder $rightElbow
    $leftForearm = Distance-Vec3 $leftElbow $leftHand
    $rightForearm = Distance-Vec3 $rightElbow $rightHand
    $leftArmReach = Distance-Vec3 $leftShoulder $leftHand
    $rightArmReach = Distance-Vec3 $rightShoulder $rightHand
    $leftArmAngle = Get-AngleDegrees (Sub-Vec3 $leftShoulder $leftElbow) (Sub-Vec3 $leftHand $leftElbow)
    $rightArmAngle = Get-AngleDegrees (Sub-Vec3 $rightShoulder $rightElbow) (Sub-Vec3 $rightHand $rightElbow)
    $leftThighLength = Distance-Vec3 $leftThigh $leftKnee
    $rightThighLength = Distance-Vec3 $rightThigh $rightKnee
    $leftCalfLength = Distance-Vec3 $leftKnee $leftFoot
    $rightCalfLength = Distance-Vec3 $rightKnee $rightFoot
    $leftLegAngle = Get-AngleDegrees (Sub-Vec3 $leftThigh $leftKnee) (Sub-Vec3 $leftFoot $leftKnee)
    $rightLegAngle = Get-AngleDegrees (Sub-Vec3 $rightThigh $rightKnee) (Sub-Vec3 $rightFoot $rightKnee)
    $leftFootFromHip = HorizontalDistance-Vec3 $leftFoot $leftThigh
    $rightFootFromHip = HorizontalDistance-Vec3 $rightFoot $rightThigh
    $leftKneeFromHip = HorizontalDistance-Vec3 $leftKnee $leftThigh
    $rightKneeFromHip = HorizontalDistance-Vec3 $rightKnee $rightThigh
    $leftFootDrop = $leftThigh.z - $leftFoot.z
    $rightFootDrop = $rightThigh.z - $rightFoot.z
    $leftKneeDrop = $leftThigh.z - $leftKnee.z
    $rightKneeDrop = $rightThigh.z - $rightKnee.z
    $feetBelowPelvis = $pelvis.z - (($leftFoot.z + $rightFoot.z) * 0.5)
    $headAbovePelvis = $head.z - $pelvis.z
    $handSpreadRatio = $handSpan / [Math]::Max(1.0, $shoulderSpan)
    $footSpreadRatio = $footSpread / [Math]::Max(1.0, $hipSpan)
    $avgFootFromHip = ($leftFootFromHip + $rightFootFromHip) * 0.5
    $avgKneeFromHip = ($leftKneeFromHip + $rightKneeFromHip) * 0.5
    $avgFootDrop = ($leftFootDrop + $rightFootDrop) * 0.5
    $avgKneeDrop = ($leftKneeDrop + $rightKneeDrop) * 0.5
    $leftArmFabrikUnreachableBy = [Math]::Max(0.0, $leftArmReach - ($leftUpperArm + $leftForearm))
    $rightArmFabrikUnreachableBy = [Math]::Max(0.0, $rightArmReach - ($rightUpperArm + $rightForearm))
    $leftLegReach = Distance-Vec3 $leftThigh $leftFoot
    $rightLegReach = Distance-Vec3 $rightThigh $rightFoot
    $leftLegFabrikUnreachableBy = [Math]::Max(0.0, $leftLegReach - ($leftThighLength + $leftCalfLength))
    $rightLegFabrikUnreachableBy = [Math]::Max(0.0, $rightLegReach - ($rightThighLength + $rightCalfLength))
    $maxFabrikUnreachableBy = (@(
            $leftArmFabrikUnreachableBy
            $rightArmFabrikUnreachableBy
            $leftLegFabrikUnreachableBy
            $rightLegFabrikUnreachableBy
        ) | Measure-Object -Maximum).Maximum

    $badShoulderSpan = $shoulderSpan -lt 16.0 -or $shoulderSpan -gt 48.0
    $badArmSpan = $handSpan -gt [Math]::Max(62.0, $shoulderSpan * 2.25) -or $elbowSpan -gt [Math]::Max(58.0, $shoulderSpan * 2.1)
    $badArmLengths = $leftUpperArm -lt 8.0 -or $rightUpperArm -lt 8.0 -or $leftForearm -lt 8.0 -or $rightForearm -lt 8.0 `
        -or $leftUpperArm -gt 30.0 -or $rightUpperArm -gt 30.0 -or $leftForearm -gt 30.0 -or $rightForearm -gt 30.0 `
        -or [Math]::Abs($leftUpperArm - $rightUpperArm) -gt 5.0 -or [Math]::Abs($leftForearm - $rightForearm) -gt 5.0
    $badArmReach = $leftArmReach -lt 12.0 -or $rightArmReach -lt 12.0 `
        -or $leftArmReach -gt ($leftUpperArm + $leftForearm + 1.5) `
        -or $rightArmReach -gt ($rightUpperArm + $rightForearm + 1.5) `
        -or [Math]::Abs($leftArmReach - $rightArmReach) -gt 18.0
    $badArmAngle = $leftArmAngle -lt 20.0 -or $rightArmAngle -lt 20.0
    $badLegLengths = $leftThighLength -lt 16.0 -or $rightThighLength -lt 16.0 -or $leftCalfLength -lt 16.0 -or $rightCalfLength -lt 16.0 `
        -or $leftThighLength -gt 46.0 -or $rightThighLength -gt 46.0 -or $leftCalfLength -gt 46.0 -or $rightCalfLength -gt 46.0 `
        -or [Math]::Abs($leftThighLength - $rightThighLength) -gt 8.0 -or [Math]::Abs($leftCalfLength - $rightCalfLength) -gt 8.0
    $badLegCrouch = $avgFootDrop -lt 48.0 -or $avgFootDrop -gt 74.0 -or $avgKneeDrop -lt 18.0 -or $avgKneeDrop -gt 46.0
    $badLegTravel = $avgFootFromHip -gt 28.0 -or $avgKneeFromHip -gt 30.0
    $badLegSpread = $footSpread -gt [Math]::Max(38.0, $hipSpan * 2.0) -or $footSpread -lt 0.5 -or $kneeSpan -gt [Math]::Max(42.0, $hipSpan * 2.2)
    $badLegAngle = $leftLegAngle -lt 75.0 -or $rightLegAngle -lt 75.0
    $badBodyStack = $headAbovePelvis -lt 35.0 -or $headAbovePelvis -gt 70.0 -or $feetBelowPelvis -lt 45.0 -or $feetBelowPelvis -gt 76.0
    $badKeyframeSourcePose = $feetBelowPelvis -lt 30.0 -or $avgFootDrop -lt 30.0 -or $avgKneeDrop -lt 4.0

    $reason = "ok"
    if ($badShoulderSpan) { $reason = "shoulder_span" }
    elseif ($badArmSpan) { $reason = "arm_span" }
    elseif ($badArmLengths) { $reason = "arm_lengths" }
    elseif ($badArmReach) { $reason = "arm_reach" }
    elseif ($badArmAngle) { $reason = "arm_angle" }
    elseif ($badLegLengths) { $reason = "leg_lengths" }
    elseif ($badLegCrouch) { $reason = "leg_crouch" }
    elseif ($badLegTravel) { $reason = "leg_travel" }
    elseif ($badLegSpread) { $reason = "leg_spread" }
    elseif ($badLegAngle) { $reason = "leg_angle" }
    elseif ($badBodyStack) { $reason = "body_stack" }

    $bad = $reason -ne "ok"
    if ($bad) {
        Add-UniqueText -List $failureClasses -Value "actor-limb-anatomy-invalid"
        if ($badKeyframeSourcePose) {
            Add-UniqueText -List $failureClasses -Value "actor-keyframe-source-pose-invalid"
        }
    }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        measuredAt = (Get-Date).ToString("o")
        worldId = [string](Get-PropertyValue $Manifest "worldId")
        evidenceKind = "actor-limb-anatomy"
        status = if ($bad) { "fail" } else { "pass" }
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        manifest = Convert-ToForwardSlash $ManifestPath
        log = Convert-ToForwardSlash $LogPath
        logLine = $LineNumber
        animationStateLine = if ($null -ne $AnimationContext) { $AnimationContext.line } else { $null }
        animationSample = if ($null -ne $AnimationContext) { $AnimationContext.sample } else { $null }
        activeGroups = if ($null -ne $AnimationContext) { $AnimationContext.activeGroups } else { $null }
        animationBlendMask = if ($null -ne $AnimationContext) { $AnimationContext.primaryBlendMask } else { $null }
        animationGroup = if ($null -ne $AnimationContext) { $AnimationContext.primaryGroup } else { $null }
        animationTime = if ($null -ne $AnimationContext) { $AnimationContext.primaryTime } else { $null }
        animationSource = if ($null -ne $AnimationContext) { $AnimationContext.primarySource } else { $null }
        startCell = [string](Get-PropertyValue $Manifest "startCell")
        startSlice = [string](Get-PropertyValue $Manifest "startSlice")
        actor = $Actor
        verdict = if ($bad) { "BAD" } else { "OK" }
        reason = $reason
        shoulderSpan = Round-Number $shoulderSpan
        hipSpan = Round-Number $hipSpan
        elbowSpan = Round-Number $elbowSpan
        handSpan = Round-Number $handSpan
        handSpreadRatio = Round-Number $handSpreadRatio
        kneeSpan = Round-Number $kneeSpan
        footSpread = Round-Number $footSpread
        footSpreadRatio = Round-Number $footSpreadRatio
        leftUpperArm = Round-Number $leftUpperArm
        rightUpperArm = Round-Number $rightUpperArm
        leftForearm = Round-Number $leftForearm
        rightForearm = Round-Number $rightForearm
        leftArmReach = Round-Number $leftArmReach
        rightArmReach = Round-Number $rightArmReach
        leftArmAngle = Round-Number $leftArmAngle
        rightArmAngle = Round-Number $rightArmAngle
        leftThigh = Round-Number $leftThighLength
        rightThigh = Round-Number $rightThighLength
        leftCalf = Round-Number $leftCalfLength
        rightCalf = Round-Number $rightCalfLength
        leftLegAngle = Round-Number $leftLegAngle
        rightLegAngle = Round-Number $rightLegAngle
        leftArmFabrikUnreachableBy = Round-Number $leftArmFabrikUnreachableBy
        rightArmFabrikUnreachableBy = Round-Number $rightArmFabrikUnreachableBy
        leftLegReach = Round-Number $leftLegReach
        rightLegReach = Round-Number $rightLegReach
        leftLegFabrikUnreachableBy = Round-Number $leftLegFabrikUnreachableBy
        rightLegFabrikUnreachableBy = Round-Number $rightLegFabrikUnreachableBy
        maxFabrikUnreachableBy = Round-Number $maxFabrikUnreachableBy
        leftFootFromHip = Round-Number $leftFootFromHip
        rightFootFromHip = Round-Number $rightFootFromHip
        leftKneeFromHip = Round-Number $leftKneeFromHip
        rightKneeFromHip = Round-Number $rightKneeFromHip
        avgFootFromHip = Round-Number $avgFootFromHip
        avgKneeFromHip = Round-Number $avgKneeFromHip
        leftFootDrop = Round-Number $leftFootDrop
        rightFootDrop = Round-Number $rightFootDrop
        leftKneeDrop = Round-Number $leftKneeDrop
        rightKneeDrop = Round-Number $rightKneeDrop
        avgFootDrop = Round-Number $avgFootDrop
        avgKneeDrop = Round-Number $avgKneeDrop
        feetBelowPelvis = Round-Number $feetBelowPelvis
        headAbovePelvis = Round-Number $headAbovePelvis
        sourcePoseInvalid = $badKeyframeSourcePose
    }
}

function New-StandingUpperAuditRow(
    $Manifest,
    [string]$ManifestPath,
    [string]$LogPath,
    [int]$LineNumber,
    [string]$Actor,
    [string]$Line
) {
    $verdict = Select-TokenFromLine $Line "verdict"
    $reason = Select-TokenFromLine $Line "reason"
    if ([string]::IsNullOrWhiteSpace($verdict)) { $verdict = "BAD" }
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "missing_verdict" }
    $shoulderSpan = [double](Select-NumberFromLine $Line "shoulderSpan")
    $elbowSpan = [double](Select-NumberFromLine $Line "elbowSpan")
    $handSpan = [double](Select-NumberFromLine $Line "handSpan")
    $handSpreadRatio = [double](Select-NumberFromLine $Line "handSpreadRatio")
    $leftUpperArm = [double](Select-NumberFromLine $Line "leftUpperLength")
    $rightUpperArm = [double](Select-NumberFromLine $Line "rightUpperLength")
    $leftForearm = [double](Select-NumberFromLine $Line "leftForearmLength")
    $rightForearm = [double](Select-NumberFromLine $Line "rightForearmLength")
    $leftArmReach = [double](Select-NumberFromLine $Line "leftShoulderToHand")
    $rightArmReach = [double](Select-NumberFromLine $Line "rightShoulderToHand")
    $handMidDrop = [double](Select-NumberFromLine $Line "handMidDrop")
    $handMidPelvisZ = [double](Select-NumberFromLine $Line "handMidPelvisZ")

    $minWeaponHandSpan = [Math]::Max(18.0, $shoulderSpan * 0.65)
    $chestLevelHands = $handMidDrop -ge 8.0 -and $handMidDrop -le 28.0 -and $handMidPelvisZ -gt 6.0
    $badTightHands = $chestLevelHands -and $handSpan -lt $minWeaponHandSpan
    if ($badTightHands) {
        $verdict = "BAD"
        if ($reason -eq "ok") { $reason = "hand_collapse" }
    }
    $bad = $verdict -ne "OK"
    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    if ($bad) {
        Add-UniqueText -List $failureClasses -Value "actor-limb-anatomy-invalid"
    }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        measuredAt = (Get-Date).ToString("o")
        worldId = [string](Get-PropertyValue $Manifest "worldId")
        evidenceKind = "actor-limb-anatomy"
        limbKind = "standing-upper-body"
        status = if ($bad) { "fail" } else { "pass" }
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        manifest = Convert-ToForwardSlash $ManifestPath
        log = Convert-ToForwardSlash $LogPath
        logLine = $LineNumber
        startCell = [string](Get-PropertyValue $Manifest "startCell")
        startSlice = [string](Get-PropertyValue $Manifest "startSlice")
        actor = $Actor
        verdict = $verdict
        reason = $reason
        shoulderSpan = Round-Number $shoulderSpan
        elbowSpan = Round-Number $elbowSpan
        handSpan = Round-Number $handSpan
        handSpreadRatio = Round-Number $handSpreadRatio
        leftUpperArm = Round-Number $leftUpperArm
        rightUpperArm = Round-Number $rightUpperArm
        leftForearm = Round-Number $leftForearm
        rightForearm = Round-Number $rightForearm
        leftArmReach = Round-Number $leftArmReach
        rightArmReach = Round-Number $rightArmReach
        handMidDrop = Round-Number $handMidDrop
        handMidPelvisZ = Round-Number $handMidPelvisZ
        minWeaponHandSpan = Round-Number $minWeaponHandSpan
        chestLevelHands = $chestLevelHands
    }
}

function New-StandingLegIkAuditRow(
    $Manifest,
    [string]$ManifestPath,
    [string]$LogPath,
    [int]$LineNumber,
    [string]$Actor,
    [string]$Line
) {
    $pelvis = Select-VectorFromLine $Line "pelvis" "pelvis"
    $leftKneeTarget = Select-VectorFromLine $Line "leftKneeTarget" "leftKneeTarget"
    $rightKneeTarget = Select-VectorFromLine $Line "rightKneeTarget" "rightKneeTarget"
    $leftFootTarget = Select-VectorFromLine $Line "leftFootTarget" "leftFootTarget"
    $rightFootTarget = Select-VectorFromLine $Line "rightFootTarget" "rightFootTarget"
    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    if (-not (Test-FiniteVec3 $pelvis) -or -not (Test-FiniteVec3 $leftKneeTarget) -or -not (Test-FiniteVec3 $rightKneeTarget) `
        -or -not (Test-FiniteVec3 $leftFootTarget) -or -not (Test-FiniteVec3 $rightFootTarget)) {
        Add-UniqueText -List $failureClasses -Value "actor-limb-anatomy-invalid"
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            measuredAt = (Get-Date).ToString("o")
            worldId = [string](Get-PropertyValue $Manifest "worldId")
            evidenceKind = "actor-limb-anatomy"
            limbKind = "standing-leg-ik"
            status = "fail"
            failureClasses = @($failureClasses.ToArray())
            warningClasses = @($warningClasses.ToArray())
            manifest = Convert-ToForwardSlash $ManifestPath
            log = Convert-ToForwardSlash $LogPath
            logLine = $LineNumber
            startCell = [string](Get-PropertyValue $Manifest "startCell")
            startSlice = [string](Get-PropertyValue $Manifest "startSlice")
            actor = $Actor
            verdict = "BAD"
            reason = "missing_bone"
        }
    }

    $leftFootDrop = $pelvis.z - $leftFootTarget.z
    $rightFootDrop = $pelvis.z - $rightFootTarget.z
    $leftKneeDrop = $pelvis.z - $leftKneeTarget.z
    $rightKneeDrop = $pelvis.z - $rightKneeTarget.z
    $avgFootDrop = ($leftFootDrop + $rightFootDrop) * 0.5
    $avgKneeDrop = ($leftKneeDrop + $rightKneeDrop) * 0.5
    $leftFootFromPelvis = HorizontalDistance-Vec3 $leftFootTarget $pelvis
    $rightFootFromPelvis = HorizontalDistance-Vec3 $rightFootTarget $pelvis
    $leftKneeFromPelvis = HorizontalDistance-Vec3 $leftKneeTarget $pelvis
    $rightKneeFromPelvis = HorizontalDistance-Vec3 $rightKneeTarget $pelvis
    $avgFootFromHip = ($leftFootFromPelvis + $rightFootFromPelvis) * 0.5
    $avgKneeFromHip = ($leftKneeFromPelvis + $rightKneeFromPelvis) * 0.5
    $footSpread = Distance-Vec3 $leftFootTarget $rightFootTarget
    $kneeSpan = Distance-Vec3 $leftKneeTarget $rightKneeTarget
    $badCrouch = $avgFootDrop -lt 48.0 -or $avgFootDrop -gt 74.0 -or $avgKneeDrop -lt 18.0 -or $avgKneeDrop -gt 46.0
    $badTravel = $avgFootFromHip -gt 38.0 -or $avgKneeFromHip -gt 38.0
    $badSpread = $footSpread -gt 42.0 -or $footSpread -lt 0.5 -or $kneeSpan -gt 46.0
    $reason = if ($badCrouch) { "leg_crouch" } elseif ($badTravel) { "leg_travel" } elseif ($badSpread) { "leg_spread" } else { "ok" }
    $bad = $reason -ne "ok"
    if ($bad) {
        Add-UniqueText -List $failureClasses -Value "actor-limb-anatomy-invalid"
    }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        measuredAt = (Get-Date).ToString("o")
        worldId = [string](Get-PropertyValue $Manifest "worldId")
        evidenceKind = "actor-limb-anatomy"
        limbKind = "standing-leg-ik"
        status = if ($bad) { "fail" } else { "pass" }
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        manifest = Convert-ToForwardSlash $ManifestPath
        log = Convert-ToForwardSlash $LogPath
        logLine = $LineNumber
        startCell = [string](Get-PropertyValue $Manifest "startCell")
        startSlice = [string](Get-PropertyValue $Manifest "startSlice")
        actor = $Actor
        verdict = if ($bad) { "BAD" } else { "OK" }
        reason = $reason
        avgFootFromHip = Round-Number $avgFootFromHip
        avgKneeFromHip = Round-Number $avgKneeFromHip
        footSpread = Round-Number $footSpread
        kneeSpan = Round-Number $kneeSpan
        leftFootDrop = Round-Number $leftFootDrop
        rightFootDrop = Round-Number $rightFootDrop
        leftKneeDrop = Round-Number $leftKneeDrop
        rightKneeDrop = Round-Number $rightKneeDrop
        avgFootDrop = Round-Number $avgFootDrop
        avgKneeDrop = Round-Number $avgKneeDrop
    }
}

function New-HumanIkSourcePoseRow(
    $Manifest,
    [string]$ManifestPath,
    [string]$LogPath,
    [int]$LineNumber,
    [string]$Actor,
    [string]$Mode,
    [string]$Line
) {
    $pelvis = Select-VectorFromLine $Line "pelvis" "pelvis"
    $leftKnee = Select-VectorFromLine $Line "leftKneeBefore" "leftKneeBefore"
    $rightKnee = Select-VectorFromLine $Line "rightKneeBefore" "rightKneeBefore"
    $leftFoot = Select-VectorFromLine $Line "leftFootBefore" "leftFootBefore"
    $rightFoot = Select-VectorFromLine $Line "rightFootBefore" "rightFootBefore"
    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    if (-not (Test-FiniteVec3 $pelvis) -or -not (Test-FiniteVec3 $leftKnee) -or -not (Test-FiniteVec3 $rightKnee) `
        -or -not (Test-FiniteVec3 $leftFoot) -or -not (Test-FiniteVec3 $rightFoot)) {
        Add-UniqueText -List $failureClasses -Value "actor-limb-anatomy-invalid"
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            measuredAt = (Get-Date).ToString("o")
            worldId = [string](Get-PropertyValue $Manifest "worldId")
            evidenceKind = "actor-limb-anatomy"
            limbKind = "human-ik-source-pose"
            status = "fail"
            failureClasses = @($failureClasses.ToArray())
            warningClasses = @($warningClasses.ToArray())
            manifest = Convert-ToForwardSlash $ManifestPath
            log = Convert-ToForwardSlash $LogPath
            logLine = $LineNumber
            startCell = [string](Get-PropertyValue $Manifest "startCell")
            startSlice = [string](Get-PropertyValue $Manifest "startSlice")
            actor = $Actor
            mode = $Mode
            verdict = "BAD"
            reason = "missing_bone"
        }
    }

    $leftFootDrop = $pelvis.z - $leftFoot.z
    $rightFootDrop = $pelvis.z - $rightFoot.z
    $leftKneeDrop = $pelvis.z - $leftKnee.z
    $rightKneeDrop = $pelvis.z - $rightKnee.z
    $avgFootDrop = ($leftFootDrop + $rightFootDrop) * 0.5
    $avgKneeDrop = ($leftKneeDrop + $rightKneeDrop) * 0.5
    $leftFootFromPelvis = HorizontalDistance-Vec3 $leftFoot $pelvis
    $rightFootFromPelvis = HorizontalDistance-Vec3 $rightFoot $pelvis
    $leftKneeFromPelvis = HorizontalDistance-Vec3 $leftKnee $pelvis
    $rightKneeFromPelvis = HorizontalDistance-Vec3 $rightKnee $pelvis
    $avgFootFromPelvis = ($leftFootFromPelvis + $rightFootFromPelvis) * 0.5
    $avgKneeFromPelvis = ($leftKneeFromPelvis + $rightKneeFromPelvis) * 0.5
    $footSpread = Distance-Vec3 $leftFoot $rightFoot
    $kneeSpan = Distance-Vec3 $leftKnee $rightKnee
    $sourceFootDrop = Select-NumberFromLine $Line "sourceFootDrop"
    if ($null -eq $sourceFootDrop) {
        $sourceFootDrop = $avgFootDrop
    }
    $footDropTarget = Select-NumberFromLine $Line "footDrop"
    $legTargetsAppliedToken = Select-TokenFromLine $Line "legApplied"
    $upperAppliedToken = Select-TokenFromLine $Line "upperApplied"

    $badFeetAbovePelvis = $avgFootDrop -lt 30.0 -or $sourceFootDrop -lt 30.0
    $badKneesAbovePelvis = $avgKneeDrop -lt 4.0
    $badLegSpread = $footSpread -gt 48.0 -or $kneeSpan -gt 52.0
    $badLegTravel = $avgFootFromPelvis -gt 85.0 -or $avgKneeFromPelvis -gt 70.0
    $badNonHumanDrop = $avgFootDrop -gt 86.0 -or $avgKneeDrop -gt 58.0
    $reason = "ok"
    if ($badFeetAbovePelvis) { $reason = "source_feet_above_pelvis" }
    elseif ($badKneesAbovePelvis) { $reason = "source_knees_above_pelvis" }
    elseif ($badLegSpread) { $reason = "source_leg_spread" }
    elseif ($badLegTravel) { $reason = "source_leg_travel" }
    elseif ($badNonHumanDrop) { $reason = "source_leg_drop" }

    $bad = $reason -ne "ok"
    if ($bad) {
        Add-UniqueText -List $failureClasses -Value "actor-limb-anatomy-invalid"
        Add-UniqueText -List $failureClasses -Value "actor-keyframe-source-pose-invalid"
    }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        measuredAt = (Get-Date).ToString("o")
        worldId = [string](Get-PropertyValue $Manifest "worldId")
        evidenceKind = "actor-limb-anatomy"
        limbKind = "human-ik-source-pose"
        status = if ($bad) { "fail" } else { "pass" }
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        manifest = Convert-ToForwardSlash $ManifestPath
        log = Convert-ToForwardSlash $LogPath
        logLine = $LineNumber
        startCell = [string](Get-PropertyValue $Manifest "startCell")
        startSlice = [string](Get-PropertyValue $Manifest "startSlice")
        actor = $Actor
        mode = $Mode
        verdict = if ($bad) { "BAD" } else { "OK" }
        reason = $reason
        sourceFootDrop = Round-Number $sourceFootDrop
        requestedFootDrop = if ($null -eq $footDropTarget) { $null } else { Round-Number $footDropTarget }
        legApplied = $legTargetsAppliedToken
        upperApplied = $upperAppliedToken
        footSpread = Round-Number $footSpread
        kneeSpan = Round-Number $kneeSpan
        leftFootDrop = Round-Number $leftFootDrop
        rightFootDrop = Round-Number $rightFootDrop
        leftKneeDrop = Round-Number $leftKneeDrop
        rightKneeDrop = Round-Number $rightKneeDrop
        avgFootDrop = Round-Number $avgFootDrop
        avgKneeDrop = Round-Number $avgKneeDrop
        avgFootFromPelvis = Round-Number $avgFootFromPelvis
        avgKneeFromPelvis = Round-Number $avgKneeFromPelvis
    }
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($manifestPathItem in Get-ManifestPaths) {
    $manifest = Get-Content -LiteralPath $manifestPathItem -Raw | ConvertFrom-Json
    $logPath = [string](Get-PropertyValue $manifest "logPath")
    if ([string]::IsNullOrWhiteSpace($logPath) -or -not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        continue
    }

    $lineNumber = 0
    $animationContextByActor = @{}
    foreach ($line in Get-Content -LiteralPath $logPath) {
        ++$lineNumber
        if ($line -match "FNV/ESM4 diag: skeleton animation state") {
            $actorMatch = [regex]::Match($line, "skeleton animation state (?<actor>.+?) sample=")
            if ($actorMatch.Success) {
                $animationContextByActor[$actorMatch.Groups["actor"].Value] = Get-ActiveAnimationContext -Line $line -LineNumber $lineNumber
            }
            continue
        }

        if ($line -notmatch "FNV/ESM4 diag: skeleton anchors") {
            if ($line -match "FNV/ESM4 diag: standing upper body audit") {
                $actorMatch = [regex]::Match($line, "standing upper body audit (?<actor>.+?) pelvis=")
                if ($actorMatch.Success) {
                    $rows.Add((New-StandingUpperAuditRow -Manifest $manifest -ManifestPath $manifestPathItem `
                                -LogPath $logPath -LineNumber $lineNumber -Actor $actorMatch.Groups["actor"].Value `
                                -Line $line)) | Out-Null
                }
            }
            elseif ($line -match "FNV/ESM4 diag: human IK mode=") {
                $actorMatch = [regex]::Match($line, "human IK mode=(?<mode>[^\s]+) (?<actor>.+?) pelvis=")
                if ($actorMatch.Success) {
                    $mode = $actorMatch.Groups["mode"].Value
                    $actor = $actorMatch.Groups["actor"].Value
                    $rows.Add((New-HumanIkSourcePoseRow -Manifest $manifest -ManifestPath $manifestPathItem `
                                -LogPath $logPath -LineNumber $lineNumber -Actor $actor -Mode $mode -Line $line)) | Out-Null
                    if ($mode -eq "standing-leg") {
                        $rows.Add((New-StandingLegIkAuditRow -Manifest $manifest -ManifestPath $manifestPathItem `
                                    -LogPath $logPath -LineNumber $lineNumber -Actor $actor -Line $line)) | Out-Null
                    }
                }
            }
            continue
        }

        $actorMatch = [regex]::Match($line, "skeleton anchors (?<actor>.+?) head=")
        if (-not $actorMatch.Success) {
            continue
        }
        $actor = $actorMatch.Groups["actor"].Value
        $animationContext = if ($animationContextByActor.ContainsKey($actor)) { $animationContextByActor[$actor] } else { $null }

        $bones = @{}
        foreach ($name in @(
            "head", "pelvis",
            "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftHand", "rightHand",
            "leftThigh", "rightThigh", "leftKnee", "rightKnee", "leftFoot", "rightFoot"
        )) {
            $bones[$name] = Select-VectorFromLine $line $name $name
        }

        $rows.Add((New-LimbAnatomyRow -Manifest $manifest -ManifestPath $manifestPathItem -LogPath $logPath `
                    -LineNumber $lineNumber -Actor $actor -Bones $bones -AnimationContext $animationContext)) | Out-Null
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
    foreach ($row in @($rows.ToArray())) {
        ($row | ConvertTo-Json -Depth 10 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No actor limb anatomy rows found."
}
else {
    if ($rows.Count -gt 80) {
        @($rows.ToArray()) |
            Group-Object worldId, actor, status, reason |
            Sort-Object Count -Descending |
            Select-Object -First 40 @{ Name = "worldId"; Expression = { $_.Group[0].worldId } },
                @{ Name = "actor"; Expression = { $_.Group[0].actor } },
                @{ Name = "status"; Expression = { $_.Group[0].status } },
                @{ Name = "reason"; Expression = { $_.Group[0].reason } },
                Count |
            Format-Table -AutoSize
    }
    else {
        @($rows.ToArray()) |
            Select-Object worldId, status, actor, animationGroup, animationTime, reason, handSpreadRatio, avgFootFromHip, avgFootDrop, avgKneeDrop, logLine |
            Format-Table -AutoSize
    }
}

if (-not $NoWrite) {
    Write-Host "Wrote actor limb anatomy ledger: $OutputPath"
}
