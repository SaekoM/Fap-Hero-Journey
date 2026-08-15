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

	# Blocks are index ranges [x, y] into `acts`, inclusive on both ends. Until the
	# final filter they always tile the whole list, which is what makes merging two
	# neighbours a plain union of adjacent ranges.
	var blocks: Array = []
	for gap_block: Vector2i in _gap_blocks(acts, gap_ms):
		blocks.append_array(_tempo_blocks(acts, gap_block, min_ms, max_ms, win_ms, delta_min))

	var beats: Array = []
	for blk: Vector2i in _merge_fragments(acts, blocks, min_ms):
		var in_ms: int = _at(acts, blk.x)
		var out_ms: int = _at(acts, blk.y)
		# Still too short after merging (no neighbour, or the neighbours were used up).
		if blk.y - blk.x < 1 or out_ms - in_ms < min_ms:
			continue
		var slice: Array = acts.slice(blk.x, blk.y + 1)
		var speed: float = FunscriptIntensity.average_speed(slice)
		if speed < min_speed:
			continue
		var beat: Dictionary = {
			"in_ms": in_ms,
			"out_ms": out_ms,
			"speed": speed,
			"intensity": FunscriptIntensity.bucket(speed),
			"action_count": slice.size(),
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
static func _gap_blocks(acts: Array, gap_ms: int) -> Array:
	var out: Array = []
	var start: int = 0
	for i in range(1, acts.size()):
		if _at(acts, i) - _at(acts, i - 1) > gap_ms:
			out.append(Vector2i(start, i - 1))
			start = i
	out.append(Vector2i(start, acts.size() - 1))
	return out


# Step 2 — recursively splits a block that is still longer than max_ms at its
# sharpest tempo change: the action where the average speed of the window before it
# differs most from the window after it. Both halves must stay usable, so a change
# too close to an edge is not a candidate. Each split moves at least one action to
# either side, which is what terminates the recursion.
static func _tempo_blocks(
	acts: Array, blk: Vector2i, min_ms: int, max_ms: int, win_ms: int, delta_min: float
) -> Array:
	var in_ms: int = _at(acts, blk.x)
	var out_ms: int = _at(acts, blk.y)
	if out_ms - in_ms <= max_ms:
		return [blk]

	var best: int = -1
	var best_delta: float = -1.0
	# From blk.x + 1: the cut hands action m to the right half, so at least one action
	# has to stay on the left.
	for m in range(blk.x + 1, blk.y + 1):
		var at: int = _at(acts, m)
		if at - in_ms < min_ms or out_ms - at < min_ms:
			continue
		var left: float = FunscriptIntensity.average_speed(_window_before(acts, blk, m, win_ms))
		var right: float = FunscriptIntensity.average_speed(_window_after(acts, blk, m, win_ms))
		# Relative to the faster side; the floor of 1.0 keeps a near-silent pair from
		# turning a rounding difference into a 100 % change.
		var delta: float = absf(right - left) / maxf(1.0, maxf(left, right))
		if delta > best_delta:  # strictly greater → a tie keeps the earlier action
			best_delta = delta
			best = m

	if best < 0 or best_delta <= delta_min:
		return _even_blocks(acts, blk, max_ms)
	return (
		_tempo_blocks(acts, Vector2i(blk.x, best - 1), min_ms, max_ms, win_ms, delta_min)
		+ _tempo_blocks(acts, Vector2i(best, blk.y), min_ms, max_ms, win_ms, delta_min)
	)


# Fallback for a block with no tempo change worth cutting on — a metronome must not
# survive as one huge beat. Divides the span into equal pieces and snaps each ideal
# cut onto the nearest action; snaps that collide or would leave an empty block are
# dropped. No recursion: a piece that stays too long has already refused to be cut.
static func _even_blocks(acts: Array, blk: Vector2i, max_ms: int) -> Array:
	var in_ms: int = _at(acts, blk.x)
	var span: int = _at(acts, blk.y) - in_ms
	var pieces: int = maxi(1, ceili(float(span) / float(maxi(1, max_ms))))
	var out: Array = []
	var start: int = blk.x
	for p in range(1, pieces):
		var ideal: int = in_ms + roundi(float(span) * float(p) / float(pieces))
		var m: int = _nearest_action(acts, blk, ideal)
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
static func _merge_fragments(acts: Array, blocks: Array, min_ms: int) -> Array:
	var out: Array = blocks.duplicate()
	while out.size() > 1:
		var k: int = -1
		for i in out.size():
			var b: Vector2i = out[i]
			if _at(acts, b.y) - _at(acts, b.x) < min_ms:
				k = i
				break
		if k < 0:
			break
		var cur: Vector2i = out[k]
		if _prefers_previous(acts, out, k):
			var prev: Vector2i = out[k - 1]
			out[k - 1] = Vector2i(prev.x, cur.y)
			out.remove_at(k)
		else:
			var nxt: Vector2i = out[k + 1]
			out[k] = Vector2i(cur.x, nxt.y)
			out.remove_at(k + 1)
	return out


static func _prefers_previous(acts: Array, blocks: Array, k: int) -> bool:
	if k == 0:
		return false
	if k == blocks.size() - 1:
		return true
	var mine: float = _speed_of(acts, blocks[k])
	var to_prev: float = absf(mine - _speed_of(acts, blocks[k - 1]))
	var to_next: float = absf(mine - _speed_of(acts, blocks[k + 1]))
	return to_prev <= to_next  # tie → the previous block


static func _speed_of(acts: Array, blk: Vector2i) -> float:
	return FunscriptIntensity.average_speed(acts.slice(blk.x, blk.y + 1))


# The block's actions in [at(m) - win_ms, at(m)] resp. [at(m), at(m) + win_ms].
# Both include action m, so a window pair shares exactly the split point.
static func _window_before(acts: Array, blk: Vector2i, m: int, win_ms: int) -> Array:
	var lo: int = _at(acts, m) - win_ms
	var i: int = m
	while i > blk.x and _at(acts, i - 1) >= lo:
		i -= 1
	return acts.slice(i, m + 1)


static func _window_after(acts: Array, blk: Vector2i, m: int, win_ms: int) -> Array:
	var hi: int = _at(acts, m) + win_ms
	var i: int = m
	while i < blk.y and _at(acts, i + 1) <= hi:
		i += 1
	return acts.slice(m, i + 1)


# Index of the block's action closest to t_ms; on a tie the earlier one, so the
# result never depends on scan direction.
static func _nearest_action(acts: Array, blk: Vector2i, t_ms: int) -> int:
	var lo: int = blk.x
	var hi: int = blk.y
	while lo < hi:
		var mid: int = (lo + hi) / 2
		if _at(acts, mid) < t_ms:
			lo = mid + 1
		else:
			hi = mid
	if lo > blk.x and t_ms - _at(acts, lo - 1) <= _at(acts, lo) - t_ms:
		return lo - 1
	return lo


static func _at(acts: Array, i: int) -> int:
	return int((acts[i] as Dictionary).get("at", 0))
