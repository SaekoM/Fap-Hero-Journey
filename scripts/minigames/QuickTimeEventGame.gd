class_name QuickTimeEventGame
extends RefCounted

# Quick-Time Event (Precision family, moment host, skill): rings close on targets at random places over the
# video, and the player presses the key each one names while it is inside the target. An event
# holds 1–5 prompts at seeded times within its window. Rules and scoring: MINIGAMES_DESIGN.md → "Quick-Time
# Event".
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
}

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

# One entry per prompt: {show_ms, target_ms, close_ms, accuracy, x, y, key}. accuracy is -1.0 until decided.
var prompts: Array[Dictionary] = []
var keys: PackedStringArray = []  # the keys in play

var _half_window_ms: int


static func normalize_knobs(raw: Dictionary) -> Dictionary:
	var knobs: Dictionary = {}
	for knob: String in KNOB_RANGES:
		var bounds: Array = KNOB_RANGES[knob]
		knobs[knob] = clampi(int(raw.get(knob, bounds[2])), int(bounds[0]), int(bounds[1]))
	knobs["keys"] = normalize_keys(raw.get("keys", []))
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


# The time that fits every prompt: each needs its lead-in plus half a window after the target.
static func min_duration_ms(raw_knobs: Dictionary) -> int:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	return int(knobs["prompts"]) * _prompt_span_ms(knobs)


# The time given to an event that pauses the video, which has no block on the timeline to fit into. The extra
# is shared out as random gaps, so its rhythm can't be learned.
static func held_duration_ms(raw_knobs: Dictionary, time_scale: float = 1.0) -> int:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	return int(knobs["prompts"]) * (ceili(_prompt_span_ms(knobs) * time_scale) + HELD_GAP_MS)


# The shortest event that fits one prompt: anything shorter can't be played at all.
static func one_prompt_ms(raw_knobs: Dictionary) -> int:
	return _prompt_span_ms(normalize_knobs(raw_knobs))


static func _prompt_span_ms(knobs: Dictionary) -> int:
	return int(knobs["lead_ms"]) + floori(int(knobs["window_ms"]) / 2.0)


# `duration_ms` is the time the event has. A window too short for every prompt gets as many as fit (at least
# one); the builder warns about that before it ever plays. `time_scale` stretches the rings and windows for the
# player's assist, but never past what lets one prompt fit, since a prompt can't outlast its event.
func _init(raw_knobs: Dictionary, duration_ms: int, rng_seed: int, time_scale: float = 1.0) -> void:
	var knobs: Dictionary = normalize_knobs(raw_knobs)
	var scale_that_fits: float = maxf(1.0, float(duration_ms) / _prompt_span_ms(knobs))
	var applied_scale: float = minf(time_scale, scale_that_fits)
	var lead_ms: int = roundi(int(knobs["lead_ms"]) * applied_scale)
	_half_window_ms = floori(int(knobs["window_ms"]) * applied_scale / 2.0)
	keys = PackedStringArray(knobs["keys"])
	var span: int = lead_ms + _half_window_ms
	var count: int = clampi(floori(float(duration_ms) / span), 1, int(knobs["prompts"]))
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = rng_seed
	_schedule(count, span, maxi(0, duration_ms - count * span), lead_ms, rng)
	_place_and_key_prompts(rng)


# Lays the prompts end to end and shares the spare time out as random gaps before, between and after them, so the rhythm differs per seed but two prompts can never overlap.
func _schedule(count: int, span: int, slack: int, lead_ms: int, rng: RandomNumberGenerator) -> void:
	var weights: Array[float] = []
	var weight_total: float = 0.0
	for _i in count + 1:
		var weight: float = rng.randf_range(0.2, 1.0)
		weights.append(weight)
		weight_total += weight
	var cursor: float = 0.0
	for i in count:
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
					"accuracy": -1.0,
				}
			)
		)
		cursor += span


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


# ── Input ────────────────────────────────────────────────────────────────────


# `key` pressed at `t_ms`. The first key in play pressed while a prompt is showing decides that prompt — early,
# on time, late, or the wrong one — so mashing can't help. A press with no prompt showing does nothing, and
# neither does a key not in play, so it can still do whatever it normally does. Returns the prompt's accuracy,
# or -1.0 when the press didn't land on a prompt.
func press(t_ms: int, key: String) -> float:
	var index: int = showing_prompt(t_ms)
	if index < 0 or not keys.has(key):
		return -1.0
	var prompt: Dictionary = prompts[index]
	var off_by: int = absi(t_ms - int(prompt["target_ms"]))
	var accuracy: float = 0.0
	if key == str(prompt["key"]) and off_by <= _half_window_ms:
		accuracy = 1.0 - float(off_by) / float(_half_window_ms)
	prompt["accuracy"] = accuracy
	return accuracy


# Moves the clock to `t_ms`: every prompt whose window has closed without a press becomes a miss.
func advance_to(t_ms: int) -> void:
	for prompt: Dictionary in prompts:
		if float(prompt["accuracy"]) < 0.0 and t_ms > int(prompt["close_ms"]):
			prompt["accuracy"] = 0.0


# Ends the event early (the video ran out): anything undecided is a miss.
func finish() -> void:
	for prompt: Dictionary in prompts:
		if float(prompt["accuracy"]) < 0.0:
			prompt["accuracy"] = 0.0


# ── Reading the game ─────────────────────────────────────────────────────────


# The undecided prompt showing at `t_ms`, or -1.
func showing_prompt(t_ms: int) -> int:
	for i in prompts.size():
		var prompt: Dictionary = prompts[i]
		if float(prompt["accuracy"]) < 0.0 and t_ms >= int(prompt["show_ms"]):
			if t_ms <= int(prompt["close_ms"]):
				return i
	return -1


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
