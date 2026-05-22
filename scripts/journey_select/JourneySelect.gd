extends Control

# ---------------------------------------------------------------------------
# JourneySelect.gd
# Purple matrix theme. Scrollable catalogue grid of journey cards. Clicking
# a card opens a detail modal with stats parsed from journey.json and
# funscript files found in user://journeys/<folder>/<round-name>/.
# ---------------------------------------------------------------------------

const TOP_BAR_HEIGHT:   int = 64
const GRID_TOP_MARGIN:  int = 16
const GRID_PADDING:     int = 40
const GRID_SEPARATION:  int = 24
const CARD_MIN_WIDTH:   int = 280
# Inset around the card grid so hover-scaled cards on the outer edge have room
# to expand without being clipped by the scroll viewport.
const HOVER_MARGIN:     int = 12
const MODAL_MIN_WIDTH:  int = 980
const MODAL_MIN_HEIGHT: int = 600
const MODAL_COVER_W:    int = 280
const BORDER_WIDTH:     int = 3

const JOURNEYS_DIR: String = "user://journeys"

# Difficulty list is owned by JourneyData (canonical schema) — JourneyData.DIFFICULTIES.

const DIFF_COLORS: Dictionary = {
	"Easy":      Color(0.35, 0.95, 0.35),
	"Medium":    Color(0.95, 0.95, 0.25),
	"Hard":      Color(1.0,  0.55, 0.1),
	"Very Hard": Color(1.0,  0.25, 0.05),
	"Extreme":   Color(1.0,  0.1,  0.1),
	"Insane":    Color(0.9,  0.05, 0.5),
}

const JourneyCardScene = preload("res://scenes/journey_select/JourneyCard.tscn")

@onready var _bg:           ColorRect       = $Background
@onready var _top_bar:      HBoxContainer   = $TopBar
@onready var _back_btn:     Button          = $TopBar/BackButton
@onready var _title_lbl:    Label           = $TopBar/TitleLabel
@onready var _sort_lbl:      Label           = $TopBar/SortContainer/SortLabel
@onready var _sort_name:     Button          = $TopBar/SortContainer/SortNameBtn
@onready var _sort_duration: Button          = $TopBar/SortContainer/SortDurationBtn
@onready var _sort_actions:  Button          = $TopBar/SortContainer/SortActionsBtn
@onready var _scroll:       ScrollContainer = $ScrollContainer
@onready var _grid:         GridContainer   = $ScrollContainer/Grid
@onready var _empty_lbl:    Label           = $EmptyLabel
@onready var _modal:        Control         = $DetailModal
@onready var _backdrop:     ColorRect       = $DetailModal/Backdrop
@onready var _modal_panel:  PanelContainer  = $DetailModal/ModalPanel
@onready var _modal_layout: HBoxContainer   = $DetailModal/ModalPanel/ModalLayout
@onready var _cover_img:    TextureRect     = $DetailModal/ModalPanel/ModalLayout/CoverImage
@onready var _details_col:  VBoxContainer   = $DetailModal/ModalPanel/ModalLayout/DetailsColumn
@onready var _modal_title:  Label           = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalTitle
@onready var _modal_author: Label           = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalAuthor
@onready var _modal_diff:   Label           = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalDifficulty
@onready var _modal_desc:   Label           = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalDescription
@onready var _stat_rounds:  Label           = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsRow/StatRounds
@onready var _stat_actions: Label           = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsRow/StatActions
@onready var _stat_length:  Label           = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsRow/StatLength
@onready var _rounds_hdr:   Label           = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundsHeader
@onready var _round_scroll: ScrollContainer = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundListScroll
@onready var _round_list:   VBoxContainer   = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundListScroll/RoundList
@onready var _play_btn:     Button          = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionRow/PlayButton
@onready var _edit_btn:     Button          = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionRow/EditButton
@onready var _delete_btn:   Button          = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionRow/DeleteButton

var _journeys:        Array      = []
var _sort_field:      String     = "name"
var _sort_asc:        bool       = true
var _current_journey: Dictionary = {}

# Search / filter state
var _search_text:    String = ""
var _diff_filter_idx: int   = 0  # 0 = all, 1+ = DIFFICULTIES[idx-1]
var _tag_filter_idx:  int   = 0  # 0 = all, 1+ = TagRegistry.all()[idx-1]

# Dynamically-created filter widgets (added to _top_bar in _apply_layout)
var _search_field: LineEdit    = null
var _diff_filter:  OptionButton = null
var _tag_filter:   OptionButton = null
var _count_label:  Label        = null


func _ready() -> void:
	MusicService.play()
	_apply_layout()
	_apply_theme()
	_connect_signals()
	_scan_journeys()
	_sort_and_populate()
	_modal.visible = false

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right  = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = 0
	_bg.offset_top = 0
	_bg.offset_right = 0
	_bg.offset_bottom = 0
	
	var animated_bg: Control = $AnimatedBackground
	animated_bg.anchor_right  = 1.0
	animated_bg.anchor_bottom = 1.0

	_top_bar.anchor_right  = 1.0
	_top_bar.anchor_bottom = 0.0
	_top_bar.offset_left   = 16
	_top_bar.offset_right  = -16
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_top_bar.add_theme_constant_override("separation", 10)

	# Header background strip — a dark, slightly translucent panel with an accent
	# underline that grounds the bar and separates it from the grid below.
	var bar_bg: Panel = Panel.new()
	var bar_style: StyleBoxFlat = StyleBoxFlat.new()
	bar_style.bg_color            = UITheme.BAR_BG
	bar_style.border_width_bottom = 2
	bar_style.border_color        = UITheme.PURPLE_MID
	bar_bg.add_theme_stylebox_override("panel", bar_style)
	bar_bg.anchor_right  = 1.0
	bar_bg.anchor_bottom = 0.0
	bar_bg.offset_bottom = TOP_BAR_HEIGHT
	bar_bg.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	add_child(bar_bg)
	# Place just before the TopBar so it renders behind the controls.
	move_child(bar_bg, _top_bar.get_index())

	# Journey count — sits right after the title; reflects the active filter.
	_count_label = Label.new()
	_count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_top_bar.add_child(_count_label)
	_top_bar.move_child(_count_label, 2)

	# Search field — expands to fill space between the title and sort controls.
	# We create it here so it's available for _apply_theme(); move_child positions
	# it after BackButton(0) + TitleLabel(1) + CountLabel(2).
	_search_field = LineEdit.new()
	_search_field.placeholder_text      = "Search journeys…"
	_search_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_field.custom_minimum_size   = Vector2(180, 0)
	_top_bar.add_child(_search_field)
	_top_bar.move_child(_search_field, 3)

	# Difficulty filter dropdown
	_diff_filter = OptionButton.new()
	_diff_filter.custom_minimum_size = Vector2(172, 0)
	_diff_filter.add_item("ALL DIFFICULTIES")
	for d: String in JourneyData.DIFFICULTIES:
		_diff_filter.add_item(d.to_upper())
	_top_bar.add_child(_diff_filter)
	_top_bar.move_child(_diff_filter, 4)

	# Tag filter dropdown
	_tag_filter = OptionButton.new()
	_tag_filter.custom_minimum_size = Vector2(150, 0)
	_tag_filter.add_item("ALL TAGS")
	for tag_def: Dictionary in TagRegistry.all():
		_tag_filter.add_item((tag_def["label"] as String).to_upper())
	_top_bar.add_child(_tag_filter)
	_top_bar.move_child(_tag_filter, 5)

	_scroll.anchor_right  = 1.0
	_scroll.anchor_bottom = 1.0
	_scroll.offset_top    = TOP_BAR_HEIGHT + GRID_TOP_MARGIN
	_scroll.offset_left   = GRID_PADDING
	_scroll.offset_right  = -GRID_PADDING
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_grid.add_theme_constant_override("h_separation", GRID_SEPARATION)
	_grid.add_theme_constant_override("v_separation", GRID_SEPARATION)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Wrap the grid in a MarginContainer so hover-scaled cards along the grid's
	# outer edge expand into this inset instead of being clipped by the scroll.
	var grid_mc: MarginContainer = MarginContainer.new()
	grid_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_mc.add_theme_constant_override("margin_left",   HOVER_MARGIN)
	grid_mc.add_theme_constant_override("margin_right",  HOVER_MARGIN)
	grid_mc.add_theme_constant_override("margin_top",    HOVER_MARGIN)
	grid_mc.add_theme_constant_override("margin_bottom", HOVER_MARGIN)
	_scroll.remove_child(_grid)
	grid_mc.add_child(_grid)
	_scroll.add_child(grid_mc)

	_empty_lbl.anchor_right  = 1.0
	_empty_lbl.anchor_bottom = 1.0
	_empty_lbl.offset_top    = TOP_BAR_HEIGHT + GRID_TOP_MARGIN

	_scroll.resized.connect(_update_grid_columns)
	get_viewport().size_changed.connect(_update_grid_columns)
	_update_grid_columns.call_deferred()

	_modal.anchor_right  = 1.0
	_modal.anchor_bottom = 1.0

	_backdrop.anchor_right  = 1.0
	_backdrop.anchor_bottom = 1.0

	_modal_panel.anchor_left   = 0.5
	_modal_panel.anchor_right  = 0.5
	_modal_panel.anchor_top    = 0.5
	_modal_panel.anchor_bottom = 0.5
	_modal_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_modal_panel.grow_vertical   = Control.GROW_DIRECTION_BOTH
	_modal_panel.custom_minimum_size = Vector2(MODAL_MIN_WIDTH, MODAL_MIN_HEIGHT)

	_modal_layout.add_theme_constant_override("separation", 20)

	_cover_img.custom_minimum_size  = Vector2(MODAL_COVER_W, 0)
	_cover_img.size_flags_vertical  = Control.SIZE_EXPAND_FILL

	_details_col.add_theme_constant_override("separation", 10)
	_details_col.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_round_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_round_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Wrap the round list in a MarginContainer so the rightmost column (coins)
	# always has breathing room and is never crowded by the vertical scrollbar.
	var round_list_mc: MarginContainer = MarginContainer.new()
	round_list_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	round_list_mc.add_theme_constant_override("margin_right", 12)
	_round_scroll.remove_child(_round_list)
	round_list_mc.add_child(_round_list)
	_round_scroll.add_child(round_list_mc)


func _update_grid_columns() -> void:
	# Subtract the margin inset on both sides — the grid no longer spans the
	# full scroll width now that it lives inside a MarginContainer.
	var available: float = _scroll.size.x - 2.0 * HOVER_MARGIN
	if available <= 0:
		return
	var cols: int = max(1, int((available + GRID_SEPARATION) / (CARD_MIN_WIDTH + GRID_SEPARATION)))
	_grid.columns = cols


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = UITheme.BG

	# TopBar background via a Panel behind the HBoxContainer would need an extra
	# node; instead we apply a dark strip by styling the scroll container top offset.
	_style_label(_title_lbl,  UITheme.PURPLE_BRIGHT, 18, true)
	# Title no longer expands — the search field takes the flexible slot instead.
	_title_lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_title_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_LEFT

	_style_label(_sort_lbl,   UITheme.PURPLE_MID,    13, true)
	_style_label(_empty_lbl,  UITheme.PURPLE_MID,    15, true)
	_empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_empty_lbl.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART

	_style_button(_back_btn,      UITheme.MAGENTA)
	_style_button(_sort_name,     UITheme.PURPLE_BRIGHT)
	_style_button(_sort_duration, UITheme.PURPLE_MID)
	_style_button(_sort_actions,  UITheme.PURPLE_MID)
	_style_button(_play_btn,      UITheme.PURPLE_BRIGHT)
	_style_button(_edit_btn,      UITheme.PURPLE_MID)
	_style_button(_delete_btn,    UITheme.DANGER)

	UITheme.style_line_edit(_search_field)
	UITheme.style_option_button(_diff_filter)
	UITheme.style_option_button(_tag_filter)
	_style_label(_count_label, UITheme.PURPLE_MID, 12, true)

	_style_modal_panel()

	_style_label(_modal_title,  UITheme.PURPLE_BRIGHT, 22, true)
	_style_label(_modal_author, UITheme.PURPLE_MID,    13, false)
	_style_label(_modal_diff,   UITheme.MAGENTA,       15, true)
	_style_label(_modal_desc,   UITheme.WHITE_SOFT,    12, false)
	_modal_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_style_label(_stat_rounds,  UITheme.WHITE_SOFT, 13, true)
	_style_label(_stat_actions, UITheme.WHITE_SOFT, 13, true)
	_style_label(_stat_length,  UITheme.WHITE_SOFT, 13, true)

	_style_label(_rounds_hdr, UITheme.SEPARATOR, 11, true)

	var sep_style: StyleBoxFlat = StyleBoxFlat.new()
	sep_style.bg_color = UITheme.SEPARATOR
	for sep_path in [
		"DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsDivider",
		"DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundsDivider",
		"DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionDivider",
	]:
		var sep: HSeparator = get_node_or_null(sep_path)
		if sep:
			sep.add_theme_stylebox_override("separator", sep_style)

	_backdrop.color = Color(0.0, 0.0, 0.0, 0.85)


func _style_modal_panel() -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.PANEL_BG
	s.border_color        = UITheme.PURPLE_BRIGHT
	s.border_width_left   = BORDER_WIDTH
	s.border_width_right  = BORDER_WIDTH
	s.border_width_top    = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left     = 4
	s.corner_radius_top_right    = 4
	s.corner_radius_bottom_left  = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.5)
	s.shadow_size  = 16
	s.content_margin_left   = 20
	s.content_margin_right  = 28
	s.content_margin_top    = 28
	s.content_margin_bottom = 28
	_modal_panel.add_theme_stylebox_override("panel", s)


func _style_label(label: Label, color: Color, size: int, uppercase: bool = false) -> void:
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	label.uppercase = uppercase


func _style_button(btn: Button, accent: Color) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   UITheme.WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", UITheme.BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.text = btn.text.to_upper()
	btn.add_theme_stylebox_override("normal",  _make_btn_style(accent, UITheme.PURPLE_DARK))
	btn.add_theme_stylebox_override("hover",   _make_btn_style(accent, UITheme.PURPLE_MID))
	btn.add_theme_stylebox_override("pressed", _make_btn_style(accent, accent))
	btn.add_theme_stylebox_override("focus",   StyleBoxEmpty.new())


func _make_btn_style(border: Color, fill: Color) -> StyleBoxFlat:
	var s: StyleBoxFlat   = StyleBoxFlat.new()
	s.bg_color            = fill
	s.border_color        = border
	s.border_width_left   = 2
	s.border_width_right  = 2
	s.border_width_top    = 2
	s.border_width_bottom = 2
	s.content_margin_left   = 18
	s.content_margin_right  = 18
	s.content_margin_top    = 12
	s.content_margin_bottom = 12
	return s


func _set_active_sort() -> void:
	var arrow: String = " ▲" if _sort_asc else " ▼"
	_style_button(_sort_name,     UITheme.PURPLE_BRIGHT if _sort_field == "name"     else UITheme.PURPLE_MID)
	_style_button(_sort_duration, UITheme.PURPLE_BRIGHT if _sort_field == "duration" else UITheme.PURPLE_MID)
	_style_button(_sort_actions,  UITheme.PURPLE_BRIGHT if _sort_field == "actions"  else UITheme.PURPLE_MID)
	_sort_name.text     = ("NAME"     + arrow) if _sort_field == "name"     else "NAME"
	_sort_duration.text = ("DURATION" + arrow) if _sort_field == "duration" else "DURATION"
	_sort_actions.text  = ("ACTIONS"  + arrow) if _sort_field == "actions"  else "ACTIONS"


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _modal.visible:
		_close_modal()
		get_viewport().set_input_as_handled()


func _connect_signals() -> void:
	_back_btn.pressed.connect(_on_back_pressed)
	_sort_name.pressed.connect(_on_sort_pressed.bind("name"))
	_sort_duration.pressed.connect(_on_sort_pressed.bind("duration"))
	_sort_actions.pressed.connect(_on_sort_pressed.bind("actions"))
	_backdrop.gui_input.connect(_on_backdrop_input)
	_play_btn.pressed.connect(_on_play_pressed)
	_edit_btn.pressed.connect(_on_edit_pressed)
	_delete_btn.pressed.connect(_on_delete_pressed)
	_search_field.text_changed.connect(func(text: String) -> void:
		_search_text = text.strip_edges()
		_sort_and_populate()
	)
	_diff_filter.item_selected.connect(func(idx: int) -> void:
		_diff_filter_idx = idx
		_sort_and_populate()
	)
	_tag_filter.item_selected.connect(func(idx: int) -> void:
		_tag_filter_idx = idx
		_sort_and_populate()
	)


func _on_sort_pressed(field: String) -> void:
	if _sort_field == field:
		_sort_asc = not _sort_asc
	else:
		_sort_field = field
		_sort_asc   = true
	_sort_and_populate()


func _on_back_pressed() -> void:
	Transition.change_scene("res://scenes/main/Main.tscn")


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_close_modal()


func _on_play_pressed() -> void:
	if _current_journey.is_empty():
		return
	GameState.StartJourney(_current_journey)
	Transition.change_scene("res://scenes/game_loop/GameLoop.tscn")


func _on_edit_pressed() -> void:
	if _current_journey.is_empty():
		return
	JourneyBuilder.edit_journey = _current_journey
	Transition.change_scene("res://scenes/journey_builder/JourneyBuilder.tscn")


func _on_delete_pressed() -> void:
	if _current_journey.is_empty():
		return
	var title: String = _current_journey.get("title", "this journey")
	var dialog: ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Delete Journey"
	dialog.dialog_text = "Permanently delete \"%s\"?\n\nAll videos, funscripts, and cover images in the journey folder will be removed. This cannot be undone." % title
	dialog.ok_button_text = "DELETE"
	dialog.get_ok_button().add_theme_color_override("font_color", UITheme.DANGER)
	dialog.confirmed.connect(func() -> void:
		_confirm_delete()
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


func _confirm_delete() -> void:
	var folder: String = _current_journey.get("folder", "")
	if folder != "":
		JourneyData.delete_dir_recursive(folder)
	_journeys.erase(_current_journey)
	_current_journey = {}
	_close_modal()
	_sort_and_populate()


# ---------------------------------------------------------------------------
# Journey scanning
# ---------------------------------------------------------------------------

# Scanning + journey.json parsing lives in JourneyScanner (RefCounted helper).
func _scan_journeys() -> void:
	_journeys = JourneyScanner.scan_all(JOURNEYS_DIR)


# ---------------------------------------------------------------------------
# Grid population
# ---------------------------------------------------------------------------

func _sort_and_populate() -> void:
	_set_active_sort()
	# Apply search + difficulty filter first, then sort the surviving subset.
	var filtered: Array = _journeys.filter(func(j: Dictionary) -> bool:
		return _passes_filter(j)
	)
	var asc: bool = _sort_asc
	match _sort_field:
		"name":
			filtered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var cmp: int = (a["title"] as String).naturalnocasecmp_to(b["title"] as String)
				return cmp < 0 if asc else cmp > 0
			)
		"duration":
			filtered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var va: int = a["total_length_ms"]
				var vb: int = b["total_length_ms"]
				return va < vb if asc else va > vb
			)
		"actions":
			filtered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var va: int = a["total_actions"]
				var vb: int = b["total_actions"]
				return va < vb if asc else va > vb
			)
	_populate_grid(filtered)


# Returns true when journey `j` matches the current search text, difficulty
# filter, and tag filter.
func _passes_filter(j: Dictionary) -> bool:
	if _search_text != "":
		var title: String = (j.get("title", "") as String).to_lower()
		if not title.contains(_search_text.to_lower()):
			return false
	if _diff_filter_idx > 0:
		var required: String = JourneyData.DIFFICULTIES[_diff_filter_idx - 1]
		if j.get("difficulty", "") != required:
			return false
	if _tag_filter_idx > 0:
		var tags_all: Array = TagRegistry.all()
		if _tag_filter_idx - 1 < tags_all.size():
			var required_tag: String = tags_all[_tag_filter_idx - 1]["id"]
			if required_tag not in (j.get("tags", []) as Array):
				return false
	return true


func _populate_grid(journeys: Array) -> void:
	for child in _grid.get_children():
		child.queue_free()
	if journeys.is_empty():
		_empty_lbl.text = "No journeys match your filter." if not _journeys.is_empty() \
			else "No journeys yet.\nCreate one in the builder!"
	_empty_lbl.visible = journeys.is_empty()

	# Header count — total catalogue size, or "shown OF total" while filtering.
	if _count_label != null:
		var total: int = _journeys.size()
		var shown: int = journeys.size()
		_count_label.text = ("%d JOURNEY%s" % [total, "" if total == 1 else "S"]) if shown == total \
			else "%d OF %d" % [shown, total]

	var idx: int = 0
	for journey: Dictionary in journeys:
		var card: PanelContainer = JourneyCardScene.instantiate()
		_grid.add_child(card)
		card.setup(journey)
		card.selected.connect(_on_journey_selected.bind(journey))
		# Staggered fade/scale-in so the catalogue builds in. The per-card delay
		# is capped so a large catalogue still finishes quickly.
		card.animate_in(min(idx, 16) * 0.022)
		idx += 1


func _on_journey_selected(journey: Dictionary) -> void:
	_current_journey = journey
	_populate_modal(journey)
	_open_modal()


# Fades the backdrop in and scales the panel up from 95% with a slight overshoot.
func _open_modal() -> void:
	_modal.visible          = true
	_backdrop.modulate.a    = 0.0
	_modal_panel.modulate.a = 0.0
	# Wait one frame so the panel has its final size before computing the pivot.
	await get_tree().process_frame
	_modal_panel.pivot_offset = _modal_panel.size / 2.0
	_modal_panel.scale        = Vector2(0.95, 0.95)
	var t: Tween = create_tween().set_parallel(true)
	t.tween_property(_backdrop,    "modulate:a", 1.0, 0.16)
	t.tween_property(_modal_panel, "modulate:a", 1.0, 0.16)
	t.tween_property(_modal_panel, "scale", Vector2.ONE, 0.18) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)


# Fades + shrinks the modal out, then hides it and resets the transform.
func _close_modal() -> void:
	if not _modal.visible:
		return
	var t: Tween = create_tween().set_parallel(true)
	t.tween_property(_backdrop,    "modulate:a", 0.0, 0.12)
	t.tween_property(_modal_panel, "modulate:a", 0.0, 0.12)
	t.tween_property(_modal_panel, "scale", Vector2(0.96, 0.96), 0.12)
	await t.finished
	_modal.visible            = false
	_modal_panel.scale        = Vector2.ONE
	_modal_panel.modulate.a   = 1.0
	_backdrop.modulate.a      = 1.0


# ---------------------------------------------------------------------------
# Detail modal
# ---------------------------------------------------------------------------

func _populate_modal(journey: Dictionary) -> void:
	_modal_title.text  = journey.get("title", "Unknown")
	_modal_author.text = "by " + (journey.get("author", "Unknown") as String)

	var diff: String = journey.get("difficulty", "Unknown")
	_modal_diff.text = "◆  " + diff.to_upper()
	var diff_color: Color = DIFF_COLORS.get(diff, UITheme.WHITE_SOFT)
	_modal_diff.add_theme_color_override("font_color", diff_color)

	# Tag chips — rebuilt each time the modal opens (named so the prior row,
	# if any, can be removed first).
	var old_tag_row: Node = _details_col.get_node_or_null("ModalTagRow")
	if old_tag_row:
		old_tag_row.free()
	var tag_ids: Array = journey.get("tags", [])
	if not tag_ids.is_empty():
		var tag_row: HFlowContainer = HFlowContainer.new()
		tag_row.name = "ModalTagRow"
		tag_row.add_theme_constant_override("h_separation", 6)
		tag_row.add_theme_constant_override("v_separation", 6)
		for id: String in tag_ids:
			tag_row.add_child(UITheme.make_tag_chip(TagRegistry.label_of(id), TagRegistry.color_of(id)))
		_details_col.add_child(tag_row)
		_details_col.move_child(tag_row, _modal_diff.get_index() + 1)

	var rounds: Array = journey.get("rounds", [])
	var total_rounds: int = journey.get("total_rounds", rounds.size())
	_stat_rounds.text  = str(total_rounds) + " ROUNDS"
	_stat_actions.text = str(journey.get("total_actions", 0)) + " ACTIONS"
	var total_secs: int = (journey.get("total_length_ms", 0) as int) / 1000
	_stat_length.text  = _format_duration(total_secs)

	var desc: String = journey.get("description", "")
	_modal_desc.text    = desc
	_modal_desc.visible = desc != ""

	var cover_path: String = journey.get("cover_path", "")
	var cover_img: Image = JourneyData.load_image_smart(cover_path)
	_cover_img.texture = ImageTexture.create_from_image(cover_img) if cover_img else null

	for child in _round_list.get_children():
		child.queue_free()

	var shops_data: Array = journey.get("shops", [])

	# Column headers
	var hdr: HBoxContainer = HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 12)
	_round_list.add_child(hdr)
	for col in [["", 36, false], ["ROUND", -1, false], ["DURATION", 56, true], ["ACTIONS", 72, true], ["COINS", 72, true]]:
		var lbl: Label = Label.new()
		lbl.text = col[0]
		if col[1] == -1:
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			lbl.custom_minimum_size = Vector2(col[1], 0)
		if col[2]:
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.uppercase = true
		hdr.add_child(lbl)
	var hdr_line: HSeparator = HSeparator.new()
	var hdr_style: StyleBoxFlat = StyleBoxFlat.new()
	hdr_style.bg_color = Color(UITheme.SEPARATOR.r, UITheme.SEPARATOR.g, UITheme.SEPARATOR.b, 0.3)
	hdr_line.add_theme_stylebox_override("separator", hdr_style)
	_round_list.add_child(hdr_line)

	var forks_data:       Array = journey.get("forks",       [])
	var storyboards_data: Array = journey.get("storyboards", [])

	_add_seq_to_list(
		_round_list,
		rounds,
		shops_data,
		storyboards_data,
		forks_data,
		0
	)


# ---------------------------------------------------------------------------
# Recursive sequence renderer
# ---------------------------------------------------------------------------

# Builds and inserts interleaved rows for rounds/shops/storyboards/forks into
# `list`. `indent` is the nesting depth (0 = top level); each level adds
# INDENT_PX pixels of left margin via a MarginContainer wrapper.
const INDENT_PX: int = 16

func _add_seq_to_list(
	list:         VBoxContainer,
	rounds:       Array,
	shops:        Array,
	storyboards:  Array,
	forks:        Array,
	indent:       int
) -> void:
	var seq: Array = []
	for rd: Dictionary in rounds:
		seq.append({"type": "round",      "data": rd, "key": (rd.get("order",       0) as int) * 3})
	for sb: Dictionary in storyboards:
		seq.append({"type": "storyboard", "data": sb, "key": (sb.get("order",       0) as int) * 3})
	for sh: Dictionary in shops:
		seq.append({"type": "shop",       "data": sh, "key": (sh.get("after_order", 0) as int) * 3 + 1})
	for fk: Dictionary in forks:
		seq.append({"type": "fork",       "data": fk, "key": (fk.get("after_order", 0) as int) * 3 + 2})
	seq.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a["key"] as int) < (b["key"] as int))

	for item: Dictionary in seq:
		match item["type"]:
			"fork":
				_add_fork_to_list(list, item["data"], indent)
			"shop":
				var shop: Dictionary = item["data"]
				var shop_row: HBoxContainer = HBoxContainer.new()
				shop_row.add_theme_constant_override("separation", 8)
				var shop_lbl: Label = Label.new()
				var shop_title: String = shop.get("title", "")
				if shop_title != "":
					shop_lbl.text = "  ◆  SHOP: %s" % shop_title.to_upper()
				else:
					shop_lbl.text = "  ◆  SHOP"
				shop_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				shop_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
				shop_lbl.add_theme_font_size_override("font_size", 11)
				shop_row.add_child(shop_lbl)
				list.add_child(_indent_wrap(shop_row, indent))
			"storyboard":
				var sb: Dictionary = item["data"]
				var sb_row: HBoxContainer = HBoxContainer.new()
				sb_row.add_theme_constant_override("separation", 8)
				var sb_lbl: Label = Label.new()
				var sb_line_count: int = (sb.get("lines", []) as Array).size()
				sb_lbl.text = "  ◈  STORYBOARD  (%d LINE%s)" % [sb_line_count, "S" if sb_line_count != 1 else ""]
				sb_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				sb_lbl.add_theme_color_override("font_color", Color(0.10, 0.85, 0.90, 1.0))
				sb_lbl.add_theme_font_size_override("font_size", 11)
				sb_row.add_child(sb_lbl)
				var sb_coins: int = sb.get("coins", 0)
				if sb_coins > 0:
					var sb_coins_lbl: Label = Label.new()
					sb_coins_lbl.text = "♦ %d" % sb_coins
					sb_coins_lbl.custom_minimum_size = Vector2(72, 0)
					sb_coins_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
					sb_coins_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
					sb_coins_lbl.add_theme_font_size_override("font_size", 12)
					sb_row.add_child(sb_coins_lbl)
				list.add_child(_indent_wrap(sb_row, indent))
			"round":
				var round_data: Dictionary = item["data"]
				var order: int = round_data.get("order", 0)
				var is_boss: bool = round_data.get("round_type", "normal") == "boss"
				var row: HBoxContainer = HBoxContainer.new()
				row.add_theme_constant_override("separation", 12)
				var order_lbl: Label = Label.new()
				order_lbl.text = "%02d." % order
				order_lbl.custom_minimum_size = Vector2(36, 0)
				order_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
				order_lbl.add_theme_font_size_override("font_size", 12)
				row.add_child(order_lbl)
				var name_lbl: Label = Label.new()
				var round_name_text: String = (round_data.get("name", "") as String).to_upper()
				name_lbl.text = ("⚔  " + round_name_text) if is_boss else round_name_text
				name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				name_lbl.add_theme_color_override("font_color", UITheme.DANGER if is_boss else UITheme.WHITE_SOFT)
				name_lbl.add_theme_font_size_override("font_size", 13)
				row.add_child(name_lbl)
				var dur_secs: int = (round_data.get("length_ms", 0) as int) / 1000
				var dur_lbl: Label = Label.new()
				dur_lbl.text = _format_duration(dur_secs)
				dur_lbl.custom_minimum_size = Vector2(56, 0)
				dur_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				dur_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
				dur_lbl.add_theme_font_size_override("font_size", 12)
				row.add_child(dur_lbl)
				var acts_lbl: Label = Label.new()
				acts_lbl.text = str(round_data.get("action_count", 0)) + " actions"
				acts_lbl.custom_minimum_size = Vector2(72, 0)
				acts_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				acts_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
				acts_lbl.add_theme_font_size_override("font_size", 12)
				row.add_child(acts_lbl)
				var coins_lbl: Label = Label.new()
				coins_lbl.text = "♦ " + str(round_data.get("coins", 0))
				coins_lbl.custom_minimum_size = Vector2(72, 0)
				coins_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				coins_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
				coins_lbl.add_theme_font_size_override("font_size", 12)
				row.add_child(coins_lbl)
				list.add_child(_indent_wrap(row, indent))


# Renders a fork header + each path (with path header + recursed items).
func _add_fork_to_list(list: VBoxContainer, fork: Dictionary, indent: int) -> void:
	# Fork header row
	var fork_row: HBoxContainer = HBoxContainer.new()
	fork_row.add_theme_constant_override("separation", 8)
	var fork_lbl: Label = Label.new()
	var paths: Array = fork.get("paths", [])
	var fork_title: String = fork.get("title", "")
	if fork_title != "":
		fork_lbl.text = "⑂  FORK: %s  (%d PATHS)" % [fork_title.to_upper(), paths.size()]
	else:
		fork_lbl.text = "⑂  FORK  (%d PATHS)" % paths.size()
	fork_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fork_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	fork_lbl.add_theme_font_size_override("font_size", 11)
	fork_row.add_child(fork_lbl)
	list.add_child(_indent_wrap(fork_row, indent))

	# Each path
	for pi: int in paths.size():
		var path: Dictionary = paths[pi]
		var path_name: String = path.get("name", "Path %d" % (pi + 1))

		# Path header
		var path_row: HBoxContainer = HBoxContainer.new()
		path_row.add_theme_constant_override("separation", 8)
		var path_lbl: Label = Label.new()
		path_lbl.text = "▸  PATH %d: %s" % [pi + 1, path_name.to_upper()]
		path_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		path_lbl.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
		path_lbl.add_theme_font_size_override("font_size", 11)
		path_row.add_child(path_lbl)
		list.add_child(_indent_wrap(path_row, indent + 1))

		# Path contents (recurse)
		_add_seq_to_list(
			list,
			path.get("rounds",      []),
			path.get("shops",       []),
			path.get("storyboards", []),
			path.get("forks",       []),
			indent + 2
		)


# Wraps a control in a MarginContainer that adds `indent * INDENT_PX` of left padding.
func _indent_wrap(child: Control, indent: int) -> Control:
	if indent == 0:
		return child
	var mc: MarginContainer = MarginContainer.new()
	mc.add_theme_constant_override("margin_left", indent * INDENT_PX)
	mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.add_child(child)
	return mc


func _format_duration(total_seconds: int) -> String:
	var h: int = total_seconds / 3600
	var m: int = (total_seconds % 3600) / 60
	var s: int = total_seconds % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s]
	return "%d:%02d" % [m, s]
