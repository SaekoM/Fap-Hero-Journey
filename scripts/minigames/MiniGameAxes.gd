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

# Stop the Bar's twist follows the needle; Hold & Release's tilt rises with the gauge; Push Your Luck's roll swings
# with the stack, gently when it's safe and widely near certain loss.
const NEEDLE_TWIST_REACH: float = 40.0
const GAUGE_TILT_REACH: float = 40.0
const STACK_ROLL_SAFE_REACH: float = 8.0
const STACK_ROLL_RISKY_REACH: float = 35.0

# One-off movements, as [{positions, ms}] steps: go to `positions` over `ms`, then the next step.
const NOD_REACH: float = 25.0
const NOD_DOWN_MS: int = 140
const NOD_BACK_MS: int = 240
const WIN_NOD: Array[Dictionary] = [
	{"positions": {PITCH: CENTRE + NOD_REACH}, "ms": NOD_DOWN_MS},
	{"positions": {PITCH: CENTRE}, "ms": NOD_BACK_MS},
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


# The twist for Stop the Bar's needle, `needle` 0 at the bar's left end to 1 at its right: one side to the other.
static func needle_twist(needle: float) -> Dictionary:
	return {TWIST: CENTRE + NEEDLE_TWIST_REACH * (2.0 * clampf(needle, 0.0, 1.0) - 1.0)}


# The tilt for Hold & Release's gauge, `level` 0 empty to 1 full: centred when empty, rising as it fills.
static func gauge_tilt(level: float) -> Dictionary:
	return {PITCH: CENTRE + GAUGE_TILT_REACH * clampf(level, 0.0, 1.0)}


# The roll for Push Your Luck's stack: `wave` is where the sway is in its swing, -1 to 1, and `risk` the risk on show,
# 0-1, which sets how wide it swings. It goes by the risk rather than how far the pieces move on screen, because a short
# stack barely moves there at all.
static func stack_roll(wave: float, risk: float) -> Dictionary:
	var reach: float = lerpf(STACK_ROLL_SAFE_REACH, STACK_ROLL_RISKY_REACH, clampf(risk, 0.0, 1.0))
	return {ROLL: CENTRE + reach * clampf(wave, -1.0, 1.0)}


# A nod from wherever the tilt already is, ending back there: away from the nearer end, so it's never cut short.
static func nod_from(pitch: float) -> Array[Dictionary]:
	var nod_to: float = pitch + NOD_REACH if pitch <= CENTRE else pitch - NOD_REACH
	return [
		{"positions": {PITCH: nod_to}, "ms": NOD_DOWN_MS},
		{"positions": {PITCH: pitch}, "ms": NOD_BACK_MS},
	]


# How long a one-off movement takes to play.
static func moves_ms(steps: Array) -> int:
	var total: int = 0
	for step: Dictionary in steps:
		total += int(step["ms"])
	return total


# A short shake from side to side, on whichever sideways axis the device has: sway, or roll without it.
static func wrong_try_jolt(has_sway: bool) -> Array[Dictionary]:
	var axis: String = SWAY if has_sway else ROLL
	return [
		{"positions": {axis: CENTRE + WRONG_TRY_JOLT_REACH}, "ms": WRONG_TRY_JOLT_STEP_MS[0]},
		{"positions": {axis: CENTRE - WRONG_TRY_JOLT_REACH}, "ms": WRONG_TRY_JOLT_STEP_MS[1]},
		{"positions": {axis: CENTRE}, "ms": WRONG_TRY_JOLT_STEP_MS[2]},
	]
