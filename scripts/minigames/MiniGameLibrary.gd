class_name MiniGameLibrary
extends RefCounted

# The journey-level mini-game library: each definition is set up once (which game, its knobs, its tiers)
# and referenced by id from any node or moment that uses it — "Containment Lock" styled once, used five
# times. MINIGAMES_DESIGN.md → "Reuse — a journey-level library".
#
# normalize_definition() rebuilds a definition key by key, like every other journey parser. ANY FIELD NOT
# LISTED THERE IS DROPPED on load and save — the fixed-key-list trap — so a new field must be added here.

const KINDS: Array[String] = [
	SafeCrackerGame.KIND, QuickTimeEventGame.KIND, DoubleOrNothingGame.KIND
]

# Which host each game can run on. MINIGAMES_DESIGN.md → "Placement — two hosts".
const HOST_NODE: String = "node"
const HOST_MOMENT: String = "moment"
const KIND_HOSTS: Dictionary = {
	SafeCrackerGame.KIND: [HOST_NODE],
	QuickTimeEventGame.KIND: [HOST_MOMENT],
	DoubleOrNothingGame.KIND: [HOST_NODE],
}

# Skill games score 0–100 and the author draws tiers on the score; chance games end in named outcomes,
# one tier each, and can never award journey score.
const CHANCE_KINDS: Array[String] = [DoubleOrNothingGame.KIND]

const MAX_ATTEMPTS: int = 5

# When a game with attempts left offers a retry: after any result, or only after the lowest tier.
const RETRY_ANY: String = "any"
const RETRY_LOWEST: String = "lowest"
const RETRY_RULES: Array[String] = [RETRY_ANY, RETRY_LOWEST]
const DEFAULT_RUNGS: int = 3
# The moments a game's character reacts to, per game, each with its own portrait and transition. The first
# of each list is the rest moment (GameCharacterView.REST_MOMENT).
const GAME_CHARACTER_MOMENTS: Dictionary = {
	SafeCrackerGame.KIND: ["idle", "opened", "wrong", "success", "failed"],
	DoubleOrNothingGame.KIND: ["idle", "win", "bust"],
}

# The tiers a new skill game starts with: [id, name, lowest score].
const DEFAULT_SKILL_TIERS: Array = [
	["fail", "Fail", 0], ["pass", "Pass", 40], ["perfect", "Perfect", 90]
]


static func is_chance(kind: String) -> bool:
	return kind in CHANCE_KINDS


static func new_definition(kind: String) -> Dictionary:
	return normalize_definition({"id": new_id(), "kind": kind})


static func new_id() -> String:
	return "mg_%08x" % (randi() & 0x7FFFFFFF)


static func normalize_definition(raw: Dictionary) -> Dictionary:
	var kind: String = str(raw.get("kind", ""))
	if not kind in KINDS:
		kind = SafeCrackerGame.KIND
	var definition: Dictionary = {
		"id": str(raw.get("id", "")).strip_edges(),
		"name": str(raw.get("name", "")).strip_edges(),
		"kind": kind,
		"attempts": clampi(int(raw.get("attempts", 1)), 1, MAX_ATTEMPTS),
		"retry_cost": normalize_retry_cost(raw.get("retry_cost", {})),
		"retry_when":
		(
			str(raw.get("retry_when", RETRY_ANY))
			if str(raw.get("retry_when", RETRY_ANY)) in RETRY_RULES
			else RETRY_ANY
		),
		"timeout_tier": str(raw.get("timeout_tier", "")),
	}
	# The creator's own framing. Only a game with a screen of its own has an intro and a panel to colour.
	if HOST_NODE in KIND_HOSTS[kind]:
		definition["intro_text"] = str(raw.get("intro_text", "")).strip_edges()
		definition["accent_color"] = _normalize_accent(raw.get("accent_color", ""))
	var raw_knobs: Dictionary = raw.get("knobs", {}) if raw.get("knobs") is Dictionary else {}
	match kind:
		SafeCrackerGame.KIND:
			definition["knobs"] = SafeCrackerGame.normalize_knobs(raw_knobs)
			var lock: String = str(raw.get("lock", LockArt.DEFAULT_STYLE))
			definition["lock"] = lock if lock in LockArt.STYLES else LockArt.DEFAULT_STYLE
		QuickTimeEventGame.KIND:
			definition["knobs"] = QuickTimeEventGame.normalize_knobs(raw_knobs)
		DoubleOrNothingGame.KIND:
			definition["knobs"] = {
				"odds":
				DoubleOrNothingGame.normalize_odds(
					raw_knobs.get("odds", DoubleOrNothingGame.DEFAULT_ODDS)
				)
			}
			definition["rungs"] = _normalize_rungs(raw.get("rungs", []))
			definition["bust_rewards"] = normalize_rewards(raw.get("bust_rewards", {}), false)
			definition["bust_result_text"] = str(raw.get("bust_result_text", "")).strip_edges()
	if GAME_CHARACTER_MOMENTS.has(kind):
		definition["game_character"] = _normalize_game_character(
			raw.get("game_character", {}), kind
		)
	if is_chance(kind):
		definition["tiers"] = _ladder_tiers(definition)
		# A chance game left alone cashes out what the player holds (DoubleOrNothingGame.time_out), so
		# it has no timeout tier to pick.
		definition["timeout_tier"] = ""
	else:
		var raw_tiers: Array = raw.get("tiers", []) if raw.get("tiers") is Array else []
		definition["tiers"] = _score_tiers(raw_tiers)
		for tier: Dictionary in definition["tiers"]:
			tier["rewards"] = normalize_rewards(tier["rewards"])
		if not _tier_ids(definition["tiers"]).has(definition["timeout_tier"]):
			definition["timeout_tier"] = ""  # "" = the lowest tier
	return definition


# ── Tiers ────────────────────────────────────────────────────────────────────
#
# A tier is {id, name, rewards}. A skill tier also has min_score: it is reached when the score is at
# least that, and the highest tier reached wins. `rewards` is what reaching it changes in the journey —
# see normalize_rewards.


# Sorted lowest first; the lowest tier always starts at 0, so every score lands in exactly one tier and
# there are no gaps to fall through. A tier on a score another already starts at moves up to the next
# free one, rather than vanishing along with its rewards; one that can't fit under 100 is dropped.
static func _score_tiers(raw_tiers: Array) -> Array:
	var source: Array = raw_tiers
	if source.is_empty():
		source = DEFAULT_SKILL_TIERS.map(
			func(spec: Array) -> Dictionary:
				return {"id": spec[0], "name": spec[1], "min_score": spec[2]}
		)
	var tiers: Array = []
	for raw: Variant in source:
		if raw is Dictionary:
			var tier: Dictionary = _tier_base(raw as Dictionary)
			tier["min_score"] = clampi(int((raw as Dictionary).get("min_score", 0)), 0, 100)
			tiers.append(tier)
	# Stable for equal scores, so the tier listed first keeps the score they share.
	for i in tiers.size():
		tiers[i]["_order"] = i
	tiers.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return (
				a["min_score"] < b["min_score"]
				if a["min_score"] != b["min_score"]
				else a["_order"] < b["_order"]
			)
	)
	var kept: Array = []
	for tier: Dictionary in tiers:
		tier.erase("_order")
		if not kept.is_empty() and tier["min_score"] <= kept[-1]["min_score"]:
			tier["min_score"] = kept[-1]["min_score"] + 1
		if tier["min_score"] <= 100:
			kept.append(tier)
	tiers = kept
	if tiers.is_empty():
		tiers.append(_tier_base({"id": "fail", "name": "Fail"}))
		tiers[0]["min_score"] = 0
	tiers[0]["min_score"] = 0
	_dedupe_ids(tiers)
	return tiers


# Double or Nothing's tiers, built from its ladder: one per way the game can end, in the order
# DoubleOrNothingGame.outcomes_for lists them. Cashing out holding rung k pays rung k's rewards; reaching
# the top rung (maxed) pays the top rung's; a bust pays bust_rewards. The rungs are the one place a
# reward is authored, so adding or removing a rung can never shift a reward onto the wrong rung.
static func _ladder_tiers(definition: Dictionary) -> Array:
	var rungs: Array = definition["rungs"]
	var tiers: Array = [
		{
			"id": DoubleOrNothingGame.OUTCOME_BUSTED,
			"name": default_outcome_name(DoubleOrNothingGame.OUTCOME_BUSTED),
			"rewards": definition["bust_rewards"],
			"result_text": definition["bust_result_text"],
		}
	]
	for outcome: String in outcome_names(DoubleOrNothingGame.KIND, definition):
		var held: int = DoubleOrNothingGame.rung_paid(outcome, rungs.size())
		if held == 0:
			continue
		var rung: Dictionary = rungs[held - 1]
		var label: String = str(rung["label"])
		(
			tiers
			. append(
				{
					"id": outcome,
					"name": label if label != "" else default_outcome_name(outcome),
					"rewards": rung["rewards"],
					"result_text": rung["result_text"],
				}
			)
		)
	return tiers


static func outcome_names(kind: String, definition: Dictionary) -> Array[String]:
	if kind == DoubleOrNothingGame.KIND:
		return DoubleOrNothingGame.outcomes_for((definition.get("rungs", []) as Array).size())
	return []


static func default_outcome_name(outcome: String) -> String:
	if outcome == DoubleOrNothingGame.OUTCOME_BUSTED:
		return "Bust"
	if outcome == DoubleOrNothingGame.OUTCOME_MAXED:
		return "Top rung"
	return "Cashed out at rung %d" % DoubleOrNothingGame.rung_paid(outcome, 0)


static func _tier_base(raw: Dictionary) -> Dictionary:
	var tier_name: String = str(raw.get("name", "")).strip_edges()
	var id: String = str(raw.get("id", "")).strip_edges()
	if id == "":
		id = tier_name.to_snake_case() if tier_name != "" else "tier"
	var rewards: Dictionary = raw.get("rewards", {}) if raw.get("rewards") is Dictionary else {}
	return {
		"id": id,
		"name": tier_name,
		"rewards": rewards,
		"result_text": str(raw.get("result_text", "")).strip_edges(),
	}


static func _dedupe_ids(tiers: Array) -> void:
	var seen: Dictionary = {}
	for tier: Dictionary in tiers:
		var id: String = tier["id"]
		var n: int = 2
		while seen.has(id):
			id = "%s_%d" % [tier["id"], n]
			n += 1
		tier["id"] = id
		seen[id] = true


static func _tier_ids(tiers: Array) -> Array:
	return tiers.map(func(tier: Dictionary) -> String: return tier["id"])


# ── Double or Nothing's ladder ───────────────────────────────────────────────


# Each rung is {label, rewards}: what cashing out while holding it pays. Trimmed to 6 rungs; a ladder
# with fewer than 2 (a new one, or a damaged file) starts over with 3. Never journey score — a chance game.
static func _normalize_rungs(raw_rungs: Variant) -> Array:
	var rungs: Array = []
	if raw_rungs is Array:
		for raw: Variant in raw_rungs:
			var src: Dictionary = raw if raw is Dictionary else {}
			(
				rungs
				. append(
					{
						"label": str(src.get("label", "")).strip_edges(),
						"result_text": str(src.get("result_text", "")).strip_edges(),
						"rewards": normalize_rewards(src.get("rewards", {}), false),
					}
				)
			)
	if rungs.size() < DoubleOrNothingGame.MIN_RUNGS:
		rungs.clear()
		for _i in DEFAULT_RUNGS:
			rungs.append({"label": "", "result_text": "", "rewards": {}})
	return rungs.slice(0, DoubleOrNothingGame.MAX_RUNGS)


# A creator's accent colour, or "" for the app's own, which follows the colour mode.
static func _normalize_accent(raw: Variant) -> String:
	var text: String = str(raw).strip_edges()
	return text if text != "" and Color.html_is_valid(text) else ""


# The colour a game's screen is drawn in.
static func accent_color(definition: Dictionary) -> Color:
	var accent: String = str(definition.get("accent_color", ""))
	return Color.html(accent) if accent != "" else UITheme.MINIGAME


# A game's optional character: {character, placement, moments: {moment: {portrait, transition}}}. Character
# and placement are ids from CAST; a blank placement or portrait means the character's first one. Moments
# are rebuilt from the game's own list, so each game always has exactly its own. No character → {}.
static func _normalize_game_character(raw: Variant, kind: String) -> Dictionary:
	var src: Dictionary = raw if raw is Dictionary else {}
	var character: String = str(src.get("character", "")).strip_edges()
	if character == "":
		return {}
	var raw_moments: Dictionary = src.get("moments", {}) if src.get("moments") is Dictionary else {}
	var moments: Dictionary = {}
	for moment: String in GAME_CHARACTER_MOMENTS[kind]:
		var entry: Dictionary = (
			raw_moments.get(moment, {}) if raw_moments.get(moment) is Dictionary else {}
		)
		var transition: String = str(entry.get("transition", GameCharacterView.DEFAULT_TRANSITION))
		if not transition in GameCharacterView.TRANSITIONS:
			transition = GameCharacterView.DEFAULT_TRANSITION
		moments[moment] = {"portrait": str(entry.get("portrait", "")), "transition": transition}
	return {
		"character": character,
		"placement": str(src.get("placement", "")).strip_edges(),
		"moments": moments,
	}


# ── Rewards and retry cost ───────────────────────────────────────────────────
#
# A tier's rewards are the rewards group rounds and storyboards already have, in the same lowercase keys
# the runtime applies a node's data with: coins (± — a negative takes coins), item (an id given),
# remove_items, set_flags, clear_flags, set_counters ({name: ±delta}), plus score for a skill game.
# Only what is set is stored, so an untouched tier saves as {}.


static func normalize_rewards(raw: Variant, allow_score: bool = true) -> Dictionary:
	var src: Dictionary = raw if raw is Dictionary else {}
	var rewards: Dictionary = {}
	var coins: int = int(src.get("coins", 0))
	if coins != 0:
		rewards["coins"] = coins
	var item: String = str(src.get("item", "")).strip_edges()
	if item != "":
		rewards["item"] = item
	_store_changes(rewards, src)
	var score: int = maxi(0, int(src.get("score", 0)))
	if allow_score and score > 0:
		rewards["score"] = score
	return rewards


# What a retry costs: the same changes minus a gift — coins spent (a positive amount), items taken,
# flags and counters changed. A player who can't pay the coins keeps the result they have.
static func normalize_retry_cost(raw: Variant) -> Dictionary:
	var src: Dictionary = raw if raw is Dictionary else {}
	var cost: Dictionary = {}
	var coins: int = maxi(0, int(src.get("coins", 0)))
	if coins > 0:
		cost["coins"] = coins
	_store_changes(cost, src)
	return cost


# The flag, counter and item-removal changes shared by rewards and the retry cost.
static func _store_changes(out: Dictionary, src: Dictionary) -> void:
	for key: String in ["remove_items", "set_flags", "clear_flags"]:
		var names: Array = JourneyData.clean_flag_list(src.get(key, []))
		if not names.is_empty():
			out[key] = names
	var counters: Dictionary = JourneyData.clean_counter_deltas(src.get("set_counters", {}))
	if not counters.is_empty():
		out["set_counters"] = counters


# ── The library ──────────────────────────────────────────────────────────────


# A journey's whole library (journey.json "MiniGames"), normalized. A definition without an id, or with
# one already taken, is dropped: nodes reference definitions by id, so two can't share one.
static func parse_library(raw: Variant) -> Array:
	var library: Array = []
	var seen: Dictionary = {}
	if not (raw is Array):
		return library
	for entry: Variant in raw:
		if not (entry is Dictionary):
			continue
		var definition: Dictionary = normalize_definition(entry as Dictionary)
		if definition["id"] == "" or seen.has(definition["id"]):
			continue
		seen[definition["id"]] = true
		library.append(definition)
	return library


# Every flag the library's games set or clear, once per use: on a tier or rung's rewards, or a retry's cost.
static func flag_names(library: Array) -> Array:
	var names: Array = []
	for change: Dictionary in _all_changes(library):
		for key: String in ["set_flags", "clear_flags"]:
			names.append_array(change.get(key, []))
	return names


# Every counter the library's games change, once per use.
static func counter_names(library: Array) -> Array:
	var names: Array = []
	for change: Dictionary in _all_changes(library):
		names.append_array((change.get("set_counters", {}) as Dictionary).keys())
	return names


static func _all_changes(library: Array) -> Array:
	var changes: Array = []
	for raw: Variant in library:
		var definition: Dictionary = raw if raw is Dictionary else {}
		changes.append(definition.get("retry_cost", {}))
		if is_chance(str(definition.get("kind", ""))):
			# Not its tiers: those are built from the rungs and repeat them.
			changes.append(definition.get("bust_rewards", {}))
			for rung: Dictionary in definition.get("rungs", []):
				changes.append(rung.get("rewards", {}))
		else:
			for tier: Dictionary in definition.get("tiers", []):
				changes.append(tier.get("rewards", {}))
	return changes


# The tiers of a skill game that no score can land in, given its knobs. A Quick-Time Event's score moves in fine
# steps, so only a Safe-Cracker's can have gaps; and a chance game's tiers are the ways it can end.
static func unreachable_tiers(definition: Dictionary) -> Array:
	if str(definition.get("kind", "")) != SafeCrackerGame.KIND:
		return []
	var scores: Dictionary = SafeCrackerGame.reachable_scores(definition["knobs"])
	var tiers: Array = definition["tiers"]
	var out: Array = []
	for i in tiers.size():
		var lowest: int = int(tiers[i]["min_score"])
		var highest: int = int(tiers[i + 1]["min_score"]) - 1 if i + 1 < tiers.size() else 100
		var reached: bool = false
		for score in range(lowest, highest + 1):
			reached = reached or scores.has(score)
		if not reached:
			out.append(tiers[i])
	return out


# Every result of a game that can change the run, as [{label, rewards}]: the tiers of a skill game; the rungs and
# the bust of a chance game, whose tiers repeat them; and the cost of a retry, when one can be offered.
static func reward_sources(definition: Dictionary) -> Array:
	var sources: Array = []
	var kind: String = str(definition.get("kind", ""))
	if is_chance(kind):
		var rungs: Array = definition.get("rungs", [])
		for index: int in rungs.size():
			sources.append(
				{"label": "Rung %d" % (index + 1), "rewards": rungs[index].get("rewards", {})}
			)
		sources.append({"label": "Bust", "rewards": definition.get("bust_rewards", {})})
	else:
		var tiers: Array = definition.get("tiers", [])
		for index: int in tiers.size():
			var name: String = str(tiers[index].get("name", "")).strip_edges()
			(
				sources
				. append(
					{
						"label": name if name != "" else "Tier %d" % (index + 1),
						"rewards": tiers[index].get("rewards", {}),
					}
				)
			)
	if HOST_NODE in KIND_HOSTS.get(kind, []) and int(definition.get("attempts", 1)) > 1:
		sources.append({"label": "Retry", "rewards": definition.get("retry_cost", {})})
	return sources


# {definition id: {name, kind}} — what a graph view needs to label mini-game nodes (GraphView.minigame_lookup).
static func name_lookup(library: Array) -> Dictionary:
	var lookup: Dictionary = {}
	for definition: Variant in library:
		if definition is Dictionary:
			lookup[str((definition as Dictionary).get("id", ""))] = {
				"name": str((definition as Dictionary).get("name", "")),
				"kind": str((definition as Dictionary).get("kind", "")),
			}
	return lookup


# Whether the player may retry after reaching `tier_id` on attempt number `attempts_used`: an attempt must
# be left, and the game's rule must allow it for this result.
static func may_retry(definition: Dictionary, tier_id: String, attempts_used: int) -> bool:
	if attempts_used >= int(definition.get("attempts", 1)):
		return false
	if str(definition.get("retry_when", RETRY_ANY)) == RETRY_LOWEST:
		var tiers: Array = definition.get("tiers", [])
		return not tiers.is_empty() and str((tiers[0] as Dictionary)["id"]) == tier_id
	return true


static func find(library: Array, game_id: String) -> Dictionary:
	for definition: Dictionary in library:
		if str(definition.get("id", "")) == game_id:
			return definition
	return {}
