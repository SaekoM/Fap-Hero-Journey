extends GdUnitTestSuite

# Phase 5 of Override items (see OVERRIDE_ITEMS_DESIGN.md): the journey.json (de)serialization for the
# `override` item category. JourneyData.coerce_journey_item / parse_journey_item must round-trip the
# funscript BUNDLE (main + axes + vibes), the immunity flag, and duration, so an authored override
# survives save/load and travels in the .fhj. (Path POOLING is JourneyBuilder's job; resolution to
# absolute is the scanner's — both are separate from this pure schema layer.)


func _override_item() -> Dictionary:
	return {
		"id": "itm_grip",
		"name": "The Grip",
		"description": "A sudden squeeze.",
		"category": "override",
		"price": 45,
		"immune_to_effects": true,
		"duration_ms": 8000,
		"scripts":
		{
			"main": "content/grip__fp.funscript",
			"axes": {"R1": "content/grip__fp.r1.funscript"},
			"vibes": {0: "content/grip__fp.vib1.funscript"},
		},
	}


# "override" is an accepted category — not silently coerced back to "modifier".
func test_override_is_a_valid_category() -> void:
	var disk: Dictionary = JourneyData.coerce_journey_item(_override_item())
	assert_str(str(disk.get("Category", ""))).is_equal("override")


# The on-disk envelope is PascalCase and carries the whole bundle + flags.
func test_coerce_writes_bundle_envelope() -> void:
	var disk: Dictionary = JourneyData.coerce_journey_item(_override_item())
	assert_bool(bool(disk.get("ImmuneToEffects", false))).is_true()
	assert_int(int(disk.get("DurationMs", -1))).is_equal(8000)
	var scripts: Dictionary = disk["Scripts"]
	assert_str(str(scripts.get("Main", ""))).is_equal("content/grip__fp.funscript")
	assert_str(str((scripts["Axes"] as Dictionary)["R1"])).is_equal("content/grip__fp.r1.funscript")
	# JSON object keys are strings — the vibe channel is stored as "0".
	assert_str(str((scripts["Vibes"] as Dictionary)["0"])).is_equal(
		"content/grip__fp.vib1.funscript"
	)


# coerce → parse returns the runtime shape intact: bundle, flag, duration, and NO manual-use `kind`.
func test_round_trip_restores_runtime_shape() -> void:
	var back: Dictionary = JourneyData.parse_journey_item(
		JourneyData.coerce_journey_item(_override_item())
	)
	assert_str(str(back["category"])).is_equal("override")
	assert_bool(bool(back["immune_to_effects"])).is_true()
	assert_int(int(back["duration_ms"])).is_equal(8000)
	assert_bool(back.has("kind")).is_false()  # activation is category-driven, so it stays usable
	var scripts: Dictionary = back["scripts"]
	assert_str(str(scripts["main"])).is_equal("content/grip__fp.funscript")
	assert_str(str((scripts["axes"] as Dictionary)["R1"])).is_equal("content/grip__fp.r1.funscript")
	# Vibe channel keys are ints at runtime (the C#/loader index), strings only on disk.
	assert_str(str((scripts["vibes"] as Dictionary)[0])).is_equal("content/grip__fp.vib1.funscript")


# A stroke-only override (no axes/vibes) round-trips with empty channel maps, not missing keys.
func test_stroke_only_override_round_trips() -> void:
	var item := {"id": "x", "category": "override", "scripts": {"main": "content/a.funscript"}}
	var back: Dictionary = JourneyData.parse_journey_item(JourneyData.coerce_journey_item(item))
	var scripts: Dictionary = back["scripts"]
	assert_str(str(scripts["main"])).is_equal("content/a.funscript")
	assert_bool((scripts["axes"] as Dictionary).is_empty()).is_true()
	assert_bool((scripts["vibes"] as Dictionary).is_empty()).is_true()


# An override can ALSO carry an effects bundle (applied while it plays) — it round-trips like a modifier's.
func test_override_carries_effects_bundle() -> void:
	var item := {
		"id": "x",
		"category": "override",
		"scripts": {"main": "content/a.funscript"},
		"effects": [{"kind": "score_multiplier", "factor": 2.0}, {"kind": "blackout"}],
	}
	var back: Dictionary = JourneyData.parse_journey_item(JourneyData.coerce_journey_item(item))
	var effects: Array = back["effects"]
	assert_int(effects.size()).is_equal(2)
	assert_str(str((effects[0] as Dictionary)["kind"])).is_equal("score_multiplier")
	assert_str(str((effects[1] as Dictionary)["kind"])).is_equal("blackout")


# The trim window (lift a section out of a longer script) round-trips through the disk envelope.
func test_override_trim_window_round_trips() -> void:
	var item := {
		"id": "x",
		"category": "override",
		"scripts": {"main": "content/a.funscript"},
		"trim": {"in_ms": 4000, "out_ms": 12000},
	}
	var back: Dictionary = JourneyData.parse_journey_item(JourneyData.coerce_journey_item(item))
	var trim: Dictionary = back["trim"]
	assert_int(int(trim["in_ms"])).is_equal(4000)
	assert_int(int(trim["out_ms"])).is_equal(12000)


# apply_override_trim lifts + rebases the window; a full/empty window is a pass-through.
func test_apply_override_trim() -> void:
	var actions := [Vector2(0, 0), Vector2(1000, 100), Vector2(2000, 0), Vector2(3000, 100)]
	var cut: Array = JourneyData.apply_override_trim(actions, {"in_ms": 1000, "out_ms": 2000})
	assert_int((cut[0] as Vector2).x).is_equal(0)  # rebased to 0
	assert_int((cut[cut.size() - 1] as Vector2).x).is_equal(1000)  # 2000 − 1000 in-point
	# No window, or a window covering the whole clip → the original array, untouched.
	assert_int(JourneyData.apply_override_trim(actions, {}).size()).is_equal(4)
	(
		assert_int(JourneyData.apply_override_trim(actions, {"in_ms": 0, "out_ms": 3000}).size())
		. is_equal(4)
	)
