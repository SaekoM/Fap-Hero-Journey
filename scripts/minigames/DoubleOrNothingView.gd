class_name DoubleOrNothingView
extends HBoxContainer

# Double or Nothing's play view: a tower of prizes and a wheel of WIN and BUST slices. The player cashes out or spins; the wheel spins, ticks past its slices, slows and lands.
#
# The result of a spin is decided by the seeded game (DoubleOrNothingGame.risk) the moment SPIN is pressed;
# the wheel is staging (LuckWheel picks where it rests to show that result). So the drama never changes
# the odds, and a seed still always plays out the same way.
#
# MiniGameScreen owns the intro and the result card; this view owns the climb.

signal finished(outcome: String, headline: String)
# True while the view waits on the player (CASH OUT or SPIN) — the screen runs auto-advance only then.
signal waiting_changed(is_waiting: bool)

const SPIN_SECS: float = 3.4
const SPIN_TURNS: float = 4.0  # whole turns before it starts to settle
const LANDED_HOLD_SECS: float = 0.9  # how long the landed wheel stays before the climb or the result
# Device (owner, 2026-11-04): a slow full stroke while the player chooses, whichever rung they hold. While the
# wheel spins, small strokes walk up and down the range and slow as the wheel does, carrying on through a win's
# celebration. A bust stops it; cashing out or a jackpot eases it back to the middle. On a serial multi-axis
# device, tilt and twist circle with the wheel and a win nods (MiniGameAxes).
const CHOOSING_HALF_CYCLE_MS: int = 1400
const SPIN_FASTEST_STROKE_MS: int = 100
const SPIN_SLOWEST_STROKE_MS: int = 260
# The tick slows with the wheel; it also drops in pitch slightly as it slows, so the end sounds heavy.
const TICK_PITCH_FAST: float = 1.25
const TICK_PITCH_SLOW: float = 0.85
# Celebrations (owner choices, 2026-10-30): every win bursts and flies its prize into the tower, with a
# fanfare that climbs a step per rung and fills out from FULL_FANFARE_RUNG; the top rung gets a moment of
# its own; cashing out gets a small "banked" one.
const FANFARE_STEP: float = 0.07  # pitch added per rung above the first
const FULL_FANFARE_RUNG: int = 3
const PRIZE_FLIGHT_SECS: float = 0.55
const BANKED_HOLD_SECS: float = 0.8
const JACKPOT_HOLD_SECS: float = 2.4

var _definition: Dictionary
var _accent: Color = Color.WHITE  # the creator's accent colour, or the app's
var _game: DoubleOrNothingGame
var _device: MiniGameDevice
var _slices: Array[Dictionary] = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()  # staging only: where the wheel rests
# True from SPIN until the player can choose again: through the spin, the landing, the celebration and the
# hold. Every way of acting checks it, because E goes straight to _spin — disabling the buttons doesn't stop
# a key, and a press slipping through here would spend a whole risk unseen.
var _locked: bool = false
var _done: bool = false
var _spin_from: float = 0.0
var _spin_to: float = 1.0
var _last_slice: int = -1

var _wheel: LuckWheelView
var _tower: VBoxContainer
var _feedback: Label
var _cash_btn: Button
var _spin_btn: Button
var _character: GameCharacterView = null  # stands outside the panel; owned by MiniGameScreen


func setup(
	definition: Dictionary,
	game: DoubleOrNothingGame,
	device: MiniGameDevice,
	character: GameCharacterView
) -> void:
	_definition = definition
	_accent = MiniGameLibrary.accent_color(definition)
	_character = character
	_game = game
	_device = device
	_slices = LuckWheel.slices(int(definition["knobs"]["odds"]))
	_rng.randomize()
	add_theme_constant_override("separation", 24)
	alignment = BoxContainer.ALIGNMENT_CENTER
	_build_table()
	_refresh_tower(false)
	_react("idle")
	_drive_choosing_stroke()
	waiting_changed.emit(true)


# ── Layout ───────────────────────────────────────────────────────────────────


func _build_table() -> void:
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	add_child(column)

	var odds: int = int(_definition["knobs"]["odds"])
	_wheel = LuckWheelView.new()
	_wheel.slices = _slices
	_wheel.accent = _accent
	_wheel.custom_minimum_size = Vector2(260, 260)
	_wheel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(_wheel)
	# The odds in words, with each kind's shape, so neither reading rests on colour.
	column.add_child(
		_label("●  %d%% WIN     ✕  %d%% BUST" % [odds, 100 - odds], UITheme.WHITE_SOFT, 14)
	)

	_tower = VBoxContainer.new()
	_tower.add_theme_constant_override("separation", 4)
	column.add_child(_tower)
	_feedback = _label("", UITheme.AMBER, 17)
	column.add_child(_feedback)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	_cash_btn = _button("CASH OUT", UITheme.PURPLE_BRIGHT)
	_cash_btn.pressed.connect(_cash_out)
	buttons.add_child(_cash_btn)
	_spin_btn = _button("SPIN  (E)", _accent)
	_spin_btn.pressed.connect(_spin)
	buttons.add_child(_spin_btn)
	column.add_child(buttons)
	_cash_btn.grab_focus.call_deferred()


# The tower, top rung first: the held rung highlighted and marked HOLDING, the next one up teased as NEXT,
# the rest dim. `just_climbed` pulses the held rung as it is reached.
func _refresh_tower(just_climbed: bool) -> void:
	for child: Node in _tower.get_children():
		child.queue_free()
	var rungs: Array = _definition["rungs"]
	for i in range(rungs.size() - 1, -1, -1):
		var number: int = i + 1
		var held: bool = number == _game.rung
		var next: bool = number == _game.rung + 1
		var rung: Dictionary = rungs[i]
		var label: String = str(rung.get("label", ""))
		var prize: String = MiniGameScreen.describe_rewards(rung.get("rewards", {}))
		var text: String = (
			"RUNG %d%s   %s"
			% [
				number,
				("  " + label.to_upper()) if label != "" else "",
				prize if prize != "" else "—"
			]
		)
		if held:
			text = "★  " + text + "   ◀ HOLDING"
		elif next:
			text = text + "   ◀ NEXT"
		var row: PanelContainer = _rung_row(text, held, next)
		_tower.add_child(row)
		if held and just_climbed:
			row.pivot_offset = row.size / 2.0
			var pulse: Tween = row.create_tween()
			row.scale = Vector2(1.08, 1.08)
			pulse.tween_property(row, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK)


func _rung_row(text: String, held: bool, next: bool) -> PanelContainer:
	var row: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL_BG_DEEP if not held else Color(_accent, 0.22)
	style.border_color = (_accent if held else Color(_accent, 0.35 if next else 0.15))
	style.set_border_width_all(2 if held else 1)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.set_content_margin_all(8)
	row.add_theme_stylebox_override("panel", style)
	var color: Color = UITheme.WHITE_SOFT if held or next else UITheme.TEXT_HINT
	row.add_child(_label(text, color, 15 if held else 13))
	return row


# ── Playing ──────────────────────────────────────────────────────────────────


func _cash_out() -> void:
	if _locked or _done:
		return
	_done = true
	_game.cash_out()
	_device.ease_out()
	_cash_btn.disabled = true
	_spin_btn.disabled = true
	waiting_changed.emit(false)
	# A small "banked" moment: a smart stop deserves a nod, not a win's fanfare.
	UISound.banked()
	_feedback.text = "BANKED"
	_pulse(_row_for(_game.rung), 1.15)
	await get_tree().create_timer(BANKED_HOLD_SECS).timeout
	if is_inside_tree():
		finished.emit(_game.outcome, "")


func _spin() -> void:
	if _locked or _done:
		return
	_locked = true
	waiting_changed.emit(false)
	_cash_btn.disabled = true
	_spin_btn.disabled = true
	_feedback.text = "SPINNING…"
	_react("idle")

	var won: bool = _game.risk()  # decided now, by the seeded game; the wheel only shows it
	var resting: float = LuckWheel.resting_turn(_slices, won, _rng)
	# The wheel's rotation r puts the point -r under the pointer, so it must end on r ≡ -resting, and at
	# least SPIN_TURNS further round than it starts.
	_spin_from = _wheel.rotation_turn
	_spin_to = -resting + ceilf(_spin_from + SPIN_TURNS + resting)
	_last_slice = LuckWheel.slice_index_at(_slices, -_spin_from)
	_device.walk(SPIN_FASTEST_STROKE_MS, SPIN_SLOWEST_STROKE_MS, SPIN_SECS)
	var spin: Tween = create_tween()
	(
		spin
		. tween_method(_set_spin, _spin_from, _spin_to, SPIN_SECS)
		. set_trans(Tween.TRANS_QUART)
		. set_ease(Tween.EASE_OUT)
	)
	await spin.finished
	if not is_inside_tree():
		return
	_landed(won)


# One frame of the spin: turn the wheel, and tick when a new slice passes the pointer.
func _set_spin(rotation_turn: float) -> void:
	_wheel.rotation_turn = rotation_turn
	_wheel.queue_redraw()
	var progress: float = clampf((rotation_turn - _spin_from) / (_spin_to - _spin_from), 0.0, 1.0)
	var slice: int = LuckWheel.slice_index_at(_slices, -rotation_turn)
	if slice != _last_slice:
		_last_slice = slice
		UISound.wheel_tick(lerpf(TICK_PITCH_FAST, TICK_PITCH_SLOW, progress))
	_device.stream_axes(MiniGameAxes.spinning_wheel(rotation_turn - _spin_from, progress))


func _landed(won: bool) -> void:
	if won:
		_device.play_axis_moves(MiniGameAxes.WIN_NOD)
	if won and _game.outcome == DoubleOrNothingGame.OUTCOME_MAXED:
		await _jackpot()
		if is_inside_tree():
			_device.ease_out()
			_done = true
			finished.emit(_game.outcome, "JACKPOT — YOU WON IT ALL")
		return
	if won:
		var climb: float = float(_game.rung - 1) / maxf(1.0, float(_rung_count() - 1))
		UISound.win_sting(1.0 + FANFARE_STEP * (_game.rung - 2), _game.rung >= FULL_FANFARE_RUNG)
		_react("win")
		_feedback.text = "WIN — UP A RUNG"
		_burst(climb)
		await _fly_prize_to(_game.rung)
		if not is_inside_tree():
			return
	else:
		UISound.bust_sting()
		_react("bust")
		_feedback.text = "BUST"
		_crack_tower()
		_device.stop()
	await get_tree().create_timer(LANDED_HOLD_SECS).timeout
	if not is_inside_tree():
		return
	if _game.is_finished():
		_done = true
		finished.emit(_game.outcome, "YOU WON IT ALL" if won else "BUST")
		return
	# The tower already shows the new rung: the prize flew into it (_fly_prize_to).
	_locked = false
	_cash_btn.disabled = false
	_spin_btn.disabled = false
	_drive_choosing_stroke()
	waiting_changed.emit(true)


# ── Celebrations ─────────────────────────────────────────────────────────────


func _rung_count() -> int:
	return (_definition["rungs"] as Array).size()


# The tower's row for rung `number` (rows run top rung first), or null.
func _row_for(number: int) -> Control:
	var index: int = _rung_count() - number
	if index < 0 or index >= _tower.get_child_count():
		return null
	return _tower.get_child(index) as Control


func _pulse(row: Control, from_scale: float) -> void:
	if row == null:
		return
	row.pivot_offset = row.size / 2.0
	row.scale = Vector2(from_scale, from_scale)
	row.create_tween().tween_property(row, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK)


# A burst of coins and sparks from the wheel's pointer. `strength` (0–1) is how high the climb has got:
# a first-rung win pops, a climb near the top showers.
func _burst(strength: float) -> void:
	var radius: float = minf(_wheel.size.x, _wheel.size.y) / 2.0 - 20.0
	MiniGameFx.burst(_wheel, _wheel.size / 2.0 + Vector2(0.0, -radius), strength)


# The prize just won lifts off the wheel and flies to its place in the tower, which then shows it HOLDING.
func _fly_prize_to(number: int) -> void:
	var target: Control = _row_for(number)
	var rung: Dictionary = (_definition["rungs"] as Array)[number - 1]
	var prize: String = MiniGameScreen.describe_rewards(rung.get("rewards", {}))
	if target == null or prize == "":
		_refresh_tower(true)
		return
	var card: PanelContainer = _rung_row(prize, true, false)
	card.top_level = true  # positioned on screen, free of the layout it flies across
	add_child(card)
	card.global_position = _wheel.global_position + _wheel.size / 2.0 - card.size / 2.0
	card.scale = Vector2(1.3, 1.3)
	var flight: Tween = create_tween().set_parallel(true)
	(
		flight
		. tween_property(card, "global_position", target.global_position, PRIZE_FLIGHT_SECS)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_IN_OUT)
	)
	flight.tween_property(card, "scale", Vector2.ONE, PRIZE_FLIGHT_SECS)
	await flight.finished
	card.queue_free()
	if is_inside_tree():
		_refresh_tower(true)


# The top rung: the wheel turns gold, a JACKPOT banner crosses the screen, the biggest bursts, and its own
# sting — then a longer hold before the result. With REDUCE FLASHING on, the banner only fades.
func _jackpot() -> void:
	UISound.jackpot_sting()
	_react("win")
	_feedback.text = "THE TOP RUNG"
	_refresh_tower(true)
	create_tween().tween_property(_wheel, "gold", 1.0, 0.6)
	_burst(1.0)
	get_tree().create_timer(0.35).timeout.connect(func() -> void: _burst(1.0))
	_show_banner("JACKPOT")
	await get_tree().create_timer(JACKPOT_HOLD_SECS).timeout


func _show_banner(text: String) -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 10  # above the screen's own UI, below nothing the player needs mid-celebration
	add_child(layer)
	var banner: Label = Label.new()
	banner.text = text
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner.set_anchors_and_offsets_preset(Control.PRESET_HCENTER_WIDE)
	banner.offset_top = -70.0
	banner.offset_bottom = 70.0
	UITheme.style_label(banner, UITheme.AMBER, 96)
	var backing: StyleBoxFlat = StyleBoxFlat.new()
	backing.bg_color = Color(0, 0, 0, 0.6)
	banner.add_theme_stylebox_override("normal", backing)
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(banner)
	banner.modulate.a = 0.0
	var arrive: Tween = banner.create_tween().set_parallel(true)
	arrive.tween_property(banner, "modulate:a", 1.0, 0.5)
	if not SettingsService.get_reduce_flashing():
		var width: float = get_viewport_rect().size.x
		banner.position.x = -width
		arrive.tween_property(banner, "position:x", 0.0, 0.5).set_trans(Tween.TRANS_BACK).set_ease(
			Tween.EASE_OUT
		)
	var leave: Tween = banner.create_tween()
	leave.tween_interval(JACKPOT_HOLD_SECS - 0.5)
	leave.tween_property(banner, "modulate:a", 0.0, 0.4)
	leave.tween_callback(layer.queue_free)


# A bust shakes the tower and drains it red — shape (the shake) as well as colour.
func _crack_tower() -> void:
	var shake: Tween = _tower.create_tween()
	var home: float = _tower.position.x
	for offset: float in [-10.0, 9.0, -7.0, 5.0, -3.0, 0.0]:
		shake.tween_property(_tower, "position:x", home + offset, 0.05)
	_tower.modulate = Color(1.0, 0.45, 0.45)


# Auto-advance ran out while the player was deciding: they keep the rung they hold.
func time_out() -> void:
	if _locked or _done:
		return
	_done = true
	_game.time_out()
	finished.emit(_game.outcome, "TIME'S UP")


# E spins; Enter is left to whichever button has focus. Returns whether it used the event.
func handle_input(event: InputEvent) -> bool:
	if (
		event is InputEventKey
		and (event as InputEventKey).pressed
		and not (event as InputEventKey).echo
	):
		if (event as InputEventKey).keycode == KEY_E:
			_spin()
			return true
	return false


# ── Device and character ────────────────────────────────────────────────────────


func _drive_choosing_stroke() -> void:
	_device.hold(0, 100, CHOOSING_HALF_CYCLE_MS)


# The game's character reacts, when it has one.
func _react(moment: String) -> void:
	if _character != null:
		_character.show_moment(moment)


func _label(text: String, color: Color, font_size: int) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(label, color, UITheme.story_font_size(font_size))
	return label


func _button(text: String, accent: Color) -> Button:
	var button: Button = Button.new()
	button.text = text
	UITheme.style_button(button, accent)
	return button


# The wheel: WIN and BUST slices round a disc that turns under a fixed pointer at the top. Each WIN slice
# carries a ● and each BUST slice a ✕, so the wheel reads without colour.
class LuckWheelView:
	extends Control

	var slices: Array[Dictionary] = []
	var accent: Color = Color.WHITE  # the colour of the WIN slices
	var rotation_turn: float = 0.0  # whole turns; the point -rotation_turn sits under the pointer
	# 0–1: how far the WIN slices have turned gold (the jackpot). Faded in, never snapped.
	var gold: float = 0.0:
		set(value):
			gold = value
			queue_redraw()

	func _draw() -> void:
		var center: Vector2 = size / 2.0
		var radius: float = minf(size.x, size.y) / 2.0 - 20.0
		var font: Font = ThemeDB.fallback_font
		for slice: Dictionary in slices:
			var from: float = _angle(float(slice["start"]))
			var to: float = _angle(float(slice["end"]))
			var won: bool = bool(slice["win"])
			var points: PackedVector2Array = [center]
			var steps: int = maxi(3, ceili((to - from) / 0.06))
			for s in steps + 1:
				points.append(
					center + Vector2.from_angle(lerpf(from, to, float(s) / steps)) * radius
				)
			var win_colour: Color = accent.lerp(UITheme.AMBER, gold)
			draw_colored_polygon(points, win_colour if won else Color(UITheme.DANGER, 0.75))
			draw_polyline(points + PackedVector2Array([center]), UITheme.PANEL_BG_DEEP, 2.0, true)
			var glyph: String = "●" if won else "✕"
			var at: Vector2 = center + Vector2.from_angle((from + to) / 2.0) * radius * 0.68
			draw_string(
				font, at + Vector2(-6.0, 6.0), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, UITheme.BG
			)
		draw_arc(center, radius, 0.0, TAU, 96, UITheme.WHITE_SOFT, 2.0, true)
		draw_circle(center, 10.0, UITheme.WHITE_SOFT)
		var tip: Vector2 = center + Vector2(0.0, -radius + 6.0)
		draw_colored_polygon(
			PackedVector2Array([tip, tip + Vector2(-12.0, -22.0), tip + Vector2(12.0, -22.0)]),
			UITheme.AMBER
		)

	# A position on the wheel (turns, clockwise from the top) as a screen angle, after the wheel's turn.
	func _angle(turn: float) -> float:
		return TAU * (turn + rotation_turn) - PI / 2.0
