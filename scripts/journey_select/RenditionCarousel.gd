class_name RenditionCarousel
extends Control

## The detail modal's cover area when a journey has renditions: one card per version — the base first,
## then each rendition — showing the selected one's cover FULL-BLEED, with the others a slide away.
## Replaces the VERSION dropdown: a rendition is mostly its cover, and a list of names hid the one thing
## that told them apart.
##
## Full-bleed rather than the usual peeking-neighbours carousel. Peeking cost better than a third of the
## frame's width, and the frame is the only place a cover is ever shown large — a 16:9 banner fitted into
## the remainder was a thin ribbon in a tall letterbox. The neighbours now sit exactly one frame to each
## side, so stepping slides them through; a dot row says how many versions there are and where you are,
## which is what the peek was really for.
##
## Pure presentation. The owner hands over the entries and listens for `selected_changed`; what a
## selection MEANS (compose the stack, swap the description, gate EDIT) stays in JourneySelect.
##
## Entry: {label: String, cover_path: String, dimmed: bool}. `dimmed` marks an inherited cover — a
## rendition without art of its own shows the base's, visibly muted, so it reads as "borrowed" rather
## than "identical".

## Fired when the centred card changes, by any route (arrows, click, wheel, keys, or select()).
signal selected_changed(index: int)

const INHERITED_TINT: Color = Color(0.55, 0.55, 0.62, 1.0)  # a borrowed cover, muted
const STRIP_H: float = 34.0  # the name strip, laid OVER the image on a scrim
const SCRIM: Color = Color(0.02, 0.0, 0.04, 0.82)
const SLIDE_SECS: float = 0.16
const ARROW_W: float = 30.0
const DOT_SIZE: float = 7.0
const DOT_GAP: float = 6.0

var _entries: Array = []
var _cards: Array = []  # Control per entry, index-aligned
var _selected: int = 0
var _label: Label = null
var _scrim: Panel = null
var _dots: HBoxContainer = null
var _side_slot: HBoxContainer = null  # owner-supplied control beside the name (the delete button)
var _left: Button = null
var _right: Button = null
var _tween: Tween = null


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_layout.bind(false))
	_left = _make_arrow("◂", -1)
	_right = _make_arrow("▸", 1)

	_scrim = Panel.new()
	var scrim_style: StyleBoxFlat = StyleBoxFlat.new()
	scrim_style.bg_color = SCRIM
	_scrim.add_theme_stylebox_override("panel", scrim_style)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scrim)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.clip_text = true
	_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	_label.add_theme_font_size_override("font_size", 14)
	add_child(_label)

	_dots = HBoxContainer.new()
	_dots.add_theme_constant_override("separation", int(DOT_GAP))
	_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dots)

	_side_slot = HBoxContainer.new()
	_side_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_side_slot)


## Replaces the cards. `selected` is centred without animation.
func set_entries(entries: Array, selected: int = 0) -> void:
	for c: Variant in _cards:
		if is_instance_valid(c):
			(c as Node).queue_free()
	_cards.clear()
	_entries = entries.duplicate(true)
	for i: int in _entries.size():
		_cards.append(_make_card(_entries[i], i))
	_rebuild_dots()
	_selected = clampi(selected, 0, maxi(0, _entries.size() - 1))
	# Cards were appended after the chrome; drawing follows tree order, so the overlays go back on top.
	for chrome: Control in [_left, _right, _scrim, _label, _dots, _side_slot]:
		chrome.move_to_front()
	_layout(false)


## A control to show beside the selected version's name — the owner's delete button, typically.
func set_side_control(control: Control) -> void:
	for c: Node in _side_slot.get_children():
		_side_slot.remove_child(c)
	if control != null:
		_side_slot.add_child(control)
	_layout(false)


func selected_index() -> int:
	return _selected


## Centres `index`. Emits `selected_changed` only when it actually moved.
func select(index: int, animated: bool = true) -> void:
	var target: int = clampi(index, 0, maxi(0, _entries.size() - 1))
	if target == _selected:
		return
	_selected = target
	_layout(animated)
	selected_changed.emit(_selected)


func _step(delta: int) -> void:
	select(_selected + delta)


# ── Input ────────────────────────────────────────────────────────────────────


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed:
		return
	var mb: InputEventMouseButton = event
	if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN or mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT:
		_step(1)
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_LEFT:
		_step(-1)
		accept_event()


# Left / Right walk the versions while the modal is open. Only when visible: the carousel lives inside
# the detail modal, so hidden means the modal is closed and the keys belong to the catalogue grid.
func _unhandled_key_input(event: InputEvent) -> void:
	if (
		not is_visible_in_tree()
		or not (event is InputEventKey)
		or not (event as InputEventKey).pressed
	):
		return
	var key: InputEventKey = event
	if key.echo:
		return
	if key.keycode == KEY_LEFT:
		_step(-1)
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_RIGHT:
		_step(1)
		get_viewport().set_input_as_handled()


# ── Building ─────────────────────────────────────────────────────────────────


func _make_arrow(glyph: String, delta: int) -> Button:
	var b: Button = Button.new()
	b.text = glyph
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(ARROW_W, 60)
	UITheme.style_button(b, UITheme.PURPLE_MID)
	b.pressed.connect(_step.bind(delta))
	add_child(b)
	return b


func _make_card(entry: Dictionary, index: int) -> Control:
	var card: Panel = Panel.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.CARD_BG
	style.border_color = UITheme.SEPARATOR
	style.set_border_width_all(1)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	card.add_theme_stylebox_override("panel", style)
	card.clip_contents = true
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	# Clicking the picture steps forward (and wraps at the end): with nothing peeking there is no
	# neighbour to aim at, and a click on the cover should still do the obvious thing. The arrows and
	# the keys remain the way to go back.
	card.gui_input.connect(
		func(e: InputEvent) -> void:
			if (
				e is InputEventMouseButton
				and (e as InputEventMouseButton).pressed
				and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
				and index == _selected
			):
				select(0 if _selected >= _cards.size() - 1 else _selected + 1)
	)
	var pic: TextureRect = TextureRect.new()
	pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var img: Image = JourneyData.load_image_smart(str(entry.get("cover_path", "")))
	if img != null:
		pic.texture = ImageTexture.create_from_image(img)
	if bool(entry.get("dimmed", false)):
		pic.modulate = INHERITED_TINT
	card.add_child(pic)
	if img == null:
		# No cover anywhere in the family: the name is the card.
		var fallback: Label = Label.new()
		fallback.text = str(entry.get("label", ""))
		fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		fallback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fallback.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
		fallback.add_theme_font_size_override("font_size", 20)
		card.add_child(fallback)
	add_child(card)
	return card


# One dot per version — what the peeking neighbours used to say: how many there are, and where you are.
func _rebuild_dots() -> void:
	for d: Node in _dots.get_children():
		d.queue_free()
	if _cards.size() < 2:
		return
	for _i: int in _cards.size():
		var dot: Panel = Panel.new()
		dot.custom_minimum_size = Vector2(DOT_SIZE, DOT_SIZE)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var s: StyleBoxFlat = StyleBoxFlat.new()
		s.bg_color = UITheme.WHITE_SOFT
		s.set_corner_radius_all(int(DOT_SIZE * 0.5))
		dot.add_theme_stylebox_override("panel", s)
		_dots.add_child(dot)


func _paint_dots() -> void:
	for i: int in _dots.get_child_count():
		(_dots.get_child(i) as Control).modulate.a = 1.0 if i == _selected else 0.35


# ── Layout ───────────────────────────────────────────────────────────────────


# After a slide: the tween is done with, so a plain re-layout can hide the cards that slid off frame
# without killing the tween from inside its own callback.
func _settle() -> void:
	_tween = null
	_layout(false)


# Every card is the FULL frame, sitting one frame-width apart, so the selected one fills the control and
# stepping slides the next in from the side. Name, dots and arrows are drawn OVER the picture — the text
# on a scrim along the bottom — rather than taking space from it.
func _layout(animated: bool) -> void:
	if _cards.is_empty():
		_label.text = ""
		_left.visible = false
		_right.visible = false
		_scrim.visible = false
		return
	var frame: Vector2 = size

	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true) if animated else null

	for i: int in _cards.size():
		var card: Control = _cards[i]
		var offset: int = i - _selected
		var target: Vector2 = Vector2(float(offset) * frame.x, 0.0)
		# Neighbours are only drawn while a slide is in flight; at rest they sit off frame anyway, and
		# leaving them hidden keeps a stack of full-size covers out of the draw list.
		card.visible = offset == 0 or animated
		card.z_index = 2 if offset == 0 else 1
		card.modulate.a = 1.0
		if _tween != null:
			_tween.tween_property(card, "position", target, SLIDE_SECS)
			_tween.tween_property(card, "size", frame, SLIDE_SECS)
		else:
			card.position = target
			card.size = frame
	if _tween != null:
		_tween.chain().tween_callback(_settle)

	# Arrows on the frame's edges, vertically centred; hidden at the ends rather than disabled — an
	# unavailable direction shouldn't draw the eye.
	_left.visible = _selected > 0
	_right.visible = _selected < _cards.size() - 1
	_left.position = Vector2(4.0, (frame.y - _left.size.y) * 0.5)
	_right.position = Vector2(frame.x - _right.size.x - 4.0, (frame.y - _right.size.y) * 0.5)
	_left.z_index = 3
	_right.z_index = 3

	# Name strip over the picture's foot: scrim, label centred, side control hugging the right. As tall
	# as the side control needs, so a button bigger than the text is never clipped by clip_contents.
	#
	# The width is reserved whether or not the control is SHOWING. Only a rendition has a delete button,
	# so measuring the strip by what is visible made the name jump sideways the moment you stepped off
	# the base — a layout that moves as you browse reads as a glitch. The gutter is the same on both
	# sides, so the name sits on the frame's centre line in every case.
	var side_min: Vector2 = Vector2.ZERO
	for c: Node in _side_slot.get_children():
		if c is Control:
			side_min = side_min.max((c as Control).get_combined_minimum_size())
	var strip_h: float = maxf(STRIP_H, side_min.y)
	var strip_y: float = frame.y - strip_h
	_scrim.visible = true
	_scrim.position = Vector2(0.0, strip_y)
	_scrim.size = Vector2(frame.x, strip_h)
	_scrim.z_index = 3
	_label.text = str(_entries[_selected].get("label", ""))
	_label.position = Vector2(side_min.x, strip_y)
	_label.size = Vector2(maxf(0.0, frame.x - side_min.x * 2.0), strip_h)
	_label.z_index = 4
	_side_slot.position = Vector2(frame.x - side_min.x, strip_y + (strip_h - side_min.y) * 0.5)
	_side_slot.size = side_min
	_side_slot.z_index = 4

	# Dots sit just above the strip.
	_paint_dots()
	var dots_size: Vector2 = _dots.get_combined_minimum_size()
	_dots.position = Vector2((frame.x - dots_size.x) * 0.5, strip_y - dots_size.y - 6.0)
	_dots.size = dots_size
	_dots.z_index = 4
