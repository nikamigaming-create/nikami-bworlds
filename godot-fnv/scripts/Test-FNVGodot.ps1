[CmdletBinding()]
param([string]$Godot = 'D:\code\gd\Godot_v4.6.3-stable_win64_console.exe')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $projectRoot 'generated\bootstrap.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Bootstrap manifest is missing' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.schema -ne 'nikami-open-nv-godot-bootstrap/v1') { throw "Unexpected manifest schema: $($manifest.schema)" }
if (-not (Test-Path -LiteralPath $manifest.save.path)) { throw "Source save is missing: $($manifest.save.path)" }
$hash = (Get-FileHash -LiteralPath $manifest.save.path -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $manifest.save.sha256) { throw 'Manifest/source save hash mismatch' }
if (@($manifest.load_order).Count -lt 1 -or $manifest.load_order[0] -ne 'FalloutNV.esm') { throw 'Invalid save load order' }
if (@($manifest.inventory).Count -lt 1) { throw 'Decoded save inventory is empty' }
$saveOverlayPath = Join-Path $projectRoot 'generated\save330-overlay\index.json'
$saveOverlayPayloadPath = Join-Path $projectRoot 'generated\save330-overlay\changeform-payloads.bin'
if (-not (Test-Path -LiteralPath $saveOverlayPath) -or -not (Test-Path -LiteralPath $saveOverlayPayloadPath)) {
    throw 'Save change-form overlay is missing'
}
$saveOverlay = Get-Content -LiteralPath $saveOverlayPath -Raw | ConvertFrom-Json
if ($saveOverlay.schema -ne 'opennv-fos-changeform-index/v1' -or $saveOverlay.source.sha256 -ne $hash) {
    throw 'Save change-form overlay provenance mismatch'
}
if ([int]$saveOverlay.counts.changeForms -ne [int]$saveOverlay.integrity.declaredChangeForms -or
    [int64]$saveOverlay.integrity.tableEnd -ne [int64]$saveOverlay.integrity.expectedTableEnd) {
    throw 'Save change-form overlay boundary census failed'
}
$overlayPayload = Get-Item -LiteralPath $saveOverlayPayloadPath
$overlayPayloadHash = (Get-FileHash -LiteralPath $saveOverlayPayloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($overlayPayload.Length -ne [int64]$saveOverlay.integrity.payloadArtifact.bytes -or
    $overlayPayloadHash -ne $saveOverlay.integrity.payloadArtifact.sha256) {
    throw 'Save change-form payload artifact mismatch'
}
$actorManifestPath = Join-Path $projectRoot 'generated\actors\actor-manifest-skeletal-v8.json'
if (-not (Test-Path -LiteralPath $actorManifestPath)) { throw 'Actor cache manifest is missing' }
$actorManifest = Get-Content -LiteralPath $actorManifestPath -Raw | ConvertFrom-Json
$expectedActorCacheRecords = @($actorManifest.actors).Count
$skeletalActorRecords = @($actorManifest.actors | Where-Object {
    $property = $_.PSObject.Properties['skeletal']
    $null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)
}).Count
$authoredAnimationRecords = @($actorManifest.actors | Where-Object {
    $property = $_.PSObject.Properties['animation_idle']
    $null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)
}).Count
if ($skeletalActorRecords -lt 1) { throw 'The skeletal actor cache is empty' }
$actorPayloadAuditPath = Join-Path $projectRoot 'generated\actors\actor-payload-audit.json'
& python (Join-Path $projectRoot 'tools\audit_opennv_actor_payloads.py') `
    --manifest $actorManifestPath --project-root $projectRoot --output $actorPayloadAuditPath
if ($LASTEXITCODE -ne 0) { throw 'Promoted actor payload integrity gate failed' }
$actorPayloadAudit = Get-Content -LiteralPath $actorPayloadAuditPath -Raw | ConvertFrom-Json
if ([string]$actorPayloadAudit.status -ne 'pass' -or [int]$actorPayloadAudit.counts.failures -ne 0 -or
    [int]$actorPayloadAudit.counts.skeletal_payloads -ne $skeletalActorRecords) {
    throw 'Promoted actor payload census mismatch'
}
$fullActorRosterPath = Join-Path $projectRoot 'generated\actors\full-runtime-enabled-actor-roster.json'
$fullActorResolutionPath = Join-Path $projectRoot 'generated\actors\full-runtime-actor-resolution.json'
& python (Join-Path $projectRoot 'tools\audit_opennv_full_actor_resolution.py') `
    --roster $fullActorRosterPath --manifest $actorManifestPath --output $fullActorResolutionPath
if ($LASTEXITCODE -ne 0) { throw 'Full-world actor visual resolution gate failed' }
$fullActorResolution = Get-Content -LiteralPath $fullActorResolutionPath -Raw | ConvertFrom-Json
if ([string]$fullActorResolution.status -ne 'pass' -or
    [int]$fullActorResolution.counts.missing_references -ne 0 -or
    [int]$fullActorResolution.counts.enabled_references -ne
        ([int]$fullActorResolution.counts.exact_references + [int]$fullActorResolution.counts.base_resolved_references)) {
    throw 'Full-world actor visual resolution census does not conserve its denominator'
}
$collisionAuditPath = Join-Path $projectRoot 'generated\assets\collision-metadata-audit.json'
& python (Join-Path $projectRoot 'tools\audit_fnv_collision_metadata.py') `
    --converted-root (Join-Path $projectRoot 'generated\assets\converted') --output $collisionAuditPath
if ($LASTEXITCODE -ne 0) { throw 'Authored/OpenMW collision metadata gate failed' }
$collisionAudit = Get-Content -LiteralPath $collisionAuditPath -Raw | ConvertFrom-Json
if ([string]$collisionAudit.status -ne 'pass' -or [int]$collisionAudit.counts.failures -ne 0 -or
    [int]$collisionAudit.counts.colliding_models -lt 1 -or [int]$collisionAudit.counts.noncolliding_models -lt 1) {
    throw 'Collision metadata census is incomplete'
}
$fullAssetInventoryPath = Join-Path $projectRoot 'generated\assets\full-cell-asset-inventory.json'
$fullAssetAuditPath = Join-Path $projectRoot 'generated\assets\full-cell-asset-coverage.json'
& python (Join-Path $projectRoot 'tools\audit_fnv_full_asset_coverage.py') `
    --inventory $fullAssetInventoryPath --project-root $projectRoot --output $fullAssetAuditPath
if ($LASTEXITCODE -ne 0) { throw 'Full-cell asset coverage gate failed' }
$fullAssetAudit = Get-Content -LiteralPath $fullAssetAuditPath -Raw | ConvertFrom-Json
if ([string]$fullAssetAudit.status -ne 'pass' -or [int]$fullAssetAudit.counts.unsupported -ne 0 -or
    [int]$fullAssetAudit.counts.models -ne ([int]$fullAssetAudit.counts.converted +
        [int]$fullAssetAudit.counts.authored_marker + [int]$fullAssetAudit.counts.procedural_effect +
        [int]$fullAssetAudit.counts.retail_missing)) {
    throw 'Full-cell asset coverage census does not conserve its denominator'
}
$placementTestOutput = & $Godot --headless --path $projectRoot --script 'res://tests/test_exterior_placement_residency.gd' 2>&1
if ($LASTEXITCODE -ne 0 -or ($placementTestOutput | Out-String) -notmatch 'OPENNV_EXTERIOR_PLACEMENT_RESIDENCY_PASS') {
    throw "Exterior placement residency gate failed:`n$($placementTestOutput | Out-String)"
}
$interiorResidencyOutput = & $Godot --headless --path $projectRoot --script 'res://tests/test_interior_residency_lru.gd' 2>&1
if ($LASTEXITCODE -ne 0 -or ($interiorResidencyOutput | Out-String) -notmatch 'OPENNV_INTERIOR_RESIDENCY_LRU_PASS') {
    throw "Interior residency LRU gate failed:`n$($interiorResidencyOutput | Out-String)"
}
$packageTestOutput = & $Godot --headless --path $projectRoot --script 'res://tests/test_authored_package_selection.gd' 2>&1
if ($LASTEXITCODE -ne 0 -or ($packageTestOutput | Out-String) -notmatch 'OPENNV_AUTHORED_PACKAGE_SELECTION_PASS') {
    throw "Authored package selection gate failed:`n$($packageTestOutput | Out-String)"
}

$conditionTestOutput = & $Godot --headless --path $projectRoot --script 'res://tests/test_opennv_condition_runtime.gd' 2>&1
if ($LASTEXITCODE -ne 0 -or ($conditionTestOutput | Out-String) -notmatch 'OPENNV_CONDITION_RUNTIME_PASS') {
    $conditionTestOutput | ForEach-Object { Write-Host $_ }
    throw 'OpenNV condition runtime test failed.'
}
$packageConditionAuditPath = Join-Path $projectRoot 'generated\semantic-db\package-condition-audit.json'
& python (Join-Path $projectRoot 'tools\audit_opennv_package_conditions.py') `
    --input (Join-Path $projectRoot 'generated\semantic-db\actor-packages.json') `
    --output $packageConditionAuditPath
if ($LASTEXITCODE -ne 0) { throw 'OpenNV package condition census failed.' }
$packageConditionAudit = Get-Content -LiteralPath $packageConditionAuditPath -Raw | ConvertFrom-Json
if ($packageConditionAudit.status -ne 'pass' -or [int]$packageConditionAudit.counts.unsupportedLayouts -ne 0) {
    throw 'OpenNV package condition layout coverage failed.'
}
$navmeshTestOutput = & $Godot --headless --path $projectRoot --script 'res://tests/test_authored_navmesh_runtime.gd' 2>&1
if ($LASTEXITCODE -ne 0 -or ($navmeshTestOutput | Out-String) -notmatch 'OPENNV_AUTHORED_NAVMESH_RUNTIME_PASS') {
    throw "Authored NAVM runtime lifecycle gate failed:`n$($navmeshTestOutput | Out-String)"
}
$animationTestOutput = & $Godot --headless --path $projectRoot --script 'res://tests/test_authored_actor_animation.gd' 2>&1
if ($LASTEXITCODE -ne 0 -or ($animationTestOutput | Out-String) -notmatch 'OPENNV_ANIMATION_TRANSPORT_EXPERIMENT_PASS') {
    throw "Authored actor animation pose gate failed:`n$($animationTestOutput | Out-String)"
}
$skeletalV2LoaderOutput = & $Godot --headless --path $projectRoot --script 'res://tests/test_skeletal_actor_v2_loader.gd' 2>&1
if ($LASTEXITCODE -ne 0 -or ($skeletalV2LoaderOutput | Out-String) -notmatch 'OPENNV_GODOT_SKELETAL_V2_PASS') {
    throw "Canonical skeletal-v2 loader gate failed:`n$($skeletalV2LoaderOutput | Out-String)"
}
$skeletalV2AnimationOutput = & $Godot --headless --path $projectRoot --script 'res://tests/test_skeletal_actor_v2_animation.gd' 2>&1
if ($LASTEXITCODE -ne 0 -or ($skeletalV2AnimationOutput | Out-String) -notmatch 'OPENNV_GODOT_SKELETAL_V2_ANIMATION_PASS') {
    throw "Canonical skeletal-v2 animation/attachment gate failed:`n$($skeletalV2AnimationOutput | Out-String)"
}
$coverageAuditPath = Join-Path $projectRoot 'generated\world\content-coverage-audit.json'
$coverageAudit = if (Test-Path -LiteralPath $coverageAuditPath) {
    Get-Content -LiteralPath $coverageAuditPath -Raw | ConvertFrom-Json
} else { $null }
$runtimeRingPath = Join-Path $projectRoot 'generated\world\goodsprings-strip-resolved-road-route.json'
$semanticManifestPath = Join-Path $projectRoot 'generated\semantic-db\manifest.json'
if (-not (Test-Path -LiteralPath $runtimeRingPath) -or -not (Test-Path -LiteralPath $semanticManifestPath)) {
    throw 'Resolved runtime ring or semantic manifest is missing'
}
$runtimeRing = Get-Content -LiteralPath $runtimeRingPath -Raw | ConvertFrom-Json
$semanticManifestHash = (Get-FileHash -LiteralPath $semanticManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$semanticDatabaseManifest = Get-Content -LiteralPath $semanticManifestPath -Raw | ConvertFrom-Json
$fullRuntimeIndexPath = Join-Path $projectRoot 'generated\world\opennv-full-runtime-index.json'
$fullRuntimeIndex = Get-Content -LiteralPath $fullRuntimeIndexPath -Raw | ConvertFrom-Json
if ($fullRuntimeIndex.schema -ne 'opennv-resolved-runtime-ring/v1' -or
    $fullRuntimeIndex.semantic_manifest_sha256 -ne $semanticManifestHash -or
    -not [bool]$fullRuntimeIndex.counts.allCells -or
    [int]$fullRuntimeIndex.counts.selectedCells -ne [int]$semanticDatabaseManifest.counts.cells -or
    [int]$fullRuntimeIndex.counts.exteriorWorldspaces -ne 32 -or
    [int]$fullRuntimeIndex.counts.missingCells -ne 0 -or
    [int]$fullRuntimeIndex.counts.missingDoorEndpoints -ne 0) {
    throw 'Full runtime index provenance, worldspace or graph census failed'
}
$navmeshRuntimeIndexPath = Join-Path $projectRoot 'generated\world\opennv-navmesh-runtime-index.json'
$navmeshRuntimeAuditPath = Join-Path $projectRoot 'generated\world\opennv-navmesh-runtime-audit.json'
& python (Join-Path $projectRoot 'tools\audit_opennv_navmesh_runtime.py') `
    --index $navmeshRuntimeIndexPath --semantic-manifest $semanticManifestPath --output $navmeshRuntimeAuditPath
if ($LASTEXITCODE -ne 0) { throw 'Full NAVM runtime topology gate failed' }
$navmeshRuntimeAudit = Get-Content -LiteralPath $navmeshRuntimeAuditPath -Raw | ConvertFrom-Json
if ([string]$navmeshRuntimeAudit.status -ne 'pass' -or
    [int]$navmeshRuntimeAudit.counts.navmeshes -ne [int]$semanticDatabaseManifest.counts.navmeshes -or
    [int]$navmeshRuntimeAudit.counts.invalid_triangle_indices -ne 0 -or
    [int]$navmeshRuntimeAudit.counts.failures -ne 0) {
    throw 'Full NAVM runtime census or triangle topology is invalid'
}
if ($runtimeRing.schema -ne 'opennv-resolved-runtime-ring/v1' -or
    $runtimeRing.semantic_manifest_sha256 -ne $semanticManifestHash -or
    [int]$runtimeRing.counts.missingCells -ne 0 -or [int]$runtimeRing.counts.missingDoorEndpoints -ne 0) {
    throw 'Resolved runtime ring provenance or graph census failed'
}
$actorCoverageTool = Join-Path $projectRoot 'tools\audit_opennv_actor_visual_coverage.py'
$actorCoveragePath = Join-Path $projectRoot 'generated\world\actor-visual-coverage-audit.json'
& python $actorCoverageTool `
    --ring $runtimeRingPath `
    --manifest $actorManifestPath `
    --project-root $projectRoot `
    --output $actorCoveragePath
if ($LASTEXITCODE -ne 0) { throw 'Selected-world exact actor visual coverage gate failed' }
$actorCoverage = Get-Content -LiteralPath $actorCoveragePath -Raw | ConvertFrom-Json
if ([string]$actorCoverage.status -ne 'pass' -or
    [int]$actorCoverage.counts.missing_enabled_refs -ne 0 -or
    [int]$actorCoverage.counts.duplicate_ring_refs -ne 0 -or
    [int]$actorCoverage.counts.exact_cached_refs -ne [int]$actorCoverage.counts.enabled_authored_refs) {
    throw 'Selected-world actor visual census is not exact'
}

$log = Join-Path $projectRoot 'generated\godot-smoke.log'
$priorSmoke = $env:FNV_GODOT_SMOKE
$priorSkip = $env:FNV_GODOT_SKIP_INTRO
$priorContinue = $env:FNV_GODOT_AUTOCONTINUE
$priorWorldSmoke = $env:FNV_GODOT_WORLD_SMOKE
$priorFastResidency = $env:FNV_GODOT_HEADLESS_FAST_RESIDENCY
try {
    $env:FNV_GODOT_SMOKE = '1'
    $env:FNV_GODOT_SKIP_INTRO = '1'
    $output = & $Godot --headless --path $projectRoot --log-file $log 2>&1
    $output | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "Godot smoke run failed with exit code $LASTEXITCODE" }
    if (($output | Out-String) -notmatch 'OPENNV_GODOT_SMOKE_PASS') { throw 'Godot smoke pass marker missing' }
    if (($output | Out-String) -notmatch 'OPENNV_SAVE_OVERLAY_READY') { throw 'Godot save overlay marker missing' }

    $env:FNV_GODOT_SMOKE = '0'
    $env:FNV_GODOT_AUTOCONTINUE = '1'
    $env:FNV_GODOT_WORLD_SMOKE = '1'
    $env:FNV_GODOT_HEADLESS_FAST_RESIDENCY = '1'
    $worldLog = Join-Path $projectRoot 'generated\godot-authored-world-smoke.log'
    # The headless dummy renderer reports RID diagnostics to stderr while it
    # constructs imported meshes; the authored residency marker is the test.
    $ErrorActionPreference = 'Continue'
    $worldOutput = & $Godot --headless --path $projectRoot --log-file $worldLog 2>&1
    $worldExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $worldOutput | Out-String | Write-Host
    if ($worldExitCode -ne 0) { throw "Godot authored-world smoke run failed with exit code $worldExitCode" }
    $worldText = $worldOutput | Out-String
    if ($worldText -notmatch 'OPENNV_GODOT_AUTHORED_WORLD_SMOKE_PASS cells=(\d+) terrain=(\d+) instances=(\d+)') {
        throw 'Godot authored-world residency marker missing'
    }
    $residentCells = [int]$Matches[1]
    $residentTerrainCells = [int]$Matches[2]
    $residentInstances = [int]$Matches[3]
    if ($worldText -notmatch 'OPENNV_RESOLVED_RUNTIME_RING_READY') {
        throw 'Godot resolved runtime ring marker missing'
    }
    if ($residentCells -lt 81 -or $residentTerrainCells -lt 81 -or $residentInstances -lt 3900) {
        throw "Authored-world no-pop resident envelope is incomplete: cells=$residentCells terrain=$residentTerrainCells instances=$residentInstances"
    }
    if ($worldText -notmatch 'OPENNV_ACTOR_RESIDENT count=(\d+)') {
        throw 'Godot authored actor residency marker missing'
    }
    $residentActors = [int]$Matches[1]
    if ($worldText -notmatch 'OPENNV_ACTOR_VISUAL_COVERAGE expected=(\d+) exact=(\d+) fallback=(\d+) missing=(\d+)') {
        throw 'Godot resident actor visual census marker missing'
    }
    $residentActorVisualExpected = [int]$Matches[1]
    $residentActorVisualExact = [int]$Matches[2]
    $residentActorVisualFallback = [int]$Matches[3]
    $residentActorVisualMissing = [int]$Matches[4]
    if ($residentActorVisualExpected -ne ($residentActorVisualExact + $residentActorVisualFallback + $residentActorVisualMissing)) {
        throw 'Resident actor visual census does not conserve expected references'
    }
    if ($residentActors -ne ($residentActorVisualExact + $residentActorVisualFallback)) {
        throw 'Resident actor count does not equal exact plus fallback visuals'
    }
    if ($worldText -notmatch 'OPENNV_ACTOR_CACHE records=(\d+)(?: skeletal=(\d+))? status=pass' -or [int]$Matches[1] -ne $expectedActorCacheRecords) {
        throw "Godot actor cache does not match its manifest: expected=$expectedActorCacheRecords"
    }
    if ($residentActors -lt 1) {
        throw 'Godot initial neighborhood did not instantiate any authored actors'
    }
}
finally {
    if ($null -eq $priorSmoke) { Remove-Item Env:FNV_GODOT_SMOKE -ErrorAction SilentlyContinue } else { $env:FNV_GODOT_SMOKE = $priorSmoke }
    if ($null -eq $priorSkip) { Remove-Item Env:FNV_GODOT_SKIP_INTRO -ErrorAction SilentlyContinue } else { $env:FNV_GODOT_SKIP_INTRO = $priorSkip }
    if ($null -eq $priorContinue) { Remove-Item Env:FNV_GODOT_AUTOCONTINUE -ErrorAction SilentlyContinue } else { $env:FNV_GODOT_AUTOCONTINUE = $priorContinue }
    if ($null -eq $priorWorldSmoke) { Remove-Item Env:FNV_GODOT_WORLD_SMOKE -ErrorAction SilentlyContinue } else { $env:FNV_GODOT_WORLD_SMOKE = $priorWorldSmoke }
    if ($null -eq $priorFastResidency) { Remove-Item Env:FNV_GODOT_HEADLESS_FAST_RESIDENCY -ErrorAction SilentlyContinue } else { $env:FNV_GODOT_HEADLESS_FAST_RESIDENCY = $priorFastResidency }
}

[pscustomobject]@{
    schema = 'nikami-open-nv-godot-smoke/v1'
    status = 'pass'
    saveSha256 = $hash
    saveNumber = $manifest.player.save_number
    location = $manifest.player.location
    masters = @($manifest.load_order).Count
    inventoryRows = @($manifest.inventory).Count
    residentCells = $residentCells
    residentTerrainCells = $residentTerrainCells
    residentInstances = $residentInstances
    residentActors = $residentActors
    residentActorVisuals = [ordered]@{
        expected = $residentActorVisualExpected
        exact = $residentActorVisualExact
        fallback = $residentActorVisualFallback
        missing = $residentActorVisualMissing
    }
    saveOverlay = [ordered]@{
        status = $saveOverlay.status
        changeForms = [int]$saveOverlay.counts.changeForms
        actors = [int]$saveOverlay.counts.byType.ACHR
        creatures = [int]$saveOverlay.counts.byType.ACRE
        references = [int]$saveOverlay.counts.byType.REFR
        moved = [int]$saveOverlay.counts.decodedInitialState.moved
        semanticPlacementMatches = [int]$saveOverlay.counts.semanticPlacementJoin.matched
        opaquePayloadBytes = [int64]$saveOverlay.counts.payloadBytes
    }
    resolvedRuntimeRing = [ordered]@{
        placements = [int]$runtimeRing.counts.placements
        actors = [int]$runtimeRing.counts.actors
        creatures = [int]$runtimeRing.counts.creatures
        doors = [int]$runtimeRing.counts.doors
        exteriorCells = [int]$runtimeRing.counts.exteriorCells
        interiors = [int]$runtimeRing.counts.interiorCells
        missingCells = [int]$runtimeRing.counts.missingCells
        missingDoorEndpoints = [int]$runtimeRing.counts.missingDoorEndpoints
    }
    fullRuntimeIndex = [ordered]@{
        placements = [int]$fullRuntimeIndex.counts.placements
        actors = [int]$fullRuntimeIndex.counts.actors
        creatures = [int]$fullRuntimeIndex.counts.creatures
        doors = [int]$fullRuntimeIndex.counts.doors
        exteriorCells = [int]$fullRuntimeIndex.counts.exteriorCells
        interiors = [int]$fullRuntimeIndex.counts.interiorCells
        worldspaces = [int]$fullRuntimeIndex.counts.exteriorWorldspaces
        missingCells = [int]$fullRuntimeIndex.counts.missingCells
        missingDoorEndpoints = [int]$fullRuntimeIndex.counts.missingDoorEndpoints
    }
    fullWorldActorVisualResolution = [ordered]@{
        status = [string]$fullActorResolution.status
        enabledReferences = [int]$fullActorResolution.counts.enabled_references
        exactReferences = [int]$fullActorResolution.counts.exact_references
        baseResolvedReferences = [int]$fullActorResolution.counts.base_resolved_references
        missingReferences = [int]$fullActorResolution.counts.missing_references
    }
    selectedWorldActorVisualCoverage = [ordered]@{
        status = [string]$actorCoverage.status
        enabledAuthoredRefs = [int]$actorCoverage.counts.enabled_authored_refs
        exactCachedRefs = [int]$actorCoverage.counts.exact_cached_refs
        missingEnabledRefs = [int]$actorCoverage.counts.missing_enabled_refs
        duplicateRingRefs = [int]$actorCoverage.counts.duplicate_ring_refs
    }
    smokeOnly = $true
    parityStatus = 'fail'
    remainingParityGaps = [ordered]@{
        fullPlacedPopulation = [int]$fullRuntimeIndex.counts.actors + [int]$fullRuntimeIndex.counts.creatures
        defaultEnabledVisuals = [int]$fullActorResolution.counts.enabled_references
        missingDefaultEnabledVisuals = [int]$fullActorResolution.counts.missing_references
        skeletalActors = $skeletalActorRecords
        authoredAnimationActors = $authoredAnimationRecords
        legacyStaticSnapshots = $expectedActorCacheRecords - $skeletalActorRecords
        missingInitialResidentVisuals = $residentActorVisualMissing
        note = 'Default-enabled visual resolution is complete. Animation clips, package AI and decoded save-state enable/equipment resolution remain incomplete.'
    }
} | ConvertTo-Json -Depth 4
