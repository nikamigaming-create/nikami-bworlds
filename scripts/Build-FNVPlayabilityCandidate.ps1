[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-zA-Z._-]+$')]
    [string]$CandidateLabel,
    [string]$BuildRoot = "D:\code\nikami-worlds\local\build\fnv-playability-recovery-20260807",
    [string]$RuntimeRoot = "D:\code\nikami-worlds\local\labs\fnv-playability-recovery-runtime-20260807",
    [string]$VcpkgRoot = "D:\code\nikami-openmw-lab\deps\vcpkg-x64-2022-m1.0",
    [string]$RelWithDebInfoExeLinkerFlags = "",
    [switch]$ResumeExistingBuild,
    [ValidateRange(1, 16)]
    [int]$BuildJobs = 4
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-UnusedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to reuse or overwrite candidate path: $Path"
    }
}

$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$candidateBuildRoot = Join-Path ([IO.Path]::GetFullPath($BuildRoot)) $CandidateLabel
$candidateRuntimeRoot = Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) $CandidateLabel
$toolchain = Join-Path $VcpkgRoot "scripts\buildsystems\vcpkg.cmake"
$installedRoot = Join-Path $VcpkgRoot "installed\x64-windows"
$luaLibrary = Join-Path $installedRoot "lib\lua51.lib"
$myGuiDll = Join-Path $VcpkgRoot "packages\mygui_x64-windows\bin\Release\MyGUIEngine.dll"
$osgPluginRoot = Join-Path $VcpkgRoot "packages\osg_x64-windows\plugins\osgPlugins-3.6.5"

foreach ($path in @($SourceRoot, $toolchain, $luaLibrary, $myGuiDll, $osgPluginRoot)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing candidate build requirement: $path"
    }
}
Assert-UnusedPath $candidateRuntimeRoot
if ($ResumeExistingBuild) {
    $cachePath = Join-Path $candidateBuildRoot "CMakeCache.txt"
    if (-not (Test-Path -LiteralPath $cachePath)) {
        throw "Cannot resume candidate without an existing CMake cache: $candidateBuildRoot"
    }
    $cachedSource = Get-Content -LiteralPath $cachePath |
        Where-Object { $_ -like 'CMAKE_HOME_DIRECTORY:INTERNAL=*' } |
        Select-Object -First 1
    if ($null -eq $cachedSource -or $cachedSource.Split('=', 2)[1] -ne $SourceRoot.Replace('\', '/')) {
        throw "Refusing to resume candidate configured from another source root: $candidateBuildRoot"
    }
}
else {
    Assert-UnusedPath $candidateBuildRoot
}

$status = @(git -C $SourceRoot status --porcelain)
if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) {
    throw "Candidate source must be a clean Git worktree: $SourceRoot"
}
$commit = (git -C $SourceRoot rev-parse HEAD).Trim()
$tree = (git -C $SourceRoot rev-parse 'HEAD^{tree}').Trim()

$glCompatibilityDefinitions = @(
    "/DGL_COMPRESSED_SRGB_S3TC_DXT1_EXT=0x8C4C",
    "/DGL_COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT=0x8C4D",
    "/DGL_COMPRESSED_SRGB_ALPHA_S3TC_DXT3_EXT=0x8C4E",
    "/DGL_COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT=0x8C4F"
)
$cxxFlags = "/DWIN32 /D_WINDOWS /GR /EHsc " + ($glCompatibilityDefinitions -join " ")

if (-not $ResumeExistingBuild) {
    cmake -S $SourceRoot -B $candidateBuildRoot -G "Visual Studio 17 2022" -A x64 `
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" `
        "-DLuaJit_LIBRARY=$luaLibrary" `
        "-DCMAKE_CXX_FLAGS=$cxxFlags" `
        "-DCMAKE_EXE_LINKER_FLAGS_RELWITHDEBINFO=$RelWithDebInfoExeLinkerFlags" `
        -DBUILD_OPENMW=ON `
        -DBUILD_OPENMW_VR=OFF `
        -DBUILD_OPENMW_TESTS=ON `
        -DBUILD_COMPONENTS_TESTS=ON `
        -DBUILD_LAUNCHER=OFF `
        -DBUILD_WIZARD=OFF `
        -DBUILD_OPENCS=OFF `
        -DBUILD_OPENCS_TESTS=OFF
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed for $CandidateLabel" }
}

$targets = @(
    "openmw", "components-tests", "bsatool", "esmtool", "openmw-iniimporter",
    "openmw-essimporter", "niftest", "openmw-navmeshtool", "openmw-bulletobjecttool"
)
cmake --build $candidateBuildRoot --config RelWithDebInfo --target $targets -- "/m:$BuildJobs"
if ($LASTEXITCODE -ne 0) { throw "Candidate build failed for $CandidateLabel" }

cmake --install $candidateBuildRoot --config RelWithDebInfo --prefix $candidateRuntimeRoot
if ($LASTEXITCODE -ne 0) { throw "Candidate install failed for $CandidateLabel" }

# CMake's install set omits these linked runtime assets. They are staged from
# the exact vcpkg tree used at link time, never borrowed from another runtime.
Copy-Item -LiteralPath $myGuiDll -Destination (Join-Path $candidateRuntimeRoot "MyGUIEngine.dll")
$runtimePluginRoot = Join-Path $candidateRuntimeRoot "osgPlugins-3.6.5"
[void](New-Item -ItemType Directory -Path $runtimePluginRoot)
Get-ChildItem -LiteralPath $osgPluginRoot -File | Copy-Item -Destination $runtimePluginRoot

$resourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $candidateRuntimeRoot "resources") -Recurse -File)
$pluginFiles = @(Get-ChildItem -LiteralPath $runtimePluginRoot -File)
$openmwPath = Join-Path $candidateRuntimeRoot "openmw.exe"
$manifest = [ordered]@{
    schema = "nikami-fnv-playability-candidate-runtime/v1"
    createdUtc = [DateTime]::UtcNow.ToString("o")
    status = "candidate-tests-pending"
    candidate = [ordered]@{
        label = $CandidateLabel
        commit = $commit
        tree = $tree
        sourceRoot = $SourceRoot
        sourceClean = $true
    }
    build = [ordered]@{
        root = $candidateBuildRoot
        configuration = "RelWithDebInfo"
        generator = "Visual Studio 17 2022"
        architecture = "x64"
        toolchain = $toolchain
        cmakeVersion = (cmake --version | Select-Object -First 1)
        compatibilityDefinitions = $glCompatibilityDefinitions
        compatibilityScope = "compiler-only GL header compatibility; no source or gameplay behavior change"
        executableLinkerFlags = $RelWithDebInfoExeLinkerFlags
        targets = $targets
    }
    runtime = [ordered]@{
        root = $candidateRuntimeRoot
        openmwSha256 = (Get-FileHash -LiteralPath $openmwPath -Algorithm SHA256).Hash.ToLowerInvariant()
        resourceFileCount = $resourceFiles.Count
        resourceBytes = ($resourceFiles | Measure-Object Length -Sum).Sum
        osgPluginCount = $pluginFiles.Count
        osgPluginBytes = ($pluginFiles | Measure-Object Length -Sum).Sum
        supplementalDependencySources = @($myGuiDll, $osgPluginRoot)
    }
    verification = [ordered]@{
        componentTestsPassed = $false
        capturePreflightPassed = $false
        engineLaunched = $false
        inGameRoutePassed = $false
    }
}
$manifestPath = Join-Path $candidateRuntimeRoot "candidate-runtime-manifest.json"
[IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    schema = "nikami-fnv-playability-candidate-build/v1"
    status = "pass"
    candidate = $CandidateLabel
    commit = $commit
    buildRoot = $candidateBuildRoot
    runtimeRoot = $candidateRuntimeRoot
    manifest = $manifestPath
}
