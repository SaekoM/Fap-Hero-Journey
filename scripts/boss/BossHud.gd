class_name BossHud
extends VBoxContainer
## The encounter's own chrome: the boss's name, a health bar that DRAINS as the round runs, split into
## one stage per authored phase, and the phase banner beneath.
##
## Shared by the round and the encounter editor's preview stage, deliberately. It is the chrome an
## author's cues have to live around — a subtitle placed at the top has to clear this, and the top
## clearance in BossCueLayer is sized against it — so previewing a hand-drawn mock of roughly the right
## shape would defeat the point. One implementation means the thing being cleared in the preview is the
## same thing that will be there in the round.
##
## Presentation only: it is told the round's progress and which phase started, and knows nothing about
## the timeline, the scheduler or the device.

# Where the block sits down the screen by default, as a fraction: just clear of the top edge. It does
# not replace the bottom progress bar, because the encounter's own name and phase line need room to read
# and the bottom of the screen is where dialogue lives — but an author whose cast art wants that corner
# can move the whole block, so this is only where it STARTS.
const DEFAULT_Y: float = 0.02
const HEIGHT: int = 80  # name + bar + stance line + phase line
const WIDTH_FRACTION: float = 0.44
const BAR_HEIGHT: int = 14

# Width of the gap cut between two stages of the bar. Wide enough to read as a break rather than a
# scratch on the fill, narrow enough that a boss with several phases does not lose most of its bar to
# the gaps between them.
const DIVISION_W: float = 3.0

# The bar's backing. Named because the stage gaps are punched in this exact colour — two literals that
# have to match, sitting a hundred lines apart, is how a gap quietly stops looking like a gap.
const BAR_BACKING: Color = Color(0.10, 0.0, 0.02, 1.0)

# How long a phase banner stays legible before it fades itself out.
const PHASE_BANNER_HOLD_SECS: float = 1.6

# One colour per stance. They have to be told apart at a glance and at speed, so each sits in a
# different part of the wheel rather than being shades of the same warning red — and the two ZEROS get
# the widest separation of all, because "she cannot be hurt" and "she is hurting you" are the pair a
# player most needs to distinguish.
const STANCE_IMMUNE_TINT: Color = Color(0.62, 0.62, 0.68, 1.0)  # grey — nothing reaches her
const STANCE_GUARD_TINT: Color = Color(0.45, 0.75, 1.0, 1.0)  # light blue — she is covering up
const STANCE_HEAL_TINT: Color = UITheme.SUCCESS  # green — the one state that runs the bar backwards

# How far the stance glow spreads beyond the bar. NORMAL gets none: the glow's PRESENCE is the signal,
# so one that never went out would say nothing.
const GLOW_SIZE: int = 6

# The CHASE bar: a dimmer bar behind the real one, trailing it by a fixed amount of TIME. The gap it
# leaves is therefore "damage taken over the last CHASE_LAG_SECS" — which is the readout that was
# actually wanted, and the only one that works here.
#
# It began as a rate-limited chase and showed nothing at all. Damage does not arrive in chunks: score
# accrues per keyframe pair as the script advances (§13.7), so the bar drains as a smooth trickle and a
# follower moving at any sensible rate stays within a frame of it. Lagging by time instead opens a gap
# proportional to the CURRENT drain rate — thin while she is guarding, twice as wide through an opening
# — so the bar shows how hard she is being hit, not merely that she is.
#
# Exponential, so it is frame-rate independent and a sudden jump closes smoothly rather than cutting.
const CHASE_LAG_SECS: float = 1.5
const GHOST_DIM: float = 0.35

# Corner brackets, drawn instead of a rounded rectangle: the bar should read as something aimed at her
# rather than as a widget. LEN is how far each arm runs along its edge.
const BRACKET_LEN: float = 9.0
const BRACKET_W: float = 2.0
const BRACKET_PAD: float = 3.0  # how far the brackets sit outside the bar

# Attempt pips. The banner that announces an attempt fades, so mid-fight there is nothing saying how
# many tries are left — which is precisely when a player wants to know.
const PIP_SIZE: float = 5.0
const PIP_GAP: float = 4.0

var _bar: ProgressBar = null
var _ghost: ProgressBar = null
var _ghost_style: StyleBoxFlat = null
var _overlay: Control = null
var _attempt: int = 1
var _max_attempts: int = 1
var _phase_marks: Array = []
var _phase_label: Label = null
var _phase_tween: Tween = null
var _fill_style: StyleBoxFlat = null

# The bar's colour has TWO authors: the phase says what the fight currently feels like, and the stance
# says how she is taking damage right now. They are kept apart and combined in _refresh_fill,
# because either one writing bg_color directly would silently erase the other — a guard opening during a
# tinted phase would drop the tint, and the next phase would drop the guard.
var _fill_base: Color = UITheme.DANGER
var _bg_style: StyleBoxFlat = null
var _stance: String = RoundTimeline.STANCE_NORMAL
var _stance_label: Label = null


## Builds the HUD and pins it centred at `y` down whatever it was added to. `phase_marks` are
## round-progress fractions (0..1); an empty array simply leaves the bar undivided.
func setup(boss_name: String, phase_marks: Array = [], y: float = DEFAULT_Y) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 2)
	var half: float = WIDTH_FRACTION * 0.5
	anchor_left = 0.5 - half
	anchor_right = 0.5 + half
	place_at(y)

	var title: Label = Label.new()
	title.text = boss_name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.style_label(title, UITheme.DANGER, 15, true)
	title.add_theme_color_override("font_outline_color", UITheme.BG)
	title.add_theme_constant_override("outline_size", 5)
	add_child(title)

	# The bar is THREE layers sharing one rect: the chase bar underneath carrying the trough and the
	# glow, the real bar over it drawn on nothing so the ghost shows through where it lags, and an
	# overlay on top for the brackets and pips. A VBox stacks its children, so they need their own
	# container to sit inside one another.
	var bar_area: Control = Control.new()
	bar_area.custom_minimum_size = Vector2(0, BAR_HEIGHT)
	bar_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar_area)

	_ghost = _make_bar()
	var bg: StyleBoxFlat = StyleBoxFlat.new()
	bg.bg_color = Color(BAR_BACKING.r, BAR_BACKING.g, BAR_BACKING.b, 0.88)
	bg.set_corner_radius_all(2)
	_bg_style = bg
	_ghost_style = StyleBoxFlat.new()
	_ghost_style.set_corner_radius_all(2)
	_ghost.add_theme_stylebox_override("background", bg)
	_ghost.add_theme_stylebox_override("fill", _ghost_style)
	bar_area.add_child(_ghost)

	_bar = _make_bar()
	var blank: StyleBoxEmpty = StyleBoxEmpty.new()  # the trough belongs to the ghost, not to both
	_bar.add_theme_stylebox_override("background", blank)
	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = UITheme.DANGER
	fill.set_corner_radius_all(2)
	_fill_style = fill
	_bar.add_theme_stylebox_override("fill", fill)
	bar_area.add_child(_bar)
	_phase_marks = phase_marks.duplicate()

	# Drawn last so the brackets frame everything, and given the whole rect so it can reach outside it —
	# the brackets sit just beyond the bar's edges and nothing clips them.
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.draw.connect(_draw_overlay)
	bar_area.add_child(_overlay)

	# Between the bar and the phase line: the stance is persistent and the phase banner is transient, so
	# the one that is always there sits closer to the thing it describes.
	_stance_label = Label.new()
	_stance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stance_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.style_label(_stance_label, UITheme.DARK_TEXT, 10, true)
	_stance_label.add_theme_color_override("font_outline_color", UITheme.BG)
	_stance_label.add_theme_constant_override("outline_size", 4)
	add_child(_stance_label)
	_refresh_stance_label()

	# The phase line lives HERE, under the bar — as a bottom-anchored cue it landed on top of the
	# encounter's dialogue, which is the one place it must not be.
	_phase_label = Label.new()
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_phase_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_phase_label.modulate.a = 0.0
	UITheme.style_label(_phase_label, UITheme.WHITE_SOFT, 12, true)
	_phase_label.add_theme_color_override("font_outline_color", UITheme.BG)
	_phase_label.add_theme_constant_override("outline_size", 5)
	add_child(_phase_label)


# One configured ProgressBar, since the real bar and its chase bar differ only in their styleboxes.
func _make_bar() -> ProgressBar:
	var bar: ProgressBar = ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = 1.0
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return bar


## Which pass this is, and out of how many. Drawn as pips beside the bar; a single-attempt fight shows
## none, because "1 of 1" is not information.
func set_attempts(attempt: int, max_attempts: int) -> void:
	_attempt = maxi(1, attempt)
	_max_attempts = maxi(1, max_attempts)
	if is_instance_valid(_overlay):
		_overlay.queue_redraw()


## Moves the whole block — name, bar and phase line together — to `y` down the screen, 0 the top edge
## and 1 the bottom.
##
## The block SLIDES against its own height rather than hanging off the anchor: at 0 it sits fully below
## the line, at 1 fully above it, and in between it straddles it. That is what stops either extreme from
## running off the screen, which a fixed offset would have done at one end or the other.
func place_at(y: float) -> void:
	var at: float = clampf(y, 0.0, 1.0)
	anchor_top = at
	anchor_bottom = at
	offset_top = -HEIGHT * at
	offset_bottom = HEIGHT * (1.0 - at)


# The chase bar closes on the real one. Done here rather than with a tween because set_round_progress
# runs every frame: a tween restarted that often never gets anywhere, and the gap has to survive being
# rewritten continuously while the fight drains it.
# Corner brackets and attempt pips. One overlay draws both because they share the bar's rect and the
# stance's colour, and splitting them would mean two Controls redrawn on the same events.
func _draw_overlay() -> void:
	if not is_instance_valid(_overlay):
		return
	var rect: Rect2 = Rect2(Vector2.ZERO, _overlay.size).grow(BRACKET_PAD)
	var tint: Color = _fill_base if _stance == RoundTimeline.STANCE_NORMAL else _stance_color()
	# Under the brackets but over both bars, so a stage gap cuts the chase bar too.
	_draw_phase_divisions(Rect2(Vector2.ZERO, _overlay.size))
	# Each corner is two arms meeting at it. Drawn as lines rather than as a rectangle with gaps so the
	# arms keep their length whatever the bar's width turns out to be.
	for corner: Vector2 in [
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		Vector2(rect.position.x, rect.end.y),
		rect.end
	]:
		var to_x: float = 1.0 if is_equal_approx(corner.x, rect.position.x) else -1.0
		var to_y: float = 1.0 if is_equal_approx(corner.y, rect.position.y) else -1.0
		_draw_bracket_arm(corner, Vector2(corner.x + BRACKET_LEN * to_x, corner.y), tint)
		_draw_bracket_arm(corner, Vector2(corner.x, corner.y + BRACKET_LEN * to_y), tint)
	_draw_attempt_pips(rect, tint)


# One pip per attempt, below the bar's left corner — the stance line beneath is centred, so this edge is
# free. Spent attempts are hollow, the current one is filled, and the ones still to come sit between.
func _draw_attempt_pips(rect: Rect2, tint: Color) -> void:
	if _max_attempts <= 1:
		return  # "1 of 1" is not information
	var y: float = rect.end.y + PIP_GAP
	for i: int in _max_attempts:
		var at: Vector2 = Vector2(rect.position.x + float(i) * (PIP_SIZE + PIP_GAP), y)
		var box: Rect2 = Rect2(at, Vector2(PIP_SIZE, PIP_SIZE))
		if i + 1 < _attempt:
			_overlay.draw_rect(box, Color(tint, 0.25), false, 1.0)  # spent
		elif i + 1 == _attempt:
			_overlay.draw_rect(box, tint)  # the one being played
		else:
			_overlay.draw_rect(box, Color(tint, 0.55), false, 1.0)  # still to come


# One arm of a corner bracket, so the corner loop above reads as geometry rather than node plumbing.
func _draw_bracket_arm(from: Vector2, to: Vector2, tint: Color) -> void:
	_overlay.draw_line(from, to, tint, BRACKET_W)


## How far through the round we are, 0..1. The bar shows it BACKWARDS — the boss's health is what is
## left of the round, which is why the encounter hides the ordinary progress bar rather than showing
## the same number twice.
func set_round_progress(fraction: float) -> void:
	if not is_instance_valid(_bar):
		return
	_bar.value = 1.0 - clampf(fraction, 0.0, 1.0)
	_step_chase()


# Moves the chase bar one frame closer to the real one. Driven from set_round_progress rather than from
# _process deliberately: the two must advance together, and this is the call both the round and the
# preview already make every frame. As _process it did not run at all — the ghost sat where it started
# and the gap grew without bound, which is what the bar visibly did.
func _step_chase() -> void:
	if not is_instance_valid(_ghost):
		return
	if is_zero_approx(_ghost.value - _bar.value):
		return
	# EVERY change eases, including the big ones. There was a size threshold above which the ghost
	# snapped instead, on the grounds that a jump is not damage — but a discontinuity is more jarring
	# than the wipe it avoided, and on a replay the long ease reads as the damage already done settling
	# into place rather than as a mistake.
	var delta: float = get_process_delta_time()
	_ghost.value = lerpf(_ghost.value, _bar.value, 1.0 - exp(-delta / CHASE_LAG_SECS))


## How the boss is currently taking damage. A stance the player cannot perceive is a mechanic they
## cannot learn to play around — and the bar is where they are already looking, so it is the one place
## the signal costs no attention.
##
## Says it TWICE, deliberately: the fill dulls or brightens for the glance, and the line beneath names
## it for the player who wants to know which of two zeros they are looking at.
func set_stance(stance: String) -> void:
	_stance = stance
	_refresh_fill()
	_refresh_stance_label()


## The colour the bar sits at between stances — the current phase's tint, or the default when the
## phase carries none. Lets a fight visibly change character as it moves through its stages.
func set_base_tint(tint: Color) -> void:
	_fill_base = tint
	_refresh_fill()


# The phase's colour, overridden by the stance while one is in force. Combined in one place so neither
# input can erase the other.
#
# NORMAL keeps the phase's own tint, which is what lets a fight change character as it moves through its
# stages. Anything else takes the stance's colour outright: with five named states a lighter or darker
# shade of the phase tint could no longer tell them apart, and the word the player reads under the bar
# has to match what they see in it.
func _refresh_fill() -> void:
	var quiet: bool = _stance == RoundTimeline.STANCE_NORMAL
	var edge: Color = _fill_base if quiet else _stance_color()
	if _fill_style != null:
		_fill_style.bg_color = edge
	if _bg_style == null:
		return
	# The frame and its glow carry the same colour as the fill, so the state still reads off the bar's
	# EDGE once the fill has drained away to almost nothing — which is exactly when it matters most.
	_bg_style.shadow_color = Color(edge, 0.0 if quiet else 0.55)
	_bg_style.shadow_size = 0 if quiet else GLOW_SIZE
	# The chunk the chase bar exposes is the same colour, dimmed — it is the health she JUST lost, not a
	# different quantity, and giving it its own hue would read as a third bar.
	if _ghost_style != null:
		_ghost_style.bg_color = Color(edge, GHOST_DIM)
	if is_instance_valid(_overlay):
		_overlay.queue_redraw()


# The stance in words, under the bar. NORMAL is drawn dim and quiet: a permanent label shouting NORMAL
# is noise, and the eye should only be caught when the state CHANGES.
func _refresh_stance_label() -> void:
	if not is_instance_valid(_stance_label):
		return
	# NORMAL shows NOTHING. It was drawn dim on the theory that a permanent label should not shout, but a
	# dim word under a bar is not read as "normal" — at that size it reads as a smudge on the video. The
	# absence IS the signal, which is already how the glow works: nothing to see means nothing is on.
	if _stance == RoundTimeline.STANCE_NORMAL:
		_stance_label.text = ""
		return
	_stance_label.text = RoundTimeline.stance_label(_stance)
	_stance_label.add_theme_color_override("font_color", _stance_color())
	_stance_label.modulate.a = 1.0


# One colour per stance, chosen so the two ZEROS never read as the same thing: she cannot be hurt either
# way, but one of them is her hurting the player back.
func _stance_color() -> Color:
	match _stance:
		RoundTimeline.STANCE_ATTACKING:
			return UITheme.DANGER
		RoundTimeline.STANCE_IMMUNE:
			return STANCE_IMMUNE_TINT
		RoundTimeline.STANCE_GUARDED:
			return STANCE_GUARD_TINT
		RoundTimeline.STANCE_VULNERABLE:
			return UITheme.PURPLE_BRIGHT
		RoundTimeline.STANCE_RECOVERING:
			return STANCE_HEAL_TINT
	return UITheme.DARK_TEXT


## Announces a phase, holding it long enough to read. Calling again replaces whatever was showing.
func show_phase(label: String) -> void:
	if label == "" or not is_instance_valid(_phase_label):
		return
	_phase_label.text = label
	kill_phase_tween()
	_phase_tween = create_tween()
	_phase_tween.tween_property(_phase_label, "modulate:a", 1.0, 0.2)
	_phase_tween.tween_interval(PHASE_BANNER_HOLD_SECS)
	_phase_tween.tween_property(_phase_label, "modulate:a", 0.0, 0.4)


## Drops a banner mid-flight. The preview calls this when it seeks, where a banner left running would
## announce a phase the playhead has already left.
func kill_phase_tween() -> void:
	if _phase_tween != null and _phase_tween.is_valid():
		_phase_tween.kill()
	_phase_tween = null


# Cuts the health bar into one STAGE per phase, so a boss with three phases reads as three chunks to
# get through rather than one long drain. A player can see there is more of this fight coming without
# being told.
#
# Drawn as GAPS punched through the bar — a rect in the bar's own backing colour, full height — not as
# marks laid over the fill. A line on top still reads as one continuous bar with decoration on it; a gap
# reads as separate stages, which is the whole point of showing them.
#
# Drawn on the OVERLAY rather than parented to the bar, because there are two bars now: a gap cut into
# only the front one would show the chase bar through it and stop reading as a gap at all.
#
# The divisions come from the PHASES, so they are wherever the author actually put them and can never
# disagree with the banners the player sees. A phase at 0 or 1 is skipped: neither end of the bar is a
# division. The bar DRAINS, so a phase at damage fraction F sits at `1 - F` along it.
func _draw_phase_divisions(rect: Rect2) -> void:
	for fraction: float in _phase_marks:
		if fraction <= 0.0 or fraction >= 1.0:
			continue
		var x: float = rect.position.x + (1.0 - fraction) * rect.size.x
		_overlay.draw_rect(
			Rect2(x - DIVISION_W * 0.5, rect.position.y, DIVISION_W, rect.size.y), BAR_BACKING
		)
