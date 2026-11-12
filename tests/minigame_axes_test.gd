extends GdUnitTestSuite

# What a serial multi-axis device's extra axes do in a mini-game. Pure positions in 0-100.


func _in_range(positions: Dictionary) -> void:
	for axis: String in positions:
		assert_float(float(positions[axis])).is_between(0.0, 100.0)


func test_the_twist_rests_at_centre_on_the_dials_starting_number() -> void:
	assert_float(MiniGameAxes.dial_twist(0, 40)[MiniGameAxes.TWIST]).is_equal_approx(50.0, 0.01)


# A dial wraps from its last number to its first: the twist mustn't lurch across its range when it does.
func test_the_twist_does_not_jump_where_the_dial_wraps() -> void:
	var at_last: float = MiniGameAxes.dial_twist(39, 40)[MiniGameAxes.TWIST]
	var at_first: float = MiniGameAxes.dial_twist(0, 40)[MiniGameAxes.TWIST]
	assert_float(absf(at_last - at_first)).is_less(10.0)


func test_the_twist_reaches_both_sides_of_a_turn() -> void:
	assert_float(MiniGameAxes.dial_twist(10, 40)[MiniGameAxes.TWIST]).is_equal_approx(100.0, 0.01)
	assert_float(MiniGameAxes.dial_twist(30, 40)[MiniGameAxes.TWIST]).is_equal_approx(0.0, 0.01)


func test_the_wheel_starts_and_lands_with_every_axis_at_centre() -> void:
	for positions: Dictionary in [
		MiniGameAxes.spinning_wheel(0.0, 0.0), MiniGameAxes.spinning_wheel(5.3, 1.0)
	]:
		for axis: String in positions:
			assert_float(float(positions[axis])).is_equal_approx(50.0, 0.01)


func test_the_wheel_moves_every_axis_within_range_mid_spin() -> void:
	for step: int in range(1, 20):
		var progress: float = step / 20.0
		_in_range(MiniGameAxes.spinning_wheel(progress * 5.0, progress))
	var middle: Dictionary = MiniGameAxes.spinning_wheel(2.65, 0.5)
	assert_float(absf(float(middle[MiniGameAxes.ROLL]) - 50.0)).is_greater(5.0)


func test_the_wrong_try_jolt_uses_sway_when_there_is_sway_and_roll_otherwise() -> void:
	var with_sway: Array[Dictionary] = MiniGameAxes.wrong_try_jolt(true)
	var without: Array[Dictionary] = MiniGameAxes.wrong_try_jolt(false)
	assert_bool((with_sway[0]["positions"] as Dictionary).has(MiniGameAxes.SWAY)).is_true()
	assert_bool((without[0]["positions"] as Dictionary).has(MiniGameAxes.ROLL)).is_true()


func test_a_one_off_movement_always_ends_back_at_centre() -> void:
	for moves: Array[Dictionary] in [MiniGameAxes.WIN_NOD, MiniGameAxes.wrong_try_jolt(true)]:
		var last: Dictionary = moves[-1]["positions"]
		for axis: String in last:
			assert_float(float(last[axis])).is_equal(MiniGameAxes.CENTRE)


func test_only_the_axes_a_device_has_are_kept() -> void:
	var kept: Dictionary = MiniGameDevice.only_axes_in({"R0": 10.0, "L2": 20.0}, ["R0", "R1"])
	assert_dict(kept).is_equal({"R0": 10.0})


# ── Stop the Bar, Hold & Release, Push Your Luck ─────────────────────────────


func test_the_twist_follows_the_needle_from_side_to_side() -> void:
	var left: float = MiniGameAxes.needle_twist(0.0)[MiniGameAxes.TWIST]
	var middle: float = MiniGameAxes.needle_twist(0.5)[MiniGameAxes.TWIST]
	var right: float = MiniGameAxes.needle_twist(1.0)[MiniGameAxes.TWIST]
	assert_float(middle).is_equal_approx(MiniGameAxes.CENTRE, 0.01)
	assert_float(left).is_less(middle)
	assert_float(right).is_greater(middle)
	_in_range(MiniGameAxes.needle_twist(1.5))


func test_the_tilt_rises_as_the_gauge_fills() -> void:
	var empty: float = MiniGameAxes.gauge_tilt(0.0)[MiniGameAxes.PITCH]
	assert_float(empty).is_equal_approx(MiniGameAxes.CENTRE, 0.01)
	assert_float(MiniGameAxes.gauge_tilt(1.0)[MiniGameAxes.PITCH]).is_greater(empty)
	_in_range(MiniGameAxes.gauge_tilt(2.0))


func test_the_roll_swings_wider_as_the_risk_rises() -> void:
	assert_float(MiniGameAxes.stack_roll(0.0, 1.0)[MiniGameAxes.ROLL]).is_equal_approx(50.0, 0.01)
	var safe_reach: float = MiniGameAxes.stack_roll(1.0, 0.0)[MiniGameAxes.ROLL] - 50.0
	var risky_reach: float = MiniGameAxes.stack_roll(1.0, 1.0)[MiniGameAxes.ROLL] - 50.0
	assert_float(safe_reach).is_greater(0.0)  # felt even with no risk
	assert_float(risky_reach).is_greater(safe_reach)
	assert_float(MiniGameAxes.stack_roll(-1.0, 1.0)[MiniGameAxes.ROLL]).is_equal_approx(
		50.0 - risky_reach, 0.01
	)
	_in_range(MiniGameAxes.stack_roll(-3.0, 2.0))
	_in_range(MiniGameAxes.stack_roll(3.0, 2.0))


# A nod from a raised tilt heads back towards the middle rather than into the end of the range, and ends where it began.
func test_a_nod_from_anywhere_stays_in_range_and_returns() -> void:
	for pitch: float in [0.0, MiniGameAxes.CENTRE, 90.0, 100.0]:
		var nod: Array[Dictionary] = MiniGameAxes.nod_from(pitch)
		_in_range(nod[0]["positions"])
		assert_float(absf(float(nod[0]["positions"][MiniGameAxes.PITCH]) - pitch)).is_equal_approx(
			MiniGameAxes.NOD_REACH, 0.01
		)
		assert_float(float(nod[-1]["positions"][MiniGameAxes.PITCH])).is_equal(pitch)
	assert_array(MiniGameAxes.nod_from(MiniGameAxes.CENTRE)).is_equal(MiniGameAxes.WIN_NOD)


func test_a_movement_lasts_as_long_as_its_steps() -> void:
	assert_int(MiniGameAxes.moves_ms(MiniGameAxes.WIN_NOD)).is_equal(
		MiniGameAxes.NOD_DOWN_MS + MiniGameAxes.NOD_BACK_MS
	)
