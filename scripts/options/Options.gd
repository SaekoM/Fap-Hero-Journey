extends Control

# ---------------------------------------------------------------------------
# Options.gd
# Purple matrix theme. Audio, display, and Intiface/Buttplug settings.
# Reads/writes all settings through the SettingsService autoload.
# ---------------------------------------------------------------------------

const TOP_BAR_HEIGHT: int = 64
const TAB_BAR_HEIGHT: int = 48
const PANEL_HALF_W: int = 480
const PANEL_PAD_V: int = 24
const BORDER_WIDTH: int = 3
const ROW_LABEL_W: int = 260
const SLIDER_MIN_W: int = 260
const VALUE_LABEL_W: int = 64

# Tab categories. Each groups a set of sections; only one tab is shown at a time.
const TAB_NAMES: Array = ["GENERAL", "CONNECTION", "DEVICE", "ABOUT"]

const DEFAULT_BP_ADDRESS: String = "ws://localhost:12345"
const DEFAULT_BAUD_RATE: int = 115200

const RESOLUTIONS: Array = [
	Vector2i(1280, 720),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]

@onready var _bg: ColorRect = $Background
@onready var _top_bar: HBoxContainer = $TopBar
@onready var _back_btn: Button = $TopBar/BackButton
@onready var _title_lbl: Label = $TopBar/TitleLabel
@onready var _content_panel: PanelContainer = $ContentPanel
@onready var _content_vbox: VBoxContainer = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox
@onready
var _master_slider: HSlider = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow/MasterSlider
@onready
var _master_value: Label = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow/MasterValue
@onready
var _fs_toggle: Button = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/FullscreenRow/FsToggle
@onready
var _res_dropdown: OptionButton = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/ResolutionRow/ResDropdown
@onready
var _address_input: LineEdit = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AddressRow/AddressInput
@onready
var _auto_toggle: Button = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AutoConnectRow/AutoConnectToggle
@onready
var _connect_btn: Button = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/ConnectBtn
@onready
var _scan_btn: Button = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/ScanBtn
@onready
var _status_lbl: Label = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/StatusLabel
@onready
var _device_dropdown: OptionButton = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/DeviceRow/DeviceDropdown
@onready
var _bp_test_btn: Button = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/BpTestBtn

@onready
var _open_folder_btn: Button = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/JourneysSection/JourneysRow/OpenFolderBtn

# Built dynamically in _build_journey_location_row(). The path label shows the
# current storage location and updates when the user picks a new folder.
var _journeys_path_label: Label = null
var _journeys_browse_btn: Button = null
var _journeys_reset_btn: Button = null

# Built dynamically in _build_transcode_section().
var _ffmpeg_path_label: Label = null
var _ffmpeg_status_label: Label = null
var _auto_transcode_toggle: Button = null

@onready
var _serial_port_dropdown: OptionButton = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialPortRow/SerialPortDropdown
@onready
var _serial_refresh_btn: Button = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialPortRow/SerialRefreshBtn
@onready
var _serial_baud_input: LineEdit = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialBaudRow/SerialBaudInput
@onready
var _serial_auto_toggle: Button = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialAutoRow/SerialAutoToggle
@onready
var _serial_connect_btn: Button = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialConnRow/SerialConnectBtn
@onready
var _serial_test_btn: Button = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialConnRow/SerialTestBtn
@onready
var _serial_status_lbl: Label = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialConnRow/SerialStatusLabel

var _is_connected: bool = false
var overlay_mode: bool = false
var _loading: bool = false

var _music_slider: HSlider = null
var _music_value_lbl: Label = null

var _range_slider: RangeSlider = null
var _range_min_lbl: Label = null
var _range_max_lbl: Label = null

# Secondary positional axes (T-code id, human name) — each gets its own range row.
const SECONDARY_AXES: Array = [
	["L1", "Surge"],
	["L2", "Sway"],
	["R0", "Twist"],
	["R1", "Roll"],
	["R2", "Pitch"],
]
var _axis_range_sliders: Dictionary = {}  # axis id → RangeSlider
var _axis_range_min_lbls: Dictionary = {}  # axis id → MIN Label
var _axis_range_max_lbls: Dictionary = {}  # axis id → MAX Label

var _home_slider: HSlider = null
var _home_value_lbl: Label = null
var _home_ease_input: LineEdit = null

var _vibe_slider: HSlider = null
var _vibe_value_lbl: Label = null
var _max_speed_slider: HSlider = null
var _max_speed_value_lbl: Label = null
var _hud_delay_slider: HSlider = null
var _hud_delay_value_lbl: Label = null
var _sensory_slider: HSlider = null
var _sensory_value_lbl: Label = null
var _ui_scale_slider: HSlider = null
var _ui_scale_value_lbl: Label = null
var _beat_bar_toggle: Button = null
var _beat_shape_dd: OptionButton = null
var _round_timer_toggle: Button = null
var _story_text_slider: HSlider = null
var _story_text_value_lbl: Label = null
var _tooltip_text_slider: HSlider = null
var _tooltip_text_value_lbl: Label = null
var _handy_status_lbl: Label = null
var _update_check_toggle: Button = null
var _ui_sound_toggle: Button = null
var _ui_sound_slider: HSlider = null
var _ui_sound_value_lbl: Label = null

var _filler_toggle: Button = null
var _filler_speed_input: LineEdit = null
var _filler_range_slider: RangeSlider = null
var _filler_range_min_lbl: Label = null
var _filler_range_max_lbl: Label = null

# Tab bar + references to the three code-built sections, needed so tab
# switching can toggle their visibility alongside the scene-built sections.
var _tab_bar: TabBar = null
var _range_section: VBoxContainer = null
var _filler_section: VBoxContainer = null

# Device-routing section (built in code) — device cards + per-actuator source assignment.
var _routing_section: VBoxContainer = null
var _routing_cards_vbox: VBoxContainer = null
var _handy_section: VBoxContainer = null  # The Handy (WiFi) connection block — lives on the CONNECTION tab
var _stroker_summary_lbl: Label = null
var _serial_delay_slider: HSlider = null
var _serial_delay_lbl: Label = null
var _serial_interp_slider: HSlider = null
var _serial_interp_lbl: Label = null
var _intiface_delay_slider: HSlider = null
var _intiface_delay_lbl: Label = null
var _transcode_section: VBoxContainer = null
var _credits_section: VBoxContainer = null

# restim (e-stim), split across two tabs: the connection block (server/path/
# auto-connect) sits on CONNECTION next to the other transports, while the
# per-axis levels are device tuning and live on DEVICE beside the T-code ranges.
var _restim_section: VBoxContainer = null
var _restim_axes_section: VBoxContainer = null
var _restim_server_input: LineEdit = null
var _restim_path_input: LineEdit = null
var _restim_auto_toggle: Button = null
var _restim_connect_btn: Button = null
var _restim_status_lbl: Label = null
var _restim_axis_sliders: Dictionary = {}  # axis id → HSlider
var _restim_axis_value_lbls: Dictionary = {}  # axis id → value Label

# The 18 "E-Stim Full" axes, grouped for the UI. [axis id, friendly label].
# Motion axes (L0/L1/C0/P0/V1/V2) note their driving funscript; those sliders are the
# fallback used only when the round has no such script.
const RESTIM_AXIS_GROUPS: Array = [
	["MASTER", [["V0", "Volume"]]],
	["POSITION", [["L0", "Alpha ← stroke"], ["L1", "Beta ← surge"]]],
	["CARRIER", [["C0", "Carrier freq ← twist"]]],
	[
		"PULSE",
		[
			["P0", "Pulse freq ← pitch"],
			["P1", "Pulse width"],
			["P2", "Pulse interval random"],
			["P3", "Pulse rise time"],
		]
	],
	[
		"VIBRATION 1",
		[
			["V1", "Vib1 freq ← sway"],
			["V2", "Vib1 strength ← roll"],
			["V3", "Vib1 random"],
			["V6", "Vib1 L/R bias"],
			["V7", "Vib1 up/down bias"],
		]
	],
	[
		"VIBRATION 2",
		[
			["V4", "Vib2 freq"],
			["V5", "Vib2 strength"],
			["W1", "Vib2 random"],
			["V8", "Vib2 L/R bias"],
			["V9", "Vib2 up/down bias"],
		]
	],
]


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_populate_resolution_dropdown()
	_refresh_serial_ports()
	_load_settings()
	_connect_signals()
	_sync_buttplug_state()
	_sync_serial_state()


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
	_top_bar.add_theme_constant_override("separation", 0)

	_content_panel.anchor_left = 0.5
	_content_panel.anchor_right = 0.5
	_content_panel.anchor_top = 0.0
	_content_panel.anchor_bottom = 1.0
	_content_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_content_panel.offset_left = -PANEL_HALF_W
	_content_panel.offset_right = PANEL_HALF_W
	_content_panel.offset_top = TOP_BAR_HEIGHT + TAB_BAR_HEIGHT + PANEL_PAD_V
	_content_panel.offset_bottom = -PANEL_PAD_V

	($ContentPanel/ContentScroll/MarginWrapper as MarginContainer).add_theme_constant_override(
		"margin_right", 24
	)

	# Wider inter-section spacing — the old fixed gap spacer nodes are hidden
	# below now that each tab shows only a few sections at a time.
	_content_vbox.add_theme_constant_override("separation", 28)

	for section_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/JourneysSection",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/OutputSection",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection",
	]:
		var section: VBoxContainer = get_node(section_path)
		section.add_theme_constant_override("separation", 12)

	for row_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/JourneysSection/JourneysRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/OutputSection/OutputModeRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/FullscreenRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/ResolutionRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AddressRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AutoConnectRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/DeviceRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialPortRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialBaudRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialAutoRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialConnRow",
	]:
		var row: HBoxContainer = get_node(row_path)
		row.add_theme_constant_override("separation", 16)

	# Hide the fixed gap spacers — sections are now grouped into tabs, so the
	# old single-scroll inter-section padding is no longer needed.
	for gap_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/JourneysGap",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/OutputGap",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SectionGap",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SectionGap2",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialGap",
	]:
		(get_node(gap_path) as Control).visible = false

	var master_lbl: Label = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow/MasterLabel
	master_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_master_slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	_master_value.custom_minimum_size = Vector2(VALUE_LABEL_W, 0)

	# ── Music Volume row (code-generated, appended to AudioSection) ───────────
	var audio_section: VBoxContainer = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection
	var music_row: HBoxContainer = HBoxContainer.new()
	music_row.add_theme_constant_override("separation", 16)
	audio_section.add_child(music_row)

	var music_lbl: Label = Label.new()
	music_lbl.text = "Music Volume"
	music_lbl.text = music_lbl.text.to_upper()
	music_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(music_lbl, UITheme.WHITE_SOFT, 14, false)
	music_row.add_child(music_lbl)

	_music_slider = HSlider.new()
	_music_slider.min_value = 0.0
	_music_slider.max_value = 1.0
	_music_slider.step = 0.01
	_music_slider.value = 0.5
	_music_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_music_slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	_style_slider(_music_slider)
	music_row.add_child(_music_slider)

	_music_value_lbl = Label.new()
	_music_value_lbl.text = "50%"
	_music_value_lbl.custom_minimum_size = Vector2(VALUE_LABEL_W, 0)
	_style_label(_music_value_lbl, UITheme.PURPLE_BRIGHT, 14, false)
	music_row.add_child(_music_value_lbl)

	_music_slider.value_changed.connect(
		func(v: float) -> void:
			_music_value_lbl.text = "%d%%" % roundi(v * 100.0)
			MusicService.set_volume(v)
			_save_settings()
	)

	# ── UI Sounds toggle (code-generated, appended to AudioSection) ───────────
	var ui_sound_row: HBoxContainer = HBoxContainer.new()
	ui_sound_row.add_theme_constant_override("separation", 16)
	audio_section.add_child(ui_sound_row)

	var ui_sound_lbl: Label = Label.new()
	ui_sound_lbl.text = "UI SOUNDS"
	ui_sound_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_label(ui_sound_lbl, UITheme.WHITE_SOFT, 14, false)
	ui_sound_row.add_child(ui_sound_lbl)

	_ui_sound_toggle = Button.new()
	_ui_sound_toggle.toggle_mode = true
	_ui_sound_toggle.focus_mode = Control.FOCUS_NONE
	_style_toggle(_ui_sound_toggle, false)
	ui_sound_row.add_child(_ui_sound_toggle)
	_ui_sound_toggle.toggled.connect(
		func(pressed: bool) -> void:
			_style_toggle(_ui_sound_toggle, pressed)
			_save_settings()
			if pressed:
				UISound.confirm()  # audible cue when enabling (disabling is cued by the click itself)
	)

	var ui_sound_hint: Label = Label.new()
	ui_sound_hint.text = "Click feedback blips on menus and buttons."
	ui_sound_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(ui_sound_hint, UITheme.SEPARATOR, 11, false)
	audio_section.add_child(ui_sound_hint)

	# ── UI Sound Volume row (code-generated, appended to AudioSection) ────────
	var ui_vol_row: HBoxContainer = HBoxContainer.new()
	ui_vol_row.add_theme_constant_override("separation", 16)
	audio_section.add_child(ui_vol_row)

	var ui_vol_lbl: Label = Label.new()
	ui_vol_lbl.text = "UI SOUND VOLUME"
	ui_vol_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(ui_vol_lbl, UITheme.WHITE_SOFT, 14, false)
	ui_vol_row.add_child(ui_vol_lbl)

	_ui_sound_slider = HSlider.new()
	_ui_sound_slider.min_value = 0.0
	_ui_sound_slider.max_value = 1.0
	_ui_sound_slider.step = 0.01
	_ui_sound_slider.value = 0.6
	_ui_sound_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ui_sound_slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	_style_slider(_ui_sound_slider)
	ui_vol_row.add_child(_ui_sound_slider)

	_ui_sound_value_lbl = Label.new()
	_ui_sound_value_lbl.text = "60%"
	_ui_sound_value_lbl.custom_minimum_size = Vector2(VALUE_LABEL_W, 0)
	_style_label(_ui_sound_value_lbl, UITheme.PURPLE_BRIGHT, 14, false)
	ui_vol_row.add_child(_ui_sound_value_lbl)

	_ui_sound_slider.value_changed.connect(
		func(v: float) -> void:
			_ui_sound_value_lbl.text = "%d%%" % roundi(v * 100.0)
			_save_settings()
	)
	# Audible preview when the drag finishes (not on every tick).
	_ui_sound_slider.drag_ended.connect(func(_changed: bool) -> void: UISound.click())

	# ── HUD Auto-Hide row (code-generated, appended to DisplaySection) ────────
	var display_section: VBoxContainer = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection
	var hud_delay_row: HBoxContainer = HBoxContainer.new()
	hud_delay_row.add_theme_constant_override("separation", 16)
	display_section.add_child(hud_delay_row)

	var hud_delay_lbl: Label = Label.new()
	hud_delay_lbl.text = "HUD AUTO-HIDE"
	hud_delay_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(hud_delay_lbl, UITheme.WHITE_SOFT, 14, false)
	hud_delay_row.add_child(hud_delay_lbl)

	_hud_delay_slider = HSlider.new()
	_hud_delay_slider.min_value = 1.0
	_hud_delay_slider.max_value = 10.0
	_hud_delay_slider.step = 0.5
	_hud_delay_slider.value = 3.0
	_hud_delay_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hud_delay_slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	_style_slider(_hud_delay_slider)
	hud_delay_row.add_child(_hud_delay_slider)

	_hud_delay_value_lbl = Label.new()
	_hud_delay_value_lbl.text = "3.0s"
	_hud_delay_value_lbl.custom_minimum_size = Vector2(VALUE_LABEL_W, 0)
	_style_label(_hud_delay_value_lbl, UITheme.PURPLE_BRIGHT, 14, false)
	hud_delay_row.add_child(_hud_delay_value_lbl)

	_hud_delay_slider.value_changed.connect(
		func(v: float) -> void:
			_hud_delay_value_lbl.text = "%.1fs" % v
			_save_settings()
	)

	# ── Sensory Strength row (code-generated, appended to DisplaySection) ────
	# Scales every visual/audio round effect. Softens rather than disables — which effects a
	# round uses stays the author's call; this is how strongly they land.
	var sensory_row: HBoxContainer = HBoxContainer.new()
	sensory_row.add_theme_constant_override("separation", 16)
	display_section.add_child(sensory_row)

	var sensory_lbl: Label = Label.new()
	sensory_lbl.text = "SENSORY STRENGTH"
	sensory_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(sensory_lbl, UITheme.WHITE_SOFT, 14, false)
	sensory_row.add_child(sensory_lbl)

	_sensory_slider = HSlider.new()
	_sensory_slider.min_value = 0.1
	_sensory_slider.max_value = 1.0
	_sensory_slider.step = 0.05
	_sensory_slider.value = 0.50
	_sensory_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sensory_slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	_style_slider(_sensory_slider)
	sensory_row.add_child(_sensory_slider)

	_sensory_value_lbl = Label.new()
	_sensory_value_lbl.text = "50%"
	_sensory_value_lbl.custom_minimum_size = Vector2(VALUE_LABEL_W, 0)
	_style_label(_sensory_value_lbl, UITheme.PURPLE_BRIGHT, 14, false)
	sensory_row.add_child(_sensory_value_lbl)

	_sensory_slider.value_changed.connect(
		func(v: float) -> void:
			_sensory_value_lbl.text = "%d%%" % roundi(v * 100.0)
			_save_settings()
	)

	# ── UI Scale row (code-generated, appended to DisplaySection) ────────────
	# Scales all GUI via Window.content_scale_factor — for high-DPI / 4K displays
	# where the native 1080p layout looks small. Applied live as the slider moves.
	var ui_scale_row: HBoxContainer = HBoxContainer.new()
	ui_scale_row.add_theme_constant_override("separation", 16)
	display_section.add_child(ui_scale_row)

	var ui_scale_lbl: Label = Label.new()
	ui_scale_lbl.text = "UI SCALE"
	ui_scale_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(ui_scale_lbl, UITheme.WHITE_SOFT, 14, false)
	ui_scale_row.add_child(ui_scale_lbl)

	_ui_scale_slider = HSlider.new()
	_ui_scale_slider.min_value = 0.75
	_ui_scale_slider.max_value = 2.5
	_ui_scale_slider.step = 0.05
	_ui_scale_slider.value = 1.0
	_ui_scale_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ui_scale_slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	_style_slider(_ui_scale_slider)
	ui_scale_row.add_child(_ui_scale_slider)

	_ui_scale_value_lbl = Label.new()
	_ui_scale_value_lbl.text = "100%"
	_ui_scale_value_lbl.custom_minimum_size = Vector2(VALUE_LABEL_W, 0)
	_style_label(_ui_scale_value_lbl, UITheme.PURPLE_BRIGHT, 14, false)
	ui_scale_row.add_child(_ui_scale_value_lbl)

	_ui_scale_slider.value_changed.connect(
		func(v: float) -> void:
			_ui_scale_value_lbl.text = "%d%%" % roundi(v * 100.0)
			# Apply live so the author sees the change immediately.
			var w: Window = get_window()
			if w != null:
				w.content_scale_factor = v
			_save_settings()
	)

	# ── Readability rows ────────────────────────────────────────────────────
	# Text-only scales, distinct from UI SCALE above (which resizes layout too).
	var story_row: HBoxContainer = HBoxContainer.new()
	story_row.add_theme_constant_override("separation", 16)
	display_section.add_child(story_row)

	var story_lbl: Label = Label.new()
	story_lbl.text = "STORY TEXT"
	story_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(story_lbl, UITheme.WHITE_SOFT, 14, false)
	story_row.add_child(story_lbl)

	_story_text_slider = HSlider.new()
	_story_text_slider.min_value = 1.0
	_story_text_slider.max_value = 2.0
	_story_text_slider.step = 0.05
	_story_text_slider.value = 1.0
	_story_text_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_story_text_slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	_style_slider(_story_text_slider)
	story_row.add_child(_story_text_slider)

	_story_text_value_lbl = Label.new()
	_story_text_value_lbl.text = "100%"
	_story_text_value_lbl.custom_minimum_size = Vector2(VALUE_LABEL_W, 0)
	_style_label(_story_text_value_lbl, UITheme.PURPLE_BRIGHT, 14, false)
	story_row.add_child(_story_text_value_lbl)

	_story_text_slider.value_changed.connect(
		func(v: float) -> void:
			_story_text_value_lbl.text = "%d%%" % roundi(v * 100.0)
			_save_settings()
	)

	var story_hint: Label = Label.new()
	story_hint.text = "Enlarges fork, boss-intro and storyboard text only — the HUD and buttons keep their size. Applies to the next screen that opens."
	story_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(story_hint, UITheme.SEPARATOR, 11, false)
	display_section.add_child(story_hint)

	var tip_row: HBoxContainer = HBoxContainer.new()
	tip_row.add_theme_constant_override("separation", 16)
	display_section.add_child(tip_row)

	var tip_lbl: Label = Label.new()
	tip_lbl.text = "TOOLTIP TEXT"
	tip_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(tip_lbl, UITheme.WHITE_SOFT, 14, false)
	tip_row.add_child(tip_lbl)

	_tooltip_text_slider = HSlider.new()
	_tooltip_text_slider.min_value = 1.0
	_tooltip_text_slider.max_value = 2.0
	_tooltip_text_slider.step = 0.05
	_tooltip_text_slider.value = 1.0
	_tooltip_text_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tooltip_text_slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	_style_slider(_tooltip_text_slider)
	tip_row.add_child(_tooltip_text_slider)

	_tooltip_text_value_lbl = Label.new()
	_tooltip_text_value_lbl.text = "100%"
	_tooltip_text_value_lbl.custom_minimum_size = Vector2(VALUE_LABEL_W, 0)
	_style_label(_tooltip_text_value_lbl, UITheme.PURPLE_BRIGHT, 14, false)
	tip_row.add_child(_tooltip_text_value_lbl)

	_tooltip_text_slider.value_changed.connect(
		func(v: float) -> void:
			_tooltip_text_value_lbl.text = "%d%%" % roundi(v * 100.0)
			_save_settings()
			UITheme.apply_tooltip_scale()  # live: the next hover shows the new size
	)

	var tip_hint: Label = Label.new()
	tip_hint.text = "Enlarges every tooltip, including the journey builder's."
	tip_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(tip_hint, UITheme.SEPARATOR, 11, false)
	display_section.add_child(tip_hint)

	var ui_scale_hint: Label = Label.new()
	ui_scale_hint.text = "Scales the entire interface. Raise it if menus look small on a high-resolution or 4K display."
	ui_scale_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(ui_scale_hint, UITheme.SEPARATOR, 11, false)
	display_section.add_child(ui_scale_hint)

	# ── Beat Bar row (code-generated, appended to DisplaySection) ────────────
	var beat_row: HBoxContainer = HBoxContainer.new()
	beat_row.add_theme_constant_override("separation", 16)
	display_section.add_child(beat_row)

	var beat_lbl: Label = Label.new()
	beat_lbl.text = "BEAT BAR"
	beat_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_label(beat_lbl, UITheme.WHITE_SOFT, 14, false)
	beat_row.add_child(beat_lbl)

	_beat_bar_toggle = Button.new()
	_beat_bar_toggle.toggle_mode = true
	_beat_bar_toggle.focus_mode = Control.FOCUS_NONE
	_style_toggle(_beat_bar_toggle, false)
	beat_row.add_child(_beat_bar_toggle)
	_beat_bar_toggle.toggled.connect(
		func(pressed: bool) -> void:
			_style_toggle(_beat_bar_toggle, pressed)
			_save_settings()
	)

	# Marker shape. Order matches BeatBar.SHAPES so the index maps straight to the id.
	_beat_shape_dd = OptionButton.new()
	_beat_shape_dd.add_item("♥ Heart")
	_beat_shape_dd.add_item("● Orb")
	_beat_shape_dd.add_item("◆ Diamond")
	_beat_shape_dd.add_item("★ Star")
	UITheme.style_option_button(_beat_shape_dd)
	beat_row.add_child(_beat_shape_dd)
	_beat_shape_dd.item_selected.connect(func(_i: int) -> void: _save_settings())

	var beat_hint: Label = Label.new()
	beat_hint.text = "Shows upcoming stroke beats scrolling toward a hit-line during play. Pick the marker shape on the right."
	beat_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(beat_hint, UITheme.SEPARATOR, 11, false)
	display_section.add_child(beat_hint)

	# ── Round Timer row ─────────────────────────────────────────────────────
	var timer_row: HBoxContainer = HBoxContainer.new()
	timer_row.add_theme_constant_override("separation", 16)
	display_section.add_child(timer_row)

	var timer_lbl: Label = Label.new()
	timer_lbl.text = "ROUND TIMER"
	timer_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_label(timer_lbl, UITheme.WHITE_SOFT, 14, false)
	timer_row.add_child(timer_lbl)

	_round_timer_toggle = Button.new()
	_round_timer_toggle.toggle_mode = true
	_round_timer_toggle.focus_mode = Control.FOCUS_NONE
	_style_toggle(_round_timer_toggle, false)
	timer_row.add_child(_round_timer_toggle)
	_round_timer_toggle.toggled.connect(
		func(pressed: bool) -> void:
			_style_toggle(_round_timer_toggle, pressed)
			_save_settings()
	)

	var timer_hint: Label = Label.new()
	timer_hint.text = "Shows the time left in the current round on the HUD. Hidden along with the rest of the HUD by effects that conceal it."
	timer_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(timer_hint, UITheme.SEPARATOR, 11, false)
	display_section.add_child(timer_hint)

	# ── Update Check row (code-generated, appended to DisplaySection) ─────────
	var upd_row: HBoxContainer = HBoxContainer.new()
	upd_row.add_theme_constant_override("separation", 16)
	display_section.add_child(upd_row)

	var upd_lbl: Label = Label.new()
	upd_lbl.text = "CHECK FOR UPDATES ON LAUNCH"
	upd_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_label(upd_lbl, UITheme.WHITE_SOFT, 14, false)
	upd_row.add_child(upd_lbl)

	_update_check_toggle = Button.new()
	_update_check_toggle.toggle_mode = true
	_update_check_toggle.focus_mode = Control.FOCUS_NONE
	_style_toggle(_update_check_toggle, false)
	upd_row.add_child(_update_check_toggle)
	_update_check_toggle.toggled.connect(
		func(pressed: bool) -> void:
			_style_toggle(_update_check_toggle, pressed)
			_save_settings()
	)

	var upd_hint: Label = Label.new()
	upd_hint.text = "Pings GitHub once per launch for a newer build and shows a banner. Off = no network call."
	upd_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(upd_hint, UITheme.SEPARATOR, 11, false)
	display_section.add_child(upd_hint)

	for label_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/OutputSection/OutputModeRow/OutputModeLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/FullscreenRow/FsLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/ResolutionRow/ResLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AddressRow/AddressLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/DeviceRow/DeviceLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialPortRow/SerialPortLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialBaudRow/SerialBaudLabel",
	]:
		(get_node(label_path) as Label).custom_minimum_size = Vector2(ROW_LABEL_W, 0)

	_res_dropdown.custom_minimum_size = Vector2(220, 0)
	_device_dropdown.custom_minimum_size = Vector2(220, 0)
	_serial_port_dropdown.custom_minimum_size = Vector2(180, 0)

	# ── Device Range section (built entirely in code) ─────────────────────────
	var range_section: VBoxContainer = VBoxContainer.new()
	range_section.add_theme_constant_override("separation", 12)
	_content_vbox.add_child(range_section)
	_range_section = range_section

	var range_header: Label = Label.new()
	range_header.text = "T-CODE DEVICE"
	_style_label(range_header, UITheme.PURPLE_BRIGHT, 13, true)
	range_section.add_child(range_header)

	var range_divider: HSeparator = HSeparator.new()
	range_divider.add_theme_stylebox_override("separator", _make_separator_style())
	range_section.add_child(range_divider)

	var range_row: HBoxContainer = HBoxContainer.new()
	range_row.add_theme_constant_override("separation", 16)
	range_section.add_child(range_row)

	var range_lbl: Label = Label.new()
	range_lbl.text = "Stroke Range"
	range_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(range_lbl, UITheme.WHITE_SOFT, 14, false)
	range_row.add_child(range_lbl)

	# Slider + value labels stacked vertically
	var slider_col: VBoxContainer = VBoxContainer.new()
	slider_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider_col.add_theme_constant_override("separation", 4)
	range_row.add_child(slider_col)

	_range_slider = RangeSlider.new()
	_range_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider_col.add_child(_range_slider)

	# Min / max value row beneath the slider
	var val_row: HBoxContainer = HBoxContainer.new()
	val_row.add_theme_constant_override("separation", 0)
	slider_col.add_child(val_row)

	_range_min_lbl = Label.new()
	_range_min_lbl.text = "MIN: 0"
	_style_label(_range_min_lbl, UITheme.PURPLE_MID, 11, true)
	val_row.add_child(_range_min_lbl)

	var val_spacer: Control = Control.new()
	val_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val_row.add_child(val_spacer)

	_range_max_lbl = Label.new()
	_range_max_lbl.text = "MAX: 100"
	_style_label(_range_max_lbl, UITheme.PURPLE_MID, 11, true)
	val_row.add_child(_range_max_lbl)

	# Update labels, push live into the player, and auto-save whenever a handle is moved.
	_range_slider.range_changed.connect(
		func(lo: float, hi: float) -> void:
			_range_min_lbl.text = "MIN: %d" % roundi(lo)
			_range_max_lbl.text = "MAX: %d" % roundi(hi)
			FunscriptPlayer.SetRangeClamp(roundi(lo), roundi(hi))
			# Handy-direct maps the range to the device slider zone (debounced).
			if SettingsService.get_stroke_target() == DeviceRouting.HANDY_TARGET:
				HandyService.set_slider_debounced(roundi(lo), roundi(hi))
			_save_settings()
	)

	# Hint beneath the slider
	var hint: Label = Label.new()
	hint.text = "Hard-clamps the stroke (main) axis to this range. Affects both Buttplug and Serial outputs."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(hint, UITheme.SEPARATOR, 11, false)
	range_section.add_child(hint)

	# ── Secondary-axis ranges (one per positional T-code axis) ────────────────
	# L1/L2/R0/R1/R2 → surge/sway/twist/roll/pitch. Each axis has its own travel
	# window, independent of the stroke range. These are bipolar (home to centre
	# 50), so a symmetric range narrows the swing around centre. Only axes with a
	# loaded script on a multi-axis device actually move (OSR2 none; SR6 all).
	var axis_hint: Label = Label.new()
	axis_hint.text = "Per-axis range for multi-axis devices (e.g. SR6). The stroke axis uses Stroke Range above."
	axis_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(axis_hint, UITheme.SEPARATOR, 11, false)
	range_section.add_child(axis_hint)

	for axis_def: Array in SECONDARY_AXES:
		var axis_id: String = axis_def[0]
		var axis_name: String = axis_def[1]

		var ax_row: HBoxContainer = HBoxContainer.new()
		ax_row.add_theme_constant_override("separation", 16)
		range_section.add_child(ax_row)

		var ax_lbl: Label = Label.new()
		ax_lbl.text = "%s (%s)" % [axis_name, axis_id]
		ax_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
		_style_label(ax_lbl, UITheme.WHITE_SOFT, 14, false)
		ax_row.add_child(ax_lbl)

		var ax_col: VBoxContainer = VBoxContainer.new()
		ax_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ax_col.add_theme_constant_override("separation", 4)
		ax_row.add_child(ax_col)

		var ax_slider: RangeSlider = RangeSlider.new()
		ax_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ax_col.add_child(ax_slider)
		_axis_range_sliders[axis_id] = ax_slider

		var ax_val_row: HBoxContainer = HBoxContainer.new()
		ax_val_row.add_theme_constant_override("separation", 0)
		ax_col.add_child(ax_val_row)

		var ax_min_lbl: Label = Label.new()
		ax_min_lbl.text = "MIN: 0"
		_style_label(ax_min_lbl, UITheme.PURPLE_MID, 11, true)
		ax_val_row.add_child(ax_min_lbl)
		_axis_range_min_lbls[axis_id] = ax_min_lbl

		var ax_val_spacer: Control = Control.new()
		ax_val_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ax_val_row.add_child(ax_val_spacer)

		var ax_max_lbl: Label = Label.new()
		ax_max_lbl.text = "MAX: 100"
		_style_label(ax_max_lbl, UITheme.PURPLE_MID, 11, true)
		ax_val_row.add_child(ax_max_lbl)
		_axis_range_max_lbls[axis_id] = ax_max_lbl

		# Live-push this axis's window and autosave on drag (mirrors Stroke Range).
		ax_slider.range_changed.connect(
			func(lo: float, hi: float) -> void:
				ax_min_lbl.text = "MIN: %d" % roundi(lo)
				ax_max_lbl.text = "MAX: %d" % roundi(hi)
				FunscriptPlayer.SetAxisRangeClamp(axis_id, roundi(lo), roundi(hi))
				_save_settings()
		)

	# ── Home Position row ────────────────────────────────────────────────────
	var home_row: HBoxContainer = HBoxContainer.new()
	home_row.add_theme_constant_override("separation", 16)
	range_section.add_child(home_row)

	var home_lbl: Label = Label.new()
	home_lbl.text = "Home Position"
	home_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(home_lbl, UITheme.WHITE_SOFT, 14, false)
	home_row.add_child(home_lbl)

	var home_slider_col: VBoxContainer = VBoxContainer.new()
	home_slider_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	home_slider_col.add_theme_constant_override("separation", 4)
	home_row.add_child(home_slider_col)

	_home_slider = HSlider.new()
	_home_slider.min_value = 0
	_home_slider.max_value = 100
	_home_slider.step = 1
	_home_slider.value = 50
	_home_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_slider(_home_slider)
	home_slider_col.add_child(_home_slider)

	_home_value_lbl = Label.new()
	_home_value_lbl.text = "50"
	_style_label(_home_value_lbl, UITheme.PURPLE_MID, 11, true)
	home_slider_col.add_child(_home_value_lbl)

	_home_slider.value_changed.connect(
		func(v: float) -> void:
			_home_value_lbl.text = str(roundi(v))
			_save_settings()
	)

	# ── Home Ease row ────────────────────────────────────────────────────────
	var home_ease_row: HBoxContainer = HBoxContainer.new()
	home_ease_row.add_theme_constant_override("separation", 16)
	range_section.add_child(home_ease_row)

	var home_ease_lbl: Label = Label.new()
	home_ease_lbl.text = "Home Ease (ms)"
	home_ease_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(home_ease_lbl, UITheme.WHITE_SOFT, 14, false)
	home_ease_row.add_child(home_ease_lbl)

	_home_ease_input = LineEdit.new()
	_home_ease_input.text = "2000"
	_home_ease_input.custom_minimum_size = Vector2(100, 0)
	_home_ease_input.placeholder_text = "2000"
	_style_line_edit(_home_ease_input)
	home_ease_row.add_child(_home_ease_input)

	var home_ease_hint_lbl: Label = Label.new()
	home_ease_hint_lbl.text = "ms"
	_style_label(home_ease_hint_lbl, UITheme.SEPARATOR, 12, false)
	home_ease_row.add_child(home_ease_hint_lbl)

	_home_ease_input.text_changed.connect(func(_t: String) -> void: _save_settings())

	var home_hint: Label = Label.new()
	home_hint.text = "L0 target position when playback pauses or stops. Secondary axes always return to centre."
	home_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(home_hint, UITheme.SEPARATOR, 11, false)
	range_section.add_child(home_hint)

	# ── Vibration Intensity row ──────────────────────────────────────────────
	var vibe_row: HBoxContainer = HBoxContainer.new()
	vibe_row.add_theme_constant_override("separation", 16)
	range_section.add_child(vibe_row)

	var vibe_lbl: Label = Label.new()
	vibe_lbl.text = "Vibration Intensity"
	vibe_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(vibe_lbl, UITheme.WHITE_SOFT, 14, false)
	vibe_row.add_child(vibe_lbl)

	var vibe_col: VBoxContainer = VBoxContainer.new()
	vibe_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vibe_col.add_theme_constant_override("separation", 4)
	vibe_row.add_child(vibe_col)

	_vibe_slider = HSlider.new()
	_vibe_slider.min_value = 0
	_vibe_slider.max_value = 100
	_vibe_slider.step = 1
	_vibe_slider.value = 100
	_vibe_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_slider(_vibe_slider)
	vibe_col.add_child(_vibe_slider)

	_vibe_value_lbl = Label.new()
	_vibe_value_lbl.text = "100%"
	_style_label(_vibe_value_lbl, UITheme.PURPLE_MID, 11, true)
	vibe_col.add_child(_vibe_value_lbl)

	_vibe_slider.value_changed.connect(
		func(v: float) -> void:
			_vibe_value_lbl.text = "%d%%" % roundi(v)
			_save_settings()
	)

	var vibe_hint: Label = Label.new()
	vibe_hint.text = "Scales output strength for vibrators. No effect on linear (stroker) devices."
	vibe_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(vibe_hint, UITheme.SEPARATOR, 11, false)
	range_section.add_child(vibe_hint)

	# ── Max Stroke Speed row ─────────────────────────────────────────────────
	var speed_row: HBoxContainer = HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 16)
	range_section.add_child(speed_row)

	var speed_lbl: Label = Label.new()
	speed_lbl.text = "Max Stroke Speed"
	speed_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(speed_lbl, UITheme.WHITE_SOFT, 14, false)
	speed_row.add_child(speed_lbl)

	var speed_col: VBoxContainer = VBoxContainer.new()
	speed_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_col.add_theme_constant_override("separation", 4)
	speed_row.add_child(speed_col)

	_max_speed_slider = HSlider.new()
	_max_speed_slider.min_value = 0
	_max_speed_slider.max_value = 1000
	_max_speed_slider.step = 25
	_max_speed_slider.value = 0
	_max_speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_slider(_max_speed_slider)
	speed_col.add_child(_max_speed_slider)

	_max_speed_value_lbl = Label.new()
	_max_speed_value_lbl.text = "Off"
	_style_label(_max_speed_value_lbl, UITheme.PURPLE_MID, 11, true)
	speed_col.add_child(_max_speed_value_lbl)

	_max_speed_slider.value_changed.connect(
		func(v: float) -> void:
			_max_speed_value_lbl.text = ("Off" if roundi(v) <= 0 else "%d u/s" % roundi(v))
			_save_settings()
	)

	var speed_hint: Label = Label.new()
	speed_hint.text = "Caps how fast linear devices move — faster strokes are slowed to this limit. Off = unlimited. No effect on vibrators."
	speed_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(speed_hint, UITheme.SEPARATOR, 11, false)
	range_section.add_child(speed_hint)

	# ── Storyboard Filler section (built entirely in code) ────────────────────
	var filler_section: VBoxContainer = VBoxContainer.new()
	filler_section.add_theme_constant_override("separation", 12)
	_content_vbox.add_child(filler_section)
	_filler_section = filler_section

	_build_routing_section()
	_build_handy_section()
	_build_restim_section()
	_build_restim_axes_section()

	var filler_header: Label = Label.new()
	filler_header.text = "STORYBOARD FILLER"
	_style_label(filler_header, UITheme.PURPLE_BRIGHT, 13, true)
	filler_section.add_child(filler_header)

	var filler_divider: HSeparator = HSeparator.new()
	filler_divider.add_theme_stylebox_override("separator", _make_separator_style())
	filler_section.add_child(filler_divider)

	# Enable row
	var filler_enable_row: HBoxContainer = HBoxContainer.new()
	filler_enable_row.add_theme_constant_override("separation", 16)
	filler_section.add_child(filler_enable_row)

	var filler_enable_lbl: Label = Label.new()
	filler_enable_lbl.text = "Enable Filler"
	filler_enable_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(filler_enable_lbl, UITheme.WHITE_SOFT, 14, false)
	filler_enable_row.add_child(filler_enable_lbl)

	_filler_toggle = Button.new()
	_filler_toggle.toggle_mode = true
	_filler_toggle.focus_mode = Control.FOCUS_NONE
	_style_toggle(_filler_toggle, false)
	filler_enable_row.add_child(_filler_toggle)

	# Speed row
	var filler_speed_row: HBoxContainer = HBoxContainer.new()
	filler_speed_row.add_theme_constant_override("separation", 16)
	filler_section.add_child(filler_speed_row)

	var filler_speed_lbl: Label = Label.new()
	filler_speed_lbl.text = "Stroke Speed (ms)"
	filler_speed_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(filler_speed_lbl, UITheme.WHITE_SOFT, 14, false)
	filler_speed_row.add_child(filler_speed_lbl)

	_filler_speed_input = LineEdit.new()
	_filler_speed_input.text = "2000"
	_filler_speed_input.custom_minimum_size = Vector2(100, 0)
	_filler_speed_input.placeholder_text = "2000"
	_style_line_edit(_filler_speed_input)
	filler_speed_row.add_child(_filler_speed_input)

	var filler_speed_hint: Label = Label.new()
	filler_speed_hint.text = "ms per half-stroke"
	_style_label(filler_speed_hint, UITheme.SEPARATOR, 12, false)
	filler_speed_row.add_child(filler_speed_hint)

	# Range row
	var filler_range_row: HBoxContainer = HBoxContainer.new()
	filler_range_row.add_theme_constant_override("separation", 16)
	filler_section.add_child(filler_range_row)

	var filler_range_lbl: Label = Label.new()
	filler_range_lbl.text = "Stroke Range"
	filler_range_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(filler_range_lbl, UITheme.WHITE_SOFT, 14, false)
	filler_range_row.add_child(filler_range_lbl)

	var filler_slider_col: VBoxContainer = VBoxContainer.new()
	filler_slider_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filler_slider_col.add_theme_constant_override("separation", 4)
	filler_range_row.add_child(filler_slider_col)

	_filler_range_slider = RangeSlider.new()
	_filler_range_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filler_slider_col.add_child(_filler_range_slider)

	var filler_val_row: HBoxContainer = HBoxContainer.new()
	filler_val_row.add_theme_constant_override("separation", 0)
	filler_slider_col.add_child(filler_val_row)

	_filler_range_min_lbl = Label.new()
	_filler_range_min_lbl.text = "MIN: 0"
	_style_label(_filler_range_min_lbl, UITheme.PURPLE_MID, 11, true)
	filler_val_row.add_child(_filler_range_min_lbl)

	var filler_val_spacer: Control = Control.new()
	filler_val_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filler_val_row.add_child(filler_val_spacer)

	_filler_range_max_lbl = Label.new()
	_filler_range_max_lbl.text = "MAX: 100"
	_style_label(_filler_range_max_lbl, UITheme.PURPLE_MID, 11, true)
	filler_val_row.add_child(_filler_range_max_lbl)

	_filler_range_slider.range_changed.connect(
		func(lo: float, hi: float) -> void:
			_filler_range_min_lbl.text = "MIN: %d" % roundi(lo)
			_filler_range_max_lbl.text = "MAX: %d" % roundi(hi)
			# Apply live so an active storyboard's filler picks up the new range
			# immediately, not just on the next storyboard.
			FunscriptPlayer.SetFillerParams(
				roundi(lo), roundi(hi), _filler_speed_input.text.to_int()
			)
			_save_settings()
	)
	_filler_toggle.toggled.connect(
		func(pressed: bool) -> void:
			_style_toggle(_filler_toggle, pressed)
			_save_settings()
	)
	_filler_speed_input.text_changed.connect(
		func(_t: String) -> void:
			# Same live-apply for half-cycle changes.
			FunscriptPlayer.SetFillerParams(
				roundi(_filler_range_slider.lo),
				roundi(_filler_range_slider.hi),
				_filler_speed_input.text.to_int()
			)
			_save_settings()
	)

	var filler_hint: Label = Label.new()
	filler_hint.text = "Keeps the device active during storyboard scenes with a repeating alternating stroke. Respects the Position Clamp above."
	filler_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(filler_hint, UITheme.SEPARATOR, 11, false)
	filler_section.add_child(filler_hint)

	# ── Journey storage location row (inserted into JourneysSection) ──────────
	_build_journey_location_row()

	# ── Transcoding section (built entirely in code) ─────────────────────────
	_build_transcode_section()

	# ── Credits section ───────────────────────────────────────────────────────
	var credits_section: VBoxContainer = VBoxContainer.new()
	credits_section.add_theme_constant_override("separation", 12)
	_content_vbox.add_child(credits_section)
	_credits_section = credits_section

	var credits_header: Label = Label.new()
	credits_header.text = "CREDITS"
	_style_label(credits_header, UITheme.PURPLE_BRIGHT, 13, true)
	credits_section.add_child(credits_header)

	var credits_divider: HSeparator = HSeparator.new()
	credits_divider.add_theme_stylebox_override("separator", _make_separator_style())
	credits_section.add_child(credits_divider)

	var credits_music_lbl: Label = Label.new()
	credits_music_lbl.text = "Music by Karl Casey @ White Bat Audio"
	_style_label(credits_music_lbl, UITheme.WHITE_SOFT, 13, false)
	credits_section.add_child(credits_music_lbl)

	# ── Tab bar — groups all sections above into navigable categories ─────────
	_build_tabs()


# ---------------------------------------------------------------------------
# Tabs
# ---------------------------------------------------------------------------


# Builds the category tab bar and shows the first tab. The tab bar floats
# between the top bar and the content panel; switching tabs toggles the
# visibility of each section rather than reparenting (the rest of this file
# addresses sections by absolute node path, which reparenting would break).
func _build_tabs() -> void:
	_tab_bar = TabBar.new()
	for tab_name: String in TAB_NAMES:
		_tab_bar.add_tab(tab_name)
	_tab_bar.clip_tabs = false
	_tab_bar.tab_alignment = TabBar.ALIGNMENT_CENTER
	_tab_bar.focus_mode = Control.FOCUS_NONE
	_tab_bar.anchor_left = 0.5
	_tab_bar.anchor_right = 0.5
	_tab_bar.anchor_top = 0.0
	_tab_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_tab_bar.offset_left = -PANEL_HALF_W
	_tab_bar.offset_right = PANEL_HALF_W
	_tab_bar.offset_top = TOP_BAR_HEIGHT
	_tab_bar.offset_bottom = TOP_BAR_HEIGHT + TAB_BAR_HEIGHT
	_style_tab_bar(_tab_bar)
	add_child(_tab_bar)

	_tab_bar.tab_changed.connect(_on_tab_changed)
	_on_tab_changed(0)


func _style_tab_bar(tabs: TabBar) -> void:
	tabs.add_theme_color_override("font_selected_color", UITheme.PURPLE_BRIGHT)
	tabs.add_theme_color_override("font_unselected_color", UITheme.PURPLE_MID)
	tabs.add_theme_color_override("font_hovered_color", UITheme.WHITE_SOFT)
	tabs.add_theme_font_size_override("font_size", 14)
	tabs.add_theme_stylebox_override(
		"tab_selected", _make_btn_style(UITheme.PURPLE_BRIGHT, UITheme.PURPLE_MID)
	)
	tabs.add_theme_stylebox_override(
		"tab_unselected", _make_btn_style(UITheme.PURPLE_MID, UITheme.PURPLE_DARK)
	)
	tabs.add_theme_stylebox_override(
		"tab_hovered", _make_btn_style(UITheme.PURPLE_BRIGHT, UITheme.PURPLE_DARK)
	)
	tabs.add_theme_stylebox_override("tab_focus", StyleBoxEmpty.new())


# Shows the sections that belong to tab `idx` and hides all others.
func _on_tab_changed(idx: int) -> void:
	const VBOX: String = "ContentPanel/ContentScroll/MarginWrapper/ContentVBox/"
	var pages: Array = [
		# GENERAL
		[
			get_node(VBOX + "JourneysSection"),
			get_node(VBOX + "AudioSection"),
			get_node(VBOX + "DisplaySection"),
			_transcode_section
		],
		# CONNECTION
		[
			get_node(VBOX + "IntifaceSection"),
			get_node(VBOX + "SerialSection"),
			_routing_section,
			_handy_section,
			_restim_section,
		],
		# DEVICE
		[_range_section, _restim_axes_section, _filler_section],
		# ABOUT
		[_credits_section],
	]
	for page_idx: int in pages.size():
		var on_this_tab: bool = page_idx == idx
		for section: Control in pages[page_idx]:
			if section != null:
				section.visible = on_this_tab

	# Reset the scroll so each tab opens at its top.
	($ContentPanel/ContentScroll as ScrollContainer).scroll_vertical = 0


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------


func _apply_theme() -> void:
	_bg.color = UITheme.BG

	_style_label(_title_lbl, UITheme.PURPLE_BRIGHT, 18, true)
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_style_button(_back_btn, UITheme.MAGENTA)
	_style_button(_open_folder_btn, UITheme.PURPLE_MID)
	_style_button(_connect_btn, UITheme.PURPLE_BRIGHT)
	_style_button(_scan_btn, UITheme.PURPLE_MID)

	_style_panel()

	for header_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/JourneysSection/JourneysHeader",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/OutputSection/OutputHeader",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/AudioHeader",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/DisplayHeader",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/IntifaceHeader",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialHeader",
	]:
		_style_label(get_node(header_path), UITheme.PURPLE_BRIGHT, 13, true)

	var sep_style: StyleBoxFlat = _make_separator_style()
	for sep_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/JourneysSection/JourneysDivider",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/OutputSection/OutputDivider",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/AudioDivider",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/DisplayDivider",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/IntifaceDivider",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialDivider",
	]:
		(get_node(sep_path) as HSeparator).add_theme_stylebox_override("separator", sep_style)

	for row_label_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/OutputSection/OutputModeRow/OutputModeLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow/MasterLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/FullscreenRow/FsLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/ResolutionRow/ResLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AddressRow/AddressLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AutoConnectRow/AutoConnectLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/DeviceRow/DeviceLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialPortRow/SerialPortLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialBaudRow/SerialBaudLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialAutoRow/SerialAutoLabel",
	]:
		_style_label(get_node(row_label_path), UITheme.WHITE_SOFT, 14, false)

	_style_label(_master_value, UITheme.PURPLE_BRIGHT, 14, false)
	_style_label(_status_lbl, UITheme.ERROR, 13, false)
	_style_label(_serial_status_lbl, UITheme.ERROR, 13, false)

	_style_slider(_master_slider)
	_style_option_button(_res_dropdown)
	_style_option_button(_device_dropdown)
	_style_option_button(_serial_port_dropdown)
	_style_line_edit(_address_input)
	_style_line_edit(_serial_baud_input)
	_style_toggle(_fs_toggle, false)
	_style_toggle(_auto_toggle, false)
	_style_toggle(_serial_auto_toggle, false)
	_style_button(_bp_test_btn, UITheme.PURPLE_MID)
	_style_button(_serial_refresh_btn, UITheme.PURPLE_MID)
	_style_button(_serial_connect_btn, UITheme.PURPLE_BRIGHT)
	_style_button(_serial_test_btn, UITheme.PURPLE_MID)


func _style_panel() -> void:
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
	s.shadow_size = 12
	s.content_margin_left = 32
	s.content_margin_right = 32
	s.content_margin_top = 28
	s.content_margin_bottom = 28
	_content_panel.add_theme_stylebox_override("panel", s)


func _make_separator_style() -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.SEPARATOR
	return s


# Thin delegates to UITheme — the canonical styling lives there. Args preserve this screen's padding.
func _style_label(label: Label, color: Color, size: int, uppercase: bool = false) -> void:
	UITheme.style_label(label, color, size, uppercase)


func _style_button(btn: Button, accent: Color) -> void:
	UITheme.style_button(btn, accent, 18, 10)


func _make_btn_style(border: Color, fill: Color) -> StyleBoxFlat:
	return UITheme.make_btn_style(border, fill, 18, 10)


func _style_toggle(btn: Button, pressed: bool) -> void:
	var active_color: Color = UITheme.PURPLE_BRIGHT
	var inactive_color: Color = UITheme.PURPLE_MID
	var accent: Color = active_color if pressed else inactive_color
	btn.add_theme_color_override("font_color", accent)
	btn.add_theme_color_override("font_hover_color", UITheme.WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", UITheme.BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.text = btn.text.to_upper()
	var fill: Color = UITheme.PURPLE_MID if pressed else UITheme.PURPLE_DARK
	btn.add_theme_stylebox_override("normal", _make_btn_style(accent, fill))
	btn.add_theme_stylebox_override("hover", _make_btn_style(accent, UITheme.PURPLE_MID))
	btn.add_theme_stylebox_override("pressed", _make_btn_style(active_color, active_color))
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.text = "ON" if pressed else "OFF"


func _style_slider(slider: HSlider) -> void:
	var track: StyleBoxFlat = StyleBoxFlat.new()
	track.bg_color = UITheme.PURPLE_DARK
	track.border_color = UITheme.PURPLE_MID
	track.border_width_left = 1
	track.border_width_right = 1
	track.border_width_top = 1
	track.border_width_bottom = 1
	track.content_margin_top = 4
	track.content_margin_bottom = 4

	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = UITheme.PURPLE_BRIGHT
	fill.content_margin_top = 4
	fill.content_margin_bottom = 4

	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_color_override("grabber_color", UITheme.MAGENTA)
	slider.custom_minimum_size.y = 24


func _style_option_button(opt: OptionButton) -> void:
	opt.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	opt.add_theme_color_override("font_hover_color", UITheme.PURPLE_BRIGHT)
	opt.add_theme_font_size_override("font_size", 14)
	opt.add_theme_stylebox_override(
		"normal", _make_btn_style(UITheme.PURPLE_MID, UITheme.PURPLE_DARK)
	)
	opt.add_theme_stylebox_override(
		"hover", _make_btn_style(UITheme.PURPLE_BRIGHT, UITheme.PURPLE_MID)
	)
	opt.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _style_line_edit(edit: LineEdit) -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.PURPLE_DARK
	s.border_color = UITheme.PURPLE_MID

	s.border_width_left = 2
	s.border_width_right = 2
	s.border_width_top = 2
	s.border_width_bottom = 2

	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 8
	s.content_margin_bottom = 8

	edit.add_theme_stylebox_override("normal", s)
	edit.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	edit.add_theme_color_override("font_placeholder_color", UITheme.PURPLE_MID)
	edit.add_theme_color_override("caret_color", UITheme.PURPLE_BRIGHT)
	edit.add_theme_color_override(
		"selection_color",
		Color(UITheme.PURPLE_BRIGHT.r, UITheme.PURPLE_BRIGHT.g, UITheme.PURPLE_BRIGHT.b, 0.4)
	)
	edit.add_theme_font_size_override("font_size", 14)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------


func _populate_resolution_dropdown() -> void:
	_res_dropdown.clear()
	for res: Vector2i in RESOLUTIONS:
		_res_dropdown.add_item("%d × %d" % [res.x, res.y])


func _refresh_serial_ports() -> void:
	var current: String = ""
	if _serial_port_dropdown.item_count > 0 and _serial_port_dropdown.selected >= 0:
		current = _serial_port_dropdown.get_item_text(_serial_port_dropdown.selected)
	_serial_port_dropdown.clear()
	for p: String in SerialDeviceService.GetAvailablePorts():
		_serial_port_dropdown.add_item(p)
	if current != "":
		for i: int in _serial_port_dropdown.item_count:
			if _serial_port_dropdown.get_item_text(i) == current:
				_serial_port_dropdown.selected = i
				return


func _load_settings() -> void:
	# Guard against code-generated slider signals firing _save_settings() before
	# all values have been populated — that would overwrite saved settings with
	# the controls' initial/default values.
	_loading = true
	# All reads go through SettingsService, which returns canonical defaults for
	# any key that has never been written — so this works on a fresh install too.
	var vol: float = SettingsService.get_master_volume()
	_master_slider.value = vol
	_update_volume_label(vol)
	AudioServer.set_bus_volume_db(0, linear_to_db(vol))

	var music_vol: float = SettingsService.get_music_volume()
	if _music_slider != null:
		_music_slider.value = music_vol
		_music_value_lbl.text = "%d%%" % roundi(music_vol * 100.0)

	_res_dropdown.selected = clampi(
		SettingsService.get_resolution_index(), 0, RESOLUTIONS.size() - 1
	)

	var fullscreen: bool = SettingsService.get_fullscreen()
	_fs_toggle.button_pressed = fullscreen
	_style_toggle(_fs_toggle, fullscreen)
	# Do NOT call _apply_fullscreen() here — SettingsService._ready() already
	# applied it at boot. Re-applying it every time Options opens would force
	# the window out of maximized / windowed-fullscreen mode.

	_address_input.text = SettingsService.get_intiface_address()

	var auto_connect: bool = SettingsService.get_intiface_auto_connect()
	_auto_toggle.button_pressed = auto_connect
	_style_toggle(_auto_toggle, auto_connect)

	_restore_device_selection(SettingsService.get_selected_device())

	var saved_port: String = SettingsService.get_serial_port()
	if saved_port != "":
		for i: int in _serial_port_dropdown.item_count:
			if _serial_port_dropdown.get_item_text(i) == saved_port:
				_serial_port_dropdown.selected = i
				break

	_serial_baud_input.text = str(SettingsService.get_serial_baud())

	var serial_auto: bool = SettingsService.get_serial_auto_connect()
	_serial_auto_toggle.button_pressed = serial_auto
	_style_toggle(_serial_auto_toggle, serial_auto)

	var range_lo: float = float(SettingsService.get_range_min())
	var range_hi: float = float(SettingsService.get_range_max())
	if _range_slider != null:
		_range_slider.set_range_values(range_lo, range_hi)
		_range_min_lbl.text = "MIN: %d" % roundi(range_lo)
		_range_max_lbl.text = "MAX: %d" % roundi(range_hi)

	for axis_def: Array in SECONDARY_AXES:
		var axis_id: String = axis_def[0]
		var ax_slider: RangeSlider = _axis_range_sliders.get(axis_id) as RangeSlider
		if ax_slider != null:
			var ax_lo: float = float(SettingsService.get_axis_range_min(axis_id))
			var ax_hi: float = float(SettingsService.get_axis_range_max(axis_id))
			ax_slider.set_range_values(ax_lo, ax_hi)
			(_axis_range_min_lbls[axis_id] as Label).text = "MIN: %d" % roundi(ax_lo)
			(_axis_range_max_lbls[axis_id] as Label).text = "MAX: %d" % roundi(ax_hi)

	var home_pos: int = SettingsService.get_home_position()
	var home_ease: int = SettingsService.get_home_ease_ms()
	if _home_slider != null:
		_home_slider.value = home_pos
		_home_value_lbl.text = str(home_pos)
	if _home_ease_input != null:
		_home_ease_input.text = str(home_ease)
	FunscriptPlayer.SetHomePosition(home_pos, home_ease)

	var vibe: int = SettingsService.get_vibe_intensity()
	if _vibe_slider != null:
		_vibe_slider.value = vibe
		_vibe_value_lbl.text = "%d%%" % vibe
	FunscriptPlayer.SetVibeIntensity(vibe)

	var max_speed: int = SettingsService.get_max_stroke_speed()
	if _max_speed_slider != null:
		_max_speed_slider.value = max_speed
		_max_speed_value_lbl.text = ("Off" if max_speed <= 0 else "%d u/s" % max_speed)
	FunscriptPlayer.SetMaxStrokeSpeed(max_speed)

	var hud_delay: float = SettingsService.get_hud_hide_delay()
	if _hud_delay_slider != null:
		_hud_delay_slider.value = hud_delay
		_hud_delay_value_lbl.text = "%.1fs" % hud_delay

	var sensory: float = SettingsService.get_sensory_strength()
	if _sensory_slider != null:
		_sensory_slider.set_value_no_signal(sensory)
		_sensory_value_lbl.text = "%d%%" % roundi(sensory * 100.0)

	var ui_scale: float = SettingsService.get_ui_scale()
	if _ui_scale_slider != null:
		_ui_scale_slider.set_value_no_signal(ui_scale)
		_ui_scale_value_lbl.text = "%d%%" % roundi(ui_scale * 100.0)

	if _beat_bar_toggle != null:
		var beat_on: bool = SettingsService.get_beat_bar_enabled()
		_beat_bar_toggle.button_pressed = beat_on
		_style_toggle(_beat_bar_toggle, beat_on)

	if _beat_shape_dd != null:
		var shape_i: int = BeatBar.SHAPES.find(SettingsService.get_beat_bar_shape())
		_beat_shape_dd.selected = shape_i if shape_i >= 0 else 0

	if _story_text_slider != null:
		var story_scale: float = SettingsService.get_story_text_scale()
		_story_text_slider.set_value_no_signal(story_scale)
		_story_text_value_lbl.text = "%d%%" % roundi(story_scale * 100.0)

	if _tooltip_text_slider != null:
		var tip_scale: float = SettingsService.get_tooltip_text_scale()
		_tooltip_text_slider.set_value_no_signal(tip_scale)
		_tooltip_text_value_lbl.text = "%d%%" % roundi(tip_scale * 100.0)

	if _round_timer_toggle != null:
		var timer_on: bool = SettingsService.get_round_timer_enabled()
		_round_timer_toggle.button_pressed = timer_on
		_style_toggle(_round_timer_toggle, timer_on)

	if _update_check_toggle != null:
		var upd_on: bool = SettingsService.get_update_check_enabled()
		_update_check_toggle.button_pressed = upd_on
		_style_toggle(_update_check_toggle, upd_on)

	if _ui_sound_toggle != null:
		var ui_snd_on: bool = SettingsService.get_ui_sound_enabled()
		# no_signal so opening Options doesn't fire the toggled handler (which would
		# play a confirm blip every time the screen loads).
		_ui_sound_toggle.set_pressed_no_signal(ui_snd_on)
		_style_toggle(_ui_sound_toggle, ui_snd_on)
	if _ui_sound_slider != null:
		var ui_snd_vol: float = SettingsService.get_ui_sound_volume()
		_ui_sound_slider.set_value_no_signal(ui_snd_vol)
		_ui_sound_value_lbl.text = "%d%%" % roundi(ui_snd_vol * 100.0)

	# Load the filler range slider FIRST so that if the toggle or speed-input
	# signals fire _save_settings() below, the slider already holds the correct
	# values and won't overwrite them with the initialisation defaults (0/100).
	var filler_lo: float = float(SettingsService.get_filler_lo())
	var filler_hi: float = float(SettingsService.get_filler_hi())
	if _filler_range_slider != null:
		_filler_range_slider.set_range_values(filler_lo, filler_hi)
		_filler_range_min_lbl.text = "MIN: %d" % roundi(filler_lo)
		_filler_range_max_lbl.text = "MAX: %d" % roundi(filler_hi)

	var filler_enabled: bool = SettingsService.get_filler_enabled()
	if _filler_toggle != null:
		_filler_toggle.button_pressed = filler_enabled
		_style_toggle(_filler_toggle, filler_enabled)

	if _filler_speed_input != null:
		_filler_speed_input.text = str(SettingsService.get_filler_half_cycle_ms())

	_loading = false


func _save_settings() -> void:
	if _loading:
		return
	SettingsService.set_master_volume(_master_slider.value)
	if _music_slider != null:
		SettingsService.set_music_volume(_music_slider.value)
	SettingsService.set_fullscreen(_fs_toggle.button_pressed)
	SettingsService.set_resolution_index(_res_dropdown.selected)
	SettingsService.set_intiface_address(_address_input.text)
	SettingsService.set_intiface_auto_connect(_auto_toggle.button_pressed)
	if _device_dropdown.selected >= 0 and _device_dropdown.item_count > 0:
		SettingsService.set_selected_device(
			_device_dropdown.get_item_text(_device_dropdown.selected)
		)

	if _serial_port_dropdown.selected >= 0 and _serial_port_dropdown.item_count > 0:
		SettingsService.set_serial_port(
			_serial_port_dropdown.get_item_text(_serial_port_dropdown.selected)
		)
	var baud: int = _serial_baud_input.text.to_int()
	if baud <= 0:
		baud = DEFAULT_BAUD_RATE
	SettingsService.set_serial_baud(baud)
	SettingsService.set_serial_auto_connect(_serial_auto_toggle.button_pressed)

	if _range_slider != null:
		SettingsService.set_range_min(roundi(_range_slider.lo))
		SettingsService.set_range_max(roundi(_range_slider.hi))

	for axis_def: Array in SECONDARY_AXES:
		var axis_id: String = axis_def[0]
		var ax_slider: RangeSlider = _axis_range_sliders.get(axis_id) as RangeSlider
		if ax_slider != null:
			SettingsService.set_axis_range_min(axis_id, roundi(ax_slider.lo))
			SettingsService.set_axis_range_max(axis_id, roundi(ax_slider.hi))

	if _home_slider != null:
		var home_position: int = roundi(_home_slider.value)
		var home_ease_ms: int = _home_ease_input.text.to_int()
		if home_ease_ms <= 0:
			home_ease_ms = 2000
		SettingsService.set_home_position(home_position)
		SettingsService.set_home_ease_ms(home_ease_ms)
		FunscriptPlayer.SetHomePosition(home_position, home_ease_ms)

	if _vibe_slider != null:
		var vib: int = roundi(_vibe_slider.value)
		SettingsService.set_vibe_intensity(vib)
		FunscriptPlayer.SetVibeIntensity(vib)

	if _max_speed_slider != null:
		var max_speed: int = roundi(_max_speed_slider.value)
		SettingsService.set_max_stroke_speed(max_speed)
		FunscriptPlayer.SetMaxStrokeSpeed(max_speed)

	if _hud_delay_slider != null:
		SettingsService.set_hud_hide_delay(_hud_delay_slider.value)

	if _sensory_slider != null:
		SettingsService.set_sensory_strength(_sensory_slider.value)

	if _ui_scale_slider != null:
		SettingsService.set_ui_scale(_ui_scale_slider.value)

	if _beat_bar_toggle != null:
		SettingsService.set_beat_bar_enabled(_beat_bar_toggle.button_pressed)

	if _beat_shape_dd != null:
		SettingsService.set_beat_bar_shape(BeatBar.SHAPES[_beat_shape_dd.selected])

	if _round_timer_toggle != null:
		SettingsService.set_round_timer_enabled(_round_timer_toggle.button_pressed)

	if _story_text_slider != null:
		SettingsService.set_story_text_scale(_story_text_slider.value)
	if _tooltip_text_slider != null:
		SettingsService.set_tooltip_text_scale(_tooltip_text_slider.value)

	if _update_check_toggle != null:
		SettingsService.set_update_check_enabled(_update_check_toggle.button_pressed)

	if _ui_sound_toggle != null:
		SettingsService.set_ui_sound_enabled(_ui_sound_toggle.button_pressed)
	if _ui_sound_slider != null:
		SettingsService.set_ui_sound_volume(_ui_sound_slider.value)
	# Push the new enabled/volume straight to the live service.
	UISound.reload_settings()

	if _filler_toggle != null:
		SettingsService.set_filler_enabled(_filler_toggle.button_pressed)
		var filler_spd: int = _filler_speed_input.text.to_int()
		if filler_spd <= 0:
			filler_spd = 2000
		SettingsService.set_filler_half_cycle_ms(filler_spd)
		SettingsService.set_filler_lo(roundi(_filler_range_slider.lo))
		SettingsService.set_filler_hi(roundi(_filler_range_slider.hi))

	SettingsService.save()


func _sync_buttplug_state() -> void:
	_is_connected = ButtplugService.BpConnected
	if _is_connected:
		_set_connected_ui(true)
		_device_dropdown.clear()
		for name: String in ButtplugService.GetDeviceNames():
			_device_dropdown.add_item(name)
		_device_dropdown.disabled = _device_dropdown.item_count == 0
	else:
		_set_connected_ui(false)


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------


func _connect_signals() -> void:
	_back_btn.pressed.connect(_on_back_pressed)
	_open_folder_btn.pressed.connect(_on_open_journeys_folder_pressed)
	_master_slider.value_changed.connect(_on_volume_changed)
	_fs_toggle.toggled.connect(_on_fullscreen_toggled)
	_res_dropdown.item_selected.connect(_on_resolution_selected)
	_auto_toggle.toggled.connect(_on_auto_connect_toggled)
	_connect_btn.pressed.connect(_on_connect_pressed)
	_scan_btn.pressed.connect(_on_scan_pressed)
	_device_dropdown.item_selected.connect(_on_device_selected)
	_serial_refresh_btn.pressed.connect(_refresh_serial_ports)
	_serial_connect_btn.pressed.connect(_on_serial_connect_pressed)
	_serial_test_btn.pressed.connect(_on_serial_test_pressed)
	_serial_auto_toggle.toggled.connect(_on_serial_auto_toggled)

	ButtplugService.connect("Connected", _on_bp_connected)
	ButtplugService.connect("Disconnected", _on_bp_disconnected)
	ButtplugService.connect("DeviceAdded", _on_bp_device_added)
	ButtplugService.connect("DeviceRemoved", _on_bp_device_removed)
	ButtplugService.connect("ScanFinished", _on_bp_scan_finished)
	ButtplugService.connect("ErrorOccurred", _on_bp_error)

	SerialDeviceService.connect("Connected", _on_serial_connected)
	SerialDeviceService.connect("Disconnected", _on_serial_disconnected)
	SerialDeviceService.connect("ErrorOccurred", _on_serial_error)


func _on_open_journeys_folder_pressed() -> void:
	var abs_path: String = ProjectSettings.globalize_path(SettingsService.get_journeys_dir())
	if not DirAccess.dir_exists_absolute(abs_path):
		DirAccess.make_dir_recursive_absolute(abs_path)
	OS.shell_open(abs_path)


# ---------------------------------------------------------------------------
# Journey storage location
# ---------------------------------------------------------------------------


# Builds the "STORAGE LOCATION" row showing the current journeys folder with
# Browse + Reset buttons, then slots it into JourneysSection above the
# existing "Open Journeys Folder" row.
# Builds the Transcoding section: a custom ffmpeg-folder picker (with a Test
# button), and the auto-transcode master toggle. Appended to the
# content column like the other code-built sections.
func _build_transcode_section() -> void:
	var section: VBoxContainer = VBoxContainer.new()
	section.add_theme_constant_override("separation", 12)
	_content_vbox.add_child(section)
	_transcode_section = section

	var header: Label = Label.new()
	header.text = "TRANSCODING"
	_style_label(header, UITheme.PURPLE_BRIGHT, 13, true)
	section.add_child(header)

	var divider: HSeparator = HSeparator.new()
	divider.add_theme_stylebox_override("separator", _make_separator_style())
	section.add_child(divider)

	# ffmpeg folder row: label · path · Browse · Test · Use Bundled
	var path_row: HBoxContainer = HBoxContainer.new()
	path_row.add_theme_constant_override("separation", 12)
	section.add_child(path_row)

	var path_lbl: Label = Label.new()
	path_lbl.text = "FFMPEG FOLDER"
	path_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(path_lbl, UITheme.WHITE_SOFT, 14, false)
	path_row.add_child(path_lbl)

	_ffmpeg_path_label = Label.new()
	_ffmpeg_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ffmpeg_path_label.clip_text = true
	_style_label(_ffmpeg_path_label, UITheme.PURPLE_BRIGHT, 12, false)
	path_row.add_child(_ffmpeg_path_label)

	var browse_btn: Button = Button.new()
	browse_btn.text = "📁 BROWSE"
	_style_button(browse_btn, UITheme.PURPLE_MID)
	browse_btn.pressed.connect(_on_ffmpeg_browse_pressed)
	path_row.add_child(browse_btn)

	var test_btn: Button = Button.new()
	test_btn.text = "TEST"
	_style_button(test_btn, UITheme.PURPLE_MID)
	test_btn.pressed.connect(_run_ffmpeg_test)
	path_row.add_child(test_btn)

	var clear_btn: Button = Button.new()
	clear_btn.text = "↺ USE BUNDLED"
	_style_button(clear_btn, UITheme.PURPLE_MID)
	clear_btn.pressed.connect(
		func() -> void:
			SettingsService.set_ffmpeg_dir("")
			SettingsService.save()
			_refresh_ffmpeg_path_label()
			if _ffmpeg_status_label != null:
				_ffmpeg_status_label.text = ""
	)
	path_row.add_child(clear_btn)

	_refresh_ffmpeg_path_label()

	_ffmpeg_status_label = Label.new()
	_ffmpeg_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(_ffmpeg_status_label, UITheme.SEPARATOR, 11, false)
	section.add_child(_ffmpeg_status_label)

	# Auto-transcode master toggle.
	var auto_row: HBoxContainer = HBoxContainer.new()
	auto_row.add_theme_constant_override("separation", 16)
	section.add_child(auto_row)

	var auto_lbl: Label = Label.new()
	auto_lbl.text = "AUTO-TRANSCODE VIDEOS"
	auto_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_label(auto_lbl, UITheme.WHITE_SOFT, 14, false)
	auto_row.add_child(auto_lbl)

	_auto_transcode_toggle = Button.new()
	_auto_transcode_toggle.toggle_mode = true
	_auto_transcode_toggle.focus_mode = Control.FOCUS_NONE
	var auto_on: bool = SettingsService.get_auto_transcode()
	_auto_transcode_toggle.button_pressed = auto_on
	_style_toggle(_auto_transcode_toggle, auto_on)
	_auto_transcode_toggle.toggled.connect(
		func(pressed: bool) -> void:
			_style_toggle(_auto_transcode_toggle, pressed)
			SettingsService.set_auto_transcode(pressed)
			SettingsService.save()
	)
	auto_row.add_child(_auto_transcode_toggle)

	var hint: Label = Label.new()
	hint.text = "On (recommended): videos are converted on save so they'll play — non-H.264 is transcoded, and H.264 in formats the player can't decode (10-bit, 4:2:2) is re-encoded. Off: videos are copied as-is and ffmpeg isn't needed — only use this if you prepare H.264 videos yourself. Leave FFmpeg Folder empty to use the bundled copy; set it only if the bundled ffmpeg won't run (e.g. under Wine)."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(hint, UITheme.SEPARATOR, 11, false)
	section.add_child(hint)


func _refresh_ffmpeg_path_label() -> void:
	if _ffmpeg_path_label == null:
		return
	var dir: String = SettingsService.get_ffmpeg_dir()
	if dir == "":
		_ffmpeg_path_label.text = "(bundled / system PATH)"
		_ffmpeg_path_label.tooltip_text = ""
	else:
		_ffmpeg_path_label.text = dir
		_ffmpeg_path_label.tooltip_text = dir


func _on_ffmpeg_browse_pressed() -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = "Select Folder Containing ffmpeg and ffprobe"
	var cur: String = SettingsService.get_ffmpeg_dir()
	if cur != "" and DirAccess.dir_exists_absolute(cur):
		dialog.current_dir = cur
	add_child(dialog)
	dialog.popup_centered(Vector2i(900, 600))
	dialog.dir_selected.connect(
		func(picked: String) -> void:
			dialog.queue_free()
			SettingsService.set_ffmpeg_dir(picked)
			SettingsService.save()
			_refresh_ffmpeg_path_label()
			_run_ffmpeg_test()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())


# Runs `ffprobe -version` from the resolved location and reports the result, so
# users (especially on Wine) can confirm their ffmpeg actually launches.
func _run_ffmpeg_test() -> void:
	if _ffmpeg_status_label == null:
		return
	var out: Array = []
	# Same resolver the builder's save path uses, so the test reflects reality.
	var code: int = OS.execute(
		SettingsService.resolve_ffmpeg_binary("ffprobe"), ["-version"], out, true, false
	)
	if code == 0:
		var ver: String = ""
		if not out.is_empty():
			ver = (out[0] as String).strip_edges().split("\n")[0]
		_ffmpeg_status_label.add_theme_color_override("font_color", UITheme.SUCCESS)
		_ffmpeg_status_label.text = "✓ ffmpeg works.  %s" % ver
	else:
		_ffmpeg_status_label.add_theme_color_override("font_color", UITheme.ERROR_SOFT)
		_ffmpeg_status_label.text = "✗ Could not run ffprobe from this location. Pick the folder that contains ffmpeg and ffprobe (or install ffmpeg on your PATH)."


func _build_journey_location_row() -> void:
	var journeys_section: VBoxContainer = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/JourneysSection

	var loc_row: HBoxContainer = HBoxContainer.new()
	loc_row.add_theme_constant_override("separation", 12)
	journeys_section.add_child(loc_row)

	var loc_label: Label = Label.new()
	loc_label.text = "STORAGE LOCATION"
	loc_label.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(loc_label, UITheme.WHITE_SOFT, 14, false)
	loc_row.add_child(loc_label)

	_journeys_path_label = Label.new()
	_journeys_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_journeys_path_label.clip_text = true
	_style_label(_journeys_path_label, UITheme.PURPLE_BRIGHT, 12, false)
	loc_row.add_child(_journeys_path_label)
	_refresh_journeys_path_label()

	_journeys_browse_btn = Button.new()
	_journeys_browse_btn.text = "📁 BROWSE"
	_style_button(_journeys_browse_btn, UITheme.PURPLE_MID)
	_journeys_browse_btn.pressed.connect(_on_journeys_browse_pressed)
	loc_row.add_child(_journeys_browse_btn)

	_journeys_reset_btn = Button.new()
	_journeys_reset_btn.text = "↺ RESET"
	_style_button(_journeys_reset_btn, UITheme.PURPLE_MID)
	_journeys_reset_btn.pressed.connect(_on_journeys_reset_pressed)
	loc_row.add_child(_journeys_reset_btn)

	# Slot above the existing Open-Folder row so the location text is visible
	# first (the open button is the action that uses it).
	var open_row: Node = journeys_section.get_node("JourneysRow")
	journeys_section.move_child(loc_row, open_row.get_index())


func _refresh_journeys_path_label() -> void:
	if _journeys_path_label == null:
		return
	var path: String = ProjectSettings.globalize_path(SettingsService.get_journeys_dir())
	_journeys_path_label.text = path
	_journeys_path_label.tooltip_text = path


func _on_journeys_browse_pressed() -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = "Select Journey Storage Folder"
	var current_abs: String = ProjectSettings.globalize_path(SettingsService.get_journeys_dir())
	if DirAccess.dir_exists_absolute(current_abs):
		dialog.current_dir = current_abs
	add_child(dialog)
	dialog.popup_centered(Vector2i(900, 600))
	dialog.dir_selected.connect(
		func(picked: String) -> void:
			dialog.queue_free()
			_apply_new_journeys_dir(picked)
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())


func _on_journeys_reset_pressed() -> void:
	_apply_new_journeys_dir(ProjectSettings.globalize_path(SettingsService.DEFAULT_JOURNEYS_DIR))


# Confirms the change with the user, moves any existing journeys from the old
# location to the new one, and persists the setting. Same-volume moves use a
# fast directory rename; cross-volume moves fall back to recursive copy + delete.
func _apply_new_journeys_dir(new_dir_abs: String) -> void:
	var old_dir_abs: String = ProjectSettings.globalize_path(SettingsService.get_journeys_dir())
	if new_dir_abs == old_dir_abs:
		return  # No-op when the user picks the same folder.

	# Guard against picking a folder nested inside the current one (or vice
	# versa) — moving a tree into itself would create infinite recursion and
	# clobber the source as we copy. globalize_path returns forward-slash form.
	if new_dir_abs.begins_with(old_dir_abs + "/") or old_dir_abs.begins_with(new_dir_abs + "/"):
		var alert: AcceptDialog = AcceptDialog.new()
		alert.title = "INVALID FOLDER"
		alert.dialog_text = "Cannot move journeys into a folder nested inside the current location (or vice versa).\n\nPlease choose a separate folder."
		add_child(alert)
		alert.popup_centered()
		alert.confirmed.connect(func() -> void: alert.queue_free())
		alert.canceled.connect(func() -> void: alert.queue_free())
		return

	# Ensure the new folder exists (and its parents).
	DirAccess.make_dir_recursive_absolute(new_dir_abs)

	var existing: Array = _list_journey_subfolders(old_dir_abs)
	if existing.is_empty():
		# Nothing to move — just persist the setting.
		SettingsService.set_journeys_dir(new_dir_abs)
		SettingsService.save()
		_refresh_journeys_path_label()
		return

	# Confirm with the user before moving — cross-volume moves can take a while.
	var msg: String = (
		"Move %d journey%s\nfrom %s\nto %s?\n\nLarge journeys may take a while if the drive is different."
		% [
			existing.size(),
			"s" if existing.size() != 1 else "",
			old_dir_abs,
			new_dir_abs,
		]
	)
	var confirmed: bool = await _show_move_confirm(msg)
	if not confirmed:
		return

	# Show modal while moving.
	var modal: Control = _create_move_modal()
	add_child(modal)

	var moved: int = 0
	var skipped: int = 0
	var idx: int = 0
	for sub_name: String in existing:
		idx += 1
		_update_move_modal(modal, "Moving %d / %d — %s" % [idx, existing.size(), sub_name])
		await get_tree().process_frame
		var src: String = old_dir_abs + "/" + sub_name
		var dst: String = new_dir_abs + "/" + sub_name
		# Collision-safe: don't clobber a journey already at the destination.
		if DirAccess.dir_exists_absolute(dst):
			skipped += 1
			continue
		if _move_dir(src, dst):
			moved += 1
		else:
			skipped += 1

	modal.queue_free()

	SettingsService.set_journeys_dir(new_dir_abs)
	SettingsService.save()
	_refresh_journeys_path_label()


# Returns subfolder names in `dir_abs` that look like journey folders —
# directories, excluding dot-prefixed staging temps and hidden entries.
func _list_journey_subfolders(dir_abs: String) -> Array:
	var result: Array = []
	if not DirAccess.dir_exists_absolute(dir_abs):
		return result
	var dir: DirAccess = DirAccess.open(dir_abs)
	if dir == null:
		return result
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if dir.current_is_dir() and not fname.begins_with("."):
			result.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	return result


# Fast rename when possible (same volume), otherwise recursive copy + delete.
func _move_dir(src_abs: String, dst_abs: String) -> bool:
	if DirAccess.rename_absolute(src_abs, dst_abs) == OK:
		return true
	# Cross-volume rename fails — fall back to a streaming copy.
	if not _copy_dir_recursive(src_abs, dst_abs):
		# Partial copy left behind — clean it up so we don't leave junk.
		JourneyData.delete_dir_recursive(dst_abs)
		return false
	JourneyData.delete_dir_recursive(src_abs)
	return true


# Recursively copies src_abs → dst_abs. Returns false on any I/O failure.
func _copy_dir_recursive(src_abs: String, dst_abs: String) -> bool:
	DirAccess.make_dir_recursive_absolute(dst_abs)
	var dir: DirAccess = DirAccess.open(src_abs)
	if dir == null:
		return false
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		var src_child: String = src_abs + "/" + fname
		var dst_child: String = dst_abs + "/" + fname
		if dir.current_is_dir():
			if not _copy_dir_recursive(src_child, dst_child):
				dir.list_dir_end()
				return false
		else:
			if DirAccess.copy_absolute(src_child, dst_child) != OK:
				dir.list_dir_end()
				return false
		fname = dir.get_next()
	dir.list_dir_end()
	return true


# Confirmation dialog for the move action. Returns true on Move, false on Cancel.
func _show_move_confirm(message: String) -> bool:
	var popup: ConfirmationDialog = ConfirmationDialog.new()
	popup.title = "MOVE JOURNEYS"
	popup.dialog_text = message
	popup.ok_button_text = "MOVE"
	popup.cancel_button_text = "CANCEL"
	add_child(popup)
	popup.popup_centered()
	var done: Array = [false]  # boxed so lambdas can mutate via reference
	var result: Array = [false]
	popup.confirmed.connect(
		func() -> void:
			result[0] = true
			done[0] = true
	)
	popup.canceled.connect(
		func() -> void:
			result[0] = false
			done[0] = true
	)
	while not done[0]:
		await get_tree().process_frame
	popup.queue_free()
	return result[0]


# Builds the "MOVING JOURNEYS" modal shown during a move operation. The status
# label inside is updated via _update_move_modal as each journey is processed.
func _create_move_modal() -> Control:
	var parts: Dictionary = UITheme.build_centered_modal(
		"MOVING JOURNEYS", UITheme.PURPLE_BRIGHT, Vector2i(600, 160)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	vbox.add_theme_constant_override("separation", 14)

	var status: Label = Label.new()
	status.name = "Status"
	status.text = "Starting…"
	_style_label(status, UITheme.WHITE_SOFT, 13, false)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(status)

	return modal


func _update_move_modal(modal: Control, status_text: String) -> void:
	if modal == null:
		return
	var lbl: Label = modal.find_child("Status", true, false) as Label
	if lbl:
		lbl.text = status_text


func _on_back_pressed() -> void:
	_save_settings()
	if overlay_mode:
		queue_free()
	else:
		Transition.change_scene("res://scenes/main/Main.tscn")


func _on_volume_changed(value: float) -> void:
	_update_volume_label(value)
	AudioServer.set_bus_volume_db(0, linear_to_db(value))
	_save_settings()


func _on_fullscreen_toggled(pressed: bool) -> void:
	_style_toggle(_fs_toggle, pressed)
	_apply_fullscreen(pressed)
	_save_settings()


func _on_resolution_selected(index: int) -> void:
	if not _fs_toggle.button_pressed:
		var res: Vector2i = RESOLUTIONS[index]
		DisplayServer.window_set_size(res)
	_save_settings()


func _on_auto_connect_toggled(pressed: bool) -> void:
	_style_toggle(_auto_toggle, pressed)
	_save_settings()


func _on_connect_pressed() -> void:
	if _is_connected:
		ButtplugService.DisconnectFromIntiface()
	else:
		var address: String = _address_input.text.strip_edges()
		if address.is_empty():
			address = DEFAULT_BP_ADDRESS
		_set_status("● CONNECTING…", UITheme.PURPLE_MID)
		_connect_btn.disabled = true
		ButtplugService.ConnectToIntiface(address)


func _on_scan_pressed() -> void:
	_set_status("● SCANNING…", UITheme.PURPLE_MID)
	_scan_btn.disabled = true
	ButtplugService.StartScan()


func _on_bp_connected() -> void:
	_is_connected = true
	_set_connected_ui(true)


func _on_bp_disconnected() -> void:
	_is_connected = false
	_device_dropdown.clear()
	_device_dropdown.disabled = true
	_set_connected_ui(false)
	_refresh_routing_cards()


func _on_bp_device_added(name: String, _index: int) -> void:
	_device_dropdown.add_item(name)
	_device_dropdown.disabled = false
	_bp_test_btn.disabled = false
	if name == SettingsService.get_selected_device():
		_device_dropdown.selected = _device_dropdown.item_count - 1
	_refresh_routing_cards()


func _on_device_selected(index: int) -> void:
	var name: String = _device_dropdown.get_item_text(index)
	SettingsService.set_selected_device(name)
	SettingsService.save()


func _restore_device_selection(device_name: String) -> void:
	if device_name.is_empty():
		return
	for i: int in _device_dropdown.item_count:
		if _device_dropdown.get_item_text(i) == device_name:
			_device_dropdown.selected = i
			return


func _on_bp_device_removed(index: int) -> void:
	for i: int in _device_dropdown.item_count:
		if _device_dropdown.get_item_id(i) == index:
			_device_dropdown.remove_item(i)
			break
	var no_devices: bool = _device_dropdown.item_count == 0
	_device_dropdown.disabled = no_devices
	_bp_test_btn.disabled = no_devices
	_refresh_routing_cards()


func _on_bp_scan_finished() -> void:
	_scan_btn.disabled = false
	var count: int = _device_dropdown.item_count
	if count > 0:
		_set_status("● %d DEVICE%s FOUND" % [count, "S" if count > 1 else ""], UITheme.OK)
	else:
		_set_status("● NO DEVICES FOUND", UITheme.ERROR)


func _on_bp_error(message: String) -> void:
	_connect_btn.disabled = false
	_set_status("● ERROR: " + message.left(60).to_upper(), UITheme.ERROR)
	_is_connected = false
	_set_connected_ui(false)


# ---------------------------------------------------------------------------
# Device routing (multi-device): device cards + per-actuator source assignment.
# ---------------------------------------------------------------------------


func _build_routing_section() -> void:
	# The routing UI supersedes the old output-mode dropdown + single device picker.
	var vbox_path: String = "ContentPanel/ContentScroll/MarginWrapper/ContentVBox/"
	(get_node(vbox_path + "OutputSection") as Control).visible = false
	(get_node(vbox_path + "IntifaceSection/DeviceRow") as Control).visible = false
	(get_node(vbox_path + "IntifaceSection/ConnectionRow/BpTestBtn") as Control).visible = false

	var section: VBoxContainer = VBoxContainer.new()
	section.add_theme_constant_override("separation", 10)
	_content_vbox.add_child(section)
	_routing_section = section

	var header: Label = Label.new()
	header.text = "DEVICE ROUTING"
	_style_label(header, UITheme.PURPLE_BRIGHT, 13, true)
	section.add_child(header)

	var divider: HSeparator = HSeparator.new()
	divider.add_theme_stylebox_override("separator", _make_separator_style())
	section.add_child(divider)

	_stroker_summary_lbl = Label.new()
	_style_label(_stroker_summary_lbl, UITheme.CYAN, 12, false)
	section.add_child(_stroker_summary_lbl)

	var d_intiface: Dictionary = _add_delay_row(
		section,
		"Intiface delay",
		(
			"Timing offset for Buttplug / Intiface devices, in milliseconds. Positive = the device "
			+ "fires later, negative = earlier. Adjust until the device lines up with the video. "
			+ "Can also be nudged live during play."
		)
	)
	_intiface_delay_slider = d_intiface["slider"]
	_intiface_delay_lbl = d_intiface["value"]
	var d_serial: Dictionary = _add_delay_row(
		section,
		"Serial delay",
		(
			"Timing offset for the serial (T-code) stroker, in milliseconds. Positive = the device "
			+ "fires later, negative = earlier. Adjust until the stroker lines up with the video. "
			+ "Can also be nudged live during play."
		)
	)
	_serial_delay_slider = d_serial["slider"]
	_serial_delay_lbl = d_serial["value"]

	# Serial stroke smoothing (the T-code interp interval factor) — a per-device/firmware tuning for
	# the OSR/SR6 stream. Same row shape as the delays, but a ×factor rather than milliseconds.
	var d_interp: Dictionary = _add_factor_row(
		section,
		"Serial smoothing",
		(
			"How smoothly motion is streamed to a T-code stroker (OSR2 / SR6). Higher = smoother, "
			+ "more fluid strokes; lower = snappier but can look steppy on fast sections. The best "
			+ "value depends on your device — raise it if the motion looks choppy, lower it if it "
			+ "feels laggy or soft."
		)
	)
	_serial_interp_slider = d_interp["slider"]
	_serial_interp_lbl = d_interp["value"]

	_routing_cards_vbox = VBoxContainer.new()
	_routing_cards_vbox.add_theme_constant_override("separation", 8)
	section.add_child(_routing_cards_vbox)

	var hint: Label = Label.new()
	hint.text = "Scan for Buttplug devices, then map each actuator. Exactly one linear device (or serial) is the stroker; constrict runs automatically from stroke activity."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(hint, UITheme.SEPARATOR, 11, false)
	section.add_child(hint)

	# Seed sliders BEFORE connecting so setup doesn't fire the change handlers.
	_intiface_delay_slider.value = SettingsService.get_intiface_delay_ms()
	_intiface_delay_lbl.text = "%d ms" % SettingsService.get_intiface_delay_ms()
	_serial_delay_slider.value = SettingsService.get_serial_delay_ms()
	_serial_delay_lbl.text = "%d ms" % SettingsService.get_serial_delay_ms()
	_serial_interp_slider.value = SettingsService.get_serial_interp_factor()
	_serial_interp_lbl.text = "%.1f×" % SettingsService.get_serial_interp_factor()
	_intiface_delay_slider.value_changed.connect(_on_intiface_delay_changed)
	_serial_delay_slider.value_changed.connect(_on_serial_delay_changed)
	_serial_interp_slider.value_changed.connect(_on_serial_interp_changed)
	_refresh_routing_cards()


# ── The Handy (direct WiFi) ──────────────────────────────────────────────────


# Connection-key setup for driving The Handy through its official v3 streaming
# API (HSP) — no Intiface needed. Includes the plain-language disclosure this
# mode demands: motion routes through Handy's cloud (needs internet, FW4+).
func _build_handy_section() -> void:
	var section: VBoxContainer = VBoxContainer.new()
	section.add_theme_constant_override("separation", 10)
	_content_vbox.add_child(section)
	_handy_section = section  # tracked so _on_tab_changed can scope it to CONNECTION

	var header: Label = Label.new()
	header.text = "THE HANDY (WIFI — NO INTIFACE)"
	_style_label(header, UITheme.PURPLE_BRIGHT, 13, true)
	section.add_child(header)

	var divider: HSeparator = HSeparator.new()
	divider.add_theme_stylebox_override("separator", _make_separator_style())
	section.add_child(divider)

	var key_row: HBoxContainer = HBoxContainer.new()
	key_row.add_theme_constant_override("separation", 16)
	section.add_child(key_row)

	var key_lbl: Label = Label.new()
	key_lbl.text = "Connection key"
	key_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(key_lbl, UITheme.WHITE_SOFT, 14, false)
	key_row.add_child(key_lbl)

	var key_edit: LineEdit = LineEdit.new()
	key_edit.placeholder_text = "From the Handy app: Settings → Connection Key"
	key_edit.text = SettingsService.get_handy_connection_key()
	key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(key_edit)
	key_row.add_child(key_edit)

	_handy_status_lbl = Label.new()
	_handy_status_lbl.text = (
		"Not checked" if SettingsService.get_handy_connection_key() != "" else "No key set"
	)
	_style_label(_handy_status_lbl, UITheme.PURPLE_MID, 11, true)
	key_row.add_child(_handy_status_lbl)

	var connect_btn: Button = UITheme.make_icon_btn("⟳ CONNECT", false, UITheme.CYAN)
	connect_btn.tooltip_text = "Save the key and check the device through Handy's servers"
	key_row.add_child(connect_btn)
	connect_btn.pressed.connect(
		func() -> void:
			SettingsService.set_handy_connection_key(key_edit.text)
			SettingsService.save()
			_refresh_routing_cards()  # the routing card appears once a key exists
			_handy_status_lbl.text = "Checking…"
			var ok: bool = await HandyService.connect_and_sync()
			_handy_status_lbl.text = "✔ Connected" if ok else "✕ Not reachable"
	)

	var d_handy: Dictionary = _add_delay_row(section, "Handy delay")
	var handy_slider: HSlider = d_handy["slider"]
	var handy_lbl: Label = d_handy["value"]
	handy_slider.value = SettingsService.get_handy_delay_ms()
	handy_lbl.text = "%d ms" % SettingsService.get_handy_delay_ms()
	handy_slider.value_changed.connect(
		func(v: float) -> void:
			handy_lbl.text = "%d ms" % roundi(v)
			SettingsService.set_handy_delay_ms(roundi(v))
			SettingsService.save()
	)

	var disclosure: Label = Label.new()
	disclosure.text = (
		"Direct Handy mode streams motion through Handy's cloud service "
		+ "(handyfeeling.com) and needs an internet connection. Requires Handy "
		+ "firmware 4+. Stroke-modifying items, curses, boss effects, and your "
		+ "stroke range all reach the device; a change made mid-round takes effect "
		+ "a fraction of a second later."
	)
	disclosure.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(disclosure, UITheme.SEPARATOR, 11, false)
	section.add_child(disclosure)


# ---------------------------------------------------------------------------
# restim (e-stim) section — network T-code over WebSocket
# ---------------------------------------------------------------------------


func _build_restim_section() -> void:
	var section: VBoxContainer = VBoxContainer.new()
	section.add_theme_constant_override("separation", 10)
	_content_vbox.add_child(section)
	_restim_section = section

	var header: Label = Label.new()
	header.text = "RESTIM (E-STIM)"
	_style_label(header, UITheme.PURPLE_BRIGHT, 13, true)
	section.add_child(header)

	var divider: HSeparator = HSeparator.new()
	divider.add_theme_stylebox_override("separator", _make_separator_style())
	section.add_child(divider)

	# Address is two fields (server + path) so the endpoint path can't be missed.
	_restim_server_input = _add_restim_text_row(section, "Server", "ws://127.0.0.1:12346")
	_restim_path_input = _add_restim_text_row(section, "Path", "/tcode")

	var auto_row: HBoxContainer = HBoxContainer.new()
	auto_row.add_theme_constant_override("separation", 16)
	section.add_child(auto_row)
	var auto_lbl: Label = Label.new()
	auto_lbl.text = "Auto-connect on launch"
	auto_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(auto_lbl, UITheme.WHITE_SOFT, 14, false)
	auto_row.add_child(auto_lbl)
	_restim_auto_toggle = Button.new()
	_restim_auto_toggle.toggle_mode = true
	_restim_auto_toggle.focus_mode = Control.FOCUS_NONE
	auto_row.add_child(_restim_auto_toggle)

	var conn_row: HBoxContainer = HBoxContainer.new()
	conn_row.add_theme_constant_override("separation", 16)
	section.add_child(conn_row)
	_restim_connect_btn = Button.new()
	_restim_connect_btn.text = "> CONNECT"
	_restim_connect_btn.focus_mode = Control.FOCUS_NONE
	_style_button(_restim_connect_btn, UITheme.PURPLE_BRIGHT)
	conn_row.add_child(_restim_connect_btn)
	_restim_status_lbl = Label.new()
	_style_label(_restim_status_lbl, UITheme.SEPARATOR, 12, true)
	conn_row.add_child(_restim_status_lbl)

	var hint: Label = Label.new()
	hint.text = "Streams the round's funscripts to restim as E-Stim Full T-code over WebSocket. Connecting turns the serial device off. Per-axis levels (Volume, Alpha/Beta, Carrier, Pulse, Vibration) live under E-STIM DEVICE on the Device tab."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(hint, UITheme.SEPARATOR, 11, false)
	section.add_child(hint)

	# Seed controls BEFORE connecting handlers so setup doesn't fire saves.
	_restim_server_input.text = SettingsService.get_restim_server()
	_restim_path_input.text = SettingsService.get_restim_path()
	var auto_on: bool = SettingsService.get_restim_auto_connect()
	_restim_auto_toggle.button_pressed = auto_on
	_style_toggle(_restim_auto_toggle, auto_on)

	_restim_server_input.text_changed.connect(
		func(t: String) -> void:
			SettingsService.set_restim_server(t)
			SettingsService.save()
	)
	_restim_path_input.text_changed.connect(
		func(t: String) -> void:
			SettingsService.set_restim_path(t)
			SettingsService.save()
	)
	_restim_auto_toggle.toggled.connect(_on_restim_auto_toggled)
	_restim_connect_btn.pressed.connect(_on_restim_connect_pressed)

	RestimService.connect("Connected", _on_restim_connected)
	RestimService.connect("Disconnected", _on_restim_disconnected)
	RestimService.connect("ErrorOccurred", _on_restim_error)

	_sync_restim_state()


# Per-axis e-stim levels. Deliberately on the DEVICE tab rather than CONNECTION:
# these are ongoing output tuning (the same kind of thing as the T-code ranges
# above them), not part of getting connected. Each row seeds and saves itself.
func _build_restim_axes_section() -> void:
	var section: VBoxContainer = VBoxContainer.new()
	section.add_theme_constant_override("separation", 10)
	_content_vbox.add_child(section)
	_restim_axes_section = section

	var header: Label = Label.new()
	header.text = "E-STIM DEVICE"
	_style_label(header, UITheme.PURPLE_BRIGHT, 13, true)
	section.add_child(header)

	var divider: HSeparator = HSeparator.new()
	divider.add_theme_stylebox_override("separator", _make_separator_style())
	section.add_child(divider)

	var hint: Label = Label.new()
	hint.text = "Motion axes (Alpha/Beta/Carrier/Pulse-freq/Vib1) follow their funscripts when a round provides them; these sliders set every other axis. Raise Volume — at 0 restim is silent. Changes apply live to a connected session."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(hint, UITheme.SEPARATOR, 11, false)
	section.add_child(hint)

	for group: Array in RESTIM_AXIS_GROUPS:
		var group_lbl: Label = Label.new()
		group_lbl.text = str(group[0])
		_style_label(group_lbl, UITheme.CYAN, 11, true)
		section.add_child(group_lbl)
		for entry: Array in group[1]:
			_add_restim_axis_row(section, str(entry[0]), str(entry[1]))


func _add_restim_text_row(parent: VBoxContainer, label_text: String, placeholder: String) -> LineEdit:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl: Label = Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(lbl, UITheme.WHITE_SOFT, 14, false)
	row.add_child(lbl)

	var edit: LineEdit = LineEdit.new()
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_line_edit(edit)
	row.add_child(edit)
	return edit


func _add_restim_axis_row(parent: VBoxContainer, axis: String, label_text: String) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl: Label = Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(lbl, UITheme.WHITE_SOFT, 13, false)
	row.add_child(lbl)

	var slider: HSlider = HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_slider(slider)
	row.add_child(slider)

	var value_lbl: Label = Label.new()
	value_lbl.custom_minimum_size = Vector2(VALUE_LABEL_W, 0)
	_style_label(value_lbl, UITheme.PURPLE_MID, 11, true)
	row.add_child(value_lbl)

	var initial: int = SettingsService.get_restim_axis(axis)
	slider.value = initial
	value_lbl.text = "%d%%" % initial

	slider.value_changed.connect(
		func(v: float) -> void:
			var iv: int = roundi(v)
			value_lbl.text = "%d%%" % iv
			SettingsService.set_restim_axis(axis, iv)
			SettingsService.save()
			FunscriptPlayer.SetRestimAxisValue(axis, iv)
	)

	_restim_axis_sliders[axis] = slider
	_restim_axis_value_lbls[axis] = value_lbl


func _on_restim_auto_toggled(pressed: bool) -> void:
	_style_toggle(_restim_auto_toggle, pressed)
	SettingsService.set_restim_auto_connect(pressed)
	SettingsService.save()


func _on_restim_connect_pressed() -> void:
	if RestimService.RestimConnected:
		RestimService.Disconnect()
		return

	var server: String = _restim_server_input.text.strip_edges()
	if server.is_empty():
		_set_restim_status("● NO SERVER", UITheme.ERROR)
		return
	var path: String = _restim_path_input.text.strip_edges()
	var addr: String = server.trim_suffix("/")
	if not path.is_empty():
		if not path.begins_with("/"):
			path = "/" + path
		addr += path

	_set_restim_status("● CONNECTING…", UITheme.PURPLE_MID)
	_restim_connect_btn.disabled = true
	RestimService.Connect(addr)


func _on_restim_connected() -> void:
	_restim_connect_btn.disabled = false
	_set_restim_status("● CONNECTED", UITheme.OK)
	_style_button(_restim_connect_btn, UITheme.MAGENTA)
	_restim_connect_btn.text = "> DISCONNECT"
	FunscriptPlayer.SendRestimManualState()
	# restim turns the serial device off on connect — refresh the serial UI to match.
	_sync_serial_state()


func _on_restim_disconnected() -> void:
	_restim_connect_btn.disabled = false
	_set_restim_status("● DISCONNECTED", UITheme.ERROR)
	_style_button(_restim_connect_btn, UITheme.PURPLE_BRIGHT)
	_restim_connect_btn.text = "> CONNECT"


func _on_restim_error(message: String) -> void:
	_restim_connect_btn.disabled = false
	_set_restim_status("● ERROR: " + message.left(60).to_upper(), UITheme.ERROR)


func _set_restim_status(text: String, color: Color) -> void:
	_restim_status_lbl.text = text
	_restim_status_lbl.add_theme_color_override("font_color", color)


func _sync_restim_state() -> void:
	if RestimService.RestimConnected:
		_set_restim_status("● CONNECTED", UITheme.OK)
		_style_button(_restim_connect_btn, UITheme.MAGENTA)
		_restim_connect_btn.text = "> DISCONNECT"
	else:
		_set_restim_status("● DISCONNECTED", UITheme.ERROR)
		_style_button(_restim_connect_btn, UITheme.PURPLE_BRIGHT)
		_restim_connect_btn.text = "> CONNECT"


func _add_delay_row(parent: VBoxContainer, label_text: String, tip: String = "") -> Dictionary:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl: Label = Label.new()
	lbl.text = label_text
	if tip != "":
		lbl.tooltip_text = UITheme.wrap_tip(tip)
	lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(lbl, UITheme.WHITE_SOFT, 14, false)
	row.add_child(lbl)

	var slider: HSlider = HSlider.new()
	slider.min_value = -2000
	slider.max_value = 2000
	slider.step = 10
	if tip != "":
		slider.tooltip_text = UITheme.wrap_tip(tip)  # on the slider too — a Label often won't show a tooltip
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_slider(slider)
	row.add_child(slider)

	var value_lbl: Label = Label.new()
	value_lbl.text = "0 ms"
	value_lbl.custom_minimum_size = Vector2(60, 0)
	_style_label(value_lbl, UITheme.PURPLE_MID, 11, true)
	row.add_child(value_lbl)

	return {"slider": slider, "value": value_lbl}


# A labelled 1.0–4.0 ×factor slider row (mirrors _add_delay_row's shape). Returns {slider, value};
# the caller seeds the value, formats the label, and wires value_changed.
func _add_factor_row(parent: VBoxContainer, label_text: String, tip: String) -> Dictionary:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl: Label = Label.new()
	lbl.text = label_text
	lbl.tooltip_text = UITheme.wrap_tip(tip)
	lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(lbl, UITheme.WHITE_SOFT, 14, false)
	row.add_child(lbl)

	var slider: HSlider = HSlider.new()
	slider.min_value = 1.0
	slider.max_value = 4.0
	slider.step = 0.1
	slider.tooltip_text = UITheme.wrap_tip(tip)  # on the slider too — a Label often won't show a tooltip
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_slider(slider)
	row.add_child(slider)

	var value_lbl: Label = Label.new()
	value_lbl.text = "1.0×"
	value_lbl.custom_minimum_size = Vector2(60, 0)
	_style_label(value_lbl, UITheme.PURPLE_MID, 11, true)
	row.add_child(value_lbl)

	return {"slider": slider, "value": value_lbl}


# Rebuilds the device cards from the live Buttplug catalog. Cheap — called on connect / scan / add / remove.
func _refresh_routing_cards() -> void:
	if _routing_cards_vbox == null:
		return
	for c in _routing_cards_vbox.get_children():
		c.queue_free()

	# Serial (T-code) — a single-device stroker option, always offered.
	var serial_body: VBoxContainer = _make_routing_card("SERIAL (T-CODE)", UITheme.AMBER)
	_add_stroker_row(serial_body, DeviceRouting.SERIAL_TARGET, "Linear (T-code stroke)")

	# The Handy (direct WiFi) — offered once a connection key is configured in
	# its section below. Stroke role only (single-axis device, cloud-synced).
	if SettingsService.get_handy_connection_key() != "":
		var handy_body: VBoxContainer = _make_routing_card("THE HANDY (WIFI)", UITheme.CYAN)
		_add_stroker_row(handy_body, DeviceRouting.HANDY_TARGET, "Linear (cloud sync)")
		var handy_note: Label = Label.new()
		handy_note.text = "Stroke items, curses & range all reach this device."
		handy_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_style_label(handy_note, UITheme.SEPARATOR, 10, false)
		handy_body.add_child(handy_note)

	var catalog: Array = ButtplugService.GetDeviceCatalog()
	if catalog.is_empty():
		var none_body: VBoxContainer = _make_routing_card("BUTTPLUG", UITheme.PURPLE_MID)
		var lbl: Label = Label.new()
		lbl.text = "No devices — connect Intiface and Scan."
		_style_label(lbl, UITheme.SEPARATOR, 11, false)
		none_body.add_child(lbl)
	else:
		for entry: Dictionary in catalog:
			var dev_id: String = str(entry.get("id", ""))
			var body: VBoxContainer = _make_routing_card(
				str(entry.get("name", dev_id)).to_upper(), UITheme.PURPLE_BRIGHT
			)
			if bool(entry.get("linear", false)):
				_add_stroker_row(
					body, DeviceRouting.make_actuator_id(dev_id, "linear", 0), "Linear"
				)
			for ch in int(entry.get("vibrate_channels", 0)):
				_add_vibe_row(
					body,
					DeviceRouting.make_actuator_id(dev_id, "vibrate", ch),
					"Vibrate %d" % (ch + 1)
				)
			for ch in int(entry.get("constrict_channels", 0)):
				_add_constrict_row(
					body,
					DeviceRouting.make_actuator_id(dev_id, "constrict", ch),
					"Constrict %d" % (ch + 1)
				)
			_add_device_test_row(
				body, int(entry.get("index", -1)), bool(entry.get("linear", false))
			)

	_update_stroker_summary()


# A titled, accent-bordered card added to the cards container; returns its body VBox for the caller to fill.
func _make_routing_card(title: String, accent: Color) -> VBoxContainer:
	var card: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL_BG
	style.border_color = Color(accent.r, accent.g, accent.b, 0.4)
	style.set_border_width_all(1)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	card.add_theme_stylebox_override("panel", style)
	_routing_cards_vbox.add_child(card)

	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	card.add_child(body)

	var title_lbl: Label = Label.new()
	title_lbl.text = title
	_style_label(title_lbl, accent, 12, true)
	body.add_child(title_lbl)
	return body


func _add_stroker_row(body: VBoxContainer, target_id: String, label_text: String) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	body.add_child(row)

	var lbl: Label = Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_label(lbl, UITheme.WHITE_SOFT, 12, false)
	row.add_child(lbl)

	var is_stroker: bool = SettingsService.get_stroke_target() == target_id
	var btn: Button = Button.new()
	btn.toggle_mode = true
	btn.button_pressed = is_stroker
	btn.text = "◉ STROKER" if is_stroker else "○ STROKER"
	btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button_subtle(btn, UITheme.CYAN)
	btn.pressed.connect(func() -> void: _set_stroker(target_id))
	row.add_child(btn)


func _add_vibe_row(body: VBoxContainer, actuator_id: String, label_text: String) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	body.add_child(row)

	var lbl: Label = Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_label(lbl, UITheme.WHITE_SOFT, 12, false)
	row.add_child(lbl)

	var dd: OptionButton = OptionButton.new()
	dd.custom_minimum_size = Vector2(160, 0)
	dd.focus_mode = Control.FOCUS_NONE
	dd.add_item("Off")
	dd.add_item("vibe1")
	dd.add_item("vibe2")
	dd.add_item("Follow stroke")
	UITheme.style_option_button(dd)
	var cur: String = str(SettingsService.get_vibration_routes().get(actuator_id, ""))
	dd.selected = {"": 0, "vibe1": 1, "vibe2": 2, "stroke": 3}.get(cur, 0)
	dd.item_selected.connect(func(idx: int) -> void: _on_vibe_source_selected(actuator_id, idx))
	row.add_child(dd)


func _add_constrict_row(body: VBoxContainer, actuator_id: String, label_text: String) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	body.add_child(row)

	var lbl: Label = Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_label(lbl, UITheme.WHITE_SOFT, 12, false)
	row.add_child(lbl)

	var on: bool = bool(SettingsService.get_constrict_routes().get(actuator_id, false))
	var btn: Button = Button.new()
	btn.toggle_mode = true
	btn.button_pressed = on
	btn.text = "AUTO" if on else "OFF"
	btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button_subtle(btn, Color(0.45, 0.95, 0.30))
	btn.pressed.connect(func() -> void: _on_constrict_toggled(actuator_id, btn.button_pressed))
	row.add_child(btn)


func _add_device_test_row(body: VBoxContainer, device_index: int, is_linear: bool) -> void:
	var btn: Button = Button.new()
	btn.text = "TEST"
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	UITheme.style_button_subtle(btn, UITheme.PURPLE_MID)
	btn.pressed.connect(func() -> void: _test_bp_device(device_index, is_linear, btn))
	body.add_child(btn)


# Exercises one Buttplug device by its live index — a stroke sweep for linear devices, a vibe pulse
# otherwise. Independent of the routing config, so it verifies the device is alive and correctly mapped.
func _test_bp_device(device_index: int, is_linear: bool, btn: Button) -> void:
	if not ButtplugService.BpConnected or device_index < 0:
		return
	btn.disabled = true
	if is_linear:
		ButtplugService.SendLinear(device_index, 600, 1.0)
		await get_tree().create_timer(0.7).timeout
		ButtplugService.SendLinear(device_index, 600, 0.0)
		await get_tree().create_timer(0.7).timeout
		ButtplugService.SendLinear(device_index, 400, 0.5)
	else:
		ButtplugService.SendVibrate(device_index, 1.0)
		await get_tree().create_timer(0.7).timeout
		ButtplugService.SendVibrate(device_index, 0.0)
	if is_instance_valid(btn):
		btn.disabled = false


func _set_stroker(target_id: String) -> void:
	# Radio behaviour across all backends; a second press on the current stroker clears it.
	var cur: String = SettingsService.get_stroke_target()
	SettingsService.set_stroke_target("" if cur == target_id else target_id)
	SettingsService.save()
	_refresh_routing_cards()


func _on_vibe_source_selected(actuator_id: String, idx: int) -> void:
	var routes: Dictionary = SettingsService.get_vibration_routes()
	var source: String = ["", "vibe1", "vibe2", "stroke"][idx]
	if source == "":
		routes.erase(actuator_id)
	else:
		routes[actuator_id] = source
	SettingsService.set_vibration_routes(routes)
	SettingsService.save()


func _on_constrict_toggled(actuator_id: String, on: bool) -> void:
	var routes: Dictionary = SettingsService.get_constrict_routes()
	if on:
		routes[actuator_id] = true
	else:
		routes.erase(actuator_id)
	SettingsService.set_constrict_routes(routes)
	SettingsService.save()


func _on_intiface_delay_changed(v: float) -> void:
	_intiface_delay_lbl.text = "%d ms" % roundi(v)
	SettingsService.set_intiface_delay_ms(roundi(v))
	SettingsService.save()
	FunscriptPlayer.SetIntifaceDelay(roundi(v))


func _on_serial_delay_changed(v: float) -> void:
	_serial_delay_lbl.text = "%d ms" % roundi(v)
	SettingsService.set_serial_delay_ms(roundi(v))
	SettingsService.save()
	FunscriptPlayer.SetSerialDelay(roundi(v))


func _on_serial_interp_changed(v: float) -> void:
	_serial_interp_lbl.text = "%.1f×" % v
	SettingsService.set_serial_interp_factor(v)
	SettingsService.save()
	FunscriptPlayer.SetSerialInterpFactor(v)


func _update_stroker_summary() -> void:
	if _stroker_summary_lbl == null:
		return
	var target: String = SettingsService.get_stroke_target()
	if target == DeviceRouting.SERIAL_TARGET:
		_stroker_summary_lbl.text = "Stroker: Serial (T-code)"
	elif target == DeviceRouting.HANDY_TARGET:
		_stroker_summary_lbl.text = "Stroker: The Handy (WiFi)"
	elif target != "":
		_stroker_summary_lbl.text = (
			"Stroker: %s" % str(DeviceRouting.parse_actuator_id(target).get("device", target))
		)
	else:
		_stroker_summary_lbl.text = "Stroker: (none set)"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


func _set_connected_ui(connected: bool) -> void:
	_connect_btn.disabled = false
	_scan_btn.disabled = not connected
	_bp_test_btn.disabled = not connected or _device_dropdown.item_count == 0
	if connected:
		_style_button(_connect_btn, UITheme.MAGENTA)
		_connect_btn.text = "> DISCONNECT"
		_set_status("● CONNECTED", UITheme.OK)
	else:
		_style_button(_connect_btn, UITheme.PURPLE_BRIGHT)
		_connect_btn.text = "> CONNECT"
		_set_status("● DISCONNECTED", UITheme.ERROR)


func _set_status(text: String, color: Color) -> void:
	_status_lbl.text = text
	_status_lbl.add_theme_color_override("font_color", color)


func _update_volume_label(value: float) -> void:
	_master_value.text = "%d%%" % roundi(value * 100.0)


func _apply_fullscreen(enabled: bool) -> void:
	var mode: DisplayServer.WindowMode = (
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
		if enabled
		else DisplayServer.WINDOW_MODE_WINDOWED
	)
	DisplayServer.window_set_mode(mode)


# ---------------------------------------------------------------------------
# Output mode + Serial
# ---------------------------------------------------------------------------


func _on_serial_auto_toggled(pressed: bool) -> void:
	_style_toggle(_serial_auto_toggle, pressed)
	_save_settings()


func _on_serial_connect_pressed() -> void:
	if SerialDeviceService.SerialConnected:
		SerialDeviceService.Disconnect()
		return
	if _serial_port_dropdown.selected < 0 or _serial_port_dropdown.item_count == 0:
		_set_serial_status("● NO PORT SELECTED", UITheme.ERROR)
		return
	var port: String = _serial_port_dropdown.get_item_text(_serial_port_dropdown.selected)
	var baud: int = _serial_baud_input.text.to_int()
	if baud <= 0:
		baud = DEFAULT_BAUD_RATE
	_set_serial_status("● CONNECTING…", UITheme.PURPLE_MID)
	_serial_connect_btn.disabled = true
	SerialDeviceService.Connect(port, baud)


func _on_serial_test_pressed() -> void:
	if not SerialDeviceService.SerialConnected:
		_set_serial_status("● NOT CONNECTED", UITheme.ERROR)
		return
	# Quick stroke: top in 600ms, bottom in 600ms, midpoint in 400ms.
	SerialDeviceService.SendLinear(600, 1.0)
	await get_tree().create_timer(0.7).timeout
	SerialDeviceService.SendLinear(600, 0.0)
	await get_tree().create_timer(0.7).timeout
	SerialDeviceService.SendLinear(400, 0.5)


func _on_serial_connected() -> void:
	_serial_connect_btn.disabled = false
	_set_serial_status("● CONNECTED", UITheme.OK)
	_style_button(_serial_connect_btn, UITheme.MAGENTA)
	_serial_connect_btn.text = "> DISCONNECT"


func _on_serial_disconnected() -> void:
	_serial_connect_btn.disabled = false
	_set_serial_status("● DISCONNECTED", UITheme.ERROR)
	_style_button(_serial_connect_btn, UITheme.PURPLE_BRIGHT)
	_serial_connect_btn.text = "> CONNECT"


func _on_serial_error(message: String) -> void:
	_serial_connect_btn.disabled = false
	_set_serial_status("● ERROR: " + message.left(60).to_upper(), UITheme.ERROR)


func _set_serial_status(text: String, color: Color) -> void:
	_serial_status_lbl.text = text
	_serial_status_lbl.add_theme_color_override("font_color", color)


func _sync_serial_state() -> void:
	if SerialDeviceService.SerialConnected:
		_set_serial_status("● CONNECTED", UITheme.OK)
		_style_button(_serial_connect_btn, UITheme.MAGENTA)
		_serial_connect_btn.text = "> DISCONNECT"
	else:
		_set_serial_status("● DISCONNECTED", UITheme.ERROR)
		_style_button(_serial_connect_btn, UITheme.PURPLE_BRIGHT)
		_serial_connect_btn.text = "> CONNECT"
