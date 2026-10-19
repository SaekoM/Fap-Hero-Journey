class_name AxisEffectFields
extends RefCounted

# The per-axis fields of an axes scale or axes clamp — one row per axis, surge to pitch — shared by
# every editor that tunes one: effect rounds, boss forced modifiers, timeline windows and custom items.
# Each editor stores values its own way (straight into the effect, or as a diff against the catalog),
# so it hands in how to read and write a key:
#   read(key: String) -> float   the key's current value (resolve with JourneyData.effect_param_value,
#                                so data written per group before per-axis values existed still shows)
#   write(key: String, value)    store a change (int for clamp positions, float for factors)

# The factor range the arrows step through. Older boss modifiers and windows were typed freely — ×0 holds
# an axis at centre, and anything up to ×5 was accepted — so a stored value above the range is shown as
# it is (allow_greater) rather than clamped to a number the device isn't playing.
const FACTOR_MIN: float = 0.0
const FACTOR_MAX: float = 3.0
const FACTOR_STEP: float = 0.05


static func is_per_axis_kind(kind: String) -> bool:
	return kind in ["axis_scale", "axis_clamp"]


static func build(kind: String, read: Callable, write: Callable) -> Control:
	var is_clamp: bool = kind == "axis_clamp"
	var grid: GridContainer = GridContainer.new()
	grid.columns = 3 if is_clamp else 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 3)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for axis: String in JourneyData.SECONDARY_AXES:
		grid.add_child(_axis_label(axis))
		if is_clamp:
			grid.add_child(_position_spin(JourneyData.axis_key("min", axis), "min ", read, write))
			grid.add_child(_position_spin(JourneyData.axis_key("max", axis), "max ", read, write))
		else:
			grid.add_child(_factor_spin(JourneyData.axis_key("factor", axis), read, write))
	return grid


static func _axis_label(axis: String) -> Label:
	var label: Label = Label.new()
	label.text = str(JourneyData.AXIS_SUFFIXES.get(axis, axis)).to_upper()
	label.custom_minimum_size = Vector2(52, 0)
	UITheme.style_label(label, UITheme.WHITE_SOFT, 10, true)
	return label


static func _factor_spin(key: String, read: Callable, write: Callable) -> SpinBox:
	var spin: SpinBox = _spin(FACTOR_MIN, FACTOR_MAX, FACTOR_STEP)
	spin.allow_greater = true
	spin.suffix = "×"
	spin.set_value_no_signal(float(read.call(key)))
	spin.value_changed.connect(func(value: float) -> void: write.call(key, value))
	return spin


static func _position_spin(key: String, prefix: String, read: Callable, write: Callable) -> SpinBox:
	var spin: SpinBox = _spin(0.0, 100.0, 1.0)
	spin.prefix = prefix
	spin.set_value_no_signal(float(read.call(key)))
	spin.value_changed.connect(func(value: float) -> void: write.call(key, int(value)))
	return spin


static func _spin(low: float, high: float, step: float) -> SpinBox:
	var spin: SpinBox = SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(spin)
	return spin
