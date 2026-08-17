class_name OverrideTimeline
extends Control

# A wide, seekable, ZOOMABLE funscript timeline for authoring an override's trim window. Draws the main
# stroke big with the axis/vib channels as thin lanes beneath, shades the excluded head/tail, and exposes
# draggable IN/OUT handles plus a scrubbable playhead. Mouse wheel zooms around the cursor and middle-drag
# pans; a sibling scrollbar (wired by the editor via view_changed / set_view_start) pans too. It owns no
# journey data — it reports edits through signals and the item editor writes them back — so it stays a
# pure view/input widget.
#
# All positions are milliseconds against the FULL clip. x maps across the padded width of the VISIBLE
# range [_view_start, _view_start + _view_span]; at full zoom that range is the whole clip. clip_contents
# keeps zoomed-out geometry from painting past the widget. Kept a class_name (like HandyPoints) so it's
# reusable and statically resolvable.

signal trim_changed(in_ms: int, out_ms: int)  # an IN/OUT handle drag settled on a new window
signal playhead_scrubbed(ms: int)  # the user dragged the playhead (used to seek a device preview)
signal view_changed(start_ms: int, span_ms: int)  # zoom/pan moved the visible range (drives a scrollbar)

const PAD: float = 8.0  # inset so handles at the view edges are still grabbable
const HANDLE_GRAB_PX: float = 12.0  # click tolerance around a handle before it counts as a scrub
const MIN_WINDOW_MS: int = 200  # the trim window can't collapse past this, so IN never crosses OUT
const MIN_VIEW_MS: int = 500  # deepest zoom — half a second across the full width
const ZOOM_STEP: float = 0.8  # each wheel notch scales the visible span by this
const LANE_GAP: float = 4.0  # vertical gap between channel rows
const RULER_H: float = 12.0  # bottom strip reserved for the view start/end time labels

var _main: Array = []  # Array[Vector2] (t_ms, pos 0-100) — the main stroke (possibly effect-transformed)
var _main_label: String = "MAIN"  # relabelled to flag when an effects preview is being shown
var _main_ghost: Array = []  # the pre-effect stroke, drawn faint under the main (empty = no ghost)
var _lanes: Array = []  # [{name:String, points:Array[Vector2], color:Color}] — axes + vibes
var _full_ms: int = 1
var _in_ms: int = 0
var _out_ms: int = 1
var _playhead_ms: int = -1  # -1 = hidden (no active preview / scrub)
var _drag: String = ""  # "", "in", "out", "scrub", "pan"
var _pan_anchor_ms: int = 0  # clip ms under the cursor when a middle-drag pan began
var _view_start: int = 0  # left edge of the visible range, in clip ms
var _view_span: int = 1  # width of the visible range, in clip ms (== _full_ms at full zoom)


func _init() -> void:
	custom_minimum_size = Vector2(0, 210)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_HSIZE
	clip_contents = true  # zoomed-out curves/handles must not paint outside the widget rect


# Feeds the channels + current window and resets the view to the whole clip. `main_label` heads the main
# row (e.g. flags an effects preview); `main_ghost` is an optional faint underlay of the raw stroke.
func setup(
	main: Array,
	lanes: Array,
	full_ms: int,
	in_ms: int,
	out_ms: int,
	main_label: String = "MAIN",
	main_ghost: Array = []
) -> void:
	_main = main
	_main_label = main_label
	_main_ghost = main_ghost
	_lanes = lanes
	_full_ms = maxi(1, full_ms)
	_in_ms = clampi(in_ms, 0, _full_ms)
	_out_ms = clampi(out_ms if out_ms > 0 else _full_ms, _in_ms + MIN_WINDOW_MS, _full_ms)
	_view_start = 0
	_view_span = _full_ms
	queue_redraw()


# Swaps just the main channel (its curve, label, ghost) without touching the zoom/window — so the effects
# preview can refresh live while an effect is tuned, without resetting the view the author set up.
func set_main(main: Array, main_label: String, main_ghost: Array) -> void:
	_main = main
	_main_label = main_label
	_main_ghost = main_ghost
	queue_redraw()


# External playback (device test-play) drives the playhead here; -1 hides it.
func set_playhead(ms: int) -> void:
	_playhead_ms = ms if ms < 0 else clampi(ms, 0, _full_ms)
	queue_redraw()


func get_in_ms() -> int:
	return _in_ms


func get_out_ms() -> int:
	return _out_ms


# Lets the numeric fields push edits back into the view without re-emitting (no feedback loop).
func set_window(in_ms: int, out_ms: int) -> void:
	_in_ms = clampi(in_ms, 0, _full_ms - MIN_WINDOW_MS)
	_out_ms = clampi(out_ms, _in_ms + MIN_WINDOW_MS, _full_ms)
	queue_redraw()


# Pans the visible range (the sibling scrollbar calls this). Emits view_changed so the two stay in sync.
func set_view_start(start_ms: int) -> void:
	var s: int = clampi(start_ms, 0, maxi(0, _full_ms - _view_span))
	if s == _view_start:
		return
	_view_start = s
	queue_redraw()
	view_changed.emit(_view_start, _view_span)


func _span_px() -> float:
	return maxf(1.0, size.x - 2.0 * PAD)


func _ms_to_x(ms: int) -> float:
	return PAD + (float(ms - _view_start) / float(_view_span)) * _span_px()


func _x_to_ms(x: float) -> int:
	return clampi(_view_start + roundi((x - PAD) / _span_px() * float(_view_span)), 0, _full_ms)


# Zooms the visible span by `factor` while keeping the clip time under `anchor_x` pinned to that x.
func _zoom_at(factor: float, anchor_x: float) -> void:
	var new_span: int = clampi(roundi(float(_view_span) * factor), MIN_VIEW_MS, _full_ms)
	if new_span == _view_span:
		return
	var anchor_ms: int = _x_to_ms(anchor_x)
	var frac: float = clampf((anchor_x - PAD) / _span_px(), 0.0, 1.0)
	_view_span = new_span
	_view_start = clampi(anchor_ms - roundi(frac * float(new_span)), 0, _full_ms - new_span)
	queue_redraw()
	view_changed.emit(_view_start, _view_span)


func _gui_input(event: InputEvent) -> void:
	# accept_event() on everything handled so a wheel/drag here doesn't also scroll the editor's outer
	# ScrollContainer (the timeline lives inside one).
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom_at(ZOOM_STEP, mb.position.x)
					accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom_at(1.0 / ZOOM_STEP, mb.position.x)
					accept_event()
			MOUSE_BUTTON_MIDDLE:
				_drag = "pan" if mb.pressed else ""
				if mb.pressed:
					_pan_anchor_ms = _x_to_ms(mb.position.x)
				accept_event()
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_drag = _pick_target(mb.position.x)
					_apply_drag(mb.position.x)
				else:
					_drag = ""
				accept_event()
	elif event is InputEventMouseMotion and _drag != "":
		_apply_drag((event as InputEventMouseMotion).position.x)
		accept_event()


# Which grip is under the cursor: an IN/OUT handle if within tolerance, otherwise a playhead scrub.
func _pick_target(x: float) -> String:
	var din: float = absf(x - _ms_to_x(_in_ms))
	var dout: float = absf(x - _ms_to_x(_out_ms))
	if din <= HANDLE_GRAB_PX and din <= dout:
		return "in"
	if dout <= HANDLE_GRAB_PX:
		return "out"
	return "scrub"


func _apply_drag(x: float) -> void:
	var ms: int = _x_to_ms(x)
	match _drag:
		"in":
			_in_ms = clampi(ms, 0, _out_ms - MIN_WINDOW_MS)
			trim_changed.emit(_in_ms, _out_ms)
		"out":
			_out_ms = clampi(ms, _in_ms + MIN_WINDOW_MS, _full_ms)
			trim_changed.emit(_in_ms, _out_ms)
		"scrub":
			_playhead_ms = ms
			playhead_scrubbed.emit(ms)
		"pan":
			set_view_start(_pan_anchor_ms - roundi((x - PAD) / _span_px() * float(_view_span)))
	queue_redraw()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if w <= 2.0 * PAD or h <= 2.0 * PAD:
		return

	draw_rect(Rect2(0.0, 0.0, w, h), Color(0.0, 0.0, 0.0, 0.35))

	# Every channel — the main stroke and each axis/vib — gets an equal-height row so they read on the same
	# scale, stacked top to bottom above the time ruler. The main stays green + thicker to mark it as primary.
	var channels: Array = [
		{
			"name": _main_label,
			"points": _main,
			"color": UITheme.TOXIC_GREEN,
			"width": 2.0,
			"ghost": _main_ghost,
		}
	]
	channels.append_array(_lanes)
	var row_h: float = (h - 2.0 * PAD - RULER_H) / float(channels.size())
	var top: float = PAD
	for ch: Dictionary in channels:
		var color: Color = ch.get("color", UITheme.CYAN)
		var band_bot: float = top + row_h - LANE_GAP
		var ghost: Array = ch.get("ghost", [])
		if not ghost.is_empty():  # the raw stroke, faint, so the effect's change reads against it
			_draw_curve(ghost, top, band_bot, Color(0.55, 0.55, 0.55, 0.45), 1.0)
		_draw_lane_label(str(ch.get("name", "")), top, color)
		_draw_curve(ch.get("points", []), top, band_bot, color, float(ch.get("width", 1.0)))
		top += row_h

	# Shade the excluded head/tail so the lit span reads as the section that will play (clip_contents keeps
	# an off-view edge from spilling).
	var in_x: float = _ms_to_x(_in_ms)
	var out_x: float = _ms_to_x(_out_ms)
	var shade: Color = Color(0.0, 0.0, 0.0, 0.55)
	if in_x > 0.0:
		draw_rect(Rect2(0.0, 0.0, in_x, h - RULER_H), shade)
	if out_x < w:
		draw_rect(Rect2(out_x, 0.0, w - out_x, h - RULER_H), shade)

	_draw_handle(in_x, h - RULER_H, "in")
	_draw_handle(out_x, h - RULER_H, "out")

	if _playhead_ms >= 0:
		var px: float = _ms_to_x(_playhead_ms)
		draw_line(Vector2(px, 0.0), Vector2(px, h - RULER_H), UITheme.MAGENTA, 1.5)

	_draw_time_ruler(w, h)


func _draw_curve(actions: Array, top: float, bot: float, color: Color, width: float) -> void:
	if actions.size() < 2:
		return
	var line: PackedVector2Array = PackedVector2Array()
	for a: Variant in actions:
		var v: Vector2 = a
		var x: float = _ms_to_x(int(v.x))
		var yy: float = bot - (clampf(v.y, 0.0, 100.0) / 100.0) * (bot - top)
		line.append(Vector2(x, yy))
	draw_polyline(line, color, width, true)


func _draw_lane_label(text: String, y: float, color: Color) -> void:
	var font: Font = get_theme_default_font()
	if font and text != "":
		draw_string(
			font, Vector2(PAD + 2.0, y + 9.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, color
		)


# The visible range's start/end times (and a hint that scroll zooms), so a zoomed view stays oriented.
func _draw_time_ruler(w: float, h: float) -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		return
	var y: float = h - 2.0
	draw_string(
		font,
		Vector2(PAD, y),
		"%.1fs" % (_view_start / 1000.0),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		9,
		UITheme.SEPARATOR
	)
	if _view_span < _full_ms:
		draw_string(
			font,
			Vector2(w * 0.5 - 40.0, y),
			"scroll to zoom · middle-drag to pan",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			9,
			UITheme.SEPARATOR
		)
	draw_string(
		font,
		Vector2(w - PAD - 44.0, y),
		"%.1fs" % ((_view_start + _view_span) / 1000.0),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		9,
		UITheme.SEPARATOR
	)


# A vertical grip bar with a triangle cap, brighter while its handle is the active drag.
func _draw_handle(x: float, bottom: float, which: String) -> void:
	var color: Color = UITheme.WHITE_SOFT if _drag == which else UITheme.PURPLE_BRIGHT
	draw_line(Vector2(x, 0.0), Vector2(x, bottom), color, 2.0)
	var dir: float = 1.0 if which == "in" else -1.0
	var cap: PackedVector2Array = PackedVector2Array(
		[Vector2(x, 0.0), Vector2(x + dir * 7.0, 0.0), Vector2(x, 9.0)]
	)
	draw_colored_polygon(cap, color)
