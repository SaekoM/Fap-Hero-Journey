extends Node

# ---------------------------------------------------------------------------
# JourneySaveService  (autoload)
#
# Per-journey resume data persistence. One save file per journey, stored at
# `user://journey_saves/<journey_folder_name>.json`. New saves overwrite the
# previous one (single-slot design — see design notes).
#
# This service is just file I/O — it has no knowledge of the game's state
# structure. Callers (GameLoop / GameState) capture the snapshot, hand it in,
# and reverse the process on load. Keeping the schema opaque here means the
# service doesn't need to change when game state evolves.
#
# Save schema (the position fields come straight from GameState.CaptureSaveData;
# the runtime walks the journey GRAPH, so a save snapshots the current node id,
# not the old spliced-sequence index):
#   {
#     "version":          int        — for forward-compat if we change shape
#     "saved_at":         String     — ISO timestamp (display + sort)
#     "journey_folder":   String     — sanity check on load
#     "current_node":     String     — GameState._currentId (resume position)
#     "rounds_entered":   int        — rounds walked so far (progress number)
#     "flags":            Array      — journey flags set up to the save point
#     "discovered":       Array      — fog-of-war discovered node ids
#     "coins":            int        — CoinService balance
#     "score":            int        — ScoreService cumulative score
#     "total_actions":    int        — for end-screen stat
#     "inventory":        Array      — owned items (active effects NOT saved)
#     "round_names":      Array      — round-name log for the end screen
#     "route_trail":      Array      — visited node ids for the end-screen recap
#   }
#
# C# callers reach this via the autoload node:
#   GetNode("/root/JourneySaveService").Call("has_save", folder).AsBool()
# ---------------------------------------------------------------------------

const SAVES_DIR: String = "user://journey_saves"
# Part-1 → Part-2 carryover (feature #5): a completed BASE run's end-state, kept so an installed rendition
# (sequel) can resume from its attach point with the coins / score / items / flags / counters intact. Keyed
# by the base's JourneyId (stable across reinstalls, unlike the folder name), NOT consumed on read the way a
# resume save is — a base completion can seed several renditions and be replayed.
const CARRYOVER_DIR: String = "user://journey_carryover"
const SCHEMA_VERSION: int = 1


func _ready() -> void:
	# Lazily create the storage directories so the first write doesn't fail.
	for d: String in [SAVES_DIR, CARRYOVER_DIR]:
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(d)):
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))


# Returns the absolute path where a journey's save file would live. Used both
# for read and write; nonexistence at this path means "no save for this
# journey."
func _save_path_for(journey_folder_name: String) -> String:
	return SAVES_DIR + "/" + JourneyData.sanitize_folder_name(journey_folder_name) + ".json"


# True when a non-empty save file exists for this journey. JourneySelect uses
# this to choose between Resume / Play UI.
func has_save(journey_folder_name: String) -> bool:
	if journey_folder_name.is_empty():
		return false
	var path: String = _save_path_for(journey_folder_name)
	if not FileAccess.file_exists(path):
		return false
	# Guard against zero-byte / truncated files from an interrupted write.
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var length: int = f.get_length()
	f.close()
	return length > 0


# Reads and parses the save for the given journey. Returns {} if no save, the
# file is missing, the JSON is malformed, or the schema version is unsupported.
# Errors are logged via printerr so a misbehaving save file is diagnosable
# without surfacing a modal to the user (they just see "no save available").
func read_save(journey_folder_name: String) -> Dictionary:
	if not has_save(journey_folder_name):
		return {}
	var path: String = _save_path_for(journey_folder_name)
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		printerr("JourneySaveService: cannot open %s for read" % path)
		return {}
	var text: String = f.get_as_text()
	f.close()
	var parser: JSON = JSON.new()
	if parser.parse(text) != OK:
		printerr("JourneySaveService: JSON parse failed for %s" % path)
		return {}
	if not (parser.data is Dictionary):
		printerr("JourneySaveService: save is not a Dictionary: %s" % path)
		return {}
	var data: Dictionary = parser.data
	var version: int = int(data.get("version", 0))
	if version != SCHEMA_VERSION:
		# A future-us could migrate older versions here. For now, refuse rather
		# than risk loading mismatched state.
		printerr("JourneySaveService: unsupported save version %d in %s" % [version, path])
		return {}
	return data


# Writes a save for the given journey, overwriting any previous file. Caller
# supplies a Dictionary with the game-state portion of the schema; this
# service stamps in `version`, `saved_at`, and `journey_folder` so callers
# can't forget those fields.
#
# Returns true on success. Failures (disk full, permissions) log via printerr.
func write_save(journey_folder_name: String, payload: Dictionary) -> bool:
	if journey_folder_name.is_empty():
		printerr("JourneySaveService: cannot write save with empty journey folder name")
		return false
	# Ensure the directory exists at write time too — Options' storage-location
	# change can move user:// indirectly, and we want to be defensive about it.
	var dir_abs: String = ProjectSettings.globalize_path(SAVES_DIR)
	if not DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.make_dir_recursive_absolute(dir_abs)

	var record: Dictionary = payload.duplicate()
	record["version"] = SCHEMA_VERSION
	record["saved_at"] = Time.get_datetime_string_from_system()
	record["journey_folder"] = journey_folder_name

	var path: String = _save_path_for(journey_folder_name)
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("JourneySaveService: cannot open %s for write" % path)
		return false
	f.store_string(JSON.stringify(record, "\t"))
	f.close()
	return true


# Removes the save for the given journey. Idempotent — silently does nothing
# if no save existed. Called from "New Run" flow when the player chooses to
# overwrite an existing save, and from end-of-journey to clean up the save
# after a successful completion.
func delete_save(journey_folder_name: String) -> void:
	if journey_folder_name.is_empty():
		return
	var path: String = _save_path_for(journey_folder_name)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# Convenience: when did the save happen? Used by the catalogue to display
# something like "Saved 2 days ago". Returns "" when no save exists.
func get_save_timestamp(journey_folder_name: String) -> String:
	var data: Dictionary = read_save(journey_folder_name)
	return data.get("saved_at", "") as String


# ---------------------------------------------------------------------------
# Part-1 → Part-2 carryover  (feature #5)
#
# Same opaque-payload I/O as the resume save above, but keyed by a base journey's
# JourneyId and stored separately. A resume save is per-run and consumed on load;
# a carryover is a base COMPLETION snapshot that persists — one base completion can
# seed multiple installed renditions, and replaying Part 1 overwrites it (latest run).
# Callers add the same run-state fields plus `reached_node` (the ending the player
# finished on, used to match the rendition's anchor).
# ---------------------------------------------------------------------------


func _carryover_path_for(base_id: String) -> String:
	return CARRYOVER_DIR + "/" + JourneyData.sanitize_folder_name(base_id) + ".json"


# True when a non-empty Part-1 carryover exists for this base JourneyId.
func has_carryover(base_id: String) -> bool:
	if base_id.is_empty():
		return false
	var path: String = _carryover_path_for(base_id)
	if not FileAccess.file_exists(path):
		return false
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var length: int = f.get_length()
	f.close()
	return length > 0


# Reads and parses the carryover for a base JourneyId. {} on absence / malformed / version mismatch.
func read_carryover(base_id: String) -> Dictionary:
	if not has_carryover(base_id):
		return {}
	var path: String = _carryover_path_for(base_id)
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		printerr("JourneySaveService: cannot open %s for read" % path)
		return {}
	var text: String = f.get_as_text()
	f.close()
	var parser: JSON = JSON.new()
	if parser.parse(text) != OK or not (parser.data is Dictionary):
		printerr("JourneySaveService: carryover JSON parse failed for %s" % path)
		return {}
	var data: Dictionary = parser.data
	if int(data.get("version", 0)) != SCHEMA_VERSION:
		printerr("JourneySaveService: unsupported carryover version in %s" % path)
		return {}
	return data


# Writes (overwrites) the Part-1 carryover for a base JourneyId. Caller supplies the run-state payload plus
# `reached_node`; this stamps version / saved_at / base_id. Returns true on success.
func write_carryover(base_id: String, payload: Dictionary) -> bool:
	if base_id.is_empty():
		printerr("JourneySaveService: cannot write carryover with empty base id")
		return false
	var dir_abs: String = ProjectSettings.globalize_path(CARRYOVER_DIR)
	if not DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.make_dir_recursive_absolute(dir_abs)

	var record: Dictionary = payload.duplicate()
	record["version"] = SCHEMA_VERSION
	record["saved_at"] = Time.get_datetime_string_from_system()
	record["base_id"] = base_id

	var path: String = _carryover_path_for(base_id)
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("JourneySaveService: cannot open %s for write" % path)
		return false
	f.store_string(JSON.stringify(record, "\t"))
	f.close()
	return true


# Removes the carryover for a base JourneyId. Idempotent.
func delete_carryover(base_id: String) -> void:
	if base_id.is_empty():
		return
	var path: String = _carryover_path_for(base_id)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
