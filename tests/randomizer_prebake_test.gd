extends GdUnitTestSuite

# RandomizerPrebake — the background-baking autoload (§5 of the background-baking
# contract). Every test drives the REAL schedule path (RandomizerParts.expand →
# RandomizerGenerator.generate); only the entry list, prepare_entry_media and
# MediaPoolService.preempt_count() are replaced through set_test_hooks. Without
# that seam the suite would run against the user's registry and spawn ffmpeg.
#
# Async pattern per §10 of the contract:
#   • states are awaited with assert_func (polling — immune to a transition that
#     already happened before the await),
#   • signals are collected with monitor_signals(RandomizerPrebake, false); the
#     `false` is mandatory because the emitter is an autoload — with the default
#     gdUnit would free it at test end and take every later suite down with it,
#   • no get_tree().create_timer() in the test body, every awaiting test carries
#     its own timeout, and both prebake delays are 0.0 so nothing waits real
#     seconds.

# ── Fake state (reset in before_test) ────────────────────────────────────────

# Entry ids handed to the fake prepare, in call order. A repeated first id is the
# fingerprint of a preemption retry (§5.5, case 3).
var _calls: Array = []

# 0-based index of the prepare call that answers {ok: false}; -1 = never fail.
var _fail_at: int = -1

# Whether that failure also bumps the fake preempt counter. This is the ONLY
# difference between "the foreground took the gate away" (retry) and "the encode
# really broke" (degrade to IDLE) — both arrive as {ok: false}.
var _preempt_on_fail: bool = false
var _preempts: int = 0

# Parks the bake loop INSIDE a prepare call so a test can observe BAKING and act
# on it (adopt, library_changed) while the loop is genuinely mid-flight.
var _hold_prepare: bool = false

# [[done, total], …] in emission order — the monotonic progress check needs the
# ordering, which assert_signal alone cannot give.
var _progress_log: Array = []

# Every `priority` the fake was handed, in call order. Nothing else in the suite would
# notice if the loop passed FOREGROUND: the background path would silently lose its
# preemptibility and its thread cap (§4.7, §4.8).
var _priorities: Array = []

# The `should_cancel` of the most recent call. Kept so a test can call it from the
# outside and prove it really is the generation check and not an empty Callable.
var _last_cancel: Callable = Callable()


func before_test() -> void:
	_calls = []
	_fail_at = -1
	_preempt_on_fail = false
	_preempts = 0
	_hold_prepare = false
	_progress_log = []
	_priorities = []
	_last_cancel = Callable()
	RandomizerPrebake.invalidate("test")
	RandomizerPrebake.set_test_hooks(_fake_entries, _fake_prepare, _fake_preempt_count)
	RandomizerPrebake.start_delay_s = 0.0
	RandomizerPrebake.retry_delay_s = 0.0
	monitor_signals(RandomizerPrebake, false)
	if not RandomizerPrebake.progress_changed.is_connected(_on_progress_changed):
		RandomizerPrebake.progress_changed.connect(_on_progress_changed)


func after_test() -> void:
	# Release a loop that is still parked inside the fake BEFORE the hooks go away,
	# so a straggler settles instead of spinning into the next test.
	_hold_prepare = false
	RandomizerPrebake.invalidate("test")
	await await_millis(20)
	if RandomizerPrebake.progress_changed.is_connected(_on_progress_changed):
		RandomizerPrebake.progress_changed.disconnect(_on_progress_changed)
	RandomizerPrebake.set_test_hooks(Callable(), Callable())
	RandomizerPrebake.start_delay_s = RandomizerPrebake.PREBAKE_START_DELAY_S
	RandomizerPrebake.retry_delay_s = RandomizerPrebake.PREBAKE_RETRY_DELAY_S


# ── Fixtures ─────────────────────────────────────────────────────────────────


func _entry(id: String) -> Dictionary:
	return {
		"id": id,
		"name": id,
		"video_rel": "content/m_%s.mp4" % id,
		"funscript_rel": "content/m_%s.funscript" % id,
		"axis_rel": {},
		"vib_rel": {},
		"boss_image_rel": "",
		"action_count": 100,
		"length_ms": 60000,
		"duration_ms": 60000,
		"tags": [],
		"weight": 1.0,
		"intensity": 3,
		"last_used": 0,
	}


# Three whole clips. With cut_parts off RandomizerParts.expand hands the list
# through untouched, so the generator sees exactly these three entries and
# answers {ok: true} — the fixture shape of tests/randomizer_generator_test.gd.
func _fake_entries() -> Array:
	return [_entry("c00"), _entry("c01"), _entry("c02")]


# An empty library: expand() hands nothing back and schedule() bows out before the
# generator (§5.7).
func _no_entries() -> Array:
	return []


# The randomizer screen's settings dict (_read_settings). The seed stays empty so
# schedule() resolves one itself and adopt() is willing to hand the run over.
func _settings(overrides: Dictionary = {}) -> Dictionary:
	var s: Dictionary = {
		"seed": 0,
		"length_mode": "count",
		"round_count": 3,
		"target_minutes": 20.0,
		"effect_pct": 0.0,
		"boss_finale": false,
		"intensity_order": false,
		"shop_every": 0,
		"cut_parts": false,
		"part_min_s": 60,
		"part_max_s": 180,
	}
	s.merge(overrides, true)
	return s


# Exactly the signature of RandomizerLibrary.prepare_entry_media (§6.1), priority
# included. Yields at least one frame so the loop is a real coroutine in the test,
# the same as in production. Priority and cancel are recorded BEFORE the park, so a
# test that waits for the call can read them while the loop is still inside it.
func _fake_prepare(
	entry: Dictionary, _on_progress: Callable, should_cancel: Callable, priority: int
) -> Dictionary:
	var idx: int = _calls.size()
	_calls.append(str(entry.get("id", "")))
	_priorities.append(priority)
	_last_cancel = should_cancel
	while _hold_prepare:
		await get_tree().process_frame
	await get_tree().process_frame
	if idx == _fail_at:
		if _preempt_on_fail:
			_preempts += 1
		return {"ok": false, "reason": "bake_failed"}
	return {"ok": true, "reason": ""}


func _fake_preempt_count() -> int:
	return _preempts


func _on_progress_changed(done: int, total: int, _name: String) -> void:
	_progress_log.append([done, total])


# Poll target for assert_func: "the loop has entered the n-th prepare call".
func _call_count() -> int:
	return _calls.size()


# ── Async helpers ────────────────────────────────────────────────────────────


# Polls state() instead of listening for state_changed: a transition that already
# happened before the await must still satisfy the wait.
func _await_state(want: int, ms: int = 3000) -> void:
	await assert_func(RandomizerPrebake, "state").wait_until(ms).is_equal(want)


func _await_calls(want: int, ms: int = 2000) -> void:
	await assert_func(self, "_call_count").wait_until(ms).is_equal(want)


func _await_never_ready(ms: int = 200) -> void:
	var want: Array = [RandomizerPrebake.State.READY]
	await assert_signal(RandomizerPrebake).wait_until(ms).is_not_emitted("state_changed", want)


# ── Tests ────────────────────────────────────────────────────────────────────


func test_schedule_bakes_every_entry_and_reaches_ready(timeout := 5000) -> void:
	RandomizerPrebake.schedule(_settings())
	# schedule() must return synchronously: the screen calls it immediately before
	# Transition.change_scene and may not be held up by it (§5.7).
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.BAKING)
	await _await_state(RandomizerPrebake.State.READY)
	var want: Array = [RandomizerPrebake.State.READY]
	await assert_signal(RandomizerPrebake).is_emitted("state_changed", want)
	assert_array(_calls).contains_exactly_in_any_order(["c00", "c01", "c02"])
	# Progress is 1-based on the running entry and counts monotonically to total.
	var dones: Array = []
	for p: Array in _progress_log:
		assert_int(int(p[1])).is_equal(3)
		dones.append(int(p[0]))
	assert_array(dones).is_equal([1, 2, 3])
	var pr: Dictionary = RandomizerPrebake.progress()
	assert_int(int(pr["done"])).is_equal(3)
	assert_int(int(pr["total"])).is_equal(3)


func test_adopt_hands_out_the_run_and_leaves_idle(timeout := 5000) -> void:
	var settings: Dictionary = _settings()
	RandomizerPrebake.schedule(settings)
	await _await_state(RandomizerPrebake.State.READY)
	var run: Dictionary = RandomizerPrebake.adopt(settings)
	assert_dict(run).contains_keys(
		["settings_key", "settings", "journey", "content_rels", "used_ids", "summary", "entries"]
	)
	# Drop-in for _show_preview / _prepare_and_materialize: the generate() keys ride
	# along, so the screen never has to read a hand-built dict (§5.2).
	assert_bool(bool(run["ok"])).is_true()
	assert_int((run["used_ids"] as Array).size()).is_equal(3)
	assert_dict(run["entries"]).has_size(3)
	# The seed was resolved once, at schedule time, and travels with the run.
	assert_int(int((run["settings"] as Dictionary)["seed"])).is_not_equal(0)
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.IDLE)
	assert_dict(RandomizerPrebake.held_settings()).is_empty()
	# The run changed owner — a second adopt finds nothing.
	assert_dict(RandomizerPrebake.adopt(settings)).is_empty()


func test_adopt_with_other_settings_returns_empty_and_keeps_the_run(timeout := 5000) -> void:
	RandomizerPrebake.schedule(_settings())
	await _await_state(RandomizerPrebake.State.READY)
	assert_dict(RandomizerPrebake.adopt(_settings({"round_count": 7}))).is_empty()
	# A failed adoption attempt must not kill the prepared run.
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.READY)
	assert_dict(RandomizerPrebake.held_settings()).is_not_empty()
	assert_dict(RandomizerPrebake.adopt(_settings())).is_not_empty()


func test_adopt_with_typed_seed_returns_empty(timeout := 5000) -> void:
	RandomizerPrebake.schedule(_settings())
	await _await_state(RandomizerPrebake.State.READY)
	# settings_key ignores the seed, so everything else matches — the seed guard
	# alone rejects: whoever types a seed wants exactly THAT run.
	assert_dict(RandomizerPrebake.adopt(_settings({"seed": 123456}))).is_empty()
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.READY)
	assert_dict(RandomizerPrebake.adopt(_settings())).is_not_empty()


func test_adopt_during_baking_hands_out_and_stops_the_loop(timeout := 5000) -> void:
	_hold_prepare = true
	var settings: Dictionary = _settings()
	RandomizerPrebake.schedule(settings)
	await _await_calls(1)
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.BAKING)
	# A half-done prebake still pays off: everything already pooled falls through
	# the idempotency guards of the visible prepare path.
	var run: Dictionary = RandomizerPrebake.adopt(settings)
	assert_dict(run).is_not_empty()
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.STALE)
	_hold_prepare = false
	await _await_state(RandomizerPrebake.State.IDLE, 2000)
	assert_int(_calls.size()).is_equal(1)  # the loop stopped where it stood
	await _await_never_ready()


func test_library_changed_during_baking_discards_the_run(timeout := 5000) -> void:
	_hold_prepare = true
	RandomizerPrebake.schedule(_settings())
	await _await_calls(1)
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.BAKING)
	# The run was drawn from a candidate field that no longer exists.
	RandomizerLibrary.library_changed.emit()
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.STALE)
	assert_dict(RandomizerPrebake.held_settings()).is_empty()
	_hold_prepare = false
	await _await_state(RandomizerPrebake.State.IDLE, 2000)
	assert_dict(RandomizerPrebake.adopt(_settings())).is_empty()
	await _await_never_ready()


func test_prepare_failure_degrades_silently_to_idle(timeout := 5000) -> void:
	_fail_at = 0
	_preempt_on_fail = false  # {ok: false} without a counter move = a real failure
	RandomizerPrebake.schedule(_settings())
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.BAKING)
	await _await_state(RandomizerPrebake.State.IDLE)
	assert_int(_calls.size()).is_equal(1)  # no retry, no further entry
	assert_dict(RandomizerPrebake.held_settings()).is_empty()
	assert_dict(RandomizerPrebake.adopt(_settings())).is_empty()
	await _await_never_ready()


func test_preemption_restarts_the_pass_and_still_reaches_ready(timeout := 5000) -> void:
	_fail_at = 0
	_preempt_on_fail = true  # same {ok: false}, but the counter moved → preemption
	RandomizerPrebake.schedule(_settings())
	await _await_state(RandomizerPrebake.State.READY)
	# Exactly one part is lost, then the whole list runs again from the front
	# (§5.5, case 3) — one preempted call plus three clean ones.
	assert_int(_calls.size()).is_equal(4)
	assert_str(str(_calls[0])).is_equal(str(_calls[1]))
	# The second pass counts from 1 again and runs to total: a counter that stayed put
	# across the retry would freeze the line at "1/3" all the way to READY (§5.7).
	var dones: Array = []
	for p: Array in _progress_log:
		assert_int(int(p[1])).is_equal(3)
		dones.append(int(p[0]))
	assert_array(dones).is_equal([1, 1, 2, 3])
	var pr: Dictionary = RandomizerPrebake.progress()
	assert_int(int(pr["done"])).is_equal(3)
	assert_int(int(pr["total"])).is_equal(3)


func test_prepare_is_called_with_background_priority_every_time(timeout := 5000) -> void:
	RandomizerPrebake.schedule(_settings())
	await _await_state(RandomizerPrebake.State.READY)
	assert_int(_priorities.size()).is_equal(3)
	# FOREGROUND here would look identical from the outside and quietly cost the whole
	# point of the background path: preemptibility (§4.8) and the thread cap (§4.7).
	for p: Variant in _priorities:
		assert_int(int(p)).is_equal(EncodeGate.Priority.BACKGROUND)


func test_prepare_gets_a_cancel_that_turns_true_on_invalidate(timeout := 5000) -> void:
	_hold_prepare = true
	RandomizerPrebake.schedule(_settings())
	await _await_calls(1)
	# The cancel handed down is the generation check (§5.4) — an empty Callable would
	# leave a running ffmpeg without any way to be stopped.
	assert_bool(_last_cancel.is_valid()).is_true()
	assert_bool(bool(_last_cancel.call())).is_false()
	RandomizerPrebake.invalidate("cancel probe")
	assert_bool(bool(_last_cancel.call())).is_true()
	_hold_prepare = false
	await _await_state(RandomizerPrebake.State.IDLE, 2000)


func test_schedule_during_baking_supersedes_the_running_loop(timeout := 5000) -> void:
	_hold_prepare = true
	RandomizerPrebake.schedule(_settings())
	await _await_calls(1)
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.BAKING)
	# Second order mid-flight: the implicit invalidate passes through STALE and lands on
	# BAKING again in the same call, so BAKING never lapses to the outside (§5.4, K3).
	var second: Dictionary = _settings({"round_count": 2})
	RandomizerPrebake.schedule(second)
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.BAKING)
	_hold_prepare = false
	await _await_state(RandomizerPrebake.State.READY)
	# Give a straggling first loop room to make one more call before counting.
	await await_millis(50)
	# One call from the superseded loop plus the two of the new run: the old loop stops
	# at its generation check and never enters prepare again.
	assert_int(_calls.size()).is_equal(3)
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.READY)
	# What is held is the SECOND order, not the one that was running.
	var held: Dictionary = RandomizerPrebake.held_settings()
	assert_int(int(held["round_count"])).is_equal(2)
	assert_str(RandomizerPrebake.settings_key(held)).is_equal(
		RandomizerPrebake.settings_key(second)
	)
	# The obsolete loop must never have dragged the state to IDLE underneath the new one
	# (checked before the adopt below, which legitimately ends in IDLE).
	var idle: Array = [RandomizerPrebake.State.IDLE]
	await assert_signal(RandomizerPrebake).wait_until(100).is_not_emitted("state_changed", idle)
	assert_int((RandomizerPrebake.adopt(second)["used_ids"] as Array).size()).is_equal(2)


func test_stale_settles_long_before_the_start_delay_is_over(timeout := 5000) -> void:
	# The one test that runs with a real start delay. Invalidated before the first
	# prepare, the loop is still sitting in that wait — and because the wait is served in
	# slices with a generation check between them, it settles within a quarter second
	# instead of leaving STALE observable for the whole delay with nothing running.
	RandomizerPrebake.start_delay_s = 2.0
	RandomizerPrebake.schedule(_settings())
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.BAKING)
	RandomizerPrebake.invalidate("test")
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.STALE)
	await _await_state(RandomizerPrebake.State.IDLE, 800)
	assert_array(_calls).is_empty()  # nothing was ever baked
	await _await_never_ready()


func test_schedule_with_nothing_to_draw_from_stays_idle(timeout := 5000) -> void:
	RandomizerPrebake.set_test_hooks(_no_entries, _fake_prepare, _fake_preempt_count)
	RandomizerPrebake.schedule(_settings())
	# An empty expansion is not an error: nothing held, nothing baking, and the next
	# Generate rolls normally (§5.7).
	assert_int(RandomizerPrebake.state()).is_equal(RandomizerPrebake.State.IDLE)
	assert_dict(RandomizerPrebake.held_settings()).is_empty()
	assert_dict(RandomizerPrebake.adopt(_settings())).is_empty()
	assert_array(_calls).is_empty()
	var baking: Array = [RandomizerPrebake.State.BAKING]
	await assert_signal(RandomizerPrebake).wait_until(200).is_not_emitted("state_changed", baking)


func test_settings_key_ignores_seed_and_separates_every_other_field() -> void:
	assert_str(RandomizerPrebake.settings_key(_settings({"seed": 1}))).is_equal(
		RandomizerPrebake.settings_key(_settings({"seed": 999}))
	)
	var base: Dictionary = _settings()
	var key: String = RandomizerPrebake.settings_key(base)
	for field: Variant in base.keys():
		var field_name: String = str(field)
		if field_name == "seed":
			continue
		var changed: Dictionary = base.duplicate(true)
		changed[field_name] = _mutate(base[field_name])
		assert_str(RandomizerPrebake.settings_key(changed)).is_not_equal(key)
	# Insertion order must not matter — JSON.stringify sorts the keys (§5.6).
	var reordered: Dictionary = {}
	var keys: Array = base.keys()
	keys.reverse()
	for field: Variant in keys:
		reordered[str(field)] = base[str(field)]
	assert_str(RandomizerPrebake.settings_key(reordered)).is_equal(key)


# Any change that survives a JSON round-trip, per value type.
func _mutate(v: Variant) -> Variant:
	if v is bool:
		return not bool(v)
	if v is int:
		return int(v) + 1
	if v is float:
		return float(v) + 1.0
	return str(v) + "_x"
