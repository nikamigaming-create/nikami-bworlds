extends SceneTree


func _init() -> void:
	var streamer_script := load("res://scripts/fnv_cell_streamer.gd")
	var streamer: Node3D = streamer_script.new()
	streamer.set("runtime_placements_require_atlas", true)
	streamer.set("source_origin", Vector3.ZERO)
	streamer.set("cell_indices_by_id", {
		"0x00000abc": {
			"atlas_rotation_radians": PI * 0.5,
			"atlas_translation_units": [100.0, 200.0, 300.0],
		}
	})
	streamer.set("exterior_runtime_origins_by_cell", {"0x00000abc": Vector3.ZERO})
	var placement := {
		"position": [10.0, 20.0, 30.0],
		"rotation_radians": [0.0, 0.0, 0.0],
		"scale": 1.0,
		"_runtime_cell": "0xabc",
		"_runtime_interior": false,
		"_runtime_origin": [0.0, 0.0, 0.0],
		"_runtime_stage": [0.0, 0.0, 0.0],
	}
	var source: Vector3 = streamer.call("_source_position", placement)
	var expected_source := Vector3(80.0, 210.0, 330.0)
	if not source.is_equal_approx(expected_source):
		fail("placement source mismatch %s != %s" % [source, expected_source])
		return
	var transform: Transform3D = streamer.call("_placement_transform", placement)
	var expected_runtime := Vector3(80.0, 330.0, -210.0) / 70.0
	if not transform.origin.is_equal_approx(expected_runtime):
		fail("placement runtime mismatch %s != %s" % [transform.origin, expected_runtime])
		return
	var portal: Vector3 = streamer.call("_runtime_position_in_cell", Vector3(10.0, 20.0, 30.0), "0xabc")
	if not portal.is_equal_approx(expected_runtime):
		fail("portal destination did not share the atlas transform")
		return
	placement["form_id"] = "0x1234"
	placement["base_form_id"] = "0xe5cab"
	placement["linked_reference"] = "0x5678"
	var semantics: Dictionary = streamer.call("_actor_package_semantics", placement, "route-humanoid")
	if str(semantics.get("actor_base", "")) != "0x000e5cab":
		fail("actor package context lost the authored base FormID")
		return
	streamer.call("_index_reference_position", placement)
	var indexed: Variant = streamer.call("_runtime_reference_position", "0x1234")
	if not indexed is Vector3 or not (indexed as Vector3).is_equal_approx(expected_runtime):
		fail("authored reference position was not indexed in runtime coordinates")
		return
	if str(streamer.call("_runtime_reference_link", "0x1234")) != "0x00005678":
		fail("authored XLKR patrol link was not indexed")
		return
	streamer.call("_drop_cell_reference_positions", "0xabc")
	if streamer.call("_runtime_reference_position", "0x1234") != null:
		fail("retired cell leaked an authored reference target")
		return
	if not str(streamer.call("_runtime_reference_link", "0x1234")).is_empty():
		fail("retired cell leaked an authored patrol link")
		return
	var player_position := Vector3(4.0, 5.0, 6.0)
	streamer.call("update_focus", player_position)
	var player_target: Variant = streamer.call("_runtime_reference_position", "0x14")
	if not player_target is Vector3 or not (player_target as Vector3).is_equal_approx(player_position):
		fail("player FormID 0x14 was not available to authored Follow packages")
		return
	streamer.free()
	print("OPENNV_ATLAS_COORDINATE_PARITY_PASS")
	quit(0)


func fail(message: String) -> void:
	push_error("OPENNV_ATLAS_COORDINATE_PARITY_FAIL " + message)
	quit(1)
