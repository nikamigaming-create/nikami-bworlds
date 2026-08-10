param(
    [Parameter(Mandatory = $true)] [string]$RosterPath,
    [Parameter(Mandatory = $true)] [string]$OutputRoot,
    [Parameter(Mandatory = $true)] [string]$PayloadRoot,
    [Parameter(Mandatory = $true)] [string]$BaseManifest,
    [Parameter(Mandatory = $true)] [string]$OutputManifest,
    [int]$ChunkSize = 128,
    [string]$BinaryRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

if ($ChunkSize -lt 1 -or $ChunkSize -gt 256) {
    throw 'ChunkSize must be between 1 and 256 so the OpenNV environment remains below Windows limits.'
}

$rosterFile = Resolve-RepoPath $RosterPath
$outputRootAbs = Resolve-RepoPath $OutputRoot
$payloadRootAbs = Resolve-RepoPath $PayloadRoot
$baseManifestAbs = Resolve-RepoPath $BaseManifest
$outputManifestAbs = Resolve-RepoPath $OutputManifest
$projectRoot = Join-Path $repoRoot 'godot-fnv'
$batchRunner = Join-Path $PSScriptRoot 'Invoke-OpenMWGoodspringsActorBatch.ps1'
$promoter = Join-Path $projectRoot 'tools/promote_opennv_skeletal_exports.py'

$roster = Get-Content -LiteralPath $rosterFile -Raw | ConvertFrom-Json
$targets = @($roster.targets)
if ([string]$roster.schema -ne 'nikami-fnv-actor-roster/v1' -or
    [int]$roster.targetCount -ne $targets.Count -or $targets.Count -lt 1) {
    throw "Invalid dynamic actor roster: $rosterFile"
}

New-Item -ItemType Directory -Path $outputRootAbs,$payloadRootAbs -Force | Out-Null
$chunkRoot = Join-Path $outputRootAbs 'rosters'
New-Item -ItemType Directory -Path $chunkRoot -Force | Out-Null
$currentManifest = $baseManifestAbs
$chunkCount = [int][Math]::Ceiling($targets.Count / [double]$ChunkSize)

for ($chunkIndex = 0; $chunkIndex -lt $chunkCount; ++$chunkIndex) {
    $first = $chunkIndex * $ChunkSize
    $count = [Math]::Min($ChunkSize, $targets.Count - $first)
    $chunkTargets = @($targets[$first..($first + $count - 1)])
    $chunkName = 'chunk-{0:d4}' -f $chunkIndex
    $chunkRosterPath = Join-Path $chunkRoot "$chunkName.json"
    $chunkRoster = [ordered]@{
        schema = 'nikami-fnv-actor-roster/v1'
        sourceRoster = $rosterFile
        chunkIndex = $chunkIndex
        chunkCount = $chunkCount
        firstTargetIndex = $first
        targetCount = $count
        targets = $chunkTargets
    }
    [IO.File]::WriteAllText(
        $chunkRosterPath,
        (($chunkRoster | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))

    $chunkOutput = Join-Path $outputRootAbs $chunkName
    $chunkPayload = Join-Path $payloadRootAbs $chunkName
    $reportPath = Join-Path $chunkOutput 'actor-mesh-export.json'
    $reportReady = $false
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $reportReady = [string]$report.status -eq 'pass' -and
            [int]$report.targetCount -eq $count -and
            [int]$report.nativeScreenshotCount -eq 0 -and
            [string]$report.rosterSha256 -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $chunkRosterPath).Hash.ToLowerInvariant()
    }
    if (-not $reportReady) {
        Write-Host "OPENNV_ROSTER_CHUNK_EXPORT index=$chunkIndex/$chunkCount targets=$count"
        & $batchRunner `
            -RosterPath $chunkRosterPath `
            -OutputRoot $chunkOutput `
            -SkeletalExportOnly `
            -MeshExportRoot $chunkPayload `
            -BinaryRoot $BinaryRoot `
            -FirstScreenshotFrame 60 `
            -FramesPerActor 10
    } else {
        Write-Host "OPENNV_ROSTER_CHUNK_REUSE index=$chunkIndex/$chunkCount targets=$count"
    }

    $nextManifest = "$outputManifestAbs.next"
    & python $promoter `
        --project-root $projectRoot `
        --roster $chunkRosterPath `
        --payload-root $chunkPayload `
        --base-manifest $currentManifest `
        --output $nextManifest `
        --export-report $reportPath
    if ($LASTEXITCODE -ne 0) { throw "Actor promotion failed for $chunkName" }
    Move-Item -LiteralPath $nextManifest -Destination $outputManifestAbs -Force
    $currentManifest = $outputManifestAbs
}

$final = Get-Content -LiteralPath $outputManifestAbs -Raw | ConvertFrom-Json
Write-Host "OPENNV_ROSTER_BATCHES_PASS chunks=$chunkCount promoted=$($targets.Count) actors=$($final.actor_count) skeletal=$($final.skeletal_actor_count)"
[pscustomobject]@{
    status = 'pass'
    chunks = $chunkCount
    promoted = $targets.Count
    manifest = $outputManifestAbs
    actorCount = $final.actor_count
    skeletalActorCount = $final.skeletal_actor_count
}
