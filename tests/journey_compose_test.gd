extends GdUnitTestSuite

# JourneyCompose: the pure renditions overlay merge. A rendition (delta) composes onto a parent graph
# in memory without mutating the parent, with break-loudly errors for every way the overlay can fail to
# line up. No autoloads / I/O — pure graph rules.


# A tiny parent graph: one terminal round "a" (empty video slot), one fork "f" with one existing choice.
func _parent() -> Dictionary:
	return {
		"start": "a",
		"nodes":
		{
			"a": {"type": "round", "data": {"video_path": ""}, "out": []},
			"f": {"type": "fork", "data": {}, "out": [{"to": "a", "name": "Existing"}]},
		},
	}


# ── New nodes ────────────────────────────────────────────────────────────────


func test_adds_new_nodes() -> void:
	var r := {"nodes": {"b": {"type": "round", "data": {}, "out": []}}}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_array(out["errors"]).is_empty()
	assert_bool((out["graph"]["nodes"] as Dictionary).has("b")).is_true()
	assert_bool((out["graph"]["nodes"] as Dictionary).has("a")).is_true()  # parent node carried over


func test_id_collision_breaks_loudly() -> void:
	var r := {"nodes": {"a": {"type": "round", "data": {}, "out": []}}}  # clashes with parent "a"
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_int((out["errors"] as Array).size()).is_equal(1)
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("id_collision")


# ── Anchors ──────────────────────────────────────────────────────────────────


func test_anchor_extends_a_terminal() -> void:
	# New chapter "b" attached past the terminal round "a".
	var r := {
		"nodes": {"b": {"type": "round", "data": {}, "out": []}},
		"anchors": [{"anchor": "a", "edge": {"to": "b"}}],
	}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_array(out["errors"]).is_empty()
	var a_out: Array = out["graph"]["nodes"]["a"]["out"]
	assert_int(a_out.size()).is_equal(1)
	assert_str(str((a_out[0] as Dictionary)["to"])).is_equal("b")


func test_anchor_adds_a_fork_choice() -> void:
	var r := {
		"nodes": {"b": {"type": "round", "data": {}, "out": []}},
		"anchors": [{"anchor": "f", "edge": {"to": "b", "name": "New Path"}}],
	}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_array(out["errors"]).is_empty()
	var f_out: Array = out["graph"]["nodes"]["f"]["out"]
	assert_int(f_out.size()).is_equal(2)  # existing choice + the rendition's new one


func test_overlay_fork_choice_carries_name_and_image() -> void:
	# An overlay option appended to a complete base fork keeps its own label + card image, and lands
	# LAST so the base's choices keep their order/indices when played standalone vs composed.
	var r := {
		"nodes": {"b": {"type": "round", "data": {}, "out": []}},
		"anchors":
		[{"anchor": "f", "edge": {"to": "b", "name": "Alt Path", "image_path": "content/alt.png"}}],
	}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_array(out["errors"]).is_empty()
	var f_out: Array = out["graph"]["nodes"]["f"]["out"]
	assert_int(f_out.size()).is_equal(2)
	assert_str(str((f_out[0] as Dictionary)["name"])).is_equal("Existing")  # base choice, still first
	var added: Dictionary = f_out[1]
	assert_str(str(added["name"])).is_equal("Alt Path")
	assert_str(str(added["image_path"])).is_equal("content/alt.png")


func test_overlay_fork_choice_with_no_target_ends_the_run() -> void:
	# An overlay choice left unconnected (empty `to`) is a valid "ends the run" choice, exactly like a base
	# fork choice — appended, not treated as a broken edge.
	var r := {"anchors": [{"anchor": "f", "edge": {"to": "", "name": "Give Up"}}]}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_array(out["errors"]).is_empty()
	var f_out: Array = out["graph"]["nodes"]["f"]["out"]
	assert_int(f_out.size()).is_equal(2)
	assert_str(str((f_out[1] as Dictionary)["name"])).is_equal("Give Up")
	assert_str(str((f_out[1] as Dictionary)["to"])).is_equal("")


func test_anchor_missing_node() -> void:
	var r := {
		"nodes": {"b": {"type": "round", "data": {}, "out": []}},
		"anchors": [{"anchor": "ghost", "edge": {"to": "b"}}],
	}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("missing_anchor")


func test_anchor_missing_edge_target() -> void:
	var r := {"anchors": [{"anchor": "a", "edge": {"to": "nowhere"}}]}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("missing_edge_target")


# A parent whose fork "f" reserves an OPEN choice (index 1, blank `to`) for a rendition to fill.
func _parent_open_slot() -> Dictionary:
	var p := _parent()
	(p["nodes"]["f"]["out"] as Array).append({"to": "", "name": "Reserved"})
	return p


func test_anchor_fills_open_fork_slot_in_place() -> void:
	# slot 1 (the reserved blank choice) is filled — the fork's choice count is unchanged, and the base's
	# own label on that choice is kept (only `to` is set).
	var r := {
		"nodes": {"b": {"type": "round", "data": {}, "out": []}},
		"anchors": [{"anchor": "f", "edge": {"to": "b"}, "slot": 1}],
	}
	var out := JourneyCompose.compose_graph(_parent_open_slot(), r)
	assert_array(out["errors"]).is_empty()
	var f_out: Array = out["graph"]["nodes"]["f"]["out"]
	assert_int(f_out.size()).is_equal(2)  # NOT grown — the blank slot was populated, not appended
	assert_str(str((f_out[1] as Dictionary)["to"])).is_equal("b")
	assert_str(str((f_out[1] as Dictionary)["name"])).is_equal("Reserved")  # base's label preserved


func test_anchor_slot_collision_leaves_choice_untouched() -> void:
	# slot 0 already leads to "a" — filling it collides and the existing choice is not overwritten.
	var r := {
		"nodes": {"b": {"type": "round", "data": {}, "out": []}},
		"anchors": [{"anchor": "f", "edge": {"to": "b"}, "slot": 0}],
	}
	var out := JourneyCompose.compose_graph(_parent_open_slot(), r)
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("slot_collision")
	assert_str(str(out["graph"]["nodes"]["f"]["out"][0]["to"])).is_equal("a")


func test_anchor_slot_out_of_range() -> void:
	var r := {
		"nodes": {"b": {"type": "round", "data": {}, "out": []}},
		"anchors": [{"anchor": "f", "edge": {"to": "b"}, "slot": 9}],
	}
	var out := JourneyCompose.compose_graph(_parent_open_slot(), r)
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("missing_slot_choice")


# ── Slot fills ───────────────────────────────────────────────────────────────


func test_slot_fill_scalar_video() -> void:
	var r := {"slot_fills": [{"node": "a", "field": "video_path", "path": "content/clip.mp4"}]}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_array(out["errors"]).is_empty()
	assert_str(str(out["graph"]["nodes"]["a"]["data"]["video_path"])).is_equal("content/clip.mp4")


func test_slot_fill_scalar_collision() -> void:
	var parent := _parent()
	parent["nodes"]["a"]["data"]["video_path"] = "content/already.mp4"  # slot already occupied
	var r := {"slot_fills": [{"node": "a", "field": "video_path", "path": "content/new.mp4"}]}
	var out := JourneyCompose.compose_graph(parent, r)
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("slot_collision")
	# The occupied slot is left untouched — never silently overwritten.
	assert_str(str(out["graph"]["nodes"]["a"]["data"]["video_path"])).is_equal(
		"content/already.mp4"
	)


func test_slot_fill_channel() -> void:
	# The paid multi-axis case: add an L0 axis script to an existing base round.
	var r := {
		"slot_fills":
		[{"node": "a", "field": "axis_scripts", "channel": "L0", "path": "content/x.funscript"}]
	}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_array(out["errors"]).is_empty()
	assert_str(str(out["graph"]["nodes"]["a"]["data"]["axis_scripts"]["L0"])).is_equal(
		"content/x.funscript"
	)


func test_slot_fill_channel_collision() -> void:
	var parent := _parent()
	parent["nodes"]["a"]["data"]["axis_scripts"] = {"L0": "content/existing.funscript"}
	var r := {
		"slot_fills":
		[{"node": "a", "field": "axis_scripts", "channel": "L0", "path": "content/new.funscript"}]
	}
	var out := JourneyCompose.compose_graph(parent, r)
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("slot_collision")


func test_slot_fill_missing_node() -> void:
	var r := {"slot_fills": [{"node": "ghost", "field": "video_path", "path": "content/x.mp4"}]}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("missing_slot_node")


func test_slot_fill_unknown_field() -> void:
	var r := {"slot_fills": [{"node": "a", "field": "bogus", "path": "x"}]}
	var out := JourneyCompose.compose_graph(_parent(), r)
	assert_str(str((out["errors"][0] as Dictionary)["kind"])).is_equal("unknown_slot_field")


# ── The parent is never mutated ───────────────────────────────────────────────


func test_parent_graph_is_not_mutated() -> void:
	var parent := _parent()
	var r := {
		"nodes": {"b": {"type": "round", "data": {}, "out": []}},
		"anchors": [{"anchor": "a", "edge": {"to": "b"}}],
		"slot_fills": [{"node": "a", "field": "video_path", "path": "content/clip.mp4"}],
	}
	var out := JourneyCompose.compose_graph(parent, r)
	# Merged graph got the overlay…
	assert_int((out["graph"]["nodes"]["a"]["out"] as Array).size()).is_equal(1)
	assert_str(str(out["graph"]["nodes"]["a"]["data"]["video_path"])).is_equal("content/clip.mp4")
	# …but the input parent is untouched (deep-copied), so a composed overlay can never corrupt the base.
	assert_int((parent["nodes"]["a"]["out"] as Array).size()).is_equal(0)
	assert_str(str(parent["nodes"]["a"]["data"]["video_path"])).is_equal("")
	assert_bool((parent["nodes"] as Dictionary).has("b")).is_false()


func test_storyboard_name_survives_the_round_trip() -> void:
	# The loader inflates a storyboard from a fixed key list, so a field missing from EITHER direction is
	# dropped between the builder and the save — the same trap that has eaten several fields already.
	var saved := JourneyData.coerce_node_save_data(
		"storyboard", {"name": "She finds out", "coins": 5, "item": "", "lines": []}
	)
	assert_str(str(saved["name"])).is_equal("She finds out")


func test_a_storyboard_without_a_name_saves_a_blank_one() -> void:
	# Blank rather than absent: the caption falls back to "STORYBOARD n" on an empty string, and a
	# missing key would read the same way — but writing it keeps every storyboard the same shape.
	var saved := JourneyData.coerce_node_save_data("storyboard", {"coins": 0, "lines": []})
	assert_str(str(saved["name"])).is_equal("")
