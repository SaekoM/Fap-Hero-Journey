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

# Difficulty list and file-extension sets are owned by JourneyData — the single
# canonical schema. Referenced here as JourneyData.<NAME>.

const DropZoneScript = preload("res://scripts/journey_builder/DropZone.gd")

# T-code secondary axes shown in the collapsible expander for each round.
const EXTRA_AXES_INFO: Array = [
	{"axis": "L1", "label": "L1  —  SURGE  (in / out)"},
	{"axis": "L2", "label": "L2  —  SWAY  (left / right)"},
	{"axis": "R0", "label": "R0  —  TWIST  (rotate)"},
	{"axis": "R1", "label": "R1  —  ROLL  (tilt side)"},
	{"axis": "R2", "label": "R2  —  PITCH  (tilt fwd / back)"},
]

# Vibrator channel drop zones shown in the collapsible expander for each round.
# key matches the vib_scripts dict key used by JourneyBuilder and GameLoop.
const VIB_CHANNELS_INFO: Array = [
	{"key": "vib1", "label": "VIB1  —  CHANNEL 0  (primary motor)"},
	{"key": "vib2", "label": "VIB2  —  CHANNEL 1  (secondary motor)"},
]

# Forced-modifier kinds a boss round can impose. Parallel arrays: KINDS feeds the
# saved data, LABELS feeds the editor dropdown.
const BOSS_MODIFIER_KINDS:  Array = ["scale", "clamp", "reverse", "blackout", "score_multiplier"]
const BOSS_MODIFIER_LABELS: Array = [
	"SCALE  —  STROKE LENGTH",
	"CLAMP  —  POSITION RANGE",
	"REVERSE  —  MIRROR",
	"BLACKOUT  —  HIDE VIDEO",
	"SCORE MULTIPLIER",
]

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
		{"label": "▶ ROUND",      "color": UITheme.PURPLE_MID,    "item": {"type": "round", "name": "", "funscript_path": "", "video_path": "", "coins": 0, "axis_scripts": {}}},
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

	if _owner._cover_path != "":
		var cover_row: HBoxContainer = HBoxContainer.new()
		cover_row.add_theme_constant_override("separation", 6)
		var change_btn: Button = Button.new()
		change_btn.text = "CHANGE COVER"
		change_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(change_btn, UITheme.PURPLE_MID)
		change_btn.pressed.connect(_owner._on_cover_pressed)
		cover_row.add_child(change_btn)
		var cover_rm_btn: Button = Button.new()
		cover_rm_btn.text = "✕ REMOVE"
		cover_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(cover_rm_btn, UITheme.MAGENTA)
		cover_rm_btn.pressed.connect(func() -> void:
			_delete_saved_image(_owner._cover_path)
			_owner._cover_path = ""
			_owner._cover_texture = null
			show_journey_info_panel()
		)
		cover_row.add_child(cover_rm_btn)
		side_vbox.add_child(cover_row)
	else:
		var cover_btn: Button = Button.new()
		cover_btn.text = "DROP IMAGE OR CLICK TO BROWSE"
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
	for diff: String in JourneyData.DIFFICULTIES:
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

	# Tags — toggle chips, one per definition in tags.json.
	side_vbox.add_child(_side_field_label("TAGS"))
	var tag_flow: HFlowContainer = HFlowContainer.new()
	tag_flow.add_theme_constant_override("h_separation", 6)
	tag_flow.add_theme_constant_override("v_separation", 6)
	side_vbox.add_child(tag_flow)
	for tag_def: Dictionary in TagRegistry.all():
		tag_flow.add_child(_make_tag_toggle(tag_def))

	side_vbox.add_child(_side_section_separator())

	# Quick-add buttons to top level
	var add_lbl: Label = Label.new()
	add_lbl.text = "ADD TO TOP LEVEL"
	add_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	add_lbl.add_theme_font_size_override("font_size", 10)
	add_lbl.uppercase = true
	side_vbox.add_child(add_lbl)

	var add_specs: Array = [
		{"label": "+ ROUND",      "color": UITheme.PURPLE_MID,    "item": {"type": "round", "name": "", "funscript_path": "", "video_path": "", "coins": 0, "axis_scripts": {}}},
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


# Toggle chip for one journey tag. Filled with the tag's colour when on,
# faintly tinted when off. Mutates _owner._journey_tags directly.
func _make_tag_toggle(tag_def: Dictionary) -> Button:
	var id: String    = tag_def["id"]
	var color: Color  = tag_def["color"]

	var btn: Button = Button.new()
	btn.text           = tag_def["label"]
	btn.toggle_mode    = true
	btn.button_pressed = id in _owner._journey_tags
	btn.focus_mode     = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 11)

	var off: StyleBoxFlat = StyleBoxFlat.new()
	off.bg_color            = Color(color.r, color.g, color.b, 0.06)
	off.border_color        = Color(color.r, color.g, color.b, 0.45)
	off.border_width_left   = 1; off.border_width_right  = 1
	off.border_width_top    = 1; off.border_width_bottom = 1
	off.corner_radius_top_left    = 6; off.corner_radius_top_right    = 6
	off.corner_radius_bottom_left = 6; off.corner_radius_bottom_right = 6
	off.content_margin_left = 11; off.content_margin_right  = 11
	off.content_margin_top  = 5;  off.content_margin_bottom = 5

	var on: StyleBoxFlat = off.duplicate()
	on.bg_color     = color
	on.border_color = color

	btn.add_theme_stylebox_override("normal",        off)
	btn.add_theme_stylebox_override("hover",         off)
	btn.add_theme_stylebox_override("pressed",       on)
	btn.add_theme_stylebox_override("hover_pressed", on)
	btn.add_theme_stylebox_override("focus",         StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color",               color)
	btn.add_theme_color_override("font_hover_color",         color)
	btn.add_theme_color_override("font_pressed_color",       UITheme.BG)
	btn.add_theme_color_override("font_hover_pressed_color", UITheme.BG)

	btn.toggled.connect(func(on_state: bool) -> void:
		if on_state:
			if id not in _owner._journey_tags:
				_owner._journey_tags.append(id)
		else:
			_owner._journey_tags.erase(id)
	)
	return btn


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

	# Multi-drop hint — shown at the top so it's the first thing the user sees.
	var drop_hint: Label = Label.new()
	drop_hint.text = "TIP: DROP ALL SCRIPTS AT ONCE TO AUTO-ROUTE BY AXIS"
	drop_hint.add_theme_color_override("font_color", Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.7))
	drop_hint.add_theme_font_size_override("font_size", 10)
	drop_hint.uppercase = true
	drop_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	drop_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(drop_hint)

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
	video_zone.accepted_extensions   = JourneyData.VIDEO_EXTENSIONS.duplicate()
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
	fs_zone.accepted_extensions   = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
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
	col.add_child(_make_axis_expander(arr, idx))

	col.add_child(_side_section_separator())
	col.add_child(_make_vib_expander(arr, idx))

	col.add_child(_side_section_separator())
	col.add_child(_make_boss_expander(arr, idx))

	col.add_child(_side_section_separator())
	col.add_child(_side_action_row(arr, idx, graph, reselect))
	return col


func _make_side_shop_editor(arr: Array, idx: int, graph: Control, reselect: Callable) -> Control:
	var shop_data: Dictionary = arr[idx]
	# Backfill config defaults so first-time edits have keys to write to.
	if not shop_data.has("mode"):             shop_data["mode"] = "pool"
	if not shop_data.has("count"):            shop_data["count"] = 3
	if not shop_data.has("items"):            shop_data["items"] = []
	if not shop_data.has("price_multiplier"): shop_data["price_multiplier"] = 1.0

	# Item registry — also bounds the pool-draw count, since a draw can never
	# yield more distinct items than exist. Clamp any stale/out-of-range count.
	var all_item_ids: Array = InventoryService.GetAllItemIds()
	var item_count: int = all_item_ids.size()
	shop_data["count"] = clampi(int(shop_data.get("count", 3)), 1, max(1, item_count))

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

	# Selection mode — random pool draw vs. a fixed authored lineup.
	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("ITEM SELECTION"))
	var mode_dd: OptionButton = OptionButton.new()
	mode_dd.add_item("RANDOM FROM POOL")   # index 0 → "pool"
	mode_dd.add_item("FIXED LINEUP")       # index 1 → "fixed"
	mode_dd.selected = 1 if shop_data.get("mode", "pool") == "fixed" else 0
	mode_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(mode_dd)
	col.add_child(mode_dd)

	# Item count — only consulted in pool mode; disabled in fixed mode where the
	# lineup length is the checklist itself. Clamped to [1, item registry size].
	col.add_child(_side_field_label("ITEMS SHOWN (POOL MODE)"))
	var count_edit: LineEdit = LineEdit.new()
	count_edit.text             = str(shop_data.get("count", 3))
	count_edit.max_length       = 3
	count_edit.placeholder_text = "3"
	count_edit.editable         = shop_data.get("mode", "pool") == "pool"
	UITheme.style_line_edit(count_edit)
	count_edit.text_changed.connect(func(val: String) -> void:
		arr[idx]["count"] = clampi(val.to_int(), 1, max(1, item_count))
	)
	# Snap the displayed text to the clamped value once editing finishes.
	count_edit.focus_exited.connect(func() -> void:
		count_edit.text = str(arr[idx]["count"])
	)
	col.add_child(count_edit)

	# Fixed-lineup checklist — shown only in fixed mode; pool mode draws from all
	# items so the list would just be noise there.
	var items_section: VBoxContainer = VBoxContainer.new()
	items_section.add_theme_constant_override("separation", 6)
	items_section.visible = shop_data.get("mode", "pool") == "fixed"
	col.add_child(items_section)

	items_section.add_child(_side_section_separator())
	items_section.add_child(_side_field_label("ITEMS"))
	var hint: Label = Label.new()
	hint.text = "PICK THE EXACT ITEMS THIS SHOP SELLS."
	hint.add_theme_color_override("font_color", Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.7))
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	items_section.add_child(hint)

	var item_checks: Array[CheckBox] = []
	for item_id: String in all_item_ids:
		var item_data: Dictionary = InventoryService.GetItemData(item_id)
		var cb: CheckBox = CheckBox.new()
		cb.text = "%s  (♦%d)" % [item_data.get("name", item_id), item_data.get("price", 0)]
		cb.button_pressed = item_id in (shop_data.get("items", []) as Array)
		cb.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
		cb.add_theme_font_size_override("font_size", 12)
		cb.toggled.connect(func(pressed: bool) -> void:
			var list: Array = arr[idx]["items"]
			if pressed and item_id not in list:
				list.append(item_id)
			elif not pressed:
				list.erase(item_id)
		)
		item_checks.append(cb)
		items_section.add_child(cb)

	# Switching back to pool mode hides the list and clears the lineup.
	mode_dd.item_selected.connect(func(sel: int) -> void:
		if sel == 1:
			arr[idx]["mode"] = "fixed"
			items_section.visible = true
			count_edit.editable = false
		else:
			arr[idx]["mode"] = "pool"
			items_section.visible = false
			count_edit.editable = true
			(arr[idx]["items"] as Array).clear()
			for cb: CheckBox in item_checks:
				cb.set_pressed_no_signal(false)
	)

	# Price multiplier — applied on top of each item's base price.
	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("PRICE MULTIPLIER"))
	var mult_edit: LineEdit = LineEdit.new()
	mult_edit.text             = str(shop_data.get("price_multiplier", 1.0))
	mult_edit.max_length       = 6
	mult_edit.placeholder_text = "1.0"
	UITheme.style_line_edit(mult_edit)
	mult_edit.text_changed.connect(func(val: String) -> void:
		var m: float = val.to_float()
		arr[idx]["price_multiplier"] = m if m > 0.0 else 1.0
	)
	col.add_child(mult_edit)

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
	img_zone.accepted_extensions   = JourneyData.IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title          = "Select Default Image"
	img_zone.picker_filters        = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(img_zone)
	if sb_data.get("image", "") != "":
		img_zone.call_deferred("set_file", sb_data["image"])
	var sb_rm_btn: Button = Button.new()
	sb_rm_btn.text = "✕ REMOVE DEFAULT IMAGE"
	sb_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb_rm_btn.visible = sb_data.get("image", "") != ""
	UITheme.style_button(sb_rm_btn, UITheme.MAGENTA)
	sb_rm_btn.pressed.connect(func() -> void:
		_delete_saved_image(arr[idx].get("image", ""))
		arr[idx]["image"] = ""
		img_zone.call_deferred("set_file", "")
		sb_rm_btn.visible = false
	)
	img_zone.file_dropped.connect(func(p: String) -> void:
		arr[idx]["image"] = p
		sb_rm_btn.visible = true
	)
	col.add_child(sb_rm_btn)

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

	# Opening slot — insert before the first line (also serves as "add first line").
	lines_col.add_child(_make_insert_line_btn(lines_arr, 0, refresh_self))

	for li in lines_arr.size():
		lines_col.add_child(_make_side_storyboard_line_block(lines_arr, li, refresh_self))
		# Slot after each line; the last one doubles as "append at end".
		lines_col.add_child(_make_insert_line_btn(lines_arr, li + 1, refresh_self))

	var paste_btn: Button = Button.new()
	paste_btn.text = "⎘ PASTE LINES"
	paste_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(paste_btn, UITheme.PURPLE_MID)
	paste_btn.pressed.connect(func() -> void:
		_show_paste_lines_popup(lines_arr, refresh_self)
	)
	col.add_child(paste_btn)

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
	img_zone.accepted_extensions   = JourneyData.IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title          = "Select Speaker Image for Line %d" % (line_idx + 1)
	img_zone.picker_filters        = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(img_zone)
	if line_data.get("image", "") != "":
		img_zone.call_deferred("set_file", line_data["image"])
	var line_rm_btn: Button = Button.new()
	line_rm_btn.text = "✕ REMOVE IMAGE"
	line_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line_rm_btn.visible = line_data.get("image", "") != ""
	UITheme.style_button(line_rm_btn, UITheme.MAGENTA)
	line_rm_btn.pressed.connect(func() -> void:
		_delete_saved_image(lines_arr[line_idx].get("image", ""))
		lines_arr[line_idx]["image"] = ""
		img_zone.call_deferred("set_file", "")
		line_rm_btn.visible = false
	)
	img_zone.file_dropped.connect(func(p: String) -> void:
		lines_arr[line_idx]["image"] = p
		line_rm_btn.visible = true
	)
	col.add_child(line_rm_btn)

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


# Thin "insert a new line here" button placed between line blocks in the
# storyboard editor.  Subtle by default, highlights on hover so it doesn't
# compete visually with the line content above/below it.
func _make_insert_line_btn(lines_arr: Array, insert_at: int, refresh: Callable) -> Control:
	var btn: Button = Button.new()
	btn.text = "╋  INSERT LINE"
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size   = Vector2(0, 24)
	btn.focus_mode            = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 10)

	var c: Color = UITheme.STORYBOARD

	var s_n: StyleBoxFlat = StyleBoxFlat.new()
	s_n.bg_color           = Color(c.r, c.g, c.b, 0.04)
	s_n.border_color       = Color(c.r, c.g, c.b, 0.22)
	s_n.border_width_left  = 1; s_n.border_width_right  = 1
	s_n.border_width_top   = 1; s_n.border_width_bottom = 1
	s_n.content_margin_top = 2; s_n.content_margin_bottom = 2
	btn.add_theme_stylebox_override("normal", s_n)

	var s_h: StyleBoxFlat = s_n.duplicate()
	s_h.bg_color     = Color(c.r, c.g, c.b, 0.15)
	s_h.border_color = c
	btn.add_theme_stylebox_override("hover", s_h)

	var s_p: StyleBoxFlat = s_n.duplicate()
	s_p.bg_color = Color(c.r, c.g, c.b, 0.28)
	btn.add_theme_stylebox_override("pressed", s_p)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	btn.add_theme_color_override("font_color",         Color(c.r, c.g, c.b, 0.45))
	btn.add_theme_color_override("font_hover_color",   c)
	btn.add_theme_color_override("font_pressed_color", c)

	btn.pressed.connect(func() -> void:
		lines_arr.insert(insert_at, {"speaker": "", "text": "", "image": ""})
		refresh.call()
	)
	return btn


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
	img_zone.accepted_extensions   = JourneyData.IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title          = "Select Card Image for Path %d" % (pi + 1)
	img_zone.picker_filters        = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub.add_child(img_zone)
	if path.get("image_path", "") != "":
		img_zone.call_deferred("set_file", path["image_path"])
	var path_rm_btn: Button = Button.new()
	path_rm_btn.text = "✕ REMOVE IMAGE"
	path_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_rm_btn.visible = path.get("image_path", "") != ""
	UITheme.style_button(path_rm_btn, UITheme.MAGENTA)
	path_rm_btn.pressed.connect(func() -> void:
		_delete_saved_image(paths_arr[pi].get("image_path", ""))
		paths_arr[pi]["image_path"] = ""
		img_zone.call_deferred("set_file", "")
		path_rm_btn.visible = false
	)
	img_zone.file_dropped.connect(func(p: String) -> void:
		paths_arr[pi]["image_path"] = p
		path_rm_btn.visible = true
	)
	sub.add_child(path_rm_btn)

	return panel


# ── Extra axes expander ──────────────────────────────────────────────────────

# Collapsed "▶ EXTRA AXES (SERIAL ONLY)" expander with one DropZone per axis.
# Serial-only: Buttplug devices ignore all secondary axes.
func _make_axis_expander(arr: Array, idx: int) -> Control:
	# Ensure the dict key exists.
	if not arr[idx].has("axis_scripts"):
		arr[idx]["axis_scripts"] = {}

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = "▶  EXTRA AXES  (SERIAL ONLY)"
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = false
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.PURPLE_MID)
	wrapper.add_child(toggle_btn)

	var axes_panel: VBoxContainer = VBoxContainer.new()
	axes_panel.add_theme_constant_override("separation", 6)
	axes_panel.visible = false
	wrapper.add_child(axes_panel)

	var hint: Label = Label.new()
	hint.text = "SECONDARY-AXIS .FUNSCRIPT FILES FOR T-CODE SR6 / OSR2+ DEVICES.  SERIAL OUTPUT ONLY — IGNORED FOR BUTTPLUG."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	axes_panel.add_child(hint)

	for info: Dictionary in EXTRA_AXES_INFO:
		var axis: String = info["axis"]
		axes_panel.add_child(_side_field_label(info["label"]))
		var zone: PanelContainer = DropZoneScript.new()
		zone.accepted_extensions   = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
		zone.picker_title          = "Select %s Funscript" % axis
		zone.picker_filters        = ["*.funscript,*.json ; Funscript Files", "*.* ; All Files"]
		zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		axes_panel.add_child(zone)
		var current_path: String = (arr[idx]["axis_scripts"] as Dictionary).get(axis, "")
		if current_path != "":
			zone.call_deferred("set_file", current_path)
		# Capture axis in closure.
		var captured_axis: String = axis
		zone.file_dropped.connect(func(p: String) -> void:
			arr[idx]["axis_scripts"][captured_axis] = p
		)

	toggle_btn.toggled.connect(func(pressed: bool) -> void:
		toggle_btn.text = ("▼  EXTRA AXES  (SERIAL ONLY)" if pressed else "▶  EXTRA AXES  (SERIAL ONLY)")
		axes_panel.visible = pressed
	)

	return wrapper


# ── Vibrator channel expander ────────────────────────────────────────────────

# Collapsed "▶ VIBRATOR SCRIPTS (BUTTPLUG ONLY)" expander with one DropZone per
# vibration channel. Accepts .vib1 / .vib2 funscripts for multi-motor devices.
# When only vib1 is provided and the device has 2+ channels, FunscriptPlayer
# mirrors it automatically — no need to fill both unless you want distinct patterns.
func _make_vib_expander(arr: Array, idx: int) -> Control:
	# Ensure the dict key exists.
	if not arr[idx].has("vib_scripts"):
		arr[idx]["vib_scripts"] = {}

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = "▶  VIBRATOR SCRIPTS  (BUTTPLUG ONLY)"
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = false
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.PURPLE_MID)
	wrapper.add_child(toggle_btn)

	var vib_panel: VBoxContainer = VBoxContainer.new()
	vib_panel.add_theme_constant_override("separation", 6)
	vib_panel.visible = false
	wrapper.add_child(vib_panel)

	var hint: Label = Label.new()
	hint.text = "PER-CHANNEL FUNSCRIPTS FOR MULTI-MOTOR VIBRATORS (E.G. WE-VIBE, LOVENSE NORA).  LEAVE EMPTY TO USE THE MAIN FUNSCRIPT FOR ALL CHANNELS."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vib_panel.add_child(hint)

	for info: Dictionary in VIB_CHANNELS_INFO:
		var ch_key: String = info["key"]
		vib_panel.add_child(_side_field_label(info["label"]))
		var zone: PanelContainer = DropZoneScript.new()
		zone.accepted_extensions   = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
		zone.picker_title          = "Select %s Funscript" % ch_key.to_upper()
		zone.picker_filters        = ["*.funscript,*.json ; Funscript Files", "*.* ; All Files"]
		zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vib_panel.add_child(zone)
		var current_path: String = (arr[idx]["vib_scripts"] as Dictionary).get(ch_key, "")
		if current_path != "":
			zone.call_deferred("set_file", current_path)
		# Capture key in closure.
		var captured_key: String = ch_key
		zone.file_dropped.connect(func(p: String) -> void:
			arr[idx]["vib_scripts"][captured_key] = p
		)

	toggle_btn.toggled.connect(func(pressed: bool) -> void:
		toggle_btn.text = ("▼  VIBRATOR SCRIPTS  (BUTTPLUG ONLY)" if pressed else "▶  VIBRATOR SCRIPTS  (BUTTPLUG ONLY)")
		vib_panel.visible = pressed
	)

	return wrapper


# ── Boss round expander ──────────────────────────────────────────────────────

# A "BOSS ROUND" toggle that, when on, marks the round as a boss and reveals its
# config: an optional intro image, an optional tagline, and a list of forced
# modifiers the player cannot remove. Toggling off reverts it to a normal round.
func _make_boss_expander(arr: Array, idx: int) -> Control:
	if not arr[idx].has("round_type"):
		arr[idx]["round_type"] = "normal"
	if not arr[idx].has("boss_modifiers"):
		arr[idx]["boss_modifiers"] = []

	var is_boss: bool = arr[idx]["round_type"] == "boss"

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 6)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = ("▼  BOSS ROUND" if is_boss else "▶  BOSS ROUND")
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = is_boss
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.MAGENTA)
	wrapper.add_child(toggle_btn)

	var boss_panel: VBoxContainer = VBoxContainer.new()
	boss_panel.add_theme_constant_override("separation", 8)
	boss_panel.visible = is_boss
	wrapper.add_child(boss_panel)

	var hint: Label = Label.new()
	hint.text = "BOSS ROUNDS DISABLE ITEM USE, APPLY FORCED MODIFIERS THE PLAYER CANNOT REMOVE, AND OPEN WITH A TELEGRAPHED INTRO CARD."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	boss_panel.add_child(hint)

	# Intro image (optional).
	boss_panel.add_child(_side_field_label("BOSS IMAGE  (OPTIONAL)"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions   = JourneyData.IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title          = "Select Boss Image"
	img_zone.picker_filters        = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	boss_panel.add_child(img_zone)
	if arr[idx].get("boss_image", "") != "":
		img_zone.call_deferred("set_file", arr[idx]["boss_image"])
	img_zone.file_dropped.connect(func(p: String) -> void:
		arr[idx]["boss_image"] = p
	)

	# Intro tagline (optional).
	boss_panel.add_child(_side_field_label("INTRO TAGLINE  (OPTIONAL)"))
	var tagline: LineEdit = LineEdit.new()
	tagline.placeholder_text = "A threat, a theme line..."
	tagline.text             = arr[idx].get("boss_tagline", "")
	UITheme.style_line_edit(tagline)
	tagline.text_changed.connect(func(val: String) -> void:
		arr[idx]["boss_tagline"] = val
	)
	boss_panel.add_child(tagline)

	# Forced modifiers list.
	boss_panel.add_child(_side_field_label("FORCED MODIFIERS"))
	var mods_list: VBoxContainer = VBoxContainer.new()
	mods_list.add_theme_constant_override("separation", 6)
	boss_panel.add_child(mods_list)
	_rebuild_boss_modifiers(arr, idx, mods_list)

	var add_btn: Button = Button.new()
	add_btn.text = "+ ADD MODIFIER"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(func() -> void:
		(arr[idx]["boss_modifiers"] as Array).append(_default_boss_modifier("scale"))
		_rebuild_boss_modifiers(arr, idx, mods_list)
	)
	boss_panel.add_child(add_btn)

	toggle_btn.toggled.connect(func(pressed: bool) -> void:
		toggle_btn.text = ("▼  BOSS ROUND" if pressed else "▶  BOSS ROUND")
		arr[idx]["round_type"] = "boss" if pressed else "normal"
		boss_panel.visible = pressed
	)

	return wrapper


# Returns a fresh modifier dict for `kind` seeded with sensible default params.
func _default_boss_modifier(kind: String) -> Dictionary:
	match kind:
		"scale":            return {"kind": "scale", "factor": 1.2}
		"clamp":            return {"kind": "clamp", "min": 0, "max": 50}
		"score_multiplier": return {"kind": "score_multiplier", "factor": 2.0}
		_:                  return {"kind": kind}


# Rebuilds the forced-modifier rows from scratch — called on add / remove / kind
# change so each row's parameter fields always match its kind.
func _rebuild_boss_modifiers(arr: Array, idx: int, list: VBoxContainer) -> void:
	for child in list.get_children():
		child.queue_free()
	var mods: Array = arr[idx].get("boss_modifiers", [])
	if mods.is_empty():
		var empty: Label = Label.new()
		empty.text = "NO MODIFIERS — THE BOSS PLAYS ITS SCRIPT AS-IS."
		empty.add_theme_color_override("font_color", UITheme.SEPARATOR)
		empty.add_theme_font_size_override("font_size", 10)
		empty.uppercase = true
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(empty)
		return
	for m_idx: int in mods.size():
		list.add_child(_make_boss_modifier_row(arr, idx, list, m_idx))


# Builds one forced-modifier row: a kind dropdown, kind-specific parameter
# fields, and a remove button.
func _make_boss_modifier_row(arr: Array, idx: int, list: VBoxContainer, m_idx: int) -> Control:
	var mod: Dictionary = arr[idx]["boss_modifiers"][m_idx]
	var kind: String = mod.get("kind", "scale")

	var panel: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color            = UITheme.CARD_BG
	s.border_color        = UITheme.PURPLE_MID
	s.border_width_left   = 1; s.border_width_right  = 1
	s.border_width_top    = 1; s.border_width_bottom = 1
	s.content_margin_left = 8; s.content_margin_right  = 8
	s.content_margin_top  = 6; s.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", s)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	# Row 1 — kind dropdown + remove button.
	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	col.add_child(head)

	var kind_dd: OptionButton = OptionButton.new()
	for label: String in BOSS_MODIFIER_LABELS:
		kind_dd.add_item(label)
	kind_dd.selected = BOSS_MODIFIER_KINDS.find(kind)
	kind_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(kind_dd)
	head.add_child(kind_dd)
	kind_dd.item_selected.connect(func(sel: int) -> void:
		arr[idx]["boss_modifiers"][m_idx] = _default_boss_modifier(BOSS_MODIFIER_KINDS[sel])
		_rebuild_boss_modifiers(arr, idx, list)
	)

	var remove_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.DANGER)
	remove_btn.pressed.connect(func() -> void:
		(arr[idx]["boss_modifiers"] as Array).remove_at(m_idx)
		_rebuild_boss_modifiers(arr, idx, list)
	)
	head.add_child(remove_btn)

	# Row 2 — kind-specific parameters.
	match kind:
		"scale", "score_multiplier":
			var prow: HBoxContainer = HBoxContainer.new()
			prow.add_theme_constant_override("separation", 6)
			var plbl: Label = _side_field_label("FACTOR")
			plbl.custom_minimum_size = Vector2(60, 0)
			prow.add_child(plbl)
			var pedit: LineEdit = LineEdit.new()
			pedit.text = str(mod.get("factor", 1.0))
			pedit.custom_minimum_size = Vector2(70, 0)
			UITheme.style_line_edit(pedit)
			pedit.text_changed.connect(func(val: String) -> void:
				arr[idx]["boss_modifiers"][m_idx]["factor"] = maxf(0.0, val.to_float())
			)
			prow.add_child(pedit)
			col.add_child(prow)
		"clamp":
			var crow: HBoxContainer = HBoxContainer.new()
			crow.add_theme_constant_override("separation", 6)
			crow.add_child(_side_field_label("MIN"))
			var min_edit: LineEdit = LineEdit.new()
			min_edit.text = str(mod.get("min", 0))
			min_edit.custom_minimum_size = Vector2(56, 0)
			UITheme.style_line_edit(min_edit)
			min_edit.text_changed.connect(func(val: String) -> void:
				arr[idx]["boss_modifiers"][m_idx]["min"] = clampi(val.to_int(), 0, 100)
			)
			crow.add_child(min_edit)
			crow.add_child(_side_field_label("MAX"))
			var max_edit: LineEdit = LineEdit.new()
			max_edit.text = str(mod.get("max", 100))
			max_edit.custom_minimum_size = Vector2(56, 0)
			UITheme.style_line_edit(max_edit)
			max_edit.text_changed.connect(func(val: String) -> void:
				arr[idx]["boss_modifiers"][m_idx]["max"] = clampi(val.to_int(), 0, 100)
			)
			crow.add_child(max_edit)
			col.add_child(crow)
		_:
			var none_lbl: Label = Label.new()
			none_lbl.text = "NO PARAMETERS"
			none_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
			none_lbl.add_theme_font_size_override("font_size", 10)
			col.add_child(none_lbl)

	return panel


# Deletes an image file only if it lives inside the app's user data directory
# (i.e. it has already been saved into a journey folder). Staging paths that
# point to the user's own filesystem are left untouched — only the reference
# in the data dict is cleared by the caller.
func _delete_saved_image(path: String) -> void:
	if path == "":
		return
	var abs_path: String = ProjectSettings.globalize_path(path)
	var user_data: String = ProjectSettings.globalize_path("user://")
	if abs_path.begins_with(user_data) and FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)
