extends Control

# ---------------------------------------------------------------------------
# Main.gd  –  Main menu controller
# Purple matrix theme. Title + buttons enclosed in an opaque panel with a
# neon-sign glowing border that occasionally flickers.
# ---------------------------------------------------------------------------

const COLOR_BG:            Color = Color(0.0,   0.0,   0.0,   1.0)  # #000000
const COLOR_PANEL_BG:      Color = Color(0.055, 0.008, 0.086, 1.0)  # #0e0216
const COLOR_PURPLE_DARK:   Color = Color(0.176, 0.024, 0.259, 1.0)  # #2d0642
const COLOR_PURPLE_MID:    Color = Color(0.408, 0.063, 0.627, 1.0)  # #6810a0
const COLOR_PURPLE_BRIGHT: Color = Color(0.698, 0.118, 1.0,   1.0)  # #b21eff
const COLOR_MAGENTA:       Color = Color(0.878, 0.0,   0.878, 1.0)  # #e000e0
const COLOR_WHITE_SOFT:    Color = Color(0.878, 0.780, 1.0,   1.0)  # #e0c7ff
const COLOR_SEPARATOR:     Color = Color(0.698, 0.118, 1.0,   0.5)
const COLOR_TAGLINE:       Color = Color(0.698, 0.118, 1.0,   1.0)

const FONT_SIZE_EYEBROW:  int = 12
const FONT_SIZE_TITLE:    int = 54
const FONT_SIZE_SUBTITLE: int = 24
const FONT_SIZE_BUTTON:   int = 17
const FONT_SIZE_TAGLINE:  int = 12

const BUTTON_MIN_WIDTH:  int = 280
const BUTTON_MIN_HEIGHT: int = 52

const PANEL_PADDING_H: int = 48
const PANEL_PADDING_V: int = 40
const BORDER_WIDTH:    int = 3

const BLINK_INTERVAL: float = 0.85

const FLICKER_INTERVAL_MIN: float = 3.5
const FLICKER_INTERVAL_MAX: float = 7.0
const FLICKER_DURATION:     float = 0.08

@onready var _bg:               ColorRect      = $Background
@onready var _panel:            PanelContainer = $Panel
@onready var _center:           VBoxContainer  = $Panel/CenterContainer
@onready var _title_section:    VBoxContainer  = $Panel/CenterContainer/TitleSection
@onready var _eyebrow:          Label          = $Panel/CenterContainer/TitleSection/Eyebrow
@onready var _title:            Label          = $Panel/CenterContainer/TitleSection/TitleLabel
@onready var _subtitle:         Label          = $Panel/CenterContainer/TitleSection/SubtitleLabel
@onready var _divider:          HSeparator     = $Panel/CenterContainer/TitleSection/TitleDivider
@onready var _button_container: VBoxContainer  = $Panel/CenterContainer/ButtonContainer
@onready var _start_btn:        Button         = $Panel/CenterContainer/ButtonContainer/StartButton
@onready var _options_btn:      Button         = $Panel/CenterContainer/ButtonContainer/OptionsButton
@onready var _build_btn:        Button         = $Panel/CenterContainer/ButtonContainer/BuildButton
@onready var _quit_btn:         Button         = $Panel/CenterContainer/ButtonContainer/QuitButton
@onready var _tagline:          Label          = $Panel/CenterContainer/TaglineLabel

var _blink_timer:     float = 0.0
var _blink_visible:   bool  = true
var _flicker_timer:   float = 0.0
var _flicker_next:    float = 0.0
var _flickering:      bool  = false
var _flicker_elapsed: float = 0.0
var _border_alpha:    float = 1.0


func _ready() -> void:
	_flicker_next = randf_range(FLICKER_INTERVAL_MIN, FLICKER_INTERVAL_MAX)
	_apply_layout()
	_apply_theme()
	_connect_buttons()


func _process(delta: float) -> void:
	# Tagline blink
	_blink_timer += delta
	if _blink_timer >= BLINK_INTERVAL:
		_blink_timer   = 0.0
		_blink_visible = not _blink_visible
		var c: Color   = _tagline.modulate
		c.a            = 1.0 if _blink_visible else 0.0
		_tagline.modulate = c

	# Neon border flicker
	_flicker_timer += delta
	if not _flickering and _flicker_timer >= _flicker_next:
		_flickering      = true
		_flicker_elapsed = 0.0
		_flicker_timer   = 0.0
		_flicker_next    = randf_range(FLICKER_INTERVAL_MIN, FLICKER_INTERVAL_MAX)

	if _flickering:
		_flicker_elapsed += delta
		_border_alpha     = 0.15 if _flicker_elapsed < FLICKER_DURATION * 0.5 else 1.0
		if _flicker_elapsed >= FLICKER_DURATION:
			_flickering   = false
			_border_alpha = 1.0
		_update_panel_border()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_bg.anchor_left   = 0.0
	_bg.anchor_top    = 0.0
	_bg.anchor_right  = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left   = 0
	_bg.offset_top    = 0
	_bg.offset_right  = 0
	_bg.offset_bottom = 0

	_panel.anchor_left   = 0.5
	_panel.anchor_right  = 0.5
	_panel.anchor_top    = 0.5
	_panel.anchor_bottom = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical   = Control.GROW_DIRECTION_BOTH

	_center.add_theme_constant_override("separation", 36)

	_title_section.add_theme_constant_override("separation", 6)
	_title_section.alignment = BoxContainer.ALIGNMENT_CENTER

	_button_container.add_theme_constant_override("separation", 14)
	_button_container.alignment = BoxContainer.ALIGNMENT_CENTER

	for btn: Button in [_start_btn, _options_btn, _build_btn, _quit_btn]:
		btn.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, BUTTON_MIN_HEIGHT)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = COLOR_BG
	_update_panel_border()

	_style_label(_eyebrow,  COLOR_MAGENTA,        FONT_SIZE_EYEBROW,  true)
	_style_label(_title,    COLOR_PURPLE_BRIGHT,   FONT_SIZE_TITLE,    true)
	_style_label(_subtitle, COLOR_MAGENTA,         FONT_SIZE_SUBTITLE, true)

	var sep: StyleBoxFlat     = StyleBoxFlat.new()
	sep.bg_color              = COLOR_SEPARATOR
	sep.content_margin_top    = 1
	sep.content_margin_bottom = 1
	_divider.add_theme_stylebox_override("separator", sep)

	_style_button(_start_btn,   COLOR_PURPLE_BRIGHT)
	_style_button(_options_btn, COLOR_MAGENTA)
	_style_button(_build_btn,   COLOR_PURPLE_MID)
	_style_button(_quit_btn,    COLOR_PURPLE_MID)

	_style_label(_tagline, COLOR_TAGLINE, FONT_SIZE_TAGLINE, true)


func _update_panel_border() -> void:
	var border_col: Color = Color(COLOR_PURPLE_BRIGHT.r, COLOR_PURPLE_BRIGHT.g, COLOR_PURPLE_BRIGHT.b, _border_alpha)
	var shadow_col: Color = Color(COLOR_MAGENTA.r, COLOR_MAGENTA.g, COLOR_MAGENTA.b, _border_alpha * 0.5)

	var s: StyleBoxFlat       = StyleBoxFlat.new()
	s.bg_color                = COLOR_PANEL_BG
	s.border_color            = border_col
	s.border_width_left       = BORDER_WIDTH
	s.border_width_right      = BORDER_WIDTH
	s.border_width_top        = BORDER_WIDTH
	s.border_width_bottom     = BORDER_WIDTH
	s.corner_radius_top_left     = 4
	s.corner_radius_top_right    = 4
	s.corner_radius_bottom_left  = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color            = shadow_col
	s.shadow_size             = 12
	s.content_margin_left     = PANEL_PADDING_H
	s.content_margin_right    = PANEL_PADDING_H
	s.content_margin_top      = PANEL_PADDING_V
	s.content_margin_bottom   = PANEL_PADDING_V
	_panel.add_theme_stylebox_override("panel", s)


func _style_label(label: Label, color: Color, size: int, uppercase: bool = false) -> void:
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	label.uppercase = uppercase


func _style_button(btn: Button, accent: Color) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   COLOR_WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", COLOR_BG)
	btn.add_theme_font_size_override("font_size", FONT_SIZE_BUTTON)
	btn.text = btn.text.to_upper()

	btn.add_theme_stylebox_override("normal",  _make_btn_style(accent, COLOR_PURPLE_DARK))
	btn.add_theme_stylebox_override("hover",   _make_btn_style(accent, COLOR_PURPLE_MID))
	btn.add_theme_stylebox_override("pressed", _make_btn_style(accent, accent))
	btn.add_theme_stylebox_override("focus",   StyleBoxEmpty.new())


func _make_btn_style(border_color: Color, fill_color: Color) -> StyleBoxFlat:
	var s: StyleBoxFlat   = StyleBoxFlat.new()
	s.bg_color            = fill_color
	s.border_color        = border_color
	s.border_width_left   = 2
	s.border_width_right  = 2
	#s.border_width_top    = 2
	s.border_width_bottom = 2
	s.corner_radius_top_left     = 0
	s.corner_radius_top_right    = 0
	s.corner_radius_bottom_left  = 0
	s.corner_radius_bottom_right = 0
	s.content_margin_left   = 20
	s.content_margin_right  = 20
	s.content_margin_top    = 12
	s.content_margin_bottom = 12
	return s


# ---------------------------------------------------------------------------
# Button signals
# ---------------------------------------------------------------------------

func _connect_buttons() -> void:
	_start_btn.pressed.connect(_on_start_pressed)
	_options_btn.pressed.connect(_on_options_pressed)
	_build_btn.pressed.connect(_on_build_pressed)
	_quit_btn.pressed.connect(_on_quit_pressed)


func _on_start_pressed() -> void:
	Transition.change_scene("res://scenes/journey_select/JourneySelect.tscn")


func _on_options_pressed() -> void:
	Transition.change_scene("res://scenes/options/Options.tscn")


func _on_build_pressed() -> void:
	Transition.change_scene("res://scenes/journey_builder/JourneyBuilder.tscn")


func _on_quit_pressed() -> void:
	get_tree().quit()
