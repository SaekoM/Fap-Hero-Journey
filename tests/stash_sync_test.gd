extends GdUnitTestSuite

# StashSync (STASH_DESIGN.md): what SYNC decides about each Stash clip — its tags, whether it needs
# importing again, and whether it's flagged.

# ── Tags ─────────────────────────────────────────────────────────────────────


# A tag Stash dropped comes off; a tag the player added here stays.
func test_a_tag_stash_dropped_comes_off_and_the_players_stay() -> void:
	(
		assert_array(
			StashSync.merged_tags(["pmv", "favourite", "edging"], ["pmv", "edging"], ["pmv"])
		)
		. is_equal(["pmv", "favourite"])
	)


func test_a_tag_stash_added_goes_on() -> void:
	assert_array(StashSync.merged_tags(["pmv", "favourite"], ["pmv"], ["pmv", "BBC"])).is_equal(
		["pmv", "favourite", "bbc"]
	)


# The first import: no Stash tags yet, so everything Stash gives is added and nothing removed.
func test_the_first_link_only_adds() -> void:
	assert_array(StashSync.merged_tags(["ch"], [], ["PMV", "ch"])).is_equal(["ch", "pmv"])


func test_tags_compare_as_the_library_stores_them() -> void:
	assert_array(StashSync.merged_tags(["pmv"], [" PMV "], [])).is_empty()


# ── Re-import ────────────────────────────────────────────────────────────────


func _entry() -> Dictionary:
	return {
		"video_src": "Z:/videos/ch3.mp4",
		"funscript_src": "Z:/videos/ch3.funscript",
		"axis_src": {"R0": "Z:/videos/ch3.twist.funscript"},
		"vib_src": {},
		"stash": {"scene_id": "57", "fingerprint": "oshash:bb22"},
	}


func _siblings() -> Dictionary:
	return {
		"funscript": "Z:/videos/ch3.funscript",
		"axis": {"R0": "Z:/videos/ch3.twist.funscript"},
		"vib": {},
	}


func test_an_unchanged_clip_is_only_retagged() -> void:
	(
		assert_bool(
			StashSync.needs_reimport(_entry(), "Z:/videos/ch3.mp4", "oshash:bb22", _siblings())
		)
		. is_false()
	)


func test_a_moved_file_is_reimported() -> void:
	(
		assert_bool(
			StashSync.needs_reimport(_entry(), "Z:/videos/new/ch3.mp4", "oshash:bb22", _siblings())
		)
		. is_true()
	)


func test_a_changed_file_is_reimported() -> void:
	(
		assert_bool(
			StashSync.needs_reimport(_entry(), "Z:/videos/ch3.mp4", "oshash:ff00", _siblings())
		)
		. is_true()
	)


# A scene with no fingerprint can't tell us its file changed, so that alone never forces a re-import.
func test_a_missing_fingerprint_is_not_a_change() -> void:
	assert_bool(StashSync.needs_reimport(_entry(), "Z:/videos/ch3.mp4", "", _siblings())).is_false()


func test_new_or_changed_scripts_reimport() -> void:
	var with_roll: Dictionary = _siblings()
	with_roll["axis"] = {
		"R0": "Z:/videos/ch3.twist.funscript", "R1": "Z:/videos/ch3.roll.funscript"
	}
	(
		assert_bool(
			StashSync.needs_reimport(_entry(), "Z:/videos/ch3.mp4", "oshash:bb22", with_roll)
		)
		. is_true()
	)
	var with_vibe: Dictionary = _siblings()
	with_vibe["vib"] = {"vibe1": "Z:/videos/ch3.vib.funscript"}
	(
		assert_bool(
			StashSync.needs_reimport(_entry(), "Z:/videos/ch3.mp4", "oshash:bb22", with_vibe)
		)
		. is_true()
	)
	var new_main: Dictionary = _siblings()
	new_main["funscript"] = "Z:/videos/ch3 (v2).funscript"
	(
		assert_bool(
			StashSync.needs_reimport(_entry(), "Z:/videos/ch3.mp4", "oshash:bb22", new_main)
		)
		. is_true()
	)


# ── Flags ────────────────────────────────────────────────────────────────────


func test_found_scenes_carry_no_flag() -> void:
	assert_dict(StashSync.flags(["1", "2"], {"1": true, "2": true}, {})).is_equal(
		{"1": "", "2": ""}
	)


# Not fetched, and Stash no longer has it as an interactive scene: gone.
func test_a_scene_stash_lost_is_gone() -> void:
	assert_dict(StashSync.flags(["1", "2"], {"1": true}, {})).is_equal(
		{"1": "", "2": StashSync.FLAG_GONE}
	)


# Not fetched under the tag filter, but still in Stash: it only lost its tags.
func test_a_scene_outside_the_tags_is_unmatched() -> void:
	assert_dict(StashSync.flags(["1", "2"], {"1": true}, {"2": true})).is_equal(
		{"1": "", "2": StashSync.FLAG_UNMATCHED}
	)


func test_each_flag_explains_itself() -> void:
	assert_str(StashSync.flag_text(StashSync.FLAG_GONE)).contains("Gone from Stash")
	assert_str(StashSync.flag_text(StashSync.FLAG_UNMATCHED)).contains("tags")
	assert_str(StashSync.flag_text("")).is_empty()
