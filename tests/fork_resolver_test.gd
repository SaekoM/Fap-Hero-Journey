extends GdUnitTestSuite

# ForkResolver — the pure fork path-picking logic extracted from GameLoop /
# ForkScreen. All deterministic: the random draw (r), score/coins value, and item
# ownership are passed in, so no RNG or autoload is involved here.


# Builds an is_owned Callable backed by a fixed owned-items list.
func _owns(items: Array) -> Callable:
	return func(id: String) -> bool: return id in items


# ── weighted_pick ────────────────────────────────────────────────────────────


# r lands in the cumulative bracket of its index. weights [1,2,1] → [1,3,4):
# r 0 → idx0, r 1-2 → idx1, r 3 → idx2.
func test_weighted_pick_brackets() -> void:
	assert_int(ForkResolver.weighted_pick([1, 2, 1], 0)).is_equal(0)
	assert_int(ForkResolver.weighted_pick([1, 2, 1], 1)).is_equal(1)
	assert_int(ForkResolver.weighted_pick([1, 2, 1], 2)).is_equal(1)
	assert_int(ForkResolver.weighted_pick([1, 2, 1], 3)).is_equal(2)


func test_weighted_pick_single_and_empty() -> void:
	assert_int(ForkResolver.weighted_pick([5], 0)).is_equal(0)
	assert_int(ForkResolver.weighted_pick([5], 4)).is_equal(0)
	assert_int(ForkResolver.weighted_pick([], 0)).is_equal(0)


# Zero-weight paths are never picked — r falls through them to the next bracket.
func test_weighted_pick_skips_zero_weights() -> void:
	assert_int(ForkResolver.weighted_pick([0, 0, 3], 0)).is_equal(2)
	assert_int(ForkResolver.weighted_pick([0, 0, 3], 2)).is_equal(2)


# ── conditional_path: score / coins thresholds ──────────────────────────────


func test_conditional_highest_met_threshold_wins() -> void:
	var paths := [{"threshold": 0}, {"threshold": 100}, {"threshold": 200}]
	assert_int(ForkResolver.conditional_path(paths, "score", 0, 150, _owns([]))).is_equal(1)
	assert_int(ForkResolver.conditional_path(paths, "score", 0, 250, _owns([]))).is_equal(2)
	assert_int(ForkResolver.conditional_path(paths, "score", 0, 50, _owns([]))).is_equal(0)


# The coins metric runs the same threshold path (value is supplied by the caller).
func test_conditional_coins_metric_uses_thresholds() -> void:
	var paths := [{"threshold": 0}, {"threshold": 50}]
	assert_int(ForkResolver.conditional_path(paths, "coins", 0, 75, _owns([]))).is_equal(1)
	assert_int(ForkResolver.conditional_path(paths, "coins", 0, 25, _owns([]))).is_equal(0)


# No path's threshold met → the (clamped) default path.
func test_conditional_no_match_uses_default() -> void:
	var paths := [{"threshold": 100}, {"threshold": 200}]
	assert_int(ForkResolver.conditional_path(paths, "score", 1, 50, _owns([]))).is_equal(1)
	# default_path out of range is clamped into bounds.
	assert_int(ForkResolver.conditional_path(paths, "score", 99, 50, _owns([]))).is_equal(1)


# ── conditional_path: item ownership ────────────────────────────────────────


func test_conditional_item_picks_first_owned() -> void:
	var paths := [{"required_item": ""}, {"required_item": "key"}, {"required_item": "gem"}]
	assert_int(ForkResolver.conditional_path(paths, "item", 0, 0, _owns(["gem"]))).is_equal(2)
	assert_int(ForkResolver.conditional_path(paths, "item", 0, 0, _owns(["key", "gem"]))).is_equal(
		1
	)
	assert_int(ForkResolver.conditional_path(paths, "item", 0, 0, _owns([]))).is_equal(0)  # default


func test_conditional_empty_paths() -> void:
	assert_int(ForkResolver.conditional_path([], "score", 0, 100, _owns([]))).is_equal(0)


# ── path_affordable (Sacrifice gating) ──────────────────────────────────────


func test_affordable_free_path() -> void:
	assert_bool(ForkResolver.path_affordable(0, "", 0, _owns([]))).is_true()


func test_affordable_coin_cost() -> void:
	assert_bool(ForkResolver.path_affordable(50, "", 100, _owns([]))).is_true()
	assert_bool(ForkResolver.path_affordable(50, "", 50, _owns([]))).is_true()  # exact
	assert_bool(ForkResolver.path_affordable(50, "", 30, _owns([]))).is_false()  # short


func test_affordable_required_item() -> void:
	assert_bool(ForkResolver.path_affordable(0, "key", 0, _owns(["key"]))).is_true()
	assert_bool(ForkResolver.path_affordable(0, "key", 0, _owns([]))).is_false()


# Both gates must pass.
func test_affordable_coins_and_item() -> void:
	assert_bool(ForkResolver.path_affordable(50, "key", 100, _owns(["key"]))).is_true()
	assert_bool(ForkResolver.path_affordable(50, "key", 100, _owns([]))).is_false()  # has coins, no item
	assert_bool(ForkResolver.path_affordable(50, "key", 30, _owns(["key"]))).is_false()  # has item, no coins


# ── timeout_pick (auto-advance) ─────────────────────────────────────────────
# `selectable` is a per-path affordability mask; `r` is the caller's random draw. All deterministic.


# Conditional forks ignore timeout_path and take their default fallback (clamped into range).
func test_timeout_conditional_uses_default() -> void:
	assert_int(ForkResolver.timeout_pick("conditional", [true, true, true], -1, 1, 0)).is_equal(1)
	assert_int(ForkResolver.timeout_pick("conditional", [true, true, true], 2, 0, 5)).is_equal(0)
	assert_int(ForkResolver.timeout_pick("conditional", [true, true], -1, 99, 0)).is_equal(1)  # clamped


# An author-set timeout path is taken verbatim when it's selectable, regardless of r.
func test_timeout_uses_author_path_when_selectable() -> void:
	assert_int(ForkResolver.timeout_pick("choice", [true, true, true], 2, 0, 0)).is_equal(2)
	assert_int(ForkResolver.timeout_pick("sacrifice", [true, false, true], 2, 0, 0)).is_equal(2)


# No author path (-1) → a random SELECTABLE path, indexed by r % pool.size().
func test_timeout_random_over_selectable_pool() -> void:
	# choice: every path selectable → pool [0,1,2].
	assert_int(ForkResolver.timeout_pick("choice", [true, true, true], -1, 0, 0)).is_equal(0)
	assert_int(ForkResolver.timeout_pick("choice", [true, true, true], -1, 0, 1)).is_equal(1)
	assert_int(ForkResolver.timeout_pick("choice", [true, true, true], -1, 0, 3)).is_equal(0)  # wraps
	# sacrifice: only paths 0 and 2 affordable → pool [0,2].
	assert_int(ForkResolver.timeout_pick("sacrifice", [true, false, true], -1, 0, 0)).is_equal(0)
	assert_int(ForkResolver.timeout_pick("sacrifice", [true, false, true], -1, 0, 1)).is_equal(2)


# An author path that isn't selectable (e.g. now unaffordable) is skipped for the random pool.
func test_timeout_unselectable_author_path_falls_to_pool() -> void:
	assert_int(ForkResolver.timeout_pick("sacrifice", [true, false, true], 1, 0, 1)).is_equal(2)


# A sacrifice fork with nothing affordable, or an empty fork, can't be auto-resolved → -1.
func test_timeout_no_selectable_returns_negative() -> void:
	assert_int(ForkResolver.timeout_pick("sacrifice", [false, false], -1, 0, 0)).is_equal(-1)
	assert_int(ForkResolver.timeout_pick("choice", [], -1, 0, 0)).is_equal(-1)


# A negative random draw still lands on a valid pool index (defensive modulo).
func test_timeout_tolerates_negative_r() -> void:
	assert_int(ForkResolver.timeout_pick("choice", [true, true, true], -1, 0, -1)).is_equal(2)
