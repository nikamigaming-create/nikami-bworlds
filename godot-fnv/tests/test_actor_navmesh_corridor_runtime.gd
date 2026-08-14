extends SceneTree

var corridor_target := Vector3.ZERO


func _initialize() -> void:
	ProjectSettings.set_setting("navigation/3d/warnings/navmesh_edge_merge_errors", false)
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	root.add_child(streamer)
	streamer.call("_load_navmesh_index")
	var source_origin := Vector3(-72392.8438, -1240.19275, 8137.58643)
	var cells := ["0x000e1aa7", "0x000daebb", "0x000daeb9", "0x000daeb8"]
	var world_id := "0x000da726"
	streamer.primary_world_id = world_id
	streamer.active_exterior_world_id = world_id
	streamer.source_origin = source_origin
	for cell_id in cells:
		streamer.cell_indices_by_id[cell_id] = {
			"form_id": cell_id, "world_form_id": world_id, "grid": [0, 0],
		}
	var production_first_edge := streamer.call(
		"_navmesh_cell_path_first_edge", cells[0], cells[cells.size() - 1], world_id) as Dictionary
	if streamer.call("_canonical_form_id", production_first_edge.get("cell", "")) != cells[1]:
		_fail("production NAVM adjacency planner did not discover the authored first cell")
		return
	var production_step := streamer.call(
		"_package_exterior_corridor_step", cells[0], cells[cells.size() - 1], 0.0) as Dictionary
	if str(production_step.get("corridorCell", "")) != cells[1] \
			or not production_step.get("position") is Vector3:
		_fail("production package corridor did not return the authored seam waypoint")
		return
	streamer.pending_actor_cell_promotions.clear()
	streamer.pending_actor_cell_promotion_ids.clear()
	for cell_id in cells:
		streamer.loaded_actor_cells[cell_id] = true
		streamer.call("_load_navmesh_cell", cell_id, source_origin, Vector3.ZERO, "__exterior__")
	for _load_frame in range(240):
		await process_frame
		if streamer.navigation_regions_by_cell.size() == cells.size():
			break
	if streamer.navigation_regions_by_cell.size() != cells.size():
		_fail("multi-cell NAVM corridor did not become resident")
		return
	if streamer.navigation_links_by_key.is_empty():
		_fail("authored external NAVM records created no runtime links")
		return
	var first_region := streamer.navigation_regions_by_cell[cells[0]] as NavigationRegion3D
	var last_region := streamer.navigation_regions_by_cell[cells[cells.size() - 1]] as NavigationRegion3D
	var navigation_map := first_region.get_navigation_map()
	for _sync_frame in range(120):
		if NavigationServer3D.map_get_iteration_id(navigation_map) > 0:
			break
		await physics_frame
	if NavigationServer3D.map_get_iteration_id(navigation_map) == 0:
		_fail("multi-cell navigation map did not synchronize")
		return
	for _settle_frame in range(12):
		await physics_frame
	var first_vertices := first_region.navigation_mesh.get_vertices()
	var last_vertices := last_region.navigation_mesh.get_vertices()
	var corridor_path := PackedVector3Array()
	var corridor_start := Vector3.ZERO
	for start_index in range(0, first_vertices.size(), maxi(1, first_vertices.size() / 30)):
		for target_index in range(0, last_vertices.size(), maxi(1, last_vertices.size() / 30)):
			var candidate := NavigationServer3D.map_get_path(navigation_map,
				first_vertices[start_index], last_vertices[target_index], true)
			if candidate.size() >= 2 \
					and candidate[candidate.size() - 1].distance_to(last_vertices[target_index]) <= 0.5 \
					and candidate[0].distance_to(candidate[candidate.size() - 1]) > 20.0:
				corridor_start = first_vertices[start_index]
				corridor_target = last_vertices[target_index]
				corridor_path = candidate
				break
		if not corridor_path.is_empty():
			break
	if corridor_path.is_empty():
		_fail("no connected real multi-cell NAVM corridor")
		return
	var actor := load("res://scripts/fnv_actor.gd").new() as CharacterBody3D
	actor.position = corridor_start
	actor.call("configure", "corridor-runtime-test", "route-creature", {
		"actor_ref": "0x00002000", "actor_cell": cells[0], "actor_scope": "__exterior__",
		"game_hour": 12.0, "reference_position_resolver": Callable(self, "_resolve_corridor_target"),
		"packages": [{"id": "0x00000006", "packageData": {"type": 6},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageTarget": {"type": 0, "target": "0x00003000"}, "conditionData": []}],
	})
	root.add_child(actor)
	actor.walk_speed = 20.0
	actor.aerial = true
	actor.navigation_agent.path_desired_distance = 2.5
	var resolved := false
	var minimum_remaining := INF
	var maximum_path_index := 0
	var maximum_displacement := 0.0
	var corridor_distance := corridor_start.distance_to(corridor_target)
	for _frame in range(1200):
		await physics_frame
		# The production actor is grounded by the world's authored collision.
		# This focused NAVM-only fixture has no terrain body, so keep the test
		# capsule on the authored surface while exercising horizontal steering.
		var surface_point := NavigationServer3D.map_get_closest_point(navigation_map, actor.global_position)
		actor.global_position.y = surface_point.y
		resolved = resolved or bool(actor.get_meta("opennv_package_target_resolved", false))
		minimum_remaining = minf(minimum_remaining, actor.global_position.distance_to(corridor_target))
		maximum_path_index = maxi(maximum_path_index, actor.navigation_agent.get_current_navigation_path_index())
		maximum_displacement = maxf(maximum_displacement, actor.global_position.distance_to(corridor_start))
		if maximum_displacement > 100.0 and maximum_path_index >= 20 \
				and minimum_remaining < corridor_distance - 50.0:
			break
	if not resolved or maximum_displacement <= 100.0 or maximum_path_index < 20 \
			or minimum_remaining >= corridor_distance - 50.0:
		_fail("actor did not traverse the real cross-cell route resolved=%s stuck=%s nearest=%.2f moved=%.2f max_path_index=%d" % [
			resolved, actor.get_meta("opennv_package_stuck", false),
			minimum_remaining, maximum_displacement, maximum_path_index])
		return
	actor.queue_free()
	await process_frame
	for cell_id in cells:
		streamer.call("_retire_navmesh_cell", cell_id)
	await process_frame
	if not streamer.navigation_links_by_key.is_empty() or not streamer.navmesh_runtime_records_by_id.is_empty():
		_fail("cross-cell NAVM links or records leaked after cell retirement")
		return
	print("OPENNV_ACTOR_NAVMESH_CORRIDOR_PASS cells=%d path_points=%d distance=%.2f moved=%.2f" % [
		cells.size(), corridor_path.size(), corridor_distance, maximum_displacement])
	quit(0)


func _resolve_corridor_target(_ref: Variant) -> Vector3:
	return corridor_target


func _fail(reason: String) -> void:
	push_error("OPENNV_ACTOR_NAVMESH_CORRIDOR_FAIL %s" % reason)
	quit(1)
