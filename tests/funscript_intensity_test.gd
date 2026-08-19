extends GdUnitTestSuite

# FunscriptIntensity — average-speed → 1-5 rating. Pure math on crafted actions.


func _stroke_script(count: int, period_ms: int, low: int, high: int) -> Array:
	# Alternating low/high positions `count` points long, spaced `period_ms` apart.
	var out: Array = []
	for i in count:
		out.append({"at": i * period_ms, "pos": low if i % 2 == 0 else high})
	return out


func test_bucket_boundaries() -> void:
	assert_int(FunscriptIntensity.bucket(0.0)).is_equal(1)
	assert_int(FunscriptIntensity.bucket(99.0)).is_equal(1)
	assert_int(FunscriptIntensity.bucket(100.0)).is_equal(2)
	assert_int(FunscriptIntensity.bucket(300.0)).is_equal(3)
	assert_int(FunscriptIntensity.bucket(450.0)).is_equal(4)
	assert_int(FunscriptIntensity.bucket(600.0)).is_equal(5)


func test_empty_or_single_action_is_gentle() -> void:
	assert_int(FunscriptIntensity.from_actions([])).is_equal(1)
	assert_int(FunscriptIntensity.from_actions([{"at": 0, "pos": 50}])).is_equal(1)


func test_average_speed_of_known_script() -> void:
	# Full-range (0↔100) strokes every 500ms → 100 units per 0.5s = 200 units/sec.
	var actions: Array = _stroke_script(11, 500, 0, 100)
	assert_float(FunscriptIntensity.average_speed(actions)).is_equal_approx(200.0, 0.5)
	assert_int(FunscriptIntensity.from_actions(actions)).is_equal(2)


func test_faster_script_rates_higher() -> void:
	var slow: Array = _stroke_script(21, 1000, 30, 70)  # 40 units/sec → 1
	var fast: Array = _stroke_script(41, 150, 0, 100)  # ~667 units/sec → 5
	assert_int(FunscriptIntensity.from_actions(slow)).is_less(FunscriptIntensity.from_actions(fast))
	assert_int(FunscriptIntensity.from_actions(slow)).is_equal(1)
	assert_int(FunscriptIntensity.from_actions(fast)).is_equal(5)


func test_zero_span_is_safe() -> void:
	# All actions at t=0 → no duration; must not divide-by-zero.
	var actions: Array = [{"at": 0, "pos": 0}, {"at": 0, "pos": 100}]
	assert_float(FunscriptIntensity.average_speed(actions)).is_equal(0.0)
	assert_int(FunscriptIntensity.from_actions(actions)).is_equal(1)


func test_unknown_path_returns_neutral() -> void:
	assert_int(FunscriptIntensity.from_path("")).is_equal(FunscriptIntensity.UNKNOWN_INTENSITY)
	assert_int(FunscriptIntensity.from_path("user://does_not_exist.funscript")).is_equal(
		FunscriptIntensity.UNKNOWN_INTENSITY
	)


# ── Vibration rating: by average LEVEL, not travel speed ──────────────────────


func test_vib_average_level_is_time_weighted() -> void:
	# Level 40 held for 1 s, then 80 held for 3 s → (40·1000 + 80·3000) / 4000 = 70.
	var vib: Array = [{"at": 0, "pos": 40}, {"at": 1000, "pos": 80}, {"at": 4000, "pos": 80}]
	assert_float(FunscriptIntensity.average_level(vib)).is_equal_approx(70.0, 0.01)


func test_vib_steady_buzz_rates_intense_not_dead() -> void:
	# A steady strong buzz barely moves position: stroke speed reads it as gentlest (1). By LEVEL
	# it's intense (90 × 5.5 = 495 → bucket 4) — the whole reason vibration needs its own metric.
	var buzz: Array = [{"at": 0, "pos": 90}, {"at": 5000, "pos": 90}]
	assert_int(FunscriptIntensity.from_actions(buzz)).is_equal(1)
	assert_int(FunscriptIntensity.vib_from_actions(buzz)).is_equal(4)
