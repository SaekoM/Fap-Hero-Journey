extends GdUnitTestSuite

# Safe-Cracker: the combination dial. Pure — a seed plus inputs in, a score out.


func _game(knobs: Dictionary = {}, rng_seed: int = 7) -> SafeCrackerGame:
	return SafeCrackerGame.new(knobs, rng_seed)


func test_the_same_seed_draws_the_same_combination() -> void:
	assert_array(_game({}, 42).combination).is_equal(_game({}, 42).combination)
	assert_array(_game({}, 42).combination).is_not_equal(_game({}, 43).combination)


func test_knobs_are_clamped_and_defaulted() -> void:
	var knobs: Dictionary = SafeCrackerGame.normalize_knobs(
		{"numbers": 9, "dial_size": 5, "warmth": "x"}
	)
	assert_int(knobs["numbers"]).is_equal(6)
	assert_int(knobs["dial_size"]).is_equal(20)
	assert_str(knobs["warmth"]).is_equal(SafeCrackerGame.WARMTH_PRECISE)
	assert_int(knobs["time_limit_s"]).is_equal(45)


# No number can be opened without turning: each sits at least a real gap from where its search starts.
func test_every_number_needs_a_turn() -> void:
	for rng_seed in 50:
		var game: SafeCrackerGame = _game({"numbers": 6, "tolerance": 3}, rng_seed)
		var from: int = 0
		for number: int in game.combination:
			var gap: int = absi(number - from)
			assert_int(mini(gap, 40 - gap)).is_greater(3)
			from = number


func test_opening_every_number_first_try_scores_100() -> void:
	var game: SafeCrackerGame = _game()
	for number: int in game.combination:
		game.set_position(number)
		assert_bool(game.try_open()).is_true()
	assert_bool(game.is_finished()).is_true()
	assert_str(game.end_reason).is_equal(SafeCrackerGame.END_OPENED)
	assert_int(game.score()).is_equal(100)


func test_a_try_within_tolerance_opens() -> void:
	var game: SafeCrackerGame = _game({"tolerance": 2})
	game.set_position(game.combination[0] + 2)
	assert_bool(game.try_open()).is_true()


func test_wrong_tries_reduce_that_numbers_share() -> void:
	var game: SafeCrackerGame = _game({"numbers": 2})
	game.set_position(game.combination[0] + 10)
	game.try_open()  # wrong
	game.try_open()  # wrong
	game.set_position(game.combination[0])
	game.try_open()
	game.set_position(game.combination[1])
	game.try_open()
	# number 1: 1 − 0.15·2 = 0.70; number 2: 1.0 → (0.70 + 1.0) / 2 = 85%
	assert_int(game.score()).is_equal(85)


func test_a_numbers_share_never_drops_below_40_percent() -> void:
	var game: SafeCrackerGame = _game({"numbers": 1})
	game.set_position(game.combination[0] + 10)
	for _i in 10:
		game.try_open()
	game.set_position(game.combination[0])
	game.try_open()
	assert_int(game.score()).is_equal(40)


func test_unopened_numbers_earn_nothing_when_time_runs_out() -> void:
	var game: SafeCrackerGame = _game({"numbers": 2, "time_limit_s": 10})
	game.set_position(game.combination[0])
	game.try_open()
	game.advance_to(9999)
	assert_bool(game.is_finished()).is_false()
	game.advance_to(10000)
	assert_str(game.end_reason).is_equal(SafeCrackerGame.END_TIME)
	assert_int(game.score()).is_equal(50)
	game.set_position(game.combination[1])
	assert_bool(game.try_open()).is_false()  # finished games take no input


func test_no_time_limit_never_times_out() -> void:
	var game: SafeCrackerGame = _game({"time_limit_s": 0})
	game.advance_to(10_000_000)
	assert_bool(game.is_finished()).is_false()


func test_the_dial_jams_at_the_wrong_try_limit() -> void:
	var game: SafeCrackerGame = _game({"max_wrong": 3})
	game.set_position(game.combination[0] + 10)
	game.try_open()
	game.try_open()
	assert_bool(game.is_finished()).is_false()
	game.try_open()
	assert_str(game.end_reason).is_equal(SafeCrackerGame.END_JAMMED)
	assert_int(game.score()).is_equal(0)


func test_the_dial_wraps_around() -> void:
	var game: SafeCrackerGame = _game({"dial_size": 40})
	game.set_position(0)
	game.turn(-1)
	assert_int(game.position).is_equal(39)
	game.turn(3)
	assert_int(game.position).is_equal(2)


func test_precise_warmth_is_1_on_the_number_and_0_opposite_it() -> void:
	var game: SafeCrackerGame = _game({"dial_size": 40})
	game.set_position(game.combination[0])
	assert_float(game.warmth()).is_equal(1.0)
	game.set_position(game.combination[0] + 20)
	assert_float(game.warmth()).is_equal(0.0)


# With the meter off, warmth still reads precisely: the screen pitches the dial's click with it.
func test_warmth_off_still_reads_precisely() -> void:
	var game: SafeCrackerGame = _game({"dial_size": 40, "warmth": "off"})
	game.set_position(game.combination[0] + 10)
	assert_float(game.warmth()).is_equal(0.5)
	assert_str(SafeCrackerGame.normalize_knobs({"warmth": "off"})["warmth"]).is_equal("off")


func test_coarse_warmth_has_three_bands() -> void:
	var game: SafeCrackerGame = _game({"dial_size": 40, "tolerance": 1, "warmth": "coarse"})
	var target: int = game.combination[0]
	game.set_position(target + 2)
	assert_float(game.warmth()).is_equal(1.0)  # hot: within tolerance + 1
	game.set_position(target + 6)
	assert_float(game.warmth()).is_equal(0.5)  # warm: within a sixth of the dial
	game.set_position(target + 15)
	assert_float(game.warmth()).is_equal(0.0)  # cold
