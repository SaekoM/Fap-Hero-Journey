class_name JourneyGraph
extends RefCounted

# ---------------------------------------------------------------------------
# JourneyGraph — the DAG model that replaces the nested "tree" journey.
#
# A journey is a directed ACYCLIC graph of nodes:
#   { "start": <id>, "nodes": { <id>: Node, ... } }
#
#   Node = {
#     "type": "round" | "shop" | "storyboard" | "fork",
#     "data": Dictionary,   # item payload — the round/shop/storyboard fields, or for
#                           #   a fork: title/description/resolution/cond_metric/default_path
#     "out":  Array,        # outgoing edges; 0 = an end, 1 = linear, N = fork choices
#   }
#   Edge = { "to": <id>, ...fork-choice config: name/description/image_path/
#                            weight/threshold/required_item/cost }
#
# Non-fork nodes have exactly one out-edge (or zero = an end). Fork nodes have
# one out-edge per choice, each carrying that choice's resolution config. `to == ""`
# (or an empty `out`) terminates the journey.
#
# DAG-only: edges only ever point "forward" (guaranteed here by migration; enforced
# by the builder later). Pure data — no UI, no node state. Mirrors the
# ForkResolver / JourneyData / JourneyScanner split.
#
# `node.data` is shape-compatible with GameState's sequence items ({type,data}), so
# the runtime can read CurrentRound()/CurrentShop()/… straight off a node.
# ---------------------------------------------------------------------------

const FORK_TYPE := "fork"


# Migrates a scanned (nested tree) journey — JourneyScanner.parse_journey output with
# rounds[]/shops[]/storyboards[]/forks[] (forks holding nested paths) — into the graph
# model, PRESERVING current runtime behaviour exactly: each fork path's tail is wired
# to the node that followed the fork (the old implicit rejoin becomes an explicit edge,
# which authors can later rewire to skip/converge). Returns {"start", "nodes"}.
static func build_graph(journey: Dictionary) -> Dictionary:
	var nodes: Dictionary = {}
	var counter: Array = [0]  # boxed int for the id allocator
	var start: String = _flatten_level(
		journey.get("rounds", []),
		journey.get("shops", []),
		journey.get("storyboards", []),
		journey.get("forks", []),
		"",
		nodes,
		counter,
		0
	)
	var graph: Dictionary = {"start": start, "nodes": nodes}
	_migrate_checkpoint_flags(graph)
	return graph


# Builds a chain of nodes for one sequence level (the top-level journey or one fork
# path), interleaving its rounds/shops/storyboards/forks by the runtime sort key. Each
# node's out-edge points to the next item; the last points to `continue_to` (the rejoin
# for a fork path, or "" / end at the top level). Forks become fork nodes whose edges
# flatten each path with `continue_to` = the node after the fork. Returns the id of the
# first node, or `continue_to` when the level is empty (an empty path goes straight on).
static func _flatten_level(
	rounds: Array,
	shops: Array,
	storyboards: Array,
	forks: Array,
	continue_to: String,
	nodes: Dictionary,
	counter: Array,
	depth: int
) -> String:
	var ordered: Array = _interleave(rounds, shops, storyboards, forks)
	if ordered.is_empty():
		return continue_to

	# Pre-allocate an id per item so each node can forward-reference the next.
	# Prefer the item's stable node_id (authored, persisted as "NodeId") so graph ids
	# survive a save — the anchor for redirect edges and Test-From-Here. A legacy item
	# with no node_id (or a stray duplicate from a corrupt save) falls back to a unique
	# positional mint, so a collision can never silently drop a node from `nodes`.
	var ids: Array = []
	var used: Dictionary = {}
	for i in ordered.size():
		var id: String = str((ordered[i]["data"] as Dictionary).get("node_id", ""))
		if id == "" or used.has(id):
			id = _next_id(counter)
			while used.has(id):
				id = _next_id(counter)
		used[id] = true
		ids.append(id)

	for i in ordered.size():
		var item: Dictionary = ordered[i]
		var id: String = ids[i]
		var next_id: String = ids[i + 1] if i + 1 < ordered.size() else continue_to
		if item["type"] == "fork":
			nodes[id] = _build_fork(item["data"], next_id, nodes, counter, depth)
		else:
			nodes[id] = {
				"type": item["type"],
				"data": item["data"],
				"out": [] if next_id == "" else [{"to": next_id}],
				"depth": depth,
			}
	return ids[0]


# Builds a fork node from a scanned fork dict. Each path's content is flattened into
# its own chain (rejoining at `rejoin`), and the path's choice/presentation config
# becomes the edge to that chain's first node (or straight to `rejoin` if empty).
static func _build_fork(
	fork: Dictionary, rejoin: String, nodes: Dictionary, counter: Array, depth: int
) -> Dictionary:
	var edges: Array = []
	for p: Dictionary in fork.get("paths", []):
		var first: String = _flatten_level(
			p.get("rounds", []),
			p.get("shops", []),
			p.get("storyboards", []),
			p.get("forks", []),
			rejoin,
			nodes,
			counter,
			depth + 1
		)
		(
			edges
			. append(
				{
					"to": first,
					"name": p.get("name", ""),
					"description": p.get("description", ""),
					"image_path": p.get("image_path", ""),
					"weight": int(p.get("weight", 1)),
					"threshold": int(p.get("threshold", 0)),
					"required_item": str(p.get("required_item", "")),
					"cost": int(p.get("cost", 0)),
				}
			)
		)
	return {
		"type": FORK_TYPE,
		"data":
		{
			"title": fork.get("title", ""),
			"description": fork.get("description", ""),
			"resolution": str(fork.get("resolution", "choice")),
			"cond_metric": str(fork.get("cond_metric", "score")),
			"default_path": int(fork.get("default_path", 0)),
			"timeout_path": int(fork.get("timeout_path", -1)),
			# Kept so the runtime journey-map marker can key a fork node by after_order
			# (the map still renders the legacy nested model in Phase 2; the graph map in
			# Phase 3 re-keys by node id and this can go).
			"after_order": int(fork.get("after_order", 0)),
		},
		"out": edges,
		"depth": depth,
	}


# Interleaves a level's items into runtime order. Key scheme matches GameState
# .BuildSequence: round/storyboard = order*3, shop = after_order*3+1, fork = +2.
# Stable: ties break by append index so legacy colliding-key journeys (old saves where
# a shop/fork shared a round's anchor) order deterministically. Returns [{type,data},…].
static func _interleave(rounds: Array, shops: Array, storyboards: Array, forks: Array) -> Array:
	var keyed: Array = []  # [[key, append_idx, {type, data}], ...]
	var ai: int = 0
	for r: Dictionary in rounds:
		keyed.append([int(r.get("order", 0)) * 3, ai, {"type": "round", "data": r}])
		ai += 1
	for sb: Dictionary in storyboards:
		keyed.append([int(sb.get("order", 0)) * 3, ai, {"type": "storyboard", "data": sb}])
		ai += 1
	for sh: Dictionary in shops:
		keyed.append([int(sh.get("after_order", 0)) * 3 + 1, ai, {"type": "shop", "data": sh}])
		ai += 1
	for f: Dictionary in forks:
		keyed.append([int(f.get("after_order", 0)) * 3 + 2, ai, {"type": "fork", "data": f}])
		ai += 1
	keyed.sort_custom(
		func(a: Array, b: Array) -> bool: return a[0] < b[0] if a[0] != b[0] else a[1] < b[1]
	)
	var result: Array = []
	for e in keyed:
		result.append(e[2])
	return result


static func _next_id(counter: Array) -> String:
	var id: String = "n%d" % counter[0]
	counter[0] += 1
	return id


# ── Queries ─────────────────────────────────────────────────────────────────


# The node dict for `id`, or {} for "" / a missing id (treated as an end).
static func node(graph: Dictionary, id: String) -> Dictionary:
	return (graph.get("nodes", {}) as Dictionary).get(id, {})


static func out_edges(graph: Dictionary, id: String) -> Array:
	return (node(graph, id) as Dictionary).get("out", [])


static func is_fork(graph: Dictionary, id: String) -> bool:
	return (node(graph, id) as Dictionary).get("type", "") == FORK_TYPE


# A node ends the journey when it has no outgoing edges (or it's the "" sentinel).
static func is_end(graph: Dictionary, id: String) -> bool:
	return id == "" or out_edges(graph, id).is_empty()


# node_id -> its 1-based ordinal WITHIN ITS TYPE, in the nodes dict's insertion order. So the "N" in a
# save error's "Storyboard N" / "Round N" / "Fork N" is the same "N" shown on that node in the graph.
# Takes the raw nodes dict (not a graph) so both the builder validator and GraphView can call it.
static func type_ordinals(nodes: Dictionary) -> Dictionary:
	var counts: Dictionary = {}
	var out: Dictionary = {}
	for id: String in nodes:
		var t: String = str((nodes[id] as Dictionary).get("type", ""))
		counts[t] = int(counts.get(t, 0)) + 1
		out[id] = int(counts[t])
	return out


# The set (Dictionary-as-set) of node ids reachable from the journey start, following out-edges
# (post-redirect, when apply_redirects has run). Any node NOT in this set is orphaned — a redirect
# skipped past it and nothing else leads there. DAG → terminates; `seen` also backstops a malformed
# cycle. Feeds the builder's live "unreachable" warning.
static func reachable_ids(graph: Dictionary, from_id: String = "") -> Dictionary:
	var seen: Dictionary = {}
	var stack: Array = [from_id if from_id != "" else str(graph.get("start", ""))]
	while not stack.is_empty():
		var id: String = str(stack.pop_back())
		if id == "" or seen.has(id):
			continue
		seen[id] = true
		for e: Dictionary in out_edges(graph, id):
			stack.append(str(e.get("to", "")))
	return seen


# Rewires nodes' out-edges per a redirect map {node_id: target_id} — the runtime side of
# the "skip / converge" authoring (a fork path's tail, or any node, pointing somewhere
# other than its default successor). `target_id == ""` makes the node an end. No-op on
# fork nodes (their out-edges ARE the path choices — redirect a path's tail instead).
# Applied by parse_graph after build_graph / from_json; the builder + validation own
# keeping the result a DAG (targets must point forward).
static func apply_redirects(graph: Dictionary, redirects: Dictionary) -> void:
	var nodes: Dictionary = graph.get("nodes", {})
	for from_id: String in redirects:
		if not nodes.has(from_id):
			continue
		var n: Dictionary = nodes[from_id]
		if n.get("type", "") == FORK_TYPE:
			continue
		var to_id: String = str(redirects[from_id])
		n["out"] = [] if to_id == "" else [{"to": to_id}]


# Rewrites `graph` in place to drop every Loop marker (loop_start / loop_end), splicing each one's single
# out-edge through so the surviving flow stays continuous — the player map hides loops unless the journey
# opts in. Every edge pointing at a marker is re-pointed to the first non-marker it reaches (an empty
# target becomes an ending). The End's loop_to back-jump is data, not an edge, so it vanishes with the node.
static func strip_loop_markers(graph: Dictionary) -> void:
	var nodes: Dictionary = graph.get("nodes", {})
	var redirect: Dictionary = {}  # marker id -> its single out target ("" = ends)
	for id: String in nodes:
		var t: String = str((nodes[id] as Dictionary).get("type", ""))
		if t == "loop_start" or t == "loop_end":
			var out: Array = (nodes[id] as Dictionary).get("out", [])
			redirect[id] = str((out[0] as Dictionary).get("to", "")) if not out.is_empty() else ""
	if redirect.is_empty():
		return
	for id: String in redirect:
		nodes.erase(id)
	for id: String in nodes:
		for e: Dictionary in (nodes[id] as Dictionary).get("out", []):
			e["to"] = _skip_markers(str(e.get("to", "")), redirect)
	graph["start"] = _skip_markers(str(graph.get("start", "")), redirect)


# Follows a chain of removed markers to the first surviving node id (or "" when it runs off the end).
# The guard is defensive — out-edges form a DAG, so a marker chain can't actually cycle.
static func _skip_markers(to: String, redirect: Dictionary) -> String:
	var guard: int = 0
	while redirect.has(to) and guard < 10000:
		to = str(redirect[to])
		guard += 1
	return to


# ── Validation (free-form authoring) ─────────────────────────────────────────


# Checks a graph for the invariants the runtime assumes: a real start, every edge resolving to a
# node, acyclicity (the runtime walks the DAG and would loop forever on a back-edge), and which
# nodes are reachable. Returns a list of issues [{kind, id, to?}] — pure (no UI strings), so it's
# unit-tested and the builder formats its own user-facing messages. Kinds:
#   "no_start"    — start is empty or not a node (graph non-empty)
#   "dangling"    — node `id` has an out-edge whose target `to` is not a node
#   "cycle"       — node `id` is closed onto by a back-edge (it participates in a loop)
#   "unreachable" — node `id` can't be reached from start (it would never play)
static func validate_graph(graph: Dictionary, finish_id: String = "") -> Array:
	var issues: Array = []
	var nodes: Dictionary = graph.get("nodes", {})
	if nodes.is_empty():
		return issues  # "no rounds" is handled separately; nothing structural to check
	var start: String = str(graph.get("start", ""))
	var start_ok: bool = start != "" and nodes.has(start)
	if not start_ok:
		issues.append({"kind": "no_start", "id": start})
	# Dangling out-edges (a non-empty target that isn't a node).
	for id: String in nodes:
		for e: Dictionary in (nodes[id] as Dictionary).get("out", []):
			var to: String = str(e.get("to", ""))
			if to != "" and not nodes.has(to):
				issues.append({"kind": "dangling", "id": id, "to": to})
	# Cycles (DFS three-colouring; report each node a back-edge closes onto).
	for id: String in _find_cycle_nodes(graph):
		issues.append({"kind": "cycle", "id": id})
	# Unreachable nodes (only meaningful with a valid start).
	if start_ok:
		var reach: Dictionary = reachable_ids(graph, start)
		# The designated finish/aftercare node lives off the main graph — reachable only via the FINISH
		# button — so treat it (and anything it leads to) as reachable rather than flagging an island.
		if finish_id != "" and nodes.has(finish_id):
			for id: String in reachable_ids(graph, finish_id):
				reach[id] = true
		for id: String in nodes:
			if not reach.has(id):
				issues.append({"kind": "unreachable", "id": id})
	return issues


# The set of node ids that a back-edge closes onto — i.e. nodes that participate in a cycle.
# Standard DFS three-colouring (gray = on the current DFS stack). Empty for a DAG.
static func _find_cycle_nodes(graph: Dictionary) -> Dictionary:
	var color: Dictionary = {}  # id -> 1 gray (on stack) · 2 black (finished)
	var found: Dictionary = {}
	for id: String in graph.get("nodes", {}):
		if not color.has(id):
			_cycle_dfs(graph, id, color, found)
	return found


static func _cycle_dfs(graph: Dictionary, id: String, color: Dictionary, found: Dictionary) -> void:
	color[id] = 1
	for e: Dictionary in out_edges(graph, id):
		var to: String = str(e.get("to", ""))
		if to == "" or not (graph.get("nodes", {}) as Dictionary).has(to):
			continue
		if color.get(to, 0) == 1:
			found[to] = true  # back-edge onto a node still on the stack → cycle
		elif not color.has(to):
			_cycle_dfs(graph, to, color, found)
	color[id] = 2


# Longest count of `round` nodes along any path from `from_id` to an end (inclusive of
# `from_id` if it is a round). DAG-only, so the memoised DFS terminates. Feeds the
# trajectory-relative progress estimate (rounds_done + longest_round_path(current)).
static func longest_round_path(graph: Dictionary, from_id: String) -> int:
	return _longest_round_path(graph, from_id, {}, {})


# `memo` caches results; `seen` guards against a malformed (non-DAG) input so a stray
# back-edge can't spin forever. Both are owned by the public entry point above.
static func _longest_round_path(
	graph: Dictionary, from_id: String, memo: Dictionary, seen: Dictionary
) -> int:
	if from_id == "" or seen.has(from_id):
		return 0
	if memo.has(from_id):
		return memo[from_id]
	seen[from_id] = true
	var here: int = 1 if (node(graph, from_id) as Dictionary).get("type", "") == "round" else 0
	var best_rest: int = 0
	for e: Dictionary in out_edges(graph, from_id):
		best_rest = maxi(best_rest, _longest_round_path(graph, str(e.get("to", "")), memo, seen))
	seen.erase(from_id)
	var total: int = here + best_rest
	memo[from_id] = total
	return total


# Max number of nodes from the `targets` set ({id: true}) on any single path from `from_id` to a leaf.
# Same memoised DFS as longest_round_path (a fork counts only its worst branch, since one run takes
# one branch). Used to flag a no-repeat pool used more times on a run-path than it has clips. `seen`
# guards a malformed cyclic input.
static func max_nodes_on_path(graph: Dictionary, from_id: String, targets: Dictionary) -> int:
	return _max_nodes_on_path(graph, from_id, targets, {}, {})


static func _max_nodes_on_path(
	graph: Dictionary, from_id: String, targets: Dictionary, memo: Dictionary, seen: Dictionary
) -> int:
	if from_id == "" or seen.has(from_id):
		return 0
	if memo.has(from_id):
		return memo[from_id]
	seen[from_id] = true
	var here: int = 1 if targets.has(from_id) else 0
	var best_rest: int = 0
	for e: Dictionary in out_edges(graph, from_id):
		best_rest = maxi(
			best_rest, _max_nodes_on_path(graph, str(e.get("to", "")), targets, memo, seen)
		)
	seen.erase(from_id)
	var total: int = here + best_rest
	memo[from_id] = total
	return total


# ── Serialization (graph ↔ journey.json) ─────────────────────────────────────
#
# The in-memory graph is already pure JSON-shaped data, so serialization is mostly an
# envelope plus a nodes-dict ⇄ array conversion (the array keeps git diffs stable and
# the node id inline). The journey.json shape is:
#   { ...PascalCase meta..., "Format": 2, "Start": <id>, "Nodes": [ {id,type,data,out}, … ] }
#
# Paths in `data` are stored RELATIVE (authoring representation); JourneyScanner.parse_graph
# resolves them to absolute on read via resolve_paths(). to_json assumes a relative-path
# (authoring) graph — never serialize a runtime graph whose paths are already absolute.

const FORMAT_GRAPH := 2  # journey.json "Format" marker for the graph (post-tree) schema.


# Serializes the graph into the journey.json node block ({Format, Start, Nodes}). The
# caller merges journey-level meta (Name/Author/Tags/MapEnabled/…) around it.
static func to_json(graph: Dictionary) -> Dictionary:
	var nodes_arr: Array = []
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		var entry: Dictionary = {
			"id": id,
			"type": n.get("type", ""),
			"data": n.get("data", {}),
			"out": n.get("out", []),
		}
		# Editor canvas position (graph builder), stored as [x, y]. Absent for a graph that
		# was never laid out (e.g. a freshly migrated runtime graph the builder hasn't seeded).
		if n.has("pos"):
			var p: Vector2 = n["pos"]
			entry["pos"] = [p.x, p.y]
		nodes_arr.append(entry)
	return {"Format": FORMAT_GRAPH, "Start": graph.get("start", ""), "Nodes": nodes_arr}


# Rebuilds the in-memory graph from a parsed journey.json dict that carries "Nodes".
# Structural only — paths stay as stored; call resolve_paths() to make them absolute.
static func from_json(data: Dictionary) -> Dictionary:
	var nodes: Dictionary = {}
	for raw: Dictionary in data.get("Nodes", []):
		var node: Dictionary = {
			"type": str(raw.get("type", "")),
			"data": raw.get("data", {}),
			"out": raw.get("out", []),
		}
		# Restore editor canvas position when present (see to_json).
		if raw.has("pos"):
			var p: Array = raw["pos"]
			if p.size() >= 2:
				node["pos"] = Vector2(float(p[0]), float(p[1]))
		nodes[str(raw.get("id", ""))] = node
	var graph: Dictionary = {"start": str(data.get("Start", "")), "nodes": nodes}
	_migrate_checkpoint_flags(graph)
	return graph


# Converts the RETIRED per-round `is_checkpoint` flag into standalone checkpoint nodes. Runs on
# every load (from_json + build_graph), so it covers both the builder and the runtime with one
# implementation, and it's idempotent — a journey with no flagged rounds is untouched.
#
# For each flagged round R: mint a checkpoint node C, reroute every edge that pointed AT R so it
# points at C instead, then wire C → R. The player now hits the save banner (C) immediately
# before the round (R), preserving the old "save at the start of this round" semantics. If R was
# the start node, C becomes the new start. Handles fork rejoins and multiple inbound edges
# uniformly, because it rewires by target id.
static func _migrate_checkpoint_flags(graph: Dictionary) -> void:
	var nodes: Dictionary = graph.get("nodes", {})
	# Snapshot the flagged round ids first — the loop below grows `nodes`.
	var flagged: Array = []
	for id: String in nodes:
		var n: Dictionary = nodes[id]
		var data: Dictionary = n.get("data", {})
		if str(n.get("type", "")) == "round" and bool(data.get("is_checkpoint", false)):
			flagged.append(id)

	for round_id: String in flagged:
		var round_node: Dictionary = nodes[round_id]
		# DETERMINISTIC id (derived from the round it guards), NOT a random one: this migration re-runs on
		# every load of a not-yet-re-saved legacy journey, so a random id would differ each time — and a
		# Save & Quit made at the checkpoint would never match on resume (current_node not in _nodes →
		# LoadFromSave resets to the journey start, losing the player's place). "cp_" + round_id is stable
		# and can't collide with author ids (which are "n_<hex>").
		var cp_id: String = "cp_" + round_id
		# Reroute inbound edges (from any node) BEFORE adding C → R, so the new edge isn't caught.
		for other_id: String in nodes:
			for e: Dictionary in (nodes[other_id] as Dictionary).get("out", []):
				if str(e.get("to", "")) == round_id:
					e["to"] = cp_id
		var cp_node: Dictionary = {
			"type": "checkpoint",
			"data": {"name": ""},
			"out": [{"to": round_id}],
		}
		# Place C up-and-left of R so it reads as the step before it; the author can re-arrange.
		if round_node.has("pos"):
			cp_node["pos"] = (round_node["pos"] as Vector2) + Vector2(-40.0, -150.0)
		nodes[cp_id] = cp_node
		if str(graph.get("start", "")) == round_id:
			graph["start"] = cp_id
		(round_node.get("data", {}) as Dictionary).erase("is_checkpoint")


# True when a parsed journey.json is already the graph format (vs. the legacy tree).
static func is_graph_json(data: Dictionary) -> bool:
	return data.has("Nodes") or int(data.get("Format", 0)) >= FORMAT_GRAPH


# Resolves every node's stored-relative media paths to absolute (base = the journey
# folder), in place. Mirrors the field set JourneyScanner.parse_journey resolves, so a
# graph read from disk matches a migrated legacy graph (both absolute).
static func resolve_paths(graph: Dictionary, base: String) -> void:
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		match n.get("type", ""):
			"round":
				_resolve_round_paths(n.get("data", {}), base)
			"storyboard":
				_resolve_storyboard_paths(n.get("data", {}), base)
			"fork":
				for e: Dictionary in n.get("out", []):
					e["image_path"] = _abs(str(e.get("image_path", "")), base)
				var fd: Dictionary = n.get("data", {})
				if fd.has("audio"):
					fd["audio"] = _abs(str(fd.get("audio", "")), base)


static func _resolve_round_paths(d: Dictionary, base: String) -> void:
	d["funscript_path"] = _abs(str(d.get("funscript_path", "")), base)
	d["video_path"] = _abs(str(d.get("video_path", "")), base)
	d["boss_image"] = _abs(str(d.get("boss_image", "")), base)
	_resolve_channels(d.get("axis_scripts", {}), base)
	_resolve_channels(d.get("vib_scripts", {}), base)
	# Pool round: each encounter entry carries its own media set — resolve them too (incl. a
	# boss entry's intro image).
	for entry: Dictionary in d.get("pool_entries", []):
		entry["funscript_path"] = _abs(str(entry.get("funscript_path", "")), base)
		entry["video_path"] = _abs(str(entry.get("video_path", "")), base)
		entry["boss_image"] = _abs(str(entry.get("boss_image", "")), base)
		_resolve_channels(entry.get("axis_scripts", {}), base)
		_resolve_channels(entry.get("vib_scripts", {}), base)


# Resolves every value of a {channel: rel} media map to absolute, in place.
static func _resolve_channels(channels: Dictionary, base: String) -> void:
	for k: String in channels:
		channels[k] = _abs(str(channels[k]), base)


static func _resolve_storyboard_paths(d: Dictionary, base: String) -> void:
	d["image"] = _abs(str(d.get("image", "")), base)
	if d.has("bgm"):
		d["bgm"] = _abs(str(d.get("bgm", "")), base)
	for line: Dictionary in d.get("lines", []):
		line["image"] = _abs(str(line.get("image", "")), base)
		if line.has("audio"):
			line["audio"] = _abs(str(line.get("audio", "")), base)


# Prepends the journey base to a non-empty relative path; "" stays "".
static func _abs(rel: String, base: String) -> String:
	return (base + "/" + rel) if rel != "" else ""
