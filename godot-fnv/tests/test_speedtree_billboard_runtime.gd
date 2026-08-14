extends SceneTree

func _init() -> void:
	var streamer_script := load("res://scripts/fnv_cell_streamer.gd")
	var streamer: Node3D = streamer_script.new()
	var mesh := streamer.call("_speedtree_billboard_mesh", "\\wastelandshrub01.spt") as Mesh
	if mesh == null or mesh.get_surface_count() != 1:
		push_error("OPENNV_SPEEDTREE_BILLBOARD_FAIL")
		streamer.free()
		quit(2)
		return
	var material := mesh.surface_get_material(0) as StandardMaterial3D
	if material == null or material.albedo_texture == null:
		push_error("OPENNV_SPEEDTREE_BILLBOARD_TEXTURE_FAIL")
		streamer.free()
		quit(3)
		return
	print("OPENNV_SPEEDTREE_BILLBOARD_PASS vertices=%d texture=%dx%d" % [
		mesh.surface_get_array_len(0), material.albedo_texture.get_width(),
		material.albedo_texture.get_height()])
	streamer.free()
	quit(0)
