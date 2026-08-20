extends GdUnitTestSuite

# RoundTimelineScheduler — the pure fire/expire decision logic behind a boss encounter
# (BOSS_ROUND_DESIGN Phase 1). Every test drives positions by hand and asserts on the returned
# decision record; nothing here starts an override, pushes an effect, or draws. Covers one-shot
# crossings, window reconciliation, pause, seek (both directions), the catch-up guard, loop reset,
# phases, and the defeat split.

# ── Fixtures ─────────────────────────────────────────────────────────────────


func _one_shot(id: String, at_ms: int, anchor: String = "start") -> Dictionary:
	return {"id": id, "track": "audio", "at_ms": at_ms, "anchor": anchor, "clip": "/hit.ogg"}


func _window(id: String, at_ms: int, duration_ms: int) -> Dictionary:
	return {
		"id": id,
		"track": "effect",
		"at_ms": at_ms,
		"duration_ms": duration_ms,
		"effects": [{"kind": "blackout"}],
	}


func _sched(events: Array, duration_ms: int = 60000, phases: Array = []) -> RoundTimelineScheduler:
	var timeline: Dictionary = RoundTimeline.normalize({"events": events, "phases": phases})
	return RoundTimelineScheduler.new(timeline, duration_ms)


func _ids(events: Array) -> Array:
	var out: Array = []
	for e: Dictionary in events:
		out.append(str(e["id"]))
	return out


# ── One-shot crossings ───────────────────────────────────────────────────────


func test_one_shot_fires_once_on_the_tick_that_crosses_it() -> void:
	var s: RoundTimelineScheduler = _sched([_one_shot("a", 1000)])
	assert_array(_ids(s.tick(500)["fire"])).is_empty()
	assert_array(_ids(s.tick(1000)["fire"])).is_equal(["a"])  # closed on the right: lands exactly
	assert_array(_ids(s.tick(1500)["fire"])).is_empty()  # and never again
	assert_array(_ids(s.tick(2000)["fire"])).is_empty()


func test_an_event_at_zero_fires_on_the_very_first_tick() -> void:
	# An opener sits at 0, and the first tick has no previous position to cross from.
	var s: RoundTimelineScheduler = _sched([_one_shot("opener", 0)])
	assert_array(_ids(s.tick(0)["fire"])).is_equal(["opener"])


func test_several_one_shots_crossed_in_one_tick_fire_in_time_order() -> void:
	var s: RoundTimelineScheduler = _sched([_one_shot("b", 900), _one_shot("a", 400)])
	s.tick(0)
	assert_array(_ids(s.tick(1000)["fire"])).is_equal(["a", "b"])


func test_the_first_tick_does_not_replay_everything_behind_it() -> void:
	# Resuming mid-round must not dump the whole first half into one tick: only an event sitting
	# exactly ON the starting position belongs to it, and the rest count as already passed.
	var s: RoundTimelineScheduler = _sched([_one_shot("a", 400), _one_shot("b", 900)])
	assert_array(_ids(s.tick(900)["fire"])).is_equal(["b"])  # "a" (behind) is skipped, not replayed
	assert_array(s.tick(1200)["fire"]).is_empty()


func test_pause_is_a_no_op() -> void:
	# A paused video reports the same position, so every rule must simply do nothing.
	var s: RoundTimelineScheduler = _sched([_one_shot("a", 1000), _window("w", 500, 2000)])
	s.tick(1000)
	for i: int in 5:
		var d: Dictionary = s.tick(1000)
		assert_array(d["fire"]).is_empty()
		assert_array(d["start"]).is_empty()
		assert_array(d["stop"]).is_empty()


# ── Windows ──────────────────────────────────────────────────────────────────


func test_window_starts_and_stops_at_its_edges() -> void:
	var s: RoundTimelineScheduler = _sched([_window("w", 1000, 2000)])
	assert_array(_ids(s.tick(999)["start"])).is_empty()
	assert_array(_ids(s.tick(1000)["start"])).is_equal(["w"])  # inclusive start
	assert_array(_ids(s.tick(2999)["stop"])).is_empty()  # still inside
	assert_array(_ids(s.tick(3000)["stop"])).is_equal(["w"])  # exclusive end


func test_window_reports_itself_only_once_while_it_stays_open() -> void:
	var s: RoundTimelineScheduler = _sched([_window("w", 0, 5000)])
	assert_array(_ids(s.tick(100)["start"])).is_equal(["w"])
	assert_array(s.tick(200)["start"]).is_empty()  # already applied — reconciliation is idempotent
	assert_array(_ids(s.active_events())).is_equal(["w"])


func test_overlapping_windows_are_independent() -> void:
	var s: RoundTimelineScheduler = _sched([_window("a", 0, 2000), _window("b", 1000, 2000)])
	assert_array(_ids(s.tick(500)["start"])).is_equal(["a"])
	assert_array(_ids(s.tick(1500)["start"])).is_equal(["b"])
	assert_array(_ids(s.tick(2500)["stop"])).is_equal(["a"])
	assert_array(_ids(s.tick(3500)["stop"])).is_equal(["b"])


# ── Seeking ──────────────────────────────────────────────────────────────────


func test_backward_seek_re_arms_one_shots_ahead_of_the_new_position() -> void:
	var s: RoundTimelineScheduler = _sched([_one_shot("a", 1000)])
	s.tick(0)
	assert_array(_ids(s.tick(1200)["fire"])).is_equal(["a"])
	s.tick(400)  # a jump backwards is handled as a seek
	assert_array(_ids(s.tick(1000)["fire"])).is_equal(["a"])  # re-armed, so it plays again


func test_forward_seek_skips_the_one_shots_it_flew_past() -> void:
	# The device re-anchor path: jumping ahead must not dump every missed cue into one tick.
	var s: RoundTimelineScheduler = _sched([_one_shot("a", 1000), _one_shot("b", 2000)])
	var d: Dictionary = s.seek(5000)
	assert_array(d["fire"]).is_empty()
	assert_array(s.tick(5100)["fire"]).is_empty()  # and they stay skipped


func test_a_large_forward_jump_is_treated_as_a_seek() -> void:
	# The safety net for a stall or an unannounced re-anchor: skip, never burst.
	var s: RoundTimelineScheduler = _sched([_one_shot("a", 1000), _one_shot("b", 2000)])
	s.tick(0)
	assert_array(s.tick(RoundTimelineScheduler.MAX_CATCHUP_MS + 3000)["fire"]).is_empty()


func test_an_ordinary_advance_below_the_guard_still_fires() -> void:
	var s: RoundTimelineScheduler = _sched([_one_shot("a", 1000)])
	s.tick(0)
	assert_array(_ids(s.tick(RoundTimelineScheduler.MAX_CATCHUP_MS - 1)["fire"])).is_equal(["a"])


func test_seek_reconciles_windows_to_the_new_position() -> void:
	var s: RoundTimelineScheduler = _sched([_window("w", 10000, 5000)])
	assert_array(_ids(s.seek(11000)["start"])).is_equal(["w"])  # seeking INTO a window switches it on
	assert_array(_ids(s.seek(200)["stop"])).is_equal(["w"])  # and out of it switches it off


# ── Loop replay + finish ─────────────────────────────────────────────────────


func test_reset_rearms_everything_and_stops_open_windows() -> void:
	var s: RoundTimelineScheduler = _sched([_one_shot("a", 1000), _window("w", 0, 5000)])
	s.tick(0)
	s.tick(1200)
	assert_array(_ids(s.reset()["stop"])).is_equal(["w"])  # the caller switched it on, so hand it back
	# A loop replay plays the round again from the top: the window re-applies…
	assert_array(_ids(s.tick(0)["start"])).is_equal(["w"])
	assert_array(_ids(s.tick(1200)["fire"])).is_equal(["a"])  # …and the one-shot is re-armed


func test_finish_returns_open_windows_for_teardown() -> void:
	var s: RoundTimelineScheduler = _sched([_window("w", 0, 60000)])
	s.tick(1000)
	assert_array(_ids(s.finish()["stop"])).is_equal(["w"])
	assert_array(s.active_events()).is_empty()
	assert_array(s.finish()["stop"]).is_empty()  # idempotent — nothing left to tear down


# ── Phases ───────────────────────────────────────────────────────────────────


func _phase(id: String, at_ms: int) -> Dictionary:
	return {"id": id, "name": id.to_upper(), "at_ms": at_ms}


func test_phase_changes_are_reported_once_on_entry() -> void:
	var s: RoundTimelineScheduler = _sched([], 60000, [_phase("p1", 0), _phase("p2", 10000)])
	var first: Dictionary = s.tick(0)
	assert_bool(bool(first["phase_changed"])).is_true()
	assert_str(str((first["phase"] as Dictionary)["id"])).is_equal("p1")

	assert_bool(bool(s.tick(5000)["phase_changed"])).is_false()  # still in p1

	var second: Dictionary = s.tick(10000)
	assert_bool(bool(second["phase_changed"])).is_true()
	assert_str(str((second["phase"] as Dictionary)["id"])).is_equal("p2")
	assert_str(str(s.current_phase()["id"])).is_equal("p2")


func test_seeking_backwards_returns_to_the_earlier_phase() -> void:
	var s: RoundTimelineScheduler = _sched([], 60000, [_phase("p1", 0), _phase("p2", 10000)])
	s.tick(12000)
	var back: Dictionary = s.seek(2000)
	assert_bool(bool(back["phase_changed"])).is_true()
	assert_str(str((back["phase"] as Dictionary)["id"])).is_equal("p1")


func test_position_before_the_first_phase_is_no_phase() -> void:
	var s: RoundTimelineScheduler = _sched([], 60000, [_phase("p2", 10000)])
	assert_bool(bool(s.tick(500)["phase_changed"])).is_false()
	assert_bool(s.current_phase().is_empty()).is_true()


# ── End anchoring + the defeat split ─────────────────────────────────────────


func test_end_anchored_events_resolve_against_the_video_length() -> void:
	# "5 s before the end" of a 60 s round is 55 s in. Reached via an announced seek, then ordinary
	# ticks — a raw jump of 50 s would (correctly) trip the catch-up guard.
	var s: RoundTimelineScheduler = _sched([_one_shot("outro", 5000, "end")], 60000)
	s.seek(54000)
	assert_array(s.tick(54500)["fire"]).is_empty()
	assert_array(_ids(s.tick(55000)["fire"])).is_equal(["outro"])


func test_unresolvable_end_anchors_never_fire() -> void:
	# Unknown video length: skipping is the designed degradation, not firing at a guessed time.
	var s: RoundTimelineScheduler = _sched([_one_shot("outro", 5000, "end")], 0)
	assert_bool(s.is_idle()).is_true()
	assert_array(s.tick(999999)["fire"]).is_empty()


func test_defeat_events_are_held_back_from_the_normal_pass() -> void:
	var events: Array = [
		_one_shot("victory", 5000, "end"),
		{"id": "defeat", "track": "audio", "at_ms": 0, "on": "defeat", "clip": "/lose.ogg"},
	]
	var s: RoundTimelineScheduler = _sched(events, 60000)
	# Playing all the way through never fires the defeat beat...
	assert_array(s.tick(0)["fire"]).is_empty()
	s.seek(54000)  # skip ahead to the outro the announced way
	assert_array(_ids(s.tick(55000)["fire"])).is_equal(["victory"])
	# ...it is handed out only when the bail-out path asks.
	assert_array(_ids(s.defeat_events())).is_equal(["defeat"])


func test_is_idle_on_an_empty_timeline() -> void:
	var s: RoundTimelineScheduler = _sched([])
	assert_bool(s.is_idle()).is_true()
	var d: Dictionary = s.tick(1000)
	assert_array(d["fire"]).is_empty()
	assert_array(d["start"]).is_empty()
	assert_bool(bool(d["phase_changed"])).is_false()
