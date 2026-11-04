extends GdUnitTestSuite

# Safe-Cracker's stage: which art each style gets, where its dial sits, and the rules for skipping an ending.


func _released_view() -> LockView:
	var view: LockView = auto_free(LockView.new())
	add_child(view)
	view.setup(LockArt.STYLE_SAFE, 3, 40)
	view.size = LockView.STAGE_SIZE
	view.play_released(1.0)
	return view


func test_every_style_has_its_own_art() -> void:
	assert_object(LockView.art_for(LockArt.STYLE_SAFE)).is_instanceof(SafeLockArt)
	assert_object(LockView.art_for(LockArt.STYLE_DOOR)).is_instanceof(DoorLockArt)
	assert_object(LockView.art_for(LockArt.STYLE_HANDCUFFS)).is_instanceof(HandcuffsLockArt)
	assert_object(LockView.art_for(LockArt.STYLE_PADLOCK)).is_instanceof(PadlockLockArt)


func test_every_style_has_a_name_for_the_editor() -> void:
	for style: String in LockArt.STYLES:
		assert_bool(LockArt.STYLE_NAMES.has(style)).is_true()


# The whole dial, with its pointer, has to fit on the stage on every lock.
func test_every_dial_fits_on_the_stage() -> void:
	const RING_AND_POINTER: float = 18.0
	for style: String in LockArt.STYLES:
		var art: LockArt = LockView.art_for(style)
		var center: Vector2 = art.dial_transform(LockView.STAGE_SIZE).origin
		var reach: float = art.dial_radius() + RING_AND_POINTER
		assert_bool(center.x - reach >= 0.0 and center.x + reach <= LockView.STAGE_SIZE.x).is_true()
		assert_bool(center.y - reach >= 0.0 and center.y + reach <= LockView.STAGE_SIZE.y).is_true()


func test_only_the_door_clips_to_the_stage() -> void:
	for style: String in LockArt.STYLES:
		assert_bool(LockView.art_for(style).clips_to_stage()).is_equal(style == LockArt.STYLE_DOOR)


# A key press spamming through the last number must not throw away the ending it just earned.
func test_a_press_just_after_the_ending_starts_does_not_skip_it() -> void:
	var view: LockView = _released_view()
	var finished: Array[bool] = [false]
	view.finale_finished.connect(func() -> void: finished[0] = true)
	view.skip_finale()
	assert_bool(finished[0]).is_false()


func test_a_later_press_runs_the_ending_to_its_end() -> void:
	var view: LockView = _released_view()
	var finished: Array[bool] = [false]
	view.finale_finished.connect(func() -> void: finished[0] = true)
	view._finale_started_ms -= roundi(LockView.SKIP_GUARD_SECS * 1000.0) + 1
	view.skip_finale()
	assert_bool(finished[0]).is_true()
	assert_float(view._art.release).is_equal_approx(1.0, 0.001)


func test_skipping_with_no_ending_playing_does_nothing() -> void:
	var view: LockView = auto_free(LockView.new())
	add_child(view)
	view.setup(LockArt.STYLE_PADLOCK, 1, 40)
	view.skip_finale()
	assert_float(view._art.release).is_equal(0.0)
