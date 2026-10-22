extends GdUnitTestSuite

# StashClient's pure half (STASH_DESIGN.md): address clean-up, the import filter, response parsing and
# path mapping. The requests themselves need a live Stash and are checked by hand.

# ── Address ──────────────────────────────────────────────────────────────────


func test_a_bare_host_gets_http_and_the_default_port() -> void:
	assert_str(StashClient.normalize_address("192.168.1.10")).is_equal("http://192.168.1.10:9999")
	assert_str(StashClient.normalize_address("  nas.local  ")).is_equal("http://nas.local:9999")


func test_a_typed_port_is_kept() -> void:
	assert_str(StashClient.normalize_address("192.168.1.10:8080")).is_equal(
		"http://192.168.1.10:8080"
	)


# A scheme means the player typed a full URL, perhaps a proxy on 80 or 443: no port is added.
func test_an_address_with_a_scheme_is_taken_as_is() -> void:
	assert_str(StashClient.normalize_address("https://stash.example.lan")).is_equal(
		"https://stash.example.lan"
	)


func test_trailing_slashes_and_graphql_are_dropped() -> void:
	assert_str(StashClient.normalize_address("http://10.0.0.5:9999/graphql/")).is_equal(
		"http://10.0.0.5:9999"
	)
	assert_str(StashClient.normalize_address("10.0.0.5:9999/")).is_equal("http://10.0.0.5:9999")


func test_a_blank_address_stays_blank() -> void:
	assert_str(StashClient.normalize_address("   ")).is_equal("")


# ── Headers and filter ───────────────────────────────────────────────────────


func test_the_key_goes_in_the_apikey_header() -> void:
	assert_bool(StashClient.headers("secret").has("ApiKey: secret")).is_true()


func test_no_key_sends_no_apikey_header() -> void:
	for header: String in StashClient.headers(""):
		assert_bool(header.begins_with("ApiKey")).is_false()


func test_the_filter_is_interactive_only() -> void:
	assert_dict(StashClient.scene_filter([])).is_equal({"interactive": true})


func test_tags_narrow_to_any_of_them() -> void:
	(
		assert_dict(StashClient.scene_filter([12, "40"]))
		. is_equal(
			{
				"interactive": true,
				"tags": {"value": ["12", "40"], "modifier": "INCLUDES", "depth": 0},
			}
		)
	)


# ── Responses ────────────────────────────────────────────────────────────────


func _body(text: String) -> PackedByteArray:
	return text.to_utf8_buffer()


func test_a_good_answer_returns_its_data() -> void:
	var answer: Dictionary = StashClient.parse_response(
		HTTPRequest.RESULT_SUCCESS, 200, _body('{"data": {"version": {"version": "v0.28.1"}}}')
	)
	assert_bool(answer["ok"]).is_true()
	assert_str(str(answer["data"]["version"]["version"])).is_equal("v0.28.1")


func test_no_connection_is_unreachable() -> void:
	var answer: Dictionary = StashClient.parse_response(
		HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray()
	)
	assert_str(answer["error"]).is_equal(StashClient.ERROR_UNREACHABLE)


func test_a_refused_key_is_unauthorized() -> void:
	for code: int in [401, 403]:
		var answer: Dictionary = StashClient.parse_response(
			HTTPRequest.RESULT_SUCCESS, code, PackedByteArray()
		)
		assert_str(answer["error"]).is_equal(StashClient.ERROR_UNAUTHORIZED)


func test_other_http_failures_say_the_code() -> void:
	var answer: Dictionary = StashClient.parse_response(
		HTTPRequest.RESULT_SUCCESS, 502, PackedByteArray()
	)
	assert_str(answer["error"]).is_equal(StashClient.ERROR_HTTP)
	assert_str(answer["message"]).is_equal("HTTP 502")


# GraphQL refuses with HTTP 200 and an errors list; Stash's message is passed on.
func test_a_graphql_error_passes_on_its_message() -> void:
	var answer: Dictionary = StashClient.parse_response(
		HTTPRequest.RESULT_SUCCESS,
		200,
		_body('{"errors": [{"message": "Cannot query field \\"x\\""}], "data": null}')
	)
	assert_str(answer["error"]).is_equal(StashClient.ERROR_GRAPHQL)
	assert_str(answer["message"]).is_equal('Cannot query field "x"')


func test_a_non_json_answer_is_a_bad_response() -> void:
	for text: String in ["<html>login</html>", "[1, 2]", '{"nodata": true}']:
		var answer: Dictionary = StashClient.parse_response(
			HTTPRequest.RESULT_SUCCESS, 200, _body(text)
		)
		assert_str(answer["error"]).is_equal(StashClient.ERROR_BAD_RESPONSE)


func test_tags_parse_to_ids_and_names() -> void:
	var data: Dictionary = {
		"findTags": {"tags": [{"id": "3", "name": "PMV"}, {"id": "9", "name": "Edging"}]}
	}
	assert_array(StashClient.parse_tags(data)).is_equal(
		[{"id": "3", "name": "PMV"}, {"id": "9", "name": "Edging"}]
	)


# ── Scenes ───────────────────────────────────────────────────────────────────


func _scene(overrides: Dictionary = {}) -> Dictionary:
	var scene: Dictionary = {
		"id": "57",
		"title": "Cock Hero Vol. 3",
		"tags": [{"id": "3", "name": "PMV"}, {"id": "9", "name": "Edging"}],
		"files":
		[
			{
				"path": "/data/videos/ch3.mp4",
				"basename": "ch3.mp4",
				"size": 1048576,
				"duration": 612.48,
				"video_codec": "h264",
				"format": "mp4",
				"fingerprints":
				[
					{"type": "phash", "value": "d1f0"},
					{"type": "md5", "value": "aa11"},
					{"type": "oshash", "value": "bb22"},
				],
			},
		],
		"paths":
		{
			"stream": "http://nas:9999/scene/57/stream?apikey=secret",
			"funscript": "http://nas:9999/scene/57/funscript",
		},
	}
	scene.merge(overrides, true)
	return scene


func test_a_scene_flattens_to_what_the_library_needs() -> void:
	var scene: Dictionary = StashClient.parse_scene(_scene())
	assert_str(scene["id"]).is_equal("57")
	assert_str(scene["name"]).is_equal("Cock Hero Vol. 3")
	assert_array(scene["tags"]).is_equal(["PMV", "Edging"])
	assert_str(scene["path"]).is_equal("/data/videos/ch3.mp4")
	assert_int(scene["duration_ms"]).is_equal(612480)
	assert_str(scene["video_codec"]).is_equal("h264")
	assert_str(scene["funscript_url"]).is_equal("http://nas:9999/scene/57/funscript")


# The key must never reach the library, even when Stash writes it into the URLs it hands out.
func test_the_api_key_is_stripped_from_scene_urls() -> void:
	var scene: Dictionary = StashClient.parse_scene(_scene())
	assert_str(scene["stream_url"]).is_equal("http://nas:9999/scene/57/stream")
	(
		assert_str(
			StashClient.strip_api_key("http://nas/scene/1/stream?resolution=ORIGINAL&apikey=s&x=1")
		)
		. is_equal("http://nas/scene/1/stream?resolution=ORIGINAL&x=1")
	)


func test_an_untitled_scene_is_named_after_its_file() -> void:
	assert_str(StashClient.parse_scene(_scene({"title": "  "}))["name"]).is_equal("ch3")


# oshash first, md5 next, and phash never: it is perceptual, not an identity.
func test_the_fingerprint_prefers_oshash_then_md5() -> void:
	assert_str(StashClient.parse_scene(_scene())["fingerprint"]).is_equal("oshash:bb22")
	assert_str(StashClient.preferred_fingerprint([{"type": "md5", "value": "aa11"}])).is_equal(
		"md5:aa11"
	)
	assert_str(StashClient.preferred_fingerprint([{"type": "phash", "value": "d1f0"}])).is_equal("")


func test_a_scene_without_a_file_is_skipped() -> void:
	assert_dict(StashClient.parse_scene(_scene({"files": []}))).is_empty()
	assert_dict(StashClient.parse_scene(_scene({"files": [{"path": ""}]}))).is_empty()


# ── Path mapping ─────────────────────────────────────────────────────────────


func test_a_mapping_swaps_the_folder() -> void:
	var mappings: Array = [{"from": "/data", "to": "Z:/"}]
	assert_str(StashClient.map_path("/data/videos/ch3.mp4", mappings)).is_equal("Z:/videos/ch3.mp4")


func test_a_share_mapping_uses_forward_slashes() -> void:
	var mappings: Array = [{"from": "/data/", "to": "\\\\nas\\media"}]
	assert_str(StashClient.map_path("/data/videos/ch3.mp4", mappings)).is_equal(
		"//nas/media/videos/ch3.mp4"
	)


# Stash on Windows reports backslashes and its own drive letters, in whatever case.
func test_matching_ignores_slash_direction_and_case() -> void:
	var mappings: Array = [{"from": "D:/Stash", "to": "//pc/stash"}]
	assert_str(StashClient.map_path("d:\\stash\\Clip.mp4", mappings)).is_equal(
		"//pc/stash/Clip.mp4"
	)


func test_the_longest_matching_folder_wins() -> void:
	var mappings: Array = [{"from": "/data", "to": "Z:"}, {"from": "/data/vr", "to": "Y:"}]
	assert_str(StashClient.map_path("/data/vr/a.mp4", mappings)).is_equal("Y:/a.mp4")
	assert_str(StashClient.map_path("/data/flat/a.mp4", mappings)).is_equal("Z:/flat/a.mp4")


# "/data" must not claim "/database": folders match whole.
func test_a_mapping_matches_whole_folder_names_only() -> void:
	var mappings: Array = [{"from": "/data", "to": "Z:"}]
	assert_str(StashClient.map_path("/database/a.mp4", mappings)).is_equal("")


func test_no_matching_mapping_gives_nothing() -> void:
	assert_str(StashClient.map_path("/data/a.mp4", [])).is_equal("")
	assert_str(StashClient.map_path("/data/a.mp4", [{"from": "", "to": "Z:"}])).is_equal("")
	assert_str(StashClient.map_path("/data/a.mp4", [{"from": "/other", "to": "Z:"}])).is_equal("")


# ── Library link ─────────────────────────────────────────────────────────────


# A clip from files or a folder carries no link; RandomizerLibrary._coerce_entry drops unlisted keys,
# so the Stash fields must survive it.
func test_a_plain_clip_has_no_stash_link() -> void:
	var entry: Dictionary = RandomizerLibrary._coerce_entry({"id": "a"})
	assert_dict(entry["stash"]).is_empty()
	assert_array(entry["stash_tags"]).is_empty()


func test_a_stash_link_survives_coercion() -> void:
	var entry: Dictionary = (
		RandomizerLibrary
		. _coerce_entry(
			{
				"id": "a",
				"stash": {"scene_id": 57, "fingerprint": "oshash:bb22", "junk": true},
				"stash_tags": ["PMV", " pmv", "Edging"],
			}
		)
	)
	assert_dict(entry["stash"]).is_equal({"scene_id": "57", "fingerprint": "oshash:bb22"})
	assert_array(entry["stash_tags"]).is_equal(["pmv", "edging"])


func test_a_link_without_a_scene_is_dropped() -> void:
	var entry: Dictionary = RandomizerLibrary._coerce_entry(
		{"id": "a", "stash": {"scene_id": "", "fingerprint": "x"}}
	)
	assert_dict(entry["stash"]).is_empty()
