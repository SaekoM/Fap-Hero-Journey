class_name MiniGameScreen
extends Control

# The play screen of a mini-game node: an intro, the game itself, and a result card offering KEEP and,
# when the game allows it, RETRY. Built in code, like the other overlays GameLoop opens.
#
# The rules live in the pure game classes (SafeCrackerGame, DoubleOrNothingGame and so on); this screen feeds them
# input and clock time, draws them, and drives the device through DeviceFiller. It never pays anything
# out: when the player keeps a result it emits `resolved` and GameLoop applies the tier (as with every
# other overlay, GameLoop also owns freeing the screen).
#
# The device is always optional (MINIGAMES_DESIGN.md → "Device"): everything the device tells the player,
# the screen also shows.

signal resolved(tier_id: String)

enum Phase { INTRO, PLAY, FINALE, RESULT }

# Safe-Cracker's device: a steady pace whose stroke grows with warmth (owner decision, 2026-10-30).
const DIAL_HALF_CYCLE_MS: int = 650
const DIAL_MIN_DEPTH: float = 15.0
# How long a multi-axis device's twist takes to follow one turn of the dial.
const DIAL_TWIST_MOVE_MS: int = 120
# The dial's click rises from this pitch (cold) to this one (on the number) — the hint a player without a
# device, or with the warmth meter off, plays by.
const TICK_PITCH_COLD: float = 0.75
const TICK_PITCH_HOT: float = 1.9
# The warmth the meter calls HOT. From here the dial trembles too, starting at this strength.
const HOT_WARMTH: float = 0.85
const WARM_WARMTH: float = 0.45
const TREMBLE_AT_HOT: float = 0.35
# The last seconds of a timed game: the time left grows and turns red, with a steady tick. The tick uses the
# duller wheel sound so it can't be mistaken for the dial's click, whose pitch is a hint.
const FINAL_STRETCH_SECS: int = 10
const TIMER_FONT_SIZE: int = 14
const TIMER_FINAL_FONT_SIZE: int = 28
const FINAL_TICK_PITCH: float = 0.7
const INTRO_FONT_SIZE: int = 18
# The result card's prize reveal.
# How long a passing reaction (a wrong try, a number opened) holds before the character returns to rest.
const REACTION_HOLD_SECS: float = 1.6
const COUNT_UP_SECS: float = 0.7
const REWARD_STAGGER_SECS: float = 0.15

# Set by GameLoop before setup(). The journey's auto-advance (fork/shop) duration; 0 = off. It runs
# whenever the screen is waiting on the player with no clock of its own.
var auto_advance_secs: int = 0

var _definition: Dictionary = {}
var _accent: Color = Color.WHITE  # the creator's accent colour, or the app's
var _begin_attempt: Callable  # () -> {seed, attempt}; counts the attempt and returns its seed
var _can_pay: Callable  # (cost: Dictionary) -> bool
var _pay: Callable  # (cost: Dictionary) -> void

var _phase: int = Phase.INTRO
var _attempt: int = 0
var _safe: SafeCrackerGame = null
var _ladder: DoubleOrNothingGame = null
var _elapsed_ms: float = 0.0
var _resolved: bool = false
var _result_tier: String = ""
var _countdown_left: float = 0.0
var _device: MiniGameDevice = MiniGameDevice.new()
var _time_scale: float = MiniGameAssist.time_scale()

var _backdrop: ColorRect
var _center: CenterContainer
var _character: GameCharacterView = null
var _title: Label
var _status: Label
var _body: VBoxContainer
var _countdown: Label
var _lock: LockView = null
var _safe_controls: HBoxContainer = null
var _timer_label: Label = null
var _final_tick_second: int = -1  # the last second the final stretch ticked for
var _warmth_bar: ColorRect = null
var _warmth_fill: ColorRect = null
var _warmth_label: Label = null
var _wrong_label: Label = null
var _feedback: Label = null
var _ladder_view: DoubleOrNothingView = null
var _push_view: PushYourLuckView = null
var _turn_view: TurnGameView = null
var _turn_mouse_catcher: Control = null  # covers the screen during a turn game, so a click anywhere counts


func setup(
	node_data: Dictionary,
	definition: Dictionary,
	begin_attempt: Callable,
	can_pay: Callable,
	pay: Callable
) -> void:
	_definition = definition
	_accent = MiniGameLibrary.accent_color(definition)
	_begin_attempt = begin_attempt
	_can_pay = can_pay
	_pay = pay
	_build_frame()
	SettingBackdrop.attach(self, _backdrop, node_data)
	_character = GameCharacterView.attach(self, _center, definition)
	_show_intro()


func _exit_tree() -> void:
	DeviceFiller.stop()


# ── Frame ────────────────────────────────────────────────────────────────────


func _build_frame() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0, 0, 0, 0.78)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_backdrop)

	_center = CenterContainer.new()
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_center)
	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL_BG_FORK
	style.border_color = Color(_accent, 0.6)
	style.set_border_width_all(2)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = Vector2(640, 0)
	_center.add_child(panel)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)

	_title = Label.new()
	_title.text = str(_definition.get("name", "")).to_upper()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(_title, _accent, UITheme.story_font_size(26))
	column.add_child(_title)
	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(_status, UITheme.TEXT_HINT, 13)
	column.add_child(_status)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 12)
	column.add_child(_body)

	_countdown = Label.new()
	_countdown.anchor_left = 0.5
	_countdown.anchor_right = 0.5
	_countdown.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_countdown.offset_top = 18
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.style_label(_countdown, UITheme.AMBER, 15)
	add_child(_countdown)


# Empties the body, except `keep` if given: it stays where it is, ahead of whatever is added next.
func _clear_body(keep: Control = null) -> void:
	for child: Node in _body.get_children():
		if child != keep:
			child.queue_free()
	_lock = null
	_ladder_view = null
	_push_view = null
	_turn_view = null
	if _turn_mouse_catcher != null:
		_turn_mouse_catcher.queue_free()
		_turn_mouse_catcher = null


func _attempts_text() -> String:
	var attempts: int = int(_definition.get("attempts", 1))
	return "ATTEMPT %d OF %d" % [maxi(1, _attempt), attempts] if attempts > 1 else ""


# ── Phases ───────────────────────────────────────────────────────────────────


func _show_intro() -> void:
	_phase = Phase.INTRO
	_clear_body()
	_status.text = _attempts_text()
	# The creator's words sit above the rules rather than replacing them: the rules are written from the game's
	# settings, so they can't go stale or leave the controls unexplained.
	var intro: String = str(_definition.get("intro_text", ""))
	if intro != "":
		var intro_label: Label = _paragraph(intro)
		UITheme.style_label(intro_label, _accent, UITheme.story_font_size(INTRO_FONT_SIZE))
		_body.add_child(intro_label)
	_body.add_child(_paragraph(_instructions()))
	var start: Button = _button("▶  START", _accent)
	start.pressed.connect(_start_attempt)
	_body.add_child(start)
	start.grab_focus.call_deferred()
	_restart_countdown()


func _instructions() -> String:
	match str(_definition.get("kind", "")):
		SafeCrackerGame.KIND:
			var knobs: Dictionary = _definition["knobs"]
			var limit: int = ceili(_time_limit_s())
			return (
				(
					"Find %d hidden number%s, in order. Turn the dial with the mouse wheel or ← →, and try "
					+ "a number with E or Enter. Listen as you turn: the click rises as you get close.%s%s"
				)
				% [
					int(knobs["numbers"]),
					"" if int(knobs["numbers"]) == 1 else "s",
					(
						" The warmth meter shows it too."
						if str(knobs["warmth"]) != SafeCrackerGame.WARMTH_OFF
						else ""
					),
					(" You have %d seconds." % limit) if limit > 0 else "",
				]
			)
		DoubleOrNothingGame.KIND:
			return (
				(
					"You hold the first prize. Cash out to keep it, or risk it to climb to the next — a %d%% "
					+ "chance each time. Lose a risk and you lose it all."
				)
				% int(_definition["knobs"]["odds"])
			)
		StopTheBarGame.KIND:
			var bar_knobs: Dictionary = _definition["knobs"]
			var stops: int = int(bar_knobs["stops"])
			return (
				(
					"A marker sweeps along the bar. Stop it in the zone with E, Enter or a click: dead centre "
					+ "scores 100%%, falling to 0%% at the zone's edge. %s%s%s"
				)
				% [
					"You have one stop." if stops == 1 else "You have %d stops." % stops,
					(
						" The zone moves each time."
						if stops > 1 and bool(bar_knobs["moving_zone"])
						else ""
					),
					(
						" Each stop is harder than the last."
						if stops > 1 and int(bar_knobs["harder_pct"]) > 0
						else ""
					),
				]
			)
		HoldReleaseGame.KIND:
			var hold_knobs: Dictionary = _definition["knobs"]
			var holds: int = int(hold_knobs["holds"])
			return (
				(
					"Hold E, Enter or the mouse button to fill the gauge, and let go in the zone. The higher "
					+ "the better, up to the zone's top edge, but past that scores nothing. %s%s%s"
				)
				% [
					"You have one hold." if holds == 1 else "You have %d holds." % holds,
					(
						" The zone moves each time."
						if holds > 1 and bool(hold_knobs["moving_zone"])
						else ""
					),
					(
						" Each hold is harder than the last."
						if holds > 1 and int(hold_knobs["harder_pct"]) > 0
						else ""
					),
				]
			)
		PushYourLuckGame.KIND:
			return (
				"You start with a small pot. Bank it to keep it, or push to draw a token from the bag, with "
				+ "PUSH or E. Value tokens add to the pot, a doubler doubles it, a shield saves you from one "
				+ "trap, and a trap with no shield loses it all. What's left in the bag is always shown, so "
				+ "the odds are yours to judge. The bigger the pot you bank, the better the prize."
			)
	return ""


func _start_attempt() -> void:
	var begun: Dictionary = _begin_attempt.call()
	_attempt = int(begun.get("attempt", _attempt + 1))
	var seed_value: int = int(begun.get("seed", 0))
	_phase = Phase.PLAY
	_status.text = _attempts_text()
	_clear_body()
	_elapsed_ms = 0.0
	if _character != null:
		_character.show_moment(GameCharacterView.REST_MOMENT)
	match str(_definition.get("kind", "")):
		SafeCrackerGame.KIND:
			_safe = SafeCrackerGame.new(_definition["knobs"], seed_value, _time_scale)
			_build_safe_view()
			# Its own clock decides the end when it has one; otherwise auto-advance guards the wait.
			if int(_definition["knobs"]["time_limit_s"]) > 0:
				_stop_countdown()
			else:
				_restart_countdown()
		DoubleOrNothingGame.KIND:
			_ladder = DoubleOrNothingGame.new(
				(_definition["rungs"] as Array).size(),
				int(_definition["knobs"]["odds"]),
				seed_value
			)
			_ladder_view = DoubleOrNothingView.new()
			_ladder_view.finished.connect(_on_ladder_finished)
			_ladder_view.waiting_changed.connect(_on_game_waiting)
			_body.add_child(_ladder_view)
			_ladder_view.setup(_definition, _ladder, _device, _character)
		PushYourLuckGame.KIND:
			_push_view = PushYourLuckView.new()
			_push_view.finished.connect(_on_ladder_finished)
			_push_view.waiting_changed.connect(_on_game_waiting)
			_body.add_child(_push_view)
			_push_view.setup(
				_definition, PushYourLuckGame.new(_definition["knobs"], seed_value), _character
			)
		StopTheBarGame.KIND:
			_build_turn_view(
				StopTheBarView.new(),
				StopTheBarGame.new(_definition["knobs"], seed_value, _time_scale)
			)
		HoldReleaseGame.KIND:
			_build_turn_view(
				HoldReleaseView.new(),
				HoldReleaseGame.new(_definition["knobs"], seed_value, _time_scale)
			)


func _finish_play(tier_id: String, headline: String) -> void:
	_result_tier = tier_id
	_phase = Phase.RESULT
	_device.stop()
	var finished_lock: LockView = _lock  # stays on the card, showing how the game ended
	_clear_body(finished_lock)
	var tier: Dictionary = _tier(tier_id)
	if headline != "":
		_body.add_child(_heading(headline, UITheme.TEXT_HINT, 15))
	_body.add_child(_heading(str(tier.get("name", "")).to_upper(), _accent, 30))
	var result_text: String = str(tier.get("result_text", ""))
	if result_text != "":
		_body.add_child(_paragraph(result_text))
	var gained: Label
	if finished_lock != null and _safe.end_reason == SafeCrackerGame.END_OPENED:
		gained = finished_lock.reward_label()  # the prize appears inside the opened lock
	else:
		gained = _paragraph("")
		_body.add_child(gained)
	_reveal_rewards(gained, tier.get("rewards", {}))

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	var retry_allowed: bool = MiniGameLibrary.may_retry(_definition, tier_id, _attempt)
	var keep: Button = _button(
		"KEEP THIS RESULT" if retry_allowed else "CONTINUE", UITheme.PURPLE_BRIGHT
	)
	keep.pressed.connect(func() -> void: _resolve(_result_tier))
	buttons.add_child(keep)
	if retry_allowed:
		var cost: Dictionary = _definition.get("retry_cost", {})
		var affordable: bool = _can_pay.call(cost)
		var cost_text: String = describe_cost(cost)
		var retry: Button = _button(
			(
				("↻ RETRY  (%s)" % cost_text if cost_text != "" else "↻ RETRY")
				if affordable
				else "↻ RETRY — NOT ENOUGH COINS"
			),
			_accent
		)
		retry.disabled = not affordable
		retry.pressed.connect(
			func() -> void:
				_pay.call(cost)
				_start_attempt()
		)
		buttons.add_child(retry)
	_body.add_child(buttons)
	keep.grab_focus.call_deferred()
	_restart_countdown()


# Hands the result to GameLoop, once: a double-click or a countdown landing with a click must not pay out
# twice.
func _resolve(tier_id: String) -> void:
	if _resolved:
		return
	_resolved = true
	_stop_countdown()
	_device.stop()
	resolved.emit(tier_id)


func _tier(tier_id: String) -> Dictionary:
	for tier: Dictionary in _definition.get("tiers", []):
		if str(tier["id"]) == tier_id:
			return tier
	return {}


# ── Safe-Cracker ─────────────────────────────────────────────────────────────


func _build_safe_view() -> void:
	_lock = LockView.new()
	_body.add_child(_lock)
	_lock.setup(
		str(_definition.get("lock", LockArt.DEFAULT_STYLE)),
		_safe.combination.size(),
		int(_definition["knobs"]["dial_size"])
	)

	# The warmth meter: a bar AND a word, so it never rests on colour alone. Left out when the author
	# turned it off — the click's pitch (and the device) are then the only hints.
	_warmth_bar = null
	if str(_definition["knobs"]["warmth"]) != SafeCrackerGame.WARMTH_OFF:
		_warmth_bar = ColorRect.new()
		_warmth_bar.color = UITheme.BAR_BG
		_warmth_bar.custom_minimum_size = Vector2(0, 18)
		_body.add_child(_warmth_bar)
		_warmth_fill = ColorRect.new()
		_warmth_fill.anchor_bottom = 1.0
		_warmth_bar.add_child(_warmth_fill)
		_warmth_label = _heading("", UITheme.WHITE_SOFT, 14)
		_body.add_child(_warmth_label)

	_timer_label = null
	_final_tick_second = -1
	if int(_definition["knobs"]["time_limit_s"]) > 0:
		_timer_label = _heading("", UITheme.TEXT_HINT, TIMER_FONT_SIZE)
		_body.add_child(_timer_label)
	_wrong_label = _heading("", UITheme.TEXT_HINT, 14)
	_wrong_label.visible = int(_definition["knobs"]["max_wrong"]) > 0
	_body.add_child(_wrong_label)
	_feedback = _heading("", UITheme.AMBER, 15)
	_body.add_child(_feedback)

	var controls: HBoxContainer = HBoxContainer.new()
	controls.alignment = BoxContainer.ALIGNMENT_CENTER
	controls.add_theme_constant_override("separation", 12)
	_safe_controls = controls
	# The dial's own buttons make the dial's sounds, not the generic UI click on top of them.
	var left: Button = _button("◀", UITheme.PURPLE_MID)
	UISound.mute_button(left)
	left.pressed.connect(func() -> void: _turn(-1))
	controls.add_child(left)
	var try_btn: Button = _button("TRY  (E)", _accent)
	UISound.mute_button(try_btn)
	try_btn.pressed.connect(_try_number)
	controls.add_child(try_btn)
	var right: Button = _button("▶", UITheme.PURPLE_MID)
	UISound.mute_button(right)
	right.pressed.connect(func() -> void: _turn(1))
	controls.add_child(right)
	_body.add_child(controls)
	_refresh_safe()


func _turn(steps: int) -> void:
	if _phase == Phase.PLAY and _safe != null and not _safe.is_finished():
		_safe.turn(steps)
		_device.move_axes(
			MiniGameAxes.dial_twist(_safe.position, int(_definition["knobs"]["dial_size"])),
			DIAL_TWIST_MOVE_MS
		)
		UISound.dial_tick(lerpf(TICK_PITCH_COLD, TICK_PITCH_HOT, _safe.warmth()))
		_refresh_safe()


func _try_number() -> void:
	if _phase != Phase.PLAY or _safe == null:
		return
	var opened: bool = _safe.try_open()
	if opened:
		UISound.latch_open()
		_lock.number_opened(_safe.opened_count)
	else:
		UISound.dial_wrong()
		_lock.wrong_try()
		if not _safe.is_finished():
			_device.play_axis_moves(
				MiniGameAxes.wrong_try_jolt(_device.has_axis(MiniGameAxes.SWAY))
			)
	_feedback.text = "CLICK — IT GIVES." if opened else "NOTHING."
	# A try that ends the game gets its ending's reaction instead (_check_safe_finished).
	if _character != null and not _safe.is_finished():
		_character.show_moment("opened" if opened else "wrong", REACTION_HOLD_SECS)
	_refresh_safe()
	_check_safe_finished()


func _check_safe_finished() -> void:
	if not _safe.is_finished():
		return
	if _character != null:
		_character.show_moment(
			"success" if _safe.end_reason == SafeCrackerGame.END_OPENED else "failed"
		)
	var headline: String = "SCORE  %d%%" % _safe.score()
	match _safe.end_reason:
		SafeCrackerGame.END_TIME:
			headline = "TIME'S UP  —  " + headline
		SafeCrackerGame.END_JAMMED:
			headline = "THE DIAL JAMMED  —  " + headline
	var tier_id: String = MiniGameResolver.tier_for_score(_definition["tiers"], _safe.score())
	_phase = Phase.FINALE
	_stop_countdown()
	_device.stop()
	for control: Node in _safe_controls.get_children():
		(control as Button).disabled = true
	match _safe.end_reason:
		SafeCrackerGame.END_OPENED:
			_lock.play_released(MiniGameResolver.tier_strength(_definition["tiers"], tier_id))
		SafeCrackerGame.END_JAMMED:
			_lock.play_jammed()
		SafeCrackerGame.END_TIME:
			_lock.play_time_up()
	await _lock.finale_finished
	_finish_play(tier_id, headline)


func _refresh_safe() -> void:
	if _lock == null:
		return
	var warmth: float = _safe.warmth()
	_lock.show_reading(_safe.position, _tremble_for(warmth))
	if _warmth_bar != null:
		_warmth_fill.size = Vector2(_warmth_bar.size.x * warmth, _warmth_bar.size.y)
		_warmth_fill.color = Color(UITheme.CYAN).lerp(UITheme.DANGER, warmth)
		_warmth_label.text = _warmth_word(warmth)
	_refresh_timer()
	_wrong_label.text = (
		"WRONG TRIES %d / %d" % [_safe.total_wrong_tries(), int(_definition["knobs"]["max_wrong"])]
	)
	# Depth follows warmth: a short stroke when cold, the full stroke on the number.
	var depth: float = lerpf(DIAL_MIN_DEPTH, 100.0, warmth)
	_device.hold(roundi(50.0 - depth / 2.0), roundi(50.0 + depth / 2.0), DIAL_HALF_CYCLE_MS)


# The dial trembles only when the meter is on and reads HOT, so it never tells a player more than the
# meter already does. A game with the meter off keeps the click and the device as its only hints.
func _tremble_for(warmth: float) -> float:
	if _warmth_bar == null or warmth < HOT_WARMTH:
		return 0.0
	return lerpf(TREMBLE_AT_HOT, 1.0, inverse_lerp(HOT_WARMTH, 1.0, warmth))


# The time this player has, assist included.
func _time_limit_s() -> float:
	return int(_definition["knobs"]["time_limit_s"]) * _time_scale


func _refresh_timer() -> void:
	if _timer_label == null:
		return
	var seconds_left: int = maxi(0, ceili(_time_limit_s() - _elapsed_ms / 1000.0))
	_timer_label.text = "%ds LEFT" % seconds_left
	if seconds_left > FINAL_STRETCH_SECS or seconds_left == _final_tick_second:
		return
	if _final_tick_second < 0:
		UITheme.style_label(
			_timer_label, UITheme.DANGER, UITheme.story_font_size(TIMER_FINAL_FONT_SIZE)
		)
	_final_tick_second = seconds_left
	if seconds_left > 0:
		UISound.wheel_tick(FINAL_TICK_PITCH)


func _warmth_word(warmth: float) -> String:
	if warmth >= HOT_WARMTH:
		return "HOT"
	if warmth >= WARM_WARMTH:
		return "WARM"
	return "COLD"


# ── Double or Nothing ────────────────────────────────────────────────────────


# The chance games play in their own views; the screen just listens for how they ended and runs auto-advance while
# they wait on the player.
func _on_ladder_finished(outcome: String, headline: String) -> void:
	_finish_play(outcome, headline)


# A game playing in its own view runs auto-advance only while that view waits on the player.
func _on_game_waiting(is_waiting: bool) -> void:
	if is_waiting:
		_restart_countdown()
	else:
		_stop_countdown()


# ── Stop the Bar and Hold & Release ──────────────────────────────────────────


# A turn game plays in its own view. A catcher over the whole screen takes the mouse, rather than _input, so a click
# meant for anything opened on top of this screen can't count as a press.
func _build_turn_view(view: TurnGameView, game: TurnScoreGame) -> void:
	_turn_view = view
	_turn_view.finished.connect(_on_turn_game_finished)
	_turn_view.waiting_changed.connect(_on_game_waiting)
	_body.add_child(_turn_view)
	_turn_view.setup(_definition, game, _character)
	_turn_mouse_catcher = Control.new()
	_turn_mouse_catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_turn_mouse_catcher.gui_input.connect(_turn_view.handle_pointer)
	add_child(_turn_mouse_catcher)


func _on_turn_game_finished(score: int) -> void:
	_finish_play(
		MiniGameResolver.tier_for_score(_definition["tiers"], score), "SCORE  %d%%" % score
	)


# ── Input and clock ──────────────────────────────────────────────────────────


# _input rather than _unhandled_input: the screen's own backdrop and panels stop mouse events, so the
# wheel would never reach an unhandled handler while the pointer is over the dial.
func _input(event: InputEvent) -> void:
	var handled: bool = false
	if _phase == Phase.INTRO and _is_go_key(event):
		_start_attempt()
		handled = true
	elif _phase == Phase.FINALE and _is_go_key(event):
		_lock.skip_finale()
		handled = true
	elif _phase == Phase.PLAY and _lock != null:
		handled = _safe_input(event)
	elif _phase == Phase.PLAY and _ladder_view != null:
		handled = _ladder_view.handle_input(event)
	elif _phase == Phase.PLAY and _push_view != null:
		handled = _push_view.handle_input(event)
	elif _phase == Phase.PLAY and _turn_view != null:
		handled = _turn_view.handle_input(event)
	if handled:
		get_viewport().set_input_as_handled()


# Wheel or ← → turn the dial; E or Enter tries the number under it. Returns whether it used the event.
func _safe_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		match (event as InputEventMouseButton).button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_turn(1)
				return true
			MOUSE_BUTTON_WHEEL_DOWN:
				_turn(-1)
				return true
	elif event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_LEFT:
				_turn(-1)
				return true
			KEY_RIGHT:
				_turn(1)
				return true
		if _is_go_key(event):
			_try_number()
			return true
	return false


func _is_go_key(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var key: InputEventKey = event
	return key.pressed and not key.echo and key.keycode in [KEY_E, KEY_ENTER, KEY_KP_ENTER]


func _process(delta: float) -> void:
	if _phase == Phase.PLAY and _safe != null and not _safe.is_finished():
		_elapsed_ms += delta * 1000.0
		_safe.advance_to(int(_elapsed_ms))
		_refresh_safe()
		_check_safe_finished()
	_tick_countdown(delta)


# ── Auto-advance ─────────────────────────────────────────────────────────────


func _restart_countdown() -> void:
	_countdown_left = float(auto_advance_secs)
	_countdown.visible = auto_advance_secs > 0


func _stop_countdown() -> void:
	_countdown_left = 0.0
	_countdown.visible = false


func _tick_countdown(delta: float) -> void:
	if not _countdown.visible or _countdown_left <= 0.0:
		return
	_countdown_left -= delta
	_countdown.text = "AUTO-CONTINUE IN %d" % ceili(maxf(0.0, _countdown_left))
	if _countdown_left > 0.0:
		return
	_stop_countdown()
	_time_out()


# The player left the screen alone: an unplayed skill game takes its timeout tier, a ladder cashes out
# what is held, and a result on screen is kept.
func _time_out() -> void:
	match _phase:
		Phase.RESULT:
			_resolve(_result_tier)
		_:
			if _ladder_view != null and _phase == Phase.PLAY:
				_ladder_view.time_out()
			elif _push_view != null and _phase == Phase.PLAY:
				_push_view.time_out()
			elif MiniGameLibrary.is_chance(str(_definition.get("kind", ""))):
				_resolve(MiniGameLibrary.untouched_chance_tier(_definition))
			else:
				_resolve(MiniGameResolver.timeout_tier(_definition))


# ── Text ─────────────────────────────────────────────────────────────────────


# What a tier pays, in the player's words: "+♦ 20 · Keycard · loses Map · +50 score". Flags and counters
# are story state and stay unspoken unless the journey shows a counter itself.
static func describe_rewards(rewards: Dictionary) -> String:
	return " · ".join(_reward_parts(rewards, true))


# The pieces describe_rewards joins, coins first when `with_coins`.
static func _reward_parts(rewards: Dictionary, with_coins: bool) -> PackedStringArray:
	var parts: PackedStringArray = []
	var coins: int = int(rewards.get("coins", 0)) if with_coins else 0
	if coins > 0:
		parts.append("+♦ %d" % coins)
	elif coins < 0:
		parts.append("−♦ %d" % -coins)
	var item: String = str(rewards.get("item", ""))
	if item != "":
		parts.append(_item_name(item))
	for taken: Variant in rewards.get("remove_items", []):
		parts.append("loses " + _item_name(str(taken)))
	if int(rewards.get("score", 0)) > 0:
		parts.append("+%d score" % int(rewards["score"]))
	return parts


# The result card's prize, revealed rather than printed: coins count up (or down) to their amount with a
# soft tick, then each other reward appears in turn. Under a second for a typical prize.
func _reveal_rewards(label: Label, rewards: Dictionary) -> void:
	var others: PackedStringArray = _reward_parts(rewards, false)
	var coins: int = int(rewards.get("coins", 0))
	if coins == 0 and others.is_empty():
		label.text = "Nothing gained."
		return
	var shown: PackedStringArray = []
	if coins != 0:
		var last_step: Array[int] = [-1]  # boxed: the counting lambda writes it
		var count_to: Callable = func(value: float) -> void:
			var amount: int = roundi(value)
			label.text = ("+♦ %d" % amount) if coins > 0 else ("−♦ %d" % -amount)
			var step: int = floori(8.0 * value / coins)
			if step != last_step[0]:
				last_step[0] = step
				UISound.dial_tick(1.4)
		# The label's own tween, because RETRY can remove the label mid-count, and the tween has to go with it.
		var count: Tween = label.create_tween()
		count.tween_method(count_to, 0.0, float(coins), COUNT_UP_SECS).set_ease(Tween.EASE_OUT)
		await count.finished
		if not is_inside_tree():
			return
		shown.append(label.text)
	for part: String in others:
		await get_tree().create_timer(REWARD_STAGGER_SECS).timeout
		if not is_inside_tree() or not is_instance_valid(label):
			return
		shown.append(part)
		label.text = " · ".join(shown)
		UISound.dial_tick(1.6)


# What a retry costs, in the same words: "−♦ 20 · loses Key". Empty when it is free.
static func describe_cost(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	if int(cost.get("coins", 0)) > 0:
		parts.append("−♦ %d" % int(cost["coins"]))
	for taken: Variant in cost.get("remove_items", []):
		parts.append("loses " + _item_name(str(taken)))
	return " · ".join(parts)


static func _item_name(item_id: String) -> String:
	return str(InventoryService.GetItemData(item_id).get("name", item_id))


func _heading(text: String, color: Color, size: int) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(label, color, UITheme.story_font_size(size))
	return label


func _paragraph(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(560, 0)
	UITheme.style_label(label, UITheme.WHITE_SOFT, UITheme.story_font_size(15))
	return label


func _button(text: String, accent: Color) -> Button:
	var button: Button = Button.new()
	button.text = text
	UITheme.style_button(button, accent)
	return button
