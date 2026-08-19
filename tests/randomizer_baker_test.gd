extends GdUnitTestSuite

# RandomizerBaker — the progressive-baking autoload (§1 of the progressive-baking
# contract). Every test drives the REAL generator (RandomizerGenerator.generate) and the
# REAL round-table derivation (RandomizerBaker.round_rels); only the four seams of §1.8
# are replaced through set_test_hooks: prepare_entry_media, MediaPoolService.preempt_count,
# RandomizerRun.link_part and the run-folder existence check. Without them the suite would
# run against the user's registry, spawn ffmpeg and write into user://.
#
# FOLDER exists on disk for the length of a test, but it holds NOTHING except the empty
# .unfinished marker materialize_partial would have written: exists_fn and link_fn still
# answer every media question, so no byte of media is ever read or written. The folder is
# real for one reason — RandomizerRun.finish() has no seam (§1.8), and without a marker to
# remove, "the run was finished" would be unobservable and every finish() call site could be
# deleted without a single test noticing.
#
# Async pattern per §9 of the contract:
#   • states are awaited with assert_func (polling — immune to a transition that already
#     happened before the await), never by listening for a signal,
#   • signals are collected with monitor_signals(RandomizerBaker, false); the `false` is
#     mandatory because the emitter is an autoload — with the default gdUnit would free it
#     at test end and take every later suite down with it,
#   • no get_tree().create_timer() in the test body, every awaiting test carries its own
#     timeout, and both delays are 0.0 so nothing waits real seconds.

# The run folder handed to begin(). Created empty (marker only) in before_test, removed in
# after_test — see the note above.
const FOLDER: String = "user://test_baker_run"

# The folder of the SECOND run, for the one test that starts a new run from inside a signal
# handler. Same treatment as FOLDER.
const FOLDER_B: String = "user://test_baker_run_b"

# ── Fake state (reset in before_test) ────────────────────────────────────────

# Entry ids handed to the fake prepare, in call order. This is the whole play-order and
# retry evidence of the suite.
var _calls: Array = []

# Every `priority` the fake was handed, in call order. Nothing else here would notice if
# the loop passed FOREGROUND: the background path would silently lose its preemptibility
# and its thread cap.
var _priorities: Array = []

# The `should_cancel` of the most recent call. Kept so a test can call it from the outside
# and prove it really is the generation check and not an empty Callable.
var _last_cancel: Callable = Callable()

# id → how many more prepare calls for that id answer {ok: false}.
var _fail_ids: Dictionary = {}

# How many of the NEXT failures also bump the fake preempt counter. Generalizes the
# contract's `_preempt_on_fail` bool, because §9.1 case 3 needs one sequence that starts
# with a preemption and continues with real failures — a bool cannot express that.
var _preempt_fails: int = 0
var _preempts: int = 0

# Parks the bake loop INSIDE a prepare call so a test can act on it (session_ended, cancel
# probe) while the loop is genuinely mid-flight.
var _hold_prepare: bool = false

# Absolute path → true: what exists_fn reports as already lying in the run folder.
var _existing: Dictionary = {}

# rel → true: link_fn answers false for these (a disk/permission problem).
var _link_fail_rels: Dictionary = {}

# Rels handed to link_fn, in call order.
var _links: Array = []

# Every `store_dir` link_fn was handed, in call order. There is exactly one pool, and the
# baker reads its constant itself (§1.2) — hand link_part the wrong directory and every
# background link would silently look for its source in the void.
var _link_store_dirs: Array = []

# [[done, total], …] in emission order — the monotonic progress check needs the ordering,
# which assert_signal alone cannot give.
var _progress_log: Array = []

# [[id, done], …]: progress() as seen from INSIDE the fake prepare. Proves the emission
# happens BEFORE the call, which _progress_log alone cannot distinguish from "after".
var _progress_at_call: Array = []

# The run the round_ready handler of the takeover test begins, and its one-shot latch.
var _takeover_run: Dictionary = {}
var _takeover_fired: bool = false


func before_test() -> void:
	_calls = []
	_priorities = []
	_last_cancel = Callable()
	_fail_ids = {}
	_preempt_fails = 0
	_preempts = 0
	_hold_prepare = false
	_existing = {}
	_link_fail_rels = {}
	_links = []
	_link_store_dirs = []
	_progress_log = []
	_progress_at_call = []
	_takeover_run = {}
	_takeover_fired = false
	# The run folders as materialize_partial leaves them: the folder plus the empty unfinished
	# marker, no media. Only finish() ever touches them.
	_make_run_folder(FOLDER)
	_make_run_folder(FOLDER_B)
	RandomizerBaker.session_ended()
	RandomizerBaker.set_test_hooks(_fake_prepare, _fake_preempt_count, _fake_link, _fake_exists)
	RandomizerBaker.start_delay_s = 0.0
	RandomizerBaker.retry_delay_s = 0.0
	monitor_signals(RandomizerBaker, false)
	if not RandomizerBaker.progress_changed.is_connected(_on_progress_changed):
		RandomizerBaker.progress_changed.connect(_on_progress_changed)


func after_test() -> void:
	# Release a loop that is still parked inside the fake BEFORE the hooks go away, so a
	# straggler settles instead of spinning into the next test (§9, point 6).
	_hold_prepare = false
	RandomizerBaker.session_ended()
	await await_millis(20)
	if RandomizerBaker.progress_changed.is_connected(_on_progress_changed):
		RandomizerBaker.progress_changed.disconnect(_on_progress_changed)
	if RandomizerBaker.round_ready.is_connected(_on_round_ready_takeover):
		RandomizerBaker.round_ready.disconnect(_on_round_ready_takeover)
	RandomizerBaker.set_test_hooks(Callable(), Callable(), Callable(), Callable())
	RandomizerBaker.start_delay_s = RandomizerBaker.START_DELAY_S
	RandomizerBaker.retry_delay_s = RandomizerBaker.RETRY_DELAY_S
	JourneyData.delete_dir_recursive(FOLDER)
	JourneyData.delete_dir_recursive(FOLDER_B)


# ── Fixtures ─────────────────────────────────────────────────────────────────


# A clip that fills EVERY media field a round node can carry. RandomizerGenerator._round_data
# copies axis_rel / vib_rel / boss_image_rel into every round node regardless of round type,
# so all five rel sources of _node_rels ride along on every round; a fixture that left them
# empty would exercise two of the five and let the other three be deleted unnoticed.
# The R1 axis script doubles as the v0 vibration track on purpose: that is the WITHIN-round
# duplicate the dedupe has to collapse (§2.2 rule 4), and it can only arise between these
# fields — the generator draws without repetition, so two rounds never share a file.
func _entry(id: String) -> Dictionary:
	return {
		"id": id,
		"name": id,
		"video_rel": "content/m_%s.mp4" % id,
		"funscript_rel": "content/m_%s.funscript" % id,
		"axis_rel":
		{"L0": "content/ax_%s_L0.funscript" % id, "R1": "content/ax_%s_R1.funscript" % id},
		"vib_rel":
		{"v0": "content/ax_%s_R1.funscript" % id, "v1": "content/vb_%s_v1.funscript" % id},
		"boss_image_rel": "content/boss_%s.png" % id,
		"action_count": 100,
		"length_ms": 60000,
		"duration_ms": 60000,
		"tags": [],
		"weight": 1.0,
		"intensity": 3,
		"last_used": 0,
	}


# The six DISTINCT rels of one entry, in the order _node_rels emits them: video, funscript,
# boss image, both axis scripts, the one vib script that is not the shared axis file.
func _entry_rels(id: String) -> Array:
	return [
		"content/m_%s.mp4" % id,
		"content/m_%s.funscript" % id,
		"content/boss_%s.png" % id,
		"content/ax_%s_L0.funscript" % id,
		"content/ax_%s_R1.funscript" % id,
		"content/vb_%s_v1.funscript" % id,
	]


# n whole clips — the fixture shape of tests/randomizer_generator_test.gd. The `bkr_` prefix
# keeps the ids out of reach of the RandomizerLibrary.get_entry fallback (§1.2): a bare
# "c00" could collide with a real registry entry of the user and turn a "this id resolves
# nowhere" test into a silent pass.
func _library(n: int) -> Array:
	var out: Array = []
	for i: int in n:
		out.append(_entry("bkr_c%02d" % i))
	return out


# A real generated run: one round per clip, fixed seed, shops optional. The journey it
# carries is what round_rels() is derived from, so the suite never hand-builds a graph.
func _run(n: int, shop_every: int = 0) -> Dictionary:
	var res: Dictionary = RandomizerGenerator.generate(
		_library(n), {"seed": 7, "round_count": n, "shop_every": shop_every}
	)
	assert_bool(bool(res["ok"])).is_true()
	return res


# id → entry, the counterpart of RandomizerScreen._pending_entries (§1.2).
func _index(lib: Array) -> Dictionary:
	var out: Dictionary = {}
	for e: Dictionary in lib:
		out[str(e.get("id", ""))] = e
	return out


# begin() exactly as the screen calls it: the whole generate() result, the entry index and
# the run folder.
func _begin(run: Dictionary, n: int) -> void:
	RandomizerBaker.begin(run, _index(_library(n)), FOLDER)


# ── Seams ────────────────────────────────────────────────────────────────────


# Exactly the signature of RandomizerLibrary.prepare_entry_media, priority included. Yields
# at least one frame so the loop is a real coroutine in the test, the same as in production.
# Priority and cancel are recorded BEFORE the park, so a test that waits for the call can
# read them while the loop is still inside it.
func _fake_prepare(
	entry: Dictionary, _on_progress: Callable, should_cancel: Callable, priority: int
) -> Dictionary:
	var id: String = str(entry.get("id", ""))
	_calls.append(id)
	_priorities.append(priority)
	_last_cancel = should_cancel
	# Snapshot taken at the ONLY moment that can tell "published before the call" from
	# "published after it".
	_progress_at_call.append([id, int(RandomizerBaker.progress().get("done", -1))])
	while _hold_prepare:
		await get_tree().process_frame
	await get_tree().process_frame
	var left: int = int(_fail_ids.get(id, 0))
	if left > 0:
		_fail_ids[id] = left - 1
		if _preempt_fails > 0:
			# The counter moved: the foreground took the gate away. Same {ok: false},
			# entirely different meaning (§1.4, point 3).
			_preempt_fails -= 1
			_preempts += 1
		return {"ok": false, "reason": "bake_failed"}
	return {"ok": true, "reason": ""}


func _fake_preempt_count() -> int:
	return _preempts


# Stands in for RandomizerRun.link_part. A successful link makes the file exist in the run
# folder, so the fake stays consistent with exists_fn across two begin() calls.
func _fake_link(folder: String, rel: String, store_dir: String) -> bool:
	_links.append(rel)
	_link_store_dirs.append(store_dir)
	if _link_fail_rels.has(rel):
		return false
	_existing[folder + "/" + rel] = true
	return true


func _fake_exists(path: String) -> bool:
	return bool(_existing.get(path, false))


func _on_progress_changed(done: int, total: int, _name: String) -> void:
	_progress_log.append([done, total])


# The hostile handler: round_ready is emitted SYNCHRONOUSLY from inside the bake loop, so a
# receiver can end the session and start the next run before the loop's next statement — the
# very thing RandomizerScreen does when the user aborts and generates again.
func _on_round_ready_takeover(_idx: int) -> void:
	if _takeover_fired:
		return
	_takeover_fired = true
	_hold_prepare = true  # keeps the NEW run mid-bake so its marker must still be there
	RandomizerBaker.session_ended()
	RandomizerBaker.begin(_takeover_run, _index(_library(2)), FOLDER_B)


# ── Async helpers ────────────────────────────────────────────────────────────


# Poll target for assert_func: "the loop has entered the n-th prepare call".
func _call_count() -> int:
	return _calls.size()


func _await_calls(want: int, ms: int = 2000) -> void:
	await assert_func(self, "_call_count").wait_until(ms).is_equal(want)


# Polls round_state instead of listening for round_ready: a round that finished before the
# await must still satisfy the wait.
func _await_round(index: int, want: int, ms: int = 3000) -> void:
	await assert_func(RandomizerBaker, "round_state", [index]).wait_until(ms).is_equal(want)


func _count_calls(id: String) -> int:
	var n: int = 0
	for c: Variant in _calls:
		if str(c) == id:
			n += 1
	return n


func _flatten(rels: Array) -> Array:
	var out: Array = []
	for r: PackedStringArray in rels:
		for rel: String in r:
			out.append(rel)
	return out


func _as_array(rels: PackedStringArray) -> Array:
	var out: Array = []
	for rel: String in rels:
		out.append(rel)
	return out


func _count_links(rel: String) -> int:
	var n: int = 0
	for r: Variant in _links:
		if str(r) == rel:
			n += 1
	return n


func _make_run_folder(folder: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var marker: FileAccess = FileAccess.open(
		folder + "/" + RandomizerRun.UNFINISHED_MARKER, FileAccess.WRITE
	)
	if marker != null:
		marker.close()


# The unfinished marker materialize_partial wrote — RandomizerRun.finish() removing it is
# the only externally visible effect the baker has on the run folder.
func _marker_of(folder: String) -> bool:
	return FileAccess.file_exists(
		ProjectSettings.globalize_path(folder + "/" + RandomizerRun.UNFINISHED_MARKER)
	)


func _marker_exists() -> bool:
	return _marker_of(FOLDER)


# Polled, not checked once: finish() runs after the last round_ready, so it can still be a
# frame away when the last round already reads READY.
func _await_marker_gone(ms: int = 2000) -> void:
	await assert_func(self, "_marker_exists").wait_until(ms).is_false()


# One node of a hand-built chain, in the on-disk shape JourneyGraph.to_json emits.
func _chain_node(id: String, type: String, data: Dictionary, to: String) -> Dictionary:
	return {
		"id": id,
		"type": type,
		"data": data,
		"out": [] if to == "" else [{"to": to}],
	}


# ── Tests ────────────────────────────────────────────────────────────────────


func test_begin_bakes_every_round_in_play_order(timeout := 5000) -> void:
	var run: Dictionary = _run(4)
	var ids: Array = run["used_ids"] as Array
	var rels: Array = RandomizerBaker.round_rels(run["journey"])
	assert_int(rels.size()).is_equal(ids.size())
	# The table really carries all FIVE rel sources of _node_rels — video, funscript, boss
	# image, axis scripts, vib scripts. Without this the _links comparison below would hold
	# just as well if boss/axis/vib had been dropped from the derivation entirely.
	for i: int in ids.size():
		assert_array(_as_array(rels[i])).is_equal(_entry_rels(str(ids[i])))
	assert_bool(_marker_exists()).is_true()
	_begin(run, 4)
	await _await_round(ids.size() - 1, RandomizerBaker.RoundState.READY)
	# used_ids IS the play order (§2.1); the loop must not reorder it.
	assert_array(_calls).is_equal(ids)
	for i: int in ids.size():
		assert_int(RandomizerBaker.round_state(i)).is_equal(RandomizerBaker.RoundState.READY)
		await assert_signal(RandomizerBaker).is_emitted("round_ready", [i])
	# Every rel of every round hardlinked exactly once, in round order.
	assert_array(_links).is_equal(_flatten(rels))
	# Deduped WITHIN the round: the axis file that doubles as the vib track is linked once,
	# not twice — a second mklink on an existing target is a wasted process spawn.
	assert_int(_count_links("content/ax_%s_R1.funscript" % str(ids[0]))).is_equal(1)
	# There is exactly one pool and the baker reads its constant itself (§1.2).
	assert_int(_link_store_dirs.size()).is_equal(_links.size())
	for sd: Variant in _link_store_dirs:
		assert_str(str(sd)).is_equal(RandomizerLibrary.STORE_DIR)
	# The whole run is baked, so the marker goes: this run survives the next app start.
	await _await_marker_gone()


func test_a_failed_part_is_retried_exactly_once_then_the_round_fails(timeout := 5000) -> void:
	var run: Dictionary = _run(4)
	var ids: Array = run["used_ids"] as Array
	var bad: String = str(ids[1])
	_fail_ids[bad] = 99  # never succeeds, and the counter never moves → real failures
	_begin(run, 4)
	await _await_round(3, RandomizerBaker.RoundState.READY)
	assert_int(_count_calls(bad)).is_equal(2)  # one attempt plus exactly ONE retry
	assert_int(RandomizerBaker.round_state(1)).is_equal(RandomizerBaker.RoundState.FAILED)
	await assert_signal(RandomizerBaker).is_emitted("round_failed", [1])
	# The next round is baked as if nothing happened — a bad round costs one round, not
	# the session.
	assert_int(RandomizerBaker.round_state(2)).is_equal(RandomizerBaker.RoundState.READY)
	await assert_signal(RandomizerBaker).is_emitted("round_ready", [2])
	for rel: String in RandomizerBaker.round_rels(run["journey"])[1] as PackedStringArray:
		assert_array(_links).not_contains([rel])
	# finish() runs even with a FAILED round: the marker answers "was the bake interrupted?",
	# not "is every round playable?" (§1.9). Skipping it here would sweep the whole run away
	# at the next app start over one lost round.
	await _await_marker_gone()


func test_preemption_is_not_a_failed_attempt_and_the_part_is_repeated(timeout := 8000) -> void:
	var run: Dictionary = _run(4)
	var ids: Array = run["used_ids"] as Array
	var probe: String = str(ids[1])
	_fail_ids[probe] = 1
	_preempt_fails = 1  # that one failure moves the counter → preemption, not a failure
	_begin(run, 4)
	await _await_round(3, RandomizerBaker.RoundState.READY)
	# The part that was running when the foreground barged in is lost and simply redone.
	assert_int(_count_calls(probe)).is_equal(2)
	assert_int(RandomizerBaker.round_state(1)).is_equal(RandomizerBaker.RoundState.READY)
	await assert_signal(RandomizerBaker).wait_until(100).is_not_emitted("round_failed", [1])

	# Second half: preemption, then two REAL failures. The preemption must not have eaten
	# the retry budget — three calls, and only then FAILED.
	RandomizerBaker.session_ended()
	await await_millis(20)
	_calls = []
	_links = []
	_existing = {}
	_fail_ids = {probe: 3}
	_preempt_fails = 1
	_begin(run, 4)
	await _await_round(3, RandomizerBaker.RoundState.READY)
	assert_int(_count_calls(probe)).is_equal(3)
	assert_int(RandomizerBaker.round_state(1)).is_equal(RandomizerBaker.RoundState.FAILED)
	await assert_signal(RandomizerBaker).is_emitted("round_failed", [1])


func test_session_ended_stops_the_loop(timeout := 5000) -> void:
	var run: Dictionary = _run(4)
	_hold_prepare = true
	_begin(run, 4)
	await _await_calls(1)
	RandomizerBaker.session_ended()
	_hold_prepare = false
	assert_bool(RandomizerBaker.active()).is_false()
	# The loop stops where it stands: its generation check is the only abort criterion,
	# and it fires the moment the parked call returns.
	await _await_calls(1)
	await await_millis(80)
	assert_int(_calls.size()).is_equal(1)
	for k: int in 5:
		assert_int(RandomizerBaker.round_state(k)).is_equal(RandomizerBaker.RoundState.READY)
	# session_ended() calls NO finish(): the run is half-baked, so the marker stays and the
	# sweep at the next app start throws the folder away (§1.10).
	assert_bool(_marker_exists()).is_true()


func test_round_state_is_ready_without_an_active_run() -> void:
	# Normal journeys and keep runs never call begin(); the GameLoop must not be able to
	# tell the difference (§2.4).
	assert_bool(RandomizerBaker.active()).is_false()
	for k: int in [-1, 0, 1, 99]:
		assert_int(RandomizerBaker.round_state(k)).is_equal(RandomizerBaker.RoundState.READY)


func test_rounds_already_in_the_run_folder_are_not_baked_again(timeout := 5000) -> void:
	var run: Dictionary = _run(5)
	var ids: Array = run["used_ids"] as Array
	var rels: Array = RandomizerBaker.round_rels(run["journey"])
	# The start buffer: the screen baked the first two rounds in the foreground and
	# materialize_partial linked them, so their files already lie in the run folder.
	for i: int in 2:
		for rel: String in rels[i] as PackedStringArray:
			_existing[FOLDER + "/" + rel] = true
	_begin(run, 5)
	# READY straight out of begin(), without a single encode — no gate ticket is drawn in
	# the most latency-critical moment of the session (§11.4).
	assert_int(RandomizerBaker.round_state(0)).is_equal(RandomizerBaker.RoundState.READY)
	assert_int(RandomizerBaker.round_state(1)).is_equal(RandomizerBaker.RoundState.READY)
	await _await_round(ids.size() - 1, RandomizerBaker.RoundState.READY)
	assert_int(_calls.size()).is_equal(ids.size() - 2)
	assert_array(_calls).is_equal(ids.slice(2))
	# No signal for a round nobody is waiting on.
	await assert_signal(RandomizerBaker).wait_until(100).is_not_emitted("round_ready", [0])
	await assert_signal(RandomizerBaker).wait_until(100).is_not_emitted("round_ready", [1])
	for rel: String in _flatten(rels.slice(0, 2)):
		assert_array(_links).not_contains([rel])
	# The productive shape of the counter, which a run without a start buffer cannot show:
	# `done` is 1-based on the round RUNNING RIGHT NOW (the third — the buffer covered 1 and
	# 2), and `total` counts ALL rounds including the buffered ones. 0-based would read
	# "2/5", counting only the pending ones "1/3"; both would make the wait line lie.
	assert_array(_progress_log[0]).is_equal([3, ids.size()])
	assert_array(_progress_log).is_equal([[3, 5], [4, 5], [5, 5]])


func test_nothing_left_to_bake_leaves_the_baker_inactive(timeout := 5000) -> void:
	var run: Dictionary = _run(3)
	for rel: String in _flatten(RandomizerBaker.round_rels(run["journey"])):
		_existing[FOLDER + "/" + rel] = true
	assert_bool(_marker_exists()).is_true()
	_begin(run, 3)
	# Nothing to do: the tree behaves exactly like it does for a normal journey (§1.5).
	assert_bool(RandomizerBaker.active()).is_false()
	# Case C finishes SYNCHRONOUSLY inside begin() — there is no loop that could do it later,
	# so a run that was complete on arrival would otherwise be swept at the next app start.
	assert_bool(_marker_exists()).is_false()
	await await_millis(80)
	assert_bool(RandomizerBaker.active()).is_false()
	assert_array(_calls).is_empty()
	assert_array(_links).is_empty()


func test_shops_take_no_index_and_do_not_break_the_order(timeout := 8000) -> void:
	var run: Dictionary = _run(6, 2)
	var summary: Dictionary = run["summary"] as Dictionary
	assert_int(int(summary["shops"])).is_greater(0)  # the fixture really carries shops
	var ids: Array = run["used_ids"] as Array
	var rels: Array = RandomizerBaker.round_rels(run["journey"])
	# A shop node carries no used_ids entry and therefore no index (§2.1): one rel list per
	# VIDEO round, no more and no less.
	assert_int(rels.size()).is_equal(ids.size())
	_begin(run, 6)
	await _await_round(ids.size() - 1, RandomizerBaker.RoundState.READY)
	assert_array(_calls).is_equal(ids)
	for i: int in ids.size():
		assert_int(RandomizerBaker.round_state(i)).is_equal(RandomizerBaker.RoundState.READY)
	# One past the last round: an unknown index never blocks the GameLoop.
	assert_int(RandomizerBaker.round_state(ids.size())).is_equal(RandomizerBaker.RoundState.READY)


func test_prepare_gets_background_priority_and_the_generation_cancel(timeout := 8000) -> void:
	var run: Dictionary = _run(3)
	_begin(run, 3)
	await _await_round(2, RandomizerBaker.RoundState.READY)
	assert_int(_priorities.size()).is_equal(3)
	# FOREGROUND here would look identical from the outside and quietly cost the whole
	# point of the background path: preemptibility and the thread cap.
	for p: Variant in _priorities:
		assert_int(int(p)).is_equal(EncodeGate.Priority.BACKGROUND)

	# The cancel handed down is the generation check (§1.3) — an empty Callable would leave
	# a running ffmpeg with no way of being stopped.
	RandomizerBaker.session_ended()
	await await_millis(20)
	_calls = []
	_existing = {}
	_hold_prepare = true
	_begin(run, 3)
	await _await_calls(1)
	assert_bool(_last_cancel.is_valid()).is_true()
	assert_bool(bool(_last_cancel.call())).is_false()
	RandomizerBaker.session_ended()
	assert_bool(bool(_last_cancel.call())).is_true()
	_hold_prepare = false


func test_begin_returns_synchronously_and_reports_active(timeout := 5000) -> void:
	var run: Dictionary = _run(3)
	# Parked, so the "one call so far" observation cannot be overtaken by a loop that
	# races through three rounds between two polls.
	_hold_prepare = true
	_begin(run, 3)
	# begin() awaits nothing: the screen calls it immediately before
	# Transition.change_scene and may not be held up by it (§1.6).
	assert_bool(RandomizerBaker.active()).is_true()
	assert_array(_calls).is_empty()  # the loop only starts deferred
	await _await_calls(1)
	_hold_prepare = false
	await _await_round(2, RandomizerBaker.RoundState.READY)
	assert_bool(RandomizerBaker.active()).is_true()  # active until session_ended (§1.5)


func test_a_link_failure_marks_the_round_failed_without_a_retry(timeout := 5000) -> void:
	var run: Dictionary = _run(4)
	var ids: Array = run["used_ids"] as Array
	var rels: Array = RandomizerBaker.round_rels(run["journey"])
	_link_fail_rels[str((rels[1] as PackedStringArray)[0])] = true
	_begin(run, 4)
	await _await_round(3, RandomizerBaker.RoundState.READY)
	assert_int(RandomizerBaker.round_state(1)).is_equal(RandomizerBaker.RoundState.FAILED)
	await assert_signal(RandomizerBaker).is_emitted("round_failed", [1])
	# A disk/permission problem is not healed by a second encode (§11.9): the bake was
	# fine, so the retry budget stays reserved for real bake failures.
	assert_int(_count_calls(str(ids[1]))).is_equal(1)
	assert_int(RandomizerBaker.round_state(2)).is_equal(RandomizerBaker.RoundState.READY)
	await assert_signal(RandomizerBaker).is_emitted("round_ready", [2])


func test_progress_counts_the_rounds_monotonically(timeout := 5000) -> void:
	var run: Dictionary = _run(4)
	var total: int = (run["used_ids"] as Array).size()
	_begin(run, 4)
	await _await_round(total - 1, RandomizerBaker.RoundState.READY)
	# 1-based on the round that is running RIGHT NOW, published before the call, so the
	# wait line reads "round 3 of 4 is up" and ends on done == total.
	assert_int(_progress_log.size()).is_equal(total)
	var dones: Array = []
	for p: Array in _progress_log:
		assert_int(int(p[1])).is_equal(total)
		dones.append(int(p[0]))
	assert_array(dones).is_equal([1, 2, 3, 4])
	var pr: Dictionary = RandomizerBaker.progress()
	assert_int(int(pr["done"])).is_equal(total)
	assert_int(int(pr["total"])).is_equal(total)
	# Emitted BEFORE the call, not after: read from inside prepare for round i, progress()
	# must already say i + 1. Published afterwards the wait line would trail a whole round
	# behind and name the clip that just finished instead of the one being waited for.
	var ids: Array = run["used_ids"] as Array
	assert_int(_progress_at_call.size()).is_equal(total)
	for k: int in total:
		var seen: Array = _progress_at_call[k]
		assert_str(str(seen[0])).is_equal(str(ids[k]))
		assert_int(int(seen[1])).is_equal(k + 1)


func test_round_rels_follows_the_chain_not_the_nodes_array_order() -> void:
	# The Nodes array is deliberately scrambled against the Start → out[0].to chain, with a
	# shop sitting between two rounds. Array order would yield [b, a, c]; only walking the
	# chain — the very traversal GameState.Advance drives — yields play order (§2.2).
	var a: Dictionary = {
		"video_path": "content/a.mp4",
		"funscript_path": "content/a.funscript",
		"boss_image": "content/a.png",
		# The boss image doubles as the axis script here: one rel reached through two
		# different fields, which the WITHIN-round dedupe has to collapse.
		"axis_scripts": {"L0": "content/a.png", "R1": "content/a_r1.funscript"},
		"vib_scripts": {"v0": ""},
	}
	var b: Dictionary = {"video_path": "content/b.mp4", "funscript_path": ""}
	var c: Dictionary = {"video_path": "content/c.mp4", "funscript_path": "content/c.funscript"}
	var journey: Dictionary = {
		"Start": "n_a",
		"Nodes":
		[
			_chain_node("n_c", "round", c, ""),
			_chain_node("n_a", "round", a, "n_shop"),
			_chain_node("n_shop", "shop", {"title": "Shop"}, "n_b"),
			_chain_node("n_b", "round", b, "n_c"),
		],
	}
	var rels: Array = RandomizerBaker.round_rels(journey)
	# The shop contributes no entry at all: it carries no index (§2.1).
	assert_int(rels.size()).is_equal(3)
	assert_array(_as_array(rels[0])).is_equal(
		["content/a.mp4", "content/a.funscript", "content/a.png", "content/a_r1.funscript"]
	)
	assert_array(_as_array(rels[1])).is_equal(["content/b.mp4"])  # empty fields dropped
	assert_array(_as_array(rels[2])).is_equal(["content/c.mp4", "content/c.funscript"])


func test_round_rels_terminates_on_a_cycle() -> void:
	# The generator wires a plain chain, but an endless walk here would hang the Play button
	# forever. The cap is by_id.size() + 1 steps, so two mutually linked rounds yield three
	# entries and — the point of the test — the call RETURNS.
	var journey: Dictionary = {
		"Start": "n_a",
		"Nodes":
		[
			_chain_node("n_a", "round", {"video_path": "content/a.mp4"}, "n_b"),
			_chain_node("n_b", "round", {"video_path": "content/b.mp4"}, "n_a"),
		],
	}
	var rels: Array = RandomizerBaker.round_rels(journey)
	assert_int(rels.size()).is_equal(3)


func test_round_rels_on_a_missing_start_is_empty() -> void:
	# An empty or dangling Start must produce an empty table, not a crash: begin() compares
	# its size against used_ids and takes the safe case-A exit from there (§1.6).
	assert_array(RandomizerBaker.round_rels({})).is_empty()
	assert_array(RandomizerBaker.round_rels({"Start": "", "Nodes": []})).is_empty()
	var dangling: Dictionary = {
		"Start": "n_missing",
		"Nodes": [_chain_node("n_a", "round", {"video_path": "content/a.mp4"}, "")],
	}
	assert_array(RandomizerBaker.round_rels(dangling)).is_empty()


func test_a_used_id_count_that_disagrees_with_the_chain_bakes_nothing(timeout := 5000) -> void:
	var run: Dictionary = _run(3)
	var broken: Dictionary = run.duplicate(true)
	var ids: Array = (broken["used_ids"] as Array).duplicate()
	ids.append("bkr_ghost")  # one used id more than the chain has round nodes
	broken["used_ids"] = ids
	assert_bool(_marker_exists()).is_true()
	# Case A (§1.6): the chain and used_ids disagree, so no index mapping can be trusted.
	# The baker refuses the whole run rather than guessing — and pushes a warning.
	RandomizerBaker.begin(broken, _index(_library(3)), FOLDER)
	assert_bool(RandomizerBaker.active()).is_false()
	await await_millis(80)
	assert_bool(RandomizerBaker.active()).is_false()
	assert_array(_calls).is_empty()
	assert_array(_links).is_empty()
	# No finish() on a suspicious run: the marker STAYS so the sweep discards the folder at
	# the next app start. Finishing here would preserve a run nobody can vouch for.
	assert_bool(_marker_exists()).is_true()
	# And with no active run every index answers READY, so the GameLoop is never blocked.
	for k: int in 5:
		assert_int(RandomizerBaker.round_state(k)).is_equal(RandomizerBaker.RoundState.READY)


func test_a_used_id_without_an_entry_fails_only_that_round(timeout := 5000) -> void:
	var run: Dictionary = _run(4)
	var ids: Array = run["used_ids"] as Array
	var idx: Dictionary = _index(_library(4))
	idx.erase(str(ids[1]))  # neither in the run index nor (bkr_ prefix) in the registry
	RandomizerBaker.begin(run, idx, FOLDER)
	await _await_round(3, RandomizerBaker.RoundState.READY)
	# An id that resolves nowhere costs ONE round, not the run: no prepare is attempted at
	# all (an empty entry handed to prepare_entry_media would encode nothing and "succeed"),
	# and the loop walks straight on.
	assert_int(RandomizerBaker.round_state(1)).is_equal(RandomizerBaker.RoundState.FAILED)
	await assert_signal(RandomizerBaker).is_emitted("round_failed", [1])
	assert_int(_count_calls(str(ids[1]))).is_equal(0)
	var expected: Array = ids.duplicate()
	expected.remove_at(1)
	assert_array(_calls).is_equal(expected)
	assert_int(RandomizerBaker.round_state(2)).is_equal(RandomizerBaker.RoundState.READY)
	await assert_signal(RandomizerBaker).is_emitted("round_ready", [2])
	await _await_marker_gone()


func test_a_second_begin_without_session_ended_supersedes_the_old_loop(timeout := 8000) -> void:
	var run_a: Dictionary = _run(5)
	var run_b: Dictionary = _run(3)
	var ids_a: Array = run_a["used_ids"] as Array
	var ids_b: Array = run_b["used_ids"] as Array
	_hold_prepare = true
	_begin(run_a, 5)
	await _await_calls(1)
	# No session_ended in between — begin() alone bumps the generation and must supersede the
	# running loop (§1.6 step 1). Two loops baking into one folder would interleave their
	# encodes and let the older one write into the younger run's table.
	_begin(run_b, 3)
	_hold_prepare = false
	await _await_round(ids_b.size() - 1, RandomizerBaker.RoundState.READY)
	await await_millis(120)
	# The old loop's single parked call is all it ever makes; everything after belongs to the
	# new run, in its own play order.
	var expected: Array = [str(ids_a[0])]
	expected.append_array(ids_b)
	assert_array(_calls).is_equal(expected)
	assert_bool(RandomizerBaker.active()).is_true()


func test_a_negative_index_never_reaches_the_table(timeout := 5000) -> void:
	var run: Dictionary = _run(3)
	_hold_prepare = true  # every round stays PENDING while we ask
	_begin(run, 3)
	assert_bool(RandomizerBaker.active()).is_true()
	assert_int(RandomizerBaker.round_state(0)).is_equal(RandomizerBaker.RoundState.PENDING)
	# GDScript indexes arrays from the back on a negative index: without the `index < 0`
	# guard round_state(-1) would answer with the LAST round's state — PENDING here — and
	# the GameLoop would wait forever on a round that does not exist (§2.4).
	assert_int(RandomizerBaker.round_state(-1)).is_equal(RandomizerBaker.RoundState.READY)
	assert_int(RandomizerBaker.round_state(-3)).is_equal(RandomizerBaker.RoundState.READY)
	assert_int(RandomizerBaker.round_state(-99)).is_equal(RandomizerBaker.RoundState.READY)
	_hold_prepare = false


func test_the_start_delay_is_paid_once_for_the_whole_run(timeout := 8000) -> void:
	var run: Dictionary = _run(3)
	RandomizerBaker.start_delay_s = 0.4  # reset to START_DELAY_S in after_test
	var t0: int = Time.get_ticks_msec()
	_begin(run, 3)
	await _await_round(2, RandomizerBaker.RoundState.READY, 5000)
	var elapsed: int = Time.get_ticks_msec() - t0
	# The delay protects exactly ONE window: the first video the GameLoop opens and seeks
	# after the scene change (§5). Paid per round instead of once, three rounds would cost
	# ~1200 ms here and every later round would idle for nothing.
	assert_int(elapsed).is_less(800)


func test_an_obsolete_loop_does_not_finish_the_new_runs_folder(timeout := 8000) -> void:
	# One round, so the loop falls out of its for-loop straight into the closing block after
	# emitting round_ready — the only window in which the obsolete loop can still do damage.
	var run: Dictionary = _run(1)
	_takeover_run = _run(2)
	RandomizerBaker.round_ready.connect(_on_round_ready_takeover)
	_begin(run, 1)
	# The handler fires inside round_ready.emit(), ends the session and begins the NEXT run on
	# FOLDER_B. Everything the old loop does after that runs on a run it no longer owns:
	# without the generation check in front of the closing block it would strip the unfinished
	# marker of a run that is still baking, and the sweep would keep a half-baked folder alive.
	await _await_calls(2, 3000)
	assert_bool(_takeover_fired).is_true()
	assert_bool(RandomizerBaker.active()).is_true()
	assert_bool(_marker_of(FOLDER_B)).is_true()
	await await_millis(60)
	assert_bool(_marker_of(FOLDER_B)).is_true()
	_hold_prepare = false
	RandomizerBaker.round_ready.disconnect(_on_round_ready_takeover)
