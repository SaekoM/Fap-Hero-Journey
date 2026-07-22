extends GdUnitTestSuite

# UITheme pure helpers — currently the tooltip word-wrap.


func _lines(s: String) -> Array:
	return s.split("\n")


# A short string is returned untouched — short tooltips must not gain stray newlines.
func test_wrap_tip_leaves_short_text() -> void:
	assert_str(UITheme.wrap_tip("Delete this choice")).is_equal("Delete this choice")


# A long line is broken on word boundaries, and no line exceeds the limit.
func test_wrap_tip_breaks_long_line() -> void:
	var text := "Reveal the map as the player plays: visited nodes shown in full, the steps ahead ghosted."
	var wrapped: String = UITheme.wrap_tip(text, 30)
	for line: String in _lines(wrapped):
		assert_int(line.length()).is_less_equal(30)
	# No content lost — the words survive, only spaces became newlines.
	assert_str(wrapped.replace("\n", " ")).is_equal(text)


# Existing newlines are preserved (each paragraph wrapped on its own) — this is what keeps the
# item tooltips' name / description / facts on separate lines.
func test_wrap_tip_preserves_newlines() -> void:
	var text := "Bail Out\nEnds the current round immediately with no reward whatsoever here.\n♦70"
	var wrapped: String = UITheme.wrap_tip(text, 40)
	assert_str(_lines(wrapped)[0]).is_equal("Bail Out")  # first line untouched
	assert_str(_lines(wrapped)[-1]).is_equal("♦70")  # last line untouched
	assert_int(_lines(wrapped).size()).is_greater(3)  # the middle line split


# A single word longer than the limit is kept whole rather than dropped or split mid-word.
func test_wrap_tip_keeps_oversized_word() -> void:
	assert_str(UITheme.wrap_tip("supercalifragilisticexpialidocious", 10)).is_equal(
		"supercalifragilisticexpialidocious"
	)
