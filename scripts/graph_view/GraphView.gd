class_name GraphView
extends Control

# ---------------------------------------------------------------------------
# GraphView.gd
# Renders a free-form journey graph: each node placed at its saved pos, edges
# drawn from every node's out-list. The builder drives editing (select / drag /
# wire) and the player-facing journey map reuses it read-only (map_mode).
#
# Public API:
#   set_graph(graph: Dictionary)   — sets the graph model and rebuilds
#   refresh()                      — rebuilds from the current model
# Signals (see declarations below):
#   graph_selection_changed(ids)   — the selected-node set changed
#   connect_target_picked(node_id) — a node was clicked while wiring an edge
# ---------------------------------------------------------------------------

const NODE_WIDTH: float = 200.0
const NODE_HEIGHT: float = 64.0
const V_GAP: float = 40.0
const H_GAP: float = 36.0
const PATH_LABEL_HEIGHT: float = 32.0
const ZOOM_MIN: float = 0.15
const ZOOM_MAX: float = 4.0
const ZOOM_STEP: float = 0.1
# Screen-space top margin when framing the graph at the top-center of the view.
const VIEW_TOP_MARGIN: float = 40.0
# Padding kept around the content when fit-to-view frames the whole graph.
const FIT_PADDING: float = 60.0
# Minimum canvas extent, and extra margin added around the laid-out content. The
# canvas is grown to fit tall/wide journeys so its draw (the edges) is never
# culled — see _resize_canvas_to_content.
const CANVAS_MIN_SIZE: float = 8000.0
const CANVAS_CONTENT_MARGIN: float = 600.0

# Read-only "map mode" (player-facing journey map): suppresses editing affordances
# (node selection / drag wiring) while keeping pan/zoom. Set before set_graph().
# Adds the "you are here" marker API.
var map_mode: bool = false

# Pan / zoom state
var _pan_offset: Vector2 = Vector2(40, 40)
var _zoom: float = 1.0
var _panning: bool = false
# Keyboard panning (builder only — the map/end-screen leave it off). Arrows or WASD scroll the
# canvas at a steady on-screen rate; screen-space so the feel is the same at any zoom.
var keyboard_pan_enabled: bool = false
const KEY_PAN_SPEED: float = 1100.0  # screen px / second
var _last_mouse: Vector2 = Vector2.ZERO
var _has_initial_center: bool = false

# Auto-layout artefacts (rebuilt on refresh).
# Edges: list of {from: Vector2, to: Vector2, color: Color, dashed?: bool}
var _edges: Array = []

# The free-form graph model (GRAPH_EDITOR_OVERHAUL.md): {start, nodes:{id:{type,data,pos,out}}}.
# Rendered by _layout_graph — nodes at their saved pos, edges from each node's out-list.
var _graph_model: Dictionary = {}
# Fog of war (player map only): when on, visited nodes render in full, nodes within _fog_depth out-edge
# hops of the visited trail render as "?" ghosts, and everything else is hidden. Recomputed each layout.
var _fog_enabled: bool = false
var _fog_depth: int = 1  # ghost levels revealed beyond the visited trail (< 0 = whole structure)
var _fog_revealed: Dictionary = {}  # node_id -> true (discovered this run; full render)
var _fog_ghost: Dictionary = {}  # node_id -> true (within _fog_depth of the trail; "?" ghost render)
var _selected_ids: Array = []  # selected node ids (graph mode) — drives the highlight + group ops
var _current_layout_node_id: String = ""  # transient: the node _make_node is building (graph mode)
var _node_ctrls: Dictionary = {}  # node_id -> Control (graph mode), for live drag moves
var _node_warnings: Dictionary = {}  # node_id -> soft-validation summary (author badge); pulled per layout
var warning_provider: Callable = Callable()  # builder hook → {node_id: warning}; called each layout (editor only)
# Traffic heatmap (audit Monte-Carlo results): {nodes: {id: pct}, edges: {"id:ei": pct}}.
# Non-empty → editor edges are tinted/thickened by traffic share and nodes get a % chip.
# Never rendered in map_mode (player map / image export). Set via set_traffic({}) to clear.
var _traffic: Dictionary = {}
# Route recap overlay (end-of-run ceremony): the run's taken path renders
# bright + thick, everything off it ghosted. Unlike the traffic heatmap this
# DOES render in map_mode — the end screen is a map-mode consumer.
var _route_nodes: Dictionary = {}  # node_id -> true (visited)
var _route_edges: Dictionary = {}  # "src_id>to_id" -> true (taken)
var _connect_mode: bool = false  # builder is wiring an edge — a node click is a target, not a drag

# Node-drag state. A plain press on a node arms a drag of the whole selection; _input tracks
# motion/release globally so it survives the cursor leaving the node.
var _dragging_node: String = ""  # the pressed node, or "" when no drag is armed
var _drag_moved: bool = false  # did the drag actually move (vs a plain click)?
var _drag_started: bool = false  # has the drag emitted nodes_drag_started yet (one undo per drag)?

# Comment (sticky-note) drag state — mirrors the node-drag model above.
var _comment_ctrls: Array = []  # index -> Control, rebuilt each layout
var _dragging_comment: int = -1  # the pressed comment index, or -1 when none
var _comment_drag_moved: bool = false
var _comment_drag_started: bool = false

# Group-frame drag/resize state — a labelled rectangle that moves the nodes inside it.
var _frame_ctrls: Array = []  # index -> Control, rebuilt each layout
var _collapsed_frame_of: Dictionary = {}  # node_id -> its collapsed group's bar Control (edges reroute to it)
var _dragging_frame: int = -1  # the frame being moved (by its header), or -1
var _frame_drag_moved: bool = false
var _frame_drag_started: bool = false
var _frame_drag_node_ids: Array = []  # nodes captured inside the frame at drag start
var _resizing_frame: int = -1  # the frame being resized (by its corner grip), or -1
var _frame_resize_started: bool = false
var _drag_collapse_to: String = ""  # plain-press on a multi-selected node → collapse to it on release-no-move

# Drag-to-connect state (dragging from a node's out-handle to a target node). _input tracks the
# motion/release globally, like the node drag; _draw renders the rubber-band line.
const HANDLE_SIZE: float = 16.0
var _connect_drag_active: bool = false
var _connect_drag_source: String = ""  # the node the edge starts from
var _connect_drag_edge_idx: int = -1  # fork choice index, or -1 for a regular node's single out-edge
var _connect_drag_from: Vector2 = Vector2.ZERO  # canvas-space handle position (line start)
var _connect_drag_to: Vector2 = Vector2.ZERO  # canvas-space cursor position (line end)
var _connect_drag_target: String = ""  # node under the cursor (the drop target), or ""
var _connect_drag_invalid: Dictionary = {}  # node ids that can't be targets (source + ancestors → would cycle)

# Marquee (box-select) state, in GraphView-local (screen) space.
var _marquee_active: bool = false
var _marquee_additive: bool = false  # Ctrl/Shift held at drag start → add to the selection
var _marquee_start: Vector2 = Vector2.ZERO
var _marquee_end: Vector2 = Vector2.ZERO
const MARQUEE_DRAG_THRESHOLD: float = 6.0

# Emitted when the selected-node set changes (click / ctrl-click / shift-click / marquee / clear /
# programmatic select). The builder mirrors it + drives the side panel (0 → journey info, 1 → node
# editor, 2+ → multi-select panel).
signal graph_selection_changed(ids: Array)
# A node was clicked while connect mode is armed — the builder wires the edge to it.
signal connect_target_picked(node_id: String)
# A node drag actually started moving — the builder snapshots for undo (one entry per drag).
signal nodes_drag_started
# An out-handle was dragged onto a target node — the builder wires source→target (edge_idx = fork
# choice, or -1 for a regular node's single out-edge), reusing its connect validation + undo.
signal edge_drawn(source_id: String, edge_idx: int, target_id: String)

# A sticky-note comment was clicked (a press with no drag) — the builder shows its editor.
signal comment_clicked(index: int)

# A group frame was clicked or dragged — the builder shows its editor.
signal frame_clicked(index: int)

# A group frame's collapse chevron was pressed — the builder toggles it (undoable).
signal frame_toggle_collapse(index: int)

# Right-click on empty canvas — the builder opens a context menu (add node/note/group at the cursor).
# Carries the world-space position under the cursor so created items land where the author clicked.
signal canvas_context_menu_requested(world_position: Vector2)

# Right-click on a node → the builder shows that node's context menu (e.g. Set as start).
signal node_context_menu_requested(node_id: String)

# "You are here" marker (map mode). A glowing ring around the current node, child
# of _canvas so it pans/zooms with the graph.
const MARKER_PAD: float = 9.0
var _marker: Panel = null
var _marker_color: Color = UITheme.PURPLE_BRIGHT

# Background grid + edges live on _canvas. Nodes are added as children of _canvas
# so they pan/zoom together with edges.
@onready var _canvas: Control = $Canvas

# Centered onboarding hint, shown only while the journey is empty. Lives on the
# GraphView (not _canvas) so it stays put regardless of pan/zoom.
var _empty_hint: Label = null


func _ready() -> void:
	clip_contents = true
	# Make sure we receive input events for pan/zoom.
	mouse_filter = Control.MOUSE_FILTER_PASS
	# Start with a large bounding rect; _resize_canvas_to_content grows it to fit
	# the actual layout so the edge draw is never culled on tall/wide journeys.
	# (A canvas item whose rect leaves the viewport is skipped entirely, which
	# would drop every edge at once while the per-node child controls survive.)
	_canvas.custom_minimum_size = Vector2(CANVAS_MIN_SIZE, CANVAS_MIN_SIZE)
	_canvas.size = Vector2(CANVAS_MIN_SIZE, CANVAS_MIN_SIZE)

	_empty_hint = Label.new()
	_empty_hint.text = "Drop videos or a folder here to auto-create rounds,\nor use  ADD NODE  in the side panel."
	_empty_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_hint.anchor_right = 1.0
	_empty_hint.anchor_bottom = 1.0
	_empty_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_hint.add_theme_color_override(
		"font_color", Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.75)
	)
	_empty_hint.add_theme_font_size_override("font_size", 16)
	_empty_hint.visible = false
	add_child(_empty_hint)


# Render entry: set the graph model and rebuild — nodes at their saved positions,
# edges from out-lists. See _layout_graph.
func set_graph(graph: Dictionary) -> void:
	_graph_model = graph
	refresh()


# Player-map fog of war: reveal `discovered` nodes (full) plus every node within `depth` out-edge hops of
# them ("?" ghosts), hiding the rest. depth < 0 ghosts the whole structure. Re-renders; call again with a
# grown `discovered` set as the player progresses. The ghost set is derived at layout time by BFS.
func set_fog(enabled: bool, discovered: Array, depth: int = 1) -> void:
	_fog_enabled = enabled
	_fog_depth = depth
	_fog_revealed = {}
	for id in discovered:
		_fog_revealed[str(id)] = true
	refresh()


func refresh() -> void:
	# Tear down old nodes.
	for c in _canvas.get_children():
		c.queue_free()
	_edges.clear()

	# Onboarding hint only while the graph has no nodes (else it overlays the graph).
	if _empty_hint:
		_empty_hint.visible = (_graph_model.get("nodes", {}) as Dictionary).is_empty()

	# Apply pan/zoom transform to the canvas.
	_apply_transform()

	# Lay out the graph deferred so the freed children are gone before we add new ones.
	call_deferred("_do_layout")


func _do_layout() -> void:
	_layout_graph()


# Grows _canvas so its rect always covers the laid-out content. Edges are drawn
# on _canvas as part of its own _draw, so if the content is taller/wider than the
# canvas rect, the renderer culls the whole canvas item once you scroll past that
# rect — and every edge disappears at once (nodes are separate items and survive).
# Sizing to the real content height/width keeps the edges visible at any scroll.
func _resize_canvas_to_content(content_size: Vector2) -> void:
	var w: float = maxf(CANVAS_MIN_SIZE, content_size.x + CANVAS_CONTENT_MARGIN)
	var h: float = maxf(CANVAS_MIN_SIZE, content_size.y + CANVAS_CONTENT_MARGIN)
	_canvas.custom_minimum_size = Vector2(w, h)
	_canvas.size = Vector2(w, h)


# ── Graph-editor layout (L1) ─────────────────────────────────────────────────


# Renders the free-form graph: each node at its saved pos, edges drawn from every node's
# out-list. Reuses _make_node via a tree-item-shaped display adapter.
func _layout_graph() -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	_node_ctrls = {}  # node_id -> Control (rebuilt each layout)
	# Fog of war (player map): BFS out from the visited trail along out-edges, marking ghosts up to
	# _fog_depth hops away (unlimited when _fog_depth < 0 → the whole structure, since every node is
	# reachable from the always-visited start). Nodes neither revealed nor ghost are hidden below.
	_fog_ghost = {}
	if _fog_enabled:
		var ring: Array = _fog_revealed.keys()
		var seen: Dictionary = _fog_revealed.duplicate()
		var hops: int = 0
		while not ring.is_empty() and (_fog_depth < 0 or hops < _fog_depth):
			hops += 1
			var next_ring: Array = []
			for nid: String in ring:
				if not nodes.has(nid):
					continue
				for fe: Dictionary in (nodes[nid] as Dictionary).get("out", []):
					var fto: String = str(fe.get("to", ""))
					if fto != "" and not seen.has(fto):
						seen[fto] = true
						_fog_ghost[fto] = true
						next_ring.append(fto)
			ring = next_ring
	# Pull fresh soft-validation badges from the builder once per layout, so EVERY render path (edit,
	# selection, create / paste / import) shows them. No provider on the player map / export → no badges.
	_node_warnings = (
		warning_provider.call() if (not map_mode and warning_provider.is_valid()) else {}
	)
	# Group frames render at the very back, then sticky-note comments, then the nodes on top. Both are
	# editor furniture the player map never has; image export shows them static (map_mode → no gui_input).
	_frame_ctrls = []
	_collapsed_frame_of = {}
	var groups: Array = _graph_model.get("groups", [])
	for gi: int in groups.size():
		var g: Dictionary = groups[gi]
		var fc: Control = _make_frame(gi, g)
		fc.position = (g.get("rect", Rect2()) as Rect2).position
		_canvas.add_child(fc)
		_frame_ctrls.append(fc)
		if g.get("collapsed", false):
			# Hide the members FROZEN at collapse time, not whatever's under the rect now — otherwise
			# dragging a collapsed bar over an unrelated node would swallow it.
			for hid: String in g.get("members", []):
				if nodes.has(hid):
					_collapsed_frame_of[hid] = fc  # hidden node → its bar; crossing edges reroute to it
	_comment_ctrls = []
	var comments: Array = _graph_model.get("comments", [])
	for ci: int in comments.size():
		var cc: Control = _make_comment(ci, comments[ci])
		cc.position = (comments[ci] as Dictionary).get("pos", Vector2.ZERO)
		_canvas.add_child(cc)
		_comment_ctrls.append(cc)
	for id: String in nodes:
		if _collapsed_frame_of.has(id):  # inside a collapsed group — drawn as the collapsed bar instead
			continue
		if _fog_enabled and not _fog_revealed.has(id):
			# Not yet reached: render a "?" ghost if it's within the reveal depth, else nothing at all
			# (no control → its edges drop out too, keeping the unknown unknown).
			if _fog_ghost.has(id):
				var ghost: Control = _make_fog_node()
				ghost.position = (nodes[id] as Dictionary).get("pos", Vector2.ZERO)
				ghost.set_meta("graph_node_id", id)
				_canvas.add_child(ghost)
				_node_ctrls[id] = ghost
			continue
		var n: Dictionary = nodes[id]
		_current_layout_node_id = id  # read by _make_node to mark the selected node
		var disp: Dictionary = _graph_display_item(n)
		if not map_mode:  # author-only badges (never on the player map)
			disp["warning"] = str(_node_warnings.get(id, ""))
			disp["is_start"] = (id == str(_graph_model.get("start", "")))
		var ctrl: Control = _make_node(disp, JourneyGraph.is_end(_graph_model, id))
		ctrl.position = n.get("pos", Vector2.ZERO)
		ctrl.set_meta("graph_node_id", id)
		if not map_mode:  # player-facing map: nodes are read-only (no select/drag wiring)
			ctrl.gui_input.connect(_on_graph_node_gui_input.bind(id))
		_canvas.add_child(ctrl)
		_node_ctrls[id] = ctrl
		if not map_mode and not _traffic.is_empty():
			_attach_traffic_chip(
				ctrl, float((_traffic.get("nodes", {}) as Dictionary).get(id, 0.0))
			)
		# Route recap: everything the run didn't visit is ghosted.
		if not _route_nodes.is_empty() and not _route_nodes.has(id):
			ctrl.modulate = Color(1, 1, 1, 0.35)
	# Out-handles in a second pass so they're the topmost (always-clickable) children.
	if not map_mode:
		for id: String in nodes:
			if _node_ctrls.has(id):
				_add_out_handles(id, nodes[id], (_node_ctrls[id] as Control).position)
	var drawn: Dictionary = {}  # dedup edges that resolve to the same control pair (collapsed bars)
	for id: String in nodes:
		# In fog mode, hidden nodes have no control so _edge_endpoint_ctrl returns null and their edges
		# drop out below; edges among shown nodes (visited + ghosts) draw, so the revealed structure
		# (up to the reveal depth) is visible — including ghost→ghost links at depth ≥ 2.
		var src_ctrl: Control = _edge_endpoint_ctrl(id)
		if src_ctrl == null:
			continue
		var n: Dictionary = nodes[id]
		var is_fork: bool = n.get("type", "") == "fork"
		var out: Array = n.get("out", [])
		for ei: int in out.size():
			var e: Dictionary = out[ei]
			var to: String = str(e.get("to", ""))
			if to == "":
				continue
			var tgt_ctrl: Control = _edge_endpoint_ctrl(to)
			if tgt_ctrl == null or tgt_ctrl == src_ctrl:
				continue  # missing target, or both ends collapse into the same bar (an internal edge)
			var key: String = "%d>%d" % [src_ctrl.get_instance_id(), tgt_ctrl.get_instance_id()]
			if drawn.has(key):
				continue
			drawn[key] = true
			var color: Color = UITheme.FORK_EDGE if is_fork else UITheme.EDGE
			var width: float = 2.0
			if not map_mode and not _traffic.is_empty():
				# Heatmap: the edge's traffic share replaces its type color —
				# hot = bright + thick, cold = ghostly dim + thin.
				var pct: float = float(
					(_traffic.get("edges", {}) as Dictionary).get("%s:%d" % [id, ei], 0.0)
				)
				color = _traffic_color(pct)
				width = lerpf(1.5, 5.0, sqrt(clampf(pct / 100.0, 0.0, 1.0)))
			if not _route_edges.is_empty():
				# Route recap: the taken path glows; roads not taken go ghostly.
				if _route_edges.has("%s>%s" % [id, to]):
					color = UITheme.CYAN
					width = 4.0
				else:
					color = Color(color, color.a * 0.22)
			_add_edge_between(src_ctrl, tgt_ctrl, color, width)
	_canvas.set_edges(_edges)
	_resize_canvas_to_content(_graph_content_size(_node_ctrls))
	if not _has_initial_center:
		_has_initial_center = true
		call_deferred("_center_initial_view")


# Tree-item shape _make_node expects, built from a graph node (type at top level; a fork's
# sublabel reads paths.size(), which maps to its out-edge count).
func _graph_display_item(n: Dictionary) -> Dictionary:
	var d: Dictionary = (n.get("data", {}) as Dictionary).duplicate()
	d["type"] = n.get("type", "round")
	if d["type"] == "fork":
		d["paths"] = n.get("out", [])
	return d


# Fog-of-war placeholder for a not-yet-reached node one step ahead: a dim "?" box the same size as a real
# node (so the layout + the edge into it line up). Carries no type / name, so it never spoils what's next.
func _make_fog_node() -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.custom_minimum_size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	panel.size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.PANEL_BG.r, UITheme.PANEL_BG.g, UITheme.PANEL_BG.b, 0.45)
	sb.border_color = Color(UITheme.SEPARATOR.r, UITheme.SEPARATOR.g, UITheme.SEPARATOR.b, 0.55)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	panel.add_theme_stylebox_override("panel", sb)
	var lbl: Label = Label.new()
	lbl.text = "?"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override(
		"font_color", Color(UITheme.SEPARATOR.r, UITheme.SEPARATOR.g, UITheme.SEPARATOR.b, 0.8)
	)
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(lbl)
	return panel


# Bounding size of the placed graph nodes (for canvas sizing). Uses the fixed node size rather
# than c.size, which may not be laid out yet at this point.
func _graph_content_size(ctrls: Dictionary) -> Vector2:
	var size: Vector2 = Vector2(NODE_WIDTH, NODE_HEIGHT)
	for id: String in ctrls:
		var c: Control = ctrls[id]
		size.x = maxf(size.x, c.position.x + NODE_WIDTH)
		size.y = maxf(size.y, c.position.y + NODE_HEIGHT)
	return size


# A press on a graph node: wires the edge (connect mode), or updates the selection and arms a drag
# of the whole selection. Modifiers: Ctrl = toggle this node, Shift = add it; plain = select just it
# (or keep a multi-selection for a group drag, collapsing to this node on a release with no move).
func _on_graph_node_gui_input(event: InputEvent, node_id: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		# Right-click → node context menu (the builder owns the popup). Connect-drag/selection unaffected.
		node_context_menu_requested.emit(node_id)
		accept_event()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if _connect_mode:
		# Wiring an edge: this click is the target — let the builder finish the connect; no drag.
		connect_target_picked.emit(node_id)
		accept_event()
		return
	if mb.ctrl_pressed:
		_toggle_in_selection(node_id)
		accept_event()
		return
	if mb.shift_pressed:
		_add_to_selection(node_id)
		accept_event()
		return
	# Plain press → arm a drag. Keep an existing multi-selection that already includes this node
	# (so the drag moves the group); otherwise select just this node.
	_drag_collapse_to = ""
	if node_id in _selected_ids:
		if _selected_ids.size() > 1:
			_drag_collapse_to = node_id
	else:
		_set_selection([node_id])
	_dragging_node = node_id
	_drag_moved = false
	_drag_started = false
	accept_event()


# Drives a node drag armed by _on_graph_node_gui_input. Global (not gui_input) so it keeps tracking
# when the cursor leaves the node. Moves the WHOLE selection live; grid-snaps each on release. A
# press with no motion collapses a kept multi-selection to the pressed node. No-op when no drag.
func _input(event: InputEvent) -> void:
	if _connect_drag_active:
		_handle_connect_drag_input(event)
		return
	if _dragging_frame >= 0:
		_handle_frame_drag(event)
		return
	if _resizing_frame >= 0:
		_handle_frame_resize(event)
		return
	if _dragging_comment >= 0:
		_handle_comment_drag(event)
		return
	if _dragging_node == "":
		return
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if event is InputEventMouseMotion:
		if not _drag_started:
			_drag_started = true
			nodes_drag_started.emit()  # builder snapshots the pre-drag state for undo
		var delta: Vector2 = (event as InputEventMouseMotion).relative / _zoom
		for id: String in _selected_ids:
			var n: Dictionary = nodes.get(id, {})
			if not n.is_empty():
				n["pos"] = (n.get("pos", Vector2.ZERO) as Vector2) + delta
				if _node_ctrls.has(id):
					(_node_ctrls[id] as Control).position = n["pos"]
		_drag_moved = true
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_dragging_node = ""
			if _drag_moved:
				for id: String in _selected_ids:
					var n2: Dictionary = nodes.get(id, {})
					if not n2.is_empty():
						n2["pos"] = GraphLayout.snap(n2.get("pos", Vector2.ZERO))
				refresh()  # re-render: highlights, grid-snapped positions, edges reconnected
			elif _drag_collapse_to != "":
				_set_selection([_drag_collapse_to])  # plain click on a multi-selected node → just it
			_drag_collapse_to = ""
			get_viewport().set_input_as_handled()


# ── Drag-to-connect (out-handles) ────────────────────────────────────────────


# Adds the out-handle nub(s) to a node's bottom edge: one centred handle for a regular node (its
# single out-edge), one per choice for a fork (spread along the bottom, tinted like fork edges).
func _add_out_handles(node_id: String, node: Dictionary, node_pos: Vector2) -> void:
	if node.get("type", "") == "fork":
		var out: Array = node.get("out", [])
		var count: int = maxi(1, out.size())
		for ei in count:
			var fx: float = NODE_WIDTH * float(ei + 1) / float(count + 1)
			_make_handle(node_id, ei, node_pos + Vector2(fx, NODE_HEIGHT), UITheme.FORK_EDGE)
	else:
		_make_handle(node_id, -1, node_pos + Vector2(NODE_WIDTH * 0.5, NODE_HEIGHT), UITheme.EDGE)


# One out-handle nub (a small circle straddling the bottom edge). Dragging it starts a connect-drag.
func _make_handle(node_id: String, edge_idx: int, center: Vector2, color: Color) -> void:
	var h: Panel = Panel.new()
	h.size = Vector2(HANDLE_SIZE, HANDLE_SIZE)
	h.position = center - Vector2(HANDLE_SIZE * 0.5, HANDLE_SIZE * 0.5)
	h.mouse_filter = Control.MOUSE_FILTER_STOP
	h.tooltip_text = "Drag to connect this node to another"
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0.04, 0.0, 0.06, 0.98)
	s.border_color = color
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_width_top = 2
	s.border_width_bottom = 2
	var rad: int = int(HANDLE_SIZE * 0.5)
	s.corner_radius_top_left = rad
	s.corner_radius_top_right = rad
	s.corner_radius_bottom_left = rad
	s.corner_radius_bottom_right = rad
	h.add_theme_stylebox_override("panel", s)
	h.gui_input.connect(_on_handle_gui_input.bind(node_id, edge_idx, center))
	_canvas.add_child(h)


# Press on an out-handle → begin a connect-drag from it. _input then tracks the rubber-band.
func _on_handle_gui_input(
	event: InputEvent, node_id: String, edge_idx: int, center: Vector2
) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_connect_drag_active = true
			_connect_drag_source = node_id
			_connect_drag_edge_idx = edge_idx
			_connect_drag_from = center
			_connect_drag_to = center
			_connect_drag_target = ""
			_connect_drag_invalid = _ancestors_and_self(node_id)
			# A fork can't point two choices at the same node — block any node another of this fork's
			# choices already targets (one choice per target).
			if edge_idx >= 0:
				var node_d: Dictionary = (_graph_model.get("nodes", {}) as Dictionary).get(
					node_id, {}
				)
				var out: Array = node_d.get("out", [])
				for j in out.size():
					if j != edge_idx:
						var t: String = str((out[j] as Dictionary).get("to", ""))
						if t != "":
							_connect_drag_invalid[t] = true
			accept_event()


# Drives the connect-drag (global, so it survives leaving the handle): tracks the cursor for the
# rubber-band + hovered target, and on release wires a valid target via the edge_drawn signal.
func _handle_connect_drag_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_connect_drag_to = _canvas.get_local_mouse_position()
		_connect_drag_target = _node_at_canvas_point(_connect_drag_to)
		queue_redraw()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			var target: String = _node_at_canvas_point(_canvas.get_local_mouse_position())
			var src: String = _connect_drag_source
			var eidx: int = _connect_drag_edge_idx
			_connect_drag_active = false
			_connect_drag_source = ""
			_connect_drag_target = ""
			queue_redraw()
			# Valid drop only: a node, not the source, not an ancestor (which would form a cycle).
			if target != "" and target != src and not _connect_drag_invalid.has(target):
				edge_drawn.emit(src, eidx, target)
			get_viewport().set_input_as_handled()


# The node id whose laid-out rect contains canvas-space point `p`, or "".
func _node_at_canvas_point(p: Vector2) -> String:
	for id: String in _node_ctrls:
		var c: Control = _node_ctrls[id]
		if Rect2(c.position, c.size).has_point(p):
			return id
	return ""


# Set of node ids that must NOT be wire targets for `source` — the source itself plus every node that
# can reach it (an edge source→ancestor would close a cycle). Reverse BFS over the out-edges.
func _ancestors_and_self(source: String) -> Dictionary:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var preds: Dictionary = {}
	for id: String in nodes:
		preds[id] = []
	for id: String in nodes:
		for e: Dictionary in (nodes[id] as Dictionary).get("out", []):
			var to: String = str(e.get("to", ""))
			if to != "" and nodes.has(to):
				(preds[to] as Array).append(id)
	var invalid: Dictionary = {source: true}
	var queue: Array = [source]
	var qi: int = 0
	while qi < queue.size():
		var cur: String = queue[qi]
		qi += 1
		for p: String in preds.get(cur, []) as Array:
			if not invalid.has(p):
				invalid[p] = true
				queue.append(p)
	return invalid


# Replaces the selection set, re-renders, and notifies the builder. The internal click/marquee
# helpers and the public select/clear all funnel through here so there's one emit path.
func _set_selection(ids: Array) -> void:
	_selected_ids = ids.duplicate()
	refresh()
	graph_selection_changed.emit(_selected_ids)


# Ctrl+click: toggle a node in/out of the selection.
func _toggle_in_selection(node_id: String) -> void:
	var ids: Array = _selected_ids.duplicate()
	if ids.has(node_id):
		ids.erase(node_id)
	else:
		ids.append(node_id)
	_set_selection(ids)


# Shift+click: add a node to the selection (no-op if already in).
func _add_to_selection(node_id: String) -> void:
	if node_id in _selected_ids:
		return
	var ids: Array = _selected_ids.duplicate()
	ids.append(node_id)
	_set_selection(ids)


# Selects one node programmatically (e.g. after a create / wire) — single-node selection.
func select_graph_node(node_id: String) -> void:
	_set_selection([node_id])


# Selects an explicit set of nodes (e.g. restoring after undo). Drops any id not in the graph.
func set_selection(ids: Array) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var valid: Array = []
	for id: String in ids:
		if nodes.has(id):
			valid.append(id)
	_set_selection(valid)


# Clears the selection (e.g. after a delete) and re-renders.
func clear_graph_selection() -> void:
	_set_selection([])


# Builder sets this while wiring an edge (click-to-connect): a node press becomes a target click
# (emit selection, no move-drag) instead of starting a drag.
func set_connect_mode(on: bool) -> void:
	_connect_mode = on


# Graph-editor seed: records {node_id: top-left Vector2} for a builder item tree by running a
# tree-style layout (fork packing, centering, rejoin handling) — without making any Controls. The
# builder seeds a migrated (legacy) journey from this so it opens compact and centered on x=0
# (which is what _center_initial_view frames).
func tree_positions(items: Array) -> Dictionary:
	var pos: Dictionary = {}
	_tree_positions(items, 0.0, 0.0, pos)
	return pos


# Computes tree-style positions, storing pos[node_id] instead of instantiating nodes (no edges or
# labels). Returns Vector2(width, bottom_y) the items occupy.
func _tree_positions(items: Array, x_center: float, y: float, pos: Dictionary) -> Vector2:
	var cur_y: float = y
	var max_w: float = NODE_WIDTH
	if items.is_empty():
		return Vector2(NODE_WIDTH, y)
	for item: Dictionary in items:
		var nid: String = str(item.get("node_id", ""))
		if item.get("type", "round") == "fork":
			if nid != "":
				pos[nid] = Vector2(x_center - NODE_WIDTH * 0.5, cur_y)
			cur_y += NODE_HEIGHT + V_GAP
			var paths: Array = item.get("paths", [])
			var path_widths: Array = []
			for path: Dictionary in paths:
				path_widths.append(maxf(_measure_items_width(path.get("items", [])), NODE_WIDTH))
			var total_w: float = 0.0
			for w in path_widths:
				total_w += w
			if paths.size() > 1:
				total_w += (paths.size() - 1) * H_GAP
			max_w = maxf(max_w, total_w)
			var col_x: float = x_center - total_w * 0.5
			var max_branch_y: float = cur_y
			for pi in paths.size():
				var pw: float = path_widths[pi]
				var path_cx: float = col_x + pw * 0.5
				var sub: Vector2 = _tree_positions(
					(paths[pi] as Dictionary).get("items", []),
					path_cx,
					cur_y + PATH_LABEL_HEIGHT + V_GAP,
					pos
				)
				max_branch_y = maxf(max_branch_y, sub.y)
				col_x += pw + H_GAP
			cur_y = max_branch_y
		else:
			if nid != "":
				pos[nid] = Vector2(x_center - NODE_WIDTH * 0.5, cur_y)
			cur_y += NODE_HEIGHT + V_GAP
	return Vector2(max_w, cur_y)


# Aligns the top-center of the graph (where the first item sits, at x=0, y=0
# in canvas-local space) with the top-center of the visible area.
func _center_initial_view() -> void:
	# In case size hasn't been finalised yet, wait one more frame.
	if size.x <= 0.0:
		await get_tree().process_frame
	_pan_offset = Vector2(size.x * 0.5, VIEW_TOP_MARGIN)
	_apply_transform()


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


# ---------------------------------------------------------------------------
# Node makers
# ---------------------------------------------------------------------------


# is_terminal: true when this node ends the run (no path leads beyond it).
func _make_node(item: Dictionary, is_terminal: bool = false) -> Control:
	var item_type: String = item.get("type", "round")
	var round_type: String = item.get("round_type", "normal") if item_type == "round" else ""
	var is_boss: bool = round_type == "boss"
	# Effect rounds (incl. un-migrated legacy cursed/blessed) take their node accent + glyph
	# straight from the round's author-set visuals (see _effect_look).
	var effect_look: Dictionary = (
		_effect_look(item) if round_type in ["effect", "cursed", "blessed"] else {}
	)
	# Terminal nodes use AMBER; boss / effect rounds get their own accent; else the type colour.
	var accent: Color
	if is_terminal:
		accent = UITheme.AMBER
	elif round_type == "boss":
		accent = UITheme.DANGER
	elif not effect_look.is_empty():
		accent = effect_look["color"]
	else:
		accent = _type_color(item_type)
	var icon: String
	if is_boss:
		icon = "⚔"
	elif not effect_look.is_empty():
		icon = effect_look["icon"]
	else:
		icon = _type_icon(item_type)
	var primary: String = _type_label(item)
	var secondary: String = _type_sublabel(item)
	if is_terminal:
		secondary = secondary + ("  ·  " if secondary != "" else "") + "END OF RUN"

	var panel: PanelContainer = PanelContainer.new()
	panel.size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	panel.custom_minimum_size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	# Map mode: nodes ignore the mouse so clicks pass through to pan/zoom.
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE if map_mode else Control.MOUSE_FILTER_STOP

	# Selected nodes get a heavier border via _node_stylebox.
	var is_selected: bool = _current_layout_node_id in _selected_ids
	panel.add_theme_stylebox_override("panel", _node_stylebox(accent, is_selected, is_terminal))

	# Stash the display item so content_bounds / fit-to-view can identify node panels.
	panel.set_meta("graph_item", item)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
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

	# Start-of-journey marker — a bright "START" tag pinned to the front of the row so the entry point
	# is obvious at a glance (the structural sibling of END OF RUN on the terminal node). The flag is
	# set in _layout_graph for author mode only, so it never shows on the player map.
	if item.get("is_start", false):
		var start_lbl: Label = Label.new()
		start_lbl.text = "START"
		start_lbl.add_theme_color_override("font_color", UITheme.CYAN)
		start_lbl.add_theme_font_size_override("font_size", 11)
		start_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		start_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(start_lbl)
		row.move_child(start_lbl, 0)

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

	# Soft validation: an author-facing ⚠ at the right edge of a node with a problem (a round with no
	# funscript, a moved source file, an unreachable island, …). The builder supplies the text via
	# warning_provider; never present in map mode. Added to `row` (a real container child, so it always
	# lays out); the glyph ignores the mouse like the rest of the node, and the detail shows as the
	# node's hover tooltip (the panel already stops the mouse in the editor).
	var warning: String = str(item.get("warning", ""))
	if warning != "":
		panel.tooltip_text = warning
		var warn_lbl: Label = Label.new()
		warn_lbl.text = "⚠"
		warn_lbl.add_theme_color_override("font_color", UITheme.AMBER)
		warn_lbl.add_theme_font_size_override("font_size", 18)
		warn_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		warn_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(warn_lbl)

	return panel


func _node_stylebox(accent: Color, selected: bool, terminal: bool = false) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0.04, 0.0, 0.06, 0.96)
	s.border_color = accent
	# Border: thicker when selected; slightly heavier than default when terminal.
	var w: int = 3 if selected else (2 if terminal else 1)
	s.border_width_left = w
	s.border_width_right = w
	s.border_width_top = w
	s.border_width_bottom = w
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	if selected:
		s.shadow_color = Color(accent.r, accent.g, accent.b, 0.50)
		s.shadow_size = 8
	elif terminal:
		# Warm amber glow to signal "this is where the run ends".
		s.shadow_color = Color(accent.r, accent.g, accent.b, 0.55)
		s.shadow_size = 14
	return s


func _type_color(item_type: String) -> Color:
	match item_type:
		"round":
			return UITheme.PURPLE_BRIGHT
		"shop":
			return UITheme.AMBER
		"storyboard":
			return UITheme.CYAN
		"fork":
			return UITheme.MAGENTA
		"checkpoint":
			return UITheme.SUCCESS
	return UITheme.PURPLE_MID


func _type_icon(item_type: String) -> String:
	match item_type:
		"round":
			return "▶"
		"shop":
			return "◆"
		"storyboard":
			return "◈"
		"fork":
			return "⑂"
		"checkpoint":
			return "⚑"
	return "•"


# Node accent colour + glyph for an effect round: the author's border colour + card icon,
# or the baked look for a legacy cursed/blessed round that hasn't been re-saved yet.
func _effect_look(item: Dictionary) -> Dictionary:
	match str(item.get("round_type", "")):
		"cursed":
			return {"color": Color.html(JourneyData.EFFECT_COLOR_HINDER), "icon": "☠"}
		"blessed":
			return {"color": Color.html(JourneyData.EFFECT_COLOR_BOON), "icon": "✦"}
		_:
			var hex: String = str(item.get("frame_color", ""))
			var color: Color = (
				Color.html(hex)
				if (hex != "" and Color.html_is_valid(hex))
				else Color.html(JourneyData.EFFECT_COLOR_NEUTRAL)
			)
			var glyph: String = str(item.get("card_icon", ""))
			return {"color": color, "icon": glyph if glyph != "" else "✦"}


func _type_label(item: Dictionary) -> String:
	var item_type: String = item.get("type", "round")
	match item_type:
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
		"checkpoint":
			var cn: String = item.get("name", "")
			return cn if cn != "" else "Checkpoint"
	return "?"


func _type_sublabel(item: Dictionary) -> String:
	var item_type: String = item.get("type", "round")
	match item_type:
		"round":
			var c: int = item.get("coins", 0)
			var rt: String = item.get("round_type", "normal")
			var rlabel: String = "ROUND"
			match rt:
				"boss":
					rlabel = "BOSS ROUND"
				"effect", "cursed", "blessed":
					rlabel = "✦ EFFECT ROUND"
			# (Checkpoints are their own node type now — no per-round marker.)
			if item.get("is_warmup", false):
				rlabel += "   ⏭ WARMUP"
			# Pending-segments marker (editor only by construction: saved journeys never
			# carry segment keys — the save consumes them into the media). One segment
			# reads as the trim it is; several show the count instead of an unreadable
			# list of windows.
			var segs: Array = JourneyData.normalize_segments(item)
			if segs.size() == 1:
				var s: Dictionary = segs[0]
				var s_out: int = int(s.get("out_ms", 0))
				rlabel += (
					"   ✂ %s–%s"
					% [
						JourneyData.ms_to_mmss(int(s.get("in_ms", 0))),
						JourneyData.ms_to_mmss(s_out) if s_out > 0 else "END",
					]
				)
			elif segs.size() > 1:
				rlabel += "   ✂ %d SEGMENTS" % segs.size()
			return "%s   ♦ %d" % [rlabel, c] if c > 0 else rlabel
		"shop":
			return "SHOP"
		"storyboard":
			var n: int = (item.get("lines", []) as Array).size()
			var sub: String = "STORYBOARD   %d LINE%s" % [n, "S" if n != 1 else ""]
			var rewards: Array = []
			if int(item.get("coins", 0)) > 0:
				rewards.append("♦ %d" % int(item.get("coins", 0)))
			if str(item.get("item", "")) != "":
				rewards.append("+ ITEM")
			if not rewards.is_empty():
				sub += "   " + "  ".join(rewards)
			return sub
		"fork":
			var paths: Array = item.get("paths", [])
			return (
				"%s   %d PATHS" % [_fork_type_label(item.get("resolution", "choice")), paths.size()]
			)
		"checkpoint":
			return "SAVE POINT"
	return ""


# Sublabel prefix for a fork node, by resolution: "FORK" (choice), "RANDOM FORK",
# "CONDITIONAL FORK", "SACRIFICE FORK".
func _fork_type_label(resolution: String) -> String:
	match resolution:
		"random":
			return "RANDOM FORK"
		"conditional":
			return "CONDITIONAL FORK"
		"sacrifice":
			return "SACRIFICE FORK"
	return "FORK"


# ---------------------------------------------------------------------------
# Edges
# ---------------------------------------------------------------------------


# The control an edge endpoint attaches to: the node itself, or — when it's inside a collapsed group —
# that group's bar (so a boundary-crossing edge reroutes to the bar instead of vanishing). null when
# it resolves to nothing (a deleted target).
func _edge_endpoint_ctrl(id: String) -> Control:
	if _node_ctrls.has(id):
		return _node_ctrls[id]
	if _collapsed_frame_of.has(id):
		return _collapsed_frame_of[id]
	return null


# Appends an orthogonal edge that leaves the source and enters the target on whichever faces point
# toward each other (top / bottom / left / right) — so a sideways or upward connection lands on the
# side or bottom of the node instead of always routing into its top.
func _add_edge_between(src: Control, tgt: Control, color: Color, width: float = 2.0) -> void:
	var route: Dictionary = _edge_route(src, tgt)
	_edges.append(
		{"points": route["points"], "arrow_dir": route["arrow_dir"], "color": color, "width": width}
	)


# ── Traffic heatmap (audit overlay) ──────────────────────────────────────────


# Applies (or clears, with {}) the audit's Monte-Carlo traffic overlay:
# {nodes: {id: pct}, edges: {"id:edge_idx": pct}}. Re-renders immediately.
func set_traffic(traffic: Dictionary) -> void:
	_traffic = traffic
	_layout_graph()


# Applies (or clears, with []) the route-recap overlay from an ordered trail
# of visited node ids. Re-renders immediately.
func set_route(trail: Array) -> void:
	_route_nodes = {}
	_route_edges = {}
	for i: int in trail.size():
		_route_nodes[str(trail[i])] = true
		if i > 0:
			_route_edges["%s>%s" % [str(trail[i - 1]), str(trail[i])]] = true
	_layout_graph()


# Traffic share → color: a temperature ramp — light green (extremely rare)
# through amber to red (extremely common). sqrt spreads the low end so 5% vs
# 25% is still visibly different.
func _traffic_color(pct: float) -> Color:
	var t: float = sqrt(clampf(pct / 100.0, 0.0, 1.0))
	var cold: Color = Color(0.6, 1.0, 0.6)  # light green — extremely rare
	var mid: Color = Color(1.0, 0.75, 0.2)  # amber — moderate traffic
	var hot: Color = Color(1.0, 0.2, 0.15)  # red — extremely common
	if t < 0.5:
		return cold.lerp(mid, t * 2.0)
	return mid.lerp(hot, (t - 0.5) * 2.0)


# A small "N%" chip floated above a node's top-right corner (editor heatmap only).
func _attach_traffic_chip(ctrl: Control, pct: float) -> void:
	var chip: Label = Label.new()
	chip.text = ("%.1f%%" if pct > 0.0 and pct < 1.0 else "%.0f%%") % pct
	chip.custom_minimum_size = Vector2(NODE_WIDTH, 0)
	chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	chip.position = Vector2(0, -14)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_theme_font_size_override("font_size", 10)
	chip.add_theme_color_override("font_color", _traffic_color(pct))
	ctrl.add_child(chip)


# Builds an orthogonal 3-segment route between two node rects. The exit/entry faces are chosen by
# which face the centre-to-centre line crosses (aspect-ratio aware, so wide nodes still prefer a
# vertical exit); the route leaves straight out of the exit face, runs perpendicular, then turns
# straight into the entry face. arrow_dir is the unit heading at the entry (for the arrowhead).
func _edge_route(src: Control, tgt: Control) -> Dictionary:
	var ss: Vector2 = src.size
	var ts: Vector2 = tgt.size
	var sc: Vector2 = src.position + ss * 0.5
	var tc: Vector2 = tgt.position + ts * 0.5
	var delta: Vector2 = tc - sc
	var approach: float = 20.0  # how far before the entry face the route makes its final turn
	var from: Vector2
	var to: Vector2
	var arrow_dir: Vector2
	var pts: PackedVector2Array = PackedVector2Array()
	# Vertical when the centre line exits the top/bottom face rather than a side: compare slopes
	# scaled by the half-extents, i.e. |dy|/halfH vs |dx|/halfW → |dy|*W vs |dx|*H.
	if absf(delta.y) * ss.x >= absf(delta.x) * ss.y:
		if delta.y >= 0.0:  # target below → leave bottom, enter top
			from = Vector2(sc.x, src.position.y + ss.y)
			to = Vector2(tc.x, tgt.position.y)
			arrow_dir = Vector2(0, 1)
		else:  # target above → leave top, enter bottom
			from = Vector2(sc.x, src.position.y)
			to = Vector2(tc.x, tgt.position.y + ts.y)
			arrow_dir = Vector2(0, -1)
		var bend_y: float = clampf(
			to.y - arrow_dir.y * approach, minf(from.y, to.y), maxf(from.y, to.y)
		)
		pts.append(from)
		pts.append(Vector2(from.x, bend_y))
		pts.append(Vector2(to.x, bend_y))
		pts.append(to)
	else:
		if delta.x >= 0.0:  # target right → leave right, enter left
			from = Vector2(src.position.x + ss.x, sc.y)
			to = Vector2(tgt.position.x, tc.y)
			arrow_dir = Vector2(1, 0)
		else:  # target left → leave left, enter right
			from = Vector2(src.position.x, sc.y)
			to = Vector2(tgt.position.x + ts.x, tc.y)
			arrow_dir = Vector2(-1, 0)
		var bend_x: float = clampf(
			to.x - arrow_dir.x * approach, minf(from.x, to.x), maxf(from.x, to.x)
		)
		pts.append(from)
		pts.append(Vector2(bend_x, from.y))
		pts.append(Vector2(bend_x, to.y))
		pts.append(to)
	return {"points": pts, "arrow_dir": arrow_dir}


# ── Canvas comments (sticky notes) ───────────────────────────────────────────
# Author-only annotations stored on the journey (_graph_model.comments). Rendered behind the nodes,
# editable in the side panel, draggable like a node. The player map never has them (comment-less
# model); image export shows them static (map_mode → no gui_input).

const COMMENT_WIDTH: float = 220.0


func _make_comment(_idx: int, comment: Dictionary) -> Control:
	var color: Color = comment.get("color", UITheme.AMBER)
	var panel: PanelContainer = PanelContainer.new()
	panel.custom_minimum_size = Vector2(COMMENT_WIDTH, 0)
	panel.add_theme_stylebox_override("panel", _comment_stylebox(color))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE if map_mode else Control.MOUSE_FILTER_STOP
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(margin)
	var lbl: Label = Label.new()
	var text: String = str(comment.get("text", ""))
	var has_text: bool = text.strip_edges() != ""
	lbl.text = text if has_text else "(empty note)"
	lbl.add_theme_color_override("font_color", color if has_text else UITheme.DARK_TEXT)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(COMMENT_WIDTH - 20.0, 0)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(lbl)
	if not map_mode:
		panel.gui_input.connect(_on_comment_gui_input.bind(_idx))
	return panel


func _comment_stylebox(color: Color) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(color.r * 0.18, color.g * 0.18, color.b * 0.18, 0.92)
	s.border_color = Color(color.r, color.g, color.b, 0.7)
	s.border_width_left = 3  # a sticky-note "tab" down the left edge
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.corner_radius_top_left = 3
	s.corner_radius_top_right = 3
	s.corner_radius_bottom_left = 3
	s.corner_radius_bottom_right = 3
	return s


# A press on a comment arms a drag; _input tracks motion/release globally (mirrors the node drag).
func _on_comment_gui_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_dragging_comment = idx
			_comment_drag_moved = false
			_comment_drag_started = false
			get_viewport().set_input_as_handled()


func _handle_comment_drag(event: InputEvent) -> void:
	var comments: Array = _graph_model.get("comments", [])
	if _dragging_comment >= comments.size():
		_dragging_comment = -1
		return
	if event is InputEventMouseMotion:
		if not _comment_drag_started:
			_comment_drag_started = true
			nodes_drag_started.emit()  # one undo entry per drag (the builder snapshots comments too)
		var delta: Vector2 = (event as InputEventMouseMotion).relative / _zoom
		var c: Dictionary = comments[_dragging_comment]
		c["pos"] = (c.get("pos", Vector2.ZERO) as Vector2) + delta
		if _dragging_comment < _comment_ctrls.size():
			(_comment_ctrls[_dragging_comment] as Control).position = c["pos"]
		_comment_drag_moved = true
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			var idx: int = _dragging_comment
			_dragging_comment = -1
			if _comment_drag_moved:
				var cd: Dictionary = comments[idx]
				cd["pos"] = GraphLayout.snap(cd.get("pos", Vector2.ZERO))
			_selected_ids = []  # drop node highlights; the note becomes the active selection
			refresh()
			comment_clicked.emit(idx)  # select it (click or drag) so the side panel + Delete target it
			get_viewport().set_input_as_handled()


# Canvas-space point at the centre of the current view (for placing a new comment).
func view_center_world() -> Vector2:
	return (size * 0.5 - _canvas.position) / _zoom


# Clears the node selection WITHOUT emitting graph_selection_changed — used when a frame becomes the
# active selection (so it doesn't bounce the side panel back to the journey-info panel).
func deselect_nodes_silent() -> void:
	_selected_ids = []


# ── Group frames ─────────────────────────────────────────────────────────────
# Free-form labelled rectangles drawn behind everything. Dragging the header moves the frame AND the
# nodes inside it; the bottom-right grip resizes. Editor furniture only (the player map has no groups).

const FRAME_HEADER_H: float = 24.0
const FRAME_GRIP: float = 16.0
const FRAME_MIN: Vector2 = Vector2(140, 100)


func _make_frame(idx: int, group: Dictionary) -> Control:
	var rect: Rect2 = group.get("rect", Rect2(0, 0, 360, 240))
	var color: Color = group.get("color", UITheme.PURPLE_BRIGHT)
	var collapsed: bool = group.get("collapsed", false)
	var frame: Control = Control.new()
	# Collapsed: just the header bar (the body and the nodes inside it are hidden). No custom_minimum_size
	# so a live resize is free to shrink (FRAME_MIN clamps it).
	frame.size = Vector2(rect.size.x, FRAME_HEADER_H) if collapsed else rect.size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE  # body passes clicks through to the nodes in front

	if not collapsed:
		var fill: Panel = Panel.new()
		fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.add_theme_stylebox_override("panel", _frame_stylebox(color))
		frame.add_child(fill)

	var header: PanelContainer = PanelContainer.new()
	header.anchor_right = 1.0
	header.offset_bottom = FRAME_HEADER_H
	header.add_theme_stylebox_override("panel", _frame_header_stylebox(color))
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE if map_mode else Control.MOUSE_FILTER_STOP
	var hmargin: MarginContainer = MarginContainer.new()
	hmargin.add_theme_constant_override("margin_left", 6)
	hmargin.add_theme_constant_override("margin_right", 8)
	hmargin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hrow: HBoxContainer = HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 4)
	hrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hmargin.add_child(hrow)
	header.add_child(hmargin)
	if not map_mode:
		var tbtn: Button = Button.new()  # collapse / expand chevron (the rest of the header drags)
		tbtn.text = "▸" if collapsed else "▾"
		tbtn.focus_mode = Control.FOCUS_NONE
		tbtn.flat = true
		tbtn.add_theme_color_override("font_color", UITheme.BG)
		tbtn.add_theme_color_override("font_hover_color", UITheme.WHITE_SOFT)
		tbtn.add_theme_font_size_override("font_size", 12)
		tbtn.tooltip_text = "Collapse / expand this group"
		tbtn.pressed.connect(func() -> void: frame_toggle_collapse.emit(idx))
		hrow.add_child(tbtn)
	var hlbl: Label = Label.new()
	var ltext: String = str(group.get("label", ""))
	hlbl.text = (ltext if ltext.strip_edges() != "" else "GROUP").to_upper()
	hlbl.add_theme_color_override("font_color", UITheme.BG)
	hlbl.add_theme_font_size_override("font_size", 11)
	hlbl.clip_text = true
	hlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hlbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hrow.add_child(hlbl)
	frame.add_child(header)

	if not map_mode:
		header.gui_input.connect(_on_frame_header_gui_input.bind(idx))
		if not collapsed:
			var grip: Panel = Panel.new()
			grip.anchor_left = 1.0
			grip.anchor_top = 1.0
			grip.anchor_right = 1.0
			grip.anchor_bottom = 1.0
			grip.offset_left = -FRAME_GRIP
			grip.offset_top = -FRAME_GRIP
			grip.mouse_filter = Control.MOUSE_FILTER_STOP
			grip.tooltip_text = "Drag to resize the frame"
			var gs: StyleBoxFlat = StyleBoxFlat.new()
			gs.bg_color = Color(color.r, color.g, color.b, 0.8)
			gs.corner_radius_top_left = 4
			grip.add_theme_stylebox_override("panel", gs)
			grip.gui_input.connect(_on_frame_resize_gui_input.bind(idx))
			frame.add_child(grip)
	return frame


func _frame_stylebox(color: Color) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(color.r, color.g, color.b, 0.05)
	s.border_color = Color(color.r, color.g, color.b, 0.5)
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_width_top = 2
	s.border_width_bottom = 2
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	return s


func _frame_header_stylebox(color: Color) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(color.r, color.g, color.b, 0.85)
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	return s


func _on_frame_header_gui_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var groups: Array = _graph_model.get("groups", [])
			if idx < groups.size():
				_dragging_frame = idx
				_frame_drag_moved = false
				_frame_drag_started = false
				var g: Dictionary = groups[idx]
				# A collapsed frame drags exactly its frozen members; an expanded one takes whatever's inside.
				_frame_drag_node_ids = (
					(g.get("members", []) as Array).duplicate()
					if g.get("collapsed", false)
					else _nodes_in_frame_rect(g.get("rect", Rect2()))
				)
				get_viewport().set_input_as_handled()


func _on_frame_resize_gui_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_resizing_frame = idx
			_frame_resize_started = false
			get_viewport().set_input_as_handled()


# Node ids whose centre falls inside `rect` — captured when a frame drag begins, to move with it.
func _nodes_in_frame_rect(rect: Rect2) -> Array:
	var ids: Array = []
	var half: Vector2 = Vector2(NODE_WIDTH, NODE_HEIGHT) * 0.5
	for id: String in _graph_model.get("nodes", {}):
		var pos: Vector2 = (_graph_model["nodes"][id] as Dictionary).get("pos", Vector2.ZERO)
		if rect.has_point(pos + half):
			ids.append(id)
	return ids


func _handle_frame_drag(event: InputEvent) -> void:
	var groups: Array = _graph_model.get("groups", [])
	if _dragging_frame >= groups.size():
		_dragging_frame = -1
		return
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if event is InputEventMouseMotion:
		if not _frame_drag_started:
			_frame_drag_started = true
			nodes_drag_started.emit()
		var delta: Vector2 = (event as InputEventMouseMotion).relative / _zoom
		var g: Dictionary = groups[_dragging_frame]
		var r: Rect2 = g.get("rect", Rect2())
		r.position += delta
		g["rect"] = r
		if _dragging_frame < _frame_ctrls.size():
			(_frame_ctrls[_dragging_frame] as Control).position = r.position
		for id: String in _frame_drag_node_ids:
			if nodes.has(id):
				var n: Dictionary = nodes[id]
				n["pos"] = (n.get("pos", Vector2.ZERO) as Vector2) + delta
				if _node_ctrls.has(id):
					(_node_ctrls[id] as Control).position = n["pos"]
		_frame_drag_moved = true
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			var idx: int = _dragging_frame
			_dragging_frame = -1
			if _frame_drag_moved:
				var g: Dictionary = groups[idx]
				var r: Rect2 = g.get("rect", Rect2())
				r.position = GraphLayout.snap(r.position)
				g["rect"] = r
				for id: String in _frame_drag_node_ids:
					if nodes.has(id):
						(nodes[id] as Dictionary)["pos"] = GraphLayout.snap(
							(nodes[id] as Dictionary).get("pos", Vector2.ZERO)
						)
			_frame_drag_node_ids = []
			_selected_ids = []
			refresh()
			frame_clicked.emit(idx)
			get_viewport().set_input_as_handled()


func _handle_frame_resize(event: InputEvent) -> void:
	var groups: Array = _graph_model.get("groups", [])
	if _resizing_frame >= groups.size():
		_resizing_frame = -1
		return
	if event is InputEventMouseMotion:
		if not _frame_resize_started:
			_frame_resize_started = true
			nodes_drag_started.emit()
		var delta: Vector2 = (event as InputEventMouseMotion).relative / _zoom
		var g: Dictionary = groups[_resizing_frame]
		var r: Rect2 = g.get("rect", Rect2())
		r.size = Vector2(
			maxf(FRAME_MIN.x, r.size.x + delta.x), maxf(FRAME_MIN.y, r.size.y + delta.y)
		)
		g["rect"] = r
		if _resizing_frame < _frame_ctrls.size():
			(_frame_ctrls[_resizing_frame] as Control).size = r.size
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			var idx: int = _resizing_frame
			_resizing_frame = -1
			var g: Dictionary = groups[idx]
			var r: Rect2 = g.get("rect", Rect2())
			r.size = GraphLayout.snap(r.size)
			g["rect"] = r
			refresh()
			get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Pan + zoom
# ---------------------------------------------------------------------------


# Continuous keyboard pan (builder only). Polled rather than event-driven so a held key scrolls
# smoothly. Stands down while a text field is focused (so typing a node name doesn't pan) and
# while a modifier is held (so Ctrl+S / Ctrl+D and friends don't also scroll).
func _process(delta: float) -> void:
	if not keyboard_pan_enabled or not is_visible_in_tree():
		return
	if _text_focused():
		return
	if (
		Input.is_key_pressed(KEY_CTRL)
		or Input.is_key_pressed(KEY_ALT)
		or Input.is_key_pressed(KEY_META)
	):
		return
	var dir: Vector2 = Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W):
		dir.y += 1.0
	if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S):
		dir.y -= 1.0
	if dir != Vector2.ZERO:
		_pan_offset += dir.normalized() * KEY_PAN_SPEED * delta
		_apply_transform()


# True when a text-entry control has focus — pan/keys must yield to typing.
func _text_focused() -> bool:
	var f: Control = get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit


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
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and not map_mode:
			# Right-click on empty canvas (a node consumes its own input) → context menu. Hand the
			# builder the world position so it can drop the chosen item under the cursor.
			canvas_context_menu_requested.emit((mb.position - _canvas.position) / _zoom)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			# Map mode, or the space-bar "hand tool" in the builder: left-drag pans (like the
			# middle button) instead of box-selecting.
			var want_pan: bool = map_mode or Input.is_key_pressed(KEY_SPACE)
			if mb.pressed and want_pan:
				_panning = true
				_last_mouse = mb.position
				accept_event()
			elif not mb.pressed and _panning:
				_panning = false  # end a left-drag pan on release (space may already be released)
				accept_event()
			elif mb.pressed:
				# Left press on empty canvas (not a node) → start a marquee box-select. A press+release
				# with no real drag collapses to "clear selection".
				_marquee_active = true
				_marquee_additive = mb.ctrl_pressed or mb.shift_pressed
				_marquee_start = mb.position
				_marquee_end = mb.position
				accept_event()
			elif _marquee_active:
				_finish_marquee()
				accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning:
			var delta: Vector2 = mm.position - _last_mouse
			_last_mouse = mm.position
			_pan_offset += delta
			_apply_transform()
		elif _marquee_active:
			_marquee_end = mm.position
			queue_redraw()
			accept_event()


# Draws the marquee box (screen space, over the graph).
func _draw() -> void:
	if _marquee_active:
		var rect: Rect2 = Rect2(_marquee_start, Vector2.ZERO).expand(_marquee_end)
		var accent: Color = UITheme.PURPLE_BRIGHT
		draw_rect(rect, Color(accent.r, accent.g, accent.b, 0.12), true)
		draw_rect(rect, accent, false, 1.5)
	if _connect_drag_active:
		# Rubber-band from the handle to the cursor, in GraphView-screen space (canvas-local × zoom +
		# pan). Red over an invalid target (the source or an ancestor → would loop), else edge colour.
		var bad: bool = (
			_connect_drag_target != ""
			and (
				_connect_drag_target == _connect_drag_source
				or _connect_drag_invalid.has(_connect_drag_target)
			)
		)
		var col: Color = (
			UITheme.ERROR_SOFT
			if bad
			else (UITheme.FORK_EDGE if _connect_drag_edge_idx >= 0 else UITheme.EDGE)
		)
		var from_s: Vector2 = _canvas.position + _connect_drag_from * _zoom
		var to_s: Vector2 = _canvas.position + _connect_drag_to * _zoom
		draw_line(from_s, to_s, col, 2.0)
		draw_circle(to_s, 4.0, col)
		if _connect_drag_target != "" and _node_ctrls.has(_connect_drag_target):
			var tc: Control = _node_ctrls[_connect_drag_target]
			draw_rect(
				Rect2(_canvas.position + tc.position * _zoom, tc.size * _zoom), col, false, 2.0
			)


# Finalizes a marquee: selects every node whose on-screen rect intersects the box (additive when
# Ctrl/Shift was held at start). A drag too small to count is a click on empty canvas → clear.
func _finish_marquee() -> void:
	_marquee_active = false
	var rect: Rect2 = Rect2(_marquee_start, Vector2.ZERO).expand(_marquee_end)
	queue_redraw()
	if rect.size.length() < MARQUEE_DRAG_THRESHOLD:
		if not _marquee_additive:
			_set_selection([])
		return
	var ids: Array = _selected_ids.duplicate() if _marquee_additive else []
	for id: String in _node_ctrls:
		var c: Control = _node_ctrls[id]
		var screen_rect: Rect2 = Rect2(_canvas.position + c.position * _zoom, c.size * _zoom)
		if rect.intersects(screen_rect) and not ids.has(id):
			ids.append(id)
	_set_selection(ids)


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
	_canvas.scale = Vector2(_zoom, _zoom)
	# Re-invoke _draw() — pan/zoom changes don't automatically invalidate the
	# CanvasItem's drawn primitives, so without this the edges flicker out.
	_canvas.queue_redraw()


# Frames the whole graph: zooms/pans so every node fits in the viewport with a
# margin. Falls back to the default view when there's nothing to frame.
# Bounding box of all laid-out node widgets in canvas-local space, as
# {min, max, size}, or {} when there are no nodes. Shared by fit_to_view and the
# image-capture path so both frame the exact same extent.
func content_bounds() -> Dictionary:
	var min_p: Vector2 = Vector2(INF, INF)
	var max_p: Vector2 = Vector2(-INF, -INF)
	var found: bool = false
	for c: Node in _canvas.get_children():
		if not (c is Control) or not c.has_meta("graph_item"):
			continue
		found = true
		var node: Control = c as Control
		min_p.x = min(min_p.x, node.position.x)
		min_p.y = min(min_p.y, node.position.y)
		max_p.x = max(max_p.x, node.position.x + node.size.x)
		max_p.y = max(max_p.y, node.position.y + node.size.y)
	if not found:
		return {}
	return {"min": min_p, "max": max_p, "size": max_p - min_p}


func fit_to_view() -> void:
	var b: Dictionary = content_bounds()
	if b.is_empty():
		reset_view()
		return
	var content: Vector2 = b["size"]
	if content.x <= 0.0 or content.y <= 0.0:
		reset_view()
		return

	var avail: Vector2 = size - Vector2(FIT_PADDING * 2.0, FIT_PADDING * 2.0)
	var z: float = clamp(min(avail.x / content.x, avail.y / content.y), ZOOM_MIN, ZOOM_MAX)
	_zoom = z
	# Map the content's center to the viewport center.
	var content_center: Vector2 = (b["min"] + b["max"]) * 0.5
	_pan_offset = size * 0.5 - content_center * _zoom
	_apply_transform()


# Frames the ENTIRE graph for an offscreen image capture: pins the content at
# `margin` px from the top-left at `scale`× zoom, with no interactive centering.
# Returns the pixel size the render target needs (content×scale + 2×margin), or
# Vector2.ZERO when the graph is empty. Used by the builder's "export image".
func frame_for_capture(scale: float, margin: float) -> Vector2:
	var b: Dictionary = content_bounds()
	if b.is_empty():
		return Vector2.ZERO
	_has_initial_center = true  # block any pending _center_initial_view re-pan
	_zoom = scale
	_pan_offset = Vector2(margin, margin) - (b["min"] as Vector2) * scale
	_apply_transform()
	return (b["size"] as Vector2) * scale + Vector2(margin, margin) * 2.0


# ── Journey-map marker (map mode) ────────────────────────────────────────────


# Finds the laid-out node for a stable map key. In the graph the key IS the node id,
# so resolve it directly against the node controls (ids are unique).
func _find_map_node(key: String) -> Control:
	if key == "":
		return null
	return _node_ctrls.get(key, null)


# Canvas-space centre of the node for `key`, or Vector2.INF when not found.
func node_center(key: String) -> Vector2:
	var n: Control = _find_map_node(key)
	if n == null:
		return Vector2.INF
	return n.position + n.size * 0.5


func set_marker_color(c: Color) -> void:
	_marker_color = c
	if is_instance_valid(_marker):
		_apply_marker_style()


# Snaps the marker onto the node for `key` (no animation).
func set_marker_at(key: String) -> void:
	var n: Control = _find_map_node(key)
	if n == null:
		return
	_ensure_marker()
	_marker.visible = true
	_marker.position = n.position - Vector2(MARKER_PAD, MARKER_PAD)


# Pans (no zoom change) so the node for `key` sits at the viewport centre.
func center_on(key: String) -> void:
	var ctr: Vector2 = node_center(key)
	if ctr == Vector2.INF:
		return
	_has_initial_center = true
	_pan_offset = size * 0.5 - ctr * _zoom
	_apply_transform()


func _ensure_marker() -> void:
	if is_instance_valid(_marker):
		return
	_marker = Panel.new()
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.size = Vector2(NODE_WIDTH + MARKER_PAD * 2.0, NODE_HEIGHT + MARKER_PAD * 2.0)
	_marker.z_index = 5  # above the node panels
	_apply_marker_style()
	_canvas.add_child(_marker)


func _apply_marker_style() -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(_marker_color.r, _marker_color.g, _marker_color.b, 0.10)
	s.border_color = _marker_color
	s.border_width_left = 3
	s.border_width_right = 3
	s.border_width_top = 3
	s.border_width_bottom = 3
	s.corner_radius_top_left = 12
	s.corner_radius_top_right = 12
	s.corner_radius_bottom_left = 12
	s.corner_radius_bottom_right = 12
	s.shadow_color = Color(_marker_color.r, _marker_color.g, _marker_color.b, 0.6)
	s.shadow_size = 16
	_marker.add_theme_stylebox_override("panel", s)


# Restores the default zoom + top-center framing.
func reset_view() -> void:
	_zoom = 1.0
	_pan_offset = Vector2(size.x * 0.5, VIEW_TOP_MARGIN)
	_apply_transform()
