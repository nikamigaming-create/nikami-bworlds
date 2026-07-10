param(
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/actor-fabrik-telemetry.jsonl",
    [int]$Iterations = 24,
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

function Add-UniqueText([System.Collections.Generic.List[string]]$List, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    if (-not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function New-Vec3([double]$X, [double]$Y, [double]$Z) {
    [pscustomobject][ordered]@{ x = $X; y = $Y; z = $Z }
}

function Add-Vec3($A, $B) { New-Vec3 ($A.x + $B.x) ($A.y + $B.y) ($A.z + $B.z) }
function Sub-Vec3($A, $B) { New-Vec3 ($A.x - $B.x) ($A.y - $B.y) ($A.z - $B.z) }
function Mul-Vec3($A, [double]$Scale) { New-Vec3 ($A.x * $Scale) ($A.y * $Scale) ($A.z * $Scale) }
function Length-Vec3($A) { [Math]::Sqrt($A.x * $A.x + $A.y * $A.y + $A.z * $A.z) }
function Distance-Vec3($A, $B) { Length-Vec3 (Sub-Vec3 $A $B) }

function Normalize-Vec3($A) {
    $length = Length-Vec3 $A
    if ($length -le 0.000001) {
        return New-Vec3 0 0 0
    }
    return Mul-Vec3 $A (1.0 / $length)
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

function Invoke-Fabrik3([object[]]$Points, $Target, [int]$IterationCount) {
    $root = New-Vec3 $Points[0].x $Points[0].y $Points[0].z
    $lengths = @(
        Distance-Vec3 $Points[0] $Points[1]
        Distance-Vec3 $Points[1] $Points[2]
    )
    $totalLength = ($lengths | Measure-Object -Sum).Sum
    $rootToTarget = Distance-Vec3 $root $Target

    $solved = @(
        New-Vec3 $Points[0].x $Points[0].y $Points[0].z
        New-Vec3 $Points[1].x $Points[1].y $Points[1].z
        New-Vec3 $Points[2].x $Points[2].y $Points[2].z
    )

    if ($rootToTarget -gt $totalLength) {
        $direction = Normalize-Vec3 (Sub-Vec3 $Target $root)
        $solved[1] = Add-Vec3 $solved[0] (Mul-Vec3 $direction $lengths[0])
        $solved[2] = Add-Vec3 $solved[1] (Mul-Vec3 $direction $lengths[1])
    }
    else {
        for ($i = 0; $i -lt $IterationCount; ++$i) {
            $solved[2] = New-Vec3 $Target.x $Target.y $Target.z
            for ($j = 1; $j -ge 0; --$j) {
                $direction = Normalize-Vec3 (Sub-Vec3 $solved[$j] $solved[$j + 1])
                $solved[$j] = Add-Vec3 $solved[$j + 1] (Mul-Vec3 $direction $lengths[$j])
            }

            $solved[0] = New-Vec3 $root.x $root.y $root.z
            for ($j = 0; $j -lt 2; ++$j) {
                $direction = Normalize-Vec3 (Sub-Vec3 $solved[$j + 1] $solved[$j])
                $solved[$j + 1] = Add-Vec3 $solved[$j] (Mul-Vec3 $direction $lengths[$j])
            }
        }
    }

    $residual = Distance-Vec3 $solved[2] $Target
    [pscustomobject][ordered]@{
        rootToTarget = [Math]::Round($rootToTarget, 4)
        chainLength = [Math]::Round($totalLength, 4)
        unreachableBy = [Math]::Round([Math]::Max(0.0, $rootToTarget - $totalLength), 4)
        residual = [Math]::Round($residual, 4)
        solvedElbow = $solved[1]
        solvedHand = $solved[2]
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

function Get-HandChain($Anchors, [string]$Side) {
    if ($Side -eq "leftHand" -or $Side -eq "left") {
        return @($Anchors.leftShoulder, $Anchors.leftElbow, $Anchors.leftHand)
    }
    return @($Anchors.rightShoulder, $Anchors.rightElbow, $Anchors.rightHand)
}

function Test-VectorPresent($Value) {
    return $null -ne $Value -and -not [double]::IsNaN([double]$Value.x) -and -not [double]::IsNaN([double]$Value.y) -and -not [double]::IsNaN([double]$Value.z)
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

function Get-FabrikStatus([string]$Verdict, [string]$TargetName) {
    if ($TargetName -eq "anchor") {
        return "pass"
    }
    if ($Verdict -eq "exploded") {
        return "fail"
    }
    if ($Verdict -eq "suspect") {
        return "questionable"
    }
    return "pass"
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($manifestPathItem in Get-ManifestPaths) {
    $manifest = Get-Content -LiteralPath $manifestPathItem -Raw | ConvertFrom-Json
    $logPath = [string](Get-PropertyValue $manifest "logPath")
    if ([string]::IsNullOrWhiteSpace($logPath) -or -not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        continue
    }

    $anchorsByActor = @{}
    $animationContextByActor = @{}
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $logPath) {
        ++$lineNumber

        if ($line -match "FNV/ESM4 diag: skeleton animation state") {
            $actorMatch = [regex]::Match($line, "skeleton animation state (?<actor>.+?) sample=")
            if ($actorMatch.Success) {
                $animationContextByActor[$actorMatch.Groups["actor"].Value] = Get-ActiveAnimationContext -Line $line -LineNumber $lineNumber
            }
            continue
        }

        if ($line -match "FNV/ESM4 diag: skeleton anchors") {
            $actorMatch = [regex]::Match($line, "skeleton anchors (?<actor>.+?) head=")
            if (-not $actorMatch.Success) {
                continue
            }
            $actor = $actorMatch.Groups["actor"].Value
            $animationContext = if ($animationContextByActor.ContainsKey($actor)) { $animationContextByActor[$actor] } else { $null }
            $anchorsByActor[$actor] = [pscustomobject][ordered]@{
                line = $lineNumber
                actor = $actor
                animationContext = $animationContext
                leftShoulder = Select-VectorFromLine $line "leftShoulder" "leftShoulder"
                leftElbow = Select-VectorFromLine $line "leftElbow" "leftElbow"
                leftHand = Select-VectorFromLine $line "leftHand" "leftHand"
                rightShoulder = Select-VectorFromLine $line "rightShoulder" "rightShoulder"
                rightElbow = Select-VectorFromLine $line "rightElbow" "rightElbow"
                rightHand = Select-VectorFromLine $line "rightHand" "rightHand"
            }
            continue
        }

        $kind = $null
        $side = $null
        $part = $null
        $actor = $null
        $targets = [ordered]@{}

        if ($line -match "FNV/ESM4 HAND GEOMETRY BOUNDS AUDIT") {
            $actorMatch = [regex]::Match($line, "HAND GEOMETRY BOUNDS AUDIT (?<actor>.+?) part=")
            $classMatch = [regex]::Match($line, " class=(?<side>leftHand|rightHand)\b")
            $partMatch = [regex]::Match($line, " part='(?<part>[^']*)'")
            if (-not $actorMatch.Success -or -not $classMatch.Success) { continue }
            $actor = $actorMatch.Groups["actor"].Value
            $kind = "hand-geometry-bounds"
            $side = $classMatch.Groups["side"].Value
            $part = if ($partMatch.Success) { $partMatch.Groups["part"].Value } else { "" }
            $renderValid = [regex]::Match($line, " renderValid=(?<value>[01])").Groups["value"].Value -eq "1"
            $sourceValid = [regex]::Match($line, " sourceValid=(?<value>[01])").Groups["value"].Value -eq "1"
            $liveValid = [regex]::Match($line, " liveValid=(?<value>[01])").Groups["value"].Value -eq "1"
            foreach ($name in @("renderCenterPathWorld")) {
                if ($renderValid) {
                    $value = Select-VectorFromLine $line $name $name
                    if ($null -ne $value) { $targets[$name] = $value }
                }
            }
            if ($sourceValid) {
                $value = Select-VectorFromLine $line "sourceCenterPathWorld" "sourceCenterPathWorld"
                if ($null -ne $value) { $targets["sourceCenterPathWorld"] = $value }
            }
            if ($liveValid) {
                $value = Select-VectorFromLine $line "liveCenterPathWorld" "liveCenterPathWorld"
                if ($null -ne $value) { $targets["liveCenterPathWorld"] = $value }
            }
            $anchor = Select-VectorFromLine $line "anchor" "anchor"
            if ($null -ne $anchor) { $targets["anchor"] = $anchor }
        }
        elseif ($line -match "FNV/ESM4 PART MATRIX AUDIT") {
            $actorMatch = [regex]::Match($line, "PART MATRIX AUDIT (?<actor>.+?) part=")
            $classMatch = [regex]::Match($line, " class=(?<side>leftHand|rightHand)\b")
            $partMatch = [regex]::Match($line, " part='(?<part>[^']*)'")
            if (-not $actorMatch.Success -or -not $classMatch.Success) { continue }
            $actor = $actorMatch.Groups["actor"].Value
            $kind = "part-matrix"
            $side = $classMatch.Groups["side"].Value
            $part = if ($partMatch.Success) { $partMatch.Groups["part"].Value } else { "" }
            foreach ($name in @("center", "anchor", "partWorldTrans", "parentWorldTrans", "partInAnchorTrans")) {
                $value = Select-VectorFromLine $line $name $name
                if ($null -ne $value) { $targets[$name] = $value }
            }
        }
        else {
            continue
        }

        if (-not $anchorsByActor.ContainsKey($actor)) {
            continue
        }
        $currentAnchors = $anchorsByActor[$actor]
        $chain = Get-HandChain $currentAnchors $side
        if (-not (Test-VectorPresent $chain[0]) -or -not (Test-VectorPresent $chain[1]) -or -not (Test-VectorPresent $chain[2])) {
            continue
        }

        foreach ($targetName in @($targets.Keys)) {
            $target = $targets[$targetName]
            if (-not (Test-VectorPresent $target)) { continue }
            $solve = Invoke-Fabrik3 -Points $chain -Target $target -IterationCount $Iterations
            $handAnchorError = Distance-Vec3 $chain[2] $target
            $verdict = if ($targetName -eq "anchor") {
                "anchor"
            } elseif ($handAnchorError -le 12.0) {
                "near-hand"
            } elseif ($solve.unreachableBy -gt 32.0 -or $handAnchorError -gt 96.0) {
                "exploded"
            } else {
                "suspect"
            }
            $status = Get-FabrikStatus -Verdict $verdict -TargetName $targetName
            $failureClasses = New-Object System.Collections.Generic.List[string]
            $warningClasses = New-Object System.Collections.Generic.List[string]
            if ($status -eq "fail") {
                Add-UniqueText -List $failureClasses -Value "actor-fabrik-target-exploded"
            }
            elseif ($status -eq "questionable") {
                Add-UniqueText -List $warningClasses -Value "actor-fabrik-target-suspect"
            }
            $animationContext = Get-PropertyValue $currentAnchors "animationContext"
            $rows.Add([pscustomobject][ordered]@{
                schemaVersion = 1
                assessedAt = (Get-Date).ToString("o")
                worldId = [string](Get-PropertyValue $manifest "worldId")
                evidenceKind = "actor-fabrik-telemetry"
                status = $status
                failureClasses = @($failureClasses.ToArray())
                warningClasses = @($warningClasses.ToArray())
                manifest = Convert-ToForwardSlash $manifestPathItem
                log = Convert-ToForwardSlash $logPath
                startCell = [string](Get-PropertyValue $manifest "startCell")
                startSlice = [string](Get-PropertyValue $manifest "startSlice")
                line = $lineNumber
                anchorLine = $currentAnchors.line
                animationStateLine = if ($null -ne $animationContext) { $animationContext.line } else { $null }
                animationSample = if ($null -ne $animationContext) { $animationContext.sample } else { $null }
                activeGroups = if ($null -ne $animationContext) { $animationContext.activeGroups } else { $null }
                animationBlendMask = if ($null -ne $animationContext) { $animationContext.primaryBlendMask } else { $null }
                animationGroup = if ($null -ne $animationContext) { $animationContext.primaryGroup } else { $null }
                animationTime = if ($null -ne $animationContext) { $animationContext.primaryTime } else { $null }
                animationSource = if ($null -ne $animationContext) { $animationContext.primarySource } else { $null }
                actor = $actor
                kind = $kind
                side = $side
                part = $part
                target = $targetName
                shoulder = $chain[0]
                elbow = $chain[1]
                hand = $chain[2]
                targetPoint = $target
                upperLength = [Math]::Round((Distance-Vec3 $chain[0] $chain[1]), 4)
                forearmLength = [Math]::Round((Distance-Vec3 $chain[1] $chain[2]), 4)
                handAnchorError = [Math]::Round($handAnchorError, 4)
                rootToTarget = $solve.rootToTarget
                chainLength = $solve.chainLength
                unreachableBy = $solve.unreachableBy
                fabrikResidual = $solve.residual
                solvedElbow = $solve.solvedElbow
                solvedHand = $solve.solvedHand
                verdict = $verdict
            }) | Out-Null
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

$summary = @($rows.ToArray()) |
    Group-Object side, target, verdict |
    ForEach-Object {
        [pscustomobject][ordered]@{
            side = $_.Group[0].side
            target = $_.Group[0].target
            verdict = $_.Group[0].verdict
            count = $_.Count
            maxHandAnchorError = [Math]::Round((@($_.Group) | ForEach-Object { $_.handAnchorError } | Measure-Object -Maximum).Maximum, 3)
            maxUnreachableBy = [Math]::Round((@($_.Group) | ForEach-Object { $_.unreachableBy } | Measure-Object -Maximum).Maximum, 3)
        }
    }

$summary | Sort-Object side, target, verdict | Format-Table -AutoSize
if (-not $NoWrite) {
    Write-Host "Wrote actor FABRIK telemetry ledger: $OutputPath"
}
