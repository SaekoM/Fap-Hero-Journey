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

# ── Readability ────────────────────────────────────────────────────────────
# Distinct from Options → UI SCALE, which resizes the whole interface (layout included) via
# content_scale_factor. These grow TEXT only, where long-form reading happens.

const TOOLTIP_BASE_FONT_SIZE: int = 16  # Godot's default theme size for TooltipLabel


# Font size for narrative text — fork prose, boss intro cards, storyboard dialogue. Pass the
# design size; the player's STORY TEXT setting scales it. Chrome (HUD, buttons, toasts) keeps
# its literal size, so a large setting doesn't reflow the whole game.
func story_font_size(base: int) -> int:
	return maxi(1, roundi(base * SettingsService.get_story_text_scale()))


# Tooltips can't take a per-label override — Godot renders them from the `TooltipLabel` theme
# type — so this puts a Theme on the Window carrying only that font size. Everything else falls
# through to the default theme, so nothing else changes appearance.
func apply_tooltip_scale() -> void:
	var w: Window = get_window()
	if w == null:
		return
	var t: Theme = w.theme if w.theme != null else Theme.new()
	t.set_font_size(
		"font_size",
		"TooltipLabel",
		maxi(1, roundi(TOOLTIP_BASE_FONT_SIZE * SettingsService.get_tooltip_text_scale()))
	)
	w.theme = t


# ── Glyph fallback fonts ─────────────────────────────────────────────────────
# The UI's button/label "icons" are Unicode GLYPHS (⑂ ✎ ✕ ▶ ◆ 🎲 …), not images. Godot's default font
# carries no symbols/emoji, so absent a bundled fallback those glyphs are supplied by whatever fonts the
# user's OS happens to have — which varies, so some players (even on Windows) get tofu boxes (□) where an
# icon should be. We append these bundled fonts as FALLBACKS on the default font: the Latin typeface is
# unchanged, and only otherwise-missing glyphs pull from them. Drop the .ttf files in res://assets/fonts/
# (see the README there). Missing files no-op — nothing breaks, you just keep depending on the OS.
const GLYPH_FALLBACK_FONTS: Array[String] = [
	"res://assets/fonts/NotoSansSymbols2-Regular.ttf",  # monochrome symbols: ⑂ ✎ ✕ ⚔ ✂ ★ ⬆ ⬇ ⚙ …
	"res://assets/fonts/NotoColorEmoji.ttf",  # colour emoji: 📂 🔥 🎲 🎭 🏁 …
]


func _ready() -> void:
	apply_tooltip_scale()
	_install_glyph_fallbacks()


# Appends the bundled symbol/emoji fonts to the DEFAULT font's fallback chain, so glyph "icons" render
# the same on every machine instead of depending on the player's installed fonts. Runs once at startup,
# before any UI is built. Warns (and no-ops) if the default font can't take fallbacks — in which case set
# Project Settings → gui/theme/custom_font to a FontFile carrying these fallbacks instead. Skips any font
# file not yet added to the project.
func _install_glyph_fallbacks() -> void:
	var base: Font = ThemeDB.fallback_font
	if not (base is FontFile):
		push_warning("UITheme: default font isn't a FontFile; glyph fallbacks not installed.")
		return
	var fonts: Array[Font] = []
	for path: String in GLYPH_FALLBACK_FONTS:
		if ResourceLoader.exists(path):
			var f: Resource = load(path)
			if f is Font:
				fonts.append(f as Font)
	if not fonts.is_empty():
		(base as FontFile).fallbacks = fonts


# Word-wraps tooltip text by inserting newlines — Godot's default tooltip does NOT autowrap, so
# a long one runs off screen. Existing newlines are preserved (each line wrapped independently),
# and a string already under the limit is returned unchanged, so short tooltips are untouched.
# Char-based rather than pixel-based on purpose: a tooltip has no parent to measure against.
func wrap_tip(text: String, max_chars: int = 54) -> String:
	var out: PackedStringArray = []
	for para: String in text.split("\n"):
		if para.length() <= max_chars:
			out.append(para)
			continue
		var line: String = ""
		for word: String in para.split(" "):
			if line == "":
				line = word
			elif line.length() + 1 + word.length() <= max_chars:
				line += " " + word
			else:
				out.append(line)
				line = word
		if line != "":
			out.append(line)
	return "\n".join(out)


# ── Palette ────────────────────────────────────────────────────────────────

# Backgrounds
const BG: Color = Color(0.0, 0.0, 0.0, 1.0)  # #000000
const BG_ZERO: Color = Color(0.0, 0.0, 0.0, 0.0)  # fully transparent black
const PANEL_BG: Color = Color(0.055, 0.008, 0.086, 1.0)  # #0e0216 – flat panels
const PANEL_BG_GAME: Color = Color(0.055, 0.008, 0.086, 0.88)  # HUD-bar variant
const PANEL_BG_DEEP: Color = Color(0.035, 0.005, 0.055, 0.97)  # deeper panel (inventory)
const PANEL_BG_SHOP: Color = Color(0.035, 0.005, 0.055, 0.96)  # shop screen
const PANEL_BG_FORK: Color = Color(0.055, 0.008, 0.086, 0.92)  # fork screen
const CARD_BG: Color = Color(0.02, 0.0, 0.04, 1.0)  # individual cards
const CARD_BG_DIM: Color = Color(0.01, 0.0, 0.02, 1.0)  # disabled cards
const BAR_BG: Color = Color(0.02, 0.004, 0.035, 0.94)  # storyboard bar

# Purple ramp
const PURPLE_DARK: Color = Color(0.176, 0.024, 0.259, 1.0)  # #2d0642
const PURPLE_MID: Color = Color(0.408, 0.063, 0.627, 1.0)  # #6810a0
const PURPLE_BRIGHT: Color = Color(0.698, 0.118, 1.0, 1.0)  # #b21eff

# Accent colors
const MAGENTA: Color = Color(0.878, 0.0, 0.878, 1.0)  # #e000e0
const WHITE_SOFT: Color = Color(0.878, 0.780, 1.0, 1.0)  # #e0c7ff
const AUDIO_TEST_BTN_WIDTH: int = 84  # compact: a utility beside its field, not a section action
const AMBER: Color = Color(1.0, 0.65, 0.15, 1.0)
const TOXIC_GREEN: Color = Color(0.45, 1.0, 0.35, 1.0)
const CYAN: Color = Color(0.10, 0.85, 0.90, 1.0)
const DARK_TEXT: Color = Color(0.55, 0.47, 0.72, 1.0)

# Semantic colors
const SEPARATOR: Color = Color(0.698, 0.118, 1.0, 0.5)
const DANGER: Color = Color(0.9, 0.15, 0.15, 1.0)
const ERROR: Color = Color(1.0, 0.25, 0.05, 1.0)
const ERROR_SOFT: Color = Color(1.0, 0.3, 0.3, 1.0)
const OK: Color = Color(0.35, 0.95, 0.35, 1.0)
const SUCCESS: Color = Color(0.3, 1.0, 0.5, 1.0)

# Aliases for clarity at the call site
const STORYBOARD: Color = Color(0.0, 0.78, 0.88, 1.0)  # used by JourneyBuilder

# Graph view (canvas) extras
const GRID: Color = Color(0.10, 0.04, 0.18, 0.4)
const EDGE: Color = Color(0.55, 0.30, 0.85, 0.85)
const FORK_EDGE: Color = Color(0.88, 0.0, 0.88, 0.85)

# ── Shape ────────────────────────────────────────────────────────────────────
# Standard corner radius for the app's controls and free-floating panels — one knob for UI rounding.
const CORNER_RADIUS: int = 4

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
	s.bg_color = fill
	s.border_color = border
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_width_top = 2
	s.border_width_bottom = 2
	s.content_margin_left = h_pad
	s.content_margin_right = h_pad
	s.content_margin_top = v_pad
	s.content_margin_bottom = v_pad
	s.set_corner_radius_all(CORNER_RADIUS)
	return s


# Full button styling: font colors, size, uppercases text, and applies the
# three-state stylebox (normal/hover/pressed) plus an empty focus rect.
func style_button(
	btn: Button, accent: Color, h_pad: int = 16, v_pad: int = 10, font_size: int = 14
) -> void:
	btn.add_theme_color_override("font_color", accent)
	btn.add_theme_color_override("font_hover_color", WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", BG)
	btn.add_theme_font_size_override("font_size", font_size)
	btn.text = btn.text.to_upper()
	btn.add_theme_stylebox_override("normal", make_btn_style(accent, PURPLE_DARK, h_pad, v_pad))
	btn.add_theme_stylebox_override("hover", make_btn_style(accent, PURPLE_MID, h_pad, v_pad))
	btn.add_theme_stylebox_override("pressed", make_btn_style(accent, accent, h_pad, v_pad))
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


# Compact icon-only button (used by JourneyBuilder rows for ↑ ↓ ✕ etc.).
# A ▶ TEST button wired to its own hidden player: press to hear the clip `read_path` names at the
# volume `read_volume` reports, press again to stop. Lives here rather than in one panel because three
# different editors now offer it and an author should not meet two versions of the same control.
#
# `on_error` reports a missing or unreadable file however the caller shows problems — a status bar in
# the builder's side panel, the button's own label in a full-screen editor. Omitted, failures are
# silent, which is only ever right when the caller has already checked the path.
func make_audio_test_button(
	host: Node, read_path: Callable, read_volume: Callable, on_error: Callable = Callable()
) -> Button:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	host.add_child(player)

	var button: Button = Button.new()
	button.text = "▶ TEST"
	# Compact and shrink-to-fit rather than full width: it is a utility beside the thing it tests, and at
	# panel width in the brightest colour on screen it read as the section's primary action.
	button.size_flags_horizontal = Control.SIZE_SHRINK_END
	button.custom_minimum_size.x = AUDIO_TEST_BTN_WIDTH
	style_button_subtle(button, TOXIC_GREEN, 9, 4, 10)

	var fail: Callable = func(message: String) -> void:
		if on_error.is_valid():
			on_error.call(message)

	button.pressed.connect(
		func() -> void:
			if player.playing:
				player.stop()
				button.text = "▶ TEST"
				return
			var path: String = str(read_path.call()).strip_edges()
			if path == "":
				fail.call("Drop an audio file first.")
				return
			var stream: AudioStream = JourneyAudio.load_from_file(path)
			if stream == null:
				fail.call("Could not read that audio file.")
				return
			player.stream = stream
			player.volume_db = linear_to_db(maxf(0.0001, float(read_volume.call())))
			player.play()
			button.text = "■ STOP"
	)
	# A clip that runs out on its own puts the label back without anyone pressing anything.
	player.finished.connect(func() -> void: button.text = "▶ TEST")
	return button


# The look of one control placed on a background — a checkpoint's SAVE on a campfire, a fork choice on
# a door. ONE function so the builder's arrangement preview and the thing a player clicks cannot drift
# apart: an author arranging against a different appearance than the game draws is the whole class of
# bug this feature is most exposed to.
#
# `backing` on gives it a plate, for a label that has to survive an arbitrary painting behind it. Off
# still gets an outline and a shadowed label, because "no plate" should mean the art shows through, not
# that the control becomes invisible over a bright patch.
func layout_hotspot_style(
	plate: Color, outline: Color, backing: bool, hovered: bool
) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	if backing:
		# The plate is darkened from whatever colour it was given: a control sits UNDER its own label,
		# and a fully saturated fill behind white text is where these stop being readable.
		style.bg_color = Color(
			plate.r * 0.22, plate.g * 0.22, plate.b * 0.22, 0.88 if hovered else 0.78
		)
	else:
		style.bg_color = Color(0, 0, 0, 0.22 if hovered else 0.0)
	style.border_color = outline if hovered else Color(outline.r, outline.g, outline.b, 0.72)
	style.set_border_width_all(3 if hovered else 2)
	style.set_corner_radius_all(CORNER_RADIUS)
	style.set_content_margin_all(6)
	return style


# Dresses a Button as a placed control, hover state included. The label keeps an outline whether or not
# there is a plate — over a photograph, a coloured word on its own is unreadable often enough that the
# outline costs nothing worth saving.
func style_layout_hotspot(
	button: Button, plate: Color, outline: Color, text: Color, backing: bool
) -> void:
	button.add_theme_stylebox_override(
		"normal", layout_hotspot_style(plate, outline, backing, false)
	)
	button.add_theme_stylebox_override("hover", layout_hotspot_style(plate, outline, backing, true))
	button.add_theme_stylebox_override(
		"pressed", layout_hotspot_style(plate, outline, backing, true)
	)
	button.add_theme_stylebox_override("focus", layout_hotspot_style(plate, outline, backing, true))
	# A placed control that cannot be pressed — an unaffordable shop slot, a choice the player has not
	# earned — had no disabled style of its own and fell back to the theme's, which looks identical to
	# the normal one. It read as a button that simply ignored clicks and never lit on hover.
	var dulled: StyleBoxFlat = layout_hotspot_style(
		Color(plate.r * 0.5, plate.g * 0.5, plate.b * 0.5, plate.a),
		outline.darkened(0.45),
		backing,
		false
	)
	dulled.set_border_width_all(1)
	button.add_theme_stylebox_override("disabled", dulled)
	button.add_theme_color_override("font_disabled_color", Color(text.r, text.g, text.b, 0.45))
	button.add_theme_color_override("font_color", text)
	button.add_theme_color_override("font_hover_color", text.lightened(0.25))
	button.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	button.add_theme_constant_override("outline_size", 4)
	button.add_theme_font_size_override("font_size", 14)


func make_icon_btn(icon: String, disabled: bool, accent: Color) -> Button:
	var btn: Button = Button.new()
	btn.text = icon
	btn.custom_minimum_size = Vector2(32, 0)
	btn.disabled = disabled
	btn.add_theme_color_override("font_color", accent)
	btn.add_theme_color_override("font_hover_color", WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.add_theme_stylebox_override("normal", make_btn_style(accent, PURPLE_DARK))
	btn.add_theme_stylebox_override("hover", make_btn_style(accent, PURPLE_MID))
	btn.add_theme_stylebox_override("pressed", make_btn_style(accent, accent))
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return btn


# Subtle/translucent button — a 1px accent border over a faint accent fill that brightens on hover.
# For buttons over video / busy backgrounds (in-game HUD, shop / fork overlays) where the solid button
# is too heavy. Same call shape as style_button, plus a disabled state and optional uppercasing.
func style_button_subtle(
	btn: Button,
	accent: Color,
	h_pad: int = 14,
	v_pad: int = 10,
	font_size: int = 13,
	uppercase: bool = false
) -> void:
	btn.add_theme_color_override("font_color", accent)
	btn.add_theme_color_override("font_hover_color", WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", BG)
	btn.add_theme_font_size_override("font_size", font_size)
	if uppercase:
		btn.text = btn.text.to_upper()

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(accent.r, accent.g, accent.b, 0.12)
	s.border_color = accent
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.content_margin_left = h_pad
	s.content_margin_right = h_pad
	s.content_margin_top = v_pad
	s.content_margin_bottom = v_pad
	s.set_corner_radius_all(CORNER_RADIUS)
	btn.add_theme_stylebox_override("normal", s)

	var s_hover: StyleBoxFlat = s.duplicate()
	s_hover.bg_color = Color(accent.r, accent.g, accent.b, 0.32)
	btn.add_theme_stylebox_override("hover", s_hover)

	var s_pressed: StyleBoxFlat = s.duplicate()
	s_pressed.bg_color = accent
	btn.add_theme_stylebox_override("pressed", s_pressed)

	var s_disabled: StyleBoxFlat = s.duplicate()
	s_disabled.bg_color = Color(accent.r, accent.g, accent.b, 0.04)
	s_disabled.border_color = Color(accent.r, accent.g, accent.b, 0.4)
	btn.add_theme_stylebox_override("disabled", s_disabled)

	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


# Small square ✕ / close button — magenta outline, transparent fill, magenta-tinted hover. Used by the
# slide-in drawers (inventory, quick settings).
func style_close_button(btn: Button) -> void:
	btn.add_theme_color_override("font_color", MAGENTA)
	btn.add_theme_color_override("font_hover_color", WHITE_SOFT)
	btn.add_theme_font_size_override("font_size", 16)
	btn.focus_mode = Control.FOCUS_NONE

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = BG_ZERO
	s.border_color = MAGENTA
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	s.set_corner_radius_all(CORNER_RADIUS)
	btn.add_theme_stylebox_override("normal", s)

	var s_hover: StyleBoxFlat = s.duplicate()
	s_hover.bg_color = Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.25)
	btn.add_theme_stylebox_override("hover", s_hover)

	var s_pressed: StyleBoxFlat = s.duplicate()
	s_pressed.bg_color = MAGENTA
	btn.add_theme_stylebox_override("pressed", s_pressed)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


# LineEdit styling: purple-dark fill, mid-purple border, bright caret/focus.
func style_line_edit(line_edit: LineEdit) -> void:
	line_edit.add_theme_color_override("font_color", WHITE_SOFT)
	line_edit.add_theme_color_override("font_placeholder_color", PURPLE_MID)
	line_edit.add_theme_color_override("caret_color", PURPLE_BRIGHT)
	line_edit.add_theme_font_size_override("font_size", 14)
	var normal_style: StyleBoxFlat = StyleBoxFlat.new()
	normal_style.bg_color = PURPLE_DARK
	normal_style.border_color = PURPLE_MID
	normal_style.border_width_left = 2
	normal_style.border_width_right = 2
	normal_style.border_width_top = 2
	normal_style.border_width_bottom = 2
	normal_style.content_margin_left = 10
	normal_style.content_margin_right = 10
	normal_style.content_margin_top = 8
	normal_style.content_margin_bottom = 8
	normal_style.set_corner_radius_all(CORNER_RADIUS)
	line_edit.add_theme_stylebox_override("normal", normal_style)
	var focus_style: StyleBoxFlat = normal_style.duplicate()
	focus_style.border_color = PURPLE_BRIGHT
	line_edit.add_theme_stylebox_override("focus", focus_style)


# SpinBox styling — reuses the line-edit look for the editable field so numeric
# inputs match the rest of the panel.
func style_spin_box(spin: SpinBox) -> void:
	spin.add_theme_color_override("font_color", WHITE_SOFT)
	spin.add_theme_font_size_override("font_size", 14)
	var le: LineEdit = spin.get_line_edit()
	if le != null:
		style_line_edit(le)
		# Commit typed text when focus leaves, not only on Enter — otherwise clicking away
		# from a field silently discards the edit. Deliberately NOT update_on_text_changed:
		# that re-clamps on every keystroke, so a field with min_value > 1 rewrites the text
		# mid-type ("1" → "2" → next digit gives "20").
		le.focus_exited.connect(func() -> void: spin.apply())
		# Also commit on teardown. focus_exited alone isn't enough: clicking the graph canvas
		# doesn't take focus, so the field keeps it — and selecting a node then rebuilds the
		# side panel, freeing a still-focused spin box with its edit uncommitted.
		spin.tree_exiting.connect(func() -> void: spin.apply())


# TextEdit styling (multi-line).
func style_text_edit(text_edit: TextEdit) -> void:
	text_edit.add_theme_color_override("font_color", WHITE_SOFT)
	text_edit.add_theme_color_override("caret_color", PURPLE_BRIGHT)
	text_edit.add_theme_font_size_override("font_size", 13)
	var normal_style: StyleBoxFlat = StyleBoxFlat.new()
	normal_style.bg_color = PURPLE_DARK
	normal_style.border_color = PURPLE_MID
	normal_style.border_width_left = 2
	normal_style.border_width_right = 2
	normal_style.border_width_top = 2
	normal_style.border_width_bottom = 2
	normal_style.content_margin_left = 10
	normal_style.content_margin_right = 10
	normal_style.content_margin_top = 8
	normal_style.content_margin_bottom = 8
	normal_style.set_corner_radius_all(CORNER_RADIUS)
	text_edit.add_theme_stylebox_override("normal", normal_style)
	var focus_style: StyleBoxFlat = normal_style.duplicate()
	focus_style.border_color = PURPLE_BRIGHT
	text_edit.add_theme_stylebox_override("focus", focus_style)


# OptionButton (dropdown) styling.
func style_option_button(option_button: OptionButton) -> void:
	_apply_dropdown_style(option_button)


# Same dark, purple-bordered dropdown look for a MenuButton (e.g. the MultiSelectDropdown component).
func style_menu_button(menu_button: MenuButton) -> void:
	_apply_dropdown_style(menu_button)


# The shared dropdown look — applies to any Button (OptionButton / MenuButton) via Button-level overrides.
func _apply_dropdown_style(btn: Button) -> void:
	btn.add_theme_color_override("font_color", WHITE_SOFT)
	btn.add_theme_color_override("font_hover_color", PURPLE_BRIGHT)
	btn.add_theme_font_size_override("font_size", 14)
	var normal_style: StyleBoxFlat = StyleBoxFlat.new()
	normal_style.bg_color = PURPLE_DARK
	normal_style.border_color = PURPLE_MID
	normal_style.border_width_left = 2
	normal_style.border_width_right = 2
	normal_style.border_width_top = 2
	normal_style.border_width_bottom = 2
	normal_style.content_margin_left = 10
	normal_style.content_margin_right = 10
	normal_style.content_margin_top = 8
	normal_style.content_margin_bottom = 8
	normal_style.set_corner_radius_all(CORNER_RADIUS)
	btn.add_theme_stylebox_override("normal", normal_style)
	var hover_style: StyleBoxFlat = normal_style.duplicate()
	hover_style.border_color = PURPLE_BRIGHT
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


# Read-only tag chip: a small rounded pill, `text` in `accent`, on a near-opaque
# dark background with an `accent` border. The dark fill keeps the chip legible
# when overlaid on bright/busy cover art, not just on dark panels.
func make_tag_chip(text: String, accent: Color) -> Control:
	var chip: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0.03, 0.0, 0.05, 0.9)
	s.border_color = accent
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 2
	s.content_margin_bottom = 2
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
	s.content_margin_top = 1
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
	panel_size: Vector2i = Vector2i(720, 520),
	backdrop_alpha: float = 0.85
) -> Dictionary:
	var modal: Control = Control.new()
	modal.anchor_right = 1.0
	modal.anchor_bottom = 1.0
	modal.mouse_filter = Control.MOUSE_FILTER_STOP
	# So the journey builder can tell a modal is open and swallow stray OS file drops (which arrive via a
	# viewport signal that ignores mouse_filter) instead of bulk-importing rounds behind the modal.
	modal.add_to_group("ui_modal")

	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, backdrop_alpha)
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	modal.add_child(backdrop)

	var panel: PanelContainer = PanelContainer.new()
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = PANEL_BG
	panel_style.border_color = accent
	panel_style.border_width_left = 2
	panel_style.border_width_right = 2
	panel_style.border_width_top = 2
	panel_style.border_width_bottom = 2
	panel_style.content_margin_left = 28
	panel_style.content_margin_right = 28
	panel_style.content_margin_top = 22
	panel_style.content_margin_bottom = 22
	panel_style.set_corner_radius_all(CORNER_RADIUS)
	panel.add_theme_stylebox_override("panel", panel_style)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	var half_w: int = panel_size.x / 2
	var half_h: int = panel_size.y / 2
	panel.offset_left = -half_w
	panel.offset_right = half_w
	panel.offset_top = -half_h
	panel.offset_bottom = half_h
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
		"vbox": vbox,
		"title": title_lbl,
	}
