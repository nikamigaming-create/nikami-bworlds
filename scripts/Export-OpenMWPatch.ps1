param(
    [string]$OpenMWSource = "",
    [string]$PatchPath = "patches/openmw/world-viewer-local.patch",
    [switch]$Cached,
    [switch]$IncludeBinary
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

$patchDir = Split-Path -Parent $PatchPath
if (-not [string]::IsNullOrWhiteSpace($patchDir)) {
    New-Item -ItemType Directory -Force -Path $patchDir | Out-Null
}

$argsList = @("diff", "--src-prefix=a/", "--dst-prefix=b/")
if ($Cached) {
    $argsList += "--cached"
}
if ($IncludeBinary) {
    $argsList += "--binary"
}
$argsList += "--output=$PatchPath"

& git -C $OpenMWSource @argsList
if ($LASTEXITCODE -ne 0) {
    throw "git diff failed."
}

Write-Host "Wrote OpenMW patch: $PatchPath"
Write-Host "Note: untracked files in the external checkout are not included. Add them there first or split them into a separate patch."
