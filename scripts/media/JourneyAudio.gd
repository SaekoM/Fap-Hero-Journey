class_name JourneyAudio
extends RefCounted

# Loading + looping for journey-supplied audio ACCENTS — the optional clip a storyboard line or a
# fork can play. Journey clips live in user:// (the journey folder), NOT as res:// imported
# resources, so load() won't take them — we pick the decoder by extension, mirroring how
# JourneyData.load_image_smart handles images. Godot decodes ogg / mp3 / wav natively (no ffmpeg),
# so the save just hash-pools the file as-is (see JourneyBuilder._pool_small_file).

const AUDIO_EXTENSIONS: Array = ["ogg", "mp3", "wav"]


# Loads an accent clip from a file path, or null if missing / unsupported / unreadable.
static func load_from_file(path: String) -> AudioStream:
	if path == "":
		return null
	var abs: String = ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs):
		return null
	match path.get_extension().to_lower():
		"ogg":
			return AudioStreamOggVorbis.load_from_file(abs)
		"mp3":
			return AudioStreamMP3.load_from_file(abs)
		"wav":
			return AudioStreamWAV.load_from_file(abs)
	return null


# Sets a stream's own loop flag (each stream type spells it differently). Loop lives on the STREAM,
# not the player, so the engine loops it seamlessly.
static func set_loop(stream: AudioStream, loop: bool) -> void:
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = loop
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = loop
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = (
			AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
		)
