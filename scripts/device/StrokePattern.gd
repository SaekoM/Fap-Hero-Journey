class_name StrokePattern
extends RefCounted

# The ruler a stroker is calibrated against: a slow, full-range, perfectly regular stroke.
#
# Real content makes a bad ruler. Scripts run at two or three strokes a second and rarely use the whole
# range, and nobody can judge a 150 ms phase error against that. This gives one unambiguous event to
# match — the device arriving at the top and stopping — repeated at an interval you can count out loud.
#
# The hold at each end is what makes it readable. A device tracking a triangle wave is never still, so
# "the top" is a guess; a device that arrives and waits announces itself.
#
# Pure and static, so the shape is unit-testable without a device or a scene.

const DEFAULT_CYCLE_MS: int = 2000  # one full up-and-down
const DEFAULT_HOLD_MS: int = 220  # the pause at each end that marks the turn
const DEFAULT_TOTAL_MS: int = 180000  # ~3 min: long enough to settle on a number, short enough to end
# Not the full 0-100. The extremes are where a device is most likely to clip against its own travel
# limits, and a stroke that clips arrives EARLY — hiding the very lag being measured.
const DEFAULT_LOW: int = 5
const DEFAULT_HIGH: int = 95

# The shortest rise or fall worth generating, so an over-long hold can't swallow the travel and leave a
# pattern that only jumps between the ends.
const MIN_TRAVEL_MS: int = 60


# Builds the pattern as Array[Vector2](at_ms, pos) — the shape JourneyData.read_funscript_actions
# returns, so it feeds the device paths exactly as a real script would.
static func calibration(
	cycle_ms: int = DEFAULT_CYCLE_MS,
	total_ms: int = DEFAULT_TOTAL_MS,
	low: int = DEFAULT_LOW,
	high: int = DEFAULT_HIGH,
	hold_ms: int = DEFAULT_HOLD_MS
) -> Array:
	var cycle: int = maxi(cycle_ms, (MIN_TRAVEL_MS + 1) * 2)
	var hold: int = clampi(hold_ms, 0, cycle / 2 - MIN_TRAVEL_MS)
	var travel: int = cycle / 2 - hold
	var lo: int = clampi(low, 0, 100)
	var hi: int = clampi(high, 0, 100)

	var out: Array = []
	var t: int = 0
	while t < maxi(total_ms, cycle):
		out.append(Vector2(t, lo))  # at rest at the bottom, about to rise
		out.append(Vector2(t + travel, hi))  # the top — the moment to match against the device
		if hold > 0:
			out.append(Vector2(t + travel + hold, hi))
			# The bottom is reached here but NOT closed: the next cycle's opening point holds it there.
			# Emitting both would put two points on the same millisecond when hold is 0.
			out.append(Vector2(t + travel + hold + travel, lo))
		t += cycle
	out.append(Vector2(t, lo))  # close the last cycle at rest rather than mid-move
	return out
