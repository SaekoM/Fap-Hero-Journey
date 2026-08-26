class_name PlacementEditor
extends Control

## Visual editor for portrait PLACEMENTS. Shows a 16:9 stage preview with one draggable / resizable box
## per placement (the three built-ins + any customs), a sample portrait inside each so you can size it
## against real art. Drag a box to move it, pull the bottom-right handle to resize. Add / rename / delete
## custom placements; the built-ins can be tuned but not removed. On DONE it emits the roster to persist
## (customs + built-ins that were changed from their code defaults — untouched built-ins stay out).
##
## Placements are screen-fraction boxes {x, y, w, h}; a portrait aspect-fits its box (matches runtime).

signal done(placements: Array)

const HANDLE_SIZE: int = 18

var _working: Array = []  # [{id, name, x, y, w, h, builtin}]
var _sample_portraits: Array = []  # absolute portrait paths, cycled through the boxes for preview
var _selected: int = -1

var _preview: Control = null  # the 16:9 stage area (boxes are its children, positioned by fraction)
var _box_nodes: Array = []  # Control per working placement, index-aligned with _working
var _list_col: VBoxContainer = null  # the side list of placements
# Backdrop preview: a setting's background drawn behind the boxes, so positions are tuned against the
# art they will actually sit on rather than against flat grey.
var _stage_bg: JourneyImage = null
# Solo: show only the selected position. A character with six positions and several expressions stacks
# into an unreadable pile, and the box being dragged is the only one that matters at that moment.
var _solo: bool = false
# The journey's settings library, for the backdrop picker. Empty when the caller has none to offer.
var _settings: Array = []
# The setting currently previewed, and the holder for its variant picker — rebuilt whenever the
# setting changes, because the variants belong to it.
var _preview_setting: Dictionary = {}
var _variant_holder: VBoxContainer = null
var _name_edit: LineEdit = null  # rename field for the selected placement


# `settings` is optional so any existing caller keeps working — without it the backdrop picker simply
# offers "(none)" and the stage stays flat.
func setup(placements: Array, sample_portraits: Array, settings: Array = []) -> void:
	_sample_portraits = sample_portraits
	_settings = settings
	_working = _build_working(placements)
	_build_ui()
	_rebuild_boxes()
	_rebuild_list()
	_select(0)


# Working set = the character's own placements (the three seeded left/center/right + any customs). The
# three seeded ids are marked `builtin` so they can be tuned but not deleted. Empty → seed the defaults.
func _build_working(placements: Array) -> Array:
	var src: Array = (
		placements if not placements.is_empty() else JourneyData.default_character_placements()
	)
	var out: Array = []
	for p: Variant in src:
		if p is Dictionary:
			var c: Dictionary = (p as Dictionary).duplicate()
			c["builtin"] = JourneyData.CHARACTER_SIDES.has(str(c.get("id", "")))
			out.append(c)
	return out


# ── UI scaffold ─────────────────────────────────────────────────────────────


func _build_ui() -> void:
	# Fill the parent (mirrors UITheme.build_centered_modal — explicit anchors, offsets default 0). A
	# PRESET_FULL_RECT here left the root zero-sized, collapsing the panel to its content minimum.
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
	# Near full-screen, matching the clip-editor overlay (FunscriptPreview) — the drag preview wants room.
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

	var header: Label = Label.new()
	header.text = "POSITIONS  —  drag to move, pull the corner to resize"
	header.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	header.add_theme_font_size_override("font_size", 14)
	root.add_child(header)

	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	# Left: the 16:9 stage preview, letterboxed inside an aspect container.
	var stage_wrap: AspectRatioContainer = AspectRatioContainer.new()
	stage_wrap.ratio = 16.0 / 9.0
	stage_wrap.stretch_mode = AspectRatioContainer.STRETCH_FIT
	stage_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(stage_wrap)

	_preview = Control.new()
	_preview.clip_contents = true
	var pv_style: StyleBoxFlat = StyleBoxFlat.new()
	pv_style.bg_color = Color(0.06, 0.06, 0.09, 1.0)
	pv_style.border_color = UITheme.SEPARATOR
	pv_style.set_border_width_all(1)
	var pv_panel: PanelContainer = PanelContainer.new()
	pv_panel.add_theme_stylebox_override("panel", pv_style)
	stage_wrap.add_child(pv_panel)
	pv_panel.add_child(_preview)

	# Behind every box and the VN guide: added first, so nothing has to be re-ordered around it.
	_stage_bg = JourneyImage.new()
	_stage_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stage_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_bg.visible = false
	_preview.add_child(_stage_bg)

	_add_vn_bar_guide()

	# Right: the placement list + add + rename/delete + DONE/CANCEL.
	var side: VBoxContainer = VBoxContainer.new()
	side.add_theme_constant_override("separation", 6)
	side.custom_minimum_size = Vector2(220, 0)
	body.add_child(side)

	side.add_child(_side_label("PREVIEW AGAINST"))
	side.add_child(_make_setting_preview_picker())
	_variant_holder = VBoxContainer.new()
	_variant_holder.add_theme_constant_override("separation", 4)
	side.add_child(_variant_holder)

	var solo_btn: CheckBox = CheckBox.new()
	solo_btn.text = "Only show selected"
	solo_btn.add_theme_font_size_override("font_size", 11)
	solo_btn.toggled.connect(
		func(on: bool) -> void:
			_solo = on
			_apply_solo()
	)
	side.add_child(solo_btn)
	side.add_child(HSeparator.new())

	var list_hdr: Label = Label.new()
	list_hdr.text = "POSITIONS"
	list_hdr.add_theme_color_override("font_color", UITheme.SEPARATOR)
	list_hdr.add_theme_font_size_override("font_size", 11)
	side.add_child(list_hdr)

	_list_col = VBoxContainer.new()
	_list_col.add_theme_constant_override("separation", 3)
	side.add_child(_list_col)

	var add_btn: Button = Button.new()
	add_btn.text = "＋ ADD POSITION"
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(_add_placement)
	side.add_child(add_btn)

	side.add_child(HSeparator.new())
	side.add_child(_side_label("NAME (selected)"))
	_name_edit = LineEdit.new()
	UITheme.style_line_edit(_name_edit)
	_name_edit.text_changed.connect(_on_name_changed)
	side.add_child(_name_edit)

	var del_btn: Button = Button.new()
	del_btn.text = "✕ DELETE POSITION"
	UITheme.style_button(del_btn, UITheme.MAGENTA)
	del_btn.pressed.connect(_delete_selected)
	side.add_child(del_btn)

	var spacer: Control = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(spacer)

	var done_btn: Button = Button.new()
	done_btn.text = "DONE"
	UITheme.style_button(done_btn, UITheme.PURPLE_BRIGHT)
	done_btn.pressed.connect(_finish)
	side.add_child(done_btn)

	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	UITheme.style_button(cancel_btn, UITheme.PURPLE_MID)
	cancel_btn.pressed.connect(queue_free)  # edits a working copy; discarding just drops it
	side.add_child(cancel_btn)


# Picks which setting's background to tune against. "(none)" keeps the flat stage, which is still the
# right answer for a character who appears everywhere rather than in one place.
func _make_setting_preview_picker() -> OptionButton:
	var picker: OptionButton = OptionButton.new()
	picker.clip_text = true
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
			_show_stage_background(_preview_setting, "")
	)
	return picker


# A second picker for WHICH variant, shown only when the chosen setting has more than one. Day and
# Night light a room differently enough to move where a portrait should stand, which is the whole
# reason an author made two.
func _rebuild_variant_picker() -> void:
	for c: Node in _variant_holder.get_children():
		c.queue_free()
	var backgrounds: Array = _preview_setting.get("backgrounds", [])
	if backgrounds.size() < 2:
		return
	_variant_holder.add_child(_side_label("VARIANT"))
	var picker: OptionButton = OptionButton.new()
	picker.clip_text = true
	for i: int in backgrounds.size():
		var bg: Dictionary = backgrounds[i]
		var name: String = str(bg.get("name", "")).strip_edges()
		picker.add_item(name if name != "" else "Variant %d" % (i + 1))
		picker.set_item_metadata(i, str(bg.get("id", "")))
	picker.selected = 0
	picker.item_selected.connect(
		func(i: int) -> void:
			_show_stage_background(_preview_setting, str(picker.get_item_metadata(i)))
	)
	_variant_holder.add_child(picker)


# Draws one variant of the chosen setting, or clears the stage when "(none)" is picked. A blank
# `background_id` means the setting's default, which is what a fresh pick shows.
func _show_stage_background(setting: Dictionary, background_id: String) -> void:
	if setting.is_empty():
		_stage_bg.visible = false
		return
	var background: Dictionary = JourneyData.setting_background(setting, background_id)
	if str(background.get("path", "")) == "":
		_stage_bg.visible = false
		return
	_stage_bg.visible = true
	# Through show_background so the author's own fit and crop alignment apply — the point is to judge
	# a portrait against the backdrop as it will really be framed, not a differently-cropped stand-in.
	_stage_bg.show_background(background, TextureRect.STRETCH_KEEP_ASPECT_COVERED)


# Hides every box but the selected one while solo is on. Kept as its own pass rather than folded into
# _make_box, so selecting a different position re-applies it without rebuilding the boxes.
func _apply_solo() -> void:
	for i: int in _box_nodes.size():
		var box: Control = _box_nodes[i]
		if is_instance_valid(box):
			box.visible = not _solo or i == _selected


func _side_label(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.SEPARATOR)
	l.add_theme_font_size_override("font_size", 10)
	return l


# A translucent strip at the bottom of the preview marking where the VN dialogue bar sits, so the
# author knows a portrait's feet can tuck behind it. Purely a guide — not part of the placement data.
func _add_vn_bar_guide() -> void:
	var bar: ColorRect = ColorRect.new()
	bar.color = Color(UITheme.CYAN.r, UITheme.CYAN.g, UITheme.CYAN.b, 0.12)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.anchor_left = 0.0
	bar.anchor_right = 1.0
	bar.anchor_top = 0.80  # ~ the VN bar height as a fraction of the 16:9 stage
	bar.anchor_bottom = 1.0
	_preview.add_child(bar)


# ── Boxes ───────────────────────────────────────────────────────────────────


func _rebuild_boxes() -> void:
	for b: Control in _box_nodes:
		if is_instance_valid(b):
			b.queue_free()
	_box_nodes.clear()
	for i: int in _working.size():
		_box_nodes.append(_make_box(i))
	_apply_solo()


func _make_box(idx: int) -> Control:
	var p: Dictionary = _working[idx]
	var box: Panel = Panel.new()
	_apply_box_rect(box, p)
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	_style_box(box, idx == _selected)
	_preview.add_child(box)

	# Sample portrait (aspect-fit), cycled through the cast so each box shows real art at its size.
	if not _sample_portraits.is_empty():
		var view: JourneyImage = JourneyImage.new()
		view.set_anchors_preset(Control.PRESET_FULL_RECT)
		view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(view)
		var portrait: String = str(_sample_portraits[idx % _sample_portraits.size()])
		view.show_path(
			portrait, TextureRect.EXPAND_IGNORE_SIZE, TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		)

	var name_lbl: Label = Label.new()
	name_lbl.text = str(p.get("name", ""))
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.position = Vector2(4, 2)
	box.add_child(name_lbl)

	# Resize handle (bottom-right).
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

	box.gui_input.connect(func(e: InputEvent) -> void: _on_box_input(idx, box, e))
	handle.gui_input.connect(func(e: InputEvent) -> void: _on_handle_input(idx, box, e))
	return box


func _apply_box_rect(box: Control, p: Dictionary) -> void:
	box.anchor_left = clampf(float(p["x"]), 0.0, 1.0)
	box.anchor_top = clampf(float(p["y"]), 0.0, 1.0)
	box.anchor_right = clampf(float(p["x"]) + float(p["w"]), 0.0, 1.0)
	box.anchor_bottom = clampf(float(p["y"]) + float(p["h"]), 0.0, 1.0)
	box.offset_left = 0.0
	box.offset_top = 0.0
	box.offset_right = 0.0
	box.offset_bottom = 0.0


func _style_box(box: Panel, selected: bool) -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(
		UITheme.PURPLE_BRIGHT.r, UITheme.PURPLE_BRIGHT.g, UITheme.PURPLE_BRIGHT.b, 0.08
	)
	s.border_color = UITheme.PURPLE_BRIGHT if selected else UITheme.PURPLE_MID
	s.set_border_width_all(2 if selected else 1)
	box.add_theme_stylebox_override("panel", s)


func _on_box_input(idx: int, box: Panel, e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
		_select(idx)
	elif e is InputEventMouseMotion:
		var mm: InputEventMouseMotion = e
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var sz: Vector2 = _preview.size
			if sz.x <= 0 or sz.y <= 0:
				return
			var p: Dictionary = _working[idx]
			p["x"] = clampf(float(p["x"]) + mm.relative.x / sz.x, 0.0, 1.0 - float(p["w"]))
			p["y"] = clampf(float(p["y"]) + mm.relative.y / sz.y, 0.0, 1.0 - float(p["h"]))
			_apply_box_rect(box, p)


func _on_handle_input(idx: int, box: Panel, e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
		_select(idx)
	elif e is InputEventMouseMotion:
		var mm: InputEventMouseMotion = e
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var sz: Vector2 = _preview.size
			if sz.x <= 0 or sz.y <= 0:
				return
			var p: Dictionary = _working[idx]
			var min_s: float = JourneyData.PLACEMENT_MIN_SIZE
			p["w"] = clampf(float(p["w"]) + mm.relative.x / sz.x, min_s, 1.0 - float(p["x"]))
			p["h"] = clampf(float(p["h"]) + mm.relative.y / sz.y, min_s, 1.0 - float(p["y"]))
			_apply_box_rect(box, p)


# ── Side list + selection ───────────────────────────────────────────────────


func _rebuild_list() -> void:
	for c: Node in _list_col.get_children():
		c.queue_free()
	for i: int in _working.size():
		var p: Dictionary = _working[i]
		var btn: Button = Button.new()
		btn.text = "%s%s" % [str(p.get("name", "")), "" if bool(p.get("builtin", false)) else "  ·"]
		btn.focus_mode = Control.FOCUS_NONE
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		UITheme.style_button_subtle(
			btn, UITheme.PURPLE_BRIGHT if i == _selected else UITheme.PURPLE_MID
		)
		var captured: int = i
		btn.pressed.connect(func() -> void: _select(captured))
		_list_col.add_child(btn)


func _select(idx: int) -> void:
	if idx < 0 or idx >= _working.size():
		_selected = -1
		return
	_selected = idx
	for i: int in _box_nodes.size():
		if is_instance_valid(_box_nodes[i]):
			_style_box(_box_nodes[i], i == _selected)
	_apply_solo()  # solo follows the selection, so picking a position swaps which one is shown
	if _name_edit != null:
		_name_edit.text = str(_working[idx].get("name", ""))
		_name_edit.editable = not bool(_working[idx].get("builtin", false))  # built-in names are fixed
	_rebuild_list()


func _on_name_changed(v: String) -> void:
	if _selected < 0 or bool(_working[_selected].get("builtin", false)):
		return
	_working[_selected]["name"] = v
	_rebuild_list()  # the box's own name label refreshes on the next box rebuild (add / delete)


func _add_placement() -> void:
	(
		_working
		. append(
			{
				"id": JourneyData.new_placement_id(),
				"name": "Placement %d" % (_working.size() + 1),
				"x": 0.35,
				"y": 0.15,
				"w": 0.30,
				"h": 0.70,
				"builtin": false,
			}
		)
	)
	_rebuild_boxes()
	_select(_working.size() - 1)


func _delete_selected() -> void:
	if _selected < 0 or bool(_working[_selected].get("builtin", false)):
		return  # built-ins can be tuned but not removed
	_working.remove_at(_selected)
	_rebuild_boxes()
	_select(mini(_selected, _working.size() - 1))


# Emits the character's full placement list (all are stored per-character; the seeded ids stay to keep
# them stable). The `builtin` display flag is stripped.
func _finish() -> void:
	var out: Array = []
	for p: Dictionary in _working:
		(
			out
			. append(
				{
					"id": str(p["id"]),
					"name": str(p.get("name", "")),
					"x": float(p["x"]),
					"y": float(p["y"]),
					"w": float(p["w"]),
					"h": float(p["h"]),
				}
			)
		)
	done.emit(out)
	queue_free()
