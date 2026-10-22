class_name RangeSlider
extends Control

## Dual-handle horizontal range slider.  Emits range_changed whenever either
## handle moves.  Values are always in the range [0, 100].
##
## Keyboard: with focus, ←/→ move one handle (Shift for steps of 10) and Enter/Space switches which
## handle that is; the handle the keys move wears a ring while the slider has keyboard focus.
signal range_changed(lo: float, hi: float)

## Current low-end clamp value (0–100).
var lo: float = 0.0
## Current high-end clamp value (0–100).
var hi: float = 100.0
## Optional (value: float) -> String for the handle labels, for a slider whose 0–100 track stands for
## something else (the randomizer's log-mapped seconds). Unset = the raw 0–100 value.
var value_format: Callable = Callable()

const HANDLE_R: float = 8.0  # handle circle radius
const TRACK_H: float = 5.0  # track rect height
const LABEL_GAP: int = 4  # px gap between handle bottom and value label

var _drag: int = -1  # 0 = lo handle, 1 = hi handle
var _key_handle: int = 0  # the handle ←/→ move: 0 = lo, 1 = hi
# Whether focus came from the keyboard: the focus ring is for keyboard users, not for every click.
var _keyboard_focus: bool = false
const KEY_STEP: float = 1.0
const KEY_STEP_LARGE: float = 10.0
var _lo_lbl: Label = null
var _hi_lbl: Label = null


func _ready() -> void:
	custom_minimum_size = Vector2(0, int(HANDLE_R) * 2 + LABEL_GAP + 16)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(queue_redraw)
	_lo_lbl = _make_val_label()
	_hi_lbl = _make_val_label()
	add_child(_lo_lbl)
	add_child(_hi_lbl)
	_update()


func _make_val_label() -> Label:
	var lbl: Label = Label.new()
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


## Set both handles at once without emitting range_changed.
func set_range_values(new_lo: float, new_hi: float) -> void:
	lo = clampf(new_lo, 0.0, 100.0)
	hi = clampf(new_hi, lo + 1.0, 100.0)
	_update()


# ── Internal helpers ──────────────────────────────────────────────────────────


func _track_start() -> float:
	return HANDLE_R


func _track_end() -> float:
	return size.x - HANDLE_R


func _track_len() -> float:
	return _track_end() - _track_start()


func _cy() -> float:
	return HANDLE_R


func _val_to_x(v: float) -> float:
	return _track_start() + v / 100.0 * _track_len()


func _x_to_val(x: float) -> float:
	if _track_len() <= 0.0:
		return 0.0
	return clampf((x - _track_start()) / _track_len() * 100.0, 0.0, 100.0)


func _update() -> void:
	if _lo_lbl == null:
		return
	_lo_lbl.text = _value_text(lo)
	_hi_lbl.text = _value_text(hi)
	queue_redraw()


func _value_text(v: float) -> String:
	return str(value_format.call(v)) if value_format.is_valid() else "%d" % roundi(v)


func _draw() -> void:
	if size.x <= 0:
		return
	var cy: float = _cy()
	var ty: float = cy - TRACK_H * 0.5
	var lx: float = _val_to_x(lo)
	var hx: float = _val_to_x(hi)
	var label_y: float = cy + HANDLE_R + LABEL_GAP

	# Full background track
	draw_rect(Rect2(_track_start(), ty, _track_len(), TRACK_H), UITheme.PURPLE_DARK)

	# Dimmed segments outside the selected range
	var dim: Color = Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.35)
	draw_rect(Rect2(_track_start(), ty, lx - _track_start(), TRACK_H), dim)
	draw_rect(Rect2(hx, ty, _track_end() - hx, TRACK_H), dim)

	# Active range fill
	draw_rect(Rect2(lx, ty, hx - lx, TRACK_H), UITheme.PURPLE_BRIGHT)

	# Handles — active handle turns MAGENTA while dragging
	var lo_col: Color = UITheme.MAGENTA if _drag == 0 else UITheme.CYAN
	var hi_col: Color = UITheme.MAGENTA if _drag == 1 else UITheme.CYAN
	draw_circle(Vector2(lx, cy), HANDLE_R, lo_col)
	draw_circle(Vector2(hx, cy), HANDLE_R, hi_col)

	# Keyboard focus: a ring round the slider, and one round the handle the arrow keys move.
	if has_focus() and _keyboard_focus:
		draw_style_box(UITheme.focus_ring_style(), Rect2(Vector2.ZERO, size))
		var key_x: float = lx if _key_handle == 0 else hx
		draw_arc(Vector2(key_x, cy), HANDLE_R + 3.0, 0.0, TAU, 24, UITheme.FOCUS_RING, 2.0, true)

	# Value labels below their respective handles (clamped to widget bounds)
	if _lo_lbl != null:
		var lw: float = _lo_lbl.get_minimum_size().x
		_lo_lbl.position = Vector2(clampf(lx - lw * 0.5, 0.0, size.x - lw), label_y)
	if _hi_lbl != null:
		var hw: float = _hi_lbl.get_minimum_size().x
		_hi_lbl.position = Vector2(clampf(hx - hw * 0.5, 0.0, size.x - hw), label_y)


func _on_focus_entered() -> void:
	_keyboard_focus = not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	queue_redraw()


# ←/→ move the keyboard handle (Shift: by 10), Enter/Space switch handles. Returns whether it used
# the event.
func _handle_key(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_accept"):
		_key_handle = 1 - _key_handle
		_keyboard_focus = true
		queue_redraw()
		return true
	var direction: float = 0.0
	if event.is_action_pressed("ui_left", true):
		direction = -1.0
	elif event.is_action_pressed("ui_right", true):
		direction = 1.0
	if direction == 0.0:
		return false
	var key: InputEventKey = event as InputEventKey
	var step: float = KEY_STEP_LARGE if key != null and key.shift_pressed else KEY_STEP
	if _key_handle == 0:
		lo = clampf(lo + direction * step, 0.0, hi - 1.0)
	else:
		hi = clampf(hi + direction * step, lo + 1.0, 100.0)
	_keyboard_focus = true
	_update()
	range_changed.emit(lo, hi)
	return true


func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey and _handle_key(event):
		accept_event()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var lx: float = _val_to_x(lo)
				var hx: float = _val_to_x(hi)
				var cy: float = _cy()
				var dl: float = mb.position.distance_to(Vector2(lx, cy))
				var dh: float = mb.position.distance_to(Vector2(hx, cy))
				if dl <= HANDLE_R * 2.5 or dh <= HANDLE_R * 2.5:
					_drag = 0 if dl <= dh else 1
					_key_handle = _drag  # the keys then nudge the handle just grabbed
					_keyboard_focus = false
					get_viewport().set_input_as_handled()
			else:
				if _drag >= 0:
					_drag = -1
					queue_redraw()
	elif event is InputEventMouseMotion and _drag >= 0:
		var new_val: float = _x_to_val((event as InputEventMouseMotion).position.x)
		if _drag == 0:
			lo = clampf(new_val, 0.0, hi - 1.0)
		else:
			hi = clampf(new_val, lo + 1.0, 100.0)
		_update()
		range_changed.emit(lo, hi)
		get_viewport().set_input_as_handled()
