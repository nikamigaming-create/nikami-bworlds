extends SceneTree

const HUMANOID := "res://generated/actors/skeletal-v2-canonical-validation-r7-20260810/actor-000.onvskel"
const HUMANOID_IDLE := "res://generated/animations/authored-v1/humanoid-mtidle.onvanim"
const VICTOR := "res://generated/actors/skeletal-v2-canonical-validation-r7-20260810/actor-001.onvskel"
const VICTOR_IDLE := "res://generated/animations/authored-v1/securitron-mtidle.onvanim"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not await _check(HUMANOID, HUMANOID_IDLE, 25):
		quit(1)
		return
	if not await _check(VICTOR, VICTOR_IDLE, 4):
		quit(1)
		return
	print("OPENNV_GODOT_SKELETAL_V2_ANIMATION_PASS")
	quit(0)


func _check(actor_path: String, animation_path: String, expected_attachments: int) -> bool:
	var skeletal_loader := load("res://scripts/opennv_skeletal_actor_loader.gd")
	var actor := skeletal_loader.call("load_scene", actor_path) as Node3D
	if actor == null:
		return _fail("actor load failed path=%s" % actor_path)
	root.add_child(actor)
	var animation_loader := load("res://scripts/opennv_animation_loader.gd")
	var player := animation_loader.call("attach_clip", actor, animation_path, "idle") as AnimationPlayer
	if player == null:
		actor.queue_free()
		return _fail("animation load failed path=%s" % animation_path)
	var source_tracks := int(actor.get_meta("opennv_animation_source_tracks", 0))
	var matched_tracks := int(actor.get_meta("opennv_animation_matched_tracks", 0))
	if matched_tracks != source_tracks:
		var unmatched: Array = actor.get_meta("opennv_animation_unmatched_tracks", []) as Array
		actor.queue_free()
		return _fail("unresolved animation tracks actor=%s matched=%d source=%d unmatched=%s" % [actor_path, matched_tracks, source_tracks, unmatched])
	var attachments: Array[BoneAttachment3D] = []
	_collect_attachments(actor, attachments)
	if attachments.size() != expected_attachments:
		actor.queue_free()
		return _fail("attachment count actor=%s count=%d" % [actor_path, attachments.size()])
	var animation := player.get_animation("idle")
	player.seek(0.0, true)
	player.advance(0.0)
	await process_frame
	var start := _attachment_transforms(attachments)
	player.seek(animation.length * 0.5, true)
	player.advance(0.0)
	await process_frame
	var finish := _attachment_transforms(attachments)
	var moved := 0
	for index in range(attachments.size()):
		if not (start[index] as Transform3D).is_equal_approx(finish[index] as Transform3D):
			moved += 1
	if moved == 0:
		actor.queue_free()
		return _fail("no attached surface followed animation actor=%s" % actor_path)
	print("OPENNV_GODOT_SKELETAL_V2_ANIMATION_ACTOR actor=%s tracks=%d attachments=%d moved=%d" % [actor_path, matched_tracks, attachments.size(), moved])
	actor.queue_free()
	await process_frame
	return true


func _collect_attachments(node: Node, result: Array[BoneAttachment3D]) -> void:
	if node is BoneAttachment3D:
		result.append(node as BoneAttachment3D)
	for child in node.get_children():
		_collect_attachments(child, result)


func _attachment_transforms(attachments: Array[BoneAttachment3D]) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	for attachment in attachments:
		result.append(attachment.global_transform)
	return result


func _fail(message: String) -> bool:
	push_error("OPENNV_GODOT_SKELETAL_V2_ANIMATION_FAIL " + message)
	return false
