extends SceneTree

const RING_PATH := "res://generated/world/opennv-full-runtime-index.json"
const ACTOR_REF := "0x000ce94e"
const PATROL_PACKAGE := "0x00025482"
const CHAIN := ["0x000ce94c", "0x000ce94b", "0x000ce94a"]
const CELLS := ["0x0008434c", "0x00084349", "0x00084344"]
const DAY_PACKAGE := "0x00ff1001"
const NIGHT_PACKAGE := "0x00ff1002"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	root.add_child(streamer)
	streamer.call("_load_actor_packages")
	streamer.call("_load_package_navigation_index", RING_PATH)
	_configure_cells(streamer)
	streamer.runtime_condition_context = {"game_hour": 12.0}
	streamer.runtime_game_minute = 720.0
	var marker_position: Variant = streamer.call("_runtime_reference_position", CHAIN[0])
	if not marker_position is Vector3:
		_fail("real Novac marker position is unavailable")
		return
	var patrol_transform := Transform3D(Basis.from_euler(Vector3(0.1, 0.2, 0.3)), marker_position)
	_add_state(streamer, ACTOR_REF, CELLS[0], marker_position as Vector3, patrol_transform,
		[PATROL_PACKAGE], PATROL_PACKAGE, 13, CHAIN[0], CHAIN[0], true)
	var before_nodes: int = streamer.get_child_count()
	var before_cells: int = streamer.loaded_actor_cells.size()
	var before_nav: int = streamer.navigation_regions_by_cell.size()
	var before_staged: int = streamer.staged_interiors.size()
	var before_detail: int = streamer.loaded_detail_cells.size()
	var before_terrain: int = streamer.loaded_terrain_cells.size()
	var before_links: int = streamer.navigation_links_by_key.size()
	var before_pins: int = streamer.portal_pinned_cells.size()
	var before_portal_generation: int = streamer.player_portal_generation
	var before_actor_buckets: int = streamer.actor_nodes_by_cell.size()
	if not bool(streamer.call("_advance_single_offscreen_schedule", ACTOR_REF, 12.0, 721.0)):
		_fail("real Patrol state did not advance")
		return
	var patrol_wrapper := streamer.offscreen_actor_states[ACTOR_REF] as Dictionary
	var patrol_state := (((patrol_wrapper.get("placement") as Dictionary).get("_runtime_actor_state")) as Dictionary)
	if str(patrol_state.get("travel_target_ref")) != CHAIN[1] or int(patrol_state.get("patrol_hops")) != 1:
		_fail("schedule-only Patrol did not advance exactly one authored XLKR hop")
		return
	if not _spatial_unchanged(patrol_wrapper, CELLS[0], marker_position, patrol_transform):
		_fail("offscreen Patrol fabricated a spatial update")
		return
	var real_restore_actor := load("res://scripts/fnv_actor.gd").new() as CharacterBody3D
	real_restore_actor.call("configure", "real-unpadded-package-restore", "route-humanoid", {
		"actor_ref": ACTOR_REF, "actor_cell": CELLS[0], "actor_scope": "__exterior__",
		"actor_interior": false, "actor_linked_reference": CHAIN[0], "game_hour": 12.0,
		"packages": [streamer.actor_packages_by_id[PATROL_PACKAGE]], "restoring_offscreen": true,
	})
	if not bool(real_restore_actor.call("restore_runtime_state", patrol_state)) \
			or str(real_restore_actor.get("travel_target_ref")) != CHAIN[1]:
		_fail("canonical FormID restore rejected a real unpadded PACK id")
		return
	real_restore_actor.free()
	streamer.call("_advance_single_offscreen_schedule", ACTOR_REF, 12.0, 1200.0)
	patrol_state = ((((streamer.offscreen_actor_states[ACTOR_REF] as Dictionary).get("placement") as Dictionary).get("_runtime_actor_state")) as Dictionary)
	if str(patrol_state.get("travel_target_ref")) != CHAIN[1] or int(patrol_state.get("patrol_hops")) != 1:
		_fail("elapsed time fabricated Patrol traversal")
		return
	if streamer.get_child_count() != before_nodes or streamer.loaded_actor_cells.size() != before_cells \
			or streamer.navigation_regions_by_cell.size() != before_nav \
			or streamer.staged_interiors.size() != before_staged \
			or streamer.loaded_detail_cells.size() != before_detail \
			or streamer.loaded_terrain_cells.size() != before_terrain \
			or streamer.navigation_links_by_key.size() != before_links \
			or streamer.portal_pinned_cells.size() != before_pins \
			or streamer.player_portal_generation != before_portal_generation \
			or streamer.actor_nodes_by_cell.size() != before_actor_buckets:
		_fail("offscreen schedule processing materialized scene or residency state")
		return

	streamer.actor_packages_by_id[DAY_PACKAGE] = _package(DAY_PACKAGE, 5, 8, 1)
	streamer.actor_packages_by_id[NIGHT_PACKAGE] = _package(NIGHT_PACKAGE, 4, 9, 1)
	var schedule_ref := "0x00ff2001"
	var schedule_position := Vector3(3.0, 4.0, 5.0)
	var schedule_transform := Transform3D(Basis.from_euler(Vector3(0.3, -0.1, 0.2)), schedule_position)
	_add_state(streamer, schedule_ref, CELLS[0], schedule_position, schedule_transform,
		[DAY_PACKAGE, NIGHT_PACKAGE], DAY_PACKAGE, 5, "", "", false)
	var stale_schedule_wrapper := streamer.offscreen_actor_states[schedule_ref] as Dictionary
	var stale_schedule_placement := stale_schedule_wrapper.get("placement") as Dictionary
	var stale_schedule_state := stale_schedule_placement.get("_runtime_actor_state") as Dictionary
	stale_schedule_state["flee_mode"] = true
	stale_schedule_state["direct_travel_target_enabled"] = true
	stale_schedule_state["wander_center_ref"] = "0x00abcdef"
	stale_schedule_state["target_desired_distance"] = 12.0
	stale_schedule_placement["_runtime_actor_state"] = stale_schedule_state
	stale_schedule_wrapper["placement"] = stale_schedule_placement
	streamer.offscreen_actor_states[schedule_ref] = stale_schedule_wrapper
	streamer.call("_advance_single_offscreen_schedule", schedule_ref, 9.25, 556.0)
	var schedule_wrapper := streamer.offscreen_actor_states[schedule_ref] as Dictionary
	var schedule_state := (((schedule_wrapper.get("placement") as Dictionary).get("_runtime_actor_state")) as Dictionary)
	if str(schedule_state.get("active_package_id")) != NIGHT_PACKAGE or int(schedule_state.get("package_type")) != 4 \
			or str(schedule_state.get("activity_state")) != "sleep" or int(schedule_state.get("schedule_epoch")) != 1 \
			or bool(schedule_state.get("flee_mode", true)) or bool(schedule_state.get("direct_travel_target_enabled", true)) \
			or not str(schedule_state.get("wander_center_ref", "")).is_empty() \
			or not is_equal_approx(float(schedule_state.get("target_desired_distance", 0.0)), 0.7):
		_fail("offscreen actor did not change schedule intent at the authored boundary")
		return
	if not _spatial_unchanged(schedule_wrapper, CELLS[0], schedule_position, schedule_transform):
		_fail("schedule boundary moved the unloaded actor")
		return
	var restored_actor := load("res://scripts/fnv_actor.gd").new() as CharacterBody3D
	restored_actor.position = schedule_position
	restored_actor.call("configure", "schedule-restore", "route-humanoid", {
		"actor_ref": schedule_ref, "actor_cell": CELLS[0], "actor_scope": "__exterior__",
		"actor_interior": false, "actor_linked_reference": "", "game_hour": 9.25,
		"packages": [streamer.actor_packages_by_id[DAY_PACKAGE], streamer.actor_packages_by_id[NIGHT_PACKAGE]],
		"restoring_offscreen": true,
	})
	restored_actor.call("restore_runtime_state", schedule_state)
	if str(restored_actor.get_meta("opennv_active_package", "")) != NIGHT_PACKAGE \
			or str(restored_actor.get("activity_state")) != "sleep":
		_fail("materialization did not preserve the schedule-current intent")
		return
	restored_actor.free()
	var queued_ref := "0x00ff2003"
	_add_state(streamer, queued_ref, CELLS[0], schedule_position, schedule_transform,
		[DAY_PACKAGE, NIGHT_PACKAGE], DAY_PACKAGE, 5, "", "", false)
	var queued_wrapper := streamer.offscreen_actor_states[queued_ref] as Dictionary
	var stale_queued_placement := (queued_wrapper.get("placement") as Dictionary).duplicate(true)
	stale_queued_placement["_runtime_offscreen_ref"] = queued_ref
	streamer.pending_offscreen_actor_refs[queued_ref] = true
	streamer.runtime_condition_context["game_hour"] = 9.25
	streamer.runtime_game_minute = 556.0
	streamer.call("_refresh_queued_offscreen_actor_state", stale_queued_placement)
	var refreshed_state := stale_queued_placement.get("_runtime_actor_state") as Dictionary
	if str(refreshed_state.get("active_package_id", "")) != NIGHT_PACKAGE:
		_fail("queued actor commit retained a stale pre-boundary package copy")
		return
	streamer.pending_offscreen_actor_refs.erase(queued_ref)
	var gap_package := "0x00ff1004"
	streamer.actor_packages_by_id[gap_package] = _package(gap_package, 10, 8, 1)
	var gap_ref := "0x00ff2002"
	_add_state(streamer, gap_ref, CELLS[0], schedule_position, schedule_transform,
		[gap_package], gap_package, 10, "", "0x00000014", false)
	var gap_wrapper := streamer.offscreen_actor_states[gap_ref] as Dictionary
	var gap_placement := gap_wrapper.get("placement") as Dictionary
	var gap_state := gap_placement.get("_runtime_actor_state") as Dictionary
	gap_state["flee_mode"] = true
	gap_state["direct_travel_target_enabled"] = true
	gap_state["wander_center_ref"] = "0x00abcdef"
	gap_state["target_desired_distance"] = 12.0
	gap_placement["_runtime_actor_state"] = gap_state
	gap_wrapper["placement"] = gap_placement
	streamer.offscreen_actor_states[gap_ref] = gap_wrapper
	streamer.call("_advance_single_offscreen_schedule", gap_ref, 12.0, 720.0)
	gap_state = ((((streamer.offscreen_actor_states[gap_ref] as Dictionary).get("placement") as Dictionary).get("_runtime_actor_state")) as Dictionary)
	if not str(gap_state.get("active_package_id", "")).is_empty() \
			or str(gap_state.get("activity_state", "")) != "idle" \
			or bool(gap_state.get("flee_mode", true)) or bool(gap_state.get("direct_travel_target_enabled", true)) \
			or not str(gap_state.get("wander_center_ref", "")).is_empty() \
			or not str(gap_state.get("travel_target_ref", "")).is_empty() \
			or not is_equal_approx(float(gap_state.get("target_desired_distance", 0.0)), 0.7):
		_fail("schedule gap retained stale package motion intent")
		return
	if float(gap_state.get("last_schedule_game_minute", -1.0)) != 720.0 \
			or int(gap_state.get("navigation_target_serial", 0)) != 1:
		_fail("schedule gap did not stamp its epoch/target invalidation")
		return

	var batch_package := "0x00ff1003"
	streamer.actor_packages_by_id[batch_package] = _package(batch_package, 5, 255, 0)
	for index in range(130):
		var ref_id := "0x%08x" % (0x00fe0000 + index)
		var position := Vector3(float(index), 0.0, 0.0)
		_add_state(streamer, ref_id, CELLS[0], position, Transform3D(Basis.IDENTITY, position),
			[batch_package], batch_package, 5, "", "", false)
	var processed_before := int(streamer.offscreen_schedule_counters.states_processed)
	var processed := int(streamer.call("_advance_offscreen_actor_schedules", 12.0, 800.0, 64))
	if processed <= 0 or processed > 64 \
			or int(streamer.offscreen_schedule_counters.states_processed) - processed_before != processed:
		_fail("offscreen round-robin schedule budget was not enforced")
		return
	for pass_index in range(20):
		streamer.call("_advance_offscreen_actor_schedules", 12.0, 801.0 + pass_index, 64)
	var updated_batch := 0
	for index in range(130):
		var ref_id := "0x%08x" % (0x00fe0000 + index)
		var wrapper := streamer.offscreen_actor_states[ref_id] as Dictionary
		var state := ((((wrapper.get("placement")) as Dictionary).get("_runtime_actor_state")) as Dictionary)
		if float(state.get("last_schedule_game_minute", 0.0)) >= 800.0:
			updated_batch += 1
	if updated_batch != 130:
		_fail("round-robin cursor starved offscreen schedule states")
		return
	if int(streamer.offscreen_schedule_counters.spatial_updates) != 0:
		_fail("schedule-only runtime reported spatial mutation")
		return
	if int(streamer.offscreen_schedule_counters.max_tick_usec) > 2000:
		_fail("offscreen schedule work exceeded its two-millisecond 60 FPS sub-budget guard")
		return
	print("OPENNV_OFFSCREEN_SCHEDULE_PASS patrol_hops=1 package_changes=%d batch=%d spatial_updates=0 max_tick_usec=%d" % [
		int(streamer.offscreen_schedule_counters.package_changes), updated_batch,
		int(streamer.offscreen_schedule_counters.max_tick_usec)])
	quit(0)

func _configure_cells(streamer: Node3D) -> void:
	var ring := JSON.parse_string(FileAccess.get_file_as_string(RING_PATH)) as Dictionary
	streamer.primary_world_id = streamer.call("_canonical_form_id", ring.get("world_form_id", ""))
	streamer.active_exterior_world_id = streamer.primary_world_id
	for cell_value in ring.get("cells", []):
		var cell := cell_value as Dictionary
		var cell_id := str(streamer.call("_canonical_form_id", cell.get("form_id", "")))
		if cell_id in CELLS:
			streamer.cell_indices_by_id[cell_id] = cell
			streamer.exterior_scope_by_cell[cell_id] = "__exterior__"

func _add_state(streamer: Node3D, ref_id: String, cell_id: String, position: Vector3,
		actor_transform: Transform3D, package_ids: Array, active_package: String,
		package_type: int, linked_seed: String, target_ref: String, patrol: bool) -> void:
	var placement := {
		"form_id": ref_id, "base_form_id": "0x00000001", "linked_reference": linked_seed,
		"_runtime_cell": cell_id, "_runtime_scope": "__exterior__", "_runtime_interior": false,
		"_runtime_restore_transform": actor_transform,
		"_runtime_actor_state": {
			"schema": "opennv-actor-runtime-state/v2", "active_package_id": active_package,
			"package_type": package_type, "package_ids": package_ids,
			"actor_linked_seed": linked_seed, "last_schedule_game_minute": 0.0,
			"schedule_epoch": 0, "simulation_mode": "schedule_only",
			"travel_target_ref": target_ref, "patrol_current_ref": target_ref,
			"patrol_route_mode": patrol, "patrol_hops": 0,
			"target_desired_distance": 0.7, "activity_state": "patrol" if patrol else "wander",
			"activity_on_arrival": "patrol" if patrol else "wander", "navigation_target_serial": 0,
		},
	}
	streamer.offscreen_actor_states[ref_id] = {"cell": cell_id, "position": position, "placement": placement}
	if not streamer.offscreen_actor_refs_by_cell.has(cell_id):
		streamer.offscreen_actor_refs_by_cell[cell_id] = []
	(streamer.offscreen_actor_refs_by_cell[cell_id] as Array).append(ref_id)

func _package(id_value: String, type_value: int, start: int, duration: int) -> Dictionary:
	return {"id": id_value, "packageData": {"type": type_value},
		"packageSchedule": {"time": start, "duration": duration},
		"packageLocation": {"type": 3, "radius": 140}, "conditionData": []}

func _spatial_unchanged(wrapper: Dictionary, cell_id: String, position: Vector3,
		actor_transform: Transform3D) -> bool:
	var placement := wrapper.get("placement") as Dictionary
	return str(wrapper.get("cell")) == cell_id and (wrapper.get("position") as Vector3).is_equal_approx(position) \
		and (placement.get("_runtime_restore_transform") as Transform3D).is_equal_approx(actor_transform)

func _fail(reason: String) -> void:
	push_error("OPENNV_OFFSCREEN_SCHEDULE_FAIL %s" % reason)
	quit(1)
