extends SceneTree


func _init() -> void:
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	if not bool(streamer.call("_validate_world_mesh_cache_contract")):
		_fail(streamer, "contract")
		return
	var converted := streamer.call("_converted_path", "sky\\sky planes\\WastelandSkyPlane.nif") as String
	if not converted.begins_with("res://local/runtime-cache/world-mesh-v1/") or not converted.ends_with(".res"):
		_fail(streamer, "selection:%s" % converted)
		return
	var mesh := ResourceLoader.load(converted) as Mesh
	if mesh == null or mesh.get_surface_count() == 0:
		_fail(streamer, "load:%s" % converted)
		return
	if not bool(mesh.get_meta("opennv_runtime_processed", false)):
		_fail(streamer, "processed-meta")
		return
	var stats := streamer.call("runtime_stats") as Dictionary
	if not bool(stats.get("world_mesh_cache_contract_valid", false)) \
			or int(stats.get("world_mesh_cache_source_count", 0)) != 9425 \
			or int(stats.get("world_mesh_cache_fallback_paths", -1)) != 0:
		_fail(streamer, "stats:%s" % JSON.stringify(stats))
		return
	print("OPENNV_WORLD_MESH_CACHE_PASS sources=%d surfaces=%d path=%s" % [
		int(stats.world_mesh_cache_source_count), mesh.get_surface_count(), converted])
	streamer.free()
	quit(0)


func _fail(streamer: Node, reason: String) -> void:
	push_error("OPENNV_WORLD_MESH_CACHE_FAIL %s" % reason)
	streamer.free()
	quit(2)
