extends GdUnitTestSuite

# Push Your Luck's rules: the starting pot, the visible bag and the odds it gives, what each token does, and its tiers.

# No specials, unless a test adds them.
const PLAIN: Dictionary = {
	"value_tokens": 4, "traps": 2, "shields": 0, "doublers": 0, "base_gain": 10, "gain_growth": 10
}


func _knobs_with(changes: Dictionary) -> Dictionary:
	var knobs: Dictionary = PLAIN.duplicate()
	knobs.merge(changes, true)
	return knobs


# The bag's order comes from the seed, so a test finds a seed that draws what it needs.
func _game_drawing_first(token: String, knobs: Dictionary) -> PushYourLuckGame:
	for seed_value: int in 2000:
		var probe: PushYourLuckGame = PushYourLuckGame.new(knobs, seed_value)
		probe.push()
		if probe.last_token == token:
			return PushYourLuckGame.new(knobs, seed_value)
	return null


func test_the_player_starts_with_something_to_lose() -> void:
	var game: PushYourLuckGame = PushYourLuckGame.new(PLAIN, 1)
	assert_bool(game.pot >= 5 and game.pot <= 15).is_true()
	assert_int(game.pushes).is_equal(0)
	assert_bool(game.is_finished()).is_false()


func test_the_bag_holds_what_the_creator_set() -> void:
	var knobs: Dictionary = _knobs_with({"shields": 2, "doublers": 1})
	var game: PushYourLuckGame = PushYourLuckGame.new(knobs, 1)
	assert_int(game.tokens_left(PushYourLuckGame.TOKEN_VALUE)).is_equal(4)
	assert_int(game.tokens_left(PushYourLuckGame.TOKEN_TRAP)).is_equal(2)
	assert_int(game.tokens_left(PushYourLuckGame.TOKEN_SHIELD)).is_equal(2)
	assert_int(game.tokens_left(PushYourLuckGame.TOKEN_DOUBLER)).is_equal(1)
	assert_int(game.total_tokens_left()).is_equal(9)
	assert_int(game.safe_tokens_at_start()).is_equal(7)


func test_the_risk_is_the_traps_share_of_whats_left() -> void:
	var game: PushYourLuckGame = _game_drawing_first(PushYourLuckGame.TOKEN_VALUE, PLAIN)
	assert_int(game.risk_pct()).is_equal(33)  # 2 in 6
	game.push()
	assert_int(game.risk_pct()).is_equal(40)  # 2 in 5


func test_a_drawn_token_stays_out() -> void:
	var game: PushYourLuckGame = _game_drawing_first(PushYourLuckGame.TOKEN_VALUE, PLAIN)
	game.push()
	assert_int(game.tokens_left(PushYourLuckGame.TOKEN_VALUE)).is_equal(3)
	assert_int(game.total_tokens_left()).is_equal(5)


func test_a_value_token_adds_within_its_range() -> void:
	var game: PushYourLuckGame = _game_drawing_first(PushYourLuckGame.TOKEN_VALUE, PLAIN)
	var before: int = game.pot
	var gain: Vector2i = game.next_gain_range()
	assert_bool(game.push()).is_true()
	assert_int(game.pot).is_equal(before + game.last_gain)
	assert_bool(game.last_gain >= gain.x and game.last_gain <= gain.y).is_true()


func test_values_grow_with_each_one_drawn() -> void:
	var game: PushYourLuckGame = _game_drawing_first(PushYourLuckGame.TOKEN_VALUE, PLAIN)
	var first: Vector2i = game.next_gain_range()
	game.push()
	var later: Vector2i = game.next_gain_range()
	assert_bool(later.x > first.x and later.y > first.y).is_true()


func test_a_trap_with_no_shield_busts() -> void:
	var game: PushYourLuckGame = _game_drawing_first(PushYourLuckGame.TOKEN_TRAP, PLAIN)
	assert_bool(game.push()).is_false()
	assert_bool(game.busted).is_true()
	assert_bool(game.is_finished()).is_true()
	assert_str(game.final_tier_id([{"id": "small", "min_pot": 0}])).is_equal(
		PushYourLuckGame.OUTCOME_BUSTED
	)
	assert_bool(game.push()).is_false()


func test_a_held_shield_drops_the_risk_to_nothing_and_takes_one_trap() -> void:
	var knobs: Dictionary = _knobs_with({"shields": 1, "value_tokens": 10, "traps": 1})
	var game: PushYourLuckGame = _game_drawing_first(PushYourLuckGame.TOKEN_SHIELD, knobs)
	game.push()
	assert_int(game.shields_held).is_equal(1)
	assert_int(game.risk_pct()).is_equal(0)
	# Draw until the trap comes out: the shield must take it.
	while game.tokens_left(PushYourLuckGame.TOKEN_TRAP) > 0 and not game.is_finished():
		assert_bool(game.push()).is_true()
	assert_bool(game.busted).is_false()
	assert_int(game.shields_held).is_equal(0)


func test_a_doubler_doubles_the_pot() -> void:
	var knobs: Dictionary = _knobs_with({"doublers": 1})
	var game: PushYourLuckGame = _game_drawing_first(PushYourLuckGame.TOKEN_DOUBLER, knobs)
	var before: int = game.pot
	game.push()
	assert_int(game.pot).is_equal(before * 2)
	assert_int(game.last_gain).is_equal(0)


func test_banking_ends_the_game_and_keeps_the_pot() -> void:
	var game: PushYourLuckGame = PushYourLuckGame.new(PLAIN, 1)
	var held: int = game.pot
	game.bank()
	assert_bool(game.is_finished()).is_true()
	assert_int(game.pot).is_equal(held)
	assert_bool(game.push()).is_false()


func test_when_only_traps_remain_it_banks_by_itself() -> void:
	# With two value tokens and a shield for every trap, every order gets to the end alive.
	var knobs: Dictionary = {
		"value_tokens": 2,
		"traps": 3,
		"shields": 3,
		"doublers": 0,
		"base_gain": 10,
		"gain_growth": 0
	}
	for seed_value: int in 200:
		var game: PushYourLuckGame = PushYourLuckGame.new(knobs, seed_value)
		while not game.is_finished():
			game.push()
		if game.banked:
			assert_bool(game.is_bag_cleared()).is_true()
			assert_int(game.tokens_left(PushYourLuckGame.TOKEN_VALUE)).is_equal(0)
			assert_int(game.tokens_left(PushYourLuckGame.TOKEN_SHIELD)).is_equal(0)
			return
	fail("No seed reached the end of the bag")


func test_a_seed_always_plays_the_same_way() -> void:
	var one: PushYourLuckGame = PushYourLuckGame.new(PLAIN, 42)
	var two: PushYourLuckGame = PushYourLuckGame.new(PLAIN, 42)
	assert_int(one.pot).is_equal(two.pot)
	for _push in 3:
		assert_bool(one.push()).is_equal(two.push())
		assert_str(one.last_token).is_equal(two.last_token)
		assert_int(one.pot).is_equal(two.pot)


func test_different_seeds_shuffle_differently() -> void:
	var orders: Dictionary = {}
	for seed_value: int in 50:
		var game: PushYourLuckGame = PushYourLuckGame.new(PLAIN, seed_value)
		game.push()
		orders[game.last_token] = true
	assert_int(orders.size()).is_equal(2)


func test_the_pot_lands_in_the_highest_tier_it_reaches() -> void:
	var tiers: Array = [
		{"id": "busted"},
		{"id": "small", "min_pot": 0},
		{"id": "big", "min_pot": 50},
	]
	assert_str(PushYourLuckGame.tier_for_pot(tiers, 49)).is_equal("small")
	assert_str(PushYourLuckGame.tier_for_pot(tiers, 50)).is_equal("big")


func test_highest_pot_is_every_value_at_its_top_then_every_doubling() -> void:
	# Averages 10, 20, 30, 40, 50 for the start and four value tokens, each up to half as much again.
	assert_int(PushYourLuckGame.highest_pot(PLAIN)).is_equal(225)
	assert_int(PushYourLuckGame.highest_pot(_knobs_with({"doublers": 2}))).is_equal(900)
	assert_int(PushYourLuckGame.typical_pot(PLAIN, 4)).is_equal(150)


func test_a_full_bag_of_safe_tokens_fits_the_tallest_stack() -> void:
	var most: int = (
		int(PushYourLuckGame.KNOB_RANGES["value_tokens"][1])
		+ int(PushYourLuckGame.KNOB_RANGES["shields"][1])
		+ int(PushYourLuckGame.KNOB_RANGES["doublers"][1])
	)
	assert_int(most).is_equal(15)


func test_knobs_are_clamped_and_default() -> void:
	var knobs: Dictionary = PushYourLuckGame.normalize_knobs({"traps": 99, "value_tokens": 1})
	assert_int(knobs["traps"]).is_equal(10)
	assert_int(knobs["value_tokens"]).is_equal(2)
	assert_int(knobs["shields"]).is_equal(1)
	assert_int(knobs["doublers"]).is_equal(1)
	assert_int(knobs["base_gain"]).is_equal(10)


# ── In the library ───────────────────────────────────────────────────────────


func _definition() -> Dictionary:
	return MiniGameLibrary.new_definition(PushYourLuckGame.KIND)


func test_a_new_game_has_a_bust_and_three_pot_tiers() -> void:
	var tiers: Array = _definition()["tiers"]
	(
		assert_array(tiers.map(func(t: Dictionary) -> String: return t["id"]))
		. is_equal([PushYourLuckGame.OUTCOME_BUSTED, "small", "medium", "large"])
	)
	assert_bool(tiers[0].has("min_pot")).is_false()
	assert_int(tiers[1]["min_pot"]).is_equal(0)


func test_it_is_a_chance_game_so_it_can_never_award_journey_score() -> void:
	var definition: Dictionary = _definition()
	assert_bool(MiniGameLibrary.is_chance(definition["kind"])).is_true()
	definition["pot_tiers"][0]["rewards"] = {"coins": 5, "score": 100}
	definition["bust_rewards"] = {"coins": -5, "score": 100}
	var loaded: Dictionary = MiniGameLibrary.normalize_definition(definition)
	assert_bool(loaded["pot_tiers"][0]["rewards"].has("score")).is_false()
	assert_int(loaded["pot_tiers"][0]["rewards"]["coins"]).is_equal(5)
	assert_bool(loaded["bust_rewards"].has("score")).is_false()


func test_the_bag_survives_the_library() -> void:
	var definition: Dictionary = _definition()
	definition["knobs"]["traps"] = 7
	definition["knobs"]["shields"] = 0
	var loaded: Dictionary = MiniGameLibrary.normalize_definition(definition)
	assert_int(loaded["knobs"]["traps"]).is_equal(7)
	assert_int(loaded["knobs"]["shields"]).is_equal(0)


func test_pot_tiers_sort_and_the_lowest_starts_at_nothing() -> void:
	var loaded: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": PushYourLuckGame.KIND,
				"pot_tiers":
				[
					{"id": "big", "name": "Big", "min_pot": 500},
					{"id": "low", "name": "Low", "min_pot": 20},
				],
			}
		)
	)
	var pots: Array = loaded["pot_tiers"].map(func(t: Dictionary) -> int: return t["min_pot"])
	assert_array(pots).is_equal([0, 500])
	assert_str(loaded["pot_tiers"][0]["id"]).is_equal("low")


func test_a_tier_called_busted_cant_take_the_busts_place() -> void:
	var loaded: Dictionary = (
		MiniGameLibrary
		. normalize_definition(
			{
				"kind": PushYourLuckGame.KIND,
				"pot_tiers":
				[{"id": PushYourLuckGame.OUTCOME_BUSTED, "name": "Busted", "min_pot": 0}],
			}
		)
	)
	var tiers: Array = loaded["tiers"]
	assert_str(tiers[0]["id"]).is_equal(PushYourLuckGame.OUTCOME_BUSTED)
	assert_bool(tiers[1]["id"] != PushYourLuckGame.OUTCOME_BUSTED).is_true()
	assert_bool(tiers[1].has("min_pot")).is_true()


func test_a_flag_on_a_pot_tier_or_the_bust_is_found() -> void:
	var definition: Dictionary = _definition()
	definition["pot_tiers"][1]["rewards"] = {"set_flags": ["rich"]}
	definition["bust_rewards"] = {"set_flags": ["broke"]}
	var loaded: Dictionary = MiniGameLibrary.normalize_definition(definition)
	var names: Array = MiniGameLibrary.flag_names([loaded])
	assert_bool(names.has("rich")).is_true()
	assert_bool(names.has("broke")).is_true()


func test_each_result_is_listed_for_the_state_overlay() -> void:
	var labels: Array = MiniGameLibrary.reward_sources(_definition()).map(
		func(source: Dictionary) -> String: return source["label"]
	)
	assert_array(labels).is_equal(["Small", "Medium", "Large", "Bust"])


func test_a_tier_out_of_reach_is_reported() -> void:
	var definition: Dictionary = _definition()
	definition["pot_tiers"][2]["min_pot"] = PushYourLuckGame.MAX_POT
	var loaded: Dictionary = MiniGameLibrary.normalize_definition(definition)
	var out_of_reach: Array = MiniGameLibrary.unreachable_tiers(loaded)
	assert_int(out_of_reach.size()).is_equal(1)
	assert_str(out_of_reach[0]["id"]).is_equal("large")


func test_placing_one_needs_the_build_that_plays_it() -> void:
	var library: Array = [{"id": "push", "kind": PushYourLuckGame.KIND}]
	var graph: Dictionary = {"nodes": {"a": {"type": "minigame", "data": {"game": "push"}}}}
	assert_bool(JourneyData.graph_needs_newer_build(graph, library)).is_true()


func test_an_untouched_game_pays_the_lowest_pot_tier() -> void:
	assert_str(MiniGameLibrary.untouched_chance_tier(_definition())).is_equal("small")
	var ladder: Dictionary = MiniGameLibrary.new_definition(DoubleOrNothingGame.KIND)
	assert_str(MiniGameLibrary.untouched_chance_tier(ladder)).is_equal(
		DoubleOrNothingGame.CASHED_PREFIX + "1"
	)
