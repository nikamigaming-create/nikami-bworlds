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
