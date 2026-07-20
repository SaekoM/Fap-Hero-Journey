extends Node

# ---------------------------------------------------------------------------
# HandyService  (autoload)
#
# Direct WiFi support for The Handy via the official API **v3 / HSP** (Handy
# Streaming Protocol) — no Intiface required.
#
# Unlike the old v2 HSSP "upload the whole script to a public URL and play it",
# HSP STREAMS the script into a small rolling on-device buffer, ≤100 points per
# add. We are the producer: convert the round's funscript to points, feed them
# a few seconds ahead of the video clock, and top the buffer up as the device
# consumes it. `pause_on_starving` means a late refill just pauses the device
# instead of drifting. Native pause/resume/stop; drift handled by re-`play`
# on seek. No third-party file hosting — points transit Handy's relay per batch.
#
# CONSEQUENCES (disclosed in Options):
#   • Motion commands route through Handy's cloud (needs internet). No script
#     FILE is uploaded/hosted anymore — a softer story than v2.
#   • Stroke-modifying items / curses / boss modifiers DO reach the device: we
#     feed the TRANSFORMED script (set_effects bakes them in; a mid-round change
#     flush-refeeds via seek, landing a fraction of a second later).
#   • Stroke RANGE does apply — mapped to the device slider stroke zone.
#
# AUTH (v3, two credentials): the app's registered APPLICATION ID goes in
# X-Api-Key (verified: the ID authenticates device calls directly; the separate
# "application key" only mints bearer tokens via /auth/token/issue, which we
# don't use). Plus the user's CONNECTION key in X-Connection-Key. Both headers
# on every device call. Set the ID via [handy] app_id or DEFAULT_APP_ID.
# ---------------------------------------------------------------------------

signal connection_changed(connected: bool)

const API_V3: String = "https://www.handyfeeling.com/api/handy-rest/v3"
# The app's registered application ID (the X-Api-Key value). SAFE to ship in
# source — per Handy's docs the Application ID is the non-privileged credential
# meant to be embedded in client code (extractable, but grants only
# non-privileged endpoints and still needs a user's connection key to touch a
# device). The privileged application *key* is the one that must NEVER ship —
# it's server-side only and we don't use it. Override via [handy] app_id.
const DEFAULT_APP_ID: String = "YGD4P0FfNHPeqgAskoT-4aRfK~zdEWhm"

const LOOKAHEAD_MS: int = 8000  # keep the buffer filled this far ahead of the clock
const FEED_INTERVAL_MS: int = 1000  # min gap between refill calls (GameLoop drives feed)
const SERVERTIME_SAMPLES: int = 5  # /servertime probes for the client-clock estimate
const REQUEST_TIMEOUT_S: float = 10.0

var _connected: bool = false
var _clock_offset_ms: int = 0  # device/server clock offset from /hstp/clocksync
# CLIENT→server clock offset (server_now ≈ local_ticks + this), from /servertime.
# Distinct from _clock_offset_ms (device↔server): this is OUR estimate of server
# time, sent as /hsp/play's server_time so the device can compensate transit lag.
var _server_offset_ms: int = 0
var _server_synced: bool = false
# Current round's RAW script as HSP points [{t:int ms, x:int 0-100}], time-sorted.
var _points: Array = []
# The script with active stroke effects (items / curses / boss) baked in — this
# is what actually streams. Equals _points when no stroke effects are active.
var _transformed: Array = []
var _effects: Array = []  # active stroke effects (InventoryService.GetActiveEffects shape)
var _hold_pos: int = 50  # device neutral, used as the flat line under a "block" effect
var _send_idx: int = 0  # index of the next point to stream (also the tail stream index)
var _playing: bool = false
var _last_feed_ms: int = -100000
var _last_video_ms: int = 0  # most recent video clock (for a delay-change resync)
var _feed_inflight: bool = false


func is_connected_ok() -> bool:
	return _connected


func has_key() -> bool:
	return _connection_key() != "" and _app_id() != ""


func _connection_key() -> String:
	return SettingsService.get_handy_connection_key().strip_edges()


func _app_id() -> String:
	var s: String = SettingsService.get_handy_app_id().strip_edges()
	return s if s != "" else DEFAULT_APP_ID


# ── Connection ───────────────────────────────────────────────────────────────


# Verifies the device is reachable and syncs the server/device clock. Emits
# connection_changed on state flips. Returns false (with a distinct log) when
# the app key is missing — that's a build/config error, not a user one.
func connect_and_sync() -> bool:
	if _app_id() == "":
		printerr("HandyService: no application ID set (DEFAULT_APP_ID / [handy] app_id).")
		_set_connected(false)
		return false
	if _connection_key() == "":
		_set_connected(false)
		return false
	var res: Dictionary = await _api_get("/connected")
	var ok: bool = bool((res.get("result", res) as Dictionary).get("connected", false))
	if ok:
		await _clocksync()  # syncs the DEVICE clock to the server
		await _estimate_server_offset()  # syncs OUR clock to the server (for server_time)
	_set_connected(ok)
	return ok


func _set_connected(ok: bool) -> void:
	if ok == _connected:
		return
	_connected = ok
	connection_changed.emit(ok)


# /hstp/clocksync (GET) returns the device/server clock offset directly (v3
# replaces the manual /servertime sampling the v2 client did). s=true makes the
# sync synchronous so the result comes back in this response.
func _clocksync() -> void:
	var res: Dictionary = await _api_get("/hstp/clocksync?s=true")
	var r: Dictionary = res.get("result", res)
	if r.has("clock_offset"):
		_clock_offset_ms = int(r["clock_offset"])


# Samples /servertime a few times to estimate the CLIENT→server clock offset
# (lowest-RTT sample wins; pure math in HandyPoints.best_offset_from_samples).
# Feeds _server_now(), which fills /hsp/play's server_time so the device can
# compensate transit latency instead of treating "command received" as t=now
# (the cause of a consistent ~0.5–1s lag when server_time is omitted).
func _estimate_server_offset() -> void:
	var samples: Array = []
	for _i: int in SERVERTIME_SAMPLES:
		var sent: int = Time.get_ticks_msec()
		var res: Dictionary = await _api_get("/servertime")
		var recv: int = Time.get_ticks_msec()
		var r: Dictionary = res.get("result", res)
		if r.has("server_time"):
			samples.append({"sent": sent, "recv": recv, "server_time": int(r["server_time"])})
	if not samples.is_empty():
		_server_offset_ms = HandyPoints.best_offset_from_samples(samples)
		_server_synced = true


# Our current estimate of the server clock (ms), for /hsp/play's server_time.
func _server_now() -> int:
	return Time.get_ticks_msec() + _server_offset_ms


# ── Script → HSP points ──────────────────────────────────────────────────────


# Loads the round's funscript actions (Vector2(at_ms, pos), time-sorted — what
# JourneyData.read_funscript_actions returns) as the point stream for the next
# HSP session. Resets the feed cursor + effects. Pure conversion in HandyPoints.
func load_actions(actions: Array) -> void:
	_points = HandyPoints.actions_to_points(actions)
	_effects = []
	_rebuild_transformed()
	_send_idx = 0


# Sets the active stroke effects and rebuilds the streamed (transformed) script
# so items / curses / boss modifiers reach the device. `hold_pos` is the device
# neutral used as the flat line under a "block" effect. Does NOT touch the
# device — the caller flush-refeeds (seek) so the change lands from the current
# position. Non-stroke kinds are ignored by the transform.
func set_effects(effects: Array, hold_pos: int = 50) -> void:
	_effects = effects
	_hold_pos = hold_pos
	_rebuild_transformed()


# Rebuilds the streamed script: stroke effects baked in, then the Handy delay as a timestamp
# shift. Either input can change mid-round (an item fires; the delay slider moves); the caller
# flush-refeeds via seek() so the device picks it up from the current position.
func _rebuild_transformed() -> void:
	_transformed = HandyPoints.offset_points(
		HandyPoints.apply_effects(_points, _effects, _hold_pos),
		SettingsService.get_handy_delay_ms()
	)


# ── HSP playback ─────────────────────────────────────────────────────────────


# Opens a fresh HSP session and starts playback at `video_ms`, seeding the
# buffer with the first batch (embedded in /hsp/play). Returns false on setup
# failure; the caller drops to a toast and plays without the device.
func start(video_ms: int) -> bool:
	if _points.is_empty():
		return false
	var setup: Dictionary = await _api_put("/hsp/setup", {})
	if setup.is_empty():
		return false
	_send_idx = 0
	_playing = true
	_last_feed_ms = -100000
	_last_video_ms = video_ms
	var win: Dictionary = HandyPoints.points_in_window(_transformed, 0, video_ms + LOOKAHEAD_MS)
	_send_idx = int(win["next_idx"])
	var play: Dictionary = {
		"start_time": _anchor(video_ms),
		"playback_rate": 1.0,
		"pause_on_starving": true,
		"loop": false,
		"add":
		{
			"points": win["batch"],
			"flush": true,
			"tail_point_stream_index": maxi(1, _send_idx),
		},
	}
	# Anchor the play to the server clock so the device compensates transit lag.
	# Only when synced — a bad estimate would desync worse than omitting it.
	if _server_synced:
		play["server_time"] = _server_now()
	await _api_put("/hsp/play", play)
	return true


# Tops the buffer up to LOOKAHEAD_MS ahead of `video_ms`. Called every frame by
# GameLoop; self-throttles to FEED_INTERVAL_MS and never overlaps a request.
# Fire-and-forget (no await at the call site).
func feed(video_ms: int) -> void:
	_last_video_ms = video_ms
	if not _playing or _feed_inflight or _send_idx >= _transformed.size():
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_feed_ms < FEED_INTERVAL_MS:
		return
	var win: Dictionary = HandyPoints.points_in_window(
		_transformed, _send_idx, video_ms + LOOKAHEAD_MS
	)
	if (win["batch"] as Array).is_empty():
		return
	_last_feed_ms = now
	_send_idx = int(win["next_idx"])
	_feed_inflight = true
	await _api_put(
		"/hsp/add", {"points": win["batch"], "flush": false, "tail_point_stream_index": _send_idx}
	)
	_feed_inflight = false


func pause() -> void:
	if _playing:
		await _api_put("/hsp/pause", {})


func resume() -> void:
	if _playing:
		await _api_put("/hsp/resume", {})


func stop() -> void:
	if _playing:
		_playing = false
		await _api_put("/hsp/stop", {})


# Play/seek anchor: the device's script clock sits level with the video clock. The Handy delay
# is NOT applied here — it lives in the streamed timestamps (HandyPoints.offset_points).
#
# 0.6.0 applied it here as `maxi(0, video_ms - delay)`. start_time can't go negative, so at a
# round start (video_ms only as large as the connect handshake took) the clamp ate the delay —
# by an amount that varied with network latency, which is why it worked for some users only.
func _anchor(video_ms: int) -> int:
	return maxi(0, video_ms)


# Re-seats playback at a new position: flush the buffer and replay from
# `video_ms` (used on unpause/seek so the device lands where the video is).
func seek(video_ms: int) -> void:
	if not _playing:
		return
	_last_video_ms = video_ms
	var win: Dictionary = HandyPoints.points_in_window(_transformed, 0, video_ms + LOOKAHEAD_MS)
	# Rewind the cursor to just past this window (points before video_ms are
	# skipped by start_time; the batch covers the lookahead).
	_send_idx = int(win["next_idx"])
	_last_feed_ms = Time.get_ticks_msec()
	var play: Dictionary = {
		"start_time": _anchor(video_ms),
		"pause_on_starving": true,
		"add":
		{
			"points": win["batch"],
			"flush": true,
			"tail_point_stream_index": maxi(1, _send_idx),
		},
	}
	if _server_synced:
		play["server_time"] = _server_now()
	await _api_put("/hsp/play", play)


# Re-times the stream for a live delay change (Quick Settings) and re-seats
# playback at the current video position so it takes effect immediately. The
# rebuild is what actually moves the points; the seek flushes the device's buffer
# of the old timings. No-op unless a session is live.
func resync_timing() -> void:
	if _playing:
		_rebuild_transformed()
		await seek(_last_video_ms)


# Maps the stroke range (0–100) onto the device slider stroke zone (v3 uses
# relative [0,1] floats).
func set_slider(range_min: int, range_max: int) -> void:
	await _api_put(
		"/slider/stroke",
		{
			"min": clampf(range_min / 100.0, 0.0, 1.0),
			"max": clampf(range_max / 100.0, 0.0, 1.0),
		}
	)


# Debounced slider for live drags — one call per ~300ms, latest value wins.
var _slider_pending: Vector2i = Vector2i(-1, -1)
var _slider_inflight: bool = false


func set_slider_debounced(range_min: int, range_max: int) -> void:
	_slider_pending = Vector2i(range_min, range_max)
	if _slider_inflight:
		return
	_slider_inflight = true
	await get_tree().create_timer(0.3).timeout
	_slider_inflight = false
	await set_slider(_slider_pending.x, _slider_pending.y)


# ── HTTP plumbing ────────────────────────────────────────────────────────────


func _headers() -> PackedStringArray:
	return PackedStringArray(
		[
			"X-Api-Key: " + _app_id(),
			"X-Connection-Key: " + _connection_key(),
			"Content-Type: application/json",
		]
	)


func _api_get(endpoint: String) -> Dictionary:
	return await _request(endpoint, HTTPClient.METHOD_GET, PackedByteArray())


func _api_put(endpoint: String, payload: Dictionary) -> Dictionary:
	return await _request(endpoint, HTTPClient.METHOD_PUT, JSON.stringify(payload).to_utf8_buffer())


# One request on a transient HTTPRequest node. Returns the parsed JSON object,
# or {} on transport/HTTP/parse failure (the API always answers with an object).
func _request(endpoint: String, method: HTTPClient.Method, body: PackedByteArray) -> Dictionary:
	var req: HTTPRequest = HTTPRequest.new()
	req.timeout = REQUEST_TIMEOUT_S
	add_child(req)
	var err: Error = req.request_raw(API_V3 + endpoint, _headers(), method, body)
	if err != OK:
		req.queue_free()
		return {}
	var result: Array = await req.request_completed
	req.queue_free()
	# result: [result_code, response_code, headers, body]
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) >= 400:
		return {}
	var parser: JSON = JSON.new()
	if parser.parse((result[3] as PackedByteArray).get_string_from_utf8()) != OK:
		return {}
	return parser.data if parser.data is Dictionary else {}
