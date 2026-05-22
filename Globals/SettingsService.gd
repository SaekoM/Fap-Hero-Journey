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
const DEFAULT_MASTER_VOLUME:     float  = 1.0
const DEFAULT_MUSIC_VOLUME:      float  = 0.5
const DEFAULT_FULLSCREEN:        bool   = false
const DEFAULT_RESOLUTION_INDEX:  int    = 1
const DEFAULT_INTIFACE_ADDRESS:  String = "ws://localhost:12345"
const DEFAULT_INTIFACE_AUTO:     bool   = true
const DEFAULT_SELECTED_DEVICE:   String = ""
const DEFAULT_OUTPUT_MODE:       String = "buttplug"
const DEFAULT_SERIAL_PORT:       String = ""
const DEFAULT_SERIAL_BAUD:       int    = 115200
const DEFAULT_SERIAL_AUTO:       bool   = false
const DEFAULT_RANGE_MIN:         int    = 0
const DEFAULT_RANGE_MAX:         int    = 100
const DEFAULT_HOME_POSITION:     int    = 50
const DEFAULT_HOME_EASE_MS:      int    = 2000
const DEFAULT_LATENCY_OFFSET_MS: int    = 0
const DEFAULT_VIBE_INTENSITY:    int    = 100
const DEFAULT_MAX_STROKE_SPEED:  int    = 0     # 0 = unlimited (units/sec)
const DEFAULT_HUD_HIDE_DELAY:    float  = 3.0   # seconds
const DEFAULT_FILLER_ENABLED:    bool   = false
const DEFAULT_FILLER_HALF_CYCLE: int    = 2000
const DEFAULT_FILLER_LO:         int    = 0
const DEFAULT_FILLER_HI:         int    = 100

var _config: ConfigFile = ConfigFile.new()


func _ready() -> void:
	# A missing file is fine — getters fall back to the canonical defaults.
	_config.load(SETTINGS_PATH)

	# Apply boot-time audio / display settings.
	AudioServer.set_bus_volume_db(0, linear_to_db(get_master_volume()))
	var mode: DisplayServer.WindowMode = DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN \
		if get_fullscreen() else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)


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

func get_range_min() -> int:
	return int(_config.get_value("device", "range_min", DEFAULT_RANGE_MIN))

func get_range_max() -> int:
	return int(_config.get_value("device", "range_max", DEFAULT_RANGE_MAX))

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

func get_hud_hide_delay() -> float:
	return float(_config.get_value("display", "hud_hide_delay", DEFAULT_HUD_HIDE_DELAY))

func get_filler_enabled() -> bool:
	return bool(_config.get_value("storyboard_filler", "enabled", DEFAULT_FILLER_ENABLED))

func get_filler_half_cycle_ms() -> int:
	return int(_config.get_value("storyboard_filler", "half_cycle_ms", DEFAULT_FILLER_HALF_CYCLE))

func get_filler_lo() -> int:
	return int(_config.get_value("storyboard_filler", "lo", DEFAULT_FILLER_LO))

func get_filler_hi() -> int:
	return int(_config.get_value("storyboard_filler", "hi", DEFAULT_FILLER_HI))


# ── Setters ─────────────────────────────────────────────────────────────────
# Setters mutate the in-memory config only. Call save() to persist.

func set_master_volume(v: float) -> void:
	_config.set_value("audio", "master_volume", v)

func set_music_volume(v: float) -> void:
	_config.set_value("audio", "music_volume", v)

func set_fullscreen(v: bool) -> void:
	_config.set_value("display", "fullscreen", v)

func set_resolution_index(v: int) -> void:
	_config.set_value("display", "resolution_index", v)

func set_intiface_address(v: String) -> void:
	_config.set_value("intiface", "address", v)

func set_intiface_auto_connect(v: bool) -> void:
	_config.set_value("intiface", "auto_connect", v)

func set_selected_device(v: String) -> void:
	_config.set_value("intiface", "selected_device", v)

func set_output_mode(v: String) -> void:
	_config.set_value("output", "mode", v)

func set_serial_port(v: String) -> void:
	_config.set_value("serial", "port", v)

func set_serial_baud(v: int) -> void:
	_config.set_value("serial", "baud_rate", v)

func set_serial_auto_connect(v: bool) -> void:
	_config.set_value("serial", "auto_connect", v)

func set_range_min(v: int) -> void:
	_config.set_value("device", "range_min", v)

func set_range_max(v: int) -> void:
	_config.set_value("device", "range_max", v)

func set_home_position(v: int) -> void:
	_config.set_value("device", "home_position", v)

func set_home_ease_ms(v: int) -> void:
	_config.set_value("device", "home_ease_ms", v)

func set_latency_offset_ms(v: int) -> void:
	_config.set_value("device", "latency_offset_ms", v)

func set_vibe_intensity(v: int) -> void:
	_config.set_value("device", "vibe_intensity", v)

func set_max_stroke_speed(v: int) -> void:
	_config.set_value("device", "max_stroke_speed", v)

func set_hud_hide_delay(v: float) -> void:
	_config.set_value("display", "hud_hide_delay", v)

func set_filler_enabled(v: bool) -> void:
	_config.set_value("storyboard_filler", "enabled", v)

func set_filler_half_cycle_ms(v: int) -> void:
	_config.set_value("storyboard_filler", "half_cycle_ms", v)

func set_filler_lo(v: int) -> void:
	_config.set_value("storyboard_filler", "lo", v)

func set_filler_hi(v: int) -> void:
	_config.set_value("storyboard_filler", "hi", v)


# ── Persistence ─────────────────────────────────────────────────────────────

func save() -> void:
	_config.save(SETTINGS_PATH)
