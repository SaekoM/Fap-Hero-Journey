extends GdUnitTestSuite

# The calibration ruler (StrokePattern) and the backend question the sync UI asks of DeviceRouting.
# Both are pure — no device, no scene.


func _times(actions: Array) -> Array:
	var out: Array = []
	for a: Vector2 in actions:
		out.append(int(a.x))
	return out


func _positions(actions: Array) -> Array:
	var out: Array = []
	for a: Vector2 in actions:
		out.append(int(a.y))
	return out


# One cycle with a hold is bottom → top → held top → bottom, and the next cycle's opening point is what
# holds the bottom. 1000 ms cycle, 200 ms hold → 300 ms of travel each way.
func test_one_cycle_has_a_hold_at_each_end() -> void:
	var actions: Array = StrokePattern.calibration(1000, 2000, 0, 100, 200)
	assert_array(_times(actions).slice(0, 5)).contains_exactly([0, 300, 500, 800, 1000])
	assert_array(_positions(actions).slice(0, 5)).contains_exactly([0, 100, 100, 0, 0])


# With no hold the pattern is a plain triangle — and, importantly, no two points share a timestamp,
# which is what the omitted closing point protects against.
func test_no_hold_leaves_no_duplicate_timestamps() -> void:
	var times: Array = _times(StrokePattern.calibration(1000, 4000, 0, 100, 0))
	assert_array(times).contains_exactly([0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000])


func test_timestamps_are_strictly_increasing() -> void:
	var times: Array = _times(StrokePattern.calibration(2000, 20000))
	for i: int in range(1, times.size()):
		assert_int(int(times[i])).is_greater(int(times[i - 1]))


func test_the_pattern_ends_at_rest_at_the_bottom() -> void:
	var actions: Array = StrokePattern.calibration(1000, 3000, 10, 90, 200)
	var last: Vector2 = actions[actions.size() - 1]
	assert_int(int(last.x)).is_equal(3000)
	assert_int(int(last.y)).is_equal(10)


func test_it_spans_at_least_the_requested_length() -> void:
	var actions: Array = StrokePattern.calibration(2000, 10000)
	assert_int(int((actions[actions.size() - 1] as Vector2).x)).is_greater_equal(10000)


# A hold long enough to swallow the travel would leave a pattern that only teleports between the ends,
# which no device can be judged against. It is clamped instead.
func test_an_over_long_hold_still_leaves_room_to_travel() -> void:
	var actions: Array = StrokePattern.calibration(1000, 1000, 0, 100, 900)
	var travel: int = int((actions[1] as Vector2).x) - int((actions[0] as Vector2).x)
	assert_int(travel).is_greater_equal(StrokePattern.MIN_TRAVEL_MS)


func test_positions_are_clamped_to_the_legal_range() -> void:
	var positions: Array = _positions(StrokePattern.calibration(1000, 2000, -40, 180, 200))
	assert_int(positions.min()).is_equal(0)
	assert_int(positions.max()).is_equal(100)


# The pattern is fed to the device paths as a script, so it has to survive the same conversion a real
# funscript does.
func test_it_converts_to_handy_points() -> void:
	var points: Array = HandyPoints.actions_to_points(
		StrokePattern.calibration(1000, 2000, 5, 95, 200)
	)
	assert_int(points.size()).is_greater(4)
	assert_int(HandyPoints.sample_pos(points, 300)).is_equal(95)
	assert_int(HandyPoints.sample_pos(points, 0)).is_equal(5)
	# Halfway up the first rise.
	assert_int(HandyPoints.sample_pos(points, 150)).is_equal(50)


# ── Which delay a stroke target belongs to ──────────────────────────────────


func test_stroke_backend_names_the_sentinels() -> void:
	assert_str(DeviceRouting.stroke_backend(DeviceRouting.HANDY_TARGET)).is_equal("handy")
	assert_str(DeviceRouting.stroke_backend(DeviceRouting.SERIAL_TARGET)).is_equal("serial")


# Anything that isn't a sentinel is an actuator id, and every actuator is Buttplug's.
func test_stroke_backend_treats_an_actuator_id_as_buttplug() -> void:
	var backend: String = DeviceRouting.stroke_backend("Edge 2#0:linear:0")
	assert_str(backend).is_equal(DeviceRouting.BP_BACKEND)


func test_stroke_backend_is_empty_when_nothing_is_targeted() -> void:
	assert_str(DeviceRouting.stroke_backend("")).is_equal("")


# ── The meter's geometry ────────────────────────────────────────────────────


# The sign that decides whether a player calibrates in the right direction. A positive delay means the
# device is executing script from that many milliseconds ago, so its marker belongs BEHIND the NOW line.
func test_a_positive_delay_marks_the_device_behind_now() -> void:
	var strip: Rect2 = Rect2(0.0, 0.0, 400.0, 100.0)
	var now: int = 10000
	var t_left: int = now - int(StrokeMeter.WINDOW_MS * StrokeMeter.NOW_FRAC)
	var now_x: float = StrokeMeter.time_to_x(strip, now, t_left)
	assert_float(StrokeMeter.time_to_x(strip, now - 200, t_left)).is_less(now_x)
	assert_float(StrokeMeter.time_to_x(strip, now + 200, t_left)).is_greater(now_x)


# NOW sits where NOW_FRAC says it does, so the rest of the strip is the script still to come.
func test_now_sits_where_the_window_says() -> void:
	var strip: Rect2 = Rect2(0.0, 0.0, 400.0, 100.0)
	var now: int = 10000
	var t_left: int = now - int(StrokeMeter.WINDOW_MS * StrokeMeter.NOW_FRAC)
	assert_float(StrokeMeter.time_to_x(strip, now, t_left)).is_equal_approx(
		400.0 * StrokeMeter.NOW_FRAC, 0.5
	)


# Top of the widget is the top of the stroke: a device at 100 is drawn above one at 0.
func test_a_higher_position_draws_higher() -> void:
	var rect: Rect2 = Rect2(0.0, 0.0, 40.0, 100.0)
	assert_float(StrokeMeter.pos_to_y(rect, 100.0)).is_less(StrokeMeter.pos_to_y(rect, 0.0))
	# And both stay inside the widget, so a stroke at either extreme draws a whole marker.
	assert_float(StrokeMeter.pos_to_y(rect, 100.0)).is_greater_equal(0.0)
	assert_float(StrokeMeter.pos_to_y(rect, 0.0)).is_less_equal(100.0)
