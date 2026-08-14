extends SceneTree


func _init() -> void:
	var bootstrap := _read_json("res://generated/bootstrap.json")
	bootstrap["_save_actor_overlay"] = _read_json("res://generated/save330-overlay/index.json")
	var streamer_script := load("res://scripts/fnv_cell_streamer.gd")
	var streamer: Node3D = streamer_script.new()
	streamer.call("_load_save_actor_overrides", bootstrap)
	var refs := streamer.get("save_enabled_actor_refs") as Dictionary
	for required in ["0x00104c68", "0x00104c6d"]:
		if not refs.has(required):
			fail("missing Save330 live saloon actor " + required)
			return
	for rejected in ["0x00103dfe", "0x0015f316"]:
		if refs.has(rejected):
			fail("enabled an inactive duplicate/quest actor " + rejected)
			return
	if refs.size() != 2:
		fail("unexpected Save330 override denominator %d" % refs.size())
		return
	var states := streamer.get("save_reference_state_by_ref") as Dictionary
	if states.size() != 1463:
		fail("validated moved-reference denominator mismatch %d" % states.size())
		return
	if not states.has("0x00000014"):
		fail("player moved-reference transform was not indexed")
		return
	var placement := {
		"form_id": "0x000e35d1",
		"position": [1.0, 2.0, 3.0],
		"rotation_radians": [0.25, 0.5, 0.75],
	}
	if not bool(streamer.call("_apply_save_reference_override", placement)):
		fail("known moved actor transform was not applied")
		return
	var position := placement.get("position", []) as Array
	if position.size() != 3 or not is_equal_approx(float(position[0]), 18851.615234375) or not is_equal_approx(float(position[1]), 2844.44775390625) or not is_equal_approx(float(position[2]), 5252.60107421875):
		fail("known moved actor position differs from decoded save prefix: %s" % str(position))
		return
	var rotation := placement.get("rotation_radians", []) as Array
	if rotation.size() != 3 or not is_equal_approx(float(rotation[0]), 0.25) or not is_equal_approx(float(rotation[1]), 0.0) or not is_equal_approx(float(rotation[2]), 3.200000762939453):
		fail("save rotation sentinel/component merge failed: %s" % str(rotation))
		return
	if not (streamer.get("applied_save_reference_refs") as Dictionary).has("0x000e35d1"):
		fail("applied save reference was not tracked")
		return
	var script_variables := (streamer.get("runtime_condition_context") as Dictionary).get("script_variables", {}) as Dictionary
	if script_variables.size() != 217 or not script_variables.has("0x00080770:2") or not is_zero_approx(float(script_variables["0x00080770:2"])):
		fail("Save330 script-variable state coverage mismatch %d" % script_variables.size())
		return
	var condition_context := streamer.get("runtime_condition_context") as Dictionary
	var quest_running := condition_context.get("quest_running", {}) as Dictionary
	var quest_stages := condition_context.get("quest_stages", {}) as Dictionary
	var quest_stage_done := condition_context.get("quest_stage_done", {}) as Dictionary
	var quest_variables := condition_context.get("quest_variables", {}) as Dictionary
	var objective_displayed := condition_context.get("objective_displayed", {}) as Dictionary
	if quest_running.size() != 640 or quest_stages.size() != 640 or quest_stage_done.size() != 15 or quest_variables.size() != 4316 or objective_displayed.size() != 4:
		fail("Save330 quest-state denominator mismatch quests=%d stages=%d stage_done=%d variables=%d objectives=%d" % [
			quest_running.size(), quest_stages.size(), quest_stage_done.size(), quest_variables.size(), objective_displayed.size()])
		return
	if not is_equal_approx(float(quest_stages.get("0x01005229", -1)), 10.0) or not is_equal_approx(float(quest_stage_done.get("0x01005229:10", 0)), 1.0) or not is_equal_approx(float(objective_displayed.get("0x01005229:10", 0)), 1.0):
		fail("representative saved quest stage/objective state was not installed")
		return
	if not is_equal_approx(float(quest_variables.get("0x00070ec9:54", 0)), 1.0):
		fail("representative saved quest script variable was not installed")
		return
	streamer.free()
	print("OPENNV_SAVE_ACTOR_ENABLE_OVERLAY_PASS refs=2 transforms=1463 script_values=217 quests=640 quest_variables=4316 sentinel_merge=pass")
	quit(0)


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(file.get_as_text()) if file != null else null
	return parsed as Dictionary if parsed is Dictionary else {}


func fail(message: String) -> void:
	push_error("OPENNV_SAVE_ACTOR_ENABLE_OVERLAY_FAIL " + message)
	quit(1)
