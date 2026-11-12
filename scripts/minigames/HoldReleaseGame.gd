class_name HoldReleaseGame
extends TurnScoreGame

# Hold & Release (Precision family, node host, skill): holding fills a gauge, and the player lets go inside a zone,
# several times. The zone's top edge scores best and anything past it is a miss, so greed pays until it doesn't.
# Rules and scoring: MINIGAMES_DESIGN.md → "Hold & Release".
#
# Pure state machine. Time comes in as milliseconds held, never as frames. Levels on the gauge run from 0.0 (empty)
# to 1.0 (full, where it bursts).

const KIND: String = "hold_release"

# {knob: [min, max, default]}
const KNOB_RANGES: Dictionary = {
	"holds": [1, 10, 3],
	"fill_ms": [600, 6000, 2500],
	"zone_pct": [5, 60, 20],
	"harder_pct": [0, 50, 0],
}

# How the gauge fills: slowly at first and faster as it rises, or at one rate.
const FILL_SPEEDS_UP: String = "speeds_up"
const FILL_STEADY: String = "steady"
const FILL_CURVES: Array[String] = [FILL_SPEEDS_UP, FILL_STEADY]

# A release at the zone's bottom edge scores this, rising to full marks at its top edge.
const ZONE_BOTTOM_ACCURACY: float = 0.5
# A release below the zone scores up to this, just under it.
const TOO_EARLY_BEST_ACCURACY: float = 0.3
# From this accuracy a release is right on the edge: a dead-on hold with its own moment.
const ON_THE_EDGE_ACCURACY: float = 0.98
# A release this far past the zone's top edge is called a near miss. It scores the same as any other overfill.
const JUST_OVER_MARGIN: float = 0.04

# A moved zone sits between these, so a hold always takes some time, and there's always room to overfill.
const LOWEST_ZONE_BOTTOM: float = 0.3
const HIGHEST_ZONE_TOP: float = 0.95
# A fixed zone is centred here, or as near as its width allows.
const FIXED_ZONE_CENTRE: float = 0.6
const LOWEST_FIXED_ZONE_BOTTOM: float = 0.05

var zone_bottoms: Array[float] = []  # one per hold
var zone_widths: Array[float] = []  # one per hold

var _fills_ms: Array[int] = []  # one per hold
var _speeds_up: bool


static func normalize_knobs(raw: Dictionary) -> Dictionary:
	var knobs: Dictionary = TurnScoreGame.normalize_shared_knobs(raw, KNOB_RANGES)
	var curve: String = str(raw.get("fill_curve", FILL_SPEEDS_UP))
	knobs["fill_curve"] = curve if curve in FILL_CURVES else FILL_SPEEDS_UP
	return knobs


# `time_scale` is the player's assist: it slows the fill and widens the zone by the same amount.
func _init(raw_knobs: Dictionary, rng_seed: int, time_scale: float = 1.0) -> void:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	var fill_ms: float = int(knobs["fill_ms"]) * time_scale
	var zone_width: float = minf(int(knobs["zone_pct"]) / 100.0 * time_scale, MAX_ZONE_WIDTH)
	_speeds_up = str(knobs["fill_curve"]) == FILL_SPEEDS_UP
	turn_count = int(knobs["holds"])
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = rng_seed
	var previous: float = -1.0
	for index: int in turn_count:
		var kept_share: float = difficulty_left(index, turn_count, int(knobs["harder_pct"]))
		var width: float = zone_width * kept_share
		_fills_ms.append(maxi(1, roundi(fill_ms * kept_share)))
		zone_widths.append(width)
		var bottom: float = _fixed_zone_bottom(width)
		if bool(knobs["moving_zone"]):
			bottom = _draw_zone_bottom(rng, previous, width)
		zone_bottoms.append(bottom)
		previous = bottom


static func _fixed_zone_bottom(width: float) -> float:
	var centred: float = FIXED_ZONE_CENTRE - width / 2.0
	return clampf(centred, LOWEST_FIXED_ZONE_BOTTOM, HIGHEST_ZONE_TOP - width)


func _draw_zone_bottom(rng: RandomNumberGenerator, previous: float, width: float) -> float:
	var highest: float = HIGHEST_ZONE_TOP - width
	if LOWEST_ZONE_BOTTOM >= highest:
		return _fixed_zone_bottom(width)  # a zone too wide to move
	var bottom: float = rng.randf_range(LOWEST_ZONE_BOTTOM, highest)
	for _try in ZONE_DRAW_TRIES:
		if previous < 0.0 or absf(bottom - previous) >= MIN_ZONE_GAP:
			break
		bottom = rng.randf_range(LOWEST_ZONE_BOTTOM, highest)
	return bottom


# ── Input ────────────────────────────────────────────────────────────────────


# Lets go after `held_ms`, and moves on to the next hold. Holding until the gauge is full ends the same way, as a
# miss. Returns the hold's accuracy, or -1.0 once every hold is made.
func release(held_ms: int) -> float:
	if is_finished():
		return -1.0
	var accuracy: float = accuracy_at(level_at(held_ms))
	accuracies.append(accuracy)
	return accuracy


# ── Reading the game ─────────────────────────────────────────────────────────


# How full the gauge is after `held_ms` of this hold.
func level_at(held_ms: int) -> float:
	var progress: float = clampf(float(held_ms) / _fills_ms[current_turn()], 0.0, 1.0)
	return progress * progress if _speeds_up else progress


# What letting go at `level` scores on this hold: rising to a small share just under the zone, rising from there to
# full marks at its top edge, and nothing past that.
func accuracy_at(level: float) -> float:
	var bottom: float = current_zone_bottom()
	var top: float = current_zone_top()
	if level > top:
		return 0.0
	if level < bottom:
		return TOO_EARLY_BEST_ACCURACY * level / bottom
	return lerpf(ZONE_BOTTOM_ACCURACY, 1.0, (level - bottom) / (top - bottom))


# Whether letting go at `level` on this hold would be a near miss.
func is_just_over(level: float) -> bool:
	var top: float = current_zone_top()
	return level > top and level <= top + JUST_OVER_MARGIN


func current_zone_bottom() -> float:
	return zone_bottoms[current_turn()]


func current_zone_top() -> float:
	return zone_bottoms[current_turn()] + zone_widths[current_turn()]
