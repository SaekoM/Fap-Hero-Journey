class_name ColourModePreview
extends PanelContainer
## The live preview beside Options' Colour mode dropdown (COLOUR_MODES_DESIGN.md): the colours that carry
## meaning — status lines, curse and boon, the beat bar's intensity, difficulty — drawn from UITheme's
## current palette and redrawn the moment the mode changes. Everything else in the app takes a new mode
## as each screen next opens; this shows it straight away, so modes can be compared.

const ROW_GAP: int = 10
const BEAT_MIN_PX: float = 10.0
const BEAT_STEP_PX: float = 4.0

var _rows: VBoxContainer


func _ready() -> void:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL_BG
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.set_content_margin_all(12)
	add_theme_stylebox_override("panel", style)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", ROW_GAP)
	add_child(_rows)
	UITheme.colour_mode_changed.connect(_on_colour_mode_changed)
	refresh()


func _on_colour_mode_changed(_mode: String) -> void:
	refresh()


func refresh() -> void:
	(get_theme_stylebox("panel") as StyleBoxFlat).border_color = UITheme.BORDER
	(get_theme_stylebox("panel") as StyleBoxFlat).set_border_width_all(1)
	for child: Node in _rows.get_children():
		child.queue_free()
	(
		_rows
		. add_child(
			_row(
				"Status",
				[
					_text("✓ Connected", UITheme.STATUS_OK),
					_text("! Battery low", UITheme.STATUS_WARNING),
					_text("✕ Can't reach Stash", UITheme.STATUS_ERROR),
					_text("i Scanning…", UITheme.STATUS_INFO),
				]
			)
		)
	)
	_rows.add_child(
		_row(
			"Curse / boon",
			[_frame("☠  CURSE", UITheme.PAIR_CURSE), _frame("✦  BOON", UITheme.PAIR_BOON)]
		)
	)
	_rows.add_child(_row("Beat intensity", [_beat_steps()]))
	var pills: Array = []
	for i: int in JourneyData.DIFFICULTIES.size():
		pills.append(_pill(str(JourneyData.DIFFICULTIES[i]), UITheme.SCALE_DIFFICULTY[i]))
	_rows.add_child(_row("Difficulty", pills))


func _row(title: String, items: Array) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label: Label = Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(110, 0)
	label.add_theme_color_override("font_color", UITheme.TEXT_HINT)
	label.add_theme_font_size_override("font_size", 11)
	row.add_child(label)
	var flow: HFlowContainer = HFlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.add_theme_constant_override("h_separation", 12)
	flow.add_theme_constant_override("v_separation", 4)
	for item: Control in items:
		flow.add_child(item)
	row.add_child(flow)
	return row


func _text(text: String, color: Color) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 13)
	return label


# An effect round's edge frame in miniature: the colour on the border, the sign inside.
func _frame(text: String, color: Color) -> Control:
	var frame: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.CARD_BG
	style.border_color = color
	style.set_border_width_all(3)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	frame.add_theme_stylebox_override("panel", style)
	frame.add_child(_text(text, UITheme.WHITE_SOFT))
	return frame


func _pill(text: String, color: Color) -> Control:
	var pill: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.CARD_BG
	style.border_color = color
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 6
	style.content_margin_right = 6
	pill.add_theme_stylebox_override("panel", style)
	var label: Label = _text(text.to_upper(), color)
	label.add_theme_font_size_override("font_size", 10)
	pill.add_child(label)
	return pill


# The beat bar's five intensity steps, low to high, each a little bigger than the last.
func _beat_steps() -> Control:
	var steps: HBoxContainer = HBoxContainer.new()
	steps.add_theme_constant_override("separation", 8)
	steps.alignment = BoxContainer.ALIGNMENT_BEGIN
	for i: int in UITheme.SCALE_INTENSITY.size():
		var dot: Control = Control.new()
		var size_px: float = BEAT_MIN_PX + i * BEAT_STEP_PX
		dot.custom_minimum_size = Vector2(size_px, size_px)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var color: Color = UITheme.SCALE_INTENSITY[i]
		dot.draw.connect(
			func() -> void:
				dot.draw_circle(dot.size / 2.0, minf(dot.size.x, dot.size.y) / 2.0, color)
		)
		steps.add_child(dot)
	return steps
