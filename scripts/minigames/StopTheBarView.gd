class_name StopTheBarView
extends TurnGameView

# Stop the Bar's play view: a needle sweeps a bar, and a press stops it. The rules live in StopTheBarGame, and what
# this shares with Hold & Release in TurnGameView.

const TRAIL_STEPS: int = 5
const TRAIL_STEP_MS: int = 16

var _sweep_elapsed_ms: float = 0.0
var _track: BarTrack


func _build_stage() -> TurnStage:
	var bar_game: StopTheBarGame = _game
	_track = BarTrack.new()
	_track.zone_centre = bar_game.current_zone_centre()
	_track.zone_half_width = bar_game.current_zone_half_width()
	return _track


func _hint_text() -> String:
	return "STOP WITH E, ENTER OR A CLICK"


func _on_turn_starting() -> void:
	_sweep_elapsed_ms = 0.0


func _on_press_in_play() -> void:
	var bar_game: StopTheBarGame = _game
	var accuracy: float = bar_game.stop(int(_sweep_elapsed_ms))
	_track.trail = PackedFloat32Array()
	_land_turn(accuracy, "IN THE ZONE" if accuracy > 0.0 else "MISSED", accuracy > 0.0)
	if not bar_game.is_finished():
		_glide_zone_to_next(bar_game)


func _play_tick(delta: float) -> void:
	var bar_game: StopTheBarGame = _game
	_sweep_elapsed_ms += delta * 1000.0
	_track.marker = bar_game.marker_at(int(_sweep_elapsed_ms))
	var positions: PackedFloat32Array = []
	for step: int in range(1, TRAIL_STEPS + 1):
		positions.append(bar_game.marker_at(int(_sweep_elapsed_ms) - step * TRAIL_STEP_MS))
	_track.trail = positions


# The zone slides to where the next stop needs it and the needle returns to the left end, so nothing jumps as the
# next sweep begins.
func _glide_zone_to_next(bar_game: StopTheBarGame) -> void:
	var reset: Tween = _stage_reset_tween()
	reset.tween_property(_track, "zone_centre", bar_game.current_zone_centre(), RESET_SECS)
	reset.parallel().tween_property(
		_track, "zone_half_width", bar_game.current_zone_half_width(), RESET_SECS
	)
	reset.parallel().tween_property(_track, "marker", 0.0, RESET_SECS)


# The bar: a track with tick marks, a zone brightest at its dead centre, and a needle.
class BarTrack:
	extends TurnStage

	const BAR_HEIGHT: float = 56.0
	const OVERHANG: float = 10.0  # how far the needle reaches above and below the bar
	const NEEDLE_WIDTH: float = 4.0
	const ARROW_HALF_WIDTH: float = 8.0
	const SLAM_EXTRA_WIDTH: float = 8.0
	const TICK_COUNT: int = 10
	const TICK_HEIGHT: float = 8.0
	const ZONE_EDGE_ALPHA: float = 0.15
	const ZONE_CENTRE_ALPHA: float = 0.9
	const TRAIL_START_ALPHA: float = 0.4
	const MISS_CROSS_SIZE: float = 9.0

	var marker: float = 0.0  # where the needle is on the bar, 0–1
	var trail: PackedFloat32Array = []  # where it just was, nearest first
	var zone_centre: float = 0.5
	var zone_half_width: float = 0.1

	func _init() -> void:
		custom_minimum_size = Vector2(0.0, BAR_HEIGHT + 2.0 * OVERHANG)

	func impact_point() -> Vector2:
		return Vector2(size.x * marker, size.y / 2.0)

	func _draw() -> void:
		draw_set_transform(Vector2(shake_x, 0.0))
		var bar: Rect2 = Rect2(0.0, OVERHANG, size.x, BAR_HEIGHT)
		_draw_track(bar)
		_draw_zone(bar)
		_draw_trail(bar)
		_draw_needle(bar)
		_draw_ripple()

	func _draw_track(bar: Rect2) -> void:
		draw_rect(bar, UITheme.BAR_BG)
		for tick: int in range(1, TICK_COUNT):
			var x: float = bar.size.x * tick / TICK_COUNT
			var colour: Color = Color(UITheme.TEXT_HINT, 0.5)
			draw_line(Vector2(x, bar.end.y - TICK_HEIGHT), Vector2(x, bar.end.y), colour, 1.0)
		draw_rect(bar, UITheme.PURPLE_MID, false, 1.0)

	func _draw_zone(bar: Rect2) -> void:
		var centre_x: float = bar.size.x * zone_centre
		var half: float = bar.size.x * zone_half_width
		var top: float = bar.position.y
		var bottom: float = bar.end.y
		var edge: Color = Color(accent, ZONE_EDGE_ALPHA)
		var middle: Color = Color(accent, ZONE_CENTRE_ALPHA)
		for side: float in [-1.0, 1.0]:
			var outer_x: float = centre_x + side * half
			draw_polygon(
				PackedVector2Array(
					[
						Vector2(outer_x, top),
						Vector2(centre_x, top),
						Vector2(centre_x, bottom),
						Vector2(outer_x, bottom),
					]
				),
				PackedColorArray([edge, middle, middle, edge])
			)
		var zone: Rect2 = Rect2(centre_x - half, top, half * 2.0, bar.size.y)
		draw_rect(zone, accent, false, 2.0)
		if flash > 0.0:
			draw_rect(zone, Color(Color.WHITE, flash * 0.7))
		# The dead centre, dark behind light so it shows on any accent colour.
		draw_line(Vector2(centre_x, top), Vector2(centre_x, bottom), UITheme.BG, 4.0)
		draw_line(Vector2(centre_x, top), Vector2(centre_x, bottom), Color.WHITE, 2.0)

	func _draw_trail(bar: Rect2) -> void:
		for step: int in trail.size():
			var x: float = bar.size.x * trail[step]
			var alpha: float = TRAIL_START_ALPHA * (1.0 - float(step + 1) / (trail.size() + 1))
			var ghost: Rect2 = Rect2(
				x - NEEDLE_WIDTH / 2.0, bar.position.y, NEEDLE_WIDTH, bar.size.y
			)
			draw_rect(ghost, Color(Color.WHITE, alpha))

	func _draw_needle(bar: Rect2) -> void:
		var x: float = bar.size.x * marker
		var colour: Color = UITheme.DANGER if missed else Color.WHITE
		var width: float = NEEDLE_WIDTH + SLAM_EXTRA_WIDTH * slam
		draw_rect(Rect2(x - width / 2.0, bar.position.y, width, bar.size.y), colour)
		_draw_arrow(x, 0.0, bar.position.y, colour)
		_draw_arrow(x, size.y, bar.end.y, colour)
		if missed:
			var mid: Vector2 = Vector2(x, bar.get_center().y)
			var down: Vector2 = Vector2(MISS_CROSS_SIZE, MISS_CROSS_SIZE)
			var up: Vector2 = Vector2(MISS_CROSS_SIZE, -MISS_CROSS_SIZE)
			draw_line(mid - down, mid + down, colour, 3.0)
			draw_line(mid - up, mid + up, colour, 3.0)

	# An arrowhead on the needle: its base at `base_y`, its tip at `tip_y`.
	func _draw_arrow(x: float, base_y: float, tip_y: float, colour: Color) -> void:
		draw_colored_polygon(
			PackedVector2Array(
				[
					Vector2(x - ARROW_HALF_WIDTH, base_y),
					Vector2(x + ARROW_HALF_WIDTH, base_y),
					Vector2(x, tip_y),
				]
			),
			colour
		)
