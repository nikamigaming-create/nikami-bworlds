extends SceneTree


func _initialize() -> void:
	var streamer := load("res://scripts/fnv_cell_streamer.gd").new() as Node3D
	root.add_child(streamer)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(12.0, 0.2, 12.0)
	floor_shape.shape = floor_box
	floor_body.position.y = -0.1
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	await physics_frame
	await physics_frame
	var candidate := Vector3.ZERO
	var no_exclusions: Array[RID] = []
	if not bool(streamer.call("_landing_has_floor", candidate, no_exclusions)) \
			or not bool(streamer.call("_landing_capsule_is_clear", candidate, no_exclusions)):
		_fail("clear floor-supported capsule was rejected")
		return
	var blocker := StaticBody3D.new()
	var blocker_shape := CollisionShape3D.new()
	var blocker_box := BoxShape3D.new()
	blocker_box.size = Vector3(1.0, 1.8, 1.0)
	blocker_shape.shape = blocker_box
	blocker.position = Vector3(0.0, 0.9, 0.0)
	blocker.add_child(blocker_shape)
	root.add_child(blocker)
	await physics_frame
	await physics_frame
	if bool(streamer.call("_landing_capsule_is_clear", candidate, no_exclusions)):
		_fail("wall-embedded capsule was accepted")
		return
	var excluded: Array[RID] = [blocker.get_rid()]
	if not bool(streamer.call("_landing_capsule_is_clear", candidate, excluded)):
		_fail("door/actor collision exclusion was ignored")
		return
	var remote_door := StaticBody3D.new()
	remote_door.position = Vector3(100.0, 100.0, 100.0)
	root.add_child(remote_door)
	await physics_frame
	if streamer.call("_safe_door_landing", remote_door, Vector3.FORWARD, null) is Vector3:
		_fail("floorless destination returned a guessed landing")
		return
	print("OPENNV_DOOR_LANDING_RUNTIME_PASS floor=1 clear=1 blocked=1 exclusion=1 abort=1")
	quit(0)


func _fail(reason: String) -> void:
	push_error("OPENNV_DOOR_LANDING_RUNTIME_FAIL %s" % reason)
	quit(1)
