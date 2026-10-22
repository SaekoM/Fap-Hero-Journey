class_name StashClient
extends RefCounted
## Talks to a Stash instance (stashapp) over its GraphQL API, for the randomizer's Stash import
## (STASH_DESIGN.md). Everything Stash-specific lives here, so a change to Stash's API is a change to
## this one file.
##
## Two halves:
##   * Static and pure: address clean-up, the queries, response parsing and path mapping. Unit-tested.
##   * The requests themselves: one HTTPRequest per call, parented to `host` while it runs. Each
##     returns {ok, error, ...}; `error` is one of the ERROR_* codes, with Stash's own words in
##     `message` when it sent any.
##
## The API key goes in the `ApiKey` header (Stash's documented route) and nowhere else: never into a
## URL, a saved file or a log.

const DEFAULT_PORT: int = 9999
const REQUEST_TIMEOUT_S: float = 20.0
# Scenes per findScenes page. Each scene is small, so this is about round trips, not memory.
const PAGE_SIZE: int = 100

const ERROR_UNREACHABLE: String = "unreachable"  # no answer: wrong address, Stash off, a firewall
const ERROR_UNAUTHORIZED: String = "unauthorized"  # 401/403: a missing or wrong API key
const ERROR_HTTP: String = "http"  # any other HTTP failure
const ERROR_BAD_RESPONSE: String = "bad_response"  # an answer that isn't the JSON we asked for
const ERROR_GRAPHQL: String = "graphql"  # Stash understood the request and refused it

# Fingerprints that identify a file's content, best first. oshash is Stash's default and always
# computed; md5 only when the instance is set to calculate it. phash is perceptual, not an identity.
const FINGERPRINT_PREFERENCE: Array = ["oshash", "md5"]

const VERSION_QUERY: String = "query { version { version } }"

const TAGS_QUERY: String = """
query FindTags($filter: FindFilterType) {
  findTags(filter: $filter) {
    tags { id name }
  }
}
"""

const SCENE_COUNT_QUERY: String = """
query CountScenes($scene_filter: SceneFilterType) {
  findScenes(scene_filter: $scene_filter, filter: { per_page: 1 }) {
    count
  }
}
"""

const SCENES_QUERY: String = """
query FindScenes($scene_filter: SceneFilterType, $filter: FindFilterType) {
  findScenes(scene_filter: $scene_filter, filter: $filter) {
    count
    scenes {
      id
      title
      tags { id name }
      files {
        path
        basename
        size
        duration
        video_codec
        format
        fingerprints { type value }
      }
      paths { stream funscript }
    }
  }
}
"""

const PRESENT_QUERY: String = """
query PresentScenes($ids: [ID!], $scene_filter: SceneFilterType) {
  findScenes(ids: $ids, scene_filter: $scene_filter, filter: { per_page: -1 }) {
    scenes { id }
  }
}
"""

var _host: Node
var _address: String
var _api_key: String


func _init(host: Node, address: String, api_key: String) -> void:
	_host = host
	_address = normalize_address(address)
	_api_key = api_key.strip_edges()


# ── Requests ─────────────────────────────────────────────────────────────────


# Checks the address and key: {ok, error, message, version, interactive_count}. The count is what the
# panel shows on success, so a working connection to an instance with no interactive scenes is plain.
func test_connection() -> Dictionary:
	var version: Dictionary = await _query(VERSION_QUERY, {})
	if not version["ok"]:
		return version
	var counted: Dictionary = await count_scenes([])
	if not counted["ok"]:
		return counted
	var data: Dictionary = version["data"]
	var version_name: String = str((data.get("version", {}) as Dictionary).get("version", ""))
	return _success({"version": version_name, "interactive_count": counted["count"]})


# Every tag on the instance, by name: {ok, error, message, tags: [{id, name}]}.
func fetch_tags() -> Dictionary:
	var filter: Dictionary = {"per_page": -1, "sort": "name", "direction": "ASC"}
	var answer: Dictionary = await _query(TAGS_QUERY, {"filter": filter})
	if not answer["ok"]:
		return answer
	return _success({"tags": parse_tags(answer["data"])})


# How many interactive scenes carry any of `tag_ids` (all of them when empty): {ok, error, message,
# count}. The preview before an import.
func count_scenes(tag_ids: Array) -> Dictionary:
	var answer: Dictionary = await _query(
		SCENE_COUNT_QUERY, {"scene_filter": scene_filter(tag_ids)}
	)
	if not answer["ok"]:
		return answer
	var found: Dictionary = (answer["data"] as Dictionary).get("findScenes", {})
	return _success({"count": int(found.get("count", 0))})


# Every interactive scene carrying any of `tag_ids` (all of them when empty), page by page, parsed by
# parse_scene: {ok, error, message, scenes}. Scenes without a file are left out.
func fetch_scenes(tag_ids: Array) -> Dictionary:
	var scenes: Array = []
	var page: int = 1
	while true:
		var answer: Dictionary = await _fetch_page(tag_ids, page, PAGE_SIZE)
		if not answer["ok"]:
			return answer
		scenes.append_array(answer["scenes"])
		# An empty page ends it even if `count` promised more, so a library changing mid-import can't
		# loop forever.
		if int(answer["page_size"]) == 0 or page * PAGE_SIZE >= int(answer["count"]):
			break
		page += 1
	return _success({"scenes": scenes})


# Which of the scenes `ids` Stash still has as interactive scenes, whatever their tags:
# {ok, error, message, ids: {scene_id: true}}. SYNC asks this to tell a deleted scene from one that
# only lost its tags.
func fetch_present_ids(ids: Array) -> Dictionary:
	if ids.is_empty():
		return _success({"ids": {}})
	var wanted: Array = []
	for id: Variant in ids:
		wanted.append(str(id))
	var answer: Dictionary = await _query(
		PRESENT_QUERY, {"ids": wanted, "scene_filter": scene_filter([])}
	)
	if not answer["ok"]:
		return answer
	var present: Dictionary = {}
	var found: Dictionary = (answer["data"] as Dictionary).get("findScenes", {})
	for raw: Variant in found.get("scenes", []):
		if raw is Dictionary:
			present[str((raw as Dictionary).get("id", ""))] = true
	return _success({"ids": present})


# The first `count` interactive scenes: what the panel shows to check the path mappings against.
func fetch_sample(count: int) -> Dictionary:
	return await _fetch_page([], 1, count)


# One page of findScenes: {ok, error, message, scenes, count (all matching), page_size (as sent)}.
func _fetch_page(tag_ids: Array, page: int, per_page: int) -> Dictionary:
	var variables: Dictionary = {
		"scene_filter": scene_filter(tag_ids),
		# Sorted by path so pages don't shuffle between requests.
		"filter": {"page": page, "per_page": per_page, "sort": "path", "direction": "ASC"},
	}
	var answer: Dictionary = await _query(SCENES_QUERY, variables)
	if not answer["ok"]:
		return answer
	var found: Dictionary = (answer["data"] as Dictionary).get("findScenes", {})
	var batch: Array = found.get("scenes", []) as Array
	var scenes: Array = []
	for raw: Variant in batch:
		var scene: Dictionary = parse_scene(raw as Dictionary)
		if not scene.is_empty():
			scenes.append(scene)
	return _success(
		{"scenes": scenes, "count": int(found.get("count", 0)), "page_size": batch.size()}
	)


# One GraphQL request: {ok, error, message, data}.
func _query(query: String, variables: Dictionary) -> Dictionary:
	if _address == "":
		return failure(ERROR_UNREACHABLE)
	var request: HTTPRequest = HTTPRequest.new()
	request.timeout = REQUEST_TIMEOUT_S
	_host.add_child(request)
	var body: String = JSON.stringify({"query": query, "variables": variables})
	var err: Error = request.request(
		graphql_url(_address), headers(_api_key), HTTPClient.METHOD_POST, body
	)
	if err != OK:
		request.queue_free()
		return failure(ERROR_UNREACHABLE)
	var result: Array = await request.request_completed
	request.queue_free()
	# result: [result_code, response_code, headers, body]
	return parse_response(int(result[0]), int(result[1]), result[3] as PackedByteArray)


# ── Pure helpers ─────────────────────────────────────────────────────────────


# The address as typed, made into a base URL: trimmed, "http://" when no scheme is given, no trailing
# slash or "/graphql". A bare host gets Stash's default port; one typed with a scheme is taken as is,
# since it may be behind a proxy on 80 or 443.
static func normalize_address(raw: String) -> String:
	var address: String = raw.strip_edges()
	if address == "":
		return ""
	var had_scheme: bool = address.contains("://")
	if not had_scheme:
		address = "http://" + address
	while address.ends_with("/"):
		address = address.left(-1)
	if address.ends_with("/graphql"):
		address = address.left(-"/graphql".length())
	var authority: String = address.get_slice("://", 1).get_slice("/", 0)
	if not had_scheme and not authority.contains(":"):
		address = address.replace("://" + authority, "://%s:%d" % [authority, DEFAULT_PORT])
	return address


static func graphql_url(address: String) -> String:
	return address + "/graphql"


# The request headers. An instance with no login set up needs no key, so none is sent.
static func headers(api_key: String) -> PackedStringArray:
	var out: PackedStringArray = ["Content-Type: application/json", "Accept: application/json"]
	if api_key != "":
		out.append("ApiKey: " + api_key)
	return out


# The scene filter for an import: interactive scenes only, narrowed to those carrying ANY of `tag_ids`
# when there are some. Sub-tags are not followed (depth 0): picking "Blowjob" brings Blowjob scenes.
static func scene_filter(tag_ids: Array) -> Dictionary:
	var filter: Dictionary = {"interactive": true}
	if not tag_ids.is_empty():
		var ids: Array = []
		for id: Variant in tag_ids:
			ids.append(str(id))
		filter["tags"] = {"value": ids, "modifier": "INCLUDES", "depth": 0}
	return filter


# Turns an HTTPRequest result into {ok, error, message, data}. A GraphQL error comes back as HTTP 200
# with an `errors` list, so the body is checked even when the status is fine.
static func parse_response(
	result_code: int, response_code: int, body: PackedByteArray
) -> Dictionary:
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return failure(ERROR_UNREACHABLE)
	if response_code == 401 or response_code == 403:
		return failure(ERROR_UNAUTHORIZED)
	if response_code >= 400:
		return failure(ERROR_HTTP, "HTTP %d" % response_code)
	var parser: JSON = JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK or not (parser.data is Dictionary):
		return failure(ERROR_BAD_RESPONSE)
	var answer: Dictionary = parser.data
	var errors: Array = answer.get("errors", []) if answer.get("errors") is Array else []
	if not errors.is_empty():
		var first: Variant = errors[0]
		var message: String = (
			str((first as Dictionary).get("message", "")) if first is Dictionary else ""
		)
		return failure(ERROR_GRAPHQL, message)
	if not (answer.get("data") is Dictionary):
		return failure(ERROR_BAD_RESPONSE)
	return _success({"data": answer["data"]})


# The tags of a findTags answer, as [{id, name}].
static func parse_tags(data: Dictionary) -> Array:
	var tags: Array = []
	for raw: Variant in (data.get("findTags", {}) as Dictionary).get("tags", []):
		if raw is Dictionary:
			var tag: Dictionary = raw
			tags.append({"id": str(tag.get("id", "")), "name": str(tag.get("name", ""))})
	return tags


# One scene from findScenes, flattened to what the library needs, or {} for a scene with no file.
# Only the first file counts: Stash lists a scene's primary file first, and the others are duplicates.
#   {id, name, tags: [names], path, size, duration_ms, video_codec, format, fingerprint,
#    stream_url, funscript_url}
static func parse_scene(raw: Dictionary) -> Dictionary:
	var files: Array = raw.get("files", []) if raw.get("files") is Array else []
	if files.is_empty() or not (files[0] is Dictionary):
		return {}
	var file: Dictionary = files[0]
	var path: String = str(file.get("path", ""))
	if path == "":
		return {}
	var raw_tags: Array = raw.get("tags", []) if raw.get("tags") is Array else []
	var tag_names: Array = []
	for tag: Variant in raw_tags:
		if tag is Dictionary and str((tag as Dictionary).get("name", "")) != "":
			tag_names.append(str((tag as Dictionary)["name"]))
	var paths: Dictionary = raw.get("paths", {}) if raw.get("paths") is Dictionary else {}
	var title: String = str(raw.get("title", "")).strip_edges()
	var basename: String = str(file.get("basename", path.get_file()))
	return {
		"id": str(raw.get("id", "")),
		# The scene's title when it has one, else the file name, as the library names a folder import.
		"name": title if title != "" else basename.get_basename(),
		"tags": tag_names,
		"path": path,
		"size": int(file.get("size", 0)),
		"duration_ms": int(round(float(file.get("duration", 0.0)) * 1000.0)),
		"video_codec": str(file.get("video_codec", "")),
		"format": str(file.get("format", "")),
		"fingerprint": preferred_fingerprint(file.get("fingerprints", [])),
		"stream_url": strip_api_key(str(paths.get("stream", ""))),
		"funscript_url": strip_api_key(str(paths.get("funscript", ""))),
	}


# The file's content fingerprint as "type:value", by FINGERPRINT_PREFERENCE, or "" when it has none.
static func preferred_fingerprint(raw: Variant) -> String:
	var by_type: Dictionary = {}
	if raw is Array:
		for entry: Variant in raw:
			if entry is Dictionary:
				var fingerprint: Dictionary = entry
				by_type[str(fingerprint.get("type", ""))] = str(fingerprint.get("value", ""))
	for kind: String in FINGERPRINT_PREFERENCE:
		if str(by_type.get(kind, "")) != "":
			return "%s:%s" % [kind, by_type[kind]]
	return ""


# A Stash media URL without any `apikey` query parameter. Stash may add the key to the URLs it hands
# out, so they work in a browser; ours are saved in the library, where the key must never be.
static func strip_api_key(url: String) -> String:
	var query_at: int = url.find("?")
	if query_at < 0:
		return url
	var kept: PackedStringArray = []
	for part: String in url.substr(query_at + 1).split("&", false):
		if not part.to_lower().begins_with("apikey="):
			kept.append(part)
	var base: String = url.left(query_at)
	return base if kept.is_empty() else base + "?" + "&".join(kept)


# Where a file Stash knows by `stash_path` lives on this PC, by the author's path mappings
# ([{from, to}]: Stash's folder → the same folder as this PC reaches it), or "" when none applies.
# The longest matching `from` wins, so "/data" → Z:/ and "/data/vr" → Y:/ can coexist. Matching is by
# whole folder names and ignores case and slash direction, since Stash may run on Linux or Windows;
# the result uses forward slashes, which Godot accepts on every platform.
static func map_path(stash_path: String, mappings: Array) -> String:
	var path: String = _forward_slashes(stash_path)
	var best_from: String = ""
	var best_to: String = ""
	for mapping: Variant in mappings:
		if not (mapping is Dictionary):
			continue
		var pair: Dictionary = mapping
		# Without their trailing slashes, so "Z:/" and "Z:" both join as "Z:" + "/videos/…".
		var from: String = _forward_slashes(str(pair.get("from", ""))).rstrip("/")
		var to: String = _forward_slashes(str(pair.get("to", ""))).rstrip("/")
		if from == "" or to == "" or from.length() <= best_from.length():
			continue
		var lower_path: String = path.to_lower()
		var lower_from: String = from.to_lower()
		if lower_path == lower_from or lower_path.begins_with(lower_from + "/"):
			best_from = from
			best_to = to
	if best_from == "":
		return ""
	return best_to + path.substr(best_from.length())


# Where this PC finds a file Stash names `stash_path`: through the path mappings, or as is when Stash
# runs on this PC. "" when neither reaches an existing file. (Reads the disk, unlike map_path.)
static func local_path(stash_path: String, mappings: Array) -> String:
	var mapped: String = map_path(stash_path, mappings)
	if mapped != "" and FileAccess.file_exists(mapped):
		return mapped
	if FileAccess.file_exists(stash_path):
		return stash_path
	return ""


static func _forward_slashes(path: String) -> String:
	return path.strip_edges().replace("\\", "/")


# What a failed request means, for the player.
static func error_text(result: Dictionary) -> String:
	var message: String = str(result.get("message", ""))
	match str(result.get("error", "")):
		ERROR_UNREACHABLE:
			return "Couldn't reach Stash. Check that it's running and that the address and port are right."
		ERROR_UNAUTHORIZED:
			return "Stash refused the API key. Copy it again from Stash's Settings → Security."
		ERROR_HTTP:
			return "Stash answered with an error (%s)." % message
		ERROR_BAD_RESPONSE:
			return (
				"Something answered at that address, but not the way Stash does. Check the address "
				+ "(Stash's own port is %d)." % DEFAULT_PORT
			)
		ERROR_GRAPHQL:
			return "Stash couldn't run the request: %s" % message
	return "Something went wrong talking to Stash."


static func failure(error: String, message: String = "") -> Dictionary:
	return {"ok": false, "error": error, "message": message}


static func _success(fields: Dictionary) -> Dictionary:
	var out: Dictionary = {"ok": true, "error": "", "message": ""}
	out.merge(fields)
	return out
