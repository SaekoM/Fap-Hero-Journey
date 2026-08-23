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

# Events that fire on the way OUT of the round — never by tick(); each exit path asks for its own set.
var _outcomes: Array = []

var _phases: Array = []

# id → true for every one-shot already fired this pass. Cleared by reset(), re-armed by seek().
var _fired: Dictionary = {}

# id → event for every window currently applied. The mirror of what the GameLoop has switched on.
var _active: Dictionary = {}

# Last position seen. -1 means "nothing yet", so the first tick can fire an event sitting at 0.
var _pos_ms: int = -1

var _phase_id: String = ""

# Segments, and the branch each has committed to. A fork is UNDECIDED until one of its events first
# wants to happen — see _branch_allows(). Deciding at round start instead would evaluate every condition
# against a player who has not done anything yet, which is the whole reason conditions exist.
var _segments: Dictionary = {}  # segment_id → segment
var _tag_owner: Dictionary = {}  # tag → segment_id
var _picks: Dictionary = {}  # segment_id → the tag that won

# id → true/false for every event whose own `condition` has been judged. Latched on first consideration
# rather than re-read each tick: a window whose condition flickered would switch itself on and off
# mid-stretch, which reads as a bug rather than as responsiveness.
var _gated: Dictionary = {}

# Injected so a test can seed it and a round is reproducible. Only consulted for branches the author
# left unconditioned — a rule always beats a roll.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init(
	timeline: Dictionary = {}, video_duration_ms: int = 0, rng: RandomNumberGenerator = null
) -> void:
	_events = RoundTimeline.resolved_events(timeline, video_duration_ms)
	_outcomes = RoundTimeline.resolved_events(timeline, video_duration_ms, true)
	_phases = RoundTimeline.resolved_phases(timeline, video_duration_ms)
	for segment: Dictionary in timeline.get("segments", []) as Array:
		_segments[str(segment.get("id", ""))] = segment
	_tag_owner = RoundTimeline.tag_owners(timeline)
	if rng != null:
		_rng = rng


# ── Driving ──────────────────────────────────────────────────────────────────


## Advances to `pos_ms` and returns what the caller should do:
##     { fire: [events], start: [events], stop: [events], phase_changed: bool, phase: {} }
## Apply `stop` before `start` (a window ending and another beginning in one tick should tear down
## first), and `fire` last. `phase` is {} when the position sits outside every phase.
##
## Backward movement, and any forward jump beyond MAX_CATCHUP_MS, are handled as a seek — see seek().
func tick(pos_ms: int, state: Dictionary = {}) -> Dictionary:
	var prev: int = _pos_ms
	if prev >= 0 and (pos_ms < prev or pos_ms - prev > MAX_CATCHUP_MS):
		return seek(pos_ms, state)
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
			# Marked fired either way: an event held back by its branch or its condition has HAPPENED as
			# far as the clock is concerned, and re-testing it on every later tick would let it slip in
			# the moment the player's state drifted past the threshold.
			_fired[str(e["id"])] = true
			if _plays(e, state):
				out["fire"].append(e)
	_reconcile_windows(pos_ms, out, state)
	_update_phase(state, out)
	return out


# Whether this event happens at all: its segment must have picked its branch, and its own condition must
# hold. Both are decided HERE, the first moment the event matters, and then remembered.
func _plays(event: Dictionary, state: Dictionary) -> bool:
	return _branch_allows(event, state) and _gate_allows(event, state)


# Commits the event's segment to a branch if it has not already, then reports whether this event is on
# it. An untagged event, or one whose tag no segment claims, always plays — an unrecognised tag must
# never silently delete content.
func _branch_allows(event: Dictionary, state: Dictionary) -> bool:
	var tag: String = str(event.get("variant_tag", ""))
	if tag == "" or not _tag_owner.has(tag):
		return true
	var segment_id: String = str(_tag_owner[tag])
	if not _picks.has(segment_id):
		_picks[segment_id] = RoundTimeline.choose_branch(_segments[segment_id], state, _rng)
	return str(_picks[segment_id]) == tag


func _gate_allows(event: Dictionary, state: Dictionary) -> bool:
	var id: String = str(event.get("id", ""))
	if not _gated.has(id):
		_gated[id] = RoundTimeline.evaluate_condition(event.get("condition", []), state)
	return bool(_gated[id])


## The branch each segment committed to this round, for anything that needs to show what happened.
func picked_branches() -> Dictionary:
	return _picks.duplicate()


## Jumps to `pos_ms` WITHOUT firing everything in between — the device re-anchor / resume path. Windows
## reconcile to the new position (so an effect that covers it switches on, and one that no longer does
## switches off), and one-shots are re-baselined: those now behind us are marked as already fired, those
## ahead are re-armed so a backward seek can play them again. Returns the same record as tick().
func seek(pos_ms: int, state: Dictionary = {}) -> Dictionary:
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
	_reconcile_windows(pos_ms, out, state)
	_update_phase(state, out)
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
	# A replay is a fresh encounter: the forks decide again, against whatever the player is doing NOW.
	# seek() deliberately keeps them — scrubbing inside one round must not reshuffle it.
	_picks.clear()
	_gated.clear()
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


## The events authored for one way OUT of the round, in order. The caller names which exit it is taking,
## rather than there being an accessor per outcome — the set grows, the shape does not.
func outcome_events(on_mode: String) -> Array:
	var out: Array = []
	for e: Dictionary in _outcomes:
		if str(e.get("on", "")) == on_mode:
			out.append(e)
	return out


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
	return _events.is_empty() and _phases.is_empty() and _outcomes.is_empty()


# ── Internals ────────────────────────────────────────────────────────────────


# Windows are decided by CONTAINMENT, never by remembering an edge was crossed: "should this be on at
# `pos`?" compared against "is it on?". That is what makes the same code correct after a pause, a seek
# backwards into the middle of a window, or a replay.
func _reconcile_windows(pos_ms: int, out: Dictionary, state: Dictionary) -> void:
	for e: Dictionary in _events:
		if not _is_windowed(e):
			continue
		var duration: int = int(e.get("duration_ms", 0))
		var id: String = str(e["id"])
		var at: int = int(e["resolved_at_ms"])
		# A window only asks about its branch once it would otherwise be opening. Testing every window on
		# every tick would commit every fork in the encounter on the first frame, against a player who
		# has not moved yet.
		var contains: bool = at <= pos_ms and pos_ms < at + duration
		var should_be_on: bool = contains and (_active.has(id) or _plays(e, state))
		var is_on: bool = _active.has(id)
		if should_be_on and not is_on:
			_active[id] = e
			out["start"].append(e)
		elif is_on and not should_be_on:
			_active.erase(id)
			out["stop"].append(e)


# The current phase is the last one the boss has dropped to the health of — containment again, but on
# the BAR rather than the clock, so it is as seek-proof as the windows are and a replay carrying damage
# over resumes in the stage that damage earned rather than starting the fight's shape again.
func _update_phase(state: Dictionary, out: Dictionary) -> void:
	var hp: float = float(state.get(RoundTimeline.SIGNAL_BOSS_HP, 1.0))
	var found: Dictionary = {}
	for p: Dictionary in _phases:
		if float(p["resolved_hp_at"]) >= hp:
			found = p
		else:
			break  # _phases runs full health first, so the first one below ends the search
	var found_id: String = str(found.get("id", ""))
	if found_id != _phase_id:
		_phase_id = found_id
		out["phase_changed"] = true
		out["phase"] = found


# Whether an event is held OPEN for a stretch (reconciled) or fires at an instant. Keyed off the track
# so a media event's own length can never be mistaken for a window — see the class comment.
static func _is_windowed(event: Dictionary) -> bool:
	match str(event.get("track", "")):
		RoundTimeline.TRACK_EFFECT, RoundTimeline.TRACK_STANCE:
			return true
		RoundTimeline.TRACK_CAST:
			return int(event.get("duration_ms", 0)) > 0
	return false  # attacks and audio always fire


static func _blank() -> Dictionary:
	return {"fire": [], "start": [], "stop": [], "phase_changed": false, "phase": {}}
