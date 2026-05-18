extends PanelContainer

# ---------------------------------------------------------------------------
# DropZone.gd  –  File drop zone with integrated browse button
# Accepts OS file drag-and-drop and a "..." browse button.
# Set accepted_extensions before adding to scene tree.
# Emits file_dropped(path) when a file is selected.
# ---------------------------------------------------------------------------

signal file_dropped(path: String)

const COLOR_PANEL_BG:      Color = Color(0.055, 0.008, 0.086, 1.0)
const COLOR_PURPLE_DARK:   Color = Color(0.176, 0.024, 0.259, 1.0)
const COLOR_PURPLE_MID:    Color = Color(0.408, 0.063, 0.627, 1.0)
const COLOR_PURPLE_BRIGHT: Color = Color(0.698, 0.118, 1.0,   1.0)
const COLOR_WHITE_SOFT:    Color = Color(0.878, 0.780, 1.0,   1.0)
const COLOR_BG:            Color = Color(0.0,   0.0,   0.0,   1.0)

var accepted_extensions: Array = []
var picker_title:        String = "Select File"
var picker_filters:      Array  = ["*.* ; All Files"]

var _placeholder: String = "Drop here or browse"
var _current_path: String = ""
var _label: Label
var _browse_btn: Button


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter          = Control.MOUSE_FILTER_STOP

	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	add_child(hbox)

	_label = Label.new()
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.clip_text             = true
	_label.add_theme_font_size_override("font_size", 11)
	_label.text = _current_path.get_file() if _current_path != "" else _placeholder
	hbox.add_child(_label)

	_browse_btn = Button.new()
	_browse_btn.text = "..."
	_browse_btn.focus_mode = Control.FOCUS_NONE
	_browse_btn.custom_minimum_size = Vector2(30, 0)
	_browse_btn.add_theme_font_size_override("font_size", 12)
	_browse_btn.pressed.connect(_on_browse_pressed)
	hbox.add_child(_browse_btn)

	_update_style()

	# Fallback for OS DnD via viewport signal (covers platforms where
	# _can_drop_data isn't triggered for external file drops)
	get_viewport().files_dropped.connect(_on_viewport_files_dropped)


func _exit_tree() -> void:
	if get_viewport():
		if get_viewport().files_dropped.is_connected(_on_viewport_files_dropped):
			get_viewport().files_dropped.disconnect(_on_viewport_files_dropped)


# --- Drag & drop (Godot internal + some OS DnD paths) ---

func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY or data.get("type") != "files":
		return false
	for f: String in (data.get("files", PackedStringArray()) as PackedStringArray):
		if f.get_extension().to_lower() in accepted_extensions:
			return true
	return false


func _drop_data(_pos: Vector2, data: Variant) -> void:
	for f: String in (data.get("files", PackedStringArray()) as PackedStringArray):
		if f.get_extension().to_lower() in accepted_extensions:
			set_file(f)
			return


# --- OS DnD fallback via viewport ---

func _on_viewport_files_dropped(files: PackedStringArray) -> void:
	if not is_visible_in_tree():
		return
	if not get_global_rect().has_point(get_viewport().get_mouse_position()):
		return
	for f: String in files:
		if f.get_extension().to_lower() in accepted_extensions:
			set_file(f)
			return


# --- Public API ---

func set_file(path: String) -> void:
	_current_path = path
	if _label:
		_label.text = path.get_file() if path != "" else _placeholder
	_update_style()
	file_dropped.emit(path)


func get_file() -> String:
	return _current_path


func clear() -> void:
	set_file("")


# --- Browse button ---

func _on_browse_pressed() -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.access    = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.filters   = picker_filters
	dialog.title     = picker_title
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(900, 600))
	dialog.file_selected.connect(func(path: String) -> void:
		set_file(path)
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())


# --- Style ---

func _update_style() -> void:
	var filled: bool = _current_path != ""

	var s: StyleBoxFlat   = StyleBoxFlat.new()
	s.bg_color            = COLOR_PURPLE_DARK if filled else COLOR_PANEL_BG
	s.border_color        = COLOR_PURPLE_BRIGHT if filled else COLOR_PURPLE_MID
	s.border_width_left   = 2
	s.border_width_right  = 2
	s.border_width_top    = 2
	s.border_width_bottom = 2
	s.content_margin_left   = 8
	s.content_margin_right  = 6
	s.content_margin_top    = 6
	s.content_margin_bottom = 6
	add_theme_stylebox_override("panel", s)

	if _label:
		_label.add_theme_color_override("font_color",
			COLOR_WHITE_SOFT if filled else COLOR_PURPLE_MID)

	if _browse_btn:
		var bs: StyleBoxFlat   = StyleBoxFlat.new()
		bs.bg_color            = COLOR_PURPLE_DARK
		bs.border_color        = COLOR_PURPLE_MID
		bs.border_width_left   = 1
		bs.border_width_right  = 1
		bs.border_width_top    = 1
		bs.border_width_bottom = 1
		bs.content_margin_left   = 4
		bs.content_margin_right  = 4
		bs.content_margin_top    = 2
		bs.content_margin_bottom = 2
		_browse_btn.add_theme_stylebox_override("normal",   bs)
		_browse_btn.add_theme_stylebox_override("focus",    StyleBoxEmpty.new())
		var bs_h: StyleBoxFlat = bs.duplicate()
		bs_h.border_color = COLOR_PURPLE_BRIGHT
		_browse_btn.add_theme_stylebox_override("hover",    bs_h)
		_browse_btn.add_theme_stylebox_override("pressed",  bs_h)
		_browse_btn.add_theme_color_override("font_color",       COLOR_PURPLE_BRIGHT)
		_browse_btn.add_theme_color_override("font_hover_color", COLOR_WHITE_SOFT)
