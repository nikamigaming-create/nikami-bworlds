extends SceneTree

const FIXTURE := "res://generated/actors/skeletal-v2-validation-v1/actor-001.onvskel"


func _init() -> void:
	var loader := load("res://scripts/opennv_skeletal_actor_loader.gd")
	var actor := loader.call("load_scene", FIXTURE) as Node3D
	if actor == null:
		fail("loader returned null")
		return
	if int(actor.get_meta("opennv_skeletal_surface_count", 0)) != 17:
		fail("expected 17 Victor assembled surfaces")
		return
	var skeleton_count := 1 if actor.get_node_or_null("Skeleton3D") is Skeleton3D else 0
	var skinned_mesh_count := 0
	var static_mesh_count := 0
	var vertex_count := 0
	for surface in actor.get_children():
		if surface is Skeleton3D:
			continue
		var visual := surface.get_node_or_null("SkinnedMesh") as MeshInstance3D
		var assembled := surface.get_node_or_null("StaticMesh") as MeshInstance3D
		if visual != null and visual.skin != null and visual.skeleton == NodePath("../../Skeleton3D"):
			skinned_mesh_count += 1
			vertex_count += visual.mesh.surface_get_array_len(0)
		elif assembled != null:
			static_mesh_count += 1
			vertex_count += assembled.mesh.surface_get_array_len(0)
		else:
			fail("Victor surface has no valid visual path")
			return
	if skeleton_count != 1 or skinned_mesh_count != 13 or static_mesh_count != 4 or vertex_count != 11114:
		fail("Victor skeletal census mismatch skeletons=%d meshes=%d static=%d vertices=%d" % [skeleton_count, skinned_mesh_count, static_mesh_count, vertex_count])
		return
	print("OPENNV_GODOT_SKELETAL_ACTOR_PASS rigged=%d static=%d vertices=%d" % [skeleton_count, static_mesh_count, vertex_count])
	actor.free()
	quit(0)


func fail(message: String) -> void:
	push_error("OPENNV_GODOT_SKELETAL_ACTOR_FAIL " + message)
	quit(1)
