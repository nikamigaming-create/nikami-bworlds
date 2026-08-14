extends SceneTree

var test_travel_target := Vector3.ZERO


func _initialize() -> void:
	# The shipped Goodsprings NAVMs contain one intentional overlapping edge.
	# Its authored anomaly is counted by the compiler; keep this lifecycle test
	# focused on topology, traversal, and retirement rather than stderr policy.
	ProjectSettings.set_setting("navigation/3d/warnings/navmesh_edge_merge_errors", false)
	var streamer_script := load("res://scripts/fnv_cell_streamer.gd")
	var streamer := streamer_script.new() as Node3D
	root.add_child(streamer)
	streamer.call("_load_navmesh_index")
	if (streamer.navmesh_index_by_cell as Dictionary).size() != 3650:
		_fail("runtime index cell census")
		return
	var cell_id := "0x000e1aa7"
	var source_origin := Vector3(-72392.8438, -1240.19275, 8137.58643)
	streamer.loaded_actor_cells[cell_id] = true
	streamer.call("_load_navmesh_cell", cell_id, source_origin, Vector3.ZERO, "__exterior__")
	for _frame in range(120):
		await process_frame
		if (streamer.navigation_regions_by_cell as Dictionary).has(cell_id):
			break
	var stats := streamer.call("runtime_stats") as Dictionary
	if int(stats.get("resident_navmesh_cells", 0)) != 1:
		_fail("NAVM cell did not become resident")
		return
	var region := (streamer.navigation_regions_by_cell as Dictionary).get(cell_id) as NavigationRegion3D
	if region == null or not region.enabled or region.navigation_mesh == null:
		_fail("NAVM region is not active")
		return
	if region.navigation_mesh.get_polygon_count() != 457 or region.navigation_mesh.get_vertices().size() != 350:
		_fail("Goodsprings NAVM topology census")
		return
	var actor_script := load("res://scripts/fnv_actor.gd")
	var actor := actor_script.new() as CharacterBody3D
	actor.call("configure", "raven-nav-runtime-test", "route-creature", {
		"game_hour": 12.0,
		"packages": [{"id": "0x5", "packageData": {"type": 12},
			"packageSchedule": {"time": 255, "duration": 0}, "packageLocation": {"radius": 350}}],
	})
	actor.position = region.navigation_mesh.get_vertices()[0]
	root.add_child(actor)
	var actor_start := actor.global_position
	for _frame in range(240):
		await physics_frame
	if actor.global_position.distance_to(actor_start) < 0.2:
		_fail("PACK actor did not traverse authored NAVM")
		return
	var navigation_map := region.get_navigation_map()
	var closest := NavigationServer3D.map_get_closest_point(navigation_map, actor.global_position)
	if closest.distance_to(actor.global_position) > 0.45:
		_fail("PACK actor left authored NAVM")
		return
	actor.queue_free()
	await process_frame
	var vertices := region.navigation_mesh.get_vertices()
	var travel_start := vertices[0]
	var travel_path := PackedVector3Array()
	for candidate in vertices:
		if candidate.distance_to(travel_start) < 1.0 or candidate.distance_to(travel_start) > 2.2:
			continue
		var candidate_path := NavigationServer3D.map_get_path(navigation_map, travel_start, candidate, true)
		if not candidate_path.is_empty():
			test_travel_target = candidate
			travel_path = candidate_path
			break
	if travel_path.is_empty():
		_fail("no bounded reachable NAVM Travel fixture")
		return
	var traveler := actor_script.new() as CharacterBody3D
	traveler.position = travel_start
	traveler.call("configure", "raven-travel-nav-runtime-test", "route-creature", {
		"game_hour": 12.0,
		"reference_position_resolver": Callable(self, "_resolve_test_reference"),
		"packages": [{"id": "0x6", "packageData": {"type": 6},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageTarget": {"type": 0, "target": "0x00001234"}}],
	})
	root.add_child(traveler)
	var was_resolved := false
	for _frame in range(300):
		await physics_frame
		was_resolved = was_resolved or bool(traveler.get_meta("opennv_package_target_resolved", false))
		if bool(traveler.get_meta("opennv_package_arrived", false)):
			break
	if not was_resolved or not bool(traveler.get_meta("opennv_package_arrived", false)):
		_fail("real Travel package did not resolve a NAVM path and arrive")
		return
	traveler.queue_free()
	await process_frame
	streamer.call("_retire_navmesh_cell", cell_id)
	await process_frame
	stats = streamer.call("runtime_stats") as Dictionary
	if int(stats.get("resident_navmesh_cells", -1)) != 0:
		_fail("NAVM cell did not retire")
		return
	print("OPENNV_AUTHORED_NAVMESH_RUNTIME_PASS cell=%s vertices=350 triangles=457" % cell_id)
	quit(0)


func _resolve_test_reference(_ref_id: Variant) -> Vector3:
	return test_travel_target


func _fail(reason: String) -> void:
	push_error("OPENNV_AUTHORED_NAVMESH_RUNTIME_FAIL %s" % reason)
	quit(1)
