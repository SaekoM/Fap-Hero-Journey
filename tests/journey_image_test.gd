extends GdUnitTestSuite

# JourneyImage.STRETCH_FIT_HEIGHT — the cast-portrait fit. Every expression fills its box's HEIGHT at its
# own aspect, stands on the box's bottom edge, and is clipped at the sides when wider than the box. Real
# PNGs written to user:// so show_path takes its normal path; the control is placed in the tree with a
# fixed size so layout is deterministic.

const EPS := 0.5  # pixels
const WIDE := "user://_jimg_test_wide.png"  # 140 x 100
const TALL := "user://_jimg_test_tall.png"  # 60 x 100


func before() -> void:
	Image.create(140, 100, false, Image.FORMAT_RGBA8).save_png(WIDE)
	Image.create(60, 100, false, Image.FORMAT_RGBA8).save_png(TALL)


func after() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(WIDE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TALL))


func _framed(
	path: String, frame: Vector2, mode: int = JourneyImage.STRETCH_FIT_HEIGHT
) -> JourneyImage:
	var view: JourneyImage = auto_free(JourneyImage.new())
	add_child(view)
	view.size = frame
	assert_bool(view.show_path(path, TextureRect.EXPAND_IGNORE_SIZE, mode)).is_true()
	return view


func test_wide_expression_fills_the_height_and_is_clipped_at_the_sides() -> void:
	var view := _framed(WIDE, Vector2(100, 130))
	var drawn: Rect2 = view.drawn_rect()
	assert_float(drawn.size.y).is_equal_approx(130.0, EPS)  # full height, not shrunk to fit the width
	assert_float(drawn.size.x).is_equal_approx(182.0, EPS)  # 140 * 130/100 — wider than the box
	assert_float(drawn.position.y).is_equal_approx(0.0, EPS)  # feet on the box's bottom edge
	assert_float(drawn.position.x).is_equal_approx(-41.0, EPS)  # centred: the overflow splits evenly
	assert_bool(view.clip_contents).is_true()


func test_tall_expression_stands_the_same_height() -> void:
	var view := _framed(TALL, Vector2(100, 130))
	var drawn: Rect2 = view.drawn_rect()
	assert_float(drawn.size.y).is_equal_approx(130.0, EPS)
	assert_float(drawn.size.x).is_equal_approx(78.0, EPS)  # 60 * 1.3
	assert_float(drawn.position.x).is_equal_approx(11.0, EPS)  # centred inside the box


func test_the_sentinel_never_reaches_the_texture_rect() -> void:
	var view := _framed(WIDE, Vector2(100, 130))
	var rect: TextureRect = view.get_child(0) as TextureRect
	assert_object(rect).is_not_null()
	assert_int(rect.stretch_mode).is_equal(TextureRect.STRETCH_SCALE)  # sized by hand, never -1


func test_resizing_the_box_relays_the_portrait() -> void:
	var view := _framed(TALL, Vector2(100, 130))
	view.size = Vector2(100, 260)
	await get_tree().process_frame  # `resized` delivers on the next frame
	var drawn: Rect2 = view.drawn_rect()
	assert_float(drawn.size.y).is_equal_approx(260.0, EPS)
	assert_float(drawn.size.x).is_equal_approx(156.0, EPS)


func test_other_fits_are_untouched() -> void:
	# The engine's centred fit still shrinks a wide image to the box width — this mode is opt-in.
	var view := _framed(WIDE, Vector2(100, 130), TextureRect.STRETCH_KEEP_ASPECT_CENTERED)
	var drawn: Rect2 = view.drawn_rect()
	assert_float(drawn.size.x).is_equal_approx(100.0, EPS)
	assert_float(drawn.size.y).is_equal_approx(71.4, EPS)
	assert_bool(view.clip_contents).is_false()
