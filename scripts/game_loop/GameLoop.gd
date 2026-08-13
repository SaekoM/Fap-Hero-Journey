extends Control

const OptionsScene = preload("res://scenes/options/Options.tscn")
const ForkScene = preload("res://scenes/fork_screen/ForkScreen.tscn")
const ShopScene = preload("res://scenes/shop_screen/ShopScreen.tscn")
const StoryboardScene = preload("res://scenes/storyboard_screen/StoryboardScreen.tscn")
const InventoryPanelScene = preload("res://scenes/inventory/InventoryPanel.tscn")
const GraphViewScene = preload("res://scenes/graph_view/GraphView.tscn")

# ---------------------------------------------------------------------------
# GameLoop.gd  –  Round controller and video player
# Reads the active journey from GameState, loads each round's video and
# funscript in sequence, then transitions to EndScreen when all rounds finish.
#
# MP4 NOTE: Godot's built-in VideoStreamPlayer only decodes .ogv (Theora).
# Install EIRTeam.FFmpeg GDExtension for MP4 support, then replace the
# _load_video() body with that extension's API.
# ---------------------------------------------------------------------------

const HUD_BAR_HEIGHT: int = 68
# Minimum real cursor travel (px) for a mouse-motion event to count as "activity"
# that reveals the HUD / cursor. Windows and some touchpads emit phantom
# InputEventMouseMotion events with (near-)zero relative movement even when nothing
# is touched — those used to pop the HUD in at random during playback. Any deliberate
# movement is well above this; raise it if a jittery touchpad still triggers reveals.
const MOUSE_MOTION_DEADZONE_PX: float = 1.0
# Playback-capable formats. Intentionally distinct from JourneyData.VIDEO_EXTENSIONS
# (the import/transcode set): includes "ogv" (Godot-native, no FFmpeg needed) and
# omits container types that only matter at import time.
const VIDEO_EXTS: Array = ["mp4", "mkv", "webm", "avi", "mov", "ogv"]

# Sequence-boundary fade timings (~1.2s total).
const TRANSITION_FADE_TIME: float = 0.45
const TRANSITION_HOLD_TIME: float = 0.30

# Boss rounds: the red frame pulses during the round's final stretch.
const BOSS_CLIMAX_SECS: float = 30.0
# Boss forced-modifier kind → HUD chip label.
const BOSS_EFFECT_NAMES: Dictionary = {
	"scale": "SCALE",
	"clamp": "CLAMP",
	"reverse": "REVERSE",
	"blackout": "BLACKOUT",
	"score_multiplier": "SCORE ×",
}

@onready var _bg: ColorRect = $Background
@onready var _video: VideoStreamPlayer = $VideoPlayer
@onready var _hud: Control = $HUD
@onready var _hud_bar: PanelContainer = $HUD/HUDBar
@onready var _hud_layout: HBoxContainer = $HUD/HUDBar/HUDLayout
@onready var _round_lbl: Label = $HUD/HUDBar/HUDLayout/RoundLabel
@onready var _coin_lbl: Label = $HUD/HUDBar/HUDLayout/CoinLabel
@onready var _progress: ProgressBar = $HUD/ProgressBar
@onready var _score_lbl: Label = $HUD/HUDBar/HUDLayout/ScoreLabel
# Round timer (opt-in, Options → Display). Built in code and added to the HUD bar, so it hides
# with the rest of the HUD when a Fog effect conceals it.
var _timer_lbl: Label = null
@onready var _pause_btn: Button = $HUD/HUDBar/HUDLayout/PauseBtn
@onready var _inv_btn: Button = $HUD/HUDBar/HUDLayout/InventoryBtn
@onready var _menu_btn: Button = $HUD/HUDBar/HUDLayout/MenuBtn
@onready var _options_btn: Button = $HUD/HUDBar/HUDLayout/OptionsBtn
@onready var _chips_row: HBoxContainer = $HUD/EffectChipsRow
@onready var _hide_timer: Timer = $HUD/HideTimer

# In-play "Quick Settings" drawer (stroke range + delay), toggled by the S key and mutually exclusive
# with the inventory drawer. Arrow keys nudge the range while it's open. STROKE_RANGE_STEP = per press.
var _session_panel: Control = null
const STROKE_RANGE_STEP: int = 5

# Persistent banner shown at top of screen whenever the *currently selected*
# output device drops its connection during play. Built dynamically in
# _apply_layout so the scene file doesn't need a new node. Lives outside the
# auto-hiding HUD so it stays visible even when the rest of the HUD fades.
var _device_warning_banner: PanelContainer = null
var _device_warning_label: Label = null
var _device_ever_seen: bool = false  # a device was present at some point this run (Slice 6 warning gate)

const DELAY_STEP: int = 10  # [ ] ; ' nudge the per-backend delays by this many ms
var _delay_toast: Label = null  # transient "delay X ms" feedback for the delay hotkeys
var _delay_toast_tween: Tween = null
@onready var _end_timer: Timer = $EndTimer
@onready var _transition: ColorRect = $TransitionLayer/TransitionOverlay

var _paused: bool = false
var _inventory_panel: Control = null

# Pause penalty — score drains while the player has *actively* paused (the pause
# button or the Options menu). System pauses (boss intro, checkpoint banner,
# shops/forks/storyboards) don't count. _options_open tracks the Options overlay
# since it pauses without setting _paused.
const PAUSE_PENALTY_PER_SEC: int = 10
var _options_open: bool = false
var _pause_penalty_accum: float = 0.0

# True while a full-screen overlay (shop / fork / storyboard) is active.
# Used to suppress gameplay hotkeys that should not fire through an overlay.
var _is_overlay_open: bool = false
# The current full-screen overlay (storyboard / shop / fork), or null. It is
# freed by the transition (after the black covers it), not by itself — see
# _transition_swap.
var _current_overlay: Control = null

# Journey map (read-only GraphView of the authored graph + "you are here" marker).
# Opened on demand (HUD button / M / overlay buttons). Self-managed (NOT
# _current_overlay, which the transition frees). Availability is authored per
# journey (_map_enabled): an author can disable it to enforce surprise, in which
# case the map is never built and the buttons never appear.
var _map_enabled: bool = true  # journey-level: author allows the player map
var _show_fork_counts: bool = true  # journey-level: show the "N ROUNDS" tag on fork choices
var _show_loops_on_map: bool = false  # journey-level: show Loop markers on the player map (off = hide)
# Finish ("I came") — journey-level opt-in. When on, an always-available hold-to-confirm button ends the
# run early; if a finish node (any type — a gentle round or a storyboard) is designated it plays as
# aftercare before the end screen.
var _allow_finish: bool = false
var _finish_node_id: String = ""
# Auto-advance (journey-level opt-in): a countdown on storyboards (per line) and interactive forks
# so a player can't linger to "rest". Separate durations — a dialogue line needs far less time than a
# fork decision. Passed to those overlays; 0 secs = off (either the feature or that surface).
var _auto_advance_enabled: bool = false
var _auto_advance_storyboard_secs: int = 20
var _auto_advance_fork_secs: int = 45
# Counter names the author surfaced to the player (journey-level "ShownCounters"). A change to one
# of these shows the transient top-right pop; the inventory panel lists them. Others stay hidden.
var _shown_counters: Array = []
# Occupied vertical slots for counter pops (index -> true) so simultaneous pops stack rather than
# overlap. See _alloc_counter_pop_slot.
var _counter_pop_slots: Dictionary = {}
const COUNTER_POP_BASE_Y: float = 90.0  # first pop sits below the HUD bar
const COUNTER_POP_STEP: float = 46.0  # one single-row pop's height + gap
const COUNTER_POP_HOLD_SECS: float = 3.5  # how long a coin/item/counter chip stays fully on screen
var _map_fog: bool = false  # journey-level: fog of war — reveal the map as it's discovered
var _map_fog_reveal: int = 1  # ghost levels revealed ahead of the trail (< 0 = whole structure)
var _map_view: GraphView = null
var _map_overlay: Control = null  # full-screen host (backdrop + map + chrome)
var _map_close_btn: Button = null
var _map_open: bool = false
# True while the active full-screen overlay permits opening the journey map over it
# (shop, storyboard, and INTERACTIVE forks). Lets the map open even though
# _is_overlay_open is set. Auto-resolving forks (random / conditional) leave it false
# so the map can't interrupt their reveal; transient banners (checkpoint / reveal
# card) never set it. While the map is open the overlay's own input is suspended (see
# _set_overlay_input_enabled) so clicks/keys can't leak through to it.
var _overlay_map_allowed: bool = false

# True for the duration of a boss round (set when the round loads, cleared at
# round end). Drives item lockout, the red frame, and the climax pulse.
var _is_boss_round: bool = false
# Pool ("encounter") round: set when a picked entry still owes its mystery reveal card. The
# card is played in _start_round_after_gates (before any boss intro), not in _begin_round, so
# a rolled boss stays a surprise until the card slides away.
var _pending_encounter_card: bool = false
var _boss_frame: Panel = null

# Cursed round: random negative effect(s) rolled at the start. Distinct from a
# boss round — items stay usable (the player can fight back), it hits mid-flow
# with no telegraph, and it has its own sickly "hex" identity (see below). Set
# when the round loads, cleared at round end.
# Effect round — the unified "twist" round (replaces the retired cursed/blessed
# types). Applies a mix of gameplay effects (hindrances and/or boons, from
# CURSE_CATALOG + BLESSING_CATALOG) plus an optional always-on sensory layer
# (SENSORY_CATALOG), framed by author-set visuals (border/accent colour, header, icon),
# with an optional "resolvable" layer (pay to cleanse / endure for a reward). Stroke
# effects are applied by
# FunscriptPlayer; the rest (coin/hud/sensory/boon behaviours) by GameLoop. All go
# into the boss-effects list so they surface as named HUD chips and lift together on
# cleanse. Set when the round loads, cleared at round end.
var _is_effect_round: bool = false
var _effect_resolvable: bool = false  # the round carries the cleanse/endure layer
# Effective length (ms) of the round currently playing. For a pool round this is
# the CHOSEN entry's length, not the round's own (empty) length_ms — read by the
# no-video timer and the play log so the end-screen recap shows the right duration.
var _active_round_length_ms: int = 0

# Chance a *random* effect round rolls TWO effects instead of one.
const DOUBLE_EFFECT_CHANCE: float = 0.22
const CLEANSE_COST_DEFAULT: int = 50

var _effect_frame: Panel = null  # optional coloured edge border (author-toggled per round)
# The non-gameplay (visual/audio) modifier engine — overlays, video shader,
# audio bus, tremor, mute. Built in _build_effect_overlay; every hex routes
# through it first (see _apply_hex). Gameplay hexes below stay here.
var _sensory: SensoryFX = null
# This round's own sensory layer as [{roll, intensity}] — collected in _apply_hex, combined with any
# active ITEM sensory effects, and pushed to SensoryFX.reconcile by _reconcile_sensory. Cleared at
# round entry (rebuilt) and at round teardown (so the round's sensory fades out; item sensory stays).
var _round_sensory: Array = []
# Guards _apply_oneshot_item_effects against the re-entrant ActiveEffectsChanged that ConsumeEffects
# emits (so a one-shot toll/interest/flag/counter fires exactly once, not once per consume).
var _applying_oneshots: bool = false
var _curse_hud_hidden: bool = false  # a "Fog" effect hid the HUD (round OR timed item), reconciled
var _curse_no_pause: bool = false  # a "Restless" effect disabled pausing this round
const TOLL_AMOUNT: int = 40  # coins a "Toll" effect takes immediately

var _effect_lingering: bool = false  # a "Lingering" boon froze the effect clock
const INTEREST_PCT: float = 0.25  # "Interest" boon pays this fraction of the coin balance
# Effects to show on the pre-round reveal card. Each: {name, desc, benefit:bool}.
# Empty = no card (normal/boss rounds).
var _reveal_effects: Array = []
var _resumed_from_save: bool = false  # true until the first item loads after a resume
const REVEAL_HOLD_SECS: float = 2.6
# Pool-round "ENCOUNTER!" card hold — punchier than the effect reveal (a mystery
# beat, not a modifier to read).
const ENCOUNTER_HOLD_SECS: float = 1.2
# Cleanse / endure decision (only when the round is resolvable): pay to lift the
# effects mid-round, or endure to the end for the round's endure_reward bonus. Its
# own floating button (not in the HUD, so a Fog effect can't lock the player out).
var _effect_resolved: bool = false
var _effect_cleanse_btn: Button = null
var _warmup_skip_btn: Button = null  # free ⏭ skip on an author-marked warmup round
var _finish_btn: Button = null  # hold-to-confirm FINISH ("I came") button, shown during rounds when enabled
var _finish_hold_tween: Tween = null  # fills while FINISH is held; fires _finish_journey at completion
var _finishing: bool = false  # set once FINISH is confirmed, so a late button_up can't re-trigger
# Exit-to-menu is hold-to-confirm (Esc key held, or the MENU button held) so a stray press can't dump a
# run. A centered overlay fills while held; release cancels, completion leaves to the menu.
const EXIT_HOLD_SECS: float = 1.0
var _exit_hold_tween: Tween = null
var _exit_hold_layer: CanvasLayer = null
var _exit_hold_fill: Label = null
var _exiting: bool = false  # guards _confirm_exit so a late key/button-up can't re-trigger
# _on_round_ended is bound to BOTH round-end signals (_video.finished / _end_timer.timeout) and is
# also called manually (FINISH / warmup skip). This guards its once-per-round side effects — counter
# bestowal, payout, advance — against a double-fire. Reset at the top of each _begin_round.
var _round_ended_guard: bool = false
const FINISH_HOLD_SECS: float = 1.2  # hold time to confirm FINISH
var _effect_cleanse_cost: int = CLEANSE_COST_DEFAULT  # per-round, set on enter

# Optional beat-bar visualiser — created only when the setting is enabled.
var _beat_bar: Control = null

# Test-play mode: the journey was launched from the builder ("Save & Test from
# here") to preview a node in the real runtime. While true, the loop returns to
# the builder (not the menu/end screen) on exit, and real player saves are
# suppressed so a preview never writes or deletes a journey's run-save. The
# return journey is the catalogue-model dict the builder reloads on the way back.
var _test_mode: bool = false
var _test_return_journey: Dictionary = {}
# Seeds applied before the first node loads in a test play, so Conditional /
# Sacrifice forks can be exercised from a chosen starting point.
var _test_seed_score: int = 0
var _test_seed_coins: int = 0
var _test_seed_flags: Array = []
# Set once this run's outcome has been logged to the scoreboard (on completion)
# or when leaving via Save & Quit (a resume, not an abandon) — so the menu exit
# doesn't also record an abandoned run.
var _run_accounted: bool = false


func _ready() -> void:
	MusicService.stop()
	_apply_layout()
	_apply_theme()
	_build_boss_frame()
	_build_effect_overlay()
	_build_beat_bar()
	# Journey-level: the author can disable the player map to enforce surprise.
	_map_enabled = bool(GameState.Journey.get("map_enabled", true))
	_show_fork_counts = bool(GameState.Journey.get("show_fork_counts", true))
	_show_loops_on_map = bool(GameState.Journey.get("show_loops_on_map", false))
	_map_fog = bool(GameState.Journey.get("map_fog", false))
	# Journey-level: auto-advance countdown on storyboards / interactive forks.
	_allow_finish = bool(GameState.Journey.get("allow_finish", false))
	_finish_node_id = str(GameState.Journey.get("finish_node", ""))
	_auto_advance_enabled = bool(GameState.Journey.get("auto_advance_enabled", false))
	_auto_advance_storyboard_secs = int(GameState.Journey.get("auto_advance_storyboard_secs", 20))
	_auto_advance_fork_secs = int(GameState.Journey.get("auto_advance_fork_secs", 45))
	_map_fog_reveal = int(GameState.Journey.get("map_fog_reveal", 1))
	_shown_counters = (GameState.Journey.get("shown_counters", []) as Array)
	_build_map()
	_connect_signals()
	# Resume vs fresh start: when the player picked Resume from the catalogue,
	# JourneySelect already populated the run-state autoloads (coins, score,
	# inventory) from the save record and stashed _round_names on GameState.
	# Wiping them here would defeat the resume. The "_resuming" meta is the
	# handshake — JourneySelect sets it before the scene change, we honour
	# it once, then clear it so a subsequent play of the same journey from
	# this session doesn't pick it up by accident.
	# Test-play handshake — the builder sets these metas before the scene change.
	# Read once and clear so a later normal run of the same journey can't inherit
	# test mode by accident (same pattern as the "_resuming" handshake below).
	_test_mode = bool(GameState.get_meta("_test_mode", false))
	if _test_mode:
		_test_return_journey = GameState.get_meta("_test_return_journey", {})
		_test_seed_score = int(GameState.get_meta("_test_seed_score", 0))
		_test_seed_coins = int(GameState.get_meta("_test_seed_coins", 0))
		_test_seed_flags = GameState.get_meta("_test_seed_flags", [])
		GameState.remove_meta("_test_mode")
		GameState.remove_meta("_test_return_journey")
		GameState.remove_meta("_test_seed_score")
		GameState.remove_meta("_test_seed_coins")
		GameState.remove_meta("_test_seed_flags")

	# Author-defined journey items — load into the inventory registry every run (fresh OR resumed),
	# since they're journey definitions, not run-state. Before Reset so a fresh run's registry is
	# populated when the first grant happens.
	InventoryService.LoadJourneyItems(GameState.Journey.get("items", []))

	var is_resuming: bool = bool(GameState.get_meta("_resuming", false))
	# A run resumed from a checkpoint save should skip that checkpoint's banner and go straight
	# on — the player already chose to stop there once. Consumed by the first _load_current_item.
	_resumed_from_save = is_resuming
	if is_resuming:
		GameState.remove_meta("_resuming")
	else:
		ScoreService.Reset()
		CoinService.Reset()
		InventoryService.Reset()
		# Pure-GDScript round-name log, read by EndScreen. Stored as meta on
		# GameState so it survives the scene change. Cleared here so a new
		# journey starts fresh.
		GameState.set_meta("_round_names", PackedStringArray())
		# Route trail (node ids in visit order) — drives the end-screen route
		# recap. Same meta pattern; restored from the save record on resume.
		GameState.set_meta("_route_trail", [])
	# Apply test-play seeds after the run-state reset above (so they survive it),
	# before any node loads — a Conditional fork at the start node then sees them.
	if _test_mode:
		if _test_seed_coins > 0:
			CoinService.SetBalance(_test_seed_coins)
		if _test_seed_score > 0:
			ScoreService.SeedLastRoundScore(_test_seed_score)
		if not _test_seed_flags.is_empty():
			GameState.SeedFlags(_test_seed_flags)
	_build_round_timer()
	_refresh_coin_label(true)
	# Handy WiFi only: sync the device ONCE before the first round (behind a brief overlay) so round 1 isn't
	# the one that eats the ~9-call handshake, and so you can see + feel it's ready before play. No-op for
	# every other stroker, in test mode, or when already connected.
	await _handy_journey_sync_gate()
	_load_current_item()
	_show_hud()
	if _test_mode:
		_show_test_banner()

	# Re-fit the video whenever the logical viewport changes. This fires on
	# window resize, fullscreen toggle, resolution change, AND UI-scale
	# (content_scale_factor) change — so the video tracks all of them, including
	# while paused.
	get_viewport().size_changed.connect(_fit_video_cover)


# Adds the round-timer label to the HUD bar, ahead of the buttons. Skipped entirely when the
# setting is off, so a disabled timer costs nothing per frame.
func _build_round_timer() -> void:
	if not SettingsService.get_round_timer_enabled():
		return
	_timer_lbl = Label.new()
	_timer_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	_timer_lbl.add_theme_font_size_override("font_size", 16)
	_hud_layout.add_child(_timer_lbl)
	_hud_layout.move_child(_timer_lbl, _score_lbl.get_index() + 1)
	_update_round_timer()


# Time LEFT in the round, which is what a player actually wants mid-round. Falls back to elapsed
# when the length is unknown (a funscript-only round with no stats, say) — counting up beats
# showing a wrong countdown.
func _update_round_timer(at_start: bool = false) -> void:
	if _timer_lbl == null:
		return
	# At a round start the video still holds the PREVIOUS clip's position (_load_video runs
	# later), so trust the length alone rather than flashing a wrong countdown for a frame.
	var elapsed_ms: int = 0 if at_start else int(_video.stream_position * 1000.0)
	var total_ms: int = _active_round_length_ms
	if total_ms > 0:
		_timer_lbl.text = "⏱ %s" % JourneyData.ms_to_mmss(maxi(0, total_ms - elapsed_ms))
	else:
		_timer_lbl.text = "⏱ %s" % JourneyData.ms_to_mmss(maxi(0, elapsed_ms))


func _process(delta: float) -> void:
	if _video.is_playing():
		var len: float = _video.get_stream_length()
		if len > 0.0:
			_progress.value = _video.stream_position / len
		# Re-fit every frame: cheap, and keeps the video covering the screen even
		# if the viewport or UI scale changes mid-playback.
		_fit_video_cover()
		if _override_session.is_active():
			_tick_override(delta)  # an override owns the device — drive its own clock, not the video's
		else:
			# Keep funscript in sync with the video clock (Handy tops up its HSP buffer too).
			FunscriptPlayer.SyncTo(_video.stream_position)
			_handy_feed()
	_apply_pause_penalty(delta)
	_update_chip_countdowns()
	if _is_boss_round:
		_update_boss_frame()
	elif _is_effect_round:
		_update_effect_frame()
	if _beat_bar != null:
		_beat_bar.set_time(FunscriptPlayer.PositionMs)
	_update_round_timer()


# Drains score while the player has actively paused (pause button or Options) —
# PAUSE_PENALTY_PER_SEC per whole second held. System pauses (boss intro,
# checkpoint banner, shops/forks/storyboards) don't set _paused / _options_open,
# so they're exempt. The accumulator resets the moment play resumes.
func _apply_pause_penalty(delta: float) -> void:
	if not (_paused or _options_open):
		_pause_penalty_accum = 0.0
		return
	_pause_penalty_accum += delta
	while _pause_penalty_accum >= 1.0:
		_pause_penalty_accum -= 1.0
		ScoreService.PenalizeScore(PAUSE_PENALTY_PER_SEC)


# ---------------------------------------------------------------------------
# Item loading (round or fork)
# ---------------------------------------------------------------------------


func _load_current_item() -> void:
	_record_trail_node()
	# Cleared on the FIRST item after a resume (whatever its type), so it only ever affects the
	# node the save landed on — a checkpoint there is skipped; later checkpoints show normally.
	var just_resumed: bool = _resumed_from_save
	_resumed_from_save = false
	match GameState.CurrentItemType():
		"fork":
			_show_fork_screen(GameState.CurrentFork())
		"shop":
			_show_shop_screen(GameState.CurrentShop())
		"storyboard":
			_show_storyboard_screen(GameState.CurrentStoryboard())
		"checkpoint":
			if just_resumed:
				_advance_from_checkpoint()  # resumed onto it → don't re-show its banner
			else:
				_show_checkpoint_gate()
		"loop_start":
			# The top marker of a Loop pair — a no-media passthrough. Advance into the body it precedes.
			GameState.Advance()
			_load_current_item()
		"loop_end":
			# The bottom marker: bump/evaluate the loop, then replay from the paired Start or take the exit.
			GameState.ResolveLoop()
			_load_current_item()
		_:
			_load_current_round()


# Appends the current node to the run's route trail (end-screen route recap).
# Consecutive duplicates are skipped — a resumed run re-enters its saved node.
func _record_trail_node() -> void:
	var node_id: String = GameState.CurrentNodeId()
	if node_id == "":
		return
	var trail: Array = GameState.get_meta("_route_trail", [])
	if not trail.is_empty() and str(trail[-1]) == node_id:
		return
	trail.append(node_id)
	GameState.set_meta("_route_trail", trail)


func _show_storyboard_screen(sb_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	# An overlay can open with no prior input (e.g. a shop right after a round), so
	# actively restore the cursor — it may have been hidden mid-playback.
	_set_cursor_hidden(false)
	_start_storyboard_filler()
	var storyboard: Control = StoryboardScene.instantiate()
	storyboard.show_map_button = _map_enabled
	storyboard.auto_advance_secs = _auto_advance_storyboard_secs if _auto_advance_enabled else 0
	storyboard.completed.connect(_on_storyboard_completed)
	storyboard.map_requested.connect(_open_map_viewer)
	add_child(storyboard)
	_current_overlay = storyboard
	_overlay_map_allowed = true
	storyboard.setup(sb_data)


func _start_storyboard_filler() -> void:
	if not SettingsService.get_filler_enabled():
		return
	FunscriptPlayer.StartFiller(
		SettingsService.get_filler_lo(),
		SettingsService.get_filler_hi(),
		SettingsService.get_filler_half_cycle_ms()
	)


func _on_storyboard_completed(coins: int) -> void:
	FunscriptPlayer.StopFiller()
	_is_overlay_open = false
	_overlay_map_allowed = false
	# Bestow the storyboard's counters at completion — the pop now fires as the overlay closes, so it
	# isn't buried under it the way an on-arrival pop was.
	GameState.ApplyCurrentNodeCounters()
	_grant_coins(coins)
	# Optional item reward — read before Advance() moves off the storyboard.
	_grant_item(str(GameState.CurrentStoryboard().get("item", "")))
	GameState.Advance()
	if GameState.IsSequenceDone():
		_transition_to_end_screen()
		return
	await _transition_swap(
		func() -> void:
			_video.paused = false
			FunscriptPlayer.Resume()
			_load_current_item()
	)


func _show_shop_screen(shop_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	# An overlay can open with no prior input (e.g. a shop right after a round), so
	# actively restore the cursor — it may have been hidden mid-playback.
	_set_cursor_hidden(false)
	var shop: Control = ShopScene.instantiate()
	shop.show_map_button = _map_enabled
	# Auto-advance also applies to shops (reuses the fork-decision duration — both are linger surfaces).
	shop.auto_advance_secs = _auto_advance_fork_secs if _auto_advance_enabled else 0
	shop.closed.connect(_on_shop_closed)
	shop.map_requested.connect(_open_map_viewer)
	add_child(shop)
	_current_overlay = shop
	_overlay_map_allowed = true
	shop.setup(shop_data)


func _on_shop_closed() -> void:
	_is_overlay_open = false
	_overlay_map_allowed = false
	GameState.ApplyCurrentNodeCounters()  # the shop's own set_counters, bestowed on close
	GameState.Advance()
	if GameState.IsSequenceDone():
		_transition_to_end_screen()
		return
	await _transition_swap(
		func() -> void:
			_video.paused = false
			FunscriptPlayer.Resume()
			_load_current_item()
	)


func _show_fork_screen(fork_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	# An overlay can open with no prior input (e.g. a shop right after a round), so
	# actively restore the cursor — it may have been hidden mid-playback.
	_set_cursor_hidden(false)
	var fork_screen = ForkScene.instantiate()
	fork_screen.show_map_button = _map_enabled
	fork_screen.show_round_counts = _show_fork_counts
	fork_screen.auto_advance_secs = _auto_advance_fork_secs if _auto_advance_enabled else 0
	fork_screen.path_chosen.connect(_on_fork_path_chosen)
	fork_screen.map_requested.connect(_open_map_viewer)
	add_child(fork_screen)
	_current_overlay = fork_screen
	fork_screen.setup(fork_data)

	# Auto-resolved fork types pick a path and play a reveal instead of waiting
	# for the player. (Sacrifice stays interactive — the player picks & pays.)
	var resolution: String = fork_data.get("resolution", "choice")
	# Conditional forks either auto-resolve (the game "spins" to the best match) or let the player pick
	# among the paths they've unlocked (cond_decider == "player") — the latter stays interactive.
	var auto_resolved: bool = (
		resolution == "random"
		or (resolution == "conditional" and fork_data.get("cond_decider", "game") != "player")
	)
	# Interactive forks let the player consult the journey map mid-decision; the auto-resolving reveals
	# run on timers, so the map stays suppressed there.
	_overlay_map_allowed = not auto_resolved
	match resolution:
		"random":
			fork_screen.reveal(_weighted_random_path(fork_data.get("paths", [])))
		"conditional":
			if auto_resolved:
				fork_screen.reveal(_conditional_path(fork_data), _conditional_caption(fork_data))


# Picks a path index by weight (per-path "weight", default 1). The weighting math
# lives in ForkResolver.weighted_pick (pure, tested); only the random draw stays
# here. If every weight is 0, all paths are equally likely.
func _weighted_random_path(paths: Array) -> int:
	if paths.is_empty():
		return 0
	var weights: Array = []
	var total: int = 0
	for p: Dictionary in paths:
		var w: int = maxi(0, int(p.get("weight", 1)))
		weights.append(w)
		total += w
	if total <= 0:
		return randi() % paths.size()
	return ForkResolver.weighted_pick(weights, randi() % total)


# Resolves a conditional fork to a path index. Score/coins use tiered thresholds;
# item checks ownership (not consumed); default path on no-match. The resolution
# logic lives in ForkResolver.conditional_path (pure, tested) — here we just gather
# the current score / coins / ownership.
func _conditional_path(fork_data: Dictionary) -> int:
	var metric: String = fork_data.get("cond_metric", "score")
	# Flag metric: the "ownership" check is a flag-set check against GameState's run flags.
	if metric == "flag":
		return ForkResolver.conditional_path(
			fork_data.get("paths", []),
			metric,
			int(fork_data.get("default_path", 0)),
			0,
			Callable(GameState, "HasFlag")
		)
	# Counter: each choice gates on its OWN counter (paths carry the effective cond_counter, already
	# resolved against the fork default in GameState.ParseFork), so it can't collapse to one scalar
	# like score/coins — ForkResolver reads each path's counter through this lookup instead.
	if metric == "counter":
		var counter_of: Callable = func(cn: String) -> int: return GameState.CounterValue(cn)
		return ForkResolver.conditional_path(
			fork_data.get("paths", []),
			metric,
			int(fork_data.get("default_path", 0)),
			0,
			Callable(InventoryService, "OwnsItem"),
			counter_of
		)
	# score / coins resolve by threshold against one scalar — only the source of the value differs.
	var value: int
	match metric:
		"coins":
			value = CoinService.Balance
		_:
			value = ScoreService.LastRoundScore
	return ForkResolver.conditional_path(
		fork_data.get("paths", []),
		metric,
		int(fork_data.get("default_path", 0)),
		value,
		Callable(InventoryService, "OwnsItem")
	)


# Flavour text shown during a conditional fork's reveal, per metric.
func _conditional_caption(fork_data: Dictionary) -> String:
	match fork_data.get("cond_metric", "score"):
		"score":
			return "BY YOUR SCORE…"
		"coins":
			return "BY YOUR COINS…"
		"item":
			return "BY WHAT YOU CARRY…"
		"flag":
			return "BY WHERE YOU'VE BEEN…"
		"counter":
			var cn: String = str(fork_data.get("cond_counter", "")).strip_edges()
			return ("BY YOUR %s…" % cn.to_upper()) if cn != "" else "BY THE TALLY…"
	return "FATE DECIDES…"


func _on_fork_path_chosen(path_index: int) -> void:
	_is_overlay_open = false
	_overlay_map_allowed = false
	GameState.ResolveFork(path_index)
	await _transition_swap(
		func() -> void:
			_video.paused = false
			FunscriptPlayer.Resume()
			_load_current_item()
	)


func _load_current_round() -> void:
	var round: Dictionary = GameState.CurrentRound().duplicate(true)
	if round.is_empty():
		push_error("GameLoop: GameState has no current round — returning to menu")
		_go_to_menu()
		return
	# Prewarm the Handy's HSP session now (script-agnostic /hsp/setup), so its round-trip overlaps the intro
	# card / mystery reveal / video load ahead — leaving only the anchored /hsp/play at the actual round
	# start. Handy WiFi only; fire-and-forget.
	if _handy_stroke_selected():
		HandyService.prewarm()
	# Migrate any legacy cursed/blessed round to the generic effect schema here, once,
	# so every downstream reader (label, enter mode, reveal card) sees generic fields.
	round.merge(JourneyData.normalize_effect_round(round), true)

	# Pool ("encounter") round: weighted-pick one entry NOW and fold its media + type onto this
	# round copy, so everything below (type flags, label, boss intro) sees the CHOSEN encounter's
	# type — a rolled boss telegraphs with its own intro card. The mystery reveal card is deferred
	# to _start_round_after_gates so it plays before that boss intro. Must run before the flags.
	_pending_encounter_card = false
	if str(round.get("round_type", "normal")) == "pool":
		_resolve_pool_round(round)
		_pending_encounter_card = bool(round.get("show_encounter", true))

	var total: int = GameState.TotalRounds()
	var num: int = GameState.RoundNumber

	_progress.value = 0.0
	_paused = false
	_pause_btn.text = "|| PAUSE"
	_update_muffle()  # a new round never starts muffled (e.g. paused → next round)

	var rtype: String = round.get("round_type", "normal")
	_is_boss_round = rtype == "boss"
	_is_effect_round = rtype == "effect"
	# A pool round mid-mystery keeps a neutral "???" label until its card slides away, so the HUD
	# never flashes "BOSS" and spoils a rolled encounter; _start_round_after_gates reveals it.
	if _pending_encounter_card:
		_round_lbl.text = "ROUND  %d / %d  —  ???" % [num, total]
	else:
		_apply_round_label(round)

	# Checkpoints are their own node now (see _show_checkpoint_gate) — a round just starts.
	_start_round_after_gates(round)


# Starts a round once any checkpoint gate is cleared: a pool round plays its mystery reveal
# first (before any boss intro, so a rolled boss stays hidden until the card slides away),
# then boss rounds telegraph with their intro card (playback waits for BEGIN); everything
# else begins now.
func _start_round_after_gates(round: Dictionary) -> void:
	if _pending_encounter_card:
		_pending_encounter_card = false
		await _show_encounter_card()
		_apply_round_label(round)  # reveal the real (possibly BOSS) label now the card is done
	if _is_boss_round:
		_show_boss_intro(round)
	else:
		_begin_round(round)


# Sets the HUD round label from the round's resolved type. Split out so a pool round can defer
# it until after its mystery card (see _load_current_round / _start_round_after_gates).
func _apply_round_label(round: Dictionary) -> void:
	var total: int = GameState.TotalRounds()
	var num: int = GameState.RoundNumber
	if _is_boss_round:
		_round_lbl.text = (
			"⚔  BOSS  %d / %d  —  %s" % [num, total, (round.get("name", "") as String).to_upper()]
		)
	else:
		var prefix: String = "ROUND"
		if _is_effect_round:
			var v: Dictionary = _effect_visuals(round)
			prefix = "%s  %s" % [v["icon"], v["header"]]
		_round_lbl.text = (
			"%s %d / %d  —  %s" % [prefix, num, total, (round.get("name", "") as String).to_upper()]
		)


# Loads the round's scripts + video and starts playback. For boss rounds this
# runs after the intro card's BEGIN; for normal rounds, immediately.
func _begin_round(round: Dictionary) -> void:
	_round_ended_guard = false  # a fresh round can end once again
	_cancel_override()  # cut any override still playing from the previous round (cut-at-round-end)
	ScoreService.StartRound()
	# Clear any pause left by a pre-round gate (boss intro / checkpoint banner) —
	# _video.play() below doesn't reset the paused flag on its own.
	_video.paused = false

	# The round's effective length (a pool round already folded the chosen entry's media +
	# stats in during _load_current_round; everything else carries its own). Read at round end
	# for the play log.
	_active_round_length_ms = int(round.get("length_ms", 0))

	if bool(round.get("is_warmup", false)):
		_show_warmup_skip_button()
	# FINISH ("I came") is available during every round when the journey opts in.
	_show_finish_button()

	var fs_path: String = round.get("funscript_path", "")
	# Prefer a sibling ".alpha" funscript for the main (L0 / position) channel when it exists —
	# that's the true alpha of an alpha/beta pair. Fall back to the plain funscript otherwise.
	if fs_path != "":
		var a_dir: String = fs_path.get_base_dir()
		var a_base: String = ImportScanner.strip_script_suffix(fs_path)
		var a_ext: String = fs_path.get_extension()
		for a_cand: String in [
			"%s/%s.alpha.%s" % [a_dir, a_base, a_ext],
			"%s/%s_alpha.%s" % [a_dir, a_base, a_ext],
		]:
			if FileAccess.file_exists(a_cand):
				fs_path = a_cand
				break
		FunscriptPlayer.LoadFunscript(fs_path)
		ScoreService.SetRoundActions(FunscriptPlayer.ActionCount)
		if _beat_bar != null:
			_beat_bar.set_beats(FunscriptPlayer.GetBeats())
	_update_round_timer(true)  # this round's full length, before the first frame ticks

	# Auto-detect sibling scripts sitting next to the main funscript on disk — e.g. a per-round
	# folder holding <name>.beta / <name>.carrier_frequency next to <name>.funscript. This lets
	# EXISTING journeys (whose journey.json has empty AxisScripts) drive restim without a
	# re-import. Explicit journey.json entries always win over an auto-detected sibling.
	var axis_scripts: Dictionary = (round.get("axis_scripts", {}) as Dictionary).duplicate()
	var estim_scripts: Dictionary = (round.get("estim_scripts", {}) as Dictionary).duplicate()
	if fs_path != "":
		var sib: Dictionary = ImportScanner.find_sibling_scripts(
			fs_path.get_base_dir(), ImportScanner.strip_script_suffix(fs_path)
		)
		for ax: String in sib["axis"]:
			if not axis_scripts.has(ax):
				axis_scripts[ax] = sib["axis"][ax]
		for eax: String in sib["estim"]:
			if not estim_scripts.has(eax):
				estim_scripts[eax] = sib["estim"][eax]

	# Load secondary axis scripts (serial + restim motion axes). Clear first so stale axes
	# from a prior round are never replayed.
	FunscriptPlayer.ClearAxisScripts()
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

	# Load restim (E-Stim Full) parameter scripts (restim output only; ignored when
	# restim isn't connected). Clear first so a prior round's params aren't replayed.
	FunscriptPlayer.ClearRestimScripts()
	for eax: String in estim_scripts:
		var estim_path: String = estim_scripts[eax]
		if estim_path != "":
			FunscriptPlayer.LoadRestimScript(eax, estim_path)

	# Boss / effect setup must run before _load_video → FunscriptPlayer.Play() so
	# the forced modifier is already active on the first dispatched stroke. Each
	# enter_*_mode populates _reveal_effects for the pre-round card.
	_reveal_effects = []
	if _is_boss_round:
		_enter_boss_mode(round)
	elif _is_effect_round:
		_enter_effect_mode(round)

	# Effect rounds get an animated intro card before playback starts (auto-advances; any
	# cleanse choice stays in-round) — whenever the author left it on, even with no effects
	# (a pure-visual round shows just the header). Normal/boss rounds never show it.
	if _is_effect_round and bool(round.get("show_reveal", true)):
		await _show_reveal_card(round)

	# Prefer the explicit video_path (set by the scanner from VideoPath, or by
	# JourneyData._round_video); fall back to a folder-scan for pre-VideoPath
	# journeys that never recorded one.
	var video_path: String = round.get("video_path", "")
	if video_path == "":
		video_path = _find_video(round.get("folder", ""))
	_load_video(video_path)

	# The Handy (direct WiFi) plays the script itself — fire-and-forget the setup/synced-play chain. MUST run
	# AFTER _load_video (so the anchor reads THIS clip's position, not the previous round's stale one) and
	# after the boss/effect setup above (so forced modifiers are baked into the streamed script). The old
	# slow per-round handshake used to defer this by accident; now that ensure_ready is instant, the order is
	# explicit. Scoring + beat bar stay on FunscriptPlayer's clock regardless.
	#
	_handy_begin_round(fs_path)


# ---------------------------------------------------------------------------
# Checkpoint rounds
# ---------------------------------------------------------------------------


# CHECKPOINT REACHED banner shown at the start of any round the author marked
# as a checkpoint. Two buttons: Save & Quit (writes a save + returns to
# catalogue) or Continue (dismisses the banner and starts the round normally).
# Pattern mirrors _show_boss_intro since both gate round start on user input.
# The checkpoint node's gate: a Save & Quit / Continue banner reached BETWEEN rounds (its own
# node now, not a round flag). Continue advances to the next item; Save & Quit writes a one-time
# save at this node and exits. Dispatched from _load_current_item.
func _show_checkpoint_gate() -> void:
	var data: Dictionary = GameState.CurrentItem().get("data", {})
	_is_overlay_open = true  # suppress gameplay hotkeys while the banner is up
	_halt_playback_for_gate()  # freeze any leftover playback so the score can't tick

	var parts: Dictionary = UITheme.build_centered_modal(
		"◆  CHECKPOINT REACHED  ◆", UITheme.AMBER, Vector2i(620, 320)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	vbox.add_theme_constant_override("separation", 18)

	# Optional author label. Omitted from the card when blank rather than showing an empty line.
	var label: String = str(data.get("name", "")).strip_edges()
	if label != "":
		var subtitle: Label = Label.new()
		subtitle.text = label.to_upper()
		UITheme.style_label(subtitle, UITheme.WHITE_SOFT, 14, true)
		subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(subtitle)

	var hint: Label = Label.new()
	hint.text = "You've reached a save point. Save & Quit to resume from here later, or continue playing now. The save is one-time — used up when you resume."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(hint, UITheme.PURPLE_MID, 12, false)
	vbox.add_child(hint)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	var save_btn: Button = Button.new()
	save_btn.text = "💾  SAVE & QUIT"
	save_btn.custom_minimum_size = Vector2(200, 0)
	UITheme.style_button(save_btn, UITheme.AMBER)
	save_btn.pressed.connect(
		func() -> void:
			modal.queue_free()
			_is_overlay_open = false
			_on_save_and_quit()
	)
	btn_row.add_child(save_btn)

	var continue_btn: Button = Button.new()
	continue_btn.text = "▶  CONTINUE"
	continue_btn.custom_minimum_size = Vector2(160, 0)
	UITheme.style_button(continue_btn, UITheme.PURPLE_BRIGHT)
	continue_btn.pressed.connect(
		func() -> void:
			modal.queue_free()
			_is_overlay_open = false
			_apply_checkpoint_continue_reward(data)  # reward for skipping the break (not on resume)
			_advance_from_checkpoint()
	)
	btn_row.add_child(continue_btn)

	add_child(modal)


# Grants a checkpoint's ON-CONTINUE reward — only when the player skips the save and keeps going (the
# interactive Continue button), never on a resume (which re-enters the checkpoint after taking the break).
# Lets an author reward pressing on: an item, a counter bump, and/or a flag, then gate a secret path or
# ending on it (e.g. "collected every safe word → bonus finale"). No-op when nothing is configured.
func _apply_checkpoint_continue_reward(data: Dictionary) -> void:
	var reward: Dictionary = data.get("continue_reward", {})
	if reward.is_empty():
		return
	_grant_item(str(reward.get("award_item", "")))  # guards "" internally, pops "✦ RECEIVED"
	GameState.ApplyItemFlagsCounters(reward)  # reward carries set_counters / set_flags in the node shape


# Continue past a checkpoint node → advance to the next item (mirrors _on_shop_closed: a
# content-less node that just moves the sequence forward).
func _advance_from_checkpoint() -> void:
	GameState.ApplyCurrentNodeCounters()  # a checkpoint's own set_counters (rare, but authoring allows it)
	GameState.Advance()
	if GameState.IsSequenceDone():
		_transition_to_end_screen()
		return
	await _transition_swap(func() -> void: _load_current_item())


# ---------------------------------------------------------------------------
# Boss rounds
# ---------------------------------------------------------------------------


# Freezes playback while a pre-round modal (boss intro / checkpoint banner) is up.
# A round reached after a shop/storyboard/fork resumes the prior video+funscript
# before loading the next item; for a gated round that real start is deferred to
# BEGIN/Continue, so without this the leftover playback would keep dispatching
# strokes and tick the score up behind the modal. _begin_round restarts cleanly.
func _halt_playback_for_gate() -> void:
	_video.paused = true
	FunscriptPlayer.Pause()


# Telegraphed intro card. The round's scripts/video do not load and playback
# does not start until the player clicks BEGIN.
func _show_boss_intro(round: Dictionary) -> void:
	_is_overlay_open = true  # suppress gameplay hotkeys while the card is up
	_halt_playback_for_gate()  # don't let leftover playback tick the score behind the card

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
	ps.border_width_left = 3
	ps.border_width_right = 3
	ps.border_width_top = 3
	ps.border_width_bottom = 3
	ps.content_margin_left = 48
	ps.content_margin_right = 48
	ps.content_margin_top = 36
	ps.content_margin_bottom = 36
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	col.custom_minimum_size = Vector2(440, 0)  # bounds scaled text so it wraps, not overflows
	panel.add_child(col)

	var banner: Label = Label.new()
	banner.text = "⚔   B O S S   R O U N D   ⚔"
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	banner.add_theme_color_override("font_color", UITheme.DANGER)
	banner.add_theme_font_size_override("font_size", UITheme.story_font_size(28))
	col.add_child(banner)

	var boss_image: String = round.get("boss_image", "")
	if boss_image != "":
		# May be a still or a baked animation (JourneyImage decides from the path); same
		# expand/stretch either way, so an animated boss portrait frames exactly like a still one.
		var img_ctl: JourneyImage = JourneyImage.new()
		img_ctl.custom_minimum_size = Vector2(380, 240)
		col.add_child(img_ctl)
		var boss_fit: int = JourneyImage.stretch_for_fit(
			str(round.get("image_fit", "")), TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		)
		if not img_ctl.show_path(boss_image, TextureRect.EXPAND_IGNORE_SIZE, boss_fit):
			img_ctl.queue_free()  # nothing to show — don't leave a 380x240 hole in the card

	var name_lbl: Label = Label.new()
	name_lbl.text = (round.get("name", "") as String).to_upper()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(22))
	col.add_child(name_lbl)

	var tagline: String = round.get("boss_tagline", "")
	if tagline.strip_edges() != "":
		var tag_lbl: Label = Label.new()
		tag_lbl.text = tagline
		tag_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tag_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tag_lbl.custom_minimum_size = Vector2(440, 0)
		tag_lbl.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
		tag_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(14))
		col.add_child(tag_lbl)

	# Name the gameplay effects the boss carries so the player isn't blindsided — the boss
	# equivalent of the effect round's reveal card, folded onto the intro. Each coloured by
	# valence (boon green, hindrance red). Empty for a boss with only raw modifiers. Resolved
	# fresh here because the card is built before _enter_boss_mode applies them.
	var boss_fx: Array = _resolve_gameplay_effects(
		round, JourneyData.catalog_subset(JourneyData.gameplay_effects(), round.get("effects", []))
	)
	for fx: Dictionary in boss_fx:
		var fx_lbl: Label = Label.new()
		fx_lbl.text = (fx.get("name", "") as String).to_upper()
		fx_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fx_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var benefit: bool = JourneyData.effect_is_benefit(str(fx.get("_ref", fx.get("name", ""))))
		fx_lbl.add_theme_color_override(
			"font_color", UITheme.SUCCESS if benefit else UITheme.ERROR_SOFT
		)
		fx_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(14))
		col.add_child(fx_lbl)

	var rules_lbl: Label = Label.new()
	rules_lbl.text = "NO ITEMS  ·  FORCED MODIFIERS"
	rules_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rules_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rules_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	rules_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(11))
	col.add_child(rules_lbl)

	var begin_btn: Button = Button.new()
	begin_btn.text = "⚔  BEGIN"
	begin_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UITheme.style_button(begin_btn, UITheme.DANGER, 32, 14)
	col.add_child(begin_btn)
	begin_btn.pressed.connect(
		func() -> void:
			overlay.queue_free()
			_is_overlay_open = false
			_begin_round(round)
	)


# Clean slate, forced modifiers, item lockout, red frame on.
func _enter_boss_mode(round: Dictionary) -> void:
	# Clean slate — drop any effects the player activated before the boss. Clear this round's sensory
	# list first so the ActiveEffectsChanged from ClearActiveEffects reconciles against an empty set.
	_round_sensory.clear()
	InventoryService.ClearActiveEffects()

	# Inject the designer's forced modifiers as boss effects.
	var boss_effects: Array = []
	for mod: Dictionary in round.get("boss_modifiers", []):
		boss_effects.append(_make_boss_effect(mod))
	if not boss_effects.is_empty():
		InventoryService.AddBossEffects(boss_effects)

	# Forced gameplay effects (hindrances/boons) — a boss can carry the full effect catalog on
	# top of its raw stroke modifiers. All ticked effects apply: forced, no roll, no cleanse.
	_apply_gameplay_effects(
		round, JourneyData.catalog_subset(JourneyData.gameplay_effects(), round.get("effects", []))
	)

	# Optional non-gameplay (visual/audio) modifiers, explicitly authored — same hex
	# pipeline as a cursed round, but forced (no cleanse). Each surfaces as a red
	# HUD chip and is torn down by _clear_curse_hexes at round end (_exit_boss_mode).
	for roll: Dictionary in JourneyData.catalog_subset(
		JourneyData.SENSORY_CATALOG, round.get("sensory", [])
	):
		var hx: Dictionary = _make_boss_effect(roll)
		hx["name"] = roll.get("name", hx["name"])
		InventoryService.AddBossEffects([hx])
		_apply_hex(roll, SensoryFX.intensity_for(round, roll))

	_reconcile_sensory()  # apply the round's collected sensory (plus any surviving item sensory)
	_reconcile_hud_hide()  # round Fog (or a surviving item Fog) → HUD hidden

	# Item use is disabled for the whole boss round.
	if is_instance_valid(_inventory_panel):
		_inventory_panel.close()
	_inv_btn.disabled = true

	if _boss_frame != null:
		_boss_frame.visible = true
		_boss_frame.modulate.a = 0.5


# Applies this round's effect(s) as boss effects — author-selected/fixed, or rolled
# from the merged pool. Unlike a boss round, items stay usable so the player can
# counter (or, when the round is resolvable, cleanse) them. Hindrances and boons mix
# freely; each effect's valence (its source catalog) colours its chip / card line.
func _enter_effect_mode(round: Dictionary) -> void:
	_effect_resolvable = bool(round.get("resolvable", false))
	_effect_cleanse_cost = int(round.get("cleanse_cost", CLEANSE_COST_DEFAULT))
	_round_sensory.clear()  # rebuilt below via _apply_hex; item sensory (if any) is folded in on reconcile

	var selected: Array = round.get("effects", [])
	var random_mode: bool = bool(round.get("effect_random", true))
	var sensory_in_pool: bool = bool(round.get("sensory_in_pool", false))

	# GAMEPLAY effects (hindrances + boons) come only from the author's ticked list. NONE
	# ticked = no gameplay effect — the round is then a pure visual (intro card + optional
	# border). Random rolls one from the ticked set; fixed applies them all.
	var to_apply: Array = []
	if not selected.is_empty():
		if random_mode:
			var pool: Array = JourneyData.catalog_subset(JourneyData.gameplay_effects(), selected)
			if sensory_in_pool:
				pool = pool + JourneyData.SENSORY_CATALOG
			to_apply = _roll_from(pool)
		else:
			to_apply = JourneyData.catalog_subset(JourneyData.gameplay_effects(), selected)

	# Ticked non-gameplay (sensory) modifiers always apply (deduped against the roll).
	for s: Dictionary in JourneyData.catalog_subset(
		JourneyData.SENSORY_CATALOG, round.get("sensory", [])
	):
		if s not in to_apply:
			to_apply.append(s)

	to_apply = _apply_gameplay_effects(round, to_apply)
	_reconcile_sensory()  # apply the round's collected sensory alongside any active item sensory
	_reconcile_hud_hide()  # round Fog (or a surviving item Fog) → HUD hidden

	# Optional coloured border (author-toggled); the resolvable cleanse layer when enabled.
	var v: Dictionary = _effect_visuals(round)
	_show_effect_overlay(v["frame"], bool(round.get("show_border", false)))
	if _effect_resolvable:
		_effect_resolved = false
		_show_cleanse_button()
	_reveal_effects = _build_reveal_effects(to_apply)


# Resolves a round's ticked catalog entries against its per-effect overrides (tuned magnitude +
# custom name/flavor) — pure, no side effects. `_ref` is preserved so valence survives a rename;
# sensory entries pass through unchanged. The boss card resolves for DISPLAY before the round's
# effects are applied, so resolution is split out from application.
func _resolve_gameplay_effects(round: Dictionary, entries: Array) -> Array:
	var overrides: Dictionary = round.get("effect_overrides", {})
	var resolved: Array = []
	for e: Dictionary in entries:
		var r: Dictionary = JourneyData.resolved_effect(str(e.get("name", "")), overrides)
		if not r.is_empty():
			resolved.append(r)
	return resolved


# Applies already-resolved effects as boss effects: into the shared effect pipeline, chip
# coloured by valence, then its GameLoop-side behaviour. Shared by boss and effect rounds — a
# boss now surfaces gameplay effects exactly as an effect round does.
func _apply_gameplay_effects(round: Dictionary, entries: Array) -> Array:
	var resolved: Array = _resolve_gameplay_effects(round, entries)
	for roll: Dictionary in resolved:
		var fx: Dictionary = _make_boss_effect(roll)
		fx["name"] = roll.get("name", fx["name"])
		if JourneyData.effect_is_benefit(str(roll.get("_ref", roll.get("name", "")))):
			fx["benefit"] = true  # green chip; hindrances/sensory stay red
		InventoryService.AddBossEffects([fx])
		_apply_effect(roll, round)
	return resolved


# Dispatches an effect to its GameLoop-side behaviour. Stroke/economy modifiers
# (scale/clamp/reverse/block/score_multiplier/coin_jackpot/coin_penalty) are already
# live via the boss-effect pipeline and need nothing here; the boon behaviours
# (gift/interest/lingering) run in _apply_boon, everything else through _apply_hex
# (sensory + hud_hide/no_pause/toll). Both no-op on kinds they don't own.
func _apply_effect(roll: Dictionary, round: Dictionary) -> void:
	if String(roll.get("kind", "")) in ["gift", "interest", "lingering"]:
		_apply_boon(roll, round)
	else:
		_apply_hex(roll, SensoryFX.intensity_for(round, roll))


# GameLoop-side boon behaviours (the ones not handled by an existing effect kind).
func _apply_boon(roll: Dictionary, round: Dictionary) -> void:
	match String(roll.get("kind", "")):
		"gift":
			_grant_item(str(round.get("gift_item", "")))
		"interest":
			_grant_coins(roundi(CoinService.Balance * float(roll.get("pct", INTEREST_PCT))))
		"lingering":
			_effect_lingering = true
			InventoryService.SetPaused(true)  # freeze the effect clock for the round


# Resolves the framing (icon, header, accent, border colour) for an effect round
# straight from its author-set fields. Colours are concrete (baked in at save / migration).
func _effect_visuals(round: Dictionary) -> Dictionary:
	return {
		"icon": _nonblank_str(str(round.get("card_icon", "")), "✦"),
		"header": _nonblank_str(str(round.get("card_header", "")), "EFFECT"),
		"accent": _hex_color(round.get("card_accent", ""), JourneyData.EFFECT_COLOR_NEUTRAL),
		"frame": _hex_color(round.get("frame_color", ""), JourneyData.EFFECT_COLOR_NEUTRAL),
	}


# Parses an "#rrggbb" string to a Color, falling back to `fallback_hex` when blank/invalid.
func _hex_color(value: Variant, fallback_hex: String) -> Color:
	var s: String = str(value)
	if s != "" and Color.html_is_valid(s):
		return Color.html(s)
	return Color.html(fallback_hex)


func _nonblank_str(value: String, fallback: String) -> String:
	return value if value != "" else fallback


# Animated pre-round reveal card naming the effect(s) and what they do. Fades + pops
# in, holds, fades out — then the round's video plays. Awaited by _begin_round so
# playback waits for it. Header / icon / accent come from the round's effect visuals.
func _show_reveal_card(round: Dictionary) -> void:
	var v: Dictionary = _effect_visuals(round)
	var accent: Color = v["accent"]

	var root: Control = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var backdrop: ColorRect = ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0, 0, 0, 0.6)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(backdrop)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG_DEEP
	ps.border_color = accent
	ps.set_border_width_all(2)
	ps.set_corner_radius_all(8)
	ps.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(440, 0)
	panel.add_child(col)

	var header: Label = Label.new()
	header.text = "%s  %s" % [v["icon"], v["header"]]
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_theme_color_override("font_color", accent)
	header.add_theme_font_size_override("font_size", UITheme.story_font_size(34))
	col.add_child(header)

	for fx: Dictionary in _reveal_effects:
		var name_lbl: Label = Label.new()
		name_lbl.text = (fx.get("name", "") as String).to_upper()
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_lbl.add_theme_color_override(
			"font_color", UITheme.SUCCESS if fx.get("benefit", false) else UITheme.ERROR_SOFT
		)
		name_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(20))
		col.add_child(name_lbl)
		var desc_lbl: Label = Label.new()
		desc_lbl.text = fx.get("desc", "")
		desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
		desc_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(13))
		col.add_child(desc_lbl)

	# Animate: fade + pop in, hold, fade out.
	await get_tree().process_frame  # let layout settle so the pivot is centered
	panel.pivot_offset = panel.size / 2.0
	panel.scale = Vector2(0.92, 0.92)
	root.modulate.a = 0.0
	var tin: Tween = create_tween().set_parallel(true)
	tin.tween_property(root, "modulate:a", 1.0, 0.3)
	tin.tween_property(panel, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	await tin.finished
	await get_tree().create_timer(REVEAL_HOLD_SECS).timeout
	if not is_inside_tree():
		return
	var tout: Tween = create_tween()
	tout.tween_property(root, "modulate:a", 0.0, 0.3)
	await tout.finished
	root.queue_free()


# Pool round: weighted-pick one encounter entry and swap its resolved media into the
# round dict (a deep copy, safe to mutate) so the rest of _begin_round loads it like a
# normal round. No-op when the pool is empty (presave should have blocked that).
func _resolve_pool_round(round: Dictionary) -> void:
	var entries: Array = round.get("pool_entries", [])
	if entries.is_empty():
		return
	# No-repeat (opt-in): drop entries whose clip already played this run so two copies of the pool
	# don't show the same video. Falls back to the full set once every entry has been drawn.
	var no_repeat: bool = bool(round.get("no_repeat", false))
	var weights: Array = (
		JourneyData.pool_draw_weights(entries, GameState.PlayedPoolClips())
		if no_repeat
		else JourneyData.pool_entry_weights(entries)
	)
	var total_w: int = 0
	for w: int in weights:
		total_w += w
	var idx: int = ForkResolver.weighted_pick(weights, randi() % maxi(1, total_w))
	var e: Dictionary = entries[idx]
	if no_repeat:
		GameState.MarkPoolClipPlayed(str(e.get("video_path", "")))
	round["video_path"] = str(e.get("video_path", ""))
	round["funscript_path"] = str(e.get("funscript_path", ""))
	round["axis_scripts"] = (e.get("axis_scripts", {}) as Dictionary).duplicate(true)
	round["vib_scripts"] = (e.get("vib_scripts", {}) as Dictionary).duplicate(true)
	# Carry the chosen entry's stats too, so round length + action count (HUD,
	# no-video timer, and the end-screen recap) reflect what actually played.
	round["length_ms"] = int(e.get("length_ms", 0))
	round["action_count"] = int(e.get("action_count", 0))
	# Adopt the chosen entry's TYPE so the round plays as that type. "pool" collapses to the
	# picked encounter's own type — normal, or boss (with its forced modifiers / intro card).
	var etype: String = str(e.get("round_type", "normal"))
	round["round_type"] = etype
	if etype == "boss":
		round["boss_modifiers"] = (e.get("boss_modifiers", []) as Array).duplicate(true)
		round["boss_tagline"] = str(e.get("boss_tagline", ""))
		round["boss_image"] = str(e.get("boss_image", ""))
		round["sensory"] = (e.get("sensory", []) as Array).duplicate(true)


# The mystery "ENCOUNTER!" reveal for a pool round: slides in from the right, holds,
# slides out to the left. Awaited by _begin_round before playback. Deliberately shows
# no name — the video reveals which encounter it is.
func _show_encounter_card() -> void:
	var accent: Color = UITheme.MAGENTA

	var root: Control = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var backdrop: ColorRect = ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0, 0, 0, 0.6)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(backdrop)

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG_DEEP
	ps.border_color = accent
	ps.set_border_width_all(2)
	ps.set_corner_radius_all(8)
	ps.set_content_margin_all(30)
	panel.add_theme_stylebox_override("panel", ps)
	root.add_child(panel)

	var label: Label = Label.new()
	label.text = "⚔  ENCOUNTER!"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", accent)
	label.add_theme_font_size_override("font_size", 44)
	panel.add_child(label)

	await get_tree().process_frame  # let the panel size itself before centering
	var target: Vector2 = (root.size - panel.size) / 2.0
	var off: Vector2 = Vector2(root.size.x, 0.0)
	panel.position = target + off
	root.modulate.a = 0.0
	var tin: Tween = create_tween().set_parallel(true)
	tin.tween_property(root, "modulate:a", 1.0, 0.35)
	tin.tween_property(panel, "position", target, 0.45).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	await tin.finished
	await get_tree().create_timer(ENCOUNTER_HOLD_SECS).timeout
	if not is_inside_tree():
		return
	var tout: Tween = create_tween().set_parallel(true)
	tout.tween_property(root, "modulate:a", 0.0, 0.3)
	tout.tween_property(panel, "position", target - off, 0.3).set_ease(Tween.EASE_IN)
	await tout.finished
	root.queue_free()


# Slow drift on the effect-round frame — breathes rather than snaps. The colour is
# set per-round in _show_effect_overlay; here we only animate the alpha.
func _update_effect_frame() -> void:
	if _effect_frame == null:
		return
	var t: float = Time.get_ticks_msec() / 1000.0
	_effect_frame.modulate.a = 0.42 + 0.25 * sin(t * TAU * 0.37)


# Builds the reveal-card payload from a list of catalog entries. Each entry's benefit
# flag comes from its source catalog (boon → green, hindrance / sensory → red).
func _build_reveal_effects(entries: Array) -> Array:
	var out: Array = []
	for e: Dictionary in entries:
		(
			out
			. append(
				{
					"name": str(e.get("name", "")),
					"desc": str(e.get("desc", "")),
					"benefit": JourneyData.effect_is_benefit(str(e.get("_ref", e.get("name", "")))),
				}
			)
		)
	return out


# Rolls one entry from `pool`, or rarely two (the "double" chance).
func _roll_from(pool: Array) -> Array:
	if pool.is_empty():
		return []
	var shuffled: Array = pool.duplicate()
	shuffled.shuffle()
	var count: int = 2 if (shuffled.size() >= 2 and randf() < DOUBLE_EFFECT_CHANCE) else 1
	return shuffled.slice(0, count)


# Floating "cleanse" button shown during a cursed round — outside the HUD so a
# Fog hex can't hide it. Pay the round's cleanse cost to lift the curse, or endure
# to the end for the round's bonus.
func _show_cleanse_button() -> void:
	_remove_cleanse_button()
	var btn: Button = Button.new()
	var has_item: bool = InventoryService.OwnsItem("cleanse")
	btn.text = (
		"✦ CLEANSE  (use Cleanse item)" if has_item else "✦ CLEANSE  (♦ %d)" % _effect_cleanse_cost
	)
	btn.tooltip_text = (
		"Lift the curse with a Cleanse item or %d coins — or endure it for the reward."
		% _effect_cleanse_cost
	)
	UITheme.style_button(btn, Color(0.45, 0.95, 0.30))
	btn.anchor_left = 0.5
	btn.anchor_right = 0.5
	btn.anchor_top = 1.0
	btn.anchor_bottom = 1.0
	btn.offset_top = -96
	btn.offset_bottom = -56
	btn.offset_left = -110
	btn.offset_right = 110
	btn.pressed.connect(_on_cleanse_pressed)
	add_child(btn)
	_effect_cleanse_btn = btn


# Free skip offered on a warmup round. Deliberately OUTSIDE the HUD, like the cleanse button —
# an effect that hides the HUD must not be able to trap a player in a round they were told they
# could leave. Sits above the cleanse button so an effect round marked warmup shows both.
func _show_warmup_skip_button() -> void:
	_remove_warmup_skip_button()
	var btn: Button = Button.new()
	btn.text = "⏭ SKIP WARMUP"
	btn.tooltip_text = "Skip this warmup round. It pays no coins, score or reward."
	UITheme.style_button(btn, UITheme.CYAN)
	btn.anchor_left = 0.5
	btn.anchor_right = 0.5
	btn.anchor_top = 1.0
	btn.anchor_bottom = 1.0
	btn.offset_top = -146
	btn.offset_bottom = -106
	btn.offset_left = -110
	btn.offset_right = 110
	btn.pressed.connect(_on_warmup_skip_pressed)
	add_child(btn)
	_warmup_skip_btn = btn
	# Starts visible and joins the HUD's cycle from the next _show_hud — which the round-start
	# transition always fires. Deliberately not calling _show_hud here: this runs *under* the
	# transition black, and would start the idle timer before the player can see anything.


# Fades the warmup skip in/out on the HUD's idle cycle so it doesn't sit over the video for the
# whole round. Kept *visible* (alpha only) rather than hidden, and never gated on the Fog curse —
# it stays clickable even at rest, so a player reaching for it mid-fade isn't punished.
func _fade_warmup_skip_button(shown: bool) -> void:
	if not is_instance_valid(_warmup_skip_btn):
		return
	var to: float = 1.0 if shown else 0.0
	if is_equal_approx(_warmup_skip_btn.modulate.a, to):
		return
	create_tween().tween_property(_warmup_skip_btn, "modulate:a", to, 0.3)


func _remove_warmup_skip_button() -> void:
	if is_instance_valid(_warmup_skip_btn):
		_warmup_skip_btn.queue_free()
	_warmup_skip_btn = null


const _FINISH_IDLE_TEXT: String = "✔ HOLD TO FINISH"


# The FINISH ("I came") button — a hold-to-confirm floating button (a tap can't end the session), shown
# only during rounds when the journey opts in. Sits just ABOVE the HUD bar, hugging the RIGHT edge (like
# the cleanse button but right-aligned). Fades with the HUD's idle cycle — when the UI fades out it does
# too — but stays clickable at rest so a hold started as it fades isn't broken.
func _show_finish_button() -> void:
	_remove_finish_button()
	if not _allow_finish or _finishing:
		return
	var btn: Button = Button.new()
	btn.text = _FINISH_IDLE_TEXT
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = UITheme.wrap_tip(
		"Hold to finish the session (I came). Ends the run and shows the finale."
	)
	UITheme.style_button(btn, UITheme.MAGENTA)
	btn.anchor_left = 1.0
	btn.anchor_right = 1.0
	btn.anchor_top = 1.0
	btn.anchor_bottom = 1.0
	btn.offset_left = -232
	btn.offset_right = -20
	btn.offset_top = -(HUD_BAR_HEIGHT + 48)  # 40px tall, an 8px gap above the bar
	btn.offset_bottom = -(HUD_BAR_HEIGHT + 8)
	btn.button_down.connect(_on_finish_hold_start)
	btn.button_up.connect(_on_finish_hold_cancel)
	add_child(btn)
	_finish_btn = btn


# Fades the FINISH button with the HUD's idle cycle (alpha only) — it disappears when the UI does. Kept
# clickable at rest (alpha, not visibility) so a hold in progress as it fades still resolves on release.
func _fade_finish_button(shown: bool) -> void:
	if not is_instance_valid(_finish_btn):
		return
	var to: float = 1.0 if shown else 0.0
	if is_equal_approx(_finish_btn.modulate.a, to):
		return
	create_tween().tween_property(_finish_btn, "modulate:a", to, 0.3)


func _remove_finish_button() -> void:
	_cancel_finish_hold()
	if is_instance_valid(_finish_btn):
		_finish_btn.queue_free()
	_finish_btn = null


func _on_finish_hold_start() -> void:
	if _finishing:
		return
	_cancel_finish_hold()
	_finish_hold_tween = create_tween()
	_finish_hold_tween.tween_method(_set_finish_fill, 0.0, 1.0, FINISH_HOLD_SECS)
	_finish_hold_tween.finished.connect(_finish_journey)


func _on_finish_hold_cancel() -> void:
	if _finishing:
		return
	_cancel_finish_hold()
	_set_finish_fill(0.0)  # reset the fill label


func _cancel_finish_hold() -> void:
	if _finish_hold_tween != null and _finish_hold_tween.is_valid():
		_finish_hold_tween.kill()
	_finish_hold_tween = null


# Draws the hold progress into the button label as a small filling bar.
func _set_finish_fill(t: float) -> void:
	if not is_instance_valid(_finish_btn):
		return
	if t <= 0.0:
		_finish_btn.text = _FINISH_IDLE_TEXT
		return
	var filled: int = clampi(int(round(t * 6.0)), 0, 6)
	_finish_btn.text = "%s%s" % ["▰".repeat(filled), "▱".repeat(6 - filled)]


# FINISH confirmed: discard the in-progress round (no payout — the skip semantic), tear down any round
# effects, then JUMP to the designated aftercare node and play it through the normal pipeline. That
# node is the ENTRY to an off-graph aftercare SEQUENCE — its out-edges advance through the chain like
# any node, so a "you lose" storyboard → aftercare round → … plays in turn until a node with no exit
# reaches "done" → the end screen. No node designated → straight to the end screen. `_finishing` guards
# against a re-trigger from a late button_up (and suppresses the button on the aftercare rounds, so it
# can't loop).
func _finish_journey() -> void:
	if _finishing:
		return
	_finishing = true
	_cancel_finish_hold()
	_remove_finish_button()
	_video.stop()
	_end_timer.stop()
	FunscriptPlayer.Stop()
	ScoreService.DiscardRound()  # the in-progress round banks nothing (same as a skip)
	_exit_boss_mode()  # drop any active round effects / frames before leaving
	if _finish_node_id != "" and GameState.JumpToFinish(_finish_node_id):
		await _transition_swap(_load_current_item)  # fade into the aftercare node
	else:
		_transition_to_end_screen()


# Exit-to-menu hold-to-confirm. Begins on Esc-key-down or MENU-button-down; a centered overlay fills over
# EXIT_HOLD_SECS and leaves to the menu at completion. Releasing (key / button up) cancels before then.
func _begin_exit_hold() -> void:
	if _exiting:
		return
	_cancel_exit_hold()
	_show_exit_hold_overlay()
	_exit_hold_tween = create_tween()
	_exit_hold_tween.tween_method(_set_exit_hold_fill, 0.0, 1.0, EXIT_HOLD_SECS)
	_exit_hold_tween.finished.connect(_confirm_exit)


func _cancel_exit_hold() -> void:
	if _exit_hold_tween != null and _exit_hold_tween.is_valid():
		_exit_hold_tween.kill()
	_exit_hold_tween = null
	_hide_exit_hold_overlay()


func _confirm_exit() -> void:
	if _exiting:
		return
	_exiting = true
	_exit_hold_tween = null
	_hide_exit_hold_overlay()
	_go_to_menu()


# A centered "keep holding to exit" card with a filling bar, on its own layer above the HUD.
func _show_exit_hold_overlay() -> void:
	_hide_exit_hold_overlay()
	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 4
	_exit_hold_layer = layer
	add_child(layer)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)
	var card: PanelContainer = PanelContainer.new()
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.0, 0.06, 0.92)
	sb.border_color = UITheme.MAGENTA
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 16
	sb.content_margin_bottom = 16
	card.add_theme_stylebox_override("panel", sb)
	center.add_child(card)
	var vb: VBoxContainer = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	card.add_child(vb)
	var lbl: Label = Label.new()
	lbl.text = "HOLD TO EXIT TO MENU"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(lbl, UITheme.MAGENTA, 15, true)
	vb.add_child(lbl)
	var fill: Label = Label.new()
	fill.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(fill, UITheme.WHITE_SOFT, 18, false)
	vb.add_child(fill)
	_exit_hold_fill = fill
	_set_exit_hold_fill(0.0)


func _hide_exit_hold_overlay() -> void:
	if is_instance_valid(_exit_hold_layer):
		_exit_hold_layer.queue_free()
	_exit_hold_layer = null
	_exit_hold_fill = null


func _set_exit_hold_fill(t: float) -> void:
	if not is_instance_valid(_exit_hold_fill):
		return
	var filled: int = clampi(int(round(t * 8.0)), 0, 8)
	_exit_hold_fill.text = "%s%s" % ["▰".repeat(filled), "▱".repeat(8 - filled)]


# Same exit as the Bail Out item: no payout, marked on the route. One skip semantic, not two.
func _on_warmup_skip_pressed() -> void:
	_video.stop()
	_end_timer.stop()
	_show_save_toast("⏭  WARMUP SKIPPED")
	_on_round_ended(true)


func _remove_cleanse_button() -> void:
	if is_instance_valid(_effect_cleanse_btn):
		_effect_cleanse_btn.queue_free()
	_effect_cleanse_btn = null


func _on_cleanse_pressed() -> void:
	# Prefer a held Cleanse item (free); fall back to coins.
	if InventoryService.OwnsItem("cleanse"):
		InventoryService.ConsumeItem("cleanse")
	elif not CoinService.SpendCoins(_effect_cleanse_cost):
		_show_save_toast("✕  NEED ♦ %d OR A CLEANSE ITEM" % _effect_cleanse_cost)
		return
	_cleanse_curse()


# Lifts the active curse(s) mid-round: clears the effects, undoes hex side-effects,
# drops the overlay. Marks the round cleansed so it pays no endure reward.
func _cleanse_curse() -> void:
	_effect_resolved = true
	InventoryService.ClearBossEffects()
	_clear_curse_hexes()
	_show_hud()  # bring the HUD straight back if a Fog hex hid it
	_hide_effect_overlay()
	_remove_cleanse_button()
	_show_save_toast("✦  CLEANSED")


# Undoes every hex side-effect — sensory ones via SensoryFX, gameplay ones
# (HUD/pause/blackout) here. Safe to call when none are active (boss rounds,
# plain rounds) — each branch no-ops.
func _clear_curse_hexes() -> void:
	if _curse_no_pause:
		_curse_no_pause = false
		_pause_btn.disabled = false
	_video.visible = true  # undo a Blinded (blackout) hex
	# Drop THIS round's sensory and reconcile: the round's kinds ease out (they left the desired set),
	# while any active ITEM sensory persists until its own timer expires. (Full teardown on scene exit
	# is handled by SensoryFX._exit_tree, not here.)
	_round_sensory.clear()
	_reconcile_sensory()
	# Fog (hud_hide) is active-list-driven: round Fog clears once its boss effects are removed, while a
	# timed item Fog persists until its own timer expires — so reconcile rather than force the HUD back.
	_reconcile_hud_hide()


# Applies a "hex" curse — effects beyond the stroke (which FunscriptPlayer can't
# do). Sensory (visual/audio) kinds are handled by SensoryFX, with `intensity`
# (0–1) mapped through the catalog's imin/imax; the gameplay kinds are handled
# here. coin_penalty is read at round end, not applied here.
func _apply_hex(roll: Dictionary, intensity: float = 1.0) -> void:
	var kind: String = String(roll.get("kind", ""))
	# Sensory (visual/audio) kinds are collected for the reconcile pass, not applied here — so the
	# round's sensory shares one engine state with any active item sensory. "blackout" (Blinded) is a
	# sensory catalog entry SensoryFX does NOT own (the HUD hides the video for it), so it's excluded.
	if kind != "blackout" and JourneyData.is_sensory_kind(kind):
		_round_sensory.append({"roll": roll, "intensity": intensity})
		return
	# hud_hide (Fog) is reconciled from the active list in _reconcile_hud_hide (so round + item Fog share
	# one state), not applied here.
	match kind:
		"toll":
			var take: int = mini(int(roll.get("amount", TOLL_AMOUNT)), CoinService.Balance)
			if take > 0:
				CoinService.SpendCoins(take)
		"no_pause":
			_curse_no_pause = true
			_pause_btn.disabled = true


# Pushes the combined desired sensory set to SensoryFX: this round's own sensory (_round_sensory) plus
# every active ITEM sensory effect (timed — identified by start_time_ms, as the chips are). The engine
# applies additions, updates intensities, and fades out anything that left the set. Item sensory that
# outlives the round therefore keeps running until its timer expires. Cheap; safe to call often.
func _reconcile_sensory() -> void:
	if _sensory == null:
		return
	var requests: Array = _round_sensory.duplicate()
	for fx: Dictionary in InventoryService.GetActiveEffects():
		var kind: String = String(fx.get("kind", ""))
		if fx.has("start_time_ms") and kind != "blackout" and JourneyData.is_sensory_kind(kind):
			(
				requests
				. append(
					{
						"roll": JourneyData.sensory_entry_by_kind(kind),
						"intensity": float(fx.get("intensity", 1.0)),
					}
				)
			)
	_sensory.reconcile(requests)


# Applies one-shot ITEM effects (toll / interest / flag / counter) the moment they enter the active list
# from an activation, then consumes each so it fires exactly once. Only player-activated effects
# (start_time_ms) are handled — round versions apply at their own boundaries. Re-entrancy-guarded
# because ConsumeEffects re-emits ActiveEffectsChanged.
func _apply_oneshot_item_effects() -> void:
	if _applying_oneshots:
		return
	_applying_oneshots = true
	var applied: Dictionary = {}  # kinds actually present, consumed once each below
	for fx: Dictionary in InventoryService.GetActiveEffects():
		if not fx.has("start_time_ms"):
			continue
		match String(fx.get("kind", "")):
			"toll":
				var take: int = mini(int(fx.get("amount", TOLL_AMOUNT)), CoinService.Balance)
				if take > 0:
					CoinService.SpendCoins(take)
					_show_pop(
						"TOLL", "-♦ %d" % take, "→ ♦ %d" % CoinService.Balance, UITheme.MAGENTA
					)
				applied["toll"] = true
			"interest":
				_grant_coins(roundi(CoinService.Balance * float(fx.get("pct", INTEREST_PCT))))
				applied["interest"] = true
			"flag":
				var fname: String = str(fx.get("flag", "")).strip_edges()
				if fname != "":
					GameState.ApplyItemFlagsCounters({"set_flags": [fname]})
				applied["flag"] = true
			"counter":
				var cname: String = str(fx.get("counter", "")).strip_edges()
				if cname != "":
					GameState.ApplyItemFlagsCounters(
						{"set_counters": {cname: int(fx.get("delta", 1))}}
					)
				applied["counter"] = true
	for kind: String in applied:
		InventoryService.ConsumeEffects(kind)
	_applying_oneshots = false


# Hides the HUD while any active effect (round Fog OR a timed item Fog) is `hud_hide`, else restores it.
# Driven off the active list so round + item Fog share one state and item Fog persists across rounds.
func _reconcile_hud_hide() -> void:
	var want_hidden: bool = false
	for fx: Dictionary in InventoryService.GetActiveEffects():
		if String(fx.get("kind", "")) == "hud_hide":
			want_hidden = true
			break
	if want_hidden == _curse_hud_hidden:
		return
	_curse_hud_hidden = want_hidden
	if want_hidden:
		_hud.visible = false
	else:
		_show_hud()  # restore + rejoin the idle-fade cycle


# Tears down boss / effect state at round end. Safe to call on plain rounds.
func _exit_boss_mode() -> void:
	if not _is_boss_round and not _is_effect_round:
		return
	# Undo any hex side-effects before clearing the flags.
	_clear_curse_hexes()
	_hide_effect_overlay()
	_remove_cleanse_button()
	# A "Lingering" boon un-freezes the effect clock at round end.
	if _effect_lingering:
		_effect_lingering = false
		InventoryService.SetPaused(_paused)
	_is_boss_round = false
	_is_effect_round = false
	InventoryService.ClearBossEffects()
	_inv_btn.disabled = false
	if _boss_frame != null:
		_boss_frame.visible = false


# Converts a saved boss modifier ({kind, factor?, min?, max?}) into a full
# effect dict the active-effects pipeline understands.
func _make_boss_effect(mod: Dictionary) -> Dictionary:
	var kind: String = mod.get("kind", "")
	var effect: Dictionary = {
		"id": "boss_" + kind,
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
	_beat_bar = BeatBar.new()
	_beat_bar.anchor_left = 0.0
	_beat_bar.anchor_right = 1.0
	_beat_bar.anchor_top = 1.0
	_beat_bar.anchor_bottom = 1.0
	_beat_bar.offset_left = 0.0
	_beat_bar.offset_right = 0.0
	_beat_bar.offset_top = -120.0
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
	s.border_width_left = 6
	s.border_width_right = 6
	s.border_width_top = 6
	s.border_width_bottom = 6
	_boss_frame.add_theme_stylebox_override("panel", s)
	add_child(_boss_frame)
	_send_frame_behind_hud(_boss_frame)


# Decorative round frames (boss/curse/blessing borders) must draw BEHIND the HUD
# so their edge border doesn't sit on top of the progress bar / HUD bar. Call
# right after the frame is added to the game-loop root.
func _send_frame_behind_hud(frame: Control) -> void:
	if is_instance_valid(_hud):
		move_child(frame, _hud.get_index())


# Builds the effect-round overlay — an optional coloured edge border (author-toggled,
# no screen tint) — and the SensoryFX engine, whose overlay stack (Murk/Tunnel/Bloodshot/
# Static/Flicker/Strobe) slots below the frame, preserving the original draw order. The
# border colour is set per-round in _show_effect_overlay. Hidden until used.
func _build_effect_overlay() -> void:
	# Non-gameplay (sensory) modifier engine — owns its overlays, the composable
	# video shader, the VideoFX audio bus, tremor, and mute.
	_sensory = SensoryFX.new()
	add_child(_sensory)
	_sensory.setup(_video, self)

	_effect_frame = Panel.new()
	_effect_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_effect_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_effect_frame.visible = false
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	s.set_border_width_all(5)
	_effect_frame.add_theme_stylebox_override("panel", s)
	add_child(_effect_frame)
	_send_frame_behind_hud(_effect_frame)


# Shows the coloured edge border for this round — but only when the author enabled it.
func _show_effect_overlay(frame_color: Color, show_border: bool) -> void:
	if _effect_frame == null:
		return
	if not show_border:
		_effect_frame.visible = false
		return
	var s: StyleBox = _effect_frame.get_theme_stylebox("panel")
	if s is StyleBoxFlat:
		(s as StyleBoxFlat).border_color = frame_color
	_effect_frame.visible = true


func _hide_effect_overlay() -> void:
	if _effect_frame != null:
		_effect_frame.visible = false


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

	# Tremor hex — per-frame jitter (zero when inactive). _fit_video_cover runs
	# every frame from _process, so this re-applies on top of the clean fit.
	if _sensory != null:
		_video.position += _sensory.tremor_offset()


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
		push_warning(
			"GameLoop: FFmpegVideoStream not found — install EIRTeam.FFmpeg for MP4 support. Running funscript-only."
		)
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
	var dur_ms: int = _active_round_length_ms
	if dur_ms > 0:
		_end_timer.wait_time = dur_ms / 1000.0
		_end_timer.start()
	else:
		# Unknown length — let the player advance manually (pause button becomes skip)
		_pause_btn.text = "> SKIP"


# ---------------------------------------------------------------------------
# Round / scene transitions
# ---------------------------------------------------------------------------


func _on_round_ended(skipped: bool = false) -> void:
	if _round_ended_guard:
		return
	_round_ended_guard = true
	_remove_warmup_skip_button()
	_remove_finish_button()  # FINISH is a during-round affordance; it doesn't carry into overlays
	_handy_stop()  # the device would otherwise keep playing into the transition
	# Extract the name here in GDScript where Dictionary access is reliable,
	# then pass it explicitly so C# never needs to look up the key itself.
	var _cur: Dictionary = GameState.CurrentRound()
	var _cur_name: String = _cur.get("name", "") as String
	# Use the effective length captured at round start — a pool round's own
	# length_ms is 0 (its media lives in entries; the chosen one was swapped in).
	GameState.LogRound(_cur, _cur_name, _active_round_length_ms, skipped)

	# Append to the GDScript-side round-name log (see _ready). EndScreen reads
	# this directly, avoiding any potential C#→GDScript Dictionary marshalling
	# quirks for the name string.
	var _names: PackedStringArray = (
		GameState.get_meta("_round_names", PackedStringArray()) as PackedStringArray
	)
	_names.append(_cur_name)
	GameState.set_meta("_round_names", _names)
	# A skipped round banks nothing: the partial score is discarded rather than added, so
	# LastRoundScore still reports the last round actually played (score-based forks read it).
	if skipped:
		ScoreService.DiscardRound()
	else:
		ScoreService.EndRound()
	FunscriptPlayer.Stop()
	# Capture coin modifiers BEFORE _exit_boss_mode clears the boss-effect list:
	# a "Fortune" boon (coin_jackpot) and a "Greed"/"Pauper" curse (coin_penalty)
	# both live there, alongside any active shop jackpot.
	var jackpot_factor: float = 1.0
	var penalty_factor: float = 1.0
	for fx: Dictionary in InventoryService.GetActiveEffects():
		match fx.get("kind", ""):
			"coin_jackpot":
				jackpot_factor *= float(fx.get("factor", 1.0))
			"coin_penalty":
				penalty_factor *= float(fx.get("factor", 1.0))
	# Endure-payout: a resolvable effect round carried to the end without cleansing
	# pays its endure_reward bonus. Captured before _exit_boss_mode clears the flag.
	var endure_reward: int = 0
	if _effect_resolvable and not _effect_resolved:
		var nr: Dictionary = JourneyData.normalize_effect_round(GameState.CurrentRound())
		endure_reward = int(nr.get("endure_reward", 0))
	# Tear down boss / effect state (modifiers, lockout, frames) if active.
	_exit_boss_mode()

	var coins: int = GameState.CurrentRound().get("coins", 0)
	coins = roundi(coins * jackpot_factor)
	# Greed/Pauper curse: coins reduced (captured above, before effects cleared).
	coins = roundi(coins * penalty_factor)
	# Consume the item coin effects so each activation settles exactly one round's payout (they don't
	# expire on a timer — see InventoryService._MakeActiveEffect). Boss-round Fortune/Greed already went
	# with _exit_boss_mode above; ConsumeEffects only touches the player-activated _active list.
	InventoryService.ConsumeEffects("coin_jackpot")
	InventoryService.ConsumeEffects("coin_penalty")
	# Endure reward: bonus for carrying a curse to the end (on top of the round
	# coins, so it survives a Greed penalty).
	coins += endure_reward
	# Skipping forfeits everything the round would have paid: coins, the endure bonus, and the
	# item reward. _exit_boss_mode still ran above, so no effect leaks into the next round.
	if not skipped:
		# Bestow the round's counters at its END (see GameState.EnterCurrent) — the node is still
		# current here (Advance runs inside the transition below). A skipped/finished round banks
		# nothing, so its counters are forfeited alongside the coins and item reward.
		GameState.ApplyCurrentNodeCounters()
		_grant_coins(coins)
		if endure_reward > 0:
			_show_save_toast("✦  CURSE ENDURED  +♦ %d" % endure_reward)
		# Optional item reward — granted when the round ends (parity with storyboards). Read
		# from `_cur` (still current — Advance happens inside the transition).
		_grant_item(str(_cur.get("award_item", "")))

	if GameState.IsLastRound():
		_transition_to_end_screen()
		return
	await _transition_swap(
		func() -> void:
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
	tween_in.tween_property(_transition, "modulate:a", 1.0, TRANSITION_FADE_TIME).set_ease(
		Tween.EASE_IN
	)
	await tween_in.finished

	# Black now fully covers the screen — including any overlay we're leaving.
	# Overlays deliberately don't free themselves (see _show_*_screen), so they
	# stay visible and dim into the black instead of vanishing and flashing the
	# play area behind them. Free it now, under cover of the opaque black.
	_free_current_overlay()

	# Hide the HUD under the black so it can't flash in at full opacity when the
	# black clears; it's faded back in below once we land on a round.
	_hud.modulate.a = 0.0

	# Hold on the black, then run the swap so the next round's video loads behind it.
	await get_tree().create_timer(TRANSITION_HOLD_TIME).timeout
	swap_action.call()

	# Hold the black until the next round's video actually has a frame, so the
	# fade never reveals the bare background between rounds.
	await _await_video_ready()

	var tween_out: Tween = create_tween()
	tween_out.tween_property(_transition, "modulate:a", 0.0, TRANSITION_FADE_TIME).set_ease(
		Tween.EASE_OUT
	)
	await tween_out.finished

	_transition.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Fade the HUD back in only when we've landed on a round — the gates (fork / shop /
	# storyboard / checkpoint) cover the screen and own their own UI.
	if not (
		GameState.CurrentItemType()
		in ["fork", "shop", "storyboard", "checkpoint", "loop_start", "loop_end"]
	):
		_show_hud(true)


# Waits until the video player has produced a frame (or a short cap elapses), so
# a round transition doesn't reveal the background before the video renders.
# Returns immediately when no video is playing (no-video rounds / overlays).
func _await_video_ready() -> void:
	if not _video.is_playing():
		return
	for _i in 90:  # ~1.5s cap so a stalled or failed decode never hangs the fade
		var tex: Texture2D = _video.get_video_texture()
		if tex != null and tex.get_size().x > 0.0:
			return
		await get_tree().process_frame


# Frees the overlay we're transitioning away from. Called from _transition_swap
# once the black is opaque, so the overlay dims into the black instead of
# vanishing and exposing the play area. No-op for round-to-round transitions.
func _free_current_overlay() -> void:
	if is_instance_valid(_current_overlay):
		_current_overlay.queue_free()
	_current_overlay = null


# ---------------------------------------------------------------------------
# Journey map — read-only GraphView of the authored graph with a "you are here"
# marker. Opened on demand: the HUD ◇ MAP button, the M key, or the map button on
# a shop / storyboard / interactive-fork overlay. Availability is authored per
# journey (_map_enabled); a journey can hide it to keep its layout a surprise.
# ---------------------------------------------------------------------------


# Builds the persistent map (hidden) on its own CanvasLayer, plus the HUD map
# button. Self-contained: reads the journey accent locally. Skipped entirely when
# the author has disabled the map for this journey — _map_view stays null, so
# _open_map_viewer no-ops and the overlay map buttons aren't shown.
# Pushes the journey's map backdrop STACK (if any) onto a map GraphView — always fully visible beneath the
# (possibly fogged) nodes, layered in order. For a composed rendition the stack already carries the base's
# layers plus each overlay's (see compose). Placement rides GameState.Journey, matching the editor exactly.
func _apply_map_backdrop_to(view: Node) -> void:
	var stack: Array = GameState.Journey.get("map_backdrops", [])
	if stack.is_empty():
		return
	var render: Array = []
	for e: Variant in stack:
		var b: Dictionary = e
		var img: Image = JourneyData.load_image_smart(str(b.get("path", "")))
		if img == null:
			continue
		(
			render
			. append(
				{
					"texture": ImageTexture.create_from_image(img),
					"offset": b.get("offset", Vector2.ZERO),
					"scale": float(b.get("scale", 1.0)),
					"opacity": float(b.get("opacity", 0.6)),
					"rotation": float(b.get("rotation", 0.0)),
				}
			)
		)
	view.set_backdrops(render)


func _build_map() -> void:
	if not _map_enabled:
		return
	var accent: Color = UITheme.PURPLE_BRIGHT

	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 2  # above TransitionLayer (1) and the overlays, so the map sits on top
	add_child(layer)

	_map_overlay = Control.new()
	_map_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_overlay.visible = false
	layer.add_child(_map_overlay)

	var backdrop: ColorRect = ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.0, 0.0, 0.85)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP  # block clicks reaching the game
	_map_overlay.add_child(backdrop)

	_map_view = GraphViewScene.instantiate()
	_map_view.map_mode = true
	_map_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_view.offset_top = 56
	_map_view.offset_bottom = -16
	_map_view.offset_left = 16
	_map_view.offset_right = -16
	_map_overlay.add_child(_map_view)
	_map_view.set_marker_color(accent)
	# Render the map from the journey GRAPH (the same DAG the runtime walks). Edges show the real
	# flow — including authored skips / converges / islands the old nested render couldn't draw —
	# so there's no separate redirect overlay any more. Format-2 journeys carry the author's node
	# positions; legacy (migrated) ones don't, so seed the layout the same way the editor does.
	# Copy the nodes first so seeding never mutates GameState.Journey.
	var map_graph: Dictionary = {
		"start": str(GameState.Journey.get("start", "")),
		"nodes": (GameState.Journey.get("nodes", {}) as Dictionary).duplicate(true),
	}
	# Loops are hidden on the player map by default — splice the markers out so the flow reads clean.
	# The author opts in per journey to reveal them.
	if not _show_loops_on_map:
		JourneyGraph.strip_loop_markers(map_graph)
	for nid: String in map_graph["nodes"]:
		if not (map_graph["nodes"][nid] as Dictionary).has("pos"):
			GraphLayout.seed_positions(map_graph)  # any node missing a pos → seed the whole graph
			break
	_map_view.set_graph(map_graph)
	_apply_map_backdrop_to(_map_view)

	var title: Label = Label.new()
	title.text = "◇  JOURNEY MAP"
	title.add_theme_color_override("font_color", accent)
	title.add_theme_font_size_override("font_size", 18)
	title.position = Vector2(22, 16)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_overlay.add_child(title)

	var hint: Label = Label.new()
	hint.text = "DRAG TO PAN  ·  SCROLL TO ZOOM  ·  ESC TO CLOSE"
	hint.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	hint.add_theme_font_size_override("font_size", 11)
	hint.position = Vector2(24, 39)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_overlay.add_child(hint)

	_map_close_btn = Button.new()
	_map_close_btn.text = "✕ CLOSE"
	_map_close_btn.focus_mode = Control.FOCUS_NONE
	_style_button(_map_close_btn, UITheme.MAGENTA)
	_map_close_btn.anchor_left = 1.0
	_map_close_btn.anchor_right = 1.0
	_map_close_btn.offset_left = -132
	_map_close_btn.offset_right = -16
	_map_close_btn.offset_top = 14
	_map_close_btn.offset_bottom = 48
	_map_close_btn.pressed.connect(_close_map_viewer)
	_map_overlay.add_child(_map_close_btn)

	# HUD map button, inserted before the inventory button.
	var map_btn: Button = Button.new()
	map_btn.text = "◇ MAP"
	map_btn.focus_mode = Control.FOCUS_NONE
	map_btn.tooltip_text = "View the journey map (M)"
	_style_button(map_btn, accent)
	_hud_layout.add_child(map_btn)
	_hud_layout.move_child(map_btn, _inv_btn.get_index())
	map_btn.pressed.connect(_on_map_pressed)
	map_btn.mouse_entered.connect(_show_hud)


func _on_map_pressed() -> void:
	if _map_open:
		_close_map_viewer()
	else:
		_open_map_viewer()


func _open_map_viewer() -> void:
	if _map_open or _map_view == null:
		return
	_map_open = true
	# Suspend the underlying overlay's input so a click/key meant for the map can't
	# leak through to it (shop/storyboard handle raw _input, which a backdrop's
	# mouse_filter does NOT block). The map's own modal handling stays in GameLoop.
	_set_overlay_input_enabled(false)
	_map_close_btn.visible = true
	if _map_fog:
		# Fog of war (author opt-in): re-render the map for the current discovery (refreshed each open so
		# newly-played nodes appear). set_fog defers its relayout — and that relayout frees the marker —
		# so place the marker / centre AFTER it settles. Overlay stays hidden until then, so no flash.
		_map_view.set_fog(true, GameState.DiscoveredNodes(), _map_fog_reveal)
		call_deferred("_finish_open_map_viewer")
	else:
		_finish_open_map_viewer()


# Marker + centre + fade-in for the open map. Split out so the fog path can run it after its relayout.
func _finish_open_map_viewer() -> void:
	if not _map_open or _map_view == null:
		return
	# The graph map highlights the current node by its stable id (GameState walks the DAG by id).
	var node_id: String = GameState.CurrentNodeId()
	_map_view.set_marker_at(node_id)
	_map_view.center_on(node_id)
	_map_overlay.modulate.a = 0.0
	_map_overlay.visible = true
	create_tween().tween_property(_map_overlay, "modulate:a", 1.0, 0.18)


func _close_map_viewer() -> void:
	if not _map_open:
		return
	_map_open = false
	# Hand input back to the overlay (shop / storyboard / fork) underneath.
	_set_overlay_input_enabled(true)
	var t: Tween = create_tween()
	t.tween_property(_map_overlay, "modulate:a", 0.0, 0.15)
	await t.finished
	_map_overlay.visible = false


# Suspends or restores the active overlay's input callbacks while the map is open.
# No-op outside an overlay (plain in-round map open) — _current_overlay is null then.
# Also toggles _process so a storyboard/fork auto-advance countdown pauses under the map viewer.
func _set_overlay_input_enabled(enabled: bool) -> void:
	if is_instance_valid(_current_overlay):
		_current_overlay.set_process_input(enabled)
		_current_overlay.set_process_unhandled_input(enabled)
		_current_overlay.set_process(enabled)


func _go_to_menu() -> void:
	_video.stop()
	FunscriptPlayer.Stop()
	_handy_stop()
	# In a test play, "back to menu" (button or Esc) returns to the builder the
	# preview was launched from, not the main menu.
	if _test_mode:
		_exit_test_to_builder()
		return
	# Quitting mid-journey is an abandoned run — unless we already accounted for
	# this run (completed it, or left via Save & Quit to resume later).
	if not _run_accounted:
		_record_run(false)
	Transition.change_scene("res://scenes/main/Main.tscn")


# Called from every "journey finished" exit site. Wipes the save file so the
# next time the player opens the journey it offers a fresh start instead of
# a stale Resume button pointing at a completed run.
func _transition_to_end_screen() -> void:
	# A test play has no results screen — reaching the end just returns to the
	# builder. Crucially, skip the save delete: a preview must never touch a
	# real player's run-save for this journey.
	if _test_mode:
		_exit_test_to_builder()
		return
	_record_run(true)  # completed run → scoreboard
	_capture_completion_carryover()  # feature #5: stash Part-1 end-state so an installed sequel can resume
	JourneySaveService.delete_save(GameState.Journey.get("folder_name", ""))
	Transition.change_scene("res://scenes/end_screen/EndScreen.tscn")


# Feature #5: on completing a BASE journey, stash its end-state keyed by the base's JourneyId so an
# installed rendition (a sequel) can resume from the ending the player reached — carrying coins, score,
# items, flags, and counters. Skipped for a rendition run (that IS Part 2; its folder_name is namespaced
# `…__rend_…`) and when the base has no id to key by. The payload mirrors _write_journey_save's run-state
# snapshot plus `reached_node`, the ending finished on, which the resume path matches to a rendition anchor.
func _capture_completion_carryover() -> void:
	var journey: Dictionary = GameState.Journey
	var base_id: String = str(journey.get("journey_id", ""))
	if base_id == "":
		return
	# A COMPOSED (Part-2) run reaching the end CONSUMES the Part-1 carryover — you've played the sequel
	# through, so "Resume Part 2" shouldn't linger (single-use, like a resume save). The composed journey
	# carries the base's JourneyId, which is what the carryover is keyed by. Bailing out early (no end
	# screen) leaves it intact, so an unfinished sequel can still be retried from Part 1.
	if str(journey.get("folder_name", "")).contains("__rend_"):
		JourneySaveService.delete_carryover(base_id)
		return
	var score_data: Dictionary = ScoreService.CaptureSaveData()
	var payload: Dictionary = {
		"coins": CoinService.Balance,
		"score": score_data.get("score", 0),
		"total_actions": score_data.get("strokes", 0),
		"inventory": InventoryService.CaptureSaveData(),
	}
	payload.merge(GameState.CaptureSaveData())  # current_node, flags, counters, discovered, pool clips
	payload["reached_node"] = str(payload.get("current_node", ""))  # the ending the sequel anchors to
	JourneySaveService.write_carryover(base_id, payload)


# Records this run's outcome to the journey's local scoreboard. `completed` is
# true when the journey reached the end screen, false for an abandoned (quit)
# run — which logs the score-so-far and how far the player got. No-op in test
# mode; sets _run_accounted so a later menu exit can't double-record.
func _record_run(completed: bool) -> void:
	_run_accounted = true
	if _test_mode:
		return
	var folder: String = GameState.Journey.get("folder_name", "")
	if folder.is_empty():
		return
	var total: int = GameState.TotalRounds()
	var reached: int = total if completed else clampi(GameState.RoundNumber, 0, total)
	var rank: int = (
		ScoreboardService
		. add_run(
			folder,
			{
				"score": ScoreService.TotalScore,
				"completed": completed,
				"rounds_done": reached,
				"rounds_total": total,
			}
		)
	)
	# The end screen's high-score flash reads this (completed runs only —
	# an abandoned run's rank is never celebrated).
	if completed:
		GameState.set_meta("_run_rank", rank)


# Returns from a test play to the builder, reloading the same journey so the
# author lands back on the graph they launched from. The journey was saved
# before the test started, so the on-disk state the builder reloads is exactly
# what was being edited — no in-memory state needs to be carried across.
func _exit_test_to_builder() -> void:
	_video.stop()
	FunscriptPlayer.Stop()
	JourneyBuilder.edit_journey = _test_return_journey
	Transition.change_scene("res://scenes/journey_builder/JourneyBuilder.tscn")


# Top-center "TEST MODE" indicator shown for the duration of a test play, so the
# author always knows this is a preview and how to leave it.
func _show_test_banner() -> void:
	var text: String = "▶  TEST MODE  —  ESC TO EXIT"
	if _test_seed_score > 0 or _test_seed_coins > 0:
		text += "    (SEED  %d PTS / ♦ %d)" % [_test_seed_score, _test_seed_coins]
	var banner: Label = Label.new()
	banner.text = text
	banner.add_theme_color_override("font_color", UITheme.AMBER)
	banner.add_theme_font_size_override("font_size", 16)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.anchor_left = 0.0
	banner.anchor_right = 1.0
	banner.offset_top = 12
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(banner)


# ---------------------------------------------------------------------------
# Save / Resume
# ---------------------------------------------------------------------------


# Writes a save for the current journey at the start of the current round.
# Used by both the checkpoint banner's "Save & Quit" button and the save_now
# inventory item. Returns true on success.
#
# Save point semantics: whatever round the player is *currently in* is the
# resume point. We don't preserve mid-round position — the player restarts
# the current round from action 0 on resume. This keeps the save model
# simple and predictable (you replay the round you were doing).
func _write_journey_save() -> bool:
	# Real saves are disabled during a test play — a preview must never write a
	# run-save (the Safe Word item and checkpoint Save & Quit both route here).
	if _test_mode:
		return false
	var journey: Dictionary = GameState.Journey
	var folder_name: String = journey.get("folder_name", "")
	if folder_name == "":
		push_warning("GameLoop: cannot save — journey has no folder_name")
		return false

	# Stitch together one payload from each service that owns part of the run.
	# Inventory carries through; active effects do NOT (clean modifier slate
	# on resume — see InventoryService.LoadFromSave for the rationale).
	var score_data: Dictionary = ScoreService.CaptureSaveData()
	var payload: Dictionary = {
		"coins": CoinService.Balance,
		"score": score_data.get("score", 0),
		"total_actions": score_data.get("strokes", 0),
		"inventory": InventoryService.CaptureSaveData(),
		"round_names": GameState.get_meta("_round_names", PackedStringArray()) as PackedStringArray,
		"route_trail": GameState.get_meta("_route_trail", []),
	}
	# GameState owns the graph-native position fields (current_node,
	# rounds_entered, flags, discovered) — merge them in under their own names so
	# LoadFromSave finds them. (Re-keying these through the old tree-model names
	# sequence_index/sequence/fork_depth silently dropped them, which reset every
	# resume to the journey start and lost pre-save flags + fog discovery.)
	payload.merge(GameState.CaptureSaveData())
	return JourneySaveService.write_save(folder_name, payload)


# Triggered by the checkpoint banner's "Save & Quit" button (also by the
# save_now item — both flow through here). Writes the save, then returns to
# the catalogue with the same cleanup as a regular Back-to-Menu.
func _on_save_and_quit() -> void:
	# In test mode there's no real save to write; just leave (back to the builder).
	if _test_mode:
		_go_to_menu()
		return
	var ok: bool = _write_journey_save()
	if not ok:
		push_warning("GameLoop: save failed — returning to menu without saving")
	# Saved for resume — this isn't an abandoned run, so don't let the menu exit
	# log it to the scoreboard.
	_run_accounted = true
	_go_to_menu()


# Triggered when the save_now utility item is consumed. Unlike the checkpoint
# banner's Save & Quit, the run keeps going — the item just writes a save the
# player can return to later. Boss-round lockout is enforced by the inventory
# panel which disables item use during bosses, so we don't need to check
# round type here.
# skip_round item: end this round here, paying nothing. Routed through the normal round-end so
# every teardown still happens (boss/effect state, funscript stop, the Handy stop, the play log
# and the transition) — only the payouts are skipped. Guarded against firing while a non-round
# item is on screen: the inventory is reachable from shops and storyboards too.
func _on_skip_item_used() -> void:
	if str(GameState.CurrentItemType()) != "round":
		_show_save_toast("✕  NOTHING TO SKIP")
		return
	_video.stop()
	# A funscript-only round is driven by _end_timer, not the video clock — leave it running and
	# it would end the NEXT round early.
	_end_timer.stop()
	_show_save_toast("⏭  ROUND SKIPPED")
	_on_round_ended(true)


func _on_save_item_used() -> void:
	if _test_mode:
		_show_save_toast("✕  SAVING DISABLED IN TEST")
		return
	var ok: bool = _write_journey_save()
	if ok:
		_show_save_toast("✓  PROGRESS SAVED")
	else:
		_show_save_toast("✕  SAVE FAILED")


# A player-visible counter changed → transient top-right pop. Hidden counters (not in the journey's
# ShownCounters) fire the signal but show nothing — they gate silently. The persistent value list
# lives in the inventory panel.
func _on_counter_changed(name: String, value: int, delta: int) -> void:
	if name in _shown_counters:
		_show_counter_pop(name, value, delta)


# Lowest free vertical slot for a counter pop, so simultaneous changes STACK instead of overlapping.
# A slot is held for the pop's lifetime and released in _show_pop; freeing the lowest means a
# vanished pop's row is reused top-down (no reflow of the survivors — they hold their place).
func _alloc_counter_pop_slot() -> int:
	var i: int = 0
	while _counter_pop_slots.has(i):
		i += 1
	_counter_pop_slots[i] = true
	return i


# A counter changed: "BELT  +1  → 3". Green for a gain, magenta for a loss.
func _show_counter_pop(name: String, value: int, delta: int) -> void:
	_show_pop(
		name, "%+d" % delta, "→ %d" % value, UITheme.SUCCESS if delta >= 0 else UITheme.MAGENTA
	)


# Coins awarded: "COINS  +♦ 25  → ♦ 140". Rewards used to land silently, so the only clue was
# the HUD number ticking — easy to miss mid-round.
func _grant_coins(amount: int) -> void:
	if amount <= 0:
		return
	CoinService.AddCoins(amount)
	_show_pop("COINS", "+♦ %d" % amount, "→ ♦ %d" % CoinService.Balance, UITheme.AMBER)


# Grants an item and announces it. Returns false when the id no longer resolves (deleted from
# the registry after authoring) — the caller stays silent rather than showing a misleading pop.
func _grant_item(item_id: String) -> bool:
	if item_id == "":
		return false
	var data: Dictionary = InventoryService.GetItemData(item_id)
	if data.is_empty():
		return false
	InventoryService.AddItem(item_id)
	_show_pop("✦ RECEIVED", str(data.get("name", item_id)).to_upper(), "", UITheme.CYAN)
	return true


# Slides a chip in from the right, holds, slides out. Non-blocking. Parented to the GameLoop
# root (not the HUD, which hides during play). `tail` may be "" for a two-part chip.
func _show_pop(title: String, detail: String, tail: String, accent: Color) -> void:
	var slot: int = _alloc_counter_pop_slot()

	var pop: PanelContainer = PanelContainer.new()
	pop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(
		UITheme.PANEL_BG_DEEP.r, UITheme.PANEL_BG_DEEP.g, UITheme.PANEL_BG_DEEP.b, 0.92
	)
	s.border_color = accent
	s.set_border_width_all(2)
	s.set_corner_radius_all(6)
	s.set_content_margin_all(10)
	pop.add_theme_stylebox_override("panel", s)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	pop.add_child(row)
	var title_lbl: Label = Label.new()
	title_lbl.text = title.to_upper()
	UITheme.style_label(title_lbl, UITheme.WHITE_SOFT, 13, true)
	row.add_child(title_lbl)
	var detail_lbl: Label = Label.new()
	detail_lbl.text = detail
	UITheme.style_label(detail_lbl, accent, 13, true)
	row.add_child(detail_lbl)
	if tail != "":
		var tail_lbl: Label = Label.new()
		tail_lbl.text = tail
		UITheme.style_label(tail_lbl, UITheme.DARK_TEXT, 13, true)
		row.add_child(tail_lbl)

	add_child(pop)
	await get_tree().process_frame  # let it size before we place it
	if not is_instance_valid(pop):
		_counter_pop_slots.erase(slot)
		return
	var screen_w: float = get_viewport_rect().size.x
	var off_x: float = screen_w + 8.0  # off-screen right
	var target_x: float = screen_w - pop.size.x - 16.0
	# Stack downward from below the HUD bar, one row per slot.
	pop.position = Vector2(off_x, COUNTER_POP_BASE_Y + slot * COUNTER_POP_STEP)
	pop.modulate.a = 0.0

	var tin: Tween = create_tween().set_parallel(true)
	tin.tween_property(pop, "position:x", target_x, 0.35).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	tin.tween_property(pop, "modulate:a", 1.0, 0.25)
	await tin.finished
	await get_tree().create_timer(COUNTER_POP_HOLD_SECS).timeout
	if not is_instance_valid(pop):
		_counter_pop_slots.erase(slot)
		return
	var tout: Tween = create_tween().set_parallel(true)
	tout.tween_property(pop, "position:x", off_x, 0.3).set_ease(Tween.EASE_IN)
	tout.tween_property(pop, "modulate:a", 0.0, 0.3)
	await tout.finished
	_counter_pop_slots.erase(slot)
	if is_instance_valid(pop):
		pop.queue_free()


# Brief auto-dismissing notification used after the save_now item fires. Keeps
# the player in the round instead of pulling them into a modal.
func _show_save_toast(text: String, hold: float = 1.6) -> void:
	var toast: PanelContainer = PanelContainer.new()
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast.anchor_left = 0.5
	toast.anchor_right = 0.5
	toast.anchor_top = 0.0
	toast.anchor_bottom = 0.0
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast.offset_top = 70  # below the device-warning banner

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(UITheme.AMBER.r, UITheme.AMBER.g, UITheme.AMBER.b, 0.92)
	s.border_color = UITheme.AMBER
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_width_top = 2
	s.border_width_bottom = 2
	s.content_margin_left = 20
	s.content_margin_right = 20
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	toast.add_theme_stylebox_override("panel", s)

	var lbl: Label = Label.new()
	lbl.text = text
	UITheme.style_label(lbl, UITheme.WHITE_SOFT, 13, true)
	toast.add_child(lbl)
	add_child(toast)

	# Hold, then fade out (default ~2s total; callers with an actionable message pass a longer hold).
	var tween: Tween = create_tween()
	tween.tween_interval(hold)
	tween.tween_property(toast, "modulate:a", 0.0, 0.4)
	tween.finished.connect(func() -> void: toast.queue_free())


func _on_options_pressed() -> void:
	_video.paused = true
	FunscriptPlayer.Pause()
	_options_open = true  # counts as an active pause for the score penalty
	# Freeze the active-effect clock while the Options overlay is open.
	InventoryService.SetPaused(true)
	_handy_pause()
	_update_muffle()  # before add_child so the overlay sits above the dim
	var opts: Control = OptionsScene.instantiate()
	opts.overlay_mode = true
	opts.tree_exiting.connect(_on_options_closed)
	add_child(opts)


func _on_options_closed() -> void:
	_options_open = false
	_update_muffle()
	# Only resume if the round was not separately paused via the pause button —
	# in that case the effect clock must stay frozen until the player resumes.
	if not _paused:
		_video.paused = false
		FunscriptPlayer.Resume()
		InventoryService.SetPaused(false)
		_handy_resume()
	# Output mode may have changed in Options — re-evaluate the disconnect
	# banner against whatever backend is now selected.
	_refresh_device_warning()
	# Beat-bar visibility setting may have toggled — create or destroy the bar
	# to match the new state without requiring the user to exit the journey.
	_refresh_beat_bar_visibility()
	# Stroke range / delay may have changed in Options — re-sync the Quick Settings drawer if open.
	if is_instance_valid(_session_panel):
		_session_panel.resync()


# ---------------------------------------------------------------------------
# Pause / HUD
# ---------------------------------------------------------------------------


func _toggle_pause() -> void:
	# A "Restless" curse forbids pausing this round.
	if _curse_no_pause and not _paused:
		_show_save_toast("✕  RESTLESS — CAN'T PAUSE")
		return
	_paused = not _paused
	_video.paused = _paused
	# Freeze the active-effect clock while paused — or for the whole round under a
	# Lingering boon, so unpausing doesn't restart the countdown.
	InventoryService.SetPaused(_paused or _effect_lingering)
	if _paused:
		FunscriptPlayer.Pause()
		_pause_btn.text = "> RESUME"
		_handy_pause()
	else:
		FunscriptPlayer.Resume()
		_pause_btn.text = "|| PAUSE"
		_handy_resume()
	_update_muffle()


# ---------------------------------------------------------------------------
# The Handy (direct WiFi stroke)
# ---------------------------------------------------------------------------

# The Handy plays the round's script via Handy's v3 HSP streaming API — see
# HandyService. GameLoop feeds the point buffer ahead of the video clock and
# starts/pauses/resumes/stops around it; FunscriptPlayer keeps running
# deviceless for scoring, the beat bar, and any routed vibes. Stroke-modifying
# effects therefore never reach this device (disclosed in Options + run-start toast).
var _handy_active: bool = false  # stroke target is the Handy (evaluated per round)
var _handy_ready: bool = false  # this round's HSP session is live


func _handy_stroke_selected() -> bool:
	return SettingsService.get_stroke_target() == DeviceRouting.HANDY_TARGET


# One-time journey-start sync for Handy WiFi: run the full clock handshake up front (behind a themed
# overlay) so round 1 starts clean, confirm the device is live with a quick stroke, and only then let the
# journey begin. No-op unless the Handy is the stroker with a key and isn't already synced; never BLOCKS
# play — an unreachable device just falls through to deviceless, same as a round would. Skipped in test mode.
func _handy_journey_sync_gate() -> void:
	if _test_mode or not _handy_stroke_selected() or not HandyService.has_key():
		return
	if HandyService.is_connected_ok():
		return  # already synced (e.g. CONNECT pressed in Options) — nothing to wait for

	var overlay: ColorRect = ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.82)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow clicks while we sync
	add_child(overlay)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var vb: VBoxContainer = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	center.add_child(vb)

	var title: Label = Label.new()
	title.text = "GETTING THE HANDY READY"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(title, UITheme.CYAN, 22, true)
	vb.add_child(title)

	var status: Label = Label.new()
	status.text = "● Syncing with the device…"
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(status, UITheme.WHITE_SOFT, 14, false)
	vb.add_child(status)

	var ok: bool = await HandyService.connect_and_sync()
	if ok:
		status.text = "● Connected"
		status.add_theme_color_override("font_color", UITheme.SUCCESS)
		await HandyService.test_stroke()  # a quick buzz so you can feel it's live
		await get_tree().create_timer(0.7).timeout
	else:
		status.text = "✕ Not reachable — playing without the Handy"
		status.add_theme_color_override("font_color", UITheme.DANGER)
		await get_tree().create_timer(1.4).timeout
	overlay.queue_free()


# Per-round setup: reachability/clock sync → load the script as HSP points →
# open a session and start streaming at the current video position → apply the
# stroke range. Any failure drops to a toast; the round plays without the device.
func _handy_begin_round(fs_path: String) -> void:
	_handy_active = _handy_stroke_selected()
	_handy_ready = false
	if not _handy_active or fs_path == "":
		return
	# ensure_ready reuses the cached session clock-sync — only the FIRST round (or after a long gap) pays the
	# full ~9-call handshake; later rounds skip straight to setup+play, so the device starts near-instantly.
	if not await HandyService.ensure_ready():
		_show_save_toast("✕  THE HANDY IS UNREACHABLE — CHECK KEYS / WIFI", 5.0)
		return
	HandyService.load_actions(JourneyData.read_funscript_actions(fs_path))
	# Bake in this round's active stroke effects (boss/curse modifiers are added
	# synchronously before this await resolves, so they're present here).
	HandyService.set_effects(
		InventoryService.GetActiveEffects(), SettingsService.get_home_position()
	)
	# Pass a live position source (not a snapshot): HandyService reads it AFTER /hsp/setup so the anchor and
	# server_time line up — the video keeps advancing during the setup round-trip, and a stale snapshot here
	# is what left the device ~1s behind for the round.
	if not await HandyService.start(_handy_video_ms):
		_show_save_toast("✕  HANDY SYNC FAILED — ROUND PLAYS WITHOUT IT", 5.0)
		return
	_handy_ready = true
	await HandyService.set_slider(SettingsService.get_range_min(), SettingsService.get_range_max())


# The live video clock in ms — passed to HandyService.start so it can read the anchor at play-send time.
func _handy_video_ms() -> int:
	return int(_video.stream_position * 1000.0)


# Active stroke effects changed mid-round (item activated / expired, cleanse,
# boss add) — rebuild the transformed stream and flush-refeed the device from
# the current position so the change reaches the Handy (lands a fraction of a
# second later via the flush). No-op unless the Handy is the live stroker.
func _handy_effects_changed() -> void:
	if not _handy_ready:
		return
	HandyService.set_effects(
		InventoryService.GetActiveEffects(), SettingsService.get_home_position()
	)
	HandyService.seek(int(_video.stream_position * 1000.0))


# Tops up the HSP buffer ahead of the video clock — called from _process while
# the Handy drives this round. Fire-and-forget + self-throttled in HandyService.
func _handy_feed() -> void:
	if _handy_ready and _video.is_playing() and not _video.paused:
		HandyService.feed(int(_video.stream_position * 1000.0))


func _handy_pause() -> void:
	if _handy_ready:
		HandyService.pause()


func _handy_resume() -> void:
	# Re-anchor to the video clock rather than a bare /hsp/resume. Pause/resume aren't
	# simultaneous with the device (each command is a network round-trip), so a plain resume
	# leaves the device drifted by that latency; seeking to the current position wipes it.
	if not _handy_ready:
		return
	if HandyService.is_override_active() and _override_bundle != null:
		# An override owns the device — seek() is suppressed, so re-anchor its OWN stream to the
		# override clock instead (start_override is replace-safe: it keeps the round stash).
		HandyService.start_override(_override_bundle.main, _override_immune, _override_ms)
	else:
		HandyService.seek(int(_video.stream_position * 1000.0))


func _handy_stop() -> void:
	# Always call stop(): it clears any prewarmed-but-unused session flag and only sends /hsp/stop when the
	# device is actually playing, so it's safe even on a round that never engaged the Handy.
	HandyService.stop()


# ---------------------------------------------------------------------------
# Override items — device takeover coordinator
# ---------------------------------------------------------------------------
# Owns the source-agnostic OverrideSession (see OVERRIDE_ITEMS_DESIGN.md): when an override item is
# activated, load its funscript bundle, seize both device paths (FunscriptPlayer + HandyService), tick
# the session each frame on its OWN clock, and hand control back — re-anchoring to the live video
# position — when it completes. Replace-on-reactivate; cut at round end.

var _override_session: OverrideSession = OverrideSession.new()
var _override_bundle: OverrideBundle = null
var _override_immune: bool = false
var _override_item_name: String = ""  # shown on the HUD override chip while active


# The override's own elapsed-ms clock — passed to HandyService.start_override so its stream stays ahead
# of the OVERRIDE position (not the video), and fed each frame while active.
func _override_ms() -> int:
	return _override_session.position_ms()


# An override item was activated. Load its bundle and seize the device on its own clock; a second
# activation REPLACES the running one (the device paths keep their round stash). No-op if the item or
# its funscript is missing.
func _on_override_activated(item_id: String) -> void:
	var item: Dictionary = InventoryService.GetItemData(item_id)
	if item.is_empty():
		return
	var bundle: OverrideBundle = _load_override_bundle(item)
	if bundle == null or bundle.is_empty():
		return
	_override_bundle = bundle
	_override_immune = bool(item.get("immune_to_effects", false))
	_override_item_name = str(item.get("name", ""))
	_override_session.begin(bundle, _override_immune, "item")
	FunscriptPlayer.BeginOverride(bundle.main, bundle.axes, bundle.vibes, _override_immune)
	if _handy_ready:
		HandyService.start_override(bundle.main, _override_immune, _override_ms)


# Loads an override item's funscript bundle from its `scripts` map ({main, axes{name:path},
# vibes{ch:path}}). Paths are read as-is (absolute / res:// / already resolved by the scanner); a
# missing file yields an empty channel, so a bad reference degrades to a shorter/empty bundle.
func _load_override_bundle(item: Dictionary) -> OverrideBundle:
	var scripts: Dictionary = item.get("scripts", {})
	var main: Array = JourneyData.read_funscript_actions(str(scripts.get("main", "")))
	var axes: Dictionary = {}
	for axis_name: Variant in scripts.get("axes", {}):
		var pts: Array = JourneyData.read_funscript_actions(str(scripts["axes"][axis_name]))
		if not pts.is_empty():
			axes[str(axis_name)] = pts
	var vibes: Dictionary = {}
	for channel: Variant in scripts.get("vibes", {}):
		var pts: Array = JourneyData.read_funscript_actions(str(scripts["vibes"][channel]))
		if not pts.is_empty():
			vibes[int(channel)] = pts
	return OverrideBundle.from_channels(main, axes, vibes)


# Per-frame while an override owns the device: advance its clock, keep the Handy buffer fed on that
# clock, and hand control back when the bundle finishes.
func _tick_override(delta: float) -> void:
	# is_playing() stays true while the video is PAUSED, so gate the clock on _video.paused — the
	# override freezes with the game (in lockstep with the C# free-run, which Pause() also halts).
	_override_session.set_paused(_video.paused)
	var event: String = _override_session.tick(int(delta * 1000.0))
	if _handy_ready and not _video.paused:
		HandyService.feed(_override_session.position_ms())
	if event == OverrideSession.EVENT_COMPLETED:
		_end_override()


# The override finished: restore both device paths to the round and re-anchor to where the video is
# NOW (it kept playing underneath).
func _end_override() -> void:
	var live_sec: float = _video.stream_position
	FunscriptPlayer.EndOverride(live_sec)
	if _handy_ready:
		HandyService.stop_override(int(live_sec * 1000.0))
	_override_bundle = null
	_override_item_name = ""


# Cuts any override in progress at a round boundary (the "cut at round end" rule). The device paths
# also self-clean on the next round's load/stop, but resetting the session here keeps state tidy.
func _cancel_override() -> void:
	if _override_session.is_active():
		_override_session.cut()
		_end_override()


# ---------------------------------------------------------------------------
# Pause muffle — "stepping out of the room"
# ---------------------------------------------------------------------------

# An ACTIVE pause (pause button / Options overlay) low-passes and gently dips
# the audio and dims the screen, tweened both ways. System gates (shops / forks
# / storyboards / boss intros) set neither _paused nor _options_open, so they
# keep their normal ambiance. The dip is a bus EFFECT (AudioEffectAmplify), not
# a bus-volume write — the user's Master volume slider (live in the very
# Options overlay that triggers this) must never be stomped. Both effects are
# removed from the Master bus on scene exit so nothing leaks past the run.
const MUFFLE_CUTOFF_HZ: float = 700.0
const MUFFLE_OPEN_HZ: float = 20500.0
const MUFFLE_DIP_DB: float = -6.0
const MUFFLE_DIM_ALPHA: float = 0.22
const MUFFLE_TWEEN_S: float = 0.22

var _muffle_on: bool = false
var _muffle_lp: AudioEffectLowPassFilter = null
var _muffle_amp: AudioEffectAmplify = null
var _muffle_dim: ColorRect = null
var _muffle_tween: Tween = null


func _update_muffle() -> void:
	var want: bool = _paused or _options_open
	if want == _muffle_on:
		return
	_muffle_on = want
	_ensure_muffle_rig()
	var master: int = AudioServer.get_bus_index("Master")
	if want:
		_set_muffle_fx_enabled(master, true)
		_muffle_dim.visible = true
	if _muffle_tween and _muffle_tween.is_valid():
		_muffle_tween.kill()
	_muffle_tween = create_tween().set_parallel(true)
	(
		_muffle_tween
		. tween_property(
			_muffle_lp, "cutoff_hz", MUFFLE_CUTOFF_HZ if want else MUFFLE_OPEN_HZ, MUFFLE_TWEEN_S
		)
		. set_trans(Tween.TRANS_SINE)
	)
	_muffle_tween.tween_property(
		_muffle_amp, "volume_db", MUFFLE_DIP_DB if want else 0.0, MUFFLE_TWEEN_S
	)
	_muffle_tween.tween_property(
		_muffle_dim, "color:a", MUFFLE_DIM_ALPHA if want else 0.0, MUFFLE_TWEEN_S
	)
	if not want:
		# Fully open again — disable the effects so the bus is bit-identical to
		# the pre-muffle state (a fully-open low-pass still costs DSP).
		_muffle_tween.chain().tween_callback(
			func() -> void:
				_set_muffle_fx_enabled(AudioServer.get_bus_index("Master"), false)
				_muffle_dim.visible = false
		)


# Lazily creates the two Master-bus effects (disabled) and the dim overlay.
func _ensure_muffle_rig() -> void:
	if _muffle_lp != null:
		return
	var master: int = AudioServer.get_bus_index("Master")
	_muffle_lp = AudioEffectLowPassFilter.new()
	_muffle_lp.cutoff_hz = MUFFLE_OPEN_HZ
	_muffle_amp = AudioEffectAmplify.new()
	_muffle_amp.volume_db = 0.0
	AudioServer.add_bus_effect(master, _muffle_lp)
	AudioServer.add_bus_effect(master, _muffle_amp)
	_set_muffle_fx_enabled(master, false)
	_muffle_dim = ColorRect.new()
	_muffle_dim.color = Color(0, 0, 0, 0)
	_muffle_dim.anchor_right = 1.0
	_muffle_dim.anchor_bottom = 1.0
	_muffle_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_muffle_dim.visible = false
	add_child(_muffle_dim)


# Toggles OUR two effects by identity — index-safe even if something else has
# added effects to the Master bus.
func _set_muffle_fx_enabled(master: int, on: bool) -> void:
	for i: int in AudioServer.get_bus_effect_count(master):
		var fx: AudioEffect = AudioServer.get_bus_effect(master, i)
		if fx == _muffle_lp or fx == _muffle_amp:
			AudioServer.set_bus_effect_enabled(master, i, on)


# The Master bus is global — strip our effects when the run scene goes away so
# the menu (or the next run) starts clean. Mirrors SensoryFX's bus hygiene.
func _exit_tree() -> void:
	# Input.mouse_mode is global and survives scene changes, so always hand the
	# cursor back visible when the run scene goes away (menu / end screen / builder),
	# no matter which exit path got us here.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_handy_stop()  # the Handy is external and would keep stroking without this stop
	if _muffle_lp == null:
		return
	var master: int = AudioServer.get_bus_index("Master")
	for i: int in range(AudioServer.get_bus_effect_count(master) - 1, -1, -1):
		var fx: AudioEffect = AudioServer.get_bus_effect(master, i)
		if fx == _muffle_lp or fx == _muffle_amp:
			AudioServer.remove_bus_effect(master, i)
	_muffle_lp = null
	_muffle_amp = null


func _show_hud(fade: bool = false) -> void:
	# Bringing the HUD back always brings the cursor back with it — real activity
	# reveals both together.
	_set_cursor_hidden(false)
	# The warmup skip fades in and out with the HUD, but is NOT subject to the curse below: a
	# player told they can leave a round must always be able to.
	_fade_warmup_skip_button(true)
	_fade_finish_button(true)  # fades in with the HUD (stays clickable at rest for an in-progress hold)
	# A "Fog" curse hides the HUD for the whole round — don't let hover / timers
	# reveal it.
	if _curse_hud_hidden:
		_hud.visible = false
		return
	_hud.visible = true
	if fade:
		# Smoothly bring the HUD back after a round transition (rather than
		# popping in at full opacity the instant the fade clears).
		_hud.modulate = Color(1, 1, 1, 0)
		create_tween().tween_property(_hud, "modulate:a", 1.0, 0.3)
	else:
		_hud.modulate = Color(1, 1, 1, 1)
	_hide_timer.start(SettingsService.get_hud_hide_delay())


func _on_hide_timer_timeout() -> void:
	_hud.visible = false
	_fade_warmup_skip_button(false)
	_fade_finish_button(false)
	# Hide the mouse cursor during uninterrupted playback so it stops covering the
	# video — but only when there's nothing the player might need to click. If a
	# menu/overlay/panel/map is up or the round is paused, keep it visible.
	if _can_hide_cursor():
		_set_cursor_hidden(true)


# True only during active, unobstructed playback — the one state where hiding the
# cursor is safe (nothing to click). Any interactive surface keeps it visible.
func _can_hide_cursor() -> bool:
	if _paused or _is_overlay_open or _map_open:
		return false
	if is_instance_valid(_session_panel) or is_instance_valid(_inventory_panel):
		return false
	return true


func _set_cursor_hidden(hidden: bool) -> void:
	var want: int = Input.MOUSE_MODE_HIDDEN if hidden else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != want:
		Input.mouse_mode = want


# Toggles the in-play Quick Settings drawer (stroke range + delay). Mutually exclusive with the
# inventory drawer — opening one closes the other.
func _on_session_settings_pressed() -> void:
	if is_instance_valid(_session_panel):
		_session_panel.close()
		return
	if is_instance_valid(_inventory_panel):
		_inventory_panel.close()
	_session_panel = SessionSettingsPanel.new()
	_session_panel.closed.connect(_on_session_settings_closed)
	add_child(_session_panel)
	_show_hud()


func _on_session_settings_closed() -> void:
	_session_panel = null


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------


func _input(event: InputEvent) -> void:
	# Any *real* activity shows the HUD. Mouse-motion is filtered through a deadzone
	# because the OS/touchpad can emit InputEventMouseMotion with (near-)zero relative
	# movement when the user isn't touching anything — those phantom events used to
	# reveal the HUD at random during playback.
	if event is InputEventMouseButton or event is InputEventKey:
		_show_hud()
	elif event is InputEventMouseMotion:
		if (event as InputEventMouseMotion).relative.length() >= MOUSE_MOTION_DEADZONE_PX:
			_show_hud()

	# Keyboard hotkeys — evaluated in order of specificity.
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			# Map viewer is modal while open: Esc / M close it; swallow the rest.
			if _map_open:
				if key_event.keycode == KEY_ESCAPE or key_event.keycode == KEY_M:
					_close_map_viewer()
				get_viewport().set_input_as_handled()
				return
			match key_event.keycode:
				KEY_M:
					# M: open the journey map (when the author enabled it). Blocked while a
					# full-screen overlay is up, except shops / storyboards / interactive
					# forks, which allow it.
					if _map_enabled and (not _is_overlay_open or _overlay_map_allowed):
						_open_map_viewer()
						get_viewport().set_input_as_handled()
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
					# Esc: close the Quick Settings drawer or inventory if open, otherwise begin the
					# hold-to-exit (a stray tap can't dump the run; releasing cancels — see the key-up
					# branch below). Overlay screens (shop/storyboard) capture Esc themselves before it
					# reaches here; the fork screen intentionally does not (no escape).
					if not _is_overlay_open:
						if is_instance_valid(_session_panel):
							_session_panel.close()
						elif is_instance_valid(_inventory_panel):
							_inventory_panel.close()
						else:
							_begin_exit_hold()
						get_viewport().set_input_as_handled()
				KEY_S:
					# S: toggle the in-play Quick Settings drawer (stroke range + delay).
					if not _is_overlay_open:
						_on_session_settings_pressed()
						get_viewport().set_input_as_handled()
				# Arrow keys nudge the stroke range, but only while the drawer is open: ↑/↓ max, →/← min.
				KEY_UP:
					if is_instance_valid(_session_panel):
						_session_panel.nudge_range(0, STROKE_RANGE_STEP)
						get_viewport().set_input_as_handled()
				KEY_DOWN:
					if is_instance_valid(_session_panel):
						_session_panel.nudge_range(0, -STROKE_RANGE_STEP)
						get_viewport().set_input_as_handled()
				KEY_RIGHT:
					if is_instance_valid(_session_panel):
						_session_panel.nudge_range(STROKE_RANGE_STEP, 0)
						get_viewport().set_input_as_handled()
				KEY_LEFT:
					if is_instance_valid(_session_panel):
						_session_panel.nudge_range(-STROKE_RANGE_STEP, 0)
						get_viewport().set_input_as_handled()
				# Live delay nudges (±10 ms) during play: [ / ] = serial, ; / ' = intiface.
				KEY_BRACKETLEFT:
					if not _is_overlay_open:
						_nudge_serial_delay(-DELAY_STEP)
						get_viewport().set_input_as_handled()
				KEY_BRACKETRIGHT:
					if not _is_overlay_open:
						_nudge_serial_delay(DELAY_STEP)
						get_viewport().set_input_as_handled()
				KEY_SEMICOLON:
					if not _is_overlay_open:
						_nudge_intiface_delay(-DELAY_STEP)
						get_viewport().set_input_as_handled()
				KEY_APOSTROPHE:
					if not _is_overlay_open:
						_nudge_intiface_delay(DELAY_STEP)
						get_viewport().set_input_as_handled()
		elif not key_event.pressed and key_event.keycode == KEY_ESCAPE:
			# Esc released — abort an in-progress hold-to-exit (a no-op when none is running).
			_cancel_exit_hold()


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

# Animated HUD counters: the score/coin labels count up (or down) to their new
# value and flash a colour + scale pulse — green for a gain, red for a loss — so
# rewards feel earned and the pause-penalty drain is actually visible.
const COUNTER_DURATION: float = 0.45
const PULSE_DURATION: float = 0.35

var _score_shown: int = 0
var _coin_shown: int = 0
# Per-label [count, scale, colour] tweens, killed/replaced on each change so
# rapid score ticks chase the target instead of stacking.
var _counter_tweens: Dictionary = {}


func _on_score_changed(total: int) -> void:
	_animate_counter(_score_lbl, _score_shown, total, "%d PTS", UITheme.MAGENTA, false)
	_score_shown = total


# Rolls `lbl` from from_val→to_val with a count-up tween and a gain/loss pulse.
# `fmt` is a printf format taking one int (e.g. "%d PTS"). `instant` snaps with
# no animation (used for the initial fill so the HUD doesn't pulse on round start).
func _animate_counter(
	lbl: Label, from_val: int, to_val: int, fmt: String, base_color: Color, instant: bool
) -> void:
	for tw: Tween in _counter_tweens.get(lbl, []):
		if tw != null and tw.is_running():
			tw.kill()

	if instant or from_val == to_val:
		lbl.text = fmt % to_val
		lbl.scale = Vector2.ONE
		lbl.add_theme_color_override("font_color", base_color)
		_counter_tweens[lbl] = []
		return

	var pulse_color: Color = UITheme.OK if to_val > from_val else UITheme.DANGER

	var count_tw: Tween = create_tween()
	(
		count_tw
		. tween_method(
			_set_counter_text.bind(lbl, fmt), float(from_val), float(to_val), COUNTER_DURATION
		)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_OUT)
	)

	lbl.pivot_offset = lbl.size / 2.0
	var scale_tw: Tween = create_tween()
	(
		scale_tw
		. tween_property(lbl, "scale", Vector2(1.12, 1.12), 0.10)
		. set_trans(Tween.TRANS_BACK)
		. set_ease(Tween.EASE_OUT)
	)
	(
		scale_tw
		. tween_property(lbl, "scale", Vector2.ONE, PULSE_DURATION - 0.10)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_IN)
	)

	lbl.add_theme_color_override("font_color", pulse_color)
	var color_tw: Tween = create_tween()
	color_tw.tween_method(_set_counter_color.bind(lbl), pulse_color, base_color, PULSE_DURATION)

	_counter_tweens[lbl] = [count_tw, scale_tw, color_tw]


func _set_counter_text(value: float, lbl: Label, fmt: String) -> void:
	lbl.text = fmt % int(round(value))


func _set_counter_color(c: Color, lbl: Label) -> void:
	lbl.add_theme_color_override("font_color", c)


func _connect_signals() -> void:
	_video.finished.connect(_on_round_ended)
	_end_timer.timeout.connect(_on_round_ended)
	_pause_btn.pressed.connect(_toggle_pause)
	# MENU is hold-to-confirm too (matches Esc), so a misclick can't drop the run mid-play.
	_menu_btn.button_down.connect(_begin_exit_hold)
	_menu_btn.button_up.connect(_cancel_exit_hold)
	_menu_btn.tooltip_text = "Hold to exit to the main menu"
	_hide_timer.timeout.connect(_on_hide_timer_timeout)
	_pause_btn.mouse_entered.connect(_show_hud)
	_menu_btn.mouse_entered.connect(_show_hud)
	_options_btn.pressed.connect(_on_options_pressed)
	_options_btn.mouse_entered.connect(_show_hud)
	_inv_btn.pressed.connect(_on_inventory_pressed)
	_inv_btn.mouse_entered.connect(_show_hud)
	ScoreService.ScoreChanged.connect(_on_score_changed)
	CoinService.BalanceChanged.connect(_on_coin_balance_changed)
	GameState.CounterChanged.connect(_on_counter_changed)
	# One-shots first: they apply + consume before the chips render, so a fire-once item effect
	# (toll/interest/flag/counter) never flashes a chip.
	InventoryService.ActiveEffectsChanged.connect(_apply_oneshot_item_effects)
	InventoryService.ActiveEffectsChanged.connect(_refresh_effect_chips)
	InventoryService.ActiveEffectsChanged.connect(_handy_effects_changed)
	InventoryService.ActiveEffectsChanged.connect(_reconcile_sensory)
	InventoryService.ActiveEffectsChanged.connect(_reconcile_hud_hide)
	# Override items don't join the effect list — they seize the device via the takeover coordinator.
	InventoryService.OverrideActivated.connect(_on_override_activated)
	# save_now utility item: writes a save mid-round so the player can resume
	# from the start of this round if they quit later. Doesn't end the run.
	InventoryService.connect("SaveRequested", _on_save_item_used)
	# skip_round utility item: ends the round here, paying nothing.
	InventoryService.connect("SkipRoundRequested", _on_skip_item_used)

	# Device-connection signals — surface a banner when the currently selected
	# output device drops its connection, and clear it on reconnect. We watch
	# both backends so an output-mode change in Options mid-game picks up the
	# correct state via _refresh_device_warning(). DeviceAdded / DeviceRemoved
	# matter independently of Connected/Disconnected: a device can drop
	# (battery, Bluetooth, USB unplug) while Intiface itself stays running.
	ButtplugService.connect("Connected", _refresh_device_warning)
	ButtplugService.connect("Disconnected", _refresh_device_warning)
	ButtplugService.connect(
		"DeviceAdded", func(_n: String, _i: int) -> void: _refresh_device_warning()
	)
	ButtplugService.connect("DeviceRemoved", func(_i: int) -> void: _refresh_device_warning())
	SerialDeviceService.connect("Connected", _refresh_device_warning)
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
	# A device is "present" if serial is connected or Intiface has a live device. Multi-device makes
	# "which device" fuzzy, so this is a general presence check across both backends.
	var serial_up: bool = SerialDeviceService.SerialConnected
	var bp_up: bool = ButtplugService.BpConnected and ButtplugService.GetActiveDeviceName() != ""
	if serial_up or bp_up:
		_device_ever_seen = true
		_device_warning_banner.visible = false
		return
	# Nothing connected right now. Only warn if a device WAS present this run — so a funscript-only
	# session with no toy never nags — and the banner clears itself the moment a device returns.
	if _device_ever_seen:
		_device_warning_label.text = "●  DEVICE DISCONNECTED  —  RECONNECT IN OPTIONS"
		_device_warning_banner.visible = true
	else:
		_device_warning_banner.visible = false


func _nudge_serial_delay(delta: int) -> void:
	var v: int = clampi(SettingsService.get_serial_delay_ms() + delta, -500, 500)
	SettingsService.set_serial_delay_ms(v)
	SettingsService.save()
	FunscriptPlayer.SetSerialDelay(v)
	_show_delay_toast("Serial delay  %d ms" % v)
	if is_instance_valid(_session_panel):
		_session_panel.resync()


func _nudge_intiface_delay(delta: int) -> void:
	var v: int = clampi(SettingsService.get_intiface_delay_ms() + delta, -500, 500)
	SettingsService.set_intiface_delay_ms(v)
	SettingsService.save()
	FunscriptPlayer.SetIntifaceDelay(v)
	_show_delay_toast("Intiface delay  %d ms" % v)
	if is_instance_valid(_session_panel):
		_session_panel.resync()


# Brief, reusable on-screen readout for the delay hotkeys (no label spam on rapid presses).
func _show_delay_toast(text: String) -> void:
	if not is_instance_valid(_delay_toast):
		_delay_toast = Label.new()
		_delay_toast.add_theme_font_size_override("font_size", 20)
		_delay_toast.add_theme_color_override("font_color", UITheme.CYAN)
		_delay_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_delay_toast.anchor_left = 0.0
		_delay_toast.anchor_right = 1.0
		_delay_toast.anchor_top = 0.12
		_delay_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_delay_toast)
	_delay_toast.text = text
	_delay_toast.modulate.a = 1.0
	if _delay_toast_tween != null and _delay_toast_tween.is_valid():
		_delay_toast_tween.kill()
	_delay_toast_tween = create_tween()
	_delay_toast_tween.tween_interval(0.8)
	_delay_toast_tween.tween_property(_delay_toast, "modulate:a", 0.0, 0.4)


# ---------------------------------------------------------------------------
# Inventory / coins / effect chips
# ---------------------------------------------------------------------------


func _on_inventory_pressed() -> void:
	if is_instance_valid(_inventory_panel):
		_inventory_panel.close()
		return
	# Mutually exclusive with the Quick Settings drawer.
	if is_instance_valid(_session_panel):
		_session_panel.close()
	_inventory_panel = InventoryPanelScene.instantiate()
	_inventory_panel.closed.connect(_on_inventory_closed)
	add_child(_inventory_panel)


func _on_inventory_closed() -> void:
	_inventory_panel = null


func _on_coin_balance_changed(_balance: int) -> void:
	_refresh_coin_label()


# `instant` snaps to the balance with no count-up/pulse — used for the initial
# HUD fill during setup so the coins don't pulse before the run begins.
func _refresh_coin_label(instant: bool = false) -> void:
	var balance: int = CoinService.Balance
	_animate_counter(_coin_lbl, _coin_shown, balance, "♦ %d", UITheme.AMBER, instant)
	_coin_shown = balance


func _refresh_effect_chips() -> void:
	for child in _chips_row.get_children():
		child.queue_free()
	# Blackout is decided over EVERY active effect; chips render the consolidated view so a multi-
	# effect item shows one chip, not one identical chip per bundled effect.
	var has_blackout: bool = false
	for effect: Dictionary in InventoryService.GetActiveEffects():
		if effect.get("kind", "") == "blackout":
			has_blackout = true
	# The override chip leads the row while a takeover is active (overrides aren't in the effect list).
	if _override_session.is_active():
		_chips_row.add_child(_make_override_chip())
	for effect: Dictionary in _visible_effects():
		_chips_row.add_child(_make_chip(effect))
	_video.visible = not has_blackout


# One representative effect per HUD chip. Effects from the same item activation (a shared non-empty
# id + start time) collapse to a single chip — a multi-effect modifier item is one item to the player,
# so it reads as one chip with the item's name. Boss / effect-round effects carry no start_time_ms and
# are never grouped, so each keeps its own chip.
func _visible_effects() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for fx: Dictionary in InventoryService.GetActiveEffects():
		var id: String = str(fx.get("id", ""))
		if id != "" and fx.has("start_time_ms"):
			var key: String = "%s|%s" % [id, str(fx.get("start_time_ms"))]
			if seen.has(key):
				continue
			seen[key] = true
		out.append(fx)
	return out


func _make_chip(effect: Dictionary) -> Control:
	# Boons green, curses / boss modifiers red, player-activated shop items amber.
	var accent: Color
	if effect.get("benefit", false):
		accent = UITheme.SUCCESS
	elif effect.get("boss", false):
		accent = UITheme.DANGER
	else:
		accent = UITheme.AMBER
	var chip: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(accent.r, accent.g, accent.b, 0.12)
	s.border_color = accent
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 4
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
	# Boss forced modifiers last the whole round, and coin effects settle at round end (they don't run
	# on a wall clock) — neither shows a countdown.
	if (
		effect.get("boss", false)
		or String(effect.get("kind", "")) in ["coin_jackpot", "coin_penalty"]
	):
		lbl.text = name_str
		return
	var remaining: float = InventoryService.GetRemainingSeconds(effect)
	lbl.text = "%s  %ds" % [name_str, int(ceil(remaining))]


func _update_chip_countdowns() -> void:
	var effects: Array = _visible_effects()
	var override_on: bool = _override_session.is_active()
	# The override chip (when active) leads the row; a count mismatch (an override began/ended, or an
	# effect changed) triggers a full rebuild so the row re-forms with the right chips.
	if effects.size() + (1 if override_on else 0) != _chips_row.get_child_count():
		_refresh_effect_chips()
		return
	var offset: int = 0
	if override_on:
		var olbl: Label = _chips_row.get_child(0).get_meta("chip_label", null)
		if olbl != null:
			olbl.text = _override_chip_text()
		offset = 1
	for i in effects.size():
		var chip: Node = _chips_row.get_child(i + offset)
		var lbl: Label = chip.get_meta("chip_label", null)
		if lbl != null:
			_update_chip_text(lbl, effects[i])


# The HUD chip shown while an override owns the device. Toxic-green to match the override visual
# language; counts down the remaining bundle time like an effect chip.
func _make_override_chip() -> Control:
	var accent: Color = UITheme.TOXIC_GREEN
	var chip: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(accent.r, accent.g, accent.b, 0.14)
	s.border_color = accent
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	chip.add_theme_stylebox_override("panel", s)
	var lbl: Label = Label.new()
	lbl.add_theme_color_override("font_color", accent)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.text = _override_chip_text()
	chip.add_child(lbl)
	chip.set_meta("chip_label", lbl)
	return chip


func _override_chip_text() -> String:
	var title: String = (
		("▶ " + _override_item_name.to_upper()) if _override_item_name != "" else "▶ OVERRIDE"
	)
	return "%s  %ds" % [title, int(ceil(_override_session.remaining_ms() / 1000.0))]


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------


func _apply_layout() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = 0
	_bg.offset_top = 0
	_bg.offset_right = 0
	_bg.offset_bottom = 0

	_video.anchor_left = 0.0
	_video.anchor_top = 0.0
	_video.anchor_right = 0.0
	_video.anchor_bottom = 0.0
	_video.offset_left = 0
	_video.offset_top = 0
	_video.offset_right = 0
	_video.offset_bottom = 0
	_video.position = Vector2.ZERO
	_video.size = get_viewport_rect().size

	_hud.anchor_right = 1.0
	_hud.anchor_bottom = 1.0

	_hud_bar.anchor_left = 0.0
	_hud_bar.anchor_right = 1.0
	_hud_bar.anchor_top = 1.0
	_hud_bar.anchor_bottom = 1.0
	_hud_bar.offset_top = -HUD_BAR_HEIGHT
	_hud_bar.offset_bottom = 0

	_hud_layout.add_theme_constant_override("separation", 16)
	_round_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Progress bar — centered thin strip at the very bottom of the screen
	_progress.anchor_left = 0.1
	_progress.anchor_right = 0.9
	_progress.anchor_top = 1.0
	_progress.anchor_bottom = 1.0
	_progress.offset_left = 0
	_progress.offset_right = 0
	_progress.offset_top = -7
	_progress.offset_bottom = -1

	# Effect chips — row pinned just above the progress bar, centred.
	_chips_row.anchor_left = 0.0
	_chips_row.anchor_right = 1.0
	_chips_row.anchor_top = 1.0
	_chips_row.anchor_bottom = 1.0
	_chips_row.offset_top = -42
	_chips_row.offset_bottom = -12
	_chips_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_chips_row.add_theme_constant_override("separation", 8)
	_chips_row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Device-disconnected banner — pinned to the top edge of the viewport,
	# centred horizontally, hidden by default. Lives outside _hud so the
	# auto-hide timer doesn't fade it away.
	_device_warning_banner = PanelContainer.new()
	_device_warning_banner.anchor_left = 0.5
	_device_warning_banner.anchor_right = 0.5
	_device_warning_banner.anchor_top = 0.0
	_device_warning_banner.anchor_bottom = 0.0
	_device_warning_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_device_warning_banner.offset_top = 12
	_device_warning_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_device_warning_banner.visible = false
	add_child(_device_warning_banner)

	var banner_style: StyleBoxFlat = StyleBoxFlat.new()
	banner_style.bg_color = Color(
		UITheme.ERROR_SOFT.r, UITheme.ERROR_SOFT.g, UITheme.ERROR_SOFT.b, 0.92
	)
	banner_style.border_color = UITheme.ERROR_SOFT
	banner_style.border_width_left = 2
	banner_style.border_width_right = 2
	banner_style.border_width_top = 2
	banner_style.border_width_bottom = 2
	banner_style.content_margin_left = 18
	banner_style.content_margin_right = 18
	banner_style.content_margin_top = 8
	banner_style.content_margin_bottom = 8
	banner_style.corner_radius_top_left = 6
	banner_style.corner_radius_top_right = 6
	banner_style.corner_radius_bottom_left = 6
	banner_style.corner_radius_bottom_right = 6
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
	bar_style.bg_color = UITheme.PANEL_BG_GAME
	bar_style.border_color = UITheme.PURPLE_BRIGHT
	bar_style.border_width_top = 1
	bar_style.content_margin_left = 20
	bar_style.content_margin_right = 20
	bar_style.content_margin_top = 14
	bar_style.content_margin_bottom = 14
	_hud_bar.add_theme_stylebox_override("panel", bar_style)

	_round_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	_round_lbl.add_theme_font_size_override("font_size", 13)
	_round_lbl.uppercase = true

	_score_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	_score_lbl.add_theme_font_size_override("font_size", 13)
	_score_lbl.uppercase = true

	_coin_lbl.add_theme_color_override("font_color", UITheme.AMBER)
	_coin_lbl.add_theme_font_size_override("font_size", 13)
	_coin_lbl.uppercase = true

	_style_progress()
	_style_button(_pause_btn, UITheme.PURPLE_BRIGHT)
	_style_button(_inv_btn, UITheme.AMBER)
	_style_button(_menu_btn, UITheme.MAGENTA)
	_style_button(_options_btn, UITheme.PURPLE_MID)


# Thin delegate to UITheme — the canonical styling lives there.
func _style_button(btn: Button, accent: Color) -> void:
	UITheme.style_button_subtle(btn, accent, 14, 8, 13, true)


func _style_progress() -> void:
	var bg: StyleBoxFlat = StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.0, 0.12, 0.8)
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4

	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = UITheme.PURPLE_BRIGHT
	fill.corner_radius_top_left = 4
	fill.corner_radius_top_right = 4
	fill.corner_radius_bottom_left = 4
	fill.corner_radius_bottom_right = 4

	_progress.add_theme_stylebox_override("background", bg)
	_progress.add_theme_stylebox_override("fill", fill)
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.show_percentage = false
