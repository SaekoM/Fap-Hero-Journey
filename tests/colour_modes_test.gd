extends GdUnitTestSuite

# Colour modes, phase 1 (COLOUR_MODES_DESIGN.md): every mode's palette is complete and readable, and
# switching applies it. Whether the colours stay apart for each kind of colour blindness was checked
# under simulation when they were chosen (the palette preview); these pin what can be checked here.


func after_test() -> void:
	UITheme.set_colour_mode(UITheme.COLOUR_MODE_OFF)  # the mode is app-wide; leave it as found


func _ratio(color: Color, background: Color = UITheme.PANEL_BG) -> float:
	return UITheme.contrast_ratio(color, background)


# ── Palettes ─────────────────────────────────────────────────────────────────


func test_every_mode_has_a_name_and_a_complete_palette() -> void:
	for mode: String in UITheme.COLOUR_MODES:
		assert_bool(UITheme.COLOUR_MODE_NAMES.has(mode)).is_true()
		var palette: Dictionary = UITheme.PALETTES[mode]
		for key: String in [
			"ok",
			"success",
			"warning",
			"error",
			"error_soft",
			"info",
			"curse",
			"boon",
			"gain",
			"loss",
			"coin",
		]:
			(
				assert_bool(palette.has(key))
				. override_failure_message("%s lacks %s" % [mode, key])
				. is_true()
			)
		assert_int((palette["intensity"] as Array).size()).is_equal(5)
		assert_int((palette["difficulty"] as Array).size()).is_equal(
			JourneyData.DIFFICULTIES.size()
		)


func test_text_is_readable_in_every_mode() -> void:
	for mode: String in UITheme.COLOUR_MODES:
		var text: Dictionary = UITheme.PALETTES[mode]["text"]
		for key: String in ["text", "hint", "purple_text", "dark_text"]:
			for background: Color in [UITheme.PANEL_BG, UITheme.CARD_BG]:
				(
					assert_float(_ratio(text[key], background))
					. override_failure_message("%s %s" % [mode, key])
					. is_greater_equal(UITheme.MIN_TEXT_CONTRAST)
				)


# Status colours are text (status lines), so they need text contrast.
func test_status_colours_are_readable_as_text() -> void:
	for mode: String in UITheme.COLOUR_MODES:
		for key: String in [
			"ok", "success", "warning", "error", "error_soft", "info", "gain", "loss", "coin"
		]:
			(
				assert_float(_ratio(UITheme.PALETTES[mode][key]))
				. override_failure_message("%s %s" % [mode, key])
				. is_greater_equal(UITheme.MIN_TEXT_CONTRAST)
			)


# Difficulty colours are pill text; intensity steps and curse/boon are shapes and frames.
func test_scales_and_pairs_are_visible() -> void:
	for mode: String in UITheme.COLOUR_MODES:
		var palette: Dictionary = UITheme.PALETTES[mode]
		for step: Color in palette["difficulty"]:
			assert_float(_ratio(step)).override_failure_message(mode).is_greater_equal(
				UITheme.MIN_TEXT_CONTRAST
			)
		for step: Color in palette["intensity"] + [palette["curse"], palette["boon"]]:
			assert_float(_ratio(step)).override_failure_message(mode).is_greater_equal(
				UITheme.MIN_UI_CONTRAST
			)


func test_control_edges_and_focus_are_visible_in_every_mode() -> void:
	for mode: String in UITheme.COLOUR_MODES:
		var text: Dictionary = UITheme.PALETTES[mode]["text"]
		for key: String in ["border", "focus"]:
			for background: Color in [UITheme.PANEL_BG, UITheme.PURPLE_DARK]:
				(
					assert_float(_ratio(text[key], background))
					. override_failure_message("%s %s" % [mode, key])
					. is_greater_equal(UITheme.MIN_UI_CONTRAST)
				)


# Off is today's look made readable: the status colours are exactly the ones the game shipped with.
func test_off_keeps_todays_status_colours() -> void:
	var off: Dictionary = UITheme.PALETTES[UITheme.COLOUR_MODE_OFF]
	assert_that(off["ok"]).is_equal(Color(0.35, 0.95, 0.35))
	assert_that(off["success"]).is_equal(Color(0.3, 1.0, 0.5))
	assert_that(off["error"]).is_equal(Color(1.0, 0.25, 0.05))
	assert_that(off["error_soft"]).is_equal(Color(1.0, 0.3, 0.3))


# ── Switching ────────────────────────────────────────────────────────────────


func test_switching_applies_the_palette() -> void:
	UITheme.set_colour_mode(UITheme.COLOUR_MODE_RED_GREEN)
	var palette: Dictionary = UITheme.PALETTES[UITheme.COLOUR_MODE_RED_GREEN]
	assert_str(UITheme.colour_mode).is_equal(UITheme.COLOUR_MODE_RED_GREEN)
	assert_that(UITheme.OK).is_equal(palette["ok"])
	assert_that(UITheme.SUCCESS).is_equal(palette["success"])
	assert_that(UITheme.ERROR_SOFT).is_equal(palette["error_soft"])
	assert_that(UITheme.STATUS_WARNING).is_equal(palette["warning"])
	assert_that(UITheme.PAIR_CURSE).is_equal(palette["curse"])
	assert_that(UITheme.SCALE_INTENSITY[4]).is_equal(palette["intensity"][4])


func test_high_contrast_changes_text_and_edges() -> void:
	UITheme.set_colour_mode(UITheme.COLOUR_MODE_HIGH_CONTRAST)
	assert_bool(UITheme.is_high_contrast()).is_true()
	assert_that(UITheme.WHITE_SOFT).is_equal(Color("#ffffff"))
	assert_that(UITheme.BORDER).is_equal(Color("#d9d9d9"))
	UITheme.set_colour_mode(UITheme.COLOUR_MODE_OFF)
	assert_that(UITheme.WHITE_SOFT).is_equal(Color(0.878, 0.780, 1.0))


func test_an_unknown_mode_reads_as_off() -> void:
	UITheme.set_colour_mode("sepia")
	assert_str(UITheme.colour_mode).is_equal(UITheme.COLOUR_MODE_OFF)


func test_switching_tells_listeners() -> void:
	var heard: Array = []
	var listener: Callable = func(mode: String) -> void: heard.append(mode)
	UITheme.colour_mode_changed.connect(listener)
	UITheme.set_colour_mode(UITheme.COLOUR_MODE_BLUE_YELLOW)
	UITheme.colour_mode_changed.disconnect(listener)
	assert_array(heard).is_equal([UITheme.COLOUR_MODE_BLUE_YELLOW])


func test_scale_step_spans_the_scale() -> void:
	var scale: Array = UITheme.SCALE_INTENSITY
	assert_that(UITheme.scale_step(scale, 0.0)).is_equal(scale[0])
	assert_that(UITheme.scale_step(scale, 1.0)).is_equal(scale[4])
	assert_that(UITheme.scale_step(scale, 0.5)).is_equal(scale[2])
	assert_that(UITheme.scale_step(scale, 7.0)).is_equal(scale[4])


# ── Helpers the screens use ──────────────────────────────────────────────────


func test_difficulty_colours_follow_the_scale() -> void:
	UITheme.set_colour_mode(UITheme.COLOUR_MODE_RED_GREEN)
	for i: int in JourneyData.DIFFICULTIES.size():
		assert_that(UITheme.difficulty_color(JourneyData.DIFFICULTIES[i])).is_equal(
			UITheme.SCALE_DIFFICULTY[i]
		)
	assert_that(UITheme.difficulty_color("Nightmare")).is_equal(UITheme.WHITE_SOFT)


# Legacy cursed and blessed rounds were baked with a pair red-green colour blindness can't tell apart;
# those take the mode's pair. Any other author colour is left alone.
func test_legacy_curse_and_boon_frames_take_the_modes_pair() -> void:
	UITheme.set_colour_mode(UITheme.COLOUR_MODE_RED_GREEN)
	var hinder: Color = Color.html(JourneyData.EFFECT_COLOR_HINDER)
	var boon: Color = Color.html(JourneyData.EFFECT_COLOR_BOON)
	assert_that(UITheme.effect_colour(hinder)).is_equal(UITheme.PAIR_CURSE)
	assert_that(UITheme.effect_colour(boon)).is_equal(UITheme.PAIR_BOON)
	var authors: Color = Color.html("#3366ff")
	assert_that(UITheme.effect_colour(authors)).is_equal(authors)
