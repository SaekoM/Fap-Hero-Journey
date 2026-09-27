extends GdUnitTestSuite

# The serial axis stream (MULTIAXIS_DESIGN.md §7 step 2): every serial axis is sampled once per physics
# tick and sent as one T-code line. These pin the three pieces that decide what reaches the device —
# the line format, where a script is at a given moment, and how a script position becomes the sent one.
# Whether the link keeps up with six axes at 120 Hz can only be judged on hardware.

# ── The line ─────────────────────────────────────────────────────────────────


func _line(axes: Array, positions: Array, interval_ms: int = 13) -> String:
	return SerialDeviceService.MoveLine(
		PackedStringArray(axes), PackedFloat64Array(positions), interval_ms
	)


func test_one_axis_is_one_command_and_a_newline() -> void:
	assert_str(_line(["L0"], [0.5])).is_equal("L05000I13\n")


# The firmware starts everything on a line at its newline, so the axes move in step.
func test_a_batch_is_one_line_with_the_commands_space_separated() -> void:
	assert_str(_line(["L0", "R1", "R2"], [1.0, 0.25, 0.0], 21)).is_equal(
		"L09999I21 R12500I21 R20000I21\n"
	)


func test_positions_outside_the_axis_are_held_to_its_ends() -> void:
	assert_str(_line(["R0", "R1"], [-0.2, 1.3])).is_equal("R00000I13 R19999I13\n")


# ── Where a script is ────────────────────────────────────────────────────────

const RAMP: Array = [Vector2(1000, 0), Vector2(2000, 100), Vector2(3000, 40)]


func _sample(points: Array, now_ms: float) -> float:
	return FunscriptPlayer.SampleScriptAt(points, now_ms)


func test_between_keyframes_is_the_straight_line_between_them() -> void:
	assert_float(_sample(RAMP, 1500)).is_equal_approx(50.0, 0.0001)
	assert_float(_sample(RAMP, 1250)).is_equal_approx(25.0, 0.0001)
	assert_float(_sample(RAMP, 2500)).is_equal_approx(70.0, 0.0001)


func test_on_a_keyframe_is_that_keyframe() -> void:
	assert_float(_sample(RAMP, 2000)).is_equal_approx(100.0, 0.0001)


# Before the script starts the axis waits at its first position — the old per-keyframe path skipped
# straight past it toward the second.
func test_before_the_first_keyframe_holds_the_first_position() -> void:
	assert_float(_sample(RAMP, 0)).is_equal_approx(0.0, 0.0001)


func test_after_the_last_keyframe_holds_the_last_position() -> void:
	assert_float(_sample(RAMP, 9000)).is_equal_approx(40.0, 0.0001)


func test_a_single_keyframe_script_holds_it() -> void:
	assert_float(_sample([Vector2(500, 70)], 100)).is_equal_approx(70.0, 0.0001)
	assert_float(_sample([Vector2(500, 70)], 900)).is_equal_approx(70.0, 0.0001)


# Sub-unit resolution is kept: a slow pitch drifting one unit over a second must glide, not step.
func test_positions_between_whole_units_are_kept() -> void:
	var slow: Array = [Vector2(0, 50), Vector2(1000, 51)]
	assert_float(_sample(slow, 250)).is_equal_approx(50.25, 0.0001)


# ── Script position → sent position ──────────────────────────────────────────


func _out(script_pos: float, axis_min: int, axis_max: int, ease_blend: float = 1.0) -> float:
	return FunscriptPlayer.SecondaryAxisOutput(script_pos, axis_min, axis_max, ease_blend)


func test_a_full_window_sends_the_script_as_is() -> void:
	for pos: float in [0.0, 33.0, 100.0]:
		assert_float(_out(pos, 0, 100)).is_equal_approx(pos, 0.0001)


# The window rescales rather than clips, so a narrowed axis keeps the script's shape at a smaller swing.
func test_a_narrowed_window_scales_the_swing_around_centre() -> void:
	assert_float(_out(0.0, 25, 75)).is_equal_approx(25.0, 0.0001)
	assert_float(_out(50.0, 25, 75)).is_equal_approx(50.0, 0.0001)
	assert_float(_out(100.0, 25, 75)).is_equal_approx(75.0, 0.0001)


# Secondary axes home to centre, so the round-start ease blends in from 50.
func test_the_ease_blends_in_from_centre() -> void:
	assert_float(_out(100.0, 0, 100, 0.0)).is_equal_approx(50.0, 0.0001)
	assert_float(_out(100.0, 0, 100, 0.5)).is_equal_approx(75.0, 0.0001)
	assert_float(_out(0.0, 0, 100, 0.5)).is_equal_approx(25.0, 0.0001)


# The clamp comes last so an ease from 50 can never leave a window that doesn't include 50.
func test_an_ease_never_leaves_a_window_that_excludes_centre() -> void:
	assert_float(_out(100.0, 60, 100, 0.0)).is_equal_approx(60.0, 0.0001)


func test_a_script_position_past_the_axis_is_held_to_the_window() -> void:
	assert_float(_out(140.0, 20, 80)).is_equal_approx(80.0, 0.0001)
	assert_float(_out(-40.0, 20, 80)).is_equal_approx(20.0, 0.0001)
