extends Control

signal closed

const COLOR_PANEL_BG:      Color = Color(0.035, 0.005, 0.055, 0.97)
const COLOR_PURPLE_BRIGHT: Color = Color(0.698, 0.118, 1.0,   1.0)
const COLOR_PURPLE_MID:    Color = Color(0.408, 0.063, 0.627, 1.0)
const COLOR_MAGENTA:       Color = Color(0.878, 0.0,   0.878, 1.0)
const COLOR_WHITE_SOFT:    Color = Color(0.878, 0.780, 1.0,   1.0)
const COLOR_DARK_TEXT:     Color = Color(0.55,  0.47,  0.72,  1.0)
const COLOR_AMBER:         Color = Color(1.0,   0.65,  0.15,  1.0)
const COLOR_TOXIC_GREEN:   Color = Color(0.45,  1.0,   0.35,  1.0)
const COLOR_CARD_BG:       Color = Color(0.02,  0.0,   0.04,  1.0)

const PANEL_WIDTH: int   = 300
const SLIDE_TIME:  float = 0.18

@onready var _backdrop:    ColorRect      = $Backdrop
@onready var _panel:       PanelContainer = $Panel
@onready var _vbox:        VBoxContainer  = $Panel/VBox
@onready var _header:      HBoxContainer  = $Panel/VBox/HeaderRow
@onready var _title:       Label          = $Panel/VBox/HeaderRow/Title
@onready var _close_btn:   Button         = $Panel/VBox/HeaderRow/CloseButton
@onready var _subtitle:    Label          = $Panel/VBox/Subtitle
@onready var _empty_lbl:   Label          = $Panel/VBox/EmptyLabel
@onready var _scroll:      ScrollContainer = $Panel/VBox/Scroll
@onready var _item_list:   VBoxContainer  = $Panel/VBox/Scroll/ItemList


func _ready() -> void:
	# The backdrop and root cover the full viewport for slide animation only —
	# they must not block clicks to the game beneath.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.color = Color(0, 0, 0, 0)
	_apply_layout()
	_apply_theme()
	_close_btn.pressed.connect(close)
	InventoryService.InventoryChanged.connect(_refresh)
	_refresh()
	_slide_in()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func close() -> void:
	emit_signal("closed")
	var tween: Tween = create_tween()
	tween.tween_property(_panel, "position:x", get_viewport_rect().size.x, SLIDE_TIME)
	tween.tween_callback(queue_free)


func _slide_in() -> void:
	var w: float = get_viewport_rect().size.x
	_panel.position.x = w
	var tween: Tween = create_tween()
	tween.tween_property(_panel, "position:x", w - PANEL_WIDTH, SLIDE_TIME)


# --------------------------------------------------------------------------
# Item list
# --------------------------------------------------------------------------

func _refresh() -> void:
	for child in _item_list.get_children():
		child.queue_free()

	var items: Array = InventoryService.GetItems()
	_empty_lbl.visible = items.is_empty()
	_scroll.visible    = not items.is_empty()

	for i in items.size():
		var data: Dictionary = items[i]
		_item_list.add_child(_make_item_row(i, data))


func _make_item_row(slot_idx: int, data: Dictionary) -> Control:
	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", _row_stylebox())
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.gui_input.connect(_on_card_input.bind(slot_idx))

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   14)
	margin.add_theme_constant_override("margin_right",  14)
	margin.add_theme_constant_override("margin_top",    10)
	margin.add_theme_constant_override("margin_bottom", 10)
	card.add_child(margin)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	margin.add_child(col)

	var top_row: HBoxContainer = HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	col.add_child(top_row)

	var name_lbl: Label = Label.new()
	name_lbl.text = (data.get("name", "?") as String).to_upper()
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_color_override("font_color", COLOR_WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", 14)
	top_row.add_child(name_lbl)

	var dur_lbl: Label = Label.new()
	var dur_ms: int = data.get("duration_ms", 0)
	dur_lbl.text = "%ds" % int(dur_ms / 1000.0)
	dur_lbl.add_theme_color_override("font_color", COLOR_TOXIC_GREEN)
	dur_lbl.add_theme_font_size_override("font_size", 11)
	top_row.add_child(dur_lbl)

	var desc_lbl: Label = Label.new()
	desc_lbl.text = data.get("description", "")
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.add_theme_color_override("font_color", COLOR_DARK_TEXT)
	desc_lbl.add_theme_font_size_override("font_size", 11)
	col.add_child(desc_lbl)

	var use_lbl: Label = Label.new()
	use_lbl.text = "> CLICK TO ACTIVATE"
	use_lbl.add_theme_color_override("font_color", COLOR_AMBER)
	use_lbl.add_theme_font_size_override("font_size", 10)
	col.add_child(use_lbl)

	# Let click events fall through every descendant to the card's gui_input.
	_set_mouse_filter_recursive(margin, Control.MOUSE_FILTER_IGNORE)
	return card


func _set_mouse_filter_recursive(node: Node, filter: int) -> void:
	if node is Control:
		(node as Control).mouse_filter = filter
	for child in node.get_children():
		_set_mouse_filter_recursive(child, filter)


func _on_card_input(event: InputEvent, slot_idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			InventoryService.ActivateItem(slot_idx)


# --------------------------------------------------------------------------
# Layout / theme
# --------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_backdrop.anchor_right  = 1.0
	_backdrop.anchor_bottom = 1.0

	# Panel: anchored to the right edge, full height.
	_panel.anchor_left   = 1.0
	_panel.anchor_top    = 0.0
	_panel.anchor_right  = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left   = -PANEL_WIDTH
	_panel.offset_right  = 0
	_panel.offset_top    = 0
	_panel.offset_bottom = 0
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)

	_vbox.add_theme_constant_override("separation", 12)
	_header.add_theme_constant_override("separation", 8)
	_item_list.add_theme_constant_override("separation", 10)


func _apply_theme() -> void:
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = COLOR_PANEL_BG
	panel_style.border_color        = COLOR_PURPLE_BRIGHT
	panel_style.border_width_left   = 3
	panel_style.content_margin_left   = 18
	panel_style.content_margin_right  = 18
	panel_style.content_margin_top    = 18
	panel_style.content_margin_bottom = 18
	_panel.add_theme_stylebox_override("panel", panel_style)

	_title.add_theme_color_override("font_color", COLOR_PURPLE_BRIGHT)
	_title.add_theme_font_size_override("font_size", 20)
	_title.uppercase = true

	_subtitle.add_theme_color_override("font_color", COLOR_DARK_TEXT)
	_subtitle.add_theme_font_size_override("font_size", 11)
	_subtitle.uppercase = true

	_empty_lbl.add_theme_color_override("font_color", COLOR_DARK_TEXT)
	_empty_lbl.add_theme_font_size_override("font_size", 13)
	_empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_style_close_button(_close_btn)


func _row_stylebox() -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = COLOR_CARD_BG
	s.border_color        = COLOR_PURPLE_MID
	s.border_width_left   = 2
	s.border_width_right  = 1
	s.border_width_top    = 1
	s.border_width_bottom = 1
	return s


func _style_close_button(btn: Button) -> void:
	btn.add_theme_color_override("font_color",       COLOR_MAGENTA)
	btn.add_theme_color_override("font_hover_color", COLOR_WHITE_SOFT)
	btn.add_theme_font_size_override("font_size", 16)
	btn.focus_mode = Control.FOCUS_NONE

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	s.border_color        = COLOR_MAGENTA
	s.border_width_left   = 1
	s.border_width_right  = 1
	s.border_width_top    = 1
	s.border_width_bottom = 1
	s.content_margin_left   = 10
	s.content_margin_right  = 10
	s.content_margin_top    = 4
	s.content_margin_bottom = 4
	btn.add_theme_stylebox_override("normal", s)

	var s_hover: StyleBoxFlat = s.duplicate()
	s_hover.bg_color = Color(COLOR_MAGENTA.r, COLOR_MAGENTA.g, COLOR_MAGENTA.b, 0.25)
	btn.add_theme_stylebox_override("hover", s_hover)

	var s_pressed: StyleBoxFlat = s.duplicate()
	s_pressed.bg_color = COLOR_MAGENTA
	btn.add_theme_stylebox_override("pressed", s_pressed)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
