class_name GraphView
extends Control

# ---------------------------------------------------------------------------
# GraphView.gd
# Renders a journey's _items[] tree as an auto-laid-out graph. Top-to-bottom
# flow for sequences; forks branch horizontally with each path as a sub-column.
# Recurses through nested forks at arbitrary depth.
#
# Public API:
#   set_items(items: Array)        — sets the model and rebuilds the graph
#   refresh()                      — rebuilds from the current model
# Signals:
#   node_selected(item, arr, idx)  — emitted when a node is clicked
# ---------------------------------------------------------------------------

signal node_selected(item: Dictionary, parent_arr: Array, idx: int)
signal insert_requested(parent_arr: Array, idx: int, screen_pos: Vector2)

const NODE_WIDTH:  float = 200.0
const NODE_HEIGHT: float = 64.0
const V_GAP:       float = 40.0
const H_GAP:       float = 36.0
const PATH_LABEL_HEIGHT: float = 32.0
const INSERT_BTN_SIZE: float = 22.0
const ZOOM_MIN:    float = 0.4
const ZOOM_MAX:    float = 2.0
const ZOOM_STEP:   float = 0.1

var _items:           Array      = []
var _selected_data:   Dictionary = {}
# Items that end the run (no items follow them anywhere in the flow).
# Rebuilt on every refresh() so the set is always current.
var _terminal_items:  Array      = []

# Pan / zoom state
var _pan_offset: Vector2 = Vector2(40, 40)
var _zoom:       float   = 1.0
var _panning:    bool    = false
var _last_mouse: Vector2 = Vector2.ZERO
var _has_initial_center: bool = false

# Auto-layout artefacts (rebuilt on refresh).
# Edges: list of {from: Vector2, to: Vector2, color: Color}
var _edges: Array = []

# Background grid + edges live on _canvas. Nodes are added as children of _canvas
# so they pan/zoom together with edges.
@onready var _canvas: Control = $Canvas


func _ready() -> void:
	clip_contents = true
	# Make sure we receive input events for pan/zoom.
	mouse_filter = Control.MOUSE_FILTER_PASS
	# Force the canvas to have a large bounding rect. A zero-sized Control's
	# _draw() output can be silently culled by the renderer once the parent's
	# transform moves the rect off-axis.
	_canvas.custom_minimum_size = Vector2(8000, 8000)
	_canvas.size = Vector2(8000, 8000)


func set_items(items: Array) -> void:
	_items = items
	refresh()


func refresh() -> void:
	# Tear down old nodes.
	for c in _canvas.get_children():
		c.queue_free()
	_edges.clear()

	# Recompute which items end the run before laying out so _make_node can
	# query the set during layout.
	_terminal_items = _collect_terminal_items(_items, false)

	# Apply pan/zoom transform to the canvas.
	_apply_transform()

	# Lay out items starting at origin (0, 0) — the canvas transform handles offset.
	# We do this deferred so the freed children are gone before we add new ones.
	call_deferred("_do_layout")


func _do_layout() -> void:
	_layout_items(_items, 0.0, 0.0)  # return value not used at top level
	_canvas.set_edges(_edges)
	if not _has_initial_center:
		_has_initial_center = true
		call_deferred("_center_initial_view")


# Aligns the top-center of the graph (where the first item sits, at x=0, y=0
# in canvas-local space) with the top-center of the visible area.
func _center_initial_view() -> void:
	# In case size hasn't been finalised yet, wait one more frame.
	if size.x <= 0.0:
		await get_tree().process_frame
	_pan_offset = Vector2(size.x * 0.5, 40.0)
	_apply_transform()


# Recursively lays out an items[] array as a vertical column centered on x_center.
# Returns { "size": Vector2(max_w, cur_y), "last_nodes": Array[Control] }
# where last_nodes are the Controls at the open ends of this subtree (can be
# multiple after an unresolved fork — used by the caller to draw merge arrows).
func _layout_items(items: Array, x_center: float, y: float) -> Dictionary:
	var cur_y: float = y
	var max_w: float = NODE_WIDTH
	# open_ends: Controls whose bottom port awaits an outgoing edge.
	# After a fork, this holds the last node of each path so merge arrows can
	# be drawn to whatever comes next at this level.
	var open_ends: Array  = []
	# Whether open_ends came from fork paths (drives edge colour for merges).
	var from_fork: bool   = false

	# Insert button before the first item (idx=0). Sits in the gap above y.
	_place_insert_btn(items, 0, x_center, y - V_GAP * 0.5)

	# Empty branch: just show the single insert button.
	if items.is_empty():
		return {"size": Vector2(NODE_WIDTH, y), "last_nodes": []}

	for i in items.size():
		var item: Dictionary = items[i]
		var t: String = item.get("type", "round")

		if t == "fork":
			# ── Fork node ────────────────────────────────────────────────────
			var fork_node: Control = _make_node(item, items, i)
			fork_node.position = Vector2(x_center - NODE_WIDTH * 0.5, cur_y)
			_canvas.add_child(fork_node)
			# Connect whatever preceded this fork to the fork node.
			for oe in open_ends:
				_add_edge(_node_bottom(oe), _node_top(fork_node),
					UITheme.FORK_EDGE if from_fork else UITheme.EDGE)
			cur_y += NODE_HEIGHT + V_GAP

			# Compute path widths (recursive measure).
			var paths: Array = item.get("paths", [])
			var path_widths: Array = []
			for path in paths:
				path_widths.append(max(_measure_items_width(path.get("items", [])), NODE_WIDTH))

			var total_w: float = 0.0
			for w in path_widths:
				total_w += w
			if paths.size() > 1:
				total_w += (paths.size() - 1) * H_GAP
			max_w = max(max_w, total_w)

			# Place each path column, collecting each path's final nodes.
			var col_x: float  = x_center - total_w * 0.5
			var max_branch_y: float = cur_y
			var all_path_ends: Array = []

			for pi in paths.size():
				var path: Dictionary     = paths[pi]
				var pw: float            = path_widths[pi]
				var path_cx: float       = col_x + pw * 0.5

				var label_node: Control = _make_path_label(path, paths, pi)
				label_node.position = Vector2(path_cx - NODE_WIDTH * 0.5, cur_y)
				_canvas.add_child(label_node)
				_add_edge(_node_bottom(fork_node), _node_top(label_node), UITheme.FORK_EDGE)

				var path_items: Array = path.get("items", [])
				var sub: Dictionary   = _layout_items(path_items, path_cx, cur_y + PATH_LABEL_HEIGHT + V_GAP)

				if not path_items.is_empty():
					var first_item_node: Control = _find_first_node_at_x(path_cx, cur_y + PATH_LABEL_HEIGHT + V_GAP)
					if first_item_node != null:
						_add_edge(_node_bottom(label_node), _node_top(first_item_node), UITheme.EDGE)

				max_branch_y = max(max_branch_y, sub["size"].y)
				all_path_ends.append_array(sub["last_nodes"])
				col_x += pw + H_GAP

			cur_y     = max_branch_y
			# Path ends become the new open ends — the next item at this level
			# receives merge arrows from all of them.
			open_ends = all_path_ends
			from_fork = true

		else:
			# ── Non-fork node ────────────────────────────────────────────────
			var is_term: bool  = _terminal_items.any(func(ti: Dictionary) -> bool: return is_same(item, ti))
			var node: Control  = _make_node(item, items, i, is_term)
			node.position = Vector2(x_center - NODE_WIDTH * 0.5, cur_y)
			_canvas.add_child(node)
			# Draw edge(s) from all open ends into this node.
			for oe in open_ends:
				_add_edge(_node_bottom(oe), _node_top(node),
					UITheme.FORK_EDGE if from_fork else UITheme.EDGE)
			open_ends = [node]
			from_fork = false
			cur_y += NODE_HEIGHT + V_GAP

		# Insert button in the gap AFTER this item (idx = i+1).
		_place_insert_btn(items, i + 1, x_center, cur_y - V_GAP * 0.5)

	return {"size": Vector2(max_w, cur_y), "last_nodes": open_ends}


# Returns all items (by reference) that would end the run — i.e., no item in
# the journey flow comes after them. Called once per refresh().
#
# has_successor_after: true when the caller knows something follows this items[]
# array in the parent scope (e.g. the fork that contains this path has a sibling
# item after it at the outer level).
func _collect_terminal_items(items: Array, has_successor_after: bool) -> Array:
	if items.is_empty():
		return []
	var last: Dictionary = items[-1]
	var t: String = last.get("type", "round")
	if t == "fork":
		if has_successor_after:
			# Fork converges into a successor — the fork's paths are not terminal.
			return []
		# Fork is the last item with nothing after it: recurse into each path.
		var result: Array = []
		for path: Dictionary in last.get("paths", []):
			result.append_array(_collect_terminal_items(path.get("items", []), false))
		return result
	else:
		# Non-fork last item.
		if has_successor_after:
			return []
		return [last]


# Recursively measures the width an items[] array will consume at layout time.
func _measure_items_width(items: Array) -> float:
	var max_w: float = NODE_WIDTH
	for item in items:
		if item.get("type", "round") == "fork":
			var paths: Array = item.get("paths", [])
			var sub_total: float = 0.0
			for path in paths:
				sub_total += max(_measure_items_width(path.get("items", [])), NODE_WIDTH)
			if paths.size() > 1:
				sub_total += (paths.size() - 1) * H_GAP
			max_w = max(max_w, sub_total)
	return max_w


func _find_first_node_at_x(x_center: float, y: float) -> Control:
	# Linear scan through canvas children to find the node placed at this position.
	for c in _canvas.get_children():
		if c.position.y == y and abs(c.position.x - (x_center - NODE_WIDTH * 0.5)) < 0.5:
			return c
	return null


# Places a small "+" button centered at (x_center, mid_y) that, when clicked,
# requests an insert into `arr` at the given index.
func _place_insert_btn(arr: Array, idx: int, x_center: float, mid_y: float) -> void:
	var btn: Button = Button.new()
	btn.text = "+"
	btn.size = Vector2(INSERT_BTN_SIZE, INSERT_BTN_SIZE)
	btn.custom_minimum_size = Vector2(INSERT_BTN_SIZE, INSERT_BTN_SIZE)
	btn.position = Vector2(x_center - INSERT_BTN_SIZE * 0.5, mid_y - INSERT_BTN_SIZE * 0.5)
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_color_override("font_color",         UITheme.PURPLE_MID)
	btn.add_theme_color_override("font_hover_color",   UITheme.WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", Color.BLACK)
	btn.add_theme_font_size_override("font_size", 16)

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0.02, 0.0, 0.04, 0.95)
	s.border_color = UITheme.PURPLE_MID
	s.border_width_left   = 1; s.border_width_right  = 1
	s.border_width_top    = 1; s.border_width_bottom = 1
	s.corner_radius_top_left     = 11
	s.corner_radius_top_right    = 11
	s.corner_radius_bottom_left  = 11
	s.corner_radius_bottom_right = 11
	s.content_margin_left   = 0; s.content_margin_right  = 0
	s.content_margin_top    = 0; s.content_margin_bottom = 0
	btn.add_theme_stylebox_override("normal", s)

	var s_hover: StyleBoxFlat = s.duplicate()
	s_hover.bg_color = Color(UITheme.PURPLE_BRIGHT.r, UITheme.PURPLE_BRIGHT.g, UITheme.PURPLE_BRIGHT.b, 0.35)
	s_hover.border_color = UITheme.PURPLE_BRIGHT
	btn.add_theme_stylebox_override("hover", s_hover)

	var s_pressed: StyleBoxFlat = s.duplicate()
	s_pressed.bg_color = UITheme.PURPLE_BRIGHT
	btn.add_theme_stylebox_override("pressed", s_pressed)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	btn.pressed.connect(func() -> void:
		# Report the button's screen-space position so the popup appears near it.
		var screen_pos: Vector2 = btn.get_global_rect().position + Vector2(INSERT_BTN_SIZE, 0)
		emit_signal("insert_requested", arr, idx, screen_pos)
	)

	_canvas.add_child(btn)


# ---------------------------------------------------------------------------
# Node makers
# ---------------------------------------------------------------------------

# is_terminal: true when this node ends the run (no path leads beyond it).
func _make_node(item: Dictionary, arr: Array, idx: int, is_terminal: bool = false) -> Control:
	var t: String = item.get("type", "round")
	var is_boss: bool = t == "round" and item.get("round_type", "normal") == "boss"
	# Terminal nodes use AMBER; boss rounds use DANGER red; else the type colour.
	var accent: Color = UITheme.AMBER if is_terminal else (UITheme.DANGER if is_boss else _type_color(t))
	var icon: String = "⚔" if is_boss else _type_icon(t)
	var primary: String = _type_label(item)
	var secondary: String = _type_sublabel(item)
	if is_terminal:
		secondary = secondary + ("  ·  " if secondary != "" else "") + "END OF RUN"

	var panel: PanelContainer = PanelContainer.new()
	panel.size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	panel.custom_minimum_size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	# Use is_same() (reference identity) — Dictionary's == does deep equality,
	# so two newly-created nodes with identical default fields would compare
	# equal and both light up as "selected".
	var is_selected: bool = is_same(item, _selected_data)
	panel.add_theme_stylebox_override("panel", _node_stylebox(accent, is_selected, is_terminal))

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   10)
	margin.add_theme_constant_override("margin_right",  10)
	margin.add_theme_constant_override("margin_top",    6)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(margin)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	# Icon
	var icon_lbl: Label = Label.new()
	icon_lbl.text = icon
	icon_lbl.add_theme_color_override("font_color", accent)
	icon_lbl.add_theme_font_size_override("font_size", 22)
	icon_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon_lbl)

	# Labels column
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)

	var primary_lbl: Label = Label.new()
	primary_lbl.text = primary
	primary_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	primary_lbl.add_theme_font_size_override("font_size", 13)
	primary_lbl.clip_text = true
	primary_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(primary_lbl)

	var secondary_lbl: Label = Label.new()
	secondary_lbl.text = secondary
	secondary_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	secondary_lbl.add_theme_font_size_override("font_size", 10)
	secondary_lbl.clip_text = true
	secondary_lbl.uppercase = true
	secondary_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(secondary_lbl)

	# Click selection
	panel.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				_select(item, arr, idx)
				accept_event()
	)

	return panel


func _make_path_label(path: Dictionary, paths_arr: Array, path_idx: int) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.size = Vector2(NODE_WIDTH, PATH_LABEL_HEIGHT)
	panel.custom_minimum_size = Vector2(NODE_WIDTH, PATH_LABEL_HEIGHT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.10)
	s.border_color = UITheme.MAGENTA
	s.border_width_left   = 1
	s.border_width_right  = 1
	s.border_width_top    = 1
	s.border_width_bottom = 1
	s.corner_radius_top_left     = 14
	s.corner_radius_top_right    = 14
	s.corner_radius_bottom_left  = 14
	s.corner_radius_bottom_right = 14
	s.content_margin_left   = 12
	s.content_margin_right  = 12
	s.content_margin_top    = 4
	s.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", s)

	var name_text: String = path.get("name", "Path %d" % (path_idx + 1))
	if (name_text as String).strip_edges() == "":
		name_text = "Path %d" % (path_idx + 1)

	var lbl: Label = Label.new()
	lbl.text = "↳ " + name_text.to_upper()
	lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(lbl)

	return panel


func _node_stylebox(accent: Color, selected: bool, terminal: bool = false) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0.04, 0.0, 0.06, 0.96)
	s.border_color = accent
	# Border: thicker when selected; slightly heavier than default when terminal.
	var w: int = 3 if selected else (2 if terminal else 1)
	s.border_width_left   = w
	s.border_width_right  = w
	s.border_width_top    = w
	s.border_width_bottom = w
	s.corner_radius_top_left     = 6
	s.corner_radius_top_right    = 6
	s.corner_radius_bottom_left  = 6
	s.corner_radius_bottom_right = 6
	if selected:
		s.shadow_color = Color(accent.r, accent.g, accent.b, 0.50)
		s.shadow_size  = 8
	elif terminal:
		# Warm amber glow to signal "this is where the run ends".
		s.shadow_color = Color(accent.r, accent.g, accent.b, 0.55)
		s.shadow_size  = 14
	return s


func _type_color(t: String) -> Color:
	match t:
		"round":      return UITheme.PURPLE_BRIGHT
		"shop":       return UITheme.AMBER
		"storyboard": return UITheme.CYAN
		"fork":       return UITheme.MAGENTA
	return UITheme.PURPLE_MID


func _type_icon(t: String) -> String:
	match t:
		"round":      return "▶"
		"shop":       return "◆"
		"storyboard": return "◈"
		"fork":       return "⑂"
	return "•"


func _type_label(item: Dictionary) -> String:
	var t: String = item.get("type", "round")
	match t:
		"round":
			var n: String = item.get("name", "")
			return n if n != "" else "Round"
		"shop":
			var n2: String = item.get("title", "")
			return n2 if n2 != "" else "Shop"
		"storyboard":
			var first_speaker: String = ""
			var lines: Array = item.get("lines", [])
			if lines.size() > 0:
				first_speaker = lines[0].get("speaker", "")
			return first_speaker if first_speaker != "" else "Storyboard"
		"fork":
			var n3: String = item.get("title", "")
			return n3 if n3 != "" else "Fork"
	return "?"


func _type_sublabel(item: Dictionary) -> String:
	var t: String = item.get("type", "round")
	match t:
		"round":
			var c: int = item.get("coins", 0)
			var rlabel: String = "BOSS ROUND" if item.get("round_type", "normal") == "boss" else "ROUND"
			return "%s   ♦ %d" % [rlabel, c] if c > 0 else rlabel
		"shop":
			return "SHOP"
		"storyboard":
			var n: int = (item.get("lines", []) as Array).size()
			return "STORYBOARD   %d LINE%s" % [n, "S" if n != 1 else ""]
		"fork":
			var paths: Array = item.get("paths", [])
			return "FORK   %d PATHS" % paths.size()
	return ""


# ---------------------------------------------------------------------------
# Edges
# ---------------------------------------------------------------------------

func _add_edge(from: Vector2, to: Vector2, color: Color) -> void:
	_edges.append({"from": from, "to": to, "color": color})


func _node_top(node: Control) -> Vector2:
	return node.position + Vector2(node.size.x * 0.5, 0.0)


func _node_bottom(node: Control) -> Vector2:
	return node.position + Vector2(node.size.x * 0.5, node.size.y)


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

func _select(item: Dictionary, arr: Array, idx: int) -> void:
	_selected_data = item
	emit_signal("node_selected", item, arr, idx)
	# Re-render so the selected node gets the highlighted border.
	refresh()


# Programmatically select the item at arr[idx]. Used by side-panel editors
# after a structural change so both the graph and the editor re-render.
func select_item(arr: Array, idx: int) -> void:
	if idx < 0 or idx >= arr.size():
		clear_selection()
		return
	_select(arr[idx], arr, idx)


func clear_selection() -> void:
	if _selected_data.is_empty():
		# Force the signal so consumers can update on a forced clear.
		emit_signal("node_selected", {}, [], -1)
		return
	_selected_data = {}
	emit_signal("node_selected", {}, [], -1)
	refresh()


# ---------------------------------------------------------------------------
# Pan + zoom
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			_last_mouse = mb.position
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, _zoom + ZOOM_STEP)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, _zoom - ZOOM_STEP)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			# Release on empty canvas (no node consumed it) clears selection.
			_select_empty()
	elif event is InputEventMouseMotion and _panning:
		var mm := event as InputEventMouseMotion
		var delta: Vector2 = mm.position - _last_mouse
		_last_mouse = mm.position
		_pan_offset += delta
		_apply_transform()


func _zoom_at(focus: Vector2, new_zoom: float) -> void:
	new_zoom = clamp(new_zoom, ZOOM_MIN, ZOOM_MAX)
	if abs(new_zoom - _zoom) < 0.001:
		return
	# Preserve the canvas point under the cursor.
	var world_before: Vector2 = (focus - _pan_offset) / _zoom
	_zoom = new_zoom
	_pan_offset = focus - world_before * _zoom
	_apply_transform()


func _apply_transform() -> void:
	_canvas.position = _pan_offset
	_canvas.scale    = Vector2(_zoom, _zoom)
	# Re-invoke _draw() — pan/zoom changes don't automatically invalidate the
	# CanvasItem's drawn primitives, so without this the edges flicker out.
	_canvas.queue_redraw()


func _select_empty() -> void:
	if _selected_data.is_empty():
		return
	_selected_data = {}
	emit_signal("node_selected", {}, [], -1)
	refresh()
