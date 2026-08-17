class_name OverrideTestPlayer
extends Node

# Plays an override bundle on the connected device straight from the builder, so an author can FEEL a slice
# while trimming it — no round required. It drives the two device paths the same way a round does, but on
# its own elapsed clock:
#   • Serial / Buttplug / restim (C# FunscriptPlayer): BeginOverride free-runs on its own clock even with no
#     round loaded; Stop() ends it.
#   • Handy WiFi (HSP): the normal load_actions → start(clock) → feed(clock) → stop() path, gated on a live
#     connection (the round-scoped start_override path needs a playing round, which the builder hasn't got).
# Effects are already baked into the bundle by the editor, so both paths play it raw. Added as a child of the
# timeline; freeing it (editor rebuild / modal close) auto-stops via _exit_tree so the device is never left
# running.

signal state_changed(playing: bool)  # true on start, false on stop/finish — drives the button label

var _bundle: OverrideBundle = null
var _timeline: OverrideTimeline = null
var _trim_in_ms: int = 0  # playhead offset: the slice plays rebased to 0 but sweeps the lit window
var _start_ticks: int = 0  # wall-clock at play start; elapsed is read from it so it can't drift slow
var _duration_ms: int = 1
var _handy: bool = false


# Elapsed play time (ms). Read from the wall clock rather than summed per-frame deltas — accumulating
# int(delta*1000) truncates the sub-ms remainder every frame, which runs the playhead a few percent slow
# and lags it behind the device's real-time playback.
func _now_ms() -> int:
	return Time.get_ticks_msec() - _start_ticks


func is_playing() -> bool:
	return _bundle != null


# Starts playback of `bundle`, sweeping `timeline`'s playhead across the trimmed window from `trim_in_ms`.
func start(bundle: OverrideBundle, timeline: OverrideTimeline, trim_in_ms: int) -> void:
	stop()
	if bundle == null or bundle.is_empty():
		return
	_bundle = bundle
	_timeline = timeline
	_trim_in_ms = trim_in_ms
	_duration_ms = maxi(1, bundle.duration_ms)
	_start_ticks = Time.get_ticks_msec()

	# C# path: a free-running override, no round needed. Effects are pre-baked, so play raw (immune).
	FunscriptPlayer.BeginOverride(bundle.main, bundle.axes, bundle.vibes, true)
	set_process(true)
	state_changed.emit(true)

	# Handy path (if connected): stream the slice on our elapsed clock via the normal play entry.
	if HandyService.is_connected_ok():
		HandyService.load_actions(bundle.main)
		HandyService.set_effects([])
		var ok: bool = await HandyService.start(_now_ms)
		if _bundle == null:  # stopped/finished during the async session setup
			HandyService.stop()
			return
		_handy = ok
		if _handy:
			HandyService.set_slider(
				SettingsService.get_range_min(), SettingsService.get_range_max()
			)


func stop() -> void:
	if _bundle == null:
		return
	FunscriptPlayer.Stop()
	if _handy:
		HandyService.stop()
	if is_instance_valid(_timeline):
		_timeline.set_playhead(-1)
	_bundle = null
	_timeline = null
	_handy = false
	set_process(false)
	state_changed.emit(false)


func _process(_delta: float) -> void:
	if _bundle == null:
		return
	var ms: int = _now_ms()
	if _handy:
		HandyService.feed(ms)
	if is_instance_valid(_timeline):
		_timeline.set_playhead(_trim_in_ms + ms)
	if ms >= _duration_ms:
		stop()


func _exit_tree() -> void:
	stop()
