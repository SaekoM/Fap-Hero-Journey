extends MiniGameDevice

# Records what a mini-game view asks of the device, without any hardware. Shared by the view tests.

var calls: Array[String] = []
var held_half_cycles_ms: Array[int] = []
var streamed_axes: Array[Dictionary] = []
var axis_moves: Array = []


func stream_axes(positions: Dictionary) -> void:
	streamed_axes.append(positions)


func play_axis_moves(steps: Array) -> void:
	axis_moves.append(steps)


func hold(_lo: int, _hi: int, half_cycle_ms: int) -> void:
	calls.append("hold")
	held_half_cycles_ms.append(half_cycle_ms)


func walk(_fastest_ms: int, _slowest_ms: int, _secs: float) -> void:
	calls.append("walk")


func ease_out() -> void:
	calls.append("ease_out")


func stop() -> void:
	calls.append("stop")
