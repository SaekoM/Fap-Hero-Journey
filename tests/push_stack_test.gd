extends GdUnitTestSuite

# Push Your Luck's stack looks, and the moments its staging reads from the game.

# Little risk, only value tokens, and a range wide enough to tell a high draw from a low one.
const SAFE: Dictionary = {
	"value_tokens": 10, "traps": 1, "shields": 0, "doublers": 0, "base_gain": 100, "gain_growth": 0
}


func _survived_push(knobs: Dictionary, wanted_big: bool) -> PushYourLuckGame:
	for seed_value: int in 1000:
		var game: PushYourLuckGame = PushYourLuckGame.new(knobs, seed_value)
		if game.push() and game.was_big_draw() == wanted_big:
			return game
	return null


func test_each_style_has_its_own_art() -> void:
	assert_object(StackArt.art_for(StackArt.STYLE_CHIPS)).is_instanceof(ChipsStackArt)
	assert_object(StackArt.art_for(StackArt.STYLE_COINS)).is_instanceof(CoinsStackArt)
	assert_object(StackArt.art_for(StackArt.STYLE_BLOCKS)).is_instanceof(BlocksStackArt)


func test_an_unknown_style_falls_back_to_chips() -> void:
	assert_object(StackArt.art_for("cards")).is_instanceof(ChipsStackArt)


func test_every_style_has_a_name() -> void:
	for style: String in StackArt.STYLES:
		assert_bool(StackArt.STYLE_NAMES.has(style)).is_true()


# So a stack of the most pieces always fits the stage.
func test_a_full_stack_of_any_look_fits_the_stage() -> void:
	var ranges: Dictionary = PushYourLuckGame.KNOB_RANGES
	var most: int = (
		int(ranges["value_tokens"][1]) + int(ranges["shields"][1]) + int(ranges["doublers"][1]) + 1
	)
	for style: String in StackArt.STYLES:
		var art: StackArt = StackArt.art_for(style)
		var height: float = most * (art.piece_height() + PushStackStage.PIECE_GAP)
		assert_bool(height < PushStackStage.STAGE_HEIGHT - PushStackStage.TABLE_HEIGHT).is_true()


func test_shields_and_doublers_have_their_own_colours() -> void:
	var plain: Color = Color(0.5, 0.2, 0.7)
	var shield: Color = StackArt.kind_colour(PushYourLuckGame.TOKEN_SHIELD, plain)
	var doubler: Color = StackArt.kind_colour(PushYourLuckGame.TOKEN_DOUBLER, plain)
	assert_bool(StackArt.kind_colour(PushYourLuckGame.TOKEN_VALUE, plain) == plain).is_true()
	assert_bool(shield != plain and doubler != plain and shield != doubler).is_true()
	var spent: Color = StackArt.kind_colour(StackArt.KIND_SPENT_SHIELD, plain)
	assert_bool(spent != shield and spent != plain).is_true()
	# Coins are gold, so neither may be.
	assert_bool(shield != StackArt.GOLD and doubler != StackArt.GOLD).is_true()


func test_a_blocked_trap_cracks_the_highest_whole_shield() -> void:
	var stage: PushStackStage = auto_free(PushStackStage.new())
	stage.art = StackArt.art_for(StackArt.STYLE_CHIPS)
	stage.size = Vector2(240.0, PushStackStage.STAGE_HEIGHT)
	add_child(stage)  # its tweens need the scene tree
	stage.land_piece(PushYourLuckGame.TOKEN_SHIELD)
	stage.land_piece(PushYourLuckGame.TOKEN_SHIELD)
	stage.hover_piece(0.05)
	stage.block_trap()
	assert_array(Array(stage._kinds)).contains_exactly(
		[PushYourLuckGame.TOKEN_VALUE, PushYourLuckGame.TOKEN_SHIELD, StackArt.KIND_SPENT_SHIELD]
	)
	stage.hover_piece(0.05)
	stage.block_trap()
	assert_array(Array(stage._kinds)).contains_exactly(
		[PushYourLuckGame.TOKEN_VALUE, StackArt.KIND_SPENT_SHIELD, StackArt.KIND_SPENT_SHIELD]
	)


func test_a_falling_stack_moves_away_from_where_it_stood() -> void:
	for style: String in StackArt.STYLES:
		var art: StackArt = StackArt.art_for(style)
		assert_bool(art.fall(3, 5, 0.0) == Vector3.ZERO).is_true()
		assert_bool(art.fall(3, 5, 1.0).y > 0.0).is_true()


func test_a_big_draw_is_near_the_top_of_its_range() -> void:
	var big: PushYourLuckGame = _survived_push(SAFE, true)
	var ordinary: PushYourLuckGame = _survived_push(SAFE, false)
	assert_bool(big.last_gain > ordinary.last_gain).is_true()
	# An average of 100 draws from 50 to 150, and the top quarter starts at 125.
	assert_bool(big.last_gain >= 125).is_true()
	assert_bool(ordinary.last_gain < 125).is_true()


func test_a_game_with_no_push_yet_has_no_news() -> void:
	var game: PushYourLuckGame = PushYourLuckGame.new(SAFE, 1)
	assert_bool(game.was_big_draw()).is_false()
	assert_bool(game.was_close_call()).is_false()


func test_a_close_call_is_surviving_at_half_risk_or_more() -> void:
	var risky: Dictionary = {"value_tokens": 2, "traps": 10, "shields": 0, "doublers": 0}
	for seed_value: int in 1000:
		var game: PushYourLuckGame = PushYourLuckGame.new(risky, seed_value)
		if game.push():
			assert_bool(game.was_close_call()).is_true()
			break
	var calm: PushYourLuckGame = _survived_push(SAFE, true)
	assert_bool(calm.was_close_call()).is_false()


func test_the_look_survives_the_library() -> void:
	var definition: Dictionary = MiniGameLibrary.new_definition(PushYourLuckGame.KIND)
	assert_str(definition["stack"]).is_equal(StackArt.DEFAULT_STYLE)
	definition["stack"] = StackArt.STYLE_BLOCKS
	var loaded: Dictionary = MiniGameLibrary.normalize_definition(definition)
	assert_str(loaded["stack"]).is_equal(StackArt.STYLE_BLOCKS)
	definition["stack"] = "cards"
	var damaged: Dictionary = MiniGameLibrary.normalize_definition(definition)
	assert_str(damaged["stack"]).is_equal(StackArt.DEFAULT_STYLE)


# Every look draws standing, hovering, landing, falling, swept and gold. Nothing here reads the picture: it's here so a
# draw call the engine refuses shows up as an error in the run.
func test_every_look_draws_in_every_state() -> void:
	for style: String in StackArt.STYLES:
		var stage: PushStackStage = auto_free(PushStackStage.new())
		stage.art = StackArt.art_for(style)
		stage.most_pieces = 16
		stage.sway_share = 1.0
		stage.size = Vector2(240.0, PushStackStage.STAGE_HEIGHT)
		add_child(stage)
		await await_idle_frame()
		stage.hover_piece(0.05)
		await await_idle_frame()
		stage.land_piece()
		await await_idle_frame()
		stage.land_piece(PushYourLuckGame.TOKEN_SHIELD)
		await await_idle_frame()
		stage.land_piece(PushYourLuckGame.TOKEN_DOUBLER)
		await await_idle_frame()
		stage.shields_up = 3
		stage.hover_piece(0.05)
		stage.block_trap()
		await await_idle_frame()
		stage.turn_gold()
		await await_idle_frame()
		stage.sweep_to(Vector2(400.0, 20.0))
		await await_idle_frame()
		stage.topple()
		await await_idle_frame()
		remove_child(stage)
