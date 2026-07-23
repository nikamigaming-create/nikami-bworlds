[CmdletBinding()]
param(
    [string]$GameDataRoot = "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data",
    [string]$OpenMwRoot = "D:\code\nikami-openmw-actor-life-state",
    [string]$ObScriptPipelineRoot = "D:\code\obscript-pipeline-review",
    [string]$PyFfiRoot = "D:\code\niftools-pyffi",
    [string]$NifXmlRoot = "D:\code\niftools-nifxml",
    [string]$LuaExe = "D:\code\nikami-openmw-lab\deps\vcpkg-x64-2022-m1.0\installed\x64-windows\tools\luajit\luajit.exe",
    [string]$BsaToolExe = "D:\code\nikami-openmw-lab\MSVC2022_64\RelWithDebInfo\bsatool.exe",
    [string]$RuntimeDependencyRoot = "D:\code\nikami-openmw-lab\deps\vcpkg-x64-2022-m1.0\installed\x64-windows",
    [string]$QtBin = "D:\code\nikami-openmw-lab\deps\Qt\6.6.3\msvc2019_64\bin",
    [string]$OutputRoot = "",
    [switch]$SkipObScript,
    [switch]$SkipAssets,
    [switch]$AllowUnpinnedTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$expectedRevisions = [ordered]@{
    obscriptPipeline = "9de1a5d93414990f97abec64da2848c18a876e68"
    pyffi = "7f4404dbb8cf832dadd4b3150819340b8764f9b0"
    nifxml = "970a6238218a106daaeb89a61bcda0eeaf9d08c4"
}

function Resolve-RequiredPath([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label was not found: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-Checked([string]$Label, [scriptblock]$Command) {
    Write-Host "==> $Label"
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Get-GitRevision([string]$Root, [string]$Label) {
    $revision = (& git -C $Root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $revision) {
        throw "Could not read $Label revision from $Root"
    }
    return $revision
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$gameData = Resolve-RequiredPath $GameDataRoot "FNV Data directory"
$openmw = Resolve-RequiredPath $OpenMwRoot "OpenMW source tree"
$pipeline = Resolve-RequiredPath $ObScriptPipelineRoot "obscript-pipeline"
$pyffi = Resolve-RequiredPath $PyFfiRoot "NifTools PyFFI"
$nifxml = Resolve-RequiredPath $NifXmlRoot "NifTools nif.xml"

if (-not $OutputRoot) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputRoot = Join-Path $repoRoot "run\fnv-parity-toolchain\$stamp"
}
$output = [IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Force -Path $output | Out-Null

$revisions = [ordered]@{
    obscriptPipeline = Get-GitRevision $pipeline "obscript-pipeline"
    pyffi = Get-GitRevision $pyffi "PyFFI"
    nifxml = Get-GitRevision $nifxml "nif.xml"
    openmw = Get-GitRevision $openmw "OpenMW"
}
if (-not $AllowUnpinnedTools) {
    foreach ($name in $expectedRevisions.Keys) {
        if ($revisions[$name] -ne $expectedRevisions[$name]) {
            throw "$name revision $($revisions[$name]) does not match pinned $($expectedRevisions[$name]). Use -AllowUnpinnedTools only for deliberate tool upgrades."
        }
    }
}

$summary = [ordered]@{
    status = "pass"
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    output = $output
    revisions = $revisions
    obscript = [ordered]@{ status = "skipped" }
    assets = [ordered]@{ status = "skipped" }
    esplugin = [ordered]@{
        status = "pending"
        reason = "esplugin is a Rust library, not a CLI; the pinned audit runner is the next toolchain slice."
        source = "https://github.com/Ortham/esplugin"
        reviewedRevision = "e01c5b01e2c0d647b40453f01353eef29c4db691"
    }
}

if (-not $SkipObScript) {
    $plugins = @(
        "FalloutNV.esm", "DeadMoney.esm", "HonestHearts.esm", "OldWorldBlues.esm",
        "LonesomeRoad.esm", "TribalPack.esm", "MercenaryPack.esm", "ClassicPack.esm",
        "CaravanPack.esm", "GunRunnersArsenal.esm"
    )
    $corpusRoot = Join-Path $output "obscript"
    $corpusDirs = [Collections.Generic.List[string]]::new()
    foreach ($plugin in $plugins) {
        $pluginPath = Resolve-RequiredPath (Join-Path $gameData $plugin) $plugin
        $pluginOutput = Join-Path $corpusRoot ([IO.Path]::GetFileNameWithoutExtension($plugin))
        Invoke-Checked "Extract $plugin scripts" {
            & python (Join-Path $pipeline "tools\extract_scripts.py") $pluginPath $pluginOutput
        }
        $corpusDirs.Add($pluginOutput)
    }

    $lua = Resolve-RequiredPath $LuaExe "LuaJIT differential interpreter"
    $previousLua = $env:LUA
    try {
        $env:LUA = $lua
        Invoke-Checked "Compare Python and Lua ObScript ASTs" {
            & python (Join-Path $pipeline "tools\diff_asts.py") $corpusRoot (Join-Path $openmw "files\data")
        }
        Invoke-Checked "Compare Python and Lua emitted code" {
            & python (Join-Path $pipeline "tools\diff_lua.py") $corpusRoot (Join-Path $openmw "files\data")
        }
    }
    finally {
        $env:LUA = $previousLua
    }

    $analysis = Join-Path $output "obscript-analysis"
    Invoke-Checked "Analyze FNV ObScript command coverage" {
        & python (Join-Path $pipeline "tools\analyze_scripts.py") @corpusDirs $analysis
    }
    $summary.obscript = [ordered]@{
        status = "pass"
        plugins = $plugins.Count
        corpus = $corpusRoot
        analysis = $analysis
        headline = (Get-Content (Join-Path $analysis "summary.txt") -Raw).Trim()
    }
}

if (-not $SkipAssets) {
    $bsa = Resolve-RequiredPath (Join-Path $gameData "Fallout - Meshes.bsa") "FNV mesh archive"
    $bsaTool = Resolve-RequiredPath $BsaToolExe "OpenMW bsatool"
    $nifTest = Resolve-RequiredPath (Join-Path $openmw "MSVC2022_64\RelWithDebInfo\niftest.exe") "OpenMW niftest"
    $assetRoot = Join-Path $output "assets"
    $assetNames = @(
        "meshes\creatures\nvsecuritron\skeleton.nif",
        "meshes\creatures\nvsecuritron\nvsecuritron.nif",
        "meshes\creatures\nvsecuritron\talking.kf",
        "meshes\creatures\nvsecuritron\idleanims\specialidle_greet.kf",
        "meshes\characters\_male\skeleton.nif",
        "meshes\characters\_1stperson\skeleton.nif",
        "meshes\characters\head\headhuman.nif",
        "meshes\characters\head\headhuman.egm",
        "meshes\weapons\1handpistol\10mmpistol.nif",
        "meshes\architecture\goodsprings\nv_prospectorsaloon_door.nif"
    )
    foreach ($asset in $assetNames) {
        Invoke-Checked "Extract $asset" { & $bsaTool extract -f $bsa $asset $assetRoot }
    }
    $assetPaths = $assetNames | ForEach-Object { Resolve-RequiredPath (Join-Path $assetRoot $_) $_ }
    Invoke-Checked "Parse real FNV assets with NifTools PyFFI" {
        & python (Join-Path $PSScriptRoot "audit_fnv_niftools.py") --pyffi-root $pyffi @assetPaths
    }
    $nifPaths = @($assetPaths | Where-Object { [IO.Path]::GetExtension($_) -in @(".nif", ".kf") })
    $dependencyRoot = Resolve-RequiredPath $RuntimeDependencyRoot "OpenMW runtime dependency root"
    $qt = Resolve-RequiredPath $QtBin "Qt runtime directory"
    $previousPath = $env:PATH
    try {
        $env:PATH = "$dependencyRoot\bin;$dependencyRoot\bin\Release;$qt;$previousPath"
        Invoke-Checked "Parse the same FNV assets with OpenMW niftest" { & $nifTest @nifPaths }
    }
    finally {
        $env:PATH = $previousPath
    }
    $summary.assets = [ordered]@{
        status = "pass"
        count = $assetPaths.Count
        root = $assetRoot
        oracles = @("NifTools PyFFI", "OpenMW niftest")
    }
}

$summaryPath = Join-Path $output "summary.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
Write-Host "FNV parity toolchain passed. Summary: $summaryPath"
