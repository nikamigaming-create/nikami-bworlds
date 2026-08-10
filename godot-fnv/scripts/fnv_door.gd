extends AnimatableBody3D

signal portal_requested(door: Node3D, actor: Node3D)

const DOOR_SOUND := "res://generated/assets/converted/sound/fx/obj/vegasdoor/sfx_vegasdoor_open.wav"

var is_open := false
var moving := false
var closed_rotation := Vector3.ZERO


func _ready() -> void:
	closed_rotation = rotation


func activate(actor: Node = null) -> void:
	if moving or bool(get_meta("opennv_portal_pending", false)):
		return
	moving = true
	is_open = not is_open
	var target := closed_rotation
	if is_open:
		target.y += deg_to_rad(92.0)
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "rotation", target, 0.62)
	if ResourceLoader.exists(DOOR_SOUND):
		var audio := AudioStreamPlayer3D.new()
		audio.stream = load(DOOR_SOUND)
		audio.unit_size = 3.0
		audio.max_distance = 24.0
		add_child(audio)
		audio.finished.connect(audio.queue_free)
		audio.play()
	await tween.finished
	moving = false
	if actor is Node3D and not str(get_meta("fnv_destination_door", "")).is_empty():
		set_meta("opennv_portal_pending", true)
		portal_requested.emit(self, actor as Node3D)


func complete_portal() -> void:
	set_meta("opennv_portal_pending", false)
