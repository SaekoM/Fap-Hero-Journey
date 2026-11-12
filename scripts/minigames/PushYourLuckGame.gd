class_name PushYourLuckGame
extends RefCounted

# Push Your Luck (Risk & Reward family, node host, chance): the player starts with a small pot and chooses each time
# to BANK it or PUSH, which draws a token from a bag whose contents are always on show. Value tokens add to the pot,
# a shield saves the player from one trap, a doubler doubles the pot, and a trap busts. Drawn tokens stay out, so the
# odds follow from what's left and can be reasoned about. Rules: MINIGAMES_DESIGN.md → "Push Your Luck".
#
# A chance family reports a named outcome, never a score, so luck can't reach a leaderboard. Pure state machine: the
# bag's order and every value come from the seeded generator, so a seed plus the same choices always ends the same way.

const KIND: String = "push_your_luck"

# {knob: [min, max, default]}. The tokens that add to the stack can't total more than a full stack holds.
const KNOB_RANGES: Dictionary = {
	"value_tokens": [2, 10, 8],
	"traps": [1, 10, 3],
	"shields": [0, 3, 1],
	"doublers": [0, 2, 1],
	"base_gain": [1, 500, 10],
	"gain_growth": [0, 500, 5],
}

const TOKEN_VALUE: String = "value"
const TOKEN_TRAP: String = "trap"
const TOKEN_SHIELD: String = "shield"
const TOKEN_DOUBLER: String = "doubler"
# Which knob says how many of each token go in the bag.
const TOKEN_KNOBS: Dictionary = {
	TOKEN_VALUE: "value_tokens",
	TOKEN_TRAP: "traps",
	TOKEN_SHIELD: "shields",
	TOKEN_DOUBLER: "doublers",
}

# A value lands this far either side of the average for its draw.
const GAIN_SPREAD: float = 0.5
# Surviving a push at this risk or above is a close call.
const CLOSE_CALL_RISK_PCT: int = 50
# A value in this top share of its range is a big draw.
const BIG_DRAW_SHARE: float = 0.75

const OUTCOME_BUSTED: String = "busted"
# The most a pot can hold, and the highest a tier can start.
const MAX_POT: int = 99999

var pot: int = 0
var pushes: int = 0  # how many have survived
var shields_held: int = 0
var busted: bool = false
var banked: bool = false
var last_token: String = ""  # what the last push drew
var last_gain: int = 0  # what the last push added, 0 if it wasn't a value token
var last_risk_pct: int = 0  # what the last push risked

var _bag: Array[String] = []  # undrawn, in the order they'll come out
var _values_drawn: int = 0
var _last_gain_range: Vector2i = Vector2i.ZERO
var _knobs: Dictionary
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


static func normalize_knobs(raw: Dictionary) -> Dictionary:
	var knobs: Dictionary = {}
	for knob: String in KNOB_RANGES:
		var bounds: Array = KNOB_RANGES[knob]
		knobs[knob] = clampi(int(raw.get(knob, bounds[2])), int(bounds[0]), int(bounds[1]))
	return knobs


# The average of value number `draw`, where 0 is the pot the game starts with.
static func average_gain(knobs: Dictionary, draw: int) -> float:
	return float(int(knobs["base_gain"]) + int(knobs["gain_growth"]) * draw)


# What the starting pot and `value_tokens` value tokens typically add up to, before any doubling.
static func typical_pot(raw_knobs: Dictionary, value_tokens: int) -> int:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	var total: float = 0.0
	for draw: int in value_tokens + 1:
		total += average_gain(knobs, draw)
	return roundi(total)


# The most any run can hold: the top of every value's range, doubled by every doubler after them all.
static func highest_pot(raw_knobs: Dictionary) -> int:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	var total: int = 0
	for draw: int in int(knobs["value_tokens"]) + 1:
		total += roundi(average_gain(knobs, draw) * (1.0 + GAIN_SPREAD))
	return mini(total * int(pow(2.0, int(knobs["doublers"]))), MAX_POT)


# The tier a pot reaches: the highest whose lowest pot is at or below it. Only pot tiers have a lowest pot, so a
# bust's tier is never picked.
static func tier_for_pot(tiers: Array, held: int) -> String:
	var reached: String = ""
	for tier: Dictionary in tiers:
		if tier.has("min_pot") and held >= int(tier["min_pot"]):
			reached = str(tier["id"])
	return reached


func _init(raw_knobs: Dictionary, rng_seed: int) -> void:
	_knobs = normalize_knobs(raw_knobs)
	_rng.seed = rng_seed
	pot = _draw_value()  # the player starts with something to lose, and a choice from the first moment
	_fill_bag()


func _fill_bag() -> void:
	for token: String in TOKEN_KNOBS:
		for _count in int(_knobs[TOKEN_KNOBS[token]]):
			_bag.append(token)
	# Shuffled by hand so the order comes from this game's own seeded generator, not the global one.
	for index: int in range(_bag.size() - 1, 0, -1):
		var other: int = _rng.randi_range(0, index)
		var held: String = _bag[index]
		_bag[index] = _bag[other]
		_bag[other] = held


func _draw_value() -> int:
	_last_gain_range = _gain_range(_values_drawn)
	_values_drawn += 1
	return _rng.randi_range(_last_gain_range.x, _last_gain_range.y)


func _gain_range(draw: int) -> Vector2i:
	var average: float = average_gain(_knobs, draw)
	return Vector2i(
		maxi(1, roundi(average * (1.0 - GAIN_SPREAD))), roundi(average * (1.0 + GAIN_SPREAD))
	)


# ── Input ────────────────────────────────────────────────────────────────────


# One push: draws the next token from the bag. Returns whether the player survived it. Once only traps are left, the
# game banks by itself, because no push could gain anything.
func push() -> bool:
	if is_finished():
		return false
	last_risk_pct = risk_pct()
	last_token = str(_bag.pop_back())
	last_gain = 0
	match last_token:
		TOKEN_TRAP:
			if shields_held <= 0:
				busted = true
				return false
			shields_held -= 1
		TOKEN_SHIELD:
			shields_held += 1
		TOKEN_DOUBLER:
			pot = mini(pot * 2, MAX_POT)
		TOKEN_VALUE:
			last_gain = _draw_value()
			pot = mini(pot + last_gain, MAX_POT)
	pushes += 1
	if is_bag_cleared():
		banked = true
	return true


func bank() -> void:
	if not is_finished():
		banked = true


# ── Reading the game ─────────────────────────────────────────────────────────


# How many of `token` are still in the bag.
func tokens_left(token: String) -> int:
	return _bag.count(token)


func total_tokens_left() -> int:
	return _bag.size()


# How many of `token` the bag started with.
func tokens_at_start(token: String) -> int:
	return int(_knobs[TOKEN_KNOBS[token]])


# How many pieces a push could add to the stack, at most: everything in the bag but its traps.
func safe_tokens_at_start() -> int:
	return (
		tokens_at_start(TOKEN_VALUE)
		+ tokens_at_start(TOKEN_SHIELD)
		+ tokens_at_start(TOKEN_DOUBLER)
	)


# The chance the next push busts, in percent. It comes straight from the bag, and is nothing with a shield held.
func risk_pct() -> int:
	if shields_held > 0 or _bag.is_empty():
		return 0
	return roundi(100.0 * tokens_left(TOKEN_TRAP) / _bag.size())


# What the next value token could add, as (lowest, highest).
func next_gain_range() -> Vector2i:
	return _gain_range(_values_drawn)


# Whether the last push's value was near the top of what it could have been.
func was_big_draw() -> bool:
	if last_gain <= 0 or _last_gain_range.y <= _last_gain_range.x:
		return false
	var share: float = inverse_lerp(
		float(_last_gain_range.x), float(_last_gain_range.y), float(last_gain)
	)
	return share >= BIG_DRAW_SHARE


# Whether the last push survived a risk that could easily have gone the other way.
func was_close_call() -> bool:
	return not busted and pushes > 0 and last_risk_pct >= CLOSE_CALL_RISK_PCT


# Whether everything worth drawing has been drawn.
func is_bag_cleared() -> bool:
	return tokens_left(TOKEN_TRAP) == _bag.size()


func is_finished() -> bool:
	return busted or banked


# The tier this game has ended on, from the definition's tiers.
func final_tier_id(tiers: Array) -> String:
	return OUTCOME_BUSTED if busted else tier_for_pot(tiers, pot)
