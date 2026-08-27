[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OpenNvRoot,
    [Parameter(Mandatory)]
    [string]$ActorReviewScene,
    [string]$ActorReviewBackgroundCell = '',
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [Parameter(Mandatory)]
    [string]$Godot,
    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-CapturePath([string]$Path) {
    return [IO.Path]::GetFullPath($Path)
}

function Get-FileEvidence([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject][ordered]@{
        path = $item.FullName
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$openNvDirectory = Resolve-CapturePath $OpenNvRoot
$scenePath = Resolve-CapturePath $ActorReviewScene
$backgroundCellPath = if ([string]::IsNullOrWhiteSpace($ActorReviewBackgroundCell)) {
    $null
} else {
    Resolve-CapturePath $ActorReviewBackgroundCell
}
$outputDirectory = Resolve-CapturePath $OutputRoot
$godotPath = Resolve-CapturePath $Godot
$runtimeDirectory = Join-Path $openNvDirectory 'runtime'
$projectPath = Join-Path $runtimeDirectory 'project.godot'
$projectFile = Join-Path $runtimeDirectory 'OpenNV.csproj'
foreach ($path in @($scenePath, $godotPath, $projectPath, $projectFile)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing OpenNV actor-review input: $path"
    }
}
if ($null -ne $backgroundCellPath -and
    -not (Test-Path -LiteralPath $backgroundCellPath -PathType Leaf)) {
    throw "Missing OpenNV actor-review owned CELL background: $backgroundCellPath"
}
if (Test-Path -LiteralPath $outputDirectory) {
    throw "Refusing to overwrite OpenNV actor-review capture: $outputDirectory"
}
$active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match '^(Godot.*|openmw|FalloutNV|nvse_loader)$'
})
if ($active.Count -ne 0) {
    throw "Actor-review capture requires idle engines: $($active.ProcessName -join ', ')"
}

$scene = Get-Content -Raw -LiteralPath $scenePath | ConvertFrom-Json
if ([string]$scene.schema -cne 'opennv-actor-review-scene/v1' -or
    [string]$scene.status -cne 'compiled-retail-observed-pending-godot-capture') {
    throw 'ActorReviewScene is not a compiled pending actor review.'
}
if ([string]$scene.recordType -cnotin @('NPC_', 'CREA')) {
    throw "ActorReviewScene has unsupported record type: $($scene.recordType)"
}
$backgroundCell = $null
$backgroundCellSha256 = ''
if ($null -ne $backgroundCellPath) {
    $backgroundCell = Get-Content -Raw -LiteralPath $backgroundCellPath | ConvertFrom-Json
    if ([string]$backgroundCell.schema -cne 'opennv-cell-scene/v10' -or
        [string]$backgroundCell.status -cne 'geometry-structure' -or
        [string]$backgroundCell.cell.formId -cnotmatch '^[0-9a-f]{8}$') {
        throw 'ActorReviewBackgroundCell is not a compiled OpenNV CELL scene.'
    }
    $backgroundCellSha256 =
        (Get-FileHash -LiteralPath $backgroundCellPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
$retailContractPath = Resolve-CapturePath ([string]$scene.retailContract.path)
if (-not (Test-Path -LiteralPath $retailContractPath -PathType Leaf) -or
    (Get-FileHash -LiteralPath $retailContractPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne
        [string]$scene.retailContract.sha256) {
    throw 'ActorReviewScene retail contract is missing or changed.'
}

dotnet build $projectFile | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'OpenNV runtime build failed before actor-review capture.'
}

New-Item -ItemType Directory -Path $outputDirectory | Out-Null
$nativeRoot = Join-Path $outputDirectory 'native-source-frames'
$engineReport = Join-Path $outputDirectory 'actor-review-engine-report.json'
$stdoutPath = Join-Path $outputDirectory 'godot.stdout.log'
$stderrPath = Join-Path $outputDirectory 'godot.stderr.log'
$godotLog = Join-Path $outputDirectory 'godot.log'
$startedAt = Get-Date
$process = $null
try {
    $arguments = @(
        '--xr-mode', 'off',
        '--path', $runtimeDirectory,
        '--log-file', $godotLog,
        '--',
        '--actor-review-scene', $scenePath,
        '--capture-root', $nativeRoot,
        '--report', $engineReport
    )
    if ($null -ne $backgroundCellPath) {
        $arguments += @('--actor-review-background-cell', $backgroundCellPath)
    }
    $process = Start-Process `
        -FilePath $godotPath `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        throw "OpenNV actor-review capture exceeded $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    $process.Refresh()
    if ($null -ne $process.ExitCode -and $process.ExitCode -ne 0) {
        throw "OpenNV actor-review Godot process failed with exit code $($process.ExitCode)."
    }
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $engineReport -PathType Leaf)) {
    throw "OpenNV actor-review engine report was not retained: $engineReport"
}
$engine = Get-Content -Raw -LiteralPath $engineReport | ConvertFrom-Json
$nativeFrames = @(Get-ChildItem -LiteralPath $nativeRoot -Filter '*.png' -File | Sort-Object Name)
$expectedSamples = @($engine.samples).Count
$backgroundMatched = if ($null -eq $backgroundCellPath) {
    $null -eq $engine.presentation.background
} else {
    $null -ne $engine.presentation.background -and
        [string]$engine.presentation.background.mode -ceq 'owned-cell-content' -and
        [IO.Path]::GetFullPath([string]$engine.presentation.background.scene) -ceq
            $backgroundCellPath -and
        [string]$engine.presentation.background.sceneSha256 -ceq $backgroundCellSha256 -and
        [string]$engine.presentation.background.cellFormId -ceq
            [string]$backgroundCell.cell.formId
}
$captured = [string]$engine.status -ceq 'captured-provisional-light-direction' -and
    -not [bool]$engine.parityPassed -and
    [bool]$engine.pose.allSkinPaletteGatesPassed -and
    [bool]$engine.pose.exactRetailRenderCacheResolvedIntoImportedParentGraph -and
    [bool]$engine.presentation.projectionResolved -and
    [bool]$engine.presentation.exactRetailCameraAppliedPerSourceFrame -and
    [bool]$engine.presentation.exactRetailFinalSceneColorProjectionAppliedPerSourceFrame -and
    [bool]$engine.presentation.retailNiCameraCullingProjectionRetainedSeparately -and
    [bool]$engine.allVisualGatesPassed -and
    $backgroundMatched -and
    $expectedSamples -gt 0 -and $nativeFrames.Count -eq $expectedSamples -and
    -not [bool]$engine.windowsAppControlUsed -and
    -not [bool]$engine.foregroundActivationUsed -and
    -not [bool]$engine.foregroundInputInjected
if (-not $captured) {
    throw "OpenNV actor-review capture failed its native-frame, skin-palette, or no-control gate: $engineReport"
}

$artifactPaths = @($scenePath, $retailContractPath)
if ($null -ne $backgroundCellPath) { $artifactPaths += $backgroundCellPath }
$artifactPaths += @($engineReport, $stdoutPath, $stderrPath, $godotLog) +
    @($nativeFrames.FullName)
$artifacts = @($artifactPaths | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
} | ForEach-Object { Get-FileEvidence $_ })
$report = [ordered]@{
    schema = 'nikami-opennv-actor-review-capture/v1'
    status = 'captured-pending-parity'
    startedAt = $startedAt.ToString('o')
    completedAt = (Get-Date).ToString('o')
    reviewKey = [string]$scene.reviewKey
    recordType = [string]$scene.recordType
    capture = [ordered]@{
        method = 'Godot engine-owned viewport PNGs driven by the immutable retail actor-review contract'
        sourceFrames = $nativeFrames.Count
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        outputOverwritten = $false
        ownedCellBackground = $null -ne $backgroundCellPath
    }
    engine = $engine
    evidencePolicy = [ordered]@{
        retailIsReferenceOnly = $true
        captureIsNotParityPass = $true
        exactRetailProjectionRequired = $true
        exactRetailSkinPaletteRequired = $true
        unresolvedLightDirectionCannotPass = $true
        ownedCellBackgroundRequired = $null -ne $backgroundCellPath
        ownedCellBackgroundMatched = $backgroundMatched
    }
    artifacts = $artifacts
}
$reportPath = Join-Path $outputDirectory 'opennv-actor-review-report.json'
[IO.File]::WriteAllText(
    $reportPath,
    ($report | ConvertTo-Json -Depth 40) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 40
