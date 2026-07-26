class_name ForkResolver
extends RefCounted

# Pure fork path-picking logic, extracted from GameLoop / ForkScreen so it can be
# tested in isolation. Every function here is deterministic: external state
# (score, coins, item ownership, the random draw) is passed in by the caller, not
# read from autoloads or RNG. The callers stay thin glue.
#
#   Random      → weighted_pick(weights, r)         (caller supplies r = randi() % total)
#   Conditional → conditional_path(...)             (caller supplies score/coins value + is_owned)
#   Sacrifice   → path_affordable(...)              (caller supplies coins + is_owned)
#   Player Choice → no logic here; the index is whatever the player clicks.


# Picks the index whose cumulative-weight bracket contains r. `weights` are the
# per-path weights (negatives clamped to 0); r must be in [0, sum(weights)). The
# caller computes r from the RNG, keeping this deterministic. Empty → 0.
static func weighted_pick(weights: Array, r: int) -> int:
	if weights.is_empty():
		return 0
	var acc: int = 0
	for i in weights.size():
		acc += maxi(0, int(weights[i]))
		if r < acc:
			return i
	return weights.size() - 1


# Resolves a conditional fork to a path index.
#   metric "item"          → first path whose required_item is owned (is_owned), else default.
#   metric "score"/"coins" → highest threshold `value` meets wins (ties → earliest), else default.
# `value` is the score or coin balance (caller picks which by metric). `is_owned`
# is a Callable(String) -> bool. `default_path` is clamped into range.
static func conditional_path(
	paths: Array, metric: String, default_path: int, value: int, is_owned: Callable
) -> int:
	if paths.is_empty():
		return 0
	var default_idx: int = clampi(default_path, 0, paths.size() - 1)

	if metric == "item":
		for i in paths.size():
			var req: String = str(paths[i].get("required_item", ""))
			if req != "" and is_owned.call(req):
				return i
		return default_idx

	# Flag: first path whose required_flag is currently set wins (is_owned is the flag-checker here).
	if metric == "flag":
		for i in paths.size():
			var rf: String = str(paths[i].get("required_flag", ""))
			if rf != "" and is_owned.call(rf):
				return i
		return default_idx

	var best_idx: int = -1
	var best_threshold: int = -1
	for i in paths.size():
		var t: int = int(paths[i].get("threshold", 0))
		if value >= t and t > best_threshold:
			best_threshold = t
			best_idx = i
	return best_idx if best_idx >= 0 else default_idx


# Sacrifice gating: can the player afford this path? Affordable when its coin cost
# is met (cost <= 0 or coins >= cost) AND its required item is owned (or none).
# `is_owned` is a Callable(String) -> bool.
static func path_affordable(
	cost: int, required_item: String, coins: int, is_owned: Callable
) -> bool:
	if cost > 0 and coins < cost:
		return false
	if required_item != "" and not is_owned.call(required_item):
		return false
	return true


# Which path a timed-out INTERACTIVE fork (auto-advance) takes.
#   conditional        → default_path, its existing fallback.
#   choice / sacrifice → timeout_path when it's set and selectable, else a selectable path chosen
#                        by `r` (the caller's random draw; r % pool.size() picks among the pool).
# `selectable` is a per-path affordability mask (all true for cost-free forks) whose size IS the path
# count; the caller builds it from live coins/ownership. Returns a valid index, or -1 when nothing is
# selectable (a sacrifice dead-end, or an empty fork) — the caller should then leave the fork alone.
static func timeout_pick(
	resolution: String, selectable: Array, timeout_path: int, default_path: int, r: int
) -> int:
	var n: int = selectable.size()
	if n == 0:
		return -1
	if resolution == "conditional":
		return clampi(default_path, 0, n - 1)
	if timeout_path >= 0 and timeout_path < n and bool(selectable[timeout_path]):
		return timeout_path
	var pool: Array = []
	for i in n:
		if bool(selectable[i]):
			pool.append(i)
	if pool.is_empty():
		return -1
	return pool[(r % pool.size() + pool.size()) % pool.size()]  # tolerate a negative r
