extends GdUnitTestSuite

# FunscriptSegmenter — cuts an action list into beats at pauses and tempo changes.
# Every fixture is a hand-built {at, pos} array; no disk, no UI, no rng.
#
# The recurring shape is `_run()`: a metronome whose average speed is
# amp / period * 1000 positions/s, so a fixture's speed (and with it its 1-5 bucket)
# is readable straight from the call. Defaults under test: gap 1500 ms,
# min beat 8000 ms, max beat 60000 ms, tempo window 5000 ms, delta 0.25, min speed 40.


# `count` actions from `start_ms`, `period_ms` apart, alternating 0 / `amp`.
# An odd `count` ends on pos 0, so concatenated runs join without a jump.
func _run(start_ms: int, count: int, period_ms: int, amp: int) -> Array:
	var out: Array = []
	for i in count:
		out.append({"at": start_ms + i * period_ms, "pos": 0 if i % 2 == 0 else amp})
	return out


func _ins(beats: Array) -> Array:
	return beats.map(func(b: Dictionary) -> int: return int(b["in_ms"]))


func _outs(beats: Array) -> Array:
	return beats.map(func(b: Dictionary) -> int: return int(b["out_ms"]))


# ── Step 1: pauses ───────────────────────────────────────────────────────────


# The threshold is exclusive: a gap of exactly gap_threshold_ms is still rhythm,
# one millisecond more is a scene change. Both sides of the edge in one test.
func test_pause_cuts_only_above_the_threshold() -> void:
	var touching: Array = _run(0, 41, 500, 100) + _run(21500, 41, 500, 100)  # gap 1500
	var beats: Array = FunscriptSegmenter.segment(touching)
	assert_array(_ins(beats)).is_equal([0])
	assert_array(_outs(beats)).is_equal([41500])

	var parted: Array = _run(0, 41, 500, 100) + _run(21501, 41, 500, 100)  # gap 1501
	beats = FunscriptSegmenter.segment(parted)
	assert_array(_ins(beats)).is_equal([0, 21501])
	assert_array(_outs(beats)).is_equal([20000, 41501])


# cfg overrides the constants; unknown keys are inert.
func test_gap_threshold_is_configurable() -> void:
	var acts: Array = _run(0, 41, 500, 100) + _run(21000, 41, 500, 100)  # gap 1000
	assert_int(FunscriptSegmenter.segment(acts).size()).is_equal(1)

	var beats: Array = FunscriptSegmenter.segment(acts, {"gap_threshold_ms": 500, "junk": true})
	assert_array(_ins(beats)).is_equal([0, 21000])
	assert_array(_outs(beats)).is_equal([20000, 41000])


# ── Step 2: tempo changes ────────────────────────────────────────────────────


# 80 s without a single pause: too long for one round, so the largest relative
# speed change wins. 40 s at 200/s then 40 s at 400/s — the best candidate is the
# first action of the fast run (left window 189/s vs right 400/s → delta 0.53),
# which beats the last action of the slow run (200 vs 380 → 0.47) because its own
# left window is already dragged down by the wider spacing behind it.
func test_long_block_splits_at_the_tempo_change() -> void:
	var acts: Array = _run(0, 81, 500, 100) + _run(40250, 160, 250, 100)
	var beats: Array = FunscriptSegmenter.segment(acts)
	assert_array(_ins(beats)).is_equal([0, 40250])
	assert_array(_outs(beats)).is_equal([40000, 80000])
	# The cut separates the two tempos, not just the timeline.
	assert_int(int(beats[0]["intensity"])).is_equal(2)
	assert_int(int(beats[1]["intensity"])).is_equal(4)


# The mirror image: 30 s at 400/s then 50 s at 200/s, so left > right at the change.
# Winner is the LAST fast action (30000) — its left window is pure fast (400/s) while
# its right window already reaches 5 s into the slow run (900 positions over 5 s =
# 180/s) → delta 220/400 = 0.55. The first slow action (30500) only reaches
# |200-360|/360 = 0.44, because half its left window is still fast. The cut action
# starts the RIGHT block, so the fast beat ends one action earlier, at 29750.
# The tempo path is what is pinned here: the even division would have cut at 40000.
func test_long_block_splits_at_a_falling_tempo_change() -> void:
	var acts: Array = _run(0, 121, 250, 100) + _run(30500, 100, 500, 100)
	var beats: Array = FunscriptSegmenter.segment(acts)
	assert_array(_ins(beats)).is_equal([0, 30000])
	assert_array(_outs(beats)).is_equal([29750, 80000])
	# 11900 positions over 29.75 s and 9900 over 50 s.
	assert_float(float(beats[0]["speed"])).is_equal_approx(400.0, 0.001)
	assert_float(float(beats[1]["speed"])).is_equal_approx(198.0, 0.001)
	assert_int(int(beats[0]["intensity"])).is_equal(4)
	assert_int(int(beats[1]["intensity"])).is_equal(2)


# The score divides by the FASTER side, so a change is measured against what it has
# to beat. One block with a rise and a fall, and the fall wins although the rise is
# the bigger ratio: rise at 25250 → left 189.47 (dragged down by the slower run
# behind it), right 400 → 210.53/400 = 0.53; fall at 50250 → left 400, right 80
# (five seconds of the 100/s crawl) → 320/400 = 0.80.
# Dividing by the LEFT side instead would score the rise 210.53/189.47 = 1.11 and
# move the cut to 25250 — and nothing downstream would hide it, because both halves
# (50 s and 26 s) are under max_beat_ms and are never re-cut.
func test_tempo_score_is_relative_to_the_faster_side() -> void:
	var slow: Array = _run(0, 51, 500, 100)  # 0..25000      @ 200/s
	var fast: Array = _run(25250, 101, 250, 100)  # 25250..50250  @ 400/s
	var crawl: Array = _run(51250, 26, 1000, 100)  # 51250..76250  @ 100/s
	var beats: Array = FunscriptSegmenter.segment(slow + fast + crawl)
	assert_array(_ins(beats)).is_equal([0, 50250])
	assert_array(_outs(beats)).is_equal([50000, 76250])


# A metronome offers no tempo change to cut on, but must not stay one huge beat.
# Even division into ceil(span / max_beat) pieces, each cut snapped to an action.
func test_constant_tempo_falls_back_to_even_division() -> void:
	var two: Array = FunscriptSegmenter.segment(_run(0, 201, 500, 100))  # 100 s → 2
	assert_array(_ins(two)).is_equal([0, 50000])
	assert_array(_outs(two)).is_equal([49500, 100000])

	var three: Array = FunscriptSegmenter.segment(_run(0, 301, 500, 100))  # 150 s → 3
	assert_array(_ins(three)).is_equal([0, 50000, 100000])
	assert_array(_outs(three)).is_equal([49500, 99500, 150000])


# Every fixture above puts the ideal cut exactly on an action, which makes the snap
# invisible. Here it is the whole point. 215 actions 700 ms apart span 149800 ms →
# ceil(149800 / 60000) = 3 pieces, ideals at round(149800 · 1/3) = 49933 and
# round(149800 · 2/3) = 99867. Neither is a multiple of 700, and the two round in
# OPPOSITE directions: 49933 is 233 ms behind action 71 (49700) but 467 ms ahead of
# action 72 (50400) → snaps back; 99867 is 467 ms behind action 142 (99400) and
# 233 ms ahead of action 143 (100100) → snaps forward. The snapped action starts the
# right piece, so the piece before it ends one action earlier: 70·700 = 49000 and
# 142·700 = 99400.
func test_even_division_snaps_to_the_nearest_action_in_both_directions() -> void:
	var beats: Array = FunscriptSegmenter.segment(_run(0, 215, 700, 100))
	assert_array(_ins(beats)).is_equal([0, 49700, 100100])
	assert_array(_outs(beats)).is_equal([49000, 99400, 149800])


# Exactly between two actions the earlier one wins, so the result can never depend on
# the direction the search happens to scan. 102 actions 700 ms apart span 70700 ms →
# 2 pieces, ideal at exactly 35350: 350 ms from action 50 (35000) and 350 ms from
# action 51 (35700).
func test_even_division_tie_snaps_to_the_earlier_action() -> void:
	var beats: Array = FunscriptSegmenter.segment(_run(0, 102, 700, 100))
	assert_array(_ins(beats)).is_equal([0, 35000])
	assert_array(_outs(beats)).is_equal([34300, 70700])


# The ideal cut is a millisecond, not a second — the 500 ms a rounding would move it
# by is already enough to reach the next action, and §11 forbids exactly that.
# 91 actions 700 ms apart span 63000 ms → 2 pieces, ideal 31500, which IS action 45.
# Rounded to 32 s first it would land 500 ms from action 45 but only 200 ms from
# action 46 (32200) and cut there instead.
func test_even_division_does_not_round_the_ideal_cut_to_seconds() -> void:
	var beats: Array = FunscriptSegmenter.segment(_run(0, 91, 700, 100))
	assert_array(_ins(beats)).is_equal([0, 31500])
	assert_array(_outs(beats)).is_equal([30800, 63000])


# ── Step 3: merging and filtering ────────────────────────────────────────────


# A 4 s fragment between a 400/s and a 100/s neighbour joins the one it matches.
# Same geometry twice, only the fragment's tempo differs — so the assertion is
# purely about "closer in speed", not about position in the list.
func test_short_block_merges_into_the_speed_closer_neighbour() -> void:
	var head: Array = _run(0, 81, 250, 100)  # 0..20000 @ 400/s
	var tail: Array = _run(28000, 21, 1000, 100)  # 28000..48000 @ 100/s

	var fast: Array = FunscriptSegmenter.segment(head + _run(22000, 17, 250, 100) + tail)
	assert_array(_ins(fast)).is_equal([0, 28000])  # fragment went left
	assert_array(_outs(fast)).is_equal([26000, 48000])

	var slow: Array = FunscriptSegmenter.segment(head + _run(22000, 5, 1000, 100) + tail)
	assert_array(_ins(slow)).is_equal([0, 22000])  # fragment went right
	assert_array(_outs(slow)).is_equal([20000, 48000])


# With two fragments the lowest index goes first, and that changes the outcome:
# B (100/s) ties between its 400/s neighbours and takes the previous one, which
# leaves C close enough to the merged block to follow it. Handling C first would
# have glued B+C together instead and left three beats.
func test_short_blocks_merge_lowest_index_first() -> void:
	var a: Array = _run(0, 81, 250, 100)  # 0..20000    @ 400/s
	var b: Array = _run(22000, 6, 1000, 100)  # 22000..27000 @ 100/s, 5 s
	var c: Array = _run(29000, 21, 250, 100)  # 29000..34000 @ 400/s, 5 s
	var d: Array = _run(36000, 21, 1000, 100)  # 36000..56000 @ 100/s
	var beats: Array = FunscriptSegmenter.segment(a + b + c + d)
	assert_array(_ins(beats)).is_equal([0, 36000])
	assert_array(_outs(beats)).is_equal([34000, 56000])


# A fragment at the head has no previous block; it takes the only neighbour it has.
func test_short_block_merges_with_its_only_neighbour() -> void:
	var a: Array = _run(0, 11, 500, 100)  # 0..5000, 5 s
	var b: Array = _run(7000, 11, 500, 100)  # 7000..12000, 5 s
	var c: Array = _run(14000, 41, 500, 100)  # 14000..34000
	var beats: Array = FunscriptSegmenter.segment(a + b + c)
	assert_array(_ins(beats)).is_equal([0, 14000])
	assert_array(_outs(beats)).is_equal([12000, 34000])


# A long but nearly motionless passage (20/s) is dropped, not merged — it is long
# enough to stand alone and therefore never a merge candidate.
func test_dead_passage_below_min_speed_is_dropped() -> void:
	var acts: Array = _run(0, 41, 500, 100) + _run(22000, 21, 1000, 20)
	var beats: Array = FunscriptSegmenter.segment(acts)
	assert_array(_ins(beats)).is_equal([0])
	assert_array(_outs(beats)).is_equal([20000])


# Nothing to merge with and too short to keep → no beats at all.
func test_everything_shorter_than_min_beat_yields_nothing() -> void:
	assert_array(FunscriptSegmenter.segment(_run(0, 9, 500, 100))).is_empty()


# ── Edge cases ───────────────────────────────────────────────────────────────


func test_empty_short_and_malformed_input_yields_nothing() -> void:
	assert_array(FunscriptSegmenter.segment([])).is_empty()
	assert_array(FunscriptSegmenter.segment([{"at": 0, "pos": 0}])).is_empty()
	# Non-dictionaries are dropped, leaving a single usable action.
	assert_array(FunscriptSegmenter.segment(["nonsense", 42, null, {"at": 0, "pos": 0}])).is_empty()


# Two actions are a valid block — it just has to clear both bars. A pair can never
# move faster than 100 positions over min_beat_ms, so with the defaults it always
# dies on min_speed; lower that bar and the same pair survives.
func test_two_far_apart_actions_need_length_and_speed() -> void:
	var pair: Array = [{"at": 0, "pos": 0}, {"at": 10000, "pos": 100}]
	assert_array(FunscriptSegmenter.segment(pair)).is_empty()

	var beats: Array = FunscriptSegmenter.segment(pair, {"min_speed": 5.0})
	assert_array(_ins(beats)).is_equal([0])
	assert_array(_outs(beats)).is_equal([10000])
	assert_int(int(beats[0]["action_count"])).is_equal(2)

	# Still too short at 4 s, however slow the bar is set.
	var close: Array = [{"at": 0, "pos": 0}, {"at": 4000, "pos": 100}]
	assert_array(FunscriptSegmenter.segment(close, {"min_speed": 0.0})).is_empty()


# The caller's array is read, never rewritten — the registry hands us the parsed
# funscript and expects it back untouched.
func test_unsorted_input_is_sorted_defensively_and_not_mutated() -> void:
	var acts: Array = _run(0, 41, 500, 100)
	acts.reverse()
	var beats: Array = FunscriptSegmenter.segment(acts)
	assert_array(_ins(beats)).is_equal([0])
	assert_array(_outs(beats)).is_equal([20000])
	assert_int(int((acts[0] as Dictionary)["at"])).is_equal(20000)  # still reversed


# Two actions on the same millisecond are one action, and the later one wins. The
# surviving list 0 → 20 → 0 travels 40 positions in 20 s (2/s); keeping the FIRST
# twin would travel 0 → 100 → 0 = 200 (10/s) and keeping BOTH would travel
# 100 + 80 + 20 = 200 as well, so speed and action_count separate all three.
# The two cfg overrides only keep the passes out of the way — one block, no filter.
func test_duplicate_timestamps_collapse_with_the_last_value_winning() -> void:
	var acts: Array = [
		{"at": 0, "pos": 0},
		{"at": 10000, "pos": 100},
		{"at": 10000, "pos": 20},
		{"at": 20000, "pos": 0},
	]
	var beats: Array = FunscriptSegmenter.segment(
		acts, {"gap_threshold_ms": 20000, "min_speed": 0.0}
	)
	assert_int(beats.size()).is_equal(1)
	assert_int(int(beats[0]["action_count"])).is_equal(3)
	assert_float(float(beats[0]["speed"])).is_equal_approx(2.0, 0.001)


# A duplicate exactly where a cut lands is the case the collapse exists for. The
# even division of the fixture above snaps its first cut BACK onto 49700, i.e. onto
# the earlier of the two twins; undeduplicated, twin A would end the left beat and
# twin B would start the right one — 49700 in two beats at once, and one action in
# two parts (§1). Collapsed, the run is the clean fixture again, down to the action
# counts (71 + 72 + 72 = 215).
func test_duplicate_at_a_cut_boundary_never_lands_in_two_beats() -> void:
	var acts: Array = _run(0, 215, 700, 100)
	acts.insert(72, {"at": 49700, "pos": 100})  # twin of action 71
	var beats: Array = FunscriptSegmenter.segment(acts)
	assert_array(_ins(beats)).is_equal([0, 49700, 100100])
	assert_array(_outs(beats)).is_equal([49000, 99400, 149800])
	var counts: Array = beats.map(func(b: Dictionary) -> int: return int(b["action_count"]))
	assert_array(counts).is_equal([71, 72, 72])
	for k in range(1, beats.size()):
		assert_int(int(beats[k]["in_ms"])).is_greater(int(beats[k - 1]["out_ms"]))


# ── Invariants the rest of the feature builds on ─────────────────────────────


# One script with everything in it: pauses, a dead stretch, a fragment, and a
# 120 s metronome that only even division can break up. Asserted literally first,
# then as the contract invariants W2/W3 rely on.
func test_composite_script_holds_every_invariant() -> void:
	var slow: Array = _run(0, 121, 500, 100)  # 0..60000       @ 200/s
	var fast: Array = _run(63000, 241, 250, 100)  # 63000..123000  @ 400/s
	var dead: Array = _run(125000, 21, 1000, 20)  # 125000..145000 @ 20/s
	var frag: Array = _run(147000, 9, 500, 100)  # 147000..151000 — 4 s
	var metro: Array = _run(153000, 241, 500, 100)  # 153000..273000 @ 200/s, evenly halved
	var acts: Array = slow + fast + dead + frag + metro
	var beats: Array = FunscriptSegmenter.segment(acts)
	# The fragment merges into the (equally fast) half behind it; the dead stretch goes.
	assert_array(_ins(beats)).is_equal([0, 63000, 147000, 213000])
	assert_array(_outs(beats)).is_equal([60000, 123000, 212500, 273000])

	var stamps: Array = acts.map(func(a: Dictionary) -> int: return int(a["at"]))
	var prev_out: int = -1
	for beat: Dictionary in beats:
		var in_ms: int = int(beat["in_ms"])
		var out_ms: int = int(beat["out_ms"])
		assert_bool(stamps.has(in_ms)).is_true()  # boundaries are real actions
		assert_bool(stamps.has(out_ms)).is_true()
		assert_int(in_ms).is_greater(prev_out)  # ascending and disjoint
		assert_int(out_ms - in_ms).is_greater_equal(FunscriptSegmenter.MIN_BEAT_MS)
		assert_float(float(beat["speed"])).is_greater_equal(FunscriptSegmenter.MIN_SPEED)
		assert_int(int(beat["action_count"])).is_greater_equal(2)
		prev_out = out_ms


# The metrics are FunscriptIntensity's, measured on the beat's own slice —
# there is no second rating scale.
func test_metrics_come_from_funscript_intensity() -> void:
	var acts: Array = _run(0, 41, 500, 100) + _run(22000, 81, 250, 100)
	var beats: Array = FunscriptSegmenter.segment(acts)
	assert_int(beats.size()).is_equal(2)
	for b: Dictionary in beats:
		var slice: Array = []
		for a: Dictionary in acts:
			if int(a["at"]) >= int(b["in_ms"]) and int(a["at"]) <= int(b["out_ms"]):
				slice.append(a)
		var measured: float = FunscriptIntensity.average_speed(slice)
		assert_float(float(b["speed"])).is_equal_approx(measured, 0.001)
		assert_int(int(b["intensity"])).is_equal(FunscriptIntensity.bucket(float(b["speed"])))
		assert_int(int(b["action_count"])).is_equal(slice.size())
	assert_float(float(beats[0]["speed"])).is_equal_approx(200.0, 0.001)
	assert_float(float(beats[1]["speed"])).is_equal_approx(400.0, 0.001)
