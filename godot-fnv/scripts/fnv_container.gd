extends StaticBody3D

signal opened(container: Node, actor: Node, contents: Array)

var contents: Array[Dictionary] = []
var activation_player: AudioStreamPlayer3D


func configure(entries: Array) -> void:
	contents.clear()
	for entry_value in entries:
		var entry := entry_value as Dictionary
		var count := int(entry.get("count", 0))
		if count != 0:
			contents.append({"item": str(entry.get("item", "")), "count": count})


func activate(actor: Node) -> void:
	if activation_player != null and activation_player.stream != null:
		activation_player.play()
	opened.emit(self, actor, contents.duplicate(true))


func configure_audio(audio_runtime: RefCounted, sound_id: String) -> void:
	if sound_id.is_empty() or audio_runtime == null:
		return
	var stream := audio_runtime.call("stream_for_sound", sound_id) as AudioStream
	if stream == null:
		return
	activation_player = AudioStreamPlayer3D.new()
	activation_player.name = "ActivationSound"
	activation_player.stream = stream
	activation_player.unit_size = 3.0
	activation_player.max_distance = 35.0
	add_child(activation_player)


func take_all() -> Array[Dictionary]:
	var transferred := contents.duplicate(true)
	contents.clear()
	return transferred
