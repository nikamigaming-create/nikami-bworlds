extends SceneTree

const HUMANOID := "res://generated/actors/skeletal-v2-canonical-validation-r7-20260810/actor-000.onvskel"
const VICTOR := "res://generated/actors/skeletal-v2-canonical-validation-r7-20260810/actor-001.onvskel"


func _init() -> void:
	if not _check(HUMANOID, 32, 7, 25):
		quit(1)
		return
	if not _check(VICTOR, 17, 13, 4):
		quit(1)
		return
	print("OPENNV_GODOT_SKELETAL_V2_PASS")
	quit(0)


func _check(path: String, expected_surfaces: int, expected_skinned: int, expected_static: int) -> bool:
	var loader := load("res://scripts/opennv_skeletal_actor_loader.gd")
	var actor := loader.call("load_scene", path) as Node3D
	if actor == null:
		return _fail("loader returned null path=%s" % path)
	if int(actor.get_meta("opennv_skeletal_format_version", 0)) != 2:
		return _fail("format version mismatch path=%s" % path)
	var skeleton := actor.get_node_or_null("Skeleton3D") as Skeleton3D
	if skeleton == null or skeleton.get_bone_count() < 1:
		return _fail("canonical skeleton missing path=%s" % path)
	var skinned := 0
	var static_surfaces := 0
	var attached := 0
	for node in _descendants(actor):
		if node is BoneAttachment3D:
			attached += 1
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			if mesh_node.name == "SkinnedMesh":
				skinned += 1
			elif mesh_node.name == "StaticMesh":
				static_surfaces += 1
	if int(actor.get_meta("opennv_skeletal_surface_count", 0)) != expected_surfaces \
			or skinned != expected_skinned or static_surfaces != expected_static:
		return _fail("surface census path=%s skinned=%d static=%d" % [path, skinned, static_surfaces])
	if attached != expected_static:
		return _fail("unattached static surfaces path=%s attached=%d expected=%d" % [path, attached, expected_static])
	actor.free()
	return true


func _descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child in node.get_children():
		result.append(child)
		result.append_array(_descendants(child))
	return result


func _fail(message: String) -> bool:
	push_error("OPENNV_GODOT_SKELETAL_V2_FAIL " + message)
	return false
