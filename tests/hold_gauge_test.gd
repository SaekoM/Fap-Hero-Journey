extends GdUnitTestSuite

# Hold & Release's containers: each style exists and reads as a gauge, and drawing one in every state doesn't fail.

const AREA: Vector2 = Vector2(584.0, GaugeArt.AREA_HEIGHT)


func test_each_style_has_its_own_art() -> void:
	assert_object(GaugeArt.art_for(GaugeArt.STYLE_TUBE)).is_instanceof(TubeGaugeArt)
	assert_object(GaugeArt.art_for(GaugeArt.STYLE_BOTTLE)).is_instanceof(BottleGaugeArt)
	assert_object(GaugeArt.art_for(GaugeArt.STYLE_THERMOMETER)).is_instanceof(ThermometerGaugeArt)
	assert_object(GaugeArt.art_for(GaugeArt.STYLE_DIAL)).is_instanceof(DialGaugeArt)
	assert_object(GaugeArt.art_for(GaugeArt.STYLE_HEART)).is_instanceof(HeartGaugeArt)


func test_an_unknown_style_falls_back_to_the_tube() -> void:
	assert_object(GaugeArt.art_for("balloon")).is_instanceof(TubeGaugeArt)


func test_every_style_has_a_name() -> void:
	for style: String in GaugeArt.STYLES:
		assert_bool(GaugeArt.STYLE_NAMES.has(style)).is_true()


func test_a_fuller_upright_container_reaches_higher() -> void:
	var upright: Array[String] = [
		GaugeArt.STYLE_TUBE,
		GaugeArt.STYLE_BOTTLE,
		GaugeArt.STYLE_THERMOMETER,
		GaugeArt.STYLE_HEART,
	]
	for style: String in upright:
		var art: GaugeArt = GaugeArt.art_for(style)
		assert_bool(art.level_point(AREA, 0.8).y < art.level_point(AREA, 0.2).y).is_true()


func test_a_heart_comes_to_a_point_and_divides_above_its_cleft() -> void:
	var heart: HeartGaugeArt = GaugeArt.art_for(GaugeArt.STYLE_HEART)
	assert_bool(heart._half_width_at(0.0) < heart._half_width_at(0.5)).is_true()
	assert_float(heart._inner_half_width_at(0.5)).is_equal(0.0)
	assert_bool(heart._inner_half_width_at(0.9) > 0.0).is_true()
	assert_bool(heart._inner_half_width_at(0.9) < heart._half_width_at(0.9)).is_true()


# The two halves of a broken heart meet along the same jagged edge, with no overlap and no gap between them.
func test_a_broken_hearts_halves_fit_together() -> void:
	var heart: HeartGaugeArt = GaugeArt.art_for(GaugeArt.STYLE_HEART)
	var left: Vector2 = heart.half_span_at(0.3, -1.0)
	var right: Vector2 = heart.half_span_at(0.3, 1.0)
	assert_float(left.y).is_equal(right.x)
	assert_bool(left.x < left.y and right.x < right.y).is_true()


# Above the cleft each half is one lobe, on its own side.
func test_a_broken_hearts_lobes_stay_on_their_own_sides() -> void:
	var heart: HeartGaugeArt = GaugeArt.art_for(GaugeArt.STYLE_HEART)
	assert_bool(heart.half_span_at(0.9, -1.0).y < 0.0).is_true()
	assert_bool(heart.half_span_at(0.9, 1.0).x > 0.0).is_true()


func test_the_warning_quickens_with_danger() -> void:
	for style: String in GaugeArt.STYLES:
		var art: GaugeArt = GaugeArt.art_for(style)
		assert_bool(art.danger_sound_gap(1.0) < art.danger_sound_gap(0.0)).is_true()


func test_the_dial_sweeps_clockwise_over_the_top() -> void:
	var art: GaugeArt = GaugeArt.art_for(GaugeArt.STYLE_DIAL)
	var centre_x: float = AREA.x / 2.0
	assert_bool(art.level_point(AREA, 0.0).x < centre_x).is_true()
	assert_float(art.level_point(AREA, 0.5).x).is_equal_approx(centre_x, 0.01)
	assert_bool(art.level_point(AREA, 1.0).x > centre_x).is_true()


func test_danger_builds_towards_the_top_edge_and_stays_past_it() -> void:
	var stage: HoldGaugeStage = auto_free(HoldGaugeStage.new())
	stage.zone_top = 0.7
	stage.filling = true
	stage.level = 0.5
	assert_float(stage.danger()).is_equal(0.0)
	stage.level = 0.65
	assert_bool(stage.danger() > 0.0 and stage.danger() < 1.0).is_true()
	stage.level = 0.9
	assert_float(stage.danger()).is_equal(1.0)


func test_letting_go_ends_the_danger() -> void:
	var stage: HoldGaugeStage = auto_free(HoldGaugeStage.new())
	stage.zone_top = 0.7
	stage.level = 0.7
	assert_float(stage.danger()).is_equal(0.0)


# A burst has to finish before the next turn clears it, or the end of its tween would bring it back.
func test_a_burst_is_over_before_the_next_turn() -> void:
	assert_bool(HoldGaugeStage.BURST_SECS < TurnGameView.LANDED_HOLD_SECS).is_true()


func test_the_container_survives_the_library() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(HoldReleaseGame.KIND)
	assert_str(definition["container"]).is_equal(GaugeArt.DEFAULT_STYLE)
	definition["container"] = GaugeArt.STYLE_DIAL
	var loaded: Dictionary = MiniGameLibrary.normalize_definition(definition)
	assert_str(loaded["container"]).is_equal(GaugeArt.STYLE_DIAL)
	definition["container"] = "balloon"
	var damaged: Dictionary = MiniGameLibrary.normalize_definition(definition)
	assert_str(damaged["container"]).is_equal(GaugeArt.DEFAULT_STYLE)


# Every container draws at empty, mid, past the zone and burst, with a ghost and a flash. Nothing here reads the
# picture: it's here so a draw call the engine refuses shows up as an error in the run.
func test_every_container_draws_in_every_state() -> void:
	for style: String in GaugeArt.STYLES:
		var stage: HoldGaugeStage = auto_free(HoldGaugeStage.new())
		stage.art = GaugeArt.art_for(style)
		stage.size = AREA
		stage.accent = Color.WHITE
		add_child(stage)
		for level: float in [0.0, 0.5, 0.9, 1.0]:
			stage.level = level
			stage.filling = level > 0.0
			stage.ghost = level
			stage.flash = 0.5
			stage.wobble = 0.5
			stage.ripple = 0.5
			stage.queue_redraw()
			await await_idle_frame()
		stage.burst = 0.5
		stage.missed = true
		stage.queue_redraw()
		await await_idle_frame()
		remove_child(stage)
