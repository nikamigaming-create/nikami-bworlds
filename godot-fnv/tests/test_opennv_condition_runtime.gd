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
		"globals": {"0x0000002a": 7.0},
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
	print("OPENNV_CONDITION_RUNTIME_PASS")
	quit(0)


func _condition(function_id: int, operator: String, comparison: float, param1: Variant = 0, or_with_next: bool = false) -> Dictionary:
	return {
		"supportedLayout": true,
		"functionId": function_id,
		"operator": operator,
		"comparison": comparison,
		"param1": param1,
		"param2Raw": 0,
		"orWithNext": or_with_next,
	}


func _assert_result(conditions: Array, context: Dictionary, expected_value: bool, expected_supported: bool, label: String) -> void:
	var result := CONDITION_RUNTIME.evaluate_all(conditions, context)
	if bool(result.get("value", false)) != expected_value or bool(result.get("supported", false)) != expected_supported:
		fail("%s value=%s supported=%s" % [label, result.get("value"), result.get("supported")])


func fail(message: String) -> void:
	push_error("OPENNV_CONDITION_RUNTIME_FAIL " + message)
	quit(1)
