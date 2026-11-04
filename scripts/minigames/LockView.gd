class_name LockView
extends Control

# The stage of a Safe-Cracker game: a lock, with the dial on it. This view owns the dial and every moment
# all locks share (the jolt, the rattle, the tremble, the light and the ending); a LockArt only draws what
# one kind of lock looks like. MiniGameScreen owns the rules and tells this view what happened. None of it
# feeds back into the game.

# The ending has played, or been skipped. MiniGameScreen moves on to the result card.
signal finale_finished

const STAGE_SIZE: Vector2 = Vector2(460.0, 340.0)

# How quickly the shown dial catches up with the real position: it glides, while input stays exact.
const DIAL_GLIDE_RATE: float = 18.0
const DIAL_SETTLED_STEPS: float = 0.01
const KNURL_COUNT: int = 72
const HUB_RATIO: float = 0.42  # of the dial's radius
const READOUT_FONT_SIZE: int = 30
const FAILED_MARK_FONT_SIZE: int = 40

const OPEN_SECS: float = 0.25  # a part sliding open as its number gives way
const JOLT_PIXELS: float = 6.0
const JOLT_SECS: float = 0.09
const TREMBLE_PIXELS: float = 2.2

# A wrong try: everything is thrown side to side while the dial kicks back and settles.
const RATTLE_STEPS: Array[float] = [1.0, -0.8, 0.6, -0.4, 0.2, 0.0]
const RATTLE_STEP_SECS: float = 0.05
const RATTLE_PIXELS: float = 5.0
const DIAL_KICK_STEPS: float = 1.2
const POINTER_FLASH_SECS: float = 0.4

# The ending. These add up to about 2.5 seconds.
const LATCH_BEAT_SECS: float = 0.35  # lets the last number's latch be heard first
const RELEASE_SECS: float = 1.7
const FINAL_HOLD_SECS: float = 0.4
const FAILED_HOLD_SECS: float = 1.1
# A press in this window is still the one that opened the lock, not a request to skip what it started.
const SKIP_GUARD_SECS: float = 0.4
const SKIP_TO_END_SECS: float = 60.0  # longer than any ending, so stepping by it runs one to its end

const LIGHT_RINGS: int = 10
const LIGHT_RADIUS_SMALLEST: float = 110.0
const LIGHT_RADIUS_LARGEST: float = 200.0
const LIGHT_RING_ALPHA: float = 0.06
const DIM_WHEN_TIME_UP: Color = Color(0.32, 0.32, 0.38)
const JAM_SHAKE: Array[float] = [-7.0, 6.0, -5.0, 4.0, -2.0, 0.0]
const JAM_SHAKE_STEP_SECS: float = 0.06

var _art: LockArt
var _dial_size: int = 40
var _target_position: int = 0
var _shown_position: float = 0.0
var _dial_kick: float = 0.0
var _tremble: float = 0.0  # 0–1: how hard the dial is trembling
var _pointer_flash: float = 0.0
var _light: float = 0.0  # 0–1: how far the light has come up
var _light_strength: float = 0.0  # 0–1: how good the result is, so how big and how golden the light
var _jammed: bool = false

var _stage: Control  # what everything is drawn on, so a shake can move it free of the panel's layout
var _reward_label: Label
var _motion: Tween = null  # the jolt or rattle now playing
var _finale: Tween = null
var _finale_started_ms: int = 0


# The art for a style. Adding a lock means adding it here.
static func art_for(style: String) -> LockArt:
	match style:
		LockArt.STYLE_DOOR:
			return DoorLockArt.new()
		LockArt.STYLE_HANDCUFFS:
			return HandcuffsLockArt.new()
		LockArt.STYLE_PADLOCK:
			return PadlockLockArt.new()
	return SafeLockArt.new()


func setup(style: String, number_count: int, dial_size: int) -> void:
	_art = art_for(style)
	_art.numbers = number_count
	_dial_size = dial_size
	custom_minimum_size = STAGE_SIZE
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_stage = Control.new()
	_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.clip_contents = _art.clips_to_stage()
	_stage.draw.connect(_paint)
	add_child(_stage)
	_build_reward_label()


# The prize's place, in the opened lock: empty and hidden until the result card writes to it.
func _build_reward_label() -> void:
	_reward_label = Label.new()
	_reward_label.custom_minimum_size = Vector2(300.0, 0.0)
	_reward_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_reward_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reward_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.style_label(_reward_label, UITheme.WHITE_SOFT, UITheme.story_font_size(20))
	var backing: StyleBoxFlat = StyleBoxFlat.new()
	backing.bg_color = Color(0.0, 0.0, 0.0, 0.7)
	backing.set_corner_radius_all(UITheme.CORNER_RADIUS)
	backing.set_content_margin_all(10)
	_reward_label.add_theme_stylebox_override("normal", backing)
	var center: Vector2 = _art.reward_center(STAGE_SIZE) / STAGE_SIZE
	_reward_label.anchor_left = center.x
	_reward_label.anchor_right = center.x
	_reward_label.anchor_top = center.y
	_reward_label.anchor_bottom = center.y
	_reward_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_reward_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_reward_label.visible = false
	add_child(_reward_label)


# ── What the game tells it ───────────────────────────────────────────────────


# The dial's position, and how hard to tremble (0 unless a hint is allowed: see MiniGameScreen).
func show_reading(dial_position: int, tremble: float) -> void:
	_target_position = dial_position
	_tremble = tremble


func number_opened(opened_count: int) -> void:
	create_tween().tween_method(_set_opened, _art.opened, float(opened_count), OPEN_SECS)
	_stop_motion()
	_motion = create_tween()
	_motion.tween_property(_stage, "position:y", JOLT_PIXELS, JOLT_SECS)
	_motion.tween_property(_stage, "position:y", 0.0, JOLT_SECS * 2.0)


func wrong_try() -> void:
	_dial_kick = -DIAL_KICK_STEPS
	var flash_from: float = 0.0 if SettingsService.get_reduce_flashing() else 1.0
	var settle: Tween = create_tween().set_parallel(true)
	settle.tween_property(self, "_dial_kick", 0.0, POINTER_FLASH_SECS).set_trans(Tween.TRANS_SINE)
	settle.tween_method(_set_pointer_flash, flash_from, 0.0, POINTER_FLASH_SECS)
	_stop_motion()
	_motion = create_tween()
	var from: float = 0.0
	for step: float in RATTLE_STEPS:
		_motion.tween_method(_set_rattle, from, step, RATTLE_STEP_SECS)
		_motion.parallel().tween_property(
			_stage, "position:x", step * RATTLE_PIXELS, RATTLE_STEP_SECS
		)
		from = step


# ── Endings ──────────────────────────────────────────────────────────────────


# Every number is open: the lock releases, and the light comes up. `strength` (0–1) is how good the result
# is, so a Perfect shines brighter than a Pass.
func play_released(strength: float) -> void:
	_light_strength = strength
	_tremble = 0.0
	_begin_finale()
	_finale.tween_interval(LATCH_BEAT_SECS)
	_finale.tween_method(_set_release, 0.0, 1.0, RELEASE_SECS).set_trans(Tween.TRANS_SINE)
	var reveal_delay: float = RELEASE_SECS * _art.reveal_point()
	var light_delay: float = RELEASE_SECS * _art.light_point()
	var light_secs: float = RELEASE_SECS - light_delay
	_finale.parallel().tween_method(_set_light, 0.0, 1.0, light_secs).set_delay(light_delay)
	_finale.parallel().tween_callback(_on_lock_gives_way).set_delay(reveal_delay)
	_finale.tween_interval(FINAL_HOLD_SECS)
	_finale.finished.connect(_on_finale_tween_finished)


# Out of wrong tries: the dial shudders and seizes, and its hub shows a warning mark.
func play_jammed() -> void:
	_jammed = true
	_tremble = 0.0
	_stop_motion()  # the wrong try that jammed it has only just started rattling
	UISound.bust_sting()
	_begin_finale()
	for offset: float in JAM_SHAKE:
		_finale.tween_property(_stage, "position:x", offset, JAM_SHAKE_STEP_SECS)
	_finale.tween_interval(FAILED_HOLD_SECS)
	_finale.finished.connect(_on_finale_tween_finished)
	_stage.queue_redraw()


# Out of time: the lock's lights die, and it stays shut.
func play_time_up() -> void:
	_tremble = 0.0
	UISound.bust_sting()
	_begin_finale()
	_finale.tween_property(_stage, "modulate", DIM_WHEN_TIME_UP, FAILED_HOLD_SECS)
	_finale.finished.connect(_on_finale_tween_finished)


# E or Enter during an ending jumps to its last frame. Ignored just after it starts, so the press spamming
# through the last number doesn't throw away the moment it earned.
func skip_finale() -> void:
	if _finale == null or not _finale.is_valid():
		return
	if Time.get_ticks_msec() - _finale_started_ms < SKIP_GUARD_SECS * 1000.0:
		return
	_finale.custom_step(SKIP_TO_END_SECS)


func reward_label() -> Label:
	_reward_label.visible = true
	return _reward_label


func _begin_finale() -> void:
	_finale_started_ms = Time.get_ticks_msec()
	_finale = create_tween()


func _on_lock_gives_way() -> void:
	if _light_strength >= 1.0:
		UISound.jackpot_sting()
	else:
		UISound.win_sting(1.0, _light_strength >= 0.5)
	MiniGameFx.burst(self, _art.reward_center(size), _light_strength)  # free of any clipping on the stage


func _on_finale_tween_finished() -> void:
	finale_finished.emit()


func _stop_motion() -> void:
	if _motion != null and _motion.is_valid():
		_motion.kill()
	_stage.position = Vector2.ZERO
	_art.rattle = 0.0


func _set_opened(value: float) -> void:
	_art.opened = value
	_stage.queue_redraw()


func _set_rattle(value: float) -> void:
	_art.rattle = value
	_stage.queue_redraw()


func _set_release(value: float) -> void:
	_art.release = value
	_stage.queue_redraw()


func _set_light(value: float) -> void:
	_light = value
	_stage.queue_redraw()


func _set_pointer_flash(value: float) -> void:
	_pointer_flash = value
	_stage.queue_redraw()


# ── Frame ────────────────────────────────────────────────────────────────────


func _process(delta: float) -> void:
	var behind: float = wrapf(
		_target_position - _shown_position, -_dial_size / 2.0, _dial_size / 2.0
	)
	if absf(behind) > DIAL_SETTLED_STEPS:
		_shown_position += behind * (1.0 - exp(-DIAL_GLIDE_RATE * delta))
		_stage.queue_redraw()
	elif behind != 0.0:
		_shown_position = _target_position
		_stage.queue_redraw()
	if _tremble > 0.0 or _dial_kick != 0.0:
		_stage.queue_redraw()


func _paint() -> void:
	_art.draw_lock(_stage, size)
	_stage.draw_set_transform_matrix(Transform2D.IDENTITY)
	_paint_light()
	_paint_dial()
	_stage.draw_set_transform_matrix(Transform2D.IDENTITY)


# Rings stacked from widest to narrowest, so the light is strongest at its centre and fades to nothing.
func _paint_light() -> void:
	if _light <= 0.0:
		return
	var center: Vector2 = _art.reward_center(size)
	var widest: float = lerpf(LIGHT_RADIUS_SMALLEST, LIGHT_RADIUS_LARGEST, _light_strength)
	var colour: Color = Color(UITheme.WHITE_SOFT).lerp(UITheme.AMBER, _light_strength)
	colour.a = LIGHT_RING_ALPHA * _light
	for ring in LIGHT_RINGS:
		_stage.draw_circle(center, lerpf(widest, widest * 0.15, float(ring) / LIGHT_RINGS), colour)


# The dial: a ring of ticks turning under a fixed pointer at the top, with every fifth position numbered and
# the exact number on its hub. Shape, not colour, carries the reading: the pointer is a triangle, and a
# jammed hub shows a ✕.
func _paint_dial() -> void:
	var opacity: float = _art.dial_opacity()
	if opacity <= 0.0:
		return
	var radius: float = _art.dial_radius()
	var offset: Vector2 = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _tremble
	var placed: Transform2D = _art.dial_transform(size) * Transform2D(0.0, offset * TREMBLE_PIXELS)
	_stage.draw_set_transform_matrix(placed)

	_stage.draw_circle(Vector2.ZERO, radius + 10.0, Color(LockArt.STEEL_DARK, opacity))
	for knurl in KNURL_COUNT:
		var outward: Vector2 = Vector2.from_angle(TAU * knurl / KNURL_COUNT)
		_stage.draw_line(
			outward * (radius + 5.0),
			outward * (radius + 10.0),
			Color(LockArt.STEEL_LIGHT, opacity),
			1.5,
			true
		)
	_stage.draw_circle(Vector2.ZERO, radius + 3.0, Color(UITheme.PANEL_BG_DEEP, opacity))
	_paint_dial_ticks(radius, opacity)
	_paint_hub(radius, opacity)
	var tip: Vector2 = Vector2(0.0, -radius - 2.0)
	var pointer: Color = Color(UITheme.AMBER).lerp(UITheme.DANGER, _pointer_flash)
	pointer.a = opacity
	_stage.draw_colored_polygon(
		PackedVector2Array([tip, tip + Vector2(-10.0, -16.0), tip + Vector2(10.0, -16.0)]), pointer
	)


func _paint_dial_ticks(radius: float, opacity: float) -> void:
	var font: Font = ThemeDB.fallback_font
	var turned: float = _shown_position + _dial_kick
	for i in _dial_size:
		# The position under the pointer sits at the top (angle −90°); the rest turn with it.
		var angle: float = TAU * (float(i) - turned) / float(_dial_size) - PI / 2.0
		var direction: Vector2 = Vector2.from_angle(angle)
		var major: bool = i % 5 == 0
		var colour: Color = UITheme.WHITE_SOFT if major else UITheme.TEXT_HINT
		colour.a *= opacity
		_stage.draw_line(
			direction * (radius - (14.0 if major else 7.0)),
			direction * radius,
			colour,
			2.0 if major else 1.0,
			true
		)
		if major:
			var text: String = str(i)
			var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
			var label_colour: Color = Color(UITheme.TEXT_HINT, opacity)
			_stage.draw_string(
				font,
				direction * (radius - 30.0) + Vector2(-width / 2.0, 5.0),
				text,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				13,
				label_colour
			)


func _paint_hub(radius: float, opacity: float) -> void:
	_stage.draw_circle(Vector2.ZERO, radius * HUB_RATIO, Color(LockArt.STEEL_DARK, opacity))
	_stage.draw_arc(
		Vector2.ZERO, radius * HUB_RATIO, 0.0, TAU, 48, Color(LockArt.STEEL, opacity), 2.0, true
	)
	var text: String = "✕" if _jammed else str(_target_position)
	var font_size: int = FAILED_MARK_FONT_SIZE if _jammed else READOUT_FONT_SIZE
	var colour: Color = UITheme.DANGER if _jammed else UITheme.WHITE_SOFT
	colour.a = opacity
	var font: Font = ThemeDB.fallback_font
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	_stage.draw_string(
		font,
		Vector2(-width / 2.0, font_size * 0.36),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		colour
	)
