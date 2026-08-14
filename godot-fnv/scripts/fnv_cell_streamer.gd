extends Node3D

signal residency_ready(cell_count: int, terrain_count: int, instance_count: int)
signal portal_transitioned(source_cell: String, destination_cell: String)
signal route_corridor_ready
signal container_activated(container: Node, actor: Node, contents: Array)

const RING_PATH := "res://generated/world/opennv-full-runtime-index.json"
const SEMANTIC_MANIFEST_PATH := "res://generated/semantic-db/manifest.json"
const NAVMESH_INDEX_PATH := "res://generated/world/opennv-navmesh-runtime-index.json"
const ACTOR_PACKAGES_PATH := "res://generated/semantic-db/actor-packages.json"
const ACTOR_BLUEPRINTS_PATH := "res://generated/semantic-db/actor-blueprints.json"
const PACKAGE_NAVIGATION_INDEX_PATH := "res://generated/semantic-db/package-navigation-index.json"
const SCRIPT_VARIABLE_SAVE_STATE_PATH := "res://generated/save330-overlay/script-variable-state.json"
const QUEST_SAVE_STATE_PATH := "res://generated/save330-overlay/quest-state.json"
const ACTOR_MANIFEST_PATH := "res://generated/actors/actor-manifest-skeletal-v8.json"
const CONVERTED_ROOT := "res://generated/assets/converted/"
const SKELETAL_SCENE_CACHE_DIR := "res://local/runtime-cache/skeletal-v1"
const WORLD_MESH_CACHE_DIR := "res://local/runtime-cache/world-mesh-v1"
const WORLD_MESH_CACHE_REPORT := "res://local/runtime-cache/world-mesh-v1-report.json"
const WORLD_MESH_CACHE_PATH_INDEX := "res://local/runtime-cache/world-mesh-v1-path-index.json"
const TERRAIN_MESH_CACHE_DIR := "res://local/runtime-cache/terrain-mesh-v2"
const TERRAIN_MESH_CACHE_REPORT := "res://local/runtime-cache/terrain-mesh-v2-report.json"
const FULL_DETAIL_RADIUS := 4
const DISTANT_TERRAIN_RADIUS := 32
const TERRAIN_VISUAL_RADIUS := 12
const DETAIL_KEEP_RADIUS := 8
const TERRAIN_KEEP_RADIUS := 14
const ACTOR_VISUAL_RADIUS := 2
const ACTOR_KEEP_RADIUS := 3
const INTERIOR_PREFETCH_DISTANCE := 40.0
const INTERIOR_PREFETCH_INTERVAL_MSEC := 250
const INTERIOR_KEEP_COUNT := 8
const DISTANT_CHUNK_CELLS := 8
const UNITS_PER_METER := 70.0
const TERRAIN_DIFFUSE := "res://generated/assets/converted/textures/landscape/dirtwasteland01.dds"
const TERRAIN_NORMAL := "res://generated/assets/converted/textures/landscape/dirtwasteland01_n.dds"
const TERRAIN_ALBEDO_ROOT := "res://generated/assets/converted/terrain-albedo/"
const TERRAIN_ALBEDO_CACHE_LIMIT := 128
const MAX_CONCURRENT_MESH_LOADS := 12
const STREAM_COMMIT_BUDGET_USEC := 2000
const EXTERIOR_SCOPE := "__exterior__"
const ROUTE_PRELOAD_RADIUS := 6
const TERRAIN_COLLISION_RADIUS := 4
const OFFSCREEN_RESTORE_MAX_RETRIES := 3
const OFFSCREEN_RESTORE_RETRY_BASE_MSEC := 250
const OFFSCREEN_SCHEDULE_BATCH := 64
const OFFSCREEN_SCHEDULE_BUDGET_USEC := 500
const PACKAGE_RUNTIME = preload("res://scripts/opennv_package_runtime.gd")
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
var pending_path_priorities: Dictionary = {}
var active_paths: Array[String] = []
var waiting_placements: Dictionary = {}
var ready_placements: Dictionary = {}
var pending_skeletal_placements: Array[Dictionary] = []
var skeletal_cache_requests: Dictionary = {}
var mesh_cache: Dictionary = {}
var mesh_ref_counts: Dictionary = {}
var collision_shape_cache: Dictionary = {}
var terrain_albedo_cache: Dictionary = {}
var terrain_albedo_lru: Array[String] = []
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
var audio_players_by_scope: Dictionary = {}
var active_scope := EXTERIOR_SCOPE
var actor_cache_by_ref: Dictionary = {}
var actor_cache_by_base: Dictionary = {}
var validated_actor_payloads: Dictionary = {}
var actor_visual_status_by_cell: Dictionary = {}
var actor_packages_by_id: Dictionary = {}
var package_navigation_targets: Dictionary = {}
var package_navigation_linked_references: Dictionary = {}
var package_navigation_doors: Dictionary = {}
var package_navigation_cell_edges: Dictionary = {}
var package_route_cache: Dictionary = {}
var navmesh_index_by_cell: Dictionary = {}
var navmesh_external_cell_edges: Dictionary = {}
var navmesh_cell_route_cache: Dictionary = {}
var navigation_regions_by_cell: Dictionary = {}
var navigation_regions_by_scope: Dictionary = {}
var navmesh_runtime_records_by_id: Dictionary = {}
var navmesh_runtime_ids_by_cell: Dictionary = {}
var navmesh_inbound_sources_by_target: Dictionary = {}
var navigation_links_by_key: Dictionary = {}
var navigation_links_by_scope: Dictionary = {}
var pending_navmesh_cell_jobs: Array[Dictionary] = []
var pending_navmesh_cell_ids: Dictionary = {}
var active_navmesh_cell_jobs: Dictionary = {}
var navmesh_worker_results: Dictionary = {}
var navmesh_worker_mutex := Mutex.new()
var pending_navmesh_publish_jobs: Array[Dictionary] = []
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
var interior_prefetch_doors_by_grid: Dictionary = {}
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
var max_focus_update_usec := 0
var focus_update_samples := 0
var max_cell_shard_usec := 0
var max_cell_terrain_usec := 0
var max_cell_placements_usec := 0
var max_cell_navmesh_usec := 0
var max_cell_interior_stage_usec := 0
var max_exterior_cell_commit_usec := 0
var max_skeletal_actor_commit_usec := 0
var max_skeletal_decode_usec := 0
var max_skeletal_animation_usec := 0
var max_skeletal_publish_usec := 0
var max_mesh_install_commit_usec := 0
var max_actor_cell_promotion_usec := 0
var max_navmesh_commit_usec := 0
var max_mesh_duplicate_usec := 0
var max_mesh_material_usec := 0
var max_mesh_collision_split_usec := 0
var max_mesh_placement_publish_usec := 0
var max_terrain_mesh_load_usec := 0
var max_terrain_texture_load_usec := 0
var max_terrain_publish_usec := 0
var max_terrain_collision_usec := 0
var max_focus_prefetch_usec := 0
var max_focus_migrate_usec := 0
var max_focus_actor_evict_usec := 0
var max_focus_world_evict_usec := 0
var stream_status_last_msec := 0
var pending_exterior_cell_jobs: Dictionary = {}
var pending_interior_stage_jobs: Dictionary = {}
var pending_exterior_retire_jobs: Dictionary = {}
var exterior_shard_worker_results: Dictionary = {}
var exterior_shard_worker_mutex := Mutex.new()
var pending_focus_scan_cursor := -1
var pending_focus_scan_grid := Vector2i.ZERO
var pending_focus_scan_world := ""
var pending_focus_scan_origin := Vector3.ZERO
var pending_focus_scan_scope := ""
var special_effect_instances := 0
var authored_marker_instances := 0
var retail_missing_instances := 0
var unsupported_model_counts: Dictionary = {}
var world_mesh_cache_fallback_paths: Dictionary = {}
var world_mesh_cache_contract_checked := false
var world_mesh_cache_contract_valid := false
var world_mesh_cache_source_count := 0
var world_mesh_cache_paths: Dictionary = {}
var terrain_mesh_cache_fallback_paths: Dictionary = {}
var terrain_mesh_cache_contract_checked := false
var terrain_mesh_cache_contract_valid := false
var terrain_mesh_cache_cell_count := 0
var mesh_load_failures := 0
var skeletal_cache_failures := 0
var runtime_condition_context: Dictionary = {}
var runtime_placements_require_atlas := false
var save_enabled_actor_refs: Dictionary = {}
var save_reference_state_by_ref: Dictionary = {}
var applied_save_reference_refs: Dictionary = {}
var reference_runtime_positions: Dictionary = {}
var reference_runtime_cells: Dictionary = {}
var reference_ids_by_cell: Dictionary = {}
var linked_reference_by_ref: Dictionary = {}
var audio_runtime := preload("res://scripts/opennv_audio_runtime.gd").new()
var player_runtime_position := Vector3.ZERO
var package_clock_accumulator := 0.0
var runtime_game_minute := 0.0
var offscreen_schedule_cursor := 0
var actor_migration_accumulator := 0.0
var offscreen_actor_states: Dictionary = {}
var offscreen_actor_refs_by_cell: Dictionary = {}
var pending_offscreen_actor_refs: Dictionary = {}
var pending_actor_refs: Dictionary = {}
var offscreen_actor_restore_retries: Dictionary = {}
var actor_load_quarantined_refs: Dictionary = {}
var pending_actor_cell_promotions: Array[Dictionary] = []
var pending_actor_cell_promotion_ids: Dictionary = {}
var player_portal_generation := 0
var portal_pinned_cells: Dictionary = {}
var actor_lifecycle_counters := {
	"captures": 0,
	"migrations": 0,
	"restore_queue_attempts": 0,
	"restore_successes": 0,
	"restore_failures": 0,
	"restore_retries_scheduled": 0,
	"restore_retries_exhausted": 0,
	"duplicate_suppressions": 0,
}
var offscreen_schedule_counters := {
	"ticks": 0,
	"states_processed": 0,
	"package_changes": 0,
	"patrol_advances": 0,
	"no_selections": 0,
	"unsupported_selections": 0,
	"spatial_updates": 0,
	"max_tick_usec": 0,
}


func _exit_tree() -> void:
	for players_value in audio_players_by_scope.values():
		for player_value in players_value as Array:
			if is_instance_valid(player_value) and player_value is AudioStreamPlayer3D:
				var player := player_value as AudioStreamPlayer3D
				player.stop()
				player.stream = null
	audio_players_by_scope.clear()
	audio_runtime.clear_cache()


func begin(save_manifest: Dictionary) -> void:
	visible = false
	# Decide the loader backend before any startup prefetch can pump requests.
	# Previously this was assigned only after interior prefetch, so headless/XR
	# could inherit the default `true` and strand the first 12 worker requests.
	threaded_loading = (not get_viewport().use_xr and DisplayServer.get_name() != "headless"
		and OS.get_environment("FNV_GODOT_FORCE_SYNC_LOAD") != "1")
	audio_runtime.load_index()
	runtime_condition_context = _build_condition_context(save_manifest)
	runtime_game_minute = float(runtime_condition_context.get("game_hour", 9.0)) * 60.0
	_load_save_actor_overrides(save_manifest)
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
	var ring_schema := str(ring.get("schema", ""))
	var resolved_runtime_ring := ring_schema == "opennv-resolved-runtime-ring/v1"
	var declared_cinematic_pack := (ring_schema == "nikami-fnv-godot-cinematic-scene-pack/v1"
		and OS.get_environment("FNV_GODOT_CINEMATIC_REEL") == "1")
	runtime_placements_require_atlas = resolved_runtime_ring
	if not resolved_runtime_ring and not declared_cinematic_pack:
		push_error("OPENNV_CELL_STREAMER requires the resolved runtime ring or declared cinematic pack")
		residency_ready.emit(0, 0, 0)
		return
	if resolved_runtime_ring and str(ring.get("semantic_manifest_sha256", "")) != FileAccess.get_sha256(SEMANTIC_MANIFEST_PATH):
		push_error("OPENNV_CELL_STREAMER resolved ring is stale")
		residency_ready.emit(0, 0, 0)
		return
	var ring_counts := ring.get("counts", {}) as Dictionary
	if resolved_runtime_ring and (int(ring_counts.get("missingCells", -1)) != 0 or int(ring_counts.get("missingDoorEndpoints", -1)) != 0):
		push_error("OPENNV_CELL_STREAMER resolved ring failed its graph census")
		residency_ready.emit(0, 0, 0)
		return
	if declared_cinematic_pack:
		if int(ring_counts.get("cells", 0)) != (ring.get("cells", []) as Array).size() \
				or int(ring_counts.get("interiors", 0)) != (ring.get("interiors", []) as Array).size() \
				or int(ring_counts.get("placements", 0)) <= 0:
			push_error("OPENNV_CELL_STREAMER cinematic pack failed its content census")
			residency_ready.emit(0, 0, 0)
			return
		print("OPENNV_CINEMATIC_SCENE_PACK_READY cells=%d interiors=%d placements=%d actors=%d" % [
			int(ring_counts.get("cells", 0)), int(ring_counts.get("interiors", 0)),
			int(ring_counts.get("placements", 0)), int(ring_counts.get("actors", 0))])
	else:
		print("OPENNV_RESOLVED_RUNTIME_RING_READY cells=%d interiors=%d placements=%d actors=%d creatures=%d doors=%d" % [
			int(ring_counts.get("exteriorCells", 0)), int(ring_counts.get("interiorCells", 0)),
			int(ring_counts.get("placements", 0)), int(ring_counts.get("actors", 0)),
			int(ring_counts.get("creatures", 0)), int(ring_counts.get("doors", 0))])
	_load_actor_manifest()
	_load_actor_packages()
	_load_package_navigation_index(ring_path)
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
		# The compact cinematic pack predates the sharded runtime index and
		# carries the complete LAND payload instead of its derived index flag.
		# Normalize that one declared compatibility shape before the common
		# neighborhood streamer decides whether terrain should be resident.
		if declared_cinematic_pack and not cell_index.has("has_terrain"):
			cell_index["has_terrain"] = cell_index.has("terrain")
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
		if cell_world_id == primary_world_id or declared_cinematic_pack:
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
	if threaded_loading:
		_pump_threaded_requests()
	set_process(true)


func _queue_placement(source_placement: Dictionary, cell_id: String, cell_origin: Vector3, stage_origin: Vector3, interior: bool, runtime_scope: String = "", stream_priority: int = 0) -> void:
	# Save/quest enable-state overlay is not decoded yet. Honor the authored
	# default rather than spawning known-disabled duplicates such as the inactive
	# Goodsprings Victor reference.
	var authored_ref := _canonical_form_id(source_placement.get("form_id", ""))
	var source := source_placement
	var source_is_actor := str(source_placement.get("base_type", "")) in ["NPC_", "CREA"]
	if source_is_actor and offscreen_actor_states.has(authored_ref):
		var offscreen_state := offscreen_actor_states[authored_ref] as Dictionary
		if _canonical_form_id(offscreen_state.get("cell", "")) != _canonical_form_id(cell_id):
			return
		source = offscreen_state.get("placement", source_placement) as Dictionary
	if source.has("default_enabled") and not bool(source.get("default_enabled", true)) and not save_enabled_actor_refs.has(authored_ref):
		return
	if not _canonical_form_id(source.get("enable_parent", "")).is_empty() \
			and not save_enabled_actor_refs.has(authored_ref):
		return
	var placement := source.duplicate(true)
	_apply_save_reference_override(placement)
	placement["_runtime_stream_priority"] = stream_priority
	placement["_runtime_cell"] = cell_id
	placement["_runtime_origin"] = [cell_origin.x, cell_origin.y, cell_origin.z]
	placement["_runtime_stage"] = [stage_origin.x, stage_origin.y, stage_origin.z]
	placement["_runtime_interior"] = interior
	if not runtime_scope.is_empty():
		placement["_runtime_scope"] = runtime_scope
	if str(placement.get("base_type", "")) in ["NPC_", "CREA"]:
		var live_actor_value: Variant = actor_nodes_by_form_id.get(authored_ref)
		if is_instance_valid(live_actor_value):
			# A scheduled actor may have migrated out of its authored cell. Reloading
			# that home cell must not spawn a duplicate or overwrite its live state.
			return
		elif actor_nodes_by_form_id.has(authored_ref):
			actor_nodes_by_form_id.erase(authored_ref)
		if pending_actor_refs.has(authored_ref):
			actor_lifecycle_counters.duplicate_suppressions += 1
			return
	_index_reference_position(placement)
	if str(placement.get("base_type", "")) == "DOOR":
		var destination_cell := _canonical_form_id(placement.get("destination_cell", ""))
		if interior_names.has(destination_cell):
			var door_ref := _canonical_form_id(placement.get("form_id", ""))
			interior_prefetch_doors[door_ref] = placement
			if not interior:
				var index := cell_indices_by_id.get(cell_id, {}) as Dictionary
				var grid_values := index.get("grid", []) as Array
				if grid_values.size() >= 2:
					var world_id := _canonical_form_id(index.get("world_form_id", primary_world_id))
					var grid_key := _world_grid_key(world_id,
						Vector2i(int(grid_values[0]), int(grid_values[1])))
					if not interior_prefetch_doors_by_grid.has(grid_key):
						interior_prefetch_doors_by_grid[grid_key] = []
					if not (interior_prefetch_doors_by_grid[grid_key] as Array).has(door_ref):
						(interior_prefetch_doors_by_grid[grid_key] as Array).append(door_ref)
	if str(placement.get("base_type", "")) in ["NPC_", "CREA"]:
		_queue_actor_placement(placement)
		return
	# Preserve the exact emitted resource-path spelling. Godot's resource registry
	# is case-sensitive even on Windows, while semantic comparisons are not.
	var model_raw := str(placement.get("model", ""))
	var model := model_raw.to_lower()
	var unsupported_effect := _is_procedural_effect_model(model)
	if str(placement.get("base_type", "")) == "DOOR" and unsupported_effect:
		_add_procedural_effect_gate(placement)
		return
	if _is_invisible_marker_model(model) or (model.is_empty() and not str(placement.get("looping_sound", "")).is_empty()) or (str(placement.get("base_type", "")) == "FURN"
		and not ResourceLoader.exists(_converted_path(model_raw))):
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
	if model.ends_with(".spt"):
		var speedtree_key := "speedtree://" + model
		if not mesh_cache.has(speedtree_key):
			var speedtree_mesh := _speedtree_billboard_mesh(model)
			if speedtree_mesh == null:
				unsupported_model_counts[model] = int(unsupported_model_counts.get(model, 0)) + 1
				return
			mesh_cache[speedtree_key] = speedtree_mesh
		if not ready_placements.has(speedtree_key):
			ready_placements[speedtree_key] = []
		(ready_placements[speedtree_key] as Array).append(placement)
		return
	var path := _converted_path(model_raw)
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
		pending_path_priorities[path] = stream_priority
	else:
		pending_path_priorities[path] = mini(int(pending_path_priorities.get(path, stream_priority)), stream_priority)
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


func _speedtree_billboard_mesh(model: String) -> Mesh:
	# FNV's .spt assets are SpeedTree generator inputs, not render meshes. The
	# shipped archive also carries the exact runtime billboard atlas; use that
	# retail texture for a low-cost crossed-card representation until the full
	# near-field branch generator is promoted.
	if not model.ends_with("wastelandshrub01.spt"):
		return null
	var texture_path := "res://generated/assets/converted/textures/trees/billboards/wastelandshrub01.png"
	if not FileAccess.file_exists(texture_path):
		return null
	var image := Image.load_from_file(ProjectSettings.globalize_path(texture_path))
	if image == null or image.is_empty():
		return null
	var material := StandardMaterial3D.new()
	material.albedo_texture = ImageTexture.create_from_image(image)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.38
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 1.0
	material.metallic = 0.0
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(material)
	var half_width := 72.0
	var height := 118.0
	for axis in range(2):
		var left := Vector3(-half_width, 0.0, 0.0) if axis == 0 else Vector3(0.0, 0.0, -half_width)
		var right := -left
		var vertices := [left, right, right + Vector3.UP * height,
			left, right + Vector3.UP * height, left + Vector3.UP * height]
		var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0),
			Vector2(0, 1), Vector2(1, 0), Vector2(0, 0)]
		for index in range(vertices.size()):
			surface.set_uv(uvs[index])
			surface.set_normal(Vector3.FORWARD if axis == 0 else Vector3.RIGHT)
			surface.add_vertex(vertices[index])
	var result := surface.commit()
	result.set_meta("opennv_has_collision", false)
	result.set_meta("opennv_source_path", model)
	return result


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
	_register_visual(_placement_scope(placement), marker)
	_attach_authored_looping_sound(marker, placement)
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
	_attach_authored_looping_sound(effect, placement)
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
	var animation_path := str(actor_record.get("animation_idle", ""))
	var validation_key := "%s|%s" % [path, animation_path]
	if validated_actor_payloads.has(validation_key):
		return bool(validated_actor_payloads[validation_key])
	var expected := str(actor_record.get("skeletal_sha256", "")).to_lower()
	var valid := (not expected.is_empty() and FileAccess.file_exists(path)
		and FileAccess.get_sha256(path).to_lower() == expected)
	var animation_expected := str(actor_record.get("animation_idle_sha256", "")).to_lower()
	if valid and not animation_path.is_empty():
		valid = (not animation_expected.is_empty() and FileAccess.file_exists(animation_path)
			and FileAccess.get_sha256(animation_path).to_lower() == animation_expected)
	validated_actor_payloads[validation_key] = valid
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


func _load_package_navigation_index(runtime_ring_path: String) -> void:
	package_navigation_targets.clear()
	package_navigation_linked_references.clear()
	package_navigation_doors.clear()
	package_navigation_cell_edges.clear()
	package_route_cache.clear()
	var document := _read_json(PACKAGE_NAVIGATION_INDEX_PATH)
	if str(document.get("schema", "")) != "opennv-package-navigation-index/v1" \
			or str(document.get("semanticContract", "")) != "linked-location-type6-only/v1" \
			or str(document.get("status", "")) != "pass":
		push_error("OPENNV_PACKAGE_NAVIGATION_INDEX schema/status mismatch")
		return
	var provenance := document.get("provenance", {}) as Dictionary
	if str(provenance.get("runtimeIndexSha256", "")).to_lower() != FileAccess.get_sha256(runtime_ring_path).to_lower() \
			or str(provenance.get("packagesSha256", "")).to_lower() != FileAccess.get_sha256(ACTOR_PACKAGES_PATH).to_lower() \
			or str(provenance.get("blueprintsSha256", "")).to_lower() != FileAccess.get_sha256(ACTOR_BLUEPRINTS_PATH).to_lower():
		push_error("OPENNV_PACKAGE_NAVIGATION_INDEX is stale")
		return
	package_navigation_targets = (document.get("targets", {}) as Dictionary).duplicate(true)
	package_navigation_linked_references = (document.get("linkedReferences", {}) as Dictionary).duplicate(true)
	package_navigation_doors = (document.get("doors", {}) as Dictionary).duplicate(true)
	package_navigation_cell_edges = (document.get("cellEdges", {}) as Dictionary).duplicate(true)
	var counts := document.get("counts", {}) as Dictionary
	if int(counts.get("unresolvedPackageReferenceTargets", -1)) != 0 \
			or int(counts.get("missingDoorEndpoints", -1)) != 0 \
			or int(counts.get("missingLinkedReferenceEndpoints", -1)) != 0 \
			or int(counts.get("linkedLocationPackages", -1)) != 296 \
			or int(counts.get("populationLinkedLocationApplications", -1)) != 1696 \
			or int(counts.get("populationLinkedLocationResolvedStarts", -1)) != 546 \
			or int(counts.get("populationLinkedLocationMissingStarts", -1)) != 1150:
		push_error("OPENNV_PACKAGE_NAVIGATION_INDEX coverage mismatch")
		package_navigation_targets.clear()
		package_navigation_linked_references.clear()
		package_navigation_doors.clear()
		package_navigation_cell_edges.clear()
		return
	print("OPENNV_PACKAGE_NAVIGATION_READY doors=%d targets=%d linked=%d" % [
		package_navigation_doors.size(), package_navigation_targets.size(),
		package_navigation_linked_references.size()])


func _load_navmesh_index() -> void:
	navmesh_index_by_cell.clear()
	navmesh_external_cell_edges.clear()
	navmesh_cell_route_cache.clear()
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
	for cell_id_value in (document.get("cell_adjacency", {}) as Dictionary).keys():
		var cell_id := _canonical_form_id(cell_id_value)
		navmesh_external_cell_edges[cell_id] = (
			(document.get("cell_adjacency", {}) as Dictionary)[cell_id_value] as Array).duplicate(true)
	var counts := document.get("counts", {}) as Dictionary
	if navmesh_index_by_cell.size() != int(counts.get("cells", -1)) or int(counts.get("navmeshes", 0)) != 6129:
		push_error("OPENNV_NAVMESH_INDEX census mismatch")
		navmesh_index_by_cell.clear()
		return
	print("OPENNV_NAVMESH_INDEX_READY cells=%d navmeshes=%d triangles=%d" % [
		navmesh_index_by_cell.size(), int(counts.get("navmeshes", 0)), int(counts.get("triangles", 0))])


func _register_navmesh_external_records(cell_id: String, scope: String,
		records: Array[Dictionary]) -> void:
	if not navmesh_runtime_ids_by_cell.has(cell_id):
		navmesh_runtime_ids_by_cell[cell_id] = []
	for record in records:
		var navmesh_id := _canonical_form_id(record.get("id", ""))
		if navmesh_id.is_empty():
			continue
		navmesh_runtime_records_by_id[navmesh_id] = record
		(navmesh_runtime_ids_by_cell[cell_id] as Array).append(navmesh_id)
		for connection_value in record.get("externalConnections", []):
			var target_id := _canonical_form_id((connection_value as Dictionary).get("navmesh", ""))
			if target_id.is_empty():
				continue
			if not navmesh_inbound_sources_by_target.has(target_id):
				navmesh_inbound_sources_by_target[target_id] = []
			var sources := navmesh_inbound_sources_by_target[target_id] as Array
			if not sources.has(navmesh_id):
				sources.append(navmesh_id)
	# Try both directions because some retail NAVMs carry only one side of the
	# external edge record. Spatial keys deduplicate reciprocal declarations.
	for record in records:
		_connect_navmesh_external_record(record, scope)
	# Only revisit authored records that explicitly target one of the newly
	# resident NAVMs. The former full resident-record scan grew O(N^2).
	for record in records:
		var target_id := _canonical_form_id(record.get("id", ""))
		for source_id_value in navmesh_inbound_sources_by_target.get(target_id, []):
			var source_id := _canonical_form_id(source_id_value)
			if source_id == target_id or not navmesh_runtime_records_by_id.has(source_id):
				continue
			var source_record := navmesh_runtime_records_by_id[source_id] as Dictionary
			_connect_navmesh_external_record(source_record, str(source_record.get("scope", scope)))


func _connect_navmesh_external_record(record: Dictionary, scope: String) -> void:
	var source_id := _canonical_form_id(record.get("id", ""))
	var source_cell := _canonical_form_id(record.get("cell", ""))
	for connection_value in record.get("externalConnections", []):
		var connection := connection_value as Dictionary
		var target_id := _canonical_form_id(connection.get("navmesh", ""))
		if target_id.is_empty() or not navmesh_runtime_records_by_id.has(target_id):
			continue
		var target := navmesh_runtime_records_by_id[target_id] as Dictionary
		var target_cell := _canonical_form_id(target.get("cell", ""))
		if target_id == source_id or str(target.get("scope", "")) != scope:
			continue
		var target_center_value: Variant = _navmesh_triangle_centroid(target, int(connection.get("triangle", -1)))
		var repaired_external := bool(connection.get("repaired", false))
		var target_center := Vector3.ZERO
		var source_center := Vector3.ZERO
		if target_center_value is Vector3:
			target_center = target_center_value as Vector3
		else:
			var repaired_pair := _closest_navmesh_centroid_pair(record, target, 12.0)
			if repaired_pair.is_empty():
				continue
			source_center = repaired_pair.get("source", Vector3.ZERO) as Vector3
			target_center = repaired_pair.get("target", Vector3.ZERO) as Vector3
			repaired_external = true
		var source_triangles := record.get("triangles", []) as Array
		var source_triangle := int(connection.get("source_triangle", -1))
		if source_triangle >= 0:
			var authored_source_value: Variant = _navmesh_triangle_centroid(record, source_triangle)
			if authored_source_value is Vector3:
				source_center = authored_source_value as Vector3
		var best_distance := source_center.distance_squared_to(target_center) if source_triangle >= 0 else INF
		if source_triangle < 0:
			for triangle_index in range(source_triangles.size()):
				var candidate_value: Variant = _navmesh_triangle_centroid(record, triangle_index)
				if not candidate_value is Vector3:
					continue
				var candidate := candidate_value as Vector3
				var distance := candidate.distance_squared_to(target_center)
				if distance < best_distance:
					best_distance = distance
					source_center = candidate
		if not is_finite(best_distance) or sqrt(best_distance) > 12.0:
			continue
		var midpoint := (source_center + target_center) * 0.5
		var pair_ids := [source_id, target_id]
		pair_ids.sort()
		var link_key := "%s|%s|%d,%d,%d" % [pair_ids[0], pair_ids[1],
			roundi(midpoint.x * 10.0), roundi(midpoint.y * 10.0), roundi(midpoint.z * 10.0)]
		if navigation_links_by_key.has(link_key):
			if repaired_external:
				var existing_link := navigation_links_by_key[link_key] as NavigationLink3D
				if is_instance_valid(existing_link):
					existing_link.set_meta("opennv_repaired_external", true)
			continue
		var link := NavigationLink3D.new()
		link.name = "NAVLINK_%s" % link_key.replace("|", "_").replace(",", "_")
		link.bidirectional = true
		link.start_position = source_center
		link.end_position = target_center
		link.enabled = scope == active_scope
		link.set_meta("opennv_source_cell", source_cell)
		link.set_meta("opennv_destination_cell", target_cell)
		link.set_meta("opennv_repaired_external", repaired_external)
		add_child(link)
		navigation_links_by_key[link_key] = link
		if not navigation_links_by_scope.has(scope):
			navigation_links_by_scope[scope] = []
		(navigation_links_by_scope[scope] as Array).append(link)


func _closest_navmesh_centroid_pair(source: Dictionary, target: Dictionary,
		maximum_distance: float) -> Dictionary:
	var best_distance_squared := maximum_distance * maximum_distance
	var best_pair: Dictionary = {}
	var source_triangles := source.get("triangles", []) as Array
	var target_triangles := target.get("triangles", []) as Array
	for source_index in range(source_triangles.size()):
		var source_value: Variant = _navmesh_triangle_centroid(source, source_index)
		if not source_value is Vector3:
			continue
		var source_center := source_value as Vector3
		for target_index in range(target_triangles.size()):
			var target_value: Variant = _navmesh_triangle_centroid(target, target_index)
			if not target_value is Vector3:
				continue
			var target_center := target_value as Vector3
			var distance_squared := source_center.distance_squared_to(target_center)
			if distance_squared <= best_distance_squared:
				best_distance_squared = distance_squared
				best_pair = {"source": source_center, "target": target_center}
	return best_pair


func _navmesh_triangle_centroid(record: Dictionary, triangle_index: int) -> Variant:
	var triangles := record.get("triangles", []) as Array
	var vertices := record.get("vertices", PackedVector3Array()) as PackedVector3Array
	if triangle_index < 0 or triangle_index >= triangles.size():
		return null
	var triangle := triangles[triangle_index] as PackedInt32Array
	if triangle.size() != 3 or triangle[0] >= vertices.size() or triangle[1] >= vertices.size() or triangle[2] >= vertices.size():
		return null
	return (vertices[triangle[0]] + vertices[triangle[1]] + vertices[triangle[2]]) / 3.0


func _load_navmesh_cell(cell_id_value: String, source_cell_origin: Vector3, stage_origin: Vector3, scope: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	if navigation_regions_by_cell.has(cell_id) or pending_navmesh_cell_ids.has(cell_id) \
			or not navmesh_index_by_cell.has(cell_id):
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
	var cell_index := cell_indices_by_id.get(cell_id, {}) as Dictionary
	var translation_values := cell_index.get("atlas_translation_units", [0.0, 0.0, 0.0]) as Array
	var job := {
		"cell": cell_id, "scope": scope, "shard": shard_path,
		"sha256": str(index.get("sha256", "")).to_lower(),
		"navmeshes": int(index.get("navmeshes", 0)),
		"source_origin": source_cell_origin, "stage_origin": stage_origin,
		"atlas_rotation": float(cell_index.get("atlas_rotation_radians", 0.0)),
		"atlas_translation": Vector3(float(translation_values[0]),
			float(translation_values[1]), float(translation_values[2])),
	}
	pending_navmesh_cell_ids[cell_id] = true
	pending_navmesh_cell_jobs.append(job)
	set_process(true)


func _pump_navmesh_stream_jobs() -> bool:
	if not pending_navmesh_publish_jobs.is_empty():
		_advance_navmesh_publish_job()
		return true
	while active_navmesh_cell_jobs.size() < 2 and not pending_navmesh_cell_jobs.is_empty():
		var job := pending_navmesh_cell_jobs.pop_front() as Dictionary
		var cell_id := _canonical_form_id(job.get("cell", ""))
		job["task"] = WorkerThreadPool.add_task(_prepare_navmesh_cell_worker.bind(job.duplicate(true)),
			true, "OpenNV NAVM %s" % cell_id)
		active_navmesh_cell_jobs[cell_id] = job
	var completed_cell := ""
	for cell_id_value in active_navmesh_cell_jobs.keys():
		var job := active_navmesh_cell_jobs[cell_id_value] as Dictionary
		if WorkerThreadPool.is_task_completed(int(job.get("task", -1))):
			completed_cell = str(cell_id_value)
			break
	if completed_cell.is_empty():
		return false
	var completed_job := active_navmesh_cell_jobs[completed_cell] as Dictionary
	WorkerThreadPool.wait_for_task_completion(int(completed_job.get("task", -1)))
	navmesh_worker_mutex.lock()
	var prepared_value: Variant = navmesh_worker_results.get(completed_cell, {})
	navmesh_worker_results.erase(completed_cell)
	navmesh_worker_mutex.unlock()
	active_navmesh_cell_jobs.erase(completed_cell)
	var prepared := (prepared_value as Dictionary) if prepared_value is Dictionary else {}
	var scope := str(completed_job.get("scope", ""))
	var still_resident := (loaded_actor_cells.has(completed_cell) if _scope_is_exterior(scope)
		else staged_interiors.has(completed_cell))
	if still_resident:
		var commit_started := Time.get_ticks_usec()
		_begin_navmesh_publish_job(prepared)
		var elapsed := Time.get_ticks_usec() - commit_started
		max_navmesh_commit_usec = maxi(max_navmesh_commit_usec, elapsed)
		max_stream_commit_usec = maxi(max_stream_commit_usec, elapsed)
		stream_commit_samples += 1
	else:
		pending_navmesh_cell_ids.erase(completed_cell)
	return true


func _begin_navmesh_publish_job(prepared: Dictionary) -> void:
	var cell_id := _canonical_form_id(prepared.get("cell", ""))
	var vertices := prepared.get("vertices", PackedVector3Array()) as PackedVector3Array
	var polygons := prepared.get("polygons", []) as Array
	if not str(prepared.get("error", "")).is_empty() or vertices.is_empty() or polygons.is_empty():
		push_warning("OPENNV_NAVMESH_PREPARE_FAILED cell=%s error=%s" % [cell_id,
			str(prepared.get("error", "empty"))])
		pending_navmesh_cell_ids.erase(cell_id)
		return
	var navigation_mesh := NavigationMesh.new()
	navigation_mesh.set_vertices(vertices)
	prepared["_navigation_mesh"] = navigation_mesh
	prepared["_polygon_cursor"] = 0
	pending_navmesh_publish_jobs.append(prepared)


func _advance_navmesh_publish_job() -> void:
	var prepared := pending_navmesh_publish_jobs[0] as Dictionary
	var polygons := prepared.get("polygons", []) as Array
	var cursor := int(prepared.get("_polygon_cursor", 0))
	var navigation_mesh := prepared.get("_navigation_mesh") as NavigationMesh
	var started := Time.get_ticks_usec()
	while cursor < polygons.size() and Time.get_ticks_usec() - started < 1000:
		navigation_mesh.add_polygon(polygons[cursor] as PackedInt32Array)
		cursor += 1
	prepared["_polygon_cursor"] = cursor
	if cursor >= polygons.size():
		pending_navmesh_publish_jobs.pop_front()
		_commit_prepared_navmesh_cell(prepared, navigation_mesh)
		pending_navmesh_cell_ids.erase(_canonical_form_id(prepared.get("cell", "")))
	var elapsed := Time.get_ticks_usec() - started
	max_navmesh_commit_usec = maxi(max_navmesh_commit_usec, elapsed)
	max_stream_commit_usec = maxi(max_stream_commit_usec, elapsed)
	stream_commit_samples += 1


func _prepare_navmesh_cell_worker(job: Dictionary) -> void:
	var cell_id := str(job.get("cell", ""))
	var shard_path := str(job.get("shard", ""))
	var result: Dictionary = {"cell": cell_id, "error": "invalid-shard"}
	var expected_hash := str(job.get("sha256", "")).to_lower()
	if not expected_hash.is_empty() and FileAccess.file_exists(shard_path) \
			and FileAccess.get_sha256(shard_path).to_lower() == expected_hash:
		var payload := _read_json(shard_path)
		if str(payload.get("schema", "")) == "opennv-navmesh-cell-shard/v1" \
				and _canonical_form_id(payload.get("cell", "")) == cell_id:
			var vertices := PackedVector3Array()
			var polygons: Array[PackedInt32Array] = []
			var runtime_records: Array[Dictionary] = []
			var rotation := float(job.get("atlas_rotation", 0.0))
			var translation := job.get("atlas_translation", Vector3.ZERO) as Vector3
			var source_origin := job.get("source_origin", Vector3.ZERO) as Vector3
			var stage_origin := job.get("stage_origin", Vector3.ZERO) as Vector3
			var cosine := cos(rotation)
			var sine := sin(rotation)
			for navmesh_value in payload.get("navmeshes", []):
				var navmesh := navmesh_value as Dictionary
				var vertex_base := vertices.size()
				var nav_vertices := PackedVector3Array()
				for vertex_value in navmesh.get("vertices", []):
					var source_vertex := _array_to_vector3(vertex_value)
					if not is_zero_approx(rotation) or translation != Vector3.ZERO:
						source_vertex = Vector3(cosine * source_vertex.x - sine * source_vertex.y,
							sine * source_vertex.x + cosine * source_vertex.y, source_vertex.z) + translation
					var offset := source_vertex - source_origin
					var runtime_vertex := stage_origin + Vector3(offset.x, offset.z, -offset.y) / UNITS_PER_METER
					vertices.append(runtime_vertex)
					nav_vertices.append(runtime_vertex)
				var nav_triangles: Array[PackedInt32Array] = []
				for triangle_value in navmesh.get("triangles", []):
					var triangle := triangle_value as Array
					if triangle.size() != 3:
						continue
					var local_triangle := PackedInt32Array([int(triangle[0]), int(triangle[1]), int(triangle[2])])
					nav_triangles.append(local_triangle)
					polygons.append(PackedInt32Array([vertex_base + local_triangle[0],
						vertex_base + local_triangle[1], vertex_base + local_triangle[2]]))
				runtime_records.append({
					"id": _canonical_form_id(navmesh.get("id", "")), "cell": cell_id,
					"scope": str(job.get("scope", "")), "vertices": nav_vertices,
					"triangles": nav_triangles,
					"externalConnections": (navmesh.get("external_connections", []) as Array).duplicate(true),
				})
			result = {"cell": cell_id, "scope": str(job.get("scope", "")),
				"navmeshes": int(job.get("navmeshes", 0)), "vertices": vertices,
				"polygons": polygons, "records": runtime_records, "error": ""}
	navmesh_worker_mutex.lock()
	navmesh_worker_results[cell_id] = result
	navmesh_worker_mutex.unlock()


func _commit_prepared_navmesh_cell(prepared: Dictionary,
		navigation_mesh_override: NavigationMesh = null) -> void:
	var cell_id := _canonical_form_id(prepared.get("cell", ""))
	var scope := str(prepared.get("scope", ""))
	var vertices := prepared.get("vertices", PackedVector3Array()) as PackedVector3Array
	var polygons := prepared.get("polygons", []) as Array
	var runtime_records: Array[Dictionary] = []
	for record_value in prepared.get("records", []):
		runtime_records.append(record_value as Dictionary)
	if not str(prepared.get("error", "")).is_empty() or vertices.is_empty() or polygons.is_empty():
		push_warning("OPENNV_NAVMESH_PREPARE_FAILED cell=%s error=%s" % [cell_id,
			str(prepared.get("error", "empty"))])
		return
	if navigation_regions_by_cell.has(cell_id):
		return
	var navigation_mesh := navigation_mesh_override
	if navigation_mesh == null:
		navigation_mesh = NavigationMesh.new()
		navigation_mesh.set_vertices(vertices)
		for polygon_value in polygons:
			navigation_mesh.add_polygon(polygon_value as PackedInt32Array)
	var region := NavigationRegion3D.new()
	region.name = "NAVM_%s" % cell_id
	region.navigation_mesh = navigation_mesh
	region.enabled = scope == active_scope
	region.use_edge_connections = true
	region.set_meta("opennv_navmesh_cell", cell_id)
	region.set_meta("opennv_navmesh_count", int(prepared.get("navmeshes", 0)))
	add_child(region)
	navigation_regions_by_cell[cell_id] = region
	if not navigation_regions_by_scope.has(scope):
		navigation_regions_by_scope[scope] = []
	(navigation_regions_by_scope[scope] as Array).append(region)
	resident_navmesh_cells += 1
	_register_navmesh_external_records(cell_id, scope, runtime_records)


func _retire_navmesh_cell(cell_id_value: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	if not navigation_regions_by_cell.has(cell_id):
		return
	var region := navigation_regions_by_cell[cell_id] as NavigationRegion3D
	for link_key_value in navigation_links_by_key.keys():
		var link := navigation_links_by_key[link_key_value] as NavigationLink3D
		if not is_instance_valid(link):
			navigation_links_by_key.erase(link_key_value)
			continue
		if _canonical_form_id(link.get_meta("opennv_source_cell", "")) == cell_id \
				or _canonical_form_id(link.get_meta("opennv_destination_cell", "")) == cell_id:
			for links_value in navigation_links_by_scope.values():
				(links_value as Array).erase(link)
			link.queue_free()
			navigation_links_by_key.erase(link_key_value)
	for navmesh_id_value in navmesh_runtime_ids_by_cell.get(cell_id, []):
		navmesh_runtime_records_by_id.erase(_canonical_form_id(navmesh_id_value))
	navmesh_runtime_ids_by_cell.erase(cell_id)
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
	result["game_minute"] = runtime_game_minute
	result["actor_ref"] = _canonical_form_id(placement.get("form_id", ""))
	result["actor_base"] = _canonical_form_id(placement.get("base_form_id", placement.get("base_form", placement.get("base", ""))))
	result["actor_cell"] = _canonical_form_id(placement.get("_runtime_cell", ""))
	result["actor_interior"] = bool(placement.get("_runtime_interior", false))
	result["actor_scope"] = _placement_scope(placement)
	result["restoring_offscreen"] = placement.has("_runtime_offscreen_ref")
	result["actor_is_creature"] = "creature" in category
	var cell_index := cell_indices_by_id.get(result["actor_cell"], {}) as Dictionary
	result["actor_world"] = "" if bool(result["actor_interior"]) else _canonical_form_id(cell_index.get("world_form_id", primary_world_id))
	result["random_percent"] = float(abs(str(result["actor_ref"]).hash()) % 100)
	result["reference_position_resolver"] = Callable(self, "_runtime_reference_position")
	result["reference_cell_resolver"] = Callable(self, "_runtime_reference_cell")
	result["reference_scope_resolver"] = Callable(self, "_runtime_reference_scope")
	result["reference_link_resolver"] = Callable(self, "_runtime_reference_link")
	result["package_route_resolver"] = Callable(self, "_package_route_step")
	result["package_door_activator"] = Callable(self, "_activate_package_door")
	result["actor_linked_reference"] = _canonical_form_id(placement.get("linked_reference", ""))
	result["actor_position"] = _placement_transform(placement).origin
	return result


func _index_reference_position(placement: Dictionary) -> void:
	var ref_id := _canonical_form_id(placement.get("form_id", ""))
	var cell_id := _canonical_form_id(placement.get("_runtime_cell", ""))
	if ref_id.is_empty() or cell_id.is_empty():
		return
	reference_runtime_positions[ref_id] = _placement_transform(placement).origin
	reference_runtime_cells[ref_id] = cell_id
	var linked_ref := _canonical_form_id(placement.get("linked_reference", ""))
	if not linked_ref.is_empty():
		linked_reference_by_ref[ref_id] = linked_ref
	if not reference_ids_by_cell.has(cell_id):
		reference_ids_by_cell[cell_id] = []
	var refs := reference_ids_by_cell[cell_id] as Array
	if not refs.has(ref_id):
		refs.append(ref_id)


func _drop_cell_reference_positions(cell_id_value: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	for ref_id_value in reference_ids_by_cell.get(cell_id, []):
		var ref_id := str(ref_id_value)
		reference_runtime_positions.erase(ref_id)
		reference_runtime_cells.erase(ref_id)
		linked_reference_by_ref.erase(ref_id)
	reference_ids_by_cell.erase(cell_id)


func _runtime_reference_position(ref_id_value: Variant) -> Variant:
	var ref_id := _canonical_form_id(ref_id_value)
	if ref_id == "0x00000014":
		return player_runtime_position
	var static_reference := _navigation_reference_row(ref_id)
	if not static_reference.is_empty() \
			and not _package_navigation_target_available(ref_id, static_reference):
		return null
	var live_actor := actor_nodes_by_form_id.get(ref_id) as Node3D
	if is_instance_valid(live_actor):
		return live_actor.global_position
	if offscreen_actor_states.has(ref_id):
		return (offscreen_actor_states[ref_id] as Dictionary).get("position", null)
	if reference_runtime_positions.has(ref_id):
		return reference_runtime_positions[ref_id]
	return _navigation_reference_position(ref_id, static_reference)


func _runtime_reference_cell(ref_id_value: Variant) -> Variant:
	var ref_id := _canonical_form_id(ref_id_value)
	if ref_id == "0x00000014":
		if not _scope_is_exterior(active_scope):
			return active_scope
		var world_origin := _world_runtime_origin(active_exterior_world_id)
		var atlas_position := world_origin + _godot_vector_to_source(player_runtime_position * UNITS_PER_METER)
		var grid := Vector2i(floori(atlas_position.x / 4096.0), floori(atlas_position.y / 4096.0))
		for candidate_value in cell_indices_by_grid.get(_world_grid_key(active_exterior_world_id, grid), []):
			var candidate := candidate_value as Dictionary
			if _canonical_form_id(candidate.get("world_form_id", "")) == active_exterior_world_id:
				return _canonical_form_id(candidate.get("form_id", ""))
		return null
	var static_reference := _navigation_reference_row(ref_id)
	if not static_reference.is_empty() \
			and not _package_navigation_target_available(ref_id, static_reference):
		return null
	if offscreen_actor_states.has(ref_id):
		return (offscreen_actor_states[ref_id] as Dictionary).get("cell", null)
	if reference_runtime_cells.has(ref_id):
		return reference_runtime_cells[ref_id]
	if not static_reference.is_empty():
		return _canonical_form_id(static_reference.get("cell", ""))
	return null


func _runtime_reference_link(ref_id_value: Variant) -> String:
	var ref_id := _canonical_form_id(ref_id_value)
	if offscreen_actor_states.has(ref_id):
		var placement := (offscreen_actor_states[ref_id] as Dictionary).get("placement", {}) as Dictionary
		return _canonical_form_id(placement.get("linked_reference", ""))
	if linked_reference_by_ref.has(ref_id):
		return _canonical_form_id(linked_reference_by_ref[ref_id])
	var static_reference := _navigation_reference_row(ref_id)
	if static_reference.is_empty() \
			or not _package_navigation_target_available(ref_id, static_reference):
		return ""
	return _canonical_form_id(static_reference.get("linkedReference", ""))


func _runtime_reference_scope(ref_id_value: Variant) -> String:
	var ref_id := _canonical_form_id(ref_id_value)
	if ref_id == "0x00000014":
		return active_scope
	var static_reference := _navigation_reference_row(ref_id)
	if not static_reference.is_empty() \
			and not _package_navigation_target_available(ref_id, static_reference):
		return ""
	var actor := actor_nodes_by_form_id.get(ref_id) as Node
	if is_instance_valid(actor):
		return str(actor.get_meta("opennv_runtime_scope", ""))
	if offscreen_actor_states.has(ref_id):
		var placement := (offscreen_actor_states[ref_id] as Dictionary).get("placement", {}) as Dictionary
		return str(placement.get("_runtime_scope", ""))
	var cell_id := _canonical_form_id(reference_runtime_cells.get(ref_id, ""))
	if cell_id.is_empty() and not static_reference.is_empty():
		cell_id = _canonical_form_id(static_reference.get("cell", ""))
	if interior_names.has(cell_id):
		return cell_id
	if exterior_scope_by_cell.has(cell_id):
		return str(exterior_scope_by_cell[cell_id])
	if cell_indices_by_id.has(cell_id):
		var cell_index := cell_indices_by_id[cell_id] as Dictionary
		return _world_scope(_canonical_form_id(cell_index.get("world_form_id", "")))
	return ""


func _package_navigation_target_position(ref_id_value: String) -> Variant:
	var ref_id := _canonical_form_id(ref_id_value)
	if not package_navigation_targets.has(ref_id):
		return null
	var target := package_navigation_targets[ref_id] as Dictionary
	if not _package_navigation_target_available(ref_id, target):
		return null
	return _navigation_reference_position(ref_id, target)


func _navigation_reference_row(ref_id_value: Variant) -> Dictionary:
	var ref_id := _canonical_form_id(ref_id_value)
	if package_navigation_targets.has(ref_id):
		return package_navigation_targets[ref_id] as Dictionary
	if package_navigation_linked_references.has(ref_id):
		return package_navigation_linked_references[ref_id] as Dictionary
	return {}


func _navigation_reference_position(ref_id: String, target: Dictionary) -> Variant:
	if target.is_empty() or not _package_navigation_target_available(ref_id, target):
		return null
	var cell_id := _canonical_form_id(target.get("cell", ""))
	var source_position := _array_to_vector3(target.get("position", []))
	if interior_names.has(cell_id):
		if not interior_source_origins.has(cell_id) or not interior_stage_origins.has(cell_id):
			return null
		return (interior_stage_origins[cell_id] as Vector3
			+ _source_vector_to_godot(source_position - (interior_source_origins[cell_id] as Vector3)) / UNITS_PER_METER)
	if not cell_indices_by_id.has(cell_id):
		return null
	var cell_index := cell_indices_by_id[cell_id] as Dictionary
	var world_id := _canonical_form_id(cell_index.get("world_form_id", ""))
	var runtime_origin := _world_runtime_origin(world_id)
	var atlas_position := _atlas_transform_source_position(source_position, cell_id)
	return _source_vector_to_godot(atlas_position - runtime_origin) / UNITS_PER_METER


func _package_navigation_target_available(ref_id: String, target: Dictionary) -> bool:
	if save_enabled_actor_refs.has(ref_id):
		return true
	return bool(target.get("defaultEnabled", true)) \
		and _canonical_form_id(target.get("enableParent", "")).is_empty()


func _package_navigation_door_position(door_id_value: String) -> Variant:
	var door_id := _canonical_form_id(door_id_value)
	if reference_runtime_positions.has(door_id):
		return reference_runtime_positions[door_id]
	if not package_navigation_doors.has(door_id):
		return null
	var row := package_navigation_doors[door_id] as Dictionary
	var synthetic_target := {
		"cell": row.get("sourceCell", ""),
		"position": row.get("position", []),
	}
	package_navigation_targets[door_id] = synthetic_target
	var result: Variant = _package_navigation_target_position(door_id)
	package_navigation_targets.erase(door_id)
	return result


func _package_route_step(source_cell_value: String, destination_cell_value: String) -> Dictionary:
	var source_cell := _canonical_form_id(source_cell_value)
	var destination_cell := _canonical_form_id(destination_cell_value)
	if source_cell.is_empty() or destination_cell.is_empty() or source_cell == destination_cell:
		return {}
	var source_exterior := cell_indices_by_id.get(source_cell, {}) as Dictionary
	var destination_exterior := cell_indices_by_id.get(destination_cell, {}) as Dictionary
	if not source_exterior.is_empty() and not destination_exterior.is_empty():
		var source_world := _canonical_form_id(source_exterior.get("world_form_id", ""))
		if source_world == _canonical_form_id(destination_exterior.get("world_form_id", "")):
			return _package_exterior_corridor_step(source_cell, destination_cell, 0.0)
	var cache_key := "%s|%s" % [source_cell, destination_cell]
	if package_route_cache.has(cache_key):
		var cached_door := str(package_route_cache[cache_key])
		if cached_door.is_empty():
			return {}
		var cached_position: Variant = _package_navigation_door_position(cached_door)
		return {"door": cached_door, "position": cached_position, "destinationCell": destination_cell} \
			if cached_position is Vector3 else {}
	var first_door := _package_door_path(source_cell, destination_cell)
	var selected_entrance_cell := source_cell
	if first_door.is_empty() and not interior_names.has(source_cell) and cell_indices_by_id.has(source_cell):
		var source_index := cell_indices_by_id[source_cell] as Dictionary
		var source_world := _canonical_form_id(source_index.get("world_form_id", ""))
		var source_grid_values := source_index.get("grid", []) as Array
		var best_distance := 2147483647
		for entrance_cell_value in package_navigation_cell_edges.keys():
			var entrance_cell := _canonical_form_id(entrance_cell_value)
			if interior_names.has(entrance_cell) or not cell_indices_by_id.has(entrance_cell):
				continue
			var entrance_index := cell_indices_by_id[entrance_cell] as Dictionary
			if _canonical_form_id(entrance_index.get("world_form_id", "")) != source_world:
				continue
			var candidate_door := _package_door_path(entrance_cell, destination_cell)
			if candidate_door.is_empty():
				continue
			var entrance_grid_values := entrance_index.get("grid", []) as Array
			if source_grid_values.size() < 2 or entrance_grid_values.size() < 2:
				continue
			var distance := maxi(absi(int(source_grid_values[0]) - int(entrance_grid_values[0])),
				absi(int(source_grid_values[1]) - int(entrance_grid_values[1])))
			if distance < best_distance:
				best_distance = distance
				first_door = candidate_door
				selected_entrance_cell = entrance_cell
	if first_door.is_empty():
		package_route_cache[cache_key] = ""
		return {}
	var position: Variant = _package_navigation_door_position(first_door)
	if not position is Vector3:
		package_route_cache[cache_key] = ""
		return {}
	if selected_entrance_cell != source_cell:
		var corridor_step := _package_exterior_corridor_step(source_cell, selected_entrance_cell,
			(position as Vector3).y)
		if not corridor_step.is_empty():
			return corridor_step
		return {}
	package_route_cache[cache_key] = first_door
	return {"door": first_door, "position": position, "destinationCell": destination_cell}


func _package_exterior_corridor_step(source_cell: String, entrance_cell: String,
		_target_height: float) -> Dictionary:
	var source_index := cell_indices_by_id.get(source_cell, {}) as Dictionary
	if source_index.is_empty():
		return {}
	var world_id := _canonical_form_id(source_index.get("world_form_id", ""))
	var first_edge := _navmesh_cell_path_first_edge(source_cell, entrance_cell, world_id)
	if first_edge.is_empty():
		return {}
	var next_cell := _canonical_form_id(first_edge.get("cell", ""))
	_queue_actor_cell_promotion(next_cell, world_id)
	var runtime_position := _runtime_position_in_cell(
		_array_to_vector3(first_edge.get("targetPosition", [])), next_cell)
	return {"door": "", "position": runtime_position, "corridor": true,
		"corridorCell": next_cell, "destinationCell": entrance_cell}


func _navmesh_cell_path_first_edge(source_cell: String, destination_cell: String,
		world_id: String) -> Dictionary:
	var cache_key := "%s|%s|%s" % [world_id, source_cell, destination_cell]
	if navmesh_cell_route_cache.has(cache_key):
		return (navmesh_cell_route_cache[cache_key] as Dictionary).duplicate(true)
	var frontier: Array[String] = [source_cell]
	var visited := {source_cell: true}
	var first_edge_by_cell: Dictionary = {}
	while not frontier.is_empty():
		var cell_id: String = frontier.pop_front()
		for edge_value in navmesh_external_cell_edges.get(cell_id, []):
			var edge := edge_value as Dictionary
			var next_cell := _canonical_form_id(edge.get("cell", ""))
			if next_cell.is_empty() or visited.has(next_cell):
				continue
			var next_index := cell_indices_by_id.get(next_cell, {}) as Dictionary
			if _canonical_form_id(next_index.get("world_form_id", "")) != world_id:
				continue
			var first_edge := edge if cell_id == source_cell else first_edge_by_cell.get(cell_id, {}) as Dictionary
			first_edge_by_cell[next_cell] = first_edge
			if next_cell == destination_cell:
				navmesh_cell_route_cache[cache_key] = first_edge.duplicate(true)
				return first_edge
			visited[next_cell] = true
			frontier.append(next_cell)
	return {}


func _package_door_path(source_cell: String, destination_cell: String) -> String:
	var frontier: Array[String] = [source_cell]
	var visited := {source_cell: true}
	var first_door_by_cell: Dictionary = {}
	while not frontier.is_empty():
		var cell_id: String = frontier.pop_front()
		for door_value in package_navigation_cell_edges.get(cell_id, []):
			var door_id := _canonical_form_id(door_value)
			if not package_navigation_doors.has(door_id):
				continue
			var row := package_navigation_doors[door_id] as Dictionary
			if (not bool(row.get("defaultEnabled", true)) or bool(row.get("locked", false))
					or int(row.get("lockLevel", 0)) > 0
					or not _canonical_form_id(row.get("enableParent", "")).is_empty()):
				continue
			var next_cell := _canonical_form_id(row.get("destinationCell", ""))
			if next_cell.is_empty() or visited.has(next_cell):
				continue
			var first_door := door_id if cell_id == source_cell else str(first_door_by_cell.get(cell_id, ""))
			first_door_by_cell[next_cell] = first_door
			if next_cell == destination_cell:
				return first_door
			visited[next_cell] = true
			frontier.append(next_cell)
	return ""


func _activate_package_door(actor: Node3D, door_id_value: String) -> bool:
	var door_id := _canonical_form_id(door_id_value)
	var door := door_nodes_by_form_id.get(door_id) as Node
	if not is_instance_valid(door):
		if package_navigation_doors.has(door_id):
			var indexed_door := package_navigation_doors[door_id] as Dictionary
			var source_cell := _canonical_form_id(indexed_door.get("sourceCell", ""))
			if _canonical_form_id(actor.get_meta("opennv_runtime_cell", "")) == source_cell \
					and not interior_names.has(source_cell):
				_load_exterior_destination(source_cell)
				_flush_ready_placements()
				set_process(true)
				if threaded_loading:
					_pump_threaded_requests()
		return false
	if not door.has_method("activate"):
		return false
	var actor_cell := _canonical_form_id(actor.get_meta("opennv_runtime_cell", ""))
	var door_cell := _canonical_form_id(door.get_meta("fnv_cell", ""))
	if actor.has_meta("fnv_actor_id") and (actor_cell.is_empty() or door_cell.is_empty() or actor_cell != door_cell):
		return false
	if package_navigation_doors.has(door_id):
		var indexed_source := _canonical_form_id((package_navigation_doors[door_id] as Dictionary).get("sourceCell", ""))
		if not indexed_source.is_empty() and indexed_source != door_cell:
			return false
	return bool(door.call("activate", actor))


func _build_condition_context(save_manifest: Dictionary) -> Dictionary:
	var globals: Dictionary = {}
	for global_value in save_manifest.get("globals", []):
		var global := global_value as Dictionary
		var form_id := _canonical_form_id(global.get("formId", ""))
		var wrapped: Variant = global.get("value", 0.0)
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
		"script_variables": {},
		"quest_completed": {},
		"objective_completed": {},
		"objective_displayed": {},
		"dead_counts": {},
	}


func _load_save_actor_overrides(save_manifest: Dictionary) -> void:
	save_enabled_actor_refs.clear()
	save_reference_state_by_ref.clear()
	applied_save_reference_refs.clear()
	var overlay := save_manifest.get("_save_actor_overlay", {}) as Dictionary
	if str(overlay.get("schema", "")) != "opennv-fos-changeform-index/v1":
		return
	var save := save_manifest.get("save", {}) as Dictionary
	if str((overlay.get("source", {}) as Dictionary).get("sha256", "")).to_lower() != str(save.get("sha256", "")).to_lower():
		return
	var script_variables := runtime_condition_context.get("script_variables", {}) as Dictionary
	var promoted_script_values := 0
	var script_save_state := _read_json(SCRIPT_VARIABLE_SAVE_STATE_PATH)
	if str(script_save_state.get("schema", "")) == "opennv-script-variable-save-state/v1" and str(script_save_state.get("status", "")) == "pass":
		var provenance := script_save_state.get("provenance", {}) as Dictionary
		if str(provenance.get("saveSha256", "")).to_lower() == str(save.get("sha256", "")).to_lower():
			for state_value in (script_save_state.get("values", {}) as Dictionary).values():
				var state := state_value as Dictionary
				var state_ref := _canonical_form_id(state.get("reference", ""))
				var state_index := int(state.get("index", -1))
				if not state_ref.is_empty() and state_index >= 0:
					script_variables["%s:%d" % [state_ref, state_index]] = float(state.get("value", 0.0))
					promoted_script_values += 1
	# The change-form decoder promotes only the fixed initial-data prefix whose
	# byte layout is validated independently. Retain every resolved transform
	# override, including the player, actors, creatures and movable references.
	# Other payload bytes remain opaque and are never guessed here.
	for entry_value in overlay.get("changeForms", []):
		var entry := entry_value as Dictionary
		var ref_id := _canonical_form_id((entry.get("refId", {}) as Dictionary).get("resolvedFormId", ""))
		var initial_value: Variant = entry.get("initialState", null)
		var initial_state := initial_value as Dictionary if initial_value is Dictionary else {}
		if not ref_id.is_empty() and str(initial_state.get("kind", "")) in ["moved", "cellChanged", "created"]:
			var position_values := initial_state.get("position", []) as Array
			if position_values.size() >= 3 and _valid_save_vector(position_values):
				var target := initial_state.get("newCellOrWorldspace", initial_state.get("cellOrWorldspace", {})) as Dictionary
				save_reference_state_by_ref[ref_id] = {
					"kind": str(initial_state.get("kind", "")),
					"position": position_values.duplicate(),
					"rotation_radians": (initial_state.get("rotationRadians", []) as Array).duplicate(),
					"target_cell_or_worldspace": _canonical_form_id(target.get("resolvedFormId", "")),
					"type": str(entry.get("type", "")),
				}
		# Save330's two live saloon actors (Joe Cobb and Trudy) share this exact
		# ChangedActor signature. Other initially-disabled refs carry different
		# branches and remain disabled until their payload grammar is promoted.
		if str(entry.get("type", "")) not in ["ACHR", "ACRE"] or str(entry.get("changeFlags", "")).to_lower() != "0x08000020":
			continue
		if not ref_id.is_empty():
			save_enabled_actor_refs[ref_id] = true
	runtime_condition_context["script_variables"] = script_variables
	_load_quest_save_state(save_manifest)
	print("OPENNV_SAVE_REFERENCE_STATE_READY transforms=%d enable_overrides=%d script_values=%d policy=validated-prefixes" % [
		save_reference_state_by_ref.size(), save_enabled_actor_refs.size(), promoted_script_values])


func _load_quest_save_state(save_manifest: Dictionary) -> void:
	var document := _read_json(QUEST_SAVE_STATE_PATH)
	if str(document.get("schema", "")) != "opennv-quest-save-state/v1" or str(document.get("status", "")) not in ["pass", "partial"]:
		push_warning("OPENNV_QUEST_SAVE_STATE_REJECTED schema-or-status")
		return
	var provenance := document.get("provenance", {}) as Dictionary
	var save := save_manifest.get("save", {}) as Dictionary
	if str(provenance.get("saveSha256", "")).to_lower() != str(save.get("sha256", "")).to_lower():
		push_warning("OPENNV_QUEST_SAVE_STATE_REJECTED save-sha")
		return
	var quest_running: Dictionary = {}
	var quest_stages: Dictionary = {}
	var quest_stage_done: Dictionary = {}
	var quest_variables: Dictionary = {}
	var quest_completed: Dictionary = {}
	var objective_completed: Dictionary = {}
	var objective_displayed: Dictionary = {}
	for quest_id_value in (document.get("quests", {}) as Dictionary):
		var quest_id := _canonical_form_id(quest_id_value)
		if quest_id.is_empty():
			continue
		var state := (document.get("quests", {}) as Dictionary)[quest_id_value] as Dictionary
		var flags := int(state.get("flags", 0))
		quest_running[quest_id] = 1.0 if (flags & 0x01) != 0 else 0.0
		quest_completed[quest_id] = 1.0 if (flags & 0x02) != 0 else 0.0
		quest_stages[quest_id] = float(state.get("currentStage", 0))
		for stage_value in (state.get("stageDone", {}) as Dictionary):
			quest_stage_done["%s:%d" % [quest_id, int(stage_value)]] = 1.0 if bool((state.get("stageDone", {}) as Dictionary)[stage_value]) else 0.0
		for objective_value in (state.get("objectives", {}) as Dictionary):
			var objective := int(objective_value)
			var objective_flags := int((state.get("objectives", {}) as Dictionary)[objective_value])
			objective_displayed["%s:%d" % [quest_id, objective]] = 1.0 if (objective_flags & 0x01) != 0 else 0.0
			objective_completed["%s:%d" % [quest_id, objective]] = 1.0 if (objective_flags & 0x02) != 0 else 0.0
		for index_value in (state.get("variables", {}) as Dictionary):
			quest_variables["%s:%d" % [quest_id, int(index_value)]] = float((state.get("variables", {}) as Dictionary)[index_value])
	runtime_condition_context["quest_running"] = quest_running
	runtime_condition_context["quest_stages"] = quest_stages
	runtime_condition_context["quest_stage_done"] = quest_stage_done
	runtime_condition_context["quest_variables"] = quest_variables
	runtime_condition_context["quest_completed"] = quest_completed
	runtime_condition_context["objective_completed"] = objective_completed
	runtime_condition_context["objective_displayed"] = objective_displayed
	print("OPENNV_QUEST_SAVE_STATE_READY quests=%d stages=%d variables=%d objectives=%d unmatched_saved=%d" % [
		quest_running.size(), quest_stage_done.size(), quest_variables.size(), objective_displayed.size(),
		int((document.get("counts", {}) as Dictionary).get("unmatchedSavedQuestChangeForms", 0))])


func _apply_save_reference_override(placement: Dictionary) -> bool:
	var ref_id := _canonical_form_id(placement.get("form_id", ""))
	if ref_id.is_empty() or not save_reference_state_by_ref.has(ref_id):
		return false
	var state := save_reference_state_by_ref[ref_id] as Dictionary
	var position_values := state.get("position", []) as Array
	if position_values.size() < 3 or not _valid_save_vector(position_values):
		return false
	placement["position"] = [float(position_values[0]), float(position_values[1]), float(position_values[2])]
	var authored_rotation := placement.get("rotation_radians", [0.0, 0.0, 0.0]) as Array
	while authored_rotation.size() < 3:
		authored_rotation.append(0.0)
	var saved_rotation := state.get("rotation_radians", []) as Array
	for index in range(mini(3, saved_rotation.size())):
		var value := float(saved_rotation[index])
		# FLT_MAX is the FOS unchanged-component sentinel. Preserve the authored
		# component instead of turning the reference transform into infinity.
		if is_finite(value) and absf(value) < 1.0e20:
			authored_rotation[index] = value
	placement["rotation_radians"] = authored_rotation
	placement["_runtime_save_state"] = state
	applied_save_reference_refs[ref_id] = true
	return true


func _valid_save_vector(values: Array) -> bool:
	if values.size() < 3:
		return false
	for index in range(3):
		var value := float(values[index])
		if not is_finite(value) or absf(value) >= 1.0e20:
			return false
	return true


func runtime_stats() -> Dictionary:
	_validate_world_mesh_cache_contract()
	_validate_terrain_mesh_cache_contract()
	var actor_coverage := _resident_actor_visual_coverage()
	var package_stats := _resident_package_runtime_stats()
	var lifecycle := _actor_lifecycle_invariants()
	return {
		"actor_cache_records": actor_cache_by_ref.size(),
		"save_reference_states": save_reference_state_by_ref.size(),
		"save_reference_states_applied": applied_save_reference_refs.size(),
		"resident_actors": resident_actors,
		"offscreen_actor_states": offscreen_actor_states.size(),
		"pending_actor_refs": pending_actor_refs.size(),
		"pending_offscreen_actor_refs": pending_offscreen_actor_refs.size(),
		"offscreen_restore_retries": offscreen_actor_restore_retries.size(),
		"actor_load_quarantined": actor_load_quarantined_refs.size(),
		"pending_actor_cell_promotions": pending_actor_cell_promotions.size(),
		"pending_exterior_cell_jobs": pending_exterior_cell_jobs.size(),
		"pending_interior_stage_jobs": pending_interior_stage_jobs.size(),
		"pending_exterior_retire_jobs": pending_exterior_retire_jobs.size(),
		"pending_focus_scan": 1 if pending_focus_scan_cursor >= 0 else 0,
		"pending_navmesh_cell_jobs": pending_navmesh_cell_jobs.size() + active_navmesh_cell_jobs.size()
			+ pending_navmesh_publish_jobs.size(),
		"actor_lifecycle_captures": int(actor_lifecycle_counters.captures),
		"actor_lifecycle_migrations": int(actor_lifecycle_counters.migrations),
		"actor_restore_queue_attempts": int(actor_lifecycle_counters.restore_queue_attempts),
		"actor_restore_successes": int(actor_lifecycle_counters.restore_successes),
		"actor_restore_failures": int(actor_lifecycle_counters.restore_failures),
		"actor_restore_retries_scheduled": int(actor_lifecycle_counters.restore_retries_scheduled),
		"actor_restore_retries_exhausted": int(actor_lifecycle_counters.restore_retries_exhausted),
		"actor_duplicate_suppressions": int(actor_lifecycle_counters.duplicate_suppressions),
		"offscreen_schedule_ticks": int(offscreen_schedule_counters.ticks),
		"offscreen_schedule_states_processed": int(offscreen_schedule_counters.states_processed),
		"offscreen_schedule_package_changes": int(offscreen_schedule_counters.package_changes),
		"offscreen_schedule_patrol_advances": int(offscreen_schedule_counters.patrol_advances),
		"offscreen_schedule_no_selections": int(offscreen_schedule_counters.no_selections),
		"offscreen_schedule_unsupported_selections": int(offscreen_schedule_counters.unsupported_selections),
		"offscreen_schedule_spatial_updates": int(offscreen_schedule_counters.spatial_updates),
		"offscreen_schedule_max_tick_usec": int(offscreen_schedule_counters.max_tick_usec),
		"actor_lifecycle_invariant_violations": int(lifecycle.get("violations", 1)),
		"actor_live_offscreen_conflicts": int(lifecycle.get("live_offscreen_conflicts", 0)),
		"actor_pending_without_state": int(lifecycle.get("pending_without_state", 0)),
		"actor_live_owner_violations": int(lifecycle.get("live_owner_violations", 0)),
		"actor_offscreen_bucket_violations": int(lifecycle.get("offscreen_bucket_violations", 0)),
		"resident_cells": resident_cells,
		"resident_instances": resident_instances,
		"resident_terrain_cells": resident_terrain_cells,
		"resident_navmesh_cells": resident_navmesh_cells,
		"deferred_route_cells": deferred_route_cells.size(),
		"deferred_terrain_cells": deferred_terrain_cells.size(),
		"deferred_interiors": deferred_interiors.size(),
		"pending_meshes": pending_paths.size() + active_paths.size(),
		"waiting_mesh_paths": waiting_placements.size(),
		"ready_mesh_paths": ready_placements.size(),
		"pending_skeletal_actors": pending_skeletal_placements.size(),
		"unsupported_model_paths": unsupported_model_counts.size(),
		"unsupported_model_instances": _unsupported_model_instance_count(),
		"mesh_load_failures": mesh_load_failures,
		"skeletal_cache_failures": skeletal_cache_failures,
		"world_mesh_cache_contract_valid": world_mesh_cache_contract_valid,
		"world_mesh_cache_source_count": world_mesh_cache_source_count,
		"world_mesh_cache_fallback_paths": world_mesh_cache_fallback_paths.size(),
		"terrain_mesh_cache_contract_valid": terrain_mesh_cache_contract_valid,
		"terrain_mesh_cache_cell_count": terrain_mesh_cache_cell_count,
		"terrain_mesh_cache_fallback_paths": terrain_mesh_cache_fallback_paths.size(),
		"cached_meshes": mesh_cache.size(),
		"cached_terrain_albedos": terrain_albedo_cache.size(),
		"referenced_meshes": mesh_ref_counts.size(),
		"max_stream_commit_usec": max_stream_commit_usec,
		"stream_commit_samples": stream_commit_samples,
		"max_focus_update_usec": max_focus_update_usec,
		"focus_update_samples": focus_update_samples,
		"max_cell_shard_usec": max_cell_shard_usec,
		"max_cell_terrain_usec": max_cell_terrain_usec,
		"max_cell_placements_usec": max_cell_placements_usec,
		"max_cell_navmesh_usec": max_cell_navmesh_usec,
		"max_cell_interior_stage_usec": max_cell_interior_stage_usec,
		"max_exterior_cell_commit_usec": max_exterior_cell_commit_usec,
		"max_skeletal_actor_commit_usec": max_skeletal_actor_commit_usec,
		"max_skeletal_decode_usec": max_skeletal_decode_usec,
		"max_skeletal_animation_usec": max_skeletal_animation_usec,
		"max_skeletal_publish_usec": max_skeletal_publish_usec,
		"max_mesh_install_commit_usec": max_mesh_install_commit_usec,
		"max_actor_cell_promotion_usec": max_actor_cell_promotion_usec,
		"max_navmesh_commit_usec": max_navmesh_commit_usec,
		"max_mesh_duplicate_usec": max_mesh_duplicate_usec,
		"max_mesh_material_usec": max_mesh_material_usec,
		"max_mesh_collision_split_usec": max_mesh_collision_split_usec,
		"max_mesh_placement_publish_usec": max_mesh_placement_publish_usec,
		"max_terrain_mesh_load_usec": max_terrain_mesh_load_usec,
		"max_terrain_texture_load_usec": max_terrain_texture_load_usec,
		"max_terrain_publish_usec": max_terrain_publish_usec,
		"max_terrain_collision_usec": max_terrain_collision_usec,
		"max_focus_prefetch_usec": max_focus_prefetch_usec,
		"max_focus_migrate_usec": max_focus_migrate_usec,
		"max_focus_actor_evict_usec": max_focus_actor_evict_usec,
		"max_focus_world_evict_usec": max_focus_world_evict_usec,
		"actor_visual_expected": actor_coverage.expected,
		"actor_visual_exact": actor_coverage.exact,
		"actor_visual_fallback": actor_coverage.fallback,
		"actor_visual_missing": actor_coverage.missing,
		"package_selected_actors": package_stats.selected,
		"package_reference_target_configured_actors": package_stats.reference_target_configured,
		"package_target_resolved_actors": package_stats.target_resolved,
		"package_steering_actors": package_stats.steering,
		"package_moving_actors": package_stats.moving,
		"package_stuck_actors": package_stats.stuck,
		"package_arrived_actors": package_stats.arrived,
		"package_action_animation_actors": package_stats.action_animation,
	}


func reset_performance_stats() -> void:
	# Startup/import work is intentionally outside the traversal gate. The soak
	# measures steady-state streaming and crossings after initial residency.
	max_stream_commit_usec = 0
	stream_commit_samples = 0
	max_focus_update_usec = 0
	focus_update_samples = 0
	max_cell_shard_usec = 0
	max_cell_terrain_usec = 0
	max_cell_placements_usec = 0
	max_cell_navmesh_usec = 0
	max_cell_interior_stage_usec = 0
	max_exterior_cell_commit_usec = 0
	max_skeletal_actor_commit_usec = 0
	max_skeletal_decode_usec = 0
	max_skeletal_animation_usec = 0
	max_skeletal_publish_usec = 0
	max_mesh_install_commit_usec = 0
	max_actor_cell_promotion_usec = 0
	max_navmesh_commit_usec = 0
	max_mesh_duplicate_usec = 0
	max_mesh_material_usec = 0
	max_mesh_collision_split_usec = 0
	max_mesh_placement_publish_usec = 0
	max_terrain_mesh_load_usec = 0
	max_terrain_texture_load_usec = 0
	max_terrain_publish_usec = 0
	max_terrain_collision_usec = 0
	max_focus_prefetch_usec = 0
	max_focus_migrate_usec = 0
	max_focus_actor_evict_usec = 0
	max_focus_world_evict_usec = 0
	offscreen_schedule_counters.max_tick_usec = 0


func _unsupported_model_instance_count() -> int:
	var total := 0
	for count_value in unsupported_model_counts.values():
		total += int(count_value)
	return total


func _actor_lifecycle_invariants() -> Dictionary:
	var result := {
		"violations": 0,
		"live_offscreen_conflicts": 0,
		"pending_without_state": 0,
		"live_owner_violations": 0,
		"offscreen_bucket_violations": 0,
	}
	for ref_value in actor_nodes_by_form_id.keys():
		var ref_id := _canonical_form_id(ref_value)
		if offscreen_actor_states.has(ref_id):
			result.live_offscreen_conflicts += 1
		var actor_value: Variant = actor_nodes_by_form_id.get(ref_id)
		if not is_instance_valid(actor_value):
			result.live_owner_violations += 1
			actor_nodes_by_form_id.erase(ref_id)
			continue
		var actor := actor_value as Node
		var cell_id := _canonical_form_id(actor.get_meta("opennv_runtime_cell", ""))
		var actor_owner_count := 0
		for nodes_value in actor_nodes_by_cell.values():
			for node_value in nodes_value as Array:
				if node_value == actor:
					actor_owner_count += 1
		var stream_owner_count := 0
		for nodes_value in stream_nodes_by_cell.values():
			for node_value in nodes_value as Array:
				if node_value == actor:
					stream_owner_count += 1
		if cell_id.is_empty() or actor_owner_count != 1 or stream_owner_count != 1:
			result.live_owner_violations += 1
		if pending_actor_refs.has(ref_id):
			result.live_owner_violations += 1
	for ref_value in pending_offscreen_actor_refs.keys():
		if not offscreen_actor_states.has(_canonical_form_id(ref_value)):
			result.pending_without_state += 1
	var bucket_counts: Dictionary = {}
	for refs_value in offscreen_actor_refs_by_cell.values():
		for ref_value in refs_value as Array:
			var ref_id := _canonical_form_id(ref_value)
			bucket_counts[ref_id] = int(bucket_counts.get(ref_id, 0)) + 1
	for ref_value in offscreen_actor_states.keys():
		var ref_id := _canonical_form_id(ref_value)
		if int(bucket_counts.get(ref_id, 0)) != 1:
			result.offscreen_bucket_violations += 1
	for ref_value in bucket_counts.keys():
		if not offscreen_actor_states.has(_canonical_form_id(ref_value)):
			result.offscreen_bucket_violations += 1
	result.violations = (int(result.live_offscreen_conflicts) + int(result.pending_without_state)
		+ int(result.live_owner_violations) + int(result.offscreen_bucket_violations))
	return result


func _resident_package_runtime_stats() -> Dictionary:
	var result := {
		"selected": 0, "reference_target_configured": 0, "target_resolved": 0,
		"steering": 0, "moving": 0, "stuck": 0, "arrived": 0, "action_animation": 0,
	}
	for actor_value in actor_nodes_by_form_id.values():
		if not is_instance_valid(actor_value):
			continue
		var actor := actor_value as Node
		if not str(actor.get_meta("opennv_active_package", "")).is_empty():
			result.selected += 1
		if not str(actor.get("travel_target_ref")).is_empty() or bool(actor.get("direct_travel_target_enabled")):
			result.reference_target_configured += 1
		if bool(actor.get_meta("opennv_package_target_resolved", false)):
			result.target_resolved += 1
		if bool(actor.get_meta("opennv_package_steering", false)):
			result.steering += 1
		if bool(actor.get_meta("opennv_package_moving", false)):
			result.moving += 1
		if bool(actor.get_meta("opennv_package_stuck", false)):
			result.stuck += 1
		if bool(actor.get_meta("opennv_package_arrived", false)):
			result.arrived += 1
		var requested_action := str(actor.get_meta("opennv_package_action_animation", "idle"))
		var actor_visual := actor.get_node_or_null("Visual") as Node3D
		var action_player := actor_visual.get_node_or_null("AnimationPlayer") as AnimationPlayer if actor_visual != null else null
		if requested_action != "idle" and action_player != null and action_player.is_playing() \
				and action_player.current_animation == requested_action \
				and int(actor_visual.get_meta("opennv_animation_matched_tracks", 0)) >= 40:
			result.action_animation += 1
	return result


func _collect_destination_interior(placement: Dictionary, result: Dictionary) -> void:
	if str(placement.get("base_type", "")) != "DOOR":
		return
	var destination_cell := _canonical_form_id(placement.get("destination_cell", ""))
	# Door-distance prefetch owns staging. Merely loading an exterior CELL must
	# not pull every linked interior into memory.
	return


func _stage_interior(cell_id_value: String, prefetch_depth: int = 0) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	if staged_interiors.has(cell_id) or pending_interior_stage_jobs.has(cell_id):
		_touch_interior_lru(cell_id)
		return
	if not deferred_interiors.has(cell_id):
		return
	var record := deferred_interiors[cell_id] as Dictionary
	deferred_interiors.erase(cell_id)
	staged_interiors[cell_id] = true
	_touch_interior_lru(cell_id)
	var cell_origin := record.get("origin", Vector3.ZERO) as Vector3
	var stage_origin := record.get("stage", Vector3.ZERO) as Vector3
	var interior_index := record.get("interior", {}) as Dictionary
	var shard_path := str(interior_index.get("shard", ""))
	var job := {"cell": cell_id, "record": record, "origin": cell_origin,
		"stage": stage_origin, "depth": prefetch_depth, "index": interior_index}
	if not shard_path.is_empty():
		job["task"] = WorkerThreadPool.add_task(
			_read_exterior_shard_worker.bind(cell_id, shard_path), true,
			"OpenNV interior %s" % cell_id)
	pending_interior_stage_jobs[cell_id] = job
	set_process(true)


func _pump_interior_stage_jobs() -> bool:
	for cell_id_value in pending_interior_stage_jobs.keys():
		var cell_id := _canonical_form_id(cell_id_value)
		var job := pending_interior_stage_jobs[cell_id] as Dictionary
		if not job.has("interior"):
			var interior := job.get("index", {}) as Dictionary
			if job.has("task"):
				var task := int(job.get("task", -1))
				if not WorkerThreadPool.is_task_completed(task):
					continue
				WorkerThreadPool.wait_for_task_completion(task)
				exterior_shard_worker_mutex.lock()
				var result_value: Variant = exterior_shard_worker_results.get(cell_id, {})
				exterior_shard_worker_results.erase(cell_id)
				exterior_shard_worker_mutex.unlock()
				interior = (result_value as Dictionary) if result_value is Dictionary else {}
			if interior.is_empty():
				deferred_interiors[cell_id] = job.get("record", {}) as Dictionary
				staged_interiors.erase(cell_id)
				interior_lru.erase(cell_id)
				pending_interior_stage_jobs.erase(cell_id)
				push_warning("OPENNV_INTERIOR_SHARD_MISSING cell=%s" % cell_id)
				return true
			job.erase("task")
			job["interior"] = interior
			job["cursor"] = 0
			_load_navmesh_cell(cell_id, job.get("origin", Vector3.ZERO),
				job.get("stage", Vector3.ZERO), cell_id)
		var placements := (job.get("interior", {}) as Dictionary).get("placements", []) as Array
		var cursor := int(job.get("cursor", 0))
		var started := Time.get_ticks_usec()
		while cursor < placements.size() and Time.get_ticks_usec() - started < 1000:
			_queue_placement(placements[cursor] as Dictionary, cell_id,
				job.get("origin", Vector3.ZERO), job.get("stage", Vector3.ZERO), true)
			cursor += 1
		job["cursor"] = cursor
		if cursor < placements.size():
			pending_interior_stage_jobs[cell_id] = job
			return true
		_queue_offscreen_actors_for_cell(cell_id, job.get("origin", Vector3.ZERO),
			job.get("stage", Vector3.ZERO), true, cell_id, 0)
		pending_interior_stage_jobs.erase(cell_id)
		resident_cells += 1
		_trim_interior_residency()
		print("OPENNV_INTERIOR_PREFETCH cell=%s remaining=%d" % [cell_id, deferred_interiors.size()])
		return true
	return false


func _touch_interior_lru(cell_id_value: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	interior_lru.erase(cell_id)
	interior_lru.append(cell_id)


func _trim_interior_residency() -> void:
	while interior_lru.size() > INTERIOR_KEEP_COUNT:
		var retired := false
		for cell_id_value in interior_lru.duplicate():
			var cell_id := str(cell_id_value)
			if cell_id == active_scope or portal_pinned_cells.has(cell_id):
				continue
			_retire_interior(cell_id)
			retired = true
			break
		if not retired:
			break


func _retire_interior(cell_id_value: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	if not staged_interiors.has(cell_id) or cell_id == active_scope or portal_pinned_cells.has(cell_id):
		return
	_drop_pending_cell_placements(cell_id)
	_retire_navmesh_cell(cell_id)
	for node_value in stream_nodes_by_cell.get(cell_id, []):
		var node := node_value as Node
		if not is_instance_valid(node):
			continue
		resident_instances = maxi(0, resident_instances - int(node.get_meta("opennv_stream_instance_count", 0)))
		if node.has_meta("fnv_actor_id"):
			_capture_offscreen_actor_state(node as Node3D)
			resident_actors = maxi(0, resident_actors - 1)
		_release_stream_mesh_ref(node)
		if node.has_meta("fnv_form_id"):
			var form_id := _canonical_form_id(node.get_meta("fnv_form_id", ""))
			door_nodes_by_form_id.erase(form_id)
			actor_nodes_by_form_id.erase(form_id)
		node.queue_free()
	stream_nodes_by_cell.erase(cell_id)
	_drop_cell_reference_positions(cell_id)
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
			_release_offscreen_actor_pending(placement)
			pending_skeletal_placements.remove_at(index)
	for table in [waiting_placements, ready_placements]:
		for path_value in table.keys():
			var path := str(path_value)
			var placements := table[path] as Array
			for index in range(placements.size() - 1, -1, -1):
				var placement := placements[index] as Dictionary
				if _canonical_form_id(placement.get("_runtime_cell", "")) == cell_id:
					_release_offscreen_actor_pending(placement)
					placements.remove_at(index)
			if placements.is_empty():
				table.erase(path)
				if not active_paths.has(path):
					pending_paths.erase(path)
					pending_path_priorities.erase(path)


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
		_mark_offscreen_actor_pending(placement)
		pending_skeletal_placements.append(placement)
		_request_skeletal_scene_cache(actor_record)
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
	_mark_offscreen_actor_pending(placement)
	if mesh_cache.has(path):
		if not ready_placements.has(path):
			ready_placements[path] = []
		(ready_placements[path] as Array).append(placement)
		return
	if not waiting_placements.has(path):
		waiting_placements[path] = []
		pending_paths.append(path)
		pending_path_priorities[path] = int(placement.get("_runtime_stream_priority", 0))
	else:
		var stream_priority := int(placement.get("_runtime_stream_priority", 0))
		pending_path_priorities[path] = mini(int(pending_path_priorities.get(path, stream_priority)), stream_priority)
	waiting_placements[path].append(placement)


func _persistent_actor_placement(placement: Dictionary) -> Dictionary:
	var result := placement.duplicate(true)
	for key in ["_runtime_actor", "_runtime_skeletal", "_runtime_restore_transform",
			"_runtime_actor_state", "_runtime_offscreen_ref"]:
		result.erase(key)
	return result


func _mark_offscreen_actor_pending(placement: Dictionary) -> void:
	var actor_ref := _canonical_form_id(placement.get("form_id", ""))
	if not actor_ref.is_empty():
		pending_actor_refs[actor_ref] = true
	var ref_id := _canonical_form_id(placement.get("_runtime_offscreen_ref", ""))
	if not ref_id.is_empty():
		pending_offscreen_actor_refs[ref_id] = true


func _release_offscreen_actor_pending(placement: Dictionary) -> void:
	pending_actor_refs.erase(_canonical_form_id(placement.get("form_id", "")))
	var ref_id := _canonical_form_id(placement.get("_runtime_offscreen_ref", ""))
	if not ref_id.is_empty():
		pending_offscreen_actor_refs.erase(ref_id)


func _release_offscreen_pending_for_path(path: String) -> void:
	for placement_value in waiting_placements.get(path, []):
		_release_offscreen_actor_pending(placement_value as Dictionary)


func _schedule_offscreen_retries_for_path(path: String, reason: String) -> void:
	for placement_value in waiting_placements.get(path, []):
		var placement := placement_value as Dictionary
		if placement.has("_runtime_actor"):
			_schedule_offscreen_actor_restore_retry(placement, reason)
		else:
			_release_offscreen_actor_pending(placement)


func _consume_offscreen_actor_state(ref_id_value: String) -> void:
	var ref_id := _canonical_form_id(ref_id_value)
	pending_actor_refs.erase(ref_id)
	pending_offscreen_actor_refs.erase(ref_id)
	offscreen_actor_restore_retries.erase(ref_id)
	actor_load_quarantined_refs.erase(ref_id)
	if not offscreen_actor_states.has(ref_id):
		return
	var state := offscreen_actor_states[ref_id] as Dictionary
	var cell_id := _canonical_form_id(state.get("cell", ""))
	(offscreen_actor_refs_by_cell.get(cell_id, []) as Array).erase(ref_id)
	if (offscreen_actor_refs_by_cell.get(cell_id, []) as Array).is_empty():
		offscreen_actor_refs_by_cell.erase(cell_id)
	offscreen_actor_states.erase(ref_id)
	actor_lifecycle_counters.restore_successes += 1


func _capture_offscreen_actor_state(actor: Node3D) -> void:
	var ref_id := _canonical_form_id(actor.get_meta("fnv_form_id", ""))
	var cell_id := _canonical_form_id(actor.get_meta("opennv_runtime_cell", ""))
	var placement := actor.get_meta("opennv_spawn_placement", {}) as Dictionary
	if ref_id.is_empty() or cell_id.is_empty() or placement.is_empty():
		return
	if offscreen_actor_states.has(ref_id):
		var prior := offscreen_actor_states[ref_id] as Dictionary
		var prior_cell := _canonical_form_id(prior.get("cell", ""))
		(offscreen_actor_refs_by_cell.get(prior_cell, []) as Array).erase(ref_id)
		if (offscreen_actor_refs_by_cell.get(prior_cell, []) as Array).is_empty():
			offscreen_actor_refs_by_cell.erase(prior_cell)
	placement = placement.duplicate(true)
	placement["_runtime_cell"] = cell_id
	var runtime_scope := str(actor.get_meta("opennv_runtime_scope", EXTERIOR_SCOPE))
	var runtime_interior := interior_names.has(cell_id)
	placement["_runtime_scope"] = runtime_scope
	placement["_runtime_interior"] = runtime_interior
	if runtime_interior:
		var cell_origin := interior_source_origins.get(cell_id, Vector3.ZERO) as Vector3
		var stage_origin := interior_stage_origins.get(cell_id, Vector3.ZERO) as Vector3
		placement["_runtime_origin"] = [cell_origin.x, cell_origin.y, cell_origin.z]
		placement["_runtime_stage"] = [stage_origin.x, stage_origin.y, stage_origin.z]
	else:
		var cell_index := cell_indices_by_id.get(cell_id, {}) as Dictionary
		var world_id := _canonical_form_id(cell_index.get("world_form_id", primary_world_id))
		var world_origin := _world_runtime_origin(world_id)
		placement["_runtime_origin"] = [world_origin.x, world_origin.y, world_origin.z]
		placement["_runtime_stage"] = [0.0, 0.0, 0.0]
	placement["_runtime_restore_transform"] = actor.global_transform
	placement["_runtime_offscreen_ref"] = ref_id
	if actor.has_method("export_runtime_state"):
		placement["_runtime_actor_state"] = actor.call("export_runtime_state") as Dictionary
		var captured_runtime_state := placement["_runtime_actor_state"] as Dictionary
		captured_runtime_state["last_schedule_game_minute"] = runtime_game_minute
		placement["_runtime_actor_state"] = captured_runtime_state
	offscreen_actor_states[ref_id] = {
		"cell": cell_id, "position": actor.global_position, "placement": placement,
	}
	if not offscreen_actor_refs_by_cell.has(cell_id):
		offscreen_actor_refs_by_cell[cell_id] = []
	if not (offscreen_actor_refs_by_cell[cell_id] as Array).has(ref_id):
		(offscreen_actor_refs_by_cell[cell_id] as Array).append(ref_id)
	reference_runtime_positions[ref_id] = actor.global_position
	reference_runtime_cells[ref_id] = cell_id
	actor_lifecycle_counters.captures += 1


func _queue_offscreen_actors_for_cell(cell_id_value: String, cell_origin: Vector3,
		stage_origin: Vector3, interior: bool, runtime_scope: String, stream_priority: int) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	for ref_id_value in (offscreen_actor_refs_by_cell.get(cell_id, []) as Array).duplicate():
		var ref_id := _canonical_form_id(ref_id_value)
		if pending_offscreen_actor_refs.has(ref_id) or not offscreen_actor_states.has(ref_id):
			continue
		_sync_offscreen_actor_schedule(ref_id)
		var state := offscreen_actor_states[ref_id] as Dictionary
		actor_lifecycle_counters.restore_queue_attempts += 1
		_queue_placement(state.get("placement", {}) as Dictionary, cell_id, cell_origin,
			stage_origin, interior, runtime_scope, stream_priority)


func _schedule_offscreen_actor_restore_retry(placement: Dictionary, reason: String) -> void:
	var ref_id := _canonical_form_id(placement.get("_runtime_offscreen_ref", ""))
	if ref_id.is_empty():
		ref_id = _canonical_form_id(placement.get("form_id", ""))
	_release_offscreen_actor_pending(placement)
	if ref_id.is_empty():
		return
	actor_lifecycle_counters.restore_failures += 1
	var prior := offscreen_actor_restore_retries.get(ref_id, {}) as Dictionary
	var attempt := int(prior.get("attempt", 0)) + 1
	if attempt > OFFSCREEN_RESTORE_MAX_RETRIES:
		offscreen_actor_restore_retries.erase(ref_id)
		actor_load_quarantined_refs[ref_id] = {
			"reason": reason,
			"cell": _canonical_form_id(placement.get("_runtime_cell", "")),
			"placement": placement.duplicate(true),
		}
		var failed_cell := _canonical_form_id(placement.get("_runtime_cell", ""))
		if not actor_visual_status_by_cell.has(failed_cell):
			actor_visual_status_by_cell[failed_cell] = {}
		(actor_visual_status_by_cell[failed_cell] as Dictionary)[ref_id] = "load_failed"
		actor_lifecycle_counters.restore_retries_exhausted += 1
		push_warning("OPENNV_ACTOR_RESTORE_EXHAUSTED ref=%s reason=%s" % [ref_id, reason])
		return
	var delay := OFFSCREEN_RESTORE_RETRY_BASE_MSEC * (1 << (attempt - 1))
	offscreen_actor_restore_retries[ref_id] = {
		"attempt": attempt,
		"due_msec": Time.get_ticks_msec() + delay,
		"reason": reason,
		"placement": placement.duplicate(true),
	}
	actor_lifecycle_counters.restore_retries_scheduled += 1
	set_process(true)


func _process_due_offscreen_actor_restore_retries() -> void:
	var now := Time.get_ticks_msec()
	for ref_value in offscreen_actor_restore_retries.keys():
		var ref_id := _canonical_form_id(ref_value)
		var retry := offscreen_actor_restore_retries.get(ref_id, {}) as Dictionary
		if now < int(retry.get("due_msec", 0)):
			continue
		var placement := retry.get("placement", {}) as Dictionary
		var cell_id := _canonical_form_id(placement.get("_runtime_cell", ""))
		if offscreen_actor_states.has(ref_id):
			var state := offscreen_actor_states[ref_id] as Dictionary
			placement = state.get("placement", placement) as Dictionary
			cell_id = _canonical_form_id(state.get("cell", cell_id))
		var interior := bool(placement.get("_runtime_interior", false))
		var resident := staged_interiors.has(cell_id) if interior else loaded_actor_cells.has(cell_id)
		if not resident:
			# Normal cell activation will queue the retained state again.
			offscreen_actor_restore_retries.erase(ref_id)
			continue
		offscreen_actor_restore_retries.erase(ref_id)
		actor_lifecycle_counters.restore_queue_attempts += 1
		_queue_placement(placement, cell_id,
			_array_to_vector3(placement.get("_runtime_origin", [])),
			_array_to_vector3(placement.get("_runtime_stage", [])), interior,
			str(placement.get("_runtime_scope", cell_id if interior else EXTERIOR_SCOPE)),
			int(placement.get("_runtime_stream_priority", 0)))


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
	_process_due_offscreen_actor_restore_retries()
	var status_now := Time.get_ticks_msec()
	if status_now - stream_status_last_msec >= 5000:
		stream_status_last_msec = status_now
		print("OPENNV_STREAM_PROGRESS pending_mesh=%d active_mesh=%d waiting_mesh=%d ready_mesh=%d skeletal=%d promotions=%d" % [
			pending_paths.size(), active_paths.size(), waiting_placements.size(), ready_placements.size(),
			pending_skeletal_placements.size(), pending_actor_cell_promotions.size()])
	if pending_focus_scan_cursor >= 0:
		_process_exterior_focus_scan_row()
	if _pump_interior_stage_jobs():
		return
	if _pump_exterior_retire_jobs():
		return
	if _pump_navmesh_stream_jobs():
		return
	if not ready_placements.is_empty():
		_flush_ready_placements(1, STREAM_COMMIT_BUDGET_USEC)
		return
	if not pending_exterior_cell_jobs.is_empty():
		var job := _pop_exterior_cell_job()
		var cell_started := Time.get_ticks_usec()
		_commit_exterior_cell_job(job)
		var cell_elapsed := Time.get_ticks_usec() - cell_started
		max_exterior_cell_commit_usec = maxi(max_exterior_cell_commit_usec, cell_elapsed)
		max_stream_commit_usec = maxi(max_stream_commit_usec, cell_elapsed)
		stream_commit_samples += 1
		return
	if not pending_actor_cell_promotions.is_empty():
		var promotion := pending_actor_cell_promotions.pop_front() as Dictionary
		var promotion_cell := _canonical_form_id(promotion.get("cell", ""))
		pending_actor_cell_promotion_ids.erase(promotion_cell)
		var promotion_start := Time.get_ticks_usec()
		_promote_actor_cell_residency(promotion_cell, _canonical_form_id(promotion.get("world", "")))
		var promotion_elapsed := Time.get_ticks_usec() - promotion_start
		max_actor_cell_promotion_usec = maxi(max_actor_cell_promotion_usec, promotion_elapsed)
		max_stream_commit_usec = maxi(max_stream_commit_usec, promotion_elapsed)
		stream_commit_samples += 1
		return
	if pending_paths.is_empty() and active_paths.is_empty() and pending_skeletal_placements.is_empty() \
			and offscreen_actor_restore_retries.is_empty() and pending_actor_cell_promotions.is_empty() \
			and pending_exterior_cell_jobs.is_empty() and pending_focus_scan_cursor < 0 \
			and pending_interior_stage_jobs.is_empty() \
			and pending_exterior_retire_jobs.is_empty() \
			and ready_placements.is_empty() \
			and pending_navmesh_cell_jobs.is_empty() and active_navmesh_cell_jobs.is_empty() \
			and pending_navmesh_publish_jobs.is_empty():
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
		var skeletal_placement := _pop_next_pending_skeletal_placement()
		if not _placement_is_resident(skeletal_placement):
			_release_offscreen_actor_pending(skeletal_placement)
			return
		var skeletal_loader := load("res://scripts/opennv_skeletal_actor_loader.gd")
		var skeletal_phase_started := Time.get_ticks_usec()
		var actor_record := skeletal_placement.get("_runtime_actor", {}) as Dictionary
		var skeletal_hash := str(actor_record.get("skeletal_sha256", ""))
		var animation_hash := str(actor_record.get("animation_idle_sha256", ""))
		var cached_path := _skeletal_scene_cache_path(skeletal_hash, animation_hash)
		var skeletal_scene: Node3D = null
		var used_packed_cache := ResourceLoader.exists(cached_path)
		if used_packed_cache:
			_request_skeletal_scene_cache(actor_record)
			var cache_status := ResourceLoader.load_threaded_get_status(cached_path)
			if cache_status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				pending_skeletal_placements.append(skeletal_placement)
				return
			var packed: PackedScene = null
			if cache_status == ResourceLoader.THREAD_LOAD_LOADED:
				packed = ResourceLoader.load_threaded_get(cached_path) as PackedScene
			else:
				skeletal_cache_requests.erase(cached_path)
				used_packed_cache = false
			if packed != null:
				skeletal_scene = packed.instantiate() as Node3D
				if str(skeletal_scene.get_meta("opennv_cache_skeletal_sha256", "")) != skeletal_hash \
						or str(skeletal_scene.get_meta("opennv_cache_animation_sha256", "")) != animation_hash:
					skeletal_scene.free()
					skeletal_scene = null
					used_packed_cache = false
					skeletal_cache_failures += 1
			else:
				used_packed_cache = false
				skeletal_cache_failures += 1
		if skeletal_scene == null and not used_packed_cache:
			skeletal_scene = skeletal_loader.call("load_scene", str(skeletal_placement.get("_runtime_skeletal", ""))) as Node3D
		max_skeletal_decode_usec = maxi(max_skeletal_decode_usec, Time.get_ticks_usec() - skeletal_phase_started)
		if skeletal_scene != null:
			var animation_path := str(actor_record.get("animation_idle", ""))
			var animation_runtime_safe := _actor_idle_animation_runtime_safe(actor_record)
			if not used_packed_cache and animation_runtime_safe and not animation_path.is_empty() and FileAccess.file_exists(animation_path):
				skeletal_phase_started = Time.get_ticks_usec()
				var animation_loader := load("res://scripts/opennv_animation_loader.gd")
				animation_loader.call("attach_clip", skeletal_scene, animation_path, "idle")
				max_skeletal_animation_usec = maxi(max_skeletal_animation_usec,
					Time.get_ticks_usec() - skeletal_phase_started)
			if not animation_runtime_safe:
				_quarantine_unsafe_actor_animation(skeletal_scene, actor_record)
			skeletal_phase_started = Time.get_ticks_usec()
			_add_skeletal_actor(skeletal_scene, skeletal_placement)
			max_skeletal_publish_usec = maxi(max_skeletal_publish_usec,
				Time.get_ticks_usec() - skeletal_phase_started)
		else:
			_schedule_offscreen_actor_restore_retry(skeletal_placement, "skeletal-load-failed")
		var skeletal_elapsed := Time.get_ticks_usec() - skeletal_start
		max_skeletal_actor_commit_usec = maxi(max_skeletal_actor_commit_usec, skeletal_elapsed)
		max_stream_commit_usec = maxi(max_stream_commit_usec, skeletal_elapsed)
		stream_commit_samples += 1
		if skeletal_elapsed > 100000:
			print("OPENNV_SKELETAL_COMMIT_SLOW ref=%s usec=%d path=%s" % [
				_canonical_form_id(skeletal_placement.get("form_id", "")), skeletal_elapsed,
				str(skeletal_placement.get("_runtime_skeletal", ""))])
		return
	if not threaded_loading:
		# OpenXR/Vulkan drivers must not receive shared imported mesh resources
		# from ResourceLoader worker threads while swapchain images are acquired.
		var commit_start := Time.get_ticks_usec()
		var committed := 0
		while not pending_paths.is_empty() and (committed == 0 or Time.get_ticks_usec() - commit_start < STREAM_COMMIT_BUDGET_USEC):
			var path := _pop_next_pending_path()
			var imported_mesh := load(path) as Mesh
			if imported_mesh != null:
				_install_mesh(path, imported_mesh)
			else:
				mesh_load_failures += 1
				_schedule_offscreen_retries_for_path(path, "mesh-load-failed")
				waiting_placements.erase(path)
			committed += 1
		var elapsed := Time.get_ticks_usec() - commit_start
		max_mesh_install_commit_usec = maxi(max_mesh_install_commit_usec, elapsed)
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
			mesh_load_failures += 1
			push_warning("OPENNV_CELL_MESH_FAILED %s" % path)
			_schedule_offscreen_retries_for_path(path, "threaded-mesh-load-failed")
			waiting_placements.erase(path)
			continue
		var imported_mesh := ResourceLoader.load_threaded_get(path) as Mesh
		if imported_mesh == null:
			mesh_load_failures += 1
			_schedule_offscreen_retries_for_path(path, "threaded-mesh-null")
			waiting_placements.erase(path)
			continue
		_install_mesh(path, imported_mesh)
	var elapsed := Time.get_ticks_usec() - commit_start
	max_mesh_install_commit_usec = maxi(max_mesh_install_commit_usec, elapsed)
	max_stream_commit_usec = maxi(max_stream_commit_usec, elapsed)
	stream_commit_samples += 1
	_pump_threaded_requests()


func _actor_idle_animation_runtime_safe(actor_record: Dictionary) -> bool:
	var animation_path := str(actor_record.get("animation_idle", "")).to_lower().replace("\\", "/")
	# The promoted bighorner MTIdle currently drives the skinned body below its
	# authored root even though every source track binds successfully. Until the
	# clip has a world-space ground-bounds validator, prefer the correct static
	# bind pose over a visibly buried actor.
	return "nvbighorner-mtidle.onvanim" not in animation_path


func _quarantine_unsafe_actor_animation(actor_root: Node3D, actor_record: Dictionary) -> void:
	for player_value in actor_root.find_children("*", "AnimationPlayer", true, false):
		var player := player_value as AnimationPlayer
		player.stop()
		if not player.is_inside_tree():
			player.autoplay = &""
	for skeleton_value in actor_root.find_children("*", "Skeleton3D", true, false):
		(skeleton_value as Skeleton3D).reset_bone_poses()
	actor_root.set_meta("opennv_animation_quarantined", true)
	actor_root.set_meta("opennv_animation_quarantine_source", actor_record.get("animation_idle", ""))


func _pump_threaded_requests() -> void:
	while active_paths.size() < MAX_CONCURRENT_MESH_LOADS and not pending_paths.is_empty():
		var path := _pop_next_pending_path()
		var error := ResourceLoader.load_threaded_request(path, "Mesh", true)
		if error == OK:
			active_paths.append(path)
		else:
			mesh_load_failures += 1
			push_warning("OPENNV_CELL_MESH_REQUEST_FAILED %s error=%d" % [path, error])
			_schedule_offscreen_retries_for_path(path, "threaded-request-failed")
			waiting_placements.erase(path)


func _pop_next_pending_path() -> String:
	if pending_paths.is_empty():
		return ""
	var best_index := 0
	var best_priority := int(pending_path_priorities.get(pending_paths[0], 2147483647))
	for index in range(1, pending_paths.size()):
		var priority := int(pending_path_priorities.get(pending_paths[index], 2147483647))
		if priority < best_priority:
			best_index = index
			best_priority = priority
	var path := pending_paths[best_index]
	pending_paths.remove_at(best_index)
	pending_path_priorities.erase(path)
	return path


func _skeletal_scene_cache_path(skeletal_hash: String, animation_hash: String) -> String:
	var animation_key := animation_hash.substr(0, 32) if not animation_hash.is_empty() else "none"
	return "%s/%s-%s.scn" % [SKELETAL_SCENE_CACHE_DIR,
		skeletal_hash.substr(0, 32), animation_key]


func _request_skeletal_scene_cache(actor_record: Dictionary) -> void:
	var skeletal_hash := str(actor_record.get("skeletal_sha256", ""))
	if skeletal_hash.is_empty():
		return
	var cached_path := _skeletal_scene_cache_path(skeletal_hash,
		str(actor_record.get("animation_idle_sha256", "")))
	if not ResourceLoader.exists(cached_path) or skeletal_cache_requests.has(cached_path):
		return
	var error := ResourceLoader.load_threaded_request(cached_path, "PackedScene", true)
	if error == OK:
		skeletal_cache_requests[cached_path] = true


func _pop_next_pending_skeletal_placement() -> Dictionary:
	if pending_skeletal_placements.is_empty():
		return {}
	var best_index := 0
	var best_priority := int(pending_skeletal_placements[0].get("_runtime_stream_priority", 2147483647))
	for index in range(1, pending_skeletal_placements.size()):
		var priority := int(pending_skeletal_placements[index].get("_runtime_stream_priority", 2147483647))
		if priority < best_priority:
			best_index = index
			best_priority = priority
	var placement := pending_skeletal_placements[best_index]
	pending_skeletal_placements.remove_at(best_index)
	return placement


func update_focus(focus_position: Vector3) -> void:
	var focus_call_started := Time.get_ticks_usec()
	player_runtime_position = focus_position
	if OS.get_environment("FNV_GODOT_CINEMATIC_REEL") == "1":
		# The compact reel preloads several atlas-isolated worldspaces at once.
		# Keep that curated set resident for all four rails; ordinary focus
		# eviction would interpret the next atlas town as far-away gameplay and
		# discard it before the camera arrived. Frustum culling remains active.
		_record_focus_update(focus_call_started)
		return
	if not _scope_is_exterior(active_scope):
		_record_focus_update(focus_call_started)
		return
	var focus_phase_started := Time.get_ticks_usec()
	_prefetch_nearby_interiors(focus_position, false)
	max_focus_prefetch_usec = maxi(max_focus_prefetch_usec,
		Time.get_ticks_usec() - focus_phase_started)
	var world_origin := _world_runtime_origin(active_exterior_world_id)
	var atlas_position := world_origin + _godot_vector_to_source(focus_position * UNITS_PER_METER)
	var focus_grid := Vector2i(floori(atlas_position.x / 4096.0), floori(atlas_position.y / 4096.0))
	if focus_grid == last_focus_grid:
		_record_focus_update(focus_call_started)
		return
	last_focus_grid = focus_grid
	_schedule_exterior_focus_scan(focus_grid, active_exterior_world_id)
	focus_phase_started = Time.get_ticks_usec()
	_migrate_exterior_actor_ownership(active_exterior_world_id)
	max_focus_migrate_usec = maxi(max_focus_migrate_usec,
		Time.get_ticks_usec() - focus_phase_started)
	focus_phase_started = Time.get_ticks_usec()
	_evict_actors_outside(focus_grid, active_exterior_world_id)
	max_focus_actor_evict_usec = maxi(max_focus_actor_evict_usec,
		Time.get_ticks_usec() - focus_phase_started)
	focus_phase_started = Time.get_ticks_usec()
	_evict_exterior_outside(focus_grid, active_exterior_world_id)
	max_focus_world_evict_usec = maxi(max_focus_world_evict_usec,
		Time.get_ticks_usec() - focus_phase_started)
	# Interior staging remains conservative until the door-distance prefetcher is
	# installed; never recurse through the entire interior graph at startup.
	print("OPENNV_ROUTE_PREFETCH_REQUEST focus_grid=%s remaining=%d" % [focus_grid, deferred_route_cells.size()])
	set_process(true)
	_record_focus_update(focus_call_started)


func _record_focus_update(started_usec: int) -> void:
	var focus_elapsed := Time.get_ticks_usec() - started_usec
	max_focus_update_usec = maxi(max_focus_update_usec, focus_elapsed)
	focus_update_samples += 1


func advance_game_time(delta: float) -> void:
	actor_migration_accumulator += delta
	if actor_migration_accumulator >= 0.5:
		actor_migration_accumulator = fmod(actor_migration_accumulator, 0.5)
		if _scope_is_exterior(active_scope) and not active_exterior_world_id.is_empty():
			_migrate_exterior_actor_ownership(active_exterior_world_id)
	var override_hour := OS.get_environment("FNV_GODOT_GAME_HOUR")
	if not override_hour.is_empty():
		return
	var scale_text := OS.get_environment("FNV_GODOT_TIME_SCALE")
	var time_scale := float(scale_text) if scale_text.is_valid_float() else 30.0
	if time_scale <= 0.0:
		return
	var elapsed_game_seconds := delta * time_scale
	runtime_game_minute += elapsed_game_seconds / 60.0
	runtime_condition_context["game_hour"] = fposmod(
		float(runtime_condition_context.get("game_hour", 9.0)) + elapsed_game_seconds / 3600.0, 24.0)
	package_clock_accumulator += elapsed_game_seconds
	if package_clock_accumulator < 60.0:
		return
	package_clock_accumulator = fmod(package_clock_accumulator, 60.0)
	var hour := float(runtime_condition_context["game_hour"])
	for actor_value in actor_nodes_by_form_id.values():
		if not is_instance_valid(actor_value):
			continue
		var actor := actor_value as Node
		if actor.has_method("update_game_hour"):
			actor.call("update_game_hour", hour)
	_advance_offscreen_actor_schedules(hour, runtime_game_minute)


func _offscreen_package_list(actor_state: Dictionary) -> Array:
	var packages: Array = []
	for package_id_value in actor_state.get("package_ids", []):
		var package_id := _canonical_form_id(package_id_value)
		if actor_packages_by_id.has(package_id):
			packages.append(actor_packages_by_id[package_id])
	return packages


func _offscreen_condition_context(ref_id: String, wrapper: Dictionary,
		placement: Dictionary, hour: float) -> Dictionary:
	var context := runtime_condition_context.duplicate(true)
	context["game_hour"] = fposmod(hour, 24.0)
	context["actor_ref"] = ref_id
	context["actor_base"] = _canonical_form_id(placement.get(
		"base_form_id", placement.get("base_form", placement.get("base", ""))))
	context["actor_cell"] = _canonical_form_id(wrapper.get("cell", ""))
	context["actor_linked_reference"] = _canonical_form_id(placement.get("linked_reference", ""))
	context["actor_interior"] = bool(placement.get("_runtime_interior", false))
	context["actor_scope"] = str(placement.get("_runtime_scope", ""))
	context["actor_world"] = ""
	if not bool(context["actor_interior"]):
		var cell_index := cell_indices_by_id.get(context["actor_cell"], {}) as Dictionary
		context["actor_world"] = _canonical_form_id(cell_index.get("world_form_id", primary_world_id))
	context["random_percent"] = float(abs(ref_id.hash()) % 100)
	context["actor_position"] = wrapper.get("position", Vector3.ZERO)
	context["actor_is_creature"] = str(placement.get("type", "")).to_upper() == "CREA" \
		or "creature" in str(placement.get("category",
			(placement.get("_runtime_actor", {}) as Dictionary).get("category", "")))
	context["reference_position_resolver"] = Callable(self, "_runtime_reference_position")
	context["reference_cell_resolver"] = Callable(self, "_runtime_reference_cell")
	return context


func _advance_single_offscreen_schedule(ref_id_value: String, hour: float,
		game_minute: float) -> bool:
	var ref_id := _canonical_form_id(ref_id_value)
	if not offscreen_actor_states.has(ref_id):
		return false
	var wrapper := (offscreen_actor_states[ref_id] as Dictionary).duplicate(true)
	var original_cell := _canonical_form_id(wrapper.get("cell", ""))
	var original_position: Variant = wrapper.get("position", null)
	var placement := (wrapper.get("placement", {}) as Dictionary).duplicate(true)
	var original_transform: Variant = placement.get("_runtime_restore_transform", null)
	var actor_state := (placement.get("_runtime_actor_state", {}) as Dictionary).duplicate(true)
	var packages := _offscreen_package_list(actor_state)
	var context := _offscreen_condition_context(ref_id, wrapper, placement, hour)
	context["current_package"] = str(actor_state.get("active_package_id", ""))
	var selection := PACKAGE_RUNTIME.select_package_result(packages, hour, context)
	var selected := selection.get("package", {}) as Dictionary
	if not bool(selection.get("supported", true)):
		offscreen_schedule_counters.unsupported_selections += 1
	if selected.is_empty():
		offscreen_schedule_counters.no_selections += 1
		var had_package := not _canonical_form_id(actor_state.get("active_package_id", "")).is_empty()
		var idle_intent := PACKAGE_RUNTIME.describe_intent({}, "")
		_apply_offscreen_intent(actor_state, idle_intent, wrapper, placement)
		if had_package:
			actor_state["schedule_epoch"] = int(actor_state.get("schedule_epoch", 0)) + 1
			actor_state["navigation_target_serial"] = int(actor_state.get("navigation_target_serial", 0)) + 1
			offscreen_schedule_counters.package_changes += 1
	else:
		var actor_linked_seed := _canonical_form_id(actor_state.get(
			"actor_linked_seed", placement.get("linked_reference", "")))
		var intent := PACKAGE_RUNTIME.describe_intent(selected, actor_linked_seed)
		var selected_id := _canonical_form_id(intent.get("package_id", ""))
		var package_changed := selected_id != _canonical_form_id(actor_state.get("active_package_id", ""))
		if package_changed:
			_apply_offscreen_intent(actor_state, intent, wrapper, placement)
			actor_state["patrol_current_ref"] = actor_state["travel_target_ref"]
			actor_state["schedule_epoch"] = int(actor_state.get("schedule_epoch", 0)) + 1
			actor_state["navigation_target_serial"] = int(actor_state.get("navigation_target_serial", 0)) + 1
			offscreen_schedule_counters.package_changes += 1
		elif bool(actor_state.get("patrol_route_mode", false)) and original_position is Vector3:
			var current_ref := _canonical_form_id(actor_state.get(
				"patrol_current_ref", actor_state.get("travel_target_ref", "")))
			var marker_position: Variant = _runtime_reference_position(current_ref)
			var actor_scope := str(placement.get("_runtime_scope", ""))
			if marker_position is Vector3 and _runtime_reference_scope(current_ref) == actor_scope:
				var arrival_distance := maxf(0.1, float(actor_state.get("target_desired_distance", 0.7)))
				if (original_position as Vector3).distance_to(marker_position as Vector3) <= arrival_distance:
					var next_ref := _runtime_reference_link(current_ref)
					if not next_ref.is_empty() and _runtime_reference_position(next_ref) is Vector3:
						actor_state["travel_target_ref"] = next_ref
						actor_state["patrol_current_ref"] = next_ref
						actor_state["patrol_hops"] = int(actor_state.get("patrol_hops", 0)) + 1
						actor_state["navigation_target_serial"] = int(actor_state.get("navigation_target_serial", 0)) + 1
						offscreen_schedule_counters.patrol_advances += 1
	actor_state["last_schedule_game_minute"] = game_minute
	actor_state["schema"] = "opennv-actor-runtime-state/v2"
	actor_state["simulation_mode"] = "schedule_only"
	placement["_runtime_actor_state"] = actor_state
	wrapper["placement"] = placement
	# Schedule-only simulation is never authorized to fabricate traversal.
	if _canonical_form_id(wrapper.get("cell", "")) != original_cell \
			or wrapper.get("position", null) != original_position \
			or placement.get("_runtime_restore_transform", null) != original_transform:
		offscreen_schedule_counters.spatial_updates += 1
		return false
	offscreen_actor_states[ref_id] = wrapper
	offscreen_schedule_counters.states_processed += 1
	return true


func _apply_offscreen_intent(actor_state: Dictionary, intent: Dictionary,
		wrapper: Dictionary, placement: Dictionary) -> void:
	actor_state["active_package_id"] = _canonical_form_id(intent.get("package_id", ""))
	actor_state["package_type"] = int(intent.get("package_type", -1))
	actor_state["activity_state"] = str(intent.get("activity_state", "idle"))
	actor_state["activity_on_arrival"] = str(intent.get("activity_on_arrival", "idle"))
	actor_state["travel_target_ref"] = _canonical_form_id(intent.get("travel_target_ref", ""))
	actor_state["patrol_route_mode"] = bool(intent.get("patrol_route_mode", false))
	actor_state["wander_center_ref"] = _canonical_form_id(intent.get("wander_center_ref", ""))
	actor_state["flee_mode"] = bool(intent.get("flee_mode", false))
	actor_state["direct_travel_target_enabled"] = bool(intent.get("direct_travel_target_enabled", false))
	actor_state["target_desired_distance"] = float(intent.get("target_desired_distance", 0.7))
	var direct_mode := str(intent.get("direct_target_mode", ""))
	if direct_mode == "current":
		actor_state["travel_target_position"] = wrapper.get("position", Vector3.ZERO)
	elif direct_mode == "editor":
		var restore_transform := placement.get("_runtime_restore_transform", Transform3D.IDENTITY) as Transform3D
		actor_state["travel_target_position"] = actor_state.get("authored_spawn_position",
			restore_transform.origin)
	else:
		actor_state["travel_target_position"] = Vector3.ZERO


func _advance_offscreen_actor_schedules(hour: float, game_minute: float,
		batch_size: int = OFFSCREEN_SCHEDULE_BATCH) -> int:
	var refs: Array = offscreen_actor_states.keys()
	refs.sort()
	if refs.is_empty() or batch_size <= 0:
		return 0
	var started_usec := Time.get_ticks_usec()
	var processed := 0
	var maximum := mini(batch_size, refs.size())
	while processed < maximum:
		var index := (offscreen_schedule_cursor + processed) % refs.size()
		var ref_id := _canonical_form_id(refs[index])
		if not pending_offscreen_actor_refs.has(ref_id):
			_advance_single_offscreen_schedule(ref_id, hour, game_minute)
		processed += 1
		if Time.get_ticks_usec() - started_usec >= OFFSCREEN_SCHEDULE_BUDGET_USEC:
			break
	offscreen_schedule_cursor = (offscreen_schedule_cursor + processed) % refs.size()
	offscreen_schedule_counters.ticks += 1
	offscreen_schedule_counters.max_tick_usec = maxi(
		int(offscreen_schedule_counters.max_tick_usec), Time.get_ticks_usec() - started_usec)
	return processed


func _sync_offscreen_actor_schedule(ref_id_value: String) -> void:
	var ref_id := _canonical_form_id(ref_id_value)
	if not offscreen_actor_states.has(ref_id):
		return
	var wrapper := offscreen_actor_states[ref_id] as Dictionary
	var actor_state := ((wrapper.get("placement", {}) as Dictionary).get(
		"_runtime_actor_state", {}) as Dictionary)
	if float(actor_state.get("last_schedule_game_minute", -1.0)) < runtime_game_minute:
		_advance_single_offscreen_schedule(ref_id,
			float(runtime_condition_context.get("game_hour", 9.0)), runtime_game_minute)


func _refresh_queued_offscreen_actor_state(placement: Dictionary) -> void:
	var ref_id := _canonical_form_id(placement.get("_runtime_offscreen_ref", ""))
	if ref_id.is_empty() or not offscreen_actor_states.has(ref_id):
		return
	# Asset I/O may span an authored schedule boundary. Refresh atomically at
	# commit so a stale queued copy can never overwrite the canonical wrapper.
	_sync_offscreen_actor_schedule(ref_id)
	var wrapper := offscreen_actor_states[ref_id] as Dictionary
	var latest := wrapper.get("placement", {}) as Dictionary
	placement["_runtime_actor_state"] = (latest.get("_runtime_actor_state", {}) as Dictionary).duplicate(true)
	if latest.has("_runtime_restore_transform"):
		placement["_runtime_restore_transform"] = latest["_runtime_restore_transform"]


func _stream_exterior_neighborhood(focus_grid: Vector2i, linked_interiors: Dictionary, initial: bool, world_id_value: String = "") -> int:
	var world_id := _canonical_form_id(world_id_value)
	if world_id.is_empty():
		world_id = primary_world_id
	var runtime_origin := _world_runtime_origin(world_id, focus_grid)
	var runtime_scope := _world_scope(world_id)
	if not initial:
		return _queue_exterior_neighborhood_jobs(focus_grid, world_id, runtime_origin, runtime_scope)
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
						_queue_placement(placement, str(cell.get("form_id", "")), runtime_origin, Vector3.ZERO, false, runtime_scope, distance)
						_collect_destination_interior(placement, linked_interiors)
				elif needs_actors:
					for placement_value in cell.get("placements", []):
						var placement := placement_value as Dictionary
						if str(placement.get("base_type", "")) in ["NPC_", "CREA"]:
							_queue_placement(placement, cell_id, runtime_origin, Vector3.ZERO, false, runtime_scope, distance)
				if needs_actors:
					_queue_offscreen_actors_for_cell(cell_id, runtime_origin, Vector3.ZERO,
						false, runtime_scope, distance)
					_load_navmesh_cell(cell_id, runtime_origin, Vector3.ZERO, runtime_scope)
					loaded_actor_cells[cell_id] = true
	if initial:
		last_focus_grid = focus_grid
	return queued_cells


func _queue_exterior_neighborhood_jobs(focus_grid: Vector2i, world_id: String,
		runtime_origin: Vector3, runtime_scope: String) -> int:
	# Reversals cancel work that can no longer enter the retained visual ring.
	for cell_id_value in pending_exterior_cell_jobs.keys():
		var stale_job := pending_exterior_cell_jobs[cell_id_value] as Dictionary
		var stale_index := stale_job.get("index", {}) as Dictionary
		var stale_grid_values := stale_index.get("grid", [2147483647, 2147483647]) as Array
		var stale_grid := Vector2i(int(stale_grid_values[0]), int(stale_grid_values[1]))
		var stale_distance := maxi(absi(stale_grid.x - focus_grid.x), absi(stale_grid.y - focus_grid.y))
		if _canonical_form_id(stale_job.get("world", "")) != world_id or stale_distance > TERRAIN_VISUAL_RADIUS:
			pending_exterior_cell_jobs.erase(cell_id_value)
	var queued := 0
	for y in range(focus_grid.y - TERRAIN_VISUAL_RADIUS, focus_grid.y + TERRAIN_VISUAL_RADIUS + 1):
		for x in range(focus_grid.x - TERRAIN_VISUAL_RADIUS, focus_grid.x + TERRAIN_VISUAL_RADIUS + 1):
			var grid := Vector2i(x, y)
			var distance := maxi(absi(x - focus_grid.x), absi(y - focus_grid.y))
			for index_value in cell_indices_by_grid.get(_world_grid_key(world_id, grid), []) as Array:
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
				var prior := pending_exterior_cell_jobs.get(cell_id, {}) as Dictionary
				var queued_job := {
					"cell_id": cell_id, "index": cell_index, "world": world_id,
					"origin": runtime_origin, "scope": runtime_scope,
					"distance": mini(distance, int(prior.get("distance", distance))),
					"terrain": needs_terrain or bool(prior.get("terrain", false)),
					"detail": needs_detail or bool(prior.get("detail", false)),
					"actors": needs_actors or bool(prior.get("actors", false)),
				}
				for runtime_key in ["_shard_task", "_cell"]:
					if prior.has(runtime_key):
						queued_job[runtime_key] = prior[runtime_key]
				pending_exterior_cell_jobs[cell_id] = queued_job
				if prior.is_empty():
					queued += 1
	if queued > 0:
		set_process(true)
	return queued


func _schedule_exterior_focus_scan(focus_grid: Vector2i, world_id_value: String) -> void:
	var world_id := _canonical_form_id(world_id_value)
	pending_focus_scan_grid = focus_grid
	pending_focus_scan_world = world_id
	pending_focus_scan_origin = _world_runtime_origin(world_id, focus_grid)
	pending_focus_scan_scope = _world_scope(world_id)
	pending_focus_scan_cursor = 0


func _process_exterior_focus_scan_row() -> void:
	if pending_focus_scan_cursor < 0:
		return
	var y := pending_focus_scan_grid.y - TERRAIN_VISUAL_RADIUS + pending_focus_scan_cursor
	for x in range(pending_focus_scan_grid.x - TERRAIN_VISUAL_RADIUS,
			pending_focus_scan_grid.x + TERRAIN_VISUAL_RADIUS + 1):
		_queue_exterior_grid_jobs(Vector2i(x, y), pending_focus_scan_grid,
			pending_focus_scan_world, pending_focus_scan_origin, pending_focus_scan_scope)
	pending_focus_scan_cursor += 1
	if pending_focus_scan_cursor > TERRAIN_VISUAL_RADIUS * 2:
		pending_focus_scan_cursor = -1


func _queue_exterior_grid_jobs(grid: Vector2i, focus_grid: Vector2i, world_id: String,
		runtime_origin: Vector3, runtime_scope: String) -> void:
	var distance := maxi(absi(grid.x - focus_grid.x), absi(grid.y - focus_grid.y))
	for index_value in cell_indices_by_grid.get(_world_grid_key(world_id, grid), []) as Array:
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
		var prior := pending_exterior_cell_jobs.get(cell_id, {}) as Dictionary
		var queued_job := {
			"cell_id": cell_id, "index": cell_index, "world": world_id,
			"origin": runtime_origin, "scope": runtime_scope,
			"distance": mini(distance, int(prior.get("distance", distance))),
			"terrain": needs_terrain or bool(prior.get("terrain", false)),
			"detail": needs_detail or bool(prior.get("detail", false)),
			"actors": needs_actors or bool(prior.get("actors", false)),
		}
		for runtime_key in ["_shard_task", "_cell"]:
			if prior.has(runtime_key):
				queued_job[runtime_key] = prior[runtime_key]
		pending_exterior_cell_jobs[cell_id] = queued_job


func _pop_exterior_cell_job() -> Dictionary:
	var best_id := ""
	var best_distance := 2147483647
	for cell_id_value in pending_exterior_cell_jobs.keys():
		var job := pending_exterior_cell_jobs[cell_id_value] as Dictionary
		if job.has("_shard_task") and not WorkerThreadPool.is_task_completed(int(job._shard_task)):
			continue
		var terrain_paths := job.get("_terrain_loading_paths", []) as Array
		var terrain_loading := false
		for terrain_path_value in terrain_paths:
			if ResourceLoader.load_threaded_get_status(str(terrain_path_value)) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				terrain_loading = true
				break
		if terrain_loading:
			continue
		var index := job.get("index", {}) as Dictionary
		var grid_values := index.get("grid", [2147483647, 2147483647]) as Array
		var grid := Vector2i(int(grid_values[0]), int(grid_values[1]))
		var distance := maxi(absi(grid.x - last_focus_grid.x), absi(grid.y - last_focus_grid.y))
		if distance < best_distance:
			best_id = str(cell_id_value)
			best_distance = distance
	var result := pending_exterior_cell_jobs.get(best_id, {}) as Dictionary
	pending_exterior_cell_jobs.erase(best_id)
	return result


func _commit_exterior_cell_job(job: Dictionary) -> void:
	if job.is_empty():
		return
	var cell_id := _canonical_form_id(job.get("cell_id", ""))
	var cell_index := job.get("index", {}) as Dictionary
	var runtime_origin := job.get("origin", Vector3.ZERO) as Vector3
	var runtime_scope := str(job.get("scope", EXTERIOR_SCOPE))
	var distance := int(job.get("distance", TERRAIN_VISUAL_RADIUS))
	var grid_values := cell_index.get("grid", [2147483647, 2147483647]) as Array
	var grid := Vector2i(int(grid_values[0]), int(grid_values[1]))
	var current_distance := maxi(absi(grid.x - last_focus_grid.x), absi(grid.y - last_focus_grid.y))
	if _canonical_form_id(job.get("world", "")) != active_exterior_world_id \
			or current_distance > TERRAIN_VISUAL_RADIUS:
		return
	distance = current_distance
	var needs_terrain := bool(job.get("terrain", false)) and (
		not loaded_terrain_cells.has(cell_id)
		or (distance <= TERRAIN_COLLISION_RADIUS and not terrain_collision_cells.has(cell_id)))
	var needs_detail := bool(job.get("detail", false)) and current_distance <= ROUTE_PRELOAD_RADIUS \
		and not loaded_detail_cells.has(cell_id)
	var needs_actors := bool(job.get("actors", false)) and current_distance <= ACTOR_VISUAL_RADIUS \
		and not loaded_actor_cells.has(cell_id)
	if not needs_terrain and not needs_detail and not needs_actors:
		return
	var phase_started := Time.get_ticks_usec()
	var cell: Dictionary
	if job.has("_cell"):
		cell = job._cell as Dictionary
	else:
		var shard_path := str(cell_index.get("shard", ""))
		if not shard_path.is_empty():
			if not job.has("_shard_task"):
				job["_shard_task"] = WorkerThreadPool.add_task(
					_read_exterior_shard_worker.bind(cell_id, shard_path), true,
					"OpenNV cell %s" % cell_id)
				pending_exterior_cell_jobs[cell_id] = job
				return
			if not WorkerThreadPool.is_task_completed(int(job._shard_task)):
				pending_exterior_cell_jobs[cell_id] = job
				return
			WorkerThreadPool.wait_for_task_completion(int(job._shard_task))
			job.erase("_shard_task")
			exterior_shard_worker_mutex.lock()
			var shard_result: Variant = exterior_shard_worker_results.get(cell_id, {})
			exterior_shard_worker_results.erase(cell_id)
			exterior_shard_worker_mutex.unlock()
			cell = (shard_result as Dictionary) if shard_result is Dictionary else {}
			if cell.is_empty():
				push_warning("OPENNV_CELL_SHARD_MISSING %s" % shard_path)
				cell = cell_index.duplicate(true)
		else:
			cell = cell_index.duplicate(true)
		job["_cell"] = cell
	max_cell_shard_usec = maxi(max_cell_shard_usec, Time.get_ticks_usec() - phase_started)
	cell["_runtime_origin"] = [runtime_origin.x, runtime_origin.y, runtime_origin.z]
	cell["_runtime_scope"] = runtime_scope
	var prepared_terrain_mesh: ArrayMesh = null
	var prepared_terrain_texture: Texture2D = null
	if needs_terrain and cell.has("terrain"):
		var terrain_step := 1 if distance <= TERRAIN_COLLISION_RADIUS else (4 if distance <= 12 else 8)
		var terrain_mesh_path := _terrain_mesh_cache_path(cell_id, terrain_step)
		var terrain_texture_path := _terrain_baked_albedo_path(cell, distance <= TERRAIN_COLLISION_RADIUS)
		if not job.has("_terrain_loading_paths"):
			var loading_paths: Array[String] = []
			if ResourceLoader.exists(terrain_mesh_path) \
					and ResourceLoader.load_threaded_request(terrain_mesh_path, "ArrayMesh", true) == OK:
				loading_paths.append(terrain_mesh_path)
			if not terrain_texture_path.is_empty() and not terrain_albedo_cache.has(terrain_texture_path) \
					and ResourceLoader.exists(terrain_texture_path) \
					and ResourceLoader.load_threaded_request(terrain_texture_path, "Texture2D", true) == OK:
				loading_paths.append(terrain_texture_path)
			job["_terrain_loading_paths"] = loading_paths
			job["_terrain_mesh_path"] = terrain_mesh_path
			job["_terrain_texture_path"] = terrain_texture_path
			job["_cell"] = cell
			pending_exterior_cell_jobs[cell_id] = job
			return
		for terrain_path_value in job.get("_terrain_loading_paths", []):
			var terrain_path := str(terrain_path_value)
			var status := ResourceLoader.load_threaded_get_status(terrain_path)
			if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				pending_exterior_cell_jobs[cell_id] = job
				return
			if status != ResourceLoader.THREAD_LOAD_LOADED:
				if terrain_path == terrain_mesh_path:
					terrain_mesh_cache_fallback_paths["%s|%d" % [cell_id, terrain_step]] = true
				continue
			var loaded_resource := ResourceLoader.load_threaded_get(terrain_path)
			if terrain_path == terrain_mesh_path:
				prepared_terrain_mesh = loaded_resource as ArrayMesh
			elif loaded_resource is Texture2D:
				prepared_terrain_texture = loaded_resource as Texture2D
				terrain_albedo_cache[terrain_path] = prepared_terrain_texture
				terrain_albedo_lru.erase(terrain_path)
				terrain_albedo_lru.append(terrain_path)
				_trim_terrain_albedo_cache()
		if prepared_terrain_mesh == null and ResourceLoader.exists(terrain_mesh_path):
			prepared_terrain_mesh = ResourceLoader.load(terrain_mesh_path) as ArrayMesh
	if needs_terrain and cell.has("terrain"):
		phase_started = Time.get_ticks_usec()
		_add_terrain(cell, distance, false, prepared_terrain_mesh, prepared_terrain_texture)
		var terrain_elapsed := Time.get_ticks_usec() - phase_started
		max_cell_terrain_usec = maxi(max_cell_terrain_usec, terrain_elapsed)
		if terrain_elapsed > 16000:
			print("OPENNV_TERRAIN_COMMIT_SLOW cell=%s distance=%d usec=%d collision=%s" % [
				cell_id, distance, terrain_elapsed, str(distance <= TERRAIN_COLLISION_RADIUS)])
		loaded_terrain_cells[cell_id] = true
	var linked_interiors := job.get("_linked_interiors", {}) as Dictionary
	if needs_detail:
		phase_started = Time.get_ticks_usec()
		var placements := cell.get("placements", []) as Array
		var placement_cursor := int(job.get("_placement_cursor", 0))
		while placement_cursor < placements.size() \
				and Time.get_ticks_usec() - phase_started < 1000:
			var placement := placements[placement_cursor] as Dictionary
			placement_cursor += 1
			if str(placement.get("base_type", "")) in ["NPC_", "CREA"] and not needs_actors:
				continue
			_queue_placement(placement, cell_id, runtime_origin, Vector3.ZERO, false,
				runtime_scope, distance)
			_collect_destination_interior(placement, linked_interiors)
		max_cell_placements_usec = maxi(max_cell_placements_usec, Time.get_ticks_usec() - phase_started)
		if placement_cursor < placements.size():
			job["_cell"] = cell
			job["_placement_cursor"] = placement_cursor
			job["_linked_interiors"] = linked_interiors
			pending_exterior_cell_jobs[cell_id] = job
			return
		job.erase("_placement_cursor")
		job.erase("_linked_interiors")
		loaded_detail_cells[cell_id] = true
		deferred_route_cells.erase(cell_id)
		resident_cells += 1
	elif needs_actors:
		phase_started = Time.get_ticks_usec()
		var placements := cell.get("placements", []) as Array
		var placement_cursor := int(job.get("_actor_placement_cursor", 0))
		while placement_cursor < placements.size() \
				and Time.get_ticks_usec() - phase_started < 1000:
			var placement := placements[placement_cursor] as Dictionary
			placement_cursor += 1
			if str(placement.get("base_type", "")) in ["NPC_", "CREA"]:
				_queue_placement(placement, cell_id, runtime_origin, Vector3.ZERO, false,
					runtime_scope, distance)
		max_cell_placements_usec = maxi(max_cell_placements_usec, Time.get_ticks_usec() - phase_started)
		if placement_cursor < placements.size():
			job["_cell"] = cell
			job["_actor_placement_cursor"] = placement_cursor
			pending_exterior_cell_jobs[cell_id] = job
			return
		job.erase("_actor_placement_cursor")
	if needs_actors:
		phase_started = Time.get_ticks_usec()
		_queue_offscreen_actors_for_cell(cell_id, runtime_origin, Vector3.ZERO, false,
			runtime_scope, distance)
		_load_navmesh_cell(cell_id, runtime_origin, Vector3.ZERO, runtime_scope)
		loaded_actor_cells[cell_id] = true
		max_cell_navmesh_usec = maxi(max_cell_navmesh_usec, Time.get_ticks_usec() - phase_started)
	phase_started = Time.get_ticks_usec()
	for linked_cell_value in linked_interiors:
		_stage_interior(str(linked_cell_value))
	max_cell_interior_stage_usec = maxi(max_cell_interior_stage_usec, Time.get_ticks_usec() - phase_started)


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


func _flush_ready_placements(max_paths: int = 1, budget_usec: int = STREAM_COMMIT_BUDGET_USEC) -> void:
	var started := Time.get_ticks_usec()
	var processed := 0
	for path_value in ready_placements.keys():
		if processed >= max_paths or (processed > 0 and Time.get_ticks_usec() - started >= budget_usec):
			break
		var path := str(path_value)
		if mesh_cache.has(path):
			_add_placements(mesh_cache[path] as Mesh, ready_placements[path] as Array)
		ready_placements.erase(path)
		processed += 1


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
		_queue_exterior_retirement(cell_id, index, true, false)
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
		_queue_exterior_retirement(cell_id, index, false, true)
	set_process(true)


func _queue_exterior_retirement(cell_id: String, index: Dictionary,
		detail: bool, terrain: bool) -> void:
	var job := pending_exterior_retire_jobs.get(cell_id, {}) as Dictionary
	job["cell"] = cell_id
	job["index"] = index
	job["detail"] = detail or bool(job.get("detail", false))
	job["terrain"] = terrain or bool(job.get("terrain", false))
	pending_exterior_retire_jobs[cell_id] = job


func _pump_exterior_retire_jobs() -> bool:
	if pending_exterior_retire_jobs.is_empty():
		return false
	var cell_id := _canonical_form_id(pending_exterior_retire_jobs.keys()[0])
	var job := pending_exterior_retire_jobs[cell_id] as Dictionary
	var index := job.get("index", {}) as Dictionary
	var values := index.get("grid", []) as Array
	if values.size() < 2:
		pending_exterior_retire_jobs.erase(cell_id)
		return true
	var grid := Vector2i(int(values[0]), int(values[1]))
	var distance := maxi(absi(grid.x - last_focus_grid.x), absi(grid.y - last_focus_grid.y))
	var world_id := _canonical_form_id(index.get("world_form_id", ""))
	if world_id == active_exterior_world_id:
		if distance <= DETAIL_KEEP_RADIUS and not bool(job.get("detail_started", false)):
			job["detail"] = false
		if distance <= TERRAIN_KEEP_RADIUS:
			job["terrain"] = false
	var started := Time.get_ticks_usec()
	if bool(job.get("detail", false)):
		if not bool(job.get("detail_started", false)):
			_drop_pending_cell_placements(cell_id)
			job["detail_started"] = true
		var nodes := stream_nodes_by_cell.get(cell_id, []) as Array
		while not nodes.is_empty() and Time.get_ticks_usec() - started < 1000:
			var node_value: Variant = nodes.pop_back()
			if not is_instance_valid(node_value):
				continue
			var node := node_value as Node
			resident_instances = maxi(0, resident_instances - int(node.get_meta("opennv_stream_instance_count", 0)))
			if node.has_meta("fnv_actor_id"):
				_capture_offscreen_actor_state(node as Node3D)
				resident_actors = maxi(0, resident_actors - 1)
			_release_stream_mesh_ref(node)
			_unregister_scope_node(node)
			if node.has_meta("fnv_form_id"):
				var form_id := _canonical_form_id(node.get_meta("fnv_form_id", ""))
				door_nodes_by_form_id.erase(form_id)
				actor_nodes_by_form_id.erase(form_id)
			node.queue_free()
		if not nodes.is_empty():
			pending_exterior_retire_jobs[cell_id] = job
			return true
		stream_nodes_by_cell.erase(cell_id)
		_drop_cell_reference_positions(cell_id)
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
		job["detail"] = false
		if world_id == active_exterior_world_id and distance <= ROUTE_PRELOAD_RADIUS:
			_queue_exterior_grid_jobs(grid, last_focus_grid, active_exterior_world_id,
				_world_runtime_origin(active_exterior_world_id), _world_scope(active_exterior_world_id))
	if bool(job.get("terrain", false)) and Time.get_ticks_usec() - started < 1000:
		if terrain_visual_by_cell.has(cell_id):
			var visual := terrain_visual_by_cell[cell_id] as Node
			if is_instance_valid(visual):
				_unregister_scope_node(visual)
				visual.queue_free()
			terrain_visual_by_cell.erase(cell_id)
		if terrain_body_by_cell.has(cell_id):
			var body := terrain_body_by_cell[cell_id] as Node
			if is_instance_valid(body):
				_unregister_scope_node(body)
				body.queue_free()
			terrain_body_by_cell.erase(cell_id)
		terrain_collision_cells.erase(cell_id)
		loaded_terrain_cells.erase(cell_id)
		resident_terrain_cells = maxi(0, resident_terrain_cells - 1)
		job["terrain"] = false
	if not bool(job.get("detail", false)) and not bool(job.get("terrain", false)):
		pending_exterior_retire_jobs.erase(cell_id)
	else:
		pending_exterior_retire_jobs[cell_id] = job
	var elapsed := Time.get_ticks_usec() - started
	max_stream_commit_usec = maxi(max_stream_commit_usec, elapsed)
	stream_commit_samples += 1
	return true


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
			_capture_offscreen_actor_state(node as Node3D)
			resident_instances = maxi(0, resident_instances - int(node.get_meta("opennv_stream_instance_count", 0)))
			resident_actors = maxi(0, resident_actors - 1)
			_release_stream_mesh_ref(node)
			_unregister_scope_node(node)
			var form_id := _canonical_form_id(node.get_meta("fnv_form_id", ""))
			actor_nodes_by_form_id.erase(form_id)
			node.queue_free()
		actor_nodes_by_cell.erase(cell_id)
		actor_visual_status_by_cell.erase(cell_id)
		loaded_actor_cells.erase(cell_id)
		_retire_navmesh_cell(cell_id)


func _migrate_exterior_actor_ownership(world_id_value: String) -> void:
	var world_id := _canonical_form_id(world_id_value)
	var runtime_origin := _world_runtime_origin(world_id)
	var expected_scope := _world_scope(world_id)
	for actor_ref_value in actor_nodes_by_form_id.keys():
		var actor_ref := _canonical_form_id(actor_ref_value)
		var actor_value: Variant = actor_nodes_by_form_id.get(actor_ref)
		if not is_instance_valid(actor_value):
			actor_nodes_by_form_id.erase(actor_ref)
			continue
		var actor := actor_value as Node3D
		if str(actor.get_meta("opennv_runtime_scope", "")) != expected_scope:
			continue
		var atlas_position := runtime_origin + _godot_vector_to_source(actor.global_position * UNITS_PER_METER)
		var grid := Vector2i(floori(atlas_position.x / 4096.0), floori(atlas_position.y / 4096.0))
		var candidates := cell_indices_by_grid.get(_world_grid_key(world_id, grid), []) as Array
		var target_cell := ""
		for candidate_value in candidates:
			var candidate := candidate_value as Dictionary
			if _canonical_form_id(candidate.get("world_form_id", "")) == world_id:
				target_cell = _canonical_form_id(candidate.get("form_id", ""))
				break
		if target_cell.is_empty():
			continue
		if not loaded_actor_cells.has(target_cell):
			_queue_actor_cell_promotion(target_cell, world_id)
			continue
		var old_cell := _canonical_form_id(actor.get_meta("opennv_runtime_cell", ""))
		if old_cell.is_empty() or old_cell == target_cell:
			continue
		(stream_nodes_by_cell.get(old_cell, []) as Array).erase(actor)
		(actor_nodes_by_cell.get(old_cell, []) as Array).erase(actor)
		if not stream_nodes_by_cell.has(target_cell):
			stream_nodes_by_cell[target_cell] = []
		if not (stream_nodes_by_cell[target_cell] as Array).has(actor):
			(stream_nodes_by_cell[target_cell] as Array).append(actor)
		if not actor_nodes_by_cell.has(target_cell):
			actor_nodes_by_cell[target_cell] = []
		if not (actor_nodes_by_cell[target_cell] as Array).has(actor):
			(actor_nodes_by_cell[target_cell] as Array).append(actor)
		var ref_id := _canonical_form_id(actor.get_meta("fnv_form_id", ""))
		(reference_ids_by_cell.get(old_cell, []) as Array).erase(ref_id)
		if not reference_ids_by_cell.has(target_cell):
			reference_ids_by_cell[target_cell] = []
		if not (reference_ids_by_cell[target_cell] as Array).has(ref_id):
			(reference_ids_by_cell[target_cell] as Array).append(ref_id)
		reference_runtime_cells[ref_id] = target_cell
		var old_status := actor_visual_status_by_cell.get(old_cell, {}) as Dictionary
		var visual_status := str(old_status.get(ref_id, "exact"))
		old_status.erase(ref_id)
		if not actor_visual_status_by_cell.has(target_cell):
			actor_visual_status_by_cell[target_cell] = {}
		(actor_visual_status_by_cell[target_cell] as Dictionary)[ref_id] = visual_status
		actor.set_meta("opennv_runtime_cell", target_cell)
		if actor.has_method("update_runtime_cell"):
			actor.call("update_runtime_cell", target_cell, expected_scope, false)
		actor_lifecycle_counters.migrations += 1


func _promote_actor_cell_residency(cell_id_value: String, world_id_value: String) -> bool:
	var cell_id := _canonical_form_id(cell_id_value)
	var world_id := _canonical_form_id(world_id_value)
	if not _cell_within_player_actor_radius(cell_id, world_id):
		return false
	if loaded_actor_cells.has(cell_id):
		return true
	if not cell_indices_by_id.has(cell_id):
		return false
	var index := cell_indices_by_id[cell_id] as Dictionary
	if _canonical_form_id(index.get("world_form_id", "")) != world_id:
		return false
	var runtime_origin := _world_runtime_origin(world_id)
	var runtime_scope := _world_scope(world_id)
	var cell := _materialize_shard(index) as Dictionary
	for placement_value in cell.get("placements", []):
		var placement := placement_value as Dictionary
		if str(placement.get("base_type", "")) in ["NPC_", "CREA"]:
			_queue_placement(placement, cell_id, runtime_origin, Vector3.ZERO, false, runtime_scope, ACTOR_VISUAL_RADIUS)
	_queue_offscreen_actors_for_cell(cell_id, runtime_origin, Vector3.ZERO, false, runtime_scope, ACTOR_VISUAL_RADIUS)
	_load_navmesh_cell(cell_id, runtime_origin, Vector3.ZERO, runtime_scope)
	loaded_actor_cells[cell_id] = true
	set_process(true)
	if threaded_loading:
		_pump_threaded_requests()
	var player_grid := _player_grid_for_world(world_id)
	if player_grid.x != 2147483647:
		_evict_actors_outside(player_grid, world_id)
	return true


func _queue_actor_cell_promotion(cell_id_value: String, world_id_value: String) -> void:
	var cell_id := _canonical_form_id(cell_id_value)
	var world_id := _canonical_form_id(world_id_value)
	if cell_id.is_empty() or loaded_actor_cells.has(cell_id) or pending_actor_cell_promotion_ids.has(cell_id) \
			or not _cell_within_player_actor_radius(cell_id, world_id):
		return
	pending_actor_cell_promotion_ids[cell_id] = true
	pending_actor_cell_promotions.append({"cell": cell_id, "world": world_id})
	set_process(true)


func _player_grid_for_world(world_id_value: Variant) -> Vector2i:
	var world_id := _canonical_form_id(world_id_value)
	if world_id.is_empty() or world_id != active_exterior_world_id:
		return Vector2i(2147483647, 2147483647)
	var world_origin := _world_runtime_origin(world_id)
	var atlas_position := world_origin + _godot_vector_to_source(player_runtime_position * UNITS_PER_METER)
	return Vector2i(floori(atlas_position.x / 4096.0), floori(atlas_position.y / 4096.0))


func _cell_within_player_actor_radius(cell_id_value: Variant, world_id_value: Variant) -> bool:
	var cell_id := _canonical_form_id(cell_id_value)
	var world_id := _canonical_form_id(world_id_value)
	var index := cell_indices_by_id.get(cell_id, {}) as Dictionary
	var grid_values := index.get("grid", []) as Array
	var player_grid := _player_grid_for_world(world_id)
	if grid_values.size() < 2 or player_grid.x == 2147483647:
		return false
	var grid := Vector2i(int(grid_values[0]), int(grid_values[1]))
	return maxi(absi(grid.x - player_grid.x), absi(grid.y - player_grid.y)) <= ACTOR_KEEP_RADIUS


func _resident_actor_visual_coverage() -> Dictionary:
	var result := {"expected": 0, "exact": 0, "fallback": 0, "missing": 0}
	for status_values in actor_visual_status_by_cell.values():
		for ref_value in (status_values as Dictionary).keys():
			var ref_id := _canonical_form_id(ref_value)
			if not _headless_fast_residency():
				var actor := actor_nodes_by_form_id.get(ref_id) as Node
				if not is_instance_valid(actor):
					continue
			var status_value: Variant = (status_values as Dictionary)[ref_value]
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
	var world_origin := _world_runtime_origin(active_exterior_world_id)
	var atlas_position := world_origin + _godot_vector_to_source(focus_position * UNITS_PER_METER)
	var focus_grid := Vector2i(floori(atlas_position.x / 4096.0), floori(atlas_position.y / 4096.0))
	for y in range(focus_grid.y - 1, focus_grid.y + 2):
		for x in range(focus_grid.x - 1, focus_grid.x + 2):
			var key := _world_grid_key(active_exterior_world_id, Vector2i(x, y))
			for door_ref_value in interior_prefetch_doors_by_grid.get(key, []):
				var door_ref := _canonical_form_id(door_ref_value)
				if not interior_prefetch_doors.has(door_ref):
					continue
				var door := interior_prefetch_doors[door_ref] as Dictionary
				var door_position := _runtime_position_in_cell(
					_source_position(door), _canonical_form_id(door.get("_runtime_cell", "")))
				if door_position.distance_squared_to(focus_position) > INTERIOR_PREFETCH_DISTANCE * INTERIOR_PREFETCH_DISTANCE:
					continue
				var destination_cell := _canonical_form_id(door.get("destination_cell", ""))
				if not destination_cell.is_empty():
					_stage_interior(destination_cell)
	if not pending_paths.is_empty() or not pending_skeletal_placements.is_empty():
		set_process(true)
		if threaded_loading:
			_pump_threaded_requests()


func _compact_scope_registries() -> void:
	for scope_value in visuals_by_scope.keys():
		var compact: Array = []
		for node_value in visuals_by_scope[scope_value]:
			if is_instance_valid(node_value):
				var node := node_value as Node
				if not node.is_queued_for_deletion():
					compact.append(node)
		visuals_by_scope[scope_value] = compact
	for scope_value in collision_bodies_by_scope.keys():
		var compact: Array = []
		for node_value in collision_bodies_by_scope[scope_value]:
			if is_instance_valid(node_value):
				var node := node_value as Node
				if not node.is_queued_for_deletion():
					compact.append(node)
		collision_bodies_by_scope[scope_value] = compact
	for scope_value in audio_players_by_scope.keys():
		var compact_audio: Array = []
		for player_value in audio_players_by_scope[scope_value]:
			if is_instance_valid(player_value):
				var player := player_value as Node
				if not player.is_queued_for_deletion():
					compact_audio.append(player)
		audio_players_by_scope[scope_value] = compact_audio


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
		var cell_id := _canonical_form_id(cell.get("form_id", ""))
		cell["_runtime_origin"] = [source_origin.x, source_origin.y, source_origin.z]
		cell["_runtime_scope"] = EXTERIOR_SCOPE
		if cell.has("terrain") and not loaded_terrain_cells.has(cell_id):
			_add_terrain(cell, 0, true)
			loaded_terrain_cells[cell_id] = true
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
	while not pending_paths.is_empty() or not active_paths.is_empty() \
			or not ready_placements.is_empty() or not pending_skeletal_placements.is_empty():
		await get_tree().process_frame
	print("OPENNV_ROUTE_PRELOAD_READY cells=%d meshes=%d instances=%d" % [queued_cells, mesh_cache.size(), resident_instances])
	route_corridor_ready.emit()


func _install_mesh(path: String, imported_mesh: Mesh) -> void:
	var install_started := Time.get_ticks_usec()
	# Processing is deterministic for a given imported resource. Retain the
	# processed mesh on that resource so unload/reload cycles do not deep-copy
	# tens of megabytes or rebuild collision surface subsets on the frame thread.
	var reused_processed := bool(imported_mesh.get_meta("opennv_runtime_processed", false))
	var mesh := imported_mesh
	if imported_mesh.has_meta("opennv_runtime_processed_mesh"):
		mesh = imported_mesh.get_meta("opennv_runtime_processed_mesh") as Mesh
	var phase_started := Time.get_ticks_usec()
	max_mesh_duplicate_usec = maxi(max_mesh_duplicate_usec, phase_started - install_started)
	if not reused_processed:
		_apply_nif_material_semantics(mesh, path)
	var phase_finished := Time.get_ticks_usec()
	max_mesh_material_usec = maxi(max_mesh_material_usec, phase_finished - phase_started)
	phase_started = phase_finished
	if not reused_processed:
		mesh = _split_render_and_collision_surfaces(mesh, path)
		# Never store a resource as metadata on itself; that creates a reference
		# cycle and leaked RenderingDevice buffers at shutdown.
		if mesh != imported_mesh:
			imported_mesh.set_meta("opennv_runtime_processed_mesh", mesh)
		imported_mesh.set_meta("opennv_runtime_processed", true)
	phase_finished = Time.get_ticks_usec()
	max_mesh_collision_split_usec = maxi(max_mesh_collision_split_usec, phase_finished - phase_started)
	if not mesh.has_meta("opennv_source_path"):
		mesh.set_meta("opennv_source_path", path)
	mesh_cache[path] = mesh
	var placements := waiting_placements.get(path, []) as Array
	waiting_placements.erase(path)
	pending_path_priorities.erase(path)
	phase_started = Time.get_ticks_usec()
	_add_placements(mesh, placements)
	phase_finished = Time.get_ticks_usec()
	max_mesh_placement_publish_usec = maxi(max_mesh_placement_publish_usec, phase_finished - phase_started)
	if DisplayServer.get_name() != "headless" and not mesh_ref_counts.has(path):
		mesh_cache.erase(path)
	var elapsed := Time.get_ticks_usec() - install_started
	if elapsed > 16000:
		print("OPENNV_MESH_INSTALL_SLOW usec=%d duplicate=%d material=%d split=%d publish=%d placements=%d path=%s" % [
			elapsed, max_mesh_duplicate_usec, max_mesh_material_usec, max_mesh_collision_split_usec,
			max_mesh_placement_publish_usec, placements.size(), path])


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
	if not convex and source.has_meta("opennv_collision_shape"):
		var baked_shape := source.get_meta("opennv_collision_shape") as Shape3D
		if baked_shape != null:
			return baked_shape
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


func _apply_nif_material_semantics(mesh: Mesh, mesh_path: String, force: bool = false) -> void:
	if DisplayServer.get_name() == "headless" and not force:
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
			else:
				_release_offscreen_actor_pending(placement)
		elif loaded_detail_cells.has(cell_id) \
				or (placement.has("_runtime_actor") and loaded_actor_cells.has(cell_id)):
			current_placements.append(placement)
		else:
			_release_offscreen_actor_pending(placement)
	placements = current_placements
	if placements.is_empty():
		return
	if DisplayServer.get_name() == "headless" and OS.get_environment("FNV_GODOT_HEADLESS_PHYSICS") != "1":
		resident_instances += placements.size()
		for placement_value in placements:
			var placement := placement_value as Dictionary
			if placement.has("_runtime_actor"):
				resident_actors += 1
				_release_offscreen_actor_pending(placement)
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
	_refresh_queued_offscreen_actor_state(placement)
	var ref_id := _canonical_form_id(placement.get("form_id", ""))
	var existing := actor_nodes_by_form_id.get(ref_id) as Node
	if is_instance_valid(existing):
		actor_lifecycle_counters.duplicate_suppressions += 1
		_release_offscreen_actor_pending(placement)
		return
	var actor_record := placement.get("_runtime_actor", {}) as Dictionary
	var actor_script := load("res://scripts/fnv_actor.gd")
	var actor := actor_script.new() as CharacterBody3D
	actor.name = "Actor_%s_%s" % [str(actor_record.get("id", "unknown")), str(placement.get("form_id", ""))]
	var authored_transform := (placement.get("_runtime_restore_transform") as Transform3D
		if placement.has("_runtime_restore_transform") else _placement_transform(placement))
	authored_transform.basis = authored_transform.basis.orthonormalized()
	actor.transform = authored_transform
	actor.set_meta("fnv_form_id", placement.get("form_id", ""))
	actor.set_meta("fnv_base_form_id", placement.get("base_form_id", ""))
	actor.set_meta("fnv_actor_id", actor_record.get("id", ""))
	actor.set_meta("fnv_actor_category", actor_record.get("category", ""))
	actor.set_meta("opennv_runtime_cell", _canonical_form_id(placement.get("_runtime_cell", "")))
	actor.set_meta("opennv_runtime_scope", _placement_scope(placement))
	actor.set_meta("opennv_spawn_placement", _persistent_actor_placement(placement))
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
	actor_nodes_by_form_id[_canonical_form_id(placement.get("form_id", ""))] = actor
	actor.call("configure", str(actor_record.get("id", "")), category, _actor_package_semantics(placement, category))
	var restore_succeeded := true
	if placement.has("_runtime_actor_state"):
		restore_succeeded = bool(actor.call("restore_runtime_state", placement.get("_runtime_actor_state", {}) as Dictionary))
	if restore_succeeded:
		_consume_offscreen_actor_state(_canonical_form_id(placement.get("form_id", "")))
	else:
		actor_lifecycle_counters.restore_failures += 1
		push_error("OPENNV_ACTOR_RESTORE_PACKAGE_MISMATCH ref=%s" % ref_id)
	var scope := _placement_scope(placement)
	_register_visual(scope, actor)
	_register_collision_body(scope, actor)
	resident_instances += 1
	resident_actors += 1
	if OS.get_environment("FNV_GODOT_ACTOR_TRACE") == "1":
		print("OPENNV_ACTOR_SPAWN id=%s ref=%s scope=%s" % [actor_record.get("id", ""), placement.get("form_id", ""), scope])


func _add_skeletal_actor(skeletal_scene: Node3D, placement: Dictionary) -> void:
	_refresh_queued_offscreen_actor_state(placement)
	var ref_id := _canonical_form_id(placement.get("form_id", ""))
	var existing := actor_nodes_by_form_id.get(ref_id) as Node
	if is_instance_valid(existing):
		actor_lifecycle_counters.duplicate_suppressions += 1
		_release_offscreen_actor_pending(placement)
		skeletal_scene.queue_free()
		return
	var actor_record := placement.get("_runtime_actor", {}) as Dictionary
	var actor_script := load("res://scripts/fnv_actor.gd")
	var actor := actor_script.new() as CharacterBody3D
	actor.name = "SkeletalActor_%s_%s" % [str(actor_record.get("id", "unknown")), str(placement.get("form_id", ""))]
	var authored_transform := (placement.get("_runtime_restore_transform") as Transform3D
		if placement.has("_runtime_restore_transform") else _placement_transform(placement))
	authored_transform.basis = authored_transform.basis.orthonormalized()
	actor.transform = authored_transform
	actor.set_meta("fnv_form_id", placement.get("form_id", ""))
	actor.set_meta("fnv_base_form_id", placement.get("base_form_id", ""))
	actor.set_meta("fnv_actor_id", actor_record.get("id", ""))
	actor.set_meta("fnv_actor_category", actor_record.get("category", ""))
	actor.set_meta("opennv_runtime_cell", _canonical_form_id(placement.get("_runtime_cell", "")))
	actor.set_meta("opennv_runtime_scope", _placement_scope(placement))
	actor.set_meta("opennv_spawn_placement", _persistent_actor_placement(placement))
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
	actor_nodes_by_form_id[_canonical_form_id(placement.get("form_id", ""))] = actor
	actor.call("configure", str(actor_record.get("id", "")), category, _actor_package_semantics(placement, category))
	var restore_succeeded := true
	if placement.has("_runtime_actor_state"):
		restore_succeeded = bool(actor.call("restore_runtime_state", placement.get("_runtime_actor_state", {}) as Dictionary))
	if restore_succeeded:
		_consume_offscreen_actor_state(_canonical_form_id(placement.get("form_id", "")))
	else:
		actor_lifecycle_counters.restore_failures += 1
		push_error("OPENNV_SKELETAL_ACTOR_RESTORE_PACKAGE_MISMATCH ref=%s" % ref_id)
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
		door.call("configure_audio", audio_runtime, str(placement.get("open_sound", "")), str(placement.get("close_sound", "")))
		door.connect("portal_requested", _on_door_portal_requested)
		add_child(door)
		_register_stream_node(placement.get("_runtime_cell", ""), door, 1, mesh)
		var door_scope := _placement_scope(placement)
		_register_visual(door_scope, door)
		_register_collision_body(door_scope, door)
		door_nodes_by_form_id[str(placement.get("form_id", "")).to_lower()] = door
		resident_instances += 1
		return
	if str(placement.get("base_type", "")) == "CONT":
		var container_script := load("res://scripts/fnv_container.gd")
		var container := container_script.new() as StaticBody3D
		container.name = "%s_%s" % [str(placement.get("base_editor_id", "Container")), str(placement.get("form_id", ""))]
		container.transform = _placement_transform(placement)
		container.set_meta("fnv_form_id", placement.get("form_id", ""))
		container.set_meta("fnv_base_form_id", placement.get("base_form_id", ""))
		container.call("configure", placement.get("inventory", []) as Array)
		container.call("configure_audio", audio_runtime, str(placement.get("activation_sound", "")))
		var container_visual := MeshInstance3D.new()
		container_visual.mesh = mesh
		container.add_child(container_visual)
		var container_collider := CollisionShape3D.new()
		var container_box := BoxShape3D.new()
		var container_bounds := mesh.get_aabb()
		container_box.size = container_bounds.size.max(Vector3.ONE * 0.05)
		container_collider.shape = container_box
		container_collider.position = container_bounds.get_center()
		container.add_child(container_collider)
		container.connect("opened", _on_container_opened)
		add_child(container)
		_attach_authored_looping_sound(container, placement)
		var container_scope := _placement_scope(placement)
		_register_visual(container_scope, container)
		_register_collision_body(container_scope, container)
		_register_stream_node(placement.get("_runtime_cell", ""), container, 1, mesh)
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
	_attach_authored_looping_sound(instance, placement)
	var instance_scope := _placement_scope(placement)
	_register_visual(instance_scope, instance)
	_register_stream_node(placement.get("_runtime_cell", ""), instance, 1, mesh)
	resident_instances += 1


func _on_container_opened(container: Node, actor: Node, contents: Array) -> void:
	container_activated.emit(container, actor, contents)


func _attach_authored_looping_sound(instance: Node3D, placement: Dictionary) -> void:
	var sound_id := str(placement.get("looping_sound", ""))
	if sound_id.is_empty() or not audio_runtime.sound_is_looping(sound_id):
		return
	var stream := audio_runtime.stream_for_sound(sound_id)
	if stream == null:
		return
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	var player := AudioStreamPlayer3D.new()
	player.name = "AuthoredLoopingSound"
	player.stream = stream
	player.unit_size = 4.0
	player.max_distance = 80.0
	instance.add_child(player)
	var scope := _placement_scope(placement)
	if not audio_players_by_scope.has(scope):
		audio_players_by_scope[scope] = []
	(audio_players_by_scope[scope] as Array).append(player)
	if scope == active_scope:
		player.play()


func _placement_transform(placement: Dictionary) -> Transform3D:
	var source_position := _source_position(placement)
	var origin_values: Array = placement.get("_runtime_origin", [source_origin.x, source_origin.y, source_origin.z])
	var runtime_origin := Vector3(float(origin_values[0]), float(origin_values[1]), float(origin_values[2]))
	var stage_values: Array = placement.get("_runtime_stage", [0.0, 0.0, 0.0])
	var stage_origin := Vector3(float(stage_values[0]), float(stage_values[1]), float(stage_values[2]))
	var rotation_values: Array = placement.get("rotation_radians", [0.0, 0.0, 0.0])
	var rotation := Vector3(float(rotation_values[0]), float(rotation_values[1]), float(rotation_values[2]))
	if runtime_placements_require_atlas and not bool(placement.get("_runtime_interior", false)):
		var cell_index := cell_indices_by_id.get(_canonical_form_id(placement.get("_runtime_cell", "")), {}) as Dictionary
		rotation.z += float(cell_index.get("atlas_rotation_radians", 0.0))
	var basis := _source_rotation_to_godot(rotation)
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
	var source := Vector3(float(values[0]), float(values[1]), float(values[2]))
	if runtime_placements_require_atlas and not bool(placement.get("_runtime_interior", false)):
		return _atlas_transform_source_position(source, _canonical_form_id(placement.get("_runtime_cell", "")))
	return source


func _atlas_transform_source_position(source: Vector3, cell_id_value: String) -> Vector3:
	var cell_index := cell_indices_by_id.get(_canonical_form_id(cell_id_value), {}) as Dictionary
	var rotation := float(cell_index.get("atlas_rotation_radians", 0.0))
	var translation_values := cell_index.get("atlas_translation_units", [0.0, 0.0, 0.0]) as Array
	var translation := Vector3(float(translation_values[0]), float(translation_values[1]), float(translation_values[2]))
	if is_zero_approx(rotation) and translation == Vector3.ZERO:
		return source
	var cosine := cos(rotation)
	var sine := sin(rotation)
	return Vector3(cosine * source.x - sine * source.y, sine * source.x + cosine * source.y, source.z) + translation


func _on_door_portal_requested(door: Node3D, actor: Node3D) -> void:
	if actor == null:
		return
	if bool(door.get_meta("opennv_portal_processing", false)):
		return
	door.set_meta("opennv_portal_processing", true)
	var destination_id := str(door.get_meta("fnv_destination_door", "")).to_lower()
	var destination_cell := _canonical_form_id(door.get_meta("fnv_destination_cell", ""))
	var portal_source_cell := _canonical_form_id(door.get_meta("fnv_cell", ""))
	var npc_portal := actor.has_meta("fnv_actor_id")
	if npc_portal:
		var source_cell := portal_source_cell
		if _canonical_form_id(actor.get_meta("opennv_runtime_cell", "")) != source_cell:
			_notify_package_portal_actor(actor, false)
			door.set_meta("opennv_portal_processing", false)
			if door.has_method("complete_portal"):
				door.call("complete_portal")
			return
		var destination_values: Variant = door.get_meta("fnv_destination_position", null)
		if destination_values is Array and (destination_values as Array).size() >= 3:
			actor.global_position = _runtime_position_in_cell(_array_to_vector3(destination_values), destination_cell)
		else:
			var indexed_destination: Variant = _package_navigation_door_position(destination_id)
			if not indexed_destination is Vector3:
				_notify_package_portal_actor(actor, false)
				door.set_meta("opennv_portal_processing", false)
				if door.has_method("complete_portal"):
					door.call("complete_portal")
				return
			actor.global_position = indexed_destination as Vector3
		var destination_rotation_values: Variant = door.get_meta("fnv_destination_rotation", null)
		if destination_rotation_values is Array and (destination_rotation_values as Array).size() >= 3:
			var source_rotation := _array_to_vector3(destination_rotation_values)
			if not interior_names.has(destination_cell):
				source_rotation.z += float((cell_indices_by_id.get(destination_cell, {}) as Dictionary).get("atlas_rotation_radians", 0.0))
			actor.global_basis = _source_rotation_to_godot(source_rotation)
		if actor is CharacterBody3D:
			(actor as CharacterBody3D).velocity = Vector3.ZERO
		_complete_npc_portal_transition(actor, source_cell, destination_cell)
		_notify_package_portal_actor(actor, true)
		door.set_meta("opennv_portal_processing", false)
		if door.has_method("complete_portal"):
			door.call("complete_portal")
		return
	var portal_token := _begin_player_portal_transaction(actor, portal_source_cell, destination_cell)
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
		if not is_instance_valid(door) or not _player_portal_transaction_current(actor, portal_token):
			_abort_portal_transaction(door, actor, portal_token, portal_source_cell, destination_cell)
			return
	if wait_frames >= 1800:
		push_warning("OPENNV_PORTAL_RESIDENCY_TIMEOUT source=%s destination_cell=%s" % [door.name, destination_cell])
		door.set_meta("opennv_portal_pending", false)
		door.set_meta("opennv_portal_processing", false)
		if door.has_method("complete_portal"):
			door.call("complete_portal")
		_notify_package_portal_actor(actor, false)
		_finish_player_portal_transaction(actor, portal_token, portal_source_cell, destination_cell)
		return
	# Scene nodes commit before the physics server sees their shapes. Two ticks
	# also cover a transition requested during the current physics callback.
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_instance_valid(door) or not _player_portal_transaction_current(actor, portal_token):
		_abort_portal_transaction(door, actor, portal_token, portal_source_cell, destination_cell)
		return
	var destination := door_nodes_by_form_id.get(destination_id) as Node3D
	if destination == null:
		push_warning("OPENNV_PORTAL_UNRESOLVED source=%s destination=%s" % [door.name, destination_id])
		door.set_meta("opennv_portal_pending", false)
		door.set_meta("opennv_portal_processing", false)
		if door.has_method("complete_portal"):
			door.call("complete_portal")
		_notify_package_portal_actor(actor, false)
		_finish_player_portal_transaction(actor, portal_token, portal_source_cell, destination_cell)
		return
	# Player travel changes the active visual/audio scope. NPC package travel must
	# never hijack the player's world; it transfers or freezes that actor only.
	_set_active_cell(destination_cell)
	var authored_destination_values: Variant = door.get_meta("fnv_destination_position", null)
	if authored_destination_values is Array and (authored_destination_values as Array).size() >= 3:
		var authored_values := authored_destination_values as Array
		var authored_destination := Vector3(
			float(authored_values[0]), float(authored_values[1]), float(authored_values[2]))
		var authored_runtime_position := _runtime_position_in_cell(authored_destination, destination_cell)
		var landing_mode := "authored"
		var landing_exclusions: Array[RID] = []
		if door is CollisionObject3D:
			landing_exclusions.append((door as CollisionObject3D).get_rid())
		if actor is CollisionObject3D:
			landing_exclusions.append((actor as CollisionObject3D).get_rid())
		var floor_exclusions := landing_exclusions.duplicate()
		if destination is CollisionObject3D:
			floor_exclusions.append((destination as CollisionObject3D).get_rid())
		if _landing_capsule_is_clear(authored_runtime_position, landing_exclusions) \
				and _landing_has_floor(authored_runtime_position, floor_exclusions):
			actor.global_position = authored_runtime_position
		else:
			var fallback_direction := destination.global_basis.z.normalized()
			if interior_centers.has(destination_cell):
				fallback_direction = (interior_centers[destination_cell] as Vector3) - destination.global_position
			fallback_direction.y = 0.0
			if fallback_direction.length_squared() < 0.1:
				fallback_direction = Vector3.FORWARD
			var fallback_landing: Variant = _safe_door_landing(destination as CollisionObject3D,
				fallback_direction.normalized(), actor as CollisionObject3D)
			if not fallback_landing is Vector3:
				_set_active_cell(portal_source_cell)
				_abort_portal_transaction(door, actor, portal_token, portal_source_cell, destination_cell)
				return
			actor.global_position = fallback_landing as Vector3
			landing_mode = "authored-fallback"
		var authored_rotation_values: Variant = door.get_meta("fnv_destination_rotation", null)
		if authored_rotation_values is Array and (authored_rotation_values as Array).size() >= 3:
			var authored_rotation := authored_rotation_values as Array
			var source_rotation := Vector3(
				float(authored_rotation[0]), float(authored_rotation[1]), float(authored_rotation[2]))
			if not interior_names.has(destination_cell):
				var destination_index := cell_indices_by_id.get(destination_cell, {}) as Dictionary
				source_rotation.z += float(destination_index.get("atlas_rotation_radians", 0.0))
			actor.global_basis = _source_rotation_to_godot(source_rotation)
		if actor is CharacterBody3D:
			(actor as CharacterBody3D).velocity = Vector3.ZERO
		var authored_source_cell := str(door.get_meta("fnv_cell", ""))
		print("OPENNV_SEAMLESS_DOOR source=%s destination=%s landing=%s name=%s" % [
			authored_source_cell, destination_cell, landing_mode,
			interior_names.get(destination_cell, "exterior")])
		portal_transitioned.emit(authored_source_cell, destination_cell)
		door.set_meta("opennv_portal_pending", false)
		door.set_meta("opennv_portal_processing", false)
		if door.has_method("complete_portal"):
			door.call("complete_portal")
		_finish_player_portal_transaction(actor, portal_token, portal_source_cell, destination_cell)
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
	var safe_landing: Variant = _safe_door_landing(destination, exit_direction.normalized(),
		actor as CollisionObject3D)
	if not safe_landing is Vector3:
		_set_active_cell(portal_source_cell)
		_abort_portal_transaction(door, actor, portal_token, portal_source_cell, destination_cell)
		return
	actor.global_position = safe_landing as Vector3
	if actor is CharacterBody3D:
		(actor as CharacterBody3D).velocity = Vector3.ZERO
	var source_cell := str(door.get_meta("fnv_cell", ""))
	print("OPENNV_SEAMLESS_DOOR source=%s destination=%s name=%s" % [source_cell, destination_cell, interior_names.get(destination_cell, "exterior")])
	portal_transitioned.emit(source_cell, destination_cell)
	door.set_meta("opennv_portal_pending", false)
	door.set_meta("opennv_portal_processing", false)
	if door.has_method("complete_portal"):
		door.call("complete_portal")
	_finish_player_portal_transaction(actor, portal_token, portal_source_cell, destination_cell)


func _notify_package_portal_actor(actor: Node3D, success: bool) -> void:
	if is_instance_valid(actor) and actor.has_method("complete_package_portal"):
		actor.call("complete_package_portal", success)


func _begin_player_portal_transaction(actor: Node3D, source_cell: String, destination_cell: String) -> int:
	player_portal_generation += 1
	var token := player_portal_generation
	actor.set_meta("opennv_player_portal_generation", token)
	for cell_id in [source_cell, destination_cell]:
		if not cell_id.is_empty():
			portal_pinned_cells[cell_id] = int(portal_pinned_cells.get(cell_id, 0)) + 1
	return token


func _player_portal_transaction_current(actor: Node3D, token: int) -> bool:
	return is_instance_valid(actor) and int(actor.get_meta("opennv_player_portal_generation", -1)) == token


func _finish_player_portal_transaction(actor: Node3D, token: int,
		source_cell: String, destination_cell: String) -> void:
	for cell_id in [source_cell, destination_cell]:
		if cell_id.is_empty():
			continue
		var remaining := int(portal_pinned_cells.get(cell_id, 0)) - 1
		if remaining <= 0:
			portal_pinned_cells.erase(cell_id)
		else:
			portal_pinned_cells[cell_id] = remaining
	if _player_portal_transaction_current(actor, token):
		actor.remove_meta("opennv_player_portal_generation")


func _abort_portal_transaction(door: Node3D, actor: Node3D, token: int,
		source_cell: String, destination_cell: String) -> void:
	if is_instance_valid(actor):
		_notify_package_portal_actor(actor, false)
	if is_instance_valid(door):
		door.set_meta("opennv_portal_processing", false)
		if door.has_method("complete_portal"):
			door.call("complete_portal")
	_finish_player_portal_transaction(actor, token, source_cell, destination_cell)


func _complete_npc_portal_transition(actor: Node3D, source_cell_value: String,
		destination_cell_value: String) -> void:
	if not is_instance_valid(actor):
		return
	var source_cell := _canonical_form_id(source_cell_value)
	var destination_cell := _canonical_form_id(destination_cell_value)
	var destination_scope := destination_cell
	var destination_interior := interior_names.has(destination_cell)
	if not destination_interior:
		var destination_index := cell_indices_by_id.get(destination_cell, {}) as Dictionary
		destination_scope = _world_scope(_canonical_form_id(destination_index.get("world_form_id", primary_world_id)))
	(stream_nodes_by_cell.get(source_cell, []) as Array).erase(actor)
	(actor_nodes_by_cell.get(source_cell, []) as Array).erase(actor)
	if not stream_nodes_by_cell.has(destination_cell):
		stream_nodes_by_cell[destination_cell] = []
	if not actor_nodes_by_cell.has(destination_cell):
		actor_nodes_by_cell[destination_cell] = []
	if not (stream_nodes_by_cell[destination_cell] as Array).has(actor):
		(stream_nodes_by_cell[destination_cell] as Array).append(actor)
	if not (actor_nodes_by_cell[destination_cell] as Array).has(actor):
		(actor_nodes_by_cell[destination_cell] as Array).append(actor)
	var ref_id := _canonical_form_id(actor.get_meta("fnv_form_id", ""))
	(reference_ids_by_cell.get(source_cell, []) as Array).erase(ref_id)
	if not reference_ids_by_cell.has(destination_cell):
		reference_ids_by_cell[destination_cell] = []
	if not (reference_ids_by_cell[destination_cell] as Array).has(ref_id):
		(reference_ids_by_cell[destination_cell] as Array).append(ref_id)
	reference_runtime_positions[ref_id] = actor.global_position
	reference_runtime_cells[ref_id] = destination_cell
	var old_status := actor_visual_status_by_cell.get(source_cell, {}) as Dictionary
	var visual_status := str(old_status.get(ref_id, "exact"))
	old_status.erase(ref_id)
	if not actor_visual_status_by_cell.has(destination_cell):
		actor_visual_status_by_cell[destination_cell] = {}
	(actor_visual_status_by_cell[destination_cell] as Dictionary)[ref_id] = visual_status
	actor.set_meta("opennv_runtime_cell", destination_cell)
	actor.set_meta("opennv_runtime_scope", destination_scope)
	if actor.has_method("update_runtime_cell"):
		actor.call("update_runtime_cell", destination_cell, destination_scope, destination_interior)
	actor_lifecycle_counters.migrations += 1
	if _npc_destination_should_remain_live(destination_cell, destination_scope):
		return
	_capture_offscreen_actor_state(actor)
	(stream_nodes_by_cell.get(destination_cell, []) as Array).erase(actor)
	(actor_nodes_by_cell.get(destination_cell, []) as Array).erase(actor)
	(reference_ids_by_cell.get(destination_cell, []) as Array).erase(ref_id)
	(actor_visual_status_by_cell.get(destination_cell, {}) as Dictionary).erase(ref_id)
	actor_nodes_by_form_id.erase(ref_id)
	for scope_value in visuals_by_scope.keys():
		(visuals_by_scope[scope_value] as Array).erase(actor)
	for scope_value in collision_bodies_by_scope.keys():
		(collision_bodies_by_scope[scope_value] as Array).erase(actor)
	resident_instances = maxi(0, resident_instances - int(actor.get_meta("opennv_stream_instance_count", 0)))
	resident_actors = maxi(0, resident_actors - 1)
	_release_stream_mesh_ref(actor)
	actor.queue_free()


func _npc_destination_should_remain_live(cell_id_value: String, scope: String) -> bool:
	var cell_id := _canonical_form_id(cell_id_value)
	if interior_names.has(cell_id):
		return active_scope == cell_id
	if not _scope_is_exterior(active_scope) or scope != active_scope or not cell_indices_by_id.has(cell_id):
		return false
	var cell_index := cell_indices_by_id[cell_id] as Dictionary
	var destination_world := _canonical_form_id(cell_index.get("world_form_id", ""))
	if destination_world != active_exterior_world_id:
		return false
	var grid_values := cell_index.get("grid", []) as Array
	if grid_values.size() < 2:
		return false
	var world_origin := _world_runtime_origin(active_exterior_world_id)
	var player_atlas := world_origin + _godot_vector_to_source(player_runtime_position * UNITS_PER_METER)
	var player_grid := Vector2i(floori(player_atlas.x / 4096.0), floori(player_atlas.y / 4096.0))
	var destination_grid := Vector2i(int(grid_values[0]), int(grid_values[1]))
	if maxi(absi(destination_grid.x - player_grid.x), absi(destination_grid.y - player_grid.y)) > ACTOR_KEEP_RADIUS:
		return false
	return (loaded_detail_cells.has(cell_id) and loaded_actor_cells.has(cell_id)
		and (not navmesh_index_by_cell.has(cell_id) or navigation_regions_by_cell.has(cell_id)))


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
	if pending_interior_stage_jobs.has(cell_id):
		return true
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
	var runtime_origin := source_origin
	if exterior_runtime_origins_by_cell.has(cell_id):
		runtime_origin = exterior_runtime_origins_by_cell[cell_id] as Vector3
	elif cell_indices_by_id.has(cell_id):
		var cell_index := cell_indices_by_id[cell_id] as Dictionary
		runtime_origin = _world_runtime_origin(_canonical_form_id(cell_index.get("world_form_id", primary_world_id)))
	return _source_vector_to_godot(_atlas_transform_source_position(authored_position, cell_id) - runtime_origin) / UNITS_PER_METER


func _safe_door_landing(destination: CollisionObject3D, preferred_direction: Vector3,
		actor: CollisionObject3D = null) -> Variant:
	if destination == null:
		return null
	var space := get_world_3d().direct_space_state
	var floor_excluded_rids: Array[RID] = [destination.get_rid()]
	var capsule_excluded_rids: Array[RID] = []
	if actor != null:
		floor_excluded_rids.append(actor.get_rid())
		capsule_excluded_rids.append(actor.get_rid())
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
			query.exclude = floor_excluded_rids
			var hit := space.intersect_ray(query)
			if not hit.is_empty():
				var floor_point: Vector3 = hit.get("position", destination.global_position)
				var candidate := floor_point + Vector3.UP * 0.06
				if _landing_capsule_is_clear(candidate, capsule_excluded_rids):
					return candidate
	return null


func _landing_capsule_is_clear(position: Vector3, excluded_rids: Array[RID]) -> bool:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.34
	capsule.height = 1.8
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	# Keep a small skin above the support plane so a valid floor contact is not
	# misclassified as capsule penetration by intersect_shape().
	query.transform = Transform3D(Basis.IDENTITY, position + Vector3.UP * 0.94)
	query.collision_mask = 1
	query.exclude = excluded_rids
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _landing_has_floor(position: Vector3, excluded_rids: Array[RID]) -> bool:
	var query := PhysicsRayQueryParameters3D.create(
		position + Vector3.UP * 0.35, position + Vector3.DOWN * 1.25)
	query.collision_mask = 1
	query.exclude = excluded_rids
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var normal := hit.get("normal", Vector3.ZERO) as Vector3
	return normal.normalized().dot(Vector3.UP) >= 0.65


func _placement_scope(placement: Dictionary) -> String:
	if placement.has("_runtime_scope"):
		return str(placement.get("_runtime_scope", EXTERIOR_SCOPE))
	return str(placement.get("_runtime_cell", "")) if bool(placement.get("_runtime_interior", false)) else EXTERIOR_SCOPE


func _canonical_form_id(value: Variant) -> String:
	if value == null:
		return ""
	var text := str(value).strip_edges().to_lower()
	if text.begins_with("0x"):
		return "0x%08x" % text.substr(2).hex_to_int()
	return text


func _register_visual(scope: String, node: Node3D) -> void:
	if not visuals_by_scope.has(scope):
		visuals_by_scope[scope] = []
	(visuals_by_scope[scope] as Array).append(node)
	node.set_meta("opennv_visual_scope", scope)
	node.visible = scope == active_scope


func _register_collision_body(scope: String, body: CollisionObject3D) -> void:
	if not collision_bodies_by_scope.has(scope):
		collision_bodies_by_scope[scope] = []
	(collision_bodies_by_scope[scope] as Array).append(body)
	body.set_meta("opennv_collision_scope", scope)
	body.collision_layer = 1 if scope == active_scope else 0


func _unregister_scope_node(node: Node) -> void:
	if node.has_meta("opennv_visual_scope"):
		var visual_scope := str(node.get_meta("opennv_visual_scope", ""))
		if visuals_by_scope.has(visual_scope):
			(visuals_by_scope[visual_scope] as Array).erase(node)
	if node.has_meta("opennv_collision_scope"):
		var collision_scope := str(node.get_meta("opennv_collision_scope", ""))
		if collision_bodies_by_scope.has(collision_scope):
			(collision_bodies_by_scope[collision_scope] as Array).erase(node)


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
	if interior_names.has(canonical_cell):
		_queue_offscreen_actors_for_cell(canonical_cell,
			interior_source_origins.get(canonical_cell, Vector3.ZERO) as Vector3,
			interior_stage_origins.get(canonical_cell, Vector3.ZERO) as Vector3,
			true, canonical_cell, 0)
	else:
		var active_world_origin := _world_runtime_origin(active_exterior_world_id)
		_queue_offscreen_actors_for_cell(canonical_cell, active_world_origin,
			Vector3.ZERO, false, active_scope, ACTOR_VISUAL_RADIUS)
	if not pending_skeletal_placements.is_empty() or not pending_paths.is_empty():
		set_process(true)
		if threaded_loading:
			_pump_threaded_requests()
	print("OPENNV_CELL_SCOPE_ACTIVE scope=%s" % active_scope)


func _set_scope_enabled(scope: String, enabled: bool) -> void:
	for node_value in visuals_by_scope.get(scope, []):
		var node := node_value as Node3D
		if is_instance_valid(node):
			node.visible = enabled
			if node is CharacterBody3D:
				node.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
	for body_value in collision_bodies_by_scope.get(scope, []):
		var body := body_value as CollisionObject3D
		if is_instance_valid(body):
			body.collision_layer = 1 if enabled else 0
	for region_value in navigation_regions_by_scope.get(scope, []):
		var region := region_value as NavigationRegion3D
		if is_instance_valid(region):
			region.enabled = enabled
	for link_value in navigation_links_by_scope.get(scope, []):
		var link := link_value as NavigationLink3D
		if is_instance_valid(link):
			link.enabled = enabled
	for player_value in audio_players_by_scope.get(scope, []):
		var player := player_value as AudioStreamPlayer3D
		if is_instance_valid(player):
			if enabled and not player.playing:
				player.play()
			elif not enabled and player.playing:
				player.stop()


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
	return actor_nodes_by_form_id.get(_canonical_form_id(form_id)) as Node3D


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


func _add_terrain(cell: Dictionary, cell_distance: int, route_detail: bool,
		prepared_mesh: ArrayMesh = null, prepared_texture: Texture2D = null) -> void:
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
	var terrain_transform := _terrain_local_transform(source_grid, atlas_rotation, atlas_translation, runtime_origin)
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
	var cache_path := _terrain_mesh_cache_path(cell_id, sample_step)
	var terrain_phase_started := Time.get_ticks_usec()
	var mesh := prepared_mesh
	if mesh == null and ResourceLoader.exists(cache_path):
		mesh = ResourceLoader.load(cache_path) as ArrayMesh
	if mesh == null:
		terrain_mesh_cache_fallback_paths["%s|%d" % [cell_id, sample_step]] = true
		mesh = _build_terrain_mesh(heights, sample_step)
	if mesh == null:
		return
	max_terrain_mesh_load_usec = maxi(max_terrain_mesh_load_usec,
		Time.get_ticks_usec() - terrain_phase_started)
	if physics_validation:
		var validation_body := StaticBody3D.new()
		validation_body.name = "LAND_%d_%d_Collision" % [cell_grid.x, cell_grid.y]
		var validation_shape := CollisionShape3D.new()
		validation_shape.shape = mesh.get_meta("opennv_collision_shape", null) as Shape3D
		if validation_shape.shape == null:
			validation_shape.shape = mesh.create_trimesh_shape()
		_configure_terrain_collision_node(validation_shape)
		validation_body.add_child(validation_shape)
		validation_body.transform = terrain_transform
		add_child(validation_body)
		_register_collision_body(runtime_scope, validation_body)
		return
	var terrain_instance := MeshInstance3D.new()
	terrain_instance.name = "LAND_%d_%d" % [cell_grid.x, cell_grid.y]
	terrain_instance.mesh = mesh
	terrain_instance.transform = terrain_transform
	terrain_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if full_detail else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.62, 0.56, 0.44)
	material.roughness = 1.0
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var baked_albedo := _terrain_baked_albedo_path(cell, full_detail)
	terrain_phase_started = Time.get_ticks_usec()
	if prepared_texture != null:
		material.albedo_texture = prepared_texture
	elif full_detail and not baked_albedo.is_empty():
		material.albedo_texture = _load_runtime_image(baked_albedo)
	elif ResourceLoader.exists(TERRAIN_DIFFUSE):
		material.albedo_texture = load(TERRAIN_DIFFUSE)
	if baked_albedo.is_empty() and ResourceLoader.exists(TERRAIN_NORMAL):
		material.normal_enabled = true
		material.normal_texture = load(TERRAIN_NORMAL)
		material.normal_scale = 0.65
	max_terrain_texture_load_usec = maxi(max_terrain_texture_load_usec,
		Time.get_ticks_usec() - terrain_phase_started)
	terrain_instance.material_override = material
	terrain_phase_started = Time.get_ticks_usec()
	add_child(terrain_instance)
	_register_visual(runtime_scope, terrain_instance)
	terrain_visual_by_cell[cell_id] = terrain_instance
	if not full_detail:
		terrain_collision_cells.erase(cell_id)
		max_terrain_publish_usec = maxi(max_terrain_publish_usec,
			Time.get_ticks_usec() - terrain_phase_started)
		return
	max_terrain_publish_usec = maxi(max_terrain_publish_usec,
		Time.get_ticks_usec() - terrain_phase_started)
	terrain_phase_started = Time.get_ticks_usec()
	var body := StaticBody3D.new()
	body.name = terrain_instance.name + "_Collision"
	var shape := CollisionShape3D.new()
	shape.shape = mesh.get_meta("opennv_collision_shape", null) as Shape3D
	if shape.shape == null:
		shape.shape = mesh.create_trimesh_shape()
	_configure_terrain_collision_node(shape)
	body.add_child(shape)
	body.transform = terrain_transform
	add_child(body)
	_register_collision_body(runtime_scope, body)
	terrain_body_by_cell[cell_id] = body
	terrain_collision_cells[cell_id] = true
	max_terrain_collision_usec = maxi(max_terrain_collision_usec,
		Time.get_ticks_usec() - terrain_phase_started)


func _terrain_mesh_cache_path(cell_id_value: String, sample_step: int) -> String:
	var key := "%s|%d" % [_canonical_form_id(cell_id_value), sample_step]
	return "%s/%s.res" % [TERRAIN_MESH_CACHE_DIR, key.sha256_text()]


func _terrain_baked_albedo_path(cell: Dictionary, full_detail: bool) -> String:
	if not full_detail:
		return ""
	var source_grid_values := cell.get("source_grid", cell.get("grid", [0, 0])) as Array
	var cell_grid_values := cell.get("grid", [0, 0]) as Array
	if source_grid_values.size() < 2 or cell_grid_values.size() < 2:
		return ""
	var world_id := str(cell.get("world_form_id", "0")).to_lower().trim_prefix("0x")
	var baked := TERRAIN_ALBEDO_ROOT + "land_%s_%d_%d.png" % [
		world_id, int(source_grid_values[0]), int(source_grid_values[1])]
	var legacy := TERRAIN_ALBEDO_ROOT + "land_%d_%d.png" % [
		int(cell_grid_values[0]), int(cell_grid_values[1])]
	if FileAccess.file_exists(baked):
		return baked
	return legacy if FileAccess.file_exists(legacy) else ""


func _configure_terrain_collision_node(node: CollisionShape3D) -> void:
	if node.shape is HeightMapShape3D:
		# HeightMapShape3D is centered and uses a unit grid. The cached heights
		# are in 128-source-unit samples, so one uniform scale restores metres.
		node.position = Vector3(2048.0 / UNITS_PER_METER, 0.0, -2048.0 / UNITS_PER_METER)
		node.scale = Vector3.ONE * (128.0 / UNITS_PER_METER)


func _terrain_local_transform(source_grid: Vector2i, atlas_rotation: float,
		atlas_translation: Vector3, runtime_origin: Vector3) -> Transform3D:
	var cell_source_origin := Vector3(source_grid.x * 4096.0, source_grid.y * 4096.0, 0.0)
	var cosine := cos(atlas_rotation)
	var sine := sin(atlas_rotation)
	var atlas_cell_origin := Vector3(
		cosine * cell_source_origin.x - sine * cell_source_origin.y,
		sine * cell_source_origin.x + cosine * cell_source_origin.y,
		0.0) + atlas_translation
	return Transform3D(
		# Atlas rotation is a world-coordinate remap, not an authored ESM object
		# attitude. C * Rz(angle) * C^-1 is a positive Godot Y rotation.
		Basis(Vector3.UP, atlas_rotation),
		_source_vector_to_godot(atlas_cell_origin - runtime_origin) / UNITS_PER_METER)


func _validate_terrain_mesh_cache_contract() -> bool:
	if terrain_mesh_cache_contract_checked:
		return terrain_mesh_cache_contract_valid
	terrain_mesh_cache_contract_checked = true
	terrain_mesh_cache_contract_valid = false
	terrain_mesh_cache_cell_count = 0
	if not FileAccess.file_exists(TERRAIN_MESH_CACHE_REPORT):
		return false
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(TERRAIN_MESH_CACHE_REPORT))
	if not document is Dictionary:
		return false
	var report := document as Dictionary
	terrain_mesh_cache_cell_count = int(report.get("cellCount", 0))
	terrain_mesh_cache_contract_valid = str(report.get("schema", "")) == "opennv-terrain-mesh-cache/v2" \
		and str(report.get("status", "")) == "pass" and bool(report.get("complete", false)) \
		and str(report.get("coverage", "")) == "goodsprings-strip-radius-14" \
		and terrain_mesh_cache_cell_count > 0 \
		and int(report.get("processedCells", 0)) == terrain_mesh_cache_cell_count \
		and int(report.get("processedResources", 0)) == int(report.get("expectedResources", -1)) \
		and (report.get("failures", []) as Array).is_empty()
	return terrain_mesh_cache_contract_valid


func _build_terrain_mesh(heights: PackedFloat32Array, sample_step: int) -> ArrayMesh:
	if heights.size() != 1089 or sample_step <= 0 or 32 % sample_step != 0:
		return null
	var grid_width := int(32 / sample_step) + 1
	var vertices := PackedVector3Array()
	vertices.resize(grid_width * grid_width)
	for sample_row in range(grid_width):
		var row := sample_row * sample_step
		for sample_column in range(grid_width):
			var column := sample_column * sample_step
			var local_source := Vector3(column * 128.0, row * 128.0, heights[row * 33 + column])
			vertices[sample_row * grid_width + sample_column] = _source_vector_to_godot(local_source) / UNITS_PER_METER
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for sample_row in range(grid_width):
		for sample_column in range(grid_width):
			surface.set_uv(Vector2(float(sample_column), float(sample_row)) / float(grid_width - 1))
			surface.add_vertex(vertices[sample_row * grid_width + sample_column])
	for row in range(grid_width - 1):
		for column in range(grid_width - 1):
			var a := row * grid_width + column
			var b := a + 1
			var c := a + grid_width
			var d := c + 1
			for index in [a, c, b, b, c, d]:
				surface.add_index(index)
	surface.generate_normals()
	return surface.commit() as ArrayMesh


func _load_runtime_image(path: String) -> Texture2D:
	if terrain_albedo_cache.has(path):
		terrain_albedo_lru.erase(path)
		terrain_albedo_lru.append(path)
		return terrain_albedo_cache[path] as Texture2D
	# Prefer Godot's compiled texture resource. Image.load_from_file plus runtime
	# mip generation was a repeatable 10-15 ms cell-crossing hitch.
	var imported := ResourceLoader.load(path) as Texture2D if ResourceLoader.exists(path) else null
	if imported != null:
		terrain_albedo_cache[path] = imported
		terrain_albedo_lru.append(path)
		_trim_terrain_albedo_cache()
		return imported
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		return null
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	terrain_albedo_cache[path] = texture
	terrain_albedo_lru.append(path)
	_trim_terrain_albedo_cache()
	return texture


func _trim_terrain_albedo_cache() -> void:
	while terrain_albedo_lru.size() > TERRAIN_ALBEDO_CACHE_LIMIT:
		var retired_path: String = terrain_albedo_lru.pop_front()
		terrain_albedo_cache.erase(retired_path)


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
	_validate_world_mesh_cache_contract()
	var model_key := model.replace("/", "\\").trim_prefix("\\").to_lower()
	if world_mesh_cache_paths.has(model_key):
		return str(world_mesh_cache_paths[model_key])
	# Remove the extension by length so upper/mixed-case .NIF paths retain their
	# exact directory and basename spelling in the emitted res:// lookup.
	var normalized := model.replace("\\", "/")
	var source_path := CONVERTED_ROOT + normalized.left(normalized.length() - 4) + ".obj"
	var cached_path := _world_mesh_cache_path(source_path)
	if ResourceLoader.exists(cached_path):
		return cached_path
	world_mesh_cache_fallback_paths[source_path] = true
	return source_path


func _world_mesh_cache_path(source_path: String) -> String:
	return "%s/%s.res" % [WORLD_MESH_CACHE_DIR, source_path.sha256_text()]


func _validate_world_mesh_cache_contract() -> bool:
	if world_mesh_cache_contract_checked:
		return world_mesh_cache_contract_valid
	world_mesh_cache_contract_checked = true
	world_mesh_cache_contract_valid = false
	world_mesh_cache_source_count = 0
	world_mesh_cache_paths.clear()
	if not FileAccess.file_exists(WORLD_MESH_CACHE_REPORT):
		return false
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(WORLD_MESH_CACHE_REPORT))
	if not document is Dictionary:
		return false
	var report := document as Dictionary
	world_mesh_cache_source_count = int(report.get("sourceCount", 0))
	var failures := report.get("failures", []) as Array
	var path_document: Variant = JSON.parse_string(FileAccess.get_file_as_string(WORLD_MESH_CACHE_PATH_INDEX)) \
		if FileAccess.file_exists(WORLD_MESH_CACHE_PATH_INDEX) else null
	if path_document is Dictionary:
		var path_index := path_document as Dictionary
		if str(path_index.get("schema", "")) == "opennv-world-mesh-path-index/v1" \
				and str(path_index.get("status", "")) == "pass" \
				and str(path_index.get("sourcePathLedgerSha256", "")) == str(report.get("sourcePathLedgerSha256", "")):
			world_mesh_cache_paths = path_index.get("paths", {}) as Dictionary
	world_mesh_cache_contract_valid = str(report.get("schema", "")) == "opennv-world-mesh-cache/v1" \
		and str(report.get("status", "")) == "pass" and bool(report.get("complete", false)) \
		and world_mesh_cache_source_count > 0 and int(report.get("processed", 0)) == world_mesh_cache_source_count \
		and failures.is_empty() and not str(report.get("sourcePathLedgerSha256", "")).is_empty() \
		and world_mesh_cache_paths.size() == world_mesh_cache_source_count \
		and int(report.get("pathIndexCount", 0)) == world_mesh_cache_source_count \
		and (report.get("pathCollisions", []) as Array).is_empty()
	return world_mesh_cache_contract_valid


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


func _read_exterior_shard_worker(cell_id: String, path: String) -> void:
	var payload := _read_json(path)
	exterior_shard_worker_mutex.lock()
	exterior_shard_worker_results[cell_id] = payload
	exterior_shard_worker_mutex.unlock()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
