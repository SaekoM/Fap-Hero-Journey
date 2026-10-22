extends GdUnitTestSuite

# Phase 0 of the colour modes (COLOUR_MODES_DESIGN.md): text and controls readable on the dark panels.
# WCAG asks 4.5:1 for text and 3:1 for control edges. These pin the measuring stick, the readable
# colours, and the lift that UITheme's style helpers apply.


func _ratio(a: Color, b: Color) -> float:
	return UITheme.contrast_ratio(a, b)


# ── The measuring stick ──────────────────────────────────────────────────────


func test_black_on_white_is_21_and_a_colour_on_itself_is_1() -> void:
	assert_float(_ratio(Color.BLACK, Color.WHITE)).is_equal_approx(21.0, 0.01)
	assert_float(_ratio(UITheme.PANEL_BG, UITheme.PANEL_BG)).is_equal_approx(1.0, 0.001)


func test_order_does_not_matter() -> void:
	assert_float(_ratio(UITheme.WHITE_SOFT, UITheme.PANEL_BG)).is_equal_approx(
		_ratio(UITheme.PANEL_BG, UITheme.WHITE_SOFT), 0.0001
	)


# ── The readable colours ─────────────────────────────────────────────────────


func test_text_colours_pass_on_every_panel() -> void:
	for text: Color in [
		UITheme.TEXT_HINT, UITheme.PURPLE_TEXT, UITheme.WHITE_SOFT, UITheme.DARK_TEXT
	]:
		for panel: Color in [UITheme.PANEL_BG, UITheme.CARD_BG, UITheme.BG]:
			assert_float(_ratio(text, panel)).is_greater_equal(UITheme.MIN_TEXT_CONTRAST)


# Text on a control's dark fill (buttons, inputs, dropdowns).
func test_text_colours_pass_on_the_control_fill() -> void:
	for text: Color in [UITheme.TEXT_HINT, UITheme.PURPLE_TEXT, UITheme.WHITE_SOFT]:
		assert_float(_ratio(text, UITheme.PURPLE_DARK)).is_greater_equal(UITheme.MIN_TEXT_CONTRAST)


func test_control_edges_and_focus_pass() -> void:
	for edge: Color in [UITheme.BORDER, UITheme.FOCUS_RING]:
		assert_float(_ratio(edge, UITheme.PANEL_BG)).is_greater_equal(UITheme.MIN_UI_CONTRAST)
		assert_float(_ratio(edge, UITheme.PURPLE_DARK)).is_greater_equal(UITheme.MIN_UI_CONTRAST)


# What phase 0 replaced really was unreadable — the reason for all of this.
func test_the_old_text_colours_failed() -> void:
	var hint_as_drawn: Color = UITheme.PANEL_BG.lerp(
		Color(UITheme.SEPARATOR, 1.0), UITheme.SEPARATOR.a
	)
	assert_float(_ratio(hint_as_drawn, UITheme.PANEL_BG)).is_less(3.0)
	assert_float(_ratio(UITheme.PURPLE_MID, UITheme.PANEL_BG)).is_less(3.0)


# ── The lift ─────────────────────────────────────────────────────────────────


func test_a_readable_colour_is_left_alone() -> void:
	assert_that(UITheme.readable(UITheme.WHITE_SOFT, UITheme.PANEL_BG)).is_equal(UITheme.WHITE_SOFT)
	assert_that(UITheme.readable(UITheme.CYAN, UITheme.PANEL_BG)).is_equal(UITheme.CYAN)


func test_a_dim_colour_is_lifted_to_readable() -> void:
	var lifted: Color = UITheme.readable(UITheme.PURPLE_MID, UITheme.PANEL_BG)
	assert_float(_ratio(lifted, UITheme.PANEL_BG)).is_greater_equal(UITheme.MIN_TEXT_CONTRAST)


# A half-transparent colour is judged as it's drawn, over the background.
func test_transparency_is_judged_as_drawn() -> void:
	var lifted: Color = UITheme.readable(UITheme.SEPARATOR, UITheme.PANEL_BG)
	assert_float(lifted.a).is_equal(1.0)
	assert_float(_ratio(lifted, UITheme.PANEL_BG)).is_greater_equal(UITheme.MIN_TEXT_CONTRAST)


# Control edges only need 3:1, so they're lifted less than text would be.
func test_edges_lift_to_their_own_minimum() -> void:
	var edge: Color = UITheme.readable(
		UITheme.PURPLE_MID, UITheme.PANEL_BG, UITheme.MIN_UI_CONTRAST
	)
	var ratio: float = _ratio(edge, UITheme.PANEL_BG)
	assert_float(ratio).is_greater_equal(UITheme.MIN_UI_CONTRAST)
	assert_float(ratio).is_less(UITheme.MIN_TEXT_CONTRAST)


# Black text is meant for a bright fill; lifting it toward white would wreck it.
func test_dark_text_meant_for_a_light_fill_is_left_alone() -> void:
	assert_that(UITheme.readable(UITheme.BG, UITheme.PANEL_BG)).is_equal(UITheme.BG)


func test_text_on_a_fill_picks_the_better_of_black_and_white() -> void:
	assert_that(UITheme.text_on(UITheme.AMBER)).is_equal(UITheme.BG)
	assert_that(UITheme.text_on(UITheme.PURPLE_MID)).is_equal(UITheme.WHITE_SOFT)
