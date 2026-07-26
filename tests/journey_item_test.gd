extends GdUnitTestSuite

# JourneyData custom-item coerce (runtime → journey.json) / parse (journey.json → runtime) round-trip.
# Pure schema mapping — no autoloads.


func test_modifier_item_round_trip() -> void:
	var item := {
		"id": "itm_1",
		"name": "Potion",
		"description": "does stuff",
		"category": "modifier",
		"price": 40,
		"duration_ms": 20000,
		"effects": [{"kind": "scale", "factor": 0.8}, {"kind": "clamp", "min": 0, "max": 50}],
	}
	var runtime := JourneyData.parse_journey_item(JourneyData.coerce_journey_item(item))
	assert_str(str(runtime["id"])).is_equal("itm_1")
	assert_str(str(runtime["name"])).is_equal("Potion")
	assert_str(str(runtime["category"])).is_equal("modifier")
	assert_int(int(runtime["price"])).is_equal(40)
	assert_int(int(runtime["duration_ms"])).is_equal(20000)
	assert_int((runtime["effects"] as Array).size()).is_equal(2)
	assert_str(str((runtime["effects"][0] as Dictionary)["kind"])).is_equal("scale")


# A key carries no effect bundle or duration, and gains kind:"key" so InventoryService refuses use.
func test_key_item_round_trip_has_no_effects() -> void:
	var saved := JourneyData.coerce_journey_item(
		{"id": "itm_k", "name": "Gold Key", "category": "key"}
	)
	assert_bool(saved.has("Effects")).is_false()
	var runtime := JourneyData.parse_journey_item(saved)
	assert_str(str(runtime["category"])).is_equal("key")
	assert_str(str(runtime["kind"])).is_equal("key")
	assert_bool(runtime.has("effects")).is_false()


func test_invalid_category_falls_back_to_modifier() -> void:
	var saved := JourneyData.coerce_journey_item({"id": "x", "category": "bogus"})
	assert_str(str(saved["Category"])).is_equal("modifier")


func test_price_clamped_non_negative() -> void:
	var saved := JourneyData.coerce_journey_item({"id": "x", "price": -20})
	assert_int(int(saved["Price"])).is_equal(0)


# A blank/missing Id on disk is healed to a fresh durable id on read (an empty id is always broken —
# LoadJourneyItems skips it and no fork can gate on ""). Guards legacy / mid-development id-less items.
func test_blank_id_is_healed_on_parse() -> void:
	var runtime := JourneyData.parse_journey_item(
		{"Name": "Orphan Key", "Category": "key", "Id": ""}
	)
	assert_str(str(runtime["id"])).is_not_equal("")
	assert_str(str(runtime["id"])).starts_with("itm_")
	var missing := JourneyData.parse_journey_item({"Name": "No Id Field", "Category": "modifier"})
	assert_str(str(missing["id"])).starts_with("itm_")


# The one-shot / fog effect kinds carry non-standard params (amount / pct / flag / counter / delta)
# that must survive the coerce↔parse deep-copy — guards against a _MakeActiveEffect/skip-list drop.
func test_oneshot_effect_params_round_trip() -> void:
	var item := {
		"id": "itm_o",
		"name": "Trinket",
		"category": "modifier",
		"duration_ms": 10000,
		"effects":
		[
			{"kind": "toll", "amount": 25},
			{"kind": "interest", "pct": 0.5},
			{"kind": "flag", "flag": "pact"},
			{"kind": "counter", "counter": "belt", "delta": 2},
			{"kind": "hud_hide"},
		],
	}
	var fx: Array = JourneyData.parse_journey_item(JourneyData.coerce_journey_item(item))["effects"]
	assert_int(fx.size()).is_equal(5)
	assert_int(int((fx[0] as Dictionary)["amount"])).is_equal(25)
	assert_float(float((fx[1] as Dictionary)["pct"])).is_equal(0.5)
	assert_str(str((fx[2] as Dictionary)["flag"])).is_equal("pact")
	assert_str(str((fx[3] as Dictionary)["counter"])).is_equal("belt")
	assert_int(int((fx[3] as Dictionary)["delta"])).is_equal(2)
	assert_str(str((fx[4] as Dictionary)["kind"])).is_equal("hud_hide")
