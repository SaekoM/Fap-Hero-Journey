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

# Shortest script that may loop: below it, a long play length would unroll into an enormous point list for
# what is effectively a held position.
const MIN_LOOP_MS: int = 100


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


# This bundle played for `play_ms` rather than once (MULTIAXIS_DESIGN.md §4, Looping). Longer than its
# script, it repeats: every channel together, on ONE loop length — the longest channel's end — so a twist
# and a pitch written to line up stay lined up on every pass. Shorter, it is cut off there. Unrolled now,
# at load, so the session clock, FunscriptPlayer and the Handy all see one long script and none of them
# needs loop logic. `play_ms` of 0 or less leaves the bundle as it is.
func played_for(play_ms: int) -> OverrideBundle:
	if play_ms <= 0 or duration_ms < MIN_LOOP_MS:
		return self
	var axes_out: Dictionary = {}
	for axis_name: Variant in axes:
		axes_out[axis_name] = _unrolled(axes[axis_name], duration_ms, play_ms)
	var vibes_out: Dictionary = {}
	for channel: Variant in vibes:
		vibes_out[channel] = _unrolled(vibes[channel], duration_ms, play_ms)
	var played: OverrideBundle = from_channels(
		_unrolled(main, duration_ms, play_ms), axes_out, vibes_out
	)
	played.duration_ms = play_ms  # exactly as long as asked, even where a channel's last pass ends early
	return played


# One channel's points repeated every `loop_ms` until `play_ms`, then cut there on a point interpolated
# at the cut, so the curve ends where it would have been rather than at its last whole stroke. A pass that
# ends where the next begins — same time, same position — loses the duplicate rather than playing a
# zero-length move; a seam that DOES jump (a stroke ending high, starting low) keeps both points.
static func _unrolled(points: Array, loop_ms: int, play_ms: int) -> Array:
	var out: Array = []
	if points.is_empty():
		return out
	var offset: int = 0
	while offset < play_ms:
		for point: Variant in points:
			var here: Vector2 = (point as Vector2) + Vector2(offset, 0)
			if here.x > play_ms:
				if not out.is_empty() and (out[-1] as Vector2).x < play_ms:
					var before: Vector2 = out[-1]
					var weight: float = (play_ms - before.x) / (here.x - before.x)
					out.append(Vector2(play_ms, lerpf(before.y, here.y, weight)))
				return out
			if not out.is_empty() and (out[-1] as Vector2).is_equal_approx(here):
				continue
			out.append(here)
		offset += loop_ms
	return out


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
