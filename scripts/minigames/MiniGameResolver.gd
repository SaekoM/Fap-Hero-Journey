class_name MiniGameResolver
extends RefCounted

# Turns a finished game into a tier, and a tier into the flags that route on it. Knows nothing about
# which game produced the result. MINIGAMES_DESIGN.md → "Outcomes" and "Routing — settled".
#
# Pure: the caller supplies the definition, the result and the run seed.


# The tier a skill score reaches: the highest tier whose lowest score is at or below it. Tiers come
# from MiniGameLibrary, sorted lowest first with the first starting at 0, so there is always one.
static func tier_for_score(tiers: Array, score: int) -> String:
	var reached: String = ""
	for tier: Dictionary in tiers:
		if score >= int(tier.get("min_score", 0)):
			reached = str(tier["id"])
	return reached


# A chance game's tier is its named outcome. "" when the outcome has no tier (an unknown outcome name).
static func tier_for_outcome(tiers: Array, outcome: String) -> String:
	for tier: Dictionary in tiers:
		if str(tier["id"]) == outcome:
			return outcome
	return ""


# The tier a timed-out node resolves to: the author's pick, or the lowest tier.
static func timeout_tier(definition: Dictionary) -> String:
	var picked: String = str(definition.get("timeout_tier", ""))
	if picked != "":
		return picked
	var tiers: Array = definition.get("tiers", [])
	return str((tiers[0] as Dictionary)["id"]) if not tiers.is_empty() else ""


# ── Routing flags ────────────────────────────────────────────────────────────


# Each tier of each game has its own flag, namespaced by the game so two games' "pass" never collide.
static func tier_flag(game_id: String, tier_id: String) -> String:
	return "%s_%s" % [game_id, tier_id]


# Resolving sets ONLY the tier reached and clears every other tier's flag, so a game played a second time
# in a run (a loop) can never route on a stale result from the first time.
static func flag_changes(definition: Dictionary, reached_tier: String) -> Dictionary:
	var game_id: String = str(definition.get("id", ""))
	var to_set: Array[String] = []
	var to_clear: Array[String] = []
	for tier: Dictionary in definition.get("tiers", []):
		var flag: String = tier_flag(game_id, str(tier["id"]))
		if str(tier["id"]) == reached_tier:
			to_set.append(flag)
		else:
			to_clear.append(flag)
	return {"set": to_set, "clear": to_clear}


# ── Seeding ──────────────────────────────────────────────────────────────────


# The seed for one attempt at one placed game: the run's seed, where the game sits (a node id, or a
# moment's id), and the attempt number. Every attempt gets its own layout, and since a reload counts as an
# attempt, reloading can't replay a layout already seen.
static func attempt_seed(run_seed: int, place_id: String, attempt: int) -> int:
	return ("%d|%s|%d" % [run_seed, place_id, attempt]).hash()
