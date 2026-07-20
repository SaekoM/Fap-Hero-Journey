extends GdUnitTestSuite

# Named counters — the pure authoring/serialization layer (parse the "belt:1, arousal:-1" field,
# clean a {name:delta} map, coerce onto a node). The runtime accumulation + fork gating lives in
# GameState (C#) and is covered in gamestate_fork_test.gd.


func test_parse_counter_deltas() -> void:
	var d: Dictionary = JourneyData.parse_counter_deltas("belt:1, arousal:2, stress:-1")
	assert_int(int(d["belt"])).is_equal(1)
	assert_int(int(d["arousal"])).is_equal(2)
	assert_int(int(d["stress"])).is_equal(-1)


# A bare name defaults to +1 — the "notch on the belt" shorthand.
func test_parse_bare_name_is_plus_one() -> void:
	var d: Dictionary = JourneyData.parse_counter_deltas("belt")
	assert_int(int(d["belt"])).is_equal(1)


func test_parse_drops_blanks_and_zeros() -> void:
	var d: Dictionary = JourneyData.parse_counter_deltas(" , belt:0 , :5 , keep:3 ")
	assert_bool(d.has("belt")).is_false()  # +0 is a no-op
	assert_int(d.size()).is_equal(1)
	assert_int(int(d["keep"])).is_equal(3)


func test_clean_counter_deltas() -> void:
	var d: Dictionary = JourneyData.clean_counter_deltas({"belt": 2, " x ": 0, "": 4, "y": -3})
	assert_int(d.size()).is_equal(2)  # x dropped (0), "" dropped (blank)
	assert_int(int(d["belt"])).is_equal(2)
	assert_int(int(d["y"])).is_equal(-3)


func test_text_round_trip() -> void:
	var text: String = "belt:1, stress:-2"
	var back: String = JourneyData.counter_deltas_to_text(JourneyData.parse_counter_deltas(text))
	# Order-independent compare: re-parse and check the maps match.
	assert_dict(JourneyData.parse_counter_deltas(back)).is_equal(
		JourneyData.parse_counter_deltas(text)
	)


# Coercion drops an empty/zero-only map so journey.json stays lean (mirrors set_flags), and keeps a
# real one.
func test_coerce_prunes_empty_counters() -> void:
	var out: Dictionary = JourneyData.coerce_node_save_data(
		"round", {"set_counters": {"belt": 0, "": 3}}
	)
	assert_bool(out.has("set_counters")).is_false()


func test_coerce_keeps_real_counters() -> void:
	var out: Dictionary = JourneyData.coerce_node_save_data(
		"storyboard", {"set_counters": {"arousal": 2}}
	)
	assert_int(int((out["set_counters"] as Dictionary)["arousal"])).is_equal(2)


# A conditional fork on a counter records which counter it gates on.
func test_coerce_fork_cond_counter() -> void:
	var out: Dictionary = JourneyData.coerce_node_save_data(
		"fork", {"cond_metric": "counter", "cond_counter": "satisfied_partners"}
	)
	assert_str(str(out["cond_metric"])).is_equal("counter")
	assert_str(str(out["cond_counter"])).is_equal("satisfied_partners")
