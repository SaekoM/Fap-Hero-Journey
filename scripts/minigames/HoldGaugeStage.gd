class_name HoldGaugeStage
extends TurnStage

# Hold & Release's stage: it owns the numbers that animate, and its GaugeArt draws them in whichever container the
# creator picked. HoldReleaseView sets and tweens these. None of it affects the score.

# How far below the zone's top edge the gauge starts to creak and tremble.
const DANGER_BAND: float = 0.15
const TREMBLE_IN_DANGER: float = 1.5
const TREMBLE_PAST_ZONE: float = 5.0
const SLOSH_SECS: float = 0.9
# Shorter than TurnGameView.LANDED_HOLD_SECS, so a burst is over before the next turn clears it.
const BURST_SECS: float = 0.85
const NOT_BURST: float = -1.0
const NO_GHOST: float = -1.0

var art: GaugeArt
var level: float = 0.0  # how full, 0–1
var filling: bool = false  # the player is holding right now
var zone_bottom: float = 0.5
var zone_top: float = 0.7
var ghost: float = NO_GHOST  # where the player let go last time
var wobble: float = 0.0  # how much the surface is still sloshing, 0–1
var burst: float = NOT_BURST  # 0–1 through a burst's aftermath
var clock: float = 0.0  # seconds, for the things that keep moving


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, GaugeArt.AREA_HEIGHT)


func _process(delta: float) -> void:
	clock += delta


func has_burst() -> bool:
	return burst >= 0.0


func is_over() -> bool:
	return level > zone_top or missed


# How close the filling gauge is to the zone's top edge, 0 until DANGER_BAND below it, and 1 at it and past it. Once
# the player lets go, the danger is over.
func danger() -> float:
	if not filling:
		return 0.0
	return smoothstep(zone_top - DANGER_BAND, zone_top, level)


func impact_point() -> Vector2:
	return art.level_point(size, level)


func float_point() -> Vector2:
	return Vector2(size.x / 2.0 + art.float_offset_x(), impact_point().y)


func play_impact(accuracy: float, on_target: bool) -> void:
	super(accuracy, on_target)
	wobble = 1.0
	create_tween().tween_property(self, "wobble", 0.0, SLOSH_SECS).set_ease(Tween.EASE_OUT)


# The gauge filled completely: the container fails in its own way.
func play_burst() -> void:
	burst = 0.0
	create_tween().tween_property(self, "burst", 1.0, BURST_SECS)
	if art.sprays_on_failure():
		MiniGameFx.spray(self, impact_point(), art.spray_colour(self), art.spray_gravity())


func clear_burst() -> void:
	burst = NOT_BURST


func _draw() -> void:
	draw_set_transform(Vector2(shake_x + _tremble(), 0.0))
	art.draw_gauge(self)
	_draw_ripple()


func _draw_ripple_shape(radius: float, colour: Color) -> void:
	art.draw_ripple(self, impact_point(), radius, colour)


# Trembles as the gauge nears the zone's top edge, harder past it, more the nearer to full.
func _tremble() -> float:
	if not filling:
		return 0.0
	var strength: float = TREMBLE_IN_DANGER * danger()
	if level > zone_top and zone_top < 1.0:
		strength = lerpf(TREMBLE_IN_DANGER, TREMBLE_PAST_ZONE, inverse_lerp(zone_top, 1.0, level))
	return randf_range(-1.0, 1.0) * strength
