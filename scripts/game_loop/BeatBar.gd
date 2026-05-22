extends Control

# ---------------------------------------------------------------------------
# BeatBar.gd  –  Optional rhythm visualiser
# A horizontal track that previews upcoming "V motions" (a down stroke feeding
# into an up stroke) read from the funscript. Each V is an orb that scrolls
# toward a fixed hit-line and lands exactly when the device reaches the bottom
# of that stroke. Purely visual — no input, no scoring.
#
# Driven externally by GameLoop:
#   set_beats(beats)  – Array of Vector2(time_ms, depth 0-100) from FunscriptPlayer
#   set_time(ms)      – current playback clock, called every frame
# ---------------------------------------------------------------------------

const LOOKAHEAD_MS:  float = 2000.0   # how far ahead an orb becomes visible
const HIT_X_FRAC:    float = 0.16     # hit-line x, as a fraction of the width
const ORB_RADIUS:    float = 10.0     # uniform orb size — intensity shows as colour
const ORB_GLOW_MULT: float = 2.1      # glow-halo radius relative to the orb
const TRAIL_COUNT:   int   = 4        # ghost orbs trailing behind each orb
const TRAIL_STEP_MS: float = 45.0     # time gap between trail ghosts
const FADE_OUT_MS:   float = 200.0    # orb fade time after it passes the hit-line
const PULSE_DECAY:   float = 3.0      # hit-line flash decay (units/sec)
const SCRIM_ALPHA:   float = 0.55     # peak darkness of the backing scrim

# Beats supplied by FunscriptPlayer: Vector2(time_ms, depth 0-100).
var _beats: Array = []
var _time_ms:      float = 0.0
var _prev_time_ms: float = 0.0
var _pulse:        float = 0.0   # hit-line flash, 1 → 0

# Built in _ready(): orb colour ramp + the soft backing scrim texture.
var _intensity_grad: Gradient        = null
var _scrim_tex:      GradientTexture2D = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Orb colour runs green → yellow → orange → red → purple from the shallowest
	# V motion to the deepest.
	_intensity_grad = Gradient.new()
	_intensity_grad.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
	_intensity_grad.colors = PackedColorArray([
		Color(0.30, 0.85, 0.35),  # green  — least intense
		Color(0.95, 0.90, 0.20),  # yellow
		Color(1.00, 0.55, 0.10),  # orange
		Color(1.00, 0.22, 0.15),  # red
		Color(0.70, 0.12, 1.00),  # purple — most intense
	])

	# Soft scrim — a dark vertical fade behind the bar so orbs stay legible on
	# any footage, with no hard top/bottom edge.
	var scrim_grad: Gradient = Gradient.new()
	scrim_grad.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	scrim_grad.colors = PackedColorArray([
		Color(0.0, 0.0, 0.0, 0.0),
		Color(0.0, 0.0, 0.0, SCRIM_ALPHA),
		Color(0.0, 0.0, 0.0, 0.0),
	])
	_scrim_tex = GradientTexture2D.new()
	_scrim_tex.gradient  = scrim_grad
	_scrim_tex.fill_from = Vector2(0.0, 0.0)
	_scrim_tex.fill_to   = Vector2(0.0, 1.0)
	_scrim_tex.width  = 8
	_scrim_tex.height = 64


# Loads a new round's beats and resets the playback clock.
func set_beats(beats: Array) -> void:
	_beats        = beats
	_time_ms      = 0.0
	_prev_time_ms = 0.0
	_pulse        = 0.0
	queue_redraw()


# Advances the visualiser to the given playback time (ms).
func set_time(ms: float) -> void:
	_prev_time_ms = _time_ms
	_time_ms = ms
	# Flash the hit-line for any beat that crossed it this frame.
	for b: Vector2 in _beats:
		if b.x > _prev_time_ms and b.x <= _time_ms:
			_pulse = 1.0
			break
	queue_redraw()


func _process(delta: float) -> void:
	if _pulse > 0.0:
		_pulse = maxf(0.0, _pulse - delta * PULSE_DECAY)
		queue_redraw()


# Maps an orb's lead time (ms until it lands) to its x position on the bar.
func _orb_x(lead: float, hit_x: float, w: float) -> float:
	var frac: float = clampf(lead / LOOKAHEAD_MS, 0.0, 1.0)  # 1 at spawn, 0 at line
	return hit_x + (w - hit_x) * frac


func _draw() -> void:
	var w: float = size.x
	var mid_y: float = size.y * 0.5
	var hit_x: float = w * HIT_X_FRAC

	# Soft backing scrim — fades to transparent at the top and bottom edges.
	draw_texture_rect(_scrim_tex, Rect2(0.0, 0.0, w, size.y), false)

	# Track baseline.
	var track_col: Color = Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.40)
	draw_line(Vector2(0.0, mid_y), Vector2(w, mid_y), track_col, 2.0, true)

	# Orbs — trail, then glow, then the solid orb on top.
	for b: Vector2 in _beats:
		var lead: float = b.x - _time_ms          # ms until this beat lands
		if lead > LOOKAHEAD_MS or lead < -FADE_OUT_MS:
			continue
		var depth: float = clampf(b.y, 0.0, 100.0) / 100.0
		var col: Color = _intensity_grad.sample(depth)

		# Spawn fade-in / post-line fade-out.
		var base_a: float = 1.0
		if lead > LOOKAHEAD_MS * 0.85:
			base_a = clampf((LOOKAHEAD_MS - lead) / (LOOKAHEAD_MS * 0.15), 0.0, 1.0)
		elif lead < 0.0:
			base_a = clampf(1.0 + lead / FADE_OUT_MS, 0.0, 1.0)

		var ox: float = _orb_x(lead, hit_x, w)

		# Trail — ghost orbs along the path the orb came from (toward the spawn
		# end). Drawn far-to-near so nearer ghosts sit on top.
		for k: int in range(TRAIL_COUNT, 0, -1):
			var g_lead: float = lead + k * TRAIL_STEP_MS
			if g_lead > LOOKAHEAD_MS:
				continue
			var g_t: float = 1.0 - float(k) / float(TRAIL_COUNT + 1)
			var g_col: Color = col
			g_col.a = base_a * g_t * 0.4
			draw_circle(Vector2(_orb_x(g_lead, hit_x, w), mid_y), ORB_RADIUS * (0.4 + 0.5 * g_t), g_col)

		# Glow halo — two soft concentric circles under the orb.
		var glow_col: Color = col
		glow_col.a = base_a * 0.20
		draw_circle(Vector2(ox, mid_y), ORB_RADIUS * ORB_GLOW_MULT, glow_col)
		glow_col.a = base_a * 0.28
		draw_circle(Vector2(ox, mid_y), ORB_RADIUS * 1.45, glow_col)

		# Solid orb.
		var orb_col: Color = col
		orb_col.a = base_a
		draw_circle(Vector2(ox, mid_y), ORB_RADIUS, orb_col)

	# Hit-line marker — a vertical bar that flares, plus an expanding ring pulse.
	var glow: float = 0.55 + 0.45 * _pulse
	var hit_col: Color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, glow)
	draw_line(Vector2(hit_x, mid_y - 20.0), Vector2(hit_x, mid_y + 20.0), hit_col, 3.0, true)
	if _pulse > 0.0:
		var ring_r: float = lerpf(8.0, 32.0, 1.0 - _pulse)
		var ring_col: Color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, _pulse * 0.6)
		draw_arc(Vector2(hit_x, mid_y), ring_r, 0.0, TAU, 32, ring_col, 2.0, true)
