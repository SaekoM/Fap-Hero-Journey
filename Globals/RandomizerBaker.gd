extends Node
## Finishes baking the run that is CURRENTLY being played. The visible Play path only
## prepares the parts of the first two rounds, so the session starts after a minute
## instead of after ten; everything behind those rounds is encoded here, in play order,
## while the user is already playing, and hardlinked into the run folder the moment it
## is done. The arithmetic works out because the encode runs several times faster than
## the playback: the baker gains ground during the session instead of losing it.
##
## The GameLoop asks exactly one question — round_state(index) — before it enters a
## round. Without an active run the answer is always READY, so normal journeys and keep
## runs behave bit-identically and the GameLoop needs no case distinction by run type.
##
## An autoload and not an object on the screen, because the screen does not survive the
## Play: Transition.change_scene destroys RandomizerScreen and every coroutine hanging
## off it dies with it. Autoloads survive scene changes — MediaPoolService's encode
## loops await on get_tree().create_timer() and are the working proof.
##
## The service never touches the EncodeGate itself. It hands BACKGROUND priority to
## prepare_entry_media, and MediaPoolService does the queueing and the preemption.
## See docs/superpowers/specs/2026-08-16-progressive-baking-contract.md §1.

enum RoundState { READY = 0, PENDING = 1, FAILED = 2 }

signal round_ready(index: int)
signal round_failed(index: int)
signal progress_changed(done: int, total: int, name: String)

# In exactly this window the GameLoop opens its first video and seeks, and that must
# not race a starting x264 (§5).
const START_DELAY_S: float = 5.0

# Insurance against spinning hot on a preemption retry in a case nobody thought of —
# cheaper than diagnosing such a case.
const RETRY_DELAY_S: float = 1.0

# Longest a wait may sit blind. Every wait is served in slices of at most this length and
# the generation is checked between them, so a loop that went obsolete during the start
# delay settles within ~0.25 s instead of sitting out the full five seconds.
const WAIT_SLICE_S: float = 0.25

# Overridable so tests do not have to wait real seconds (§1.8). Never touched in
# production.
var start_delay_s: float = START_DELAY_S
var retry_delay_s: float = RETRY_DELAY_S

# The round state table. Index = 0-based VIDEO round index (§2.1): the index into
# used_ids, the index here, and GameState.RoundNumber - 1 while the loop stands on that
# round. Shop nodes carry none of the three.
# Per entry: {"rels": PackedStringArray, "state": int}  (int out of RoundState)
var _rounds: Array = []

var _used_ids: Array = []
var _entries: Dictionary = {}
var _folder: String = ""

# True between begin() and session_ended() — deliberately NOT "encoding right now"
# (§1.5). Were it to drop when the loop ends, round_state() would answer READY for a
# FAILED round and the GameLoop would walk into a round without a video.
var _run_active: bool = false

# +1 on EVERY begin / session_ended. A bake loop remembers its own value at start;
# `_gen != my_gen` is its ONLY abort condition and at the same time the should_cancel it
# hands to prepare_entry_media, so an abort also kills a running ffmpeg through the
# gate's effective_cancel.
var _gen: int = 0

var _done: int = 0
var _total: int = 0
var _current_name: String = ""

# Test seams (§1.8). An invalid Callable means "use the real path".
var _prepare_fn: Callable = Callable()
var _preempt_count_fn: Callable = Callable()
var _link_fn: Callable = Callable()
var _exists_fn: Callable = Callable()


func _ready() -> void:
	# Marker sweep at app start: every run folder whose bake never finished is discarded
	# together with its scoreboard and its resume save. That implements "no resuming a
	# half-baked run" without touching a single line of the resume code.
	RandomizerRun.sweep_unfinished()


# ── Public API ───────────────────────────────────────────────────────────────


## Takes over the just-materialized run and starts baking whatever is still missing.
## Returns SYNCHRONOUSLY — the screen calls this immediately before
## Transition.change_scene and may not be held up by it; the loop starts deferred.
func begin(run: Dictionary, entries: Dictionary, folder: String) -> void:
	_gen += 1  # supersedes a loop that might still be running from a previous run
	_rounds = []
	_run_active = false
	_done = 0
	_total = 0
	_current_name = ""
	_used_ids = (run.get("used_ids", []) as Array).duplicate()
	_entries = entries
	_folder = folder
	var rels_table: Array = round_rels(run.get("journey", {}) as Dictionary)
	if rels_table.size() != _used_ids.size():
		# The forward chain and used_ids disagree — this run is not what it claims to
		# be, and guessing an index mapping would be worse than not baking. The
		# unfinished marker deliberately stays put: the sweep is the safe outcome.
		push_warning(
			(
				"RandomizerBaker: %d round nodes for %d used ids — not baking."
				% [rels_table.size(), _used_ids.size()]
			)
		)
		return
	if _used_ids.is_empty():
		# A run without a single video round is complete the moment it is materialized.
		RandomizerRun.finish(folder)
		return
	var pending: int = 0
	for i: int in _used_ids.size():
		var rels: PackedStringArray = rels_table[i]
		# READY means: every file of this round already lies in the RUN FOLDER —
		# materialize_partial linked everything the pool had, so the folder is the whole
		# truth (§2.3). A round with no rels at all is trivially ready.
		var ready: bool = true
		for rel: String in rels:
			if not _exists(_folder + "/" + rel):
				ready = false
				break
		if not ready:
			pending += 1
		# No round_ready here: nobody waits on a round that was ready before the session
		# even started (§11.4).
		_rounds.append({"rels": rels, "state": RoundState.READY if ready else RoundState.PENDING})
	if pending == 0:
		# The start buffer covered the whole run (a short run, or every part a cache
		# hit). Nothing to bake, so the baker stays out of the GameLoop's way entirely.
		RandomizerRun.finish(folder)
		return
	_total = _rounds.size()
	_run_active = true
	# Deferred so begin() is guaranteed to return before anything awaits.
	_bake_loop.call_deferred(_gen)


## State of the 0-based video round `index` (§2). Without an active run ALWAYS READY.
func round_state(index: int) -> int:
	if not _run_active:
		return RoundState.READY  # normal journeys, keep runs, after session_ended
	if index < 0 or index >= _rounds.size():
		return RoundState.READY  # defensive: an unknown round never blocks
	return int((_rounds[index] as Dictionary)["state"])


## The session is over (EndScreen or abort). Aborts the loop; the run folder stays where
## it is, marker included, and is cleared by the next Generate or the next app start.
## Idempotent — the GameLoop guards with active() on top.
func session_ended() -> void:
	if not _run_active:
		return
	_gen += 1  # the running loop goes obsolete at its next check
	_run_active = false
	_rounds = []
	_used_ids = []
	_entries = {}
	_folder = ""
	_done = 0
	_total = 0
	_current_name = ""


## True between begin() and session_ended(), even when nothing is encoding any more.
func active() -> bool:
	return _run_active


## {done, total, name} for the GameLoop's wait line.
func progress() -> Dictionary:
	return {"done": _done, "total": _total, "name": _current_name}


## Round n → its content rels, in play order. Walks the single forward chain from Start —
## the very traversal GameState.Advance drives at runtime — so the table stays right even
## if a serialization round-trip or a later generator change shuffles the Nodes array.
## Only `type == "round"` gets an index; a shop carries neither rel fields nor an index
## (§2.1). Returns Array[PackedStringArray], one rel list per video round.
## Public ONLY so the test contract can rebuild the table; no production caller outside
## this file.
static func round_rels(journey: Dictionary) -> Array:
	var by_id: Dictionary = {}
	for raw: Variant in journey.get("Nodes", []) as Array:
		var node: Dictionary = raw as Dictionary
		by_id[str(node.get("id", ""))] = node
	var out: Array = []
	var id: String = str(journey.get("Start", ""))
	# Capped defensively against a cycle. The generator wires a plain chain and never
	# produces one, but an endless loop here would hang the Play button.
	var steps: int = by_id.size() + 1
	while steps > 0 and by_id.has(id):
		steps -= 1
		var node: Dictionary = by_id[id] as Dictionary
		if str(node.get("type", "")) == "round":
			out.append(_node_rels(node.get("data", {}) as Dictionary))
		var edges: Array = node.get("out", []) as Array
		if edges.is_empty():
			break
		id = str((edges[0] as Dictionary).get("to", ""))
	return out


# Without these seams the suite would run against the user's real registry, spawn ffmpeg
# and write into user://.
#   prepare_fn:       func(entry: Dictionary, on_progress: Callable,
#                          should_cancel: Callable, priority: int) -> Dictionary
#                                                    replaces prepare_entry_media
#   preempt_count_fn: func() -> int                  replaces MediaPoolService.preempt_count()
#   link_fn:          func(folder: String, rel: String, store_dir: String) -> bool
#                                                    replaces RandomizerRun.link_part
#   exists_fn:        func(path: String) -> bool     replaces the run-folder existence check
# An invalid Callable (the default) means: use the real path. RandomizerRun.finish() gets
# no seam — on a folder that does not exist it is a silent no-op.
func set_test_hooks(
	prepare_fn: Callable,
	preempt_count_fn: Callable = Callable(),
	link_fn: Callable = Callable(),
	exists_fn: Callable = Callable()
) -> void:
	_prepare_fn = prepare_fn
	_preempt_count_fn = preempt_count_fn
	_link_fn = link_fn
	_exists_fn = exists_fn


# ── Bake loop ────────────────────────────────────────────────────────────────


# Bakes the pending rounds in play order. A loop that went obsolete returns WORDLESSLY:
# it touches neither the table nor the counters and emits nothing, because a younger
# begin() owns all of it by then and session_ended() cleans up synchronously itself.
func _bake_loop(my_gen: int) -> void:
	# Once, before the FIRST encode of the run: in exactly this window the GameLoop
	# opens its first video after the scene change and seeks (§5).
	if not await _wait(start_delay_s, my_gen):
		return
	var cancel: Callable = func() -> bool: return _gen != my_gen
	for i: int in _rounds.size():
		if _gen != my_gen:
			return
		var round_entry: Dictionary = _rounds[i]
		if int(round_entry["state"]) != RoundState.PENDING:
			continue  # start buffer / cache hit — no gate ticket for something already there
		var sid: String = str(_used_ids[i])
		# Part pseudo-entries do not exist in RandomizerLibrary — only the video they
		# were cut from does — which is why the index travels with the run.
		var entry: Dictionary = _entries.get(sid, {}) as Dictionary
		if entry.is_empty():
			entry = RandomizerLibrary.get_entry(sid)
		if entry.is_empty():
			_mark_failed(i)  # an id that resolves nowhere: one lost round, not a lost run
			continue
		_publish_progress(i + 1, _total, str(entry.get("name", "")))

		var attempts: int = 0  # only REAL failures are counted here
		var ok: bool = false
		while true:
			# Snapshot around the call: the counter is monotonic, so any rise between
			# here and the return belongs to this call — preemption, not a failure.
			var before: int = _preempt_count()
			var pr: Dictionary = await _prepare(entry, cancel)
			if _gen != my_gen:
				return
			if bool(pr.get("ok", false)):
				ok = true
				break
			if _preempt_count() != before:
				# A foreground job (a builder save after a session abort, say) took the
				# gate away. That is not a failed attempt: it does not count against the
				# retry budget and the part is simply redone. An endless preemption
				# keeps this loop spinning on purpose — retry_delay_s keeps it cool.
				if not await _wait(retry_delay_s, my_gen):
					return
				continue
			attempts += 1
			if attempts >= 2:  # exactly ONE retry
				break
			if not await _wait(retry_delay_s, my_gen):
				return

		if not ok:
			_mark_failed(i)
			continue

		var linked: bool = true
		for rel: String in round_entry["rels"] as PackedStringArray:
			if not _link(rel):
				linked = false
				break
		if _gen != my_gen:
			return
		if not linked:
			# The bake worked and the link did not: a disk or permission problem that a
			# second encode would not heal (§11.9). No retry.
			_mark_failed(i)
			continue

		round_entry["state"] = RoundState.READY
		round_ready.emit(i)

	# round_ready is emitted synchronously above, so a handler could have ended the session
	# and begun a NEW run before we get here. Without this check the obsolete loop would
	# finish() the YOUNGER run's folder and strip a marker that is still being earned
	# (§1.4.1: an obsolete loop touches nothing any more).
	if _gen != my_gen:
		return
	_current_name = ""
	# Marker gone — the run counts as fully baked and survives the next app start. Called
	# even when rounds failed: the marker answers "was the bake interrupted?", not "is
	# every round playable?".
	RandomizerRun.finish(_folder)


# A real failure: degrade silently. No popup, no sound, no modal — the user is playing.
# A failure shows up as nothing but a round the GameLoop skips.
func _mark_failed(index: int) -> void:
	(_rounds[index] as Dictionary)["state"] = RoundState.FAILED
	round_failed.emit(index)


# Waits `secs` and reports whether this loop is still in charge afterwards (true = still
# ours). The wait is served in WAIT_SLICE_S slices with a generation check in between, so
# a session_ended during the start delay is noticed in a quarter second instead of after
# the full five.
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


# on_progress is empty on the background path: the wait line shows only n/m, so a percent
# callback every 0.4 s would be signal noise without a receiver.
func _prepare(entry: Dictionary, cancel: Callable) -> Dictionary:
	if _prepare_fn.is_valid():
		return await _prepare_fn.call(entry, Callable(), cancel, EncodeGate.Priority.BACKGROUND)
	return await RandomizerLibrary.prepare_entry_media(
		entry, Callable(), cancel, EncodeGate.Priority.BACKGROUND
	)


# ── Internals ────────────────────────────────────────────────────────────────


# The per-node variant of RandomizerGenerator._collect_content_rels: every non-empty
# pooled rel a round node references, deduped WITHIN the round (boss image, axis and vib
# scripts can share a file with each other).
static func _node_rels(data: Dictionary) -> PackedStringArray:
	var candidates: Array = [
		str(data.get("video_path", "")),
		str(data.get("funscript_path", "")),
		str(data.get("boss_image", "")),
	]
	for ax: Variant in (data.get("axis_scripts", {}) as Dictionary).values():
		candidates.append(str(ax))
	for vb: Variant in (data.get("vib_scripts", {}) as Dictionary).values():
		candidates.append(str(vb))
	var seen: Dictionary = {}
	var out: PackedStringArray = PackedStringArray()
	for rel: String in candidates:
		if rel != "" and not seen.has(rel):
			seen[rel] = true
			out.append(rel)
	return out


# "Does this rel already lie in the run folder?" — the same check materialize does.
func _exists(path: String) -> bool:
	if _exists_fn.is_valid():
		return bool(_exists_fn.call(path))
	return FileAccess.file_exists(ProjectSettings.globalize_path(path))


func _link(rel: String) -> bool:
	if _link_fn.is_valid():
		return bool(_link_fn.call(_folder, rel, RandomizerLibrary.STORE_DIR))
	return RandomizerRun.link_part(_folder, rel, RandomizerLibrary.STORE_DIR)


func _preempt_count() -> int:
	if _preempt_count_fn.is_valid():
		return int(_preempt_count_fn.call())
	return MediaPoolService.preempt_count()


# 1-based on the round that is running RIGHT NOW, published before the call: that makes
# "Preparing next round… 3/12" read as "round 3 of 12 is up", and the last round leaves
# done == total behind.
func _publish_progress(done: int, total: int, round_name: String) -> void:
	_done = done
	_total = total
	_current_name = round_name
	progress_changed.emit(_done, _total, _current_name)
