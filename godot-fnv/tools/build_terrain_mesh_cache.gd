extends SceneTree

const INDEX_PATH := "res://generated/world/opennv-full-runtime-index.json"
const ROUTE_PATH := "res://generated/world/goodsprings-authored-road-route.json"
const CACHE_DIR := "res://local/runtime-cache/terrain-mesh-v2"
const REPORT_PATH := "res://local/runtime-cache/terrain-mesh-v2-report.json"
const SAMPLE_STEPS := [1, 4, 8]
const ROUTE_RADIUS_CELLS := 14


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	var index_document: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX_PATH))
	if not index_document is Dictionary:
		push_error("OPENNV_TERRAIN_MESH_CACHE_FAIL index")
		quit(2)
		return
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	var full_world := OS.get_environment("FNV_GODOT_TERRAIN_CACHE_FULL_WORLD") == "1"
	var route_document: Variant = JSON.parse_string(FileAccess.get_file_as_string(ROUTE_PATH))
	if not full_world and not route_document is Dictionary:
		push_error("OPENNV_TERRAIN_MESH_CACHE_FAIL route")
		streamer.free()
		quit(2)
		return
	var route_world := str((route_document as Dictionary).get("world_form_id", "")).to_lower() if route_document is Dictionary else ""
	var route_cells := _route_footprint(route_document as Dictionary) if route_document is Dictionary else {}
	var cells: Array[Dictionary] = []
	for cell_value in (index_document as Dictionary).get("cells", []):
		var cell_index := cell_value as Dictionary
		var grid := cell_index.get("grid", []) as Array
		var in_footprint := full_world or (str(cell_index.get("world_form_id", "")).to_lower() == route_world \
			and grid.size() >= 2 and route_cells.has("%d,%d" % [int(grid[0]), int(grid[1])]))
		if bool(cell_index.get("has_terrain", false)) and in_footprint:
			cells.append(cell_index)
	cells.sort_custom(func(a: Dictionary, b: Dictionary):
		return str(a.get("form_id", "")) < str(b.get("form_id", "")))
	var limit_text := OS.get_environment("FNV_GODOT_TERRAIN_CACHE_LIMIT")
	var limit := limit_text.to_int() if limit_text.is_valid_int() else 0
	var built := 0
	var reused := 0
	var processed_cells := 0
	var failures: Array[String] = []
	var ledger: Array[String] = []
	var started := Time.get_ticks_msec()
	for cell_index in cells:
		if limit > 0 and processed_cells >= limit:
			break
		var cell_id := str(cell_index.get("form_id", ""))
		var shard_path := str(cell_index.get("shard", ""))
		ledger.append("%s|%s" % [cell_id, shard_path])
		var shard_document: Variant = JSON.parse_string(FileAccess.get_file_as_string(shard_path))
		if not shard_document is Dictionary:
			failures.append("shard:%s" % cell_id)
			processed_cells += 1
			continue
		var terrain := (shard_document as Dictionary).get("terrain", {}) as Dictionary
		var heights := _decode_heights(terrain)
		if heights.size() != 1089:
			failures.append("terrain:%s" % cell_id)
			processed_cells += 1
			continue
		for sample_step in SAMPLE_STEPS:
			var destination := streamer.call("_terrain_mesh_cache_path", cell_id, sample_step) as String
			if ResourceLoader.exists(destination):
				reused += 1
				continue
			var mesh := streamer.call("_build_terrain_mesh", heights, sample_step) as ArrayMesh
			if mesh == null or mesh.get_surface_count() == 0:
				failures.append("mesh:%s:%d" % [cell_id, sample_step])
				continue
			mesh.set_meta("opennv_terrain_cell", cell_id)
			mesh.set_meta("opennv_terrain_sample_step", sample_step)
			if sample_step == 1:
				var shape := _build_heightmap_shape(heights)
				mesh.set_meta("opennv_collision_shape", shape)
			var error := ResourceSaver.save(mesh, destination)
			if error != OK:
				failures.append("save:%s:%d" % [cell_id, sample_step])
			else:
				built += 1
		processed_cells += 1
		if processed_cells % 100 == 0:
			print("OPENNV_TERRAIN_MESH_CACHE_PROGRESS cells=%d/%d built=%d reused=%d failures=%d elapsed_sec=%.1f" % [
				processed_cells, cells.size(), built, reused, failures.size(),
				float(Time.get_ticks_msec() - started) / 1000.0])
	var expected_resources := cells.size() * SAMPLE_STEPS.size()
	var processed_resources := built + reused
	var complete := limit <= 0 and failures.is_empty() and processed_cells == cells.size() \
		and processed_resources == expected_resources
	var report := {
		"schema": "opennv-terrain-mesh-cache/v2",
		"status": "pass" if complete else ("diagnostic" if limit > 0 and failures.is_empty() else "fail"),
		"complete": complete, "cellCount": cells.size(), "processedCells": processed_cells,
		"firstCell": str(cells[0].get("form_id", "")) if not cells.is_empty() else "",
		"coverage": "full-world" if full_world else "goodsprings-strip-radius-%d" % ROUTE_RADIUS_CELLS,
		"sampleSteps": SAMPLE_STEPS, "expectedResources": expected_resources,
		"built": built, "reused": reused, "processedResources": processed_resources,
		"failures": failures, "cellLedgerSha256": "\n".join(ledger).sha256_text(),
		"elapsedMsec": Time.get_ticks_msec() - started,
	}
	var output := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify(report, "  "))
	print("OPENNV_TERRAIN_MESH_CACHE_BUILD_%s cells=%d/%d built=%d reused=%d failures=%d elapsed_sec=%.1f" % [
		"PASS" if complete else ("DIAGNOSTIC" if limit > 0 and failures.is_empty() else "FAIL"),
		processed_cells, cells.size(), built, reused, failures.size(),
		float(Time.get_ticks_msec() - started) / 1000.0])
	streamer.free()
	quit(0 if failures.is_empty() else 3)


func _route_footprint(route: Dictionary) -> Dictionary:
	var route_grids: Dictionary = {}
	var previous := Vector2.ZERO
	var has_previous := false
	for waypoint_value in route.get("waypoints", []):
		var values := (waypoint_value as Dictionary).get("position", []) as Array
		if values.size() < 2:
			continue
		var point := Vector2(float(values[0]), float(values[1]))
		var segments := 1
		if has_previous:
			segments = maxi(1, ceili(previous.distance_to(point) / 2048.0))
		for index in range(segments + 1):
			var sample := point if not has_previous else previous.lerp(point, float(index) / float(segments))
			var center := Vector2i(floori(sample.x / 4096.0), floori(sample.y / 4096.0))
			for y in range(center.y - ROUTE_RADIUS_CELLS, center.y + ROUTE_RADIUS_CELLS + 1):
				for x in range(center.x - ROUTE_RADIUS_CELLS, center.x + ROUTE_RADIUS_CELLS + 1):
					route_grids["%d,%d" % [x, y]] = true
		previous = point
		has_previous = true
	return route_grids


func _decode_heights(terrain: Dictionary) -> PackedFloat32Array:
	var deltas := terrain.get("heightDeltas", []) as Array
	if deltas.size() != 1089:
		return PackedFloat32Array()
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
	return heights


func _build_heightmap_shape(heights: PackedFloat32Array) -> HeightMapShape3D:
	var shape := HeightMapShape3D.new()
	shape.map_width = 33
	shape.map_depth = 33
	var map_data := PackedFloat32Array()
	map_data.resize(1089)
	# HeightMap local Z grows in the opposite direction from the converted
	# Bethesda terrain mesh, so reverse rows while retaining X columns.
	for target_row in range(33):
		var source_row := 32 - target_row
		for column in range(33):
			map_data[target_row * 33 + column] = heights[source_row * 33 + column] / 128.0
	shape.map_data = map_data
	return shape
