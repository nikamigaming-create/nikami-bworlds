extends SceneTree


func _initialize() -> void:
	ProjectSettings.set_setting("navigation/3d/warnings/navmesh_edge_merge_errors", false)
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	root.add_child(streamer)
	await process_frame
	streamer.call("_load_navmesh_index")
	var cell_id := "0x0010d629"
	streamer.active_scope = cell_id
	streamer.staged_interiors[cell_id] = true
	streamer.call("_load_navmesh_cell", cell_id, Vector3.ZERO, Vector3.ZERO, cell_id)
	var initially_pending: int = streamer.pending_navmesh_cell_jobs.size()
	var same_cell_links: Array[NavigationLink3D] = []
	for _frame in range(120):
		same_cell_links.clear()
		for link_value in streamer.navigation_links_by_key.values():
			var link := link_value as NavigationLink3D
			if str(link.get_meta("opennv_source_cell", "")) == cell_id \
					and str(link.get_meta("opennv_destination_cell", "")) == cell_id:
				same_cell_links.append(link)
		if not same_cell_links.is_empty():
			break
		await process_frame
	if same_cell_links.is_empty():
		_fail("Gomorrah authored same-cell NAVM links were discarded index=%s fast=%s initial=%d pending=%d active=%d regions=%d records=%d" % [
			streamer.navmesh_index_by_cell.has(cell_id), streamer.call("_headless_fast_residency"), initially_pending, streamer.pending_navmesh_cell_jobs.size(),
			streamer.active_navmesh_cell_jobs.size(), streamer.navigation_regions_by_cell.size(),
			streamer.navmesh_runtime_records_by_id.size()])
		return
	var navigation_map := streamer.get_world_3d().navigation_map
	for _frame in range(120):
		if NavigationServer3D.map_get_iteration_id(navigation_map) > 0:
			break
		await physics_frame
	for _frame in range(12):
		await physics_frame
	var routed := false
	for link in same_cell_links:
		var start := link.global_transform * link.start_position
		var finish := link.global_transform * link.end_position
		var path := NavigationServer3D.map_get_path(navigation_map, start, finish, true)
		if path.size() >= 2 and path[path.size() - 1].distance_to(finish) <= 0.5:
			routed = true
			break
	if not routed:
		_fail("Gomorrah same-cell authored links are not routable")
		return
	streamer.call("_retire_navmesh_cell", cell_id)
	await process_frame
	if not streamer.navigation_links_by_key.is_empty():
		_fail("same-cell NAVM links leaked after retirement")
		return
	print("OPENNV_SAME_CELL_NAVM_LINK_PASS cell=%s links=%d" % [cell_id, same_cell_links.size()])
	quit(0)


func _fail(reason: String) -> void:
	push_error("OPENNV_SAME_CELL_NAVM_LINK_FAIL %s" % reason)
	quit(1)
