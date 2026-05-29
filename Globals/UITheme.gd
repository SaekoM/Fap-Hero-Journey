extends Node

# ---------------------------------------------------------------------------
# UITheme  –  Central palette + style helpers
#
# Autoloaded as `UITheme`. Holds every shared color constant and every
# duplicated `_style_*` helper that used to live in each screen script.
#
# Usage:
#     label.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
#     UITheme.style_button(my_btn, UITheme.MAGENTA)
#     hbox.add_child(UITheme.make_icon_btn("↑", false, UITheme.PURPLE_MID))
# ---------------------------------------------------------------------------

# ── Palette ────────────────────────────────────────────────────────────────

# Backgrounds
const BG:            Color = Color(0.0,   0.0,   0.0,   1.0)   # #000000
const BG_ZERO:       Color = Color(0.0,   0.0,   0.0,   0.0)   # fully transparent black
const PANEL_BG:      Color = Color(0.055, 0.008, 0.086, 1.0)   # #0e0216 – flat panels
const PANEL_BG_GAME: Color = Color(0.055, 0.008, 0.086, 0.88)  # HUD-bar variant
const PANEL_BG_DEEP: Color = Color(0.035, 0.005, 0.055, 0.97)  # deeper panel (inventory)
const PANEL_BG_SHOP: Color = Color(0.035, 0.005, 0.055, 0.96)  # shop screen
const PANEL_BG_FORK: Color = Color(0.055, 0.008, 0.086, 0.92)  # fork screen
const CARD_BG:       Color = Color(0.02,  0.0,   0.04,  1.0)   # individual cards
const CARD_BG_DIM:   Color = Color(0.01,  0.0,   0.02,  1.0)   # disabled cards
const BAR_BG:        Color = Color(0.02,  0.004, 0.035, 0.94)  # storyboard bar

# Purple ramp
const PURPLE_DARK:   Color = Color(0.176, 0.024, 0.259, 1.0)   # #2d0642
const PURPLE_MID:    Color = Color(0.408, 0.063, 0.627, 1.0)   # #6810a0
const PURPLE_BRIGHT: Color = Color(0.698, 0.118, 1.0,   1.0)   # #b21eff

# Accent colors
const MAGENTA:       Color = Color(0.878, 0.0,   0.878, 1.0)   # #e000e0
const WHITE_SOFT:    Color = Color(0.878, 0.780, 1.0,   1.0)   # #e0c7ff
const AMBER:         Color = Color(1.0,   0.65,  0.15,  1.0)
const TOXIC_GREEN:   Color = Color(0.45,  1.0,   0.35,  1.0)
const CYAN:          Color = Color(0.10,  0.85,  0.90,  1.0)
const DARK_TEXT:     Color = Color(0.55,  0.47,  0.72,  1.0)

# Semantic colors
const SEPARATOR:     Color = Color(0.698, 0.118, 1.0,   0.5)
const DANGER:        Color = Color(0.9,   0.15,  0.15,  1.0)
const ERROR:         Color = Color(1.0,   0.25,  0.05,  1.0)
const ERROR_SOFT:    Color = Color(1.0,   0.3,   0.3,   1.0)
const OK:            Color = Color(0.35,  0.95,  0.35,  1.0)
const SUCCESS:       Color = Color(0.3,   1.0,   0.5,   1.0)

# Aliases for clarity at the call site
const STORYBOARD:    Color = Color(0.0,   0.78,  0.88,  1.0)   # used by JourneyBuilder

# Graph view (canvas) extras
const GRID:          Color = Color(0.10,  0.04,  0.18,  0.4)
const EDGE:          Color = Color(0.55,  0.30,  0.85,  0.85)
const FORK_EDGE:     Color = Color(0.88,  0.0,   0.88,  0.85)


# ── Style helpers ──────────────────────────────────────────────────────────

# Apply standard font-color + size + uppercase override to a Label.
func style_label(label: Label, color: Color, size: int, uppercase: bool = false) -> void:
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	label.uppercase = uppercase


# Build a StyleBoxFlat with the cyberpunk border + fill scheme.
# Default padding (16h / 10v) matches the most common call sites.
func make_btn_style(border: Color, fill: Color, h_pad: int = 16, v_pad: int = 10) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color            = fill
	s.border_color        = border
	s.border_width_left   = 2; s.border_width_right  = 2
	s.border_width_top    = 2; s.border_width_bottom = 2
	s.content_margin_left = h_pad; s.content_margin_right  = h_pad
	s.content_margin_top  = v_pad; s.content_margin_bottom = v_pad
	return s


# Full button styling: font colors, size, uppercases text, and applies the
# three-state stylebox (normal/hover/pressed) plus an empty focus rect.
func style_button(btn: Button, accent: Color, h_pad: int = 16, v_pad: int = 10, font_size: int = 14) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", BG)
	btn.add_theme_font_size_override("font_size", font_size)
	btn.text = btn.text.to_upper()
	btn.add_theme_stylebox_override("normal",  make_btn_style(accent, PURPLE_DARK, h_pad, v_pad))
	btn.add_theme_stylebox_override("hover",   make_btn_style(accent, PURPLE_MID,  h_pad, v_pad))
	btn.add_theme_stylebox_override("pressed", make_btn_style(accent, accent,      h_pad, v_pad))
	btn.add_theme_stylebox_override("focus",   StyleBoxEmpty.new())


# Compact icon-only button (used by JourneyBuilder rows for ↑ ↓ ✕ etc.).
func make_icon_btn(icon: String, disabled: bool, accent: Color) -> Button:
	var btn: Button = Button.new()
	btn.text = icon
	btn.custom_minimum_size = Vector2(32, 0)
	btn.disabled = disabled
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.add_theme_stylebox_override("normal",  make_btn_style(accent, PURPLE_DARK))
	btn.add_theme_stylebox_override("hover",   make_btn_style(accent, PURPLE_MID))
	btn.add_theme_stylebox_override("pressed", make_btn_style(accent, accent))
	btn.add_theme_stylebox_override("focus",   StyleBoxEmpty.new())
	return btn


# LineEdit styling: purple-dark fill, mid-purple border, bright caret/focus.
func style_line_edit(line_edit: LineEdit) -> void:
	line_edit.add_theme_color_override("font_color",             WHITE_SOFT)
	line_edit.add_theme_color_override("font_placeholder_color", PURPLE_MID)
	line_edit.add_theme_color_override("caret_color",            PURPLE_BRIGHT)
	line_edit.add_theme_font_size_override("font_size", 14)
	var normal_style: StyleBoxFlat = StyleBoxFlat.new()
	normal_style.bg_color            = PURPLE_DARK
	normal_style.border_color        = PURPLE_MID
	normal_style.border_width_left   = 2; normal_style.border_width_right  = 2
	normal_style.border_width_top    = 2; normal_style.border_width_bottom = 2
	normal_style.content_margin_left = 10; normal_style.content_margin_right  = 10
	normal_style.content_margin_top  = 8;  normal_style.content_margin_bottom = 8
	line_edit.add_theme_stylebox_override("normal", normal_style)
	var focus_style: StyleBoxFlat = normal_style.duplicate()
	focus_style.border_color = PURPLE_BRIGHT
	line_edit.add_theme_stylebox_override("focus", focus_style)


# TextEdit styling (multi-line).
func style_text_edit(text_edit: TextEdit) -> void:
	text_edit.add_theme_color_override("font_color",  WHITE_SOFT)
	text_edit.add_theme_color_override("caret_color", PURPLE_BRIGHT)
	text_edit.add_theme_font_size_override("font_size", 13)
	var normal_style: StyleBoxFlat = StyleBoxFlat.new()
	normal_style.bg_color            = PURPLE_DARK
	normal_style.border_color        = PURPLE_MID
	normal_style.border_width_left   = 2; normal_style.border_width_right  = 2
	normal_style.border_width_top    = 2; normal_style.border_width_bottom = 2
	normal_style.content_margin_left = 10; normal_style.content_margin_right  = 10
	normal_style.content_margin_top  = 8;  normal_style.content_margin_bottom = 8
	text_edit.add_theme_stylebox_override("normal", normal_style)
	var focus_style: StyleBoxFlat = normal_style.duplicate()
	focus_style.border_color = PURPLE_BRIGHT
	text_edit.add_theme_stylebox_override("focus", focus_style)


# OptionButton (dropdown) styling.
func style_option_button(option_button: OptionButton) -> void:
	option_button.add_theme_color_override("font_color",       WHITE_SOFT)
	option_button.add_theme_color_override("font_hover_color", PURPLE_BRIGHT)
	option_button.add_theme_font_size_override("font_size", 14)
	var normal_style: StyleBoxFlat = StyleBoxFlat.new()
	normal_style.bg_color            = PURPLE_DARK
	normal_style.border_color        = PURPLE_MID
	normal_style.border_width_left   = 2; normal_style.border_width_right  = 2
	normal_style.border_width_top    = 2; normal_style.border_width_bottom = 2
	normal_style.content_margin_left = 10; normal_style.content_margin_right  = 10
	normal_style.content_margin_top  = 8;  normal_style.content_margin_bottom = 8
	option_button.add_theme_stylebox_override("normal", normal_style)
	var hover_style: StyleBoxFlat = normal_style.duplicate()
	hover_style.border_color = PURPLE_BRIGHT
	option_button.add_theme_stylebox_override("hover",   hover_style)
	option_button.add_theme_stylebox_override("pressed", hover_style)
	option_button.add_theme_stylebox_override("focus",   StyleBoxEmpty.new())


# Read-only tag chip: a small rounded pill, `text` in `accent`, on a near-opaque
# dark background with an `accent` border. The dark fill keeps the chip legible
# when overlaid on bright/busy cover art, not just on dark panels.
func make_tag_chip(text: String, accent: Color) -> Control:
	var chip: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color            = Color(0.03, 0.0, 0.05, 0.9)
	s.border_color        = accent
	s.border_width_left   = 1; s.border_width_right  = 1
	s.border_width_top    = 1; s.border_width_bottom = 1
	s.corner_radius_top_left     = 6; s.corner_radius_top_right    = 6
	s.corner_radius_bottom_left  = 6; s.corner_radius_bottom_right = 6
	s.content_margin_left = 8; s.content_margin_right  = 8
	s.content_margin_top  = 2; s.content_margin_bottom = 2
	chip.add_theme_stylebox_override("panel", s)

	var lbl: Label = Label.new()
	lbl.text = text.to_upper()
	lbl.add_theme_color_override("font_color", accent)
	lbl.add_theme_font_size_override("font_size", 10)
	chip.add_child(lbl)
	return chip


# Thin horizontal separator stylebox using the SEPARATOR color at given alpha.
func make_separator_style(alpha: float = 1.0) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(SEPARATOR.r, SEPARATOR.g, SEPARATOR.b, SEPARATOR.a * alpha)
	s.content_margin_top    = 1
	s.content_margin_bottom = 1
	return s


# ── Centered modal scaffolding ──────────────────────────────────────────────
#
# Every dynamically-built modal in this project shares the same shape: a
# full-screen semi-opaque backdrop, a centered PanelContainer with an accent
# bordered StyleBoxFlat, a title label, and a VBoxContainer for body content.
# This helper builds the scaffolding once so callers can focus on the body.
#
# Returns:
#   {
#     "modal":  Control          – add as child of the calling node; queue_free to dismiss
#     "vbox":   VBoxContainer    – append body content to this
#     "title":  Label            – already populated and styled, exposed so callers can restyle if needed
#   }
#
# Standard panel size is 720×520. Pass `panel_size` to override (e.g. a wider
# error modal listing many issues, or a narrower confirmation prompt).
func build_centered_modal(
		title: String,
		accent: Color,
		panel_size: Vector2i = Vector2i(720, 520)) -> Dictionary:
	var modal: Control = Control.new()
	modal.anchor_right  = 1.0
	modal.anchor_bottom = 1.0
	modal.mouse_filter  = Control.MOUSE_FILTER_STOP

	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.85)
	backdrop.anchor_right  = 1.0
	backdrop.anchor_bottom = 1.0
	modal.add_child(backdrop)

	var panel: PanelContainer = PanelContainer.new()
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color              = PANEL_BG
	panel_style.border_color          = accent
	panel_style.border_width_left     = 2;  panel_style.border_width_right    = 2
	panel_style.border_width_top      = 2;  panel_style.border_width_bottom   = 2
	panel_style.content_margin_left   = 28; panel_style.content_margin_right  = 28
	panel_style.content_margin_top    = 22; panel_style.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", panel_style)
	panel.anchor_left = 0.5; panel.anchor_right  = 0.5
	panel.anchor_top  = 0.5; panel.anchor_bottom = 0.5
	var half_w: int = panel_size.x / 2
	var half_h: int = panel_size.y / 2
	panel.offset_left = -half_w; panel.offset_right  = half_w
	panel.offset_top  = -half_h; panel.offset_bottom = half_h
	modal.add_child(panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title_lbl: Label = Label.new()
	title_lbl.text = title
	style_label(title_lbl, accent, 16, true)
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title_lbl)

	return {
		"modal": modal,
		"vbox":  vbox,
		"title": title_lbl,
	}
