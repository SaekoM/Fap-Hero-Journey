extends GdUnitTestSuite

# HandyService v3 HSP — the pure feeder math: funscript actions → HSP points,
# and the lookahead window batching that streams them into the device buffer.


func test_actions_to_points_shape() -> void:
	var actions := [Vector2(0, 0), Vector2(500, 100), Vector2(1000, 37.4)]
	var points: Array = HandyPoints.actions_to_points(actions)
	assert_int(points.size()).is_equal(3)
	assert_int(int((points[1] as Dictionary)["t"])).is_equal(500)
	assert_int(int((points[1] as Dictionary)["x"])).is_equal(100)
	# position is rounded + clamped to 0-100
	assert_int(int((points[2] as Dictionary)["x"])).is_equal(37)


func _points(times: Array) -> Array:
	var out: Array = []
	for t: int in times:
		out.append({"t": t, "x": 50})
	return out


# The window collects points up to until_t and reports the next cursor.
func test_window_collects_up_to_time() -> void:
	var pts := _points([0, 1000, 2000, 3000, 9000])
	var w: Dictionary = HandyPoints.points_in_window(pts, 0, 2500)
	assert_int((w["batch"] as Array).size()).is_equal(3)  # 0, 1000, 2000
	assert_int(int(w["next_idx"])).is_equal(3)


# Resuming from a cursor only returns the remaining in-window points.
func test_window_resumes_from_cursor() -> void:
	var pts := _points([0, 1000, 2000, 3000, 9000])
	var w: Dictionary = HandyPoints.points_in_window(pts, 3, 12000)
	assert_int((w["batch"] as Array).size()).is_equal(2)  # 3000, 9000
	assert_int(int(w["next_idx"])).is_equal(5)


# A batch never exceeds the HSP per-add cap.
func test_window_caps_at_max_points() -> void:
	var times: Array = []
	for i: int in 250:
		times.append(i * 10)
	var w: Dictionary = HandyPoints.points_in_window(_points(times), 0, 999999)
	assert_int((w["batch"] as Array).size()).is_equal(HandyPoints.MAX_POINTS_PER_ADD)
	assert_int(int(w["next_idx"])).is_equal(HandyPoints.MAX_POINTS_PER_ADD)


# Nothing in range → empty batch, cursor unmoved (feeder no-ops).
func test_window_empty_when_ahead() -> void:
	var pts := _points([5000, 6000])
	var w: Dictionary = HandyPoints.points_in_window(pts, 0, 1000)
	assert_int((w["batch"] as Array).size()).is_equal(0)
	assert_int(int(w["next_idx"])).is_equal(0)


# ── index_at_or_after (start/seek window the CURRENT position) ────────────────


# Returns the first index whose time is >= t; an exact hit returns that index.
func test_index_at_or_after_basic() -> void:
	var pts := _points([0, 1000, 2000, 3000, 4000])
	assert_int(HandyPoints.index_at_or_after(pts, 0)).is_equal(0)
	assert_int(HandyPoints.index_at_or_after(pts, 2000)).is_equal(2)  # exact match
	assert_int(HandyPoints.index_at_or_after(pts, 2500)).is_equal(3)  # between → next


# A seek past the last point returns size() (an empty forward window, not a rewind to 0).
func test_index_at_or_after_past_end() -> void:
	var pts := _points([0, 1000, 2000])
	assert_int(HandyPoints.index_at_or_after(pts, 9999)).is_equal(3)


func test_index_at_or_after_empty() -> void:
	assert_int(HandyPoints.index_at_or_after([], 1000)).is_equal(0)


# The bug this fixes: seeding a mid-script window. A seek to 2:00 must batch points AROUND 2:00,
# not the opening of the script — window(index_at_or_after(t), …) is what the start/seek path now
# does, vs the old window(0, …) that shipped the first 100 points every time.
func test_mid_script_window_is_local_not_from_start() -> void:
	var times: Array = []
	for i: int in 2000:
		times.append(i * 100)  # 0..200s at 10 Hz
	var pts := _points(times)
	var seek_ms := 120000  # 2:00

	# Old behaviour: from index 0 → the batch is the OPENING of the script (wrong).
	var old_batch: Array = HandyPoints.points_in_window(pts, 0, seek_ms + 8000)["batch"]
	assert_int(int((old_batch[0] as Dictionary)["t"])).is_equal(0)

	# Fixed: from the seek index → the batch begins at the seek position.
	var from_idx: int = HandyPoints.index_at_or_after(pts, seek_ms)
	var new_batch: Array = HandyPoints.points_in_window(pts, from_idx, seek_ms + 8000)["batch"]
	assert_int(int((new_batch[0] as Dictionary)["t"])).is_equal(seek_ms)
	# ...and every point in it is within the [seek, seek+lookahead] window.
	for p: Dictionary in new_batch:
		assert_bool(int(p["t"]) >= seek_ms and int(p["t"]) <= seek_ms + 8000).is_true()


# ── apply_effects (items / curses reach the Handy) ───────────────────────────

const PTS := [
	{"t": 0, "x": 0},
	{"t": 500, "x": 100},
	{"t": 1000, "x": 0},
]


func _xs(points: Array) -> Array:
	return points.map(func(p: Dictionary) -> int: return int(p["x"]))


# No stroke effects → positions unchanged, timestamps preserved.
func test_apply_effects_passthrough() -> void:
	var out: Array = HandyPoints.apply_effects(PTS, [])
	assert_array(_xs(out)).is_equal([0, 100, 0])
	assert_int(int((out[1] as Dictionary)["t"])).is_equal(500)


# Reverse mirrors around 100 (0↔100); an even count cancels.
func test_apply_effects_reverse() -> void:
	assert_array(_xs(HandyPoints.apply_effects(PTS, [{"kind": "reverse"}]))).is_equal([100, 0, 100])
	(
		assert_array(
			_xs(HandyPoints.apply_effects(PTS, [{"kind": "reverse"}, {"kind": "reverse"}]))
		)
		. is_equal([0, 100, 0])
	)


# Clamp rescales 0-100 into the sub-range.
func test_apply_effects_clamp() -> void:
	var out: Array = HandyPoints.apply_effects(PTS, [{"kind": "clamp", "min": 40, "max": 60}])
	assert_array(_xs(out)).is_equal([40, 60, 40])


# Scale shrinks each stroke around its local centre (midpoint of neighbours).
func test_apply_effects_scale_local_centre() -> void:
	# Middle point x=100, neighbours 0 and 0 → centre 0 → 0 + (100-0)*0.6 = 60.
	var out: Array = HandyPoints.apply_effects(PTS, [{"kind": "scale", "factor": 0.6}])
	assert_int(int((out[1] as Dictionary)["x"])).is_equal(60)


# Block → flat hold line at hold_pos, timestamps intact.
func test_apply_effects_block_holds() -> void:
	var out: Array = HandyPoints.apply_effects(PTS, [{"kind": "block"}], 50)
	assert_array(_xs(out)).is_equal([50, 50, 50])
	assert_int(int((out[2] as Dictionary)["t"])).is_equal(1000)


# Non-stroke kinds (score/coin effects) are ignored.
func test_apply_effects_ignores_non_stroke() -> void:
	var out: Array = HandyPoints.apply_effects(
		PTS, [{"kind": "score_multiplier", "factor": 2.0}, {"kind": "coin_penalty", "factor": 0.5}]
	)
	assert_array(_xs(out)).is_equal([0, 100, 0])


# ── delay offset (the user's Handy delay, as a timestamp shift) ──────────────


# A positive delay pushes every point later — the device acts after the video.
func test_offset_positive_delays_points() -> void:
	var out: Array = HandyPoints.offset_points(PTS, 300)
	assert_array(out.map(func(p: Dictionary) -> int: return int(p["t"]))).is_equal([300, 800, 1300])
	# positions ride along untouched
	assert_array(_xs(out)).is_equal([0, 100, 0])


# A negative delay pulls points earlier — the device fires ahead of the video.
func test_offset_negative_advances_points() -> void:
	var out: Array = HandyPoints.offset_points(PTS, -200)
	# t=0 → -200 is not a legal timestamp and is already past: dropped.
	assert_array(out.map(func(p: Dictionary) -> int: return int(p["t"]))).is_equal([300, 800])


# Zero is the identity (and the common case — don't rebuild the array for nothing).
func test_offset_zero_is_identity() -> void:
	assert_array(HandyPoints.offset_points(PTS, 0)).is_equal(PTS)


# The regression this fixes: at a round start video_ms is small, and the old
# `maxi(0, video_ms - delay)` anchor clamped the delay away entirely. A timestamp
# shift has no floor — the delay survives at position 0 exactly as it does later.
func test_offset_applies_fully_at_round_start() -> void:
	var out: Array = HandyPoints.offset_points([{"t": 0, "x": 50}], 500)
	assert_int(int((out[0] as Dictionary)["t"])).is_equal(500)


# ── server-clock offset (transit-lag compensation) ───────────────────────────


# The lowest round-trip sample wins; offset = server_time + rtt/2 − recv.
func test_best_offset_lowest_rtt_wins() -> void:
	var samples := [
		{"sent": 0, "recv": 200, "server_time": 5000},  # rtt 200 → offset 5000+100-200=4900
		{"sent": 300, "recv": 340, "server_time": 5220},  # rtt 40 → offset 5220+20-340=4900 (wins)
		{"sent": 500, "recv": 900, "server_time": 5300},  # rtt 400, noisier
	]
	# server_now ≈ local_now + 4900
	assert_int(HandyPoints.best_offset_from_samples(samples)).is_equal(4900)


func test_best_offset_single_sample() -> void:
	var samples := [{"sent": 1000, "recv": 1080, "server_time": 999040}]
	# offset = 999040 + 40 − 1080 = 998000
	assert_int(HandyPoints.best_offset_from_samples(samples)).is_equal(998000)
