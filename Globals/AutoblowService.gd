extends Node

# ---------------------------------------------------------------------------
# AutoblowService  (autoload)
#
# Autoblow Ultra and Vacuglide over Autoblow's cloud API (developers.autoblow.com, HTTP API v1). EXPERIMENTAL and
# untested on a real device: only switched on in the editor or with the EXPERIMENTAL_SETTING project setting (see
# available()), so release builds don't show it until it's been tried on hardware. See AUTOBLOW_DESIGN.md.
#
# How it plays a round: the whole script (with stroke effects and the player's stroke range baked in) is uploaded
# once, then started at the video's position. Pause stops it, resume and seek start it again at the video's
# position, so a pause never leaves drift. A mid-round change (an item, a curse, the range slider) re-uploads and
# restarts at the live position; the old script plays on for the second or two the upload takes. Filler between
# rounds uses the devices' live speed controls instead (the Ultra's oscillator, the Vacuglide's target speed).
#
# The device token goes in the x-device-token header only, never a URL or the log. Every request's result is
# logged (path, status, time, rate-limit headroom) so a player's log is enough to diagnose a problem.
# ---------------------------------------------------------------------------

signal connection_changed(connected: bool)

const EXPERIMENTAL_SETTING: String = "fhj/experimental/autoblow"
const DISCOVERY_HOST: String = "https://latency.autoblowapi.com"
const CLUSTER_HOST: String = "https://%s.autoblowapi.com"
const REQUEST_TIMEOUT_S: float = 10.0
const UPLOAD_TIMEOUT_S: float = 60.0  # the API asks for at least 60 s on uploads
const RESYNC_AFTER_MS: int = 600000  # re-check the device (and its latency) after 10 minutes
const LATENCY_SAMPLES: int = 3
const RANGE_REUPLOAD_DELAY_S: float = 1.0  # a range drag settles before the script is re-sent
const TEST_SECONDS: float = 1.5
const TEST_HALF_STROKE_MS: int = 350

var _connected: bool = false
var _device_type: String = ""
var _cluster: String = ""
var _one_way_ms: int = 0  # half the fastest round trip: how far ahead a start is aimed
var _last_check_ms: int = -100000000

# The round's script as {t, x} points, its stroke effects, and the flat position a "block" effect holds at.
var _points: Array = []
var _effects: Array = []
var _hold_pos: int = 50
var _uploaded_signature: String = ""  # what the device holds now, so an unchanged script isn't sent twice
var _upload_inflight: bool = false

var _playing: bool = false  # a sync script is started (not paused) on the device
var _video_ms_source: Callable = Callable()

var _override_active: bool = false
var _saved_points: Array = []
var _saved_effects: Array = []
var _saved_hold_pos: int = 50
var _saved_video_ms_source: Callable = Callable()

var _filler_active: bool = false
var _range_reupload_pending: bool = false


# Whether this build drives Autoblow devices at all.
func available() -> bool:
	return (
		OS.has_feature("editor") or bool(ProjectSettings.get_setting(EXPERIMENTAL_SETTING, false))
	)


func has_token() -> bool:
	return _token() != ""


func is_connected_ok() -> bool:
	return _connected


# "Autoblow Ultra" / "Vacuglide", or "" before a device has answered.
func device_name() -> String:
	return str(AutoblowScript.DEVICE_NAMES.get(_device_type, ""))


func _token() -> String:
	return SettingsService.get_autoblow_token().strip_edges()


# ── Connection ───────────────────────────────────────────────────────────────


# Finds the device: asks the discovery host which cluster it's on (trying each device type this build drives, since
# the token alone doesn't say), measures the round trip there, and applies the player's delay. Returns whether one
# answered as connected.
func connect_and_check() -> bool:
	if not available() or not has_token():
		_set_connected(false)
		return false
	var found: bool = false
	_uploaded_signature = ""  # the device may have been given another script since; send ours again
	for device_type: String in AutoblowScript.API_PREFIXES:
		var path: String = AutoblowScript.api_prefix(device_type) + "/connected"
		var res: Dictionary = await _request(DISCOVERY_HOST + path, HTTPClient.METHOD_GET)
		var data: Dictionary = res.get("data", {})
		if res.get("ok", false) and bool(data.get("connected", false)):
			_device_type = str(data.get("deviceType", device_type))
			if AutoblowScript.api_prefix(_device_type) == "":
				_device_type = device_type  # an unexpected name: trust the path that answered
			_cluster = str(data.get("cluster", ""))
			found = _cluster != ""
			break
	if found:
		await _measure_latency()
		await apply_delay()
		_last_check_ms = Time.get_ticks_msec()
		print("AutoblowService: %s on %s, ~%d ms one way" % [device_name(), _cluster, _one_way_ms])
	_set_connected(found)
	return found


# The per-round entry point: reuses the last check while it's fresh.
func ensure_ready() -> bool:
	if not available() or not has_token():
		_set_connected(false)
		return false
	if _connected and Time.get_ticks_msec() - _last_check_ms < RESYNC_AFTER_MS:
		return true
	return await connect_and_check()


func _set_connected(ok: bool) -> void:
	if ok == _connected:
		return
	_connected = ok
	connection_changed.emit(ok)


# Half the fastest of a few round trips to the device's cluster. The API has no server clock, so a start is aimed
# this far ahead of the video to land level with it.
func _measure_latency() -> void:
	var fastest: int = 1 << 30
	for _i: int in LATENCY_SAMPLES:
		var sent: int = Time.get_ticks_msec()
		var res: Dictionary = await _device_get("/connected")
		if res.get("ok", false):
			fastest = mini(fastest, Time.get_ticks_msec() - sent)
	_one_way_ms = fastest / 2 if fastest < (1 << 30) else 0


# Sends the player's Autoblow delay as the device's own sync offset. The setting's positive means "fire later"; the
# API's positive means the device runs AHEAD, hence the sign flip. The device keeps it until it restarts.
func apply_delay() -> void:
	if _cluster == "":
		return
	await _device_put(
		"/sync-script/offset", {"offsetTimeMs": -SettingsService.get_autoblow_delay_ms()}
	)


# ── The round's script ───────────────────────────────────────────────────────


# Loads the round's funscript actions (Vector2(at_ms, pos), as JourneyData.read_funscript_actions returns them).
func load_actions(actions: Array) -> void:
	_points = HandyPoints.actions_to_points(actions)
	_effects = []


# The active stroke effects, baked into the next upload. While an override plays they're kept for the round.
func set_effects(effects: Array, hold_pos: int = 50) -> void:
	if _override_active:
		_saved_effects = effects
		_saved_hold_pos = hold_pos
		return
	_effects = effects
	_hold_pos = hold_pos


func _script_bytes() -> PackedByteArray:
	return AutoblowScript.funscript_bytes(
		HandyPoints.apply_effects(_points, _effects, _hold_pos),
		SettingsService.get_range_min(),
		SettingsService.get_range_max()
	)


# Sends the current script to the device unless it already holds exactly this one. One upload at a time: a second
# caller waits for the first and then sends only if the script has changed again meanwhile.
func _upload() -> bool:
	while _upload_inflight:
		await get_tree().process_frame
	var bytes: PackedByteArray = _script_bytes()
	var signature: String = bytes.get_string_from_utf8().sha256_text()
	if signature == _uploaded_signature:
		return true
	_upload_inflight = true
	var boundary: String = "fhj%d" % Time.get_ticks_usec()
	var form: Dictionary = AutoblowScript.multipart_file("round.funscript", bytes, boundary)
	var res: Dictionary = await _request(
		_cluster_url("/sync-script/upload-funscript"),
		HTTPClient.METHOD_PUT,
		form["body"],
		str(form["content_type"]),
		UPLOAD_TIMEOUT_S
	)
	_upload_inflight = false
	if not res.get("ok", false):
		_uploaded_signature = ""
		return false
	_uploaded_signature = signature
	return true


# Uploads the round's script and starts it at the video's position. `video_ms_source` is read AFTER the upload, so
# the start lands where the video is then, not where it was when the upload began. False when the device can't be
# reached or refuses the script; the round then plays without it.
func start(video_ms_source: Callable) -> bool:
	if _points.is_empty() or not await ensure_ready():
		return false
	_filler_active = false
	_video_ms_source = video_ms_source
	if not await _upload():
		return false
	return await _start_at(int(video_ms_source.call()))


func _start_at(video_ms: int) -> bool:
	var res: Dictionary = await _device_put(
		"/sync-script/start", {"startTimeMs": maxi(0, video_ms + _one_way_ms)}
	)
	_playing = res.get("ok", false)
	return _playing


func pause() -> void:
	if _playing:
		_playing = false
		await _device_put("/sync-script/stop", {})


# Starts the script again at `video_ms` (resume, seek): re-anchors to the video, so no drift carries over.
func seek(video_ms: int) -> void:
	if _uploaded_signature == "" or _override_active:
		return
	await _start_at(video_ms)


func stop() -> void:
	_override_active = false
	_saved_points = []
	_saved_effects = []
	_range_reupload_pending = false
	if _playing:
		_playing = false
		await _device_put("/sync-script/stop", {})


# The script changed mid-round (an effect, the stroke range): send the new one and pick up at the live position.
# The old script keeps playing until the new one lands.
func reload() -> void:
	if not _playing or not _video_ms_source.is_valid():
		return
	if await _upload() and _playing:
		await _start_at(int(_video_ms_source.call()))


# The stroke range moved. Range is baked into the script, so it takes a re-upload: once the drag settles.
func range_changed() -> void:
	if not _playing or _range_reupload_pending:
		return
	_range_reupload_pending = true
	await get_tree().create_timer(RANGE_REUPLOAD_DELAY_S).timeout
	if not _range_reupload_pending:
		return  # stopped meanwhile
	_range_reupload_pending = false
	await reload()


# ── Overrides ────────────────────────────────────────────────────────────────


func is_override_active() -> bool:
	return _override_active


# An override item takes the device: its script plays on its own clock (`override_ms_source`). The round's script
# is kept to put back. A second override replaces the first and keeps the round's.
func start_override(main_actions: Array, immune: bool, override_ms_source: Callable) -> bool:
	if not _playing and not _override_active:
		return false
	if not _override_active:
		_saved_points = _points
		_saved_effects = _effects
		_saved_hold_pos = _hold_pos
		_saved_video_ms_source = _video_ms_source
	_override_active = true
	_points = HandyPoints.actions_to_points(main_actions)
	_effects = [] if immune else _saved_effects.duplicate()
	_video_ms_source = override_ms_source
	if not await _upload():
		return false
	return await _start_at(int(override_ms_source.call()))


# The override finished: the round's script goes back on and picks up where the video is now.
func stop_override(resume_video_ms: int) -> void:
	if not _override_active:
		return
	_override_active = false
	_points = _saved_points
	_effects = _saved_effects
	_hold_pos = _saved_hold_pos
	_video_ms_source = _saved_video_ms_source
	_saved_points = []
	_saved_effects = []
	if await _upload():
		await _start_at(resume_video_ms)


# ── Filler (storyboards, shops) ──────────────────────────────────────────────
# A plain rhythm needs no script: the Ultra's oscillator takes a speed and a stroke span, the Vacuglide a target
# speed. Both switch at once, which suits filler that changes with the screen.


func is_filler_active() -> bool:
	return _filler_active


func start_filler(bottom: int, top: int, half_cycle_ms: int) -> void:
	if not _connected or _playing:
		return
	_filler_active = true
	var speed: int = AutoblowScript.filler_speed(half_cycle_ms)
	if _device_type == AutoblowScript.DEVICE_ULTRA:
		var span: Vector2i = AutoblowScript.oscillate_span(bottom, top)
		await _device_put("/oscillate", {"speed": speed, "minY": span.x, "maxY": span.y})
	else:
		await _device_put("/target-speed", {"targetSpeed": speed})


# Walking strokes have no rhythm of their own on these devices: they run at the walk's middle speed.
func start_filler_walk(fastest_ms: int, slowest_ms: int, _slowdown_ms: int) -> void:
	await start_filler(0, 100, (fastest_ms + slowest_ms) / 2)


func stop_filler() -> void:
	if not _filler_active:
		return
	_filler_active = false
	await _stop_live_speed()


func _stop_live_speed() -> void:
	if _device_type == AutoblowScript.DEVICE_ULTRA:
		await _device_put("/oscillate/stop", {})
	else:
		await _device_put("/target-speed/stop", {})


# A short burst so the player can feel the connection is live. Skipped while a round plays.
func test_stroke() -> bool:
	if not _connected or _playing:
		return false
	var span: Vector2i = AutoblowScript.oscillate_span(5, 95)
	var speed: int = AutoblowScript.filler_speed(TEST_HALF_STROKE_MS)
	var res: Dictionary = {}
	if _device_type == AutoblowScript.DEVICE_ULTRA:
		res = await _device_put("/oscillate", {"speed": speed, "minY": span.x, "maxY": span.y})
	else:
		res = await _device_put("/target-speed", {"targetSpeed": speed})
	await get_tree().create_timer(TEST_SECONDS).timeout
	await _stop_live_speed()
	return res.get("ok", false)


# ── HTTP ─────────────────────────────────────────────────────────────────────


func _cluster_url(path: String) -> String:
	return (CLUSTER_HOST % _cluster) + AutoblowScript.api_prefix(_device_type) + path


func _device_get(path: String) -> Dictionary:
	return await _request(_cluster_url(path), HTTPClient.METHOD_GET)


func _device_put(path: String, payload: Dictionary) -> Dictionary:
	# A bodyless command goes without a body or Content-Type, as the API asks.
	if payload.is_empty():
		return await _request(_cluster_url(path), HTTPClient.METHOD_PUT)
	return await _request(
		_cluster_url(path),
		HTTPClient.METHOD_PUT,
		JSON.stringify(payload).to_utf8_buffer(),
		"application/json"
	)


# One request. Returns {ok, status, data}, data being the parsed JSON object ({} if none). A 429 waits as long as
# the rate-limit headers ask, then tries once more.
func _request(
	url: String,
	method: HTTPClient.Method,
	body: PackedByteArray = PackedByteArray(),
	content_type: String = "",
	timeout_s: float = REQUEST_TIMEOUT_S
) -> Dictionary:
	var res: Dictionary = await _send(url, method, body, content_type, timeout_s)
	if int(res["status"]) == 429:
		var wait_ms: int = AutoblowScript.rate_limit_wait_ms(
			res["headers"], Time.get_unix_time_from_system()
		)
		print("AutoblowService: rate limited, waiting %d ms" % wait_ms)
		await get_tree().create_timer(wait_ms / 1000.0).timeout
		res = await _send(url, method, body, content_type, timeout_s)
	return res


func _send(
	url: String,
	method: HTTPClient.Method,
	body: PackedByteArray,
	content_type: String,
	timeout_s: float
) -> Dictionary:
	var headers: PackedStringArray = PackedStringArray(["x-device-token: " + _token()])
	if content_type != "":
		headers.append("Content-Type: " + content_type)
	var req: HTTPRequest = HTTPRequest.new()
	req.timeout = timeout_s
	add_child(req)
	var sent: int = Time.get_ticks_msec()
	var failed: Dictionary = {"ok": false, "status": 0, "data": {}, "headers": PackedStringArray()}
	if req.request_raw(url, headers, method, body) != OK:
		req.queue_free()
		return failed
	var result: Array = await req.request_completed  # [result, status, headers, body]
	req.queue_free()
	var status: int = int(result[1])
	var response_headers: PackedStringArray = result[2]
	_log(url, method, status, Time.get_ticks_msec() - sent, response_headers)
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return failed
	var data: Variant = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	return {
		"ok": status >= 200 and status < 300,
		"status": status,
		"data": data if data is Dictionary else {},
		"headers": response_headers,
	}


# One line per request: which path (never the token), its status and time, and the rate-limit headroom left.
func _log(
	url: String, method: HTTPClient.Method, status: int, elapsed_ms: int, headers: PackedStringArray
) -> void:
	var path: String = url.substr(url.find(".com") + 4)
	var verb: String = "GET" if method == HTTPClient.METHOD_GET else "PUT"
	var remaining: String = AutoblowScript.header_value(headers, "x-ratelimit-remaining")
	print(
		(
			"AutoblowService: %s %s -> %d in %d ms%s"
			% [verb, path, status, elapsed_ms, (", %s left" % remaining) if remaining != "" else ""]
		)
	)
