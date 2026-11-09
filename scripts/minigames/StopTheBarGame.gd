class_name StopTheBarGame
extends TurnScoreGame

# Stop the Bar (Precision family, node host, skill): a marker sweeps back and forth along a bar, and the player
# stops it inside a zone, several times. Rules and scoring: MINIGAMES_DESIGN.md → "Stop the Bar".
#
# Pure state machine. Time comes in as milliseconds since the current sweep began, never as frames, so a stop is
# exactly as hard at 60 Hz as at 144 Hz. Positions on the bar run from 0.0 (left) to 1.0 (right).

const KIND: String = "stop_the_bar"

# {knob: [min, max, default]}
const KNOB_RANGES: Dictionary = {
	"stops": [1, 10, 3],
	"sweep_ms": [400, 4000, 1400],
	"zone_pct": [5, 60, 20],
	"harder_pct": [0, 50, 0],
}

# A fixed zone sits in the middle of the bar.
const FIXED_ZONE_CENTRE: float = 0.5
# A moved zone keeps this clear of the bar's ends, so the marker doesn't begin a sweep inside it.
const ZONE_EDGE_MARGIN: float = 0.1

var zone_centres: Array[float] = []  # one per stop
var zone_half_widths: Array[float] = []  # one per stop

var _sweeps_ms: Array[int] = []  # one per stop


static func normalize_knobs(raw: Dictionary) -> Dictionary:
	return TurnScoreGame.normalize_shared_knobs(raw, KNOB_RANGES)


# `time_scale` is the player's assist: it slows the sweep and widens the zone by the same amount.
func _init(raw_knobs: Dictionary, rng_seed: int, time_scale: float = 1.0) -> void:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	var sweep_ms: float = int(knobs["sweep_ms"]) * time_scale
	var zone_width: float = minf(int(knobs["zone_pct"]) / 100.0 * time_scale, MAX_ZONE_WIDTH)
	turn_count = int(knobs["stops"])
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = rng_seed
	var previous: float = -1.0
	for index: int in turn_count:
		var kept_share: float = difficulty_left(index, turn_count, int(knobs["harder_pct"]))
		var half_width: float = zone_width * kept_share / 2.0
		_sweeps_ms.append(maxi(1, roundi(sweep_ms * kept_share)))
		zone_half_widths.append(half_width)
		var centre: float = FIXED_ZONE_CENTRE
		if bool(knobs["moving_zone"]):
			centre = _draw_zone_centre(rng, previous, half_width)
		zone_centres.append(centre)
		previous = centre


func _draw_zone_centre(rng: RandomNumberGenerator, previous: float, half_width: float) -> float:
	var lowest: float = half_width + ZONE_EDGE_MARGIN
	var highest: float = 1.0 - lowest
	if lowest >= highest:
		return FIXED_ZONE_CENTRE  # a zone too wide to move
	var centre: float = rng.randf_range(lowest, highest)
	for _try in ZONE_DRAW_TRIES:
		if previous < 0.0 or absf(centre - previous) >= MIN_ZONE_GAP:
			break
		centre = rng.randf_range(lowest, highest)
	return centre


# ── Input ────────────────────────────────────────────────────────────────────


# Stops the marker where it stands `sweep_elapsed_ms` into this sweep, and moves on to the next stop. Returns the
# stop's accuracy: 1.0 dead centre, falling to 0.0 at the zone's edge and beyond. -1.0 once every stop is made.
func stop(sweep_elapsed_ms: int) -> float:
	if is_finished():
		return -1.0
	var off_by: float = absf(marker_at(sweep_elapsed_ms) - current_zone_centre())
	var accuracy: float = maxf(0.0, 1.0 - off_by / current_zone_half_width())
	accuracies.append(accuracy)
	return accuracy


# ── Reading the game ─────────────────────────────────────────────────────────


# Where the marker is, `sweep_elapsed_ms` into a sweep: out from the left end, back from the right, and so on.
func marker_at(sweep_elapsed_ms: int) -> float:
	var sweep_ms: int = _sweeps_ms[current_turn()]
	var through_round_trip: int = maxi(0, sweep_elapsed_ms) % (2 * sweep_ms)
	var outward: float = float(through_round_trip) / sweep_ms
	return outward if outward <= 1.0 else 2.0 - outward


func current_zone_centre() -> float:
	return zone_centres[current_turn()]


func current_zone_half_width() -> float:
	return zone_half_widths[current_turn()]
