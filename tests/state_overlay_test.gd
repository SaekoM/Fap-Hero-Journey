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


# ── Mini-games ───────────────────────────────────────────────────────────────


func _safe_library(extra: Dictionary = {}) -> Array:
	var raw: Dictionary = {
		"id": "safe",
		"kind": SafeCrackerGame.KIND,
		"tiers":
		[
			{"name": "Fail", "min_score": 0, "rewards": {"clear_flags": ["lucky"]}},
			{"name": "Pass", "min_score": 40, "rewards": {"set_flags": ["opened_safe"]}},
			{
				"name": "Perfect",
				"min_score": 90,
				"rewards": {"set_flags": ["opened_safe"], "set_counters": {"grit": 2}},
			},
		],
	}
	raw.merge(extra, true)
	return [MiniGameLibrary.normalize_definition(raw)]


func _graph_with_node(type: String, data: Dictionary) -> Dictionary:
	return {"nodes": {"n": {"type": type, "data": data, "out": []}}}


func _node_marks(graph: Dictionary, library: Array, items: Dictionary = {}) -> Array:
	return JourneyData.state_marks_in_graph(graph, items, library)["nodes"].get("n", [])


func test_a_game_node_shows_its_tiers_rewards_with_their_names() -> void:
	var graph: Dictionary = _graph_with_node("minigame", {"game": "safe"})
	assert_array(_texts(_node_marks(graph, _safe_library()))).contains_exactly_in_any_order(
		["⚐ lucky (Fail)", "⚑ opened_safe (Pass, Perfect)", "+2 grit (Perfect)"]
	)


func test_a_chip_keeps_what_the_where_used_list_filters_on() -> void:
	var graph: Dictionary = _graph_with_node("minigame", {"game": "safe"})
	for mark: Dictionary in _node_marks(graph, _safe_library()):
		if str(mark["kind"]) == "flag" and str(mark["name"]) == "opened_safe":
			assert_str(str(mark["role"])).is_equal("change")
			assert_str(str(mark["tone"])).is_equal("set")
			return
	fail("opened_safe has no mark")


func test_different_amounts_are_separate_chips() -> void:
	var library: Array = _safe_library(
		{
			"tiers":
			[
				{"name": "Fail", "min_score": 0, "rewards": {"set_counters": {"grit": -1}}},
				{"name": "Pass", "min_score": 40, "rewards": {"set_counters": {"grit": 1}}},
			]
		}
	)
	var graph: Dictionary = _graph_with_node("minigame", {"game": "safe"})
	assert_array(_texts(_node_marks(graph, library))).contains_exactly_in_any_order(
		["−1 grit (Fail)", "+1 grit (Pass)"]
	)


func test_a_ladder_names_its_rungs_and_its_bust() -> void:
	var library: Array = [
		(
			MiniGameLibrary
			. normalize_definition(
				{
					"id": "wager",
					"kind": DoubleOrNothingGame.KIND,
					"rungs":
					[
						{"rewards": {}},
						{"rewards": {"set_flags": ["high_roller"]}},
					],
					"bust_rewards": {"clear_flags": ["lucky"]},
				}
			)
		)
	]
	var graph: Dictionary = _graph_with_node("minigame", {"game": "wager"})
	assert_array(_texts(_node_marks(graph, library))).contains_exactly_in_any_order(
		["⚑ high_roller (Rung 2)", "⚐ lucky (Bust)"]
	)


func test_a_retry_cost_shows_only_when_a_retry_can_be_offered() -> void:
	var cost: Dictionary = {"set_counters": {"grit": -1}}
	var graph: Dictionary = _graph_with_node("minigame", {"game": "safe"})
	var one_try: Array = _safe_library({"attempts": 1, "retry_cost": cost})
	assert_array(_texts(_node_marks(graph, one_try))).not_contains(["−1 grit (Retry)"])
	var two_tries: Array = _safe_library({"attempts": 2, "retry_cost": cost})
	assert_array(_texts(_node_marks(graph, two_tries))).contains(["−1 grit (Retry)"])


func test_a_dodge_on_a_boss_shows_on_the_round() -> void:
	var library: Array = [
		(
			MiniGameLibrary
			. normalize_definition(
				{
					"id": "slip",
					"kind": QuickTimeEventGame.KIND,
					"tiers":
					[
						{"name": "Miss", "min_score": 0, "rewards": {}},
						{"name": "Hit", "min_score": 50, "rewards": {"set_flags": ["slipped"]}},
					],
				}
			)
		)
	]
	var timeline: Dictionary = {"events": [{"track": "attack", "dodge": {"game": "slip"}}]}
	var graph: Dictionary = _graph_with_node("round", {"timeline": timeline})
	assert_array(_texts(_node_marks(graph, library))).contains_exactly(["⚑ slipped (Hit)"])


func test_a_game_given_item_shows_what_using_it_does() -> void:
	var library: Array = _safe_library(
		{"tiers": [{"name": "Win", "min_score": 0, "rewards": {"item": "key"}}]}
	)
	var items: Dictionary = {
		"key": {"name": "Keycard", "effects": [{"kind": "flag", "flag": "has_key"}]}
	}
	var graph: Dictionary = _graph_with_node("minigame", {"game": "safe"})
	assert_array(_texts(_node_marks(graph, library, items))).contains_exactly_in_any_order(
		["🎒 +Keycard (Win)", "🎒 Keycard → ⚑ has_key (Win)"]
	)


func test_a_game_that_is_gone_or_a_journey_without_a_library_shows_nothing() -> void:
	var graph: Dictionary = _graph_with_node("minigame", {"game": "gone"})
	assert_array(_node_marks(graph, _safe_library())).is_empty()
	assert_array(_node_marks(_graph_with_node("minigame", {"game": "safe"}), [])).is_empty()
