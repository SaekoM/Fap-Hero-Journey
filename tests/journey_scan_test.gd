extends GdUnitTestSuite

# Journey scan round-trip (Tier 2, step 1) — writes a full-coverage journey.json
# to a temp user:// dir and runs the REAL JourneyScanner.parse_journey, asserting
# every authored per-round / fork / shop / storyboard field comes back. Guards the
# scanner's two duplicated parse sites (top-level + fork-path round) against a
# dropped or renamed field, and doubles as the written journey.json schema.
#
# No media files needed: each round carries cached ActionCount/LengthMs, so the
# scanner's fast path returns them without touching disk (see _resolve_round_stats).

const TEST_DIR := "user://test_roundtrip"
const JOURNEY := "tj"
const EPS := 0.0001


func after() -> void:
	var base := ProjectSettings.globalize_path(TEST_DIR)
	DirAccess.remove_absolute(base + "/" + JOURNEY + "/journey.json")
	DirAccess.remove_absolute(base + "/" + JOURNEY)
	DirAccess.remove_absolute(base)


# Writes `data` as journey.json in the temp journey dir and parses it for real.
func _parse(data: Dictionary) -> Dictionary:
	var jdir := TEST_DIR + "/" + JOURNEY
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(jdir))
	var f := FileAccess.open(jdir + "/journey.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	return JourneyScanner.parse_journey(jdir, JOURNEY)


# A journey exercising every field path: a cursed round (curses + sensory +
# intensity), a boss round (modifiers + tagline), a shop, a storyboard, and a
# conditional fork whose path holds a cursed round and a nested fork.
func _full_journey() -> Dictionary:
	return {
		"Name": "Test Journey",
		"Author": "Tester",
		"Difficulty": "Hard",
		"Description": "a description",
		"Tags": [],
		"Rounds":
		[
			{
				"Name": "Cursed One",
				"FolderName": "r001",
				"FunscriptPath": "r001/script.funscript",
				"VideoPath": "r001/video.mp4",
				"ActionCount": 42,
				"LengthMs": 120000,
				"RoundType": "Cursed",
				"IsCheckpoint": true,
				"CurseReward": 75,
				"CleanseCost": 30,
				"CurseRandom": false,
				"Curses": ["Shrunken", "Greed"],
				"BoonRandom": true,
				"Boons": [],
				"GiftItem": "",
				"BossTagline": "",
				"BossModifiers": [],
				"Sensory": ["Murk", "Muffled"],
				"SensoryInPool": true,
				"SensoryIntensity": {"Murk": 0.8},
				"ShowReveal": false,
				"CoinsAwarded": 10,
				"Order": 0,
			},
			{
				"Name": "Boss One",
				"FolderName": "r002",
				"FunscriptPath": "r002/script.funscript",
				"ActionCount": 10,
				"LengthMs": 5000,
				"RoundType": "Boss",
				"BossTagline": "Face me",
				"BossModifiers":
				[{"Kind": "scale", "Factor": 1.2}, {"Kind": "clamp", "Min": 0, "Max": 50}],
				"Sensory": ["Tremor"],
				"CoinsAwarded": 0,
				"Order": 1,
			},
		],
		"Shops":
		[
			{
				"AfterOrder": 0,
				"Title": "The Shop",
				"Mode": "fixed",
				"Count": 2,
				"Items": ["key", "cleanse"],
				"Guaranteed": ["key"],
				"PriceMultiplier": 1.5
			},
		],
		"Storyboards":
		[
			{
				"Order": 0,
				"CoinsAwarded": 5,
				"Item": "key",
				"Lines": [{"Speaker": "A", "Text": "hi"}]
			},
		],
		"Forks":
		[
			{
				"AfterOrder": 1,
				"Title": "The Fork",
				"Description": "choose",
				"Resolution": "conditional",
				"CondMetric": "coins",
				"DefaultPath": 1,
				"Paths":
				[
					{
						"Name": "Left",
						"Description": "go left",
						"Weight": 3,
						"Threshold": 100,
						"RequiredItem": "key",
						"Cost": 20,
						"Rounds":
						[
							{
								"Name": "Path Round",
								"FolderName": "fork0_p0_r001",
								"FunscriptPath": "fork0_p0_r001/script.funscript",
								"VideoPath": "fork0_p0_r001/video.mp4",
								"ActionCount": 7,
								"LengthMs": 3000,
								"RoundType": "cursed",
								"Curses": ["Inverted"],
								"Sensory": ["Bleary"],
								"SensoryIntensity": {"Bleary": 0.5},
								"ShowReveal": false,
								"Order": 0
							},
						],
						"Shops": [],
						"Storyboards": [],
						"Forks":
						[
							{
								"AfterOrder": 0,
								"Title": "Nested",
								"Resolution": "choice",
								"Paths":
								[
									{
										"Name": "NestLeft",
										"Rounds": [],
										"Shops": [],
										"Storyboards": [],
										"Forks": []
									}
								]
							},
						],
					},
					{"Name": "Right", "Rounds": [], "Shops": [], "Storyboards": [], "Forks": []},
				],
			},
		],
	}


func test_top_level_fields() -> void:
	var j := _parse(_full_journey())
	assert_str(j.title).is_equal("Test Journey")
	assert_str(j.author).is_equal("Tester")
	assert_str(j.difficulty).is_equal("Hard")
	assert_str(j.description).is_equal("a description")
	assert_int(j.total_rounds).is_equal(3)  # 2 top-level + 1 in the longest fork path
	assert_bool(j.map_enabled).is_true()  # omitted MapEnabled → default true (back-compat)


# The journey-level map switch round-trips. Authors set MapEnabled:false to hide
# the in-play journey map (enforce surprise); test_top_level_fields covers the
# omitted → true default that keeps the pre-existing catalogue's map.
func test_map_enabled_round_trips() -> void:
	var d := _full_journey()
	d["MapEnabled"] = false
	assert_bool(_parse(d).map_enabled).is_false()


# A legacy cursed round migrates to the generic effect schema on scan (curses →
# effects, curse_reward → endure_reward, resolvable + green/CURSED visuals), sensory intact.
func test_cursed_round_fields() -> void:
	var r: Dictionary = _parse(_full_journey()).rounds[0]
	assert_str(r.round_type).is_equal("effect")
	assert_str(r.frame_color).is_equal(JourneyData.EFFECT_COLOR_HINDER)
	assert_str(r.card_header).is_equal("CURSED")
	assert_bool(r.resolvable).is_true()
	assert_bool(r.is_checkpoint).is_true()
	assert_int(r.endure_reward).is_equal(75)
	assert_int(r.cleanse_cost).is_equal(30)
	assert_bool(r.effect_random).is_false()
	assert_array(r.effects).contains_exactly(["Shrunken", "Greed"])
	assert_array(r.sensory).contains_exactly(["Murk", "Muffled"])
	assert_bool(r.sensory_in_pool).is_true()
	assert_float(float(r.sensory_intensity["Murk"])).is_equal_approx(0.8, EPS)
	assert_bool(r.show_reveal).is_false()
	assert_int(int(r.coins)).is_equal(10)
	assert_int(int(r.order)).is_equal(0)
	assert_int(r.action_count).is_equal(42)
	assert_int(r.length_ms).is_equal(120000)
	assert_str(r.funscript_path).is_equal(TEST_DIR + "/" + JOURNEY + "/r001/script.funscript")
	# Explicit VideoPath resolves to an absolute path under the journey folder.
	assert_str(r.video_path).is_equal(TEST_DIR + "/" + JOURNEY + "/r001/video.mp4")


# Boss round: modifiers parse to lowercase kind + params; omitted ShowReveal
# defaults to true (the default that keeps existing journeys telegraphing).
func test_boss_round_fields_and_show_reveal_default() -> void:
	var r: Dictionary = _parse(_full_journey()).rounds[1]
	assert_str(r.round_type).is_equal("boss")
	assert_str(r.boss_tagline).is_equal("Face me")
	assert_array(r.sensory).contains_exactly(["Tremor"])
	assert_bool(r.show_reveal).is_true()  # omitted → default true
	# No VideoPath authored → scanner emits "" (consumer folder-scan fallback handles it).
	assert_str(r.video_path).is_equal("")
	var bm: Array = r.boss_modifiers
	assert_int(bm.size()).is_equal(2)
	assert_str(bm[0]["kind"]).is_equal("scale")
	assert_float(float(bm[0]["factor"])).is_equal_approx(1.2, EPS)
	assert_str(bm[1]["kind"]).is_equal("clamp")
	assert_float(float(bm[1]["min"])).is_equal_approx(0.0, EPS)
	assert_float(float(bm[1]["max"])).is_equal_approx(50.0, EPS)


func test_fork_resolution_fields() -> void:
	var fork: Dictionary = _parse(_full_journey()).forks[0]
	assert_int(int(fork.after_order)).is_equal(1)
	assert_str(fork.title).is_equal("The Fork")
	assert_str(fork.resolution).is_equal("conditional")
	assert_str(fork.cond_metric).is_equal("coins")
	assert_int(fork.default_path).is_equal(1)
	var left: Dictionary = fork.paths[0]
	assert_str(left.name).is_equal("Left")
	assert_int(left.weight).is_equal(3)
	assert_int(left.threshold).is_equal(100)
	assert_str(left.required_item).is_equal("key")
	assert_int(left.cost).is_equal(20)


# The fork-PATH round is the scanner's second (duplicated) parse site — assert it
# carries the same authored fields as a top-level round.
func test_fork_path_round_fields() -> void:
	var pr: Dictionary = _parse(_full_journey()).forks[0].paths[0].rounds[0]
	assert_str(pr.round_type).is_equal("effect")
	assert_array(pr.effects).contains_exactly(["Inverted"])
	assert_array(pr.sensory).contains_exactly(["Bleary"])
	assert_float(float(pr.sensory_intensity["Bleary"])).is_equal_approx(0.5, EPS)
	assert_bool(pr.show_reveal).is_false()
	assert_int(pr.action_count).is_equal(7)
	assert_str(pr.video_path).is_equal(TEST_DIR + "/" + JOURNEY + "/fork0_p0_r001/video.mp4")


func test_nested_fork() -> void:
	var nested: Array = _parse(_full_journey()).forks[0].paths[0].forks
	assert_int(nested.size()).is_equal(1)
	assert_str(nested[0]["title"]).is_equal("Nested")
	assert_str(nested[0]["resolution"]).is_equal("choice")


func test_shop_fields() -> void:
	var s: Dictionary = _parse(_full_journey()).shops[0]
	assert_int(int(s.after_order)).is_equal(0)
	assert_str(s.title).is_equal("The Shop")
	assert_str(s.mode).is_equal("fixed")
	assert_int(s.count).is_equal(2)
	assert_array(s.items).contains_exactly(["key", "cleanse"])
	assert_array(s.guaranteed).contains_exactly(["key"])
	assert_float(s.price_multiplier).is_equal_approx(1.5, EPS)


func test_storyboard_fields() -> void:
	var sb: Dictionary = _parse(_full_journey()).storyboards[0]
	assert_int(int(sb.order)).is_equal(0)
	assert_int(int(sb.coins)).is_equal(5)
	assert_str(sb.item).is_equal("key")
	assert_int(sb.lines.size()).is_equal(1)
	assert_str(sb.lines[0]["speaker"]).is_equal("A")
	assert_str(sb.lines[0]["text"]).is_equal("hi")


# A folder with no journey.json parses to an empty dict (the "skip it" signal).
func test_missing_journey_returns_empty() -> void:
	var parsed := JourneyScanner.parse_journey(TEST_DIR + "/does_not_exist", "does_not_exist")
	assert_dict(parsed).is_empty()


# Back-compat: a round with no explicit video_path resolves via the folder scan
# (pre-VideoPath journeys), while an explicit video_path always wins. Guards
# JourneyData._round_video — the consumer seam GameLoop/build_journey_model use.
func test_round_video_explicit_and_folder_fallback() -> void:
	var folder := TEST_DIR + "/vid_round"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var vf := FileAccess.open(folder + "/clip.mp4", FileAccess.WRITE)
	vf.store_string("not really a video")
	vf.close()

	# No video_path → folder scan finds the file on disk.
	var scanned := JourneyData._round_video({"folder": folder})
	assert_str(scanned).is_equal(folder + "/clip.mp4")

	# Explicit video_path wins and is returned verbatim (no folder scan).
	var explicit := JourneyData._round_video({"folder": folder, "video_path": "/abs/pool/m_x.mp4"})
	assert_str(explicit).is_equal("/abs/pool/m_x.mp4")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(folder) + "/clip.mp4")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))


# ── Silent forks in the catalogue preview ────────────────────────────
# The preview's fork entry is rebuilt field by field, so anything not named there never reaches the
# detail modal — which is how a silent fork ends up announcing its title and its choice names to a
# player who is never meant to see the decision happen.


func _fork_graph(fork_data: Dictionary) -> Dictionary:
	return {
		"start": "f",
		"nodes":
		{
			"f": {"type": "fork", "data": fork_data, "out": [{"to": "a", "name": "Left"}]},
			"a": {"type": "round", "data": {"name": "After"}, "out": []},
		}
	}


func test_the_preview_entry_knows_a_fork_is_silent() -> void:
	var seq: Dictionary = JourneyScanner._graph_catalogue_sequence(
		_fork_graph({"title": "Does she spare him?", "resolution": "random", "silent": true})
	)
	var forks: Array = seq.get("forks", [])
	assert_int(forks.size()).is_equal(1)
	assert_bool(bool((forks[0] as Dictionary)["silent"])).is_true()


func test_an_ordinary_fork_is_not_marked_silent() -> void:
	var seq: Dictionary = JourneyScanner._graph_catalogue_sequence(
		_fork_graph({"title": "Which way?", "resolution": "choice"})
	)
	assert_bool(bool((seq["forks"][0] as Dictionary)["silent"])).is_false()


# The flag is resolved through fork_is_silent, not read raw — so a fork that cannot route without the
# player is never treated as silent by the preview either, however its data got written.
func test_a_player_choice_marked_silent_is_not_hidden_from_the_preview() -> void:
	var seq: Dictionary = JourneyScanner._graph_catalogue_sequence(
		_fork_graph({"title": "Which way?", "resolution": "choice", "silent": true})
	)
	assert_bool(bool((seq["forks"][0] as Dictionary)["silent"])).is_false()
