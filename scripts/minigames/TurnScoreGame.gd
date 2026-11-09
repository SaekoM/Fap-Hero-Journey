class_name TurnScoreGame
extends RefCounted

# What Stop the Bar and Hold & Release share: a set number of turns, each scored 0–1 for accuracy, with the game's
# score the mean of them. Pure, like the games built on it.

# From this accuracy a turn counts as dead on. Every turn dead on is a flawless game.
const DEAD_ON_ACCURACY: float = 0.9
# The widest a zone can get with the player's assist, so a turn always needs some aim.
const MAX_ZONE_WIDTH: float = 0.9
# Two zones in a row land at least this far apart when there's room, so each turn has to be judged afresh.
const MIN_ZONE_GAP: float = 0.2
const ZONE_DRAW_TRIES: int = 32

var turn_count: int = 0
var accuracies: Array[float] = []  # one per turn taken so far


# The knobs in `ranges` ({knob: [min, max, default]}) clamped, plus the switches every such game has.
static func normalize_shared_knobs(raw: Dictionary, ranges: Dictionary) -> Dictionary:
	var knobs: Dictionary = {}
	for knob: String in ranges:
		var bounds: Array = ranges[knob]
		knobs[knob] = clampi(int(raw.get(knob, bounds[2])), int(bounds[0]), int(bounds[1]))
	knobs["moving_zone"] = bool(raw.get("moving_zone", true))
	knobs["show_tiers"] = bool(raw.get("show_tiers", true))
	return knobs


# What turn `index` keeps of the game's timing and zone width: all of it on the first turn, shrinking evenly to
# `harder_pct` less on the last.
static func difficulty_left(index: int, turns: int, harder_pct: int) -> float:
	if turns <= 1:
		return 1.0
	return 1.0 - harder_pct / 100.0 * index / (turns - 1)


# The turn being played, or the last one once the game is over.
func current_turn() -> int:
	return mini(accuracies.size(), turn_count - 1)


func is_finished() -> bool:
	return accuracies.size() >= turn_count


# Whether the game is over with every turn dead on.
func is_flawless() -> bool:
	if not is_finished():
		return false
	for accuracy: float in accuracies:
		if accuracy < DEAD_ON_ACCURACY:
			return false
	return true


# 0–100: the mean accuracy over every turn, with turns not yet taken counting as misses.
func score() -> int:
	var total: float = 0.0
	for accuracy: float in accuracies:
		total += accuracy
	return roundi(100.0 * total / turn_count)
