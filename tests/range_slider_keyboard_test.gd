extends GdUnitTestSuite

# RangeSlider's keyboard control (COLOUR_MODES_DESIGN.md, phase 4): ←/→ move one handle, Enter/Space
# switches which. Options' stroke and axis ranges and the oscillate speed limits are all RangeSliders,
# so without this they could only be set with a mouse.


func _press(slider: RangeSlider, action: String) -> bool:
	var event: InputEventAction = InputEventAction.new()
	event.action = action
	event.pressed = true
	return slider._handle_key(event)


func _slider(lo: float, hi: float) -> RangeSlider:
	var slider: RangeSlider = auto_free(RangeSlider.new())
	slider.set_range_values(lo, hi)
	return slider


func test_arrows_move_the_low_handle_first() -> void:
	var slider: RangeSlider = _slider(20.0, 80.0)
	assert_bool(_press(slider, "ui_right")).is_true()
	assert_float(slider.lo).is_equal(21.0)
	assert_bool(_press(slider, "ui_left")).is_true()
	assert_bool(_press(slider, "ui_left")).is_true()
	assert_float(slider.lo).is_equal(19.0)
	assert_float(slider.hi).is_equal(80.0)


func test_accept_switches_to_the_high_handle() -> void:
	var slider: RangeSlider = _slider(20.0, 80.0)
	assert_bool(_press(slider, "ui_accept")).is_true()
	_press(slider, "ui_left")
	assert_float(slider.hi).is_equal(79.0)
	assert_float(slider.lo).is_equal(20.0)


func test_handles_never_cross() -> void:
	var slider: RangeSlider = _slider(49.0, 50.0)
	_press(slider, "ui_right")
	assert_float(slider.lo).is_equal(49.0)
	_press(slider, "ui_accept")
	_press(slider, "ui_left")
	assert_float(slider.hi).is_equal(50.0)


func test_handles_stop_at_the_ends() -> void:
	var slider: RangeSlider = _slider(0.0, 100.0)
	_press(slider, "ui_left")
	assert_float(slider.lo).is_equal(0.0)
	_press(slider, "ui_accept")
	_press(slider, "ui_right")
	assert_float(slider.hi).is_equal(100.0)


func test_each_move_reports_the_range() -> void:
	var slider: RangeSlider = _slider(20.0, 80.0)
	var heard: Array = []
	slider.range_changed.connect(func(lo: float, hi: float) -> void: heard.append([lo, hi]))
	_press(slider, "ui_right")
	assert_array(heard).is_equal([[21.0, 80.0]])


func test_other_keys_are_left_alone() -> void:
	var slider: RangeSlider = _slider(20.0, 80.0)
	assert_bool(_press(slider, "ui_up")).is_false()
	assert_float(slider.lo).is_equal(20.0)
