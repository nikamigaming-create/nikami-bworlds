extends Node3D

signal residency_ready(cell_count: int, terrain_count: int, instance_count: int)
signal portal_transitioned(source_cell: String, destination_cell: String)
signal route_corridor_ready

const RING_PATH := "res://generated/world/opennv-full-runtime-index.json"
const SEMANTIC_MANIFEST_PATH := "res://generated/semantic-db/manifest.json"
const NAVMESH_INDEX_PATH := "res://generated/world/opennv-navmesh-runtime-index.json"
const ACTOR_PACKAGES_PATH := "res://generated/semantic-db/actor-packages.json"
const ACTOR_MANIFEST_PATH := "res://generated/actors/actor-manifest-skeletal-v8.json"
const CONVERTED_ROOT := "res://generated/assets/converted/"
const FULL_DETAIL_RADIUS := 4
const DISTANT_TERRAIN_RADIUS := 32
const TERRAIN_VISUAL_RADIUS := 12
const DETAIL_KEEP_RADIUS := 8
const TERRAIN_KEEP_RADIUS := 14
const ACTOR_VISUAL_RADIUS := 2
const ACTOR_KEEP_RADIUS := 3
const INTERIOR_PREFETCH_DISTANCE := 40.0
const INTERIOR_PREFETCH_INTERVAL_MSEC := 250
const INTERIOR_KEEP_COUNT := 3
const DISTANT_CHUNK_CELLS := 8
const UNITS_PER_METER := 70.0
const TERRAIN_DIFFUSE := "res://generated/assets/converted/textures/landscape/dirtwasteland01.dds"
const TERRAIN_NORMAL := "res://generated/assets/converted/textures/landscape/dirtwasteland01_n.dds"
const TERRAIN_ALBEDO_ROOT := "res://generated/assets/converted/terrain-albedo/"
const MAX_CONCURRENT_MESH_LOADS := 12
const STREAM_COMMIT_BUDGET_USEC := 2000
const EXTERIOR_SCOPE := "__exterior__"
const ROUTE_PRELOAD_RADIUS := 6
const TERRAIN_COLLISION_RADIUS := 4
const HUMANOID_MOTION_SHADER := """
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec4 tint : source_color = vec4(1.0);
uniform float roughness_value = 1.0;
uniform float metallic_value = 0.0;
uniform float min_y = 0.0;
uniform float actor_height = 120.0;
uniform float center_x = 0.0;
uniform float half_width = 25.0;
uniform float phase = 0.0;
uniform float motion = 0.0;

void vertex() {
	float h = clamp((VERTEX.y - min_y) / max(actor_height, 0.001), 0.0, 1.0);
	float lateral = (VERTEX.x - center_x) / max(half_width, 0.001);
	float stride = sin(TIME * 6.0 + phase) * motion;
	float leg_region = (1.0 - smoothstep(0.46, 0.58, h)) * smoothstep(0.02, 0.18, h);
	float leg_side = smoothstep(0.08, 0.34, abs(lateral));
	VERTEX.z += stride * sign(lateral) * leg_region * leg_side * actor_height * 0.042;
	float arm_region = smoothstep(0.42, 0.55, h) * (1.0 - smoothstep(0.78, 0.88, h));
	float arm_side = smoothstep(0.42, 0.68, abs(lateral));
	VERTEX.z -= stride * sign(lateral) * arm_region * arm_side * actor_height * 0.052;
	VERTEX.y += abs(stride) * motion * (1.0 - smoothstep(0.82, 0.94, h)) * actor_height * 0.006;
}

void fragment() {
	vec4 texel = texture(albedo_texture, UV) * tint;
	if (texel.a < 0.42) discard;
	ALBEDO = texel.rgb;
	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
}
"""

var source_origin := Vector3.ZERO
var center_grid := Vector2i.ZERO
var primary_world_id := ""
var active_exterior_world_id := ""
var pending_paths: Array[String] = []
var active_paths: Array[String] = []
var waiting_placements: Dictionary = {}
var ready_placements: Dictionary = {}
var pending_skeletal_placements: Array[Dictionary] = []
var mesh_cache: Dictionary = {}
var mesh_ref_counts: Dictionary = {}
var collision_shape_cache: Dictionary = {}
var terrain_albedo_cache: Dictionary = {}
var resident_cells := 0
var resident_instances := 0
var resident_terrain_cells := 0
var distant_terrain_surfaces: Dictionary = {}
var threaded_loading := true
var door_nodes_by_form_id: Dictionary = {}
var actor_nodes_by_form_id: Dictionary = {}
var interior_names: Dictionary = {}
var interior_centers: Dictionary = {}
var visuals_by_scope: Dictionary = {}
var collision_bodies_by_scope: Dictionary = {}
var active_scope := EXTERIOR_SCOPE
var actor_cache_by_ref: Dictionary = {}
var actor_cache_by_base: Dictionary = {}
var validated_actor_payloads: Dictionary = {}
var actor_visual_status_by_cell: Dictionary = {}
var actor_packages_by_id: Dictionary = {}
var navmesh_index_by_cell: Dictionary = {}
var navigation_regions_by_cell: Dictionary = {}
var navigation_regions_by_scope: Dictionary = {}
var resident_navmesh_cells := 0
var resident_actors := 0
var cell_indices_by_grid: Dictionary = {}
var cell_indices_by_id: Dictionary = {}
var exterior_scope_by_cell: Dictionary = {}
var exterior_runtime_origins_by_cell: Dictionary = {}
var isolated_world_origins: Dictionary = {}
var loaded_detail_cells: Dictionary = {}
var loaded_actor_cells: Dictionary = {}
var loaded_terrain_cells: Dictionary = {}
var terrain_visual_by_cell: Dictionary = {}
var terrain_body_by_cell: Dictionary = {}
var terrain_collision_cells: Dictionary = {}
var stream_nodes_by_cell: Dictionary = {}
var actor_nodes_by_cell: Dictionary = {}
var interior_prefetch_doors: Dictionary = {}
var last_interior_prefetch_msec := 0
var last_focus_grid := Vector2i(2147483647, 2147483647)
var deferred_route_cells: Dictionary = {}
var deferred_terrain_cells: Dictionary = {}
var deferred_interiors: Dictionary = {}
var staged_interiors: Dictionary = {}
var interior_records_by_id: Dictionary = {}
var interior_lru: Array[String] = []
var interior_source_origins: Dictionary = {}
var interior_stage_origins: Dictionary = {}
var initial_residency_emitted := false
var max_stream_commit_usec := 0
var stream_commit_samples := 0
var special_effect_instances := 0
var authored_marker_instances := 0
var retail_missing_instances := 0
var unsupported_model_counts: Dictionary = {}
var runtime_condition_context: Dictionary = {}


func begin(save_manifest: Dictionary) -> void:
	visible = false
	runtime_condition_context = _build_condition_context(save_manifest)
	var source: Array = save_manifest.get("world", {}).get("source_position", [])
	if source.size() >= 3:
		source_origin = Vector3(float(source[0]), float(source[1]), float(source[2]))
	var ring_path := OS.get_environment("FNV_GODOT_RING_PATH")
	if ring_path.is_empty():
		ring_path = RING_PATH
	var ring := _read_json(ring_path)
	if ring.is_empty():
		push_warning("OPENNV_CELL_STREAMER ring manifest unavailable")
		residency_ready.emit(0, 0, 0)
		return
	if str(ring.get("schema", "")) != "opennv-resolved-runtime-ring/v1":
		push_error("OPENNV_CELL_STREAMER requires the resolved runtime ring")
		residency_ready.emit(0, 0, 0)
		return
	if str(ring.get("semantic_manifest_sha256", "")) != FileAccess.get_sha256(SEMANTIC_MANIFEST_PATH):
		push_error("OPENNV_CELL_STREAMER resolved ring is stale")
		residency_ready.emit(0, 0, 0)
		return
	var ring_counts := ring.get("counts", {}) as Dictionary
	if int(ring_counts.get("missingCells", -1)) != 0 or int(ring_counts.get("missingDoorEndpoints", -1)) != 0:
		push_error("OPENNV_CELL_STREAMER resolved ring failed its graph census")
		residency_ready.emit(0, 0, 0)
		return
	print("OPENNV_RESOLVED_RUNTIME_RING_READY cells=%d interiors=%d placements=%d actors=%d creatures=%d doors=%d" % [
		int(ring_counts.get("exteriorCells", 0)), int(ring_counts.get("interiorCells", 0)),
		int(ring_counts.get("placements", 0)), int(ring_counts.get("actors", 0)),
		int(ring_counts.get("creatures", 0)), int(ring_counts.get("doors", 0))])
	_load_actor_manifest()
	_load_actor_packages()
	_load_navmesh_index()
	var grid: Array = ring.get("center_grid", [0, 0])
	center_grid = Vector2i(int(grid[0]), int(grid[1]))
	primary_world_id = _canonical_form_id(ring.get("world_form_id", ""))
	active_exterior_world_id = primary_world_id
	# Register every interior up front, but do not build every casino, vault and
	# Strip room before Goodsprings can appear. Each interior keeps a stable
	# off-world stage transform and is queued when a nearby exterior door enters
	# the route prefetch radius.
	var interior_index := 0
	for interior_value in ring.get("interiors", []):
		var interior := interior_value as Dictionary
		var cell_id := _canonical_form_id(interior.get("form_id", ""))
		interior_names[cell_id] = str(interior.get("full_name", interior.get("editor_id", cell_id)))
		var cell_origin := _array_to_vector3(interior.get("source_origin", [0.0, 0.0, 0.0]))
		var cell_center := _array_to_vector3(interior.get("source_center", [0.0, 0.0, 0.0]))
		if not interior.has("shard"):
			var placements: Array = interior.get("placements", [])
			cell_origin = _interior_source_origin(placements)
			cell_center = _interior_source_center(placements)
		var stage_origin := Vector3(0.0, -500.0 - float(interior_index) * 350.0, 0.0)
		interior_source_origins[cell_id] = cell_origin
		interior_stage_origins[cell_id] = stage_origin
		interior_centers[cell_id] = stage_origin + _source_vector_to_godot(cell_center - cell_origin) / UNITS_PER_METER
		var interior_record := {
			"interior": interior,
			"origin": cell_origin,
			"stage": stage_origin,
		}
		deferred_interiors[cell_id] = interior_record
		interior_records_by_id[cell_id] = interior_record
		interior_index += 1
	var initial_interior_cells: Dictionary = {}
	var isolated_exterior_cells := 0
	for cell_value in ring.get("cells", []):
		var cell_index := cell_value as Dictionary
		var cell_grid_values: Array = cell_index.get("grid", [0, 0])
		var cell_grid := Vector2i(int(cell_grid_values[0]), int(cell_grid_values[1]))
		var indexed_cell_id := _canonical_form_id(cell_index.get("form_id", ""))
		cell_indices_by_id[indexed_cell_id] = cell_index
		var cell_world_id := _canonical_form_id(cell_index.get("world_form_id", ""))
		# Exterior grids are namespaced by worldspace. Fallout reuses the same
		# coordinates in Mojave, DLC, vault and simulation worldspaces; a bare
		# x,y index cross-loaded unrelated cells and made broad traversal unsafe.
		var runtime_scope := _world_scope(cell_world_id)
		exterior_scope_by_cell[indexed_cell_id] = runtime_scope
		var grid_key := _world_grid_key(cell_world_id, cell_grid)
		if not cell_indices_by_grid.has(grid_key):
			cell_indices_by_grid[grid_key] = []
		(cell_indices_by_grid[grid_key] as Array).append(cell_index)
		if cell_world_id == primary_world_id:
			deferred_route_cells[indexed_cell_id] = cell_index
		else:
			isolated_exterior_cells += 1
		var cell_distance := maxi(absi(cell_grid.x - center_grid.x), absi(cell_grid.y - center_grid.y))
		if OS.get_environment("FNV_GODOT_CINEMATIC_REEL") == "1":
			# The four-location pack deliberately spans unrelated world grids.
			# Treat each curated cell as local detail; frustum culling still keeps
			# only the active camera's town on the GPU.
			cell_distance = 0
	print("OPENNV_EXTERIOR_WORLD_INDEX primary=%s seamless=%d isolated=%d" % [
		primary_world_id, deferred_route_cells.size(), isolated_exterior_cells])
	# Materialize only the initial fixed-radius neighborhood. The former startup
	# loop decoded all 5,044 shards and built nearly the entire Mojave before the
	# first frame, making startup O(total world content).
	_stream_exterior_neighborhood(center_grid, initial_interior_cells, true, primary_world_id)
	_prefetch_nearby_interiors(Vector3.ZERO, true)
	_flush_ready_placements()
	if _headless_fast_residency():
		visible = true
		var fast_coverage := _resident_actor_visual_coverage()
		print("OPENNV_ACTOR_RESIDENT count=%d" % resident_actors)
		print("OPENNV_ACTOR_VISUAL_COVERAGE expected=%d exact=%d fallback=%d missing=%d" % [
			fast_coverage.expected, fast_coverage.exact, fast_coverage.fallback, fast_coverage.missing])
		print("OPENNV_CELL_RESIDENT cells=%d terrain=%d instances=%d meshes=0 radius=%d" % [
			resident_cells, resident_terrain_cells, resident_instances, FULL_DETAIL_RADIUS])
		initial_residency_emitted = true
		residency_ready.emit(resident_cells, resident_terrain_cells, resident_instances)
		return
	if pending_paths.is_empty() and pending_skeletal_placements.is_empty():
		push_warning("OPENNV_CELL_STREAMER no imported authored meshes were found")
		residency_ready.emit(resident_cells, resident_terrain_cells, 0)
		return
	# Dummy/headless and OpenXR rendering backends cannot safely accept imported
	# mesh RIDs created on ResourceLoader workers. Desktop Vulkan is the only
	# path where bounded background loads are enabled.
	threaded_loading = (not get_viewport().use_xr and DisplayServer.get_name() != "headless"
		and OS.get_environment("FNV_GODOT_FORCE_SYNC_LOAD") != "1")
	if threaded_loading:
		_pump_threaded_requests()
	set_process(true)


func _queue_placement(source_placement: Dictionary, cell_id: String, cell_origin: Vector3, stage_origin: Vector3, interior: bool, runtime_scope: String = "") -> void:
	# Save/quest enable-state overlay is not decoded yet. Honor the authored
	# default rather than spawning known-disabled duplicates such as the inactive
	# Goodsprings Victor reference.
	if source_placement.has("default_enabled") and not bool(source_placement.get("default_enabled", true)):
		return
	var placement := source_placement.duplicate(true)
	placement["_runtime_cell"] = cell_id
	placement["_runtime_origin"] = [cell_origin.x, cell_origin.y, cell_origin.z]
	placement["_runtime_stage"] = [stage_origin.x, stage_origin.y, stage_origin.z]
	placement["_runtime_interior"] = interior
	if not runtime_scope.is_empty():
		placement["_runtime_scope"] = runtime_scope
	if str(placement.get("base_type", "")) == "DOOR":
		var destination_cell := _canonical_form_id(placement.get("destination_cell", ""))
		if interior_names.has(destination_cell):
			interior_prefetch_doors[_canonical_form_id(placement.get("form_id", ""))] = placement
	if str(placement.get("base_type", "")) in ["NPC_", "CREA"]:
		_queue_actor_placement(placement)
		return
	var model := str(placement.get("model", "")).to_lower()
	var unsupported_effect := _is_procedural_effect_model(model)
	if str(placement.get("base_type", "")) == "DOOR" and unsupported_effect:
		_add_procedural_effect_gate(placement)
		return
	if _is_invisible_marker_model(model) or (str(placement.get("base_type", "")) == "FURN"
		and not ResourceLoader.exists(_converted_path(str(placement.get("model", ""))))):
		_add_authored_marker(placement)
		return
	# Particle/controller NIFs cannot be flattened to OBJ. Keep them explicit
	# and animated with a bounded Godot adapter instead of silently deleting
	# atmosphere or rendering white static cages.
	if unsupported_effect:
		_add_procedural_world_effect(placement, model)
		return
	if model == "architecture\\westside\\craftsmanwindowext.nif":
		return
	if _is_retail_missing_model(model):
		retail_missing_instances += 1
		return
	var path := _converted_path(str(placement.get("model", "")))
	if path.is_empty() or not ResourceLoader.exists(path):
		unsupported_model_counts[model] = int(unsupported_model_counts.get(model, 0)) + 1
		return
	if _headless_fast_residency():
		resident_instances += 1
		return
	# A streamed cell commonly reuses a mesh that was loaded for an earlier
	# cell. Install that placement from the resident mesh immediately. The old
	# code appended it to a stale waiting list without scheduling another load,
	# so repeated roads, rocks, houses and interior modules silently vanished.
	if mesh_cache.has(path):
		if not ready_placements.has(path):
			ready_placements[path] = []
		(ready_placements[path] as Array).append(placement)
		return
	if not waiting_placements.has(path):
		waiting_placements[path] = []
		pending_paths.append(path)
	waiting_placements[path].append(placement)


func _add_procedural_effect_gate(placement: Dictionary) -> void:
	if _headless_fast_residency():
		resident_instances += 1
		return
	var mesh := BoxMesh.new()
	# Dimensions are in source units because the authored placement transform
	# applies Bethesda's 70-units-per-meter scale.
	mesh.size = Vector3(300.0, 220.0, 12.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.05, 0.28, 0.31, 0.62)
	material.emission_enabled = true
	material.emission = Color(0.03, 0.22, 0.24)
	material.emission_energy_multiplier = 0.8
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.72
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = material
	_add_placement(mesh, placement)


func _is_procedural_effect_model(model: String) -> bool:
	return (model.begins_with("effects\\") or model.begins_with("fx\\") or "\\effects\\" in model
		or model.begins_with("lights\\") or "light" in model or "glow" in model
		or "\\sky\\" in model or "rain" in model or model.ends_with("skeleton.nif"))


func _is_invisible_marker_model(model: String) -> bool:
	var filename := model.get_file().to_lower()
	return ("marker" in filename or "shadow" in filename
		or "invisible" in filename or "nomesh" in filename)


func _is_retail_missing_model(model: String) -> bool:
	return model in [
		"architecture\\diner\\dinernosigntest.nif",
		"clutter\\heliosone\\nv_heliosone_solarreflectormetal_01.nif",
	]


func _add_authored_marker(placement: Dictionary) -> void:
	if _headless_fast_residency():
		resident_instances += 1
		authored_marker_instances += 1
		return
	var marker := Node3D.new()
	marker.name = "AuthoredMarker_%s" % str(placement.get("form_id", ""))
	marker.transform = _placement_transform(placement)
	marker.set_meta("fnv_form_id", placement.get("form_id", ""))
	marker.set_meta("fnv_base_form_id", placement.get("base_form_id", ""))
	marker.set_meta("fnv_base_type", placement.get("base_type", ""))
	marker.set_meta("fnv_furniture_marker", str(placement.get("base_type", "")) == "FURN")
	add_child(marker)
	_register_stream_node(placement.get("_runtime_cell", ""), marker, 1)
	resident_instances += 1
	authored_marker_instances += 1


func _add_procedural_world_effect(placement: Dictionary, model: String) -> void:
	if _headless_fast_residency():
		resident_instances += 1
		special_effect_instances += 1
		return
	var effect := GPUParticles3D.new()
	effect.name = "AuthoredEffect_%s" % str(placement.get("form_id", ""))
	effect.transform = _placement_transform(placement)
	effect.amount = 48
	effect.lifetime = 3.5
	effect.randomness = 0.65
	effect.visibility_aabb = AABB(Vector3(-8.0, -5.0, -8.0), Vector3(16.0, 12.0, 16.0))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(2.5, 0.4, 2.5)
	var color := Color(0.48, 0.43, 0.34, 0.32)
	var size := Vector2(0.22, 0.22)
	if "rain" in model or "water" in model:
		process.direction = Vector3.DOWN
		process.initial_velocity_min = 7.0
		process.initial_velocity_max = 11.0
		process.gravity = Vector3(0.0, -2.0, 0.0)
		process.emission_box_extents = Vector3(7.0, 0.5, 7.0)
		color = Color(0.44, 0.57, 0.65, 0.42)
		size = Vector2(0.025, 0.7)
	elif "fire" in model or "spark" in model or "electric" in model or "klaxon" in model:
		process.direction = Vector3.UP
		process.initial_velocity_min = 0.8
		process.initial_velocity_max = 2.4
		process.gravity = Vector3(0.0, 0.8, 0.0)
		color = Color(1.0, 0.34, 0.05, 0.72)
		size = Vector2(0.18, 0.32)
	else:
		process.direction = Vector3.UP
		process.initial_velocity_min = 0.15
		process.initial_velocity_max = 0.75
		process.gravity = Vector3(0.0, 0.12, 0.0)
		if "toxic" in model or "radiation" in model or "swamp" in model:
			color = Color(0.42, 0.62, 0.20, 0.34)
	process.color = color
	var quad := QuadMesh.new()
	quad.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.vertex_color_use_as_albedo = true
	quad.material = material
	effect.process_material = process
	effect.draw_pass_1 = quad
	add_child(effect)
	var scope := _placement_scope(placement)
	_register_visual(scope, effect)
	_register_stream_node(placement.get("_runtime_cell", ""), effect, 1)
	resident_instances += 1
	special_effect_instances += 1


func _load_actor_manifest() -> void:
	actor_cache_by_ref.clear()
	actor_cache_by_base.clear()
	validated_actor_payloads.clear()
	var manifest := _read_json(ACTOR_MANIFEST_PATH)
	if str(manifest.get("status", "")) != "pass" or str(manifest.get("schema", "")) not in ["opennv-godot-actor-cache/v1", "opennv-godot-actor-cache/v2"]:
		push_error("OPENNV_ACTOR_CACHE manifest failed validation")
		return
	var skeletal_records := 0
	for actor_value in manifest.get("actors", []):
		var actor := actor_value as Dictionary
		var skeletal_path := str(actor.get("skeletal", ""))
		if not skeletal_path.is_empty():
			var expected_skeletal_hash := str(actor.get("skeletal_sha256", "")).to_lower()
			if expected_skeletal_hash.is_empty():
				push_error("OPENNV_ACTOR_CACHE skeletal payload hash missing: %s" % skeletal_path)
				continue
			skeletal_records += 1
		actor_cache_by_ref[_canonical_form_id(actor.get("authored_ref", ""))] = actor
		var base_id := _canonical_form_id(actor.get("base_form", ""))
		if not base_id.is_empty() and not actor_cache_by_base.has(base_id):
			actor_cache_by_base[base_id] = actor
	print("OPENNV_ACTOR_CACHE records=%d skeletal=%d status=%s" % [actor_cache_by_ref.size(), skeletal_records, str(manifest.get("status", "missing"))])


func _actor_payload_is_valid(actor_record: Dictionary) -> bool:
	var path := str(actor_record.get("skeletal", ""))
	if path.is_empty():
		return false
	if validated_actor_payloads.has(path):
		return bool(validated_actor_payloads[path])
	var expected := str(actor_record.get("skeletal_sha256", "")).to_lower()
	var valid := (not expected.is_empty() and FileAccess.file_exists(path)
		and FileAccess.get_sha256(path).to_lower() == expected)
	validated_actor_payloads[path] = valid
	if not valid:
		push_warning("OPENNV_ACTOR_PAYLOAD_INVALID path=%s" % path)
	return valid


func _load_actor_packages() -> void:
	actor_packages_by_id.clear()
	if not FileAccess.file_exists(ACTOR_PACKAGES_PATH):
		return
	var document := _read_json(ACTOR_PACKAGES_PATH)
	if str(document.get("schema", "")) != "opennv-semantic-actor-packages/v1":
		push_error("OPENNV_ACTOR_PACKAGES schema mismatch")
		return
	for package_value in document.get("packages", []):
		var package := package_value as Dictionary
		var package_id := _canonical_form_id(package.get("id", ""))
		if not package_id.is_empty():
			actor_packages_by_id[package_id] = package
	print("OPENNV_ACTOR_PACKAGES_READY count=%d" % actor_packages_by_id.size())


func _load_navmesh_index() -> void:
	navmesh_index_by_cell.clear()
	var document := _read_json(NAVMESH_INDEX_PATH)
	if str(document.get("schema", "")) != "opennv-navmesh-runtime-index/v1":
		push_error("OPENNV_NAVMESH_INDEX schema mismatch")
		return
	if str(document.get("semantic_manifest_sha256", "")) != FileAccess.get_sha256(SEMANTIC_MANIFEST_PATH):
		push_error("OPENNV_NAVMESH_INDEX is stale")
		return
	for cell_id_value in (document.get("cells", {}) as Dictionary).keys():
		var cell_id := _canonical_form_id(cell_id_value)
		navmesh_index_by_cell[cell_id] = (document.get("cells", {}) as Dictionary)[cell_id_value]
	var counts := document.get("counts", {}) as Dictionary
	if navmesh_index_by_cell.size() != int(counts.get("cells", -1)) or int(counts.get("navmeshes", 0)) != 6129:
		push_error("OPENNV_NAVMESH_INDEX census mismatch")
		navmesh_index_by_cell.clear()
		return
	print("OPENNV_NAVMESH_INDEX_READY cells=%d navmeshes=%d triangles=%d" % [
		navmesh_index_by_cell.size(), int(counts.get("navmeshes", 0)), int(counts.get("triangles", 0))])


func _load_navmesh_cell(cell_id_value: String, source_cell_origin: Vector3, stage_origin: Vector3, scope: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	if navigation_regions_by_cell.has(cell_id) or not navmesh_index_by_cell.has(cell_id):
		return
	# The headless fast-residency test validates the complete index census but
	# deliberately avoids allocating Rendering/Navigation server RIDs.
	if _headless_fast_residency():
		return
	var index := navmesh_index_by_cell[cell_id] as Dictionary
	var shard_path := str(index.get("shard", ""))
	if shard_path.is_empty() or not FileAccess.file_exists(shard_path):
		push_warning("OPENNV_NAVMESH_SHARD_MISSING cell=%s path=%s" % [cell_id, shard_path])
		return
	var expected_hash := str(index.get("sha256", "")).to_lower()
	if expected_hash.is_empty() or FileAccess.get_sha256(shard_path).to_lower() != expected_hash:
		push_warning("OPENNV_NAVMESH_SHARD_INVALID cell=%s" % cell_id)
		return
	var payload := _read_json(shard_path)
	if str(payload.get("schema", "")) != "opennv-navmesh-cell-shard/v1" or _canonical_form_id(payload.get("cell", "")) != cell_id:
		push_warning("OPENNV_NAVMESH_SHARD_SCHEMA cell=%s" % cell_id)
		return
	var vertices := PackedVector3Array()
	var polygons: Array[PackedInt32Array] = []
	for navmesh_value in payload.get("navmeshes", []):
		var navmesh := navmesh_value as Dictionary
		var vertex_base := vertices.size()
		for vertex_value in navmesh.get("vertices", []):
			var source_vertex := _array_to_vector3(vertex_value)
			vertices.append(stage_origin + _source_vector_to_godot(source_vertex - source_cell_origin) / UNITS_PER_METER)
		for triangle_value in navmesh.get("triangles", []):
			var triangle := triangle_value as Array
			if triangle.size() != 3:
				continue
			polygons.append(PackedInt32Array([
				vertex_base + int(triangle[0]), vertex_base + int(triangle[1]), vertex_base + int(triangle[2])]))
	if vertices.is_empty() or polygons.is_empty():
		return
	var navigation_mesh := NavigationMesh.new()
	navigation_mesh.set_vertices(vertices)
	for polygon in polygons:
		navigation_mesh.add_polygon(polygon)
	var region := NavigationRegion3D.new()
	region.name = "NAVM_%s" % cell_id
	region.navigation_mesh = navigation_mesh
	region.enabled = scope == active_scope
	region.use_edge_connections = true
	region.set_meta("opennv_navmesh_cell", cell_id)
	region.set_meta("opennv_navmesh_count", int(index.get("navmeshes", 0)))
	add_child(region)
	navigation_regions_by_cell[cell_id] = region
	if not navigation_regions_by_scope.has(scope):
		navigation_regions_by_scope[scope] = []
	(navigation_regions_by_scope[scope] as Array).append(region)
	resident_navmesh_cells += 1


func _retire_navmesh_cell(cell_id_value: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	if not navigation_regions_by_cell.has(cell_id):
		return
	var region := navigation_regions_by_cell[cell_id] as NavigationRegion3D
	for scope_value in navigation_regions_by_scope.keys():
		(navigation_regions_by_scope[scope_value] as Array).erase(region)
	if is_instance_valid(region):
		region.queue_free()
	navigation_regions_by_cell.erase(cell_id)
	resident_navmesh_cells = maxi(0, resident_navmesh_cells - 1)


func _actor_package_semantics(placement: Dictionary, category: String) -> Dictionary:
	var packages: Array = []
	for package_id_value in placement.get("packages", []):
		var package_id := _canonical_form_id(package_id_value)
		if actor_packages_by_id.has(package_id):
			packages.append(actor_packages_by_id[package_id])
	var hour_text := OS.get_environment("FNV_GODOT_GAME_HOUR")
	var saved_hour := float(runtime_condition_context.get("game_hour", 9.0))
	var game_hour := clampf(float(hour_text) if hour_text.is_valid_float() else saved_hour, 0.0, 23.999)
	var result := runtime_condition_context.duplicate(true)
	result["packages"] = packages
	result["game_hour"] = game_hour
	result["actor_ref"] = _canonical_form_id(placement.get("form_id", ""))
	result["actor_base"] = _canonical_form_id(placement.get("base_form", placement.get("base", "")))
	result["actor_cell"] = _canonical_form_id(placement.get("_runtime_cell", ""))
	result["actor_interior"] = bool(placement.get("_runtime_interior", false))
	result["actor_is_creature"] = "creature" in category
	var cell_index := exterior_cells_by_id.get(result["actor_cell"], {}) as Dictionary
	result["actor_world"] = "" if bool(result["actor_interior"]) else _canonical_form_id(cell_index.get("world_form_id", primary_world_id))
	result["random_percent"] = float(abs(str(result["actor_ref"]).hash()) % 100)
	return result


func _build_condition_context(save_manifest: Dictionary) -> Dictionary:
	var globals: Dictionary = {}
	for global_value in save_manifest.get("globals", []):
		var global := global_value as Dictionary
		var form_id := _canonical_form_id(global.get("formId", ""))
		var wrapped := global.get("value", 0.0)
		globals[form_id] = float((wrapped as Dictionary).get("value", 0.0)) if wrapped is Dictionary else float(wrapped)
	var scene := save_manifest.get("scene", {}) as Dictionary
	var player := save_manifest.get("player", {}) as Dictionary
	return {
		"globals": globals,
		"game_hour": float(scene.get("game_hour", 9.0)),
		"actor_level": float(player.get("level", 1.0)),
		"quest_running": {},
		"quest_stages": {},
		"quest_stage_done": {},
		"quest_variables": {},
		"quest_completed": {},
		"objective_completed": {},
		"objective_displayed": {},
		"dead_counts": {},
	}


func runtime_stats() -> Dictionary:
	var actor_coverage := _resident_actor_visual_coverage()
	return {
		"actor_cache_records": actor_cache_by_ref.size(),
		"resident_actors": resident_actors,
		"resident_cells": resident_cells,
		"resident_instances": resident_instances,
		"resident_terrain_cells": resident_terrain_cells,
		"resident_navmesh_cells": resident_navmesh_cells,
		"deferred_route_cells": deferred_route_cells.size(),
		"deferred_terrain_cells": deferred_terrain_cells.size(),
		"deferred_interiors": deferred_interiors.size(),
		"pending_meshes": pending_paths.size() + active_paths.size(),
		"pending_skeletal_actors": pending_skeletal_placements.size(),
		"cached_meshes": mesh_cache.size(),
		"referenced_meshes": mesh_ref_counts.size(),
		"max_stream_commit_usec": max_stream_commit_usec,
		"stream_commit_samples": stream_commit_samples,
		"actor_visual_expected": actor_coverage.expected,
		"actor_visual_exact": actor_coverage.exact,
		"actor_visual_fallback": actor_coverage.fallback,
		"actor_visual_missing": actor_coverage.missing,
	}


func _collect_destination_interior(placement: Dictionary, result: Dictionary) -> void:
	if str(placement.get("base_type", "")) != "DOOR":
		return
	var destination_cell := _canonical_form_id(placement.get("destination_cell", ""))
	# Door-distance prefetch owns staging. Merely loading an exterior CELL must
	# not pull every linked interior into memory.
	return


func _stage_interior(cell_id_value: String, prefetch_depth: int = 0) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	if staged_interiors.has(cell_id):
		_touch_interior_lru(cell_id)
		return
	if not deferred_interiors.has(cell_id):
		return
	var record := deferred_interiors[cell_id] as Dictionary
	deferred_interiors.erase(cell_id)
	staged_interiors[cell_id] = true
	_touch_interior_lru(cell_id)
	resident_cells += 1
	var interior := _materialize_shard(record.get("interior", {}) as Dictionary)
	var cell_origin := record.get("origin", Vector3.ZERO) as Vector3
	var stage_origin := record.get("stage", Vector3.ZERO) as Vector3
	_load_navmesh_cell(cell_id, cell_origin, stage_origin, cell_id)
	var linked_interiors: Dictionary = {}
	for placement_value in interior.get("placements", []):
		var placement := placement_value as Dictionary
		_queue_placement(placement, cell_id, cell_origin, stage_origin, true)
		_collect_destination_interior(placement, linked_interiors)
	# Keep only the destination and one directly linked room warm. The previous
	# unbounded recursion loaded the transitive closure of casino/vault door
	# graphs and never released it.
	if prefetch_depth < 1:
		for linked_cell_value in linked_interiors:
			_stage_interior(str(linked_cell_value), prefetch_depth + 1)
	_trim_interior_residency()
	print("OPENNV_INTERIOR_PREFETCH cell=%s remaining=%d" % [cell_id, deferred_interiors.size()])


func _touch_interior_lru(cell_id_value: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	interior_lru.erase(cell_id)
	interior_lru.append(cell_id)


func _trim_interior_residency() -> void:
	while interior_lru.size() > INTERIOR_KEEP_COUNT:
		var retired := false
		for cell_id_value in interior_lru.duplicate():
			var cell_id := str(cell_id_value)
			if cell_id == active_scope:
				continue
			_retire_interior(cell_id)
			retired = true
			break
		if not retired:
			break


func _retire_interior(cell_id_value: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	if not staged_interiors.has(cell_id) or cell_id == active_scope:
		return
	_drop_pending_cell_placements(cell_id)
	_retire_navmesh_cell(cell_id)
	for node_value in stream_nodes_by_cell.get(cell_id, []):
		var node := node_value as Node
		if not is_instance_valid(node):
			continue
		resident_instances = maxi(0, resident_instances - int(node.get_meta("opennv_stream_instance_count", 0)))
		if node.has_meta("fnv_actor_id"):
			resident_actors = maxi(0, resident_actors - 1)
		_release_stream_mesh_ref(node)
		if node.has_meta("fnv_form_id"):
			var form_id := str(node.get_meta("fnv_form_id", "")).to_lower()
			door_nodes_by_form_id.erase(form_id)
			actor_nodes_by_form_id.erase(form_id)
		node.queue_free()
	stream_nodes_by_cell.erase(cell_id)
	actor_visual_status_by_cell.erase(cell_id)
	visuals_by_scope.erase(cell_id)
	collision_bodies_by_scope.erase(cell_id)
	for door_id_value in interior_prefetch_doors.keys():
		var door_record := interior_prefetch_doors[door_id_value] as Dictionary
		if _canonical_form_id(door_record.get("_runtime_cell", "")) == cell_id:
			interior_prefetch_doors.erase(door_id_value)
	staged_interiors.erase(cell_id)
	interior_lru.erase(cell_id)
	if interior_records_by_id.has(cell_id):
		deferred_interiors[cell_id] = interior_records_by_id[cell_id]
	resident_cells = maxi(0, resident_cells - 1)
	print("OPENNV_INTERIOR_RETIRED cell=%s staged=%d" % [cell_id, staged_interiors.size()])


func _drop_pending_cell_placements(cell_id: String) -> void:
	for index in range(pending_skeletal_placements.size() - 1, -1, -1):
		var placement := pending_skeletal_placements[index] as Dictionary
		if _canonical_form_id(placement.get("_runtime_cell", "")) == cell_id:
			pending_skeletal_placements.remove_at(index)
	for table in [waiting_placements, ready_placements]:
		for path_value in table.keys():
			var path := str(path_value)
			var placements := table[path] as Array
			for index in range(placements.size() - 1, -1, -1):
				var placement := placements[index] as Dictionary
				if _canonical_form_id(placement.get("_runtime_cell", "")) == cell_id:
					placements.remove_at(index)
			if placements.is_empty():
				table.erase(path)
				if not active_paths.has(path):
					pending_paths.erase(path)


func _queue_actor_placement(placement: Dictionary) -> void:
	var cell_id := _canonical_form_id(placement.get("_runtime_cell", ""))
	var ref_id := _canonical_form_id(placement.get("form_id", ""))
	if not actor_visual_status_by_cell.has(cell_id):
		actor_visual_status_by_cell[cell_id] = {}
	var cell_status := actor_visual_status_by_cell[cell_id] as Dictionary
	var actor_value: Variant = actor_cache_by_ref.get(ref_id)
	var visual_status := "exact"
	# Reuse a post-skin snapshot when several authored references instantiate
	# the same NPC_/CREA base. This immediately covers generic settlers and
	# creature packs without duplicating identical mesh exports per reference.
	if not actor_value is Dictionary:
		actor_value = actor_cache_by_base.get(_canonical_form_id(placement.get("base_form_id", "")))
		visual_status = "fallback"
	if not actor_value is Dictionary:
		cell_status[ref_id] = "missing"
		return
	cell_status[ref_id] = visual_status
	var actor_record := (actor_value as Dictionary).duplicate(true)
	if visual_status == "fallback":
		actor_record["visual_source_id"] = actor_record.get("id", "")
		actor_record["id"] = ref_id
	var path := str(actor_record.get("mesh", ""))
	var skeletal_path := str(actor_record.get("skeletal", ""))
	var skeletal_ready := (not skeletal_path.is_empty() and FileAccess.file_exists(skeletal_path)) if _headless_fast_residency() else _actor_payload_is_valid(actor_record)
	if skeletal_ready:
		if _headless_fast_residency():
			resident_instances += 1
			resident_actors += 1
			return
		placement["_runtime_actor"] = actor_record
		placement["_runtime_skeletal"] = skeletal_path
		pending_skeletal_placements.append(placement)
		set_process(true)
		return
	if path.is_empty() or not ResourceLoader.exists(path):
		push_warning("OPENNV_ACTOR_MESH_MISSING ref=%s path=%s" % [placement.get("form_id", ""), path])
		return
	if _headless_fast_residency():
		resident_instances += 1
		resident_actors += 1
		return
	placement["_runtime_actor"] = actor_record
	if mesh_cache.has(path):
		if not ready_placements.has(path):
			ready_placements[path] = []
		(ready_placements[path] as Array).append(placement)
		return
	if not waiting_placements.has(path):
		waiting_placements[path] = []
		pending_paths.append(path)
	waiting_placements[path].append(placement)


func _interior_source_origin(placements: Array) -> Vector3:
	for placement_value in placements:
		var placement := placement_value as Dictionary
		if str(placement.get("base_type", "")) == "DOOR":
			return _source_position(placement)
	return _source_position(placements[0] as Dictionary) if not placements.is_empty() else Vector3.ZERO


func _interior_source_center(placements: Array) -> Vector3:
	if placements.is_empty():
		return Vector3.ZERO
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for placement_value in placements:
		var point := _source_position(placement_value as Dictionary)
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return (minimum + maximum) * 0.5


func _process(_delta: float) -> void:
	if pending_paths.is_empty() and active_paths.is_empty() and pending_skeletal_placements.is_empty():
		set_process(false)
		visible = true
		print("OPENNV_ACTOR_RESIDENT count=%d" % resident_actors)
		var actor_coverage := _resident_actor_visual_coverage()
		print("OPENNV_ACTOR_VISUAL_COVERAGE expected=%d exact=%d fallback=%d missing=%d" % [
			actor_coverage.expected, actor_coverage.exact, actor_coverage.fallback, actor_coverage.missing])
		print("OPENNV_CELL_RESIDENT cells=%d terrain=%d instances=%d meshes=%d radius=%d" % [
			resident_cells, resident_terrain_cells, resident_instances, mesh_cache.size(), FULL_DETAIL_RADIUS])
		if not initial_residency_emitted:
			initial_residency_emitted = true
			residency_ready.emit(resident_cells, resident_terrain_cells, resident_instances)
		return
	if not pending_skeletal_placements.is_empty():
		var skeletal_start := Time.get_ticks_usec()
		var skeletal_placement := pending_skeletal_placements.pop_back() as Dictionary
		if not _placement_is_resident(skeletal_placement):
			return
		var skeletal_loader := load("res://scripts/opennv_skeletal_actor_loader.gd")
		var skeletal_scene := skeletal_loader.call("load_scene", str(skeletal_placement.get("_runtime_skeletal", ""))) as Node3D
		if skeletal_scene != null:
			var actor_record := skeletal_placement.get("_runtime_actor", {}) as Dictionary
			var animation_path := str(actor_record.get("animation_idle", ""))
			if not animation_path.is_empty() and FileAccess.file_exists(animation_path):
				var animation_loader := load("res://scripts/opennv_animation_loader.gd")
				animation_loader.call("attach_clip", skeletal_scene, animation_path, "idle")
			_add_skeletal_actor(skeletal_scene, skeletal_placement)
		var skeletal_elapsed := Time.get_ticks_usec() - skeletal_start
		max_stream_commit_usec = maxi(max_stream_commit_usec, skeletal_elapsed)
		stream_commit_samples += 1
		return
	if not threaded_loading:
		# OpenXR/Vulkan drivers must not receive shared imported mesh resources
		# from ResourceLoader worker threads while swapchain images are acquired.
		var commit_start := Time.get_ticks_usec()
		var committed := 0
		while not pending_paths.is_empty() and (committed == 0 or Time.get_ticks_usec() - commit_start < STREAM_COMMIT_BUDGET_USEC):
			var path := pending_paths.pop_back() as String
			var imported_mesh := load(path) as Mesh
			if imported_mesh != null:
				_install_mesh(path, imported_mesh)
			else:
				waiting_placements.erase(path)
			committed += 1
		var elapsed := Time.get_ticks_usec() - commit_start
		max_stream_commit_usec = maxi(max_stream_commit_usec, elapsed)
		stream_commit_samples += 1
		return
	var commit_start := Time.get_ticks_usec()
	for index in range(active_paths.size() - 1, -1, -1):
		if Time.get_ticks_usec() - commit_start >= STREAM_COMMIT_BUDGET_USEC:
			break
		var path := active_paths[index]
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		active_paths.remove_at(index)
		if status != ResourceLoader.THREAD_LOAD_LOADED:
			push_warning("OPENNV_CELL_MESH_FAILED %s" % path)
			waiting_placements.erase(path)
			continue
		var imported_mesh := ResourceLoader.load_threaded_get(path) as Mesh
		if imported_mesh == null:
			waiting_placements.erase(path)
			continue
		_install_mesh(path, imported_mesh)
	var elapsed := Time.get_ticks_usec() - commit_start
	max_stream_commit_usec = maxi(max_stream_commit_usec, elapsed)
	stream_commit_samples += 1
	_pump_threaded_requests()


func _pump_threaded_requests() -> void:
	while active_paths.size() < MAX_CONCURRENT_MESH_LOADS and not pending_paths.is_empty():
		var path := pending_paths.pop_back() as String
		var error := ResourceLoader.load_threaded_request(path, "Mesh", true)
		if error == OK:
			active_paths.append(path)
		else:
			push_warning("OPENNV_CELL_MESH_REQUEST_FAILED %s error=%d" % [path, error])
			waiting_placements.erase(path)


func update_focus(focus_position: Vector3) -> void:
	if not _scope_is_exterior(active_scope):
		return
	_prefetch_nearby_interiors(focus_position, false)
	var world_origin := _world_runtime_origin(active_exterior_world_id)
	var atlas_position := world_origin + _godot_vector_to_source(focus_position * UNITS_PER_METER)
	var focus_grid := Vector2i(floori(atlas_position.x / 4096.0), floori(atlas_position.y / 4096.0))
	if focus_grid == last_focus_grid:
		return
	last_focus_grid = focus_grid
	var linked_interiors: Dictionary = {}
	var queued_cells := _stream_exterior_neighborhood(focus_grid, linked_interiors, false, active_exterior_world_id)
	_evict_actors_outside(focus_grid, active_exterior_world_id)
	_evict_exterior_outside(focus_grid, active_exterior_world_id)
	# Interior staging remains conservative until the door-distance prefetcher is
	# installed; never recurse through the entire interior graph at startup.
	for linked_cell_value in linked_interiors:
		_stage_interior(str(linked_cell_value))
	_flush_ready_placements()
	if queued_cells > 0:
		print("OPENNV_ROUTE_PREFETCH cells=%d focus_grid=%s remaining=%d" % [queued_cells, focus_grid, deferred_route_cells.size()])
		set_process(true)
		if threaded_loading:
			_pump_threaded_requests()


func _stream_exterior_neighborhood(focus_grid: Vector2i, linked_interiors: Dictionary, initial: bool, world_id_value: String = "") -> int:
	var world_id := _canonical_form_id(world_id_value)
	if world_id.is_empty():
		world_id = primary_world_id
	var runtime_origin := _world_runtime_origin(world_id, focus_grid)
	var runtime_scope := _world_scope(world_id)
	var queued_cells := 0
	for y in range(focus_grid.y - TERRAIN_VISUAL_RADIUS, focus_grid.y + TERRAIN_VISUAL_RADIUS + 1):
		for x in range(focus_grid.x - TERRAIN_VISUAL_RADIUS, focus_grid.x + TERRAIN_VISUAL_RADIUS + 1):
			var grid := Vector2i(x, y)
			var indices := cell_indices_by_grid.get(_world_grid_key(world_id, grid), []) as Array
			if indices.is_empty():
				continue
			var distance := maxi(absi(x - focus_grid.x), absi(y - focus_grid.y))
			for index_value in indices:
				var cell_index := index_value as Dictionary
				var cell_id := _canonical_form_id(cell_index.get("form_id", ""))
				exterior_runtime_origins_by_cell[cell_id] = runtime_origin
				var needs_terrain := bool(cell_index.get("has_terrain", false)) and (
					not loaded_terrain_cells.has(cell_id)
					or (distance <= TERRAIN_COLLISION_RADIUS and not terrain_collision_cells.has(cell_id)))
				var needs_detail := distance <= ROUTE_PRELOAD_RADIUS and not loaded_detail_cells.has(cell_id)
				var needs_actors := distance <= ACTOR_VISUAL_RADIUS and not loaded_actor_cells.has(cell_id)
				if not needs_terrain and not needs_detail and not needs_actors:
					continue
				var cell := (_materialize_shard(cell_index) as Dictionary).duplicate(true)
				cell["_runtime_origin"] = [runtime_origin.x, runtime_origin.y, runtime_origin.z]
				cell["_runtime_scope"] = runtime_scope
				if needs_terrain and cell.has("terrain"):
					_add_terrain(cell, distance, false)
					loaded_terrain_cells[cell_id] = true
				if needs_detail:
					loaded_detail_cells[cell_id] = true
					deferred_route_cells.erase(cell_id)
					resident_cells += 1
					queued_cells += 1
					for placement_value in cell.get("placements", []):
						var placement := placement_value as Dictionary
						if str(placement.get("base_type", "")) in ["NPC_", "CREA"] and not needs_actors:
							continue
						_queue_placement(placement, str(cell.get("form_id", "")), runtime_origin, Vector3.ZERO, false, runtime_scope)
						_collect_destination_interior(placement, linked_interiors)
				elif needs_actors:
					for placement_value in cell.get("placements", []):
						var placement := placement_value as Dictionary
						if str(placement.get("base_type", "")) in ["NPC_", "CREA"]:
							_queue_placement(placement, cell_id, runtime_origin, Vector3.ZERO, false, runtime_scope)
				if needs_actors:
					_load_navmesh_cell(cell_id, runtime_origin, Vector3.ZERO, runtime_scope)
					loaded_actor_cells[cell_id] = true
	if initial:
		last_focus_grid = focus_grid
	return queued_cells


func _world_grid_key(world_id_value: String, grid: Vector2i) -> String:
	return "%s|%d,%d" % [_canonical_form_id(world_id_value), grid.x, grid.y]


func _world_scope(world_id_value: String) -> String:
	var world_id := _canonical_form_id(world_id_value)
	return EXTERIOR_SCOPE if world_id == primary_world_id else "world:" + world_id


func _scope_is_exterior(scope: String) -> bool:
	return scope == EXTERIOR_SCOPE or scope.begins_with("world:")


func _world_runtime_origin(world_id_value: String, preferred_grid: Vector2i = Vector2i.ZERO) -> Vector3:
	var world_id := _canonical_form_id(world_id_value)
	if world_id == primary_world_id:
		return source_origin
	if not isolated_world_origins.has(world_id):
		isolated_world_origins[world_id] = Vector3(
			float(preferred_grid.x * 4096), float(preferred_grid.y * 4096), 0.0)
	return isolated_world_origins[world_id] as Vector3


func _flush_ready_placements() -> void:
	for path_value in ready_placements.keys():
		var path := str(path_value)
		if mesh_cache.has(path):
			_add_placements(mesh_cache[path] as Mesh, ready_placements[path] as Array)
	ready_placements.clear()


func _register_stream_node(cell_id_value: Variant, node: Node, instance_count: int = 0, mesh: Mesh = null) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	if cell_id.is_empty():
		return
	if not stream_nodes_by_cell.has(cell_id):
		stream_nodes_by_cell[cell_id] = []
	(stream_nodes_by_cell[cell_id] as Array).append(node)
	if node.has_meta("fnv_actor_id"):
		if not actor_nodes_by_cell.has(cell_id):
			actor_nodes_by_cell[cell_id] = []
		(actor_nodes_by_cell[cell_id] as Array).append(node)
	node.set_meta("opennv_stream_instance_count", instance_count)
	if mesh != null and mesh.has_meta("opennv_source_path"):
		var path := str(mesh.get_meta("opennv_source_path", ""))
		if not path.is_empty():
			node.set_meta("opennv_stream_mesh_path", path)
			mesh_ref_counts[path] = int(mesh_ref_counts.get(path, 0)) + 1


func _evict_exterior_outside(focus_grid: Vector2i, world_id_value: String = "") -> void:
	var active_world := _canonical_form_id(world_id_value)
	if active_world.is_empty():
		active_world = primary_world_id
	for cell_id_value in loaded_detail_cells.keys():
		var cell_id := str(cell_id_value)
		var index := cell_indices_by_id.get(cell_id, {}) as Dictionary
		var values := index.get("grid", []) as Array
		if values.size() < 2:
			continue
		var grid := Vector2i(int(values[0]), int(values[1]))
		var cell_world := _canonical_form_id(index.get("world_form_id", ""))
		if cell_world == active_world and maxi(absi(grid.x - focus_grid.x), absi(grid.y - focus_grid.y)) <= DETAIL_KEEP_RADIUS:
			continue
		_drop_pending_cell_placements(cell_id)
		for node_value in stream_nodes_by_cell.get(cell_id, []):
			var node := node_value as Node
			if not is_instance_valid(node):
				continue
			resident_instances = maxi(0, resident_instances - int(node.get_meta("opennv_stream_instance_count", 0)))
			if node.has_meta("fnv_actor_id"):
				resident_actors = maxi(0, resident_actors - 1)
			_release_stream_mesh_ref(node)
			if node.has_meta("fnv_form_id"):
				var form_id := str(node.get_meta("fnv_form_id", "")).to_lower()
				door_nodes_by_form_id.erase(form_id)
				actor_nodes_by_form_id.erase(form_id)
			node.queue_free()
		stream_nodes_by_cell.erase(cell_id)
		actor_visual_status_by_cell.erase(cell_id)
		for door_id_value in interior_prefetch_doors.keys():
			var door_record := interior_prefetch_doors[door_id_value] as Dictionary
			if _canonical_form_id(door_record.get("_runtime_cell", "")) == cell_id:
				interior_prefetch_doors.erase(door_id_value)
		loaded_detail_cells.erase(cell_id)
		loaded_actor_cells.erase(cell_id)
		actor_nodes_by_cell.erase(cell_id)
		deferred_route_cells[cell_id] = index
		resident_cells = maxi(0, resident_cells - 1)
	for cell_id_value in loaded_terrain_cells.keys():
		var cell_id := str(cell_id_value)
		var index := cell_indices_by_id.get(cell_id, {}) as Dictionary
		var values := index.get("grid", []) as Array
		if values.size() < 2:
			continue
		var grid := Vector2i(int(values[0]), int(values[1]))
		var cell_world := _canonical_form_id(index.get("world_form_id", ""))
		if cell_world == active_world and maxi(absi(grid.x - focus_grid.x), absi(grid.y - focus_grid.y)) <= TERRAIN_KEEP_RADIUS:
			continue
		if terrain_visual_by_cell.has(cell_id):
			var visual := terrain_visual_by_cell[cell_id] as Node
			if is_instance_valid(visual):
				visual.queue_free()
			terrain_visual_by_cell.erase(cell_id)
		if terrain_body_by_cell.has(cell_id):
			var body := terrain_body_by_cell[cell_id] as Node
			if is_instance_valid(body):
				body.queue_free()
			terrain_body_by_cell.erase(cell_id)
		terrain_collision_cells.erase(cell_id)
		loaded_terrain_cells.erase(cell_id)
		resident_terrain_cells = maxi(0, resident_terrain_cells - 1)
	_compact_scope_registries()


func _evict_actors_outside(focus_grid: Vector2i, world_id_value: String) -> void:
	var active_world := _canonical_form_id(world_id_value)
	for cell_id_value in loaded_actor_cells.keys():
		var cell_id := str(cell_id_value)
		var index := cell_indices_by_id.get(cell_id, {}) as Dictionary
		var values := index.get("grid", []) as Array
		if values.size() < 2:
			continue
		var grid := Vector2i(int(values[0]), int(values[1]))
		var cell_world := _canonical_form_id(index.get("world_form_id", ""))
		if cell_world == active_world and maxi(absi(grid.x - focus_grid.x), absi(grid.y - focus_grid.y)) <= ACTOR_KEEP_RADIUS:
			continue
		var cell_nodes := stream_nodes_by_cell.get(cell_id, []) as Array
		for node_value in actor_nodes_by_cell.get(cell_id, []):
			var node := node_value as Node
			cell_nodes.erase(node)
			if not is_instance_valid(node):
				continue
			resident_instances = maxi(0, resident_instances - int(node.get_meta("opennv_stream_instance_count", 0)))
			resident_actors = maxi(0, resident_actors - 1)
			_release_stream_mesh_ref(node)
			var form_id := str(node.get_meta("fnv_form_id", "")).to_lower()
			actor_nodes_by_form_id.erase(form_id)
			node.queue_free()
		actor_nodes_by_cell.erase(cell_id)
		actor_visual_status_by_cell.erase(cell_id)
		loaded_actor_cells.erase(cell_id)
		_retire_navmesh_cell(cell_id)


func _resident_actor_visual_coverage() -> Dictionary:
	var result := {"expected": 0, "exact": 0, "fallback": 0, "missing": 0}
	for status_values in actor_visual_status_by_cell.values():
		for status_value in (status_values as Dictionary).values():
			result.expected += 1
			var status := str(status_value)
			if result.has(status):
				result[status] += 1
	return result


func _release_stream_mesh_ref(node: Node) -> void:
	var path := str(node.get_meta("opennv_stream_mesh_path", ""))
	if path.is_empty():
		return
	var remaining := maxi(0, int(mesh_ref_counts.get(path, 0)) - 1)
	if remaining == 0:
		mesh_ref_counts.erase(path)
		mesh_cache.erase(path)
		collision_shape_cache.erase(path + "|trimesh")
		collision_shape_cache.erase(path + "|convex")
	else:
		mesh_ref_counts[path] = remaining


func _prefetch_nearby_interiors(focus_position: Vector3, force: bool) -> void:
	var now := Time.get_ticks_msec()
	if not force and now - last_interior_prefetch_msec < INTERIOR_PREFETCH_INTERVAL_MSEC:
		return
	last_interior_prefetch_msec = now
	for door_value in interior_prefetch_doors.values():
		var door := door_value as Dictionary
		var door_position := _runtime_position_in_cell(
			_source_position(door), _canonical_form_id(door.get("_runtime_cell", "")))
		if door_position.distance_squared_to(focus_position) > INTERIOR_PREFETCH_DISTANCE * INTERIOR_PREFETCH_DISTANCE:
			continue
		var destination_cell := _canonical_form_id(door.get("destination_cell", ""))
		if not destination_cell.is_empty():
			_stage_interior(destination_cell)
	_flush_ready_placements()
	if not pending_paths.is_empty() or not pending_skeletal_placements.is_empty():
		set_process(true)
		if threaded_loading:
			_pump_threaded_requests()


func _compact_scope_registries() -> void:
	for scope_value in visuals_by_scope.keys():
		var compact: Array = []
		for node_value in visuals_by_scope[scope_value]:
			var node := node_value as Node
			if is_instance_valid(node) and not node.is_queued_for_deletion():
				compact.append(node)
		visuals_by_scope[scope_value] = compact
	for scope_value in collision_bodies_by_scope.keys():
		var compact: Array = []
		for node_value in collision_bodies_by_scope[scope_value]:
			var node := node_value as Node
			if is_instance_valid(node) and not node.is_queued_for_deletion():
				compact.append(node)
		collision_bodies_by_scope[scope_value] = compact


func _upgrade_terrain_collision(focus_grid: Vector2i) -> void:
	# Collision upgrades are handled by the direct neighborhood lookup above.
	# Retained as a compatibility entry point for older callers.
	return


func preload_route_corridor() -> void:
	# Proof capture must never spend its recorded runtime discovering meshes.
	# Queue the entire authored corridor while the recorder is still gated, then
	# signal only after every threaded resource has been installed.
	var queued_cells := deferred_route_cells.size()
	var remaining_indices := deferred_route_cells.values()
	deferred_route_cells.clear()
	for index_value in remaining_indices:
		var cell := _materialize_shard(index_value as Dictionary)
		var linked_interiors: Dictionary = {}
		for placement_value in cell.get("placements", []):
			var placement := placement_value as Dictionary
			_queue_placement(placement, str(cell.get("form_id", "")), source_origin, Vector3.ZERO, false)
			_collect_destination_interior(placement, linked_interiors)
		for linked_cell_value in linked_interiors:
			_stage_interior(str(linked_cell_value))
	_flush_ready_placements()
	print("OPENNV_ROUTE_PRELOAD_BEGIN cells=%d pending_meshes=%d" % [queued_cells, pending_paths.size()])
	set_process(true)
	if threaded_loading:
		_pump_threaded_requests()
	while not pending_paths.is_empty() or not active_paths.is_empty():
		await get_tree().process_frame
	print("OPENNV_ROUTE_PRELOAD_READY cells=%d meshes=%d instances=%d" % [queued_cells, mesh_cache.size(), resident_instances])
	route_corridor_ready.emit()


func _install_mesh(path: String, imported_mesh: Mesh) -> void:
	# Material semantics are renderer-specific. Never mutate the shared import
	# cache returned by the loader while the renderer may be uploading it.
	var mesh := imported_mesh if DisplayServer.get_name() == "headless" else imported_mesh.duplicate(true) as Mesh
	_apply_nif_material_semantics(mesh, path)
	mesh = _split_render_and_collision_surfaces(mesh, path)
	mesh.set_meta("opennv_source_path", path)
	mesh_cache[path] = mesh
	var placements := waiting_placements.get(path, []) as Array
	waiting_placements.erase(path)
	_add_placements(mesh, placements)
	if DisplayServer.get_name() != "headless" and not mesh_ref_counts.has(path):
		mesh_cache.erase(path)


func _split_render_and_collision_surfaces(source: Mesh, mesh_path: String) -> Mesh:
	if DisplayServer.get_name() == "headless":
		return source
	var metadata_path := mesh_path + ".textures.json"
	if not FileAccess.file_exists(metadata_path):
		return source
	var metadata := _read_json(metadata_path)
	var render_flags := metadata.get("render_surfaces", []) as Array
	var collision_flags := metadata.get("collision_surfaces", []) as Array
	if render_flags.size() != source.get_surface_count() or collision_flags.size() != source.get_surface_count():
		return source
	var render_indices: Array[int] = []
	var collision_indices: Array[int] = []
	for surface_index in range(source.get_surface_count()):
		if bool(render_flags[surface_index]):
			render_indices.append(surface_index)
		if bool(collision_flags[surface_index]):
			collision_indices.append(surface_index)
	if render_indices.is_empty():
		var collision_only := ArrayMesh.new()
		collision_only.set_meta("opennv_has_collision", not collision_indices.is_empty())
		if not collision_indices.is_empty():
			collision_only.set_meta("opennv_collision_mesh", _mesh_surface_subset(source, collision_indices))
		return collision_only
	var result := _mesh_surface_subset(source, render_indices) if render_indices.size() != source.get_surface_count() else source
	result.set_meta("opennv_has_collision", not collision_indices.is_empty())
	if not collision_indices.is_empty():
		result.set_meta("opennv_collision_mesh", _mesh_surface_subset(source, collision_indices))
	return result


func _collision_mesh_for(source: Mesh) -> Mesh:
	if source.has_meta("opennv_collision_mesh"):
		var collision_mesh := source.get_meta("opennv_collision_mesh") as Mesh
		if collision_mesh != null:
			return collision_mesh
	return source


func _collision_shape_for(source: Mesh, convex: bool = false) -> Shape3D:
	if source.has_meta("opennv_has_collision") and not bool(source.get_meta("opennv_has_collision")):
		return null
	var path := str(source.get_meta("opennv_source_path", ""))
	var kind := "convex" if convex else "trimesh"
	var key := path + "|" + kind if not path.is_empty() else "%d|%s" % [source.get_instance_id(), kind]
	if collision_shape_cache.has(key):
		return collision_shape_cache[key] as Shape3D
	var shape: Shape3D = source.create_convex_shape() if convex else _collision_mesh_for(source).create_trimesh_shape()
	collision_shape_cache[key] = shape
	return shape


func _apply_nif_material_semantics(mesh: Mesh, mesh_path: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var metadata_path := mesh_path + ".textures.json"
	var metadata := _read_json(metadata_path) if FileAccess.file_exists(metadata_path) else {}
	var alpha_surfaces: Array = metadata.get("alpha_surfaces", [])
	var two_sided_surfaces: Array = metadata.get("two_sided_surfaces", [])
	var actor_mesh := "/generated/actors/" in mesh_path.to_lower()
	for surface_index in range(mesh.get_surface_count()):
		var alpha_cutout := surface_index < alpha_surfaces.size() and bool(alpha_surfaces[surface_index])
		var source_material := mesh.surface_get_material(surface_index) as StandardMaterial3D
		if source_material == null:
			# Never expose Godot's white default material. A surface without an
			# authored material gets an explicit low-reflectance wasteland fallback.
			var fallback := StandardMaterial3D.new()
			fallback.albedo_color = Color(0.20, 0.16, 0.11, 1.0)
			fallback.roughness = 1.0
			fallback.cull_mode = BaseMaterial3D.CULL_BACK
			mesh.surface_set_material(surface_index, fallback)
			continue
		var texture_path := ""
		if source_material.albedo_texture != null:
			texture_path = source_material.albedo_texture.resource_path.to_lower()
		var tint_fence := "fence" in mesh_path.to_lower() or "fence" in texture_path
		var missing_authored_texture := source_material.albedo_texture == null
		var material := source_material.duplicate() as StandardMaterial3D
		# Keep authored opaque shells one-sided. The former blanket cull-disabled
		# policy exposed hidden reverse faces and made houses appear inside out.
		material.cull_mode = (BaseMaterial3D.CULL_DISABLED
			if surface_index < two_sided_surfaces.size() and bool(two_sided_surfaces[surface_index])
			else BaseMaterial3D.CULL_BACK)
		if missing_authored_texture:
			material.albedo_color = Color(0.20, 0.16, 0.11, 1.0)
			material.metallic = 0.0
			material.roughness = 1.0
		if alpha_cutout or (actor_mesh and material.albedo_texture != null):
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			material.alpha_scissor_threshold = 0.42
			material.cull_mode = BaseMaterial3D.CULL_DISABLED
		if tint_fence:
			# The source fence diffuse is near paper-white and the original engine
			# darkens it through its legacy lighting path. Match that response here
			# so these alpha cards never become white horizon artifacts in VR.
			material.albedo_color *= Color(0.19, 0.17, 0.14, 1.0)
		var goodsprings_victor_screen := (mesh_path.to_lower().ends_with("/actor-036.obj")
			and surface_index == 0)
		if "victor_neutral" in texture_path or goodsprings_victor_screen:
			# Victor's authored face is a lit Securitron display, not an ordinary
			# diffuse panel. Keep it readable in shade after the live controller
			# stack has been flattened into the Godot actor snapshot.
			if goodsprings_victor_screen:
				material.albedo_texture = load("res://generated/assets/converted/textures/creatures/securitron/victor_neutral.dds") as Texture2D
			material.albedo_color = Color.WHITE
			material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			# The live NIF controller applies a screen-space/decal ordering bias.
			# The flattened OBJ loses that state and leaves the display behind the
			# monitor glass, so restore the authored overlay ordering explicitly.
			material.no_depth_test = true
			material.render_priority = 100
			material.emission_enabled = true
			material.emission_texture = material.albedo_texture
			material.emission = Color(1.0, 1.0, 1.0, 1.0)
			material.emission_energy_multiplier = 1.35
		mesh.surface_set_material(surface_index, material)


func _add_placements(mesh: Mesh, placements: Array) -> void:
	var current_placements: Array = []
	for placement_value in placements:
		var placement := placement_value as Dictionary
		var cell_id := _canonical_form_id(placement.get("_runtime_cell", ""))
		if bool(placement.get("_runtime_interior", false)):
			if staged_interiors.has(cell_id):
				current_placements.append(placement)
		elif loaded_detail_cells.has(cell_id):
			current_placements.append(placement)
	placements = current_placements
	if placements.is_empty():
		return
	if DisplayServer.get_name() == "headless" and OS.get_environment("FNV_GODOT_HEADLESS_PHYSICS") != "1":
		resident_instances += placements.size()
		for placement_value in placements:
			if (placement_value as Dictionary).has("_runtime_actor"):
				resident_actors += 1
		return
	var static_placements_by_cell: Dictionary = {}
	for placement_value in placements:
		var placement := placement_value as Dictionary
		if placement.has("_runtime_actor"):
			_add_actor(mesh, placement)
		elif _is_spinning_windmill(placement):
			_add_spinning_windmill(mesh, placement)
		elif str(placement.get("base_type", "")) in ["DOOR", "CONT", "ACTI", "TACT", "FURN"]:
			_add_placement(mesh, placement)
		else:
			var scope := _placement_scope(placement)
			var cell_id := _canonical_form_id(placement.get("_runtime_cell", ""))
			var batch_key := "%s|%s" % [scope, cell_id]
			if not static_placements_by_cell.has(batch_key):
				static_placements_by_cell[batch_key] = []
			(static_placements_by_cell[batch_key] as Array).append(placement)
	for batch_key_value in static_placements_by_cell:
		var static_placements := static_placements_by_cell[batch_key_value] as Array
		var scope := _placement_scope(static_placements[0] as Dictionary)
		var cell_id := _canonical_form_id((static_placements[0] as Dictionary).get("_runtime_cell", ""))
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = static_placements.size()
		for index in range(static_placements.size()):
			multimesh.set_instance_transform(index, _placement_transform(static_placements[index]))
		var batch := MultiMeshInstance3D.new()
		batch.name = "StaticBatch_%d_%s_%s" % [mesh_cache.size(), scope, cell_id]
		batch.multimesh = multimesh
		add_child(batch)
		_register_visual(scope, batch)
		_register_stream_node(cell_id, batch, static_placements.size(), mesh)
		# Exterior architecture needs the same physical contract as interiors.
		# Reuse one trimesh shape per source mesh and instance only its transform.
		if _mesh_has_authored_collision(mesh, static_placements[0] as Dictionary):
			var collision_shape := _collision_shape_for(mesh)
			if collision_shape != null:
				var body := StaticBody3D.new()
				body.name = "WorldCollision_%d_%s" % [mesh_cache.size(), scope]
				for placement_value in static_placements:
					var shape := CollisionShape3D.new()
					shape.shape = collision_shape
					shape.transform = _placement_transform(placement_value as Dictionary)
					body.add_child(shape)
				add_child(body)
				_register_collision_body(scope, body)
				_register_stream_node(cell_id, body)
		resident_instances += static_placements.size()


func _is_spinning_windmill(placement: Dictionary) -> bool:
	return "spinningwindmill" in str(placement.get("model", "")).to_lower().replace("\\", "/")


func _mesh_surface_subset(source: Mesh, indices: Array[int]) -> ArrayMesh:
	var result := ArrayMesh.new()
	for surface_index in indices:
		if surface_index < 0 or surface_index >= source.get_surface_count():
			continue
		result.add_surface_from_arrays(
			source.surface_get_primitive_type(surface_index),
			source.surface_get_arrays(surface_index))
		result.surface_set_material(result.get_surface_count() - 1, source.surface_get_material(surface_index))
	return result


func _surface_center(source: Mesh, surface_index: int) -> Vector3:
	if surface_index < 0 or surface_index >= source.get_surface_count():
		return Vector3.ZERO
	var arrays := source.surface_get_arrays(surface_index)
	var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	if vertices.is_empty():
		return Vector3.ZERO
	var minimum := vertices[0]
	var maximum := vertices[0]
	for vertex in vertices:
		minimum = minimum.min(vertex)
		maximum = maximum.max(vertex)
	return (minimum + maximum) * 0.5


func _add_spinning_windmill(mesh: Mesh, placement: Dictionary) -> void:
	if mesh.get_surface_count() < 2:
		return
	var assembly := Node3D.new()
	assembly.name = "%s_%s" % [str(placement.get("base_editor_id", "Windmill")), str(placement.get("form_id", ""))]
	assembly.transform = _placement_transform(placement)
	var stationary_indices: Array[int] = []
	for surface_index in range(1, mesh.get_surface_count()):
		stationary_indices.append(surface_index)
	var tower := MeshInstance3D.new()
	tower.name = "Tower"
	tower.mesh = _mesh_surface_subset(mesh, stationary_indices)
	assembly.add_child(tower)
	var rotor_script := load("res://scripts/fnv_spinning_prop.gd")
	var rotor := rotor_script.new() as Node3D
	rotor.name = "Rotor"
	var pivot := _surface_center(mesh, 0)
	rotor.position = pivot
	var blades := MeshInstance3D.new()
	blades.name = "Blades"
	blades.mesh = _mesh_surface_subset(mesh, [0])
	blades.position = -pivot
	rotor.add_child(blades)
	assembly.add_child(rotor)
	add_child(assembly)
	var scope := _placement_scope(placement)
	_register_visual(scope, assembly)
	_register_stream_node(placement.get("_runtime_cell", ""), assembly, 1, mesh)
	var collision_shape := _collision_shape_for(mesh)
	if collision_shape != null:
		var body := StaticBody3D.new()
		body.name = assembly.name + "_Collision"
		body.transform = assembly.transform
		var collider := CollisionShape3D.new()
		collider.shape = collision_shape
		body.add_child(collider)
		add_child(body)
		_register_collision_body(scope, body)
		_register_stream_node(placement.get("_runtime_cell", ""), body)
	resident_instances += 1


func _static_mesh_needs_collision(placement: Dictionary) -> bool:
	var model := str(placement.get("model", "")).to_lower().replace("\\", "/")
	# LAND is the general walking surface, but Bethesda road/ramp meshes bridge
	# deliberate cuts and elevation changes that raw LAND cannot represent.
	# Retain those authored roadway surfaces while excluding rocks, vegetation,
	# signs and clutter from the expensive collision set.
	return (model.begins_with("architecture/") or model.begins_with("dungeons/")
		or "wastelandroad" in model or model.begins_with("scol/scolroad")
		or model.begins_with("scol/scolgs") or "house" in model or "porch" in model)


func _mesh_has_authored_collision(mesh: Mesh, placement: Dictionary) -> bool:
	if mesh.has_meta("opennv_has_collision"):
		return bool(mesh.get_meta("opennv_has_collision"))
	return _static_mesh_needs_collision(placement)


func _add_actor(mesh: Mesh, placement: Dictionary) -> void:
	var actor_record := placement.get("_runtime_actor", {}) as Dictionary
	var actor_script := load("res://scripts/fnv_actor.gd")
	var actor := actor_script.new() as CharacterBody3D
	actor.name = "Actor_%s_%s" % [str(actor_record.get("id", "unknown")), str(placement.get("form_id", ""))]
	var authored_transform := _placement_transform(placement)
	authored_transform.basis = authored_transform.basis.orthonormalized()
	actor.transform = authored_transform
	actor.set_meta("fnv_form_id", placement.get("form_id", ""))
	actor.set_meta("fnv_base_form_id", placement.get("base_form_id", ""))
	actor.set_meta("fnv_actor_id", actor_record.get("id", ""))
	actor.set_meta("fnv_actor_category", actor_record.get("category", ""))
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.mesh = mesh
	visual.scale = Vector3.ONE * (float(placement.get("scale", 1.0)) / UNITS_PER_METER)
	actor.add_child(visual)
	_install_humanoid_motion(visual, mesh, actor_record)
	var collider := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	var category := str(actor_record.get("category", ""))
	if "creature" in category:
		capsule.radius = 0.28
		capsule.height = 0.9
	else:
		capsule.radius = 0.34
		capsule.height = 1.72
	collider.shape = capsule
	collider.position.y = capsule.height * 0.5
	actor.add_child(collider)
	add_child(actor)
	_register_stream_node(placement.get("_runtime_cell", ""), actor, 1, mesh)
	actor_nodes_by_form_id[str(placement.get("form_id", "")).to_lower()] = actor
	actor.call("configure", str(actor_record.get("id", "")), category, _actor_package_semantics(placement, category))
	var scope := _placement_scope(placement)
	_register_visual(scope, actor)
	_register_collision_body(scope, actor)
	resident_instances += 1
	resident_actors += 1
	if OS.get_environment("FNV_GODOT_ACTOR_TRACE") == "1":
		print("OPENNV_ACTOR_SPAWN id=%s ref=%s scope=%s" % [actor_record.get("id", ""), placement.get("form_id", ""), scope])


func _add_skeletal_actor(skeletal_scene: Node3D, placement: Dictionary) -> void:
	var actor_record := placement.get("_runtime_actor", {}) as Dictionary
	var actor_script := load("res://scripts/fnv_actor.gd")
	var actor := actor_script.new() as CharacterBody3D
	actor.name = "SkeletalActor_%s_%s" % [str(actor_record.get("id", "unknown")), str(placement.get("form_id", ""))]
	var authored_transform := _placement_transform(placement)
	authored_transform.basis = authored_transform.basis.orthonormalized()
	actor.transform = authored_transform
	actor.set_meta("fnv_form_id", placement.get("form_id", ""))
	actor.set_meta("fnv_base_form_id", placement.get("base_form_id", ""))
	actor.set_meta("fnv_actor_id", actor_record.get("id", ""))
	actor.set_meta("fnv_actor_category", actor_record.get("category", ""))
	actor.set_meta("opennv_skeletal", true)
	skeletal_scene.name = "Visual"
	actor.add_child(skeletal_scene)
	var collider := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	var category := str(actor_record.get("category", ""))
	if "creature" in category:
		capsule.radius = 0.28
		capsule.height = 0.9
	else:
		capsule.radius = 0.34
		capsule.height = 1.72
	collider.shape = capsule
	collider.position.y = capsule.height * 0.5
	actor.add_child(collider)
	add_child(actor)
	_register_stream_node(placement.get("_runtime_cell", ""), actor, 1)
	actor_nodes_by_form_id[str(placement.get("form_id", "")).to_lower()] = actor
	actor.call("configure", str(actor_record.get("id", "")), category, _actor_package_semantics(placement, category))
	var scope := _placement_scope(placement)
	_register_visual(scope, actor)
	_register_collision_body(scope, actor)
	resident_instances += 1
	resident_actors += 1
	if OS.get_environment("FNV_GODOT_ACTOR_TRACE") == "1":
		print("OPENNV_SKELETAL_ACTOR_SPAWN id=%s ref=%s surfaces=%d" % [actor_record.get("id", ""), placement.get("form_id", ""), int(skeletal_scene.get_meta("opennv_skeletal_surface_count", 0))])


func _install_humanoid_motion(visual: MeshInstance3D, mesh: Mesh, actor_record: Dictionary) -> void:
	var category := str(actor_record.get("category", ""))
	if "humanoid" not in category and "settler" not in category:
		return
	var bounds := mesh.get_aabb()
	if bounds.size.y <= 0.01:
		return
	var shader := Shader.new()
	shader.code = HUMANOID_MOTION_SHADER
	var actor_phase := float(abs(str(actor_record.get("id", "")).hash()) % 1000) / 71.0
	for surface_index in range(mesh.get_surface_count()):
		var source := mesh.surface_get_material(surface_index) as StandardMaterial3D
		if source == null or source.albedo_texture == null:
			continue
		var material := ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter("albedo_texture", source.albedo_texture)
		material.set_shader_parameter("tint", source.albedo_color)
		material.set_shader_parameter("roughness_value", source.roughness)
		material.set_shader_parameter("metallic_value", source.metallic)
		material.set_shader_parameter("min_y", bounds.position.y)
		material.set_shader_parameter("actor_height", bounds.size.y)
		material.set_shader_parameter("center_x", bounds.get_center().x)
		material.set_shader_parameter("half_width", maxf(bounds.size.x * 0.22, bounds.size.y * 0.10))
		material.set_shader_parameter("phase", actor_phase)
		# These exported actors are post-skin snapshots, so no skeleton survives
		# into Godot. Animate the limb regions continuously in the vertex shader.
		# Do not mutate ShaderMaterial resources from every physics tick: actors
		# can be hidden/re-scoped during portal travel and the renderer may already
		# have retired their material RID, which caused an unbounded error loop.
		material.set_shader_parameter("motion", 1.0)
		visual.set_surface_override_material(surface_index, material)


func _add_placement(mesh: Mesh, placement: Dictionary) -> void:
	if str(placement.get("base_type", "")) == "DOOR":
		var door_script := load("res://scripts/fnv_door.gd")
		var door := door_script.new() as AnimatableBody3D
		door.name = "%s_%s" % [str(placement.get("base_editor_id", "Door")), str(placement.get("form_id", ""))]
		var authored_transform := _placement_transform(placement)
		var hinge_offset := _door_hinge_offset(mesh)
		authored_transform.origin += authored_transform.basis * hinge_offset
		door.transform = authored_transform
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		visual.position = -hinge_offset
		door.add_child(visual)
		var collider := CollisionShape3D.new()
		collider.shape = _collision_shape_for(mesh, true)
		collider.position = -hinge_offset
		door.add_child(collider)
		door.set_meta("fnv_form_id", placement.get("form_id", ""))
		door.set_meta("fnv_destination_door", placement.get("destination_door"))
		door.set_meta("fnv_destination_position", placement.get("destination_position"))
		door.set_meta("fnv_destination_rotation", placement.get("destination_rotation_radians"))
		door.set_meta("fnv_destination_cell", placement.get("destination_cell", ""))
		door.set_meta("fnv_cell", placement.get("_runtime_cell", ""))
		door.connect("portal_requested", _on_door_portal_requested)
		add_child(door)
		_register_stream_node(placement.get("_runtime_cell", ""), door, 1, mesh)
		var door_scope := _placement_scope(placement)
		_register_visual(door_scope, door)
		_register_collision_body(door_scope, door)
		door_nodes_by_form_id[str(placement.get("form_id", "")).to_lower()] = door
		resident_instances += 1
		return
	var instance := MeshInstance3D.new()
	instance.name = "%s_%s" % [str(placement.get("base_editor_id", "REFR")), str(placement.get("form_id", ""))]
	instance.mesh = mesh
	instance.transform = _placement_transform(placement)
	instance.set_meta("fnv_form_id", placement.get("form_id", ""))
	instance.set_meta("fnv_base_form_id", placement.get("base_form_id", ""))
	instance.set_meta("fnv_base_type", placement.get("base_type", ""))
	add_child(instance)
	var instance_scope := _placement_scope(placement)
	_register_visual(instance_scope, instance)
	_register_stream_node(placement.get("_runtime_cell", ""), instance, 1, mesh)
	resident_instances += 1


func _placement_transform(placement: Dictionary) -> Transform3D:
	var source_position := _source_position(placement)
	var origin_values: Array = placement.get("_runtime_origin", [source_origin.x, source_origin.y, source_origin.z])
	var runtime_origin := Vector3(float(origin_values[0]), float(origin_values[1]), float(origin_values[2]))
	var stage_values: Array = placement.get("_runtime_stage", [0.0, 0.0, 0.0])
	var stage_origin := Vector3(float(stage_values[0]), float(stage_values[1]), float(stage_values[2]))
	var rotation_values: Array = placement.get("rotation_radians", [0.0, 0.0, 0.0])
	var basis := _source_rotation_to_godot(Vector3(
		float(rotation_values[0]), float(rotation_values[1]), float(rotation_values[2])))
	basis = basis.scaled(Vector3.ONE * (float(placement.get("scale", 1.0)) / UNITS_PER_METER))
	return Transform3D(basis, stage_origin + _source_vector_to_godot(source_position - runtime_origin) / UNITS_PER_METER)


func _door_hinge_offset(mesh: Mesh) -> Vector3:
	var bounds := mesh.get_aabb()
	# Bethesda animated door NIFs normally retain a root at one horizontal
	# edge. Static load-door snapshots are centered because their controller
	# hierarchy was flattened; rebase only those centered meshes to an edge.
	var use_x := bounds.size.x > bounds.size.z
	var minimum := bounds.position.x if use_x else bounds.position.z
	var maximum := bounds.end.x if use_x else bounds.end.z
	var span := maximum - minimum
	if span <= 0.01:
		return Vector3.ZERO
	var edge_distance := minf(absf(minimum), absf(maximum))
	if edge_distance <= span * 0.16:
		return Vector3.ZERO
	return Vector3(minimum, 0.0, 0.0) if use_x else Vector3(0.0, 0.0, minimum)


func _source_position(placement: Dictionary) -> Vector3:
	var values: Array = placement.get("position", [0.0, 0.0, 0.0])
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


func _on_door_portal_requested(door: Node3D, actor: Node3D) -> void:
	if actor == null:
		return
	if bool(door.get_meta("opennv_portal_processing", false)):
		return
	door.set_meta("opennv_portal_processing", true)
	var destination_id := str(door.get_meta("fnv_destination_door", "")).to_lower()
	var destination_cell := _canonical_form_id(door.get_meta("fnv_destination_cell", ""))
	if interior_names.has(destination_cell) and not staged_interiors.has(destination_cell):
		_stage_interior(destination_cell)
		_flush_ready_placements()
		if threaded_loading:
			_pump_threaded_requests()
		set_process(true)
	elif not interior_names.has(destination_cell):
		_load_exterior_destination(destination_cell)
	# A door mesh can arrive before the floor, walls and collision for the same
	# cell. Never move the player into a partially committed destination.
	var wait_frames := 0
	while _cell_has_pending_placements(destination_cell) and wait_frames < 1800:
		await get_tree().process_frame
		wait_frames += 1
	if wait_frames >= 1800:
		push_warning("OPENNV_PORTAL_RESIDENCY_TIMEOUT source=%s destination_cell=%s" % [door.name, destination_cell])
		door.set_meta("opennv_portal_pending", false)
		door.set_meta("opennv_portal_processing", false)
		if door.has_method("complete_portal"):
			door.call("complete_portal")
		return
	# Scene nodes commit before the physics server sees their shapes. Two ticks
	# also cover a transition requested during the current physics callback.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var destination := door_nodes_by_form_id.get(destination_id) as Node3D
	if destination == null:
		push_warning("OPENNV_PORTAL_UNRESOLVED source=%s destination=%s" % [door.name, destination_id])
		door.set_meta("opennv_portal_pending", false)
		door.set_meta("opennv_portal_processing", false)
		if door.has_method("complete_portal"):
			door.call("complete_portal")
		return
	# Emerge just beyond the paired door, retaining the actor and all world state.
	_set_active_cell(destination_cell)
	var authored_destination_values: Variant = door.get_meta("fnv_destination_position", null)
	if authored_destination_values is Array and (authored_destination_values as Array).size() >= 3:
		var authored_values := authored_destination_values as Array
		var authored_destination := Vector3(
			float(authored_values[0]), float(authored_values[1]), float(authored_values[2]))
		actor.global_position = _runtime_position_in_cell(authored_destination, destination_cell)
		var authored_rotation_values: Variant = door.get_meta("fnv_destination_rotation", null)
		if authored_rotation_values is Array and (authored_rotation_values as Array).size() >= 3:
			var authored_rotation := authored_rotation_values as Array
			actor.global_basis = _source_rotation_to_godot(Vector3(
				float(authored_rotation[0]), float(authored_rotation[1]), float(authored_rotation[2])))
		if actor is CharacterBody3D:
			(actor as CharacterBody3D).velocity = Vector3.ZERO
		var authored_source_cell := str(door.get_meta("fnv_cell", ""))
		print("OPENNV_SEAMLESS_DOOR source=%s destination=%s landing=authored name=%s" % [
			authored_source_cell, destination_cell, interior_names.get(destination_cell, "exterior")])
		portal_transitioned.emit(authored_source_cell, destination_cell)
		door.set_meta("opennv_portal_pending", false)
		door.set_meta("opennv_portal_processing", false)
		if door.has_method("complete_portal"):
			door.call("complete_portal")
		return
	var exit_direction := destination.global_basis.z.normalized()
	if interior_centers.has(destination_cell):
		exit_direction = (interior_centers[destination_cell] as Vector3) - destination.global_position
	elif str(destination.get_meta("fnv_form_id", "")).to_lower() == "0x105228":
		# The converted Goodsprings Home door's mesh-forward axis runs along the
		# facade.  Its actual exterior apron and authored road are toward the
		# save-space origin, so land on that side instead of inside the wall.
		exit_direction = -destination.global_position
	exit_direction.y = 0.0
	if exit_direction.length_squared() < 0.1:
		exit_direction = Vector3.FORWARD
	actor.global_position = _safe_door_landing(destination, exit_direction.normalized())
	if actor is CharacterBody3D:
		(actor as CharacterBody3D).velocity = Vector3.ZERO
	var source_cell := str(door.get_meta("fnv_cell", ""))
	print("OPENNV_SEAMLESS_DOOR source=%s destination=%s name=%s" % [source_cell, destination_cell, interior_names.get(destination_cell, "exterior")])
	portal_transitioned.emit(source_cell, destination_cell)
	door.set_meta("opennv_portal_pending", false)
	door.set_meta("opennv_portal_processing", false)
	if door.has_method("complete_portal"):
		door.call("complete_portal")


func _load_exterior_destination(cell_id_value: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	if cell_id.is_empty() or loaded_detail_cells.has(cell_id) or not cell_indices_by_id.has(cell_id):
		return
	var cell_index := cell_indices_by_id[cell_id] as Dictionary
	var cell := (_materialize_shard(cell_index) as Dictionary).duplicate(true)
	var world_id := _canonical_form_id(cell_index.get("world_form_id", ""))
	var runtime_scope := _world_scope(world_id)
	var grid_values := cell_index.get("grid", [0, 0]) as Array
	var runtime_origin := _world_runtime_origin(world_id, Vector2i(int(grid_values[0]), int(grid_values[1])))
	exterior_runtime_origins_by_cell[cell_id] = runtime_origin
	_load_navmesh_cell(cell_id, runtime_origin, Vector3.ZERO, runtime_scope)
	cell["_runtime_origin"] = [runtime_origin.x, runtime_origin.y, runtime_origin.z]
	cell["_runtime_scope"] = runtime_scope
	loaded_detail_cells[cell_id] = true
	loaded_actor_cells[cell_id] = true
	deferred_route_cells.erase(cell_id)
	resident_cells += 1
	if cell.has("terrain"):
		_add_terrain(cell, 0, false)
		loaded_terrain_cells[cell_id] = true
	for placement_value in cell.get("placements", []):
		_queue_placement(placement_value as Dictionary, cell_id, runtime_origin, Vector3.ZERO, false, runtime_scope)
	_flush_ready_placements()
	set_process(true)
	if threaded_loading:
		_pump_threaded_requests()


func _placement_is_resident(placement: Dictionary) -> bool:
	var cell_id := _canonical_form_id(placement.get("_runtime_cell", ""))
	if bool(placement.get("_runtime_interior", false)):
		return staged_interiors.has(cell_id)
	if placement.has("_runtime_actor"):
		return loaded_actor_cells.has(cell_id)
	return loaded_detail_cells.has(cell_id)


func _headless_fast_residency() -> bool:
	return DisplayServer.get_name() == "headless" and OS.get_environment("FNV_GODOT_HEADLESS_FAST_RESIDENCY") == "1"


func _cell_has_pending_placements(cell_id_value: String) -> bool:
	var cell_id := _canonical_form_id(cell_id_value)
	for placement_values in waiting_placements.values():
		for placement_value in placement_values as Array:
			if _canonical_form_id((placement_value as Dictionary).get("_runtime_cell", "")) == cell_id:
				return true
	for placement_values in ready_placements.values():
		for placement_value in placement_values as Array:
			if _canonical_form_id((placement_value as Dictionary).get("_runtime_cell", "")) == cell_id:
				return true
	for placement_value in pending_skeletal_placements:
		if _canonical_form_id((placement_value as Dictionary).get("_runtime_cell", "")) == cell_id:
			return true
	return false


func _runtime_position_in_cell(authored_position: Vector3, cell_id_value: String) -> Vector3:
	var cell_id := _canonical_form_id(cell_id_value)
	if interior_source_origins.has(cell_id) and interior_stage_origins.has(cell_id):
		return (interior_stage_origins[cell_id] as Vector3) + _source_vector_to_godot(
			authored_position - (interior_source_origins[cell_id] as Vector3)) / UNITS_PER_METER
	var runtime_origin := exterior_runtime_origins_by_cell.get(cell_id, source_origin) as Vector3
	return _source_vector_to_godot(authored_position - runtime_origin) / UNITS_PER_METER


func _safe_door_landing(destination: CollisionObject3D, preferred_direction: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var landing_distances := [8.0, 6.0, 4.5] if str(destination.get_meta("fnv_form_id", "")).to_lower() == "0x105228" else [3.2, 4.5, 1.8]
	for direction_value in [preferred_direction, -preferred_direction]:
		var horizontal: Vector3 = direction_value
		horizontal.y = 0.0
		if horizontal.length_squared() < 0.1:
			continue
		horizontal = horizontal.normalized()
		# Door convex hulls and porch shells extend beyond the visible threshold.
		# Probe far enough out for the player's capsule to start fully clear.
		for landing_distance_value in landing_distances:
			var landing_distance := float(landing_distance_value)
			var probe_top: Vector3 = destination.global_position + horizontal * landing_distance + Vector3.UP * 1.8
			var query := PhysicsRayQueryParameters3D.create(probe_top, probe_top + Vector3.DOWN * 5.0)
			query.collision_mask = 1
			query.exclude = [destination.get_rid()]
			var hit := space.intersect_ray(query)
			if not hit.is_empty():
				var floor_point: Vector3 = hit.get("position", destination.global_position)
				return floor_point + Vector3.UP * 0.06
	return destination.global_position + preferred_direction * 3.2 + Vector3.UP * 0.06


func _placement_scope(placement: Dictionary) -> String:
	if placement.has("_runtime_scope"):
		return str(placement.get("_runtime_scope", EXTERIOR_SCOPE))
	return str(placement.get("_runtime_cell", "")) if bool(placement.get("_runtime_interior", false)) else EXTERIOR_SCOPE


func _canonical_form_id(value: Variant) -> String:
	var text := str(value).strip_edges().to_lower()
	if text.begins_with("0x"):
		return "0x%08x" % text.substr(2).hex_to_int()
	return text


func _register_visual(scope: String, node: Node3D) -> void:
	if not visuals_by_scope.has(scope):
		visuals_by_scope[scope] = []
	(visuals_by_scope[scope] as Array).append(node)
	node.visible = scope == active_scope


func _register_collision_body(scope: String, body: CollisionObject3D) -> void:
	if not collision_bodies_by_scope.has(scope):
		collision_bodies_by_scope[scope] = []
	(collision_bodies_by_scope[scope] as Array).append(body)
	body.collision_layer = 1 if scope == active_scope else 0


func _set_active_cell(cell_id: String) -> void:
	var canonical_cell := _canonical_form_id(cell_id)
	var previous_scope := active_scope
	var next_scope := (canonical_cell if interior_names.has(canonical_cell)
		else str(exterior_scope_by_cell.get(canonical_cell, EXTERIOR_SCOPE)))
	active_scope = next_scope
	if _scope_is_exterior(active_scope):
		var exterior_index := cell_indices_by_id.get(canonical_cell, {}) as Dictionary
		active_exterior_world_id = _canonical_form_id(exterior_index.get("world_form_id", primary_world_id))
		last_focus_grid = Vector2i(2147483647, 2147483647)
	else:
		_touch_interior_lru(active_scope)
	_trim_interior_residency()
	if previous_scope != active_scope:
		_set_scope_enabled(previous_scope, false)
	_set_scope_enabled(active_scope, true)
	print("OPENNV_CELL_SCOPE_ACTIVE scope=%s" % active_scope)


func _set_scope_enabled(scope: String, enabled: bool) -> void:
	for node_value in visuals_by_scope.get(scope, []):
		var node := node_value as Node3D
		if is_instance_valid(node):
			node.visible = enabled
	for body_value in collision_bodies_by_scope.get(scope, []):
		var body := body_value as CollisionObject3D
		if is_instance_valid(body):
			body.collision_layer = 1 if enabled else 0
	for region_value in navigation_regions_by_scope.get(scope, []):
		var region := region_value as NavigationRegion3D
		if is_instance_valid(region):
			region.enabled = enabled


func portal_destination_transform(source_door_id: String) -> Transform3D:
	var source := door_nodes_by_form_id.get(source_door_id.to_lower()) as Node3D
	if source == null:
		return Transform3D()
	var destination_id := str(source.get_meta("fnv_destination_door", "")).to_lower()
	var destination := door_nodes_by_form_id.get(destination_id) as Node3D
	return destination.global_transform if destination != null else Transform3D()


func door_by_form_id(form_id: String) -> Node3D:
	return door_nodes_by_form_id.get(form_id.to_lower()) as Node3D


func actor_by_form_id(form_id: String) -> Node3D:
	return actor_nodes_by_form_id.get(form_id.to_lower()) as Node3D


func interior_center(cell_id: String) -> Vector3:
	return interior_centers.get(_canonical_form_id(cell_id), Vector3.ZERO) as Vector3


func portal_destination_center(source_door_id: String) -> Vector3:
	var source := door_nodes_by_form_id.get(source_door_id.to_lower()) as Node3D
	if source == null:
		return Vector3.ZERO
	var destination_cell := str(source.get_meta("fnv_destination_cell", ""))
	return interior_centers.get(_canonical_form_id(destination_cell), Vector3.ZERO) as Vector3


func is_interior_cell(cell_id: String) -> bool:
	return interior_names.has(_canonical_form_id(cell_id))


func _add_terrain(cell: Dictionary, cell_distance: int, route_detail: bool) -> void:
	var cell_id := _canonical_form_id(cell.get("form_id", ""))
	var runtime_origin_values := cell.get("_runtime_origin", [source_origin.x, source_origin.y, source_origin.z]) as Array
	var runtime_origin := Vector3(
		float(runtime_origin_values[0]), float(runtime_origin_values[1]), float(runtime_origin_values[2]))
	var runtime_scope := str(cell.get("_runtime_scope", EXTERIOR_SCOPE))
	var cell_grid_values: Array = cell.get("grid", [0, 0])
	var cell_grid := Vector2i(int(cell_grid_values[0]), int(cell_grid_values[1]))
	var source_grid_values: Array = cell.get("source_grid", cell_grid_values)
	var source_grid := Vector2i(int(source_grid_values[0]), int(source_grid_values[1]))
	var atlas_rotation := float(cell.get("atlas_rotation_radians", 0.0))
	var atlas_translation_values: Array = cell.get("atlas_translation_units", [0.0, 0.0, 0.0])
	var atlas_translation := Vector3(float(atlas_translation_values[0]), float(atlas_translation_values[1]), float(atlas_translation_values[2]))
	var terrain := cell.get("terrain", {}) as Dictionary
	var deltas: Array = terrain.get("heightDeltas", [])
	if deltas.size() != 1089:
		return
	var replacing := terrain_visual_by_cell.has(cell_id) or terrain_body_by_cell.has(cell_id)
	if terrain_visual_by_cell.has(cell_id):
		var old_visual := terrain_visual_by_cell[cell_id] as Node
		if is_instance_valid(old_visual):
			old_visual.queue_free()
		terrain_visual_by_cell.erase(cell_id)
	if terrain_body_by_cell.has(cell_id):
		var old_body := terrain_body_by_cell[cell_id] as Node
		if is_instance_valid(old_body):
			old_body.queue_free()
		terrain_body_by_cell.erase(cell_id)
	if not replacing:
		resident_terrain_cells += 1
	var physics_validation := DisplayServer.get_name() == "headless" and OS.get_environment("FNV_GODOT_HEADLESS_PHYSICS") == "1"
	if DisplayServer.get_name() == "headless" and not physics_validation:
		return
	var heights := PackedFloat32Array()
	heights.resize(1089)
	var row_base := float(terrain.get("heightOffset", 0.0))
	for row in range(33):
		row_base += float(deltas[row * 33])
		var height := row_base
		heights[row * 33] = height * 8.0
		for column in range(1, 33):
			height += float(deltas[row * 33 + column])
			heights[row * 33 + column] = height * 8.0

	# Full-detail statics must sit on full-detail LAND. Keeping the complete
	# route surface at 33x33 prevents roads and rocks from floating over a coarse
	# 4x/8x approximation while off-route terrain remains aggressively reduced.
	var full_detail := cell_distance <= TERRAIN_COLLISION_RADIUS
	var sample_step := 1 if full_detail else (4 if cell_distance <= 12 else 8)
	var grid_width := int(32 / sample_step) + 1
	var vertices := PackedVector3Array()
	vertices.resize(grid_width * grid_width)
	for sample_row in range(grid_width):
		var row := sample_row * sample_step
		for sample_column in range(grid_width):
			var column := sample_column * sample_step
			var source := Vector3(
				source_grid.x * 4096.0 + column * 128.0,
				source_grid.y * 4096.0 + row * 128.0,
				heights[row * 33 + column])
			if not is_zero_approx(atlas_rotation) or atlas_translation != Vector3.ZERO:
				var cosine := cos(atlas_rotation)
				var sine := sin(atlas_rotation)
				source = Vector3(
					cosine * source.x - sine * source.y,
					sine * source.x + cosine * source.y,
					source.z) + atlas_translation
			vertices[sample_row * grid_width + sample_column] = _source_vector_to_godot(source - runtime_origin) / UNITS_PER_METER
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for sample_row in range(grid_width):
		for sample_column in range(grid_width):
			var vertex := vertices[sample_row * grid_width + sample_column]
			surface.set_uv(Vector2(float(sample_column), float(sample_row)) / float(grid_width - 1))
			surface.add_vertex(vertex)
	for row in range(grid_width - 1):
		for column in range(grid_width - 1):
			var a := row * grid_width + column
			var b := a + 1
			var c := a + grid_width
			var d := c + 1
			surface.add_index(a)
			surface.add_index(c)
			surface.add_index(b)
			surface.add_index(b)
			surface.add_index(c)
			surface.add_index(d)
	surface.generate_normals()
	var mesh := surface.commit()
	if physics_validation:
		var validation_body := StaticBody3D.new()
		validation_body.name = "LAND_%d_%d_Collision" % [cell_grid.x, cell_grid.y]
		var validation_shape := CollisionShape3D.new()
		validation_shape.shape = mesh.create_trimesh_shape()
		validation_body.add_child(validation_shape)
		add_child(validation_body)
		_register_collision_body(runtime_scope, validation_body)
		return
	var terrain_instance := MeshInstance3D.new()
	terrain_instance.name = "LAND_%d_%d" % [cell_grid.x, cell_grid.y]
	terrain_instance.mesh = mesh
	terrain_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if full_detail else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.62, 0.56, 0.44)
	material.roughness = 1.0
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var world_id := str(cell.get("world_form_id", "0")).to_lower().trim_prefix("0x")
	var baked_albedo := TERRAIN_ALBEDO_ROOT + "land_%s_%d_%d.png" % [world_id, source_grid.x, source_grid.y]
	var legacy_baked_albedo := TERRAIN_ALBEDO_ROOT + "land_%d_%d.png" % [cell_grid.x, cell_grid.y]
	if not FileAccess.file_exists(baked_albedo) and FileAccess.file_exists(legacy_baked_albedo):
		baked_albedo = legacy_baked_albedo
	if full_detail and FileAccess.file_exists(baked_albedo):
		material.albedo_texture = _load_runtime_image(baked_albedo)
	elif ResourceLoader.exists(TERRAIN_DIFFUSE):
		material.albedo_texture = load(TERRAIN_DIFFUSE)
	if not FileAccess.file_exists(baked_albedo) and ResourceLoader.exists(TERRAIN_NORMAL):
		material.normal_enabled = true
		material.normal_texture = load(TERRAIN_NORMAL)
		material.normal_scale = 0.65
	terrain_instance.material_override = material
	add_child(terrain_instance)
	_register_visual(runtime_scope, terrain_instance)
	terrain_visual_by_cell[cell_id] = terrain_instance
	if not full_detail:
		terrain_collision_cells.erase(cell_id)
		return
	var body := StaticBody3D.new()
	body.name = terrain_instance.name + "_Collision"
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	add_child(body)
	_register_collision_body(runtime_scope, body)
	terrain_body_by_cell[cell_id] = body
	terrain_collision_cells[cell_id] = true


func _load_runtime_image(path: String) -> Texture2D:
	if terrain_albedo_cache.has(path):
		return terrain_albedo_cache[path] as Texture2D
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		return null
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	terrain_albedo_cache[path] = texture
	return texture


func _append_distant_terrain(cell_grid: Vector2i, vertices: PackedVector3Array, grid_width: int) -> void:
	var chunk := Vector2i(
		floori(float(cell_grid.x) / DISTANT_CHUNK_CELLS),
		floori(float(cell_grid.y) / DISTANT_CHUNK_CELLS))
	var surface: SurfaceTool = distant_terrain_surfaces.get(chunk)
	if surface == null:
		surface = SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		distant_terrain_surfaces[chunk] = surface
	for row in range(grid_width - 1):
		for column in range(grid_width - 1):
			var a := row * grid_width + column
			var b := a + 1
			var c := a + grid_width
			var d := c + 1
			for index in [a, c, b, b, c, d]:
				var vertex := vertices[index]
				surface.set_uv(Vector2(vertex.x, -vertex.z) * 0.16)
				surface.add_vertex(vertex)


func _commit_distant_terrain() -> void:
	if DisplayServer.get_name() == "headless":
		return
	for chunk_value in distant_terrain_surfaces:
		var chunk := chunk_value as Vector2i
		var surface := distant_terrain_surfaces[chunk] as SurfaceTool
		surface.generate_normals()
		var instance := MeshInstance3D.new()
		instance.name = "DistantLAND_%d_%d" % [chunk.x, chunk.y]
		instance.mesh = surface.commit()
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.62, 0.56, 0.44)
		material.roughness = 1.0
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		if ResourceLoader.exists(TERRAIN_DIFFUSE):
			material.albedo_texture = load(TERRAIN_DIFFUSE)
		if ResourceLoader.exists(TERRAIN_NORMAL):
			material.normal_enabled = true
			material.normal_texture = load(TERRAIN_NORMAL)
			material.normal_scale = 0.65
		instance.material_override = material
		add_child(instance)
		_register_visual(EXTERIOR_SCOPE, instance)
	distant_terrain_surfaces.clear()


func _source_rotation_to_godot(euler: Vector3) -> Basis:
	# Match OpenMW's Gamebryo placement convention exactly:
	# q(-X) * q(-Y) * q(-Z), then conjugate from source coordinates
	# (x, y, z) into Godot coordinates (x, z, -y).  Using Godot's default
	# Euler order happened to work for yaw-only references but misplaced
	# pitched and rolled architecture, roads and clutter.
	var source_rotation := Basis(
		Quaternion(Vector3.RIGHT, -euler.x)
		* Quaternion(Vector3.UP, -euler.y)
		* Quaternion(Vector3.BACK, -euler.z))
	var source_to_godot := Basis(
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 0.0, -1.0),
		Vector3(0.0, 1.0, 0.0))
	return (source_to_godot * source_rotation * source_to_godot.inverse()).orthonormalized()


func _source_vector_to_godot(value: Vector3) -> Vector3:
	return Vector3(value.x, value.z, -value.y)


func _godot_vector_to_source(value: Vector3) -> Vector3:
	return Vector3(value.x, -value.z, value.y)


func _converted_path(model: String) -> String:
	if not model.to_lower().ends_with(".nif"):
		return ""
	return CONVERTED_ROOT + model.replace("\\", "/").trim_suffix(".nif") + ".obj"


func _array_to_vector3(value: Variant) -> Vector3:
	var values := value as Array
	if values.size() < 3:
		return Vector3.ZERO
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


func _materialize_shard(index: Dictionary) -> Dictionary:
	var shard := str(index.get("shard", ""))
	if shard.is_empty():
		return index
	var payload := _read_json(shard)
	if payload.is_empty():
		push_warning("OPENNV_CELL_SHARD_MISSING %s" % shard)
		return index
	return payload


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
