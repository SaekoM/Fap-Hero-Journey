extends Node
## Persistent clip library for the randomizer. Holds the registry of clips a run is
## drawn from (video + paired funscript + axis/vib, plus tags / weight / intensity /
## probed durations / last-used / the funscript-derived beats a run cuts parts from,
## see the randomizer-parts contract), and owns the shared content pool the clips are
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

# Separator between the video fingerprint and the segment identity in a part id
# ("<video_id>#trim:<a>-<b>"). See _video_id_of for why it lives here as well.
const PART_ID_SEP: String = "#"

# Block size of the chunked pooled-video copy (see _copy_file_chunked).
const COPY_CHUNK_BYTES: int = 8 * 1024 * 1024

# Ordered list of entry dicts (see RandomizerGenerator's header for the shape).
var _entries: Array = []

# Ids of entries that arrived from the registry WITHOUT a "parts" key, i.e. written
# before beats existed. Used as a set (value is always true). Filled by load_registry,
# drained by ensure_parts_migrated — the analysis itself must not run in _ready().
var _unanalysed_ids: Dictionary = {}


func _ready() -> void:
	_sweep_scratch_files()
	load_registry()


# ── Persistence ──────────────────────────────────────────────────────────────


func load_registry() -> void:
	_entries = []
	_unanalysed_ids = {}
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
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		# Entries written before parts existed carry a funscript but NO "parts" key at
		# all. The missing key — not an empty array — is what separates "never analysed"
		# from "analysed, nothing usable". Only the ID is remembered here: segmenting
		# every legacy script would run inside the autoload's _ready() and freeze the
		# whole app's start for minutes, even for someone who never opens the randomizer.
		# ensure_parts_migrated does the work, on demand, from the randomizer screen.
		if not d.has("parts") and str(d.get("funscript_src", "")) != "":
			_unanalysed_ids[str(d.get("id", ""))] = true
		_entries.append(_coerce_entry(d))


func save_registry() -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STORE_DIR))
	var f: FileAccess = FileAccess.open(REGISTRY_PATH, FileAccess.WRITE)
	if f == null:
		push_error("RandomizerLibrary: cannot write registry.")
		return false
	f.store_string(JSON.stringify({"version": 1, "entries": _entries}, "\t"))
	f.close()
	return true


# Segments the legacy entries load_registry flagged as never analysed (no "parts" key
# in the stored JSON). Deliberately NOT called from _ready(): reading and cutting a
# library's worth of funscripts is seconds to minutes of blocking I/O and only matters
# once the randomizer is actually opened. Effectively one-shot — the set is drained as
# it goes, so a second call is free.
#
# An entry whose funscript is unreachable right now (unmounted drive, moved folder) is
# SKIPPED WHOLE: no "parts" key, no save, and it stays in the set so the next call
# retries. Persisting an empty analysis there would lock the clip out of every future
# run. Only a file that was really read — even if it analysed to nothing — settles the
# "analysed" state.
func ensure_parts_migrated() -> void:
	if _unanalysed_ids.is_empty():
		return
	var dirty: bool = false
	for id: Variant in _unanalysed_ids.keys():
		var sid: String = str(id)
		var i: int = _index_of(sid)
		var src: String = str(_entries[i].get("funscript_src", "")) if i >= 0 else ""
		if src == "":
			# Entry removed, or its script detached since load — nothing left to migrate.
			_unanalysed_ids.erase(sid)
			continue
		if not FileAccess.file_exists(ProjectSettings.globalize_path(src)):
			continue
		_entries[i]["parts"] = _coerce_parts(_segment_parts(src))
		_unanalysed_ids.erase(sid)
		dirty = true
	if dirty:
		save_registry()


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
		# No main stroke funscript, but a vibration script IS present: a "vibrator only" clip. Its
		# stats/intensity/parts are read from the vibration track, not the (absent) stroke script.
		"vib_only": bool(e.get("vib_only", false)),
		"last_used": int(e.get("last_used", 0)),
		"added_at": int(e.get("added_at", 0)),
		# Beats from FunscriptSegmenter, computed once on import and persisted; the
		# expansion layer tiles them into the run's parts. Empty for a whole clip.
		"parts": _coerce_parts(e.get("parts", [])),
		# {part_id: unix} — the part-level counterpart of last_used. Both coexist:
		# a whole-clip entry decays on last_used, its parts decay individually.
		"part_used": _coerce_part_used(e.get("part_used", {})),
	}


# Normalizes a persisted beat list. JSON hands numbers back as float, so every field
# is re-coerced; a non-dictionary element or a window with out_ms <= in_ms is dropped
# rather than repaired — a beat that spans nothing can't be cut or played.
static func _coerce_parts(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for p: Variant in raw as Array:
		if not (p is Dictionary):
			continue
		var d: Dictionary = p
		var in_ms: int = int(d.get("in_ms", 0))
		var out_ms: int = int(d.get("out_ms", 0))
		if out_ms <= in_ms:
			continue
		var beat: Dictionary = {
			"in_ms": in_ms,
			"out_ms": out_ms,
			"speed": float(d.get("speed", 0.0)),
			"intensity": clampi(int(d.get("intensity", 3)), 1, 5),
			"action_count": int(d.get("action_count", 0)),
		}
		out.append(beat)
	return out


# Normalizes the {part_id: unix} map. Empty keys and non-positive / non-numeric
# stamps are dropped, so _freshness never sees a timestamp it can't subtract.
static func _coerce_part_used(raw: Variant) -> Dictionary:
	var out: Dictionary = {}
	if not (raw is Dictionary):
		return out
	for k: Variant in raw as Dictionary:
		var key: String = str(k)
		var v: Variant = (raw as Dictionary)[k]
		if key == "" or not (v is int or v is float):
			continue
		var ts: int = int(v)
		if ts > 0:
			out[key] = ts
	return out


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


# Marks the ids a generated run used, so cross-run freshness deprioritizes them next
# time. The list is MIXED: a whole-clip id bumps its entry's last_used as before, a
# part id instead stamps part_used[id] on the video it came from. A part deliberately
# does NOT bump the video's last_used — the whole point of part freshness is that a
# video may come round again immediately while the passage just played may not.
# Unknown ids are ignored.
func mark_used(ids: Array, now: int = 0) -> void:
	if now == 0:
		now = int(Time.get_unix_time_from_system())
	var touched: bool = false
	for id: Variant in ids:
		var sid: String = str(id)
		var pi: int = _index_of(_video_id_of(sid)) if _is_part_id(sid) else -1
		if pi >= 0:
			(_entries[pi]["part_used"] as Dictionary)[sid] = now
			touched = true
			continue
		var i: int = _index_of(sid)
		if i >= 0:
			_entries[i]["last_used"] = now
			touched = true
	if touched:
		save_registry()


# Part-id grammar: "<video_id>" + PART_ID_SEP + segments_identity. A video id is a
# 16-char hex fingerprint and never contains the separator, so the FIRST one splits
# the two halves; an id without one is already a video id.
#
# RandomizerParts spells these two lines out a second time (as public statics) on
# purpose: it keeps this autoload free of any compile dependency on the pure
# expansion class. Both spellings must stay bit-identical.
func _video_id_of(id: String) -> String:
	var sep: int = id.find(PART_ID_SEP)
	return id.substr(0, sep) if sep > 0 else id


func _is_part_id(id: String) -> bool:
	return id.find(PART_ID_SEP) > 0


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
		str(info["codec"]), str(info["pix_fmt"]), false, video_src.get_extension()
	)
	# When the probe couldn't run (no ffprobe), assume a re-encode is needed so the
	# predicted .mp4 rel is safe; prepare_entry_media re-checks ffmpeg availability.
	var needs_transcode: bool = reason != "" or not MediaPoolService.is_available()
	var duration_s: float = MediaPoolService.probe_duration_seconds(video_src)

	var vfp: String = JourneyData.media_fingerprint(video_src)
	var vext: String = "mp4" if needs_transcode else video_src.get_extension()
	var video_rel: String = JourneyData.pooled_media_rel(vfp, vext, video_src)

	# Vibrator-only: no main stroke funscript, but a vibration script is attached. Its stats,
	# intensity and beats come from the vibration track (rated by average level, segmented on level)
	# instead of the absent stroke script.
	var vib_only: bool = funscript_src == "" and not _first_vib_src(vib_srcs).is_empty()
	var script_for_analysis: String = _first_vib_src(vib_srcs) if vib_only else funscript_src

	var stats: Dictionary = _read_script_stats(script_for_analysis)
	# Auto-rate intensity from the script's motion (stroke speed) or vibration level; the passed
	# value is the fallback for a clip imported without any script at all.
	var rated: int = intensity
	if (
		script_for_analysis != ""
		and FileAccess.file_exists(ProjectSettings.globalize_path(script_for_analysis))
	):
		rated = (
			FunscriptIntensity.vib_from_path(script_for_analysis)
			if vib_only
			else FunscriptIntensity.from_path(script_for_analysis)
		)

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
			"vib_only": vib_only,
			"added_at": now,
			# Analysis happens exactly here, at import — the round-length slider is a
			# generate-time knob and never re-triggers it. A vibrator-only clip segments its
			# vibration track by LEVEL; everything else segments the stroke script by speed.
			"parts":
			(
				_segment_parts(script_for_analysis, FunscriptSegmenter.Metric.LEVEL)
				if vib_only
				else _segment_parts(funscript_src)
			),
		}
	)

	var existing: int = _index_of(vfp)
	if existing >= 0:
		# Preserve last_used across a re-add; take the new tags/weight/intensity.
		entry["last_used"] = int(_entries[existing].get("last_used", 0))
		# Same for part freshness: `parts` is recomputed from the script, but a beat
		# that came out identical keeps its history. No pruning of orphaned keys — a
		# dead one costs a few bytes and re-adding the same file usually reproduces it.
		entry["part_used"] = (_entries[existing].get("part_used", {}) as Dictionary).duplicate(true)
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
# Attaches a whole script BUNDLE to an existing clip: a main stroke funscript and/or axis + vibration
# channels, merged onto whatever the entry already has (each new channel fills/replaces its own slot).
# Re-rates and re-segments from the main script (stroke) or, when there's still no main, the vibration
# track — so a vibration-only clip that gains a main becomes a stroke clip. No-op on an unknown id or an
# empty bundle. (estim/e-stim scripts aren't carried — the randomizer library has no estim channel.)
func set_scripts(id: String, main_src: String, axis_srcs: Dictionary, vib_srcs: Dictionary) -> void:
	var i: int = _index_of(id)
	if i < 0:
		return
	var merged: Dictionary = _entries[i].duplicate(true)
	if main_src != "":
		merged["funscript_src"] = main_src
	var axis_all: Dictionary = (merged.get("axis_src", {}) as Dictionary).duplicate(true)
	axis_all.merge(axis_srcs, true)
	merged["axis_src"] = axis_all
	var vib_all: Dictionary = (merged.get("vib_src", {}) as Dictionary).duplicate(true)
	vib_all.merge(vib_srcs, true)
	merged["vib_src"] = vib_all
	_refresh_entry_scripts(i, merged)


# Sets ONE channel's source and rebuilds. `kind` is "main" / "axis" / "vib"; `channel` is the axis
# code or vib channel (ignored for main). No-op on an unknown id or a missing file. Lets a clip gain
# a vibration or axis script even when a stroke script is already attached.
func set_channel_script(id: String, kind: String, channel: String, path: String) -> void:
	var i: int = _index_of(id)
	if i < 0 or path == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
		return
	var merged: Dictionary = _entries[i].duplicate(true)
	match kind:
		"main":
			merged["funscript_src"] = path
		"axis":
			var a: Dictionary = (merged.get("axis_src", {}) as Dictionary).duplicate(true)
			a[channel] = path
			merged["axis_src"] = a
		"vib":
			var v: Dictionary = (merged.get("vib_src", {}) as Dictionary).duplicate(true)
			v[channel] = path
			merged["vib_src"] = v
		_:
			return
	_refresh_entry_scripts(i, merged)


# Removes ONE channel and rebuilds (a stroke clip whose main is cleared re-derives from its vibration
# track, if any). No-op on an unknown id.
func clear_channel_script(id: String, kind: String, channel: String) -> void:
	var i: int = _index_of(id)
	if i < 0:
		return
	var merged: Dictionary = _entries[i].duplicate(true)
	match kind:
		"main":
			merged["funscript_src"] = ""
		"axis":
			var a: Dictionary = (merged.get("axis_src", {}) as Dictionary).duplicate(true)
			a.erase(channel)
			merged["axis_src"] = a
		"vib":
			var v: Dictionary = (merged.get("vib_src", {}) as Dictionary).duplicate(true)
			v.erase(channel)
			merged["vib_src"] = v
		_:
			return
	_refresh_entry_scripts(i, merged)


# Recomputes every DERIVED field from `merged`'s current *_src channels — the pooled rels, the
# vibrator-only flag, and the stats/intensity/beats (from the main stroke script, or the vibration
# track when there is no main) — then coerces, persists, and signals. Shared by every script edit.
func _refresh_entry_scripts(i: int, merged: Dictionary) -> void:
	var main: String = str(merged.get("funscript_src", ""))
	var axis_all: Dictionary = merged.get("axis_src", {})
	var vib_all: Dictionary = merged.get("vib_src", {})
	var vib_only: bool = main == "" and not _first_vib_src(vib_all).is_empty()
	var script_for_analysis: String = _first_vib_src(vib_all) if vib_only else main

	merged["vib_only"] = vib_only
	merged["funscript_rel"] = _predict_script_rel(main)
	merged["axis_rel"] = _predict_channel_rels(axis_all)
	merged["vib_rel"] = _predict_channel_rels(vib_all)

	var stats: Dictionary = _read_script_stats(script_for_analysis)
	merged["action_count"] = int(stats["count"])
	merged["length_ms"] = int(stats["length_ms"])
	if (
		script_for_analysis != ""
		and FileAccess.file_exists(ProjectSettings.globalize_path(script_for_analysis))
	):
		merged["intensity"] = (
			FunscriptIntensity.vib_from_path(script_for_analysis)
			if vib_only
			else FunscriptIntensity.from_path(script_for_analysis)
		)
	merged["parts"] = (
		_segment_parts(script_for_analysis, FunscriptSegmenter.Metric.LEVEL)
		if vib_only
		else _segment_parts(main)
	)
	_entries[i] = _coerce_entry(merged)
	save_registry()
	library_changed.emit()


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
	# It now has a stroke script, so it is no longer vibrator-only — rate/segment as stroke.
	merged["vib_only"] = false
	# A new script means new beats; part_used survives via the duplicate() above.
	merged["parts"] = _segment_parts(funscript_src)
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
# transcode. `priority` selects the EncodeGate lane (default FOREGROUND); the only
# BACKGROUND caller is RandomizerPrebake, pooling the next run while a session plays.
# Returns { ok, reason }.
func prepare_entry_media(
	entry: Dictionary,
	on_progress: Callable = Callable(),
	should_cancel: Callable = Callable(),
	priority: int = EncodeGate.Priority.FOREGROUND
) -> Dictionary:
	var video_src: String = str(entry.get("video_src", ""))
	if video_src == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(video_src)):
		return {"ok": false, "reason": "video_missing"}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CONTENT_DIR))

	var vreason: String = await _pool_video(entry, video_src, on_progress, should_cancel, priority)
	if vreason != "":
		return {"ok": false, "reason": vreason}
	if not _pool_all_scripts(entry):
		return {"ok": false, "reason": "copy_failed"}
	return {"ok": true, "reason": ""}


# Ensures the entry's video is pooled (transcode or copy). Returns "" on success,
# else a failure reason. Idempotent (skips an already-pooled file). No default for
# `priority` — a forgotten argument here should be a parse error, not a silently
# dropped foreground encode.
func _pool_video(
	entry: Dictionary,
	video_src: String,
	on_progress: Callable,
	should_cancel: Callable,
	priority: int
) -> String:
	var video_dst: String = STORE_DIR + "/" + str(entry.get("video_rel", ""))
	if FileAccess.file_exists(video_dst):
		return ""
	var segments: Array = entry.get("segments", []) as Array
	if not segments.is_empty():
		# A part is a cut, and a cut always forces a re-encode — needs_transcode carries
		# no information here and is deliberately not consulted.
		if not MediaPoolService.is_available():
			return "ffmpeg_unavailable"
		var baked: bool = await MediaPoolService.bake_edl(
			video_src, video_dst, segments, on_progress, should_cancel, priority
		)
		if not baked:
			# bake_edl wipes only its own scratch dir; a killed concat can still leave a
			# truncated output behind, which would later pass the already-pooled check.
			_remove_if_exists(video_dst)
			return "bake_failed"
		return ""
	if bool(entry.get("needs_transcode", false)):
		if not MediaPoolService.is_available():
			return "ffmpeg_unavailable"
		var dur: float = float(entry.get("duration_ms", 0)) / 1000.0
		var ok: bool = await MediaPoolService.transcode_video(
			video_src, video_dst, dur, 0, 0, on_progress, should_cancel, priority
		)
		if not ok:
			# A killed/failed encode leaves a truncated file that would later look
			# already-pooled — delete it so a retry re-transcodes cleanly.
			_remove_if_exists(video_dst)
			return "transcode_failed"
		return ""
	if not await _copy_file_chunked(video_src, video_dst, should_cancel):
		_remove_if_exists(video_dst)
		return "copy_failed"
	return ""


# Pools the funscript + every axis/vib script: a verbatim copy for a whole clip, the
# actions cut to the window for a part. The destination rel is taken FROM THE ENTRY
# rather than recomputed, so the file can't land anywhere other than where the
# generator already points. False if any non-empty source fails to pool.
func _pool_all_scripts(entry: Dictionary) -> bool:
	var segments: Array = entry.get("segments", []) as Array
	if not _ensure_pooled(
		str(entry.get("funscript_src", "")), str(entry.get("funscript_rel", "")), segments
	):
		return false
	var axis_rel: Dictionary = entry.get("axis_rel", {}) as Dictionary
	if not _pool_channels(entry.get("axis_src", {}) as Dictionary, axis_rel, segments):
		return false
	var vib_rel: Dictionary = entry.get("vib_rel", {}) as Dictionary
	if not _pool_channels(entry.get("vib_src", {}) as Dictionary, vib_rel, segments):
		return false
	return true


# One axis/vib channel map: every source pooled under the rel predicted for its own
# channel key. A key missing from `rels` means the source was already gone at import.
func _pool_channels(srcs: Dictionary, rels: Dictionary, segments: Array) -> bool:
	for key: Variant in srcs:
		if not _ensure_pooled(str(srcs[key]), str(rels.get(key, "")), segments):
			return false
	return true


# True when a script source is empty (nothing to do) or pools successfully. An empty
# destination rel means the source was unreadable when the rel was predicted (import
# time) — but it may well be back now, so the rel is re-predicted instead of failing
# hard. Before parts existed this case pooled fine; a hard false would be a regression.
# Only a source that is STILL missing predicts "" again and fails.
func _ensure_pooled(src: String, dst_rel: String, segments: Array) -> bool:
	if src == "":
		return true
	var rel: String = dst_rel
	if rel == "":
		rel = _predict_script_rel(src, segments)
	if rel == "":
		return false
	return _pool_script(src, rel, segments)


# ── Helpers ──────────────────────────────────────────────────────────────────


# Materializes one funscript-family file at `dst_rel` in the pool. Without segments
# that's the byte copy it always was; with segments the actions are rewritten to the
# part's window. Idempotent — an already-pooled rel is left alone.
func _pool_script(src: String, dst_rel: String, segments: Array) -> bool:
	if not FileAccess.file_exists(ProjectSettings.globalize_path(src)):
		return false
	var dst: String = STORE_DIR + "/" + dst_rel
	if FileAccess.file_exists(dst):
		return true
	if segments.is_empty():
		return _copy_file(src, dst)
	var f: FileAccess = FileAccess.open(src, FileAccess.READ)
	if f == null:
		return false
	var parser := JSON.new()
	var ok: bool = parser.parse(f.get_as_text()) == OK and parser.data is Dictionary
	f.close()
	if not ok:
		_remove_if_exists(dst)
		return false
	# The one funscript rewriter — main script and axis/vib siblings alike, no per
	# channel special casing. source_len_ms 0 is enough: a part window is always
	# closed (out_ms > 0), and that parameter only resolves open ends.
	var cut: Dictionary = JourneyData.edl_funscript_json(parser.data as Dictionary, segments, 0)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst.get_base_dir()))
	# Write beside the target and rename into place: a kill mid-store_string would
	# otherwise leave half a JSON at `dst`, which the idempotency check above waves
	# through as pooled on the next run. The rename is the only publishing step.
	var tmp: String = dst + ".tmp"
	var df: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if df == null:
		_remove_if_exists(tmp)
		return false
	df.store_string(JSON.stringify(cut))
	df.close()
	var moved: int = DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(dst)
	)
	if moved != OK:
		_remove_if_exists(tmp)
		return false
	return true


# Reads a funscript and cuts it into beats. [] for an empty / missing / unparseable
# path. The JSON is parsed here rather than through JourneyData.read_funscript_actions
# because the segmenter hands its slices straight to FunscriptIntensity.average_speed,
# which wants {at, pos} dicts — the Vector2 form would be a second format truth.
# Segmentation parameters are deliberately not user-facing: the analysis hangs off the
# import alone, so the same clip always yields the same beats.
func _segment_parts(funscript_src: String, metric: int = FunscriptSegmenter.Metric.STROKE) -> Array:
	if (
		funscript_src == ""
		or not FileAccess.file_exists(ProjectSettings.globalize_path(funscript_src))
	):
		return []
	var f: FileAccess = FileAccess.open(funscript_src, FileAccess.READ)
	if f == null:
		return []
	var parser := JSON.new()
	var ok: bool = parser.parse(f.get_as_text()) == OK and parser.data is Dictionary
	f.close()
	if not ok:
		return []
	return FunscriptSegmenter.segment((parser.data as Dictionary).get("actions", []), {}, metric)


# The path of the first non-empty vibration source (channel order is arbitrary but stable within a
# run). "" when there is none — the signal that a clip is NOT vibrator-only.
func _first_vib_src(vib_srcs: Dictionary) -> String:
	for key: Variant in vib_srcs:
		var src: String = str(vib_srcs[key])
		if src != "":
			return src
	return ""


# Predicted pooled rel for a script source ("" for empty/missing) — deterministic
# from the fingerprint, computed WITHOUT copying (the copy is deferred to prepare).
# `segments` joins the fingerprint so a part gets its own pooled file; the default
# empty list reproduces the whole-clip identity byte for byte.
func _predict_script_rel(src: String, segments: Array = []) -> String:
	if src == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(src)):
		return ""
	return JourneyData.pooled_media_rel(
		JourneyData.media_fingerprint(src, segments), "funscript", src
	)


# {channel_key: source} → {channel_key: predicted_rel} (skips empty/missing sources).
func _predict_channel_rels(srcs: Dictionary, segments: Array = []) -> Dictionary:
	var out: Dictionary = {}
	for key: String in srcs:
		var rel: String = _predict_script_rel(str(srcs[key]), segments)
		if rel != "":
			out[key] = rel
	return out


# Reads funscript stats {count, length_ms} straight from a source path (no pooling).
func _read_script_stats(src: String) -> Dictionary:
	if src == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(src)):
		return {"count": 0, "length_ms": 0}
	return JourneyData.read_funscript_stats(src)


# Deletes a stale/partial pooled file. The result IS checked: this runs right after
# OS.kill ended a bake/transcode, and on Windows the child's handle can still be open
# for a moment — the delete then fails silently and the truncated mp4 counts as pooled
# on the next run. One short synchronous retry closes that window; the function isn't
# async, and 200 ms in the already-failed path is cheaper than a broken clip.
func _remove_if_exists(path: String) -> void:
	var abs: String = ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs):
		return
	if DirAccess.remove_absolute(abs) == OK:
		return
	OS.delay_msec(200)
	if DirAccess.remove_absolute(abs) != OK:
		push_warning("RandomizerLibrary: could not delete stale pooled file %s" % abs)


# Deletes orphaned encode/copy scratch from a previous session (app closed mid-bake). The
# process kill on shutdown ends the ffmpeg, but the coroutine waiting on it is never
# resumed, so its scratch file — `<name>.mp4.part.mp4`, possibly hundreds of megabytes —
# stays behind, once for every session that ended while a background bake was running. The
# rename-publish pattern (here and in MediaPoolService alike) guarantees these are never
# valid pool content, so anything still carrying the marker is dead weight. Runs once at
# start, before anything can be writing: CONTENT_DIR is flat (every pooled rel is exactly
# "content/<name>.<ext>"), so a single non-recursive pass covers it.
func _sweep_scratch_files() -> void:
	var da: DirAccess = DirAccess.open(CONTENT_DIR)
	if da == null:
		return
	da.list_dir_begin()
	var to_delete: PackedStringArray = []
	var fname: String = da.get_next()
	while fname != "":
		if not da.current_is_dir() and (fname.contains(".part.") or fname.ends_with(".tmp")):
			to_delete.append(CONTENT_DIR + "/" + fname)
		fname = da.get_next()
	da.list_dir_end()
	for p: String in to_delete:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


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


# The copy path for a POOLED VIDEO — the only file here big enough to matter (a whole clip
# without a funscript is routinely gigabytes). _copy_file reads the entire source into RAM
# and writes it back in one synchronous burst; on the BACKGROUND prebake path that is
# seconds of frozen gameplay plus a RAM spike the size of the source file. This one moves
# COPY_CHUNK_BYTES at a time and hands a frame back between blocks, so the running session
# keeps drawing, and it honours should_cancel at the same granularity.
#
# Writes beside the target and renames into place, exactly like _pool_script: the rename is
# the only publishing step, so an app exit mid-copy can never leave a truncated file at the
# final name, which the already-pooled check would wave through on the next run.
func _copy_file_chunked(src: String, dst: String, should_cancel: Callable) -> bool:
	var sf: FileAccess = FileAccess.open(src, FileAccess.READ)
	if sf == null:
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst.get_base_dir()))
	var tmp: String = dst + ".tmp"
	var df: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if df == null:
		sf.close()
		return false
	var total: int = sf.get_length()
	var done: int = 0
	var cancelled: bool = false
	while done < total:
		var chunk: PackedByteArray = sf.get_buffer(mini(COPY_CHUNK_BYTES, total - done))
		if chunk.is_empty():
			break  # short read: the source shrank or went away mid-copy
		df.store_buffer(chunk)
		done += chunk.size()
		if done >= total:
			break  # last block written — no point yielding another frame first
		await get_tree().process_frame
		if should_cancel.is_valid() and should_cancel.call():
			cancelled = true
			break
	sf.close()
	df.close()
	if cancelled or done < total:
		_remove_if_exists(tmp)
		return false
	var moved: int = DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(dst)
	)
	if moved != OK:
		_remove_if_exists(tmp)
		return false
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
