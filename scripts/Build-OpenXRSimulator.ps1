[CmdletBinding()]
param(
    [string]$VulkanSdk = $env:VULKAN_SDK,
    [switch]$SkipTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repoRoot 'tools\openxr-simulator'
$buildRoot = Join-Path $repoRoot 'local\build\openxr-simulator'
$installRoot = Join-Path $repoRoot 'local\openxr-simulator'
$requiredSource = @(
    (Join-Path $sourceRoot 'CMakeLists.txt'),
    (Join-Path $sourceRoot 'src\runtime.cpp'),
    (Join-Path $sourceRoot 'LICENSE'),
    (Join-Path $sourceRoot 'NIKAMI-VENDOR.md')
)
foreach ($path in $requiredSource) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing vendored OpenXR Simulator source file: $path"
    }
}

if ([string]::IsNullOrWhiteSpace($VulkanSdk)) {
    throw 'Set VULKAN_SDK or pass -VulkanSdk to a Vulkan SDK root containing Include\vulkan\vulkan.h.'
}
$vulkanHeader = Join-Path $VulkanSdk 'Include\vulkan\vulkan.h'
if (-not (Test-Path -LiteralPath $vulkanHeader -PathType Leaf)) {
    throw "Vulkan header not found: $vulkanHeader"
}

$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if ($null -eq $cmake) {
    throw 'cmake was not found on PATH.'
}

New-Item -ItemType Directory -Path $buildRoot, $installRoot -Force | Out-Null
$env:VULKAN_SDK = (Resolve-Path -LiteralPath $VulkanSdk).Path

& $cmake.Source -S $sourceRoot -B $buildRoot -A x64 -DBUILD_TESTING=ON
if ($LASTEXITCODE -ne 0) { throw "OpenXR Simulator configure failed ($LASTEXITCODE)." }
& $cmake.Source --build $buildRoot --config Release
if ($LASTEXITCODE -ne 0) { throw "OpenXR Simulator build failed ($LASTEXITCODE)." }

if (-not $SkipTests) {
    & ctest --test-dir $buildRoot -C Release --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw "OpenXR Simulator tests failed ($LASTEXITCODE)." }
}

$runtimeDll = Join-Path $sourceRoot 'bin\openxr_simulator.dll'
if (-not (Test-Path -LiteralPath $runtimeDll -PathType Leaf)) {
    throw "OpenXR Simulator build did not produce: $runtimeDll"
}
$runtimeDll = (Resolve-Path -LiteralPath $runtimeDll).Path
Copy-Item -LiteralPath $runtimeDll -Destination (Join-Path $installRoot 'openxr_simulator.dll') -Force
$manifest = [ordered]@{
    file_format_version = '1.0.0'
    runtime = [ordered]@{
        library_path = (Join-Path $installRoot 'openxr_simulator.dll')
        name = 'Nikami Worlds OpenXR Simulator v1.5.0'
    }
} | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText(
    (Join-Path $installRoot 'openxr_simulator.json'), $manifest + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    schema = 'nikami-openxr-simulator-build/v1'
    sourceRoot = $sourceRoot
    buildRoot = $buildRoot
    runtimeManifest = Join-Path $installRoot 'openxr_simulator.json'
    runtimeDllSha256 = (Get-FileHash -LiteralPath $runtimeDll -Algorithm SHA256).Hash
    testsRun = -not $SkipTests
    machineWideRuntimeChanged = $false
} | ConvertTo-Json -Depth 3
