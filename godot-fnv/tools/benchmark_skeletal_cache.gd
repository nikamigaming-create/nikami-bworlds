extends SceneTree

const SOURCE := "res://generated/actors/skeletal-v2-full-20260810/chunk-0012/actor-029.onvskel"
const CACHE := "res://local/performance/skeletal-cache-probe.scn"
const ANIMATION := "res://generated/animations/authored-v1/humanoid-mtidle.onvanim"

func _init() -> void:
	var loader := load("res://scripts/opennv_skeletal_actor_loader.gd")
	var parse_started := Time.get_ticks_usec()
	var actor := loader.call("load_scene", SOURCE) as Node3D
	var parse_usec := Time.get_ticks_usec() - parse_started
	if actor == null:
		push_error("OPENNV_SKELETAL_CACHE_PROBE_FAIL source-load")
		quit(2)
		return
	var animation_started := Time.get_ticks_usec()
	var animation_loader := load("res://scripts/opennv_animation_loader.gd")
	animation_loader.call("attach_clip", actor, ANIMATION, "idle")
	var animation_usec := Time.get_ticks_usec() - animation_started
	_set_owner_recursive(actor, actor)
	var packed := PackedScene.new()
	if packed.pack(actor) != OK:
		push_error("OPENNV_SKELETAL_CACHE_PROBE_FAIL pack")
		quit(3)
		return
	var save_started := Time.get_ticks_usec()
	var save_error := ResourceSaver.save(packed, CACHE)
	var save_usec := Time.get_ticks_usec() - save_started
	actor.free()
	if save_error != OK:
		push_error("OPENNV_SKELETAL_CACHE_PROBE_FAIL save=%d" % save_error)
		quit(4)
		return
	var cold_started := Time.get_ticks_usec()
	var cached := load(CACHE) as PackedScene
	var cold_instance := cached.instantiate() if cached != null else null
	var cold_usec := Time.get_ticks_usec() - cold_started
	if cold_instance != null:
		cold_instance.free()
	var warm_started := Time.get_ticks_usec()
	var warm_instance := cached.instantiate() if cached != null else null
	var warm_usec := Time.get_ticks_usec() - warm_started
	if warm_instance != null:
		warm_instance.free()
	print("OPENNV_SKELETAL_CACHE_PROBE_PASS parse_usec=%d animation_usec=%d save_usec=%d cold_usec=%d warm_usec=%d bytes=%d" % [
		parse_usec, animation_usec, save_usec, cold_usec, warm_usec, FileAccess.get_file_as_bytes(CACHE).size()])
	quit()


func _set_owner_recursive(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_set_owner_recursive(child, root)
