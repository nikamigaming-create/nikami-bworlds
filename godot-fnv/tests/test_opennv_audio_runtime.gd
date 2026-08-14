extends SceneTree


func _init() -> void:
	var runtime = load("res://scripts/opennv_audio_runtime.gd").new()
	if not runtime.load_index():
		fail("runtime index did not load")
		return
	if runtime.stream_for_sound("NPCSecuritronScreenGlitch") == null:
		fail("animation text-key sound editor ID did not resolve")
		return
	if runtime.stream_for_sound("npchumanchew") == null:
		fail("validated retail animation sound alias did not resolve")
		return
	if runtime.stream_for_sound("npchumanswallow") == null:
		fail("retail eat-animation swallow event did not resolve")
		return
	var event_runtime = load("res://scripts/opennv_animation_event_runtime.gd").new()
	root.add_child(event_runtime)
	await process_frame
	OS.set_environment("FNV_GODOT_HEADLESS_AUDIO_EVENTS", "1")
	event_runtime.call("dispatch_text_key", "sound: NPCSecuritronScreenGlitch")
	await process_frame
	var animation_sound := event_runtime.get_node_or_null("AnimationSound") as AudioStreamPlayer3D
	if animation_sound == null or animation_sound.stream == null:
		fail("animation text-key event did not create authored sound player")
		return
	var found := {"wav": false, "ogg": false, "mp3": false}
	for table_name in ["sounds", "music"]:
		var table := runtime.get(table_name) as Dictionary
		for form_id in table:
			var record := table[form_id] as Dictionary
			for path_value in record.get("files", []) as Array:
				var extension := str(path_value).get_extension().to_lower()
				if not found.has(extension) or bool(found[extension]):
					continue
				var stream := runtime.call("_load_stream", str(path_value)) as AudioStream
				if stream == null:
					fail("could not decode %s asset %s" % [extension, path_value])
					return
				found[extension] = true
	for extension in found:
		if not bool(found[extension]):
			fail("no loadable %s coverage" % extension)
			return
	var streamer = load("res://scripts/fnv_cell_streamer.gd").new()
	root.add_child(streamer)
	await process_frame
	var streamer_audio = streamer.get("audio_runtime")
	if not streamer_audio.load_index():
		fail("streamer audio index did not load")
		return
	var emitter := Node3D.new()
	streamer.add_child(emitter)
	streamer.call("_attach_authored_looping_sound", emitter, {"looping_sound": "0x14e0a"})
	var player := emitter.get_node_or_null("AuthoredLoopingSound") as AudioStreamPlayer3D
	if player == null or player.stream == null:
		fail("model-less authored looping emitter was not instantiated")
		return
	streamer.call("_set_scope_enabled", "__exterior__", false)
	await process_frame
	if player.playing:
		fail("inactive streamed scope kept its looping audio live scopes=%s" % str(streamer.get("audio_players_by_scope")))
		return
	streamer.call("_set_scope_enabled", "__exterior__", true)
	await process_frame
	if not player.playing:
		fail("active streamed scope did not resume looping audio")
		return
	animation_sound.stop()
	animation_sound.stream = null
	player.stop()
	player.stream = null
	var sound_count := (runtime.get("sounds") as Dictionary).size()
	var music_count := (runtime.get("music") as Dictionary).size()
	streamer.call("_exit_tree")
	streamer.free()
	event_runtime.free()
	runtime.call("clear_cache")
	load("res://scripts/opennv_animation_event_runtime.gd").call("reset_shared_audio_runtime")
	OS.unset_environment("FNV_GODOT_HEADLESS_AUDIO_EVENTS")
	# Audio resources and playback RIDs retire asynchronously. Drop every strong
	# test reference and give the servers a bounded drain window before exit so
	# leak detection is deterministic under the full-suite process cadence.
	animation_sound = null
	player = null
	emitter = null
	streamer_audio = null
	streamer = null
	event_runtime = null
	runtime = null
	for index in range(5):
		await process_frame
	await create_timer(0.1).timeout
	print("OPENNV_AUDIO_RUNTIME_PASS sounds=%d music=%d formats=wav,ogg,mp3" % [
		sound_count, music_count])
	quit(0)


func fail(message: String) -> void:
	push_error("OPENNV_AUDIO_RUNTIME_FAIL " + message)
	quit(1)
