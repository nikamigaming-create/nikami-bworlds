extends SceneTree

const MANIFEST := "res://generated/actors/actor-manifest-skeletal-v8.json"
const CACHE_DIR := "res://local/runtime-cache/skeletal-v1"
const REPORT := "res://local/runtime-cache/skeletal-v1-report.json"

func _init() -> void:
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not document is Dictionary:
		push_error("OPENNV_SKELETAL_CACHE_BUILD_FAIL manifest")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	var loader := load("res://scripts/opennv_skeletal_actor_loader.gd")
	var animation_loader := load("res://scripts/opennv_animation_loader.gd")
	var limit_text := OS.get_environment("FNV_GODOT_SKELETAL_CACHE_LIMIT")
	var limit := limit_text.to_int() if limit_text.is_valid_int() else 0
	var seen: Dictionary = {}
	var built := 0
	var reused := 0
	var failed: Array[String] = []
	var started := Time.get_ticks_msec()
	for actor_value in document.get("actors", []):
		var actor := actor_value as Dictionary
		var skeletal := str(actor.get("skeletal", ""))
		var skeletal_hash := str(actor.get("skeletal_sha256", ""))
		var animation := str(actor.get("animation_idle", ""))
		var animation_hash := str(actor.get("animation_idle_sha256", ""))
		if skeletal.is_empty() or skeletal_hash.is_empty():
			continue
		var key := _cache_key(skeletal_hash, animation_hash)
		if seen.has(key):
			reused += 1
			continue
		seen[key] = true
		if not FileAccess.file_exists(skeletal) or FileAccess.get_sha256(skeletal).to_lower() != skeletal_hash.to_lower():
			failed.append("skeletal:%s" % skeletal)
			continue
		if not animation.is_empty() and (animation_hash.is_empty() or not FileAccess.file_exists(animation) \
				or FileAccess.get_sha256(animation).to_lower() != animation_hash.to_lower()):
			failed.append("animation:%s" % animation)
			continue
		var destination := "%s/%s.scn" % [CACHE_DIR, key]
		if ResourceLoader.exists(destination):
			reused += 1
			continue
		if limit > 0 and built >= limit:
			break
		var scene := loader.call("load_scene", skeletal) as Node3D
		if scene == null:
			failed.append(skeletal)
			continue
		if not animation.is_empty() and FileAccess.file_exists(animation):
			animation_loader.call("attach_clip", scene, animation, "idle")
		scene.set_meta("opennv_cache_skeletal_sha256", skeletal_hash)
		scene.set_meta("opennv_cache_animation_sha256", animation_hash)
		_set_owner_recursive(scene, scene)
		var packed := PackedScene.new()
		var error := packed.pack(scene)
		if error == OK:
			error = ResourceSaver.save(packed, destination)
		scene.free()
		if error != OK:
			failed.append(skeletal)
			continue
		built += 1
		if built % 50 == 0:
			print("OPENNV_SKELETAL_CACHE_PROGRESS built=%d unique=%d elapsed_sec=%.1f" % [
				built, seen.size(), float(Time.get_ticks_msec() - started) / 1000.0])
	var report := {
		"schema": "opennv-skeletal-scene-cache/v1",
		"status": "pass" if failed.is_empty() else "fail",
		"manifestSha256": FileAccess.get_sha256(MANIFEST),
		"uniqueKeysVisited": seen.size(), "built": built, "reused": reused,
		"failures": failed, "elapsedMsec": Time.get_ticks_msec() - started,
	}
	var report_file := FileAccess.open(REPORT, FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "  "))
	print("OPENNV_SKELETAL_CACHE_BUILD_%s built=%d reused=%d failures=%d elapsed_sec=%.1f" % [
		"PASS" if failed.is_empty() else "FAIL", built, reused, failed.size(),
		float(Time.get_ticks_msec() - started) / 1000.0])
	quit(0 if failed.is_empty() else 3)


static func cache_path(skeletal_hash: String, animation_hash: String) -> String:
	return "%s/%s.scn" % [CACHE_DIR, _cache_key(skeletal_hash, animation_hash)]


static func _cache_key(skeletal_hash: String, animation_hash: String) -> String:
	return "%s-%s" % [skeletal_hash.substr(0, 32),
		animation_hash.substr(0, 32) if not animation_hash.is_empty() else "none"]


func _set_owner_recursive(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_set_owner_recursive(child, root)
