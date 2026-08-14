extends RefCounted

const INDEX_PATH := "res://generated/semantic-db/audio-runtime-index.json"
const CACHE_LIMIT := 128

var sounds: Dictionary = {}
var music: Dictionary = {}
var sound_editor_ids: Dictionary = {}
var animation_sound_aliases: Dictionary = {}
var music_editor_ids: Dictionary = {}
var stream_cache: Dictionary = {}
var cache_lru: Array[String] = []


func clear_cache() -> void:
	stream_cache.clear()
	cache_lru.clear()


func load_index(path: String = INDEX_PATH) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("OPENNV_AUDIO_RUNTIME_INDEX unavailable path=%s" % path)
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or str(parsed.get("schema", "")) != "opennv-audio-runtime-index/v1":
		push_error("OPENNV_AUDIO_RUNTIME_INDEX invalid")
		return false
	sounds = parsed.get("sounds", {}) as Dictionary
	music = parsed.get("music", {}) as Dictionary
	sound_editor_ids = parsed.get("soundEditorIds", {}) as Dictionary
	animation_sound_aliases = parsed.get("animationSoundAliases", {}) as Dictionary
	music_editor_ids = parsed.get("musicEditorIds", {}) as Dictionary
	var counts := parsed.get("counts", {}) as Dictionary
	print("OPENNV_AUDIO_RUNTIME_READY sounds=%d files=%d music=%d" % [
		int(counts.get("soundsLoadable", 0)), int(counts.get("soundFilesLoadable", 0)),
		int(counts.get("musicLoadable", 0))])
	return true


func stream_for_sound(form_id_value: Variant) -> AudioStream:
	var key := _canonical(form_id_value)
	key = str(animation_sound_aliases.get(key, key))
	key = str(sound_editor_ids.get(key, key))
	return _stream_for_record(sounds.get(key, {}) as Dictionary)


func stream_for_music(form_id_value: Variant) -> AudioStream:
	var key := _canonical(form_id_value)
	key = str(music_editor_ids.get(key, key))
	return _stream_for_record(music.get(key, {}) as Dictionary)


func sound_is_looping(form_id_value: Variant) -> bool:
	var key := _canonical(form_id_value)
	key = str(animation_sound_aliases.get(key, key))
	key = str(sound_editor_ids.get(key, key))
	var record := sounds.get(key, {}) as Dictionary
	var data := record.get("soundData", {}) as Dictionary
	return (int(data.get("flags", 0)) & 0x10) != 0


func _stream_for_record(record: Dictionary) -> AudioStream:
	var files := record.get("files", []) as Array
	if files.is_empty():
		return null
	var path := str(files[randi() % files.size()])
	if stream_cache.has(path):
		_touch(path)
		return stream_cache[path] as AudioStream
	var stream := _load_stream(path)
	if stream == null:
		return null
	stream_cache[path] = stream
	_touch(path)
	while cache_lru.size() > CACHE_LIMIT:
		stream_cache.erase(cache_lru.pop_front())
	return stream


func _load_stream(path: String) -> AudioStream:
	if not FileAccess.file_exists(path):
		return null
	match path.get_extension().to_lower():
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
	return null


func _touch(path: String) -> void:
	var index := cache_lru.find(path)
	if index >= 0:
		cache_lru.remove_at(index)
	cache_lru.append(path)


func _canonical(value: Variant) -> String:
	var text := str(value).strip_edges().to_lower()
	if text.is_empty() or text == "null":
		return ""
	if text.begins_with("0x"):
		return "0x%x" % text.hex_to_int()
	if text.is_valid_int():
		return "0x%x" % int(text)
	return text
