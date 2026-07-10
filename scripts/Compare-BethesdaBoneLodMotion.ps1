param(
    [Parameter(Mandatory = $true)]
    [string]$RetailPath,
    [Parameter(Mandatory = $true)]
    [string]$OpenMWPath,
    [Parameter(Mandatory = $true)]
    [string]$BoneLodAuditPath,
    [string]$OutputPath = "",
    [int]$RetailStartFrame = [int]::MinValue,
    [int]$RetailEndFrame = [int]::MaxValue,
    [double]$ToleranceDegrees = 0.001
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-InputPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-ActorFrames([string]$Path) {
    $frames = [Collections.Generic.List[object]]::new()
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $record = $line | ConvertFrom-Json
        if ($record.event -eq "actor-frame") {
            $frames.Add($record)
        }
    }
    return @($frames)
}

function Convert-MatrixToQuaternion($Matrix) {
    if ($Matrix.Count -ne 9) {
        throw "Expected a 3x3 rotation matrix."
    }
    $m = @($Matrix | ForEach-Object { [double]$_ })
    $trace = $m[0] + $m[4] + $m[8]
    if ($trace -gt 0.0) {
        $s = 2.0 * [Math]::Sqrt($trace + 1.0)
        $w = 0.25 * $s
        $x = ($m[7] - $m[5]) / $s
        $y = ($m[2] - $m[6]) / $s
        $z = ($m[3] - $m[1]) / $s
    }
    elseif ($m[0] -gt $m[4] -and $m[0] -gt $m[8]) {
        $s = 2.0 * [Math]::Sqrt(1.0 + $m[0] - $m[4] - $m[8])
        $w = ($m[7] - $m[5]) / $s
        $x = 0.25 * $s
        $y = ($m[1] + $m[3]) / $s
        $z = ($m[2] + $m[6]) / $s
    }
    elseif ($m[4] -gt $m[8]) {
        $s = 2.0 * [Math]::Sqrt(1.0 + $m[4] - $m[0] - $m[8])
        $w = ($m[2] - $m[6]) / $s
        $x = ($m[1] + $m[3]) / $s
        $y = 0.25 * $s
        $z = ($m[5] + $m[7]) / $s
    }
    else {
        $s = 2.0 * [Math]::Sqrt(1.0 + $m[8] - $m[0] - $m[4])
        $w = ($m[3] - $m[1]) / $s
        $x = ($m[2] + $m[6]) / $s
        $y = ($m[5] + $m[7]) / $s
        $z = 0.25 * $s
    }
    $norm = [Math]::Sqrt($w * $w + $x * $x + $y * $y + $z * $z)
    if ($norm -le 0.0) {
        throw "Could not normalize rotation quaternion."
    }
    return @(
        ($w / $norm)
        ($x / $norm)
        ($y / $norm)
        ($z / $norm)
    )
}

function Get-RotationAngleDegrees($First, $Current) {
    $firstQuaternion = Convert-MatrixToQuaternion $First
    $currentQuaternion = Convert-MatrixToQuaternion $Current
    $dot = 0.0
    for ($index = 0; $index -lt 4; ++$index) {
        $dot += $firstQuaternion[$index] * $currentQuaternion[$index]
    }
    # q and -q are the same rotation.
    $dot = [Math]::Abs($dot)
    $dot = [Math]::Max(-1.0, [Math]::Min(1.0, $dot))
    return 2.0 * [Math]::Acos($dot) * 180.0 / [Math]::PI
}

function Measure-NodeMotion($Frames, [string[]]$NodeNames) {
    $results = [Collections.Generic.List[object]]::new()
    foreach ($name in $NodeNames) {
        $rotations = [Collections.Generic.List[object]]::new()
        foreach ($frame in $Frames) {
            $entries = if ($null -ne $frame.PSObject.Properties["nodes"]) {
                @($frame.nodes)
            }
            elseif ($null -ne $frame.PSObject.Properties["bones"]) {
                @($frame.bones)
            }
            else {
                @()
            }
            $node = @($entries | Where-Object { $_.name -eq $name }) | Select-Object -First 1
            if ($null -ne $node -and $null -ne $node.transform -and $null -ne $node.transform.localRotation) {
                $rotations.Add(@($node.transform.localRotation))
            }
        }

        $maximum = $null
        if ($rotations.Count -gt 0) {
            $maximum = 0.0
            $first = $rotations[0]
            foreach ($rotation in $rotations) {
                $maximum = [Math]::Max($maximum, (Get-RotationAngleDegrees $first $rotation))
            }
        }
        $results.Add([ordered]@{
            node = $name
            samples = $rotations.Count
            maxRotationFromFirstDegrees = $maximum
        })
    }
    return @($results)
}

function Get-MaximumMotion($Measurements) {
    $values = @($Measurements | Where-Object { $null -ne $_.maxRotationFromFirstDegrees } |
        ForEach-Object { [double]$_.maxRotationFromFirstDegrees })
    if ($values.Count -eq 0) {
        return $null
    }
    return ($values | Measure-Object -Maximum).Maximum
}

$retail = Resolve-InputPath $RetailPath
$openmw = Resolve-InputPath $OpenMWPath
$auditPath = Resolve-InputPath $BoneLodAuditPath
$audit = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
$groupZero = @($audit.boneLodControllers[0].groups | Where-Object { $_.index -eq 0 } |
    Select-Object -ExpandProperty nodes)
if ($groupZero.Count -eq 0) {
    throw "The NIF audit does not contain Bethesda bone LOD group 0."
}

$retailFrames = @(Get-ActorFrames $retail | Where-Object {
        $null -ne $_.PSObject.Properties["frame"] `
            -and [int]$_.frame -ge $RetailStartFrame `
            -and [int]$_.frame -le $RetailEndFrame
    })
$openmwFrames = Get-ActorFrames $openmw
$retailMotion = Measure-NodeMotion $retailFrames $groupZero
$openmwMotion = Measure-NodeMotion $openmwFrames $groupZero
$retailMaximum = Get-MaximumMotion $retailMotion
$openmwMaximum = Get-MaximumMotion $openmwMotion
$missingRetail = @($retailMotion | Where-Object { $_.samples -eq 0 } | Select-Object -ExpandProperty node)
$missingOpenMW = @($openmwMotion | Where-Object { $_.samples -eq 0 } | Select-Object -ExpandProperty node)
$passed = $missingRetail.Count -eq 0 -and $missingOpenMW.Count -eq 0 `
    -and $null -ne $retailMaximum -and $retailMaximum -le $ToleranceDegrees `
    -and $null -ne $openmwMaximum -and $openmwMaximum -le $ToleranceDegrees

$report = [ordered]@{
    schema = "nikami-bethesda-bone-lod-motion/v1"
    status = if ($passed) { "matched" } else { "diverged" }
    toleranceDegrees = $ToleranceDegrees
    authoredGroup = 0
    authoredNodeCount = $groupZero.Count
    retail = [ordered]@{
        path = $retail
        selectedFrameRange = @($RetailStartFrame, $RetailEndFrame)
        frameCount = $retailFrames.Count
        maximumRotationFromFirstDegrees = $retailMaximum
        missingNodes = $missingRetail
        nodes = $retailMotion
    }
    openmw = [ordered]@{
        path = $openmw
        frameCount = $openmwFrames.Count
        maximumRotationFromFirstDegrees = $openmwMaximum
        missingNodes = $missingOpenMW
        nodes = $openmwMotion
    }
}

$json = $report | ConvertTo-Json -Depth 8
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutput = Resolve-InputPath $OutputPath
    $outputDirectory = Split-Path -Parent $resolvedOutput
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    [IO.File]::WriteAllText($resolvedOutput, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
$json

if (-not $passed) {
    exit 1
}
