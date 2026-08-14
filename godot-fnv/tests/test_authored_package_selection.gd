extends SceneTree


func _init() -> void:
	var actor_script := load("res://scripts/fnv_actor.gd")
	var actor: CharacterBody3D = actor_script.new()
	actor.call("configure", "schedule-test", "route-humanoid", {
		"game_hour": 23.0,
		"packages": [
			{"id": "0x1", "packageData": {"type": 5}, "packageSchedule": {"time": 8, "duration": 4}, "packageLocation": {"radius": 140}},
			{"id": "0x2", "packageData": {"type": 12}, "packageSchedule": {"time": 22, "duration": 4}, "packageLocation": {"radius": 350}},
			{"id": "0x3", "packageData": {"type": 6}, "packageSchedule": {"time": 255, "duration": 0}},
		],
	})
	if str(actor.get_meta("opennv_active_package", "")) != "0x2":
		fail("overnight authored package was not selected")
		return
	if absf(float(actor.get("wander_radius")) - 5.0) > 0.001:
		fail("authored sandbox radius was not converted")
		return
	actor.call("update_game_hour", 9.0)
	if str(actor.get_meta("opennv_active_package", "")) != "0x1":
		fail("authored schedule did not transition as game time advanced")
		return
	actor.free()
	var fallback: CharacterBody3D = actor_script.new()
	fallback.call("configure", "fallback-test", "route-humanoid", {
		"game_hour": 17.0,
		"packages": [
			{"id": "0xa", "packageData": {"type": 4}, "packageSchedule": {"time": 22, "duration": 7}},
			{"id": "0xb", "packageData": {"type": 6}, "packageSchedule": {"time": 255, "duration": 0}},
		],
	})
	if str(fallback.get_meta("opennv_active_package", "")) != "0xb":
		fail("untimed authored fallback package was not selected")
		return
	if float(fallback.get("wander_radius")) != 0.0:
		fail("unresolved travel package fabricated movement")
		return
	fallback.free()
	var no_wander: CharacterBody3D = actor_script.new()
	no_wander.call("configure", "no-wander-test", "route-humanoid", {
		"game_hour": 12.0,
		"packages": [{"id": "0xc", "packageData": {"type": 12, "typeSpecificFlags": 32},
			"packageSchedule": {"time": 255, "duration": 0}, "packageLocation": {"radius": 700}}],
	})
	if float(no_wander.get("wander_radius")) != 0.0:
		fail("sandbox no-wandering flag was ignored")
		return
	no_wander.free()
	var cast_magic: CharacterBody3D = actor_script.new()
	cast_magic.call("configure", "cast-test", "route-humanoid", {
		"game_hour": 12.0,
		"packages": [{"id": "0xd", "packageData": {"type": 11},
			"packageSchedule": {"time": 255, "duration": 0}, "packageLocation": {"radius": 700}}],
	})
	if float(cast_magic.get("wander_radius")) != 0.0:
		fail("cast-magic package was misclassified as wander")
		return
	cast_magic.free()
	var conditional: CharacterBody3D = actor_script.new()
	conditional.call("configure", "conditional-test", "route-humanoid", {
		"game_hour": 23.0,
		"packages": [
			{"id": "0xe", "packageData": {"type": 12}, "packageSchedule": {"time": 22, "duration": 4},
				"packageLocation": {"radius": 350}, "conditionData": [_condition(18, "greater_or_equal", 22.0)]},
			{"id": "0xf", "packageData": {"type": 6}, "packageSchedule": {"time": 255, "duration": 0}},
		],
	})
	if str(conditional.get_meta("opennv_active_package", "")) != "0xe":
		fail("known true authored package condition was not selected")
		return
	conditional.free()
	var fail_closed: CharacterBody3D = actor_script.new()
	fail_closed.call("configure", "unsupported-condition-test", "route-humanoid", {
		"game_hour": 23.0,
		"packages": [
			{"id": "0x10", "packageData": {"type": 12}, "packageSchedule": {"time": 22, "duration": 4},
				"conditionData": [_condition(9999, "equal", 1.0)]},
			{"id": "0x11", "packageData": {"type": 6}, "packageSchedule": {"time": 255, "duration": 0}},
		],
	})
	if str(fail_closed.get_meta("opennv_active_package", "")) != "0x11":
		fail("unsupported package condition did not fail closed")
		return
	fail_closed.free()
	var calendar_fail_closed: CharacterBody3D = actor_script.new()
	calendar_fail_closed.call("configure", "calendar-condition-test", "route-humanoid", {
		"game_hour": 23.0,
		"packages": [
			{"id": "0x12", "packageData": {"type": 12},
				"packageSchedule": {"dayOfWeek": 6, "month": 255, "date": 0, "time": 22, "duration": 4}},
			{"id": "0x13", "packageData": {"type": 6}, "packageSchedule": {"time": 255, "duration": 0}},
		],
	})
	if str(calendar_fail_closed.get_meta("opennv_active_package", "")) != "0x13":
		fail("calendar-qualified package ran without decoded calendar state")
		return
	calendar_fail_closed.free()
	var calendar_timeless_fail_closed: CharacterBody3D = actor_script.new()
	calendar_timeless_fail_closed.call("configure", "calendar-timeless-test", "route-humanoid", {
		"game_hour": 9.0, "day_of_week": 2,
		"packages": [
			{"id": "0x121", "packageData": {"type": 12},
				"packageSchedule": {"dayOfWeek": 9, "month": 255, "date": 0, "time": 255, "duration": 24}},
			{"id": "0x122", "packageData": {"type": 6}, "packageSchedule": {"time": 255, "duration": 0}},
		],
	})
	if str(calendar_timeless_fail_closed.get_meta("opennv_active_package", "")) != "0x122":
		fail("calendar-qualified timeless fallback ignored its weekday constraint")
		return
	calendar_timeless_fail_closed.free()
	var weekday_group: CharacterBody3D = actor_script.new()
	weekday_group.call("configure", "weekday-group-test", "route-humanoid", {
		"game_hour": 9.0, "day_of_week": 3,
		"packages": [{"id": "0x131", "packageData": {"type": 12},
			"packageSchedule": {"dayOfWeek": 9, "month": 255, "date": 0, "time": 8, "duration": 4},
			"packageLocation": {"radius": 140}}],
	})
	if str(weekday_group.get_meta("opennv_active_package", "")) != "0x131":
		fail("Monday/Wednesday/Friday schedule group did not match Wednesday")
		return
	weekday_group.free()
	var targeted_travel: CharacterBody3D = actor_script.new()
	targeted_travel.call("configure", "targeted-travel-test", "route-humanoid", {
		"game_hour": 12.0,
		"packages": [{"id": "0x14", "packageData": {"type": 6},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageTarget": {"type": 0, "target": "0x00123456"}}],
	})
	if str(targeted_travel.get("travel_target_ref")) != "0x00123456" or float(targeted_travel.get("walk_speed")) <= 0.0:
		fail("authored Travel target was not retained for NAVM resolution")
		return
	targeted_travel.free()
	var linked_travel: CharacterBody3D = actor_script.new()
	linked_travel.call("configure", "linked-travel-test", "route-humanoid", {
		"game_hour": 12.0, "actor_linked_reference": "0x00000420",
		"packages": [{"id": "0x141", "packageData": {"type": 6},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageLocation": {"type": 6}}],
	})
	if str(linked_travel.get("travel_target_ref")) != "0x00000420" or float(linked_travel.get("walk_speed")) <= 0.0:
		fail("linked-reference Travel target was not configured")
		return
	linked_travel.free()
	var patrol: CharacterBody3D = actor_script.new()
	patrol.call("configure", "patrol-test", "route-humanoid", {
		"game_hour": 12.0,
		"packages": [{"id": "0x15", "packageData": {"type": 13},
			"packageSchedule": {"time": 255, "duration": 0}, "packageLocation": {"type": 3, "radius": 210}}],
	})
	if absf(float(patrol.get("wander_radius")) - 3.0) > 0.001:
		fail("radius-bearing Patrol did not retain its authored range")
		return
	patrol.free()
	var referenced_sandbox: CharacterBody3D = actor_script.new()
	referenced_sandbox.call("configure", "reference-sandbox-test", "route-humanoid", {
		"game_hour": 12.0,
		"packages": [{"id": "0x150", "packageData": {"type": 12},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageLocation": {"type": 0, "location": "0x00000250", "radius": 280}}],
	})
	if str(referenced_sandbox.get("wander_center_ref")) != "0x00000250" \
			or absf(float(referenced_sandbox.get("wander_radius")) - 4.0) > 0.001:
		fail("reference-centered Sandbox did not retain its authored center and radius")
		return
	referenced_sandbox.free()
	var linked_patrol: CharacterBody3D = actor_script.new()
	linked_patrol.call("configure", "linked-patrol-test", "route-humanoid", {
		"game_hour": 12.0, "actor_linked_reference": "0x200",
		"packages": [{"id": "0x151", "packageData": {"type": 13},
			"packageSchedule": {"time": 255, "duration": 0}, "packageLocation": {"type": 3, "radius": 0}}],
	})
	if bool(linked_patrol.get("patrol_route_mode")) or not bool(linked_patrol.get("direct_travel_target_enabled")) \
			or not str(linked_patrol.get("travel_target_ref")).is_empty():
		fail("editor-location Patrol was incorrectly rebound to actor XLKR")
		return
	linked_patrol.free()
	var empty_link_fallback: CharacterBody3D = actor_script.new()
	empty_link_fallback.call("configure", "empty-link-fallback", "route-humanoid", {
		"game_hour": 12.0, "actor_linked_reference": "",
		"packages": [
			{"id": "0x152", "packageData": {"type": 13},
				"packageSchedule": {"time": 255, "duration": 0}, "packageLocation": {"type": 6, "radius": 0}},
			{"id": "0x153", "packageData": {"type": 5},
				"packageSchedule": {"time": 255, "duration": 0}, "packageLocation": {"type": 3, "radius": 140}},
		],
	})
	if str(empty_link_fallback.get_meta("opennv_active_package", "")) != "0x153":
		fail("empty linked-location package did not fall through structurally")
		return
	empty_link_fallback.free()
	var current_location_patrol: CharacterBody3D = actor_script.new()
	current_location_patrol.call("configure", "current-location-patrol", "route-humanoid", {
		"game_hour": 12.0, "actor_linked_reference": "",
		"packages": [{"id": "0x154", "packageData": {"type": 13},
			"packageSchedule": {"time": 255, "duration": 0}, "packageLocation": {"type": 2, "radius": 0}}],
	})
	if str(current_location_patrol.get_meta("opennv_active_package", "")) != "0x154" \
			or not bool(current_location_patrol.get("direct_travel_target_enabled")):
		fail("zero-radius current-location Patrol was incorrectly treated as XLKR")
		return
	current_location_patrol.free()
	var explicit_location_patrol: CharacterBody3D = actor_script.new()
	explicit_location_patrol.call("configure", "explicit-location-patrol", "route-humanoid", {
		"game_hour": 12.0, "actor_linked_reference": "0x00000999",
		"packages": [{"id": "0x155", "packageData": {"type": 13},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageLocation": {"type": 0, "location": "0x00000888", "radius": 0}}],
	})
	if not bool(explicit_location_patrol.get("patrol_route_mode")) \
			or str(explicit_location_patrol.get("travel_target_ref")) != "0x00000888":
		fail("zero-radius explicit-location Patrol did not start at its package marker")
		return
	explicit_location_patrol.free()
	var follow: CharacterBody3D = actor_script.new()
	follow.call("configure", "follow-test", "route-humanoid", {
		"game_hour": 12.0,
		"packages": [{"id": "0x16", "packageData": {"type": 1},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageTarget": {"type": 0, "target": "0x14", "distance": 210}}],
	})
	if str(follow.get("travel_target_ref")) != "0x14" or absf(float(follow.get("target_desired_distance")) - 3.0) > 0.001:
		fail("authored Follow target/distance was not retained")
		return
	follow.free()
	var sleeper: CharacterBody3D = actor_script.new()
	sleeper.call("configure", "sleep-test", "route-humanoid", {
		"game_hour": 1.0,
		"packages": [{"id": "0x17", "packageData": {"type": 4},
			"packageSchedule": {"time": 22, "duration": 7},
			"packageLocation": {"type": 0, "location": "0x0000beef"}}],
	})
	if str(sleeper.get("travel_target_ref")) != "0x0000beef" \
			or str(sleeper.get("activity_state")) != "travel_to_sleep" \
			or str(sleeper.get_meta("opennv_package_activity", "")) != "travel_to_sleep":
		fail("Sleep package did not retain its authored furniture/location activity")
		return
	sleeper.free()
	var eater: CharacterBody3D = actor_script.new()
	eater.call("configure", "eat-test", "route-humanoid", {
		"game_hour": 12.0,
		"packages": [{"id": "0x18", "packageData": {"type": 3},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageLocation": {"type": 3, "radius": 0}}],
	})
	if str(eater.get("activity_state")) != "eat" or float(eater.get("walk_speed")) != 0.0:
		fail("Editor-location Eat package did not begin its authored stationary activity")
		return
	eater.free()
	var guard: CharacterBody3D = actor_script.new()
	guard.call("configure", "guard-test", "route-creature", {
		"game_hour": 12.0,
		"packages": [{"id": "0x19", "packageData": {"type": 14},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageTarget": {"type": 0, "target": "0x0000cafe", "distance": 420}}],
	})
	if str(guard.get("travel_target_ref")) != "0x0000cafe" \
			or str(guard.get("activity_on_arrival")) != "guard":
		fail("Guard package did not retain its authored reference target")
		return
	guard.free()
	var fleeing: CharacterBody3D = actor_script.new()
	fleeing.call("configure", "flee-test", "route-humanoid", {
		"game_hour": 12.0,
		"packages": [{"id": "0x1a", "packageData": {"type": 10},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageTarget": {"type": 0, "target": "0x14", "distance": 2000}}],
	})
	if not bool(fleeing.get("flee_mode")) or str(fleeing.get("travel_target_ref")) != "0x14":
		fail("Flee package did not retain its authored threat target")
		return
	fleeing.free()
	print("OPENNV_AUTHORED_PACKAGE_SELECTION_PASS")
	quit(0)


func _condition(function_id: int, operator: String, comparison: float) -> Dictionary:
	return {
		"supportedLayout": true,
		"functionId": function_id,
		"operator": operator,
		"comparison": comparison,
		"param1Raw": 0,
		"param2Raw": 0,
	}


func fail(message: String) -> void:
	push_error("OPENNV_AUTHORED_PACKAGE_SELECTION_FAIL " + message)
	quit(1)
