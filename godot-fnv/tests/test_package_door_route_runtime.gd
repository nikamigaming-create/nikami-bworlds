extends SceneTree


class FakeDoor:
	extends Node3D
	var activated_actor: Node

	func activate(actor: Node = null) -> bool:
		activated_actor = actor
		return true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	root.add_child(streamer)
	var cell_a := "0x00000100"
	var cell_b := "0x00000101"
	var cell_c := "0x00000102"
	var cell_d := "0x00000103"
	var world_id := "0x0000003c"
	var door_ab := "0x00001000"
	var door_bc := "0x00001001"
	var locked_door_ac := "0x00001002"
	streamer.primary_world_id = world_id
	streamer.active_exterior_world_id = world_id
	streamer.source_origin = Vector3.ZERO
	streamer.player_runtime_position = Vector3.ZERO
	streamer.package_navigation_cell_edges = {cell_a: [locked_door_ac, door_ab], cell_b: [door_bc]}
	streamer.package_navigation_doors = {
		door_ab: {"sourceCell": cell_a, "destinationCell": cell_b, "defaultEnabled": true},
		door_bc: {"sourceCell": cell_b, "destinationCell": cell_c, "defaultEnabled": true},
		locked_door_ac: {"sourceCell": cell_a, "destinationCell": cell_c,
			"defaultEnabled": true, "locked": true, "lockLevel": 50},
	}
	if bool(streamer.call("_package_navigation_target_available", "0x00003001",
			{"defaultEnabled": false})) \
			or bool(streamer.call("_package_navigation_target_available", "0x00003002",
			{"defaultEnabled": true, "enableParent": "0x00004000"})):
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL unavailable package targets were accepted")
		quit(1)
		return
	streamer.save_enabled_actor_refs["0x00003001"] = true
	if not bool(streamer.call("_package_navigation_target_available", "0x00003001",
			{"defaultEnabled": false})):
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL validated save enable override was ignored")
		quit(1)
		return
	streamer.save_enabled_actor_refs.erase("0x00003001")
	streamer.interior_names[cell_b] = "Intermediate Interior"
	streamer.interior_names[cell_c] = "Test Interior"
	streamer.cell_indices_by_id = {
		cell_a: {"form_id": cell_a, "world_form_id": world_id, "grid": [1, 0]},
		cell_d: {"form_id": cell_d, "world_form_id": world_id, "grid": [0, 0]},
	}
	streamer.cell_indices_by_grid[streamer.call("_world_grid_key", world_id, Vector2i(1, 0))] = [
		{"form_id": cell_a, "world_form_id": world_id, "grid": [1, 0]}]
	streamer.navmesh_external_cell_edges = {
		cell_d: [{"cell": cell_a, "sourcePosition": [256.0, 128.0, 0.0]}],
	}
	streamer.reference_runtime_positions[door_ab] = Vector3(4.0, 0.0, 2.0)
	var step := streamer.call("_package_route_step", cell_a, cell_c) as Dictionary
	if str(step.get("door", "")) != door_ab or step.get("position") != Vector3(4.0, 0.0, 2.0):
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL BFS did not select first authored door: %s" % JSON.stringify(step))
		quit(1)
		return
	var entrance_step := streamer.call("_package_route_step", cell_d, cell_c) as Dictionary
	if not bool(entrance_step.get("corridor", false)) \
			or str(entrance_step.get("corridorCell", "")) != cell_a \
			or streamer.pending_actor_cell_promotions.size() != 1:
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL exterior adjacency did not select reachable entrance")
		quit(1)
		return
	streamer.call("_process", 0.0)
	var remote_cell := "0x00000104"
	streamer.cell_indices_by_id[remote_cell] = {
		"form_id": remote_cell, "world_form_id": world_id, "grid": [10, 10],
	}
	streamer.call("_queue_actor_cell_promotion", remote_cell, world_id)
	if not streamer.pending_actor_cell_promotions.is_empty():
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL remote NPC promotion escaped the player actor budget")
		quit(1)
		return
	var fake_door := FakeDoor.new()
	streamer.add_child(fake_door)
	fake_door.set_meta("fnv_cell", cell_a)
	streamer.door_nodes_by_form_id[door_ab] = fake_door
	var actor := load("res://scripts/fnv_actor.gd").new() as CharacterBody3D
	var manifest := JSON.parse_string(FileAccess.get_file_as_string(
		"res://generated/actors/actor-manifest-skeletal-v8.json")) as Dictionary
	var actor_record := (manifest.get("actors", []) as Array)[0] as Dictionary
	streamer.actor_cache_by_ref["0x00002000"] = actor_record
	actor.set_meta("fnv_form_id", "0x00002000")
	actor.set_meta("fnv_base_form_id", actor_record.get("base_form", ""))
	actor.set_meta("fnv_actor_id", "door-route-test")
	actor.set_meta("opennv_runtime_cell", cell_a)
	actor.set_meta("opennv_runtime_scope", "__exterior__")
	actor.set_meta("opennv_spawn_placement", {
		"form_id": "0x00002000", "base_form_id": actor_record.get("base_form", ""),
		"base_type": "NPC_", "position": [0.0, 0.0, 0.0],
		"_runtime_cell": cell_a, "_runtime_scope": "__exterior__",
		"_runtime_origin": [0.0, 0.0, 0.0], "_runtime_stage": [0.0, 0.0, 0.0],
		"_runtime_interior": false,
	})
	streamer.add_child(actor)
	await process_frame
	actor.call("configure", "door-route-test", "route-humanoid", {
		"actor_ref": "0x00002000", "actor_cell": cell_a, "actor_scope": "__exterior__",
		"actor_interior": false, "game_hour": 12.0,
		"packages": [{"id": "0x00000005", "packageData": {"type": 6},
			"packageSchedule": {"time": 255, "duration": 0},
			"packageTarget": {"type": 0, "target": "0x00003000"}, "conditionData": []}],
		"reference_position_resolver": func(_ref: Variant) -> Variant: return null,
		"reference_cell_resolver": func(_ref: Variant) -> Variant: return cell_c,
		"reference_scope_resolver": func(_ref: Variant) -> String: return cell_c,
		"package_route_resolver": func(_source: String, _destination: String) -> Dictionary:
			return {"door": door_ab, "position": Vector3(4.0, 0.0, 2.0)},
	})
	actor.call("_resolve_authored_travel_target")
	if actor.package_route_door_ref != door_ab:
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL unstaged target did not resolve portal before final position")
		quit(1)
		return
	if not bool(streamer.call("_activate_package_door", actor, door_ab)) or fake_door.activated_actor != actor:
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL package door activation did not dispatch actor")
		quit(1)
		return
	var retail_door := load("res://scripts/fnv_door.gd").new() as AnimatableBody3D
	streamer.add_child(retail_door)
	await process_frame
	var first_door_accept := bool(retail_door.call("activate", actor))
	var second_door_accept := bool(retail_door.call("activate", actor))
	await create_timer(0.7).timeout
	retail_door.queue_free()
	await process_frame
	if not first_door_accept or second_door_accept:
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL concurrent door reservation was not exclusive")
		quit(1)
		return
	actor.package_portal_pending = true
	streamer.call("_notify_package_portal_actor", actor, false)
	if actor.package_portal_pending:
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL portal failure did not release actor reservation")
		quit(1)
		return
	streamer.active_scope = "__exterior__"
	streamer.stream_nodes_by_cell = {cell_a: [actor], cell_c: []}
	streamer.actor_nodes_by_cell = {cell_a: [actor], cell_c: []}
	streamer.actor_nodes_by_form_id = {"0x00002000": actor}
	streamer.reference_ids_by_cell = {cell_a: ["0x00002000"], cell_c: []}
	streamer.actor_visual_status_by_cell = {cell_a: {"0x00002000": "exact"}, cell_c: {}}
	streamer.resident_actors = 1
	streamer.resident_instances = 1
	fake_door.set_meta("fnv_cell", cell_b)
	if bool(streamer.call("_activate_package_door", actor, door_ab)):
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL actor activated a door from a different source cell")
		quit(1)
		return
	fake_door.set_meta("fnv_cell", cell_a)
	fake_door.set_meta("fnv_destination_cell", cell_c)
	fake_door.set_meta("fnv_destination_door", door_bc)
	fake_door.set_meta("fnv_destination_position", [10.0, 20.0, 30.0])
	fake_door.set_meta("fnv_destination_rotation", [0.0, 0.0, 0.0])
	var transition_count := [0]
	streamer.portal_transitioned.connect(func(_source: String, _destination: String) -> void:
		transition_count[0] = int(transition_count[0]) + 1)
	streamer.call("_on_door_portal_requested", fake_door, actor)
	if streamer.active_scope != "__exterior__" \
			or int(transition_count[0]) != 0 \
			or streamer.actor_nodes_by_form_id.has("0x00002000") \
			or not streamer.offscreen_actor_states.has("0x00002000") \
			or str((streamer.offscreen_actor_states["0x00002000"] as Dictionary).get("cell", "")) != cell_c:
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL NPC portal changed player scope or lost offscreen state")
		quit(1)
		return
	var invariants := streamer.call("_actor_lifecycle_invariants") as Dictionary
	var offscreen_stats := streamer.call("runtime_stats") as Dictionary
	if int(invariants.get("violations", -1)) != 0 \
			or int(offscreen_stats.get("resident_actors", -1)) != 0 \
			or int(offscreen_stats.get("actor_visual_expected", -1)) != 0:
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL lifecycle invariants=%s" % JSON.stringify(invariants))
		quit(1)
		return
	streamer.call("_set_active_cell", cell_c)
	if not streamer.pending_actor_refs.has("0x00002000") or streamer.pending_skeletal_placements.is_empty():
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL entering destination did not restore offscreen arrival")
		quit(1)
		return
	streamer.call("_drop_pending_cell_placements", cell_c)
	var player := CharacterBody3D.new()
	streamer.add_child(player)
	var token_a := int(streamer.call("_begin_player_portal_transaction", player, cell_a, cell_b))
	var token_b := int(streamer.call("_begin_player_portal_transaction", player, cell_a, cell_c))
	if bool(streamer.call("_player_portal_transaction_current", player, token_a)) \
			or not bool(streamer.call("_player_portal_transaction_current", player, token_b)) \
			or int(streamer.portal_pinned_cells.get(cell_a, 0)) != 2:
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL player portal generations/pins did not serialize")
		quit(1)
		return
	streamer.call("_finish_player_portal_transaction", player, token_a, cell_a, cell_b)
	streamer.call("_finish_player_portal_transaction", player, token_b, cell_a, cell_c)
	if not streamer.portal_pinned_cells.is_empty():
		push_error("OPENNV_PACKAGE_DOOR_ROUTE_FAIL player portal pins leaked")
		quit(1)
		return
	await process_frame
	print("OPENNV_PACKAGE_DOOR_ROUTE_PASS edges=3 locked_skipped=1 npc_scope_unchanged=1")
	streamer.queue_free()
	await process_frame
	quit(0)
