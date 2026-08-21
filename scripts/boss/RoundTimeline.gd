class_name RoundTimeline
extends RefCounted
## Pure model + validation for a round's TIMELINE — the authored event track that turns a boss round
## into a designed encounter (see BOSS_ROUND_DESIGN.md). Holds no state, touches no disk and no
## autoloads: every function is static and takes what it needs, so the whole layer is headless-testable
## exactly like FunscriptSegmenter / RandomizerParts.
##
## The timeline lives on a ROUND NODE's `data`, which JourneyData.coerce_node_save_data deep-copies
## wholesale — so it serializes with no coerce change, the way the loop keys do. That is why the shape
## here is snake_case on disk too (PascalCase is reserved for journey-LEVEL blocks like Items and
## Characters, which have their own explicit coerce/parse). `normalize()` is therefore used on BOTH
## sides — save and load — and is the single definition of the canonical shape.
##
## Time model: an event's `at_ms` is an offset from its `anchor` — the round's start, or its END.
## End-anchored events ("the last 10 seconds") are resolved once, when the video duration is known, so
## swapping a round's video keeps them meaningful instead of silently pointing at the wrong moment.
## Resolution lives in resolve_at_ms(); an event that cannot resolve returns NO_TIME and is skipped —
## never played at a wrong time.

# ── Vocabulary ───────────────────────────────────────────────────────────────

const TRACK_ATTACK: String = "attack"  # an override takeover (the boss seizes the device)
const TRACK_EFFECT: String = "effect"  # an effect bundle applied over a window
const TRACK_CAST: String = "cast"  # a timed image / portrait / subtitle pop-up
const TRACK_AUDIO: String = "audio"  # a one-shot sfx or narration cue
const TRACKS: Array[String] = [TRACK_ATTACK, TRACK_EFFECT, TRACK_CAST, TRACK_AUDIO]

# Where at_ms is measured from. END keeps "N ms before the round ends" correct across a video swap.
const ANCHOR_START: String = "start"
const ANCHOR_END: String = "end"
const ANCHORS: Array[String] = [ANCHOR_START, ANCHOR_END]

# When an event is allowed to fire. DEFEAT events replace the victory outro when the player bails out
# of the boss early (FINISH / exit), so an encounter can close either way.
const ON_ALWAYS: String = "always"
const ON_DEFEAT: String = "defeat"
const ON_MODES: Array[String] = [ON_ALWAYS, ON_DEFEAT]

# Cast compositing. ADD/SCREEN make black pixels drop out, which is what turns an opaque animated clip
# into usable flash / energy VFX — the decoder has no alpha channel (BOSS_ROUND_DESIGN §5.1).
const BLEND_NORMAL: String = "normal"
const BLEND_ADD: String = "add"
# Retired from authoring: CanvasItemMaterial has no screen mode, so it was only ever approximated with
# ADD and the two rendered identically. Kept as a constant purely to migrate cues authored while the
# option existed — see normalize_event.
const BLEND_SCREEN: String = "screen"
const BLENDS: Array[String] = [BLEND_NORMAL, BLEND_ADD]

const TRANSITION_FADE: String = "fade"
const TRANSITION_FLASH: String = "flash"
const TRANSITION_POP: String = "pop"
const TRANSITION_RISE: String = "rise"
const TRANSITION_SLIDE_LEFT: String = "slide_left"
const TRANSITION_SLIDE_RIGHT: String = "slide_right"
const TRANSITION_SLIDE_TOP: String = "slide_top"
const TRANSITION_SLIDE_BOTTOM: String = "slide_bottom"
# Superseded by the four directional values. Kept only to migrate cues authored while slide picked its
# own direction — see normalize_event. Never offered for authoring.
const TRANSITION_SLIDE: String = "slide"
const TRANSITIONS: Array[String] = [
	TRANSITION_FADE,
	TRANSITION_FLASH,
	TRANSITION_POP,
	TRANSITION_RISE,
	TRANSITION_SLIDE_LEFT,
	TRANSITION_SLIDE_RIGHT,
	TRANSITION_SLIDE_TOP,
	TRANSITION_SLIDE_BOTTOM,
]

const ANCHOR_CENTER: String = "center"
const CAST_ANCHORS: Array[String] = ["center", "left", "right", "top", "bottom", "custom"]

const AUDIO_SFX: String = "sfx"
const AUDIO_NARRATION: String = "narration"
const AUDIO_KINDS: Array[String] = [AUDIO_SFX, AUDIO_NARRATION]

# Returned by resolve_at_ms when an event cannot be placed on the round's clock (an end-anchored event
# on a video of unknown length). Callers SKIP such events — a wrong time is worse than no event.
const NO_TIME: int = -1

# Cue-local defaults. Modest fades: a cast pop-up that snaps is jarring, one that lingers reads as slow.
const DEFAULT_CUE_FADE_MS: int = 250
const DEFAULT_TEXT_HOLD_MS: int = 2500

# Subtitle type size, in CANVAS pixels (BossCueLayer scales the canvas, so this is the size it will
# appear at on a 1080p screen). Bounded so a line cannot be made unreadably small or large enough to
# cover the picture it is describing.
# Where a subtitle sits vertically, as a fraction of the canvas: 0 is the top edge, 1 the bottom. A free
# position rather than a set of presets, matching how cast art is placed — the author can tuck a line
# under a portrait, lift it clear of the health bar, or centre it, without the layer guessing which of
# those they meant. The default reproduces the band subtitles have always sat in.
const DEFAULT_TEXT_Y: float = 0.89

const DEFAULT_TEXT_SIZE: int = 22
const MIN_TEXT_SIZE: int = 10
const MAX_TEXT_SIZE: int = 72

# A narration cue ducks the round audio by default (an unducked line is buried under the video); an sfx
# does not, because a stab is meant to sit on top of the mix.
const DEFAULT_NARRATION_DUCK_PCT: float = 0.6
const DEFAULT_DUCK_FADE_MS: int = 200

# How long a one-shot cue carrying a LINE stays up. Longer than a wordless cue's hold because the floor
# is reading speed, not the beat — a fixed value rather than a field, since a line wanting its own timing
# is its own cue (see _fill_cast).
# Default hold for the defeat event (see the timeline-level `defeat_hold_ms`).
const DEFAULT_DEFEAT_HOLD_MS: int = 1600

# ── Validation issue codes ───────────────────────────────────────────────────

const ISSUE_ATTACK_OVERLAP: String = "attack_overlap"
const ISSUE_ATTACK_NO_SCRIPT: String = "attack_no_script"
const ISSUE_CAST_EMPTY: String = "cast_empty"
const ISSUE_AUDIO_NO_CLIP: String = "audio_no_clip"
const ISSUE_EFFECT_EMPTY: String = "effect_empty"
const ISSUE_UNRESOLVABLE: String = "unresolvable_anchor"
const ISSUE_OUT_OF_RANGE: String = "out_of_range"

# ── Construction / normalization ─────────────────────────────────────────────


## The canonical empty timeline — what a round without an authored encounter carries.
static func empty() -> Dictionary:
	return {
		"events": [],
		"phases": [],
		"bgm": {},
		"hp_bar": true,
		"phase_ticks": true,
		"boss_name": "",
		"defeat_hold_ms": DEFAULT_DEFEAT_HOLD_MS,
	}


## True when this timeline would change nothing at play time, so callers can skip the whole subsystem
## (and a round with one keeps behaving exactly like today's boss round).
static func is_empty(timeline: Dictionary) -> bool:
	return (
		(timeline.get("events", []) as Array).is_empty()
		and (timeline.get("phases", []) as Array).is_empty()
		and str((timeline.get("bgm", {}) as Dictionary).get("clip", "")) == ""
	)


## Any dictionary → the canonical timeline shape, with defaults filled and unusable entries dropped.
## Used on BOTH save and load (see the class comment), so a hand-edited or legacy journey.json is
## healed the same way a freshly authored one is. JSON hands every number back as a float, so each
## field is re-coerced rather than trusted.
static func normalize(raw: Dictionary) -> Dictionary:
	var out: Dictionary = empty()
	var events: Array = []
	for e: Variant in raw.get("events", []) as Array:
		if not (e is Dictionary):
			continue
		var ev: Dictionary = normalize_event(e as Dictionary)
		if not ev.is_empty():
			events.append(ev)
	# Sorted by anchor then offset so the scheduler and the editor always see one deterministic order.
	# START events sort before END events: they are measured from opposite ends of the round, so a
	# single numeric sort across both would interleave them meaninglessly.
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _event_sorter(a, b))
	out["events"] = events

	var phases: Array = []
	for p: Variant in raw.get("phases", []) as Array:
		if not (p is Dictionary):
			continue
		var ph: Dictionary = normalize_phase(p as Dictionary)
		if not ph.is_empty():
			phases.append(ph)
	phases.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _event_sorter(a, b))
	out["phases"] = phases

	var bgm: Dictionary = raw.get("bgm", {})
	if str(bgm.get("clip", "")) != "":
		out["bgm"] = {
			"clip": str(bgm["clip"]),
			"volume": clampf(float(bgm.get("volume", 1.0)), 0.0, 1.0),
		}
	out["hp_bar"] = bool(raw.get("hp_bar", true))
	# Division marks on the health bar, one per phase — a wordless "there is another stage to this".
	out["phase_ticks"] = bool(raw.get("phase_ticks", true))
	# What the health bar is labelled. Blank falls back to the round's own name, which is what the bar
	# used before it could be named — a round called "Sloppy BJ" is a filename, not a boss.
	out["boss_name"] = str(raw.get("boss_name", ""))
	# How long the give-in event is held before the round tears down. Long enough to read a line, short
	# enough that a player who has decided to stop is not made to wait.
	out["defeat_hold_ms"] = maxi(0, int(raw.get("defeat_hold_ms", DEFAULT_DEFEAT_HOLD_MS)))
	return out


# START before END, then by offset, then by id — a total order, so normalize() is stable and two
# normalizations of the same data compare equal.
static func _event_sorter(a: Dictionary, b: Dictionary) -> bool:
	var a_end: bool = str(a.get("anchor", ANCHOR_START)) == ANCHOR_END
	var b_end: bool = str(b.get("anchor", ANCHOR_START)) == ANCHOR_END
	if a_end != b_end:
		return not a_end
	var a_at: int = int(a.get("at_ms", 0))
	var b_at: int = int(b.get("at_ms", 0))
	if a_at != b_at:
		return a_at < b_at
	return str(a.get("id", "")) < str(b.get("id", ""))


## One raw event → its canonical shape, or {} when it is not usable at all (an unknown track — there is
## nothing sensible to play). A recognised event with missing content is KEPT and reported by
## validate() instead, so the editor can show the author what to fix rather than silently eating it.
static func normalize_event(raw: Dictionary) -> Dictionary:
	var track: String = str(raw.get("track", ""))
	if not TRACKS.has(track):
		return {}
	var out: Dictionary = {
		"id": _id_or_new(raw, "evt"),
		"track": track,
		"at_ms": maxi(0, int(raw.get("at_ms", 0))),
		"anchor": _one_of(str(raw.get("anchor", ANCHOR_START)), ANCHORS, ANCHOR_START),
		"duration_ms": maxi(0, int(raw.get("duration_ms", 0))),
		"phase": str(raw.get("phase", "")),
		"on": _one_of(str(raw.get("on", ON_ALWAYS)), ON_MODES, ON_ALWAYS),
	}
	# The reactive seam (BOSS_ROUND_DESIGN §8): carried verbatim, never interpreted in v1, so a journey
	# authored by a future build round-trips through this one without losing its conditions.
	var condition: Variant = raw.get("condition", null)
	if condition is Dictionary and not (condition as Dictionary).is_empty():
		out["condition"] = (condition as Dictionary).duplicate(true)

	match track:
		TRACK_ATTACK:
			_fill_attack(out, raw)
		TRACK_EFFECT:
			out["effects"] = _copy_dict_array(raw.get("effects", []))
			_carry_fades(out, raw)
		TRACK_CAST:
			_fill_cast(out, raw)
		TRACK_AUDIO:
			_fill_audio(out, raw)
	return out


# An attack IS an override request — the same bundle/immunity/trim/effects an override ITEM carries, so
# the runtime can hand it to the existing engine untouched. `name` is the only addition: it labels the
# HUD chip so the attack reads as a named move rather than a generic takeover.
static func _fill_attack(out: Dictionary, raw: Dictionary) -> void:
	out["name"] = str(raw.get("name", ""))
	out["immune_to_effects"] = bool(raw.get("immune_to_effects", false))
	out["scripts"] = _normalize_scripts(raw.get("scripts", {}))
	out["effects"] = _copy_dict_array(raw.get("effects", []))
	_carry_trim(out, raw)


static func _fill_cast(out: Dictionary, raw: Dictionary) -> void:
	out["character_id"] = str(raw.get("character_id", ""))
	out["portrait"] = str(raw.get("portrait", ""))
	out["image"] = str(raw.get("image", ""))
	out["anchor_pos"] = _one_of(
		str(raw.get("anchor_pos", ANCHOR_CENTER)), CAST_ANCHORS, ANCHOR_CENTER
	)
	out["offset"] = _to_offset(raw.get("offset", null))
	out["scale"] = maxf(0.01, float(raw.get("scale", 1.0)))
	# Bare `slide` becomes slide_left, which is the direction it always travelled, so a cue authored
	# before directions existed keeps the entrance it was given.
	var raw_transition: String = str(raw.get("transition", TRANSITION_FADE))
	if raw_transition == TRANSITION_SLIDE:
		raw_transition = TRANSITION_SLIDE_LEFT
	out["transition"] = _one_of(raw_transition, TRANSITIONS, TRANSITION_FADE)
	out["in_ms"] = maxi(0, int(raw.get("in_ms", DEFAULT_CUE_FADE_MS)))
	out["out_ms"] = maxi(0, int(raw.get("out_ms", DEFAULT_CUE_FADE_MS)))
	# Tier-1 animation layer: an animated source plays through the existing hidden decoder, with a blend
	# mode standing in for the alpha the 4:2:0 decoder cannot give us. Whether it repeats is NOT stored —
	# BossCueLayer derives it from the cue's kind, since a windowed cue loops for as long as its window
	# is open and a one-shot plays exactly once, and no third answer is meaningful.
	# `screen` folds into `add` rather than being dropped: the two always rendered the same, so mapping
	# preserves exactly what the author saw, where falling back to NORMAL would silently stop black
	# dropping out of a cue that was composited on purpose.
	var raw_blend: String = str(raw.get("blend", BLEND_NORMAL))
	if raw_blend == BLEND_SCREEN:
		raw_blend = BLEND_ADD
	out["blend"] = _one_of(raw_blend, BLENDS, BLEND_NORMAL)
	# Dialogue: a subtitle riding the same cue, sharing its fades and its lifetime. A line that needs its
	# own schedule is authored as its own text-only cue rather than as a parallel set of timings here.
	var text: String = str(raw.get("text", ""))
	if text != "":
		out["text"] = text
		out["text_y"] = clampf(float(raw.get("text_y", DEFAULT_TEXT_Y)), 0.0, 1.0)
		out["text_size"] = clampi(
			int(raw.get("text_size", DEFAULT_TEXT_SIZE)), MIN_TEXT_SIZE, MAX_TEXT_SIZE
		)
		# Only stored when the author actually picked one, so an untouched cue keeps following the
		# theme's subtitle colour instead of being pinned to whatever white happened to be current.
		if raw.has("text_color"):
			out["text_color"] = _to_tint(raw["text_color"])


static func _fill_audio(out: Dictionary, raw: Dictionary) -> void:
	var kind: String = _one_of(str(raw.get("kind", AUDIO_SFX)), AUDIO_KINDS, AUDIO_SFX)
	out["clip"] = str(raw.get("clip", ""))
	out["kind"] = kind
	out["volume"] = clampf(float(raw.get("volume", 1.0)), 0.0, 1.0)
	# Narration ducks by default, sfx does not — see DEFAULT_NARRATION_DUCK_PCT.
	var default_duck: float = DEFAULT_NARRATION_DUCK_PCT if kind == AUDIO_NARRATION else 0.0
	out["duck_pct"] = clampf(float(raw.get("duck_pct", default_duck)), 0.0, 1.0)
	out["duck_fade_ms"] = maxi(0, int(raw.get("duck_fade_ms", DEFAULT_DUCK_FADE_MS)))
	# An audio cue can be sliced like an attack: resizing its block on the timeline cuts the clip rather
	# than merely changing how long the block looks, so what plays matches what is drawn.
	_carry_trim(out, raw)


# Ease-in / ease-out for an effect window or an audio cue, in ms. Zero (the default) is a hard cut,
# which is what these did before authors could set them.
static func _carry_fades(out: Dictionary, raw: Dictionary) -> void:
	out["fade_in_ms"] = maxi(0, int(raw.get("fade_in_ms", 0)))
	out["fade_out_ms"] = maxi(0, int(raw.get("fade_out_ms", 0)))


# The {in_ms, out_ms} slice window an attack or audio cue plays, when it has one. Absent means "the
# whole thing" — which is different from a zero-length window, so it must not be defaulted into being.
static func _carry_trim(out: Dictionary, raw: Dictionary) -> void:
	var trim: Dictionary = raw.get("trim", {})
	if trim is Dictionary and not (trim as Dictionary).is_empty():
		out["trim"] = {
			"in_ms": maxi(0, int(trim.get("in_ms", 0))),
			"out_ms": maxi(0, int(trim.get("out_ms", 0))),
		}


## One raw phase → canonical, or {} when it carries no id/name to identify it by.
static func normalize_phase(raw: Dictionary) -> Dictionary:
	var id: String = _id_or_new(raw, "phs")
	var out: Dictionary = {
		"id": id,
		"name": str(raw.get("name", "")),
		"at_ms": maxi(0, int(raw.get("at_ms", 0))),
		"anchor": _one_of(str(raw.get("anchor", ANCHOR_START)), ANCHORS, ANCHOR_START),
		"banner": bool(raw.get("banner", false)),
	}
	# `tint` is optional: absent means "leave the round's own framing alone", which is different from a
	# transparent tint, so it must not be defaulted into existence.
	if raw.has("tint") and raw["tint"] != null:
		out["tint"] = _to_tint(raw["tint"])
	return out


# ── Time resolution ──────────────────────────────────────────────────────────


## An event's absolute position on the round clock. START events are their own offset; END events count
## backwards from the video's duration. Returns NO_TIME when an END event cannot be placed (duration
## unknown) or would land before the round begins — the caller skips it rather than firing it wrongly.
static func resolve_at_ms(event: Dictionary, video_duration_ms: int) -> int:
	var at: int = int(event.get("at_ms", 0))
	if str(event.get("anchor", ANCHOR_START)) != ANCHOR_END:
		return at
	if video_duration_ms <= 0:
		return NO_TIME
	var resolved: int = video_duration_ms - at
	return resolved if resolved >= 0 else NO_TIME


## Every event with its anchor resolved, in play order: `{…event, resolved_at_ms}`. Unresolvable events
## are dropped. `include_defeat` selects which outro set comes back — the normal pass excludes
## defeat-only events, the bail-out path asks for them specifically.
static func resolved_events(
	timeline: Dictionary, video_duration_ms: int, include_defeat: bool = false
) -> Array:
	var out: Array = []
	for e: Dictionary in timeline.get("events", []) as Array:
		var is_defeat: bool = str(e.get("on", ON_ALWAYS)) == ON_DEFEAT
		if is_defeat != include_defeat:
			continue
		var at: int = resolve_at_ms(e, video_duration_ms)
		if at == NO_TIME:
			continue
		var copy: Dictionary = e.duplicate(true)
		copy["resolved_at_ms"] = at
		out.append(copy)
	out.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var a_at: int = int(a["resolved_at_ms"])
			var b_at: int = int(b["resolved_at_ms"])
			if a_at != b_at:
				return a_at < b_at
			return str(a.get("id", "")) < str(b.get("id", ""))
	)
	return out


## Phases with their anchors resolved, in play order — same contract as resolved_events.
static func resolved_phases(timeline: Dictionary, video_duration_ms: int) -> Array:
	var out: Array = []
	for p: Dictionary in timeline.get("phases", []) as Array:
		var at: int = resolve_at_ms(p, video_duration_ms)
		if at == NO_TIME:
			continue
		var copy: Dictionary = p.duplicate(true)
		copy["resolved_at_ms"] = at
		out.append(copy)
	out.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["resolved_at_ms"]) < int(b["resolved_at_ms"])
	)
	return out


# ── Validation ───────────────────────────────────────────────────────────────


## Authoring problems, as [{code, event_id, message}] — what the editor surfaces and the presave gate
## can block on. `video_duration_ms` is optional: pass 0 when the round's length is unknown and the
## range/anchor checks that need it are skipped rather than guessed at.
static func validate(timeline: Dictionary, video_duration_ms: int = 0) -> Array:
	var issues: Array = []
	for e: Dictionary in timeline.get("events", []) as Array:
		var id: String = str(e.get("id", ""))
		match str(e.get("track", "")):
			TRACK_ATTACK:
				if str((e.get("scripts", {}) as Dictionary).get("main", "")) == "":
					issues.append(
						_issue(
							ISSUE_ATTACK_NO_SCRIPT, id, "This attack has no main funscript to play."
						)
					)
			TRACK_CAST:
				# A cue with neither art nor a line renders nothing at all.
				var has_art: bool = (
					str(e.get("image", "")) != "" or str(e.get("character_id", "")) != ""
				)
				if not has_art and str(e.get("text", "")) == "":
					issues.append(
						_issue(ISSUE_CAST_EMPTY, id, "This cue has no image, character, or text.")
					)
			TRACK_AUDIO:
				if str(e.get("clip", "")) == "":
					issues.append(_issue(ISSUE_AUDIO_NO_CLIP, id, "This audio cue has no clip."))
			TRACK_EFFECT:
				if (e.get("effects", []) as Array).is_empty():
					issues.append(
						_issue(ISSUE_EFFECT_EMPTY, id, "This effect window applies no effects.")
					)
		if video_duration_ms > 0:
			var at: int = resolve_at_ms(e, video_duration_ms)
			if at == NO_TIME:
				issues.append(
					_issue(
						ISSUE_UNRESOLVABLE,
						id,
						"This event is anchored further from the end than the round is long."
					)
				)
			elif at >= video_duration_ms:
				issues.append(
					_issue(ISSUE_OUT_OF_RANGE, id, "This event starts after the round ends.")
				)
	issues.append_array(_attack_overlap_issues(timeline, video_duration_ms))
	return issues


# The override engine holds ONE session (a second request replaces the first), so two attacks that
# overlap would silently cut each other off. Rejecting them at authoring time is clearer than shipping
# an encounter whose attacks eat one another. Only checkable once times resolve, hence the duration gate.
static func _attack_overlap_issues(timeline: Dictionary, video_duration_ms: int) -> Array:
	if video_duration_ms <= 0:
		return []
	var attacks: Array = []
	for e: Dictionary in resolved_events(timeline, video_duration_ms):
		if str(e.get("track", "")) == TRACK_ATTACK:
			attacks.append(e)
	var issues: Array = []
	for i: int in range(1, attacks.size()):
		var prev: Dictionary = attacks[i - 1]
		var cur: Dictionary = attacks[i]
		var prev_end: int = int(prev["resolved_at_ms"]) + int(prev.get("duration_ms", 0))
		if int(cur["resolved_at_ms"]) < prev_end:
			issues.append(
				_issue(
					ISSUE_ATTACK_OVERLAP,
					str(cur.get("id", "")),
					"This attack starts before the previous one finishes."
				)
			)
	return issues


static func _issue(code: String, event_id: String, message: String) -> Dictionary:
	return {"code": code, "event_id": event_id, "message": message}


# ── Media (for pooling) ──────────────────────────────────────────────────────

## Media kinds, so the save can pool each file the way its family expects (a funscript normalizes to
## the .funscript extension; an image or clip keeps its own).
const MEDIA_FUNSCRIPT: String = "funscript"
const MEDIA_IMAGE: String = "image"
const MEDIA_AUDIO: String = "audio"


## Every media SOURCE the timeline references, as `[{path, kind}]` — attack funscripts (all channels),
## cast images, audio clips, and the BGM — deduped, in a stable order. The save pools these into the
## journey's content/ and feeds the result back through remap_media(). Character PORTRAITS are
## deliberately absent: they belong to the journey's Characters block, which pools them itself.
static func media_entries(timeline: Dictionary) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	var add := func(path: String, kind: String) -> void:
		if path != "" and not seen.has(path):
			seen[path] = true
			out.append({"path": path, "kind": kind})
	for e: Dictionary in timeline.get("events", []) as Array:
		match str(e.get("track", "")):
			TRACK_ATTACK:
				var scripts: Dictionary = e.get("scripts", {})
				add.call(str(scripts.get("main", "")), MEDIA_FUNSCRIPT)
				for group: String in ["axes", "vibes"]:
					for channel: Variant in (scripts.get(group, {}) as Dictionary).values():
						add.call(str(channel), MEDIA_FUNSCRIPT)
			TRACK_CAST:
				add.call(str(e.get("image", "")), MEDIA_IMAGE)
			TRACK_AUDIO:
				add.call(str(e.get("clip", "")), MEDIA_AUDIO)
	add.call(str((timeline.get("bgm", {}) as Dictionary).get("clip", "")), MEDIA_AUDIO)
	return out


## The same sources as media_entries(), as a plain deduped path list.
static func media_paths(timeline: Dictionary) -> Array:
	var out: Array = []
	for entry: Dictionary in media_entries(timeline):
		out.append(str(entry["path"]))
	return out


## A copy of `timeline` with every pooled REL turned into an absolute path under `base` — the load-side
## counterpart of the save's pooling, mirroring JourneyGraph's other media resolution. Empty paths stay
## empty; an already-absolute path would be re-prefixed, so this runs exactly once, at load.
static func resolve_media(timeline: Dictionary, base: String) -> Dictionary:
	var mapping: Dictionary = {}
	for rel: String in media_paths(timeline):
		mapping[rel] = base + "/" + rel
	return remap_media(timeline, mapping)


## A copy of `timeline` with every media source replaced by `mapping[source]`. Paths missing from the
## mapping are left as they are — pooling one file must never blank out another — so a partial pool
## degrades to "some paths still point at the author's disk" rather than to a broken timeline.
static func remap_media(timeline: Dictionary, mapping: Dictionary) -> Dictionary:
	var out: Dictionary = timeline.duplicate(true)
	var mapped := func(path: String) -> String:
		return str(mapping.get(path, path)) if path != "" else path
	for e: Dictionary in out.get("events", []) as Array:
		match str(e.get("track", "")):
			TRACK_ATTACK:
				var scripts: Dictionary = e.get("scripts", {})
				scripts["main"] = mapped.call(str(scripts.get("main", "")))
				for group: String in ["axes", "vibes"]:
					var channels: Dictionary = scripts.get(group, {})
					for key: Variant in channels.keys():
						channels[key] = mapped.call(str(channels[key]))
			TRACK_CAST:
				e["image"] = mapped.call(str(e.get("image", "")))
			TRACK_AUDIO:
				e["clip"] = mapped.call(str(e.get("clip", "")))
	var bgm: Dictionary = out.get("bgm", {})
	if str(bgm.get("clip", "")) != "":
		bgm["clip"] = mapped.call(str(bgm["clip"]))
	return out


# ── Small helpers ────────────────────────────────────────────────────────────


## Ids are minted here rather than by the editor so a hand-written or migrated timeline still gets
## stable per-event identity (the inspector, undo, and the scheduler's fired-set all key on it).
static func new_event_id(prefix: String = "evt") -> String:
	return "%s_%08x%08x" % [prefix, randi(), randi()]


static func _id_or_new(raw: Dictionary, prefix: String) -> String:
	var id: String = str(raw.get("id", "")).strip_edges()
	return id if id != "" else new_event_id(prefix)


static func _one_of(value: String, allowed: Array[String], fallback: String) -> String:
	return value if allowed.has(value) else fallback


static func _copy_dict_array(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for e: Variant in raw as Array:
		if e is Dictionary:
			out.append((e as Dictionary).duplicate(true))
	return out


# The funscript bundle an attack plays: main + optional axis/vib channels, string-keyed so it survives
# a JSON round-trip unchanged. Identical in shape to an override item's `scripts`.
static func _normalize_scripts(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {"main": str(raw.get("main", "")), "axes": {}, "vibes": {}}
	for group: String in ["axes", "vibes"]:
		var channels: Dictionary = raw.get(group, {})
		for key: Variant in channels:
			var path: String = str(channels[key])
			if path != "":
				(out[group] as Dictionary)[str(key)] = path
	return out


# This canonical shape IS the on-disk shape (see the class comment), so it has to survive
# JSON.stringify → JSON.parse. Vector2 and Color do NOT: stringify renders them as "(0, 0)" strings
# that parse back as text, silently losing the value. Offsets and tints are therefore kept as plain
# {x,y} / {r,g,b,a} dictionaries, and converted at the point of use by the two helpers below. Both
# accept the engine type as input so a caller can hand one over without pre-converting.
static func _to_offset(raw: Variant) -> Dictionary:
	if raw is Vector2:
		return {"x": (raw as Vector2).x, "y": (raw as Vector2).y}
	if raw is Dictionary:
		var d: Dictionary = raw
		return {"x": float(d.get("x", 0.0)), "y": float(d.get("y", 0.0))}
	return {"x": 0.0, "y": 0.0}


static func _to_tint(raw: Variant) -> Dictionary:
	if raw is Color:
		var c: Color = raw
		return {"r": c.r, "g": c.g, "b": c.b, "a": c.a}
	if raw is Dictionary:
		var d: Dictionary = raw
		return {
			"r": float(d.get("r", 1.0)),
			"g": float(d.get("g", 1.0)),
			"b": float(d.get("b", 1.0)),
			"a": float(d.get("a", 1.0)),
		}
	return {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0}


## {x,y} → Vector2, for the renderer. Kept here so the storage shape has exactly one reader.
static func offset_vector(cue: Dictionary) -> Vector2:
	var o: Dictionary = cue.get("offset", {})
	return Vector2(float(o.get("x", 0.0)), float(o.get("y", 0.0)))


## The subtitle's authored colour, or `fallback` when the cue never set one.
static func cue_text_color(cue: Dictionary, fallback: Color) -> Color:
	if not cue.has("text_color"):
		return fallback
	var t: Dictionary = cue["text_color"]
	return Color(
		float(t.get("r", 1.0)),
		float(t.get("g", 1.0)),
		float(t.get("b", 1.0)),
		float(t.get("a", 1.0))
	)


## {r,g,b,a} → Color, for the framing layer. Returns `fallback` when the phase carries no tint.
static func phase_tint(phase: Dictionary, fallback: Color = Color.WHITE) -> Color:
	if not phase.has("tint"):
		return fallback
	var t: Dictionary = phase["tint"]
	return Color(
		float(t.get("r", 1.0)),
		float(t.get("g", 1.0)),
		float(t.get("b", 1.0)),
		float(t.get("a", 1.0))
	)
