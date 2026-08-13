class_name OverrideSession
extends RefCounted

# The pure lifecycle + clock for ONE device takeover, shared by every override trigger (an inventory
# item today, Boss Attacks later — see OVERRIDE_ITEMS_DESIGN.md). It owns no device calls: the
# coordinator (GameLoop) drives the real device paths and reacts to this session's state and events.
# Keeping the timing and the begin/replace/cut/complete transitions here makes them deterministic and
# unit-testable, with no video, device, or UI in the loop.
#
# Each frame the coordinator calls tick(delta_ms) and restores normal round playback when the event
# is EVENT_COMPLETED (or right after it calls cut()). While is_active() the round's own re-anchors
# are suppressed, so the override owns the device until it ends.

const EVENT_NONE := ""
const EVENT_COMPLETED := "completed"

var _active: bool = false
var _paused: bool = false
var _elapsed_ms: int = 0
var _bundle: OverrideBundle = null
var _immune: bool = false
var _source: String = ""


# Starts a takeover from idle. Resets the clock and stores the per-request immunity flag and source
# (provenance: "item" / "boss_attack").
func begin(bundle: OverrideBundle, immune: bool, source: String) -> void:
	_active = true
	_paused = false
	_elapsed_ms = 0
	_bundle = bundle
	_immune = immune
	_source = source


# Replaces a running override with a new one (the item re-activation policy): swap the bundle and
# restart the clock while staying active, with no intermediate hand-back to the round. Identical to
# begin() from idle — the coordinator decides device-side whether a re-anchor is needed (it isn't).
func replace(bundle: OverrideBundle, immune: bool, source: String) -> void:
	begin(bundle, immune, source)


# Ends the takeover immediately (round end, or a policy cut). Fires no EVENT_COMPLETED — the caller
# chose to stop it — and the coordinator does the device restore.
func cut() -> void:
	_active = false
	_bundle = null


# Advances the clock by delta_ms unless paused or idle. Returns EVENT_COMPLETED exactly once, on the
# tick that reaches the bundle duration (and goes inactive); EVENT_NONE otherwise.
func tick(delta_ms: int) -> String:
	if not _active or _paused:
		return EVENT_NONE
	_elapsed_ms += maxi(0, delta_ms)
	if _elapsed_ms >= _duration():
		_active = false
		return EVENT_COMPLETED
	return EVENT_NONE


# Pausing holds the clock (the game pause pauses the override too; they resume together).
func set_paused(paused: bool) -> void:
	_paused = paused


func is_paused() -> bool:
	return _paused


# True while the override owns the device — also the re-anchor-suppression signal for the round.
func is_active() -> bool:
	return _active


# Clock position clamped to the bundle length — what the device paths are fed while active.
func position_ms() -> int:
	return mini(_elapsed_ms, _duration())


func remaining_ms() -> int:
	return maxi(0, _duration() - _elapsed_ms)


# Whether the active override ignores the run's stroke effects/curses (the per-item flag).
func is_immune() -> bool:
	return _immune


# Provenance of the active override ("item" / "boss_attack"), for the future policy + telemetry split.
func source() -> String:
	return _source


func bundle() -> OverrideBundle:
	return _bundle


func _duration() -> int:
	return _bundle.duration_ms if _bundle != null else 0
