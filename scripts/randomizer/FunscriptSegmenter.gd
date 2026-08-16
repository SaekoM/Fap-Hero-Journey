class_name FunscriptSegmenter
extends RefCounted
## Cuts a funscript's action list into BEATS — the smallest self-contained units a
## randomizer round can be built from. Pure and disk-free like FunscriptIntensity,
## whose average_speed()/bucket() produce every number reported here; the project
## deliberately has only one rating scale.
##
## The structure comes from the script itself, not from the video: scripters stop
## at scene changes and mark passages by changing tempo. Three passes exploit that —
## pauses, then tempo changes inside anything still too long, then a cleanup that
## folds fragments into the neighbour they resemble and drops what is too short or
## too lifeless to be worth playing.
##
## Every boundary lands on a real action timestamp. A round that starts mid-stroke
## is worthless, so this rule has no exception — not even for the even division that
## breaks up a metronome.
##
## Output per beat: {in_ms, out_ms, speed, intensity, action_count}, sorted by in_ms.
## out_ms is INCLUSIVE and no action belongs to two beats, so consecutive beats
## satisfy out_ms < next.in_ms. Beats do NOT tile the video: pauses and discarded
## dead passages stay as holes between them, which is why any length arithmetic
## downstream must use the beat span and never the video duration.

# A gap longer than this is a hard boundary. Shorter ones are part of the rhythm.
const GAP_THRESHOLD_MS: int = 1500

# Below ~8 s nothing works as a unit of its own, so it gets merged or dropped.
const MIN_BEAT_MS: int = 8000

# Above this a block is re-cut on tempo. One minute is already a long round.
const MAX_BEAT_MS: int = 60000

# Sliding window for the local stroke speed — wide enough to smooth single
# outliers, narrow enough that a section change still shows up as one.
const TEMPO_WINDOW_MS: int = 5000

# Relative change (0..1) a window pair must exceed to count as a section boundary.
const TEMPO_MIN_DELTA: float = 0.25

# Positions/s below which a passage is practically dead and not worth a round.
const MIN_SPEED: float = 40.0

const DEFAULT_CFG: Dictionary = {
	"gap_threshold_ms": GAP_THRESHOLD_MS,
	"min_beat_ms": MIN_BEAT_MS,
	"max_beat_ms": MAX_BEAT_MS,
	"tempo_window_ms": TEMPO_WINDOW_MS,
	"tempo_min_delta": TEMPO_MIN_DELTA,
	"min_speed": MIN_SPEED,
}


## Read-only, flattened view of the normalized action list, built once per segment()
## call. It exists purely for speed: the passes below ask the same two questions over
## and over — "how fast is this index range?" and "what is the tempo score at this
## action?" — and answering them by slicing the action array was quadratic on scripts
## that keep changing tempo without ever pausing (the tempo pass rescans its whole
## block on every recursion level, and every candidate paid for two Array.slice()
## allocations plus two summation loops).
##
## The dictionaries are gone; what survives is what the passes read.
class _Prep:
	extends RefCounted

	# Timestamps, STRICTLY ascending — _normalized() collapsed the duplicates, which
	# is what lets every "first/last index at time t" question be a bsearch and every
	# window boundary be monotone in the index.
	var at: PackedInt64Array

	# travel[i] = sum of |pos delta| over acts[0..i], i.e. FunscriptIntensity's `dist`
	# accumulated from the very first action instead of from a slice's first action.
	var travel: PackedFloat64Array

	# win_lo[i] / win_hi[i] — the ±tempo_window_ms window around action i, expressed
	# as indices and NOT clamped to any block. See _tempo_blocks() for why the block
	# clamp can be applied later instead of baked in here.
	var win_lo: PackedInt32Array
	var win_hi: PackedInt32Array

	# delta[i] — the tempo score of a cut at action i using the unclamped windows.
	var delta: PackedFloat64Array

	func _init(acts: Array, win_ms: int) -> void:
		var n: int = acts.size()
		at.resize(n)
		travel.resize(n)
		win_lo.resize(n)
		win_hi.resize(n)
		delta.resize(n)

		var prev: float = 0.0
		var sum: float = 0.0
		for i in n:
			var a: Dictionary = acts[i]
			at[i] = int(a.get("at", 0))
			var pos: float = float(a.get("pos", 0))
			if i > 0:
				sum += absf(pos - prev)
			travel[i] = sum
			prev = pos

		# Both window edges move monotonically with i, so one pass with two trailing
		# pointers replaces the per-candidate linear walk the old _window_before() /
		# _window_after() did. The `lo < i` / `hi >= i` clamps reproduce those walks'
		# own guards, which never let a window drop its centre action.
		var lo: int = 0
		var hi: int = 0
		for i in n:
			var lo_at: int = at[i] - win_ms
			while lo < i and at[lo] < lo_at:
				lo += 1
			win_lo[i] = lo
			var hi_at: int = at[i] + win_ms
			if hi < i:
				hi = i
			while hi + 1 < n and at[hi + 1] <= hi_at:
				hi += 1
			win_hi[i] = hi

		for i in n:
			delta[i] = score(win_lo[i], i, win_hi[i])

	# FunscriptIntensity.average_speed() of the actions at[a..b], inclusive, without
	# materialising them. Same terms in the same order (the prefix difference cancels
	# everything before a), same division, and the same two zero cases: fewer than two
	# actions, or a non-positive span. Positions are integers in practice, so the
	# partial sums are exact and the subtraction is exact too.
	func speed(a: int, b: int) -> float:
		if b <= a:
			return 0.0
		var span_ms: float = float(at[b] - at[a])
		if span_ms <= 0.0:
			return 0.0
		return (travel[b] - travel[a]) / (span_ms / 1000.0)

	# Tempo score of a cut at action m whose windows reach to `lo` and `hi`.
	# Relative to the faster side; the floor of 1.0 keeps a near-silent pair from
	# turning a rounding difference into a 100 % change.
	func score(lo: int, m: int, hi: int) -> float:
		var left: float = speed(lo, m)
		var right: float = speed(m, hi)
		return absf(right - left) / maxf(1.0, maxf(left, right))


# Segments a raw funscript action list [{at:ms, pos:0-100}, …] into beats.
# Returns [] for anything unusable (empty, one action, all too short, all too slow).
static func segment(actions: Array, cfg: Dictionary = {}) -> Array:
	var c: Dictionary = DEFAULT_CFG.duplicate(true)
	c.merge(cfg, true)
	# Coerced explicitly: cfg may come from JSON, where every number is a float.
	var gap_ms: int = int(c["gap_threshold_ms"])
	var min_ms: int = int(c["min_beat_ms"])
	var max_ms: int = int(c["max_beat_ms"])
	var win_ms: int = int(c["tempo_window_ms"])
	var delta_min: float = float(c["tempo_min_delta"])
	var min_speed: float = float(c["min_speed"])

	var acts: Array = _normalized(actions)
	if acts.size() < 2:
		return []
	var prep := _Prep.new(acts, win_ms)

	# Blocks are index ranges [x, y] into the action list, inclusive on both ends.
	# Until the final filter they always tile the whole list, which is what makes
	# merging two neighbours a plain union of adjacent ranges.
	var blocks: Array = []
	for gap_block: Vector2i in _gap_blocks(prep, gap_ms):
		blocks.append_array(_tempo_blocks(prep, gap_block, min_ms, max_ms, win_ms, delta_min))

	var beats: Array = []
	for blk: Vector2i in _merge_fragments(prep, blocks, min_ms):
		var in_ms: int = prep.at[blk.x]
		var out_ms: int = prep.at[blk.y]
		# Still too short after merging (no neighbour, or the neighbours were used up).
		if blk.y - blk.x < 1 or out_ms - in_ms < min_ms:
			continue
		var speed: float = prep.speed(blk.x, blk.y)
		if speed < min_speed:
			continue
		var beat: Dictionary = {
			"in_ms": in_ms,
			"out_ms": out_ms,
			"speed": speed,
			"intensity": FunscriptIntensity.bucket(speed),
			"action_count": blk.y - blk.x + 1,
		}
		beats.append(beat)
	return beats


# Drops non-dictionaries, returns the actions in ascending time and collapses
# duplicate timestamps. The caller's array is never touched — the registry hands
# over its parsed funscript and reuses it.
static func _normalized(actions: Array) -> Array:
	# Decorated with the input index because sort_custom is not stable: two actions
	# sharing a timestamp must keep the order the file gave them.
	var deco: Array = []
	for i in actions.size():
		if actions[i] is Dictionary:
			deco.append([int((actions[i] as Dictionary).get("at", 0)), i, actions[i]])
	var by_time := func(x: Array, y: Array) -> bool:
		if int(x[0]) != int(y[0]):
			return int(x[0]) < int(y[0])
		return int(x[1]) < int(y[1])
	deco.sort_custom(by_time)
	var out: Array = []
	for i in deco.size():
		var d: Array = deco[i]
		# One millisecond, one action — a later twin overrides an earlier one, the way a
		# player walking the list would end up on the last value. Kept apart, a cut
		# landing between two twins would give the left beat the same out_ms as the
		# right beat's in_ms and hand one timestamp to two parts (§1).
		if i + 1 < deco.size() and int((deco[i + 1] as Array)[0]) == int(d[0]):
			continue
		out.append(d[2])
	return out


# Step 1 — a pause longer than the threshold ends a block. Strictly longer: a gap of
# exactly gap_ms is still rhythm.
static func _gap_blocks(prep: _Prep, gap_ms: int) -> Array:
	var at: PackedInt64Array = prep.at
	var out: Array = []
	var start: int = 0
	for i in range(1, at.size()):
		if at[i] - at[i - 1] > gap_ms:
			out.append(Vector2i(start, i - 1))
			start = i
	out.append(Vector2i(start, at.size() - 1))
	return out


# Step 2 — recursively splits a block that is still longer than max_ms at its
# sharpest tempo change: the action where the average speed of the window before it
# differs most from the window after it. Both halves must stay usable, so a change
# too close to an edge is not a candidate. Each split moves at least one action to
# either side, which is what terminates the recursion.
#
# The naive form scored every candidate from scratch on every recursion level, which
# is quadratic when the sharpest change sits near a block start (the big remainder is
# rescanned in full, over and over). Two observations make the rescan cheap without
# changing which action wins:
#
#  1. A candidate's score depends ONLY on its two windows — never on the block — as
#     long as neither window is clamped by a block edge. Those scores are therefore
#     the same on every recursion level and are precomputed once, in prep.delta.
#  2. Clamping happens exactly to the candidates within win_ms of an edge, and "within
#     win_ms of an edge" is monotone in at[m]. So the clamped candidates form a prefix
#     and a suffix of the candidate range; only those are rescored here, and they are
#     rescored with the identical expression, so an over-wide zone would still give
#     the identical number.
#
# The three sub-scans below therefore visit the same candidates, in the same ascending
# order, with the same values as the single loop they replace — and keep the same
# `strictly greater` comparison, so a tie still keeps the earliest action.
static func _tempo_blocks(
	prep: _Prep, blk: Vector2i, min_ms: int, max_ms: int, win_ms: int, delta_min: float
) -> Array:
	var at: PackedInt64Array = prep.at
	var in_ms: int = at[blk.x]
	var out_ms: int = at[blk.y]
	if out_ms - in_ms <= max_ms:
		return [blk]

	# Candidate range. From blk.x + 1: the cut hands action m to the right half, so at
	# least one action has to stay on the left. The two min_ms edge exclusions are
	# monotone in at[m], hence a binary search each instead of a skipping scan.
	var first: int = maxi(blk.x + 1, at.bsearch(in_ms + min_ms, true))
	var last: int = mini(blk.y, at.bsearch(out_ms - min_ms, false) - 1)

	var best: int = -1
	var best_delta: float = -1.0
	if first <= last:
		# Last candidate whose backward window still reaches past blk.x, i.e. the last
		# one with at[m] <= at[blk.x - 1] + win_ms. At the list head nothing is clamped.
		var edge_l: int = blk.x - 1
		if blk.x > 0:
			edge_l = mini(last, at.bsearch(at[blk.x - 1] + win_ms, false) - 1)
		# Mirror image: first candidate whose forward window reaches past blk.y.
		var edge_r: int = blk.y + 1
		if blk.y + 1 < at.size():
			edge_r = maxi(first, at.bsearch(at[blk.y + 1] - win_ms, true))

		for m in range(first, mini(edge_l, last) + 1):
			var d: float = prep.score(maxi(blk.x, prep.win_lo[m]), m, mini(blk.y, prep.win_hi[m]))
			if d > best_delta:
				best_delta = d
				best = m
		var deltas: PackedFloat64Array = prep.delta
		for m in range(maxi(first, edge_l + 1), mini(last, edge_r - 1) + 1):
			var d: float = deltas[m]
			if d > best_delta:
				best_delta = d
				best = m
		for m in range(maxi(first, edge_r), last + 1):
			var d: float = prep.score(maxi(blk.x, prep.win_lo[m]), m, mini(blk.y, prep.win_hi[m]))
			if d > best_delta:
				best_delta = d
				best = m

	if best < 0 or best_delta <= delta_min:
		return _even_blocks(prep, blk, max_ms)
	return (
		_tempo_blocks(prep, Vector2i(blk.x, best - 1), min_ms, max_ms, win_ms, delta_min)
		+ _tempo_blocks(prep, Vector2i(best, blk.y), min_ms, max_ms, win_ms, delta_min)
	)


# Fallback for a block with no tempo change worth cutting on — a metronome must not
# survive as one huge beat. Divides the span into equal pieces and snaps each ideal
# cut onto the nearest action; snaps that collide or would leave an empty block are
# dropped. No recursion: a piece that stays too long has already refused to be cut.
static func _even_blocks(prep: _Prep, blk: Vector2i, max_ms: int) -> Array:
	var in_ms: int = prep.at[blk.x]
	var span: int = prep.at[blk.y] - in_ms
	var pieces: int = maxi(1, ceili(float(span) / float(maxi(1, max_ms))))
	var out: Array = []
	var start: int = blk.x
	for p in range(1, pieces):
		var ideal: int = in_ms + roundi(float(span) * float(p) / float(pieces))
		var m: int = _nearest_action(prep, blk, ideal)
		if m <= start:
			continue
		out.append(Vector2i(start, m - 1))
		start = m
	out.append(Vector2i(start, blk.y))
	return out


# Step 3.1 — folds every block shorter than min_ms into the neighbour whose speed is
# closest to its own, lowest index first, until nothing short is left to merge. The
# order matters: merging changes the speed of the survivor and therefore what the
# next fragment finds attractive.
static func _merge_fragments(prep: _Prep, blocks: Array, min_ms: int) -> Array:
	var at: PackedInt64Array = prep.at
	var out: Array = blocks.duplicate()
	while out.size() > 1:
		var k: int = -1
		for i in out.size():
			var b: Vector2i = out[i]
			if at[b.y] - at[b.x] < min_ms:
				k = i
				break
		if k < 0:
			break
		var cur: Vector2i = out[k]
		if _prefers_previous(prep, out, k):
			var prev: Vector2i = out[k - 1]
			out[k - 1] = Vector2i(prev.x, cur.y)
			out.remove_at(k)
		else:
			var nxt: Vector2i = out[k + 1]
			out[k] = Vector2i(cur.x, nxt.y)
			out.remove_at(k + 1)
	return out


static func _prefers_previous(prep: _Prep, blocks: Array, k: int) -> bool:
	if k == 0:
		return false
	if k == blocks.size() - 1:
		return true
	var mine: float = _speed_of(prep, blocks[k])
	var to_prev: float = absf(mine - _speed_of(prep, blocks[k - 1]))
	var to_next: float = absf(mine - _speed_of(prep, blocks[k + 1]))
	return to_prev <= to_next  # tie → the previous block


static func _speed_of(prep: _Prep, blk: Vector2i) -> float:
	return prep.speed(blk.x, blk.y)


# Index of the block's action closest to t_ms; on a tie the earlier one, so the
# result never depends on scan direction.
static func _nearest_action(prep: _Prep, blk: Vector2i, t_ms: int) -> int:
	var at: PackedInt64Array = prep.at
	var lo: int = blk.x
	var hi: int = blk.y
	while lo < hi:
		var mid: int = (lo + hi) / 2
		if at[mid] < t_ms:
			lo = mid + 1
		else:
			hi = mid
	if lo > blk.x and t_ms - at[lo - 1] <= at[lo] - t_ms:
		return lo - 1
	return lo
