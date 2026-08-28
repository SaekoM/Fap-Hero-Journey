class_name StrokeMeter
extends Control

# Draws what the script is asking of the stroker RIGHT NOW, so a delay can be judged against the device
# instead of guessed at.
#
# Two readouts, because they answer different questions:
#   • THE PISTON — a marker at the script's current position, on the device's own axis. This is the thing
#     you compare against what you can feel.
#   • THE STRIP — the next few seconds of the curve scrolling past a NOW line. The piston alone is purely
#     reactive: you can only notice a mismatch after it has already happened. Seeing the turn coming is
#     what makes a phase judgement possible at all.
#
# It draws the SCRIPT — the position at the raw round clock, undelayed. The delay is what moves the
# DEVICE against this picture. Drawing the delayed position instead would move the picture, and the
# slider would look like it does nothing. The dashed marker shows where the delay currently puts the
# device, so the setting is visible rather than only felt.
#
# Backend-agnostic on purpose: it is handed points and a clock, and neither where those came from nor
# what is on the other end is its business.
#
# Stroke-modifying items and curses are deliberately NOT reflected. They change how FAR the device
# travels, never WHEN — and the timing is the whole point of the picture.

const PISTON_W: float = 34.0
const GUTTER: float = 12.0
const PUCK_H: float = 5.0
const PAD_V: float = 4.0  # keeps the puck off the track's ends at the extremes of travel
const WINDOW_MS: int = 4000  # how much of the script the strip spans
const NOW_FRAC: float = 0.28  # where NOW sits across it; the rest is what's coming
const DASH_LEN: float = 5.0
const LEGEND_SIZE: int = 10
const DEFAULT_HEIGHT: float = 96.0  # enough for the curve to have shape in a side drawer

var _points_source: Callable = Callable()
var _clock: Callable = Callable()
var _delay_ms_source: Callable = Callable()


func _ready() -> void:
	# The meter is a readout, never a target — it sits inside panels whose controls must stay clickable.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The curve is drawn past the right edge of the window so its last segment isn't cut short; this is
	# what keeps that overshoot inside the widget.
	clip_contents = true
	# Only when the owner hasn't asked for a size. _ready runs after they set one, so assigning
	# unconditionally would shrink the calibration screen's tall meter back to drawer height.
	if custom_minimum_size.y <= 0.0:
		custom_minimum_size = Vector2(0, DEFAULT_HEIGHT)
	set_process(true)


# `points_source` returns the HandyPoints stream to draw; `clock` returns the current position in ms on
# the same timeline those points are stamped against.
#
# Both are read every frame rather than captured once, because what is driving the device can change
# under an open panel — an override item seizes it mid-round and plays something else entirely. A meter
# still showing the round's script then would be wrong at exactly the moment it looks most authoritative.
func set_source(points_source: Callable, clock: Callable) -> void:
	_points_source = points_source
	_clock = clock
	queue_redraw()


# Where the delay currently sits. A Callable rather than a value because the dashed marker has to track
# a slider while it is being dragged.
func set_delay_source(delay_ms: Callable) -> void:
	_delay_ms_source = delay_ms


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func _points() -> Array:
	return _points_source.call() if _points_source.is_valid() else []


func _now_ms() -> int:
	return int(_clock.call()) if _clock.is_valid() else 0


func _delay_ms() -> int:
	return int(_delay_ms_source.call()) if _delay_ms_source.is_valid() else 0


func _draw() -> void:
	var piston: Rect2 = Rect2(0.0, 0.0, PISTON_W, size.y)
	var strip: Rect2 = Rect2(PISTON_W + GUTTER, 0.0, maxf(0.0, size.x - PISTON_W - GUTTER), size.y)
	var now: int = _now_ms()
	# Sampled once and passed down, so the piston and the strip can never disagree about which script they
	# are drawing on a frame where the source changed between them.
	var points: Array = _points()
	_draw_piston(piston, points, now)
	_draw_strip(strip, points, now)


# Screen y for a script position, top = 100. Inset by the puck so a stroke at either extreme still draws
# a whole marker instead of half of one.
#
# Static, and named without the underscore, because the two mappings below are the whole geometry of this
# widget and worth pinning down in a test — particularly time_to_x, where the sign decides whether a
# player calibrates in the right direction or exactly the wrong one.
static func pos_to_y(rect: Rect2, pos: float) -> float:
	var top: float = rect.position.y + PAD_V
	var travel: float = maxf(1.0, rect.size.y - PAD_V * 2.0)
	return top + travel * (1.0 - clampf(pos / 100.0, 0.0, 1.0))


# Screen x for a script time. A moment EARLIER than the window's left edge maps further left, which is
# what puts the device marker behind NOW when the delay is positive — a positive delay means the device
# is executing script from that many milliseconds ago.
static func time_to_x(strip: Rect2, t: int, t_left: int) -> float:
	return strip.position.x + strip.size.x * float(t - t_left) / float(WINDOW_MS)


func _draw_piston(rect: Rect2, points: Array, now: int) -> void:
	draw_rect(rect, Color(UITheme.PURPLE_DARK, 0.55))
	var mid_y: float = pos_to_y(rect, 50.0)
	draw_line(
		Vector2(rect.position.x, mid_y),
		Vector2(rect.end.x, mid_y),
		Color(UITheme.SEPARATOR, 0.35),
		1.0
	)
	if not points.is_empty():
		var y: float = pos_to_y(rect, float(HandyPoints.sample_pos(points, now)))
		# Filled from the bottom as well as marked: the fill reads from the corner of an eye, which is
		# how this gets looked at while attention is elsewhere.
		draw_rect(Rect2(rect.position.x, y, rect.size.x, rect.end.y - y), Color(UITheme.CYAN, 0.16))
		draw_rect(Rect2(rect.position.x, y - PUCK_H * 0.5, rect.size.x, PUCK_H), UITheme.CYAN)
	draw_rect(rect, Color(UITheme.SEPARATOR, 0.7), false, 1.0)


func _draw_strip(strip: Rect2, points: Array, now: int) -> void:
	if strip.size.x <= 1.0:
		return
	draw_rect(strip, Color(UITheme.PURPLE_DARK, 0.35))
	var mid_y: float = pos_to_y(strip, 50.0)
	draw_line(
		Vector2(strip.position.x, mid_y),
		Vector2(strip.end.x, mid_y),
		Color(UITheme.SEPARATOR, 0.25),
		1.0
	)

	if points.is_empty():
		_draw_legend(strip, "NO SCRIPT", UITheme.DARK_TEXT, 0)
		draw_rect(strip, Color(UITheme.SEPARATOR, 0.5), false, 1.0)
		return

	var t_left: int = now - int(WINDOW_MS * NOW_FRAC)
	_draw_curve(strip, points, t_left)

	var delay: int = _delay_ms()
	if delay != 0:
		# A positive delay means the device is executing script from `delay` ms ago, which is to the LEFT
		# of now — so this marker sits where the device should be, not where the video is.
		_draw_dashed_v(
			time_to_x(strip, now - delay, t_left), strip.position.y, strip.end.y, UITheme.AMBER
		)
	var now_x: float = time_to_x(strip, now, t_left)
	draw_line(Vector2(now_x, strip.position.y), Vector2(now_x, strip.end.y), UITheme.CYAN, 2.0)
	_draw_legend(strip, "NOW", UITheme.CYAN, delay)
	draw_rect(strip, Color(UITheme.SEPARATOR, 0.5), false, 1.0)


# The curve as individual segments rather than a polyline: the same choice FunscriptPreview makes,
# because a polyline triangulates into visible seams at the sharp corners a stroke script is made of.
func _draw_curve(strip: Rect2, points: Array, t_left: int) -> void:
	var t_right: int = t_left + WINDOW_MS
	var color: Color = Color(UITheme.WHITE_SOFT, 0.85)
	# Start from the interpolated value AT the left edge, so a segment that entered the window before it
	# opened is drawn from that edge instead of appearing only once its next point arrives.
	var prev: Vector2 = Vector2(
		strip.position.x, pos_to_y(strip, float(HandyPoints.sample_pos(points, t_left)))
	)
	var first: int = maxi(0, HandyPoints.index_at_or_after(points, t_left) - 1)
	for i: int in range(first, points.size()):
		var point: Dictionary = points[i]
		var t: int = int(point["t"])
		if t <= t_left:
			continue
		var here: Vector2 = Vector2(time_to_x(strip, t, t_left), pos_to_y(strip, float(point["x"])))
		draw_line(prev, here, color, 2.0, true)
		prev = here
		if t >= t_right:
			return


func _draw_dashed_v(x: float, top: float, bottom: float, color: Color) -> void:
	var y: float = top
	while y < bottom:
		draw_line(Vector2(x, y), Vector2(x, minf(y + DASH_LEN, bottom)), color, 1.0)
		y += DASH_LEN * 2.0


# Names the two markers. Without it the dashed line reads as decoration, and the whole point of it is
# that it says what the delay is doing.
func _draw_legend(strip: Rect2, now_text: String, now_color: Color, delay: int) -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		return
	var at: Vector2 = strip.position + Vector2(6.0, 13.0)
	draw_string(font, at, now_text, HORIZONTAL_ALIGNMENT_LEFT, -1, LEGEND_SIZE, now_color)
	if delay != 0:
		draw_string(
			font,
			at + Vector2(0.0, 13.0),
			"DEVICE %+d ms" % delay,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			LEGEND_SIZE,
			UITheme.AMBER
		)
