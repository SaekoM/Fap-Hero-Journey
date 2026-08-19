class_name RandomizerGenerator
extends RefCounted
## Pure, seeded journey generator for the randomizer. Given a library of clip
## entries + settings, it produces a complete Format-2 journey dict (ready to
## write as journey.json) plus the list of pooled content rels the run folder must
## contain. Deterministic for a fixed seed, so a run is reproducible and the whole
## thing is unit-testable headless (no disk, no UI). Mirrors the pure-logic pattern
## of ForkResolver / DeviceRouting / JourneyAudit.
##
## Consumes library entries of the shape:
##   { id, name, video_rel, funscript_rel, axis_rel:{}, vib_rel:{}, boss_image_rel,
##     action_count:int, length_ms:int, duration_ms:int,
##     tags:[String], weight:float, intensity:int(1-5), last_used:int(unix) }
## where *_rel are pooled paths RELATIVE to the run folder ("content/m_<fp>.<ext>").
## The launcher hardlinks/copies each returned content rel into the run's content/.

# Settings keys (all optional; defaults below) —
#   seed:int (0 → time-seeded)          length_mode:"count"|"time"
#   round_count:int                     target_minutes:float
#   tags_include:[String]               tags_exclude:[String]
#   intensity_order:bool (build-up)     effect_pct:float 0..1
#   boss_finale:bool                    shop_every:int (0=off)
#   coins_per_round:int
#   freshness_halflife_hours:float (0=off)   now_unix:int (injectable)
#   name:String   author:String   difficulty:String

const DEFAULT_SETTINGS: Dictionary = {
	"seed": 0,
	"length_mode": "count",
	"round_count": 10,
	"target_minutes": 20.0,
	"tags_include": [],
	"tags_exclude": [],
	"intensity_order": false,
	"effect_pct": 0.0,
	"boss_finale": false,
	"shop_every": 0,
	# On: a run never plays two clips cut from the same source video (one part per video).
	"unique_sources": false,
	# Off: vibrator-only clips (a vibration script, no stroke) are excluded — a stroker device would
	# feel them as dead rounds. On (default) lets them into runs alongside stroke clips.
	"include_vib_only": true,
	"coins_per_round": 10,
	"freshness_halflife_hours": 0.0,
	"now_unix": 0,
	"name": "Random Run",
	"author": "Randomizer",
	"difficulty": "Medium",
}

# Weight floor so a just-used clip is deprioritized but never fully excluded.
const FRESHNESS_FLOOR: float = 0.1

# Target coin balance the player should have by each generated shop — enough for
# ~2 typical modifier items (shop_items.json modifiers cluster at 20–50). Drives
# the per-round coin payout when shops are enabled.
const SHOP_BUDGET_TARGET: int = 75


# Produces a run. Returns:
#   { ok:bool, reason:String,
#     journey:Dictionary,        # the full journey.json dict (empty when not ok)
#     content_rels:Array,        # pooled rels the run folder must contain
#     summary:{rounds, effects, bosses, shops, est_length_ms, seed} }
# reason is "" on success, else "empty_library" / "no_matches".
static func generate(entries: Array, settings: Dictionary = {}) -> Dictionary:
	var cfg: Dictionary = DEFAULT_SETTINGS.duplicate(true)
	cfg.merge(settings, true)

	var seed_val: int = int(cfg["seed"])
	if seed_val == 0:
		seed_val = int(Time.get_unix_time_from_system()) ^ (randi() | 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	if entries.is_empty():
		return _fail("empty_library", seed_val)

	var now: int = int(cfg["now_unix"])
	if now == 0:
		now = int(Time.get_unix_time_from_system())

	var pool: Array = _filter(entries, cfg)
	if pool.is_empty():
		return _fail("no_matches", seed_val)

	# Weighted-random permutation of the whole filtered pool (no-repeat by
	# construction). Both length modes draw the front of this ordering.
	var ordered: Array = _weighted_order(pool, cfg, now, rng)
	if bool(cfg["unique_sources"]):
		ordered = _one_per_source(ordered)
	var chosen: Array = _take_by_length(ordered, cfg)
	if cfg["intensity_order"]:
		# Build-up: play mild → intense. Stable sort keeps the weighted order as the
		# tie-break within an intensity band.
		chosen = _stable_sort_by_intensity(chosen)

	# ── Assemble the node sequence (rounds + interleaved shops) ──────────────
	var seq: Array = []  # ordered [{type, data}]
	var summary: Dictionary = {
		"rounds": 0,
		"effects": 0,
		"bosses": 0,
		"shops": 0,
		"est_length_ms": 0,
		"seed": seed_val,
	}
	var last_idx: int = chosen.size() - 1
	var shop_every: int = int(cfg["shop_every"])
	# When shops are generated, per-round coins must accumulate to something
	# spendable by each shop, or the shop is dead weight. Scale up so the player has
	# ~SHOP_BUDGET_TARGET coins by every shop (shop appears every `shop_every`
	# rounds); never below the base setting.
	var coins_per_round: int = int(cfg["coins_per_round"])
	if shop_every > 0:
		coins_per_round = maxi(
			coins_per_round, ceili(float(SHOP_BUDGET_TARGET) / float(shop_every))
		)
	summary["coins_per_round"] = coins_per_round

	for i: int in chosen.size():
		var entry: Dictionary = chosen[i]

		var round_type: String = "normal"
		if bool(cfg["boss_finale"]) and i == last_idx:
			round_type = "boss"
		elif rng.randf() < float(cfg["effect_pct"]):
			round_type = "effect"

		(
			seq
			. append(
				{
					"type": "round",
					"data": _round_data(entry, round_type, coins_per_round, rng),
				}
			)
		)

		summary["rounds"] += 1
		if round_type == "effect":
			summary["effects"] += 1
		elif round_type == "boss":
			summary["bosses"] += 1
		summary["est_length_ms"] += _entry_length_ms(entry)

		# Insert a shop after every Nth round (never trailing the final round).
		if shop_every > 0 and (i + 1) % shop_every == 0 and i != last_idx:
			seq.append({"type": "shop", "data": _shop_data()})
			summary["shops"] += 1

	var used_ids: Array = []
	for e: Dictionary in chosen:
		used_ids.append(str(e.get("id", "")))

	# ── Ids, edges, positions → graph ───────────────────────────────────────
	var graph: Dictionary = _wire_linear(seq, rng)

	var meta: Dictionary = {
		# Seed baked into the Name so it's a stable identity both the preview's Keep
		# and the end-screen's Save read straight off the journey (matching names).
		"Name": "%s · seed %d" % [str(cfg["name"]), seed_val],
		"Author": str(cfg["author"]),
		"Description": "Generated by the randomizer (seed %d)." % seed_val,
		"Difficulty": str(cfg["difficulty"]),
		"Tags": [],
		"MapEnabled": true,
		"MapFog": false,
		"MapFogReveal": 1,
	}
	var journey: Dictionary = meta.duplicate(true)
	journey.merge(JourneyGraph.to_json(graph))  # adds Format / Start / Nodes
	journey["Comments"] = []
	journey["Groups"] = []

	return {
		"ok": true,
		"reason": "",
		"journey": journey,
		"content_rels": _collect_content_rels(graph),
		"used_ids": used_ids,
		"summary": summary,
	}


# ── Selection ────────────────────────────────────────────────────────────────


# Keeps entries matching the tag filter. include empty → all pass; else an entry
# must share ≥1 tag with include. exclude drops any entry sharing ≥1 excluded tag.
static func _filter(entries: Array, cfg: Dictionary) -> Array:
	var inc: Array = cfg["tags_include"]
	var exc: Array = cfg["tags_exclude"]
	var include_vib_only: bool = bool(cfg["include_vib_only"])
	var out: Array = []
	for e: Dictionary in entries:
		if not include_vib_only and bool(e.get("vib_only", false)):
			continue
		var tags: Array = e.get("tags", [])
		if not inc.is_empty() and not _shares_tag(tags, inc):
			continue
		if not exc.is_empty() and _shares_tag(tags, exc):
			continue
		out.append(e)
	return out


static func _shares_tag(a: Array, b: Array) -> bool:
	for t: Variant in a:
		if t in b:
			return true
	return false


# Weighted-random permutation without replacement. Effective weight folds in the
# per-clip spawn weight and the cross-run freshness decay (recently-used clips are
# down-weighted, floored so they can still appear).
static func _weighted_order(
	pool: Array, cfg: Dictionary, now: int, rng: RandomNumberGenerator
) -> Array:
	var items: Array = []  # [{entry, w}]
	var halflife: float = float(cfg["freshness_halflife_hours"])
	for e: Dictionary in pool:
		var w: float = maxf(0.0001, float(e.get("weight", 1.0))) * _freshness(e, now, halflife)
		items.append({"entry": e, "w": w})

	var order: Array = []
	while not items.is_empty():
		var total: float = 0.0
		for it: Dictionary in items:
			total += it["w"]
		var roll: float = rng.randf() * total
		var pick: int = items.size() - 1
		var acc: float = 0.0
		for idx: int in items.size():
			acc += items[idx]["w"]
			if roll <= acc:
				pick = idx
				break
		order.append(items[pick]["entry"])
		items.remove_at(pick)
	return order


# Keeps only the FIRST clip from each source video, preserving the weighted order — so a run
# never plays two clips from the same video. The winner of the weighted draw is already at the
# front, so this respects weight/freshness.
static func _one_per_source(ordered: Array) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for e: Dictionary in ordered:
		var key: String = _source_key(e)
		if seen.has(key):
			continue
		seen[key] = true
		out.append(e)
	return out


# Identity for "the same video". The video FILE NAME, deliberately NOT the media fingerprint:
# JourneyData.media_fingerprint keys on the absolute PATH, so the same video imported from two
# folders (easy to do in a big folder import) becomes two entries with two different ids/source_ids
# and would slip past a fingerprint-based cap. The filename catches that. All parts of one video
# share its video_src, so cutting is handled by the same key. Falls back to source_id/id when a
# source path is missing. Trade-off: two genuinely different videos that share a filename count as
# one here — acceptable for a "one clip per video" convenience.
static func _source_key(e: Dictionary) -> String:
	var src: String = str(e.get("video_src", ""))
	if src != "":
		return src.get_file().to_lower()
	return str(e.get("source_id", e.get("id", "")))


# 1.0 for a never-used clip; drops toward FRESHNESS_FLOOR the more recently it was
# used, recovering to ~1 after several half-lives. Off (1.0) when halflife<=0.
static func _freshness(entry: Dictionary, now: int, halflife_hours: float) -> float:
	if halflife_hours <= 0.0:
		return 1.0
	var last: int = int(entry.get("last_used", 0))
	if last <= 0:
		return 1.0
	var age_hours: float = maxf(0.0, float(now - last) / 3600.0)
	var factor: float = 1.0 - pow(2.0, -age_hours / halflife_hours)
	return maxf(FRESHNESS_FLOOR, factor)


# Draws the front of the weighted ordering per the length mode. count → first N.
# time → FIRST-FIT over the weighted order: add every clip that still fits the
# budget and SKIP (don't stop on) ones too large, so the total never overshoots and
# one early big clip can't truncate the run. Only when nothing fits at all is a
# single clip forced (a 0-round run is useless). Whole-video rounds can't be
# trimmed, so the packed total lands at or just under the target — approximate by
# design, but never wildly over/under.
static func _take_by_length(ordered: Array, cfg: Dictionary) -> Array:
	if str(cfg["length_mode"]) == "time":
		var budget_ms: int = int(round(float(cfg["target_minutes"]) * 60000.0))
		var out: Array = []
		var acc: int = 0
		for e: Dictionary in ordered:
			var dur: int = _entry_length_ms(e)
			if acc + dur <= budget_ms:
				out.append(e)
				acc += dur
		if out.is_empty() and not ordered.is_empty():
			out.append(ordered[0])  # nothing fit — every clip exceeds the budget
		return out
	var n: int = mini(int(cfg["round_count"]), ordered.size())
	return ordered.slice(0, maxi(0, n))


# Round length for the time budget / summary: the video duration, falling back to
# the funscript length when the clip's duration wasn't probed.
static func _entry_length_ms(entry: Dictionary) -> int:
	var dur: int = int(entry.get("duration_ms", 0))
	return dur if dur > 0 else int(entry.get("length_ms", 0))


static func _stable_sort_by_intensity(chosen: Array) -> Array:
	var indexed: Array = []
	for i: int in chosen.size():
		indexed.append({"e": chosen[i], "i": i})
	indexed.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var ia: int = int((a["e"] as Dictionary).get("intensity", 3))
			var ib: int = int((b["e"] as Dictionary).get("intensity", 3))
			if ia != ib:
				return ia < ib
			return int(a["i"]) < int(b["i"])  # stable tie-break
	)
	var out: Array = []
	for it: Dictionary in indexed:
		out.append(it["e"])
	return out


# ── Node builders ────────────────────────────────────────────────────────────


# Builds a round node's data, stamped through the canonical coercion so effect /
# boss fields match an editor-saved round exactly. Media fields carry the pooled
# rels (kept by coerce). An effect round is seeded with the FULL gameplay-effect
# pool + effect_random, so the runtime rolls a random effect each time — an empty
# effects[] would be a pure-visual round with NO gameplay effect (see GameLoop
# `_enter_effect_mode`). A boss round bakes rolled forced modifiers (boss modifiers
# are author-fixed, applied directly — not rolled at runtime — so they're rolled
# here, deterministic per seed); an empty list would be a boss with no effect.
static func _round_data(
	entry: Dictionary, round_type: String, coins: int, rng: RandomNumberGenerator
) -> Dictionary:
	var effects: Array = _all_gameplay_effect_names() if round_type == "effect" else []
	var data: Dictionary = {
		"name": str(entry.get("name", "Round")),
		"video_path": str(entry.get("video_rel", "")),
		"funscript_path": str(entry.get("funscript_rel", "")),
		"axis_scripts": (entry.get("axis_rel", {}) as Dictionary).duplicate(true),
		"vib_scripts": (entry.get("vib_rel", {}) as Dictionary).duplicate(true),
		"action_count": int(entry.get("action_count", 0)),
		"length_ms": int(entry.get("length_ms", 0)),
		"boss_image": str(entry.get("boss_image_rel", "")),
		"coins": coins,
		"round_type": round_type,
		"effects": effects,
		"effect_random": true,
		"boss_modifiers": _boss_modifiers(rng) if round_type == "boss" else [],
	}
	return JourneyData.coerce_node_save_data("round", data)


# Every gameplay (hindrance + boon) effect name from the catalog — the pool a
# generated effect round rolls from.
static func _all_gameplay_effect_names() -> Array:
	var names: Array = []
	for e: Dictionary in JourneyData.gameplay_effects():
		names.append(str(e.get("name", "")))
	return names


# Forced modifiers for a boss round: always a 2× score reward (the boss payoff),
# plus one rolled stroke challenge (bigger strokes / a clamped half / inversion).
# Shapes match the builder's boss-modifier authoring (BOSS_MODIFIER_KINDS).
static func _boss_modifiers(rng: RandomNumberGenerator) -> Array:
	var mods: Array = [{"kind": "score_multiplier", "factor": 2.0}]
	match rng.randi() % 3:
		0:
			mods.append({"kind": "scale", "factor": 1.3})
		1:
			var top: bool = rng.randf() < 0.5
			mods.append({"kind": "clamp", "min": 50 if top else 0, "max": 100 if top else 50})
		_:
			mods.append({"kind": "reverse"})
	return mods


static func _shop_data() -> Dictionary:
	# A default pooled shop: a few random draws from the item registry. No
	# guaranteed items — the generator has no authored intent to enforce.
	return (
		JourneyData
		. coerce_node_save_data(
			"shop",
			{
				"title": "Shop",
				"mode": "pool",
				"count": 3,
				"price_multiplier": 1.0,
				"items": [],
				"guaranteed": [],
			}
		)
	)


# ── Graph wiring ─────────────────────────────────────────────────────────────


# Assigns deterministic ids + a left-to-right layout and threads a single forward
# edge through the sequence (last node ends the run). Returns {start, nodes}.
static func _wire_linear(seq: Array, rng: RandomNumberGenerator) -> Dictionary:
	var ids: Array = []
	for _i in seq.size():
		ids.append(_mint_id(rng))
	var nodes: Dictionary = {}
	for i: int in seq.size():
		var item: Dictionary = seq[i]
		var out_edges: Array = []
		if i + 1 < seq.size():
			out_edges = [{"to": ids[i + 1]}]
		nodes[ids[i]] = {
			"type": str(item["type"]),
			"data": item["data"],
			"out": out_edges,
			"pos": Vector2(i * 240, 200),
		}
	return {"start": ids[0] if not ids.is_empty() else "", "nodes": nodes}


static func _mint_id(rng: RandomNumberGenerator) -> String:
	return "n_%08x%08x" % [rng.randi(), rng.randi()]


# Every non-empty pooled content rel referenced by the graph — the files the run
# folder's content/ must hold (deduped, since one clip can recur... it can't here
# with no-repeat, but boss/axis/vib share the round). Order-stable.
static func _collect_content_rels(graph: Dictionary) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for id: String in graph.get("nodes", {}):
		var d: Dictionary = (graph["nodes"][id] as Dictionary).get("data", {})
		var candidates: Array = [
			str(d.get("video_path", "")),
			str(d.get("funscript_path", "")),
			str(d.get("boss_image", "")),
		]
		for ax: Variant in (d.get("axis_scripts", {}) as Dictionary).values():
			candidates.append(str(ax))
		for vb: Variant in (d.get("vib_scripts", {}) as Dictionary).values():
			candidates.append(str(vb))
		for rel: String in candidates:
			if rel != "" and not seen.has(rel):
				seen[rel] = true
				out.append(rel)
	return out


static func _fail(reason: String, seed_val: int) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"journey": {},
		"content_rels": [],
		"used_ids": [],
		"summary":
		{
			"rounds": 0,
			"effects": 0,
			"bosses": 0,
			"shops": 0,
			"est_length_ms": 0,
			"coins_per_round": 0,
			"seed": seed_val,
		},
	}
