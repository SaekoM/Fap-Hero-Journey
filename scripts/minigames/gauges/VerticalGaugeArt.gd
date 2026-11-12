class_name VerticalGaugeArt
extends GaugeArt

# A container that fills straight up, drawn from its outline: how wide it is at each level. The fill is drawn as thin
# rows rather than one polygon, so any outline works and a nearly empty gauge can't produce a degenerate shape.

const ROW_HEIGHT: float = 3.0
const ROW_OVERLAP: float = 0.5  # so no seams show between rows of the fill
const OUTLINE_STEPS: int = 20
const TICK_COUNT: int = 10
const TICK_LENGTH: float = 10.0
const ZONE_TOP_ALPHA: float = 0.75
const ZONE_BOTTOM_ALPHA: float = 0.12
const FLASH_ALPHA: float = 0.7
const EDGE_REACH: float = 6.0

# The liquid's surface.
const WAVE_SLICE: float = 4.0
const WAVE_AT_REST: float = 1.5  # at a full gauge; less when lower
const WAVE_SLOSH: float = 9.0
const WAVE_LENGTH: float = 0.12
const WAVE_SPEED: float = 9.0
const SURFACE_WIDTH: float = 3.0
const SLAM_EXTRA_WIDTH: float = 5.0

# Bubbles rise faster the fuller it gets.
const BUBBLE_COUNT: int = 8
const BUBBLE_SPEED_EMPTY: float = 0.18
const BUBBLE_SPEED_FULL: float = 0.9
const BUBBLE_ALPHA: float = 0.35
const BUBBLE_SPREAD: float = 0.7

const HOT_WHITENING: float = 0.5

# Liquid dripping down after a burst.
const DRIP_COUNT: int = 7
const DRIP_FALL: float = 170.0
const DRIP_RADIUS: float = 3.0


# The level-0 and level-1 heights in the stage.
func _bottom_y() -> float:
	return AREA_HEIGHT - 10.0


func _top_y() -> float:
	return 10.0


# How far the container reaches either side of its centre at `level`.
func _half_width_at(_level: float) -> float:
	return 48.0


# How far a gap in the middle reaches either side of the centre at `level`.
func _inner_half_width_at(_level: float) -> float:
	return 0.0


# How far the zone's top edge reaches either side of the centre.
func _edge_half_width(_stage: HoldGaugeStage) -> float:
	return _zone_half_width()


# How far the zone's band reaches either side of the centre.
func _zone_half_width() -> float:
	return 48.0


func _is_liquid() -> bool:
	return true


func _fill_colour(stage: HoldGaugeStage) -> Color:
	var colour: Color = UITheme.DANGER if stage.is_over() else stage.accent
	return colour.lerp(UITheme.BG, 0.25)


# For a container that's red already: it whitens as it nears the limit instead of turning red.
func _hot_fill_colour(stage: HoldGaugeStage) -> Color:
	return UITheme.DANGER.lerp(Color.WHITE, _heat(stage) * HOT_WHITENING)


func _heat(stage: HoldGaugeStage) -> float:
	return 1.0 if stage.is_over() else stage.danger()


func level_point(area: Vector2, level: float) -> Vector2:
	return Vector2(area.x / 2.0, _y_of(level))


func _y_of(level: float) -> float:
	return lerpf(_bottom_y(), _top_y(), level)


func draw_gauge(stage: HoldGaugeStage) -> void:
	var centre_x: float = stage.size.x / 2.0
	_draw_back(stage, centre_x)
	_draw_fill(stage, centre_x)
	if _is_liquid():
		_draw_bubbles(stage, centre_x)
	_draw_zone(stage, centre_x)
	_draw_ticks(stage, centre_x)
	_draw_ghost(stage, centre_x)
	_draw_shell(stage, centre_x)
	_draw_top_edge(stage, centre_x)
	if stage.has_burst():
		_draw_failure(stage, centre_x)


func _draw_back(stage: HoldGaugeStage, centre_x: float) -> void:
	_draw_rows(stage, centre_x, _bottom_y(), _top_y(), UITheme.BAR_BG)


# Fills the container's outline between two heights, bottom first.
func _draw_rows(
	stage: HoldGaugeStage, centre_x: float, from_y: float, to_y: float, colour: Color
) -> void:
	var y: float = from_y
	while y > to_y:
		var row_top: float = maxf(y - ROW_HEIGHT, to_y)
		var level: float = inverse_lerp(_bottom_y(), _top_y(), y)
		_draw_row(stage, centre_x, level, row_top, y - row_top + ROW_OVERLAP, colour)
		y = row_top


func _draw_row(
	stage: HoldGaugeStage, centre_x: float, level: float, top: float, height: float, colour: Color
) -> void:
	var half_width: float = _half_width_at(level)
	stage.draw_rect(Rect2(centre_x - half_width, top, half_width * 2.0, height), colour)


func _draw_fill(stage: HoldGaugeStage, centre_x: float) -> void:
	if stage.level <= 0.0:
		return
	var colour: Color = _fill_colour(stage)
	var surface_y: float = _y_of(stage.level)
	var wave: float = 0.0
	if _is_liquid():
		wave = stage.level * WAVE_AT_REST + stage.wobble * WAVE_SLOSH
	var wave_bottom: float = minf(surface_y + wave, _bottom_y())
	_draw_rows(stage, centre_x, _bottom_y(), wave_bottom, colour)

	var half_width: float = _half_width_at(stage.level)
	var gap: float = _inner_half_width_at(stage.level)
	var surface: PackedVector2Array = []
	var x: float = -half_width
	while x < half_width:
		var slice_end: float = minf(x + WAVE_SLICE, half_width)
		if absf((x + slice_end) / 2.0) < gap:
			# Across a heart's cleft: the surface stops here and picks up on the far side.
			_draw_surface(stage, surface)
			surface.clear()
		else:
			var phase: float = x * WAVE_LENGTH + stage.clock * WAVE_SPEED
			var y: float = surface_y - wave * sin(phase)
			stage.draw_rect(
				Rect2(centre_x + x, y, slice_end - x, maxf(0.0, wave_bottom - y + ROW_OVERLAP)),
				colour
			)
			surface.append(Vector2(centre_x + x, y))
		x = slice_end
	surface.append(Vector2(centre_x + half_width, surface_y))
	_draw_surface(stage, surface)


func _draw_surface(stage: HoldGaugeStage, surface: PackedVector2Array) -> void:
	if surface.size() >= 2:
		stage.draw_polyline(surface, Color.WHITE, SURFACE_WIDTH + SLAM_EXTRA_WIDTH * stage.slam)


func _draw_bubbles(stage: HoldGaugeStage, centre_x: float) -> void:
	var speed: float = lerpf(BUBBLE_SPEED_EMPTY, BUBBLE_SPEED_FULL, stage.level)
	var colour: Color = Color(Color.WHITE, BUBBLE_ALPHA)
	for bubble: int in BUBBLE_COUNT:
		var risen: float = fposmod(stage.clock * speed + bubble * 0.37, 1.0)
		var on_gauge: float = risen * stage.level
		var drift: float = sin(bubble * 2.4 + stage.clock * 2.0)
		var from_centre: float = drift * _half_width_at(on_gauge) * BUBBLE_SPREAD
		if absf(from_centre) >= _inner_half_width_at(on_gauge):
			_draw_droplet(
				stage, Vector2(centre_x + from_centre, _y_of(on_gauge)), 1.5 + bubble % 3, colour
			)


# The zone: brightest at its top edge, where it pays the most.
func _draw_zone(stage: HoldGaugeStage, centre_x: float) -> void:
	var top: float = _y_of(stage.zone_top)
	var bottom: float = _y_of(stage.zone_bottom)
	var half_width: float = _zone_half_width()
	var left: float = centre_x - half_width
	var right: float = centre_x + half_width
	var bright: Color = Color(stage.accent, ZONE_TOP_ALPHA)
	var dim: Color = Color(stage.accent, ZONE_BOTTOM_ALPHA)
	stage.draw_polygon(
		PackedVector2Array(
			[Vector2(left, top), Vector2(right, top), Vector2(right, bottom), Vector2(left, bottom)]
		),
		PackedColorArray([bright, bright, dim, dim])
	)
	var zone: Rect2 = Rect2(left, top, half_width * 2.0, bottom - top)
	stage.draw_rect(zone, stage.accent, false, SHELL_WIDTH)
	if stage.flash > 0.0:
		stage.draw_rect(zone, Color(Color.WHITE, stage.flash * FLASH_ALPHA))


func _draw_ticks(stage: HoldGaugeStage, centre_x: float) -> void:
	var colour: Color = Color(UITheme.TEXT_HINT, 0.5)
	for tick: int in range(1, TICK_COUNT):
		var on_gauge: float = float(tick) / TICK_COUNT
		if _shows_tick(on_gauge):
			var y: float = _y_of(on_gauge)
			var wall: float = centre_x - _half_width_at(on_gauge)
			stage.draw_line(Vector2(wall, y), Vector2(wall + TICK_LENGTH, y), colour)


func _shows_tick(_level: float) -> bool:
	return true


# Where the player let go last time.
func _draw_ghost(stage: HoldGaugeStage, centre_x: float) -> void:
	if stage.ghost < 0.0:
		return
	var y: float = _y_of(stage.ghost)
	var half_width: float = _zone_half_width() + EDGE_REACH
	var colour: Color = Color(Color.WHITE, GHOST_ALPHA)
	stage.draw_dashed_line(
		Vector2(centre_x - half_width, y), Vector2(centre_x + half_width, y), colour, 2.0, 6.0
	)


# The outline, walking up one side and down the other.
func _draw_shell(stage: HoldGaugeStage, centre_x: float) -> void:
	var left_side: PackedVector2Array = []
	var right_side: PackedVector2Array = []
	for step: int in OUTLINE_STEPS + 1:
		var on_gauge: float = float(step) / OUTLINE_STEPS
		var half_width: float = _half_width_at(on_gauge)
		var y: float = _y_of(on_gauge)
		left_side.append(Vector2(centre_x - half_width, y))
		right_side.append(Vector2(centre_x + half_width, y))
	var outline: PackedVector2Array = left_side
	right_side.reverse()
	outline.append_array(right_side)
	outline.append(left_side[0])
	stage.draw_polyline(outline, UITheme.PURPLE_MID, SHELL_WIDTH)


func _draw_top_edge(stage: HoldGaugeStage, centre_x: float) -> void:
	var y: float = _y_of(stage.zone_top)
	var reach: float = _edge_half_width(stage) + EDGE_REACH
	var left: Vector2 = Vector2(centre_x - reach, y)
	var right: Vector2 = Vector2(centre_x + reach, y)
	_draw_edge_line(stage, left, right)
	_draw_arrow(stage, left, Vector2(-ARROW_LENGTH, 0.0), Color.WHITE)
	_draw_arrow(stage, right, Vector2(ARROW_LENGTH, 0.0), Color.WHITE)


# What a burst looks like after the spray, as stage.burst runs from 0 to 1.
func _draw_failure(stage: HoldGaugeStage, centre_x: float) -> void:
	_draw_drips(stage, centre_x, _fill_colour(stage))


# Drops running down the outside from the top of the container, fading as they go.
func _draw_drips(stage: HoldGaugeStage, centre_x: float, colour: Color) -> void:
	var fallen: float = stage.burst * stage.burst * DRIP_FALL
	var faded: Color = Color(colour, 1.0 - stage.burst)
	for drip: int in DRIP_COUNT:
		var across: float = (float(drip) / (DRIP_COUNT - 1)) * 2.0 - 1.0
		var x: float = centre_x + across * (_half_width_at(1.0) + 6.0)
		var y: float = _top_y() + fallen * (0.6 + 0.4 * sin(drip * 1.7))
		_draw_droplet(stage, Vector2(x, y), DRIP_RADIUS, faded)


# One bubble or drip.
func _draw_droplet(stage: HoldGaugeStage, at: Vector2, radius: float, colour: Color) -> void:
	stage.draw_circle(at, radius, colour)


# Jagged lines, one array of points each, as fractions of the zone band's width and the container's height.
func _draw_cracks(stage: HoldGaugeStage, centre_x: float, cracks: Array) -> void:
	var half_width: float = _zone_half_width()
	var height: float = _bottom_y() - _top_y()
	for crack: Array in cracks:
		var points: PackedVector2Array = []
		for point: Vector2 in crack:
			var x: float = centre_x - half_width + point.x * half_width * 2.0
			points.append(Vector2(x, _top_y() + point.y * height))
		stage.draw_polyline(points, UITheme.WHITE_SOFT, CRACK_WIDTH, true)
