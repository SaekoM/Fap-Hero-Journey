extends GdUnitTestSuite

# Forks with any number of choices: cards up to ForkScreen.CARD_LAYOUT_MOST, a list with a preview past that, the
# names new choices start with, and the version floor a long fork stamps.

const ForkScene = preload("res://scenes/fork_screen/ForkScreen.tscn")


func _paths(count: int) -> Array:
	var paths: Array = []
	for i: int in count:
		paths.append({"name": "Choice %d" % (i + 1), "round_count": 2})
	return paths


func _fork_screen(choice_count: int) -> ForkScreen:
	var screen: ForkScreen = auto_free(ForkScene.instantiate())
	add_child(screen)
	screen.setup({"title": "Which way", "resolution": "choice", "paths": _paths(choice_count)})
	return screen


func test_up_to_six_choices_are_cards() -> void:
	var screen: ForkScreen = _fork_screen(ForkScreen.CARD_LAYOUT_MOST)
	assert_bool(screen._is_list_layout()).is_false()
	assert_array(screen._list_rows).is_empty()
	assert_int(screen._cards_row.get_child_count()).is_equal(ForkScreen.CARD_LAYOUT_MOST)


func test_more_than_six_become_a_list_with_one_card_previewed() -> void:
	var screen: ForkScreen = _fork_screen(ForkScreen.CARD_LAYOUT_MOST + 3)
	assert_bool(screen._is_list_layout()).is_true()
	assert_int(screen._list_rows.size()).is_equal(ForkScreen.CARD_LAYOUT_MOST + 3)
	var showing: Array = screen._cards.filter(func(card: Control) -> bool: return card.visible)
	assert_int(showing.size()).is_equal(1)
	assert_int(screen._selected).is_equal(0)


# A click focuses its row and presses it in one go: the first only selects it, the next one chooses.
func test_the_first_press_on_a_row_selects_and_the_next_chooses() -> void:
	var screen: ForkScreen = _fork_screen(9)
	await await_idle_frame()  # the list focuses its first row a frame after it opens, which selects it
	var chosen: Array[int] = []
	screen.path_chosen.connect(func(index: int) -> void: chosen.append(index))
	screen._list_rows[4].pressed.emit()
	assert_int(screen._selected).is_equal(4)
	assert_bool((screen._cards[4] as Control).visible).is_true()
	assert_array(chosen).is_empty()
	await await_idle_frame()
	screen._list_rows[4].pressed.emit()
	assert_array(chosen).is_equal([4])


func test_a_reveal_lands_on_its_choice_in_a_bounded_roll() -> void:
	for n: int in [2, 4, 6, 7, 12, 40]:
		for index: int in n:
			var roll: Vector2i = ForkScreen.reveal_roll(n, index)
			assert_int((roll.x + roll.y) % n).is_equal(index)
			assert_int(roll.y).is_less_equal(ForkScreen.REVEAL_MOST_STEPS)
	# A small fork rolls exactly as it always has: three times round from the first card.
	assert_bool(ForkScreen.reveal_roll(4, 2) == Vector2i(0, 14)).is_true()


func test_new_choices_are_lettered_then_numbered() -> void:
	assert_str(JourneyData.default_fork_choice_name(0)).is_equal("Path A")
	assert_str(JourneyData.default_fork_choice_name(25)).is_equal("Path Z")
	assert_str(JourneyData.default_fork_choice_name(26)).is_equal("Path 27")


func test_a_fork_with_more_choices_than_older_builds_could_show_needs_0_9_3() -> void:
	var fork_with: Callable = func(choice_count: int) -> Dictionary:
		var out: Array = []
		for i: int in choice_count:
			out.append({"to": ""})
		return {"nodes": {"f": {"type": "fork", "data": {}, "out": out}}}
	var most: int = JourneyData.OLDER_BUILDS_FORK_CHOICES
	assert_bool(JourneyData.graph_needs_newer_build(fork_with.call(most), [])).is_false()
	assert_bool(JourneyData.graph_needs_newer_build(fork_with.call(most + 1), [])).is_true()
