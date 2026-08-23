extends GdUnitTestSuite

# RoundTimeline — the pure boss-encounter model (BOSS_ROUND_DESIGN Phase 0). Every test builds a raw
# dictionary by hand and asserts on the normalized/resolved/validated result: no disk, no autoloads,
# no rng beyond the minted ids. Covers the canonical shape, the start/end anchor maths, the defeat
# split, authoring validation, and the media enumeration the save pools through.

# ── Fixtures ─────────────────────────────────────────────────────────────────


func _attack(id: String, at_ms: int, duration_ms: int = 5000) -> Dictionary:
	return {
		"id": id,
		"track": "attack",
		"at_ms": at_ms,
		"duration_ms": duration_ms,
		"name": "The Grip",
		"scripts": {"main": "/src/grip.funscript"},
	}


func _cast(id: String, at_ms: int) -> Dictionary:
	return {"id": id, "track": "cast", "at_ms": at_ms, "image": "/src/boss.png"}


func _audio(id: String, at_ms: int, kind: String = "sfx") -> Dictionary:
	return {"id": id, "track": "audio", "at_ms": at_ms, "kind": kind, "clip": "/src/hit.ogg"}


func _timeline(events: Array, extra: Dictionary = {}) -> Dictionary:
	var raw: Dictionary = {"events": events}
	raw.merge(extra, true)
	return RoundTimeline.normalize(raw)


func _by_id(timeline: Dictionary, id: String) -> Dictionary:
	for e: Dictionary in timeline["events"] as Array:
		if str(e["id"]) == id:
			return e
	return {}


# ── Normalization ────────────────────────────────────────────────────────────


func test_empty_timeline_is_the_canonical_blank() -> void:
	var t: Dictionary = RoundTimeline.empty()
	assert_bool(RoundTimeline.is_empty(t)).is_true()
	assert_array(t["events"]).is_empty()
	assert_array(t["phases"]).is_empty()
	assert_bool(bool(t["hp_bar"])).is_true()  # the HP bar is on by default for a timeline round


func test_normalize_fills_defaults_and_drops_unknown_tracks() -> void:
	var t: Dictionary = _timeline([_cast("c1", 1000), {"id": "x", "track": "nonsense", "at_ms": 0}])
	assert_int((t["events"] as Array).size()).is_equal(1)  # the unknown track is unplayable → dropped
	var cue: Dictionary = _by_id(t, "c1")
	assert_str(str(cue["anchor"])).is_equal("start")
	assert_str(str(cue["on"])).is_equal("always")
	assert_str(str(cue["blend"])).is_equal("normal")
	# Looping is NOT stored: BossCueLayer derives it from the cue's kind, so a one-shot plays once and a
	# windowed cue repeats for as long as its window is open.
	assert_bool(cue.has("loop")).is_false()


func test_normalize_coerces_json_floats_and_bad_enums() -> void:
	# JSON hands every number back as a float and a hand-edited file can carry anything at all.
	var t: Dictionary = _timeline(
		[
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 1500.0,
				"duration_ms": 900.0,
				"image": "/src/a.png",
				"anchor": "sideways",
				"blend": "multiply",
				"transition": "explode",
			}
		]
	)
	var cue: Dictionary = _by_id(t, "c1")
	assert_int(int(cue["at_ms"])).is_equal(1500)
	assert_int(int(cue["duration_ms"])).is_equal(900)
	assert_str(str(cue["anchor"])).is_equal("start")  # unknown enum → the safe default
	assert_str(str(cue["blend"])).is_equal("normal")
	assert_str(str(cue["transition"])).is_equal("fade")


func test_normalize_mints_missing_ids_and_keeps_given_ones() -> void:
	var t: Dictionary = _timeline([_cast("keep_me", 0), {"track": "audio", "clip": "/a.ogg"}])
	var ids: Array = []
	for e: Dictionary in t["events"] as Array:
		ids.append(str(e["id"]))
	assert_bool(ids.has("keep_me")).is_true()
	for id: String in ids:
		assert_bool(id.is_empty()).is_false()  # every event ends up identifiable


func test_normalize_sorts_start_before_end_then_by_offset() -> void:
	# END events count backwards from the round's end, so they must not interleave with START offsets.
	var t: Dictionary = _timeline(
		[
			{"id": "end_a", "track": "cast", "at_ms": 1000, "anchor": "end", "image": "/a.png"},
			_cast("start_b", 5000),
			_cast("start_a", 200),
		]
	)
	var ids: Array = []
	for e: Dictionary in t["events"] as Array:
		ids.append(str(e["id"]))
	assert_array(ids).is_equal(["start_a", "start_b", "end_a"])


func test_normalize_is_idempotent() -> void:
	# normalize() runs on BOTH save and load, so a second pass must not drift the shape.
	var once: Dictionary = _timeline([_attack("a1", 1000), _cast("c1", 20), _audio("s1", 50)])
	var twice: Dictionary = RoundTimeline.normalize(once)
	assert_str(JSON.stringify(twice)).is_equal(JSON.stringify(once))


func test_normalize_survives_a_json_round_trip() -> void:
	# The canonical shape IS the on-disk shape: Vector2/Color would stringify to unparseable text, so
	# offsets and tints must stay plain dictionaries.
	var t: Dictionary = _timeline(
		[{"id": "c1", "track": "cast", "image": "/a.png", "offset": {"x": 12.0, "y": -4.0}}],
		{
			"phases":
			[
				{
					"id": "p1",
					"name": "PHASE 2",
					"at_ms": 1000,
					"tint": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0}
				}
			]
		}
	)
	var parser := JSON.new()
	assert_int(parser.parse(JSON.stringify(t))).is_equal(OK)
	var back: Dictionary = RoundTimeline.normalize(parser.data as Dictionary)
	assert_str(JSON.stringify(back)).is_equal(JSON.stringify(t))
	assert_vector(RoundTimeline.offset_vector(_by_id(back, "c1"))).is_equal(Vector2(12.0, -4.0))


func test_a_legacy_condition_object_is_dropped_not_crashed() -> void:
	# v1 RESERVED `condition` as an opaque dictionary it never interpreted. Phase 6 implements that seam,
	# so a condition is now a validated clause list — and the old placeholder shape, which names no
	# signal this build knows, drops out. Dropping is the deliberate direction: an unreadable rule makes
	# an event fire MORE often than intended, never silently stop happening.
	var t: Dictionary = _timeline(
		[{"id": "c1", "track": "cast", "image": "/a.png", "condition": {"phase": "p2"}}]
	)
	assert_bool(_by_id(t, "c1").has("condition")).is_false()


# ── Per-track shape ──────────────────────────────────────────────────────────


func test_attack_normalizes_as_an_override_request() -> void:
	var t: Dictionary = _timeline(
		[
			{
				"id": "a1",
				"track": "attack",
				"at_ms": 0,
				"name": "The Grip",
				"immune_to_effects": true,
				"scripts":
				{"main": "/m.funscript", "axes": {"R1": "/r1.funscript"}, "vibes": {"vib1": ""}},
				"trim": {"in_ms": 500.0, "out_ms": 2000.0},
			}
		]
	)
	var a: Dictionary = _by_id(t, "a1")
	assert_str(str(a["name"])).is_equal("The Grip")  # names the HUD chip
	assert_bool(bool(a["immune_to_effects"])).is_true()
	var scripts: Dictionary = a["scripts"]
	assert_str(str(scripts["main"])).is_equal("/m.funscript")
	assert_str(str((scripts["axes"] as Dictionary)["R1"])).is_equal("/r1.funscript")
	assert_bool((scripts["vibes"] as Dictionary).is_empty()).is_true()  # empty channels are dropped
	assert_int(int((a["trim"] as Dictionary)["in_ms"])).is_equal(500)


func test_cast_text_styling_appears_only_with_text() -> void:
	var silent: Dictionary = _by_id(_timeline([_cast("c1", 0)]), "c1")
	assert_bool(silent.has("text_size")).is_false()  # no subtitle → nothing to style

	var spoken: Dictionary = _by_id(
		_timeline([{"id": "c2", "track": "cast", "image": "/a.png", "text": "You are mine."}]), "c2"
	)
	assert_str(str(spoken["text"])).is_equal("You are mine.")
	assert_int(int(spoken["text_size"])).is_equal(RoundTimeline.DEFAULT_TEXT_SIZE)
	assert_float(float(spoken["text_y"])).is_equal(RoundTimeline.DEFAULT_TEXT_Y)
	# Colour is stored only when the author picks one, so an untouched line follows the theme.
	assert_bool(spoken.has("text_color")).is_false()


func test_cast_text_size_is_clamped_and_colour_round_trips() -> void:
	var styled: Dictionary = _by_id(
		_timeline(
			[
				{
					"id": "c3",
					"track": "cast",
					"text": "Loud.",
					"text_size": 9000,
					"text_y": 4.2,
					"text_color": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0},
				}
			]
		),
		"c3"
	)
	assert_int(int(styled["text_size"])).is_equal(RoundTimeline.MAX_TEXT_SIZE)
	# An out-of-range position is clamped rather than anchoring the line off the canvas entirely.
	assert_float(float(styled["text_y"])).is_equal(1.0)
	assert_object(RoundTimeline.cue_text_color(styled, Color.WHITE)).is_equal(Color(1, 0, 0, 1))


func test_narration_ducks_by_default_and_sfx_does_not() -> void:
	var t: Dictionary = _timeline([_audio("s1", 0, "sfx"), _audio("n1", 10, "narration")])
	# A stab sits on top of the mix; a spoken line pulls the round down under it.
	assert_float(float(_by_id(t, "s1")["duck_pct"])).is_equal_approx(0.0, 0.001)
	assert_float(float(_by_id(t, "n1")["duck_pct"])).is_equal_approx(
		RoundTimeline.DEFAULT_NARRATION_DUCK_PCT, 0.001
	)


# ── Anchor resolution ────────────────────────────────────────────────────────


func test_start_anchor_resolves_to_its_own_offset() -> void:
	assert_int(RoundTimeline.resolve_at_ms(_cast("c1", 4200), 60000)).is_equal(4200)


func test_end_anchor_counts_back_from_the_video_duration() -> void:
	var ev: Dictionary = {"track": "cast", "at_ms": 10000, "anchor": "end"}
	assert_int(RoundTimeline.resolve_at_ms(ev, 60000)).is_equal(50000)
	# The whole point of end-anchoring: swap the video, the event stays "10 s before the end".
	assert_int(RoundTimeline.resolve_at_ms(ev, 90000)).is_equal(80000)


func test_unresolvable_end_anchors_report_no_time() -> void:
	var ev: Dictionary = {"track": "cast", "at_ms": 10000, "anchor": "end"}
	# Unknown duration, and an offset longer than the round — both must degrade to "skip", never to a
	# wrong time.
	assert_int(RoundTimeline.resolve_at_ms(ev, 0)).is_equal(RoundTimeline.NO_TIME)
	assert_int(RoundTimeline.resolve_at_ms(ev, 4000)).is_equal(RoundTimeline.NO_TIME)


func test_resolved_events_are_ordered_and_skip_the_unresolvable() -> void:
	var t: Dictionary = _timeline(
		[
			{"id": "outro", "track": "cast", "at_ms": 5000, "anchor": "end", "image": "/a.png"},
			_cast("early", 1000),
			{
				"id": "impossible",
				"track": "cast",
				"at_ms": 999999,
				"anchor": "end",
				"image": "/a.png"
			},
		]
	)
	var resolved: Array = RoundTimeline.resolved_events(t, 60000)
	var ids: Array = []
	for e: Dictionary in resolved:
		ids.append(str(e["id"]))
	assert_array(ids).is_equal(["early", "outro"])  # 1000 then 55000; the impossible one is gone
	assert_int(int((resolved[1] as Dictionary)["resolved_at_ms"])).is_equal(55000)


func test_outcome_events_are_split_out_of_the_normal_pass() -> void:
	var t: Dictionary = _timeline(
		[
			_cast("normal", 1000),
			{"id": "defeat", "track": "cast", "at_ms": 0, "on": "gave_in", "image": "/a.png"},
		]
	)
	var victory: Array = RoundTimeline.resolved_events(t, 60000)
	assert_int(victory.size()).is_equal(1)
	assert_str(str((victory[0] as Dictionary)["id"])).is_equal("normal")

	var defeat: Array = RoundTimeline.resolved_events(t, 60000, true)
	assert_int(defeat.size()).is_equal(1)
	assert_str(str((defeat[0] as Dictionary)["id"])).is_equal("defeat")


# ── Validation ───────────────────────────────────────────────────────────────


func _codes(issues: Array) -> Array:
	var out: Array = []
	for i: Dictionary in issues:
		out.append(str(i["code"]))
	return out


func test_validate_accepts_a_well_formed_timeline() -> void:
	var t: Dictionary = _timeline([_attack("a1", 1000), _cast("c1", 20), _audio("s1", 50)])
	assert_array(RoundTimeline.validate(t, 60000)).is_empty()


func test_validate_flags_empty_content_per_track() -> void:
	var t: Dictionary = _timeline(
		[
			{"id": "a1", "track": "attack", "at_ms": 0},  # no main funscript
			{"id": "c1", "track": "cast", "at_ms": 10},  # no art and no text
			{"id": "s1", "track": "audio", "at_ms": 20},  # no clip
			{"id": "e1", "track": "effect", "at_ms": 30, "duration_ms": 100},  # applies nothing
		]
	)
	var codes: Array = _codes(RoundTimeline.validate(t, 60000))
	assert_bool(codes.has(RoundTimeline.ISSUE_ATTACK_NO_SCRIPT)).is_true()
	assert_bool(codes.has(RoundTimeline.ISSUE_CAST_EMPTY)).is_true()
	assert_bool(codes.has(RoundTimeline.ISSUE_AUDIO_NO_CLIP)).is_true()
	assert_bool(codes.has(RoundTimeline.ISSUE_EFFECT_EMPTY)).is_true()


func test_validate_flags_overlapping_attacks() -> void:
	# The override engine holds one session, so a second attack would silently cut the first.
	var clashing: Dictionary = _timeline([_attack("a1", 1000, 5000), _attack("a2", 3000, 5000)])
	(
		assert_bool(
			_codes(RoundTimeline.validate(clashing, 60000)).has(RoundTimeline.ISSUE_ATTACK_OVERLAP)
		)
		. is_true()
	)

	# Butting up exactly against the previous attack's end is fine.
	var clean: Dictionary = _timeline([_attack("a1", 1000, 5000), _attack("a2", 6000, 5000)])
	assert_array(RoundTimeline.validate(clean, 60000)).is_empty()


func test_validate_flags_events_past_the_end_of_the_round() -> void:
	var t: Dictionary = _timeline([_cast("late", 90000)])
	(
		assert_bool(_codes(RoundTimeline.validate(t, 60000)).has(RoundTimeline.ISSUE_OUT_OF_RANGE))
		. is_true()
	)


func test_validate_skips_duration_checks_when_the_length_is_unknown() -> void:
	# With no probed duration the range/anchor checks would be guesses, so only content checks run.
	var t: Dictionary = _timeline(
		[_cast("late", 90000), _attack("a1", 0, 5000), _attack("a2", 1, 5000)]
	)
	assert_array(RoundTimeline.validate(t, 0)).is_empty()


# ── Media enumeration + remap (what the save pools) ──────────────────────────


func test_media_paths_collects_every_source_once() -> void:
	var t: Dictionary = _timeline(
		[
			{
				"id": "a1",
				"track": "attack",
				"scripts":
				{
					"main": "/m.funscript",
					"axes": {"R1": "/r1.funscript"},
					"vibes": {"vib1": "/v1.funscript"}
				},
			},
			_cast("c1", 10),
			_cast("c2", 20),  # same image as c1 — must appear once
			_audio("s1", 30),
		],
		{"bgm": {"clip": "/theme.ogg"}}
	)
	var paths: Array = RoundTimeline.media_paths(t)
	assert_bool(paths.has("/m.funscript")).is_true()
	assert_bool(paths.has("/r1.funscript")).is_true()
	assert_bool(paths.has("/v1.funscript")).is_true()
	assert_bool(paths.has("/src/hit.ogg")).is_true()
	assert_bool(paths.has("/theme.ogg")).is_true()
	assert_int(paths.count("/src/boss.png")).is_equal(1)  # deduped


func test_remap_media_rewrites_known_paths_and_leaves_the_rest() -> void:
	var t: Dictionary = _timeline(
		[
			{
				"id": "a1",
				"track": "attack",
				"scripts": {"main": "/m.funscript", "axes": {"R1": "/r1.funscript"}},
			},
			_cast("c1", 10),
		],
		{"bgm": {"clip": "/theme.ogg"}}
	)
	var mapped: Dictionary = RoundTimeline.remap_media(
		t, {"/m.funscript": "content/m__fp.funscript", "/theme.ogg": "content/theme__fp.ogg"}
	)
	var a: Dictionary = _by_id(mapped, "a1")
	assert_str(str((a["scripts"] as Dictionary)["main"])).is_equal("content/m__fp.funscript")
	# Unmapped paths survive untouched — a partial pool must never blank a path out.
	assert_str(str(((a["scripts"] as Dictionary)["axes"] as Dictionary)["R1"])).is_equal(
		"/r1.funscript"
	)
	assert_str(str(_by_id(mapped, "c1")["image"])).is_equal("/src/boss.png")
	assert_str(str((mapped["bgm"] as Dictionary)["clip"])).is_equal("content/theme__fp.ogg")


func test_remap_media_does_not_mutate_the_original() -> void:
	var t: Dictionary = _timeline(
		[{"id": "a1", "track": "attack", "scripts": {"main": "/m.funscript"}}]
	)
	var before: String = JSON.stringify(t)
	RoundTimeline.remap_media(t, {"/m.funscript": "content/pooled.funscript"})
	assert_str(JSON.stringify(t)).is_equal(before)


func test_media_entries_tag_each_source_with_its_family() -> void:
	# The save pools each family differently (funscripts normalize their extension, art goes through
	# the animation bake), so the enumeration has to say which is which.
	var t: Dictionary = _timeline(
		[
			{"id": "a1", "track": "attack", "scripts": {"main": "/m.funscript"}},
			_cast("c1", 10),
			_audio("s1", 20),
		],
		{"bgm": {"clip": "/theme.ogg"}}
	)
	var kinds: Dictionary = {}
	for entry: Dictionary in RoundTimeline.media_entries(t):
		kinds[str(entry["path"])] = str(entry["kind"])
	assert_str(str(kinds["/m.funscript"])).is_equal(RoundTimeline.MEDIA_FUNSCRIPT)
	assert_str(str(kinds["/src/boss.png"])).is_equal(RoundTimeline.MEDIA_IMAGE)
	assert_str(str(kinds["/src/hit.ogg"])).is_equal(RoundTimeline.MEDIA_AUDIO)
	assert_str(str(kinds["/theme.ogg"])).is_equal(RoundTimeline.MEDIA_AUDIO)


func test_resolve_media_prefixes_every_pooled_rel() -> void:
	# The load-side counterpart of pooling: rels become absolute under the journey folder.
	var t: Dictionary = _timeline(
		[
			{"id": "a1", "track": "attack", "scripts": {"main": "content/m__fp.funscript"}},
			{"id": "c1", "track": "cast", "image": "content/boss__fp.png"},
		],
		{"bgm": {"clip": "content/theme__fp.ogg"}}
	)
	var resolved: Dictionary = RoundTimeline.resolve_media(t, "user://journeys/demo")
	assert_str(str((_by_id(resolved, "a1")["scripts"] as Dictionary)["main"])).is_equal(
		"user://journeys/demo/content/m__fp.funscript"
	)
	assert_str(str(_by_id(resolved, "c1")["image"])).is_equal(
		"user://journeys/demo/content/boss__fp.png"
	)
	assert_str(str((resolved["bgm"] as Dictionary)["clip"])).is_equal(
		"user://journeys/demo/content/theme__fp.ogg"
	)


# ── Variants (Phase 5) ───────────────────────────────────────────────────────


func _seeded() -> RandomNumberGenerator:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 12345
	return rng


func test_alts_normalize_to_sparse_overlays_and_drop_empties() -> void:
	var t: Dictionary = _timeline(
		[
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 0,
				"text": "Base line.",
				"alts":
				[
					{"text": "Alt line.", "text_size": 9000},
					{"at_ms": 5000, "duration_ms": 800},  # timing only → nothing survives → dropped
					{"image": "/src/other.png"},
				],
			}
		]
	)
	var alts: Array = _by_id(t, "c1")["alts"]
	assert_int(alts.size()).is_equal(2)  # the middle entry overlaid nothing at all
	# Only ALT_FIELDS survive, and they are clamped exactly as the base fields are.
	assert_str(str((alts[0] as Dictionary)["text"])).is_equal("Alt line.")
	assert_int(int((alts[0] as Dictionary)["text_size"])).is_equal(RoundTimeline.MAX_TEXT_SIZE)
	assert_bool((alts[0] as Dictionary).has("at_ms")).is_false()
	assert_str(str((alts[1] as Dictionary)["image"])).is_equal("/src/other.png")


func test_roll_covers_base_and_every_alt() -> void:
	var t: Dictionary = _timeline(
		[
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 0,
				"text": "Base.",
				"alts": [{"text": "One."}, {"text": "Two."}],
			}
		]
	)
	# Index 0 is the BASE, 1..n the alts — two alternatives means three possible lines.
	var seen: Dictionary = {}
	var rng: RandomNumberGenerator = _seeded()
	for _i: int in 200:
		seen[int(RoundTimeline.roll_variants(t, rng)["c1"])] = true
	assert_int(seen.size()).is_equal(3)
	assert_bool(seen.has(0) and seen.has(1) and seen.has(2)).is_true()


func test_an_event_without_alts_is_never_rolled_for() -> void:
	var t: Dictionary = _timeline([_cast("c1", 0)])
	assert_bool(RoundTimeline.roll_variants(t, _seeded()).is_empty()).is_true()


func test_apply_bakes_the_choice_and_strips_the_candidates() -> void:
	var t: Dictionary = _timeline(
		[
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 2000,
				"text": "Base.",
				"image": "/src/boss.png",
				"alts": [{"text": "Chosen."}],
			}
		]
	)
	var baked: Dictionary = _by_id(RoundTimeline.apply_variants(t, {"c1": 1}), "c1")
	assert_str(str(baked["text"])).is_equal("Chosen.")
	# Untouched fields come from the base, and the candidate list is gone so nothing downstream can
	# choose a second time.
	assert_str(str(baked["image"])).is_equal("/src/boss.png")
	assert_int(int(baked["at_ms"])).is_equal(2000)
	assert_bool(baked.has("alts")).is_false()


func test_apply_zero_keeps_the_base() -> void:
	var t: Dictionary = _timeline(
		[{"id": "c1", "track": "cast", "at_ms": 0, "text": "Base.", "alts": [{"text": "Alt."}]}]
	)
	var baked: Dictionary = _by_id(RoundTimeline.apply_variants(t, {"c1": 0}), "c1")
	assert_str(str(baked["text"])).is_equal("Base.")
	assert_bool(baked.has("alts")).is_false()


func test_a_chosen_line_does_not_inherit_the_base_colour() -> void:
	# Otherwise one coloured alternative would silently tint every other candidate to match it.
	var t: Dictionary = _timeline(
		[
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 0,
				"text": "Base.",
				"text_color": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0},
				"alts": [{"text": "Plain."}],
			}
		]
	)
	(
		assert_bool(_by_id(RoundTimeline.apply_variants(t, {"c1": 1}), "c1").has("text_color"))
		. is_false()
	)


func test_alt_media_is_pooled_and_resolved_like_any_other_source() -> void:
	# Missing this would pool the base cue and leave every alternative pointing at the author's own disk.
	var t: Dictionary = _timeline(
		[
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 0,
				"image": "/src/boss.png",
				"alts": [{"image": "/src/boss_angry.png"}],
			},
			{
				"id": "s1",
				"track": "audio",
				"at_ms": 0,
				"clip": "/src/hit.ogg",
				"alts": [{"clip": "/src/hit_hard.ogg"}],
			},
		]
	)
	var paths: Array = RoundTimeline.media_paths(t)
	assert_bool(paths.has("/src/boss_angry.png")).is_true()
	assert_bool(paths.has("/src/hit_hard.ogg")).is_true()

	var mapped: Dictionary = RoundTimeline.remap_media(
		t, {"/src/boss_angry.png": "content/angry.png"}
	)
	var alts: Array = _by_id(mapped, "c1")["alts"]
	assert_str(str((alts[0] as Dictionary)["image"])).is_equal("content/angry.png")


func test_an_alternative_that_changes_nothing_is_reported() -> void:
	# Validated against the RAW event: normalize drops the empty overlay, so by save time there is
	# nothing left to warn about.
	var raw: Dictionary = {
		"events":
		[{"id": "c1", "track": "cast", "at_ms": 0, "text": "Base.", "alts": [{"text": ""}]}]
	}
	(
		assert_bool(_codes(RoundTimeline.validate(raw, 60000)).has(RoundTimeline.ISSUE_ALT_EMPTY))
		. is_true()
	)


# ── Segments (Phase 5.5) ─────────────────────────────────────────────────────


func _segmented(events: Array, tags: Array = ["A", "B"]) -> Dictionary:
	return _timeline(events, {"segments": [{"id": "seg1", "name": "The Move", "tags": tags}]})


func test_an_untagged_event_always_survives() -> void:
	var t: Dictionary = _segmented([_cast("plain", 0)])
	var kept: Dictionary = RoundTimeline.apply_segments(t, {"seg1": "A"})
	assert_int((kept["events"] as Array).size()).is_equal(1)


func test_only_the_chosen_branch_survives() -> void:
	var a: Dictionary = _cast("c_a", 0)
	a["variant_tag"] = "A"
	var b: Dictionary = _cast("c_b", 0)
	b["variant_tag"] = "B"
	var t: Dictionary = _segmented([a, b, _cast("plain", 0)])

	var kept: Array = RoundTimeline.apply_segments(t, {"seg1": "B"})["events"] as Array
	var ids: Array = []
	for e: Dictionary in kept:
		ids.append(str(e["id"]))
	assert_bool(ids.has("c_b")).is_true()
	assert_bool(ids.has("plain")).is_true()  # untagged rides along with whichever branch won
	assert_bool(ids.has("c_a")).is_false()


func test_an_unclaimed_tag_is_never_dropped() -> void:
	# An unrecognised tag silently deleting an author's work is the worst failure here, because nothing
	# in the round would look wrong — the events would simply never appear.
	var orphan: Dictionary = _cast("orphan", 0)
	orphan["variant_tag"] = "NOT_IN_ANY_SEGMENT"
	var t: Dictionary = _segmented([orphan])
	assert_int((RoundTimeline.apply_segments(t, {"seg1": "A"})["events"] as Array).size()).is_equal(
		1
	)


func test_roll_picks_only_from_the_declared_tags() -> void:
	var t: Dictionary = _segmented([_cast("c1", 0)], ["A", "B", "C"])
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 99
	var seen: Dictionary = {}
	for _i: int in 200:
		seen[str(RoundTimeline.roll_segments(t, rng)["seg1"])] = true
	assert_int(seen.size()).is_equal(3)
	assert_bool(seen.has("A") and seen.has("B") and seen.has("C")).is_true()


func test_a_one_branch_segment_is_never_rolled_and_is_reported() -> void:
	var only: Dictionary = _cast("c1", 0)
	only["variant_tag"] = "A"
	var t: Dictionary = _segmented([only], ["A"])
	assert_bool(RoundTimeline.roll_segments(t, RandomNumberGenerator.new()).is_empty()).is_true()
	(
		assert_bool(_codes(RoundTimeline.validate(t, 60000)).has(RoundTimeline.ISSUE_SEGMENT_THIN))
		. is_true()
	)


func test_a_branch_with_no_events_is_reported() -> void:
	var a: Dictionary = _cast("c_a", 0)
	a["variant_tag"] = "A"
	var t: Dictionary = _segmented([a])  # tags A and B, but nothing is tagged B
	(
		assert_bool(
			_codes(RoundTimeline.validate(t, 60000)).has(RoundTimeline.ISSUE_SEGMENT_DEAD_TAG)
		)
		. is_true()
	)


func test_attacks_on_different_branches_may_overlap() -> void:
	# They can never both play, so flagging them would put a false error on every segmented encounter.
	var a: Dictionary = _attack("a_a", 1000, 5000)
	a["variant_tag"] = "A"
	var b: Dictionary = _attack("a_b", 1000, 8000)
	b["variant_tag"] = "B"
	var t: Dictionary = _segmented([a, b])
	(
		assert_bool(
			_codes(RoundTimeline.validate(t, 60000)).has(RoundTimeline.ISSUE_ATTACK_OVERLAP)
		)
		. is_false()
	)


func test_a_real_overlap_behind_an_excluded_attack_is_still_caught() -> void:
	# The excluded attack sits between two that DO collide. Comparing only immediate neighbours would
	# blame the excluded one and never compare the pair that actually clash.
	var first: Dictionary = _attack("a_first", 0, 10000)
	first["variant_tag"] = "B"
	var excluded: Dictionary = _attack("a_excluded", 1000, 500)
	excluded["variant_tag"] = "A"
	var real: Dictionary = _attack("a_real", 2000, 500)  # untagged: coexists with either branch
	var t: Dictionary = _timeline(
		[first, excluded, real], {"segments": [{"id": "seg1", "tags": ["A", "B"]}]}
	)

	var flagged: Array = []
	for issue: Dictionary in RoundTimeline.validate(t, 60000):
		if str(issue["code"]) == RoundTimeline.ISSUE_ATTACK_OVERLAP:
			flagged.append(str(issue["event_id"]))
	assert_array(flagged).is_equal(["a_real"])


func test_segments_resolve_before_alternatives() -> void:
	# A dropped branch has no business rolling for alternatives it will never show.
	var losing: Dictionary = _cast("c_lose", 0)
	losing["variant_tag"] = "A"
	losing["alts"] = [{"text": "never seen"}]
	var winning: Dictionary = _cast("c_win", 0)
	winning["variant_tag"] = "B"
	var t: Dictionary = _segmented([losing, winning])

	var survived: Dictionary = RoundTimeline.apply_segments(t, {"seg1": "B"})
	(
		assert_bool(RoundTimeline.roll_variants(survived, RandomNumberGenerator.new()).is_empty())
		. is_true()
	)


func test_a_timeline_without_segments_is_untouched() -> void:
	var t: Dictionary = _timeline([_cast("c1", 0)])
	assert_array(t["segments"]).is_empty()
	# apply_segments with no picks must hand back exactly what it was given.
	assert_int((RoundTimeline.apply_segments(t, {})["events"] as Array).size()).is_equal(1)


# ── Conditions (Phase 6, pure layer) ─────────────────────────────────────────


func _state(overrides: Dictionary = {}) -> Dictionary:
	var s: Dictionary = RoundTimeline.empty_state()
	s.merge(overrides, true)
	return s


func test_an_empty_condition_always_passes() -> void:
	# What makes conditions back-compatible with every event authored before they existed.
	assert_bool(RoundTimeline.evaluate_condition([], _state())).is_true()


func test_clauses_are_anded() -> void:
	var both: Dictionary = RoundTimeline.normalize_condition(
		[{"signal": "score", "op": "gt", "value": 100}, {"signal": "spm", "op": "lt", "value": 40}]
	)
	(
		assert_bool(RoundTimeline.evaluate_condition(both, _state({"score": 500, "spm": 20.0})))
		. is_true()
	)
	# Second clause fails → the whole thing fails.
	(
		assert_bool(RoundTimeline.evaluate_condition(both, _state({"score": 500, "spm": 90.0})))
		. is_false()
	)


func test_an_unknown_signal_or_op_is_dropped_not_failed() -> void:
	# A journey from a later build should fire MORE often than intended, never fall silent.
	var parsed: Dictionary = (
		RoundTimeline
		. normalize_condition(
			[
				{"signal": "heart_rate", "op": "gt", "value": 1},
				{"signal": "score", "op": "sideways", "value": 1},
				{"signal": "score", "op": "gte", "value": 10},
			]
		)
	)
	assert_int(RoundTimeline.condition_clauses(parsed).size()).is_equal(1)
	assert_bool(RoundTimeline.evaluate_condition(parsed, _state({"score": 10}))).is_true()


func test_the_item_signal_compares_as_text() -> void:
	var used: Dictionary = RoundTimeline.normalize_condition(
		[{"signal": "last_item_kind", "op": "eq", "value": "cleanse"}]
	)
	(
		assert_bool(RoundTimeline.evaluate_condition(used, _state({"last_item_kind": "cleanse"})))
		. is_true()
	)
	(
		assert_bool(RoundTimeline.evaluate_condition(used, _state({"last_item_kind": "key"})))
		. is_false()
	)


func test_a_conditioned_branch_beats_the_roll() -> void:
	var segment: Dictionary = (
		RoundTimeline
		. normalize_segment(
			{
				"id": "seg1",
				"branches":
				[
					{
						"tag": "STRUGGLING",
						"condition": [{"signal": "score", "op": "lt", "value": 100}]
					},
					{"tag": "NORMAL", "condition": []},
				],
			}
		)
	)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	assert_str(RoundTimeline.choose_branch(segment, _state({"score": 20}), rng)).is_equal(
		"STRUGGLING"
	)
	# Condition fails → the unconditioned pool decides, and here it holds only one branch.
	assert_str(RoundTimeline.choose_branch(segment, _state({"score": 900}), rng)).is_equal("NORMAL")


func test_all_branches_conditioned_and_none_matching_still_plays_something() -> void:
	# A fork that silently drops its whole move is indistinguishable from a bug.
	var segment: Dictionary = (
		RoundTimeline
		. normalize_segment(
			{
				"id": "seg1",
				"branches":
				[
					{"tag": "A", "condition": [{"signal": "score", "op": "gt", "value": 1000}]},
					{"tag": "B", "condition": [{"signal": "score", "op": "gt", "value": 2000}]},
				],
			}
		)
	)
	(
		assert_str(
			RoundTimeline.choose_branch(segment, _state({"score": 0}), RandomNumberGenerator.new())
		)
		. is_equal("A")
	)


func test_a_segment_with_no_conditions_is_still_a_plain_random_fork() -> void:
	var segment: Dictionary = RoundTimeline.normalize_segment(
		{"id": "seg1", "tags": ["A", "B", "C"]}
	)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7
	var seen: Dictionary = {}
	for _i: int in 200:
		seen[RoundTimeline.choose_branch(segment, _state(), rng)] = true
	assert_int(seen.size()).is_equal(3)


func test_legacy_tag_lists_migrate_to_branches() -> void:
	var segment: Dictionary = RoundTimeline.normalize_segment({"id": "seg1", "tags": ["A", "B"]})
	assert_array(RoundTimeline.segment_tags(segment)).is_equal(["A", "B"])
	# A legacy tag carried no rule, so its branch is unconditioned and joins the random pool. Read
	# through condition_clauses rather than cast directly: an empty condition normalizes to {}, and the
	# assertion should be about there being no rule, not about which shape "no rule" happens to take.
	var condition: Variant = (segment["branches"][0] as Dictionary)["condition"]
	assert_array(RoundTimeline.condition_clauses(condition)).is_empty()


func test_an_event_condition_normalizes_to_a_clause_list() -> void:
	# The v1 schema reserved `condition` as a DICTIONARY carried verbatim. Left that way it would reach
	# evaluate_condition, which iterates it as a list of clauses — and iterating a Dictionary yields its
	# keys, so every clause would arrive as a bare String.
	var t: Dictionary = _timeline(
		[
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 0,
				"text": "hi",
				"condition": [{"signal": "score", "op": "lt", "value": 50}],
			}
		]
	)
	var condition: Variant = _by_id(t, "c1")["condition"]
	assert_bool(condition is Dictionary).is_true()
	assert_int(RoundTimeline.condition_clauses(condition).size()).is_equal(1)
	assert_bool(RoundTimeline.evaluate_condition(condition, RoundTimeline.empty_state())).is_true()


func test_an_event_without_a_condition_stores_none() -> void:
	# An absent condition always passes, so writing an empty list onto every event would put noise in
	# every saved journey.
	assert_bool(_by_id(_timeline([_cast("c1", 0)]), "c1").has("condition")).is_false()


func test_condition_text_matches_the_operator_dropdown() -> void:
	# The gutter, the inspector caption and the operator picker all read from op_symbol, so an author
	# meets the same phrasing everywhere.
	assert_str(RoundTimeline.op_symbol(RoundTimeline.OP_GTE)).is_equal(">=")
	(
		assert_str(RoundTimeline.condition_text([{"signal": "score", "op": "gte", "value": 250}]))
		. is_equal("Score >= 250")
	)
	assert_str(RoundTimeline.condition_text([])).is_equal("random")


func test_any_mode_passes_when_one_clause_holds() -> void:
	# Multiple clauses default to ALL; ANY is opt-in, so nothing authored before it changes meaning.
	var clauses: Array = [
		{"signal": "score", "op": "gt", "value": 1000},
		{"signal": "spm", "op": "lt", "value": 20},
	]
	var all_of: Dictionary = RoundTimeline.normalize_condition({"match": "all", "clauses": clauses})
	var any_of: Dictionary = RoundTimeline.normalize_condition({"match": "any", "clauses": clauses})
	var slow_but_low: Dictionary = _state({"score": 10, "spm": 5.0})
	assert_bool(RoundTimeline.evaluate_condition(all_of, slow_but_low)).is_false()
	assert_bool(RoundTimeline.evaluate_condition(any_of, slow_but_low)).is_true()


func test_any_mode_fails_when_no_clause_holds() -> void:
	var any_of: Dictionary = RoundTimeline.normalize_condition(
		{"match": "any", "clauses": [{"signal": "score", "op": "gt", "value": 1000}]}
	)
	assert_bool(RoundTimeline.evaluate_condition(any_of, _state({"score": 10}))).is_false()


func test_a_bare_clause_list_still_reads_as_all() -> void:
	# The shape conditions were first written in. It meant ALL, and has to keep meaning it.
	var legacy: Dictionary = RoundTimeline.normalize_condition(
		[{"signal": "score", "op": "gt", "value": 10}]
	)
	assert_str(RoundTimeline.condition_match(legacy)).is_equal(RoundTimeline.MATCH_ALL)


func test_condition_text_spells_out_the_joiner() -> void:
	var any_of: Dictionary = (
		RoundTimeline
		. normalize_condition(
			{
				"match": "any",
				"clauses":
				[
					{"signal": "score", "op": "lt", "value": 100},
					{"signal": "spm", "op": "lt", "value": 20},
				],
			}
		)
	)
	assert_str(RoundTimeline.condition_text(any_of)).is_equal(
		"Score < 100 or Strokes Per Minute < 20"
	)


func test_both_name_signals_compare_as_text() -> void:
	# last_item_kind asks WHAT SORT of item; last_item_id asks WHICH ONE. Both are names, so both parse
	# and compare as text rather than being coerced to numbers.
	assert_bool(RoundTimeline.is_text_signal(RoundTimeline.SIGNAL_LAST_ITEM)).is_true()
	assert_bool(RoundTimeline.is_text_signal(RoundTimeline.SIGNAL_LAST_ITEM_ID)).is_true()
	assert_bool(RoundTimeline.is_text_signal(RoundTimeline.SIGNAL_SCORE)).is_false()

	var by_id: Dictionary = RoundTimeline.normalize_condition(
		[{"signal": "last_item_id", "op": "eq", "value": "itm_silver_key"}]
	)
	var clause: Dictionary = RoundTimeline.condition_clauses(by_id)[0]
	assert_bool(clause["value"] is String).is_true()
	(
		assert_bool(
			RoundTimeline.evaluate_condition(by_id, _state({"last_item_id": "itm_silver_key"}))
		)
		. is_true()
	)
	(
		assert_bool(RoundTimeline.evaluate_condition(by_id, _state({"last_item_id": "itm_other"})))
		. is_false()
	)


func test_an_unused_item_signal_reads_as_nothing_used() -> void:
	# Both stay empty until items are un-gated in boss rounds, so a rule on them simply never fires.
	var state: Dictionary = RoundTimeline.empty_state()
	assert_str(str(state[RoundTimeline.SIGNAL_LAST_ITEM_ID])).is_equal("")
	var rule: Dictionary = RoundTimeline.normalize_condition(
		[{"signal": "last_item_id", "op": "eq", "value": "cleanse"}]
	)
	assert_bool(RoundTimeline.evaluate_condition(rule, state)).is_false()


func test_items_default_to_allowed_on_an_authored_encounter() -> void:
	# The GATE for a boss round with no encounter lives in GameLoop._items_allowed_here — the model only
	# says what an authored one wants, and an author who never touched the switch wants the default.
	assert_bool(bool(_timeline([_cast("c1", 0)])["items_allowed"])).is_true()
	(
		assert_bool(bool(_timeline([_cast("c1", 0)], {"items_allowed": false})["items_allowed"]))
		. is_false()
	)


func test_signals_read_as_words_not_ids() -> void:
	# The stored ids stay terse so saved journeys keep working; everything on screen says what the
	# number actually is. The stroke ranges are spelled out because "small" never told anyone where
	# small stops.
	assert_str(RoundTimeline.signal_label("spm")).is_equal("Strokes Per Minute")
	assert_str(RoundTimeline.signal_label("small")).is_equal("Small Strokes (0-20)")
	assert_str(RoundTimeline.signal_label("last_item_id")).is_equal("Last Item Used")
	# An id this build does not know still shows as itself rather than blank.
	assert_str(RoundTimeline.signal_label("whatever")).is_equal("whatever")


func test_a_name_signal_reads_and_compares_as_is() -> void:
	# Ordering an item name is meaningless, so only equality is offered — and it reads in words.
	assert_array(RoundTimeline.ops_for("last_item_id")).is_equal(["eq", "neq"])
	assert_array(RoundTimeline.ops_for("score")).is_equal(RoundTimeline.OPS)
	assert_str(RoundTimeline.op_label("eq", "last_item_id")).is_equal("is")
	assert_str(RoundTimeline.op_label("neq", "last_item_id")).is_equal("is not")
	assert_str(RoundTimeline.op_label("lt", "score")).is_equal("<")


func test_a_rule_prints_the_item_name_when_one_is_known() -> void:
	var rule: Dictionary = RoundTimeline.normalize_condition(
		[{"signal": "last_item_id", "op": "eq", "value": "itm_key"}]
	)
	assert_str(RoundTimeline.condition_text(rule, {"itm_key": "Silver Key"})).is_equal(
		"Last Item Used is Silver Key"
	)
	# With no name to hand, the raw value shows — terse, never wrong.
	assert_str(RoundTimeline.condition_text(rule)).is_equal("Last Item Used is itm_key")


func test_matched_branch_answers_only_the_rules() -> void:
	# The editor asks the deterministic half of the question — which branch the RULES pick for a given
	# player — without a roll answering the rest on its behalf.
	var segment: Dictionary = (
		RoundTimeline
		. normalize_segment(
			{
				"id": "seg1",
				"branches":
				[
					{"tag": "HARD", "condition": [{"signal": "score", "op": "gte", "value": 500}]},
					{"tag": "EASY", "condition": []},
				],
			}
		)
	)
	assert_str(RoundTimeline.matched_branch(segment, _state({"score": 900}))).is_equal("HARD")
	# No rule holds → "", which is the caller's cue that a roll (or the editor's cycle) decides.
	assert_str(RoundTimeline.matched_branch(segment, _state({"score": 10}))).is_equal("")
	assert_array(RoundTimeline.unconditioned_branches(segment)).is_equal(["EASY"])


func test_choose_branch_still_prefers_a_rule_over_the_roll() -> void:
	# The split must not have changed what the ROUND does.
	var segment: Dictionary = (
		RoundTimeline
		. normalize_segment(
			{
				"id": "seg1",
				"branches":
				[
					{"tag": "HARD", "condition": [{"signal": "score", "op": "gte", "value": 500}]},
					{"tag": "EASY", "condition": []},
				],
			}
		)
	)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	for _i: int in 30:
		assert_str(RoundTimeline.choose_branch(segment, _state({"score": 900}), rng)).is_equal(
			"HARD"
		)


func test_hp_source_defaults_to_time() -> void:
	# Every encounter authored before Phase 7 keeps the bar it had — the clock, read backwards.
	var t: Dictionary = _timeline([_cast("c1", 0)])
	assert_str(str(t["hp_source"])).is_equal(RoundTimeline.HP_TIME)
	assert_int(int(t["damage_target"])).is_equal(RoundTimeline.DEFAULT_DAMAGE_TARGET)


func test_an_unknown_hp_source_falls_back_rather_than_reaching_the_bar() -> void:
	var t: Dictionary = _timeline([_cast("c1", 0)], {"hp_source": "vibes"})
	assert_str(str(t["hp_source"])).is_equal(RoundTimeline.HP_TIME)


func test_damage_fraction_fills_toward_the_target() -> void:
	var t: Dictionary = _timeline([_cast("c1", 0)], {"hp_source": "score", "damage_target": 400})
	assert_float(RoundTimeline.damage_fraction(t, 0)).is_equal(0.0)
	assert_float(RoundTimeline.damage_fraction(t, 200)).is_equal(0.5)
	assert_float(RoundTimeline.damage_fraction(t, 400)).is_equal(1.0)
	# Past the target the bar stays empty rather than going negative and refilling.
	assert_float(RoundTimeline.damage_fraction(t, 9999)).is_equal(1.0)


func test_a_target_of_nothing_cannot_divide_by_zero() -> void:
	# A zero target would read as instantly dead — or crash the bar, depending on the platform.
	var t: Dictionary = _timeline([_cast("c1", 0)], {"hp_source": "score", "damage_target": 0})
	assert_int(int(t["damage_target"])).is_equal(1)
	assert_float(RoundTimeline.damage_fraction(t, 1)).is_equal(1.0)


# ── Cycling combinations (the editor's CYCLE) ────────────────────────────────


func _two_forks() -> Dictionary:
	var a1: Dictionary = _cast("a1", 0)
	a1["variant_tag"] = "A1"
	var a2: Dictionary = _cast("a2", 0)
	a2["variant_tag"] = "A2"
	var b1: Dictionary = _cast("b1", 1000)
	b1["variant_tag"] = "B1"
	var b2: Dictionary = _cast("b2", 1000)
	b2["variant_tag"] = "B2"
	return _timeline(
		[a1, a2, b1, b2],
		{
			"segments":
			[
				{"id": "segA", "tags": ["A1", "A2"]},
				{"id": "segB", "tags": ["B1", "B2"]},
			]
		}
	)


func _walk(timeline: Dictionary, presses: int) -> Array:
	var segments: Dictionary = {}
	var variants: Dictionary = {}
	var seen: Array = []
	for _i: int in presses:
		var stepped: Dictionary = RoundTimeline.next_combination(
			timeline, segments, variants, RoundTimeline.empty_state()
		)
		segments = stepped["segments"]
		variants = stepped["variants"]
		seen.append("%s|%s" % [str(segments.get("segA", "")), str(segments.get("segB", ""))])
	return seen


func test_cycling_reaches_every_combination_of_two_forks() -> void:
	# An odometer, not lockstep: stepping both dials together would show A1|B1 and A2|B2 and never a
	# mixed pairing.
	var seen: Array = _walk(_two_forks(), 4)
	assert_int(seen.size()).is_equal(4)
	var unique: Dictionary = {}
	for combo: String in seen:
		unique[combo] = true
	assert_int(unique.size()).is_equal(4)


func test_cycle_wraps_around() -> void:
	var timeline: Dictionary = _two_forks()
	var seen: Array = _walk(timeline, 8)
	assert_str(str(seen[4])).is_equal(str(seen[0]))
	assert_str(str(seen[7])).is_equal(str(seen[3]))


func test_a_conditioned_fork_does_not_block_the_ones_after_it() -> void:
	# The bug this function was extracted to make testable: a rule-decided segment is not the cycle's
	# to step, and absorbing the carry made it a wall nothing behind could be reached through.
	var timeline: Dictionary = _two_forks()
	var segments: Array = timeline["segments"]
	# segA is decided by a rule that always holds, so only segB should ever move.
	(segments[0] as Dictionary)["branches"] = (
		RoundTimeline
		. normalize_segment(
			{
				"id": "segA",
				"branches":
				[
					{"tag": "A1", "condition": [{"signal": "score", "op": "gte", "value": 0}]},
					{"tag": "A2", "condition": []},
				],
			}
		)["branches"]
	)

	var segments_picks: Dictionary = {}
	var variants: Dictionary = {}
	var reached: Dictionary = {}
	for _i: int in 6:
		var stepped: Dictionary = RoundTimeline.next_combination(
			timeline, segments_picks, variants, RoundTimeline.empty_state()
		)
		segments_picks = stepped["segments"]
		variants = stepped["variants"]
		reached[str(segments_picks.get("segB", ""))] = true
	assert_int(reached.size()).is_equal(2)  # segB still reaches both of its branches


func test_alts_step_after_branch_wrap() -> void:
	var spoken: Dictionary = _cast("c1", 0)
	spoken["variant_tag"] = "A1"
	spoken["alts"] = [{"text": "second"}]
	var other: Dictionary = _cast("c2", 0)
	other["variant_tag"] = "A2"
	var timeline: Dictionary = _timeline(
		[spoken, other], {"segments": [{"id": "segA", "tags": ["A1", "A2"]}]}
	)

	var segments: Dictionary = {}
	var variants: Dictionary = {}
	# First press moves the branch, not the line.
	var step1: Dictionary = RoundTimeline.next_combination(
		timeline, segments, variants, RoundTimeline.empty_state()
	)
	assert_int(int((step1["variants"] as Dictionary).get("c1", 0))).is_equal(0)
	# Second press wraps the branch and carries into the alternative.
	var step2: Dictionary = RoundTimeline.next_combination(
		timeline, step1["segments"], step1["variants"], RoundTimeline.empty_state()
	)
	assert_int(int((step2["variants"] as Dictionary).get("c1", 0))).is_equal(1)


func test_the_separate_out_of_attempts_ending_folds_into_giving_in() -> void:
	# Two ways to lose, one ending. Nothing ever wanted to tell them apart, and an author writing "she
	# wins" was writing it twice — so an encounter authored against the split keeps playing.
	var t: Dictionary = _timeline(
		[{"id": "c1", "track": "cast", "at_ms": 0, "text": "She wins.", "on": "lost"}]
	)
	assert_str(str(_by_id(t, "c1")["on"])).is_equal(RoundTimeline.ON_GAVE_IN)


func test_an_alt_with_its_own_art_drops_the_inherited_character() -> void:
	# A cue naming a CHARACTER resolves its art from that character's portrait and only falls back to
	# `image` — in the round and in the preview alike. So an alternative that brings its own picture has
	# to shed the character, or the portrait wins the lookup and the alternative draws the original.
	var event: Dictionary = (
		RoundTimeline
		. normalize_event(
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 0,
				"character_id": "boss",
				"alts": [{"image": "/alt.png"}],
			}
		)
	)
	var chosen: Dictionary = RoundTimeline.apply_variant(event, 1)
	assert_str(str(chosen["image"])).is_equal("/alt.png")
	assert_bool(str(chosen.get("character_id", "")) == "").is_true()


func test_an_alt_choosing_an_expression_keeps_its_character() -> void:
	# The opposite case: a portrait IS the character's art, so it needs the character to resolve against.
	var event: Dictionary = (
		RoundTimeline
		. normalize_event(
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 0,
				"character_id": "boss",
				"alts": [{"portrait": "angry"}],
			}
		)
	)
	var chosen: Dictionary = RoundTimeline.apply_variant(event, 1)
	assert_str(str(chosen["portrait"])).is_equal("angry")
	assert_str(str(chosen["character_id"])).is_equal("boss")


func test_the_base_cue_keeps_its_character() -> void:
	# Index 0 is the base and must be untouched — the rule above applies to a CHOSEN alternative only.
	var event: Dictionary = (
		RoundTimeline
		. normalize_event(
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 0,
				"character_id": "boss",
				"alts": [{"image": "/alt.png"}],
			}
		)
	)
	assert_str(str(RoundTimeline.apply_variant(event, 0)["character_id"])).is_equal("boss")


func test_a_cast_alt_can_frame_itself() -> void:
	# Placement is not timing. A portrait and a wide shot want different framing, and text_y was already
	# per-alt — so excluding the rest was inconsistent as well as limiting.
	var t: Dictionary = _timeline(
		[
			{
				"id": "c1",
				"track": "cast",
				"at_ms": 0,
				"image": "/a.png",
				"alts":
				[
					{
						"image": "/b.png",
						"scale": 1.8,
						"anchor_pos": "left",
						"offset": {"x": 40, "y": -10}
					}
				]
			}
		]
	)
	var alt: Dictionary = (_by_id(t, "c1")["alts"] as Array)[0]
	assert_float(float(alt["scale"])).is_equal_approx(1.8, 0.001)
	assert_str(str(alt["anchor_pos"])).is_equal("left")
	assert_float(float((alt["offset"] as Dictionary)["x"])).is_equal_approx(40.0, 0.001)


func test_an_alt_that_sets_no_framing_inherits_it() -> void:
	# The overlay is SPARSE: a key the alternative never set must not appear, or it would overwrite the
	# parent's own placement with a default and silently un-nudge the cue.
	var t: Dictionary = _timeline(
		[{"id": "c1", "track": "cast", "at_ms": 0, "image": "/a.png", "alts": [{"text": "hi"}]}]
	)
	var alt: Dictionary = (_by_id(t, "c1")["alts"] as Array)[0]
	assert_bool(alt.has("offset")).is_false()
	assert_bool(alt.has("scale")).is_false()
	assert_bool(alt.has("anchor_pos")).is_false()


func test_an_attack_never_carries_alts() -> void:
	# Attacks vary by SEGMENT, not by overlay. An alt could only swap the script inside a fixed block —
	# invisible in the preview, in the reference curve and on the device, and silently losing the tail of
	# anything longer. Two attacks on branches of one segment may start together and run for different
	# lengths, and each branch brings its own telegraph and impact with it.
	var raw: Dictionary = _attack("a1", 0)
	raw["alts"] = [{"text": "nope"}]
	assert_bool(_by_id(_timeline([raw]), "a1").has("alts")).is_false()


func test_two_attacks_on_different_branches_may_share_a_start() -> void:
	# The mechanism that replaces attack alts: one segment, two unconditioned branches, a dice roll per
	# round entry. They overlap on the lane on purpose and must NOT be reported for it.
	var t: Dictionary = (
		RoundTimeline
		. normalize(
			{
				"events":
				[
					_tagged_attack("a1", 0, 4000, "A"),
					_tagged_attack("a2", 0, 9000, "B"),
				],
				"segments":
				[
					{
						"id": "seg1",
						"name": "Opener",
						"branches": [{"tag": "A", "condition": {}}, {"tag": "B", "condition": {}}],
					}
				],
			}
		)
	)
	for issue: Dictionary in RoundTimeline.validate(t, 60000):
		assert_str(str(issue["code"])).is_not_equal(RoundTimeline.ISSUE_ATTACK_OVERLAP)
	# One of them plays, never both, and the lengths stay their own.
	var picked: Dictionary = RoundTimeline.apply_segments(t, {"seg1": "B"})
	var ids: Array = []
	for event: Dictionary in picked["events"] as Array:
		ids.append(str(event["id"]))
	assert_array(ids).is_equal(["a2"])
	assert_int(int((picked["events"] as Array)[0]["duration_ms"])).is_equal(9000)


func _tagged_attack(id: String, at_ms: int, duration_ms: int, tag: String) -> Dictionary:
	var event: Dictionary = _attack(id, at_ms, duration_ms)
	event["variant_tag"] = tag
	return event


func test_audio_fades_survive_normalizing() -> void:
	# They did not. The editor offered the fields and BossAudioCues implemented them, but normalize()
	# builds a fresh dictionary from the keys it knows and these were only listed for effect windows —
	# so every audio ease an author set was silently discarded on the way through.
	var t: Dictionary = _timeline(
		[
			{
				"id": "a1",
				"track": "audio",
				"at_ms": 0,
				"clip": "/a.ogg",
				"fade_in_ms": 400,
				"fade_out_ms": 900,
			}
		]
	)
	assert_int(int(_by_id(t, "a1")["fade_in_ms"])).is_equal(400)
	assert_int(int(_by_id(t, "a1")["fade_out_ms"])).is_equal(900)
	# A cue that was never given one still normalizes to a hard cut, which is what audio always did.
	var plain: Dictionary = _timeline(
		[{"id": "a2", "track": "audio", "at_ms": 0, "clip": "/a.ogg"}]
	)
	assert_int(int(_by_id(plain, "a2")["fade_in_ms"])).is_equal(0)


func test_the_outcome_flags_survive_normalizing() -> void:
	# normalize() builds a FRESH dictionary from the keys it knows, so a field missing from it is dropped
	# on the way through — which is what happened to both of these: the editor wrote them and the save
	# threw them away, with nothing anywhere reporting a problem.
	var t: Dictionary = RoundTimeline.normalize({"won_flag": "beat_her", "lost_flag": "she_won"})
	assert_str(str(t["won_flag"])).is_equal("beat_her")
	assert_str(str(t["lost_flag"])).is_equal("she_won")
	# Normalizing twice is what a save/load round trip does, and it must be a no-op.
	var again: Dictionary = RoundTimeline.normalize(t)
	assert_str(str(again["won_flag"])).is_equal("beat_her")
	assert_str(str(again["lost_flag"])).is_equal("she_won")
	# Blank is the "no flag" case and must not become a flag literally named " ".
	assert_str(str(RoundTimeline.normalize({"won_flag": "  "})["won_flag"])).is_equal("")


func test_the_health_bar_carries_where_it_sits_on_screen() -> void:
	assert_float(float(RoundTimeline.normalize({})["hp_bar_y"])).is_equal_approx(
		RoundTimeline.DEFAULT_HP_BAR_Y, 0.001
	)
	assert_float(float(RoundTimeline.normalize({"hp_bar_y": 0.8})["hp_bar_y"])).is_equal_approx(
		0.8, 0.001
	)
	# Clamped, not trusted: the block places itself off an anchor, and a fraction outside 0..1 would put
	# the boss's name somewhere nothing can scroll to.
	assert_float(float(RoundTimeline.normalize({"hp_bar_y": 4.0})["hp_bar_y"])).is_equal_approx(
		1.0, 0.001
	)
	assert_float(float(RoundTimeline.normalize({"hp_bar_y": -2.0})["hp_bar_y"])).is_equal_approx(
		0.0, 0.001
	)


func test_a_phase_carries_the_health_it_takes_over_at() -> void:
	var t: Dictionary = RoundTimeline.normalize(
		{"phases": [{"id": "p1", "name": "Enraged", "hp_at": 0.4}]}
	)
	assert_float(RoundTimeline.phase_hp_at((t["phases"] as Array)[0], 60000)).is_equal_approx(
		0.4, 0.001
	)


func test_a_phase_authored_on_the_clock_reads_back_as_a_health_point() -> void:
	# No hp_at, so its old at_ms places it: three quarters through a 60s round is a quarter-full bar.
	var phase: Dictionary = RoundTimeline.normalize_phase({"id": "p1", "at_ms": 45000})
	assert_float(RoundTimeline.phase_hp_at(phase, 60000)).is_equal_approx(0.25, 0.001)
	# Length unknown, so it cannot be placed — the opening stage is the safe answer, not a crash.
	assert_float(RoundTimeline.phase_hp_at(phase, 0)).is_equal_approx(1.0, 0.001)


func test_resolved_phases_run_from_full_health_downwards() -> void:
	var t: Dictionary = (
		RoundTimeline
		. normalize(
			{
				"phases":
				[
					{"id": "late", "hp_at": 0.2},
					{"id": "open", "hp_at": 1.0},
					{"id": "mid", "hp_at": 0.6},
				]
			}
		)
	)
	var order: Array = []
	for phase: Dictionary in RoundTimeline.resolved_phases(t, 60000):
		order.append(str(phase["id"]))
	assert_array(order).is_equal(["open", "mid", "late"])


func test_the_pre_rename_defeat_spelling_migrates() -> void:
	# `defeat` meant the PLAYER gave in. Once a boss could itself be defeated the word pointed both ways,
	# so it was renamed — and an encounter authored before that has to keep working untouched.
	var t: Dictionary = _timeline(
		[{"id": "c1", "track": "cast", "at_ms": 0, "text": "You yield.", "on": "defeat"}]
	)
	assert_str(str(_by_id(t, "c1")["on"])).is_equal(RoundTimeline.ON_GAVE_IN)


func test_the_pre_rename_hold_key_migrates() -> void:
	var t: Dictionary = _timeline([_cast("c1", 0)], {"defeat_hold_ms": 2400})
	assert_int(int(t["outcome_hold_ms"])).is_equal(2400)
	# The new spelling wins when both are present — a re-saved encounter carries only the new one.
	var both: Dictionary = _timeline(
		[_cast("c1", 0)], {"defeat_hold_ms": 2400, "outcome_hold_ms": 900}
	)
	assert_int(int(both["outcome_hold_ms"])).is_equal(900)


func test_an_unknown_outcome_mode_falls_back_to_always() -> void:
	var t: Dictionary = _timeline(
		[{"id": "c1", "track": "cast", "at_ms": 0, "text": "x", "on": "exploded"}]
	)
	assert_str(str(_by_id(t, "c1")["on"])).is_equal(RoundTimeline.ON_ALWAYS)


func test_max_attempts_defaults_to_a_single_pass() -> void:
	# ONE is today's behaviour exactly: the round plays once and moves on, whatever the bar reached. An
	# encounter authored before the fight loop existed must not suddenly start replaying itself.
	var t: Dictionary = _timeline([_cast("c1", 0)])
	assert_int(int(t["max_attempts"])).is_equal(RoundTimeline.DEFAULT_MAX_ATTEMPTS)
	assert_bool(RoundTimeline.allows_replay(t)).is_false()


func test_replay_needs_both_score_hp_and_more_than_one_attempt() -> void:
	# A time-based bar refills every pass, so replaying against one is nonsense — it is not a fight, it
	# is the same round twice.
	var time_based: Dictionary = _timeline([_cast("c1", 0)], {"max_attempts": 3})
	assert_bool(RoundTimeline.allows_replay(time_based)).is_false()

	var one_pass: Dictionary = _timeline([_cast("c1", 0)], {"hp_source": "score"})
	assert_bool(RoundTimeline.allows_replay(one_pass)).is_false()

	var fight: Dictionary = _timeline([_cast("c1", 0)], {"hp_source": "score", "max_attempts": 3})
	assert_bool(RoundTimeline.allows_replay(fight)).is_true()


func test_attempts_are_clamped_to_at_least_one() -> void:
	# Zero attempts would be a round that cannot be played at all.
	assert_int(int(_timeline([_cast("c1", 0)], {"max_attempts": 0})["max_attempts"])).is_equal(1)


func test_boss_counters_are_namespaced_per_node() -> void:
	# Two bosses in one journey must not share a health pool, and neither should collide with a counter
	# an author named themselves.
	assert_str(RoundTimeline.damage_counter_key("nd_a")).is_equal("boss_hp:nd_a")
	assert_str(RoundTimeline.attempt_counter_key("nd_a")).is_equal("boss_try:nd_a")
	(
		assert_bool(
			RoundTimeline.damage_counter_key("nd_a") == RoundTimeline.damage_counter_key("nd_b")
		)
		. is_false()
	)


func test_the_new_outcome_modes_are_authorable() -> void:
	# "lost" is deliberately absent: it is a value read on the way IN, not one an author can still write
	# — see test_the_separate_out_of_attempts_ending_folds_into_giving_in.
	for mode: String in [RoundTimeline.ON_WON, RoundTimeline.ON_GAVE_IN]:
		var t: Dictionary = _timeline(
			[{"id": "c1", "track": "cast", "at_ms": 0, "text": "x", "on": mode}]
		)
		assert_str(str(_by_id(t, "c1")["on"])).is_equal(mode)
		# All three fire on the way OUT, so none of them belongs to the timed pass.
		assert_array(RoundTimeline.resolved_events(t, 60000)).is_empty()
		assert_int(RoundTimeline.resolved_events(t, 60000, true).size()).is_equal(1)


func test_is_outcome_event_covers_every_exit() -> void:
	# One predicate, so a fourth exit later does not mean hunting down every hand-written != always.
	for mode: String in [RoundTimeline.ON_WON, RoundTimeline.ON_GAVE_IN]:
		assert_bool(RoundTimeline.is_outcome_event({"on": mode})).is_true()
	# A raw, unnormalized event still reads as an outcome under either retired spelling.
	assert_bool(RoundTimeline.is_outcome_event({"on": RoundTimeline.ON_LOST_LEGACY})).is_true()
	assert_bool(RoundTimeline.is_outcome_event({"on": RoundTimeline.ON_DEFEAT_LEGACY})).is_true()
	assert_bool(RoundTimeline.is_outcome_event({"on": "always"})).is_false()
	assert_bool(RoundTimeline.is_outcome_event({})).is_false()


func test_every_outcome_has_a_label() -> void:
	# The chip on a selected event reads from this; a blank would leave the event looking untyped.
	for mode: String in [RoundTimeline.ON_WON, RoundTimeline.ON_GAVE_IN]:
		assert_bool(RoundTimeline.outcome_label(mode) != "").is_true()
	assert_str(RoundTimeline.outcome_label(RoundTimeline.ON_ALWAYS)).is_equal("")


func test_outcomes_never_appear_on_the_timed_pass() -> void:
	# Whichever way the round ends, none of these sit on the clock — the scheduler must never fire one.
	# "lost" migrates to "gave_in" on the way in and stays an outcome, which is the point of including it.
	var events: Array = []
	for mode: String in ["won", "lost", "gave_in"]:
		events.append({"id": mode, "track": "cast", "at_ms": 500, "text": mode, "on": mode})
	events.append(_cast("timed", 500))
	var t: Dictionary = _timeline(events)
	assert_array(_ids_of(RoundTimeline.resolved_events(t, 60000))).is_equal(["timed"])
	assert_int(RoundTimeline.resolved_events(t, 60000, true).size()).is_equal(3)


func _ids_of(events: Array) -> Array:
	var out: Array = []
	for e: Dictionary in events:
		out.append(str(e["id"]))
	return out


func test_a_stance_window_carries_its_stance() -> void:
	var t: Dictionary = _timeline(
		[{"id": "s1", "track": "stance", "at_ms": 0, "duration_ms": 1000, "stance": "vulnerable"}]
	)
	assert_str(str(_by_id(t, "s1")["stance"])).is_equal(RoundTimeline.STANCE_VULNERABLE)


func test_an_unknown_stance_reads_as_normal() -> void:
	# A typo must never make a boss invincible — the safe fallback is "ordinary", not "immune".
	var t: Dictionary = _timeline(
		[{"id": "s1", "track": "stance", "at_ms": 0, "duration_ms": 1, "stance": "invincibel"}]
	)
	assert_str(str(_by_id(t, "s1")["stance"])).is_equal(RoundTimeline.STANCE_NORMAL)
	assert_float(RoundTimeline.stance_mult("invincibel")).is_equal(1.0)


func test_each_stance_scales_damage_its_own_way() -> void:
	assert_float(RoundTimeline.stance_mult(RoundTimeline.STANCE_NORMAL)).is_equal(1.0)
	assert_float(RoundTimeline.stance_mult(RoundTimeline.STANCE_GUARDED)).is_equal(0.5)
	assert_float(RoundTimeline.stance_mult(RoundTimeline.STANCE_IMMUNE)).is_equal(0.0)
	assert_float(RoundTimeline.stance_mult(RoundTimeline.STANCE_VULNERABLE)).is_equal(2.0)
	# Negative is the whole point of RECOVERING: healing is damage with the sign flipped.
	assert_bool(RoundTimeline.stance_mult(RoundTimeline.STANCE_RECOVERING) < 0.0).is_true()
	# An attack makes her untouchable without an authored window — she must not damage herself with it.
	assert_float(RoundTimeline.stance_mult(RoundTimeline.STANCE_ATTACKING)).is_equal(0.0)


func test_attacking_can_be_authored_as_a_stance() -> void:
	# Not every encounter uses the attack track: a creator can write the boss's moves straight into the
	# round's own funscript, where the strokes ARE the attack and nothing in the engine can detect it.
	# Marking the window is the only way to say so, so it has to survive normalize like any other.
	var t: Dictionary = _timeline(
		[{"id": "s1", "track": "stance", "at_ms": 0, "duration_ms": 2000, "stance": "attacking"}]
	)
	assert_str(str(_by_id(t, "s1")["stance"])).is_equal(RoundTimeline.STANCE_ATTACKING)
	assert_float(RoundTimeline.stance_mult(RoundTimeline.STANCE_ATTACKING)).is_equal(0.0)


func test_attacking_is_its_own_word_even_though_it_is_the_same_zero() -> void:
	# Mechanically identical to IMMUNE, but "she is doing something to you" and "she is turtling" are
	# different things for a player to learn.
	(
		assert_bool(
			(
				RoundTimeline.stance_label(RoundTimeline.STANCE_ATTACKING)
				== RoundTimeline.stance_label(RoundTimeline.STANCE_IMMUNE)
			)
		)
		. is_false()
	)


func test_every_stance_has_a_label() -> void:
	for stance: String in RoundTimeline.STANCES:
		assert_bool(RoundTimeline.stance_label(stance) != "").is_true()


func test_the_last_open_stance_wins() -> void:
	# Validation holds stances to one at a time, so this only decides what happens when an author
	# overlapped them anyway. The later block is the one drawn on top, so it is the one that applies.
	assert_str(RoundTimeline.active_stance([])).is_equal(RoundTimeline.STANCE_NORMAL)
	(
		assert_str(RoundTimeline.active_stance([{"stance": "guarded"}, {"stance": "vulnerable"}]))
		. is_equal(RoundTimeline.STANCE_VULNERABLE)
	)


func test_overlapping_stances_are_reported() -> void:
	var t: Dictionary = _timeline(
		[
			{"id": "s1", "track": "stance", "at_ms": 0, "duration_ms": 2000, "stance": "guarded"},
			{"id": "s2", "track": "stance", "at_ms": 1000, "duration_ms": 2000, "stance": "immune"},
		]
	)
	var codes: Array = []
	for issue: Dictionary in RoundTimeline.validate(t, 60000):
		codes.append(str(issue["code"]))
	assert_bool(codes.has(RoundTimeline.ISSUE_STANCE_OVERLAP)).is_true()


func test_stances_that_do_not_overlap_are_fine() -> void:
	var t: Dictionary = _timeline(
		[
			{"id": "s1", "track": "stance", "at_ms": 0, "duration_ms": 1000, "stance": "guarded"},
			{"id": "s2", "track": "stance", "at_ms": 1000, "duration_ms": 1000, "stance": "immune"},
		]
	)
	for issue: Dictionary in RoundTimeline.validate(t, 60000):
		assert_str(str(issue["code"])).is_not_equal(RoundTimeline.ISSUE_STANCE_OVERLAP)


func test_regeneration_is_off_until_an_author_turns_it_on() -> void:
	var t: Dictionary = RoundTimeline.normalize({})
	assert_int(int(t["pause_regen_per_sec"])).is_equal(0)
	assert_float(float(t["attempt_regen_pct"])).is_equal(0.0)


func test_attempt_regeneration_is_a_fraction_of_the_bar() -> void:
	(
		assert_float(
			float(RoundTimeline.normalize({"attempt_regen_pct": 0.25})["attempt_regen_pct"])
		)
		. is_equal_approx(0.25, 0.001)
	)
	# Clamped: more than a full bar back is meaningless, and negative would deal damage between passes.
	(
		assert_float(
			float(RoundTimeline.normalize({"attempt_regen_pct": 4.0})["attempt_regen_pct"])
		)
		. is_equal_approx(1.0, 0.001)
	)
	(
		assert_float(
			float(RoundTimeline.normalize({"attempt_regen_pct": -1.0})["attempt_regen_pct"])
		)
		. is_equal_approx(0.0, 0.001)
	)


func test_expected_pass_score_matches_the_scoring_rule() -> void:
	# Deterministic on purpose: scoring runs as the SCRIPT advances, so this is exactly what the round
	# deals every time — not an estimate of a good run.
	var scoring: Dictionary = {
		"small_max": 20, "medium_max": 70, "small_pts": 1, "medium_pts": 3, "large_pts": 5
	}
	# Amplitudes 90 (large), 50 (medium), 10 (small) → 5 + 3 + 1. The big stroke runs DOWNWARD: a
	# 90-wide upstroke will not fit inside the 0-100 range alongside the other two.
	var points: Array = [Vector2(0, 95), Vector2(100, 5), Vector2(200, 55), Vector2(300, 45)]
	assert_int(RoundTimeline.expected_pass_score(points, scoring)).is_equal(9)


func test_expected_pass_score_needs_two_points() -> void:
	# A video-only round has no script to score, and one lone action is not a stroke.
	var scoring: Dictionary = {"small_max": 20, "medium_max": 70}
	assert_int(RoundTimeline.expected_pass_score([], scoring)).is_equal(0)
	assert_int(RoundTimeline.expected_pass_score([Vector2(0, 50)], scoring)).is_equal(0)


func test_expected_pass_score_reads_the_thresholds_it_is_given() -> void:
	# The thresholds come from ScoreService rather than being repeated in the model, so retuning the
	# score cannot silently invalidate a boss an author already balanced.
	var points: Array = [Vector2(0, 0), Vector2(100, 30)]
	(
		assert_int(RoundTimeline.expected_pass_score(points, {"small_max": 50, "small_pts": 1}))
		. is_equal(1)
	)
	(
		assert_int(
			RoundTimeline.expected_pass_score(
				points, {"small_max": 10, "medium_max": 70, "medium_pts": 3}
			)
		)
		. is_equal(3)
	)


func test_direction_does_not_change_the_score() -> void:
	# Amplitude is a distance: a downstroke is worth what the matching upstroke is worth.
	var scoring: Dictionary = {"small_max": 20, "medium_max": 70, "medium_pts": 3}
	var up: Array = [Vector2(0, 10), Vector2(100, 60)]
	var down: Array = [Vector2(0, 60), Vector2(100, 10)]
	assert_int(RoundTimeline.expected_pass_score(up, scoring)).is_equal(
		RoundTimeline.expected_pass_score(down, scoring)
	)


func test_no_win_jump_by_default() -> void:
	# Every encounter authored before the jump existed simply plays out.
	var t: Dictionary = _timeline([_cast("c1", 0)])
	assert_int(int(t["win_jump_ms"])).is_equal(RoundTimeline.NO_TIME)
	assert_int(RoundTimeline.win_jump_at_ms(t, 60000)).is_equal(RoundTimeline.NO_TIME)


func test_a_win_jump_is_end_anchored_by_default() -> void:
	# "Skip to the last 10 seconds" is a distance from the END, so it survives the clip being re-cut.
	var t: Dictionary = _timeline([_cast("c1", 0)], {"win_jump_ms": 10000})
	assert_str(str(t["win_jump_anchor"])).is_equal(RoundTimeline.ANCHOR_END)
	assert_int(RoundTimeline.win_jump_at_ms(t, 60000)).is_equal(50000)


func test_a_start_anchored_win_jump_is_absolute() -> void:
	var t: Dictionary = _timeline(
		[_cast("c1", 0)], {"win_jump_ms": 12000, "win_jump_anchor": "start"}
	)
	assert_int(RoundTimeline.win_jump_at_ms(t, 60000)).is_equal(12000)


func test_an_unplaceable_win_jump_reports_no_time() -> void:
	# Further from the end than the round is long: the caller skips rather than seeking somewhere odd.
	var t: Dictionary = _timeline([_cast("c1", 0)], {"win_jump_ms": 90000})
	assert_int(RoundTimeline.win_jump_at_ms(t, 60000)).is_equal(RoundTimeline.NO_TIME)
