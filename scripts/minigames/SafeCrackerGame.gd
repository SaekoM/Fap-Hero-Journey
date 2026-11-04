class_name SafeCrackerGame
extends RefCounted

# Safe-Cracker (Deduction family, node host, skill): turn a dial to find a hidden combination of 1–6
# numbers, in order. A warmth reading says how close the dial is to the number being searched for.
# Rules and scoring: MINIGAMES_DESIGN.md → "Safe-Cracker".
#
# Pure state machine: everything comes in through the constructor and the input calls, and nothing is
# read from the engine, so a seed plus a list of inputs always produces the same game and score.
# Time is passed in by the caller (advance_to) in clock milliseconds, never counted in frames.

const KIND: String = "safe_cracker"

const WARMTH_PRECISE: String = "precise"
const WARMTH_COARSE: String = "coarse"
# No meter on screen: the dial's click (and the device) are the only hints. warmth() still reads precisely,
# because the screen pitches the click with it.
const WARMTH_OFF: String = "off"

# {knob: [min, max, default]}. Strings list their allowed values instead.
const KNOB_RANGES: Dictionary = {
	"numbers": [1, 6, 3],
	"dial_size": [20, 100, 40],
	"tolerance": [0, 3, 1],
	"time_limit_s": [0, 300, 45],
	"max_wrong": [0, 20, 0],
}
const WARMTH_MODES: Array[String] = [WARMTH_PRECISE, WARMTH_COARSE, WARMTH_OFF]

# A number opened after w wrong tries earns max(MIN_CREDIT, 1 − WRONG_PENALTY·w) of its share.
const WRONG_PENALTY: float = 0.15
const MIN_CREDIT: float = 0.4

# 0 to 4 wrong tries on a number; past 4, its share is already at MIN_CREDIT.
const _WRONG_TRIES_THAT_CHANGE_CREDIT: Array[int] = [0, 1, 2, 3, 4]

# Why a finished game ended.
const END_OPENED: String = "opened"
const END_TIME: String = "time"
const END_JAMMED: String = "jammed"

var combination: Array[int] = []
var position: int = 0
var opened_count: int = 0
var wrong_tries: Array[int] = []  # per number
var end_reason: String = ""

var _dial_size: int
var _tolerance: int
var _warmth_mode: String
var _time_limit_ms: int
var _max_wrong: int


static func normalize_knobs(raw: Dictionary) -> Dictionary:
	var knobs: Dictionary = {}
	for knob: String in KNOB_RANGES:
		var bounds: Array = KNOB_RANGES[knob]
		knobs[knob] = clampi(int(raw.get(knob, bounds[2])), int(bounds[0]), int(bounds[1]))
	var warmth: String = str(raw.get("warmth", WARMTH_PRECISE))
	knobs["warmth"] = warmth if warmth in WARMTH_MODES else WARMTH_PRECISE
	return knobs


# Every score a game with these knobs can end on, as a set. The audit reads this to find tiers nobody can reach:
# scores come in steps, so a 90–99% tier on a one-number lock can never happen. Shares are counted in twentieths
# of a number (a wrong try costs 3 of 20, down to 8), so the sums stay exact.
static func reachable_scores(raw_knobs: Dictionary) -> Dictionary:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	var numbers: int = int(knobs["numbers"])
	var max_wrong: int = int(knobs["max_wrong"])
	# Without a time limit or a wrong-try limit, a game can only end with every number open.
	var can_stop_early: bool = int(knobs["time_limit_s"]) > 0 or max_wrong > 0
	var scores: Dictionary = {}
	var states: Dictionary = {Vector2i.ZERO: true}  # (credit so far, wrong tries so far)
	for opened in numbers + 1:
		var next_states: Dictionary = {}
		for state: Vector2i in states:
			if opened == numbers or can_stop_early:
				scores[roundi(100.0 * state.x / (20.0 * numbers))] = true
			for wrong in _WRONG_TRIES_THAT_CHANGE_CREDIT:
				var wrong_total: int = state.y + wrong
				# Reaching the limit jams the dial before this number could open.
				if max_wrong == 0 or wrong_total < max_wrong:
					var credit: int = 20 - 3 * wrong
					next_states[Vector2i(state.x + credit, wrong_total)] = true
		states = next_states
	return scores


# `time_scale` stretches the time limit, for the player's assist. Everything else stays as the author set it.
func _init(raw_knobs: Dictionary, rng_seed: int, time_scale: float = 1.0) -> void:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	_dial_size = int(knobs["dial_size"])
	_tolerance = int(knobs["tolerance"])
	_warmth_mode = str(knobs["warmth"])
	_time_limit_ms = roundi(int(knobs["time_limit_s"]) * 1000 * time_scale)
	_max_wrong = int(knobs["max_wrong"])
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = rng_seed
	combination = _draw_combination(int(knobs["numbers"]), rng)
	for _i in combination.size():
		wrong_tries.append(0)


# Each number sits a real turn away from where the search for it starts (the dial's rest position, or
# the previous number), so no number can be opened by trying without turning.
func _draw_combination(count: int, rng: RandomNumberGenerator) -> Array[int]:
	var min_gap: int = maxi(_tolerance * 2 + 2, floori(_dial_size / 5.0))
	var numbers: Array[int] = []
	var from: int = 0
	for _i in count:
		var offset: int = rng.randi_range(min_gap, _dial_size - min_gap)
		var number: int = posmod(from + offset, _dial_size)
		numbers.append(number)
		from = number
	return numbers


# ── Input ────────────────────────────────────────────────────────────────────


func turn(steps: int) -> void:
	if not is_finished():
		position = posmod(position + steps, _dial_size)


func set_position(value: int) -> void:
	if not is_finished():
		position = posmod(value, _dial_size)


# Tries the number under the dial. Returns true when it opened the number being searched for.
func try_open() -> bool:
	if is_finished():
		return false
	if distance_to_target() <= _tolerance:
		opened_count += 1
		if opened_count == combination.size():
			end_reason = END_OPENED
		return true
	wrong_tries[opened_count] += 1
	if _max_wrong > 0 and total_wrong_tries() >= _max_wrong:
		end_reason = END_JAMMED
	return false


# Moves the game clock to `elapsed_ms` since the game began; ends it when the time limit passes.
func advance_to(elapsed_ms: int) -> void:
	if not is_finished() and _time_limit_ms > 0 and elapsed_ms >= _time_limit_ms:
		end_reason = END_TIME


# ── Reading the game ─────────────────────────────────────────────────────────


func is_finished() -> bool:
	return end_reason != ""


func total_wrong_tries() -> int:
	var total: int = 0
	for count: int in wrong_tries:
		total += count
	return total


# Steps between the dial and the number being searched for, the short way round. 0 once all are open.
func distance_to_target() -> int:
	if opened_count >= combination.size():
		return 0
	var gap: int = absi(position - combination[opened_count])
	return mini(gap, _dial_size - gap)


# How close the dial is, 0 (as far as it can be) to 1 (on the number). In coarse mode it snaps to three
# bands — cold 0, warm 0.5, hot 1 — so the reading is a hint rather than a homing beacon.
func warmth() -> float:
	var distance: int = distance_to_target()
	if _warmth_mode == WARMTH_COARSE:
		if distance <= _tolerance + 1:
			return 1.0
		if distance <= floori(_dial_size / 6.0):
			return 0.5
		return 0.0
	return 1.0 - float(distance) / floorf(_dial_size / 2.0)


# 0–100. Each number is an equal share, reduced by the wrong tries spent on it; unopened numbers earn 0.
func score() -> int:
	var credit: float = 0.0
	for i in opened_count:
		credit += maxf(MIN_CREDIT, 1.0 - WRONG_PENALTY * wrong_tries[i])
	return roundi(100.0 * credit / combination.size())
