extends Control

# ---------------------------------------------------------------------------
# Main.gd  –  Main menu controller
# Purple matrix theme. Title + buttons enclosed in an opaque panel with a
# neon-sign glowing border that occasionally flickers.
# ---------------------------------------------------------------------------

const FONT_SIZE_EYEBROW: int = 12
const FONT_SIZE_TITLE: int = 54
const FONT_SIZE_SUBTITLE: int = 24
const FONT_SIZE_BUTTON: int = 17
const FONT_SIZE_TAGLINE: int = 12

const BUTTON_MIN_WIDTH: int = 280
const BUTTON_MIN_HEIGHT: int = 52

const PANEL_PADDING_H: int = 48
const PANEL_PADDING_V: int = 40
const BORDER_WIDTH: int = 3

const BLINK_INTERVAL: float = 0.85

const FLICKER_INTERVAL_MIN: float = 3.5
const FLICKER_INTERVAL_MAX: float = 7.0
const FLICKER_DURATION: float = 0.08

@onready var _bg: ColorRect = $Background
@onready var _panel: PanelContainer = $Panel
@onready var _center: VBoxContainer = $Panel/CenterContainer
@onready var _title_section: VBoxContainer = $Panel/CenterContainer/TitleSection
@onready var _eyebrow: Label = $Panel/CenterContainer/TitleSection/Eyebrow
@onready var _title: Label = $Panel/CenterContainer/TitleSection/TitleLabel
@onready var _subtitle: Label = $Panel/CenterContainer/TitleSection/SubtitleLabel
@onready var _divider: HSeparator = $Panel/CenterContainer/TitleSection/TitleDivider
@onready var _button_container: VBoxContainer = $Panel/CenterContainer/ButtonContainer
@onready var _start_btn: Button = $Panel/CenterContainer/ButtonContainer/StartButton
@onready var _randomize_btn: Button = $Panel/CenterContainer/ButtonContainer/RandomizeButton
@onready var _options_btn: Button = $Panel/CenterContainer/ButtonContainer/OptionsButton
@onready var _build_btn: Button = $Panel/CenterContainer/ButtonContainer/BuildButton
@onready var _quit_btn: Button = $Panel/CenterContainer/ButtonContainer/QuitButton
@onready var _tagline: Label = $Panel/CenterContainer/TaglineLabel

var _blink_timer: float = 0.0
var _blink_visible: bool = true
var _flicker_timer: float = 0.0
var _flicker_next: float = 0.0
var _flickering: bool = false
var _flicker_elapsed: float = 0.0
var _border_alpha: float = 1.0

# Plays the entrance animation only once per app session — replaying it on every
# return to the menu gets tiresome. Static, so it survives scene reloads but
# resets on app restart ("first startup").
static var _intro_played: bool = false

# True once the entrance animation has finished — gates the tagline blink and
# button hover effects so they don't fight the intro tweens.
var _intro_done: bool = false
# Per-button hover scale tween, so a fast re-hover replaces rather than stacks.
var _btn_tweens: Dictionary = {}


func _ready() -> void:
	MusicService.play()
	_flicker_next = randf_range(FLICKER_INTERVAL_MIN, FLICKER_INTERVAL_MAX)
	_apply_layout()
	_apply_theme()
	_connect_buttons()
	_setup_version_label()
	_check_for_update()
	if _intro_played:
		# Already played this session — show the menu fully formed.
		_intro_done = true
	else:
		_intro_played = true
		_play_intro()


func _process(delta: float) -> void:
	# Tagline blink — held off until the entrance animation finishes (the intro
	# owns the tagline's alpha until then).
	if _intro_done:
		_blink_timer += delta
		if _blink_timer >= BLINK_INTERVAL:
			_blink_timer = 0.0
			_blink_visible = not _blink_visible
			var c: Color = _tagline.modulate
			c.a = 1.0 if _blink_visible else 0.0
			_tagline.modulate = c

	# Neon border flicker
	_flicker_timer += delta
	if not _flickering and _flicker_timer >= _flicker_next:
		_flickering = true
		_flicker_elapsed = 0.0
		_flicker_timer = 0.0
		_flicker_next = randf_range(FLICKER_INTERVAL_MIN, FLICKER_INTERVAL_MAX)

	if _flickering:
		_flicker_elapsed += delta
		_border_alpha = 0.15 if _flicker_elapsed < FLICKER_DURATION * 0.5 else 1.0
		if _flicker_elapsed >= FLICKER_DURATION:
			_flickering = false
			_border_alpha = 1.0
		_update_panel_border()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------


func _apply_layout() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	_bg.anchor_left = 0.0
	_bg.anchor_top = 0.0
	_bg.anchor_right = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = 0
	_bg.offset_top = 0
	_bg.offset_right = 0
	_bg.offset_bottom = 0

	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	_center.add_theme_constant_override("separation", 36)

	_title_section.add_theme_constant_override("separation", 6)
	_title_section.alignment = BoxContainer.ALIGNMENT_CENTER

	_button_container.add_theme_constant_override("separation", 14)
	_button_container.alignment = BoxContainer.ALIGNMENT_CENTER

	for btn: Button in [_start_btn, _options_btn, _build_btn, _quit_btn]:
		btn.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, BUTTON_MIN_HEIGHT)


# Pins a subtle version label to the bottom-right corner. Read from
# project.godot (application/config/version) so it tracks the real build version.
# Added directly to the root (not the panel) so it stays out of the intro tweens.
func _setup_version_label() -> void:
	var version: String = str(ProjectSettings.get_setting("application/config/version", ""))
	if version == "":
		return
	var ver_lbl: Label = Label.new()
	ver_lbl.text = "v" + version
	ver_lbl.add_theme_color_override("font_color", UITheme.PURPLE_TEXT)
	ver_lbl.add_theme_font_size_override("font_size", 12)
	ver_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ver_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchor to the bottom-right corner, growing up/left from it.
	ver_lbl.anchor_left = 1.0
	ver_lbl.anchor_top = 1.0
	ver_lbl.anchor_right = 1.0
	ver_lbl.anchor_bottom = 1.0
	ver_lbl.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ver_lbl.grow_vertical = Control.GROW_DIRECTION_BEGIN
	ver_lbl.offset_left = -160
	ver_lbl.offset_top = -30
	ver_lbl.offset_right = -14
	ver_lbl.offset_bottom = -10
	add_child(ver_lbl)


# ---------------------------------------------------------------------------
# Update check (Phase 1 — notify only)
# ---------------------------------------------------------------------------


# Best-effort GitHub release check (once per session — UpdateService caches the
# result). The banner appears only if a newer build exists; failures are silent.
# On returning to the menu, re-shows the banner from cache without re-checking.
func _check_for_update() -> void:
	if UpdateService.has_update():
		_show_update_banner(UpdateService.available_version)
	elif not UpdateService.checked() and SettingsService.get_update_check_enabled():
		UpdateService.update_available.connect(_on_update_available, CONNECT_ONE_SHOT)
		UpdateService.check_for_update()


func _on_update_available(latest_version: String, _release: Dictionary) -> void:
	_show_update_banner(latest_version)


# A subtle top-center banner; clicking opens the release page. (A later phase
# swaps the click for an in-app download.) Added to the root so it sits above the
# panel and outside the intro tweens.
func _show_update_banner(latest_version: String) -> void:
	var banner: Button = Button.new()
	banner.text = "▲  UPDATE AVAILABLE  —  v%s" % latest_version
	banner.tooltip_text = "Opens the release page in your browser"
	banner.focus_mode = Control.FOCUS_NONE
	banner.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	banner.add_theme_color_override("font_hover_color", UITheme.WHITE_SOFT)
	banner.add_theme_font_size_override("font_size", 13)

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.18)
	s.border_color = UITheme.MAGENTA
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.set_corner_radius_all(UITheme.CORNER_RADIUS)
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	banner.add_theme_stylebox_override("normal", s)
	var s_hover: StyleBoxFlat = s.duplicate()
	s_hover.bg_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.34)
	banner.add_theme_stylebox_override("hover", s_hover)
	banner.add_theme_stylebox_override("pressed", s_hover)
	banner.add_theme_stylebox_override("focus", UITheme.focus_ring_style())

	# Pinned to top-centre, sizing to its content.
	banner.anchor_left = 0.5
	banner.anchor_right = 0.5
	banner.anchor_top = 0.0
	banner.anchor_bottom = 0.0
	banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	banner.offset_top = 18
	banner.pressed.connect(_open_update_modal)

	banner.modulate.a = 0.0
	add_child(banner)
	create_tween().tween_property(banner, "modulate:a", 1.0, 0.4)


# The update flow: download the platform build, verify, extract into a sibling
# folder, and reveal it. The running app is never overwritten — the user launches
# the new folder and deletes the old one.
func _open_update_modal() -> void:
	var parts: Dictionary = UITheme.build_centered_modal(
		"UPDATE  —  v%s" % UpdateService.available_version, UITheme.MAGENTA, Vector2i(580, 400)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	vbox.add_theme_constant_override("separation", 16)

	var status: Label = Label.new()
	status.text = "A newer version is available. It'll download and extract into a new folder next to your current install — then close this and run the new one."
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	status.add_theme_font_size_override("font_size", 13)
	vbox.add_child(status)

	var bar: ProgressBar = ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 16)
	bar.min_value = 0
	bar.max_value = 100
	bar.value = 0
	bar.visible = false
	vbox.add_child(bar)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 14)
	vbox.add_child(btn_row)

	var dl_btn: Button = Button.new()
	dl_btn.text = "⬇  DOWNLOAD"
	var notes_btn: Button = Button.new()
	notes_btn.text = "RELEASE NOTES"
	var close_btn: Button = Button.new()
	close_btn.text = "CLOSE"
	for b: Button in [dl_btn, notes_btn, close_btn]:
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(150, 0)
		_style_button(b, UITheme.MAGENTA)
		btn_row.add_child(b)

	notes_btn.pressed.connect(func() -> void: OS.shell_open(UpdateService.release_url()))
	close_btn.pressed.connect(modal.queue_free)

	var on_progress: Callable = func(got: int, total: int) -> void:
		bar.visible = true
		if total > 0:
			bar.value = clampf(float(got) / float(total) * 100.0, 0.0, 100.0)
			status.text = "Downloading…  %d%%  (%.1f MB)" % [int(bar.value), got / 1048576.0]
		else:
			status.text = "Downloading…  %.1f MB" % (got / 1048576.0)

	var drop_progress: Callable = func() -> void:
		if UpdateService.download_progress.is_connected(on_progress):
			UpdateService.download_progress.disconnect(on_progress)

	var on_ready: Callable = func(folder: String) -> void:
		drop_progress.call()
		bar.value = 100
		status.text = (
			"Update ready — its folder has been opened:\n%s\n\nClose this app and run the new version there, then delete the old folder."
			% folder
		)
		dl_btn.visible = false
		close_btn.pressed.disconnect(modal.queue_free)
		close_btn.text = "QUIT"
		close_btn.pressed.connect(get_tree().quit)

	var on_failed: Callable = func(reason: String) -> void:
		drop_progress.call()
		bar.visible = false
		status.text = "Update failed: %s" % reason
		dl_btn.disabled = false
		notes_btn.disabled = false

	dl_btn.pressed.connect(
		func() -> void:
			dl_btn.disabled = true
			notes_btn.disabled = true
			bar.visible = true
			status.text = "Starting download…"
			UpdateService.download_progress.connect(on_progress)
			UpdateService.download_ready.connect(on_ready, CONNECT_ONE_SHOT)
			UpdateService.download_failed.connect(on_failed, CONNECT_ONE_SHOT)
			UpdateService.download_and_stage()
	)

	# Closing mid-download drops the progress hook (the download itself finishes
	# in the autoload regardless).
	modal.tree_exiting.connect(drop_progress)

	add_child(modal)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------


func _apply_theme() -> void:
	_bg.color = UITheme.BG
	_update_panel_border()

	_style_label(_eyebrow, UITheme.MAGENTA, FONT_SIZE_EYEBROW, true)
	_style_label(_title, UITheme.PURPLE_BRIGHT, FONT_SIZE_TITLE, true)
	_style_label(_subtitle, UITheme.MAGENTA, FONT_SIZE_SUBTITLE, true)

	var sep: StyleBoxFlat = StyleBoxFlat.new()
	sep.bg_color = UITheme.SEPARATOR
	sep.content_margin_top = 1
	sep.content_margin_bottom = 1
	_divider.add_theme_stylebox_override("separator", sep)

	_style_button(_start_btn, UITheme.PURPLE_BRIGHT)
	_style_button(_randomize_btn, UITheme.CYAN)
	_style_button(_options_btn, UITheme.MAGENTA)
	_style_button(_build_btn, UITheme.PURPLE_MID)
	_style_button(_quit_btn, UITheme.PURPLE_MID)

	_style_label(_tagline, UITheme.PURPLE_BRIGHT, FONT_SIZE_TAGLINE, true)


func _update_panel_border() -> void:
	var border_col: Color = Color(
		UITheme.PURPLE_BRIGHT.r, UITheme.PURPLE_BRIGHT.g, UITheme.PURPLE_BRIGHT.b, _border_alpha
	)
	var shadow_col: Color = Color(
		UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, _border_alpha * 0.5
	)

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.PANEL_BG
	s.border_color = border_col
	s.border_width_left = BORDER_WIDTH
	s.border_width_right = BORDER_WIDTH
	s.border_width_top = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left = 4
	s.corner_radius_top_right = 4
	s.corner_radius_bottom_left = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color = shadow_col
	s.shadow_size = 12
	s.content_margin_left = PANEL_PADDING_H
	s.content_margin_right = PANEL_PADDING_H
	s.content_margin_top = PANEL_PADDING_V
	s.content_margin_bottom = PANEL_PADDING_V
	_panel.add_theme_stylebox_override("panel", s)


# Thin delegates to UITheme — the canonical styling lives there. Args preserve this screen's padding/font.
func _style_label(label: Label, color: Color, size: int, uppercase: bool = false) -> void:
	UITheme.style_label(label, color, size, uppercase)


func _style_button(btn: Button, accent: Color) -> void:
	UITheme.style_button(btn, accent, 20, 12, FONT_SIZE_BUTTON)


# ---------------------------------------------------------------------------
# Button signals
# ---------------------------------------------------------------------------


func _connect_buttons() -> void:
	_start_btn.pressed.connect(_on_start_pressed)
	_randomize_btn.pressed.connect(_on_randomize_pressed)
	_options_btn.pressed.connect(_on_options_pressed)
	_build_btn.pressed.connect(_on_build_pressed)
	_quit_btn.pressed.connect(_on_quit_pressed)
	for btn: Button in [_start_btn, _randomize_btn, _options_btn, _build_btn, _quit_btn]:
		btn.mouse_entered.connect(_hover_btn.bind(btn, true))
		btn.mouse_exited.connect(_hover_btn.bind(btn, false))


# ---------------------------------------------------------------------------
# Entrance animation + hover
# ---------------------------------------------------------------------------


# Staged entrance: the title section pops in, the buttons cascade up one at a
# time, then the tagline fades in. Buttons are locked until it finishes.
func _play_intro() -> void:
	var btns: Array = [_start_btn, _randomize_btn, _options_btn, _build_btn, _quit_btn]
	_title_section.modulate.a = 0.0
	_tagline.modulate.a = 0.0
	for btn: Button in btns:
		btn.modulate.a = 0.0
		btn.disabled = true

	# Let layout settle (for scale pivots) and the scene transition clear.
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout

	# Title section — fade + pop.
	_title_section.pivot_offset = _title_section.size / 2.0
	_title_section.scale = Vector2(0.85, 0.85)
	var t1: Tween = create_tween().set_parallel()
	t1.tween_property(_title_section, "modulate:a", 1.0, 0.30)
	(
		t1
		. tween_property(_title_section, "scale", Vector2.ONE, 0.40)
		. set_ease(Tween.EASE_OUT)
		. set_trans(Tween.TRANS_BACK)
	)
	await t1.finished

	# Buttons — cascade up.
	for i: int in btns.size():
		var b: Button = btns[i]
		b.pivot_offset = b.size / 2.0
		b.scale = Vector2(0.9, 0.9)
		var bt: Tween = create_tween().set_parallel()
		bt.tween_property(b, "modulate:a", 1.0, 0.25).set_delay(i * 0.07)
		(
			bt
			. tween_property(b, "scale", Vector2.ONE, 0.30)
			. set_delay(i * 0.07)
			. set_ease(Tween.EASE_OUT)
			. set_trans(Tween.TRANS_BACK)
		)
	await get_tree().create_timer(0.30 + btns.size() * 0.07).timeout

	# Tagline.
	create_tween().tween_property(_tagline, "modulate:a", 1.0, 0.30)

	for btn: Button in btns:
		btn.disabled = false
	_intro_done = true


# Smoothly scales a menu button on hover. Ignored until the intro finishes so
# it never competes with the cascade tweens.
func _hover_btn(btn: Button, hovering: bool) -> void:
	if not _intro_done:
		return
	var prev: Tween = _btn_tweens.get(btn)
	if prev != null and prev.is_running():
		prev.kill()
	btn.pivot_offset = btn.size / 2.0
	var tw: Tween = create_tween()
	(
		tw
		. tween_property(btn, "scale", Vector2(1.04, 1.04) if hovering else Vector2.ONE, 0.10)
		. set_ease(Tween.EASE_OUT)
		. set_trans(Tween.TRANS_CUBIC)
	)
	_btn_tweens[btn] = tw


func _on_start_pressed() -> void:
	Transition.change_scene("res://scenes/journey_select/JourneySelect.tscn")


func _on_randomize_pressed() -> void:
	Transition.change_scene("res://scenes/randomizer/Randomizer.tscn")


func _on_options_pressed() -> void:
	Transition.change_scene("res://scenes/options/Options.tscn")


func _on_build_pressed() -> void:
	Transition.change_scene("res://scenes/journey_builder/JourneyBuilder.tscn")


func _on_quit_pressed() -> void:
	get_tree().quit()
