extends GdUnitTestSuite

# Hold & Release's rules: the fill, scoring against the zone's top edge, the zone's placement, and the player's assist.

const FILL_MS: int = 1000
# A steady fill and, at the default 20% width, a fixed zone from 0.5 to 0.7.
const FIXED: Dictionary = {
	"holds": 2, "fill_ms": FILL_MS, "zone_pct": 20, "moving_zone": false, "fill_curve": "steady"
}


func _steady_game() -> HoldReleaseGame:
	return HoldReleaseGame.new(FIXED, 1)


func test_a_steady_fill_rises_evenly_and_stops_at_full() -> void:
	var game: HoldReleaseGame = _steady_game()
	assert_float(game.level_at(0)).is_equal_approx(0.0, 0.001)
	assert_float(game.level_at(500)).is_equal_approx(0.5, 0.001)
	assert_float(game.level_at(1000)).is_equal_approx(1.0, 0.001)
	assert_float(game.level_at(5000)).is_equal_approx(1.0, 0.001)


func test_a_fill_that_speeds_up_starts_slower_but_arrives_on_time() -> void:
	var knobs: Dictionary = FIXED.duplicate()
	knobs["fill_curve"] = HoldReleaseGame.FILL_SPEEDS_UP
	var game: HoldReleaseGame = HoldReleaseGame.new(knobs, 1)
	assert_float(game.level_at(500)).is_equal_approx(0.25, 0.001)
	assert_float(game.level_at(1000)).is_equal_approx(1.0, 0.001)


func test_the_zones_top_edge_scores_full_marks() -> void:
	assert_float(_steady_game().release(700)).is_equal_approx(1.0, 0.001)


func test_the_score_climbs_through_the_zone() -> void:
	assert_float(_steady_game().release(500)).is_equal_approx(0.5, 0.001)
	assert_float(_steady_game().release(600)).is_equal_approx(0.75, 0.001)


func test_too_early_earns_a_small_share_that_rises_towards_the_zone() -> void:
	assert_float(_steady_game().release(0)).is_equal_approx(0.0, 0.001)
	assert_float(_steady_game().release(250)).is_equal_approx(0.15, 0.001)
	assert_float(_steady_game().release(499)).is_less(HoldReleaseGame.TOO_EARLY_BEST_ACCURACY)


func test_past_the_top_edge_is_a_miss() -> void:
	assert_float(_steady_game().release(701)).is_equal(0.0)
	assert_float(_steady_game().release(1000)).is_equal(0.0)


func test_the_score_is_the_mean_over_every_hold() -> void:
	var game: HoldReleaseGame = _steady_game()
	game.release(700)
	assert_bool(game.is_finished()).is_false()
	assert_int(game.score()).is_equal(50)
	game.release(600)
	assert_bool(game.is_finished()).is_true()
	assert_int(game.score()).is_equal(88)


func test_a_release_after_the_last_does_nothing() -> void:
	var game: HoldReleaseGame = _steady_game()
	game.release(700)
	game.release(700)
	assert_float(game.release(700)).is_equal(-1.0)
	assert_int(game.accuracies.size()).is_equal(2)


# Accuracy runs from 0.5 at the zone's bottom edge (0.5) to 1.0 at its top (0.7), so it passes the dead-on 0.9 at a
# level of 0.66: 0.68 counts, and 0.6 doesn't.
func test_flawless_needs_every_hold_dead_on() -> void:
	var flawless: HoldReleaseGame = _steady_game()
	flawless.release(700)
	assert_bool(flawless.is_flawless()).is_false()
	flawless.release(680)
	assert_bool(flawless.is_flawless()).is_true()
	var flawed: HoldReleaseGame = _steady_game()
	flawed.release(700)
	flawed.release(600)
	assert_bool(flawed.is_flawless()).is_false()


# In a zone from 0.5 to 0.7, a level of 0.698 scores 99.5% and 0.68 scores 95%.
func test_on_the_edge_is_the_very_top_of_the_zone() -> void:
	assert_bool(_steady_game().accuracy_at(0.698) >= HoldReleaseGame.ON_THE_EDGE_ACCURACY).is_true()
	assert_bool(_steady_game().accuracy_at(0.68) >= HoldReleaseGame.ON_THE_EDGE_ACCURACY).is_false()


func test_just_over_is_only_a_little_past_the_top_edge() -> void:
	var game: HoldReleaseGame = _steady_game()
	assert_bool(game.is_just_over(0.7)).is_false()
	assert_bool(game.is_just_over(0.72)).is_true()
	assert_bool(game.is_just_over(0.8)).is_false()


func test_a_moving_zone_comes_from_the_seed() -> void:
	var knobs: Dictionary = {"holds": 6}
	assert_array(HoldReleaseGame.new(knobs, 7).zone_bottoms).is_equal(
		HoldReleaseGame.new(knobs, 7).zone_bottoms
	)
	assert_array(HoldReleaseGame.new(knobs, 7).zone_bottoms).is_not_equal(
		HoldReleaseGame.new(knobs, 8).zone_bottoms
	)


func test_a_moving_zone_leaves_time_to_fill_and_room_to_overfill() -> void:
	var game: HoldReleaseGame = HoldReleaseGame.new({"holds": 10, "zone_pct": 20}, 3)
	var previous: float = -1.0
	for index: int in game.zone_bottoms.size():
		var bottom: float = game.zone_bottoms[index]
		assert_bool(bottom >= HoldReleaseGame.LOWEST_ZONE_BOTTOM).is_true()
		assert_bool(bottom + game.zone_widths[index] <= HoldReleaseGame.HIGHEST_ZONE_TOP).is_true()
		if previous >= 0.0:
			assert_bool(absf(bottom - previous) >= HoldReleaseGame.MIN_ZONE_GAP).is_true()
		previous = bottom


func test_a_zone_too_wide_to_move_still_leaves_room_to_overfill() -> void:
	var game: HoldReleaseGame = HoldReleaseGame.new({"zone_pct": 60}, 3, 1.5)
	assert_float(game.current_zone_bottom()).is_equal_approx(0.05, 0.001)
	assert_float(game.current_zone_top()).is_equal_approx(HoldReleaseGame.HIGHEST_ZONE_TOP, 0.001)


func test_the_assist_slows_the_fill_and_widens_the_zone() -> void:
	var game: HoldReleaseGame = HoldReleaseGame.new(FIXED, 1, 1.5)
	assert_float(game.level_at(750)).is_equal_approx(0.5, 0.001)
	assert_float(game.current_zone_top() - game.current_zone_bottom()).is_equal_approx(0.3, 0.001)


# 50% harder over three holds: 1000 ms and a 20% zone, then 750 ms and 15%, then 500 ms and 10%.
func test_gets_harder_shrinks_the_fill_and_zone_evenly() -> void:
	var knobs: Dictionary = FIXED.duplicate()
	knobs["holds"] = 3
	knobs["harder_pct"] = 50
	var game: HoldReleaseGame = HoldReleaseGame.new(knobs, 1)
	assert_float(game.level_at(500)).is_equal_approx(0.5, 0.001)
	game.release(0)
	assert_float(game.level_at(375)).is_equal_approx(0.5, 0.001)
	assert_float(game.current_zone_top() - game.current_zone_bottom()).is_equal_approx(0.15, 0.001)
	game.release(0)
	assert_float(game.level_at(250)).is_equal_approx(0.5, 0.001)
	assert_float(game.current_zone_top() - game.current_zone_bottom()).is_equal_approx(0.1, 0.001)


func test_knobs_are_clamped_and_default() -> void:
	var knobs: Dictionary = HoldReleaseGame.normalize_knobs(
		{"holds": 99, "fill_ms": 1, "fill_curve": "wobbly"}
	)
	assert_int(knobs["holds"]).is_equal(10)
	assert_int(knobs["fill_ms"]).is_equal(600)
	assert_int(knobs["zone_pct"]).is_equal(20)
	assert_int(knobs["harder_pct"]).is_equal(0)
	assert_str(knobs["fill_curve"]).is_equal(HoldReleaseGame.FILL_SPEEDS_UP)
	assert_bool(knobs["moving_zone"]).is_true()
	assert_bool(knobs["show_tiers"]).is_true()


# The library rebuilds a definition key by key, so a game's fields have to survive a save and load.
func test_a_definition_survives_the_library() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(HoldReleaseGame.KIND)
	definition["knobs"]["holds"] = 5
	definition["knobs"]["fill_curve"] = HoldReleaseGame.FILL_STEADY
	definition["knobs"]["show_tiers"] = false
	definition["game_character"] = {
		"character": "warden", "moments": {"miss": {"portrait": "grin"}}
	}
	var loaded: Dictionary = MiniGameLibrary.normalize_definition(definition)
	assert_str(loaded["kind"]).is_equal(HoldReleaseGame.KIND)
	assert_int(loaded["knobs"]["holds"]).is_equal(5)
	assert_str(loaded["knobs"]["fill_curve"]).is_equal(HoldReleaseGame.FILL_STEADY)
	assert_bool(loaded["knobs"]["show_tiers"]).is_false()
	assert_str(loaded["game_character"]["moments"]["miss"]["portrait"]).is_equal("grin")
	assert_array(MiniGameLibrary.KIND_HOSTS[loaded["kind"]]).is_equal([MiniGameLibrary.HOST_NODE])
	assert_bool(MiniGameLibrary.is_chance(loaded["kind"])).is_false()


func test_placing_one_needs_the_build_that_plays_it() -> void:
	var library: Array = [{"id": "hold", "kind": HoldReleaseGame.KIND}]
	var graph: Dictionary = {"nodes": {"a": {"type": "minigame", "data": {"game": "hold"}}}}
	assert_bool(JourneyData.graph_needs_newer_game(graph, library)).is_true()
