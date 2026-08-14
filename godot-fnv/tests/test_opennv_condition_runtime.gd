extends SceneTree

const CONDITION_RUNTIME = preload("res://scripts/opennv_condition_runtime.gd")


func _init() -> void:
	var context := {
		"game_hour": 23.0,
		"actor_ref": "0x001073e8",
		"actor_base": "0x000e5cab",
		"actor_cell": "0x00102f4a",
		"actor_world": "0x000da726",
		"actor_interior": false,
		"actor_position": Vector3(1.0, 0.0, 0.0),
		"reference_position_resolver": func(ref_id: Variant) -> Variant:
			return Vector3(4.0, 0.0, 0.0) if str(ref_id).to_lower() == "0x00000014" else null,
		"reference_cell_resolver": func(ref_id: Variant) -> Variant:
			return "0x00102f4a" if str(ref_id).to_lower() == "0x00000014" else null,
		"globals": {"0x0000002a": 7.0},
		"script_variables": {"0x010049b0:1": 2.0},
		"quest_running": {"0x01000042": 1.0},
		"quest_stages": {"0x01000042": 10.0},
		"quest_stage_done": {"0x01000042:10": 1.0},
		"quest_variables": {"0x01000042:7": 3.0},
		"quest_completed": {"0x01000042": 0.0},
		"objective_completed": {},
		"objective_displayed": {"0x01000042:20": 1.0},
	}
	_assert_result([
		_condition(18, "greater_or_equal", 22.0),
		_condition(136, "equal", 1.0, "0x001073e8"),
	], context, true, true, "known AND conditions")
	_assert_result([
		_condition(9999, "equal", 1.0, 0, true),
		_condition(18, "greater", 22.0),
	], context, true, false, "known-true OR branch")
	_assert_result([
		_condition(9999, "equal", 1.0),
	], context, false, false, "unsupported condition must fail closed")
	_assert_result([
		_condition(74, "equal", 7.0, "0x0000002a"),
	], context, true, true, "global lookup")
	_assert_result([
		_condition(67, "equal", 1.0, "0x00102f4a"),
		_condition(310, "equal", 1.0, "0x000da726"),
		_condition(300, "equal", 0.0),
	], context, true, true, "authored cell and world context")
	_assert_result([
		_condition(72, "equal", 1.0, "0x000e5cab"),
	], context, true, true, "authored actor base context")
	_assert_result([
		_condition(1, "equal", 210.0, "0x00000014"),
	], context, true, true, "authored GetDistance in source units")
	_assert_result([
		_condition(32, "equal", 1.0, "0x00000014"),
	], context, true, true, "authored GetInSameCell")
	_assert_result([
		_condition(53, "equal", 2.0, "0x010049b0", false, 1),
	], context, true, true, "authored GetScriptVariable live value")
	_assert_result([
		_condition(53, "equal", 0.0, "0x010049b0", false, 8),
	], context, false, false, "missing GetScriptVariable value fails closed")
	_assert_result([
		_condition(53, "equal", 0.0, 0, false, 1),
	], context, false, false, "null GetScriptVariable target fails closed")
	_assert_result([
		_condition(56, "equal", 1.0, "0x01000042"),
		_condition(58, "equal", 10.0, "0x01000042"),
		_condition(59, "equal", 1.0, "0x01000042", false, 10),
		_condition(79, "equal", 3.0, "0x01000042", false, 7),
		_condition(421, "equal", 1.0, "0x01000042", false, 20),
	], context, true, true, "save-backed quest conditions")
	_assert_result([
		_condition(420, "equal", 0.0, "0x01000042", false, 20),
	], context, true, true, "missing known-quest objective is native zero")
	_assert_result([
		_condition(56, "equal", 0.0, "0x01009999"),
	], context, false, false, "unknown quest fails closed")
	print("OPENNV_CONDITION_RUNTIME_PASS")
	quit(0)


func _condition(function_id: int, operator: String, comparison: float, param1: Variant = 0, or_with_next: bool = false, param2: int = 0) -> Dictionary:
	return {
		"supportedLayout": true,
		"functionId": function_id,
		"operator": operator,
		"comparison": comparison,
		"param1": param1,
		"param2Raw": param2,
		"orWithNext": or_with_next,
	}


func _assert_result(conditions: Array, context: Dictionary, expected_value: bool, expected_supported: bool, label: String) -> void:
	var result := CONDITION_RUNTIME.evaluate_all(conditions, context)
	if bool(result.get("value", false)) != expected_value or bool(result.get("supported", false)) != expected_supported:
		fail("%s value=%s supported=%s" % [label, result.get("value"), result.get("supported")])


func fail(message: String) -> void:
	push_error("OPENNV_CONDITION_RUNTIME_FAIL " + message)
	quit(1)
