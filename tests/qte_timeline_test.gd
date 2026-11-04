extends GdUnitTestSuite

# Quick-Time Event on the boss timeline: how an attack's dodge is stored and placed, and that its verdict is in
# before the attack decides whether to land.

const VIDEO_MS: int = 60000
const GAME_ID: String = "qtd"
# One prompt: 1200 ms lead plus half of a 600 ms window.
const ONE_PROMPT_MS: int = 1500


func _library(prompts: int = 1, pause_video: bool = false) -> Array:
	return [
		(
			MiniGameLibrary
			. normalize_definition(
				{
					"id": GAME_ID,
					"kind": QuickTimeEventGame.KIND,
					"knobs": {"prompts": prompts, "pause_video": pause_video},
				}
			)
		)
	]


func _attack(at_ms: int, anchor: String = RoundTimeline.ANCHOR_START) -> Dictionary:
	return (
		RoundTimeline
		. normalize_event(
			{
				"id": "atk",
				"track": RoundTimeline.TRACK_ATTACK,
				"at_ms": at_ms,
				"anchor": anchor,
				"scripts": {"main": "/a.funscript"},
				"dodge": {"game": GAME_ID, "pass_score": 70},
			}
		)
	)


func _standalone(at_ms: int, duration_ms: int, game: String = GAME_ID) -> Dictionary:
	return (
		RoundTimeline
		. normalize_event(
			{
				"id": "solo",
				"track": RoundTimeline.TRACK_QTE,
				"at_ms": at_ms,
				"duration_ms": duration_ms,
				"game": game,
			}
		)
	)


func _dodges(attack: Dictionary, library: Array = _library()) -> Array:
	return RoundTimeline.attack_dodge_events({"events": [attack]}, library, VIDEO_MS)


func _codes(issues: Array) -> Array:
	return issues.map(func(issue: Dictionary) -> String: return str(issue["code"]))


# ── Format ───────────────────────────────────────────────────────────────────


func test_an_attacks_dodge_survives_normalizing() -> void:
	var dodge: Dictionary = _attack(5000)["dodge"]
	assert_str(str(dodge["game"])).is_equal(GAME_ID)
	assert_int(int(dodge["pass_score"])).is_equal(70)


func test_the_pass_score_defaults_and_is_clamped() -> void:
	var normalized: Dictionary = RoundTimeline.normalize_event(
		{"track": RoundTimeline.TRACK_ATTACK, "dodge": {"game": GAME_ID}}
	)
	assert_int(int(normalized["dodge"]["pass_score"])).is_equal(50)
	var too_high: Dictionary = RoundTimeline.normalize_event(
		{"track": RoundTimeline.TRACK_ATTACK, "dodge": {"game": GAME_ID, "pass_score": 900}}
	)
	assert_int(int(too_high["dodge"]["pass_score"])).is_equal(100)


func test_an_attack_with_no_game_stores_no_dodge() -> void:
	var normalized: Dictionary = RoundTimeline.normalize_event(
		{"track": RoundTimeline.TRACK_ATTACK, "dodge": {"game": ""}}
	)
	assert_bool(normalized.has("dodge")).is_false()


func test_a_standalone_qte_keeps_its_game() -> void:
	assert_str(str(_standalone(0, 3000)["game"])).is_equal(GAME_ID)


# ── Placement ────────────────────────────────────────────────────────────────


func test_a_dodge_ends_exactly_when_its_attack_is_due() -> void:
	var dodge: Dictionary = _dodges(_attack(5000))[0]
	assert_int(int(dodge["at_ms"])).is_equal(5000 - ONE_PROMPT_MS)
	assert_int(int(dodge["duration_ms"])).is_equal(ONE_PROMPT_MS)
	assert_str(str(dodge["attack_id"])).is_equal("atk")
	assert_int(int(dodge["pass_score"])).is_equal(70)


func test_a_dodge_follows_an_attack_anchored_to_the_end() -> void:
	var dodge: Dictionary = _dodges(_attack(10000, RoundTimeline.ANCHOR_END))[0]
	assert_int(int(dodge["at_ms"])).is_equal(50000 - ONE_PROMPT_MS)


func test_more_prompts_start_earlier() -> void:
	var dodge: Dictionary = _dodges(_attack(10000), _library(3))[0]
	assert_int(int(dodge["duration_ms"])).is_equal(ONE_PROMPT_MS * 3)


# It takes no time on the clock: the round starts it as the attack comes due.
func test_a_dodge_that_pauses_the_video_gets_no_event_of_its_own() -> void:
	assert_array(_dodges(_attack(5000), _library(1, true))).is_empty()


func test_an_early_attack_gets_a_shorter_dodge() -> void:
	var dodge: Dictionary = _dodges(_attack(2000), _library(3))[0]
	assert_int(int(dodge["at_ms"])).is_equal(0)
	assert_int(int(dodge["duration_ms"])).is_equal(2000)


func test_an_attack_too_early_for_one_prompt_gets_no_dodge() -> void:
	assert_array(_dodges(_attack(ONE_PROMPT_MS - 1))).is_empty()


func test_a_game_no_longer_in_the_library_gets_no_dodge() -> void:
	assert_array(_dodges(_attack(5000), [])).is_empty()


# ── Timing ───────────────────────────────────────────────────────────────────


# The whole design rests on this: a verdict reached as the window stops is in before the attack fires.
func test_the_dodge_stops_in_the_same_tick_its_attack_fires() -> void:
	var timeline: Dictionary = RoundTimeline.with_attack_dodges(
		{"events": [_attack(5000)]}, _library(), VIDEO_MS
	)
	var scheduler: RoundTimelineScheduler = RoundTimelineScheduler.new(timeline, VIDEO_MS)
	scheduler.tick(0)
	var opening: Dictionary = scheduler.tick(5000 - ONE_PROMPT_MS)
	assert_int((opening["start"] as Array).size()).is_equal(1)
	var closing: Dictionary = scheduler.tick(5000)
	assert_int((closing["stop"] as Array).size()).is_equal(1)
	assert_int((closing["fire"] as Array).size()).is_equal(1)


# A failed condition must drop both together, not show a dodge for an attack that never comes.
func test_a_dodge_and_its_attack_share_one_verdict_on_the_condition() -> void:
	var attack: Dictionary = _attack(5000)
	attack["condition"] = RoundTimeline.normalize_condition(
		[{"signal": RoundTimeline.SIGNAL_SCORE, "op": RoundTimeline.OP_GTE, "value": 100}]
	)
	var timeline: Dictionary = RoundTimeline.with_attack_dodges(
		{"events": [attack]}, _library(), VIDEO_MS
	)
	var scheduler: RoundTimelineScheduler = RoundTimelineScheduler.new(timeline, VIDEO_MS)
	var low: Dictionary = RoundTimeline.empty_state()
	low[RoundTimeline.SIGNAL_SCORE] = 0
	var high: Dictionary = RoundTimeline.empty_state()
	high[RoundTimeline.SIGNAL_SCORE] = 500
	scheduler.tick(0, low)
	assert_array(scheduler.tick(5000 - ONE_PROMPT_MS, low)["start"]).is_empty()
	# The player has since earned the score, but the verdict was reached when the dodge came due.
	assert_array(scheduler.tick(5000, high)["fire"]).is_empty()


# ── Authoring problems ───────────────────────────────────────────────────────


func test_a_standalone_qte_with_no_game_is_reported() -> void:
	var issues: Array = RoundTimeline.qte_issues(
		{"events": [_standalone(0, 3000, "")]}, _library(), VIDEO_MS
	)
	assert_array(_codes(issues)).contains([RoundTimeline.ISSUE_QTE_NO_GAME])


func test_an_attack_whose_game_was_deleted_is_reported() -> void:
	var issues: Array = RoundTimeline.qte_issues({"events": [_attack(5000)]}, [], VIDEO_MS)
	assert_array(_codes(issues)).contains([RoundTimeline.ISSUE_QTE_NO_GAME])


func test_a_block_too_short_for_its_prompts_is_reported() -> void:
	var issues: Array = RoundTimeline.qte_issues(
		{"events": [_standalone(0, ONE_PROMPT_MS)]}, _library(3), VIDEO_MS
	)
	assert_array(_codes(issues)).contains([RoundTimeline.ISSUE_QTE_TOO_SHORT])


func test_an_attack_too_early_to_dodge_is_reported() -> void:
	var issues: Array = RoundTimeline.qte_issues(
		{"events": [_attack(ONE_PROMPT_MS - 1)]}, _library(), VIDEO_MS
	)
	assert_array(_codes(issues)).contains([RoundTimeline.ISSUE_QTE_TOO_SHORT])


func test_overlapping_qtes_are_reported() -> void:
	var issues: Array = RoundTimeline.qte_issues(
		{"events": [_standalone(4000, 3000), _attack(5000)]}, _library(), VIDEO_MS
	)
	assert_array(_codes(issues)).contains([RoundTimeline.ISSUE_QTE_OVERLAP])


func test_a_sound_encounter_has_no_qte_issues() -> void:
	var issues: Array = RoundTimeline.qte_issues(
		{"events": [_standalone(20000, 3000), _attack(5000)]}, _library(), VIDEO_MS
	)
	assert_array(issues).is_empty()


# ── Who uses a game ──────────────────────────────────────────────────────────


func test_a_nodes_qtes_are_found_on_the_round_and_its_pool() -> void:
	var data: Dictionary = {
		"timeline": {"events": [_attack(5000)]},
		"pool_entries": [{"timeline": {"events": [_standalone(0, 3000)]}}],
	}
	assert_array(RoundTimeline.qte_games_on_node(data)).is_equal([GAME_ID, GAME_ID])


# ── The view ─────────────────────────────────────────────────────────────────


func _view(start_ms: int) -> QuickTimeEventView:
	var view: QuickTimeEventView = auto_free(QuickTimeEventView.new())
	add_child(view)
	view.setup(
		QuickTimeEventGame.new({}, ONE_PROMPT_MS, 1),
		QuickTimeEventGame.normalize_knobs({}),
		start_ms
	)
	return view


func test_a_press_on_target_scores_full_marks_at_any_start_position() -> void:
	var view: QuickTimeEventView = _view(30000)
	assert_bool(view.press(30000 + 1200, "E")).is_true()
	assert_int(view.score()).is_equal(100)


func test_a_press_with_no_prompt_showing_does_not_land() -> void:
	assert_bool(_view(30000).press(20000, "E")).is_false()


func test_playing_on_counts_but_jumping_does_not() -> void:
	var view: QuickTimeEventView = _view(30000)
	view.advance_to(31000)
	assert_bool(view.played_through_to(31500)).is_true()
	assert_bool(view.played_through_to(30000)).is_false()
	assert_bool(view.played_through_to(50000)).is_false()


func _held_view() -> QuickTimeEventView:
	var view: QuickTimeEventView = auto_free(QuickTimeEventView.new())
	add_child(view)
	var knobs: Dictionary = QuickTimeEventGame.normalize_knobs({})
	view.setup_held(QuickTimeEventGame.new(knobs, ONE_PROMPT_MS, 1), knobs)
	return view


# Its clock is its own: the video isn't moving.
func test_a_held_view_runs_on_its_own_clock_and_reports_the_end() -> void:
	var view: QuickTimeEventView = _held_view()
	var over: Array[bool] = [false]
	view.game_over.connect(func() -> void: over[0] = true)
	view._process(1.2)
	assert_bool(over[0]).is_false()
	assert_bool(view.press_held("E")).is_true()
	view._process(0.0)
	assert_bool(over[0]).is_true()
	assert_int(view.score()).is_equal(100)


func test_a_held_view_ends_on_its_own_if_the_player_does_nothing() -> void:
	var view: QuickTimeEventView = _held_view()
	var over: Array[bool] = [false]
	view.game_over.connect(func() -> void: over[0] = true)
	view._process(5.0)
	assert_bool(over[0]).is_true()
	assert_int(view.score()).is_equal(0)


# ── Pausing, on the timeline ─────────────────────────────────────────────────


func test_a_qte_with_no_length_fires_as_an_instant() -> void:
	var scheduler: RoundTimelineScheduler = RoundTimelineScheduler.new(
		{"events": [_standalone(1000, 0)]}, VIDEO_MS
	)
	scheduler.tick(0)
	assert_int((scheduler.tick(1000)["fire"] as Array).size()).is_equal(1)


func test_a_qte_that_pauses_the_video_has_no_timing_issues() -> void:
	var issues: Array = RoundTimeline.qte_issues(
		{"events": [_standalone(0, 0), _attack(1)]}, _library(5, true), VIDEO_MS
	)
	assert_array(issues).is_empty()


# ── Encounter audio during a pause ───────────────────────────────────────────


# Disabling the node is what holds a cue's fades and out-point, so they can't cut it off while it's silent.
func test_encounter_audio_holds_and_releases() -> void:
	var cues: BossAudioCues = auto_free(BossAudioCues.new())
	add_child(cues)
	var voice: AudioStreamPlayer = AudioStreamPlayer.new()
	voice.stream = AudioStreamGenerator.new()  # stream_paused only applies to a voice that's playing
	cues.add_child(voice)
	cues._voices.append(voice)
	voice.play()
	cues.set_paused(true)
	assert_bool(voice.stream_paused).is_true()
	assert_bool(cues.can_process()).is_false()
	cues.set_paused(false)
	assert_bool(voice.stream_paused).is_false()
	assert_bool(cues.can_process()).is_true()
