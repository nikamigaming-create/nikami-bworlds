[CmdletBinding()]
param(
    [string]$DataRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data',
    [string]$NavmeshShardRoot = 'D:\OpenNVGodotData\navmesh\cells',
    [string]$FullRuntimeShardRoot = 'D:\OpenNVGodotData\world\opennv-full-runtime-cells',
    [string]$AudioArchiveRoot = 'D:\OpenNVGodotData\audio\archives',
    [string]$BsaTool = 'D:\code\nikami-worlds\local\openmw-godot-skeletal-export-v2-canonical-20260810\bsatool.exe',
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
$scriptVariableIndex = Join-Path $semanticDirectory 'script-variable-index.json'
$runtimeRing = Join-Path $projectRoot 'generated\world\goodsprings-strip-resolved-road-route.json'
$runtimeRingCells = Join-Path $projectRoot 'generated\world\goodsprings-strip-resolved-road-route-cells'
$navmeshRuntimeIndex = Join-Path $projectRoot 'generated\world\opennv-navmesh-runtime-index.json'
$navmeshRuntimeCandidate = "$navmeshRuntimeIndex.candidate"
$navmeshRuntimeAudit = Join-Path $projectRoot 'generated\world\opennv-navmesh-runtime-audit.json'
$fullRuntimeIndex = Join-Path $projectRoot 'generated\world\opennv-full-runtime-index.json'
$packageNavigationIndex = Join-Path $semanticDirectory 'package-navigation-index.json'
$soundAudit = Join-Path $semanticDirectory 'sound-asset-audit.json'
$audioRuntimeIndex = Join-Path $semanticDirectory 'audio-runtime-index.json'

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

& python (Join-Path $projectRoot 'tools\compile_opennv_script_variable_index.py') `
    --semantic-dir $semanticDirectory --output $scriptVariableIndex
if ($LASTEXITCODE -ne 0) { throw 'Script-variable structural index compilation failed' }

& python (Join-Path $projectRoot 'tools\build_opennv_resolved_runtime_ring.py') `
    --template (Join-Path $projectRoot 'generated\world\goodsprings-strip-road-route.json') `
    --semantic-db $semanticDirectory --output $runtimeRing --output-cells-dir $runtimeRingCells
if ($LASTEXITCODE -ne 0) { throw 'Resolved runtime ring compilation failed' }

& python (Join-Path $projectRoot 'tools\build_opennv_resolved_runtime_ring.py') `
    --template (Join-Path $projectRoot 'generated\world\goodsprings-strip-road-route.json') `
    --semantic-db $semanticDirectory --output $fullRuntimeIndex `
    --output-cells-dir $FullRuntimeShardRoot --all-cells
if ($LASTEXITCODE -ne 0) { throw 'Full OpenNV runtime index compilation failed' }

& python (Join-Path $projectRoot 'tools\build_opennv_package_navigation_index.py') `
    --runtime-index $fullRuntimeIndex `
    --packages (Join-Path $semanticDirectory 'actor-packages.json') `
    --blueprints $actorBlueprints `
    --output $packageNavigationIndex
if ($LASTEXITCODE -ne 0) { throw 'Full OpenNV package target/door navigation index compilation failed' }

& python (Join-Path $projectRoot 'tools\build_opennv_navmesh_runtime_index.py') `
    --semantic-db $semanticDirectory --output $navmeshRuntimeCandidate --output-shards-dir $NavmeshShardRoot
if ($LASTEXITCODE -ne 0) { throw 'NAVM runtime index compilation failed' }

& python (Join-Path $projectRoot 'tools\audit_opennv_navmesh_runtime.py') `
    --index $navmeshRuntimeCandidate `
    --semantic-manifest (Join-Path $semanticDirectory 'manifest.json') `
    --output $navmeshRuntimeAudit
if ($LASTEXITCODE -ne 0) { throw 'NAVM runtime topology audit failed' }
Move-Item -LiteralPath $navmeshRuntimeCandidate -Destination $navmeshRuntimeIndex -Force

if (-not (Test-Path -LiteralPath $BsaTool -PathType Leaf)) {
    throw "BSA tool required for authored sound census: $BsaTool"
}
& python (Join-Path $projectRoot 'tools\audit_opennv_sound_assets.py') `
    --semantic (Join-Path $semanticDirectory 'sounds.json') --data-root $DataRoot `
    --bsatool $BsaTool --output $soundAudit
$soundAuditDocument = Get-Content -LiteralPath $soundAudit -Raw | ConvertFrom-Json
if ([int]$soundAuditDocument.counts.consumerReferencesMissingRecord -ne 0 -or
    [int]$soundAuditDocument.counts.sounds -ne (
        [int]$soundAuditDocument.counts.soundsResolved + [int]$soundAuditDocument.counts.soundsMissing +
        [int]$soundAuditDocument.counts.soundsWithoutAuthoredPath)) {
    throw 'Authored sound census lost records or consumer references'
}
if (Test-Path -LiteralPath $AudioArchiveRoot -PathType Container) {
    & python (Join-Path $projectRoot 'tools\build_opennv_audio_runtime_index.py') `
        --audit $soundAudit --data-root $DataRoot --archive-root $AudioArchiveRoot --output $audioRuntimeIndex
    if ($LASTEXITCODE -ne 0) { throw 'Extracted OpenNV audio runtime index failed validation' }
}

$manifest = Get-Content -LiteralPath (Join-Path $semanticDirectory 'manifest.json') -Raw | ConvertFrom-Json
$audit = Get-Content -LiteralPath $semanticAudit -Raw | ConvertFrom-Json
$actorManifest = Get-Content -LiteralPath (Join-Path $semanticDirectory 'actor-blueprints.manifest.json') -Raw | ConvertFrom-Json
$ringManifest = Get-Content -LiteralPath $runtimeRing -Raw | ConvertFrom-Json
$navmeshManifest = Get-Content -LiteralPath $navmeshRuntimeIndex -Raw | ConvertFrom-Json
$packageNavigationManifest = Get-Content -LiteralPath $packageNavigationIndex -Raw | ConvertFrom-Json
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
    packageNavigationDoors = $packageNavigationManifest.counts.doors
    packageNavigationTargets = $packageNavigationManifest.counts.resolvedPackageReferenceTargets +
        $packageNavigationManifest.counts.runtimeResolvedPackageReferenceTargets
} | ConvertTo-Json
