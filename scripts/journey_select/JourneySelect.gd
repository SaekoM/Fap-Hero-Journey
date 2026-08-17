extends Control

# ---------------------------------------------------------------------------
# JourneySelect.gd
# Purple matrix theme. Scrollable catalogue grid of journey cards. Clicking
# a card opens a detail modal with stats parsed from journey.json and
# funscript files found in user://journeys/<folder>/<round-name>/.
# ---------------------------------------------------------------------------

const TOP_BAR_HEIGHT: int = 64
const GRID_TOP_MARGIN: int = 16
const GRID_PADDING: int = 40
const GRID_SEPARATION: int = 24
const CARD_MIN_WIDTH: int = 280
# Inset around the card grid so hover-scaled cards on the outer edge have room
# to expand without being clipped by the scroll viewport.
const HOVER_MARGIN: int = 12
const MODAL_MIN_WIDTH: int = 980
const MODAL_MIN_HEIGHT: int = 600
const MODAL_COVER_W: int = 280
const BORDER_WIDTH: int = 3

# Journeys root is configurable via Options → Journey Storage Location.
# Read via SettingsService.get_journeys_dir() so changes take effect next scan.

# Difficulty list is owned by JourneyData (canonical schema) — JourneyData.DIFFICULTIES.

const DIFF_COLORS: Dictionary = {
	"Easy": Color(0.35, 0.95, 0.35),
	"Medium": Color(0.95, 0.95, 0.25),
	"Hard": Color(1.0, 0.55, 0.1),
	"Very Hard": Color(1.0, 0.25, 0.05),
	"Extreme": Color(1.0, 0.1, 0.1),
	"Insane": Color(0.9, 0.05, 0.5),
}

const JourneyCardScene = preload("res://scenes/journey_select/JourneyCard.tscn")

@onready var _bg: ColorRect = $Background
@onready var _top_bar: HBoxContainer = $TopBar
@onready var _back_btn: Button = $TopBar/BackButton
@onready var _title_lbl: Label = $TopBar/TitleLabel
@onready var _sort_lbl: Label = $TopBar/SortContainer/SortLabel
@onready var _sort_name: Button = $TopBar/SortContainer/SortNameBtn
@onready var _sort_duration: Button = $TopBar/SortContainer/SortDurationBtn
@onready var _sort_actions: Button = $TopBar/SortContainer/SortActionsBtn
@onready var _scroll: ScrollContainer = $ScrollContainer
@onready var _grid: GridContainer = $ScrollContainer/Grid
@onready var _empty_lbl: Label = $EmptyLabel
@onready var _modal: Control = $DetailModal
@onready var _backdrop: ColorRect = $DetailModal/Backdrop
@onready var _modal_panel: PanelContainer = $DetailModal/ModalPanel
@onready var _modal_layout: HBoxContainer = $DetailModal/ModalPanel/ModalLayout
@onready var _cover_img: TextureRect = $DetailModal/ModalPanel/ModalLayout/CoverImage
@onready var _details_col: VBoxContainer = $DetailModal/ModalPanel/ModalLayout/DetailsColumn
@onready var _modal_title: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalTitle
@onready var _modal_author: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalAuthor
@onready var _modal_diff: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalDifficulty
@onready var _modal_desc: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalDescription
@onready
var _stat_rounds: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsRow/StatRounds
@onready
var _stat_actions: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsRow/StatActions
@onready
var _stat_length: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsRow/StatLength
@onready var _rounds_hdr: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundsHeader
@onready
var _round_scroll: ScrollContainer = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundListScroll
@onready
var _round_list: VBoxContainer = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundListScroll/RoundList
@onready
var _play_btn: Button = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionRow/PlayButton
@onready
var _edit_btn: Button = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionRow/EditButton
# The EDIT button's normal label, captured at setup so _refresh_edit_lock can swap in a locked variant.
var _edit_btn_base_text: String = ""
@onready
var _delete_btn: Button = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionRow/DeleteButton

# Dynamically created in _populate_modal when the current journey has a save.
# Inserted as the first child of the ActionRow so it sits before Play. Removed
# (and Play recoloured) when the modal switches to a journey without a save.
var _resume_btn: Button = null
# "RESUME PART 2" — appears only when a rendition is selected in VERSION and a Part-1 carryover exists for
# an ending that rendition extends (feature #5). Rebuilt on every VERSION change.
var _rend_resume_btn: Button = null
# Delete-rendition button in the VERSION row; visible only when a rendition (not Base) is selected.
var _rend_delete_btn: Button = null

# EXPORT button — created once in _connect_signals, lives at the end of the modal ActionRow. Packages
# the selected journey to a shareable .fhj. No version gate (packaging only copies what's on disk).
var _export_btn: Button = null

# IMPORT button — created once in _connect_signals, lives in the top bar (a global action, not tied to
# a selected journey). Reads a .fhj, previews it, then installs it into the journeys folder.
var _import_btn: Button = null

# Rendition (overlay) version selector — built per-modal when the selected journey has installed
# renditions. `_selected_rendition` is {} for the plain base, or the chosen rendition summary dict.
var _rendition_select: OptionButton = null
var _selected_rendition: Dictionary = {}

# ＋ RENDITION button — a per-journey action (modal ActionRow) that opens the builder in overlay mode.
var _rendition_btn: Button = null

# Separate scoreboard panel, floated to the right of the detail modal. Built once
# (lazily) and repositioned against the modal's right edge when the modal opens
# or the viewport resizes. _scoreboard_content holds the per-journey rows.
var _scoreboard_panel: PanelContainer = null
var _scoreboard_content: VBoxContainer = null
const SCOREBOARD_PANEL_W: int = 300
const SCOREBOARD_PANEL_GAP: int = 16

var _journeys: Array = []
var _sort_field: String = "name"
var _sort_asc: bool = true
var _current_journey: Dictionary = {}

# Set true for one call when the user chose "Open Anyway" past the newer-version warning, so
# the re-invoked play/resume/edit handler skips the gate instead of looping the dialog.
var _bypass_version_gate: bool = false

# Search / filter state
var _search_text: String = ""
var _diff_filter_idx: int = 0  # 0 = all, 1+ = DIFFICULTIES[idx-1]
var _tag_filter_idx: int = 0  # 0 = all, 1+ = TagRegistry.all()[idx-1]

# Dynamically-created filter widgets (added to _top_bar in _apply_layout)
var _search_field: LineEdit = null
var _diff_filter: OptionButton = null
var _tag_filter: OptionButton = null
var _count_label: Label = null


func _ready() -> void:
	MusicService.play()
	_apply_layout()
	_apply_theme()
	_connect_signals()
	_scan_journeys()
	_sort_and_populate()
	_modal.visible = false
	# Keep the floating scoreboard glued to the modal's right edge across resizes.
	get_viewport().size_changed.connect(_position_scoreboard_panel)


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------


func _apply_layout() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = 0
	_bg.offset_top = 0
	_bg.offset_right = 0
	_bg.offset_bottom = 0

	var animated_bg: Control = $AnimatedBackground
	animated_bg.anchor_right = 1.0
	animated_bg.anchor_bottom = 1.0

	_top_bar.anchor_right = 1.0
	_top_bar.anchor_bottom = 0.0
	_top_bar.offset_left = 16
	_top_bar.offset_right = -16
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_top_bar.add_theme_constant_override("separation", 10)

	# Header background strip — a dark, slightly translucent panel with an accent
	# underline that grounds the bar and separates it from the grid below.
	var bar_bg: Panel = Panel.new()
	var bar_style: StyleBoxFlat = StyleBoxFlat.new()
	bar_style.bg_color = UITheme.BAR_BG
	bar_style.border_width_bottom = 2
	bar_style.border_color = UITheme.PURPLE_MID
	bar_bg.add_theme_stylebox_override("panel", bar_style)
	bar_bg.anchor_right = 1.0
	bar_bg.anchor_bottom = 0.0
	bar_bg.offset_bottom = TOP_BAR_HEIGHT
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	_search_field.placeholder_text = "Search journeys…"
	_search_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_field.custom_minimum_size = Vector2(180, 0)
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

	_scroll.anchor_right = 1.0
	_scroll.anchor_bottom = 1.0
	_scroll.offset_top = TOP_BAR_HEIGHT + GRID_TOP_MARGIN
	_scroll.offset_left = GRID_PADDING
	_scroll.offset_right = -GRID_PADDING
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_grid.add_theme_constant_override("h_separation", GRID_SEPARATION)
	_grid.add_theme_constant_override("v_separation", GRID_SEPARATION)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Wrap the grid in a MarginContainer so hover-scaled cards along the grid's
	# outer edge expand into this inset instead of being clipped by the scroll.
	var grid_mc: MarginContainer = MarginContainer.new()
	grid_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_mc.add_theme_constant_override("margin_left", HOVER_MARGIN)
	grid_mc.add_theme_constant_override("margin_right", HOVER_MARGIN)
	grid_mc.add_theme_constant_override("margin_top", HOVER_MARGIN)
	grid_mc.add_theme_constant_override("margin_bottom", HOVER_MARGIN)
	_scroll.remove_child(_grid)
	grid_mc.add_child(_grid)
	_scroll.add_child(grid_mc)

	_empty_lbl.anchor_right = 1.0
	_empty_lbl.anchor_bottom = 1.0
	_empty_lbl.offset_top = TOP_BAR_HEIGHT + GRID_TOP_MARGIN

	_scroll.resized.connect(_update_grid_columns)
	get_viewport().size_changed.connect(_update_grid_columns)
	_update_grid_columns.call_deferred()

	_modal.anchor_right = 1.0
	_modal.anchor_bottom = 1.0

	_backdrop.anchor_right = 1.0
	_backdrop.anchor_bottom = 1.0

	_modal_panel.anchor_left = 0.5
	_modal_panel.anchor_right = 0.5
	_modal_panel.anchor_top = 0.5
	_modal_panel.anchor_bottom = 0.5
	_modal_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_modal_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_modal_panel.custom_minimum_size = Vector2(MODAL_MIN_WIDTH, MODAL_MIN_HEIGHT)
	# Keep the floating scoreboard glued to the modal panel's actual rect. The
	# panel re-lays-out (and re-centres) for a frame or two after the modal opens
	# with fresh content, so positioning it once off a single-frame size read was
	# racy — it would intermittently latch a stale/huge size and stretch off
	# screen until reopened. Tracking item_rect_changed self-corrects every pass.
	_modal_panel.item_rect_changed.connect(_position_scoreboard_panel)

	_modal_layout.add_theme_constant_override("separation", 20)

	_cover_img.custom_minimum_size = Vector2(MODAL_COVER_W, 0)
	_cover_img.size_flags_vertical = Control.SIZE_EXPAND_FILL

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
	_style_label(_title_lbl, UITheme.PURPLE_BRIGHT, 18, true)
	# Title no longer expands — the search field takes the flexible slot instead.
	_title_lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT

	_style_label(_sort_lbl, UITheme.PURPLE_MID, 13, true)
	_style_label(_empty_lbl, UITheme.PURPLE_MID, 15, true)
	_empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_style_button(_back_btn, UITheme.MAGENTA)
	_style_button(_sort_name, UITheme.PURPLE_BRIGHT)
	_style_button(_sort_duration, UITheme.PURPLE_MID)
	_style_button(_sort_actions, UITheme.PURPLE_MID)
	_style_button(_play_btn, UITheme.PURPLE_BRIGHT)
	_style_button(_edit_btn, UITheme.PURPLE_MID)
	_edit_btn_base_text = _edit_btn.text
	_style_button(_delete_btn, UITheme.DANGER)

	UITheme.style_line_edit(_search_field)
	UITheme.style_option_button(_diff_filter)
	UITheme.style_option_button(_tag_filter)
	_style_label(_count_label, UITheme.PURPLE_MID, 12, true)

	_style_modal_panel()

	_style_label(_modal_title, UITheme.PURPLE_BRIGHT, 22, true)
	_style_label(_modal_author, UITheme.PURPLE_MID, 13, false)
	_style_label(_modal_diff, UITheme.MAGENTA, 15, true)
	_style_label(_modal_desc, UITheme.WHITE_SOFT, 12, false)
	_modal_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_style_label(_stat_rounds, UITheme.WHITE_SOFT, 13, true)
	_style_label(_stat_actions, UITheme.WHITE_SOFT, 13, true)
	_style_label(_stat_length, UITheme.WHITE_SOFT, 13, true)

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
	s.border_color = UITheme.PURPLE_BRIGHT
	s.border_width_left = BORDER_WIDTH
	s.border_width_right = BORDER_WIDTH
	s.border_width_top = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left = 4
	s.corner_radius_top_right = 4
	s.corner_radius_bottom_left = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.5)
	s.shadow_size = 16
	s.content_margin_left = 20
	s.content_margin_right = 28
	s.content_margin_top = 28
	s.content_margin_bottom = 28
	_modal_panel.add_theme_stylebox_override("panel", s)


# Thin delegates to UITheme — the canonical styling lives there. Args preserve this screen's padding.
func _style_label(label: Label, color: Color, size: int, uppercase: bool = false) -> void:
	UITheme.style_label(label, color, size, uppercase)


func _style_button(btn: Button, accent: Color) -> void:
	UITheme.style_button(btn, accent, 18, 12)


func _set_active_sort() -> void:
	var arrow: String = " ▲" if _sort_asc else " ▼"
	_style_button(
		_sort_name, UITheme.PURPLE_BRIGHT if _sort_field == "name" else UITheme.PURPLE_MID
	)
	_style_button(
		_sort_duration, UITheme.PURPLE_BRIGHT if _sort_field == "duration" else UITheme.PURPLE_MID
	)
	_style_button(
		_sort_actions, UITheme.PURPLE_BRIGHT if _sort_field == "actions" else UITheme.PURPLE_MID
	)
	_sort_name.text = ("NAME" + arrow) if _sort_field == "name" else "NAME"
	_sort_duration.text = ("DURATION" + arrow) if _sort_field == "duration" else "DURATION"
	_sort_actions.text = ("ACTIONS" + arrow) if _sort_field == "actions" else "ACTIONS"


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
	# Play plays start_journey at the embark point (not on press — a New Run shows
	# an overwrite confirm first), so mute its default click.
	UISound.mute_button(_play_btn)
	_edit_btn.pressed.connect(_on_edit_pressed)
	_delete_btn.pressed.connect(_on_delete_pressed)
	_search_field.text_changed.connect(
		func(text: String) -> void:
			_search_text = text.strip_edges()
			_sort_and_populate()
	)
	_diff_filter.item_selected.connect(
		func(idx: int) -> void:
			_diff_filter_idx = idx
			_sort_and_populate()
	)
	_tag_filter.item_selected.connect(
		func(idx: int) -> void:
			_tag_filter_idx = idx
			_sort_and_populate()
	)
	_build_export_button()
	_build_import_button()
	_build_rendition_button()


func _on_sort_pressed(field: String) -> void:
	if _sort_field == field:
		_sort_asc = not _sort_asc
	else:
		_sort_field = field
		_sort_asc = true
	_sort_and_populate()


func _on_back_pressed() -> void:
	Transition.change_scene("res://scenes/main/Main.tscn")


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_close_modal()


# Version gate: true when the running app is new enough for the selected journey (journeys
# stamp a MinVersion at save; older/unstamped ones always pass). See UpdateService.app_meets.
func _app_supports_current() -> bool:
	return UpdateService.app_meets(str(_current_journey.get("min_version", "")))


# Pops a "made for a newer version" warning. On "Open Anyway", sets the one-shot bypass and
# re-runs `retry` (the originating play/resume/edit handler), which then skips the gate.
func _warn_version_then(retry: Callable) -> void:
	var need: String = str(_current_journey.get("min_version", ""))
	var dialog: ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Newer Version Needed"
	dialog.dialog_text = (
		"This journey was made for FHJ v%s or newer. You're on v%s, so it may not open or play correctly.\n\nUpdate from the main menu to be safe."
		% [need, UpdateService.current_version()]
	)
	dialog.ok_button_text = "OPEN ANYWAY"
	dialog.cancel_button_text = "CANCEL"
	dialog.get_ok_button().add_theme_color_override("font_color", UITheme.DANGER)
	dialog.confirmed.connect(
		func() -> void:
			_bypass_version_gate = true
			dialog.queue_free()
			retry.call()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()


func _on_play_pressed() -> void:
	if _current_journey.is_empty():
		return
	if not _bypass_version_gate and not _app_supports_current():
		_warn_version_then(_on_play_pressed)
		return
	_bypass_version_gate = false
	# A rendition run is isolated (its own save key) and always starts fresh, so it skips the base-save
	# overwrite confirm below.
	if not _selected_rendition.is_empty():
		_on_play_pressed_unguarded()
		return
	# When a save exists, "Play" means New Run — confirm overwrite first so
	# the user doesn't lose progress they may have forgotten about.
	var folder_name: String = _current_journey.get("folder_name", "")
	if JourneySaveService.has_save(folder_name):
		var title: String = _current_journey.get("title", "this journey")
		var dialog: ConfirmationDialog = ConfirmationDialog.new()
		dialog.title = "Start a New Run?"
		dialog.dialog_text = (
			'You have a saved run for "%s". Starting a new run will permanently delete that save.\n\nUse the Resume button instead to continue where you left off.'
			% title
		)
		dialog.ok_button_text = "DELETE SAVE & PLAY"
		dialog.cancel_button_text = "CANCEL"
		dialog.get_ok_button().add_theme_color_override("font_color", UITheme.DANGER)
		dialog.confirmed.connect(_on_play_pressed_unguarded)
		dialog.canceled.connect(func() -> void: dialog.queue_free())
		add_child(dialog)
		dialog.popup_centered()
		return
	_on_play_pressed_unguarded()


func _on_edit_pressed() -> void:
	if _current_journey.is_empty():
		return
	if not _bypass_version_gate and not _app_supports_current():
		_warn_version_then(_on_edit_pressed)
		return
	_bypass_version_gate = false
	# A rendition selected in the VERSION dropdown → edit the overlay (base ghosted, its delta re-loaded);
	# otherwise edit the base journey.
	if not _selected_rendition.is_empty():
		if bool(_selected_rendition.get("locked", false)):
			_show_locked_message("rendition")
			return
		# A rendition that stacks on ANOTHER rendition must ghost the composed base ⊕ ancestor chain — else
		# its anchors onto the ancestor's nodes have nothing to attach to (disconnected graph) and its
		# ParentId would be reset to the base on save. A rendition anchored straight to the base needs none.
		if not _setup_rendition_ancestors_for_edit():
			return
		JourneyBuilder.rendition_parent = _current_journey
		JourneyBuilder.edit_rendition = _selected_rendition
	else:
		if bool(_current_journey.get("locked", false)):
			_show_locked_message("journey")
			return
		JourneyBuilder.edit_journey = _current_journey
	Transition.change_scene("res://scenes/journey_builder/JourneyBuilder.tscn")


# The soft edit-lock stops a buyer opening a paid import in the builder. It's a courtesy lock, not
# copy protection — journey.json is plaintext — so the message says what happened without overpromising.
func _show_locked_message(kind: String) -> void:
	_show_message(
		"Locked",
		(
			"This %s was installed from a paid pack and is locked for editing — it belongs to its creator.\n\nYou can still play it and build renditions on top of it."
			% kind
		)
	)


func _on_delete_pressed() -> void:
	if _current_journey.is_empty():
		return
	var title: String = _current_journey.get("title", "this journey")
	var body: String = (
		'Permanently delete "%s"?\n\nAll videos, funscripts, and cover images in the journey folder will be removed. This cannot be undone.'
		% title
	)
	# A base with renditions: warn that the overlays lose their parent. They're not deleted, but drop out of
	# the catalogue (no base to attach to) until this journey is reinstalled by the same JourneyId.
	var rends: Array = _current_journey.get("renditions", [])
	if not rends.is_empty():
		body += (
			"\n\n⚠ %d rendition%s overlay this journey — they'll stop working and disappear from the catalogue until you reinstall the base. (They aren't deleted.)"
			% [rends.size(), "s" if rends.size() != 1 else ""]
		)
	var dialog: ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Delete Journey"
	dialog.dialog_text = body
	dialog.ok_button_text = "DELETE"
	dialog.get_ok_button().add_theme_color_override("font_color", UITheme.DANGER)
	dialog.confirmed.connect(
		func() -> void:
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
	# Also drop the save file and scoreboard — a deleted journey shouldn't leave
	# orphan data in user:// that would resurface if the user creates a new
	# journey with the same folder name.
	JourneySaveService.delete_save(_current_journey.get("folder_name", ""))
	ScoreboardService.clear(_current_journey.get("folder_name", ""))
	_journeys.erase(_current_journey)
	_current_journey = {}
	_close_modal()
	_sort_and_populate()


# ---------------------------------------------------------------------------
# Export (.fhj packaging)
# ---------------------------------------------------------------------------


func _build_export_button() -> void:
	_export_btn = Button.new()
	_export_btn.text = "⬆  EXPORT"
	_style_button(_export_btn, UITheme.CYAN)
	_export_btn.pressed.connect(_on_export_pressed)
	_play_btn.get_parent().add_child(_export_btn)


func _build_rendition_button() -> void:
	_rendition_btn = Button.new()
	_rendition_btn.text = "＋  RENDITION"
	_style_button(_rendition_btn, UITheme.PURPLE_MID)
	_rendition_btn.pressed.connect(_on_rendition_pressed)
	_play_btn.get_parent().add_child(_rendition_btn)


# Opens the builder in overlay-authoring mode against the selected journey. Requires the base to have a
# stable JourneyId (the overlay's ParentId) — a pre-id journey must be re-saved once in the builder first.
func _on_rendition_pressed() -> void:
	if _current_journey.is_empty():
		return
	if str(_current_journey.get("journey_id", "")) == "":
		_show_message(
			"Can't Add a Rendition",
			"This journey has no stable ID yet. Open it in the builder and save once to give it an ID, then renditions can target it."
		)
		return
	JourneyBuilder.rendition_parent = _current_journey
	JourneyBuilder.rendition_over = {}
	# With a rendition SELECTED in VERSION, the new overlay targets IT (sibling-dependency) rather than the
	# base: compose base ⊕ its chain as the ghosted parent, and stamp its id as the new overlay's ParentId.
	if not _selected_rendition.is_empty():
		var composed: Dictionary = JourneyScanner.compose_play_journey(
			_current_journey.get("folder", ""),
			_current_journey.get("folder_name", ""),
			_selected_chain()
		)
		if composed.is_empty() or not (composed.get("compose_errors", []) as Array).is_empty():
			_show_message(
				"Can't Overlay That",
				"The selected rendition didn't compose cleanly, so it can't be a parent. Fix it first."
			)
			return
		JourneyBuilder.rendition_over = {
			"start": composed.get("start", ""),
			"nodes": composed.get("nodes", {}),
			"parent_id": str(_selected_rendition.get("journey_id", "")),
			"parent_name": str(_selected_rendition.get("name", "")),
		}
	Transition.change_scene("res://scenes/journey_builder/JourneyBuilder.tscn")


func _on_export_pressed() -> void:
	if _current_journey.is_empty():
		return
	# Re-packaging a paid import is the same leak the lock guards against, so export is blocked too.
	if _selection_locked():
		_show_locked_message("rendition" if not _selected_rendition.is_empty() else "journey")
		return
	# Both a base journey and a rendition (selected in the VERSION dropdown) can split into a free video
	# pack + a paid scripts pack — but only when there's actually scene video to give away. A scripts-only
	# overlay (e.g. a multi-axis rendition) has none, so a split would just emit an empty video pack: offer
	# self-contained only, with a note. `_export_folder`/`_export_default_name` target whichever is selected.
	var has_scene: bool = _export_has_scene_assets()
	var body: String = "Choose an export format:\n\n•  Self-contained — everything in one .fhj file."
	var buttons: Array = [
		{
			"text": "SELF-CONTAINED",
			"accent": UITheme.PURPLE_BRIGHT,
			"on_press": _pick_selfcontained_location
		},
	]
	if has_scene:
		body += "\n•  Split — a free video pack + a paid scripts pack (for selling scripts)."
		buttons.append(
			{
				"text": "SPLIT: VIDEO + SCRIPTS",
				"accent": UITheme.CYAN,
				"on_press": _open_split_router
			}
		)
	else:
		body += "\n\n(Split is unavailable — this has no scene video to distribute for free.)"
	buttons.append({"text": "CANCEL", "accent": UITheme.PURPLE_MID})
	_themed_modal("Export Journey", body, buttons)


# True when the export target (the selected rendition, else the base) carries any SCENE video — the free
# side of a split. Without it, a split would produce an empty video pack, so the SPLIT option is withheld.
func _export_has_scene_assets() -> bool:
	var data: Dictionary = JourneyScanner._read_raw_json(_export_folder())
	if data.is_empty():
		return true  # can't read it — don't suppress the option
	for a: Dictionary in JourneyPackage.enumerate_assets(data):
		if str(a.get("role", "")) == "scene":
			return true
	return false


# The folder + default filename to export — the selected rendition's when one is chosen, else the base.
func _export_folder() -> String:
	if _selected_rendition.is_empty():
		return str(_current_journey.get("folder", ""))
	return str(_selected_rendition.get("folder", ""))


func _export_default_name() -> String:
	var title: String = (
		str(_current_journey.get("title", "journey"))
		if _selected_rendition.is_empty()
		else str(_selected_rendition.get("name", "rendition"))
	)
	return JourneyData.sanitize_folder_name(title) + ".fhj"


func _pick_selfcontained_location() -> void:
	var default_name: String = _export_default_name()
	var dialog: FileDialog = FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.title = "Export Journey Package"
	dialog.add_filter("*.fhj", "FHJ Journey Package")
	dialog.current_file = default_name
	SettingsService.remember_browse_dir(dialog)
	dialog.file_selected.connect(
		func(path: String) -> void:
			dialog.queue_free()
			_run_export(path)
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


func _run_export(out_path: String) -> void:
	if not out_path.to_lower().ends_with(".fhj"):
		out_path += ".fhj"
	var folder: String = _export_folder()
	var progress: Dictionary = _show_progress_overlay("Exporting journey…")
	var bar: ProgressBar = progress["bar"]
	var result: Dictionary = await JourneyPackager.export_journey(
		folder, out_path, "embedded", func(frac: float) -> void: bar.value = frac * 100.0
	)
	(progress["overlay"] as Node).queue_free()
	if bool(result.get("ok", false)):
		_show_message("Journey Exported", "Saved to:\n%s" % out_path)
	else:
		_show_message("Export Failed", str(result.get("error", "Unknown error.")))


# The split-export routing modal: per-group Free/Paid choice (scene video + cover are always free).
# Scripts/Images/Audio default to Paid. Collects role → "free"/"paid" and hands off to the save picker.
func _open_split_router() -> void:
	var m: Dictionary = _make_modal_overlay(500)
	var overlay: Node = m["overlay"]
	var col: VBoxContainer = m["body"]

	var header: Label = Label.new()
	_style_label(header, UITheme.PURPLE_BRIGHT, 18)
	header.text = "SPLIT EXPORT — WHAT DO YOU SELL?"
	col.add_child(header)

	var info: Label = Label.new()
	_style_label(info, UITheme.WHITE_SOFT, 13)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.text = "Video and cover are always free. Anything set to Paid goes into the scripts pack; everything free goes into the video pack."
	col.add_child(info)

	# role → the group's OptionButton (Paid=index 0, Free=index 1); several roles can share one group.
	var opt_by_role: Dictionary = {}
	var groups: Array = [
		["📜 Scripts (funscript + axis/vibe)", ["funscript", "axis", "vibe"]],
		["🖼 Images (portraits, boss/fork art, backgrounds)", ["image"]],
		["🔊 Audio (music + accents)", ["audio"]],
	]
	for g: Array in groups:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var lbl: Label = Label.new()
		_style_label(lbl, UITheme.WHITE_SOFT, 14)
		lbl.text = str(g[0])
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)
		var opt: OptionButton = OptionButton.new()
		opt.add_item("Paid", 0)
		opt.add_item("Free", 1)
		opt.selected = 0
		row.add_child(opt)
		col.add_child(row)
		for role: String in g[1] as Array:
			opt_by_role[role] = opt

	col.add_child(HSeparator.new())
	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	_style_button(cancel_btn, UITheme.PURPLE_MID)
	cancel_btn.pressed.connect(overlay.queue_free)
	btn_row.add_child(cancel_btn)
	var go_btn: Button = Button.new()
	go_btn.text = "EXPORT ▸"
	_style_button(go_btn, UITheme.CYAN)
	go_btn.pressed.connect(
		func() -> void:
			var role_overrides: Dictionary = {}
			for role: String in opt_by_role:
				var opt: OptionButton = opt_by_role[role]
				role_overrides[role] = "free" if opt.selected == 1 else "paid"
			overlay.queue_free()
			_pick_split_location(role_overrides)
	)
	btn_row.add_child(go_btn)
	col.add_child(btn_row)


func _pick_split_location(role_overrides: Dictionary) -> void:
	var default_name: String = _export_default_name()  # the selected rendition's name, else the base's
	var dialog: FileDialog = FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.title = "Export Split Packs (choose a base name)"
	dialog.add_filter("*.fhj", "FHJ Journey Package")
	dialog.current_file = default_name
	SettingsService.remember_browse_dir(dialog)
	dialog.file_selected.connect(
		func(path: String) -> void:
			dialog.queue_free()
			_run_split_export(path, role_overrides)
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


func _run_split_export(base_path: String, role_overrides: Dictionary) -> void:
	var folder: String = _export_folder()  # the selected rendition's folder, else the base's
	var progress: Dictionary = _show_progress_overlay("Exporting split packs…")
	var bar: ProgressBar = progress["bar"]
	var result: Dictionary = await JourneyPackager.export_split(
		folder, base_path, role_overrides, func(frac: float) -> void: bar.value = frac * 100.0
	)
	(progress["overlay"] as Node).queue_free()
	if bool(result.get("ok", false)):
		_show_message(
			"Split Exported",
			(
				"Created two files:\n%s\n%s"
				% [
					str(result.get("scripts", "")).get_file(),
					str(result.get("video", "")).get_file(),
				]
			)
		)
	else:
		_show_message("Export Failed", str(result.get("error", "Unknown error.")))


# ── Themed modal overlays ────────────────────────────────────────────────────
# Native AcceptDialog/ConfirmationDialog render in Godot's gray default theme, so every export/import
# dialog uses these instead: a dim full-screen overlay with an app-themed panel, CENTERED via a
# CenterContainer. (Anchoring an auto-sized panel with PRESET_CENTER pins its top-left to the middle,
# which is why the split modal appeared off-centre.)


# Dim overlay + centered themed panel, already added to the tree. Returns {overlay, body}; fill `body`
# (a VBox) and free `overlay` when done.
func _make_modal_overlay(min_width: int = 480) -> Dictionary:
	var overlay: ColorRect = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.6)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.border_color = UITheme.PURPLE_BRIGHT
	ps.set_border_width_all(2)
	ps.set_corner_radius_all(6)
	ps.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)

	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.custom_minimum_size = Vector2(min_width, 0)
	panel.add_child(body)

	add_child(overlay)
	return {"overlay": overlay, "body": body}


# A themed message / confirmation modal: title, wrapped body, and a right-aligned button row. Each
# button = {"text": String, "accent": Color, "on_press": Callable}; pressing one frees the overlay then
# calls its on_press (an absent/invalid Callable just dismisses).
func _themed_modal(title: String, body_text: String, buttons: Array) -> void:
	var m: Dictionary = _make_modal_overlay()
	var col: VBoxContainer = m["body"]
	var overlay: Node = m["overlay"]

	var hdr: Label = Label.new()
	_style_label(hdr, UITheme.PURPLE_BRIGHT, 18)
	hdr.text = title
	col.add_child(hdr)

	if body_text != "":
		var lbl: Label = Label.new()
		_style_label(lbl, UITheme.WHITE_SOFT, 14)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.custom_minimum_size = Vector2(480, 0)
		lbl.text = body_text
		col.add_child(lbl)

	col.add_child(HSeparator.new())
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_END
	for b: Dictionary in buttons:
		var btn: Button = Button.new()
		btn.text = str(b["text"])
		_style_button(btn, b.get("accent", UITheme.PURPLE_MID))
		var cb: Callable = b.get("on_press", Callable())
		btn.pressed.connect(
			func() -> void:
				overlay.queue_free()
				if cb.is_valid():
					cb.call()
		)
		row.add_child(btn)
	col.add_child(row)


# Progress overlay (themed, centered). Returns {overlay, bar}; caller updates bar.value (0–100) and
# frees overlay when done.
func _show_progress_overlay(title: String) -> Dictionary:
	var m: Dictionary = _make_modal_overlay(420)
	var col: VBoxContainer = m["body"]
	var lbl: Label = Label.new()
	_style_label(lbl, UITheme.PURPLE_BRIGHT, 18)
	lbl.text = title
	col.add_child(lbl)
	var bar: ProgressBar = ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = 0.0
	col.add_child(bar)
	return {"overlay": m["overlay"], "bar": bar}


func _show_message(title: String, body: String) -> void:
	_themed_modal(title, body, [{"text": "OK", "accent": UITheme.PURPLE_BRIGHT}])


# ---------------------------------------------------------------------------
# Import (.fhj packaging)
# ---------------------------------------------------------------------------


func _build_import_button() -> void:
	_import_btn = Button.new()
	_import_btn.text = "⬇  IMPORT"
	_style_button(_import_btn, UITheme.CYAN)
	_import_btn.pressed.connect(_on_import_pressed)
	_top_bar.add_child(_import_btn)
	_top_bar.move_child(_import_btn, _back_btn.get_index() + 1)


func _on_import_pressed() -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.title = "Import Journey Package"
	dialog.add_filter("*.fhj", "FHJ Journey Package")
	SettingsService.remember_browse_dir(dialog)
	dialog.file_selected.connect(
		func(path: String) -> void:
			dialog.queue_free()
			_open_package(path)
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


# Reads the manifest and either rejects (corrupt / not-yet-supported package kinds) or shows the
# preview. Lean + rendition packages are 0.7.2 — refuse them clearly rather than half-installing.
func _open_package(fhj_abs: String) -> void:
	var manifest: Dictionary = JourneyPackager.read_manifest(fhj_abs)
	if not bool(manifest.get("ok", false)):
		var why: String = str(manifest.get("error", "Unrecognized file."))
		if str(manifest.get("error", "")) == "newer_format":
			why = "This package was made by a newer version of FHJ. Update to import it."
		_show_message("Import Failed", why)
		return
	var pack: String = str(manifest.get("pack", "full"))
	# A video pack (base OR rendition) carries no journey.json and always recombines via media-merge, so
	# route it by pack BEFORE the rendition-type check — a rendition's video pack is also type:rendition.
	if pack == "video":
		_import_video_pack(fhj_abs, manifest)
		return
	if str(manifest.get("type", "journey")) == "rendition":
		_import_rendition_package(fhj_abs, manifest)
		return
	# "full" and "scripts" both carry journey.json → install as a journey. A "full" pack marked lean is
	# the 0.7.2 user-sourced re-link case (not the split scripts half), which isn't supported yet.
	if pack == "full" and str(manifest.get("mode", "embedded")) == "lean":
		_show_message(
			"Not Supported Yet",
			"This package ships without its video and needs re-linking — that arrives in a later update."
		)
		return
	_show_import_preview(fhj_abs, manifest)


func _show_import_preview(fhj_abs: String, manifest: Dictionary) -> void:
	var counts: Dictionary = manifest.get("counts", {})
	var body: String = (
		"%s\nby %s\n\n%d rounds · %d forks · %d shops · %d storyboards"
		% [
			str(manifest.get("name", "Untitled")),
			str(manifest.get("author", "Unknown")),
			int(counts.get("rounds", 0)),
			int(counts.get("forks", 0)),
			int(counts.get("shops", 0)),
			int(counts.get("storyboards", 0)),
		]
	)
	var need: String = str(manifest.get("min_version", ""))
	if need != "" and not UpdateService.app_meets(need):
		body += (
			"\n\n⚠ Made for FHJ v%s or newer (you're on v%s). It may not open or play correctly."
			% [need, UpdateService.current_version()]
		)
	if str(manifest.get("pack", "full")) == "scripts":
		body += "\n\nℹ Scripts-only pack — after importing, add its companion video pack to play with video."

	_themed_modal(
		"Import Journey",
		body,
		[
			{
				"text": "IMPORT",
				"accent": UITheme.PURPLE_BRIGHT,
				"on_press": _begin_import.bind(fhj_abs, manifest)
			},
			{"text": "CANCEL", "accent": UITheme.PURPLE_MID},
		]
	)


# Resolves a JourneyId collision (or installs straight away when the id is new). Overwrite replaces the
# existing journey's folder (keeping the id); Import as copy installs to a fresh folder with a new id;
# Skip cancels.
func _begin_import(fhj_abs: String, manifest: Dictionary) -> void:
	var collision: Dictionary = JourneyPackage.find_id_collision(
		str(manifest.get("journey_id", "")), _journeys
	)
	# A paid (scripts-only) pack is what a buyer receives — install it edit-locked.
	var lock: bool = str(manifest.get("pack", "full")) == "scripts"
	if collision.is_empty():
		_run_install(fhj_abs, _unique_folder_name(str(manifest.get("name", "journey"))), "", lock)
		return

	_themed_modal(
		"Already Installed",
		(
			'A journey with this ID is already installed ("%s").\n\nOverwrite it, or import as a separate copy?'
			% str(collision.get("title", ""))
		),
		[
			{
				"text": "OVERWRITE",
				"accent": UITheme.PURPLE_BRIGHT,
				"on_press":
				_run_install.bind(fhj_abs, str(collision.get("folder_name", "")), "", lock)
			},
			{
				"text": "IMPORT AS COPY",
				"accent": UITheme.CYAN,
				"on_press": _import_journey_as_copy.bind(fhj_abs, manifest)
			},
			{"text": "SKIP", "accent": UITheme.PURPLE_MID},
		]
	)


# Import-as-copy: a fresh folder + a new JourneyId so the copy is independent of the original. Broken
# out as a method (rather than an inline lambda) so it stays parser- and formatter-safe inside the
# button dict — a multi-line lambda there previously tripped the formatter and corrupted the file.
func _import_journey_as_copy(fhj_abs: String, manifest: Dictionary) -> void:
	_run_install(
		fhj_abs,
		_unique_folder_name(str(manifest.get("name", "journey")) + " copy"),
		JourneyData.new_journey_id(),
		str(manifest.get("pack", "full")) == "scripts"
	)


func _run_install(fhj_abs: String, folder_name: String, new_id: String, lock: bool = false) -> void:
	var progress: Dictionary = _show_progress_overlay("Importing journey…")
	var bar: ProgressBar = progress["bar"]
	var result: Dictionary = await JourneyPackager.install(
		fhj_abs,
		folder_name,
		new_id,
		func(frac: float) -> void: bar.value = frac * 100.0,
		Callable(),
		lock
	)
	(progress["overlay"] as Node).queue_free()
	if bool(result.get("ok", false)):
		# A run-save / scoreboard from a prior journey in this folder (an overwrite) references content
		# that's now gone, so invalidate them — same write-barrier the builder applies on re-save.
		JourneySaveService.delete_save(folder_name)
		ScoreboardService.clear(folder_name)
		_scan_journeys()
		_sort_and_populate()
		_show_message("Journey Imported", "Added to your catalogue.")
	else:
		_show_message("Import Failed", str(result.get("error", "Unknown error.")))


# A journeys-folder name that doesn't collide with an existing folder (appends " 2", " 3", … before
# re-slugging). Used for a fresh import and for import-as-copy.
func _unique_folder_name(base_name: String) -> String:
	var root: String = SettingsService.get_journeys_dir()
	var candidate: String = JourneyData.sanitize_folder_name(base_name)
	if candidate == "":
		candidate = "journey"
	var n: int = 2
	while DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(root + "/" + candidate)):
		candidate = JourneyData.sanitize_folder_name(base_name + " " + str(n))
		if candidate == "":
			candidate = "journey_" + str(n)
		n += 1
	return candidate


# ── Rendition packages ────────────────────────────────────────────────────────


# Import an overlay package: preview it, flag whether its base is installed, then install into a folder
# the scanner groups under that base (or leaves as an orphan until the base arrives).
func _import_rendition_package(fhj_abs: String, manifest: Dictionary) -> void:
	var parent: Dictionary = JourneyPackage.find_id_collision(
		str(manifest.get("parent_id", "")), _journeys
	)
	var parent_note: String = (
		"\n\nFor base: %s" % str(parent.get("title", ""))
		if not parent.is_empty()
		else "\n\n⚠ Its base journey isn't installed — import the base first, or this overlay won't appear until you do."
	)
	var body: String = (
		"%s\nby %s\n\nAn overlay (rendition) that adds content to a base journey.%s"
		% [
			str(manifest.get("name", "Untitled")),
			str(manifest.get("author", "Unknown")),
			parent_note
		]
	)
	if str(manifest.get("pack", "full")) == "scripts":
		body += "\n\nℹ Scripts-only pack — after importing, add its companion video pack to play with video."
	_themed_modal(
		"Import Rendition",
		body,
		[
			{
				"text": "IMPORT",
				"accent": UITheme.PURPLE_BRIGHT,
				"on_press": _run_rendition_install.bind(fhj_abs, manifest)
			},
			{"text": "CANCEL", "accent": UITheme.PURPLE_MID},
		]
	)


func _run_rendition_install(fhj_abs: String, manifest: Dictionary) -> void:
	# Re-importing the same overlay overwrites its folder (matched by its own JourneyId when its base is
	# installed); otherwise it lands in a fresh folder.
	var existing: Dictionary = _find_installed_rendition(str(manifest.get("journey_id", "")))
	var folder: String = (
		str(existing.get("folder_name", ""))
		if not existing.is_empty()
		else _unique_folder_name(str(manifest.get("name", "rendition")))
	)
	# A paid (scripts-only) rendition is a bought overlay — install it edit-locked.
	var lock: bool = str(manifest.get("pack", "full")) == "scripts"
	var progress: Dictionary = _show_progress_overlay("Importing rendition…")
	var bar: ProgressBar = progress["bar"]
	var result: Dictionary = await JourneyPackager.install(
		fhj_abs, folder, "", func(frac: float) -> void: bar.value = frac * 100.0, Callable(), lock
	)
	(progress["overlay"] as Node).queue_free()
	if bool(result.get("ok", false)):
		_scan_journeys()
		_sort_and_populate()
		_show_message(
			"Rendition Imported", "Added — it appears in its base journey's VERSION list."
		)
	else:
		_show_message("Import Failed", str(result.get("error", "Unknown error.")))


# An installed rendition (across every base's grouped list) with this JourneyId, or {}.
func _find_installed_rendition(journey_id: String) -> Dictionary:
	if journey_id == "":
		return {}
	for j: Dictionary in _journeys:
		for r: Variant in j.get("renditions", []):
			if r is Dictionary and str((r as Dictionary).get("journey_id", "")) == journey_id:
				return r
	return {}


# A video pack carries no journey.json — it fills in the footage its scripts pack left out, for ONE
# specific journey. Match strictly on the pack's JourneyId (its "script portion"); it's never offered to
# an unrelated journey. Not installed → tell the user to import the scripts pack first; already complete
# → say so; missing its video → confirm the merge. (A re-imported COPY has a fresh id, so it isn't a
# match — the video belongs to the original id. Overwrite instead of copy if you want the video there.)
func _import_video_pack(fhj_abs: String, manifest: Dictionary) -> void:
	var id: String = str(manifest.get("journey_id", ""))
	var target: Dictionary = JourneyPackage.find_id_collision(id, _journeys)
	if target.is_empty():
		# A rendition's own video pack matches its installed OVERLAY (its id lives under a base's renditions,
		# not in _journeys). Give it a "title" for the merge dialogs, which are written for base journeys.
		var rend: Dictionary = _find_installed_rendition(id)
		if not rend.is_empty():
			target = rend.duplicate()
			if not target.has("title"):
				target["title"] = str(target.get("name", "rendition"))
	if target.is_empty():
		_show_message(
			"No Matching Journey",
			"This video pack belongs to a journey or rendition that isn't installed. Import its scripts pack first, then add this video pack."
		)
		return
	var provides: Array = JourneyPackager.pack_file_names(fhj_abs)
	if provides.is_empty():
		_show_message("Import Failed", "This video pack is empty or couldn't be read.")
		return
	if not _journey_missing_any(target, provides):
		_show_message(
			"Already Complete", '"%s" already has its video.' % str(target.get("title", ""))
		)
		return
	_confirm_video_merge(fhj_abs, target)


# True when `journey`'s folder is missing any of `provides` (rel paths) on disk — i.e. it's waiting for
# a video pack to fill those slots.
func _journey_missing_any(journey: Dictionary, provides: Array) -> bool:
	var folder_abs: String = ProjectSettings.globalize_path(str(journey.get("folder", "")))
	for rel: String in provides:
		if not FileAccess.file_exists(folder_abs.path_join(rel)):
			return true
	return false


func _confirm_video_merge(fhj_abs: String, target: Dictionary) -> void:
	_themed_modal(
		"Add Video to Journey",
		(
			'Add the video for "%s"?\n\nIt fills in the footage its scripts pack left out.'
			% str(target.get("title", ""))
		),
		[
			{
				"text": "ADD VIDEO",
				"accent": UITheme.PURPLE_BRIGHT,
				"on_press": _run_video_merge.bind(fhj_abs, target)
			},
			{"text": "CANCEL", "accent": UITheme.PURPLE_MID},
		]
	)


func _run_video_merge(fhj_abs: String, target: Dictionary) -> void:
	var progress: Dictionary = _show_progress_overlay("Adding video…")
	var bar: ProgressBar = progress["bar"]
	var result: Dictionary = await JourneyPackager.merge_media(
		fhj_abs, str(target.get("folder", "")), func(frac: float) -> void: bar.value = frac * 100.0
	)
	(progress["overlay"] as Node).queue_free()
	if bool(result.get("ok", false)):
		# Additive (video only), so structure is unchanged — no save/scoreboard invalidation needed.
		_scan_journeys()
		_sort_and_populate()
		_show_message(
			"Video Added", 'The video for "%s" is now installed.' % str(target.get("title", ""))
		)
	else:
		_show_message("Import Failed", str(result.get("error", "Unknown error.")))


# ---------------------------------------------------------------------------
# Journey scanning
# ---------------------------------------------------------------------------


# Scanning + journey.json parsing lives in JourneyScanner (RefCounted helper).
func _scan_journeys() -> void:
	_journeys = JourneyScanner.scan_all(SettingsService.get_journeys_dir())


# ---------------------------------------------------------------------------
# Grid population
# ---------------------------------------------------------------------------


func _sort_and_populate() -> void:
	_set_active_sort()
	# Apply search + difficulty filter first, then sort the surviving subset.
	var filtered: Array = _journeys.filter(func(j: Dictionary) -> bool: return _passes_filter(j))
	var asc: bool = _sort_asc
	match _sort_field:
		"name":
			filtered.sort_custom(
				func(a: Dictionary, b: Dictionary) -> bool:
					var cmp: int = (a["title"] as String).naturalnocasecmp_to(b["title"] as String)
					return cmp < 0 if asc else cmp > 0
			)
		"duration":
			filtered.sort_custom(
				func(a: Dictionary, b: Dictionary) -> bool:
					var va: int = a["total_length_ms"]
					var vb: int = b["total_length_ms"]
					return va < vb if asc else va > vb
			)
		"actions":
			filtered.sort_custom(
				func(a: Dictionary, b: Dictionary) -> bool:
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
		_empty_lbl.text = (
			"No journeys match your filter."
			if not _journeys.is_empty()
			else "No journeys yet.\nCreate one in the builder!"
		)
	_empty_lbl.visible = journeys.is_empty()

	# Header count — total catalogue size, or "shown OF total" while filtering.
	if _count_label != null:
		var total: int = _journeys.size()
		var shown: int = journeys.size()
		_count_label.text = (
			("%d JOURNEY%s" % [total, "" if total == 1 else "S"])
			if shown == total
			else "%d OF %d" % [shown, total]
		)

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
	UISound.journey()
	_current_journey = journey
	_populate_modal(journey)
	_open_modal()


# Fades the backdrop in and scales the panel up from 95% with a slight overshoot.
func _open_modal() -> void:
	_modal.visible = true
	_backdrop.modulate.a = 0.0
	_modal_panel.modulate.a = 0.0
	if _scoreboard_panel != null:
		_scoreboard_panel.modulate.a = 0.0
	# Wait one frame so the panel has its final size before computing the pivot.
	await get_tree().process_frame
	_modal_panel.pivot_offset = _modal_panel.size / 2.0
	_modal_panel.scale = Vector2(0.95, 0.95)
	_position_scoreboard_panel()
	var t: Tween = create_tween().set_parallel(true)
	t.tween_property(_backdrop, "modulate:a", 1.0, 0.16)
	t.tween_property(_modal_panel, "modulate:a", 1.0, 0.16)
	t.tween_property(_modal_panel, "scale", Vector2.ONE, 0.18).set_ease(Tween.EASE_OUT).set_trans(
		Tween.TRANS_BACK
	)
	if _scoreboard_panel != null:
		t.tween_property(_scoreboard_panel, "modulate:a", 1.0, 0.16)


# Fades + shrinks the modal out, then hides it and resets the transform.
func _close_modal() -> void:
	if not _modal.visible:
		return
	var t: Tween = create_tween().set_parallel(true)
	t.tween_property(_backdrop, "modulate:a", 0.0, 0.12)
	t.tween_property(_modal_panel, "modulate:a", 0.0, 0.12)
	t.tween_property(_modal_panel, "scale", Vector2(0.96, 0.96), 0.12)
	if _scoreboard_panel != null:
		t.tween_property(_scoreboard_panel, "modulate:a", 0.0, 0.12)
	await t.finished
	_modal.visible = false
	_modal_panel.scale = Vector2.ONE
	_modal_panel.modulate.a = 1.0
	_backdrop.modulate.a = 1.0


# ---------------------------------------------------------------------------
# Detail modal
# ---------------------------------------------------------------------------


func _populate_modal(journey: Dictionary) -> void:
	_modal_title.text = journey.get("title", "Unknown")
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
			tag_row.add_child(
				UITheme.make_tag_chip(TagRegistry.label_of(id), TagRegistry.color_of(id))
			)
		_details_col.add_child(tag_row)
		_details_col.move_child(tag_row, _modal_diff.get_index() + 1)

	_set_modal_desc(str(journey.get("description", "")))

	_set_modal_cover(str(journey.get("cover_path", "")))

	# Stats + the round/fork/shop list — recomputed on VERSION change (base ⊕ rendition when one's picked).
	_update_node_view(journey)

	# Rendition (overlay) version picker — only when this base has installed renditions.
	_refresh_rendition_selector(journey)

	# Reflect the base's lock on the EDIT button (the selector just reset the selection to Base).
	_refresh_edit_lock()

	# Resume vs Play UI. When a save exists for this journey, surface a Resume
	# button as the primary action and recolour Play to make it clear it'll
	# start a fresh run (overwriting the save). When no save exists, the
	# button row is the original Play / Edit / Delete trio.
	_refresh_resume_button(journey)

	# Local scoreboard — ranked past runs for this journey.
	_populate_scoreboard(journey)


const SCORE_MONTHS: Array = [
	"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
]


# Lazily builds the floating scoreboard panel (a styled card with a header and a
# scrollable content column) as a sibling of the modal panel under DetailModal.
func _ensure_scoreboard_panel() -> void:
	if _scoreboard_panel != null:
		return
	_scoreboard_panel = PanelContainer.new()
	_scoreboard_panel.name = "ScoreboardPanel"
	_scoreboard_panel.custom_minimum_size = Vector2(SCOREBOARD_PANEL_W, 0)
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.PANEL_BG
	s.border_color = UITheme.PURPLE_BRIGHT
	s.border_width_left = BORDER_WIDTH
	s.border_width_right = BORDER_WIDTH
	s.border_width_top = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left = 4
	s.corner_radius_top_right = 4
	s.corner_radius_bottom_left = 4
	s.corner_radius_bottom_right = 4
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.content_margin_top = 20
	s.content_margin_bottom = 20
	_scoreboard_panel.add_theme_stylebox_override("panel", s)

	_scoreboard_content = VBoxContainer.new()
	_scoreboard_content.add_theme_constant_override("separation", 6)
	_scoreboard_content.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_scoreboard_panel.add_child(_scoreboard_content)

	_modal.add_child(_scoreboard_panel)


# Rebuilds the floating HIGH SCORES panel from the journey's recorded runs
# (ranked by score). Called each modal open and after the player clears the board.
func _populate_scoreboard(journey: Dictionary) -> void:
	_ensure_scoreboard_panel()
	for child in _scoreboard_content.get_children():
		child.queue_free()

	var folder: String = journey.get("folder_name", "")
	var runs: Array = ScoreboardService.read_runs(folder)

	# Header: title + a Clear button (only when there's something to clear).
	var hdr: HBoxContainer = HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 8)
	var title: Label = Label.new()
	title.text = "HIGH SCORES"
	title.uppercase = true
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	title.add_theme_font_size_override("font_size", 13)
	hdr.add_child(title)
	if not runs.is_empty():
		var clear_btn: Button = Button.new()
		clear_btn.text = "CLEAR"
		clear_btn.focus_mode = Control.FOCUS_NONE
		clear_btn.add_theme_font_size_override("font_size", 10)
		clear_btn.add_theme_color_override("font_color", UITheme.DANGER)
		clear_btn.flat = true
		clear_btn.pressed.connect(_on_clear_scores_pressed)
		hdr.add_child(clear_btn)
	_scoreboard_content.add_child(hdr)

	var hdr_line: HSeparator = HSeparator.new()
	_scoreboard_content.add_child(hdr_line)

	if runs.is_empty():
		var empty: Label = Label.new()
		empty.text = "No runs yet — play it!"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", UITheme.PURPLE_MID)
		empty.add_theme_font_size_override("font_size", 11)
		_scoreboard_content.add_child(empty)
	else:
		for i in runs.size():
			_scoreboard_content.add_child(_make_score_row(i + 1, runs[i]))


# Places the scoreboard panel against the modal panel's right edge, matching its
# height. Driven by the modal panel's item_rect_changed (so it tracks every
# layout/centre pass), plus viewport resize and the initial open.
func _position_scoreboard_panel() -> void:
	if _scoreboard_panel == null or not _modal.visible:
		return
	_scoreboard_panel.custom_minimum_size = Vector2(SCOREBOARD_PANEL_W, _modal_panel.size.y)
	_scoreboard_panel.size = Vector2(SCOREBOARD_PANEL_W, _modal_panel.size.y)
	_scoreboard_panel.position = (
		_modal_panel.position + Vector2(_modal_panel.size.x + SCOREBOARD_PANEL_GAP, 0.0)
	)


# One ranked run row: rank · score · outcome badge · date.
func _make_score_row(rank: int, run: Dictionary) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var rank_lbl: Label = Label.new()
	rank_lbl.text = "%d." % rank
	rank_lbl.custom_minimum_size = Vector2(22, 0)
	rank_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	rank_lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(rank_lbl)

	var score_lbl: Label = Label.new()
	score_lbl.text = _format_score(int(run.get("score", 0)))
	score_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	score_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	score_lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(score_lbl)

	var outcome_lbl: Label = Label.new()
	if bool(run.get("completed", false)):
		outcome_lbl.text = "✓ COMPLETE"
		outcome_lbl.add_theme_color_override("font_color", UITheme.SUCCESS)
	else:
		outcome_lbl.text = (
			"✗ ROUND %d/%d" % [int(run.get("rounds_done", 0)), int(run.get("rounds_total", 0))]
		)
		outcome_lbl.add_theme_color_override("font_color", UITheme.ERROR_SOFT)
	outcome_lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(outcome_lbl)

	var date_lbl: Label = Label.new()
	date_lbl.text = _format_short_date(str(run.get("date", "")))
	date_lbl.custom_minimum_size = Vector2(56, 0)
	date_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	date_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	date_lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(date_lbl)

	return row


# Thousands-separated score, e.g. 14200 → "14,200".
func _format_score(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	out = s + out
	return ("-" + out) if n < 0 else out


# ISO datetime ("2026-06-12T14:30:25") → "Jun 12". Falls back to the raw date
# portion if parsing fails.
func _format_short_date(iso: String) -> String:
	if iso.is_empty():
		return ""
	var dt: Dictionary = Time.get_datetime_dict_from_datetime_string(iso, false)
	var month: int = int(dt.get("month", 0))
	var day: int = int(dt.get("day", 0))
	if month >= 1 and month <= 12 and day >= 1:
		return "%s %d" % [SCORE_MONTHS[month - 1], day]
	return iso.split("T")[0]


# Confirms, then wipes the current journey's recorded runs and refreshes the
# section in place.
func _on_clear_scores_pressed() -> void:
	if _current_journey.is_empty():
		return
	var title: String = _current_journey.get("title", "this journey")
	var dialog: ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Clear Run History"
	dialog.dialog_text = 'Clear all recorded runs for "%s"?\n\nThis cannot be undone.' % title
	dialog.ok_button_text = "CLEAR"
	dialog.get_ok_button().add_theme_color_override("font_color", UITheme.DANGER)
	dialog.confirmed.connect(
		func() -> void:
			ScoreboardService.clear(_current_journey.get("folder_name", ""))
			_populate_scoreboard(_current_journey)
			dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


# Builds a "VERSION" dropdown (Base + each installed rendition) in the detail column when this journey
# has renditions, and clears the current selection. Removes any prior row first (idempotent per modal).
# Fills the stats row + the round/fork/shop/storyboard list for `journey`. Split out of _populate_modal
# so the VERSION picker can recompute it for a composed base⊕rendition without rebuilding the whole modal.
func _update_node_view(journey: Dictionary) -> void:
	var rounds: Array = journey.get("rounds", [])
	var total_rounds: int = journey.get("total_rounds", rounds.size())
	_stat_rounds.text = str(total_rounds) + " ROUNDS"
	_stat_actions.text = str(journey.get("total_actions", 0)) + " ACTIONS"
	var total_secs: int = (journey.get("total_length_ms", 0) as int) / 1000
	_stat_length.text = "~" + _format_duration(total_secs)  # expected runtime — an estimate

	for child in _round_list.get_children():
		child.queue_free()

	var hdr: HBoxContainer = HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 12)
	_round_list.add_child(hdr)
	for col in [
		["", 36, false],
		["ROUND", -1, false],
		["DURATION", 56, true],
		["ACTIONS", 72, true],
		["COINS", 72, true]
	]:
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

	_add_seq_to_list(
		_round_list,
		rounds,
		journey.get("shops", []),
		journey.get("storyboards", []),
		journey.get("forks", []),
		0
	)


# Recomputes the node view for the current VERSION selection: the composed base⊕rendition when a
# rendition is picked (via compose_play_journey, which rebuilds the catalogue lists), else the base.
# The ordered rendition folders to compose for the current VERSION selection (the selected rendition's full
# ancestor chain, base-ward). Empty when Base is selected. Falls back to [folder] for older summaries.
func _selected_chain() -> Array:
	if _selected_rendition.is_empty():
		return []
	var chain: Array = _selected_rendition.get("chain_folders", [])
	if not chain.is_empty():
		return chain
	var f: String = str(_selected_rendition.get("folder", ""))
	return [f] if f != "" else []


# Sets the detail-modal cover image from a cover_path (blank / unreadable → no cover).
func _set_modal_cover(cover_path: String) -> void:
	var img: Image = JourneyData.load_image_smart(cover_path)
	_cover_img.texture = ImageTexture.create_from_image(img) if img else null


# Sets the detail-modal description, hiding the label when empty. Shared by the initial populate and the
# VERSION swap (a rendition shows its own description, falling back to the base's).
func _set_modal_desc(desc: String) -> void:
	_modal_desc.text = desc
	_modal_desc.visible = desc != ""


# The soft edit-lock state of whatever's selected — the rendition when one's picked in VERSION, else the
# base journey. Drives the EDIT and EXPORT gates (both target the same selection).
func _selection_locked() -> bool:
	return (
		bool(_selected_rendition.get("locked", false))
		if not _selected_rendition.is_empty()
		else bool(_current_journey.get("locked", false))
	)


# When editing a rendition that stacks on other renditions, ghost the composed base + ancestor chain in the
# builder (via rendition_over) so its anchors resolve and its ParentId is preserved on save. Returns false
# (and explains why) if the ancestor chain won't compose. A rendition anchored straight to the base composes
# nothing and returns true — the builder's base-only ghost path handles it.
func _setup_rendition_ancestors_for_edit() -> bool:
	var chain: Array = _selected_chain()  # [..ancestors.., self]
	if chain.size() <= 1:
		JourneyBuilder.rendition_over = {}  # parent is the base — nothing to compose
		return true
	var ancestors: Array = chain.slice(0, chain.size() - 1)
	var composed: Dictionary = JourneyScanner.compose_play_journey(
		str(_current_journey.get("folder", "")),
		str(_current_journey.get("folder_name", "")),
		ancestors
	)
	if composed.is_empty() or not (composed.get("compose_errors", []) as Array).is_empty():
		_show_message(
			"Can't Edit That",
			"This rendition builds on another rendition that didn't compose cleanly. Fix the parent rendition first."
		)
		return false
	var parent_id: String = str(_selected_rendition.get("parent_id", ""))
	JourneyBuilder.rendition_over = {
		"start": composed.get("start", ""),
		"nodes": composed.get("nodes", {}),
		"parent_id": parent_id,
		"parent_name": _rendition_name_by_id(parent_id),
	}
	return true


# The display name of an installed rendition of the current base, by its JourneyId (for the overlay banner).
func _rendition_name_by_id(journey_id: String) -> String:
	for r: Dictionary in _current_journey.get("renditions", []):
		if str(r.get("journey_id", "")) == journey_id:
			return str(r.get("name", "a rendition"))
	return "a rendition"


# Reflect the soft edit-lock on the EDIT button for whatever's selected (base or a rendition): swap in a
# 🔒 label + hover cue. Left clickable — the click explains why (see _show_locked_message).
func _refresh_edit_lock() -> void:
	var locked: bool = _selection_locked()
	_edit_btn.text = "🔒 LOCKED" if locked else _edit_btn_base_text
	_edit_btn.tooltip_text = "🔒 Installed from a paid pack — locked for editing" if locked else ""


func _update_node_view_for_selection() -> void:
	_refresh_edit_lock()  # base vs the selected rendition may differ in lock state
	_refresh_rend_resume_button()  # a Part-1 carryover may continue into the newly selected rendition
	# Show the selected rendition's OWN cover + description when it has them, else fall back to the base's.
	var base_cover: String = str(_current_journey.get("cover_path", ""))
	var base_desc: String = str(_current_journey.get("description", ""))
	if _selected_rendition.is_empty():
		_set_modal_cover(base_cover)
		_set_modal_desc(base_desc)
		_update_node_view(_current_journey)
		return
	var rend_cover: String = str(_selected_rendition.get("cover_path", ""))
	var rend_desc: String = str(_selected_rendition.get("description", ""))
	_set_modal_cover(rend_cover if rend_cover != "" else base_cover)
	_set_modal_desc(rend_desc if rend_desc != "" else base_desc)
	var composed: Dictionary = JourneyScanner.compose_play_journey(
		str(_current_journey.get("folder", "")),
		str(_current_journey.get("folder_name", "")),
		_selected_chain()
	)
	_update_node_view(composed if not composed.is_empty() else _current_journey)


func _refresh_rendition_selector(journey: Dictionary) -> void:
	_selected_rendition = {}
	_rend_delete_btn = null
	_refresh_rend_resume_button()  # drop any stale Part-2 button from the previously shown journey
	var old: Node = _details_col.get_node_or_null("RenditionRow")
	if old:
		old.free()
	var rends: Array = journey.get("renditions", [])
	if rends.is_empty():
		_rendition_select = null
		return

	var row: HBoxContainer = HBoxContainer.new()
	row.name = "RenditionRow"
	row.add_theme_constant_override("separation", 8)
	var lbl: Label = Label.new()
	_style_label(lbl, UITheme.SEPARATOR, 11, true)
	lbl.text = "VERSION"
	row.add_child(lbl)

	# For chained (sibling-dependency) renditions, label which ancestor a rendition stacks on so the
	# dependency is legible — selecting it composes that ancestor too.
	var name_by_id: Dictionary = {}
	for rr: Dictionary in rends:
		name_by_id[str(rr.get("journey_id", ""))] = str(rr.get("name", "Rendition"))
	_rendition_select = OptionButton.new()
	_rendition_select.add_item("Base", 0)
	for i in rends.size():
		var r: Dictionary = rends[i]
		var label: String = str(r.get("name", "Rendition"))
		var pid: String = str(r.get("parent_id", ""))
		if name_by_id.has(pid):  # parent is another rendition → show the stack
			label += "  — on %s" % str(name_by_id[pid])
		_rendition_select.add_item(label, i + 1)
	_rendition_select.selected = 0
	# Signal-connect lambda (not a dict value) — safe. Index 0 = base; otherwise the rendition summary.
	_rendition_select.item_selected.connect(
		func(idx: int) -> void:
			_selected_rendition = {} if idx == 0 else (rends[idx - 1] as Dictionary)
			if _rend_delete_btn != null:
				_rend_delete_btn.visible = idx != 0
			_update_node_view_for_selection()
	)
	row.add_child(_rendition_select)

	# Delete the selected rendition (base journeys are untouched). Hidden while "Base" is selected.
	var del_btn: Button = Button.new()
	del_btn.text = "🗑"
	del_btn.tooltip_text = "Delete this rendition"
	_style_button(del_btn, UITheme.MAGENTA)
	del_btn.visible = false
	del_btn.pressed.connect(_confirm_delete_rendition)
	row.add_child(del_btn)
	_rend_delete_btn = del_btn

	_details_col.add_child(row)
	_details_col.move_child(row, _modal_diff.get_index() + 1)


# Creates or removes the Resume button based on whether the current journey
# has a save. Idempotent — safe to call every time the modal opens.
func _refresh_resume_button(journey: Dictionary) -> void:
	var folder_name: String = journey.get("folder_name", "")
	var has_save: bool = JourneySaveService.has_save(folder_name)

	if has_save:
		if _resume_btn == null:
			_resume_btn = Button.new()
			_resume_btn.text = "▶  RESUME"
			_style_button(_resume_btn, UITheme.AMBER)
			_resume_btn.pressed.connect(_on_resume_pressed)
			var action_row: HBoxContainer = _play_btn.get_parent()
			action_row.add_child(_resume_btn)
			action_row.move_child(_resume_btn, _play_btn.get_index())
			# Resume plays start_journey at the embark point; mute its default click
			# (after add_child, which is where the global wiring hooks it).
			UISound.mute_button(_resume_btn)
		_play_btn.text = "↻  NEW RUN"
		_style_button(_play_btn, UITheme.PURPLE_MID)
	else:
		if _resume_btn != null:
			_resume_btn.queue_free()
			_resume_btn = null
		_play_btn.text = "▶  PLAY"
		_style_button(_play_btn, UITheme.PURPLE_BRIGHT)


# Loads the save file for the current journey, restores game state into the
# autoload services, and transitions to the gameplay scene. Bypasses the
# normal StartJourney path so the saved sequence (including any fork choices
# already made) is preserved.
#
# Saves are single-use by design: the file is deleted as part of the resume
# so the player has to actively earn a new save point (reach a checkpoint
# round or use The Safe Word) before they can quit-and-resume again. This
# keeps the save model thematically consistent — checkpoints are recoveries
# you commit to, not safety nets you indefinitely fall back on.
func _on_resume_pressed() -> void:
	if _current_journey.is_empty():
		return
	if not _bypass_version_gate and not _app_supports_current():
		_warn_version_then(_on_resume_pressed)
		return
	_bypass_version_gate = false
	var folder_name: String = _current_journey.get("folder_name", "")
	var save_data: Dictionary = JourneySaveService.read_save(folder_name)
	if save_data.is_empty():
		# Save vanished between modal open and Resume click (deleted in another
		# window?). Fall back to a fresh start so the user isn't stuck.
		push_warning("JourneySelect: save missing or unreadable — starting fresh")
		_on_play_pressed_unguarded()
		return

	# The runtime walks the journey GRAPH (parse_graph migrates legacy journeys on the
	# fly); _current_journey stays the catalogue model for the detail panel.
	var play_journey: Dictionary = JourneyScanner.parse_graph(
		_current_journey.get("folder", ""), _current_journey.get("folder_name", "")
	)
	GameState.LoadFromSave(play_journey, save_data)
	CoinService.SetBalance(int(save_data.get("coins", 0)))
	(
		ScoreService
		. LoadFromSave(
			{
				"score": save_data.get("score", 0),
				"strokes": save_data.get("total_actions", 0),
			}
		)
	)
	# Inventory restoration — owned items only. Active effects are not
	# carried (deliberate; see InventoryService.LoadFromSave). Old saves
	# missing the field load as empty, which is the right pre-feature default.
	InventoryService.LoadFromSave(save_data.get("inventory", []) as Array)
	# Restore the round-names log so the end-screen breakdown is complete.
	var names: PackedStringArray = PackedStringArray()
	for n in save_data.get("round_names", []) as Array:
		names.append(str(n))
	GameState.set_meta("_round_names", names)
	# Restore the route trail so the end-screen route recap spans the whole
	# run, not just the resumed half (old saves load as an empty trail).
	var trail: Array = []
	for t in save_data.get("route_trail", []) as Array:
		trail.append(str(t))
	GameState.set_meta("_route_trail", trail)

	# Consume the save NOW (before the transition). If the player quits at any
	# point in the resumed run without writing a fresh save, the journey is
	# back to fresh-start state in the catalogue.
	JourneySaveService.delete_save(folder_name)

	# Handshake with GameLoop._ready — without this, GameLoop would treat
	# the scene change as a fresh start and Reset() each service, wiping
	# all the state we just restored from the save record.
	GameState.set_meta("_resuming", true)
	UISound.start_journey()
	Transition.change_scene("res://scenes/game_loop/GameLoop.tscn")


# Internal: starts a fresh journey without any save-overwrite check. Used by
# both the new-run path (after the user confirms overwrite) and the fallback
# path when a save is unreadable.
func _on_play_pressed_unguarded() -> void:
	var play_journey: Dictionary
	if _selected_rendition.is_empty():
		JourneySaveService.delete_save(_current_journey.get("folder_name", ""))
		play_journey = JourneyScanner.parse_graph(
			_current_journey.get("folder", ""), _current_journey.get("folder_name", "")
		)
	else:
		play_journey = _prepare_rendition_run()
		if play_journey.is_empty():
			return  # load/compose error already surfaced
	GameState.StartJourney(play_journey)
	UISound.start_journey()
	Transition.change_scene("res://scenes/game_loop/GameLoop.tscn")


# Confirm-then-delete the selected rendition. The base journey is untouched.
func _confirm_delete_rendition() -> void:
	if _selected_rendition.is_empty():
		return
	var name: String = str(_selected_rendition.get("name", "this rendition"))
	_themed_modal(
		"Delete Rendition",
		(
			'Delete the rendition "%s"?\n\nIt and its saved progress are removed. The base journey is untouched. This can\'t be undone.'
			% name
		),
		[
			{"text": "DELETE", "accent": UITheme.MAGENTA, "on_press": _do_delete_rendition},
			{"text": "CANCEL", "accent": UITheme.PURPLE_MID},
		]
	)


func _do_delete_rendition() -> void:
	if _selected_rendition.is_empty():
		return
	var rend: Dictionary = _selected_rendition
	var folder: String = str(rend.get("folder", ""))
	if folder != "":
		JourneyData.delete_dir_recursive(folder)
	# Clean the composed run's isolated save/scoreboard, keyed "<base>__rend_<rendition>".
	var folder_name: String = str(rend.get("folder_name", ""))
	if folder_name != "":
		var run_key: String = JourneyData.sanitize_folder_name(
			str(_current_journey.get("folder_name", "")) + "__rend_" + folder_name
		)
		JourneySaveService.delete_save(run_key)
		ScoreboardService.clear(run_key)
	# Rescan, then keep the detail modal open by re-finding the base and rebuilding its VERSION list.
	var base_id: String = str(_current_journey.get("journey_id", ""))
	_selected_rendition = {}
	_scan_journeys()
	_sort_and_populate()
	for j: Dictionary in _journeys:
		if str(j.get("journey_id", "")) == base_id:
			_current_journey = j
			_refresh_rendition_selector(j)
			_update_node_view_for_selection()
			break
	_show_message("Rendition Deleted", 'Removed "%s".' % str(rend.get("name", "")))


# Feature #5: the composed entry node a Part-1 carryover resumes INTO for the currently selected rendition,
# or "" when there's no rendition selected, no carryover for the base, or this rendition doesn't extend the
# ending the player reached (precise match — see JourneyRendition.resume_entry).
func _rendition_resume_entry() -> String:
	if _selected_rendition.is_empty():
		return ""
	var base_id: String = str(_current_journey.get("journey_id", ""))
	if base_id == "":
		return ""
	var carry: Dictionary = JourneySaveService.read_carryover(base_id)
	if carry.is_empty():
		return ""
	var delta: Dictionary = JourneyScanner.load_rendition_delta(
		str(_selected_rendition.get("folder", ""))
	)
	return JourneyRendition.resume_entry(
		delta.get("anchors", []), str(carry.get("reached_node", ""))
	)


# Adds/removes the "RESUME PART 2" button to match the VERSION selection. Called whenever the selection
# changes (base ↔ a rendition), so the button only shows when a Part-1 carryover actually continues into
# the selected rendition.
func _refresh_rend_resume_button() -> void:
	var can_resume: bool = _rendition_resume_entry() != ""
	if can_resume:
		if _rend_resume_btn == null:
			_rend_resume_btn = Button.new()
			_rend_resume_btn.text = "▶  RESUME PART 2"
			_style_button(_rend_resume_btn, UITheme.CYAN)
			_rend_resume_btn.pressed.connect(_on_rend_resume_pressed)
			var action_row: HBoxContainer = _play_btn.get_parent()
			action_row.add_child(_rend_resume_btn)
			action_row.move_child(_rend_resume_btn, _play_btn.get_index())
			UISound.mute_button(_rend_resume_btn)
	elif _rend_resume_btn != null:
		_rend_resume_btn.queue_free()
		_rend_resume_btn = null


# Feature #5: start the selected rendition seeded with the base's Part-1 carryover, jumping straight to the
# rendition's attach point (the sequel's entry) so Part 1 isn't replayed. Coins / score / items / flags /
# counters carry over. The carryover is consumed when the Part-2 run COMPLETES (see GameLoop), so bailing
# out early lets you retry from Part 1, but finishing the sequel retires "Resume Part 2".
func _on_rend_resume_pressed() -> void:
	if not _bypass_version_gate and not _app_supports_current():
		_warn_version_then(_on_rend_resume_pressed)
		return
	_bypass_version_gate = false
	var entry: String = _rendition_resume_entry()
	var base_id: String = str(_current_journey.get("journey_id", ""))
	var carry: Dictionary = JourneySaveService.read_carryover(base_id)
	if entry == "" or carry.is_empty():
		return  # carryover vanished or the rendition changed between open and click
	var play_journey: Dictionary = _prepare_rendition_run()  # composes + isolates the run's save folder
	if play_journey.is_empty():
		return  # compose error already surfaced
	# Resume position = the sequel's attach point, not Part 1's ending.
	carry["current_node"] = entry
	GameState.LoadFromSave(play_journey, carry)  # restores flags / counters / position into the composed graph
	CoinService.SetBalance(int(carry.get("coins", 0)))
	ScoreService.LoadFromSave(
		{"score": carry.get("score", 0), "strokes": carry.get("total_actions", 0)}
	)
	InventoryService.LoadFromSave(carry.get("inventory", []) as Array)
	GameState.set_meta("_resuming", true)  # handshake: GameLoop keeps the seeded state instead of Reset()
	UISound.start_journey()
	Transition.change_scene("res://scenes/game_loop/GameLoop.tscn")


# Composes the selected rendition onto its base into a play-ready journey, isolated from the base's
# save/scoreboard by a distinct folder_name key. Returns {} (after showing a message) when the base or
# rendition can't load, or the overlay doesn't fit the installed base (break-loudly).
func _prepare_rendition_run() -> Dictionary:
	var play_journey: Dictionary = JourneyScanner.compose_play_journey(
		_current_journey.get("folder", ""),
		_current_journey.get("folder_name", ""),
		_selected_chain()
	)
	if play_journey.is_empty():
		_show_message("Couldn't Load", "Failed to load the rendition or its base journey.")
		return {}
	var errors: Array = play_journey.get("compose_errors", [])
	if not errors.is_empty():
		_show_message("Rendition Doesn't Fit", _compose_error_summary(errors))
		return {}
	# Isolate this run's save + scoreboard from the base (both key off folder_name), and label it.
	var run_key: String = JourneyData.sanitize_folder_name(
		(
			str(_current_journey.get("folder_name", ""))
			+ "__rend_"
			+ str(_selected_rendition.get("folder_name", ""))
		)
	)
	play_journey["folder_name"] = run_key
	play_journey["title"] = (
		str(play_journey.get("title", "")) + " — " + str(_selected_rendition.get("name", ""))
	)
	JourneySaveService.delete_save(run_key)
	return play_journey


# Human summary of compose break-loudly errors — the overlay references base content that's gone or
# conflicts, usually because the installed base changed since the rendition was authored.
func _compose_error_summary(errors: Array) -> String:
	var kinds: Array = []
	for e: Dictionary in errors:
		kinds.append(str(e.get("kind", "?")))
	return (
		"This add-on doesn't fit the installed base — the base may have changed since the add-on was made.\n\nIssues: %s"
		% ", ".join(kinds)
	)


# ---------------------------------------------------------------------------
# Recursive sequence renderer
# ---------------------------------------------------------------------------

# Builds and inserts interleaved rows for rounds/shops/storyboards/forks into
# `list`. `indent` is the nesting depth (0 = top level); each level adds
# INDENT_PX pixels of left margin via a MarginContainer wrapper.
const INDENT_PX: int = 16


func _add_seq_to_list(
	list: VBoxContainer, rounds: Array, shops: Array, storyboards: Array, forks: Array, indent: int
) -> void:
	var seq: Array = []
	for rd: Dictionary in rounds:
		seq.append({"type": "round", "data": rd, "key": (rd.get("order", 0) as int) * 3})
	for sb: Dictionary in storyboards:
		seq.append({"type": "storyboard", "data": sb, "key": (sb.get("order", 0) as int) * 3})
	for sh: Dictionary in shops:
		seq.append({"type": "shop", "data": sh, "key": (sh.get("after_order", 0) as int) * 3 + 1})
	for fk: Dictionary in forks:
		seq.append({"type": "fork", "data": fk, "key": (fk.get("after_order", 0) as int) * 3 + 2})
	seq.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return (a["key"] as int) < (b["key"] as int)
	)

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
				var storyboard_data: Dictionary = item["data"]
				var sb_row: HBoxContainer = HBoxContainer.new()
				sb_row.add_theme_constant_override("separation", 8)
				var sb_lbl: Label = Label.new()
				var sb_line_count: int = (storyboard_data.get("lines", []) as Array).size()
				sb_lbl.text = (
					"  ◈  STORYBOARD  (%d LINE%s)"
					% [sb_line_count, "S" if sb_line_count != 1 else ""]
				)
				sb_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				sb_lbl.add_theme_color_override("font_color", Color(0.10, 0.85, 0.90, 1.0))
				sb_lbl.add_theme_font_size_override("font_size", 11)
				sb_row.add_child(sb_lbl)
				var sb_coins: int = storyboard_data.get("coins", 0)
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
				name_lbl.add_theme_color_override(
					"font_color", UITheme.DANGER if is_boss else UITheme.WHITE_SOFT
				)
				name_lbl.add_theme_font_size_override("font_size", 13)
				row.add_child(name_lbl)
				var is_pool: bool = str(round_data.get("round_type", "normal")) == "pool"
				var dur_secs: int = (round_data.get("length_ms", 0) as int) / 1000
				var dur_lbl: Label = Label.new()
				# A pool's duration is the weighted-average of its entries — mark it as an estimate.
				dur_lbl.text = ("~" if is_pool else "") + _format_duration(dur_secs)
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
			path.get("rounds", []),
			path.get("shops", []),
			path.get("storyboards", []),
			path.get("forks", []),
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
