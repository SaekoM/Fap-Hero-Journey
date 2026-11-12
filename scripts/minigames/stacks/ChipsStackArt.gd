class_name ChipsStackArt
extends StackArt

# Round casino chips, seen edge-on, in the game's accent colour with white stripes round the edge. They clatter down
# and roll away to either side.

const WIDTH: float = 96.0
const HEIGHT: float = 14.0
const STRIPE_WIDTH: float = 8.0
const STRIPE_GAP: float = 18.0
const STRIPE_ALPHA: float = 0.85
const SHADE_STEPS: int = 3
const SHADE_STRENGTH: float = 0.16
const HIGHLIGHT_ALPHA: float = 0.5
const ROLL_REACH: float = 190.0
const FALL_DROP: float = 340.0
const ROLL_SPIN: float = 6.0


func piece_width() -> float:
	return WIDTH


func piece_height() -> float:
	return HEIGHT


func draw_piece(
	stage: PushStackStage, index: int, kind: String, accent: Color, gold: float, opacity: float
) -> void:
	var shade: float = SHADE_STRENGTH * (index % SHADE_STEPS)
	var body: Color = kind_colour(kind, accent).lerp(UITheme.BG, shade).lerp(GOLD, gold)
	body.a = opacity
	var radius: float = HEIGHT / 2.0
	var inner: float = WIDTH / 2.0 - radius
	stage.draw_rect(Rect2(-inner, 0.0, inner * 2.0, HEIGHT), body)
	stage.draw_circle(Vector2(-inner, radius), radius, body)
	stage.draw_circle(Vector2(inner, radius), radius, body)
	# Stripes round the edge, shifted every other chip so a stack doesn't line up too neatly.
	var stripe: Color = Color(Color.WHITE, STRIPE_ALPHA * opacity)
	var x: float = -inner + (STRIPE_GAP / 2.0 if index % 2 == 0 else 0.0)
	while x < inner - STRIPE_WIDTH:
		stage.draw_rect(Rect2(x, 0.0, STRIPE_WIDTH, HEIGHT), stripe)
		x += STRIPE_WIDTH + STRIPE_GAP
	var highlight: Color = Color(Color.WHITE, HIGHLIGHT_ALPHA * opacity)
	stage.draw_line(Vector2(-inner, 1.0), Vector2(inner, 1.0), highlight, 1.0)
	draw_emblem(stage, kind, opacity)


func fall(index: int, count: int, progress: float) -> Vector3:
	var side: float = 1.0 if index % 2 == 0 else -1.0
	var height_share: float = float(index + 1) / count
	return Vector3(
		side * progress * ROLL_REACH * height_share,
		progress * progress * FALL_DROP,
		side * progress * ROLL_SPIN * height_share
	)


func play_fall_sound() -> void:
	UISound.stack_clatter()
