extends GdUnitTestSuite

# Double or Nothing's play view: E must do nothing from SPIN until the player can choose again. Spamming it
# through the landing used to spend extra risks unseen, skipping rungs and ending the game.

const RUNGS: int = 6


func _press_e(view: DoubleOrNothingView) -> void:
	var key: InputEventKey = InputEventKey.new()
	key.keycode = KEY_E
	key.pressed = true
	view.handle_input(key)


# A view in play on a game whose first risk (made here) won, with rungs left to climb.
func _view_after_a_win() -> Dictionary:
	var rng_seed: int = 0
	var game: DoubleOrNothingGame = DoubleOrNothingGame.new(RUNGS, 50, rng_seed)
	while not game.risk():
		rng_seed += 1
		game = DoubleOrNothingGame.new(RUNGS, 50, rng_seed)
	var rungs: Array = []
	for _i in RUNGS:
		rungs.append({"label": "", "rewards": {}})
	var definition: Dictionary = MiniGameLibrary.normalize_definition(
		{"kind": DoubleOrNothingGame.KIND, "rungs": rungs, "knobs": {"odds": 50}}
	)
	var view: DoubleOrNothingView = auto_free(DoubleOrNothingView.new())
	add_child(view)
	view.setup(definition, game, func(_lo: int, _hi: int, _half: int) -> void: pass, null)
	return {"view": view, "game": game}


func test_e_is_ignored_while_the_wheel_spins() -> void:
	var game: DoubleOrNothingGame = DoubleOrNothingGame.new(RUNGS, 90, 1)
	var rungs: Array = []
	for _i in RUNGS:
		rungs.append({"label": "", "rewards": {}})
	var view: DoubleOrNothingView = auto_free(DoubleOrNothingView.new())
	add_child(view)
	view.setup(
		MiniGameLibrary.normalize_definition({"kind": DoubleOrNothingGame.KIND, "rungs": rungs}),
		game,
		func(_lo: int, _hi: int, _half: int) -> void: pass,
		null
	)
	_press_e(view)  # the one real spin: its risk is drawn now
	var rung_after_first: int = game.rung
	var outcome_after_first: String = game.outcome
	for _i in 10:
		_press_e(view)
	assert_int(game.rung).is_equal(rung_after_first)
	assert_str(game.outcome).is_equal(outcome_after_first)


# The regression itself: the wheel has stopped, but the celebration and the hold are still playing.
func test_e_is_ignored_after_the_wheel_lands_until_the_result_is_clear() -> void:
	var setup: Dictionary = _view_after_a_win()
	var view: DoubleOrNothingView = setup["view"]
	var game: DoubleOrNothingGame = setup["game"]
	view._locked = true  # as _spin leaves it
	view._landed(true)  # runs up to its first wait, then the celebration plays on
	for _i in 10:
		_press_e(view)
	assert_int(game.rung).is_equal(2)
	assert_str(game.outcome).is_equal("")
	assert_bool(view._locked).is_true()
