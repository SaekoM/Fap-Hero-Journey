extends GdUnitTestSuite

# Quick-Time Event: prompts on rings at random places, scored by timing and key. Pure — times in ms from the
# event's start.


func _game(
	knobs: Dictionary = {}, duration_ms: int = 10000, rng_seed: int = 3
) -> QuickTimeEventGame:
	return QuickTimeEventGame.new(knobs, duration_ms, rng_seed)


func test_the_same_seed_schedules_the_same_prompts() -> void:
	var a: QuickTimeEventGame = _game({"prompts": 3}, 10000, 11)
	var b: QuickTimeEventGame = _game({"prompts": 3}, 10000, 11)
	assert_array(a.prompts).is_equal(b.prompts)


func test_prompts_never_overlap_and_stay_inside_the_moment() -> void:
	for rng_seed in 40:
		var game: QuickTimeEventGame = _game(
			{"prompts": 5, "lead_ms": 800, "window_ms": 400}, 9000, rng_seed
		)
		assert_int(game.prompts.size()).is_equal(5)
		var last_close: int = -1
		for prompt: Dictionary in game.prompts:
			assert_int(int(prompt["show_ms"])).is_greater(last_close)
			assert_int(int(prompt["target_ms"]) - int(prompt["show_ms"])).is_equal(800)
			last_close = int(prompt["close_ms"])
		assert_int(last_close).is_less_equal(9000)


func test_an_event_can_ask_for_up_to_ten_prompts() -> void:
	assert_int(QuickTimeEventGame.normalize_knobs({"prompts": 11})["prompts"]).is_equal(10)
	assert_int(_game({"prompts": 10}, 20000).prompts.size()).is_equal(10)


func test_a_short_moment_holds_as_many_prompts_as_fit() -> void:
	# each prompt needs 1200 + 300 = 1500 ms
	assert_int(_game({"prompts": 5}, 3200).prompts.size()).is_equal(2)
	assert_int(_game({"prompts": 5}, 100).prompts.size()).is_equal(1)
	assert_int(QuickTimeEventGame.min_duration_ms({"prompts": 5})).is_equal(7500)


func test_a_press_on_target_scores_100() -> void:
	var game: QuickTimeEventGame = _game()
	var target: int = int(game.prompts[0]["target_ms"])
	assert_float(game.press(target, "E")).is_equal(1.0)
	assert_bool(game.is_finished()).is_true()
	assert_int(game.score()).is_equal(100)


func test_accuracy_falls_off_across_the_half_window() -> void:
	var game: QuickTimeEventGame = _game({"window_ms": 600})
	var target: int = int(game.prompts[0]["target_ms"])
	assert_float(game.press(target + 150, "E")).is_equal_approx(0.5, 0.0001)
	assert_int(game.score()).is_equal(50)


# The first press while a prompt shows decides it: pressing early during the lead-in is a miss, and the
# press after it can't rescue the prompt.
func test_the_first_press_decides_so_mashing_cannot_help() -> void:
	var game: QuickTimeEventGame = _game({"window_ms": 600})
	var prompt: Dictionary = game.prompts[0]
	assert_float(game.press(int(prompt["show_ms"]) + 10, "E")).is_equal(0.0)
	assert_float(game.press(int(prompt["target_ms"]), "E")).is_equal(-1.0)
	assert_int(game.score()).is_equal(0)


func test_a_press_with_no_prompt_showing_is_ignored() -> void:
	var game: QuickTimeEventGame = _game({}, 10000)
	var show_ms: int = int(game.prompts[0]["show_ms"])
	if show_ms > 0:
		assert_float(game.press(show_ms - 1, "E")).is_equal(-1.0)
	assert_float(game.press(int(game.prompts[0]["target_ms"]), "E")).is_equal(1.0)


func test_an_unpressed_prompt_becomes_a_miss_when_its_window_closes() -> void:
	var game: QuickTimeEventGame = _game({"prompts": 2}, 10000)
	game.press(int(game.prompts[0]["target_ms"]), "E")
	game.advance_to(int(game.prompts[1]["close_ms"]))
	assert_bool(game.is_finished()).is_false()
	game.advance_to(int(game.prompts[1]["close_ms"]) + 1)
	assert_bool(game.is_finished()).is_true()
	assert_int(game.score()).is_equal(50)


func test_ending_early_counts_undecided_prompts_as_misses() -> void:
	var game: QuickTimeEventGame = _game({"prompts": 3}, 10000)
	game.press(int(game.prompts[0]["target_ms"]), "E")
	game.finish()
	assert_bool(game.is_finished()).is_true()
	assert_int(game.score()).is_equal(33)


func test_ring_progress_reaches_1_on_the_target() -> void:
	var game: QuickTimeEventGame = _game({"lead_ms": 1000})
	var prompt: Dictionary = game.prompts[0]
	assert_float(game.ring_progress(0, int(prompt["show_ms"]))).is_equal(0.0)
	assert_float(game.ring_progress(0, int(prompt["show_ms"]) + 500)).is_equal(0.5)
	assert_float(game.ring_progress(0, int(prompt["target_ms"]))).is_equal(1.0)


# ── Keys ─────────────────────────────────────────────────────────────────────


func test_keys_default_to_e() -> void:
	assert_array(QuickTimeEventGame.normalize_keys([])).is_equal(["E"])
	assert_array(QuickTimeEventGame.normalize_knobs({})["keys"]).is_equal(["E"])


func test_keys_are_cleaned_up_and_put_in_order() -> void:
	assert_array(QuickTimeEventGame.normalize_keys(["q", "A", "A", "Tab", 7])).is_equal(
		["A", "Q", "7"]
	)


# They would pause the fight, or open a panel over it, instead of answering the ring.
func test_the_rounds_own_hotkeys_cannot_be_asked_for() -> void:
	for hotkey: String in ["F", "M", "S"]:
		assert_bool(QuickTimeEventGame.ALLOWED_KEYS.has(hotkey)).is_false()
	assert_array(QuickTimeEventGame.normalize_keys(["F"])).is_equal(["E"])


func test_every_prompt_asks_for_a_key_in_play() -> void:
	for rng_seed in 20:
		var game: QuickTimeEventGame = _game({"prompts": 5, "keys": ["A", "B"]}, 20000, rng_seed)
		for prompt: Dictionary in game.prompts:
			assert_array(["A", "B"]).contains([prompt["key"]])


func test_the_key_a_prompt_asks_for_scores_and_another_in_play_misses() -> void:
	var game: QuickTimeEventGame = _game({"keys": ["A", "B"]})
	var prompt: Dictionary = game.prompts[0]
	var other: String = "B" if str(prompt["key"]) == "A" else "A"
	assert_float(game.press(int(prompt["target_ms"]), other)).is_equal(0.0)
	assert_int(game.score()).is_equal(0)


func test_the_right_key_on_target_scores_100_whichever_it_is() -> void:
	var game: QuickTimeEventGame = _game({"keys": ["A", "B"]})
	var prompt: Dictionary = game.prompts[0]
	assert_float(game.press(int(prompt["target_ms"]), str(prompt["key"]))).is_equal(1.0)


# It stays free to do whatever it normally does.
func test_a_key_not_in_play_does_nothing() -> void:
	var game: QuickTimeEventGame = _game()
	var prompt: Dictionary = game.prompts[0]
	assert_float(game.press(int(prompt["target_ms"]), "Q")).is_equal(-1.0)
	assert_float(float(prompt["accuracy"])).is_equal(-1.0)


# ── Placement ────────────────────────────────────────────────────────────────


func test_targets_stay_on_screen_and_apart() -> void:
	for rng_seed in 40:
		var game: QuickTimeEventGame = _game({"prompts": 5}, 20000, rng_seed)
		var previous: Vector2 = Vector2(-1.0, -1.0)
		for prompt: Dictionary in game.prompts:
			var at: Vector2 = Vector2(float(prompt["x"]), float(prompt["y"]))
			assert_float(at.x).is_between(0.15, 0.85)
			assert_float(at.y).is_between(0.25, 0.75)
			if previous.x >= 0.0:
				assert_float(at.distance_to(previous)).is_greater_equal(0.2)
			previous = at


func test_the_same_seed_places_targets_the_same_and_another_differently() -> void:
	var first: Dictionary = _game({}, 10000, 11).prompts[0]
	var again: Dictionary = _game({}, 10000, 11).prompts[0]
	var other: Dictionary = _game({}, 10000, 12).prompts[0]
	assert_float(float(first["x"])).is_equal(float(again["x"]))
	assert_bool(is_equal_approx(float(first["x"]), float(other["x"]))).is_false()


# ── Look and pausing ─────────────────────────────────────────────────────────


func test_the_look_has_sensible_defaults() -> void:
	var knobs: Dictionary = QuickTimeEventGame.normalize_knobs({})
	assert_int(int(knobs["size_pct"])).is_equal(100)
	assert_bool(Color.html_is_valid(str(knobs["ring_color"]))).is_true()
	assert_bool(Color.html_is_valid(str(knobs["target_color"]))).is_true()


func test_a_chosen_look_survives_normalizing() -> void:
	var knobs: Dictionary = (
		QuickTimeEventGame
		. normalize_knobs(
			{
				"ring_color": "12ab34",
				"target_color": "ff0000",
				"size_pct": 150,
			}
		)
	)
	assert_str(str(knobs["ring_color"])).is_equal("12ab34")
	assert_str(str(knobs["target_color"])).is_equal("ff0000")
	assert_int(int(knobs["size_pct"])).is_equal(150)


func test_a_bad_look_falls_back() -> void:
	var knobs: Dictionary = QuickTimeEventGame.normalize_knobs(
		{"ring_color": "not a colour", "size_pct": 900}
	)
	assert_str(str(knobs["ring_color"])).is_equal(QuickTimeEventGame.DEFAULT_RING_COLOR)
	assert_int(int(knobs["size_pct"])).is_equal(200)


func test_pausing_the_video_is_on_unless_turned_off() -> void:
	assert_bool(QuickTimeEventGame.normalize_knobs({})["pause_video"]).is_true()
	var off: Dictionary = QuickTimeEventGame.normalize_knobs({"pause_video": false})
	assert_bool(off["pause_video"]).is_false()


# An event that pauses the video has no block to fit: it gets the time all its prompts need, and some to spare.
func test_a_held_event_has_time_for_every_prompt() -> void:
	var knobs: Dictionary = {"prompts": 5}
	var duration: int = QuickTimeEventGame.held_duration_ms(knobs)
	assert_int(duration).is_greater(QuickTimeEventGame.min_duration_ms(knobs))
	assert_int(_game(knobs, duration).prompts.size()).is_equal(5)


# ── The player's assist ──────────────────────────────────────────────────────


func test_assist_slows_the_rings_and_widens_the_window() -> void:
	var game: QuickTimeEventGame = QuickTimeEventGame.new(
		{"prompts": 1, "lead_ms": 1000, "window_ms": 600}, 10000, 3, 1.5
	)
	var prompt: Dictionary = game.prompts[0]
	assert_int(int(prompt["target_ms"]) - int(prompt["show_ms"])).is_equal(1500)
	assert_int(int(prompt["close_ms"]) - int(prompt["target_ms"])).is_equal(450)


# The authored limits cap the knobs, not the assist: a game already at the slowest still gets the help.
func test_assist_goes_past_the_authored_limits() -> void:
	var game: QuickTimeEventGame = QuickTimeEventGame.new(
		{"prompts": 1, "lead_ms": 3000, "window_ms": 1500}, 20000, 3, 1.5
	)
	var prompt: Dictionary = game.prompts[0]
	assert_int(int(prompt["target_ms"]) - int(prompt["show_ms"])).is_equal(4500)


func test_an_assisted_game_that_pauses_the_video_keeps_every_prompt() -> void:
	var knobs: Dictionary = {"prompts": 5, "lead_ms": 3000, "window_ms": 1500}
	var game: QuickTimeEventGame = QuickTimeEventGame.new(
		knobs, QuickTimeEventGame.held_duration_ms(knobs, 1.5), 3, 1.5
	)
	assert_int(game.prompts.size()).is_equal(5)


# Over the video the event's length is fixed, so slower rings can mean fewer of them, but one must still fit.
func test_a_lone_assisted_prompt_stays_inside_a_short_event() -> void:
	var knobs: Dictionary = {"prompts": 1, "lead_ms": 1000, "window_ms": 600}
	var game: QuickTimeEventGame = QuickTimeEventGame.new(knobs, 1300, 3, 1.5)
	assert_int(int(game.prompts[0]["close_ms"])).is_less_equal(1300)


func test_assist_does_not_change_how_a_hit_scores() -> void:
	var game: QuickTimeEventGame = QuickTimeEventGame.new(
		{"prompts": 1, "lead_ms": 1000, "window_ms": 600}, 10000, 3, 1.5
	)
	var prompt: Dictionary = game.prompts[0]
	assert_float(game.press(int(prompt["target_ms"]), str(prompt["key"]))).is_equal(1.0)


# ── Prompt kinds ─────────────────────────────────────────────────────────────

const HOLDS: Dictionary = {"prompt_kinds": ["hold"], "hold_ms": 1000, "window_ms": 600}
const MASHES: Dictionary = {"prompt_kinds": ["mash"], "mash_ms": 2000, "mash_presses": 5}


func test_prompt_kinds_default_to_press_and_are_cleaned_up() -> void:
	assert_array(QuickTimeEventGame.normalize_knobs({})["prompt_kinds"]).is_equal(["press"])
	(
		assert_array(
			QuickTimeEventGame.normalize_prompt_kinds(
				["Mash", "bogus", "press", "press", "sequence"]
			)
		)
		. is_equal(["press", "mash"])
	)
	assert_array(QuickTimeEventGame.normalize_prompt_kinds(["bogus"])).is_equal(["press"])


func test_a_press_only_event_asks_for_one_key_per_prompt() -> void:
	for prompt: Dictionary in _game({"prompts": 4}, 20000).prompts:
		assert_str(str(prompt["kind"])).is_equal("press")
		assert_array(["E"]).contains([prompt["key"]])
		assert_int(int(prompt["end_ms"])).is_equal(int(prompt["close_ms"]))


# The kinds come from a generator of their own, so allowing more kinds can't move a press-only event's rings.
func test_allowing_more_kinds_keeps_the_rings_where_they_were() -> void:
	var presses: QuickTimeEventGame = _game({"prompts": 1}, 10000, 7)
	var mixed: QuickTimeEventGame = _game(
		{"prompts": 1, "prompt_kinds": ["press", "mash"]}, 10000, 7
	)
	assert_float(float(mixed.prompts[0]["x"])).is_equal(float(presses.prompts[0]["x"]))
	assert_str(str(mixed.prompts[0]["key"])).is_equal(str(presses.prompts[0]["key"]))


func test_every_prompt_is_one_of_the_allowed_kinds_and_both_turn_up() -> void:
	var seen: Dictionary = {}
	for rng_seed in 30:
		var game: QuickTimeEventGame = _game(
			{"prompts": 4, "prompt_kinds": ["hold", "mash"]}, 30000, rng_seed
		)
		for prompt: Dictionary in game.prompts:
			assert_array(["hold", "mash"]).contains([prompt["kind"]])
			seen[prompt["kind"]] = true
	assert_int(seen.size()).is_equal(2)


func test_mixed_prompts_never_overlap_and_stay_inside_the_moment() -> void:
	var knobs: Dictionary = {"prompts": 5, "prompt_kinds": ["press", "hold", "mash"]}
	var duration: int = QuickTimeEventGame.min_duration_ms(knobs)
	for rng_seed in 40:
		var game: QuickTimeEventGame = _game(knobs, duration, rng_seed)
		assert_int(game.prompts.size()).is_equal(5)
		var last_end: int = -1
		for prompt: Dictionary in game.prompts:
			# Every prompt here can roll a hold, leaving no spare time, so one may start as the last ends.
			assert_int(int(prompt["show_ms"])).is_greater_equal(last_end)
			last_end = int(prompt["end_ms"])
		assert_int(last_end).is_less_equal(duration)


# Holds are allowed, so every prompt is given room for one, whichever kinds the seed picks.
func test_the_time_an_event_needs_allows_for_its_longest_kind() -> void:
	assert_int(QuickTimeEventGame.one_prompt_ms({})).is_equal(1500)
	(
		assert_int(
			QuickTimeEventGame.one_prompt_ms({"prompt_kinds": ["press", "hold"], "hold_ms": 800})
		)
		. is_equal(2300)
	)
	(
		assert_int(QuickTimeEventGame.min_duration_ms({"prompts": 2, "prompt_kinds": ["hold"]}))
		. is_equal(5000)
	)
	# A mash: its lead-in and the default 3000 ms mash time, with no hit window.
	assert_int(QuickTimeEventGame.one_prompt_ms({"prompt_kinds": ["mash"]})).is_equal(4200)


func test_a_held_event_has_time_for_every_hold() -> void:
	var knobs: Dictionary = {"prompts": 5, "prompt_kinds": ["hold"]}
	var duration: int = QuickTimeEventGame.held_duration_ms(knobs, 1.5)
	assert_int(QuickTimeEventGame.new(knobs, duration, 3, 1.5).prompts.size()).is_equal(5)


func test_hold_and_mash_need_a_newer_build() -> void:
	assert_bool(QuickTimeEventGame.needs_newer_build({})).is_false()
	assert_bool(QuickTimeEventGame.needs_newer_build({"prompt_kinds": ["press"]})).is_false()
	assert_bool(QuickTimeEventGame.needs_newer_build({"prompt_kinds": ["hold"]})).is_true()
	assert_bool(QuickTimeEventGame.needs_newer_build({"prompt_kinds": ["press", "mash"]})).is_true()


func test_a_boss_encounter_with_holds_raises_the_journeys_floor() -> void:
	var library: Array = [
		{"id": "q_plain", "kind": QuickTimeEventGame.KIND, "knobs": {}},
		{"id": "q_hold", "kind": QuickTimeEventGame.KIND, "knobs": {"prompt_kinds": ["hold"]}},
	]
	var graph_with: Callable = func(game_id: String) -> Dictionary:
		var event: Dictionary = {"track": RoundTimeline.TRACK_QTE, "game": game_id}
		return {"nodes": {"n1": {"type": "round", "data": {"timeline": {"events": [event]}}}}}
	assert_bool(JourneyData.graph_needs_newer_build(graph_with.call("q_hold"), library)).is_true()
	assert_bool(JourneyData.graph_needs_newer_build(graph_with.call("q_plain"), library)).is_false()


# ── Hold ─────────────────────────────────────────────────────────────────────


func test_a_hold_on_target_held_to_the_end_scores_100() -> void:
	var game: QuickTimeEventGame = _game(HOLDS)
	var prompt: Dictionary = game.prompts[0]
	var target: int = int(prompt["target_ms"])
	assert_float(game.press(target, "E")).is_equal(QuickTimeEventGame.TAKEN)
	assert_bool(game.is_finished()).is_false()
	game.advance_to(target + 999)
	assert_bool(game.is_finished()).is_false()
	game.advance_to(target + 1000)
	assert_bool(game.is_finished()).is_true()
	assert_int(game.score()).is_equal(100)


func test_letting_go_halfway_scores_half_the_press() -> void:
	var game: QuickTimeEventGame = _game(HOLDS)
	var target: int = int(game.prompts[0]["target_ms"])
	game.press(target + 150, "E")  # a press worth 0.5
	assert_float(game.release(target + 150 + 500, "E")).is_equal_approx(0.25, 0.0001)
	assert_int(game.score()).is_equal(25)


# A hold keeps showing past its press window while the fill runs, so the next prompt can't start under it.
func test_a_running_hold_shows_until_its_fill_has_run() -> void:
	var game: QuickTimeEventGame = _game(HOLDS)
	var prompt: Dictionary = game.prompts[0]
	var pressed_at: int = int(prompt["target_ms"]) + 100  # late, but inside the window
	game.press(pressed_at, "E")
	assert_int(game.showing_prompt(int(prompt["close_ms"]) + 500)).is_equal(0)
	assert_int(pressed_at + 1000).is_less_equal(int(prompt["end_ms"]))
	assert_float(game.hold_progress(0, pressed_at + 500)).is_equal_approx(0.5, 0.0001)


func test_a_hold_pressed_early_or_with_the_wrong_key_misses() -> void:
	var early: QuickTimeEventGame = _game(HOLDS)
	assert_float(early.press(int(early.prompts[0]["show_ms"]) + 10, "E")).is_equal(0.0)
	var wrong: QuickTimeEventGame = _game(HOLDS.merged({"keys": ["A", "B"]}))
	var prompt: Dictionary = wrong.prompts[0]
	var other: String = "B" if str(prompt["key"]) == "A" else "A"
	assert_float(wrong.press(int(prompt["target_ms"]), other)).is_equal(0.0)


func test_a_hold_never_pressed_misses_when_its_window_closes() -> void:
	var game: QuickTimeEventGame = _game(HOLDS)
	game.advance_to(int(game.prompts[0]["close_ms"]) + 1)
	assert_bool(game.is_finished()).is_true()
	assert_int(game.score()).is_equal(0)


func test_other_presses_during_a_hold_are_ignored() -> void:
	var game: QuickTimeEventGame = _game(HOLDS.merged({"keys": ["A", "B"]}))
	var prompt: Dictionary = game.prompts[0]
	var target: int = int(prompt["target_ms"])
	game.press(target, str(prompt["key"]))
	var other: String = "B" if str(prompt["key"]) == "A" else "A"
	assert_float(game.press(target + 200, other)).is_equal(QuickTimeEventGame.IGNORED)
	assert_float(game.release(target + 300, other)).is_equal(QuickTimeEventGame.IGNORED)
	game.advance_to(target + 1000)
	assert_int(game.score()).is_equal(100)


func test_a_release_with_no_hold_running_is_ignored() -> void:
	var game: QuickTimeEventGame = _game()
	assert_float(game.release(int(game.prompts[0]["target_ms"]), "E")).is_equal(
		QuickTimeEventGame.IGNORED
	)


# The video ran out under a hold the player was still keeping down: they keep what they pressed.
func test_ending_early_during_a_hold_keeps_its_press() -> void:
	var game: QuickTimeEventGame = _game(HOLDS)
	game.press(int(game.prompts[0]["target_ms"]), "E")
	game.finish()
	assert_int(game.score()).is_equal(100)


func test_assist_does_not_lengthen_a_hold() -> void:
	var game: QuickTimeEventGame = QuickTimeEventGame.new(HOLDS, 10000, 3, 1.5)
	var target: int = int(game.prompts[0]["target_ms"])
	game.press(target, "E")
	game.advance_to(target + 1000)
	assert_bool(game.is_finished()).is_true()


# ── Mash ─────────────────────────────────────────────────────────────────────


func _mash(game: QuickTimeEventGame, from_ms: int, presses: int) -> float:
	var result: float = QuickTimeEventGame.IGNORED
	for press in presses:
		result = game.press(from_ms + press * 10, "E")
	return result


func test_filling_a_mash_in_time_scores_100() -> void:
	var game: QuickTimeEventGame = _game(MASHES)
	var target: int = int(game.prompts[0]["target_ms"])
	assert_float(_mash(game, target, 4)).is_equal(QuickTimeEventGame.TAKEN)
	assert_float(game.mash_progress(0)).is_equal_approx(0.8, 0.0001)
	assert_float(game.press(target + 100, "E")).is_equal(1.0)
	assert_int(game.score()).is_equal(100)


# All or nothing: one press short is as good as none.
func test_a_mash_short_of_full_when_time_runs_out_misses() -> void:
	var game: QuickTimeEventGame = _game(MASHES)
	var prompt: Dictionary = game.prompts[0]
	_mash(game, int(prompt["target_ms"]), 4)
	game.advance_to(int(prompt["close_ms"]))
	assert_bool(game.is_finished()).is_false()
	game.advance_to(int(prompt["close_ms"]) + 1)
	assert_int(game.score()).is_equal(0)


func test_a_mash_runs_for_its_time_from_when_the_ring_lands() -> void:
	var prompt: Dictionary = _game(MASHES).prompts[0]
	assert_int(int(prompt["close_ms"]) - int(prompt["target_ms"])).is_equal(2000)
	assert_int(int(prompt["end_ms"])).is_equal(int(prompt["close_ms"]))


# Jumping the gun costs nothing.
func test_presses_before_the_ring_lands_are_ignored() -> void:
	var game: QuickTimeEventGame = _game(MASHES)
	var prompt: Dictionary = game.prompts[0]
	assert_float(game.press(int(prompt["show_ms"]) + 10, "E")).is_equal(QuickTimeEventGame.IGNORED)
	assert_int(int(prompt["presses"])).is_equal(0)


func test_other_keys_during_a_mash_are_ignored() -> void:
	var game: QuickTimeEventGame = _game(MASHES.merged({"keys": ["A", "B"]}))
	var prompt: Dictionary = game.prompts[0]
	var other: String = "B" if str(prompt["key"]) == "A" else "A"
	assert_float(game.press(int(prompt["target_ms"]), other)).is_equal(QuickTimeEventGame.IGNORED)
	assert_float(float(prompt["accuracy"])).is_equal(-1.0)


func test_the_mash_timer_runs_down_from_when_the_ring_lands() -> void:
	var game: QuickTimeEventGame = _game(MASHES)
	var target: int = int(game.prompts[0]["target_ms"])
	assert_float(game.mash_time_left(0, target - 100)).is_equal(1.0)
	assert_float(game.mash_time_left(0, target + 500)).is_equal_approx(0.75, 0.0001)
	assert_float(game.mash_time_left(0, target + 2000)).is_equal(0.0)


func test_assist_gives_a_mash_half_as_much_time_again() -> void:
	var game: QuickTimeEventGame = QuickTimeEventGame.new(MASHES, 20000, 3, 1.5)
	var prompt: Dictionary = game.prompts[0]
	assert_int(int(prompt["close_ms"]) - int(prompt["target_ms"])).is_equal(3000)
	assert_int(int(prompt["mash_presses"])).is_equal(5)


func test_a_mash_needs_its_lead_in_and_its_time() -> void:
	assert_int(QuickTimeEventGame.one_prompt_ms(MASHES)).is_equal(1200 + 2000)
	var knobs: Dictionary = MASHES.merged({"prompts": 3})
	assert_int(QuickTimeEventGame.held_duration_ms(knobs, 1.5)).is_equal(
		3 * (ceili(3200 * 1.5) + 700)
	)
