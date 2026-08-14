extends SceneTree


func _initialize() -> void:
	ProjectSettings.set_setting("navigation/3d/warnings/navmesh_edge_merge_errors", false)
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	root.add_child(streamer)
	await process_frame
	streamer.call("_load_navmesh_index")
	var cells := ["0x00084341", "0x00084340"]
	for cell_id in cells:
		streamer.loaded_actor_cells[cell_id] = true
		streamer.call("_load_navmesh_cell", cell_id, Vector3.ZERO, Vector3.ZERO, "__exterior__")
	var repaired_link: NavigationLink3D
	for _frame in range(120):
		for link_value in streamer.navigation_links_by_key.values():
			var link := link_value as NavigationLink3D
			if bool(link.get_meta("opennv_repaired_external", false)):
				repaired_link = link
				break
		if repaired_link != null:
			break
		await physics_frame
	if repaired_link == null:
		var source := streamer.navmesh_runtime_records_by_id.get("0x000eae0c", {}) as Dictionary
		var target := streamer.navmesh_runtime_records_by_id.get("0x000eae0a", {}) as Dictionary
		var nearest := streamer.call("_closest_navmesh_centroid_pair", source, target, 500.0) as Dictionary
		var nearest_distance := INF
		if not nearest.is_empty():
			nearest_distance = (nearest.get("source") as Vector3).distance_to(nearest.get("target") as Vector3)
		_fail("known malformed retail external edge was not repaired nearest=%.3fm" % nearest_distance)
		return
	var navigation_map := streamer.get_world_3d().navigation_map
	for _frame in range(120):
		if NavigationServer3D.map_get_iteration_id(navigation_map) > 0:
			break
		await physics_frame
	for _frame in range(12):
		await physics_frame
	var start := repaired_link.global_transform * repaired_link.start_position
	var finish := repaired_link.global_transform * repaired_link.end_position
	var path := NavigationServer3D.map_get_path(navigation_map, start, finish, true)
	if path.size() < 2 or path[path.size() - 1].distance_to(finish) > 0.5:
		_fail("repaired retail seam is not routable")
		return
	for cell_id in cells:
		streamer.call("_retire_navmesh_cell", cell_id)
	await process_frame
	if not streamer.navigation_links_by_key.is_empty() or not streamer.navmesh_runtime_records_by_id.is_empty():
		_fail("repaired seam leaked after retirement")
		return
	print("OPENNV_NAVMESH_EXTERNAL_REPAIR_PASS cells=2 path_points=%d" % path.size())
	quit(0)


func _fail(reason: String) -> void:
	push_error("OPENNV_NAVMESH_EXTERNAL_REPAIR_FAIL %s" % reason)
	quit(1)
