class_name JourneyData
extends RefCounted

# ---------------------------------------------------------------------------
# JourneyData
# Pure-data helpers for the journey-builder model. No UI. Stateless static-
# style methods that take and return plain Dictionaries / Arrays.
#
# The "model" is a flat Array of item dicts where each item is one of:
#   { type: "round",      name, funscript_path, video_path, coins }
#   { type: "shop",       title, mode, count, items, price_multiplier }
#   { type: "storyboard", coins, image, lines }
#   { type: "fork",       title, description, paths: [ {name, description, image_path, items: [...]} ] }
# Nested forks are stored inside a path's `items` array (recursive).
#
# Used by JourneyBuilder.gd via class-name calls:
#   JourneyData.parse_journey(j)            – inflate from saved JSON dict
#   JourneyData.validate(items, name)       – returns "" or first error
#   JourneyData.find_video_in_round(folder) – first video file in a folder
# ---------------------------------------------------------------------------

const DIFFICULTIES: Array = ["Easy", "Medium", "Hard", "Very Hard", "Extreme", "Insane"]

const VIDEO_EXTENSIONS: Array[String] = ["mp4", "m4v", "mkv", "avi", "mov", "wmv", "webm"]
const FUNSCRIPT_EXTENSIONS: Array[String] = ["funscript", "json"]
const IMAGE_EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "webp", "gif"]

# What the IN-GAME image slots accept (boss image, storyboard default + speaker, fork card): stills
# plus anything the builder can bake to a looping H.264. Past the input filter there's no
# difference — a GIF is converted to exactly what an .mp4 already is.
#
# Deliberately NOT merged into IMAGE_EXTENSIONS: that list also drives the journey COVER and the
# canvas / side-panel drop handlers, where a dropped .mp4 already means "bulk-import rounds"
# (VIDEO_EXTENSIONS). Adding video there would make those drops ambiguous. The cover stays on
# IMAGE_EXTENSIONS: dropping a movie on it is far likelier a slip than intent.
const ANIMATED_IMAGE_EXTENSIONS: Array[String] = [
	"png", "jpg", "jpeg", "webp", "gif", "apng", "mp4", "m4v", "webm", "mkv", "mov"
]

# Bake ceilings for animated images, per surface (see MediaPoolService.bake_animation). Roughly 2x
# the on-screen size, so UI scaling has headroom without paying for pixels nobody can see — a 1080p
# GIF dropped into the 380x240 boss slot is ~20x more than is ever displayed. Never upscales: a
# smaller source is baked at its own size.
const ANIM_CAP_BOSS: Vector2i = Vector2i(760, 480)  # displayed at 380x240
const ANIM_CAP_FORK: Vector2i = Vector2i(440, 720)  # fork cards are 220x360
const ANIM_CAP_STORYBOARD: Vector2i = Vector2i(1920, 1080)  # fullscreen background
const ANIM_CAP_PORTRAIT: Vector2i = Vector2i(720, 1080)  # VN cast portrait; tall, bottom-anchored, ~half-screen
# The cover never animates (it sits in the catalogue grid), but a GIF cover still has to be
# converted to a still PNG — Godot can't read GIF. Generous: an ordinary PNG/JPG cover isn't
# downscaled at all, so this only exists to stop an absurd source, and it never upscales.
const ANIM_CAP_COVER: Vector2i = Vector2i(2048, 2048)

# Secondary T-code axes supported for serial devices (L0 = main stroke, handled separately).
const EXTRA_AXES: Array[String] = ["L1", "L2", "R0", "R1", "R2"]

# Standard funscript multi-axis / vibrator suffixes, keyed by our internal channel
# id. Used to name pooled channel scripts (content/m_<fp>.<suffix>.funscript) so the
# pooled files stay self-describing and follow the funscript multi-axis convention.
const AXIS_SUFFIXES: Dictionary = {
	"L1": "surge",
	"L2": "sway",
	"R0": "twist",
	"R1": "roll",
	"R2": "pitch",
}
const VIB_SUFFIXES: Dictionary = {
	"vib1": "vibe1",
	"vib2": "vibe2",
}

# restim (E-Stim Full) parameter scripts, keyed by restim T-code axis → funscript name suffix.
# These have no serial/motion equivalent, so they stream to restim only. (alpha/beta are NOT
# here — they map to the L0 main / L1 surge slots so they also drive serial, like position.)
const ESTIM_SUFFIXES: Dictionary = {
	"V0": "volume",
	"C0": "carrier_frequency",
	"P0": "pulse_frequency",
	"P1": "pulse_width",
	"P2": "pulse_interval_random",
	"P3": "pulse_rise_time",
	"V1": "vib1_frequency",
	"V2": "vib1_strength",
	"V3": "vib1_random",
	"V4": "vib2_frequency",
	"V5": "vib2_strength",
	"V6": "vib1_left_right_bias",
	"V7": "vib1_up_down_bias",
	"V8": "vib2_left_right_bias",
	"V9": "vib2_up_down_bias",
	"W1": "vib2_random",
}

# Curse catalog — the GAMEPLAY afflictions a cursed round can apply (they change
# the device output, the economy, or the controls). Non-gameplay visual/audio
# effects live in SENSORY_CATALOG below. Single source of truth shared by the
# builder (curse picker) and GameLoop (rolling/applying). Each entry is a
# boss-modifier-shaped dict: stroke curses (scale/clamp/reverse/block) are applied
# by FunscriptPlayer; the rest (coin_penalty/toll/hud_hide/no_pause) by GameLoop.
# "name" is the unique id used to select.
const CURSE_CATALOG: Array = [
	{
		"kind": "scale",
		"factor": 0.6,
		"name": "Shrunken",
		"desc": "Strokes shortened to 60% of their length."
	},
	{
		"kind": "clamp",
		"min": 40,
		"max": 60,
		"name": "Choked",
		"desc": "Strokes confined to the middle of the range."
	},
	{
		"kind": "clamp",
		"min": 0,
		"max": 45,
		"name": "Sunken",
		"desc": "Strokes confined to the bottom of the range."
	},
	{"kind": "reverse", "name": "Inverted", "desc": "Up and down are flipped."},
	{"kind": "block", "name": "Numbed", "desc": "The device ignores the script entirely."},
	{
		"kind": "coin_penalty",
		"factor": 0.5,
		"name": "Greed",
		"desc": "Coins earned this round are halved."
	},
	{
		"kind": "coin_penalty",
		"factor": 0.0,
		"name": "Pauper",
		"desc": "No coins are earned this round."
	},
	{"kind": "toll", "amount": 40, "name": "Toll", "desc": "Lose 40 coins immediately."},
	{"kind": "hud_hide", "name": "Fog", "desc": "The HUD is hidden for the whole round."},
	{"kind": "no_pause", "name": "Restless", "desc": "You can't pause this round."},
]

# Non-gameplay (sensory) modifiers — purely visual/audio; they don't touch the
# device, economy, or controls. Authors can add these to cursed or boss rounds
# (the "Non-gameplay modifiers" picker), and a cursed round can optionally let
# them into its random pool. Single-sourced here; GameLoop applies every kind via
# its hex pipeline (_apply_hex), and Blinded rides the active-effect chip scan.
# Each entry with an adjustable intensity carries imin/imax/idef: a per-round
# slider edits a normalized intensity (0–1), and the real effect value is
# lerp(imin, imax, intensity). imin may exceed imax for "inverted" effects where
# a stronger result is a lower number (pixelate blocks, strobe interval, low-pass
# cutoff, tunnel ramp). idef reproduces the current default value. Binary effects
# (Blinded, Silence) carry no intensity fields → no slider.
const SENSORY_CATALOG: Array = [
	# Visibility / audio deniers.
	{
		"kind": "blackout",
		"name": "Blinded",
		"desc": "The video is hidden — the device plays on in the dark."
	},
	{
		"kind": "murk",
		"name": "Murk",
		"desc": "The screen is dimmed.",
		"imin": 0.40,
		"imax": 0.95,
		"idef": 0.58
	},
	{
		"kind": "tunnel",
		"name": "Tunnel",
		"desc": "Vision closes to a narrow tunnel.",
		"imin": 0.60,
		"imax": 0.20,
		"idef": 0.38
	},
	{
		"kind": "strobe",
		"name": "Strobe",
		"desc": "The screen fades to black and back every few seconds.",
		"imin": 5.0,
		"imax": 1.0,
		"idef": 0.50
	},
	{"kind": "mute", "name": "Silence", "desc": "The audio is muted."},
	# Per-pixel video effects (one composable shader on the video).
	{
		"kind": "grayscale",
		"name": "Drained",
		"desc": "Color is drained from the video.",
		"imin": 0.40,
		"imax": 1.00,
		"idef": 1.00
	},
	{
		"kind": "blur",
		"name": "Bleary",
		"desc": "The video blurs out of focus.",
		"imin": 1.0,
		"imax": 6.0,
		"idef": 0.30
	},
	{
		"kind": "pixelate",
		"name": "Censored",
		"desc": "The video is pixelated.",
		"imin": 160.0,
		"imax": 30.0,
		"idef": 0.54
	},
	{
		"kind": "invert",
		"name": "Negative",
		"desc": "The video's colors are inverted.",
		"imin": 0.40,
		"imax": 1.00,
		"idef": 1.00
	},
	{
		"kind": "sepia",
		"name": "Faded",
		"desc": "The video washes out to sepia.",
		"imin": 0.40,
		"imax": 1.00,
		"idef": 1.00
	},
	{
		"kind": "posterize",
		"name": "Banded",
		"desc": "The video's colors crush into harsh bands.",
		"imin": 10.0,
		"imax": 3.0,
		"idef": 0.71
	},
	{
		"kind": "saturate",
		"name": "Feverish",
		"desc": "The video's colors run hot and oversaturated.",
		"imin": 1.4,
		"imax": 3.5,
		"idef": 0.38
	},
	{
		"kind": "chromatic",
		"name": "Fracture",
		"desc": "The video's colors split apart.",
		"imin": 0.002,
		"imax": 0.020,
		"idef": 0.22
	},
	{
		"kind": "wave",
		"name": "Swoon",
		"desc": "The video ripples and sways.",
		"imin": 0.003,
		"imax": 0.020,
		"idef": 0.29
	},
	# Overlay-node visual effects.
	{
		"kind": "bloodshot",
		"name": "Bloodshot",
		"desc": "A red haze pulses over the screen.",
		"imin": 0.50,
		"imax": 1.00,
		"idef": 1.00
	},
	{
		"kind": "static",
		"name": "Interference",
		"desc": "Static crawls across the screen.",
		"imin": 0.12,
		"imax": 0.50,
		"idef": 0.47
	},
	{
		"kind": "flicker",
		"name": "Flicker",
		"desc": "The screen flickers erratically.",
		"imin": 0.50,
		"imax": 1.20,
		"idef": 0.71
	},
	{
		"kind": "tremor",
		"name": "Tremor",
		"desc": "The screen shakes.",
		"imin": 3.0,
		"imax": 18.0,
		"idef": 0.40
	},
	# Audio-bus effects.
	{
		"kind": "lowpass",
		"name": "Muffled",
		"desc": "The audio is muffled, as if underwater.",
		"imin": 2200.0,
		"imax": 300.0,
		"idef": 0.79
	},
	{
		"kind": "reverb",
		"name": "Cavern",
		"desc": "The audio echoes in a vast space.",
		"imin": 0.30,
		"imax": 0.90,
		"idef": 0.50
	},
	{
		"kind": "distort",
		"name": "Distorted",
		"desc": "The audio is distorted and harsh.",
		"imin": 0.20,
		"imax": 0.90,
		"idef": 0.43
	},
	{
		"kind": "volwobble",
		"name": "Faltering",
		"desc": "The audio swells and fades.",
		"imin": -10.0,
		"imax": -40.0,
		"idef": 0.47
	},
]

# The SENSORY_CATALOG kinds that are audio (everything else is visual). Used to
# split the "Non-gameplay modifiers" picker into Visual / Audio subsections.
const AUDIO_SENSORY_KINDS: Array = ["mute", "lowpass", "reverb", "distort", "volwobble"]

# Boon catalog — the blessings a blessed round can apply. Like CURSE_CATALOG, but
# positive. score_multiplier/coin_jackpot/scale ride existing effect kinds;
# gift/ward/lingering/interest are applied by GameLoop.
const BLESSING_CATALOG: Array = [
	{
		"kind": "score_multiplier",
		"factor": 2.0,
		"name": "Fervor",
		"desc": "Double score this round."
	},
	{
		"kind": "coin_jackpot",
		"factor": 2.0,
		"name": "Fortune",
		"desc": "Double the coins earned this round."
	},
	{"kind": "scale", "factor": 1.35, "name": "Surge", "desc": "Stronger, longer strokes."},
	{"kind": "gift", "name": "Gift", "desc": "Start the round holding a free item."},
	{
		"kind": "lingering",
		"name": "Lingering",
		"desc": "Your active item effects don't run out this round."
	},
	{
		"kind": "interest",
		"pct": 0.25,
		"name": "Interest",
		"desc": "Gain coins equal to 25% of your balance."
	},
]

# ── Effect rounds (unified cursed/blessed) ───────────────────────────────────
# An Effect Round applies a mix of gameplay effects (hindrances and/or boons) plus
# an optional always-on sensory layer, framed by author-set visuals (border colour,
# card accent, header text, icon glyph — no theme indirection), with an optional
# "resolvable" layer (pay to cleanse / endure for a reward). It replaces the retired
# cursed/blessed round types; legacy rounds migrate via normalize_effect_round (below)
# on load and re-save.

# Default effect-round colours (concrete hex, so every effect round carries real values).
# New rounds get the neutral look; migrated legacy rounds keep their old colour + label.
const EFFECT_COLOR_NEUTRAL: String = "#99bfff"  # cool blue
const EFFECT_COLOR_HINDER: String = "#73f24d"  # toxic green (old cursed)
const EFFECT_COLOR_BOON: String = "#ffd64d"  # gold (old blessed)


# The gameplay effects an Effect Round can apply: the hindrance (negative) and boon
# (positive) catalogs merged. Sensory modifiers are a separate always-apply layer
# (SENSORY_CATALOG) with their own picker + intensity — not part of this list.
static func gameplay_effects() -> Array:
	return CURSE_CATALOG + BLESSING_CATALOG


# True when `name` is a positive (boon) effect — drives the green-vs-red chip / card colour.
static func effect_is_benefit(name: String) -> bool:
	for e: Dictionary in BLESSING_CATALOG:
		if str(e.get("name", "")) == name:
			return true
	return false


# Looks up an effect entry by name across every catalog (gameplay + sensory). {} if unknown.
static func effect_entry(name: String) -> Dictionary:
	for cat: Array in [CURSE_CATALOG, BLESSING_CATALOG, SENSORY_CATALOG]:
		for e: Dictionary in cat:
			if str(e.get("name", "")) == name:
				return e
	return {}


# True when `kind` is a sensory (visual/audio) effect. Sensory effects are keyed by kind in item
# bundles and applied through SensoryFX; the gameplay/stroke item kinds are keyed by kind too but
# reconciled by their own consumers.
static func is_sensory_kind(kind: String) -> bool:
	return not sensory_entry_by_kind(kind).is_empty()


# The SENSORY_CATALOG entry for a kind (carries name + imin/imax/idef intensity range). {} if none.
static func sensory_entry_by_kind(kind: String) -> Dictionary:
	for e: Dictionary in SENSORY_CATALOG:
		if str(e.get("kind", "")) == kind:
			return e
	return {}


# Stroke-modifier kinds — these change the funscript curve, so their magnitude is tuned
# live in the funscript preview (where the author can watch the strokes), not the side
# panel. reverse/block are stroke kinds but carry no magnitude.
const STROKE_EFFECT_KINDS: Array = ["scale", "clamp", "reverse", "block"]


static func is_stroke_effect(kind: String) -> bool:
	return kind in STROKE_EFFECT_KINDS


# The tunable numeric parameter(s) for an effect kind, each a spec the authoring controls
# read: {key, label, ctl, min, max, step}. `ctl` picks the control style — "pct" (0–1 shown
# as %), "mult" (× multiplier), "coins" (whole coins), "pos" (0–100 stroke position). Empty
# for binary kinds (reverse/block/hud_hide/no_pause/gift/lingering).
static func effect_param_specs(kind: String) -> Array:
	match kind:
		"scale":
			return [
				{
					"key": "factor",
					"label": "Stroke length",
					"ctl": "pct",
					"min": 0.1,
					"max": 2.0,
					"step": 0.05
				}
			]
		"clamp":
			return [
				{"key": "min", "label": "Range min", "ctl": "pos", "min": 0, "max": 100, "step": 1},
				{"key": "max", "label": "Range max", "ctl": "pos", "min": 0, "max": 100, "step": 1},
			]
		"coin_penalty":
			return [
				{
					"key": "factor",
					"label": "Coins kept",
					"ctl": "pct",
					"min": 0.0,
					"max": 1.0,
					"step": 0.05
				}
			]
		"coin_jackpot":
			return [
				{
					"key": "factor",
					"label": "Coin ×",
					"ctl": "mult",
					"min": 1.0,
					"max": 10.0,
					"step": 0.25
				}
			]
		"score_multiplier":
			return [
				{
					"key": "factor",
					"label": "Score ×",
					"ctl": "mult",
					"min": 1.0,
					"max": 10.0,
					"step": 0.25
				}
			]
		"toll":
			return [
				{
					"key": "amount",
					"label": "Coins taken",
					"ctl": "coins",
					"min": 0,
					"max": 100000,
					"step": 5
				}
			]
		"interest":
			return [
				{
					"key": "pct",
					"label": "Balance %",
					"ctl": "pct",
					"min": 0.0,
					"max": 1.0,
					"step": 0.05
				}
			]
		_:
			return []


# A catalog effect entry merged with the round's per-effect override diff. `overrides` is the
# round's effect_overrides map (name → {changed params/name/desc}); only present keys win, so
# untouched params keep the catalog default. Stamps `_ref` = the original catalog name so
# valence (effect_is_benefit) and re-lookup still work after a custom rename. {} if unknown.
# The catalog entries a round actually ticked, in catalog order. Shared by the runtime and the
# builder's live sensory preview.
static func catalog_subset(catalog: Array, names: Array) -> Array:
	var out: Array = []
	for entry: Dictionary in catalog:
		if entry.get("name", "") in names:
			out.append(entry)
	return out


static func resolved_effect(name: String, overrides: Dictionary) -> Dictionary:
	var base: Dictionary = effect_entry(name)
	if base.is_empty():
		return {}
	var out: Dictionary = base.duplicate(true)
	var ov: Dictionary = overrides.get(name, {})
	for k: String in ov:
		out[k] = ov[k]
	out["_ref"] = name
	return out


# All names in `catalog`, in order. Used to bake a legacy round's "empty = full random
# pool" into an explicit effects list at migration, so the roll scope (hindrances-only /
# boons-only) survives the drop of the theme concept.
static func _catalog_names(catalog: Array) -> Array:
	var out: Array = []
	for e: Dictionary in catalog:
		out.append(str(e.get("name", "")))
	return out


static func _nonblank(value: String, fallback: String) -> String:
	return value if value != "" else fallback


# Canonical Effect-Round field set + legacy migration. Given any round-shaped dict that
# carries either the new generic fields (round_type "effect") or the retired cursed/blessed
# schema, returns the fully-typed generic effect fields (visuals always concrete). Non-effect
# rounds (normal/boss) pass their round_type through and still receive defaulted effect fields.
#
# This is the single migration point: coerce_node_save_data merges it in on SAVE (so re-saving
# a legacy journey rewrites it as generic — "migrate on next save"), and the runtime / scanners
# merge it in on LOAD (so an un-re-saved legacy journey still plays). Pure → unit-tested.
static func normalize_effect_round(src: Dictionary) -> Dictionary:
	var rtype: String = str(src.get("round_type", "normal")).to_lower()
	var effects: Array = []
	var effect_random: bool
	var resolvable: bool
	var endure_reward: int
	var frame_color: String
	var card_accent: String
	var card_header: String
	var card_icon: String
	var show_border: bool

	match rtype:
		"cursed":
			var curses: Array = src.get("curses", [])
			if curses.is_empty():
				effects = _catalog_names(CURSE_CATALOG)  # was "empty = full curse pool"
			else:
				for n: Variant in curses:
					effects.append(str(n))
			effect_random = bool(src.get("curse_random", true))
			resolvable = true
			endure_reward = int(src.get("curse_reward", 0))
			frame_color = EFFECT_COLOR_HINDER
			card_accent = EFFECT_COLOR_HINDER
			card_header = "CURSED"
			card_icon = "☠"
			show_border = true  # legacy cursed rounds had a frame — keep it (tint-free now)
			rtype = "effect"
		"blessed":
			for n: Variant in src.get("boons", []):
				if str(n) != "Ward":  # retired boon — dropped on migration
					effects.append(str(n))
			if effects.is_empty():
				effects = _catalog_names(BLESSING_CATALOG)  # was "empty = full boon pool"
			effect_random = bool(src.get("boon_random", true))
			resolvable = false
			endure_reward = 0
			frame_color = EFFECT_COLOR_BOON
			card_accent = EFFECT_COLOR_BOON
			card_header = "BLESSED"
			card_icon = "✦"
			show_border = true  # legacy blessed rounds had a frame — keep it (tint-free now)
			rtype = "effect"
		"effect":
			for n: Variant in src.get("effects", []):
				effects.append(str(n))
			effect_random = bool(src.get("effect_random", true))
			resolvable = bool(src.get("resolvable", false))
			endure_reward = int(src.get("endure_reward", 0))
			frame_color = _nonblank(str(src.get("frame_color", "")), EFFECT_COLOR_NEUTRAL)
			card_accent = _nonblank(str(src.get("card_accent", "")), EFFECT_COLOR_NEUTRAL)
			card_header = _nonblank(str(src.get("card_header", "")), "EFFECT")
			card_icon = _nonblank(str(src.get("card_icon", "")), "✦")
			show_border = bool(src.get("show_border", false))  # new rounds: border off by default
		_:  # normal / boss
			# A BOSS can carry forced gameplay effects (kept from source); a normal round has
			# none, so an empty source list leaves this empty and unused. The framing / reveal
			# fields stay defaulted — a boss draws its own intro card, not the effect card.
			for n: Variant in src.get("effects", []):
				effects.append(str(n))
			effect_random = bool(src.get("effect_random", true))
			resolvable = bool(src.get("resolvable", false))
			endure_reward = int(src.get("endure_reward", 0))
			frame_color = _nonblank(str(src.get("frame_color", "")), EFFECT_COLOR_NEUTRAL)
			card_accent = _nonblank(str(src.get("card_accent", "")), EFFECT_COLOR_NEUTRAL)
			card_header = _nonblank(str(src.get("card_header", "")), "EFFECT")
			card_icon = _nonblank(str(src.get("card_icon", "")), "✦")
			show_border = false

	return {
		"round_type": rtype,
		"effects": effects,
		"effect_random": effect_random,
		"resolvable": resolvable,
		"cleanse_cost": int(src.get("cleanse_cost", 50)),
		"endure_reward": endure_reward,
		"frame_color": frame_color,
		"card_accent": card_accent,
		"card_header": card_header,
		"card_icon": card_icon,
		"show_border": show_border,
		# Per-effect tuning + custom name/flavor (name → diff of changed params). Legacy
		# rounds carry none → catalog defaults; deep-copied so edits never alias the source.
		"effect_overrides": (src.get("effect_overrides", {}) as Dictionary).duplicate(true),
		# Sensory layer (shared with boss rounds) — kept as-is.
		"sensory": (src.get("sensory", []) as Array).duplicate(),
		"sensory_in_pool": bool(src.get("sensory_in_pool", false)),
		"sensory_intensity": (src.get("sensory_intensity", {}) as Dictionary).duplicate(),
		"gift_item": str(src.get("gift_item", "")),
		"show_reveal": bool(src.get("show_reveal", true)),
	}


# ── Round serialization ──────────────────────────────────────────────────────


# Normalizes a graph node's in-editor `data` into its canonical on-disk (Format-2) form: the
# lowercase field set the runtime + scanner expect, with every field typed. Two jobs:
#   1. Guarantee the BASELINE fields a node always carries (a never-edited new node has only
#      a couple of keys; the runtime should still get a complete, fully-populated record).
#   2. Re-coerce numerics: JSON loads every number as float, so coins/costs round-trip as 5.0
#      unless re-coerced to int here — the "coins lesson".
# Any EXTRA keys already on `data` (e.g. boss_modifiers, future fields) pass through via the
# initial deep copy. The save walk rewrites the MEDIA-path fields AFTER this. Pure → unit-tested.
static func coerce_node_save_data(type: String, data: Dictionary) -> Dictionary:
	var out: Dictionary = data.duplicate(true)
	out.erase("type")  # node-level — lives outside data on disk
	out.erase("node_id")  # node-level — the node's dict key IS its id
	out.erase("paths")  # legacy tree key; fork choices are out-edges in the graph
	# Segments are consumed by the save — the baked media IS the cut, so journey.json never
	# carries them. The legacy trim / section-loop fields go too, so a migrated round stops
	# carrying both spellings after its first save.
	out.erase("segments")
	out.erase("trim_start_ms")
	out.erase("trim_end_ms")
	out.erase("loop_in_ms")
	out.erase("loop_out_ms")
	out.erase("loop_count")
	# Scalars get coercing overwrites (value types — no aliasing). Collection fields (arrays /
	# dicts) are ALREADY deep-copied into `out`; only fill a default when ABSENT — reassigning
	# `out[k] = data.get(k, …)` would re-alias the source's live array/dict and let a later
	# mutation of the save-data bleed back into the editor node.
	match type:
		"round":
			# The full round field set, lowercase. Media paths (funscript/video/boss/axis/vib) +
			# action_count/length_ms + folder are overwritten afterwards by _save_round_node_media.
			out["coins"] = int(data.get("coins", 0))
			out["award_item"] = str(data.get("award_item", ""))  # optional item id granted at round end
			# is_checkpoint is RETIRED — converted to a checkpoint node on load
			# (JourneyGraph._migrate_checkpoint_flags) and stripped from the round below with the
			# other legacy keys, so a re-save never carries it.
			out["is_warmup"] = bool(data.get("is_warmup", false))
			out["boss_tagline"] = str(data.get("boss_tagline", ""))
			_fill_default(out, "boss_modifiers", [])  # lowercase {kind,…}; deep-copied pass-through
			# Effect-round fields, migrated from any legacy cursed/blessed schema. Drop the retired
			# keys first so re-saving a legacy round actually rewrites them out (migrate-on-save);
			# normalize_effect_round then supplies the canonical set (round_type, effects,
			# resolvable, sensory layer, framing colours, …). "theme" is a retired interim key.
			for legacy: String in [
				"curses",
				"boons",
				"curse_random",
				"boon_random",
				"curse_reward",
				"theme",
				"is_checkpoint",  # retired — checkpoints are their own node type now
			]:
				out.erase(legacy)
			out.merge(normalize_effect_round(data), true)
			_prune_orphan_overrides(out)  # drop tuning for effects no longer ticked
			# Pool round ("encounter"): a list of media-set entries, one weighted-picked
			# at runtime. Only pool rounds carry the list; media inside is pooled later by
			# _save_round_node_media (like a normal round's media, ×N entries).
			if str(out.get("round_type", "")) == "pool":
				var pool_out: Array = []
				for pe: Variant in data.get("pool_entries", []):
					if pe is Dictionary:
						pool_out.append(coerce_pool_entry(pe))
				out["pool_entries"] = pool_out
				out["show_encounter"] = bool(data.get("show_encounter", true))
				# Opt-in: don't draw a clip this pool already showed this run (across its copies).
				out["no_repeat"] = bool(data.get("no_repeat", false))
			else:
				out.erase("pool_entries")
				out.erase("show_encounter")
				out.erase("no_repeat")
		"shop":
			out["title"] = str(data.get("title", ""))
			out["mode"] = str(data.get("mode", "pool"))
			out["count"] = int(data.get("count", 3))
			out["price_multiplier"] = float(data.get("price_multiplier", 1.0))
			_fill_default(out, "items", [])
			_fill_default(out, "guaranteed", [])
			_fill_default(out, "excluded", [])
		"storyboard":
			# image + lines are overwritten by _save_storyboard_node_media.
			out["coins"] = int(data.get("coins", 0))
			out["item"] = str(data.get("item", ""))
		"fork":
			out["title"] = str(data.get("title", ""))
			out["description"] = str(data.get("description", ""))
			out["resolution"] = str(data.get("resolution", "choice"))
			out["cond_metric"] = str(data.get("cond_metric", "score"))
			out["cond_decider"] = str(data.get("cond_decider", "game"))
			out["default_path"] = int(data.get("default_path", 0))
			out["timeout_path"] = int(data.get("timeout_path", -1))
			out["after_order"] = int(data.get("after_order", 0))
			# Which counter a "counter" conditional fork gates on (blank for other metrics).
			out["cond_counter"] = str(data.get("cond_counter", ""))
		"checkpoint":
			# A save point between rounds — its only field is the banner label.
			out["name"] = str(data.get("name", ""))
	# Counter deltas can ride on ANY node type (a round bumps "belt", a storyboard bumps "arousal"),
	# so normalize them here rather than per type. Cleaned to {name:int}; dropped entirely when empty
	# so the schema stays lean (mirrors how set_flags only appears when non-empty).
	var counters: Dictionary = clean_counter_deltas(data.get("set_counters", {}))
	if counters.is_empty():
		out.erase("set_counters")
	else:
		out["set_counters"] = counters
	return out


# Sets out[key] = default only when key is absent. Used for collection fields whose present
# value is already deep-copied into `out`, so we must not reassign and re-alias the source.
static func _fill_default(out: Dictionary, key: String, default: Variant) -> void:
	if not out.has(key):
		out[key] = default


# Drops effect_overrides for effects the round no longer selects (in effects[] or sensory[]).
# Un-ticking an effect leaves its tuning in place during editing (re-tick restores it), but the
# save prunes the orphans so on-disk diffs stay lean. Mutates `out` in place.
static func _prune_orphan_overrides(out: Dictionary) -> void:
	var overrides: Dictionary = out.get("effect_overrides", {})
	if overrides.is_empty():
		return
	var live: Dictionary = {}
	for nm: Variant in out.get("effects", []):
		live[str(nm)] = true
	for nm: Variant in out.get("sensory", []):
		live[str(nm)] = true
	for nm: String in overrides.keys():
		if not live.has(nm):
			overrides.erase(nm)


# ── Pool round (random encounter) ─────────────────────────────────────────────
# A pool round holds several media-set entries; the runtime weighted-picks one as
# the "encounter" each play. Each entry is just media + a name + a spawn weight
# (deep-copied so a coerced entry never aliases the editor's live dicts). At save
# the media paths are pooled into content/ by _save_round_node_media; at scan they
# resolve back to absolute — same as a normal round's media, per entry.
static func coerce_pool_entry(e: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"name": str(e.get("name", "")),
		"video_path": str(e.get("video_path", "")),
		"funscript_path": str(e.get("funscript_path", "")),
		"axis_scripts": (e.get("axis_scripts", {}) as Dictionary).duplicate(true),
		"vib_scripts": (e.get("vib_scripts", {}) as Dictionary).duplicate(true),
		"weight": maxi(1, int(e.get("weight", 1))),
		# Per-entry round type: a rolled encounter can play as normal or as a boss (the round
		# adopts the picked entry's type at runtime). Only boss carries extra config.
		"round_type": str(e.get("round_type", "normal")),
	}
	if str(out["round_type"]) == "boss":
		out["boss_modifiers"] = (e.get("boss_modifiers", []) as Array).duplicate(true)
		out["boss_tagline"] = str(e.get("boss_tagline", ""))
		out["boss_image"] = str(e.get("boss_image", ""))
		out["sensory"] = (e.get("sensory", []) as Array).duplicate(true)
	return out


# Per-entry spawn weights (≥1) for the runtime pick. Pair with
# ForkResolver.weighted_pick(weights, randi() % sum(weights)).
static func pool_entry_weights(entries: Array) -> Array:
	var w: Array = []
	for e: Variant in entries:
		w.append(maxi(1, int((e as Dictionary).get("weight", 1))))
	return w


# Weights for a NO-REPEAT pool draw: an entry whose video already played this run (its video_path is
# in `played`, a {video_path: true} set) gets weight 0 so it's skipped — UNLESS every entry has
# played, in which case the full weights are returned (repeat rather than dead-end). Pure; pairs with
# pool_entry_weights.
static func pool_draw_weights(entries: Array, played: Dictionary) -> Array:
	var base: Array = pool_entry_weights(entries)
	var filtered: Array = []
	var any_unplayed: bool = false
	for i in entries.size():
		var vp: String = str((entries[i] as Dictionary).get("video_path", ""))
		if vp != "" and played.has(vp):
			filtered.append(0)
		else:
			filtered.append(int(base[i]))
			any_unplayed = true
	return filtered if any_unplayed else base


# Every animated image source the graph references, deduped. `animated_exts` is passed in (the
# caller owns the "what can ffmpeg bake" question — see MediaPoolService.ANIMATED_EXTENSIONS) so
# this stays pure data.
#
# The builder blocks a save when any of these exist and ffmpeg can't run: an animated image MUST be
# converted (Godot has no GIF decoder), and unlike video transcoding that isn't optional — an
# unbaked GIF ships as a blank image.
static func graph_animated_image_sources(graph: Dictionary, animated_exts: Array) -> Array:
	var out: Dictionary = {}
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		var d: Dictionary = n.get("data", {})
		match str(n.get("type", "")):
			"round":
				_note_animated(out, str(d.get("boss_image", "")), animated_exts)
				for pe: Variant in d.get("pool_entries", []):
					_note_animated(
						out, str((pe as Dictionary).get("boss_image", "")), animated_exts
					)
			"storyboard":
				_note_animated(out, str(d.get("image", "")), animated_exts)
				for line: Variant in d.get("lines", []):
					_note_animated(out, str((line as Dictionary).get("image", "")), animated_exts)
			"fork":
				for e: Variant in n.get("out", []):
					_note_animated(out, str((e as Dictionary).get("image_path", "")), animated_exts)
	return out.keys()


static func _note_animated(out: Dictionary, path: String, animated_exts: Array) -> void:
	if path != "" and path.get_extension().to_lower() in animated_exts:
		out[path] = true


# ── Journey identity ─────────────────────────────────────────────────────────

# Minimum FHJ version required to safely open a journey written by this build. Stamped as
# "MinVersion"; JourneySelect warns when the running app is older. A MAINTAINED FLOOR, not the
# live app version — bump it only when a save introduces a feature/format an older app can't
# read, so a plain re-save doesn't inflate the requirement.
const JOURNEY_MIN_APP_VERSION: String = "0.6.0"


# A stable, globally-unique id for a journey, minted ONCE and preserved across every later save
# (see stamp_journey_identity). Journeys travel between users, so this is 128 bits of randomness
# rather than anything machine- or counter-derived — two authors must never mint the same id.
# Prefixed like node ids ("n_…") so it reads unambiguously in journey.json.
#
# This exists so other content can refer to a journey durably: Name and FolderName are both
# user-renameable, so neither can anchor anything.
static func new_journey_id() -> String:
	return "j_%08x%08x%08x%08x" % [randi(), randi(), randi(), randi()]


# Stamps journey-level identity + version fields onto a journey.json meta dict, in place.
#
# Every writer of a permanent journey routes through here (the builder's save and the
# randomizer's keep) so the two can't drift — the randomizer previously wrote journeys with no
# version stamps at all because it builds its own meta block.
#
# `existing_id` carries the id forward: it MUST be stable for the life of the journey, so it is
# minted only when absent. Renaming a journey keeps its id (same journey); a fresh save mints a
# new one.
static func stamp_journey_identity(meta: Dictionary, existing_id: String = "") -> void:
	var id: String = existing_id.strip_edges()
	if id == "":
		id = new_journey_id()
	meta["JourneyId"] = id
	# The exact build that wrote the file (informational) + the floor needed to open it.
	meta["CreatedWith"] = str(ProjectSettings.get_setting("application/config/version", ""))
	meta["MinVersion"] = JOURNEY_MIN_APP_VERSION


# ── Item templates ───────────────────────────────────────────────────────────


# A stable per-node id, minted when an item is created and persisted to journey.json
# as "NodeId". JourneyGraph.build_graph uses it as the graph node key, so ids survive
# saves — the anchor that lets redirect edges (skip/converge) and Test-From-Here seeks
# reference a node. Random rather than a counter so copy/paste (across items, paths, or
# journeys) can't collide; build_graph also guards against a stray duplicate.
static func new_node_id() -> String:
	return "n_%08x%08x" % [randi(), randi()]


# ── Custom journey items ─────────────────────────────────────────────────────
# Author-defined, journey-scoped items: a name + description, and either an effect BUNDLE (a
# "modifier" that, when used, applies its tuned effects for the duration) or a "key" (owned for fork
# gating, never manually used). Stored in the journey meta; loaded into InventoryService each run.
# Effects are resolved {kind, params} dicts — the same shape built-in items use — so the C# runtime
# consumes them directly. Ids are minted once and preserved so award/shop/gate references survive edits.
const ITEM_CATEGORIES: Array = ["modifier", "key"]
const ITEM_DEFAULT_DURATION_MS: int = 30000


static func new_item_id() -> String:
	return "itm_%08x%08x" % [randi(), randi()]


# Runtime (snake-case) shape → journey.json (PascalCase envelope; effect param dicts stay lowercase).
static func coerce_journey_item(item: Dictionary) -> Dictionary:
	var category: String = str(item.get("category", "modifier"))
	if not ITEM_CATEGORIES.has(category):
		category = "modifier"
	var out: Dictionary = {
		"Id": str(item.get("id", "")),
		"Name": str(item.get("name", "")),
		"Description": str(item.get("description", "")),
		"Category": category,
		"Price": maxi(0, int(item.get("price", 0))),
	}
	# Optional icon (pooled path written by the save; the author's source path in the editor model).
	if str(item.get("image", "")) != "":
		out["Image"] = str(item.get("image", ""))
	if category == "key":
		return out
	out["DurationMs"] = maxi(0, int(item.get("duration_ms", ITEM_DEFAULT_DURATION_MS)))
	var effects_out: Array = []
	for e: Variant in item.get("effects", []):
		if e is Dictionary:
			effects_out.append((e as Dictionary).duplicate(true))
	out["Effects"] = effects_out
	return out


static func coerce_journey_items(items: Array) -> Array:
	var out: Array = []
	for it: Variant in items:
		if it is Dictionary:
			out.append(coerce_journey_item(it))
	return out


# journey.json (PascalCase) → runtime (snake-case). A "key" gets kind:"key" so InventoryService
# refuses manual use and fork gating works by id; a "modifier" carries its effects bundle.
static func parse_journey_item(raw: Dictionary) -> Dictionary:
	var category: String = str(raw.get("Category", "modifier"))
	if not ITEM_CATEGORIES.has(category):
		category = "modifier"
	# Heal a missing/blank id on read. An empty id is always broken — InventoryService.LoadJourneyItems
	# skips it and no fork can gate on "" — so minting one here (durable on the next save) can only fix
	# a broken item, never break a valid reference. Guards against legacy / mid-development id-less items.
	var id: String = str(raw.get("Id", "")).strip_edges()
	if id == "":
		id = new_item_id()
	var item: Dictionary = {
		"id": id,
		"name": str(raw.get("Name", "")),
		"description": str(raw.get("Description", "")),
		"category": category,
		"price": int(raw.get("Price", 0)),
	}
	if str(raw.get("Image", "")) != "":
		item["image"] = str(raw.get("Image", ""))
	if category == "key":
		item["kind"] = "key"
		return item
	item["duration_ms"] = int(raw.get("DurationMs", ITEM_DEFAULT_DURATION_MS))
	var effects: Array = []
	for e: Variant in raw.get("Effects", []):
		if e is Dictionary:
			effects.append((e as Dictionary).duplicate(true))
	item["effects"] = effects
	return item


static func parse_journey_items(raw: Array) -> Array:
	var out: Array = []
	for r: Variant in raw:
		if r is Dictionary:
			out.append(parse_journey_item(r))
	return out


# ── Characters (the storyboard cast) ────────────────────────────────────────
# Journey-level cast, each carrying its OWN portraits (expressions) and placements (position/size boxes
# tuned to that character's art). A storyboard line's `stage` is a LIST of {character, portrait,
# placement} — position and expression chosen independently. Durable `chr_…` / `por_…` ids (blank-id
# heal on read). Portraits pool like any in-game image; placements are pure fraction boxes.

# Seed ids for the three positions every character starts with (draggable/tunable afterward).
const CHARACTER_SIDES: Array = ["left", "center", "right"]

# Code defaults for the three seeded positions {id: box}. Screen-space fractions; a portrait aspect-fits
# the box. New characters copy these into their own Placements; also the fallback for a stale reference.
const PLACEMENT_BUILTINS: Dictionary = {
	"left": {"name": "Left", "x": 0.0, "y": 0.10, "w": 0.40, "h": 0.76},
	"center": {"name": "Center", "x": 0.30, "y": 0.10, "w": 0.40, "h": 0.76},
	"right": {"name": "Right", "x": 0.60, "y": 0.10, "w": 0.40, "h": 0.76},
}
const PLACEMENT_MIN_SIZE: float = 0.05  # a box can't be smaller than this fraction, so it stays grabbable


static func new_character_id() -> String:
	return "chr_%08x%08x" % [randi(), randi()]


static func new_portrait_id() -> String:
	return "por_%08x%08x" % [randi(), randi()]


static func new_placement_id() -> String:
	return "plc_%08x%08x" % [randi(), randi()]


# The three positions a fresh character starts with (copied from the built-in boxes, then tunable).
static func default_character_placements() -> Array:
	var out: Array = []
	for bid: String in CHARACTER_SIDES:
		var d: Dictionary = PLACEMENT_BUILTINS[bid]
		out.append(
			{"id": bid, "name": str(d["name"]), "x": d["x"], "y": d["y"], "w": d["w"], "h": d["h"]}
		)
	return out


# ── Character coerce/parse (runtime snake ⇄ journey.json PascalCase) ─────────


static func coerce_journey_character(c: Dictionary) -> Dictionary:
	return {
		"Id": str(c.get("id", "")),
		"Name": str(c.get("name", "")),
		"Portraits": coerce_portraits(c.get("portraits", [])),
		"Placements": coerce_journey_placements(c.get("placements", [])),
	}


static func coerce_journey_characters(list: Array) -> Array:
	var out: Array = []
	for c: Variant in list:
		if c is Dictionary:
			out.append(coerce_journey_character(c))
	return out


static func parse_journey_character(raw: Dictionary) -> Dictionary:
	var id: String = str(raw.get("Id", "")).strip_edges()
	if id == "":
		id = new_character_id()  # heal a blank id so the character is still referenceable
	var placements: Array = parse_journey_placements(raw.get("Placements", []))
	if placements.is_empty():
		placements = default_character_placements()  # self-heal: always give a character L/C/R to start
	return {
		"id": id,
		"name": str(raw.get("Name", "")),
		"portraits": parse_portraits(raw.get("Portraits", [])),
		"placements": placements,
	}


static func parse_journey_characters(raw: Array) -> Array:
	var out: Array = []
	for r: Variant in raw:
		if r is Dictionary:
			out.append(parse_journey_character(r))
	return out


# ── Portraits (a character's expressions; first = default) ──────────────────


static func coerce_portraits(list: Array) -> Array:
	var out: Array = []
	for p: Variant in list:
		if p is Dictionary:
			(
				out
				. append(
					{
						"Id": str((p as Dictionary).get("id", "")),
						"Name": str((p as Dictionary).get("name", "")),
						"Path": str((p as Dictionary).get("path", "")),
					}
				)
			)
	return out


static func parse_portraits(raw: Array) -> Array:
	var out: Array = []
	for p: Variant in raw:
		if p is Dictionary:
			var pid: String = str((p as Dictionary).get("Id", "")).strip_edges()
			if pid == "":
				pid = new_portrait_id()
			(
				out
				. append(
					{
						"id": pid,
						"name": str((p as Dictionary).get("Name", "")),
						"path": str((p as Dictionary).get("Path", "")),
					}
				)
			)
	return out


# Path of a character's portrait by id; falls back to the FIRST portrait (the default), or "" if none.
static func character_portrait_path(character: Dictionary, portrait_id: String) -> String:
	var portraits: Array = character.get("portraits", [])
	if portraits.is_empty():
		return ""
	for p: Variant in portraits:
		if p is Dictionary and str((p as Dictionary).get("id", "")) == portrait_id:
			return str((p as Dictionary).get("path", ""))
	return str((portraits[0] as Dictionary).get("path", ""))


# The character's default (first) portrait / placement id, for the speaker chip's implicit staging.
static func character_default_portrait(character: Dictionary) -> String:
	var portraits: Array = character.get("portraits", [])
	return str((portraits[0] as Dictionary).get("id", "")) if not portraits.is_empty() else ""


static func character_default_placement(character: Dictionary) -> String:
	var placements: Array = character.get("placements", [])
	return str((placements[0] as Dictionary).get("id", "")) if not placements.is_empty() else ""


# ── Placements (a character's position/size boxes) ──────────────────────────


static func coerce_journey_placement(p: Dictionary) -> Dictionary:
	return {
		"Id": str(p.get("id", "")),
		"Name": str(p.get("name", "")),
		"X": clampf(float(p.get("x", 0.0)), 0.0, 1.0),
		"Y": clampf(float(p.get("y", 0.0)), 0.0, 1.0),
		"W": clampf(float(p.get("w", 0.4)), PLACEMENT_MIN_SIZE, 1.0),
		"H": clampf(float(p.get("h", 0.76)), PLACEMENT_MIN_SIZE, 1.0),
	}


static func coerce_journey_placements(list: Array) -> Array:
	var out: Array = []
	for p: Variant in list:
		if p is Dictionary:
			out.append(coerce_journey_placement(p))
	return out


static func parse_journey_placement(raw: Dictionary) -> Dictionary:
	var id: String = str(raw.get("Id", "")).strip_edges()
	if id == "":
		id = new_placement_id()
	return {
		"id": id,
		"name": str(raw.get("Name", "")),
		"x": clampf(float(raw.get("X", 0.0)), 0.0, 1.0),
		"y": clampf(float(raw.get("Y", 0.0)), 0.0, 1.0),
		"w": clampf(float(raw.get("W", 0.4)), PLACEMENT_MIN_SIZE, 1.0),
		"h": clampf(float(raw.get("H", 0.76)), PLACEMENT_MIN_SIZE, 1.0),
	}


static func parse_journey_placements(raw: Array) -> Array:
	var out: Array = []
	for r: Variant in raw:
		if r is Dictionary:
			out.append(parse_journey_placement(r))
	return out


# Resolves a placement id to its box {x, y, w, h} within a character's OWN placements. Falls back to the
# character's first placement, then the code center default, so a portrait is never lost to a stale id.
static func resolve_placement(id: String, placements: Array) -> Dictionary:
	for p: Variant in placements:
		if p is Dictionary and str((p as Dictionary).get("id", "")) == id:
			var d: Dictionary = p
			return {
				"x": float(d.get("x", 0.0)),
				"y": float(d.get("y", 0.0)),
				"w": float(d.get("w", 0.4)),
				"h": float(d.get("h", 0.76)),
			}
	if not placements.is_empty():
		var f: Dictionary = placements[0]
		return {
			"x": float(f.get("x", 0.0)),
			"y": float(f.get("y", 0.0)),
			"w": float(f.get("w", 0.4)),
			"h": float(f.get("h", 0.76)),
		}
	var b: Dictionary = PLACEMENT_BUILTINS["center"]
	return {"x": b["x"], "y": b["y"], "w": b["w"], "h": b["h"]}


# ── Stage (a line's list of on-stage characters) ────────────────────────────
# A LIST of {character, portrait?, placement?}. portrait/placement omitted → the character's default
# (first) of each. Entries with no character are dropped; ids are NOT validated here (a stale id just
# renders nothing at runtime, never a crash).
static func clean_stage(v: Variant) -> Array:
	var out: Array = []
	if not (v is Array):
		return out
	for e: Variant in v:
		if not (e is Dictionary):
			continue
		var ch: String = str((e as Dictionary).get("character", "")).strip_edges()
		if ch == "":
			continue
		var entry: Dictionary = {"character": ch}
		var por: String = str((e as Dictionary).get("portrait", "")).strip_edges()
		var plc: String = str((e as Dictionary).get("placement", "")).strip_edges()
		if por != "":
			entry["portrait"] = por
		if plc != "":
			entry["placement"] = plc
		out.append(entry)
	return out


# Non-destructive staging for the speaker quick-pick: appends {character, placement, portrait} to the
# stage ONLY IF that character isn't already on it — never moves or re-expresses an already-staged
# character, so explicit STAGE edits always win. Returns a fresh list only when it actually adds
# someone (callers detect a change by size). `placement`/`portrait` are the character's defaults.
static func stage_with_speaker(
	stage: Array, character_id: String, placement: String, portrait: String
) -> Array:
	if character_id == "":
		return stage
	for e: Variant in stage:
		if e is Dictionary and str((e as Dictionary).get("character", "")) == character_id:
			return stage  # already on stage — leave it alone
	var out: Array = stage.duplicate(true)
	var entry: Dictionary = {"character": character_id}
	if placement != "":
		entry["placement"] = placement
	if portrait != "":
		entry["portrait"] = portrait
	out.append(entry)
	return out


# Normalizes a flag list (from a comma-separated field or a saved array) to a deduped, trimmed,
# non-empty string array. Shared by a node's "sets flags" and a fork choice's "sets flags".
static func clean_flag_list(v: Variant) -> Array:
	var out: Array = []
	var src: Array = v if v is Array else []
	for f: Variant in src:
		var s: String = str(f).strip_edges()
		if s != "" and not (s in out):
			out.append(s)
	return out


# The numeric analogue of clean_flag_list: normalizes a {name: delta} map (from disk or the editor)
# to {String: int}, dropping blank names and zero deltas (a +0 counter change is a no-op, so it
# stays out of journey.json). GameState.ApplyCounters reads the result as set_counters.
static func clean_counter_deltas(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if not (v is Dictionary):
		return out
	for k: Variant in v as Dictionary:
		var name: String = str(k).strip_edges()
		var delta: int = int((v as Dictionary)[k])
		if name != "" and delta != 0:
			out[name] = delta
	return out


# Parses the authoring text field ("belt:1, arousal:2, stress:-1") into a {name: delta} map. Each
# comma-separated token is "name:delta"; a bare "name" defaults to +1 (the "notch on the belt"
# case). Round-trips with counter_deltas_to_text.
static func parse_counter_deltas(text: String) -> Dictionary:
	var out: Dictionary = {}
	for token: String in text.split(",", false):
		var parts: PackedStringArray = token.split(":")
		var name: String = parts[0].strip_edges()
		if name == "":
			continue
		var delta: int = 1
		if parts.size() > 1 and parts[1].strip_edges() != "":
			delta = int(parts[1].strip_edges())
		if delta != 0:
			out[name] = delta
	return out


# Renders a {name: delta} map back to the "belt:1, arousal:2, stress:-1" field text.
static func counter_deltas_to_text(deltas: Dictionary) -> String:
	var parts: PackedStringArray = []
	for name: Variant in deltas:
		parts.append("%s:%d" % [str(name), int(deltas[name])])
	return ", ".join(parts)


# ── Shop offer ───────────────────────────────────────────────────────────────


# Resolves a shop's displayed lineup from its authored config. Pure — the item
# registry is passed in so this is shared by ShopScreen (live) and JourneyAudit
# (analysis). "fixed" mode shows exactly the authored `items`; "pool" mode shows
# every `guaranteed` item plus random draws from the rest of the registry up to
# `count` (count can never trim a guaranteed item). Stale ids are dropped.
# Returned in registry order so guaranteed items aren't visually distinguishable
# from drawn ones. `rng` is injectable for deterministic tests (null = global).
static func resolve_shop_offer(
	shop_data: Dictionary, all_ids: Array, rng: RandomNumberGenerator = null
) -> Array:
	if str(shop_data.get("mode", "pool")) == "fixed":
		return shop_fixed_ids(shop_data, all_ids)

	var guaranteed: Array = shop_guaranteed_ids(shop_data, all_ids)
	# `excluded` bars items from the RANDOM draw only — a guaranteed item is explicit intent and
	# still appears, so ticking one in both lists isn't a contradiction the roll has to resolve.
	var excluded: Array = shop_data.get("excluded", [])
	var rest: Array = all_ids.filter(
		func(id: String) -> bool: return not (id in guaranteed) and not (id in excluded)
	)
	if rng != null:
		# Fisher-Yates with the injected rng (Array.shuffle only uses the global one).
		for i: int in range(rest.size() - 1, 0, -1):
			var j: int = rng.randi_range(0, i)
			var tmp: Variant = rest[i]
			rest[i] = rest[j]
			rest[j] = tmp
	else:
		rest.shuffle()

	var count: int = maxi(int(shop_data.get("count", 3)), guaranteed.size())
	var lineup: Array = guaranteed + rest.slice(0, count - guaranteed.size())
	return all_ids.filter(func(id: String) -> bool: return id in lineup)


# The item ids a shop is GUARANTEED to offer: the whole lineup in fixed mode,
# the authored `guaranteed` list in pool mode. Registry order; stale ids dropped.
static func shop_guaranteed_ids(shop_data: Dictionary, all_ids: Array) -> Array:
	if str(shop_data.get("mode", "pool")) == "fixed":
		return shop_fixed_ids(shop_data, all_ids)
	var g: Array = shop_data.get("guaranteed", [])
	return all_ids.filter(func(id: String) -> bool: return id in g)


# The item ids a shop MIGHT offer: the fixed lineup, or (pool mode) everything the draw can
# reach. Excluded items are unreachable, so they're dropped — the auditor models item ownership
# from this, and counting a barred item as obtainable would wrongly clear a fork that requires it.
# A guaranteed item survives exclusion (see resolve_shop_offer).
static func shop_possible_ids(shop_data: Dictionary, all_ids: Array) -> Array:
	if str(shop_data.get("mode", "pool")) == "fixed":
		return shop_fixed_ids(shop_data, all_ids)
	var excluded: Array = shop_data.get("excluded", [])
	var guaranteed: Array = shop_guaranteed_ids(shop_data, all_ids)
	return all_ids.filter(
		func(id: String) -> bool: return (id in guaranteed) or not (id in excluded)
	)


# The authored fixed lineup filtered to ids that still exist, in registry order.
static func shop_fixed_ids(shop_data: Dictionary, all_ids: Array) -> Array:
	var configured: Array = shop_data.get("items", [])
	return all_ids.filter(func(id: String) -> bool: return id in configured)


# Returns a fresh default item dict for a builder node of the given type. Single
# source of truth for the empty-item shape, used by the insert menu, the quick-
# add buttons, and the Ctrl+1–4 shortcuts.
static func new_item(type: String) -> Dictionary:
	match type:
		"round":
			return {
				"type": "round",
				"name": "",
				"funscript_path": "",
				"video_path": "",
				"coins": 0,
				"award_item": "",
				"axis_scripts": {},
				"estim_scripts": {},
				"node_id": new_node_id()
			}
		"shop":
			return {"type": "shop", "title": "", "node_id": new_node_id()}
		"checkpoint":
			# A save point between rounds — no media, no gameplay. `name` labels its banner.
			return {"type": "checkpoint", "name": "", "node_id": new_node_id()}
		"storyboard":
			# coins / item: optional reward granted when the storyboard is finished.
			return {
				"type": "storyboard",
				"coins": 0,
				"item": "",
				"image": "",
				"lines": [],
				"node_id": new_node_id()
			}
		"fork":
			# resolution: "choice" | "random" | "conditional" | "sacrifice"
			# cond_metric (conditional only): "score" | "coins" | "item"
			# default_path (conditional only): index taken when no rule matches
			# timeout_path (choice/sacrifice): auto-advance fallback; -1 = random affordable
			# Per-path config (only the field(s) for the active resolution are used):
			#   weight (random) · threshold (conditional score/coins) ·
			#   required_item (conditional item check, OR sacrifice — consumed) ·
			#   cost (sacrifice — coins spent). required_item "" = none/free.
			return {
				"type": "fork",
				"node_id": new_node_id(),
				"title": "",
				"description": "",
				"resolution": "choice",
				"cond_metric": "score",
				"default_path": 0,
				"timeout_path": -1,
				"paths":
				[
					{
						"name": "Path A",
						"description": "",
						"image_path": "",
						"items": [],
						"weight": 1,
						"threshold": 0,
						"required_item": "",
						"cost": 0
					},
					{
						"name": "Path B",
						"description": "",
						"image_path": "",
						"items": [],
						"weight": 1,
						"threshold": 0,
						"required_item": "",
						"cost": 0
					},
				]
			}
	return {"type": type}


# ── Parse ───────────────────────────────────────────────────────────────────


# Takes a journey dict as parsed by JourneySelect._parse_journey() and
# returns the builder model:
#   {
#     "name":           String,
#     "author":         String,
#     "description":    String,
#     "difficulty_idx": int,
#     "cover_path":     String,
#     "items":          Array[Dictionary],
#   }
static func parse_journey(journey: Dictionary) -> Dictionary:
	var name: String = journey.get("title", "")
	var author: String = journey.get("author", "")
	var description: String = journey.get("description", "")

	var diff: String = journey.get("difficulty", "Easy")
	var diff_idx: int = DIFFICULTIES.find(diff)
	if diff_idx < 0:
		diff_idx = 0

	var cover_path: String = journey.get("cover_path", "")

	var rounds: Array = (journey.get("rounds", []) as Array).duplicate()
	rounds.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return (a.get("order", 0) as int) < (b.get("order", 0) as int)
	)
	var forks: Array = (journey.get("forks", []) as Array).duplicate()
	var shops: Array = (journey.get("shops", []) as Array).duplicate()
	var storyboards: Array = (journey.get("storyboards", []) as Array).duplicate()

	# Interleave by the same key scheme as GameState.BuildSequence so authoring
	# order is preserved after a round-trip through disk.
	var seq: Array = []
	for r: Dictionary in rounds:
		var rd: Dictionary = {
			"type": "round",
			"name": r.get("name", ""),
			"funscript_path": r.get("funscript_path", ""),
			"axis_scripts": r.get("axis_scripts", {}),
			"vib_scripts": r.get("vib_scripts", {}),
			"estim_scripts": r.get("estim_scripts", {}),
			"is_checkpoint": bool(r.get("is_checkpoint", false)),
			"is_warmup": bool(r.get("is_warmup", false)),
			"boss_image": r.get("boss_image", ""),
			"boss_tagline": r.get("boss_tagline", ""),
			"boss_modifiers": r.get("boss_modifiers", []),
			"video_path": _round_video(r),
			"coins": r.get("coins", 0),
			"original_folder": r.get("folder", ""),
			"node_id": r.get("node_id", ""),
		}
		# Effect-round + sensory fields (migrates legacy cursed/blessed → generic).
		rd.merge(normalize_effect_round(r), true)
		seq.append({"key": (r.get("order", 0) as int) * 3, "data": rd})
	for sb: Dictionary in storyboards:
		(
			seq
			. append(
				{
					"key": (sb.get("order", 0) as int) * 3,
					"data":
					{
						"type": "storyboard",
						"coins": sb.get("coins", 0),
						"item": sb.get("item", ""),
						"image": sb.get("image", ""),
						"lines": sb.get("lines", []),
						"node_id": sb.get("node_id", ""),
					},
				}
			)
		)
	for sh: Dictionary in shops:
		(
			seq
			. append(
				{
					"key": (sh.get("after_order", 0) as int) * 3 + 1,
					"data": _build_shop_item(sh),
				}
			)
		)
	for f: Dictionary in forks:
		(
			seq
			. append(
				{
					"key": (f.get("after_order", 0) as int) * 3 + 2,
					"data": _build_fork_item(f),
				}
			)
		)
	# Sort by runtime key, tie-break by append index. Current saves give every
	# item a unique key (monotonic position), so ties never happen — but a journey
	# last saved under the old "anchor shops/forks to the previous round" scheme can
	# have colliding keys, and a bare sort_custom is NOT stable, so those journeys
	# would load in a different item order on each open. That nondeterminism is what
	# made Test-From-Here behave differently per reopen. The index tie-break pins a
	# deterministic order.
	for i in seq.size():
		seq[i]["_ord"] = i
	seq.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return (
				(a["key"] as int) < (b["key"] as int)
				if a["key"] != b["key"]
				else (a["_ord"] as int) < (b["_ord"] as int)
			)
	)

	var items: Array = []
	for s in seq:
		items.append(s["data"])

	return {
		"name": name,
		"author": author,
		"description": description,
		"difficulty_idx": diff_idx,
		"cover_path": cover_path,
		"tags": journey.get("tags", []),
		"map_enabled": bool(journey.get("map_enabled", true)),
		"map_fog": bool(journey.get("map_fog", false)),
		"map_fog_reveal": int(journey.get("map_fog_reveal", 1)),
		"shown_counters": journey.get("shown_counters", []),
		"auto_advance_enabled": bool(journey.get("auto_advance_enabled", false)),
		"auto_advance_storyboard_secs": int(journey.get("auto_advance_storyboard_secs", 20)),
		"auto_advance_fork_secs": int(journey.get("auto_advance_fork_secs", 45)),
		"allow_finish": bool(journey.get("allow_finish", false)),
		"finish_node": str(journey.get("finish_node", "")),
		"redirects": journey.get("redirects", {}),
		"items": items,
		"characters": journey.get("characters", []),
	}


# Inflates a scanned shop dict into the builder's shop item model.
static func _build_shop_item(sh: Dictionary) -> Dictionary:
	return {
		"type": "shop",
		"title": sh.get("title", ""),
		"mode": sh.get("mode", "pool"),
		"count": int(sh.get("count", 3)),
		"items": (sh.get("items", []) as Array).duplicate(),
		"price_multiplier": float(sh.get("price_multiplier", 1.0)),
		"node_id": sh.get("node_id", ""),
	}


static func _build_fork_item(f: Dictionary) -> Dictionary:
	var paths_out: Array = []
	for p: Dictionary in f.get("paths", []):
		(
			paths_out
			. append(
				{
					"name": p.get("name", ""),
					"description": p.get("description", ""),
					"image_path": p.get("image_path", ""),
					"items": _build_path_items(p),
					"weight": int(p.get("weight", 1)),
					"threshold": int(p.get("threshold", 0)),
					"required_item": str(p.get("required_item", "")),
					"cost": int(p.get("cost", 0)),
				}
			)
		)
	return {
		"type": "fork",
		"title": f.get("title", ""),
		"description": f.get("description", ""),
		"resolution": str(f.get("resolution", "choice")),
		"cond_metric": str(f.get("cond_metric", "score")),
		"default_path": int(f.get("default_path", 0)),
		"timeout_path": int(f.get("timeout_path", -1)),
		"paths": paths_out,
		"node_id": f.get("node_id", ""),
	}


# Recursively rebuilds a path's mixed items[] array from the parsed-journey
# separate rounds/storyboards/shops/forks arrays. Nested forks recurse.
static func _build_path_items(p: Dictionary) -> Array:
	var sub: Array = []
	for pr: Dictionary in p.get("rounds", []):
		var rd: Dictionary = {
			"type": "round",
			"name": pr.get("name", ""),
			"funscript_path": pr.get("funscript_path", ""),
			"axis_scripts": pr.get("axis_scripts", {}),
			"vib_scripts": pr.get("vib_scripts", {}),
			"estim_scripts": pr.get("estim_scripts", {}),
			"is_checkpoint": bool(pr.get("is_checkpoint", false)),
			"is_warmup": bool(pr.get("is_warmup", false)),
			"boss_image": pr.get("boss_image", ""),
			"boss_tagline": pr.get("boss_tagline", ""),
			"boss_modifiers": pr.get("boss_modifiers", []),
			"video_path": _round_video(pr),
			"coins": pr.get("coins", 0),
			"original_folder": pr.get("folder", ""),
			"node_id": pr.get("node_id", ""),
		}
		# Effect-round + sensory fields (migrates legacy cursed/blessed → generic).
		rd.merge(normalize_effect_round(pr), true)
		sub.append({"key": (pr.get("order", 0) as int) * 3, "data": rd})
	for psb: Dictionary in p.get("storyboards", []):
		(
			sub
			. append(
				{
					"key": (psb.get("order", 0) as int) * 3,
					"data":
					{
						"type": "storyboard",
						"coins": psb.get("coins", 0),
						"item": psb.get("item", ""),
						"image": psb.get("image", ""),
						"lines": psb.get("lines", []),
						"node_id": psb.get("node_id", ""),
					},
				}
			)
		)
	for ps: Dictionary in p.get("shops", []):
		(
			sub
			. append(
				{
					"key": (ps.get("after_order", 0) as int) * 3 + 1,
					"data": _build_shop_item(ps),
				}
			)
		)
	for nf: Dictionary in p.get("forks", []):
		(
			sub
			. append(
				{
					"key": (nf.get("after_order", 0) as int) * 3 + 2,
					"data": _build_fork_item(nf),
				}
			)
		)
	# Stable tie-break by append index (see parse_journey) so a fork path with
	# legacy colliding keys orders deterministically instead of varying per open.
	for i in sub.size():
		sub[i]["_ord"] = i
	sub.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return (
				(a["key"] as int) < (b["key"] as int)
				if a["key"] != b["key"]
				else (a["_ord"] as int) < (b["_ord"] as int)
			)
	)
	var items: Array = []
	for s in sub:
		items.append(s["data"])
	return items


# ── Validate ────────────────────────────────────────────────────────────────


# Returns "" if the model is valid for saving, otherwise a user-facing message
# describing the first problem encountered.
static func validate(items: Array, journey_name: String) -> String:
	if journey_name.strip_edges() == "":
		return "Please enter a journey name."

	var top_round_count: int = items.reduce(
		func(acc: int, it: Dictionary) -> int:
			return acc + (1 if it.get("type", "round") == "round" else 0),
		0
	)
	if top_round_count == 0:
		return "Please add at least one round before saving."

	var round_idx_global: int = 0
	for item: Dictionary in items:
		var item_type: String = item.get("type", "round")
		match item_type:
			"round":
				round_idx_global += 1
				if (item.get("name", "") as String).strip_edges() == "":
					return "Round %d needs a name." % round_idx_global
				if item.get("funscript_path", "") == "":
					return 'Round "%s" needs a funscript.' % item.get("name", "?")
			"fork":
				var context_label: String = "fork after round %d" % round_idx_global
				var fork_error: String = validate_fork(item, context_label)
				if fork_error != "":
					return fork_error
			"storyboard":
				var lines: Array = item.get("lines", [])
				if lines.is_empty():
					return "A storyboard needs at least one line."
	return ""


# Recursively validates a fork. Returns "" if OK, or an error message.
# `context_label` is used in messages so the user knows where the error is
# (e.g. "fork after round 3" or "nested fork in path \"Path A\"").
static func validate_fork(fork_item: Dictionary, context_label: String) -> String:
	var paths: Array = fork_item.get("paths", [])
	if paths.size() < 2:
		return "The %s needs at least 2 paths." % context_label
	for pi in paths.size():
		var ppath: Dictionary = paths[pi]
		var pname: String = ppath.get("name", "")
		if pname.strip_edges() == "":
			return "Path %d of %s needs a name." % [pi + 1, context_label]
		var pi_list: Array = ppath.get("items", [])
		var pr_count: int = pi_list.reduce(
			func(acc: int, x: Dictionary) -> int:
				return acc + (1 if x.get("type", "round") == "round" else 0),
			0
		)
		if pr_count == 0:
			return 'Path "%s" (in %s) needs at least one round.' % [pname, context_label]
		for pi_item: Dictionary in pi_list:
			var pi_t: String = pi_item.get("type", "round")
			match pi_t:
				"round":
					if (pi_item.get("name", "") as String).strip_edges() == "":
						return 'A round in path "%s" needs a name.' % pname
					if pi_item.get("funscript_path", "") == "":
						return (
							'Round "%s" in path "%s" needs a funscript.'
							% [pi_item.get("name", "?"), pname]
						)
				"fork":
					var nested_err: String = validate_fork(
						pi_item, 'nested fork in path "%s"' % pname
					)
					if nested_err != "":
						return nested_err
	return ""


# ── Filesystem helpers ──────────────────────────────────────────────────────


# Resolves a round's video: the explicit scanner-provided path when present
# (the shared-media / VideoPath case), else a folder-scan fallback so journeys
# saved before VideoPath keep resolving. r is a scanner round_data dict.
static func _round_video(r: Dictionary) -> String:
	var explicit: String = r.get("video_path", "")
	if explicit != "":
		return explicit
	return find_video_in_round(r.get("folder", ""))


# Returns the path to the first video file in `folder`, or "" if none.
static func find_video_in_round(folder: String) -> String:
	if folder == "":
		return ""
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension().to_lower() in VIDEO_EXTENSIONS:
			dir.list_dir_end()
			return folder + "/" + fname
		fname = dir.get_next()
	dir.list_dir_end()
	return ""


# ── Shared content pool ──────────────────────────────────────────────────────
# Per-round playback assets (video / funscript / axis / vib / boss image) are
# stored once under content/m_<fingerprint>.<ext> and referenced by explicit
# paths, so an asset reused across rounds (e.g. a clip used by a Normal round and
# a Cursed round in a fork) lives on disk and in the shared zip exactly once.
# (The media/ folder is separate — it holds journey images.)


# Source identity for pool dedup: globalized path + byte size + mtime, hashed to
# a short hex. Deliberately NOT a content hash — that would mean reading whole
# multi-GB videos every save. Two rounds reusing the same source file produce the
# same fingerprint (so they pool to one file); editing the source (new size or
# mtime) yields a new fingerprint, so a re-save picks up the changed bytes.
# The round's SEGMENTS (see segments_identity) join the identity, because they change the
# baked output bytes: two rounds cutting one source identically still pool to one file, while
# different cuts get distinct files. The full-clip and single-window forms reproduce the legacy
# identity strings EXACTLY, so every pooled rel that exists today stays stable across the
# upgrade — without that, the first 0.6.2 save of any trimmed journey would re-bake every clip.
#
# `variant` does the same job for any other transform that changes the OUTPUT bytes while the
# source is unchanged — currently the animated-image bake, whose size cap differs per surface. One
# GIF used as a boss image (760x480) and a storyboard background (1920x1080) must NOT pool to one
# file; with the same cap on two rounds, it still does. Empty variant = the legacy identity, so
# every existing pooled rel stays stable.
static func media_fingerprint(src: String, segments: Array = [], variant: String = "") -> String:
	var abs: String = ProjectSettings.globalize_path(src)
	var size: int = 0
	var f: FileAccess = FileAccess.open(abs, FileAccess.READ)
	if f != null:
		size = f.get_length()
		f.close()
	var mtime: int = FileAccess.get_modified_time(abs)
	var identity: String = "%s|%d|%d" % [abs, size, mtime]
	var seg_id: String = segments_identity(segments)
	if seg_id != "":
		identity += "|" + seg_id
	if variant != "":
		identity += "|" + variant
	return identity.sha256_text().substr(0, 16)


# Journey-root-relative path for a fingerprinted pooled content file. Pooled
# playback content (video / funscript / axis / vib / boss image) lives under
# content/, kept separate from media/ which holds journey IMAGES (cover,
# storyboard art, fork-path art).
static func pooled_media_rel(fingerprint: String, ext: String, source: String = "") -> String:
	# A readable source-name prefix keeps content/ browsable ("clip__<fp>.mp4") while the fingerprint
	# still drives dedup + collision-safety. Same fingerprint ⇒ same source ⇒ same prefix, so dedup is
	# unaffected. Source-less callers fall back to the legacy "m_<fp>" spelling.
	if source == "":
		return "content/m_%s.%s" % [fingerprint, ext]
	return "content/%s__%s.%s" % [_pooled_prefix(source), fingerprint, ext]


# A filesystem-safe, length-bounded stem derived from a source filename, for the readable pool prefix.
# Drops all extensions, recovers the stem of an ALREADY-pooled file (so re-saving doesn't grow the name
# `clip__fp__fp2…`), sanitizes to [A-Za-z0-9_-] with single-underscore runs, and caps the length.
static func _pooled_prefix(source: String) -> String:
	var base: String = source.get_file()
	var dot: int = base.find(".")
	if dot > 0:
		base = base.substr(0, dot)
	base = _strip_pool_suffix(base)
	base = RegEx.create_from_string("[^A-Za-z0-9_-]+").sub(base, "_", true)
	base = RegEx.create_from_string("_+").sub(base, "_", true)  # keep "__" as the separator, not in the stem
	base = base.lstrip("_").rstrip("_")
	if base.length() > 40:
		base = base.substr(0, 40).rstrip("_")
	return base if base != "" else "media"


# True iff `path` names a file this journey pooled into content/ (either the readable `<name>__<fp>`
# or legacy `m_<fp>` spelling). Drives hardlink reuse on re-save. Splits on "/" rather than using
# get_base_dir(), which returns "" for a single-component relative path like "content/x.mp4".
static func is_pooled_content_path(path: String) -> bool:
	var parts: PackedStringArray = path.split("/")
	if parts.size() < 2 or parts[parts.size() - 2] != "content":
		return false
	var stem: String = parts[parts.size() - 1]
	var dot: int = stem.find(".")
	if dot > 0:
		stem = stem.substr(0, dot)  # part before the first extension (handles "…​.pitch.funscript")
	if stem.begins_with("m_") and is_hex16(stem.substr(2)):
		return true
	var us: int = stem.rfind("__")
	return us >= 0 and is_hex16(stem.substr(us + 2))


# True iff `s` is exactly a 16-char lowercase/uppercase hex string — the shape of a pooled fingerprint.
# (Not String.is_valid_hex_number: that range-parses as an int, so it rejects 16-hex values > int64.)
static func is_hex16(s: String) -> bool:
	if s.length() != 16:
		return false
	for i: int in 16:
		var c: int = s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)):
			return false
	return true


# Recovers the readable stem of a pooled filename: strips a trailing "__<16 hex>" (new form) and treats
# the legacy "m_<16 hex>" as nameless (its original filename wasn't preserved).
static func _strip_pool_suffix(base: String) -> String:
	if base.begins_with("m_") and is_hex16(base.substr(2)):
		return ""
	var us: int = base.rfind("__")
	if us >= 0 and is_hex16(base.substr(us + 2)):
		return base.substr(0, us)
	return base


# Pure dedup planner (the testable core of the save-time pooling). `sources` is
# an ordered Array of {fingerprint, ext}; returns a parallel Array of
# {rel, copy} where `copy` is true only the first time a given pooled rel is
# seen — repeats reference the same rel and skip the write. The save flow mirrors
# this with a live map so it can interleave the async transcode/copy work.
static func plan_media_pool(sources: Array) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for s: Dictionary in sources:
		var rel: String = pooled_media_rel(
			s.get("fingerprint", ""), s.get("ext", ""), str(s.get("src", ""))
		)
		var is_copy: bool = not seen.has(rel)
		seen[rel] = true
		out.append({"rel": rel, "copy": is_copy})
	return out


# Recursively deletes a directory and all its contents. Accepts either a
# user:// path or an OS-absolute path — globalize_path leaves absolutes
# unchanged, so this is safe for both callers.
static func delete_dir_recursive(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		var child: String = path + "/" + fname
		if dir.current_is_dir():
			delete_dir_recursive(child)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child))
		fname = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# Loads an image by inspecting magic bytes rather than trusting the file
# extension — handles covers that are JPEG/WebP saved with a .png extension.
# Returns the Image, or null if the path is empty / unreadable / undecodable.
static func load_image_smart(user_path: String) -> Image:
	if user_path == "":
		return null
	var abs_path: String = ProjectSettings.globalize_path(user_path)
	var f: FileAccess = FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return null
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	if bytes.is_empty():
		return null

	var img: Image = Image.new()
	var err: Error

	if (
		bytes.size() >= 4
		and bytes[0] == 0x89
		and bytes[1] == 0x50
		and bytes[2] == 0x4E
		and bytes[3] == 0x47
	):
		err = img.load_png_from_buffer(bytes)
	elif bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
		err = img.load_jpg_from_buffer(bytes)
	elif (
		bytes.size() >= 12
		and bytes[0] == 0x52
		and bytes[1] == 0x49
		and bytes[2] == 0x46
		and bytes[3] == 0x46
		and bytes[8] == 0x57
		and bytes[9] == 0x45
		and bytes[10] == 0x42
		and bytes[11] == 0x50
	):
		err = img.load_webp_from_buffer(bytes)
	else:
		err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			err = img.load_png_from_buffer(bytes)
		if err != OK:
			err = img.load_webp_from_buffer(bytes)

	return img if err == OK else null


# Parses a funscript and returns {count, length_ms}: the number of actions and
# the timestamp of the last action. Both 0 if the file is missing/unreadable.
# JourneyBuilder calls this once at save time to cache the stats into
# journey.json so the catalogue scan never has to re-parse funscripts.
# Loads a funscript's action points as an Array of Vector2(at_ms, pos), sorted by
# time. Returns [] if the file is missing or malformed. Used by the in-builder
# funscript preview graph.
static func read_funscript_actions(path: String) -> Array:
	var points: Array = []
	if path == "" or not FileAccess.file_exists(path):
		return points
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return points
	var parser: JSON = JSON.new()
	if parser.parse(f.get_as_text()) == OK and parser.data is Dictionary:
		for a in (parser.data as Dictionary).get("actions", []):
			if a is Dictionary:
				points.append(Vector2(float(a.get("at", 0)), float(a.get("pos", 0))))
	f.close()
	points.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
	return points


# ── Funscript trim (per-round video trim bake) ───────────────────────────────


# Trims time-sorted Vector2(at_ms, pos) action points to the [in_ms, out_ms]
# window and rebases them to t=0. out_ms <= 0 means "to the end". Boundary
# strokes are preserved by SYNTHESIZING an interpolated point exactly at each
# cut that lands mid-stroke — otherwise the device would snap from its home
# position to the first kept action (or stop short of the last stroke's true
# position at the out-cut). Returns [] when the window is empty/invalid.
static func trim_action_points(points: Array, in_ms: int, out_ms: int) -> Array:
	var end_ms: int = out_ms if out_ms > 0 else (1 << 62)
	if in_ms >= end_ms:
		return []
	var out: Array = []
	for i: int in points.size():
		var p: Vector2 = points[i]
		if p.x < in_ms:
			continue
		if p.x > end_ms:
			break
		# Entering the window mid-stroke: anchor the interpolated position at t=0.
		if out.is_empty() and p.x > in_ms and i > 0:
			out.append(Vector2(0, _pos_at(points[i - 1], p, in_ms)))
		out.append(Vector2(p.x - in_ms, p.y))
	# Leaving the window mid-stroke: anchor the interpolated position at the end.
	if not out.is_empty():
		var last_kept: Vector2 = out[-1]
		if last_kept.x + in_ms < end_ms:
			for i: int in points.size():
				var p: Vector2 = points[i]
				if p.x > end_ms and i > 0 and (points[i - 1] as Vector2).x < end_ms:
					out.append(Vector2(end_ms - in_ms, _pos_at(points[i - 1], p, end_ms)))
					break
	elif points.size() >= 2:
		# The whole window sits inside one long stroke: two interpolated anchors.
		for i: int in range(1, points.size()):
			var a: Vector2 = points[i - 1]
			var b: Vector2 = points[i]
			if a.x <= in_ms and b.x >= end_ms:
				out.append(Vector2(0, _pos_at(a, b, in_ms)))
				out.append(Vector2(end_ms - in_ms, _pos_at(a, b, end_ms)))
				break
	return out


# "m:ss" (or "h:mm:ss", or plain seconds) → milliseconds. Empty/garbage → 0.
static func mmss_to_ms(text: String) -> int:
	var t: String = text.strip_edges()
	if t == "":
		return 0
	var total: float = 0.0
	for part: String in t.split(":"):
		total = total * 60.0 + part.to_float()
	return maxi(0, roundi(total * 1000.0))


# Milliseconds → "m:ss" (the format mmss_to_ms accepts back).
static func ms_to_mmss(ms: int) -> String:
	var s: int = maxi(0, ms) / 1000
	return "%d:%02d" % [s / 60, s % 60]


# Linear position between two action points at time t.
static func _pos_at(a: Vector2, b: Vector2, t: float) -> float:
	if b.x <= a.x:
		return b.y
	return roundf(lerpf(a.y, b.y, (t - a.x) / (b.x - a.x)))


# ── Section looping (legacy — migration only) ──────────────────────────────
# Section looping used to be its own pair of windows (trim + an inner loop window ×N). It is
# now expressed as repeated SEGMENTS, so nothing below is part of the live save path: these
# two survive purely so normalize_segments can recognise a round authored before segments
# existed and expand it into the equivalent segment list. Don't build on them.

# (The old LOOP_MAX_COUNT ceiling is gone with the spinbox that enforced it — segments have no
# repeat cap. A long bake is the author's call and their time; it's async and cancellable.)


# True when the legacy loop params describe a real repeat (≥2 passes over a non-empty window
# that sits within the trim). Anything else was never a loop, so it migrates as a plain trim.
static func has_section_loop(
	trim_in: int, trim_out: int, loop_in: int, loop_out: int, count: int
) -> bool:
	if count < 2 or loop_out <= loop_in:
		return false
	var t_out: int = trim_out if trim_out > 0 else (1 << 62)
	return loop_in >= trim_in and loop_out <= t_out


# Appends `seg` (points rebased to 0) shifted by `offset` ms. Collapses a seam duplicate — the
# boundary anchor trim_action_points leaves at the end of one segment and the start of the next
# share a timestamp — keeping the later position so the joins stay clean.
static func _append_shifted_points(out: Array, seg: Array, offset: int) -> void:
	for p: Vector2 in seg:
		var at: int = int(p.x) + offset
		if not out.is_empty() and int((out[-1] as Vector2).x) == at:
			out[-1] = Vector2(at, p.y)
			continue
		out.append(Vector2(at, p.y))


# ── Segments (the EDL) ──────────────────────────────────────────────────────
# A round's video is an ordered list of SOURCE windows: [{in_ms, out_ms}, …], played back to
# back and concatenated at save. The runtime still sees one plain clip.
#
# One list subsumes trim AND section looping: a trim is one segment, a loop is the same window
# listed N times, a cut is what survives, a rearrangement is list order. No `repeat` field — a
# repeat IS a duplicated row, which is what makes duplicate, reorder and loop one operation.
#
# Windows may overlap and may run out of order. `out_ms <= 0` means "to the end": a pure
# function can't probe the file, so that's the only open-ended form. Empty list = full clip.


# Canonical segment list for a round's editor `data`, migrating the legacy trim/section-loop
# fields when `segments` isn't present. One-way and idempotent, so load → save → load is
# stable. The legacy shapes map exactly onto their replacements, so a migrated round bakes to
# the same bytes it did before.
static func normalize_segments(data: Dictionary) -> Array:
	if data.has("segments"):
		return coerce_segments(data.get("segments", []))

	var trim_in: int = int(data.get("trim_start_ms", 0))
	var trim_out: int = int(data.get("trim_end_ms", 0))
	var loop_in: int = int(data.get("loop_in_ms", 0))
	var loop_out: int = int(data.get("loop_out_ms", 0))
	var count: int = int(data.get("loop_count", 0))

	if has_section_loop(trim_in, trim_out, loop_in, loop_out, count):
		var segs: Array = []
		if loop_in > trim_in:
			segs.append({"in_ms": trim_in, "out_ms": loop_in})
		for _k: int in count:
			segs.append({"in_ms": loop_in, "out_ms": loop_out})
		# trim_out == 0 legitimately means "to the end", so the finale is only empty when a
		# real trim_out sits at the loop's out point.
		if trim_out <= 0 or trim_out > loop_out:
			segs.append({"in_ms": loop_out, "out_ms": trim_out})
		return segs

	if trim_in > 0 or trim_out > 0:
		return [{"in_ms": trim_in, "out_ms": trim_out}]
	return []


# Coerces a raw segments array (JSON loads every number as float — the "coins lesson") and
# drops entries that can't describe a window: negative starts, or a closed window that ends
# at or before it begins. An open end (out_ms <= 0) is always kept.
static func coerce_segments(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for s: Variant in raw:
		if not (s is Dictionary):
			continue
		var a: int = maxi(0, int((s as Dictionary).get("in_ms", 0)))
		var b: int = int((s as Dictionary).get("out_ms", 0))
		if b > 0 and b <= a:
			continue
		out.append({"in_ms": a, "out_ms": maxi(0, b)})
	return out


# Total baked length of a segment list, in ms. `source_len_ms` resolves open-ended segments
# (out_ms <= 0); pass the probed source duration. An empty list is the whole source.
static func segments_total_ms(segments: Array, source_len_ms: int) -> int:
	if segments.is_empty():
		return maxi(0, source_len_ms)
	var total: int = 0
	for seg: Dictionary in segments:
		var end_ms: int = int(seg.get("out_ms", 0))
		if end_ms <= 0:
			end_ms = source_len_ms
		total += maxi(0, end_ms - int(seg.get("in_ms", 0)))
	return total


# Bakes the action list for a segment list: each window cut and rebased by trim_action_points
# (keeping its interpolated boundary anchors), then laid end to end. Returns points rebased to
# 0; an empty list returns `points` untouched.
#
# `source_len_ms` resolves open ends, falling back to the last action's timestamp — right for a
# funscript running to the end of its clip, harmless otherwise (a trailing gap has no actions).
static func build_edl_action_points(
	points: Array, segments: Array, source_len_ms: int = 0
) -> Array:
	if segments.is_empty():
		return points
	var src_end: int = source_len_ms
	if src_end <= 0 and not points.is_empty():
		src_end = int((points[-1] as Vector2).x)

	var out: Array = []
	var at: int = 0  # running offset into the baked timeline
	for seg: Dictionary in segments:
		var start_ms: int = int(seg.get("in_ms", 0))
		var out_ms: int = int(seg.get("out_ms", 0))
		_append_shifted_points(out, trim_action_points(points, start_ms, out_ms), at)
		at += maxi(0, (out_ms if out_ms > 0 else src_end) - start_ms)
	return out


# Replaces a parsed funscript's `actions` with the baked EDL set (as {at, pos} ints),
# preserving every other metadata key. The one funscript rewriter for the save bake — main
# funscript and axis/vib siblings alike. An empty segment list returns it unchanged.
static func edl_funscript_json(
	fs: Dictionary, segments: Array, source_len_ms: int = 0
) -> Dictionary:
	if segments.is_empty():
		return fs.duplicate(true)
	var points: Array = []
	for a in fs.get("actions", []):
		if a is Dictionary:
			points.append(Vector2(float(a.get("at", 0)), float(a.get("pos", 0))))
	points.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
	var built: Array = build_edl_action_points(points, segments, source_len_ms)
	var out: Dictionary = fs.duplicate(true)
	var actions: Array = []
	for p: Vector2 in built:
		actions.append({"at": int(p.x), "pos": int(p.y)})
	out["actions"] = actions
	return out


# Fingerprint identity suffix for a segment list (see media_fingerprint).
#
# The pooled filename derives from this, so changing the SPELLING re-bakes every affected clip.
# Two forms are byte-identical to what shipped before segments existed, on purpose: an empty
# list → "", one segment → "trim:a-b". Anything a trim couldn't express gets "edl:".
static func segments_identity(segments: Array) -> String:
	if segments.is_empty():
		return ""
	if segments.size() == 1:
		var only: Dictionary = segments[0]
		var a: int = int(only.get("in_ms", 0))
		var b: int = int(only.get("out_ms", 0))
		# One window spanning the whole source IS the full clip — same bytes, same identity.
		if a <= 0 and b <= 0:
			return ""
		return "trim:%d-%d" % [a, b]
	var parts: PackedStringArray = []
	for s: Dictionary in segments:
		parts.append("%d-%d" % [int(s.get("in_ms", 0)), int(s.get("out_ms", 0))])
	return "edl:" + ",".join(parts)


static func read_funscript_stats(path: String) -> Dictionary:
	var result: Dictionary = {"count": 0, "length_ms": 0}
	if path == "" or not FileAccess.file_exists(path):
		return result
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return result
	var parser: JSON = JSON.new()
	if parser.parse(f.get_as_text()) == OK and parser.data is Dictionary:
		var actions: Array = (parser.data as Dictionary).get("actions", [])
		result["count"] = actions.size()
		if not actions.is_empty():
			result["length_ms"] = int(actions[-1].get("at", 0))
	f.close()
	return result


# True when any round node in the graph carries a video_path. Drives the save's transcode
# plan + whether to show the streaming modal.
static func graph_has_any_video(graph: Dictionary) -> bool:
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		if str(n.get("type", "")) != "round":
			continue
		var data: Dictionary = n.get("data", {})
		if str(data.get("video_path", "")) != "":
			return true
		# A pool round's videos live in its entries.
		for pe: Variant in data.get("pool_entries", []):
			if str((pe as Dictionary).get("video_path", "")) != "":
				return true
	return false


# Unique video source paths across every round node, for transcode probing (a source reused
# across rounds is probed once — identity by path).
static func graph_video_sources(graph: Dictionary) -> Array:
	var sources: Array = []
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		if str(n.get("type", "")) == "round":
			var v: String = str((n.get("data", {}) as Dictionary).get("video_path", ""))
			if v != "" and not sources.has(v):
				sources.append(v)
	return sources


# Sanitize an arbitrary string into a filesystem-safe folder name.
# (Moved from JourneyBuilder.gd — used by the save flow.)
static func sanitize_folder_name(name: String) -> String:
	const INVALID: String = '\\/:*?"<>|'
	# Trim surrounding whitespace FIRST — otherwise leading/trailing spaces become
	# underscores below and can no longer be stripped.
	var result: String = ""
	for ch: String in name.strip_edges():
		if ch in INVALID:
			continue
		result += "_" if ch == " " else ch
	# Windows forbids folder names ending in a dot or space — NTFS lets Godot create them
	# via native paths, but Win32/Explorer then can't open or delete them ("location is not
	# available"). And a LEADING dot makes JourneyScanner.scan_all skip the folder (it hides
	# ".~save_*" staging), so the journey would save yet never appear in the catalogue.
	while result.length() > 0 and (result.ends_with(".") or result.ends_with(" ")):
		result = result.substr(0, result.length() - 1)
	while result.begins_with("."):
		result = result.substr(1)
	return result if result != "" else "Journey"
