param(
    [string]$MatrixPath = "catalog/fnv-goodsprings-retail-matrix.json",
    [string]$PluginDll = "run/worktrees/xnvse-oracle/nvse_retail_oracle/build/nvse_retail_oracle.dll",
    [string]$SaveFixture = "run/retail-oracle/checkpoints/NikamiOracleEasyPeteSeated.fos",
    [string]$RunId = ("fnv-goodsprings-appearance-" + (Get-Date -Format "yyyyMMdd-HHmmss")),
    [string]$OutputRoot = "run/retail-oracle",
    [switch]$StageReferences
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

$matrixFile = Resolve-AbsolutePath $MatrixPath
$outputDirectory = Resolve-AbsolutePath (Join-Path $OutputRoot $RunId)
$runner = Join-Path $PSScriptRoot "Invoke-FNVRetailOracle.ps1"
$comparator = Join-Path $PSScriptRoot "compare_fnv_goodsprings_appearance.py"
$contactSheetScript = Join-Path $PSScriptRoot "New-ScreenshotContactSheet.ps1"

foreach ($required in @($matrixFile, (Resolve-AbsolutePath $PluginDll), (Resolve-AbsolutePath $SaveFixture),
        $runner, $comparator, $contactSheetScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing Goodsprings appearance-matrix dependency: $required"
    }
}
if (Test-Path -LiteralPath $outputDirectory) {
    throw "Refusing to overwrite an existing Goodsprings matrix run: $outputDirectory"
}
New-Item -ItemType Directory -Path $outputDirectory | Out-Null

$matrix = Get-Content -LiteralPath $matrixFile -Raw | ConvertFrom-Json
$humanoids = @($matrix.targets | Where-Object { $_.category -like "*humanoid" })
if ($humanoids.Count -ne [int]$matrix.scope.humanoidCount) {
    throw "Matrix humanoid count does not match its declared scope."
}

$captureByTarget = @{}
$groupRuns = New-Object System.Collections.Generic.List[object]
$groups = @($humanoids | Group-Object { $_.cell.form })
for ($groupIndex = 0; $groupIndex -lt $groups.Count; ++$groupIndex) {
    $group = $groups[$groupIndex]
    $targets = @($group.Group)
    $cellLabel = if (-not [string]::IsNullOrWhiteSpace([string]$targets[0].cell.editorId)) {
        [string]$targets[0].cell.editorId
    } else {
        [string]$targets[0].cell.form
    }
    $safeCellLabel = ($cellLabel -replace '[^A-Za-z0-9_-]', '-').ToLowerInvariant()
    $groupLabel = "{0:D2}-{1}" -f ($groupIndex + 1), $safeCellLabel
    $jsonl = Join-Path $outputDirectory "$groupLabel.jsonl"
    $screens = Join-Path $outputDirectory "$groupLabel-screens"
    $forms = @($targets | ForEach-Object { [string]$_.reference.form })
    $enableParents = @($targets | ForEach-Object { [string]$_.authoredPlacement.enableParent } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $runnerArguments = @{
        PluginDll = Resolve-AbsolutePath $PluginDll
        OutputPath = $jsonl
        ScreenshotDirectory = $screens
        BatchTargetForm = $forms
        BatchEnableParentForm = $enableParents
        BatchMoveToTargets = $true
        BatchSettleFrames = 90
        BatchAdvanceFrames = 3
        PortraitDistance = 70
        RequireAppearanceTelemetry = $true
        SaveFixture = Resolve-AbsolutePath $SaveFixture
        BeforeFrame = 5
        CommandFrame = 10
        AfterFrame = 15
        MaxFrames = [Math]::Max(200, $targets.Count * 140)
        SampleEvery = 1
        TimeoutSeconds = [Math]::Min(300, [Math]::Max(90, 45 + ($targets.Count * 22)))
        BackgroundDataMode = $true
    }
    if ($StageReferences) {
        $runnerArguments.BatchEnableTargets = $true
    }
    $run = & $runner @runnerArguments
    $groupRuns.Add([pscustomobject][ordered]@{
        label = $groupLabel
        cell = $group.Name
        targets = @($targets.id)
        output = $jsonl
        screenshots = @($run.screenshots)
        proofCrops = @($run.portraitProofCrops)
    }) | Out-Null
    foreach ($target in $targets) {
        $captureByTarget[[string]$target.id] = $jsonl
    }
}

$reportPath = Join-Path $outputDirectory "appearance-differential.json"
$compareArguments = @("--matrix", $matrixFile, "--out", $reportPath)
foreach ($target in $humanoids) {
    $compareArguments += @("--capture", "$($target.id)=$($captureByTarget[[string]$target.id])")
}
& python $comparator @compareArguments
if ($LASTEXITCODE -ne 0) {
    throw "Goodsprings appearance comparator exited with code $LASTEXITCODE."
}
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$humanoidIds = @($humanoids.id)
$failedHumanoids = @($report.rows | Where-Object {
    $_.id -in $humanoidIds -and $_.status -ne "passed"
})
if ($failedHumanoids.Count -gt 0) {
    throw "Goodsprings authored-to-retail differential failed for $($failedHumanoids.Count) humanoid(s)."
}

$contactSheet = Join-Path $outputDirectory "retail-contact-sheet.png"
& $contactSheetScript -ManifestPath $reportPath -OutputPath $contactSheet -Columns 4 | Out-Null

[pscustomobject][ordered]@{
    schema = "nikami-fnv-goodsprings-appearance-run/v1"
    runId = $RunId
    stagedReferences = [bool]$StageReferences
    targetCount = $humanoids.Count
    groupCount = $groups.Count
    passed = $humanoids.Count
    groups = @($groupRuns)
    report = $reportPath
    contactSheet = $contactSheet
    status = "retail-traits-passed-pixels-captured-review-required"
}
