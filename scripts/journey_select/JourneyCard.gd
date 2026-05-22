extends PanelContainer

signal selected

const CARD_MIN_WIDTH:  int   = 280
const CARD_MIN_HEIGHT: int   = 360
const BORDER_WIDTH:    int   = 2
const CORNER_RADIUS:   int   = 8
const HOVER_SCALE:     float = 1.03

# Difficulty → pill colour. Mirrors JourneySelect.DIFF_COLORS (kept local so the
# card is self-contained — JourneySelect is not a class_name singleton).
const DIFF_COLORS: Dictionary = {
	"Easy":      Color(0.35, 0.95, 0.35),
	"Medium":    Color(0.95, 0.95, 0.25),
	"Hard":      Color(1.0,  0.55, 0.1),
	"Very Hard": Color(1.0,  0.25, 0.05),
	"Extreme":   Color(1.0,  0.1,  0.1),
	"Insane":    Color(0.9,  0.05, 0.5),
}

# Accent palette for generated placeholders — picked deterministically per title
# so a cover-less journey always renders with the same colour.
const PLACEHOLDER_ACCENTS: Array = [
	UITheme.PURPLE_BRIGHT, UITheme.MAGENTA, UITheme.CYAN, UITheme.AMBER,
]

@onready var _vbox:  VBoxContainer = $VBox
@onready var _cover: TextureRect   = $VBox/CoverRect
@onready var _title: Label         = $VBox/TitleLabel

# Footer line (round count + duration) built in _ready().
var _footer: Label = null

# Tag chip strip pinned to the cover bottom; shown only while hovered.
var _tag_overlay: Control = null

# Active hover scale tween, killed/replaced on each hover transition.
var _hover_tween: Tween = null


func _ready() -> void:
	custom_minimum_size = Vector2(CARD_MIN_WIDTH, CARD_MIN_HEIGHT)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter        = Control.MOUSE_FILTER_STOP

	_cover.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cover.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_cover.custom_minimum_size   = Vector2.ZERO

	_title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	_title.add_theme_font_size_override("font_size", 13)
	_title.uppercase = true
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_constant_override("margin_top", 8)

	# Footer — round count + total duration, below the title.
	_footer = Label.new()
	_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_footer.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	_footer.add_theme_font_size_override("font_size", 11)
	_vbox.add_child(_footer)

	mouse_entered.connect(_on_hover_enter)
	mouse_exited.connect(_on_hover_exit)
	_set_style(false)


func setup(journey: Dictionary) -> void:
	var title: String = journey.get("title", "Unknown")
	_title.text = title

	var cover_path: String = journey.get("cover_path", "")
	var img: Image = JourneyData.load_image_smart(cover_path)
	if img != null:
		_cover.texture = ImageTexture.create_from_image(img)
	else:
		_build_placeholder(title)

	# Cover overlays — built bottom-to-top: scrim, then difficulty pill, then tags.
	_build_gradient_scrim()
	_build_difficulty_pill(journey.get("difficulty", ""))
	_build_tag_overlay(journey.get("tags", []))

	var round_count: int = journey.get("total_rounds", (journey.get("rounds", []) as Array).size())
	var total_secs:  int = (journey.get("total_length_ms", 0) as int) / 1000
	_footer.text = "%d %s  ·  %s" % [
		round_count,
		"ROUND" if round_count == 1 else "ROUNDS",
		_format_duration(total_secs),
	]


# ── Intro animation ──────────────────────────────────────────────────────────

# Fades + scales the card in. `delay` staggers cards so the grid builds in.
func animate_in(delay: float) -> void:
	modulate.a = 0.0
	await get_tree().process_frame
	if not is_inside_tree():
		return
	pivot_offset = size / 2.0
	scale = Vector2(0.96, 0.96)
	var t: Tween = create_tween().set_parallel(true)
	t.tween_property(self, "modulate:a", 1.0, 0.20).set_delay(delay)
	t.tween_property(self, "scale", Vector2.ONE, 0.26) \
		.set_delay(delay).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


# ── Cover overlays ───────────────────────────────────────────────────────────

# Faint accent-tinted fill + a large title initial, shown when a journey has
# no cover image so the slot never looks broken/empty.
func _build_placeholder(title: String) -> void:
	var accent: Color = PLACEHOLDER_ACCENTS[absi(title.hash()) % PLACEHOLDER_ACCENTS.size()]

	var bg: ColorRect = ColorRect.new()
	bg.color         = Color(accent.r, accent.g, accent.b, 0.07)
	bg.anchor_right  = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_cover.add_child(bg)

	var glyph: Label = Label.new()
	glyph.text = title.substr(0, 1).to_upper() if title != "" else "?"
	glyph.add_theme_font_size_override("font_size", 84)
	glyph.add_theme_color_override("font_color", Color(accent.r, accent.g, accent.b, 0.5))
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	glyph.anchor_right  = 1.0
	glyph.anchor_bottom = 1.0
	glyph.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_cover.add_child(glyph)


# Always-on transparent→dark gradient along the cover bottom — adds depth and
# keeps the hover tag chips legible against bright cover art.
func _build_gradient_scrim() -> void:
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0))
	grad.set_color(1, Color(0, 0, 0, 0.55))

	var gtex: GradientTexture2D = GradientTexture2D.new()
	gtex.gradient  = grad
	gtex.fill_from = Vector2(0, 0)
	gtex.fill_to   = Vector2(0, 1)
	gtex.width     = 4
	gtex.height    = 64

	var scrim: TextureRect = TextureRect.new()
	scrim.texture       = gtex
	scrim.stretch_mode  = TextureRect.STRETCH_SCALE
	scrim.anchor_left   = 0.0
	scrim.anchor_right  = 1.0
	scrim.anchor_top    = 1.0
	scrim.anchor_bottom = 1.0
	scrim.offset_top    = -90
	scrim.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_cover.add_child(scrim)


# Colour-coded difficulty pill, pinned to the cover's top-left corner.
func _build_difficulty_pill(difficulty: String) -> void:
	if difficulty == "":
		return
	var color: Color = DIFF_COLORS.get(difficulty, UITheme.WHITE_SOFT)
	var pill: Control = UITheme.make_tag_chip(difficulty, color)
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.position     = Vector2(8, 8)
	_cover.add_child(pill)


# Hidden chip strip pinned to the cover bottom; revealed on hover.
func _build_tag_overlay(tag_ids: Array) -> void:
	if tag_ids.is_empty():
		return
	_tag_overlay = HFlowContainer.new()
	_tag_overlay.add_theme_constant_override("h_separation", 4)
	_tag_overlay.add_theme_constant_override("v_separation", 4)
	_tag_overlay.anchor_left   = 0.0
	_tag_overlay.anchor_right  = 1.0
	_tag_overlay.anchor_top    = 1.0
	_tag_overlay.anchor_bottom = 1.0
	_tag_overlay.offset_left   = 8
	_tag_overlay.offset_right  = -8
	_tag_overlay.offset_top    = -78
	_tag_overlay.offset_bottom = -8
	_tag_overlay.visible       = false
	_tag_overlay.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	for id: String in tag_ids:
		_tag_overlay.add_child(UITheme.make_tag_chip(TagRegistry.label_of(id), TagRegistry.color_of(id)))
	_cover.add_child(_tag_overlay)


# ── Styling / hover ──────────────────────────────────────────────────────────

func _set_style(hovered: bool) -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color     = UITheme.PURPLE_DARK if hovered else UITheme.PANEL_BG
	s.border_color = UITheme.PURPLE_BRIGHT if hovered else UITheme.PURPLE_MID
	s.border_width_left   = BORDER_WIDTH
	s.border_width_right  = BORDER_WIDTH
	s.border_width_top    = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left     = CORNER_RADIUS
	s.corner_radius_top_right    = CORNER_RADIUS
	s.corner_radius_bottom_left  = CORNER_RADIUS
	s.corner_radius_bottom_right = CORNER_RADIUS
	if hovered:
		s.shadow_color = Color(UITheme.PURPLE_BRIGHT.r, UITheme.PURPLE_BRIGHT.g, UITheme.PURPLE_BRIGHT.b, 0.5)
		s.shadow_size  = 14
	# A small inset frames the cover so the rounded corners read as panel, not
	# square image corners poking through.
	s.content_margin_left   = 5
	s.content_margin_right  = 5
	s.content_margin_top    = 5
	s.content_margin_bottom = 10
	add_theme_stylebox_override("panel", s)


func _on_hover_enter() -> void:
	_set_style(true)
	_title.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	if _tag_overlay != null:
		_tag_overlay.visible = true
	z_index = 1
	pivot_offset = size / 2.0
	_animate_scale(Vector2(HOVER_SCALE, HOVER_SCALE))


func _on_hover_exit() -> void:
	_set_style(false)
	_title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	if _tag_overlay != null:
		_tag_overlay.visible = false
	z_index = 0
	_animate_scale(Vector2.ONE)


func _animate_scale(target: Vector2) -> void:
	if _hover_tween != null and _hover_tween.is_running():
		_hover_tween.kill()
	_hover_tween = create_tween()
	_hover_tween.tween_property(self, "scale", target, 0.12) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			selected.emit()


func _format_duration(total_seconds: int) -> String:
	var h: int = total_seconds / 3600
	var m: int = (total_seconds % 3600) / 60
	var s: int = total_seconds % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s]
	return "%d:%02d" % [m, s]
