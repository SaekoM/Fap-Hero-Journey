class_name BossAudioCues
extends Node
## Plays a boss timeline's AUDIO — one-shot sfx and narration cues, plus the encounter's looping BGM
## (BOSS_ROUND_DESIGN §3.2). Presentation only, like BossCueLayer: it is handed resolved paths and told
## when to play them.
##
## Ducking is the part worth explaining. A narration line played flat sits underneath the round's own
## audio and is simply not heard, so a cue may ask the rest of the mix to step back while it speaks.
## The duck is applied to the ROUND VIDEO and the BGM through a caller-supplied setter rather than by
## touching an audio bus: the video's volume already belongs to the GameLoop (fades, pause muffle,
## override handover all move it), and a second owner writing the same property would fight them.
## The caller therefore says how loud the round should be, and keeps its own bookkeeping intact.
##
## Overlapping ducks are reference-counted by depth: two narration cues at once duck once, and the mix
## comes back only when the last of them finishes.

# Player pool ceiling. Cues are short and rarely overlap; past this the OLDEST is recycled so a dense
# stretch of timeline cannot spawn players without bound.
const MAX_VOICES: int = 6

# Silence, in dB — what a fully ducked (duck_pct 1.0) mix drops to.
const SILENCE_DB: float = -60.0

## Emitted whenever the round's audio should change level, as a 0..1 factor of its normal volume.
## The GameLoop applies it to the video (and anything else it owns), so this node never writes a
## volume it does not own.
signal duck_changed(factor: float)

var _bgm: AudioStreamPlayer = null
var _voices: Array[AudioStreamPlayer] = []

# Deepest duck currently requested, and how many cues are asking for one. Depth is tracked separately
# from the count so releasing a shallow duck cannot undo a deeper one still in effect.
var _duck_requests: Array[float] = []


func _exit_tree() -> void:
	stop_all()


## Plays one audio cue: `{clip, volume, kind, duck_pct, duck_fade_ms}` with `clip` already resolved.
## A cue with no clip is a no-op — validation reports it as an authoring problem; playback just skips it.
func play_cue(cue: Dictionary) -> void:
	var stream: AudioStream = JourneyAudio.load_from_file(str(cue.get("clip", "")))
	if stream == null:
		return
	var player: AudioStreamPlayer = _take_voice()
	player.stream = stream
	player.volume_db = linear_to_db(maxf(0.0001, float(cue.get("volume", 1.0))))

	var duck: float = clampf(float(cue.get("duck_pct", 0.0)), 0.0, 1.0)
	if duck > 0.0:
		_push_duck(duck)
		# Released when the clip ends — including when a recycled player is cut short, since finished
		# fires on stop() too. ONE_SHOT so a recycled player never carries a stale handler.
		player.finished.connect(func() -> void: _pop_duck(duck), CONNECT_ONE_SHOT)
	player.play()


## Starts the encounter's looping music. `{clip, volume}`, resolved. Replaces anything already playing.
func play_bgm(bgm: Dictionary) -> void:
	stop_bgm()
	var stream: AudioStream = JourneyAudio.load_from_file(str(bgm.get("clip", "")))
	if stream == null:
		return
	JourneyAudio.set_loop(stream, true)  # loop lives on the STREAM, not the player
	_bgm = AudioStreamPlayer.new()
	_bgm.stream = stream
	_bgm.volume_db = linear_to_db(maxf(0.0001, float(bgm.get("volume", 1.0))))
	add_child(_bgm)
	_bgm.play()


func stop_bgm() -> void:
	if is_instance_valid(_bgm):
		_bgm.queue_free()
	_bgm = null


## Everything off, and the mix handed back at full volume — the round ended or was cut short.
func stop_all() -> void:
	stop_bgm()
	for voice: AudioStreamPlayer in _voices:
		if is_instance_valid(voice):
			voice.stop()
	_duck_requests.clear()
	duck_changed.emit(1.0)


# ── Ducking ──────────────────────────────────────────────────────────────────


func _push_duck(amount: float) -> void:
	_duck_requests.append(amount)
	_emit_duck()


func _pop_duck(amount: float) -> void:
	var at: int = _duck_requests.find(amount)
	if at >= 0:
		_duck_requests.remove_at(at)
	_emit_duck()


# The deepest outstanding request wins, so overlapping cues never stack into silence and releasing one
# cannot lift a duck another still wants.
func _emit_duck() -> void:
	var deepest: float = 0.0
	for amount: float in _duck_requests:
		deepest = maxf(deepest, amount)
	duck_changed.emit(1.0 - deepest)


## The dB a ducked round should sit at, for a caller that mixes in dB rather than linear.
static func duck_db(factor: float) -> float:
	return SILENCE_DB if factor <= 0.001 else linear_to_db(factor)


# ── Voices ───────────────────────────────────────────────────────────────────


# An idle player if there is one, else a new one, else the oldest recycled. Recycling stops whatever it
# was playing, which releases that cue's duck through the finished handler.
func _take_voice() -> AudioStreamPlayer:
	for voice: AudioStreamPlayer in _voices:
		if is_instance_valid(voice) and not voice.playing:
			return voice
	if _voices.size() < MAX_VOICES:
		var voice: AudioStreamPlayer = AudioStreamPlayer.new()
		add_child(voice)
		_voices.append(voice)
		return voice
	var oldest: AudioStreamPlayer = _voices[0]
	_voices.remove_at(0)
	_voices.append(oldest)
	oldest.stop()
	return oldest
