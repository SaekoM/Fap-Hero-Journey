class_name SessionSettingsPanel
extends Control

## In-play "Quick Settings" drawer (stroke range + delay), toggled by the "S" key from GameLoop. Slides
## in from the right like the inventory panel and is mutually exclusive with it. Adjustments persist to
## the same settings as Options and apply to the player live — no pause, no round restart.

signal closed

const PANEL_WIDTH: int = 320
const SLIDE_TIME: float = 0.18

var _panel: PanelContainer = null
var _range_slider: RangeSlider = null
var _intiface_delay_slider: HSlider = null
var _intiface_delay_lbl: Label = null
var _serial_delay_slider: HSlider = null
var _serial_delay_lbl: Label = null
var _handy_delay_slider: HSlider = null
var _handy_delay_lbl: Label = null
var _meter: StrokeMeter = null


func _ready() -> void:
	# Root spans the viewport for the slide only; it must not block clicks to the game beneath.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_right = 1.0
	anchor_bottom = 1.0
	_build()
	_slide_in()


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -PANEL_WIDTH
	_panel.offset_right = 0
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)

	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG_DEEP
	ps.border_color = UITheme.PURPLE_BRIGHT
	ps.border_width_left = 3
	ps.content_margin_left = 18
	ps.content_margin_right = 18
	ps.content_margin_top = 18
	ps.content_margin_bottom = 18
	_panel.add_theme_stylebox_override("panel", ps)
	add_child(_panel)

	var vb: VBoxContainer = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	_panel.add_child(vb)

	# ── Header ────────────────────────────────────────────────────────────────
	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vb.add_child(header)

	var title: Label = Label.new()
	title.text = "QUICK SETTINGS"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)

	var close_btn: Button = Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	_style_close_button(close_btn)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	# ── The stroke, as the script has it ──────────────────────────────────────
	# Above the delays deliberately: it is what those sliders are set against, and a slider with nothing
	# to judge it by is the reason people gave up on them.
	vb.add_child(_section_label("STROKE"))
	_meter = StrokeMeter.new()
	_meter.custom_minimum_size = Vector2(0, 104)
	_meter.set_delay_source(_active_delay_ms)
	vb.add_child(_meter)
	vb.add_child(
		_hint_label("Where the script says the device should be. Set the delay until yours agrees.")
	)

	# ── Stroke range ──────────────────────────────────────────────────────────
	vb.add_child(_section_label("STROKE RANGE"))

	_range_slider = RangeSlider.new()
	_range_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_range_slider.set_range_values(SettingsService.get_range_min(), SettingsService.get_range_max())
	_range_slider.range_changed.connect(_on_range_changed)
	vb.add_child(_range_slider)

	vb.add_child(_hint_label("How much of the stroke the device uses.  ↑/↓ max · ←/→ min."))

	# ── Delays (per backend) ────────────────────────────────────────────────────
	var d_intiface: Dictionary = _add_delay(vb, "INTIFACE DELAY")
	_intiface_delay_slider = d_intiface["slider"]
	_intiface_delay_lbl = d_intiface["value"]
	_intiface_delay_slider.set_value_no_signal(SettingsService.get_intiface_delay_ms())
	_intiface_delay_lbl.text = "%d ms" % SettingsService.get_intiface_delay_ms()
	_intiface_delay_slider.value_changed.connect(_on_intiface_delay_changed)

	var d_serial: Dictionary = _add_delay(vb, "SERIAL DELAY")
	_serial_delay_slider = d_serial["slider"]
	_serial_delay_lbl = d_serial["value"]
	_serial_delay_slider.set_value_no_signal(SettingsService.get_serial_delay_ms())
	_serial_delay_lbl.text = "%d ms" % SettingsService.get_serial_delay_ms()
	_serial_delay_slider.value_changed.connect(_on_serial_delay_changed)

	var d_handy: Dictionary = _add_delay(vb, "HANDY DELAY")
	_handy_delay_slider = d_handy["slider"]
	_handy_delay_lbl = d_handy["value"]
	_handy_delay_slider.set_value_no_signal(SettingsService.get_handy_delay_ms())
	_handy_delay_lbl.text = "%d ms" % SettingsService.get_handy_delay_ms()
	_handy_delay_slider.value_changed.connect(_on_handy_delay_changed)

	(
		vb
		. add_child(
			_hint_label(
				"Shifts each backend's output for device / Bluetooth / serial lag. Positive = adds delay (acts later); negative = fires ahead."
			)
		)
	)


func _section_label(text: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	lbl.add_theme_font_size_override("font_size", 13)
	return lbl


func _hint_label(text: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	lbl.add_theme_font_size_override("font_size", 11)
	return lbl


# Builds a labelled delay slider (−500..500 ms) + its value label; returns { slider, value }. The
# caller seeds the value and connects value_changed so setup doesn't fire the apply.
func _add_delay(vb: VBoxContainer, title: String) -> Dictionary:
	vb.add_child(_section_label(title))
	var slider: HSlider = HSlider.new()
	slider.min_value = -2000
	slider.max_value = 2000
	slider.step = 10
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(slider)
	var value_lbl: Label = Label.new()
	value_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
	value_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(value_lbl)
	return {"slider": slider, "value": value_lbl}


# ── Apply (persist + push to the player live; same settings as Options) ────────


func _on_range_changed(lo: float, hi: float) -> void:
	SettingsService.set_range_min(int(lo))
	SettingsService.set_range_max(int(hi))
	SettingsService.save()
	FunscriptPlayer.SetRangeClamp(int(lo), int(hi))
	# Handy-direct: the stroke range is the one modifier that DOES reach the
	# device — it maps to the slide zone (debounced; drags spam this handler).
	if SettingsService.get_stroke_target() == DeviceRouting.HANDY_TARGET:
		HandyService.set_slider_debounced(int(lo), int(hi))


func _on_intiface_delay_changed(v: float) -> void:
	_intiface_delay_lbl.text = "%d ms" % int(v)
	SettingsService.set_intiface_delay_ms(int(v))
	SettingsService.save()
	FunscriptPlayer.SetIntifaceDelay(int(v))


func _on_serial_delay_changed(v: float) -> void:
	_serial_delay_lbl.text = "%d ms" % int(v)
	SettingsService.set_serial_delay_ms(int(v))
	SettingsService.save()
	FunscriptPlayer.SetSerialDelay(int(v))


func _on_handy_delay_changed(v: float) -> void:
	_handy_delay_lbl.text = "%d ms" % int(v)
	SettingsService.set_handy_delay_ms(int(v))
	SettingsService.save()
	# Handy-direct: the delay shifts the play anchor — re-seat the live session
	# so the change takes effect now (no-op unless the Handy is the stroker).
	if SettingsService.get_stroke_target() == DeviceRouting.HANDY_TARGET:
		HandyService.resync_timing()


# Points the meter at whatever GameLoop is currently driving the device with, and the clock that goes
# with it. Both are read live rather than snapshotted, so an override item seizing the device mid-round
# changes the picture instead of leaving a stale one. Without this the meter reads NO SCRIPT, which is
# the honest answer for a round that has no funscript.
func set_stroke_source(points_source: Callable, clock: Callable) -> void:
	if _meter != null:
		_meter.set_source(points_source, clock)


# The delay belonging to whatever is actually driving strokes. Three sliders are shown — a player may
# have more than one device configured — but only one of them is what the meter's device marker means.
func _active_delay_ms() -> int:
	match DeviceRouting.stroke_backend(SettingsService.get_stroke_target()):
		DeviceRouting.HANDY_TARGET:
			return SettingsService.get_handy_delay_ms()
		DeviceRouting.SERIAL_TARGET:
			return SettingsService.get_serial_delay_ms()
		DeviceRouting.BP_BACKEND:
			return SettingsService.get_intiface_delay_ms()
	return 0


# Nudge the stroke range from GameLoop's arrow-key hotkeys (active only while this panel is open).
func nudge_range(d_min: int, d_max: int) -> void:
	var lo: int = clampi(int(_range_slider.lo) + d_min, 0, 99)
	var hi: int = clampi(int(_range_slider.hi) + d_max, lo + 1, 100)
	_range_slider.set_range_values(lo, hi)  # moves handles without re-emitting
	_on_range_changed(lo, hi)


# Re-read the sliders from settings (e.g. after the full Options screen changed them while this is open).
func resync() -> void:
	if _range_slider != null:
		_range_slider.set_range_values(
			SettingsService.get_range_min(), SettingsService.get_range_max()
		)
	if _intiface_delay_slider != null:
		_intiface_delay_slider.set_value_no_signal(SettingsService.get_intiface_delay_ms())
		_intiface_delay_lbl.text = "%d ms" % SettingsService.get_intiface_delay_ms()
	if _serial_delay_slider != null:
		_serial_delay_slider.set_value_no_signal(SettingsService.get_serial_delay_ms())
		_serial_delay_lbl.text = "%d ms" % SettingsService.get_serial_delay_ms()
	if _handy_delay_slider != null:
		_handy_delay_slider.set_value_no_signal(SettingsService.get_handy_delay_ms())
		_handy_delay_lbl.text = "%d ms" % SettingsService.get_handy_delay_ms()


# ── Slide animation (mirrors InventoryPanel) ───────────────────────────────────


func close() -> void:
	emit_signal("closed")
	var tween: Tween = create_tween()
	tween.tween_property(_panel, "position:x", get_viewport_rect().size.x, SLIDE_TIME)
	tween.tween_callback(queue_free)


func _slide_in() -> void:
	var w: float = get_viewport_rect().size.x
	_panel.position.x = w
	var tween: Tween = create_tween()
	tween.tween_property(_panel, "position:x", w - PANEL_WIDTH, SLIDE_TIME)


# Thin delegate to UITheme — the canonical styling lives there.
func _style_close_button(btn: Button) -> void:
	UITheme.style_close_button(btn)
