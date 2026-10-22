extends GdUnitTestSuite

# Oscillating devices (OSCILLATE_DESIGN.md): the stroke's rhythm, and the speed it becomes. These pin the
# maths so a tuning change can be checked without hardware; how it FEELS is the tester's call.


# Strokes per second a fresh tracker reads after `segments` ([startMs, startPos, endMs, endPos], or []
# for a frozen stroke).
func _rate(segments: Array) -> float:
	return FunscriptPlayer.StrokeRateOf(segments)


# A script that turns at 0, 100, 0, 100… every `half_ms`, for `halves` half-strokes.
func _strokes(half_ms: float, halves: int, from_ms: float = 0.0) -> Array:
	var out: Array = []
	for i: int in halves:
		var start: float = from_ms + i * half_ms
		var up: bool = i % 2 == 0
		out.append([start, 0.0 if up else 100.0, start + half_ms, 100.0 if up else 0.0])
	return out


# ── Stroke rate ──────────────────────────────────────────────────────────────


func test_two_strokes_a_second() -> void:
	assert_float(_rate(_strokes(250.0, 4))).is_equal_approx(2.0, 0.001)


func test_nothing_before_the_first_stroke() -> void:
	assert_float(_rate([])).is_equal(0.0)


# It's the rhythm, not the distance: a short fast flick reads as fast as a full fast stroke.
func test_a_short_flick_is_as_fast_as_a_full_stroke() -> void:
	var flicks: Array = [
		[0.0, 40.0, 100.0, 60.0], [100.0, 60.0, 200.0, 40.0], [200.0, 40.0, 300.0, 60.0]
	]
	assert_float(_rate(flicks)).is_equal_approx(5.0, 0.001)


# Points along each stroke don't count as turns; after a couple of strokes it reads the true rhythm.
func test_points_along_a_stroke_settle_on_the_same_rate() -> void:
	var segments: Array = []
	for i: int in 5:
		var start: float = i * 250.0
		var up: bool = i % 2 == 0
		var from: float = 0.0 if up else 100.0
		var to: float = 100.0 if up else 0.0
		segments.append([start, from, start + 125.0, 50.0])
		segments.append([start + 125.0, 50.0, start + 250.0, to])
	assert_float(_rate(segments)).is_equal_approx(2.0, 0.1)


# A hold stops it outright, so the machine stops when the script does.
func test_a_hold_stops_it() -> void:
	var segments: Array = _strokes(250.0, 4)
	segments.append([1000.0, 0.0, 1800.0, 1.0])  # barely moves: a hold
	assert_float(_rate(segments)).is_equal(0.0)


# An effect that freezes the stroke is a hold too.
func test_a_frozen_stroke_stops_it() -> void:
	var segments: Array = _strokes(250.0, 4)
	segments.append([])
	assert_float(_rate(segments)).is_equal(0.0)


# After a hold, the first stroke reads its own length rather than counting the hold as stroke time.
func test_the_first_stroke_after_a_hold_reads_fresh() -> void:
	var segments: Array = [[0.0, 0.0, 250.0, 100.0], [250.0, 100.0, 3000.0, 100.0]]
	segments.append([3000.0, 100.0, 3125.0, 0.0])
	assert_float(_rate(segments)).is_equal_approx(4.0, 0.001)


# A change of rhythm moves the reading halfway per half-stroke.
func test_a_new_rhythm_is_followed_over_a_stroke_or_two() -> void:
	var segments: Array = _strokes(250.0, 4)
	segments.append([1000.0, 0.0, 1125.0, 100.0])  # the half-stroke before ran 250 ms
	segments.append([1125.0, 100.0, 1250.0, 0.0])  # this turn closes a 125 ms half-stroke
	assert_float(_rate(segments)).is_equal_approx(1000.0 / (2.0 * 187.5), 0.001)


# A jump in the clock (a seek) isn't read as one enormous stroke.
func test_a_seek_does_not_read_as_a_slow_stroke() -> void:
	var segments: Array = _strokes(250.0, 2)
	segments.append_array(_strokes(250.0, 2, 60000.0))
	assert_float(_rate(segments)).is_equal_approx(2.0, 0.001)


# ── Depth ────────────────────────────────────────────────────────────────────


func _depth(segments: Array) -> float:
	return FunscriptPlayer.StrokeDepthOf(segments)


func test_full_strokes_are_full_depth() -> void:
	assert_float(_depth(_strokes(250.0, 4))).is_equal_approx(100.0, 0.001)


func test_a_flutter_is_shallow() -> void:
	var flutter: Array = [
		[0.0, 0.0, 60.0, 20.0], [60.0, 20.0, 120.0, 0.0], [120.0, 0.0, 180.0, 20.0]
	]
	assert_float(_depth(flutter)).is_equal_approx(20.0, 0.001)


# Points along a stroke add up to the whole stroke, turn to turn: 10 → 40 → 70 and back reads as 60
# once a couple of strokes have settled it.
func test_depth_runs_turn_to_turn() -> void:
	var segments: Array = []
	for i: int in 6:
		var start: float = i * 200.0
		var up: bool = i % 2 == 0
		segments.append([start, 10.0 if up else 70.0, start + 100.0, 40.0])
		segments.append([start + 100.0, 40.0, start + 200.0, 70.0 if up else 10.0])
	assert_float(_depth(segments)).is_equal_approx(60.0, 1.5)


func test_a_hold_has_no_depth() -> void:
	var segments: Array = _strokes(250.0, 4)
	segments.append([])
	assert_float(_depth(segments)).is_equal(0.0)


# ── How hard the stroke drives it ────────────────────────────────────────────


func _drive(rate: float, depth: float, full_rate: float = 3.0) -> float:
	return FunscriptPlayer.OscillateStrokeFraction(rate, depth, full_rate)


# The owner's tuning points (set on a virtual device, 2026-10-22).
func test_fast_full_strokes_are_full_speed() -> void:
	assert_float(_drive(3.0, 100.0)).is_equal_approx(1.0, 0.001)


func test_full_strokes_at_half_the_rhythm() -> void:
	assert_float(_drive(1.5, 100.0)).is_equal_approx(0.6, 0.001)


# A 0–20 flutter at 8 strokes a second is gentle on a stroker, so here too.
func test_a_fast_flutter_is_gentle() -> void:
	assert_float(_drive(8.0, 20.0)).is_equal_approx(0.3, 0.001)


# Rhythm past full speed doesn't make up for shallower strokes.
func test_fast_half_depth_strokes() -> void:
	assert_float(_drive(9.0, 50.0)).is_equal_approx(0.7, 0.001)


# Between the points it's a straight line: full strokes at a quarter of the rhythm are half of 0.6.
func test_between_the_points_is_a_straight_line() -> void:
	assert_float(_drive(0.75, 100.0)).is_equal_approx(0.3, 0.001)
	assert_float(_drive(3.0, 35.0)).is_equal_approx(0.5, 0.001)


func test_no_rhythm_or_no_depth_is_nothing() -> void:
	assert_float(_drive(0.0, 100.0)).is_equal(0.0)
	assert_float(_drive(3.0, 0.0)).is_equal(0.0)


# ── Speed ────────────────────────────────────────────────────────────────────


func _speed(fraction: float, min_pct: float, max_pct: float) -> float:
	return FunscriptPlayer.OscillateSpeed(fraction, min_pct, max_pct)


func test_no_rhythm_means_stopped_whatever_the_min() -> void:
	assert_float(_speed(0.0, 20.0, 80.0)).is_equal(0.0)


func test_speed_scales_from_min_to_max() -> void:
	assert_float(_speed(0.01, 20.0, 80.0)).is_equal_approx(0.206, 0.001)
	assert_float(_speed(0.5, 20.0, 80.0)).is_equal_approx(0.5, 0.001)
	assert_float(_speed(1.0, 20.0, 80.0)).is_equal_approx(0.8, 0.001)


func test_faster_than_full_speed_stays_at_max() -> void:
	assert_float(_speed(3.0, 20.0, 80.0)).is_equal_approx(0.8, 0.001)


func test_a_min_above_the_max_is_held_to_it() -> void:
	assert_float(_speed(0.1, 90.0, 60.0)).is_equal_approx(0.6, 0.001)


# ── Easing ───────────────────────────────────────────────────────────────────


func _ease(current: float, target: float, dt_sec: float) -> float:
	return FunscriptPlayer.OscillateEase(current, target, dt_sec)


# Never stopped-to-full in one step: 1.5 of the range per second.
func test_speed_changes_are_eased() -> void:
	assert_float(_ease(0.0, 1.0, 0.1)).is_equal_approx(0.15, 0.001)
	assert_float(_ease(1.0, 0.0, 0.1)).is_equal_approx(0.85, 0.001)


func test_a_small_change_lands_exactly() -> void:
	assert_float(_ease(0.4, 0.45, 0.1)).is_equal_approx(0.45, 0.0001)
