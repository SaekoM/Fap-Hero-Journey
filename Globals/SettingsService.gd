extends Node

# ---------------------------------------------------------------------------
# SettingsService  (autoload)
# Single source of truth for user://settings.cfg. The schema — every section,
# key, type, and default value — is declared exactly once, here.
#
# All other code reads settings through the typed get_*() methods and writes
# through set_*() followed by save(). No other file should open settings.cfg
# directly.
#
# The ConfigFile is held in memory and kept consistent: every write goes
# through a setter, so getters always reflect the latest values without a
# disk round-trip.
#
# C# callers reach this via the autoload node, e.g.:
#   GetNode("/root/SettingsService").Call("get_output_mode").AsString()
# ---------------------------------------------------------------------------

const SETTINGS_PATH: String = "user://settings.cfg"

# ── Canonical defaults ──────────────────────────────────────────────────────
const DEFAULT_MASTER_VOLUME: float = 1.0
const DEFAULT_MUSIC_VOLUME: float = 0.5
const DEFAULT_FULLSCREEN: bool = false
const DEFAULT_RESOLUTION_INDEX: int = 1
const DEFAULT_INTIFACE_ADDRESS: String = "ws://localhost:12345"
const DEFAULT_INTIFACE_AUTO: bool = true
const DEFAULT_SELECTED_DEVICE: String = ""
const DEFAULT_OUTPUT_MODE: String = "buttplug"
const DEFAULT_SERIAL_PORT: String = ""
const DEFAULT_SERIAL_BAUD: int = 115200
const DEFAULT_SERIAL_AUTO: bool = false
const DEFAULT_RANGE_MIN: int = 0
const DEFAULT_RANGE_MAX: int = 100
const DEFAULT_HOME_POSITION: int = 50
const DEFAULT_HOME_EASE_MS: int = 2000
const DEFAULT_LATENCY_OFFSET_MS: int = 0
const DEFAULT_VIBE_INTENSITY: int = 100
const DEFAULT_MAX_STROKE_SPEED: int = 0  # 0 = unlimited (units/sec)
# Serial (T-code) stroke smoothing: the interval FunscriptPlayer streams with, as a multiple of the
# output tick. >1 keeps the OSR gliding toward a fresh target instead of finishing early and
# dwelling. Best value varies by device/firmware, so it's tunable. See FunscriptPlayer._PhysicsProcess.
const DEFAULT_SERIAL_INTERP_FACTOR: float = 1.6

# ── Device routing (one stroker + per-actuator Buttplug vibe/constrict routes) ──
# Actuator id: "<name>#<occurrence>:<linear|vibrate|constrict>:<channel>". Stroke target is
# such an id (a Buttplug linear) or the sentinel "serial". Serial stays a single T-code device
# and is NOT part of the per-actuator mapping (Buttplug-only, by design).
const DEFAULT_STROKE_TARGET: String = ""
const DEFAULT_VIBRATION_ROUTES: Dictionary = {}  # { actuator_id: "vibe1"|"vibe2"|"stroke" }
const DEFAULT_CONSTRICT_ROUTES: Dictionary = {}  # { actuator_id: true }

# Constrict auto state machine (activity-driven squeeze). WHICH actuators = constrict_routes above;
# these globals tune the level transitions. Activity is the stroke speed in funscript units/sec.
const DEFAULT_CONSTRICT_MAX_LEVEL: int = 1  # 1 or 2
const DEFAULT_CONSTRICT_L1_THRESHOLD: float = 45.0  # activity to engage level 1
const DEFAULT_CONSTRICT_L1_SUSTAIN_MS: int = 5000  # held above L1 this long → engage
const DEFAULT_CONSTRICT_RELEASE_THRESHOLD: float = 25.0  # activity below which it releases
const DEFAULT_CONSTRICT_RELEASE_SUSTAIN_MS: int = 10000  # held below this long → release
const DEFAULT_CONSTRICT_MIN_HOLD_MS: int = 12000  # minimum time engaged before a release is allowed
const DEFAULT_CONSTRICT_L2_ENABLED: bool = false
const DEFAULT_CONSTRICT_L2_THRESHOLD: float = 90.0
const DEFAULT_CONSTRICT_L2_SUSTAIN_MS: int = 8000
const DEFAULT_CONSTRICT_L2_FINAL_PCT: float = 12.0  # level 2 only within the final % of the script
const DEFAULT_CONSTRICT_HOLD_ON_PAUSE: bool = true
const DEFAULT_HUD_HIDE_DELAY: float = 3.0  # seconds
const DEFAULT_UI_SCALE: float = 1.0  # Window.content_scale_factor multiplier
const DEFAULT_BEAT_BAR_ENABLED: bool = false
const DEFAULT_ROUND_TIMER_ENABLED: bool = false  # opt-in, like the beat bar
const DEFAULT_BEAT_BAR_SHAPE: String = "heart"  # see BeatBar.SHAPES
# Readability scales, separate from UI_SCALE (which resizes the whole interface, layout and all).
# These grow TEXT only, in the two places long-form reading actually happens.
const DEFAULT_STORY_TEXT_SCALE: float = 1.0  # fork / boss / storyboard prose
const DEFAULT_TOOLTIP_TEXT_SCALE: float = 1.0  # every tooltip, builder included
# Fraction of the funscript clip-editor's resizable area given to the video pane (the rest goes to
# the curve graph below it). Authors drag the divider to taste; the choice persists. See
# FunscriptPreview's VSplitContainer.
const DEFAULT_PREVIEW_VIDEO_SPLIT: float = 0.68
# Fraction of the clip-editor's WIDTH given to the left column (video + graph + playback controls);
# the rest is the segment-timeline column on the right. Draggable + persisted, like the video split.
const DEFAULT_PREVIEW_COLUMNS_SPLIT: float = 0.68
const DEFAULT_FILLER_ENABLED: bool = false
const DEFAULT_FILLER_HALF_CYCLE: int = 2000
const DEFAULT_FILLER_LO: int = 0
const DEFAULT_FILLER_HI: int = 100
const DEFAULT_JOURNEYS_DIR: String = "user://journeys"
const DEFAULT_FFMPEG_DIR: String = ""  # "" = bundled binary / PATH
const DEFAULT_AUTO_TRANSCODE: bool = true
const DEFAULT_UPDATE_CHECK: bool = true  # check GitHub for a newer build on launch
const DEFAULT_UI_SOUND_ENABLED: bool = true  # click/hover feedback blips
const DEFAULT_UI_SOUND_VOLUME: float = 0.6  # linear, 0–1

var _config: ConfigFile = ConfigFile.new()


func _ready() -> void:
	# A missing file is fine — getters fall back to the canonical defaults.
	_config.load(SETTINGS_PATH)

	# Apply boot-time audio / display settings.
	AudioServer.set_bus_volume_db(0, linear_to_db(get_master_volume()))
	var mode: DisplayServer.WindowMode = (
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
		if get_fullscreen()
		else DisplayServer.WINDOW_MODE_WINDOWED
	)
	DisplayServer.window_set_mode(mode)

	apply_ui_scale()


# ── Getters ─────────────────────────────────────────────────────────────────


func get_master_volume() -> float:
	return float(_config.get_value("audio", "master_volume", DEFAULT_MASTER_VOLUME))


func get_music_volume() -> float:
	return float(_config.get_value("audio", "music_volume", DEFAULT_MUSIC_VOLUME))


func get_fullscreen() -> bool:
	return bool(_config.get_value("display", "fullscreen", DEFAULT_FULLSCREEN))


func get_resolution_index() -> int:
	return int(_config.get_value("display", "resolution_index", DEFAULT_RESOLUTION_INDEX))


func get_intiface_address() -> String:
	return str(_config.get_value("intiface", "address", DEFAULT_INTIFACE_ADDRESS))


func get_intiface_auto_connect() -> bool:
	return bool(_config.get_value("intiface", "auto_connect", DEFAULT_INTIFACE_AUTO))


func get_selected_device() -> String:
	return str(_config.get_value("intiface", "selected_device", DEFAULT_SELECTED_DEVICE))


func get_output_mode() -> String:
	return str(_config.get_value("output", "mode", DEFAULT_OUTPUT_MODE))


func get_serial_port() -> String:
	return str(_config.get_value("serial", "port", DEFAULT_SERIAL_PORT))


func get_serial_baud() -> int:
	return int(_config.get_value("serial", "baud_rate", DEFAULT_SERIAL_BAUD))


func get_serial_auto_connect() -> bool:
	return bool(_config.get_value("serial", "auto_connect", DEFAULT_SERIAL_AUTO))


# Player-side scale on every sensory (visual/audio) effect, 0.1–1.0. Multiplies the author's
# per-round intensity, so it softens without overriding which effects a round uses. Defaults
# below 1.0 — the catalog maxima were tuned harsher than most players want.
func get_sensory_strength() -> float:
	return clampf(float(_config.get_value("display", "sensory_strength", 0.50)), 0.1, 1.0)


func set_sensory_strength(value: float) -> void:
	_config.set_value("display", "sensory_strength", clampf(value, 0.1, 1.0))


func get_range_min() -> int:
	return int(_config.get_value("device", "range_min", DEFAULT_RANGE_MIN))


func get_range_max() -> int:
	return int(_config.get_value("device", "range_max", DEFAULT_RANGE_MAX))


# Per-axis range for the secondary positional axes (T-code L1/L2/R0/R1/R2). Each
# axis has its own [min,max] travel window; the stroke axis uses range_min/range_max.
func get_axis_range_min(axis: String) -> int:
	return int(_config.get_value("device", "axis_%s_range_min" % axis, DEFAULT_RANGE_MIN))


func get_axis_range_max(axis: String) -> int:
	return int(_config.get_value("device", "axis_%s_range_max" % axis, DEFAULT_RANGE_MAX))


func get_home_position() -> int:
	return int(_config.get_value("device", "home_position", DEFAULT_HOME_POSITION))


func get_home_ease_ms() -> int:
	return int(_config.get_value("device", "home_ease_ms", DEFAULT_HOME_EASE_MS))


func get_latency_offset_ms() -> int:
	return int(_config.get_value("device", "latency_offset_ms", DEFAULT_LATENCY_OFFSET_MS))


func get_vibe_intensity() -> int:
	return int(_config.get_value("device", "vibe_intensity", DEFAULT_VIBE_INTENSITY))


func get_max_stroke_speed() -> int:
	return int(_config.get_value("device", "max_stroke_speed", DEFAULT_MAX_STROKE_SPEED))


# Serial stroke smoothing factor, clamped to a sane band (a value < 1 would make the OSR finish each
# move early and step; too high softens/lags the motion).
func get_serial_interp_factor() -> float:
	return clampf(
		float(_config.get_value("device", "serial_interp_factor", DEFAULT_SERIAL_INTERP_FACTOR)),
		1.0,
		4.0
	)


func set_serial_interp_factor(value: float) -> void:
	_config.set_value("device", "serial_interp_factor", clampf(value, 1.0, 4.0))


# ── Device routing ──
func get_stroke_target() -> String:
	return str(_config.get_value("routing", "stroke_target", DEFAULT_STROKE_TARGET))


func get_vibration_routes() -> Dictionary:
	var v: Variant = _config.get_value("routing", "vibration_routes", {})
	return (v as Dictionary).duplicate() if v is Dictionary else {}


func get_constrict_routes() -> Dictionary:
	var v: Variant = _config.get_value("routing", "constrict_routes", {})
	return (v as Dictionary).duplicate() if v is Dictionary else {}


# Per-backend output delay (ms). Both default to the legacy single latency_offset_ms, so a
# setup's tuned value carries forward until the user overrides a backend explicitly.
# The Handy (direct WiFi) — cloud-API connection key + its own latency offset
# (applied as a script-time shift when starting synced playback).
func get_handy_connection_key() -> String:
	return str(_config.get_value("handy", "connection_key", ""))


# Handy API v3 APPLICATION ID — the X-Api-Key value that authenticates device
# calls (distinct from the user's per-device connection key, and from the
# "application key" which only mints tokens). Ships baked into the build; this
# override lets the dev supply it via settings instead of source. Empty falls
# back to HandyService.DEFAULT_APP_ID.
func get_handy_app_id() -> String:
	return str(_config.get_value("handy", "app_id", ""))


func get_handy_delay_ms() -> int:
	return int(_config.get_value("handy", "delay_ms", 0))


func get_serial_delay_ms() -> int:
	return int(_config.get_value("device", "serial_delay_ms", get_latency_offset_ms()))


func get_intiface_delay_ms() -> int:
	return int(_config.get_value("device", "intiface_delay_ms", get_latency_offset_ms()))


# ── Constrict auto state machine (tuning; read by FunscriptPlayer) ──
func get_constrict_max_level() -> int:
	return int(_config.get_value("constrict", "max_level", DEFAULT_CONSTRICT_MAX_LEVEL))


func get_constrict_level1_threshold() -> float:
	return float(_config.get_value("constrict", "level1_threshold", DEFAULT_CONSTRICT_L1_THRESHOLD))


func get_constrict_level1_sustain_ms() -> int:
	return int(_config.get_value("constrict", "level1_sustain_ms", DEFAULT_CONSTRICT_L1_SUSTAIN_MS))


func get_constrict_release_threshold() -> float:
	return float(
		_config.get_value("constrict", "release_threshold", DEFAULT_CONSTRICT_RELEASE_THRESHOLD)
	)


func get_constrict_release_sustain_ms() -> int:
	return int(
		_config.get_value("constrict", "release_sustain_ms", DEFAULT_CONSTRICT_RELEASE_SUSTAIN_MS)
	)


func get_constrict_min_hold_ms() -> int:
	return int(_config.get_value("constrict", "min_hold_ms", DEFAULT_CONSTRICT_MIN_HOLD_MS))


func get_constrict_level2_enabled() -> bool:
	return bool(_config.get_value("constrict", "level2_enabled", DEFAULT_CONSTRICT_L2_ENABLED))


func get_constrict_level2_threshold() -> float:
	return float(_config.get_value("constrict", "level2_threshold", DEFAULT_CONSTRICT_L2_THRESHOLD))


func get_constrict_level2_sustain_ms() -> int:
	return int(_config.get_value("constrict", "level2_sustain_ms", DEFAULT_CONSTRICT_L2_SUSTAIN_MS))


func get_constrict_level2_final_percent() -> float:
	return float(
		_config.get_value("constrict", "level2_final_percent", DEFAULT_CONSTRICT_L2_FINAL_PCT)
	)


func get_constrict_hold_on_pause() -> bool:
	return bool(_config.get_value("constrict", "hold_on_pause", DEFAULT_CONSTRICT_HOLD_ON_PAUSE))


func get_hud_hide_delay() -> float:
	return float(_config.get_value("display", "hud_hide_delay", DEFAULT_HUD_HIDE_DELAY))


func get_ui_scale() -> float:
	return float(_config.get_value("display", "ui_scale", DEFAULT_UI_SCALE))


func get_beat_bar_enabled() -> bool:
	return bool(_config.get_value("display", "beat_bar_enabled", DEFAULT_BEAT_BAR_ENABLED))


# Shows time left in the round on the HUD bar. Off by default so the HUD doesn't change under
# existing players; it hides with the rest of the HUD under a Fog effect.
func get_round_timer_enabled() -> bool:
	return bool(_config.get_value("display", "round_timer_enabled", DEFAULT_ROUND_TIMER_ENABLED))


func set_round_timer_enabled(value: bool) -> void:
	_config.set_value("display", "round_timer_enabled", value)


# Multiplies the font size of narrative text — fork titles/descriptions, boss intro cards,
# storyboard dialogue. Layout is unchanged, so very large values can crowd a card; 2.0 is the
# practical ceiling.
func get_story_text_scale() -> float:
	return clampf(
		float(_config.get_value("display", "story_text_scale", DEFAULT_STORY_TEXT_SCALE)), 1.0, 2.0
	)


func set_story_text_scale(value: float) -> void:
	_config.set_value("display", "story_text_scale", clampf(value, 1.0, 2.0))


# Multiplies tooltip font size app-wide (applied via UITheme.apply_tooltip_scale).
func get_tooltip_text_scale() -> float:
	return clampf(
		float(_config.get_value("display", "tooltip_text_scale", DEFAULT_TOOLTIP_TEXT_SCALE)),
		1.0,
		2.0
	)


func set_tooltip_text_scale(value: float) -> void:
	_config.set_value("display", "tooltip_text_scale", clampf(value, 1.0, 2.0))


# Marker shape on the beat bar — "heart" / "orb" / "diamond" / "star" (BeatBar.SHAPES).
# Unknown values fall back to the default rather than drawing nothing.
func get_beat_bar_shape() -> String:
	return str(_config.get_value("display", "beat_bar_shape", DEFAULT_BEAT_BAR_SHAPE))


func set_beat_bar_shape(value: String) -> void:
	_config.set_value("display", "beat_bar_shape", value)


# Video-vs-graph split of the clip editor, clamped to a usable band so a saved value can never
# hide either pane entirely (the graph also enforces its own pixel minimum at layout time).
func get_preview_video_split() -> float:
	return clampf(
		float(_config.get_value("builder", "preview_video_split", DEFAULT_PREVIEW_VIDEO_SPLIT)),
		0.2,
		0.9
	)


func set_preview_video_split(value: float) -> void:
	_config.set_value("builder", "preview_video_split", clampf(value, 0.2, 0.9))


# Left-column (video/graph) share of the clip editor's width, clamped so neither the video nor the
# timeline column can be dragged uselessly small.
func get_preview_columns_split() -> float:
	return clampf(
		float(_config.get_value("builder", "preview_columns_split", DEFAULT_PREVIEW_COLUMNS_SPLIT)),
		0.4,
		0.85
	)


func set_preview_columns_split(value: float) -> void:
	_config.set_value("builder", "preview_columns_split", clampf(value, 0.4, 0.85))


func get_filler_enabled() -> bool:
	return bool(_config.get_value("storyboard_filler", "enabled", DEFAULT_FILLER_ENABLED))


func get_filler_half_cycle_ms() -> int:
	return int(_config.get_value("storyboard_filler", "half_cycle_ms", DEFAULT_FILLER_HALF_CYCLE))


func get_filler_lo() -> int:
	return int(_config.get_value("storyboard_filler", "lo", DEFAULT_FILLER_LO))


func get_filler_hi() -> int:
	return int(_config.get_value("storyboard_filler", "hi", DEFAULT_FILLER_HI))


# Root folder for journey content. Either the default Godot user-data path
# (`user://journeys`) or an OS-absolute path the user picked via Options →
# Journey Storage Location. Consumers that need an OS path can pass the result
# through `ProjectSettings.globalize_path` — it's a no-op for absolute paths.
func get_journeys_dir() -> String:
	return str(_config.get_value("storage", "journeys_dir", DEFAULT_JOURNEYS_DIR))


# Optional folder holding ffmpeg + ffprobe. Empty = use the bundled binaries (or
# the system PATH). Lets users on Wine / unusual setups point at a working
# ffmpeg when the bundled one can't run.
func get_ffmpeg_dir() -> String:
	return str(_config.get_value("transcode", "ffmpeg_dir", DEFAULT_FFMPEG_DIR))


# Resolves an ffmpeg tool ("ffmpeg" / "ffprobe") to a runnable path: custom
# folder → bundled (res:// in the editor, user:// or next-to-app in exports) →
# bare name (system PATH). Pure lookup — no PCK extraction (the builder handles
# that). Single source of truth so the builder and the Options "Test" button
# can't drift apart.
func resolve_ffmpeg_binary(name: String) -> String:
	var exe: String = name + ".exe" if OS.get_name() == "Windows" else name
	var dir: String = get_ffmpeg_dir()
	if dir != "":
		# Try the platform-suffixed name and the bare name (covers a folder of
		# Linux-style binaries used from a Windows build).
		for cand_name: String in [exe, name]:
			var cand: String = dir.path_join(cand_name)
			if FileAccess.file_exists(cand):
				return cand
	if OS.has_feature("editor"):
		var bundled: String = ProjectSettings.globalize_path("res://bin/" + exe)
		if FileAccess.file_exists(bundled):
			return bundled
	else:
		var user_abs: String = ProjectSettings.globalize_path("user://bin/" + exe)
		if FileAccess.file_exists(user_abs):
			return user_abs
		var next_to_app: String = OS.get_executable_path().get_base_dir() + "/bin/" + exe
		if FileAccess.file_exists(next_to_app):
			return next_to_app
	return name  # last resort: PATH lookup


# When true (default), the builder automatically converts videos on save so they
# play: non-H.264 codecs are transcoded, and H.264 in a pixel format the runtime
# decoder can't handle (10-bit, 4:2:2/4:4:4) is re-encoded to 8-bit 4:2:0. When
# false, NO transcoding happens — videos are copied as-is (the author takes
# responsibility for compatibility, and ffmpeg isn't required).
func get_auto_transcode() -> bool:
	return bool(_config.get_value("transcode", "auto_transcode", DEFAULT_AUTO_TRANSCODE))


# When true (default), the main menu pings GitHub once per launch to see if a
# newer release exists and shows an update banner. Off = no network call, no
# banner — for players who'd rather the app never phone home.
func get_update_check_enabled() -> bool:
	return bool(_config.get_value("updates", "check_on_launch", DEFAULT_UPDATE_CHECK))


func get_ui_sound_enabled() -> bool:
	return bool(_config.get_value("audio", "ui_sound_enabled", DEFAULT_UI_SOUND_ENABLED))


func get_ui_sound_volume() -> float:
	return float(_config.get_value("audio", "ui_sound_volume", DEFAULT_UI_SOUND_VOLUME))


# ── Setters ─────────────────────────────────────────────────────────────────
# Setters mutate the in-memory config only. Call save() to persist.


func set_master_volume(value: float) -> void:
	_config.set_value("audio", "master_volume", value)


func set_music_volume(value: float) -> void:
	_config.set_value("audio", "music_volume", value)


func set_fullscreen(value: bool) -> void:
	_config.set_value("display", "fullscreen", value)


func set_resolution_index(value: int) -> void:
	_config.set_value("display", "resolution_index", value)


func set_intiface_address(value: String) -> void:
	_config.set_value("intiface", "address", value)


func set_intiface_auto_connect(value: bool) -> void:
	_config.set_value("intiface", "auto_connect", value)


func set_selected_device(value: String) -> void:
	_config.set_value("intiface", "selected_device", value)


func set_serial_port(value: String) -> void:
	_config.set_value("serial", "port", value)


func set_serial_baud(value: int) -> void:
	_config.set_value("serial", "baud_rate", value)


func set_serial_auto_connect(value: bool) -> void:
	_config.set_value("serial", "auto_connect", value)


func set_range_min(value: int) -> void:
	_config.set_value("device", "range_min", value)


func set_range_max(value: int) -> void:
	_config.set_value("device", "range_max", value)


func set_axis_range_min(axis: String, value: int) -> void:
	_config.set_value("device", "axis_%s_range_min" % axis, value)


func set_axis_range_max(axis: String, value: int) -> void:
	_config.set_value("device", "axis_%s_range_max" % axis, value)


func set_home_position(value: int) -> void:
	_config.set_value("device", "home_position", value)


func set_home_ease_ms(value: int) -> void:
	_config.set_value("device", "home_ease_ms", value)


func set_vibe_intensity(value: int) -> void:
	_config.set_value("device", "vibe_intensity", value)


func set_max_stroke_speed(value: int) -> void:
	_config.set_value("device", "max_stroke_speed", value)


# ── Device routing ──
func set_stroke_target(value: String) -> void:
	_config.set_value("routing", "stroke_target", value)


func set_vibration_routes(value: Dictionary) -> void:
	_config.set_value("routing", "vibration_routes", value)


func set_constrict_routes(value: Dictionary) -> void:
	_config.set_value("routing", "constrict_routes", value)


func set_handy_connection_key(value: String) -> void:
	_config.set_value("handy", "connection_key", value.strip_edges())


func set_handy_delay_ms(value: int) -> void:
	_config.set_value("handy", "delay_ms", value)


func set_serial_delay_ms(value: int) -> void:
	_config.set_value("device", "serial_delay_ms", value)


func set_intiface_delay_ms(value: int) -> void:
	_config.set_value("device", "intiface_delay_ms", value)


func set_hud_hide_delay(value: float) -> void:
	_config.set_value("display", "hud_hide_delay", value)


func set_ui_scale(value: float) -> void:
	_config.set_value("display", "ui_scale", value)


# Applies the stored UI scale to the root window. content_scale_factor multiplies
# all GUI content, so a higher value makes the whole interface bigger — useful on
# high-DPI / 4K displays where the native 1080p layout looks small. Safe to call
# any time (boot or live from Options).
func apply_ui_scale() -> void:
	var w: Window = get_window()
	if w != null:
		w.content_scale_factor = get_ui_scale()


func set_beat_bar_enabled(value: bool) -> void:
	_config.set_value("display", "beat_bar_enabled", value)


func set_filler_enabled(value: bool) -> void:
	_config.set_value("storyboard_filler", "enabled", value)


func set_filler_half_cycle_ms(value: int) -> void:
	_config.set_value("storyboard_filler", "half_cycle_ms", value)


func set_filler_lo(value: int) -> void:
	_config.set_value("storyboard_filler", "lo", value)


func set_filler_hi(value: int) -> void:
	_config.set_value("storyboard_filler", "hi", value)


func set_journeys_dir(value: String) -> void:
	_config.set_value("storage", "journeys_dir", value)


func set_ffmpeg_dir(value: String) -> void:
	_config.set_value("transcode", "ffmpeg_dir", value)


func set_auto_transcode(value: bool) -> void:
	_config.set_value("transcode", "auto_transcode", value)


func set_update_check_enabled(value: bool) -> void:
	_config.set_value("updates", "check_on_launch", value)


func set_ui_sound_enabled(value: bool) -> void:
	_config.set_value("audio", "ui_sound_enabled", value)


func set_ui_sound_volume(value: float) -> void:
	_config.set_value("audio", "ui_sound_volume", value)


# ── Persistence ─────────────────────────────────────────────────────────────


func save() -> void:
	_config.save(SETTINGS_PATH)
