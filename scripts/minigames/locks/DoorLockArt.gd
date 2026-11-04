class_name DoorLockArt
extends LockArt

# A close-up of a door's lock: wooden panelling with a brass plate, and the dial as the face of a big brass
# knob. Each number pops up a pin in the plate. On the release the knob turns, a line of light opens down the
# door's right edge, and the door swings towards the player, growing and fading past them into the light.

const WOOD: Color = Color(0.32, 0.20, 0.12)
const WOOD_DARK: Color = Color(0.17, 0.10, 0.06)
const BRASS: Color = Color(0.66, 0.50, 0.22)
const BRASS_LIGHT: Color = Color(0.86, 0.70, 0.36)
const BRASS_DARK: Color = Color(0.30, 0.21, 0.08)
const LIGHT_BEYOND: Color = Color(0.62, 0.50, 0.30)  # what shows through the opening door

const PLANK_COUNT: int = 6
const RECESS_LEFT: Rect2 = Rect2(16.0, 20.0, 74.0, 300.0)
const RECESS_RIGHT: Rect2 = Rect2(370.0, 20.0, 74.0, 300.0)
const PLATE_RECT: Rect2 = Rect2(105.0, 4.0, 250.0, 332.0)
const SCREW_INSET: float = 16.0
const SCREW_RADIUS: float = 5.0

const KNOB_CENTER: Vector2 = Vector2(230.0, 172.0)
const KNOB_DIAL_RADIUS: float = 92.0
const COLLAR_RADIUS: float = 114.0
const COLLAR_INNER_RADIUS: float = 108.0  # the dark band behind the dial's pointer, so it stands out on brass
const KNOB_TURN: float = PI / 2.0
const KNOB_RATTLE: float = 0.07  # radians: the knob jiggling against its plate

const PIN_SPACING: float = 30.0
const PIN_SLOT_TOP: float = 14.0
const PIN_SLOT_SIZE: Vector2 = Vector2(14.0, 34.0)
const PIN_WIDTH: float = 10.0
const PIN_HEIGHT_LOCKED: float = 6.0
const PIN_HEIGHT_OPEN: float = 28.0

const KEYHOLE_CENTER: Vector2 = Vector2(230.0, 303.0)
const KEYHOLE_RADIUS: float = 8.0
const KEYHOLE_FOOT: Vector2 = Vector2(9.0, 24.0)  # half its width and its height below the centre

# The release, as parts of its whole: the knob turns, the door comes ajar, then it swings past the player.
const KNOB_TURN_END: float = 0.25
const AJAR_END: float = 0.55
const AJAR_GAP: float = 44.0  # how wide the line of light gets before the door swings past
const PAST_PLAYER_SCALE: float = 1.7


func dial_radius() -> float:
	return KNOB_DIAL_RADIUS


# The dial is the knob's face: it turns with the knob, and rides on the door as it swings.
func dial_transform(area: Vector2) -> Transform2D:
	var turn: float = KNOB_TURN * smoothstep(0.0, KNOB_TURN_END, release) + rattle * KNOB_RATTLE
	return _door_transform(area) * Transform2D(turn, KNOB_CENTER)


func dial_opacity() -> float:
	return _door_opacity()


func reveal_point() -> float:
	return KNOB_TURN_END


func light_point() -> float:
	return AJAR_END


# The door grows past the stage's edges as it swings towards the player.
func clips_to_stage() -> bool:
	return true


func draw_lock(canvas: CanvasItem, area: Vector2) -> void:
	var door: Rect2 = Rect2(Vector2.ZERO, area)
	if release > 0.0:
		canvas.draw_rect(door, LIGHT_BEYOND)
	canvas.draw_set_transform_matrix(_door_transform(area))
	_draw_panelling(canvas, door)
	_draw_plate_and_screws(canvas)
	_draw_pins(canvas)
	_draw_keyhole(canvas)
	_draw_collar(canvas)
	canvas.draw_set_transform_matrix(Transform2D.IDENTITY)


# Hinged on the left: narrowing first opens a gap down the right edge, then growing brings it past the player.
func _door_transform(area: Vector2) -> Transform2D:
	var ajar: float = smoothstep(KNOB_TURN_END, AJAR_END, release)
	var past: float = lerpf(1.0, PAST_PLAYER_SCALE, smoothstep(AJAR_END, 1.0, release))
	var width: float = (area.x - AJAR_GAP * ajar) / area.x * past
	var hinge: Vector2 = Vector2(0.0, area.y / 2.0)
	var origin: Vector2 = hinge - Vector2(hinge.x * width, hinge.y * past)
	return Transform2D(Vector2(width, 0.0), Vector2(0.0, past), origin)


func _door_opacity() -> float:
	return 1.0 - smoothstep(AJAR_END, 1.0, release)


func _faded(colour: Color) -> Color:
	return Color(colour, colour.a * _door_opacity())


func _draw_panelling(canvas: CanvasItem, door: Rect2) -> void:
	canvas.draw_rect(door, _faded(WOOD))
	for plank in range(1, PLANK_COUNT):
		var x: float = door.size.x * plank / PLANK_COUNT
		canvas.draw_line(Vector2(x, 0.0), Vector2(x, door.size.y), _faded(WOOD_DARK), 2.0, true)
	for recess: Rect2 in [RECESS_LEFT, RECESS_RIGHT]:
		_draw_plate(canvas, recess, _faded(Color(WOOD_DARK, 0.55)), _faded(WOOD_DARK), 3)


func _draw_plate_and_screws(canvas: CanvasItem) -> void:
	_draw_plate(canvas, PLATE_RECT, _faded(BRASS), _faded(BRASS_LIGHT), 14)
	var inner: Rect2 = PLATE_RECT.grow(-SCREW_INSET)
	for corner: Vector2 in [
		inner.position,
		Vector2(inner.end.x, inner.position.y),
		Vector2(inner.position.x, inner.end.y),
		inner.end,
	]:
		canvas.draw_circle(corner, SCREW_RADIUS, _faded(BRASS_LIGHT))
		var slot: Vector2 = Vector2(SCREW_RADIUS - 1.0, 0.0)
		canvas.draw_line(corner - slot, corner + slot, _faded(BRASS_DARK), 1.5, true)


# A slot per number across the top of the plate. A pin stands taller as well as turning amber, so colour isn't
# the only cue.
func _draw_pins(canvas: CanvasItem) -> void:
	var first_x: float = KNOB_CENTER.x - PIN_SPACING * (numbers - 1) / 2.0
	var slot_bottom: float = PIN_SLOT_TOP + PIN_SLOT_SIZE.y
	for i in numbers:
		var x: float = first_x + PIN_SPACING * i
		var slot: Rect2 = Rect2(Vector2(x - PIN_SLOT_SIZE.x / 2.0, PIN_SLOT_TOP), PIN_SLOT_SIZE)
		_draw_plate(canvas, slot, _faded(HOLLOW), _faded(BRASS_DARK), 3)
		var open: float = _part_open(i)
		var height: float = lerpf(PIN_HEIGHT_LOCKED, PIN_HEIGHT_OPEN, open)
		var pin: Rect2 = Rect2(x - PIN_WIDTH / 2.0, slot_bottom - 3.0 - height, PIN_WIDTH, height)
		canvas.draw_rect(pin, _faded(Color(BRASS_LIGHT).lerp(UITheme.AMBER, open)))


func _draw_keyhole(canvas: CanvasItem) -> void:
	var foot_y: float = KEYHOLE_CENTER.y + KEYHOLE_FOOT.y
	(
		canvas
		. draw_colored_polygon(
			PackedVector2Array(
				[
					KEYHOLE_CENTER,
					Vector2(KEYHOLE_CENTER.x + KEYHOLE_FOOT.x, foot_y),
					Vector2(KEYHOLE_CENTER.x - KEYHOLE_FOOT.x, foot_y),
				]
			),
			_faded(HOLLOW)
		)
	)
	canvas.draw_circle(KEYHOLE_CENTER, KEYHOLE_RADIUS, _faded(HOLLOW))


func _draw_collar(canvas: CanvasItem) -> void:
	canvas.draw_circle(KNOB_CENTER, COLLAR_RADIUS, _faded(BRASS_LIGHT))
	canvas.draw_circle(KNOB_CENTER, COLLAR_RADIUS - 3.0, _faded(BRASS))
	canvas.draw_circle(KNOB_CENTER, COLLAR_INNER_RADIUS, _faded(BRASS_DARK))
