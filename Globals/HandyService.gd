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
# Re-run the (slow) clock sync only when the cached one is older than this. The clocks are
# session-stable, so ensure_ready() reuses the cache round-to-round — killing the per-round
# ~9-call handshake that delayed the device by several seconds at every round start.
const RESYNC_AFTER_MS: int = 600000  # 10 min
const RECOVER_AFTER_FAILURES: int = 2  # consecutive stream-call failures before a full re-establish

var _connected: bool = false
var _clock_offset_ms: int = 0  # device/server clock offset from /hstp/clocksync
# CLIENT→server clock offset (server_now ≈ local_ticks + this), from /servertime.
# Distinct from _clock_offset_ms (device↔server): this is OUR estimate of server
# time, sent as /hsp/play's server_time so the device can compensate transit lag.
var _server_offset_ms: int = 0
var _server_synced: bool = false
var _last_sync_ms: int = -100000000  # when the clock sync last succeeded (for ensure_ready's cache)
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
# Deferred play: when a round opens with a long no-action intro, the first stroke can be beyond LOOKAHEAD,
# so the opening /hsp/play window is empty. Sending it anyway starves the device (pause_on_starving) and it
# recovers ~LOOKAHEAD behind. Instead we DEFER the play — feed() fires the anchored /hsp/play once the first
# stroke comes within reach. `_video_ms_source` is start()'s live position Callable, reused by that engage.
var _deferred_play: bool = false
var _video_ms_source: Callable = Callable()
# Prewarm: a fresh /hsp/setup done ahead of the round so start() only needs /hsp/play. `_session_ready`
# means one exists and hasn't been consumed yet; `_setup_inflight` means a prewarm's setup is in progress.
var _session_ready: bool = false
var _setup_inflight: bool = false
# Resilience: a run of failed stream calls triggers a full re-establish from the current position.
var _consecutive_failures: int = 0
var _recovering: bool = false


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
		_last_sync_ms = Time.get_ticks_msec()
	_set_connected(ok)
	return ok


# The per-round entry point: reuse the cached session sync when it's fresh, so a round start costs only
# /hsp/setup + /hsp/play instead of re-running the whole ~9-call connect handshake (the several-second
# per-round startup lag). Falls back to a full connect_and_sync when never synced, stale (>RESYNC_AFTER_MS),
# or disconnected. A stale device that dropped since the last sync just fails at start() → deviceless, which
# is the same graceful path as before.
func ensure_ready() -> bool:
	if _app_id() == "" or _connection_key() == "":
		_set_connected(false)
		return false
	if _connected and _server_synced and Time.get_ticks_msec() - _last_sync_ms < RESYNC_AFTER_MS:
		return true
	return await connect_and_sync()


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


# Opens the HSP session AHEAD of the round (fire-and-forget from GameLoop when a round loads) so start()
# only has to fire the anchored /hsp/play — the setup round-trip overlaps the intro card / video load
# instead of adding to the round-start delay. /hsp/setup takes no script, so it's safe this early. No-op when
# a session is already ready or a prewarm is inflight; silently does nothing if the device isn't reachable.
func prewarm() -> void:
	if _session_ready or _setup_inflight:
		return
	if not await ensure_ready():
		return
	if _session_ready or _setup_inflight:  # state may have changed across the await
		return
	_setup_inflight = true
	var setup: Dictionary = await _api_put("/hsp/setup", {})
	_setup_inflight = false
	_session_ready = not setup.is_empty()


# Opens a fresh HSP session and starts playback at the CURRENT video position, seeding the buffer with the
# first batch (embedded in /hsp/play). Returns false on setup failure; the caller drops to a toast and plays
# without the device.
#
# `video_ms_source` is a Callable returning the live video position (ms). It's read AFTER /hsp/setup so the
# anchor (start_time) and server_time are captured in the SAME instant — otherwise the ~1 setup-RTT between
# them leaves the device anchored that far behind the video for the whole round (the "plays ~1s late" lag).
func start(video_ms_source: Callable) -> bool:
	if _points.is_empty():
		return false
	# Reuse a prewarmed session when one's ready; wait out an inflight prewarm; otherwise set up now. Either
	# way the session is consumed here (the next round prewarms a fresh one).
	if not _session_ready:
		var guard: int = 0
		while _setup_inflight and not _session_ready and guard < 600:
			await get_tree().process_frame
			guard += 1
	if _session_ready:
		_session_ready = false
	else:
		var setup: Dictionary = await _api_put("/hsp/setup", {})
		if setup.is_empty():
			return false
	_playing = true
	_last_feed_ms = -100000
	_video_ms_source = video_ms_source  # kept for the deferred engage in feed()
	var video_ms: int = int(video_ms_source.call())  # live, paired with _server_now() in _send_play
	_last_video_ms = video_ms
	# If the first stroke is beyond the lookahead (a long no-action intro), DON'T play into an empty window —
	# that starves the device. Defer; feed() fires the anchored play once a stroke comes into reach.
	if (
		HandyPoints
		. points_in_window(
			_transformed,
			HandyPoints.index_at_or_after(_transformed, video_ms),
			video_ms + LOOKAHEAD_MS
		)["batch"]
		. is_empty()
	):
		_deferred_play = true
		return true  # session is set up; the real /hsp/play waits for strokes
	_deferred_play = false
	if (await _send_play(video_ms)).is_empty():
		return false
	_note_stream_ok()  # clear the failure counter on a clean (re)start
	return true


# Builds the point window from `video_ms` and sends one anchored /hsp/play (flush + server_time). Assumes an
# HSP session already exists (setup done). Shared by start(), seek(), and the deferred engage. Window starts
# at the CURRENT position (not index 0) so the device isn't handed the opening seconds while it plays here.
func _send_play(video_ms: int) -> Dictionary:
	_last_video_ms = video_ms
	_last_feed_ms = Time.get_ticks_msec()
	var from_idx: int = HandyPoints.index_at_or_after(_transformed, video_ms)
	var win: Dictionary = HandyPoints.points_in_window(
		_transformed, from_idx, video_ms + LOOKAHEAD_MS
	)
	_send_idx = int(win["next_idx"])
	var play: Dictionary = {
		"start_time": _anchor(video_ms),
		"playback_rate": 1.0,
		"pause_on_starving": true,
		"loop": false,
		"add":
		{"points": win["batch"], "flush": true, "tail_point_stream_index": maxi(1, _send_idx)},
	}
	# Anchor to the server clock so the device compensates transit lag (only when synced — a bad estimate
	# would desync worse than omitting it).
	if _server_synced:
		play["server_time"] = _server_now()
	return await _api_put("/hsp/play", play)


# Tops the buffer up to LOOKAHEAD_MS ahead of `video_ms`. Called every frame by
# GameLoop; self-throttles to FEED_INTERVAL_MS and never overlaps a request.
# Fire-and-forget (no await at the call site).
func feed(video_ms: int) -> void:
	_last_video_ms = video_ms  # kept fresh even when we don't send, so recovery anchors to the live clock
	# Deferred engage: the round opened with the first stroke beyond lookahead (long intro). Once a stroke
	# comes within reach, fire the real anchored play now — a FRESH /hsp/setup first (the earlier one may
	# have gone stale idling through the intro), then the anchored play read at the live position. This is
	# the automatic version of the user's "pause when the strokes start → it syncs".
	if _deferred_play:
		if not _playing or _recovering or _feed_inflight:
			return
		if (
			HandyPoints
			. points_in_window(
				_transformed,
				HandyPoints.index_at_or_after(_transformed, video_ms),
				video_ms + LOOKAHEAD_MS
			)["batch"]
			. is_empty()
		):
			return  # still nothing to stroke within reach
		_deferred_play = false
		_feed_inflight = true
		var setup: Dictionary = await _api_put("/hsp/setup", {})
		if not setup.is_empty():
			var eng_ms: int = (
				int(_video_ms_source.call()) if _video_ms_source.is_valid() else video_ms
			)
			if not (await _send_play(eng_ms)).is_empty():
				_note_stream_ok()
		_feed_inflight = false
		return
	if not _playing or _recovering or _feed_inflight or _send_idx >= _transformed.size():
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
	var next_idx: int = int(win["next_idx"])  # NOT committed until the add succeeds — a dropped packet
	_feed_inflight = true  # would otherwise skip these points forever, starving the device
	var res: Dictionary = await _api_put(
		"/hsp/add", {"points": win["batch"], "flush": false, "tail_point_stream_index": next_idx}
	)
	_feed_inflight = false
	if res.is_empty():
		_note_stream_failure()  # keep _send_idx; the same batch retries next feed
	else:
		_send_idx = next_idx
		_note_stream_ok()


# ── Resilience / recovery ─────────────────────────────────────────────────────


func _note_stream_ok() -> void:
	_consecutive_failures = 0


func _note_stream_failure() -> void:
	_consecutive_failures += 1
	if _consecutive_failures >= RECOVER_AFTER_FAILURES:
		_recover()  # fire-and-forget


# A run of stream failures escalated (WiFi blip / device sleep): re-establish the session and re-seat
# playback at the CURRENT video position, so it self-heals in ~a second instead of going silent until the
# next seek. feed() no-ops while this runs (the _recovering guard) so it can't fight the re-establish.
func _recover() -> void:
	if _recovering or not _playing:
		return
	_recovering = true
	if await ensure_ready():
		_session_ready = false  # force a fresh /hsp/setup inside start()
		await start(func() -> int: return _last_video_ms)  # reads the live clock after setup
	_consecutive_failures = 0
	_recovering = false


func pause() -> void:
	if _playing:
		await _api_put("/hsp/pause", {})


# (No resume() — GameLoop resumes by seek()ing to the video position, which re-anchors the device
# to the clock instead of continuing from where the bare /hsp/resume left it drifted.)


func stop() -> void:
	_session_ready = false  # the session is gone — the next round prewarms a fresh one
	_deferred_play = false  # drop any pending deferred engage
	_consecutive_failures = 0
	_recovering = false
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


# Re-seats playback at a new position: flush the buffer and replay from `video_ms` (used on unpause/seek so
# the device lands where the video is). If there's no stroke within reach (still a no-action stretch), it
# defers like start() instead of sending an empty window that would starve the device.
func seek(video_ms: int) -> void:
	if not _playing:
		return
	if (
		HandyPoints
		. points_in_window(
			_transformed,
			HandyPoints.index_at_or_after(_transformed, video_ms),
			video_ms + LOOKAHEAD_MS
		)["batch"]
		. is_empty()
	):
		_deferred_play = true
		_last_video_ms = video_ms
		return
	_deferred_play = false
	await _send_play(video_ms)


# Re-times the stream for a live delay change (Quick Settings) and re-seats
# playback at the current video position so it takes effect immediately. The
# rebuild is what actually moves the points; the seek flushes the device's buffer
# of the old timings. No-op unless a session is live.
func resync_timing() -> void:
	if _playing:
		_rebuild_transformed()
		await seek(_last_video_ms)


# Fires a short, self-contained stroke so the user can physically confirm the WiFi connection is live
# (there's no other feedback that a cloud "connected" actually reaches the device). Two full strokes over
# ~1.6s via the proven /hsp/setup + /hsp/play path — no clock sync needed (immediate, start_time 0). Skipped
# mid-round so it can't disrupt a live session. Returns false if not connected or setup fails.
func test_stroke() -> bool:
	if not _connected or _playing:
		return false
	var setup: Dictionary = await _api_put("/hsp/setup", {})
	if setup.is_empty():
		return false
	var pts: Array = [
		{"t": 0, "x": 50},
		{"t": 350, "x": 5},
		{"t": 700, "x": 95},
		{"t": 1050, "x": 5},
		{"t": 1400, "x": 95},
		{"t": 1600, "x": 50},
	]
	var res: Dictionary = await _api_put(
		"/hsp/play",
		{
			"start_time": 0,
			"playback_rate": 1.0,
			"pause_on_starving": true,
			"loop": false,
			"add": {"points": pts, "flush": true, "tail_point_stream_index": pts.size()},
		}
	)
	return not res.is_empty()


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
