extends SceneTree

func _init() -> void:
	var paths := [
		"res://generated/actors/goodsprings-strip-chunk-a/actor-028.obj",
		"res://generated/actors/goodsprings-strip-chunk-a/actor-036.obj",
	]
	for path in paths:
		var mesh := load(path) as Mesh
		print("OPENNV_MESH_AUDIT path=%s surfaces=%d" % [path, mesh.get_surface_count() if mesh != null else -1])
		if mesh == null:
			continue
		for index in range(mesh.get_surface_count()):
			var material := mesh.surface_get_material(index) as StandardMaterial3D
			var texture := ""
			if material != null and material.albedo_texture != null:
				texture = material.albedo_texture.resource_path
			print("OPENNV_MESH_SURFACE index=%d name=%s material=%s texture=%s" % [
				index, mesh.surface_get_name(index), material.resource_path if material != null else "<null>", texture])
	quit()
