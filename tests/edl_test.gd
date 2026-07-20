extends GdUnitTestSuite

# The segment list (EDL) that replaced per-round trim + section looping: an ordered list of
# source windows, baked end to end at save. Covers the legacy migration, the baked funscript,
# and the fingerprint canonicalization that keeps already-pooled files stable.


func _seg(a: int, b: int) -> Dictionary:
	return {"in_ms": a, "out_ms": b}


func _pts(pairs: Array) -> Array:
	var out: Array = []
	for p: Array in pairs:
		out.append(Vector2(p[0], p[1]))
	return out


func _ats(points: Array) -> Array:
	return points.map(func(p: Vector2) -> int: return int(p.x))


# ── Migration off the legacy fields ──────────────────────────────────────────


# No trim and no loop is the full clip — no segments at all.
func test_normalize_untouched_round_has_no_segments() -> void:
	assert_array(JourneyData.normalize_segments({})).is_empty()
	assert_array(JourneyData.normalize_segments({"trim_start_ms": 0, "trim_end_ms": 0})).is_empty()


# A plain trim becomes exactly one segment.
func test_normalize_trim_becomes_one_segment() -> void:
	var segs: Array = JourneyData.normalize_segments({"trim_start_ms": 1000, "trim_end_ms": 5000})
	assert_array(segs).is_equal([_seg(1000, 5000)])


# An open-ended trim (trim_end 0 = "to the end") survives as an open segment.
func test_normalize_open_ended_trim() -> void:
	var segs: Array = JourneyData.normalize_segments({"trim_start_ms": 2000, "trim_end_ms": 0})
	assert_array(segs).is_equal([_seg(2000, 0)])


# A section loop expands to intro + the window once per pass + finale. This is the shape
# change users see: loop_count 3 becomes 3 rows, not one row with a count.
func test_normalize_section_loop_expands_to_rows() -> void:
	var segs: Array = (
		JourneyData
		. normalize_segments(
			{
				"trim_start_ms": 0,
				"trim_end_ms": 35000,
				"loop_in_ms": 12000,
				"loop_out_ms": 20000,
				"loop_count": 3,
			}
		)
	)
	(
		assert_array(segs)
		. is_equal(
			[
				_seg(0, 12000),  # intro
				_seg(12000, 20000),  # ×3
				_seg(12000, 20000),
				_seg(12000, 20000),
				_seg(20000, 35000),  # finale
			]
		)
	)


# A loop starting at the trim-in has no intro; one ending at the trim-out has no finale.
func test_normalize_section_loop_without_intro_or_finale() -> void:
	var segs: Array = (
		JourneyData
		. normalize_segments(
			{
				"trim_start_ms": 4000,
				"trim_end_ms": 8000,
				"loop_in_ms": 4000,
				"loop_out_ms": 8000,
				"loop_count": 2,
			}
		)
	)
	assert_array(segs).is_equal([_seg(4000, 8000), _seg(4000, 8000)])


# A loop the old has_section_loop would have rejected (count < 2) degrades to the plain trim —
# matching what the previous save pipeline actually baked.
func test_normalize_rejects_degenerate_loop() -> void:
	var segs: Array = (
		JourneyData
		. normalize_segments(
			{
				"trim_start_ms": 1000,
				"trim_end_ms": 9000,
				"loop_in_ms": 2000,
				"loop_out_ms": 3000,
				"loop_count": 1,
			}
		)
	)
	assert_array(segs).is_equal([_seg(1000, 9000)])


# Once segments exist they win outright, and re-normalizing is a no-op (load→save→load stable).
func test_normalize_is_idempotent() -> void:
	var once: Array = JourneyData.normalize_segments({"trim_start_ms": 1000, "trim_end_ms": 5000})
	var twice: Array = JourneyData.normalize_segments({"segments": once})
	assert_array(twice).is_equal(once)


# Present segments take priority over stale legacy fields left on the same dict.
func test_normalize_segments_win_over_legacy_fields() -> void:
	var segs: Array = JourneyData.normalize_segments(
		{"segments": [_seg(100, 200)], "trim_start_ms": 9000, "trim_end_ms": 9999}
	)
	assert_array(segs).is_equal([_seg(100, 200)])


# JSON loads numbers as float ("the coins lesson") — coercion keeps them ints.
func test_coerce_segments_reinstates_ints() -> void:
	var segs: Array = JourneyData.coerce_segments([{"in_ms": 1000.0, "out_ms": 5000.0}])
	assert_int(int((segs[0] as Dictionary)["in_ms"])).is_equal(1000)
	assert_int(int((segs[0] as Dictionary)["out_ms"])).is_equal(5000)


# Garbage rows are dropped rather than baked into a broken concat list.
func test_coerce_segments_drops_impossible_windows() -> void:
	var segs: Array = JourneyData.coerce_segments(
		[{"in_ms": 5000, "out_ms": 5000}, {"in_ms": 8000, "out_ms": 2000}, "nonsense", _seg(0, 100)]
	)
	assert_array(segs).is_equal([_seg(0, 100)])


# ── Baked funscript ──────────────────────────────────────────────────────────

const RAMP := [[0, 0], [1000, 100], [2000, 0], [3000, 100], [4000, 0]]


# No segments = untouched.
func test_build_edl_empty_returns_source() -> void:
	var pts: Array = _pts(RAMP)
	assert_array(JourneyData.build_edl_action_points(pts, [])).is_equal(pts)


# One segment behaves exactly like the old trim path.
func test_build_edl_single_segment_matches_trim() -> void:
	var pts: Array = _pts(RAMP)
	var edl: Array = JourneyData.build_edl_action_points(pts, [_seg(1000, 3000)])
	assert_array(edl).is_equal(JourneyData.trim_action_points(pts, 1000, 3000))


# A duplicated window is laid down twice, the second shifted by its own duration — this is
# what makes a repeat just a duplicated row.
func test_build_edl_duplicate_window_tiles() -> void:
	var pts: Array = _pts(RAMP)
	var edl: Array = JourneyData.build_edl_action_points(pts, [_seg(1000, 3000), _seg(1000, 3000)])
	# Two 2000ms passes → the run ends at 4000ms.
	assert_int(int((edl[-1] as Vector2).x)).is_equal(4000)
	# The seam is not duplicated (one point at the join, not two).
	assert_array(_ats(edl)).contains_exactly_in_any_order([0, 1000, 2000, 3000, 4000])


# Windows may be listed out of source order — that's what rearranging is.
func test_build_edl_honours_list_order_not_source_order() -> void:
	var pts: Array = _pts(RAMP)
	var edl: Array = JourneyData.build_edl_action_points(pts, [_seg(3000, 4000), _seg(0, 1000)])
	# First segment starts at source pos 100 (t=3000), second at pos 0 (t=0).
	assert_int(int((edl[0] as Vector2).y)).is_equal(100)
	assert_int(int((edl[-1] as Vector2).x)).is_equal(2000)


# A migrated section loop bakes to exactly what the old loop builder produced — the guarantee
# that makes the migration safe. Written out literally because that builder is now deleted.
# RAMP, trim [0,4000], loop [1000,2000] ×3 → 1000ms intro + 3×1000ms + 2000ms finale.
# Seam behaviour carried over: where one pass ends and the next begins on the same timestamp,
# the later position wins.
func test_build_edl_matches_legacy_loop_output() -> void:
	var segs: Array = (
		JourneyData
		. normalize_segments(
			{
				"trim_start_ms": 0,
				"trim_end_ms": 4000,
				"loop_in_ms": 1000,
				"loop_out_ms": 2000,
				"loop_count": 3,
			}
		)
	)
	var edl: Array = JourneyData.build_edl_action_points(_pts(RAMP), segs, 4000)
	(
		assert_array(edl)
		. is_equal(
			_pts(
				[
					[0, 0],
					[1000, 100],
					[2000, 100],
					[3000, 100],
					[4000, 0],
					[5000, 100],
					[6000, 0],
				]
			)
		)
	)


# An open-ended final segment runs to the source length when one is supplied.
func test_build_edl_open_segment_uses_source_length() -> void:
	var pts: Array = _pts(RAMP)
	var edl: Array = JourneyData.build_edl_action_points(pts, [_seg(0, 1000), _seg(3000, 0)], 4000)
	assert_int(int((edl[-1] as Vector2).x)).is_equal(2000)  # 1000 + (4000-3000)


# Total length sums the windows; an empty list is the whole source.
func test_segments_total_ms() -> void:
	assert_int(JourneyData.segments_total_ms([], 30000)).is_equal(30000)
	(
		assert_int(
			JourneyData.segments_total_ms(
				[_seg(0, 1000), _seg(5000, 6000), _seg(5000, 6000)], 30000
			)
		)
		. is_equal(3000)
	)
	# Open-ended segments resolve against the source length.
	assert_int(JourneyData.segments_total_ms([_seg(20000, 0)], 30000)).is_equal(10000)


# edl_funscript_json swaps the actions and keeps every other metadata key.
func test_edl_funscript_json_preserves_metadata() -> void:
	var fs := {
		"actions": [{"at": 0, "pos": 0}, {"at": 1000, "pos": 100}, {"at": 2000, "pos": 0}],
		"range": 90,
		"version": "1.0",
	}
	var out: Dictionary = JourneyData.edl_funscript_json(fs, [_seg(1000, 2000)])
	assert_int(int(out["range"])).is_equal(90)
	assert_str(str(out["version"])).is_equal("1.0")
	assert_int((out["actions"] as Array).size()).is_equal(2)
	assert_int(int((out["actions"] as Array)[0]["at"])).is_equal(0)  # rebased to 0


# ── Fingerprint canonicalization ─────────────────────────────────────────────
# These protect every already-pooled file on disk: if the identity for an untouched or
# singly-trimmed clip changes, the first save after upgrading re-bakes the whole journey.


# Full clip → the legacy (empty) identity.
func test_identity_empty_is_legacy() -> void:
	assert_str(JourneyData.segments_identity([])).is_equal("")


# One window → byte-identical to the string the old trim path produced.
func test_identity_single_segment_is_legacy_trim_string() -> void:
	assert_str(JourneyData.segments_identity([_seg(1000, 3000)])).is_equal("trim:1000-3000")


# A single 0→end window IS the full clip, so it must not fork the pool.
func test_identity_single_full_span_is_legacy() -> void:
	assert_str(JourneyData.segments_identity([_seg(0, 0)])).is_equal("")


# Anything a trim couldn't express gets the new form.
func test_identity_multi_segment_is_edl() -> void:
	assert_str(JourneyData.segments_identity([_seg(0, 1000), _seg(0, 1000)])).is_equal(
		"edl:0-1000,0-1000"
	)


# Order is part of the identity — rearranged segments bake to different bytes.
func test_identity_is_order_sensitive() -> void:
	var a: String = JourneyData.segments_identity([_seg(0, 1000), _seg(2000, 3000)])
	var b: String = JourneyData.segments_identity([_seg(2000, 3000), _seg(0, 1000)])
	assert_str(a).is_not_equal(b)


# Repeat count is part of the identity — two passes ≠ three passes.
func test_identity_distinguishes_repeat_counts() -> void:
	var twice: String = JourneyData.segments_identity([_seg(0, 100), _seg(0, 100)])
	var thrice: String = JourneyData.segments_identity([_seg(0, 100), _seg(0, 100), _seg(0, 100)])
	assert_str(twice).is_not_equal(thrice)
