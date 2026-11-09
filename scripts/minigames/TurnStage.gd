class_name TurnStage
extends Control

# The drawn part of a turn-based game, such as Stop the Bar's bar or Hold & Release's gauge: what they share is how a
# turn lands. TurnGameView redraws it every frame, so the values here can simply be tweened.

const RIPPLE_SECS: float = 0.5
const RIPPLE_START_RADIUS: float = 8.0
const RIPPLE_END_RADIUS: float = 80.0
const SLAM_SECS: float = 0.25
const FLASH_SECS: float = 0.35
const SHAKE_STEP_SECS: float = 0.05
const SHAKE_OFFSETS: Array[float] = [-10.0, 9.0, -7.0, 5.0, -3.0, 0.0]

var accent: Color = Color.WHITE
var missed: bool = false  # the turn landed off target; cleared as the next one begins
# Each runs from its start back to rest after a turn.
var slam: float = 0.0
var flash: float = 0.0
var ripple: float = 1.0
var shake_x: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# Where the turn landed: the ripple and any burst come from here.
func impact_point() -> Vector2:
	return size / 2.0


# Where the turn's percent starts its rise.
func float_point() -> Vector2:
	return impact_point()


# The moment a turn lands. Off target it shakes, so a miss doesn't rest on colour alone.
func play_impact(accuracy: float, on_target: bool) -> void:
	slam = 1.0
	create_tween().tween_property(self, "slam", 0.0, SLAM_SECS).set_ease(Tween.EASE_OUT)
	if not on_target:
		missed = true
		var shake: Tween = create_tween()
		for offset: float in SHAKE_OFFSETS:
			shake.tween_property(self, "shake_x", offset, SHAKE_STEP_SECS)
		return
	ripple = 0.0
	create_tween().tween_property(self, "ripple", 1.0, RIPPLE_SECS).set_ease(Tween.EASE_OUT)
	var dead_on: bool = accuracy >= TurnScoreGame.DEAD_ON_ACCURACY
	if dead_on and not SettingsService.get_reduce_flashing():
		flash = 1.0
		create_tween().tween_property(self, "flash", 0.0, FLASH_SECS)


func _draw_ripple() -> void:
	if ripple < 1.0:
		var radius: float = lerpf(RIPPLE_START_RADIUS, RIPPLE_END_RADIUS, ripple)
		_draw_ripple_shape(radius, Color(accent, 1.0 - ripple))


func _draw_ripple_shape(radius: float, colour: Color) -> void:
	draw_arc(impact_point(), radius, 0.0, TAU, 48, colour, 3.0, true)
