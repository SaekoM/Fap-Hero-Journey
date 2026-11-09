class_name QuickTimeEventView
extends Control

# A Quick-Time Event over a boss round: rings closing on targets at random places on the screen, each naming
# the key to press, with its hit window drawn as a band round the target.
#
# It runs one of two ways, as its creator chooses. Over the playing video it follows the video's position.
# Holding the round, the video is paused and dimmed behind it, and it keeps its own clock and makes its own sounds.
#
# The rules live in QuickTimeEventGame. This view feeds the game its time, draws it, and reacts. GameLoop decides
# what a finished game means and tells it what to say.

# Holding the round: the game has been decided. GameLoop answers with show_result.
signal game_over
# Holding the round: the result has been shown, so the round can carry on.
signal released

const TARGET_RADIUS: float = 64.0
const RING_START_RADIUS: float = 250.0
const RING_SMALLEST_RADIUS: float = 6.0  # a late ring keeps closing; this keeps it drawable
const RING_WIDTH: float = 6.0
const RING_WIDTH_IN_WINDOW: float = 10.0  # thicker inside the window, whatever colours the creator picked
const TARGET_WIDTH: float = 3.0
const BAND_ALPHA: float = 0.35
const ARC_POINTS: int = 72
const KEY_FONT_SIZE: int = 44
# A hold or a mash: a small word under its key, so it reads as one before the ring lands.
const KIND_WORD_FONT_SIZE: int = 14
const KIND_WORD_OFFSET: float = 0.7  # of the key's font size, below its middle
# A hold: a fill that runs round the target once it's pressed.
const HOLD_FILL_WIDTH: float = 10.0
const HOLD_TRACK_ALPHA: float = 0.45
# A mash: the target fills from the middle out with each press, heating from the target's colour towards white-hot,
# trembling harder and throwing sparks as it nears full. A thin arc round it runs down with the time left.
const MASH_EMPTY_ALPHA: float = 0.15
const MASH_HOT: Color = Color(1.0, 0.96, 0.86)
const MASH_TREMBLE_MOST: float = 7.0
const MASH_PULSE_GROWTH: float = 0.12  # how much bigger the target swells on a press
const MASH_PULSE_DECAY: float = 7.0  # per second
const MASH_TIMER_GAP: float = 10.0  # between the target and its timer arc
const MASH_TIMER_WIDTH: float = 4.0
const MASH_KEY_OUTLINE: int = 6  # so the key stays readable over a white-hot fill
const MASH_TICK_PITCH_LOW: float = 0.8
const MASH_TICK_PITCH_HIGH: float = 1.6
const SPARKS_FROM: float = 0.75  # how full a mash is before its presses throw sparks
const SPARKS_PER_PRESS: int = 3
const SPARK_SPEED: Vector2 = Vector2(160.0, 320.0)  # slowest and fastest, pixels a second
const SPARK_LIFE_SECS: float = 0.35
const SPARK_LENGTH: float = 0.04  # of a second's travel, so faster sparks streak longer
const SPARK_WIDTH: float = 2.0

const DIM_ALPHA: float = 0.7
const DIM_SECS: float = 0.25

const CALLOUT_SIZE: Vector2 = Vector2(500.0, 60.0)
const CALLOUT_FONT_SIZE: int = 30
const CALLOUT_RISE: float = 34.0
const CALLOUT_SECS: float = 0.6
const RESULT_FONT_SIZE: int = 64
const RESULT_HOLD_SECS: float = 0.8
const RESULT_DETAIL_HOLD_SECS: float = 2.2
const RESULT_DETAIL_OFFSET: float = 70.0
const RESULT_FADE_SECS: float = 0.35

# The end of an event that guarded an attack: DODGED sweeps a streak across the screen and bursts; HIT reddens
# the edges and shakes everything this view draws. Never the video itself.
const STAMP_START_SCALE: float = 2.2
const STAMP_SECS: float = 0.22
const STAMP_TILT: float = -0.1
const SWEEP_SECS: float = 0.45
const SWEEP_WIDTH: float = 0.18  # of the screen's width
const SWEEP_SLANT: float = 0.12  # of the screen's width, top to bottom
const SWEEP_ALPHA: float = 0.35
const VIGNETTE_STEPS: int = 10
const VIGNETTE_STEP_WIDTH: float = 0.012  # of the screen's shorter side, per step
const VIGNETTE_PEAK_ALPHA: float = 0.6
const VIGNETTE_GENTLE_ALPHA: float = 0.35  # under REDUCE FLASHING, which also fades it in
const VIGNETTE_RISE_SECS: float = 0.3
const VIGNETTE_FADE_SECS: float = 0.9
const SHAKE_STEP_SECS: float = 0.05
const SHAKE_OFFSETS: Array[float] = [-14.0, 12.0, -9.0, 6.0, -3.0, 0.0]
const DODGED_STING_PITCH: float = 1.2
const NOT_STARTED: float = -1.0

# How dark the screen is behind the rings, 0–1.
var dim: float = 0.0:
	set(value):
		dim = value
		queue_redraw()

var _game: QuickTimeEventGame
var _holds_round: bool = false
var _game_over_sent: bool = false
var _start_ms: int = 0
var _last_position_ms: int = 0
var _clock_ms: float = 0.0
var _announced: Dictionary = {}  # prompt index → true once the player has been told how it went
var _ring_colour: Color = Color.WHITE
var _target_colour: Color = Color.WHITE
var _size_scale: float = 1.0

var _sweep: float = NOT_STARTED
var _vignette: float = 0.0
var _shake_x: float = 0.0
var _mash_pulse: float = 0.0  # 1 on a mash press, dying away
var _sparks: Array[Dictionary] = []  # {at, velocity, life} for the sparks a mash throws


# Over the playing video. `start_ms` is where this game starts on it.
func setup(game: QuickTimeEventGame, knobs: Dictionary, start_ms: int) -> void:
	_start_ms = start_ms
	_last_position_ms = start_ms
	_apply(game, knobs)


# Holding the round, on its own clock. GameLoop has paused the video.
func setup_held(game: QuickTimeEventGame, knobs: Dictionary) -> void:
	_holds_round = true
	_apply(game, knobs)
	create_tween().tween_property(self, "dim", DIM_ALPHA, DIM_SECS)


func _apply(game: QuickTimeEventGame, knobs: Dictionary) -> void:
	_game = game
	_ring_colour = Color.html(str(knobs["ring_color"]))
	_target_colour = Color.html(str(knobs["target_color"]))
	_size_scale = int(knobs["size_pct"]) / 100.0
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_age_mash_effects(delta)
	if not _holds_round or _game_over_sent:
		return
	_clock_ms += delta * 1000.0
	_game.advance_to(int(_clock_ms))
	_announce_decided_prompts()
	queue_redraw()
	if _game.is_finished():
		_game_over_sent = true
		game_over.emit()


# ── What the round tells it ──────────────────────────────────────────────────


func advance_to(position_ms: int) -> void:
	_last_position_ms = position_ms
	_clock_ms = position_ms - _start_ms
	_game.advance_to(int(_clock_ms))
	_announce_decided_prompts()
	queue_redraw()


# `key` at `position_ms` of the video. Returns whether it landed on a prompt.
func press(position_ms: int, key: String) -> bool:
	return _press_at(position_ms - _start_ms, key)


# `key` right now, while holding the round. Returns whether it landed on a prompt.
func press_held(key: String) -> bool:
	return _press_at(int(_clock_ms), key)


# `key` let go at `position_ms` of the video. Returns whether it ended a hold.
func release(position_ms: int, key: String) -> bool:
	return _release_at(position_ms - _start_ms, key)


# `key` let go right now, while holding the round. Returns whether it ended a hold.
func release_held(key: String) -> bool:
	return _release_at(int(_clock_ms), key)


func _press_at(t_ms: int, key: String) -> bool:
	var index: int = _game.showing_prompt(t_ms)
	var result: float = _game.press(t_ms, key)
	var is_mash: bool = (
		index >= 0 and str(_game.prompts[index]["kind"]) == QuickTimeEventGame.PROMPT_MASH
	)
	if is_mash and result != QuickTimeEventGame.IGNORED:
		_on_mash_press(index)
	return _answered(result)


# Every press a mash takes is felt: the target swells and springs back, a tick rises in pitch while the round is
# held, and once it's nearly full, sparks fly off it.
func _on_mash_press(index: int) -> void:
	var filled: float = _game.mash_progress(index)
	_mash_pulse = 1.0
	if _holds_round:
		UISound.dial_tick(lerpf(MASH_TICK_PITCH_LOW, MASH_TICK_PITCH_HIGH, filled))
	if filled < SPARKS_FROM:
		return
	var center: Vector2 = _prompt_center(index)
	var radius: float = _target_radius() * filled
	for _spark in SPARKS_PER_PRESS:
		var direction: Vector2 = Vector2.from_angle(randf() * TAU)
		var speed: float = randf_range(SPARK_SPEED.x, SPARK_SPEED.y)
		_sparks.append(
			{"at": center + direction * radius, "velocity": direction * speed, "life": 1.0}
		)


func _age_mash_effects(delta: float) -> void:
	if _mash_pulse <= 0.0 and _sparks.is_empty():
		return
	_mash_pulse = maxf(0.0, _mash_pulse - MASH_PULSE_DECAY * delta)
	for spark: Dictionary in _sparks:
		spark["at"] += spark["velocity"] * delta
		spark["life"] = float(spark["life"]) - delta / SPARK_LIFE_SECS
	var alive: Array[Dictionary] = []
	for spark: Dictionary in _sparks:
		if float(spark["life"]) > 0.0:
			alive.append(spark)
	_sparks = alive
	queue_redraw()


func _release_at(t_ms: int, key: String) -> bool:
	return _answered(_game.release(t_ms, key))


# Whether a press or release did anything, refreshing what's shown when it did.
func _answered(result: float) -> bool:
	if result == QuickTimeEventGame.IGNORED:
		return false
	_announce_decided_prompts()
	queue_redraw()
	return true


# Whether the round played through to `position_ms` from where this last saw it, rather than jumping there.
# A game skipped by a seek, or rewound by a replay, was never really played and must not count.
func played_through_to(position_ms: int) -> bool:
	var moved: int = position_ms - _last_position_ms
	return moved >= 0 and moved <= RoundTimelineScheduler.MAX_CATCHUP_MS


func score() -> int:
	return _game.score()


# The game is over: says how it went, with any words the creator wrote for this result, lets the round go, and
# removes itself. Words stay up longer, so they can be read.
func show_result(text: String, colour: Color, detail: String = "") -> Label:
	_clock_ms = float(_game.prompts[-1]["close_ms"]) + 1.0
	queue_redraw()
	var label: Label = _callout(text, colour, RESULT_FONT_SIZE, size / 2.0)
	var leave: Tween = create_tween()
	leave.tween_interval(RESULT_HOLD_SECS if detail == "" else RESULT_DETAIL_HOLD_SECS)
	leave.tween_property(label, "modulate:a", 0.0, RESULT_FADE_SECS)
	if detail != "":
		var words: Label = _callout(
			detail,
			UITheme.WHITE_SOFT,
			UITheme.story_font_size(CALLOUT_FONT_SIZE),
			size / 2.0 + Vector2(0.0, RESULT_DETAIL_OFFSET)
		)
		words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		leave.parallel().tween_property(words, "modulate:a", 0.0, RESULT_FADE_SECS)
	leave.parallel().tween_property(self, "dim", 0.0, RESULT_FADE_SECS)
	leave.tween_callback(released.emit)
	leave.tween_callback(queue_free)
	return label


# The end of an event that guarded an attack, staged: DODGED stamps down with a streak sweeping across and a
# burst; HIT stamps down with red edges and a shake. Sounds only while the round is held, as ever.
func show_dodge_result(dodged: bool, detail: String = "") -> void:
	var label: Label = show_result(
		"DODGED" if dodged else "HIT", UITheme.AMBER if dodged else UITheme.DANGER, detail
	)
	_stamp(label)
	if dodged:
		_sweep = 0.0
		create_tween().tween_property(self, "_sweep", 1.0, SWEEP_SECS).set_trans(Tween.TRANS_CUBIC)
		MiniGameFx.burst(self, size / 2.0, 1.0)
		if _holds_round:
			UISound.win_sting(DODGED_STING_PITCH, true)
		return
	_redden_edges()
	var shake: Tween = create_tween()
	for offset: float in SHAKE_OFFSETS:
		shake.tween_property(self, "_shake_x", offset, SHAKE_STEP_SECS)
	if _holds_round:
		UISound.bust_sting()


# The word lands from large and tilted, like a stamp.
func _stamp(label: Label) -> void:
	label.pivot_offset = label.size / 2.0
	label.scale = Vector2(STAMP_START_SCALE, STAMP_START_SCALE)
	label.rotation = STAMP_TILT
	var landing: Tween = label.create_tween()
	(
		landing
		. tween_property(label, "scale", Vector2.ONE, STAMP_SECS)
		. set_trans(Tween.TRANS_BACK)
		. set_ease(Tween.EASE_OUT)
	)


# Red creeps in from the screen's edges and fades. Under REDUCE FLASHING it rises gently and stays fainter.
func _redden_edges() -> void:
	var gentle: bool = SettingsService.get_reduce_flashing()
	var peak: float = VIGNETTE_GENTLE_ALPHA if gentle else VIGNETTE_PEAK_ALPHA
	var redden: Tween = create_tween()
	if gentle:
		redden.tween_property(self, "_vignette", peak, VIGNETTE_RISE_SECS)
	else:
		_vignette = peak
	redden.tween_property(self, "_vignette", 0.0, VIGNETTE_FADE_SECS)


# ── Feedback ─────────────────────────────────────────────────────────────────


func _announce_decided_prompts() -> void:
	for i in _game.prompts.size():
		var accuracy: float = float(_game.prompts[i]["accuracy"])
		if accuracy >= 0.0 and not _announced.has(i):
			_announced[i] = true
			_announce(i, accuracy, _prompt_center(i))


# Words as well as colour say how a prompt went, so it reads in every colour mode. Sounds only play while the round
# is held: over a playing round, the video's own sound is what the player should be hearing.
func _announce(index: int, accuracy: float, at: Vector2) -> void:
	if accuracy <= 0.0:
		if _holds_round:
			UISound.dial_wrong()
		_float_callout("MISS", UITheme.DANGER, at)
		return
	if _holds_round:
		UISound.banked()
	# A filled mash has its own moment: the biggest burst, and no words over it.
	if str(_game.prompts[index]["kind"]) == QuickTimeEventGame.PROMPT_MASH:
		MiniGameFx.burst(self, at, 1.0)
		return
	MiniGameFx.burst(self, at, accuracy)
	var perfect: bool = accuracy >= QuickTimeEventGame.PERFECT_ACCURACY
	_float_callout(
		"PERFECT" if perfect else "GOOD", UITheme.AMBER if perfect else UITheme.WHITE_SOFT, at
	)


func _float_callout(text: String, colour: Color, at: Vector2) -> void:
	var above: Vector2 = at + Vector2(0.0, -_target_radius() - CALLOUT_RISE)
	var label: Label = _callout(text, colour, CALLOUT_FONT_SIZE, above)
	var drift: Tween = label.create_tween().set_parallel(true)
	drift.tween_property(label, "position:y", label.position.y - CALLOUT_RISE, CALLOUT_SECS)
	drift.tween_property(label, "modulate:a", 0.0, CALLOUT_SECS)
	drift.chain().tween_callback(label.queue_free)


func _callout(text: String, colour: Color, font_size: int, center: Vector2) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size = CALLOUT_SIZE
	label.position = center - CALLOUT_SIZE / 2.0
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.style_label(label, colour, font_size)
	add_child(label)
	return label


# ── Drawing ──────────────────────────────────────────────────────────────────


# Where a prompt's target sits on the screen. The game holds it as a fraction of the screen.
func _prompt_center(index: int) -> Vector2:
	var prompt: Dictionary = _game.prompts[index]
	return Vector2(float(prompt["x"]), float(prompt["y"])) * size


func _target_radius() -> float:
	return TARGET_RADIUS * _size_scale


func _draw() -> void:
	if dim > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, dim))
	if _vignette > 0.0:
		_draw_vignette()
	if _game == null:
		return
	if _sweep >= 0.0 and _sweep < 1.0:
		_draw_sweep()
	draw_set_transform(Vector2(_shake_x, 0.0))
	_draw_sparks()
	var index: int = _game.showing_prompt(int(_clock_ms))
	if index < 0:
		return
	var center: Vector2 = _prompt_center(index)
	var prompt: Dictionary = _game.prompts[index]
	var is_mash: bool = str(prompt["kind"]) == QuickTimeEventGame.PROMPT_MASH
	if is_mash and int(_clock_ms) >= int(prompt["target_ms"]):
		_draw_mash(index, center)
		return
	if _game.is_holding(prompt):
		_draw_hold_fill(center, _game.hold_progress(index, int(_clock_ms)))
		_draw_key_label(center, str(prompt["key"]))
		return
	var progress: float = _game.ring_progress(index, int(_clock_ms))
	var band: float = _game.hit_band(index)
	if not is_mash:
		_draw_hit_band(center, band)  # a mash has no hit window: it starts when the ring lands
	# A hold's target is the empty track its fill will run along, thick where a press's outline is thin, and a mash's
	# is the faint disc it will fill, so the three read apart from the moment the ring appears.
	if str(prompt["kind"]) == QuickTimeEventGame.PROMPT_HOLD:
		_draw_hold_fill(center, 0.0)
	elif is_mash:
		draw_circle(center, _target_radius(), Color(_target_colour, MASH_EMPTY_ALPHA))
		draw_arc(center, _target_radius(), 0.0, TAU, ARC_POINTS, _target_colour, TARGET_WIDTH, true)
	else:
		draw_arc(center, _target_radius(), 0.0, TAU, ARC_POINTS, _target_colour, TARGET_WIDTH, true)
	var in_window: bool = not is_mash and absf(progress - 1.0) <= band
	draw_arc(
		center,
		_ring_radius(progress),
		0.0,
		TAU,
		ARC_POINTS,
		_ring_colour,
		RING_WIDTH_IN_WINDOW if in_window else RING_WIDTH,
		true
	)
	match str(prompt["kind"]):
		QuickTimeEventGame.PROMPT_MASH:
			_draw_key_label(center, str(prompt["key"]))
			_draw_kind_word(center, "MASH")
		QuickTimeEventGame.PROMPT_HOLD:
			_draw_key_label(center, str(prompt["key"]))
			_draw_kind_word(center, "HOLD")
		_:
			_draw_key_label(center, str(prompt["key"]))


# Where the ring has to be for a press to count.
func _draw_hit_band(center: Vector2, band: float) -> void:
	var outer: float = _ring_radius(maxf(0.0, 1.0 - band))
	var inner: float = _ring_radius(1.0 + band)
	draw_arc(
		center,
		(outer + inner) / 2.0,
		0.0,
		TAU,
		ARC_POINTS,
		Color(_target_colour, BAND_ALPHA),
		outer - inner,
		true
	)


# `progress` runs 0 as a prompt appears, 1 on the target, and on past it through the window's late half.
func _ring_radius(progress: float) -> float:
	var radius: float = lerpf(RING_START_RADIUS * _size_scale, _target_radius(), progress)
	return maxf(RING_SMALLEST_RADIUS, radius)


func _draw_key_label(center: Vector2, key: String, outline: int = 0) -> void:
	var font: Font = ThemeDB.fallback_font
	var font_size: int = roundi(KEY_FONT_SIZE * _size_scale)
	var width: float = font.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if outline > 0:
		draw_string_outline(
			font,
			center + Vector2(-width / 2.0, font_size * 0.36),
			key,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_size,
			outline,
			UITheme.BG
		)
	draw_string(
		font,
		center + Vector2(-width / 2.0, font_size * 0.36),
		key,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		UITheme.WHITE_SOFT
	)


# A hold being held: the target with a track round it, and the fill running clockwise from the top.
func _draw_hold_fill(center: Vector2, filled: float) -> void:
	var radius: float = _target_radius()
	draw_arc(
		center,
		radius,
		0.0,
		TAU,
		ARC_POINTS,
		Color(_target_colour, HOLD_TRACK_ALPHA),
		HOLD_FILL_WIDTH,
		true
	)
	if filled <= 0.0:
		return
	var start: float = -PI / 2.0
	var points: int = maxi(2, ceili(ARC_POINTS * filled))
	draw_arc(
		center, radius, start, start + TAU * filled, points, _target_colour, HOLD_FILL_WIDTH, true
	)


# The kind's word under the key, so a hold or a mash reads as one before the ring lands.
func _draw_kind_word(center: Vector2, word: String) -> void:
	var font: Font = ThemeDB.fallback_font
	var font_size: int = roundi(KIND_WORD_FONT_SIZE * _size_scale)
	var key_size: float = KEY_FONT_SIZE * _size_scale
	var width: float = font.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(
		font,
		center + Vector2(-width / 2.0, key_size * KIND_WORD_OFFSET + font_size * 0.36),
		word,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		_target_colour
	)


# A mash running: the target fills from the middle with each press, heating and trembling as it nears full and
# swelling on every press, with the time left running down round it.
func _draw_mash(index: int, center: Vector2) -> void:
	var filled: float = _game.mash_progress(index)
	var trembling: float = MASH_TREMBLE_MOST * filled * filled
	var at: Vector2 = (
		center + Vector2(randf_range(-trembling, trembling), randf_range(-trembling, trembling))
	)
	var radius: float = _target_radius() * (1.0 + MASH_PULSE_GROWTH * _mash_pulse)
	draw_circle(at, radius, Color(_target_colour, MASH_EMPTY_ALPHA))
	if filled > 0.0:
		draw_circle(at, radius * filled, _target_colour.lerp(MASH_HOT, filled))
	draw_arc(
		at, radius, 0.0, TAU, ARC_POINTS, _target_colour.lerp(MASH_HOT, filled), TARGET_WIDTH, true
	)
	var time_left: float = _game.mash_time_left(index, int(_clock_ms))
	if time_left > 0.0:
		var start: float = -PI / 2.0
		var points: int = maxi(2, ceili(ARC_POINTS * time_left))
		draw_arc(
			at,
			radius + MASH_TIMER_GAP,
			start,
			start + TAU * time_left,
			points,
			_ring_colour,
			MASH_TIMER_WIDTH,
			true
		)
	_draw_key_label(at, str(_game.prompts[index]["key"]), MASH_KEY_OUTLINE)


func _draw_sparks() -> void:
	for spark: Dictionary in _sparks:
		var life: float = float(spark["life"])
		var tail: Vector2 = spark["at"] - spark["velocity"] * SPARK_LENGTH
		draw_line(tail, spark["at"], Color(MASH_HOT, life), SPARK_WIDTH, true)


# ── The dodge moment ─────────────────────────────────────────────────────────


# A slanted band of light crossing the screen left to right.
func _draw_sweep() -> void:
	var band: float = size.x * SWEEP_WIDTH
	var slant: float = size.x * SWEEP_SLANT
	var x: float = lerpf(-band, size.x + slant, _sweep)
	var colour: Color = Color(UITheme.AMBER, SWEEP_ALPHA * (1.0 - _sweep * 0.5))
	draw_colored_polygon(
		PackedVector2Array(
			[
				Vector2(x, 0.0),
				Vector2(x + band, 0.0),
				Vector2(x + band - slant, size.y),
				Vector2(x - slant, size.y),
			]
		),
		colour
	)


# Bands of red along every edge, strongest at the edge itself.
func _draw_vignette() -> void:
	var step: float = minf(size.x, size.y) * VIGNETTE_STEP_WIDTH
	for i in VIGNETTE_STEPS:
		var colour: Color = Color(
			UITheme.DANGER, _vignette * (1.0 - float(i) / VIGNETTE_STEPS) / 2.0
		)
		var inset: float = i * step
		draw_rect(Rect2(inset, inset, size.x - inset * 2.0, step), colour)
		draw_rect(Rect2(inset, size.y - inset - step, size.x - inset * 2.0, step), colour)
		draw_rect(Rect2(inset, inset + step, step, size.y - (inset + step) * 2.0), colour)
		draw_rect(
			Rect2(size.x - inset - step, inset + step, step, size.y - (inset + step) * 2.0), colour
		)
