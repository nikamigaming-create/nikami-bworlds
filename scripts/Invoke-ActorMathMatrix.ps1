param(
    [string]$WorldId = "fallout_new_vegas",
    [ValidateSet("flat", "vr")]
    [string]$Mode = "flat",
    [string]$StartSlice = "goodsprings-settler-actor-close-burst",
    [string]$OutputRoot = "run/actor-math-matrix",
    [string]$MatrixId = "",
    [int]$RunSeconds = 12,
    [int[]]$CaptureSeconds = @(10),
    [string[]]$Case = @(),
    [switch]$WithScreenshots,
    [switch]$DryRun
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

function New-CaseDefinition([string]$Id, [string]$Label, [string[]]$Env) {
    [pscustomobject][ordered]@{
        id = $Id
        label = $Label
        env = @($Env)
    }
}

function Get-DefaultCases {
    @(
        New-CaseDefinition "baseline" "default actor policy with math audits" @()
        New-CaseDefinition "manual-callbacks" "disable native callbacks and force the manual actor pose path" @("OPENMW_FNV_DISABLE_NATIVE_ANIMATION_CALLBACKS=1")
        New-CaseDefinition "old-viewer-raw-upper" "isolated viewer default: bind core/lower body, raw upper body" @("OPENMW_FNV_ROTATION_MODE=bindCoreBindLowerRawUpper")
        New-CaseDefinition "old-viewer-raw-upper-manual" "isolated viewer rotation default on the manual actor pose path" @("OPENMW_FNV_ROTATION_MODE=bindCoreBindLowerRawUpper", "OPENMW_FNV_DISABLE_NATIVE_ANIMATION_CALLBACKS=1")
        New-CaseDefinition "rot-bind-upper" "current default rotation mode made explicit" @("OPENMW_FNV_ROTATION_MODE=bindCoreBindLowerBindUpper")
        New-CaseDefinition "rot-standing-upper" "standing upper body split-key mode" @("OPENMW_FNV_ROTATION_MODE=standingUpperBody")
        New-CaseDefinition "rot-raw-key" "use key rotation without runtime bind composition" @("OPENMW_FNV_ROTATION_MODE=rawKey")
        New-CaseDefinition "rot-bind-then-key" "compose bind then key in runtime pose path" @("OPENMW_FNV_ROTATION_MODE=bindThenKey")
        New-CaseDefinition "controller-raw" "controller actor basis uses raw key rotations" @("OPENMW_ESM4_ACTOR_ROTATION_COMPOSITION=raw")
        New-CaseDefinition "controller-upper-default-lower-bind" "allow controller upper-body key rotations while keeping baked lower-body bind" @("OPENMW_ESM4_PIN_ACTOR_BIND_ROTATION=0")
        New-CaseDefinition "controller-upper-raw-lower-bind" "allow controller upper-body raw key rotations while keeping baked lower-body bind" @("OPENMW_ESM4_PIN_ACTOR_BIND_ROTATION=0", "OPENMW_ESM4_ACTOR_ROTATION_COMPOSITION=raw")
        New-CaseDefinition "controller-upper-raw-bind-lower-bind" "allow controller upper-body raw then bind rotations while keeping baked lower-body bind" @("OPENMW_ESM4_PIN_ACTOR_BIND_ROTATION=0", "OPENMW_ESM4_ACTOR_ROTATION_COMPOSITION=rawBind")
        New-CaseDefinition "controller-upper-bind-raw-lower-bind" "allow controller upper-body bind then raw rotations while keeping baked lower-body bind" @("OPENMW_ESM4_PIN_ACTOR_BIND_ROTATION=0", "OPENMW_ESM4_ACTOR_ROTATION_COMPOSITION=bindRaw")
        New-CaseDefinition "standing-arm-ik" "apply standing upper-limb IK with the current actor policy" @("OPENMW_ESM4_STANDING_ARM_IK=1")
        New-CaseDefinition "controller-raw-standing-arm-ik" "raw controller actor basis plus standing upper-limb IK" @("OPENMW_ESM4_ACTOR_ROTATION_COMPOSITION=raw", "OPENMW_ESM4_STANDING_ARM_IK=1")
        New-CaseDefinition "no-weapon-idle-pose" "keep neutral locomotion idle instead of forcing weapon idle pose" @("OPENMW_ESM4_ENABLE_WEAPON_IDLE_POSE=0", "OPENMW_FNV_ENABLE_WEAPON_IDLE_POSE=0")
        New-CaseDefinition "no-weapon-idle-no-weapon-ik" "keep neutral locomotion idle and disable FNV grip IK" @("OPENMW_ESM4_ENABLE_WEAPON_IDLE_POSE=0", "OPENMW_FNV_ENABLE_WEAPON_IDLE_POSE=0", "OPENMW_FNV_DISABLE_WEAPON_IK=1")
        New-CaseDefinition "disable-weapon-ik" "disable FNV grip IK while keeping the rest of policy intact" @("OPENMW_FNV_DISABLE_WEAPON_IK=1")
        New-CaseDefinition "weapon-ik-soft" "keep weapon IK but reduce arm/clavicle strength" @("OPENMW_FNV_DISABLE_WEAPON_IK=", "OPENMW_FNV_WEAPON_IK=1", "OPENMW_FNV_WEAPON_IK_STRENGTH=0.55", "OPENMW_FNV_WEAPON_IK_CLAVICLE_STRENGTH=0.04")
        New-CaseDefinition "weapon-ik-low-ready" "keep weapon IK but lower and shorten grip targets" @("OPENMW_FNV_DISABLE_WEAPON_IK=", "OPENMW_FNV_WEAPON_IK=1", "OPENMW_FNV_WEAPON_IK_RIGHT_FORWARD=18", "OPENMW_FNV_WEAPON_IK_LEFT_FORWARD=14", "OPENMW_FNV_WEAPON_IK_RIGHT_SIDE=8", "OPENMW_FNV_WEAPON_IK_LEFT_SIDE=6", "OPENMW_FNV_WEAPON_IK_RIGHT_DROP=10", "OPENMW_FNV_WEAPON_IK_LEFT_DROP=8")
        New-CaseDefinition "weapon-ik-hand-orientation" "test automatic explicit hand orientation against grip forward/palm targets" @("OPENMW_FNV_DISABLE_WEAPON_IK=", "OPENMW_FNV_WEAPON_IK=1", "OPENMW_FNV_ENABLE_WEAPON_IK_HAND_ORIENTATION=1")
        New-CaseDefinition "weapon-ik-low-ready-auto-hand" "test low-ready targets plus automatic explicit hand orientation" @("OPENMW_FNV_DISABLE_WEAPON_IK=", "OPENMW_FNV_WEAPON_IK=1", "OPENMW_FNV_ENABLE_WEAPON_IK_HAND_ORIENTATION=1", "OPENMW_FNV_WEAPON_IK_RIGHT_FORWARD=18", "OPENMW_FNV_WEAPON_IK_LEFT_FORWARD=14", "OPENMW_FNV_WEAPON_IK_RIGHT_SIDE=8", "OPENMW_FNV_WEAPON_IK_LEFT_SIDE=6", "OPENMW_FNV_WEAPON_IK_RIGHT_DROP=10", "OPENMW_FNV_WEAPON_IK_LEFT_DROP=8")
        New-CaseDefinition "weapon-ik-class-grip-forced-hand" "test class-specific low-ready targets and forced hand grip axes" @("OPENMW_FNV_DISABLE_WEAPON_IK=", "OPENMW_FNV_WEAPON_IK=1", "OPENMW_FNV_ENABLE_WEAPON_IK_HAND_ORIENTATION=1", "OPENMW_FNV_WEAPON_IK_LONG_GUN_RIGHT_FORWARD=18", "OPENMW_FNV_WEAPON_IK_LONG_GUN_LEFT_FORWARD=14", "OPENMW_FNV_WEAPON_IK_LONG_GUN_RIGHT_SIDE=8", "OPENMW_FNV_WEAPON_IK_LONG_GUN_LEFT_SIDE=6", "OPENMW_FNV_WEAPON_IK_LONG_GUN_RIGHT_DROP=10", "OPENMW_FNV_WEAPON_IK_LONG_GUN_LEFT_DROP=8", "OPENMW_FNV_WEAPON_IK_SIDEARM_RIGHT_FORWARD=18", "OPENMW_FNV_WEAPON_IK_SIDEARM_LEFT_FORWARD=14", "OPENMW_FNV_WEAPON_IK_SIDEARM_RIGHT_SIDE=8", "OPENMW_FNV_WEAPON_IK_SIDEARM_LEFT_SIDE=6", "OPENMW_FNV_WEAPON_IK_SIDEARM_RIGHT_DROP=10", "OPENMW_FNV_WEAPON_IK_SIDEARM_LEFT_DROP=8", "OPENMW_FNV_WEAPON_IK_LONG_GUN_RIGHT_HAND_ORIENTATION=+X/+Y", "OPENMW_FNV_WEAPON_IK_LONG_GUN_LEFT_HAND_ORIENTATION=+Z/+Y", "OPENMW_FNV_WEAPON_IK_SIDEARM_RIGHT_HAND_ORIENTATION=-Y/+X", "OPENMW_FNV_WEAPON_IK_SIDEARM_LEFT_HAND_ORIENTATION=-Y/-Z")
        New-CaseDefinition "enable-fallout-weapon-ik" "enable the FNV weapon grip IK path for Fallout-family targets that do not set it in policy" @("OPENMW_FNV_DISABLE_WEAPON_IK=", "OPENMW_FNV_WEAPON_IK=1")
        New-CaseDefinition "controller-raw-bind" "controller actor basis composes raw then bind" @("OPENMW_ESM4_ACTOR_ROTATION_COMPOSITION=rawBind")
        New-CaseDefinition "controller-bind-raw" "controller actor basis composes bind then raw" @("OPENMW_ESM4_ACTOR_ROTATION_COMPOSITION=bindRaw")
        New-CaseDefinition "freeze-idle" "freeze idle controller advance" @("OPENMW_FNV_FREEZE_IDLE_ANIM=1")
        New-CaseDefinition "disable-idle-seed" "disable synthetic idle seed" @("OPENMW_FNV_DISABLE_IDLE_SEED=1")
        New-CaseDefinition "pin-bind-rotation" "pin actor basis bind rotations" @("OPENMW_ESM4_PIN_ACTOR_BIND_ROTATION=1")
        New-CaseDefinition "pin-bind-freeze-idle" "pin bind rotations and freeze idle" @("OPENMW_ESM4_PIN_ACTOR_BIND_ROTATION=1", "OPENMW_FNV_FREEZE_IDLE_ANIM=1")
        New-CaseDefinition "no-rig-heuristic" "disable ESM4 rig heuristic" @("OPENMW_ESM4_ENABLE_RIG_HEURISTIC=0")
        New-CaseDefinition "no-kf-source" "clear actor KF source environment" @("OPENMW_WORLD_VIEWER_NPC_ANIMATION_SOURCES=")
        New-CaseDefinition "keep-key-translations" "allow Fallout actor KF translations from animation data" @("OPENMW_ESM4_DROP_ACTOR_KEY_TRANSLATIONS=0")
        New-CaseDefinition "pin-key-translations" "pin Fallout actor KF translations to bind pose" @("OPENMW_ESM4_PIN_ACTOR_KEY_TRANSLATIONS_TO_BIND=1")
        New-CaseDefinition "drop-key-translations" "drop Fallout actor KF translations and keep skeleton offsets" @("OPENMW_ESM4_DROP_ACTOR_KEY_TRANSLATIONS=1")
        New-CaseDefinition "drop-translations-pin-lower" "drop key translations and pin lower-body rotations to bind" @("OPENMW_ESM4_DROP_ACTOR_KEY_TRANSLATIONS=1", "OPENMW_ESM4_PIN_ACTOR_LOWER_BODY_BIND_ROTATION=1")
        New-CaseDefinition "drop-translations-standing-leg-ik" "drop key translations and post-solve standing lower legs" @("OPENMW_ESM4_DROP_ACTOR_KEY_TRANSLATIONS=1", "OPENMW_ESM4_STANDING_LEG_IK=1")
    )
}

function Select-Cases([string[]]$RequestedCases) {
    $allCases = @(Get-DefaultCases)
    if ($RequestedCases.Count -eq 0) {
        return $allCases
    }

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($RequestedCases)) {
        $match = @($allCases | Where-Object { [string]::Equals($_.id, $name, [StringComparison]::OrdinalIgnoreCase) })
        if ($match.Count -ne 1) {
            $known = (@($allCases | ForEach-Object { $_.id }) -join ", ")
            throw "Unknown actor math matrix case '$name'. Known cases: $known"
        }
        $selected.Add($match[0]) | Out-Null
    }
    return @($selected.ToArray())
}

$script:VectorPattern = "\(\s*(?<{0}x>[-+0-9.eE]+)\s*,\s*(?<{0}y>[-+0-9.eE]+)\s*,\s*(?<{0}z>[-+0-9.eE]+)\s*\)"

function Select-VectorFromLine([string]$Line, [string]$Name, [string]$Prefix) {
    $pattern = [string]::Format($script:VectorPattern, $Prefix)
    $match = [regex]::Match($Line, "(?<![A-Za-z0-9_])" + [regex]::Escape($Name) + "\s*=\s*" + $pattern)
    if (-not $match.Success) {
        return $null
    }
    [pscustomobject][ordered]@{
        x = [double]::Parse([string]$match.Groups["${Prefix}x"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        y = [double]::Parse([string]$match.Groups["${Prefix}y"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        z = [double]::Parse([string]$match.Groups["${Prefix}z"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

function Measure-RootSamples([string]$LogPath) {
    $samples = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            count = 0
            feetAboveCount = 0
            firstFeetAboveLine = $null
            minFootMidMinusPelvisZ = $null
            maxFootMidMinusPelvisZ = $null
            firstFeetAboveActor = $null
            firstFeetAboveRootMinusPelvisZ = $null
        }
    }

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $LogPath) {
        ++$lineNumber
        if ($line -notmatch "FNV/ESM4 ACTOR ROOT ATTACHMENT AUDIT") {
            continue
        }
        $actorMatch = [regex]::Match($line, "AUDIT (?<actor>.+?) root=")
        $foot = Select-VectorFromLine -Line $line -Name "footMidMinusPelvis" -Prefix "foot"
        $rootMinus = Select-VectorFromLine -Line $line -Name "rootMinusPelvis" -Prefix "rootMinus"
        if ($null -eq $foot) {
            continue
        }
        $samples.Add([pscustomobject][ordered]@{
            line = $lineNumber
            actor = if ($actorMatch.Success) { $actorMatch.Groups["actor"].Value } else { "" }
            footMidMinusPelvisZ = $foot.z
            rootMinusPelvisZ = if ($null -ne $rootMinus) { $rootMinus.z } else { $null }
        }) | Out-Null
    }

    $feetAbove = @($samples.ToArray() | Where-Object { $_.footMidMinusPelvisZ -ge 0.0 })
    $firstFeetAbove = if ($feetAbove.Count -gt 0) { $feetAbove[0] } else { $null }
    $footZValues = @($samples.ToArray() | ForEach-Object { $_.footMidMinusPelvisZ })
    [pscustomobject][ordered]@{
        count = $samples.Count
        feetAboveCount = $feetAbove.Count
        firstFeetAboveLine = if ($null -ne $firstFeetAbove) { $firstFeetAbove.line } else { $null }
        minFootMidMinusPelvisZ = if ($footZValues.Count -gt 0) { [Math]::Round(($footZValues | Measure-Object -Minimum).Minimum, 3) } else { $null }
        maxFootMidMinusPelvisZ = if ($footZValues.Count -gt 0) { [Math]::Round(($footZValues | Measure-Object -Maximum).Maximum, 3) } else { $null }
        firstFeetAboveActor = if ($null -ne $firstFeetAbove) { $firstFeetAbove.actor } else { $null }
        firstFeetAboveRootMinusPelvisZ = if ($null -ne $firstFeetAbove -and $null -ne $firstFeetAbove.rootMinusPelvisZ) { [Math]::Round($firstFeetAbove.rootMinusPelvisZ, 3) } else { $null }
    }
}

function Read-FirstJsonLine([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $line = Get-Content -LiteralPath $Path -TotalCount 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        return $null
    }
    return ($line | ConvertFrom-Json)
}

function Summarize-Fabrik([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            rowCount = 0
            explodedCount = 0
            suspectCount = 0
            nearHandCount = 0
            maxHandAnchorError = $null
            maxUnreachableBy = $null
            explodedTargets = @()
        }
    }

    $rows = @(Get-Content -LiteralPath $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    if ($rows.Count -eq 0) {
        return [pscustomobject][ordered]@{
            rowCount = 0
            explodedCount = 0
            suspectCount = 0
            nearHandCount = 0
            maxHandAnchorError = $null
            maxUnreachableBy = $null
            explodedTargets = @()
        }
    }

    $exploded = @($rows | Where-Object { $_.verdict -eq "exploded" })
    $suspect = @($rows | Where-Object { $_.verdict -eq "suspect" })
    $nearHand = @($rows | Where-Object { $_.verdict -eq "near-hand" })
    $explodedTargets = @($exploded | Group-Object side, target | ForEach-Object { "$($_.Group[0].side):$($_.Group[0].target)" } | Sort-Object -Unique)
    [pscustomobject][ordered]@{
        rowCount = $rows.Count
        explodedCount = $exploded.Count
        suspectCount = $suspect.Count
        nearHandCount = $nearHand.Count
        maxHandAnchorError = [Math]::Round((@($rows) | ForEach-Object { $_.handAnchorError } | Measure-Object -Maximum).Maximum, 3)
        maxUnreachableBy = [Math]::Round((@($rows) | ForEach-Object { $_.unreachableBy } | Measure-Object -Maximum).Maximum, 3)
        explodedTargets = @($explodedTargets)
    }
}

function Summarize-WeaponIk([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            rowCount = 0
            passCount = 0
            failCount = 0
            questionableCount = 0
            maxAimAfter = $null
            maxRightTargetAfter = $null
            maxLeftTargetAfter = $null
            maxHandForwardAngle = $null
            maxHandOrientationForwardError = $null
            maxHandOrientationPalmError = $null
            failureClasses = @()
            warningClasses = @()
        }
    }

    $rows = @(Get-Content -LiteralPath $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    if ($rows.Count -eq 0) {
        return [pscustomobject][ordered]@{
            rowCount = 0
            passCount = 0
            failCount = 0
            questionableCount = 0
            maxAimAfter = $null
            maxRightTargetAfter = $null
            maxLeftTargetAfter = $null
            maxHandForwardAngle = $null
            maxHandOrientationForwardError = $null
            maxHandOrientationPalmError = $null
            failureClasses = @()
            warningClasses = @()
        }
    }

    $rightTargetValues = @($rows | ForEach-Object { if ($null -ne $_.targetDistancesAfter) { $_.targetDistancesAfter.x } })
    $leftTargetValues = @($rows | ForEach-Object { if ($null -ne $_.targetDistancesAfter) { $_.targetDistancesAfter.y } })
    $handForwardAngles = @($rows | ForEach-Object {
        if ($null -ne $_.handForwardAngles) {
            $_.handForwardAngles.x
            $_.handForwardAngles.y
        }
    })
    $handOrientationForwardErrors = @($rows | ForEach-Object {
        if ($null -ne $_.handOrientationErrors) {
            $_.handOrientationErrors.rightForward
            $_.handOrientationErrors.leftForward
        }
    })
    $handOrientationPalmErrors = @($rows | ForEach-Object {
        if ($null -ne $_.handOrientationErrors) {
            $_.handOrientationErrors.rightPalm
            $_.handOrientationErrors.leftPalm
        }
    })
    [pscustomobject][ordered]@{
        rowCount = $rows.Count
        passCount = @($rows | Where-Object { $_.status -eq "pass" }).Count
        failCount = @($rows | Where-Object { $_.status -eq "fail" }).Count
        questionableCount = @($rows | Where-Object { $_.status -eq "questionable" }).Count
        maxAimAfter = [Math]::Round((@($rows) | ForEach-Object { $_.weaponAimAngleAfter } | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum, 3)
        maxRightTargetAfter = if ($rightTargetValues.Count -gt 0) { [Math]::Round(($rightTargetValues | Measure-Object -Maximum).Maximum, 3) } else { $null }
        maxLeftTargetAfter = if ($leftTargetValues.Count -gt 0) { [Math]::Round(($leftTargetValues | Measure-Object -Maximum).Maximum, 3) } else { $null }
        maxHandForwardAngle = if ($handForwardAngles.Count -gt 0) { [Math]::Round(($handForwardAngles | Measure-Object -Maximum).Maximum, 3) } else { $null }
        maxHandOrientationForwardError = if ($handOrientationForwardErrors.Count -gt 0) { [Math]::Round(($handOrientationForwardErrors | Measure-Object -Maximum).Maximum, 3) } else { $null }
        maxHandOrientationPalmError = if ($handOrientationPalmErrors.Count -gt 0) { [Math]::Round(($handOrientationPalmErrors | Measure-Object -Maximum).Maximum, 3) } else { $null }
        failureClasses = @($rows | ForEach-Object { @($_.failureClasses) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        warningClasses = @($rows | ForEach-Object { @($_.warningClasses) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    }
}

$matrixStamp = if ([string]::IsNullOrWhiteSpace($MatrixId)) {
    (Get-Date).ToString("yyyyMMdd-HHmmss")
} else {
    $MatrixId
}

$matrixRoot = Resolve-RepoRelativePath (Join-Path $OutputRoot $matrixStamp)
New-Item -ItemType Directory -Force -Path $matrixRoot | Out-Null

$cases = @(Select-Cases -RequestedCases $Case)
$commonEnv = @(
    "OPENMW_FNV_PART_MATRIX_AUDIT=1",
    "OPENMW_FNV_ACTOR_BASIS_AUDIT=1",
    "OPENMW_ESM4_ACTOR_BASIS_AUDIT=1",
    "OPENMW_ESM4_ROOT_ATTACHMENT_AUDIT=1",
    "OPENMW_PROOF_POSTURE_TARGET=player",
    "OPENMW_PROOF_POSTURE_SAMPLES=8"
)

$summaryPath = Join-Path $matrixRoot "summary.jsonl"
if (Test-Path -LiteralPath $summaryPath) {
    Remove-Item -LiteralPath $summaryPath -Force
}

$summaryRows = New-Object System.Collections.Generic.List[object]
foreach ($caseDefinition in @($cases)) {
    $caseRoot = Join-Path $matrixRoot $caseDefinition.id
    New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
    $env = @($commonEnv + $caseDefinition.env)
    Write-Host "=== Actor math case: $($caseDefinition.id) :: $($caseDefinition.label)"
    Write-Host ("env: " + (@($env) -join ", "))

    $invokeArgs = @{
        Mode = $Mode
        WorldId = @($WorldId)
        StartSlice = $StartSlice
        UseActorAnimationPolicyEnvironment = $true
        RunSeconds = $RunSeconds
        OutputRoot = $caseRoot
        SetEnv = @($env)
    }
    if ($CaptureSeconds.Count -gt 0) {
        $invokeArgs["CaptureSeconds"] = @($CaptureSeconds)
    }
    if (-not $WithScreenshots) {
        $invokeArgs["NoEngineScreenshot"] = $true
    }
    if ($DryRun) {
        $invokeArgs["DryRun"] = $true
    }

    & (Join-Path $PSScriptRoot "Invoke-RealWorldScreenshots.ps1") @invokeArgs

    $manifest = @(Get-ChildItem -LiteralPath $caseRoot -Recurse -Filter "manifest.json" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($manifest.Count -ne 1) {
        throw "Expected exactly one latest manifest for case '$($caseDefinition.id)' under $caseRoot."
    }

    if ($DryRun) {
        $manifestJson = Get-Content -LiteralPath $manifest[0].FullName -Raw | ConvertFrom-Json
        $summaryRow = [pscustomobject][ordered]@{
            schemaVersion = 1
            measuredAt = (Get-Date).ToString("o")
            matrixId = $matrixStamp
            caseId = $caseDefinition.id
            label = $caseDefinition.label
            worldId = $WorldId
            startSlice = $StartSlice
            manifest = Convert-ToForwardSlash $manifest[0].FullName
            log = Convert-ToForwardSlash ([string](Get-PropertyValue $manifestJson "logPath"))
            env = @($env)
            rootStatus = "dry-run"
            rootReason = "telemetry-not-run"
            rootAuditCount = 0
            feetAbovePelvisCount = 0
            averageFootMidMinusPelvisZ = $null
            minFootMidMinusPelvisZ = $null
            maxFootMidMinusPelvisZ = $null
            firstFeetAboveLine = $null
            firstFeetAboveActor = $null
            firstFeetAboveRootMinusPelvisZ = $null
            renderStatus = "dry-run"
            renderInvalidRatio = $null
            renderGoodCount = $null
            sourceGoodCount = $null
            liveGoodCount = $null
            basisStatus = "dry-run"
            basisReason = "telemetry-not-run"
            basisAuditCount = 0
            basisLargeRotationDeltaCount = 0
            basisMaxRotationDeltaDegrees = $null
            basisMaxRotationDeltaBone = $null
            fabrikRowCount = 0
            fabrikExplodedCount = 0
            fabrikSuspectCount = 0
            fabrikNearHandCount = 0
            fabrikMaxHandAnchorError = $null
            fabrikMaxUnreachableBy = $null
            fabrikExplodedTargets = @()
            weaponIkRowCount = 0
            weaponIkPassCount = 0
            weaponIkFailCount = 0
            weaponIkQuestionableCount = 0
            weaponIkMaxAimAfter = $null
            weaponIkMaxRightTargetAfter = $null
            weaponIkMaxLeftTargetAfter = $null
            weaponIkMaxHandForwardAngle = $null
            weaponIkMaxHandOrientationForwardError = $null
            weaponIkMaxHandOrientationPalmError = $null
            weaponIkFailureClasses = @()
            weaponIkWarningClasses = @()
            rootLedger = $null
            renderLedger = $null
            basisLedger = $null
            fabrikLedger = $null
            weaponIkLedger = $null
        }
        ($summaryRow | ConvertTo-Json -Depth 10 -Compress) | Add-Content -LiteralPath $summaryPath -Encoding ASCII
        $summaryRows.Add($summaryRow) | Out-Null
        continue
    }

    $rootLedger = Join-Path $caseRoot "actor-root-attachment-telemetry.jsonl"
    $renderLedger = Join-Path $caseRoot "actor-render-live-telemetry.jsonl"
    $basisLedger = Join-Path $caseRoot "actor-basis-telemetry.jsonl"
    $fabrikLedger = Join-Path $caseRoot "actor-fabrik-telemetry.jsonl"
    $weaponIkLedger = Join-Path $caseRoot "actor-weapon-ik-telemetry.jsonl"

    & (Join-Path $PSScriptRoot "Measure-ActorRootAttachmentTelemetry.ps1") -ManifestPath $manifest[0].FullName -OutputPath $rootLedger
    & (Join-Path $PSScriptRoot "Measure-ActorRenderLiveTelemetry.ps1") -ManifestPath $manifest[0].FullName -OutputPath $renderLedger
    & (Join-Path $PSScriptRoot "Measure-ActorBasisTelemetry.ps1") -ManifestPath $manifest[0].FullName -OutputPath $basisLedger
    & (Join-Path $PSScriptRoot "Measure-ActorFabrikTelemetry.ps1") -ManifestPath $manifest[0].FullName -OutputPath $fabrikLedger
    & (Join-Path $PSScriptRoot "Measure-ActorWeaponIkTelemetry.ps1") -ManifestPath $manifest[0].FullName -OutputPath $weaponIkLedger

    $manifestJson = Get-Content -LiteralPath $manifest[0].FullName -Raw | ConvertFrom-Json
    $rootRow = Read-FirstJsonLine $rootLedger
    $renderRow = Read-FirstJsonLine $renderLedger
    $basisRow = Read-FirstJsonLine $basisLedger
    $fabrikSummary = Summarize-Fabrik $fabrikLedger
    $weaponIkSummary = Summarize-WeaponIk $weaponIkLedger
    $rootSamples = Measure-RootSamples ([string](Get-PropertyValue $manifestJson "logPath"))

    $summaryRow = [pscustomobject][ordered]@{
        schemaVersion = 1
        measuredAt = (Get-Date).ToString("o")
        matrixId = $matrixStamp
        caseId = $caseDefinition.id
        label = $caseDefinition.label
        worldId = $WorldId
        startSlice = $StartSlice
        manifest = Convert-ToForwardSlash $manifest[0].FullName
        log = Convert-ToForwardSlash ([string](Get-PropertyValue $manifestJson "logPath"))
        env = @($env)
        rootStatus = if ($null -ne $rootRow) { $rootRow.status } else { $null }
        rootReason = if ($null -ne $rootRow) { $rootRow.reason } else { $null }
        rootAuditCount = if ($null -ne $rootRow) { $rootRow.rootAuditCount } else { $rootSamples.count }
        feetAbovePelvisCount = if ($null -ne $rootRow) { $rootRow.feetAbovePelvisCount } else { $rootSamples.feetAboveCount }
        averageFootMidMinusPelvisZ = if ($null -ne $rootRow) { $rootRow.averageFootMidMinusPelvisZ } else { $null }
        minFootMidMinusPelvisZ = $rootSamples.minFootMidMinusPelvisZ
        maxFootMidMinusPelvisZ = $rootSamples.maxFootMidMinusPelvisZ
        firstFeetAboveLine = $rootSamples.firstFeetAboveLine
        firstFeetAboveActor = $rootSamples.firstFeetAboveActor
        firstFeetAboveRootMinusPelvisZ = $rootSamples.firstFeetAboveRootMinusPelvisZ
        renderStatus = if ($null -ne $renderRow) { $renderRow.status } else { $null }
        renderInvalidRatio = if ($null -ne $renderRow) { $renderRow.renderInvalidRatio } else { $null }
        renderGoodCount = if ($null -ne $renderRow) { $renderRow.renderGoodCount } else { $null }
        sourceGoodCount = if ($null -ne $renderRow) { $renderRow.sourceGoodCount } else { $null }
        liveGoodCount = if ($null -ne $renderRow) { $renderRow.liveGoodCount } else { $null }
        basisStatus = if ($null -ne $basisRow) { $basisRow.status } else { $null }
        basisReason = if ($null -ne $basisRow) { $basisRow.reason } else { $null }
        basisAuditCount = if ($null -ne $basisRow) { $basisRow.basisAuditCount } else { $null }
        basisLargeRotationDeltaCount = if ($null -ne $basisRow) { $basisRow.largeRotationDeltaCount } else { $null }
        basisMaxRotationDeltaDegrees = if ($null -ne $basisRow) { $basisRow.maxRotationDeltaDegrees } else { $null }
        basisMaxRotationDeltaBone = if ($null -ne $basisRow) { $basisRow.maxRotationDeltaBone } else { $null }
        fabrikRowCount = $fabrikSummary.rowCount
        fabrikExplodedCount = $fabrikSummary.explodedCount
        fabrikSuspectCount = $fabrikSummary.suspectCount
        fabrikNearHandCount = $fabrikSummary.nearHandCount
        fabrikMaxHandAnchorError = $fabrikSummary.maxHandAnchorError
        fabrikMaxUnreachableBy = $fabrikSummary.maxUnreachableBy
        fabrikExplodedTargets = @($fabrikSummary.explodedTargets)
        weaponIkRowCount = $weaponIkSummary.rowCount
        weaponIkPassCount = $weaponIkSummary.passCount
        weaponIkFailCount = $weaponIkSummary.failCount
        weaponIkQuestionableCount = $weaponIkSummary.questionableCount
        weaponIkMaxAimAfter = $weaponIkSummary.maxAimAfter
        weaponIkMaxRightTargetAfter = $weaponIkSummary.maxRightTargetAfter
        weaponIkMaxLeftTargetAfter = $weaponIkSummary.maxLeftTargetAfter
        weaponIkMaxHandForwardAngle = $weaponIkSummary.maxHandForwardAngle
        weaponIkMaxHandOrientationForwardError = $weaponIkSummary.maxHandOrientationForwardError
        weaponIkMaxHandOrientationPalmError = $weaponIkSummary.maxHandOrientationPalmError
        weaponIkFailureClasses = @($weaponIkSummary.failureClasses)
        weaponIkWarningClasses = @($weaponIkSummary.warningClasses)
        rootLedger = Convert-ToForwardSlash $rootLedger
        renderLedger = Convert-ToForwardSlash $renderLedger
        basisLedger = Convert-ToForwardSlash $basisLedger
        fabrikLedger = Convert-ToForwardSlash $fabrikLedger
        weaponIkLedger = Convert-ToForwardSlash $weaponIkLedger
    }

    ($summaryRow | ConvertTo-Json -Depth 10 -Compress) | Add-Content -LiteralPath $summaryPath -Encoding ASCII
    $summaryRows.Add($summaryRow) | Out-Null
}

@($summaryRows.ToArray()) |
    Select-Object caseId, rootStatus, feetAbovePelvisCount, minFootMidMinusPelvisZ, maxFootMidMinusPelvisZ, firstFeetAboveLine, renderInvalidRatio, sourceGoodCount, liveGoodCount, basisStatus, basisLargeRotationDeltaCount, basisMaxRotationDeltaDegrees, basisMaxRotationDeltaBone, fabrikExplodedCount, fabrikNearHandCount, weaponIkRowCount, weaponIkFailCount, weaponIkQuestionableCount, weaponIkMaxAimAfter, weaponIkMaxRightTargetAfter, weaponIkMaxLeftTargetAfter, weaponIkMaxHandForwardAngle, weaponIkMaxHandOrientationForwardError, weaponIkMaxHandOrientationPalmError |
    Format-Table -AutoSize

Write-Host "Wrote actor math matrix summary: $summaryPath"
