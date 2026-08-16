extends Node
## Holds exactly ONE prepared randomizer run and pools its media in the background
## while the previous run is being played. The wait for a 20-part run is 5-10 minutes
## of encoding either way; this service only moves it off the "Play" button and into
## the session that is already running, where the CPU is decoding but never encoding.
##
## An autoload and not an object on the screen, because the screen does not survive
## the Play: Transition.change_scene destroys RandomizerScreen and every coroutine
## hanging off it dies with it. Autoloads survive scene changes — MediaPoolService's
## encode loops await on get_tree().create_timer() and are the working proof.
##
## The prepared run lives purely in memory (no persistence across restarts); the baked
## files survive in the pool anyway and are cache hits on any later identical cut.
##
## The service never touches the EncodeGate itself. It hands BACKGROUND priority to
## prepare_entry_media, and MediaPoolService does the queueing and the preemption.
## See docs/superpowers/specs/2026-08-16-background-baking-contract.md §5.

enum State { IDLE = 0, BAKING = 1, READY = 2, STALE = 3 }

signal state_changed(state: int)
signal progress_changed(done: int, total: int, name: String)

# In exactly this window the GameLoop opens its first video and seeks, and that must
# not race a starting x264.
const PREBAKE_START_DELAY_S: float = 5.0

# Insurance against spinning hot on a preemption retry in a case nobody thought of —
# cheaper than diagnosing such a case (§5.5).
const PREBAKE_RETRY_DELAY_S: float = 1.0

# Longest a wait may sit blind. Every wait is served in slices of at most this length and
# the generation is checked between them, so an obsolete loop settles within ~0.25 s
# instead of sitting out the full start delay. Without it STALE stays observable for 5 s
# with nothing running at all, which the state machine does not promise (§5.3).
const WAIT_SLICE_S: float = 0.25

# Overridable so tests do not have to wait real seconds (§5.8). Never touched in
# production.
var start_delay_s: float = PREBAKE_START_DELAY_S
var retry_delay_s: float = PREBAKE_RETRY_DELAY_S

var _state: int = State.IDLE

# The one prepared run: a flat copy of the generate() result plus settings_key,
# settings and entries (§5.2). Empty means nothing is held.
var _held: Dictionary = {}

# +1 on EVERY schedule / adopt / invalidate. A bake loop remembers its own value at
# start; `_gen != my_gen` is its ONLY abort condition and at the same time the
# should_cancel it hands to prepare_entry_media. State alone would not do: a schedule
# during STALE sets BAKING again straight away, and an old loop looking only at the
# state would consider itself still in charge (§5.4).
var _gen: int = 0

var _done: int = 0
var _total: int = 0
var _current_name: String = ""

# Test seams (§5.8). An invalid Callable means "use the real path".
var _entries_fn: Callable = Callable()
var _prepare_fn: Callable = Callable()
var _preempt_count_fn: Callable = Callable()


func _ready() -> void:
	RandomizerLibrary.library_changed.connect(_on_library_changed)


# Add, remove, clear_all, set_funscript: the run was drawn from a candidate field
# that no longer exists. (update_entry deliberately does not emit — a weight edit
# leaves the run valid, just no longer the exact distribution now dialled in. Known
# and accepted gap of the design.)
func _on_library_changed() -> void:
	invalidate("library_changed")


# ── Public API ───────────────────────────────────────────────────────────────


## Throws away whatever is held, rolls a new run and starts baking it. Returns
## immediately — the screen calls this right before Transition.change_scene.
func schedule(settings: Dictionary) -> void:
	invalidate("rescheduled")
	var s: Dictionary = settings.duplicate(true)
	var seed_val: int = int(s.get("seed", 0))
	if seed_val == 0:
		# EXACTLY the formula of RandomizerScreen._generate_and_preview: expansion and
		# generator must see the same seed here that they would have seen up front, or
		# "same seed → same run" stops holding for a prepared run.
		seed_val = int(Time.get_unix_time_from_system()) ^ (randi() | 1)
	s["seed"] = seed_val
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	# Both are pure and done in milliseconds — a run is fully described here, before
	# any disk I/O happens.
	var entries: Array = RandomizerParts.expand(_library_entries(), s, rng)
	if entries.is_empty():
		# Nothing to draw from. Not an error: nothing is held, the state is whatever
		# invalidate left, and the next Generate rolls normally.
		return
	var res: Dictionary = RandomizerGenerator.generate(entries, s)
	if not bool(res.get("ok", false)):
		return
	# Part pseudo-entries do not exist in RandomizerLibrary — only the video they were
	# cut from does. The index is therefore the counterpart of the screen's
	# _pending_entries and has to travel with the run.
	var index: Dictionary = {}
	for e: Dictionary in entries:
		index[str(e.get("id", ""))] = e
	# A flat copy of the WHOLE result, so the held dict is a drop-in for
	# _show_preview(res) and _prepare_and_materialize(res) (§5.2).
	var held: Dictionary = res.duplicate()
	held["settings_key"] = settings_key(s)
	held["settings"] = s
	held["entries"] = index
	_held = held
	_gen += 1
	_done = 0
	_total = (res["used_ids"] as Array).size()
	_current_name = ""
	_set_state(State.BAKING)
	# Deferred so schedule() is guaranteed to return before anything awaits.
	_bake_loop.call_deferred(_gen)


## Hands the held run over if it matches, otherwise {}. Works during BAKING too — a
## half-done prebake still pays off, because everything already pooled falls through
## the file_exists guards of the visible prepare path.
func adopt(settings: Dictionary) -> Dictionary:
	if _held.is_empty():
		return {}
	if _state != State.BAKING and _state != State.READY:
		return {}
	if int(settings.get("seed", 0)) != 0:
		# Whoever types a seed wants exactly THAT run, not the prepared one with its own.
		return {}
	if settings_key(settings) != str(_held.get("settings_key", "")):
		return {}
	# The object itself, not a copy: the run changes owner, and a deep copy of a whole
	# journey graph would be pure memory and time. Every {} path above leaves the state
	# untouched — a failed adoption attempt must not kill a running prebake.
	var run: Dictionary = _held
	_held = {}
	_gen += 1
	_reset_progress()
	_set_state(State.STALE if _state == State.BAKING else State.IDLE)
	return run


## Discards the held run and aborts a running bake. `reason` is diagnosis only.
func invalidate(reason: String = "") -> void:
	_held = {}
	if _state == State.BAKING:
		# Neither adopt nor invalidate can stop ffmpeg on the spot. STALE is a real,
		# short-lived state: the loop sees it via its generation and settles to IDLE.
		_set_state(State.STALE)
	elif _state == State.READY:
		_reset_progress()
		_set_state(State.IDLE)
	_gen += 1
	if reason != "":
		print_verbose("RandomizerPrebake: invalidated (%s)" % reason)


func state() -> int:
	return _state


func progress() -> Dictionary:
	return {"done": _done, "total": _total, "name": _current_name}


## The settings of the held run, so RandomizerScreen can put its sliders back where
## they were — the scene is rebuilt from scratch after every Play and would otherwise
## generate against a prebake with different settings and throw it away.
func held_settings() -> Dictionary:
	if _held.is_empty() or (_state != State.BAKING and _state != State.READY):
		return {}
	return (_held.get("settings", {}) as Dictionary).duplicate(true)


# Hash of the settings WITHOUT "seed": a prepared run matches the same sliders no
# matter which seed was drawn for it. JSON.stringify sorts the keys (3rd parameter
# sort_keys, passed explicitly so a later default change cannot silently shift the
# hash), the dict is flat and JSON-serializable — so the hash is stable and the
# comparison a string compare. A new settings field changes the hash and the match
# fails; that is the safe direction (a discarded prebake costs CPU, a wrongly adopted
# one delivers a run the user did not order).
static func settings_key(settings: Dictionary) -> String:
	var s: Dictionary = settings.duplicate(true)
	s.erase("seed")
	return JSON.stringify(s, "", true).sha256_text()


# Without this seam the test would run against the user's real registry and spawn
# ffmpeg.
#   entries_fn:       func() -> Array                      replaces RandomizerLibrary.get_all()
#   prepare_fn:       func(entry: Dictionary, on_progress: Callable,
#                          should_cancel: Callable, priority: int) -> Dictionary
#                                                          replaces prepare_entry_media
#   preempt_count_fn: func() -> int                        replaces MediaPoolService.preempt_count()
# An invalid Callable (the default) means: use the real path.
func set_test_hooks(
	entries_fn: Callable, prepare_fn: Callable, preempt_count_fn: Callable = Callable()
) -> void:
	_entries_fn = entries_fn
	_prepare_fn = prepare_fn
	_preempt_count_fn = preempt_count_fn


# ── Bake loop ────────────────────────────────────────────────────────────────


func _bake_loop(my_gen: int) -> void:
	if not await _wait(start_delay_s, my_gen):
		_settle_obsolete()
		return
	var ids: Array = (_held.get("used_ids", []) as Array).duplicate()
	var index: Dictionary = _held.get("entries", {}) as Dictionary
	var total: int = ids.size()
	var cancel: Callable = func() -> bool: return _gen != my_gen
	while true:
		var preempted: bool = false
		for i: int in total:
			if _gen != my_gen:
				_settle_obsolete()
				return
			var sid: String = str(ids[i])
			var entry: Dictionary = index.get(sid, {}) as Dictionary
			if entry.is_empty():
				entry = RandomizerLibrary.get_entry(sid)
			if entry.is_empty():
				_fail_run()  # an id that resolves nowhere is a real error
				return
			_publish_progress(i + 1, total, str(entry.get("name", "")))
			# Snapshot around the call: the counter is monotonic, so any rise between
			# here and the return belongs to this call — preemption, not a failure.
			var before: int = _preempt_count()
			var pr: Dictionary = await _prepare(entry, cancel)
			if _gen != my_gen:
				# Our own abort wish (adopt / invalidate / reschedule). Not an error.
				_settle_obsolete()
				return
			if not bool(pr.get("ok", false)):
				if _preempt_count() != before:
					# Preempted: run the list again from the front. The idempotency
					# guards skip everything already done; exactly the one part that
					# was running is lost, so no bookkeeping is needed (§5.5, case 3).
					preempted = true
					break
				_fail_run()  # §5.5, case 4
				return
		if not preempted:
			break
		if not await _wait(retry_delay_s, my_gen):
			_settle_obsolete()
			return
	_current_name = ""
	_set_state(State.READY)


# Waits `secs` and reports whether this loop is still in charge afterwards (true = still
# ours). The wait is served in WAIT_SLICE_S slices with a generation check in between, so
# an adopt/invalidate/reschedule during the start delay is noticed in a quarter second
# instead of after the full five.
func _wait(secs: float, my_gen: int) -> bool:
	if secs <= 0.0:
		# Even at 0 the loop ALWAYS yields once, so it never runs through synchronously.
		await get_tree().process_frame
		return _gen == my_gen
	var left: float = secs
	while left > 0.0:
		# The last slice is exactly the remainder, so `left` hits 0.0 dead on and no
		# rounding crumb buys another timer.
		var slice: float = minf(left, WAIT_SLICE_S)
		await get_tree().create_timer(slice).timeout
		if _gen != my_gen:
			return false
		left -= slice
	return true


# Cleanup of a loop that became obsolete. Only if nobody newer is in charge: BAKING
# means a younger loop owns the state, READY/IDLE that somebody already tidied up.
func _settle_obsolete() -> void:
	if _state == State.STALE:
		_reset_progress()
		_set_state(State.IDLE)


# A real failure: degrade silently. No popup, no sound — the user is playing. The
# next Generate rolls normally, and if the cause persists the visible prepare path
# reports it with its usual text.
func _fail_run() -> void:
	_held = {}
	_reset_progress()
	_set_state(State.IDLE)


# on_progress is empty on the background path: the UI shows only n/m, so a percent
# callback every 0.4 s would be signal noise without a receiver.
func _prepare(entry: Dictionary, cancel: Callable) -> Dictionary:
	if _prepare_fn.is_valid():
		return await _prepare_fn.call(entry, Callable(), cancel, EncodeGate.Priority.BACKGROUND)
	return await RandomizerLibrary.prepare_entry_media(
		entry, Callable(), cancel, EncodeGate.Priority.BACKGROUND
	)


# ── Internals ────────────────────────────────────────────────────────────────


func _library_entries() -> Array:
	if _entries_fn.is_valid():
		return _entries_fn.call() as Array
	return RandomizerLibrary.get_all()


func _preempt_count() -> int:
	if _preempt_count_fn.is_valid():
		return int(_preempt_count_fn.call())
	return MediaPoolService.preempt_count()


func _set_state(s: int) -> void:
	if _state == s:
		return
	_state = s
	state_changed.emit(_state)


# Deliberately silent: the UI hides the line via state_changed, so an extra
# progress_changed(0, 0, "") would only make it flicker.
func _reset_progress() -> void:
	_done = 0
	_total = 0
	_current_name = ""


# 1-based on the entry that is running RIGHT NOW, published before the call: that
# makes "Preparing next run 3/12…" read as "entry 3 of 12 is up", and at READY
# done == total.
func _publish_progress(done: int, total: int, entry_name: String) -> void:
	_done = done
	_total = total
	_current_name = entry_name
	progress_changed.emit(_done, _total, _current_name)
