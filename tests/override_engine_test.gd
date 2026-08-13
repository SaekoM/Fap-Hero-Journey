extends GdUnitTestSuite

# Phase 1 of Override items (see OVERRIDE_ITEMS_DESIGN.md): the PURE engine core — OverrideBundle
# (channel payload + derived duration) and OverrideSession (the takeover lifecycle + clock + pause
# gating + the re-anchor-suppression query). No device, no UI, no video: these are the deterministic
# parts the GameLoop coordinator will drive later, so they're the safe first slice to lock down.


func _pts(pairs: Array) -> Array:
	var out: Array = []
	for p: Array in pairs:
		out.append(Vector2(p[0], p[1]))
	return out


func _bundle(duration_ms: int) -> OverrideBundle:
	return OverrideBundle.from_channels(_pts([[0, 0], [duration_ms, 100]]))


# ── OverrideBundle ───────────────────────────────────────────────────────────


# Duration spans EVERY channel, not just the main stroke — an axis or vibe that runs longer than the
# stroke extends the takeover.
func test_bundle_duration_spans_all_channels() -> void:
	var bundle := OverrideBundle.from_channels(
		_pts([[0, 0], [4000, 100]]),  # main ends at 4s
		{"R1": _pts([[0, 50], [6000, 50]])},  # axis ends at 6s (the max)
		{0: _pts([[0, 0], [2000, 100]])}  # vib ends at 2s
	)
	assert_int(bundle.duration_ms).is_equal(6000)


# A stroke-only override needs no axes/vibes and takes the main stroke's length.
func test_bundle_stroke_only() -> void:
	var bundle := OverrideBundle.from_channels(_pts([[0, 0], [3000, 100]]))
	assert_int(bundle.duration_ms).is_equal(3000)
	assert_bool(bundle.defined_axes().is_empty()).is_true()
	assert_bool(bundle.defined_vibes().is_empty()).is_true()
	assert_bool(bundle.is_empty()).is_false()


# Empty channels are dropped, so only channels that actually play get reported (and later sent).
func test_bundle_drops_empty_channels() -> void:
	var bundle := OverrideBundle.from_channels(_pts([[0, 0], [1000, 100]]), {"L1": []}, {1: []})
	assert_bool(bundle.defined_axes().is_empty()).is_true()
	assert_bool(bundle.defined_vibes().is_empty()).is_true()


func test_bundle_empty_is_empty() -> void:
	var bundle := OverrideBundle.from_channels([])
	assert_bool(bundle.is_empty()).is_true()
	assert_int(bundle.duration_ms).is_equal(0)


# ── OverrideSession ──────────────────────────────────────────────────────────


# Begin activates (re-anchor suppression on); the clock advances each tick and reports COMPLETED
# exactly once when it reaches the duration, going inactive so control returns to the round.
func test_session_runs_and_completes() -> void:
	var session := OverrideSession.new()
	session.begin(_bundle(3000), true, "item")
	assert_bool(session.is_active()).is_true()
	assert_str(session.tick(1000)).is_equal(OverrideSession.EVENT_NONE)
	assert_int(session.position_ms()).is_equal(1000)
	assert_str(session.tick(1000)).is_equal(OverrideSession.EVENT_NONE)
	assert_str(session.tick(1000)).is_equal(OverrideSession.EVENT_COMPLETED)
	assert_bool(session.is_active()).is_false()


# Position never runs past the bundle length even when the final tick overshoots.
func test_session_position_clamps() -> void:
	var session := OverrideSession.new()
	session.begin(_bundle(2500), false, "item")
	session.tick(4000)
	assert_int(session.position_ms()).is_equal(2500)


# A paused session holds its clock; ticks are ignored until it resumes (game pause pauses the
# override too).
func test_session_pause_gates_clock() -> void:
	var session := OverrideSession.new()
	session.begin(_bundle(3000), false, "item")
	session.tick(1000)
	session.set_paused(true)
	assert_str(session.tick(5000)).is_equal(OverrideSession.EVENT_NONE)
	assert_int(session.position_ms()).is_equal(1000)
	session.set_paused(false)
	assert_str(session.tick(2000)).is_equal(OverrideSession.EVENT_COMPLETED)


# Replace swaps the bundle and restarts the clock while staying active — the new request's immunity
# flag takes over and there is no hand-back to the round between the two.
func test_session_replace_restarts() -> void:
	var session := OverrideSession.new()
	session.begin(_bundle(3000), false, "item")
	session.tick(2000)
	session.replace(_bundle(1000), true, "item")
	assert_bool(session.is_active()).is_true()
	assert_int(session.position_ms()).is_equal(0)
	assert_bool(session.is_immune()).is_true()
	assert_str(session.tick(1000)).is_equal(OverrideSession.EVENT_COMPLETED)


# Cut ends the takeover immediately with no COMPLETED event; further ticks are inert.
func test_session_cut_is_immediate_and_silent() -> void:
	var session := OverrideSession.new()
	session.begin(_bundle(3000), false, "boss_attack")
	session.tick(500)
	session.cut()
	assert_bool(session.is_active()).is_false()
	assert_str(session.tick(1000)).is_equal(OverrideSession.EVENT_NONE)


# An idle session never advances or fires events.
func test_session_idle_is_inert() -> void:
	var session := OverrideSession.new()
	assert_bool(session.is_active()).is_false()
	assert_str(session.tick(1000)).is_equal(OverrideSession.EVENT_NONE)
	assert_int(session.position_ms()).is_equal(0)


# Source provenance is carried through for the future item-vs-boss_attack policy/telemetry split.
func test_session_carries_source() -> void:
	var session := OverrideSession.new()
	session.begin(_bundle(1000), false, "boss_attack")
	assert_str(session.source()).is_equal("boss_attack")
