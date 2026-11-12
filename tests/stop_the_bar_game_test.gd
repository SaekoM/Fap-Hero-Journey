extends GdUnitTestSuite

# Stop the Bar's rules: the sweep, scoring by accuracy, the zone's placement, and the player's assist.

const SWEEP_MS: int = 1000
# A zone in the middle of the bar, a fifth of it wide, so its edges are at 0.4 and 0.6.
const FIXED: Dictionary = {"stops": 2, "sweep_ms": SWEEP_MS, "zone_pct": 20, "moving_zone": false}


func _fixed_game() -> StopTheBarGame:
	return StopTheBarGame.new(FIXED, 1)


func test_the_marker_sweeps_out_and_back() -> void:
	var game: StopTheBarGame = _fixed_game()
	assert_float(game.marker_at(0)).is_equal_approx(0.0, 0.001)
	assert_float(game.marker_at(500)).is_equal_approx(0.5, 0.001)
	assert_float(game.marker_at(1000)).is_equal_approx(1.0, 0.001)
	assert_float(game.marker_at(1500)).is_equal_approx(0.5, 0.001)
	assert_float(game.marker_at(2000)).is_equal_approx(0.0, 0.001)
	assert_float(game.marker_at(2500)).is_equal_approx(0.5, 0.001)


func test_dead_centre_scores_full_marks() -> void:
	assert_float(_fixed_game().stop(500)).is_equal_approx(1.0, 0.001)


func test_accuracy_falls_towards_the_zones_edge() -> void:
	assert_float(_fixed_game().stop(550)).is_equal_approx(0.5, 0.001)
	assert_float(_fixed_game().stop(600)).is_equal_approx(0.0, 0.001)


func test_a_stop_outside_the_zone_scores_nothing() -> void:
	assert_float(_fixed_game().stop(100)).is_equal_approx(0.0, 0.001)


func test_the_score_is_the_mean_over_every_stop() -> void:
	var game: StopTheBarGame = _fixed_game()
	game.stop(500)
	assert_bool(game.is_finished()).is_false()
	assert_int(game.score()).is_equal(50)
	game.stop(550)
	assert_bool(game.is_finished()).is_true()
	assert_int(game.score()).is_equal(75)


func test_a_stop_after_the_last_does_nothing() -> void:
	var game: StopTheBarGame = _fixed_game()
	game.stop(500)
	game.stop(500)
	assert_float(game.stop(500)).is_equal(-1.0)
	assert_int(game.accuracies.size()).is_equal(2)
	assert_int(game.score()).is_equal(100)


func test_a_fixed_zone_stays_in_the_middle() -> void:
	for centre: float in _fixed_game().zone_centres:
		assert_float(centre).is_equal_approx(StopTheBarGame.FIXED_ZONE_CENTRE, 0.001)


func test_a_moving_zone_comes_from_the_seed() -> void:
	var knobs: Dictionary = {"stops": 6, "moving_zone": true}
	assert_array(StopTheBarGame.new(knobs, 7).zone_centres).is_equal(
		StopTheBarGame.new(knobs, 7).zone_centres
	)
	assert_array(StopTheBarGame.new(knobs, 7).zone_centres).is_not_equal(
		StopTheBarGame.new(knobs, 8).zone_centres
	)


func test_a_moving_zone_stays_on_the_bar_and_really_moves() -> void:
	var game: StopTheBarGame = StopTheBarGame.new({"stops": 10, "zone_pct": 20}, 3)
	var previous: float = -1.0
	var half_width: float = game.current_zone_half_width()
	for centre: float in game.zone_centres:
		assert_bool(centre - half_width >= StopTheBarGame.ZONE_EDGE_MARGIN).is_true()
		assert_bool(centre + half_width <= 1.0 - StopTheBarGame.ZONE_EDGE_MARGIN).is_true()
		if previous >= 0.0:
			assert_bool(absf(centre - previous) >= StopTheBarGame.MIN_ZONE_GAP).is_true()
		previous = centre


func test_a_zone_too_wide_to_move_stays_in_the_middle() -> void:
	var game: StopTheBarGame = StopTheBarGame.new({"zone_pct": 60}, 3, 1.5)
	for centre: float in game.zone_centres:
		assert_float(centre).is_equal_approx(StopTheBarGame.FIXED_ZONE_CENTRE, 0.001)


func test_the_assist_slows_the_sweep_and_widens_the_zone() -> void:
	var game: StopTheBarGame = StopTheBarGame.new(FIXED, 1, 1.5)
	assert_float(game.current_zone_half_width()).is_equal_approx(0.15, 0.001)
	assert_float(game.marker_at(750)).is_equal_approx(0.5, 0.001)


func test_the_assist_never_makes_the_zone_the_whole_bar() -> void:
	var game: StopTheBarGame = StopTheBarGame.new({"zone_pct": 60}, 1, 2.0)
	assert_float(game.current_zone_half_width() * 2.0).is_equal_approx(
		StopTheBarGame.MAX_ZONE_WIDTH, 0.001
	)


# 50% harder over three stops: 1000 ms and a 20% zone, then 750 ms and 15%, then 500 ms and 10%.
func test_gets_harder_shrinks_the_sweep_and_zone_evenly() -> void:
	var knobs: Dictionary = FIXED.duplicate()
	knobs["stops"] = 3
	knobs["harder_pct"] = 50
	var game: StopTheBarGame = StopTheBarGame.new(knobs, 1)
	assert_float(game.current_zone_half_width()).is_equal_approx(0.1, 0.001)
	assert_float(game.marker_at(500)).is_equal_approx(0.5, 0.001)
	game.stop(500)
	assert_float(game.current_zone_half_width()).is_equal_approx(0.075, 0.001)
	assert_float(game.marker_at(375)).is_equal_approx(0.5, 0.001)
	game.stop(375)
	assert_float(game.current_zone_half_width()).is_equal_approx(0.05, 0.001)
	assert_float(game.marker_at(250)).is_equal_approx(0.5, 0.001)


func test_a_single_stop_never_gets_harder() -> void:
	var knobs: Dictionary = FIXED.duplicate()
	knobs["stops"] = 1
	knobs["harder_pct"] = 50
	var game: StopTheBarGame = StopTheBarGame.new(knobs, 1)
	assert_float(game.current_zone_half_width()).is_equal_approx(0.1, 0.001)


# Flawless needs the game over and every stop at 90% or better. The zone's half width is 0.1 and a sweep is 1000 ms,
# so 9 ms from dead centre scores 91%, and 20 ms scores 80%.
func test_flawless_needs_every_stop_dead_on() -> void:
	var flawless: StopTheBarGame = _fixed_game()
	flawless.stop(500)
	assert_bool(flawless.is_flawless()).is_false()
	flawless.stop(509)
	assert_bool(flawless.is_flawless()).is_true()
	var flawed: StopTheBarGame = _fixed_game()
	flawed.stop(500)
	flawed.stop(520)
	assert_bool(flawed.is_flawless()).is_false()


func test_tier_strength_runs_from_lowest_to_highest() -> void:
	var tiers: Array = [{"id": "fail"}, {"id": "pass"}, {"id": "perfect"}]
	assert_float(MiniGameResolver.tier_strength(tiers, "fail")).is_equal(0.0)
	assert_float(MiniGameResolver.tier_strength(tiers, "pass")).is_equal(0.5)
	assert_float(MiniGameResolver.tier_strength(tiers, "perfect")).is_equal(1.0)
	assert_float(MiniGameResolver.tier_strength([{"id": "only"}], "only")).is_equal(1.0)


func test_knobs_are_clamped_and_default() -> void:
	var knobs: Dictionary = StopTheBarGame.normalize_knobs({"stops": 99, "sweep_ms": 1})
	assert_int(knobs["stops"]).is_equal(10)
	assert_int(knobs["sweep_ms"]).is_equal(400)
	assert_int(knobs["zone_pct"]).is_equal(20)
	assert_bool(knobs["moving_zone"]).is_true()
	assert_int(knobs["harder_pct"]).is_equal(0)
	assert_bool(knobs["show_tiers"]).is_true()


# The library rebuilds a definition key by key, so a game's fields have to survive a save and load.
func test_a_definition_survives_the_library() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(StopTheBarGame.KIND)
	definition["knobs"]["stops"] = 5
	definition["knobs"]["moving_zone"] = false
	definition["knobs"]["harder_pct"] = 25
	definition["knobs"]["show_tiers"] = false
	definition["game_character"] = {"character": "warden", "moments": {"hit": {"portrait": "grin"}}}
	var loaded: Dictionary = MiniGameLibrary.normalize_definition(definition)
	assert_str(loaded["kind"]).is_equal(StopTheBarGame.KIND)
	assert_int(loaded["knobs"]["stops"]).is_equal(5)
	assert_bool(loaded["knobs"]["moving_zone"]).is_false()
	assert_int(loaded["knobs"]["harder_pct"]).is_equal(25)
	assert_bool(loaded["knobs"]["show_tiers"]).is_false()
	assert_str(loaded["game_character"]["moments"]["hit"]["portrait"]).is_equal("grin")
	(
		assert_array(loaded["tiers"].map(func(t: Dictionary) -> String: return t["id"]))
		. is_equal(["fail", "pass", "perfect"])
	)
	assert_array(MiniGameLibrary.KIND_HOSTS[loaded["kind"]]).is_equal([MiniGameLibrary.HOST_NODE])
	assert_bool(MiniGameLibrary.is_chance(loaded["kind"])).is_false()


# An older build would quietly play an unknown game as a Safe-Cracker, so placing one raises the floor.
func test_placing_a_stop_the_bar_needs_the_build_that_plays_it() -> void:
	var library: Array = [
		{"id": "bar", "kind": StopTheBarGame.KIND}, {"id": "safe", "kind": SafeCrackerGame.KIND}
	]
	var plays_bar: Dictionary = {"nodes": {"a": {"type": "minigame", "data": {"game": "bar"}}}}
	var plays_safe: Dictionary = {"nodes": {"a": {"type": "minigame", "data": {"game": "safe"}}}}
	assert_bool(JourneyData.graph_needs_newer_build(plays_bar, library)).is_true()
	assert_bool(JourneyData.graph_needs_newer_build(plays_safe, library)).is_false()
	assert_str(JourneyData.content_min_version(false, true, true)).is_equal(
		JourneyData.JOURNEY_MIN_APP_VERSION_NEWER_GAMES
	)
	assert_str(JourneyData.content_min_version(false, true, false)).is_equal(
		JourneyData.JOURNEY_MIN_APP_VERSION_MINIGAMES
	)
