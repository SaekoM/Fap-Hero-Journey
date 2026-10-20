extends GdUnitTestSuite

# Multi-axis modifiers (MULTIAXIS_DESIGN.md §3, step 3): the stroke curses mirrored onto every axis but
# the stroke — Stiffened, Braced, Contrary, Stilled and the Limber blessing — the two that create motion
# (Posed and the Vortex blessing), and the substitution that hands a player without those axes the
# stroke twin instead.

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


func test_limber_and_vortex_are_blessings_and_the_rest_are_curses() -> void:
	assert_bool(JourneyData.effect_is_benefit("Limber")).is_true()
	assert_bool(JourneyData.effect_is_benefit("Vortex")).is_true()
	for name: String in ["Stiffened", "Braced", "Contrary", "Stilled", "Posed"]:
		assert_bool(JourneyData.effect_is_benefit(name)).is_false()


# A legacy cursed round with no curses listed meant "the whole pool as it stood then". The axis curses
# added since must not quietly join it and change the odds of a journey nobody re-tuned.
func test_a_legacy_full_pool_round_keeps_its_old_pool() -> void:
	var cursed: Dictionary = JourneyData.normalize_effect_round({"round_type": "cursed"})
	for name: String in ["Stiffened", "Braced", "Contrary", "Stilled", "Posed"]:
		assert_array(cursed["effects"]).not_contains([name])
	assert_array(cursed["effects"]).contains(["Shrunken", "Numbed"])
	var blessed: Dictionary = JourneyData.normalize_effect_round({"round_type": "blessed"})
	assert_array(blessed["effects"]).not_contains(["Limber", "Vortex"])


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


# ── What Pose and Vortex would drive ───────────────────────────────────────


func _context(device: Array, scripted: Array, has_stroke: bool = true) -> Dictionary:
	return JourneyData.axis_context(device, scripted, false, has_stroke)


# Pose holds roll and pitch whether or not the round scripts them — it replaces the script.
func test_pose_drives_the_roll_and_pitch_the_device_has() -> void:
	assert_array(_context(SR6, ["R1", "R2"])["pose_axes"]).is_equal(["R1", "R2"])
	assert_array(_context(STROKE_ONLY, [])["pose_axes"]).is_empty()


# A script always wins, so Vortex only takes the turning axes the round leaves free — and never surge
# or sway, which would push the device diagonally.
func test_vortex_drives_only_unscripted_turning_axes() -> void:
	assert_array(_context(SR6, ["R1"])["vortex_axes"]).is_equal(["R0", "R2"])
	assert_array(_context(OSR2, [])["vortex_axes"]).is_equal(["R1", "R2"])
	assert_array(_context(SR6, ["R0", "R1", "R2"])["vortex_axes"]).is_empty()


# An e-stim alpha main track is no stroke to follow.
func test_vortex_needs_a_stroke() -> void:
	assert_array(_context(SR6, [], false)["vortex_axes"]).is_empty()


# ── Substitution ─────────────────────────────────────────────────────────────


func _motion(on: bool) -> Dictionary:
	return {"motion": on}


func test_with_axis_motion_the_axis_curse_is_kept() -> void:
	var stiffened: Dictionary = JourneyData.effect_entry("Stiffened")
	var out: Array = JourneyData.express_effects([stiffened], _motion(true))
	assert_str(str((out[0] as Dictionary)["kind"])).is_equal("axis_scale")


func test_without_it_the_named_twin_takes_its_place() -> void:
	var out: Array = JourneyData.express_effects(
		[JourneyData.effect_entry("Braced")], _motion(false)
	)
	var twin: Dictionary = out[0]
	assert_str(str(twin["kind"])).is_equal("clamp")
	assert_str(str(twin["name"])).is_equal("Choked")  # the card names a curse that exists
	assert_str(str(twin["_ref"])).is_equal("Choked")
	assert_bool(twin.has("rotary_min")).is_false()
	assert_bool(twin.has("substitute")).is_false()


# An authored axes scale with no named substitute passes on the axis scaled furthest from ×1, so a curse
# stays a curse even when the author changed only one axis.
func test_an_authored_scale_twin_takes_the_strongest_axis() -> void:
	var tuned: Dictionary = {"kind": "axis_scale", "factor_L1": 0.9, "factor_R2": 1.8}
	assert_float(float(JourneyData.stroke_twin(tuned)["factor"])).is_equal_approx(1.8, 0.0001)


func test_an_authored_clamp_twin_takes_the_narrowest_band() -> void:
	var band: Dictionary = {
		"kind": "axis_clamp", "min_L1": 30, "max_L1": 70, "min_R1": 48, "max_R1": 58
	}
	var twin: Dictionary = JourneyData.stroke_twin(band)
	assert_int(int(twin["min"])).is_equal(48)
	assert_int(int(twin["max"])).is_equal(58)
	assert_bool(twin.has("min_R1")).is_false()


# A catalog effect plays its named substitute exactly as catalogued, whatever its own or tuned values
# (owner, 2026-10-15): Stiffened is Shrunken's ×0.6, Braced is Choked's 40–60.
func test_a_catalog_twin_plays_its_substitute_as_catalogued() -> void:
	var stiffened: Dictionary = JourneyData.effect_entry("Stiffened").duplicate(true)
	stiffened["factor_R2"] = 0.2  # tuned on the round
	var shrunken: Dictionary = JourneyData.stroke_twin(stiffened)
	assert_float(float(shrunken["factor"])).is_equal_approx(0.6, 0.0001)
	var choked: Dictionary = JourneyData.stroke_twin(JourneyData.effect_entry("Braced"))
	assert_int(int(choked["min"])).is_equal(40)
	assert_int(int(choked["max"])).is_equal(60)
	assert_bool(choked.has("rotary_min")).is_false()


# ── Per-axis values ──────────────────────────────────────────────────────────


# An axis's own value wins; without one, a turning axis falls back to the group `rotary_` value older
# data carries, and everything else to the plain value — so a journey saved per group plays the same.
func test_axis_values_fall_back_through_the_group_values() -> void:
	var fx: Dictionary = {"factor": 0.6, "rotary_factor": 0.4, "factor_R2": 0.9}
	assert_float(JourneyData.axis_value(fx, "factor", "R2")).is_equal_approx(0.9, 0.0001)
	assert_float(JourneyData.axis_value(fx, "factor", "R0")).is_equal_approx(0.4, 0.0001)
	assert_float(JourneyData.axis_value(fx, "factor", "L1")).is_equal_approx(0.6, 0.0001)
	assert_float(JourneyData.axis_value({}, "max", "L2")).is_equal_approx(100.0, 0.0001)


func test_a_new_axis_modifier_is_written_per_axis() -> void:
	var scale: Dictionary = JourneyData.default_axis_modifier("axis_scale")
	assert_float(float(scale["factor_L1"])).is_equal_approx(0.6, 0.0001)
	assert_float(float(scale["factor_R1"])).is_equal_approx(0.4, 0.0001)
	var band: Dictionary = JourneyData.default_axis_modifier("axis_clamp")
	assert_int(int(band["min_R0"])).is_equal(45)
	assert_int(int(band["max_L2"])).is_equal(60)


# Raw kinds (boss forced modifiers, timeline windows) carry no catalog name, and swap by kind alone.
func test_a_raw_axis_kind_swaps_to_its_stroke_kind() -> void:
	var out: Array = JourneyData.express_effects([{"kind": "axis_block"}], _motion(false))
	assert_dict(out[0] as Dictionary).is_equal({"kind": "block"})


func test_other_effects_pass_through_untouched() -> void:
	var shrunken: Dictionary = JourneyData.effect_entry("Shrunken")
	var fog: Dictionary = JourneyData.effect_entry("Fog")
	assert_array(JourneyData.express_effects([shrunken, fog], _motion(false))).is_equal(
		[shrunken, fog]
	)


# A kept Pose carries the axes it drives, so the player needs no device profile of its own — and the
# catalog entry it came from is left untouched.
func test_a_kept_pose_is_stamped_with_its_axes() -> void:
	var posed: Dictionary = JourneyData.effect_entry("Posed")
	var out: Array = JourneyData.express_effects([posed], _context(OSR2, []))
	assert_str(str((out[0] as Dictionary)["kind"])).is_equal("pose")
	assert_array((out[0] as Dictionary)["axes"]).is_equal(["R1", "R2"])
	assert_bool(posed.has("axes")).is_false()


# A tilt means nothing on the stroke: the twin plays its substitute exactly as catalogued.
func test_pose_without_roll_or_pitch_becomes_choked() -> void:
	var out: Array = JourneyData.express_effects(
		[JourneyData.effect_entry("Posed")], _context(STROKE_ONLY, [])
	)
	var twin: Dictionary = out[0]
	var choked: Dictionary = JourneyData.effect_entry("Choked")
	assert_str(str(twin["kind"])).is_equal("clamp")
	assert_str(str(twin["name"])).is_equal("Choked")
	assert_int(int(twin["min"])).is_equal(int(choked["min"]))
	assert_int(int(twin["max"])).is_equal(int(choked["max"]))
	assert_bool(twin.has("pitch")).is_false()


func test_vortex_with_nothing_to_move_becomes_surge() -> void:
	var out: Array = JourneyData.express_effects(
		[JourneyData.effect_entry("Vortex")], _context(SR6, ["R0", "R1", "R2"])
	)
	var twin: Dictionary = out[0]
	assert_str(str(twin["kind"])).is_equal("scale")
	assert_str(str(twin["name"])).is_equal("Surge")
	assert_float(float(twin["factor"])).is_equal_approx(
		float(JourneyData.effect_entry("Surge")["factor"]), 0.0001
	)
	assert_bool(twin.has("gain")).is_false()


# A forced Pose (a raw kind, no catalog name) still lands on a real curse.
func test_a_raw_pose_falls_back_to_its_default_substitute() -> void:
	var out: Array = JourneyData.express_effects(
		[{"kind": "pose", "pitch": 10, "roll": 0}], _context(STROKE_ONLY, [])
	)
	assert_str(str((out[0] as Dictionary)["name"])).is_equal("Choked")


# Pose and Vortex create motion, so a round with no axis scripts doesn't stop them.
func test_creating_kinds_ignore_whether_the_round_has_axis_motion() -> void:
	var context: Dictionary = _context(OSR2, [])
	assert_bool(bool(context["motion"])).is_false()
	var out: Array = JourneyData.express_effects(
		[JourneyData.effect_entry("Vortex"), JourneyData.effect_entry("Stiffened")], context
	)
	assert_str(str((out[0] as Dictionary)["kind"])).is_equal("vortex")
	assert_str(str((out[1] as Dictionary)["kind"])).is_equal("scale")


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


# ── Pose and Vortex on the device ──────────────────────────────────────────


func _created(base: float, follow: float, lock: float, pose: float, pose_blend: float) -> float:
	return FunscriptPlayer.CreatedMotionPos(base, follow, lock, pose, pose_blend)


func test_pose_tilts_from_centre() -> void:
	assert_float(FunscriptPlayer.PoseTarget(25.0)).is_equal_approx(75.0, 0.0001)
	assert_float(FunscriptPlayer.PoseTarget(-50.0)).is_equal_approx(0.0, 0.0001)
	assert_float(FunscriptPlayer.PoseTarget(80.0)).is_equal_approx(100.0, 0.0001)


# Fully in, Pose replaces whatever the axis was doing; halfway, it is halfway there — the ease that
# keeps it from snapping the device to its tilt.
func test_pose_replaces_the_axis_as_it_blends_in() -> void:
	assert_float(_created(20.0, NAN, 0.0, 75.0, 1.0)).is_equal_approx(75.0, 0.0001)
	assert_float(_created(20.0, NAN, 0.0, 75.0, 0.5)).is_equal_approx(47.5, 0.0001)
	assert_float(_created(20.0, NAN, 0.0, 75.0, 0.0)).is_equal_approx(20.0, 0.0001)


# Vortex takes over from Auto Twist on the twist rather than adding to it.
func test_vortex_takes_over_from_what_was_there() -> void:
	assert_float(_created(60.0, 75.0, 1.0, NAN, 0.0)).is_equal_approx(75.0, 0.0001)
	assert_float(_created(60.0, 75.0, 0.5, NAN, 0.0)).is_equal_approx(67.5, 0.0001)


# A held axis is held: Pose wins over Vortex where both reach it.
func test_pose_wins_over_vortex() -> void:
	assert_float(_created(50.0, 90.0, 1.0, 30.0, 1.0)).is_equal_approx(30.0, 0.0001)


func test_neither_leaves_the_axis_alone() -> void:
	assert_float(_created(42.0, NAN, 1.0, NAN, 1.0)).is_equal_approx(42.0, 0.0001)


# Vortex's circle, read at a stroke that last turned at 100 and 0, at the default radius (±25).
func _circle(stroke: float, direction: int, top: float = 100.0, bottom: float = 0.0) -> Vector2:
	return FunscriptPlayer.VortexTilt(stroke, top, bottom, direction, 0.5)


# Top, side, bottom, other side: pitch rides the stroke's height, roll leans one way going down and the
# other going up.
func test_vortex_circles_once_per_down_and_up() -> void:
	assert_vector(_circle(100.0, -1)).is_equal_approx(Vector2(75, 50), Vector2(0.01, 0.01))
	assert_vector(_circle(50.0, -1)).is_equal_approx(Vector2(50, 75), Vector2(0.01, 0.01))
	assert_vector(_circle(0.0, 1)).is_equal_approx(Vector2(25, 50), Vector2(0.01, 0.01))
	assert_vector(_circle(50.0, 1)).is_equal_approx(Vector2(50, 25), Vector2(0.01, 0.01))


# Every point is on the circle, so the tip travels round it rather than cutting corners.
func test_vortex_stays_on_its_circle() -> void:
	for stroke: float in [10.0, 30.0, 70.0, 90.0]:
		var p: Vector2 = _circle(stroke, -1) - Vector2(50, 50)
		assert_float(p.length()).is_equal_approx(25.0, 0.01)


# A shallow stroke is measured between its own turns, so it still makes a whole loop.
func test_a_shallow_stroke_still_makes_a_whole_loop() -> void:
	assert_vector(_circle(60.0, -1, 60.0, 40.0)).is_equal_approx(
		Vector2(75, 50), Vector2(0.01, 0.01)
	)
	assert_vector(_circle(50.0, -1, 60.0, 40.0)).is_equal_approx(
		Vector2(50, 75), Vector2(0.01, 0.01)
	)


# Before the stroke has moved far enough to have a direction, roll stays at centre.
func test_no_lean_before_the_stroke_has_a_direction() -> void:
	assert_float(_circle(50.0, 0).y).is_equal_approx(50.0, 0.01)


# On the device each axis reads its own value: pitch scaled alone leaves roll untouched.
func test_one_axis_scaled_alone() -> void:
	var fx: Array = [{"kind": "axis_scale", "factor_R2": 0.5}]
	assert_float(_mod("R2", 100.0, fx)).is_equal_approx(75.0, 0.0001)
	assert_float(_mod("R1", 100.0, fx)).is_equal_approx(100.0, 0.0001)


func test_one_axis_clamped_alone() -> void:
	var fx: Array = [{"kind": "axis_clamp", "min_L1": 40, "max_L1": 60}]
	assert_float(_mod("L1", 100.0, fx)).is_equal_approx(60.0, 0.0001)
	assert_float(_mod("L2", 100.0, fx)).is_equal_approx(100.0, 0.0001)
