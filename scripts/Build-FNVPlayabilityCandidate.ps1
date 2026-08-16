[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-zA-Z._-]+$')]
    [string]$CandidateLabel,
    [string]$BuildRoot = "",
    [string]$RuntimeRoot = "",
    [Parameter(Mandatory = $true)]
    [string]$VcpkgRoot,
    [string]$RelWithDebInfoExeLinkerFlags = "",
    [switch]$EnableVr,
    [switch]$AllowDirtyDiagnostic,
    [switch]$SkipComponentTests,
    [switch]$ResumeExistingBuild,
    [switch]$ResumeUnverifiedStaging,
    [ValidateRange(1, 16)]
    [int]$BuildJobs = 4
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    $BuildRoot = Join-Path $repoRoot "local\build\fnv-playability-recovery"
}
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = Join-Path $repoRoot "local\labs\fnv-playability-recovery-runtime"
}

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
$openXrLoaderDll = Join-Path $installedRoot "bin\openxr_loader.dll"

foreach ($path in @($SourceRoot, $toolchain, $luaLibrary, $myGuiDll, $osgPluginRoot)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing candidate build requirement: $path"
    }
}
if ($ResumeUnverifiedStaging -and -not $ResumeExistingBuild) {
    throw "-ResumeUnverifiedStaging requires -ResumeExistingBuild."
}
if (Test-Path -LiteralPath $candidateRuntimeRoot) {
    $existingManifestPath = Join-Path $candidateRuntimeRoot "candidate-runtime-manifest.json"
    if (-not $ResumeUnverifiedStaging) {
        Assert-UnusedPath $candidateRuntimeRoot
    }
    if (Test-Path -LiteralPath $existingManifestPath) {
        throw "Refusing to resume a manifest-bearing candidate runtime: $candidateRuntimeRoot"
    }
    foreach ($requiredRuntimeFile in @("openmw.exe", "openmw_vr.exe", "resources")) {
        if (-not (Test-Path -LiteralPath (Join-Path $candidateRuntimeRoot $requiredRuntimeFile))) {
            throw "Cannot resume incomplete candidate staging; missing $requiredRuntimeFile in $candidateRuntimeRoot"
        }
    }
}
else {
    Assert-UnusedPath $candidateRuntimeRoot
}
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
if ($LASTEXITCODE -ne 0) {
    throw "Candidate source must be a Git worktree: $SourceRoot"
}
if ($status.Count -ne 0 -and -not $AllowDirtyDiagnostic) {
    throw "Candidate source must be a clean Git worktree: $SourceRoot"
}
$commit = (git -C $SourceRoot rev-parse HEAD).Trim()
$tree = (git -C $SourceRoot rev-parse 'HEAD^{tree}').Trim()
$sourceClean = $status.Count -eq 0
$sourceDiffSha256 = if ($sourceClean) { $null } else {
    $diffBytes = [Text.Encoding]::UTF8.GetBytes((git -C $SourceRoot diff --binary | Out-String))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($diffBytes)).ToLowerInvariant()
}
$candidateStatus = if ($sourceClean) { "candidate-tests-pending" } else { "diagnostic-source-dirty" }

function ConvertTo-RepositoryRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRepoRoot = [IO.Path]::GetFullPath($repoRoot).TrimEnd([char[]]@('\', '/'))
    if ($fullPath.StartsWith($fullRepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($fullRepoRoot.Length).TrimStart([char[]]@('\', '/')) -replace '\\', '/'
    }
    return $null
}

$glCompatibilityDefinitions = @(
    "/DGL_COMPRESSED_SRGB_S3TC_DXT1_EXT=0x8C4C",
    "/DGL_COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT=0x8C4D",
    "/DGL_COMPRESSED_SRGB_ALPHA_S3TC_DXT3_EXT=0x8C4E",
    "/DGL_COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT=0x8C4F"
)
# /FS makes PDB writes safe when CMake/MSBuild compile a large project with
# parallel workers. Without it, otherwise valid candidate builds can fail with
# C1041 while two compiler processes open the same component PDB.
$cxxFlags = "/DWIN32 /D_WINDOWS /GR /EHsc /FS " + ($glCompatibilityDefinitions -join " ")
$buildOpenMwVr = if ($EnableVr) { "ON" } else { "OFF" }

if (-not $ResumeExistingBuild) {
    cmake -S $SourceRoot -B $candidateBuildRoot -G "Visual Studio 17 2022" -A x64 `
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" `
        "-DLuaJit_LIBRARY=$luaLibrary" `
        "-DCMAKE_CXX_FLAGS=$cxxFlags" `
        "-DCMAKE_EXE_LINKER_FLAGS_RELWITHDEBINFO=$RelWithDebInfoExeLinkerFlags" `
        -DBUILD_OPENMW=ON `
        "-DBUILD_OPENMW_VR=$buildOpenMwVr" `
        -DBUILD_OPENMW_TESTS=ON `
        -DBUILD_COMPONENTS_TESTS=ON `
        -DBUILD_LAUNCHER=OFF `
        -DBUILD_WIZARD=OFF `
        -DBUILD_OPENCS=OFF `
        -DBUILD_OPENCS_TESTS=OFF
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed for $CandidateLabel" }
}

$targets = @(
    "openmw", "bsatool", "esmtool", "openmw-iniimporter",
    "openmw-essimporter", "niftest", "openmw-navmeshtool", "openmw-bulletobjecttool"
)
if (-not $SkipComponentTests) {
    $targets += "components-tests"
}
if ($EnableVr) {
    $targets += "openmw_vr"
}
if (-not $ResumeUnverifiedStaging) {
    cmake --build $candidateBuildRoot --config RelWithDebInfo --target $targets -- "/m:$BuildJobs"
    if ($LASTEXITCODE -ne 0) { throw "Candidate build failed for $CandidateLabel" }
}
else {
    # This path is intentionally metadata-only. It may finalize a runtime only
    # when its staged executable postdates every currently dirty source file.
    $stagedVrExe = Join-Path $candidateRuntimeRoot "openmw_vr.exe"
    $stagedTimestamp = (Get-Item -LiteralPath $stagedVrExe).LastWriteTimeUtc
    foreach ($changedPath in $status) {
        $relativePath = $changedPath.Substring(3)
        $sourcePath = Join-Path $SourceRoot $relativePath
        if ((Test-Path -LiteralPath $sourcePath) -and (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc -gt $stagedTimestamp) {
            throw "Refusing to finalize staging built before current source edit: $relativePath"
        }
    }
}

if (-not $ResumeUnverifiedStaging) {
    cmake --install $candidateBuildRoot --config RelWithDebInfo --prefix $candidateRuntimeRoot
    if ($LASTEXITCODE -ne 0) { throw "Candidate install failed for $CandidateLabel" }

    # CMake's install set omits these linked runtime assets. They are staged from
    # the exact vcpkg tree used at link time, never borrowed from another runtime.
    Copy-Item -LiteralPath $myGuiDll -Destination (Join-Path $candidateRuntimeRoot "MyGUIEngine.dll")
    if ($EnableVr) {
        if (-not (Test-Path -LiteralPath $openXrLoaderDll)) {
            throw "Missing OpenXR runtime dependency for VR candidate: $openXrLoaderDll"
        }
        Copy-Item -LiteralPath $openXrLoaderDll -Destination (Join-Path $candidateRuntimeRoot "openxr_loader.dll")
    }
    $runtimePluginRoot = Join-Path $candidateRuntimeRoot "osgPlugins-3.6.5"
    [void](New-Item -ItemType Directory -Path $runtimePluginRoot)
    Get-ChildItem -LiteralPath $osgPluginRoot -File | Copy-Item -Destination $runtimePluginRoot
}
else {
    $runtimePluginRoot = Join-Path $candidateRuntimeRoot "osgPlugins-3.6.5"
}

$resourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $candidateRuntimeRoot "resources") -Recurse -File)
$pluginFiles = @(Get-ChildItem -LiteralPath $runtimePluginRoot -File)
$openmwPath = Join-Path $candidateRuntimeRoot "openmw.exe"
$manifest = [ordered]@{
    schema = "nikami-fnv-playability-candidate-runtime/v1"
    createdUtc = [DateTime]::UtcNow.ToString("o")
    status = $candidateStatus
    candidate = [ordered]@{
        label = $CandidateLabel
        commit = $commit
        tree = $tree
        sourceRoot = "engine-repository"
        sourceClean = $sourceClean
        sourceDiffSha256 = $sourceDiffSha256
    }
    build = [ordered]@{
        root = ConvertTo-RepositoryRelativePath $candidateBuildRoot
        configuration = "RelWithDebInfo"
        generator = "Visual Studio 17 2022"
        architecture = "x64"
        toolchain = $toolchain
        cmakeVersion = (cmake --version | Select-Object -First 1)
        compatibilityDefinitions = $glCompatibilityDefinitions
        compatibilityScope = "compiler-only GL header compatibility; no source or gameplay behavior change"
        executableLinkerFlags = $RelWithDebInfoExeLinkerFlags
        vrEnabled = [bool]$EnableVr
        targets = $targets
    }
    runtime = [ordered]@{
        root = ConvertTo-RepositoryRelativePath $candidateRuntimeRoot
        openmwSha256 = (Get-FileHash -LiteralPath $openmwPath -Algorithm SHA256).Hash.ToLowerInvariant()
        openmwVrSha256 = if ($EnableVr) {
            (Get-FileHash -LiteralPath (Join-Path $candidateRuntimeRoot "openmw_vr.exe")).Hash.ToLowerInvariant()
        } else { $null }
        openXrLoaderSha256 = if ($EnableVr) {
            (Get-FileHash -LiteralPath (Join-Path $candidateRuntimeRoot "openxr_loader.dll")).Hash.ToLowerInvariant()
        } else { $null }
        resourceFileCount = $resourceFiles.Count
        resourceBytes = ($resourceFiles | Measure-Object Length -Sum).Sum
        osgPluginCount = $pluginFiles.Count
        osgPluginBytes = ($pluginFiles | Measure-Object Length -Sum).Sum
        supplementalDependencySources = @("MyGUIEngine.dll", "osgPlugins-3.6.5") + $(if ($EnableVr) { @("openxr_loader.dll") } else { @() })
    }
    verification = [ordered]@{
        componentTestsPassed = $false
        componentTestsSkippedForDiagnostic = [bool]$SkipComponentTests
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
