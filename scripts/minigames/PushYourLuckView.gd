class_name PushYourLuckView
extends HBoxContainer

# Push Your Luck's play view: a stack on a table, beside the pot, the risk, what's left in the bag and the tiers it
# could pay. The player banks or pushes. A pushed piece hovers over the stack with slowing ticks, then shows what it
# drew: it lands, or a shield takes the blow, or the lot comes down.
#
# The result of a push is decided by the seeded game the moment PUSH is pressed; the hover is staging, so the drama
# never changes the odds. Nothing may show the game's state until the hover ends, or it would give the draw away.
# MiniGameScreen owns the intro and the result card; this view owns the climb, and PushStackStage draws the stack.

signal finished(tier_id: String, headline: String)
# True while the view waits on the player (BANK or PUSH) — the screen runs auto-advance only then.
signal waiting_changed(is_waiting: bool)

const STACK_WIDTH: float = 240.0
# The hover: ticks that spread out as it slows, and then a beat of silence before the result.
const HOVER_SECS: float = 0.95
const HANG_SECS: float = 0.25
const HOVER_TICKS: int = 6
const HOVER_TICK_PITCH_LOW: float = 0.9
const HOVER_TICK_PITCH_HIGH: float = 1.6
const LANDED_HOLD_SECS: float = 0.5
const BLOCKED_HOLD_SECS: float = 0.8
const BANKED_HOLD_SECS: float = 1.3
const BUST_HOLD_SECS: float = 1.8
const TOP_HOLD_SECS: float = 2.4
const TOP_SECOND_BURST_SECS: float = 0.35
const LAND_TICK_PITCH: float = 1.1
# A surviving push's sting climbs with the height of the stack, and fills out from here.
const STING_STEP: float = 0.04
const FULL_STING_PUSHES: int = 4
const TIER_UP_STING_PITCH: float = 1.15
const BIG_DRAW_STING_PITCH: float = 1.2
const DOUBLER_STING_PITCH: float = 1.3
const BIG_DRAW_BURST_STRENGTH: float = 0.3
const DOUBLER_BURST_STRENGTH: float = 0.7
const TIER_UP_BURST_STRENGTH: float = 0.5
const BANKED_BURST_STRENGTH: float = 0.6
# From this risk, the risk reads as a warning and the stack creaks.
const WARNING_RISK_PCT: int = 50

# Device: a stroke that quickens with the risk shown, set again after each draw lands. On a serial multi-axis device the
# roll swings to the stack's sway, wider and quicker as the risk shown rises. Both go by the risk on show, which only
# changes once a piece lands, so neither can give a hovering draw away. A shield taking a trap jolts; a bust jolts and
# stops; banking or clearing the bag nods and eases.
const CALM_HALF_CYCLE_MS: int = 1400
const RISKY_HALF_CYCLE_MS: int = 300
const CREAK_GAP_FAR: float = 1.1
const CREAK_GAP_NEAR: float = 0.45
const CREAK_PITCH_FAR: float = 0.8
const CREAK_PITCH_NEAR: float = 1.2

const POT_FONT_SIZE: int = 30
const POT_COUNT_SECS: float = 0.4
const POT_PULSE_SCALE: float = 1.2
const POT_PULSE_SECS: float = 0.3
const POT_COUNT_TICK_PITCH: float = 1.5
const POT_COUNT_TICKS: int = 5
const POT_SHATTER_SECS: float = 0.9
const POT_SHATTER_DROP: float = 110.0
const POT_SHATTER_SPREAD: float = 26.0
const POT_SHATTER_SPIN: float = 3.0

const GAIN_FLOAT_SIZE: Vector2 = Vector2(120.0, 28.0)
const GAIN_FLOAT_RISE: float = 40.0
const GAIN_FLOAT_SECS: float = 0.8
const GAIN_FONT_SIZE: int = 18
const BIG_GAIN_FONT_SIZE: int = 28

const STAR_FLIGHT_SECS: float = 0.45
const ROW_PULSE_SCALE: float = 1.08
const ROW_PULSE_SECS: float = 0.35

const STAMP_FONT_SIZE: int = 40
const STAMP_SIZE: Vector2 = Vector2(220.0, 60.0)
const STAMP_START_SCALE: float = 2.2
const STAMP_SECS: float = 0.22
const STAMP_TILT: float = -0.14

const TILE_COUNT_FONT_SIZE: int = 20
const TILE_NAME_FONT_SIZE: int = 10
const TILE_PULSE_SCALE: float = 1.2
const TILE_PULSE_SECS: float = 0.3
# The bag's tiles, in the order they're shown: [token, name, whether it's bad news].
const BAG_TILES: Array = [
	[PushYourLuckGame.TOKEN_VALUE, "VALUE", false],
	[PushYourLuckGame.TOKEN_TRAP, "TRAPS", true],
	[PushYourLuckGame.TOKEN_SHIELD, "SHIELDS", false],
	[PushYourLuckGame.TOKEN_DOUBLER, "DOUBLERS", false],
]

var _definition: Dictionary
var _accent: Color = Color.WHITE  # the creator's accent colour, or the app's
var _game: PushYourLuckGame
var _character: GameCharacterView = null  # stands outside the panel; owned by MiniGameScreen
var _device: MiniGameDevice
# True from PUSH until the player can choose again. Every way of acting checks it, because E goes straight to _push:
# disabling the buttons doesn't stop a key.
var _locked: bool = false
# The roll waits until then (Time.get_ticks_msec) while a jolt plays, which may be on the roll itself.
var _roll_resumes_ms: int = 0
var _done: bool = false
var _shown_pot: int = 0
var _creak_left: float = 0.0

var _stack: PushStackStage
var _pot_label: Label
var _risk_label: Label
var _risk_meter: RiskMeter
var _next_label: Label
var _feedback: Label
var _tile_counts: Dictionary = {}  # token → the Label showing how many are left
var _tiers_list: VBoxContainer
var _held_row: Control = null
var _bank_btn: Button
var _push_btn: Button


func setup(
	definition: Dictionary,
	game: PushYourLuckGame,
	device: MiniGameDevice,
	character: GameCharacterView
) -> void:
	_definition = definition
	_accent = MiniGameLibrary.accent_color(definition)
	_game = game
	_device = device
	_character = character
	add_theme_constant_override("separation", 24)
	alignment = BoxContainer.ALIGNMENT_CENTER
	_build()
	_shown_pot = _game.pot
	_show_pot(_shown_pot)
	_refresh()
	_react("idle")
	waiting_changed.emit(true)


func _build() -> void:
	_stack = PushStackStage.new()
	_stack.art = StackArt.art_for(str(_definition.get("stack", StackArt.DEFAULT_STYLE)))
	_stack.accent = _accent
	_stack.most_pieces = _game.safe_tokens_at_start() + 1
	_stack.custom_minimum_size.x = STACK_WIDTH
	add_child(_stack)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(column)
	_pot_label = _label(_accent, POT_FONT_SIZE)
	column.add_child(_pot_label)
	_risk_label = _label(UITheme.WHITE_SOFT, 18)
	column.add_child(_risk_label)
	_risk_meter = RiskMeter.new()
	_risk_meter.accent = _accent
	column.add_child(_risk_meter)
	column.add_child(_build_bag_tiles())
	_next_label = _label(UITheme.TEXT_HINT, 13)
	column.add_child(_next_label)
	_tiers_list = VBoxContainer.new()
	_tiers_list.add_theme_constant_override("separation", 4)
	column.add_child(_tiers_list)
	_feedback = _label(UITheme.AMBER, 17)
	column.add_child(_feedback)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	_bank_btn = _button("BANK", UITheme.PURPLE_BRIGHT)
	_bank_btn.pressed.connect(_bank)
	buttons.add_child(_bank_btn)
	_push_btn = _button("PUSH  (E)", _accent)
	_push_btn.pressed.connect(_push)
	buttons.add_child(_push_btn)
	column.add_child(buttons)
	_bank_btn.grab_focus.call_deferred()


# One tile per kind of token the bag started with, so the player can see exactly what's left.
func _build_bag_tiles() -> Control:
	var tiles: HBoxContainer = HBoxContainer.new()
	tiles.alignment = BoxContainer.ALIGNMENT_CENTER
	tiles.add_theme_constant_override("separation", 6)
	for spec: Array in BAG_TILES:
		var token: String = spec[0]
		if _game.tokens_at_start(token) > 0:
			tiles.add_child(_bag_tile(token, spec[1], spec[2]))
	return tiles


func _bag_tile(token: String, tile_name: String, is_bad_news: bool) -> PanelContainer:
	var colour: Color = UITheme.DANGER if is_bad_news else StackArt.kind_colour(token, _accent)
	var tile: PanelContainer = PanelContainer.new()
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL_BG_DEEP
	style.border_color = Color(colour, 0.6)
	style.set_border_width_all(1)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.set_content_margin_all(4)
	tile.add_theme_stylebox_override("panel", style)
	var stacked: VBoxContainer = VBoxContainer.new()
	stacked.add_theme_constant_override("separation", 0)
	tile.add_child(stacked)
	var count: Label = _label(colour, TILE_COUNT_FONT_SIZE)
	_tile_counts[token] = count
	stacked.add_child(count)
	stacked.add_child(_label(UITheme.TEXT_HINT, TILE_NAME_FONT_SIZE, tile_name))
	return tile


func _process(delta: float) -> void:
	if not _done and Time.get_ticks_msec() >= _roll_resumes_ms:
		_device.follow_axes(MiniGameAxes.stack_roll(_stack.sway_wave(), _stack.sway_share))
	# The stack creaks at a high risk, but not during a push: the game already knows the result by then, and the risk it
	# reads would give the draw away.
	if _done or _locked or _game.risk_pct() < WARNING_RISK_PCT:
		return
	_creak_left -= delta
	if _creak_left <= 0.0:
		var danger: float = inverse_lerp(WARNING_RISK_PCT, 100.0, float(_game.risk_pct()))
		_creak_left = lerpf(CREAK_GAP_FAR, CREAK_GAP_NEAR, danger)
		UISound.gauge_creak(lerpf(CREAK_PITCH_FAR, CREAK_PITCH_NEAR, danger))


# ── Playing ──────────────────────────────────────────────────────────────────


# E pushes; Enter is left to whichever button has focus. Returns whether it used the event.
func handle_input(event: InputEvent) -> bool:
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_E:
		_push()
		return true
	return false


func _bank() -> void:
	if _locked or _done:
		return
	_done = true
	_game.bank()
	_set_buttons_enabled(false)
	waiting_changed.emit(false)
	UISound.banked()
	_react("banked")
	_device.play_axis_moves_then(MiniGameAxes.WIN_NOD, _device.ease_out)
	_stack.settle()
	_stack.sweep_to(_point_in_stack(_pot_label))
	_show_stamp("BANKED", _accent)
	if is_instance_valid(_held_row):
		MiniGameFx.burst(_held_row, _held_row.size / 2.0, BANKED_BURST_STRENGTH)
	await get_tree().create_timer(BANKED_HOLD_SECS).timeout
	if is_inside_tree():
		finished.emit(_game.final_tier_id(_tiers()), "BANKED  %d" % _game.pot)


func _push() -> void:
	if _locked or _done:
		return
	_locked = true
	_set_buttons_enabled(false)
	waiting_changed.emit(false)
	_react("idle")
	_feedback.text = ""
	var survived: bool = _game.push()  # decided now, by the seeded game; the hover only shows it
	_stack.hover_piece(HOVER_SECS)
	var hover: Tween = create_tween()
	var gaps: float = HOVER_TICKS * (HOVER_TICKS + 1) / 2.0
	for tick: int in HOVER_TICKS:
		var pitch: float = lerpf(
			HOVER_TICK_PITCH_LOW, HOVER_TICK_PITCH_HIGH, float(tick) / (HOVER_TICKS - 1)
		)
		hover.tween_callback(UISound.wheel_tick.bind(pitch))
		hover.tween_interval(HOVER_SECS * (tick + 1) / gaps)
	hover.tween_interval(HANG_SECS)
	await hover.finished
	if not is_inside_tree():
		return
	if not survived:
		_bust()
	elif _game.last_token == PushYourLuckGame.TOKEN_TRAP:
		_block_trap()
	else:
		_land_piece()


func _land_piece() -> void:
	var tier_before: String = PushYourLuckGame.tier_for_pot(_tiers(), _shown_pot)
	var held_row_before: Vector2 = (
		_held_row.global_position if is_instance_valid(_held_row) else Vector2.ZERO
	)
	_stack.land_piece(_game.last_token)
	_stack.shields_up = _game.shields_held
	UISound.dial_tick(LAND_TICK_PITCH)
	_react("win")
	_float_draw()
	if _game.pot != _shown_pot:
		_count_pot_up()
	_refresh()
	var tier_now: String = PushYourLuckGame.tier_for_pot(_tiers(), _game.pot)
	var tier_rose: bool = tier_now != tier_before
	_feedback.text = _landing_words(tier_now, tier_rose)
	_play_landing_sound(tier_rose)
	if _game.was_big_draw():
		MiniGameFx.burst(_stack, _stack.top_point(), BIG_DRAW_BURST_STRENGTH)
	elif _game.last_token == PushYourLuckGame.TOKEN_DOUBLER:
		MiniGameFx.burst(_stack, _stack.top_point(), DOUBLER_BURST_STRENGTH)
	if tier_rose:
		_celebrate_tier_up(held_row_before)
	if _game.is_finished():
		_clear_bag()
		return
	_unlock_after(LANDED_HOLD_SECS)


# A trap, but a shield takes it: no piece, the stack shudders, and the shield is gone.
func _block_trap() -> void:
	_stack.block_trap()
	var jolt: Array[Dictionary] = _jolt()
	_device.play_axis_moves(jolt)
	_roll_resumes_ms = Time.get_ticks_msec() + MiniGameAxes.moves_ms(jolt)
	_stack.shields_up = _game.shields_held
	UISound.gauge_shield_block()
	_react("win")
	_feedback.text = "TRAP!  THE SHIELD HELD"
	_refresh()
	if _game.is_finished():
		_clear_bag()
		return
	_unlock_after(BLOCKED_HOLD_SECS)


func _unlock_after(secs: float) -> void:
	await get_tree().create_timer(secs).timeout
	if not is_inside_tree():
		return
	_locked = false
	_set_buttons_enabled(true)
	waiting_changed.emit(true)


# What to say about a landing, biggest news first. It can be more than one thing at once.
func _landing_words(tier_now: String, tier_rose: bool) -> String:
	var words: PackedStringArray = []
	match _game.last_token:
		PushYourLuckGame.TOKEN_SHIELD:
			words.append("SHIELD!")
		PushYourLuckGame.TOKEN_DOUBLER:
			words.append("DOUBLED!")
	if tier_rose:
		words.append("TIER UP — %s" % MiniGameResolver.tier_name(_definition, tier_now).to_upper())
	if _game.was_close_call():
		words.append("CLOSE CALL!")
	if _game.was_big_draw():
		words.append("BIG DRAW!")
	return "   ".join(words)


func _play_landing_sound(tier_rose: bool) -> void:
	if tier_rose:
		UISound.win_sting(TIER_UP_STING_PITCH, true)
	elif _game.last_token == PushYourLuckGame.TOKEN_DOUBLER:
		UISound.win_sting(DOUBLER_STING_PITCH, true)
	elif _game.last_token == PushYourLuckGame.TOKEN_SHIELD:
		UISound.banked()
	elif _game.was_big_draw():
		UISound.win_sting(BIG_DRAW_STING_PITCH, true)
	else:
		var pushes: int = _game.pushes
		UISound.win_sting(1.0 + STING_STEP * pushes, pushes >= FULL_STING_PUSHES)
	if _game.was_close_call():
		UISound.stack_close_call()


# The ★ flies up from the old tier to the new one, which pulses and bursts. The new row needs a frame to be laid out.
func _celebrate_tier_up(from: Vector2) -> void:
	await get_tree().process_frame
	if not is_inside_tree() or not is_instance_valid(_held_row):
		return
	var row: Control = _held_row
	row.pivot_offset = row.size / 2.0
	row.scale = Vector2(ROW_PULSE_SCALE, ROW_PULSE_SCALE)
	var pulse: Tween = row.create_tween()
	pulse.tween_property(row, "scale", Vector2.ONE, ROW_PULSE_SECS).set_trans(Tween.TRANS_BACK)
	MiniGameFx.burst(row, row.size / 2.0, TIER_UP_BURST_STRENGTH)
	if from == Vector2.ZERO:
		return
	var star: Label = _label(UITheme.AMBER, GAIN_FONT_SIZE, "★")
	star.top_level = true
	star.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(star)
	star.global_position = from
	var flight: Tween = star.create_tween()
	(
		flight
		. tween_property(star, "global_position", row.global_position, STAR_FLIGHT_SECS)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_IN_OUT)
	)
	flight.tween_callback(star.queue_free)


func _bust() -> void:
	_done = true
	UISound.bust_sting()
	_stack.art.play_fall_sound()
	_react("bust")
	_device.play_axis_moves_then(_jolt(), _device.stop)
	_stack.topple()
	_risk_meter.set_risk(0.0)
	_risk_label.text = ""
	_next_label.text = ""
	_refresh_bag()
	_shatter_pot()
	_show_stamp("BUST", UITheme.DANGER)
	await get_tree().create_timer(BUST_HOLD_SECS).timeout
	if is_inside_tree():
		finished.emit(PushYourLuckGame.OUTCOME_BUSTED, "BUST  —  LOST %d" % _game.pot)


# Everything worth drawing is out, so it banks by itself: the stack turns gold, with the jackpot's sound, a banner and
# the biggest bursts.
func _clear_bag() -> void:
	_done = true
	UISound.jackpot_sting()
	_feedback.text = "NOTHING LEFT BUT TRAPS"
	_device.play_axis_moves_then(MiniGameAxes.WIN_NOD, _device.ease_out)
	_stack.turn_gold()
	MiniGameFx.burst(_stack, _stack.top_point(), 1.0)
	var second_burst: Tween = create_tween()
	second_burst.tween_interval(TOP_SECOND_BURST_SECS)
	second_burst.tween_callback(func() -> void: MiniGameFx.burst(_stack, _stack.top_point(), 1.0))
	MiniGameFx.show_banner(self, "BAG CLEARED", TOP_HOLD_SECS)
	await get_tree().create_timer(TOP_HOLD_SECS).timeout
	if is_inside_tree():
		finished.emit(_game.final_tier_id(_tiers()), "BAG CLEARED  —  %d" % _game.pot)


# Auto-advance ran out while the player was deciding: they keep what they hold.
func time_out() -> void:
	if _locked or _done:
		return
	_done = true
	_game.bank()
	_device.ease_out()
	finished.emit(_game.final_tier_id(_tiers()), "TIME'S UP  —  BANKED %d" % _game.pot)


# ── The pot ──────────────────────────────────────────────────────────────────


func _show_pot(amount: int) -> void:
	_pot_label.text = "POT  %d" % amount


# The pot ticks up to its new amount and pulses.
func _count_pot_up() -> void:
	var from: int = _shown_pot
	_shown_pot = _game.pot
	var last_step: Array[int] = [-1]  # boxed: the counting lambda writes it
	var count_to: Callable = func(value: float) -> void:
		_show_pot(roundi(value))
		var step: int = floori(inverse_lerp(float(from), float(_game.pot), value) * POT_COUNT_TICKS)
		if step != last_step[0]:
			last_step[0] = step
			UISound.dial_tick(POT_COUNT_TICK_PITCH)
	var count: Tween = _pot_label.create_tween()
	count.tween_method(count_to, float(from), float(_game.pot), POT_COUNT_SECS)
	_pot_label.pivot_offset = _pot_label.size / 2.0
	_pot_label.scale = Vector2(POT_PULSE_SCALE, POT_PULSE_SCALE)
	var pulse: Tween = _pot_label.create_tween()
	pulse.tween_property(_pot_label, "scale", Vector2.ONE, POT_PULSE_SECS).set_trans(
		Tween.TRANS_BACK
	)


# On a bust, the pot's characters fall away one by one.
func _shatter_pot() -> void:
	var text: String = _pot_label.text
	var font: Font = _pot_label.get_theme_font("font")
	var font_size: int = _pot_label.get_theme_font_size("font_size")
	var full_width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var left: Vector2 = _pot_label.global_position
	left.x += (_pot_label.size.x - full_width) / 2.0
	for index: int in text.length():
		var before: String = text.substr(0, index)
		var shard: Label = _label(UITheme.DANGER, POT_FONT_SIZE, text[index])
		shard.top_level = true
		shard.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(shard)
		var x: float = font.get_string_size(before, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		shard.global_position = left + Vector2(x, 0.0)
		var side: float = 1.0 if index % 2 == 0 else -1.0
		var target: Vector2 = (
			shard.global_position + Vector2(side * POT_SHATTER_SPREAD, POT_SHATTER_DROP)
		)
		var fall: Tween = shard.create_tween().set_parallel(true)
		fall.tween_property(shard, "global_position", target, POT_SHATTER_SECS).set_ease(
			Tween.EASE_IN
		)
		fall.tween_property(shard, "rotation", side * POT_SHATTER_SPIN, POT_SHATTER_SECS)
		fall.tween_property(shard, "modulate:a", 0.0, POT_SHATTER_SECS).set_ease(Tween.EASE_IN)
		fall.chain().tween_callback(shard.queue_free)
	# A space, not nothing, so the column doesn't jump.
	_pot_label.text = " "


# ── Showing it ───────────────────────────────────────────────────────────────


func _refresh() -> void:
	var risk: int = _game.risk_pct()
	_stack.sway_share = risk / 100.0
	_device.hold(0, 100, risk_half_cycle_ms(_stack.sway_share))
	_refresh_bag()
	if _game.is_finished():
		_risk_label.text = ""
		_next_label.text = ""
		_risk_meter.set_risk(0.0)
	else:
		_show_risk(risk)
		var gain: Vector2i = _game.next_gain_range()
		_next_label.text = (
			"NEXT VALUE  +%d TO +%d" % [gain.x, gain.y]
			if _game.tokens_left(PushYourLuckGame.TOKEN_VALUE) > 0
			else "NO VALUE LEFT IN THE BAG"
		)
	_refresh_tiers()


# The risk in words and as a bar, with the sum behind it, so the player can check it against the bag.
func _show_risk(risk: int) -> void:
	if _game.shields_held > 0:
		_risk_label.text = "BUST RISK  0%%  —  SHIELD UP (%d)" % _game.shields_held
	else:
		_risk_label.text = (
			"BUST RISK  %d%%  (%d IN %d)"
			% [risk, _game.tokens_left(PushYourLuckGame.TOKEN_TRAP), _game.total_tokens_left()]
		)
	var colour: Color = UITheme.DANGER if risk >= WARNING_RISK_PCT else UITheme.WHITE_SOFT
	UITheme.style_label(_risk_label, colour, UITheme.story_font_size(18))
	_risk_meter.set_risk(risk / 100.0)


# What's left in the bag. A count that just fell pulses, so the eye goes to what was drawn.
func _refresh_bag() -> void:
	for token: String in _tile_counts:
		var count: Label = _tile_counts[token]
		var left: String = str(_game.tokens_left(token))
		if count.text != "" and count.text != left:
			count.pivot_offset = count.size / 2.0
			count.scale = Vector2(TILE_PULSE_SCALE, TILE_PULSE_SCALE)
			var pulse: Tween = count.create_tween()
			pulse.tween_property(count, "scale", Vector2.ONE, TILE_PULSE_SECS)
		count.text = left


# The tiers it could pay, top first: the one the pot would bank is marked.
func _refresh_tiers() -> void:
	for child: Node in _tiers_list.get_children():
		child.queue_free()
	var held: String = PushYourLuckGame.tier_for_pot(_tiers(), _game.pot)
	var tiers: Array = _tiers()
	_held_row = null
	for index: int in range(tiers.size() - 1, -1, -1):
		var tier: Dictionary = tiers[index]
		if tier.has("min_pot"):
			var is_held: bool = str(tier["id"]) == held
			var row: PanelContainer = _tier_row(tier, is_held)
			_tiers_list.add_child(row)
			if is_held:
				_held_row = row


func _tier_row(tier: Dictionary, held: bool) -> PanelContainer:
	var row: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(_accent, 0.22) if held else UITheme.PANEL_BG_DEEP
	style.border_color = _accent if held else Color(_accent, 0.2)
	style.set_border_width_all(2 if held else 1)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.set_content_margin_all(6)
	row.add_theme_stylebox_override("panel", style)
	var prize: String = MiniGameScreen.describe_rewards(tier.get("rewards", {}))
	var text: String = (
		"%s  %s  (%d+)%s"
		% [
			"★" if held else "  ",
			str(tier.get("name", "")).to_upper(),
			int(tier["min_pot"]),
			"   " + prize if prize != "" else "",
		]
	)
	row.add_child(_label(UITheme.WHITE_SOFT if held else UITheme.TEXT_HINT, 13, text))
	return row


# What the push drew rises from the top of the stack and fades, larger for a big draw.
func _float_draw() -> void:
	var text: String = "+%d" % _game.last_gain
	match _game.last_token:
		PushYourLuckGame.TOKEN_SHIELD:
			text = "SHIELD"
		PushYourLuckGame.TOKEN_DOUBLER:
			text = "×2"
	var font_size: int = BIG_GAIN_FONT_SIZE if _game.was_big_draw() else GAIN_FONT_SIZE
	var colour: Color = StackArt.kind_colour(_game.last_token, UITheme.AMBER)
	var label: Label = _label(colour, font_size, text)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size = GAIN_FLOAT_SIZE
	var at: Vector2 = _stack.top_point() - GAIN_FLOAT_SIZE / 2.0
	label.position = at
	_stack.add_child(label)
	var rise: Tween = label.create_tween().set_parallel(true)
	rise.tween_property(label, "position:y", at.y - GAIN_FLOAT_RISE, GAIN_FLOAT_SECS)
	rise.tween_property(label, "modulate:a", 0.0, GAIN_FLOAT_SECS).set_ease(Tween.EASE_IN)
	rise.chain().tween_callback(label.queue_free)


# A word stamped across the stack.
func _show_stamp(text: String, colour: Color) -> void:
	var stamp: Label = _label(colour, STAMP_FONT_SIZE, text)
	stamp.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stamp.size = STAMP_SIZE
	stamp.position = (_stack.size - STAMP_SIZE) / 2.0
	stamp.pivot_offset = STAMP_SIZE / 2.0
	stamp.rotation = STAMP_TILT
	stamp.scale = Vector2(STAMP_START_SCALE, STAMP_START_SCALE)
	stamp.modulate.a = 0.0
	_stack.add_child(stamp)
	var land: Tween = stamp.create_tween().set_parallel(true)
	land.tween_property(stamp, "scale", Vector2.ONE, STAMP_SECS).set_ease(Tween.EASE_IN)
	land.tween_property(stamp, "modulate:a", 1.0, STAMP_SECS)


# The middle of `control`, in the stack's own coordinates.
func _point_in_stack(control: Control) -> Vector2:
	return control.global_position + control.size / 2.0 - _stack.global_position


func _tiers() -> Array:
	return _definition["tiers"]


# The stroke for a risk of `risk_share`, 0-1: slow when safe, quickening as the risk rises.
static func risk_half_cycle_ms(risk_share: float) -> int:
	return roundi(lerpf(CALM_HALF_CYCLE_MS, RISKY_HALF_CYCLE_MS, clampf(risk_share, 0.0, 1.0)))


func _jolt() -> Array[Dictionary]:
	return MiniGameAxes.wrong_try_jolt(_device.has_axis(MiniGameAxes.SWAY))


func _set_buttons_enabled(enabled: bool) -> void:
	_bank_btn.disabled = not enabled
	_push_btn.disabled = not enabled


func _react(moment: String) -> void:
	if _character != null:
		_character.show_moment(moment)


func _label(color: Color, font_size: int, text: String = "") -> Label:
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


# The bust risk as a bar, moving from the game's colour towards danger as it fills.
class RiskMeter:
	extends Control

	const HEIGHT: float = 16.0
	const TICK_COUNT: int = 10
	const MOVE_SECS: float = 0.3

	var accent: Color = Color.WHITE
	var _risk: float = 0.0  # 0–1

	func _init() -> void:
		custom_minimum_size.y = HEIGHT
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_risk(value: float) -> void:
		var move: Tween = create_tween()
		move.tween_method(_show_risk, _risk, value, MOVE_SECS).set_ease(Tween.EASE_OUT)

	func _show_risk(value: float) -> void:
		_risk = value
		queue_redraw()

	func _draw() -> void:
		var bar: Rect2 = Rect2(Vector2.ZERO, size)
		draw_rect(bar, UITheme.BAR_BG)
		var colour: Color = accent.lerp(UITheme.DANGER, _risk)
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x * _risk, size.y)), colour)
		var tick_colour: Color = Color(UITheme.TEXT_HINT, 0.5)
		for tick: int in range(1, TICK_COUNT):
			var x: float = size.x * tick / TICK_COUNT
			draw_line(Vector2(x, 0.0), Vector2(x, size.y), tick_colour, 1.0)
		draw_rect(bar, UITheme.PURPLE_MID, false, 1.0)
