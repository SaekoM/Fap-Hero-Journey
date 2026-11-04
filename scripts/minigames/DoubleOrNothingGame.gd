class_name DoubleOrNothingGame
extends RefCounted

# Double or Nothing (Risk & Reward family, node host, chance): the player holds rung 1 of the author's
# reward ladder and chooses each time to CASH OUT or RISK IT — a win climbs a rung, a loss busts.
# Rules: MINIGAMES_DESIGN.md → "Double or Nothing".
#
# A chance family reports a NAMED OUTCOME, never a score, so luck can't reach a leaderboard.
# Pure state machine: every flip draws from the seeded generator, so a seed plus the same choices always
# ends the same way, and a reload (a new attempt, a new seed) can't replay a known flip.

const KIND: String = "double_or_nothing"

const MIN_RUNGS: int = 2
const MAX_RUNGS: int = 6
const ODDS_RANGE: Array[int] = [10, 90]
const DEFAULT_ODDS: int = 50

const OUTCOME_BUSTED: String = "busted"
const OUTCOME_MAXED: String = "maxed"
const CASHED_PREFIX: String = "cashed_"

var rung: int = 1  # the rung the player holds, 1-based
var outcome: String = ""

var _rung_count: int
var _odds: float
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


static func normalize_odds(raw: Variant) -> int:
	return clampi(int(raw), ODDS_RANGE[0], ODDS_RANGE[1])


# Every outcome a ladder of `rung_count` rungs can end in, lowest first: busted, cashed out holding
# rung 1 … rung_count − 1, then maxed (holding the top rung always cashes out by itself).
static func outcomes_for(rung_count: int) -> Array[String]:
	var names: Array[String] = [OUTCOME_BUSTED]
	for held in range(1, clampi(rung_count, MIN_RUNGS, MAX_RUNGS)):
		names.append(CASHED_PREFIX + str(held))
	names.append(OUTCOME_MAXED)
	return names


# The rung an outcome pays out (1-based), or 0 for a bust.
static func rung_paid(outcome_name: String, rung_count: int) -> int:
	if outcome_name == OUTCOME_MAXED:
		return clampi(rung_count, MIN_RUNGS, MAX_RUNGS)
	if outcome_name.begins_with(CASHED_PREFIX):
		return int(outcome_name.trim_prefix(CASHED_PREFIX))
	return 0


func _init(rung_count: int, odds_percent: int, rng_seed: int) -> void:
	_rung_count = clampi(rung_count, MIN_RUNGS, MAX_RUNGS)
	_odds = normalize_odds(odds_percent) / 100.0
	_rng.seed = rng_seed


# ── Input ────────────────────────────────────────────────────────────────────


# One flip. Returns true on a win (climbed a rung), false on a bust. Climbing onto the top rung ends the
# game as maxed.
func risk() -> bool:
	if is_finished():
		return false
	if _rng.randf() >= _odds:
		outcome = OUTCOME_BUSTED
		return false
	rung += 1
	if rung == _rung_count:
		outcome = OUTCOME_MAXED
	return true


func cash_out() -> void:
	if not is_finished():
		outcome = CASHED_PREFIX + str(rung)


# Auto-advance ran out with no choice made: the player keeps the rung they hold.
func time_out() -> void:
	cash_out()


# ── Reading the game ─────────────────────────────────────────────────────────


func is_finished() -> bool:
	return outcome != ""


func rung_count() -> int:
	return _rung_count
