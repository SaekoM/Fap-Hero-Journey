class_name HeartGaugeArt
extends VerticalGaugeArt

# A heart: it fills with rose from the point upward, little hearts rising through it, and above the cleft the fill
# divides into its two lobes. It beats all the while, faster near the top edge, where it also whitens. Overfilled, it
# breaks in two down the middle and little hearts fall.
#
# The shape is the classic parametric heart. Its widths are worked out once, per level, because the outline has two
# edges on each side above the cleft, which a plain width can't describe.

const LEVEL_BINS: int = 128
const WIDTH_SAMPLES: int = 1440
const OUTLINE_POINTS: int = 96
# The curve's own units, before scaling to fit the area.
const CURVE_LOWEST: float = -17.0
const CURVE_HIGHEST: float = 11.92
const CURVE_CLEFT: float = 5.0
const CURVE_HALF_WIDTH: float = 16.0
# The break: each half swings out from the point and sinks a little, along one jagged edge. Each entry is how far from
# the point to the cleft (0–1), and how far that edge is off the centre line there.
const BREAK_EDGE: Array[Vector2] = [
	Vector2(0.0, 0.0),
	Vector2(0.18, 7.0),
	Vector2(0.36, -6.0),
	Vector2(0.54, 8.0),
	Vector2(0.72, -7.0),
	Vector2(0.88, 5.0),
	Vector2(1.0, 0.0),
]
const BREAK_SPREAD: float = 20.0
const BREAK_DROP: float = 8.0
const BREAK_TILT: float = 0.16
const FLYING_HEARTS: int = 12
const FLYING_FARTHEST: float = 130.0
const FLYING_FALL: float = 70.0
const FLYING_ARC_START: float = -PI * 0.9
const FLYING_ARC_END: float = -PI * 0.1
const HEART_FLOAT_OFFSET_X: float = 170.0  # clear of the lobes
const ROSE: Color = Color(0.95, 0.33, 0.55)
const LITTLE_HEART_SCALE: float = 2.2
# Its heartbeat: resting, then quickening as it nears the limit.
const BEATS_AT_REST: float = 1.0
const BEATS_IN_DANGER: float = 2.6
const FIRST_THUMP_AT: float = 0.1
const SECOND_THUMP_AT: float = 0.32
const SECOND_THUMP_STRENGTH: float = 0.7
const THUMP_WIDTH: float = 0.07
const GLOW_CENTRE_LEVEL: float = 0.55
const GLOW_GROWTH: float = 0.05
const GLOW_ALPHA: float = 0.6
const GLOW_WIDTH: float = 5.0
const STEADY_GLOW: float = 0.4
const HEARTBEAT_PITCH_FAR: float = 0.9
const HEARTBEAT_PITCH_NEAR: float = 1.15
const ZONE_FLASH_MIX: float = 0.7
const ZONE_BOTTOM_EDGE_WIDTH: float = 2.0

var _outer_widths: PackedFloat32Array = []  # per level bin: how far the heart reaches from its centre
var _inner_widths: PackedFloat32Array = []  # per level bin: how far the cleft reaches, 0 below it
var _beat_phase: float = 0.0  # 0–1 through the current heartbeat
var _last_clock: float = 0.0
var _reduce_flashing: bool = SettingsService.get_reduce_flashing()


func _init() -> void:
	_measure_widths()


func _measure_widths() -> void:
	_outer_widths.resize(LEVEL_BINS + 1)
	_inner_widths.resize(LEVEL_BINS + 1)
	_inner_widths.fill(INF)
	var cleft_level: float = _level_of_curve(CURVE_CLEFT)
	for sample: int in WIDTH_SAMPLES:
		var point: Vector2 = _curve_point(TAU * sample / WIDTH_SAMPLES)
		var level: float = _level_of_curve(point.y)
		var bin: int = clampi(roundi(level * LEVEL_BINS), 0, LEVEL_BINS)
		var reach: float = absf(point.x) * _curve_scale()
		_outer_widths[bin] = maxf(_outer_widths[bin], reach)
		_inner_widths[bin] = minf(_inner_widths[bin], reach)
	# A bin the samples missed takes its neighbour's width, and below the cleft there's no gap to leave.
	for bin: int in range(1, LEVEL_BINS + 1):
		if _outer_widths[bin] <= 0.0:
			_outer_widths[bin] = _outer_widths[bin - 1]
			_inner_widths[bin] = _inner_widths[bin - 1]
	for bin: int in LEVEL_BINS + 1:
		if float(bin) / LEVEL_BINS <= cleft_level:
			_inner_widths[bin] = 0.0


static func _curve_point(angle: float) -> Vector2:
	var across: float = 16.0 * pow(sin(angle), 3.0)
	var up: float = (
		13.0 * cos(angle) - 5.0 * cos(2.0 * angle) - 2.0 * cos(3.0 * angle) - cos(4.0 * angle)
	)
	return Vector2(across, up)


static func _level_of_curve(height: float) -> float:
	return inverse_lerp(CURVE_LOWEST, CURVE_HIGHEST, height)


func _curve_scale() -> float:
	return (_bottom_y() - _top_y()) / (CURVE_HIGHEST - CURVE_LOWEST)


func _bin_of(level: float) -> int:
	return clampi(roundi(level * LEVEL_BINS), 0, LEVEL_BINS)


func _half_width_at(level: float) -> float:
	return _outer_widths[_bin_of(level)]


func _inner_half_width_at(level: float) -> float:
	return _inner_widths[_bin_of(level)]


func _zone_half_width() -> float:
	return CURVE_HALF_WIDTH * _curve_scale()


func _edge_half_width(stage: HoldGaugeStage) -> float:
	return _half_width_at(stage.zone_top)


func _fill_colour(stage: HoldGaugeStage) -> Color:
	return ROSE.lerp(Color.WHITE, _heat(stage) * HOT_WHITENING)


func float_offset_x() -> float:
	return HEART_FLOAT_OFFSET_X


func sprays_on_failure() -> bool:
	return false


func play_fail_sound() -> void:
	UISound.gauge_heartbreak()


# Instead of a creak, its own heartbeat, at the pace of the glow.
func play_danger_sound(danger: float) -> void:
	UISound.gauge_heartbeat(lerpf(HEARTBEAT_PITCH_FAR, HEARTBEAT_PITCH_NEAR, danger))


func danger_sound_gap(danger: float) -> float:
	return 1.0 / _beats_per_second(danger)


# Once broken it's a picture of its own, because the zone, the surface and the rest don't belong on two drifting halves.
func draw_gauge(stage: HoldGaugeStage) -> void:
	if stage.has_burst():
		_draw_broken(stage, stage.size.x / 2.0)
	else:
		super(stage)


# Each row is one or two spans.
func _draw_row(
	stage: HoldGaugeStage, centre_x: float, level: float, top: float, height: float, colour: Color
) -> void:
	var outer: float = _half_width_at(level)
	var inner: float = _inner_half_width_at(level)
	var width: float = outer - inner
	stage.draw_rect(Rect2(centre_x - outer, top, width, height), colour)
	stage.draw_rect(Rect2(centre_x + inner, top, width, height), colour)


# The zone follows the heart's outline. A rectangle would stick out well past it near the point.
func _draw_zone(stage: HoldGaugeStage, centre_x: float) -> void:
	var top: float = _y_of(stage.zone_top)
	var bottom: float = _y_of(stage.zone_bottom)
	var colour: Color = stage.accent.lerp(Color.WHITE, stage.flash * ZONE_FLASH_MIX)
	var y: float = bottom
	while y > top:
		var row_top: float = maxf(y - ROW_HEIGHT, top)
		var share: float = inverse_lerp(bottom, top, y)
		var alpha: float = lerpf(ZONE_BOTTOM_ALPHA, ZONE_TOP_ALPHA, share)
		var level: float = inverse_lerp(_bottom_y(), _top_y(), y)
		_draw_row(stage, centre_x, level, row_top, y - row_top, Color(colour, alpha))
		y = row_top
	var reach: float = _half_width_at(stage.zone_bottom)
	stage.draw_line(
		Vector2(centre_x - reach, bottom),
		Vector2(centre_x + reach, bottom),
		stage.accent,
		ZONE_BOTTOM_EDGE_WIDTH
	)


# The outline, with a soft glow beating round it.
func _draw_shell(stage: HoldGaugeStage, centre_x: float) -> void:
	var outline: PackedVector2Array = []
	for step: int in OUTLINE_POINTS + 1:
		var point: Vector2 = _curve_point(TAU * step / OUTLINE_POINTS)
		var x: float = point.x * _curve_scale()
		outline.append(Vector2(centre_x + x, _y_of(_level_of_curve(point.y))))
	_draw_beat_glow(stage, outline, Vector2(centre_x, _y_of(GLOW_CENTRE_LEVEL)))
	stage.draw_polyline(outline, ROSE, SHELL_WIDTH, true)


# ── Broken ───────────────────────────────────────────────────────────────────


func _draw_broken(stage: HoldGaugeStage, centre_x: float) -> void:
	var settled: float = 1.0 - pow(1.0 - stage.burst, 2.0)
	var point: Vector2 = Vector2(centre_x + stage.shake_x, _bottom_y())
	for side: float in [-1.0, 1.0]:
		var moved: Vector2 = Vector2(side * BREAK_SPREAD, BREAK_DROP) * settled
		stage.draw_set_transform(point + moved, side * BREAK_TILT * settled)
		_draw_half(stage, side)
	stage.draw_set_transform(Vector2(stage.shake_x, 0.0))
	_draw_flying_hearts(stage, centre_x, settled)


# One half, with the heart's point at the origin.
func _draw_half(stage: HoldGaugeStage, side: float) -> void:
	var y: float = _bottom_y()
	while y > _top_y():
		var row_top: float = maxf(y - ROW_HEIGHT, _top_y())
		var level: float = inverse_lerp(_bottom_y(), _top_y(), y)
		var span: Vector2 = half_span_at(level, side)
		stage.draw_rect(
			Rect2(span.x, row_top - _bottom_y(), span.y - span.x, y - row_top + ROW_OVERLAP), ROSE
		)
		y = row_top
	stage.draw_polyline(_half_outline(side), Color.WHITE, SHELL_WIDTH, true)


# Where one half reaches across at `level`, as (left, right) from the centre line.
func half_span_at(level: float, side: float) -> Vector2:
	var outer: float = _half_width_at(level)
	var inner: float = _inner_half_width_at(level)
	var edge: float = inner * side if inner > 0.0 else _break_edge_at(level)
	return Vector2(edge, outer) if side > 0.0 else Vector2(-outer, edge)


# How far the jagged edge is off the centre line at `level`. It only runs from the point to the cleft.
func _break_edge_at(level: float) -> float:
	var along: float = level / _level_of_curve(CURVE_CLEFT)
	for index: int in range(1, BREAK_EDGE.size()):
		if along <= BREAK_EDGE[index].x:
			var before: Vector2 = BREAK_EDGE[index - 1]
			var share: float = inverse_lerp(before.x, BREAK_EDGE[index].x, along)
			return lerpf(before.y, BREAK_EDGE[index].y, share)
	return 0.0


# Round the outside from the cleft down to the point, then back up the jagged edge.
func _half_outline(side: float) -> PackedVector2Array:
	var outline: PackedVector2Array = []
	var half_points: int = floori(OUTLINE_POINTS / 2.0)
	for step: int in half_points + 1:
		var point: Vector2 = _curve_point(PI * step / half_points)
		var height: float = _y_of(_level_of_curve(point.y)) - _bottom_y()
		outline.append(Vector2(side * point.x * _curve_scale(), height))
	var cleft_level: float = _level_of_curve(CURVE_CLEFT)
	for corner: Vector2 in BREAK_EDGE:
		outline.append(Vector2(corner.y, _y_of(corner.x * cleft_level) - _bottom_y()))
	return outline


# Little hearts thrown up from the break, falling and fading.
func _draw_flying_hearts(stage: HoldGaugeStage, centre_x: float, settled: float) -> void:
	var origin: Vector2 = Vector2(centre_x, _y_of(_level_of_curve(CURVE_CLEFT)))
	var colour: Color = Color(ROSE, 1.0 - stage.burst)
	for index: int in FLYING_HEARTS:
		var across: float = float(index) / (FLYING_HEARTS - 1)
		var heading: Vector2 = Vector2.from_angle(lerpf(FLYING_ARC_START, FLYING_ARC_END, across))
		var distance: float = FLYING_FARTHEST * settled * (0.6 + 0.1 * (index % 5))
		var fallen: float = stage.burst * stage.burst * FLYING_FALL
		var at: Vector2 = origin + heading * distance + Vector2(0.0, fallen)
		_draw_droplet(stage, at, 2.0 + index % 3, colour)


# A steady glow with REDUCE FLASHING on, since a beat is a repeating pulse of light.
func _draw_beat_glow(stage: HoldGaugeStage, outline: PackedVector2Array, centre: Vector2) -> void:
	_advance_beat(stage)
	var beat: float = STEADY_GLOW if _reduce_flashing else _beat_strength()
	var grown: float = 1.0 + GLOW_GROWTH * beat
	var glow: PackedVector2Array = []
	for point: Vector2 in outline:
		glow.append(centre + (point - centre) * grown)
	stage.draw_polyline(glow, Color(ROSE, GLOW_ALPHA * beat), GLOW_WIDTH, true)


func _advance_beat(stage: HoldGaugeStage) -> void:
	var elapsed: float = maxf(0.0, stage.clock - _last_clock)
	_last_clock = stage.clock
	_beat_phase = fposmod(_beat_phase + elapsed * _beats_per_second(stage.danger()), 1.0)


static func _beats_per_second(danger: float) -> float:
	return lerpf(BEATS_AT_REST, BEATS_IN_DANGER, danger)


# A heartbeat's two thumps within one beat: a strong one, and a softer one just after.
func _beat_strength() -> float:
	return maxf(_thump(FIRST_THUMP_AT, 1.0), _thump(SECOND_THUMP_AT, SECOND_THUMP_STRENGTH))


func _thump(at: float, strength: float) -> float:
	var off_by: float = (_beat_phase - at) / THUMP_WIDTH
	return strength * exp(-off_by * off_by)


# Little hearts instead of bubbles and drips: two circles over a point.
func _draw_droplet(stage: HoldGaugeStage, at: Vector2, radius: float, colour: Color) -> void:
	var size: float = radius * LITTLE_HEART_SCALE
	var lobe: float = size * 0.55
	var shoulder: Vector2 = Vector2(size * 0.5, -size * 0.25)
	stage.draw_circle(at - Vector2(shoulder.x, -shoulder.y), lobe, colour)
	stage.draw_circle(at + shoulder, lobe, colour)
	(
		stage
		. draw_colored_polygon(
			PackedVector2Array(
				[
					at + Vector2(-size * 1.0, 0.0),
					at + Vector2(size * 1.0, 0.0),
					at + Vector2(0.0, size * 1.2),
				]
			),
			colour
		)
	)


# A good release's ripple is a growing heart.
func draw_ripple(stage: HoldGaugeStage, at: Vector2, radius: float, colour: Color) -> void:
	var points: PackedVector2Array = []
	for step: int in RIPPLE_POINTS + 1:
		var point: Vector2 = _curve_point(TAU * step / RIPPLE_POINTS)
		points.append(at + Vector2(point.x, -point.y) * radius / CURVE_HALF_WIDTH)
	stage.draw_polyline(points, colour, RIPPLE_WIDTH, true)
