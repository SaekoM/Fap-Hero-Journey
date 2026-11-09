class_name TurnLamps
extends Control

# One lamp per turn of a TurnScoreGame, with its percent underneath. Unlit, the next turn pulses, then filled by how
# well it went: a dead-on turn gets a second ring and a miss a cross, so neither rests on colour.

const RADIUS: float = 13.0
const TALLY_GROWTH: float = 5.0
const CURRENT_GROWTH: float = 2.0
const OUTER_RING_GAP: float = 4.0
const CROSS_SIZE: float = 6.0
const TEXT_GAP: float = 18.0
const FONT_SIZE: int = 13
const HEIGHT: float = 58.0
const LOWEST_FILL_ALPHA: float = 0.35
const PULSE_SPEED: float = 5.0

var game: TurnScoreGame
var accent: Color = Color.WHITE
var current: int = -1  # the turn being played
var tally_index: int = -1  # the lamp the ending is counting

var _clock: float = 0.0
var _reduce_flashing: bool = SettingsService.get_reduce_flashing()


func _init() -> void:
	custom_minimum_size = Vector2(0.0, HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	if current >= 0 and not _reduce_flashing:
		_clock += delta
		queue_redraw()


func _draw() -> void:
	var font: Font = get_theme_font("font", "Label")
	var spacing: float = size.x / game.turn_count
	for index: int in game.turn_count:
		var centre: Vector2 = Vector2(spacing * (index + 0.5), RADIUS + TALLY_GROWTH)
		if index < game.accuracies.size():
			_draw_taken_turn(centre, index, font, spacing)
		elif index == current:
			var pulse: float = 0.5 + 0.5 * sin(_clock * PULSE_SPEED)
			var alpha: float = 1.0 if _reduce_flashing else lerpf(0.5, 1.0, pulse)
			draw_arc(centre, RADIUS + CURRENT_GROWTH, 0.0, TAU, 32, Color(accent, alpha), 3.0, true)
		else:
			draw_arc(centre, RADIUS, 0.0, TAU, 32, Color(UITheme.TEXT_HINT, 0.6), 1.5, true)


func _draw_taken_turn(centre: Vector2, index: int, font: Font, spacing: float) -> void:
	var accuracy: float = game.accuracies[index]
	var radius: float = RADIUS + (TALLY_GROWTH if index == tally_index else 0.0)
	if accuracy <= 0.0:
		_draw_miss(centre, radius)
	elif accuracy >= TurnScoreGame.DEAD_ON_ACCURACY:
		draw_circle(centre, radius, UITheme.AMBER)
		draw_arc(centre, radius + OUTER_RING_GAP, 0.0, TAU, 32, UITheme.AMBER, 1.5, true)
	else:
		draw_circle(centre, radius, Color(accent, lerpf(LOWEST_FILL_ALPHA, 1.0, accuracy)))
		draw_arc(centre, radius, 0.0, TAU, 32, accent, 1.5, true)
	var text_at: Vector2 = Vector2(centre.x - spacing / 2.0, centre.y + RADIUS + TEXT_GAP)
	var text: String = "%d%%" % roundi(accuracy * 100.0)
	draw_string(
		font, text_at, text, HORIZONTAL_ALIGNMENT_CENTER, spacing, FONT_SIZE, UITheme.WHITE_SOFT
	)


func _draw_miss(centre: Vector2, radius: float) -> void:
	draw_arc(centre, radius, 0.0, TAU, 32, UITheme.DANGER, 2.0, true)
	var down: Vector2 = Vector2(CROSS_SIZE, CROSS_SIZE)
	var up: Vector2 = Vector2(CROSS_SIZE, -CROSS_SIZE)
	draw_line(centre - down, centre + down, UITheme.DANGER, 2.0)
	draw_line(centre - up, centre + up, UITheme.DANGER, 2.0)
