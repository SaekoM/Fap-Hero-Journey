extends GdUnitTestSuite

# Shop lineup resolution (JourneyData.resolve_shop_offer + the guaranteed/
# possible queries). Pure — the item registry is injected, and randomness is
# driven through a seeded RandomNumberGenerator, so draws are deterministic.
# ShopScreen._resolve_offer and the journey auditor both ride these helpers.

const REGISTRY: Array = ["cleanse", "key", "mirror", "overdrive", "safe_word"]


func _rng(seed_value: int = 1234) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


# Fixed mode: exactly the authored lineup, in registry order, stale ids dropped.
func test_fixed_mode_exact_lineup() -> void:
	var shop := {"mode": "fixed", "items": ["safe_word", "key", "gone_item"], "count": 1}
	var offer: Array = JourneyData.resolve_shop_offer(shop, REGISTRY, _rng())
	assert_array(offer).is_equal(["key", "safe_word"])


# Pool mode: guaranteed items always present, lineup filled to count.
func test_pool_mode_guarantees_present() -> void:
	var shop := {"mode": "pool", "guaranteed": ["key"], "count": 3}
	for seed_value: int in [1, 99, 4242]:
		var offer: Array = JourneyData.resolve_shop_offer(shop, REGISTRY, _rng(seed_value))
		assert_array(offer).contains(["key"])
		assert_int(offer.size()).is_equal(3)


# Count can never trim a guaranteed item: 3 guaranteed with count 2 shows all 3.
func test_pool_count_never_trims_guaranteed() -> void:
	var shop := {"mode": "pool", "guaranteed": ["cleanse", "key", "safe_word"], "count": 2}
	var offer: Array = JourneyData.resolve_shop_offer(shop, REGISTRY, _rng())
	assert_array(offer).is_equal(["cleanse", "key", "safe_word"])


# Pool mode with no guarantees behaves like the legacy random draw.
func test_pool_mode_plain_draw() -> void:
	var shop := {"mode": "pool", "count": 2}
	var offer: Array = JourneyData.resolve_shop_offer(shop, REGISTRY, _rng())
	assert_int(offer.size()).is_equal(2)
	for id: String in offer:
		assert_bool(id in REGISTRY).is_true()


# Stale guaranteed ids (item removed from the registry) are dropped, not offered.
func test_stale_guaranteed_dropped() -> void:
	var shop := {"mode": "pool", "guaranteed": ["gone_item", "key"], "count": 2}
	var offer: Array = JourneyData.resolve_shop_offer(shop, REGISTRY, _rng())
	assert_array(offer).contains(["key"])
	assert_bool("gone_item" in offer).is_false()


# The audit-facing queries: guaranteed = lineup (fixed) / guaranteed list (pool);
# possible = lineup (fixed) / whole registry (pool).
func test_guaranteed_and_possible_queries() -> void:
	var fixed := {"mode": "fixed", "items": ["key", "cleanse"]}
	assert_array(JourneyData.shop_guaranteed_ids(fixed, REGISTRY)).is_equal(["cleanse", "key"])
	assert_array(JourneyData.shop_possible_ids(fixed, REGISTRY)).is_equal(["cleanse", "key"])

	var pool := {"mode": "pool", "guaranteed": ["key"], "count": 2}
	assert_array(JourneyData.shop_guaranteed_ids(pool, REGISTRY)).is_equal(["key"])
	assert_array(JourneyData.shop_possible_ids(pool, REGISTRY)).is_equal(REGISTRY)


# ── Exclusions (pool mode: "never drawn") ────────────────────────────────────


# An excluded item never turns up in the random draw, across many seeds.
func test_excluded_never_drawn() -> void:
	var shop := {"mode": "pool", "excluded": ["key", "mirror"], "count": 3}
	for seed_value: int in [1, 7, 99, 4242, 88888]:
		var offer: Array = JourneyData.resolve_shop_offer(shop, REGISTRY, _rng(seed_value))
		assert_bool("key" in offer).is_false()
		assert_bool("mirror" in offer).is_false()
		assert_int(offer.size()).is_equal(3)


# Guaranteed beats excluded — ticking both is explicit intent, not a contradiction.
func test_guaranteed_survives_exclusion() -> void:
	var shop := {"mode": "pool", "guaranteed": ["key"], "excluded": ["key"], "count": 2}
	var offer: Array = JourneyData.resolve_shop_offer(shop, REGISTRY, _rng())
	assert_array(offer).contains(["key"])


# Excluding most of the registry shrinks the lineup rather than erroring or repeating.
func test_exclusions_can_shrink_the_lineup() -> void:
	var shop := {"mode": "pool", "excluded": ["cleanse", "key", "mirror", "overdrive"], "count": 4}
	var offer: Array = JourneyData.resolve_shop_offer(shop, REGISTRY, _rng())
	assert_array(offer).is_equal(["safe_word"])


# Exclusions don't touch fixed mode — there the authored list IS the lineup.
func test_exclusions_ignored_in_fixed_mode() -> void:
	var shop := {"mode": "fixed", "items": ["key", "cleanse"], "excluded": ["key"], "count": 1}
	var offer: Array = JourneyData.resolve_shop_offer(shop, REGISTRY, _rng())
	assert_array(offer).is_equal(["cleanse", "key"])


# The auditor asks what a shop MIGHT offer — an excluded item is unreachable, so it must not
# count as obtainable (it would otherwise wrongly satisfy a fork that requires that item).
func test_possible_ids_respect_exclusions() -> void:
	var shop := {"mode": "pool", "excluded": ["key"], "count": 3}
	var possible: Array = JourneyData.shop_possible_ids(shop, REGISTRY)
	assert_bool("key" in possible).is_false()
	assert_bool("cleanse" in possible).is_true()
	# ...unless it's also guaranteed.
	var both := {"mode": "pool", "guaranteed": ["key"], "excluded": ["key"], "count": 3}
	assert_bool("key" in JourneyData.shop_possible_ids(both, REGISTRY)).is_true()
