class_name OpenNVConditionRuntime
extends RefCounted


static func evaluate_all(conditions: Array, context: Dictionary) -> Dictionary:
	var unsupported: Dictionary = {}
	var index := 0
	while index < conditions.size():
		var condition := conditions[index] as Dictionary
		var result := _evaluate(condition, context)
		if not bool(result.supported):
			unsupported[int(condition.get("functionId", -1))] = true
		var group_value := bool(result.supported) and bool(result.value)
		while bool(condition.get("orWithNext", false)) and index + 1 < conditions.size():
			index += 1
			condition = conditions[index] as Dictionary
			result = _evaluate(condition, context)
			if not bool(result.supported):
				unsupported[int(condition.get("functionId", -1))] = true
			elif bool(result.value):
				group_value = true
		if not group_value:
			return {"supported": unsupported.is_empty(), "value": false, "unsupported": unsupported.keys()}
		index += 1
	return {"supported": unsupported.is_empty(), "value": true, "unsupported": unsupported.keys()}


static func _evaluate(condition: Dictionary, context: Dictionary) -> Dictionary:
	if not bool(condition.get("supportedLayout", false)):
		return {"supported": false, "value": false}
	var actual_result := _function_value(int(condition.get("functionId", -1)), condition, context)
	if not bool(actual_result.supported):
		return {"supported": false, "value": false}
	var expected: Variant = condition.get("comparison", 0.0)
	if bool(condition.get("comparisonUsesGlobal", false)):
		var global_id := _canonical(condition.get("comparisonGlobal", ""))
		var globals := context.get("globals", {}) as Dictionary
		if not globals.has(global_id):
			return {"supported": false, "value": false}
		expected = globals[global_id]
	var actual := float(actual_result.value)
	var comparison := float(expected)
	match str(condition.get("operator", "unsupported")):
		"equal": return {"supported": true, "value": is_equal_approx(actual, comparison)}
		"not_equal": return {"supported": true, "value": not is_equal_approx(actual, comparison)}
		"greater": return {"supported": true, "value": actual > comparison}
		"greater_or_equal": return {"supported": true, "value": actual >= comparison}
		"less": return {"supported": true, "value": actual < comparison}
		"less_or_equal": return {"supported": true, "value": actual <= comparison}
		_: return {"supported": false, "value": false}


static func _function_value(function_id: int, condition: Dictionary, context: Dictionary) -> Dictionary:
	var param1 := _canonical(condition.get("param1", condition.get("param1Raw", "")))
	var param2 := int(condition.get("param2Raw", 0))
	match function_id:
		18: return _value(context.get("game_hour", 0.0))
		35: return _value(1.0 if bool(context.get("actor_disabled", false)) else 0.0)
		46: return _value(1.0 if bool(context.get("actor_dead", false)) else 0.0)
		49: return _value(1.0 if bool(context.get("actor_sleeping", false)) else 0.0)
		50: return _value(1.0 if bool(context.get("talked_to_player", false)) else 0.0)
		56: return _dictionary_value(context.get("quest_running", {}), param1)
		58: return _dictionary_value(context.get("quest_stages", {}), param1)
		59: return _dictionary_value(context.get("quest_stage_done", {}), "%s:%d" % [param1, param2])
		64: return _value(1.0 if bool(context.get("actor_is_creature", false)) else 0.0)
		67: return _value(1.0 if _canonical(context.get("actor_cell", "")) == param1 else 0.0)
		72: return _value(1.0 if _canonical(context.get("actor_base", "")) == param1 else 0.0)
		74: return _dictionary_value(context.get("globals", {}), param1)
		77: return _value(float(context.get("random_percent", 0.0)))
		79: return _dictionary_value(context.get("quest_variables", {}), "%s:%d" % [param1, param2])
		80: return _value(float(context.get("actor_level", 1.0)))
		84: return _dictionary_value(context.get("dead_counts", {}), param1)
		91: return _value(1.0 if bool(context.get("actor_alerted", false)) else 0.0)
		110: return _value(1.0 if _canonical(context.get("current_package", "")) == param1 else 0.0)
		136: return _value(1.0 if _canonical(context.get("actor_ref", "")) == param1 else 0.0)
		300: return _value(1.0 if bool(context.get("actor_interior", false)) else 0.0)
		310: return _value(1.0 if _canonical(context.get("actor_world", "")) == param1 else 0.0)
		420: return _dictionary_value(context.get("objective_completed", {}), "%s:%d" % [param1, param2])
		421: return _dictionary_value(context.get("objective_displayed", {}), "%s:%d" % [param1, param2])
		546: return _dictionary_value(context.get("quest_completed", {}), param1)
		_: return {"supported": false, "value": 0.0}


static func _dictionary_value(value: Variant, key: String) -> Dictionary:
	var dictionary := value as Dictionary
	return _value(dictionary[key]) if dictionary.has(key) else {"supported": false, "value": 0.0}


static func _value(value: Variant) -> Dictionary:
	return {"supported": true, "value": float(value)}


static func _canonical(value: Variant) -> String:
	var text := str(value).strip_edges().to_lower()
	if text.is_empty() or text == "null" or text == "0":
		return ""
	if text.begins_with("formid:"):
		text = text.trim_prefix("formid:")
	if text.begins_with("0x"):
		return "0x%08x" % text.hex_to_int()
	if text.is_valid_int():
		return "0x%08x" % int(text)
	return text
