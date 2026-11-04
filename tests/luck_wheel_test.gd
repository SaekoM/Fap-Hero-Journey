extends GdUnitTestSuite

# Double or Nothing's wheel: the slices show the real odds, and the wheel rests on the result it was told.


func _win_share(slice_list: Array[Dictionary]) -> float:
	var share: float = 0.0
	for slice: Dictionary in slice_list:
		if bool(slice["win"]):
			share += float(slice["end"]) - float(slice["start"])
	return share


func test_win_slices_cover_exactly_the_odds() -> void:
	for odds: int in [10, 35, 50, 90]:
		assert_float(_win_share(LuckWheel.slices(odds))).is_equal_approx(odds / 100.0, 0.0001)


func test_slices_alternate_round_the_whole_wheel() -> void:
	var slice_list: Array[Dictionary] = LuckWheel.slices(50)
	assert_int(slice_list.size()).is_equal(LuckWheel.PAIRS * 2)
	assert_float(float(slice_list[0]["start"])).is_equal(0.0)
	assert_float(float(slice_list[-1]["end"])).is_equal_approx(1.0, 0.0001)
	for i in slice_list.size():
		assert_bool(bool(slice_list[i]["win"])).is_equal(i % 2 == 0)


func test_the_wheel_rests_on_the_result_it_was_told() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 9
	var slice_list: Array[Dictionary] = LuckWheel.slices(30)
	for _i in 200:
		(
			assert_bool(
				LuckWheel.is_win_at(slice_list, LuckWheel.resting_turn(slice_list, true, rng))
			)
			. is_true()
		)
		(
			assert_bool(
				LuckWheel.is_win_at(slice_list, LuckWheel.resting_turn(slice_list, false, rng))
			)
			. is_false()
		)


func test_positions_wrap_round_the_wheel() -> void:
	var slice_list: Array[Dictionary] = LuckWheel.slices(50)
	assert_int(LuckWheel.slice_index_at(slice_list, 0.01)).is_equal(0)
	assert_int(LuckWheel.slice_index_at(slice_list, 1.01)).is_equal(0)
	assert_int(LuckWheel.slice_index_at(slice_list, -0.01)).is_equal(slice_list.size() - 1)
