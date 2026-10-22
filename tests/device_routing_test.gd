extends GdUnitTestSuite

# Unit tests for DeviceRouting — pure resolver, no real devices needed.


func _catalog() -> Array:
	return [
		{"id": "Solace Pro#0", "linear": true, "vibrate_channels": 0, "constrict_channels": 0},
		{"id": "Max 2#0", "linear": false, "vibrate_channels": 1, "constrict_channels": 1},
		{"id": "Edge 2#0", "linear": false, "vibrate_channels": 2, "constrict_channels": 0},
		{
			"id": "Thruster#0",
			"linear": false,
			"vibrate_channels": 0,
			"constrict_channels": 0,
			"oscillate_channels": 1,
		},
	]


func _find_vibe(plan: Dictionary, device: String, channel: int) -> Dictionary:
	for e: Dictionary in plan["vibration"] as Array:
		if e["device"] == device and int(e["channel"]) == channel:
			return e
	return {}


func test_parse_actuator_id_valid() -> void:
	var a: Dictionary = DeviceRouting.parse_actuator_id("Edge 2#0:vibrate:1")
	assert_str(a["device"]).is_equal("Edge 2#0")
	assert_str(a["kind"]).is_equal("vibrate")
	assert_int(a["channel"]).is_equal(1)


func test_parse_actuator_id_malformed() -> void:
	assert_bool(DeviceRouting.parse_actuator_id("nonsense").is_empty()).is_true()
	assert_bool(DeviceRouting.parse_actuator_id("Edge 2#0:vibrate:x").is_empty()).is_true()


func test_serial_stroke_target() -> void:
	var plan: Dictionary = DeviceRouting.resolve("serial", {}, {}, _catalog())
	assert_str(str((plan["stroke"] as Dictionary).get("backend", ""))).is_equal("serial")


# The Handy resolves like serial — a backend sentinel, not a catalog device
# (GameLoop drives it over the cloud API; FunscriptPlayer ignores the backend).
func test_handy_stroke_target() -> void:
	var plan: Dictionary = DeviceRouting.resolve("handy", {}, {}, _catalog())
	assert_str(str((plan["stroke"] as Dictionary).get("backend", ""))).is_equal("handy")
	# Vibration routing is unaffected by a handy stroke target.
	var plan2: Dictionary = DeviceRouting.resolve(
		"handy", {"Edge 2#0:vibrate:0": "vibe1"}, {}, _catalog()
	)
	assert_int((plan2["vibration"] as Array).size()).is_equal(1)


func test_buttplug_stroke_present() -> void:
	var plan: Dictionary = DeviceRouting.resolve("Solace Pro#0:linear:0", {}, {}, _catalog())
	assert_str(str((plan["stroke"] as Dictionary).get("backend", ""))).is_equal("bp")
	assert_str(str((plan["stroke"] as Dictionary).get("device", ""))).is_equal("Solace Pro#0")


func test_buttplug_stroke_absent_drops() -> void:
	var plan: Dictionary = DeviceRouting.resolve("Ghost#0:linear:0", {}, {}, _catalog())
	assert_bool((plan["stroke"] as Dictionary).is_empty()).is_true()


func test_stroke_target_must_be_linear() -> void:
	# Pointing the stroker at a vibrate actuator resolves to nothing.
	var plan: Dictionary = DeviceRouting.resolve("Edge 2#0:vibrate:0", {}, {}, _catalog())
	assert_bool((plan["stroke"] as Dictionary).is_empty()).is_true()


func test_vibration_routes_resolve() -> void:
	var routes: Dictionary = {"Edge 2#0:vibrate:0": "vibe1", "Edge 2#0:vibrate:1": "vibe2"}
	var plan: Dictionary = DeviceRouting.resolve("", routes, {}, _catalog())
	assert_int((plan["vibration"] as Array).size()).is_equal(2)
	assert_str(str(_find_vibe(plan, "Edge 2#0", 0).get("source", ""))).is_equal("vibe1")
	assert_str(str(_find_vibe(plan, "Edge 2#0", 1).get("source", ""))).is_equal("vibe2")


func test_vibration_follow_stroke_source() -> void:
	var plan: Dictionary = DeviceRouting.resolve(
		"", {"Max 2#0:vibrate:0": "stroke"}, {}, _catalog()
	)
	assert_str(str(_find_vibe(plan, "Max 2#0", 0).get("source", ""))).is_equal("stroke")


func test_vibration_absent_device_dropped() -> void:
	var plan: Dictionary = DeviceRouting.resolve("", {"Ghost#0:vibrate:0": "vibe1"}, {}, _catalog())
	assert_int((plan["vibration"] as Array).size()).is_equal(0)


func test_vibration_channel_out_of_range_dropped() -> void:
	# Edge 2 exposes channels 0 and 1; channel 2 does not exist.
	var plan: Dictionary = DeviceRouting.resolve(
		"", {"Edge 2#0:vibrate:2": "vibe1"}, {}, _catalog()
	)
	assert_int((plan["vibration"] as Array).size()).is_equal(0)


func test_vibration_invalid_source_dropped() -> void:
	var plan: Dictionary = DeviceRouting.resolve(
		"", {"Edge 2#0:vibrate:0": "bogus"}, {}, _catalog()
	)
	assert_int((plan["vibration"] as Array).size()).is_equal(0)


func test_constrict_enabled_present() -> void:
	var plan: Dictionary = DeviceRouting.resolve("", {}, {"Max 2#0:constrict:0": true}, _catalog())
	assert_int((plan["constrict"] as Array).size()).is_equal(1)
	assert_str(str(((plan["constrict"] as Array)[0] as Dictionary).get("device", ""))).is_equal(
		"Max 2#0"
	)


func test_constrict_disabled_skipped() -> void:
	var plan: Dictionary = DeviceRouting.resolve("", {}, {"Max 2#0:constrict:0": false}, _catalog())
	assert_int((plan["constrict"] as Array).size()).is_equal(0)


func test_constrict_absent_channel_dropped() -> void:
	# Edge 2 has no constrict channels.
	var plan: Dictionary = DeviceRouting.resolve("", {}, {"Edge 2#0:constrict:0": true}, _catalog())
	assert_int((plan["constrict"] as Array).size()).is_equal(0)


func test_empty_config() -> void:
	var plan: Dictionary = DeviceRouting.resolve("", {}, {}, _catalog())
	assert_bool((plan["stroke"] as Dictionary).is_empty()).is_true()
	assert_int((plan["vibration"] as Array).size()).is_equal(0)
	assert_int((plan["constrict"] as Array).size()).is_equal(0)


func test_full_example() -> void:
	var plan: Dictionary = DeviceRouting.resolve(
		"Solace Pro#0:linear:0",
		{
			"Max 2#0:vibrate:0": "stroke",
			"Edge 2#0:vibrate:0": "vibe1",
			"Edge 2#0:vibrate:1": "vibe2"
		},
		{"Max 2#0:constrict:0": true},
		_catalog()
	)
	assert_str(str((plan["stroke"] as Dictionary).get("backend", ""))).is_equal("bp")
	assert_str(str((plan["stroke"] as Dictionary).get("device", ""))).is_equal("Solace Pro#0")
	assert_int((plan["vibration"] as Array).size()).is_equal(3)
	assert_int((plan["constrict"] as Array).size()).is_equal(1)


# ── Oscillate (OSCILLATE_DESIGN.md) ──────────────────────────────────────────


func test_an_oscillate_route_resolves_with_its_limits() -> void:
	var plan: Dictionary = DeviceRouting.resolve(
		"",
		{},
		{},
		_catalog(),
		{"Thruster#0:oscillate:0": "stroke_rate"},
		{"Thruster#0:oscillate:0": {"min": 15, "max": 70}}
	)
	assert_array(plan["oscillate"]).is_equal(
		[{"device": "Thruster#0", "channel": 0, "source": "stroke_rate", "min": 15, "max": 70}]
	)


func test_an_oscillate_route_without_limits_gets_the_full_range() -> void:
	var plan: Dictionary = DeviceRouting.resolve(
		"", {}, {}, _catalog(), {"Thruster#0:oscillate:0": "vibe1"}, {}
	)
	var route: Dictionary = (plan["oscillate"] as Array)[0]
	assert_int(route["min"]).is_equal(0)
	assert_int(route["max"]).is_equal(100)
	assert_str(route["source"]).is_equal("vibe1")


func test_oscillate_routes_need_a_real_channel_and_source() -> void:
	var routes: Dictionary = {
		"Thruster#0:oscillate:1": "stroke_rate",  # out of range
		"Ghost#0:oscillate:0": "stroke_rate",  # not connected
		"Edge 2#0:oscillate:0": "stroke_rate",  # no oscillator
		"Thruster#0:vibrate:0": "stroke_rate",  # wrong kind
	}
	assert_array(DeviceRouting.resolve("", {}, {}, _catalog(), routes, {})["oscillate"]).is_empty()
	var bad_source: Dictionary = {"Thruster#0:oscillate:0": "stroke"}  # a vibration source
	(
		assert_array(DeviceRouting.resolve("", {}, {}, _catalog(), bad_source, {})["oscillate"])
		. is_empty()
	)


# Older callers pass four arguments; the plan still has an (empty) oscillate list.
func test_the_plan_always_lists_oscillate() -> void:
	assert_array(DeviceRouting.resolve("", {}, {}, _catalog())["oscillate"]).is_empty()


func test_limits_are_clamped_and_ordered() -> void:
	var aid: String = "Thruster#0:oscillate:0"
	assert_dict(DeviceRouting.oscillate_limits_for({aid: {"min": -20, "max": 140}}, aid)).is_equal(
		{"min": 0, "max": 100}
	)
	assert_dict(DeviceRouting.oscillate_limits_for({aid: {"min": 80, "max": 40}}, aid)).is_equal(
		{"min": 40, "max": 40}
	)
	assert_dict(DeviceRouting.oscillate_limits_for({aid: "junk"}, aid)).is_equal(
		{"min": 0, "max": 100}
	)
