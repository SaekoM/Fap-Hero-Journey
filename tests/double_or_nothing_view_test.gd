extends GdUnitTestSuite

# Double or Nothing's play view: E must do nothing from SPIN until the player can choose again. Spamming it
# through the landing used to spend extra risks unseen, skipping rungs and ending the game.

const RUNGS: int = 6

const RecordingDevice = preload("res://tests/recording_device.gd")


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
	var device: RecordingDevice = RecordingDevice.new()
	view.setup(definition, game, device, null)
	return {"view": view, "game": game, "device": device}


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
		RecordingDevice.new(),
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


# ── The device ───────────────────────────────────────────────────────────────


func test_a_spin_asks_for_one_walk_rather_than_a_change_every_frame() -> void:
	var setup: Dictionary = _view_after_a_win()
	var device: RecordingDevice = setup["device"]
	device.calls.clear()
	setup["view"]._spin()
	await await_millis(200)
	assert_array(device.calls).contains_exactly(["walk"])


func test_cashing_out_eases_the_device_home() -> void:
	var setup: Dictionary = _view_after_a_win()
	var device: RecordingDevice = setup["device"]
	device.calls.clear()
	setup["view"]._cash_out()
	assert_array(device.calls).contains_exactly(["ease_out"])


func test_a_bust_stops_the_device_dead() -> void:
	var setup: Dictionary = _view_after_a_win()
	var device: RecordingDevice = setup["device"]
	device.calls.clear()
	setup["view"]._landed(false)
	assert_array(device.calls).contains_exactly(["stop"])


func test_the_spinning_wheel_drives_the_extra_axes() -> void:
	var setup: Dictionary = _view_after_a_win()
	setup["view"]._spin()
	await await_millis(200)
	assert_bool((setup["device"] as RecordingDevice).streamed_axes.is_empty()).is_false()


func test_a_win_nods_and_a_bust_does_not() -> void:
	var setup: Dictionary = _view_after_a_win()
	var device: RecordingDevice = setup["device"]
	setup["view"]._landed(false)
	assert_array(device.axis_moves).is_empty()
	setup["view"]._landed(true)
	assert_array(device.axis_moves).is_equal([MiniGameAxes.WIN_NOD])
