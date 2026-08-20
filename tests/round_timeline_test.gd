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
	assert_bool(bool(cue["loop"])).is_false()  # an attack hit plays once, not on a loop


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


func test_condition_is_carried_verbatim_for_the_reactive_seam() -> void:
	# v1 never interprets `condition`, but a journey authored by a future build must round-trip here
	# without losing it.
	var t: Dictionary = _timeline(
		[{"id": "c1", "track": "cast", "image": "/a.png", "condition": {"phase": "p2"}}]
	)
	assert_str(str((_by_id(t, "c1")["condition"] as Dictionary)["phase"])).is_equal("p2")


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


func test_cast_text_timings_appear_only_with_text() -> void:
	var silent: Dictionary = _by_id(_timeline([_cast("c1", 0)]), "c1")
	assert_bool(silent.has("text_hold_ms")).is_false()  # no subtitle → no subtitle timing

	var spoken: Dictionary = _by_id(
		_timeline([{"id": "c2", "track": "cast", "image": "/a.png", "text": "You are mine."}]), "c2"
	)
	assert_str(str(spoken["text"])).is_equal("You are mine.")
	assert_int(int(spoken["text_hold_ms"])).is_equal(RoundTimeline.DEFAULT_TEXT_HOLD_MS)


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


func test_defeat_events_are_split_out_of_the_normal_pass() -> void:
	var t: Dictionary = _timeline(
		[
			_cast("normal", 1000),
			{"id": "defeat", "track": "cast", "at_ms": 0, "on": "defeat", "image": "/a.png"},
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
