class_name MiniGameAxes
extends RefCounted

# What the secondary axes of a serial multi-axis device do during a mini-game: pure positions, in the 0-100 space
# scripts use, so the player's own axis limits still apply when they're sent (FunscriptPlayer.MoveGameAxis).
# A position dictionary reads {axis: position}. MINIGAMES_DESIGN.md → "Device on serial multi-axis".

const CENTRE: float = 50.0
const TWIST: String = "R0"
const ROLL: String = "R1"
const PITCH: String = "R2"
const SWAY: String = "L2"

const DIAL_TWIST_REACH: float = 50.0
# The wheel's first turns are far quicker than a device should circle, so several of them make one circle.
const WHEEL_TURNS_PER_CIRCLE: float = 2.0
const WHEEL_TURNS_PER_TWIST: float = 4.0
const CIRCLE_REACH: float = 25.0
const WHEEL_TWIST_REACH: float = 40.0
# As shares of the wheel's rotation: the motion fades in to start from centre, and fades out to land there.
const WHEEL_FADE_IN_UNTIL: float = 0.3
const WHEEL_FADE_OUT_FROM: float = 0.8

# One-off movements, as [{positions, ms}] steps: go to `positions` over `ms`, then the next step.
const WIN_NOD: Array[Dictionary] = [
	{"positions": {PITCH: 75.0}, "ms": 140},
	{"positions": {PITCH: CENTRE}, "ms": 240},
]
const WRONG_TRY_JOLT_REACH: float = 28.0
const WRONG_TRY_JOLT_STEP_MS: Array[int] = [70, 80, 110]


# The twist for a dial reading. Dials wrap and a twist can't, so one full turn of the dial swings the twist to one
# side, across the centre to the other and back, with no jump where the numbers wrap. It only says where the dial
# is, never how close that is to the answer.
static func dial_twist(dial_position: int, dial_size: int) -> Dictionary:
	var turn_share: float = float(dial_position) / float(maxi(1, dial_size))
	return {TWIST: CENTRE + DIAL_TWIST_REACH * sin(TAU * turn_share)}


# Tilt circling with the spinning wheel, with the twist sweeping more slowly beneath it. `turns_so_far` is how far
# the wheel has turned this spin, and `progress` the same as a 0-1 share of the whole spin.
static func spinning_wheel(turns_so_far: float, progress: float) -> Dictionary:
	var strength: float = (
		smoothstep(0.0, WHEEL_FADE_IN_UNTIL, progress)
		* (1.0 - smoothstep(WHEEL_FADE_OUT_FROM, 1.0, progress))
	)
	var circle_angle: float = TAU * turns_so_far / WHEEL_TURNS_PER_CIRCLE
	var twist_angle: float = TAU * turns_so_far / WHEEL_TURNS_PER_TWIST
	return {
		PITCH: CENTRE + CIRCLE_REACH * strength * sin(circle_angle),
		ROLL: CENTRE + CIRCLE_REACH * strength * cos(circle_angle),
		TWIST: CENTRE + WHEEL_TWIST_REACH * strength * sin(twist_angle),
	}


# A short shake from side to side, on whichever sideways axis the device has: sway, or roll without it.
static func wrong_try_jolt(has_sway: bool) -> Array[Dictionary]:
	var axis: String = SWAY if has_sway else ROLL
	return [
		{"positions": {axis: CENTRE + WRONG_TRY_JOLT_REACH}, "ms": WRONG_TRY_JOLT_STEP_MS[0]},
		{"positions": {axis: CENTRE - WRONG_TRY_JOLT_REACH}, "ms": WRONG_TRY_JOLT_STEP_MS[1]},
		{"positions": {axis: CENTRE}, "ms": WRONG_TRY_JOLT_STEP_MS[2]},
	]
