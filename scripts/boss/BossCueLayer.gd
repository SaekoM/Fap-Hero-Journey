class_name BossCueLayer
extends Control
## Draws a boss timeline's CAST cues — the portraits, one-off art, attack animations and subtitles a
## creator places on the round's clock (BOSS_ROUND_DESIGN §5). Presentation only: it is told what to
## show and when to drop it, and knows nothing about the timeline, the scheduler, or the cast registry.
## Callers hand over an already-resolved image path, so the journey's Characters block stays the
## GameLoop's business.
##
## A plain Control rather than a CanvasLayer, deliberately: parented between the video and the HUD it
## covers the video and leaves the bar readable, whereas any CanvasLayer would draw over the HUD too.
##
## Cues come in two shapes, matching the scheduler's two event kinds:
##   • one-shot  — show(), then fade itself out after its own hold; nothing else has to remember it.
##   • windowed  — show() on the window opening, clear(id) when it closes.
##
## The Tier-1 animation layer lives here (§5.1): an animated source plays through JourneyImage's hidden
## decoder, with a BLEND mode standing in for the alpha the 4:2:0 decoder cannot provide — `add` and
## `screen` drop black out, which is what makes a flash or an energy wash composite instead of sitting
## on screen as a rectangle.

# Ceiling on animated cues alive at once. Each one is a live video decoder on top of the round's own,
# so a dense stretch of timeline could otherwise stack them until playback suffers. Past the cap the
# OLDEST animated cue is retired — a new attack hit matters more than the tail of the last one.
const MAX_ANIMATED_CUES: int = 3

# Fallback hold for a one-shot cue that gives no timings at all, so it cannot linger forever.
const DEFAULT_HOLD_MS: int = 1200

# How far a "slide" transition travels, as a fraction of the viewport width.
const SLIDE_FRACTION: float = 0.08

# Subtitles sit this far above the bottom edge, clear of the HUD bar.
const SUBTITLE_BOTTOM_MARGIN: int = 96
const SUBTITLE_FONT_SIZE: int = 22

# id → {root: Control, animated: bool, tween: Tween}. Insertion order doubles as the age order the
# animated-cue cap retires from.
var _cues: Dictionary = {}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Shows one cast cue. `image_path` is already resolved (a character's portrait or a loose file) and may
## be empty for a subtitle-only line. `one_shot` cues fade themselves out; windowed ones wait for
## clear(). Re-showing an id replaces what was there, so a replayed cue never stacks on itself.
func show_cue(cue: Dictionary, image_path: String, one_shot: bool) -> void:
	var id: String = str(cue.get("id", ""))
	clear(id)

	var root: Control = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.modulate.a = 0.0
	add_child(root)

	var animated: bool = false
	if image_path != "":
		animated = _add_image(root, cue, image_path, one_shot)
	if str(cue.get("text", "")) != "":
		_add_subtitle(root, cue)

	_cues[id] = {"root": root, "animated": animated}
	if animated:
		_enforce_animated_cap(id)
	_play_in(id, cue, one_shot)


## Drops the cue with this id, fading it out first. Safe to call for an id that is not showing.
func clear(id: String) -> void:
	if not _cues.has(id):
		return
	var entry: Dictionary = _cues[id]
	_cues.erase(id)
	var root: Control = entry["root"]
	if not is_instance_valid(root):
		return
	_kill_tween(entry)
	var out_ms: int = int(entry.get("out_ms", 0))
	if out_ms <= 0:
		root.queue_free()
		return
	var tween: Tween = create_tween()
	tween.tween_property(root, "modulate:a", 0.0, out_ms / 1000.0)
	tween.tween_callback(root.queue_free)


## Drops every cue at once — the round ended, or the encounter was cut short.
func clear_all() -> void:
	for id: Variant in _cues.keys():
		var entry: Dictionary = _cues[id]
		_kill_tween(entry)
		var root: Control = entry["root"]
		if is_instance_valid(root):
			root.queue_free()
	_cues.clear()


# ── Building a cue ───────────────────────────────────────────────────────────


# Adds the cue's art. Returns whether it turned out to be an ANIMATION, which is what the decoder cap
# counts. A one-shot animation plays once and takes the whole cue down with it when it ends, so an
# attack hit clears itself even if the author gave no hold time.
func _add_image(root: Control, cue: Dictionary, path: String, one_shot: bool) -> bool:
	var image: JourneyImage = JourneyImage.new()
	image.loop = not one_shot
	image.muted = true  # a cue's sound belongs on the audio track, where it can duck the round
	root.add_child(image)
	_place(image, cue)
	if not image.show_path(
		path, TextureRect.EXPAND_IGNORE_SIZE, TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	):
		image.queue_free()
		return false

	var animated: bool = path.get_extension().to_lower() == JourneyImage.ANIMATED_EXT
	if animated:
		_apply_blend(image, str(cue.get("blend", RoundTimeline.BLEND_NORMAL)))
		if one_shot:
			var id: String = str(cue.get("id", ""))
			image.animation_finished.connect(func() -> void: clear(id))
	return animated


# Positions and scales the art from the cue's anchor + offset + scale. Anchors are expressed as
# fractions of the viewport so a cue lands in the same relative spot at any resolution.
func _place(image: Control, cue: Dictionary) -> void:
	var frac: Vector2 = _anchor_fraction(str(cue.get("anchor_pos", RoundTimeline.ANCHOR_CENTER)))
	var scale_factor: float = maxf(0.01, float(cue.get("scale", 1.0)))
	image.set_anchors_preset(Control.PRESET_FULL_RECT)
	image.anchor_left = frac.x - 0.5 * scale_factor
	image.anchor_right = frac.x + 0.5 * scale_factor
	image.anchor_top = frac.y - 0.5 * scale_factor
	image.anchor_bottom = frac.y + 0.5 * scale_factor
	var offset: Vector2 = RoundTimeline.offset_vector(cue)
	image.offset_left = offset.x
	image.offset_right = offset.x
	image.offset_top = offset.y
	image.offset_bottom = offset.y


static func _anchor_fraction(anchor: String) -> Vector2:
	match anchor:
		"left":
			return Vector2(0.25, 0.5)
		"right":
			return Vector2(0.75, 0.5)
		"top":
			return Vector2(0.5, 0.25)
		"bottom":
			return Vector2(0.5, 0.75)
	return Vector2(0.5, 0.5)  # center, and the fallback for "custom" (the offset does the work)


# The blend mode is what substitutes for alpha (§5.1). The material has to sit on the node that
# actually DRAWS, and JourneyImage draws through a TextureRect it owns, so the children are told to
# inherit rather than the wrapper being styled and nothing changing.
func _apply_blend(image: JourneyImage, blend: String) -> void:
	if blend == RoundTimeline.BLEND_NORMAL:
		return
	var material: CanvasItemMaterial = CanvasItemMaterial.new()
	# CanvasItemMaterial offers MIX / ADD / SUB / MUL — there is no SCREEN. Screen is approximated with
	# ADD, which shares the property that matters here (black drops out, bright pixels carry); a true
	# screen curve would need a custom shader and is not worth one for the Tier-1 layer. The two
	# settings therefore behave identically today — see BOSS_ROUND_DESIGN §5.1.
	material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	image.material = material
	for child: Node in image.get_children():
		if child is CanvasItem:
			(child as CanvasItem).use_parent_material = true


func _add_subtitle(root: Control, cue: Dictionary) -> void:
	var label: Label = Label.new()
	label.text = str(cue["text"])
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchored across the bottom, above the HUD bar — a subtitle, not a speech bubble (§5).
	label.anchor_left = 0.15
	label.anchor_right = 0.85
	label.anchor_top = 1.0
	label.anchor_bottom = 1.0
	label.offset_top = -SUBTITLE_BOTTOM_MARGIN
	label.offset_bottom = -SUBTITLE_BOTTOM_MARGIN * 0.35
	UITheme.style_label(label, UITheme.WHITE_SOFT, SUBTITLE_FONT_SIZE, false)
	# An outline instead of a panel: video is unpredictable behind text, and a box would fight the
	# art the cue is there to show.
	label.add_theme_color_override("font_outline_color", UITheme.BG)
	label.add_theme_constant_override("outline_size", 6)
	root.add_child(label)


# ── Timing ───────────────────────────────────────────────────────────────────


# Fades the cue in, and for a one-shot schedules its own exit. `flash` snaps in with no fade at all;
# `slide` drifts in from the side while fading.
func _play_in(id: String, cue: Dictionary, one_shot: bool) -> void:
	if not _cues.has(id):
		return
	var entry: Dictionary = _cues[id]
	var root: Control = entry["root"]
	var transition: String = str(cue.get("transition", RoundTimeline.TRANSITION_FADE))
	var in_ms: int = 0 if transition == RoundTimeline.TRANSITION_FLASH else int(cue.get("in_ms", 0))
	# Remembered for clear(), which has only the id to go on by then.
	entry["out_ms"] = int(cue.get("out_ms", 0))

	var tween: Tween = create_tween()
	entry["tween"] = tween
	tween.set_parallel(true)
	if in_ms <= 0:
		root.modulate.a = 1.0
	else:
		tween.tween_property(root, "modulate:a", 1.0, in_ms / 1000.0)
	if transition == RoundTimeline.TRANSITION_SLIDE:
		var travel: float = get_viewport_rect().size.x * SLIDE_FRACTION
		root.position.x = -travel
		(
			tween
			. tween_property(root, "position:x", 0.0, maxf(0.12, in_ms / 1000.0))
			. set_ease(Tween.EASE_OUT)
			. set_trans(Tween.TRANS_CUBIC)
		)

	if not one_shot:
		return  # a window owns its lifetime; clear() ends it
	# A one-shot ANIMATION ends itself when the clip finishes (see _add_image), so only give it a
	# timed exit when it cannot: a still, or a subtitle-only line.
	if bool(entry.get("animated", false)):
		return
	var hold_ms: int = _hold_for(cue)
	tween.set_parallel(false)
	tween.tween_interval(maxf(0.0, (in_ms + hold_ms) / 1000.0))
	tween.tween_callback(func() -> void: clear(id))


# How long a one-shot stays up. A subtitle sets the pace when there is one — a line the player cannot
# finish reading is worse than art lingering a beat too long.
static func _hold_for(cue: Dictionary) -> int:
	if str(cue.get("text", "")) != "":
		return int(cue.get("text_hold_ms", DEFAULT_HOLD_MS))
	var duration: int = int(cue.get("duration_ms", 0))
	return duration if duration > 0 else DEFAULT_HOLD_MS


# ── Housekeeping ─────────────────────────────────────────────────────────────


# Retires the oldest animated cue once too many decoders are alive. `keep_id` is the cue just added,
# which must survive even if it is somehow the only one counted.
func _enforce_animated_cap(keep_id: String) -> void:
	var animated_ids: Array = []
	for id: Variant in _cues:
		if bool((_cues[id] as Dictionary).get("animated", false)):
			animated_ids.append(str(id))
	var over: int = animated_ids.size() - MAX_ANIMATED_CUES
	for i: int in over:
		var victim: String = str(animated_ids[i])
		if victim != keep_id:
			clear(victim)


static func _kill_tween(entry: Dictionary) -> void:
	var tween: Variant = entry.get("tween")
	if tween is Tween and (tween as Tween).is_valid():
		(tween as Tween).kill()
