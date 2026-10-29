extends GdUnitTestSuite

# The builder's ± STATE overlay: where counters and flags change and where they are checked, read
# straight from the graph so the canvas can show it live.


func _texts(marks: Array) -> Array:
	var out: Array = []
	for mark: Dictionary in marks:
		out.append(str(mark["text"]))
	return out


func test_a_node_shows_its_counter_and_flag_changes() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"r":
			{
				"type": "round",
				"data":
				{
					"set_counters": {"Ammo": 3, "Stress": -1},
					"set_flags": ["met_her"],
					"clear_flags": ["hidden"],
				},
				"out": [],
			},
		},
	}
	var marks: Array = JourneyData.state_marks_in_graph(graph)["nodes"]["r"]
	assert_array(_texts(marks)).contains_exactly(["+3 Ammo", "−1 Stress", "⚑ met_her", "⚐ hidden"])
	assert_str(marks[0]["tone"]).is_equal("up")
	assert_str(marks[1]["tone"]).is_equal("down")


func test_a_node_that_touches_nothing_has_no_marks() -> void:
	var graph: Dictionary = {"nodes": {"r": {"type": "round", "data": {}, "out": []}}}
	assert_dict(JourneyData.state_marks_in_graph(graph)["nodes"]).is_empty()


# A choice's changes and its requirement go on the choice's line, requirement first.
func test_a_fork_choice_shows_its_gate_then_its_changes() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"f":
			{
				"type": "fork",
				"data":
				{
					"resolution": "conditional",
					"cond_metric": "counter",
					"cond_counter": "Ammo",
					"default_path": 0,
				},
				"out":
				[
					{"to": "a"},
					{"to": "b", "threshold": 5, "set_counters": {"Ammo": -5}},
				],
			},
		},
	}
	var edges: Dictionary = JourneyData.state_marks_in_graph(graph)["edges"]
	assert_bool(edges.has("f:0")).is_false()
	assert_array(_texts(edges["f:1"])).contains_exactly(["🔒 Ammo ≥ 5", "−5 Ammo"])
	assert_str(edges["f:1"][0]["role"]).is_equal("check")


func test_a_requirement_on_the_default_choice_is_marked_ignored() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"f":
			{
				"type": "fork",
				"data": {"resolution": "conditional", "cond_metric": "flag", "default_path": 0},
				"out": [{"to": "a", "required_flag": "key"}, {"to": "b"}],
			},
		},
	}
	var edges: Dictionary = JourneyData.state_marks_in_graph(graph)["edges"]
	assert_str(edges["f:0"][0]["text"]).is_equal("🔒 ⚑ key  (default — ignored)")


# A requirement only gates a conditional fork; on a player's free choice it does nothing.
func test_a_requirement_on_a_free_choice_is_not_shown() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"f":
			{
				"type": "fork",
				"data": {"resolution": "choice", "cond_metric": "flag"},
				"out": [{"to": "a", "required_flag": "key"}, {"to": "b"}],
			},
		},
	}
	assert_dict(JourneyData.state_marks_in_graph(graph)["edges"]).is_empty()


func test_a_loop_exit_shows_as_a_check() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"e":
			{
				"type": "loop_end",
				"data":
				{
					"loop_conditions":
					[
						{"kind": "counter", "counter": "Ammo", "cmp": "lte", "threshold": 0},
						{"kind": "flag", "flag": "escaped"},
						{"kind": "repeats", "count": 3},
					],
				},
				"out": [],
			},
		},
	}
	var marks: Array = JourneyData.state_marks_in_graph(graph)["nodes"]["e"]
	assert_array(_texts(marks)).contains_exactly(["⟲ exit at Ammo ≤ 0", "⟲ exit on ⚑ escaped"])


func test_a_boss_encounter_raises_its_outcome_flags() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"b":
			{
				"type": "round",
				"data": {"timeline": {"won_flag": "beat_boss", "lost_flag": "fled"}},
				"out": [],
			},
		},
	}
	var marks: Array = JourneyData.state_marks_in_graph(graph)["nodes"]["b"]
	assert_array(_texts(marks)).contains_exactly(["⚑ beat_boss (won)", "⚑ fled (lost)"])


func test_what_a_node_hands_out_shows_what_using_it_does() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"s": {"type": "storyboard", "data": {"item": "it_medkit"}, "out": []},
			"r": {"type": "round", "data": {"award_item": "it_plain"}, "out": []},
		},
	}
	var items: Dictionary = {
		"it_medkit":
		{
			"name": "Medkit",
			"effects":
			[
				{"kind": "counter", "counter": "Health", "delta": 20},
				{"kind": "flag", "flag": "healed"},
			],
		},
	}
	var marks: Dictionary = JourneyData.state_marks_in_graph(graph, items)["nodes"]
	assert_array(_texts(marks["s"])).contains_exactly(
		["🎒 +Medkit", "🎒 Medkit → ⚑ healed", "🎒 Medkit → +20 Health"]
	)
	# An item with no flag or counter effect that nothing checks can't change the route: not shown.
	assert_bool(marks.has("r")).is_false()


func test_an_items_state_effects_are_read_from_its_effect_list() -> void:
	var effects: Dictionary = (
		JourneyData
		. item_state_effects(
			{
				"effects":
				[
					{"kind": "counter", "counter": "Ammo", "delta": -1},
					{"kind": "flag", "flag": "fired"},
					{"kind": "scale", "pct": 50},
				]
			}
		)
	)
	assert_array(effects["flags"]).is_equal(["fired"])
	assert_dict(effects["counters"]).is_equal({"Ammo": -1})


# ── Items as state ───────────────────────────────────────────────────────────

const KEYCARD: Dictionary = {"it_key": {"name": "Keycard"}}


# `nodes` plus a Loop End that exits on holding the Keycard, so the Keycard matters to routing.
func _with_keycard_gate(nodes: Dictionary) -> Dictionary:
	nodes["gate"] = {
		"type": "loop_end",
		"data": {"loop_conditions": [{"kind": "item", "item": "it_key"}]},
		"out": [],
	}
	return {"nodes": nodes}


func test_an_item_handed_out_and_taken_back_shows_both() -> void:
	var graph: Dictionary = _with_keycard_gate(
		{
			"r": {"type": "round", "data": {"award_item": "it_key"}, "out": []},
			"t": {"type": "storyboard", "data": {"remove_items": ["it_key"]}, "out": []},
		}
	)
	var marks: Dictionary = JourneyData.state_marks_in_graph(graph, KEYCARD)["nodes"]
	assert_array(_texts(marks["r"])).contains_exactly(["🎒 +Keycard"])
	assert_array(_texts(marks["t"])).contains_exactly(["🎒 −Keycard"])
	assert_str(marks["t"][0]["kind"]).is_equal("item")
	assert_str(marks["t"][0]["name"]).is_equal("it_key")


func test_only_an_effect_round_gives_its_gift() -> void:
	var graph: Dictionary = _with_keycard_gate(
		{
			"plain": {"type": "round", "data": {"gift_item": "it_key"}, "out": []},
			"cursed":
			{"type": "round", "data": {"round_type": "effect", "gift_item": "it_key"}, "out": []},
		}
	)
	var marks: Dictionary = JourneyData.state_marks_in_graph(graph, KEYCARD)["nodes"]
	assert_bool(marks.has("plain")).is_false()
	assert_array(_texts(marks["cursed"])).contains_exactly(["🎒 +Keycard"])


func test_a_shop_marks_stock_it_may_not_draw() -> void:
	var items: Dictionary = {
		"it_key": {"name": "Keycard"},
		"it_map": {"name": "Map", "effects": [{"kind": "flag", "flag": "mapped"}]},
		"it_snack": {"name": "Snack"},
	}
	var graph: Dictionary = _with_keycard_gate(
		{
			"s":
			{
				"type": "shop",
				"data": {"mode": "pool", "guaranteed": ["it_key"], "excluded": []},
				"out": [],
			},
		}
	)
	var marks: Array = JourneyData.state_marks_in_graph(graph, items)["nodes"]["s"]
	assert_array(_texts(marks)).contains(["🛒 Keycard", "🛒 Map (maybe)"])
	assert_array(_texts(marks)).not_contains(["🛒 Snack (maybe)"])  # nothing checks it, no effect
	assert_str(marks[0]["group"]).is_equal("shop")


func test_item_checks_and_a_spent_sacrifice() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"f":
			{
				"type": "fork",
				"data": {"resolution": "conditional", "cond_metric": "item", "default_path": 1},
				"out": [{"to": "a", "required_item": "it_key"}, {"to": "b"}],
			},
			"g":
			{
				"type": "fork",
				"data": {"resolution": "sacrifice"},
				"out": [{"to": "a", "required_item": "it_key", "remove_items": []}],
			},
			"e":
			{
				"type": "loop_end",
				"data": {"loop_conditions": [{"kind": "item", "item": "it_key"}]},
				"out": [],
			},
		},
	}
	var result: Dictionary = JourneyData.state_marks_in_graph(graph, KEYCARD)
	assert_array(_texts(result["edges"]["f:0"])).contains_exactly(["🔒 🎒 Keycard"])
	assert_array(_texts(result["edges"]["g:0"])).contains_exactly(["🔒 🎒 Keycard (spent)"])
	assert_array(_texts(result["nodes"]["e"])).contains_exactly(["⟲ exit holding 🎒 Keycard"])


func test_an_item_nothing_checks_and_with_no_state_effect_is_left_off() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"r": {"type": "round", "data": {"award_item": "it_key"}, "out": []},
			"t": {"type": "storyboard", "data": {"remove_items": ["it_key"]}, "out": []},
		},
	}
	assert_dict(JourneyData.state_marks_in_graph(graph, KEYCARD)["nodes"]).is_empty()
