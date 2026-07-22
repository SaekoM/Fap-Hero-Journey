extends GdUnitTestSuite

# Journey balance auditor — pins the pure analysis: baseline scoring, the coin
# interval walk (incl. curse/boon economics), fork gate findings (coins / score /
# item / flag), shop-sourced item availability, and the seeded Monte-Carlo pass.

const ITEMS: Dictionary = {
	"key": {"price": 30, "kind": "key"}, "cleanse": {"price": 25, "kind": "cleanse"}
}


func _round(coins: int, extra: Dictionary = {}) -> Dictionary:
	var data: Dictionary = {"coins": coins, "round_type": "normal"}
	data.merge(extra, true)
	return {"type": "round", "data": data, "out": []}


func _edge(to: String, extra: Dictionary = {}) -> Dictionary:
	var e: Dictionary = {"to": to}
	e.merge(extra, true)
	return e


func _audit(graph: Dictionary, ctx_extra: Dictionary = {}) -> Dictionary:
	var ctx: Dictionary = {"items": ITEMS, "round_scores": {}, "mc_runs": 400, "rng_seed": 7}
	ctx.merge(ctx_extra, true)
	return JourneyAudit.audit(graph, ctx)


func _findings_of_kind(result: Dictionary, kind: String, severity: String = "") -> Array:
	return (result["findings"] as Array).filter(
		func(f: Dictionary) -> bool:
			return f["kind"] == kind and (severity == "" or f["severity"] == severity)
	)


# ScoreService bucket mirror: deltas of 10 → 1pt, 70 → 3pt, 71 → 5pt. Actions
# are the Vector2(at_ms, pos) points read_funscript_actions produces.
func test_baseline_score_buckets() -> void:
	var actions := [Vector2(0, 0), Vector2(100, 10), Vector2(200, 80), Vector2(300, 9)]
	assert_int(JourneyAudit.baseline_score(actions)).is_equal(1 + 3 + 5)


# Linear graph: round payout and storyboard coins accumulate into the next
# node's entry interval.
func test_coin_interval_linear() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1": {"type": "round", "data": {"coins": 100}, "out": [_edge("sb")]},
			"sb": {"type": "storyboard", "data": {"coins": 5}, "out": [_edge("r2")]},
			"r2": _round(0),
		}
	}
	var coins: Dictionary = _audit(graph)["coins"]
	assert_int(int((coins["r2"] as Dictionary)["lo"])).is_equal(105)
	assert_int(int((coins["r2"] as Dictionary)["hi"])).is_equal(105)


# Fixed Toll curse: endure = payout + reward - 40; cleanse = payout - cost - 40.
# The next node's entry spans [cleanse, endure].
func test_cursed_round_interval() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1":
			{
				"type": "round",
				"data":
				{
					"coins": 100,
					"round_type": "cursed",
					"curses": ["Toll"],
					"curse_random": false,
					"curse_reward": 20,
					"cleanse_cost": 50,
				},
				"out": [_edge("r2")]
			},
			"r2": _round(0),
		}
	}
	var coins: Dictionary = _audit(graph)["coins"]
	assert_int(int((coins["r2"] as Dictionary)["lo"])).is_equal(10)  # 100-50-40
	assert_int(int((coins["r2"] as Dictionary)["hi"])).is_equal(80)  # 100+20-40


# An effect round with no ticked effects applies nothing (a pure-visual round): the next
# node's entry coins equal the plain payout — no random effect is rolled.
func test_effect_round_no_effects_is_noop() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1":
			{
				"type": "round",
				"data": {"coins": 100, "round_type": "effect", "effects": []},
				"out": [_edge("r2")]
			},
			"r2": _round(0),
		}
	}
	var coins: Dictionary = _audit(graph)["coins"]
	assert_int(int((coins["r2"] as Dictionary)["lo"])).is_equal(100)
	assert_int(int((coins["r2"] as Dictionary)["hi"])).is_equal(100)


# A tuned Toll (amount override) shifts the coin interval by the tuned value, not the
# catalog default of 40 — proving the auditor reads effect_overrides.
func test_effect_tuned_toll_interval() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1":
			{
				"type": "round",
				"data":
				{
					"coins": 100,
					"round_type": "effect",
					"effects": ["Toll"],
					"effect_random": false,
					"effect_overrides": {"Toll": {"amount": 10}},
				},
				"out": [_edge("r2")]
			},
			"r2": _round(0),
		}
	}
	var coins: Dictionary = _audit(graph)["coins"]
	assert_int(int((coins["r2"] as Dictionary)["lo"])).is_equal(90)  # 100 − 10 tuned toll
	assert_int(int((coins["r2"] as Dictionary)["hi"])).is_equal(90)


# Sacrifice gates: a cost above the best-case balance is dead; a cost above the
# worst case (but below best) only warns.
func test_sacrifice_cost_findings() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1": {"type": "round", "data": {"coins": 100}, "out": [_edge("f")]},
			"f":
			{
				"type": "fork",
				"data": {"resolution": "sacrifice"},
				"out":
				[
					_edge("a", {"name": "Free", "cost": 0}),
					_edge("b", {"name": "Pricey", "cost": 999}),
				]
			},
			"a": _round(0),
			"b": _round(0),
		}
	}
	var result := _audit(graph)
	var dead: Array = _findings_of_kind(result, "sacrifice_cost", "dead")
	assert_int(dead.size()).is_equal(1)
	assert_int(int((dead[0] as Dictionary)["edge_idx"])).is_equal(1)


# Conditional score gates compare against the preceding round's baseline score.
func test_conditional_score_gate() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1": {"type": "round", "data": {"coins": 0}, "out": [_edge("f")]},
			"f":
			{
				"type": "fork",
				"data": {"resolution": "conditional", "cond_metric": "score", "default_path": 0},
				"out":
				[
					_edge("a", {"name": "High road", "threshold": 60}),
					_edge("b", {"name": "Default", "threshold": 0}),
				]
			},
			"a": _round(0),
			"b": _round(0),
		}
	}
	var result := _audit(graph, {"round_scores": {"r1": 50}})
	var dead: Array = _findings_of_kind(result, "score_gate", "dead")
	assert_int(dead.size()).is_equal(1)
	assert_int(int((dead[0] as Dictionary)["edge_idx"])).is_equal(0)

	# Reachable threshold → no dead finding.
	var ok := _audit(graph, {"round_scores": {"r1": 70}})
	assert_int(_findings_of_kind(ok, "score_gate", "dead").size()).is_equal(0)


# Flag gates are upstream-aware: dead when nothing on a route in sets the flag,
# clean when an upstream node sets it.
func test_flag_gate_upstream_aware() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1": {"type": "round", "data": {"coins": 0}, "out": [_edge("f")]},
			"f":
			{
				"type": "fork",
				"data": {"resolution": "conditional", "cond_metric": "flag", "default_path": 1},
				"out":
				[
					_edge("a", {"name": "Secret", "required_flag": "opened"}),
					_edge("b", {"name": "Default"}),
				]
			},
			"a": _round(0),
			"b": _round(0),
		}
	}
	var result := _audit(graph)
	assert_int(_findings_of_kind(result, "flag_gate", "dead").size()).is_equal(1)

	(graph["nodes"]["r1"]["data"] as Dictionary)["set_flags"] = ["opened"]
	var ok := _audit(graph)
	assert_int(_findings_of_kind(ok, "flag_gate", "dead").size()).is_equal(0)


# Item gates ride shop availability: a fixed-lineup shop upstream (affordable in
# the worst case) makes the item guaranteed; no source at all is dead; a
# pool-mode shop without a guarantee is possible-only → warn.
func test_item_gate_shop_sources() -> void:
	var fork := {
		"type": "fork",
		"data": {"resolution": "sacrifice"},
		"out":
		[
			_edge("a", {"name": "Free", "cost": 0}),
			_edge("b", {"name": "Locked", "required_item": "key"}),
		]
	}
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1": {"type": "round", "data": {"coins": 100}, "out": [_edge("shop")]},
			"shop":
			{
				"type": "shop",
				"data": {"mode": "fixed", "items": ["key"], "price_multiplier": 1.0},
				"out": [_edge("f")]
			},
			"f": fork,
			"a": _round(0),
			"b": _round(0),
		}
	}
	var ok := _audit(graph)
	assert_int(_findings_of_kind(ok, "item_gate").size()).is_equal(0)

	# Pool mode, not guaranteed → possible only → warn.
	(graph["nodes"]["shop"] as Dictionary)["data"] = {
		"mode": "pool", "count": 1, "guaranteed": [], "price_multiplier": 1.0
	}
	var possible := _audit(graph)
	assert_int(_findings_of_kind(possible, "item_gate", "warn").size()).is_equal(1)

	# No shop at all → the item can never be owned → dead.
	(graph["nodes"]["r1"] as Dictionary)["out"] = [_edge("f")]
	(graph["nodes"] as Dictionary).erase("shop")
	var dead := _audit(graph)
	assert_int(_findings_of_kind(dead, "item_gate", "dead").size()).is_equal(1)


# Seeded Monte-Carlo: a 9:1 weighted random fork routes ~90/10, and a heavily
# lopsided fork surfaces a cold-path finding on the rare edge.
func test_monte_carlo_weighted_traffic() -> void:
	var graph := {
		"start": "f",
		"nodes":
		{
			"f":
			{
				"type": "fork",
				"data": {"resolution": "random"},
				"out":
				[
					_edge("a", {"name": "Common", "weight": 9}),
					_edge("b", {"name": "Rare", "weight": 1}),
				]
			},
			"a": _round(0),
			"b": _round(0),
		}
	}
	var result := _audit(graph, {"mc_runs": 1000})
	var edges: Dictionary = (result["visits"] as Dictionary)["edges"]
	var common: int = int(edges.get("f:0", 0))
	var rare: int = int(edges.get("f:1", 0))
	assert_int(common + rare).is_equal(1000)
	assert_bool(common > 800).is_true()
	assert_bool(rare > 20).is_true()

	(graph["nodes"]["f"]["out"][0] as Dictionary)["weight"] = 999
	var lopsided := _audit(graph, {"mc_runs": 1000})
	assert_int(_findings_of_kind(lopsided, "cold_path").size()).is_equal(1)


# Statistics: route bounds for total score / rounds / duration, the end-coin
# range, MC averages inside the analytical bounds, and a ~50/50 ending split.
func test_statistics() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1": {"type": "round", "data": {"coins": 100}, "out": [_edge("f")]},
			"f":
			{
				"type": "fork",
				"data": {"resolution": "random"},
				"out": [_edge("a", {"weight": 1}), _edge("b", {"weight": 1})]
			},
			"a": _round(0),
			"b": _round(0),
		}
	}
	var result := _audit(
		graph,
		{
			"round_scores": {"r1": 50, "a": 10, "b": 30},
			"round_lengths": {"r1": 60000, "a": 30000, "b": 90000},
			"mc_runs": 1000,
		}
	)
	var stats: Dictionary = result["stats"]
	assert_int(int((stats["total_score"] as Dictionary)["lo"])).is_equal(60)
	assert_int(int((stats["total_score"] as Dictionary)["hi"])).is_equal(80)
	assert_int(int((stats["rounds"] as Dictionary)["lo"])).is_equal(2)
	assert_int(int((stats["rounds"] as Dictionary)["hi"])).is_equal(2)
	assert_int(int((stats["duration_ms"] as Dictionary)["lo"])).is_equal(90000)
	assert_int(int((stats["duration_ms"] as Dictionary)["hi"])).is_equal(150000)
	assert_int(int((stats["end_coins"] as Dictionary)["lo"])).is_equal(100)
	assert_int(int((stats["end_coins"] as Dictionary)["hi"])).is_equal(100)
	assert_str(str((stats["best_round"] as Dictionary)["node_id"])).is_equal("r1")

	var avg: float = float((stats["total_score"] as Dictionary)["avg"])
	assert_bool(avg >= 60.0 and avg <= 80.0).is_true()

	var endings: Array = stats["endings"]
	assert_int(endings.size()).is_equal(2)
	for e: Dictionary in endings:
		assert_bool(float(e["pct"]) > 30.0).is_true()

	# Arrival averages (the ⚖ ON ARRIVAL block): every run reaches "a" or "b"
	# carrying exactly r1's 100-coin payout and its 50-point round score.
	var visits: Dictionary = result["visits"]
	var arrive_coins: Dictionary = visits["avg_arrival_coins"]
	var arrive_score: Dictionary = visits["avg_arrival_score"]
	for id: String in ["a", "b"]:
		assert_float(float(arrive_coins[id])).is_equal_approx(100.0, 0.01)
		assert_float(float(arrive_score[id])).is_equal_approx(50.0, 0.01)


# A pool ("encounter") round's score/length is a RANGE — the runtime rolls one entry — so the
# interval walk must bound it with round_score_bounds / round_length_bounds rather than collapse
# it to the flat mean. (Before this, a pool round had no round-level funscript and audited as a
# zero-score, zero-length round.)
func test_pool_round_score_and_length_bounds() -> void:
	var graph := {
		"start": "p",
		"nodes": {"p": {"type": "round", "data": {"coins": 0, "round_type": "pool"}, "out": []}},
	}
	var result := _audit(
		graph,
		{
			"round_scores": {"p": 40},  # weighted mean (what the MC pass models)
			"round_lengths": {"p": 60000},
			"round_score_bounds": {"p": {"lo": 10, "hi": 90}},
			"round_length_bounds": {"p": {"lo": 30000, "hi": 120000}},
		}
	)
	var stats: Dictionary = result["stats"]
	assert_int(int((stats["total_score"] as Dictionary)["lo"])).is_equal(10)
	assert_int(int((stats["total_score"] as Dictionary)["hi"])).is_equal(90)
	assert_int(int((stats["duration_ms"] as Dictionary)["lo"])).is_equal(30000)
	assert_int(int((stats["duration_ms"] as Dictionary)["hi"])).is_equal(120000)


# The bounds keys are optional: an ordinary round supplies none, and its flat score/length must
# still bound itself (the new ctx keys must not disturb existing journeys).
func test_round_without_bounds_uses_flat_value() -> void:
	var graph := {
		"start": "r1", "nodes": {"r1": {"type": "round", "data": {"coins": 0}, "out": []}}
	}
	var result := _audit(graph, {"round_scores": {"r1": 50}, "round_lengths": {"r1": 60000}})
	var stats: Dictionary = result["stats"]
	assert_int(int((stats["total_score"] as Dictionary)["lo"])).is_equal(50)
	assert_int(int((stats["total_score"] as Dictionary)["hi"])).is_equal(50)
	assert_int(int((stats["duration_ms"] as Dictionary)["lo"])).is_equal(60000)
	assert_int(int((stats["duration_ms"] as Dictionary)["hi"])).is_equal(60000)


# Coverage: a flag set but never required by any fork choice is an orphan;
# adding a checker clears the finding.
func test_flag_unused_coverage() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1":
			{"type": "round", "data": {"coins": 0, "set_flags": ["secret"]}, "out": [_edge("f")]},
			"f":
			{
				"type": "fork",
				"data": {"resolution": "conditional", "cond_metric": "flag", "default_path": 1},
				"out": [_edge("a", {"name": "Gated"}), _edge("b", {"name": "Default"})]
			},
			"a": _round(0),
			"b": _round(0),
		}
	}
	var orphan := _audit(graph)
	assert_int(_findings_of_kind(orphan, "flag_unused").size()).is_equal(1)

	(graph["nodes"]["f"]["out"][0] as Dictionary)["required_flag"] = "secret"
	var checked := _audit(graph)
	assert_int(_findings_of_kind(checked, "flag_unused").size()).is_equal(0)


# Coverage: a granted key-kind item nothing requires is flagged; a self-useful
# item (Cleanse) granted without a gate is NOT — it has its own effect.
func test_item_unused_coverage() -> void:
	var graph := {
		"start": "sb",
		"nodes":
		{
			"sb": {"type": "storyboard", "data": {"coins": 0, "item": "key"}, "out": [_edge("r")]},
			"r": _round(0),
		}
	}
	var unused := _audit(graph)
	assert_int(_findings_of_kind(unused, "item_unused").size()).is_equal(1)

	(graph["nodes"]["sb"]["data"] as Dictionary)["item"] = "cleanse"
	var self_useful := _audit(graph)
	assert_int(_findings_of_kind(self_useful, "item_unused").size()).is_equal(0)


# A content-less checkpoint node (the graph shape the migration produces).
func _checkpoint(to: String) -> Dictionary:
	return {"type": "checkpoint", "data": {"name": ""}, "out": [_edge(to)]}


# Checkpoint spacing: two 20-min rounds with no save point exceed the 30-min threshold; a
# checkpoint node before each round caps every stretch at one round.
func test_checkpoint_gap() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1": {"type": "round", "data": {"coins": 0}, "out": [_edge("r2")]},
			"r2": _round(0),
		}
	}
	var lengths := {"round_lengths": {"r1": 1_200_000, "r2": 1_200_000}}
	var gap := _audit(graph, lengths)
	var found: Array = _findings_of_kind(gap, "checkpoint_gap")
	assert_int(found.size()).is_equal(1)
	assert_str(str((found[0] as Dictionary)["node_id"])).is_equal("r2")

	# Splice a checkpoint node before each round → each round is its own stretch.
	var saved_graph := {
		"start": "c1",
		"nodes":
		{
			"c1": _checkpoint("r1"),
			"r1": {"type": "round", "data": {"coins": 0}, "out": [_edge("c2")]},
			"c2": _checkpoint("r2"),
			"r2": _round(0),
		}
	}
	var saved := _audit(saved_graph, lengths)
	assert_int(_findings_of_kind(saved, "checkpoint_gap").size()).is_equal(0)


# Gate-purchase policy: a shop selling a key that a fork ahead requires gets
# bought, so the locked branch receives real traffic (~50% — both paths
# qualify) and the purchase price shows up in the fork's arrival coins.
func test_simulation_buys_gate_items() -> void:
	var graph := {
		"start": "r1",
		"nodes":
		{
			"r1": {"type": "round", "data": {"coins": 100}, "out": [_edge("shop")]},
			"shop":
			{
				"type": "shop",
				"data": {"mode": "fixed", "items": ["key"], "price_multiplier": 1.0},
				"out": [_edge("f")]
			},
			"f":
			{
				"type": "fork",
				"data": {"resolution": "sacrifice"},
				"out":
				[
					_edge("a", {"name": "Free", "cost": 0}),
					_edge("b", {"name": "Locked", "required_item": "key"}),
				]
			},
			"a": _round(0),
			"b": _round(0),
		}
	}
	var result := _audit(graph, {"mc_runs": 1000})
	var edges: Dictionary = (result["visits"] as Dictionary)["edges"]
	# Every run owns the key at the fork → both paths qualify → roughly even.
	assert_bool(int(edges.get("f:1", 0)) > 300).is_true()
	assert_bool(int(edges.get("f:0", 0)) > 300).is_true()
	# The ♦30 key purchase is visible in the fork's arrival coins.
	var arrive: Dictionary = (result["visits"] as Dictionary)["avg_arrival_coins"]
	assert_float(float(arrive["f"])).is_equal_approx(70.0, 0.01)


# Checkpoint statistics + the save-spacing bar: a checkpoint node before each of two 20-min
# rounds → every stretch is exactly one round, and the spacing bar splits the route into two
# equal segments.
func test_checkpoint_stats_and_bar() -> void:
	var graph := {
		"start": "c1",
		"nodes":
		{
			"c1": _checkpoint("r1"),
			"r1": {"type": "round", "data": {"coins": 0}, "out": [_edge("c2")]},
			"c2": _checkpoint("r2"),
			"r2": _round(0),
		}
	}
	var lengths := {"round_lengths": {"r1": 1_200_000, "r2": 1_200_000}}
	var stats: Dictionary = _audit(graph, lengths)["stats"]

	var cp: Dictionary = stats["checkpoints"]
	assert_int(int(cp["count"])).is_equal(2)
	assert_int(int(cp["shortest_ms"])).is_equal(1_200_000)
	assert_int(int(cp["longest_ms"])).is_equal(1_200_000)
	# Every simulated stretch is exactly one 20-min round.
	assert_float(float(cp["avg_ms"])).is_equal_approx(1_200_000.0, 1.0)

	var bar: Dictionary = stats["cp_bar"]
	assert_int(int(bar["total_ms"])).is_equal(2_400_000)
	var segments: Array = bar["segments"]
	assert_int(segments.size()).is_equal(2)
	assert_int(int((segments[0] as Dictionary)["ms"])).is_equal(1_200_000)
	assert_int(int((segments[1] as Dictionary)["rounds"])).is_equal(1)
