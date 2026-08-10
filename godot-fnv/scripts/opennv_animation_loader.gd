class_name OpenNVAnimationLoader
extends RefCounted

const MAGIC := "ONVANIM1"
const VERSION := 1
const MAX_TRACKS := 10000
const MAX_FRAMES := 36000
const UNITS_PER_METER := 70.0


static func attach_clip(actor_root: Node3D, path: String, clip_name: String = "idle") -> AnimationPlayer:
	var payload := _read_payload(path)
	if payload.is_empty():
		return null
	var skeletons: Array[Skeleton3D] = []
	_collect_skeletons(actor_root, skeletons)
	if skeletons.is_empty():
		push_error("OPENNV_ANIMATION_NO_SKELETON path=%s" % path)
		return null
	var animation := Animation.new()
	animation.length = float(payload.duration)
	animation.loop_mode = Animation.LOOP_LINEAR
	var matched_bindings := 0
	var matched_source_tracks: Dictionary = {}
	var unmatched_source_tracks: Array[String] = []
	for track_value in payload.tracks:
		var source_track := track_value as Dictionary
		var source_matched := false
		for skeleton in skeletons:
			var bone_index := skeleton.find_bone(str(source_track.name))
			if bone_index < 0:
				bone_index = _find_bone_case_insensitive(skeleton, str(source_track.name))
			if bone_index < 0:
				var source_indices: Dictionary = skeleton.get_meta("opennv_source_bone_indices", {}) as Dictionary
				bone_index = int(source_indices.get(str(source_track.name).to_lower(), -1))
			if bone_index < 0:
				bone_index = _find_fallout_alias_bone(skeleton, str(source_track.name))
			if bone_index < 0:
				continue
			matched_bindings += 1
			source_matched = true
			matched_source_tracks[str(source_track.name).to_lower()] = true
			var target := NodePath("%s:%s" % [actor_root.get_path_to(skeleton), skeleton.get_bone_name(bone_index)])
			_add_bone_delta_tracks(animation, target, source_track.frames, skeleton.get_bone_rest(bone_index),
				float(payload.sample_rate), float(payload.duration))
		if not source_matched:
			unmatched_source_tracks.append(str(source_track.name))
	if matched_source_tracks.is_empty():
		push_error("OPENNV_ANIMATION_ZERO_MATCHES path=%s source_tracks=%d" % [path, payload.tracks.size()])
		return null
	var library := AnimationLibrary.new()
	library.add_animation(clip_name, animation)
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	player.root_node = NodePath("..")
	player.add_animation_library("", library)
	actor_root.add_child(player)
	player.play(clip_name)
	actor_root.set_meta("opennv_animation_source", path)
	actor_root.set_meta("opennv_animation_source_tracks", payload.tracks.size())
	actor_root.set_meta("opennv_animation_matched_tracks", matched_source_tracks.size())
	actor_root.set_meta("opennv_animation_matched_bindings", matched_bindings)
	actor_root.set_meta("opennv_animation_unmatched_tracks", unmatched_source_tracks)
	actor_root.set_meta("opennv_animation_text_keys", payload.text_keys)
	return player


static func _add_bone_delta_tracks(animation: Animation, target: NodePath, frames: Array,
		rest: Transform3D, sample_rate: float, duration: float) -> void:
	var position_track := animation.add_track(Animation.TYPE_POSITION_3D)
	var rotation_track := animation.add_track(Animation.TYPE_ROTATION_3D)
	var scale_track := animation.add_track(Animation.TYPE_SCALE_3D)
	for track_index in [position_track, rotation_track, scale_track]:
		animation.track_set_path(track_index, target)
		animation.track_set_interpolation_type(track_index, Animation.INTERPOLATION_LINEAR)
	var rest_position := rest.origin
	var rest_rotation := rest.basis.get_rotation_quaternion().normalized()
	var rest_scale := rest.basis.get_scale()
	for frame_index in range(frames.size()):
		var frame := frames[frame_index] as Dictionary
		var absolute_position: Vector3 = frame.get("position", rest_position)
		var absolute_rotation: Quaternion = frame.get("rotation", rest_rotation)
		var absolute_scale: Vector3 = frame.get("scale", rest_scale)
		var absolute := Transform3D(Basis(absolute_rotation).scaled(absolute_scale), absolute_position)
		var delta := rest.affine_inverse() * absolute
		var time := minf(duration, float(frame_index) / sample_rate)
		animation.track_insert_key(position_track, time, delta.origin)
		animation.track_insert_key(rotation_track, time, delta.basis.get_rotation_quaternion().normalized())
		animation.track_insert_key(scale_track, time, delta.basis.get_scale())


static func _read_payload(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_buffer(8).get_string_from_ascii() != MAGIC:
		push_error("OPENNV_ANIMATION_BAD_MAGIC path=%s" % path)
		return {}
	var version := file.get_32()
	var sample_rate := file.get_float()
	var duration := file.get_float()
	var frame_count := file.get_32()
	var track_count := file.get_32()
	var text_key_count := file.get_32()
	if version != VERSION or sample_rate <= 0.0 or duration <= 0.0 \
			or frame_count == 0 or frame_count > MAX_FRAMES or track_count > MAX_TRACKS or text_key_count > MAX_TRACKS:
		push_error("OPENNV_ANIMATION_BAD_HEADER path=%s version=%d tracks=%d frames=%d" % [path, version, track_count, frame_count])
		return {}
	var text_keys: Array[Dictionary] = []
	for _index in range(text_key_count):
		text_keys.append({"time": file.get_float(), "text": _read_string(file)})
	var tracks: Array[Dictionary] = []
	for _track_index in range(track_count):
		var name := _read_string(file)
		var frames: Array[Dictionary] = []
		for _frame_index in range(frame_count):
			var flags := file.get_8()
			var frame := {"flags": flags}
			if (flags & 1) != 0:
				frame.position = _source_position(Vector3(file.get_float(), file.get_float(), file.get_float()))
			if (flags & 2) != 0:
				frame.rotation = _source_quaternion(Quaternion(file.get_float(), file.get_float(), file.get_float(), file.get_float()))
			if (flags & 4) != 0:
				var scale := file.get_float()
				frame.scale = Vector3.ONE * scale
			frames.append(frame)
		tracks.append({"name": name, "frames": frames})
	if file.get_position() != file.get_length():
		push_error("OPENNV_ANIMATION_TRAILING_BYTES path=%s bytes=%d" % [path, file.get_length() - file.get_position()])
		return {}
	return {"sample_rate": sample_rate, "duration": duration, "text_keys": text_keys, "tracks": tracks}


static func _collect_skeletons(node: Node, result: Array[Skeleton3D]) -> void:
	if node is Skeleton3D:
		result.append(node as Skeleton3D)
	for child in node.get_children():
		_collect_skeletons(child, result)


static func _find_bone_case_insensitive(skeleton: Skeleton3D, name: String) -> int:
	for index in range(skeleton.get_bone_count()):
		if skeleton.get_bone_name(index).nocasecmp_to(name) == 0:
			return index
	return -1


static func _find_fallout_alias_bone(skeleton: Skeleton3D, name: String) -> int:
	var base := name.split(":", false, 1)[0]
	var candidates := [base, base + "Root", "Bip01 " + base]
	var source_indices: Dictionary = skeleton.get_meta("opennv_source_bone_indices", {}) as Dictionary
	for candidate in candidates:
		var index := int(source_indices.get(str(candidate).to_lower(), -1))
		if index >= 0:
			return index
		index = _find_bone_case_insensitive(skeleton, str(candidate))
		if index >= 0:
			return index
	return -1


static func _read_string(file: FileAccess) -> String:
	var size := file.get_32()
	if size > 1000000 or file.get_position() + size > file.get_length():
		return ""
	return file.get_buffer(size).get_string_from_utf8()


static func _source_position(value: Vector3) -> Vector3:
	return Vector3(value.x, value.z, -value.y) / UNITS_PER_METER


static func _source_quaternion(value: Quaternion) -> Quaternion:
	var conversion := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))
	return (conversion * Basis(value.normalized()) * conversion.inverse()).get_rotation_quaternion().normalized()
