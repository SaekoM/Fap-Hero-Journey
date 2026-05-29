extends Control

const OptionsScene         = preload("res://scenes/options/Options.tscn")
const ForkScene            = preload("res://scenes/fork_screen/ForkScreen.tscn")
const ShopScene            = preload("res://scenes/shop_screen/ShopScreen.tscn")
const StoryboardScene      = preload("res://scenes/storyboard_screen/StoryboardScreen.tscn")
const InventoryPanelScene  = preload("res://scenes/inventory/InventoryPanel.tscn")
const BeatBarScript        = preload("res://scripts/game_loop/BeatBar.gd")

# ---------------------------------------------------------------------------
# GameLoop.gd  –  Round controller and video player
# Reads the active journey from GameState, loads each round's video and
# funscript in sequence, then transitions to EndScreen when all rounds finish.
#
# MP4 NOTE: Godot's built-in VideoStreamPlayer only decodes .ogv (Theora).
# Install EIRTeam.FFmpeg GDExtension for MP4 support, then replace the
# _load_video() body with that extension's API.
# ---------------------------------------------------------------------------

const HUD_BAR_HEIGHT:  int   = 68
# Playback-capable formats. Intentionally distinct from JourneyData.VIDEO_EXTENSIONS
# (the import/transcode set): includes "ogv" (Godot-native, no FFmpeg needed) and
# omits container types that only matter at import time.
const VIDEO_EXTS:      Array = ["mp4", "mkv", "webm", "avi", "mov", "ogv"]

# Sequence-boundary fade timings (~1.2s total).
const TRANSITION_FADE_TIME: float = 0.45
const TRANSITION_HOLD_TIME: float = 0.30

# Boss rounds: the red frame pulses during the round's final stretch.
const BOSS_CLIMAX_SECS: float = 30.0
# Boss forced-modifier kind → HUD chip label.
const BOSS_EFFECT_NAMES: Dictionary = {
	"scale":            "SCALE",
	"clamp":            "CLAMP",
	"reverse":          "REVERSE",
	"blackout":         "BLACKOUT",
	"score_multiplier": "SCORE ×",
}

@onready var _bg:          ColorRect         = $Background
@onready var _video:       VideoStreamPlayer = $VideoPlayer
@onready var _hud:         Control           = $HUD
@onready var _hud_bar:     PanelContainer    = $HUD/HUDBar
@onready var _hud_layout:  HBoxContainer     = $HUD/HUDBar/HUDLayout
@onready var _round_lbl:   Label             = $HUD/HUDBar/HUDLayout/RoundLabel
@onready var _coin_lbl:    Label             = $HUD/HUDBar/HUDLayout/CoinLabel
@onready var _progress:    ProgressBar       = $HUD/ProgressBar
@onready var _score_lbl:   Label             = $HUD/HUDBar/HUDLayout/ScoreLabel
@onready var _pause_btn:   Button            = $HUD/HUDBar/HUDLayout/PauseBtn
@onready var _inv_btn:     Button            = $HUD/HUDBar/HUDLayout/InventoryBtn
@onready var _menu_btn:    Button            = $HUD/HUDBar/HUDLayout/MenuBtn
@onready var _options_btn: Button            = $HUD/HUDBar/HUDLayout/OptionsBtn
@onready var _chips_row:   HBoxContainer     = $HUD/EffectChipsRow
@onready var _hide_timer:  Timer             = $HUD/HideTimer

# Persistent banner shown at top of screen whenever the *currently selected*
# output device drops its connection during play. Built dynamically in
# _apply_layout so the scene file doesn't need a new node. Lives outside the
# auto-hiding HUD so it stays visible even when the rest of the HUD fades.
var _device_warning_banner: PanelContainer = null
var _device_warning_label:  Label          = null
@onready var _end_timer:   Timer             = $EndTimer
@onready var _transition:  ColorRect         = $TransitionLayer/TransitionOverlay

var _paused: bool = false
var _inventory_panel: Control = null
var _cover_applied: bool = false

# True while a full-screen overlay (shop / fork / storyboard) is active.
# Used to suppress gameplay hotkeys that should not fire through an overlay.
var _is_overlay_open: bool = false

# True for the duration of a boss round (set when the round loads, cleared at
# round end). Drives item lockout, the red frame, and the climax pulse.
var _is_boss_round: bool  = false
var _boss_frame:    Panel = null

# Optional beat-bar visualiser — created only when the setting is enabled.
var _beat_bar: Control = null


func _ready() -> void:
	MusicService.stop()
	_apply_layout()
	_apply_theme()
	_build_boss_frame()
	_build_beat_bar()
	_connect_signals()
	ScoreService.Reset()
	CoinService.Reset()
	InventoryService.Reset()
	# Pure-GDScript round-name log, read by EndScreen. Stored as meta on
	# GameState so it survives the scene change. Cleared here so a new
	# journey starts fresh.
	GameState.set_meta("_round_names", PackedStringArray())
	_refresh_coin_label()
	_load_current_item()
	_show_hud()


func _process(_delta: float) -> void:
	if _video.is_playing():
		var len: float = _video.get_stream_length()
		if len > 0.0:
			_progress.value = _video.stream_position / len
		# Keep funscript in sync with video clock
		FunscriptPlayer.SyncTo(_video.stream_position)
		if not _cover_applied:
			_fit_video_cover()
	_update_chip_countdowns()
	if _is_boss_round:
		_update_boss_frame()
	if _beat_bar != null:
		_beat_bar.set_time(FunscriptPlayer.PositionMs)


# ---------------------------------------------------------------------------
# Item loading (round or fork)
# ---------------------------------------------------------------------------

func _load_current_item() -> void:
	match GameState.CurrentItemType():
		"fork":
			_show_fork_screen(GameState.CurrentFork())
		"shop":
			_show_shop_screen(GameState.CurrentShop())
		"storyboard":
			_show_storyboard_screen(GameState.CurrentStoryboard())
		_:
			_load_current_round()


func _show_storyboard_screen(sb_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	_start_storyboard_filler()
	var storyboard: Control = StoryboardScene.instantiate()
	storyboard.completed.connect(_on_storyboard_completed)
	add_child(storyboard)
	storyboard.setup(sb_data)


func _start_storyboard_filler() -> void:
	if not SettingsService.get_filler_enabled():
		return
	FunscriptPlayer.StartFiller(
		SettingsService.get_filler_lo(),
		SettingsService.get_filler_hi(),
		SettingsService.get_filler_half_cycle_ms())


func _on_storyboard_completed(coins: int) -> void:
	FunscriptPlayer.StopFiller()
	_is_overlay_open = false
	if coins > 0:
		CoinService.AddCoins(coins)
	GameState.Advance()
	if GameState.IsSequenceDone():
		Transition.change_scene("res://scenes/end_screen/EndScreen.tscn")
		return
	await _transition_swap(func() -> void:
		_video.paused = false
		FunscriptPlayer.Resume()
		_load_current_item()
	)


func _show_shop_screen(shop_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	var shop: Control = ShopScene.instantiate()
	shop.closed.connect(_on_shop_closed)
	add_child(shop)
	shop.setup(shop_data)


func _on_shop_closed() -> void:
	_is_overlay_open = false
	GameState.Advance()
	if GameState.IsSequenceDone():
		Transition.change_scene("res://scenes/end_screen/EndScreen.tscn")
		return
	await _transition_swap(func() -> void:
		_video.paused = false
		FunscriptPlayer.Resume()
		_load_current_item()
	)


func _show_fork_screen(fork_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	var fork_screen = ForkScene.instantiate()
	fork_screen.path_chosen.connect(_on_fork_path_chosen)
	add_child(fork_screen)
	fork_screen.setup(fork_data)


func _on_fork_path_chosen(path_index: int) -> void:
	_is_overlay_open = false
	GameState.ResolveFork(path_index)
	await _transition_swap(func() -> void:
		_video.paused = false
		FunscriptPlayer.Resume()
		_load_current_item()
	)


func _load_current_round() -> void:
	var round: Dictionary = GameState.CurrentRound()
	if round.is_empty():
		push_error("GameLoop: GameState has no current round — returning to menu")
		_go_to_menu()
		return

	var total: int = GameState.TotalRounds()
	var num:   int = GameState.RoundNumber

	_progress.value = 0.0
	_paused = false
	_pause_btn.text = "|| PAUSE"

	_is_boss_round = round.get("round_type", "normal") == "boss"
	if _is_boss_round:
		_round_lbl.text = "⚔  BOSS  %d / %d  —  %s" % [num, total,
			(round.get("name", "") as String).to_upper()]
		# Telegraph the boss — playback begins only when the player commits.
		_show_boss_intro(round)
	else:
		_round_lbl.text = "ROUND %d / %d  —  %s" % [num, total,
			(round.get("name", "") as String).to_upper()]
		_begin_round(round)


# Loads the round's scripts + video and starts playback. For boss rounds this
# runs after the intro card's BEGIN; for normal rounds, immediately.
func _begin_round(round: Dictionary) -> void:
	ScoreService.StartRound()

	var fs_path: String = round.get("funscript_path", "")
	if fs_path != "":
		FunscriptPlayer.LoadFunscript(fs_path)
		ScoreService.SetRoundActions(FunscriptPlayer.ActionCount)
		if _beat_bar != null:
			_beat_bar.set_beats(FunscriptPlayer.GetBeats())

	# Load secondary axis scripts (serial devices only; FunscriptPlayer ignores
	# them if output mode is Buttplug). Clear first so stale axes from a prior
	# round are never replayed.
	FunscriptPlayer.ClearAxisScripts()
	var axis_scripts: Dictionary = round.get("axis_scripts", {})
	for axis: String in axis_scripts:
		var ax_path: String = axis_scripts[axis]
		if ax_path != "":
			FunscriptPlayer.LoadAxisScript(axis, ax_path)

	# Load vibrator-channel scripts (Buttplug vibrators only; ignored for linear
	# devices and serial output). Clear first so stale channels from a prior round
	# are never sent to the device.
	FunscriptPlayer.ClearVibScripts()
	var vib_scripts: Dictionary = round.get("vib_scripts", {})
	for ch_key: String in vib_scripts:
		var vib_path: String = vib_scripts[ch_key]
		if vib_path != "":
			var channel: int = 0 if ch_key == "vib1" else 1
			FunscriptPlayer.LoadVibScript(channel, vib_path)

	# Boss setup must run before _load_video → FunscriptPlayer.Play() so the
	# forced modifiers are already active on the first dispatched stroke.
	if _is_boss_round:
		_enter_boss_mode(round)

	var folder: String = round.get("folder", "")
	var video_path: String = _find_video(folder)
	_load_video(video_path)


# ---------------------------------------------------------------------------
# Boss rounds
# ---------------------------------------------------------------------------

# Telegraphed intro card. The round's scripts/video do not load and playback
# does not start until the player clicks BEGIN.
func _show_boss_intro(round: Dictionary) -> void:
	_is_overlay_open = true  # suppress gameplay hotkeys while the card is up

	var overlay: Control = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)

	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.92)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(backdrop)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.border_color = UITheme.DANGER
	ps.border_width_left = 3; ps.border_width_right = 3
	ps.border_width_top = 3; ps.border_width_bottom = 3
	ps.content_margin_left = 48; ps.content_margin_right = 48
	ps.content_margin_top = 36;  ps.content_margin_bottom = 36
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	panel.add_child(col)

	var banner: Label = Label.new()
	banner.text = "⚔   B O S S   R O U N D   ⚔"
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_theme_color_override("font_color", UITheme.DANGER)
	banner.add_theme_font_size_override("font_size", 28)
	col.add_child(banner)

	var boss_image: String = round.get("boss_image", "")
	if boss_image != "":
		var img: Image = JourneyData.load_image_smart(boss_image)
		if img != null:
			var tex: TextureRect = TextureRect.new()
			tex.texture = ImageTexture.create_from_image(img)
			tex.custom_minimum_size = Vector2(380, 240)
			tex.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
			tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			col.add_child(tex)

	var name_lbl: Label = Label.new()
	name_lbl.text = (round.get("name", "") as String).to_upper()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", 22)
	col.add_child(name_lbl)

	var tagline: String = round.get("boss_tagline", "")
	if tagline.strip_edges() != "":
		var tag_lbl: Label = Label.new()
		tag_lbl.text = tagline
		tag_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tag_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tag_lbl.custom_minimum_size = Vector2(440, 0)
		tag_lbl.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
		tag_lbl.add_theme_font_size_override("font_size", 14)
		col.add_child(tag_lbl)

	var rules_lbl: Label = Label.new()
	rules_lbl.text = "NO ITEMS  ·  FORCED MODIFIERS"
	rules_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rules_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	rules_lbl.add_theme_font_size_override("font_size", 11)
	col.add_child(rules_lbl)

	var begin_btn: Button = Button.new()
	begin_btn.text = "⚔  BEGIN"
	begin_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UITheme.style_button(begin_btn, UITheme.DANGER, 32, 14)
	col.add_child(begin_btn)
	begin_btn.pressed.connect(func() -> void:
		overlay.queue_free()
		_is_overlay_open = false
		_begin_round(round)
	)


# Clean slate, forced modifiers, item lockout, red frame on.
func _enter_boss_mode(round: Dictionary) -> void:
	# Clean slate — drop any effects the player activated before the boss.
	InventoryService.ClearActiveEffects()

	# Inject the designer's forced modifiers as boss effects.
	var boss_effects: Array = []
	for mod: Dictionary in round.get("boss_modifiers", []):
		boss_effects.append(_make_boss_effect(mod))
	if not boss_effects.is_empty():
		InventoryService.AddBossEffects(boss_effects)

	# Item use is disabled for the whole boss round.
	if is_instance_valid(_inventory_panel):
		_inventory_panel.close()
	_inv_btn.disabled = true

	if _boss_frame != null:
		_boss_frame.visible    = true
		_boss_frame.modulate.a = 0.5


# Tears down boss state at round end. Safe to call on non-boss rounds.
func _exit_boss_mode() -> void:
	if not _is_boss_round:
		return
	_is_boss_round = false
	InventoryService.ClearBossEffects()
	_inv_btn.disabled = false
	if _boss_frame != null:
		_boss_frame.visible = false


# Converts a saved boss modifier ({kind, factor?, min?, max?}) into a full
# effect dict the active-effects pipeline understands.
func _make_boss_effect(mod: Dictionary) -> Dictionary:
	var kind: String = mod.get("kind", "")
	var effect: Dictionary = {
		"id":   "boss_" + kind,
		"name": BOSS_EFFECT_NAMES.get(kind, kind.to_upper()),
		"kind": kind,
		"boss": true,
	}
	if mod.has("factor"):
		effect["factor"] = mod["factor"]
	if mod.has("min"):
		effect["min"] = mod["min"]
	if mod.has("max"):
		effect["max"] = mod["max"]
	return effect


func _build_beat_bar() -> void:
	if not SettingsService.get_beat_bar_enabled():
		return
	_beat_bar = BeatBarScript.new()
	_beat_bar.anchor_left   = 0.0
	_beat_bar.anchor_right  = 1.0
	_beat_bar.anchor_top    = 1.0
	_beat_bar.anchor_bottom = 1.0
	_beat_bar.offset_left   = 0.0
	_beat_bar.offset_right  = 0.0
	_beat_bar.offset_top    = -120.0
	_beat_bar.offset_bottom = -56.0
	add_child(_beat_bar)


# Brings the beat bar into sync with the current setting. Called after the
# Options overlay closes so toggling "Beat Bar" mid-game takes effect on the
# active round instead of requiring the user to exit and re-enter.
func _refresh_beat_bar_visibility() -> void:
	var should_show: bool = SettingsService.get_beat_bar_enabled()
	if should_show and _beat_bar == null:
		_build_beat_bar()
		# Seed the new bar with the current round's beats if a round is loaded
		# so it doesn't start blank.
		if _beat_bar != null and FunscriptPlayer.ActionCount > 0:
			_beat_bar.set_beats(FunscriptPlayer.GetBeats())
	elif not should_show and _beat_bar != null:
		_beat_bar.queue_free()
		_beat_bar = null


func _build_boss_frame() -> void:
	_boss_frame = Panel.new()
	_boss_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_boss_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_frame.visible = false
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	s.border_color = UITheme.DANGER
	s.border_width_left = 6; s.border_width_right  = 6
	s.border_width_top  = 6; s.border_width_bottom = 6
	_boss_frame.add_theme_stylebox_override("panel", s)
	add_child(_boss_frame)


# Holds the boss frame at a subtle level, then pulses it in the final stretch.
func _update_boss_frame() -> void:
	if _boss_frame == null:
		return
	var remaining: float = _round_time_left()
	if remaining > 0.0 and remaining <= BOSS_CLIMAX_SECS:
		var t: float = Time.get_ticks_msec() / 1000.0
		_boss_frame.modulate.a = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * TAU * 1.5))
	else:
		_boss_frame.modulate.a = 0.5


# Seconds left in the current round — from the video clock, or the no-video
# fallback timer. Returns -1 when unknown.
func _round_time_left() -> float:
	if _video.is_playing():
		var vlen: float = _video.get_stream_length()
		if vlen > 0.0:
			return vlen - _video.stream_position
	if not _end_timer.is_stopped():
		return _end_timer.time_left
	return -1.0


func _fit_video_cover() -> void:
	var texture := _video.get_video_texture()
	if texture == null:
		return
	var video_size := texture.get_size()
	if video_size.x <= 0.0 or video_size.y <= 0.0:
		return
	_cover_applied = true
	var screen := get_viewport_rect().size
	var video_ar := video_size.x / video_size.y
	var screen_ar := screen.x / screen.y
	var scaled: Vector2
	if video_ar > screen_ar:
		# Wider than screen — fit width, letterbox top/bottom
		scaled = Vector2(screen.x, screen.x / video_ar)
	else:
		# Taller than screen — fit height, letterbox sides
		scaled = Vector2(screen.y * video_ar, screen.y)
	_video.position = (screen - scaled) / 2.0
	_video.size = scaled


func _find_video(folder: String) -> String:
	if folder == "":
		return ""
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension().to_lower() in VIDEO_EXTS:
			dir.list_dir_end()
			return folder + "/" + fname
		fname = dir.get_next()
	dir.list_dir_end()
	return ""


func _load_video(path: String) -> void:
	_cover_applied = false
	_video.position = Vector2.ZERO
	_video.size = get_viewport_rect().size
	if path == "":
		push_warning("GameLoop: no video found for this round — funscript-only fallback")
		_start_no_video_fallback()
		return

	var ext: String = path.get_extension().to_lower()

	if ext == "ogv":
		var stream: Resource = ResourceLoader.load(path)
		if stream and stream is VideoStream:
			_video.stream = stream as VideoStream
			_video.play()
			FunscriptPlayer.Play()
			return
		push_warning("GameLoop: could not load .ogv at %s" % path)
		_start_no_video_fallback()
		return

	# MP4/MKV/WebM — requires EIRTeam.FFmpeg GDExtension.
	# Install: https://github.com/EIRTeam/EIRTeam.FFmpeg/releases
	# Drop the addons/ folder into the project root and reopen Godot.
	if not ClassDB.class_exists("FFmpegVideoStream"):
		push_warning("GameLoop: FFmpegVideoStream not found — install EIRTeam.FFmpeg for MP4 support. Running funscript-only.")
		_start_no_video_fallback()
		return

	var abs_path: String = ProjectSettings.globalize_path(path)
	var stream: Resource = ClassDB.instantiate("FFmpegVideoStream")
	stream.set("file", abs_path)
	_video.stream = stream as VideoStream
	_video.play()

	# EIRTeam.FFmpeg surfaces open/decode failures as C++-level push_errors
	# rather than a catchable GDScript return value. Give the player one frame
	# to settle: if the file couldn't be opened the player will have stopped
	# itself, and is_playing() returns false. In that case wipe the stream and
	# fall back to the funscript-only timer so the round still advances.
	await get_tree().process_frame
	if not _video.is_playing():
		push_warning("GameLoop: video failed to open '%s' — funscript-only fallback." % abs_path)
		_video.stream = null
		_start_no_video_fallback()
		return
	FunscriptPlayer.Play()


func _start_no_video_fallback() -> void:
	# No video: use funscript length to drive a timer so the round still advances.
	FunscriptPlayer.Play()
	var dur_ms: int = GameState.CurrentRound().get("length_ms", 0)
	if dur_ms > 0:
		_end_timer.wait_time = dur_ms / 1000.0
		_end_timer.start()
	else:
		# Unknown length — let the player advance manually (pause button becomes skip)
		_pause_btn.text = "> SKIP"


# ---------------------------------------------------------------------------
# Round / scene transitions
# ---------------------------------------------------------------------------

func _on_round_ended() -> void:
	# Extract the name here in GDScript where Dictionary access is reliable,
	# then pass it explicitly so C# never needs to look up the key itself.
	var _cur: Dictionary = GameState.CurrentRound()
	var _cur_name: String = _cur.get("name", "") as String
	var _cur_ms: int      = _cur.get("length_ms", 0) as int
	GameState.LogRound(_cur, _cur_name, _cur_ms)

	# Append to the GDScript-side round-name log (see _ready). EndScreen reads
	# this directly, avoiding any potential C#→GDScript Dictionary marshalling
	# quirks for the name string.
	var _names: PackedStringArray = GameState.get_meta("_round_names", PackedStringArray()) as PackedStringArray
	_names.append(_cur_name)
	GameState.set_meta("_round_names", _names)
	ScoreService.EndRound()
	FunscriptPlayer.Stop()
	# Tear down boss state (forced modifiers, item lockout, red frame) if active.
	_exit_boss_mode()

	var coins: int = GameState.CurrentRound().get("coins", 0)
	# Apply any active coin_jackpot multipliers, then consume them so a single
	# jackpot only ever doubles one round's reward (matches the item description).
	var jackpot_factor: float = 1.0
	for fx: Dictionary in InventoryService.GetActiveEffects():
		if fx.get("kind", "") == "coin_jackpot":
			jackpot_factor *= float(fx.get("factor", 1.0))
	coins = roundi(coins * jackpot_factor)
	InventoryService.ConsumeEffects("coin_jackpot")
	if coins > 0:
		CoinService.AddCoins(coins)

	if GameState.IsLastRound():
		Transition.change_scene("res://scenes/end_screen/EndScreen.tscn")
		return
	await _transition_swap(func() -> void:
		GameState.Advance()
		_load_current_item()
	)


# Fade-to-black → hold → run swap → fade-from-black. Used at every sequence
# boundary so transitions feel intentional instead of jump-cut. The transition
# overlay lives on a high-layer CanvasLayer, so it always sits above shop /
# storyboard / fork screens that may be added/removed during the swap.
func _transition_swap(swap_action: Callable) -> void:
	_transition.mouse_filter = Control.MOUSE_FILTER_STOP

	var tween_in: Tween = create_tween()
	tween_in.tween_property(_transition, "modulate:a", 1.0, TRANSITION_FADE_TIME).set_ease(Tween.EASE_IN)
	await tween_in.finished

	await get_tree().create_timer(TRANSITION_HOLD_TIME).timeout
	swap_action.call()

	var tween_out: Tween = create_tween()
	tween_out.tween_property(_transition, "modulate:a", 0.0, TRANSITION_FADE_TIME).set_ease(Tween.EASE_OUT)
	await tween_out.finished

	_transition.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _go_to_menu() -> void:
	_video.stop()
	FunscriptPlayer.Stop()
	Transition.change_scene("res://scenes/main/Main.tscn")


func _on_options_pressed() -> void:
	_video.paused = true
	FunscriptPlayer.Pause()
	# Freeze the active-effect clock while the Options overlay is open.
	InventoryService.SetPaused(true)
	var opts: Control = OptionsScene.instantiate()
	opts.overlay_mode = true
	opts.tree_exiting.connect(_on_options_closed)
	add_child(opts)


func _on_options_closed() -> void:
	# Only resume if the round was not separately paused via the pause button —
	# in that case the effect clock must stay frozen until the player resumes.
	if not _paused:
		_video.paused = false
		FunscriptPlayer.Resume()
		InventoryService.SetPaused(false)
	# Output mode may have changed in Options — re-evaluate the disconnect
	# banner against whatever backend is now selected.
	_refresh_device_warning()
	# Beat-bar visibility setting may have toggled — create or destroy the bar
	# to match the new state without requiring the user to exit the journey.
	_refresh_beat_bar_visibility()


# ---------------------------------------------------------------------------
# Pause / HUD
# ---------------------------------------------------------------------------

func _toggle_pause() -> void:
	_paused = not _paused
	_video.paused = _paused
	# Freeze the active-effect clock so timed items don't drain while paused.
	InventoryService.SetPaused(_paused)
	if _paused:
		FunscriptPlayer.Pause()
		_pause_btn.text = "> RESUME"
	else:
		FunscriptPlayer.Resume()
		_pause_btn.text = "|| PAUSE"


func _show_hud() -> void:
	_hud.modulate = Color(1, 1, 1, 1)
	_hud.visible  = true
	_hide_timer.start(SettingsService.get_hud_hide_delay())


func _on_hide_timer_timeout() -> void:
	_hud.visible = false


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# Any activity shows the HUD.
	if event is InputEventMouseMotion or event is InputEventMouseButton \
			or event is InputEventKey:
		_show_hud()

	# Keyboard hotkeys — evaluated in order of specificity.
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			match key_event.keycode:
				KEY_SPACE:
					# Space: pause / resume — blocked while a full-screen overlay is open
					# (shop / fork / storyboard handles its own input first).
					if not _is_overlay_open:
						_toggle_pause()
						get_viewport().set_input_as_handled()
				KEY_TAB:
					# Tab: toggle inventory panel — disabled during boss rounds.
					if not _is_overlay_open and not _is_boss_round:
						_on_inventory_pressed()
						get_viewport().set_input_as_handled()
				KEY_ESCAPE:
					# Esc: close inventory if open, otherwise leave to menu.
					# Overlay screens (shop/storyboard) capture Esc themselves before
					# it reaches here; the fork screen intentionally does not (no escape).
					if not _is_overlay_open:
						if is_instance_valid(_inventory_panel):
							_inventory_panel.close()
						else:
							_go_to_menu()
						get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

func _on_score_changed(total: int) -> void:
	_score_lbl.text = str(total) + " PTS"


func _connect_signals() -> void:
	_video.finished.connect(_on_round_ended)
	_end_timer.timeout.connect(_on_round_ended)
	_pause_btn.pressed.connect(_toggle_pause)
	_menu_btn.pressed.connect(_go_to_menu)
	_hide_timer.timeout.connect(_on_hide_timer_timeout)
	_pause_btn.mouse_entered.connect(_show_hud)
	_menu_btn.mouse_entered.connect(_show_hud)
	_options_btn.pressed.connect(_on_options_pressed)
	_options_btn.mouse_entered.connect(_show_hud)
	_inv_btn.pressed.connect(_on_inventory_pressed)
	_inv_btn.mouse_entered.connect(_show_hud)
	ScoreService.ScoreChanged.connect(_on_score_changed)
	CoinService.BalanceChanged.connect(_on_coin_balance_changed)
	InventoryService.ActiveEffectsChanged.connect(_refresh_effect_chips)

	# Device-connection signals — surface a banner when the currently selected
	# output device drops its connection, and clear it on reconnect. We watch
	# both backends so an output-mode change in Options mid-game picks up the
	# correct state via _refresh_device_warning(). DeviceAdded / DeviceRemoved
	# matter independently of Connected/Disconnected: a device can drop
	# (battery, Bluetooth, USB unplug) while Intiface itself stays running.
	ButtplugService.connect("Connected",      _refresh_device_warning)
	ButtplugService.connect("Disconnected",   _refresh_device_warning)
	ButtplugService.connect("DeviceAdded",    func(_n: String, _i: int) -> void: _refresh_device_warning())
	ButtplugService.connect("DeviceRemoved",  func(_i: int) -> void: _refresh_device_warning())
	SerialDeviceService.connect("Connected",    _refresh_device_warning)
	SerialDeviceService.connect("Disconnected", _refresh_device_warning)
	_refresh_device_warning()


# ---------------------------------------------------------------------------
# Device connection state
# ---------------------------------------------------------------------------

# Updates the disconnect banner to reflect the currently selected output mode
# and the relevant connection state. Called from connect/disconnect/device
# signals on both backends, plus once at startup so a session that's already
# in a bad state when the game scene loads still shows the warning.
#
# Buttplug has three distinct states the banner distinguishes:
#   • Intiface itself is not connected → reconnect Intiface in Options.
#   • Intiface connected but no device available → the device has dropped
#     (battery, Bluetooth, USB unplug). Power it on / re-pair it.
#   • The user has a specific device selected from a prior session, that
#     device isn't present, BUT a different device IS — commands are silently
#     going to the fallback device. Tell the user about the mismatch so they
#     either connect their preferred device or update their selection.
# Serial has only one failure mode (port closed) — message stays simple.
#
# Hidden when: the selected backend has a device AND either the user has no
# specific preference (selected_device is empty) or the selected one is
# present.
func _refresh_device_warning() -> void:
	if _device_warning_banner == null:
		return
	var mode: String = SettingsService.get_output_mode()
	var disconnected: bool = false
	var label_text: String = ""
	if mode == "serial":
		disconnected = not SerialDeviceService.SerialConnected
		label_text   = "●  SERIAL DEVICE DISCONNECTED  —  RECONNECT IN OPTIONS"
	else:
		if not ButtplugService.BpConnected:
			disconnected = true
			label_text   = "●  INTIFACE DISCONNECTED  —  RECONNECT IN OPTIONS"
		else:
			var selected_name: String = SettingsService.get_selected_device()
			var active_name: String   = ButtplugService.GetActiveDeviceName()
			if active_name == "":
				disconnected = true
				label_text   = "●  NO DEVICE CONNECTED  —  POWER ON OR RE-PAIR YOUR DEVICE"
			elif selected_name != "" and selected_name != active_name:
				# User has an explicit preference that isn't currently present.
				# Playback still works via the fallback to active_name; the
				# banner just tells the user it's not the device they picked.
				disconnected = true
				label_text   = "●  \"%s\" UNAVAILABLE  —  USING \"%s\" INSTEAD  (CHANGE IN OPTIONS)" % [
					selected_name.to_upper(), active_name.to_upper(),
				]
	if disconnected:
		_device_warning_label.text = label_text
	_device_warning_banner.visible = disconnected


# ---------------------------------------------------------------------------
# Inventory / coins / effect chips
# ---------------------------------------------------------------------------

func _on_inventory_pressed() -> void:
	if is_instance_valid(_inventory_panel):
		_inventory_panel.close()
		return
	_inventory_panel = InventoryPanelScene.instantiate()
	_inventory_panel.closed.connect(_on_inventory_closed)
	add_child(_inventory_panel)


func _on_inventory_closed() -> void:
	_inventory_panel = null


func _on_coin_balance_changed(_balance: int) -> void:
	_refresh_coin_label()


func _refresh_coin_label() -> void:
	_coin_lbl.text = "♦ %d" % CoinService.Balance


func _refresh_effect_chips() -> void:
	for child in _chips_row.get_children():
		child.queue_free()
	var has_blackout: bool = false
	for effect: Dictionary in InventoryService.GetActiveEffects():
		_chips_row.add_child(_make_chip(effect))
		if effect.get("kind", "") == "blackout":
			has_blackout = true
	_video.visible = not has_blackout


func _make_chip(effect: Dictionary) -> Control:
	# Boss forced modifiers get a red chip; player-activated effects stay amber.
	var accent: Color = UITheme.DANGER if effect.get("boss", false) else UITheme.AMBER
	var chip: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color            = Color(accent.r, accent.g, accent.b, 0.12)
	s.border_color        = accent
	s.border_width_left   = 1
	s.border_width_right  = 1
	s.border_width_top    = 1
	s.border_width_bottom = 1
	s.content_margin_left   = 10
	s.content_margin_right  = 10
	s.content_margin_top    = 4
	s.content_margin_bottom = 4
	chip.add_theme_stylebox_override("panel", s)

	var lbl: Label = Label.new()
	lbl.add_theme_color_override("font_color", accent)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.set_meta("effect_id", effect.get("id", ""))
	_update_chip_text(lbl, effect)
	chip.add_child(lbl)
	chip.set_meta("chip_label", lbl)
	return chip


func _update_chip_text(lbl: Label, effect: Dictionary) -> void:
	var name_str: String = (effect.get("name", "") as String).to_upper()
	# Boss forced modifiers last the whole round — no countdown.
	if effect.get("boss", false):
		lbl.text = name_str
		return
	var remaining: float = InventoryService.GetRemainingSeconds(effect)
	lbl.text = "%s  %ds" % [name_str, int(ceil(remaining))]


func _update_chip_countdowns() -> void:
	var effects: Array = InventoryService.GetActiveEffects()
	if effects.size() != _chips_row.get_child_count():
		_refresh_effect_chips()
		return
	for i in effects.size():
		var chip: Node = _chips_row.get_child(i)
		var lbl: Label = chip.get_meta("chip_label", null)
		if lbl != null:
			_update_chip_text(lbl, effects[i])


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right  = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left   = 0
	_bg.offset_top    = 0
	_bg.offset_right  = 0
	_bg.offset_bottom = 0

	_video.anchor_left   = 0.0
	_video.anchor_top    = 0.0
	_video.anchor_right  = 0.0
	_video.anchor_bottom = 0.0
	_video.offset_left   = 0
	_video.offset_top    = 0
	_video.offset_right  = 0
	_video.offset_bottom = 0
	_video.position      = Vector2.ZERO
	_video.size          = get_viewport_rect().size

	_hud.anchor_right  = 1.0
	_hud.anchor_bottom = 1.0

	_hud_bar.anchor_left   = 0.0
	_hud_bar.anchor_right  = 1.0
	_hud_bar.anchor_top    = 1.0
	_hud_bar.anchor_bottom = 1.0
	_hud_bar.offset_top    = -HUD_BAR_HEIGHT
	_hud_bar.offset_bottom = 0

	_hud_layout.add_theme_constant_override("separation", 16)
	_round_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Progress bar — centered thin strip at the very bottom of the screen
	_progress.anchor_left   = 0.1
	_progress.anchor_right  = 0.9
	_progress.anchor_top    = 1.0
	_progress.anchor_bottom = 1.0
	_progress.offset_left   = 0
	_progress.offset_right  = 0
	_progress.offset_top    = -7
	_progress.offset_bottom = -1

	# Effect chips — row pinned just above the progress bar, centred.
	_chips_row.anchor_left   = 0.0
	_chips_row.anchor_right  = 1.0
	_chips_row.anchor_top    = 1.0
	_chips_row.anchor_bottom = 1.0
	_chips_row.offset_top    = -42
	_chips_row.offset_bottom = -12
	_chips_row.alignment     = BoxContainer.ALIGNMENT_CENTER
	_chips_row.add_theme_constant_override("separation", 8)
	_chips_row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Device-disconnected banner — pinned to the top edge of the viewport,
	# centred horizontally, hidden by default. Lives outside _hud so the
	# auto-hide timer doesn't fade it away.
	_device_warning_banner = PanelContainer.new()
	_device_warning_banner.anchor_left   = 0.5
	_device_warning_banner.anchor_right  = 0.5
	_device_warning_banner.anchor_top    = 0.0
	_device_warning_banner.anchor_bottom = 0.0
	_device_warning_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_device_warning_banner.offset_top    = 12
	_device_warning_banner.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_device_warning_banner.visible       = false
	add_child(_device_warning_banner)

	var banner_style: StyleBoxFlat = StyleBoxFlat.new()
	banner_style.bg_color              = Color(UITheme.ERROR_SOFT.r, UITheme.ERROR_SOFT.g, UITheme.ERROR_SOFT.b, 0.92)
	banner_style.border_color          = UITheme.ERROR_SOFT
	banner_style.border_width_left     = 2; banner_style.border_width_right  = 2
	banner_style.border_width_top      = 2; banner_style.border_width_bottom = 2
	banner_style.content_margin_left   = 18; banner_style.content_margin_right  = 18
	banner_style.content_margin_top    = 8;  banner_style.content_margin_bottom = 8
	banner_style.corner_radius_top_left     = 6; banner_style.corner_radius_top_right    = 6
	banner_style.corner_radius_bottom_left  = 6; banner_style.corner_radius_bottom_right = 6
	_device_warning_banner.add_theme_stylebox_override("panel", banner_style)

	_device_warning_label = Label.new()
	_device_warning_label.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	_device_warning_label.add_theme_font_size_override("font_size", 13)
	_device_warning_label.uppercase = true
	_device_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_device_warning_banner.add_child(_device_warning_label)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = UITheme.BG

	var bar_style: StyleBoxFlat = StyleBoxFlat.new()
	bar_style.bg_color            = UITheme.PANEL_BG_GAME
	bar_style.border_color        = UITheme.PURPLE_BRIGHT
	bar_style.border_width_top    = 1
	bar_style.content_margin_left  = 20
	bar_style.content_margin_right = 20
	bar_style.content_margin_top   = 14
	bar_style.content_margin_bottom = 14
	_hud_bar.add_theme_stylebox_override("panel", bar_style)

	_round_lbl.add_theme_color_override("font_color",    UITheme.WHITE_SOFT)
	_round_lbl.add_theme_font_size_override("font_size", 13)
	_round_lbl.uppercase = true

	_score_lbl.add_theme_color_override("font_color",    UITheme.MAGENTA)
	_score_lbl.add_theme_font_size_override("font_size", 13)
	_score_lbl.uppercase = true

	_coin_lbl.add_theme_color_override("font_color",    UITheme.AMBER)
	_coin_lbl.add_theme_font_size_override("font_size", 13)
	_coin_lbl.uppercase = true

	_style_progress()
	_style_button(_pause_btn,   UITheme.PURPLE_BRIGHT)
	_style_button(_inv_btn,     UITheme.AMBER)
	_style_button(_menu_btn,    UITheme.MAGENTA)
	_style_button(_options_btn, UITheme.PURPLE_MID)


func _style_button(btn: Button, accent: Color) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   UITheme.WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", UITheme.BG)
	btn.add_theme_font_size_override("font_size", 13)
	btn.text = btn.text.to_upper()

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color            = Color(accent.r, accent.g, accent.b, 0.12)
	s.border_color        = accent
	s.border_width_left   = 1
	s.border_width_right  = 1
	s.border_width_top    = 1
	s.border_width_bottom = 1
	s.content_margin_left   = 14
	s.content_margin_right  = 14
	s.content_margin_top    = 8
	s.content_margin_bottom = 8
	btn.add_theme_stylebox_override("normal", s)

	var s_hover: StyleBoxFlat = s.duplicate()
	s_hover.bg_color = Color(accent.r, accent.g, accent.b, 0.32)
	btn.add_theme_stylebox_override("hover", s_hover)

	var s_pressed: StyleBoxFlat = s.duplicate()
	s_pressed.bg_color = accent
	btn.add_theme_stylebox_override("pressed", s_pressed)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _style_progress() -> void:
	var bg: StyleBoxFlat = StyleBoxFlat.new()
	bg.bg_color                  = Color(0.08, 0.0, 0.12, 0.8)
	bg.corner_radius_top_left    = 4
	bg.corner_radius_top_right   = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4

	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color                  = UITheme.PURPLE_BRIGHT
	fill.corner_radius_top_left    = 4
	fill.corner_radius_top_right   = 4
	fill.corner_radius_bottom_left = 4
	fill.corner_radius_bottom_right = 4

	_progress.add_theme_stylebox_override("background", bg)
	_progress.add_theme_stylebox_override("fill", fill)
	_progress.min_value      = 0.0
	_progress.max_value      = 1.0
	_progress.show_percentage = false
