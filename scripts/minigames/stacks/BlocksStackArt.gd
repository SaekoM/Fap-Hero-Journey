class_name BlocksStackArt
extends StackArt

# A tower of wooden blocks, a little uneven. The whole tower tumbles over to one side, end over end, the higher blocks
# travelling furthest.

const WIDTH: float = 88.0
const HEIGHT: float = 15.0
const WOOD: Color = Color(0.72, 0.5, 0.29)
const WOOD_DARK: Color = Color(0.56, 0.37, 0.2)
const EDGE: Color = Color(0.3, 0.19, 0.09)
const GRAIN: Color = Color(0.42, 0.27, 0.13)
const GRAIN_ALPHA: float = 0.6
const TUMBLE_REACH: float = 240.0
const FALL_DROP: float = 300.0
const TUMBLE_SPIN: float = 3.2


func piece_width() -> float:
	return WIDTH


func piece_height() -> float:
	return HEIGHT


func misalignment() -> float:
	return 4.0


func draw_piece(
	stage: PushStackStage, index: int, kind: String, _accent: Color, gold: float, opacity: float
) -> void:
	var half: float = WIDTH / 2.0
	var plain: Color = WOOD if index % 2 == 0 else WOOD_DARK
	var wood: Color = kind_colour(kind, plain).lerp(StackArt.GOLD, gold)
	wood.a = opacity
	var block: Rect2 = Rect2(-half, 0.0, WIDTH, HEIGHT)
	stage.draw_rect(block, wood)
	var grain: Color = Color(GRAIN, GRAIN_ALPHA * opacity)
	var offset: float = 5.0 * (index % 3)
	stage.draw_line(
		Vector2(-half + 8.0 + offset, 5.0), Vector2(half - 20.0 + offset, 5.0), grain, 1.0
	)
	stage.draw_line(Vector2(-half + 20.0, 10.0), Vector2(half - 10.0 - offset, 10.0), grain, 1.0)
	stage.draw_rect(block, Color(EDGE, opacity), false, 1.0)
	draw_emblem(stage, kind, opacity)


func fall(index: int, count: int, progress: float) -> Vector3:
	var height_share: float = float(index + 1) / count
	return Vector3(
		progress * TUMBLE_REACH * height_share,
		progress * progress * FALL_DROP,
		progress * TUMBLE_SPIN * height_share
	)


func play_fall_sound() -> void:
	UISound.stack_tumble()
