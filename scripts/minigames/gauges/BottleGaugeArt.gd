class_name BottleGaugeArt
extends VerticalGaugeArt

# A corked bottle: fizz rises from the body into the neck. The cork rattles near the top edge, and overfilled, it pops
# and foam sprays.

const BODY_HALF_WIDTH: float = 56.0
const NECK_HALF_WIDTH: float = 18.0
const SHOULDER_START: float = 0.6
const SHOULDER_END: float = 0.75
const CORK_HEIGHT: float = 20.0
const CORK_OVERHANG: float = 3.0
const CORK_COLOUR: Color = Color(0.72, 0.53, 0.33)
const CORK_RATTLE: float = 4.0
const CORK_RATTLE_SPEED: float = 40.0
const CORK_FLIGHT: float = 150.0
const CORK_DRIFT: float = 60.0


func _top_y() -> float:
	return 10.0 + CORK_HEIGHT


func _half_width_at(level: float) -> float:
	var shoulder: float = smoothstep(SHOULDER_START, SHOULDER_END, level)
	return lerpf(BODY_HALF_WIDTH, NECK_HALF_WIDTH, shoulder)


func _zone_half_width() -> float:
	return BODY_HALF_WIDTH


func spray_colour(_stage: HoldGaugeStage) -> Color:
	return Color.WHITE


func play_fail_sound() -> void:
	UISound.gauge_pop()


func _draw_shell(stage: HoldGaugeStage, centre_x: float) -> void:
	super(stage, centre_x)
	if not stage.has_burst():
		var rattle: float = (
			stage.danger() * CORK_RATTLE * absf(sin(stage.clock * CORK_RATTLE_SPEED))
		)
		_draw_cork(stage, Vector2(centre_x, _top_y() - rattle), 1.0)


func _draw_failure(stage: HoldGaugeStage, centre_x: float) -> void:
	super(stage, centre_x)
	var flown: Vector2 = Vector2(stage.burst * CORK_DRIFT, -stage.burst * CORK_FLIGHT)
	_draw_cork(stage, Vector2(centre_x, _top_y()) + flown, 1.0 - stage.burst)


# The cork, with the bottom of it at `base`.
func _draw_cork(stage: HoldGaugeStage, base: Vector2, opacity: float) -> void:
	var half_width: float = NECK_HALF_WIDTH + CORK_OVERHANG
	stage.draw_rect(
		Rect2(base.x - half_width, base.y - CORK_HEIGHT, half_width * 2.0, CORK_HEIGHT),
		Color(CORK_COLOUR, opacity)
	)
