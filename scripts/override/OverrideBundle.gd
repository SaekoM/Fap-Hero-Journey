class_name OverrideBundle
extends RefCounted

# One override's funscript payload, ready to hand to the device paths: a main stroke plus any
# secondary axis (L1/L2/R0/R1/R2) and vibration (vib1/vib2) channels. Every channel is the
# time-sorted Array[Vector2] shape JourneyData.read_funscript_actions returns (x = at_ms, y = pos
# 0-100). Pure data plus the derived play length — loading the files stays with the caller so this
# is unit-testable without disk.
#
# Source-agnostic on purpose (see OVERRIDE_ITEMS_DESIGN.md): an inventory item builds one of these
# today, and the future Boss Attacks feature builds the same thing from a boss node. Neither trigger's
# identity lives here.

var main: Array = []  # Array[Vector2] — the stroke axis (L0)
var axes: Dictionary = {}  # String axis name ("L1".."R2") -> Array[Vector2]
var vibes: Dictionary = {}  # int channel (0 = vib1, 1 = vib2) -> Array[Vector2]
var duration_ms: int = 0  # max end time across every channel; the override's play length


# Builds a bundle from already-loaded channel actions and derives its duration. `axis_actions` and
# `vibe_actions` default empty (a stroke-only override). Empty channels are dropped so
# defined_axes/defined_vibes report only what actually plays.
static func from_channels(
	main_actions: Array, axis_actions: Dictionary = {}, vibe_actions: Dictionary = {}
) -> OverrideBundle:
	var bundle := OverrideBundle.new()
	bundle.main = main_actions
	for axis_name: Variant in axis_actions:
		var points: Array = axis_actions[axis_name]
		if not points.is_empty():
			bundle.axes[axis_name] = points
	for channel: Variant in vibe_actions:
		var points: Array = vibe_actions[channel]
		if not points.is_empty():
			bundle.vibes[channel] = points
	bundle.duration_ms = bundle._compute_duration()
	return bundle


# Nothing to play on any channel.
func is_empty() -> bool:
	return main.is_empty() and axes.is_empty() and vibes.is_empty()


# The axis names this override drives (channels a device without them simply ignores).
func defined_axes() -> Array:
	return axes.keys()


# The vibration channels this override drives.
func defined_vibes() -> Array:
	return vibes.keys()


# Last action time across main + every axis + every vibe. An axis/vibe running longer than the
# stroke extends the takeover; 0 for an empty bundle.
func _compute_duration() -> int:
	var end_ms: int = _channel_end(main)
	for axis_name: Variant in axes:
		end_ms = maxi(end_ms, _channel_end(axes[axis_name]))
	for channel: Variant in vibes:
		end_ms = maxi(end_ms, _channel_end(vibes[channel]))
	return end_ms


# at_ms of a channel's final action (points are time-sorted), 0 when empty.
static func _channel_end(points: Array) -> int:
	if points.is_empty():
		return 0
	return int((points[points.size() - 1] as Vector2).x)
