class_name SettingEditor
extends Control

# Full-screen editor for one setting, modelled on PlacementEditor.
#
# A setting is almost entirely about its art, and the question an author is asking — does this framing
# work — cannot be answered by a thumbnail. So the preview takes the room and the controls sit beside
# it, rather than a small window with a picture inside it.
#
# The layout follows the data's own scope, which is the part worth keeping:
#   TOP    — name and music. These belong to the SETTING; every variant shares them.
#   LEFT   — the selected variant, drawn at the size and framing it will really have.
#   RIGHT  — the variant list and that variant's own art and framing.
#
# Edits apply straight to the live dictionary (the modal it replaced did the same), so DONE simply
# closes. There is no cancel: nothing here is destructive except deleting a variant, which is one
# click and visibly undone by adding another.

signal closed

# DropZone.gd declares no class_name, so it is preloaded rather than referenced by type — same as
# BuilderSidePanel does.
const DropZoneScript = preload("res://scripts/journey_builder/DropZone.gd")
const PREVIEW_BG: Color = Color(0.06, 0.06, 0.09, 1.0)
# Past roughly 3x a background is being enlarged well beyond its own resolution and starts to soften;
# the cap is a nudge rather than a hard rule about what looks right.
const MAX_ZOOM: float = 3.0
const ZOOM_STEP: float = 0.05

var _setting: Dictionary = {}
var _selected: int = 0

var _preview: JourneyImage = null
var _preview_frame: Control = null
var _list_col: VBoxContainer = null
var _options_col: VBoxContainer = null
var _empty_hint: Label = null
var _music_test_btn: Button = null
var _zoom_slider: HSlider = null


func setup(setting: Dictionary) -> void:
	_setting = setting
	_build_ui()
	_refresh()


func _backgrounds() -> Array:
	return _setting.get("backgrounds", [])


func _current() -> Dictionary:
	var list: Array = _backgrounds()
	if _selected < 0 or _selected >= list.size():
		return {}
	return list[_selected]


# ── Layout ──────────────────────────────────────────────────────────────────


func _build_ui() -> void:
	# Explicit anchors rather than PRESET_FULL_RECT — the same reason PlacementEditor gives: a preset
	# here leaves the root zero-sized and the panel collapses to its content minimum.
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP

	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.6)
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP  # eat clicks behind the editor
	add_child(backdrop)

	var panel: PanelContainer = PanelContainer.new()
	panel.anchor_left = 0.03
	panel.anchor_right = 0.97
	panel.anchor_top = 0.025
	panel.anchor_bottom = 0.975
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.border_color = UITheme.CYAN
	ps.set_border_width_all(1)
	ps.set_corner_radius_all(UITheme.CORNER_RADIUS)
	ps.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", ps)
	add_child(panel)

	var root: VBoxContainer = VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	root.add_child(_build_setting_strip())
	root.add_child(HSeparator.new())

	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	body.add_child(_build_preview())
	body.add_child(_build_side())


# Name and music: setting-level, so they sit above the variant work rather than inside it.
func _build_setting_strip() -> Control:
	var strip: HBoxContainer = HBoxContainer.new()
	strip.add_theme_constant_override("separation", 14)

	var name_col: VBoxContainer = VBoxContainer.new()
	name_col.add_theme_constant_override("separation", 2)
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_col.add_child(_label("SETTING NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(_setting.get("name", ""))
	name_edit.placeholder_text = "Place name (e.g. The Tavern)..."
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: _setting["name"] = v)
	name_col.add_child(name_edit)
	strip.add_child(name_col)

	var music_col: VBoxContainer = VBoxContainer.new()
	music_col.add_theme_constant_override("separation", 2)
	music_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	music_col.size_flags_stretch_ratio = 1.6
	music_col.add_child(_label("MUSIC  (plays while the story is in this place — every variant)"))
	music_col.add_child(_build_music_row())
	strip.add_child(music_col)

	return strip


func _build_music_row() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var zone: PanelContainer = DropZoneScript.new()
	zone.accepted_extensions = JourneyAudio.AUDIO_EXTENSIONS.duplicate()
	zone.picker_title = "Select Setting Music"
	zone.picker_filters = ["*.ogg,*.mp3,*.wav ; Audio Files"]
	zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(zone)
	if str(_setting.get("bgm", "")) != "":
		# emit:false — set_file fires file_dropped by default and this is a restore, not a drop.
		zone.call_deferred("set_file", str(_setting.get("bgm", "")), false)

	var volume: SpinBox = SpinBox.new()
	volume.min_value = 0
	volume.max_value = 100
	volume.step = 1
	volume.suffix = "%"
	volume.value = roundi(float(_setting.get("bgm_volume", JourneyData.DEFAULT_BGM_VOLUME)) * 100.0)
	volume.custom_minimum_size = Vector2(96, 0)
	UITheme.style_spin_box(volume)
	volume.value_changed.connect(
		func(v: float) -> void: _setting["bgm_volume"] = clampf(v / 100.0, 0.0, 1.0)
	)
	row.add_child(volume)

	# Errors land on the button itself: this editor has no status line, and a silent failure on a file
	# that will not load is the one outcome worth avoiding.
	var test: Button = UITheme.make_audio_test_button(
		self,
		func() -> String: return str(_setting.get("bgm", "")),
		func() -> float: return float(_setting.get("bgm_volume", JourneyData.DEFAULT_BGM_VOLUME)),
		_flash_music_error
	)
	row.add_child(test)
	_music_test_btn = test

	var clear: Button = Button.new()
	clear.text = "✕"
	UITheme.style_button(clear, UITheme.MAGENTA)
	clear.pressed.connect(
		func() -> void:
			_setting["bgm"] = ""
			zone.set_file("", false)
	)
	row.add_child(clear)

	zone.file_dropped.connect(func(path: String) -> void: _setting["bgm"] = path)
	return row


# The variant at the size it will actually be seen, letterboxed to 16:9 so the framing choice means
# what it appears to mean.
func _build_preview() -> Control:
	var wrap: AspectRatioContainer = AspectRatioContainer.new()
	wrap.ratio = 16.0 / 9.0
	wrap.stretch_mode = AspectRatioContainer.STRETCH_FIT
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = PREVIEW_BG
	style.border_color = UITheme.SEPARATOR
	style.set_border_width_all(1)
	var frame: PanelContainer = PanelContainer.new()
	frame.add_theme_stylebox_override("panel", style)
	frame.clip_contents = true
	wrap.add_child(frame)

	_preview_frame = Control.new()
	_preview_frame.clip_contents = true
	# STOP, not IGNORE: the preview is the framing control, not just a picture of one.
	_preview_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview_frame.gui_input.connect(_on_preview_input)
	frame.add_child(_preview_frame)

	_preview = JourneyImage.new()
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_frame.add_child(_preview)

	_empty_hint = Label.new()
	_empty_hint.text = "Drop an image on the right to see it here"
	_empty_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_empty_hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	_empty_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_frame.add_child(_empty_hint)

	return wrap


func _build_side() -> Control:
	var side: VBoxContainer = VBoxContainer.new()
	side.add_theme_constant_override("separation", 6)
	side.custom_minimum_size = Vector2(300, 0)

	side.add_child(_label("VARIANTS  (first is the default)"))
	_list_col = VBoxContainer.new()
	_list_col.add_theme_constant_override("separation", 3)
	side.add_child(_list_col)

	var add_btn: Button = Button.new()
	add_btn.text = "＋ ADD VARIANT"
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(_add_background)
	side.add_child(add_btn)

	side.add_child(HSeparator.new())

	_options_col = VBoxContainer.new()
	_options_col.add_theme_constant_override("separation", 6)
	side.add_child(_options_col)

	var spacer: Control = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(spacer)

	var done: Button = Button.new()
	done.text = "DONE"
	UITheme.style_button(done, UITheme.CYAN)
	done.pressed.connect(
		func() -> void:
			closed.emit()
			queue_free()
	)
	side.add_child(done)
	return side


# ── The selected variant's own fields ───────────────────────────────────────


func _fill_options() -> void:
	for c: Node in _options_col.get_children():
		c.queue_free()
	var bg: Dictionary = _current()
	if bg.is_empty():
		return

	_options_col.add_child(_label("VARIANT NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(bg.get("name", ""))
	name_edit.placeholder_text = "e.g. Night"
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(
		func(v: String) -> void:
			bg["name"] = v
			_rebuild_list()  # the list entry is the only place this name is read back
	)
	_options_col.add_child(name_edit)

	_options_col.add_child(_label("IMAGE"))
	var zone: PanelContainer = DropZoneScript.new()
	zone.accepted_extensions = JourneyData.ANIMATED_IMAGE_EXTENSIONS.duplicate()
	zone.picker_title = "Select Background Image"
	zone.picker_filters = [
		"*.png,*.jpg,*.jpeg,*.webp,*.gif,*.apng,*.mp4,*.m4v,*.webm,*.mkv,*.mov ; Background (image or animation)"
	]
	zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options_col.add_child(zone)
	if str(bg.get("path", "")) != "":
		zone.call_deferred("set_file", str(bg.get("path", "")), false)
	zone.file_dropped.connect(
		func(path: String) -> void:
			bg["path"] = path
			_show_preview()  # the preview IS the feedback; no rebuild, so the drop cannot re-enter
	)

	# The handler is hoisted rather than written inline: a multi-statement lambda as the last argument
	# of a nested call leaves the closing parens dedenting two levels at once, which the parser rejects.
	var on_fit: Callable = func(v: String) -> void:
		bg["image_fit"] = v
		_fill_options()  # framing only applies to a crop, so the field list changes with this
		_show_preview()
	var fit_options: Array = [
		{"value": "crop", "label": "Crop — fills the frame"},
		{"value": "fit", "label": "Fit — whole image, letterboxed"},
		{"value": "stretch", "label": "Stretch — fills, distorts"},
	]
	_options_col.add_child(_label("FIT"))
	_options_col.add_child(_choice(fit_options, str(bg.get("image_fit", "crop")), on_fit))

	# Framing decides where a crop sits, so it means nothing for the fits that show the whole image or
	# distort it to fit. Hidden rather than disabled — a control that can never apply is noise, and this
	# pane is meant to stay short.
	if str(bg.get("image_fit", "crop")) != "crop":
		return
	_options_col.add_child(_label("ZOOM"))
	var zoom: HSlider = HSlider.new()
	zoom.min_value = 1.0
	zoom.max_value = MAX_ZOOM
	zoom.step = 0.01
	zoom.value = maxf(float(bg.get("zoom", 1.0)), 1.0)
	zoom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zoom.value_changed.connect(
		func(v: float) -> void:
			bg["zoom"] = v
			_show_preview()
	)
	_options_col.add_child(zoom)
	_zoom_slider = zoom

	var reset: Button = Button.new()
	reset.text = "⟲ RECENTRE"
	reset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button_subtle(reset, UITheme.DARK_TEXT, 10, 6, 10)
	reset.tooltip_text = UITheme.wrap_tip(
		"Back to a centred crop at exactly the size that fills the frame — how a background starts."
	)
	reset.pressed.connect(
		func() -> void:
			bg["focus_x"] = 0.5
			bg["focus_y"] = 0.5
			bg["zoom"] = 1.0
			zoom.set_value_no_signal(1.0)
			_show_preview()
	)
	_options_col.add_child(reset)

	_options_col.add_child(_hint("Drag the preview to frame it. Scroll over it to zoom."))


# ── Refresh ─────────────────────────────────────────────────────────────────


func _refresh() -> void:
	_rebuild_list()
	_fill_options()
	_show_preview()


func _rebuild_list() -> void:
	for c: Node in _list_col.get_children():
		c.queue_free()
	var list: Array = _backgrounds()
	for i: int in list.size():
		_list_col.add_child(_make_list_row(i))


func _make_list_row(idx: int) -> Control:
	var bg: Dictionary = _backgrounds()[idx]
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var pick: Button = Button.new()
	var name: String = str(bg.get("name", "")).strip_edges()
	pick.text = (
		"%s%s"
		% [name if name != "" else "Variant %d" % (idx + 1), "  ·  DEFAULT" if idx == 0 else ""]
	)
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick.clip_text = true
	UITheme.style_button(pick, UITheme.CYAN if idx == _selected else UITheme.PURPLE_MID)
	pick.pressed.connect(
		func() -> void:
			_selected = idx
			_refresh()
	)
	row.add_child(pick)

	var del: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	del.pressed.connect(func() -> void: _delete_background(idx))
	row.add_child(del)
	return row


func _show_preview() -> void:
	var bg: Dictionary = _current()
	var path: String = str(bg.get("path", ""))
	_empty_hint.visible = path == ""
	if path == "":
		_preview.visible = false
		return
	_preview.visible = true
	# The same call the game makes, with the same fallback the full-bleed surfaces use — so what is
	# shown here is what a shop or a fork will show, not an approximation of it.
	_preview.show_background(bg, TextureRect.STRETCH_KEEP_ASPECT_COVERED)


# Drag to move the crop, scroll to zoom. Both are no-ops unless the selected variant is actually
# cropping — there is nothing to reframe when the whole image already shows.
func _on_preview_input(event: InputEvent) -> void:
	var bg: Dictionary = _current()
	if bg.is_empty() or str(bg.get("image_fit", "crop")) != "crop":
		return

	if (
		event is InputEventMouseMotion
		and (event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT
	):
		# The image itself does the maths: it knows the scale and the overflow, and duplicating that
		# here is how the preview would end up disagreeing with the game.
		var moved: Vector2 = _preview.drag_focus((event as InputEventMouseMotion).relative)
		bg["focus_x"] = moved.x
		bg["focus_y"] = moved.y
		return

	if not (event is InputEventMouseButton):
		return
	var button: InputEventMouseButton = event
	if not button.pressed:
		return
	var step: float = 0.0
	if button.button_index == MOUSE_BUTTON_WHEEL_UP:
		step = ZOOM_STEP
	elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		step = -ZOOM_STEP
	if step == 0.0:
		return
	bg["zoom"] = clampf(float(bg.get("zoom", 1.0)) + step, 1.0, MAX_ZOOM)
	if _zoom_slider != null:
		_zoom_slider.set_value_no_signal(float(bg["zoom"]))
	_show_preview()


# ── Mutations ───────────────────────────────────────────────────────────────


func _add_background() -> void:
	_setting["backgrounds"].append({"id": JourneyData.new_background_id(), "name": "", "path": ""})
	_selected = _backgrounds().size() - 1
	_refresh()


func _delete_background(idx: int) -> void:
	var list: Array = _backgrounds()
	if idx < 0 or idx >= list.size():
		return
	list.remove_at(idx)
	_selected = clampi(_selected, 0, maxi(0, list.size() - 1))
	_refresh()


# Says why the test did nothing, on the control that did nothing, then puts itself back. A modal error
# would be heavier than the mistake — usually an empty field or a file that moved.
func _flash_music_error(message: String) -> void:
	if _music_test_btn == null:
		return
	_music_test_btn.text = "✕ %s" % ("NO FILE" if message.begins_with("Drop") else "UNREADABLE")
	_music_test_btn.tooltip_text = message
	var timer: SceneTreeTimer = get_tree().create_timer(1.6)
	timer.timeout.connect(
		func() -> void:
			if is_instance_valid(_music_test_btn):
				_music_test_btn.text = "▶ TEST"
	)


# A quieter, wrapping line for guidance rather than a field caption.
func _hint(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", UITheme.SEPARATOR)
	l.add_theme_font_size_override("font_size", 10)
	return l


func _label(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.SEPARATOR)
	l.add_theme_font_size_override("font_size", 11)
	return l


# A dropdown over {value, label} options, reporting the VALUE rather than the index so the caller never
# has to know the order.
func _choice(options: Array, current: String, on_pick: Callable) -> OptionButton:
	var dd: OptionButton = OptionButton.new()
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dd.clip_text = true
	for i: int in options.size():
		var opt: Dictionary = options[i]
		dd.add_item(str(opt["label"]))
		dd.set_item_metadata(i, str(opt["value"]))
		if str(opt["value"]) == current:
			dd.selected = i
	dd.item_selected.connect(func(i: int) -> void: on_pick.call(str(dd.get_item_metadata(i))))
	return dd
