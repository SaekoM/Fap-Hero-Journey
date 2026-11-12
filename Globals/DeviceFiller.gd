extends Node

## The storyboard filler's one entry point: a plain alternating stroke sent to every connected device.
##
## There are two ways a stroke reaches hardware in this app, and the filler needs both. Serial and
## Buttplug devices take one "go to X over N ms" command per half-stroke, which FunscriptPlayer issues
## from its own tick. A Handy on direct WiFi takes a streamed point script instead, which is why the
## filler never reached one — FunscriptPlayer's filler has no path to it, so a storyboard (and the
## builder's test button) left a WiFi Handy sitting still.
##
## Neither backend minds being asked when it isn't there: each call no-ops on a device that isn't
## connected, so callers say "fill" once and every device that can hear it does.

const MIN_HALF_CYCLE_MS: int = 50

# The serial and Buttplug half of a running walk().
var _walk_tween: Tween = null
# A one-off movement of the secondary axes in progress (play_axis_moves).
var _axis_moves_tween: Tween = null


## Starts the stroke on every connected device. `lo`/`hi` are 0-100 positions (either order),
## `half_cycle_ms` is one stroke in one direction.
func start(lo: int, hi: int, half_cycle_ms: int) -> void:
	_end_walk()
	var half: int = maxi(MIN_HALF_CYCLE_MS, half_cycle_ms)
	var bottom: int = clampi(mini(lo, hi), 0, 100)
	var top: int = clampi(maxi(lo, hi), 0, 100)
	FunscriptPlayer.StartFiller(bottom, top, half)
	# Fire-and-forget: the Handy path is HTTP, and a caller opening a storyboard shouldn't wait on a
	# round trip to show it. A failure there is already reported by HandyService.
	HandyService.start_filler(bottom, top, half)
	AutoblowService.start_filler(bottom, top, half)


## Re-aims a running stroke without restarting it, for a live edit while testing.
func set_params(lo: int, hi: int, half_cycle_ms: int) -> void:
	_end_walk()
	var half: int = maxi(MIN_HALF_CYCLE_MS, half_cycle_ms)
	var bottom: int = clampi(mini(lo, hi), 0, 100)
	var top: int = clampi(maxi(lo, hi), 0, 100)
	FunscriptPlayer.SetFillerParams(bottom, top, half)
	# The Handy is looping a script rather than taking commands, so a new aim IS a new script.
	if HandyService.is_filler_active():
		HandyService.start_filler(bottom, top, half)
	if AutoblowService.is_filler_active():
		AutoblowService.start_filler(bottom, top, half)


## Small strokes walking up and down the range, slowing from `fastest_ms` to `slowest_ms` over `secs`. A Handy
## gets it as one script. Serial and Buttplug devices stroke on their own timer, so they are steered along the
## same script: their stroke range and pace follow it as it plays.
func walk(fastest_ms: int, slowest_ms: int, secs: float) -> void:
	_end_walk()
	var slowdown_ms: int = roundi(secs * 1000.0)
	var points: Array = HandyPoints.walking_strokes(0, fastest_ms, slowest_ms, slowdown_ms)
	var length_ms: float = float((points[points.size() - 1] as Dictionary)["t"])
	_walk_tween = create_tween()
	_walk_tween.tween_method(_steer_along.bind(points), 0.0, length_ms, length_ms / 1000.0)
	HandyService.start_filler_walk(fastest_ms, slowest_ms, slowdown_ms)
	AutoblowService.start_filler_walk(fastest_ms, slowest_ms, slowdown_ms)


# Sets the stroke to match the part of the script at `time_ms`.
func _steer_along(time_ms: float, points: Array) -> void:
	var next_index: int = clampi(
		HandyPoints.index_at_or_after(points, roundi(time_ms)), 1, points.size() - 1
	)
	var previous: Dictionary = points[next_index - 1]
	var next: Dictionary = points[next_index]
	var centre: int = (int(previous["x"]) + int(next["x"])) / 2
	var half_stroke: int = HandyPoints.WALK_STROKE_LENGTH / 2
	FunscriptPlayer.SetFillerParams(
		maxi(0, centre - half_stroke),
		mini(100, centre + half_stroke),
		int(next["t"]) - int(previous["t"])
	)


## Moves secondary axes, {axis: position}, over `duration_ms`. Serial only: every other device ignores this.
func move_axes(positions: Dictionary, duration_ms: int) -> void:
	for axis: String in positions:
		FunscriptPlayer.MoveGameAxis(axis, float(positions[axis]), duration_ms)


## Plays [{positions, ms}] steps in order, each moving the axes over its `ms`. A new one replaces one still playing.
func play_axis_moves(steps: Array) -> void:
	_end_axis_moves()
	_axis_moves_tween = create_tween()
	for step: Dictionary in steps:
		var duration_ms: int = int(step["ms"])
		_axis_moves_tween.tween_callback(move_axes.bind(step["positions"], duration_ms))
		_axis_moves_tween.tween_interval(duration_ms / 1000.0)


## Ends the stroke with every device gliding back to the middle.
func ease_out() -> void:
	_end_walk()
	_end_axis_moves()
	FunscriptPlayer.StopFiller()  # already eases to neutral
	HandyService.ease_filler_home()
	AutoblowService.stop_filler()  # a live speed has no position to glide to: it just stops


## Stops every device. Both halves are idempotent and neither is conditional on this having started
## the stroke — a stop is the one call that must never be skipped on a guess about what is running.
func stop() -> void:
	_end_walk()
	_end_axis_moves()
	FunscriptPlayer.StopFiller()
	HandyService.stop_filler()
	AutoblowService.stop_filler()


func _end_axis_moves() -> void:
	if _axis_moves_tween != null:
		_axis_moves_tween.kill()
		_axis_moves_tween = null


func _end_walk() -> void:
	if _walk_tween != null:
		_walk_tween.kill()
		_walk_tween = null
