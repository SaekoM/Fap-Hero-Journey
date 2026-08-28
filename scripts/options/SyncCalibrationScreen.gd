class_name SyncCalibrationScreen
extends Control

# Dials in a device's delay against a ruler instead of against a guess.
#
# The delay slider has always been here; what was missing was anything to judge it BY. This runs the
# calibration pattern on the live stroker and draws the same pattern on screen, so the two can be
# compared directly: watch the meter reach the top, feel when the device does, move the slider until
# they agree.
#
# The pattern goes out over the same code path a round uses (see SyncCalibrator), which is the only
# reason the number found here means anything during play.
#
# Refuses to run while a journey is playing. It takes the device over, and a round already has the
# in-play meter in Quick Settings — which is the better tool anyway, being real content.

signal closed

# The Handy applies a delay change by re-timing its stream and re-seating playback, which flushes the
# on-device buffer. Dragging a slider straight into that would fire one flush per pixel, so the resync
# waits for the drag to settle.
const RESYNC_DEBOUNCE_S: float = 0.25
const DELAY_RANGE_MS: int = 2000  # matches the Options sliders, so a saved value is never clamped away
const DELAY_STEP_MS: int = 5

var _calibrator: SyncCalibrator = null
var _meter: StrokeMeter = null
var _play_btn: Button = null
var _status: Label = null
var _delay_slider: HSlider = null
var _delay_lbl: Label = null
var _resync_timer: Timer = null
var _backend: String = ""


func _ready() -> void:
	_backend = DeviceRouting.stroke_backend(SettingsService.get_stroke_target())
	_calibrator = SyncCalibrator.new()
	_calibrator.finished.connect(_on_pattern_finished)
	add_child(_calibrator)

	_resync_timer = Timer.new()
	_resync_timer.one_shot = true
	_resync_timer.wait_time = RESYNC_DEBOUNCE_S
	_resync_timer.timeout.connect(_apply_delay_to_device)
	add_child(_resync_timer)

	_build_ui()


func _exit_tree() -> void:
	# The calibrator stops itself when freed, but the setting is only written on change — a save here
	# makes sure a value nudged and then closed on survives.
	SettingsService.save()


# ── Layout ──────────────────────────────────────────────────────────────────


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("ui_modal")

	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel: PanelContainer = PanelContainer.new()
	panel.anchor_left = 0.08
	panel.anchor_right = 0.92
	panel.anchor_top = 0.10
	panel.anchor_bottom = 0.90
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL_BG
	style.border_color = UITheme.CYAN
	style.set_border_width_all(1)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var root: VBoxContainer = VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	panel.add_child(root)

	var title: Label = Label.new()
	title.text = "SYNC CALIBRATION"
	UITheme.style_label(title, UITheme.CYAN, 18, true)
	root.add_child(title)

	var intro: Label = Label.new()
	intro.text = (
		"A slow, full-range stroke plays on your device and draws here at the same time. Watch the bar "
		+ "reach the top, feel when the device does, and move the delay until they agree."
	)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(intro, UITheme.WHITE_SOFT, 13, false)
	root.add_child(intro)

	_meter = StrokeMeter.new()
	_meter.custom_minimum_size = Vector2(0, 200)
	_meter.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_meter.set_delay_source(_current_delay_ms)
	# Pointed at the calibrator for good: it hands back the pattern while it runs and nothing when it is
	# stopped, so starting and stopping needs no further wiring here.
	_meter.set_source(_calibrator.points, _calibrator.now_ms)
	root.add_child(_meter)

	root.add_child(_build_transport())
	root.add_child(HSeparator.new())
	root.add_child(_build_delay_row())
	root.add_child(_build_caveats())

	var close: Button = Button.new()
	close.text = "DONE"
	close.size_flags_horizontal = Control.SIZE_SHRINK_END
	UITheme.style_button(close, UITheme.CYAN)
	close.pressed.connect(_close)
	root.add_child(close)


func _build_transport() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var target: Label = Label.new()
	target.text = _backend_name()
	UITheme.style_label(target, UITheme.PURPLE_BRIGHT, 13, true)
	row.add_child(target)

	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(_status, UITheme.DARK_TEXT, 12, false)
	_status.text = (
		"Ready." if _backend != "" else "No stroker is selected — pick one under Device routing."
	)
	row.add_child(_status)

	_play_btn = Button.new()
	_play_btn.text = "▶  START"
	UITheme.style_button(_play_btn, UITheme.CYAN)
	_play_btn.pressed.connect(_toggle_pattern)
	row.add_child(_play_btn)
	return row


func _build_delay_row() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var label: Label = Label.new()
	label.text = "DELAY"
	label.custom_minimum_size = Vector2(70, 0)
	UITheme.style_label(label, UITheme.WHITE_SOFT, 14, true)
	row.add_child(label)

	_delay_slider = HSlider.new()
	_delay_slider.min_value = -DELAY_RANGE_MS
	_delay_slider.max_value = DELAY_RANGE_MS
	_delay_slider.step = DELAY_STEP_MS
	_delay_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_delay_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_delay_slider.editable = _backend != ""
	_delay_slider.set_value_no_signal(_current_delay_ms())
	_delay_slider.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"Positive means the device acts LATER, negative means earlier. If the device reaches the "
				+ "top after the bar does, go negative."
			)
		)
	)
	_delay_slider.value_changed.connect(_on_delay_changed)
	row.add_child(_delay_slider)

	_delay_lbl = Label.new()
	_delay_lbl.text = "%d ms" % _current_delay_ms()
	_delay_lbl.custom_minimum_size = Vector2(70, 0)
	UITheme.style_label(_delay_lbl, UITheme.AMBER, 12, true)
	row.add_child(_delay_lbl)
	return row


# The two things that will otherwise be discovered the hard way, said once, here, where the number is
# being chosen.
func _build_caveats() -> Control:
	var note: Label = Label.new()
	note.text = (
		"One number can't be right everywhere: a stroker's travel time grows with distance and speed, "
		+ "so a fast full-range section will always lag more than a slow short one. Calibrate on this "
		+ "pattern for a clean starting point, then nudge it in play if dense sections feel late.\n"
		+ "On the Handy, changing the delay re-seats the stream — the small hitch you feel is that, "
		+ "not the sync slipping."
	)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(note, UITheme.DARK_TEXT, 11, false)
	return note


# ── The pattern ─────────────────────────────────────────────────────────────


func _toggle_pattern() -> void:
	if _calibrator.is_running():
		_stop_pattern()
		return
	if FunscriptPlayer.Playing:
		_set_status(
			"A journey is playing. Close it first, or use the meter in Quick Settings (S).",
			UITheme.AMBER
		)
		return
	if _backend == "":
		return

	_play_btn.disabled = true
	_set_status("Starting…", UITheme.DARK_TEXT)
	var driving: bool = await _calibrator.start()
	# Reaching a device is a network round-trip, and the screen can be closed inside it.
	if not is_instance_valid(_play_btn):
		return
	_play_btn.disabled = false
	if not _calibrator.is_running():
		return  # stopped while the device was being reached
	_play_btn.text = "■  STOP"
	# The meter runs either way: seeing the picture move proves the tool itself works even when nothing is
	# listening, which is a more useful failure than a dead screen.
	if driving:
		_set_status("Playing on your device.", UITheme.SUCCESS)
	else:
		_set_status("Couldn't reach the device — the pattern is on screen only.", UITheme.DANGER)


func _stop_pattern() -> void:
	_calibrator.stop()
	_play_btn.text = "▶  START"
	_set_status("Stopped.", UITheme.DARK_TEXT)


func _on_pattern_finished() -> void:
	_play_btn.text = "▶  START"
	_set_status("Pattern finished — press start to run it again.", UITheme.DARK_TEXT)


func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


# ── The delay ───────────────────────────────────────────────────────────────


func _current_delay_ms() -> int:
	match _backend:
		DeviceRouting.HANDY_TARGET:
			return SettingsService.get_handy_delay_ms()
		DeviceRouting.SERIAL_TARGET:
			return SettingsService.get_serial_delay_ms()
		DeviceRouting.BP_BACKEND:
			return SettingsService.get_intiface_delay_ms()
	return 0


func _on_delay_changed(value: float) -> void:
	var ms: int = int(value)
	_delay_lbl.text = "%d ms" % ms
	match _backend:
		DeviceRouting.HANDY_TARGET:
			SettingsService.set_handy_delay_ms(ms)
		DeviceRouting.SERIAL_TARGET:
			SettingsService.set_serial_delay_ms(ms)
		DeviceRouting.BP_BACKEND:
			SettingsService.set_intiface_delay_ms(ms)
	_resync_timer.start()


# Pushes the settled value at the live output. The C# backends take it instantly; the Handy has to
# re-time and re-seat its stream, which is why this waits for the drag to stop.
func _apply_delay_to_device() -> void:
	var ms: int = _current_delay_ms()
	match _backend:
		DeviceRouting.HANDY_TARGET:
			HandyService.resync_timing()
		DeviceRouting.SERIAL_TARGET:
			FunscriptPlayer.SetSerialDelay(ms)
		DeviceRouting.BP_BACKEND:
			FunscriptPlayer.SetIntifaceDelay(ms)
	SettingsService.save()


func _backend_name() -> String:
	match _backend:
		DeviceRouting.HANDY_TARGET:
			return "THE HANDY (WIFI)"
		DeviceRouting.SERIAL_TARGET:
			return "SERIAL STROKER"
		DeviceRouting.BP_BACKEND:
			return "INTIFACE STROKER"
	return "NO STROKER"


# ── Closing ─────────────────────────────────────────────────────────────────


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		accept_event()
		_close()


func _close() -> void:
	_calibrator.stop()
	closed.emit()
	queue_free()
