class_name BuilderSidePanel
extends RefCounted

# ---------------------------------------------------------------------------
# BuilderSidePanel
# Renders the journey-builder's right-hand editor panel. Owns no state of its
# own — reads from and mutates the JourneyBuilder it was constructed with.
#
# Public entry points:
#   show_journey_info_panel()                 – default view, journey metadata
#   show_node_editor(item, arr, idx)          – per-node editor for a graph selection
#   show_insert_popup(overlay, graph, arr, idx, screen_pos)
#                                             – floating "+" insert picker
#
# Everything else is internal. The owner (JourneyBuilder) is accessed via
# `_owner.<field>` / `_owner.<method>()`.
# ---------------------------------------------------------------------------

const COVER_HEIGHT: int = 280
const ROW_SEP:      int = 8
const DIFFICULTIES: Array = ["Easy", "Medium", "Hard", "Very Hard", "Extreme", "Insane"]

const VIDEO_EXTENSIONS:     Array[String] = ["mp4", "m4v", "mkv", "avi", "mov", "wmv", "webm"]
const FUNSCRIPT_EXTENSIONS: Array[String] = ["funscript", "json"]
const IMAGE_EXTENSIONS:     Array[String] = ["png", "jpg", "jpeg", "webp"]

const DropZoneScript = preload("res://scripts/journey_builder/DropZone.gd")

var _owner: JourneyBuilder


func _init(owner: JourneyBuilder) -> void:
	_owner = owner


# ── Public API ──────────────────────────────────────────────────────────────

func show_insert_popup(overlay: Control, graph: Control, arr: Array, insert_idx: int, screen_pos: Vector2) -> void:
	# Builds a small floating panel with 4 type buttons. Clicking outside it
	# dismisses without inserting.
	var popup: PopupPanel = PopupPanel.new()
	overlay.add_child(popup)

	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG
	panel_style.border_color = UITheme.PURPLE_BRIGHT
	panel_style.border_width_left   = 2; panel_style.border_width_right  = 2
	panel_style.border_width_top    = 2; panel_style.border_width_bottom = 2
	panel_style.content_margin_left   = 6; panel_style.content_margin_right  = 6
	panel_style.content_margin_top    = 6; panel_style.content_margin_bottom = 6
	popup.add_theme_stylebox_override("panel", panel_style)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	popup.add_child(vbox)

	var hdr: Label = Label.new()
	hdr.text = "INSERT HERE"
	hdr.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hdr.add_theme_font_size_override("font_size", 10)
	hdr.uppercase = true
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hdr)

	var specs: Array = [
		{"label": "▶ ROUND",      "color": UITheme.PURPLE_MID,    "item": {"type": "round", "name": "", "funscript_path": "", "video_path": "", "coins": 0}},
		{"label": "◆ SHOP",       "color": UITheme.PURPLE_BRIGHT, "item": {"type": "shop", "title": ""}},
		{"label": "◈ STORYBOARD", "color": UITheme.STORYBOARD,    "item": {"type": "storyboard", "coins": 0, "image": "", "lines": []}},
		{"label": "⑂ FORK",       "color": UITheme.MAGENTA,       "item": {
			"type": "fork", "title": "", "description": "",
			"paths": [
				{"name": "Path A", "description": "", "image_path": "", "items": []},
				{"name": "Path B", "description": "", "image_path": "", "items": []},
			],
		}},
	]
	for spec in specs:
		var btn: Button = Button.new()
		btn.text = spec["label"]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(180, 0)
		UITheme.style_button(btn, spec["color"])
		var item_template: Dictionary = spec["item"]
		btn.pressed.connect(func() -> void:
			arr.insert(insert_idx, item_template.duplicate(true))
			popup.queue_free()
			graph.call_deferred("set_items", _owner._items)
			graph.call_deferred("select_item", arr, insert_idx)
		)
		vbox.add_child(btn)

	popup.popup(Rect2i(Vector2i(screen_pos), Vector2i(0, 0)))


# Default side-panel view (no node selected). Shows journey metadata + quick-add.
func show_journey_info_panel() -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	if side_vbox == null:
		return
	for c in side_vbox.get_children():
		c.queue_free()

	var hdr: Label = Label.new()
	hdr.text = "// JOURNEY INFO //"
	hdr.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_vbox.add_child(hdr)

	# Cover preview + button
	side_vbox.add_child(_side_field_label("COVER IMAGE"))
	var cover_border: PanelContainer = PanelContainer.new()
	cover_border.custom_minimum_size = Vector2(0, COVER_HEIGHT * 0.9)
	var cb_style: StyleBoxFlat = StyleBoxFlat.new()
	cb_style.bg_color           = UITheme.PURPLE_DARK
	cb_style.border_color       = UITheme.PURPLE_MID
	cb_style.border_width_left  = 2; cb_style.border_width_right  = 2
	cb_style.border_width_top   = 2; cb_style.border_width_bottom = 2
	cover_border.add_theme_stylebox_override("panel", cb_style)
	side_vbox.add_child(cover_border)

	var cover_preview: TextureRect = TextureRect.new()
	cover_preview.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	cover_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	cover_preview.clip_contents = true
	if _owner._cover_texture != null:
		cover_preview.texture = _owner._cover_texture
	cover_border.add_child(cover_preview)

	var cover_btn: Button = Button.new()
	cover_btn.text = "DROP IMAGE OR CLICK TO BROWSE" if _owner._cover_path == "" else "CHANGE COVER"
	UITheme.style_button(cover_btn, UITheme.PURPLE_MID)
	cover_btn.pressed.connect(_owner._on_cover_pressed)
	side_vbox.add_child(cover_btn)

	side_vbox.add_child(_side_section_separator())

	# Name
	side_vbox.add_child(_side_field_label("JOURNEY NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Journey name..."
	name_edit.text = _owner._journey_name
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(val: String) -> void: _owner._journey_name = val)
	side_vbox.add_child(name_edit)

	# Author
	side_vbox.add_child(_side_field_label("AUTHOR"))
	var author_edit: LineEdit = LineEdit.new()
	author_edit.placeholder_text = "Author name..."
	author_edit.text = _owner._journey_author
	UITheme.style_line_edit(author_edit)
	author_edit.text_changed.connect(func(val: String) -> void: _owner._journey_author = val)
	side_vbox.add_child(author_edit)

	# Difficulty
	side_vbox.add_child(_side_field_label("DIFFICULTY"))
	var diff_btn: OptionButton = OptionButton.new()
	for diff: String in DIFFICULTIES:
		diff_btn.add_item(diff)
	diff_btn.selected = _owner._journey_difficulty_idx
	UITheme.style_option_button(diff_btn)
	diff_btn.item_selected.connect(func(idx: int) -> void: _owner._journey_difficulty_idx = idx)
	side_vbox.add_child(diff_btn)

	# Description
	side_vbox.add_child(_side_field_label("DESCRIPTION"))
	var desc_edit: TextEdit = TextEdit.new()
	desc_edit.placeholder_text = "Optional description..."
	desc_edit.text = _owner._journey_desc
	desc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_edit.custom_minimum_size = Vector2(0, 90)
	desc_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(desc_edit)
	desc_edit.text_changed.connect(func() -> void: _owner._journey_desc = desc_edit.text)
	side_vbox.add_child(desc_edit)

	side_vbox.add_child(_side_section_separator())

	# Quick-add buttons to top level
	var add_lbl: Label = Label.new()
	add_lbl.text = "ADD TO TOP LEVEL"
	add_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	add_lbl.add_theme_font_size_override("font_size", 10)
	add_lbl.uppercase = true
	side_vbox.add_child(add_lbl)

	var add_specs: Array = [
		{"label": "+ ROUND",      "color": UITheme.PURPLE_MID,    "item": {"type": "round", "name": "", "funscript_path": "", "video_path": "", "coins": 0}},
		{"label": "◆ SHOP",       "color": UITheme.PURPLE_BRIGHT, "item": {"type": "shop", "title": ""}},
		{"label": "◈ STORYBOARD", "color": UITheme.STORYBOARD,    "item": {"type": "storyboard", "coins": 0, "image": "", "lines": []}},
		{"label": "⑂ FORK",       "color": UITheme.MAGENTA,       "item": {
			"type": "fork", "title": "", "description": "",
			"paths": [
				{"name": "Path A", "description": "", "image_path": "", "items": []},
				{"name": "Path B", "description": "", "image_path": "", "items": []},
			],
		}},
	]
	for spec in add_specs:
		var btn: Button = Button.new()
		btn.text = spec["label"]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(btn, spec["color"])
		var item_template: Dictionary = spec["item"]
		btn.pressed.connect(func() -> void:
			_owner._items.append(item_template.duplicate(true))
			_owner._refresh_graph()
		)
		side_vbox.add_child(btn)


# Builds the editor for the currently selected node into the side panel.
func show_node_editor(item: Dictionary, arr: Array, idx: int) -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	for c in side_vbox.get_children():
		c.queue_free()
	_build_side_panel_editor(side_vbox, item, arr, idx, _owner._graph)


# ── Internal: per-type editors ──────────────────────────────────────────────

# Dispatches to the right inline editor based on item type. The path-item
# editors work directly on the parent array reference, so edits persist back
# into _items at any nesting depth.
func _build_side_panel_editor(
		container: VBoxContainer,
		item: Dictionary,
		arr: Array,
		idx: int,
		graph: Control) -> void:
	var t: String = item.get("type", "round")

	var hdr: Label = Label.new()
	var accent: Color
	match t:
		"round":      hdr.text = "// ROUND //";      accent = UITheme.PURPLE_BRIGHT
		"shop":       hdr.text = "// SHOP //";       accent = UITheme.PURPLE_BRIGHT
		"storyboard": hdr.text = "// STORYBOARD //"; accent = UITheme.STORYBOARD
		"fork":       hdr.text = "// FORK //";       accent = UITheme.MAGENTA
		_:            hdr.text = "// ITEM //";       accent = UITheme.PURPLE_MID
	hdr.add_theme_color_override("font_color", accent)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	container.add_child(hdr)

	# Called by editors after a structural change (move / delete / add line) to
	# refresh both the graph and the side panel for the new state.
	var reselect: Callable = func(new_idx: int) -> void:
		graph.select_item(arr, new_idx)

	match t:
		"round":
			container.add_child(_make_side_round_editor(arr, idx, graph, reselect))
		"shop":
			container.add_child(_make_side_shop_editor(arr, idx, graph, reselect))
		"storyboard":
			container.add_child(_make_side_storyboard_editor(arr, idx, graph, reselect))
		"fork":
			container.add_child(_make_fork_compact_editor(arr, idx, graph, reselect))


# ── Internal: small helpers ─────────────────────────────────────────────────

func _side_field_label(text: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.uppercase = true
	return lbl


func _side_section_separator() -> Control:
	var spacer: Control = Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	return spacer


# Bottom row of move/delete buttons used by every side-panel editor.
func _side_action_row(arr: Array, idx: int, graph: Control, reselect: Callable) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var up_btn: Button = UITheme.make_icon_btn("↑ MOVE UP", idx == 0, UITheme.PURPLE_MID)
	up_btn.custom_minimum_size = Vector2(0, 0)
	up_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	up_btn.pressed.connect(func() -> void:
		if idx <= 0: return
		var tmp: Dictionary = arr[idx]
		arr[idx]     = arr[idx - 1]
		arr[idx - 1] = tmp
		reselect.call(idx - 1)
	)
	row.add_child(up_btn)

	var dn_btn: Button = UITheme.make_icon_btn("↓ MOVE DOWN", idx == arr.size() - 1, UITheme.PURPLE_MID)
	dn_btn.custom_minimum_size = Vector2(0, 0)
	dn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dn_btn.pressed.connect(func() -> void:
		if idx >= arr.size() - 1: return
		var tmp: Dictionary = arr[idx]
		arr[idx]     = arr[idx + 1]
		arr[idx + 1] = tmp
		reselect.call(idx + 1)
	)
	row.add_child(dn_btn)

	var rm_btn: Button = UITheme.make_icon_btn("✕ DELETE", false, UITheme.MAGENTA)
	rm_btn.custom_minimum_size = Vector2(0, 0)
	rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rm_btn.pressed.connect(func() -> void:
		arr.remove_at(idx)
		reselect.call(-1)
	)
	row.add_child(rm_btn)

	return row


# ── Internal: round / shop / storyboard / fork inline editors ──────────────

func _make_side_round_editor(arr: Array, idx: int, graph: Control, reselect: Callable) -> Control:
	var round_data: Dictionary = arr[idx]
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	col.add_child(_side_field_label("ROUND NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Round name..."
	name_edit.text             = round_data.get("name", "")
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(val: String) -> void:
		arr[idx]["name"] = val
	)
	col.add_child(name_edit)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("VIDEO FILE"))
	var video_zone: PanelContainer = DropZoneScript.new()
	video_zone.accepted_extensions   = VIDEO_EXTENSIONS.duplicate()
	video_zone.picker_title          = "Select Video"
	video_zone.picker_filters        = ["*.mp4,*.m4v,*.mkv,*.avi,*.mov,*.wmv,*.webm ; Video Files", "*.* ; All Files"]
	video_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(video_zone)
	if round_data.get("video_path", "") != "":
		video_zone.call_deferred("set_file", round_data["video_path"])
	video_zone.file_dropped.connect(func(p: String) -> void:
		arr[idx]["video_path"] = p
		if (arr[idx].get("name","") as String).strip_edges() == "":
			var auto: String = p.get_file().get_basename()
			arr[idx]["name"] = auto
			name_edit.text = auto
	)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("FUNSCRIPT"))
	var fs_zone: PanelContainer = DropZoneScript.new()
	fs_zone.accepted_extensions   = FUNSCRIPT_EXTENSIONS.duplicate()
	fs_zone.picker_title          = "Select Funscript"
	fs_zone.picker_filters        = ["*.funscript,*.json ; Funscript Files", "*.* ; All Files"]
	fs_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(fs_zone)
	if round_data.get("funscript_path", "") != "":
		fs_zone.call_deferred("set_file", round_data["funscript_path"])
	fs_zone.file_dropped.connect(func(p: String) -> void:
		arr[idx]["funscript_path"] = p
		if (arr[idx].get("name","") as String).strip_edges() == "":
			var auto: String = p.get_file().get_basename()
			arr[idx]["name"] = auto
			name_edit.text = auto
	)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("COINS AWARDED"))
	var coins_edit: LineEdit = LineEdit.new()
	coins_edit.text             = str(round_data.get("coins", 0))
	coins_edit.max_length       = 6
	coins_edit.placeholder_text = "0"
	UITheme.style_line_edit(coins_edit)
	coins_edit.text_changed.connect(func(val: String) -> void:
		arr[idx]["coins"] = val.to_int()
	)
	col.add_child(coins_edit)

	col.add_child(_side_section_separator())
	col.add_child(_side_action_row(arr, idx, graph, reselect))
	return col


func _make_side_shop_editor(arr: Array, idx: int, graph: Control, reselect: Callable) -> Control:
	var shop_data: Dictionary = arr[idx]
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	col.add_child(_side_field_label("SHOP TITLE"))
	var title_edit: LineEdit = LineEdit.new()
	title_edit.placeholder_text = "Shop title (optional)..."
	title_edit.text             = shop_data.get("title", "")
	UITheme.style_line_edit(title_edit)
	title_edit.text_changed.connect(func(val: String) -> void:
		arr[idx]["title"] = val
	)
	col.add_child(title_edit)

	col.add_child(_side_section_separator())
	col.add_child(_side_action_row(arr, idx, graph, reselect))
	return col


func _make_side_storyboard_editor(arr: Array, idx: int, graph: Control, reselect: Callable) -> Control:
	var sb_data: Dictionary = arr[idx]
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	col.add_child(_side_field_label("COINS AWARDED"))
	var coins_edit: LineEdit = LineEdit.new()
	coins_edit.text             = str(sb_data.get("coins", 0))
	coins_edit.max_length       = 6
	coins_edit.placeholder_text = "0"
	UITheme.style_line_edit(coins_edit)
	coins_edit.text_changed.connect(func(val: String) -> void:
		arr[idx]["coins"] = val.to_int()
	)
	col.add_child(coins_edit)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("DEFAULT IMAGE"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions   = IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title          = "Select Default Image"
	img_zone.picker_filters        = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(img_zone)
	if sb_data.get("image", "") != "":
		img_zone.call_deferred("set_file", sb_data["image"])
	img_zone.file_dropped.connect(func(p: String) -> void:
		arr[idx]["image"] = p
	)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("DIALOGUE LINES"))

	var lines_arr: Array = sb_data.get("lines", [])
	if not sb_data.has("lines"):
		arr[idx]["lines"] = lines_arr

	var lines_col: VBoxContainer = VBoxContainer.new()
	lines_col.add_theme_constant_override("separation", 6)
	col.add_child(lines_col)

	var refresh_self: Callable = func() -> void:
		reselect.call(idx)

	for li in lines_arr.size():
		lines_col.add_child(_make_side_storyboard_line_block(lines_arr, li, refresh_self))

	var add_row: HBoxContainer = HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 6)
	col.add_child(add_row)

	var add_line_btn: Button = Button.new()
	add_line_btn.text = "+ ADD LINE"
	add_line_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_line_btn, UITheme.STORYBOARD)
	add_line_btn.pressed.connect(func() -> void:
		lines_arr.append({"speaker": "", "text": "", "image": ""})
		refresh_self.call()
	)
	add_row.add_child(add_line_btn)

	var paste_btn: Button = Button.new()
	paste_btn.text = "⎘ PASTE LINES"
	paste_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(paste_btn, UITheme.PURPLE_MID)
	paste_btn.pressed.connect(func() -> void:
		_show_paste_lines_popup(lines_arr, refresh_self)
	)
	add_row.add_child(paste_btn)

	col.add_child(_side_section_separator())
	col.add_child(_side_action_row(arr, idx, graph, reselect))
	return col


# Opens a popup with a large TextEdit. Each non-empty line of the pasted text
# becomes a new dialogue line. Format: "SPEAKER: text" splits on the first
# colon; lines without a colon become narration (no speaker).
func _show_paste_lines_popup(lines_arr: Array, refresh_storyboard: Callable) -> void:
	var popup: PopupPanel = PopupPanel.new()
	_owner.add_child(popup)

	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG
	panel_style.border_color = UITheme.STORYBOARD
	panel_style.border_width_left   = 2; panel_style.border_width_right  = 2
	panel_style.border_width_top    = 2; panel_style.border_width_bottom = 2
	panel_style.content_margin_left   = 16; panel_style.content_margin_right  = 16
	panel_style.content_margin_top    = 16; panel_style.content_margin_bottom = 16
	popup.add_theme_stylebox_override("panel", panel_style)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	popup.add_child(vbox)

	var hdr: Label = Label.new()
	hdr.text = "// PASTE DIALOGUE LINES //"
	hdr.add_theme_color_override("font_color", UITheme.STORYBOARD)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hdr)

	var hint: Label = Label.new()
	hint.text = "ONE LINE PER DIALOGUE.  FORMAT:  SPEAKER: text  (LINES WITHOUT A COLON BECOME NARRATION.)"
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)

	var text_edit: TextEdit = TextEdit.new()
	text_edit.placeholder_text = "ARIA: Hello there.\nThe wind howled outside.\nKAI: It's getting cold."
	text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_edit.size_flags_vertical   = Control.SIZE_FILL
	text_edit.custom_minimum_size = Vector2(0, 200)
	text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(text_edit)
	vbox.add_child(text_edit)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(cancel_btn, UITheme.PURPLE_MID)
	cancel_btn.pressed.connect(func() -> void: popup.queue_free())
	btn_row.add_child(cancel_btn)

	var apply_btn: Button = Button.new()
	apply_btn.text = "+ APPEND LINES"
	apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(apply_btn, UITheme.STORYBOARD)
	apply_btn.pressed.connect(func() -> void:
		var parsed: Array = _parse_pasted_lines(text_edit.text)
		for line: Dictionary in parsed:
			lines_arr.append(line)
		popup.queue_free()
		refresh_storyboard.call()
	)
	btn_row.add_child(apply_btn)

	popup.popup_centered_clamped(Vector2i(720, 560), 0.9)
	text_edit.grab_focus()


# Parses a pasted multi-line block into dialogue-line dicts.
# Format: "SPEAKER: text" → {speaker: "SPEAKER", text: "text"}.
# Lines without a colon become narration: {speaker: "", text: "<line>"}.
# Blank lines are skipped.
func _parse_pasted_lines(raw: String) -> Array:
	var result: Array = []
	for raw_line in raw.split("\n"):
		var line: String = (raw_line as String).strip_edges()
		if line == "":
			continue
		var colon_idx: int = line.find(":")
		if colon_idx > 0:
			var speaker: String = line.substr(0, colon_idx).strip_edges()
			var text: String = line.substr(colon_idx + 1).strip_edges()
			result.append({"speaker": speaker, "text": text, "image": ""})
		else:
			result.append({"speaker": "", "text": line, "image": ""})
	return result


# Per-line sub-block for the storyboard side editor: speaker, text (multi-line),
# optional per-line image override, and line move/remove buttons.
func _make_side_storyboard_line_block(lines_arr: Array, line_idx: int, refresh_storyboard: Callable) -> Control:
	var line_data: Dictionary = lines_arr[line_idx]

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color            = UITheme.PANEL_BG
	ps.border_color        = Color(UITheme.STORYBOARD.r, UITheme.STORYBOARD.g, UITheme.STORYBOARD.b, 0.35)
	ps.border_width_left   = 1; ps.border_width_right  = 1
	ps.border_width_top    = 1; ps.border_width_bottom = 1
	ps.content_margin_left = 10; ps.content_margin_right  = 10
	ps.content_margin_top  = 8;  ps.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", ps)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	panel.add_child(col)

	var hdr_lbl: Label = Label.new()
	hdr_lbl.text = "LINE %d" % (line_idx + 1)
	hdr_lbl.add_theme_color_override("font_color", UITheme.STORYBOARD)
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr_lbl.uppercase = true
	col.add_child(hdr_lbl)

	col.add_child(_side_field_label("SPEAKER"))
	var speaker_edit: LineEdit = LineEdit.new()
	speaker_edit.placeholder_text = "Speaker (optional)..."
	speaker_edit.text             = line_data.get("speaker", "")
	UITheme.style_line_edit(speaker_edit)
	speaker_edit.text_changed.connect(func(val: String) -> void:
		lines_arr[line_idx]["speaker"] = val
	)
	col.add_child(speaker_edit)

	col.add_child(_side_field_label("DIALOGUE"))
	var text_edit: TextEdit = TextEdit.new()
	text_edit.placeholder_text     = "Dialogue text..."
	text_edit.text                  = line_data.get("text", "")
	text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_edit.custom_minimum_size   = Vector2(0, 90)
	text_edit.wrap_mode             = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(text_edit)
	text_edit.text_changed.connect(func() -> void:
		lines_arr[line_idx]["text"] = text_edit.text
	)
	col.add_child(text_edit)

	col.add_child(_side_field_label("SPEAKER IMAGE (OPTIONAL)"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions   = IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title          = "Select Speaker Image for Line %d" % (line_idx + 1)
	img_zone.picker_filters        = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(img_zone)
	if line_data.get("image", "") != "":
		img_zone.call_deferred("set_file", line_data["image"])
	img_zone.file_dropped.connect(func(p: String) -> void:
		lines_arr[line_idx]["image"] = p
	)

	# Line action row (move + delete).
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var up_btn: Button = UITheme.make_icon_btn("↑", line_idx == 0, UITheme.STORYBOARD)
	up_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	up_btn.pressed.connect(func() -> void:
		if line_idx <= 0: return
		var tmp: Dictionary = lines_arr[line_idx]
		lines_arr[line_idx]     = lines_arr[line_idx - 1]
		lines_arr[line_idx - 1] = tmp
		refresh_storyboard.call()
	)
	row.add_child(up_btn)
	var dn_btn: Button = UITheme.make_icon_btn("↓", line_idx == lines_arr.size() - 1, UITheme.STORYBOARD)
	dn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dn_btn.pressed.connect(func() -> void:
		if line_idx >= lines_arr.size() - 1: return
		var tmp: Dictionary = lines_arr[line_idx]
		lines_arr[line_idx]     = lines_arr[line_idx + 1]
		lines_arr[line_idx + 1] = tmp
		refresh_storyboard.call()
	)
	row.add_child(dn_btn)
	var rm_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rm_btn.pressed.connect(func() -> void:
		lines_arr.remove_at(line_idx)
		refresh_storyboard.call()
	)
	row.add_child(rm_btn)
	col.add_child(row)

	return panel


func _make_fork_compact_editor(arr: Array, idx: int, graph: Control, reselect: Callable) -> Control:
	var item: Dictionary = arr[idx]

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)

	var title_lbl: Label = Label.new()
	title_lbl.text = "TITLE"
	title_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	title_lbl.add_theme_font_size_override("font_size", 10)
	title_lbl.uppercase = true
	col.add_child(title_lbl)

	var title_edit: LineEdit = LineEdit.new()
	title_edit.placeholder_text = "Fork title (optional)..."
	title_edit.text = item.get("title", "")
	UITheme.style_line_edit(title_edit)
	title_edit.text_changed.connect(func(val: String) -> void:
		arr[idx]["title"] = val
	)
	col.add_child(title_edit)

	var desc_lbl: Label = Label.new()
	desc_lbl.text = "DESCRIPTION"
	desc_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	desc_lbl.add_theme_font_size_override("font_size", 10)
	desc_lbl.uppercase = true
	col.add_child(desc_lbl)

	var desc_edit: LineEdit = LineEdit.new()
	desc_edit.placeholder_text = "Fork description (optional)..."
	desc_edit.text = item.get("description", "")
	UITheme.style_line_edit(desc_edit)
	desc_edit.text_changed.connect(func(val: String) -> void:
		arr[idx]["description"] = val
	)
	col.add_child(desc_edit)

	var paths_lbl: Label = Label.new()
	paths_lbl.text = "PATHS"
	paths_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	paths_lbl.add_theme_font_size_override("font_size", 10)
	paths_lbl.uppercase = true
	col.add_child(paths_lbl)

	var paths_arr: Array = item.get("paths", [])
	if not item.has("paths"):
		arr[idx]["paths"] = paths_arr

	for pi in paths_arr.size():
		col.add_child(_make_path_editor_block(paths_arr, pi, graph, reselect))

	if paths_arr.size() < 4:
		var add_path_btn: Button = Button.new()
		add_path_btn.text = "+ ADD PATH"
		add_path_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(add_path_btn, UITheme.PURPLE_MID)
		add_path_btn.pressed.connect(func() -> void:
			paths_arr.append({
				"name": "Path %s" % char(65 + paths_arr.size()),
				"description": "",
				"image_path": "",
				"items": [],
			})
			reselect.call(idx)
		)
		col.add_child(add_path_btn)

	col.add_child(_side_section_separator())
	col.add_child(_side_action_row(arr, idx, graph, reselect))
	return col


# Per-path editor card inside the fork compact editor.
func _make_path_editor_block(paths_arr: Array, pi: int, graph: Control, reselect: Callable) -> Control:
	var path: Dictionary = paths_arr[pi]

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.08)
	ps.border_color = UITheme.MAGENTA
	ps.border_width_left   = 1; ps.border_width_right  = 1
	ps.border_width_top    = 1; ps.border_width_bottom = 1
	ps.content_margin_left = 10; ps.content_margin_right  = 10
	ps.content_margin_top  = 8;  ps.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", ps)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sub: VBoxContainer = VBoxContainer.new()
	sub.add_theme_constant_override("separation", 4)
	panel.add_child(sub)

	var hdr: HBoxContainer = HBoxContainer.new()
	hdr.add_theme_constant_override("separation", ROW_SEP)
	sub.add_child(hdr)

	var path_lbl: Label = Label.new()
	path_lbl.text = "PATH %d" % (pi + 1)
	path_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	path_lbl.add_theme_font_size_override("font_size", 11)
	path_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(path_lbl)

	if paths_arr.size() > 2:
		var rm_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
		rm_btn.pressed.connect(func() -> void:
			paths_arr.remove_at(pi)
			graph.call_deferred("refresh")
		)
		hdr.add_child(rm_btn)

	sub.add_child(_side_field_label("NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Path name..."
	name_edit.text = path.get("name", "")
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(val: String) -> void:
		paths_arr[pi]["name"] = val
	)
	sub.add_child(name_edit)

	sub.add_child(_side_field_label("DESCRIPTION"))
	var desc_edit: LineEdit = LineEdit.new()
	desc_edit.placeholder_text = "Description (optional)..."
	desc_edit.text = path.get("description", "")
	UITheme.style_line_edit(desc_edit)
	desc_edit.text_changed.connect(func(val: String) -> void:
		paths_arr[pi]["description"] = val
	)
	sub.add_child(desc_edit)

	sub.add_child(_side_field_label("CARD IMAGE"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions   = IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title          = "Select Card Image for Path %d" % (pi + 1)
	img_zone.picker_filters        = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub.add_child(img_zone)
	if path.get("image_path", "") != "":
		img_zone.call_deferred("set_file", path["image_path"])
	img_zone.file_dropped.connect(func(p: String) -> void:
		paths_arr[pi]["image_path"] = p
	)

	return panel
