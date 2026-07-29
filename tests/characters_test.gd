extends GdUnitTestSuite

# JourneyData storyboard cast: characters (each with their own portraits + placements), the per-line
# stage list, and the placement box helpers. Pure schema mapping + resolution — no autoloads.

# ── Character round-trip (portraits + per-character placements) ─────────────


func test_character_round_trip() -> void:
	var chr := {
		"id": "chr_1",
		"name": "Alice",
		"portraits":
		[
			{"id": "por_a", "name": "Neutral", "path": "content/n.png"},
			{"id": "por_b", "name": "Happy", "path": "content/h.png"},
		],
		"placements": [{"id": "left", "name": "Left", "x": 0.0, "y": 0.1, "w": 0.4, "h": 0.8}],
	}
	var rt := JourneyData.parse_journey_character(JourneyData.coerce_journey_character(chr))
	assert_str(str(rt["id"])).is_equal("chr_1")
	assert_str(str(rt["name"])).is_equal("Alice")
	assert_int((rt["portraits"] as Array).size()).is_equal(2)
	assert_str(str((rt["portraits"][1] as Dictionary)["name"])).is_equal("Happy")
	assert_int((rt["placements"] as Array).size()).is_equal(1)


# A character with no placements self-heals to the three seeded positions (never left with none).
func test_character_without_placements_seeds_defaults() -> void:
	var rt := JourneyData.parse_journey_character({"Id": "chr_2", "Name": "Bob"})
	assert_int((rt["placements"] as Array).size()).is_equal(3)
	assert_str(str((rt["placements"][0] as Dictionary)["id"])).is_equal("left")


func test_blank_character_id_healed() -> void:
	assert_str(str(JourneyData.parse_journey_character({"Name": "X"})["id"])).starts_with("chr_")


func test_blank_portrait_id_healed() -> void:
	var rt := JourneyData.parse_journey_character(
		{"Id": "chr_3", "Portraits": [{"Name": "Only", "Path": "p.png"}]}
	)
	assert_str(str((rt["portraits"][0] as Dictionary)["id"])).starts_with("por_")


# ── character_portrait_path: by id, default to first, empty when none ───────


func test_portrait_path_by_id() -> void:
	var chr := {"portraits": [{"id": "por_a", "path": "a.png"}, {"id": "por_b", "path": "b.png"}]}
	assert_str(JourneyData.character_portrait_path(chr, "por_b")).is_equal("b.png")


func test_portrait_path_unknown_falls_back_to_first() -> void:
	var chr := {"portraits": [{"id": "por_a", "path": "a.png"}]}
	assert_str(JourneyData.character_portrait_path(chr, "por_missing")).is_equal("a.png")


func test_portrait_path_none() -> void:
	assert_str(JourneyData.character_portrait_path({"portraits": []}, "por_a")).is_equal("")


# ── Stage list ──────────────────────────────────────────────────────────────


func test_clean_stage_keeps_entries_and_optionals() -> void:
	var stage := (
		JourneyData
		. clean_stage(
			[
				{"character": "chr_a", "portrait": "por_1", "placement": "left"},
				{"character": "chr_b"},  # portrait/placement omitted (defaults at runtime)
				{"character": ""},  # no character → dropped
				{"portrait": "por_x"},  # no character → dropped
			]
		)
	)
	assert_int(stage.size()).is_equal(2)
	assert_str(str((stage[0] as Dictionary)["character"])).is_equal("chr_a")
	assert_str(str((stage[0] as Dictionary)["placement"])).is_equal("left")
	assert_bool((stage[1] as Dictionary).has("placement")).is_false()


func test_clean_stage_non_array() -> void:
	assert_int(JourneyData.clean_stage({}).size()).is_equal(0)
	assert_int(JourneyData.clean_stage("nope").size()).is_equal(0)


func test_stage_with_speaker_appends_when_absent() -> void:
	var out := JourneyData.stage_with_speaker([], "chr_a", "left", "por_1")
	assert_int(out.size()).is_equal(1)
	assert_str(str((out[0] as Dictionary)["character"])).is_equal("chr_a")
	assert_str(str((out[0] as Dictionary)["placement"])).is_equal("left")
	assert_str(str((out[0] as Dictionary)["portrait"])).is_equal("por_1")


func test_stage_with_speaker_noop_when_present() -> void:
	var stage := [{"character": "chr_a", "placement": "right"}]
	var out := JourneyData.stage_with_speaker(stage, "chr_a", "left", "por_1")
	assert_int(out.size()).is_equal(1)
	# unchanged — never re-placed or re-expressed
	assert_str(str((out[0] as Dictionary)["placement"])).is_equal("right")


func test_stage_with_speaker_second_character_joins() -> void:
	var out := JourneyData.stage_with_speaker(
		[{"character": "chr_a", "placement": "left"}], "chr_b", "right", ""
	)
	assert_int(out.size()).is_equal(2)
	assert_str(str((out[1] as Dictionary)["character"])).is_equal("chr_b")


# ── Placement boxes (per-character) ─────────────────────────────────────────


func test_placement_round_trip_and_clamp() -> void:
	var rt := JourneyData.parse_journey_placement(
		{"Id": "plc_1", "Name": "Close", "X": 1.8, "W": 0.0}
	)
	assert_str(str(rt["id"])).is_equal("plc_1")
	assert_float(float(rt["x"])).is_equal_approx(1.0, 0.001)  # clamped
	assert_float(float(rt["w"])).is_equal_approx(JourneyData.PLACEMENT_MIN_SIZE, 0.001)  # floored


func test_default_character_placements() -> void:
	var d := JourneyData.default_character_placements()
	assert_int(d.size()).is_equal(3)
	assert_str(str((d[2] as Dictionary)["id"])).is_equal("right")


# resolve within a character's placements: found → its box; unknown → first; empty → center default.
func test_resolve_placement_found() -> void:
	var pls := [{"id": "left", "x": 0.5, "y": 0.5, "w": 0.2, "h": 0.3}]
	assert_float(float(JourneyData.resolve_placement("left", pls)["x"])).is_equal_approx(0.5, 0.001)


func test_resolve_placement_unknown_falls_back_to_first() -> void:
	var pls := [{"id": "left", "x": 0.11, "y": 0.1, "w": 0.4, "h": 0.7}]
	assert_float(float(JourneyData.resolve_placement("gone", pls)["x"])).is_equal_approx(
		0.11, 0.001
	)


func test_resolve_placement_empty_falls_back_to_center() -> void:
	var box := JourneyData.resolve_placement("x", [])
	assert_float(float(box["x"])).is_equal_approx(
		float(JourneyData.PLACEMENT_BUILTINS["center"]["x"]), 0.001
	)
