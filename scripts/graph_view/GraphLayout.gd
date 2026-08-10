class_name GraphLayout
extends RefCounted

# ---------------------------------------------------------------------------
# GraphLayout — position helpers for the graph editor: `snap` (the one place the drag grid is
# applied, so it stays consistent everywhere) and `seed_positions`, a fallback layout for a graph
# that carries no authored positions.
#
# seed_positions is a FALLBACK: a freshly-migrated legacy journey has no positions, so this lays it
# out simply — row = longest-path depth from start, columns spread within a row (id-sorted). The
# builder seeds from GraphView.tree_positions (a port of the real tree layout, compact + centered)
# and authors drag from there; seed_positions' main live consumer is the runtime journey map of a
# legacy journey. A rough but non-overlapping start — not meant to reproduce the tree layout exactly.
#
# Keeping position decisions behind this seam (plus tree_positions) leaves room for the optional
# auto-layout (Sugiyama — GRAPH_EDITOR_OVERHAUL.md §9 / L5) to slot in later.
# ---------------------------------------------------------------------------

const COL_W: float = 320.0  # horizontal spacing between columns within a layer
const ROW_H: float = 140.0  # vertical spacing between layers
const GRID: float = 24.0  # snap grid for author drags (kept here as the layout authority)


# Assigns a "pos" (Vector2) to every node in `graph`, IN PLACE. A simple layered placement: each
# node's row is its longest-path depth from start (so a converged node sits below all of its
# predecessors), and within a row nodes spread left-to-right in a stable (id-sorted) order so the
# layout is the same run to run. Non-overlapping by construction (one column per node per row).
static func seed_positions(graph: Dictionary) -> void:
	var nodes: Dictionary = graph.get("nodes", {})
	var depth: Dictionary = _depths(graph)
	# Bucket node ids by row (= depth; unreachable nodes default to row 0), id-sorted for stability.
	var rows: Dictionary = {}  # int row -> Array[String]
	var ids: Array = nodes.keys()
	ids.sort()
	for id: String in ids:
		var r: int = int(depth.get(id, 0))
		if not rows.has(r):
			rows[r] = []
		(rows[r] as Array).append(id)
	# Each node: x = its column index within its row, y = its row.
	for r: int in rows:
		var layer: Array = rows[r]
		for c in layer.size():
			(nodes[layer[c]] as Dictionary)["pos"] = Vector2(float(c) * COL_W, float(r) * ROW_H)


# Snaps a position to the editor grid. The one place the grid size is applied, so it stays
# consistent between drag and seed/auto-layout.
static func snap(p: Vector2) -> Vector2:
	return Vector2(roundi(p.x / GRID) * GRID, roundi(p.y / GRID) * GRID)


# Longest-path depth (in nodes) from start to each node. DAG → terminates; `seen` backstops a
# malformed cycle. Longest (not shortest) so a node never sits at or above one that feeds it.
static func _depths(graph: Dictionary) -> Dictionary:
	var depth: Dictionary = {}
	_depth_dfs(graph, str(graph.get("start", "")), 0, depth, {})
	return depth


static func _depth_dfs(
	graph: Dictionary, id: String, d: int, depth: Dictionary, seen: Dictionary
) -> void:
	if id == "" or not (graph.get("nodes", {}) as Dictionary).has(id) or seen.has(id):
		return
	if depth.has(id) and int(depth[id]) >= d:
		return  # already reached by an equal-or-longer path
	depth[id] = d
	seen[id] = true
	for e: Dictionary in JourneyGraph.out_edges(graph, id):
		_depth_dfs(graph, str(e.get("to", "")), d + 1, depth, seen)
	seen.erase(id)


# ── Auto-layout (Sugiyama-style "Arrange") ───────────────────────────────────
# Assigns every node a tidy layered position IN PLACE, replacing manual positions (the builder's
# "Arrange" action; undoable there). Rows = longest-path depth; in-row order is chosen to reduce edge
# crossings (median heuristic); x is aligned to each node's neighbours (iterative barycenter with
# overlap removal) and the whole graph is centred on x=0. Deterministic (id-sorted seeds), so
# re-arranging twice gives the same result.
const LAYOUT_PASSES: int = 4


static func auto_layout(graph: Dictionary) -> void:
	var nodes: Dictionary = graph.get("nodes", {})
	if nodes.is_empty():
		return
	var adj: Dictionary = _adjacency(graph)
	var layer: Dictionary = _assign_layers(graph, adj)
	var layers: Array = _build_layers(nodes, layer)
	# Loop-aware: each Loop's body (Start + End + the nodes between them) shares a cluster id, so crossing
	# reduction keeps the whole body together in every row instead of scattering a fork's branches — that
	# keeps the drawn Loop band tight around its own nodes and off unrelated ones.
	var cluster: Dictionary = _loop_clusters(graph, adj)
	_reduce_crossings(layers, adj, cluster)
	var x: Dictionary = _assign_x(layers, adj)
	for l_idx in layers.size():
		for id: String in layers[l_idx]:
			(nodes[id] as Dictionary)["pos"] = Vector2(float(x[id]), float(l_idx) * ROW_H)


# Predecessor + successor id lists per node (edges to missing/empty targets ignored).
static func _adjacency(graph: Dictionary) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var preds: Dictionary = {}
	var succ: Dictionary = {}
	for id: String in nodes:
		preds[id] = []
		succ[id] = []
	for id: String in nodes:
		for e: Dictionary in JourneyGraph.out_edges(graph, id):
			var to: String = str(e.get("to", ""))
			if to != "" and nodes.has(to):
				(succ[id] as Array).append(to)
				(preds[to] as Array).append(id)
	return {"preds": preds, "succ": succ}


# Longest-path layer per node (sources at 0) via Kahn's topological order. A node left unreached
# (only if a cycle slipped past the draw-time guard) defaults to layer 0.
static func _assign_layers(graph: Dictionary, adj: Dictionary) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var succ: Dictionary = adj["succ"]
	var indeg: Dictionary = {}
	for id: String in nodes:
		indeg[id] = (adj["preds"][id] as Array).size()
	var queue: Array = []
	for id: String in nodes:
		if int(indeg[id]) == 0:
			queue.append(id)
	queue.sort()
	var layer: Dictionary = {}
	var qi: int = 0
	while qi < queue.size():
		var id: String = queue[qi]
		qi += 1
		if not layer.has(id):
			layer[id] = 0
		for to: String in succ[id] as Array:
			layer[to] = maxi(int(layer.get(to, 0)), int(layer[id]) + 1)
			indeg[to] = int(indeg[to]) - 1
			if int(indeg[to]) == 0:
				queue.append(to)
	for id: String in nodes:
		if not layer.has(id):
			layer[id] = 0
	return layer


# Groups node ids into per-layer arrays (index = layer), id-sorted for a deterministic start order.
static func _build_layers(nodes: Dictionary, layer: Dictionary) -> Array:
	var max_layer: int = 0
	for id: String in nodes:
		max_layer = maxi(max_layer, int(layer[id]))
	var layers: Array = []
	for _i in max_layer + 1:
		layers.append([])
	var ids: Array = nodes.keys()
	ids.sort()
	for id: String in ids:
		(layers[int(layer[id])] as Array).append(id)
	return layers


# Median-heuristic crossing reduction: a few down+up passes, each ordering a layer by the median
# position of its neighbours in the adjacent (already-ordered) layer. `cluster` keeps Loop bodies grouped.
static func _reduce_crossings(layers: Array, adj: Dictionary, cluster: Dictionary) -> void:
	for _i in LAYOUT_PASSES:
		for l_idx in range(1, layers.size()):
			_order_layer(layers, l_idx, l_idx - 1, adj["preds"], cluster)
		for l_idx in range(layers.size() - 2, -1, -1):
			_order_layer(layers, l_idx, l_idx + 1, adj["succ"], cluster)


static func _order_layer(
	layers: Array, l_idx: int, ref_idx: int, neigh: Dictionary, cluster: Dictionary
) -> void:
	var ref_pos: Dictionary = {}
	var ref_layer: Array = layers[ref_idx]
	for i in ref_layer.size():
		ref_pos[ref_layer[i]] = i
	var keyed: Array = []
	var cur: Array = layers[l_idx]
	for i in cur.size():
		var id: String = cur[i]
		var positions: Array = []
		for n: String in neigh[id] as Array:
			if ref_pos.has(n):
				positions.append(int(ref_pos[n]))
		positions.sort()
		var key: float = _median(positions) if not positions.is_empty() else float(i)
		keyed.append({"id": id, "key": key, "idx": i})
	# A Loop body's nodes share a cluster id; the whole cluster moves as one block (keyed on its members'
	# smallest median in this row) so its nodes stay contiguous instead of being split by outside nodes.
	# Non-clustered nodes are their own singleton cluster, so they still order by their own median.
	var group_key: Dictionary = {}
	for k: Dictionary in keyed:
		var cid: String = str(cluster.get(k["id"], k["id"]))
		if not group_key.has(cid) or k["key"] < float(group_key[cid]):
			group_key[cid] = k["key"]
	keyed.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var ca: String = str(cluster.get(a["id"], a["id"]))
			var cb: String = str(cluster.get(b["id"], b["id"]))
			var ga: float = float(group_key[ca])
			var gb: float = float(group_key[cb])
			if not is_equal_approx(ga, gb):
				return ga < gb
			if ca != cb:
				return ca < cb  # different clusters, same block position → stable by cluster id
			if not is_equal_approx(float(a["key"]), float(b["key"])):
				return a["key"] < b["key"]
			return a["idx"] < b["idx"]
	)
	var ordered: Array = []
	for k: Dictionary in keyed:
		ordered.append(k["id"])
	layers[l_idx] = ordered


# Cluster id per node for loop-aware layout: every node in a Loop's body (Start + End + the nodes on a
# path between them) maps to that Loop's End id; nodes in no loop are absent (they cluster as singletons).
# loop_to is data, not an edge, so the body is found purely from forward flow — descendants of the Start
# that are also ancestors of the End.
static func _loop_clusters(graph: Dictionary, adj: Dictionary) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var succ: Dictionary = adj["succ"]
	var preds: Dictionary = adj["preds"]
	var cluster: Dictionary = {}
	for end_id: String in nodes:
		if str((nodes[end_id] as Dictionary).get("type", "")) != "loop_end":
			continue
		var start_id: String = str(
			((nodes[end_id] as Dictionary).get("data", {}) as Dictionary).get("loop_to", "")
		)
		if start_id == "" or not nodes.has(start_id):
			continue
		var down: Dictionary = _reach(start_id, succ)
		var up: Dictionary = _reach(end_id, preds)
		cluster[start_id] = end_id
		cluster[end_id] = end_id
		for nid: String in down:
			if up.has(nid):
				cluster[nid] = end_id
	return cluster


# Set (Dictionary-as-set) of node ids reachable from `from_id` along the given adjacency (succ or preds).
static func _reach(from_id: String, adjmap: Dictionary) -> Dictionary:
	var seen: Dictionary = {}
	var stack: Array = [from_id]
	while not stack.is_empty():
		var id: String = str(stack.pop_back())
		if seen.has(id):
			continue
		seen[id] = true
		for n: Variant in adjmap.get(id, []):
			stack.append(str(n))
	return seen


static func _median(sorted_positions: Array) -> float:
	var n: int = sorted_positions.size()
	if n == 0:
		return 0.0
	if n % 2 == 1:
		return float(sorted_positions[n / 2])
	return (float(sorted_positions[n / 2 - 1]) + float(sorted_positions[n / 2])) * 0.5


# X per node: start at order-index spacing, then a few barycenter passes (toward the neighbour
# average, then push right to keep COL_W spacing in order), then centre the graph on x=0.
static func _assign_x(layers: Array, adj: Dictionary) -> Dictionary:
	var x: Dictionary = {}
	for l_idx in layers.size():
		var lay: Array = layers[l_idx]
		for i in lay.size():
			x[lay[i]] = float(i) * COL_W
	for _i in LAYOUT_PASSES:
		for l_idx in range(1, layers.size()):
			_align_layer(layers[l_idx], adj["preds"], x)
		for l_idx in range(layers.size() - 2, -1, -1):
			_align_layer(layers[l_idx], adj["succ"], x)
	_center_x(layers, x)
	return x


static func _align_layer(layer: Array, neigh: Dictionary, x: Dictionary) -> void:
	for i in layer.size():
		var id: String = layer[i]
		var ns: Array = neigh[id]
		var want: float = float(x[id])
		if not ns.is_empty():
			var total: float = 0.0
			for n: String in ns:
				total += float(x[n])
			want = total / float(ns.size())
		if i > 0:
			want = maxf(want, float(x[layer[i - 1]]) + COL_W)
		x[id] = want


static func _center_x(layers: Array, x: Dictionary) -> void:
	var min_x: float = INF
	var max_x: float = -INF
	for l_idx in layers.size():
		for id: String in layers[l_idx]:
			min_x = minf(min_x, float(x[id]))
			max_x = maxf(max_x, float(x[id]))
	if min_x == INF:
		return
	var shift: float = -(min_x + max_x) * 0.5
	for id: String in x:
		x[id] = float(x[id]) + shift
