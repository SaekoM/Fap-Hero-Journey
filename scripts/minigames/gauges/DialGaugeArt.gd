class_name DialGaugeArt
extends GaugeArt

# A pressure dial: a needle swings clockwise round an arc, with the zone as a band on it. Near the top edge the needle
# shakes, and overfilled, it pins at the end, the glass cracks and steam vents.

const FACE_CENTRE_Y: float = 134.0
const FACE_RADIUS: float = 106.0
const START_DEGREES: float = 150.0
const SWEEP_DEGREES: float = 240.0
const ARC_POINTS: int = 64

const ZONE_RADIUS: float = 90.0
const ZONE_THICKNESS: float = 20.0
const ZONE_SEGMENTS: int = 14
const ZONE_TOP_ALPHA: float = 0.9
const ZONE_BOTTOM_ALPHA: float = 0.15
const PROGRESS_RADIUS: float = 70.0
const PROGRESS_THICKNESS: float = 8.0
const TICK_COUNT: int = 10
const TICK_INNER_RADIUS: float = 96.0
const NEEDLE_LENGTH: float = 96.0
const NEEDLE_WIDTH: float = 4.0
const SLAM_EXTRA_WIDTH: float = 5.0
const HUB_RADIUS: float = 10.0
const FLASH_ALPHA: float = 0.7

const SHAKE_SPEED: float = 45.0
const SHAKE_DANGER: float = 0.012  # as a share of the arc
const WOBBLE_SPEED: float = 25.0
const WOBBLE_SWING: float = 0.03

const CRACKS: Array = [
	[Vector2(-0.7, -0.5), Vector2(-0.4, -0.35), Vector2(-0.45, -0.1), Vector2(-0.15, 0.05)],
	[Vector2(0.65, -0.55), Vector2(0.4, -0.3), Vector2(0.5, -0.05)],
]
const STEAM_PUFFS: int = 7
const STEAM_RISE: float = 110.0
const STEAM_SPREAD: float = 70.0
const STEAM_RADIUS: float = 14.0
const STEAM_ALPHA: float = 0.4
const STEAM_GRAVITY: Vector2 = Vector2(0.0, -60.0)


func level_point(area: Vector2, level: float) -> Vector2:
	return _centre(area) + Vector2.from_angle(_angle(level)) * NEEDLE_LENGTH


func spray_colour(_stage: HoldGaugeStage) -> Color:
	return Color(Color.WHITE, 0.7)


func spray_gravity() -> Vector2:
	return STEAM_GRAVITY


func play_fail_sound() -> void:
	UISound.gauge_steam()


func _centre(area: Vector2) -> Vector2:
	return Vector2(area.x / 2.0, FACE_CENTRE_Y)


func _angle(level: float) -> float:
	return deg_to_rad(START_DEGREES + SWEEP_DEGREES * level)


func draw_gauge(stage: HoldGaugeStage) -> void:
	var centre: Vector2 = _centre(stage.size)
	stage.draw_circle(centre, FACE_RADIUS, UITheme.BAR_BG)
	_draw_ticks(stage, centre)
	_draw_zone(stage, centre)
	_draw_progress(stage, centre)
	_draw_ghost(stage, centre)
	_draw_top_edge(stage, centre)
	_draw_needle(stage, centre)
	stage.draw_arc(centre, FACE_RADIUS, 0.0, TAU, ARC_POINTS, UITheme.PURPLE_MID, SHELL_WIDTH, true)
	if stage.has_burst():
		_draw_failure(stage, centre)


func _draw_ticks(stage: HoldGaugeStage, centre: Vector2) -> void:
	var colour: Color = Color(UITheme.TEXT_HINT, 0.5)
	for tick: int in TICK_COUNT + 1:
		var heading: Vector2 = Vector2.from_angle(_angle(float(tick) / TICK_COUNT))
		stage.draw_line(
			centre + heading * TICK_INNER_RADIUS, centre + heading * FACE_RADIUS, colour
		)


# The zone: brightest at its top edge, where it pays the most.
func _draw_zone(stage: HoldGaugeStage, centre: Vector2) -> void:
	for segment: int in ZONE_SEGMENTS:
		var from_share: float = float(segment) / ZONE_SEGMENTS
		var to_share: float = float(segment + 1) / ZONE_SEGMENTS
		var from_level: float = lerpf(stage.zone_bottom, stage.zone_top, from_share)
		var to_level: float = lerpf(stage.zone_bottom, stage.zone_top, to_share)
		var alpha: float = lerpf(ZONE_BOTTOM_ALPHA, ZONE_TOP_ALPHA, to_share)
		var colour: Color = stage.accent.lerp(Color.WHITE, stage.flash * FLASH_ALPHA)
		stage.draw_arc(
			centre,
			ZONE_RADIUS,
			_angle(from_level),
			_angle(to_level),
			6,
			Color(colour, alpha),
			ZONE_THICKNESS
		)


func _draw_progress(stage: HoldGaugeStage, centre: Vector2) -> void:
	if stage.level <= 0.0:
		return
	var colour: Color = UITheme.DANGER if stage.is_over() else stage.accent
	stage.draw_arc(
		centre,
		PROGRESS_RADIUS,
		_angle(0.0),
		_angle(stage.level),
		ARC_POINTS,
		colour,
		PROGRESS_THICKNESS
	)


# Where the player let go last time.
func _draw_ghost(stage: HoldGaugeStage, centre: Vector2) -> void:
	if stage.ghost < 0.0:
		return
	var heading: Vector2 = Vector2.from_angle(_angle(stage.ghost))
	stage.draw_dashed_line(
		centre + heading * HUB_RADIUS,
		centre + heading * FACE_RADIUS,
		Color(Color.WHITE, GHOST_ALPHA),
		2.0,
		6.0
	)


func _draw_top_edge(stage: HoldGaugeStage, centre: Vector2) -> void:
	var heading: Vector2 = Vector2.from_angle(_angle(stage.zone_top))
	var inner: Vector2 = centre + heading * (ZONE_RADIUS - ZONE_THICKNESS / 2.0)
	var outer: Vector2 = centre + heading * FACE_RADIUS
	_draw_edge_line(stage, inner, outer)
	_draw_arrow(stage, outer, heading * ARROW_LENGTH, Color.WHITE)


func _draw_needle(stage: HoldGaugeStage, centre: Vector2) -> void:
	var shake: float = stage.danger() * SHAKE_DANGER * sin(stage.clock * SHAKE_SPEED)
	var swing: float = stage.wobble * WOBBLE_SWING * sin(stage.clock * WOBBLE_SPEED)
	var heading: Vector2 = Vector2.from_angle(_angle(stage.level + shake + swing))
	var colour: Color = UITheme.DANGER if stage.is_over() else Color.WHITE
	var width: float = NEEDLE_WIDTH + SLAM_EXTRA_WIDTH * stage.slam
	stage.draw_line(centre, centre + heading * NEEDLE_LENGTH, colour, width)
	stage.draw_circle(centre, HUB_RADIUS, colour)


# Cracks across the glass, and puffs of steam rising from the top of the dial.
func _draw_failure(stage: HoldGaugeStage, centre: Vector2) -> void:
	for crack: Array in CRACKS:
		var points: PackedVector2Array = []
		for point: Vector2 in crack:
			points.append(centre + point * FACE_RADIUS)
		stage.draw_polyline(points, UITheme.WHITE_SOFT, CRACK_WIDTH, true)
	var vent: Vector2 = centre + Vector2(0.0, -FACE_RADIUS)
	var colour: Color = Color(Color.WHITE, STEAM_ALPHA * (1.0 - stage.burst))
	for puff: int in STEAM_PUFFS:
		var across: float = (float(puff) / (STEAM_PUFFS - 1)) * 2.0 - 1.0
		var drift: Vector2 = Vector2(across * STEAM_SPREAD, -STEAM_RISE) * stage.burst
		var radius: float = STEAM_RADIUS * (0.5 + stage.burst)
		stage.draw_circle(vent + drift, radius, colour)
