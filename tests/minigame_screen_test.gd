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


# RETRY removes the result card while its coins may still be counting up, so the count has to stop with its label.
func test_a_reveal_stops_when_its_label_goes() -> void:
	var screen: MiniGameScreen = auto_free(MiniGameScreen.new())
	add_child(screen)
	# After add_child: Godot switches processing back on when the node is ready, and a bare screen has no countdown.
	screen.set_process(false)
	var counting: Label = Label.new()
	screen.add_child(counting)
	screen._reveal_rewards(counting, {"coins": 20})
	var staggering: Label = Label.new()
	screen.add_child(staggering)
	screen._reveal_rewards(staggering, {"score": 50, "item": "", "coins": 0})
	counting.free()
	staggering.free()
	await await_millis(
		int((MiniGameScreen.COUNT_UP_SECS + MiniGameScreen.REWARD_STAGGER_SECS) * 1000.0) + 100
	)
	assert_bool(is_instance_valid(screen)).is_true()
	remove_child(screen)


func test_a_free_retry_has_no_cost_text() -> void:
	assert_str(MiniGameScreen.describe_cost({})).is_equal("")
	assert_str(MiniGameScreen.describe_cost({"coins": 25})).is_equal("−♦ 25")
