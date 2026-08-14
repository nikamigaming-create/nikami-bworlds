extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	var manifest := JSON.parse_string(FileAccess.get_file_as_string(
		"res://generated/actors/actor-manifest-skeletal-v8.json")) as Dictionary
	var actor_record := (manifest.get("actors", []) as Array)[0] as Dictionary
	var ref_id := "0x00002000"
	var cell_id := "0x00000100"
	streamer.actor_cache_by_ref[ref_id] = actor_record
	streamer.loaded_actor_cells[cell_id] = true
	var placement := {
		"form_id": ref_id, "base_form_id": actor_record.get("base_form", ""),
		"base_type": "NPC_", "default_enabled": true,
		"position": [0.0, 0.0, 0.0], "_runtime_cell": cell_id,
		"_runtime_scope": "__exterior__", "_runtime_origin": [0.0, 0.0, 0.0],
		"_runtime_stage": [0.0, 0.0, 0.0], "_runtime_interior": false,
		"_runtime_actor": actor_record,
	}
	streamer.call("_schedule_offscreen_actor_restore_retry", placement, "synthetic-load-failure")
	if not streamer.offscreen_actor_restore_retries.has(ref_id):
		push_error("OPENNV_ACTOR_LOAD_RETRY_FAIL retry was not scheduled")
		quit(1)
		return
	(streamer.offscreen_actor_restore_retries[ref_id] as Dictionary)["due_msec"] = 0
	streamer.call("_process_due_offscreen_actor_restore_retries")
	if streamer.offscreen_actor_restore_retries.has(ref_id) \
			or not streamer.pending_actor_refs.has(ref_id) \
			or streamer.pending_skeletal_placements.is_empty():
		push_error("OPENNV_ACTOR_LOAD_RETRY_FAIL due retry did not requeue actor")
		quit(1)
		return
	streamer.call("_drop_pending_cell_placements", cell_id)
	if streamer.pending_actor_refs.has(ref_id) or not streamer.pending_skeletal_placements.is_empty():
		push_error("OPENNV_ACTOR_LOAD_RETRY_FAIL cancellation retained pending work")
		quit(1)
		return
	print("OPENNV_ACTOR_LOAD_RETRY_PASS retries=1 pending_released=1")
	streamer.set_process(false)
	streamer.free()
	quit(0)
