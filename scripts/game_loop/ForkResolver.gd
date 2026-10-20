class_name ForkResolver
extends RefCounted

# Pure fork path-picking logic, extracted from GameLoop / ForkScreen so it can be
# tested in isolation. Every function here is deterministic: external state
# (score, coins, item ownership, the random draw) is passed in by the caller, not
# read from autoloads or RNG. The callers stay thin glue.
#
#   Random      → weighted_pick(weights, r)         (caller supplies r = randi() % total)
#   Conditional → conditional_path(...)             (caller supplies score/coins value + is_owned + r)
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


# Resolves a conditional fork to a path index: one of the paths whose condition is met, chosen at random
# with equal odds, else the default. Every metric works the same way (owner, 2026-10-17) — a fork that
# lets the game decide used to take the FIRST unlocked flag or item path, or the HIGHEST threshold met,
# so the same path came up every time several were unlocked. An author who wants tiers raises the low
# thresholds so they stop overlapping. `r` is the caller's random draw (any int; r mod the met count
# picks), `value` the score or coin balance for those metrics, `is_owned` a Callable(String) -> bool
# (items, or the flag-checker for flags), `counter_of` a Callable(String) -> int for counters.
# `default_path` is clamped into range.
static func conditional_path(
	paths: Array,
	metric: String,
	default_path: int,
	value: int,
	is_owned: Callable,
	counter_of: Callable = Callable(),
	r: int = 0
) -> int:
	if paths.is_empty():
		return 0
	var met: Array = met_paths(paths, metric, value, is_owned, counter_of)
	if met.is_empty():
		return clampi(default_path, 0, paths.size() - 1)
	return met[posmod(r, met.size())]


# The indices of every path whose condition is met, in path order.
static func met_paths(
	paths: Array, metric: String, value: int, is_owned: Callable, counter_of: Callable = Callable()
) -> Array:
	var met: Array = []
	for i: int in paths.size():
		if path_met(paths[i], metric, value, is_owned, counter_of):
			met.append(i)
	return met


# Whether one path's condition is met.
#   item / flag      → its required item is owned / required flag is set (none named = never met).
#   counter          → ITS OWN counter (cond_counter, read through counter_of) reaches its threshold.
#   score / coins    → `value` reaches its threshold.
static func path_met(
	path: Dictionary,
	metric: String,
	value: int,
	is_owned: Callable,
	counter_of: Callable = Callable()
) -> bool:
	var threshold: int = int(path.get("threshold", 0))
	match metric:
		"item":
			var item: String = str(path.get("required_item", ""))
			return item != "" and is_owned.call(item)
		"flag":
			var flag: String = str(path.get("required_flag", ""))
			return flag != "" and is_owned.call(flag)
		"counter":
			var counter: int = (
				int(counter_of.call(str(path.get("cond_counter", ""))))
				if counter_of.is_valid()
				else 0
			)
			return counter >= threshold
	return value >= threshold


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
