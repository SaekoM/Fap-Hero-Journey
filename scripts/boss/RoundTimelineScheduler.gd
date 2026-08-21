class_name RoundTimelineScheduler
extends RefCounted
## Decides WHAT should happen on a boss timeline at a given video position — and nothing else. It
## starts no overrides, pushes no effects and draws nothing: `tick()` returns a plain decision record
## and the GameLoop applies it. That split is the whole point: the timing rules (crossings, windows,
## seeks, loop replays, phases) are the fiddly part, and keeping them free of engine calls means they
## are unit-tested headlessly instead of debugged in a live boss round.
##
## Two kinds of event, two rules — and which one an event is depends on its TRACK, not on whether it
## happens to have a duration:
##   • ONE-SHOT — fires once, on a forward crossing of its time. A fired-set keeps it from re-firing
##     while the round plays on. Attacks and audio cues are always one-shots: their duration describes
##     how long the MEDIA runs (and which slice of it plays), not a window to be held open. An attack
##     whose length made it "windowed" would never fire at all.
##   • WINDOWED — active exactly while `at <= pos < at + duration`, RECONCILED every tick rather than
##     toggled by events. Reconciliation is idempotent, which is what makes pause, seek and replay fall
##     out for free instead of each needing their own special case. Effects are always windows; a cast
##     cue is one only when given a duration, otherwise it is a flash.
##
## Positions come from the round's video, so PAUSE needs no handling at all: the position stops moving
## and every rule above is a no-op. Seeks and loop replays do need handling — see seek() and reset().
##
## Typical driving (GameLoop side):
##     var d := scheduler.tick(video_pos_ms)
##     apply d["stop"], then d["start"], then d["fire"]   # tear down before building up
##     if d["phase_changed"]: update the phase banner / tint

# A forward jump larger than this is treated as a SEEK, not as playback catching up. Without it, one
# stalled frame (a slow video load, a device re-anchor the caller forgot to announce) would dump every
# one-shot it flew past into a single tick — a burst of attacks and cues firing at once. Skipping a cue
# is the far better failure of the two. Generous enough that ordinary hitching never trips it.
const MAX_CATCHUP_MS: int = 2000

# Events for the normal (victory) pass, resolved to absolute positions and sorted.
var _events: Array = []

# The `on: "defeat"` set — never fired by tick(); the bail-out path asks for them explicitly.
var _defeat: Array = []

var _phases: Array = []

# id → true for every one-shot already fired this pass. Cleared by reset(), re-armed by seek().
var _fired: Dictionary = {}

# id → event for every window currently applied. The mirror of what the GameLoop has switched on.
var _active: Dictionary = {}

# Last position seen. -1 means "nothing yet", so the first tick can fire an event sitting at 0.
var _pos_ms: int = -1

var _phase_id: String = ""


func _init(timeline: Dictionary = {}, video_duration_ms: int = 0) -> void:
	_events = RoundTimeline.resolved_events(timeline, video_duration_ms)
	_defeat = RoundTimeline.resolved_events(timeline, video_duration_ms, true)
	_phases = RoundTimeline.resolved_phases(timeline, video_duration_ms)


# ── Driving ──────────────────────────────────────────────────────────────────


## Advances to `pos_ms` and returns what the caller should do:
##     { fire: [events], start: [events], stop: [events], phase_changed: bool, phase: {} }
## Apply `stop` before `start` (a window ending and another beginning in one tick should tear down
## first), and `fire` last. `phase` is {} when the position sits outside every phase.
##
## Backward movement, and any forward jump beyond MAX_CATCHUP_MS, are handled as a seek — see seek().
func tick(pos_ms: int) -> Dictionary:
	var prev: int = _pos_ms
	if prev >= 0 and (pos_ms < prev or pos_ms - prev > MAX_CATCHUP_MS):
		return seek(pos_ms)
	if prev < 0:
		# First tick of a pass. Baseline just BEHIND the position: an event sitting exactly on it still
		# fires (a round opener at 0), while everything further back counts as already past. Baselining
		# at zero instead would make a resume mid-round dump the entire first half into one tick.
		prev = pos_ms - 1
	_pos_ms = pos_ms

	var out: Dictionary = _blank()
	for e: Dictionary in _events:
		if _is_windowed(e):
			continue
		var at: int = int(e["resolved_at_ms"])
		# Half-open on the left so an event exactly at the previous position never fires twice, and
		# closed on the right so one landing exactly on this tick is not skipped.
		if at > prev and at <= pos_ms and not _fired.has(e["id"]):
			_fired[str(e["id"])] = true
			out["fire"].append(e)
	_reconcile_windows(pos_ms, out)
	_update_phase(pos_ms, out)
	return out


## Jumps to `pos_ms` WITHOUT firing everything in between — the device re-anchor / resume path. Windows
## reconcile to the new position (so an effect that covers it switches on, and one that no longer does
## switches off), and one-shots are re-baselined: those now behind us are marked as already fired, those
## ahead are re-armed so a backward seek can play them again. Returns the same record as tick().
func seek(pos_ms: int) -> Dictionary:
	_pos_ms = pos_ms
	var out: Dictionary = _blank()
	for e: Dictionary in _events:
		if _is_windowed(e):
			continue
		var id: String = str(e["id"])
		if int(e["resolved_at_ms"]) <= pos_ms:
			_fired[id] = true  # behind us now — skipped, not replayed
		else:
			_fired.erase(id)  # ahead of us again — allowed to fire when reached
	_reconcile_windows(pos_ms, out)
	_update_phase(pos_ms, out)
	return out


## Back to the top: forget every fired one-shot and drop the phase, so the round can play again from
## scratch. Used by a LOOP replay. Any window still applied is returned in `stop` — the caller switched
## it on, so only the caller can switch it off.
func reset() -> Dictionary:
	var out: Dictionary = _blank()
	for id: Variant in _active:
		out["stop"].append(_active[id])
	_active.clear()
	_fired.clear()
	_pos_ms = -1
	_phase_id = ""
	return out


## The round is over (normally, or cut short): everything still applied comes back in `stop`. The
## fired-set is deliberately left alone — the round is finished, not restarting.
func finish() -> Dictionary:
	var out: Dictionary = _blank()
	for id: Variant in _active:
		out["stop"].append(_active[id])
	_active.clear()
	return out


# ── Queries ──────────────────────────────────────────────────────────────────


## The authored `on: "defeat"` events, in order — one authored event for the bail-out path, in place of
## the victory outro.
func defeat_events() -> Array:
	return _defeat.duplicate()


## Every window currently applied, in no particular order.
func active_events() -> Array:
	return _active.values()


## The phase the position currently sits in, or {} when it sits before the first one.
func current_phase() -> Dictionary:
	for p: Dictionary in _phases:
		if str(p.get("id", "")) == _phase_id:
			return p
	return {}


## Events for the normal pass, resolved and ordered — what the editor and the tests read back.
func events() -> Array:
	return _events.duplicate()


## True when there is nothing at all to drive, so the GameLoop can skip the whole subsystem.
func is_idle() -> bool:
	return _events.is_empty() and _phases.is_empty() and _defeat.is_empty()


# ── Internals ────────────────────────────────────────────────────────────────


# Windows are decided by CONTAINMENT, never by remembering an edge was crossed: "should this be on at
# `pos`?" compared against "is it on?". That is what makes the same code correct after a pause, a seek
# backwards into the middle of a window, or a replay.
func _reconcile_windows(pos_ms: int, out: Dictionary) -> void:
	for e: Dictionary in _events:
		if not _is_windowed(e):
			continue
		var duration: int = int(e.get("duration_ms", 0))
		var id: String = str(e["id"])
		var at: int = int(e["resolved_at_ms"])
		var should_be_on: bool = at <= pos_ms and pos_ms < at + duration
		var is_on: bool = _active.has(id)
		if should_be_on and not is_on:
			_active[id] = e
			out["start"].append(e)
		elif is_on and not should_be_on:
			_active.erase(id)
			out["stop"].append(e)


# The current phase is simply the last one whose start is at or behind the position — containment
# again, so it is as seek-proof as the windows are.
func _update_phase(pos_ms: int, out: Dictionary) -> void:
	var found: Dictionary = {}
	for p: Dictionary in _phases:
		if int(p["resolved_at_ms"]) <= pos_ms:
			found = p
		else:
			break  # _phases is sorted, so the first one ahead ends the search
	var found_id: String = str(found.get("id", ""))
	if found_id != _phase_id:
		_phase_id = found_id
		out["phase_changed"] = true
		out["phase"] = found


# Whether an event is held OPEN for a stretch (reconciled) or fires at an instant. Keyed off the track
# so a media event's own length can never be mistaken for a window — see the class comment.
static func _is_windowed(event: Dictionary) -> bool:
	match str(event.get("track", "")):
		RoundTimeline.TRACK_EFFECT:
			return true
		RoundTimeline.TRACK_CAST:
			return int(event.get("duration_ms", 0)) > 0
	return false  # attacks and audio always fire


static func _blank() -> Dictionary:
	return {"fire": [], "start": [], "stop": [], "phase_changed": false, "phase": {}}
