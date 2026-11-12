class_name TurnScoreMeter
extends Control

# The score so far, filling towards the tiers' marks. Marks are left out when the creator hides the tiers. Each mark
# names its tier, with a tick once reached; a name that would overlap the one before moves up a row.

const BAR_HEIGHT: float = 22.0
const ROW_HEIGHT: float = 16.0
const ROW_COUNT: int = 2
const NAME_FONT_SIZE: int = 12
const SCORE_FONT_SIZE: int = 14
const NAME_GAP: float = 8.0
const REACHED_PREFIX: String = "✓ "
const FILL_SECS: float = 0.35

var accent: Color = Color.WHITE
# The tiers above the lowest, sorted lowest first. Empty when the tiers are hidden.
var tier_marks: Array = []:
	set(value):
		tier_marks = value
		custom_minimum_size.y = (
			BAR_HEIGHT + (ROW_COUNT * ROW_HEIGHT if not value.is_empty() else 0.0)
		)
var score: float = 0.0


func _init() -> void:
	custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func show_score(value: int) -> void:
	var fill: Tween = create_tween()
	fill.tween_method(_set_score, score, float(value), FILL_SECS).set_ease(Tween.EASE_OUT)


func _set_score(value: float) -> void:
	score = value
	queue_redraw()


func _draw() -> void:
	var font: Font = get_theme_font("font", "Label")
	var bar: Rect2 = Rect2(0.0, size.y - BAR_HEIGHT, size.x, BAR_HEIGHT)
	draw_rect(bar, UITheme.BAR_BG)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * score / 100.0, bar.size.y)), accent)
	draw_rect(bar, UITheme.PURPLE_MID, false, 1.0)
	_draw_tier_marks(font, bar)
	var text: String = "%d%%" % roundi(score)
	var baseline: Vector2 = Vector2(0.0, bar.end.y - (BAR_HEIGHT - SCORE_FONT_SIZE) / 2.0 - 2.0)
	draw_string_outline(
		font,
		baseline,
		text,
		HORIZONTAL_ALIGNMENT_CENTER,
		bar.size.x,
		SCORE_FONT_SIZE,
		4,
		UITheme.BG
	)
	draw_string(
		font, baseline, text, HORIZONTAL_ALIGNMENT_CENTER, bar.size.x, SCORE_FONT_SIZE, Color.WHITE
	)


func _draw_tier_marks(font: Font, bar: Rect2) -> void:
	var row_ends: Array[float] = [-INF, -INF]
	for tier: Dictionary in tier_marks:
		var from_score: float = float(tier.get("min_score", 0))
		var x: float = bar.size.x * from_score / 100.0
		draw_line(Vector2(x, bar.position.y - 3.0), Vector2(x, bar.end.y), UITheme.WHITE_SOFT, 2.0)
		var reached: bool = roundi(score) >= int(from_score)
		var tier_name: String = str(tier.get("name", "")).strip_edges().to_upper()
		# The width always allows for the tick, so a name doesn't shift as it's reached.
		var width: float = (
			font
			. get_string_size(
				REACHED_PREFIX + tier_name, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_SIZE
			)
			. x
		)
		var left: float = clampf(x - width / 2.0, 0.0, maxf(0.0, bar.size.x - width))
		var row: int = 0 if left >= row_ends[0] + NAME_GAP else 1
		row_ends[row] = left + width
		draw_string(
			font,
			Vector2(left, bar.position.y - 5.0 - row * ROW_HEIGHT),
			(REACHED_PREFIX + tier_name) if reached else tier_name,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			NAME_FONT_SIZE,
			UITheme.AMBER if reached else UITheme.TEXT_HINT
		)
