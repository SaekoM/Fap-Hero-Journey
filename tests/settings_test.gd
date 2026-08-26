extends GdUnitTestSuite

# Settings — the journey-level "reusable place" model and the two precedence rules that decide what a
# scene shows and what it plays. Pure: raw dictionaries in, resolved values out. No disk, no autoloads.
#
# The precedence tests matter more than the schema ones. Both rules are "most specific wins", and the
# subtle half is that an EXPLICIT image or clip beats a setting at the SAME level — which is what keeps
# every storyboard authored before settings existed behaving exactly as it did.

# ── Fixtures ─────────────────────────────────────────────────────────────────


func _setting(id: String, name: String, backgrounds: Array, bgm: String = "") -> Dictionary:
	return {
		"id": id,
		"name": name,
		"backgrounds": backgrounds,
		"bgm": bgm,
		"bgm_volume": 0.6,
	}


func _background(id: String, name: String, path: String) -> Dictionary:
	return {"id": id, "name": name, "path": path}


func _tavern() -> Dictionary:
	return _setting(
		"set_tavern",
		"The Tavern",
		[
			_background("bgd_day", "Day", "res://tavern_day.png"),
			_background("bgd_night", "Night", "res://tavern_night.png"),
		],
		"res://tavern.ogg"
	)


# ── Round-trip ───────────────────────────────────────────────────────────────


func test_a_setting_survives_a_round_trip_through_disk_shape() -> void:
	var settings: Array = [_tavern()]
	var back: Array = JourneyData.parse_journey_settings(
		JourneyData.coerce_journey_settings(settings)
	)
	assert_int(back.size()).is_equal(1)
	assert_str(back[0]["id"]).is_equal("set_tavern")
	assert_str(back[0]["name"]).is_equal("The Tavern")
	assert_str(back[0]["bgm"]).is_equal("res://tavern.ogg")
	assert_int((back[0]["backgrounds"] as Array).size()).is_equal(2)
	assert_str((back[0]["backgrounds"] as Array)[1]["name"]).is_equal("Night")


func test_a_blank_id_is_healed_so_the_setting_stays_referenceable() -> void:
	var raw: Array = [{"Id": "", "Name": "Nowhere", "Backgrounds": [{"Id": "", "Path": "a.png"}]}]
	var parsed: Array = JourneyData.parse_journey_settings(raw)
	assert_str(parsed[0]["id"]).is_not_equal("")
	assert_str((parsed[0]["backgrounds"] as Array)[0]["id"]).is_not_equal("")


# ── Lookup ───────────────────────────────────────────────────────────────────


func test_a_deleted_setting_resolves_to_nothing_rather_than_the_wrong_place() -> void:
	# Falling back to index 0 would dress a scene in another scene's clothes with nothing on screen to
	# explain it — an author would read that as the reference having worked.
	assert_dict(JourneyData.setting_by_id([_tavern()], "set_gone")).is_empty()


func test_a_stale_background_falls_back_to_the_settings_first() -> void:
	# Unlike a missing setting, this one still has a right answer: the place is known and only the
	# variant is not, so the default beats showing nothing.
	var background: Dictionary = JourneyData.setting_background(_tavern(), "bgd_deleted")
	assert_str(background["path"]).is_equal("res://tavern_day.png")


# ── Background precedence ────────────────────────────────────────────────────


func test_a_line_image_beats_everything_above_it() -> void:
	var node: Dictionary = {"image": "res://node.png", "setting": "set_tavern"}
	var line: Dictionary = {"image": "res://line.png", "setting": "set_tavern"}
	assert_str(JourneyData.resolved_background([_tavern()], node, line)).is_equal("res://line.png")


func test_a_lines_setting_beats_the_nodes_image() -> void:
	var node: Dictionary = {"image": "res://node.png"}
	var line: Dictionary = {"setting": "set_tavern", "setting_bg": "bgd_night"}
	assert_str(JourneyData.resolved_background([_tavern()], node, line)).is_equal(
		"res://tavern_night.png"
	)


func test_a_node_image_beats_the_nodes_own_setting() -> void:
	# The explicit statement wins at the same level — and this is the shape every storyboard authored
	# before settings existed has, so adding a setting above one must not change what it shows.
	var node: Dictionary = {"image": "res://node.png", "setting": "set_tavern"}
	assert_str(JourneyData.resolved_background([_tavern()], node, {})).is_equal("res://node.png")


func test_a_node_setting_supplies_the_background_when_nothing_else_does() -> void:
	var node: Dictionary = {"setting": "set_tavern"}
	assert_str(JourneyData.resolved_background([_tavern()], node, {})).is_equal(
		"res://tavern_day.png"
	)


func test_a_scene_with_no_setting_and_no_image_shows_nothing() -> void:
	assert_str(JourneyData.resolved_background([_tavern()], {}, {})).is_equal("")


# ── BGM precedence ───────────────────────────────────────────────────────────


func test_a_line_clip_beats_the_setting_and_the_journey() -> void:
	var node: Dictionary = {"setting": "set_tavern"}
	var line: Dictionary = {"bgm": "res://line.ogg", "bgm_volume": 0.9}
	var got: Dictionary = JourneyData.resolved_bgm(
		[_tavern()], node, line, ["res://journey.ogg"], 0.5
	)
	assert_str(got["clip"]).is_equal("res://line.ogg")
	assert_float(got["volume"]).is_equal_approx(0.9, 0.001)


func test_a_settings_theme_beats_the_journey_score() -> void:
	var got: Dictionary = JourneyData.resolved_bgm(
		[_tavern()], {"setting": "set_tavern"}, {}, ["res://journey.ogg"], 0.5
	)
	assert_str(got["clip"]).is_equal("res://tavern.ogg")


func test_a_nodes_own_clip_beats_its_setting() -> void:
	# Same reasoning as the node image: an existing storyboard's BGM must keep winning after a setting
	# is applied above it, or adding a place would silently retheme a finished scene.
	var node: Dictionary = {"bgm": "res://node.ogg", "setting": "set_tavern"}
	var got: Dictionary = JourneyData.resolved_bgm([_tavern()], node, {}, [], 0.5)
	assert_str(got["clip"]).is_equal("res://node.ogg")


func test_the_journey_score_carries_its_whole_playlist() -> void:
	# The identity of the journey score is the LIST, not one track: any of them playing means the right
	# music is already on, which is what stops it restarting at every node.
	var got: Dictionary = JourneyData.resolved_bgm([], {}, {}, ["res://a.ogg", "res://b.ogg"], 0.4)
	assert_array(got["playlist"]).contains_exactly(["res://a.ogg", "res://b.ogg"])
	assert_float(got["volume"]).is_equal_approx(0.4, 0.001)


func test_a_journey_with_no_score_and_no_setting_is_silent() -> void:
	assert_dict(JourneyData.resolved_bgm([], {}, {}, [], 0.5)).is_empty()


func test_blank_journey_tracks_are_dropped_rather_than_played() -> void:
	# An author who added a track row and never filled it should get silence, not a load error.
	assert_dict(JourneyData.resolved_bgm([], {}, {}, ["", ""], 0.5)).is_empty()


# ── Continuity ───────────────────────────────────────────────────────────────


func test_two_scenes_on_one_setting_resolve_to_the_same_playlist() -> void:
	# This is the whole feature: SettingMusic compares the resolved playlist against what is already
	# playing and does nothing when they match, so equality here IS the music not restarting.
	var settings: Array = [_tavern()]
	var first: Dictionary = JourneyData.resolved_bgm(settings, {"setting": "set_tavern"}, {})
	var second: Dictionary = JourneyData.resolved_bgm(
		settings, {"setting": "set_tavern"}, {"setting": "set_tavern", "setting_bg": "bgd_night"}
	)
	# Different background variant, same place — so the same music, uninterrupted.
	assert_array(second["playlist"]).contains_exactly(first["playlist"])


# ── Framing ──────────────────────────────────────────────────────────────────


func test_a_backgrounds_framing_rides_along_with_its_path() -> void:
	var framed: Array = [
		_setting(
			"set_a",
			"A",
			[
				{
					"id": "bgd_a",
					"name": "",
					"path": "res://a.png",
					"image_fit": "crop",
					"focus_x": 0.25,
					"focus_y": 0.0,
					"zoom": 1.5,
				}
			]
		)
	]
	var view: Dictionary = JourneyData.resolved_background_view(framed, {"setting": "set_a"}, {})
	assert_str(view["image_fit"]).is_equal("crop")
	assert_float(view["focus_x"]).is_equal_approx(0.25, 0.001)
	assert_float(view["zoom"]).is_equal_approx(1.5, 0.001)


func test_a_plain_node_image_carries_no_framing_of_its_own() -> void:
	# So each surface keeps the framing it has always used for its own image — adding settings to a
	# journey must not restage the scenes that were authored before them.
	var view: Dictionary = JourneyData.resolved_background_view([], {"image": "res://n.png"}, {})
	assert_str(view["image_fit"]).is_equal("")
	assert_float(view["focus_x"]).is_equal_approx(0.5, 0.001)
	assert_float(view["zoom"]).is_equal_approx(1.0, 0.001)


func test_the_retired_edge_presets_migrate_to_focal_points() -> void:
	# "top" and the rest were always particular focal points, so a journey authored against them keeps
	# the framing it was given rather than snapping back to centre.
	var raw: Array = [
		{
			"Id": "set_a",
			"Name": "A",
			"Backgrounds":
			[
				{"Id": "b1", "Path": "a.png", "Fit": "crop", "Align": "top"},
				{"Id": "b2", "Path": "b.png", "Fit": "crop", "Align": "right"},
				{"Id": "b3", "Path": "c.png", "Fit": "crop"},
			],
		}
	]
	var backgrounds: Array = JourneyData.parse_journey_settings(raw)[0]["backgrounds"]
	assert_float(backgrounds[0]["focus_y"]).is_equal_approx(0.0, 0.001)
	assert_float(backgrounds[0]["focus_x"]).is_equal_approx(0.5, 0.001)  # untouched axis stays centred
	assert_float(backgrounds[1]["focus_x"]).is_equal_approx(1.0, 0.001)
	assert_float(backgrounds[2]["focus_x"]).is_equal_approx(0.5, 0.001)


func test_a_numeric_focus_wins_over_a_legacy_preset() -> void:
	# Both present means the background was re-framed after the migration; the number is the newer
	# statement and the preset is a leftover.
	var raw: Array = [
		{
			"Id": "set_a",
			"Name": "A",
			"Backgrounds": [{"Id": "b1", "Path": "a.png", "Align": "top", "FocusY": 0.8}],
		}
	]
	var backgrounds: Array = JourneyData.parse_journey_settings(raw)[0]["backgrounds"]
	assert_float(backgrounds[0]["focus_y"]).is_equal_approx(0.8, 0.001)


func test_zoom_never_falls_below_cover() -> void:
	# Under 1.0 a crop stops covering and gaps appear at the edges — which is what the Fit mode is for.
	var raw: Array = [
		{
			"Id": "set_a",
			"Name": "A",
			"Backgrounds": [{"Id": "b1", "Path": "a.png", "Zoom": 0.4}],
		}
	]
	var backgrounds: Array = JourneyData.parse_journey_settings(raw)[0]["backgrounds"]
	assert_float(backgrounds[0]["zoom"]).is_equal_approx(1.0, 0.001)


# ── Reference counting (delete guard, row badge, audit) ──────────────────────


func _node(data: Dictionary) -> Dictionary:
	return {"type": "storyboard", "data": data, "out": []}


func test_a_setting_used_by_nothing_counts_zero() -> void:
	var nodes: Dictionary = {"n1": _node({"setting": "set_other"}), "n2": _node({})}
	assert_int(JourneyData.setting_reference_count(nodes, "set_tavern")).is_equal(0)


func test_nodes_and_storyboard_lines_both_count() -> void:
	# A line reference breaks exactly as a node reference does when the setting goes, so the delete
	# guard has to see both — counting only nodes would call a setting unused while lines still used it.
	var nodes: Dictionary = {
		"n1": _node({"setting": "set_tavern"}),
		"n2":
		_node(
			{
				"setting": "",
				"lines": [{"setting": "set_tavern"}, {"setting": ""}, {"setting": "set_tavern"}],
			}
		),
	}
	assert_int(JourneyData.setting_reference_count(nodes, "set_tavern")).is_equal(3)


func test_an_empty_id_never_matches_an_unset_node() -> void:
	# Every node without a setting carries "" — counting those would report the blank id as the most
	# used setting in the journey.
	var nodes: Dictionary = {"n1": _node({"setting": ""}), "n2": _node({})}
	assert_int(JourneyData.setting_reference_count(nodes, "")).is_equal(0)


# ── Media enumeration (pooling + packaging) ──────────────────────────────────


func test_every_setting_asset_is_enumerated_for_pooling() -> void:
	var sources: Array = JourneyData.settings_media_sources([_tavern()])
	assert_array(sources).contains(
		["res://tavern_day.png", "res://tavern_night.png", "res://tavern.ogg"]
	)


func test_a_shared_asset_is_only_listed_once() -> void:
	var shared: Array = [
		_setting("set_a", "A", [_background("bgd_a", "", "res://same.png")]),
		_setting("set_b", "B", [_background("bgd_b", "", "res://same.png")]),
	]
	assert_int(JourneyData.settings_media_sources(shared).size()).is_equal(1)
