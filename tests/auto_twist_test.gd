extends GdUnitTestSuite

# Auto Twist — R0 synthesised from the stroke for content with no twist script (MULTIAXIS_DESIGN.md §1).
# The model is one line, `twist = 50 + gain × (stroke − 50)`, held to a per-tick speed ceiling. These
# pin that line and the step → gain mapping; how it FEELS can only be judged on hardware.

const SUBTLE: float = 0.1
const MEDIUM: float = 0.5
const STRONG: float = 1.0
const NO_CAP: float = 0.0


func _step(stroke: float, previous: float, gain: float, max_delta: float = NO_CAP) -> float:
	return FunscriptPlayer.AutoTwistStep(stroke, previous, gain, max_delta)


# ── The model ────────────────────────────────────────────────────────────────


func test_centre_stays_centre_at_every_step() -> void:
	for gain: float in [0.0, SUBTLE, MEDIUM, STRONG]:
		assert_float(_step(50.0, 50.0, gain)).is_equal_approx(50.0, 0.0001)


# The steps are defined as the swing either side of centre at a full 0–100 stroke.
func test_a_full_stroke_swings_the_advertised_amount_either_side() -> void:
	assert_float(_step(100.0, 50.0, SUBTLE)).is_equal_approx(55.0, 0.0001)
	assert_float(_step(0.0, 50.0, SUBTLE)).is_equal_approx(45.0, 0.0001)
	assert_float(_step(100.0, 50.0, MEDIUM)).is_equal_approx(75.0, 0.0001)
	assert_float(_step(0.0, 50.0, MEDIUM)).is_equal_approx(25.0, 0.0001)
	assert_float(_step(100.0, 50.0, STRONG)).is_equal_approx(100.0, 0.0001)
	assert_float(_step(0.0, 50.0, STRONG)).is_equal_approx(0.0, 0.0001)


func test_off_holds_centre_whatever_the_stroke_does() -> void:
	for stroke: float in [0.0, 20.0, 80.0, 100.0]:
		assert_float(_step(stroke, 50.0, 0.0)).is_equal_approx(50.0, 0.0001)


# Twist scales with how far the stroke travels — a shallow stroke gets a hint, a deep one the full swing.
func test_twist_scales_linearly_with_stroke_travel() -> void:
	assert_float(_step(60.0, 50.0, MEDIUM)).is_equal_approx(55.0, 0.0001)
	assert_float(_step(70.0, 50.0, MEDIUM)).is_equal_approx(60.0, 0.0001)
	assert_float(_step(40.0, 50.0, MEDIUM)).is_equal_approx(45.0, 0.0001)


# The twist moves the same way as the stroke, so it alternates exactly when the stroke does — up-stroke
# twists one way, down-stroke unwinds. No separate direction state to get out of step.
func test_twist_turns_where_the_stroke_turns() -> void:
	var up: float = _step(90.0, 50.0, MEDIUM)
	var down: float = _step(10.0, up, MEDIUM)
	assert_float(up).is_greater(50.0)
	assert_float(down).is_less(50.0)


# ── The speed ceiling ────────────────────────────────────────────────────────


func test_the_ceiling_trims_a_jump_bigger_than_it_allows() -> void:
	assert_float(_step(100.0, 50.0, STRONG, 4.0)).is_equal_approx(54.0, 0.0001)
	assert_float(_step(0.0, 50.0, STRONG, 4.0)).is_equal_approx(46.0, 0.0001)


func test_the_ceiling_leaves_an_ordinary_move_alone() -> void:
	assert_float(_step(52.0, 50.0, STRONG, 4.0)).is_equal_approx(52.0, 0.0001)


# The reason this model replaced the per-stroke one: nothing accumulates. A tick the ceiling trims just
# lags, and once the stroke settles the twist arrives exactly where the formula says — no residual offset.
func test_a_trimmed_twist_catches_up_and_never_drifts() -> void:
	var twist: float = 50.0
	for _i: int in 10:
		twist = _step(100.0, twist, STRONG, 10.0)
	assert_float(twist).is_equal_approx(100.0, 0.0001)
	for _i: int in 10:
		twist = _step(50.0, twist, STRONG, 10.0)
	assert_float(twist).is_equal_approx(50.0, 0.0001)


# The exact failure the per-stroke model had: fast up-strokes trimmed by the ceiling, slow down-strokes
# not, so every cycle lost ground in one direction until the twist pinned at a rail. Here an untrimmed
# stroke simply lands where the formula says, so there is no ground to lose.
func test_trimming_one_direction_only_cannot_walk_the_twist_off() -> void:
	var twist: float = 50.0
	for _stroke: int in 20:
		twist = _step(100.0, twist, STRONG, 7.0)  # fast up-stroke: trimmed
		twist = _step(0.0, twist, STRONG, NO_CAP)  # slow down-stroke: untouched
	assert_float(twist).is_equal_approx(0.0, 0.0001)  # exactly where the stroke is, not beyond it
	for _settle: int in 20:
		twist = _step(50.0, twist, STRONG, 7.0)
	assert_float(twist).is_equal_approx(50.0, 0.0001)


# ── Bounds ───────────────────────────────────────────────────────────────────


# Full 0–100 space, never more. The player's own R0 window is applied once, afterwards — clamping to it
# here too would compress the motion twice.
func test_output_never_leaves_the_axis() -> void:
	assert_float(_step(140.0, 50.0, STRONG)).is_equal_approx(100.0, 0.0001)
	assert_float(_step(-40.0, 50.0, STRONG)).is_equal_approx(0.0, 0.0001)


func test_no_ceiling_means_the_full_move_in_one_tick() -> void:
	assert_float(_step(100.0, 0.0, STRONG, NO_CAP)).is_equal_approx(100.0, 0.0001)


# ── Full travel, whatever the stroke range ────────────────────────────────
# The stroke Auto Twist reads has already been fitted into the player's Stroke Range. That range is for
# the stroke; the twist has its own (R0). Undoing the stroke fit is what lets Strong reach 0 and 100.


func _unfit(sent: float, range_min: int, range_max: int) -> float:
	return FunscriptPlayer.StrokeInScriptSpace(sent, range_min, range_max)


func test_a_full_stroke_range_is_left_alone() -> void:
	assert_float(_unfit(0.0, 0, 100)).is_equal_approx(0.0, 0.0001)
	assert_float(_unfit(37.0, 0, 100)).is_equal_approx(37.0, 0.0001)
	assert_float(_unfit(100.0, 0, 100)).is_equal_approx(100.0, 0.0001)


func test_a_narrowed_stroke_range_is_taken_back_out() -> void:
	assert_float(_unfit(20.0, 20, 80)).is_equal_approx(0.0, 0.0001)
	assert_float(_unfit(50.0, 20, 80)).is_equal_approx(50.0, 0.0001)
	assert_float(_unfit(80.0, 20, 80)).is_equal_approx(100.0, 0.0001)


# The question this section exists to answer: with the stroke range narrowed to 20–80, does Strong still
# reach both ends of R0's travel? Before the fix it stopped at 20 and 80.
func test_strong_reaches_both_ends_through_a_narrowed_stroke_range() -> void:
	assert_float(_step(_unfit(80.0, 20, 80), 50.0, STRONG)).is_equal_approx(100.0, 0.0001)
	assert_float(_step(_unfit(20.0, 20, 80), 50.0, STRONG)).is_equal_approx(0.0, 0.0001)


# A zero-width range carries no stroke at all, so there is nothing to twist with — not a division by zero.
func test_a_zero_width_stroke_range_twists_nothing() -> void:
	assert_float(_unfit(50.0, 50, 50)).is_equal_approx(50.0, 0.0001)


# ── Steps → gains ────────────────────────────────────────────────────────────


func test_each_named_step_has_its_gain() -> void:
	assert_float(SettingsService.auto_twist_gain(0)).is_equal_approx(0.0, 0.0001)
	assert_float(SettingsService.auto_twist_gain(1)).is_equal_approx(SUBTLE, 0.0001)
	assert_float(SettingsService.auto_twist_gain(2)).is_equal_approx(MEDIUM, 0.0001)
	assert_float(SettingsService.auto_twist_gain(3)).is_equal_approx(STRONG, 0.0001)


# A saved step that no longer exists reads as Off, never as whatever gain happens to sit at that index.
func test_an_unknown_step_is_off() -> void:
	assert_float(SettingsService.auto_twist_gain(-1)).is_equal_approx(0.0, 0.0001)
	assert_float(SettingsService.auto_twist_gain(99)).is_equal_approx(0.0, 0.0001)


# Options builds its dropdown from the step names and indexes the gains by the same number.
func test_step_names_and_gains_line_up() -> void:
	assert_int(SettingsService.AUTO_TWIST_STEPS.size()).is_equal(
		SettingsService.AUTO_TWIST_GAINS.size()
	)
	assert_str(str(SettingsService.AUTO_TWIST_STEPS[0])).is_equal("Off")
