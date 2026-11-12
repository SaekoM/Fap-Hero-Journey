class_name MiniGameDevice
extends RefCounted

# What a mini-game asks the device to do. Remembers the stroke it last asked for, so a game can say what it
# wants every frame and only real changes reach the hardware. The device is always optional: with nothing
# connected, every call here is harmless.

const NOT_RUNNING: int = -1
# A stream of axis positions is sent no faster than this, each move a little longer so the device keeps gliding.
const AXIS_STREAM_INTERVAL_MS: int = 33
const AXIS_STREAM_MOVE_MS: int = 50

var _lo: int = NOT_RUNNING
var _hi: int = NOT_RUNNING
var _half_cycle_ms: int = NOT_RUNNING
var _last_axis_stream_ms: int = -AXIS_STREAM_INTERVAL_MS
# The newest positions stream_axes held back for the rate, and what follow_axes was last given.
var _unsent_axis_positions: Dictionary = {}
var _followed_axis_positions: Dictionary = {}
# Counts every new request, so an ending queued behind a movement (play_axis_moves_then) knows if it's still wanted.
var _requests: int = 0


func is_running() -> bool:
	return _lo != NOT_RUNNING


# A steady stroke, starting it if nothing is running.
func hold(lo: int, hi: int, half_cycle_ms: int) -> void:
	if lo == _lo and hi == _hi and half_cycle_ms == _half_cycle_ms:
		return
	_requests += 1
	var was_running: bool = is_running()
	_remember(lo, hi, half_cycle_ms)
	if was_running:
		DeviceFiller.set_params(lo, hi, half_cycle_ms)
	else:
		DeviceFiller.start(lo, hi, half_cycle_ms)


# Small strokes walking up and down the range, slowing from `fastest_ms` to `slowest_ms` over `secs`, then
# staying that slow until told otherwise.
func walk(fastest_ms: int, slowest_ms: int, secs: float) -> void:
	_requests += 1
	DeviceFiller.walk(fastest_ms, slowest_ms, secs)
	# Not a steady stroke, so the next hold() always counts as a change.
	_forget_stroke_but_stay_running()


# Moves secondary axes, {axis: position}, over `duration_ms`.
func move_axes(positions: Dictionary, duration_ms: int) -> void:
	if is_running():
		DeviceFiller.move_axes(
			only_axes_in(positions, SettingsService.get_device_axes()), duration_ms
		)


# For positions that change every frame: sends them at a rate the serial line can carry.
func stream_axes(positions: Dictionary) -> void:
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _last_axis_stream_ms >= AXIS_STREAM_INTERVAL_MS:
		_last_axis_stream_ms = now_ms
		_unsent_axis_positions = {}
		move_axes(positions, AXIS_STREAM_MOVE_MS)
	else:
		_unsent_axis_positions = positions


# For positions that move on some frames and rest on others: streams them while they move, and once they rest, sends
# the last of them if the rate held it back, so the axes always land where the picture did.
func follow_axes(positions: Dictionary) -> void:
	if positions != _followed_axis_positions:
		_followed_axis_positions = positions
		stream_axes(positions)
	elif not _unsent_axis_positions.is_empty():
		var last_positions: Dictionary = _unsent_axis_positions
		_unsent_axis_positions = {}
		move_axes(last_positions, AXIS_STREAM_MOVE_MS)


# A one-off movement, then `ending` (ease_out or stop) once it has played, unless something else has been asked of
# the device by then.
func play_axis_moves_then(steps: Array, ending: Callable) -> void:
	play_axis_moves(steps)
	_requests += 1
	var request: int = _requests
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	tree.create_timer(MiniGameAxes.moves_ms(steps) / 1000.0).timeout.connect(
		func() -> void:
			if request == _requests:
				ending.call()
	)


# A one-off movement, as MiniGameAxes describes them.
func play_axis_moves(steps: Array) -> void:
	if not is_running():
		return
	var device_axes: Array = SettingsService.get_device_axes()
	var usable_steps: Array = []
	for step: Dictionary in steps:
		var positions: Dictionary = only_axes_in(step["positions"], device_axes)
		usable_steps.append({"positions": positions, "ms": step["ms"]})
	DeviceFiller.play_axis_moves(usable_steps)


# Whether the player's device profile includes this axis.
func has_axis(axis: String) -> bool:
	return SettingsService.device_has_axis(axis)


# `positions` without the axes the player's device doesn't have.
static func only_axes_in(positions: Dictionary, device_axes: Array) -> Dictionary:
	var kept: Dictionary = {}
	for axis: String in positions:
		if device_axes.has(axis):
			kept[axis] = positions[axis]
	return kept


# A gentle ending: the device glides back to the middle.
func ease_out() -> void:
	_requests += 1
	if is_running():
		_forget()
		DeviceFiller.ease_out()


# An abrupt ending.
func stop() -> void:
	_requests += 1
	if is_running():
		_forget()
		DeviceFiller.stop()


func _remember(lo: int, hi: int, half_cycle_ms: int) -> void:
	_lo = lo
	_hi = hi
	_half_cycle_ms = half_cycle_ms


func _forget_stroke_but_stay_running() -> void:
	_half_cycle_ms = NOT_RUNNING
	_lo = 0
	_hi = 100


func _forget() -> void:
	_remember(NOT_RUNNING, NOT_RUNNING, NOT_RUNNING)
	_unsent_axis_positions = {}
