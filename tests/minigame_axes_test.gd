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
