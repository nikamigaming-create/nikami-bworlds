param(
    [string]$EquationPath = "run/retail-oracle/fnv-retail-v32-bone-lod-equation-walk.jsonl",
    [string]$TransitionPath = "run/retail-oracle/fnv-retail-v41-high-process-guard-values.jsonl",
    [string]$LodOnePath = "run/retail-oracle/fnv-retail-v12-bone-lod-structured.jsonl",
    [string]$LodTwoPath = "run/retail-oracle/fnv-retail-v25-bone-lod-visible-2700.jsonl",
    [string]$BoneLodAuditPath = "run/transform-oracle/kf-samples/2hrforward-bone-lod-audit.json",
    [string]$OutputPath = "",
    [double]$Tolerance = 0.00001
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-InputPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Read-JsonLines([string]$Path) {
    $records = [Collections.Generic.List[object]]::new()
    foreach ($line in [IO.File]::ReadLines((Resolve-InputPath $Path))) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $records.Add(($line | ConvertFrom-Json)) }
    }
    return @($records)
}

function Get-BlendFlagsByNode($Frame) {
    $flags = @{}
    foreach ($sequence in @($Frame.animDataSequences)) {
        if ($null -eq $sequence) { continue }
        foreach ($block in @($sequence.controlledBlocks)) {
            if ($null -eq $block -or $null -eq $block.blend -or [string]::IsNullOrWhiteSpace($block.object)) {
                continue
            }
            $flags[[string]$block.object] = [int]$block.blend.flags
        }
    }
    return $flags
}

function Test-FrozenGroups($Frame, $Groups, [int[]]$FrozenGroups) {
    $flags = Get-BlendFlagsByNode $Frame
    $failures = [Collections.Generic.List[string]]::new()
    $tested = 0
    foreach ($group in @($Groups)) {
        foreach ($node in @($group.nodes)) {
            if ($node -eq "Weapon" -or -not $flags.ContainsKey([string]$node)) { continue }
            ++$tested
            $expected = if ($FrozenGroups -contains [int]$group.index) { 5 } else { 1 }
            if ([int]$flags[[string]$node] -ne $expected) {
                $failures.Add("LOD $($Frame.boneLodController.currentLod) group $($group.index) node '$node' has blend flags $($flags[[string]$node]), expected $expected")
            }
        }
    }
    return [ordered]@{ testedNodes = $tested; failures = @($failures) }
}

$equationRecords = Read-JsonLines $EquationPath
$transitionRecords = Read-JsonLines $TransitionPath
$lodOneRecords = Read-JsonLines $LodOnePath
$lodTwoRecords = Read-JsonLines $LodTwoPath
$audit = Get-Content -LiteralPath (Resolve-InputPath $BoneLodAuditPath) -Raw | ConvertFrom-Json
$groups = @($audit.boneLodControllers[0].groups)

$failures = [Collections.Generic.List[string]]::new()
$equationFrames = @($equationRecords | Where-Object {
        $_.event -eq "actor-frame" -and $null -ne $_.boneLodInputs -and $null -ne $_.cameraDistance
    })
$maximumQuotientError = 0.0
foreach ($frame in $equationFrames) {
    $inputs = $frame.boneLodInputs
    $expected = ([double]$frame.cameraDistance / [double]$inputs.actorScale) * [double]$inputs.distanceConstant `
        * [double]$inputs.cameraLodAdjust / ([double]$inputs.distanceMultiplier * [double]$inputs.actorFadeMultiplier)
    $quotientError = [Math]::Abs($expected - [double]$inputs.quotient)
    $maximumQuotientError = [Math]::Max($maximumQuotientError, $quotientError)
    if ($quotientError -gt $Tolerance) { $failures.Add("Frame $($frame.frame) quotient error $quotientError exceeds $Tolerance") }
    if ([int][Math]::Floor($expected) -ne [int]$inputs.predictedLod) {
        $failures.Add("Frame $($frame.frame) predicted LOD does not equal floor(retail quotient)")
    }
}
if ($equationFrames.Count -eq 0) { $failures.Add("No retail equation frames were found") }

$start = @($transitionRecords | Where-Object { $_.event -eq "start" }) | Select-Object -First 1
if ($null -eq $start -or -not $start.boneLodWriterCallsHooked -or -not $start.highProcessBoneLodPathHooked) {
    $failures.Add("The transition capture did not confirm both retail call hooks")
}
$guards = @($transitionRecords | Where-Object { $_.event -eq "high-process-bone-lod-path" } | Sort-Object frame)
$writerCalls = @($transitionRecords | Where-Object { $_.event -eq "bone-lod-writer-call" } | Sort-Object frame)
$firstOpenGuard = @($guards | Where-Object { -not $_.guards.processStateGate }) | Select-Object -First 1
$firstWriter = $writerCalls | Select-Object -First 1
if ($null -eq $firstOpenGuard -or $null -eq $firstWriter) {
    $failures.Add("The transition capture is missing the guard opening or writer call")
}
elseif ([int]$firstOpenGuard.frame -ne [int]$firstWriter.frame) {
    $failures.Add("Writer first ran at frame $($firstWriter.frame), guard opened at frame $($firstOpenGuard.frame)")
}
if (@($guards | Where-Object { [int]$_.frame -lt [int]$firstOpenGuard.frame -and -not $_.guards.processStateGate }).Count -ne 0) {
    $failures.Add("The temporary AnimData guard opened before the recorded transition")
}
if (@($writerCalls | Where-Object { [int]$_.frame -lt [int]$firstOpenGuard.frame }).Count -ne 0) {
    $failures.Add("The bone-LOD writer ran while the temporary AnimData guard was occupied")
}
if ($writerCalls.Count -gt 0) {
    $writerFrames = @($writerCalls | ForEach-Object { [int]$_.frame })
    foreach ($frame in $writerFrames[0]..$writerFrames[-1]) {
        if ($writerFrames -notcontains $frame) { $failures.Add("Retail writer cadence skipped frame $frame after the guard opened") }
    }
}

$lodOneFrame = @($lodOneRecords | Where-Object {
        $_.event -eq "actor-frame" -and [int]$_.boneLodController.currentLod -eq 1 -and [int]$_.frame -ge 64
    }) | Select-Object -Last 1
$lodTwoFrame = @($lodTwoRecords | Where-Object {
        $_.event -eq "actor-frame" -and [int]$_.boneLodController.currentLod -eq 2
    }) | Select-Object -Last 1
if ($null -eq $lodOneFrame -or $null -eq $lodTwoFrame) {
    $failures.Add("The stabilized LOD 1 or LOD 2 frame is missing")
    $lodOneResult = [ordered]@{ testedNodes = 0; failures = @("missing frame") }
    $lodTwoResult = [ordered]@{ testedNodes = 0; failures = @("missing frame") }
}
else {
    $lodOneResult = Test-FrozenGroups $lodOneFrame $groups @(0)
    $lodTwoResult = Test-FrozenGroups $lodTwoFrame $groups @(0, 1)
    foreach ($failure in @($lodOneResult.failures) + @($lodTwoResult.failures)) { $failures.Add($failure) }
}

$report = [ordered]@{
    schema = "nikami-fnv-retail-bone-lod-parity/v1"
    status = if ($failures.Count -eq 0) { "matched" } else { "diverged" }
    equation = [ordered]@{
        frames = $equationFrames.Count
        maximumQuotientError = $maximumQuotientError
        tolerance = $Tolerance
    }
    transition = [ordered]@{
        guardSamples = $guards.Count
        firstOpenGuardFrame = if ($null -ne $firstOpenGuard) { [int]$firstOpenGuard.frame } else { $null }
        writerCalls = $writerCalls.Count
        firstWriterFrame = if ($null -ne $firstWriter) { [int]$firstWriter.frame } else { $null }
    }
    cumulativeGroups = [ordered]@{ lodOne = $lodOneResult; lodTwo = $lodTwoResult }
    failures = @($failures)
}

$json = $report | ConvertTo-Json -Depth 8
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutput = Resolve-InputPath $OutputPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
    [IO.File]::WriteAllText($resolvedOutput, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
$json
if ($failures.Count -ne 0) { exit 1 }
