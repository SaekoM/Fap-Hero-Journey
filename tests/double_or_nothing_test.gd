extends GdUnitTestSuite

# Double or Nothing: a ladder of rewards, cash out or risk it. Chance — it ends in a named outcome.


func test_cashing_out_straight_away_keeps_rung_1() -> void:
	var game: DoubleOrNothingGame = DoubleOrNothingGame.new(3, 50, 1)
	game.cash_out()
	assert_str(game.outcome).is_equal("cashed_1")
	assert_int(DoubleOrNothingGame.rung_paid(game.outcome, 3)).is_equal(1)


func test_the_same_seed_flips_the_same_way() -> void:
	for rng_seed in 20:
		var a: DoubleOrNothingGame = DoubleOrNothingGame.new(6, 50, rng_seed)
		var b: DoubleOrNothingGame = DoubleOrNothingGame.new(6, 50, rng_seed)
		while not a.is_finished():
			assert_bool(a.risk()).is_equal(b.risk())
		assert_str(a.outcome).is_equal(b.outcome)


# Climbing onto the top rung cashes out by itself as "maxed".
func test_reaching_the_top_rung_is_maxed() -> void:
	var game: DoubleOrNothingGame = DoubleOrNothingGame.new(3, 90, 0)
	var rng_seed: int = 0
	while true:  # find a seed that wins both flips at 90%
		game = DoubleOrNothingGame.new(3, 90, rng_seed)
		if game.risk() and game.risk():
			break
		rng_seed += 1
	assert_str(game.outcome).is_equal(DoubleOrNothingGame.OUTCOME_MAXED)
	assert_int(game.rung).is_equal(3)
	assert_int(DoubleOrNothingGame.rung_paid(game.outcome, 3)).is_equal(3)


func test_a_lost_flip_busts_and_pays_nothing() -> void:
	var rng_seed: int = 0
	var game: DoubleOrNothingGame = DoubleOrNothingGame.new(4, 10, rng_seed)
	while game.risk():  # at 10% a bust comes quickly
		rng_seed += 1
		game = DoubleOrNothingGame.new(4, 10, rng_seed)
	assert_str(game.outcome).is_equal(DoubleOrNothingGame.OUTCOME_BUSTED)
	assert_int(DoubleOrNothingGame.rung_paid(game.outcome, 4)).is_equal(0)
	game.cash_out()  # a finished game takes no more choices
	assert_str(game.outcome).is_equal(DoubleOrNothingGame.OUTCOME_BUSTED)


func test_the_odds_knob_is_honoured() -> void:
	var wins: int = 0
	for rng_seed in 2000:
		if DoubleOrNothingGame.new(2, 30, rng_seed).risk():
			wins += 1
	assert_int(wins).is_between(500, 700)  # ≈ 30%


func test_odds_are_clamped() -> void:
	assert_int(DoubleOrNothingGame.normalize_odds(0)).is_equal(10)
	assert_int(DoubleOrNothingGame.normalize_odds(100)).is_equal(90)


func test_timing_out_keeps_the_rung_held() -> void:
	var rng_seed: int = 0
	var game: DoubleOrNothingGame = DoubleOrNothingGame.new(4, 90, rng_seed)
	while not game.risk():  # find a seed whose first flip wins
		rng_seed += 1
		game = DoubleOrNothingGame.new(4, 90, rng_seed)
	game.time_out()
	assert_str(game.outcome).is_equal("cashed_2")


func test_the_outcomes_of_a_ladder() -> void:
	assert_array(DoubleOrNothingGame.outcomes_for(3)).is_equal(
		["busted", "cashed_1", "cashed_2", "maxed"]
	)
	assert_array(DoubleOrNothingGame.outcomes_for(2)).is_equal(["busted", "cashed_1", "maxed"])
	assert_int(DoubleOrNothingGame.outcomes_for(99).size()).is_equal(7)  # clamped to 6 rungs
