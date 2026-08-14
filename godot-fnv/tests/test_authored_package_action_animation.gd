extends SceneTree

const ACTOR := "res://generated/actors/skeletal-v2-canonical-validation-r7-20260810/actor-000.onvskel"
const CLIPS := {
	"sleep": "res://generated/animations/authored-v1/humanoid-dynamicidle-sleep.onvanim",
	"eat": "res://generated/animations/authored-v1/humanoid-eatidle.onvanim",
}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for clip_name_value in CLIPS:
		var clip_name := str(clip_name_value)
		var actor := load("res://scripts/opennv_skeletal_actor_loader.gd").call("load_scene", ACTOR) as Node3D
		if actor == null:
			_fail("actor load failed")
			return
		root.add_child(actor)
		var loader := load("res://scripts/opennv_animation_loader.gd")
		var player := loader.call("attach_clip", actor, str(CLIPS[clip_name]), clip_name, false) as AnimationPlayer
		var matched := int(actor.get_meta("opennv_animation_matched_tracks", -1))
		var unmatched := actor.get_meta("opennv_animation_unmatched_tracks", []) as Array
		if player == null or matched < 40 or not _only_optional_tracks(unmatched):
			_fail("unresolved required %s package action tracks matched=%d unmatched=%s" % [
				clip_name, matched, unmatched])
			return
		if player.get_animation_list().size() != 1 or player.current_animation != "":
			_fail("non-autoplay %s clip changed playback state" % clip_name)
			return
		player.play(clip_name)
		player.seek(0.0, true)
		player.advance(0.0)
		await process_frame
		var skeleton := actor.get_node_or_null("Skeleton3D") as Skeleton3D
		var start := skeleton.get_bone_pose(0)
		player.seek(player.get_animation(clip_name).length * 0.5, true)
		player.advance(0.0)
		await process_frame
		var moved := not start.is_equal_approx(skeleton.get_bone_pose(0))
		if not moved:
			# Root may intentionally be static; require motion from at least one bone.
			for bone_index in range(1, skeleton.get_bone_count()):
				player.seek(0.0, true)
				player.advance(0.0)
				var bone_start := skeleton.get_bone_pose(bone_index)
				player.seek(player.get_animation(clip_name).length * 0.5, true)
				player.advance(0.0)
				if not bone_start.is_equal_approx(skeleton.get_bone_pose(bone_index)):
					moved = true
					break
		if not moved:
			_fail("%s package action produced no bone motion" % clip_name)
			return
		actor.free()
		await process_frame
	var scheduled_visual := load("res://scripts/opennv_skeletal_actor_loader.gd").call("load_scene", ACTOR) as Node3D
	var scheduled_actor := load("res://scripts/fnv_actor.gd").new() as CharacterBody3D
	scheduled_visual.name = "Visual"
	scheduled_actor.add_child(scheduled_visual)
	root.add_child(scheduled_actor)
	scheduled_actor.call("configure", "0x0001", "humanoid", {
		"game_hour": 9.0,
		"packages": [{
			"id": "0xsleep", "packageData": {"type": 4},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageLocation": {"type": 2}, "conditionData": [],
		}],
	})
	var scheduled_player := scheduled_visual.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if scheduled_player == null or scheduled_player.current_animation != "sleep" \
			or str(scheduled_actor.get_meta("opennv_package_action_animation", "")) != "sleep":
		_fail("selected sleep package did not dispatch the authored clip")
		return
	scheduled_actor.free()
	await process_frame
	print("OPENNV_AUTHORED_PACKAGE_ACTION_ANIMATION_PASS")
	quit(0)


func _only_optional_tracks(tracks: Array) -> bool:
	for track_value in tracks:
		var track := str(track_value).to_lower()
		if track in ["backweapon", "sideweapon", "quiver", "torch"]:
			continue
		if "finger" in track or "twist" in track or "tail" in track:
			continue
		return false
	return true


func _fail(message: String) -> void:
	push_error("OPENNV_AUTHORED_PACKAGE_ACTION_ANIMATION_FAIL " + message)
	quit(1)
