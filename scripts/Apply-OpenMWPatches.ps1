param(
    [string]$OpenMWSource = "",
    [string]$SeriesPath = "patches/openmw/series",
    [switch]$Check,
    [switch]$Reverse,
    [switch]$AllowDirty
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
if (-not [System.IO.Path]::IsPathRooted($SeriesPath)) {
    $SeriesPath = Join-Path $script:NikamiRepoRoot $SeriesPath
}

if (-not (Test-Path -LiteralPath $SeriesPath)) {
    throw "Missing patch series: $SeriesPath"
}

$sourceStatus = @(& git -C $OpenMWSource status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect OpenMW checkout state: $OpenMWSource"
}
if ($sourceStatus.Count -gt 0 -and -not $AllowDirty) {
    throw "OpenMW checkout is not clean. Commit/stash downstream work or use a disposable worktree before applying the overlay. Pass -AllowDirty only for an intentional research checkout."
}
if ($Check -and $AllowDirty) {
    throw "-Check cannot validate uncommitted downstream changes cumulatively. Use a clean commit/worktree."
}

$seriesRoot = Split-Path -Parent (Resolve-Path -LiteralPath $SeriesPath).Path
$patches = Get-Content -LiteralPath $SeriesPath |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }

if (@($patches).Count -eq 0) {
    Write-Host "No OpenMW patches listed in $SeriesPath."
    exit 0
}

$patches = @($patches)
if ($Reverse) {
    [array]::Reverse($patches)
}

function Invoke-PatchQueue([string]$TargetSource) {
    foreach ($patch in $patches) {
        $patchPath = if ([System.IO.Path]::IsPathRooted($patch)) { $patch } else { Join-Path $seriesRoot $patch }
        if (-not (Test-Path -LiteralPath $patchPath)) {
            throw "Missing patch listed in series: $patchPath"
        }

        $argsList = @("apply", "--whitespace=nowarn")
        if ($Reverse) {
            $argsList += "--reverse"
        }
        $argsList += $patchPath

        Write-Host "git -C $TargetSource $($argsList -join ' ')"
        & git -C $TargetSource @argsList
        if ($LASTEXITCODE -ne 0) {
            throw "git apply failed for $patchPath"
        }
    }
}

if ($Check) {
    # Each patch is allowed to depend on earlier patches in the ordered series.
    # Validate by actually applying the queue in a disposable worktree; checking
    # every file independently against the original base produces false failures.
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $checkRoot = [System.IO.Path]::GetFullPath((Join-Path $tempBase ("nikami-openmw-overlay-check-" + [guid]::NewGuid().ToString("N"))))
    if (-not $checkRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing unsafe temporary worktree path: $checkRoot"
    }

    try {
        & git -C $OpenMWSource worktree add --detach $checkRoot HEAD
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to create cumulative patch-check worktree: $checkRoot"
        }
        Invoke-PatchQueue -TargetSource $checkRoot
        Write-Host "Cumulative patch check passed."
    }
    finally {
        & git -C $OpenMWSource worktree remove --force $checkRoot 2>$null
        if (Test-Path -LiteralPath $checkRoot) {
            Remove-Item -LiteralPath $checkRoot -Recurse -Force
        }
    }
}
else {
    Invoke-PatchQueue -TargetSource $OpenMWSource
    Write-Host "Patch queue applied."
}
