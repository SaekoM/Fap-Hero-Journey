extends Control

# ---------------------------------------------------------------------------
# JourneySelect.gd
# Purple matrix theme. Scrollable catalogue grid of journey cards. Clicking
# a card opens a detail modal with stats parsed from journey.json and
# funscript files found in user://journeys/<folder>/<round-name>/.
# ---------------------------------------------------------------------------

const COLOR_BG:            Color = Color(0.0,   0.0,   0.0,   1.0)
const COLOR_PANEL_BG:      Color = Color(0.055, 0.008, 0.086, 1.0)
const COLOR_PURPLE_DARK:   Color = Color(0.176, 0.024, 0.259, 1.0)
const COLOR_PURPLE_MID:    Color = Color(0.408, 0.063, 0.627, 1.0)
const COLOR_PURPLE_BRIGHT: Color = Color(0.698, 0.118, 1.0,   1.0)
const COLOR_MAGENTA:       Color = Color(0.878, 0.0,   0.878, 1.0)
const COLOR_WHITE_SOFT:    Color = Color(0.878, 0.780, 1.0,   1.0)
const COLOR_SEPARATOR:     Color = Color(0.698, 0.118, 1.0,   0.5)
const COLOR_DANGER:        Color = Color(0.9,   0.15,  0.15,  1.0)

const TOP_BAR_HEIGHT:   int = 64
const GRID_TOP_MARGIN:  int = 16
const GRID_PADDING:     int = 40
const GRID_SEPARATION:  int = 24
const CARD_MIN_WIDTH:   int = 280
const MODAL_MIN_WIDTH:  int = 980
const MODAL_MIN_HEIGHT: int = 600
const MODAL_COVER_W:    int = 280
const BORDER_WIDTH:     int = 3

const JOURNEYS_DIR: String = "user://journeys"

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


func _ready() -> void:
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
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_top_bar.add_theme_constant_override("separation", 0)

	_scroll.anchor_right  = 1.0
	_scroll.anchor_bottom = 1.0
	_scroll.offset_top    = TOP_BAR_HEIGHT + GRID_TOP_MARGIN
	_scroll.offset_left   = GRID_PADDING
	_scroll.offset_right  = -GRID_PADDING
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_grid.add_theme_constant_override("h_separation", GRID_SEPARATION)
	_grid.add_theme_constant_override("v_separation", GRID_SEPARATION)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

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


func _update_grid_columns() -> void:
	var available: float = _scroll.size.x
	if available <= 0:
		return
	var cols: int = max(1, int((available + GRID_SEPARATION) / (CARD_MIN_WIDTH + GRID_SEPARATION)))
	_grid.columns = cols


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = COLOR_BG

	# TopBar background via a Panel behind the HBoxContainer would need an extra
	# node; instead we apply a dark strip by styling the scroll container top offset.
	_style_label(_title_lbl,  COLOR_PURPLE_BRIGHT, 18, true)
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER

	_style_label(_sort_lbl,   COLOR_PURPLE_MID,    13, true)
	_style_label(_empty_lbl,  COLOR_PURPLE_MID,    15, true)
	_empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_empty_lbl.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART

	_style_button(_back_btn,      COLOR_MAGENTA)
	_style_button(_sort_name,     COLOR_PURPLE_BRIGHT)
	_style_button(_sort_duration, COLOR_PURPLE_MID)
	_style_button(_sort_actions,  COLOR_PURPLE_MID)
	_style_button(_play_btn,      COLOR_PURPLE_BRIGHT)
	_style_button(_edit_btn,      COLOR_PURPLE_MID)
	_style_button(_delete_btn,    COLOR_DANGER)

	_style_modal_panel()

	_style_label(_modal_title,  COLOR_PURPLE_BRIGHT, 22, true)
	_style_label(_modal_author, COLOR_PURPLE_MID,    13, false)
	_style_label(_modal_diff,   COLOR_MAGENTA,       15, true)
	_style_label(_modal_desc,   COLOR_WHITE_SOFT,    12, false)
	_modal_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_style_label(_stat_rounds,  COLOR_WHITE_SOFT, 13, true)
	_style_label(_stat_actions, COLOR_WHITE_SOFT, 13, true)
	_style_label(_stat_length,  COLOR_WHITE_SOFT, 13, true)

	_style_label(_rounds_hdr, COLOR_SEPARATOR, 11, true)

	var sep_style: StyleBoxFlat = StyleBoxFlat.new()
	sep_style.bg_color = COLOR_SEPARATOR
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
	s.bg_color = COLOR_PANEL_BG
	s.border_color        = COLOR_PURPLE_BRIGHT
	s.border_width_left   = BORDER_WIDTH
	s.border_width_right  = BORDER_WIDTH
	s.border_width_top    = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left     = 4
	s.corner_radius_top_right    = 4
	s.corner_radius_bottom_left  = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color = Color(COLOR_MAGENTA.r, COLOR_MAGENTA.g, COLOR_MAGENTA.b, 0.5)
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
	btn.add_theme_color_override("font_hover_color",   COLOR_WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", COLOR_BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.text = btn.text.to_upper()
	btn.add_theme_stylebox_override("normal",  _make_btn_style(accent, COLOR_PURPLE_DARK))
	btn.add_theme_stylebox_override("hover",   _make_btn_style(accent, COLOR_PURPLE_MID))
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
	_style_button(_sort_name,     COLOR_PURPLE_BRIGHT if _sort_field == "name"     else COLOR_PURPLE_MID)
	_style_button(_sort_duration, COLOR_PURPLE_BRIGHT if _sort_field == "duration" else COLOR_PURPLE_MID)
	_style_button(_sort_actions,  COLOR_PURPLE_BRIGHT if _sort_field == "actions"  else COLOR_PURPLE_MID)
	_sort_name.text     = ("NAME"     + arrow) if _sort_field == "name"     else "NAME"
	_sort_duration.text = ("DURATION" + arrow) if _sort_field == "duration" else "DURATION"
	_sort_actions.text  = ("ACTIONS"  + arrow) if _sort_field == "actions"  else "ACTIONS"


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _modal.visible:
		_modal.visible = false
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
			_modal.visible = false


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
	dialog.get_ok_button().add_theme_color_override("font_color", COLOR_DANGER)
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
		_delete_directory_recursive(folder)
	_journeys.erase(_current_journey)
	_current_journey = {}
	_modal.visible = false
	_sort_and_populate()


func _delete_directory_recursive(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		var child: String = path + "/" + fname
		if dir.current_is_dir():
			_delete_directory_recursive(child)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child))
		fname = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

# ---------------------------------------------------------------------------
# Journey scanning
# ---------------------------------------------------------------------------

func _scan_journeys() -> void:
	_journeys.clear()
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(JOURNEYS_DIR)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(JOURNEYS_DIR))
		return
	var dir: DirAccess = DirAccess.open(JOURNEYS_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			var journey: Dictionary = _parse_journey(JOURNEYS_DIR + "/" + entry, entry)
			if not journey.is_empty():
				_journeys.append(journey)
		entry = dir.get_next()
	dir.list_dir_end()


func _parse_journey(path: String, folder: String) -> Dictionary:
	var json_path: String = path + "/journey.json"
	if not FileAccess.file_exists(json_path):
		return {}
	var file: FileAccess = FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		return {}
	var parser: JSON = JSON.new()
	var err: int = parser.parse(file.get_as_text())
	file.close()
	if err != OK:
		return {}
	var data: Dictionary = parser.data

	var journey: Dictionary = {
		"folder":          path,
		"folder_name":     folder,
		"title":           data.get("Name", folder),
		"description":     data.get("Description", ""),
		"difficulty":      data.get("Difficulty", "Unknown"),
		"author":          data.get("Author", "Unknown"),
		"rounds":          [],
		"forks":           [],
		"shops":           [],
		"cover_path":      "",
		"total_actions":   0,
		"total_length_ms": 0,
		"modified_time":   FileAccess.get_modified_time(json_path),
	}

	var raw_shops: Array = data.get("Shops", [])
	for raw_shop in raw_shops:
		if raw_shop is Dictionary:
			journey["shops"].append({
				"after_order": raw_shop.get("AfterOrder", raw_shop.get("after_order", 0)),
				"title":       raw_shop.get("Title",       raw_shop.get("title",       "")),
			})
		else:
			# Legacy format: bare int order number.
			journey["shops"].append({"after_order": int(raw_shop), "title": ""})

	journey["cover_path"] = _find_cover_image(path)

	var raw_rounds: Array = data.get("Rounds", [])
	# Filter out any legacy Shop-type rounds — shops are now declared via "Shops": [...]
	raw_rounds = raw_rounds.filter(func(r: Dictionary) -> bool:
		return r.get("RoundType", "Normal") != "Shop"
	)
	raw_rounds.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a.get("Order", 0) as int) < (b.get("Order", 0) as int)
	)

	for raw: Dictionary in raw_rounds:
		var round_name: String   = raw.get("Name", "Round")
		var round_folder: String = path + "/" + round_name
		var fs: Dictionary       = _read_funscript_stats(round_folder)
		var round_data: Dictionary = {
			"name":           round_name,
			"folder":         round_folder,
			"funscript_path": fs["path"],
			"coins":          raw.get("CoinsAwarded", 0),
			"order":          raw.get("Order", 0),
			"action_count":   fs["count"],
			"length_ms":      fs["length_ms"],
		}
		journey["total_actions"]   = (journey["total_actions"] as int) + (fs["count"] as int)
		journey["total_length_ms"] = (journey["total_length_ms"] as int) + (fs["length_ms"] as int)
		journey["rounds"].append(round_data)

	var raw_forks: Array = data.get("Forks", [])
	var parsed_forks: Array = []
	for raw_fork: Dictionary in raw_forks:
		var fork_entry: Dictionary = {
			"after_order": raw_fork.get("AfterOrder", raw_fork.get("after_order", 0)),
			"title":       raw_fork.get("Title",       raw_fork.get("title",       "")),
			"description": raw_fork.get("Description", raw_fork.get("description", "")),
			"paths":       [],
		}
		var raw_paths: Array = raw_fork.get("Paths", raw_fork.get("paths", []))
		for raw_path: Dictionary in raw_paths:
			var img_file: String = raw_path.get("Image", raw_path.get("image", ""))
			var path_entry: Dictionary = {
				"name":        raw_path.get("Name",        raw_path.get("name",        "Path")),
				"description": raw_path.get("Description", raw_path.get("description", "")),
				"image_path":  (path + "/" + img_file) if img_file != "" else "",
				"rounds":      [],
			}
			var raw_pr_rounds: Array = raw_path.get("Rounds", raw_path.get("rounds", []))
			for raw_pr: Dictionary in raw_pr_rounds:
				var pr_name: String   = raw_pr.get("Name", raw_pr.get("name", "Round"))
				var pr_folder: String = path + "/" + pr_name
				var pr_fs: Dictionary = _read_funscript_stats(pr_folder)
				path_entry["rounds"].append({
					"name":           pr_name,
					"folder":         pr_folder,
					"funscript_path": pr_fs["path"],
					"coins":          raw_pr.get("CoinsAwarded", raw_pr.get("coins", 0)),
					"order":          raw_pr.get("Order",        raw_pr.get("order", 0)),
					"action_count":   pr_fs["count"],
					"length_ms":      pr_fs["length_ms"],
				})
			path_entry["shops"] = []
			var raw_pr_shops: Array = raw_path.get("Shops", raw_path.get("shops", []))
			for raw_ps in raw_pr_shops:
				if raw_ps is Dictionary:
					path_entry["shops"].append({
						"after_order": raw_ps.get("AfterOrder", raw_ps.get("after_order", 0)),
						"title":       raw_ps.get("Title",      raw_ps.get("title",       "")),
					})
				else:
					path_entry["shops"].append({"after_order": int(raw_ps), "title": ""})
			fork_entry["paths"].append(path_entry)
		parsed_forks.append(fork_entry)
	journey["forks"] = parsed_forks

	return journey


func _find_cover_image(path: String) -> String:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
			dir.list_dir_end()
			return path + "/" + fname
		fname = dir.get_next()
	dir.list_dir_end()
	return ""


# Loads an image by inspecting magic bytes rather than trusting the file extension.
# Handles covers that are JPEG/WebP saved with a .png extension.
static func load_image_smart(user_path: String) -> Image:
	if user_path == "":
		return null
	var abs_path: String = ProjectSettings.globalize_path(user_path)
	var f: FileAccess = FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return null
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	if bytes.is_empty():
		return null

	var img: Image = Image.new()
	var err: Error

	if bytes.size() >= 4 and bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
		err = img.load_png_from_buffer(bytes)
	elif bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes.size() >= 12 and bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46 \
			and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50:
		err = img.load_webp_from_buffer(bytes)
	else:
		err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			err = img.load_png_from_buffer(bytes)
		if err != OK:
			err = img.load_webp_from_buffer(bytes)

	return img if err == OK else null


func _read_funscript_stats(folder: String) -> Dictionary:
	var result: Dictionary = {"count": 0, "length_ms": 0, "path": ""}
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return result
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension() in ["funscript", "json"]:
			var full_path: String = folder + "/" + fname
			var f: FileAccess = FileAccess.open(full_path, FileAccess.READ)
			if f:
				var parser: JSON = JSON.new()
				if parser.parse(f.get_as_text()) == OK:
					var d: Dictionary = parser.data
					var actions: Array = d.get("actions", [])
					result["count"]     = actions.size()
					result["path"]      = full_path
					if not actions.is_empty():
						result["length_ms"] = actions[-1].get("at", 0)
				f.close()
				dir.list_dir_end()
				return result
		fname = dir.get_next()
	dir.list_dir_end()
	return result


# ---------------------------------------------------------------------------
# Grid population
# ---------------------------------------------------------------------------

func _sort_and_populate() -> void:
	_set_active_sort()
	var sorted: Array = _journeys.duplicate()
	var asc: bool = _sort_asc
	match _sort_field:
		"name":
			sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var cmp: int = (a["title"] as String).naturalnocasecmp_to(b["title"] as String)
				return cmp < 0 if asc else cmp > 0
			)
		"duration":
			sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var va: int = a["total_length_ms"]
				var vb: int = b["total_length_ms"]
				return va < vb if asc else va > vb
			)
		"actions":
			sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var va: int = a["total_actions"]
				var vb: int = b["total_actions"]
				return va < vb if asc else va > vb
			)
	_populate_grid(sorted)


func _populate_grid(journeys: Array) -> void:
	for child in _grid.get_children():
		child.queue_free()
	_empty_lbl.visible = journeys.is_empty()
	for journey: Dictionary in journeys:
		var card: PanelContainer = JourneyCardScene.instantiate()
		_grid.add_child(card)
		card.setup(journey)
		card.selected.connect(_on_journey_selected.bind(journey))


func _on_journey_selected(journey: Dictionary) -> void:
	_current_journey = journey
	_populate_modal(journey)
	_modal.visible = true


# ---------------------------------------------------------------------------
# Detail modal
# ---------------------------------------------------------------------------

func _populate_modal(journey: Dictionary) -> void:
	_modal_title.text  = journey.get("title", "Unknown")
	_modal_author.text = "by " + (journey.get("author", "Unknown") as String)

	var diff: String = journey.get("difficulty", "Unknown")
	_modal_diff.text = "◆  " + diff.to_upper()
	var diff_color: Color = DIFF_COLORS.get(diff, COLOR_WHITE_SOFT)
	_modal_diff.add_theme_color_override("font_color", diff_color)

	var rounds: Array = journey.get("rounds", [])
	_stat_rounds.text  = str(rounds.size()) + " ROUNDS"
	_stat_actions.text = str(journey.get("total_actions", 0)) + " ACTIONS"
	var total_secs: int = (journey.get("total_length_ms", 0) as int) / 1000
	_stat_length.text  = _format_duration(total_secs)

	var desc: String = journey.get("description", "")
	_modal_desc.text    = desc
	_modal_desc.visible = desc != ""

	var cover_path: String = journey.get("cover_path", "")
	var cover_img: Image = load_image_smart(cover_path)
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
		lbl.add_theme_color_override("font_color", COLOR_SEPARATOR)
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.uppercase = true
		hdr.add_child(lbl)
	var hdr_line: HSeparator = HSeparator.new()
	var hdr_style: StyleBoxFlat = StyleBoxFlat.new()
	hdr_style.bg_color = Color(COLOR_SEPARATOR.r, COLOR_SEPARATOR.g, COLOR_SEPARATOR.b, 0.3)
	hdr_line.add_theme_stylebox_override("separator", hdr_style)
	_round_list.add_child(hdr_line)

	var forks_data: Array = journey.get("forks", [])
	var seq: Array = []
	for rd: Dictionary in rounds:
		seq.append({"type": "round", "data": rd, "key": (rd.get("order", 0) as int) * 3})
	for sh: Dictionary in shops_data:
		seq.append({"type": "shop", "data": sh, "key": (sh.get("after_order", 0) as int) * 3 + 1})
	for fk: Dictionary in forks_data:
		seq.append({"type": "fork", "data": fk, "key": (fk.get("after_order", 0) as int) * 3 + 2})
	seq.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a["key"] as int) < (b["key"] as int))

	for item: Dictionary in seq:
		if item["type"] == "fork":
			var fork: Dictionary = item["data"]
			var fork_row: HBoxContainer = HBoxContainer.new()
			fork_row.add_theme_constant_override("separation", 8)
			_round_list.add_child(fork_row)
			var fork_lbl: Label = Label.new()
			var paths: Array = fork.get("paths", [])
			var fork_title: String = fork.get("title", "")
			if fork_title != "":
				fork_lbl.text = "  ⑂  FORK: %s  (%d PATHS)" % [fork_title.to_upper(), paths.size()]
			else:
				fork_lbl.text = "  ⑂  FORK  (%d PATHS)" % paths.size()
			fork_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			fork_lbl.add_theme_color_override("font_color", COLOR_PURPLE_BRIGHT)
			fork_lbl.add_theme_font_size_override("font_size", 11)
			fork_row.add_child(fork_lbl)
			continue

		if item["type"] == "shop":
			var shop: Dictionary = item["data"]
			var shop_row: HBoxContainer = HBoxContainer.new()
			shop_row.add_theme_constant_override("separation", 8)
			_round_list.add_child(shop_row)
			var shop_lbl: Label = Label.new()
			var shop_title: String = shop.get("title", "")
			if shop_title != "":
				shop_lbl.text = "  ◆  SHOP: %s" % shop_title.to_upper()
			else:
				shop_lbl.text = "  ◆  SHOP"
			shop_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			shop_lbl.add_theme_color_override("font_color", COLOR_MAGENTA)
			shop_lbl.add_theme_font_size_override("font_size", 11)
			shop_row.add_child(shop_lbl)
			continue

		var round_data: Dictionary = item["data"]
		var order: int = round_data.get("order", 0)

		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		_round_list.add_child(row)

		var order_lbl: Label = Label.new()
		order_lbl.text = "%02d." % order
		order_lbl.custom_minimum_size = Vector2(36, 0)
		order_lbl.add_theme_color_override("font_color", COLOR_PURPLE_MID)
		order_lbl.add_theme_font_size_override("font_size", 12)
		row.add_child(order_lbl)

		var name_lbl: Label = Label.new()
		name_lbl.text = (round_data.get("name", "") as String).to_upper()
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_color_override("font_color", COLOR_WHITE_SOFT)
		name_lbl.add_theme_font_size_override("font_size", 13)
		row.add_child(name_lbl)

		var dur_secs: int = (round_data.get("length_ms", 0) as int) / 1000
		var dur_lbl: Label = Label.new()
		dur_lbl.text = _format_duration(dur_secs)
		dur_lbl.custom_minimum_size = Vector2(56, 0)
		dur_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		dur_lbl.add_theme_color_override("font_color", COLOR_WHITE_SOFT)
		dur_lbl.add_theme_font_size_override("font_size", 12)
		row.add_child(dur_lbl)

		var acts_lbl: Label = Label.new()
		acts_lbl.text = str(round_data.get("action_count", 0)) + " actions"
		acts_lbl.custom_minimum_size = Vector2(72, 0)
		acts_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		acts_lbl.add_theme_color_override("font_color", COLOR_PURPLE_MID)
		acts_lbl.add_theme_font_size_override("font_size", 12)
		row.add_child(acts_lbl)

		var coins_lbl: Label = Label.new()
		coins_lbl.text = "♦ " + str(round_data.get("coins", 0))
		coins_lbl.custom_minimum_size = Vector2(72, 0)
		coins_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		coins_lbl.add_theme_color_override("font_color", COLOR_MAGENTA)
		coins_lbl.add_theme_font_size_override("font_size", 12)
		row.add_child(coins_lbl)


func _format_duration(total_seconds: int) -> String:
	var h: int = total_seconds / 3600
	var m: int = (total_seconds % 3600) / 60
	var s: int = total_seconds % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s]
	return "%d:%02d" % [m, s]
