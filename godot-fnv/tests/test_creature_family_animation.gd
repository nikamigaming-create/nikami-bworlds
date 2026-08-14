extends SceneTree

const MANIFEST := "res://generated/actors/actor-manifest-skeletal-v8.json"
func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var document := JSON.parse_string(FileAccess.get_file_as_string(MANIFEST)) as Dictionary
	var checked := 0
	for promotion_value in document.get("creature_idle_promotions", []):
		var promotion := promotion_value as Dictionary
		var animation_path := str(promotion.get("animation", ""))
		var record: Dictionary = {}
		for value in document.get("actors", []):
			var actor := value as Dictionary
			if str(actor.get("animation_idle", "")) == animation_path and not str(actor.get("skeletal", "")).is_empty():
				record = actor
				break
		var model := str(promotion.get("model", "")).to_lower()
		var allows_static_idle := "sentryturret" in model or "bighorner" in model
		if record.is_empty() or not await _check_actor(record, animation_path, allows_static_idle):
			return
		checked += 1
	if checked < 11:
		_fail("creature promotion census is incomplete count=%d" % checked)
		return
	print("OPENNV_CREATURE_FAMILY_ANIMATION_PASS families=%d" % checked)
	quit(0)


func _check_actor(record: Dictionary, animation_path: String, allows_static_idle: bool) -> bool:
	var actor_node := load("res://scripts/opennv_skeletal_actor_loader.gd").call(
		"load_scene", str(record.get("skeletal", ""))) as Node3D
	if actor_node == null:
		_fail("dog skeletal actor did not load")
		return false
	root.add_child(actor_node)
	var player := load("res://scripts/opennv_animation_loader.gd").call(
		"attach_clip", actor_node, animation_path, "idle") as AnimationPlayer
	if player == null:
		_fail("creature animation did not attach path=%s" % animation_path)
		return false
	var source_tracks := int(actor_node.get_meta("opennv_animation_source_tracks", 0))
	var matched_tracks := int(actor_node.get_meta("opennv_animation_matched_tracks", 0))
	if source_tracks <= 0 or matched_tracks != source_tracks:
		_fail("creature track coverage path=%s source=%d matched=%d" % [animation_path, source_tracks, matched_tracks])
		return false
	var skeleton := _find_skeleton(actor_node)
	if skeleton == null:
		_fail("creature canonical skeleton is missing path=%s" % animation_path)
		return false
	var animation := player.get_animation("idle")
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	if not bool(streamer.call("_actor_idle_animation_runtime_safe", record)):
		streamer.call("_quarantine_unsafe_actor_animation", actor_node, record)
		if not bool(actor_node.get_meta("opennv_animation_quarantined", false)) or player.is_playing():
			streamer.free()
			_fail("unsafe creature animation was not quarantined path=%s" % animation_path)
			return false
		streamer.free()
		print("OPENNV_CREATURE_FAMILY_ANIMATION_QUARANTINED actor=%s path=%s" % [
			record.get("authored_ref", ""), animation_path])
		actor_node.queue_free()
		await process_frame
		return true
	streamer.free()
	player.seek(0.0, true)
	player.advance(0.0)
	await process_frame
	var start := _bone_poses(skeleton)
	var moved := 0
	for fraction in [0.25, 0.5, 0.75, 1.0]:
		player.seek(animation.length * float(fraction), true)
		player.advance(0.0)
		await process_frame
		var finish := _bone_poses(skeleton)
		for index in range(mini(start.size(), finish.size())):
			if not (start[index] as Transform3D).is_equal_approx(finish[index] as Transform3D):
				moved += 1
		if moved > 0:
			break
	if moved == 0 and not allows_static_idle:
		_fail("creature animation produced no bone motion path=%s" % animation_path)
		return false
	print("OPENNV_CREATURE_FAMILY_ANIMATION_ACTOR actor=%s tracks=%d moved_bones=%d path=%s" % [
		record.get("authored_ref", ""), matched_tracks, moved, animation_path])
	actor_node.queue_free()
	await process_frame
	return true


func _find_skeleton(node: Node) -> Skeleton3D:
	var best := node as Skeleton3D if node is Skeleton3D else null
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null and (best == null or found.get_bone_count() > best.get_bone_count()):
			best = found
	return best


func _bone_poses(skeleton: Skeleton3D) -> Array[Transform3D]:
	var values: Array[Transform3D] = []
	for index in range(skeleton.get_bone_count()):
		values.append(skeleton.get_bone_global_pose(index))
	return values


func _fail(message: String) -> void:
	push_error("OPENNV_CREATURE_FAMILY_ANIMATION_FAIL " + message)
	quit(1)
