extends Node

# ---------------------------------------------------------------------------
# UISound  (autoload)
#
# Lightweight UI feedback blips. The waveforms are SYNTHESIZED into in-memory
# AudioStreamWAV resources at startup — no audio files are shipped or imported.
# That fits the synthwave aesthetic (everything's a synth blip), avoids any
# asset/licensing management, and keeps every sound tweakable from code.
#
# Click is auto-wired to EVERY BaseButton in the app via the SceneTree's
# node_added signal, so buttons get sound with zero per-scene wiring — including
# ones built dynamically (the builder, modals, the shop, …). Screens can also
# call the semantic helpers (hover / confirm / back / error) at meaningful
# moments — hover is intentionally NOT auto-played (too chatty across button rows).
#
# Gated by SettingsService ui_sound_enabled / ui_sound_volume; call
# reload_settings() after the Options toggle changes them.
# ---------------------------------------------------------------------------

const MIX_RATE: int = 44100
const POOL_SIZE: int = 6  # concurrent one-shots before the pool round-robins
const PITCH_SCALE: float = 1.0  # 1.0 plays samples at natural pitch; <1 pitches every blip down
const PITCH_VARIATION: float = 0.08  # ±fraction of random pitch jitter per play, so repeats don't sound identical

# Real UI click sample. Loaded if present; otherwise the synth tick is used.
const CLICK_OGG_PATH: String = "res://assets/sfx/click.ogg"
# Storyboard dialogue-advance sample. Falls back to the click sound if missing.
const STORYBOARD_WAV_PATH: String = "res://assets/sfx/storyboard click.wav"
# Event samples (silent if a file is missing — they're all imported normally).
const ITEM_USE_WAV_PATH: String = "res://assets/sfx/item use.wav"
const JOURNEY_WAV_PATH: String = "res://assets/sfx/journey click.wav"
const START_JOURNEY_WAV_PATH: String = "res://assets/sfx/start journey click.wav"
const GAME_COMPLETE_WAV_PATH: String = "res://assets/sfx/game complete.wav"
const LATCH_OPEN_WAV_PATH: String = "res://assets/sfx/latch_open.wav"

var _streams: Dictionary = {}  # kind -> AudioStreamWAV
var _players: Array[AudioStreamPlayer] = []
var _next_player: int = 0

# Instance-ids of buttons we've already wired, so a re-parented button isn't
# double-connected. Cleared per-button on tree_exited.
var _wired: Dictionary = {}

var _enabled: bool = true
var _volume_db: float = 0.0
# Game sounds have their own switch and volume (Options → GAME SOUNDS), apart from the UI blips.
var _game_enabled: bool = true
var _game_volume_db: float = 0.0

# Decibels added to a sound on top of its category's volume. The latch sample is one sharp transient: its
# peak is near full scale but it carries little energy, so it reads as quiet next to the other sounds.
const GAIN_DB: Dictionary = {"latch_open": 8.0}

# The sounds that belong to play rather than to menus: in-play events and mini-game feedback. Every other
# kind is a UI sound. Which switch and volume a sound obeys is decided by this list alone.
const GAME_SOUNDS: Array[String] = [
	"item_use",
	"game_complete",
	"dial_tick",
	"dial_wrong",
	"dial_open",
	"latch_open",
	"wheel_tick",
	"win_sting",
	"win_harmony",
	"jackpot_sting",
	"banked",
	"bust_sting",
	"gauge_creak",
	"gauge_near_miss",
	"gauge_burst",
	"gauge_pop",
	"gauge_shatter",
	"gauge_steam",
	"gauge_heartbreak",
	"gauge_heartbeat",
	"stack_clatter",
	"stack_spill",
	"stack_tumble",
	"stack_close_call",
	"gauge_shield_block",
]


func _ready() -> void:
	# Survive the game pause (boss intro, shops, options) so menu clicks during a
	# paused round still sound.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_build_streams()
	for i in POOL_SIZE:
		var p: AudioStreamPlayer = AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)

	reload_settings()

	# Wire every button — those already in the tree, and all future ones.
	get_tree().node_added.connect(_on_node_added)
	_wire_existing(get_tree().root)


# Re-read the enabled / volume settings (call after the Options control changes).
func reload_settings() -> void:
	_enabled = SettingsService.get_ui_sound_enabled()
	_volume_db = linear_to_db(clampf(SettingsService.get_ui_sound_volume(), 0.0001, 1.0))
	_game_enabled = SettingsService.get_game_sound_enabled()
	_game_volume_db = linear_to_db(clampf(SettingsService.get_game_sound_volume(), 0.0001, 1.0))


# ── Public play API ──────────────────────────────────────────────────────────


func click() -> void:
	_play("click")


func storyboard() -> void:
	_play("storyboard")


func item_use() -> void:
	_play("item_use")


func journey() -> void:
	_play("journey")


func start_journey() -> void:
	_play("start_journey")


func game_complete() -> void:
	_play("game_complete")


func hover() -> void:
	_play("hover")


func confirm() -> void:
	_play("confirm")


func back() -> void:
	_play("back")


func error() -> void:
	_play("error")


# ── Mini-game sounds ──────────────────────────────────────────────────────────
# Game sounds (see GAME_SOUNDS): Safe-Cracker's dial tick is the hint a player hears when the warmth meter
# is off. The tick plays at the pitch it is given, with no random jitter, because its pitch IS the
# information.


# One notch of the dial. `pitch` rises as the dial nears the number (MiniGameScreen maps warmth to it).
func dial_tick(pitch: float) -> void:
	_play_unjittered("dial_tick", pitch)


# A try on the wrong number: a dull, low thunk.
func dial_wrong() -> void:
	_play_unjittered("dial_wrong", 1.0)


# A mechanical clunk resolving up into a chime: the cue for switching game sounds on, and the latch's stand-in
# if its sample is missing.
func dial_open() -> void:
	_play_unjittered("dial_open", 1.0)


# A lock giving way: a Safe-Cracker number opened.
func latch_open() -> void:
	_play_unjittered("latch_open", 1.0)


# Double or Nothing's wheel passing a slice under the pointer. `pitch` falls as the wheel slows.
func wheel_tick(pitch: float) -> void:
	_play_unjittered("wheel_tick", pitch)


# The wheel landed on WIN: a rising flourish. `pitch` climbs with the rung reached, and a `full` win (a
# high rung) layers a harmony over it, so rung 4 sounds bigger than rung 1.
func win_sting(pitch: float, full: bool) -> void:
	_play_unjittered("win_sting", pitch)
	if full:
		_play_unjittered("win_harmony", pitch)


# The top rung: a long, bright run of its own.
func jackpot_sting() -> void:
	_play_unjittered("jackpot_sting", 1.0)


# Cashing out: a short two-note "banked" chime — pleased, not triumphant.
func banked() -> void:
	_play_unjittered("banked", 1.0)


# The wheel landed on BUST: a falling drop.
func bust_sting() -> void:
	_play_unjittered("bust_sting", 1.0)


# Hold & Release's gauge nearing its limit: a dull strain, rising in `pitch` as it gets closer.
func gauge_creak(pitch: float) -> void:
	_play_unjittered("gauge_creak", pitch)


# Let go just past the limit: a short falling groan.
func gauge_near_miss() -> void:
	_play_unjittered("gauge_near_miss", 1.0)


# The ways a full gauge fails, one per container.
func gauge_burst() -> void:
	_play_unjittered("gauge_burst", 1.0)


func gauge_pop() -> void:
	_play_unjittered("gauge_pop", 1.0)


func gauge_shatter() -> void:
	_play_unjittered("gauge_shatter", 1.0)


func gauge_steam() -> void:
	_play_unjittered("gauge_steam", 1.0)


# The heart's warning, in place of the creak.
func gauge_heartbeat(pitch: float) -> void:
	_play_unjittered("gauge_heartbeat", pitch)


func gauge_heartbreak() -> void:
	_play_unjittered("gauge_heartbreak", 1.0)


# The ways Push Your Luck's stack comes down, one per look.
func stack_clatter() -> void:
	_play_unjittered("stack_clatter", 1.0)


func stack_spill() -> void:
	_play_unjittered("stack_spill", 1.0)


func stack_tumble() -> void:
	_play_unjittered("stack_tumble", 1.0)


# Surviving a risky push: a quick, relieved rise.
func stack_close_call() -> void:
	_play_unjittered("stack_close_call", 1.0)


# A shield taking a trap: a hard knock that rings off.
func gauge_shield_block() -> void:
	_play_unjittered("gauge_shield_block", 1.0)


func _play_unjittered(kind: String, pitch: float) -> void:
	_start(kind, pitch)


func _play(kind: String) -> void:
	_start(kind, PITCH_SCALE * randf_range(1.0 - PITCH_VARIATION, 1.0 + PITCH_VARIATION))


# Plays `kind` at `pitch`, under the switch and volume of its category (game or UI).
func _start(kind: String, pitch: float) -> void:
	var is_game: bool = kind in GAME_SOUNDS
	if not (_game_enabled if is_game else _enabled):
		return
	var stream: AudioStream = _streams.get(kind)
	if stream == null:
		return
	var p: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % _players.size()
	p.stream = stream
	p.volume_db = (_game_volume_db if is_game else _volume_db) + float(GAIN_DB.get(kind, 0.0))
	p.pitch_scale = pitch
	p.play()


# ── Global button wiring ──────────────────────────────────────────────────────


func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		_wire_button(node)


func _wire_existing(root: Node) -> void:
	for child in root.get_children():
		if child is BaseButton:
			_wire_button(child)
		_wire_existing(child)


func _wire_button(btn: BaseButton) -> void:
	var id: int = btn.get_instance_id()
	if _wired.has(id):
		return
	_wired[id] = true
	# ONE_SHOT because tree_exited also fires on a REPARENT (remove_child +
	# add_child) — the button then comes back through _on_node_added and gets
	# re-wired, so the eviction hook must not accumulate one lambda per move.
	btn.tree_exited.connect(func() -> void: _wired.erase(id), CONNECT_ONE_SHOT)
	# Muted buttons play their own custom sound at the call site (e.g. Play /
	# Resume play start_journey on embark), so skip the default click here.
	if btn.has_meta("ui_sound_muted") and bool(btn.get_meta("ui_sound_muted")):
		return
	# `pressed` fires on enabled buttons only, so disabled controls stay silent.
	# (hover() stays available for screens that want it explicitly.) The signal
	# connection SURVIVES a reparent while the _wired guard resets with it, so
	# re-wires must check before connecting.
	if not btn.pressed.is_connected(click):
		btn.pressed.connect(click)


# Stops a button from auto-playing the default click — for buttons that trigger a
# custom or deferred sound themselves. Works whether called before or after the
# button was wired (disconnects an existing click hookup if present).
func mute_button(btn: BaseButton) -> void:
	if btn == null:
		return
	btn.set_meta("ui_sound_muted", true)
	if btn.pressed.is_connected(click):
		btn.pressed.disconnect(click)


# Loads an AudioStream resource if it exists and imported cleanly, else null.
func _load_stream(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	return res if res is AudioStream else null


# ── Synthesis ─────────────────────────────────────────────────────────────────


func _build_streams() -> void:
	# Each blip is a short tone (or note sequence) with a quick attack + decay.
	# Frequencies are musical so they read as intentional, not beeps. Hover is
	# quiet so a mouse sweep across a button row stays unobtrusive.
	_streams["hover"] = _make_blip([1046.5], 0.045, 0.14, "sine")
	# Click: prefer the real sample at CLICK_OGG_PATH; fall back to the synth noise
	# tick when it's missing or not yet imported (so the app always has UI sound).
	var click_sample: AudioStream = _load_stream(CLICK_OGG_PATH)
	if click_sample != null:
		_streams["click"] = click_sample
	else:
		_streams["click"] = _make_blip([2500.0], 0.032, 0.85, "noise")

	# Storyboard dialogue advance — its own sample, else reuse the click.
	var story_sample: AudioStream = _load_stream(STORYBOARD_WAV_PATH)
	_streams["storyboard"] = story_sample if story_sample != null else _streams["click"]

	# Event samples (no fallback — a missing one is simply silent).
	_streams["item_use"] = _load_stream(ITEM_USE_WAV_PATH)
	_streams["journey"] = _load_stream(JOURNEY_WAV_PATH)
	_streams["start_journey"] = _load_stream(START_JOURNEY_WAV_PATH)
	_streams["game_complete"] = _load_stream(GAME_COMPLETE_WAV_PATH)
	_streams["confirm"] = _make_blip([659.3, 987.8, 1318.5], 0.16, 0.30, "sine")
	_streams["back"] = _make_blip([659.3, 440.0], 0.12, 0.28, "sine")
	_streams["error"] = _make_blip([196.0, 185.0], 0.20, 0.30, "square")
	# Safe-Cracker. The tick is a very short, bright noise click so a fast spin stays crisp.
	_streams["dial_tick"] = _make_blip([3200.0], 0.022, 0.75, "noise")
	_streams["dial_wrong"] = _make_blip([110.0, 98.0], 0.22, 0.32, "square")
	_streams["dial_open"] = _make_blip([392.0, 523.3, 784.0, 1046.5], 0.42, 0.34, "sine")
	var latch_sample: AudioStream = _load_stream(LATCH_OPEN_WAV_PATH)
	_streams["latch_open"] = latch_sample if latch_sample != null else _streams["dial_open"]
	# Double or Nothing. The tick is a little duller than the dial's so the two games sound apart.
	_streams["wheel_tick"] = _make_blip([2200.0], 0.02, 0.7, "noise")
	_streams["win_sting"] = _make_blip([523.3, 659.3, 784.0, 1046.5, 1318.5], 0.6, 0.34, "sine")
	_streams["bust_sting"] = _make_blip([392.0, 311.1, 233.1, 174.6], 0.65, 0.26, "saw")
	_streams["win_harmony"] = _make_blip([659.3, 784.0, 987.8, 1318.5, 1568.0], 0.6, 0.2, "sine")
	_streams["jackpot_sting"] = _make_blip(
		[523.3, 659.3, 784.0, 1046.5, 1318.5, 1568.0, 2093.0], 1.1, 0.36, "sine"
	)
	_streams["banked"] = _make_blip([784.0, 1046.5], 0.26, 0.3, "sine")
	# Hold & Release. For a noise wave, each "note" is a lowpass cutoff in Hz, so a falling list sounds like a thud
	# and a steady high one like a hiss.
	_streams["gauge_creak"] = _make_blip([420.0, 300.0], 0.14, 0.55, "noise")
	_streams["gauge_near_miss"] = _make_blip([233.1, 207.7, 185.0, 155.6], 0.55, 0.22, "saw")
	_streams["gauge_burst"] = _make_blip([1800.0, 700.0, 300.0], 0.4, 0.85, "noise")
	_streams["gauge_pop"] = _make_blip([6000.0, 1500.0], 0.12, 0.95, "noise")
	_streams["gauge_shatter"] = _make_blip([7000.0, 5000.0, 3000.0], 0.5, 0.7, "noise")
	_streams["gauge_steam"] = _make_blip([4000.0, 3600.0, 3200.0], 0.9, 0.35, "noise")
	_streams["gauge_heartbreak"] = _make_blip([5000.0, 1200.0, 500.0], 0.4, 0.85, "noise")
	_streams["gauge_heartbeat"] = _make_blip([80.0, 55.0], 0.22, 0.8, "sine")
	# Push Your Luck.
	_streams["stack_clatter"] = _make_blip([5200.0, 2600.0, 4200.0, 1800.0], 0.5, 0.8, "noise")
	_streams["stack_spill"] = _make_blip(
		[8000.0, 6500.0, 7500.0, 5500.0, 6000.0], 0.7, 0.55, "noise"
	)
	_streams["stack_tumble"] = _make_blip([900.0, 400.0, 700.0, 300.0], 0.6, 0.9, "noise")
	_streams["stack_close_call"] = _make_blip([440.0, 659.3], 0.24, 0.26, "sine")
	_streams["gauge_shield_block"] = _make_blip([1760.0, 1318.5, 1046.5], 0.4, 0.3, "square")


# Renders `notes` (played in equal time slices) into a mono 16-bit AudioStreamWAV.
# Phase is integrated continuously across note changes so segment boundaries don't
# click; a 3 ms attack + exponential decay shapes the whole blip.
func _make_blip(notes: Array, duration: float, amp: float, wave: String) -> AudioStreamWAV:
	var n: int = int(duration * MIX_RATE)
	var data: PackedByteArray = PackedByteArray()
	data.resize(n * 2)

	var phase: float = 0.0
	var lp: float = 0.0  # one-pole lowpass state (used by the "noise" wave)
	var seg: int = maxi(notes.size(), 1)
	const ATTACK: float = 0.003

	for i in n:
		var note_idx: int = clampi(int((float(i) / float(n)) * seg), 0, seg - 1)
		var freq: float = float(notes[note_idx])
		phase += TAU * freq / float(MIX_RATE)

		var s: float = 0.0
		match wave:
			"square":
				s = 1.0 if sin(phase) >= 0.0 else -1.0
			"saw":
				s = fmod(phase / TAU, 1.0) * 2.0 - 1.0
			"noise":
				# Neutral tick: white noise through a one-pole lowpass. For this
				# wave the "note" is the cutoff in Hz — lower = duller/softer.
				var alpha: float = clampf(1.0 - exp(-TAU * freq / float(MIX_RATE)), 0.0, 1.0)
				lp += alpha * (randf_range(-1.0, 1.0) - lp)
				s = lp
			_:
				s = sin(phase)

		var tt: float = float(i) / float(MIX_RATE)
		var env: float
		if tt < ATTACK:
			env = tt / ATTACK
		else:
			env = exp(-3.5 * (tt - ATTACK) / maxf(duration - ATTACK, 0.0001))

		var v: int = int(round(clampf(s * env * amp, -1.0, 1.0) * 32767.0))
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF

	var stream: AudioStreamWAV = AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	return stream
