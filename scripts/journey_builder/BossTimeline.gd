class_name BossTimeline
extends Control
## The boss encounter's authoring surface: the round's clock drawn as LANES of event blocks — attacks,
## effects, cast cues and audio — with a phase band above them (BOSS_ROUND_DESIGN §6). Blocks are
## dragged to move, their right edge dragged to resize, and clicked to select; CTRL+wheel zooms around
## the cursor and middle-drag pans, exactly like the override editor's timeline.
##
## Purely a view/input widget, like OverrideTimeline: it owns no journey data and writes nothing back.
## Edits leave as signals and the editor decides what they mean, which is what keeps undo, validation
## and persistence in one place instead of smeared through the drawing code.
##
## Positions are milliseconds on the round's clock. END-anchored events are resolved for display
## through RoundTimeline.resolve_at_ms, so an event authored as "10 s before the end" sits where it will
## actually play; dragging one reports a new offset measured from whichever end it is anchored to.
##
## (The ms↔x mapping, zoom and pan mirror OverrideTimeline's. They are deliberately re-stated rather
## than shared: that widget is shipped and verified, and hoisting a base class out from under it is a
## refactor worth doing on its own, not in the middle of building this.)

signal event_selected(id: String)
signal event_moved(id: String, at_ms: int)  # a block was dragged; at_ms is in its own anchor's terms
signal event_resized(id: String, duration_ms: int)
## The LEFT edge was dragged. `at_ms` is the block's new start, in its own anchor; the END stays put.
##
## Its own signal rather than a move plus a resize, because for a media block the two are one gesture
## with one meaning: cut this much off the FRONT of the source. Reported as a move would have slid the
## block later and then cut its tail, which is the opposite of what the drag looks like.
signal event_head_dragged(id: String, at_ms: int)
signal playhead_scrubbed(ms: int)
signal view_changed(start_ms: int, span_ms: int)
## Something was dragged out of the Boss Kit and dropped on the track. `kind` is what the kit item was
## ("track" / "phase") and `value` names it; `at_ms` is where it landed on the round's clock.
signal kit_dropped(kind: String, value: String, at_ms: int)
## The track was right-clicked at `at_ms`. The widget offers no menu of its own — it reports WHERE, and
## the editor decides what can be done there.
signal context_menu_requested(at_ms: int, at_global: Vector2)

## A phase marker was dragged along the health strip. `hp_at` is the health it now takes over at, 0..1.
signal phase_moved(id: String, hp_at: float)

const PAD: float = 8.0
const MIN_VIEW_MS: int = 500
const ZOOM_STEP: float = 0.8

# A one-shot has no duration, so it is drawn as a fixed-width marker instead of a zero-wide sliver.
const MARKER_W: float = 10.0

# How much of its colour a block keeps when its branch is not the one currently rolled. Gentler than it
# was under the flat layout: the branch ROW now carries that signal, so the block only has to look
# secondary rather than do the whole job of saying "not this one".
const DORMANT_ALPHA: float = 0.55

# Width of the drawn resize grip at each end of a windowed block, and the grab tolerance around it.
# The grip is VISIBLE rather than an invisible hot zone — an edge you cannot see is an edge you find by
# accident.
const HANDLE_W: float = 6.0
const EDGE_GRAB_PX: float = 8.0

# A window cannot be resized below this — a shorter one is indistinguishable from a one-shot.
const MIN_DURATION_MS: int = 100

# Reference strip: the round's own stroke curve, drawn above the lanes so events can be placed against
# real actions rather than by eye.
const REFERENCE_H: float = 96.0

const LANE_H: float = 30.0
const LANE_GAP: float = 4.0
const PHASE_BAND_H: float = 16.0
# The health strip's own ground, matching the HUD bar's backing so it reads as the bar laid flat rather
# than as one more lane of the time track it sits above.
const STRIP_BACKING: Color = Color(0.10, 0.0, 0.02, 1.0)
const RULER_H: float = 14.0
const LABEL_W: float = 58.0  # gutter holding each lane's name

# ── Segment strips ──────────────────────────────────────────────────────────
# A segment is drawn as its OWN block below the backbone lanes: a header, then one row per branch.
# Parallel rows are what makes exclusivity legible — "one of these plays" needs no explaining — and they
# also fix the flat layout's real defect, where two branches at the same time stacked on one lane and
# only the topmost could ever be clicked.
const SEGMENT_HEADER_H: float = 18.0
const SEGMENT_GAP: float = 8.0

# The gutter widens when segments exist, because a branch row is labelled with the CONDITION that picks
# it. Printing the rule at the exact place and time it applies is the whole point — logic parked in a
# side panel is what made the structure feel implied.
const SEGMENT_LABEL_W: float = 168.0

# Backing for the branch row the current roll picked, so the live path reads at a glance.
const LIVE_ROW_BG: Color = Color(1, 1, 1, 0.07)
const DEAD_ROW_BG: Color = Color(1, 1, 1, 0.02)
# Two near-identical greys were the only thing saying which branch the preview had picked, which read as
# "cycling did nothing". The live row now gets a coloured rail down its left edge and says so in words.
const LIVE_RAIL_W: float = 3.0
const DORMANT_TEXT_ALPHA: float = 0.45

# Lane order, top to bottom. Attacks lead because they are the encounter's spine.
const LANES: Array[String] = [
	RoundTimeline.TRACK_ATTACK,
	RoundTimeline.TRACK_STANCE,
	RoundTimeline.TRACK_EFFECT,
	RoundTimeline.TRACK_CAST,
	RoundTimeline.TRACK_AUDIO
]

var _reference: Array = []  # Array[Vector2] (t_ms, pos 0-100) — the round's main stroke, for sync
# Extra curves drawn over the reference in ABSOLUTE round time: an imported attack's own stroke, and the
# transformed curve inside an effect window. [{points: Array[Vector2], color: Color}]
var _overlays: Array = []
# Ids that failed validation — drawn with a ⚠ so the problem is on the block, not in a footnote.
var _issues: Dictionary = {}
var _events: Array = []  # normalized events, in the editor's own order
var _phases: Array = []
var _full_ms: int = 1
var _selected_id: String = ""
var _dormant_tags: Array = []
# value → display name for anything a branch rule can name, so the gutter reads "Silver Key" and not the
# id it is stored under. Supplied by the editor, which is the side that knows this journey's items.
var _value_labels: Dictionary = {}
var _segments: Array = []
var _collapsed: Dictionary = {}  # segment_id → true while its rows are folded away
# Derived layout, rebuilt whenever the events, segments or fold states change: tag → row y, plus the
# per-segment geometry the header and bracket are drawn from.
var _row_y: Dictionary = {}
var _strips: Array = []
var _strips_h: float = 0.0
var _playhead_ms: int = -1

var _view_start: int = 0
var _view_span: int = 1

var _drag: String = ""  # "", "move", "resize", "scrub", "pan"
var _drag_id: String = ""
var _drag_grab_offset_ms: int = 0  # cursor-to-block-start distance, so a move doesn't snap to the cursor
var _drag_end_ms: int = 0  # a left-edge resize pins the block's END, so it is captured when the drag starts
var _pan_anchor_ms: int = 0
# Where a win skips the clip to, or NO_TIME. Held resolved rather than as the encounter's own
# offset-plus-anchor, because the widget only ever needs to know which column to draw the flag in.
var _win_point_ms: int = RoundTimeline.NO_TIME


func _init() -> void:
	clip_contents = true
	custom_minimum_size = Vector2(0, _preferred_height())
	focus_mode = Control.FOCUS_CLICK


## Feeds the whole timeline and resets the view to the full round. `full_ms` is the round video's
## length — the clock everything is placed against, and what END-anchored events resolve through.
func setup(timeline: Dictionary, full_ms: int) -> void:
	_events = (timeline.get("events", []) as Array).duplicate(true)
	_phases = (timeline.get("phases", []) as Array).duplicate(true)
	_segments = (timeline.get("segments", []) as Array).duplicate(true)
	_full_ms = maxi(1, full_ms)
	_rebuild_layout()
	_view_start = 0
	_view_span = _full_ms
	queue_redraw()
	view_changed.emit(_view_start, _view_span)


## Swaps the event list without disturbing zoom, pan or selection — the editor calls this after every
## edit, and resetting the view each time would make authoring unusable.
## Branch tags the preview did NOT pick this roll. Their blocks stay on the lane — an author has to see
## everything they wrote — but are drawn faded, so which branch is currently live reads at a glance and
## RE-ROLL visibly swaps it.
func set_value_labels(labels: Dictionary) -> void:
	_value_labels = labels


## Where a win skips the clip to, already resolved against the round's length. NO_TIME hides the flag.
func set_win_point(at_ms: int) -> void:
	if _win_point_ms == at_ms:
		return
	_win_point_ms = at_ms
	queue_redraw()


func set_dormant_tags(tags: Array) -> void:
	if _dormant_tags == tags:
		return
	_dormant_tags = tags
	_rebuild_layout()
	queue_redraw()


func set_events(events: Array, phases: Array, segments: Array = []) -> void:
	_events = events.duplicate(true)
	_phases = phases.duplicate(true)
	_segments = segments.duplicate(true)
	_rebuild_layout()
	queue_redraw()


func set_selected(id: String) -> void:
	if _selected_id == id:
		return
	_selected_id = id
	queue_redraw()


func get_selected() -> String:
	return _selected_id


## External playback (the device test-play) drives the playhead; -1 hides it.
func set_playhead(ms: int) -> void:
	_playhead_ms = ms
	queue_redraw()


func set_view_start(start_ms: int) -> void:
	var s: int = clampi(start_ms, 0, maxi(0, _full_ms - _view_span))
	if s == _view_start:
		return
	_view_start = s
	queue_redraw()
	view_changed.emit(_view_start, _view_span)


func _preferred_height() -> float:
	return (
		REFERENCE_H
		+ PHASE_BAND_H
		+ LANES.size() * (LANE_H + LANE_GAP)
		+ _strips_h
		+ RULER_H
		+ 2.0 * PAD
	)


# The gutter has to hold a condition once segments exist; before that the narrow lane names are plenty.
func _gutter_w() -> float:
	return SEGMENT_LABEL_W if not _segments.is_empty() else LABEL_W


# Where the backbone lanes end and the segment strips begin.
func _strips_top() -> float:
	return PAD + REFERENCE_H + PHASE_BAND_H + LANES.size() * (LANE_H + LANE_GAP)


# Recomputes every segment's header and branch-row positions, and the span each strip brackets. Derived
# rather than authored: a segment has no time of its own, so the bracket is simply the extent of the
# events tagged into it — which is also the honest answer to "how far does this fork reach".
func _rebuild_layout() -> void:
	_row_y.clear()
	_strips.clear()
	var y: float = _strips_top()
	for segment: Dictionary in _segments:
		var id: String = str(segment.get("id", ""))
		var folded: bool = bool(_collapsed.get(id, false))
		var strip: Dictionary = {
			"id": id,
			"name": str(segment.get("name", "")),
			"header_y": y,
			"folded": folded,
			"rows": [],
			"from_ms": -1,
			"to_ms": -1,
		}
		y += SEGMENT_HEADER_H
		for branch: Dictionary in segment.get("branches", []) as Array:
			var tag: String = str(branch.get("tag", ""))
			var row: Dictionary = {
				"tag": tag,
				"y": y,
				"text": RoundTimeline.condition_text(branch.get("condition", {}), _value_labels),
				"live": not _dormant_tags.has(tag),
			}
			if not folded:
				_row_y[tag] = y
				y += LANE_H + LANE_GAP
			(strip["rows"] as Array).append(row)
			_extend_span(strip, tag)
		_strips.append(strip)
		y += SEGMENT_GAP
	_strips_h = maxf(0.0, y - _strips_top())
	custom_minimum_size = Vector2(0, _preferred_height())


# Grows a strip's bracket to cover every event carrying `tag`.
func _extend_span(strip: Dictionary, tag: String) -> void:
	for event: Dictionary in _events:
		if str(event.get("variant_tag", "")) != tag:
			continue
		var at: int = _event_at_ms(event)
		var end: int = at + int(event.get("duration_ms", 0))
		if int(strip["from_ms"]) < 0 or at < int(strip["from_ms"]):
			strip["from_ms"] = at
		if end > int(strip["to_ms"]):
			strip["to_ms"] = end


# An event on a FOLDED segment is not drawn at all — it is summarised by the header's chip instead. It
# must therefore not be hit-testable either, which falls out of both going through this one predicate.
func _event_visible(event: Dictionary) -> bool:
	var tag: String = str(event.get("variant_tag", ""))
	return tag == "" or _row_y.has(tag)


## The round's main funscript, as (t_ms, pos) points, drawn as a reference strip above the lanes.
func set_reference(actions: Array) -> void:
	_reference = actions
	queue_redraw()


## Curves drawn on top of the reference, already in absolute round time — an attack's stroke where it
## will play, or an effect window's transformed curve. Replaces whatever was there.
func set_overlays(overlays: Array) -> void:
	_overlays = overlays
	queue_redraw()


## Ids with a validation problem, as a set. Marked on the block itself rather than listed elsewhere.
func set_issues(issue_ids: Dictionary) -> void:
	_issues = issue_ids
	queue_redraw()


# ── View maths ───────────────────────────────────────────────────────────────


func _track_x0() -> float:
	return PAD + _gutter_w()


func _span_px() -> float:
	return maxf(1.0, size.x - _track_x0() - PAD)


func _ms_to_x(ms: int) -> float:
	return _track_x0() + (float(ms - _view_start) / float(_view_span)) * _span_px()


# The health strip spans the whole track width regardless of zoom: 1.0 at the left, 0.0 at the right,
# the same direction the bar drains.
func _hp_to_x(hp_at: float) -> float:
	return _track_x0() + (1.0 - clampf(hp_at, 0.0, 1.0)) * _span_px()


func _x_to_hp(x: float) -> float:
	return clampf(1.0 - (x - _track_x0()) / _span_px(), 0.0, 1.0)


# Phases in play order with their health points resolved. Not cached: the list is a handful of entries
# and it has to follow an edit immediately, which is the whole reason the widget redraws.
func _resolved_phases() -> Array:
	return RoundTimeline.resolved_phases({"phases": _phases}, _full_ms)


func _x_to_ms(x: float) -> int:
	return clampi(
		_view_start + roundi((x - _track_x0()) / _span_px() * float(_view_span)), 0, _full_ms
	)


func _zoom_at(factor: float, anchor_x: float) -> void:
	var new_span: int = clampi(roundi(float(_view_span) * factor), MIN_VIEW_MS, _full_ms)
	if new_span == _view_span:
		return
	var anchor_ms: int = _x_to_ms(anchor_x)
	var frac: float = clampf((anchor_x - _track_x0()) / _span_px(), 0.0, 1.0)
	_view_span = new_span
	_view_start = clampi(anchor_ms - roundi(frac * float(new_span)), 0, _full_ms - new_span)
	queue_redraw()
	view_changed.emit(_view_start, _view_span)


# Where an event actually sits on the round's clock, END anchors included.
func _event_at_ms(event: Dictionary) -> int:
	var at: int = RoundTimeline.resolve_at_ms(event, _full_ms)
	return 0 if at == RoundTimeline.NO_TIME else at


func _lane_y(track: String) -> float:
	var index: int = LANES.find(track)
	if index < 0:
		index = 0
	return PAD + REFERENCE_H + PHASE_BAND_H + index * (LANE_H + LANE_GAP)


# The on-screen rect of one event block.
func _event_rect(event: Dictionary) -> Rect2:
	var at: int = _event_at_ms(event)
	var x: float = _ms_to_x(at)
	var duration: int = int(event.get("duration_ms", 0))
	var w: float = MARKER_W if duration <= 0 else maxf(MARKER_W, _ms_to_x(at + duration) - x)
	return Rect2(x, _event_row_y(event), w, LANE_H)


# A tagged event sits in its BRANCH's row; everything untagged stays on the backbone lane for its track.
# Track identity is carried by the block's colour either way, so nothing is lost by moving it.
func _event_row_y(event: Dictionary) -> float:
	var tag: String = str(event.get("variant_tag", ""))
	if tag != "" and _row_y.has(tag):
		return float(_row_y[tag])
	return _lane_y(str(event.get("track", "")))


# ── Input ────────────────────────────────────────────────────────────────────


func _gui_input(event: InputEvent) -> void:
	# accept_event() on everything handled, so a drag here never also scrolls whatever holds the lanes.
	#
	# The WHEEL is the deliberate exception. A plain wheel is left unhandled so it reaches the scroll
	# container the lanes sit in — segments stack downwards without limit, so scrolling is the common
	# thing to want and zooming the rare one. Zoom moved to CTRL+wheel, where every other timeline in
	# every other tool puts it.
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed and mb.ctrl_pressed:
					_zoom_at(ZOOM_STEP, mb.position.x)
					accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed and mb.ctrl_pressed:
					_zoom_at(1.0 / ZOOM_STEP, mb.position.x)
					accept_event()
			MOUSE_BUTTON_MIDDLE:
				_drag = "pan" if mb.pressed else ""
				if mb.pressed:
					_pan_anchor_ms = _x_to_ms(mb.position.x)
				accept_event()
			MOUSE_BUTTON_RIGHT:
				# A menu rather than an immediate edit: right-clicking is how people probe an unfamiliar
				# widget, and a bare click that silently moved the win flag punished that.
				if mb.pressed and mb.position.x >= _track_x0():
					context_menu_requested.emit(
						_x_to_ms(mb.position.x), get_global_mouse_position()
					)
				accept_event()
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					if not _toggle_strip_at(mb.position):
						_begin_drag(mb.position)
				else:
					_drag = ""
					_drag_id = ""
				accept_event()
	elif event is InputEventMouseMotion and _drag != "":
		_apply_drag((event as InputEventMouseMotion).position)
		accept_event()


# Decides what a press means: grabbing a block's right edge resizes it, its body moves it, and empty
# track scrubs the playhead.
func _begin_drag(pos: Vector2) -> void:
	# The health strip sits above the lanes and owns its own drags, so a marker can be slid along it
	# without fighting the events underneath.
	if pos.y >= PAD + REFERENCE_H and pos.y < PAD + REFERENCE_H + PHASE_BAND_H:
		var phase: Dictionary = _phase_at_point(pos)
		if not phase.is_empty():
			var phase_id: String = str(phase["id"])
			set_selected(phase_id)
			event_selected.emit(phase_id)
			_drag = "phase"
			_drag_id = phase_id
			return
	var hit: Dictionary = _event_at_point(pos)
	if hit.is_empty():
		# Empty track scrubs and nothing else — dropping the selection here would cost it every time the
		# playhead moved, which is exactly when an author is checking the block they have selected.
		# Deselecting is the video stage's job instead.
		_drag = "scrub"
		_apply_drag(pos)
		return
	var id: String = str(hit["id"])
	set_selected(id)
	event_selected.emit(id)
	var rect: Rect2 = _event_rect(hit)
	var windowed: bool = int(hit.get("duration_ms", 0)) > 0
	if windowed and pos.x >= rect.end.x - EDGE_GRAB_PX:
		_drag = "resize"
	elif windowed and pos.x <= rect.position.x + EDGE_GRAB_PX:
		# Dragging the LEFT grip pins the end and cuts into the front. On a media block that means the
		# SOURCE is cut — an attack can be reduced to its middle strokes rather than always having to
		# begin at the funscript's first one.
		_drag = "resize_left"
		_drag_end_ms = _event_at_ms(hit) + int(hit.get("duration_ms", 0))
	else:
		_drag = "move"
		# Remember where inside the block the grab landed, so dragging moves it rather than teleporting
		# its start to the cursor.
		_drag_grab_offset_ms = _x_to_ms(pos.x) - _event_at_ms(hit)
	_drag_id = id


func _apply_drag(pos: Vector2) -> void:
	match _drag:
		"scrub":
			_playhead_ms = _x_to_ms(pos.x)
			playhead_scrubbed.emit(_playhead_ms)
		"pan":
			set_view_start(
				_pan_anchor_ms - roundi((pos.x - _track_x0()) / _span_px() * float(_view_span))
			)
		"move":
			var event: Dictionary = _find(_drag_id)
			if not event.is_empty():
				var start: int = clampi(_x_to_ms(pos.x) - _drag_grab_offset_ms, 0, _full_ms)
				# Reported in the event's OWN terms: an end-anchored block's offset is measured back
				# from the round's end, so dragging it right makes that offset smaller.
				var reported: int = start
				if str(event.get("anchor", RoundTimeline.ANCHOR_START)) == RoundTimeline.ANCHOR_END:
					reported = maxi(0, _full_ms - start)
				event_moved.emit(_drag_id, reported)
		"resize":
			var event: Dictionary = _find(_drag_id)
			if not event.is_empty():
				var duration: int = _x_to_ms(pos.x) - _event_at_ms(event)
				event_resized.emit(_drag_id, maxi(MIN_DURATION_MS, duration))
		"phase":
			var phase: Dictionary = _find_phase(_drag_id)
			if not phase.is_empty():
				phase_moved.emit(_drag_id, _x_to_hp(pos.x))
		"resize_left":
			var event: Dictionary = _find(_drag_id)
			if not event.is_empty():
				# Clamped so the start can never cross the pinned end.
				var start: int = clampi(_x_to_ms(pos.x), 0, _drag_end_ms - MIN_DURATION_MS)
				var reported: int = start
				if str(event.get("anchor", RoundTimeline.ANCHOR_START)) == RoundTimeline.ANCHOR_END:
					reported = maxi(0, _full_ms - start)
				event_head_dragged.emit(_drag_id, reported)
	queue_redraw()


# ── Drag-and-drop from the Boss Kit ──────────────────────────────────────────


# The kit's payload is a plain dictionary under one key, so an unrelated drag (a file, another widget's
# data) is refused rather than misread as an event.
func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	return data is Dictionary and (data as Dictionary).has("boss_kit")


# The drop's X gives the TIME; what to create comes from the kit item itself, not from which lane it
# landed on — an ATTACK dragged onto the audio row is still meant to be an attack, and silently turning
# it into something else would be worse than placing it where it belongs.
func _drop_data(pos: Vector2, data: Variant) -> void:
	var payload: Dictionary = (data as Dictionary)["boss_kit"]
	kit_dropped.emit(str(payload.get("type", "")), str(payload.get("value", "")), _x_to_ms(pos.x))


# Topmost event under a point, or {}. Later events win, matching the draw order.
func _event_at_point(pos: Vector2) -> Dictionary:
	var found: Dictionary = {}
	for event: Dictionary in _events:
		if _event_visible(event) and _event_rect(event).has_point(pos):
			found = event
	return found


# The phase whose stretch of the strip contains `pos` — the last one starting at or before it, so the
# click lands on the stretch the author sees rather than only on its 1px start line.
func _phase_at_point(pos: Vector2) -> Dictionary:
	var found: Dictionary = {}
	for phase: Dictionary in _resolved_phases():
		if _hp_to_x(float(phase["resolved_hp_at"])) <= pos.x:
			found = _find_phase(str(phase["id"]))
	return found


func _find_phase(id: String) -> Dictionary:
	for phase: Dictionary in _phases:
		if str(phase.get("id", "")) == id:
			return phase
	return {}


func _find(id: String) -> Dictionary:
	for event: Dictionary in _events:
		if str(event.get("id", "")) == id:
			return event
	return {}


# ── Drawing ──────────────────────────────────────────────────────────────────


func _draw() -> void:
	if size.x <= _track_x0() + PAD or size.y <= 2.0 * PAD:
		return
	draw_rect(Rect2(Vector2.ZERO, size), UITheme.CARD_BG_DIM)
	_draw_grid()
	_draw_reference()
	_draw_phase_band()
	_draw_lanes()
	_draw_strips()
	for event: Dictionary in _events:
		if _event_visible(event):
			_draw_event(event)
	_draw_win_point()
	_draw_playhead()
	_draw_ruler()


# The health bar laid flat: full health at the left, empty at the right, cut into the stages the author
# wrote. It is NOT the clock — it does not zoom or scroll with the tracks below it, because health is a
# different axis, and drawing phases on the time track was what made the bar and the banners disagree.
# Its own dark backing says so at a glance.
func _draw_phase_band() -> void:
	var y: float = PAD + REFERENCE_H
	draw_rect(Rect2(_track_x0(), y, _span_px(), PHASE_BAND_H), STRIP_BACKING)
	draw_string(
		ThemeDB.fallback_font,
		Vector2(PAD, y + PHASE_BAND_H - 4.0),
		"HEALTH",
		HORIZONTAL_ALIGNMENT_LEFT,
		LABEL_W - 4.0,
		10,
		UITheme.DARK_TEXT
	)
	var phases: Array = _resolved_phases()
	for i: int in phases.size():
		var phase: Dictionary = phases[i]
		var x0: float = _hp_to_x(float(phase["resolved_hp_at"]))
		# Each stage runs until the next one takes over; the last runs to an empty bar.
		var x1: float = _track_x0() + _span_px()
		if i + 1 < phases.size():
			x1 = _hp_to_x(float((phases[i + 1] as Dictionary)["resolved_hp_at"]))
		var tint: Color = RoundTimeline.phase_tint(phase, UITheme.PURPLE_MID)
		if str(phase.get("id", "")) == _selected_id:
			tint = UITheme.PURPLE_BRIGHT
		draw_rect(
			Rect2(x0, y, maxf(2.0, x1 - x0), PHASE_BAND_H), Color(tint.r, tint.g, tint.b, 0.22)
		)
		draw_line(Vector2(x0, y), Vector2(x0, y + PHASE_BAND_H), tint, 2.0)
		var label: String = str(phase.get("name", ""))
		if label != "":
			draw_string(
				ThemeDB.fallback_font,
				Vector2(x0 + 4.0, y + PHASE_BAND_H - 4.0),
				label,
				HORIZONTAL_ALIGNMENT_LEFT,
				maxf(0.0, x1 - x0 - 8.0),
				10,
				tint
			)


# Vertical time gridlines with stamps along the bottom, so an event can be placed to a readable time
# instead of by eye. The step is chosen so the visible span always shows a handful of lines: at full
# zoom that is minutes, and deep in it is a second or less.
func _draw_grid() -> void:
	var step: int = _grid_step_ms()
	var first: int = (_view_start / step) * step
	var line_top: float = PAD
	var line_bottom: float = size.y - RULER_H
	var t: int = first
	while t <= _view_start + _view_span:
		if t >= _view_start:
			var x: float = _ms_to_x(t)
			draw_line(Vector2(x, line_top), Vector2(x, line_bottom), Color(1, 1, 1, 0.06), 1.0)
			draw_string(
				ThemeDB.fallback_font,
				Vector2(x + 3.0, size.y - 3.0),
				JourneyData.ms_to_mmss(t),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				9,
				UITheme.DARK_TEXT
			)
		t += step


# The coarsest step that still fits a useful number of lines across the view — the same ladder a video
# editor walks, so the grid never collapses into a smear or thins out to nothing.
func _grid_step_ms() -> int:
	for step: int in [
		250, 500, 1000, 2000, 5000, 10000, 15000, 30000, 60000, 120000, 300000, 600000
	]:
		if _view_span / step <= 12:
			return step
	return 1800000


# The round's stroke curve. Only the visible span is walked — a long script at full zoom would otherwise
# cost thousands of segments a frame for a strip a few dozen pixels tall.
func _draw_reference() -> void:
	var top: float = PAD
	var bottom: float = PAD + REFERENCE_H - 4.0
	draw_rect(Rect2(_track_x0(), top, _span_px(), REFERENCE_H - 4.0), Color(1, 1, 1, 0.02))
	# Stroke-height lines, so a curve can be read against real positions instead of eyeballed. 0 and 100
	# are the travel limits and drawn brighter; the quarters are guides.
	for level: int in [0, 25, 50, 75, 100]:
		var y: float = lerpf(bottom, top, level / 100.0)
		var edge: bool = level == 0 or level == 100
		draw_line(
			Vector2(_track_x0(), y),
			Vector2(_track_x0() + _span_px(), y),
			Color(1, 1, 1, 0.16 if edge else 0.07),
			1.0
		)
		draw_string(
			ThemeDB.fallback_font,
			Vector2(PAD, y + 3.0),
			str(level),
			HORIZONTAL_ALIGNMENT_RIGHT,
			LABEL_W - 6.0,
			9,
			UITheme.DARK_TEXT
		)
	if _reference.size() < 2:
		return
	var view_end: int = _view_start + _view_span
	var previous: Vector2 = Vector2.ZERO
	var has_previous: bool = false
	for point: Vector2 in _reference:
		var t: int = int(point.x)
		if t < _view_start or t > view_end:
			has_previous = false  # off-screen: break the line rather than bridging the gap
			continue
		var here: Vector2 = Vector2(
			_ms_to_x(t), lerpf(bottom, top, clampf(point.y / 100.0, 0.0, 1.0))
		)
		if has_previous:
			draw_line(previous, here, UITheme.PURPLE_MID, 1.0)
		previous = here
		has_previous = true

	for overlay: Dictionary in _overlays:
		_draw_overlay_curve(overlay, top, bottom)


# One overlay curve — an attack's own stroke, or an effect window's transformed one — drawn brighter
# and thicker than the reference so it reads as ON TOP of the round's script rather than part of it.
func _draw_overlay_curve(overlay: Dictionary, top: float, bottom: float) -> void:
	var points: Array = overlay.get("points", [])
	if points.size() < 2:
		return
	var color: Color = overlay.get("color", UITheme.WHITE_SOFT)
	var view_end: int = _view_start + _view_span
	var previous: Vector2 = Vector2.ZERO
	var has_previous: bool = false
	for point: Vector2 in points:
		var t: int = int(point.x)
		if t < _view_start or t > view_end:
			has_previous = false
			continue
		var here: Vector2 = Vector2(
			_ms_to_x(t), lerpf(bottom, top, clampf(point.y / 100.0, 0.0, 1.0))
		)
		if has_previous:
			draw_line(previous, here, color, 2.0)
		previous = here
		has_previous = true


func _draw_lanes() -> void:
	for track: String in LANES:
		var y: float = _lane_y(track)
		draw_rect(Rect2(_track_x0(), y, _span_px(), LANE_H), Color(1, 1, 1, 0.03))
		draw_string(
			ThemeDB.fallback_font,
			Vector2(PAD, y + LANE_H * 0.65),
			track.to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT,
			LABEL_W - 4.0,
			10,
			UITheme.DARK_TEXT
		)


# A segment as its own block: a header naming the fork, then one row per branch labelled with the rule
# that picks it. The rows being PARALLEL is what says "one of these plays" — the thing the flat layout
# could only imply.
# Folds or unfolds the segment whose header was clicked, reporting whether it consumed the click so a
# header press never also starts dragging whatever happens to sit behind it.
func _toggle_strip_at(pos: Vector2) -> bool:
	for strip: Dictionary in _strips:
		var y: float = float(strip["header_y"])
		if pos.y >= y and pos.y < y + SEGMENT_HEADER_H:
			var id: String = str(strip["id"])
			_collapsed[id] = not bool(_collapsed.get(id, false))
			_rebuild_layout()
			queue_redraw()
			return true
	return false


func _draw_strips() -> void:
	for strip: Dictionary in _strips:
		_draw_strip_header(strip)
		if bool(strip["folded"]):
			continue
		_draw_strip_bracket(strip)
		for row: Dictionary in strip["rows"] as Array:
			_draw_branch_row(row)


func _draw_strip_header(strip: Dictionary) -> void:
	var y: float = float(strip["header_y"])
	var rows: int = (strip["rows"] as Array).size()
	var folded: bool = bool(strip["folded"])
	draw_rect(
		Rect2(PAD, y, size.x - 2.0 * PAD, SEGMENT_HEADER_H),
		Color(UITheme.CYAN.r, UITheme.CYAN.g, UITheme.CYAN.b, 0.10)
	)
	var name: String = str(strip["name"])
	if name == "":
		name = "SEGMENT"
	# Folded, the strip still has to say what it is hiding, or collapsing one would look like deleting it.
	var caption: String = "%s  %s" % ["▶" if folded else "▼", name.to_upper()]
	if folded:
		caption += "  ·  %d branches" % rows
	draw_string(
		ThemeDB.fallback_font,
		Vector2(PAD + 4.0, y + SEGMENT_HEADER_H * 0.75),
		caption,
		HORIZONTAL_ALIGNMENT_LEFT,
		size.x - 2.0 * PAD - 8.0,
		10,
		UITheme.CYAN
	)


# The bracket spans exactly the events tagged into this segment — the fork's reach, drawn rather than
# inferred. Nothing tagged yet means nothing to bracket.
func _draw_strip_bracket(strip: Dictionary) -> void:
	if int(strip["from_ms"]) < 0:
		return
	var x0: float = _ms_to_x(int(strip["from_ms"]))
	var x1: float = maxf(x0 + 2.0, _ms_to_x(int(strip["to_ms"])))
	var y: float = float(strip["header_y"]) + SEGMENT_HEADER_H - 2.0
	var tint: Color = Color(UITheme.CYAN.r, UITheme.CYAN.g, UITheme.CYAN.b, 0.55)
	draw_line(Vector2(x0, y), Vector2(x1, y), tint, 1.0)
	draw_line(Vector2(x0, y), Vector2(x0, y + 4.0), tint, 1.0)
	draw_line(Vector2(x1, y), Vector2(x1, y + 4.0), tint, 1.0)


func _draw_branch_row(row: Dictionary) -> void:
	var y: float = float(row["y"])
	var live: bool = bool(row["live"])
	draw_rect(Rect2(_track_x0(), y, _span_px(), LANE_H), LIVE_ROW_BG if live else DEAD_ROW_BG)
	if live:
		# Runs the full width, not just the gutter, so the picked branch is obvious wherever the author
		# happens to be looking along the track.
		draw_rect(Rect2(_track_x0(), y, LIVE_RAIL_W, LANE_H), UITheme.CYAN)
		draw_rect(Rect2(_track_x0(), y + LANE_H - 1.0, _span_px(), 1.0), Color(UITheme.CYAN, 0.35))
	# The rule, then the branch it selects — read left to right it is a sentence: "score < 100 → GENTLE".
	draw_string(
		ThemeDB.fallback_font,
		Vector2(PAD + 6.0, y + LANE_H * 0.45),
		str(row["text"]),
		HORIZONTAL_ALIGNMENT_LEFT,
		_gutter_w() - 10.0,
		9,
		UITheme.WHITE_SOFT if live else UITheme.DARK_TEXT
	)
	draw_string(
		ThemeDB.fallback_font,
		Vector2(PAD + 6.0, y + LANE_H * 0.88),
		("▶ " if live else "→ ") + str(row["tag"]),
		HORIZONTAL_ALIGNMENT_LEFT,
		_gutter_w() - 10.0,
		10,
		UITheme.CYAN if live else Color(UITheme.DARK_TEXT, DORMANT_TEXT_ALPHA)
	)


func _draw_event(event: Dictionary) -> void:
	var rect: Rect2 = _event_rect(event)
	# Cheap cull: a zoomed-in view can leave most of the encounter off-screen.
	if rect.end.x < _track_x0() or rect.position.x > size.x:
		return
	var color: Color = track_color(str(event.get("track", "")))
	var selected: bool = str(event.get("id", "")) == _selected_id
	# A block on a branch this roll did not pick is dimmed rather than hidden: an author needs to see
	# every branch they wrote, and hiding half the timeline whenever the dice landed differently would
	# make the encounter look like it had lost content.
	var dormant: bool = _dormant_tags.has(str(event.get("variant_tag", "")))
	if dormant:
		color = Color(color.r, color.g, color.b, color.a * DORMANT_ALPHA)
	# A block with a validation problem is HIGHLIGHTED rather than badged: an icon needs room a short
	# block does not have and competes with the label, whereas a colour shift reads at any width and at
	# any zoom. The track colour still shows through the fill, so what KIND of event it is stays legible.
	var flagged: bool = _issues.has(str(event.get("id", "")))
	var body: Rect2 = rect.grow_individual(0.0, -3.0, 0.0, -3.0)
	draw_rect(body, Color(color.r, color.g, color.b, 0.85 if selected else 0.55))
	if flagged:
		draw_rect(body, Color(UITheme.AMBER.r, UITheme.AMBER.g, UITheme.AMBER.b, 0.22))
		draw_rect(body, UITheme.AMBER, false, 2.0)
	else:
		draw_rect(body, color if selected else Color(color.r, color.g, color.b, 0.7), false, 1.0)
	# Resize grips, on windowed blocks only — a one-shot has no length to drag.
	if int(event.get("duration_ms", 0)) > 0 and body.size.x > HANDLE_W * 3.0:
		var grip: Color = UITheme.WHITE_SOFT if selected else Color(color.r, color.g, color.b, 0.9)
		draw_rect(Rect2(body.position.x, body.position.y, HANDLE_W, body.size.y), grip)
		draw_rect(Rect2(body.end.x - HANDLE_W, body.position.y, HANDLE_W, body.size.y), grip)
	# End-anchored blocks get a tick on their right edge — the end they are measured from.
	if str(event.get("anchor", RoundTimeline.ANCHOR_START)) == RoundTimeline.ANCHOR_END:
		draw_line(Vector2(body.end.x, body.position.y), body.end, UITheme.WHITE_SOFT, 2.0)
	var label: String = _event_label(event)
	if label != "" and body.size.x > 22.0:
		draw_string(
			ThemeDB.fallback_font,
			Vector2(body.position.x + 4.0, body.position.y + body.size.y * 0.7),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			body.size.x - 8.0,
			10,
			UITheme.WHITE_SOFT
		)


# A block's caption: whatever identifies the event to its author at a glance.
static func _event_label(event: Dictionary) -> String:
	match str(event.get("track", "")):
		RoundTimeline.TRACK_ATTACK:
			return str(event.get("name", "ATTACK"))
		RoundTimeline.TRACK_CAST:
			var text: String = str(event.get("text", ""))
			return text if text != "" else "CUE"
		RoundTimeline.TRACK_AUDIO:
			return str(event.get("clip", "")).get_file()
		RoundTimeline.TRACK_EFFECT:
			var effects: Array = event.get("effects", [])
			if effects.is_empty():
				return "EFFECT"
			return str((effects[0] as Dictionary).get("kind", "EFFECT")).to_upper()
	return ""


static func track_color(track: String) -> Color:
	match track:
		RoundTimeline.TRACK_ATTACK:
			return UITheme.DANGER
		RoundTimeline.TRACK_STANCE:
			return UITheme.TOXIC_GREEN
		RoundTimeline.TRACK_EFFECT:
			return UITheme.PURPLE_BRIGHT
		RoundTimeline.TRACK_CAST:
			return UITheme.CYAN
		RoundTimeline.TRACK_AUDIO:
			return UITheme.AMBER
	return UITheme.DARK_TEXT


# The point a win skips the clip to, as a flag rather than another hairline: it is a property of the
# encounter, not a position the author is currently at, and must not be mistaken for the playhead.
func _draw_win_point() -> void:
	if _win_point_ms == RoundTimeline.NO_TIME:
		return
	var x: float = _ms_to_x(_win_point_ms)
	if x < _track_x0() or x > size.x:
		return
	var bottom: float = size.y - RULER_H
	draw_line(Vector2(x, PAD), Vector2(x, bottom), UITheme.TOXIC_GREEN, 1.0)
	draw_string(
		ThemeDB.fallback_font,
		Vector2(x + 4.0, PAD + 10.0),
		"⚑ WIN",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		9,
		UITheme.TOXIC_GREEN
	)


func _draw_playhead() -> void:
	if _playhead_ms < 0:
		return
	var x: float = _ms_to_x(_playhead_ms)
	if x < _track_x0() or x > size.x:
		return
	draw_line(Vector2(x, PAD), Vector2(x, size.y - RULER_H), UITheme.WHITE_SOFT, 1.0)


# The visible range's start/end, so a zoomed view stays oriented.
func _draw_ruler() -> void:
	var y: float = size.y - 3.0
	draw_string(
		ThemeDB.fallback_font,
		Vector2(_track_x0(), y),
		JourneyData.ms_to_mmss(_view_start),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		10,
		UITheme.DARK_TEXT
	)
	draw_string(
		ThemeDB.fallback_font,
		Vector2(_track_x0(), y),
		JourneyData.ms_to_mmss(_view_start + _view_span),
		HORIZONTAL_ALIGNMENT_RIGHT,
		_span_px(),
		10,
		UITheme.DARK_TEXT
	)
