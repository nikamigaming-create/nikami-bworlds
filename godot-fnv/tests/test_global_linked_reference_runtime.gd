extends SceneTree


const RING_PATH := "res://generated/world/opennv-full-runtime-index.json"
const ACTOR_REF := "0x000ce94e"
const PACKAGE_ID := "0x00025482"
const CHAIN := ["0x000ce94c", "0x000ce94b", "0x000ce94a"]
const CELLS := ["0x0008434c", "0x00084349", "0x00084344"]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	root.add_child(streamer)
	streamer.call("_load_actor_packages")
	streamer.call("_load_package_navigation_index", RING_PATH)
	streamer.call("_load_navmesh_index")
	if streamer.package_navigation_linked_references.size() != 8202:
		_fail("global linked-reference denominator drifted")
		return
	var ring := JSON.parse_string(FileAccess.get_file_as_string(RING_PATH)) as Dictionary
	streamer.primary_world_id = streamer.call("_canonical_form_id", ring.get("world_form_id", ""))
	streamer.active_exterior_world_id = streamer.primary_world_id
	var found_patrol_cells := 0
	for cell_value in ring.get("cells", []):
		var cell := cell_value as Dictionary
		var cell_id := str(streamer.call("_canonical_form_id", cell.get("form_id", "")))
		var grid_values := cell.get("grid", []) as Array
		var cell_world := str(streamer.call("_canonical_form_id", cell.get("world_form_id", "")))
		var near_novac: bool = cell_world == streamer.primary_world_id and grid_values.size() >= 2 \
			and maxi(absi(int(grid_values[0]) - 4), absi(int(grid_values[1]) + 8)) <= 4
		if cell_id not in CELLS and not near_novac:
			continue
		streamer.cell_indices_by_id[cell_id] = cell
		streamer.exterior_scope_by_cell[cell_id] = "__exterior__"
		var grid := Vector2i(int(grid_values[0]), int(grid_values[1]))
		streamer.cell_indices_by_grid[streamer.call("_world_grid_key", streamer.primary_world_id, grid)] = [cell]
		if cell_id in CELLS:
			found_patrol_cells += 1
	if found_patrol_cells != CELLS.size():
		_fail("real Novac patrol cells are absent from the full runtime index")
		return
	var positions: Array[Vector3] = []
	for index in range(CHAIN.size()):
		var ref_id: String = CHAIN[index]
		if str(streamer.call("_runtime_reference_cell", ref_id)) != CELLS[index]:
			_fail("global marker cell lookup failed at hop %d" % index)
			return
		if str(streamer.call("_runtime_reference_scope", ref_id)) != "__exterior__":
			_fail("global marker scope lookup failed at hop %d" % index)
			return
		var position: Variant = streamer.call("_runtime_reference_position", ref_id)
		if not position is Vector3:
			_fail("global marker position lookup failed at hop %d" % index)
			return
		positions.append(position as Vector3)
		var expected_link: String = CHAIN[index + 1] if index + 1 < CHAIN.size() else CHAIN[0]
		if str(streamer.call("_runtime_reference_link", ref_id)) != expected_link:
			_fail("global linked-reference lookup failed at hop %d" % index)
			return
	# A resident placement may temporarily override the immutable source-space
	# position. Cell eviction must discard only that override, never the patrol graph.
	streamer.reference_runtime_positions[CHAIN[0]] = Vector3(999.0, 999.0, 999.0)
	streamer.reference_runtime_cells[CHAIN[0]] = CELLS[0]
	streamer.linked_reference_by_ref[CHAIN[0]] = CHAIN[1]
	streamer.reference_ids_by_cell[CELLS[0]] = [CHAIN[0]]
	streamer.call("_drop_cell_reference_positions", CELLS[0])
	if (streamer.call("_runtime_reference_position", CHAIN[0]) as Vector3).distance_to(positions[0]) > 0.001 \
			or str(streamer.call("_runtime_reference_link", CHAIN[0])) != CHAIN[1]:
		_fail("patrol graph or position vanished after source-cell eviction")
		return
	streamer.package_navigation_linked_references["0x00ffff01"] = {
		"cell": CELLS[0], "position": [0.0, 0.0, 0.0], "defaultEnabled": false,
		"enableParent": "", "linkedReference": "0x00ffff02",
	}
	if streamer.call("_runtime_reference_position", "0x00ffff01") != null \
			or not str(streamer.call("_runtime_reference_link", "0x00ffff01")).is_empty():
		_fail("disabled global marker did not fail closed")
		return
	var actor_position: Variant = streamer.call("_runtime_reference_position", ACTOR_REF)
	if not actor_position is Vector3:
		_fail("real patrol actor has no global source position")
		return
	streamer.player_runtime_position = actor_position as Vector3
	var actor := load("res://scripts/fnv_actor.gd").new() as CharacterBody3D
	actor.position = actor_position as Vector3
	actor.call("configure", "NovacPatrolActor", "route-humanoid", {
		"actor_ref": ACTOR_REF, "actor_cell": CELLS[0], "actor_scope": "__exterior__",
		"actor_interior": false, "actor_linked_reference": CHAIN[0], "game_hour": 12.0,
		"packages": [streamer.actor_packages_by_id[PACKAGE_ID]],
		"reference_position_resolver": Callable(streamer, "_runtime_reference_position"),
		"reference_cell_resolver": Callable(streamer, "_runtime_reference_cell"),
		"reference_scope_resolver": Callable(streamer, "_runtime_reference_scope"),
		"reference_link_resolver": Callable(streamer, "_runtime_reference_link"),
		"package_route_resolver": Callable(streamer, "_package_route_step"),
	})
	actor.set_meta("fnv_form_id", ACTOR_REF)
	actor.set_meta("fnv_actor_id", "NovacPatrolActor")
	actor.set_meta("opennv_runtime_cell", CELLS[0])
	actor.set_meta("opennv_runtime_scope", "__exterior__")
	root.add_child(actor)
	await process_frame
	if not actor.patrol_route_mode or actor.travel_target_ref != CHAIN[0]:
		_fail("real authored Patrol package did not select its XLKR seed")
		return
	var first_corridor := streamer.call("_package_route_step", CELLS[0], CELLS[1]) as Dictionary
	if not bool(first_corridor.get("corridor", false)) \
			or str(first_corridor.get("destinationCell", "")) != CELLS[1] \
			or str(first_corridor.get("corridorCell", "")).is_empty():
		_fail("real cross-cell patrol did not select the authored NAVM seam: %s" % JSON.stringify(first_corridor))
		return
	var first_edge := streamer.call("_navmesh_cell_path_first_edge", CELLS[0], CELLS[1],
		streamer.primary_world_id) as Dictionary
	var expected_target_side := streamer.call("_runtime_position_in_cell",
		streamer.call("_array_to_vector3", first_edge.get("targetPosition", [])),
		streamer.call("_canonical_form_id", first_edge.get("cell", ""))) as Vector3
	if (first_corridor.get("position") as Vector3).distance_to(expected_target_side) > 0.001:
		_fail("corridor waypoint remained on the source side of the NAVM seam")
		return
	var cached_edge := streamer.call("_navmesh_cell_path_first_edge", CELLS[0], CELLS[1],
		streamer.primary_world_id) as Dictionary
	if cached_edge != first_edge or streamer.navmesh_cell_route_cache.size() != 1:
		_fail("immutable NAVM cell route was not cached")
		return
	for cell_id in CELLS:
		streamer.call("_load_navmesh_cell", cell_id, Vector3.ZERO, Vector3.ZERO, "__exterior__")
		streamer.loaded_actor_cells[cell_id] = true
	streamer.active_scope = "__exterior__"
	# Keep the fixture deterministic while the threaded NAVM jobs publish. The
	# route state is advanced explicitly below, not by free-running actor/stream
	# ticks during an asynchronous load.
	streamer.set_process(false)
	actor.set_process(false)
	actor.set_physics_process(false)
	streamer.actor_nodes_by_form_id[ACTOR_REF] = actor
	streamer.stream_nodes_by_cell[CELLS[0]] = [actor]
	streamer.actor_nodes_by_cell[CELLS[0]] = [actor]
	streamer.reference_ids_by_cell[CELLS[0]] = [ACTOR_REF]
	streamer.reference_runtime_cells[ACTOR_REF] = CELLS[0]
	actor.aerial = true
	actor.walk_speed = 24.0
	for _load_frame in range(240):
		streamer.call("_pump_navmesh_stream_jobs")
		var all_loaded := true
		for cell_id in CELLS:
			if not streamer.navigation_regions_by_cell.has(cell_id):
				all_loaded = false
				break
		if all_loaded:
			break
		await process_frame
	var first_region := streamer.navigation_regions_by_cell.get(CELLS[0]) as NavigationRegion3D
	if not is_instance_valid(first_region):
		_fail("real Novac patrol NAVM did not load pending=%d active=%d publish=%d regions=%d" % [
			streamer.pending_navmesh_cell_jobs.size(), streamer.active_navmesh_cell_jobs.size(),
			streamer.pending_navmesh_publish_jobs.size(), streamer.navigation_regions_by_cell.size()])
		return
	var navigation_map := first_region.get_navigation_map()
	actor.navigation_agent.set_navigation_map(navigation_map)
	for _sync in range(120):
		if NavigationServer3D.map_get_iteration_id(navigation_map) > 0:
			break
		await physics_frame
	for _settle in range(12):
		await physics_frame
	# Drive the real package state machine through each authored arrival. The
	# separate four-cell corridor test proves physical NavigationAgent movement;
	# this gate proves the retail Novac cycle, ownership changes, and eviction-
	# independent link resolution without spending a minute walking the fixture.
	var visited_cells: Dictionary = {}
	for index in range(CHAIN.size()):
		if actor.travel_target_ref != CHAIN[index]:
			_fail("Patrol target order diverged before hop %d: %s" % [index, actor.travel_target_ref])
			return
		actor.global_position = NavigationServer3D.map_get_closest_point(navigation_map, positions[index])
		actor.set_meta("opennv_runtime_cell", CELLS[index])
		actor.call("update_runtime_cell", CELLS[index], "__exterior__", false)
		visited_cells[CELLS[index]] = true
		actor.call("_resolve_authored_travel_target")
		var expected_next: String = CHAIN[index + 1] if index + 1 < CHAIN.size() else CHAIN[0]
		if actor.travel_target_ref != expected_next:
			_fail("Patrol did not advance from hop %d to %s pos=%s target=%s remain=%.3f resolved=%s route=%s map=%s iteration=%d" % [
				index, expected_next, actor.global_position, actor.travel_target_position,
				actor.global_position.distance_to(actor.travel_target_position),
				actor.travel_target_resolved, actor.package_route_waypoint,
				actor.navigation_agent.get_navigation_map(),
				NavigationServer3D.map_get_iteration_id(actor.navigation_agent.get_navigation_map())])
			return
	if actor.travel_target_ref != CHAIN[0] or visited_cells.size() != 3:
		_fail("real Novac Patrol did not wrap its three-cell authored cycle")
		return
	actor.queue_free()
	await process_frame
	print("OPENNV_GLOBAL_LINKED_REFERENCE_PASS nodes=8202 actor=%s hops=%d cells=%d wrapped=1" % [
		ACTOR_REF, CHAIN.size(), visited_cells.size()])
	quit(0)


func _fail(reason: String) -> void:
	push_error("OPENNV_GLOBAL_LINKED_REFERENCE_FAIL %s" % reason)
	quit(1)
