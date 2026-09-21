extends GdUnitTestSuite

# JourneyExtract: the pure "extract to rendition" graph surgery — the inverse of JourneyCompose. Selected
# nodes move into an overlay delta; the base's entry points turn back into anchors (regular → ending,
# fork choice → overlay choice). Verifies the split, the break-loudly guards, fork index remapping, and
# that extract-then-compose round-trips the structure. No autoloads / IO.


# start → a → b → c, a straight chain.
func _chain() -> Dictionary:
	return {
		"start": "a",
		"nodes":
		{
			"a": {"type": "round", "data": {}, "out": [{"to": "b"}]},
			"b": {"type": "round", "data": {}, "out": [{"to": "c"}]},
			"c": {"type": "round", "data": {}, "out": []},
		},
	}


# start "s" → fork "f" with three choices → a / b / c (each a terminal round).
func _fork_graph() -> Dictionary:
	return {
		"start": "f",
		"nodes":
		{
			"f":
			{
				"type": "fork",
				"data": {"default_path": 2, "timeout_path": 1},
				"out":
				[{"to": "a", "name": "A"}, {"to": "b", "name": "B"}, {"to": "c", "name": "C"}],
			},
			"a": {"type": "round", "data": {}, "out": []},
			"b": {"type": "round", "data": {}, "out": []},
			"c": {"type": "round", "data": {}, "out": []},
		},
	}


# ── Regular (ending-extend) extraction ────────────────────────────────────────


func test_extract_tail_turns_base_node_into_ending() -> void:
	# Pull the tail {c} off the chain: b loses its forward edge (becomes an ending) and the rendition
	# reattaches c via an ending-extend anchor.
	var out := JourneyExtract.extract_rendition(_chain(), ["c"])
	assert_array(out["errors"]).is_empty()
	assert_int((out["base"]["nodes"]["b"]["out"] as Array).size()).is_equal(0)  # b now ends
	assert_bool((out["base"]["nodes"] as Dictionary).has("c")).is_false()  # c left the base
	assert_bool((out["rendition"]["nodes"] as Dictionary).has("c")).is_true()
	var anchors: Array = out["rendition"]["anchors"]
	assert_int(anchors.size()).is_equal(1)
	assert_str(str((anchors[0] as Dictionary)["anchor"])).is_equal("b")
	assert_str(str(((anchors[0] as Dictionary)["edge"] as Dictionary)["to"])).is_equal("c")


func test_extract_then_compose_round_trips_a_tail() -> void:
	# The strong property: extracting a tail and composing it back reproduces the original edge.
	var out := JourneyExtract.extract_rendition(_chain(), ["b", "c"])
	assert_array(out["errors"]).is_empty()
	var composed := JourneyCompose.compose_graph(out["base"], out["rendition"])
	assert_array(composed["errors"]).is_empty()
	# a → b restored, and b, c are back in the merged graph.
	assert_str(str((composed["graph"]["nodes"]["a"]["out"][0] as Dictionary)["to"])).is_equal("b")
	assert_bool((composed["graph"]["nodes"] as Dictionary).has("b")).is_true()
	assert_bool((composed["graph"]["nodes"] as Dictionary).has("c")).is_true()


# ── Fork (overlay-choice) extraction ──────────────────────────────────────────


func test_extract_fork_choice_becomes_overlay_choice() -> void:
	# Pull {c} (choice 3) off the fork: the base fork drops to 2 choices and the extracted choice becomes
	# an overlay-choice anchor carrying its full config (its name here).
	var out := JourneyExtract.extract_rendition(_fork_graph(), ["c"])
	assert_array(out["errors"]).is_empty()
	var f_out: Array = out["base"]["nodes"]["f"]["out"]
	assert_int(f_out.size()).is_equal(2)  # A, B kept
	var anchors: Array = out["rendition"]["anchors"]
	assert_int(anchors.size()).is_equal(1)
	assert_str(str((anchors[0] as Dictionary)["anchor"])).is_equal("f")
	var edge: Dictionary = (anchors[0] as Dictionary)["edge"]
	assert_str(str(edge["to"])).is_equal("c")
	assert_str(str(edge["name"])).is_equal("C")  # the choice's config travels to the overlay


func test_extract_fork_remaps_default_and_timeout_paths() -> void:
	# Extracting choice 0 (A) shifts B,C down one: default_path 2 → 1, timeout_path 1 → 0.
	var out := JourneyExtract.extract_rendition(_fork_graph(), ["a"])
	assert_array(out["errors"]).is_empty()
	var data: Dictionary = out["base"]["nodes"]["f"]["data"]
	assert_int(int(data["default_path"])).is_equal(1)
	assert_int(int(data["timeout_path"])).is_equal(0)


func test_extract_fork_index_pointing_at_removed_choice_resets() -> void:
	# default_path points AT the extracted choice (C, index 2) → resets to 0; timeout (also removed's
	# neighbour) stays valid. Here we extract C, so default_path 2 is the removed one → 0.
	var out := JourneyExtract.extract_rendition(_fork_graph(), ["c"])
	assert_array(out["errors"]).is_empty()
	var data: Dictionary = out["base"]["nodes"]["f"]["data"]
	assert_int(int(data["default_path"])).is_equal(0)  # pointed at the removed choice → safe default
	assert_int(int(data["timeout_path"])).is_equal(1)  # index 1 (B) survived unshifted


func test_extract_fork_underflow_breaks_loudly() -> void:
	# A 2-choice fork can't spare a choice — extracting one would leave it invalid.
	var g := {
		"start": "f",
		"nodes":
		{
			"f": {"type": "fork", "data": {}, "out": [{"to": "a"}, {"to": "b"}]},
			"a": {"type": "round", "data": {}, "out": []},
			"b": {"type": "round", "data": {}, "out": []},
		},
	}
	var out := JourneyExtract.extract_rendition(g, ["b"])
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("fork_underflow")


# ── Exit edges (rendition → base) survive ─────────────────────────────────────


func test_exit_edge_back_into_base_is_kept_on_the_rendition_node() -> void:
	# a → b → c, extract only {b}. b's exit edge to c (a kept node) rides along on the rendition node, so
	# composing reconnects a → b → c.
	var out := JourneyExtract.extract_rendition(_chain(), ["b"])
	assert_array(out["errors"]).is_empty()
	assert_str(str((out["rendition"]["nodes"]["b"]["out"][0] as Dictionary)["to"])).is_equal("c")
	var composed := JourneyCompose.compose_graph(out["base"], out["rendition"])
	assert_array(composed["errors"]).is_empty()
	assert_str(str((composed["graph"]["nodes"]["b"]["out"][0] as Dictionary)["to"])).is_equal("c")


# ── Break-loudly guards ───────────────────────────────────────────────────────


func test_selecting_start_is_rejected() -> void:
	(
		assert_str(
			str(
				(JourneyExtract.extract_rendition(_chain(), ["a"])["errors"][0] as Dictionary)["kind"]
			)
		)
		. is_equal("selects_start")
	)


func test_empty_selection_is_rejected() -> void:
	(
		assert_str(
			str((JourneyExtract.extract_rendition(_chain(), [])["errors"][0] as Dictionary)["kind"])
		)
		. is_equal("empty_selection")
	)


func test_missing_node_is_rejected() -> void:
	(
		assert_str(
			str(
				(JourneyExtract.extract_rendition(_chain(), ["ghost"])["errors"][0] as Dictionary)["kind"]
			)
		)
		. is_equal("missing_node")
	)


func test_selection_with_no_base_entry_is_rejected() -> void:
	# An island {a,b,c} where nothing outside points in — but start is inside, so it trips selects_start
	# first. Use a graph with a separate unreachable island to isolate no_anchor.
	var g := {
		"start": "s",
		"nodes":
		{
			"s": {"type": "round", "data": {}, "out": []},
			"x": {"type": "round", "data": {}, "out": [{"to": "y"}]},  # island, unreachable from s
			"y": {"type": "round", "data": {}, "out": []},
		},
	}
	var out := JourneyExtract.extract_rendition(g, ["x", "y"])
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("no_anchor")


# ── Notes and frames travel with the nodes they annotate ─────────────────────
# Extracting a branch used to leave its sticky notes and group frames behind on the base canvas,
# pointing at nothing. The rule (split_annotations) is the same in both directions — extract and
# merge back — so it lives here, pure, with the canvas passing in what each frame wraps.

const _FRAME_ALL_MOVED := {"rect": Rect2(0, 0, 400, 300), "label": "Chapter"}
const _FRAME_MIXED := {"rect": Rect2(1000, 0, 400, 300), "label": "Both"}
const _FRAME_EMPTY := {"rect": Rect2(2000, 0, 100, 100), "label": "Todo"}


func _split(moved: Array) -> Dictionary:
	var comments := [
		{"pos": Vector2(50, 50), "text": "pinned to x", "node_id": "x"},
		{"pos": Vector2(50, 50), "text": "pinned to k", "node_id": "k"},
		{"pos": Vector2(100, 100), "text": "loose, inside the moving frame"},
		{"pos": Vector2(1100, 100), "text": "loose, inside the mixed frame"},
		{"pos": Vector2(5000, 5000), "text": "loose, nowhere"},
	]
	var groups := [_FRAME_ALL_MOVED, _FRAME_MIXED, _FRAME_EMPTY]
	var members := [["x", "y"], ["x", "k"], []]
	var m: Dictionary = {}
	for id: String in moved:
		m[id] = true
	return JourneyExtract.split_annotations(comments, groups, m, members)


func test_pinned_notes_follow_their_node() -> void:
	var out := _split(["x", "y"])
	var moved_texts: Array = (out["moved"]["comments"] as Array).map(
		func(c: Dictionary) -> String: return str(c["text"])
	)
	assert_bool(moved_texts.has("pinned to x")).is_true()
	assert_bool(moved_texts.has("pinned to k")).is_false()


func test_a_frame_moves_only_when_everything_inside_it_moved() -> void:
	var out := _split(["x", "y"])
	var moved_labels: Array = (out["moved"]["groups"] as Array).map(
		func(g: Dictionary) -> String: return str(g["label"])
	)
	var kept_labels: Array = (out["kept"]["groups"] as Array).map(
		func(g: Dictionary) -> String: return str(g["label"])
	)
	assert_array(moved_labels).contains_exactly(["Chapter"])
	assert_array(kept_labels).contains_exactly_in_any_order(["Both", "Todo"])  # mixed and empty stay


func test_loose_notes_go_with_a_moving_frame_and_otherwise_stay() -> void:
	var out := _split(["x", "y"])
	var moved_texts: Array = (out["moved"]["comments"] as Array).map(
		func(c: Dictionary) -> String: return str(c["text"])
	)
	var kept_texts: Array = (out["kept"]["comments"] as Array).map(
		func(c: Dictionary) -> String: return str(c["text"])
	)
	assert_bool(moved_texts.has("loose, inside the moving frame")).is_true()
	assert_bool(kept_texts.has("loose, inside the mixed frame")).is_true()
	assert_bool(kept_texts.has("loose, nowhere")).is_true()


func test_split_returns_copies_and_loses_nothing() -> void:
	var out := _split(["x", "y"])
	var total_comments: int = (
		(out["moved"]["comments"] as Array).size() + (out["kept"]["comments"] as Array).size()
	)
	var total_groups: int = (
		(out["moved"]["groups"] as Array).size() + (out["kept"]["groups"] as Array).size()
	)
	assert_int(total_comments).is_equal(5)
	assert_int(total_groups).is_equal(3)
	(out["moved"]["groups"][0] as Dictionary)["label"] = "changed"
	assert_str(str(_FRAME_ALL_MOVED["label"])).is_equal("Chapter")


# ── Extracting from inside a rendition ───────────────────────────────────────
# A fork choice marked `_slot` is a base fork's open slot that the current rendition filled. The slot is
# the base's, so it is reopened rather than removed, and the anchor carries the slot index so the child
# fills the very same slot; a rendition's own `_anchor` marker on an ordinary choice is stripped.


func test_extracting_a_slot_filled_choice_reopens_the_slot_and_keeps_the_index() -> void:
	var g := {
		"start": "f",
		"nodes":
		{
			"f":
			{
				"type": "fork",
				"data": {"default_path": 1, "timeout_path": 1},
				"out":
				[
					{"to": "a", "name": "A"},
					{"to": "x", "name": "Open", "_anchor": true, "_slot": 1},
				],
			},
			"a": {"type": "round", "data": {}, "out": []},
			"x": {"type": "round", "data": {}, "out": []},
		},
	}
	var out := JourneyExtract.extract_rendition(g, ["x"])
	assert_array(out["errors"]).is_empty()
	var fork: Dictionary = out["base"]["nodes"]["f"]
	assert_int((fork["out"] as Array).size()).is_equal(2)  # the slot stays, reopened
	assert_str(str((fork["out"][1] as Dictionary)["to"])).is_equal("")
	assert_bool((fork["out"][1] as Dictionary).has("_slot")).is_false()
	assert_int(int(fork["data"]["default_path"])).is_equal(1)  # nothing shifted
	var anchor: Dictionary = out["rendition"]["anchors"][0]
	assert_int(int(anchor["slot"])).is_equal(1)
	assert_str(str((anchor["edge"] as Dictionary)["to"])).is_equal("x")


func test_extracting_an_anchored_choice_strips_the_rendition_marker() -> void:
	var g := {
		"start": "f",
		"nodes":
		{
			"f":
			{
				"type": "fork",
				"data": {},
				"out":
				[
					{"to": "a", "name": "A"},
					{"to": "b", "name": "B"},
					{"to": "x", "name": "Extra", "_anchor": true},
				],
			},
			"a": {"type": "round", "data": {}, "out": []},
			"b": {"type": "round", "data": {}, "out": []},
			"x": {"type": "round", "data": {}, "out": []},
		},
	}
	var out := JourneyExtract.extract_rendition(g, ["x"])
	assert_array(out["errors"]).is_empty()
	var edge: Dictionary = (out["rendition"]["anchors"][0] as Dictionary)["edge"]
	assert_bool(edge.has("_anchor")).is_false()
	assert_str(str(edge["name"])).is_equal("Extra")
