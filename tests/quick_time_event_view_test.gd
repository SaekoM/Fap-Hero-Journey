extends GdUnitTestSuite

# The Quick-Time Event's view: every prompt kind and the dodge moments. Nothing here reads the picture: it's here so a draw
# call the engine refuses shows up as an error in the run.


func _view(knobs: Dictionary) -> QuickTimeEventView:
	var view: QuickTimeEventView = auto_free(QuickTimeEventView.new())
	add_child(view)
	view.size = Vector2(1280.0, 720.0)
	var game: QuickTimeEventGame = QuickTimeEventGame.new(knobs, 30000, 5)
	view.setup(game, QuickTimeEventGame.normalize_knobs(knobs), 0)
	return view


func _play_through(view: QuickTimeEventView, game_knobs: Dictionary) -> void:
	var game: QuickTimeEventGame = QuickTimeEventGame.new(game_knobs, 30000, 5)
	for prompt: Dictionary in game.prompts:
		view.advance_to(int(prompt["show_ms"]) + 100)
		await await_idle_frame()
		view.press(int(prompt["target_ms"]), str(prompt["key"]))
		await await_idle_frame()
		view.advance_to(int(prompt["end_ms"]) + 1)
		await await_idle_frame()


func test_every_kind_draws_through_a_whole_event_and_a_dodge() -> void:
	var knobs: Dictionary = {"prompts": 3, "prompt_kinds": ["press", "hold", "mash"]}
	var view: QuickTimeEventView = _view(knobs)
	await _play_through(view, knobs)
	view.show_dodge_result(true, "Slipped it")
	await await_millis(200)
	remove_child(view)


func test_a_hit_draws_its_red_edges_and_shake() -> void:
	var view: QuickTimeEventView = _view({"prompts": 2})
	view.advance_to(30000)
	await await_idle_frame()
	view.show_dodge_result(false)
	for _frame in 5:
		await await_idle_frame()
	remove_child(view)


func test_a_mash_draws_filling_up_with_sparks_and_its_burst() -> void:
	var knobs: Dictionary = {"prompt_kinds": ["mash"], "mash_presses": 8}
	var view: QuickTimeEventView = _view(knobs)
	var prompt: Dictionary = QuickTimeEventGame.new(knobs, 30000, 5).prompts[0]
	var target: int = int(prompt["target_ms"])
	view.advance_to(target - 200)
	await await_idle_frame()
	for press in 8:
		view.advance_to(target + press * 50)
		view.press(target + press * 50, "E")
		await await_idle_frame()
	await await_millis(200)
	remove_child(view)
