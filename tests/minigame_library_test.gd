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


# Only the tier reached is set; every other tier's flag is cleared, so a replay in a loop can't leave a
# stale Perfect behind.
func test_resolving_sets_one_tier_flag_and_clears_the_rest() -> void:
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"id": "mg_lock", "kind": SafeCrackerGame.KIND}
	)
	var changes: Dictionary = MiniGameResolver.flag_changes(definition, "pass")
	assert_array(changes["set"]).is_equal(["mg_lock_pass"])
	assert_array(changes["clear"]).is_equal(["mg_lock_fail", "mg_lock_perfect"])


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
