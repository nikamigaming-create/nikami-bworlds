extends SceneTree


func _init() -> void:
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	if not bool(streamer.call("_validate_terrain_mesh_cache_contract")):
		_fail(streamer, "contract")
		return
	var report := JSON.parse_string(FileAccess.get_file_as_string(
		"res://local/runtime-cache/terrain-mesh-v2-report.json")) as Dictionary
	if int(report.get("cellCount", 0)) != 2110 or int(report.get("processedResources", 0)) != 6330:
		_fail(streamer, "counts:%s" % JSON.stringify(report))
		return
	var cached_path := streamer.call("_terrain_mesh_cache_path", str(report.get("firstCell", "")), 1) as String
	var cached_mesh := ResourceLoader.load(cached_path) as ArrayMesh
	if cached_mesh == null or not (cached_mesh.get_meta("opennv_collision_shape", null) is HeightMapShape3D):
		_fail(streamer, "heightmap:%s" % cached_path)
		return
	var heights := PackedFloat32Array()
	heights.resize(1089)
	for index in range(1089):
		heights[index] = float(index % 37) * 0.25
	var mesh := streamer.call("_build_terrain_mesh", heights, 4) as ArrayMesh
	if mesh == null or mesh.get_surface_count() != 1:
		_fail(streamer, "mesh")
		return
	var grid := Vector2i(2, -3)
	var angle := 0.37
	var translation := Vector3(123.0, -77.0, 19.0)
	var origin := Vector3(-5000.0, 800.0, 120.0)
	var transform := streamer.call("_terrain_local_transform", grid, angle, translation, origin) as Transform3D
	var vertices := mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var sample_column := 3
	var sample_row := 5
	var width := 9
	var local_vertex := vertices[sample_row * width + sample_column]
	var source := Vector3(grid.x * 4096.0 + sample_column * 4.0 * 128.0,
		grid.y * 4096.0 + sample_row * 4.0 * 128.0,
		heights[(sample_row * 4) * 33 + sample_column * 4])
	var rotated := Vector3(cos(angle) * source.x - sin(angle) * source.y,
		sin(angle) * source.x + cos(angle) * source.y, source.z) + translation
	var expected := Vector3(rotated.x - origin.x, rotated.z - origin.z, -(rotated.y - origin.y)) / 70.0
	var actual := transform * local_vertex
	if actual.distance_to(expected) > 0.0001:
		_fail(streamer, "transform actual=%s expected=%s" % [actual, expected])
		return
	var stats := streamer.call("runtime_stats") as Dictionary
	print("OPENNV_TERRAIN_MESH_CACHE_PASS cells=%d resources=%d residual=%.8f" % [
		int(stats.terrain_mesh_cache_cell_count), int(report.processedResources), actual.distance_to(expected)])
	streamer.free()
	quit(0)


func _fail(streamer: Node, reason: String) -> void:
	push_error("OPENNV_TERRAIN_MESH_CACHE_FAIL %s" % reason)
	streamer.free()
	quit(2)
