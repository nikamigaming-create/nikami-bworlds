extends SceneTree


func _init() -> void:
	var streamer_script := load("res://scripts/fnv_cell_streamer.gd")
	var streamer: Node = streamer_script.new()
	var records := {
		"0x00000001": {"id": 1},
		"0x00000002": {"id": 2},
		"0x00000003": {"id": 3},
		"0x00000004": {"id": 4},
		"0x00000005": {"id": 5},
		"0x00000006": {"id": 6},
		"0x00000007": {"id": 7},
		"0x00000008": {"id": 8},
		"0x00000009": {"id": 9},
	}
	streamer.set("interior_records_by_id", records)
	streamer.set("staged_interiors", {
		"0x00000001": true,
		"0x00000002": true,
		"0x00000003": true,
		"0x00000004": true,
		"0x00000005": true,
		"0x00000006": true,
		"0x00000007": true,
		"0x00000008": true,
		"0x00000009": true,
	})
	var lru: Array[String] = [
		"0x00000001", "0x00000002", "0x00000003", "0x00000004",
		"0x00000005", "0x00000006", "0x00000007", "0x00000008",
		"0x00000009",
	]
	streamer.set("interior_lru", lru)
	streamer.set("active_scope", "0x00000001")
	streamer.set("resident_cells", 9)
	var pending_paths: Array[String] = ["mesh-a", "mesh-b"]
	var skeletal: Array[Dictionary] = [
		{"_runtime_cell": "0x00000002"},
		{"_runtime_cell": "0x00000003"},
	]
	streamer.set("pending_paths", pending_paths)
	streamer.set("waiting_placements", {
		"mesh-a": [{"_runtime_cell": "0x00000002"}],
		"mesh-b": [{"_runtime_cell": "0x00000003"}],
	})
	streamer.set("ready_placements", {
		"mesh-c": [{"_runtime_cell": "0x00000002"}],
	})
	streamer.set("pending_skeletal_placements", skeletal)
	streamer.call("_trim_interior_residency")
	var staged := streamer.get("staged_interiors") as Dictionary
	var deferred := streamer.get("deferred_interiors") as Dictionary
	if staged.size() != 8 or not staged.has("0x00000001"):
		fail("interior residency did not retain exactly eight cells including the active cell: %s" % staged)
		return
	if staged.has("0x00000002") or not deferred.has("0x00000002"):
		fail("oldest inactive interior was not returned to the deferred index")
		return
	if int(streamer.get("resident_cells")) != 8:
		fail("resident cell telemetry did not decrement")
		return
	if (streamer.get("waiting_placements") as Dictionary).has("mesh-a") \
			or (streamer.get("ready_placements") as Dictionary).has("mesh-c") \
			or (streamer.get("pending_paths") as Array).has("mesh-a") \
			or (streamer.get("pending_skeletal_placements") as Array).size() != 1:
		fail("retired interior left stale placement work queued")
		return
	print("OPENNV_INTERIOR_RESIDENCY_LRU_PASS")
	streamer.free()
	quit(0)


func fail(message: String) -> void:
	push_error("OPENNV_INTERIOR_RESIDENCY_LRU_FAIL " + message)
	quit(1)
