class_name MiniGameResolver
extends RefCounted

# Turns a finished game into a tier. Knows nothing about which game produced the result.
# MINIGAMES_DESIGN.md → "Outcomes" and "Routing — settled".
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


# How good a tier is, 0 (the lowest) to 1 (the highest). Tiers are sorted lowest first. A game's only tier is 1.
static func tier_strength(tiers: Array, tier_id: String) -> float:
	for index: int in tiers.size():
		if str((tiers[index] as Dictionary)["id"]) == tier_id:
			return float(index) / (tiers.size() - 1) if tiers.size() > 1 else 1.0
	return 0.0


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


# What a tier is called, for showing the player. "" when the game has no such tier.
static func tier_name(definition: Dictionary, tier_id: String) -> String:
	for tier: Dictionary in definition.get("tiers", []):
		if str(tier["id"]) == tier_id:
			return str(tier.get("name", ""))
	return ""


# What the creator wrote for reaching a tier, or "".
static func tier_result_text(definition: Dictionary, tier_id: String) -> String:
	for tier: Dictionary in definition.get("tiers", []):
		if str(tier["id"]) == tier_id:
			return str(tier.get("result_text", ""))
	return ""


# ── Seeding ──────────────────────────────────────────────────────────────────


# The seed for one attempt at one placed game: the run's seed, where the game sits (a node id, or a
# moment's id), and the attempt number. Every attempt gets its own layout, and since a reload counts as an
# attempt, reloading can't replay a layout already seen.
static func attempt_seed(run_seed: int, place_id: String, attempt: int) -> int:
	return ("%d|%s|%d" % [run_seed, place_id, attempt]).hash()
