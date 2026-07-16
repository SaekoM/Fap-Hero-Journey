class_name RandomizerRun
extends RefCounted
## Turns a generated journey (RandomizerGenerator.generate) into a playable temp
## journey folder, and — on request — promotes it to a permanent catalogue journey.
##
## A run folder lives at user://randomizer_runs/<id>/ with journey.json + content/.
## The pooled clip files are HARDLINKED from the library store when possible (both
## are under user://, so it's instant + zero extra disk), falling back to a byte
## copy across volumes. Temp runs live OUTSIDE the catalogue's journeys dir, so the
## scanner never sees them; they're wiped on the next generate + on request.
##
## Paths in the generated journey.json are relative ("content/m_<fp>.<ext>"), and
## the library store names pooled files by the same fingerprint, so a link/copy of
## the same rel into the run folder resolves correctly (JourneyGraph.resolve_paths
## prepends the run folder as base — see the _abs note in JourneyGraph).

const RUNS_DIR: String = "user://randomizer_runs"


# Materializes a run. `journey` is the generator's journey dict, `content_rels`
# the pooled rels it references (relative to the library store). Returns
# { ok:bool, reason:String, folder:String (abs user:// path), folder_name:String }.
static func materialize(journey: Dictionary, content_rels: Array, store_dir: String) -> Dictionary:
	var run_id: String = "run_%x_%04x" % [int(Time.get_unix_time_from_system()), randi() & 0xFFFF]
	var folder: String = RUNS_DIR + "/" + run_id
	# Fresh folder (defensive — id collisions are astronomically unlikely, but a
	# leftover from a crashed run must not bleed in).
	JourneyData.delete_dir_recursive(folder)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder + "/content"))

	for rel: String in content_rels:
		var src: String = store_dir + "/" + rel
		var dst: String = folder + "/" + rel
		if not FileAccess.file_exists(ProjectSettings.globalize_path(src)):
			JourneyData.delete_dir_recursive(folder)
			return _fail("missing_pooled_file", rel)
		if not _link_or_copy(src, dst):
			JourneyData.delete_dir_recursive(folder)
			return _fail("link_failed", rel)

	if not _write_journey_json(folder, journey):
		JourneyData.delete_dir_recursive(folder)
		return _fail("json_write_failed", "")

	return {"ok": true, "reason": "", "folder": folder, "folder_name": run_id}


# Deletes every temp run folder. Call before generating a new run (and/or on app
# exit) so ephemeral runs don't accumulate. Each run's folder name is also its
# scoreboard/save key (it's the journey folder_name the runtime records under), so
# clear those first — otherwise a one-shot run's per-run scoreboard + resume-save
# would orphan in user:// forever. (Kept runs live in the catalogue under a
# different name, so their boards are untouched.)
static func clear_all() -> void:
	var dir: DirAccess = DirAccess.open(RUNS_DIR)
	if dir != null:
		dir.list_dir_begin()
		var run_id: String = dir.get_next()
		while run_id != "":
			if dir.current_is_dir() and run_id != "." and run_id != "..":
				ScoreboardService.clear(run_id)
				JourneySaveService.delete_save(run_id)
			run_id = dir.get_next()
		dir.list_dir_end()
	JourneyData.delete_dir_recursive(RUNS_DIR)


# Promotes a materialized run to a permanent, self-contained catalogue journey:
# copies (never links) the folder into the journeys dir under a sanitized name, so
# it survives later library edits. Rewrites journey.json's Name. Returns
# { ok, reason, folder, folder_name }. `journeys_dir` defaults to the configured
# catalogue location.
static func keep(run_folder: String, display_name: String, journeys_dir: String = "") -> Dictionary:
	if journeys_dir == "":
		journeys_dir = SettingsService.get_journeys_dir()
	var folder_name: String = JourneyData.sanitize_folder_name(display_name)
	if folder_name == "":
		folder_name = "random_run"
	var dest: String = journeys_dir + "/" + folder_name
	# Don't clobber an existing catalogue journey — suffix until unique.
	var unique: String = dest
	var n: int = 2
	while DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(unique)):
		unique = "%s_%d" % [dest, n]
		n += 1
	dest = unique

	if not _copy_tree(run_folder, dest):
		JourneyData.delete_dir_recursive(dest)
		return _fail("copy_failed", "")

	# Stamp the display name into the copied journey.json (the run used a generic name), plus the
	# journey identity + version fields. This is the moment a throwaway run becomes a permanent,
	# shareable catalogue journey, so it's where those belong: the generator can't mint the id
	# itself without breaking its own contract (it is pure and seeded — same seed, same journey —
	# and a random id would make every generation differ).
	var data: Dictionary = _read_journey_json(dest)
	if not data.is_empty():
		data["Name"] = display_name
		JourneyData.stamp_journey_identity(data, str(data.get("JourneyId", "")))
		_write_journey_json(dest, data)

	return {"ok": true, "reason": "", "folder": dest, "folder_name": dest.get_file()}


# ── I/O helpers ──────────────────────────────────────────────────────────────


# Hardlinks src→dst (instant, same-volume), falling back to a byte copy. Both
# paths are user:// (or absolute); the dst parent is created first.
static func _link_or_copy(src: String, dst: String) -> bool:
	var src_abs: String = ProjectSettings.globalize_path(src)
	var dst_abs: String = ProjectSettings.globalize_path(dst)
	DirAccess.make_dir_recursive_absolute(dst_abs.get_base_dir())
	if _hardlink(src_abs, dst_abs):
		return true
	return _copy_file(src_abs, dst_abs)


# OS-level hardlink. Windows: mklink /H (no admin needed); Unix: ln. Returns true
# only when the link file actually appears — a nonzero exit or cross-volume
# refusal falls through to the copy path.
static func _hardlink(src_abs: String, dst_abs: String) -> bool:
	if FileAccess.file_exists(dst_abs):
		return true
	var out: Array = []
	if OS.get_name() == "Windows":
		OS.execute("cmd", ["/c", "mklink", "/H", dst_abs, src_abs], out, true, false)
	else:
		OS.execute("ln", [src_abs, dst_abs], out, true, false)
	return FileAccess.file_exists(dst_abs)


static func _copy_file(src_abs: String, dst_abs: String) -> bool:
	var sf: FileAccess = FileAccess.open(src_abs, FileAccess.READ)
	if sf == null:
		return false
	var bytes: PackedByteArray = sf.get_buffer(sf.get_length())
	sf.close()
	var df: FileAccess = FileAccess.open(dst_abs, FileAccess.WRITE)
	if df == null:
		return false
	df.store_buffer(bytes)
	df.close()
	return true


# Recursively copies a directory tree with real byte copies (used by keep so the
# result is independent of the library store's hardlinked originals).
static func _copy_tree(src: String, dst: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst))
	var dir: DirAccess = DirAccess.open(src)
	if dir == null:
		return false
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		var child_src: String = src + "/" + name
		var child_dst: String = dst + "/" + name
		if dir.current_is_dir():
			if not _copy_tree(child_src, child_dst):
				dir.list_dir_end()
				return false
		elif not _copy_file(
			ProjectSettings.globalize_path(child_src), ProjectSettings.globalize_path(child_dst)
		):
			dir.list_dir_end()
			return false
		name = dir.get_next()
	dir.list_dir_end()
	return true


static func _write_journey_json(folder: String, journey: Dictionary) -> bool:
	var f: FileAccess = FileAccess.open(folder + "/journey.json", FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(journey, "\t"))
	f.close()
	return true


static func _read_journey_json(folder: String) -> Dictionary:
	var f: FileAccess = FileAccess.open(folder + "/journey.json", FileAccess.READ)
	if f == null:
		return {}
	var parser := JSON.new()
	var err: int = parser.parse(f.get_as_text())
	f.close()
	if err != OK or not (parser.data is Dictionary):
		return {}
	return parser.data


static func _fail(reason: String, detail: String) -> Dictionary:
	if detail != "":
		push_warning("RandomizerRun: %s (%s)" % [reason, detail])
	return {"ok": false, "reason": reason, "folder": "", "folder_name": ""}
