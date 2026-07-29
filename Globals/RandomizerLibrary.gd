extends Node
## Persistent clip library for the randomizer. Holds the registry of clips a run is
## drawn from (video + paired funscript + axis/vib, plus tags / weight / intensity /
## probed durations / last-used), and owns the shared content pool the clips are
## transcoded + deduped into on ADD — so generation later is instant reference
## assembly and a run survives the original source files moving or being deleted.
##
## Registry JSON: user://randomizer_library.json
## Pooled content: user://randomizer_library/content/m_<fingerprint>.<ext>
## (same fingerprint scheme as journey folders, so a rel like content/m_<fp>.mp4 is
## valid verbatim once the file is copied into a run folder's content/.)
##
## The pure selection / graph logic lives in RandomizerGenerator; this service is
## just the data model, persistence, and the pooling I/O.

signal library_changed

const REGISTRY_PATH: String = "user://randomizer_library.json"
const STORE_DIR: String = "user://randomizer_library"
const CONTENT_DIR: String = "user://randomizer_library/content"

# Ordered list of entry dicts (see RandomizerGenerator's header for the shape).
var _entries: Array = []


func _ready() -> void:
	load_registry()


# ── Persistence ──────────────────────────────────────────────────────────────


func load_registry() -> void:
	_entries = []
	if not FileAccess.file_exists(REGISTRY_PATH):
		return
	var f: FileAccess = FileAccess.open(REGISTRY_PATH, FileAccess.READ)
	if f == null:
		return
	var parser := JSON.new()
	var err: int = parser.parse(f.get_as_text())
	f.close()
	if err != OK or not (parser.data is Dictionary):
		push_warning("RandomizerLibrary: registry unparseable; starting empty.")
		return
	var raw: Array = (parser.data as Dictionary).get("entries", [])
	for e: Variant in raw:
		if e is Dictionary:
			_entries.append(_coerce_entry(e))


func save_registry() -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STORE_DIR))
	var f: FileAccess = FileAccess.open(REGISTRY_PATH, FileAccess.WRITE)
	if f == null:
		push_error("RandomizerLibrary: cannot write registry.")
		return false
	f.store_string(JSON.stringify({"version": 1, "entries": _entries}, "\t"))
	f.close()
	return true


# Fills any missing fields so downstream code (and the generator) never has to
# guard. Applied on load and on add.
static func _coerce_entry(e: Dictionary) -> Dictionary:
	return {
		"id": str(e.get("id", "")),
		"name": str(e.get("name", "Clip")),
		# SOURCE paths (originals on the user's disk) — pooling into content/ is now
		# deferred to run time, so these must stay valid until Generate is pressed.
		"video_src": str(e.get("video_src", "")),
		"funscript_src": str(e.get("funscript_src", "")),
		"axis_src": (e.get("axis_src", {}) as Dictionary).duplicate(true),
		"vib_src": (e.get("vib_src", {}) as Dictionary).duplicate(true),
		# Whether the video needs an H.264 re-encode (decided at probe time); drives
		# the predicted pooled extension below and the run-time transcode.
		"needs_transcode": bool(e.get("needs_transcode", false)),
		# PREDICTED pooled rels ("content/m_<fp>.<ext>") — deterministic from the
		# source fingerprint, so the generator can reference them before the file is
		# actually pooled. prepare_entry_media materializes them at run time.
		"video_rel": str(e.get("video_rel", "")),
		"funscript_rel": str(e.get("funscript_rel", "")),
		"axis_rel": (e.get("axis_rel", {}) as Dictionary).duplicate(true),
		"vib_rel": (e.get("vib_rel", {}) as Dictionary).duplicate(true),
		"boss_image_rel": str(e.get("boss_image_rel", "")),
		"action_count": int(e.get("action_count", 0)),
		"length_ms": int(e.get("length_ms", 0)),
		"duration_ms": int(e.get("duration_ms", 0)),
		"tags": (e.get("tags", []) as Array).duplicate(),
		"weight": float(e.get("weight", 1.0)),
		"intensity": clampi(int(e.get("intensity", 3)), 1, 5),
		"last_used": int(e.get("last_used", 0)),
		"added_at": int(e.get("added_at", 0)),
	}


# ── Query / mutate ───────────────────────────────────────────────────────────


func get_all() -> Array:
	return _entries.duplicate(true)


func size() -> int:
	return _entries.size()


func has_id(id: String) -> bool:
	return _index_of(id) >= 0


func update_entry(id: String, changes: Dictionary) -> void:
	var i: int = _index_of(id)
	if i < 0:
		return
	var merged: Dictionary = _entries[i].duplicate(true)
	merged.merge(changes, true)
	_entries[i] = _coerce_entry(merged)
	save_registry()
	# Deliberately NO library_changed here: tag/weight/intensity edits aren't
	# structural, and rebuilding the list would free the control being edited
	# mid-drag. Add/remove (which change the row set) do emit.


func remove_entry(id: String, delete_pooled: bool = true) -> void:
	var i: int = _index_of(id)
	if i < 0:
		return
	var entry: Dictionary = _entries[i]
	_entries.remove_at(i)
	if delete_pooled:
		_delete_orphan_pooled(entry)
	save_registry()
	library_changed.emit()


# Bumps last_used for the given ids to `now` (a generated run marks the clips it
# used, so cross-run freshness deprioritizes them next time).
func mark_used(ids: Array, now: int = 0) -> void:
	if now == 0:
		now = int(Time.get_unix_time_from_system())
	var touched: bool = false
	for id: Variant in ids:
		var i: int = _index_of(str(id))
		if i >= 0:
			_entries[i]["last_used"] = now
			touched = true
	if touched:
		save_registry()


func _index_of(id: String) -> int:
	for i: int in _entries.size():
		if str(_entries[i].get("id", "")) == id:
			return i
	return -1


# ── Add a clip (probe only — pooling is deferred to run time) ─────────────────


# Registers a clip WITHOUT transcoding/copying anything: it only probes the video
# (fast ffprobe) for duration + whether it needs an H.264 re-encode, reads funscript
# stats from the source, and stores the source paths + predicted pooled rels. The
# actual transcode/copy into content/ happens in prepare_entry_media, called only for
# the clips a generated run uses. `video_src` / `funscript_src` / channel sources are
# ABSOLUTE filesystem paths. Re-adding the same video replaces the entry. Because
# pooling is deferred, the SOURCE files must still exist when Generate is pressed.
# Returns { ok, reason, entry }.
func add_clip(
	video_src: String,
	funscript_src: String = "",
	axis_srcs: Dictionary = {},
	vib_srcs: Dictionary = {},
	tags: Array = [],
	weight: float = 1.0,
	intensity: int = 3,
	display_name: String = ""
) -> Dictionary:
	if video_src == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(video_src)):
		return {"ok": false, "reason": "video_missing", "entry": {}}

	# Probe only (metadata) — decides the re-encode need + the predicted pooled ext.
	var info: Dictionary = MediaPoolService.probe_stream_info(video_src)
	var reason: String = MediaPoolService.classify_transcode(
		str(info["codec"]), str(info["pix_fmt"]), false
	)
	# When the probe couldn't run (no ffprobe), assume a re-encode is needed so the
	# predicted .mp4 rel is safe; prepare_entry_media re-checks ffmpeg availability.
	var needs_transcode: bool = reason != "" or not MediaPoolService.is_available()
	var duration_s: float = MediaPoolService.probe_duration_seconds(video_src)

	var vfp: String = JourneyData.media_fingerprint(video_src)
	var vext: String = "mp4" if needs_transcode else video_src.get_extension()
	var video_rel: String = JourneyData.pooled_media_rel(vfp, vext, video_src)

	var stats: Dictionary = _read_script_stats(funscript_src)
	# Auto-rate intensity from the funscript's motion; the passed value is the
	# fallback for a clip imported without a script.
	var rated: int = intensity
	if (
		funscript_src != ""
		and FileAccess.file_exists(ProjectSettings.globalize_path(funscript_src))
	):
		rated = FunscriptIntensity.from_path(funscript_src)

	var now: int = int(Time.get_unix_time_from_system())
	var entry: Dictionary = _coerce_entry(
		{
			"id": vfp,
			"name": display_name if display_name != "" else video_src.get_file().get_basename(),
			"video_src": video_src,
			"funscript_src": funscript_src,
			"axis_src": axis_srcs,
			"vib_src": vib_srcs,
			"needs_transcode": needs_transcode,
			"video_rel": video_rel,
			"funscript_rel": _predict_script_rel(funscript_src),
			"axis_rel": _predict_channel_rels(axis_srcs),
			"vib_rel": _predict_channel_rels(vib_srcs),
			"action_count": int(stats["count"]),
			"length_ms": int(stats["length_ms"]),
			"duration_ms": int(round(duration_s * 1000.0)),
			"tags": tags,
			"weight": weight,
			"intensity": rated,
			"added_at": now,
		}
	)

	var existing: int = _index_of(vfp)
	if existing >= 0:
		# Preserve last_used across a re-add; take the new tags/weight/intensity.
		entry["last_used"] = int(_entries[existing].get("last_used", 0))
		_entries[existing] = entry
	else:
		_entries.append(entry)
	save_registry()
	library_changed.emit()
	return {"ok": true, "reason": "", "entry": entry}


# Attaches (or replaces) a funscript on an existing clip that was imported without
# one — the card's drop zone / browse. Reads stats + predicts the pooled rel; the
# file itself is pooled later by prepare_entry_media. Emits library_changed so the
# card refreshes from a drop zone into a normal script row.
func set_funscript(id: String, funscript_src: String) -> void:
	var i: int = _index_of(id)
	if i < 0 or funscript_src == "":
		return
	if not FileAccess.file_exists(ProjectSettings.globalize_path(funscript_src)):
		return
	var stats: Dictionary = _read_script_stats(funscript_src)
	var merged: Dictionary = _entries[i].duplicate(true)
	merged["funscript_src"] = funscript_src
	merged["funscript_rel"] = _predict_script_rel(funscript_src)
	merged["action_count"] = int(stats["count"])
	merged["length_ms"] = int(stats["length_ms"])
	# The clip had no meaningful intensity before — rate it from the new script.
	merged["intensity"] = FunscriptIntensity.from_path(funscript_src)
	_entries[i] = _coerce_entry(merged)
	save_registry()
	library_changed.emit()


# Removes every clip and wipes the shared content pool. Existing temp runs keep
# working — they hardlink the pooled files, so the inodes survive until those runs
# are cleared too.
func clear_all() -> void:
	_entries = []
	save_registry()
	JourneyData.delete_dir_recursive(CONTENT_DIR)
	library_changed.emit()


func get_entry(id: String) -> Dictionary:
	var i: int = _index_of(id)
	return _entries[i].duplicate(true) if i >= 0 else {}


# ── Run-time pooling (deferred transcode) ─────────────────────────────────────


# Materializes ONE entry's media into the shared pool: transcodes the video to
# H.264 (or copies it) and copies the funscript + axis/vib scripts, all keyed by
# the entry's predicted rels. Idempotent — skips anything already pooled, so a
# re-roll that reuses a clip pays the transcode only once. Called at Generate time
# for each clip the run actually uses. on_progress / should_cancel drive the
# transcode. Returns { ok, reason }.
func prepare_entry_media(
	entry: Dictionary, on_progress: Callable = Callable(), should_cancel: Callable = Callable()
) -> Dictionary:
	var video_src: String = str(entry.get("video_src", ""))
	if video_src == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(video_src)):
		return {"ok": false, "reason": "video_missing"}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CONTENT_DIR))

	var vreason: String = await _pool_video(entry, video_src, on_progress, should_cancel)
	if vreason != "":
		return {"ok": false, "reason": vreason}
	if not _pool_all_scripts(entry):
		return {"ok": false, "reason": "copy_failed"}
	return {"ok": true, "reason": ""}


# Ensures the entry's video is pooled (transcode or copy). Returns "" on success,
# else a failure reason. Idempotent (skips an already-pooled file).
func _pool_video(
	entry: Dictionary, video_src: String, on_progress: Callable, should_cancel: Callable
) -> String:
	var video_dst: String = STORE_DIR + "/" + str(entry.get("video_rel", ""))
	if FileAccess.file_exists(video_dst):
		return ""
	if bool(entry.get("needs_transcode", false)):
		if not MediaPoolService.is_available():
			return "ffmpeg_unavailable"
		var dur: float = float(entry.get("duration_ms", 0)) / 1000.0
		var ok: bool = await MediaPoolService.transcode_video(
			video_src, video_dst, dur, 0, 0, on_progress, should_cancel
		)
		if not ok:
			# A killed/failed encode leaves a truncated file that would later look
			# already-pooled — delete it so a retry re-transcodes cleanly.
			_remove_if_exists(video_dst)
			return "transcode_failed"
		return ""
	if not _copy_file(video_src, video_dst):
		_remove_if_exists(video_dst)
		return "copy_failed"
	return ""


# Pools the funscript + every axis/vib script (small verbatim copies). False if any
# non-empty source fails to pool.
func _pool_all_scripts(entry: Dictionary) -> bool:
	if not _ensure_pooled(str(entry.get("funscript_src", ""))):
		return false
	for src: Variant in (entry.get("axis_src", {}) as Dictionary).values():
		if not _ensure_pooled(str(src)):
			return false
	for src: Variant in (entry.get("vib_src", {}) as Dictionary).values():
		if not _ensure_pooled(str(src)):
			return false
	return true


# True when a script source is empty (nothing to do) or pools successfully.
func _ensure_pooled(src: String) -> bool:
	return src == "" or _pool_script(src) != ""


# ── Helpers ──────────────────────────────────────────────────────────────────


# Copies a funscript-family file into the pool by fingerprint; returns its rel
# ("" for an empty/missing/failed source).
func _pool_script(src: String) -> String:
	if src == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(src)):
		return ""
	var fp: String = JourneyData.media_fingerprint(src)
	var rel: String = JourneyData.pooled_media_rel(fp, "funscript", src)
	var dst: String = STORE_DIR + "/" + rel
	if not FileAccess.file_exists(dst):
		if not _copy_file(src, dst):
			return ""
	return rel


# Predicted pooled rel for a script source ("" for empty/missing) — deterministic
# from the fingerprint, computed WITHOUT copying (the copy is deferred to prepare).
func _predict_script_rel(src: String) -> String:
	if src == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(src)):
		return ""
	return JourneyData.pooled_media_rel(JourneyData.media_fingerprint(src), "funscript", src)


# {channel_key: source} → {channel_key: predicted_rel} (skips empty/missing sources).
func _predict_channel_rels(srcs: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key: String in srcs:
		var rel: String = _predict_script_rel(str(srcs[key]))
		if rel != "":
			out[key] = rel
	return out


# Reads funscript stats {count, length_ms} straight from a source path (no pooling).
func _read_script_stats(src: String) -> Dictionary:
	if src == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(src)):
		return {"count": 0, "length_ms": 0}
	return JourneyData.read_funscript_stats(src)


func _remove_if_exists(path: String) -> void:
	var abs: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)


func _copy_file(src: String, dst: String) -> bool:
	var sf: FileAccess = FileAccess.open(src, FileAccess.READ)
	if sf == null:
		return false
	var bytes: PackedByteArray = sf.get_buffer(sf.get_length())
	sf.close()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst.get_base_dir()))
	var df: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if df == null:
		return false
	df.store_buffer(bytes)
	df.close()
	return true


# When removing an entry, delete its pooled files only if no other entry still
# references the same rel (fingerprint dedup means a rel can be shared).
func _delete_orphan_pooled(entry: Dictionary) -> void:
	var rels: Array = [str(entry.get("video_rel", "")), str(entry.get("funscript_rel", ""))]
	for ax: Variant in (entry.get("axis_rel", {}) as Dictionary).values():
		rels.append(str(ax))
	for vb: Variant in (entry.get("vib_rel", {}) as Dictionary).values():
		rels.append(str(vb))
	for rel: String in rels:
		if rel == "" or _rel_still_referenced(rel):
			continue
		var abs: String = ProjectSettings.globalize_path(STORE_DIR + "/" + rel)
		if FileAccess.file_exists(abs):
			DirAccess.remove_absolute(abs)


func _rel_still_referenced(rel: String) -> bool:
	for e: Dictionary in _entries:
		if str(e.get("video_rel", "")) == rel or str(e.get("funscript_rel", "")) == rel:
			return true
		if rel in (e.get("axis_rel", {}) as Dictionary).values():
			return true
		if rel in (e.get("vib_rel", {}) as Dictionary).values():
			return true
	return false
