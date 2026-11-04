class_name HandcuffsLockArt
extends LockArt

# A pair of cuffs chained to the dial. Each number loosens the ratchet a notch, widening the gap in both
# cuffs; on the release they spring open and fly apart.

const DIAL_CENTER: Vector2 = Vector2(230.0, 128.0)
const CUFF_CENTER_X_INSET: float = 70.0  # from the stage's side
const CUFF_CENTER_Y: float = 255.0
const CUFF_RADIUS: float = 54.0
const CUFF_THICKNESS: float = 14.0
const LOCK_BOX_SIZE: Vector2 = Vector2(92.0, 28.0)
const LOCK_BOX_Y: float = -CUFF_RADIUS - 8.0  # from the cuff's centre
const GAP_ANGLE: float = PI / 2.0  # the cuff opens at the bottom
const GAP_CLOSED: float = PI / 18.0  # 10°
const GAP_LOOSENED: float = PI / 3.0  # 60°: with every number open, before the release
const GAP_RELEASED: float = PI * 7.0 / 6.0  # 210°
const TOOTH_COUNT: int = 7
const TOOTH_STEP: float = 0.13
const TOOTH_LENGTH: float = 7.0
const SPRING_DISTANCE: Vector2 = Vector2(26.0, 14.0)
const SPRING_TILT: float = 0.45
const RATTLE_TILT: float = 0.14
const CHAIN_LINK_COUNT: int = 4
const CHAIN_LINK_RADIUS: float = 8.0


func dial_radius() -> float:
	return 105.0


func dial_transform(_area: Vector2) -> Transform2D:
	return Transform2D(0.0, DIAL_CENTER)


func reward_center(area: Vector2) -> Vector2:
	return area / 2.0


func draw_lock(canvas: CanvasItem, area: Vector2) -> void:
	_draw_chain(canvas, _lock_box_anchor(area, -1.0))
	_draw_chain(canvas, _lock_box_anchor(area, 1.0))
	_draw_cuff(canvas, area, -1.0)
	_draw_cuff(canvas, area, 1.0)
	canvas.draw_set_transform_matrix(Transform2D.IDENTITY)


# Where a cuff sits, resting: `side` is -1 for the left one, 1 for the right.
func _cuff_home(area: Vector2, side: float) -> Vector2:
	return Vector2(area.x / 2.0 + side * (area.x / 2.0 - CUFF_CENTER_X_INSET), CUFF_CENTER_Y)


func _lock_box_anchor(area: Vector2, side: float) -> Vector2:
	return _cuff_home(area, side) + Vector2(0.0, LOCK_BOX_Y)


# The chain fades with the dial, which it hangs from.
func _draw_chain(canvas: CanvasItem, from: Vector2) -> void:
	var colour: Color = Color(STEEL_LIGHT, dial_opacity())
	var to_dial: Vector2 = DIAL_CENTER - from
	var length: float = to_dial.length() - dial_radius()
	for link in CHAIN_LINK_COUNT:
		var at: Vector2 = from + to_dial.normalized() * length * (link + 0.5) / CHAIN_LINK_COUNT
		canvas.draw_arc(at, CHAIN_LINK_RADIUS, 0.0, TAU, 16, colour, 3.0, true)


# Drawn as the left cuff, with the right one its mirror image.
func _draw_cuff(canvas: CanvasItem, area: Vector2, side: float) -> void:
	var spring: float = smoothstep(reveal_point(), 1.0, release)
	var home: Vector2 = _cuff_home(area, side)
	var at: Vector2 = home + Vector2(side * SPRING_DISTANCE.x, SPRING_DISTANCE.y) * spring
	var tilt: float = spring * SPRING_TILT + rattle * RATTLE_TILT
	var mirror: Transform2D = Transform2D(Vector2(-side, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
	canvas.draw_set_transform_matrix(
		Transform2D(0.0, at) * mirror * Transform2D(tilt, Vector2.ZERO)
	)

	var loosened: float = lerpf(GAP_CLOSED, GAP_LOOSENED, opened / maxf(1.0, numbers))
	var gap: float = lerpf(loosened, GAP_RELEASED, spring)
	var arc_start: float = GAP_ANGLE + gap / 2.0
	var arc_end: float = GAP_ANGLE + TAU - gap / 2.0
	canvas.draw_arc(Vector2.ZERO, CUFF_RADIUS, arc_start, arc_end, 48, STEEL, CUFF_THICKNESS, true)
	var inner_edge: float = CUFF_RADIUS - CUFF_THICKNESS / 2.0
	canvas.draw_arc(Vector2.ZERO, inner_edge, arc_start, arc_end, 48, STEEL_LIGHT, 2.0, true)
	for tooth in TOOTH_COUNT:
		var direction: Vector2 = Vector2.from_angle(arc_start + TOOTH_STEP * (tooth + 1))
		canvas.draw_line(
			direction * (CUFF_RADIUS + CUFF_THICKNESS / 2.0 - TOOTH_LENGTH),
			direction * (CUFF_RADIUS + CUFF_THICKNESS / 2.0),
			STEEL_DARK,
			2.0,
			true
		)
	var box: Rect2 = Rect2(
		Vector2(-LOCK_BOX_SIZE.x / 2.0, LOCK_BOX_Y - LOCK_BOX_SIZE.y / 2.0), LOCK_BOX_SIZE
	)
	_draw_plate(canvas, box, STEEL, STEEL_LIGHT, 5)
	_draw_pips(canvas, box.get_center(), box.size.x - 12.0)
