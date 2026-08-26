extends Control

signal completed(coins: int)
signal map_requested  # player tapped the "◇ MAP" button (GameLoop owns the map)

const VN_BAR_HEIGHT: int = 210
# Matches SettingMusic's crossfade, so a line that changes place moves its picture and its score over
# the same span rather than one chasing the other.
const BG_FADE_SECS: float = 0.4

# Cast portraits (the VN "stage") are drawn over the background and under the VN bar. Each is placed by
# a PLACEMENT box (screen-fraction x/y/w/h) resolved from the line's stage id via JourneyData —
# the three built-ins (left/center/right) plus any custom placements. A portrait aspect-fits its box.
# Speaker is full brightness; anyone else on stage is dimmed (the standard VN "who's talking" cue).
const PORTRAIT_LIT: Color = Color(1, 1, 1, 1)
const PORTRAIT_DIM: Color = Color(0.5, 0.5, 0.58, 1)

@onready var _bg_image: TextureRect = $BgImage
@onready var _vn_bar: PanelContainer = $VNBar
@onready var _speaker: Label = $VNBar/Inner/VBox/Speaker
@onready var _dialogue: Label = $VNBar/Inner/VBox/DialogueLine
@onready var _hint: Label = $VNBar/Inner/VBox/ContinueHint
@onready var _fade: ColorRect = $FadeOverlay

var _lines: Array = []
var _line_idx: int = 0
var _coins: int = 0
# The storyboard node itself, kept so each line can resolve its backdrop and music against the node's
# defaults and the journey's settings library.
var _node: Dictionary = {}
var _can_advance: bool = false

# Auto-advance countdown (journey opt-in). GameLoop sets auto_advance_secs before _ready; when >0
# each dialogue line auto-advances after the countdown (reset on every line, and whenever the player
# clicks through sooner). The clock only ticks once the opening fade lets the player advance. 0 = off.
var auto_advance_secs: int = 0
var _time_left: float = 0.0
var _timer_active: bool = false
var _countdown_lbl: Label = null

# Optional per-line audio accent. One player, reused as lines advance; a line repeating the same clip
# (a bed) is left playing rather than restarted. Plays over the BGM on the Master bus, at its own volume.
var _audio: AudioStreamPlayer = null
var _current_audio_path: String = ""
# Optional storyboard BGM — one looping track under EVERY line (started once in setup, stopped at exit).

var _skip_btn: Button = null
var _map_btn: Button = null

# Draws the storyboard image (still or baked animation) in $BgImage's place — see _setup_bg_image.
var _bg_view: JourneyImage = null
# The backdrop currently drawn, so an unchanged one is never reloaded — that would restart an animated
# background and dissolve a picture into itself.
var _bg_shown: Dictionary = {}
var _bg_fade: Tween = null

# Persistent-stage cast, from the journey roster. Each line's `stage` is a LIST of {character, portrait,
# placement}; portrait/placement default to the character's first of each. Each character carries its own
# portraits + placements. Portrait nodes are created lazily and reused per CHARACTER (so one who stays
# across lines keeps their node — no flicker, no animated-portrait restart).
var _cast: Dictionary = {}  # character id → character dict (name/portraits[]/placements[])
var _portraits: Dictionary = {}  # character id → JourneyImage
var _portrait_paths: Dictionary = {}  # character id → the path currently shown (skips a needless reload)

var show_map_button: bool = true  # GameLoop clears this when the journey hides the map


func _ready() -> void:
	_apply_layout()
	_setup_bg_image()  # after _apply_layout: it reads $BgImage's finished expand/stretch
	_apply_theme()
	_add_map_button()
	_add_countdown_label()
	_audio = AudioStreamPlayer.new()
	_audio.bus = "Master"
	# A one-shot lifts the duck the moment it ends rather than at the next line, so the score is back up
	# under the pause where a reader actually sits.
	_audio.finished.connect(func() -> void: SettingMusic.unduck())
	add_child(_audio)
	_fade.color = Color.BLACK
	_fade.modulate.a = 1.0
	await get_tree().process_frame
	var tween: Tween = create_tween()
	tween.tween_property(_fade, "modulate:a", 0.0, 0.35).set_ease(Tween.EASE_OUT)
	tween.tween_callback(
		func() -> void:
			_can_advance = true
			_skip_btn.visible = true
			if _map_btn != null:
				_map_btn.visible = true
	)


func setup(data: Dictionary) -> void:
	_coins = data.get("coins", 0)
	_node = data
	_lines = data.get("lines", [])
	_line_idx = 0
	_build_cast()
	if _lines.is_empty():
		_apply_scene({})
		return
	_show_line()


# Indexes the journey's cast roster by id for per-line stage lookups. The roster is journey-level
# (GameState.Journey), not part of the storyboard node's data, and portraits are already resolved to
# absolute paths by the scanner.
func _build_cast() -> void:
	_cast.clear()
	for c: Variant in GameState.Journey.get("characters", []):
		if c is Dictionary:
			var id: String = str((c as Dictionary).get("id", ""))
			if id != "":
				_cast[id] = c


# Asks for the music this line should be under, every line.
#
# Asking repeatedly is deliberate and free: SettingMusic compares the request against what is already
# playing and does nothing when they match, so a scene's theme runs unbroken across its lines and on
# into the next node that wants the same thing. That continuity is why the music lives in an autoload
# rather than in a player owned by this screen — a screen is rebuilt per node, and anything it owns
# restarts with it.
func _apply_scene_audio(line: Dictionary) -> void:
	var wanted: Dictionary = JourneyData.resolved_bgm(
		GameState.Journey.get("settings", []),
		_node,
		line,
		GameState.Journey.get("bgm", []),
		float(GameState.Journey.get("bgm_volume", 0.6))
	)
	if wanted.is_empty():
		SettingMusic.stop()
		return
	SettingMusic.play_playlist(wanted.get("playlist", []), float(wanted.get("volume", 0.6)))


# Ghosts the stage as it looks RIGHT NOW, so the frame that follows can dissolve out of it.
#
# A copy of the drawn frame rather than a second set of layers: the cast portraits are cached per
# character and tinted through modulate, so they cannot be duplicated to fade one against the other —
# and fading only the backdrop is what made the first attempt look broken, with the picture dissolving
# while the characters on it popped.
#
# Sits UNDER the VN bar, so the live bar covers the copy of itself in the ghost and the dialogue never
# double-exposes. Nothing else on screen is above it, so everything the scene change touched fades as
# one thing.
func _ghost_stage() -> void:
	var viewport_texture: ViewportTexture = get_viewport().get_texture()
	if viewport_texture == null:
		return
	var frame: Image = viewport_texture.get_image()
	if frame == null:
		return

	var ghost: TextureRect = TextureRect.new()
	ghost.texture = ImageTexture.create_from_image(frame)
	ghost.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ghost.stretch_mode = TextureRect.STRETCH_SCALE
	ghost.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ghost)
	move_child(ghost, _vn_bar.get_index())

	if _bg_fade != null and _bg_fade.is_valid():
		_bg_fade.kill()
	_bg_fade = create_tween()
	_bg_fade.tween_property(ghost, "modulate:a", 0.0, BG_FADE_SECS)
	_bg_fade.tween_callback(ghost.queue_free)


# True when this line moves the story somewhere else — a different place, not merely a different line
# in the same one. Only that is worth a transition; an ordinary line swapping an expression is not.
func _changes_scene(line: Dictionary) -> bool:
	if _bg_shown.is_empty():
		return false  # the first line has nothing to dissolve out of
	var incoming: Dictionary = JourneyData.resolved_background_view(
		GameState.Journey.get("settings", []), _node, line
	)
	return incoming != _bg_shown


# Draws the backdrop and sets the music for one line (or for a storyboard with no lines at all).
func _apply_scene(line: Dictionary) -> void:
	# Ghost BEFORE anything changes — the copy has to be of the scene being left.
	if _changes_scene(line):
		_ghost_stage()
	_load_bg_view(
		JourneyData.resolved_background_view(GameState.Journey.get("settings", []), _node, line)
	)
	_apply_scene_audio(line)


# Linear 0–1 author volume → dB for an AudioStreamPlayer; 0 mutes.
func _volume_db(v: float) -> float:
	return linear_to_db(v) if v > 0.0 else -80.0


func _show_line() -> void:
	var line: Dictionary = _lines[_line_idx]
	_apply_scene(line)

	var spk: String = line.get("speaker", "")
	_speaker.visible = spk != ""
	_speaker.text = spk.to_upper()
	_dialogue.text = line.get("text", "")

	_update_stage(line)

	var is_last: bool = _line_idx >= _lines.size() - 1
	_hint.text = "▶ CLICK OR SPACE TO COMPLETE" if is_last else "▶ CLICK OR SPACE TO CONTINUE"

	_play_line_audio(line)

	# Restart the per-line countdown (clicking through sooner resets it via this same call).
	if auto_advance_secs > 0:
		_time_left = float(auto_advance_secs)
		_timer_active = true
		_update_countdown_label()


# Plays this line's optional audio accent. A line repeating the clip already playing (a bed carried
# across lines) is left alone so it doesn't restart; anything else swaps in the new clip (or silence).
# Plays the line's audio accent, and steps the score back under it when the author asked.
#
# Unducked FIRST, every time: a looping accent never reports finished, so without this the score would
# stay held down for the rest of the scene once one looping line had ducked it. Clearing on every line
# means the duck lasts exactly as long as the line that asked for it.
func _play_line_audio(line: Dictionary) -> void:
	SettingMusic.unduck()
	var path: String = str(line.get("audio", ""))
	if path != "" and path == _current_audio_path and _audio.playing:
		return
	_audio.stop()
	_current_audio_path = path
	if path == "":
		return
	var stream: AudioStream = JourneyAudio.load_from_file(path)
	if stream == null:
		return
	JourneyAudio.set_loop(stream, bool(line.get("audio_loop", false)))
	_audio.stream = stream
	_audio.volume_db = _volume_db(float(line.get("audio_volume", 1.0)))
	_audio.play()
	if bool(line.get("audio_duck", false)):
		SettingMusic.duck()


# Shows a storyboard image — still, or an animation the builder baked to looping H.264.
#
# This used to re-implement JourneyData.load_image_smart's magic-byte sniffing inline; it now goes
# through JourneyImage, which owns both cases (and that sniffing) in one place. $BgImage is left in
# the scene but retired — see _setup_bg_image.
# Same, for a resolved background that may carry the author's own framing. $BgImage's stretch stays the
# FALLBACK — a plain line image, or a background with no fit set, is framed exactly as it always was.
func _load_bg_view(view: Dictionary) -> void:
	# Identical backdrop: leave it alone. Re-showing would restart an animated background and dissolve
	# a picture into itself — the same reasoning that keeps the music from restarting per line.
	if view == _bg_shown:
		return
	_bg_shown = view.duplicate()
	_bg_view.show_background(view, _bg_image.stretch_mode)


# Puts a JourneyImage exactly where $BgImage sat (same index, so layering is unchanged) and hides
# the original. Done in code rather than by editing the scene: $BgImage still owns the layout, and
# its expand/stretch stay the single source of truth for how the image is framed.
func _setup_bg_image() -> void:
	_bg_view = JourneyImage.new()
	_bg_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bg_view)
	move_child(_bg_view, _bg_image.get_index())
	_bg_image.visible = false


# Lazily creates (or returns) the reused JourneyImage for a character, drawn just above the background
# so it sits under the VN bar and its overlays. Aspect-preserved centering fits any art.
func _ensure_portrait(character_id: String) -> JourneyImage:
	if _portraits.has(character_id):
		return _portraits[character_id]
	var view: JourneyImage = JourneyImage.new()
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.visible = false
	add_child(view)
	move_child(view, _bg_view.get_index() + 1)
	_portraits[character_id] = view
	return view


# Renders the line's persistent stage: a list of {character, portrait, placement}. Each shows that
# character's chosen portrait (default = their first) in their chosen placement box (default = their
# first), and a character whose NAME matches the line's speaker is lit while the rest dim. Characters
# no longer on stage are hidden; a line with no stage clears everything.
func _update_stage(line: Dictionary) -> void:
	var stage: Array = line.get("stage", []) if line.get("stage", null) is Array else []
	var speaker: String = str(line.get("speaker", "")).strip_edges().to_lower()

	# Which character ids are on stage this line, and whether the speaker is one of them (only then do
	# we dim the others — narration / an off-stage speaker leaves everyone at full brightness).
	var on_stage: Dictionary = {}
	var lit_present: bool = false
	for e: Variant in stage:
		if e is Dictionary:
			var cid: String = str((e as Dictionary).get("character", ""))
			on_stage[cid] = true
			if (
				speaker != ""
				and str(_cast.get(cid, {}).get("name", "")).strip_edges().to_lower() == speaker
			):
				lit_present = true

	# Hide any portrait whose character dropped off the stage this line.
	for cid: String in _portraits:
		if not on_stage.has(cid):
			(_portraits[cid] as JourneyImage).visible = false

	for e: Variant in stage:
		if not (e is Dictionary):
			continue
		var cid: String = str((e as Dictionary).get("character", ""))
		var chr: Dictionary = _cast.get(cid, {})
		var portrait: String = JourneyData.character_portrait_path(
			chr, str((e as Dictionary).get("portrait", ""))
		)
		if portrait == "":
			if _portraits.has(cid):
				(_portraits[cid] as JourneyImage).visible = false
			continue
		var view: JourneyImage = _ensure_portrait(cid)
		# Position by the character's chosen placement box. Fractions → anchors, no pixel offsets.
		var box: Dictionary = JourneyData.resolve_placement(
			str((e as Dictionary).get("placement", "")), chr.get("placements", [])
		)
		view.anchor_left = clampf(float(box["x"]), 0.0, 1.0)
		view.anchor_top = clampf(float(box["y"]), 0.0, 1.0)
		view.anchor_right = clampf(float(box["x"]) + float(box["w"]), 0.0, 1.0)
		view.anchor_bottom = clampf(float(box["y"]) + float(box["h"]), 0.0, 1.0)
		view.offset_left = 0.0
		view.offset_top = 0.0
		view.offset_right = 0.0
		view.offset_bottom = 0.0
		# Only (re)load when the portrait path actually changed — a character keeping the same expression
		# keeps their (possibly animated) portrait running instead of restarting it.
		if portrait != str(_portrait_paths.get(cid, "")):
			_portrait_paths[cid] = portrait
			view.show_path(
				portrait, TextureRect.EXPAND_IGNORE_SIZE, TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			)
		view.visible = true
		var is_speaker: bool = (
			lit_present and str(chr.get("name", "")).strip_edges().to_lower() == speaker
		)
		view.modulate = PORTRAIT_LIT if (is_speaker or not lit_present) else PORTRAIT_DIM


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Transition.change_scene("res://scenes/main/Main.tscn")
		return
	if not _can_advance:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			# Let the corner buttons handle clicks that land on them (skip / map),
			# rather than treating the click as an advance.
			if _skip_btn.visible and _skip_btn.get_global_rect().has_point(mb.global_position):
				return
			if (
				_map_btn != null
				and _map_btn.visible
				and _map_btn.get_global_rect().has_point(mb.global_position)
			):
				return
			_advance()
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_advance()
		get_viewport().set_input_as_handled()


func _advance() -> void:
	UISound.storyboard()
	_line_idx += 1
	if _line_idx >= _lines.size():
		_finish()
	else:
		_show_line()


# Counts the current line's timer down once the player is allowed to advance. Pausing is handled by
# GameLoop toggling set_process() while the map viewer is open.
func _process(delta: float) -> void:
	if not _timer_active or not _can_advance:
		return
	_time_left -= delta
	if _time_left <= 0.0:
		_timer_active = false
		_advance()
		return
	_update_countdown_label()


func _finish() -> void:
	_can_advance = false
	_timer_active = false
	if _audio != null:
		_audio.stop()
	# The score outlives this screen, so a duck taken for a line must not leave with it still held down.
	SettingMusic.unduck()
	if _countdown_lbl != null:
		_countdown_lbl.visible = false
	_skip_btn.visible = false
	if _map_btn != null:
		_map_btn.visible = false
	var tween: Tween = create_tween()
	tween.tween_property(_fade, "modulate:a", 1.0, 0.4).set_ease(Tween.EASE_IN)
	tween.tween_callback(
		func() -> void:
			# GameLoop frees this screen during the transition (after the black
			# covers it) — see _transition_swap. Don't self-free, or the play area
			# behind would flash before the fade completes.
			emit_signal("completed", _coins)
	)


# A countdown pinned bottom-left (mirroring the "continue" hint on the right) when the journey arms
# auto-advance. Only built when enabled; text/colour are filled by _update_countdown_label.
func _add_countdown_label() -> void:
	if auto_advance_secs <= 0:
		return
	_countdown_lbl = Label.new()
	_countdown_lbl.anchor_top = 1.0
	_countdown_lbl.anchor_bottom = 1.0
	_countdown_lbl.offset_left = 48  # match the inner-margin gutter the hint uses on the right
	_countdown_lbl.offset_top = -44
	_countdown_lbl.offset_bottom = -22
	_countdown_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(11))
	_countdown_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_countdown_lbl)


func _update_countdown_label() -> void:
	if _countdown_lbl == null:
		return
	var secs: int = int(ceil(_time_left))
	_countdown_lbl.text = "AUTO-ADVANCE IN %d" % secs
	_countdown_lbl.add_theme_color_override(
		"font_color", UITheme.ERROR_SOFT if secs <= 5 else UITheme.DARK_TEXT
	)


# A "◇ MAP" button in the top-right, just left of SKIP, so the player can open the
# read-only journey map mid-storyboard. GameLoop owns the map — we emit a request and
# it opens the viewer over this screen. Revealed alongside SKIP once the open fade ends.
func _add_map_button() -> void:
	if not show_map_button:
		return
	var accent: Color = UITheme.PURPLE_BRIGHT
	_map_btn = Button.new()
	_map_btn.text = "◇ MAP"
	_map_btn.focus_mode = Control.FOCUS_NONE
	_map_btn.tooltip_text = "View the journey map (M)"
	_map_btn.visible = false
	_map_btn.anchor_left = 1.0
	_map_btn.anchor_right = 1.0
	_map_btn.anchor_top = 0.0
	_map_btn.anchor_bottom = 0.0
	_map_btn.offset_left = -236  # sits left of SKIP (which spans -110..-16)
	_map_btn.offset_right = -126
	_map_btn.offset_top = 16
	_map_btn.offset_bottom = 46
	_map_btn.pressed.connect(func() -> void: emit_signal("map_requested"))
	add_child(_map_btn)

	_map_btn.add_theme_color_override("font_color", accent)
	_map_btn.add_theme_color_override("font_hover_color", UITheme.WHITE_SOFT)
	_map_btn.add_theme_font_size_override("font_size", 11)
	var n: StyleBoxFlat = StyleBoxFlat.new()
	n.bg_color = Color(accent.r, accent.g, accent.b, 0.10)
	n.border_color = accent
	n.border_width_left = 1
	n.border_width_right = 1
	n.border_width_top = 1
	n.border_width_bottom = 1
	n.set_corner_radius_all(UITheme.CORNER_RADIUS)
	n.content_margin_left = 10
	n.content_margin_right = 10
	n.content_margin_top = 4
	n.content_margin_bottom = 4
	_map_btn.add_theme_stylebox_override("normal", n)
	var h: StyleBoxFlat = n.duplicate()
	h.bg_color = Color(accent.r, accent.g, accent.b, 0.28)
	_map_btn.add_theme_stylebox_override("hover", h)
	_map_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


# ---------------------------------------------------------------------------
# Layout / theme
# ---------------------------------------------------------------------------


func _apply_layout() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	_bg_image.anchor_left = 0.0
	_bg_image.anchor_top = 0.0
	_bg_image.anchor_right = 1.0
	_bg_image.anchor_bottom = 1.0
	_bg_image.offset_left = 0
	_bg_image.offset_top = 0
	_bg_image.offset_right = 0
	_bg_image.offset_bottom = 0
	_bg_image.expand_mode = 1  # EXPAND_IGNORE — never overflow anchor bounds
	_bg_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

	_vn_bar.anchor_left = 0.0
	_vn_bar.anchor_right = 1.0
	_vn_bar.anchor_top = 1.0
	_vn_bar.anchor_bottom = 1.0
	_vn_bar.offset_top = -VN_BAR_HEIGHT
	_vn_bar.offset_bottom = 0

	_fade.anchor_right = 1.0
	_fade.anchor_bottom = 1.0

	var inner: MarginContainer = $VNBar/Inner
	inner.add_theme_constant_override("margin_left", 48)
	inner.add_theme_constant_override("margin_right", 48)
	inner.add_theme_constant_override("margin_top", 22)
	inner.add_theme_constant_override("margin_bottom", 22)

	var vbox: VBoxContainer = $VNBar/Inner/VBox
	vbox.add_theme_constant_override("separation", 12)

	# Detach hint from the VBox so it no longer participates in the text flow.
	# Re-parent it directly onto the root Control as an absolutely-positioned
	# overlay pinned to the bottom-right corner — it will never move regardless
	# of speaker visibility or dialogue line wrapping.
	vbox.remove_child(_hint)
	add_child(_hint)
	_hint.anchor_left = 0.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_left = 0
	_hint.offset_right = -48  # match inner right margin
	_hint.offset_top = -44  # inner bottom margin (22) + label height (~22)
	_hint.offset_bottom = -22  # inner bottom margin
	_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Skip button — top-right corner, hidden until the opening fade completes.
	_skip_btn = Button.new()
	_skip_btn.text = "SKIP  ▶▶"
	_skip_btn.anchor_left = 1.0
	_skip_btn.anchor_right = 1.0
	_skip_btn.anchor_top = 0.0
	_skip_btn.anchor_bottom = 0.0
	_skip_btn.offset_left = -110
	_skip_btn.offset_right = -16
	_skip_btn.offset_top = 16
	_skip_btn.offset_bottom = 46
	_skip_btn.focus_mode = Control.FOCUS_NONE
	_skip_btn.visible = false
	_skip_btn.pressed.connect(_finish)
	add_child(_skip_btn)


func _apply_theme() -> void:
	var bar_style: StyleBoxFlat = StyleBoxFlat.new()
	bar_style.bg_color = UITheme.BAR_BG
	bar_style.border_color = UITheme.CYAN
	bar_style.border_width_top = 2
	bar_style.content_margin_left = 0
	bar_style.content_margin_right = 0
	bar_style.content_margin_top = 0
	bar_style.content_margin_bottom = 0
	_vn_bar.add_theme_stylebox_override("panel", bar_style)

	_speaker.add_theme_color_override("font_color", UITheme.CYAN)
	_speaker.add_theme_font_size_override("font_size", UITheme.story_font_size(14))
	_speaker.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_speaker.uppercase = true

	_dialogue.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	_dialogue.add_theme_font_size_override("font_size", UITheme.story_font_size(19))
	_dialogue.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_hint.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	_hint.add_theme_font_size_override("font_size", UITheme.story_font_size(11))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# Skip button — subtle but readable; uses DARK_TEXT so it doesn't compete
	# with the dialogue, but brightens on hover.
	_skip_btn.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	_skip_btn.add_theme_color_override("font_hover_color", UITheme.WHITE_SOFT)
	_skip_btn.add_theme_color_override("font_pressed_color", UITheme.BG)
	_skip_btn.add_theme_font_size_override("font_size", 11)

	var sk_n: StyleBoxFlat = StyleBoxFlat.new()
	sk_n.bg_color = Color(UITheme.DARK_TEXT.r, UITheme.DARK_TEXT.g, UITheme.DARK_TEXT.b, 0.08)
	sk_n.border_color = UITheme.DARK_TEXT
	sk_n.border_width_left = 1
	sk_n.border_width_right = 1
	sk_n.border_width_top = 1
	sk_n.border_width_bottom = 1
	sk_n.set_corner_radius_all(UITheme.CORNER_RADIUS)
	sk_n.content_margin_left = 10
	sk_n.content_margin_right = 10
	sk_n.content_margin_top = 4
	sk_n.content_margin_bottom = 4
	_skip_btn.add_theme_stylebox_override("normal", sk_n)

	var sk_h: StyleBoxFlat = sk_n.duplicate()
	sk_h.bg_color = Color(UITheme.WHITE_SOFT.r, UITheme.WHITE_SOFT.g, UITheme.WHITE_SOFT.b, 0.15)
	sk_h.border_color = UITheme.WHITE_SOFT
	_skip_btn.add_theme_stylebox_override("hover", sk_h)

	var sk_p: StyleBoxFlat = sk_n.duplicate()
	sk_p.bg_color = UITheme.DARK_TEXT
	_skip_btn.add_theme_stylebox_override("pressed", sk_p)
	_skip_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
