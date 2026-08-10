extends SceneTree

const FIXTURE := "res://generated/actors/skeletal-v2-validation-v1/actor-000.onvskel"


func _init() -> void:
	var loader := load("res://scripts/opennv_skeletal_actor_loader.gd")
	var actor := loader.call("load_scene", FIXTURE) as Node3D
	if actor == null:
		fail("loader returned null")
		return
	var rigged := 0
	var static_surfaces := 0
	var vertices := 0
	var skeleton_count := 1 if actor.get_node_or_null("Skeleton3D") is Skeleton3D else 0
	for surface in actor.get_children():
		if surface is Skeleton3D:
			continue
		var skinned := surface.get_node_or_null("SkinnedMesh") as MeshInstance3D
		var assembled := surface.get_node_or_null("StaticMesh") as MeshInstance3D
		if skinned != null:
			rigged += 1
			vertices += skinned.mesh.surface_get_array_len(0)
		elif assembled != null:
			static_surfaces += 1
			vertices += assembled.mesh.surface_get_array_len(0)
		else:
			fail("surface has neither a skinned nor assembled-static mesh")
			return
	if skeleton_count != 1 or rigged != 7 or static_surfaces != 25 or vertices != 9762:
		fail("mixed actor census mismatch rigged=%d static=%d vertices=%d" % [rigged, static_surfaces, vertices])
		return
	print("OPENNV_GODOT_MIXED_ACTOR_PASS rigged=%d static=%d vertices=%d" % [rigged, static_surfaces, vertices])
	actor.free()
	quit(0)


func fail(message: String) -> void:
	push_error("OPENNV_GODOT_MIXED_ACTOR_FAIL " + message)
	quit(1)
