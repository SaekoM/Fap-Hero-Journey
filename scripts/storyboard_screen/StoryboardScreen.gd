extends Control

signal completed(coins: int)

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

var _skip_btn: Button = null


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_fade.color      = Color.BLACK
	_fade.modulate.a = 1.0
	await get_tree().process_frame
	var tween: Tween = create_tween()
	tween.tween_property(_fade, "modulate:a", 0.0, 0.35).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void:
		_can_advance = true
		_skip_btn.visible = true
	)


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
	_hint.text = "▶ CLICK OR SPACE TO COMPLETE" if is_last else "▶ CLICK OR SPACE TO CONTINUE"


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
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Transition.change_scene("res://scenes/main/Main.tscn")
		return
	if not _can_advance:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			# Let the skip button handle clicks that land on it.
			if _skip_btn.visible and _skip_btn.get_global_rect().has_point(mb.global_position):
				return
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
	_skip_btn.visible = false
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

	# Detach hint from the VBox so it no longer participates in the text flow.
	# Re-parent it directly onto the root Control as an absolutely-positioned
	# overlay pinned to the bottom-right corner — it will never move regardless
	# of speaker visibility or dialogue line wrapping.
	vbox.remove_child(_hint)
	add_child(_hint)
	_hint.anchor_left   = 0.0
	_hint.anchor_right  = 1.0
	_hint.anchor_top    = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_left   = 0
	_hint.offset_right  = -48   # match inner right margin
	_hint.offset_top    = -44   # inner bottom margin (22) + label height (~22)
	_hint.offset_bottom = -22   # inner bottom margin
	_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hint.mouse_filter  = Control.MOUSE_FILTER_IGNORE

	# Skip button — top-right corner, hidden until the opening fade completes.
	_skip_btn = Button.new()
	_skip_btn.text = "SKIP  ▶▶"
	_skip_btn.anchor_left   = 1.0
	_skip_btn.anchor_right  = 1.0
	_skip_btn.anchor_top    = 0.0
	_skip_btn.anchor_bottom = 0.0
	_skip_btn.offset_left   = -110
	_skip_btn.offset_right  = -16
	_skip_btn.offset_top    = 16
	_skip_btn.offset_bottom = 46
	_skip_btn.focus_mode    = Control.FOCUS_NONE
	_skip_btn.visible       = false
	_skip_btn.pressed.connect(_finish)
	add_child(_skip_btn)


func _apply_theme() -> void:
	var bar_style: StyleBoxFlat = StyleBoxFlat.new()
	bar_style.bg_color           = UITheme.BAR_BG
	bar_style.border_color       = UITheme.CYAN
	bar_style.border_width_top   = 2
	bar_style.content_margin_left   = 0
	bar_style.content_margin_right  = 0
	bar_style.content_margin_top    = 0
	bar_style.content_margin_bottom = 0
	_vn_bar.add_theme_stylebox_override("panel", bar_style)

	_speaker.add_theme_color_override("font_color",    UITheme.CYAN)
	_speaker.add_theme_font_size_override("font_size", 14)
	_speaker.uppercase = true

	_dialogue.add_theme_color_override("font_color",    UITheme.WHITE_SOFT)
	_dialogue.add_theme_font_size_override("font_size", 19)
	_dialogue.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_hint.add_theme_color_override("font_color",    UITheme.DARK_TEXT)
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# Skip button — subtle but readable; uses DARK_TEXT so it doesn't compete
	# with the dialogue, but brightens on hover.
	_skip_btn.add_theme_color_override("font_color",         UITheme.DARK_TEXT)
	_skip_btn.add_theme_color_override("font_hover_color",   UITheme.WHITE_SOFT)
	_skip_btn.add_theme_color_override("font_pressed_color", UITheme.BG)
	_skip_btn.add_theme_font_size_override("font_size", 11)

	var sk_n: StyleBoxFlat = StyleBoxFlat.new()
	sk_n.bg_color = Color(UITheme.DARK_TEXT.r, UITheme.DARK_TEXT.g, UITheme.DARK_TEXT.b, 0.08)
	sk_n.border_color = UITheme.DARK_TEXT
	sk_n.border_width_left   = 1; sk_n.border_width_right  = 1
	sk_n.border_width_top    = 1; sk_n.border_width_bottom = 1
	sk_n.corner_radius_top_left     = 4; sk_n.corner_radius_top_right    = 4
	sk_n.corner_radius_bottom_left  = 4; sk_n.corner_radius_bottom_right = 4
	sk_n.content_margin_left  = 10; sk_n.content_margin_right  = 10
	sk_n.content_margin_top   = 4;  sk_n.content_margin_bottom = 4
	_skip_btn.add_theme_stylebox_override("normal", sk_n)

	var sk_h: StyleBoxFlat = sk_n.duplicate()
	sk_h.bg_color     = Color(UITheme.WHITE_SOFT.r, UITheme.WHITE_SOFT.g, UITheme.WHITE_SOFT.b, 0.15)
	sk_h.border_color = UITheme.WHITE_SOFT
	_skip_btn.add_theme_stylebox_override("hover", sk_h)

	var sk_p: StyleBoxFlat = sk_n.duplicate()
	sk_p.bg_color = UITheme.DARK_TEXT
	_skip_btn.add_theme_stylebox_override("pressed", sk_p)
	_skip_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
