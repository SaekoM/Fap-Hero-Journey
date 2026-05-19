extends Control

const OptionsScene        = preload("res://scenes/options/Options.tscn")
const ForkScene           = preload("res://scenes/fork_screen/ForkScreen.tscn")
const ShopScene           = preload("res://scenes/shop_screen/ShopScreen.tscn")
const InventoryPanelScene = preload("res://scenes/inventory/InventoryPanel.tscn")

# ---------------------------------------------------------------------------
# GameLoop.gd  –  Round controller and video player
# Reads the active journey from GameState, loads each round's video and
# funscript in sequence, then transitions to EndScreen when all rounds finish.
#
# MP4 NOTE: Godot's built-in VideoStreamPlayer only decodes .ogv (Theora).
# Install EIRTeam.FFmpeg GDExtension for MP4 support, then replace the
# _load_video() body with that extension's API.
# ---------------------------------------------------------------------------

const COLOR_BG:           Color = Color(0.0,   0.0,   0.0,   1.0)
const COLOR_PANEL_BG:     Color = Color(0.055, 0.008, 0.086, 0.88)
const COLOR_PURPLE_BRIGHT:Color = Color(0.698, 0.118, 1.0,   1.0)
const COLOR_PURPLE_MID:   Color = Color(0.408, 0.063, 0.627, 1.0)
const COLOR_MAGENTA:      Color = Color(0.878, 0.0,   0.878, 1.0)
const COLOR_WHITE_SOFT:   Color = Color(0.878, 0.780, 1.0,   1.0)
const COLOR_AMBER:        Color = Color(1.0,   0.65,  0.15,  1.0)
const COLOR_TOXIC_GREEN:  Color = Color(0.45,  1.0,   0.35,  1.0)
const COLOR_BG_ZERO:      Color = Color(0.0,   0.0,   0.0,   0.0)

const HUD_BAR_HEIGHT:  int   = 68
const HUD_HIDE_DELAY:  float = 3.0
const VIDEO_EXTS:      Array = ["mp4", "mkv", "webm", "avi", "mov", "ogv"]

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
@onready var _end_timer:   Timer             = $EndTimer

var _paused: bool = false
var _inventory_panel: Control = null


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_connect_signals()
	ScoreService.Reset()
	CoinService.Reset()
	InventoryService.Reset()
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
	_update_chip_countdowns()


# ---------------------------------------------------------------------------
# Item loading (round or fork)
# ---------------------------------------------------------------------------

func _load_current_item() -> void:
	match GameState.CurrentItemType():
		"fork":
			_show_fork_screen(GameState.CurrentFork())
		"shop":
			_show_shop_screen(GameState.CurrentShop())
		_:
			_load_current_round()


func _show_shop_screen(shop_data: Dictionary) -> void:
	_video.paused = true
	FunscriptPlayer.Pause()
	var shop: Control = ShopScene.instantiate()
	shop.closed.connect(_on_shop_closed)
	add_child(shop)
	shop.setup(shop_data)


func _on_shop_closed() -> void:
	_video.paused = false
	FunscriptPlayer.Resume()
	GameState.Advance()
	if GameState.IsSequenceDone():
		Transition.change_scene("res://scenes/end_screen/EndScreen.tscn")
	else:
		_load_current_item()


func _show_fork_screen(fork_data: Dictionary) -> void:
	_video.paused = true
	FunscriptPlayer.Pause()
	var fork_screen = ForkScene.instantiate()
	fork_screen.path_chosen.connect(_on_fork_path_chosen)
	add_child(fork_screen)
	fork_screen.setup(fork_data)


func _on_fork_path_chosen(path_index: int) -> void:
	GameState.ResolveFork(path_index)
	_video.paused = false
	FunscriptPlayer.Resume()
	_load_current_round()


func _load_current_round() -> void:
	var round: Dictionary = GameState.CurrentRound()
	if round.is_empty():
		push_error("GameLoop: GameState has no current round — returning to menu")
		_go_to_menu()
		return

	var total: int = GameState.TotalRounds()
	var num:   int = GameState.RoundNumber
	_round_lbl.text = "ROUND %d / %d  —  %s" % [num, total,
		(round.get("name", "") as String).to_upper()]

	_progress.value = 0.0
	_paused = false
	_pause_btn.text = "|| PAUSE"

	ScoreService.StartRound()

	var fs_path: String = round.get("funscript_path", "")
	if fs_path != "":
		FunscriptPlayer.LoadFunscript(fs_path)
		ScoreService.SetRoundActions(FunscriptPlayer.ActionCount)

	var folder: String = round.get("folder", "")
	var video_path: String = _find_video(folder)
	_load_video(video_path)


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
	if ClassDB.class_exists("FFmpegVideoStream"):
		var stream: Resource = ClassDB.instantiate("FFmpegVideoStream")
		stream.set("file", ProjectSettings.globalize_path(path))
		_video.stream = stream as VideoStream
		_video.play()
		FunscriptPlayer.Play()
	else:
		push_warning("GameLoop: FFmpegVideoStream not found — install EIRTeam.FFmpeg for MP4 support. Running funscript-only.")
		_start_no_video_fallback()


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
	ScoreService.EndRound()
	FunscriptPlayer.Stop()

	var coins: int = GameState.CurrentRound().get("coins", 0)
	if coins > 0:
		CoinService.AddCoins(coins)

	if GameState.IsLastRound():
		Transition.change_scene("res://scenes/end_screen/EndScreen.tscn")
	else:
		GameState.Advance()
		_load_current_item()


func _go_to_menu() -> void:
	_video.stop()
	FunscriptPlayer.Stop()
	Transition.change_scene("res://scenes/main/Main.tscn")


func _on_options_pressed() -> void:
	_video.paused = true
	FunscriptPlayer.Pause()
	var opts: Control = OptionsScene.instantiate()
	opts.overlay_mode = true
	opts.tree_exiting.connect(_on_options_closed)
	add_child(opts)


func _on_options_closed() -> void:
	if not _paused:
		_video.paused = false
		FunscriptPlayer.Resume()


# ---------------------------------------------------------------------------
# Pause / HUD
# ---------------------------------------------------------------------------

func _toggle_pause() -> void:
	_paused = not _paused
	_video.paused = _paused
	if _paused:
		FunscriptPlayer.Pause()
		_pause_btn.text = "> RESUME"
	else:
		FunscriptPlayer.Resume()
		_pause_btn.text = "|| PAUSE"


func _show_hud() -> void:
	_hud.modulate = Color(1, 1, 1, 1)
	_hud.visible  = true
	_hide_timer.start(HUD_HIDE_DELAY)


func _on_hide_timer_timeout() -> void:
	_hud.visible = false


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton \
			or event is InputEventKey:
		_show_hud()
	if event.is_action_pressed("ui_cancel"):
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
	for effect: Dictionary in InventoryService.GetActiveEffects():
		_chips_row.add_child(_make_chip(effect))


func _make_chip(effect: Dictionary) -> Control:
	var chip: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color            = Color(COLOR_AMBER.r, COLOR_AMBER.g, COLOR_AMBER.b, 0.12)
	s.border_color        = COLOR_AMBER
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
	lbl.add_theme_color_override("font_color", COLOR_AMBER)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.set_meta("effect_id", effect.get("id", ""))
	_update_chip_text(lbl, effect)
	chip.add_child(lbl)
	chip.set_meta("chip_label", lbl)
	return chip


func _update_chip_text(lbl: Label, effect: Dictionary) -> void:
	var name_str: String = (effect.get("name", "") as String).to_upper()
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

	_video.anchor_right  = 1.0
	_video.anchor_bottom = 1.0
	_video.offset_left   = 0
	_video.offset_top    = 0
	_video.offset_right  = 0
	_video.offset_bottom = 0

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


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = COLOR_BG

	var bar_style: StyleBoxFlat = StyleBoxFlat.new()
	bar_style.bg_color            = COLOR_PANEL_BG
	bar_style.border_color        = COLOR_PURPLE_BRIGHT
	bar_style.border_width_top    = 1
	bar_style.content_margin_left  = 20
	bar_style.content_margin_right = 20
	bar_style.content_margin_top   = 14
	bar_style.content_margin_bottom = 14
	_hud_bar.add_theme_stylebox_override("panel", bar_style)

	_round_lbl.add_theme_color_override("font_color",    COLOR_WHITE_SOFT)
	_round_lbl.add_theme_font_size_override("font_size", 13)
	_round_lbl.uppercase = true

	_score_lbl.add_theme_color_override("font_color",    COLOR_MAGENTA)
	_score_lbl.add_theme_font_size_override("font_size", 13)
	_score_lbl.uppercase = true

	_coin_lbl.add_theme_color_override("font_color",    COLOR_AMBER)
	_coin_lbl.add_theme_font_size_override("font_size", 13)
	_coin_lbl.uppercase = true

	_style_progress()
	_style_button(_pause_btn,   COLOR_PURPLE_BRIGHT)
	_style_button(_inv_btn,     COLOR_AMBER)
	_style_button(_menu_btn,    COLOR_MAGENTA)
	_style_button(_options_btn, COLOR_PURPLE_MID)


func _style_button(btn: Button, accent: Color) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   COLOR_WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", COLOR_BG)
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
	fill.bg_color                  = COLOR_PURPLE_BRIGHT
	fill.corner_radius_top_left    = 4
	fill.corner_radius_top_right   = 4
	fill.corner_radius_bottom_left = 4
	fill.corner_radius_bottom_right = 4

	_progress.add_theme_stylebox_override("background", bg)
	_progress.add_theme_stylebox_override("fill", fill)
	_progress.min_value      = 0.0
	_progress.max_value      = 1.0
	_progress.show_percentage = false
