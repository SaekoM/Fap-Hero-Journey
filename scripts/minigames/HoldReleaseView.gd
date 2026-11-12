class_name HoldReleaseView
extends TurnGameView

# Hold & Release's play view: holding fills a gauge, in the container the creator picked, and letting go ends the
# turn. The rules live in HoldReleaseGame, the drawing in HoldGaugeStage and its GaugeArt, and what this shares with
# Stop the Bar in TurnGameView.
#
# Device: a slow stroke while the player waits to hold. Holding speeds it up as the gauge fills, in a few steps rather
# than every frame, so a WiFi device can keep up; letting go drops it back. On a serial multi-axis device the tilt rises
# with the level and drains with it.

# How often the rising tick sounds as the gauge fills, so the fill can be heard as well as seen.
const FILL_TICKS: int = 10
const FILL_TICK_PITCH_LOW: float = 0.8
const FILL_TICK_PITCH_HIGH: float = 1.8
const ON_THE_EDGE_STING_PITCH: float = 1.25
const ON_THE_EDGE_BURST_STRENGTH: float = 1.0

const WAITING_HALF_CYCLE_MS: int = 1200
const FILL_SLOWEST_HALF_CYCLE_MS: int = 700
const FILL_FASTEST_HALF_CYCLE_MS: int = 150
const FILL_STROKE_STEPS: int = 5

var _held_ms: float = 0.0
var _holding: bool = false
var _last_tick_step: int = -1
var _danger_sound_left: float = 0.0
var _gauge: HoldGaugeStage


func _build_stage() -> TurnStage:
	var hold_game: HoldReleaseGame = _game
	_gauge = HoldGaugeStage.new()
	_gauge.art = GaugeArt.art_for(str(_definition.get("container", GaugeArt.DEFAULT_STYLE)))
	_gauge.zone_bottom = hold_game.current_zone_bottom()
	_gauge.zone_top = hold_game.current_zone_top()
	return _gauge


func _hint_text() -> String:
	return "HOLD E, ENTER OR THE MOUSE BUTTON, AND LET GO IN THE ZONE"


func _on_turn_starting() -> void:
	_held_ms = 0.0
	_holding = false
	_last_tick_step = -1
	_danger_sound_left = 0.0
	_gauge.clear_burst()
	_device.hold(0, 100, WAITING_HALF_CYCLE_MS)


# A key still down from the last turn doesn't start this one: it takes a new press.
func _on_press_in_play() -> void:
	if not _holding:
		_holding = true
		_gauge.filling = true
		waiting_changed.emit(false)


func _on_release_in_play() -> void:
	if _holding:
		_end_hold()


func _play_tick(delta: float) -> void:
	if not _holding:
		return
	var hold_game: HoldReleaseGame = _game
	_held_ms += delta * 1000.0
	_gauge.level = hold_game.level_at(int(_held_ms))
	_device.hold(0, 100, _fill_half_cycle_ms(_gauge.level))
	_play_fill_sounds(delta)
	if _gauge.level >= 1.0:
		_gauge.play_burst()
		_end_hold()


# The stroke while the gauge fills: from slow when empty to fastest near full, changing only at each step.
static func _fill_half_cycle_ms(level: float) -> int:
	var step: int = clampi(floori(level * FILL_STROKE_STEPS), 0, FILL_STROKE_STEPS - 1)
	var share: float = float(step) / (FILL_STROKE_STEPS - 1)
	return roundi(lerpf(FILL_SLOWEST_HALF_CYCLE_MS, FILL_FASTEST_HALF_CYCLE_MS, share))


func _follow_stage_on_device() -> void:
	_device.follow_axes(MiniGameAxes.gauge_tilt(_gauge.level))


# The nod starts from where the tilt stopped, so it doesn't snap back to the middle first.
func _celebration_nod() -> Array[Dictionary]:
	return MiniGameAxes.nod_from(float(MiniGameAxes.gauge_tilt(_gauge.level)[MiniGameAxes.PITCH]))


func _play_fill_sounds(delta: float) -> void:
	var step: int = floori(_gauge.level * FILL_TICKS)
	if step != _last_tick_step:
		_last_tick_step = step
		UISound.dial_tick(lerpf(FILL_TICK_PITCH_LOW, FILL_TICK_PITCH_HIGH, _gauge.level))
	var danger: float = _gauge.danger()
	if danger <= 0.0:
		return
	_danger_sound_left -= delta
	if _danger_sound_left <= 0.0:
		_danger_sound_left = _gauge.art.danger_sound_gap(danger)
		_gauge.art.play_danger_sound(danger)


func _end_hold() -> void:
	var hold_game: HoldReleaseGame = _game
	_holding = false
	_gauge.filling = false
	_device.hold(0, 100, WAITING_HALF_CYCLE_MS)
	var level: float = _gauge.level
	var bottom: float = hold_game.current_zone_bottom()
	var top: float = hold_game.current_zone_top()
	var just_over: bool = hold_game.is_just_over(level)
	var accuracy: float = hold_game.release(int(_held_ms))
	_gauge.ghost = level
	if level < bottom:
		_land_turn(accuracy, "TOO EARLY", false)
	elif level <= top:
		_land_turn(accuracy, "IN THE ZONE", true)
	elif _gauge.has_burst():
		_land_turn(accuracy, "BURST", false, _gauge.art.play_fail_sound)
	elif just_over:
		_land_turn(accuracy, "JUST OVER", false, UISound.gauge_near_miss)
	else:
		_land_turn(accuracy, "OVERFILLED", false)
	if not hold_game.is_finished():
		_drain_for_next(hold_game)


func _dead_on_word(accuracy: float) -> String:
	if accuracy >= HoldReleaseGame.ON_THE_EDGE_ACCURACY:
		return "ON THE EDGE"
	return super(accuracy)


func _celebrate_dead_on(accuracy: float) -> void:
	if accuracy < HoldReleaseGame.ON_THE_EDGE_ACCURACY:
		super(accuracy)
		return
	UISound.win_sting(ON_THE_EDGE_STING_PITCH, true)
	MiniGameFx.burst(_gauge, _gauge.impact_point(), ON_THE_EDGE_BURST_STRENGTH)


# The gauge drains and the zone slides to where the next hold needs it, so nothing jumps.
func _drain_for_next(hold_game: HoldReleaseGame) -> void:
	var reset: Tween = _stage_reset_tween()
	reset.tween_property(_gauge, "level", 0.0, RESET_SECS)
	reset.parallel().tween_property(
		_gauge, "zone_bottom", hold_game.current_zone_bottom(), RESET_SECS
	)
	reset.parallel().tween_property(_gauge, "zone_top", hold_game.current_zone_top(), RESET_SECS)
