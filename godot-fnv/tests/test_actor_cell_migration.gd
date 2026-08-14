extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	root.add_child(streamer)
	var world := "0x0000003c"
	var old_cell := "0x00000100"
	var new_cell := "0x00000101"
	streamer.primary_world_id = world
	streamer.active_exterior_world_id = world
	streamer.source_origin = Vector3.ZERO
	streamer.cell_indices_by_grid = {
		"%s|0,0" % world: [{"form_id": old_cell, "world_form_id": world, "grid": [0, 0]}],
		"%s|1,0" % world: [{"form_id": new_cell, "world_form_id": world, "grid": [1, 0]}],
	}
	streamer.cell_indices_by_id = {
		old_cell: {"form_id": old_cell, "world_form_id": world, "grid": [0, 0]},
		new_cell: {"form_id": new_cell, "world_form_id": world, "grid": [1, 0]},
	}
	streamer.loaded_actor_cells = {old_cell: true}
	var actor := load("res://scripts/fnv_actor.gd").new() as CharacterBody3D
	actor.position = Vector3(62.0, 0.0, 0.0)
	actor.set_meta("fnv_form_id", "0x00000200")
	actor.set_meta("fnv_actor_id", "migration-test")
	actor.set_meta("opennv_runtime_cell", old_cell)
	actor.set_meta("opennv_runtime_scope", "__exterior__")
	var manifest := JSON.parse_string(FileAccess.get_file_as_string(
		"res://generated/actors/actor-manifest-skeletal-v8.json")) as Dictionary
	var actor_record := (manifest.get("actors", []) as Array)[0] as Dictionary
	var package := {"id": "0x5", "packageData": {"type": 12},
		"packageSchedule": {"time": 255, "duration": 0},
		"packageLocation": {"type": 3, "radius": 210}, "conditionData": []}
	var placement := {
		"form_id": "0x00000200", "base_form_id": str(actor_record.get("base_form", "")),
		"base_type": "NPC_", "default_enabled": true, "packages": ["0x5"],
		"position": [0.0, 0.0, 0.0], "_runtime_cell": old_cell,
		"_runtime_scope": "__exterior__", "_runtime_origin": [0.0, 0.0, 0.0],
		"_runtime_stage": [0.0, 0.0, 0.0], "_runtime_interior": false,
	}
	actor.set_meta("opennv_spawn_placement", placement)
	streamer.add_child(actor)
	await process_frame
	actor.call("configure", "migration-test", "route-humanoid", {
		"actor_ref": "0x00000200", "game_hour": 12.0, "packages": [package]})
	actor.spawn_position = Vector3(5.0, 0.0, 0.0)
	actor.navigation_target_serial = 17
	streamer.actor_cache_by_ref["0x00000200"] = actor_record
	streamer.actor_packages_by_id["0x00000005"] = package
	streamer.actor_nodes_by_form_id = {"0x00000200": actor}
	streamer.stream_nodes_by_cell = {old_cell: [actor], new_cell: []}
	streamer.actor_nodes_by_cell = {old_cell: [actor], new_cell: []}
	streamer.reference_ids_by_cell = {old_cell: ["0x00000200"], new_cell: []}
	streamer.reference_runtime_cells = {"0x00000200": old_cell}
	streamer.actor_visual_status_by_cell = {old_cell: {"0x00000200": "exact"}, new_cell: {}}
	streamer.call("_migrate_exterior_actor_ownership", world)
	if streamer.pending_actor_cell_promotions.size() != 1:
		push_error("OPENNV_ACTOR_CELL_MIGRATION_FAIL destination promotion was not budget-queued")
		quit(1)
		return
	streamer.call("_process", 0.0)
	streamer.call("_migrate_exterior_actor_ownership", world)
	if str(actor.get_meta("opennv_runtime_cell", "")) != new_cell \
			or not (streamer.actor_nodes_by_cell[new_cell] as Array).has(actor) \
			or (streamer.actor_nodes_by_cell[old_cell] as Array).has(actor) \
			or str(streamer.reference_runtime_cells["0x00000200"]) != new_cell:
		push_error("OPENNV_ACTOR_CELL_MIGRATION_FAIL ownership did not follow live cell")
		quit(1)
		return
	streamer.call("_queue_placement", {
		"form_id": "0x00000200", "base_form_id": "0x00000300", "base_type": "NPC_",
		"default_enabled": true, "position": [0.0, 0.0, 0.0],
	}, old_cell, Vector3.ZERO, Vector3.ZERO, false, "__exterior__", 0)
	if str(streamer.reference_runtime_cells["0x00000200"]) != new_cell \
			or (streamer.actor_nodes_by_form_id as Dictionary).size() != 1:
		push_error("OPENNV_ACTOR_CELL_MIGRATION_FAIL home-cell reload duplicated/reset migrated actor")
		quit(1)
		return
	streamer.call("_capture_offscreen_actor_state", actor)
	if not streamer.offscreen_actor_states.has("0x00000200"):
		push_error("OPENNV_ACTOR_CELL_MIGRATION_FAIL live state was not captured")
		quit(1)
		return
	(streamer.stream_nodes_by_cell[new_cell] as Array).erase(actor)
	(streamer.actor_nodes_by_cell[new_cell] as Array).erase(actor)
	streamer.actor_nodes_by_form_id.erase("0x00000200")
	actor.queue_free()
	await process_frame
	streamer.call("_queue_offscreen_actors_for_cell", new_cell, Vector3.ZERO,
		Vector3.ZERO, false, "__exterior__", 0)
	streamer.set_process(true)
	var restored: CharacterBody3D
	for _frame in range(240):
		await process_frame
		var candidate := streamer.actor_nodes_by_form_id.get("0x00000200") as CharacterBody3D
		if is_instance_valid(candidate):
			restored = candidate
			break
	if restored == null or Vector2(restored.global_position.x, restored.global_position.z).distance_to(Vector2(62.0, 0.0)) > 0.05 \
			or int(restored.navigation_target_serial) < 17 \
			or Vector2(restored.spawn_position.x, restored.spawn_position.z).distance_to(Vector2(5.0, 0.0)) > 0.05 \
			or streamer.offscreen_actor_states.has("0x00000200"):
		push_error("OPENNV_ACTOR_CELL_MIGRATION_FAIL offscreen actor state did not restore actor=%s position=%s serial=%s retained=%s" % [
			str(restored), str(restored.global_position if restored != null else Vector3.ZERO),
			str(restored.navigation_target_serial if restored != null else -1),
			str(streamer.offscreen_actor_states.has("0x00000200"))])
		quit(1)
		return
	var stats := streamer.call("runtime_stats") as Dictionary
	if int(stats.get("actor_lifecycle_invariant_violations", -1)) != 0 \
			or int(stats.get("actor_lifecycle_captures", 0)) != 1 \
			or int(stats.get("actor_lifecycle_migrations", 0)) != 1 \
			or int(stats.get("actor_restore_successes", 0)) != 1:
		push_error("OPENNV_ACTOR_CELL_MIGRATION_FAIL lifecycle stats=%s" % JSON.stringify(stats))
		quit(1)
		return
	print("OPENNV_ACTOR_CELL_MIGRATION_PASS old=%s new=%s" % [old_cell, new_cell])
	quit(0)
