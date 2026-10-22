extends WorldEnvironment

# ---------------------------------------------------------------------------
# GlowEnvironment  –  app-wide neon bloom
#
# Autoloaded so the whole app shares one glow post-process: the bright palette
# (PURPLE_BRIGHT #b21eff / MAGENTA #e000e0, both near the top of the 0–1 range)
# blooms into a real neon glow instead of the flat 2px borders + fake shadow we
# use elsewhere. One WorldEnvironment under the root viewport covers every scene.
#
# Requires a RenderingDevice backend (Forward+ / Mobile). The project renders
# with d3d12 (Forward+), so glow is available. 2D glow reads the framebuffer and
# blooms any pixel brighter than GLOW_THRESHOLD, which is why the threshold sits
# just under the neon colors. Background mode MUST be Canvas for 2D glow.
#
# Tuning lives in the consts below.
#   • Too strong / washing out bright VIDEO during a round? Lower GLOW_INTENSITY,
#     raise GLOW_THRESHOLD, or call `GlowEnvironment.set_enabled(false)` while a
#     video plays (and true again on the menus).
#   • Want a punchier sign-on-black look? Switch the blend mode to ADDITIVE.
# ---------------------------------------------------------------------------

const GLOW_INTENSITY: float = 0.9  # overall bloom strength
const GLOW_BLOOM: float = 0.05  # small constant bloom added everywhere
const GLOW_STRENGTH: float = 1.1  # per-sample blur strength
const GLOW_THRESHOLD: float = 0.85  # pixels brighter than this glow (neon sits ~0.88–1.0)
# High contrast (a colour mode for low vision) turns the bloom down: its white text and edges sit above
# the threshold and would smear (COLOUR_MODES_DESIGN.md).
const HIGH_CONTRAST_INTENSITY: float = 0.25


func _ready() -> void:
	environment = _build_environment()
	_apply_colour_mode(UITheme.colour_mode)
	UITheme.colour_mode_changed.connect(_apply_colour_mode)


func _apply_colour_mode(_mode: String) -> void:
	if environment != null:
		environment.glow_intensity = (
			HIGH_CONTRAST_INTENSITY if UITheme.is_high_contrast() else GLOW_INTENSITY
		)


func _build_environment() -> Environment:
	var env: Environment = Environment.new()

	# 2D project: the canvas is the background; glow composites on top of it.
	# (2D glow does nothing unless background mode is Canvas.)
	env.background_mode = Environment.BG_CANVAS

	env.glow_enabled = true
	env.glow_normalized = true  # steadier intensity regardless of resolution
	env.glow_intensity = GLOW_INTENSITY
	env.glow_bloom = GLOW_BLOOM
	env.glow_strength = GLOW_STRENGTH
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN  # gentler than ADDITIVE over video
	env.glow_hdr_threshold = GLOW_THRESHOLD

	# Spread the blur across a few mip levels for a soft, sign-like halo rather
	# than a tight ring. set_glow_level is 0-indexed (valid 0–6), even though the
	# inspector labels them 1–7: indices 1–2 carry the body, 3–4 the wide falloff.
	env.set_glow_level(0, 0.0)
	env.set_glow_level(1, 1.0)
	env.set_glow_level(2, 1.0)
	env.set_glow_level(3, 0.6)
	env.set_glow_level(4, 0.3)
	env.set_glow_level(5, 0.0)
	env.set_glow_level(6, 0.0)

	return env


# Runtime on/off (e.g. GameLoop could drop glow while a video plays so bright
# scenes aren't bloomed). Safe to call before _ready — no-ops until built.
func set_enabled(on: bool) -> void:
	if environment != null:
		environment.glow_enabled = on
