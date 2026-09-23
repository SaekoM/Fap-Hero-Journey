class_name StrokePattern
extends RefCounted

# The ruler a stroker is calibrated against.
#
# Real content makes a bad ruler. Scripts run at two or three strokes a second and rarely use the whole
# range, and nobody can judge a 150 ms phase error against that. So the ruler is slow, full-range, and
# holds still at each end — a device tracking a triangle wave is never stationary, so "the top" is a
# guess, while a device that arrives and waits announces itself.
#
# But a ruler with no marks on it can only measure part of the error. A PERFECTLY REGULAR stroke looks
# the same at t and at t+cycle, so a device a whole cycle late is indistinguishable from one in perfect
# sync — and at a two-second cycle that is two seconds of lag you cannot see, which is more than the
# delay slider's whole range. `bar()` is the answer: one repeating BAR made of three phases that feel
# nothing like each other — a long sweep, a burst of quick taps, then stillness — so any offset lands
# you in the wrong phase and says so. `cycles()` remains for the plain regular shape.
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

# The bar's three phases. Sized so each is unmistakable BY FEEL, not just on the meter: the sweep is
# slower than anything in real content, the taps are faster than any of it, and the rest is the only
# time the device is still for longer than a turn. The bar runs ~5 s — comfortably more than twice
# the delay slider's 2 s range, so no reachable delay can disguise itself as a different phase.
const BAR_SWEEP_TRAVEL_MS: int = 1100  # the long climb: the moment to match
const BAR_SWEEP_HOLD_MS: int = 300  # held at each end of the sweep
const BAR_TAPS: int = 3
const BAR_TAP_TRAVEL_MS: int = 150  # each quick stroke
const BAR_TAP_HOLD_MS: int = 60  # the beat between them, so three reads as three
const BAR_REST_MS: int = 900  # dead still at the bottom — the easiest landmark of all


# The calibration ruler: repeating bars of sweep → taps → rest, as Array[Vector2](at_ms, pos) — the
# shape JourneyData.read_funscript_actions returns, so it feeds the device paths exactly as a real
# script would. Every phase boundary is a landmark, so a device that is late lands in a phase the
# screen isn't showing and the error is visible rather than hidden by the repeat.
static func bar(
	total_ms: int = DEFAULT_TOTAL_MS, low: int = DEFAULT_LOW, high: int = DEFAULT_HIGH
) -> Array:
	var lo: int = clampi(low, 0, 100)
	var hi: int = clampi(high, 0, 100)
	var out: Array = [Vector2(0, lo)]  # at rest at the bottom, about to sweep
	var t: int = 0
	# At least one whole bar, however short a total is asked for: half a ruler is not a ruler.
	while t < maxi(total_ms, 1):
		t = _step(out, t, hi, BAR_SWEEP_TRAVEL_MS)
		t = _step(out, t, hi, BAR_SWEEP_HOLD_MS)
		t = _step(out, t, lo, BAR_SWEEP_TRAVEL_MS)
		t = _step(out, t, lo, BAR_SWEEP_HOLD_MS)
		for _i: int in BAR_TAPS:
			t = _step(out, t, hi, BAR_TAP_TRAVEL_MS)
			t = _step(out, t, hi, BAR_TAP_HOLD_MS)
			t = _step(out, t, lo, BAR_TAP_TRAVEL_MS)
			t = _step(out, t, lo, BAR_TAP_HOLD_MS)
		t = _step(out, t, lo, BAR_REST_MS)
	return out


# One move or hold: a point `ms` later at `pos`. Every phase is built from these, so timestamps come
# out strictly increasing by construction and no two can ever share a millisecond.
static func _step(out: Array, t: int, pos: int, ms: int) -> int:
	var at: int = t + maxi(1, ms)
	out.append(Vector2(at, pos))
	return at


# The plain regular shape: one cycle repeated, bottom → top → bottom. Kept for callers that want an
# even ruler (and as the reference the bar is measured against in tests); the calibration screen uses
# bar() instead, for the reason in the class note.
static func cycles(
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
