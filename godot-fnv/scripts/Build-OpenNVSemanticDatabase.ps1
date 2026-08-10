[CmdletBinding()]
param(
    [string]$DataRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data',
    [string]$NavmeshShardRoot = 'D:\OpenNVGodotData\navmesh\cells',
    [switch]$SkipResolvedIndex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $projectRoot '..')).Path
$bootstrap = Join-Path $projectRoot 'generated\bootstrap.json'
$resolvedDirectory = Join-Path $projectRoot 'generated\resolved-db'
$resolvedManifest = Join-Path $resolvedDirectory 'manifest.json'
$semanticDirectory = Join-Path $projectRoot 'generated\semantic-db'
$semanticAudit = Join-Path $semanticDirectory 'audit.json'
$actorBlueprints = Join-Path $semanticDirectory 'actor-blueprints.json'
$runtimeRing = Join-Path $projectRoot 'generated\world\goodsprings-strip-resolved-road-route.json'
$runtimeRingCells = Join-Path $projectRoot 'generated\world\goodsprings-strip-resolved-road-route-cells'
$navmeshRuntimeIndex = Join-Path $projectRoot 'generated\world\opennv-navmesh-runtime-index.json'

if (-not $SkipResolvedIndex) {
    & python (Join-Path $projectRoot 'tools\export_opennv_resolved_database.py') `
        --bootstrap $bootstrap --data-root $DataRoot --output-dir $resolvedDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Resolved record database compilation failed' }
}

& python (Join-Path $projectRoot 'tools\export_opennv_semantic_database.py') `
    --bootstrap $bootstrap --data-root $DataRoot --resolved-manifest $resolvedManifest `
    --output-dir $semanticDirectory
if ($LASTEXITCODE -ne 0) { throw 'Semantic database compilation failed' }

& python (Join-Path $projectRoot 'tools\audit_opennv_semantic_database.py') `
    --semantic-dir $semanticDirectory --resolved-manifest $resolvedManifest --output $semanticAudit
if ($LASTEXITCODE -ne 0) { throw 'Semantic database audit failed' }

& python (Join-Path $projectRoot 'tools\compile_opennv_actor_blueprints.py') `
    --semantic-dir $semanticDirectory --output $actorBlueprints
if ($LASTEXITCODE -ne 0) { throw 'Actor blueprint compilation failed' }

& python (Join-Path $projectRoot 'tools\build_opennv_resolved_runtime_ring.py') `
    --template (Join-Path $projectRoot 'generated\world\goodsprings-strip-road-route.json') `
    --semantic-db $semanticDirectory --output $runtimeRing --output-cells-dir $runtimeRingCells
if ($LASTEXITCODE -ne 0) { throw 'Resolved runtime ring compilation failed' }

& python (Join-Path $projectRoot 'tools\build_opennv_navmesh_runtime_index.py') `
    --semantic-db $semanticDirectory --output $navmeshRuntimeIndex --output-shards-dir $NavmeshShardRoot
if ($LASTEXITCODE -ne 0) { throw 'NAVM runtime index compilation failed' }

$manifest = Get-Content -LiteralPath (Join-Path $semanticDirectory 'manifest.json') -Raw | ConvertFrom-Json
$audit = Get-Content -LiteralPath $semanticAudit -Raw | ConvertFrom-Json
$actorManifest = Get-Content -LiteralPath (Join-Path $semanticDirectory 'actor-blueprints.manifest.json') -Raw | ConvertFrom-Json
$ringManifest = Get-Content -LiteralPath $runtimeRing -Raw | ConvertFrom-Json
$navmeshManifest = Get-Content -LiteralPath $navmeshRuntimeIndex -Raw | ConvertFrom-Json
[pscustomobject]@{
    schema = 'opennv-semantic-build/v1'
    status = 'pass'
    loadOrderSha256 = $manifest.load_order_sha256
    records = $manifest.counts.live_records
    cells = $manifest.counts.cells
    placements = $manifest.counts.placements
    actorBlueprints = $actorManifest.counts.blueprints
    actorPopulation = $actorManifest.counts.population_references
    doors = $audit.cross_links.linked_doors
    runtimeRingPlacements = $ringManifest.counts.placements
    runtimeRingActors = $ringManifest.counts.actors + $ringManifest.counts.creatures
    runtimeRingInteriors = $ringManifest.counts.interiorCells
    navmeshes = $navmeshManifest.counts.navmeshes
    navmeshTriangles = $navmeshManifest.counts.triangles
} | ConvertTo-Json
