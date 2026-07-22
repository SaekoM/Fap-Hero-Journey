class_name JourneyAudit
extends RefCounted

# Journey balance auditor — pure analysis over the builder's graph model
# ({start, nodes:{id:{type,data,out}}}). Two passes:
#
#   1. An INTERVAL WALK propagating worst/best-case coins, last-round score,
#      item ownership (guaranteed vs possible) and settable flags through the
#      DAG in topological order, then checking every fork gate against them.
#   2. A MONTE-CARLO pass (simulate) that plays N runs with the baseline
#      player model and counts per-edge traffic, surfacing near-dead paths.
#
# Baseline player model (documented in the report UI): completes every round,
# never cleanses (endures), and buys ONLY gate items — at a shop, the simulated
# player purchases an offered item some fork ahead requires (when affordable
# and not already held), so item-locked branches receive realistic traffic
# instead of a flat 0%. The interval walk mirrors that asymmetry: COIN bounds
# assume no purchases (a run's simulated average can therefore dip below the
# analytic lo after a gate purchase), while ITEM availability assumes a needed
# guaranteed+affordable item IS bought.
#
# Score/coin mechanics are mirrored from the runtime; the mirrored constants
# below must stay in lockstep with their sources.

# ScoreService.cs stroke buckets (amplitude = |pos delta|, 0-100).
const SCORE_SMALL_MAX: int = 20
const SCORE_MEDIUM_MAX: int = 70
const SCORE_SMALL_PTS: int = 1
const SCORE_MEDIUM_PTS: int = 3
const SCORE_LARGE_PTS: int = 5

# GameLoop.TOLL_AMOUNT — coins a "Toll" curse takes immediately.
const TOLL_AMOUNT: int = 40

# Monte-Carlo defaults: runs per audit, and the traffic share (in %) under
# which an edge is reported as a cold path.
const DEFAULT_MC_RUNS: int = 1000
const COLD_EDGE_PCT: float = 2.0

# A worst-route stretch without a checkpoint longer than this (playtime from
# funscript lengths) earns an INFO finding. 30 minutes.
const CHECKPOINT_GAP_MS: int = 1_800_000

# Finding severities.
const SEV_DEAD: String = "dead"  # can never happen — dead authored content
const SEV_WARN: String = "warn"  # fails on some routes / some runs
const SEV_INFO: String = "info"  # worth knowing; not necessarily a problem


# Runs the full audit. ctx:
#   items:         {item_id: {"price": int, ...}} — the item registry
#   round_scores:  {node_id: int} — baseline funscript score per round node
#                  (compute via baseline_score; engine glue does the file I/O).
#                  For a POOL round this is the weighted MEAN over its entries (the
#                  runtime rolls one), i.e. the expected value the MC pass models.
#   round_lengths: {node_id: int} — funscript length in ms per round node (pool: mean)
#   round_score_bounds:  {node_id: {lo, hi}} (optional) — per-node score range when a
#                  round's score isn't a single value (a POOL round varies by which
#                  entry is rolled). Absent → the flat round_scores value bounds it.
#   round_length_bounds: {node_id: {lo, hi}} (optional) — same, for funscript length
#   mc_runs:       int (optional, DEFAULT_MC_RUNS)
#   rng_seed:      int (optional — fixed seed makes the MC pass reproducible)
# Returns {findings, coins, last_score, visits, stats}: findings is an Array of
# {severity, kind, node_id, edge_idx, msg}; coins/last_score map node_id →
# {lo, hi} ENTRY intervals; visits is simulate()'s output; stats is
# _statistics()'s journey-wide summary.
static func audit(graph: Dictionary, ctx: Dictionary) -> Dictionary:
	# Migrate any legacy cursed/blessed round nodes to the generic effect schema once,
	# up front, so every downstream walk reads a single (effect) shape.
	graph = _normalize_rounds(graph)
	var flow: Dictionary = _flow_analysis(graph, ctx)
	var findings: Array = _gate_findings(graph, ctx, flow)

	var rng := RandomNumberGenerator.new()
	if ctx.has("rng_seed"):
		rng.seed = int(ctx["rng_seed"])
	else:
		rng.randomize()
	var visits: Dictionary = simulate(graph, ctx, int(ctx.get("mc_runs", DEFAULT_MC_RUNS)), rng)
	findings.append_array(_coverage_findings(graph, ctx))
	findings.append_array(_checkpoint_findings(flow))
	findings.append_array(_cold_edge_findings(graph, visits))

	return {
		"findings": findings,
		"coins": flow["coins"],
		"last_score": flow["last_score"],
		"visits": visits,
		"stats": _statistics(graph, ctx, flow, visits),
	}


# Journey-wide summary numbers for the report's stats strip. Route bounds come
# from the interval walk's end-node exits; averages from the Monte-Carlo pass.
# Returns {end_coins: {lo,hi,avg}, total_score: {lo,hi,avg}, rounds: {lo,hi,avg},
# duration_ms: {lo,hi}, best_round: {node_id, score}, endings: [{node_id, pct}],
# checkpoints: {count, shortest/longest_ms+_rounds, avg_ms},
# cp_bar: {total_ms, segments: [{ms, rounds}]} (worst-route save spacing)}.
static func _statistics(
	graph: Dictionary, ctx: Dictionary, flow: Dictionary, visits: Dictionary
) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var exits: Dictionary = flow.get("exits", {})

	# End nodes = reachable nodes with no out-edges.
	var end_coins: Dictionary = {}
	var total_score: Dictionary = {}
	var rounds: Dictionary = {}
	var duration: Dictionary = {}
	for id: String in exits:
		if not ((nodes[id] as Dictionary).get("out", []) as Array).is_empty():
			continue
		var e: Dictionary = exits[id]
		_widen(end_coins, e["coins"])
		_widen(total_score, e["total"])
		_widen(rounds, e["rounds"])
		_widen(duration, e["dur"])

	var best_round: Dictionary = {"node_id": "", "score": 0}
	var round_scores: Dictionary = ctx.get("round_scores", {})
	for id: String in round_scores:
		if exits.has(id) and int(round_scores[id]) > int(best_round["score"]):
			best_round = {"node_id": id, "score": int(round_scores[id])}

	var endings: Array = []
	var runs: int = maxi(1, int(visits.get("runs", 1)))
	for id: String in visits.get("endings", {}):
		endings.append(
			{"node_id": id, "pct": int((visits["endings"] as Dictionary)[id]) * 100.0 / runs}
		)
	endings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["pct"] > b["pct"])

	end_coins["avg"] = float(visits.get("avg_end_coins", 0.0))
	total_score["avg"] = float(visits.get("avg_total_score", 0.0))
	rounds["avg"] = float(visits.get("avg_rounds", 0.0))

	# Checkpoint spacing summary + the save-spacing bar's worst-route segments.
	var cp: Dictionary = flow.get("cp", {})
	var checkpoints: Dictionary = {
		"count": int(cp.get("count", 0)),
		"longest_ms": int(cp.get("max_ms", 0)),
		"longest_rounds": int(cp.get("max_rounds", 0)),
		"shortest_ms": maxi(0, int(cp.get("min_ms", 0))),
		"shortest_rounds": int(cp.get("min_rounds", 0)),
		"avg_ms": float(visits.get("avg_stretch_ms", 0.0)),
	}

	var round_lengths: Dictionary = ctx.get("round_lengths", {})
	var segments: Array = []
	var seg_ms: int = 0
	var seg_rounds: int = 0
	var total_ms: int = 0
	for id: String in worst_route(graph, round_lengths):
		var node: Dictionary = nodes[id]
		var ntype: String = str(node.get("type", ""))
		# A checkpoint NODE closes the running stretch; other non-round nodes are skipped.
		if ntype == "checkpoint":
			if seg_rounds > 0:
				segments.append({"ms": seg_ms, "rounds": seg_rounds})
				seg_ms = 0
				seg_rounds = 0
			continue
		if ntype != "round":
			continue
		seg_ms += int(round_lengths.get(id, 0))
		seg_rounds += 1
		total_ms += int(round_lengths.get(id, 0))
	if seg_rounds > 0:
		segments.append({"ms": seg_ms, "rounds": seg_rounds})

	return {
		"end_coins": end_coins,
		"total_score": total_score,
		"rounds": rounds,
		"duration_ms": duration,
		"best_round": best_round,
		"endings": endings,
		"checkpoints": checkpoints,
		"cp_bar": {"total_ms": total_ms, "segments": segments},
	}


# Records a completed checkpoint stretch as the shortest seen, when it is.
# Zero-round stretches (a checkpoint on the journey's first round) are noise.
static func _note_completed_stretch(cp: Dictionary, gap_r: Dictionary, gap_ms: Dictionary) -> void:
	if int(gap_r["lo"]) <= 0:
		return
	if int(cp["min_ms"]) < 0 or int(gap_ms["lo"]) < int(cp["min_ms"]):
		cp["min_ms"] = int(gap_ms["lo"])
		cp["min_rounds"] = int(gap_r["lo"])


# The start→end route with the greatest total round playtime (DAG longest path
# by duration) — the representative path for the save-spacing bar.
static func worst_route(graph: Dictionary, round_lengths: Dictionary) -> Array:
	var nodes: Dictionary = graph.get("nodes", {})
	var order: Array = topo_order(graph)
	var best_dur: Dictionary = {}
	var best_next: Dictionary = {}
	for i: int in range(order.size() - 1, -1, -1):
		var id: String = order[i]
		var node: Dictionary = nodes[id]
		var own: int = 0
		if str(node.get("type", "")) == "round":
			own = int(round_lengths.get(id, 0))
		var best: int = -1
		var nxt: String = ""
		for e: Dictionary in node.get("out", []):
			var to: String = str(e.get("to", ""))
			if best_dur.has(to) and int(best_dur[to]) > best:
				best = int(best_dur[to])
				nxt = to
		best_dur[id] = own + maxi(0, best)
		best_next[id] = nxt
	var route: Array = []
	var id: String = str(graph.get("start", ""))
	while id != "" and nodes.has(id) and route.size() <= order.size():
		route.append(id)
		id = str(best_next.get(id, ""))
	return route


# Widens `acc` ({lo, hi}, possibly empty) to cover the interval `iv`.
static func _widen(acc: Dictionary, iv: Dictionary) -> void:
	if acc.is_empty():
		acc["lo"] = int(iv["lo"])
		acc["hi"] = int(iv["hi"])
		return
	acc["lo"] = mini(int(acc["lo"]), int(iv["lo"]))
	acc["hi"] = maxi(int(acc["hi"]), int(iv["hi"]))


# The exact score a full completion of `actions` yields (ScoreService.AddStroke
# with no multipliers): every consecutive position delta bucketed small/medium/
# large. Actions are Vector2(at_ms, pos) points, time-sorted — the shape
# JourneyData.read_funscript_actions returns.
static func baseline_score(actions: Array) -> int:
	var score: int = 0
	for i: int in range(1, actions.size()):
		var amplitude: int = absi(roundi((actions[i] as Vector2).y - (actions[i - 1] as Vector2).y))
		if amplitude <= SCORE_SMALL_MAX:
			score += SCORE_SMALL_PTS
		elif amplitude <= SCORE_MEDIUM_MAX:
			score += SCORE_MEDIUM_PTS
		else:
			score += SCORE_LARGE_PTS
	return score


# Kahn topological order over the nodes reachable from start. Cycles can't be
# saved (validate_graph blocks them), but a mid-edit graph may contain one —
# nodes on a cycle simply drop out of the order, and the audit skips them.
static func topo_order(graph: Dictionary) -> Array:
	var nodes: Dictionary = graph.get("nodes", {})
	var reachable: Dictionary = {}
	var queue: Array = []
	var start: String = str(graph.get("start", ""))
	if nodes.has(start):
		queue.append(start)
		reachable[start] = true
	while not queue.is_empty():
		var id: String = queue.pop_back()
		for e: Dictionary in (nodes[id] as Dictionary).get("out", []):
			var to: String = str(e.get("to", ""))
			if nodes.has(to) and not reachable.has(to):
				reachable[to] = true
				queue.append(to)

	var in_deg: Dictionary = {}
	for id: String in reachable:
		if not in_deg.has(id):
			in_deg[id] = 0
		for e: Dictionary in (nodes[id] as Dictionary).get("out", []):
			var to: String = str(e.get("to", ""))
			if reachable.has(to):
				in_deg[to] = int(in_deg.get(to, 0)) + 1

	var order: Array = []
	var ready: Array = []
	for id: String in in_deg:
		if int(in_deg[id]) == 0:
			ready.append(id)
	while not ready.is_empty():
		var id: String = ready.pop_back()
		order.append(id)
		for e: Dictionary in (nodes[id] as Dictionary).get("out", []):
			var to: String = str(e.get("to", ""))
			if not in_deg.has(to):
				continue
			in_deg[to] = int(in_deg[to]) - 1
			if int(in_deg[to]) == 0:
				ready.append(to)
	return order


# ── Interval / set dataflow ──────────────────────────────────────────────────


# Worst/best coin delta a round completion applies, from its authored config.
# {lo, hi}: lo assumes the harshest possible coin curse (and, when the player
# could instead cleanse, whichever of enduring-worst vs paying-the-cleanse is
# poorer); hi assumes the kindest roll plus every possible coin boon and the
# endure reward. Fixed (non-random) curse/boon lists apply to BOTH bounds.
static func round_coin_interval(data: Dictionary, entry_lo: int, entry_hi: int) -> Dictionary:
	var payout: int = int(data.get("coins", 0))
	var round_type: String = str(data.get("round_type", "normal"))

	if round_type == "effect":
		return _effect_coin_interval(data, payout, entry_lo, entry_hi)

	# Normal/boss rounds: boss modifiers may carry coin effects (always applied).
	var lo: int = payout
	var hi: int = payout
	for mod: Dictionary in data.get("boss_modifiers", []):
		match str(mod.get("kind", "")):
			"coin_penalty":
				lo = roundi(lo * float(mod.get("factor", 1.0)))
				hi = roundi(hi * float(mod.get("factor", 1.0)))
			"toll":
				lo -= TOLL_AMOUNT
				hi -= TOLL_AMOUNT
	return {"lo": lo, "hi": hi}


# Coin interval for an effect round — the merged cursed/blessed model. The pool can
# mix hindrances (coin_penalty/toll) and boons (coin_jackpot/interest). Random mode
# rolls ONE from the pool (bound over each single outcome); fixed mode applies every
# listed effect together. When the round is resolvable, the endure reward is added and
# the cleanse alternative (full payout − cost, minus any toll that already hit) bounds
# the other side.
static func _effect_coin_interval(
	data: Dictionary, payout: int, entry_lo: int, entry_hi: int
) -> Dictionary:
	var pool: Array = _effect_pool(data)
	var random_roll: bool = bool(data.get("effect_random", true)) and pool.size() > 1
	var resolvable: bool = bool(data.get("resolvable", false))
	var reward: int = int(data.get("endure_reward", 0)) if resolvable else 0

	var lo: int
	var hi: int
	var toll_amount: int = 0  # the tuned toll a roll could inflict (one Toll entry per round)
	var toll_possible: bool
	var toll_certain: bool
	if random_roll:
		lo = 1 << 30
		hi = -(1 << 30)
		toll_possible = false
		toll_certain = true
		for e: Dictionary in pool:
			var o: Dictionary = _applied_coins([e], payout, entry_lo, entry_hi)
			lo = mini(lo, int(o["lo"]))
			hi = maxi(hi, int(o["hi"]))
			if int(o["toll"]) > 0:
				toll_possible = true
				toll_amount = int(o["toll"])
			else:
				toll_certain = false
	else:
		var o: Dictionary = _applied_coins(pool, payout, entry_lo, entry_hi)
		lo = int(o["lo"])
		hi = int(o["hi"])
		toll_amount = int(o["toll"])
		toll_possible = toll_amount > 0
		toll_certain = toll_amount > 0

	var endure_lo: int = lo + reward
	var endure_hi: int = hi + reward
	if not resolvable:
		return {"lo": endure_lo, "hi": endure_hi}

	# The player may cleanse instead: full payout, reward forfeited, cost paid (a rolled
	# toll already hit before the cleanse and isn't refunded).
	var cleanse_cost: int = int(data.get("cleanse_cost", 50))
	var cleanse_lo: int = payout - cleanse_cost - (toll_amount if toll_possible else 0)
	var cleanse_hi: int = payout - cleanse_cost - (toll_amount if toll_certain else 0)
	return {"lo": mini(endure_lo, cleanse_lo), "hi": maxi(endure_hi, cleanse_hi)}


# Coin outcome {lo, hi, toll} for one applied set of effects, before any endure reward.
# Magnitudes come from the (already override-resolved) entries: coin factor, toll amount,
# interest pct. `toll` is returned as the total AMOUNT (0 if none) so the cleanse path can
# subtract the tuned value.
static func _applied_coins(applied: Array, payout: int, entry_lo: int, entry_hi: int) -> Dictionary:
	var earned: int = payout
	var toll: int = 0
	var interest_frac: float = 0.0
	for e: Dictionary in applied:
		match str(e.get("kind", "")):
			"coin_penalty", "coin_jackpot":
				earned = roundi(earned * float(e.get("factor", 1.0)))
			"toll":
				toll += int(e.get("amount", TOLL_AMOUNT))
			"interest":
				interest_frac += float(e.get("pct", 0.25))
	return {
		"lo": earned - toll + roundi(entry_lo * interest_frac),
		"hi": earned - toll + roundi(entry_hi * interest_frac),
		"toll": toll,
	}


# The gameplay effect entries an effect round can roll — resolved against the round's
# per-effect overrides so tuned magnitudes (factor/toll amount/interest pct) feed the coin
# math. NONE ticked = no gameplay effect (empty pool → pure visual), matching GameLoop.
static func _effect_pool(data: Dictionary) -> Array:
	var names: Array = data.get("effects", [])
	var overrides: Dictionary = data.get("effect_overrides", {})
	var pool: Array = []
	for e: Dictionary in JourneyData.gameplay_effects():
		var nm: String = str(e.get("name", ""))
		if nm in names:
			pool.append(JourneyData.resolved_effect(nm, overrides))
	return pool


static func _pool_has_kind(pool: Array, kind: String) -> bool:
	for entry: Dictionary in pool:
		if str(entry.get("kind", "")) == kind:
			return true
	return false


# Returns a deep graph copy whose round nodes carry the canonical effect-round fields
# (legacy cursed/blessed migrated), so the whole audit reads one schema.
static func _normalize_rounds(graph: Dictionary) -> Dictionary:
	var out: Dictionary = graph.duplicate(true)
	var nodes: Dictionary = out.get("nodes", {})
	for id: String in nodes:
		var node: Dictionary = nodes[id]
		if str(node.get("type", "")) == "round":
			var data: Dictionary = node.get("data", {})
			data.merge(JourneyData.normalize_effect_round(data), true)
	return out


# Forward dataflow over the DAG. Returns per-node ENTRY states:
#   coins       {id: {lo, hi}}
#   last_score  {id: {lo, hi}}   (baseline score of the nearest upstream round)
#   guaranteed  {id: {item_id: true}}   items owned on EVERY route in
#   possible    {id: {item_id: true}}   items owned on SOME route in
#   flags       {id: {flag: true}}      flags settable on some route in
# plus "exits" — per-node EXIT accumulators {coins, total, rounds, dur} used by
# the statistics (total = cumulative baseline score, rounds = rounds completed,
# dur = summed funscript length in ms; all {lo, hi} route bounds).
static func _flow_analysis(graph: Dictionary, ctx: Dictionary) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var items: Dictionary = ctx.get("items", {})
	var round_scores: Dictionary = ctx.get("round_scores", {})
	var round_lengths: Dictionary = ctx.get("round_lengths", {})
	# Optional per-node ranges (pool rounds roll one entry, so their score/length is a range,
	# not a value). Absent for ordinary rounds → the flat score/length bounds itself.
	var round_score_bounds: Dictionary = ctx.get("round_score_bounds", {})
	var round_length_bounds: Dictionary = ctx.get("round_length_bounds", {})
	var order: Array = topo_order(graph)

	var coins: Dictionary = {}
	var last_score: Dictionary = {}
	var guaranteed: Dictionary = {}
	var possible: Dictionary = {}
	var flags: Dictionary = {}
	var exits: Dictionary = {}
	# Checkpoint spacing: worst gap anywhere + shortest COMPLETED stretch (a
	# stretch completes at a checkpoint round's start, or at a journey end).
	var cp: Dictionary = {
		"max_rounds": 0, "max_ms": 0, "at_node": "", "count": 0, "min_ms": -1, "min_rounds": 0
	}
	# Per-edge exit states, keyed "node_id:edge_idx", merged into successors.
	var edge_out: Dictionary = {}

	var start: String = str(graph.get("start", ""))
	for id: String in order:
		var node: Dictionary = nodes[id]
		var data: Dictionary = node.get("data", {})
		var type: String = str(node.get("type", ""))

		# Entry state = merge of predecessor edge exits (start seeds empty).
		var entry: Dictionary
		if id == start:
			entry = _zero_state()
		else:
			entry = _merge_incoming(nodes, order, edge_out, id)
		coins[id] = entry["coins"]
		last_score[id] = entry["score"]
		guaranteed[id] = entry["guaranteed"]
		possible[id] = entry["possible"]
		flags[id] = entry["flags"]

		# Node completion effects → exit state.
		var exit_coins: Dictionary = (entry["coins"] as Dictionary).duplicate()
		var exit_score: Dictionary = (entry["score"] as Dictionary).duplicate()
		var exit_total: Dictionary = (entry["total"] as Dictionary).duplicate()
		var exit_rounds: Dictionary = (entry["rounds"] as Dictionary).duplicate()
		var exit_dur: Dictionary = (entry["dur"] as Dictionary).duplicate()
		var exit_gap_r: Dictionary = (entry["gap_r"] as Dictionary).duplicate()
		var exit_gap_ms: Dictionary = (entry["gap_ms"] as Dictionary).duplicate()
		var exit_guar: Dictionary = (entry["guaranteed"] as Dictionary).duplicate()
		var exit_poss: Dictionary = (entry["possible"] as Dictionary).duplicate()
		var exit_flags: Dictionary = (entry["flags"] as Dictionary).duplicate()
		for f: String in JourneyData.clean_flag_list(data.get("set_flags", [])):
			exit_flags[f] = true

		match type:
			"round":
				var delta: Dictionary = round_coin_interval(
					data, int(exit_coins["lo"]), int(exit_coins["hi"])
				)
				exit_coins["lo"] = maxi(0, int(exit_coins["lo"]) + int(delta["lo"]))
				exit_coins["hi"] = maxi(0, int(exit_coins["hi"]) + int(delta["hi"]))
				# Score / length bound the round. Ordinary rounds are a single value; a pool
				# round's depends on which entry is rolled, so it supplies a real {lo, hi}.
				var s: int = int(round_scores.get(id, 0))
				var sb: Dictionary = round_score_bounds.get(id, {"lo": s, "hi": s})
				var s_lo: int = int(sb.get("lo", s))
				var s_hi: int = int(sb.get("hi", s))
				exit_score = {"lo": s_lo, "hi": s_hi}
				exit_total["lo"] = int(exit_total["lo"]) + s_lo
				exit_total["hi"] = int(exit_total["hi"]) + s_hi
				exit_rounds["lo"] = int(exit_rounds["lo"]) + 1
				exit_rounds["hi"] = int(exit_rounds["hi"]) + 1
				var ms: int = int(round_lengths.get(id, 0))
				var lb: Dictionary = round_length_bounds.get(id, {"lo": ms, "hi": ms})
				exit_dur["lo"] = int(exit_dur["lo"]) + int(lb.get("lo", ms))
				exit_dur["hi"] = int(exit_dur["hi"]) + int(lb.get("hi", ms))
				# Save spacing: a round always extends the current stretch (a checkpoint NODE,
				# handled below, is what resets it).
				exit_gap_r["lo"] = int(exit_gap_r["lo"]) + 1
				exit_gap_r["hi"] = int(exit_gap_r["hi"]) + 1
				exit_gap_ms["lo"] = int(exit_gap_ms["lo"]) + int(lb.get("lo", ms))
				exit_gap_ms["hi"] = int(exit_gap_ms["hi"]) + int(lb.get("hi", ms))
				if int(exit_gap_ms["hi"]) > int(cp["max_ms"]):
					cp["max_ms"] = int(exit_gap_ms["hi"])
					cp["max_rounds"] = int(exit_gap_r["hi"])
					cp["at_node"] = id
				if str(data.get("round_type", "")) == "effect":
					var gift: String = str(data.get("gift_item", ""))
					if gift != "" and _pool_has_kind(_effect_pool(data), "gift"):
						exit_poss[gift] = true
						if not bool(data.get("effect_random", true)):
							exit_guar[gift] = true
			"storyboard":
				exit_coins["lo"] = int(exit_coins["lo"]) + int(data.get("coins", 0))
				exit_coins["hi"] = int(exit_coins["hi"]) + int(data.get("coins", 0))
				var reward: String = str(data.get("item", ""))
				if reward != "":
					exit_guar[reward] = true
					exit_poss[reward] = true
			"shop":
				# Coins assume no purchase; availability assumes the player buys
				# what's guaranteed and worst-case affordable (class doc).
				var mult: float = float(data.get("price_multiplier", 1.0))
				var all_ids: Array = items.keys()
				all_ids.sort()
				for iid: String in JourneyData.shop_guaranteed_ids(data, all_ids):
					if _shop_price(items, iid, mult) <= int(exit_coins["lo"]):
						exit_guar[iid] = true
				for iid: String in JourneyData.shop_possible_ids(data, all_ids):
					if _shop_price(items, iid, mult) <= int(exit_coins["hi"]):
						exit_poss[iid] = true
			"checkpoint":
				# A save point closes the current stretch and starts a fresh one at zero.
				cp["count"] = int(cp["count"]) + 1
				_note_completed_stretch(cp, entry["gap_r"], entry["gap_ms"])
				exit_gap_r = {"lo": 0, "hi": 0}
				exit_gap_ms = {"lo": 0, "hi": 0}

		exits[id] = {
			"coins": exit_coins,
			"total": exit_total,
			"rounds": exit_rounds,
			"dur": exit_dur,
		}

		# A journey end completes the final stretch (no checkpoint closes it).
		if (node.get("out", []) as Array).is_empty():
			_note_completed_stretch(cp, exit_gap_r, exit_gap_ms)

		# Per-edge exits (sacrifice choices spend on the way out).
		var out: Array = node.get("out", [])
		var resolution: String = str(data.get("resolution", ""))
		for ei: int in out.size():
			var e: Dictionary = out[ei]
			var e_coins: Dictionary = exit_coins.duplicate()
			var e_guar: Dictionary = exit_guar.duplicate()
			var e_poss: Dictionary = exit_poss.duplicate()
			var e_flags: Dictionary = exit_flags.duplicate()
			if type == "fork":
				for f: String in JourneyData.clean_flag_list(e.get("set_flags", [])):
					e_flags[f] = true
				if resolution == "sacrifice":
					var cost: int = int(e.get("cost", 0))
					e_coins["lo"] = maxi(0, int(e_coins["lo"]) - cost)
					e_coins["hi"] = maxi(0, int(e_coins["hi"]) - cost)
					var req: String = str(e.get("required_item", ""))
					if req != "":
						e_guar.erase(req)
						e_poss.erase(req)
			edge_out["%s:%d" % [id, ei]] = {
				"to": str(e.get("to", "")),
				"coins": e_coins,
				"score": exit_score,
				"total": exit_total.duplicate(),
				"rounds": exit_rounds.duplicate(),
				"dur": exit_dur.duplicate(),
				"gap_r": exit_gap_r.duplicate(),
				"gap_ms": exit_gap_ms.duplicate(),
				"guaranteed": e_guar,
				"possible": e_poss,
				"flags": e_flags,
			}

	return {
		"coins": coins,
		"last_score": last_score,
		"guaranteed": guaranteed,
		"possible": possible,
		"flags": flags,
		"exits": exits,
		"cp": cp,
	}


# The interval quantities a dataflow state carries (each {lo, hi}). gap_r /
# gap_ms track rounds/playtime since the last checkpoint (reset by one).
const _INTERVAL_KEYS: Array = ["coins", "score", "total", "rounds", "dur", "gap_r", "gap_ms"]


static func _zero_state() -> Dictionary:
	var state: Dictionary = {"guaranteed": {}, "possible": {}, "flags": {}}
	for k: String in _INTERVAL_KEYS:
		state[k] = {"lo": 0, "hi": 0}
	return state


static func _shop_price(items: Dictionary, item_id: String, mult: float) -> int:
	return int(round(float((items.get(item_id, {}) as Dictionary).get("price", 0)) * mult))


# Merges every predecessor edge-exit that targets `id`: intervals widen
# (min lo / max hi), guaranteed intersects, possible + flags union.
static func _merge_incoming(
	nodes: Dictionary, order: Array, edge_out: Dictionary, id: String
) -> Dictionary:
	var merged: Dictionary = {}
	for pred: String in order:
		var out: Array = (nodes[pred] as Dictionary).get("out", [])
		for ei: int in out.size():
			var key: String = "%s:%d" % [pred, ei]
			if not edge_out.has(key) or str((edge_out[key] as Dictionary)["to"]) != id:
				continue
			var e: Dictionary = edge_out[key]
			if merged.is_empty():
				merged = {
					"guaranteed": (e["guaranteed"] as Dictionary).duplicate(),
					"possible": (e["possible"] as Dictionary).duplicate(),
					"flags": (e["flags"] as Dictionary).duplicate(),
				}
				for k: String in _INTERVAL_KEYS:
					merged[k] = (e[k] as Dictionary).duplicate()
				continue
			for k: String in _INTERVAL_KEYS:
				var m: Dictionary = merged[k]
				m["lo"] = mini(int(m["lo"]), int((e[k] as Dictionary)["lo"]))
				m["hi"] = maxi(int(m["hi"]), int((e[k] as Dictionary)["hi"]))
			var still_guaranteed: Dictionary = {}
			for iid: String in merged["guaranteed"]:
				if (e["guaranteed"] as Dictionary).has(iid):
					still_guaranteed[iid] = true
			merged["guaranteed"] = still_guaranteed
			for iid: String in e["possible"]:
				(merged["possible"] as Dictionary)[iid] = true
			for f: String in e["flags"]:
				(merged["flags"] as Dictionary)[f] = true
	if merged.is_empty():
		merged = _zero_state()
	return merged


# ── Gate findings ────────────────────────────────────────────────────────────


static func _gate_findings(graph: Dictionary, ctx: Dictionary, flow: Dictionary) -> Array:
	var nodes: Dictionary = graph.get("nodes", {})
	var items: Dictionary = ctx.get("items", {})
	var findings: Array = []

	for id: String in topo_order(graph):
		var node: Dictionary = nodes[id]
		var data: Dictionary = node.get("data", {})
		var type: String = str(node.get("type", ""))
		var in_coins: Dictionary = flow["coins"].get(id, {"lo": 0, "hi": 0})

		if type == "fork":
			findings.append_array(_fork_findings(id, node, flow))
		elif type == "shop":
			var mult: float = float(data.get("price_multiplier", 1.0))
			var all_ids: Array = items.keys()
			all_ids.sort()
			var guar: Array = JourneyData.shop_guaranteed_ids(data, all_ids)
			if not guar.is_empty():
				var cheapest: int = _shop_price(items, guar[0], mult)
				for iid: String in guar:
					cheapest = mini(cheapest, _shop_price(items, iid, mult))
				if cheapest > int(in_coins["hi"]):
					(
						findings
						. append(
							{
								"severity": SEV_WARN,
								"kind": "shop_unaffordable",
								"node_id": id,
								"edge_idx": -1,
								"msg":
								(
									"Nothing guaranteed here is ever affordable (cheapest ♦%d, best-case coins ♦%d)."
									% [cheapest, int(in_coins["hi"])]
								),
							}
						)
					)
		elif type == "round" and bool(data.get("resolvable", false)):
			var cleanse: int = int(data.get("cleanse_cost", 50))
			if cleanse > int(in_coins["lo"]):
				(
					findings
					. append(
						{
							"severity": SEV_INFO,
							"kind": "cleanse_unaffordable",
							"node_id": id,
							"edge_idx": -1,
							"msg":
							(
								"Cleansing (♦%d) may be unaffordable — worst-case coins here are ♦%d."
								% [cleanse, int(in_coins["lo"])]
							),
						}
					)
				)
	return findings


static func _fork_findings(id: String, node: Dictionary, flow: Dictionary) -> Array:
	var data: Dictionary = node.get("data", {})
	var out: Array = node.get("out", [])
	var resolution: String = str(data.get("resolution", "choice"))
	var findings: Array = []
	var in_coins: Dictionary = flow["coins"].get(id, {"lo": 0, "hi": 0})
	var in_score: Dictionary = flow["last_score"].get(id, {"lo": 0, "hi": 0})
	var guar: Dictionary = flow["guaranteed"].get(id, {})
	var poss: Dictionary = flow["possible"].get(id, {})
	var in_flags: Dictionary = flow["flags"].get(id, {})

	for ei: int in out.size():
		var e: Dictionary = out[ei]
		var path: String = str(e.get("name", "path %d" % (ei + 1)))

		if resolution == "sacrifice":
			var cost: int = int(e.get("cost", 0))
			var req: String = str(e.get("required_item", ""))
			if cost > int(in_coins["hi"]):
				(
					findings
					. append(
						_finding(
							SEV_DEAD,
							"sacrifice_cost",
							id,
							ei,
							(
								'"%s" costs ♦%d but the best-case balance here is ♦%d — it can never be taken.'
								% [path, cost, int(in_coins["hi"])]
							)
						)
					)
				)
			elif cost > int(in_coins["lo"]) and cost > 0:
				findings.append(
					_finding(
						SEV_WARN,
						"sacrifice_cost",
						id,
						ei,
						(
							'"%s" (♦%d) is unaffordable on some routes (worst case ♦%d).'
							% [path, cost, int(in_coins["lo"])]
						)
					)
				)
			if req != "":
				if not poss.has(req):
					findings.append(
						_finding(
							SEV_DEAD,
							"item_gate",
							id,
							ei,
							'"%s" requires "%s", which no route here can ever grant.' % [path, req]
						)
					)
				elif not guar.has(req):
					findings.append(
						_finding(
							SEV_WARN,
							"item_gate",
							id,
							ei,
							'"%s" requires "%s", which is only sometimes owned here.' % [path, req]
						)
					)

		elif resolution == "conditional":
			var metric: String = str(data.get("cond_metric", "score"))
			match metric:
				"score":
					var t: int = int(e.get("threshold", 0))
					if t > 0 and t > int(in_score["hi"]):
						(
							findings
							. append(
								_finding(
									SEV_DEAD,
									"score_gate",
									id,
									ei,
									(
										'"%s" needs a last-round score of %d, but the best possible is %d (barring score boons/items).'
										% [path, t, int(in_score["hi"])]
									)
								)
							)
						)
					elif t > 0 and t > int(in_score["lo"]):
						(
							findings
							. append(
								_finding(
									SEV_INFO,
									"score_gate",
									id,
									ei,
									(
										'"%s" (score ≥ %d) is only reachable via some routes (worst-route best score %d).'
										% [path, t, int(in_score["lo"])]
									)
								)
							)
						)
				"coins":
					var t: int = int(e.get("threshold", 0))
					if t > 0 and t > int(in_coins["hi"]):
						findings.append(
							_finding(
								SEV_DEAD,
								"coin_gate",
								id,
								ei,
								(
									'"%s" needs ♦%d, but the best-case balance here is ♦%d.'
									% [path, t, int(in_coins["hi"])]
								)
							)
						)
				"item":
					var req: String = str(e.get("required_item", ""))
					if req != "" and not poss.has(req):
						findings.append(
							_finding(
								SEV_DEAD,
								"item_gate",
								id,
								ei,
								(
									'"%s" checks for "%s", which no route here can ever grant.'
									% [path, req]
								)
							)
						)
					elif req != "" and not guar.has(req):
						findings.append(
							_finding(
								SEV_INFO,
								"item_gate",
								id,
								ei,
								(
									'"%s" checks for "%s", which is only sometimes owned here.'
									% [path, req]
								)
							)
						)
				"flag":
					var rf: String = str(e.get("required_flag", ""))
					if rf != "" and not in_flags.has(rf):
						findings.append(
							_finding(
								SEV_DEAD,
								"flag_gate",
								id,
								ei,
								(
									'"%s" requires flag "%s", but no route into this fork sets it.'
									% [path, rf]
								)
							)
						)
	return findings


static func _finding(
	severity: String, kind: String, node_id: String, edge_idx: int, msg: String
) -> Dictionary:
	return {
		"severity": severity, "kind": kind, "node_id": node_id, "edge_idx": edge_idx, "msg": msg
	}


# ── Coverage findings ────────────────────────────────────────────────────────


# The inverse of the gate checks: authored content that nothing consumes.
# Orphan flags (set but never required by any fork choice) and unused gate
# items (key-kind items granted/stocked but never required — items with their
# own effects, like Cleanse, are exempt: not being gated isn't waste for them).
static func _coverage_findings(graph: Dictionary, ctx: Dictionary) -> Array:
	var nodes: Dictionary = graph.get("nodes", {})
	var items: Dictionary = ctx.get("items", {})
	var findings: Array = []

	var flag_set_at: Dictionary = {}  # flag → first setter node id
	var flags_required: Dictionary = {}
	var key_source_at: Dictionary = {}  # item_id → first source node id (key-kind only)
	var items_required: Dictionary = {}

	for id: String in topo_order(graph):
		var node: Dictionary = nodes[id]
		var data: Dictionary = node.get("data", {})
		for f: String in JourneyData.clean_flag_list(data.get("set_flags", [])):
			if not flag_set_at.has(f):
				flag_set_at[f] = id
		match str(node.get("type", "")):
			"storyboard":
				_note_key_source(key_source_at, items, str(data.get("item", "")), id)
			"round":
				if (
					str(data.get("round_type", "")) == "effect"
					and _pool_has_kind(_effect_pool(data), "gift")
				):
					_note_key_source(key_source_at, items, str(data.get("gift_item", "")), id)
			"shop":
				var all_ids: Array = items.keys()
				all_ids.sort()
				for iid: String in JourneyData.shop_guaranteed_ids(data, all_ids):
					_note_key_source(key_source_at, items, iid, id)
		for e: Dictionary in node.get("out", []):
			for f: String in JourneyData.clean_flag_list(e.get("set_flags", [])):
				if not flag_set_at.has(f):
					flag_set_at[f] = id
			if str(e.get("required_flag", "")) != "":
				flags_required[str(e["required_flag"])] = true
			if str(e.get("required_item", "")) != "":
				items_required[str(e["required_item"])] = true

	for f: String in flag_set_at:
		if not flags_required.has(f):
			findings.append(
				_finding(
					SEV_INFO,
					"flag_unused",
					str(flag_set_at[f]),
					-1,
					'Flag "%s" is set here, but nothing in the journey ever checks it.' % f
				)
			)
	for iid: String in key_source_at:
		if not items_required.has(iid):
			findings.append(
				_finding(
					SEV_INFO,
					"item_unused",
					str(key_source_at[iid]),
					-1,
					'"%s" is granted/stocked here, but no fork path ever requires it.' % iid
				)
			)
	return findings


# Records `node_id` as the first source of `item_id` when the item is a pure
# gate item (registry kind "key").
static func _note_key_source(
	sources: Dictionary, items: Dictionary, item_id: String, node_id: String
) -> void:
	if item_id == "" or sources.has(item_id):
		return
	if str((items.get(item_id, {}) as Dictionary).get("kind", "")) != "key":
		return
	sources[item_id] = node_id


# Checkpoint spacing: the flow analysis tracked the worst stretch (any route)
# without a checkpoint; over CHECKPOINT_GAP_MS of playtime earns an INFO.
static func _checkpoint_findings(flow: Dictionary) -> Array:
	var cp: Dictionary = flow.get("cp", {})
	if int(cp.get("max_ms", 0)) <= CHECKPOINT_GAP_MS:
		return []
	var minutes: int = roundi(int(cp["max_ms"]) / 60000.0)
	var msg: String
	if int(cp.get("count", 0)) == 0:
		msg = (
			"No checkpoints — a worst-case route runs ~%d min (%d rounds) without a save point."
			% [minutes, int(cp["max_rounds"])]
		)
	else:
		msg = (
			"Longest stretch without a checkpoint ends here: %d rounds / ~%d min (worst route)."
			% [int(cp["max_rounds"]), minutes]
		)
	return [_finding(SEV_INFO, "checkpoint_gap", str(cp.get("at_node", "")), -1, msg)]


# ── Monte-Carlo simulation ───────────────────────────────────────────────────


# Items required by some fork choice at-or-below each node ({node_id:
# {item_id: true}}), by reverse dataflow over the topo order. Drives the sim's
# gate-purchase policy: a shop visit only buys what a reachable fork ahead needs.
static func _items_needed_below(graph: Dictionary) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var order: Array = topo_order(graph)
	var needed: Dictionary = {}
	for i: int in range(order.size() - 1, -1, -1):
		var id: String = order[i]
		var acc: Dictionary = {}
		for e: Dictionary in (nodes[id] as Dictionary).get("out", []):
			var req: String = str(e.get("required_item", ""))
			if req != "":
				acc[req] = true
			var to: String = str(e.get("to", ""))
			if needed.has(to):
				for iid: String in needed[to]:
					acc[iid] = true
		needed[id] = acc
	return needed


# Plays `runs` baseline runs and counts traffic + end-of-run outcomes. Returns
# {runs, nodes: {id: visits}, edges: {"id:edge_idx": visits},
#  endings: {end_node_id: run_count},
#  avg_end_coins, avg_total_score, avg_rounds (means over completed runs),
#  avg_stretch_ms (mean checkpoint stretch),
#  avg_arrival_coins / avg_arrival_score: {id: mean state arriving at node}}.
static func simulate(
	graph: Dictionary, ctx: Dictionary, runs: int, rng: RandomNumberGenerator
) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var round_scores: Dictionary = ctx.get("round_scores", {})
	var round_lengths: Dictionary = ctx.get("round_lengths", {})
	var items: Dictionary = ctx.get("items", {})
	var all_item_ids: Array = items.keys()
	all_item_ids.sort()
	var needed_below: Dictionary = _items_needed_below(graph)
	var start: String = str(graph.get("start", ""))
	var node_visits: Dictionary = {}
	var edge_visits: Dictionary = {}
	var endings: Dictionary = {}
	var arrive_coins: Dictionary = {}
	var arrive_score: Dictionary = {}
	var sum_coins: int = 0
	var sum_total: int = 0
	var sum_rounds: int = 0
	var completed: int = 0
	var stretch_total_ms: int = 0
	var stretch_count: int = 0
	var step_cap: int = nodes.size() * 4  # cycle guard for mid-edit graphs

	for _run: int in runs:
		var coins: int = 0
		var score: int = 0
		var total_score: int = 0
		var rounds_seen: int = 0
		var seg_ms: int = 0
		var seg_rounds: int = 0
		var owned: Dictionary = {}  # item_id → count
		var run_flags: Dictionary = {}
		var id: String = start
		var steps: int = 0

		while nodes.has(id) and steps < step_cap:
			steps += 1
			node_visits[id] = int(node_visits.get(id, 0)) + 1
			# Arrival state (before this node's effects) — the side panel's
			# "on arrival" averages divide these by the visit count.
			arrive_coins[id] = int(arrive_coins.get(id, 0)) + coins
			arrive_score[id] = int(arrive_score.get(id, 0)) + score
			var node: Dictionary = nodes[id]
			var data: Dictionary = node.get("data", {})
			var type: String = str(node.get("type", ""))
			for f: String in JourneyData.clean_flag_list(data.get("set_flags", [])):
				run_flags[f] = true

			match type:
				"round":
					coins = maxi(0, coins + _roll_round_coins(data, coins, owned, rng))
					score = int(round_scores.get(id, 0))
					total_score += score
					rounds_seen += 1
					seg_ms += int(round_lengths.get(id, 0))
					seg_rounds += 1
				"checkpoint":
					# A save point closes the current stretch (segments run between saves).
					if seg_rounds > 0:
						stretch_total_ms += seg_ms
						stretch_count += 1
						seg_ms = 0
						seg_rounds = 0
				"storyboard":
					coins += int(data.get("coins", 0))
					var reward: String = str(data.get("item", ""))
					if reward != "":
						owned[reward] = int(owned.get(reward, 0)) + 1
				"shop":
					# Gate-purchase policy: buy an offered item some fork ahead
					# requires, when affordable and not already held. The lineup
					# is rolled per run, so pool-mode randomness carries through.
					var mult: float = float(data.get("price_multiplier", 1.0))
					var offer: Array = JourneyData.resolve_shop_offer(data, all_item_ids, rng)
					for iid: String in offer:
						if not (needed_below.get(id, {}) as Dictionary).has(iid):
							continue
						if int(owned.get(iid, 0)) > 0:
							continue
						var price: int = _shop_price(items, iid, mult)
						if coins >= price:
							coins -= price
							owned[iid] = int(owned.get(iid, 0)) + 1

			var out: Array = node.get("out", [])
			if out.is_empty():
				# The run ends here — record the ending and the outcome sums.
				endings[id] = int(endings.get(id, 0)) + 1
				sum_coins += coins
				sum_total += total_score
				sum_rounds += rounds_seen
				completed += 1
				if seg_rounds > 0:
					stretch_total_ms += seg_ms
					stretch_count += 1
				break
			var ei: int = _pick_edge(data, out, type, coins, score, owned, run_flags, rng)
			var e: Dictionary = out[ei]
			for f: String in JourneyData.clean_flag_list(e.get("set_flags", [])):
				run_flags[f] = true
			if type == "fork" and str(data.get("resolution", "")) == "sacrifice":
				coins = maxi(0, coins - int(e.get("cost", 0)))
				var req: String = str(e.get("required_item", ""))
				if req != "" and int(owned.get(req, 0)) > 0:
					owned[req] = int(owned[req]) - 1
			var key: String = "%s:%d" % [id, ei]
			edge_visits[key] = int(edge_visits.get(key, 0)) + 1
			id = str(e.get("to", ""))

	var avg_arrival_coins: Dictionary = {}
	var avg_arrival_score: Dictionary = {}
	for id: String in node_visits:
		var v: int = maxi(1, int(node_visits[id]))
		avg_arrival_coins[id] = float(arrive_coins.get(id, 0)) / v
		avg_arrival_score[id] = float(arrive_score.get(id, 0)) / v

	var denom: int = maxi(1, completed)
	return {
		"runs": runs,
		"nodes": node_visits,
		"edges": edge_visits,
		"endings": endings,
		"avg_end_coins": float(sum_coins) / denom,
		"avg_total_score": float(sum_total) / denom,
		"avg_rounds": float(sum_rounds) / denom,
		"avg_stretch_ms": float(stretch_total_ms) / maxi(1, stretch_count),
		"avg_arrival_coins": avg_arrival_coins,
		"avg_arrival_score": avg_arrival_score,
	}


# One simulated round's coin delta under the baseline model (endure, never
# cleanse). Rolls a random curse/boon the way GameLoop does (uniform from the
# authored pool, or the whole catalog when none are ticked).
static func _roll_round_coins(
	data: Dictionary, balance: int, owned: Dictionary, rng: RandomNumberGenerator
) -> int:
	var payout: int = int(data.get("coins", 0))
	match str(data.get("round_type", "normal")):
		"effect":
			var pool: Array = _effect_pool(data)
			var applied: Array = pool
			if bool(data.get("effect_random", true)) and not pool.is_empty():
				applied = [pool[rng.randi_range(0, pool.size() - 1)]]
			var reward: int = (
				int(data.get("endure_reward", 0)) if bool(data.get("resolvable", false)) else 0
			)
			var delta: int = payout + reward
			for e: Dictionary in applied:
				match str(e.get("kind", "")):
					"coin_penalty":
						delta -= payout - roundi(payout * float(e.get("factor", 1.0)))
					"coin_jackpot":
						delta += roundi(payout * float(e.get("factor", 1.0))) - payout
					"toll":
						delta -= int(e.get("amount", TOLL_AMOUNT))
					"interest":
						delta += roundi(balance * float(e.get("pct", 0.25)))
					"gift":
						var gift: String = str(data.get("gift_item", ""))
						if gift != "":
							owned[gift] = int(owned.get(gift, 0)) + 1
			return delta
		_:
			var delta: int = payout
			for mod: Dictionary in data.get("boss_modifiers", []):
				match str(mod.get("kind", "")):
					"coin_penalty":
						delta = roundi(delta * float(mod.get("factor", 1.0)))
					"toll":
						delta -= TOLL_AMOUNT
			return delta


# Picks the out-edge a baseline run takes, mirroring the runtime resolvers.
static func _pick_edge(
	data: Dictionary,
	out: Array,
	type: String,
	coins: int,
	score: int,
	owned: Dictionary,
	run_flags: Dictionary,
	rng: RandomNumberGenerator
) -> int:
	if type != "fork" or out.size() <= 1:
		return 0 if out.size() <= 1 else rng.randi_range(0, out.size() - 1)

	var is_owned := func(item_id: String) -> bool: return int(owned.get(item_id, 0)) > 0
	var has_flag := func(flag: String) -> bool: return run_flags.has(flag)

	match str(data.get("resolution", "choice")):
		"random":
			var weights: Array = []
			var total: int = 0
			for e: Dictionary in out:
				weights.append(int(e.get("weight", 1)))
				total += maxi(0, int(e.get("weight", 1)))
			if total <= 0:
				return rng.randi_range(0, out.size() - 1)
			return ForkResolver.weighted_pick(weights, rng.randi_range(0, total - 1))
		"conditional":
			var metric: String = str(data.get("cond_metric", "score"))
			var value: int = score if metric == "score" else coins
			var checker: Callable = has_flag if metric == "flag" else is_owned
			return ForkResolver.conditional_path(
				out, metric, int(data.get("default_path", 0)), value, checker
			)
		"sacrifice":
			var affordable: Array = []
			for ei: int in out.size():
				var e: Dictionary = out[ei]
				if ForkResolver.path_affordable(
					int(e.get("cost", 0)), str(e.get("required_item", "")), coins, is_owned
				):
					affordable.append(ei)
			if affordable.is_empty():
				return 0
			return affordable[rng.randi_range(0, affordable.size() - 1)]
		_:  # player choice — uniform
			return rng.randi_range(0, out.size() - 1)


static func _cold_edge_findings(graph: Dictionary, visits: Dictionary) -> Array:
	var findings: Array = []
	var runs: int = maxi(1, int(visits.get("runs", 1)))
	var nodes: Dictionary = graph.get("nodes", {})
	for key: String in visits.get("edges", {}):
		var count: int = int((visits["edges"] as Dictionary)[key])
		var pct: float = count * 100.0 / runs
		if pct < COLD_EDGE_PCT:
			var parts: PackedStringArray = key.split(":")
			var node_id: String = parts[0]
			var ei: int = int(parts[1])
			# Only fork choices are interesting — a linear edge under 2% means
			# its whole subtree is cold, which the fork edge above it explains.
			if str((nodes.get(node_id, {}) as Dictionary).get("type", "")) != "fork":
				continue
			(
				findings
				. append(
					_finding(
						SEV_INFO,
						"cold_path",
						node_id,
						ei,
						(
							"This choice was taken in %.1f%% of %d simulated runs — content behind it is rarely seen."
							% [pct, runs]
						)
					)
				)
			)
	return findings
