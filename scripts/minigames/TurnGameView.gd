class_name TurnGameView
extends VBoxContainer

# The play view Stop the Bar and Hold & Release share: lamps for the turns, the game's own stage, and a live score
# meter, with the moment each turn lands and the tally at the end. A game adds its stage and its rules for a turn by
# overriding the hooks under "What a game supplies".
#
# MiniGameScreen owns the intro and the result card, and passes in key and mouse events. A turn is scored from the
# same clock reading the stage was last drawn at, so the player is judged on exactly what they saw.

signal finished(score: int)
# True while the game waits on the player — the screen runs auto-advance only then.
signal waiting_changed(is_waiting: bool)

enum State { PLAYING, LANDED, ENDING, DONE }

# How long the stage stays after a turn lands. The stage resets for the next one in the last part of this.
const LANDED_HOLD_SECS: float = 0.9
const RESET_SECS: float = 0.35
# The ending: the lamps tally one at a time, the tier lands, and it holds before the result card.
const TALLY_STEP_SECS: float = 0.14
const RESULT_HOLD_SECS: float = 1.2
const FLAWLESS_HOLD_SECS: float = 2.4
const FLAWLESS_SECOND_BURST_SECS: float = 0.35

const FEEDBACK_HEIGHT: float = 40.0
const FEEDBACK_FONT_SIZE: int = 17
const FINAL_FONT_SIZE: int = 24

const FLOAT_LABEL_SIZE: Vector2 = Vector2(90.0, 28.0)
const FLOAT_RISE: float = 36.0
const FLOAT_SECS: float = 0.8

const HIT_TICK_PITCH_LOW: float = 1.0
const HIT_TICK_PITCH_HIGH: float = 1.7
const DEAD_ON_STING_PITCH: float = 1.0
const TALLY_TICK_PITCH_LOW: float = 1.0
const TALLY_TICK_PITCH_HIGH: float = 1.9
const TIER_STING_PITCH_LOW: float = 1.0
const TIER_STING_PITCH_HIGH: float = 1.2

var _definition: Dictionary
var _game: TurnScoreGame
var _accent: Color = Color.WHITE  # the creator's accent colour, or the app's
var _character: GameCharacterView = null  # stands outside the panel; owned by MiniGameScreen

var _state: int = State.PLAYING
var _landed_left: float = 0.0
var _ending: Tween = null
var _result_landed: bool = false

var _lamps: TurnLamps
var _stage: TurnStage
var _meter: TurnScoreMeter
var _feedback: Label
var _hint: Label


func setup(definition: Dictionary, game: TurnScoreGame, character: GameCharacterView) -> void:
	_definition = definition
	_game = game
	_accent = MiniGameLibrary.accent_color(definition)
	_character = character
	add_theme_constant_override("separation", 12)
	_build()
	_begin_turn()


func _build() -> void:
	_lamps = TurnLamps.new()
	_lamps.game = _game
	_lamps.accent = _accent
	add_child(_lamps)

	_stage = _build_stage()
	_stage.accent = _accent
	add_child(_stage)

	_feedback = _label(UITheme.AMBER, FEEDBACK_FONT_SIZE)
	_feedback.custom_minimum_size = Vector2(0.0, FEEDBACK_HEIGHT)
	_feedback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_feedback)

	_meter = TurnScoreMeter.new()
	_meter.accent = _accent
	if bool(_definition["knobs"]["show_tiers"]):
		_meter.tier_marks = (_definition["tiers"] as Array).slice(1)
	add_child(_meter)

	_hint = _label(UITheme.TEXT_HINT, 13)
	_hint.text = _hint_text()
	add_child(_hint)


func _label(color: Color, font_size: int) -> Label:
	var label: Label = Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(label, color, UITheme.story_font_size(font_size))
	return label


# ── What a game supplies ─────────────────────────────────────────────────────


func _build_stage() -> TurnStage:
	return TurnStage.new()


func _hint_text() -> String:
	return ""


# A new turn is starting: put the game's own state back to the start of a turn.
func _on_turn_starting() -> void:
	pass


# The key or mouse button went down during a turn.
func _on_press_in_play() -> void:
	pass


# The key or mouse button came up during a turn.
func _on_release_in_play() -> void:
	pass


# One frame of a turn.
func _play_tick(_delta: float) -> void:
	pass


# What a dead-on turn is called.
func _dead_on_word(_accuracy: float) -> String:
	return "DEAD ON"


# A dead-on turn's sound and burst, bigger the closer it was.
func _celebrate_dead_on(accuracy: float) -> void:
	UISound.win_sting(DEAD_ON_STING_PITCH, false)
	var closeness: float = inverse_lerp(TurnScoreGame.DEAD_ON_ACCURACY, 1.0, accuracy)
	MiniGameFx.burst(_stage, _stage.impact_point(), closeness)


# ── Input and clock ──────────────────────────────────────────────────────────


# E or Enter counts as the press and release. Returns whether it used the event.
func handle_input(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var key: InputEventKey = event
	if key.echo or not key.keycode in [KEY_E, KEY_ENTER, KEY_KP_ENTER]:
		return false
	if key.pressed:
		_press()
	else:
		_release()
	return true


# So does the left mouse button, anywhere on the screen.
func handle_pointer(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click == null or click.button_index != MOUSE_BUTTON_LEFT:
		return
	if click.pressed:
		_press()
	else:
		_release()


# During the hold after a turn a press does nothing, so a double press can't spend the next turn unseen.
func _press() -> void:
	match _state:
		State.PLAYING:
			_on_press_in_play()
		State.ENDING:
			_skip_ending()


func _release() -> void:
	if _state == State.PLAYING:
		_on_release_in_play()


func _process(delta: float) -> void:
	match _state:
		State.PLAYING:
			_play_tick(delta)
		State.LANDED:
			_landed_left -= delta
			if _landed_left <= 0.0:
				if _game.is_finished():
					_begin_ending()
				else:
					_begin_turn()
		State.DONE:
			return
	_stage.queue_redraw()


# ── One turn ─────────────────────────────────────────────────────────────────


func _begin_turn() -> void:
	_state = State.PLAYING
	_stage.missed = false
	_feedback.text = ""
	_lamps.current = _game.accuracies.size()
	_on_turn_starting()
	if _character != null and not _game.accuracies.is_empty():
		_character.show_moment(GameCharacterView.REST_MOMENT)
	waiting_changed.emit(true)


# The game has recorded a turn. `word` is what to call it unless it was dead on, `on_target` is whether it landed in
# the zone, and `off_target_sound` is what plays if not. The stage holds where it stopped until the game's reset,
# which begins late in the hold.
func _land_turn(
	accuracy: float, word: String, on_target: bool, off_target_sound: Callable = UISound.dial_wrong
) -> void:
	_state = State.LANDED
	_landed_left = LANDED_HOLD_SECS
	waiting_changed.emit(false)
	_lamps.current = -1
	_lamps.queue_redraw()
	_meter.show_score(_game.score())
	_stage.play_impact(accuracy, on_target)
	var dead_on: bool = accuracy >= TurnScoreGame.DEAD_ON_ACCURACY
	_feedback.text = _dead_on_word(accuracy) if dead_on else word
	if dead_on:
		_celebrate_dead_on(accuracy)
	elif on_target:
		UISound.dial_tick(lerpf(HIT_TICK_PITCH_LOW, HIT_TICK_PITCH_HIGH, accuracy))
	else:
		off_target_sound.call()
	var colour: Color = UITheme.AMBER if on_target else UITheme.DANGER
	_float_percent("%d%%" % roundi(accuracy * 100.0), colour)
	# The last turn gets the game's ending instead.
	if _character != null and not _game.is_finished():
		_character.show_moment("hit" if on_target else "miss")


# The turn's percent rises from where it landed and fades.
func _float_percent(text: String, color: Color) -> void:
	var label: Label = _label(color, FEEDBACK_FONT_SIZE)
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size = FLOAT_LABEL_SIZE
	var at: Vector2 = _stage.float_point() - FLOAT_LABEL_SIZE / 2.0
	at.x = clampf(at.x, 0.0, _stage.size.x - FLOAT_LABEL_SIZE.x)
	label.position = at
	_stage.add_child(label)
	var rise: Tween = label.create_tween().set_parallel(true)
	rise.tween_property(label, "position:y", at.y - FLOAT_RISE, FLOAT_SECS).set_ease(Tween.EASE_OUT)
	rise.tween_property(label, "modulate:a", 0.0, FLOAT_SECS).set_ease(Tween.EASE_IN)
	rise.chain().tween_callback(label.queue_free)


# A tween for the game to move its stage back for the next turn: it waits out the hold, and the first property added
# to it, with the rest added in parallel, runs for RESET_SECS.
func _stage_reset_tween() -> Tween:
	var reset: Tween = _stage.create_tween()
	reset.tween_interval(LANDED_HOLD_SECS - RESET_SECS)
	reset.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	return reset


# ── The ending ───────────────────────────────────────────────────────────────


# The lamps tally one by one with rising ticks as the score counts up, then the tier lands.
func _begin_ending() -> void:
	_state = State.ENDING
	_hint.text = "PRESS E TO SKIP"
	UITheme.style_label(_feedback, UITheme.WHITE_SOFT, UITheme.story_font_size(FINAL_FONT_SIZE))
	_ending = create_tween()
	for index: int in _game.accuracies.size():
		_ending.tween_callback(_tally_lamp.bind(index))
		_ending.tween_interval(TALLY_STEP_SECS)
	_ending.tween_callback(_land_result)
	_ending.tween_interval(FLAWLESS_HOLD_SECS if _game.is_flawless() else RESULT_HOLD_SECS)
	_ending.tween_callback(_finish)


func _tally_lamp(index: int) -> void:
	_lamps.tally_index = index
	_lamps.queue_redraw()
	var total: float = 0.0
	for accuracy: float in _game.accuracies.slice(0, index + 1):
		total += accuracy
	_feedback.text = "SCORE  %d%%" % roundi(100.0 * total / _game.accuracies.size())
	var progress: float = float(index + 1) / _game.accuracies.size()
	UISound.dial_tick(lerpf(TALLY_TICK_PITCH_LOW, TALLY_TICK_PITCH_HIGH, progress))


func _land_result() -> void:
	_result_landed = true
	_lamps.tally_index = -1
	_lamps.queue_redraw()
	var tier_id: String = _final_tier_id()
	var strength: float = MiniGameResolver.tier_strength(_definition["tiers"], tier_id)
	var tier_name: String = MiniGameResolver.tier_name(_definition, tier_id).to_upper()
	_feedback.text = "%d%%  —  %s" % [_game.score(), tier_name]
	_react_to_tier(strength)
	if _game.is_flawless():
		_celebrate_flawless()
	elif strength <= 0.0:
		UISound.bust_sting()
	else:
		var pitch: float = lerpf(TIER_STING_PITCH_LOW, TIER_STING_PITCH_HIGH, strength)
		UISound.win_sting(pitch, strength >= 1.0)
		MiniGameFx.burst(_stage, _stage.size / 2.0, strength)


# Every turn dead on: the jackpot's sound, a banner and the biggest bursts.
func _celebrate_flawless() -> void:
	UISound.jackpot_sting()
	MiniGameFx.burst(_stage, _stage.size / 2.0, 1.0)
	var second_burst: Tween = create_tween()
	second_burst.tween_interval(FLAWLESS_SECOND_BURST_SECS)
	second_burst.tween_callback(func() -> void: MiniGameFx.burst(_stage, _stage.size / 2.0, 1.0))
	MiniGameFx.show_banner(self, "FLAWLESS", FLAWLESS_HOLD_SECS)


func _react_to_tier(strength: float) -> void:
	if _character != null:
		_character.show_moment("failed" if strength <= 0.0 else "passed")


func _final_tier_id() -> String:
	return MiniGameResolver.tier_for_score(_definition["tiers"], _game.score())


func _skip_ending() -> void:
	_ending.kill()
	if not _result_landed:
		_react_to_tier(MiniGameResolver.tier_strength(_definition["tiers"], _final_tier_id()))
	_finish()


func _finish() -> void:
	_state = State.DONE
	finished.emit(_game.score())
