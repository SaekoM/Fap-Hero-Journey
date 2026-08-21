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

# How much bigger a POP cue starts before settling. Overshoot is on the way IN only — it lands on 1.0
# and stays, so nothing wobbles under the round.
const POP_OVERSHOOT: float = 1.15

# How far a "rise" drifts upward, as a fraction of the canvas height. Deliberately much shorter than a
# slide: rise is the gentle option for dialogue, where a slide's travel reads as too much movement.
const RISE_FRACTION: float = 0.035

# How far a "slide" transition travels, as a fraction of the CANVAS width — cues are positioned in
# canvas space, so measuring this against the window instead would make the same slide cover a
# different share of the picture at every resolution.
const SLIDE_FRACTION: float = 0.08

# Cast art is placed against a fixed 1920x1080 REFERENCE CANVAS, letterboxed into whatever rect this
# layer happens to occupy. This is what makes the encounter editor's preview trustworthy: the layer
# fills the whole screen in a round but only a panel in the editor's stage, and a placement expressed
# in the parent's own pixels therefore meant two different things in the two places — an author who
# nudged a cue to the right edge of the preview found it somewhere else, and differently sized, in the
# real round. Mapping both through one canvas makes the preview exact. The round's own parent is
# already this size, so existing authored cues keep the position they were tuned to.
const REFERENCE_CANVAS: Vector2 = Vector2(1920.0, 1080.0)

# Height of the box a line is laid out in, in canvas pixels — it scales with the canvas because the type
# inside it does. Only the box: a longer line simply overflows it rather than being clipped.
const SUBTITLE_BAND_HEIGHT: int = 72

# id → {root, image, subtitle: Control, animated: bool, tween: Tween}. Insertion order doubles as the
# animated-cue cap retires from.
var _cues: Dictionary = {}

# The reference canvas as an actual node: letterboxed inside this layer, clipping whatever overhangs it.
# Cues are parented here rather than to the layer so that art an author deliberately ran off the edge is
# cut at the SCREEN edge in the preview too, instead of spilling into the editor's letterbox margin and
# showing them a portrait the player will never see.
var _canvas: Control = null


func _ready() -> void:
	# ...AND offsets: set_anchors_preset alone only moves the anchors, re-deriving the offsets so the
	# control KEEPS its current rect — which for a freshly created node is 0x0, so it would never draw.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.clip_contents = true
	add_child(_canvas)
	_fit_canvas()
	# The editor's stage changes size as the modal lays out and as the inspector opens, so placements
	# resolved against a stale rect have to be recomputed rather than baked in once.
	resized.connect(_fit_canvas)


## Shows one cast cue. `image_path` is already resolved (a character's portrait or a loose file) and may
## be empty for a subtitle-only line. `one_shot` cues fade themselves out; windowed ones wait for
## clear(). Re-showing an id replaces what was there, so a replayed cue never stacks on itself.
func show_cue(cue: Dictionary, image_path: String, one_shot: bool) -> void:
	var id: String = str(cue.get("id", ""))
	clear(id)

	var root: Control = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.modulate.a = 0.0
	_canvas.add_child(root)

	# Only a real animation counts toward the decoder cap, so a static portrait must not trip it just by
	# having loaded.
	var image: Control = null
	var animated: bool = false
	if image_path != "":
		image = _add_image(root, cue, image_path, one_shot)
		animated = (
			image != null and image_path.get_extension().to_lower() == JourneyImage.ANIMATED_EXT
		)
	var subtitle: Control = null
	if str(cue.get("text", "")) != "":
		subtitle = _add_subtitle(root, cue)

	_cues[id] = {"root": root, "animated": animated, "subtitle": subtitle, "image": image}
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


# Adds the cue's art, returning the node so a later resize can re-place it — or null if the art would
# not load. A one-shot animation plays once and takes the whole cue down with it when it ends, so an
# attack hit clears itself even if the author gave no hold time.
func _add_image(root: Control, cue: Dictionary, path: String, one_shot: bool) -> Control:
	var image: JourneyImage = JourneyImage.new()
	image.loop = not one_shot
	image.muted = true  # a cue's sound belongs on the audio track, where it can duck the round
	root.add_child(image)
	_place(image, cue)
	if not image.show_path(
		path, TextureRect.EXPAND_IGNORE_SIZE, TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	):
		image.queue_free()
		return null

	if path.get_extension().to_lower() == JourneyImage.ANIMATED_EXT:
		_apply_blend(image, str(cue.get("blend", RoundTimeline.BLEND_NORMAL)))
		if one_shot:
			var id: String = str(cue.get("id", ""))
			image.animation_finished.connect(func() -> void: clear(id))
	return image


# Positions and scales the art from the cue's anchor + offset + scale, all resolved on the reference
# canvas and then mapped into this layer's actual rect. Anchors and offsets are therefore worth the
# same thing at any size, which is the whole point — see REFERENCE_CANVAS.
func _place(image: Control, cue: Dictionary) -> void:
	# Fixed anchors: the rect is computed here, so letting the anchor system stretch it as well would
	# apply the parent's proportions a second time and undo the mapping.
	image.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_apply_placement(image, cue)


# Places one cue on the canvas. Pure canvas pixels — the canvas node carries the scale.
func _apply_placement(image: Control, cue: Dictionary) -> void:
	var frac: Vector2 = _anchor_fraction(str(cue.get("anchor_pos", RoundTimeline.ANCHOR_CENTER)))
	var scale_factor: float = maxf(0.01, float(cue.get("scale", 1.0)))
	var box: Vector2 = REFERENCE_CANVAS * scale_factor

	# Deliberately NOT clamped to the canvas. Running a cue off the edge is a composition tool, not a
	# mistake — pushing a full-body portrait down past the bottom to crop the legs, or off to one side so
	# only a shoulder shows, is exactly how an author frames one. The preview resolves through this same
	# canvas, so whatever they see hanging off the edge is what the round will show.
	var centre: Vector2 = frac * REFERENCE_CANVAS + RoundTimeline.offset_vector(cue)

	image.size = box
	image.position = centre - box * 0.5


# Letterboxes the canvas inside the layer, preserving its aspect, and re-places what is showing. A layer
# that has not been laid out yet reports zero, so the canvas sits at 1:1 until a real `resized` arrives.
func _fit_canvas() -> void:
	_canvas.size = REFERENCE_CANVAS
	var fit: float = 1.0
	if size.x > 0.0 and size.y > 0.0:
		fit = minf(size.x / REFERENCE_CANVAS.x, size.y / REFERENCE_CANVAS.y)
	# Scaling the CANVAS rather than each cue is what makes the preview honest about type as well as
	# art: a 22 px subtitle shrinks with everything else instead of rendering at full size on a
	# quarter-size stage, which would have made the editor's text look far larger than the round's.
	_canvas.scale = Vector2(fit, fit)
	_canvas.position = (size - REFERENCE_CANVAS * fit) * 0.5


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


func _add_subtitle(root: Control, cue: Dictionary) -> Control:
	var label: Label = Label.new()
	label.text = str(cue["text"])
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchored across the bottom, above the HUD bar — a subtitle, not a speech bubble (§5).
	label.anchor_left = 0.15
	label.anchor_right = 0.85
	_place_subtitle(label, float(cue.get("text_y", RoundTimeline.DEFAULT_TEXT_Y)))
	UITheme.style_label(
		label,
		RoundTimeline.cue_text_color(cue, UITheme.WHITE_SOFT),
		int(cue.get("text_size", RoundTimeline.DEFAULT_TEXT_SIZE)),
		false
	)
	# An outline instead of a panel: video is unpredictable behind text, and a box would fight the
	# art the cue is there to show.
	label.add_theme_color_override("font_outline_color", UITheme.BG)
	label.add_theme_constant_override("outline_size", 6)
	root.add_child(label)
	return label


# Pins the line's vertical middle at `y`, a 0..1 fraction of the canvas — 0 the top edge, 1 the bottom.
# Fractional anchors resolve against whatever the canvas is sized to, so this needs no scale
# compensation and no re-placing when the layer resizes. The screen-space clearances this replaces
# existed only to hold a line a fixed distance off the bottom edge, clear of the HUD bar; with a free
# position that is the author's call, and the editor previews the bar so the call can be made on sight.
func _place_subtitle(label: Control, y: float) -> void:
	var band: float = float(SUBTITLE_BAND_HEIGHT)
	label.anchor_top = clampf(y, 0.0, 1.0)
	label.anchor_bottom = label.anchor_top
	label.offset_top = -band * 0.5
	label.offset_bottom = band * 0.5


# ── Timing ───────────────────────────────────────────────────────────────────


# Fades the cue in, and for a one-shot schedules its own exit. `flash` snaps in with no fade at all;
# `slide` drifts in from the side while fading.
func _play_in(id: String, cue: Dictionary, one_shot: bool) -> void:
	if not _cues.has(id):
		return
	var entry: Dictionary = _cues[id]
	var root: Control = entry["root"]
	var image: Control = _live(entry, "image")
	var subtitle: Control = _live(entry, "subtitle")
	var transition: String = str(cue.get("transition", RoundTimeline.TRANSITION_FADE))
	var flash: bool = transition == RoundTimeline.TRANSITION_FLASH
	var in_ms: int = 0 if flash else int(cue.get("in_ms", 0))
	# Remembered for clear(), which has only the id to go on by then.
	entry["out_ms"] = int(cue.get("out_ms", 0))

	# The cue fades as ONE — art and line together. A line that wants its own schedule is simply its own
	# text-only cue, which already carries a full set of fades; giving every cue a second parallel set of
	# subtitle timings bought that same result for a good deal more UI.
	if in_ms <= 0:
		root.modulate.a = 1.0

	# Motion belongs to the art; a subtitle sliding across the screen with its portrait reads as the
	# caption coming loose. Only a cue with no art at all moves its line instead — and then it is the
	var mover: Control = image if image != null else subtitle
	var travel: Vector2 = _entry_travel(transition)
	var popping: bool = transition == RoundTimeline.TRANSITION_POP and mover != null
	var sliding: bool = travel != Vector2.ZERO and mover != null
	# A one-shot ANIMATION ends itself when its clip finishes (see _add_image), so only a still or a
	# subtitle-only line needs a timed exit.
	var timed_exit: bool = one_shot and not bool(entry.get("animated", false))
	# A flash with no movement and no timed exit has nothing to animate, and a Tween created with no
	# Tweeners errors on its first step — so the tween is built lazily, only once something needs it.
	if in_ms <= 0 and not sliding and not popping and not timed_exit:
		return

	var tween: Tween = create_tween()
	entry["tween"] = tween
	tween.set_parallel(true)
	if in_ms > 0:
		tween.tween_property(root, "modulate:a", 1.0, in_ms / 1000.0)
	if sliding:
		var placed: Vector2 = mover.position
		mover.position = placed + travel
		(
			tween
			. tween_property(mover, "position", placed, maxf(0.12, in_ms / 1000.0))
			. set_ease(Tween.EASE_OUT)
			. set_trans(Tween.TRANS_CUBIC)
		)
	if popping:
		# Scaled about the art's OWN centre, not the cue root's: the root spans the whole canvas, so
		# scaling that would swing an edge-anchored portrait in from the middle of the screen instead of
		# letting it punch up where it was placed.
		_centre_pivot(mover)
		mover.scale = Vector2(POP_OVERSHOOT, POP_OVERSHOOT)
		(
			tween
			. tween_property(mover, "scale", Vector2.ONE, maxf(0.14, in_ms / 1000.0))
			. set_ease(Tween.EASE_OUT)
			. set_trans(Tween.TRANS_BACK)
		)
	if not timed_exit:
		return  # a window owns its lifetime; clear() ends it
	var hold_ms: int = _hold_for(cue)
	tween.set_parallel(false)
	tween.tween_interval(maxf(0.0, (in_ms + hold_ms) / 1000.0))
	tween.tween_callback(func() -> void: clear(id))


# Where a cue starts, relative to where it belongs, for the entrances that travel. Zero for the ones
# that do not, which is also how _play_in decides whether there is any movement to tween.
static func _entry_travel(transition: String) -> Vector2:
	var slide_x: float = REFERENCE_CANVAS.x * SLIDE_FRACTION
	var slide_y: float = REFERENCE_CANVAS.y * SLIDE_FRACTION
	match transition:
		RoundTimeline.TRANSITION_SLIDE_LEFT:
			return Vector2(-slide_x, 0.0)
		RoundTimeline.TRANSITION_SLIDE_RIGHT:
			return Vector2(slide_x, 0.0)
		RoundTimeline.TRANSITION_SLIDE_TOP:
			return Vector2(0.0, -slide_y)
		RoundTimeline.TRANSITION_SLIDE_BOTTOM:
			return Vector2(0.0, slide_y)
		RoundTimeline.TRANSITION_RISE:
			return Vector2(0.0, REFERENCE_CANVAS.y * RISE_FRACTION)
	return Vector2.ZERO


# One of a cue's parts, or null if it has none of that kind (or it has already been freed).
static func _live(entry: Dictionary, key: String) -> Control:
	var node: Variant = entry.get(key)
	return node if node is Control and is_instance_valid(node) else null


# Puts a node's scaling origin at its own middle. A subtitle is sized by anchors, so on the frame it is
# created its size is still zero and the pivot would land in the corner — it is corrected once the
# layout has actually run, which is well inside a pop's duration.
static func _centre_pivot(node: Control) -> void:
	node.pivot_offset = node.size * 0.5
	if node.size == Vector2.ZERO:
		node.resized.connect(func() -> void: node.pivot_offset = node.size * 0.5, CONNECT_ONE_SHOT)


# How long a one-shot stays up. A subtitle sets the pace when there is one — a line the player cannot
# finish reading is worse than art lingering a moment too long.
static func _hold_for(cue: Dictionary) -> int:
	if str(cue.get("text", "")) != "":
		return RoundTimeline.DEFAULT_TEXT_HOLD_MS
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
