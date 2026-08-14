extends SceneTree

const AUXILIARY_NAME := "PCloud02Smoke-Emitter"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var actor_path := "user://opennv-v3-auxiliary-test.onvskel"
	var animation_path := "user://opennv-v3-auxiliary-test.onvanim"
	if not _write_actor(actor_path) or not _write_animation(animation_path):
		_fail("could not create fixture")
		return
	var actor := load("res://scripts/opennv_skeletal_actor_loader.gd").call("load_scene", actor_path) as Node3D
	if actor == null or int(actor.get_meta("opennv_skeletal_format_version", 0)) != 3 \
			or int(actor.get_meta("opennv_auxiliary_node_count", 0)) != 1:
		_fail("v3 actor or auxiliary census did not load")
		return
	root.add_child(actor)
	var auxiliary := _find_auxiliary(actor)
	if auxiliary == null:
		_fail("auxiliary node was not built")
		return
	var player := load("res://scripts/opennv_animation_loader.gd").call(
		"attach_clip", actor, animation_path, "auxiliary_test") as AnimationPlayer
	if player == null or int(actor.get_meta("opennv_animation_source_tracks", 0)) != 1 \
			or int(actor.get_meta("opennv_animation_matched_tracks", 0)) != 1:
		_fail("auxiliary animation track did not bind")
		return
	player.pause()
	player.seek(0.0, true)
	player.advance(0.0)
	await process_frame
	var start := auxiliary.transform
	var expected_start := Vector3(1.0, 0.0, -2.0)
	if not start.origin.is_equal_approx(expected_start):
		_fail("frame-zero absolute local transform did not preserve auxiliary bind offset actual=%s expected=%s" % [
			start.origin, expected_start])
		return
	player.seek(0.5, true)
	player.advance(0.0)
	await process_frame
	var finish := auxiliary.transform
	if start.is_equal_approx(finish) or finish.origin.x < 1.45:
		_fail("bound auxiliary node did not move")
		return
	actor.free()
	await process_frame
	print("OPENNV_GODOT_SKELETAL_V3_AUXILIARY_ANIMATION_PASS")
	quit(0)


func _write_actor(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer("ONVSKEL3".to_ascii_buffer())
	file.store_32(3)
	file.store_32(0)
	file.store_32(1)
	_store_string(file, "Bip01")
	file.store_32(0xffffffff)
	_store_identity(file)
	_store_identity(file)
	file.store_32(1)
	_store_string(file, AUXILIARY_NAME)
	_store_string(file, "Bip01")
	_store_translation(file, Vector3(70.0, 140.0, 0.0))
	_store_translation(file, Vector3(70.0, 140.0, 0.0))
	file.close()
	return true


func _write_animation(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer("ONVANIM1".to_ascii_buffer())
	file.store_32(1)
	file.store_float(30.0)
	file.store_float(1.0)
	file.store_32(31)
	file.store_32(1)
	file.store_32(0)
	_store_string(file, AUXILIARY_NAME)
	for frame in range(31):
		file.store_8(1)
		file.store_float(70.0 + float(frame) / 30.0 * 70.0)
		file.store_float(140.0)
		file.store_float(0.0)
	file.close()
	return true


func _store_string(file: FileAccess, value: String) -> void:
	var bytes := value.to_utf8_buffer()
	file.store_32(bytes.size())
	file.store_buffer(bytes)


func _store_identity(file: FileAccess) -> void:
	for value in [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
			0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]:
		file.store_float(value)


func _store_translation(file: FileAccess, translation: Vector3) -> void:
	for value in [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
			0.0, 0.0, 1.0, 0.0, translation.x, translation.y, translation.z, 1.0]:
		file.store_float(value)


func _find_auxiliary(node: Node) -> Node3D:
	if node is Node3D and str(node.get_meta("opennv_source_auxiliary_name", "")) == AUXILIARY_NAME:
		return node as Node3D
	for child in node.get_children():
		var found := _find_auxiliary(child)
		if found != null:
			return found
	return null


func _fail(message: String) -> void:
	push_error("OPENNV_GODOT_SKELETAL_V3_AUXILIARY_ANIMATION_FAIL " + message)
	quit(1)
