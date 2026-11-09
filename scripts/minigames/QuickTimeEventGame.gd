class_name QuickTimeEventGame
extends RefCounted

# Quick-Time Event (Precision family, moment host, skill): rings close on targets at random places over the
# video, and the player answers each one while it is inside the target. An event holds 1–10 prompts at seeded
# times within its window. Each prompt is one of the kinds its creator allows:
#
#   Press     press the key the ring names, on time.
#   Hold      press it on time, then keep it down while a fill runs round the target.
#   Mash      once the ring lands, press its key fast enough to fill the target before time runs out.
#
# Rules and scoring: MINIGAMES_DESIGN.md → "Quick-Time Event".
#
# Pure state machine. All times are milliseconds from the start of the event, supplied by the caller
# from the video position — never frames — so a prompt is exactly as hard at 60 Hz as at 144 Hz.

const KIND: String = "quick_time_event"

# {knob: [min, max, default]}
const KNOB_RANGES: Dictionary = {
	"prompts": [1, 10, 1],
	"lead_ms": [400, 3000, 1200],
	"window_ms": [200, 1500, 600],
	"size_pct": [50, 200, 100],
	"hold_ms": [500, 3000, 1000],
	"mash_ms": [1000, 8000, 3000],
	"mash_presses": [5, 60, 15],
}

# The kinds of prompt, in the order the editor shows them.
const PROMPT_PRESS: String = "press"
const PROMPT_HOLD: String = "hold"
const PROMPT_MASH: String = "mash"
const PROMPT_KINDS: Array[String] = [PROMPT_PRESS, PROMPT_HOLD, PROMPT_MASH]
const DEFAULT_PROMPT_KIND: String = PROMPT_PRESS

# What press() and release() return when they didn't decide a prompt. IGNORED: the key had nothing to do with a
# prompt, so it can still do whatever it normally does. TAKEN: it answered a prompt that isn't decided yet (a hold
# began, or a mash took a press).
const IGNORED: float = -1.0
const TAKEN: float = -2.0

# The keys a creator can ask for. Left out: F, M and S, which the round already uses for "I came", the map and
# Quick Settings, so a prompt can never fight a hotkey.
const ALLOWED_KEYS: Array[String] = [
	"A",
	"B",
	"C",
	"D",
	"E",
	"G",
	"H",
	"I",
	"J",
	"K",
	"L",
	"N",
	"O",
	"P",
	"Q",
	"R",
	"T",
	"U",
	"V",
	"W",
	"X",
	"Y",
	"Z",
	"1",
	"2",
	"3",
	"4",
	"5",
	"6",
	"7",
	"8",
	"9",
	"0",
]
const DEFAULT_KEY: String = "E"

# The rings' colours, as the creator sets them.
const DEFAULT_RING_COLOR: String = "ffffff"
const DEFAULT_TARGET_COLOR: String = "ffc24d"

# Spare time per prompt in an event that pauses the video (see held_duration_ms).
const HELD_GAP_MS: int = 700

# Where a target can sit, as a fraction of the screen: clear of the edges and the HUD bars.
const TARGET_X_RANGE: Vector2 = Vector2(0.15, 0.85)
const TARGET_Y_RANGE: Vector2 = Vector2(0.25, 0.75)
# Two prompts in a row land at least this far apart, so each one really does have to be found.
const MIN_TARGET_GAP: float = 0.2
const TARGET_DRAW_TRIES: int = 32

const NOT_YET: int = -1

# A hit at this accuracy or better is called PERFECT.
const PERFECT_ACCURACY: float = 0.8

# One entry per prompt:
#   show_ms, target_ms, close_ms  the ring appears, meets the target, and the press window (a mash's time) shuts
#   end_ms                        the latest the prompt can still be running: close_ms, or later for a hold
#   kind, key                     the prompt's kind and the key it asks for
#   x, y                          where its target sits, as a fraction of the screen
#   accuracy                      0–1 once decided, -1 until then
#   hold_ms, held_from_ms, press_accuracy   a hold's fill time, when its press began it, and how well timed it was
#   mash_presses, presses         how many presses a mash needs, and how many it has had
var prompts: Array[Dictionary] = []
var keys: PackedStringArray = []  # the keys in play

var _half_window_ms: int
var _mash_ms: int  # a mash's time, with the assist applied


static func normalize_knobs(raw: Dictionary) -> Dictionary:
	var knobs: Dictionary = {}
	for knob: String in KNOB_RANGES:
		var bounds: Array = KNOB_RANGES[knob]
		knobs[knob] = clampi(int(raw.get(knob, bounds[2])), int(bounds[0]), int(bounds[1]))
	knobs["keys"] = normalize_keys(raw.get("keys", []))
	knobs["prompt_kinds"] = normalize_prompt_kinds(raw.get("prompt_kinds", []))
	knobs["ring_color"] = _normalize_color(raw.get("ring_color"), DEFAULT_RING_COLOR)
	knobs["target_color"] = _normalize_color(raw.get("target_color"), DEFAULT_TARGET_COLOR)
	knobs["pause_video"] = bool(raw.get("pause_video", true))
	return knobs


static func _normalize_color(raw: Variant, fallback: String) -> String:
	var text: String = str(raw)
	return text if raw != null and Color.html_is_valid(text) else fallback


# The allowed keys among `raw`, once each, in a fixed order. At least one: an event needs a key to press.
static func normalize_keys(raw: Variant) -> Array:
	var wanted: Array = raw if raw is Array else []
	var names: Array = wanted.map(func(key: Variant) -> String: return str(key).to_upper())
	var out: Array = []
	for key: String in ALLOWED_KEYS:
		if names.has(key):
			out.append(key)
	return out if not out.is_empty() else [DEFAULT_KEY]


# The known prompt kinds among `raw`, once each, in a fixed order. At least one: Press, when none is left.
static func normalize_prompt_kinds(raw: Variant) -> Array:
	var wanted: Array = raw if raw is Array else []
	var names: Array = wanted.map(func(kind: Variant) -> String: return str(kind).to_lower())
	var out: Array = []
	for kind: String in PROMPT_KINDS:
		if names.has(kind):
			out.append(kind)
	return out if not out.is_empty() else [DEFAULT_PROMPT_KIND]


# Whether a game with these knobs needs a build that knows Hold and Mash prompts. An older one would quietly turn
# them into plain presses.
static func needs_newer_build(raw_knobs: Dictionary) -> bool:
	var kinds: Array = normalize_prompt_kinds(raw_knobs.get("prompt_kinds", []))
	return kinds.has(PROMPT_HOLD) or kinds.has(PROMPT_MASH)


# The time that fits every prompt, whichever kinds the seed picks: each is given room for the longest kind allowed.
static func min_duration_ms(raw_knobs: Dictionary) -> int:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	return int(knobs["prompts"]) * _longest_span_ms(knobs)


# The time given to an event that pauses the video, which has no block on the timeline to fit into. The extra
# is shared out as random gaps, so its rhythm can't be learned. The assist stretches rings and mashes, not holds.
static func held_duration_ms(raw_knobs: Dictionary, time_scale: float = 1.0) -> int:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	return int(knobs["prompts"]) * (_longest_span_ms(knobs, time_scale) + HELD_GAP_MS)


# The shortest event that fits one prompt of any kind it allows: anything shorter can't be played for sure.
static func one_prompt_ms(raw_knobs: Dictionary) -> int:
	return _longest_span_ms(normalize_knobs(raw_knobs))


# A ring's lead-in plus the late half of its window: the whole of a press.
static func _ring_span_ms(knobs: Dictionary) -> int:
	return int(knobs["lead_ms"]) + floori(int(knobs["window_ms"]) / 2.0)


# The whole of one prompt of `kind`, with the assist's `time_scale`:
#   Press  its ring.
#   Hold   its ring, then the fill, which the assist doesn't lengthen.
#   Mash   its lead-in, then the mash time, both lengthened by the assist. It has no hit window.
static func _kind_span_ms(knobs: Dictionary, kind: String, time_scale: float) -> int:
	match kind:
		PROMPT_HOLD:
			return ceili(_ring_span_ms(knobs) * time_scale) + int(knobs["hold_ms"])
		PROMPT_MASH:
			return ceili((int(knobs["lead_ms"]) + int(knobs["mash_ms"])) * time_scale)
	return ceili(_ring_span_ms(knobs) * time_scale)


static func _longest_span_ms(knobs: Dictionary, time_scale: float = 1.0) -> int:
	var longest: int = 0
	for kind: String in knobs["prompt_kinds"]:
		longest = maxi(longest, _kind_span_ms(knobs, kind, time_scale))
	return longest


# The most the assist can stretch prompts of every allowed kind and still fit one of each in `duration_ms`.
static func _largest_scale_that_fits(knobs: Dictionary, duration_ms: int) -> float:
	var largest: float = INF
	for kind: String in knobs["prompt_kinds"]:
		var stretched: float = float(_ring_span_ms(knobs))
		var fixed: float = 0.0
		match kind:
			PROMPT_HOLD:
				fixed = float(knobs["hold_ms"])
			PROMPT_MASH:
				stretched = float(int(knobs["lead_ms"]) + int(knobs["mash_ms"]))
		largest = minf(largest, (duration_ms - fixed) / stretched)
	return largest


# `duration_ms` is the time the event has. A window too short for every prompt gets as many as fit (at least
# one); the builder warns about that before it ever plays. `time_scale` stretches the rings and windows for the
# player's assist, and a mash's time with them, but never past what lets one prompt fit, since a prompt can't
# outlast its event. It never stretches a hold's fill.
#
# The kinds come from a generator of their own, so a Press-only event plays exactly as it did before Hold and Mash
# existed.
func _init(raw_knobs: Dictionary, duration_ms: int, rng_seed: int, time_scale: float = 1.0) -> void:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	var scale_that_fits: float = maxf(1.0, _largest_scale_that_fits(knobs, duration_ms))
	var applied_scale: float = minf(time_scale, scale_that_fits)
	var lead_ms: int = roundi(int(knobs["lead_ms"]) * applied_scale)
	_half_window_ms = floori(int(knobs["window_ms"]) * applied_scale / 2.0)
	_mash_ms = roundi(int(knobs["mash_ms"]) * applied_scale)
	keys = PackedStringArray(knobs["keys"])
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = rng_seed
	var kinds_rng: RandomNumberGenerator = RandomNumberGenerator.new()
	kinds_rng.seed = hash([rng_seed, "prompt kinds"])
	var kinds: Array[String] = _fitting_kinds(knobs, duration_ms, lead_ms, kinds_rng)
	var spans: Array[int] = []
	var total_span: int = 0
	for kind: String in kinds:
		spans.append(_span_ms(knobs, kind, lead_ms))
		total_span += spans[-1]
	_schedule(spans, maxi(0, duration_ms - total_span), lead_ms, rng)
	_place_and_key_prompts(rng)
	_give_kinds(kinds, knobs)


# The kind of each prompt, from the seed, for as many as fit in the event: at least one.
func _fitting_kinds(
	knobs: Dictionary, duration_ms: int, lead_ms: int, kinds_rng: RandomNumberGenerator
) -> Array[String]:
	var allowed: Array = knobs["prompt_kinds"]
	var kinds: Array[String] = []
	var used_ms: int = 0
	for _prompt in int(knobs["prompts"]):
		var kind: String = str(allowed[0])
		if allowed.size() > 1:
			kind = str(allowed[kinds_rng.randi_range(0, allowed.size() - 1)])
		var span: int = _span_ms(knobs, kind, lead_ms)
		if not kinds.is_empty() and used_ms + span > duration_ms:
			break
		kinds.append(kind)
		used_ms += span
	return kinds


# One prompt of `kind` in this game, with the assist already applied to `lead_ms` and the windows.
func _span_ms(knobs: Dictionary, kind: String, lead_ms: int) -> int:
	match kind:
		PROMPT_HOLD:
			return lead_ms + _half_window_ms + int(knobs["hold_ms"])
		PROMPT_MASH:
			return lead_ms + _mash_ms
	return lead_ms + _half_window_ms


# Lays the prompts end to end and shares the spare time out as random gaps before, between and after them, so the
# rhythm differs per seed but two prompts can never overlap.
func _schedule(spans: Array[int], slack: int, lead_ms: int, rng: RandomNumberGenerator) -> void:
	var weights: Array[float] = []
	var weight_total: float = 0.0
	for _i in spans.size() + 1:
		var weight: float = rng.randf_range(0.2, 1.0)
		weights.append(weight)
		weight_total += weight
	var cursor: float = 0.0
	for i in spans.size():
		cursor += slack * weights[i] / weight_total
		var show_ms: int = roundi(cursor)
		var target_ms: int = show_ms + lead_ms
		(
			prompts
			. append(
				{
					"show_ms": show_ms,
					"target_ms": target_ms,
					"close_ms": target_ms + _half_window_ms,
					"end_ms": show_ms + spans[i],
					"accuracy": -1.0,
				}
			)
		)
		cursor += spans[i]


# Each prompt gets a place on the screen and one of the keys in play, both from the seed.
func _place_and_key_prompts(rng: RandomNumberGenerator) -> void:
	var previous: Vector2 = Vector2(-1.0, -1.0)
	for prompt: Dictionary in prompts:
		var at: Vector2 = _draw_target(rng)
		for _try in TARGET_DRAW_TRIES:
			if previous.x < 0.0 or at.distance_to(previous) >= MIN_TARGET_GAP:
				break
			at = _draw_target(rng)
		prompt["x"] = at.x
		prompt["y"] = at.y
		prompt["key"] = keys[rng.randi_range(0, keys.size() - 1)]
		previous = at


func _draw_target(rng: RandomNumberGenerator) -> Vector2:
	return Vector2(
		rng.randf_range(TARGET_X_RANGE.x, TARGET_X_RANGE.y),
		rng.randf_range(TARGET_Y_RANGE.x, TARGET_Y_RANGE.y)
	)


# Each prompt's kind, and what that kind needs: a hold its fill time, a mash its presses and its own window, which
# runs for the mash time from the moment the ring lands.
func _give_kinds(kinds: Array[String], knobs: Dictionary) -> void:
	for i in prompts.size():
		var prompt: Dictionary = prompts[i]
		var kind: String = kinds[i]
		prompt["kind"] = kind
		match kind:
			PROMPT_HOLD:
				prompt["hold_ms"] = int(knobs["hold_ms"])
				prompt["held_from_ms"] = NOT_YET
				prompt["press_accuracy"] = 0.0
			PROMPT_MASH:
				prompt["close_ms"] = int(prompt["target_ms"]) + _mash_ms
				prompt["mash_presses"] = int(knobs["mash_presses"])
				prompt["presses"] = 0


# ── Input ────────────────────────────────────────────────────────────────────


# `key` pressed at `t_ms`. The first key in play pressed while a prompt is showing answers it, so mashing can't help:
#
#   Press     decides it: early, on time, late, or the wrong key.
#   Hold      the right key on time starts the fill (TAKEN); early, late or the wrong key is a miss.
#   Mash      once the ring has landed, each press of its key counts (TAKEN) until enough fill it (1.0). Presses
#             before it lands, and other keys, are ignored, so jumping the gun or fumbling a key costs nothing.
#
# While a hold's fill runs, other presses are ignored. A press with no prompt showing does nothing, and neither does
# a key not in play, so it can still do whatever it normally does. Returns the prompt's accuracy once decided,
# TAKEN when it answered a prompt still running, or IGNORED.
func press(t_ms: int, key: String) -> float:
	var index: int = showing_prompt(t_ms)
	if index < 0 or not keys.has(key):
		return IGNORED
	var prompt: Dictionary = prompts[index]
	match str(prompt["kind"]):
		PROMPT_HOLD:
			return _press_hold(prompt, t_ms, key)
		PROMPT_MASH:
			return _press_mash(prompt, t_ms, key)
	return _decide(prompt, _timed_accuracy(prompt, t_ms, key))


func _press_hold(prompt: Dictionary, t_ms: int, key: String) -> float:
	if is_holding(prompt):
		return IGNORED
	var accuracy: float = _timed_accuracy(prompt, t_ms, key)
	if accuracy <= 0.0:
		return _decide(prompt, 0.0)
	prompt["held_from_ms"] = t_ms
	prompt["press_accuracy"] = accuracy
	return TAKEN


# All or nothing: filling it in time scores 100%, and anything less is a miss when its time runs out.
func _press_mash(prompt: Dictionary, t_ms: int, key: String) -> float:
	if t_ms < int(prompt["target_ms"]) or key != str(prompt["key"]):
		return IGNORED
	prompt["presses"] = int(prompt["presses"]) + 1
	if int(prompt["presses"]) >= int(prompt["mash_presses"]):
		return _decide(prompt, 1.0)
	return TAKEN


# `key` let go at `t_ms`. Ends a hold early, scoring its press by how much of the fill was held. Returns the hold's
# accuracy, or IGNORED when no hold was running on that key.
func release(t_ms: int, key: String) -> float:
	for prompt: Dictionary in prompts:
		if is_holding(prompt) and key == str(prompt["key"]):
			var held: float = clampf(
				float(t_ms - int(prompt["held_from_ms"])) / int(prompt["hold_ms"]), 0.0, 1.0
			)
			return _decide(prompt, float(prompt["press_accuracy"]) * held)
	return IGNORED


# How well a press of `key` at `t_ms` meets the prompt's target: 1 dead on, falling to 0 at the window's edges, and
# 0 for a press outside the window or of the wrong key.
func _timed_accuracy(prompt: Dictionary, t_ms: int, key: String) -> float:
	var off_by: int = absi(t_ms - int(prompt["target_ms"]))
	if key != str(prompt["key"]) or off_by > _half_window_ms:
		return 0.0
	return 1.0 - float(off_by) / float(_half_window_ms)


func _decide(prompt: Dictionary, accuracy: float) -> float:
	prompt["accuracy"] = accuracy
	return accuracy


# Moves the clock to `t_ms`: a hold whose fill has run is decided on its press, and every other prompt whose window
# has closed without an answer becomes a miss.
func advance_to(t_ms: int) -> void:
	for prompt: Dictionary in prompts:
		if float(prompt["accuracy"]) >= 0.0:
			continue
		if is_holding(prompt):
			if t_ms >= int(prompt["held_from_ms"]) + int(prompt["hold_ms"]):
				_decide(prompt, float(prompt["press_accuracy"]))
		elif t_ms > int(prompt["close_ms"]):
			_decide(prompt, 0.0)


# Ends the event early (the video ran out): a hold being held keeps its press, since the player didn't let go, and
# anything else undecided is a miss.
func finish() -> void:
	for prompt: Dictionary in prompts:
		if float(prompt["accuracy"]) >= 0.0:
			continue
		_decide(prompt, float(prompt["press_accuracy"]) if is_holding(prompt) else 0.0)


# ── Reading the game ─────────────────────────────────────────────────────────


# The undecided prompt showing at `t_ms`, or -1. A hold being held shows until its fill has run.
func showing_prompt(t_ms: int) -> int:
	for i in prompts.size():
		var prompt: Dictionary = prompts[i]
		if float(prompt["accuracy"]) >= 0.0 or t_ms < int(prompt["show_ms"]):
			continue
		var showing_until: int = int(prompt["close_ms"])
		if is_holding(prompt):
			showing_until = int(prompt["held_from_ms"]) + int(prompt["hold_ms"])
		if t_ms <= showing_until:
			return i
	return -1


# Whether `prompt` is a hold whose key is down and whose fill is running.
func is_holding(prompt: Dictionary) -> bool:
	return (
		str(prompt.get("kind", "")) == PROMPT_HOLD
		and float(prompt["accuracy"]) < 0.0
		and int(prompt["held_from_ms"]) != NOT_YET
	)


# How far a hold's fill has run at `t_ms`, 0–1: 0 until its press.
func hold_progress(index: int, t_ms: int) -> float:
	var prompt: Dictionary = prompts[index]
	if str(prompt["kind"]) != PROMPT_HOLD or int(prompt["held_from_ms"]) == NOT_YET:
		return 0.0
	return clampf(float(t_ms - int(prompt["held_from_ms"])) / int(prompt["hold_ms"]), 0.0, 1.0)


# How full a mash is, 0–1.
func mash_progress(index: int) -> float:
	var prompt: Dictionary = prompts[index]
	if str(prompt["kind"]) != PROMPT_MASH:
		return 0.0
	return clampf(float(prompt["presses"]) / int(prompt["mash_presses"]), 0.0, 1.0)


# How much of a mash's time is left at `t_ms`, 1 until its ring lands, down to 0 as it runs out.
func mash_time_left(index: int, t_ms: int) -> float:
	var prompt: Dictionary = prompts[index]
	var start: int = int(prompt["target_ms"])
	var length: int = maxi(1, int(prompt["close_ms"]) - start)
	return clampf(1.0 - float(t_ms - start) / length, 0.0, 1.0)


# How far the ring has closed on prompt `index` at `t_ms`: 0 as it appears, 1 on the target, above 1
# past it (the window's late half).
func ring_progress(index: int, t_ms: int) -> float:
	var prompt: Dictionary = prompts[index]
	var lead: float = float(int(prompt["target_ms"]) - int(prompt["show_ms"]))
	return float(t_ms - int(prompt["show_ms"])) / lead


# How far either side of the target the hit window reaches, in the same units as ring_progress.
func hit_band(index: int) -> float:
	var prompt: Dictionary = prompts[index]
	var lead: float = float(int(prompt["target_ms"]) - int(prompt["show_ms"]))
	return float(_half_window_ms) / lead


func is_finished() -> bool:
	for prompt: Dictionary in prompts:
		if float(prompt["accuracy"]) < 0.0:
			return false
	return true


# 0–100: the mean accuracy over every prompt, undecided ones counting as misses.
func score() -> int:
	var total: float = 0.0
	for prompt: Dictionary in prompts:
		total += maxf(0.0, float(prompt["accuracy"]))
	return roundi(100.0 * total / prompts.size())
