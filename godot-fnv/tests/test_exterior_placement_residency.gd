extends SceneTree


func _init() -> void:
	OS.set_environment("FNV_GODOT_HEADLESS_PHYSICS", "1")
	var streamer_script := load("res://scripts/fnv_cell_streamer.gd")
	var streamer: Node = streamer_script.new()
	streamer.set("loaded_detail_cells", {"0x00000001": true})
	streamer.set("staged_interiors", {"0x00000003": true})
	var mesh := BoxMesh.new()
	streamer.call("_add_placements", mesh, [{
		"_runtime_cell": "0x00000001",
		"_runtime_interior": false,
	}])
	if int(streamer.get("resident_instances")) != 1:
		fail("loaded exterior placement was discarded")
		return
	streamer.call("_add_placements", mesh, [{
		"_runtime_cell": "0x00000002",
		"_runtime_interior": false,
	}])
	if int(streamer.get("resident_instances")) != 1:
		fail("unloaded exterior placement was retained")
		return
	streamer.call("_add_placements", mesh, [{
		"_runtime_cell": "0x00000003",
		"_runtime_interior": true,
	}])
	if int(streamer.get("resident_instances")) != 2:
		fail("staged interior placement was discarded")
		return
	streamer.set("loaded_detail_cells", {
		"0x00000001": true,
		"0x00000004": true,
	})
	streamer.set("exterior_scope_by_cell", {"0x00000004": "world:0x00000099"})
	streamer.set("primary_world_id", "0x00000010")
	streamer.set("active_exterior_world_id", "0x00000010")
	streamer.set("cell_indices_by_id", {
		"0x00000004": {"world_form_id": "0x00000099", "grid": [2, 3]},
	})
	streamer.call("_add_placements", mesh, [{
		"_runtime_cell": "0x00000004",
		"_runtime_interior": false,
		"_runtime_scope": "world:0x00000099",
	}])
	var scopes := streamer.get("visuals_by_scope") as Dictionary
	if not scopes.has("world:0x00000099"):
		fail("isolated exterior placement leaked into the primary world scope")
		return
	streamer.call("_set_active_cell", "0x00000004")
	if str(streamer.get("active_scope")) != "world:0x00000099":
		fail("isolated exterior cell did not activate its own world scope")
		return
	if str(streamer.get("active_exterior_world_id")) != "0x00000099":
		fail("isolated exterior did not select its authored worldspace")
		return
	if str(streamer.call("_canonical_form_id", null)) != "":
		fail("null optional FormID was treated as an authored reference")
		return
	if not (streamer.get("interior_lru") as Array).is_empty():
		fail("exterior worldspace was incorrectly inserted into the interior LRU")
		return
	var primary_key := str(streamer.call("_world_grid_key", "0x00000010", Vector2i(2, 3)))
	var isolated_key := str(streamer.call("_world_grid_key", "0x00000099", Vector2i(2, 3)))
	if primary_key == isolated_key:
		fail("different worldspaces alias the same exterior grid key")
		return
	streamer.call("_queue_placement", {
		"form_id": "0x00000005", "base_type": "ACTI",
		"model": "Effects\\Ambient\\FXSmokeSmall01.NIF",
	}, "0x00000004", Vector3.ZERO, Vector3.ZERO, false, "world:0x00000099")
	if int(streamer.get("special_effect_instances")) != 1:
		fail("authored particle effect was silently dropped")
		return
	streamer.call("_queue_placement", {
		"form_id": "0x00000006", "base_type": "FURN",
		"model": "Furniture\\FloorSitMarker.NIF",
	}, "0x00000004", Vector3.ZERO, Vector3.ZERO, false, "world:0x00000099")
	if int(streamer.get("authored_marker_instances")) != 1:
		fail("authored furniture marker was silently dropped")
		return
	var pending_paths := streamer.get("pending_paths") as Array
	pending_paths.clear()
	pending_paths.append_array(["far", "near", "guard"])
	streamer.set("pending_path_priorities", {"far": 9, "near": 0, "guard": 3})
	if str(streamer.call("_pop_next_pending_path")) != "near":
		fail("streaming queue did not prioritize the nearest cell")
		return
	var pending_actors := streamer.get("pending_skeletal_placements") as Array
	pending_actors.append_array([
		{"id": "far", "_runtime_stream_priority": 8},
		{"id": "near", "_runtime_stream_priority": 1},
	])
	if str((streamer.call("_pop_next_pending_skeletal_placement") as Dictionary).get("id")) != "near":
		fail("skeletal actor queue did not prioritize the nearest cell")
		return
	print("OPENNV_EXTERIOR_PLACEMENT_RESIDENCY_PASS")
	streamer.free()
	OS.set_environment("FNV_GODOT_HEADLESS_PHYSICS", "")
	quit(0)


func fail(message: String) -> void:
	OS.set_environment("FNV_GODOT_HEADLESS_PHYSICS", "")
	push_error("OPENNV_EXTERIOR_PLACEMENT_RESIDENCY_FAIL " + message)
	quit(1)
