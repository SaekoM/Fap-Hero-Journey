class_name DeviceProfile
extends RefCounted

# ---------------------------------------------------------------------------
# DeviceProfile  (pure static resolver — no engine state, unit-tested)
#
# Which motion axes the player's device has. Nothing can be probed — a T-code D2 reports firmware
# configuration, not whether a servo is fitted — so the player declares it by picking the name on the
# box. Stroke only is the default because it is the safe failure: an SR6 owner who never opens Options
# gets stroke curses instead of multi-axis ones, rather than a stroke-only player getting curses they
# can't feel.
#
# The profile drives game DECISIONS only — which multi-axis curses can roll, which items are offered,
# the catalogue filter, whether Auto Twist is offered. It never filters device output: firmware ignores
# an axis that isn't fitted, and a wrong pick must never silence hardware that is really there.
# ---------------------------------------------------------------------------

const STROKE_ONLY: String = "stroke"
const OSR2: String = "osr2"
const OSR2_TWIST: String = "osr2_twist"
const SR6: String = "sr6"
const DEFAULT: String = STROKE_ONLY

# Dropdown order. Saved by id, so reordering or adding a preset never changes what a saved file means.
const PRESETS: Array = [
	{"id": STROKE_ONLY, "name": "Stroke only", "axes": ["L0"]},
	{"id": OSR2, "name": "OSR2", "axes": ["L0", "R1", "R2"]},
	{"id": OSR2_TWIST, "name": "OSR2 + twist", "axes": ["L0", "R0", "R1", "R2"]},
	{"id": SR6, "name": "SR6", "axes": ["L0", "L1", "L2", "R0", "R1", "R2"]},
]


# Dropdown position of a preset, or -1 for an id no preset has.
static func index_of(profile_id: String) -> int:
	for i: int in PRESETS.size():
		if PRESETS[i]["id"] == profile_id:
			return i
	return -1


# The preset at a dropdown position; an out-of-range position reads as the default.
static func id_at(index: int) -> String:
	if index < 0 or index >= PRESETS.size():
		return DEFAULT
	return str(PRESETS[index]["id"])


# The axes a preset declares. An unknown id — a hand-edited file, or a preset removed later — reads as
# the default rather than as nothing, so the stroke is always there.
static func declared_axes(profile_id: String) -> Array:
	var index: int = index_of(profile_id)
	return (PRESETS[index if index >= 0 else index_of(DEFAULT)]["axes"] as Array).duplicate()


# The axes the game may count on right now. Only serial carries anything but the stroke — the Handy
# and Buttplug linears are single-axis — so a multi-axis profile counts as Stroke only while the stroke
# goes anywhere else. Otherwise an SR6 owner playing on their Handy tonight would roll curses that do
# nothing.
static func effective_axes(profile_id: String, stroke_target: String) -> Array:
	if stroke_target != DeviceRouting.SERIAL_TARGET:
		return declared_axes(STROKE_ONLY)
	return declared_axes(profile_id)


# Whether the profile is being held to Stroke only by where the stroke goes — what Options explains
# when it greys the selector out.
static func is_limited_by_target(stroke_target: String) -> bool:
	return stroke_target != DeviceRouting.SERIAL_TARGET
