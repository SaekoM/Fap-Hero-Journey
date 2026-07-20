extends GdUnitTestSuite

# Per-round video trim — the pure core: trim_action_points (window + rebase +
# boundary-stroke interpolation) and the cut-aware media fingerprint that keys the
# content pool. trim_action_points is now the per-SEGMENT primitive the EDL builds on,
# so these cases still guard every cut the editor can make (see edl_test.gd).


func _pts(pairs: Array) -> Array:
	var out: Array = []
	for p: Array in pairs:
		out.append(Vector2(p[0], p[1]))
	return out


# Actions landing exactly on the cut points are kept and rebased; nothing is
# synthesized.
func test_exact_window_shift() -> void:
	var points := _pts([[0, 0], [1000, 100], [2000, 0], [3000, 100], [4000, 0]])
	var trimmed: Array = JourneyData.trim_action_points(points, 1000, 3000)
	assert_array(trimmed).is_equal(_pts([[0, 100], [1000, 0], [2000, 100]]))


# An in-cut landing mid-stroke synthesizes the interpolated position at t=0 so
# the device starts where the video shows it, not at home.
func test_in_cut_mid_stroke_interpolates() -> void:
	var trimmed: Array = JourneyData.trim_action_points(_pts([[0, 0], [2000, 100]]), 1000, 0)
	assert_array(trimmed).is_equal(_pts([[0, 50], [1000, 100]]))


# An out-cut landing mid-stroke synthesizes the interpolated end position.
func test_out_cut_mid_stroke_interpolates() -> void:
	var trimmed: Array = JourneyData.trim_action_points(
		_pts([[0, 0], [2000, 100], [4000, 0]]), 0, 3000
	)
	assert_array(trimmed).is_equal(_pts([[0, 0], [2000, 100], [3000, 50]]))


# A window entirely inside one long stroke yields the two interpolated anchors.
func test_window_inside_single_stroke() -> void:
	var trimmed: Array = JourneyData.trim_action_points(_pts([[0, 0], [4000, 100]]), 1000, 3000)
	assert_array(trimmed).is_equal(_pts([[0, 25], [2000, 75]]))


# out_ms <= 0 means "to the end": only the head is cut.
func test_out_zero_keeps_tail() -> void:
	var trimmed: Array = JourneyData.trim_action_points(
		_pts([[0, 0], [1000, 100], [2000, 0]]), 1000, 0
	)
	assert_array(trimmed).is_equal(_pts([[0, 100], [1000, 0]]))


# Degenerate windows produce an empty script (presave validation blocks them,
# but the pure function must not misbehave).
func test_invalid_window_is_empty() -> void:
	assert_array(JourneyData.trim_action_points(_pts([[0, 0], [1000, 100]]), 2000, 1000)).is_empty()
	assert_array(JourneyData.trim_action_points([], 0, 1000)).is_empty()


# The fingerprint keys the content pool: untrimmed stays byte-identical to the
# legacy form (existing pooled rels survive), identical trims share, different
# trims split.
# The mm:ss helpers behind the trim fields round-trip cleanly.
func test_mmss_helpers() -> void:
	assert_int(JourneyData.mmss_to_ms("2:30")).is_equal(150000)
	assert_int(JourneyData.mmss_to_ms("1:02:03")).is_equal(3723000)
	assert_int(JourneyData.mmss_to_ms("90")).is_equal(90000)
	assert_int(JourneyData.mmss_to_ms("")).is_equal(0)
	assert_str(JourneyData.ms_to_mmss(150000)).is_equal("2:30")
	assert_str(JourneyData.ms_to_mmss(0)).is_equal("0:00")
	assert_int(JourneyData.mmss_to_ms(JourneyData.ms_to_mmss(754000))).is_equal(754000)


func _seg(a: int, b: int) -> Array:
	return [{"in_ms": a, "out_ms": b}]


func test_fingerprint_trim_awareness() -> void:
	var src := "user://some_video.mp4"
	assert_str(JourneyData.media_fingerprint(src, [])).is_equal(JourneyData.media_fingerprint(src))
	assert_str(JourneyData.media_fingerprint(src, _seg(1000, 3000))).is_equal(
		JourneyData.media_fingerprint(src, _seg(1000, 3000))
	)
	(
		assert_bool(
			(
				JourneyData.media_fingerprint(src, _seg(1000, 3000))
				== JourneyData.media_fingerprint(src)
			)
		)
		. is_false()
	)


# The animated-image bake reuses the fingerprint to keep per-surface bakes apart: one GIF baked at
# the boss cap and the storyboard cap must NOT pool to the same file, but the same cap twice must.
func test_fingerprint_variant_separates_bakes() -> void:
	var src := "user://anim.gif"
	# An empty variant is the legacy identity — existing pooled rels must stay stable.
	assert_str(JourneyData.media_fingerprint(src, [], "")).is_equal(
		JourneyData.media_fingerprint(src)
	)
	var boss := JourneyData.media_fingerprint(src, [], "anim:760x480")
	var story := JourneyData.media_fingerprint(src, [], "anim:1920x1080")
	var still_boss := JourneyData.media_fingerprint(src, [], "still:760x480")
	assert_str(boss).is_not_equal(story)  # different caps → different files
	assert_str(boss).is_not_equal(still_boss)  # animated vs static → different files
	assert_str(boss).is_not_equal(JourneyData.media_fingerprint(src))  # variant vs legacy
	assert_str(boss).is_equal(JourneyData.media_fingerprint(src, [], "anim:760x480"))  # dedupes
	(
		assert_bool(
			(
				JourneyData.media_fingerprint(src, _seg(1000, 3000))
				== JourneyData.media_fingerprint(src, _seg(1000, 4000))
			)
		)
		. is_false()
	)


# ── Section looping (legacy) ─────────────────────────────────────────────────
# Section looping is now expressed as repeated segments (see edl_test.gd). has_section_loop
# survives only as the migration gate in normalize_segments — it decides whether a round saved
# before segments existed had a real loop to expand — so its exact acceptance rules still
# matter and stay tested here.


func test_has_section_loop_gating() -> void:
	# Real loop: ≥2 passes over a non-empty window inside the trim.
	assert_bool(JourneyData.has_section_loop(0, 4000, 1000, 3000, 3)).is_true()
	assert_bool(JourneyData.has_section_loop(0, 0, 1000, 3000, 3)).is_true()  # trim_out 0 = to end
	# Not a loop: <2 passes, empty/inverted window, or window outside the trim.
	assert_bool(JourneyData.has_section_loop(0, 4000, 1000, 3000, 1)).is_false()
	assert_bool(JourneyData.has_section_loop(0, 4000, 2000, 2000, 3)).is_false()
	assert_bool(JourneyData.has_section_loop(1500, 4000, 1000, 3000, 3)).is_false()  # loop_in < trim_in


# The legacy loop expands to the same points through the EDL path — the equivalence that makes
# the migration safe. Window [1000,3000] ×3 → 1000 intro + 3×2000 + 1000 finale = 8000ms.
func test_legacy_loop_expands_through_edl() -> void:
	var points := _pts([[0, 0], [1000, 100], [2000, 0], [3000, 100], [4000, 0]])
	var segs: Array = (
		JourneyData
		. normalize_segments(
			{
				"trim_start_ms": 0,
				"trim_end_ms": 4000,
				"loop_in_ms": 1000,
				"loop_out_ms": 3000,
				"loop_count": 3,
			}
		)
	)
	assert_array(JourneyData.build_edl_action_points(points, segs, 4000)).is_equal(
		_pts(
			[
				[0, 0],
				[1000, 100],
				[2000, 0],
				[3000, 100],
				[4000, 0],
				[5000, 100],
				[6000, 0],
				[7000, 100],
				[8000, 0]
			]
		)
	)
