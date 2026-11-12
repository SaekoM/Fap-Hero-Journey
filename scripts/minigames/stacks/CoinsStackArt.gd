class_name CoinsStackArt
extends StackArt

# A pile of gold coins, narrower and thinner than chips and looser, with a sheen. They spill and scatter in every
# direction, so this one is gold whatever the game's accent colour.

const WIDTH: float = 74.0
const HEIGHT: float = 11.0
const DARK_EDGE: Color = Color(0.55, 0.36, 0.05)
const RIDGE_GAP: float = 6.0
const RIDGE_ALPHA: float = 0.35
const SHEEN_ALPHA: float = 0.8
const SCATTER_REACH: float = 220.0
const FALL_DROP: float = 300.0
const SCATTER_SPIN: float = 9.0
const SCATTER_SEED: float = 12.9898


func piece_width() -> float:
	return WIDTH


func piece_height() -> float:
	return HEIGHT


func misalignment() -> float:
	return 5.0


func draw_piece(
	stage: PushStackStage, index: int, kind: String, _accent: Color, gold: float, opacity: float
) -> void:
	var half: float = WIDTH / 2.0
	var body: Color = kind_colour(kind, GOLD).lerp(Color.WHITE, gold * 0.3)
	body.a = opacity
	stage.draw_rect(Rect2(-half, 0.0, WIDTH, HEIGHT), body)
	var ridge: Color = Color(DARK_EDGE, RIDGE_ALPHA * opacity)
	var x: float = -half + RIDGE_GAP
	while x < half:
		stage.draw_line(Vector2(x, 2.0), Vector2(x, HEIGHT), ridge, 1.0)
		x += RIDGE_GAP
	stage.draw_rect(Rect2(-half, 0.0, WIDTH, HEIGHT), Color(DARK_EDGE, opacity), false, 1.0)
	# A glint that slides along each coin in turn.
	var travel: float = fposmod(stage.clock * 0.7 + index * 0.13, 1.0)
	var glint_x: float = lerpf(-half, half - 6.0, travel)
	stage.draw_rect(Rect2(glint_x, 1.0, 6.0, 2.0), Color(Color.WHITE, SHEEN_ALPHA * opacity))
	draw_emblem(stage, kind, opacity)


func fall(index: int, count: int, progress: float) -> Vector3:
	# Each coin takes its own way, from a repeatable scatter rather than a random one, so the draw needn't remember it.
	var scatter: float = sin(index * SCATTER_SEED)
	var height_share: float = float(index + 1) / count
	return Vector3(
		scatter * progress * SCATTER_REACH * (0.4 + 0.6 * height_share),
		progress * progress * FALL_DROP,
		scatter * progress * SCATTER_SPIN
	)


func play_fall_sound() -> void:
	UISound.stack_spill()
