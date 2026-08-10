extends SceneTree

const HUMANOID_ACTOR := "res://generated/actors/skeletal-v2-validation-v1/actor-000.onvskel"
const HUMANOID_IDLE := "res://generated/animations/authored-v1/humanoid-mtidle.onvanim"
const SECURITRON_ACTOR := "res://generated/actors/skeletal-v2-validation-v1/actor-001.onvskel"
const SECURITRON_IDLE := "res://generated/animations/authored-v1/securitron-mtidle.onvanim"


func _init() -> void:
	if not _test_actor(HUMANOID_ACTOR, HUMANOID_IDLE, 40):
		quit(1)
		return
	if not _test_actor(SECURITRON_ACTOR, SECURITRON_IDLE, 40):
		quit(1)
		return
	print("OPENNV_ANIMATION_TRANSPORT_EXPERIMENT_PASS humanoid=%s securitron=%s" % [HUMANOID_IDLE, SECURITRON_IDLE])
	quit(0)


func _test_actor(actor_path: String, animation_path: String, minimum_matches: int) -> bool:
	var skeletal_loader := load("res://scripts/opennv_skeletal_actor_loader.gd")
	var actor := skeletal_loader.call("load_scene", actor_path) as Node3D
	if actor == null:
		push_error("OPENNV_AUTHORED_ACTOR_ANIMATION_FAIL actor=%s" % actor_path)
		return false
	root.add_child(actor)
	var animation_loader := load("res://scripts/opennv_animation_loader.gd")
	var player := animation_loader.call("attach_clip", actor, animation_path, "idle") as AnimationPlayer
	if player == null:
		push_error("OPENNV_AUTHORED_ACTOR_ANIMATION_FAIL animation=%s" % animation_path)
		actor.queue_free()
		return false
	var matches := int(actor.get_meta("opennv_animation_matched_tracks", 0))
	var source_tracks := int(actor.get_meta("opennv_animation_source_tracks", 0))
	var animation := player.get_animation("idle")
	if matches < minimum_matches or matches > source_tracks or source_tracks < minimum_matches or animation == null or animation.track_get_key_count(0) < 100:
		push_error("OPENNV_AUTHORED_ACTOR_ANIMATION_FAIL matches=%d source=%d tracks=%d" % [matches, source_tracks, animation.get_track_count() if animation != null else 0])
		actor.queue_free()
		return false
	var skeletons: Array[Skeleton3D] = []
	_collect_skeletons(actor, skeletons)
	if skeletons.size() != 1 or int(actor.get_meta("opennv_canonical_skeleton_count", 0)) != 1:
		push_error("OPENNV_AUTHORED_ACTOR_ANIMATION_FAIL canonical skeleton count=%d actor=%s" % [skeletons.size(), actor_path])
		actor.queue_free()
		return false
	player.seek(0.0, true)
	player.advance(0.0)
	var start_poses := _bone_poses(skeletons)
	player.seek(animation.length * 0.5, true)
	player.advance(0.0)
	var end_poses := _bone_poses(skeletons)
	var moved := false
	for index in range(mini(start_poses.size(), end_poses.size())):
		if not (start_poses[index] as Transform3D).is_equal_approx(end_poses[index] as Transform3D):
			moved = true
			break
	if not moved:
		push_error("OPENNV_AUTHORED_ACTOR_ANIMATION_FAIL no bone pose changed actor=%s" % actor_path)
		actor.queue_free()
		return false
	actor.queue_free()
	return true


func _collect_skeletons(node: Node, result: Array[Skeleton3D]) -> void:
	if node is Skeleton3D:
		result.append(node as Skeleton3D)
	for child in node.get_children():
		_collect_skeletons(child, result)


func _bone_poses(skeletons: Array[Skeleton3D]) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	for skeleton in skeletons:
		for bone_index in range(skeleton.get_bone_count()):
			result.append(skeleton.get_bone_pose(bone_index))
	return result
