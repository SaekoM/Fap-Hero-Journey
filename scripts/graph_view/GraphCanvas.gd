extends Control

# Child of GraphView. Holds the auto-laid-out node widgets as children, and
# draws the edges that connect them via _draw(). Pan/zoom transform is applied
# by the parent GraphView to this control's position + scale, so node positions
# and edge coordinates share the same canvas-local space.

# Edges: list of { points: PackedVector2Array, color: Color, arrow_dir: Vector2 }
# plus optional dashed: bool and width: float (traffic heatmap thickens hot edges).
var edges: Array = []

# Region bands (Loop pairs): list of { rect: Rect2, color: Color }. Drawn first, beneath the edges and
# the node cards, as a faint tinted rounded rect so the repeated stretch reads as one enclosed region.
var bands: Array = []

# Map backdrops (a journey's location images): a STACK drawn FIRST — under bands, edges and nodes — in
# list order (first = bottom), in canvas-local space so they pan/zoom locked to the graph. Each entry is
# { texture: Texture2D, offset: Vector2, scale: float, opacity: float }. Composed renditions layer the
# base's backdrops (bottom) then each overlay's on top.
var backdrops: Array = []


func set_edges(e: Array) -> void:
	edges = e
	queue_redraw()


func set_bands(b: Array) -> void:
	bands = b
	queue_redraw()


# Sets the full backdrop stack (empty clears). Offsets/scales are canvas-local — the same space as node
# positions — so alignment holds at any pan/zoom.
func set_backdrops(list: Array) -> void:
	backdrops = list
	queue_redraw()


# Slack added around the drawn extent so a cull rect computed one frame is still right the next, while
# a drag is carrying something outward.
const CULL_MARGIN: float = 512.0


# Godot culls a CanvasItem by its own rect, and this one deliberately draws outside it: node positions
# run NEGATIVE (the tree layout centres on x = 0) and a hand-placed node can sit thousands of pixels
# past the far edge. Once the drawn area no longer overlapped the rect the WHOLE item was culled, so
# every edge vanished at once at particular pan/zoom combinations while the node cards stayed — they
# are separate items with rects of their own. A custom cull rect covering what we actually draw fixes
# it for good, and recomputing it per redraw means a drag that carries a node out of the old extent is
# covered without the parent having to notice.
func _update_cull_rect() -> void:
	var r: Rect2 = Rect2(Vector2.ZERO, size)
	for c: Node in get_children():
		if c is Control:
			r = r.merge(Rect2((c as Control).position, (c as Control).size))
	for e: Dictionary in edges:
		for pt: Vector2 in e.get("points", PackedVector2Array()) as PackedVector2Array:
			r = r.expand(pt)
	for b: Dictionary in bands:
		r = r.merge(b.get("rect", Rect2()) as Rect2)
	for bd: Dictionary in backdrops:
		var tex: Texture2D = bd.get("texture")
		if tex == null:
			continue
		# A rotated backdrop sweeps beyond its own box; its diagonal is the safe bound either way.
		var drawn: Vector2 = tex.get_size() * maxf(0.01, float(bd.get("scale", 1.0)))
		var reach: float = drawn.length() * 0.5
		var centre: Vector2 = (bd.get("offset", Vector2.ZERO) as Vector2) + drawn * 0.5
		r = r.merge(Rect2(centre - Vector2(reach, reach), Vector2(reach, reach) * 2.0))
	RenderingServer.canvas_item_set_custom_rect(get_canvas_item(), true, r.grow(CULL_MARGIN))


func _draw() -> void:
	_update_cull_rect()
	for bd in backdrops:
		var tex: Texture2D = bd.get("texture")
		var op: float = clampf(float(bd.get("opacity", 0.6)), 0.0, 1.0)
		if tex == null or op <= 0.0:
			continue
		var scl: float = maxf(0.01, float(bd.get("scale", 1.0)))
		var rot: float = deg_to_rad(float(bd.get("rotation", 0.0)))
		var tex_size: Vector2 = tex.get_size()
		var offset: Vector2 = bd.get("offset", Vector2.ZERO)
		if is_zero_approx(rot):
			draw_texture_rect(tex, Rect2(offset, tex_size * scl), false, Color(1, 1, 1, op))
		else:
			# Rotate around the placed image's centre: translate there, rotate + scale, draw centred.
			var center: Vector2 = offset + tex_size * scl * 0.5
			draw_set_transform(center, rot, Vector2(scl, scl))
			draw_texture_rect(tex, Rect2(-tex_size * 0.5, tex_size), false, Color(1, 1, 1, op))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)  # reset for bands/edges below
	for b in bands:
		var rect: Rect2 = b["rect"]
		var bc: Color = b["color"]
		draw_rect(rect, Color(bc.r, bc.g, bc.b, 0.07), true)
		_draw_band_border(rect, Color(bc.r, bc.g, bc.b, 0.4))
	for e in edges:
		var points: PackedVector2Array = e["points"]
		var color: Color = e["color"]
		var dashed: bool = e.get("dashed", false)
		var width: float = float(e.get("width", 2.0))
		# The route is pre-computed by GraphView (orthogonal, entering the target on whichever face
		# points back toward the source). Draw each segment, then an arrowhead along the entry heading.
		for i in range(points.size() - 1):
			_edge_seg(points[i], points[i + 1], color, dashed, width)
		if points.size() > 0:
			_draw_arrowhead(points[points.size() - 1], e.get("arrow_dir", Vector2(0, 1)), color)


# A dashed rectangle outline for a region band — four dashed sides in the band colour.
func _draw_band_border(rect: Rect2, color: Color) -> void:
	var tl: Vector2 = rect.position
	var tr: Vector2 = rect.position + Vector2(rect.size.x, 0)
	var br: Vector2 = rect.position + rect.size
	var bl: Vector2 = rect.position + Vector2(0, rect.size.y)
	draw_dashed_line(tl, tr, color, 1.5, 6.0)
	draw_dashed_line(tr, br, color, 1.5, 6.0)
	draw_dashed_line(br, bl, color, 1.5, 6.0)
	draw_dashed_line(bl, tl, color, 1.5, 6.0)


# A small arrowhead at `tip` pointing along `dir` (the unit heading into the node). The two barbs
# splay back from the tip, so it reads correctly whether the edge enters from the top, bottom, or a side.
func _draw_arrowhead(tip: Vector2, dir: Vector2, color: Color) -> void:
	var a: float = 6.0
	var back: Vector2 = -dir * a
	var perp: Vector2 = Vector2(-dir.y, dir.x) * a
	draw_line(tip, tip + back + perp, color, 2.0, true)
	draw_line(tip, tip + back - perp, color, 2.0, true)


# One edge segment, solid for normal flow or dashed for a redirect (a non-default jump).
func _edge_seg(a: Vector2, b: Vector2, color: Color, dashed: bool, width: float = 2.0) -> void:
	if dashed:
		draw_dashed_line(a, b, color, width, 6.0)
	else:
		draw_line(a, b, color, width, true)
