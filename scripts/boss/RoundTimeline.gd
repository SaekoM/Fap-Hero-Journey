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
const TRACK_STANCE: String = "stance"  # how the boss takes damage over a window
# A stretch of the CLIP that only plays when its rule holds. Unlike every other track it does not add
# anything to the round — it takes something away, by jumping the playhead over itself when the rule
# fails. That makes a scene conditional: no climax until the boss is beaten, no foreplay after the first
# attempt.
const TRACK_REGION: String = "region"
const TRACKS: Array[String] = [
	TRACK_ATTACK, TRACK_EFFECT, TRACK_STANCE, TRACK_REGION, TRACK_CAST, TRACK_AUDIO
]

# ── Stances ──────────────────────────────────────────────────────────────────
#
# How the boss takes damage, as a NAME rather than a bare number. The multiplier underneath is still the
# mechanic; the name exists so the bar can say one word.
#
# It is a lane of its own rather than a field on an effect window because effect windows MULTIPLY: ×0.5
# and ×2 overlapping give ×1, which has no name. Stances are held to one at a time (validate() reports
# an overlap) so there is always exactly one word to show.
const STANCE_NORMAL: String = "normal"
const STANCE_GUARDED: String = "guarded"
const STANCE_IMMUNE: String = "immune"
const STANCE_VULNERABLE: String = "vulnerable"
# Healing, which is damage with the sign flipped — so a regen window is a stance rather than a mechanism
# of its own, and rides everything stances already do.
const STANCE_RECOVERING: String = "recovering"
# Both DERIVED and AUTHORABLE, which no other stance is.
#
# It is derived while an attack on the attack track owns the device, and outranks any window an author
# placed — the round knows a takeover is running and says so.
#
# It is also placeable, because plenty of encounters have no attack track at all: a creator can write the
# boss's moves straight into the round's own funscript, and the strokes ARE the attack. Nothing in the
# engine can detect that, so the author marks it. Same zero as IMMUNE, deliberately a different word:
# "she is doing something to you" and "she is turtling" are not the same thing to play against.
const STANCE_ATTACKING: String = "attacking"
# ATTACKING sits beside IMMUNE so the two zeros read together in the picker.
const STANCES: Array[String] = [
	STANCE_NORMAL,
	STANCE_GUARDED,
	STANCE_ATTACKING,
	STANCE_IMMUNE,
	STANCE_VULNERABLE,
	STANCE_RECOVERING,
]

# Where at_ms is measured from. END keeps "N ms before the round ends" correct across a video swap.
const ANCHOR_START: String = "start"
const ANCHOR_END: String = "end"
const ANCHORS: Array[String] = [ANCHOR_START, ANCHOR_END]

# When an event is allowed to fire. DEFEAT events replace the victory outro when the player bails out
# of the boss early (FINISH / exit), so an encounter can close either way.
const ON_ALWAYS: String = "always"
# When an event plays. ALWAYS is the timeline proper; anything else is an OUTCOME, which has no place on
# the clock — it fires on the way out of the round, whichever way that turns out to be.
#
# `gave_in` was stored as `defeat` until a boss could itself be defeated, at which point the word pointed
# both ways: it means the PLAYER gave in. Renamed with a migration rather than left ambiguous, because
# the confusion only gets more expensive once authors have content built on it.
#
# It now covers BOTH ways a player loses: pressing FINISH, and running the attempts out with the boss
# still standing. They were briefly separate endings, but nothing wanted to tell them apart — an author
# writing "she wins" wrote it twice — so there are two ways out of a round, not three.
const ON_GAVE_IN: String = "gave_in"
# The boss went down mid-pass — the bar reached zero.
const ON_WON: String = "won"
const ON_MODES: Array[String] = [ON_ALWAYS, ON_GAVE_IN, ON_WON]

# Values that used to mean "the player lost". Read on the way in, never written: `defeat` predates the
# rename, `lost` was the separate out-of-attempts ending before it merged into ON_GAVE_IN.
const ON_DEFEAT_LEGACY: String = "defeat"
const ON_LOST_LEGACY: String = "lost"

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

# The only fields an ALTERNATIVE may overlay. The line is drawn between what a candidate IS and WHEN it
# happens: content and framing may vary, timing may not.
#
# Timing is excluded because an alt that could move itself on the clock would let one candidate reorder
# against its siblings, and both the scheduler's ordering and the containment rule the window model
# rests on assume an event's position is fixed at resolve time. Overlays make that structurally
# impossible rather than merely discouraged.
#
# PLACEMENT is not timing, and used to be excluded with it — wrongly. A portrait and a wide shot want
# different framing, and `text_y` was already here, so the rule was inconsistent as well as limiting.
const ALT_FIELDS: Array[String] = [
	"text",
	"text_y",
	"text_size",
	"text_color",
	"offset",
	"scale",
	"anchor_pos",
	"image",
	"portrait",
	"clip",
]

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
# Default hold for an OUTCOME moment — long enough to read a line, short enough that a player who has
# decided to stop is not made to wait. Neutral name because every way out of the round shares it.
const DEFAULT_OUTCOME_HOLD_MS: int = 1600

# What drains the boss health bar. TIME is what it has always been — round progress, inverted — and
# stays the default so every existing encounter is untouched. SCORE makes the bar an honest readout of
# the player: it empties as they earn, and "empty" becomes a condition an author hangs events on rather
# than a mechanic of its own.
const HP_TIME: String = "time"
const HP_SCORE: String = "score"
const HP_SOURCES: Array[String] = [HP_TIME, HP_SCORE]

# How many passes the player gets at the boss. ONE is the default and means today's behaviour exactly —
# the round plays once and moves on, whatever the bar reached. Anything higher turns the round into a
# fight: a pass that ends with the boss still standing replays, carrying its damage.
#
# A cap is not optional. Without one a player who cannot reach the target loops for ever.
const DEFAULT_MAX_ATTEMPTS: int = 1

# How hard the boss can be hit while an effect window is open. 1.0 is ordinary; 0.0 is a window she
# simply cannot be hurt through, and anything above 1 is an opening. A raw number rather than named
# tiers, so an author can tune a fight rather than pick from a menu.
#
# Overlapping windows MULTIPLY, matching how ScoreService already stacks score_multiplier effects.

# Score needed to empty the bar. Arbitrary as a default because what is achievable depends entirely on
# the round; the author tunes it against what they actually see themselves score.
const DEFAULT_DAMAGE_TARGET: int = 1000

# ── Validation issue codes ───────────────────────────────────────────────────

const ISSUE_ATTACK_OVERLAP: String = "attack_overlap"
const ISSUE_ATTACK_NO_SCRIPT: String = "attack_no_script"
const ISSUE_CAST_EMPTY: String = "cast_empty"
const ISSUE_AUDIO_NO_CLIP: String = "audio_no_clip"
const ISSUE_EFFECT_EMPTY: String = "effect_empty"
const ISSUE_UNRESOLVABLE: String = "unresolvable_anchor"
const ISSUE_OUT_OF_RANGE: String = "out_of_range"
const ISSUE_ALT_EMPTY: String = "alt_empty"
# What a condition may read about the player. Deliberately NOT elapsed time: an event's position on the
# clock already says when it happens, and a second way to express the same thing invites an author to
# write a condition that contradicts the placement they just dragged.
const SIGNAL_SCORE: String = "score"
const SIGNAL_SPM: String = "spm"  # strokes per minute, over a rolling window
const SIGNAL_SMALL: String = "small"
const SIGNAL_MEDIUM: String = "medium"
const SIGNAL_LARGE: String = "large"
const SIGNAL_ITEMS_USED: String = "items_used"
const SIGNAL_LAST_ITEM: String = "last_item_kind"
# The specific item, where SIGNAL_LAST_ITEM is its category. "They used a cleanse" and "they used the
# Silver Key" are different questions, and an encounter built around one particular item cannot ask the
# first one.
const SIGNAL_LAST_ITEM_ID: String = "last_item_id"

# How much fight the boss has left, 0..1 — the bar as a number a rule can read. This is what closes the
# loop: the bar stops being a readout and starts driving what the boss does.
const SIGNAL_BOSS_HP: String = "boss_hp"

# Which pass this is, counting from 1. The anti-repetition tool: variants make a replay DIFFERENT, this
# makes it ESCALATE, and a repeat that acknowledges itself reads as a fight rather than a bug.
const SIGNAL_ATTEMPT: String = "attempt"
const SIGNALS: Array[String] = [
	SIGNAL_SCORE,
	SIGNAL_SPM,
	SIGNAL_SMALL,
	SIGNAL_MEDIUM,
	SIGNAL_LARGE,
	SIGNAL_ITEMS_USED,
	SIGNAL_LAST_ITEM,
	SIGNAL_LAST_ITEM_ID,
	SIGNAL_BOSS_HP,
	SIGNAL_ATTEMPT,
]


## True when an event fires on the way OUT of the round rather than at a time on it. One predicate, so
## adding a fourth exit later does not mean hunting down every `!= ON_ALWAYS` written by hand.
static func is_outcome_event(event: Dictionary) -> bool:
	return str(event.get("on", ON_ALWAYS)) != ON_ALWAYS


## A human name for one of the ways out, for headings and chips.
static func outcome_label(on_mode: String) -> String:
	match on_mode:
		ON_WON:
			return "ON WIN"
		ON_GAVE_IN:
			return "ON DEFEAT"
	return ""


## Which way out of the round an event belongs to, migrating the pre-rename spelling.
static func _normalize_on(raw: Dictionary) -> String:
	var mode: String = str(raw.get("on", ON_ALWAYS))
	if mode == ON_DEFEAT_LEGACY or mode == ON_LOST_LEGACY:
		mode = ON_GAVE_IN
	return _one_of(mode, ON_MODES, ON_ALWAYS)


## True for the signals whose value is a NAME rather than a number. Kept as one predicate because three
## separate places have to agree about it — parsing, comparing and printing — and a fourth text signal
## added later must not have to remember all of them.
static func is_text_signal(signal_name: String) -> bool:
	return signal_name == SIGNAL_LAST_ITEM or signal_name == SIGNAL_LAST_ITEM_ID


## The operators that make sense for a signal. Ordering an item name is meaningless, so a name signal
## offers only "is" and "is not" — showing it `<` invited a rule that could never mean what it looked
## like, since _clause_holds treats every non-`neq` comparison on a name as equality anyway.
static func ops_for(signal_name: String) -> Array[String]:
	return NAME_OPS if is_text_signal(signal_name) else OPS


## The signal as an author should read it. The stored ids stay terse and stable — a saved journey keeps
## working — while everything on screen says what the number actually is. The stroke ranges are spelled
## out because "small" alone never told anyone where small stops.
static func signal_label(signal_name: String) -> String:
	match signal_name:
		SIGNAL_SCORE:
			return "Score"
		SIGNAL_SPM:
			return "Strokes Per Minute"
		SIGNAL_SMALL:
			return "Small Strokes (0-20)"
		SIGNAL_MEDIUM:
			return "Medium Strokes (21-70)"
		SIGNAL_LARGE:
			return "Large Strokes (71-100)"
		SIGNAL_ITEMS_USED:
			return "Items Used"
		SIGNAL_LAST_ITEM:
			return "Last Item Type Used"
		SIGNAL_LAST_ITEM_ID:
			return "Last Item Used"
		SIGNAL_BOSS_HP:
			return "Boss Health Left (0-1)"
		SIGNAL_ATTEMPT:
			return "Attempt Number"
	return signal_name


## The comparison in words. A name reads "is" / "is not"; a number keeps its symbol, which is shorter
## and unambiguous once there are digits either side of it.
static func op_label(op: String, signal_name: String) -> String:
	if is_text_signal(signal_name):
		return "is not" if op == OP_NEQ else "is"
	return op_symbol(op)


const OP_LT: String = "lt"
const OP_LTE: String = "lte"
const OP_GT: String = "gt"
const OP_GTE: String = "gte"
const OP_EQ: String = "eq"
const OP_NEQ: String = "neq"
const OPS: Array[String] = [OP_LT, OP_LTE, OP_GT, OP_GTE, OP_EQ, OP_NEQ]

# The comparisons a NAME signal may use. A typed constant rather than a literal built per call: an array
# literal is untyped in GDScript, so returning one from a function declared Array[String] fails at
# runtime — and only when an author actually clicks the signal that reaches it.
const NAME_OPS: Array[String] = [OP_EQ, OP_NEQ]

# How a condition's clauses combine. Flat and one-level on purpose: nesting groups inside groups is the
# point where a rule editor turns into visual programming, and an author who genuinely needs
# "(A and B) or C" writes a second branch — which is the mechanism segments already provide.
const MATCH_ALL: String = "all"
const MATCH_ANY: String = "any"
const MATCHES: Array[String] = [MATCH_ALL, MATCH_ANY]

const ISSUE_CONDITION_BAD: String = "condition_bad"
const ISSUE_SEGMENT_THIN: String = "segment_thin"
const ISSUE_SEGMENT_DEAD_TAG: String = "segment_dead_tag"
const ISSUE_SEGMENT_TAG_CLASH: String = "segment_tag_clash"
const ISSUE_STANCE_OVERLAP: String = "stance_overlap"
const ISSUE_REGION_NO_RULE: String = "region_no_rule"

# ── Construction / normalization ─────────────────────────────────────────────


## The canonical empty timeline — what a round without an authored encounter carries.
static func empty() -> Dictionary:
	return {
		"events": [],
		"phases": [],
		"segments": [],
		"bgm": {},
		"hp_bar": true,
		"hp_bar_y": DEFAULT_HP_BAR_Y,
		"won_flag": "",
		"lost_flag": "",
		"pause_regen_per_sec": 0,
		"attempt_regen_pct": 0.0,
		"phase_ticks": true,
		"boss_name": "",
		"outcome_hold_ms": DEFAULT_OUTCOME_HOLD_MS,
		"items_allowed": true,
		"hp_source": HP_TIME,
		"damage_target": DEFAULT_DAMAGE_TARGET,
		"max_attempts": DEFAULT_MAX_ATTEMPTS,
		"win_jump_ms": NO_TIME,
		"win_jump_anchor": ANCHOR_END,
	}


## True when this timeline would change nothing at play time, so callers can skip the whole subsystem
## (and a round with one keeps behaving exactly like today's boss round). BOTH places that drop a
## timeline on save ask this, so anything it fails to notice is silently discarded.
##
## Compared against the DEFAULT rather than against a hand-written list of fields. It used to test only
## events, phases and bgm — which was true when an encounter with no events did nothing, and stopped
## being true the moment the encounter grew settings of its own. A boss that is named, has a score
## health bar, a damage target, attempts and regeneration is a complete encounter carrying no events at
## all, and it was being thrown away on save.
##
## Written this way so the same thing cannot happen again: a field added to empty() and normalize() is
## covered here the day it is added, with nothing to remember.
static func is_empty(timeline: Dictionary) -> bool:
	return JSON.stringify(normalize(timeline)) == JSON.stringify(empty())


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

	var segments: Array = []
	for sg: Variant in raw.get("segments", []) as Array:
		if sg is Dictionary:
			segments.append(normalize_segment(sg as Dictionary))
	out["segments"] = segments

	var bgm: Dictionary = raw.get("bgm", {})
	if str(bgm.get("clip", "")) != "":
		out["bgm"] = {
			"clip": str(bgm["clip"]),
			"volume": clampf(float(bgm.get("volume", 1.0)), 0.0, 1.0),
		}
	out["hp_bar"] = bool(raw.get("hp_bar", true))
	# Her colour. Absent means "the default red" — different from a stored red, because a theme change
	# should still move an encounter that never chose.
	if raw.has("bar_color") and raw["bar_color"] != null:
		out["bar_color"] = _to_tint(raw["bar_color"])
	out["hp_bar_y"] = clampf(float(raw.get("hp_bar_y", DEFAULT_HP_BAR_Y)), 0.0, 1.0)
	# Whether the health bar is SPLIT into one stage per phase — a wordless "there is another stage to
	# this". The key keeps its original name so existing journeys still read; what changed is the drawing
	# (gaps punched through the bar rather than marks laid over it), not what the switch means.
	out["phase_ticks"] = bool(raw.get("phase_ticks", true))
	# What the health bar is labelled. Blank falls back to the round's own name, which is what the bar
	# used before it could be named — a round called "Sloppy BJ" is a filename, not a boss.
	out["boss_name"] = str(raw.get("boss_name", ""))
	# How long the give-in event is held before the round tears down. Long enough to read a line, short
	# enough that a player who has decided to stop is not made to wait.
	# `defeat_hold_ms` is the pre-rename spelling, read once on the way in so an existing encounter keeps
	# the hold its author tuned.
	var hold_default: int = int(raw.get("defeat_hold_ms", DEFAULT_OUTCOME_HOLD_MS))
	out["outcome_hold_ms"] = maxi(0, int(raw.get("outcome_hold_ms", hold_default)))
	# Items default to ALLOWED — but only for a round that HAS an authored encounter. A boss round with
	# no timeline keeps the original lockout (see GameLoop._items_allowed_here), so every journey built
	# before this feature plays exactly as it did. Opting in is what un-gates them.
	out["items_allowed"] = bool(raw.get("items_allowed", true))
	out["hp_source"] = _one_of(str(raw.get("hp_source", HP_TIME)), HP_SOURCES, HP_TIME)
	# Clamped above zero: a target of nothing would divide the bar by zero and read as instantly dead.
	out["damage_target"] = maxi(1, int(raw.get("damage_target", DEFAULT_DAMAGE_TARGET)))
	# Clamped to at least one pass: zero attempts would mean a round that cannot be played at all.
	out["max_attempts"] = maxi(1, int(raw.get("max_attempts", DEFAULT_MAX_ATTEMPTS)))
	# Where a win skips to. NO_TIME means "stay put and let the round play out", which is the default and
	# what every encounter authored before this did.
	out["win_jump_ms"] = maxi(NO_TIME, int(raw.get("win_jump_ms", NO_TIME)))
	out["win_jump_anchor"] = _one_of(
		str(raw.get("win_jump_anchor", ANCHOR_END)), ANCHORS, ANCHOR_END
	)
	# What the JOURNEY learns from the fight. Advancing past a boss no longer means it was beaten — with
	# replays a player can leave having lost — so each exit carries its own author-named flag rather than
	# the node's blanket set_flags standing in for a result.
	#
	# These have to be listed here like every other field: normalize() builds a FRESH dictionary from the
	# keys it knows, so anything it does not copy is silently dropped on the next pass. That is exactly
	# what happened to both of these — the editor wrote them and the save threw them away.
	for key: String in OUTCOME_FLAG_KEYS:
		out[key] = str(raw.get(key, "")).strip_edges()
	# Regeneration, both forms OFF by default so no encounter gains a mechanic it was not authored with.
	#
	# Pausing is the one slowdown a player can actually perform — scoring runs off the script, not the
	# player (§13.7), so there is no such thing as "going easy" for a rule to read. This is what makes
	# stepping away from a fight cost something.
	out["pause_regen_per_sec"] = maxi(0, int(raw.get("pause_regen_per_sec", 0)))
	# How much of the bar she recovers between attempts, so a replay can escalate rather than only grind.
	out["attempt_regen_pct"] = clampf(float(raw.get("attempt_regen_pct", 0.0)), 0.0, 1.0)
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
		"on": _normalize_on(raw),
		# Which branch of a SEGMENT this event belongs to. Empty means "always plays" — which is what
		# every event authored before segments existed normalizes to, so nothing has to migrate.
		"variant_tag": str(raw.get("variant_tag", "")),
	}
	# The event's own gate. Stored only when it says something: an absent condition always passes, so
	# writing an empty list onto every event would be noise in every saved journey.
	var condition: Dictionary = normalize_condition(raw.get("condition", {}))
	if not condition.is_empty():
		out["condition"] = condition

	match track:
		TRACK_ATTACK:
			_fill_attack(out, raw)
		TRACK_EFFECT:
			out["effects"] = _copy_dict_array(raw.get("effects", []))
			_carry_fades(out, raw)
		TRACK_STANCE:
			out["stance"] = event_stance(raw)
		TRACK_REGION:
			pass  # a region needs only its span and its condition, and every event already carries both
		TRACK_CAST:
			_fill_cast(out, raw)
		TRACK_AUDIO:
			_fill_audio(out, raw)
	# Alternatives ride any track whose CONTENT can be swapped inside a fixed block. An attack's cannot,
	# and briefly could: the swap was invisible everywhere it mattered (the preview skips attacks, the
	# reference curve reads the base event, and TEST ON DEVICE plays the base bundle), and a longer
	# script silently lost its tail because the block's length is what everything else is aligned to.
	#
	# SEGMENTS are how an attack varies, and are strictly better at it. Two attacks on branches of one
	# segment may start together and run for DIFFERENT lengths — are_exclusive() exempts them from the
	# overlap rule — and each branch brings its own telegraph, impact and audio along with it, which is
	# the thing an overlay inside one block structurally cannot do.
	if track == TRACK_CAST or track == TRACK_AUDIO:
		var alts: Array = _normalize_alts(raw)
		if not alts.is_empty():
			out["alts"] = alts
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


## The event's ALTERNATIVES, each a sparse overlay of ALT_FIELDS. Absent or empty stays absent, so a
## timeline authored before variants existed normalizes to exactly what it was.
static func _alt_overlays_nothing(alt: Dictionary) -> bool:
	for key: String in ALT_FIELDS:
		if alt.has(key) and str(alt[key]) != "":
			return false
	return true


static func _normalize_alts(raw: Dictionary) -> Array:
	var out: Array = []
	for entry: Variant in raw.get("alts", []) as Array:
		if not (entry is Dictionary):
			continue
		var alt: Dictionary = {}
		for key: String in ALT_FIELDS:
			if not (entry as Dictionary).has(key):
				continue
			match key:
				"text_y":
					alt[key] = clampf(float((entry as Dictionary)[key]), 0.0, 1.0)
				"text_size":
					alt[key] = clampi(int((entry as Dictionary)[key]), MIN_TEXT_SIZE, MAX_TEXT_SIZE)
				"text_color":
					alt[key] = _to_tint((entry as Dictionary)[key])
				"offset":
					alt[key] = _to_offset((entry as Dictionary)[key])
				"scale":
					alt[key] = maxf(0.01, float((entry as Dictionary)[key]))
				"anchor_pos":
					alt[key] = _one_of(str((entry as Dictionary)[key]), CAST_ANCHORS, ANCHOR_CENTER)
				_:
					alt[key] = str((entry as Dictionary)[key])
		# An overlay of nothing is dropped rather than kept: it is indistinguishable from the base and
		# would silently dilute the odds of everything the author actually wrote. validate() reports it.
		if not alt.is_empty():
			out.append(alt)
	return out


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
	# Listed here as well as on the effect window. It was not, so an audio cue's ease in/out was written
	# by the editor, implemented by BossAudioCues._apply_fades — and thrown away in between by this
	# function, which builds a fresh dictionary from the keys it knows.
	_carry_fades(out, raw)


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


# Health remaining, 0..1, at which a phase takes over: the boss enters it the moment the bar drops to
# or below this, so 1.0 is the opening stage and 0.0 a last stand. Phases are keyed to HEALTH rather than
# to the clock because the bar's divisions are what a player reads the fight's structure from — a phase
# that arrived on a timer while the bar still sat half full contradicted the very thing it explained.
const PHASE_HP_KEY: String = "hp_at"

# Where the health bar and boss name sit down the screen, 0 the top edge and 1 the bottom. Authorable
# because the block is the one piece of chrome a cue cannot be placed over: art that wants the top of
# the frame has nowhere to go while it is nailed there.
const DEFAULT_HP_BAR_Y: float = 0.02

# The two flags an encounter can raise on its way out, one per exit. Named as a set because everything
# that has to know what a fight tells the journey — the round, the builder's flag universe, the auditor
# — should ask rather than hard-code the pair and drift when a third exit appears.
const OUTCOME_FLAG_KEYS: Array[String] = ["won_flag", "lost_flag"]


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
	# Absent means an encounter authored before phases followed health. Its `at_ms` above still places it,
	# and phase_hp_at() converts that once the round's length is known — so nothing has to be re-authored.
	if raw.has(PHASE_HP_KEY) and raw[PHASE_HP_KEY] != null:
		out[PHASE_HP_KEY] = clampf(float(raw[PHASE_HP_KEY]), 0.0, 1.0)
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
## are dropped. `include_outcomes` selects which set comes back — the normal pass excludes everything
## that fires on the way OUT of the round, and each exit path asks for its own.
static func resolved_events(
	timeline: Dictionary, video_duration_ms: int, include_outcomes: bool = false
) -> Array:
	var out: Array = []
	for e: Dictionary in timeline.get("events", []) as Array:
		var is_outcome: bool = str(e.get("on", ON_ALWAYS)) != ON_ALWAYS
		if is_outcome != include_outcomes:
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


## The flag names this encounter can raise, blanks dropped. What a journey can learn from the fight.
static func outcome_flags(timeline: Dictionary) -> Array:
	var out: Array = []
	for key: String in OUTCOME_FLAG_KEYS:
		var flag: String = str(timeline.get(key, "")).strip_edges()
		if flag != "" and not out.has(flag):
			out.append(flag)
	return out


## The encounter's own bar colour, or `fallback` when it never picked one.
##
## This is the BASE of three layers, not the whole story: a stance overrides it while one is in force,
## and a phase tint overrides it for that stage. It is what the bar returns to when neither applies.
static func bar_color(timeline: Dictionary, fallback: Color) -> Color:
	if not timeline.has("bar_color"):
		return fallback
	var t: Dictionary = timeline["bar_color"]
	return Color(
		float(t.get("r", 1.0)),
		float(t.get("g", 1.0)),
		float(t.get("b", 1.0)),
		float(t.get("a", 1.0))
	)


## The health point a phase takes over at, 0..1. An authored phase carries it directly; one written
## before phases followed health is converted from where it sits on the clock, which loses nothing: a
## bar driven by time is exactly the round's progress read backwards.
static func phase_hp_at(phase: Dictionary, video_duration_ms: int) -> float:
	if phase.has(PHASE_HP_KEY):
		return clampf(float(phase[PHASE_HP_KEY]), 0.0, 1.0)
	if video_duration_ms <= 0:
		return 1.0
	var at: int = resolve_at_ms(phase, video_duration_ms)
	if at == NO_TIME:
		return 1.0
	return clampf(1.0 - float(at) / float(video_duration_ms), 0.0, 1.0)


## Phases in play order — full health first — each carrying `resolved_hp_at`, and `resolved_at_ms` for
## anything that still wants to know where a legacy phase sat on the clock.
static func resolved_phases(timeline: Dictionary, video_duration_ms: int) -> Array:
	var out: Array = []
	for p: Dictionary in timeline.get("phases", []) as Array:
		var copy: Dictionary = p.duplicate(true)
		var at: int = resolve_at_ms(p, video_duration_ms)
		copy["resolved_at_ms"] = 0 if at == NO_TIME else at
		copy["resolved_hp_at"] = phase_hp_at(p, video_duration_ms)
		out.append(copy)
	# Descending health: the opening stage first, the last stand last. Ties break on id so the order is
	# stable rather than dependent on however the array happened to be built.
	out.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var a_hp: float = float(a["resolved_hp_at"])
			var b_hp: float = float(b["resolved_hp_at"])
			if not is_equal_approx(a_hp, b_hp):
				return a_hp > b_hp
			return str(a.get("id", "")) < str(b.get("id", ""))
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
			TRACK_REGION:
				# Without a rule a region always plays, which is what the clip does anyway. Worth saying:
				# an author who meant to gate a scene and left the rule blank has authored nothing, and
				# nothing about the block on the lane admits it.
				if condition_clauses(e.get("condition", {})).is_empty():
					issues.append(
						_issue(
							ISSUE_REGION_NO_RULE,
							id,
							(
								"This region has no rule, so it always plays — the same as not "
								+ "marking it at all."
							)
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
		# Checked against the RAW event rather than a normalized one: _normalize_alts drops an empty
		# overlay on save, so by then there is nothing left to report. The author needs telling while the
		# row is still in front of them, not to have it quietly vanish when they hit save.
		for alt: Variant in e.get("alts", []) as Array:
			if not (alt is Dictionary) or _alt_overlays_nothing(alt as Dictionary):
				issues.append(
					_issue(
						ISSUE_ALT_EMPTY,
						id,
						"An alternative here changes nothing, so it would play as the original."
					)
				)
				break
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
	issues.append_array(_segment_issues(timeline))
	issues.append_array(
		_overlap_issues(
			timeline,
			video_duration_ms,
			TRACK_ATTACK,
			ISSUE_ATTACK_OVERLAP,
			"This attack starts before the previous one finishes."
		)
	)
	issues.append_array(
		_overlap_issues(
			timeline,
			video_duration_ms,
			TRACK_STANCE,
			ISSUE_STANCE_OVERLAP,
			(
				"This stance starts before the previous one finishes. Only one can be in force, so "
				+ "the later one simply replaces the earlier."
			)
		)
	)
	return issues


# A segment that cannot choose, or a branch nothing was written for. Both are silent at play time — the
# first always plays its single branch, the second drops every event whenever it is picked — so neither
# looks like a mistake from inside the round.
static func _segment_issues(timeline: Dictionary) -> Array:
	var issues: Array = []
	var used: Dictionary = {}
	for event: Dictionary in timeline.get("events", []) as Array:
		var tag: String = str(event.get("variant_tag", ""))
		if tag != "":
			used[tag] = true
	# A tag names ONE branch of ONE segment across the whole encounter — an event carries only the tag,
	# so a name two segments both claim can only be resolved to the first, and the second segment's
	# choice silently does nothing. Reported rather than repaired: which segment a shared tag's events
	# were meant for is exactly the thing that cannot be recovered once the names have collided.
	var claimed: Dictionary = {}
	for segment: Dictionary in timeline.get("segments", []) as Array:
		var owner_id: String = str(segment.get("id", ""))
		for tag: String in segment_tags(segment):
			if claimed.has(tag) and str(claimed[tag]) != owner_id:
				(
					issues
					. append(
						_issue(
							ISSUE_SEGMENT_TAG_CLASH,
							owner_id,
							(
								(
									'Branch "%s" is also a branch of another segment. Rename it — a branch name '
									% tag
								)
								+ "belongs to one segment, and a shared one leaves this segment unable to "
								+ "pick anything."
							)
						)
					)
				)
			else:
				claimed[tag] = owner_id
	for segment: Dictionary in timeline.get("segments", []) as Array:
		var id: String = str(segment.get("id", ""))
		var tags: Array = segment_tags(segment)
		if tags.size() < 2:
			(
				issues
				. append(
					_issue(
						ISSUE_SEGMENT_THIN,
						id,
						"This segment has fewer than two branches, so there is nothing to choose between."
					)
				)
			)
			continue
		for tag: Variant in tags:
			if not used.has(str(tag)):
				issues.append(
					_issue(
						ISSUE_SEGMENT_DEAD_TAG,
						id,
						'Branch "%s" has no events, so picking it plays nothing at all.' % str(tag)
					)
				)
	return issues


# The override engine holds ONE session (a second request replaces the first), so two attacks that
# overlap would silently cut each other off. Rejecting them at authoring time is clearer than shipping
# an encounter whose attacks eat one another. Only checkable once times resolve, hence the duration gate.
# Windows on ONE lane that must not run at the same time. Attacks cannot, because the override engine
# holds a single session and the later one would cut the earlier short. Stances cannot, because the
# health bar shows one word and two at once has no name.
static func _overlap_issues(
	timeline: Dictionary, video_duration_ms: int, track: String, code: String, message: String
) -> Array:
	if video_duration_ms <= 0:
		return []
	var windows: Array = []
	for e: Dictionary in resolved_events(timeline, video_duration_ms):
		if str(e.get("track", "")) == track:
			windows.append(e)
	# Two windows on different branches of one SEGMENT can never both play, so their blocks are allowed
	# to overlap on the lane — comparing them would put a false error on every segmented encounter. Each
	# is therefore checked against every later one it could actually coexist with, rather than against
	# its immediate neighbour: an excluded window sitting between two real ones must not break the chain
	# and hide a genuine overlap behind it.
	var owner: Dictionary = tag_owners(timeline)
	var issues: Array = []
	var reported: Dictionary = {}
	for i: int in windows.size():
		var prev: Dictionary = windows[i]
		var prev_end: int = int(prev["resolved_at_ms"]) + int(prev.get("duration_ms", 0))
		for j: int in range(i + 1, windows.size()):
			var cur: Dictionary = windows[j]
			if int(cur["resolved_at_ms"]) >= prev_end:
				break  # sorted by time, so nothing after this one can overlap `prev` either
			var id: String = str(cur.get("id", ""))
			if reported.has(id) or are_exclusive(prev, cur, owner):
				continue
			reported[id] = true
			issues.append(_issue(code, id, message))
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
		# An ALTERNATIVE's art and audio are sources like any other. Missing them here would pool the
		# base cue and leave every alternative pointing at the author's own disk — working perfectly on
		# the machine that made the journey and blank on every other one.
		for alt: Dictionary in e.get("alts", []) as Array:
			add.call(str(alt.get("image", "")), MEDIA_IMAGE)
			add.call(str(alt.get("clip", "")), MEDIA_AUDIO)
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
		for alt: Dictionary in e.get("alts", []) as Array:
			if alt.has("image"):
				alt["image"] = mapped.call(str(alt["image"]))
			if alt.has("clip"):
				alt["clip"] = mapped.call(str(alt["clip"]))
	var bgm: Dictionary = out.get("bgm", {})
	if str(bgm.get("clip", "")) != "":
		bgm["clip"] = mapped.call(str(bgm["clip"]))
	return out


## A player-state snapshot with every signal at rest. Callers that have no state yet still evaluate
## against something real rather than against missing keys.
static func empty_state() -> Dictionary:
	return {
		SIGNAL_SCORE: 0,
		SIGNAL_SPM: 0.0,
		SIGNAL_SMALL: 0,
		SIGNAL_MEDIUM: 0,
		SIGNAL_LARGE: 0,
		SIGNAL_ITEMS_USED: 0,
		SIGNAL_LAST_ITEM: "",
		SIGNAL_LAST_ITEM_ID: "",
		SIGNAL_BOSS_HP: 1.0,
		SIGNAL_ATTEMPT: 1,
	}


## A raw condition → `{match, clauses}`, or `{}` when it says nothing. Clauses naming a signal or an
## operator this build does not know are DISCARDED rather than failed closed: a journey authored by a
## later build should degrade to "this fires more often than intended", never to an encounter whose
## events silently stop happening.
##
## A bare list is accepted as the legacy shape and read as match-ALL, which is what it meant.
static func normalize_condition(raw: Variant) -> Dictionary:
	var entries: Array = []
	var match_mode: String = MATCH_ALL
	if raw is Array:
		entries = raw
	elif raw is Dictionary:
		entries = (raw as Dictionary).get("clauses", [])
		match_mode = _one_of(str((raw as Dictionary).get("match", MATCH_ALL)), MATCHES, MATCH_ALL)
	var out: Array = []
	for entry: Variant in entries:
		if not (entry is Dictionary):
			continue
		var clause: Dictionary = entry
		var signal_name: String = str(clause.get("signal", ""))
		var op: String = str(clause.get("op", ""))
		if not SIGNALS.has(signal_name) or not OPS.has(op):
			continue
		var value: Variant = clause.get("value", 0)
		(
			out
			. append(
				{
					"signal": signal_name,
					"op": op,
					"value": str(value) if is_text_signal(signal_name) else float(value),
				}
			)
		)
	return {} if out.is_empty() else {"match": match_mode, "clauses": out}


## The clauses inside a condition, whatever shape it arrived in.
static func condition_clauses(condition: Variant) -> Array:
	if condition is Dictionary:
		return (condition as Dictionary).get("clauses", [])
	return condition if condition is Array else []


## Whether a condition needs every clause or just one of them.
static func condition_match(condition: Variant) -> String:
	if condition is Dictionary:
		return _one_of(str((condition as Dictionary).get("match", MATCH_ALL)), MATCHES, MATCH_ALL)
	return MATCH_ALL


## A condition as a short human sentence — "score < 100", "items_used >= 1". Shared by the timeline
## gutter and the inspector so the rule reads identically wherever an author meets it. An empty
## condition reads as a die, because an unconditioned branch IS the random fork.
static func condition_text(condition: Variant, value_labels: Dictionary = {}) -> String:
	var clauses: Array = condition_clauses(condition)
	if clauses.is_empty():
		return "random"
	var parts: Array = []
	for clause: Dictionary in clauses:
		var signal_name: String = str(clause.get("signal", ""))
		var value: Variant = clause.get("value", 0)
		# `value_labels` turns a stored id into the name an author gave it. Absent, the raw value shows —
		# which is right for numbers and merely terse for an item, never wrong.
		var shown: String = (
			str(value_labels.get(str(value), str(value)))
			if is_text_signal(signal_name)
			else str(snappedf(float(value), 0.01)).trim_suffix(".0")
		)
		parts.append(
			(
				"%s %s %s"
				% [
					signal_label(signal_name),
					op_label(str(clause.get("op", "")), signal_name),
					shown
				]
			)
		)
	# The joiner is the rule, spelled out: "Score < 100 or Strokes Per Minute < 20" needs no key.
	var joiner: String = " or " if condition_match(condition) == MATCH_ANY else " and "
	return joiner.join(PackedStringArray(parts))


static func op_symbol(op: String) -> String:
	match op:
		OP_LT:
			return "<"
		OP_LTE:
			return "<="
		OP_GT:
			return ">"
		OP_GTE:
			return ">="
		OP_NEQ:
			return "!="
	return "="


## Whether a condition holds — every clause under ALL, any one of them under ANY. An empty condition
## always passes, which is what makes conditions back-compatible with everything authored before them.
static func evaluate_condition(condition: Variant, state: Dictionary) -> bool:
	var clauses: Array = condition_clauses(condition)
	if clauses.is_empty():
		return true
	var any_mode: bool = condition_match(condition) == MATCH_ANY
	for clause: Dictionary in clauses:
		if _clause_holds(clause, state):
			if any_mode:
				return true
		elif not any_mode:
			return false
	# Fell through: under ALL nothing failed, under ANY nothing passed.
	return not any_mode


static func _clause_holds(clause: Dictionary, state: Dictionary) -> bool:
	var signal_name: String = str(clause.get("signal", ""))
	var op: String = str(clause.get("op", ""))
	# A name compares only for equality — ordering item kinds or ids is meaningless.
	if is_text_signal(signal_name):
		var actual: String = str(state.get(signal_name, ""))
		var wanted: String = str(clause.get("value", ""))
		if op == OP_NEQ:
			return actual != wanted
		return actual == wanted
	var have: float = float(state.get(signal_name, 0))
	var want: float = float(clause.get("value", 0))
	match op:
		OP_LT:
			return have < want
		OP_LTE:
			return have <= want
		OP_GT:
			return have > want
		OP_GTE:
			return have >= want
		OP_NEQ:
			return not is_equal_approx(have, want)
	return is_equal_approx(have, want)


## One SEGMENT: a named set of mutually exclusive branches, of which exactly one survives a round. A
## segment owns no events — the events name IT, by tag — which is what keeps them flat on their lanes
## and out of a nested container.
static func normalize_segment(raw: Dictionary) -> Dictionary:
	var branches: Array = []
	var seen: Dictionary = {}
	var add := func(tag: String, condition: Variant) -> void:
		var name: String = tag.strip_edges()
		if name == "" or seen.has(name):
			return
		seen[name] = true
		branches.append({"tag": name, "condition": normalize_condition(condition)})
	for entry: Variant in raw.get("branches", []) as Array:
		if entry is Dictionary:
			add.call(
				str((entry as Dictionary).get("tag", "")),
				(entry as Dictionary).get("condition", [])
			)
	# Legacy shape: a bare list of tag names, from before a branch could carry a condition.
	for tag: Variant in raw.get("tags", []) as Array:
		add.call(str(tag), [])
	return {"id": _id_or_new(raw, "seg"), "name": str(raw.get("name", "")), "branches": branches}


## Just the branch names, for the callers that only care which tags exist.
static func segment_tags(segment: Dictionary) -> Array:
	var out: Array = []
	for branch: Dictionary in segment.get("branches", []) as Array:
		out.append(str(branch.get("tag", "")))
	return out


## Which branch of  plays, given what the player is doing right now.
##
## A CONDITIONED branch wins if its predicate holds, in author order — so the specific cases are written
## first and the general one last, the way anyone writes a set of rules. Whatever is left unconditioned
## is the pool a dice roll picks from, which is how a segment with no conditions at all stays exactly the
## random fork Phase 5 shipped. If every branch is conditioned and none holds, the FIRST is played:
## never nothing, because a fork that silently drops its whole move looks identical to a bug.
static func choose_branch(
	segment: Dictionary, state: Dictionary, rng: RandomNumberGenerator
) -> String:
	var branches: Array = segment.get("branches", [])
	if branches.is_empty():
		return ""
	var ruled: String = matched_branch(segment, state)
	if ruled != "":
		return ruled
	var open_pool: Array = unconditioned_branches(segment)
	if open_pool.is_empty():
		return str((branches[0] as Dictionary).get("tag", ""))
	return str(open_pool[rng.randi_range(0, open_pool.size() - 1)])


## Steps the encounter to its NEXT combination of branches and alternatives, as
## `{segments: {...}, variants: {...}}`. What the editor's CYCLE walks.
##
## An ODOMETER, not lockstep: the first dial that can move does, and only when it wraps does the next
## one advance. Stepping every dial together would march them in formation and never reach a mixed
## combination — two two-branch segments would show AA and BB and never AB.
##
## Two kinds of dial are SKIPPED, and both pass the carry straight through rather than absorbing it:
## a segment with fewer than two branches has nothing to step, and one whose branch the RULES decide is
## not the cycle's to move. Absorbing the carry was a real bug — the first conditioned segment became a
## wall, and nothing after it could ever be reached.
##
## Pure so the stepping is testable: the editor owns the picks, this owns the arithmetic.
static func next_combination(
	timeline: Dictionary, segment_picks: Dictionary, variant_picks: Dictionary, state: Dictionary
) -> Dictionary:
	var segments_out: Dictionary = segment_picks.duplicate()
	var variants_out: Dictionary = variant_picks.duplicate()

	# Every segment starts on its FIRST branch unless a pick already says otherwise. The editor seeds
	# this itself before it ever cycles, but a pure function must not depend on the caller having done
	# so — left unseeded, a dial further down the odometer stays unset until a carry happens to reach
	# it, and the sequence never closes back on where it began.
	for segment: Dictionary in timeline.get("segments", []) as Array:
		var seed_tags: Array = segment_tags(segment)
		var seed_id: String = str(segment.get("id", ""))
		if seed_tags.size() >= 2 and not segments_out.has(seed_id):
			segments_out[seed_id] = str(seed_tags[0])

	var carry: bool = true

	for segment: Dictionary in timeline.get("segments", []) as Array:
		if not carry:
			break
		var tags: Array = segment_tags(segment)
		if tags.size() < 2 or matched_branch(segment, state) != "":
			continue
		var id: String = str(segment.get("id", ""))
		# A segment with no pick yet is treated as sitting on its FIRST branch, which is where the editor
		# defaults it. Letting find() return -1 stand would make `next` 0 — so the first press would
		# re-select the branch already showing, and the whole cycle would run one press behind.
		var current: int = maxi(0, tags.find(str(segments_out.get(id, ""))))
		var next: int = current + 1
		segments_out[id] = str(tags[next % tags.size()])
		carry = next >= tags.size()

	for event: Dictionary in timeline.get("events", []) as Array:
		if not carry:
			break
		var alts: Array = event.get("alts", [])
		if alts.is_empty():
			continue
		# Index 0 is the base cue, so the dial has alts + 1 positions.
		var positions: int = alts.size() + 1
		var event_id: String = str(event.get("id", ""))
		var step: int = int(variants_out.get(event_id, 0)) + 1
		variants_out[event_id] = step % positions
		carry = step >= positions

	return {"segments": segments_out, "variants": variants_out}


## The first branch whose rule HOLDS, or "" when none does. Split out of choose_branch so the editor can
## ask the deterministic half of the question — which branch the rules pick for a given player — without
## a dice roll answering the rest of it on the editor's behalf.
static func matched_branch(segment: Dictionary, state: Dictionary) -> String:
	for branch: Dictionary in segment.get("branches", []) as Array:
		var condition: Variant = branch.get("condition", {})
		if condition_clauses(condition).is_empty():
			continue
		if evaluate_condition(condition, state):
			return str(branch.get("tag", ""))
	return ""


## The branches carrying no rule — the pool a roll picks from once the rules have had their say.
static func unconditioned_branches(segment: Dictionary) -> Array:
	var out: Array = []
	for branch: Dictionary in segment.get("branches", []) as Array:
		if condition_clauses(branch.get("condition", {})).is_empty():
			out.append(str(branch.get("tag", "")))
	return out


## Picks one surviving tag per segment, as `{segment_id: tag}`. Unlike an event's alternatives there is
## no implicit "base" candidate: a segment IS its list of branches, and each was written on purpose.
static func roll_segments(timeline: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var picks: Dictionary = {}
	for segment: Dictionary in timeline.get("segments", []) as Array:
		if segment_tags(segment).size() < 2:
			continue  # nothing to choose between; validate() reports it
		picks[str(segment.get("id", ""))] = choose_branch(segment, empty_state(), rng)
	return picks


## A copy of `timeline` holding only the events that survived their segment. An event is dropped when
## its tag belongs to a segment that chose a DIFFERENT branch. An untagged event always survives, and so
## does one whose tag no segment claims — an unrecognised tag must never silently delete an author's
## work, which is the failure mode that would be hardest to notice.
static func apply_segments(timeline: Dictionary, picks: Dictionary) -> Dictionary:
	if picks.is_empty():
		return timeline
	var owner: Dictionary = tag_owners(timeline)
	var out: Dictionary = timeline.duplicate(true)
	var kept: Array = []
	for event: Dictionary in out.get("events", []) as Array:
		var tag: String = str(event.get("variant_tag", ""))
		if tag == "" or not owner.has(tag):
			kept.append(event)
			continue
		var segment_id: String = str(owner[tag])
		if not picks.has(segment_id) or str(picks[segment_id]) == tag:
			kept.append(event)
	out["events"] = kept
	return out


## `{tag: segment_id}` for every tag a segment claims. A tag claimed twice belongs to the first segment:
## the alternative is undefined exclusivity, which would make the overlap check below unsound.
static func tag_owners(timeline: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for segment: Dictionary in timeline.get("segments", []) as Array:
		for tag: String in segment_tags(segment):
			if not out.has(tag):
				out[tag] = str(segment.get("id", ""))
	return out


## True when two events can never both play, being different branches of one segment.
static func are_exclusive(a: Dictionary, b: Dictionary, owner: Dictionary) -> bool:
	var tag_a: String = str(a.get("variant_tag", ""))
	var tag_b: String = str(b.get("variant_tag", ""))
	if tag_a == "" or tag_b == "" or tag_a == tag_b:
		return false
	return owner.has(tag_a) and owner.has(tag_b) and str(owner[tag_a]) == str(owner[tag_b])


## Chooses one candidate per event carrying alternatives, as `{event_id: index}` — index 0 is the BASE
## event, 1..n its alts. The base is deliberately in the pool: writing two alternatives means three
## possible lines, which is what an author expects from the word.
##
## Rolled ONCE per round entry and then held, so a cue that replays inside an encounter stays consistent.
## `rng` is injected rather than global so tests are deterministic and a reload can reproduce a run.
static func roll_variants(timeline: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var picks: Dictionary = {}
	for event: Dictionary in timeline.get("events", []) as Array:
		var alts: Array = event.get("alts", [])
		if alts.is_empty():
			continue
		picks[str(event.get("id", ""))] = rng.randi_range(0, alts.size())
	return picks


## A copy of `timeline` with each event's chosen alternative BAKED IN. Everything downstream — the
## scheduler, the cue layer, the device — then sees ordinary events and needs no knowledge of variants
## at all, which is why this happens once at round start rather than at every dispatch.
static func apply_variants(timeline: Dictionary, picks: Dictionary) -> Dictionary:
	if picks.is_empty():
		return timeline
	var out: Dictionary = timeline.duplicate(true)
	var events: Array = out.get("events", [])
	for i: int in events.size():
		var event: Dictionary = events[i]
		events[i] = apply_variant(event, int(picks.get(str(event.get("id", "")), 0)))
	return out


## One event with alternative `index` applied — 0 (or anything out of range) leaves it untouched. The
## `alts` list is stripped from the result: once a choice is baked, carrying the others would only
## invite something downstream to choose again.
static func apply_variant(event: Dictionary, index: int) -> Dictionary:
	var alts: Array = event.get("alts", [])
	if alts.is_empty():
		return event
	var out: Dictionary = event.duplicate(true)
	out.erase("alts")
	if index <= 0 or index > alts.size():
		return out
	var alt: Dictionary = alts[index - 1]
	for key: Variant in alt:
		out[str(key)] = alt[key]
	# A chosen line that sets no colour must not inherit the base line's, or an author who wrote one
	# coloured alternative would find every other candidate silently tinted to match it.
	if alt.has("text") and not alt.has("text_color"):
		out.erase("text_color")
	# Same shape, and the reason the alternative's picture never appeared: a cue naming a CHARACTER
	# resolves its art from that character's portrait and only falls back to `image`, in both the round
	# and the preview. An alternative bringing its own art therefore has to drop the inherited character,
	# or the portrait wins the lookup and the alternative silently draws the original.
	#
	# Setting `portrait` instead is untouched — that IS the character's art, and needs the character.
	if str(alt.get("image", "")) != "":
		out.erase("character_id")
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


## Where a boss's accumulated damage lives, namespaced by the node it belongs to.
##
## A GameState counter, so it rides save data for free and a half-beaten boss survives a save/quit. The
## node id keeps two bosses in one journey from sharing a health pool, and the `boss_hp:` prefix keeps it
## out of the way of anything an author named themselves — this is bookkeeping, not a counter they wrote.
static func damage_counter_key(node_id: String) -> String:
	return "boss_hp:%s" % node_id


## Which pass the player is on, kept beside the damage and for the same reasons.
static func attempt_counter_key(node_id: String) -> String:
	return "boss_try:%s" % node_id


## True when this encounter is a FIGHT — one the player can fail and be given another pass at — rather
## than a round that simply plays through.
static func allows_replay(timeline: Dictionary) -> bool:
	return (
		str(timeline.get("hp_source", HP_TIME)) == HP_SCORE
		and int(timeline.get("max_attempts", DEFAULT_MAX_ATTEMPTS)) > 1
	)


## What a full, uninterrupted pass of a round is worth — the score its funscript will deal on its own.
##
## Deterministic, and that is the point: scoring happens as the SCRIPT advances (FunscriptPlayer
## .ProcessKeyframe calls AddStroke per keyframe pair), not from anything the player does. So this is
## not an estimate of a good run — it is exactly what the round deals every time, and what an author
## should size `damage_target` against.
##
## `scoring` carries the thresholds from ScoreService rather than repeating them here, so retuning the
## score cannot silently invalidate every boss an author has already balanced.
## Effects are ignored: items and damage windows are what MOVE a fight off this number.
static func expected_pass_score(points: Array, scoring: Dictionary) -> int:
	if points.size() < 2:
		return 0
	var small_max: int = int(scoring.get("small_max", 20))
	var medium_max: int = int(scoring.get("medium_max", 70))
	var small_pts: int = int(scoring.get("small_pts", 1))
	var medium_pts: int = int(scoring.get("medium_pts", 3))
	var large_pts: int = int(scoring.get("large_pts", 5))
	var total: int = 0
	for i: int in points.size() - 1:
		var amplitude: int = int(absf((points[i + 1] as Vector2).y - (points[i] as Vector2).y))
		if amplitude <= small_max:
			total += small_pts
		elif amplitude <= medium_max:
			total += medium_pts
		else:
			total += large_pts
	return total


## Where a win jumps the clip to, resolved against the round's length — or NO_TIME when the author set
## no jump, or set one that cannot be placed.
##
## END-anchored by default because the useful jump is "skip to the finale", which is a distance from the
## end rather than a position from the start; an author who moves the clip keeps the ending they meant.
static func win_jump_at_ms(timeline: Dictionary, video_duration_ms: int) -> int:
	var at: int = int(timeline.get("win_jump_ms", NO_TIME))
	if at == NO_TIME:
		return NO_TIME
	return resolve_at_ms(
		{"at_ms": at, "anchor": str(timeline.get("win_jump_anchor", ANCHOR_END))}, video_duration_ms
	)


## What a stance does to incoming damage. Unknown names read as NORMAL rather than as zero: a typo must
## never silently make a boss invincible.
static func stance_mult(stance: String) -> float:
	match stance:
		STANCE_GUARDED:
			return 0.5
		STANCE_IMMUNE, STANCE_ATTACKING:
			return 0.0
		STANCE_VULNERABLE:
			return 2.0
		STANCE_RECOVERING:
			return -0.5
	return 1.0


## The word the health bar shows for a stance.
static func stance_label(stance: String) -> String:
	match stance:
		STANCE_GUARDED:
			return "GUARDING"
		STANCE_IMMUNE:
			return "IMMUNE"
		STANCE_VULNERABLE:
			return "VULNERABLE"
		STANCE_RECOVERING:
			return "RECOVERING"
		STANCE_ATTACKING:
			return "ATTACKING"
	return "NORMAL"


## The stance an event declares, falling back to NORMAL for anything unrecognised.
static func event_stance(event: Dictionary) -> String:
	return _one_of(str(event.get("stance", STANCE_NORMAL)), STANCES, STANCE_NORMAL)


## The stance in force, given every stance window currently open. NORMAL when none is.
##
## Validation holds stances to one at a time, so this is nearly always a set of one. When an author has
## overlapped them anyway the LAST to open wins — deterministic, and it matches what the timeline looks
## like, where a later block is drawn over an earlier one.
static func active_stance(windows: Array) -> String:
	var stance: String = STANCE_NORMAL
	for window: Dictionary in windows:
		stance = event_stance(window)
	return stance


## How full the boss health bar should be, 0..1, for a timeline showing  against its target. The
## caller supplies both numbers, so this stays pure and the same maths serves the round and the preview.
static func damage_fraction(timeline: Dictionary, score: int) -> float:
	var target: int = maxi(1, int(timeline.get("damage_target", DEFAULT_DAMAGE_TARGET)))
	return clampf(float(score) / float(target), 0.0, 1.0)


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
