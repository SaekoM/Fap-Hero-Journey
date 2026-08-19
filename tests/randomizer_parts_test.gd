extends GdUnitTestSuite

# RandomizerParts — the pure expansion layer that tiles a video's funscript beats
# into round-sized parts and emits them as pseudo-entries in the existing entry
# format. Every test feeds hand-written beat arrays (no FunscriptSegmenter, no
# disk) and a seeded RandomNumberGenerator, so the tiling, the intensity bias,
# the coherence brake and the part-id grammar are all asserted headless.
#
# Fantasy source paths are deliberate: media_fingerprint hashes "<abs>|0|0|trim:a-b"
# for a missing file, so the rel prediction stays deterministic without any I/O.

# ── Fixtures ─────────────────────────────────────────────────────────────────

# Speeds picked so FunscriptIntensity.bucket lands exactly on the wanted level
# (thresholds 100/250/400/550).
const SPEED_I1: float = 50.0
const SPEED_I2: float = 150.0
const SPEED_I3: float = 300.0
const SPEED_I4: float = 420.0
const SPEED_I5: float = 600.0

# Default range from the contract: 60–180 s with ±0.15 × span jitter.
const MIN_MS: int = 60000
const MAX_MS: int = 180000


# action_count is DERIVED from speed and duration, never a free parameter: a beat's
# speed is summed |Δpos| per second on the 0–100 position scale, so over `d` seconds
# it travels speed·d positions ≈ speed·d/100 full-range strokes, i.e. that many
# actions. A hard-coded constant would put the same 40 actions on an 8 s crawl and
# on a two-minute intensity-5 wall — physically impossible, and it would silently
# turn an action_count-weighted mean into a plain unweighted one, hiding exactly the
# §5.3 weighting the tests below pin down.
func _beat(in_ms: int, out_ms: int, speed: float) -> Dictionary:
	var secs: float = float(out_ms - in_ms) / 1000.0
	return {
		"in_ms": in_ms,
		"out_ms": out_ms,
		"speed": speed,
		"intensity": FunscriptIntensity.bucket(speed),
		"action_count": maxi(2, roundi(speed * secs / 100.0)),
	}


# `n` beats of `len_ms`, laid out with a `gap_ms` hole between them — the beats a
# segmenter emits are disjoint runs, never touching (contract §1).
func _beats(n: int, len_ms: int, speed: float, gap_ms: int = 200) -> Array:
	var out: Array = []
	for i: int in n:
		var start: int = i * (len_ms + gap_ms)
		out.append(_beat(start, start + len_ms, speed))
	return out


func _video(id: String, beats: Array, part_used: Dictionary = {}) -> Dictionary:
	return {
		"id": id,
		"name": "Clip " + id,
		"video_src": "res://__fixture__/%s.mp4" % id,
		"funscript_src": "res://__fixture__/%s.funscript" % id,
		"axis_src": {"twist": "res://__fixture__/%s.twist.funscript" % id},
		"vib_src": {},
		"needs_transcode": false,
		"video_rel": "content/%s.mp4" % id,
		"funscript_rel": "content/%s.funscript" % id,
		"axis_rel": {"twist": "content/%s.twist.funscript" % id},
		"vib_rel": {},
		"boss_image_rel": "content/%s.png" % id,
		"action_count": 5000,
		"length_ms": 1800000,
		"duration_ms": 1800000,
		"tags": ["fixture"],
		"weight": 2.5,
		"intensity": 3,
		"last_used": 111,
		"added_at": 222,
		"parts": beats,
		"part_used": part_used,
	}


# A clip with no script at all — the whole-clip path.
func _whole_clip(id: String) -> Dictionary:
	var e: Dictionary = _video(id, [])
	e["funscript_src"] = ""
	e["axis_src"] = {}
	return e


func _cfg(extra: Dictionary = {}) -> Dictionary:
	# Full-strength coupling by default so the tiling tests reason about target lengths at the
	# classic hard→short mapping; the softened product default (0.5) is covered on its own in
	# test_target_length_ms_coupling. `extra` still wins.
	var c: Dictionary = {"cut_parts": true, "intensity_length_coupling": 1.0}
	c.merge(extra, true)
	return c


func _rng(seed_val: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


func _seg_of(entry: Dictionary) -> Dictionary:
	return (entry["segments"] as Array)[0]


# [[in_ms, out_ms], …] — the tiling signature used to compare runs.
func _tiling(entries: Array) -> Array:
	var out: Array = []
	for e: Dictionary in entries:
		var s: Dictionary = _seg_of(e)
		out.append([int(s["in_ms"]), int(s["out_ms"])])
	return out


func _expand_one(video: Dictionary, seed_val: int, extra: Dictionary = {}) -> Array:
	return RandomizerParts.expand([video], _cfg(extra), _rng(seed_val))


# ── Tiling invariants ────────────────────────────────────────────────────────


# The core structural guarantee the generator relies on: every beat belongs to
# exactly one part, in order, with no beat split and none dropped. Walking the
# beats alongside the parts must consume the list exactly.
func test_tiling_is_gapless_and_disjoint() -> void:
	var beats: Array = _beats(60, 8000, SPEED_I3)
	for seed_val: int in [1, 2, 3, 17, 4242]:
		var parts: Array = _expand_one(_video("gap", beats), seed_val)
		assert_array(parts).is_not_empty()
		var bi: int = 0
		var prev_out: int = -1
		for p: Dictionary in parts:
			var s: Dictionary = _seg_of(p)
			# A part starts on the next unconsumed beat's in_ms …
			assert_int(int(s["in_ms"])).is_equal(int((beats[bi] as Dictionary)["in_ms"]))
			# … and ends on some later beat's out_ms, consuming everything between.
			while (
				bi < beats.size() and int((beats[bi] as Dictionary)["out_ms"]) != int(s["out_ms"])
			):
				bi += 1
			assert_int(bi).is_less(beats.size())  # the out_ms was a real beat boundary
			bi += 1
			assert_int(int(s["in_ms"])).is_greater(prev_out)  # disjoint, strictly ordered
			prev_out = int(s["out_ms"])
		assert_int(bi).is_equal(beats.size())  # every beat consumed


# The rng is the only entropy source, so a re-run with the same seed must
# reproduce the cut points bit for bit.
func test_same_seed_same_tiling() -> void:
	var beats: Array = _beats(60, 8000, SPEED_I3)
	var a: Array = _expand_one(_video("det", beats), 12345)
	var b: Array = _expand_one(_video("det", beats), 12345)
	assert_str(JSON.stringify(_tiling(a))).is_equal(JSON.stringify(_tiling(b)))


# …and a different seed must actually move them, or the feature buys nothing.
# Asserted over a spread of seeds: any single pair could legitimately collide.
func test_different_seed_changes_tiling() -> void:
	var beats: Array = _beats(60, 8000, SPEED_I3)
	var seen: Dictionary = {}
	for seed_val: int in [1, 2, 3, 4, 5, 6, 7, 8]:
		seen[JSON.stringify(_tiling(_expand_one(_video("var", beats), seed_val)))] = true
	assert_int(seen.size()).is_greater(1)


# Intensity 5 pulls the target to the bottom of the range, intensity 1 to the
# top. Same beat grid, same seed — only the speed differs, and the part lengths
# must separate cleanly.
func test_intensity_bias_shortens_hard_parts() -> void:
	var hard: Array = _expand_one(_video("hard", _beats(40, 20000, SPEED_I5)), 77)
	var soft: Array = _expand_one(_video("soft", _beats(40, 20000, SPEED_I1)), 77)
	var hard_avg: float = _avg_length(hard)
	var soft_avg: float = _avg_length(soft)
	assert_float(hard_avg).is_less(soft_avg)
	# Intensity 5 → centre 60 s (+18 s jitter); intensity 1 → centre 180 s.
	assert_float(hard_avg).is_less(100000.0)
	assert_float(soft_avg).is_greater(120000.0)
	assert_int(hard.size()).is_greater(soft.size())  # shorter parts → more of them


func _avg_length(parts: Array) -> float:
	var total: int = 0
	for p: Dictionary in parts:
		total += int(p["length_ms"])
	return float(total) / float(maxi(1, parts.size()))


# Three calm beats then a wall of hard ones. The target for intensity 1 is ~180 s,
# far beyond the 24 s the calm run spans — so only the coherence brake can end
# that part, and it must end it exactly at the jump.
func test_coherence_brake_stops_at_intensity_jump() -> void:
	var beats: Array = _beats(3, 8000, SPEED_I1)
	var tail: Array = _beats(12, 8000, SPEED_I5)
	var offset: int = 3 * 8200
	for b: Dictionary in tail:
		beats.append(_beat(offset + int(b["in_ms"]), offset + int(b["out_ms"]), SPEED_I5))
	var parts: Array = _expand_one(_video("brake", beats), 5)
	assert_int(parts.size()).is_greater_equal(2)
	var first: Dictionary = parts[0]
	assert_int(int(_seg_of(first)["out_ms"])).is_equal(int((beats[2] as Dictionary)["out_ms"]))
	assert_int(int(first["intensity"])).is_equal(1)
	# The part is far short of its own target — proof the brake, not the length, cut it.
	assert_int(int(first["length_ms"])).is_less(MIN_MS)
	assert_int(int(parts[1]["intensity"])).is_equal(5)


# §5.5 — the brake compares each candidate against the RUNNING length-weighted mean
# of what is already in the part: not against the part's first beat, and not against
# its immediate predecessor. Four beats of the SAME length (20 s), so "length
# weighted" collapses to the plain running average and only the "running" half is
# under test here; tolerance 1, and a 300–600 s range puts the rolled target
# (≥ 555 s for an intensity-1 opener) far out of reach so nothing but the brake can
# cut. Speeds 50/150/300/420 → buckets 1/2/3/4.
#
#   step  merged so far   running mean            candidate  |Δ|  verdict
#     1   50              50/1          =  50 → 1     2       1   merge
#     2   50,150          200/2         = 100 → 2     3       1   merge
#     3   50,150,300      500/3         = 166.7 → 2   4       2   BREAK
#
# Beats 0–2 therefore become ONE part ending at 60400, and the 420 beat opens the
# next. The two wrong references both change the answer:
#   · against the FIRST beat's intensity (fixed at 1), step 2 already breaks
#     (|3-1| = 2) and the first part ends at 40200 instead of 60400;
#   · against the PREDECESSOR beat (3 at step 3), step 3 merges (|4-3| = 1) and the
#     whole video collapses into a single part ending at 80600.
# The part's own intensity is that same weighted mean, bucket(166.7) = 2 — pinned
# because reading it off the first beat would give 1 and go unnoticed otherwise.
func test_coherence_brake_follows_the_running_weighted_mean() -> void:
	var beats: Array = [
		_beat(0, 20000, SPEED_I1),
		_beat(20200, 40200, SPEED_I2),
		_beat(40400, 60400, SPEED_I3),
		_beat(60600, 80600, SPEED_I4),
	]
	var wide: Dictionary = {"part_min_s": 300, "part_max_s": 600, "intensity_tolerance": 1}
	var mean: float = (50.0 * 20000.0 + 150.0 * 20000.0 + 300.0 * 20000.0) / 60000.0
	for seed_val: int in [1, 7, 4242]:
		var parts: Array = _expand_one(_video("run", beats), seed_val, wide)
		assert_int(parts.size()).is_equal(2)
		assert_int(int(_seg_of(parts[0])["out_ms"])).is_equal(60400)
		assert_int(int(_seg_of(parts[1])["in_ms"])).is_equal(60600)
		# Far below even the smallest possible target — only the brake can have cut.
		assert_int(int(parts[0]["length_ms"])).is_less(300000)
		# The pseudo-entry exposes no raw speed (§2.2), so the weighted mean is pinned
		# through the only field that carries it: the bucket.
		assert_int(int(parts[0]["intensity"])).is_equal(FunscriptIntensity.bucket(mean))
		assert_int(int(parts[0]["intensity"])).is_equal(2)
		assert_int(int(parts[1]["intensity"])).is_equal(4)


# …and the other half of §5.3: the running mean is weighted by beat LENGTH, not by
# beat count and not by action_count. Two fixtures, one per wrong weighting; both
# use the same generous 300–600 s range so the target can never be the cutter.
#
# (1) unweighted (plain) mean. A short fast beat and a long faster one:
#       300 × 8 s + 420 × 100 s → 44 400 000 / 108 000 = 411.1 → bucket 4
#       plain mean (300 + 420) / 2                     = 360   → bucket 3
#     A following intensity-5 beat is 1 step from 4 (merge) but 2 steps from 3
#     (break), so the whole thing is ONE part only when the weighting is by length.
#
# (2) action_count weighting. Because actions scale with speed × length, an
#     action-weighted mean is pulled towards the FAST beat instead of the LONG one:
#       399 × 8 s (32 actions) + 100 × 20 s (20 actions)
#       by length: 5 192 000 / 28 000          = 185.4 → bucket 2
#       by actions: (399·32 + 100·20) / 52     = 284.0 → bucket 3
#     A following intensity-1 beat is 1 step from 2 (merge) but 2 steps from 3
#     (break) — again a single part only for the length-weighted reading.
func test_running_intensity_is_length_weighted() -> void:
	var wide: Dictionary = {"part_min_s": 300, "part_max_s": 600, "intensity_tolerance": 1}

	var by_length: float = (300.0 * 8000.0 + 420.0 * 100000.0) / 108000.0
	assert_float(by_length).is_equal_approx(411.111, 0.001)
	assert_int(FunscriptIntensity.bucket(by_length)).is_equal(4)
	assert_int(FunscriptIntensity.bucket((300.0 + 420.0) / 2.0)).is_equal(3)
	var mixed: Array = [
		_beat(0, 8000, SPEED_I3),  # 8 s at 300 → 24 actions
		_beat(8200, 108200, SPEED_I4),  # 100 s at 420 → 420 actions
		_beat(108400, 128400, SPEED_I5),  # 20 s at 600 → 120 actions
	]
	var parts: Array = _expand_one(_video("wlen", mixed), 91, wide)
	assert_int(parts.size()).is_equal(1)
	assert_int(int(_seg_of(parts[0])["out_ms"])).is_equal(128400)
	assert_int(int(parts[0]["action_count"])).is_equal(564)
	# 56 400 000 / 128 000 = 440.625 → bucket 4.
	assert_int(int(parts[0]["intensity"])).is_equal(FunscriptIntensity.bucket(440.625))
	assert_int(int(parts[0]["intensity"])).is_equal(4)

	assert_int(FunscriptIntensity.bucket(5192000.0 / 28000.0)).is_equal(2)
	assert_int(FunscriptIntensity.bucket((399.0 * 32.0 + 100.0 * 20.0) / 52.0)).is_equal(3)
	var skewed: Array = [
		_beat(0, 8000, 399.0),  # 8 s at 399 → 32 actions
		_beat(8200, 28200, 100.0),  # 20 s at 100 → 20 actions
		_beat(28400, 48400, SPEED_I1),  # 20 s at 50 → 10 actions
	]
	var slow: Array = _expand_one(_video("wact", skewed), 91, wide)
	assert_int(slow.size()).is_equal(1)
	assert_int(int(_seg_of(slow[0])["out_ms"])).is_equal(48400)
	assert_int(int(slow[0]["action_count"])).is_equal(62)
	# 6 192 000 / 48 000 = 129.0 → bucket 2.
	assert_int(int(slow[0]["intensity"])).is_equal(FunscriptIntensity.bucket(129.0))
	assert_int(int(slow[0]["intensity"])).is_equal(2)


# A hole wider than max_merge_gap_ms would be baked into the part (one window,
# no jump cuts), so merging must stop there even mid-target.
func test_merge_stops_at_large_hole() -> void:
	var beats: Array = [
		_beat(0, 20000, SPEED_I1),
		_beat(20200, 40200, SPEED_I1),
		_beat(300000, 320000, SPEED_I1),  # 260 s hole
	]
	var parts: Array = _expand_one(_video("hole", beats), 3)
	assert_int(parts.size()).is_equal(2)
	assert_int(int(_seg_of(parts[0])["out_ms"])).is_equal(40200)
	assert_int(int(_seg_of(parts[1])["in_ms"])).is_equal(300000)


# The hole check is `in_ms - out_ms > max_merge_gap_ms`, so a hole EXACTLY on the
# limit still merges and one millisecond more does not. Both beats are speed 50 and
# the target for an intensity-1 opener is ≥ 162 s, so nothing else can cut here.
func test_max_merge_gap_boundary() -> void:
	var cfg: Dictionary = {"max_merge_gap_ms": 5000}
	# 25000 - 20000 = 5000, not > 5000 → merged into one part.
	var exact: Array = [_beat(0, 20000, SPEED_I1), _beat(25000, 45000, SPEED_I1)]
	var merged: Array = _expand_one(_video("gapok", exact), 4, cfg)
	assert_int(merged.size()).is_equal(1)
	assert_int(int(merged[0]["length_ms"])).is_equal(45000)
	# 25001 - 20000 = 5001 → the merge stops at the hole.
	var over: Array = [_beat(0, 20000, SPEED_I1), _beat(25001, 45001, SPEED_I1)]
	var split: Array = _expand_one(_video("gapno", over), 4, cfg)
	assert_int(split.size()).is_equal(2)
	assert_int(int(_seg_of(split[0])["out_ms"])).is_equal(20000)


# The brake check is `absi(Δ) > intensity_tolerance`, so a step of exactly one level
# survives tolerance 1 and dies at tolerance 0. Same two beats, same seed — only the
# knob moves. (Running intensity at the decision is bucket(300) = 3, the candidate
# is bucket(420) = 4, so Δ is exactly 1.)
func test_intensity_tolerance_boundary() -> void:
	assert_int(FunscriptIntensity.bucket(SPEED_I3)).is_equal(3)
	assert_int(FunscriptIntensity.bucket(SPEED_I4)).is_equal(4)
	var beats: Array = [_beat(0, 20000, SPEED_I3), _beat(20200, 40200, SPEED_I4)]
	var lenient: Array = _expand_one(_video("tol1", beats), 13, {"intensity_tolerance": 1})
	assert_int(lenient.size()).is_equal(1)
	assert_int(int(lenient[0]["length_ms"])).is_equal(40200)
	var strict: Array = _expand_one(_video("tol0", beats), 13, {"intensity_tolerance": 0})
	assert_int(strict.size()).is_equal(2)
	assert_int(int(_seg_of(strict[0])["out_ms"])).is_equal(20000)


# A single beat longer than the slider maximum is emitted whole. Cutting inside a
# beat is forbidden, so overshooting the slider is the honest outcome.
func test_beat_longer_than_max_becomes_its_own_part() -> void:
	var parts: Array = _expand_one(_video("huge", [_beat(1000, 301000, SPEED_I5)]), 9)
	assert_int(parts.size()).is_equal(1)
	assert_int(int(parts[0]["length_ms"])).is_equal(300000)
	assert_int(int(parts[0]["length_ms"])).is_greater(MAX_MS)


# The max_ms CEILING, provably doing the cutting — the rolled target can't, because
# every part below comes out shorter than part_min_s.
#
# Range 35–40 s (min_ms 35000, max_ms 40000) over 10 s beats with 200 ms holes, so
# beat k spans [10200k, 10200k + 10000]. Starting at 0:
#   +b1 → 20200 - 0 = 20200 ≤ 40000  merge
#   +b2 → 30400 - 0 = 30400 ≤ 40000  merge
#   +b3 → 40600 - 0 = 40600 >  40000 BREAK  ← the ceiling, at span 30400
# The target for an intensity-3 opener is 37500 ± 0.15 × 5000 = [36750, 38250], i.e.
# always ABOVE the 30400 reached — `out_ms - in_ms >= target` is never true, so the
# only check that can have fired is the ceiling. Three beats per part repeats, and
# the tenth beat is left over as a short tail.
func test_max_ms_ceiling_cuts_before_the_target() -> void:
	var parts: Array = _expand_one(
		_video("cap", _beats(10, 10000, SPEED_I3)), 12, {"part_min_s": 35, "part_max_s": 40}
	)
	assert_int(parts.size()).is_equal(4)
	assert_int(int(parts[0]["length_ms"])).is_equal(30400)
	# Shorter than min_ms, hence shorter than any possible target: not a target cut.
	assert_int(int(parts[0]["length_ms"])).is_less(35000)
	assert_array(_tiling(parts)).is_equal(
		[[0, 30400], [30600, 61000], [61200, 91600], [91800, 101800]]
	)
	for p: Dictionary in parts:
		var length: int = int(p["length_ms"])
		if length > 10000:  # more than one beat merged → the ceiling applies
			assert_int(length).is_less_equal(40000)


# The leftover at the end of a video is shorter than the minimum. Single-pass
# tiling stays single-pass — no merging the rest back into its predecessor.
func test_last_part_may_be_shorter_than_min() -> void:
	var parts: Array = _expand_one(_video("tail", _beats(12, 8000, SPEED_I5)), 21)
	assert_int(parts.size()).is_equal(2)
	assert_int(int(parts[1]["length_ms"])).is_less(MIN_MS)


# ── Target length ────────────────────────────────────────────────────────────


func test_target_length_ms_biases_and_clamps() -> void:
	# Jitter off → the bare bias curve: 5 → min, 1 → max, 3 → midpoint.
	assert_int(RandomizerParts.target_length_ms(5, MIN_MS, MAX_MS, 0.0, _rng(1))).is_equal(MIN_MS)
	assert_int(RandomizerParts.target_length_ms(1, MIN_MS, MAX_MS, 0.0, _rng(1))).is_equal(MAX_MS)
	assert_int(RandomizerParts.target_length_ms(3, MIN_MS, MAX_MS, 0.0, _rng(1))).is_equal(120000)
	# With jitter the result never escapes the slider range, whatever the roll.
	var rng: RandomNumberGenerator = _rng(4711)
	for i: int in 200:
		var t: int = RandomizerParts.target_length_ms(1 + i % 5, MIN_MS, MAX_MS, 0.5, rng)
		assert_int(t).is_between(MIN_MS, MAX_MS)


# `coupling` scales the intensity→length pull around the range's mid-point (jitter off so the
# bare curve shows). MID_MS is the midpoint the neutral setting collapses to.
func test_target_length_ms_coupling() -> void:
	var mid: int = (MIN_MS + MAX_MS) / 2  # 120000
	# 0 → intensity ignored: every bucket lands on the mid of the range.
	for intensity: int in [1, 3, 5]:
		var flat: int = RandomizerParts.target_length_ms(
			intensity, MIN_MS, MAX_MS, 0.0, _rng(1), 0.0
		)
		assert_int(flat).is_equal(mid)
	# −1 → inverted: the endpoints swap, so a hard round aims LONG and a calm one short.
	assert_int(RandomizerParts.target_length_ms(5, MIN_MS, MAX_MS, 0.0, _rng(1), -1.0)).is_equal(
		MAX_MS
	)
	assert_int(RandomizerParts.target_length_ms(1, MIN_MS, MAX_MS, 0.0, _rng(1), -1.0)).is_equal(
		MIN_MS
	)
	# +0.5 → softened default: hard is shorter than mid but off the floor; calm longer, off the
	# ceiling. i5 → mid − ¼ span = 90000, i1 → mid + ¼ span = 150000.
	assert_int(RandomizerParts.target_length_ms(5, MIN_MS, MAX_MS, 0.0, _rng(1), 0.5)).is_equal(
		90000
	)
	assert_int(RandomizerParts.target_length_ms(1, MIN_MS, MAX_MS, 0.0, _rng(1), 0.5)).is_equal(
		150000
	)


# Exactly one draw per emitted part, and none at all for pass-through entries —
# that is what keeps the rng bookkeeping (and thus reproducibility) trivial.
func test_one_randf_per_part_and_none_for_whole_clips() -> void:
	var lib: Array = [
		_whole_clip("w1"),
		_video("p1", _beats(30, 8000, SPEED_I3)),
		_whole_clip("w2"),
		_video("p2", _beats(20, 8000, SPEED_I5)),
	]
	var rng: RandomNumberGenerator = _rng(31337)
	var out: Array = RandomizerParts.expand(lib, _cfg(), rng)
	var draws: int = 0
	for e: Dictionary in out:
		if not (e.get("segments", []) as Array).is_empty():
			draws += 1
	assert_int(draws).is_greater(0)
	var ref: RandomNumberGenerator = _rng(31337)
	for i: int in draws:
		ref.randf()
	assert_int(rng.randi()).is_equal(ref.randi())  # the sequences are still in lockstep


# ── Part ids ─────────────────────────────────────────────────────────────────


func test_make_part_id_format() -> void:
	var id: String = RandomizerParts.make_part_id(
		"7f3a1c9b2e4d5068", [{"in_ms": 120000, "out_ms": 198000}]
	)
	assert_str(id).is_equal("7f3a1c9b2e4d5068#trim:120000-198000")


func test_is_part_id_and_video_id_of_grammar() -> void:
	assert_bool(RandomizerParts.is_part_id("abc#trim:1-2")).is_true()
	assert_bool(RandomizerParts.is_part_id("abc")).is_false()
	assert_bool(RandomizerParts.is_part_id("")).is_false()
	assert_bool(RandomizerParts.is_part_id("#trim:1-2")).is_false()  # no video id in front
	assert_str(RandomizerParts.video_id_of("abc#trim:1-2")).is_equal("abc")
	assert_str(RandomizerParts.video_id_of("abc")).is_equal("abc")
	# Everything before the FIRST separator, so a stray "#" can't split it twice.
	assert_str(RandomizerParts.video_id_of("abc#trim:1-2#x")).is_equal("abc")


# The ids hang off the beat boundaries, not off the run — the same cut on the same
# source must yield the same id, because part_used is keyed by it.
func test_part_ids_are_stable_and_resolve_to_video() -> void:
	var beats: Array = _beats(30, 8000, SPEED_I3)
	var a: Array = _expand_one(_video("stab", beats), 808)
	var b: Array = _expand_one(_video("stab", beats), 808)
	for k: int in a.size():
		var id: String = str((a[k] as Dictionary)["id"])
		assert_str(id).is_equal(str((b[k] as Dictionary)["id"]))
		assert_bool(RandomizerParts.is_part_id(id)).is_true()
		assert_str(RandomizerParts.video_id_of(id)).is_equal("stab")
		var s: Dictionary = _seg_of(a[k])
		assert_str(id).is_equal("stab#trim:%d-%d" % [int(s["in_ms"]), int(s["out_ms"])])
	# Distinct cuts must never collide.
	var seen: Dictionary = {}
	for e: Dictionary in a:
		assert_bool(seen.has(str(e["id"]))).is_false()
		seen[str(e["id"])] = true


# Freshness runs on the part axis: the pseudo-entry's last_used is looked up in
# the VIDEO's part_used under the part id, never inherited from the video.
func test_last_used_comes_from_part_used() -> void:
	var beats: Array = _beats(30, 8000, SPEED_I3)
	var probe: Array = _expand_one(_video("fresh", beats), 606)
	var hot_id: String = str((probe[1] as Dictionary)["id"])
	var parts: Array = _expand_one(_video("fresh", beats, {hot_id: 999999}), 606)
	assert_int(int((parts[0] as Dictionary)["last_used"])).is_equal(0)
	assert_int(int((parts[1] as Dictionary)["last_used"])).is_equal(999999)


# ── Pseudo-entry shape ───────────────────────────────────────────────────────


# duration_ms is the field the generator's time budget prefers; if it kept the
# video's length the budget would be wrong by orders of magnitude.
func test_duration_equals_length_equals_part_span() -> void:
	var parts: Array = _expand_one(_video("dur", _beats(30, 8000, SPEED_I3)), 55)
	for p: Dictionary in parts:
		var s: Dictionary = _seg_of(p)
		var span: int = int(s["out_ms"]) - int(s["in_ms"])
		assert_int(int(p["length_ms"])).is_equal(span)
		assert_int(int(p["duration_ms"])).is_equal(span)
		assert_int(int(p["duration_ms"])).is_not_equal(1800000)  # not the video length


func test_pseudo_entry_carries_every_contract_field() -> void:
	var video: Dictionary = _video("shape", _beats(30, 8000, SPEED_I3))
	var parts: Array = _expand_one(video, 64)
	var p: Dictionary = parts[0]
	for key: String in [
		"id",
		"name",
		"video_src",
		"funscript_src",
		"axis_src",
		"vib_src",
		"needs_transcode",
		"video_rel",
		"funscript_rel",
		"axis_rel",
		"vib_rel",
		"boss_image_rel",
		"action_count",
		"length_ms",
		"duration_ms",
		"tags",
		"weight",
		"intensity",
		"last_used",
		"added_at",
		"segments",
		"source_id",
		"part_index",
		"part_count",
	]:
		assert_bool(p.has(key)).override_failure_message("missing field: " + key).is_true()
	# Inherited verbatim from the video.
	assert_str(str(p["video_src"])).is_equal(str(video["video_src"]))
	assert_str(str(p["boss_image_rel"])).is_equal(str(video["boss_image_rel"]))
	assert_float(float(p["weight"])).is_equal(2.5)
	assert_array(p["tags"]).is_equal(["fixture"])
	assert_int(int(p["added_at"])).is_equal(222)
	assert_bool(bool(p["needs_transcode"])).is_true()  # a cut always re-encodes
	assert_str(str(p["source_id"])).is_equal("shape")
	# Positional naming the screen shows verbatim.
	assert_str(str(p["name"])).is_equal("Clip shape · 1/%d" % parts.size())
	assert_int(int(p["part_index"])).is_equal(0)
	assert_int(int(p["part_count"])).is_equal(parts.size())
	assert_int((p["segments"] as Array).size()).is_equal(1)
	# A pseudo-entry has no sub-parts of its own.
	assert_bool(p.has("parts")).is_false()
	assert_bool(p.has("part_used")).is_false()
	# Copies, not aliases — the generator must not be able to write back.
	assert_bool(is_same(p["tags"], video["tags"])).is_false()
	assert_bool(is_same(p["axis_src"], video["axis_src"])).is_false()


# The screen shows "Part k/n" straight off these three fields, so they have to be
# positional for EVERY part, not just the first one: index counts up, count is the
# same n everywhere, and the name carries the 1-based pair.
func test_part_index_and_name_are_positional_for_every_part() -> void:
	var parts: Array = _expand_one(_video("pos", _beats(60, 8000, SPEED_I3)), 909)
	var n: int = parts.size()
	assert_int(n).is_greater(2)  # a genuinely multi-part video
	for idx: int in n:
		var p: Dictionary = parts[idx]
		assert_int(int(p["part_index"])).is_equal(idx)
		assert_int(int(p["part_count"])).is_equal(n)
		assert_str(str(p["name"])).is_equal("Clip pos · %d/%d" % [idx + 1, n])
		assert_bool(str(p["name"]).ends_with("%d/%d" % [idx + 1, n])).is_true()


func test_action_count_sums_the_merged_beats() -> void:
	# Two beats merged by a target far above their span. Each is 20 s at speed 50,
	# so _beat derives 50 × 20 / 100 = 10 actions; the part must carry the sum.
	var beats: Array = [_beat(0, 20000, SPEED_I1), _beat(20200, 40200, SPEED_I1)]
	assert_int(int((beats[0] as Dictionary)["action_count"])).is_equal(10)
	var parts: Array = _expand_one(_video("acts", beats), 8)
	assert_int(parts.size()).is_equal(1)
	assert_int(int(parts[0]["action_count"])).is_equal(20)


# ── Rel prediction ───────────────────────────────────────────────────────────


# The rels must carry the segments, or every part of one video would pool to the
# same file and overwrite each other. Extension is always mp4 (bake_edl's output).
func test_predict_part_rels_uses_segments_and_mp4() -> void:
	var video: Dictionary = _video("rels", [])
	var segs: Array = [{"in_ms": 1000, "out_ms": 5000}]
	var rels: Dictionary = RandomizerParts.predict_part_rels(video, segs)
	var src: String = str(video["video_src"])
	assert_str(str(rels["video_rel"])).is_equal(
		JourneyData.pooled_media_rel(JourneyData.media_fingerprint(src, segs), "mp4", src)
	)
	assert_bool(str(rels["video_rel"]).ends_with(".mp4")).is_true()
	assert_bool(str(rels["funscript_rel"]).ends_with(".funscript")).is_true()
	assert_bool((rels["axis_rel"] as Dictionary).has("twist")).is_true()
	assert_dict(rels["vib_rel"]).is_empty()
	# A different window is a different pooled file.
	var other: Dictionary = RandomizerParts.predict_part_rels(
		video, [{"in_ms": 1000, "out_ms": 6000}]
	)
	assert_str(str(other["video_rel"])).is_not_equal(str(rels["video_rel"]))
	# …and so is the whole clip.
	var whole: Dictionary = RandomizerParts.predict_part_rels(video, [])
	assert_str(str(whole["video_rel"])).is_not_equal(str(rels["video_rel"]))


func test_predict_part_rels_empty_sources_stay_empty() -> void:
	var bare: Dictionary = {"video_src": "", "funscript_src": "", "axis_src": {}, "vib_src": {}}
	var rels: Dictionary = RandomizerParts.predict_part_rels(bare, [{"in_ms": 0, "out_ms": 1000}])
	assert_str(str(rels["video_rel"])).is_equal("")
	assert_str(str(rels["funscript_rel"])).is_equal("")
	assert_dict(rels["axis_rel"]).is_empty()
	assert_dict(rels["vib_rel"]).is_empty()


# Each part of one video gets its own pooled rel — the dedup key includes the cut.
func test_parts_of_one_video_get_distinct_rels() -> void:
	var parts: Array = _expand_one(_video("pool", _beats(30, 8000, SPEED_I3)), 71)
	var seen: Dictionary = {}
	for p: Dictionary in parts:
		var rel: String = str(p["video_rel"])
		assert_bool(seen.has(rel)).is_false()
		seen[rel] = true


# ── Pass-through and opt-out ─────────────────────────────────────────────────


# No script → the entry is not just equivalent, it is the SAME object, still
# carrying parts/part_used and no segments key.
func test_entry_without_funscript_passes_through_unchanged() -> void:
	var whole: Dictionary = _whole_clip("plain")
	var out: Array = RandomizerParts.expand([whole], _cfg(), _rng(1))
	assert_int(out.size()).is_equal(1)
	assert_bool(is_same(out[0], whole)).is_true()
	assert_bool((out[0] as Dictionary).has("segments")).is_false()
	assert_bool((out[0] as Dictionary).has("part_used")).is_true()


# Fewer than two actions is the second "no usable script" case from the spec.
func test_entry_with_too_few_actions_passes_through() -> void:
	var thin: Dictionary = _video("thin", [])
	thin["action_count"] = 1
	var out: Array = RandomizerParts.expand([thin], _cfg(), _rng(1))
	assert_int(out.size()).is_equal(1)
	assert_bool(is_same(out[0], thin)).is_true()


# A script that WAS analysed and yielded nothing usable is a different state: the
# video contributes no candidates rather than falling back to the whole clip.
func test_entry_with_script_but_no_parts_yields_no_candidates() -> void:
	var out: Array = RandomizerParts.expand([_video("empty", [])], _cfg(), _rng(1))
	assert_array(out).is_empty()


# cut_parts off must reproduce today's behaviour exactly: same entries, same
# objects, no rng draws.
func test_cut_parts_off_returns_input() -> void:
	var lib: Array = [_video("a", _beats(30, 8000, SPEED_I3)), _whole_clip("b")]
	var rng: RandomNumberGenerator = _rng(2024)
	var out: Array = RandomizerParts.expand(lib, {}, rng)
	assert_int(out.size()).is_equal(2)
	assert_bool(is_same(out[0], lib[0])).is_true()
	assert_bool(is_same(out[1], lib[1])).is_true()
	assert_bool(is_same(out, lib)).is_false()  # a copy, so the caller's array is safe
	assert_int(rng.randi()).is_equal(_rng(2024).randi())  # untouched rng
	# Explicit false behaves the same as the default.
	assert_int(RandomizerParts.expand(lib, {"cut_parts": false}, _rng(1)).size()).is_equal(2)


# The slider range is honoured through the settings dict the screen hands over —
# and a nonsensical range is clamped rather than crashing the tiling.
func test_custom_range_and_degenerate_range() -> void:
	var beats: Array = _beats(60, 4000, SPEED_I3)
	var short: Array = _expand_one(_video("rng", beats), 12, {"part_min_s": 20, "part_max_s": 40})
	for p: Dictionary in short:
		assert_int(int(p["length_ms"])).is_less_equal(40000 + 4200)  # cap + one beat's grain
	assert_int(short.size()).is_greater(4)
	# min == max → expand widens max to min + 1 s instead of dividing by zero.
	var flat: Array = _expand_one(_video("rng", beats), 12, {"part_min_s": 30, "part_max_s": 30})
	assert_array(flat).is_not_empty()


# The generator is handed one settings dict for both layers; its keys must be
# harmless here (and vice versa).
func test_generator_settings_keys_are_harmless() -> void:
	var settings: Dictionary = {
		"cut_parts": true,
		"seed": 42,
		"length_mode": "time",
		"target_minutes": 20.0,
		"round_count": 10,
	}
	var out: Array = RandomizerParts.expand(
		[_video("mix", _beats(30, 8000, SPEED_I3))], settings, _rng(42)
	)
	assert_array(out).is_not_empty()
