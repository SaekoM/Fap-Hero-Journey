extends Node

# ---------------------------------------------------------------------------
# ScoreboardService  (autoload)
#
# Per-journey local run history. One file per journey at
# `user://scoreboards/<journey_folder_name>.json`, keyed the same way as
# JourneySaveService so the two stay in lockstep (a journey rebuild or deletion
# clears both). Pure file I/O — callers hand in a run entry, this stamps the
# date and keeps the list ranked + capped.
#
# A "run" is recorded when a journey ends: completed (reached the end screen) or
# abandoned (quit to menu mid-journey). Save & Quit at a checkpoint is NOT a run
# — it's intent to resume. Test plays never record.
#
# File schema:
#   {
#     "version": int,
#     "journey_folder": String,
#     "runs": [
#       { "score": int, "completed": bool, "rounds_done": int,
#         "rounds_total": int, "date": String (ISO) },
#       ...
#     ]   # ranked by score desc, capped to MAX_RUNS
#   }
#
# C# callers reach this via the autoload node:
#   GetNode("/root/ScoreboardService").Call("add_run", folder, entry)
# ---------------------------------------------------------------------------

const SCOREBOARD_DIR: String = "user://scoreboards"
const SCHEMA_VERSION: int = 1
const MAX_RUNS: int = 10  # the board keeps the top N runs by score


func _ready() -> void:
	var dir_abs: String = ProjectSettings.globalize_path(SCOREBOARD_DIR)
	if not DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.make_dir_recursive_absolute(dir_abs)


func _path_for(journey_folder_name: String) -> String:
	return SCOREBOARD_DIR + "/" + JourneyData.sanitize_folder_name(journey_folder_name) + ".json"


# The whole per-journey record ({version, journey_folder, runs, discovered}). {} when missing/malformed
# or an unsupported version. The single reader so runs and the discovered set share one file safely.
func _read_file(journey_folder_name: String) -> Dictionary:
	if journey_folder_name.is_empty():
		return {}
	var path: String = _path_for(journey_folder_name)
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text: String = f.get_as_text()
	f.close()
	var parser: JSON = JSON.new()
	if parser.parse(text) != OK or not (parser.data is Dictionary):
		printerr("ScoreboardService: malformed scoreboard at %s" % path)
		return {}
	var data: Dictionary = parser.data
	if int(data.get("version", 0)) != SCHEMA_VERSION:
		printerr("ScoreboardService: unsupported version in %s" % path)
		return {}
	return data


# Stamps version + folder and writes the whole record. Creates the dir if needed.
func _write_file(journey_folder_name: String, data: Dictionary) -> void:
	var dir_abs: String = ProjectSettings.globalize_path(SCOREBOARD_DIR)
	if not DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.make_dir_recursive_absolute(dir_abs)
	data["version"] = SCHEMA_VERSION
	data["journey_folder"] = journey_folder_name
	var path: String = _path_for(journey_folder_name)
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("ScoreboardService: cannot open %s for write" % path)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()


# The journey's runs, ranked by score (highest first). Empty array when there's
# no scoreboard yet, the file is missing/malformed, or the version is unsupported.
func read_runs(journey_folder_name: String) -> Array:
	var runs: Array = _read_file(journey_folder_name).get("runs", [])
	runs.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("score", 0)) > int(b.get("score", 0))
	)
	return runs


# Records one run for the journey. The caller supplies score / completed /
# rounds_done / rounds_total; this stamps the date, ranks by score, and caps the
# list to MAX_RUNS. Empty folder name is a no-op (e.g. a malformed journey).
# Returns the run's 1-based rank on the board (1 = new best), or 0 when the run
# didn't make the top MAX_RUNS — the end screen's high-score flash reads this.
func add_run(journey_folder_name: String, entry: Dictionary) -> int:
	if journey_folder_name.is_empty():
		return 0
	var data: Dictionary = _read_file(journey_folder_name)  # keep the discovered set alongside
	var runs: Array = data.get("runs", [])
	var record: Dictionary = entry.duplicate()
	record["date"] = Time.get_datetime_string_from_system()
	runs.append(record)
	runs.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("score", 0)) > int(b.get("score", 0))
	)
	# Rank by identity (is_same), before the cap trims the tail.
	var rank: int = 0
	for i: int in runs.size():
		if is_same(runs[i], record):
			rank = i + 1
			break
	if runs.size() > MAX_RUNS:
		runs = runs.slice(0, MAX_RUNS)
	if rank > MAX_RUNS:
		rank = 0

	data["runs"] = runs
	_write_file(journey_folder_name, data)
	return rank


# The persistent set of node ids the player has EVER reached in this journey (across all playthroughs) —
# drives the previewer's mystery-reveal. Distinct from the per-run fog set, which resets each run.
func read_discovered(journey_folder_name: String) -> Array:
	return _read_file(journey_folder_name).get("discovered", [])


# Unions `node_ids` into the journey's persistent discovered set, preserving the run history. No-op for an
# empty folder / id list or when nothing is new; returns true when the set grew (a node seen for the
# first time), so a caller can refresh a preview.
func merge_discovered(journey_folder_name: String, node_ids: Array) -> bool:
	if journey_folder_name.is_empty() or node_ids.is_empty():
		return false
	var data: Dictionary = _read_file(journey_folder_name)
	var discovered: Array = data.get("discovered", [])
	var seen: Dictionary = {}
	for d: Variant in discovered:
		seen[str(d)] = true
	var added: bool = false
	for n: Variant in node_ids:
		var nid: String = str(n)
		if nid != "" and not seen.has(nid):
			seen[nid] = true
			discovered.append(nid)
			added = true
	if not added:
		return false
	data["discovered"] = discovered
	_write_file(journey_folder_name, data)
	return true


# Wipes the journey's run history. Idempotent. Called when the player clears it
# manually, when the journey is deleted, and when the author rebuilds it.
func clear(journey_folder_name: String) -> void:
	if journey_folder_name.is_empty():
		return
	var path: String = _path_for(journey_folder_name)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# True when the journey has at least one recorded run.
func has_runs(journey_folder_name: String) -> bool:
	return not read_runs(journey_folder_name).is_empty()
