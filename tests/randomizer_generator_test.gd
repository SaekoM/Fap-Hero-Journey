extends GdUnitTestSuite

# RandomizerGenerator — the pure, seeded run generator. Every test feeds a
# synthetic library (no disk / no MediaPoolService) and asserts on the emitted
# Format-2 journey dict. Determinism, no-repeat, both length modes, injected
# systems (effect / boss / shop), tag filtering, intensity ordering,
# and structural graph validity.

# ── Fixtures ─────────────────────────────────────────────────────────────────


func _entry(
	id: String, dur_ms: int, intensity: int, weight: float = 1.0, tags: Array = []
) -> Dictionary:
	return {
		"id": id,
		"name": id,
		"video_rel": "content/m_%s.mp4" % id,
		"funscript_rel": "content/m_%s.funscript" % id,
		"axis_rel": {},
		"vib_rel": {},
		"boss_image_rel": "",
		"action_count": 100,
		"length_ms": dur_ms,
		"duration_ms": dur_ms,
		"tags": tags,
		"weight": weight,
		"intensity": intensity,
		"last_used": 0,
	}


# A library of `n` clips, each 60s, mid intensity.
func _library(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(_entry("c%02d" % i, 60000, 3))
	return out


# Follows the graph's forward edges from Start, returning node dicts in play order.
func _sequence(journey: Dictionary) -> Array:
	var by_id: Dictionary = {}
	for node: Dictionary in journey.get("Nodes", []):
		by_id[str(node["id"])] = node
	var out: Array = []
	var cur: String = str(journey.get("Start", ""))
	var guard: int = 0
	while cur != "" and by_id.has(cur) and guard < 10000:
		var n: Dictionary = by_id[cur]
		out.append(n)
		var edges: Array = n.get("out", [])
		cur = str((edges[0] as Dictionary).get("to", "")) if not edges.is_empty() else ""
		guard += 1
	return out


func _rounds(journey: Dictionary) -> Array:
	return _sequence(journey).filter(func(n: Dictionary) -> bool: return str(n["type"]) == "round")


# ── Tests ────────────────────────────────────────────────────────────────────


func test_empty_library_fails() -> void:
	var res: Dictionary = RandomizerGenerator.generate([], {"seed": 1})
	assert_bool(res["ok"]).is_false()
	assert_str(res["reason"]).is_equal("empty_library")


func test_count_mode_produces_n_rounds() -> void:
	var res: Dictionary = RandomizerGenerator.generate(
		_library(10), {"seed": 7, "length_mode": "count", "round_count": 6}
	)
	assert_bool(res["ok"]).is_true()
	assert_int(_rounds(res["journey"]).size()).is_equal(6)
	assert_int(int((res["summary"] as Dictionary)["rounds"])).is_equal(6)


func test_count_capped_by_library_and_no_repeat() -> void:
	# Ask for more than the library holds → capped, and every clip is unique.
	var res: Dictionary = RandomizerGenerator.generate(
		_library(4), {"seed": 3, "length_mode": "count", "round_count": 10}
	)
	var rounds: Array = _rounds(res["journey"])
	assert_int(rounds.size()).is_equal(4)
	var seen: Dictionary = {}
	for r: Dictionary in rounds:
		var rel: String = str((r["data"] as Dictionary)["video_path"])
		assert_bool(seen.has(rel)).is_false()  # no clip reused within a run
		seen[rel] = true


# unique_sources: with cutting on, several parts share one video file. Off, a run may draw more
# than one; on, it caps at one clip per video.
func test_unique_sources_limits_to_one_per_video() -> void:
	var lib: Array = []  # 2 videos × 3 parts each, parts sharing their video's file
	for v: int in 2:
		for p: int in 3:
			var e: Dictionary = _entry("v%d#p%d" % [v, p], 60000, 3)
			e["video_src"] = "res://clips/video_%d.mp4" % v
			e["source_id"] = "v%d" % v
			lib.append(e)

	# Off: 6 entries drawn without replacement → the same video repeats.
	var loose: Dictionary = RandomizerGenerator.generate(
		lib, {"seed": 5, "round_count": 6, "unique_sources": false}
	)
	assert_int((loose["used_ids"] as Array).size()).is_equal(6)

	# On: one clip per video → caps at the 2 distinct videos.
	var strict: Dictionary = RandomizerGenerator.generate(
		lib, {"seed": 5, "round_count": 6, "unique_sources": true}
	)
	assert_int((strict["used_ids"] as Array).size()).is_equal(2)


# The same video imported from two folders is two entries with DIFFERENT fingerprints (the
# fingerprint keys on the path), so a fingerprint-based cap would miss them. The filename key still
# treats them as one video.
func test_unique_sources_dedups_same_filename_across_paths() -> void:
	var a: Dictionary = _entry("fp_a", 60000, 3)
	a["video_src"] = "res://folderA/movie.mp4"
	var b: Dictionary = _entry("fp_b", 60000, 3)
	b["video_src"] = "res://folderB/movie.mp4"  # same file name, different path → different id
	var res: Dictionary = RandomizerGenerator.generate(
		[a, b], {"seed": 1, "round_count": 4, "unique_sources": true}
	)
	assert_int((res["used_ids"] as Array).size()).is_equal(1)


# include_vib_only gates vibrator-only clips (a vibration script, no stroke) in or out of a run.
func test_include_vib_only_filters_vibrator_clips() -> void:
	var lib: Array = []
	for i: int in 3:
		lib.append(_entry("stroke%d" % i, 60000, 3))
	var vib: Dictionary = _entry("vib0", 60000, 3)
	vib["vib_only"] = true
	lib.append(vib)

	# Off: the vibrator-only clip never appears — only the 3 stroke clips.
	var without: Dictionary = RandomizerGenerator.generate(
		lib, {"seed": 2, "round_count": 4, "include_vib_only": false}
	)
	assert_bool((without["used_ids"] as Array).has("vib0")).is_false()
	assert_int((without["used_ids"] as Array).size()).is_equal(3)

	# On (default): eligible, so all 4 can be drawn.
	var with_vib: Dictionary = RandomizerGenerator.generate(
		lib, {"seed": 2, "round_count": 4, "include_vib_only": true}
	)
	assert_int((with_vib["used_ids"] as Array).size()).is_equal(4)


func test_same_seed_is_deterministic() -> void:
	var a: Dictionary = RandomizerGenerator.generate(_library(8), {"seed": 42, "round_count": 5})
	var b: Dictionary = RandomizerGenerator.generate(_library(8), {"seed": 42, "round_count": 5})
	assert_str(JSON.stringify(a["journey"])).is_equal(JSON.stringify(b["journey"]))


func test_different_seed_changes_order() -> void:
	var a: Dictionary = RandomizerGenerator.generate(_library(12), {"seed": 1, "round_count": 8})
	var b: Dictionary = RandomizerGenerator.generate(_library(12), {"seed": 2, "round_count": 8})
	assert_str(JSON.stringify(a["journey"])).is_not_equal(JSON.stringify(b["journey"]))


func test_graph_is_structurally_valid() -> void:
	var res: Dictionary = RandomizerGenerator.generate(
		_library(6), {"seed": 9, "round_count": 6, "shop_every": 2, "boss_finale": true}
	)
	var graph: Dictionary = JourneyGraph.from_json(res["journey"])
	assert_array(JourneyGraph.validate_graph(graph)).is_empty()  # no start/dangling/cycle/unreachable


func test_linear_chain_single_end() -> void:
	var res: Dictionary = RandomizerGenerator.generate(_library(5), {"seed": 4, "round_count": 5})
	var seq: Array = _sequence(res["journey"])
	assert_int(seq.size()).is_equal(5)  # walking Start reaches every node
	var ends: int = 0
	for n: Dictionary in res["journey"]["Nodes"]:
		if (n.get("out", []) as Array).is_empty():
			ends += 1
	assert_int(ends).is_equal(1)  # exactly one terminal node


func test_time_mode_respects_budget() -> void:
	# 10 clips × 60s, target 5 min → 5 rounds (300s fits, the 6th would overshoot).
	var res: Dictionary = RandomizerGenerator.generate(
		_library(10), {"seed": 11, "length_mode": "time", "target_minutes": 5.0}
	)
	var rounds: Array = _rounds(res["journey"])
	assert_int(rounds.size()).is_equal(5)
	assert_int(int((res["summary"] as Dictionary)["est_length_ms"])).is_less_equal(5 * 60000)


func test_time_mode_takes_at_least_one() -> void:
	# A single clip longer than the budget is still included (a 0-round run is useless).
	var res: Dictionary = RandomizerGenerator.generate(
		[_entry("big", 600000, 3)], {"seed": 1, "length_mode": "time", "target_minutes": 1.0}
	)
	assert_int(_rounds(res["journey"]).size()).is_equal(1)


func test_time_mode_skips_oversized_and_never_overshoots() -> void:
	# The reported bug: a 90-min clip mixed with 10-min clips, 60-min budget. First-fit
	# must SKIP the oversized clip (not produce an 80-90 min run) and keep packing the
	# small ones (not truncate to a 2-min run). Regardless of the random order.
	var lib: Array = [_entry("big", 90 * 60000, 3)]
	for i in 8:
		lib.append(_entry("s%02d" % i, 10 * 60000, 3))
	for s: int in [1, 2, 3, 7, 42]:  # several seeds → several random orderings
		var res: Dictionary = RandomizerGenerator.generate(
			lib, {"seed": s, "length_mode": "time", "target_minutes": 60.0}
		)
		var rounds: Array = _rounds(res["journey"])
		# Never overshoots the 60-min budget.
		assert_int(int((res["summary"] as Dictionary)["est_length_ms"])).is_less_equal(60 * 60000)
		# The oversized clip is never included (a 10-min clip always fits instead).
		for r: Dictionary in rounds:
			assert_str(str((r["data"] as Dictionary)["video_path"])).is_not_equal(
				"content/m_big.mp4"
			)
		# Packs six 10-min clips (60 min), not a truncated 1-2 round run.
		assert_int(rounds.size()).is_equal(6)


func test_boss_finale_marks_last_round() -> void:
	var res: Dictionary = RandomizerGenerator.generate(
		_library(5), {"seed": 8, "round_count": 5, "boss_finale": true}
	)
	var rounds: Array = _rounds(res["journey"])
	var last: Dictionary = rounds[rounds.size() - 1]["data"]
	assert_str(str(last["round_type"])).is_equal("boss")
	# Regression: a boss round MUST carry forced modifiers, or it's a boss with no
	# effect (the "boss had no modifiers" bug).
	assert_array(last["boss_modifiers"]).is_not_empty()
	# Earlier rounds are not bosses and carry no boss modifiers.
	var first: Dictionary = rounds[0]["data"]
	assert_str(str(first["round_type"])).is_not_equal("boss")
	assert_array(first["boss_modifiers"]).is_empty()


func test_boss_modifiers_are_valid_kinds() -> void:
	var res: Dictionary = RandomizerGenerator.generate(
		_library(3), {"seed": 2, "round_count": 3, "boss_finale": true}
	)
	var rounds: Array = _rounds(res["journey"])
	var mods: Array = (rounds[rounds.size() - 1]["data"] as Dictionary)["boss_modifiers"]
	var valid: Array = ["scale", "clamp", "reverse", "score_multiplier"]
	for m: Dictionary in mods:
		assert_array(valid).contains([str(m["kind"])])


func test_effect_pct_full_makes_effect_rounds() -> void:
	var res: Dictionary = RandomizerGenerator.generate(
		_library(6), {"seed": 2, "round_count": 6, "effect_pct": 1.0}
	)
	for r: Dictionary in _rounds(res["journey"]):
		var data: Dictionary = r["data"]
		assert_str(str(data["round_type"])).is_equal("effect")
		# Regression: an effect round MUST carry a non-empty effects[] pool, or the
		# runtime treats it as a pure-visual round with no gameplay effect.
		assert_array(data["effects"]).is_not_empty()
		assert_bool(bool(data["effect_random"])).is_true()


func test_normal_round_has_no_effects() -> void:
	var res: Dictionary = RandomizerGenerator.generate(
		_library(4), {"seed": 9, "round_count": 4, "effect_pct": 0.0}
	)
	for r: Dictionary in _rounds(res["journey"]):
		assert_str(str((r["data"] as Dictionary)["round_type"])).is_equal("normal")
		assert_array((r["data"] as Dictionary)["effects"]).is_empty()


func test_shops_inserted_between_rounds() -> void:
	# 6 rounds, a shop every 2 → shops after rounds 2 and 4 (never trailing round 6).
	var res: Dictionary = RandomizerGenerator.generate(
		_library(6), {"seed": 5, "round_count": 6, "shop_every": 2}
	)
	var shops: Array = _sequence(res["journey"]).filter(
		func(n: Dictionary) -> bool: return str(n["type"]) == "shop"
	)
	assert_int(shops.size()).is_equal(2)
	assert_int(int((res["summary"] as Dictionary)["shops"])).is_equal(2)
	# The final node is a round, not a shop.
	var seq: Array = _sequence(res["journey"])
	assert_str(str((seq[seq.size() - 1] as Dictionary)["type"])).is_equal("round")


func test_tag_include_filters_pool() -> void:
	var lib: Array = [
		_entry("a", 60000, 3, 1.0, ["soft"]),
		_entry("b", 60000, 3, 1.0, ["hard"]),
		_entry("c", 60000, 3, 1.0, ["soft"]),
	]
	var res: Dictionary = RandomizerGenerator.generate(
		lib, {"seed": 1, "round_count": 5, "tags_include": ["soft"]}
	)
	var rounds: Array = _rounds(res["journey"])
	assert_int(rounds.size()).is_equal(2)  # only the two 'soft' clips qualify
	for r: Dictionary in rounds:
		assert_str(str((r["data"] as Dictionary)["video_path"])).is_not_equal("content/m_b.mp4")


func test_tag_exclude_drops_matches() -> void:
	var lib: Array = [
		_entry("a", 60000, 3, 1.0, ["ok"]),
		_entry("b", 60000, 3, 1.0, ["skip"]),
	]
	var res: Dictionary = RandomizerGenerator.generate(
		lib, {"seed": 1, "round_count": 5, "tags_exclude": ["skip"]}
	)
	assert_int(_rounds(res["journey"]).size()).is_equal(1)


func test_no_matches_after_filter_fails() -> void:
	var lib: Array = [_entry("a", 60000, 3, 1.0, ["x"])]
	var res: Dictionary = RandomizerGenerator.generate(
		lib, {"seed": 1, "tags_include": ["missing"]}
	)
	assert_bool(res["ok"]).is_false()
	assert_str(res["reason"]).is_equal("no_matches")


func test_intensity_order_ramps_up() -> void:
	var lib: Array = [
		_entry("i5", 60000, 5),
		_entry("i1", 60000, 1),
		_entry("i4", 60000, 4),
		_entry("i2", 60000, 2),
		_entry("i3", 60000, 3),
	]
	var res: Dictionary = RandomizerGenerator.generate(
		lib, {"seed": 3, "round_count": 5, "intensity_order": true}
	)
	# Reconstruct each round's intensity from its clip id (name == id) and assert
	# the sequence is non-decreasing.
	var by_rel: Dictionary = {}
	for e: Dictionary in lib:
		by_rel[str(e["video_rel"])] = int(e["intensity"])
	var prev: int = 0
	for r: Dictionary in _rounds(res["journey"]):
		var inten: int = int(by_rel[str((r["data"] as Dictionary)["video_path"])])
		assert_int(inten).is_greater_equal(prev)
		prev = inten


func test_content_rels_cover_every_clip() -> void:
	var res: Dictionary = RandomizerGenerator.generate(_library(4), {"seed": 1, "round_count": 4})
	var rels: Array = res["content_rels"]
	# 4 rounds × (video + funscript) = 8 distinct pooled files.
	assert_int(rels.size()).is_equal(8)
	for r: Dictionary in _rounds(res["journey"]):
		assert_array(rels).contains([str((r["data"] as Dictionary)["video_path"])])
