[CmdletBinding()]
param(
    [string]$GameRoot = "D:\SteamLibrary\steamapps\common\Dragon Age Ultimate Edition",
    [string]$OutputRoot,
    [string]$HavenRoot,
    [string]$Blender = "D:\SteamLibrary\steamapps\common\Blender\blender.exe",
    [string]$OpenMWBinary,
    [string]$OpenMWConfig,
    [string]$OpenMWResources,
    [string]$OpenMWStartCell = "AleswellInn",
    [int]$OpenMWRunSeconds = 30,
    [switch]$SkipBuild,
    [switch]$SkipOpenMW
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($HavenRoot)) {
    $HavenRoot = Join-Path $repoRoot "external\Haven-Tools"
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputRoot = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-$stamp"
}

$geometryRim = Join-Path $GameRoot "packages\core\env\lak100d\lak100d.rim"
$actorRim = Join-Path $GameRoot "modules\single player\data\al_arl01al_redcliffe_villag.rim"
$patchPath = Join-Path $repoRoot "patches\haven-tools\0001-dao-openmw-poc-cli.patch"
$composer = Join-Path $repoRoot "scripts\compose_dao_havenarea.py"
$havenExe = Join-Path $HavenRoot "build\Release\HavenTools.exe"

foreach ($required in @($GameRoot, $geometryRim, $actorRim, $patchPath, $composer, $Blender)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required path not found: $required"
    }
}
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite existing POC directory: $OutputRoot"
}

if (-not (Test-Path -LiteralPath (Join-Path $HavenRoot ".git"))) {
    New-Item -ItemType Directory -Path (Split-Path $HavenRoot) -Force | Out-Null
    git clone https://github.com/adarec1994/Haven-Tools.git $HavenRoot
    if ($LASTEXITCODE -ne 0) { throw "Haven Tools clone failed" }
}

$expectedCommit = "0765a5db7b5cea0cc5b405867deca7fa373921db"
$actualCommit = (git -C $HavenRoot rev-parse HEAD).Trim()
if ($actualCommit -ne $expectedCommit) {
    throw "Haven Tools revision mismatch. Expected $expectedCommit, got $actualCommit"
}

git -C $HavenRoot apply --reverse --check $patchPath 2>$null
if ($LASTEXITCODE -ne 0) {
    git -C $HavenRoot apply --check $patchPath
    if ($LASTEXITCODE -ne 0) { throw "Haven CLI patch does not apply cleanly" }
    git -C $HavenRoot apply $patchPath
    if ($LASTEXITCODE -ne 0) { throw "Haven CLI patch failed" }
}

if (-not $SkipBuild) {
    cmake -S $HavenRoot -B (Join-Path $HavenRoot "build") -A x64
    if ($LASTEXITCODE -ne 0) { throw "Haven CMake configure failed" }
    cmake --build (Join-Path $HavenRoot "build") --config Release
    if ($LASTEXITCODE -ne 0) { throw "Haven build failed" }
}
if (-not (Test-Path -LiteralPath $havenExe)) { throw "Haven executable not found: $havenExe" }

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
& $havenExe --batch-level $GameRoot $geometryRim $OutputRoot $actorRim
if ($LASTEXITCODE -ne 0) { throw "Haven Redcliffe export failed" }

$areaDir = Join-Path $OutputRoot "lak100d"
$areaFile = Join-Path $areaDir "lak100d.havenarea"
$objFile = Join-Path $areaDir "lak100d-openmw.obj"
$importer = Join-Path $HavenRoot "src\python\havenarea_importer.py"
& $Blender --background --python $composer -- $importer $areaFile $objFile
if ($LASTEXITCODE -ne 0) { throw "Blender scene composition failed" }
if (-not (Test-Path -LiteralPath $objFile)) { throw "OBJ was not produced: $objFile" }

$area = Get-Content -Raw -LiteralPath $areaFile | ConvertFrom-Json
$actors = @($area.actors)
$report = [ordered]@{
    schemaVersion = 1
    sourceGame = "Dragon Age: Origins"
    level = "Redcliffe Village"
    geometryResource = $geometryRim
    gameplayResource = $actorRim
    havenCommit = $expectedCommit
    havenArea = $areaFile
    openMwScene = $objFile
    terrainKinds = @($area.terrain.patches.PSObject.Properties).Count
    propKinds = @($area.props.PSObject.Properties).Count
    treeKinds = @($area.trees.PSObject.Properties).Count
    actorRecords = $actors.Count
    activeActorRecords = @($actors | Where-Object active).Count
    actorsAreVisualMeshes = $false
    openMwLoadVerified = $false
}

if (-not $SkipOpenMW -and -not [string]::IsNullOrWhiteSpace($OpenMWBinary)) {
    foreach ($required in @($OpenMWBinary, $OpenMWConfig, $OpenMWResources)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "OpenMW verification path not found: $required" }
    }
    $runDir = Join-Path $OutputRoot "openmw-load"
    New-Item -ItemType Directory -Path "$runDir\userdata\data","$runDir\config" -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $OpenMWConfig "openmw.cfg") -Destination "$runDir\config\openmw.cfg"
    Copy-Item -LiteralPath (Join-Path $OpenMWConfig "settings.cfg") -Destination "$runDir\config\settings.cfg"
    $previousScene = $env:OPENMW_WORLD_VIEWER_EXTRA_SCENE
    $previousScale = $env:OPENMW_WORLD_VIEWER_EXTRA_SCENE_SCALE
    try {
        $env:OPENMW_WORLD_VIEWER_EXTRA_SCENE = $objFile
        $env:OPENMW_WORLD_VIEWER_EXTRA_SCENE_SCALE = "1"
        $arguments = @("--replace", "config", "--config", "$runDir\config", "--user-data", "$runDir\userdata", "--data-local", "$runDir\userdata\data", "--resources", $OpenMWResources, "--skip-menu", "--start", $OpenMWStartCell, "--no-sound")
        $process = Start-Process -FilePath $OpenMWBinary -ArgumentList $arguments -WorkingDirectory (Split-Path $OpenMWBinary) -WindowStyle Hidden -RedirectStandardOutput "$runDir\stdout.log" -RedirectStandardError "$runDir\stderr.log" -PassThru
        if (-not $process.WaitForExit($OpenMWRunSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force
        }
        $log = Join-Path $runDir "config\openmw.log"
        if (Test-Path -LiteralPath $log) {
            $loadedLine = Select-String -LiteralPath $log -SimpleMatch "World viewer extra scene: loaded path=$objFile" | Select-Object -First 1
            $report.openMwLoadVerified = $null -ne $loadedLine
            $report.openMwLog = $log
            $report.openMwEvidence = if ($loadedLine) { $loadedLine.Line } else { $null }
        }
    }
    finally {
        $env:OPENMW_WORLD_VIEWER_EXTRA_SCENE = $previousScene
        $env:OPENMW_WORLD_VIEWER_EXTRA_SCENE_SCALE = $previousScale
    }
}

$reportPath = Join-Path $OutputRoot "poc-report.json"
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
$report | ConvertTo-Json -Depth 8
Write-Host "POC report: $reportPath"

