extends GdUnitTestSuite

# The mini-game library (definitions, tiers) and the resolver (result → tier → routing flags).


func test_a_new_skill_game_has_fail_pass_perfect() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(SafeCrackerGame.KIND)
	var ids: Array = definition["tiers"].map(func(t: Dictionary) -> String: return t["id"])
	assert_array(ids).is_equal(["fail", "pass", "perfect"])
	assert_str(str(definition["id"])).starts_with("mg_")
	assert_int(int(definition["knobs"]["numbers"])).is_equal(3)


func test_an_unknown_kind_falls_back_and_unknown_keys_are_dropped() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": "pinball", "junk": 1}
	)
	assert_str(definition["kind"]).is_equal(SafeCrackerGame.KIND)
	assert_bool(definition.has("junk")).is_false()


# Tiers sort lowest first, the lowest always starts at 0 (no score falls through), and a repeated
# lowest score keeps the first tier that used it.
func test_skill_tiers_are_sorted_with_no_gap_below() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": SafeCrackerGame.KIND,
				"tiers":
				[
					{"id": "great", "name": "Great", "min_score": 80},
					{"id": "ok", "name": "OK", "min_score": 20},
					{"id": "dupe", "name": "Dupe", "min_score": 80},
				],
			}
		)
	)
	var tiers: Array = definition["tiers"]
	(
		assert_array(tiers.map(func(t: Dictionary) -> String: return t["id"]))
		. is_equal(["ok", "great", "dupe"])
	)
	assert_array(tiers.map(func(t: Dictionary) -> int: return t["min_score"])).is_equal([0, 80, 81])


# A tier that can't fit under 100 once the others have their scores is dropped.
func test_a_tier_pushed_past_100_is_dropped() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": SafeCrackerGame.KIND,
				"tiers":
				[
					{"id": "low", "min_score": 0},
					{"id": "top", "min_score": 100},
					{"id": "also_top", "min_score": 100},
				],
			}
		)
	)
	assert_int((definition["tiers"] as Array).size()).is_equal(2)


func test_tier_rewards_are_carried_through() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": SafeCrackerGame.KIND,
				"tiers": [{"id": "win", "name": "Win", "min_score": 0, "rewards": {"coins": 25}}],
			}
		)
	)
	assert_dict(definition["tiers"][0]["rewards"]).is_equal({"coins": 25})


func test_double_or_nothing_has_one_tier_per_outcome() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(DoubleOrNothingGame.KIND)
	assert_int((definition["rungs"] as Array).size()).is_equal(3)
	var ids: Array = definition["tiers"].map(func(t: Dictionary) -> String: return t["id"])
	assert_array(ids).is_equal(["busted", "cashed_1", "cashed_2", "maxed"])
	assert_str(definition["tiers"][0]["name"]).is_equal("Bust")
	assert_int(int(definition["knobs"]["odds"])).is_equal(50)


# Adding a rung keeps the rewards already attached to the outcomes that still exist.
# Rewards live on the rungs, so removing a rung can't shift another rung's reward onto the wrong rung,
# and the tiers are rebuilt from the ladder every time.
func test_tiers_follow_the_rungs() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": DoubleOrNothingGame.KIND,
				"rungs":
				[
					{"label": "Small", "rewards": {"coins": 10}},
					{"label": "", "rewards": {"coins": 30}},
					{"label": "Jackpot", "rewards": {"coins": 90, "item": "key"}},
				],
				"bust_rewards": {"coins": -5},
			}
		)
	)
	var tiers: Array = definition["tiers"]
	(
		assert_array(tiers.map(func(t: Dictionary) -> String: return t["name"]))
		. is_equal(["Bust", "Small", "Cashed out at rung 2", "Jackpot"])
	)
	assert_dict(tiers[0]["rewards"]).is_equal({"coins": -5})
	assert_dict(tiers[2]["rewards"]).is_equal({"coins": 30})
	assert_dict(tiers[3]["rewards"]).is_equal({"coins": 90, "item": "key"})
	assert_str(definition["timeout_tier"]).is_equal("")


func test_a_damaged_ladder_starts_over_with_three_rungs() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": DoubleOrNothingGame.KIND, "rungs": [{"label": "only"}]}
	)
	assert_int((definition["rungs"] as Array).size()).is_equal(3)


func test_a_timeout_tier_that_no_longer_exists_falls_back_to_the_lowest() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": SafeCrackerGame.KIND, "timeout_tier": "gone"}
	)
	assert_str(definition["timeout_tier"]).is_equal("")
	assert_str(MiniGameResolver.timeout_tier(definition)).is_equal("fail")


func test_attempts_are_clamped() -> void:
	assert_int(MiniGameLibrary.normalize_definition({"attempts": 0})["attempts"]).is_equal(1)
	assert_int(MiniGameLibrary.normalize_definition({"attempts": 9})["attempts"]).is_equal(5)


func test_hosts_and_kinds() -> void:
	assert_array(MiniGameLibrary.KIND_HOSTS[QuickTimeEventGame.KIND]).contains(
		[MiniGameLibrary.HOST_MOMENT]
	)
	assert_bool(MiniGameLibrary.is_chance(DoubleOrNothingGame.KIND)).is_true()
	assert_bool(MiniGameLibrary.is_chance(SafeCrackerGame.KIND)).is_false()


func test_rewards_keep_only_what_is_set() -> void:
	var rewards: Dictionary = (
		MiniGameLibrary
		. normalize_rewards(
			{
				"coins": -15,
				"item": " key ",
				"remove_items": ["", "map", "map"],
				"set_flags": ["opened"],
				"clear_flags": [],
				"set_counters": {"grit": 2, "": 5, "zero": 0},
				"score": 300,
				"junk": true,
			}
		)
	)
	(
		assert_dict(rewards)
		. is_equal(
			{
				"coins": -15,
				"item": "key",
				"remove_items": ["map"],
				"set_flags": ["opened"],
				"set_counters": {"grit": 2},
				"score": 300,
			}
		)
	)
	assert_dict(MiniGameLibrary.normalize_rewards({})).is_empty()


# Luck never reaches a leaderboard: a chance game's tiers can't award journey score.
func test_a_chance_game_cannot_award_score() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": DoubleOrNothingGame.KIND,
				"rungs": [{"rewards": {"coins": 10}}, {"rewards": {"score": 500, "coins": 40}}],
				"bust_rewards": {"score": 99},
			}
		)
	)
	var maxed: Dictionary = definition["tiers"][-1]
	assert_dict(maxed["rewards"]).is_equal({"coins": 40})
	assert_dict(definition["bust_rewards"]).is_empty()


func test_a_retry_cost_never_gives_anything() -> void:
	var cost: Dictionary = MiniGameLibrary.normalize_retry_cost(
		{"coins": 20, "item": "key", "score": 50, "set_counters": {"grit": -1}}
	)
	assert_dict(cost).is_equal({"coins": 20, "set_counters": {"grit": -1}})
	assert_dict(MiniGameLibrary.normalize_retry_cost({"coins": -5})).is_empty()


# Nodes reference definitions by id, so one without an id, or with a taken one, can't be kept.
func test_the_library_drops_definitions_it_cannot_reference() -> void:
	var library: Array = (
		MiniGameLibrary
		. parse_library(
			[
				{"id": "mg_a", "kind": SafeCrackerGame.KIND},
				{"id": "", "kind": SafeCrackerGame.KIND},
				{"id": "mg_a", "kind": DoubleOrNothingGame.KIND},
				"not a definition",
				{"id": "mg_b", "kind": DoubleOrNothingGame.KIND},
			]
		)
	)
	(
		assert_array(library.map(func(d: Dictionary) -> String: return d["id"]))
		. is_equal(["mg_a", "mg_b"])
	)
	assert_str(MiniGameLibrary.find(library, "mg_b")["kind"]).is_equal(DoubleOrNothingGame.KIND)
	assert_dict(MiniGameLibrary.find(library, "mg_z")).is_empty()
	assert_array(MiniGameLibrary.parse_library("garbage")).is_empty()


func test_retrying_needs_an_attempt_left() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": SafeCrackerGame.KIND, "attempts": 2}
	)
	assert_str(definition["retry_when"]).is_equal(MiniGameLibrary.RETRY_ANY)
	assert_bool(MiniGameLibrary.may_retry(definition, "pass", 1)).is_true()
	assert_bool(MiniGameLibrary.may_retry(definition, "pass", 2)).is_false()


# "Only after the lowest tier": a Pass is kept, a Fail may be retried. For Double or Nothing the lowest
# tier is the bust.
func test_retrying_only_after_the_lowest_tier() -> void:
	var skill: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": SafeCrackerGame.KIND, "attempts": 3, "retry_when": "lowest"}
	)
	assert_bool(MiniGameLibrary.may_retry(skill, "fail", 1)).is_true()
	assert_bool(MiniGameLibrary.may_retry(skill, "pass", 1)).is_false()
	var chance: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": DoubleOrNothingGame.KIND, "attempts": 3, "retry_when": "lowest"}
	)
	assert_bool(MiniGameLibrary.may_retry(chance, "busted", 1)).is_true()
	assert_bool(MiniGameLibrary.may_retry(chance, "cashed_1", 1)).is_false()
	(
		assert_str(MiniGameLibrary.normalize_definition({"retry_when": "sometimes"})["retry_when"])
		. is_equal(MiniGameLibrary.RETRY_ANY)
	)


func test_a_lookup_names_each_game() -> void:
	var lookup: Dictionary = MiniGameLibrary.name_lookup(
		[{"id": "mg_a", "name": "The Vault", "kind": SafeCrackerGame.KIND}, "junk"]
	)
	assert_dict(lookup).is_equal({"mg_a": {"name": "The Vault", "kind": SafeCrackerGame.KIND}})


func test_a_game_character_has_exactly_its_games_moments() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": DoubleOrNothingGame.KIND,
				"game_character":
				{
					"character": "c_vex",
					"placement": "right",
					"moments":
					{
						"win": {"portrait": "p_grin", "transition": "spin"},
						"bust": {"transition": "wobble"},
						"not_a_moment": {"portrait": "p_x"},
					},
				},
			}
		)
	)
	var block: Dictionary = definition["game_character"]
	assert_str(block["placement"]).is_equal("right")
	assert_array((block["moments"] as Dictionary).keys()).contains_exactly(["idle", "win", "bust"])
	assert_dict(block["moments"]["win"]).is_equal({"portrait": "p_grin", "transition": "spin"})
	assert_str(block["moments"]["bust"]["transition"]).is_equal(
		GameCharacterView.DEFAULT_TRANSITION
	)


func test_safe_cracker_has_its_own_character_moments() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": SafeCrackerGame.KIND, "game_character": {"character": "c_vex"}}
	)
	assert_array((definition["game_character"]["moments"] as Dictionary).keys()).contains_exactly(
		["idle", "opened", "wrong", "success", "failed"]
	)


func test_no_character_means_no_block() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": DoubleOrNothingGame.KIND, "game_character": {"placement": "left"}}
	)
	assert_dict(definition["game_character"]).is_empty()


# ── Resolver ─────────────────────────────────────────────────────────────────


func test_a_score_reaches_the_highest_tier_at_or_below_it() -> void:
	var tiers: Array = MiniGameLibrary.new_definition(SafeCrackerGame.KIND)["tiers"]
	assert_str(MiniGameResolver.tier_for_score(tiers, 0)).is_equal("fail")
	assert_str(MiniGameResolver.tier_for_score(tiers, 39)).is_equal("fail")
	assert_str(MiniGameResolver.tier_for_score(tiers, 40)).is_equal("pass")
	assert_str(MiniGameResolver.tier_for_score(tiers, 100)).is_equal("perfect")


func test_a_chance_outcome_is_its_own_tier() -> void:
	var tiers: Array = MiniGameLibrary.new_definition(DoubleOrNothingGame.KIND)["tiers"]
	assert_str(MiniGameResolver.tier_for_outcome(tiers, "cashed_2")).is_equal("cashed_2")
	assert_str(MiniGameResolver.tier_for_outcome(tiers, "cashed_9")).is_equal("")


func test_each_attempt_gets_its_own_seed() -> void:
	var first: int = MiniGameResolver.attempt_seed(1234, "node_a", 1)
	assert_int(first).is_equal(MiniGameResolver.attempt_seed(1234, "node_a", 1))
	assert_int(first).is_not_equal(MiniGameResolver.attempt_seed(1234, "node_a", 2))
	assert_int(first).is_not_equal(MiniGameResolver.attempt_seed(1234, "node_b", 1))
	assert_int(first).is_not_equal(MiniGameResolver.attempt_seed(1235, "node_a", 1))


# The lock is stored on the game, or it would be dropped on every load and save (the fixed-key-list trap).
func test_a_safe_crackers_lock_survives_normalizing() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": SafeCrackerGame.KIND, "lock": LockArt.STYLE_HANDCUFFS}
	)
	assert_str(str(definition["lock"])).is_equal(LockArt.STYLE_HANDCUFFS)


func test_a_missing_or_unknown_lock_is_a_safe() -> void:
	for raw: Dictionary in [
		{"kind": SafeCrackerGame.KIND}, {"kind": SafeCrackerGame.KIND, "lock": "bank vault"}
	]:
		var definition: Dictionary = MiniGameLibrary.normalize_definition(raw)
		assert_str(str(definition["lock"])).is_equal(LockArt.STYLE_SAFE)


# ── Flags on tiers ───────────────────────────────────────────────────────────


# Routing on a result is a flag the creator sets on a tier. A fork reading one must not be told nothing sets it.
func test_the_flags_a_creator_set_on_a_skill_games_tiers_are_found() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"id": "g",
				"kind": SafeCrackerGame.KIND,
				"tiers":
				[
					{"name": "Fail", "min_score": 0, "rewards": {"clear_flags": ["opened"]}},
					{"name": "Pass", "min_score": 40, "rewards": {"set_flags": ["opened"]}},
				],
				"retry_cost": {"set_flags": ["cheated"]},
			}
		)
	)
	var names: Array = MiniGameLibrary.flag_names([definition])
	assert_int(names.count("opened")).is_equal(2)
	assert_int(names.count("cheated")).is_equal(1)


# Once each: a ladder's tiers repeat its rungs, so reading those would count every flag twice or more.
func test_the_flags_on_a_ladder_are_counted_once_each() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"id": "g",
				"kind": DoubleOrNothingGame.KIND,
				"rungs":
				[
					{"rewards": {"set_flags": ["climbed"]}},
					{"rewards": {}},
				],
				"bust_rewards": {"set_flags": ["busted"]},
			}
		)
	)
	var names: Array = MiniGameLibrary.flag_names([definition])
	assert_int(names.count("climbed")).is_equal(1)
	assert_int(names.count("busted")).is_equal(1)


# Nothing a creator didn't ask for: the flag pickers list only what they made.
func test_an_untouched_game_adds_no_flags() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(SafeCrackerGame.KIND)
	assert_array(MiniGameLibrary.flag_names([definition])).is_empty()


# ── Tiers nobody can reach ───────────────────────────────────────────────────


func test_a_tier_between_a_safe_crackers_score_steps_cannot_be_reached() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": SafeCrackerGame.KIND,
				"knobs": {"numbers": 1, "time_limit_s": 30},
				"tiers":
				[
					{"id": "low", "name": "Low", "min_score": 0},
					{"id": "gap", "name": "Gap", "min_score": 90},
					{"id": "top", "name": "Top", "min_score": 100},
				],
			}
		)
	)
	var names: Array = MiniGameLibrary.unreachable_tiers(definition).map(
		func(tier: Dictionary) -> String: return str(tier["id"])
	)
	assert_array(names).is_equal(["gap"])


# A game with no way to fail can't end below its lowest share.
func test_a_fail_tier_cannot_be_reached_with_no_limits() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": SafeCrackerGame.KIND, "knobs": {"time_limit_s": 0, "max_wrong": 0}}
	)
	var names: Array = MiniGameLibrary.unreachable_tiers(definition).map(
		func(tier: Dictionary) -> String: return str(tier["id"])
	)
	assert_array(names).is_equal(["fail"])


func test_a_new_safe_cracker_can_reach_every_tier() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(SafeCrackerGame.KIND)
	assert_array(MiniGameLibrary.unreachable_tiers(definition)).is_empty()


func test_only_a_safe_cracker_has_score_gaps() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(QuickTimeEventGame.KIND)
	assert_array(MiniGameLibrary.unreachable_tiers(definition)).is_empty()


func test_the_counters_a_tier_changes_are_found() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"id": "g",
				"kind": SafeCrackerGame.KIND,
				"tiers":
				[{"name": "All", "min_score": 0, "rewards": {"set_counters": {"grit": 2}}}],
			}
		)
	)
	assert_array(MiniGameLibrary.counter_names([definition])).is_equal(["grit"])


func test_a_tier_is_named_for_the_player() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(SafeCrackerGame.KIND)
	assert_str(MiniGameResolver.tier_name(definition, "perfect")).is_equal("Perfect")
	assert_str(MiniGameResolver.tier_name(definition, "nothing")).is_equal("")


# The end screen prints this log, so a game has to land in it, in order with the rounds.
func test_a_played_game_lands_in_the_play_log() -> void:
	GameState.LogMiniGame("The Vault", "Perfect")
	var entry: Dictionary = GameState.GetPlayLog()[-1]
	assert_str(str(entry["type"])).is_equal("minigame")
	assert_str(str(entry["name"])).is_equal("The Vault")
	assert_str(str(entry["tier"])).is_equal("Perfect")


# ── A game's framing ─────────────────────────────────────────────────────────


# These go through normalize_definition, so each has to be listed there or a save would drop it.
func test_the_framing_survives_normalizing() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": SafeCrackerGame.KIND,
				"intro_text": "  The vault hums.  ",
				"accent_color": "12ab34",
				"tiers": [{"id": "all", "name": "All", "min_score": 0, "result_text": "It opens."}],
			}
		)
	)
	assert_str(str(definition["intro_text"])).is_equal("The vault hums.")
	assert_str(str(definition["accent_color"])).is_equal("12ab34")
	assert_str(MiniGameResolver.tier_result_text(definition, "all")).is_equal("It opens.")


func test_a_ladders_result_text_reaches_its_tiers() -> void:
	var definition: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": DoubleOrNothingGame.KIND,
				"rungs": [{"result_text": "Safe."}, {"result_text": "Bold."}],
				"bust_result_text": "Gone.",
			}
		)
	)
	var by_id: Dictionary = {}
	for tier: Dictionary in definition["tiers"]:
		by_id[tier["id"]] = tier["result_text"]
	assert_str(str(by_id[DoubleOrNothingGame.OUTCOME_BUSTED])).is_equal("Gone.")
	assert_str(str(by_id[DoubleOrNothingGame.CASHED_PREFIX + "1"])).is_equal("Safe.")
	assert_str(str(by_id[DoubleOrNothingGame.OUTCOME_MAXED])).is_equal("Bold.")


func test_a_new_game_uses_the_apps_accent() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(SafeCrackerGame.KIND)
	assert_str(str(definition["accent_color"])).is_empty()
	assert_bool(MiniGameLibrary.accent_color(definition) == UITheme.MINIGAME).is_true()


func test_a_bad_accent_falls_back_to_the_apps() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": SafeCrackerGame.KIND, "accent_color": "not a colour"}
	)
	assert_str(str(definition["accent_color"])).is_empty()


func test_a_chosen_accent_is_used() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": SafeCrackerGame.KIND, "accent_color": "ff0000"}
	)
	assert_bool(MiniGameLibrary.accent_color(definition) == Color.html("ff0000")).is_true()


# It has no screen of its own for an intro or an accent to appear on.
func test_a_quick_time_event_has_no_intro_or_accent() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(QuickTimeEventGame.KIND)
	assert_bool(definition.has("intro_text")).is_false()
	assert_bool(definition.has("accent_color")).is_false()


# ── The player's assist ──────────────────────────────────────────────────────


# Loads a one-node run with the assisted mark as given. A save only restores onto a node that exists.
func _load_run(assisted: bool) -> void:
	GameState.LoadFromSave(
		{"nodes": {"here": {"type": "round"}}, "start": "here"},
		{"current_node": "here", "minigame_assisted": assisted}
	)


# A resume has to keep the mark: otherwise quitting and reloading would wash an assisted run clean.
func test_the_assisted_mark_rides_the_save() -> void:
	_load_run(true)
	assert_bool(bool(GameState.CaptureSaveData()["minigame_assisted"])).is_true()
	assert_bool(GameState.MiniGameAssisted).is_true()
	_load_run(false)
	assert_bool(bool(GameState.CaptureSaveData()["minigame_assisted"])).is_false()
	assert_bool(GameState.MiniGameAssisted).is_false()


func test_only_a_game_started_with_the_switch_on_marks_the_run() -> void:
	var was_on: bool = SettingsService.get_minigame_assist()
	_load_run(false)
	SettingsService.set_minigame_assist(false)
	MiniGameAssist.note_game_started()
	assert_bool(GameState.MiniGameAssisted).is_false()
	assert_float(MiniGameAssist.time_scale()).is_equal(1.0)
	SettingsService.set_minigame_assist(true)
	MiniGameAssist.note_game_started()
	assert_bool(GameState.MiniGameAssisted).is_true()
	assert_float(MiniGameAssist.time_scale()).is_equal(MiniGameAssist.ASSISTED_TIME_SCALE)
	SettingsService.set_minigame_assist(was_on)
	_load_run(false)
