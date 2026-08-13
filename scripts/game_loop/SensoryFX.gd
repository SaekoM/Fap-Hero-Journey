class_name SensoryFX
extends Node

# ---------------------------------------------------------------------------
# SensoryFX — the non-gameplay (visual/audio) modifier engine.
#
# Owns everything a sensory hex touches: the screen overlays (Murk / Tunnel /
# Strobe / Bloodshot / Interference / Flicker), the composable per-pixel video
# shader (Drained / Bleary / Censored / Negative / Faded / Banded / Feverish /
# Fracture / Swoon), the Tremor shake, the Silence mute, and the dedicated
# VideoFX audio bus (Muffled / Cavern / Distorted / Faltering).
#
# GameLoop creates one in _build_effect_overlay and routes every hex through
# apply(); kinds this component doesn't own (gameplay hexes — Fog / Toll /
# Restless / Blinded) return false and stay GameLoop's problem. clear_all()
# tears every effect down; _exit_tree cleans the global audio bus so nothing
# leaks past the scene (Esc out of a test, journey complete, …).
#
# Effect values come from JourneyData.SENSORY_CATALOG: a normalized intensity
# (0–1, author-set or catalog default — see intensity_for) is mapped through the
# entry's imin/imax by _ival. imin may exceed imax for "inverted" effects where
# stronger = a lower number (pixelate blocks, strobe interval, low-pass cutoff,
# tunnel ramp).
# ---------------------------------------------------------------------------

const VIDEO_FX_BUS: String = "VideoFX"  # dedicated audio bus for hex audio effects

# One composable canvas_item shader for every per-pixel video hex. Each effect is
# a uniform defaulting to identity (off); multiple can be on at once. Applied to
# the video node only, so the HUD/frames keep their colour.
const VIDEO_FX_SHADER: String = """
shader_type canvas_item;

uniform float grayscale = 0.0;
uniform float invert = 0.0;
uniform float sepia = 0.0;
uniform float saturation = 1.0;
uniform float posterize = 0.0;   // 0 = off, else number of colour levels
uniform float blur = 0.0;        // 0 = off, else texel radius
uniform float pixelate = 0.0;    // 0 = off, else blocks across the width
uniform float chromatic = 0.0;   // 0 = off, else channel UV offset
uniform float wave = 0.0;        // 0 = off, else ripple amplitude in UV

void fragment() {
	vec2 uv = UV;

	if (wave > 0.0) {
		uv.x += sin(uv.y * 28.0 + TIME * 3.0) * wave;
		uv.y += cos(uv.x * 24.0 + TIME * 2.3) * wave;
	}

	if (pixelate > 0.0) {
		float ar = TEXTURE_PIXEL_SIZE.y / TEXTURE_PIXEL_SIZE.x;
		vec2 grid = vec2(pixelate, max(1.0, pixelate / ar));
		uv = (floor(uv * grid) + 0.5) / grid;
	}

	vec4 col;
	if (chromatic > 0.0) {
		col.r = texture(TEXTURE, uv + vec2(chromatic, 0.0)).r;
		col.g = texture(TEXTURE, uv).g;
		col.b = texture(TEXTURE, uv - vec2(chromatic, 0.0)).b;
		col.a = texture(TEXTURE, uv).a;
	} else if (blur > 0.0) {
		vec2 t = TEXTURE_PIXEL_SIZE * blur;
		vec4 s = texture(TEXTURE, uv) * 2.0;
		s += texture(TEXTURE, uv + vec2(t.x, 0.0));
		s += texture(TEXTURE, uv - vec2(t.x, 0.0));
		s += texture(TEXTURE, uv + vec2(0.0, t.y));
		s += texture(TEXTURE, uv - vec2(0.0, t.y));
		s += texture(TEXTURE, uv + t);
		s += texture(TEXTURE, uv - t);
		s += texture(TEXTURE, uv + vec2(t.x, -t.y));
		s += texture(TEXTURE, uv + vec2(-t.x, t.y));
		col = s / 10.0;
	} else {
		col = texture(TEXTURE, uv);
	}

	vec3 c = col.rgb;

	if (saturation != 1.0) {
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(vec3(l), c, saturation);
	}
	if (posterize > 0.0) {
		c = floor(c * posterize) / posterize;
	}
	if (sepia > 0.0) {
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(c, vec3(l) * vec3(1.07, 0.74, 0.43), sepia);
	}
	if (grayscale > 0.0) {
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(c, vec3(l), grayscale);
	}
	if (invert > 0.0) {
		c = mix(c, vec3(1.0) - c, invert);
	}

	COLOR = vec4(c, col.a);
}
"""

# Animated TV static for the Interference hex, drawn on a full-rect overlay.
const STATIC_SHADER: String = """
shader_type canvas_item;

uniform float strength : hint_range(0.0, 1.0) = 0.30;

float rand(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 cell = floor(UV * vec2(480.0, 270.0));
	float n = rand(cell + vec2(fract(TIME) * 91.0, fract(TIME * 1.7) * 57.0));
	COLOR = vec4(vec3(n), strength);
}
"""

var _video: VideoStreamPlayer = null

var _murk: ColorRect = null  # "Murk" — dims the screen
var _tunnel: TextureRect = null  # "Tunnel" — closing vignette
var _tunnel_grad: Gradient = null  # Tunnel gradient (mid ramp point moves with intensity)
var _bloodshot: ColorRect = null  # "Bloodshot" — pulsing red haze
var _static: ColorRect = null  # "Interference" — animated TV static
var _flicker: ColorRect = null  # "Flicker" — erratic brightness dips
var _strobe: ColorRect = null  # "Strobe" — flickering black overlay
var _fx_mat: ShaderMaterial = null  # composable per-pixel video effects

var _strobe_tween: Tween = null
var _bloodshot_tween: Tween = null
var _flicker_tween: Tween = null
var _volwobble_tween: Tween = null

var _tremor: bool = false  # "Tremor" — shakes the video each frame
var _tremor_amp: float = 9.0  # shake amplitude (set from intensity)
var _muted: bool = false  # a "Silence" hex muted the video
var _pre_mute_volume_db: float = 0.0  # restored when a "Silence" hex ends

# --- Reconcile / fade state (drives timed item sensory alongside round sensory) ---
const FADE_SECS: float = 1.5  # how long a departing effect eases out on reconcile
# Per-pixel shader effects → [uniform name, identity/off value]. Also the set used to decide when the
# shader material can be dropped (no shader kind applied or fading).
const _SHADER_OFF: Dictionary = {
	"grayscale": ["grayscale", 0.0],
	"blur": ["blur", 0.0],
	"pixelate": ["pixelate", 0.0],
	"invert": ["invert", 0.0],
	"sepia": ["sepia", 0.0],
	"posterize": ["posterize", 0.0],
	"saturate": ["saturation", 1.0],
	"chromatic": ["chromatic", 0.0],
	"wave": ["wave", 0.0],
}
var _applied: Dictionary = {}  # kind → applied intensity (ON, not fading); skips no-op re-applies
var _fading: Dictionary = {}  # kind → the Tween easing it off; a re-request cancels it
var _audio_fx: Dictionary = {}  # audio kind → its AudioEffect on the bus (targeted fade + removal)


# Builds the overlay nodes (as children of overlay_parent, in back-to-front
# order: murk → tunnel → bloodshot → static → flicker → strobe), the video-FX
# material, and the audio bus. Call once, where the overlay stack should sit in
# the parent's draw order.
func setup(video: VideoStreamPlayer, overlay_parent: Control) -> void:
	_video = video

	# Murk — a flat dark dim (a softer Blinded; you can still half-see).
	_murk = _make_full_rect_color(Color(0, 0, 0, 0.72), overlay_parent)

	# Tunnel — a radial vignette: clear centre, dark edges, mid ramp point pulled
	# inward so the clear centre is narrow and the edges crush to near-black.
	_tunnel_grad = Gradient.new()
	_tunnel_grad.set_color(0, Color(0, 0, 0, 0.0))
	_tunnel_grad.set_color(1, Color(0, 0, 0, 0.99))
	_tunnel_grad.add_point(0.45, Color(0, 0, 0, 0.40))
	var gtex: GradientTexture2D = GradientTexture2D.new()
	gtex.gradient = _tunnel_grad
	gtex.fill = GradientTexture2D.FILL_RADIAL
	gtex.fill_from = Vector2(0.5, 0.5)
	gtex.fill_to = Vector2(0.5, 1.0)
	_tunnel = TextureRect.new()
	_tunnel.texture = gtex
	_tunnel.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_tunnel.stretch_mode = TextureRect.STRETCH_SCALE
	_tunnel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tunnel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tunnel.visible = false
	overlay_parent.add_child(_tunnel)

	# Per-pixel video hexes all ride ONE composable shader on the video node so
	# several can stack at once (double-curse / multi-hex boss). Each is a uniform,
	# default = identity; _set_video_fx flips one on, _reset_video_fx clears all.
	var fx_shader: Shader = Shader.new()
	fx_shader.code = VIDEO_FX_SHADER
	_fx_mat = ShaderMaterial.new()
	_fx_mat.shader = fx_shader
	_reset_video_fx_params()

	# Bloodshot — a red haze that pulses (animated in _start_bloodshot).
	_bloodshot = _make_full_rect_color(Color(0.6, 0.0, 0.0, 0.35), overlay_parent)

	# Interference — animated TV static, generated by a noise shader on the rect.
	var static_shader: Shader = Shader.new()
	static_shader.code = STATIC_SHADER
	var static_mat: ShaderMaterial = ShaderMaterial.new()
	static_mat.shader = static_shader
	_static = _make_full_rect_color(Color(0, 0, 0, 1), overlay_parent)
	_static.material = static_mat

	# Flicker — opaque black whose alpha jitters in quick dips (animated in
	# _start_flicker). Distinct from Strobe's slow full fade-to-black.
	_flicker = _make_full_rect_color(Color(0, 0, 0, 1), overlay_parent)
	_flicker.modulate.a = 0.0

	# Strobe — opaque black whose alpha flickers (animated in _start_strobe).
	_strobe = _make_full_rect_color(Color(0, 0, 0, 1), overlay_parent)
	_strobe.modulate.a = 0.0

	_setup_audio_fx_bus()


func _make_full_rect_color(color: Color, parent: Control) -> ColorRect:
	var rect: ColorRect = ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.color = color
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	parent.add_child(rect)
	return rect


# Leaving the game loop (Esc out of a test, journey complete, etc.) — strip any
# audio effects off the global VideoFX bus so they don't bleed into the next run
# or anything else routed through it. The overlay nodes die with the scene.
func _exit_tree() -> void:
	_stop_volwobble()
	_clear_audio_effects()


# ---------------------------------------------------------------------------
# Intensity
# ---------------------------------------------------------------------------


# This round's intensity (0–1) for a sensory modifier: the author's per-round
# override if set, else the catalog default. Used by effect and boss rounds.
# `sensory_intensity` is keyed by the ORIGINAL catalog name, so look up via `_ref`
# (present on override-resolved entries) — a custom-renamed sensory effect keeps its
# intensity. Falls back to `name` for un-resolved entries (boss rounds).
static func intensity_for(round: Dictionary, entry: Dictionary) -> float:
	var overrides: Dictionary = round.get("sensory_intensity", {})
	var nm: String = str(entry.get("_ref", entry.get("name", "")))
	if overrides.has(nm):
		return clampf(float(overrides[nm]), 0.0, 1.0)
	return float(entry.get("idef", 0.5))


# The real effect value for a sensory hex at the given intensity (0–1), mapped
# through the catalog entry's imin/imax. imin may exceed imax (inverted effects).
func _ival(roll: Dictionary, intensity: float) -> float:
	return lerpf(
		float(roll.get("imin", 0.0)), float(roll.get("imax", 1.0)), clampf(intensity, 0.0, 1.0)
	)


# ---------------------------------------------------------------------------
# Apply / clear
# ---------------------------------------------------------------------------


# Applies one sensory hex. Returns true when the kind belongs to this component;
# false means it's a gameplay hex the caller (GameLoop) must handle itself.
#
# The author's `intensity` is scaled by the player's SENSORY STRENGTH setting before anything
# is mapped through imin/imax — one multiply here covers every effect, since they all read
# their value from _ival. It softens, it doesn't disable: at the 0.1 floor each effect sits at
# its catalog minimum, and which effects a round uses stays the author's call.
# `player_scaled` folds in the player's SENSORY STRENGTH comfort setting. The builder's preview
# passes false: the author is tuning the round's own intensity, and showing it pre-scaled would
# have them compensate for a setting only their own install has.
func apply(roll: Dictionary, intensity: float = 1.0, player_scaled: bool = true) -> bool:
	if player_scaled:
		intensity *= SettingsService.get_sensory_strength()
	intensity = clampf(intensity, 0.0, 1.0)
	match String(roll.get("kind", "")):
		"mute":
			_muted = true
			_pre_mute_volume_db = _video.volume_db
			_video.volume_db = -80.0
		"murk":
			_murk.color.a = _ival(roll, intensity)
			_murk.visible = true
		"tunnel":
			_set_tunnel_intensity(_ival(roll, intensity), intensity)
			_tunnel.visible = true
		"strobe":
			_strobe.visible = true
			_start_strobe(_ival(roll, intensity))
		# Per-pixel video hexes — one composable shader, one uniform each.
		"grayscale":
			_set_video_fx("grayscale", _ival(roll, intensity))
		"blur":
			_set_video_fx("blur", _ival(roll, intensity))
		"pixelate":
			_set_video_fx("pixelate", _ival(roll, intensity))
		"invert":
			_set_video_fx("invert", _ival(roll, intensity))
		"sepia":
			_set_video_fx("sepia", _ival(roll, intensity))
		"posterize":
			_set_video_fx("posterize", _ival(roll, intensity))
		"saturate":
			_set_video_fx("saturation", _ival(roll, intensity))
		"chromatic":
			_set_video_fx("chromatic", _ival(roll, intensity))
		"wave":
			_set_video_fx("wave", _ival(roll, intensity))
		# Overlay-node visual hexes.
		"bloodshot":
			_bloodshot.visible = true
			_start_bloodshot(_ival(roll, intensity))
		"static":
			if _static.material != null:
				(_static.material as ShaderMaterial).set_shader_parameter(
					"strength", _ival(roll, intensity)
				)
			_static.visible = true
		"flicker":
			_flicker.visible = true
			_start_flicker(_ival(roll, intensity))
		"tremor":
			_tremor_amp = _ival(roll, intensity)
			_tremor = true
		# Audio hexes — bus effects (Faltering wobbles the bus level).
		"lowpass":
			var lp: AudioEffectLowPassFilter = AudioEffectLowPassFilter.new()
			lp.cutoff_hz = _ival(roll, intensity)
			_apply_audio("lowpass", lp)
		"reverb":
			var rv: AudioEffectReverb = AudioEffectReverb.new()
			rv.wet = _ival(roll, intensity)  # imin/imax = wet range
			rv.room_size = lerpf(0.6, 0.95, clampf(intensity, 0.0, 1.0))
			rv.dry = 0.5
			_apply_audio("reverb", rv)
		"distort":
			var ds: AudioEffectDistortion = AudioEffectDistortion.new()
			ds.mode = AudioEffectDistortion.MODE_CLIP
			ds.drive = _ival(roll, intensity)
			ds.post_gain = -10.0
			_apply_audio("distort", ds)
		"volwobble":
			_start_volwobble(_ival(roll, intensity))
		_:
			return false  # not a sensory kind — gameplay hexes stay with GameLoop
	return true


# Undoes every sensory effect (mute / video shader / audio bus / overlays /
# tremor). Safe to call when none are active — each branch no-ops.
func clear_all() -> void:
	# Cancel any in-flight fades and drop all reconcile tracking — this is the hard reset.
	for kind: String in _fading.keys():
		var t: Tween = _fading[kind]
		if t != null and t.is_valid():
			t.kill()
	_fading.clear()
	_applied.clear()
	if _muted:
		_muted = false
		_video.volume_db = _pre_mute_volume_db
	_reset_video_fx()  # undo every per-pixel video hex (Drained/Bleary/…)
	_clear_audio_effects()  # undo low-pass / reverb / distortion + restore bus level
	_stop_strobe()
	_stop_bloodshot()
	_stop_flicker()
	_stop_volwobble()
	_tremor = false
	for overlay: Control in [_murk, _tunnel, _bloodshot, _static, _flicker, _strobe]:
		if overlay != null:
			overlay.visible = false
			overlay.modulate.a = 1.0


# Per-frame video jitter for the Tremor hex (mixed frequencies so it reads as a
# shake, not a wobble). Zero when inactive — the caller adds it unconditionally
# after fitting the video each frame.
func tremor_offset() -> Vector2:
	if not _tremor:
		return Vector2.ZERO
	var ts: float = Time.get_ticks_msec() / 1000.0
	return (
		Vector2(sin(ts * 97.0) + sin(ts * 61.0), cos(ts * 89.0) + sin(ts * 53.0))
		* (_tremor_amp * 0.5)
	)


# ---------------------------------------------------------------------------
# Video shader
# ---------------------------------------------------------------------------


# Turns one per-pixel video effect on (lazily assigning the shared shader to the
# video). Several may be active at once — each is an independent uniform.
func _set_video_fx(param: String, value: float) -> void:
	if _fx_mat == null:
		return
	_video.material = _fx_mat
	_fx_mat.set_shader_parameter(param, value)


# Resets every video-effect uniform to its identity (off) value.
func _reset_video_fx_params() -> void:
	if _fx_mat == null:
		return
	_fx_mat.set_shader_parameter("grayscale", 0.0)
	_fx_mat.set_shader_parameter("invert", 0.0)
	_fx_mat.set_shader_parameter("sepia", 0.0)
	_fx_mat.set_shader_parameter("saturation", 1.0)
	_fx_mat.set_shader_parameter("posterize", 0.0)
	_fx_mat.set_shader_parameter("blur", 0.0)
	_fx_mat.set_shader_parameter("pixelate", 0.0)
	_fx_mat.set_shader_parameter("chromatic", 0.0)
	_fx_mat.set_shader_parameter("wave", 0.0)


# Clears all video effects and drops the shader off the video entirely.
func _reset_video_fx() -> void:
	_reset_video_fx_params()
	_video.material = null


# Sets the Tunnel vignette from intensity: `mid_offset` (from imin/imax) moves the ramp point — smaller
# = narrower clear centre = a tighter tunnel — and `strength` (raw 0–1 intensity) scales the DARKNESS.
func _set_tunnel_intensity(mid_offset: float, strength: float) -> void:
	if _tunnel_grad == null:
		return
	_tunnel_grad.set_offset(1, clampf(mid_offset, 0.05, 0.95))
	# Scale the vignette darkness with intensity too — not just the ramp position — so a low setting is a
	# faint tunnel and a high one crushes to near-black. Without this only the ramp moved, so 1% and 100%
	# both read as "dark-edged vignette" and felt identical. Baked into the gradient, independent of
	# modulate.a (which the fade-out owns), so fades still work.
	var s: float = clampf(strength, 0.0, 1.0)
	_tunnel_grad.set_color(1, Color(0, 0, 0, lerpf(0.12, 0.40, s)))  # mid ramp point
	_tunnel_grad.set_color(2, Color(0, 0, 0, lerpf(0.30, 0.99, s)))  # dark edge


# ---------------------------------------------------------------------------
# Audio bus
# ---------------------------------------------------------------------------


# Routes the video's audio through a dedicated bus (→ Master) so audio hexes
# (low-pass / reverb / distortion / volume wobble) affect only the video, never
# any other sound. Idempotent — the bus survives scene reloads, so reuse it.
func _setup_audio_fx_bus() -> void:
	if AudioServer.get_bus_index(VIDEO_FX_BUS) == -1:
		var idx: int = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, VIDEO_FX_BUS)
		AudioServer.set_bus_send(idx, "Master")
	_video.bus = VIDEO_FX_BUS
	# The bus is global and survives scene reloads — start each session clean so a
	# prior run that exited mid-round (e.g. Esc out of a test) can't leave a stale
	# audio effect (distortion/reverb/…) routed onto this run's video.
	_clear_audio_effects()


func _add_audio_effect(effect: AudioEffect) -> void:
	var idx: int = AudioServer.get_bus_index(VIDEO_FX_BUS)
	if idx != -1:
		AudioServer.add_bus_effect(idx, effect)


# Strips every audio effect off the VideoFX bus and restores its level (undoing a
# Faltering wobble). Safe when none are present.
func _clear_audio_effects() -> void:
	_audio_fx.clear()
	var idx: int = AudioServer.get_bus_index(VIDEO_FX_BUS)
	if idx == -1:
		return
	while AudioServer.get_bus_effect_count(idx) > 0:
		AudioServer.remove_bus_effect(idx, 0)
	AudioServer.set_bus_volume_db(idx, 0.0)


# ---------------------------------------------------------------------------
# Animated overlays (tween drivers)
# ---------------------------------------------------------------------------


func _start_strobe(clear_secs: float = 3.0) -> void:
	_stop_strobe()
	# Pulse to full black: <clear_secs> clear → 1s fade in → 1s black → 1s fade
	# back. Intensity shortens the clear gap (more frequent = more intense).
	_strobe.modulate.a = 0.0
	_strobe_tween = create_tween().set_loops()
	_strobe_tween.tween_interval(maxf(0.2, clear_secs))
	_strobe_tween.tween_property(_strobe, "modulate:a", 1.0, 1.0)
	_strobe_tween.tween_interval(1.0)
	_strobe_tween.tween_property(_strobe, "modulate:a", 0.0, 1.0)


func _stop_strobe() -> void:
	if _strobe_tween != null and _strobe_tween.is_valid():
		_strobe_tween.kill()
	_strobe_tween = null
	if _strobe != null:
		_strobe.modulate.a = 0.0


func _start_bloodshot(peak: float = 1.0) -> void:
	_stop_bloodshot()
	# Pulse between a faint floor and the intensity-driven peak alpha.
	_bloodshot.modulate.a = 0.0
	_bloodshot_tween = create_tween().set_loops()
	_bloodshot_tween.tween_property(_bloodshot, "modulate:a", clampf(peak, 0.0, 1.0), 0.9)
	_bloodshot_tween.tween_property(_bloodshot, "modulate:a", clampf(peak * 0.3, 0.0, 1.0), 0.9)


func _stop_bloodshot() -> void:
	if _bloodshot_tween != null and _bloodshot_tween.is_valid():
		_bloodshot_tween.kill()
	_bloodshot_tween = null
	if _bloodshot != null:
		_bloodshot.modulate.a = 0.0


# Quick erratic black dips — a jittered cadence so it reads as a faulty signal
# rather than the slow, regular Strobe fade.
func _start_flicker(scale: float = 1.0) -> void:
	_stop_flicker()
	# Intensity scales the dip darkness (cadence stays fixed). clampf keeps the
	# scaled peaks valid even when the catalog range pushes above 1.0.
	var s: float = clampf(scale, 0.0, 1.0 / 0.85)  # 0.85 is the tallest dip below
	_flicker.modulate.a = 0.0
	_flicker_tween = create_tween().set_loops()
	_flicker_tween.tween_interval(0.8)
	_flicker_tween.tween_property(_flicker, "modulate:a", 0.7 * s, 0.04)
	_flicker_tween.tween_property(_flicker, "modulate:a", 0.0, 0.04)
	_flicker_tween.tween_interval(0.12)
	_flicker_tween.tween_property(_flicker, "modulate:a", 0.45 * s, 0.03)
	_flicker_tween.tween_property(_flicker, "modulate:a", 0.0, 0.06)
	_flicker_tween.tween_interval(0.5)
	_flicker_tween.tween_property(_flicker, "modulate:a", 0.85 * s, 0.03)
	_flicker_tween.tween_property(_flicker, "modulate:a", 0.0, 0.05)


func _stop_flicker() -> void:
	if _flicker_tween != null and _flicker_tween.is_valid():
		_flicker_tween.kill()
	_flicker_tween = null
	if _flicker != null:
		_flicker.modulate.a = 0.0


# Faltering — swells the VideoFX bus level up and down (bus, not _video.volume_db,
# so it never collides with a Silence/mute hex on the same round).
func _start_volwobble(depth_db: float = -24.0) -> void:
	_stop_volwobble()
	var idx: int = AudioServer.get_bus_index(VIDEO_FX_BUS)
	if idx == -1:
		return
	# Swell between 0 dB and the intensity-driven depth (deeper = more dramatic).
	var set_db: Callable = func(v: float) -> void: AudioServer.set_bus_volume_db(idx, v)
	_volwobble_tween = create_tween().set_loops()
	_volwobble_tween.tween_method(set_db, 0.0, depth_db, 1.2)
	_volwobble_tween.tween_method(set_db, depth_db, 0.0, 1.2)


func _stop_volwobble() -> void:
	if _volwobble_tween != null and _volwobble_tween.is_valid():
		_volwobble_tween.kill()
	_volwobble_tween = null


# ---------------------------------------------------------------------------
# Declarative reconcile — round sensory + timed item sensory funnel through here
# ---------------------------------------------------------------------------


# Drives the engine from a desired set of effects. Each request is {roll: <SENSORY_CATALOG entry>,
# intensity: 0-1}. Kinds present are applied (strongest intensity wins on a repeated kind); kinds that
# left the set ease out over FADE_SECS. One engine state reflects everything active, and an expiring
# item effect fades instead of snapping. No-op re-applies are skipped so animated effects don't restart.
func reconcile(requests: Array) -> void:
	var desired: Dictionary = {}  # kind → {roll, intensity}
	for req: Dictionary in requests:
		var roll: Dictionary = req.get("roll", {})
		var kind: String = str(roll.get("kind", ""))
		if kind == "":
			continue
		var intensity: float = float(req.get("intensity", 1.0))
		if not desired.has(kind) or intensity > float((desired[kind] as Dictionary)["intensity"]):
			desired[kind] = {"roll": roll, "intensity": intensity}

	for kind: String in desired:
		var intensity: float = float((desired[kind] as Dictionary)["intensity"])
		_cancel_fade(kind)
		if _applied.has(kind) and is_equal_approx(float(_applied[kind]), intensity):
			continue
		apply((desired[kind] as Dictionary)["roll"], intensity)
		_applied[kind] = intensity

	for kind: String in _applied.keys():
		if not desired.has(kind) and not _fading.has(kind):
			_begin_fade(kind)


# Starts (or immediately finishes) the ease-out for a kind that left the desired set.
func _begin_fade(kind: String) -> void:
	_applied.erase(kind)
	var tween: Tween = _make_fade_tween(kind)
	if tween == null:
		_finalize_off(kind)  # nothing to animate (binary/unknown) — hard off
		return
	_fading[kind] = tween
	tween.finished.connect(
		func() -> void:
			_fading.erase(kind)
			_finalize_off(kind)
	)


# Cancels an in-flight fade so the kind can be re-applied at full strength (a killed tween never
# emits `finished`, so its finalize won't run).
func _cancel_fade(kind: String) -> void:
	if not _fading.has(kind):
		return
	var t: Tween = _fading[kind]
	if t != null and t.is_valid():
		t.kill()
	_fading.erase(kind)


# Builds the ease-out tween for one kind (ramping its value toward "off"); null when the kind has no
# smooth ramp (finalize hard-cuts it). Stops any driving loop first so the fade owns the property.
func _make_fade_tween(kind: String) -> Tween:
	if _SHADER_OFF.has(kind):
		if _fx_mat == null:
			return null
		var param: String = str((_SHADER_OFF[kind] as Array)[0])
		var off_val: float = float((_SHADER_OFF[kind] as Array)[1])
		var cur: float = _fx_mat.get_shader_parameter(param)
		var st: Tween = create_tween()
		st.tween_method(
			func(v: float) -> void: _fx_mat.set_shader_parameter(param, v), cur, off_val, FADE_SECS
		)
		return st
	match kind:
		"murk":
			var t: Tween = create_tween()
			t.tween_property(_murk, "color:a", 0.0, FADE_SECS)
			return t
		"tunnel":
			var t: Tween = create_tween()
			t.tween_property(_tunnel, "modulate:a", 0.0, FADE_SECS)
			return t
		"static":
			var t: Tween = create_tween()
			t.tween_property(_static, "modulate:a", 0.0, FADE_SECS)
			return t
		"strobe":
			# Kill the pulsing LOOP (not _stop_strobe, which also zeroes the alpha) and fade the
			# overlay out from wherever it currently sits.
			if _strobe_tween != null and _strobe_tween.is_valid():
				_strobe_tween.kill()
			_strobe_tween = null
			var t: Tween = create_tween()
			t.tween_property(_strobe, "modulate:a", 0.0, FADE_SECS)
			return t
		"bloodshot":
			if _bloodshot_tween != null and _bloodshot_tween.is_valid():
				_bloodshot_tween.kill()
			_bloodshot_tween = null
			var t: Tween = create_tween()
			t.tween_property(_bloodshot, "modulate:a", 0.0, FADE_SECS)
			return t
		"flicker":
			if _flicker_tween != null and _flicker_tween.is_valid():
				_flicker_tween.kill()
			_flicker_tween = null
			var t: Tween = create_tween()
			t.tween_property(_flicker, "modulate:a", 0.0, FADE_SECS)
			return t
		"tremor":
			var t: Tween = create_tween()
			t.tween_method(func(v: float) -> void: _tremor_amp = v, _tremor_amp, 0.0, FADE_SECS)
			return t
		"mute":
			var t: Tween = create_tween()
			t.tween_property(_video, "volume_db", _pre_mute_volume_db, FADE_SECS)
			return t
		"volwobble":
			_stop_volwobble()
			var vidx: int = AudioServer.get_bus_index(VIDEO_FX_BUS)
			if vidx == -1:
				return null
			var t: Tween = create_tween()
			t.tween_method(
				func(v: float) -> void: AudioServer.set_bus_volume_db(vidx, v),
				AudioServer.get_bus_volume_db(vidx),
				0.0,
				FADE_SECS
			)
			return t
		"lowpass":
			var lp: AudioEffect = _audio_fx.get("lowpass")
			if lp == null:
				return null
			var t: Tween = create_tween()
			t.tween_property(lp, "cutoff_hz", 20000.0, FADE_SECS)
			return t
		"reverb":
			var rv: AudioEffect = _audio_fx.get("reverb")
			if rv == null:
				return null
			var t: Tween = create_tween()
			t.tween_property(rv, "wet", 0.0, FADE_SECS)
			return t
		"distort":
			var ds: AudioEffect = _audio_fx.get("distort")
			if ds == null:
				return null
			var t: Tween = create_tween()
			t.tween_property(ds, "drive", 0.0, FADE_SECS)
			return t
	return null


# Hard "off" for a kind after its fade completes (or immediately when it has no fade).
func _finalize_off(kind: String) -> void:
	if _SHADER_OFF.has(kind):
		if _fx_mat != null:
			_fx_mat.set_shader_parameter(
				str((_SHADER_OFF[kind] as Array)[0]), float((_SHADER_OFF[kind] as Array)[1])
			)
		_drop_shader_if_idle()
		return
	match kind:
		"murk":
			if _murk != null:
				_murk.visible = false
				_murk.color.a = 0.0
		"tunnel":
			if _tunnel != null:
				_tunnel.visible = false
				_tunnel.modulate.a = 1.0
		"static":
			if _static != null:
				_static.visible = false
				_static.modulate.a = 1.0
		"strobe":
			_stop_strobe()
			if _strobe != null:
				_strobe.visible = false
		"bloodshot":
			_stop_bloodshot()
			if _bloodshot != null:
				_bloodshot.visible = false
		"flicker":
			_stop_flicker()
			if _flicker != null:
				_flicker.visible = false
		"mute":
			_muted = false
			_video.volume_db = _pre_mute_volume_db
		"tremor":
			_tremor = false
			_tremor_amp = 0.0
		"volwobble":
			_stop_volwobble()
			var vidx: int = AudioServer.get_bus_index(VIDEO_FX_BUS)
			if vidx != -1:
				AudioServer.set_bus_volume_db(vidx, 0.0)
		"lowpass", "reverb", "distort":
			_remove_audio_fx(kind)


# Drops the shader material off the video once no per-pixel effect is applied or fading.
func _drop_shader_if_idle() -> void:
	for k: String in _SHADER_OFF:
		if _applied.has(k) or _fading.has(k):
			return
	if _video != null:
		_video.material = null


# Adds an audio bus effect for `kind`, replacing any prior instance so a re-apply (intensity change)
# doesn't stack duplicates. Tracked in _audio_fx for targeted fade + removal.
func _apply_audio(kind: String, effect: AudioEffect) -> void:
	_remove_audio_fx(kind)
	_audio_fx[kind] = effect
	_add_audio_effect(effect)


# Removes the tracked audio effect for `kind` from the bus by identity, leaving other effects intact.
func _remove_audio_fx(kind: String) -> void:
	if not _audio_fx.has(kind):
		return
	var effect: AudioEffect = _audio_fx[kind]
	var idx: int = AudioServer.get_bus_index(VIDEO_FX_BUS)
	if idx != -1:
		for i: int in AudioServer.get_bus_effect_count(idx):
			if AudioServer.get_bus_effect(idx, i) == effect:
				AudioServer.remove_bus_effect(idx, i)
				break
	_audio_fx.erase(kind)
