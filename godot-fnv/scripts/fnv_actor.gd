extends CharacterBody3D

const PACKAGE_RUNTIME = preload("res://scripts/opennv_package_runtime.gd")
const ANIMATION_LOADER = preload("res://scripts/opennv_animation_loader.gd")
const PACKAGE_ACTION_CLIPS := {
	"sleep": "res://generated/animations/authored-v1/humanoid-dynamicidle-sleep.onvanim",
	"eat": "res://generated/animations/authored-v1/humanoid-eatidle.onvanim",
}

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
var travel_target_ref := ""
var travel_target_position := Vector3.ZERO
var travel_target_resolved := false
var target_desired_distance := 0.7
var patrol_route_mode := false
var wander_center_ref := ""
var flee_mode := false
var activity_state := "idle"
var activity_on_arrival := "idle"
var activity_animation := "idle"
var loaded_action_clips: Dictionary = {}
var direct_travel_target_enabled := false
var progress_sample_position := Vector3.ZERO
var progress_sample_seconds := 0.0
var package_route_door_ref := ""
var package_portal_pending := false
var package_route_waypoint := false


func configure(id_value: String, category_value: String, semantics: Dictionary = {}) -> void:
	_reset_package_telemetry()
	actor_id = id_value
	category = category_value
	var placed_ref := str(semantics.get("actor_ref", actor_id))
	phase = float(abs(placed_ref.hash()) % 1000) / 159.0
	aerial = "raven" in actor_id
	condition_context = semantics.duplicate(true)
	if semantics.get("actor_position") is Vector3 and not bool(semantics.get("restoring_offscreen", false)):
		spawn_position = semantics.get("actor_position") as Vector3
	active_package = _select_package(semantics.get("packages", []) as Array, float(semantics.get("game_hour", 9.0)))
	package_semantics_available = not active_package.is_empty()
	if package_semantics_available:
		set_meta("opennv_active_package", str(active_package.get("id", "")))
		set_meta("opennv_active_package_type", int((active_package.get("packageData", {}) as Dictionary).get("type", -1)))
		_configure_authored_package_motion()
		_sync_activity_animation()
		navigation_repath_seconds = fposmod(phase, 2.0)
	if package_semantics_available:
		return
	# Missing package semantics must be visible as idle coverage, never disguised
	# by the old hash-based showcase circles.
	wander_radius = 0.0
	walk_speed = 0.0


func update_game_hour(hour: float) -> void:
	condition_context["game_hour"] = fposmod(hour, 24.0)
	condition_context["current_package"] = str(active_package.get("id", ""))
	var next_package := _select_package(condition_context.get("packages", []) as Array, float(condition_context["game_hour"]))
	if str(next_package.get("id", "")) == str(active_package.get("id", "")):
		return
	active_package = next_package
	package_semantics_available = not active_package.is_empty()
	set_meta("opennv_active_package", str(active_package.get("id", "")))
	set_meta("opennv_active_package_type", int((active_package.get("packageData", {}) as Dictionary).get("type", -1)))
	wander_radius = 0.0
	walk_speed = 0.0
	travel_target_ref = ""
	travel_target_resolved = false
	direct_travel_target_enabled = false
	patrol_route_mode = false
	wander_center_ref = ""
	flee_mode = false
	package_route_door_ref = ""
	package_portal_pending = false
	package_route_waypoint = false
	activity_state = "idle"
	activity_on_arrival = "idle"
	_reset_package_telemetry()
	navigation_repath_seconds = 0.0
	if package_semantics_available:
		_configure_authored_package_motion()
	_sync_activity_animation()


func _reset_package_telemetry() -> void:
	set_meta("opennv_package_target_resolved", false)
	set_meta("opennv_package_arrived", false)
	set_meta("opennv_package_steering", false)
	set_meta("opennv_package_moving", false)
	set_meta("opennv_package_stuck", false)
	progress_sample_seconds = 0.0
	progress_sample_position = global_position if is_inside_tree() else position


func _select_package(packages: Array, hour: float) -> Dictionary:
	return PACKAGE_RUNTIME.select_package(packages, hour, condition_context)


func _configure_authored_package_motion() -> void:
	var package_type := int((active_package.get("packageData", {}) as Dictionary).get("type", -1))
	# Fallout package types 5/12/13 are Wander/Sandbox/Patrol. Patrols whose
	# points are encoded only in linked-ref chains remain stationary until that
	# graph is compiled; radius-bearing editor-location patrols are navigable.
	var package_data := active_package.get("packageData", {}) as Dictionary
	var no_wandering := (int(package_data.get("typeSpecificFlags", 0)) & (1 << 5)) != 0
	activity_state = _package_activity_name(package_type)
	activity_on_arrival = activity_state
	set_meta("opennv_package_activity", activity_state)
	if package_type in [5, 12, 13] and not no_wandering:
		var location := active_package.get("packageLocation", {}) as Dictionary
		var location_type := int(location.get("type", -1))
		var authored_radius := int(location.get("radius", 0 if package_type == 13 else 256))
		wander_radius = clampf(float(maxi(64, authored_radius)) / 70.0, 0.9, 12.0) if authored_radius > 0 or package_type != 13 else 0.0
		walk_speed = 0.42 if "creature" not in category else 0.62
		if location_type == 0:
			var location_ref := str(location.get("location", ""))
			if package_type == 13 and authored_radius <= 0:
				travel_target_ref = location_ref
				patrol_route_mode = not travel_target_ref.is_empty()
				target_desired_distance = 0.7
				wander_radius = 0.0
			else:
				wander_center_ref = location_ref
		elif location_type == 6:
			var linked_ref := str(condition_context.get("actor_linked_reference", ""))
			if package_type == 13 and not linked_ref.is_empty():
				travel_target_ref = linked_ref
				patrol_route_mode = true
				target_desired_distance = 0.7
				wander_radius = 0.0
			else:
				wander_center_ref = linked_ref
		elif package_type == 13 and authored_radius <= 0 and location_type in [2, 3]:
			travel_target_position = (global_position if is_inside_tree() else position) \
				if location_type == 2 else spawn_position
			direct_travel_target_enabled = true
			target_desired_distance = 0.7
			wander_radius = 0.0
	elif package_type == 6:
		var target := active_package.get("packageTarget", {}) as Dictionary
		if int(target.get("type", -1)) == 0:
			travel_target_ref = str(target.get("target", ""))
		var travel_location := active_package.get("packageLocation", {}) as Dictionary
		var travel_location_type := int(travel_location.get("type", -1))
		if travel_target_ref.is_empty() and travel_location_type == 0:
			travel_target_ref = str(travel_location.get("location", ""))
		elif travel_target_ref.is_empty() and travel_location_type == 6:
			travel_target_ref = str(condition_context.get("actor_linked_reference", ""))
		elif travel_target_ref.is_empty() and travel_location_type in [2, 3]:
			travel_target_position = global_position if travel_location_type == 2 else spawn_position
			direct_travel_target_enabled = true
		walk_speed = (0.50 if "creature" not in category else 0.68) \
				if not travel_target_ref.is_empty() or direct_travel_target_enabled else 0.0
		target_desired_distance = 0.7
	elif package_type in [1, 2, 7, 15]:
		# Follow resolves specific references—including the player FormID 0x14—
		# through the same bounded reference-position adapter as Travel.
		var follow_target := active_package.get("packageTarget", {}) as Dictionary
		if int(follow_target.get("type", -1)) == 0:
			travel_target_ref = str(follow_target.get("target", ""))
		target_desired_distance = clampf(float(maxi(96, int(follow_target.get("distance", 210)))) / 70.0, 1.35, 12.0)
		walk_speed = (0.56 if "creature" not in category else 0.72) if not travel_target_ref.is_empty() else 0.0
	elif package_type in [3, 4, 8, 9, 14, 16]:
		# Eat, Sleep, UseItemAt, Ambush, Guard and UseWeapon first travel to
		# their authored package location/reference, then enter the authored
		# stationary activity. Editor/current-location variants begin in place.
		travel_target_ref = _package_location_reference(active_package)
		if travel_target_ref.is_empty() and package_type in [8, 14]:
			travel_target_ref = _package_target_reference(active_package)
		if not travel_target_ref.is_empty():
			walk_speed = 0.48 if "creature" not in category else 0.66
			target_desired_distance = 0.75
			activity_state = "travel_to_" + activity_on_arrival
		else:
			walk_speed = 0.0
	elif package_type == 0:
		travel_target_ref = _package_target_reference(active_package)
		walk_speed = (0.50 if "creature" not in category else 0.68) if not travel_target_ref.is_empty() else 0.0
		target_desired_distance = 1.0
	elif package_type == 10:
		travel_target_ref = _package_target_reference(active_package)
		flee_mode = not travel_target_ref.is_empty()
		walk_speed = (0.85 if "creature" not in category else 1.05) if flee_mode else 0.0
		target_desired_distance = 12.0
	else:
		wander_radius = 0.0
		walk_speed = 0.0
	set_meta("opennv_package_activity", activity_state)


func _package_target_reference(package: Dictionary) -> String:
	var target := package.get("packageTarget", {}) as Dictionary
	return str(target.get("target", "")) if int(target.get("type", -1)) == 0 else ""


func _package_location_reference(package: Dictionary) -> String:
	var location := package.get("packageLocation", {}) as Dictionary
	var location_type := int(location.get("type", -1))
	if location_type == 0:
		return str(location.get("location", ""))
	if location_type == 6:
		return str(condition_context.get("actor_linked_reference", ""))
	return ""


func _package_activity_name(package_type: int) -> String:
	return PACKAGE_RUNTIME.activity_name(package_type)


func _sync_activity_animation() -> void:
	if visual == null or ("humanoid" not in category and "settler" not in category):
		return
	var requested := activity_state if PACKAGE_ACTION_CLIPS.has(activity_state) else "idle"
	if requested == activity_animation:
		return
	var player := visual.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if requested != "idle":
		var path := str(PACKAGE_ACTION_CLIPS[requested])
		if not FileAccess.file_exists(path):
			return
		if not loaded_action_clips.has(requested):
			player = ANIMATION_LOADER.attach_clip(visual, path, requested, false)
			if player == null:
				return
			loaded_action_clips[requested] = true
		if player != null and player.has_animation(requested):
			player.play(requested)
			activity_animation = requested
			set_meta("opennv_package_action_animation", requested)
		return
	if player != null and player.has_animation("idle"):
		player.play("idle")
	activity_animation = "idle"
	set_meta("opennv_package_action_animation", "idle")


func export_runtime_state() -> Dictionary:
	var package_ids: Array[String] = []
	for package_value in condition_context.get("packages", []):
		package_ids.append(str((package_value as Dictionary).get("id", "")))
	return {
		"schema": "opennv-actor-runtime-state/v2",
		"active_package_id": str(active_package.get("id", "")),
		"package_type": int((active_package.get("packageData", {}) as Dictionary).get("type", -1)),
		"package_ids": package_ids,
		"actor_linked_seed": str(condition_context.get("actor_linked_reference", "")),
		"last_schedule_game_minute": float(condition_context.get("game_minute", 0.0)),
		"schedule_epoch": 0,
		"simulation_mode": "schedule_only",
		"navigation_target_serial": navigation_target_serial,
		"travel_target_ref": travel_target_ref,
		"travel_target_position": travel_target_position,
		"target_desired_distance": target_desired_distance,
		"patrol_route_mode": patrol_route_mode,
		"wander_center_ref": wander_center_ref,
		"flee_mode": flee_mode,
		"activity_state": activity_state,
		"activity_on_arrival": activity_on_arrival,
		"direct_travel_target_enabled": direct_travel_target_enabled,
		"authored_spawn_position": spawn_position,
	}


func restore_runtime_state(state: Dictionary) -> bool:
	if _canonical_form_id(state.get("active_package_id", "")) \
			!= _canonical_form_id(active_package.get("id", "")):
		return false
	navigation_target_serial = int(state.get("navigation_target_serial", navigation_target_serial))
	travel_target_ref = str(state.get("travel_target_ref", travel_target_ref))
	travel_target_position = state.get("travel_target_position", travel_target_position) as Vector3
	target_desired_distance = float(state.get("target_desired_distance", target_desired_distance))
	patrol_route_mode = bool(state.get("patrol_route_mode", patrol_route_mode))
	wander_center_ref = str(state.get("wander_center_ref", wander_center_ref))
	flee_mode = bool(state.get("flee_mode", flee_mode))
	activity_state = str(state.get("activity_state", activity_state))
	activity_on_arrival = str(state.get("activity_on_arrival", activity_on_arrival))
	direct_travel_target_enabled = bool(state.get("direct_travel_target_enabled", direct_travel_target_enabled))
	spawn_position = state.get("authored_spawn_position", spawn_position) as Vector3
	travel_target_resolved = false
	navigation_repath_seconds = fposmod(phase, 1.0)
	set_meta("opennv_package_activity", activity_state)
	_sync_activity_animation()
	return true


func _canonical_form_id(value: Variant) -> String:
	var text := str(value).strip_edges().to_lower()
	if text.is_empty():
		return ""
	if text.begins_with("0x"):
		text = text.substr(2)
	return "0x%08x" % text.hex_to_int()


func update_runtime_cell(cell_id: String, scope: String, interior: bool) -> void:
	condition_context["actor_cell"] = cell_id
	condition_context["actor_scope"] = scope
	condition_context["actor_interior"] = interior
	package_route_door_ref = ""
	package_portal_pending = false
	package_route_waypoint = false
	travel_target_resolved = false
	navigation_repath_seconds = 0.1


func complete_package_portal(success: bool) -> void:
	package_portal_pending = false
	travel_target_resolved = false
	if success:
		package_route_door_ref = ""
	navigation_repath_seconds = 0.25 if success else 1.0


func _ready() -> void:
	spawn_position = global_position
	visual = get_node_or_null("Visual") as Node3D
	progress_sample_position = global_position
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
	var center := spawn_position
	if not wander_center_ref.is_empty():
		var resolver_value: Variant = condition_context.get("reference_position_resolver")
		if resolver_value is Callable:
			var resolved: Variant = (resolver_value as Callable).call(wander_center_ref)
			if resolved is Vector3:
				center = resolved as Vector3
	var candidate := center + Vector3(cos(angle), 0.0, sin(angle)) * radial
	var target := NavigationServer3D.map_get_closest_point(navigation_map, candidate)
	if target.distance_to(center) > wander_radius * 1.35 or target.distance_to(global_position) < 0.45:
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
	if not travel_target_ref.is_empty() and navigation_repath_seconds <= 0.0:
		if not travel_target_resolved or navigation_agent.is_navigation_finished() or _package_requires_dynamic_repath():
			_resolve_authored_travel_target()
		else:
			# Keep the NavigationAgent's current path index for static targets.
			# Reassigning the same target every two seconds resets long routes to
			# waypoint zero and makes actors oscillate at cross-cell seams.
			navigation_repath_seconds = 0.5
	elif direct_travel_target_enabled and navigation_repath_seconds <= 0.0:
		_resolve_direct_travel_target()
	if wander_radius > 0.0 and travel_target_ref.is_empty() and (navigation_repath_seconds <= 0.0 or navigation_agent.is_navigation_finished()):
		if not _choose_authored_wander_target():
			navigation_repath_seconds = 0.5
	var horizontal := Vector3.ZERO
	if (wander_radius > 0.0 or travel_target_resolved) and not navigation_agent.is_navigation_finished():
		var next_position := navigation_agent.get_next_path_position()
		horizontal = Vector3(next_position.x - global_position.x, 0.0, next_position.z - global_position.z)
	if horizontal.length_squared() > 0.04:
		var direction := horizontal.normalized()
		velocity.x = move_toward(velocity.x, direction.x * walk_speed, delta * 1.8)
		velocity.z = move_toward(velocity.z, direction.z * walk_speed, delta * 1.8)
		rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), minf(1.0, delta * 2.5))
		set_meta("opennv_package_steering", true)
	else:
		velocity.x = move_toward(velocity.x, 0.0, delta * 1.8)
		velocity.z = move_toward(velocity.z, 0.0, delta * 1.8)
		set_meta("opennv_package_steering", false)
	velocity.y = move_toward(velocity.y, 0.0 if aerial else -4.5, delta * 5.0)
	move_and_slide()
	_update_motion_telemetry(delta, horizontal.length_squared() > 0.04)


func _package_requires_dynamic_repath() -> bool:
	var package_type := int((active_package.get("packageData", {}) as Dictionary).get("type", -1))
	return package_type in [1, 2, 7, 10, 15]


func _update_motion_telemetry(delta: float, steering: bool) -> void:
	progress_sample_seconds += delta
	if progress_sample_seconds < 1.0:
		return
	var displacement := global_position.distance_to(progress_sample_position)
	set_meta("opennv_package_moving", displacement >= 0.05)
	set_meta("opennv_package_stuck", steering and displacement < 0.05)
	progress_sample_position = global_position
	progress_sample_seconds = 0.0


func _resolve_authored_travel_target() -> void:
	travel_target_resolved = false
	set_meta("opennv_package_target_resolved", false)
	navigation_repath_seconds = 1.0
	var actor_scope := str(condition_context.get("actor_scope", ""))
	var actor_cell := str(condition_context.get("actor_cell", ""))
	var target_cell := ""
	var cell_resolver_value: Variant = condition_context.get("reference_cell_resolver")
	if cell_resolver_value is Callable:
		target_cell = str((cell_resolver_value as Callable).call(travel_target_ref))
	var target_scope := ""
	var scope_resolver_value: Variant = condition_context.get("reference_scope_resolver")
	if scope_resolver_value is Callable:
		target_scope = str((scope_resolver_value as Callable).call(travel_target_ref))
	# A different exterior CELL in the same worldspace still needs the streamed
	# NAVM corridor planner. Directly projecting a remote marker onto only the
	# resident navigation map makes patrols stop at the current cell boundary.
	var requires_portal := (not target_scope.is_empty() and target_scope != actor_scope) \
		or (not target_cell.is_empty() and target_cell != actor_cell)
	var target: Vector3
	if requires_portal:
		if package_portal_pending:
			return
		var route_resolver_value: Variant = condition_context.get("package_route_resolver")
		if not route_resolver_value is Callable:
			return
		var step := (route_resolver_value as Callable).call(actor_cell, target_cell) as Dictionary
		if step.is_empty() or not step.get("position") is Vector3:
			return
		package_route_door_ref = str(step.get("door", ""))
		package_route_waypoint = bool(step.get("corridor", false))
		target = step.get("position") as Vector3
	else:
		package_route_door_ref = ""
		package_route_waypoint = false
		var resolver_value: Variant = condition_context.get("reference_position_resolver")
		if not resolver_value is Callable:
			return
		var resolved: Variant = (resolver_value as Callable).call(travel_target_ref)
		if not resolved is Vector3:
			return
		target = resolved as Vector3
	if bool(condition_context.get("actor_interior", false)):
		if target_cell != actor_cell and package_route_door_ref.is_empty():
			return
	var navigation_map := navigation_agent.get_navigation_map()
	if not navigation_map.is_valid() or NavigationServer3D.map_get_iteration_id(navigation_map) == 0:
		return
	if flee_mode:
		var away := global_position - target
		away.y = 0.0
		if away.length_squared() < 0.01:
			away = Vector3(cos(phase), 0.0, sin(phase))
		var flee_candidate := global_position + away.normalized() * target_desired_distance
		travel_target_position = NavigationServer3D.map_get_closest_point(navigation_map, flee_candidate)
	else:
		travel_target_position = NavigationServer3D.map_get_closest_point(navigation_map, target)
		var snap_distance := (Vector2(travel_target_position.x, travel_target_position.z)
			.distance_to(Vector2(target.x, target.z))) if package_route_waypoint else travel_target_position.distance_to(target)
		if snap_distance > 3.0:
			return
	var arrival_distance := 0.9 if not package_route_door_ref.is_empty() or package_route_waypoint \
		else (0.7 if flee_mode else target_desired_distance)
	if travel_target_position.distance_to(global_position) <= arrival_distance:
		if package_route_waypoint:
			travel_target_resolved = false
			set_meta("opennv_package_target_resolved", false)
			set_meta("opennv_package_arrived", false)
			navigation_repath_seconds = 0.6
			return
		if not package_route_door_ref.is_empty():
			var activator_value: Variant = condition_context.get("package_door_activator")
			if activator_value is Callable and bool((activator_value as Callable).call(self, package_route_door_ref)):
				package_portal_pending = true
				travel_target_resolved = false
				set_meta("opennv_package_arrived", false)
				navigation_repath_seconds = 2.0
			return
		set_meta("opennv_package_arrived", true)
		if patrol_route_mode:
			var link_resolver_value: Variant = condition_context.get("reference_link_resolver")
			if link_resolver_value is Callable:
				var next_ref := str((link_resolver_value as Callable).call(travel_target_ref))
				if not next_ref.is_empty() and next_ref != travel_target_ref:
					travel_target_ref = next_ref
					navigation_repath_seconds = 0.1
		elif not flee_mode and activity_state.begins_with("travel_to_"):
			activity_state = activity_on_arrival
			set_meta("opennv_package_activity", activity_state)
			_sync_activity_animation()
		return
	var path := NavigationServer3D.map_get_path(navigation_map, global_position, travel_target_position, true)
	if path.is_empty() or path[path.size() - 1].distance_to(travel_target_position) > 0.5:
		return
	navigation_agent.target_position = travel_target_position
	travel_target_resolved = true
	set_meta("opennv_package_target_resolved", true)
	set_meta("opennv_package_arrived", false)
	navigation_repath_seconds = 2.0 + fposmod(phase, 0.5)


func _resolve_direct_travel_target() -> void:
	travel_target_resolved = false
	set_meta("opennv_package_target_resolved", false)
	navigation_repath_seconds = 2.0
	var navigation_map := navigation_agent.get_navigation_map()
	if not navigation_map.is_valid() or NavigationServer3D.map_get_iteration_id(navigation_map) == 0:
		return
	var snapped := NavigationServer3D.map_get_closest_point(navigation_map, travel_target_position)
	if snapped.distance_to(travel_target_position) > 3.0:
		return
	if snapped.distance_to(global_position) <= target_desired_distance:
		set_meta("opennv_package_arrived", true)
		return
	var path := NavigationServer3D.map_get_path(navigation_map, global_position, snapped, true)
	if path.is_empty() or path[path.size() - 1].distance_to(snapped) > 0.5:
		return
	navigation_agent.target_position = snapped
	travel_target_resolved = true
	set_meta("opennv_package_target_resolved", true)
	set_meta("opennv_package_arrived", false)
	navigation_repath_seconds = 2.0 + fposmod(phase, 0.5)
