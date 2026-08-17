class_name HandyPoints
extends RefCounted

# Pure HSP point math for HandyService — funscript actions → Handy Streaming
# Protocol points, and the lookahead-window batching that streams them into the
# device buffer. Kept a `class_name` (not on the HandyService autoload) so it's
# statically resolvable and unit-testable without standing up the singleton —
# the same split the project uses for DeviceRouting / ForkResolver / JourneyAudit.

const MAX_POINTS_PER_ADD: int = 100  # HSP hard cap per /hsp/add


# Vector2(at_ms, pos) → [{t:int ms, x:int 0-100}], clamped and int-coerced.
# `actions` is the time-sorted shape JourneyData.read_funscript_actions returns.
static func actions_to_points(actions: Array) -> Array:
	var out: Array = []
	for a: Vector2 in actions:
		out.append({"t": maxi(0, roundi(a.x)), "x": clampi(roundi(a.y), 0, 100)})
	return out


# First index whose point time is ≥ `t` (points are time-sorted), or points.size() when every
# point is before t. Binary search. Used to seed a play/seek window at the CURRENT position:
# start_time is video_ms, so the batch must begin at video_ms too — sending from index 0 hands
# the device the OPENING seconds of the script while it plays from the middle, so it starves and
# the per-second feed has to grind forward for seconds before anything lands.
static func index_at_or_after(points: Array, t: int) -> int:
	var lo: int = 0
	var hi: int = points.size()
	while lo < hi:
		var mid: int = (lo + hi) / 2
		if int((points[mid] as Dictionary)["t"]) < t:
			lo = mid + 1
		else:
			hi = mid
	return lo


# The next batch to stream: points from `from_idx` whose t ≤ until_t, capped at
# MAX_POINTS_PER_ADD. Returns {batch, next_idx} — next_idx is the cursor to
# resume from (and doubles as the HSP tail-point stream index).
static func points_in_window(points: Array, from_idx: int, until_t: int) -> Dictionary:
	var batch: Array = []
	var i: int = from_idx
	while i < points.size() and int((points[i] as Dictionary)["t"]) <= until_t:
		batch.append(points[i])
		i += 1
		if batch.size() >= MAX_POINTS_PER_ADD:
			break
	return {"batch": batch, "next_idx": i}


# Interpolated position (0-100) at time `t` across a time-sorted point stream; clamped to the ends.
# Used to read where the device currently is so a replacing override can ease in from there.
static func sample_pos(points: Array, t: int) -> int:
	if points.is_empty():
		return 50
	if t <= int((points[0] as Dictionary)["t"]):
		return int((points[0] as Dictionary)["x"])
	var last: Dictionary = points[points.size() - 1]
	if t >= int(last["t"]):
		return int(last["x"])
	var i: int = index_at_or_after(points, t)  # first point at/after t → bracket is [i-1, i]
	var a: Dictionary = points[i - 1]
	var b: Dictionary = points[i]
	var ta: int = int(a["t"])
	var tb: int = int(b["t"])
	if tb <= ta:
		return int(b["x"])
	var f: float = float(t - ta) / float(tb - ta)
	return clampi(roundi(lerpf(float(a["x"]), float(b["x"]), f)), 0, 100)


# Prepends a bridge point at `from_pos` (where the device currently is) and shifts the stream back by
# `bridge_ms`, so the device eases from its current position into the script over that window instead of
# snapping to the script's first point — the jerk when one override flush-replaces another (or a round).
static func bridge_from(points: Array, from_pos: int, bridge_ms: int) -> Array:
	if points.is_empty() or bridge_ms <= 0 or from_pos < 0:
		return points
	var out: Array = [{"t": 0, "x": clampi(from_pos, 0, 100)}]
	for p: Variant in points:
		out.append({"t": int((p as Dictionary)["t"]) + bridge_ms, "x": int((p as Dictionary)["x"])})
	return out


# Applies the active stroke effects to a point stream so the Handy plays the
# MODIFIED script (items / curses / boss modifiers reach the device). `effects`
# is InventoryService.GetActiveEffects()'s shape — [{kind, factor?/min?/max?}];
# non-stroke kinds are ignored. Timestamps are untouched (only x changes), so
# the streamed points stay aligned to the video clock.
#
# IMPORTANT: the mirror→scale→clamp order + formulas MUST stay in lockstep with
# FunscriptPlayer.TransformPos (C#, the runtime source of truth) and its
# GDScript twin FunscriptPreview._transform_pos_at. Change one → change all.
# `block` = the device ignores the script: a flat hold line at `hold_pos`.
static func apply_effects(points: Array, effects: Array, hold_pos: int = 50) -> Array:
	if points.is_empty():
		return []
	if _has_kind(effects, "block"):
		var held: Array = []
		for p: Dictionary in points:
			held.append({"t": int(p["t"]), "x": clampi(hold_pos, 0, 100)})
		return held

	# Precompute the composed scale factor + mirror parity once (they're global).
	var mirrored: bool = _count_kind(effects, "reverse") % 2 == 1
	var scale_factor: float = 1.0
	for e: Dictionary in effects:
		if str(e.get("kind", "")) == "scale" and e.has("factor"):
			scale_factor *= float(e["factor"])

	var out: Array = []
	for i: int in points.size():
		var pos: float = _mirror(float((points[i] as Dictionary)["x"]), mirrored)
		# Scale around each stroke's local centre (neighbour midpoint).
		if not is_equal_approx(scale_factor, 1.0):
			var prev: float = _mirror(float((points[maxi(0, i - 1)] as Dictionary)["x"]), mirrored)
			var nxt: float = _mirror(
				float((points[mini(points.size() - 1, i + 1)] as Dictionary)["x"]), mirrored
			)
			var center: float = (prev + nxt) * 0.5
			pos = center + (pos - center) * scale_factor
		# Clamp into a sub-range (stacks successively).
		for e: Dictionary in effects:
			if str(e.get("kind", "")) == "clamp":
				var mn: float = float(e.get("min", 0))
				var mx: float = float(e.get("max", 100))
				pos = mn + clampf(pos, 0.0, 100.0) / 100.0 * (mx - mn)
		out.append({"t": int((points[i] as Dictionary)["t"]), "x": clampi(roundi(pos), 0, 100)})
	return out


static func _mirror(v: float, mirrored: bool) -> float:
	return 100.0 - v if mirrored else v


# Shifts every timestamp by `offset_ms` — how the Handy delay is expressed. A point at t now
# plays `offset` ms later relative to the video, so POSITIVE = more delay.
#
# NOT on /hsp/play's start_time, which is what 0.6.0 did: that anchor was `maxi(0, video_ms -
# delay)` and start_time can't go negative, so at a round start (where video_ms is small) the
# clamp silently ate the delay. A timestamp shift has no such floor.
#
# A negative offset moves points earlier; any landing before 0 are dropped — already past, and
# t < 0 isn't a legal HSP timestamp. Costs at most |offset| ms (≤2s) off the front.
static func offset_points(points: Array, offset_ms: int) -> Array:
	if offset_ms == 0:
		return points
	var out: Array = []
	for p: Dictionary in points:
		var t: int = int(p["t"]) + offset_ms
		if t >= 0:
			out.append({"t": t, "x": int(p["x"])})
	return out


# Estimates the client→server clock offset from a set of /servertime samples
# (each {sent, recv, server_time}, all ms). Keeps the lowest-round-trip sample
# (least queueing noise) and assumes the server stamped at the round-trip
# midpoint. Returns `offset` such that server_time_now ≈ local_now + offset —
# used to fill /hsp/play's server_time so the device can compensate transit lag.
static func best_offset_from_samples(samples: Array) -> int:
	var best_rtt: int = 1 << 62
	var best_offset: int = 0
	for s: Dictionary in samples:
		var rtt: int = int(s["recv"]) - int(s["sent"])
		if rtt < best_rtt:
			best_rtt = rtt
			best_offset = int(s["server_time"]) + rtt / 2 - int(s["recv"])
	return best_offset


static func _has_kind(effects: Array, kind: String) -> bool:
	for e: Dictionary in effects:
		if str(e.get("kind", "")) == kind:
			return true
	return false


static func _count_kind(effects: Array, kind: String) -> int:
	var n: int = 0
	for e: Dictionary in effects:
		if str(e.get("kind", "")) == kind:
			n += 1
	return n
