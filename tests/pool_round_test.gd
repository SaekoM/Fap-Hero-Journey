extends GdUnitTestSuite

# Pool round (random encounter) — the pure schema + weighted-pick foundation:
# entry coercion, weight extraction, the round-data round-trip, and selection via
# the shared ForkResolver.weighted_pick.


func test_coerce_pool_entry_canonical_shape() -> void:
	var e: Dictionary = JourneyData.coerce_pool_entry({"name": "Goblin", "video_path": "g.mp4"})
	assert_str(str(e["name"])).is_equal("Goblin")
	assert_str(str(e["video_path"])).is_equal("g.mp4")
	assert_str(str(e["funscript_path"])).is_equal("")  # defaulted
	assert_int(int(e["weight"])).is_equal(1)  # default weight
	assert_bool((e["axis_scripts"] as Dictionary).is_empty()).is_true()


func test_coerce_pool_entry_clamps_weight() -> void:
	assert_int(int(JourneyData.coerce_pool_entry({"weight": 0})["weight"])).is_equal(1)
	assert_int(int(JourneyData.coerce_pool_entry({"weight": -5})["weight"])).is_equal(1)
	assert_int(int(JourneyData.coerce_pool_entry({"weight": 4})["weight"])).is_equal(4)


# A pool entry defaults to a normal encounter and carries no boss config.
func test_coerce_pool_entry_defaults_normal() -> void:
	var e: Dictionary = JourneyData.coerce_pool_entry({"name": "A"})
	assert_str(str(e["round_type"])).is_equal("normal")
	assert_bool(e.has("boss_modifiers")).is_false()  # only boss entries carry it


# A boss entry keeps its type + forced-modifier / tagline / image config through coercion.
func test_coerce_pool_entry_boss_carries_config() -> void:
	var e: Dictionary = (
		JourneyData
		. coerce_pool_entry(
			{
				"name": "Ogre",
				"round_type": "boss",
				"boss_tagline": "IT AWAKENS",
				"boss_image": "ogre.png",
				"boss_modifiers": [{"kind": "scale", "value": 2.0}],
			}
		)
	)
	assert_str(str(e["round_type"])).is_equal("boss")
	assert_str(str(e["boss_tagline"])).is_equal("IT AWAKENS")
	assert_str(str(e["boss_image"])).is_equal("ogre.png")
	assert_int((e["boss_modifiers"] as Array).size()).is_equal(1)


func test_coerce_pool_entry_deep_copies_channels() -> void:
	var axis: Dictionary = {"L1": "a.funscript"}
	var e: Dictionary = JourneyData.coerce_pool_entry({"axis_scripts": axis})
	axis["L1"] = "MUTATED"  # mutate the source afterward
	assert_str(str((e["axis_scripts"] as Dictionary)["L1"])).is_equal("a.funscript")


func test_pool_entry_weights() -> void:
	var w: Array = JourneyData.pool_entry_weights([{"weight": 1}, {"weight": 3}, {}])
	assert_array(w).is_equal([1, 3, 1])  # missing weight → 1


# ── pool_draw_weights (no-repeat pool draw) ──────────────────────────────────


func test_pool_draw_weights_none_played_is_base() -> void:
	var entries := [{"video_path": "a", "weight": 2}, {"video_path": "b"}]
	assert_array(JourneyData.pool_draw_weights(entries, {})).is_equal([2, 1])


# A played clip's entry is zeroed (skipped); the rest keep their weight.
func test_pool_draw_weights_zeros_played_entry() -> void:
	var entries := [{"video_path": "a", "weight": 3}, {"video_path": "b"}]
	assert_array(JourneyData.pool_draw_weights(entries, {"a": true})).is_equal([0, 1])


# Every clip already played → fall back to the full weights rather than dead-ending on all-zero.
func test_pool_draw_weights_all_played_falls_back() -> void:
	var entries := [{"video_path": "a", "weight": 2}, {"video_path": "b"}]
	assert_array(JourneyData.pool_draw_weights(entries, {"a": true, "b": true})).is_equal([2, 1])


# An entry with no video_path is treated as unplayed (kept), never matched against the played set.
func test_pool_draw_weights_empty_path_kept() -> void:
	var entries := [{"video_path": ""}, {"video_path": "b"}]
	assert_array(JourneyData.pool_draw_weights(entries, {"b": true})).is_equal([1, 0])


func test_pool_round_coercion_keeps_entries() -> void:
	var data: Dictionary = {
		"round_type": "pool",
		"pool_entries": [{"name": "A", "video_path": "a.mp4", "weight": 2}, {"name": "B"}],
	}
	var out: Dictionary = JourneyData.coerce_node_save_data("round", data)
	assert_str(str(out["round_type"])).is_equal("pool")
	assert_int((out["pool_entries"] as Array).size()).is_equal(2)
	assert_int(int((out["pool_entries"][0] as Dictionary)["weight"])).is_equal(2)
	assert_str(str((out["pool_entries"][1] as Dictionary)["name"])).is_equal("B")


func test_non_pool_round_drops_entries() -> void:
	# A normal round must not carry a pool_entries key (schema stays lean).
	var data: Dictionary = {"round_type": "normal", "pool_entries": [{"name": "stray"}]}
	var out: Dictionary = JourneyData.coerce_node_save_data("round", data)
	assert_bool(out.has("pool_entries")).is_false()


func test_pool_round_show_encounter_toggle() -> void:
	# Defaults on; an explicit off persists; non-pool rounds never carry the flag.
	var on: Dictionary = JourneyData.coerce_node_save_data("round", {"round_type": "pool"})
	assert_bool(bool(on["show_encounter"])).is_true()
	var off_data: Dictionary = {"round_type": "pool", "show_encounter": false}
	var off: Dictionary = JourneyData.coerce_node_save_data("round", off_data)
	assert_bool(bool(off["show_encounter"])).is_false()
	var normal: Dictionary = JourneyData.coerce_node_save_data(
		"round", {"round_type": "normal", "show_encounter": true}
	)
	assert_bool(normal.has("show_encounter")).is_false()


func test_pool_entry_paths_resolve_on_scan() -> void:
	# The scan side (JourneyGraph.resolve_paths) must make each entry's media
	# absolute, not just the round's own fields.
	var entry: Dictionary = {
		"name": "A",
		"video_path": "content/m_a.mp4",
		"funscript_path": "content/m_a.funscript",
		"boss_image": "content/m_a.png",
		"axis_scripts": {"L1": "content/m_a.L1.funscript"},
	}
	var graph: Dictionary = {
		"start": "n1",
		"nodes":
		{
			"n1":
			{"type": "round", "data": {"round_type": "pool", "pool_entries": [entry]}, "out": []}
		},
	}
	JourneyGraph.resolve_paths(graph, "/base")
	var e: Dictionary = graph["nodes"]["n1"]["data"]["pool_entries"][0]
	assert_str(str(e["video_path"])).is_equal("/base/content/m_a.mp4")
	assert_str(str(e["funscript_path"])).is_equal("/base/content/m_a.funscript")
	assert_str(str(e["boss_image"])).is_equal("/base/content/m_a.png")  # boss entry's intro image
	assert_str(str((e["axis_scripts"] as Dictionary)["L1"])).is_equal(
		"/base/content/m_a.L1.funscript"
	)


func test_weighted_pick_favors_heavy_entry() -> void:
	# weights [1,3]: r=0 → index 0; r in {1,2,3} → index 1 (the heavier entry).
	var weights: Array = JourneyData.pool_entry_weights([{"weight": 1}, {"weight": 3}])
	assert_int(ForkResolver.weighted_pick(weights, 0)).is_equal(0)
	assert_int(ForkResolver.weighted_pick(weights, 1)).is_equal(1)
	assert_int(ForkResolver.weighted_pick(weights, 3)).is_equal(1)
