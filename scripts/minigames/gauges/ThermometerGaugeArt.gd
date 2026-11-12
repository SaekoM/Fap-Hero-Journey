class_name ThermometerGaugeArt
extends VerticalGaugeArt

# A thermometer: a hot column climbs from a bulb. Near the top edge it glows, and overfilled, the glass shatters.

const COLUMN_HALF_WIDTH: float = 22.0
const ZONE_HALF_WIDTH: float = 62.0
const BULB_RADIUS: float = 34.0
const BULB_CENTRE_Y: float = AREA_HEIGHT - BULB_RADIUS - 2.0
const CAP_MARGIN: float = 3.0
const ARC_POINTS: int = 48
const GLOW_REACH: float = 12.0
const GLOW_ALPHA: float = 0.3
const SHARD_COUNT: int = 12
const SHARD_SIZE: float = 8.0
const SHARD_FLIGHT: float = 130.0
const SHARD_GOLDEN_ANGLE: float = 2.4
const CRACKS: Array = [
	[Vector2(0.42, 0.0), Vector2(0.55, 0.15), Vector2(0.45, 0.3), Vector2(0.56, 0.45)],
]


func _bottom_y() -> float:
	return BULB_CENTRE_Y


func _top_y() -> float:
	return COLUMN_HALF_WIDTH + CAP_MARGIN


func _half_width_at(_level: float) -> float:
	return COLUMN_HALF_WIDTH


func _zone_half_width() -> float:
	return ZONE_HALF_WIDTH


func _is_liquid() -> bool:
	return false


func _fill_colour(stage: HoldGaugeStage) -> Color:
	return _hot_fill_colour(stage)


func spray_colour(_stage: HoldGaugeStage) -> Color:
	return UITheme.DANGER


func play_fail_sound() -> void:
	UISound.gauge_shatter()


# Where the column's walls meet the bulb. Below this, the column is inside it.
func _junction_y() -> float:
	return BULB_CENTRE_Y - sqrt(BULB_RADIUS * BULB_RADIUS - COLUMN_HALF_WIDTH * COLUMN_HALF_WIDTH)


func _shows_tick(level: float) -> bool:
	return _y_of(level) < _junction_y()


func _draw_back(stage: HoldGaugeStage, centre_x: float) -> void:
	super(stage, centre_x)
	stage.draw_circle(Vector2(centre_x, BULB_CENTRE_Y), BULB_RADIUS, UITheme.BAR_BG)
	stage.draw_circle(Vector2(centre_x, _top_y()), COLUMN_HALF_WIDTH, UITheme.BAR_BG)


func _draw_fill(stage: HoldGaugeStage, centre_x: float) -> void:
	var colour: Color = _fill_colour(stage)
	var heat: float = _heat(stage)
	if heat > 0.0 and stage.level > 0.0:
		var reach: float = COLUMN_HALF_WIDTH + GLOW_REACH * heat
		var top: float = _y_of(stage.level)
		stage.draw_rect(
			Rect2(centre_x - reach, top, reach * 2.0, BULB_CENTRE_Y - top),
			Color(colour, GLOW_ALPHA * heat)
		)
	super(stage, centre_x)
	stage.draw_circle(Vector2(centre_x, BULB_CENTRE_Y), BULB_RADIUS - SHELL_WIDTH, colour)


# The glass in one line: up a wall from the bulb, over the rounded cap, down the other wall, and round the bulb, leaving
# the bulb's top open where the column joins it.
func _draw_shell(stage: HoldGaugeStage, centre_x: float) -> void:
	var left: float = centre_x - COLUMN_HALF_WIDTH
	var right: float = centre_x + COLUMN_HALF_WIDTH
	var cap: Vector2 = Vector2(centre_x, _top_y())
	var join: float = _junction_y()
	var colour: Color = UITheme.PURPLE_MID
	stage.draw_line(Vector2(left, join), Vector2(left, _top_y()), colour, SHELL_WIDTH)
	stage.draw_line(Vector2(right, join), Vector2(right, _top_y()), colour, SHELL_WIDTH)
	stage.draw_arc(cap, COLUMN_HALF_WIDTH, PI, TAU, ARC_POINTS, colour, SHELL_WIDTH, true)
	var open_half: float = asin(COLUMN_HALF_WIDTH / BULB_RADIUS)
	stage.draw_arc(
		Vector2(centre_x, BULB_CENTRE_Y),
		BULB_RADIUS,
		-PI / 2.0 + open_half,
		PI * 1.5 - open_half,
		ARC_POINTS,
		colour,
		SHELL_WIDTH,
		true
	)


# Shards of glass fly out from near the top of the column, and fade.
func _draw_failure(stage: HoldGaugeStage, centre_x: float) -> void:
	super(stage, centre_x)
	_draw_cracks(stage, centre_x, CRACKS)
	var origin: Vector2 = Vector2(centre_x, _top_y() + 20.0)
	var colour: Color = Color(UITheme.WHITE_SOFT, 1.0 - stage.burst)
	for shard: int in SHARD_COUNT:
		var heading: Vector2 = Vector2.from_angle(shard * SHARD_GOLDEN_ANGLE)
		var at: Vector2 = origin + heading * stage.burst * SHARD_FLIGHT * (0.6 + 0.1 * (shard % 5))
		var tip: Vector2 = heading * SHARD_SIZE
		stage.draw_colored_polygon(
			PackedVector2Array(
				[at + tip, at + tip.orthogonal() * 0.5, at - tip.orthogonal() * 0.5]
			),
			colour
		)
