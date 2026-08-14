extends Node

const AUDIO_RUNTIME_SCRIPT = preload("res://scripts/opennv_audio_runtime.gd")

static var shared_audio_runtime: RefCounted


static func reset_shared_audio_runtime() -> void:
	if shared_audio_runtime != null and shared_audio_runtime.has_method("clear_cache"):
		shared_audio_runtime.call("clear_cache")
	shared_audio_runtime = null


func _ready() -> void:
	if shared_audio_runtime == null:
		shared_audio_runtime = AUDIO_RUNTIME_SCRIPT.new()
		shared_audio_runtime.call("load_index")


func _exit_tree() -> void:
	for child in get_children():
		if child is AudioStreamPlayer3D:
			var player := child as AudioStreamPlayer3D
			player.stop()
			player.stream = null


func dispatch_text_key(text_value: String) -> void:
	var text := text_value.strip_edges()
	if not text.to_lower().begins_with("sound:"):
		return
	var sound_id := text.substr(text.find(":") + 1).strip_edges()
	if sound_id.is_empty() or shared_audio_runtime == null:
		return
	var stream := shared_audio_runtime.call("stream_for_sound", sound_id) as AudioStream
	if stream == null:
		push_warning("OPENNV_ANIMATION_SOUND_UNRESOLVED %s" % sound_id)
		return
	# Headless animation/pose gates still resolve authored sound keys, but should not
	# start an audio backend object unless the dedicated audio lifecycle test asks
	# for one. Playback objects can outlive the final headless frame inside Godot's
	# audio thread and produce an intermittent ObjectDB leak at process teardown.
	if DisplayServer.get_name() == "headless" and OS.get_environment("FNV_GODOT_HEADLESS_AUDIO_EVENTS") != "1":
		return
	var player := AudioStreamPlayer3D.new()
	player.name = "AnimationSound"
	player.stream = stream
	player.finished.connect(player.queue_free)
	add_child(player)
	player.play()
