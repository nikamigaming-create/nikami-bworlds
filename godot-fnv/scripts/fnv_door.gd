extends AnimatableBody3D

signal portal_requested(door: Node3D, actor: Node3D)

var is_open := false
var moving := false
var closed_rotation := Vector3.ZERO
var audio_runtime: RefCounted
var open_sound := ""
var close_sound := ""


func _ready() -> void:
	closed_rotation = rotation


func activate(actor: Node = null) -> bool:
	if moving or bool(get_meta("opennv_portal_pending", false)):
		return false
	moving = true
	_perform_activation(actor)
	return true


func _perform_activation(actor: Node = null) -> void:
	is_open = not is_open
	var target := closed_rotation
	if is_open:
		target.y += deg_to_rad(92.0)
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "rotation", target, 0.62)
	var sound_id := open_sound if is_open else close_sound
	var authored_stream: AudioStream
	if audio_runtime != null and audio_runtime.has_method("stream_for_sound"):
		authored_stream = audio_runtime.call("stream_for_sound", sound_id) as AudioStream
	if authored_stream != null:
		var audio := AudioStreamPlayer3D.new()
		audio.stream = authored_stream
		audio.unit_size = 3.0
		audio.max_distance = 24.0
		add_child(audio)
		audio.finished.connect(audio.queue_free)
		audio.play()
	await tween.finished
	moving = false
	if actor != null and not is_instance_valid(actor):
		complete_portal()
		return
	if actor is Node3D and not str(get_meta("fnv_destination_door", "")).is_empty():
		set_meta("opennv_portal_pending", true)
		portal_requested.emit(self, actor as Node3D)


func configure_audio(runtime: RefCounted, authored_open_sound: String, authored_close_sound: String) -> void:
	audio_runtime = runtime
	open_sound = authored_open_sound
	close_sound = authored_close_sound


func complete_portal() -> void:
	set_meta("opennv_portal_pending", false)
