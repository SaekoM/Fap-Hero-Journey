class_name LockArt
extends RefCounted

# What one kind of lock looks like. LockView owns the dial and every animated moment; an art only draws the
# lock from the numbers below, which LockView animates. So a new lock is one small subclass, an entry in
# STYLES and STYLE_NAMES, and a line in LockView.art_for.
#
# Everything is drawn in the stage's own coordinates, with the origin at its top left.

const STYLE_SAFE: String = "safe"
const STYLE_DOOR: String = "door"
const STYLE_HANDCUFFS: String = "handcuffs"
const STYLE_PADLOCK: String = "padlock"
const STYLES: Array[String] = [STYLE_SAFE, STYLE_DOOR, STYLE_HANDCUFFS, STYLE_PADLOCK]
const STYLE_NAMES: Dictionary = {
	STYLE_SAFE: "Safe",
	STYLE_DOOR: "Door",
	STYLE_HANDCUFFS: "Handcuffs",
	STYLE_PADLOCK: "Padlock",
}
const DEFAULT_STYLE: String = STYLE_SAFE

const STEEL: Color = Color(0.30, 0.32, 0.37)
const STEEL_LIGHT: Color = Color(0.58, 0.61, 0.67)
const STEEL_DARK: Color = Color(0.13, 0.14, 0.17)
const HOLLOW: Color = Color(0.03, 0.03, 0.05)

const PIP_RADIUS: float = 6.0
const PIP_SPACING: float = 20.0

var numbers: int = 1  # how many numbers this lock has to give up
var opened: float = 0.0  # numbers opened so far; passes through fractions as each one animates
var release: float = 0.0  # 0 = locked, 1 = the final release has finished
var rattle: float = 0.0  # -1 to 1: how far a wrong try is currently throwing the moving parts


# Draws the lock itself. The dial and the light are drawn over it by LockView.
func draw_lock(_canvas: CanvasItem, _area: Vector2) -> void:
	pass


func dial_radius() -> float:
	return 100.0


# Where the dial sits, as a transform of its centre, so it can move with the part it is mounted on.
func dial_transform(area: Vector2) -> Transform2D:
	return Transform2D(0.0, area / 2.0)


# Most locks fall away from around their dial, so the dial fades as the release starts.
func dial_opacity() -> float:
	return 1.0 - smoothstep(0.1, 0.4, release)


# How far through the release (0–1) the lock visibly gives way: the light and the fanfare start here.
func reveal_point() -> float:
	return 0.2


# How far through the release (0–1) the light starts to come up. A lock that opens in stages can hold it back.
func light_point() -> float:
	return reveal_point()


# Whether drawing is cut off at the stage's edges. Off by default, so parts can fly free during a release.
func clips_to_stage() -> bool:
	return false


# Where the light shines from and the prize appears once the lock has released.
func reward_center(area: Vector2) -> Vector2:
	return area / 2.0


# How open part `index` of the lock is, 0–1: each number moves one part.
func _part_open(index: int) -> float:
	return clampf(opened - index, 0.0, 1.0)


# A row of markers, one per number, filling as each opens. Hollow or solid, so colour isn't the only cue.
# They close up to fit within `room` pixels of width.
func _draw_pips(canvas: CanvasItem, center: Vector2, room: float) -> void:
	var spacing: float = minf(PIP_SPACING, (room - PIP_RADIUS * 2.0) / maxf(1.0, numbers - 1))
	var first_x: float = center.x - spacing * (numbers - 1) / 2.0
	for i in numbers:
		var at: Vector2 = Vector2(first_x + spacing * i, center.y)
		canvas.draw_circle(at, PIP_RADIUS, HOLLOW)
		canvas.draw_arc(at, PIP_RADIUS, 0.0, TAU, 20, STEEL_LIGHT, 1.5, true)
		var fill: float = _part_open(i)
		if fill > 0.0:
			canvas.draw_circle(at, (PIP_RADIUS - 1.5) * fill, UITheme.AMBER)


static func _draw_plate(
	canvas: CanvasItem, rect: Rect2, fill: Color, edge: Color, corner_radius: int
) -> void:
	var plate: StyleBoxFlat = StyleBoxFlat.new()
	plate.bg_color = fill
	plate.border_color = edge
	plate.set_border_width_all(2)
	plate.set_corner_radius_all(corner_radius)
	canvas.draw_style_box(plate, rect)
