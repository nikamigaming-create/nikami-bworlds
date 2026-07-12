param(
    [string]$OpenMWSource = "",
    [string]$LockPath = "catalog/openmw-base-lock.json",
    [string]$SeriesPath = "patches/openmw/series"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

$OpenMWSource = Resolve-NikamiPath `
    -ParameterValue $OpenMWSource `
    -EnvName "NIKAMI_OPENMW_SOURCE" `
    -ConfigName "openmwSource" `
    -Required `
    -Description "clean-base-capable OpenMW source checkout"
$OpenMWSource = [System.IO.Path]::GetFullPath($OpenMWSource)
$LockPath = Resolve-NikamiRepoRelativePath -Path $LockPath
$SeriesPath = Resolve-NikamiRepoRelativePath -Path $SeriesPath

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& git -C $Repository @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "git -C $Repository $($Arguments -join ' ') failed: $($lines -join [Environment]::NewLine)"
    }
    return ($lines -join [Environment]::NewLine).Trim()
}

function Assert-HexObjectId {
    param([string]$Value, [string]$Description)
    if ($Value -notmatch '^[0-9a-f]{40}$') {
        throw "$Description is not a full lowercase Git object ID: $Value"
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $OpenMWSource ".git"))) {
    throw "Not a Git checkout: $OpenMWSource"
}
if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
    throw "Missing OpenMW base lock: $LockPath"
}
if (-not (Test-Path -LiteralPath $SeriesPath -PathType Leaf)) {
    throw "Missing OpenMW patch series: $SeriesPath"
}

$lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
if ([string]$lock.schema -ne "nikami-openmw-base-lock/v1") {
    throw "Unexpected OpenMW base-lock schema: $($lock.schema)"
}

$queueBase = ([string]$lock.queueBase).ToLowerInvariant()
$queueBaseTree = ([string]$lock.queueBaseTree).ToLowerInvariant()
$checkpointCommit = ([string]$lock.compositeCheckpoint.commit).ToLowerInvariant()
$checkpointTree = ([string]$lock.compositeCheckpoint.tree).ToLowerInvariant()
$lockedReplayTree = ([string]$lock.replayVerification.replayedTree).ToLowerInvariant()
Assert-HexObjectId -Value $queueBase -Description "queueBase"
Assert-HexObjectId -Value $queueBaseTree -Description "queueBaseTree"
Assert-HexObjectId -Value $checkpointCommit -Description "composite checkpoint commit"
Assert-HexObjectId -Value $checkpointTree -Description "composite checkpoint tree"
Assert-HexObjectId -Value $lockedReplayTree -Description "locked replay tree"
if ($lockedReplayTree -ne $checkpointTree) {
    throw "Locked replay tree does not equal the composite checkpoint tree."
}
if ([string]$lock.replayVerification.base -ne $queueBase) {
    throw "replayVerification.base does not equal queueBase."
}

$seriesRoot = Split-Path -Parent $SeriesPath
$patches = @(Get-Content -LiteralPath $SeriesPath |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") })
if ($patches.Count -ne [int]$lock.replayVerification.patchCount) {
    throw "Patch count $($patches.Count) does not match the locked count $($lock.replayVerification.patchCount)."
}
if (@($patches | Select-Object -Unique).Count -ne $patches.Count) {
    throw "OpenMW patch series contains duplicate entries."
}
$patchPaths = foreach ($patch in $patches) {
    $path = [System.IO.Path]::GetFullPath((Join-Path $seriesRoot $patch))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing patch listed in the OpenMW series: $path"
    }
    $path
}

$actualBaseTree = Invoke-GitCapture -Repository $OpenMWSource -Arguments @("rev-parse", "$queueBase^{tree}")
if ($actualBaseTree -ne $queueBaseTree) {
    throw "queueBase tree mismatch: lock=$queueBaseTree checkout=$actualBaseTree"
}
$actualCheckpointTree = Invoke-GitCapture -Repository $OpenMWSource -Arguments @("rev-parse", "$checkpointCommit^{tree}")
if ($actualCheckpointTree -ne $checkpointTree) {
    throw "Composite checkpoint tree mismatch: lock=$checkpointTree checkout=$actualCheckpointTree"
}

$worktreeParent = [System.IO.Path]::GetFullPath((Join-Path $script:NikamiRepoRoot "run\worktrees"))
New-Item -ItemType Directory -Path $worktreeParent -Force | Out-Null
$worktreePath = [System.IO.Path]::GetFullPath((Join-Path $worktreeParent (
    "openmw-overlay-replay-" + [Guid]::NewGuid().ToString("N"))))
$allowedPrefix = $worktreeParent.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $worktreePath.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unsafe replay worktree path: $worktreePath"
}

$worktreeAdded = $false
$replayTree = $null
$cleanupFailure = $null
try {
    Invoke-GitCapture -Repository $OpenMWSource -Arguments @(
        "worktree", "add", "--detach", $worktreePath, $queueBase) | Out-Null
    $worktreeAdded = $true

    foreach ($patchPath in $patchPaths) {
        Invoke-GitCapture -Repository $worktreePath -Arguments @(
            "apply", "--whitespace=nowarn", $patchPath) | Out-Null
    }
    Invoke-GitCapture -Repository $worktreePath -Arguments @("add", "-A") | Out-Null
    $replayTree = Invoke-GitCapture -Repository $worktreePath -Arguments @("write-tree")
}
finally {
    if ($worktreeAdded) {
        try {
            Invoke-GitCapture -Repository $OpenMWSource -Arguments @(
                "worktree", "remove", "--force", $worktreePath) | Out-Null
        }
        catch {
            $cleanupFailure = $_
        }
    }
}

if ($null -ne $cleanupFailure) {
    throw "Replay completed but disposable-worktree cleanup failed: $($cleanupFailure.Exception.Message)"
}
if (Test-Path -LiteralPath $worktreePath) {
    throw "Git reported successful cleanup but the replay worktree still exists: $worktreePath"
}
if ($replayTree -ne $lockedReplayTree) {
    throw "OpenMW patch replay tree mismatch: lock=$lockedReplayTree replay=$replayTree"
}

[pscustomobject][ordered]@{
    schema = "nikami-openmw-overlay-replay/v1"
    status = "passed"
    source = $OpenMWSource
    base = $queueBase
    baseTree = $queueBaseTree
    patchCount = $patches.Count
    replayTree = $replayTree
    checkpointCommit = $checkpointCommit
    checkpointTree = $checkpointTree
    exactMatch = $true
} | ConvertTo-Json -Depth 3
