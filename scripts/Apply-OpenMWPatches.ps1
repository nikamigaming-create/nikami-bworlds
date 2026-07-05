param(
    [string]$OpenMWSource = "",
    [string]$SeriesPath = "patches/openmw/series",
    [switch]$Check,
    [switch]$Reverse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

$OpenMWSource = Resolve-NikamiPath `
    -ParameterValue $OpenMWSource `
    -EnvName "NIKAMI_OPENMW_SOURCE" `
    -ConfigName "openmwSource" `
    -Required `
    -Description "external OpenMW source checkout"

if (-not (Test-Path -LiteralPath (Join-Path $OpenMWSource ".git"))) {
    throw "Not a git checkout: $OpenMWSource"
}
if (-not (Test-Path -LiteralPath $SeriesPath)) {
    throw "Missing patch series: $SeriesPath"
}

$seriesRoot = Split-Path -Parent (Resolve-Path -LiteralPath $SeriesPath).Path
$patches = Get-Content -LiteralPath $SeriesPath |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }

if (@($patches).Count -eq 0) {
    Write-Host "No OpenMW patches listed in $SeriesPath."
    exit 0
}

foreach ($patch in $patches) {
    $patchPath = if ([System.IO.Path]::IsPathRooted($patch)) { $patch } else { Join-Path $seriesRoot $patch }
    if (-not (Test-Path -LiteralPath $patchPath)) {
        throw "Missing patch listed in series: $patchPath"
    }

    $argsList = @("apply", "--whitespace=nowarn")
    if ($Check) {
        $argsList += "--check"
    }
    if ($Reverse) {
        $argsList += "--reverse"
    }
    $argsList += $patchPath

    Write-Host "git -C $OpenMWSource $($argsList -join ' ')"
    & git -C $OpenMWSource @argsList
    if ($LASTEXITCODE -ne 0) {
        throw "git apply failed for $patchPath"
    }
}

if ($Check) {
    Write-Host "Patch check passed."
} else {
    Write-Host "Patch queue applied."
}
