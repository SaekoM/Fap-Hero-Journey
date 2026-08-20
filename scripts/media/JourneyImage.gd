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

var _rect: TextureRect = null
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


func show_path(path: String, expand_mode: int, stretch_mode: int) -> bool:
	_clear()
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
	return r


func _show_still(path: String, expand_mode: int, stretch_mode: int) -> bool:
	var img: Image = JourneyData.load_image_smart(path)
	if img == null:
		return false
	_rect = _make_rect(expand_mode, stretch_mode)
	_rect.texture = ImageTexture.create_from_image(img)
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
