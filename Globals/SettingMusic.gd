extends Node

# ---------------------------------------------------------------------------
# SettingMusic  (autoload)
# The score under a journey's non-playable nodes: storyboards, shops, checkpoints and forks.
#
# Everything here exists to serve one rule — MUSIC THAT SHOULD KEEP PLAYING KEEPS PLAYING. A storyboard
# advancing from line to line asks for its music on every line, and asking is not the same as changing:
# if what is wanted matches what is already on, the request is a no-op and the track is left exactly
# where it is. Without that, a scene's theme restarted on every line of dialogue, which is what this
# feature was built to fix.
#
# Identity is the PLAYLIST, not the clip. A single-track request is a one-entry playlist, so a setting
# and the journey's shuffled score compare the same way and neither restarts the other unnecessarily.
#
# Distinct from MusicService, which owns menu music from a fixed asset list. Two services rather than
# one because they answer to different owners: that one is the app's, this one is the journey's, and
# entering a journey should silence the menu rather than inherit its rotation.
# ---------------------------------------------------------------------------

# Long enough that two pieces of music trade places rather than collide, short enough that a deliberate
# scene change still feels like one. Fixed rather than authorable: a fade time per setting is a knob
# nobody would tune and everybody would have to read past.
const CROSSFADE_SECS: float = 0.4
const SILENT_DB: float = -40.0
# How far the score drops under a voiced line. Enough that speech sits clearly on top, not so far that
# the music seems to stop and start around it.
const DUCK_DB: float = -12.0
# Quick enough not to swallow the first syllable, slow enough not to read as a level jump.
const DUCK_SECS: float = 0.25

# Two players so a change can crossfade: one carries the outgoing track while the other brings the new
# one in. They swap roles on every change rather than one being permanently "current".
var _player: AudioStreamPlayer = null
var _fading: AudioStreamPlayer = null
var _tween: Tween = null

# The playlist currently on, as the identity to compare a request against. Empty means silence.
var _current: Array = []
var _volume: float = 0.6
# Shuffled play order over _current, with the index of the track playing now.
var _order: Array[int] = []
var _order_index: int = 0
var _paused: bool = false
# Held under a voiced line. Separate tween from the crossfade so a scene change mid-narration does not
# cancel the duck (or the other way round) — they are different decisions about the same volume.
var _ducked: bool = false
var _duck_tween: Tween = null


func _ready() -> void:
	_player = _make_player()
	_fading = _make_player()


# The level the score should currently sit at: its own volume, less the duck when something is speaking
# over it. Every place that sets a volume goes through this, so a track arriving mid-narration comes in
# already ducked rather than blaring for a quarter second.
func _target_db() -> float:
	return linear_to_db(maxf(_volume, 0.0001)) + (DUCK_DB if _ducked else 0.0)


# Drops the score under a voiced line and lifts it again after. No-ops when nothing is playing, so a
# caller never has to ask whether there is music to duck.
func duck() -> void:
	_set_ducked(true)


func unduck() -> void:
	_set_ducked(false)


func _set_ducked(on: bool) -> void:
	if _ducked == on:
		return
	_ducked = on
	if _current.is_empty() or _paused:
		return
	if _duck_tween != null and _duck_tween.is_valid():
		_duck_tween.kill()
	_duck_tween = create_tween()
	_duck_tween.tween_property(_player, "volume_db", _target_db(), DUCK_SECS)


func _make_player() -> AudioStreamPlayer:
	var p: AudioStreamPlayer = AudioStreamPlayer.new()
	p.bus = "Master"
	p.volume_db = SILENT_DB
	add_child(p)
	return p


# Asks for a playlist. A request matching what is already playing does NOTHING — this is the whole
# point of the service, and the reason a storyboard can call it on every line without thinking.
#
# `volume` still applies to a matching request: an author may reuse one track at two levels, and that
# is a change worth making without restarting the music.
func play_playlist(tracks: Array, volume: float = 0.6) -> void:
	var cleaned: Array = []
	for t: Variant in tracks:
		if str(t) != "":
			cleaned.append(str(t))

	if cleaned.is_empty():
		stop()
		return

	# Asking for music implies wanting to hear it: a request arriving while paused for a round lifts the
	# pause, whether or not the track itself is changing.
	resume()

	if cleaned == _current:
		_volume = volume
		if not _paused:
			_player.volume_db = _target_db()
		return

	_current = cleaned
	_volume = volume
	_build_order()
	_order_index = 0
	_paused = false
	_crossfade_to(_current[_order[0]])


# Convenience for the single-clip case (a setting's theme, a line's own music).
func play_clip(clip: String, volume: float = 0.6) -> void:
	if clip == "":
		stop()
		return
	play_playlist([clip], volume)


# Silence, with the same fade a change gets so music never simply vanishes.
func stop() -> void:
	if _current.is_empty():
		return
	_current = []
	_order.clear()
	_order_index = 0
	_paused = false
	_ducked = false  # nothing to hold down once the score is gone
	_swap_players()
	_fade_out_fading()


# Holds the track where it is — for a playable round, whose own audio owns the space. The position is
# kept, so resume() picks the score back up mid-phrase instead of restarting it.
func pause() -> void:
	if _paused or _current.is_empty():
		return
	_paused = true
	_kill_tween()
	_player.stream_paused = true
	_fading.stream_paused = true


func resume() -> void:
	if not _paused:
		return
	_paused = false
	_player.stream_paused = false
	_fading.stream_paused = false
	_player.volume_db = _target_db()


func is_playing() -> bool:
	return not _current.is_empty()


# Brings `path` in on the idle player while the other fades out. A stream that fails to load leaves the
# service silent rather than half-faded into nothing.
func _crossfade_to(path: String) -> void:
	# JourneyAudio, not load(): a journey's pooled media lives at an absolute filesystem path
	# (G:/journeys/…/content/…), and the resource loader only resolves res:// and user://. This is the
	# same helper the storyboard's own BGM used before the music moved here.
	var stream: AudioStream = JourneyAudio.load_from_file(path)
	if stream == null:
		push_warning("SettingMusic: could not load %s" % path)
		stop()
		return

	# A lone track loops in the engine, seamlessly. A playlist must NOT — each track has to end for
	# _process to bring the next one in, or the first track would play forever.
	JourneyAudio.set_loop(stream, _current.size() == 1)

	_swap_players()
	_player.stream = stream
	_player.volume_db = SILENT_DB
	_player.play()

	_kill_tween()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_player, "volume_db", _target_db(), CROSSFADE_SECS)
	_tween.tween_property(_fading, "volume_db", SILENT_DB, CROSSFADE_SECS)
	_tween.chain().tween_callback(func() -> void: _fading.stop())


func _fade_out_fading() -> void:
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(_fading, "volume_db", SILENT_DB, CROSSFADE_SECS)
	_tween.tween_callback(func() -> void: _fading.stop())


func _swap_players() -> void:
	var previous: AudioStreamPlayer = _player
	_player = _fading
	_fading = previous


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()


# Shuffles the play order, reshuffling on each pass so a track never immediately repeats across the
# seam. A one-track playlist simply loops.
func _build_order() -> void:
	_order.clear()
	for i: int in _current.size():
		_order.append(i)
	_order.shuffle()


func _process(_delta: float) -> void:
	# Advance the playlist when a track ends. Polled rather than driven by `finished`, because the
	# players swap roles on every crossfade and a signal connection would have to follow them around.
	if _current.is_empty() or _paused:
		return
	if _player.playing or _player.stream == null:
		return
	if _current.size() == 1:
		# A lone track normally loops in the engine and never reaches here. This catches the formats
		# where the loop flag does not take, so a single-track score restarts instead of falling silent.
		_player.play()
		return
	_order_index += 1
	if _order_index >= _order.size():
		_build_order()
		_order_index = 0
	_crossfade_to(_current[_order[_order_index]])
