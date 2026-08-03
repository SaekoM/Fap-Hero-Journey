class_name JourneyPackager
extends RefCounted

## I/O driver for .fhj packages: writes a journey folder out to a single file, and reads / installs one
## back. The pure decisions (manifest shape, routing, hashing) live in JourneyPackage; this file only
## moves bytes.
##
## CONTAINER — a custom format, NOT a zip. Journeys routinely carry multi-GB video, and a standard zip
## caps at 4 GB (no ZIP64 in Godot's ZIPPacker), while ZIPReader loads whole entries into RAM. So the
## .fhj is: [header] then each file's raw bytes concatenated, then a JSON index (manifest + a
## {name, offset, size} table) in a trailer — like a zip's central directory, but with 64-bit offsets.
## All reads/writes are chunked, so memory stays flat regardless of file size. Async (yields on the
## main-loop frame between chunks) so a big export/import never freezes the app.
##
## Layout:  [MAGIC(8)][format(u32)] [file bytes …] [index JSON] [index_offset(u64)][index_len(u64)][MAGIC(8)]

const CHUNK: int = 8 * 1024 * 1024  # bytes moved per read/write call
const YIELD_BYTES: int = 32 * 1024 * 1024  # yield to the frame roughly this often
const MAGIC: String = "FHJPACK1"  # 8 ASCII bytes, written at head and tail
const CONTAINER_FORMAT: int = 1
const TRAILER_SIZE: int = 24  # index_offset(8) + index_len(8) + MAGIC(8)

const COVER_EXTS: Array[String] = ["png", "jpg", "jpeg", "webp"]

# ── Export ─────────────────────────────────────────────────────────────────


# Packs `journey_folder` (a user:// journey dir) into a single .fhj at `out_abs`. Writes journey.json
# from the parsed dict (so a minted JourneyId lands in it) plus every file under content/ and media/.
# Nothing is re-encoded. Returns {ok, error}.
static func export_journey(
	journey_folder: String,
	out_abs: String,
	mode: String = "embedded",
	on_progress: Callable = Callable(),
	should_cancel: Callable = Callable()
) -> Dictionary:
	var folder_abs: String = ProjectSettings.globalize_path(journey_folder)
	var journey_json_abs: String = folder_abs.path_join("journey.json")
	if not FileAccess.file_exists(journey_json_abs):
		return _err("This journey has no journey.json to export.")
	var journey_data: Dictionary = _read_json(journey_json_abs)
	if journey_data.is_empty():
		return _err("journey.json is empty or malformed.")

	# A package must be self-identifying: a journey with no JourneyId can't be de-duplicated on re-import
	# or anchored by a rendition. Mint one INTO the package (source folder left untouched — it earns its
	# own id on its next builder save).
	if str(journey_data.get("JourneyId", "")).strip_edges() == "":
		journey_data["JourneyId"] = JourneyData.new_journey_id()

	var cover_rel: String = _find_cover_rel(folder_abs)
	var assets: Array = JourneyPackage.enumerate_assets(journey_data, cover_rel)
	var manifest: Dictionary = JourneyPackage.build_manifest(
		journey_data, assets, cover_rel, mode, "full"
	)

	var entries: Array = []
	_collect_dir(folder_abs, "content", entries)
	_collect_dir(folder_abs, "media", entries)
	return await _write_pack(out_abs, manifest, journey_data, entries, on_progress, should_cancel)


# ── Split export (free video pack + paid scripts pack) ───────────────────────


# Exports a journey as TWO packages: "<base> (scripts).fhj" (journey.json + the paid assets, video slots
# left empty) and "<base> (video).fhj" (the free scene video + cover, no journey.json). `role_overrides`
# (role → "free"/"paid") moves whole asset groups between the halves; scene footage and the cover are
# always free regardless. Returns {ok, error, scripts, video}.
static func export_split(
	journey_folder: String,
	base_out_abs: String,
	role_overrides: Dictionary = {},
	on_progress: Callable = Callable(),
	should_cancel: Callable = Callable()
) -> Dictionary:
	var folder_abs: String = ProjectSettings.globalize_path(journey_folder)
	var journey_json_abs: String = folder_abs.path_join("journey.json")
	if not FileAccess.file_exists(journey_json_abs):
		return _err("This journey has no journey.json to export.")
	var journey_data: Dictionary = _read_json(journey_json_abs)
	if journey_data.is_empty():
		return _err("journey.json is empty or malformed.")
	if str(journey_data.get("JourneyId", "")).strip_edges() == "":
		journey_data["JourneyId"] = JourneyData.new_journey_id()

	var cover_rel: String = _find_cover_rel(folder_abs)
	var assets: Array = JourneyPackage.enumerate_assets(journey_data, cover_rel)

	# Role toggles → per-asset overrides (apply_overrides still refuses to paywall a scene).
	var overrides: Dictionary = {}
	for asset: Dictionary in assets:
		var role: String = str(asset["role"])
		if role_overrides.has(role):
			overrides[str(asset["rel"])] = str(role_overrides[role])
	JourneyPackage.apply_overrides(assets, overrides)
	if not JourneyPackage.paid_pack_is_clean(assets):
		return _err("Internal error: scene video was routed into the paid pack.")

	# Index the pooled files on disk so each pack can pull its own by rel.
	var disk: Dictionary = {}
	var disk_list: Array = []
	_collect_dir(folder_abs, "content", disk_list)
	_collect_dir(folder_abs, "media", disk_list)
	for e: Dictionary in disk_list:
		disk[str(e["rel"])] = e

	var paid_assets: Array = assets.filter(func(a: Dictionary) -> bool: return a["pack"] == "paid")
	var free_assets: Array = assets.filter(func(a: Dictionary) -> bool: return a["pack"] == "free")

	var base: String = base_out_abs
	if base.to_lower().ends_with(".fhj"):
		base = base.substr(0, base.length() - 4)
	var scripts_out: String = base + " (scripts).fhj"
	var video_out: String = base + " (video).fhj"

	var scripts_manifest: Dictionary = JourneyPackage.build_manifest(
		journey_data, paid_assets, "", "lean", "scripts"
	)
	var scripts_progress: Callable = func(f: float) -> void:
		if on_progress.is_valid():
			on_progress.call(f * 0.5)  # scripts pack drives the first half of the bar
	var r1: Dictionary = await _write_pack(
		scripts_out,
		scripts_manifest,
		journey_data,
		_entries_for(paid_assets, disk),
		scripts_progress,
		should_cancel
	)
	if not bool(r1["ok"]):
		return r1

	var video_manifest: Dictionary = JourneyPackage.build_manifest(
		journey_data, free_assets, cover_rel, "embedded", "video"
	)
	var video_progress: Callable = func(f: float) -> void:
		if on_progress.is_valid():
			on_progress.call(0.5 + f * 0.5)  # video pack drives the second half
	var r2: Dictionary = await _write_pack(
		video_out,
		video_manifest,
		{},
		_entries_for(free_assets, disk),
		video_progress,
		should_cancel
	)
	if not bool(r2["ok"]):
		return r2
	return {"ok": true, "error": "", "scripts": scripts_out, "video": video_out}


# ── Import ─────────────────────────────────────────────────────────────────


# Reads just the manifest (from the trailer index) without extracting anything, for the preview +
# dedupe. Returns JourneyPackage.parse_manifest's result, or an ok:false container-level error.
static func read_manifest(fhj_abs: String) -> Dictionary:
	var idx: Dictionary = _read_index(fhj_abs)
	if not bool(idx["ok"]):
		return idx
	var manifest: Variant = idx["manifest"]
	if not (manifest is Dictionary) or (manifest as Dictionary).is_empty():
		return _err("This file isn't an FHJ package (no manifest).")
	return JourneyPackage.parse_manifest(manifest)


# The rel paths a pack carries ("content/…", "media/…", "journey.json") — used to find which installed
# journey is missing a video pack's files, so recombination can target it even when a re-imported copy
# carries a different JourneyId.
static func pack_file_names(fhj_abs: String) -> Array:
	var idx: Dictionary = _read_index(fhj_abs)
	if not bool(idx["ok"]):
		return []
	var names: Array = []
	for fe: Variant in idx["files"]:
		if fe is Dictionary:
			names.append(str((fe as Dictionary)["name"]))
	return names


# Extracts an .fhj into a hidden staging folder, then atomically swaps it into journeys_dir/<folder_name>
# (mirrors the builder's stage-then-swap so a mid-extract failure never corrupts an existing journey).
# `new_id`, when set, restamps the installed journey.json's JourneyId (import-as-copy). Returns
# {ok, error, folder}.
static func install(
	fhj_abs: String,
	folder_name: String,
	new_id: String = "",
	on_progress: Callable = Callable(),
	should_cancel: Callable = Callable(),
	lock: bool = false
) -> Dictionary:
	var idx: Dictionary = _read_index(fhj_abs)
	if not bool(idx["ok"]):
		return idx

	var journeys_root: String = SettingsService.get_journeys_dir()
	# Dot-prefixed so JourneyScanner skips a leftover staging folder if the app dies mid-extract.
	var staging: String = journeys_root + "/.~import_" + folder_name
	var staging_abs: String = ProjectSettings.globalize_path(staging)
	if DirAccess.dir_exists_absolute(staging_abs):
		JourneyData.delete_dir_recursive(staging_abs)
	DirAccess.make_dir_recursive_absolute(staging_abs)

	var r: Dictionary = await _extract_files(
		fhj_abs, idx["files"], staging_abs, on_progress, should_cancel
	)
	if not bool(r["ok"]):
		JourneyData.delete_dir_recursive(staging_abs)
		return r

	# Finalize the staged journey.json before it goes live: import-as-copy restamps the JourneyId; a paid
	# pack gets the soft edit-lock stamped in. One read/write for both.
	_finalize_journey_json(staging_abs.path_join("journey.json"), new_id, lock)

	# Atomic-ish swap: clear the destination (overwrite / same folder) then rename staging into place.
	var final_abs: String = ProjectSettings.globalize_path(journeys_root + "/" + folder_name)
	if DirAccess.dir_exists_absolute(final_abs):
		JourneyData.delete_dir_recursive(final_abs)
	DirAccess.rename_absolute(staging_abs, final_abs)
	return {"ok": true, "error": "", "folder": journeys_root + "/" + folder_name}


# Merges a VIDEO pack's files directly into an already-installed journey folder — the recombination
# step: the scripts pack installed the journey with empty video slots, this drops the free video +
# cover into the same content/ + media/ (matched by their shared pooled rel paths). Additive; it never
# touches journey.json (a video pack has none). Returns {ok, error}.
static func merge_media(
	fhj_abs: String,
	target_folder: String,
	on_progress: Callable = Callable(),
	should_cancel: Callable = Callable()
) -> Dictionary:
	var idx: Dictionary = _read_index(fhj_abs)
	if not bool(idx["ok"]):
		return idx
	var target_abs: String = ProjectSettings.globalize_path(target_folder)
	if not DirAccess.dir_exists_absolute(target_abs):
		return _err("The target journey folder is missing.")
	return await _extract_files(fhj_abs, idx["files"], target_abs, on_progress, should_cancel)


# Streams each indexed file out of the pack into dest_abs/<name> (chunked, low memory). Shared by
# install (into a staging folder) and merge_media (into a live journey folder).
static func _extract_files(
	fhj_abs: String, files: Array, dest_abs: String, on_progress: Callable, should_cancel: Callable
) -> Dictionary:
	var pack: FileAccess = FileAccess.open(fhj_abs, FileAccess.READ)
	if pack == null:
		return _err("Could not open the package.")

	var total: int = 0
	for fe: Dictionary in files:
		total += int(fe["size"])
	total = maxi(1, total)

	var done: int = 0
	var since_yield: int = 0
	for fe: Dictionary in files:
		if should_cancel.is_valid() and should_cancel.call():
			pack.close()
			return _err("cancelled")
		var name: String = str(fe["name"])
		if name.begins_with("/") or name.contains(".."):
			continue  # path-traversal guard — a package entry can only land inside the target folder
		var dst_abs: String = dest_abs.path_join(name)
		DirAccess.make_dir_recursive_absolute(dst_abs.get_base_dir())
		var out: FileAccess = FileAccess.open(dst_abs, FileAccess.WRITE)
		if out == null:
			pack.close()
			return _err("Could not write %s (drive full or write-protected?)." % name)
		pack.seek(int(fe["offset"]))
		var remaining: int = int(fe["size"])
		while remaining > 0:
			var n: int = mini(CHUNK, remaining)
			out.store_buffer(pack.get_buffer(n))
			remaining -= n
			done += n
			since_yield += n
			if on_progress.is_valid():
				on_progress.call(float(done) / float(total))
			if since_yield >= YIELD_BYTES:
				since_yield = 0
				await (Engine.get_main_loop() as SceneTree).process_frame
		out.close()
	pack.close()
	if on_progress.is_valid():
		on_progress.call(1.0)
	return {"ok": true, "error": ""}


# Post-install touch-ups to an on-disk journey.json: `new_id` restamps the JourneyId (import-as-copy);
# `lock` stamps the soft edit-lock (paid-pack import). Reads/writes once; a no-op when neither applies.
static func _finalize_journey_json(journey_json_abs: String, new_id: String, lock: bool) -> void:
	if new_id == "" and not lock:
		return
	var data: Dictionary = _read_json(journey_json_abs)
	if data.is_empty():
		return
	if new_id != "":
		data["JourneyId"] = new_id
	if lock:
		data["Locked"] = true
	var f: FileAccess = FileAccess.open(journey_json_abs, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()


# ── Container I/O ────────────────────────────────────────────────────────────


# Writes one .fhj: header, journey.json (from `journey_data`; skipped when empty — the video pack),
# each entry's raw bytes (chunked), then the JSON index + trailer. `on_progress` reports 0–1 of this
# file. Shared by the self-contained and split exports.
static func _write_pack(
	out_abs: String,
	manifest: Dictionary,
	journey_data: Dictionary,
	entries: Array,
	on_progress: Callable,
	should_cancel: Callable
) -> Dictionary:
	var journey_bytes: PackedByteArray = PackedByteArray()
	if not journey_data.is_empty():
		journey_bytes = JSON.stringify(journey_data, "\t").to_utf8_buffer()

	var total: int = journey_bytes.size()
	for e: Dictionary in entries:
		total += int(e["size"])
	total = maxi(1, total)

	var pack: FileAccess = FileAccess.open(out_abs, FileAccess.WRITE)
	if pack == null:
		return _err("Could not create %s (drive full or write-protected?)." % out_abs.get_file())

	pack.store_buffer(MAGIC.to_utf8_buffer())  # head magic (identification; trailer magic is authoritative)
	pack.store_32(CONTAINER_FORMAT)

	var files: Array = []  # [{name, offset, size}]
	var done: int = 0
	var since_yield: int = 0

	if not journey_bytes.is_empty():
		var joff: int = pack.get_position()
		pack.store_buffer(journey_bytes)
		files.append({"name": "journey.json", "offset": joff, "size": journey_bytes.size()})
		done += journey_bytes.size()
		if on_progress.is_valid():
			on_progress.call(float(done) / float(total))

	for e: Dictionary in entries:
		if should_cancel.is_valid() and should_cancel.call():
			pack.close()
			DirAccess.remove_absolute(out_abs)
			return _err("cancelled")
		var src: FileAccess = FileAccess.open(str(e["abs"]), FileAccess.READ)
		if src == null:
			continue  # a file that vanished mid-export is skipped, not fatal
		var off: int = pack.get_position()
		var remaining: int = int(e["size"])
		while remaining > 0:
			var n: int = mini(CHUNK, remaining)
			pack.store_buffer(src.get_buffer(n))
			remaining -= n
			done += n
			since_yield += n
			if on_progress.is_valid():
				on_progress.call(float(done) / float(total))
			if since_yield >= YIELD_BYTES:
				since_yield = 0
				await (Engine.get_main_loop() as SceneTree).process_frame
		src.close()
		files.append({"name": str(e["rel"]), "offset": off, "size": int(e["size"])})

	# Trailer: the index (manifest + file table) at a recorded offset, then offset/len/magic so a reader
	# can find it from the end without scanning.
	var index_bytes: PackedByteArray = (
		JSON.stringify({"manifest": manifest, "files": files}).to_utf8_buffer()
	)
	var index_offset: int = pack.get_position()
	pack.store_buffer(index_bytes)
	pack.store_64(index_offset)
	pack.store_64(index_bytes.size())
	pack.store_buffer(MAGIC.to_utf8_buffer())
	pack.close()
	if on_progress.is_valid():
		on_progress.call(1.0)
	return {"ok": true, "error": ""}


# Reads the trailer index of an .fhj. Returns {ok, manifest, files} or {ok:false, error}.
static func _read_index(fhj_abs: String) -> Dictionary:
	var f: FileAccess = FileAccess.open(fhj_abs, FileAccess.READ)
	if f == null:
		return _err("Could not open the package (is it a valid .fhj file?).")
	var size: int = f.get_length()
	if size < TRAILER_SIZE:
		f.close()
		return _err("This file isn't an FHJ package.")
	f.seek(size - TRAILER_SIZE)
	var index_offset: int = f.get_64()
	var index_len: int = f.get_64()
	var magic: PackedByteArray = f.get_buffer(8)
	if magic != MAGIC.to_utf8_buffer():
		f.close()
		return _err("This file isn't an FHJ package.")
	if index_offset < 0 or index_len < 0 or index_offset + index_len > size - TRAILER_SIZE:
		f.close()
		return _err("The package index is out of range (file corrupt or truncated).")
	f.seek(index_offset)
	var index_bytes: PackedByteArray = f.get_buffer(index_len)
	f.close()
	var parser: JSON = JSON.new()
	if parser.parse(index_bytes.get_string_from_utf8()) != OK or not (parser.data is Dictionary):
		return _err("The package index is corrupt.")
	var index: Dictionary = parser.data
	return {"ok": true, "manifest": index.get("manifest", {}), "files": index.get("files", [])}


# ── Helpers ────────────────────────────────────────────────────────────────


# The disk entries ({rel, abs, size}) for a set of assets, skipping any whose file isn't on disk.
static func _entries_for(assets: Array, disk: Dictionary) -> Array:
	var out: Array = []
	for a: Dictionary in assets:
		var rel: String = str(a["rel"])
		if disk.has(rel):
			out.append(disk[rel])
	return out


# The journey's cover rel ("media/cover.<ext>") or "" — cover isn't stored in journey.json, it's the
# file JourneyScanner.find_cover_image globs for, so packaging finds it the same way.
static func _find_cover_rel(folder_abs: String) -> String:
	var media_abs: String = folder_abs.path_join("media")
	for ext: String in COVER_EXTS:
		if FileAccess.file_exists(media_abs.path_join("cover." + ext)):
			return "media/cover." + ext
	return ""


# Appends {rel, abs, size} for every file directly under folder_abs/<sub>. No-op if the dir is absent
# (a storyboard-only journey may have no content/, etc.).
static func _collect_dir(folder_abs: String, sub: String, entries: Array) -> void:
	var dir_abs: String = folder_abs.path_join(sub)
	var d: DirAccess = DirAccess.open(dir_abs)
	if d == null:
		return
	d.list_dir_begin()
	var name: String = d.get_next()
	while name != "":
		if not d.current_is_dir():
			var abs: String = dir_abs.path_join(name)
			entries.append({"rel": sub + "/" + name, "abs": abs, "size": _file_size(abs)})
		name = d.get_next()
	d.list_dir_end()


static func _file_size(abs: String) -> int:
	var f: FileAccess = FileAccess.open(abs, FileAccess.READ)
	if f == null:
		return 0
	var s: int = f.get_length()
	f.close()
	return s


static func _read_json(abs: String) -> Dictionary:
	var f: FileAccess = FileAccess.open(abs, FileAccess.READ)
	if f == null:
		return {}
	var parser: JSON = JSON.new()
	var err: int = parser.parse(f.get_as_text())
	f.close()
	if err != OK or not (parser.data is Dictionary):
		return {}
	return parser.data


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}
