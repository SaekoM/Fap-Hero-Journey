extends Control

# ---------------------------------------------------------------------------
# Options.gd
# Purple matrix theme. Audio, display, and Intiface/Buttplug settings.
# Reads/writes all settings through the SettingsService autoload.
# ---------------------------------------------------------------------------

const TOP_BAR_HEIGHT:  int = 64
const TAB_BAR_HEIGHT:  int = 48
const PANEL_HALF_W:    int = 480
const PANEL_PAD_V:     int = 24
const BORDER_WIDTH:    int = 3
const ROW_LABEL_W:     int = 260
const SLIDER_MIN_W:    int = 260
const VALUE_LABEL_W:   int = 64

# Tab categories. Each groups a set of sections; only one tab is shown at a time.
const TAB_NAMES: Array = ["GENERAL", "CONNECTION", "DEVICE", "ABOUT"]

const DEFAULT_BP_ADDRESS:  String = "ws://localhost:12345"
const DEFAULT_BAUD_RATE:   int    = 115200
const OUTPUT_MODES:        Array  = ["Buttplug (Intiface)", "Serial T-code (SR6 / OSR2)"]
const OUTPUT_MODE_KEYS:    Array  = ["buttplug", "serial"]

const RESOLUTIONS: Array = [
	Vector2i(1280, 720),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]

@onready var _bg:              ColorRect     = $Background
@onready var _top_bar:         HBoxContainer = $TopBar
@onready var _back_btn:        Button        = $TopBar/BackButton
@onready var _title_lbl:       Label         = $TopBar/TitleLabel
@onready var _content_panel:   PanelContainer = $ContentPanel
@onready var _content_vbox:    VBoxContainer  = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox
@onready var _master_slider:   HSlider        = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow/MasterSlider
@onready var _master_value:    Label          = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow/MasterValue
@onready var _fs_toggle:       Button         = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/FullscreenRow/FsToggle
@onready var _res_dropdown:    OptionButton   = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/ResolutionRow/ResDropdown
@onready var _address_input:   LineEdit       = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AddressRow/AddressInput
@onready var _auto_toggle:     Button         = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AutoConnectRow/AutoConnectToggle
@onready var _connect_btn:     Button         = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/ConnectBtn
@onready var _scan_btn:        Button         = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/ScanBtn
@onready var _status_lbl:      Label          = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/StatusLabel
@onready var _device_dropdown: OptionButton   = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/DeviceRow/DeviceDropdown
@onready var _bp_test_btn:     Button         = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/BpTestBtn

@onready var _open_folder_btn:      Button       = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/JourneysSection/JourneysRow/OpenFolderBtn

@onready var _output_mode_dropdown: OptionButton = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/OutputSection/OutputModeRow/OutputModeDropdown

@onready var _serial_port_dropdown: OptionButton = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialPortRow/SerialPortDropdown
@onready var _serial_refresh_btn:   Button       = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialPortRow/SerialRefreshBtn
@onready var _serial_baud_input:    LineEdit     = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialBaudRow/SerialBaudInput
@onready var _serial_auto_toggle:   Button       = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialAutoRow/SerialAutoToggle
@onready var _serial_connect_btn:   Button       = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialConnRow/SerialConnectBtn
@onready var _serial_test_btn:      Button       = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialConnRow/SerialTestBtn
@onready var _serial_status_lbl:    Label        = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/SerialSection/SerialConnRow/SerialStatusLabel

var _is_connected: bool = false
var overlay_mode: bool = false
var _loading: bool = false

var _music_slider:    HSlider = null
var _music_value_lbl: Label   = null

var _range_slider:  RangeSlider = null
var _range_min_lbl: Label       = null
var _range_max_lbl: Label       = null

var _home_slider:    HSlider  = null
var _home_value_lbl: Label    = null
var _home_ease_input: LineEdit = null

var _latency_slider:    HSlider = null
var _latency_value_lbl: Label   = null
var _vibe_slider:       HSlider = null
var _vibe_value_lbl:    Label   = null
var _max_speed_slider:    HSlider = null
var _max_speed_value_lbl: Label   = null
var _hud_delay_slider:    HSlider = null
var _hud_delay_value_lbl: Label   = null

var _filler_toggle:     Button      = null
var _filler_speed_input: LineEdit   = null
var _filler_range_slider:  RangeSlider = null
var _filler_range_min_lbl: Label       = null
var _filler_range_max_lbl: Label       = null

# Tab bar + references to the three code-built sections, needed so tab
# switching can toggle their visibility alongside the scene-built sections.
var _tab_bar:         TabBar        = null
var _range_section:   VBoxContainer = null
var _filler_section:  VBoxContainer = null
var _credits_section: VBoxContainer = null


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_populate_resolution_dropdown()
	_populate_output_mode_dropdown()
	_refresh_serial_ports()
	_load_settings()
	_connect_signals()
	_sync_buttplug_state()
	_sync_serial_state()


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
	_top_bar.offset_left   = 16
	_top_bar.offset_right  = -16
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_top_bar.add_theme_constant_override("separation", 0)

	_content_panel.anchor_left   = 0.5
	_content_panel.anchor_right  = 0.5
	_content_panel.anchor_top    = 0.0
	_content_panel.anchor_bottom = 1.0
	_content_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_content_panel.offset_left   = -PANEL_HALF_W
	_content_panel.offset_right  =  PANEL_HALF_W
	_content_panel.offset_top    = TOP_BAR_HEIGHT + TAB_BAR_HEIGHT + PANEL_PAD_V
	_content_panel.offset_bottom = -PANEL_PAD_V

	($ContentPanel/ContentScroll/MarginWrapper as MarginContainer).add_theme_constant_override("margin_right", 24)

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
		var s: VBoxContainer = get_node(section_path)
		s.add_theme_constant_override("separation", 12)

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
		var r: HBoxContainer = get_node(row_path)
		r.add_theme_constant_override("separation", 16)

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
	_master_value.custom_minimum_size  = Vector2(VALUE_LABEL_W, 0)

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

	_music_slider.value_changed.connect(func(v: float) -> void:
		_music_value_lbl.text = "%d%%" % roundi(v * 100.0)
		MusicService.set_volume(v)
		_save_settings()
	)

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

	_hud_delay_slider.value_changed.connect(func(v: float) -> void:
		_hud_delay_value_lbl.text = "%.1fs" % v
		_save_settings()
	)

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

	_res_dropdown.custom_minimum_size  = Vector2(220, 0)
	_device_dropdown.custom_minimum_size = Vector2(220, 0)
	_output_mode_dropdown.custom_minimum_size = Vector2(280, 0)
	_serial_port_dropdown.custom_minimum_size = Vector2(180, 0)

	# ── Device Range section (built entirely in code) ─────────────────────────
	var range_section: VBoxContainer = VBoxContainer.new()
	range_section.add_theme_constant_override("separation", 12)
	_content_vbox.add_child(range_section)
	_range_section = range_section

	var range_header: Label = Label.new()
	range_header.text = "DEVICE RANGE"
	_style_label(range_header, UITheme.PURPLE_BRIGHT, 13, true)
	range_section.add_child(range_header)

	var range_divider: HSeparator = HSeparator.new()
	range_divider.add_theme_stylebox_override("separator", _make_separator_style())
	range_section.add_child(range_divider)

	var range_row: HBoxContainer = HBoxContainer.new()
	range_row.add_theme_constant_override("separation", 16)
	range_section.add_child(range_row)

	var range_lbl: Label = Label.new()
	range_lbl.text = "Position Clamp"
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
	_range_slider.range_changed.connect(func(lo: float, hi: float) -> void:
		_range_min_lbl.text = "MIN: %d" % roundi(lo)
		_range_max_lbl.text = "MAX: %d" % roundi(hi)
		FunscriptPlayer.SetRangeClamp(roundi(lo), roundi(hi))
		_save_settings()
	)

	# Hint beneath the slider
	var hint: Label = Label.new()
	hint.text = "Hard-clamps all playback positions to this range. Affects both Buttplug and Serial outputs."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(hint, UITheme.SEPARATOR, 11, false)
	range_section.add_child(hint)

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

	_home_slider.value_changed.connect(func(v: float) -> void:
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

	_home_ease_input.text_changed.connect(func(_t: String) -> void:
		_save_settings()
	)

	var home_hint: Label = Label.new()
	home_hint.text = "L0 target position when playback pauses or stops. Secondary axes always return to centre."
	home_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(home_hint, UITheme.SEPARATOR, 11, false)
	range_section.add_child(home_hint)

	# ── Latency Offset row ───────────────────────────────────────────────────
	var latency_row: HBoxContainer = HBoxContainer.new()
	latency_row.add_theme_constant_override("separation", 16)
	range_section.add_child(latency_row)

	var latency_lbl: Label = Label.new()
	latency_lbl.text = "Latency Offset"
	latency_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_style_label(latency_lbl, UITheme.WHITE_SOFT, 14, false)
	latency_row.add_child(latency_lbl)

	var latency_col: VBoxContainer = VBoxContainer.new()
	latency_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	latency_col.add_theme_constant_override("separation", 4)
	latency_row.add_child(latency_col)

	_latency_slider = HSlider.new()
	_latency_slider.min_value = -500
	_latency_slider.max_value = 500
	_latency_slider.step = 10
	_latency_slider.value = 0
	_latency_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_slider(_latency_slider)
	latency_col.add_child(_latency_slider)

	_latency_value_lbl = Label.new()
	_latency_value_lbl.text = "0 ms"
	_style_label(_latency_value_lbl, UITheme.PURPLE_MID, 11, true)
	latency_col.add_child(_latency_value_lbl)

	_latency_slider.value_changed.connect(func(v: float) -> void:
		_latency_value_lbl.text = "%d ms" % roundi(v)
		_save_settings()
	)

	var latency_hint: Label = Label.new()
	latency_hint.text = "Shifts the funscript relative to the video to compensate for device/Bluetooth lag. Positive = device acts earlier."
	latency_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(latency_hint, UITheme.SEPARATOR, 11, false)
	range_section.add_child(latency_hint)

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

	_vibe_slider.value_changed.connect(func(v: float) -> void:
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

	_max_speed_slider.value_changed.connect(func(v: float) -> void:
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
	_filler_toggle.focus_mode  = Control.FOCUS_NONE
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

	_filler_range_slider.range_changed.connect(func(lo: float, hi: float) -> void:
		_filler_range_min_lbl.text = "MIN: %d" % roundi(lo)
		_filler_range_max_lbl.text = "MAX: %d" % roundi(hi)
		_save_settings()
	)
	_filler_toggle.toggled.connect(func(pressed: bool) -> void:
		_style_toggle(_filler_toggle, pressed)
		_save_settings()
	)
	_filler_speed_input.text_changed.connect(func(_t: String) -> void:
		_save_settings()
	)

	var filler_hint: Label = Label.new()
	filler_hint.text = "Keeps the device active during storyboard scenes with a repeating alternating stroke. Respects the Position Clamp above."
	filler_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_label(filler_hint, UITheme.SEPARATOR, 11, false)
	filler_section.add_child(filler_hint)

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
	_tab_bar.clip_tabs     = false
	_tab_bar.tab_alignment = TabBar.ALIGNMENT_CENTER
	_tab_bar.focus_mode    = Control.FOCUS_NONE
	_tab_bar.anchor_left   = 0.5
	_tab_bar.anchor_right  = 0.5
	_tab_bar.anchor_top    = 0.0
	_tab_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_tab_bar.offset_left   = -PANEL_HALF_W
	_tab_bar.offset_right  =  PANEL_HALF_W
	_tab_bar.offset_top    = TOP_BAR_HEIGHT
	_tab_bar.offset_bottom = TOP_BAR_HEIGHT + TAB_BAR_HEIGHT
	_style_tab_bar(_tab_bar)
	add_child(_tab_bar)

	_tab_bar.tab_changed.connect(_on_tab_changed)
	_on_tab_changed(0)


func _style_tab_bar(tabs: TabBar) -> void:
	tabs.add_theme_color_override("font_selected_color",   UITheme.PURPLE_BRIGHT)
	tabs.add_theme_color_override("font_unselected_color", UITheme.PURPLE_MID)
	tabs.add_theme_color_override("font_hovered_color",    UITheme.WHITE_SOFT)
	tabs.add_theme_font_size_override("font_size", 14)
	tabs.add_theme_stylebox_override("tab_selected",   _make_btn_style(UITheme.PURPLE_BRIGHT, UITheme.PURPLE_MID))
	tabs.add_theme_stylebox_override("tab_unselected", _make_btn_style(UITheme.PURPLE_MID,    UITheme.PURPLE_DARK))
	tabs.add_theme_stylebox_override("tab_hovered",    _make_btn_style(UITheme.PURPLE_BRIGHT, UITheme.PURPLE_DARK))
	tabs.add_theme_stylebox_override("tab_focus",      StyleBoxEmpty.new())


# Shows the sections that belong to tab `idx` and hides all others.
func _on_tab_changed(idx: int) -> void:
	const VBOX: String = "ContentPanel/ContentScroll/MarginWrapper/ContentVBox/"
	var pages: Array = [
		# GENERAL
		[get_node(VBOX + "JourneysSection"), get_node(VBOX + "AudioSection"), get_node(VBOX + "DisplaySection")],
		# CONNECTION
		[get_node(VBOX + "OutputSection"), get_node(VBOX + "IntifaceSection"), get_node(VBOX + "SerialSection")],
		# DEVICE
		[_range_section, _filler_section],
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
	_title_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER

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
	_style_label(_status_lbl,   UITheme.ERROR,         13, false)
	_style_label(_serial_status_lbl, UITheme.ERROR,    13, false)

	_style_slider(_master_slider)
	_style_option_button(_res_dropdown)
	_style_option_button(_device_dropdown)
	_style_option_button(_output_mode_dropdown)
	_style_option_button(_serial_port_dropdown)
	_style_line_edit(_address_input)
	_style_line_edit(_serial_baud_input)
	_style_toggle(_fs_toggle,   false)
	_style_toggle(_auto_toggle, false)
	_style_toggle(_serial_auto_toggle, false)
	_style_button(_bp_test_btn,        UITheme.PURPLE_MID)
	_style_button(_serial_refresh_btn, UITheme.PURPLE_MID)
	_style_button(_serial_connect_btn, UITheme.PURPLE_BRIGHT)
	_style_button(_serial_test_btn,    UITheme.PURPLE_MID)


func _style_panel() -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color            = UITheme.PANEL_BG
	s.border_color        = UITheme.PURPLE_BRIGHT
	s.border_width_left   = BORDER_WIDTH
	s.border_width_right  = BORDER_WIDTH
	s.border_width_top    = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left     = 4
	s.corner_radius_top_right    = 4
	s.corner_radius_bottom_left  = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.5)
	s.shadow_size  = 12
	s.content_margin_left   = 32
	s.content_margin_right  = 32
	s.content_margin_top    = 28
	s.content_margin_bottom = 28
	_content_panel.add_theme_stylebox_override("panel", s)

func _make_separator_style() -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.SEPARATOR
	return s


func _style_label(label: Label, color: Color, size: int, uppercase: bool = false) -> void:
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	label.uppercase = uppercase


func _style_button(btn: Button, accent: Color) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   UITheme.WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", UITheme.BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.text = btn.text.to_upper()
	btn.add_theme_stylebox_override("normal",  _make_btn_style(accent, UITheme.PURPLE_DARK))
	btn.add_theme_stylebox_override("hover",   _make_btn_style(accent, UITheme.PURPLE_MID))
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
	s.content_margin_top    = 10
	s.content_margin_bottom = 10
	return s


func _style_toggle(btn: Button, pressed: bool) -> void:
	var active_color:   Color = UITheme.PURPLE_BRIGHT
	var inactive_color: Color = UITheme.PURPLE_MID
	var accent: Color = active_color if pressed else inactive_color
	btn.add_theme_color_override("font_color",          accent)
	btn.add_theme_color_override("font_hover_color",    UITheme.WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color",  UITheme.BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.text = btn.text.to_upper()
	var fill: Color = UITheme.PURPLE_MID if pressed else UITheme.PURPLE_DARK
	btn.add_theme_stylebox_override("normal",   _make_btn_style(accent, fill))
	btn.add_theme_stylebox_override("hover",    _make_btn_style(accent, UITheme.PURPLE_MID))
	btn.add_theme_stylebox_override("pressed",  _make_btn_style(active_color, active_color))
	btn.add_theme_stylebox_override("focus",    StyleBoxEmpty.new())
	btn.text = "ON" if pressed else "OFF"


func _style_slider(slider: HSlider) -> void:
	var track: StyleBoxFlat = StyleBoxFlat.new()
	track.bg_color          = UITheme.PURPLE_DARK
	track.border_color      = UITheme.PURPLE_MID
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

	slider.add_theme_stylebox_override("slider",       track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_color_override("grabber_color",   UITheme.MAGENTA)
	slider.custom_minimum_size.y = 24


func _style_option_button(opt: OptionButton) -> void:
	opt.add_theme_color_override("font_color",       UITheme.WHITE_SOFT)
	opt.add_theme_color_override("font_hover_color", UITheme.PURPLE_BRIGHT)
	opt.add_theme_font_size_override("font_size", 14)
	opt.add_theme_stylebox_override("normal", _make_btn_style(UITheme.PURPLE_MID,    UITheme.PURPLE_DARK))
	opt.add_theme_stylebox_override("hover",  _make_btn_style(UITheme.PURPLE_BRIGHT, UITheme.PURPLE_MID))
	opt.add_theme_stylebox_override("focus",  StyleBoxEmpty.new())


func _style_line_edit(edit: LineEdit) -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color          = UITheme.PURPLE_DARK
	s.border_color      = UITheme.PURPLE_MID
	
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
	edit.add_theme_color_override("selection_color", Color(UITheme.PURPLE_BRIGHT.r, UITheme.PURPLE_BRIGHT.g, UITheme.PURPLE_BRIGHT.b, 0.4))
	edit.add_theme_font_size_override("font_size", 14)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func _populate_resolution_dropdown() -> void:
	_res_dropdown.clear()
	for res: Vector2i in RESOLUTIONS:
		_res_dropdown.add_item("%d × %d" % [res.x, res.y])


func _populate_output_mode_dropdown() -> void:
	_output_mode_dropdown.clear()
	for label: String in OUTPUT_MODES:
		_output_mode_dropdown.add_item(label)


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

	_res_dropdown.selected = clampi(SettingsService.get_resolution_index(), 0, RESOLUTIONS.size() - 1)

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

	var mode_idx: int = OUTPUT_MODE_KEYS.find(SettingsService.get_output_mode())
	if mode_idx < 0:
		mode_idx = 0
	_output_mode_dropdown.selected = mode_idx

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

	var home_pos: int = SettingsService.get_home_position()
	var home_ease: int = SettingsService.get_home_ease_ms()
	if _home_slider != null:
		_home_slider.value = home_pos
		_home_value_lbl.text = str(home_pos)
	if _home_ease_input != null:
		_home_ease_input.text = str(home_ease)
	FunscriptPlayer.SetHomePosition(home_pos, home_ease)

	var latency: int = SettingsService.get_latency_offset_ms()
	if _latency_slider != null:
		_latency_slider.value = latency
		_latency_value_lbl.text = "%d ms" % latency
	FunscriptPlayer.SetLatencyOffset(latency)

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
		SettingsService.set_selected_device(_device_dropdown.get_item_text(_device_dropdown.selected))

	var mode_idx: int = clampi(_output_mode_dropdown.selected, 0, OUTPUT_MODE_KEYS.size() - 1)
	SettingsService.set_output_mode(OUTPUT_MODE_KEYS[mode_idx])

	if _serial_port_dropdown.selected >= 0 and _serial_port_dropdown.item_count > 0:
		SettingsService.set_serial_port(_serial_port_dropdown.get_item_text(_serial_port_dropdown.selected))
	var baud: int = _serial_baud_input.text.to_int()
	if baud <= 0:
		baud = DEFAULT_BAUD_RATE
	SettingsService.set_serial_baud(baud)
	SettingsService.set_serial_auto_connect(_serial_auto_toggle.button_pressed)

	if _range_slider != null:
		SettingsService.set_range_min(roundi(_range_slider.lo))
		SettingsService.set_range_max(roundi(_range_slider.hi))

	if _home_slider != null:
		var hp: int = roundi(_home_slider.value)
		var he: int = _home_ease_input.text.to_int()
		if he <= 0:
			he = 2000
		SettingsService.set_home_position(hp)
		SettingsService.set_home_ease_ms(he)
		FunscriptPlayer.SetHomePosition(hp, he)

	if _latency_slider != null:
		var lat: int = roundi(_latency_slider.value)
		SettingsService.set_latency_offset_ms(lat)
		FunscriptPlayer.SetLatencyOffset(lat)

	if _vibe_slider != null:
		var vib: int = roundi(_vibe_slider.value)
		SettingsService.set_vibe_intensity(vib)
		FunscriptPlayer.SetVibeIntensity(vib)

	if _max_speed_slider != null:
		var ms: int = roundi(_max_speed_slider.value)
		SettingsService.set_max_stroke_speed(ms)
		FunscriptPlayer.SetMaxStrokeSpeed(ms)

	if _hud_delay_slider != null:
		SettingsService.set_hud_hide_delay(_hud_delay_slider.value)

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

	_bp_test_btn.pressed.connect(_on_bp_test_pressed)

	_output_mode_dropdown.item_selected.connect(_on_output_mode_selected)
	_serial_refresh_btn.pressed.connect(_refresh_serial_ports)
	_serial_connect_btn.pressed.connect(_on_serial_connect_pressed)
	_serial_test_btn.pressed.connect(_on_serial_test_pressed)
	_serial_auto_toggle.toggled.connect(_on_serial_auto_toggled)

	ButtplugService.connect("Connected",     _on_bp_connected)
	ButtplugService.connect("Disconnected",  _on_bp_disconnected)
	ButtplugService.connect("DeviceAdded",   _on_bp_device_added)
	ButtplugService.connect("DeviceRemoved", _on_bp_device_removed)
	ButtplugService.connect("ScanFinished",  _on_bp_scan_finished)
	ButtplugService.connect("ErrorOccurred", _on_bp_error)

	SerialDeviceService.connect("Connected",     _on_serial_connected)
	SerialDeviceService.connect("Disconnected",  _on_serial_disconnected)
	SerialDeviceService.connect("ErrorOccurred", _on_serial_error)


func _on_open_journeys_folder_pressed() -> void:
	var abs_path: String = ProjectSettings.globalize_path("user://journeys")
	if not DirAccess.dir_exists_absolute(abs_path):
		DirAccess.make_dir_recursive_absolute(abs_path)
	OS.shell_open(abs_path)


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


func _on_bp_test_pressed() -> void:
	if not ButtplugService.BpConnected:
		_set_status("● NOT CONNECTED", UITheme.ERROR)
		return
	var idx: int = ButtplugService.GetSelectedDeviceIndex()
	if idx < 0:
		_set_status("● NO DEVICE SELECTED", UITheme.ERROR)
		return
	_bp_test_btn.disabled = true
	if ButtplugService.DeviceSupportsLinear(idx):
		# Linear stroker: full stroke up, full stroke down, return to centre.
		ButtplugService.SendLinear(idx, 600, 1.0)
		await get_tree().create_timer(0.7).timeout
		ButtplugService.SendLinear(idx, 600, 0.0)
		await get_tree().create_timer(0.7).timeout
		ButtplugService.SendLinear(idx, 400, 0.5)
	else:
		# Vibrator: pulse at full intensity then stop.
		ButtplugService.SendVibrate(idx, 1.0)
		await get_tree().create_timer(0.7).timeout
		ButtplugService.SendVibrate(idx, 0.0)
	_bp_test_btn.disabled = not ButtplugService.BpConnected or _device_dropdown.item_count == 0


func _on_bp_connected() -> void:
	_is_connected = true
	_set_connected_ui(true)


func _on_bp_disconnected() -> void:
	_is_connected = false
	_device_dropdown.clear()
	_device_dropdown.disabled = true
	_set_connected_ui(false)


func _on_bp_device_added(name: String, _index: int) -> void:
	_device_dropdown.add_item(name)
	_device_dropdown.disabled = false
	_bp_test_btn.disabled = false
	if name == SettingsService.get_selected_device():
		_device_dropdown.selected = _device_dropdown.item_count - 1


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
	_bp_test_btn.disabled     = no_devices


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
# Helpers
# ---------------------------------------------------------------------------

func _set_connected_ui(connected: bool) -> void:
	_connect_btn.disabled = false
	_scan_btn.disabled    = not connected
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
	var mode: DisplayServer.WindowMode = DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN if enabled \
		else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)


# ---------------------------------------------------------------------------
# Output mode + Serial
# ---------------------------------------------------------------------------

func _on_output_mode_selected(_index: int) -> void:
	_save_settings()


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
	var baud: int    = _serial_baud_input.text.to_int()
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
