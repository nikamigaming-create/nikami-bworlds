extends Node

const DEFAULT_MANIFEST := "res://generated/bootstrap.json"
const RESOLVED_DATABASE_MANIFEST := "res://generated/resolved-db/manifest.json"
const SEMANTIC_DATABASE_MANIFEST := "res://generated/semantic-db/manifest.json"
const SEMANTIC_DATABASE_AUDIT := "res://generated/semantic-db/audit.json"
const ACTOR_BLUEPRINTS := "res://generated/semantic-db/actor-blueprints.json"
const ACTOR_BLUEPRINT_MANIFEST := "res://generated/semantic-db/actor-blueprints.manifest.json"
const SAVE_OVERLAY_INDEX := "res://generated/save330-overlay/index.json"
const SAVE_OVERLAY_PAYLOADS := "res://generated/save330-overlay/changeform-payloads.bin"
const AUTHORED_ROAD_ROUTE := "res://generated/world/goodsprings-authored-road-route.json"
const FREESIDE_NORTH_ROAD_ROUTE := "res://generated/world/freeside-north-authored-road-route.json"
const FREESIDE_ROAD_ROUTE := "res://generated/world/freeside-authored-road-route.json"
const STRIP_ROAD_ROUTE := "res://generated/world/strip-authored-road-route.json"
const SHOWCASE_ROUTE_RAIL_SPEED := 80.0
const SHOWCASE_CAPTURE_TIME_SCALE := 4.0
const CINEMATIC_SCENE_PACK := "res://generated/cinematics/scene-pack.json"
const CINEMATIC_SCENE_SECONDS := 15.0
const PHOSPHOR := Color(0.69, 0.84, 0.47)
const DARK_GREEN := Color(0.035, 0.075, 0.038)
const USER_SETTINGS_PATH := "user://open_nv_settings.json"
const AMBIENT_BED := "res://generated/assets/converted/sound/fx/amb/amb_desertdefault/beds/amb_desertdaybed_lp.ogg"
const AMBIENT_ONESHOTS := [
	"res://generated/assets/converted/sound/fx/amb/amb_desertdefault/wind/mellow/amb_windgust_mellow_01.ogg",
	"res://generated/assets/converted/sound/fx/amb/amb_desertdefault/birds/a/sfx_desert_bird-a_os_01.ogg",
]
const WASTELAND_SKY_SHADER := """
shader_type sky;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float cloud_noise(vec2 p) {
	float value = 0.0;
	float amplitude = 0.55;
	for (int octave = 0; octave < 5; octave++) {
		value += value_noise(p) * amplitude;
		p = p * 2.03 + vec2(17.1, 9.2);
		amplitude *= 0.5;
	}
	return value;
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	float height = max(direction.y, 0.0);
	vec3 horizon = vec3(0.72, 0.52, 0.31);
	vec3 zenith = vec3(0.055, 0.16, 0.32);
	vec3 color = mix(horizon, zenith, pow(height, 0.42));
	if (direction.y < 0.0) {
		color = mix(horizon, vec3(0.20, 0.14, 0.09), min(-direction.y * 2.0, 1.0));
	} else {
		vec2 cloud_uv = direction.xz / max(direction.y + 0.24, 0.24) * 3.25;
		cloud_uv += vec2(TIME * 0.0032, TIME * 0.0013);
		vec2 warp = vec2(value_noise(cloud_uv * 0.31), value_noise(cloud_uv * 0.31 + 31.7));
		float density = cloud_noise(cloud_uv + (warp - 0.5) * 2.2);
		float cloud = smoothstep(0.49, 0.78, density);
		float altitude_band = smoothstep(0.015, 0.12, direction.y) * (1.0 - smoothstep(0.70, 0.97, direction.y));
		vec3 cloud_color = mix(vec3(0.58, 0.49, 0.40), vec3(0.93, 0.88, 0.76), height);
		color = mix(color, cloud_color, cloud * altitude_band * 0.52);
	}
	COLOR = color;
}
"""

var manifest: Dictionary = {}
var active_manifest_path := DEFAULT_MANIFEST
var ui: CanvasLayer
var menu_root: Control
var world_root: Node3D
var pip_boy: Control
var player: CharacterBody3D
var last_safe_player_position := Vector3.ZERO
var has_safe_player_position := false
var camera: Camera3D
var mouse_look := false
var authored_resident := false
var continue_requested := false
var world_playable := false
var active_video: VideoStreamPlayer
var hud_root: Control
var user_settings: Dictionary = {"play_opening_movie": false}
var xr_interface: XRInterface
var xr_origin: XROrigin3D
var xr_active := false
var left_controller: XRController3D
var right_controller: XRController3D
var xr_trigger_was_pressed := false
var ambient_one_shot: AudioStreamPlayer3D
var ambient_clock := 0.0
var cell_streamer: Node3D
var world_environment: Environment
var world_sun: DirectionalLight3D
var showcase_active := false
var showcase_complete := false
var showcase_long_route := false
var showcase_route_gate_index := 0
var showcase_route_waypoints: Array[Vector3] = []
var showcase_route_waypoint_index := 0
var showcase_route_stuck_clock := 0.0
var showcase_route_progress_clock := 0.0
var cinematic_active := false
var cinematic_complete := false
var cinematic_scenes: Array = []
var cinematic_scene_index := -1
var cinematic_started_msec := 0
var cinematic_elapsed := 0.0
var cinematic_start_frame := 0
var cinematic_scene_seconds := CINEMATIC_SCENE_SECONDS
var cinematic_portraits := false
var cinematic_portrait_reverse_captured := false
var cinematic_vault_door_activated := false
var cinematic_vault_entered := false
var cinematic_interior_origin := Vector3.ZERO
var cinematic_label: Label
var showcase_route_best_distance := INF
var showcase_route_progress_index := -1
var showcase_phase := ""
var showcase_phase_clock := 0.0
var showcase_entry_door: Node3D
var showcase_interior_door: Node3D
var showcase_target := Vector3.ZERO
var showcase_phases: Array[String] = []

func _ready() -> void:
	DisplayServer.window_set_title("OpenNV")
	_load_user_settings()
	manifest = _read_manifest()
	if manifest.is_empty():
		push_error("OPENNV_GODOT_BOOT manifest missing or invalid")
		get_tree().quit(2)
		return
	if not _validate_resolved_database():
		push_error("OPENNV_GODOT_BOOT resolved database missing, stale, or incompatible")
		get_tree().quit(4)
		return
	if not _validate_semantic_database():
		push_error("OPENNV_GODOT_BOOT semantic database missing, stale, or invalid")
		get_tree().quit(5)
		return
	if not _validate_actor_blueprints():
		push_error("OPENNV_GODOT_BOOT actor blueprints missing, stale, or incomplete")
		get_tree().quit(6)
		return
	if not _validate_save_overlay():
		push_error("OPENNV_GODOT_BOOT save overlay missing, stale, or invalid")
		get_tree().quit(7)
		return
	print("OPENNV_GODOT_SAVE_READY save=%s hash=%s location=%s" % [
		str(manifest.get("save", {}).get("path", "")),
		str(manifest.get("save", {}).get("sha256", "")),
		str(manifest.get("player", {}).get("location", "unknown"))])
	if OS.get_environment("FNV_GODOT_SMOKE") == "1":
		print("OPENNV_GODOT_SMOKE_PASS schema=%s masters=%d inventory=%d" % [
			str(manifest.get("schema", "")),
			manifest.get("load_order", []).size(),
			manifest.get("inventory", []).size()])
		get_tree().quit()
		return
	_initialize_openxr()
	ui = CanvasLayer.new()
	ui.name = "Interface"
	add_child(ui)
	# The movie and menu are useful presentation time: assemble the save-centered
	# world behind them so Continue never opens a dedicated loading screen.
	_build_world()
	_show_intro_or_menu()

func _initialize_openxr() -> void:
	if OS.get_environment("FNV_GODOT_OPENXR") != "1":
		return
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface == null:
		push_warning("OPENNV_OPENXR_UNAVAILABLE fallback=desktop")
		return
	if not xr_interface.is_initialized() and not xr_interface.initialize():
		push_warning("OPENNV_OPENXR_UNAVAILABLE fallback=desktop")
		return
	xr_active = true
	get_viewport().use_xr = true
	Engine.physics_ticks_per_second = 90
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	print("OPENNV_OPENXR_READY runtime=%s" % xr_interface.get_name())

func _read_manifest() -> Dictionary:
	var requested := OS.get_environment("FNV_GODOT_MANIFEST")
	active_manifest_path = requested if not requested.is_empty() else DEFAULT_MANIFEST
	if not FileAccess.file_exists(active_manifest_path):
		return {}
	var file := FileAccess.open(active_manifest_path, FileAccess.READ)
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _validate_resolved_database() -> bool:
	if not FileAccess.file_exists(RESOLVED_DATABASE_MANIFEST):
		return false
	var file := FileAccess.open(RESOLVED_DATABASE_MANIFEST, FileAccess.READ)
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return false
	var database := parsed as Dictionary
	if str(database.get("schema", "")) != "opennv-resolved-record-database/v1":
		return false
	if str(database.get("bootstrap_sha256", "")) != FileAccess.get_sha256(active_manifest_path):
		push_error("OPENNV_RESOLVED_DATABASE_STALE bootstrap hash mismatch")
		return false
	var plugins := database.get("plugins", []) as Array
	var requested_load_order := manifest.get("load_order", []) as Array
	if plugins.size() != requested_load_order.size():
		return false
	for index in range(plugins.size()):
		if str((plugins[index] as Dictionary).get("name", "")) != str(requested_load_order[index]):
			return false
	var counts := database.get("counts", {}) as Dictionary
	print("OPENNV_RESOLVED_DATABASE_READY plugins=%d winning=%d live=%d load_order_sha256=%s" % [
		plugins.size(), int(counts.get("winning", 0)), int(counts.get("live", 0)),
		str(database.get("load_order_sha256", ""))])
	return true


func _validate_semantic_database() -> bool:
	if not FileAccess.file_exists(SEMANTIC_DATABASE_MANIFEST) or not FileAccess.file_exists(SEMANTIC_DATABASE_AUDIT):
		return false
	var manifest_file := FileAccess.open(SEMANTIC_DATABASE_MANIFEST, FileAccess.READ)
	var audit_file := FileAccess.open(SEMANTIC_DATABASE_AUDIT, FileAccess.READ)
	var manifest_value = JSON.parse_string(manifest_file.get_as_text())
	var audit_value = JSON.parse_string(audit_file.get_as_text())
	if not manifest_value is Dictionary or not audit_value is Dictionary:
		return false
	var database := manifest_value as Dictionary
	var audit := audit_value as Dictionary
	if str(database.get("schema", "")) != "opennv-semantic-database/v1":
		return false
	if str(audit.get("schema", "")) != "opennv-semantic-database-audit/v1" or str(audit.get("status", "")) != "pass":
		return false
	if str(database.get("bootstrap_sha256", "")) != FileAccess.get_sha256(active_manifest_path):
		return false
	if str(database.get("resolved_manifest_sha256", "")) != FileAccess.get_sha256(RESOLVED_DATABASE_MANIFEST):
		return false
	if str(audit.get("semantic_manifest_sha256", "")) != FileAccess.get_sha256(SEMANTIC_DATABASE_MANIFEST):
		return false
	if str(audit.get("resolved_manifest_sha256", "")) != FileAccess.get_sha256(RESOLVED_DATABASE_MANIFEST):
		return false
	var counts := database.get("counts", {}) as Dictionary
	print("OPENNV_SEMANTIC_DATABASE_READY records=%d cells=%d placements=%d actors=%d" % [
		int(counts.get("live_records", 0)), int(counts.get("cells", 0)),
		int(counts.get("placements", 0)), int(counts.get("actor_placements", 0))])
	return true


func _validate_actor_blueprints() -> bool:
	if not FileAccess.file_exists(ACTOR_BLUEPRINTS) or not FileAccess.file_exists(ACTOR_BLUEPRINT_MANIFEST):
		return false
	var file := FileAccess.open(ACTOR_BLUEPRINT_MANIFEST, FileAccess.READ)
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return false
	var actor_manifest := parsed as Dictionary
	if str(actor_manifest.get("schema", "")) != "opennv-actor-blueprint-manifest/v1":
		return false
	if str(actor_manifest.get("status", "")) != "pass":
		return false
	if str(actor_manifest.get("blueprints_sha256", "")) != FileAccess.get_sha256(ACTOR_BLUEPRINTS):
		return false
	if str(actor_manifest.get("semantic_manifest_sha256", "")) != FileAccess.get_sha256(SEMANTIC_DATABASE_MANIFEST):
		return false
	var counts := actor_manifest.get("counts", {}) as Dictionary
	for failure_key in ["missing_template_targets", "missing_list_targets", "template_cycles", "list_cycles", "missing_placement_bases"]:
		if int(counts.get(failure_key, -1)) != 0:
			return false
	print("OPENNV_ACTOR_BLUEPRINTS_READY blueprints=%d population=%d lists=%d" % [
		int(counts.get("blueprints", 0)), int(counts.get("population_references", 0)),
		int(counts.get("levelled_lists", 0))])
	return true


func _validate_save_overlay() -> bool:
	if not FileAccess.file_exists(SAVE_OVERLAY_INDEX) or not FileAccess.file_exists(SAVE_OVERLAY_PAYLOADS):
		return false
	var file := FileAccess.open(SAVE_OVERLAY_INDEX, FileAccess.READ)
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return false
	var overlay := parsed as Dictionary
	if str(overlay.get("schema", "")) != "opennv-fos-changeform-index/v1":
		return false
	if str(overlay.get("status", "")) != "indexed-opaque":
		return false
	var source := overlay.get("source", {}) as Dictionary
	var save := manifest.get("save", {}) as Dictionary
	if str(source.get("sha256", "")) != str(save.get("sha256", "")):
		return false
	if int(source.get("bytes", -1)) != int(save.get("bytes", -2)):
		return false
	var counts := overlay.get("counts", {}) as Dictionary
	var integrity := overlay.get("integrity", {}) as Dictionary
	var payload_artifact := integrity.get("payloadArtifact", {}) as Dictionary
	if int(counts.get("changeForms", -1)) != int(integrity.get("declaredChangeForms", -2)):
		return false
	if int(integrity.get("tableEnd", -1)) != int(integrity.get("expectedTableEnd", -2)):
		return false
	if int(payload_artifact.get("bytes", -1)) != int(counts.get("payloadBytes", -2)):
		return false
	if str(payload_artifact.get("sha256", "")) != FileAccess.get_sha256(SAVE_OVERLAY_PAYLOADS):
		return false
	var join := counts.get("semanticPlacementJoin", {}) as Dictionary
	print("OPENNV_SAVE_OVERLAY_READY changeforms=%d actors=%d creatures=%d references=%d matched=%d opaque_bytes=%d" % [
		int(counts.get("changeForms", 0)), int((counts.get("byType", {}) as Dictionary).get("ACHR", 0)),
		int((counts.get("byType", {}) as Dictionary).get("ACRE", 0)),
		int((counts.get("byType", {}) as Dictionary).get("REFR", 0)), int(join.get("matched", 0)),
		int(counts.get("payloadBytes", 0))])
	return true

func _show_intro_or_menu() -> void:
	_show_main_menu()

func _skip_active_video() -> void:
	if active_video == null:
		return
	active_video.stop()
	_finish_active_video(active_video)

func _finish_active_video(video: VideoStreamPlayer) -> void:
	if active_video == video:
		active_video = null
	if is_instance_valid(video):
		video.queue_free()
	_show_main_menu()

func _show_main_menu() -> void:
	if menu_root != null:
		menu_root.queue_free()
	menu_root = Control.new()
	menu_root.name = "MainMenu"
	menu_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.add_child(menu_root)

	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.018, 0.027, 0.017)
	menu_root.add_child(background)

	var title := Label.new()
	title.text = "OPENNV"
	title.position = Vector2(90, 72)
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color(0.83, 0.77, 0.56))
	menu_root.add_child(title)

	var rule := ColorRect.new()
	rule.position = Vector2(91, 213)
	rule.size = Vector2(380, 2)
	rule.color = Color(0.58, 0.51, 0.32)
	menu_root.add_child(rule)

	var buttons := VBoxContainer.new()
	buttons.position = Vector2(92, 252)
	buttons.size = Vector2(340, 330)
	buttons.add_theme_constant_override("separation", 10)
	menu_root.add_child(buttons)
	_add_menu_button(buttons, "RESUME" if continue_requested and authored_resident else "CONTINUE", _continue_save)
	_add_menu_button(buttons, "LOAD", _show_load_summary)
	_add_menu_button(buttons, "NEW", _continue_save)
	_add_menu_button(buttons, "SETTINGS", _show_settings_summary)
	_add_menu_button(buttons, "CREDITS", _show_credits)
	_add_menu_button(buttons, "EXIT", func(): get_tree().quit())

	var save := manifest.get("player", {}) as Dictionary
	var status := Label.new()
	status.text = "SAVE %s  •  %s  •  LEVEL %s\n%s" % [
		str(save.get("save_number", "?")), str(save.get("location", "UNKNOWN")),
		str(save.get("level", "?")), str(save.get("play_time", ""))]
	status.position = Vector2(92, 620)
	status.add_theme_color_override("font_color", Color(0.56, 0.60, 0.45))
	menu_root.add_child(status)
	print("OPENNV_GODOT_MENU_READY mode=save-backed")
	if OS.get_environment("FNV_GODOT_AUTOCONTINUE") == "1":
		call_deferred("_continue_save")

func _add_menu_button(parent: Control, label: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(320, 42)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_font_size_override("font_size", 24)
	button.add_theme_color_override("font_color", Color(0.72, 0.68, 0.50))
	button.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.72))
	button.pressed.connect(callback)
	parent.add_child(button)
	if parent.get_child_count() == 1:
		button.call_deferred("grab_focus")

func _continue_save() -> void:
	continue_requested = true
	if authored_resident:
		_enter_world()
	else:
		print("OPENNV_GODOT_CONTINUE_QUEUED residency=background")

func _show_load_summary() -> void:
	_show_modal("LOAD GAME", "Save %s\n%s\n%s" % [
		str(manifest.get("player", {}).get("save_number", "?")),
		str(manifest.get("player", {}).get("location", "Unknown")),
		str(manifest.get("save", {}).get("path", ""))])

func _show_settings_summary() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "SETTINGS"
	dialog.min_size = Vector2i(680, 320)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	dialog.add_child(body)
	var summary := Label.new()
	summary.text = "Renderer: %s\nWorld FOV: %s\nKeyboard, mouse, and controller navigation" % [
		RenderingServer.get_current_rendering_method(), str(manifest.get("camera", {}).get("world_fov", 75))]
	body.add_child(summary)
	menu_root.add_child(dialog)
	dialog.popup_centered()

func _show_credits() -> void:
	_show_modal("OPENNV", "OpenNV runs your legally owned game assets.\nNothing else is required.")

func _show_modal(title_text: String, body_text: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = title_text
	dialog.dialog_text = body_text
	dialog.min_size = Vector2i(650, 240)
	menu_root.add_child(dialog)
	dialog.popup_centered()

func _load_user_settings() -> void:
	if not FileAccess.file_exists(USER_SETTINGS_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(USER_SETTINGS_PATH))
	if parsed is Dictionary:
		user_settings.merge(parsed, true)

func _save_user_settings() -> void:
	var file := FileAccess.open(USER_SETTINGS_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(user_settings, "  "))

func _build_world() -> void:
	if world_root != null:
		return
	world_root = Node3D.new()
	world_root.name = "OpenNVWorld"
	add_child(world_root)

	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	world_environment = environment
	var sky_shader := Shader.new()
	sky_shader.code = WASTELAND_SKY_SHADER
	var sky_material := ShaderMaterial.new()
	sky_material.shader = sky_shader
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_color = Color(0.72, 0.66, 0.54)
	environment.ambient_light_energy = 0.48
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 0.72
	# Keep the exterior air clear in VR.  The old dense amber height fog read as
	# a yellow veil across the entire headset view and hid the authored world.
	environment.fog_enabled = false
	environment_node.environment = environment
	world_root.add_child(environment_node)

	world_sun = DirectionalLight3D.new()
	world_sun.rotation_degrees = Vector3(-48, -28, 0)
	world_sun.light_color = Color(1.0, 0.83, 0.59)
	world_sun.light_energy = 1.05
	world_sun.shadow_enabled = true
	world_root.add_child(world_sun)

	var streamer_script := load("res://scripts/fnv_cell_streamer.gd")
	cell_streamer = streamer_script.new()
	cell_streamer.name = "AuthoredCellStreamer"
	world_root.add_child(cell_streamer)
	cell_streamer.connect("residency_ready", _on_initial_cells_resident)
	cell_streamer.connect("portal_transitioned", _on_portal_transitioned)
	cell_streamer.call("begin", manifest)

	# Keep the emergency floor out of authored builds: it otherwise masks the
	# actual LAND surface at the center of Goodsprings.
	if not FileAccess.file_exists("res://generated/world/cell-ring.json"):
		var ground := StaticBody3D.new()
		ground.name = "BootstrapGround"
		if DisplayServer.get_name() != "headless":
			var ground_mesh := MeshInstance3D.new()
			var plane := PlaneMesh.new()
			plane.size = Vector2(240, 240)
			ground_mesh.mesh = plane
			var material := StandardMaterial3D.new()
			material.albedo_color = Color(0.31, 0.27, 0.18)
			material.roughness = 1.0
			ground_mesh.material_override = material
			ground.add_child(ground_mesh)
		var collider := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(240, 0.25, 240)
		collider.shape = box
		collider.position.y = -0.14
		ground.add_child(collider)
		world_root.add_child(ground)

	player = CharacterBody3D.new()
	player.name = "Player"
	player.position = Vector3(0, 1.0, 0)
	player.floor_snap_length = 0.45
	player.floor_max_angle = deg_to_rad(52.0)
	player.safe_margin = 0.04
	last_safe_player_position = player.position
	has_safe_player_position = true
	var player_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.34
	capsule.height = 1.8
	player_shape.shape = capsule
	player_shape.position.y = 0.9
	player.add_child(player_shape)
	if xr_active:
		xr_origin = XROrigin3D.new()
		xr_origin.name = "TrackedOrigin"
		player.add_child(xr_origin)
		camera = XRCamera3D.new()
		camera.name = "Head"
		xr_origin.add_child(camera)
		for hand in ["left_hand", "right_hand"]:
			var controller := XRController3D.new()
			controller.name = hand.capitalize() + "Controller"
			controller.tracker = hand
			xr_origin.add_child(controller)
			if hand == "left_hand":
				left_controller = controller
			else:
				right_controller = controller
	else:
		camera = Camera3D.new()
		camera.position = Vector3(0, 1.62, 0)
		camera.fov = float(manifest.get("camera", {}).get("world_fov", 75.0))
		player.add_child(camera)
	world_root.add_child(player)
	_build_ambient_audio()

	if DisplayServer.get_name() != "headless":
		_build_hud()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	mouse_look = false
	print("OPENNV_GODOT_WORLD_READY worldspace=%s source_position=%s save_hash=%s" % [
		str(manifest.get("world", {}).get("form_id", "")),
		str(manifest.get("world", {}).get("source_position", [])),
		str(manifest.get("save", {}).get("sha256", ""))])

func _build_ambient_audio() -> void:
	if DisplayServer.get_name() == "headless" or OS.get_environment("FNV_GODOT_DISABLE_AUDIO") == "1":
		return
	if ResourceLoader.exists(AMBIENT_BED):
		var bed := AudioStreamPlayer.new()
		bed.name = "AuthoredDesertAmbience"
		var stream := load(AMBIENT_BED)
		if stream is AudioStreamOggVorbis:
			stream = stream.duplicate()
			stream.loop = true
		bed.stream = stream
		bed.volume_db = -8.0
		world_root.add_child(bed)
		bed.play()
	ambient_one_shot = AudioStreamPlayer3D.new()
	ambient_one_shot.name = "AuthoredAmbientOneShot"
	ambient_one_shot.unit_size = 8.0
	ambient_one_shot.max_distance = 55.0
	world_root.add_child(ambient_one_shot)
	ambient_clock = randf_range(4.0, 9.0)

func _on_initial_cells_resident(cell_count: int, terrain_count: int, instance_count: int) -> void:
	authored_resident = terrain_count > 0 and instance_count > 0
	print("OPENNV_GODOT_RESIDENCY_GATE_OPEN cells=%d terrain=%d instances=%d" % [cell_count, terrain_count, instance_count])
	if OS.get_environment("FNV_GODOT_WORLD_SMOKE") == "1":
		print("OPENNV_GODOT_AUTHORED_WORLD_SMOKE_PASS cells=%d terrain=%d instances=%d" % [cell_count, terrain_count, instance_count])
		get_tree().quit(0 if instance_count > 0 and terrain_count > 0 else 3)
	elif continue_requested and authored_resident:
		_enter_world()
	var capture_path := OS.get_environment("FNV_GODOT_CAPTURE_PATH")
	if authored_resident and not capture_path.is_empty():
		call_deferred("_capture_native_frame", capture_path)

func _enter_world() -> void:
	if menu_root != null:
		menu_root.queue_free()
		menu_root = null
	world_playable = true
	if hud_root != null:
		hud_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	mouse_look = true
	print("OPENNV_GODOT_SEAMLESS_CONTINUE state=resident-no-loading-screen")
	if OS.get_environment("FNV_GODOT_CINEMATIC_REEL") == "1" and not cinematic_active and not cinematic_complete:
		call_deferred("_begin_cinematic_reel")
	elif OS.get_environment("FNV_GODOT_SELF_DRIVE") == "1" and not showcase_active and not showcase_complete:
		call_deferred("_begin_showcase_route")

func _on_portal_transitioned(_source_cell: String, destination_cell: String) -> void:
	if world_environment == null or cell_streamer == null:
		return
	var inside := bool(cell_streamer.call("is_interior_cell", destination_cell))
	if player != null and is_instance_valid(player):
		last_safe_player_position = player.global_position
		has_safe_player_position = true
	# Exterior fog is intentionally never restored here. The previous toggle
	# re-enabled the obsolete dense amber fog after the first return trip.
	world_environment.fog_enabled = false
	if inside:
		# Isolated interior cells are not watertight presentation shells. A dark,
		# neutral void prevents the exterior sky/horizon from shining through tiny
		# authored gaps while retaining ambient visibility in the room.
		world_environment.background_mode = Environment.BG_COLOR
		world_environment.background_color = Color(0.006, 0.008, 0.010)
		world_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		world_environment.ambient_light_color = Color(0.42, 0.39, 0.34)
		world_environment.ambient_light_energy = 0.55
	else:
		world_environment.background_mode = Environment.BG_SKY
		world_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		world_environment.ambient_light_color = Color(0.72, 0.66, 0.54)
		world_environment.ambient_light_energy = 0.48
	if world_sun != null:
		world_sun.visible = not inside
	print("OPENNV_ENVIRONMENT_MODE interior=%s cell=%s" % [inside, destination_cell])
	if cinematic_active and inside:
		cinematic_vault_entered = true
		cinematic_interior_origin = player.global_position
		return
	if showcase_active and showcase_phase == "route_gate_opening":
		_continue_long_route_after_gate()
		return
	if showcase_active:
		_capture_showcase_checkpoint("03-interior" if inside else "05-returned-exterior")
		if inside and showcase_phase == "entry_opening":
			var destination_id := str(showcase_entry_door.get_meta("fnv_destination_door", ""))
			showcase_interior_door = cell_streamer.call("door_by_form_id", destination_id) as Node3D
			var center: Vector3 = cell_streamer.call("interior_center", destination_cell)
			var inward := center - player.global_position
			inward.y = 0.0
			if inward.length_squared() < 0.1:
				inward = -showcase_interior_door.global_basis.z
			showcase_target = player.global_position + inward.normalized() * 4.5
			_set_showcase_phase("interior_walk")
		elif not inside and showcase_phase == "exit_opening":
			# Return to the first decoded Goodsprings road placement.  A guessed
			# forward vector from this converted door runs along its porch hull.
			showcase_target = _atlas_position_to_world(Vector3(-72236.59375, -1339.0230712890625, 8121.35009765625))
			_set_showcase_phase("exterior_walkaway")


func _begin_showcase_route() -> void:
	if OS.get_environment("FNV_GODOT_LONG_ROUTE") == "1":
		cell_streamer.call("preload_route_corridor")
		await cell_streamer.route_corridor_ready
	var gate_path := OS.get_environment("FNV_GODOT_CAPTURE_GATE_FILE")
	if OS.get_environment("FNV_GODOT_MOVIE_MODE") == "1":
		gate_path = ""
	if not gate_path.is_empty():
		print("OPENNV_SHOWCASE_CAPTURE_GATE_WAIT path=%s" % gate_path)
		while not FileAccess.file_exists(gate_path):
			await get_tree().create_timer(0.1).timeout
		print("OPENNV_SHOWCASE_CAPTURE_GATE_OPEN path=%s" % gate_path)
	var entry_id := OS.get_environment("FNV_GODOT_SHOWCASE_DOOR")
	if entry_id.is_empty():
		entry_id = "0x105228"
	showcase_entry_door = cell_streamer.call("door_by_form_id", entry_id) as Node3D
	var door_wait_seconds := 0.0
	while showcase_entry_door == null and door_wait_seconds < 30.0:
		await get_tree().create_timer(0.1).timeout
		door_wait_seconds += 0.1
		showcase_entry_door = cell_streamer.call("door_by_form_id", entry_id) as Node3D
	if showcase_entry_door == null:
		push_error("OPENNV_SHOWCASE_FAILED missing_entry_door=%s" % entry_id)
		get_tree().quit(7)
		return
	if door_wait_seconds > 0.0:
		print("OPENNV_SHOWCASE_DOOR_READY id=%s wait_seconds=%.1f" % [entry_id, door_wait_seconds])
	showcase_active = true
	showcase_long_route = OS.get_environment("FNV_GODOT_LONG_ROUTE") == "1"
	showcase_phase_clock = 0.0
	if camera != null and not xr_active:
		camera.fov = 74.0
	_capture_showcase_checkpoint("01-start")
	_set_showcase_phase("walk_to_entry")
	print("OPENNV_SHOWCASE_READY door=%s distance=%.2f" % [entry_id, player.global_position.distance_to(showcase_entry_door.global_position)])


func _begin_cinematic_reel() -> void:
	var document = JSON.parse_string(FileAccess.get_file_as_string(CINEMATIC_SCENE_PACK))
	if not document is Dictionary:
		push_error("OPENNV_CINEMATIC_FAILED invalid_scene_pack")
		get_tree().quit(12)
		return
	cinematic_portraits = OS.get_environment("FNV_GODOT_PORTRAIT_REEL") == "1"
	cinematic_scenes = document.get("portrait_scenes" if cinematic_portraits else "cinematic_scenes", [])
	cinematic_scene_seconds = 5.0 if cinematic_portraits else CINEMATIC_SCENE_SECONDS
	if cinematic_scenes.size() != 4:
		push_error("OPENNV_CINEMATIC_FAILED expected_scenes=4 actual=%d" % cinematic_scenes.size())
		get_tree().quit(12)
		return
	# Await the coroutine itself. A compact cinematic pack may already have no
	# deferred cells, in which case its ready signal is emitted synchronously
	# and awaiting the signal afterward would miss it forever.
	await cell_streamer.call("preload_route_corridor")
	var gate_path := OS.get_environment("FNV_GODOT_CAPTURE_GATE_FILE")
	if not gate_path.is_empty():
		print("OPENNV_CINEMATIC_CAPTURE_GATE_WAIT path=%s" % gate_path)
		while not FileAccess.file_exists(gate_path):
			await get_tree().create_timer(0.05).timeout
		print("OPENNV_CINEMATIC_CAPTURE_GATE_OPEN path=%s" % gate_path)
	if hud_root != null:
		hud_root.visible = false
	_build_cinematic_label()
	cinematic_active = true
	cinematic_started_msec = Time.get_ticks_msec()
	cinematic_elapsed = 0.0
	cinematic_start_frame = Engine.get_process_frames()
	_enter_cinematic_scene(0)


func _build_cinematic_label() -> void:
	var layer := CanvasLayer.new()
	layer.name = "CinematicTitles"
	add_child(layer)
	cinematic_label = Label.new()
	cinematic_label.position = Vector2(32, 26)
	cinematic_label.add_theme_font_size_override("font_size", 30)
	cinematic_label.add_theme_color_override("font_color", Color(0.88, 0.94, 0.76))
	cinematic_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.9))
	cinematic_label.add_theme_constant_override("shadow_offset_x", 2)
	cinematic_label.add_theme_constant_override("shadow_offset_y", 2)
	layer.add_child(cinematic_label)
	if cinematic_portraits and camera != null:
		var portrait_fill := OmniLight3D.new()
		portrait_fill.name = "PortraitFill"
		portrait_fill.light_color = Color(1.0, 0.82, 0.62)
		portrait_fill.light_energy = 5.0
		portrait_fill.omni_range = 9.0
		portrait_fill.position = Vector3(0.0, 0.2, -0.4)
		camera.add_child(portrait_fill)


func _enter_cinematic_scene(index: int) -> void:
	cinematic_scene_index = index
	cinematic_portrait_reverse_captured = false
	cinematic_vault_door_activated = false
	cinematic_vault_entered = false
	var scene := cinematic_scenes[index] as Dictionary
	if cinematic_portraits:
		var portrait_actor := cell_streamer.call("actor_by_form_id", str(scene.get("actor", ""))) as Node3D
		if portrait_actor == null:
			push_error("OPENNV_PORTRAIT_FAILED missing_actor=%s" % scene.get("actor", ""))
			get_tree().quit(14)
			return
		var facing := portrait_actor.global_basis.x.normalized()
		facing.y = 0.0
		if facing.length_squared() < 0.1:
			facing = Vector3.FORWARD
		var distance := float(scene.get("distance", 2.1))
		var target_height := float(scene.get("target_height", 1.35))
		player.global_position = portrait_actor.global_position + facing.normalized() * distance
		player.velocity = Vector3.ZERO
		camera.look_at(portrait_actor.global_position + Vector3.UP * target_height, Vector3.UP)
		if cinematic_label != null:
			cinematic_label.text = "OPENNV  /  %s" % str(scene.get("label", ""))
		_capture_portrait_after_draw(index, "%s-front-a" % str(scene.get("id", "actor")))
		print("OPENNV_PORTRAIT_SCENE index=%d id=%s actor=%s" % [index, scene.get("id", ""), scene.get("actor", "")])
		return
	player.global_position = _atlas_position_to_world(_array_to_vector3(scene.get("start", [])))
	player.velocity = Vector3.ZERO
	cell_streamer.call("update_focus", player.global_position)
	if cinematic_label != null:
		cinematic_label.text = "OPENNV  /  %s" % str(scene.get("label", ""))
	_capture_showcase_checkpoint("cinematic-%02d-%s" % [index + 1, str(scene.get("id", "scene"))])
	print("OPENNV_CINEMATIC_SCENE index=%d id=%s label=%s" % [index, scene.get("id", ""), scene.get("label", "")])


func _capture_portrait_after_draw(index: int, scene_id: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	if cinematic_active and cinematic_scene_index == index:
		_capture_showcase_checkpoint("portrait-%02d-%s" % [index + 1, scene_id])


func _physics_process_cinematic(delta: float) -> void:
	cinematic_elapsed += delta
	var elapsed := cinematic_elapsed
	if elapsed >= cinematic_scene_seconds * cinematic_scenes.size():
		_complete_cinematic_reel()
		return
	var index := mini(int(elapsed / cinematic_scene_seconds), cinematic_scenes.size() - 1)
	if index != cinematic_scene_index:
		_enter_cinematic_scene(index)
	var local_time := fmod(elapsed, cinematic_scene_seconds)
	var amount := smoothstep(0.0, 1.0, local_time / cinematic_scene_seconds)
	var scene := cinematic_scenes[index] as Dictionary
	if cinematic_portraits:
		var portrait_actor := cell_streamer.call("actor_by_form_id", str(scene.get("actor", ""))) as Node3D
		if portrait_actor != null:
			var facing := portrait_actor.global_basis.x.normalized()
			facing.y = 0.0
			if facing.length_squared() < 0.1:
				facing = Vector3.FORWARD
			var reversed := local_time >= cinematic_scene_seconds * 0.5
			var distance := float(scene.get("distance", 2.1))
			var target_height := float(scene.get("target_height", 1.35))
			player.global_position = portrait_actor.global_position + facing.normalized() * distance * (-1.0 if reversed else 1.0)
			camera.look_at(portrait_actor.global_position + Vector3.UP * target_height, Vector3.UP)
			if reversed and not cinematic_portrait_reverse_captured:
				cinematic_portrait_reverse_captured = true
				_capture_portrait_after_draw(index, "%s-front-b" % str(scene.get("id", "actor")))
		return
	if str(scene.get("id", "")) == "vault21":
		var door_at := float(scene.get("door_at_seconds", 7.5))
		if local_time >= door_at and not cinematic_vault_door_activated:
			var door := cell_streamer.call("door_by_form_id", str(scene.get("door", ""))) as Node3D
			if door != null:
				cinematic_vault_door_activated = true
				player.global_position = door.global_position - door.global_basis.z.normalized() * 2.0
				door.call("activate", player)
				print("OPENNV_CINEMATIC_VAULT_DOOR id=%s" % scene.get("door", ""))
		if cinematic_vault_entered:
			var interior_amount := clampf((local_time - door_at) / maxf(0.1, CINEMATIC_SCENE_SECONDS - door_at), 0.0, 1.0)
			# The portal's collision-safe landing is intentionally outside the
			# doorway hull. Move the cinematic rail into the authored entrance
			# corridor instead of orbiting the cell's broad bounding-box center.
			player.global_position = Vector3(0.0, -500.0, -4.4).lerp(Vector3(0.0, -500.0, -7.6), interior_amount)
			camera.look_at(Vector3(0.0, -498.7, -10.5), Vector3.UP)
			return
	var start := _atlas_position_to_world(_array_to_vector3(scene.get("start", [])))
	var end := _atlas_position_to_world(_array_to_vector3(scene.get("end", [])))
	var look_start := _atlas_position_to_world(_array_to_vector3(scene.get("look_start", [])))
	var look_end := _atlas_position_to_world(_array_to_vector3(scene.get("look_end", [])))
	player.global_position = start.lerp(end, amount)
	player.velocity = Vector3.ZERO
	camera.look_at(look_start.lerp(look_end, amount), Vector3.UP)


func _array_to_vector3(values: Array) -> Vector3:
	if values.size() < 3:
		return Vector3.ZERO
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


func _complete_cinematic_reel() -> void:
	if cinematic_complete:
		return
	cinematic_complete = true
	cinematic_active = false
	var report := {
		"schema": "nikami-opennv-godot-cinematic-reel/v1",
		"status": "pass",
		"sceneSeconds": cinematic_scene_seconds,
		"scenes": cinematic_scenes.map(func(row): return str((row as Dictionary).get("id", ""))),
		"vaultDoorActivated": cinematic_vault_door_activated,
		"vaultInteriorEntered": cinematic_vault_entered,
		"startFrame": cinematic_start_frame,
		"endFrame": Engine.get_process_frames(),
		"streaming": cell_streamer.call("runtime_stats"),
		"windowsAppControlUsed": false,
		"foregroundActivationUsed": false,
		"foregroundInputInjected": false,
	}
	var report_path := OS.get_environment("FNV_GODOT_CINEMATIC_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
	print("OPENNV_CINEMATIC_COMPLETE scenes=%d vault_entered=%s" % [cinematic_scenes.size(), cinematic_vault_entered])
	var release_path := OS.get_environment("FNV_GODOT_CAPTURE_RELEASE_FILE")
	if not release_path.is_empty():
		while not FileAccess.file_exists(release_path):
			await get_tree().create_timer(0.05).timeout
	get_tree().quit(0)


func _set_showcase_phase(next_phase: String) -> void:
	showcase_phase = next_phase
	showcase_phase_clock = 0.0
	showcase_phases.append(next_phase)
	print("OPENNV_SHOWCASE_PHASE name=%s" % next_phase)


func _physics_process_showcase(delta: float) -> void:
	showcase_phase_clock += delta * SHOWCASE_CAPTURE_TIME_SCALE
	match showcase_phase:
		"walk_to_entry":
			if _showcase_walk_toward(showcase_entry_door.global_position, 2.35, 2.05, delta) or showcase_phase_clock > 12.0:
				player.velocity = Vector3.ZERO
				_face_showcase_target(showcase_entry_door.global_position)
				_capture_showcase_checkpoint("02-entry-door")
				_set_showcase_phase("entry_opening")
				showcase_entry_door.call("activate", player)
		"entry_opening", "exit_opening":
			player.velocity = Vector3.ZERO
		"interior_walk":
			if _showcase_walk_toward(showcase_target, 1.55, 0.3, delta) or showcase_phase_clock > 4.0:
				player.velocity = Vector3.ZERO
				_set_showcase_phase("interior_look")
		"interior_look":
			player.velocity = Vector3.ZERO
			if showcase_interior_door != null:
				_face_showcase_target(showcase_interior_door.global_position)
			if showcase_phase_clock >= 2.5:
				showcase_target = showcase_interior_door.global_position
				_set_showcase_phase("walk_to_exit")
		"walk_to_exit":
			if _showcase_walk_toward(showcase_target, 1.45, 1.9, delta) or showcase_phase_clock > 5.0:
				player.velocity = Vector3.ZERO
				_face_showcase_target(showcase_interior_door.global_position)
				_capture_showcase_checkpoint("04-exit-door")
				_set_showcase_phase("exit_opening")
				showcase_interior_door.call("activate", player)
		"exterior_walkaway":
			var exterior_offset := showcase_target - player.global_position
			exterior_offset.y = 0.0
			if exterior_offset.length() <= 2.5:
				player.velocity = Vector3.ZERO
				if showcase_long_route:
					_begin_long_showcase_route()
				else:
					_complete_showcase_route()
			elif showcase_phase_clock > 12.0:
				push_error("OPENNV_SHOWCASE_FAILED exterior_walkaway player=%s target=%s" % [player.global_position, showcase_target])
				get_tree().quit(9)
			else:
				var exterior_steering_target := _showcase_route_steering_target(showcase_target)
				_showcase_walk_toward(exterior_steering_target, 2.15, 0.1, delta)
		"route_walking":
			_open_nearby_strip_gates()
			if showcase_route_waypoint_index >= showcase_route_waypoints.size():
				_finish_long_route_leg()
				return
			var waypoint := showcase_route_waypoints[showcase_route_waypoint_index]
			var before := player.global_position
			var waypoint_offset := waypoint - player.global_position
			waypoint_offset.y = 0.0
			if showcase_route_progress_index != showcase_route_waypoint_index:
				showcase_route_progress_index = showcase_route_waypoint_index
				showcase_route_best_distance = waypoint_offset.length()
				showcase_route_progress_clock = 0.0
			elif waypoint_offset.length() < showcase_route_best_distance - 0.2:
				showcase_route_best_distance = waypoint_offset.length()
				showcase_route_progress_clock = 0.0
			else:
				showcase_route_progress_clock += delta
			if showcase_route_progress_clock >= 5.0:
				push_error("OPENNV_LONG_ROUTE_FAILED no_progress waypoint=%d player=%s target=%s distance=%.2f" % [
					showcase_route_waypoint_index, player.global_position, waypoint, waypoint_offset.length()])
				get_tree().quit(9)
				return
			# Road placement origins can sit several meters off the walkable crown
			# (especially ramps and long curved chunks).  Accept the road envelope;
			# the following 10 m sample still preserves the authored street line.
			if waypoint_offset.length() <= 8.0:
				showcase_route_waypoint_index += 1
				showcase_route_stuck_clock = 0.0
				if showcase_route_waypoint_index % 25 == 0:
					print("OPENNV_LONG_ROUTE_PROGRESS gate_index=%d waypoint=%d/%d position=%s" % [
						showcase_route_gate_index, showcase_route_waypoint_index, showcase_route_waypoints.size(), player.global_position])
				if showcase_route_waypoint_index >= showcase_route_waypoints.size():
					_finish_long_route_leg()
			else:
				# The unattended proof rail is deliberately faster than gameplay so
				# the complete 2.35 km corridor and its gates fit a bounded video.
				# Manual flat-screen and VR movement keep their normal speed.
				_showcase_route_rail_toward(waypoint, SHOWCASE_ROUTE_RAIL_SPEED, delta)
				var horizontal_motion := Vector2(player.global_position.x - before.x, player.global_position.z - before.z).length()
				showcase_route_stuck_clock = showcase_route_stuck_clock + delta if horizontal_motion < 0.015 else 0.0
				if showcase_route_stuck_clock >= 0.65:
					# Engine-owned self-drive can step over road debris and steep seams
					# without disabling authored collision for normal play.
					player.velocity.y = 7.5
					player.global_position.y += 0.18
					showcase_route_stuck_clock = 0.0
					print("OPENNV_LONG_ROUTE_STEP waypoint=%d position=%s" % [showcase_route_waypoint_index, player.global_position])
		"route_gate_opening":
			player.velocity = Vector3.ZERO


func _showcase_route_steering_target(waypoint: Vector3) -> Vector3:
	var direction := waypoint - player.global_position
	direction.y = 0.0
	if direction.length_squared() < 0.01:
		return waypoint
	direction = direction.normalized()
	var space := get_viewport().get_world_3d().direct_space_state
	var origin := player.global_position + Vector3.UP * 0.85
	var forward_query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 3.2)
	forward_query.exclude = [player.get_rid()]
	forward_query.collision_mask = 1
	if space.intersect_ray(forward_query).is_empty():
		return waypoint
	var left := Vector3(-direction.z, 0.0, direction.x)
	var right := -left
	var left_query := PhysicsRayQueryParameters3D.create(origin, origin + left * 5.0)
	left_query.exclude = [player.get_rid()]
	left_query.collision_mask = 1
	var right_query := PhysicsRayQueryParameters3D.create(origin, origin + right * 5.0)
	right_query.exclude = [player.get_rid()]
	right_query.collision_mask = 1
	var left_clear := space.intersect_ray(left_query).is_empty()
	var right_clear := space.intersect_ray(right_query).is_empty()
	var side := left if left_clear or not right_clear else right
	return player.global_position + side * 6.0 + direction * 1.5


func _showcase_route_rail_toward(target: Vector3, speed: float, delta: float) -> void:
	var offset := target - player.global_position
	offset.y = 0.0
	if offset.length_squared() < 0.0001:
		return
	var direction := offset.normalized()
	_face_showcase_target(target)
	var travel := minf(speed * delta, offset.length())
	var position := player.global_position + direction * travel
	# Road mesh origins carry the authored elevation profile. Smooth large
	# legacy-mesh origin changes so the proof camera descends ramps instead of
	# falling through LAND or catching a vertical mesh side.
	position.y = move_toward(player.global_position.y, target.y + 0.2, 8.0 * delta)
	player.global_position = position
	player.velocity = Vector3.ZERO


func _showcase_walk_toward(target: Vector3, speed: float, stop_distance: float, delta: float) -> bool:
	var offset := target - player.global_position
	offset.y = 0.0
	if offset.length() <= stop_distance:
		return true
	# Short unattended proof approaches use the same authored-position rail as
	# the long road. This prevents a capture-only camera from scraping porch,
	# doorway, or interior collision while preserving real door activation.
	_showcase_route_rail_toward(target, speed * SHOWCASE_CAPTURE_TIME_SCALE, delta)
	return false


func _face_showcase_target(target: Vector3) -> void:
	var flat_target := Vector3(target.x, player.global_position.y, target.z)
	if player.global_position.distance_squared_to(flat_target) > 0.01:
		player.look_at(flat_target, Vector3.UP)


func _begin_long_showcase_route() -> void:
	showcase_route_gate_index = 0
	_capture_showcase_checkpoint("06-goodsprings-departure")
	if not _set_authored_road_route(AUTHORED_ROAD_ROUTE):
		push_error("OPENNV_LONG_ROUTE_FAILED authored road route missing or invalid")
		get_tree().quit(8)


func _set_authored_road_route(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var document = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not document is Dictionary or document.get("status", "") != "pass":
		return false
	var authored: Array = document.get("waypoints", [])
	if authored.is_empty():
		return false
	showcase_route_waypoints.clear()
	showcase_route_waypoint_index = 0
	showcase_route_stuck_clock = 0.0
	showcase_route_progress_index = -1
	showcase_route_best_distance = INF
	showcase_route_progress_clock = 0.0
	var previous := player.global_position
	for item in authored:
		var values: Array = item.get("position", [])
		if values.size() < 3:
			return false
		var target := _atlas_position_to_world(Vector3(float(values[0]), float(values[1]), float(values[2])))
		# Keep turns on Bethesda's authored road chain, with close enough samples
		# that a chord cannot cut across a house or a curved roadside obstacle.
		var horizontal_distance := Vector2(target.x - previous.x, target.z - previous.z).length()
		var segments := maxi(1, ceili(horizontal_distance / 10.0))
		for index in range(1, segments + 1):
			showcase_route_waypoints.append(previous.lerp(target, float(index) / float(segments)))
		previous = target
	var validation_start := OS.get_environment("FNV_GODOT_ROUTE_VALIDATION_START").to_int()
	if OS.get_environment("FNV_GODOT_HEADLESS_PHYSICS") == "1" and validation_start > 0 and validation_start < showcase_route_waypoints.size():
		showcase_route_waypoint_index = validation_start
		player.global_position = showcase_route_waypoints[validation_start - 1] + Vector3.UP * 1.0
		cell_streamer.call("update_focus", player.global_position)
		print("OPENNV_LONG_ROUTE_VALIDATION_RESUME waypoint=%d position=%s" % [validation_start, player.global_position])
	_set_showcase_phase("route_walking")
	print("OPENNV_LONG_ROUTE_AUTHORED path=%s source_points=%d walk_points=%d distance_units=%.1f" % [
		path, authored.size(), showcase_route_waypoints.size(), float(document.get("route_distance_units", 0.0))])
	return true


func _set_long_route_leg(target: Vector3) -> void:
	showcase_route_waypoints.clear()
	showcase_route_waypoint_index = 0
	showcase_route_stuck_clock = 0.0
	showcase_route_progress_index = -1
	showcase_route_best_distance = INF
	showcase_route_progress_clock = 0.0
	var start := player.global_position
	var horizontal_distance := Vector2(target.x - start.x, target.z - start.z).length()
	var segments := maxi(1, ceili(horizontal_distance / 70.0))
	for index in range(1, segments + 1):
		var amount := float(index) / float(segments)
		showcase_route_waypoints.append(start.lerp(target, amount))
	_set_showcase_phase("route_walking")
	print("OPENNV_LONG_ROUTE_LEG gate_index=%d waypoints=%d target=%s" % [showcase_route_gate_index, segments, target])


func _finish_long_route_leg() -> void:
	player.velocity = Vector3.ZERO
	var gate_ids: Array[String] = ["0x116420", "0x133954", "0x116425"]
	if showcase_route_gate_index >= gate_ids.size():
		_capture_showcase_checkpoint("10-strip-arrival")
		_complete_showcase_route()
		return
	var gate_id: String = gate_ids[showcase_route_gate_index]
	var gate := cell_streamer.call("door_by_form_id", gate_id) as Node3D
	if gate == null:
		if showcase_phase_clock > 15.0:
			push_error("OPENNV_LONG_ROUTE_FAILED missing_gate=%s" % gate_id)
			get_tree().quit(8)
		return
	player.global_position = Vector3(gate.global_position.x, player.global_position.y, gate.global_position.z) - gate.global_basis.z.normalized() * 2.2
	_face_showcase_target(gate.global_position)
	_capture_showcase_checkpoint("07-gate-%d" % showcase_route_gate_index)
	_set_showcase_phase("route_gate_opening")
	gate.call("activate", player)


func _continue_long_route_after_gate() -> void:
	showcase_route_gate_index += 1
	match showcase_route_gate_index:
		1:
			_capture_showcase_checkpoint("08-freeside-north")
			if not _set_authored_road_route(FREESIDE_NORTH_ROAD_ROUTE):
				get_tree().quit(8)
		2:
			_capture_showcase_checkpoint("09-freeside")
			if not _set_authored_road_route(FREESIDE_ROAD_ROUTE):
				get_tree().quit(8)
		3:
			if not _set_authored_road_route(STRIP_ROAD_ROUTE):
				get_tree().quit(8)


func _atlas_position_to_world(source: Vector3) -> Vector3:
	var source_values: Array = manifest.get("world", {}).get("source_position", [0.0, 0.0, 0.0])
	var origin := Vector3(float(source_values[0]), float(source_values[1]), float(source_values[2]))
	var offset := source - origin
	return Vector3(offset.x, offset.z, -offset.y) / 70.0


func _open_nearby_strip_gates() -> void:
	if showcase_route_gate_index < 3:
		return
	for gate_id in ["0x16a14d", "0x16a14e", "0x16a14f", "0x16a150"]:
		var gate := cell_streamer.call("door_by_form_id", gate_id) as Node3D
		if gate != null and not bool(gate.get_meta("showcase_opened", false)) and player.global_position.distance_to(gate.global_position) < 10.0:
			gate.set_meta("showcase_opened", true)
			gate.call("activate", player)
			print("OPENNV_LONG_ROUTE_OPEN_GATE id=%s" % gate_id)


func _capture_showcase_checkpoint(label: String) -> void:
	var directory := OS.get_environment("FNV_GODOT_NATIVE_FRAME_DIR")
	if directory.is_empty():
		return
	call_deferred("_save_showcase_checkpoint", directory, label)


func _save_showcase_checkpoint(directory: String, label: String) -> void:
	await get_tree().process_frame
	var path := directory.path_join("%s.png" % label)
	var frame := get_viewport().get_texture().get_image()
	var error := frame.save_png(path)
	print("OPENNV_SHOWCASE_NATIVE_FRAME label=%s path=%s error=%d" % [label, path, error])


func _complete_showcase_route() -> void:
	if showcase_complete:
		return
	showcase_active = false
	showcase_complete = true
	_capture_showcase_checkpoint("06-complete")
	var report_path := OS.get_environment("FNV_GODOT_ROUTE_REPORT")
	if not report_path.is_empty():
		var streamer_stats: Dictionary = cell_streamer.call("runtime_stats") if cell_streamer != null else {}
		var report := {
			"schema": "nikami-opennv-godot-showcase-route/v1",
			"status": "pass",
			"route": "goodsprings-door-roundtrip-to-strip-v1" if showcase_long_route else "goodsprings-door-roundtrip-v1",
			"phases": showcase_phases,
			"windowsAppControlUsed": false,
			"foregroundActivationUsed": false,
			"foregroundInputInjected": false,
			"entryDoor": str(showcase_entry_door.get_meta("fnv_form_id", "")),
			"saveSha256": str(manifest.get("save", {}).get("sha256", "")),
			"streaming": streamer_stats,
		}
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
	print("OPENNV_SHOWCASE_COMPLETE phases=%d" % showcase_phases.size())
	var release_path := OS.get_environment("FNV_GODOT_CAPTURE_RELEASE_FILE")
	if not release_path.is_empty():
		while not FileAccess.file_exists(release_path):
			await get_tree().create_timer(0.1).timeout
	else:
		await get_tree().create_timer(2.0).timeout
	_stop_world_audio()
	get_tree().quit(0)

func _capture_native_frame(path: String) -> void:
	if not world_playable:
		_enter_world()
	# Use a deterministic overlook for unattended native captures. Gameplay still
	# begins at the decoded save position and retains the normal first-person camera.
	var capture_camera := Camera3D.new()
	capture_camera.name = "NativeCaptureCamera"
	capture_camera.fov = 68.0
	world_root.add_child(capture_camera)
	var interior_door := OS.get_environment("FNV_GODOT_CAPTURE_INTERIOR_DOOR")
	if not interior_door.is_empty() and cell_streamer != null and cell_streamer.has_method("portal_destination_transform"):
		var destination: Transform3D = cell_streamer.call("portal_destination_transform", interior_door)
		var room_center: Vector3 = cell_streamer.call("portal_destination_center", interior_door)
		var inward := room_center - destination.origin
		inward.y = 0.0
		if inward.length_squared() < 0.1:
			inward = -destination.basis.z
		inward = inward.normalized()
		# Stand well inside the authored room, looking back through its center.
		# Door origins can sit inside thick modular wall geometry, so a small
		# threshold offset is not a reliable presentation camera.
		capture_camera.position = room_center - inward * 3.0
		capture_camera.position.y = destination.origin.y + 1.62
		capture_camera.look_at(Vector3(room_center.x, destination.origin.y + 1.35, room_center.z), Vector3.UP)
		if world_environment != null:
			world_environment.fog_enabled = false
		var camera_light := OmniLight3D.new()
		camera_light.light_color = Color(1.0, 0.82, 0.60)
		camera_light.light_energy = 2.2
		camera_light.omni_range = 18.0
		capture_camera.add_child(camera_light)
		print("OPENNV_NATIVE_CAPTURE_INTERIOR source_door=%s position=%s" % [interior_door, capture_camera.position])
	else:
		capture_camera.position = Vector3(-10.0, 32.0, -10.0)
		capture_camera.look_at(Vector3(58.0, 3.5, -82.0), Vector3.UP)
	capture_camera.current = true
	# Let threaded mesh installs, materials, shadows, fog and the swapchain settle.
	for _frame in range(12):
		await get_tree().process_frame
	var frame := get_viewport().get_texture().get_image()
	var error := frame.save_png(path)
	if error != OK:
		push_error("OPENNV_GODOT_NATIVE_CAPTURE_FAILED path=%s error=%d" % [path, error])
		get_tree().quit(5)
		return
	print("OPENNV_GODOT_NATIVE_CAPTURE_READY path=%s size=%dx%d" % [path, frame.get_width(), frame.get_height()])
	if OS.get_environment("FNV_GODOT_CAPTURE_HOLD") == "1":
		return
	_stop_world_audio()
	await get_tree().process_frame
	get_tree().quit(0)

func _stop_world_audio() -> void:
	if world_root == null:
		return
	for child in world_root.find_children("*", "AudioStreamPlayer", true, false):
		(child as AudioStreamPlayer).stop()
	for child in world_root.find_children("*", "AudioStreamPlayer3D", true, false):
		(child as AudioStreamPlayer3D).stop()

func _build_hud() -> void:
	var hud := Control.new()
	hud_root = hud
	hud.name = "HUD"
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(hud)
	var location := Label.new()
	location.text = "%s  |  SAVE %s" % [str(manifest.get("player", {}).get("location", "")), str(manifest.get("player", {}).get("save_number", ""))]
	location.position = Vector2(24, 20)
	location.add_theme_color_override("font_color", PHOSPHOR)
	hud.add_child(location)
	var help := Label.new()
	help.text = "WASD MOVE   SHIFT SPRINT   SPACE JUMP   E ACTIVATE   TAB PIP-BOY   ESC MENU"
	help.position = Vector2(24, 680)
	help.add_theme_color_override("font_color", PHOSPHOR)
	hud.add_child(help)
	var crosshair := Label.new()
	crosshair.text = "+"
	crosshair.position = Vector2(636, 348)
	crosshair.add_theme_color_override("font_color", Color(0.85, 0.85, 0.72))
	hud.add_child(crosshair)
	_build_pip_boy(hud)

func _build_pip_boy(parent: Control) -> void:
	pip_boy = Panel.new()
	pip_boy.name = "PipBoy"
	pip_boy.position = Vector2(170, 70)
	pip_boy.size = Vector2(940, 580)
	pip_boy.visible = false
	parent.add_child(pip_boy)
	var body := VBoxContainer.new()
	body.position = Vector2(34, 26)
	body.size = Vector2(872, 520)
	pip_boy.add_child(body)
	var title := Label.new()
	title.text = "PIP-BOY 3000  |  INV   DATA   MAP   RADIO"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", PHOSPHOR)
	body.add_child(title)
	var line := HSeparator.new()
	body.add_child(line)
	var inventory := RichTextLabel.new()
	inventory.fit_content = false
	inventory.custom_minimum_size = Vector2(850, 450)
	inventory.bbcode_enabled = true
	inventory.add_theme_color_override("default_color", PHOSPHOR)
	var rows: Array = manifest.get("inventory", [])
	var text := "[font_size=19]REAL SAVE INVENTORY[/font_size]\n\n"
	for row in rows.slice(0, mini(rows.size(), 22)):
		text += "%s   x%s\n" % [str(row.get("form_id", "")), str(row.get("count", 0))]
	inventory.text = text
	body.add_child(inventory)

func _physics_process(delta: float) -> void:
	if not world_playable or player == null or not is_instance_valid(player) or (pip_boy != null and pip_boy.visible):
		return
	if cell_streamer != null and cell_streamer.has_method("update_focus"):
		cell_streamer.call("update_focus", player.global_position)
	if cinematic_active:
		_physics_process_cinematic(delta)
		_update_ambient_audio(delta)
		return
	if showcase_active:
		_physics_process_showcase(delta)
		_update_ambient_audio(delta)
		return
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if xr_active and left_controller != null:
		var stick := left_controller.get_vector2("primary")
		if stick.length() > input.length():
			# OpenXR's primary stick Y is opposite Godot's move_forward/move_back
			# action convention. Normalize it here so stick-up always moves forward.
			input = Vector2(stick.x, -stick.y)
	var movement_basis := player.global_basis
	if xr_active and camera != null:
		var forward := -camera.global_basis.z
		forward.y = 0.0
		forward = forward.normalized()
		var right := camera.global_basis.x
		right.y = 0.0
		right = right.normalized()
		movement_basis = Basis(right, Vector3.UP, -forward)
	var direction := (movement_basis * Vector3(input.x, 0, input.y)).normalized()
	var speed := 7.0 if Input.is_action_pressed("sprint") else 4.2
	player.velocity.x = direction.x * speed
	player.velocity.z = direction.z * speed
	if not player.is_on_floor():
		player.velocity.y -= 18.0 * delta
	elif Input.is_action_just_pressed("jump"):
		player.velocity.y = 6.3
	player.move_and_slide()
	if player.is_on_floor():
		last_safe_player_position = player.global_position
		has_safe_player_position = true
	elif has_safe_player_position and player.global_position.y < last_safe_player_position.y - 12.0:
		# Never let a late collision upgrade or malformed third-party mesh turn
		# into an endless void fall. Restore the last confirmed walkable point;
		# the streamer continues upgrading the surrounding LAND from there.
		player.global_position = last_safe_player_position + Vector3.UP * 0.08
		player.velocity = Vector3.ZERO
		print("OPENNV_TRAVERSAL_RECOVER position=%s" % player.global_position)
	_update_ambient_audio(delta)
	if xr_active and right_controller != null:
		var trigger_pressed := right_controller.get_float("trigger") >= 0.72
		if trigger_pressed and not xr_trigger_was_pressed:
			_try_activate_from(right_controller.global_position, -right_controller.global_basis.z)
		xr_trigger_was_pressed = trigger_pressed

func _update_ambient_audio(delta: float) -> void:
	if ambient_one_shot == null or not is_instance_valid(ambient_one_shot):
		return
	ambient_clock -= delta
	if ambient_clock > 0.0 or ambient_one_shot.playing:
		return
	var candidates: Array[String] = []
	for path in AMBIENT_ONESHOTS:
		if ResourceLoader.exists(path):
			candidates.append(path)
	if candidates.is_empty():
		return
	ambient_one_shot.stream = load(candidates.pick_random())
	var angle := randf() * TAU
	ambient_one_shot.global_position = player.global_position + Vector3(cos(angle) * 18.0, randf_range(3.0, 8.0), sin(angle) * 18.0)
	ambient_one_shot.play()
	ambient_clock = randf_range(8.0, 18.0)

func _try_activate() -> void:
	if camera == null or not is_instance_valid(camera):
		return
	_try_activate_from(camera.global_position, -camera.global_basis.z)

func _try_activate_from(origin: Vector3, direction: Vector3) -> void:
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction.normalized() * 3.2)
	query.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	var target = hit.get("collider")
	if target != null and target.has_method("activate"):
		target.activate(player)

func _input(event: InputEvent) -> void:
	# Mouse look must run before fullscreen HUD controls can consume GUI events.
	if not world_playable or player == null or camera == null:
		return
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		mouse_look = true
	elif event is InputEventMouseMotion and not xr_active and mouse_look and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		player.rotate_y(-event.relative.x * 0.0023)
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * 0.0023, -1.45, 1.45)

func _unhandled_input(event: InputEvent) -> void:
	if active_video != null and event.is_action_pressed("skip_cinematic"):
		_skip_active_video()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("pip_boy") and pip_boy != null and world_playable:
		pip_boy.visible = not pip_boy.visible
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if pip_boy.visible else Input.MOUSE_MODE_CAPTURED
		mouse_look = not pip_boy.visible
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("activate") and world_playable:
		_try_activate()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("pause") and world_root != null and world_playable:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		mouse_look = false
		world_playable = false
		if hud_root != null:
			hud_root.visible = false
		_show_main_menu()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		mouse_look = false
