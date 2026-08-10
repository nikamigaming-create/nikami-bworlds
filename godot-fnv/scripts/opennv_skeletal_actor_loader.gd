class_name OpenNVSkeletalActorLoader
extends RefCounted

const MAGIC_V1 := "ONVSKEL1"
const MAGIC_V2 := "ONVSKEL2"
const UNITS_PER_METER := 70.0
const MAX_SURFACES := 100000
const MAX_ELEMENTS := 10000000


static func load_scene(path: String) -> Node3D:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("OPENNV_SKELETAL_OPEN_FAILED path=%s" % path)
		return null
	var magic := file.get_buffer(8).get_string_from_ascii()
	if magic not in [MAGIC_V1, MAGIC_V2]:
		push_error("OPENNV_SKELETAL_BAD_MAGIC path=%s" % path)
		return null
	var version := file.get_32()
	var surface_count := file.get_32()
	if (magic == MAGIC_V1 and version != 1) or (magic == MAGIC_V2 and version != 2) or surface_count > MAX_SURFACES:
		push_error("OPENNV_SKELETAL_BAD_HEADER path=%s version=%d surfaces=%d" % [path, version, surface_count])
		return null

	var declared_bones: Array[Dictionary] = []
	if version >= 2:
		var declared_bone_count := file.get_32()
		if declared_bone_count > MAX_ELEMENTS:
			push_error("OPENNV_SKELETAL_BAD_CANONICAL_COUNT path=%s bones=%d" % [path, declared_bone_count])
			return null
		for bone_index in range(declared_bone_count):
			var bone_name := _read_string(file)
			var parent_raw := file.get_32()
			var parent := int(parent_raw) if parent_raw <= 0x7fffffff else int(parent_raw - 0x100000000)
			if bone_name.is_empty() or parent < -1 or parent >= bone_index:
				push_error("OPENNV_SKELETAL_BAD_CANONICAL_BONE path=%s bone=%d parent=%d" % [path, bone_index, parent])
				return null
			declared_bones.append({
				"name": bone_name,
				"parent": parent,
				"local": _read_matrix(file),
				"skeleton": _read_matrix(file),
			})

	var root := Node3D.new()
	root.name = "OpenNVSkeletalActor"
	var surfaces: Array[Dictionary] = []
	for surface_index in range(surface_count):
		var surface := _read_surface(file, surface_index)
		if surface.is_empty():
			root.queue_free()
			return null
		surfaces.append(surface)
	if file.get_position() != file.get_length():
		push_error("OPENNV_SKELETAL_TRAILING_BYTES path=%s bytes=%d" % [path, file.get_length() - file.get_position()])
		root.queue_free()
		return null
	var canonical := (_build_declared_canonical_skeleton(declared_bones)
		if not declared_bones.is_empty() else _build_canonical_skeleton(surfaces))
	var skeleton := canonical.get("skeleton") as Skeleton3D
	var bone_indices := canonical.get("bone_indices", {}) as Dictionary
	if skeleton != null:
		root.add_child(skeleton)
	for surface_index in range(surfaces.size()):
		var surface_node := _build_surface(surfaces[surface_index], surface_index, skeleton, bone_indices)
		if surface_node is BoneAttachment3D and skeleton != null:
			skeleton.add_child(surface_node)
		else:
			root.add_child(surface_node)
	root.set_meta("opennv_skeletal_surface_count", surface_count)
	root.set_meta("opennv_canonical_skeleton_count", 1 if skeleton != null else 0)
	root.set_meta("opennv_canonical_bone_count", skeleton.get_bone_count() if skeleton != null else 0)
	root.set_meta("opennv_skeletal_format_version", version)
	root.set_meta("opennv_skeletal_source", path)
	return root


static func _read_surface(file: FileAccess, surface_index: int) -> Dictionary:
	var name := _read_string(file)
	var root_bone := _read_string(file)
	var texture := _read_string(file)
	var vertex_count := file.get_32()
	var index_count := file.get_32()
	var bone_count := file.get_32()
	if maxi(vertex_count, maxi(index_count, bone_count)) > MAX_ELEMENTS or index_count % 3 != 0:
		push_error("OPENNV_SKELETAL_BAD_COUNTS surface=%d vertices=%d indices=%d bones=%d" % [surface_index, vertex_count, index_count, bone_count])
		return {}
	var transform := _read_matrix(file)
	var skin_to_skeleton := _read_matrix(file)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	uvs.resize(vertex_count)
	for vertex_index in range(vertex_count):
		vertices[vertex_index] = _source_position(Vector3(file.get_float(), file.get_float(), file.get_float()))
		normals[vertex_index] = _source_direction(Vector3(file.get_float(), file.get_float(), file.get_float())).normalized()
		uvs[vertex_index] = Vector2(file.get_float(), 1.0 - file.get_float())
	var indices := PackedInt32Array()
	indices.resize(index_count)
	for index in range(index_count):
		indices[index] = file.get_32()
		if indices[index] >= vertex_count:
			push_error("OPENNV_SKELETAL_BAD_INDEX surface=%d index=%d value=%d" % [surface_index, index, indices[index]])
			return {}

	var bones: Array[Dictionary] = []
	for bone_index in range(bone_count):
		var bone_name := _read_string(file)
		var parent_raw := file.get_32()
		var parent := int(parent_raw) if parent_raw <= 0x7fffffff else int(parent_raw - 0x100000000)
		if parent < -1 or parent >= bone_count or parent == bone_index:
			push_error("OPENNV_SKELETAL_BAD_PARENT surface=%d bone=%d parent=%d" % [surface_index, bone_index, parent])
			return {}
		bones.append({
			"name": bone_name,
			"parent": parent,
			"inverse_bind": _read_matrix(file),
			"local": _read_matrix(file),
			"skeleton": _read_matrix(file),
		})

	var packed_bones := PackedInt32Array()
	var packed_weights := PackedFloat32Array()
	packed_bones.resize(vertex_count * 4)
	packed_weights.resize(vertex_count * 4)
	var discarded_weight := 0.0
	for vertex_index in range(vertex_count):
		var influence_count := file.get_16()
		if influence_count > bone_count:
			push_error("OPENNV_SKELETAL_BAD_INFLUENCE_COUNT surface=%d vertex=%d count=%d" % [surface_index, vertex_index, influence_count])
			return {}
		var vertex_influences: Array[Dictionary] = []
		for _influence_index in range(influence_count):
			var influence_bone := file.get_16()
			var influence_weight := file.get_float()
			if influence_bone >= bone_count or influence_weight < 0.0:
				push_error("OPENNV_SKELETAL_BAD_INFLUENCE surface=%d vertex=%d bone=%d weight=%f" % [surface_index, vertex_index, influence_bone, influence_weight])
				return {}
			vertex_influences.append({"bone": influence_bone, "weight": influence_weight})
		vertex_influences.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.weight) > float(b.weight))
		var retained_weight := 0.0
		for influence_index in range(vertex_influences.size()):
			var influence := vertex_influences[influence_index] as Dictionary
			if influence_index < 4:
				packed_bones[vertex_index * 4 + influence_index] = int(influence.bone)
				packed_weights[vertex_index * 4 + influence_index] = float(influence.weight)
				retained_weight += float(influence.weight)
			else:
				discarded_weight += float(influence.weight)
		if retained_weight > 0.000001:
			for influence_index in range(mini(4, vertex_influences.size())):
				packed_weights[vertex_index * 4 + influence_index] /= retained_weight

	return {
		"name": name,
		"root_bone": root_bone,
		"texture": texture,
		"vertices": vertices,
		"normals": normals,
		"uvs": uvs,
		"indices": indices,
		"bones": bones,
		"packed_bones": packed_bones,
		"packed_weights": packed_weights,
		"discarded_weight": discarded_weight,
		"transform": transform,
		"skin_to_skeleton": skin_to_skeleton,
	}


static func _build_canonical_skeleton(surfaces: Array[Dictionary]) -> Dictionary:
	var records: Dictionary = {}
	var parent_candidates: Dictionary = {}
	for surface in surfaces:
		var bones := surface.bones as Array[Dictionary]
		for bone_index in range(bones.size()):
			var bone := bones[bone_index] as Dictionary
			var key := str(bone.name).to_lower()
			if key.is_empty():
				continue
			if not records.has(key):
				records[key] = bone
				parent_candidates[key] = []
			else:
				var incumbent := records[key] as Dictionary
				if not _source_transform(incumbent.skeleton as PackedFloat32Array).is_equal_approx(
						_source_transform(bone.skeleton as PackedFloat32Array)):
					push_error("OPENNV_SKELETAL_INCONSISTENT_GLOBAL bone=%s" % bone.name)
			var parent_index := int(bone.parent)
			if parent_index >= 0:
				var parent_key := str((bones[parent_index] as Dictionary).name).to_lower()
				if not parent_key.is_empty() and not (parent_candidates[key] as Array).has(parent_key):
					(parent_candidates[key] as Array).append(parent_key)
	if records.is_empty():
		return {"skeleton": null, "bone_indices": {}}
	var depth_cache: Dictionary = {}
	for key_value in records.keys():
		_graph_depth(str(key_value), parent_candidates, depth_cache, {})
	var keys := records.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		var depth_a := int(depth_cache.get(str(a), 0))
		var depth_b := int(depth_cache.get(str(b), 0))
		return depth_a < depth_b if depth_a != depth_b else str(a) < str(b))
	var chosen_parent: Dictionary = {}
	for key_value in keys:
		var key := str(key_value)
		var best := ""
		var best_depth := -1
		for candidate_value in parent_candidates.get(key, []):
			var candidate := str(candidate_value)
			var depth := int(depth_cache.get(candidate, 0))
			if depth > best_depth:
				best = candidate
				best_depth = depth
		chosen_parent[key] = best
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	var bone_indices: Dictionary = {}
	var global_rests: Dictionary = {}
	for key_value in keys:
		var key := str(key_value)
		var bone := records[key] as Dictionary
		bone_indices[key] = skeleton.get_bone_count()
		skeleton.add_bone(_safe_bone_name(str(bone.name), int(bone_indices[key])))
		global_rests[key] = _source_transform(bone.skeleton as PackedFloat32Array)
	for key_value in keys:
		var key := str(key_value)
		var bone_index := int(bone_indices[key])
		var parent_key := str(chosen_parent.get(key, ""))
		var rest := global_rests[key] as Transform3D
		if not parent_key.is_empty() and bone_indices.has(parent_key):
			skeleton.set_bone_parent(bone_index, int(bone_indices[parent_key]))
			rest = (global_rests[parent_key] as Transform3D).affine_inverse() * rest
		skeleton.set_bone_rest(bone_index, rest)
	skeleton.set_meta("opennv_source_bone_indices", bone_indices)
	return {"skeleton": skeleton, "bone_indices": bone_indices}


static func _build_declared_canonical_skeleton(bones: Array[Dictionary]) -> Dictionary:
	if bones.is_empty():
		return {"skeleton": null, "bone_indices": {}}
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	var bone_indices: Dictionary = {}
	for bone_index in range(bones.size()):
		var bone := bones[bone_index] as Dictionary
		var key := str(bone.name).to_lower()
		if bone_indices.has(key):
			push_error("OPENNV_SKELETAL_DUPLICATE_CANONICAL_BONE name=%s" % bone.name)
			return {"skeleton": null, "bone_indices": {}}
		bone_indices[key] = bone_index
		skeleton.add_bone(_safe_bone_name(str(bone.name), bone_index))
	for bone_index in range(bones.size()):
		var bone := bones[bone_index] as Dictionary
		skeleton.set_bone_parent(bone_index, int(bone.parent))
		skeleton.set_bone_rest(bone_index, _source_transform(bone.local as PackedFloat32Array))
		var declared_global := _source_transform(bone.skeleton as PackedFloat32Array)
		if not skeleton.get_bone_global_rest(bone_index).is_equal_approx(declared_global):
			push_error("OPENNV_SKELETAL_CANONICAL_RECONSTRUCTION bone=%s" % bone.name)
			return {"skeleton": null, "bone_indices": {}}
	skeleton.set_meta("opennv_source_bone_indices", bone_indices)
	return {"skeleton": skeleton, "bone_indices": bone_indices}


static func _safe_bone_name(source: String, bone_index: int) -> String:
	var result := source.replace(":", "_COLON_").replace("/", "_SLASH_")
	if result.is_empty():
		result = "OpenNVBone_%d" % bone_index
	return result


static func _graph_depth(key: String, parents: Dictionary, cache: Dictionary, visiting: Dictionary) -> int:
	if cache.has(key):
		return int(cache[key])
	if visiting.has(key):
		push_error("OPENNV_SKELETAL_PARENT_CYCLE bone=%s" % key)
		return 0
	visiting[key] = true
	var result := 0
	for parent_value in parents.get(key, []):
		result = maxi(result, 1 + _graph_depth(str(parent_value), parents, cache, visiting))
	visiting.erase(key)
	cache[key] = result
	return result


static func _build_surface(surface: Dictionary, surface_index: int, skeleton: Skeleton3D,
		bone_indices: Dictionary) -> Node3D:
	var bones := surface.bones as Array[Dictionary]
	var holder: Node3D
	if bones.is_empty() and not str(surface.root_bone).is_empty() and skeleton != null:
		var attachment := BoneAttachment3D.new()
		var attachment_index := int(bone_indices.get(str(surface.root_bone).to_lower(), -1))
		if attachment_index < 0:
			push_error("OPENNV_SKELETAL_ATTACHMENT_BONE_MISSING bone=%s" % surface.root_bone)
		else:
			attachment.bone_name = skeleton.get_bone_name(attachment_index)
		holder = attachment
		holder.set_meta("opennv_attachment_bone", surface.root_bone)
	else:
		holder = Node3D.new()
	holder.name = "Surface_%03d_%s" % [surface_index, str(surface.name).validate_node_name()]
	if bones.is_empty():
		var static_arrays := []
		static_arrays.resize(Mesh.ARRAY_MAX)
		static_arrays[Mesh.ARRAY_VERTEX] = surface.vertices
		static_arrays[Mesh.ARRAY_NORMAL] = surface.normals
		static_arrays[Mesh.ARRAY_TEX_UV] = surface.uvs
		static_arrays[Mesh.ARRAY_INDEX] = surface.indices
		var static_mesh := ArrayMesh.new()
		static_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, static_arrays)
		static_mesh.surface_set_material(0, _surface_material(surface))
		var static_visual := MeshInstance3D.new()
		static_visual.name = "StaticMesh"
		static_visual.mesh = static_mesh
		holder.add_child(static_visual)
		holder.set_meta("opennv_static_assembled_surface", true)
		holder.set_meta("opennv_texture_source", surface.texture)
		return holder
	if skeleton == null:
		push_error("OPENNV_SKELETAL_CANONICAL_MISSING surface=%d" % surface_index)
		return holder

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = surface.vertices
	arrays[Mesh.ARRAY_NORMAL] = surface.normals
	arrays[Mesh.ARRAY_TEX_UV] = surface.uvs
	arrays[Mesh.ARRAY_INDEX] = surface.indices
	arrays[Mesh.ARRAY_BONES] = surface.packed_bones
	arrays[Mesh.ARRAY_WEIGHTS] = surface.packed_weights
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _surface_material(surface))

	var skin := Skin.new()
	for bone_index in range(bones.size()):
		var bone := bones[bone_index] as Dictionary
		var canonical_index := int(bone_indices.get(str(bone.name).to_lower(), -1))
		if canonical_index < 0:
			push_error("OPENNV_SKELETAL_CANONICAL_BONE_MISSING surface=%d bone=%s" % [surface_index, bone.name])
			return holder
		skin.add_bind(canonical_index, _source_transform(bone.inverse_bind as PackedFloat32Array))
	var visual := MeshInstance3D.new()
	visual.name = "SkinnedMesh"
	visual.mesh = mesh
	visual.skin = skin
	visual.transform = _source_transform(surface.transform as PackedFloat32Array)
	holder.add_child(visual)
	# The canonical Skeleton3D is a sibling of every surface holder. Surfaces
	# are assembled before the complete actor enters the SceneTree, so get_path_to
	# has no common parent yet; the stable relative path is exact by construction.
	visual.skeleton = NodePath("../../Skeleton3D")
	holder.set_meta("opennv_root_bone", surface.root_bone)
	holder.set_meta("opennv_texture_source", surface.texture)
	holder.set_meta("opennv_discarded_weight", surface.discarded_weight)
	return holder


static func _surface_material(surface: Dictionary) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.72, 0.66, 0.55)
	var texture_source := str(surface.texture).replace("\\", "/").trim_prefix("/")
	var texture_resource := "res://generated/assets/converted/" + texture_source
	if not texture_source.is_empty() and ResourceLoader.exists(texture_resource):
		material.albedo_texture = load(texture_resource) as Texture2D
	material.roughness = 0.8
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


static func _read_string(file: FileAccess) -> String:
	var size := file.get_32()
	if size > MAX_ELEMENTS or file.get_position() + size > file.get_length():
		push_error("OPENNV_SKELETAL_BAD_STRING size=%d offset=%d" % [size, file.get_position()])
		return ""
	return file.get_buffer(size).get_string_from_utf8()


static func _read_matrix(file: FileAccess) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(16)
	for index in range(16):
		values[index] = file.get_float()
	return values


static func _source_position(value: Vector3) -> Vector3:
	return Vector3(value.x, value.z, -value.y) / UNITS_PER_METER


static func _source_direction(value: Vector3) -> Vector3:
	return Vector3(value.x, value.z, -value.y)


static func _source_transform(matrix: PackedFloat32Array) -> Transform3D:
	var basis := Basis(
		_source_direction(Vector3(matrix[0], matrix[1], matrix[2])),
		_source_direction(Vector3(matrix[8], matrix[9], matrix[10])),
		_source_direction(Vector3(-matrix[4], -matrix[5], -matrix[6]))
	)
	return Transform3D(basis, _source_position(Vector3(matrix[12], matrix[13], matrix[14])))
