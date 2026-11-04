class_name PadlockLockArt
extends LockArt

# A padlock with the dial set into its body. Each number lifts the shackle a little out of the body; on the
# release it pops up and swings round on its right leg.

const BODY_RECT: Rect2 = Rect2(110.0, 88.0, 240.0, 246.0)
const DIAL_CENTER: Vector2 = Vector2(230.0, 205.0)
const PIPS_Y: float = 317.0
const SHACKLE_ARC_CENTER: Vector2 = Vector2(230.0, 78.0)
const SHACKLE_RADIUS: float = 52.0
const SHACKLE_THICKNESS: float = 20.0
const SHACKLE_LEG_BOTTOM: float = 120.0  # hidden inside the body while locked
const SHACKLE_PROGRESS_LIFT: float = 8.0  # how far it rises with every number open
const SHACKLE_RELEASE_LIFT: float = 12.0
const SHACKLE_SWING: float = 0.6  # radians, round its right leg
const RATTLE_SHIFT: float = 6.0
const POP_END: float = 0.4  # the part of the release spent popping up, before it swings


func dial_radius() -> float:
	return 92.0


func dial_transform(_area: Vector2) -> Transform2D:
	return Transform2D(0.0, DIAL_CENTER)


func reward_center(_area: Vector2) -> Vector2:
	return DIAL_CENTER


func draw_lock(canvas: CanvasItem, _area: Vector2) -> void:
	_draw_shackle(canvas)
	_draw_plate(canvas, BODY_RECT, STEEL, STEEL_LIGHT, 18)
	_draw_plate(canvas, BODY_RECT.grow(-10.0), Color(STEEL, 0.0), STEEL_DARK, 12)
	_draw_pips(canvas, Vector2(DIAL_CENTER.x, PIPS_Y), BODY_RECT.size.x - 60.0)


func _draw_shackle(canvas: CanvasItem) -> void:
	var lift: float = (
		SHACKLE_PROGRESS_LIFT * opened / maxf(1.0, numbers)
		+ SHACKLE_RELEASE_LIFT * smoothstep(0.0, POP_END, release)
	)
	var swing: float = SHACKLE_SWING * smoothstep(POP_END, 1.0, release)
	var pivot: Vector2 = Vector2(SHACKLE_ARC_CENTER.x + SHACKLE_RADIUS, BODY_RECT.position.y)
	var shift: Vector2 = Vector2(rattle * RATTLE_SHIFT, -lift)
	canvas.draw_set_transform_matrix(
		(
			Transform2D(0.0, pivot + shift)
			* Transform2D(swing, Vector2.ZERO)
			* Transform2D(0.0, -pivot)
		)
	)
	var left: float = SHACKLE_ARC_CENTER.x - SHACKLE_RADIUS
	var right: float = SHACKLE_ARC_CENTER.x + SHACKLE_RADIUS
	for leg_x: float in [left, right]:
		canvas.draw_line(
			Vector2(leg_x, SHACKLE_ARC_CENTER.y),
			Vector2(leg_x, SHACKLE_LEG_BOTTOM),
			STEEL_LIGHT,
			SHACKLE_THICKNESS
		)
	canvas.draw_arc(
		SHACKLE_ARC_CENTER, SHACKLE_RADIUS, PI, TAU, 32, STEEL_LIGHT, SHACKLE_THICKNESS, true
	)
	canvas.draw_set_transform_matrix(Transform2D.IDENTITY)
