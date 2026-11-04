class_name LuckWheel
extends RefCounted

# The geometry of Double or Nothing's wheel: how the WIN and BUST slices are laid out for given odds, and
# where the wheel comes to rest for a result already decided.
#
# The OUTCOME is never decided here — DoubleOrNothingGame.risk() draws it from the seeded game. The wheel
# only shows it: given "won", it picks a resting place inside a WIN slice. So the staging can be as
# dramatic as it likes without ever changing the odds or the seed's results.
#
# Positions are in TURNS: 0.0 is the top of the wheel (under the pointer), going clockwise to 1.0.

# The wheel is cut into this many WIN/BUST pairs, so the two colours alternate round it and a spin passes
# close calls on its way, instead of one big WIN half and one big BUST half.
const PAIRS: int = 6
# A resting place keeps this share of a slice clear at each edge, so it never sits on a line.
const EDGE_MARGIN: float = 0.15


# The slices for `odds_percent` (the chance a risk wins): {start, end, win} in turns, in order round the
# wheel. Each pair gives WIN its share of the pair and BUST the rest, so WIN covers exactly the odds.
static func slices(odds_percent: int) -> Array[Dictionary]:
	var win_share: float = clampf(odds_percent / 100.0, 0.0, 1.0)
	var pair_width: float = 1.0 / PAIRS
	var out: Array[Dictionary] = []
	for i in PAIRS:
		var start: float = i * pair_width
		var split: float = start + pair_width * win_share
		out.append({"start": start, "end": split, "win": true})
		out.append({"start": split, "end": start + pair_width, "win": false})
	return out


# Where the wheel rests to show `won`: a random point well inside a random slice of the right kind. The
# randomness is presentation only (which WIN slice, where in it).
static func resting_turn(
	slice_list: Array[Dictionary], won: bool, rng: RandomNumberGenerator
) -> float:
	var matching: Array = slice_list.filter(
		func(slice: Dictionary) -> bool: return bool(slice["win"]) == won
	)
	var slice: Dictionary = matching[rng.randi_range(0, matching.size() - 1)]
	var width: float = float(slice["end"]) - float(slice["start"])
	return float(slice["start"]) + width * rng.randf_range(EDGE_MARGIN, 1.0 - EDGE_MARGIN)


# Whether the point `turn` (0–1, clockwise from the top) falls in a WIN slice.
static func is_win_at(slice_list: Array[Dictionary], turn: float) -> bool:
	var t: float = fposmod(turn, 1.0)
	for slice: Dictionary in slice_list:
		if t >= float(slice["start"]) and t < float(slice["end"]):
			return bool(slice["win"])
	return false


# Which slice the point `turn` is in — the spin ticks each time this changes under the pointer.
static func slice_index_at(slice_list: Array[Dictionary], turn: float) -> int:
	var t: float = fposmod(turn, 1.0)
	for i in slice_list.size():
		if t >= float(slice_list[i]["start"]) and t < float(slice_list[i]["end"]):
			return i
	return slice_list.size() - 1
