extends GdUnitTestSuite

# Device profile — the player's declared axes (MULTIAXIS_DESIGN.md §2). Everything that decides by
# hardware (multi-axis curses, items, the catalogue filter, Auto Twist) reads these, so a wrong answer
# here means curses the player can't feel.

const BUTTPLUG_LINEAR: String = "Launch#0:linear:0"

# ── Presets ──────────────────────────────────────────────────────────────────


# The owner-confirmed table. A change here is a change to what every player is offered.
func test_each_preset_holds_the_agreed_axes() -> void:
	assert_array(DeviceProfile.declared_axes(DeviceProfile.STROKE_ONLY)).contains_exactly(["L0"])
	assert_array(DeviceProfile.declared_axes(DeviceProfile.OSR2)).contains_exactly(
		["L0", "R1", "R2"]
	)
	assert_array(DeviceProfile.declared_axes(DeviceProfile.OSR2_TWIST)).contains_exactly(
		["L0", "R0", "R1", "R2"]
	)
	assert_array(DeviceProfile.declared_axes(DeviceProfile.SR6)).contains_exactly(
		["L0", "L1", "L2", "R0", "R1", "R2"]
	)


# The safe failure: a player who never opens Options is offered only what a stroker can play.
func test_the_default_is_stroke_only() -> void:
	assert_str(DeviceProfile.DEFAULT).is_equal(DeviceProfile.STROKE_ONLY)


func test_every_preset_has_the_stroke() -> void:
	for preset: Dictionary in DeviceProfile.PRESETS:
		assert_bool((preset["axes"] as Array).has("L0")).is_true()


# Only the OSR2 + twist and SR6 presets unlock Auto Twist; the plain OSR2 has no twist servo.
func test_only_the_twist_presets_have_twist() -> void:
	assert_bool(DeviceProfile.declared_axes(DeviceProfile.OSR2).has("R0")).is_false()
	assert_bool(DeviceProfile.declared_axes(DeviceProfile.OSR2_TWIST).has("R0")).is_true()
	assert_bool(DeviceProfile.declared_axes(DeviceProfile.SR6).has("R0")).is_true()


# A hand-edited file or a preset removed later still leaves the stroke — never an empty device.
func test_an_unknown_profile_reads_as_the_default() -> void:
	assert_array(DeviceProfile.declared_axes("sr12")).contains_exactly(["L0"])
	assert_array(DeviceProfile.declared_axes("")).contains_exactly(["L0"])


# Callers get their own list; changing it must not change the preset for everyone else.
func test_declared_axes_is_a_copy() -> void:
	var axes: Array = DeviceProfile.declared_axes(DeviceProfile.OSR2)
	axes.append("R0")
	assert_bool(DeviceProfile.declared_axes(DeviceProfile.OSR2).has("R0")).is_false()


# ── Dropdown ↔ saved id ──────────────────────────────────────────────────────


# Options builds the dropdown from PRESETS and saves by id, so the two directions must agree.
func test_dropdown_position_and_id_round_trip() -> void:
	for i: int in DeviceProfile.PRESETS.size():
		assert_int(DeviceProfile.index_of(DeviceProfile.id_at(i))).is_equal(i)


func test_an_out_of_range_position_reads_as_the_default() -> void:
	assert_str(DeviceProfile.id_at(-1)).is_equal(DeviceProfile.DEFAULT)
	assert_str(DeviceProfile.id_at(99)).is_equal(DeviceProfile.DEFAULT)


func test_an_unknown_id_has_no_position() -> void:
	assert_int(DeviceProfile.index_of("sr12")).is_equal(-1)


# ── Only serial carries the other axes ───────────────────────────────────────


func test_on_serial_the_profile_counts_as_declared() -> void:
	(
		assert_array(DeviceProfile.effective_axes(DeviceProfile.SR6, DeviceRouting.SERIAL_TARGET))
		. contains_exactly(["L0", "L1", "L2", "R0", "R1", "R2"])
	)
	assert_bool(DeviceProfile.is_limited_by_target(DeviceRouting.SERIAL_TARGET)).is_false()


# An SR6 owner playing on their Handy tonight must not roll curses the Handy can't play.
func test_off_serial_every_profile_counts_as_stroke_only() -> void:
	for target: String in [DeviceRouting.HANDY_TARGET, BUTTPLUG_LINEAR, ""]:
		for preset: Dictionary in DeviceProfile.PRESETS:
			assert_array(DeviceProfile.effective_axes(str(preset["id"]), target)).contains_exactly(
				["L0"]
			)
		assert_bool(DeviceProfile.is_limited_by_target(target)).is_true()
