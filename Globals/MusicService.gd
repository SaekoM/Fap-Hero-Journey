extends Node

# ---------------------------------------------------------------------------
# MusicService  (autoload)
# Manages continuous background music for menu screens.
# Tracks are shuffled and played in rotation; when the last track finishes
# the list is reshuffled before cycling again (avoids immediate repeats).
# Music is paused (not stopped) when entering gameplay so the playback
# position is preserved when the player returns to a menu.
# ---------------------------------------------------------------------------

const TRACKS: Array[String] = [
	"res://assets/music/menu_music.ogg",
	"res://assets/music/White Bat Audio - The Wraith.ogg",
	"res://assets/music/White Bat Audio - Solstice.ogg",
]

var _player: AudioStreamPlayer = null
var _order: Array[int] = []
var _order_index: int = 0


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
	_player.finished.connect(_on_track_finished)
	add_child(_player)

	var vol: float = float(SettingsService.get_music_volume())
	_player.volume_db = linear_to_db(vol)

	_build_order()
	_play_current()


func play() -> void:
	if _player == null:
		return
	if _player.stream_paused:
		_player.stream_paused = false
	elif not _player.playing:
		_play_current()


func stop() -> void:
	if _player == null:
		return
	_player.stream_paused = true


func set_volume(linear: float) -> void:
	if _player == null:
		return
	_player.volume_db = linear_to_db(linear)


func _on_track_finished() -> void:
	_order_index += 1
	if _order_index >= _order.size():
		_build_order()
	_play_current()


func _play_current() -> void:
	var path: String = TRACKS[_order[_order_index]]
	var stream: AudioStreamOggVorbis = load(path)
	stream.loop = false
	_player.stream = stream
	_player.play()


# Fisher-Yates shuffle of track indices. If there is more than one track,
# ensure the first entry in the new order differs from the last track that
# just played so there are no back-to-back repeats across reshuffles.
func _build_order() -> void:
	# _order_index sits one past the end when called after the final track —
	# clamp it back to the track that just played.
	var last: int = _order[mini(_order_index, _order.size() - 1)] if _order.size() > 0 else -1
	_order.clear()
	for i in TRACKS.size():
		_order.append(i)
	_order.shuffle()
	if TRACKS.size() > 1 and _order[0] == last:
		# Swap first entry with a random other position to avoid repeat.
		var swap: int = randi_range(1, _order.size() - 1)
		var tmp: int = _order[0]
		_order[0] = _order[swap]
		_order[swap] = tmp
	_order_index = 0
