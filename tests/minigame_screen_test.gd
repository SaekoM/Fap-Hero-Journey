extends GdUnitTestSuite

# The pure text helpers of the mini-game play screen: what a tier pays and what a retry costs, in the
# player's words.


func test_rewards_are_described_in_the_players_words() -> void:
	assert_str(MiniGameScreen.describe_rewards({"coins": 20, "score": 50})).is_equal(
		"+♦ 20 · +50 score"
	)
	assert_str(MiniGameScreen.describe_rewards({"coins": -15})).is_equal("−♦ 15")


# Flags and counters are story state: the player isn't told about them.
func test_story_state_is_not_spoken() -> void:
	(
		assert_str(
			MiniGameScreen.describe_rewards({"set_flags": ["opened"], "set_counters": {"grit": 1}})
		)
		. is_equal("")
	)


func test_a_free_retry_has_no_cost_text() -> void:
	assert_str(MiniGameScreen.describe_cost({})).is_equal("")
	assert_str(MiniGameScreen.describe_cost({"coins": 25})).is_equal("−♦ 25")
