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

const DIM_ALPHA: float = 0.7
const DIM_SECS: float = 0.25

const PERFECT_ACCURACY: float = 0.8
const CALLOUT_SIZE: Vector2 = Vector2(500.0, 60.0)
const CALLOUT_FONT_SIZE: int = 30
const CALLOUT_RISE: float = 34.0
const CALLOUT_SECS: float = 0.6
const RESULT_FONT_SIZE: int = 64
const RESULT_HOLD_SECS: float = 0.8
const RESULT_FADE_SECS: float = 0.35

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


func _press_at(t_ms: int, key: String) -> bool:
	var landed: bool = _game.press(t_ms, key) >= 0.0
	if landed:
		_announce_decided_prompts()
		queue_redraw()
	return landed


# Whether the round played through to `position_ms` from where this last saw it, rather than jumping there.
# A game skipped by a seek, or rewound by a replay, was never really played and must not count.
func played_through_to(position_ms: int) -> bool:
	var moved: int = position_ms - _last_position_ms
	return moved >= 0 and moved <= RoundTimelineScheduler.MAX_CATCHUP_MS


func score() -> int:
	return _game.score()


# The game is over: says how it went, lets the round go, and removes itself.
func show_result(text: String, colour: Color) -> void:
	_clock_ms = float(_game.prompts[-1]["close_ms"]) + 1.0
	queue_redraw()
	var label: Label = _callout(text, colour, RESULT_FONT_SIZE, size / 2.0)
	var leave: Tween = create_tween()
	leave.tween_interval(RESULT_HOLD_SECS)
	leave.tween_property(label, "modulate:a", 0.0, RESULT_FADE_SECS)
	leave.parallel().tween_property(self, "dim", 0.0, RESULT_FADE_SECS)
	leave.tween_callback(released.emit)
	leave.tween_callback(queue_free)


# ── Feedback ─────────────────────────────────────────────────────────────────


func _announce_decided_prompts() -> void:
	for i in _game.prompts.size():
		var accuracy: float = float(_game.prompts[i]["accuracy"])
		if accuracy >= 0.0 and not _announced.has(i):
			_announced[i] = true
			_announce(accuracy, _prompt_center(i))


# Words as well as colour say how a prompt went, so it reads in every colour mode. Sounds only play while the round
# is held: over a playing round, the video's own sound is what the player should be hearing.
func _announce(accuracy: float, at: Vector2) -> void:
	if accuracy <= 0.0:
		if _holds_round:
			UISound.dial_wrong()
		_float_callout("MISS", UITheme.DANGER, at)
		return
	if _holds_round:
		UISound.banked()
	MiniGameFx.burst(self, at, accuracy)
	var perfect: bool = accuracy >= PERFECT_ACCURACY
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
	if _game == null:
		return
	var index: int = _game.showing_prompt(int(_clock_ms))
	if index < 0:
		return
	var center: Vector2 = _prompt_center(index)
	var progress: float = _game.ring_progress(index, int(_clock_ms))
	var band: float = _game.hit_band(index)
	_draw_hit_band(center, band)
	draw_arc(center, _target_radius(), 0.0, TAU, ARC_POINTS, _target_colour, TARGET_WIDTH, true)
	var in_window: bool = absf(progress - 1.0) <= band
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
	_draw_key_label(center, str(_game.prompts[index]["key"]))


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


func _draw_key_label(center: Vector2, key: String) -> void:
	var font: Font = ThemeDB.fallback_font
	var font_size: int = roundi(KEY_FONT_SIZE * _size_scale)
	var width: float = font.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(
		font,
		center + Vector2(-width / 2.0, font_size * 0.36),
		key,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		UITheme.WHITE_SOFT
	)
