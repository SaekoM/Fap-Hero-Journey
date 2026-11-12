extends GdUnitTestSuite

# The names the builder's panels use for a node, such as a fork choice's LEADS TO. A node's id means nothing to
# an author, so no kind of node may fall back to it.

const LIBRARY: Array = [{"id": "safe", "name": "The Warden's Safe"}]


func _node(type: String, data: Dictionary = {}, to: String = "") -> Dictionary:
	return {"type": type, "data": data, "out": [{"to": to}] if to != "" else []}


func _label(nodes: Dictionary, id: String) -> String:
	return JourneyData.graph_node_label(nodes, id, LIBRARY)


func test_a_loop_start_names_the_node_it_loops_to() -> void:
	var nodes: Dictionary = {
		"start": _node("loop_start", {}, "r"),
		"r": _node("round", {"name": "Training"}),
	}
	assert_str(_label(nodes, "start")).is_equal("Loop to Round — Training")


func test_a_loop_start_with_nothing_after_it_says_so() -> void:
	assert_str(_label({"start": _node("loop_start")}, "start")).is_equal("Loop to (nothing yet)")
	var dangling: Dictionary = {"start": _node("loop_start", {}, "gone")}
	assert_str(_label(dangling, "start")).is_equal("Loop to (nothing yet)")


func test_a_loop_with_an_empty_body_still_reads() -> void:
	var nodes: Dictionary = {"start": _node("loop_start", {}, "end"), "end": _node("loop_end")}
	assert_str(_label(nodes, "start")).is_equal("Loop to Loop End")


func test_each_kind_of_node_has_a_readable_name() -> void:
	var nodes: Dictionary = {
		"r": _node("round", {"name": "One"}),
		"s": _node("shop", {"title": "Market"}),
		"b": _node("storyboard", {"name": "Intro"}),
		"f": _node("fork", {"title": "Choice"}),
		"c": _node("checkpoint", {"name": "Rest"}),
		"m": _node("minigame", {"game": "safe"}),
		"e": _node("loop_end"),
	}
	assert_str(_label(nodes, "r")).is_equal("Round — One")
	assert_str(_label(nodes, "s")).is_equal("Shop — Market")
	assert_str(_label(nodes, "b")).is_equal("Storyboard — Intro")
	assert_str(_label(nodes, "f")).is_equal("Fork — Choice")
	assert_str(_label(nodes, "c")).is_equal("Checkpoint — Rest")
	assert_str(_label(nodes, "m")).is_equal("Mini-Game — The Warden's Safe")
	assert_str(_label(nodes, "e")).is_equal("Loop End")


func test_an_unnamed_node_or_a_missing_game_still_reads() -> void:
	var nodes: Dictionary = {
		"r": _node("round"),
		"c": _node("checkpoint"),
		"m": _node("minigame", {"game": "gone"}),
	}
	assert_str(_label(nodes, "r")).is_equal("Round — (unnamed)")
	assert_str(_label(nodes, "c")).is_equal("Checkpoint — (unnamed)")
	assert_str(_label(nodes, "m")).is_equal("Mini-Game — (unnamed)")


func test_a_missing_or_unknown_node_never_shows_its_id() -> void:
	assert_str(_label({}, "n_123")).is_equal("(missing node)")
	assert_str(_label({"n_123": _node("something_new")}, "n_123")).is_equal("Something New")
