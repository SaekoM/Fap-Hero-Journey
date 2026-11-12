extends GdUnitTestSuite

# What Stop the Bar, Hold & Release and Push Your Luck ask of the device, and the MiniGameDevice calls they share.
# Nothing here reaches hardware.

const RecordingDevice = preload("res://tests/recording_device.gd")


# Records the axis moves MiniGameDevice itself would send, rather than what a view asks of it.
class AxisRecordingDevice:
	extends MiniGameDevice

	var sent_axes: Array[Dictionary] = []

	func move_axes(positions: Dictionary, _duration_ms: int) -> void:
		sent_axes.append(positions)


# The jolt goes to sway or roll, depending on the profile the test machine has saved.
func _jolt(device: MiniGameDevice) -> Array[Dictionary]:
	return MiniGameAxes.wrong_try_jolt(device.has_axis(MiniGameAxes.SWAY))


func _definition(kind: String) -> Dictionary:
	return MiniGameLibrary.normalize_definition({"kind": kind})


func _stop_the_bar(device: MiniGameDevice) -> StopTheBarView:
	var definition: Dictionary = _definition(StopTheBarGame.KIND)
	var view: StopTheBarView = auto_free(StopTheBarView.new())
	add_child(view)
	view.setup(definition, StopTheBarGame.new(definition["knobs"], 1), device, null)
	return view


func _hold_and_release(device: MiniGameDevice) -> HoldReleaseView:
	var definition: Dictionary = _definition(HoldReleaseGame.KIND)
	var view: HoldReleaseView = auto_free(HoldReleaseView.new())
	add_child(view)
	view.setup(definition, HoldReleaseGame.new(definition["knobs"], 1), device, null)
	return view


func _push_your_luck(device: MiniGameDevice, rng_seed: int = 1) -> PushYourLuckView:
	var definition: Dictionary = _definition(PushYourLuckGame.KIND)
	var view: PushYourLuckView = auto_free(PushYourLuckView.new())
	add_child(view)
	view.setup(definition, PushYourLuckGame.new(definition["knobs"], rng_seed), device, null)
	return view


# ── Shared device calls ──────────────────────────────────────────────────────


# The rate holds back positions that change faster than it allows; once they rest, the last of them still goes out.
func test_followed_axes_land_on_the_last_position_once_they_rest() -> void:
	var device: AxisRecordingDevice = AxisRecordingDevice.new()
	device.follow_axes({"R0": 10.0})
	device.follow_axes({"R0": 20.0})  # within the rate: held back
	assert_array(device.sent_axes).is_equal([{"R0": 10.0}])
	device.follow_axes({"R0": 20.0})  # resting now
	assert_array(device.sent_axes).is_equal([{"R0": 10.0}, {"R0": 20.0}])
	device.follow_axes({"R0": 20.0})
	assert_int(device.sent_axes.size()).is_equal(2)


func test_an_ending_waits_for_its_movement() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	device.play_axis_moves_then(MiniGameAxes.WIN_NOD, device.ease_out)
	assert_array(device.calls).is_empty()
	await await_millis(MiniGameAxes.moves_ms(MiniGameAxes.WIN_NOD) + 150)
	assert_array(device.calls).contains_exactly(["ease_out"])


# A queued ending mustn't land on a stroke something asked for since.
func test_a_queued_ending_is_dropped_once_something_newer_is_asked() -> void:
	var device: AxisRecordingDevice = AxisRecordingDevice.new()
	var endings: Array[String] = []
	device.play_axis_moves_then(MiniGameAxes.WIN_NOD, func() -> void: endings.append("ended"))
	device.ease_out()  # nothing running, so it only counts as a newer request
	await await_millis(MiniGameAxes.moves_ms(MiniGameAxes.WIN_NOD) + 150)
	assert_array(endings).is_empty()


# ── Stop the Bar ─────────────────────────────────────────────────────────────


func test_stop_the_bar_strokes_once_per_crossing() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	var view: StopTheBarView = _stop_the_bar(device)
	var bar_game: StopTheBarGame = view._game
	assert_array(device.held_half_cycles_ms).contains_exactly([bar_game.current_sweep_ms()])


func test_the_needle_drives_the_twist() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	_stop_the_bar(device)
	await await_millis(200)
	assert_bool(device.streamed_axes.is_empty()).is_false()
	assert_bool(device.streamed_axes[-1].has(MiniGameAxes.TWIST)).is_true()


func test_a_missed_stop_jolts() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	var view: StopTheBarView = _stop_the_bar(device)
	var bar_game: StopTheBarGame = view._game
	# The needle starts at the left end; a zone never touches it (StopTheBarGame.ZONE_EDGE_MARGIN).
	view._sweep_elapsed_ms = 0.0
	view._on_press_in_play()
	assert_float(bar_game.accuracies[0]).is_equal(0.0)
	assert_array(device.axis_moves).is_equal([_jolt(device)])


# ── Hold & Release ───────────────────────────────────────────────────────────


func test_holding_quickens_the_stroke_in_steps_as_the_gauge_fills() -> void:
	var slowest: int = HoldReleaseView._fill_half_cycle_ms(0.0)
	assert_int(slowest).is_equal(HoldReleaseView.FILL_SLOWEST_HALF_CYCLE_MS)
	assert_int(HoldReleaseView._fill_half_cycle_ms(1.0)).is_equal(
		HoldReleaseView.FILL_FASTEST_HALF_CYCLE_MS
	)
	assert_int(HoldReleaseView._fill_half_cycle_ms(0.05)).is_equal(slowest)  # within the first step
	assert_int(HoldReleaseView._fill_half_cycle_ms(0.5)).is_less(slowest)


func test_hold_and_release_waits_slowly_and_drops_back_on_letting_go() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	var view: HoldReleaseView = _hold_and_release(device)
	assert_array(device.held_half_cycles_ms).contains_exactly(
		[HoldReleaseView.WAITING_HALF_CYCLE_MS]
	)
	view._on_press_in_play()
	view._held_ms = 0.0
	view._play_tick(0.0)
	assert_int(device.held_half_cycles_ms[-1]).is_equal(HoldReleaseView.FILL_SLOWEST_HALF_CYCLE_MS)
	view._on_release_in_play()
	assert_int(device.held_half_cycles_ms[-1]).is_equal(HoldReleaseView.WAITING_HALF_CYCLE_MS)


func test_a_release_too_early_jolts() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	var view: HoldReleaseView = _hold_and_release(device)
	view._on_press_in_play()
	view._on_release_in_play()  # nothing held yet: the gauge is empty
	assert_array(device.axis_moves).is_equal([_jolt(device)])


# ── Push Your Luck ───────────────────────────────────────────────────────────


func test_push_your_luck_strokes_faster_as_the_risk_rises() -> void:
	assert_int(PushYourLuckView.risk_half_cycle_ms(0.0)).is_equal(
		PushYourLuckView.CALM_HALF_CYCLE_MS
	)
	assert_int(PushYourLuckView.risk_half_cycle_ms(1.0)).is_equal(
		PushYourLuckView.RISKY_HALF_CYCLE_MS
	)
	assert_int(PushYourLuckView.risk_half_cycle_ms(0.6)).is_less(
		PushYourLuckView.risk_half_cycle_ms(0.3)
	)


func test_push_your_luck_starts_at_the_stroke_for_the_risk_shown() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	var view: PushYourLuckView = _push_your_luck(device)
	assert_array(device.held_half_cycles_ms).contains_exactly(
		[PushYourLuckView.risk_half_cycle_ms(view._stack.sway_share)]
	)


func test_banking_nods_then_eases_home() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	var view: PushYourLuckView = _push_your_luck(device)
	device.calls.clear()
	view._bank()
	assert_array(device.axis_moves).is_equal([MiniGameAxes.WIN_NOD])
	await await_millis(MiniGameAxes.moves_ms(MiniGameAxes.WIN_NOD) + 150)
	assert_array(device.calls).contains_exactly(["ease_out"])


func test_a_bust_jolts_then_stops() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	var view: PushYourLuckView = _push_your_luck(device)
	device.calls.clear()
	view._bust()
	assert_array(device.axis_moves).is_equal([_jolt(device)])
	await await_millis(MiniGameAxes.moves_ms(device.axis_moves[0]) + 150)
	assert_array(device.calls).contains_exactly(["stop"])


# The swing goes by the risk on show, which a push doesn't change until the piece lands, so it carries on through the
# hover; it stops once the game is over.
func test_the_roll_swings_until_the_game_ends() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	var view: PushYourLuckView = _push_your_luck(device)
	await await_millis(150)
	assert_bool(device.streamed_axes.is_empty()).is_false()
	assert_bool(device.streamed_axes[-1].has(MiniGameAxes.ROLL)).is_true()
	view._locked = true  # as a push leaves it while the piece hovers
	device.streamed_axes.clear()
	await await_millis(150)
	assert_bool(device.streamed_axes.is_empty()).is_false()
	view._done = true
	device.streamed_axes.clear()
	await await_millis(150)
	assert_array(device.streamed_axes).is_empty()


func test_the_roll_waits_out_a_shield_jolt() -> void:
	var device: RecordingDevice = RecordingDevice.new()
	var view: PushYourLuckView = _push_your_luck(device)
	view._stack.hover_piece(0.1)  # as a push does: the shield takes the hovering piece
	view._block_trap()
	device.streamed_axes.clear()
	await await_millis(MiniGameAxes.moves_ms(device.axis_moves[0]) / 2)
	assert_array(device.streamed_axes).is_empty()
