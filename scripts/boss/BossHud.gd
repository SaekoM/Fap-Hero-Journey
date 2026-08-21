class_name BossHud
extends VBoxContainer
## The encounter's own chrome: the boss's name, a health bar that DRAINS as the round runs, division
## marks along it for the authored phases, and the phase banner beneath.
##
## Shared by the round and the encounter editor's preview stage, deliberately. It is the chrome an
## author's cues have to live around — a subtitle placed at the top has to clear this, and the top
## clearance in BossCueLayer is sized against it — so previewing a hand-drawn mock of roughly the right
## shape would defeat the point. One implementation means the thing being cleared in the preview is the
## same thing that will be there in the round.
##
## Presentation only: it is told the round's progress and which phase started, and knows nothing about
## the timeline, the scheduler or the device.

# Sits below the HUD bar rather than replacing the bottom progress bar: the encounter's own name and
# phase line need room to read, and the bottom of the screen is where dialogue lives.
const TOP_MARGIN: int = 20
const HEIGHT: int = 64
const WIDTH_FRACTION: float = 0.44
const BAR_HEIGHT: int = 14

# How long a phase banner stays legible before it fades itself out.
const PHASE_BANNER_HOLD_SECS: float = 1.6

var _bar: ProgressBar = null
var _phase_label: Label = null
var _phase_tween: Tween = null


## Builds the HUD and pins it top-centre in whatever it was added to. `phase_marks` are round-progress
## fractions (0..1); an empty array simply leaves the bar undivided.
func setup(boss_name: String, phase_marks: Array = []) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 2)
	var half: float = WIDTH_FRACTION * 0.5
	anchor_left = 0.5 - half
	anchor_right = 0.5 + half
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_top = TOP_MARGIN
	offset_bottom = TOP_MARGIN + HEIGHT

	var title: Label = Label.new()
	title.text = boss_name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.style_label(title, UITheme.DANGER, 15, true)
	title.add_theme_color_override("font_outline_color", UITheme.BG)
	title.add_theme_constant_override("outline_size", 5)
	add_child(title)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.value = 1.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, BAR_HEIGHT)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg: StyleBoxFlat = StyleBoxFlat.new()
	bg.bg_color = Color(0.10, 0.0, 0.02, 0.88)
	bg.border_color = Color(UITheme.DANGER.r, UITheme.DANGER.g, UITheme.DANGER.b, 0.7)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(3)
	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = UITheme.DANGER
	fill.set_corner_radius_all(3)
	_bar.add_theme_stylebox_override("background", bg)
	_bar.add_theme_stylebox_override("fill", fill)
	add_child(_bar)
	_add_phase_ticks(phase_marks)

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


## How far through the round we are, 0..1. The bar shows it BACKWARDS — the boss's health is what is
## left of the round, which is why the encounter hides the ordinary progress bar rather than showing
## the same number twice.
func set_round_progress(fraction: float) -> void:
	if is_instance_valid(_bar):
		_bar.value = 1.0 - clampf(fraction, 0.0, 1.0)


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


# Division marks on the health bar, one per phase — so a player can SEE there is another stage coming
# without being told. Each is a thin rect anchored by fraction, so it tracks the bar at any width.
#
# The bar DRAINS, so a phase at time T sits at `1 - T/length` along it: the marks arrive already
# resolved and in order, and a phase at 0 is skipped, since the start of the round is not a division.
func _add_phase_ticks(phase_marks: Array) -> void:
	for fraction: float in phase_marks:
		if fraction <= 0.0 or fraction >= 1.0:
			continue
		var tick: ColorRect = ColorRect.new()
		tick.color = Color(UITheme.WHITE_SOFT.r, UITheme.WHITE_SOFT.g, UITheme.WHITE_SOFT.b, 0.8)
		tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var at: float = 1.0 - fraction
		tick.anchor_left = at
		tick.anchor_right = at
		tick.anchor_top = 0.0
		tick.anchor_bottom = 1.0
		tick.offset_left = -1.0
		tick.offset_right = 1.0
		tick.offset_top = 2.0
		tick.offset_bottom = -2.0
		_bar.add_child(tick)
