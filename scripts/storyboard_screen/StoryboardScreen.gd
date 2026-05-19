extends Control

signal completed(coins: int)

const COLOR_BAR_BG:  Color = Color(0.02, 0.004, 0.035, 0.94)
const COLOR_CYAN:    Color = Color(0.10, 0.85,  0.90,  1.0)
const COLOR_WHITE:   Color = Color(0.878, 0.780, 1.0,  1.0)
const COLOR_MUTED:   Color = Color(0.55, 0.47,  0.72,  1.0)

const VN_BAR_HEIGHT: int = 210

@onready var _bg_image:  TextureRect    = $BgImage
@onready var _vn_bar:    PanelContainer = $VNBar
@onready var _speaker:   Label          = $VNBar/Inner/VBox/Speaker
@onready var _dialogue:  Label          = $VNBar/Inner/VBox/DialogueLine
@onready var _hint:      Label          = $VNBar/Inner/VBox/ContinueHint
@onready var _fade:      ColorRect      = $FadeOverlay

var _lines:       Array  = []
var _line_idx:    int    = 0
var _coins:       int    = 0
var _def_image:   String = ""
var _can_advance: bool   = false


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_fade.color      = Color.BLACK
	_fade.modulate.a = 1.0
	await get_tree().process_frame
	var tween: Tween = create_tween()
	tween.tween_property(_fade, "modulate:a", 0.0, 0.35).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void: _can_advance = true)


func setup(data: Dictionary) -> void:
	_coins     = data.get("coins", 0)
	_def_image = data.get("image", "")
	_lines     = data.get("lines", [])
	_line_idx  = 0
	if _lines.is_empty():
		_load_bg_image(_def_image)
		return
	_show_line()


func _show_line() -> void:
	var line: Dictionary = _lines[_line_idx]
	var img: String = line.get("image", "")
	if img == "":
		img = _def_image
	_load_bg_image(img)

	var spk: String = line.get("speaker", "")
	_speaker.visible = spk != ""
	_speaker.text    = spk.to_upper()
	_dialogue.text   = line.get("text", "")

	var is_last: bool = _line_idx >= _lines.size() - 1
	_hint.text = "▶ CLICK OR PRESS SPACE TO COMPLETE" if is_last else "▶ CLICK OR PRESS SPACE TO CONTINUE"


func _load_bg_image(path: String) -> void:
	if path == "":
		_bg_image.texture = null
		return
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		_bg_image.texture = null
		return
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
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
	_bg_image.texture = ImageTexture.create_from_image(img) if err == OK else null


func _input(event: InputEvent) -> void:
	if not _can_advance:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_advance()
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_advance()
		get_viewport().set_input_as_handled()


func _advance() -> void:
	_line_idx += 1
	if _line_idx >= _lines.size():
		_finish()
	else:
		_show_line()


func _finish() -> void:
	_can_advance = false
	var tween: Tween = create_tween()
	tween.tween_property(_fade, "modulate:a", 1.0, 0.4).set_ease(Tween.EASE_IN)
	tween.tween_callback(func() -> void:
		emit_signal("completed", _coins)
		queue_free()
	)


# ---------------------------------------------------------------------------
# Layout / theme
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_bg_image.anchor_left   = 0.0
	_bg_image.anchor_top    = 0.0
	_bg_image.anchor_right  = 1.0
	_bg_image.anchor_bottom = 1.0
	_bg_image.offset_left   = 0
	_bg_image.offset_top    = 0
	_bg_image.offset_right  = 0
	_bg_image.offset_bottom = 0
	_bg_image.expand_mode  = 1  # EXPAND_IGNORE — never overflow anchor bounds
	_bg_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

	_vn_bar.anchor_left   = 0.0
	_vn_bar.anchor_right  = 1.0
	_vn_bar.anchor_top    = 1.0
	_vn_bar.anchor_bottom = 1.0
	_vn_bar.offset_top    = -VN_BAR_HEIGHT
	_vn_bar.offset_bottom = 0

	_fade.anchor_right  = 1.0
	_fade.anchor_bottom = 1.0

	var inner: MarginContainer = $VNBar/Inner
	inner.add_theme_constant_override("margin_left",   48)
	inner.add_theme_constant_override("margin_right",  48)
	inner.add_theme_constant_override("margin_top",    22)
	inner.add_theme_constant_override("margin_bottom", 22)

	var vbox: VBoxContainer = $VNBar/Inner/VBox
	vbox.add_theme_constant_override("separation", 12)


func _apply_theme() -> void:
	var bar_style: StyleBoxFlat = StyleBoxFlat.new()
	bar_style.bg_color           = COLOR_BAR_BG
	bar_style.border_color       = COLOR_CYAN
	bar_style.border_width_top   = 2
	bar_style.content_margin_left   = 0
	bar_style.content_margin_right  = 0
	bar_style.content_margin_top    = 0
	bar_style.content_margin_bottom = 0
	_vn_bar.add_theme_stylebox_override("panel", bar_style)

	_speaker.add_theme_color_override("font_color",    COLOR_CYAN)
	_speaker.add_theme_font_size_override("font_size", 14)
	_speaker.uppercase = true

	_dialogue.add_theme_color_override("font_color",    COLOR_WHITE)
	_dialogue.add_theme_font_size_override("font_size", 19)
	_dialogue.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_hint.add_theme_color_override("font_color",    COLOR_MUTED)
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
