extends GdUnitTestSuite

# The cast's shared animations (CastMotion), and the three places that store them: boss CAST cues, storyboard
# stages and mini-game characters.

const STAGE: Vector2 = Vector2(1280.0, 720.0)
const SETTLE_MS: int = 1100  # longer than any entrance, exit or change (Silhouette is the longest)


func _art() -> Control:
	var art: Control = auto_free(Control.new())
	add_child(art)
	art.size = Vector2(200.0, 300.0)
	art.position = Vector2(400.0, 200.0)
	return art


# At rest after a motion that doesn't hold, or held in the pose of one that does.
func _assert_settled(art: Control, motion: String) -> void:
	if motion == CastMotion.SILHOUETTE:
		assert_str(CastMotion.held(art)).is_equal(motion)
		assert_bool(art.material is ShaderMaterial).is_true()
		assert_bool(art.scale.is_equal_approx(Vector2.ONE)).is_true()
	elif motion == CastMotion.LEAN_IN:
		assert_str(CastMotion.held(art)).is_equal(motion)
		assert_bool(art.scale.is_equal_approx(Vector2.ONE * CastMotion.LEAN_HELD_SCALE)).is_true()
		assert_object(art.material).is_null()
	else:
		_assert_at_rest(art)
	assert_bool(art.position.is_equal_approx(Vector2(400.0, 200.0))).is_true()
	assert_float(art.modulate.a).is_equal_approx(1.0, 0.0001)


func _assert_at_rest(art: Control) -> void:
	assert_str(CastMotion.held(art)).is_empty()
	assert_bool(art.position.is_equal_approx(Vector2(400.0, 200.0))).is_true()
	assert_bool(art.scale.is_equal_approx(Vector2.ONE)).is_true()
	assert_float(art.rotation).is_equal_approx(0.0, 0.0001)
	assert_float(art.modulate.a).is_equal_approx(1.0, 0.0001)
	assert_object(art.material).is_null()  # Silhouette and Wipe take their shader off again


# ── Names ────────────────────────────────────────────────────────────────────


func test_every_motion_has_a_name() -> void:
	for motion: String in CastMotion.ALL:
		assert_bool(CastMotion.NAMES.has(motion)).is_true()


func test_old_names_read_as_their_shared_ones() -> void:
	assert_str(CastMotion.normalize("flash", CastMotion.FADE)).is_equal(CastMotion.CUT)
	assert_str(CastMotion.normalize("slide", CastMotion.FADE)).is_equal(CastMotion.SLIDE_LEFT)
	assert_str(CastMotion.normalize("Spin", CastMotion.FADE)).is_equal(CastMotion.SPIN)
	assert_str(CastMotion.normalize("explode", CastMotion.FADE)).is_equal(CastMotion.FADE)
	assert_str(CastMotion.normalize(null, CastMotion.CUT)).is_equal(CastMotion.CUT)


func test_slides_and_rises_travel_from_their_side() -> void:
	assert_float(CastMotion.travel(CastMotion.SLIDE_LEFT, STAGE).x).is_less(0.0)
	assert_float(CastMotion.travel(CastMotion.SLIDE_RIGHT, STAGE).x).is_greater(0.0)
	assert_float(CastMotion.travel(CastMotion.SLIDE_TOP, STAGE).y).is_less(0.0)
	assert_float(CastMotion.travel(CastMotion.SLIDE_BOTTOM, STAGE).y).is_greater(0.0)
	assert_float(CastMotion.travel(CastMotion.RISE, STAGE).y).is_greater(0.0)
	assert_float(CastMotion.travel(CastMotion.DROP, STAGE).y).is_less(0.0)  # falls in from above
	assert_bool(CastMotion.travel(CastMotion.FADE, STAGE) == Vector2.ZERO).is_true()


# ── Playing ──────────────────────────────────────────────────────────────────


# Every motion plays at once on its own art, so the suite waits once rather than once per motion.
func test_every_entrance_ends_at_rest_or_held() -> void:
	var arts: Array[Control] = []
	for motion: String in CastMotion.ALL:
		arts.append(_art())
		CastMotion.enter(arts.back(), motion, STAGE)
	await await_millis(SETTLE_MS)
	for index: int in arts.size():
		_assert_settled(arts[index], CastMotion.ALL[index])


func test_a_cut_entrance_has_nothing_to_animate() -> void:
	assert_object(CastMotion.enter(_art(), CastMotion.CUT, STAGE)).is_null()


func test_every_exit_calls_back_once_and_leaves_the_art_ready_to_show_again() -> void:
	var arts: Array[Control] = []
	var calls: Array[int] = []
	for motion: String in CastMotion.ALL:
		var index: int = arts.size()
		arts.append(_art())
		calls.append(0)
		CastMotion.exit(arts.back(), motion, STAGE, func() -> void: calls[index] += 1)
	await await_millis(SETTLE_MS)
	for index: int in arts.size():
		assert_int(calls[index]).override_failure_message(CastMotion.ALL[index]).is_equal(1)
		_assert_at_rest(arts[index])


func test_every_change_swaps_exactly_once_and_ends_at_rest_or_held() -> void:
	var arts: Array[Control] = []
	var swaps: Array[int] = []
	for motion: String in CastMotion.ALL:
		var index: int = arts.size()
		arts.append(_art())
		swaps.append(0)
		CastMotion.change(arts.back(), motion, STAGE, func() -> void: swaps[index] += 1)
	await await_millis(SETTLE_MS)
	for index: int in arts.size():
		assert_int(swaps[index]).override_failure_message(CastMotion.ALL[index]).is_equal(1)
		_assert_settled(arts[index], CastMotion.ALL[index])


# A storyboard line can arrive before the last one's animation is done: the new one starts from rest.
func test_starting_again_mid_animation_puts_the_art_back_first() -> void:
	var art: Control = _art()
	var calls: Array[int] = [0]
	CastMotion.exit(art, CastMotion.SLIDE_LEFT, STAGE, func() -> void: calls[0] += 1)
	await await_idle_frame()
	CastMotion.enter(art, CastMotion.CUT, STAGE)
	_assert_at_rest(art)
	await await_millis(SETTLE_MS)
	assert_int(calls[0]).is_equal(0)  # the exit was overtaken, so whatever it would have hidden stays


# Silhouette and Wipe draw the art's children through their shader, then hand back what the art had: an additive
# boss cue stays additive. A silhouette keeps it until it's released.
func test_silhouette_and_wipe_put_back_the_art_material_and_its_children() -> void:
	for motion: String in [CastMotion.SILHOUETTE, CastMotion.WIPE]:
		var art: Control = _art()
		var additive: CanvasItemMaterial = CanvasItemMaterial.new()
		additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		art.material = additive
		var picture: TextureRect = TextureRect.new()
		art.add_child(picture)
		CastMotion.enter(art, motion, STAGE)
		assert_bool(art.material is ShaderMaterial).is_true()
		assert_bool(picture.use_parent_material).is_true()
		await await_millis(SETTLE_MS)
		CastMotion.release(art)  # nothing to release after a wipe
		await await_millis(SETTLE_MS)
		assert_object(art.material).override_failure_message(motion).is_same(additive)
		assert_bool(picture.use_parent_material).is_false()


# A new picture arrives as new children partway through a Silhouette change; it's drawn black too, not in full colour.
func test_a_silhouette_change_covers_the_new_picture() -> void:
	var art: Control = _art()
	var seen: Array[bool] = [false]
	var swap: Callable = func() -> void:
		var picture: TextureRect = TextureRect.new()
		art.add_child(picture)
		seen[0] = true
	CastMotion.change(art, CastMotion.SILHOUETTE, STAGE, swap)
	await await_millis(400)
	assert_bool(seen[0]).is_true()
	assert_bool((art.get_child(0) as CanvasItem).use_parent_material).is_true()


# ── Holds ────────────────────────────────────────────────────────────────────


func test_only_silhouette_and_lean_in_hold() -> void:
	for motion: String in CastMotion.ALL:
		assert_bool(CastMotion.holds(motion)).override_failure_message(motion).is_equal(
			motion in [CastMotion.SILHOUETTE, CastMotion.LEAN_IN]
		)


# Asked for another motion, a held character is released first (colour fills in), then the change plays.
func test_a_different_reaction_releases_the_hold_then_plays() -> void:
	var art: Control = _art()
	CastMotion.enter(art, CastMotion.SILHOUETTE, STAGE)
	await await_millis(SETTLE_MS)
	var swaps: Array[int] = [0]
	CastMotion.change(art, CastMotion.FADE, STAGE, func() -> void: swaps[0] += 1)
	await await_idle_frame()
	assert_int(swaps[0]).is_equal(0)  # still releasing
	await await_millis(SETTLE_MS)
	assert_int(swaps[0]).is_equal(1)
	_assert_at_rest(art)


# Asked for the held motion again (a new expression, still in shadow), it swaps and keeps holding.
func test_the_same_reaction_swaps_and_keeps_holding() -> void:
	var art: Control = _art()
	CastMotion.enter(art, CastMotion.LEAN_IN, STAGE)
	await await_millis(SETTLE_MS)
	var swaps: Array[int] = [0]
	CastMotion.change(art, CastMotion.LEAN_IN, STAGE, func() -> void: swaps[0] += 1)
	assert_int(swaps[0]).is_equal(1)
	assert_str(CastMotion.held(art)).is_equal(CastMotion.LEAN_IN)
	assert_bool(art.scale.is_equal_approx(Vector2.ONE * CastMotion.LEAN_HELD_SCALE)).is_true()


func test_a_cut_change_also_ends_a_hold() -> void:
	var art: Control = _art()
	CastMotion.enter(art, CastMotion.LEAN_IN, STAGE)
	await await_millis(SETTLE_MS)
	var swaps: Array[int] = [0]
	CastMotion.change(art, CastMotion.CUT, STAGE, func() -> void: swaps[0] += 1)
	await await_millis(SETTLE_MS)
	assert_int(swaps[0]).is_equal(1)
	_assert_at_rest(art)


func test_an_exit_leaves_from_the_hold_and_clears_it() -> void:
	var art: Control = _art()
	CastMotion.enter(art, CastMotion.SILHOUETTE, STAGE)
	await await_millis(SETTLE_MS)
	var calls: Array[int] = [0]
	CastMotion.exit(art, CastMotion.SLIDE_LEFT, STAGE, func() -> void: calls[0] += 1)
	await await_millis(SETTLE_MS)
	assert_int(calls[0]).is_equal(1)
	_assert_at_rest(art)


# Stopped partway (a storyboard line overtaking it), held art goes back to its held pose, not to plain rest.
func test_stopping_keeps_the_hold() -> void:
	var art: Control = _art()
	CastMotion.enter(art, CastMotion.SILHOUETTE, STAGE)
	await await_idle_frame()
	CastMotion.stop(art)
	assert_str(CastMotion.held(art)).is_equal(CastMotion.SILHOUETTE)
	assert_bool(art.material is ShaderMaterial).is_true()
	(
		assert_float(float((art.material as ShaderMaterial).get_shader_parameter("silhouette")))
		. is_equal(1.0)
	)


func test_an_entrance_starts_from_no_hold() -> void:
	var art: Control = _art()
	CastMotion.enter(art, CastMotion.LEAN_IN, STAGE)
	await await_millis(SETTLE_MS)
	CastMotion.enter(art, CastMotion.CUT, STAGE)
	_assert_at_rest(art)


func test_stop_is_safe_on_art_at_rest() -> void:
	var art: Control = _art()
	CastMotion.stop(art)
	_assert_at_rest(art)


# ── Where they're stored ─────────────────────────────────────────────────────


func test_a_stage_entry_keeps_its_entrance_and_exit() -> void:
	var stage: Array = (
		JourneyData
		. clean_stage(
			[
				{"character": "chr_a", "enter": "pop", "exit": "slide_right"},
				{"character": "chr_b", "enter": "cut", "exit": "wobble"},
			]
		)
	)
	assert_str(str(stage[0]["enter"])).is_equal(CastMotion.POP)
	assert_str(str(stage[0]["exit"])).is_equal(CastMotion.SLIDE_RIGHT)
	# A Cut is the default, so it isn't stored, and an unknown name falls back to it.
	assert_bool((stage[1] as Dictionary).has("enter")).is_false()
	assert_bool((stage[1] as Dictionary).has("exit")).is_false()


func test_a_boss_cue_reads_flash_as_a_cut_and_exits_with_a_fade_by_default() -> void:
	var cue: Dictionary = RoundTimeline.normalize_event(
		{"id": "c1", "track": "cast", "at_ms": 0, "image": "/a.png", "transition": "flash"}
	)
	assert_str(str(cue["transition"])).is_equal(CastMotion.CUT)
	assert_str(str(cue["exit_transition"])).is_equal(CastMotion.FADE)


func test_a_boss_cue_keeps_a_chosen_exit() -> void:
	var cue: Dictionary = RoundTimeline.normalize_event(
		{"id": "c1", "track": "cast", "at_ms": 0, "image": "/a.png", "exit_transition": "spin"}
	)
	assert_str(str(cue["exit_transition"])).is_equal(CastMotion.SPIN)


func test_a_game_character_moment_keeps_any_motion_from_the_shared_set() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(SafeCrackerGame.KIND)
	definition["game_character"] = {
		"character": "chr_a",
		"moments": {"idle": {"transition": "slide_top"}, "wrong": {"transition": "flash"}},
	}
	var loaded: Dictionary = MiniGameLibrary.normalize_definition(definition)
	var moments: Dictionary = loaded["game_character"]["moments"]
	assert_str(str(moments["idle"]["transition"])).is_equal(CastMotion.SLIDE_TOP)
	assert_str(str(moments["wrong"]["transition"])).is_equal(CastMotion.CUT)
