class_name CharacterEditor
extends Control

# Full-screen editor for one character, laid out like SettingEditor because the two hold the same shape
# of thing: a name, a set of variants, and a picture you have to SEE to judge.
#
#   TOP    — the character's name, and which setting to judge them against.
#   LEFT   — the stage: their portrait standing in each of their positions, over that backdrop.
#   RIGHT  — expressions and positions, and whichever of the two is selected.
#
# This absorbs what used to be a separate positions editor. A portrait and where it stands are one
# judgement — art framed for a left-hand slot looks wrong centred — and making them two windows meant
# choosing an expression, closing, opening positions, and remembering what you had just seen.
#
# Edits apply straight to the live character (the modal it replaced did the same), so DONE simply
# closes. Deleting is the only destructive act and is one click to undo by adding another.

signal closed

const DropZoneScript = preload("res://scripts/journey_builder/DropZone.gd")
const HANDLE_SIZE: int = 14
const PREVIEW_BG: Color = Color(0.06, 0.06, 0.09, 1.0)

var _character: Dictionary = {}
var _settings: Array = []
var _portrait_idx: int = 0
var _placement_idx: int = 0
# Show only the selected position. A character with six of them stacks into an unreadable pile, and
# while dragging, one box is the only one that matters.
var _solo: bool = false

var _stage: Control = null
var _backdrop: JourneyImage = null
var _boxes: Array = []  # Control per placement, index-aligned with _placements()
var _lists: VBoxContainer = null
var _preview_setting: Dictionary = {}
var _variant_holder: VBoxContainer = null


func setup(character: Dictionary, settings: Array) -> void:
	_character = character
	_settings = settings
	_build_ui()
	_refresh()


func _portraits() -> Array:
	return _character.get("portraits", [])


func _placements() -> Array:
	return _character.get("placements", [])


# The portrait currently being judged — the selected expression, or the first when none is. Every box
# on the stage draws this one, so switching expression re-dresses the whole character at once.
func _shown_portrait_path() -> String:
	var list: Array = _portraits()
	if list.is_empty():
		return ""
	var index: int = clampi(_portrait_idx, 0, list.size() - 1)
	return str((list[index] as Dictionary).get("path", ""))


# ── Layout ──────────────────────────────────────────────────────────────────


func _build_ui() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	# The builder's shortcuts stand down while anything in this group is visible.
	add_to_group("ui_modal")

	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel: PanelContainer = PanelContainer.new()
	panel.anchor_left = 0.03
	panel.anchor_right = 0.97
	panel.anchor_top = 0.025
	panel.anchor_bottom = 0.975
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.border_color = UITheme.PURPLE_BRIGHT
	ps.set_border_width_all(1)
	ps.set_corner_radius_all(UITheme.CORNER_RADIUS)
	ps.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", ps)
	add_child(panel)

	var root: VBoxContainer = VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	root.add_child(_build_top_strip())
	root.add_child(HSeparator.new())

	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	body.add_child(_build_stage())
	body.add_child(_build_side())


func _build_top_strip() -> Control:
	var strip: HBoxContainer = HBoxContainer.new()
	strip.add_theme_constant_override("separation", 14)

	var name_col: VBoxContainer = VBoxContainer.new()
	name_col.add_theme_constant_override("separation", 2)
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_col.add_child(_label("NAME  (match a line's speaker to light this character)"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(_character.get("name", ""))
	name_edit.placeholder_text = "Character name..."
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: _character["name"] = v)
	name_col.add_child(name_edit)
	strip.add_child(name_col)

	var against: VBoxContainer = VBoxContainer.new()
	against.add_theme_constant_override("separation", 2)
	against.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	against.add_child(_label("PREVIEW AGAINST  (a place to judge them in)"))
	var picker_row: HBoxContainer = HBoxContainer.new()
	picker_row.add_theme_constant_override("separation", 6)
	picker_row.add_child(_make_setting_picker())
	_variant_holder = VBoxContainer.new()
	_variant_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker_row.add_child(_variant_holder)
	against.add_child(picker_row)
	strip.add_child(against)

	return strip


func _build_stage() -> Control:
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

	_stage = Control.new()
	_stage.clip_contents = true
	frame.add_child(_stage)

	_backdrop = JourneyImage.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.visible = false
	_stage.add_child(_backdrop)

	_add_vn_bar_guide()
	return wrap


# The dialogue bar's footprint, so a portrait is not framed with its feet behind text it will never be
# seen without.
func _add_vn_bar_guide() -> void:
	var guide: ColorRect = ColorRect.new()
	guide.color = Color(0, 0, 0, 0.28)
	guide.anchor_top = 1.0 - 0.28
	guide.anchor_right = 1.0
	guide.anchor_bottom = 1.0
	guide.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(guide)


func _build_side() -> Control:
	var side: VBoxContainer = VBoxContainer.new()
	side.add_theme_constant_override("separation", 6)
	side.custom_minimum_size = Vector2(300, 0)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(scroll)
	_lists = VBoxContainer.new()
	_lists.add_theme_constant_override("separation", 6)
	_lists.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_lists)

	side.add_child(HSeparator.new())
	var done: Button = Button.new()
	done.text = "DONE"
	done.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(done, UITheme.PURPLE_BRIGHT)
	done.pressed.connect(
		func() -> void:
			closed.emit()
			queue_free()
	)
	side.add_child(done)
	return side


# ── The two lists ───────────────────────────────────────────────────────────


func _rebuild_lists() -> void:
	for c: Node in _lists.get_children():
		c.queue_free()

	_lists.add_child(_label("EXPRESSIONS  (first is the default)"))
	var portraits: Array = _portraits()
	for i: int in portraits.size():
		_lists.add_child(_make_portrait_row(i))
	var add_portrait: Button = Button.new()
	add_portrait.text = "＋ ADD EXPRESSION"
	add_portrait.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_portrait, UITheme.PURPLE_MID)
	add_portrait.pressed.connect(_add_portrait)
	_lists.add_child(add_portrait)

	_lists.add_child(HSeparator.new())
	_lists.add_child(_label("POSITIONS  (drag on the stage to move)"))
	var solo: CheckBox = CheckBox.new()
	solo.text = "Only show selected"
	solo.add_theme_font_size_override("font_size", 10)
	solo.button_pressed = _solo
	solo.toggled.connect(
		func(on: bool) -> void:
			_solo = on
			_apply_solo()
	)
	_lists.add_child(solo)

	var placements: Array = _placements()
	for i: int in placements.size():
		_lists.add_child(_make_placement_row(i))
	var add_position: Button = Button.new()
	add_position.text = "＋ ADD POSITION"
	add_position.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_position, UITheme.PURPLE_MID)
	add_position.pressed.connect(_add_placement)
	_lists.add_child(add_position)


# One expression: choosing it re-dresses every box on the stage, so a whole character can be judged in
# one look rather than one position at a time.
func _make_portrait_row(index: int) -> Control:
	var portrait: Dictionary = _portraits()[index]

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.set_corner_radius_all(UITheme.CORNER_RADIUS)
	ps.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", ps)
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	panel.add_child(col)

	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	var pick: Button = Button.new()
	# Recomputed rather than written once, so typing a name can update this button without rebuilding
	# the list — a rebuild frees the very field being typed into, and the focus goes with it.
	var relabel: Callable = func() -> void:
		var current: String = str(portrait.get("name", "")).strip_edges()
		pick.text = (
			"%s%s"
			% [
				current if current != "" else "Expression %d" % (index + 1),
				"  ·  DEFAULT" if index == 0 else "",
			]
		)
	relabel.call()
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick.clip_text = true
	UITheme.style_button(
		pick, UITheme.PURPLE_BRIGHT if index == _portrait_idx else UITheme.PURPLE_MID
	)
	pick.pressed.connect(
		func() -> void:
			_portrait_idx = index
			_refresh()
	)
	head.add_child(pick)
	var drop: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	drop.pressed.connect(func() -> void: _delete_portrait(index))
	head.add_child(drop)
	col.add_child(head)

	if index != _portrait_idx:
		return panel

	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(portrait.get("name", ""))
	name_edit.placeholder_text = "Expression name (e.g. Happy)..."
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(
		func(v: String) -> void:
			portrait["name"] = v
			relabel.call()  # NOT _rebuild_lists: that would free this field mid-keystroke
	)
	col.add_child(name_edit)

	var zone: PanelContainer = DropZoneScript.new()
	zone.accepted_extensions = JourneyData.ANIMATED_IMAGE_EXTENSIONS.duplicate()
	zone.picker_title = "Select Portrait Image"
	zone.picker_filters = [
		"*.png,*.jpg,*.jpeg,*.webp,*.gif,*.apng,*.mp4,*.m4v,*.webm,*.mkv,*.mov ; Portrait (image or animation)"
	]
	zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(zone)
	if str(portrait.get("path", "")) != "":
		# emit:false — set_file fires file_dropped by default, and this is a restore, not a drop.
		zone.call_deferred("set_file", str(portrait.get("path", "")), false)
	zone.file_dropped.connect(
		func(path: String) -> void:
			portrait["path"] = path
			_rebuild_boxes()  # the stage is the feedback; no full refresh, so the list keeps its scroll
	)
	return panel


func _make_placement_row(index: int) -> Control:
	var placement: Dictionary = _placements()[index]

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var pick: Button = Button.new()
	var relabel: Callable = func() -> void:
		pick.text = str(placement.get("name", "Position %d" % (index + 1)))
	relabel.call()
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick.clip_text = true
	UITheme.style_button(
		pick, UITheme.PURPLE_BRIGHT if index == _placement_idx else UITheme.PURPLE_MID
	)
	pick.pressed.connect(
		func() -> void:
			_placement_idx = index
			_rebuild_lists()
			_style_boxes()
			_apply_solo()
	)
	row.add_child(pick)
	var drop: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	drop.pressed.connect(func() -> void: _delete_placement(index))
	row.add_child(drop)
	col.add_child(row)

	if index != _placement_idx:
		return col

	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(placement.get("name", ""))
	UITheme.style_line_edit(name_edit)
	# The three seeded positions are the vocabulary a line's `stage` refers to, so their names are fixed.
	name_edit.editable = not bool(placement.get("builtin", false))
	name_edit.text_changed.connect(
		func(v: String) -> void:
			placement["name"] = v
			relabel.call()
			_relabel_box(index)  # the box on the stage carries the name too
	)
	col.add_child(name_edit)
	return col


# ── The stage ───────────────────────────────────────────────────────────────


func _rebuild_boxes() -> void:
	for box: Variant in _boxes:
		if is_instance_valid(box):
			(box as Control).queue_free()
	_boxes.clear()
	for i: int in _placements().size():
		_boxes.append(_make_box(i))
	_apply_solo()


func _make_box(index: int) -> Control:
	var placement: Dictionary = _placements()[index]
	var box: Panel = Panel.new()
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_box_rect(box, placement)
	_stage.add_child(box)

	var portrait: String = _shown_portrait_path()
	if portrait != "":
		var view: JourneyImage = JourneyImage.new()
		view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(view)
		view.show_path(
			portrait, TextureRect.EXPAND_IGNORE_SIZE, TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		)

	var name_lbl: Label = Label.new()
	name_lbl.text = str(placement.get("name", ""))
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.position = Vector2(4, 2)
	box.add_child(name_lbl)

	var handle: Panel = Panel.new()
	handle.custom_minimum_size = Vector2(HANDLE_SIZE, HANDLE_SIZE)
	handle.anchor_left = 1.0
	handle.anchor_top = 1.0
	handle.anchor_right = 1.0
	handle.anchor_bottom = 1.0
	handle.offset_left = -HANDLE_SIZE
	handle.offset_top = -HANDLE_SIZE
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	var hs: StyleBoxFlat = StyleBoxFlat.new()
	hs.bg_color = UITheme.PURPLE_BRIGHT
	hs.set_corner_radius_all(3)
	handle.add_theme_stylebox_override("panel", hs)
	box.add_child(handle)

	box.gui_input.connect(func(e: InputEvent) -> void: _on_box_input(index, box, e))
	handle.gui_input.connect(func(e: InputEvent) -> void: _on_handle_input(index, box, e))
	_style_box(box, index == _placement_idx)
	return box


# Placements are fractions of the SCREEN — a portrait belongs to the viewport, not to something painted
# in the backdrop — so these are plain anchors rather than the image-space maths a node layout uses.
func _apply_box_rect(box: Control, placement: Dictionary) -> void:
	box.anchor_left = clampf(float(placement["x"]), 0.0, 1.0)
	box.anchor_top = clampf(float(placement["y"]), 0.0, 1.0)
	box.anchor_right = clampf(float(placement["x"]) + float(placement["w"]), 0.0, 1.0)
	box.anchor_bottom = clampf(float(placement["y"]) + float(placement["h"]), 0.0, 1.0)
	box.offset_left = 0.0
	box.offset_top = 0.0
	box.offset_right = 0.0
	box.offset_bottom = 0.0


func _style_box(box: Panel, selected: bool) -> void:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.28 if selected else 0.16)
	style.border_color = UITheme.PURPLE_BRIGHT if selected else UITheme.SEPARATOR
	style.set_border_width_all(2 if selected else 1)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	box.add_theme_stylebox_override("panel", style)


# Updates the caption drawn on one stage box, without rebuilding it — the box holds a live drag and a
# loaded portrait, neither of which should be thrown away to change a word.
func _relabel_box(index: int) -> void:
	if index < 0 or index >= _boxes.size() or not is_instance_valid(_boxes[index]):
		return
	for child: Node in (_boxes[index] as Control).get_children():
		if child is Label:
			(child as Label).text = str(_placements()[index].get("name", ""))
			return


func _style_boxes() -> void:
	for i: int in _boxes.size():
		if is_instance_valid(_boxes[i]):
			_style_box(_boxes[i] as Panel, i == _placement_idx)


func _apply_solo() -> void:
	for i: int in _boxes.size():
		if is_instance_valid(_boxes[i]):
			(_boxes[i] as Control).visible = not _solo or i == _placement_idx


func _on_box_input(index: int, box: Panel, event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_placement_idx = index
		_rebuild_lists()
		_style_boxes()
		return
	if not (event is InputEventMouseMotion):
		return
	var motion: InputEventMouseMotion = event
	if not (motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
		return
	var stage: Vector2 = _stage.size
	if stage.x <= 0.0 or stage.y <= 0.0:
		return
	var placement: Dictionary = _placements()[index]
	placement["x"] = clampf(float(placement["x"]) + motion.relative.x / stage.x, 0.0, 1.0)
	placement["y"] = clampf(float(placement["y"]) + motion.relative.y / stage.y, 0.0, 1.0)
	_apply_box_rect(box, placement)


func _on_handle_input(index: int, box: Panel, event: InputEvent) -> void:
	if not (event is InputEventMouseMotion):
		return
	var motion: InputEventMouseMotion = event
	if not (motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
		return
	var stage: Vector2 = _stage.size
	if stage.x <= 0.0 or stage.y <= 0.0:
		return
	var placement: Dictionary = _placements()[index]
	placement["w"] = clampf(
		float(placement["w"]) + motion.relative.x / stage.x, JourneyData.PLACEMENT_MIN_SIZE, 1.0
	)
	placement["h"] = clampf(
		float(placement["h"]) + motion.relative.y / stage.y, JourneyData.PLACEMENT_MIN_SIZE, 1.0
	)
	_apply_box_rect(box, placement)


# ── Backdrop pickers ────────────────────────────────────────────────────────


func _make_setting_picker() -> OptionButton:
	var picker: OptionButton = OptionButton.new()
	picker.clip_text = true
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.add_item("(none)")
	picker.set_item_metadata(0, "")
	for setting: Variant in _settings:
		if not (setting is Dictionary):
			continue
		var name: String = str((setting as Dictionary).get("name", "")).strip_edges()
		picker.add_item(name if name != "" else "(unnamed)")
		picker.set_item_metadata(picker.item_count - 1, setting)
	picker.item_selected.connect(
		func(i: int) -> void:
			var chosen: Variant = picker.get_item_metadata(i)
			_preview_setting = chosen if chosen is Dictionary else {}
			_rebuild_variant_picker()
			_show_backdrop("")
	)
	return picker


# Which variant of the chosen place — shown only when there is more than one. Day and night light a
# room differently enough to move where a portrait should stand.
func _rebuild_variant_picker() -> void:
	for c: Node in _variant_holder.get_children():
		c.queue_free()
	var backgrounds: Array = _preview_setting.get("backgrounds", [])
	if backgrounds.size() < 2:
		return
	var picker: OptionButton = OptionButton.new()
	picker.clip_text = true
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i: int in backgrounds.size():
		var bg: Dictionary = backgrounds[i]
		var name: String = str(bg.get("name", "")).strip_edges()
		picker.add_item(name if name != "" else "Variant %d" % (i + 1))
		picker.set_item_metadata(i, str(bg.get("id", "")))
	picker.selected = 0
	picker.item_selected.connect(
		func(i: int) -> void: _show_backdrop(str(picker.get_item_metadata(i)))
	)
	_variant_holder.add_child(picker)


func _show_backdrop(background_id: String) -> void:
	if _preview_setting.is_empty():
		_backdrop.visible = false
		return
	var background: Dictionary = JourneyData.setting_background(_preview_setting, background_id)
	if str(background.get("path", "")) == "":
		_backdrop.visible = false
		return
	_backdrop.visible = true
	# Through show_background so the author's own fit and crop apply — judging a portrait against a
	# differently-framed stand-in would defeat the point.
	_backdrop.show_background(background, TextureRect.STRETCH_KEEP_ASPECT_COVERED)


# ── Mutations ───────────────────────────────────────────────────────────────


func _refresh() -> void:
	_rebuild_lists()
	_rebuild_boxes()


func _add_portrait() -> void:
	(_character["portraits"] as Array).append(
		{"id": JourneyData.new_portrait_id(), "name": "", "path": ""}
	)
	_portrait_idx = _portraits().size() - 1
	_refresh()


func _delete_portrait(index: int) -> void:
	var list: Array = _portraits()
	if index < 0 or index >= list.size():
		return
	list.remove_at(index)
	_portrait_idx = clampi(_portrait_idx, 0, maxi(0, list.size() - 1))
	_refresh()


func _add_placement() -> void:
	(
		(_character["placements"] as Array)
		. append(
			{
				"id": JourneyData.new_placement_id(),
				"name": "Position %d" % (_placements().size() + 1),
				"x": 0.35,
				"y": 0.10,
				"w": 0.30,
				"h": 0.76,
			}
		)
	)
	_placement_idx = _placements().size() - 1
	_refresh()


func _delete_placement(index: int) -> void:
	var list: Array = _placements()
	if index < 0 or index >= list.size():
		return
	list.remove_at(index)
	_placement_idx = clampi(_placement_idx, 0, maxi(0, list.size() - 1))
	_refresh()


# ESC closes. Edits went straight to the live character, so this is the same as pressing DONE.
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	if (event as InputEventKey).keycode != KEY_ESCAPE:
		return
	get_viewport().set_input_as_handled()
	closed.emit()
	queue_free()


func _label(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.SEPARATOR)
	l.add_theme_font_size_override("font_size", 11)
	return l
