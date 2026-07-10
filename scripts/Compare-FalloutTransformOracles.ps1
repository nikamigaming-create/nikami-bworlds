param(
    [Parameter(Mandatory = $true)]
    [string]$RetailPath,
    [Parameter(Mandatory = $true)]
    [string]$OpenMWPath,
    [string]$OutputPath = "run\transform-oracle\fallout-transform-diff.json",
    [ValidateSet('retail-mixed', 'aim', 'locomotion')]
    [string]$UpperPhase = 'retail-mixed',
    [int]$RetailMinFrame = 0,
    [double]$TranslationThreshold = 0.05,
    [double]$RotationThresholdDegrees = 0.25,
    [double]$ScaleThreshold = 0.001
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Read-JsonLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing transform-oracle input: $Path"
    }
    return @(Get-Content -LiteralPath $Path | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })
}

function Get-Sequence([object]$Frame, [string]$Property, [string]$FilePattern) {
    foreach ($sequence in @($Frame.$Property)) {
        if ($null -ne $sequence -and [string]$sequence.file -match $FilePattern) {
            return $sequence
        }
    }
    return $null
}

function Get-OpenMWGroups([string]$Description) {
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($part in @($Description -split ' \| ')) {
        if ($part -match '^(?<slot>\d+):(?<name>[^@ ]+)@t=(?<time>[-+0-9.eE]+).*?\bsrc=(?<source>.+)$') {
            $groups.Add([pscustomobject]@{
                    slot = [int]$Matches.slot
                    name = [string]$Matches.name
                    time = [double]::Parse($Matches.time, [Globalization.CultureInfo]::InvariantCulture)
                    source = ([string]$Matches.source).Trim()
                }) | Out-Null
        }
    }
    return @($groups)
}

function Get-CircularDistance([double]$Left, [double]$Right, [double]$Duration) {
    $difference = [Math]::Abs($Left - $Right)
    if ($Duration -le 0) {
        return $difference
    }
    $wrapped = $difference % $Duration
    return [Math]::Min($wrapped, $Duration - $wrapped)
}

function Get-VectorDistance([object[]]$Left, [object[]]$Right) {
    if ($Left.Count -ne 3 -or $Right.Count -ne 3) {
        throw "Expected two three-component vectors."
    }
    $sum = 0.0
    for ($index = 0; $index -lt 3; $index++) {
        $delta = [double]$Left[$index] - [double]$Right[$index]
        $sum += $delta * $delta
    }
    return [Math]::Sqrt($sum)
}

function Get-ScaleComponents([object]$Scale) {
    if ($Scale -is [System.Array]) {
        $values = @($Scale | ForEach-Object { [double]$_ })
        if ($values.Count -eq 3) {
            return $values
        }
    }
    $scalar = [double]$Scale
    return @($scalar, $scalar, $scalar)
}

function Get-ScaleError([object]$RetailScale, [object]$OpenMWScale) {
    $retail = @(Get-ScaleComponents $RetailScale)
    $openmw = @(Get-ScaleComponents $OpenMWScale)
    $maximum = 0.0
    for ($index = 0; $index -lt 3; $index++) {
        $maximum = [Math]::Max($maximum, [Math]::Abs($retail[$index] - $openmw[$index]))
    }
    return $maximum
}

function Get-RotationAngleDegrees([object[]]$Retail, [object[]]$OpenMW, [bool]$TransposeOpenMW) {
    if ($Retail.Count -ne 9 -or $OpenMW.Count -ne 9) {
        throw "Expected two row-major 3x3 rotation matrices."
    }

    $right = New-Object 'double[,]' 3, 3
    $left = New-Object 'double[,]' 3, 3
    for ($row = 0; $row -lt 3; $row++) {
        for ($column = 0; $column -lt 3; $column++) {
            $left[$row, $column] = [double]$Retail[$row * 3 + $column]
            $sourceIndex = if ($TransposeOpenMW) { $column * 3 + $row } else { $row * 3 + $column }
            $right[$row, $column] = [double]$OpenMW[$sourceIndex]
        }
    }

    # relative = transpose(retail) * openmw
    $trace = 0.0
    for ($row = 0; $row -lt 3; $row++) {
        $diagonal = 0.0
        for ($inner = 0; $inner -lt 3; $inner++) {
            $diagonal += $left[$inner, $row] * $right[$inner, $row]
        }
        $trace += $diagonal
    }
    $cosine = [Math]::Max(-1.0, [Math]::Min(1.0, ($trace - 1.0) / 2.0))
    return [Math]::Acos($cosine) * 180.0 / [Math]::PI
}

function Get-NodeMap([object[]]$Nodes, [string]$TransformProperty) {
    $map = @{}
    foreach ($node in @($Nodes)) {
        if ($null -eq $node -or [string]::IsNullOrWhiteSpace([string]$node.name)) {
            continue
        }
        if ($node.PSObject.Properties.Name -contains 'present' -and -not [bool]$node.present) {
            continue
        }
        if ($null -eq $node.$TransformProperty) {
            continue
        }
        $map[[string]$node.name] = $node
    }
    return $map
}

function Get-NodeAnimationPhase([string]$Name) {
    if ($Name -eq 'Bip01 NonAccum' -or $Name -eq 'Bip01 Pelvis' -or
        $Name -match '^Bip01 [LR] (Thigh|Calf|Foot|Toe)') {
        return 'locomotion'
    }
    if ($UpperPhase -eq 'retail-mixed') {
        if ($Name -match '^Bip01 (Spine|Neck|Head)') {
            return 'locomotion'
        }
        return 'aim'
    }
    return $UpperPhase
}

$retailAbsolute = Resolve-AbsolutePath $RetailPath
$openmwAbsolute = Resolve-AbsolutePath $OpenMWPath
$outputAbsolute = Resolve-AbsolutePath $OutputPath
$retailRows = @(Read-JsonLines $retailAbsolute)
$openmwRows = @(Read-JsonLines $openmwAbsolute)

$retailSamples = [System.Collections.Generic.List[object]]::new()
foreach ($frame in @($retailRows | Where-Object { $_.event -eq 'actor-frame' })) {
    if ([int]$frame.frame -lt $RetailMinFrame) {
        continue
    }
    $locomotion = Get-Sequence $frame 'animDataSequences' '(?i)(^|[\\/])2hrforward\.kf$'
    if ($null -eq $locomotion -or [double]$locomotion.last -lt -1.0e20 -or [int]$locomotion.state -ne 1) {
        continue
    }
    $aim = Get-Sequence $frame 'middleHighSequences' '(?i)(^|[\\/])2hraim\.kf$'
    if ($null -eq $aim -or [double]$aim.last -lt -1.0e20 -or [int]$aim.state -ne 1) {
        continue
    }
    $retailSamples.Add([pscustomobject]@{
            frame = [int]$frame.frame
            locomotionTime = [double]$locomotion.last
            locomotionDuration = [double]$locomotion.end - [double]$locomotion.begin
            aimTime = [double]$aim.last
            aimDuration = [double]$aim.end - [double]$aim.begin
            source = [string]$locomotion.file
            nodes = $frame.bones
        }) | Out-Null
}

$openmwSamples = [System.Collections.Generic.List[object]]::new()
foreach ($frame in @($openmwRows | Where-Object { $_.event -eq 'actor-frame' })) {
    $groups = @(Get-OpenMWGroups ([string]$frame.activeGroups))
    $locomotion = @($groups | Where-Object {
            $_.source -match '(?i)(^|[\\/])2hrforward\.kf$' -and $_.name -match '(?i)forward'
        } | Select-Object -First 1)
    if ($locomotion.Count -eq 0) {
        continue
    }
    $aim = @($groups | Where-Object { $_.source -match '(?i)(^|[\\/])2hraim\.kf$' } | Select-Object -First 1)
    $openmwSamples.Add([pscustomobject]@{
            sample = [int]$frame.sample
            update = [uint64]$frame.update
            locomotionTime = [double]$locomotion[0].time
            aimTime = if ($aim.Count -gt 0) { [double]$aim[0].time } else { $null }
            source = [string]$locomotion[0].source
            nodes = $frame.nodes
        }) | Out-Null
}

if ($retailSamples.Count -eq 0) {
    throw "Retail input contains no valid 2hrforward actor frames."
}
if ($openmwSamples.Count -eq 0) {
    throw "OpenMW input contains no valid 2hrforward frames."
}

$pairs = [System.Collections.Generic.List[object]]::new()
foreach ($retail in @($retailSamples)) {
    $best = $null
    $bestScore = [double]::PositiveInfinity
    $bestLocomotionDelta = 0.0
    $bestAimDelta = $null
    foreach ($openmw in @($openmwSamples)) {
        $locomotionDelta = Get-CircularDistance $retail.locomotionTime $openmw.locomotionTime $retail.locomotionDuration
        $score = [Math]::Pow($locomotionDelta / [Math]::Max($retail.locomotionDuration, 0.001), 2)
        $aimDelta = $null
        if ($null -ne $retail.aimTime -and $null -ne $openmw.aimTime -and $retail.aimDuration -gt 0) {
            $aimDelta = Get-CircularDistance $retail.aimTime $openmw.aimTime $retail.aimDuration
            $score += [Math]::Pow($aimDelta / $retail.aimDuration, 2)
        }
        if ($score -lt $bestScore) {
            $best = $openmw
            $bestScore = $score
            $bestLocomotionDelta = $locomotionDelta
            $bestAimDelta = $aimDelta
        }
    }
    $pairs.Add([pscustomobject]@{
            retail = $retail
            openmw = $best
            score = $bestScore
            locomotionDelta = $bestLocomotionDelta
            aimDelta = $bestAimDelta
        }) | Out-Null
}

$measurements = [System.Collections.Generic.List[object]]::new()
$retailNodeNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$openmwNodeNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$openmwNodeMaps = @{}
foreach ($openmw in @($openmwSamples)) {
    $openmwMap = Get-NodeMap $openmw.nodes 'transform'
    $openmwNodeMaps[$openmw.sample] = $openmwMap
    foreach ($name in @($openmwMap.Keys)) { $openmwNodeNames.Add($name) | Out-Null }
}
foreach ($retail in @($retailSamples)) {
    $retailMap = Get-NodeMap $retail.nodes 'transform'
    foreach ($name in @($retailMap.Keys)) { $retailNodeNames.Add($name) | Out-Null }
    foreach ($name in @($retailMap.Keys | Sort-Object)) {
        # OpenMW carries the NIF-to-renderer basis bridge on Bip01 while retail
        # carries it on Scene Root. Children are directly comparable after the
        # global row/column convention is selected below.
        if ($name -eq 'Bip01') {
            continue
        }
        $phase = Get-NodeAnimationPhase $name
        $retailNode = $retailMap[$name]
        $retailTransform = $retailNode.transform
        $retailPhaseTime = if ($phase -eq 'locomotion') { $retail.locomotionTime } else { $retail.aimTime }
        $phaseDuration = if ($phase -eq 'locomotion') { $retail.locomotionDuration } else { $retail.aimDuration }
        $bestOpenMW = $null
        $bestPhaseDelta = [double]::PositiveInfinity
        $bestPoseDirectDegrees = [double]::PositiveInfinity
        $bestPoseDirectSample = 0
        $bestPoseDirectPhaseDelta = [double]::PositiveInfinity
        $bestPoseTransposedDegrees = [double]::PositiveInfinity
        $bestPoseTransposedSample = 0
        $bestPoseTransposedPhaseDelta = [double]::PositiveInfinity
        $bestPoseTranslation = [double]::PositiveInfinity
        $bestPoseTranslationSample = 0
        $bestPoseTranslationPhaseDelta = [double]::PositiveInfinity
        foreach ($candidate in @($openmwSamples)) {
            $candidateMap = $openmwNodeMaps[$candidate.sample]
            if (-not $candidateMap.ContainsKey($name)) {
                continue
            }
            $candidatePhaseTime = if ($phase -eq 'locomotion') { $candidate.locomotionTime } else { $candidate.aimTime }
            if ($null -eq $candidatePhaseTime) {
                continue
            }
            $phaseDelta = Get-CircularDistance $retailPhaseTime $candidatePhaseTime $phaseDuration
            $candidateTransform = $candidateMap[$name].transform
            $poseTranslation = Get-VectorDistance @($retailTransform.localTranslation) @($candidateTransform.localTranslation)
            if ($poseTranslation -lt $bestPoseTranslation) {
                $bestPoseTranslation = $poseTranslation
                $bestPoseTranslationSample = $candidate.sample
                $bestPoseTranslationPhaseDelta = $phaseDelta
            }
            $poseDirectDegrees = Get-RotationAngleDegrees @($retailTransform.localRotation) @($candidateTransform.localRotation) $false
            if ($poseDirectDegrees -lt $bestPoseDirectDegrees) {
                $bestPoseDirectDegrees = $poseDirectDegrees
                $bestPoseDirectSample = $candidate.sample
                $bestPoseDirectPhaseDelta = $phaseDelta
            }
            $poseTransposedDegrees = Get-RotationAngleDegrees @($retailTransform.localRotation) @($candidateTransform.localRotation) $true
            if ($poseTransposedDegrees -lt $bestPoseTransposedDegrees) {
                $bestPoseTransposedDegrees = $poseTransposedDegrees
                $bestPoseTransposedSample = $candidate.sample
                $bestPoseTransposedPhaseDelta = $phaseDelta
            }
            if ($phaseDelta -lt $bestPhaseDelta) {
                $bestOpenMW = $candidate
                $bestPhaseDelta = $phaseDelta
            }
        }
        if ($null -eq $bestOpenMW) {
            continue
        }
        $openmwMap = $openmwNodeMaps[$bestOpenMW.sample]
        $openmwNode = $openmwMap[$name]
        $openmwTransform = $openmwNode.transform
        $measurements.Add([pscustomobject]@{
                node = $name
                retailDepth = if ($retailNode.PSObject.Properties.Name -contains 'depth') { [int]$retailNode.depth } else { 2147483647 }
                phase = $phase
                phaseDelta = $bestPhaseDelta
                retailFrame = $retail.frame
                openmwSample = $bestOpenMW.sample
                translation = Get-VectorDistance @($retailTransform.localTranslation) @($openmwTransform.localTranslation)
                rotationDirectDegrees = Get-RotationAngleDegrees @($retailTransform.localRotation) @($openmwTransform.localRotation) $false
                rotationTransposedDegrees = Get-RotationAngleDegrees @($retailTransform.localRotation) @($openmwTransform.localRotation) $true
                poseNearestDirectDegrees = $bestPoseDirectDegrees
                poseNearestDirectSample = $bestPoseDirectSample
                poseNearestDirectPhaseDelta = $bestPoseDirectPhaseDelta
                poseNearestTransposedDegrees = $bestPoseTransposedDegrees
                poseNearestTransposedSample = $bestPoseTransposedSample
                poseNearestTransposedPhaseDelta = $bestPoseTransposedPhaseDelta
                poseNearestTranslation = $bestPoseTranslation
                poseNearestTranslationSample = $bestPoseTranslationSample
                poseNearestTranslationPhaseDelta = $bestPoseTranslationPhaseDelta
                scale = Get-ScaleError $retailTransform.localScale $openmwTransform.localScale
            }) | Out-Null
    }
}

if ($measurements.Count -eq 0) {
    throw "The paired frames have no common present nodes."
}

$directMean = ($measurements | Measure-Object rotationDirectDegrees -Average).Average
$transposedMean = ($measurements | Measure-Object rotationTransposedDegrees -Average).Average
$rotationConvention = if ($transposedMean -lt $directMean) { 'transpose-openmw' } else { 'direct' }
$rotationProperty = if ($rotationConvention -eq 'transpose-openmw') { 'rotationTransposedDegrees' } else { 'rotationDirectDegrees' }
$poseNearestRotationProperty = if ($rotationConvention -eq 'transpose-openmw') { 'poseNearestTransposedDegrees' } else { 'poseNearestDirectDegrees' }
$poseNearestSampleProperty = if ($rotationConvention -eq 'transpose-openmw') { 'poseNearestTransposedSample' } else { 'poseNearestDirectSample' }
$poseNearestPhaseDeltaProperty = if ($rotationConvention -eq 'transpose-openmw') { 'poseNearestTransposedPhaseDelta' } else { 'poseNearestDirectPhaseDelta' }

$nodeStats = [System.Collections.Generic.List[object]]::new()
foreach ($group in @($measurements | Group-Object node | Sort-Object Name)) {
    $items = @($group.Group)
    $rotations = @($items | ForEach-Object { [double]$_.$rotationProperty })
    $poseNearestRotations = @($items | ForEach-Object { [double]$_.$poseNearestRotationProperty })
    $poseNearestPhaseDeltas = @($items | ForEach-Object { [double]$_.$poseNearestPhaseDeltaProperty })
    $poseNearestTranslations = @($items | ForEach-Object { [double]$_.poseNearestTranslation })
    $maximumTranslationItem = @($items | Sort-Object translation -Descending | Select-Object -First 1)[0]
    $maximumRotationItem = @($items | Sort-Object $rotationProperty -Descending | Select-Object -First 1)[0]
    $maximumPoseNearestRotationItem = @($items | Sort-Object $poseNearestRotationProperty -Descending | Select-Object -First 1)[0]
    $nodeStats.Add([pscustomobject]@{
            node = $group.Name
            retailDepth = ($items | Measure-Object retailDepth -Minimum).Minimum
            phase = [string]$items[0].phase
            phaseDeltaMean = ($items | Measure-Object phaseDelta -Average).Average
            phaseDeltaMax = ($items | Measure-Object phaseDelta -Maximum).Maximum
            samples = $items.Count
            translationMean = ($items | Measure-Object translation -Average).Average
            translationMax = ($items | Measure-Object translation -Maximum).Maximum
            rotationMeanDegrees = ($rotations | Measure-Object -Average).Average
            rotationMaxDegrees = ($rotations | Measure-Object -Maximum).Maximum
            poseNearestRotationMeanDegrees = ($poseNearestRotations | Measure-Object -Average).Average
            poseNearestRotationMaxDegrees = ($poseNearestRotations | Measure-Object -Maximum).Maximum
            poseNearestPhaseDeltaMean = ($poseNearestPhaseDeltas | Measure-Object -Average).Average
            poseNearestPhaseDeltaMax = ($poseNearestPhaseDeltas | Measure-Object -Maximum).Maximum
            poseNearestTranslationMean = ($poseNearestTranslations | Measure-Object -Average).Average
            poseNearestTranslationMax = ($poseNearestTranslations | Measure-Object -Maximum).Maximum
            scaleMean = ($items | Measure-Object scale -Average).Average
            scaleMax = ($items | Measure-Object scale -Maximum).Maximum
            translationMaxAt = [ordered]@{
                retailFrame = $maximumTranslationItem.retailFrame
                openmwSample = $maximumTranslationItem.openmwSample
            }
            rotationMaxAt = [ordered]@{
                retailFrame = $maximumRotationItem.retailFrame
                openmwSample = $maximumRotationItem.openmwSample
            }
            poseNearestRotationMaxAt = [ordered]@{
                retailFrame = $maximumPoseNearestRotationItem.retailFrame
                openmwSample = [int]$maximumPoseNearestRotationItem.$poseNearestSampleProperty
                phaseDelta = [double]$maximumPoseNearestRotationItem.$poseNearestPhaseDeltaProperty
            }
        }) | Out-Null
}

$firstDivergence = $null
foreach ($measurement in @($measurements | Sort-Object retailFrame, retailDepth, node)) {
    $rotation = [double]$measurement.$rotationProperty
    if ($measurement.translation -gt $TranslationThreshold -or
        $rotation -gt $RotationThresholdDegrees -or
        $measurement.scale -gt $ScaleThreshold) {
        $firstDivergence = [pscustomobject]@{
            node = $measurement.node
            retailFrame = $measurement.retailFrame
            openmwSample = $measurement.openmwSample
            translation = $measurement.translation
            rotationDegrees = $rotation
            scale = $measurement.scale
            phase = $measurement.phase
            phaseDelta = $measurement.phaseDelta
        }
        break
    }
}

$firstPoseNearestDivergence = $null
foreach ($measurement in @($measurements | Sort-Object retailFrame, retailDepth, node)) {
    $rotation = [double]$measurement.$poseNearestRotationProperty
    if ($measurement.poseNearestTranslation -gt $TranslationThreshold -or
        $rotation -gt $RotationThresholdDegrees -or
        $measurement.scale -gt $ScaleThreshold) {
        $firstPoseNearestDivergence = [pscustomobject]@{
            node = $measurement.node
            retailFrame = $measurement.retailFrame
            openmwSample = [int]$measurement.$poseNearestSampleProperty
            translation = $measurement.poseNearestTranslation
            rotationDegrees = $rotation
            scale = $measurement.scale
            phase = $measurement.phase
            phaseDelta = [double]$measurement.$poseNearestPhaseDeltaProperty
        }
        break
    }
}

$missingInOpenMW = @($retailNodeNames | Where-Object { -not $openmwNodeNames.Contains($_) } | Sort-Object)
$missingInRetail = @($openmwNodeNames | Where-Object { -not $retailNodeNames.Contains($_) } | Sort-Object)
$pairReport = @($pairs | ForEach-Object {
        [pscustomobject]@{
            retailFrame = $_.retail.frame
            retailLocomotionTime = $_.retail.locomotionTime
            retailAimTime = $_.retail.aimTime
            openmwSample = $_.openmw.sample
            openmwLocomotionTime = $_.openmw.locomotionTime
            openmwAimTime = $_.openmw.aimTime
            locomotionDelta = $_.locomotionDelta
            aimDelta = $_.aimDelta
            score = $_.score
        }
    })

$selectedRotations = @($measurements | ForEach-Object { [double]$_.$rotationProperty })
$poseNearestRotations = @($measurements | ForEach-Object { [double]$_.$poseNearestRotationProperty })
$poseNearestTranslations = @($measurements | ForEach-Object { [double]$_.poseNearestTranslation })
$result = [ordered]@{
    schema = 'nikami-fallout-transform-oracle-diff/v1'
    generatedAt = [DateTime]::UtcNow.ToString('o')
    retailPath = $retailAbsolute
    openmwPath = $openmwAbsolute
    status = if ($null -eq $firstDivergence) { 'pass' } else { 'diverged' }
    phaseStatus = if ($null -eq $firstDivergence) { 'pass' } else { 'diverged' }
    poseShapeStatus = if ($null -eq $firstPoseNearestDivergence) { 'pass' } else { 'diverged' }
    thresholds = [ordered]@{
        translation = $TranslationThreshold
        rotationDegrees = $RotationThresholdDegrees
        scale = $ScaleThreshold
    }
    pairing = [ordered]@{
        retailSamples = $retailSamples.Count
        openmwSamples = $openmwSamples.Count
        pairedNodeSamples = $measurements.Count
        method = 'per-node nearest controlling phase: locomotion drives lower body, torso, neck, and head; weapon-pose aim drives the two arm branches and Weapon'
        retailPriorityEvidence = [ordered]@{
            lowerBody = 'locomotion 30 > aim 25'
            torsoNeckHead = 'locomotion 31 > aim 30'
            armBranches = 'aim 35 > locomotion 31'
            weapon = 'aim 45'
        }
        diagnosticWholeFramePairs = $pairReport
    }
    rotationConvention = [ordered]@{
        selected = $rotationConvention
        directMeanDegrees = $directMean
        transposedMeanDegrees = $transposedMean
    }
    summary = [ordered]@{
        comparedNodeSamples = $measurements.Count
        comparedNodes = $nodeStats.Count
        missingInOpenMW = $missingInOpenMW
        missingInRetail = $missingInRetail
        excludedCoordinateBridgeNodes = @('Bip01')
        translationMean = ($measurements | Measure-Object translation -Average).Average
        translationMax = ($measurements | Measure-Object translation -Maximum).Maximum
        rotationMeanDegrees = ($selectedRotations | Measure-Object -Average).Average
        rotationMaxDegrees = ($selectedRotations | Measure-Object -Maximum).Maximum
        scaleMean = ($measurements | Measure-Object scale -Average).Average
        scaleMax = ($measurements | Measure-Object scale -Maximum).Maximum
        firstDivergence = $firstDivergence
        poseNearest = [ordered]@{
            purpose = 'transform-curve parity independent of sequence start offset or callback timing'
            translationMean = ($poseNearestTranslations | Measure-Object -Average).Average
            translationMax = ($poseNearestTranslations | Measure-Object -Maximum).Maximum
            rotationMeanDegrees = ($poseNearestRotations | Measure-Object -Average).Average
            rotationMaxDegrees = ($poseNearestRotations | Measure-Object -Maximum).Maximum
            firstDivergence = $firstPoseNearestDivergence
        }
    }
    nodes = @($nodeStats)
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputAbsolute) | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outputAbsolute -Encoding UTF8
$result | ConvertTo-Json -Depth 12 | ConvertFrom-Json
