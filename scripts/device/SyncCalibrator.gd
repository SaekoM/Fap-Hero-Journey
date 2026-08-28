class_name SyncCalibrator
extends Node

# Plays the calibration pattern on whichever device actually drives strokes, on its own elapsed clock —
# no journey, no video, no round.
#
# It deliberately uses THE SAME two paths a round uses, because a number dialled in through some other
# code path would not transfer to play:
#   • Handy WiFi (HSP): load_actions → start(clock) → feed(clock) → stop(), the normal streaming entry,
#     so the clock sync and the delay behave exactly as they do mid-round.
#   • Everything else (serial / Buttplug / restim, via the C# FunscriptPlayer): BeginOverride, which
#     free-runs on its own clock with no round loaded. OverrideTestPlayer drives the builder's test-play
#     the same way.
#
# Only the live stroke backend is driven. Running both would buzz routed vibrators through a path the
# user isn't calibrating, and a Handy session and a FunscriptPlayer override moving at once is two
# devices to compare against one picture.
#
# Freeing this node stops the device — the screen holding it can close by any route without leaving a
# stroker running.

signal finished  # the pattern reached its end on its own

var _actions: Array = []  # Array[Vector2] — what the device paths are fed
var _points: Array = []  # the same pattern in HandyPoints shape, for the meter
var _start_ticks: int = 0
var _duration_ms: int = 0
var _running: bool = false
var _handy: bool = false  # a Handy session is live and needs feeding + stopping
var _override: bool = false  # a FunscriptPlayer override is live and needs stopping


func _ready() -> void:
	set_process(false)  # only the running pattern needs a frame; start() turns this on


# Elapsed pattern time in ms. Read from the wall clock rather than summed per-frame deltas: truncating
# the sub-millisecond remainder every frame runs the clock a few percent slow, which on a sync tool
# would be indistinguishable from the very lag being measured.
func now_ms() -> int:
	return Time.get_ticks_msec() - _start_ticks


func is_running() -> bool:
	return _running


# The pattern in the shape StrokeMeter draws — empty unless it is actually running, so the meter can be
# pointed at this once and left alone: it shows the pattern while it plays and nothing when it doesn't.
func points() -> Array:
	return _points


# Starts the pattern and hands it to the live stroke backend. Returns false when no device could be
# driven — the clock still runs and the meter still animates, so the screen can show the picture and say
# there is nothing on the other end of it.
func start() -> bool:
	stop()
	_actions = StrokePattern.calibration()
	_points = HandyPoints.actions_to_points(_actions)
	_duration_ms = int((_actions[_actions.size() - 1] as Vector2).x)
	_start_ticks = Time.get_ticks_msec()
	_running = true
	set_process(true)

	var backend: String = DeviceRouting.stroke_backend(SettingsService.get_stroke_target())
	if backend == DeviceRouting.HANDY_TARGET:
		return await _start_handy()
	if backend == "":
		return false
	# Immune: the pattern is a ruler, and an item scaling it would change what is being measured.
	FunscriptPlayer.BeginOverride(_actions, {}, {}, true)
	_override = true
	return true


func _start_handy() -> bool:
	if not HandyService.has_key() or not await HandyService.ensure_ready():
		return false
	if not _running:
		return false  # stopped while the connection handshake was in flight
	HandyService.load_actions(_actions)
	HandyService.set_effects([])
	_handy = await HandyService.start(now_ms)
	if not _handy:
		return false
	if not _running:
		HandyService.stop()
		return false
	await HandyService.set_slider(SettingsService.get_range_min(), SettingsService.get_range_max())
	return true


func stop() -> void:
	if not _running:
		return
	_running = false
	_points = []
	set_process(false)
	if _override:
		FunscriptPlayer.Stop()
		_override = false
	if _handy:
		HandyService.stop()
		_handy = false


func _process(_delta: float) -> void:
	if not _running:
		return
	var ms: int = now_ms()
	if _handy:
		HandyService.feed(ms)
	if ms >= _duration_ms:
		stop()
		finished.emit()


func _exit_tree() -> void:
	stop()
