class_name GaugeArt
extends RefCounted

# What one kind of Hold & Release container looks like. HoldGaugeStage owns the numbers that animate; an art only
# draws them, in the stage's own coordinates. The look never changes the rules. So a new container is one small
# subclass, an entry in STYLES and STYLE_NAMES, and a line in art_for.

const STYLE_TUBE: String = "tube"
const STYLE_BOTTLE: String = "bottle"
const STYLE_THERMOMETER: String = "thermometer"
const STYLE_DIAL: String = "dial"
const STYLE_HEART: String = "heart"
const STYLES: Array[String] = [STYLE_TUBE, STYLE_BOTTLE, STYLE_THERMOMETER, STYLE_DIAL, STYLE_HEART]
const STYLE_NAMES: Dictionary = {
	STYLE_TUBE: "Tube",
	STYLE_BOTTLE: "Bottle",
	STYLE_THERMOMETER: "Thermometer",
	STYLE_DIAL: "Pressure dial",
	STYLE_HEART: "Heart",
}
const DEFAULT_STYLE: String = STYLE_TUBE

# Every art draws into this height, so changing the container never moves the rest of the panel.
const AREA_HEIGHT: float = 240.0
const ARROW_LENGTH: float = 16.0
const ARROW_HALF_WIDTH: float = 8.0
const TOP_EDGE_DARK_WIDTH: float = 5.0
const TOP_EDGE_LIGHT_WIDTH: float = 3.0
const GHOST_ALPHA: float = 0.45
const SHELL_WIDTH: float = 2.0
const CRACK_WIDTH: float = 2.0
const SPRAY_GRAVITY: Vector2 = Vector2(0.0, 620.0)
const FLOAT_OFFSET_X: float = 130.0
# The warning as the gauge nears its limit speeds up and rises with the danger.
const CREAK_GAP_FAR: float = 0.45
const CREAK_GAP_NEAR: float = 0.12
const CREAK_PITCH_FAR: float = 0.8
const CREAK_PITCH_NEAR: float = 1.3
const RIPPLE_WIDTH: float = 3.0
const RIPPLE_POINTS: int = 48


static func art_for(style: String) -> GaugeArt:
	match style:
		STYLE_BOTTLE:
			return BottleGaugeArt.new()
		STYLE_THERMOMETER:
			return ThermometerGaugeArt.new()
		STYLE_DIAL:
			return DialGaugeArt.new()
		STYLE_HEART:
			return HeartGaugeArt.new()
	return TubeGaugeArt.new()


func draw_gauge(_stage: HoldGaugeStage) -> void:
	pass


# Where `level` is on this container, in a stage of `area`.
func level_point(_area: Vector2, _level: float) -> Vector2:
	return Vector2.ZERO


# How far from the centre a turn's percent starts its rise, so it clears the container.
func float_offset_x() -> float:
	return FLOAT_OFFSET_X


# Whether it throws out a spray of particles when it fails, or draws everything itself.
func sprays_on_failure() -> bool:
	return true


# What flies out when it fails, and how it falls.
func spray_colour(stage: HoldGaugeStage) -> Color:
	return stage.accent


func spray_gravity() -> Vector2:
	return SPRAY_GRAVITY


func play_fail_sound() -> void:
	UISound.gauge_burst()


# The warning sound at `danger` (0–1), and how long until the next one.
func play_danger_sound(danger: float) -> void:
	UISound.gauge_creak(lerpf(CREAK_PITCH_FAR, CREAK_PITCH_NEAR, danger))


func danger_sound_gap(danger: float) -> float:
	return lerpf(CREAK_GAP_FAR, CREAK_GAP_NEAR, danger)


func draw_ripple(stage: HoldGaugeStage, at: Vector2, radius: float, colour: Color) -> void:
	stage.draw_arc(at, radius, 0.0, TAU, RIPPLE_POINTS, colour, RIPPLE_WIDTH, true)


# An arrowhead on `stage`, with its point at `tip` and its base `back` away from it.
func _draw_arrow(stage: HoldGaugeStage, tip: Vector2, back: Vector2, colour: Color) -> void:
	var side: Vector2 = back.orthogonal().normalized() * ARROW_HALF_WIDTH
	stage.draw_colored_polygon(
		PackedVector2Array([tip, tip + back + side, tip + back - side]), colour
	)


# The zone's top edge, dark behind light so it shows on any accent colour.
func _draw_edge_line(stage: HoldGaugeStage, from: Vector2, to: Vector2) -> void:
	stage.draw_line(from, to, UITheme.BG, TOP_EDGE_DARK_WIDTH)
	stage.draw_line(from, to, Color.WHITE, TOP_EDGE_LIGHT_WIDTH)
