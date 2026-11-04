class_name SafeLockArt
extends LockArt

# A safe door. Each number slides a bolt back; on the release the handle spins, then the door swings open on
# its left hinges, carrying the dial with it.

const FRAME_INSET: Vector2 = Vector2(14.0, 6.0)
const DOOR_INSET: float = 12.0
const DIAL_CENTER_X: float = 176.0  # left of centre, leaving the door's right side for the handle and bolts
const HANDLE_CENTER_X: float = 332.0
const HANDLE_RADIUS: float = 24.0
const HANDLE_SPIN_TURNS: float = 1.5
const HANDLE_SPIN_END: float = 0.35  # the part of the release spent spinning the handle
const HANDLE_RATTLE_RADIANS: float = 0.3
const DOOR_OPEN_WIDTH: float = 0.1  # how much of its width the door still shows, fully swung open
const BOLT_SIZE: Vector2 = Vector2(46.0, 14.0)
const BOLT_REACH: float = 8.0  # how far a closed bolt sticks out past the door, into the frame
const BOLT_TRAVEL: float = 30.0
const RIVET_INSET: float = 18.0
const RIVET_RADIUS: float = 4.0


func dial_radius() -> float:
	return 112.0


func dial_transform(area: Vector2) -> Transform2D:
	return (
		_door_transform(_door_rect(area)) * Transform2D(0.0, Vector2(DIAL_CENTER_X, area.y / 2.0))
	)


# The dial stays on the door as it swings.
func dial_opacity() -> float:
	return 1.0


func reveal_point() -> float:
	return HANDLE_SPIN_END


func reward_center(area: Vector2) -> Vector2:
	return area / 2.0 + Vector2(20.0, 0.0)  # the door, swung open, hides the left edge of the hollow


func draw_lock(canvas: CanvasItem, area: Vector2) -> void:
	var door: Rect2 = _door_rect(area)
	_draw_plate(canvas, Rect2(FRAME_INSET, area - FRAME_INSET * 2.0), STEEL_DARK, STEEL, 10)
	_draw_plate(canvas, door, HOLLOW, STEEL_DARK, 4)
	canvas.draw_set_transform_matrix(_door_transform(door))
	_draw_plate(canvas, door, STEEL, STEEL_LIGHT, 6)
	_draw_plate(canvas, door.grow(-RIVET_INSET / 2.0), Color(STEEL, 0.0), STEEL_DARK, 4)
	_draw_rivets(canvas, door)
	_draw_bolts(canvas, door)
	_draw_handle(canvas, Vector2(HANDLE_CENTER_X, area.y / 2.0))
	canvas.draw_set_transform_matrix(Transform2D.IDENTITY)


func _door_rect(area: Vector2) -> Rect2:
	return Rect2(FRAME_INSET, area - FRAME_INSET * 2.0).grow(-DOOR_INSET)


# The door turning on its left edge: narrowed towards the hinge, as a door seen swinging open is.
func _door_transform(door: Rect2) -> Transform2D:
	var swing: float = smoothstep(HANDLE_SPIN_END, 1.0, release)
	var width: float = lerpf(1.0, DOOR_OPEN_WIDTH, swing)
	return Transform2D(
		Vector2(width, 0.0), Vector2(0.0, 1.0), Vector2(door.position.x * (1.0 - width), 0.0)
	)


func _draw_rivets(canvas: CanvasItem, door: Rect2) -> void:
	var inner: Rect2 = door.grow(-RIVET_INSET)
	for corner: Vector2 in [
		inner.position,
		Vector2(inner.end.x, inner.position.y),
		Vector2(inner.position.x, inner.end.y),
		inner.end,
	]:
		canvas.draw_circle(corner, RIVET_RADIUS, STEEL_LIGHT)


func _draw_bolts(canvas: CanvasItem, door: Rect2) -> void:
	for i in numbers:
		var open: float = _part_open(i)
		var y: float = door.position.y + door.size.y * (i + 1) / (numbers + 1)
		var left: float = door.end.x + BOLT_REACH - BOLT_SIZE.x - BOLT_TRAVEL * open
		var bolt: Rect2 = Rect2(Vector2(left, y - BOLT_SIZE.y / 2.0), BOLT_SIZE)
		_draw_plate(canvas, bolt, Color(STEEL_LIGHT).lerp(UITheme.AMBER, open), STEEL_DARK, 3)


func _draw_handle(canvas: CanvasItem, center: Vector2) -> void:
	var spin: float = TAU * HANDLE_SPIN_TURNS * smoothstep(0.0, HANDLE_SPIN_END, release)
	var turn: float = spin + rattle * HANDLE_RATTLE_RADIANS
	for spoke in 3:
		var direction: Vector2 = Vector2.from_angle(turn + TAU * spoke / 3.0)
		canvas.draw_line(center, center + direction * HANDLE_RADIUS, STEEL_LIGHT, 7.0, true)
		canvas.draw_circle(center + direction * HANDLE_RADIUS, 6.0, STEEL_LIGHT)
	canvas.draw_circle(center, 10.0, STEEL_DARK)
