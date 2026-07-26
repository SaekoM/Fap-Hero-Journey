extends GdUnitTestSuite

# JourneyGraph migration (tree → DAG). The cutover hinges on this being behaviour-
# preserving: walking the migrated graph must reproduce exactly what the old tree
# runtime (GameState.BuildSequence + ResolveFork + fork_end) produced — same item
# order, and every fork path rejoining at the node that followed the fork. Each fork's
# implicit rejoin becomes an EXPLICIT edge (path tail → post-fork node), which is what
# later lets authors rewire it to skip/converge.


func _round(order: int, name: String) -> Dictionary:
	return {"order": order, "name": name}


func _fork(after: int, title: String, paths: Array) -> Dictionary:
	return {"after_order": after, "title": title, "resolution": "choice", "paths": paths}


func _path(name: String, rounds: Array, forks: Array = []) -> Dictionary:
	return {"name": name, "rounds": rounds, "shops": [], "storyboards": [], "forks": forks}


# A round A, a 2-path fork after it (P0 = [X, Y], P1 = [Z]), then round B. Both paths
# must rejoin at B — the canonical tree shape.
func _fork_journey() -> Dictionary:
	return {
		"rounds": [_round(0, "A"), _round(1, "B")],
		"shops": [],
		"storyboards": [],
		"forks":
		[
			_fork(
				0,
				"F",
				[
					_path("P0", [_round(0, "X"), _round(1, "Y")]),
					_path("P1", [_round(0, "Z")]),
				]
			)
		],
	}


# Walks the graph from start, taking `fork_choices[i]` at the i-th fork reached.
# Returns a label per node: "<type>:<name/title>" (forks as "fork:<title>").
func _walk(graph: Dictionary, fork_choices: Array) -> Array:
	var seq: Array = []
	var id: String = graph["start"]
	var bi: int = 0
	var guard: int = 0
	while id != "" and guard < 200:
		guard += 1
		var n: Dictionary = JourneyGraph.node(graph, id)
		if n.is_empty():
			break
		if n["type"] == JourneyGraph.FORK_TYPE:
			seq.append("fork:%s" % n["data"].get("title", ""))
			var edges: Array = n["out"]
			var idx: int = int(fork_choices[bi]) if bi < fork_choices.size() else 0
			bi += 1
			id = str(edges[idx]["to"]) if idx < edges.size() else ""
		else:
			seq.append("%s:%s" % [n["type"], n["data"].get("name", n["data"].get("title", ""))])
			var out: Array = n["out"]
			id = str(out[0]["to"]) if not out.is_empty() else ""
	return seq


func _first_fork(graph: Dictionary) -> Dictionary:
	for id: String in graph["nodes"]:
		if (graph["nodes"][id] as Dictionary)["type"] == JourneyGraph.FORK_TYPE:
			return graph["nodes"][id]
	return {}


# Node id of the round named `name` (ids are positional; tests look up by content).
func _id_of(graph: Dictionary, name: String) -> String:
	for id: String in graph["nodes"]:
		var n: Dictionary = graph["nodes"][id]
		if n["type"] == "round" and n["data"].get("name", "") == name:
			return id
	return ""


func _depth_of(graph: Dictionary, name: String) -> int:
	var id: String = _id_of(graph, name)
	return int((graph["nodes"][id] as Dictionary).get("depth", -1)) if id != "" else -1


# Each path plays its own rounds, then BOTH rejoin at B (the explicit rejoin edge).
func test_migration_walks_each_path_and_rejoins() -> void:
	var g := JourneyGraph.build_graph(_fork_journey())
	assert_array(_walk(g, [0])).is_equal(["round:A", "fork:F", "round:X", "round:Y", "round:B"])
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:B"])


# A plain linear journey maps to a simple chain.
func test_linear_journey() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A"), _round(1, "B"), _round(2, "C")],
				"shops": [],
				"storyboards": [],
				"forks": [],
			}
		)
	)
	assert_array(_walk(g, [])).is_equal(["round:A", "round:B", "round:C"])
	assert_str(g["start"]).is_not_equal("")


# Interleave: a shop authored between two rounds sorts between them (key after*3+1).
func test_shop_interleave() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A"), _round(1, "B")],
				"shops": [{"after_order": 0, "title": "S"}],
				"storyboards": [],
				"forks": [],
			}
		)
	)
	assert_array(_walk(g, [])).is_equal(["round:A", "shop:S", "round:B"])


# A fork as the LAST item: its paths run out at an end (no rejoin node exists).
func test_fork_last_paths_reach_end() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A")],
				"shops": [],
				"storyboards": [],
				"forks":
				[_fork(0, "F", [_path("P0", [_round(0, "X")]), _path("P1", [_round(0, "Z")])])],
			}
		)
	)
	assert_array(_walk(g, [0])).is_equal(["round:A", "fork:F", "round:X"])
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:F", "round:Z"])


# An empty path edge points straight at the rejoin (no wasted node).
func test_empty_path_goes_straight_to_rejoin() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A"), _round(1, "B")],
				"shops": [],
				"storyboards": [],
				"forks": [_fork(0, "F", [_path("P0", []), _path("P1", [_round(0, "Z")])])],
			}
		)
	)
	assert_array(_walk(g, [0])).is_equal(["round:A", "fork:F", "round:B"])
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:B"])


# Fork meta lands on the node; per-choice config lands on the edges.
func test_fork_meta_and_edge_config() -> void:
	var fork := _fork(
		0,
		"F",
		[
			{
				"name": "Pay",
				"rounds": [_round(0, "X")],
				"shops": [],
				"storyboards": [],
				"forks": [],
				"weight": 3,
				"threshold": 50,
				"required_item": "key",
				"cost": 20,
				"image_path": "media/x.png"
			},
			_path("Free", [_round(0, "Z")]),
		]
	)
	fork["resolution"] = "sacrifice"
	fork["cond_metric"] = "coins"
	fork["default_path"] = 1
	var g := JourneyGraph.build_graph(
		{"rounds": [_round(0, "A")], "shops": [], "storyboards": [], "forks": [fork]}
	)
	var b := _first_fork(g)
	assert_str(b["data"]["resolution"]).is_equal("sacrifice")
	assert_str(b["data"]["cond_metric"]).is_equal("coins")
	assert_int(b["data"]["default_path"]).is_equal(1)
	var e0: Dictionary = b["out"][0]
	assert_str(e0["name"]).is_equal("Pay")
	assert_int(e0["weight"]).is_equal(3)
	assert_int(e0["threshold"]).is_equal(50)
	assert_str(e0["required_item"]).is_equal("key")
	assert_int(e0["cost"]).is_equal(20)
	assert_str(e0["image_path"]).is_equal("media/x.png")


# Trajectory-relative progress basis: longest round-count to any end. For _fork_journey
# that's A → X → Y → B = 4 (the P0 fork), not the shorter P1 (A,Z,B = 3).
func test_longest_round_path() -> void:
	var g := JourneyGraph.build_graph(_fork_journey())
	assert_int(JourneyGraph.longest_round_path(g, g["start"])).is_equal(4)


# Nested fork inside a path still rejoins correctly (depth-2 tree → graph).
func test_nested_fork() -> void:
	var inner := _fork(0, "Inner", [_path("Q0", [_round(0, "M")])])
	var outer := _fork(
		0, "Outer", [_path("P0", [_round(0, "X")], [inner]), _path("P1", [_round(0, "Z")])]
	)
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A"), _round(1, "B")],
				"shops": [],
				"storyboards": [],
				"forks": [outer],
			}
		)
	)
	# Outer P0 → X, then the inner fork → Q0 = [M], rejoining the inner at B, then B.
	assert_array(_walk(g, [0, 0])).is_equal(
		["round:A", "fork:Outer", "round:X", "fork:Inner", "round:M", "round:B"]
	)
	# Outer P1 → Z → B.
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:Outer", "round:Z", "round:B"])


# A redirect points a node past its default successor — a skip ahead.
func test_redirect_skips_ahead() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A"), _round(1, "B"), _round(2, "C")],
				"shops": [],
				"storyboards": [],
				"forks": [],
			}
		)
	)
	JourneyGraph.apply_redirects(g, {_id_of(g, "A"): _id_of(g, "C")})
	assert_array(_walk(g, [])).is_equal(["round:A", "round:C"])  # B skipped


# A redirect to "" ends the journey early.
func test_redirect_to_end() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A"), _round(1, "B")],
				"shops": [],
				"storyboards": [],
				"forks": [],
			}
		)
	)
	JourneyGraph.apply_redirects(g, {_id_of(g, "A"): ""})
	assert_array(_walk(g, [])).is_equal(["round:A"])


# Both fork paths skip the default rejoin (B) and converge directly onto C.
func test_redirect_converges_paths() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A"), _round(1, "B"), _round(2, "C")],
				"shops": [],
				"storyboards": [],
				"forks":
				[_fork(0, "F", [_path("P0", [_round(0, "X")]), _path("P1", [_round(0, "Z")])])],
			}
		)
	)
	var c := _id_of(g, "C")
	JourneyGraph.apply_redirects(g, {_id_of(g, "X"): c, _id_of(g, "Z"): c})  # both skip B → C
	assert_array(_walk(g, [0])).is_equal(["round:A", "fork:F", "round:X", "round:C"])
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:C"])


# Nodes carry their tree-nesting depth (reproduces the old fork_depth for the end screen).
func test_node_depth_tracks_nesting() -> void:
	var inner := _fork(0, "Inner", [_path("Q0", [_round(0, "M")])])
	var outer := _fork(0, "Outer", [_path("P0", [_round(0, "X")], [inner])])
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A")],
				"shops": [],
				"storyboards": [],
				"forks": [outer],
			}
		)
	)
	assert_int(_depth_of(g, "A")).is_equal(0)  # top level
	assert_int(_depth_of(g, "X")).is_equal(1)  # inside outer's path
	assert_int(_depth_of(g, "M")).is_equal(2)  # inside inner's path


# ── Stable node ids (Phase 3 step 1) ────────────────────────────────────────
# An item's persistent node_id (authored, saved as "NodeId") becomes its graph node
# key, so ids survive a save — the anchor that lets redirect edges and Test-From-Here
# reference a node. Legacy items with none fall back to a positional mint.


# A round carrying a node_id keeps that exact id as its node key; edges still wire it.
func test_build_graph_honors_stored_node_id() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds":
				[
					{"order": 0, "name": "A", "node_id": "n_a"},
					{"order": 1, "name": "B", "node_id": "n_b"}
				],
				"shops": [],
				"storyboards": [],
				"forks": [],
			}
		)
	)
	assert_bool(g["nodes"].has("n_a")).is_true()
	assert_bool(g["nodes"].has("n_b")).is_true()
	assert_str(g["start"]).is_equal("n_a")
	assert_str(g["nodes"]["n_a"]["out"][0]["to"]).is_equal("n_b")
	assert_array(_walk(g, [])).is_equal(["round:A", "round:B"])  # wiring intact


# A fork and the rounds inside its paths all keep their stored ids.
func test_build_graph_honors_stored_ids_through_fork() -> void:
	var fork := _fork(
		0,
		"F",
		[
			{
				"name": "P0",
				"rounds": [{"order": 0, "name": "X", "node_id": "n_x"}],
				"shops": [],
				"storyboards": [],
				"forks": []
			},
			{
				"name": "P1",
				"rounds": [{"order": 0, "name": "Z", "node_id": "n_z"}],
				"shops": [],
				"storyboards": [],
				"forks": []
			},
		]
	)
	fork["node_id"] = "n_f"
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [{"order": 0, "name": "A", "node_id": "n_a"}],
				"shops": [],
				"storyboards": [],
				"forks": [fork],
			}
		)
	)
	assert_str(g["nodes"]["n_f"]["type"]).is_equal(JourneyGraph.FORK_TYPE)
	assert_bool(g["nodes"].has("n_x")).is_true()
	assert_bool(g["nodes"].has("n_z")).is_true()
	# Edges wire by the stored ids — walking each path lands on the right round.
	assert_array(_walk(g, [0])).is_equal(["round:A", "fork:F", "round:X"])
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:F", "round:Z"])


# A legacy item with no node_id still gets a non-empty (positional) id, so migration
# of journeys not yet re-saved keeps working unchanged.
func test_build_graph_mints_fallback_when_missing() -> void:
	var g := JourneyGraph.build_graph(_fork_journey())  # fixtures carry no node_id
	for id: String in g["nodes"]:
		assert_str(id).is_not_equal("")
	assert_array(_walk(g, [0])).is_equal(["round:A", "fork:F", "round:X", "round:Y", "round:B"])


# A corrupt save with a DUPLICATE stored id must not collapse two nodes into one —
# the collision falls back to a fresh id so neither round is lost.
func test_build_graph_guards_duplicate_ids() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds":
				[
					{"order": 0, "name": "A", "node_id": "dup"},
					{"order": 1, "name": "B", "node_id": "dup"}
				],
				"shops": [],
				"storyboards": [],
				"forks": [],
			}
		)
	)
	assert_int((g["nodes"] as Dictionary).size()).is_equal(2)  # both survived
	assert_array(_walk(g, [])).is_equal(["round:A", "round:B"])


# ── Graph editor: position seam (overhaul L1) ───────────────────────────────
# GraphLayout.seed_positions lays nodes out in layers by longest-path depth from start,
# non-overlapping — the initial placement a migrated journey opens with.
func test_seed_positions_layers_by_depth() -> void:
	# A, FORK(P0=[X], P1=[Z]), B  →  depths A=0, fork=1, X=Z=2, B=3 (longest path A,F,X/Z,B).
	var fork := _fork(
		0,
		"F",
		[
			{
				"name": "P0",
				"rounds": [{"order": 0, "name": "X", "node_id": "x"}],
				"shops": [],
				"storyboards": [],
				"forks": []
			},
			{
				"name": "P1",
				"rounds": [{"order": 0, "name": "Z", "node_id": "z"}],
				"shops": [],
				"storyboards": [],
				"forks": []
			},
		]
	)
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds":
				[
					{"order": 0, "name": "A", "node_id": "a"},
					{"order": 1, "name": "B", "node_id": "b"}
				],
				"shops": [],
				"storyboards": [],
				"forks": [fork],
			}
		)
	)
	GraphLayout.seed_positions(g)
	assert_float(g["nodes"]["a"]["pos"].y).is_less(g["nodes"]["b"]["pos"].y)  # rows follow flow depth
	assert_float(g["nodes"]["x"]["pos"].y).is_equal(g["nodes"]["z"]["pos"].y)  # siblings share a row
	assert_float(g["nodes"]["x"]["pos"].x).is_not_equal(g["nodes"]["z"]["pos"].x)  # …in different columns


# GraphLayout.auto_layout (Sugiyama "Arrange") layers by longest-path depth, keeps a row's nodes
# COL_W apart, and is deterministic (re-running yields identical positions).
func test_auto_layout_layers_and_no_overlap() -> void:
	var fork := _fork(
		0,
		"F",
		[
			{
				"name": "P0",
				"rounds": [{"order": 0, "name": "X", "node_id": "x"}],
				"shops": [],
				"storyboards": [],
				"forks": []
			},
			{
				"name": "P1",
				"rounds": [{"order": 0, "name": "Z", "node_id": "z"}],
				"shops": [],
				"storyboards": [],
				"forks": []
			},
		]
	)
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds":
				[
					{"order": 0, "name": "A", "node_id": "a"},
					{"order": 1, "name": "B", "node_id": "b"}
				],
				"shops": [],
				"storyboards": [],
				"forks": [fork],
			}
		)
	)
	GraphLayout.auto_layout(g)
	assert_float(g["nodes"]["a"]["pos"].y).is_less(g["nodes"]["x"]["pos"].y)  # rows follow flow depth
	assert_float(g["nodes"]["x"]["pos"].y).is_equal(g["nodes"]["z"]["pos"].y)  # siblings share a row
	assert_float(g["nodes"]["x"]["pos"].y).is_less(g["nodes"]["b"]["pos"].y)  # convergence sits below
	assert_float(absf(g["nodes"]["x"]["pos"].x - g["nodes"]["z"]["pos"].x)).is_greater_equal(
		GraphLayout.COL_W - 0.01
	)
	var px: float = g["nodes"]["x"]["pos"].x  # deterministic re-arrange
	GraphLayout.auto_layout(g)
	assert_float(g["nodes"]["x"]["pos"].x).is_equal(px)


# ── Catalogue preview reconstruction (detail-modal forks) ───────────────────
# parse_graph rebuilds an approximate nested tree from the graph so the JourneySelect
# detail modal shows the real fork structure (not a flat round list). The inverse of the
# migration walk: tree → build_graph → _graph_catalogue_sequence reproduces the fork.


# Names (or titles) of a rounds/paths list, for order-sensitive structure assertions.
func _names(items: Array) -> Array:
	var out: Array = []
	for it: Dictionary in items:
		out.append(it.get("name", it.get("title", "")))
	return out


# A reconverging fork rebuilds as round A → FORK(P0=[X,Y] / P1=[Z]) → round B, with B (the
# rejoin) placed exactly once at the top level and round numbers staying contiguous.
func test_catalogue_sequence_reconstructs_fork() -> void:
	var g := JourneyGraph.build_graph(_fork_journey())
	var seq := JourneyScanner._graph_catalogue_sequence(g)
	assert_array(_names(seq["rounds"])).is_equal(["A", "B"])  # B not duplicated into each path
	assert_int(seq["rounds"][0]["order"]).is_equal(0)
	assert_int(seq["rounds"][1]["order"]).is_equal(1)  # contiguous: the fork takes no number
	assert_int((seq["forks"] as Array).size()).is_equal(1)
	var fork: Dictionary = seq["forks"][0]
	assert_str(fork["title"]).is_equal("F")
	assert_int(fork["after_order"]).is_equal(0)  # anchored just after round A
	var paths: Array = fork["paths"]
	assert_array(_names(paths)).is_equal(["P0", "P1"])
	assert_array(_names(paths[0]["rounds"])).is_equal(["X", "Y"])
	assert_array(_names(paths[1]["rounds"])).is_equal(["Z"])


# A fork whose paths never reconverge (each runs to an end) still rebuilds with both paths;
# there is no post-fork continuation to place.
func test_catalogue_sequence_fork_without_rejoin() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A")],
				"shops": [],
				"storyboards": [],
				"forks":
				[_fork(0, "F", [_path("P0", [_round(0, "X")]), _path("P1", [_round(0, "Z")])])],
			}
		)
	)
	var seq := JourneyScanner._graph_catalogue_sequence(g)
	assert_array(_names(seq["rounds"])).is_equal(["A"])
	var paths: Array = (seq["forks"][0] as Dictionary)["paths"]
	assert_array(_names(paths[0]["rounds"])).is_equal(["X"])
	assert_array(_names(paths[1]["rounds"])).is_equal(["Z"])


# A shop authored between two rounds anchors after round A (after_order 0) without consuming a
# round number — B stays round 1, matching how the legacy nested preview numbers.
func test_catalogue_sequence_shop_keeps_numbering_contiguous() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds": [_round(0, "A"), _round(1, "B")],
				"shops": [{"after_order": 0, "title": "S"}],
				"storyboards": [],
				"forks": [],
			}
		)
	)
	var seq := JourneyScanner._graph_catalogue_sequence(g)
	assert_array(_names(seq["rounds"])).is_equal(["A", "B"])
	assert_int(seq["rounds"][1]["order"]).is_equal(1)  # not bumped to 2 by the shop
	assert_int((seq["shops"] as Array).size()).is_equal(1)
	assert_int(seq["shops"][0]["after_order"]).is_equal(0)


# Snapping to the grid is idempotent and lands on grid multiples.
func test_grid_snap() -> void:
	var snapped := GraphLayout.snap(Vector2(31.0, 7.0))
	assert_vector(snapped).is_equal(GraphLayout.snap(snapped))  # idempotent
	assert_float(fmod(snapped.x, GraphLayout.GRID)).is_equal(0.0)


# ── Structural validation (overhaul L4) ─────────────────────────────────────
# validate_graph catches the invalid graphs free-form authoring allows but the tree couldn't:
# missing start, edges to deleted nodes, cycles, and orphans. Pure, so it's fully unit-tested;
# the builder blocks saving on start/dangling/cycle (orphans are a normal mid-authoring state).


func _g(start: String, nodes: Dictionary) -> Dictionary:
	return {"start": start, "nodes": nodes}


func _n(type: String, outs: Array) -> Dictionary:
	var out: Array = []
	for t: String in outs:
		out.append({"to": t})
	return {"type": type, "data": {}, "out": out}


func _has_kind(graph: Dictionary, kind: String) -> bool:
	for i: Dictionary in JourneyGraph.validate_graph(graph):
		if i["kind"] == kind:
			return true
	return false


# A clean linear DAG and an empty graph both validate with no issues.
func test_validate_clean_dag_and_empty() -> void:
	var g := _g("a", {"a": _n("round", ["b"]), "b": _n("round", ["c"]), "c": _n("round", [])})
	assert_array(JourneyGraph.validate_graph(g)).is_empty()
	assert_array(JourneyGraph.validate_graph(_g("", {}))).is_empty()


# A back-edge (b → a) is flagged as a cycle.
func test_validate_flags_cycle() -> void:
	var g := _g("a", {"a": _n("round", ["b"]), "b": _n("round", ["a"])})
	assert_bool(_has_kind(g, "cycle")).is_true()


# An out-edge to a non-existent node is flagged dangling, naming the bad target.
func test_validate_flags_dangling() -> void:
	var g := _g("a", {"a": _n("round", ["ghost"])})
	var hit := false
	for i: Dictionary in JourneyGraph.validate_graph(g):
		if i["kind"] == "dangling" and i.get("to", "") == "ghost":
			hit = true
	assert_bool(hit).is_true()


# A start id that isn't a node is flagged (and suppresses the reachability pass).
func test_validate_flags_no_start() -> void:
	assert_bool(_has_kind(_g("missing", {"a": _n("round", [])}), "no_start")).is_true()


# An island node is flagged unreachable; the (reachable) start never is.
func test_validate_flags_unreachable_not_start() -> void:
	var g := _g("a", {"a": _n("round", []), "b": _n("round", [])})  # b has no in-edge
	var unreachable_ids: Array = []
	for i: Dictionary in JourneyGraph.validate_graph(g):
		if i["kind"] == "unreachable":
			unreachable_ids.append(i["id"])
	assert_bool(unreachable_ids.has("b")).is_true()
	assert_bool(unreachable_ids.has("a")).is_false()


# The designated finish/aftercare node lives off the main graph (reachable only via the FINISH button),
# so passing it as finish_id exempts it from the unreachable flag.
func test_validate_exempts_finish_node_from_unreachable() -> void:
	var g := _g("a", {"a": _n("round", []), "b": _n("storyboard", [])})  # b is an island
	var unreachable_ids: Array = []
	for i: Dictionary in JourneyGraph.validate_graph(g, "b"):
		if i["kind"] == "unreachable":
			unreachable_ids.append(i["id"])
	assert_bool(unreachable_ids.has("b")).is_false()  # exempt as the finish node


# type_ordinals numbers each node within its type in insertion order, so the "N" in a save error's
# "Storyboard N" is the same "N" GraphView draws on that node.
func test_type_ordinals_number_per_type_in_order() -> void:
	var nodes := {
		"a": _n("round", []),
		"b": _n("storyboard", []),
		"c": _n("round", []),
		"d": _n("storyboard", []),
		"e": _n("fork", []),
	}
	var ord: Dictionary = JourneyGraph.type_ordinals(nodes)
	assert_int(ord["a"]).is_equal(1)  # first round
	assert_int(ord["c"]).is_equal(2)  # second round
	assert_int(ord["b"]).is_equal(1)  # first storyboard
	assert_int(ord["d"]).is_equal(2)  # second storyboard
	assert_int(ord["e"]).is_equal(1)  # first fork


func test_type_ordinals_empty() -> void:
	assert_int((JourneyGraph.type_ordinals({}) as Dictionary).size()).is_equal(0)


# max_nodes_on_path counts target nodes on a single path; a linear chain sums them all.
func test_max_nodes_on_path_linear() -> void:
	var g := _g(
		"s",
		{
			"s": _n("round", ["a"]),
			"a": _n("round", ["b"]),
			"b": _n("round", ["c"]),
			"c": _n("round", []),
		}
	)
	assert_int(JourneyGraph.max_nodes_on_path(g, "s", {"a": true, "c": true})).is_equal(2)


# A fork counts only its worst (most-targets) branch — one run takes one branch.
func test_max_nodes_on_path_takes_worst_branch() -> void:
	var g := _g(
		"s",
		{
			"s": _n("fork", ["x", "y"]),  # branch1: x (1 target); branch2: y → z (2 targets)
			"x": _n("round", []),
			"y": _n("round", ["z"]),
			"z": _n("round", []),
		}
	)
	assert_int(JourneyGraph.max_nodes_on_path(g, "s", {"x": true, "y": true, "z": true})).is_equal(
		2
	)
	assert_int(JourneyGraph.max_nodes_on_path(g, "s", {"x": true})).is_equal(1)


func test_max_nodes_on_path_none_targeted() -> void:
	var g := _g("s", {"s": _n("round", ["a"]), "a": _n("round", [])})
	assert_int(JourneyGraph.max_nodes_on_path(g, "s", {})).is_equal(0)
