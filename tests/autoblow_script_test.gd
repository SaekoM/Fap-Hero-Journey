extends GdUnitTestSuite

# AutoblowScript (the pure half of AutoblowService) and the Autoblow's place in routing. Nothing here reaches the
# network: the device itself is untested until one is available (AUTOBLOW_DESIGN.md).


func _actions(script_bytes: PackedByteArray) -> Array:
	return (JSON.parse_string(script_bytes.get_string_from_utf8()) as Dictionary)["actions"]


# ── The script that's uploaded ───────────────────────────────────────────────


func test_the_script_is_a_funscript_of_the_points() -> void:
	var points: Array = [{"t": 0, "x": 0}, {"t": 500, "x": 100}, {"t": 1000, "x": 50}]
	var actions: Array = _actions(AutoblowScript.funscript_bytes(points, 0, 100))
	assert_int(actions.size()).is_equal(3)
	assert_int(int(actions[1]["at"])).is_equal(500)
	assert_int(int(actions[1]["pos"])).is_equal(100)


func test_the_stroke_range_is_baked_into_the_positions() -> void:
	var points: Array = [{"t": 0, "x": 0}, {"t": 500, "x": 100}, {"t": 1000, "x": 50}]
	var actions: Array = _actions(AutoblowScript.funscript_bytes(points, 20, 80))
	assert_int(int(actions[0]["pos"])).is_equal(20)
	assert_int(int(actions[1]["pos"])).is_equal(80)
	assert_int(int(actions[2]["pos"])).is_equal(50)


func test_a_reversed_range_reads_the_same_way_round() -> void:
	assert_int(AutoblowScript.in_range(100, 80, 20)).is_equal(80)
	assert_int(AutoblowScript.in_range(0, 80, 20)).is_equal(20)


func test_the_script_stops_at_the_apis_time_limit() -> void:
	var points: Array = [{"t": 0, "x": 0}, {"t": AutoblowScript.MAX_LAST_ACTION_MS + 1, "x": 100}]
	assert_int(_actions(AutoblowScript.funscript_bytes(points, 0, 100)).size()).is_equal(1)


# ── Multipart upload ─────────────────────────────────────────────────────────


func test_the_upload_body_wraps_the_file_between_boundaries() -> void:
	var form: Dictionary = AutoblowScript.multipart_file(
		"round.funscript", "{}".to_utf8_buffer(), "edge"
	)
	assert_str(str(form["content_type"])).is_equal("multipart/form-data; boundary=edge")
	var body: String = (form["body"] as PackedByteArray).get_string_from_utf8()
	assert_bool(body.begins_with("--edge\r\n")).is_true()
	assert_bool(body.contains('name="file"; filename="round.funscript"')).is_true()
	assert_bool(body.contains("\r\n\r\n{}\r\n--edge--\r\n")).is_true()


# ── Devices ──────────────────────────────────────────────────────────────────


func test_each_device_answers_on_its_own_path() -> void:
	assert_str(AutoblowScript.api_prefix(AutoblowScript.DEVICE_ULTRA)).is_equal("/autoblow")
	assert_str(AutoblowScript.api_prefix(AutoblowScript.DEVICE_VACUGLIDE)).is_equal("/vacuglide")
	assert_str(AutoblowScript.api_prefix("vacupump")).is_empty()  # not driven yet


func test_the_autoblow_is_its_own_stroke_backend() -> void:
	assert_str(DeviceRouting.stroke_backend(DeviceRouting.AUTOBLOW_TARGET)).is_equal(
		DeviceRouting.AUTOBLOW_TARGET
	)
	var plan: Dictionary = DeviceRouting.resolve(DeviceRouting.AUTOBLOW_TARGET, {}, {}, [])
	assert_str(str(plan["stroke"].get("backend", ""))).is_equal(DeviceRouting.AUTOBLOW_TARGET)


# ── Filler ───────────────────────────────────────────────────────────────────


func test_shorter_half_strokes_run_faster() -> void:
	assert_int(AutoblowScript.filler_speed(AutoblowScript.FASTEST_HALF_STROKE_MS)).is_equal(100)
	assert_int(AutoblowScript.filler_speed(AutoblowScript.SLOWEST_HALF_STROKE_MS * 2)).is_equal(
		AutoblowScript.SLOWEST_SPEED
	)
	assert_int(AutoblowScript.filler_speed(400)).is_greater(AutoblowScript.filler_speed(900))


func test_the_oscillator_span_keeps_its_minimum_width() -> void:
	var narrow: Vector2i = AutoblowScript.oscillate_span(50, 52)
	assert_int(narrow.y - narrow.x).is_equal(AutoblowScript.MIN_OSCILLATE_SPAN)
	var at_top: Vector2i = AutoblowScript.oscillate_span(98, 100)
	assert_int(at_top.y).is_equal(100)
	assert_int(at_top.x).is_equal(100 - AutoblowScript.MIN_OSCILLATE_SPAN)
	assert_bool(AutoblowScript.oscillate_span(80, 20) == Vector2i(20, 80)).is_true()


# ── Rate limits ──────────────────────────────────────────────────────────────


func test_a_rate_limit_waits_for_its_reset() -> void:
	var seconds_left: PackedStringArray = PackedStringArray(["X-RateLimit-Reset: 3"])
	assert_int(AutoblowScript.rate_limit_wait_ms(seconds_left, 0.0)).is_equal(3000)
	var unix_time: PackedStringArray = PackedStringArray(["x-ratelimit-reset: 1700000005"])
	assert_int(AutoblowScript.rate_limit_wait_ms(unix_time, 1700000000.0)).is_equal(5000)


func test_a_rate_limit_without_a_reset_waits_the_fallback() -> void:
	assert_int(AutoblowScript.rate_limit_wait_ms(PackedStringArray(), 0.0)).is_equal(
		AutoblowScript.RATE_LIMIT_FALLBACK_WAIT_MS
	)


func test_a_header_is_found_whatever_its_case() -> void:
	var headers: PackedStringArray = PackedStringArray(["X-RateLimit-Remaining: 42"])
	assert_str(AutoblowScript.header_value(headers, "x-ratelimit-remaining")).is_equal("42")
	assert_str(AutoblowScript.header_value(headers, "x-ratelimit-limit")).is_empty()


# ── Switched off in release builds ───────────────────────────────────────────


func test_it_is_offered_in_the_editor_or_by_the_experimental_setting() -> void:
	var expected: bool = (
		OS.has_feature("editor")
		or bool(ProjectSettings.get_setting(AutoblowService.EXPERIMENTAL_SETTING, false))
	)
	assert_bool(AutoblowService.available()).is_equal(expected)
