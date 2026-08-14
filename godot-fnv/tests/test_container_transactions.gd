extends SceneTree

var opened_contents: Array = []

func _init() -> void:
	var container: StaticBody3D = load("res://scripts/fnv_container.gd").new()
	root.add_child(container)
	container.call("configure", [
		{"item": "0x00000001", "count": 3},
		{"item": "0x00000002", "count": 1},
		{"item": "0x00000003", "count": 0},
	])
	container.connect("opened", _on_opened)
	container.call("activate", null)
	if opened_contents.size() != 2:
		fail("activation did not expose authored nonzero contents")
		return
	var before := _total(opened_contents)
	var transferred := container.call("take_all") as Array
	if _total(transferred) != before or not (container.get("contents") as Array).is_empty():
		fail("take-all did not conserve item counts")
		return
	if not (container.call("take_all") as Array).is_empty():
		fail("empty container duplicated items")
		return
	container.queue_free()
	var streamer: Node3D = load("res://scripts/fnv_cell_streamer.gd").new()
	root.add_child(streamer)
	streamer.call("_add_placement", BoxMesh.new(), {
		"form_id": "0x10", "base_form_id": "0x20", "base_type": "CONT",
		"base_editor_id": "TestContainer", "inventory": [{"item": "0x30", "count": 2}],
		"position": [0.0, 0.0, 0.0], "rotation_radians": [0.0, 0.0, 0.0], "scale": 1.0,
		"_runtime_cell": "0x40", "_runtime_interior": false, "_runtime_scope": "__exterior__",
	})
	var streamed := streamer.get_node_or_null("TestContainer_0x10")
	if streamed == null or not streamed.has_method("activate") or (streamed.get("contents") as Array).size() != 1:
		fail("streamed CONT placement did not become an interactive container")
		return
	streamer.queue_free()
	print("OPENNV_CONTAINER_TRANSACTIONS_PASS items=%d count=%d" % [transferred.size(), before])
	quit(0)


func _on_opened(_container: Node, _actor: Node, contents: Array) -> void:
	opened_contents = contents


func _total(entries: Array) -> int:
	var result := 0
	for entry_value in entries:
		result += int((entry_value as Dictionary).get("count", 0))
	return result


func fail(message: String) -> void:
	push_error("OPENNV_CONTAINER_TRANSACTIONS_FAIL " + message)
	quit(1)
