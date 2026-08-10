extends CharacterBody3D

const CONDITION_RUNTIME = preload("res://scripts/opennv_condition_runtime.gd")

var actor_id := ""
var category := ""
var spawn_position := Vector3.ZERO
var phase := 0.0
var wander_radius := 0.0
var walk_speed := 0.0
var aerial := false
var visual: Node3D
var active_package: Dictionary = {}
var package_semantics_available := false
var navigation_agent: NavigationAgent3D
var navigation_target_serial := 0
var navigation_repath_seconds := 0.0
var condition_context: Dictionary = {}


func configure(id_value: String, category_value: String, semantics: Dictionary = {}) -> void:
	actor_id = id_value
	category = category_value
	phase = float(abs(actor_id.hash()) % 1000) / 159.0
	aerial = "raven" in actor_id
	condition_context = semantics.duplicate(true)
	active_package = _select_package(semantics.get("packages", []) as Array, float(semantics.get("game_hour", 9.0)))
	package_semantics_available = not active_package.is_empty()
	if package_semantics_available:
		set_meta("opennv_active_package", str(active_package.get("id", "")))
		set_meta("opennv_active_package_type", int((active_package.get("packageData", {}) as Dictionary).get("type", -1)))
		_configure_authored_package_motion()
	if package_semantics_available:
		return
	# Missing package semantics must be visible as idle coverage, never disguised
	# by the old hash-based showcase circles.
	wander_radius = 0.0
	walk_speed = 0.0


func _package_covers_hour(package: Dictionary, hour: float) -> bool:
	var schedule := package.get("packageSchedule", {}) as Dictionary
	var start := int(schedule.get("time", 255))
	var duration := int(schedule.get("duration", 0))
	if start == 255 or duration <= 0:
		return false
	if duration >= 24:
		return true
	var end := fmod(float(start + duration), 24.0)
	return (hour >= start and hour < end) if start <= end else (hour >= start or hour < end)


func _select_package(packages: Array, hour: float) -> Dictionary:
	var fallback: Dictionary = {}
	for package_value in packages:
		var package := package_value as Dictionary
		var condition_result := CONDITION_RUNTIME.evaluate_all(package.get("conditionData", []) as Array, condition_context)
		if not bool(condition_result.value):
			continue
		if _package_covers_hour(package, hour):
			return package
		var schedule := package.get("packageSchedule", {}) as Dictionary
		if fallback.is_empty() and (int(schedule.get("time", 255)) == 255 or int(schedule.get("duration", 0)) <= 0):
			fallback = package
	return fallback


func _configure_authored_package_motion() -> void:
	var package_type := int((active_package.get("packageData", {}) as Dictionary).get("type", -1))
	# Fallout package types 5 and 12 are Wander/Sandbox. Retain
	# the authored radius. Travel and furniture packages stay put until their
	# reference-target and navigation adapters are resident.
	var package_data := active_package.get("packageData", {}) as Dictionary
	var no_wandering := (int(package_data.get("typeSpecificFlags", 0)) & (1 << 5)) != 0
	if package_type in [5, 12] and not no_wandering:
		var location := active_package.get("packageLocation", {}) as Dictionary
		wander_radius = clampf(float(maxi(64, int(location.get("radius", 256)))) / 70.0, 0.9, 12.0)
		walk_speed = 0.42 if "creature" not in category else 0.62
	else:
		wander_radius = 0.0
		walk_speed = 0.0


func _ready() -> void:
	spawn_position = global_position
	visual = get_node_or_null("Visual") as Node3D
	floor_snap_length = 0.35
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING if aerial else CharacterBody3D.MOTION_MODE_GROUNDED
	navigation_agent = NavigationAgent3D.new()
	navigation_agent.name = "AuthoredNavigationAgent"
	navigation_agent.path_desired_distance = 0.35
	navigation_agent.target_desired_distance = 0.7
	navigation_agent.radius = 0.32
	navigation_agent.height = 1.7
	navigation_agent.avoidance_enabled = false
	add_child(navigation_agent)


func _choose_authored_wander_target() -> bool:
	if navigation_agent == null or wander_radius <= 0.0:
		return false
	var navigation_map := navigation_agent.get_navigation_map()
	if not navigation_map.is_valid() or NavigationServer3D.map_get_iteration_id(navigation_map) == 0:
		return false
	# Deterministic low-discrepancy directions prevent synchronized crowds while
	# retaining replayable package behavior.
	var angle := phase + float(navigation_target_serial) * 2.399963229728653
	var radial := wander_radius * (0.45 + 0.5 * float((navigation_target_serial * 37 + abs(actor_id.hash())) % 101) / 100.0)
	var candidate := spawn_position + Vector3(cos(angle), 0.0, sin(angle)) * radial
	var target := NavigationServer3D.map_get_closest_point(navigation_map, candidate)
	if target.distance_to(spawn_position) > wander_radius * 1.35 or target.distance_to(global_position) < 0.45:
		navigation_target_serial += 1
		return false
	navigation_agent.target_position = target
	navigation_target_serial += 1
	navigation_repath_seconds = 8.0 + float(navigation_target_serial % 7)
	return true


func _physics_process(delta: float) -> void:
	if not is_visible_in_tree():
		velocity = Vector3.ZERO
		return
	navigation_repath_seconds -= delta
	if wander_radius > 0.0 and (navigation_repath_seconds <= 0.0 or navigation_agent.is_navigation_finished()):
		if not _choose_authored_wander_target():
			navigation_repath_seconds = 0.5
	var horizontal := Vector3.ZERO
	if wander_radius > 0.0 and not navigation_agent.is_navigation_finished():
		var next_position := navigation_agent.get_next_path_position()
		horizontal = Vector3(next_position.x - global_position.x, 0.0, next_position.z - global_position.z)
	if horizontal.length_squared() > 0.04:
		var direction := horizontal.normalized()
		velocity.x = move_toward(velocity.x, direction.x * walk_speed, delta * 1.8)
		velocity.z = move_toward(velocity.z, direction.z * walk_speed, delta * 1.8)
		rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), minf(1.0, delta * 2.5))
	else:
		velocity.x = move_toward(velocity.x, 0.0, delta * 1.8)
		velocity.z = move_toward(velocity.z, 0.0, delta * 1.8)
	velocity.y = move_toward(velocity.y, 0.0 if aerial else -4.5, delta * 5.0)
	move_and_slide()
