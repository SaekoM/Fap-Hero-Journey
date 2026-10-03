extends GdUnitTestSuite

# Multi-axis modifiers (MULTIAXIS_DESIGN.md §3, step 3): the stroke curses mirrored onto every axis but
# the stroke — Stiffened, Braced, Contrary, Stilled and the Limber blessing — and the substitution that
# hands a player without those axes the stroke twin instead.

# ── The catalog ──────────────────────────────────────────────────────────────


func test_every_axis_entry_names_a_stroke_twin_that_exists() -> void:
	for entry: Dictionary in JourneyData.gameplay_effects():
		if not JourneyData.is_axis_effect(str(entry.get("kind", ""))):
			continue
		var twin: Dictionary = JourneyData.effect_entry(str(entry.get("substitute", "")))
		assert_dict(twin).is_not_empty()
		# The twin is the matching STROKE kind, so the substitution is the same curse, felt elsewhere.
		assert_str(str(twin["kind"])).is_equal(JourneyData.AXIS_EFFECT_TWINS[entry["kind"]])


# Owner's call: the turning axes are subtle, so they get the stronger values; surge and sway mirror the
# stroke curses exactly.
func test_turning_axes_get_the_stronger_values() -> void:
	var stiffened: Dictionary = JourneyData.effect_entry("Stiffened")
	assert_float(float(stiffened["factor"])).is_equal_approx(0.6, 0.0001)
	assert_float(float(stiffened["rotary_factor"])).is_less(float(stiffened["factor"]))
	var braced: Dictionary = JourneyData.effect_entry("Braced")
	var linear_band: int = int(braced["max"]) - int(braced["min"])
	var rotary_band: int = int(braced["rotary_max"]) - int(braced["rotary_min"])
	assert_int(rotary_band).is_less(linear_band)
	var limber: Dictionary = JourneyData.effect_entry("Limber")
	assert_float(float(limber["rotary_factor"])).is_greater(float(limber["factor"]))


func test_limber_is_a_blessing_and_the_rest_are_curses() -> void:
	assert_bool(JourneyData.effect_is_benefit("Limber")).is_true()
	for name: String in ["Stiffened", "Braced", "Contrary", "Stilled"]:
		assert_bool(JourneyData.effect_is_benefit(name)).is_false()


# A legacy cursed round with no curses listed meant "the whole pool as it stood then". The axis curses
# added since must not quietly join it and change the odds of a journey nobody re-tuned.
func test_a_legacy_full_pool_round_keeps_its_old_pool() -> void:
	var cursed: Dictionary = JourneyData.normalize_effect_round({"round_type": "cursed"})
	for name: String in ["Stiffened", "Braced", "Contrary", "Stilled"]:
		assert_array(cursed["effects"]).not_contains([name])
	assert_array(cursed["effects"]).contains(["Shrunken", "Numbed"])
	var blessed: Dictionary = JourneyData.normalize_effect_round({"round_type": "blessed"})
	assert_array(blessed["effects"]).not_contains(["Limber"])


# ── Does this round give an axis curse anything to act on? ──────────────────

const SR6: Array = ["L0", "L1", "L2", "R0", "R1", "R2"]
const OSR2: Array = ["L0", "R1", "R2"]
const STROKE_ONLY: Array = ["L0"]


func test_a_scripted_axis_the_device_has_is_motion() -> void:
	assert_bool(JourneyData.round_has_axis_motion(OSR2, ["R2"], false)).is_true()


# An OSR2 can't feel a twist script, so a round whose only axis is twist gives it nothing.
func test_a_scripted_axis_the_device_lacks_is_not() -> void:
	assert_bool(JourneyData.round_has_axis_motion(OSR2, ["R0"], false)).is_false()


func test_auto_twist_counts_on_a_device_with_twist() -> void:
	assert_bool(JourneyData.round_has_axis_motion(SR6, [], true)).is_true()
	assert_bool(JourneyData.round_has_axis_motion(OSR2, [], true)).is_false()


func test_a_stroke_only_device_never_has_axis_motion() -> void:
	assert_bool(JourneyData.round_has_axis_motion(STROKE_ONLY, ["R0", "R1", "L1"], true)).is_false()


# ── Substitution ─────────────────────────────────────────────────────────────


func test_with_axis_motion_the_axis_curse_is_kept() -> void:
	var stiffened: Dictionary = JourneyData.effect_entry("Stiffened")
	var out: Array = JourneyData.express_effects([stiffened], true)
	assert_str(str((out[0] as Dictionary)["kind"])).is_equal("axis_scale")


func test_without_it_the_named_twin_takes_its_place() -> void:
	var out: Array = JourneyData.express_effects([JourneyData.effect_entry("Braced")], false)
	var twin: Dictionary = out[0]
	assert_str(str(twin["kind"])).is_equal("clamp")
	assert_str(str(twin["name"])).is_equal("Choked")  # the card names a curse that exists
	assert_str(str(twin["_ref"])).is_equal("Choked")
	assert_bool(twin.has("rotary_min")).is_false()
	assert_bool(twin.has("substitute")).is_false()


# The author's tuning survives the swap: a Stiffened turned down to ×0.5 becomes a stroke scale ×0.5,
# not the catalog's Shrunken ×0.6.
func test_the_twin_keeps_the_authors_linear_values() -> void:
	var tuned: Dictionary = JourneyData.effect_entry("Stiffened").duplicate(true)
	tuned["factor"] = 0.5
	var twin: Dictionary = JourneyData.stroke_twin(tuned)
	assert_float(float(twin["factor"])).is_equal_approx(0.5, 0.0001)


# Raw kinds (boss forced modifiers, timeline windows) carry no catalog name, and swap by kind alone.
func test_a_raw_axis_kind_swaps_to_its_stroke_kind() -> void:
	var out: Array = JourneyData.express_effects([{"kind": "axis_block"}], false)
	assert_dict(out[0] as Dictionary).is_equal({"kind": "block"})


func test_other_effects_pass_through_untouched() -> void:
	var shrunken: Dictionary = JourneyData.effect_entry("Shrunken")
	var fog: Dictionary = JourneyData.effect_entry("Fog")
	assert_array(JourneyData.express_effects([shrunken, fog], false)).is_equal([shrunken, fog])


# ── What the audit lists ─────────────────────────────────────────────────────


func test_a_round_reports_every_axis_modifier_it_can_apply() -> void:
	var data: Dictionary = {
		"effects": ["Stiffened", "Greed"],
		"boss_modifiers": [{"kind": "axis_block"}, {"kind": "scale", "factor": 1.2}],
		"timeline": {"events": [{"effects": [{"kind": "axis_reverse"}, {"kind": "blur"}]}]},
		"pool_entries": [{"timeline": {"events": [{"effects": [{"kind": "axis_block"}]}]}}],
	}
	assert_array(JourneyData.axis_effects_in_round(data)).is_equal(
		["Stiffened", "Axes stilled", "Axes reverse"]
	)


func test_a_round_without_them_reports_none() -> void:
	assert_array(JourneyData.axis_effects_in_round({"effects": ["Shrunken"]})).is_empty()


# ── On the device ────────────────────────────────────────────────────────────


func _mod(axis: String, pos: float, effects: Array, mirror: float = 0.0) -> float:
	return FunscriptPlayer.AxisModifiedPos(axis, pos, effects, mirror)


func test_no_axis_effects_leave_the_script_alone() -> void:
	assert_float(_mod("R1", 73.0, [])).is_equal_approx(73.0, 0.0001)


# These axes rest at centre and swing both ways, so scaling squeezes the swing around 50.
func test_axis_scale_squeezes_around_centre() -> void:
	var fx: Array = [{"kind": "axis_scale", "factor": 0.6, "rotary_factor": 0.4}]
	assert_float(_mod("L1", 100.0, fx)).is_equal_approx(80.0, 0.0001)  # surge: ×0.6
	assert_float(_mod("R2", 100.0, fx)).is_equal_approx(70.0, 0.0001)  # pitch: ×0.4
	assert_float(_mod("R2", 50.0, fx)).is_equal_approx(50.0, 0.0001)


func test_scales_multiply() -> void:
	var fx: Array = [{"kind": "axis_scale", "factor": 0.5}, {"kind": "axis_scale", "factor": 0.5}]
	assert_float(_mod("L2", 100.0, fx)).is_equal_approx(62.5, 0.0001)


# Remap rather than clip, like the stroke clamp: the script keeps its shape inside the band.
func test_axis_clamp_remaps_into_the_band() -> void:
	var fx: Array = [
		{"kind": "axis_clamp", "min": 40, "max": 60, "rotary_min": 45, "rotary_max": 55}
	]
	assert_float(_mod("L1", 0.0, fx)).is_equal_approx(40.0, 0.0001)
	assert_float(_mod("L1", 100.0, fx)).is_equal_approx(60.0, 0.0001)
	assert_float(_mod("R0", 100.0, fx)).is_equal_approx(55.0, 0.0001)


# An effect without rotary values drives every axis with its plain ones.
func test_plain_values_apply_to_turning_axes_when_no_rotary_ones() -> void:
	var fx: Array = [{"kind": "axis_scale", "factor": 0.5}]
	assert_float(_mod("R1", 100.0, fx)).is_equal_approx(75.0, 0.0001)


# Contrary eases through centre like the stroke mirror: fully on flips, halfway holds at 50.
func test_reverse_flips_through_centre() -> void:
	assert_float(_mod("R1", 80.0, [], 1.0)).is_equal_approx(20.0, 0.0001)
	assert_float(_mod("R1", 80.0, [], 0.5)).is_equal_approx(50.0, 0.0001)


# The stroke's own curses never touch the other axes — Shrunken shrinks the stroke, not the twist.
func test_stroke_curses_leave_the_axes_alone() -> void:
	var fx: Array = [{"kind": "scale", "factor": 0.3}, {"kind": "clamp", "min": 0, "max": 10}]
	assert_float(_mod("R0", 90.0, fx)).is_equal_approx(90.0, 0.0001)
