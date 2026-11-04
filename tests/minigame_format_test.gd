extends GdUnitTestSuite

# Mini-games in the journey format: the node type, its save coercion, the version floor a journey that
# places one needs, and the library travelling in a rendition.


func test_a_new_minigame_node_points_at_no_game_yet() -> void:
	var node: Dictionary = JourneyData.new_item("minigame")
	assert_str(node["type"]).is_equal("minigame")
	assert_str(node["game"]).is_equal("")
	assert_str(str(node["node_id"])).is_not_empty()


func test_saving_a_minigame_node_keeps_its_game_and_backdrop() -> void:
	var out: Dictionary = JourneyData.coerce_node_save_data(
		"minigame",
		{
			"type": "minigame",
			"game": "mg_lock",
			"setting": "s_yard",
			"image": "a.png",
			"image_fit": "fit"
		}
	)
	assert_str(out["game"]).is_equal("mg_lock")
	assert_str(out["setting"]).is_equal("s_yard")
	assert_str(out["image"]).is_equal("a.png")
	assert_bool(out.has("type")).is_false()


func test_a_minigame_backdrop_resolves_against_the_journey_folder() -> void:
	var graph: Dictionary = {
		"nodes": {"m": {"type": "minigame", "data": {"game": "mg_a", "image": "media/a.png"}}}
	}
	JourneyGraph.resolve_paths(graph, "C:/journeys/demo")
	assert_str(graph["nodes"]["m"]["data"]["image"]).is_equal("C:/journeys/demo/media/a.png")


func test_placing_a_minigame_raises_the_version_floor() -> void:
	assert_str(JourneyData.content_min_version(false, false)).is_equal("")
	assert_str(JourneyData.content_min_version(true, false)).is_equal(
		JourneyData.JOURNEY_MIN_APP_VERSION_WIDE_CODECS
	)
	assert_str(JourneyData.content_min_version(true, true)).is_equal(
		JourneyData.JOURNEY_MIN_APP_VERSION_MINIGAMES
	)


func test_graph_has_minigames() -> void:
	var with_game: Dictionary = {"nodes": {"a": {"type": "round"}, "b": {"type": "minigame"}}}
	assert_bool(JourneyData.graph_has_minigames(with_game)).is_true()
	assert_bool(JourneyData.graph_has_minigames({"nodes": {"a": {"type": "round"}}})).is_false()
	assert_bool(JourneyData.graph_has_minigames({})).is_false()


# A journey whose only mini-game is a dodge still needs the build that plays it.
func test_a_dodge_in_an_encounter_counts_as_a_minigame() -> void:
	var attack: Dictionary = {"track": "attack", "dodge": {"game": "g"}}
	var data: Dictionary = {"timeline": {"events": [attack]}}
	var graph: Dictionary = {"nodes": {"a": {"type": "round", "data": data}}}
	assert_bool(JourneyData.graph_has_minigames(graph)).is_true()


# A rendition carries its own library, and needs the mini-game build once it places one.
func test_a_rendition_round_trips_its_minigames() -> void:
	var rendition: Dictionary = {
		"name": "Extra",
		"parent_id": "j_parent",
		"nodes": {"m": {"type": "minigame", "data": {"game": "mg_safe"}, "out": []}},
		"minigames": [{"id": "mg_safe", "kind": SafeCrackerGame.KIND, "name": "The Vault"}],
	}
	var disk: Dictionary = JourneyRendition.coerce_rendition(rendition)
	assert_str(disk["MinVersion"]).is_equal(JourneyData.JOURNEY_MIN_APP_VERSION_MINIGAMES)
	var back: Dictionary = JourneyRendition.parse_rendition(disk)
	assert_int((back["minigames"] as Array).size()).is_equal(1)
	assert_str(back["minigames"][0]["name"]).is_equal("The Vault")


func test_a_rendition_without_minigames_keeps_the_standing_floor() -> void:
	var disk: Dictionary = JourneyRendition.coerce_rendition({"name": "Plain", "nodes": {}})
	assert_str(disk["MinVersion"]).is_equal(JourneyData.JOURNEY_MIN_APP_VERSION)
