extends SceneTree

const SOURCE_ROOT := "res://generated/assets/converted"
const CACHE_DIR := "res://local/runtime-cache/world-mesh-v1"
const REPORT := "res://local/runtime-cache/world-mesh-v1-report.json"
const PATH_INDEX := "res://local/runtime-cache/world-mesh-v1-path-index.json"


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	var sources: Array[String] = []
	_collect_obj_sources(SOURCE_ROOT, sources)
	sources.sort()
	var paths: Dictionary = {}
	var path_collisions: Array[String] = []
	for source_path in sources:
		var relative := source_path.trim_prefix(SOURCE_ROOT + "/")
		var model_key := relative.left(relative.length() - 4).replace("/", "\\").to_lower() + ".nif"
		var destination := streamer.call("_world_mesh_cache_path", source_path) as String
		if paths.has(model_key) and str(paths[model_key]) != destination:
			path_collisions.append(model_key)
		else:
			paths[model_key] = destination
	var limit_text := OS.get_environment("FNV_GODOT_WORLD_MESH_CACHE_LIMIT")
	var limit := limit_text.to_int() if limit_text.is_valid_int() else 0
	var built := 0
	var reused := 0
	var failed: Array[String] = []
	var started := Time.get_ticks_msec()
	for source_path in sources:
		if limit > 0 and built >= limit:
			break
		var destination := streamer.call("_world_mesh_cache_path", source_path) as String
		if ResourceLoader.exists(destination):
			reused += 1
			continue
		var imported := load(source_path) as Mesh
		if imported == null or imported.get_surface_count() == 0:
			failed.append("load:%s" % source_path)
			continue
		var mesh := imported.duplicate(true) as Mesh
		streamer.call("_apply_nif_material_semantics", mesh, source_path, true)
		mesh = streamer.call("_split_render_and_collision_surfaces", mesh, source_path) as Mesh
		mesh.set_meta("opennv_source_path", source_path)
		mesh.set_meta("opennv_runtime_processed", true)
		if bool(mesh.get_meta("opennv_has_collision", false)):
			var collision_mesh := streamer.call("_collision_mesh_for", mesh) as Mesh
			if collision_mesh != null:
				var shape := collision_mesh.create_trimesh_shape()
				if shape != null:
					mesh.set_meta("opennv_collision_shape", shape)
		var error := ResourceSaver.save(mesh, destination)
		if error != OK:
			failed.append("save:%s" % source_path)
			continue
		built += 1
		if built % 50 == 0:
			print("OPENNV_WORLD_MESH_CACHE_PROGRESS built=%d reused=%d total=%d elapsed_sec=%.1f" % [
				built, reused, sources.size(), float(Time.get_ticks_msec() - started) / 1000.0])
	var processed := built + reused
	var complete := limit <= 0 and failed.is_empty() and path_collisions.is_empty() \
		and processed == sources.size() and paths.size() == sources.size()
	var path_index := {
		"schema": "opennv-world-mesh-path-index/v1", "status": "pass" if complete else "fail",
		"sourceCount": sources.size(), "sourcePathLedgerSha256": "\n".join(sources).sha256_text(),
		"paths": paths, "collisions": path_collisions,
	}
	var path_output := FileAccess.open(PATH_INDEX, FileAccess.WRITE)
	if path_output != null:
		path_output.store_string(JSON.stringify(path_index))
	var report := {
		"schema": "opennv-world-mesh-cache/v1",
		"status": "pass" if complete else ("diagnostic" if limit > 0 and failed.is_empty() else "fail"),
		"complete": complete,
		"sourceRoot": SOURCE_ROOT, "sourceCount": sources.size(),
		"sourcePathLedgerSha256": "\n".join(sources).sha256_text(),
		"pathIndexCount": paths.size(), "pathCollisions": path_collisions,
		"built": built, "reused": reused, "processed": processed, "failures": failed,
		"elapsedMsec": Time.get_ticks_msec() - started,
	}
	var output := FileAccess.open(REPORT, FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify(report, "  "))
	print("OPENNV_WORLD_MESH_CACHE_BUILD_%s built=%d reused=%d failures=%d total=%d elapsed_sec=%.1f" % [
		"PASS" if complete else ("DIAGNOSTIC" if limit > 0 and failed.is_empty() else "FAIL"), built, reused, failed.size(), sources.size(),
		float(Time.get_ticks_msec() - started) / 1000.0])
	streamer.free()
	quit(0 if failed.is_empty() else 3)


func _collect_obj_sources(directory_path: String, output: Array[String]) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if name != "." and name != "..":
			var child := directory_path.path_join(name)
			if directory.current_is_dir():
				_collect_obj_sources(child, output)
			elif name.to_lower().ends_with(".obj"):
				output.append(child)
		name = directory.get_next()
	directory.list_dir_end()
