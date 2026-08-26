class_name JourneyImage
extends Control
## One journey image — a still (PNG / JPG / WebP) or an animation the builder baked to looping
## H.264 (see MediaPoolService.bake_animation). Callers hand it a path and the TextureRect
## expand/stretch they'd have used anyway; it picks how to display it.
##
## Why an animation is drawn through a TextureRect rather than by the VideoStreamPlayer itself:
## VideoStreamPlayer exposes only `expand` — it has NO aspect-preserving stretch mode — so drawing
## with it directly would letterbox-or-distort differently from the still it replaces. Two of the
## three surfaces (boss intro, storyboard background) use STRETCH_KEEP_ASPECT_CENTERED. So the
## player runs hidden purely as a decoder (decoding is driven by its internal process, not by
## drawing) and its frame texture is drawn by a TextureRect, which keeps every existing
## expand/stretch behaviour byte-for-byte.
##
## Looping is engine-side: `loop` lives on VideoStreamPlayer, not VideoStreamPlayback, so it works
## regardless of the FFmpeg GDExtension. It's implemented as a RESTART, which is why the builder
## pre-repeats short loops — see MediaPoolService.ANIM_TARGET_SECS.

# Extension the builder bakes animations to. The path itself is the signal — no schema flag.
const ANIMATED_EXT: String = "mp4"

## Emitted when a NON-looping animation reaches its end. Nothing to listen for on the looping default.
signal animation_finished

## Set BEFORE show_path(). Both default to the historical behaviour, so existing callers (boss intro,
## storyboard background, fork art) are unaffected:
##   loop  — off for a one-shot, e.g. a boss attack animation that plays once and clears.
##   muted — on for anything whose sound belongs elsewhere; a boss cue's audio lives on the timeline's
##           audio track, where it can duck the round, so the cue itself must stay silent.
var loop: bool = true
var muted: bool = false

## How a CROP-fitted image is framed. Set BEFORE show_path(); ignored by every other fit, which either
## shows the whole image or distorts it and so has nothing to frame.
##
##   focus — the point of the IMAGE, in 0-1 on each axis, kept as near the centre of the frame as the
##           overflow allows. (0.5, 0.5) is the engine's own centred crop; (0.5, 0.0) keeps the top.
##   zoom  — multiplier over the scale that exactly covers the frame. 1.0 is cover; larger pushes in.
##
## Normalized rather than pixel offsets on purpose: the frame's aspect differs between the 16:9 editor
## preview and whatever window the player has, so an offset tuned in one is wrong in the other. A focal
## point means the same thing in both.
##
## Not a TextureRect feature — STRETCH_KEEP_ASPECT_COVERED always crops dead centre at exactly cover
## scale — so anything other than the default is sized and placed by hand (see _apply_crop_align).
var focus: Vector2 = Vector2(0.5, 0.5)
var zoom: float = 1.0

var _rect: TextureRect = null
# True only while an edge-aligned crop is in force. Every other fit is drawn by the TextureRect's own
# stretch mode, and _apply_crop_align must keep its hands off those — sizing the rect by hand turns a
# letterboxed "fit" into a crop.
var _manual_crop: bool = false
var _player: VideoStreamPlayer = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# Shows `path`, returning false when there is nothing to show (empty path, unreadable file, or an
# animated source with no FFmpeg GDExtension) so callers can skip their image layer entirely
# rather than leaving an empty rect behind.
# Maps an author "image fit" choice to a TextureRect stretch mode. Empty / unknown → `fallback`, so each
# surface keeps its historical default and existing journeys look identical.
static func stretch_for_fit(fit: String, fallback: int) -> int:
	match fit:
		"fit":
			return TextureRect.STRETCH_KEEP_ASPECT_CENTERED  # whole image, letterboxed
		"crop":
			return TextureRect.STRETCH_KEEP_ASPECT_COVERED  # fills the frame, crops the overflow
		"stretch":
			return TextureRect.STRETCH_SCALE  # fills the frame, distorts aspect
	return fallback


# Shows a background as JourneyData.resolved_background_view() described it — path plus the author's
# framing. `fallback_stretch` is the surface's own historical default, used when the background names
# no fit (or came from a plain node/line image, which never carries one).
func show_background(view: Dictionary, fallback_stretch: int) -> bool:
	focus = Vector2(
		clampf(float(view.get("focus_x", 0.5)), 0.0, 1.0),
		clampf(float(view.get("focus_y", 0.5)), 0.0, 1.0)
	)
	zoom = maxf(float(view.get("zoom", 1.0)), 1.0)
	return show_path(
		str(view.get("path", "")),
		TextureRect.EXPAND_IGNORE_SIZE,
		stretch_for_fit(str(view.get("image_fit", "")), fallback_stretch)
	)


func show_path(path: String, expand_mode: int, stretch_mode: int) -> bool:
	_clear()
	# A fresh show decides all of this again from its own stretch mode. Reset rather than leave it: the
	# storyboard reuses ONE JourneyImage for every line, so a stale connection would fire for an image
	# that no longer wants hand-positioning, and stale clipping would crop the next letterboxed one.
	_manual_crop = false
	clip_contents = false
	if resized.is_connected(_apply_crop_align):
		resized.disconnect(_apply_crop_align)
	if path == "":
		return false
	if path.get_extension().to_lower() == ANIMATED_EXT:
		return _show_animated(path, expand_mode, stretch_mode)
	return _show_still(path, expand_mode, stretch_mode)


func _make_rect(expand_mode: int, stretch_mode: int) -> TextureRect:
	var r: TextureRect = TextureRect.new()
	r.expand_mode = expand_mode
	r.stretch_mode = stretch_mode
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(r)
	_manual_crop = _wants_manual_crop(stretch_mode)
	if _manual_crop:
		# Our own clipping, since the rect will be deliberately bigger than this control.
		clip_contents = true
		r.stretch_mode = TextureRect.STRETCH_SCALE  # we compute the exact aspect-preserving size
		r.set_anchors_preset(Control.PRESET_TOP_LEFT)
		resized.connect(_apply_crop_align)
	return r


# True only when the framing differs from what the engine already does — a dead-centre crop at cover
# scale IS the built-in mode, so it stays on it and costs nothing.
func _wants_manual_crop(stretch_mode: int) -> bool:
	if stretch_mode != TextureRect.STRETCH_KEEP_ASPECT_COVERED:
		return false
	return not is_equal_approx(zoom, 1.0) or not focus.is_equal_approx(Vector2(0.5, 0.5))


# Sizes the rect to cover this control (times `zoom`) preserving aspect, then slides it so `focus`
# sits as near the frame's centre as the overflow allows. Re-run on every resize, because the overflow
# depends on the frame's shape — which the editor preview and the player's window do not share.
func _apply_crop_align() -> void:
	# Not for every image: only a non-default crop is positioned by hand. Without this guard the cover
	# maths ran for "fit" and "stretch" too, overwriting the rect's size and position and drawing every
	# background cropped whatever the author chose.
	if not _manual_crop or _rect == null or _rect.texture == null:
		return
	var overflow: Vector2 = _layout_crop()
	if overflow.x < 0.0:
		return
	# focus 0 keeps the leading edge, 1 the trailing, 0.5 centres — the same meaning on both axes and
	# the same meaning whatever the frame's aspect turns out to be.
	_rect.position = -overflow * focus


# Sizes the rect and reports how much of it hangs outside the frame, or (-1, -1) when there is nothing
# to lay out yet. Shared so a caller dragging the image can convert pixels into focus without
# re-deriving the scale.
func _layout_crop() -> Vector2:
	var frame: Vector2 = size
	var tex: Vector2 = _rect.texture.get_size()
	if frame.x <= 0.0 or frame.y <= 0.0 or tex.x <= 0.0 or tex.y <= 0.0:
		return Vector2(-1.0, -1.0)
	# The LARGER ratio, so neither axis is left short — that is what "cover" means.
	var scale: float = maxf(frame.x / tex.x, frame.y / tex.y) * maxf(zoom, 1.0)
	var drawn: Vector2 = tex * scale
	_rect.size = drawn
	return (drawn - frame).max(Vector2.ZERO)


# Moves the framing by a drag in SCREEN pixels, returning the focus it settled on. An axis with no
# overflow cannot move, so dragging it does nothing rather than drifting the image off its own edge.
func drag_focus(delta_px: Vector2) -> Vector2:
	if _rect == null or _rect.texture == null:
		return focus
	var overflow: Vector2 = _layout_crop()
	if overflow.x < 0.0:
		return focus
	var moved: Vector2 = focus
	if overflow.x > 0.0:
		moved.x = clampf(focus.x - delta_px.x / overflow.x, 0.0, 1.0)
	if overflow.y > 0.0:
		moved.y = clampf(focus.y - delta_px.y / overflow.y, 0.0, 1.0)
	focus = moved
	_apply_crop_align()
	return focus


func _show_still(path: String, expand_mode: int, stretch_mode: int) -> bool:
	var img: Image = JourneyData.load_image_smart(path)
	if img == null:
		return false
	_rect = _make_rect(expand_mode, stretch_mode)
	_rect.texture = ImageTexture.create_from_image(img)
	_apply_crop_align()  # the texture is known now, so the first layout can be exact
	return true


func _show_animated(path: String, expand_mode: int, stretch_mode: int) -> bool:
	# Same guard the round player uses: without the GDExtension there is no H.264 decode, and a
	# baked animation is the only form the image exists in — so there's nothing to fall back to.
	if not ClassDB.class_exists("FFmpegVideoStream"):
		push_warning("JourneyImage: FFmpegVideoStream missing — cannot show '%s'." % path)
		return false

	var stream: Resource = ClassDB.instantiate("FFmpegVideoStream")
	stream.set("file", ProjectSettings.globalize_path(path))

	_player = VideoStreamPlayer.new()
	_player.stream = stream as VideoStream
	_player.loop = loop
	if muted:
		_player.volume_db = -80.0
	if not loop:
		_player.finished.connect(func() -> void: animation_finished.emit())
	_player.expand = true
	_player.visible = false  # decodes anyway; the TextureRect below does the drawing
	_player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player.set_anchors_preset(Control.PRESET_FULL_RECT)

	# play() asserts is_inside_tree(), and callers routinely build a whole subtree BEFORE parenting
	# it — ForkScreen fills a card and only then adds it to the row, so nothing here is in the tree
	# yet. Start on tree entry instead. Connecting BEFORE add_child covers both cases with one
	# path: add_child() emits tree_entered straight away when the parent is already in the tree
	# (the storyboard), and defers it until the subtree lands otherwise (fork cards, boss intro).
	_player.tree_entered.connect(_player.play, CONNECT_ONE_SHOT)
	add_child(_player)

	_rect = _make_rect(expand_mode, stretch_mode)
	set_process(true)
	return true


func _process(_delta: float) -> void:
	# Re-read each frame rather than caching once: the playback owns the texture, and this stays
	# correct if it ever hands back a different instance (e.g. across a loop restart).
	if _player != null and _rect != null:
		_rect.texture = _player.get_video_texture()


func _clear() -> void:
	set_process(false)
	if _player != null:
		_player.queue_free()
		_player = null
	if _rect != null:
		_rect.queue_free()
		_rect = null
