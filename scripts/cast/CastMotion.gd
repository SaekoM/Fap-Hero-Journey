class_name CastMotion
extends RefCounted

# One set of animations for cast art, shared by everywhere a character appears: storyboard stages, boss CAST cues
# and mini-game characters. Each animation plays three ways:
#
#               entrance                  exit                       expression change
#   Cut         appears                   vanishes                   swaps
#   Fade        fades in                  fades out                  fades out, swaps, fades in
#   Pop         punches up from small     shrinks away               swaps and punches up
#   Rise        floats up, overshoots,    lifts a little, then       hops up, swaps, lands
#               settles back              sinks away
#   Drop        falls in from above,      lifts a little, then       sinks out, the new one
#               lands with a squash       falls away                 drops in
#   Slide       in from that side         off to that side           out to that side and back
#   Wipe        revealed left to right    hidden left to right       wiped away, wiped back in
#   Flip        turns in from edge-on     turns away to edge-on      turns over like a card
#   Spin        spins in                  spins out                  one full turn
#   Silhouette  arrives as a black shape  fades as a shape           drains to black, swaps     (holds)
#   Nod         nods as it fades in       nods, then fades           nods twice, swapping on the first
#   Jump        springs up from a         crouches and jumps away    crouches, jumps (swapping at
#               crouch and lands                                     the top) and lands
#   Lean in     comes in close            comes closer as it fades   leans in, swaps            (holds)
#   Shake       appears with a shake      shakes, then vanishes      swaps with a shake
#   Tremble     appears with a shiver     shivers, then vanishes     swaps with a shiver
#
# Each call animates one Control and owns its tween, so a new call on the same Control first stops the last one and
# puts it back where it rests. `stage` is the size of what the art moves within, which slides, rises and drops are
# measured against. With `fade` off, the caller fades something else itself (a boss cue fades its whole cue as one).
# Silhouette and Wipe colour or clip the art through a shader that's only on it while it's needed.
#
# Silhouette and Lean in HOLD: the art stays black, or leaned in, after the animation. The caller ends a hold with
# release(), which animates back (colour fills in, or it eases back) and is what change() does first when it's asked
# for anything but the held motion; asked for the held motion again, it swaps the picture and keeps holding. An
# entrance starts from no hold, and an exit leaves from the held pose and clears it.

const CUT: String = "cut"
const FADE: String = "fade"
const POP: String = "pop"
const RISE: String = "rise"
const DROP: String = "drop"
const SLIDE_LEFT: String = "slide_left"
const SLIDE_RIGHT: String = "slide_right"
const SLIDE_TOP: String = "slide_top"
const SLIDE_BOTTOM: String = "slide_bottom"
const WIPE: String = "wipe"
const FLIP: String = "flip"
const SPIN: String = "spin"
const SILHOUETTE: String = "silhouette"
const NOD: String = "nod"
const JUMP: String = "jump"
const LEAN_IN: String = "lean_in"
const SHAKE: String = "shake"
const TREMBLE: String = "tremble"
const ALL: Array[String] = [
	CUT,
	FADE,
	POP,
	RISE,
	DROP,
	SLIDE_LEFT,
	SLIDE_RIGHT,
	SLIDE_TOP,
	SLIDE_BOTTOM,
	WIPE,
	FLIP,
	SPIN,
	SILHOUETTE,
	NOD,
	JUMP,
	LEAN_IN,
	SHAKE,
	TREMBLE,
]
const NAMES: Dictionary = {
	CUT: "Cut",
	FADE: "Fade",
	POP: "Pop",
	RISE: "Rise",
	DROP: "Drop",
	SLIDE_LEFT: "Slide (left)",
	SLIDE_RIGHT: "Slide (right)",
	SLIDE_TOP: "Slide (top)",
	SLIDE_BOTTOM: "Slide (bottom)",
	WIPE: "Wipe",
	FLIP: "Flip",
	SPIN: "Spin",
	SILHOUETTE: "Silhouette",
	NOD: "Nod",
	JUMP: "Jump",
	LEAN_IN: "Lean in",
	SHAKE: "Shake",
	TREMBLE: "Tremble",
}

# Names from before the sets were joined. A boss cue's "flash" only ever snapped in, which is a Cut now; a bare
# "slide" always travelled from the left.
const OLD_NAMES: Dictionary = {"flash": CUT, "slide": SLIDE_LEFT}

const DEFAULT_SECS: float = 0.3
# Entrances and exits that need longer than DEFAULT_SECS to read, used when the caller doesn't give a length.
const OWN_SECS: Dictionary = {
	DROP: 0.45, WIPE: 0.45, SILHOUETTE: 0.5, NOD: 0.4, JUMP: 0.5, LEAN_IN: 0.35
}
# The motions that leave the art held in a pose until it's released.
const HOLDS: Array[String] = [SILHOUETTE, LEAN_IN]
const RELEASE_SECS: float = 0.25
const SHORTEST_SECS: float = 0.14  # a movement any quicker reads as a glitch
const HALF_CHANGE_SECS: float = 0.13  # each half of a change that swaps in the middle
const SPIN_CHANGE_SECS: float = 0.5
const POP_FROM_SCALE: float = 0.82
const SPIN_FROM_SCALE: float = 0.6
const SLIDE_FRACTION: float = 0.08  # of the stage's width or height
const RISE_FRACTION: float = 0.06  # of the stage's height
const RISE_OVERSHOOT_FRACTION: float = 0.015  # how far above its spot a Rise floats before settling back
const RISE_FLOAT_SHARE: float = 0.7  # of a Rise's time spent floating up; the rest settles
const DROP_FRACTION: float = 0.12  # of the stage's height
const NOD_FRACTION: float = 0.025  # of the stage's height
const JUMP_FRACTION: float = 0.06  # of the stage's height
const SQUASHED: Vector2 = Vector2(1.08, 0.9)  # a crouch or a landing, about the art's feet
const STRETCHED: Vector2 = Vector2(0.94, 1.08)  # in the air
const LEAN_FROM_SCALE: float = 1.15  # how close a Lean in comes from, or goes to
const LEAN_HELD_SCALE: float = 1.08  # how much bigger a held Lean in stays
const SHAKE_STEP_SECS: float = 0.05
const SHAKE_OFFSETS: Array[float] = [-14.0, 12.0, -9.0, 6.0, -3.0, 0.0]
const TREMBLE_STEP_SECS: float = 0.035
const TREMBLE_STEPS: int = 16
const TREMBLE_OFFSET: float = 3.0
const WIPE_SOFT_EDGE: float = 12.0  # pixels the wipe's edge blends over

const _META_TWEEN: StringName = &"cast_motion_tween"
const _META_HOME: StringName = &"cast_motion_home"
const _META_EFFECT: StringName = &"cast_motion_effect"
const _META_HELD: StringName = &"cast_motion_held"

# Darkens the art towards black (silhouette 0..1) and shows only what lies between two canvas x positions (wipe).
# Positions are on the canvas rather than the art so one material can cover the art's children too.
const _EFFECT_SHADER: String = """
shader_type canvas_item;
render_mode %s;
uniform float silhouette = 0.0;
uniform float wipe_from = -1.0e9;
uniform float wipe_to = 1.0e9;
uniform float soft_edge = 12.0;
varying float canvas_x;

void vertex() {
	canvas_x = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).x;
}

void fragment() {
	COLOR.rgb = mix(COLOR.rgb, vec3(0.0), silhouette);
	// Linear ramps rather than smoothstep: with no wipe running the edges sit a billion pixels out, where
	// `edge - soft_edge` rounds back to `edge` and smoothstep would divide by zero.
	float shown = clamp((canvas_x - wipe_from) / soft_edge + 1.0, 0.0, 1.0)
		* clamp((wipe_to - canvas_x) / soft_edge + 1.0, 0.0, 1.0);
	COLOR.a *= shown;
}
"""

static var _effect_shaders: Dictionary = {}  # blend mode -> Shader, built once each


# `raw` as one of ALL, reading the old names, or `fallback` when it's none of them.
static func normalize(raw: Variant, fallback: String) -> String:
	var wanted: String = str(raw).strip_edges().to_lower()
	wanted = str(OLD_NAMES.get(wanted, wanted))
	return wanted if wanted in ALL else fallback


# ── Playing ──────────────────────────────────────────────────────────────────


# `target` arrives where it already stands. Returns the tween, or null for a Cut (and for a Fade with `fade` off),
# which have nothing to animate. A negative `secs` uses the motion's own length.
static func enter(
	target: Control, motion: String, stage: Vector2, secs: float = -1.0, fade: bool = true
) -> Tween:
	stop(target)
	_clear_hold(target)  # an entrance starts from nothing held
	if motion == CUT or (motion == FADE and not fade):
		return null
	var home: Vector2 = target.position
	var tween: Tween = _begin(target, motion)
	tween.set_parallel(true)
	secs = _length(motion, secs)
	if fade and _fades(motion):
		var window: Vector2 = _entrance_fade(motion) * secs
		target.modulate.a = 0.0
		tween.tween_property(target, "modulate:a", 1.0, window.y).set_delay(window.x)
	match motion:
		POP:
			target.scale = Vector2(POP_FROM_SCALE, POP_FROM_SCALE)
			_ease(tween.tween_property(target, "scale", Vector2.ONE, secs), Tween.TRANS_BACK)
		RISE:
			var floated: Vector2 = home - _rise_overshoot(stage)
			_sequence(
				tween,
				target,
				"position",
				home + travel(RISE, stage),
				[
					[floated, secs * RISE_FLOAT_SHARE, Tween.TRANS_CUBIC, Tween.EASE_OUT],
					[home, secs * (1.0 - RISE_FLOAT_SHARE), Tween.TRANS_SINE, Tween.EASE_IN_OUT],
				]
			)
		DROP:
			var fall_secs: float = secs * 0.6
			_sequence(
				tween,
				target,
				"position",
				home + travel(DROP, stage),
				[[home, fall_secs, Tween.TRANS_CUBIC, Tween.EASE_IN]]
			)
			_land(tween, target, fall_secs, secs - fall_secs)
		SLIDE_LEFT, SLIDE_RIGHT, SLIDE_TOP, SLIDE_BOTTOM:
			target.position = home + travel(motion, stage)
			_ease(tween.tween_property(target, "position", home, secs), Tween.TRANS_CUBIC)
		WIPE:
			var edges: Vector2 = _wipe_edges(target)
			var effect: ShaderMaterial = _effect(target)
			effect.set_shader_parameter("wipe_from", edges.x)
			effect.set_shader_parameter("wipe_to", edges.x)  # hidden from the first frame
			_sequence(
				tween,
				effect,
				"shader_parameter/wipe_to",
				edges.x,
				[[edges.y, secs, Tween.TRANS_SINE, Tween.EASE_IN_OUT]]
			)
		FLIP:
			target.scale.x = 0.0
			_ease(tween.tween_property(target, "scale:x", 1.0, secs), Tween.TRANS_SINE)
		SPIN:
			target.rotation = -TAU
			target.scale = Vector2(SPIN_FROM_SCALE, SPIN_FROM_SCALE)
			_ease(tween.tween_property(target, "rotation", 0.0, secs), Tween.TRANS_CUBIC)
			_ease(tween.tween_property(target, "scale", Vector2.ONE, secs), Tween.TRANS_CUBIC)
		SILHOUETTE:
			_hold(target, SILHOUETTE)  # black from the first frame, and it stays
			tween.tween_interval(secs)  # the shape fades in with the alpha tween above
		NOD:
			var nodded: Vector2 = home + Vector2(0.0, stage.y * NOD_FRACTION)
			_sequence(
				tween,
				target,
				"position",
				home,
				[
					[nodded, secs * 0.4, Tween.TRANS_SINE, Tween.EASE_OUT],
					[home, secs * 0.6, Tween.TRANS_SINE, Tween.EASE_IN_OUT],
				]
			)
		JUMP:
			# Starts crouched, springs up, lands.
			var up: Vector2 = home - Vector2(0.0, stage.y * JUMP_FRACTION)
			target.scale = SQUASHED
			_sequence(
				tween,
				target,
				"position",
				home,
				[
					[up, secs * 0.35, Tween.TRANS_QUAD, Tween.EASE_OUT],
					[home, secs * 0.3, Tween.TRANS_QUAD, Tween.EASE_IN],
				]
			)
			_sequence(
				tween,
				target,
				"scale",
				SQUASHED,
				[
					[STRETCHED, secs * 0.35, Tween.TRANS_QUAD, Tween.EASE_OUT],
					[Vector2.ONE, secs * 0.3, Tween.TRANS_QUAD, Tween.EASE_IN],
				]
			)
			_land(tween, target, secs * 0.65, secs * 0.35)
		LEAN_IN:
			_hold(target, LEAN_IN)
			target.scale = Vector2(LEAN_FROM_SCALE, LEAN_FROM_SCALE)
			_ease(
				tween.tween_property(target, "scale", _held_scale(target), secs), Tween.TRANS_CUBIC
			)
		SHAKE:
			tween.set_parallel(false)
			_shake(tween, target, home)
		TREMBLE:
			tween.set_parallel(false)
			_tremble(tween, target, home)
		_:
			tween.tween_interval(secs)  # a plain fade: the alpha tween above is the whole of it
	return tween


# `target` leaves, then `on_done` runs (to hide or free it), and the target is put back as it was at rest, ready to
# be shown again. A Cut runs `on_done` at once and returns null. A negative `secs` uses the motion's own length.
static func exit(
	target: Control,
	motion: String,
	stage: Vector2,
	on_done: Callable,
	secs: float = -1.0,
	fade: bool = true
) -> Tween:
	stop(target)  # leaves from the held pose, if there is one
	if motion == CUT or (motion == FADE and not fade):
		on_done.call()
		_clear_hold(target)
		return null
	var home: Vector2 = target.position
	var tween: Tween = _begin(target, motion)
	tween.set_parallel(true)
	secs = _length(motion, secs)
	if fade and _fades(motion):
		var window: Vector2 = _exit_fade(motion) * secs
		tween.tween_property(target, "modulate:a", 0.0, window.y).set_delay(window.x)
	match motion:
		POP:
			_ease(
				tween.tween_property(
					target, "scale", Vector2(POP_FROM_SCALE, POP_FROM_SCALE), secs
				),
				Tween.TRANS_BACK,
				Tween.EASE_IN
			)
		RISE:
			var lift_secs: float = secs * (1.0 - RISE_FLOAT_SHARE)
			_sequence(
				tween,
				target,
				"position",
				home,
				[
					[home - _rise_overshoot(stage), lift_secs, Tween.TRANS_SINE, Tween.EASE_OUT],
					[
						home + travel(RISE, stage),
						secs - lift_secs,
						Tween.TRANS_CUBIC,
						Tween.EASE_IN
					],
				]
			)
		DROP:
			# A little lift, then it falls out of sight.
			_sequence(
				tween,
				target,
				"position",
				home,
				[
					[home - _rise_overshoot(stage), secs * 0.3, Tween.TRANS_SINE, Tween.EASE_OUT],
					[home - travel(DROP, stage), secs * 0.7, Tween.TRANS_CUBIC, Tween.EASE_IN],
				]
			)
		SLIDE_LEFT, SLIDE_RIGHT, SLIDE_TOP, SLIDE_BOTTOM:
			_ease(
				tween.tween_property(target, "position", home + travel(motion, stage), secs),
				Tween.TRANS_CUBIC,
				Tween.EASE_IN
			)
		WIPE:
			var edges: Vector2 = _wipe_edges(target)
			var effect: ShaderMaterial = _effect(target)
			effect.set_shader_parameter("wipe_to", edges.y)
			_sequence(
				tween,
				effect,
				"shader_parameter/wipe_from",
				edges.x,
				[[edges.y, secs, Tween.TRANS_SINE, Tween.EASE_IN_OUT]]
			)
		FLIP:
			_ease(
				tween.tween_property(target, "scale:x", 0.0, secs), Tween.TRANS_SINE, Tween.EASE_IN
			)
		SPIN:
			_ease(
				tween.tween_property(target, "rotation", TAU, secs),
				Tween.TRANS_CUBIC,
				Tween.EASE_IN
			)
			_ease(
				tween.tween_property(
					target, "scale", Vector2(SPIN_FROM_SCALE, SPIN_FROM_SCALE), secs
				),
				Tween.TRANS_CUBIC,
				Tween.EASE_IN
			)
		SILHOUETTE:
			# Drains to black first, unless it's already a held shape.
			var effect: ShaderMaterial = _effect(target)
			_sequence(
				tween,
				effect,
				"shader_parameter/silhouette",
				float(effect.get_shader_parameter("silhouette")),
				[[1.0, _exit_fade(SILHOUETTE).x * secs, Tween.TRANS_SINE, Tween.EASE_IN_OUT]]
			)
		NOD:
			var nodded: Vector2 = home + Vector2(0.0, stage.y * NOD_FRACTION)
			_sequence(
				tween,
				target,
				"position",
				home,
				[
					[nodded, secs * 0.3, Tween.TRANS_SINE, Tween.EASE_OUT],
					[home, secs * 0.3, Tween.TRANS_SINE, Tween.EASE_IN_OUT],
				]
			)
		JUMP:
			# Crouches, then jumps up and away.
			var away: Vector2 = home - Vector2(0.0, stage.y * JUMP_FRACTION * 3.0)
			_sequence(
				tween,
				target,
				"position",
				home,
				[
					[home, secs * 0.3, Tween.TRANS_LINEAR, Tween.EASE_IN_OUT],
					[away, secs * 0.7, Tween.TRANS_CUBIC, Tween.EASE_OUT],
				]
			)
			_sequence(
				tween,
				target,
				"scale",
				Vector2.ONE,
				[
					[SQUASHED, secs * 0.3, Tween.TRANS_QUAD, Tween.EASE_OUT],
					[STRETCHED, secs * 0.7, Tween.TRANS_QUAD, Tween.EASE_OUT],
				]
			)
		LEAN_IN:
			_ease(
				tween.tween_property(
					target, "scale", Vector2(LEAN_FROM_SCALE, LEAN_FROM_SCALE), secs
				),
				Tween.TRANS_CUBIC,
				Tween.EASE_IN
			)
		SHAKE:
			tween.set_parallel(false)
			_shake(tween, target, home)
		TREMBLE:
			tween.set_parallel(false)
			_tremble(tween, target, home)
		_:
			tween.tween_interval(secs)
	tween.chain().tween_callback(on_done)
	tween.tween_callback(
		func() -> void:
			_put_back(target, home)
			_clear_hold(target)
	)
	return tween


# `target` changes what it shows: `swap` is called at the moment the new picture should appear. A Cut swaps at once
# and returns null. Held in another pose, it's released first and the change follows; held in this motion's pose,
# the picture swaps and the hold carries on.
static func change(target: Control, motion: String, stage: Vector2, swap: Callable) -> Tween:
	stop(target)
	var holding: String = held(target)
	if holding == motion:
		swap_picture(target, swap)
		return null
	if holding != "":
		return _release_then(target, func() -> void: change(target, motion, stage, swap))
	if motion == CUT:
		swap.call()
		return null
	var home: Vector2 = target.position
	var tween: Tween = _begin(target, motion)
	match motion:
		FADE:
			tween.tween_property(target, "modulate:a", 0.0, HALF_CHANGE_SECS)
			tween.tween_callback(swap)
			tween.tween_property(target, "modulate:a", 1.0, HALF_CHANGE_SECS)
		POP:
			swap.call()
			target.scale = Vector2(POP_FROM_SCALE, POP_FROM_SCALE)
			_ease(
				tween.tween_property(target, "scale", Vector2.ONE, DEFAULT_SECS), Tween.TRANS_BACK
			)
		RISE:
			# A small hop: up, swapping at the top, and back down.
			var hop: Vector2 = home - travel(RISE, stage)
			_ease(
				tween.tween_property(target, "position", hop, HALF_CHANGE_SECS),
				Tween.TRANS_SINE,
				Tween.EASE_IN
			)
			tween.tween_callback(swap)
			_ease(
				tween.tween_property(target, "position", home, HALF_CHANGE_SECS), Tween.TRANS_SINE
			)
		DROP:
			# Sinks out of sight, and the new picture drops in from above and lands.
			var sink_secs: float = 0.15
			var fall_secs: float = 0.18
			var half_drop: Vector2 = travel(DROP, stage) * 0.5  # upwards
			tween.set_parallel(true)
			_sequence(
				tween,
				target,
				"position",
				home,
				[[home - half_drop, sink_secs, Tween.TRANS_CUBIC, Tween.EASE_IN]]  # down
			)
			tween.tween_property(target, "modulate:a", 0.0, sink_secs)
			tween.tween_callback(swap).set_delay(sink_secs)
			_sequence(
				tween,
				target,
				"position",
				home + half_drop,
				[[home, fall_secs, Tween.TRANS_CUBIC, Tween.EASE_IN]],
				sink_secs
			)
			tween.tween_property(target, "modulate:a", 1.0, fall_secs).set_delay(sink_secs)
			_land(tween, target, sink_secs + fall_secs, 0.16)
		SLIDE_LEFT, SLIDE_RIGHT, SLIDE_TOP, SLIDE_BOTTOM:
			# Out to that side, fading, and back in with the new picture.
			var away: Vector2 = home + travel(motion, stage)
			tween.set_parallel(true)
			_ease(
				tween.tween_property(target, "position", away, HALF_CHANGE_SECS),
				Tween.TRANS_CUBIC,
				Tween.EASE_IN
			)
			tween.tween_property(target, "modulate:a", 0.0, HALF_CHANGE_SECS)
			tween.chain().tween_callback(swap)
			_ease(
				tween.chain().tween_property(target, "position", home, HALF_CHANGE_SECS),
				Tween.TRANS_CUBIC
			)
			tween.tween_property(target, "modulate:a", 1.0, HALF_CHANGE_SECS)
		WIPE:
			# Wiped away left to right, then the new picture wiped in the same way.
			var edges: Vector2 = _wipe_edges(target)
			var effect: ShaderMaterial = _effect(target)
			var out_secs: float = 0.22
			tween.set_parallel(true)
			_sequence(
				tween,
				effect,
				"shader_parameter/wipe_from",
				edges.x,
				[[edges.y, out_secs, Tween.TRANS_SINE, Tween.EASE_IN]]
			)
			tween.tween_callback(swap_picture.bind(target, swap)).set_delay(out_secs)
			tween.tween_callback(effect.set_shader_parameter.bind("wipe_from", edges.x)).set_delay(
				out_secs
			)
			_sequence(
				tween,
				effect,
				"shader_parameter/wipe_to",
				edges.x,
				[[edges.y, 0.28, Tween.TRANS_SINE, Tween.EASE_OUT]],
				out_secs
			)
		FLIP:
			_ease(
				tween.tween_property(target, "scale:x", 0.0, HALF_CHANGE_SECS),
				Tween.TRANS_SINE,
				Tween.EASE_IN
			)
			tween.tween_callback(swap)
			_ease(tween.tween_property(target, "scale:x", 1.0, HALF_CHANGE_SECS), Tween.TRANS_SINE)
		SPIN:
			# One full turn, swapped halfway, where it's upside down.
			tween.set_parallel(true)
			_ease(
				tween.tween_property(target, "rotation", TAU, SPIN_CHANGE_SECS),
				Tween.TRANS_SINE,
				Tween.EASE_IN_OUT
			)
			tween.tween_callback(swap).set_delay(SPIN_CHANGE_SECS / 2.0)
			tween.chain().tween_callback(func() -> void: target.rotation = 0.0)
		SILHOUETTE:
			# Drains to black, swaps while it's a shape, and stays black.
			var effect: ShaderMaterial = _effect(target)
			var drain_secs: float = 0.25
			tween.set_parallel(true)
			_sequence(
				tween,
				effect,
				"shader_parameter/silhouette",
				0.0,
				[[1.0, drain_secs, Tween.TRANS_SINE, Tween.EASE_IN]]
			)
			tween.tween_callback(swap_picture.bind(target, swap)).set_delay(drain_secs)
			tween.tween_callback(_hold.bind(target, SILHOUETTE)).set_delay(drain_secs)
		NOD:
			# Two nods, the new picture showing at the bottom of the first.
			var nodded: Vector2 = home + Vector2(0.0, stage.y * NOD_FRACTION)
			var half_nod: Vector2 = home + Vector2(0.0, stage.y * NOD_FRACTION * 0.5)
			tween.set_parallel(true)
			_sequence(
				tween,
				target,
				"position",
				home,
				[
					[nodded, 0.12, Tween.TRANS_SINE, Tween.EASE_OUT],
					[home, 0.12, Tween.TRANS_SINE, Tween.EASE_IN_OUT],
					[half_nod, 0.08, Tween.TRANS_SINE, Tween.EASE_OUT],
					[home, 0.1, Tween.TRANS_SINE, Tween.EASE_IN_OUT],
				]
			)
			tween.tween_callback(swap).set_delay(0.12)
		JUMP:
			# Crouches, jumps (the new picture showing at the top) and lands.
			var up: Vector2 = home - Vector2(0.0, stage.y * JUMP_FRACTION)
			tween.set_parallel(true)
			_sequence(
				tween,
				target,
				"position",
				home,
				[
					[home, 0.1, Tween.TRANS_LINEAR, Tween.EASE_IN_OUT],
					[up, 0.15, Tween.TRANS_QUAD, Tween.EASE_OUT],
					[home, 0.12, Tween.TRANS_QUAD, Tween.EASE_IN],
				]
			)
			_sequence(
				tween,
				target,
				"scale",
				Vector2.ONE,
				[
					[SQUASHED, 0.1, Tween.TRANS_QUAD, Tween.EASE_OUT],
					[STRETCHED, 0.15, Tween.TRANS_QUAD, Tween.EASE_OUT],
					[Vector2.ONE, 0.12, Tween.TRANS_QUAD, Tween.EASE_IN],
				]
			)
			tween.tween_callback(swap).set_delay(0.25)
			_land(tween, target, 0.37, 0.16)
		LEAN_IN:
			# Leans in, swaps, and stays leaned in.
			var leaned: Vector2 = Vector2(LEAN_HELD_SCALE, LEAN_HELD_SCALE)
			_hold(target, LEAN_IN)
			tween.set_parallel(true)
			_ease(tween.tween_property(target, "scale", leaned, 0.2), Tween.TRANS_CUBIC)
			tween.tween_callback(swap).set_delay(0.15)
		TREMBLE:
			swap.call()
			_tremble(tween, target, home)
		_:
			swap.call()
			_shake(tween, target, home)
	return tween


# The motion `target` is held in (Silhouette or Lean in), or "" when it's at plain rest.
static func held(target: Control) -> String:
	return str(target.get_meta(_META_HELD)) if target.has_meta(_META_HELD) else ""


# Whether `motion` leaves the art held in a pose until it's released.
static func holds(motion: String) -> bool:
	return motion in HOLDS


# Ends a hold: colour fills back in, or the art eases back to its own size. Returns null when nothing is held.
static func release(target: Control) -> Tween:
	stop(target)
	var holding: String = held(target)
	if holding == "":
		return null
	var tween: Tween = _begin(target, holding)
	target.remove_meta(_META_HELD)  # stopped partway, it's put back at plain rest
	match holding:
		SILHOUETTE:
			var effect: ShaderMaterial = _effect(target)
			_ease(
				tween.tween_property(effect, "shader_parameter/silhouette", 0.0, RELEASE_SECS),
				Tween.TRANS_SINE,
				Tween.EASE_IN_OUT
			)
		_:
			_ease(
				tween.tween_property(target, "scale", Vector2.ONE, RELEASE_SECS),
				Tween.TRANS_SINE,
				Tween.EASE_IN_OUT
			)
	return tween


# Shows a new picture on art that may be held: a silhouette's shader also has to cover the picture's new children.
static func swap_picture(target: Control, swap: Callable) -> void:
	swap.call()
	if is_instance_valid(target) and target.has_meta(_META_EFFECT):
		_share_effect(target)


# Stops whatever `target` was doing and puts it back at rest where it stood (in its held pose, if it has one). Safe
# to call on one that's at rest.
static func stop(target: Control) -> void:
	# has_meta first: get_meta treats a null default as "no default" and logs an error when the key is missing.
	if target.has_meta(_META_TWEEN):
		var running: Variant = target.get_meta(_META_TWEEN)
		if running is Tween and (running as Tween).is_valid():
			(running as Tween).kill()
	if target.has_meta(_META_HOME):
		_put_back(target, target.get_meta(_META_HOME))
	_forget(target)


# How far a slide, rise or drop travels from where the art rests: where it comes in from, and leaves towards.
static func travel(motion: String, stage: Vector2) -> Vector2:
	match motion:
		SLIDE_LEFT:
			return Vector2(-stage.x * SLIDE_FRACTION, 0.0)
		SLIDE_RIGHT:
			return Vector2(stage.x * SLIDE_FRACTION, 0.0)
		SLIDE_TOP:
			return Vector2(0.0, -stage.y * SLIDE_FRACTION)
		SLIDE_BOTTOM:
			return Vector2(0.0, stage.y * SLIDE_FRACTION)
		RISE:
			return Vector2(0.0, stage.y * RISE_FRACTION)
		DROP:
			return Vector2(0.0, -stage.y * DROP_FRACTION)
	return Vector2.ZERO


# ── Inside ───────────────────────────────────────────────────────────────────


# A tween for `target`, remembered on it with where it rests, and forgotten again when it finishes. It turns and
# scales about its own middle, or about its feet for the motions that squash on landing. Art that hasn't been laid
# out yet has no size, so its pivot is placed again once it has.
static func _begin(target: Control, motion: String) -> Tween:
	var about_feet: bool = motion in [JUMP, DROP]
	_place_pivot(target, about_feet)
	if target.size == Vector2.ZERO:
		target.resized.connect(func() -> void: _place_pivot(target, about_feet), CONNECT_ONE_SHOT)
	target.set_meta(_META_HOME, target.position)
	var tween: Tween = target.create_tween()
	target.set_meta(_META_TWEEN, tween)
	# Only its own: a release's follow-up (_release_then) has already started the next tween by the time this fires.
	tween.finished.connect(
		func() -> void:
			if is_instance_valid(target) and target.get_meta(_META_TWEEN, tween) == tween:
				_forget(target)
	)
	return tween


static func _place_pivot(target: Control, about_feet: bool) -> void:
	target.pivot_offset = Vector2(
		target.size.x / 2.0, target.size.y if about_feet else target.size.y / 2.0
	)


static func _forget(target: Control) -> void:
	if is_instance_valid(target):
		target.remove_meta(_META_TWEEN)
		target.remove_meta(_META_HOME)
		if held(target) != SILHOUETTE:  # a held silhouette keeps its shader
			_drop_effect(target)


static func _put_back(target: Control, home: Vector2) -> void:
	if not is_instance_valid(target):
		return
	target.position = home
	target.scale = _held_scale(target)
	target.rotation = 0.0
	target.modulate.a = 1.0
	if held(target) == SILHOUETTE:
		_effect(target).set_shader_parameter("silhouette", 1.0)


# Holds `target` in `motion`'s pose from now on. A silhouette is black at once.
static func _hold(target: Control, motion: String) -> void:
	target.set_meta(_META_HELD, motion)
	if motion == SILHOUETTE:
		_effect(target).set_shader_parameter("silhouette", 1.0)


# Drops any hold at once, with no animation, leaving the art at plain rest.
static func _clear_hold(target: Control) -> void:
	if not is_instance_valid(target) or held(target) == "":
		return
	target.remove_meta(_META_HELD)
	target.scale = Vector2.ONE
	_drop_effect(target)


static func _held_scale(target: Control) -> Vector2:
	return Vector2(LEAN_HELD_SCALE, LEAN_HELD_SCALE) if held(target) == LEAN_IN else Vector2.ONE


# Releases the hold, then runs `follow` (the change that was asked for). A release that's stopped partway never runs
# it: whatever stopped it has taken over.
static func _release_then(target: Control, follow: Callable) -> Tween:
	var tween: Tween = release(target)
	tween.finished.connect(
		func() -> void:
			if is_instance_valid(target):
				follow.call(),
		CONNECT_ONE_SHOT
	)
	return tween


# The motion's length: the one asked for, or its own when none was.
static func _length(motion: String, secs: float) -> float:
	if secs < 0.0:
		secs = float(OWN_SECS.get(motion, DEFAULT_SECS))
	return maxf(SHORTEST_SECS, secs)


# Whether the art fades in or out as it makes this entrance or exit. The rest show or hide it some other way.
static func _fades(motion: String) -> bool:
	return motion not in [FLIP, SHAKE, TREMBLE, WIPE]


# When an entrance's fade-in runs, as (start, length) shares of its time.
static func _entrance_fade(motion: String) -> Vector2:
	match motion:
		NOD:
			return Vector2(0.0, 0.5)
		JUMP:
			return Vector2(0.0, 0.35)
		DROP:
			return Vector2(0.0, 0.4)
	return Vector2(0.0, 1.0)


# When an exit's fade-out runs, as (start, length) shares of its time.
static func _exit_fade(motion: String) -> Vector2:
	match motion:
		NOD:
			return Vector2(0.5, 0.5)
		JUMP:
			return Vector2(0.3, 0.7)
		SILHOUETTE:
			return Vector2(0.65, 0.35)  # drains to black first, then the shape fades
	return Vector2(0.0, 1.0)


# Tweens one property of `object` through `steps` one after another, starting `start_at` seconds in, alongside whatever
# else the (parallel) tween runs. Each step is [value, seconds, transition, easing]. Every step names the value it
# starts from, so none of them depends on where the one before happened to leave the property.
static func _sequence(
	tween: Tween,
	object: Object,
	property: String,
	start_value: Variant,
	steps: Array,
	start_at: float = 0.0
) -> void:
	var at: float = start_at
	var previous: Variant = start_value
	for step: Array in steps:
		(
			tween
			. tween_property(object, property, step[0], float(step[1]))
			. from(previous)
			. set_delay(at)
			. set_trans(step[2])
			. set_ease(step[3])
		)
		previous = step[0]
		at += float(step[1])


# A landing: squashes about its feet, then springs back to its own shape.
static func _land(tween: Tween, target: Control, at: float, secs: float) -> void:
	_sequence(
		tween,
		target,
		"scale",
		Vector2.ONE,
		[
			[SQUASHED, secs * 0.4, Tween.TRANS_QUAD, Tween.EASE_OUT],
			[Vector2.ONE, secs * 0.6, Tween.TRANS_BACK, Tween.EASE_OUT],
		],
		at
	)


static func _shake(tween: Tween, target: Control, home: Vector2) -> void:
	for offset: float in SHAKE_OFFSETS:
		tween.tween_property(target, "position:x", home.x + offset, SHAKE_STEP_SECS)


# A fine, fast shiver: smaller and longer than a Shake.
static func _tremble(tween: Tween, target: Control, home: Vector2) -> void:
	for step: int in TREMBLE_STEPS:
		var offset: float = TREMBLE_OFFSET if step % 2 == 0 else -TREMBLE_OFFSET
		tween.tween_property(target, "position:x", home.x + offset, TREMBLE_STEP_SECS)
	tween.tween_property(target, "position:x", home.x, TREMBLE_STEP_SECS)


# How far above its resting spot a Rise floats before it settles.
static func _rise_overshoot(stage: Vector2) -> Vector2:
	return Vector2(0.0, stage.y * RISE_OVERSHOOT_FRACTION)


static func _ease(
	tweener: PropertyTweener,
	transition: Tween.TransitionType,
	easing: Tween.EaseType = Tween.EASE_OUT
) -> void:
	tweener.set_trans(transition).set_ease(easing)


# ── Silhouette and Wipe ──────────────────────────────────────────────────────


# The canvas x positions a wipe runs between: just past the art's left and right edges, so it starts fully hidden
# and ends fully shown.
static func _wipe_edges(target: Control) -> Vector2:
	var rect: Rect2 = target.get_global_rect()
	return Vector2(rect.position.x - WIPE_SOFT_EDGE, rect.end.x + WIPE_SOFT_EDGE)


# The effect material on `target` for the rest of this motion, put on it the first time it's asked for. Whatever
# material the art had is kept to put back, and an additive boss cue stays additive. The art's picture is drawn by
# its children (a portrait's TextureRect or video), so those are told to draw with it too.
static func _effect(target: Control) -> ShaderMaterial:
	if target.has_meta(_META_EFFECT):
		return target.material as ShaderMaterial
	var additive: bool = (
		target.material is CanvasItemMaterial
		and (target.material as CanvasItemMaterial).blend_mode == CanvasItemMaterial.BLEND_MODE_ADD
	)
	var effect: ShaderMaterial = ShaderMaterial.new()
	effect.shader = _effect_shader("blend_add" if additive else "blend_mix")
	# Every parameter is set up front: tween_property refuses (returns null for) a shader parameter the material
	# doesn't hold a value for yet, even one the shader declares with a default.
	effect.set_shader_parameter("soft_edge", WIPE_SOFT_EDGE)
	effect.set_shader_parameter("silhouette", 0.0)
	effect.set_shader_parameter("wipe_from", -1.0e9)
	effect.set_shader_parameter("wipe_to", 1.0e9)
	target.set_meta(_META_EFFECT, {"material": target.material, "shared": []})
	target.material = effect
	_share_effect(target)
	return effect


static func _effect_shader(blend_mode: String) -> Shader:
	if not _effect_shaders.has(blend_mode):
		var shader: Shader = Shader.new()
		shader.code = _EFFECT_SHADER % blend_mode
		_effect_shaders[blend_mode] = shader
	return _effect_shaders[blend_mode]


# Tells every part of the art under `target` that has no material of its own to draw with the effect. Called again
# after a swap, because a new picture arrives as new children.
static func _share_effect(target: Control) -> void:
	var shared: Array = target.get_meta(_META_EFFECT)["shared"]
	var waiting: Array[Node] = target.get_children()
	while not waiting.is_empty():
		var node: Node = waiting.pop_back()
		if not (node is CanvasItem):
			continue
		var item: CanvasItem = node
		if item.material != null:
			continue  # it draws with its own material, and so do its children
		if not item.use_parent_material:
			item.use_parent_material = true
			shared.append(item)
		waiting.append_array(item.get_children())


# Takes the effect off again, putting back the material the art had and what its children drew with.
static func _drop_effect(target: Control) -> void:
	if not target.has_meta(_META_EFFECT):
		return
	var record: Dictionary = target.get_meta(_META_EFFECT)
	target.material = record["material"]
	for item: Variant in record["shared"]:
		if is_instance_valid(item):
			(item as CanvasItem).use_parent_material = false
	target.remove_meta(_META_EFFECT)
