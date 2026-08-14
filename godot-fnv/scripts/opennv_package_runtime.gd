class_name OpenNvPackageRuntime
extends RefCounted

const CONDITION_RUNTIME = preload("res://scripts/opennv_condition_runtime.gd")


static func select_package(packages: Array, hour: float, context: Dictionary) -> Dictionary:
	return select_package_result(packages, hour, context).get("package", {}) as Dictionary


static func select_package_result(packages: Array, hour: float, context: Dictionary) -> Dictionary:
	var fallback: Dictionary = {}
	var unsupported: Dictionary = {}
	for package_value in packages:
		var package := package_value as Dictionary
		if not package_structurally_applicable(package, context):
			continue
		var condition_result := CONDITION_RUNTIME.evaluate_all(
			package.get("conditionData", []) as Array, context)
		if not bool(condition_result.get("supported", false)):
			for function_id in condition_result.get("unsupported", []):
				unsupported[int(function_id)] = true
		if not bool(condition_result.value):
			continue
		if package_covers_hour(package, hour, context):
			return {"package": package, "supported": unsupported.is_empty(),
				"unsupported_functions": unsupported.keys(), "reason": "scheduled"}
		var schedule := package.get("packageSchedule", {}) as Dictionary
		if fallback.is_empty() and calendar_constraints_match(package, context) \
				and (int(schedule.get("time", 255)) == 255 \
				or int(schedule.get("duration", 0)) <= 0):
			fallback = package
	return {"package": fallback, "supported": unsupported.is_empty(),
		"unsupported_functions": unsupported.keys(),
		"reason": "fallback" if not fallback.is_empty() else "no_selection"}


static func package_structurally_applicable(package: Dictionary, context: Dictionary) -> bool:
	var location := package.get("packageLocation", {}) as Dictionary
	if int(location.get("type", -1)) == 6:
		return not str(context.get("actor_linked_reference", "")).is_empty()
	return true


static func package_covers_hour(package: Dictionary, hour: float, context: Dictionary) -> bool:
	if not calendar_constraints_match(package, context):
		return false
	var schedule := package.get("packageSchedule", {}) as Dictionary
	var start := int(schedule.get("time", 255))
	var duration := int(schedule.get("duration", 0))
	if start == 255 or duration <= 0:
		return false
	if duration >= 24:
		return true
	var end := fmod(float(start + duration), 24.0)
	return (hour >= start and hour < end) if start <= end else (hour >= start or hour < end)


static func calendar_constraints_match(package: Dictionary, context: Dictionary) -> bool:
	var schedule := package.get("packageSchedule", {}) as Dictionary
	var day_of_week := int(schedule.get("dayOfWeek", 255))
	var month := int(schedule.get("month", 255))
	var date := int(schedule.get("date", 0))
	if day_of_week != 255 and (not context.has("day_of_week") \
			or not calendar_day_matches(day_of_week, int(context["day_of_week"]))):
		return false
	if month != 255 and (not context.has("month") or int(context["month"]) != month):
		return false
	if date != 0 and (not context.has("date") or int(context["date"]) != date):
		return false
	return true


static func calendar_day_matches(authored_day: int, current_day: int) -> bool:
	match authored_day:
		7:
			return current_day >= 1 and current_day <= 5
		8:
			return current_day == 0 or current_day == 6
		9:
			return current_day in [1, 3, 5]
		10:
			return current_day in [2, 4]
	return current_day == authored_day


static func activity_name(package_type: int) -> String:
	return {
		0: "find", 1: "follow", 2: "escort", 3: "eat", 4: "sleep",
		5: "wander", 6: "travel", 7: "accompany", 8: "use_item",
		9: "ambush", 10: "flee", 12: "sandbox", 13: "patrol",
		14: "guard", 15: "dialogue", 16: "use_weapon",
	}.get(package_type, "idle") as String


static func describe_intent(package: Dictionary, actor_linked_seed: String) -> Dictionary:
	if package.is_empty():
		return {"package_id": "", "package_type": -1, "activity_state": "idle",
			"activity_on_arrival": "idle", "travel_target_ref": "", "patrol_route_mode": false,
			"wander_center_ref": "", "flee_mode": false, "direct_travel_target_enabled": false,
			"direct_target_mode": "", "target_desired_distance": 0.7}
	var package_type := int((package.get("packageData", {}) as Dictionary).get("type", -1))
	var location := package.get("packageLocation", {}) as Dictionary
	var target := package.get("packageTarget", {}) as Dictionary
	var location_type := int(location.get("type", -1))
	var target_ref := ""
	var patrol := false
	var wander_center := ""
	var flee := false
	var direct_target_mode := ""
	var target_distance := 0.7
	var no_wandering := (int((package.get("packageData", {}) as Dictionary).get(
		"typeSpecificFlags", 0)) & (1 << 5)) != 0
	var activity := activity_name(package_type)
	var activity_on_arrival := activity
	if package_type in [5, 12, 13] and not no_wandering:
		var radius := int(location.get("radius", 0 if package_type == 13 else 256))
		if package_type == 13 and location_type == 6:
			target_ref = actor_linked_seed
			patrol = not target_ref.is_empty()
		elif package_type == 13 and radius <= 0 and location_type == 0:
			target_ref = str(location.get("location", ""))
			patrol = not target_ref.is_empty()
		elif package_type == 13 and radius <= 0 and location_type in [2, 3]:
			direct_target_mode = "current" if location_type == 2 else "editor"
		elif location_type == 0:
			wander_center = str(location.get("location", ""))
		elif location_type == 6:
			wander_center = actor_linked_seed
	elif package_type == 6:
		if int(target.get("type", -1)) == 0:
			target_ref = str(target.get("target", ""))
		if target_ref.is_empty() and location_type == 0:
			target_ref = str(location.get("location", ""))
		elif target_ref.is_empty() and location_type == 6:
			target_ref = actor_linked_seed
		elif target_ref.is_empty() and location_type in [2, 3]:
			direct_target_mode = "current" if location_type == 2 else "editor"
	elif package_type in [1, 2, 7, 15, 0, 10]:
		if int(target.get("type", -1)) == 0:
			target_ref = str(target.get("target", ""))
		if package_type in [1, 2, 7, 15]:
			target_distance = clampf(float(maxi(96, int(target.get("distance", 210)))) / 70.0, 1.35, 12.0)
		elif package_type == 0:
			target_distance = 1.0
		else:
			target_distance = 12.0
			flee = not target_ref.is_empty()
	elif package_type in [3, 4, 8, 9, 14, 16]:
		if location_type == 0:
			target_ref = str(location.get("location", ""))
		elif location_type == 6:
			target_ref = actor_linked_seed
		if target_ref.is_empty() and package_type in [8, 14] and int(target.get("type", -1)) == 0:
			target_ref = str(target.get("target", ""))
		if not target_ref.is_empty():
			activity = "travel_to_" + activity_on_arrival
			target_distance = 0.75
	return {
		"package_id": str(package.get("id", "")), "package_type": package_type,
		"activity_state": activity, "activity_on_arrival": activity_on_arrival,
		"travel_target_ref": target_ref, "patrol_route_mode": patrol,
		"wander_center_ref": wander_center, "flee_mode": flee,
		"direct_travel_target_enabled": not direct_target_mode.is_empty(),
		"direct_target_mode": direct_target_mode, "target_desired_distance": target_distance,
	}
