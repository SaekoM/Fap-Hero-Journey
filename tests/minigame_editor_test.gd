extends GdUnitTestSuite

# The pure parts of the builder's mini-game editor.


func test_a_rewards_summary_lists_what_a_tier_does() -> void:
	var summary: String = (
		MiniGameEditor
		. rewards_summary(
			{
				"coins": 20,
				"item": "key",
				"remove_items": ["map", "rope"],
				"set_flags": ["opened"],
				"clear_flags": ["locked"],
				"set_counters": {"grit": 1},
				"score": 50,
			}
		)
	)
	assert_str(summary).is_equal("♦ +20 · + item · − 2 items · ⚑ 2 · 🔢 1 · score +50")


func test_an_empty_rewards_summary_says_nothing() -> void:
	assert_str(MiniGameEditor.rewards_summary({})).is_equal("nothing")
	assert_str(MiniGameEditor.rewards_summary({"coins": -5})).is_equal("♦ -5")
