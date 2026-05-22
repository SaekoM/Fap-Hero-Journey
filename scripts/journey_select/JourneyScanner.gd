class_name JourneyScanner
extends RefCounted

# ---------------------------------------------------------------------------
# JourneyScanner
# Scans user://journeys/ and parses each journey.json into the catalogue model
# consumed by JourneySelect (and, in turn, GameState). Pure data — no UI, no
# node state. Mirrors the JourneyData split: JourneyData owns the builder-side
# model, JourneyScanner owns the catalogue-side scan + parse.
#
# Per-journey model returned:
#   { folder, folder_name, title, description, difficulty, author,
#     rounds[], forks[], shops[], storyboards[],
#     cover_path, total_actions, total_length_ms, modified_time }
#
# Entry point: JourneyScanner.scan_all(journeys_dir) -> Array[Dictionary]
# ---------------------------------------------------------------------------

const IMAGE_EXTS: Array[String] = ["png", "jpg", "jpeg", "webp"]
const EXTRA_AXIS_SUFFIXES: Array[String] = ["_L1", "_L2", "_R0", "_R1", "_R2"]


# Scans `journeys_dir` for sub-folders containing a journey.json and returns the
# parsed catalogue model for each. Creates the directory if it doesn't exist.
static func scan_all(journeys_dir: String) -> Array:
	var result: Array = []
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(journeys_dir)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(journeys_dir))
		return result
	var dir: DirAccess = DirAccess.open(journeys_dir)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			var journey: Dictionary = parse_journey(journeys_dir + "/" + entry, entry)
			if not journey.is_empty():
				result.append(journey)
		entry = dir.get_next()
	dir.list_dir_end()
	return result


# Parses one journey folder's journey.json into the catalogue model.
# Returns {} if the file is missing or malformed.
static func parse_journey(path: String, folder: String) -> Dictionary:
	var json_path: String = path + "/journey.json"
	if not FileAccess.file_exists(json_path):
		return {}
	var file: FileAccess = FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		return {}
	var parser: JSON = JSON.new()
	var err: int = parser.parse(file.get_as_text())
	file.close()
	if err != OK:
		return {}
	var data: Dictionary = parser.data

	var journey: Dictionary = {
		"folder":          path,
		"folder_name":     folder,
		"title":           data.get("Name", folder),
		"description":     data.get("Description", ""),
		"difficulty":      data.get("Difficulty", "Unknown"),
		"author":          data.get("Author", "Unknown"),
		"rounds":          [],
		"forks":           [],
		"shops":           [],
		"storyboards":     [],
		"cover_path":      "",
		"tags":            TagRegistry.sanitize(data.get("Tags", [])),
		"total_actions":   0,
		"total_length_ms": 0,
		"modified_time":   FileAccess.get_modified_time(json_path),
	}

	var raw_shops: Array = data.get("Shops", [])
	for raw_shop in raw_shops:
		if raw_shop is Dictionary:
			journey["shops"].append({
				"after_order": raw_shop.get("AfterOrder", raw_shop.get("after_order", 0)),
				"title":       raw_shop.get("Title",       raw_shop.get("title",       "")),
			})
		else:
			# Legacy format: bare int order number.
			journey["shops"].append({"after_order": int(raw_shop), "title": ""})

	var raw_storyboards: Array = data.get("Storyboards", [])
	for raw_sb in raw_storyboards:
		if not raw_sb is Dictionary:
			continue
		var sb_img_file: String = raw_sb.get("Image", raw_sb.get("image", ""))
		var sb_lines_raw: Array = raw_sb.get("Lines", raw_sb.get("lines", []))
		var sb_lines: Array = []
		for raw_line in sb_lines_raw:
			if not raw_line is Dictionary:
				continue
			var line_img_file: String = raw_line.get("Image", raw_line.get("image", ""))
			sb_lines.append({
				"speaker": raw_line.get("Speaker", raw_line.get("speaker", "")),
				"text":    raw_line.get("Text",    raw_line.get("text",    "")),
				"image":   (path + "/" + line_img_file) if line_img_file != "" else "",
			})
		journey["storyboards"].append({
			"order":  raw_sb.get("Order",        raw_sb.get("order",        0)),
			"coins":  raw_sb.get("CoinsAwarded", raw_sb.get("coins",        0)),
			"image":  (path + "/" + sb_img_file) if sb_img_file != "" else "",
			"lines":  sb_lines,
		})

	journey["cover_path"] = find_cover_image(path)

	var raw_rounds: Array = data.get("Rounds", [])
	# Filter out any legacy Shop-type rounds — shops are now declared via "Shops": [...]
	raw_rounds = raw_rounds.filter(func(r: Dictionary) -> bool:
		return r.get("RoundType", "Normal") != "Shop"
	)
	raw_rounds.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a.get("Order", 0) as int) < (b.get("Order", 0) as int)
	)

	for raw: Dictionary in raw_rounds:
		var round_name: String   = raw.get("Name", "Round")
		var round_folder: String = path + "/" + round_name

		var fs: Dictionary = _resolve_round_stats(raw, path, round_folder)

		# Axis scripts — {axis: relative_path} in JSON, resolved to absolute paths.
		var raw_axis: Dictionary = raw.get("AxisScripts", raw.get("axis_scripts", {}))
		var axis_scripts: Dictionary = {}
		for axis: String in raw_axis:
			var rel: String = raw_axis[axis]
			if rel != "":
				axis_scripts[axis] = path + "/" + rel

		# Vib scripts — {ch_key: relative_path} in JSON, resolved to absolute paths.
		var raw_vib: Dictionary = raw.get("VibScripts", raw.get("vib_scripts", {}))
		var vib_scripts: Dictionary = {}
		for ch_key: String in raw_vib:
			var rel: String = raw_vib[ch_key]
			if rel != "":
				vib_scripts[ch_key] = path + "/" + rel

		# Boss-round config — RoundType plus optional intro image / tagline /
		# forced modifiers. Absent fields fall back to a plain ("normal") round.
		var round_type: String = (raw.get("RoundType", "Normal") as String).to_lower()
		var boss_image: String = raw.get("BossImage", "")
		if boss_image != "":
			boss_image = path + "/" + boss_image
		var boss_modifiers: Array = []
		for raw_mod in raw.get("BossModifiers", []):
			if raw_mod is Dictionary:
				boss_modifiers.append(_parse_boss_modifier(raw_mod))

		var round_data: Dictionary = {
			"name":           round_name,
			"folder":         round_folder,
			"funscript_path": fs["path"],
			"axis_scripts":   axis_scripts,
			"vib_scripts":    vib_scripts,
			"round_type":     round_type,
			"boss_image":     boss_image,
			"boss_tagline":   raw.get("BossTagline", ""),
			"boss_modifiers": boss_modifiers,
			"coins":          raw.get("CoinsAwarded", 0),
			"order":          raw.get("Order", 0),
			"action_count":   fs["count"],
			"length_ms":      fs["length_ms"],
		}
		journey["total_actions"]   = (journey["total_actions"] as int) + (fs["count"] as int)
		journey["total_length_ms"] = (journey["total_length_ms"] as int) + (fs["length_ms"] as int)
		journey["rounds"].append(round_data)

	var raw_forks: Array = data.get("Forks", [])
	var parsed_forks: Array = []
	for raw_fork: Dictionary in raw_forks:
		parsed_forks.append(parse_fork(raw_fork, path))
	journey["forks"] = parsed_forks

	return journey


# Recursively parses a fork's JSON dict. Each path can contain nested forks
# in its "Forks" array.
static func parse_fork(raw_fork: Dictionary, journey_path: String) -> Dictionary:
	var fork_entry: Dictionary = {
		"after_order": raw_fork.get("AfterOrder", raw_fork.get("after_order", 0)),
		"title":       raw_fork.get("Title",       raw_fork.get("title",       "")),
		"description": raw_fork.get("Description", raw_fork.get("description", "")),
		"paths":       [],
	}
	var raw_paths: Array = raw_fork.get("Paths", raw_fork.get("paths", []))
	for raw_path: Dictionary in raw_paths:
		var img_file: String = raw_path.get("Image", raw_path.get("image", ""))
		var path_entry: Dictionary = {
			"name":        raw_path.get("Name",        raw_path.get("name",        "Path")),
			"description": raw_path.get("Description", raw_path.get("description", "")),
			"image_path":  (journey_path + "/" + img_file) if img_file != "" else "",
			"rounds":      [],
			"shops":       [],
			"storyboards": [],
			"forks":       [],
		}
		var raw_pr_rounds: Array = raw_path.get("Rounds", raw_path.get("rounds", []))
		for raw_pr: Dictionary in raw_pr_rounds:
			var pr_name: String   = raw_pr.get("Name", raw_pr.get("name", "Round"))
			var pr_folder: String = journey_path + "/" + pr_name

			var pr_fs: Dictionary = _resolve_round_stats(raw_pr, journey_path, pr_folder)

			var pr_raw_axis: Dictionary = raw_pr.get("AxisScripts", raw_pr.get("axis_scripts", {}))
			var pr_axis_scripts: Dictionary = {}
			for axis: String in pr_raw_axis:
				var rel: String = pr_raw_axis[axis]
				if rel != "":
					pr_axis_scripts[axis] = journey_path + "/" + rel

			var pr_raw_vib: Dictionary = raw_pr.get("VibScripts", raw_pr.get("vib_scripts", {}))
			var pr_vib_scripts: Dictionary = {}
			for ch_key: String in pr_raw_vib:
				var rel: String = pr_raw_vib[ch_key]
				if rel != "":
					pr_vib_scripts[ch_key] = journey_path + "/" + rel

			var pr_round_type: String = (raw_pr.get("RoundType", "Normal") as String).to_lower()
			var pr_boss_image: String = raw_pr.get("BossImage", "")
			if pr_boss_image != "":
				pr_boss_image = journey_path + "/" + pr_boss_image
			var pr_boss_modifiers: Array = []
			for raw_mod in raw_pr.get("BossModifiers", []):
				if raw_mod is Dictionary:
					pr_boss_modifiers.append(_parse_boss_modifier(raw_mod))

			path_entry["rounds"].append({
				"name":           pr_name,
				"folder":         pr_folder,
				"funscript_path": pr_fs["path"],
				"axis_scripts":   pr_axis_scripts,
				"vib_scripts":    pr_vib_scripts,
				"round_type":     pr_round_type,
				"boss_image":     pr_boss_image,
				"boss_tagline":   raw_pr.get("BossTagline", ""),
				"boss_modifiers": pr_boss_modifiers,
				"coins":          raw_pr.get("CoinsAwarded", raw_pr.get("coins", 0)),
				"order":          raw_pr.get("Order",        raw_pr.get("order", 0)),
				"action_count":   pr_fs["count"],
				"length_ms":      pr_fs["length_ms"],
			})
		var raw_pr_shops: Array = raw_path.get("Shops", raw_path.get("shops", []))
		for raw_ps in raw_pr_shops:
			if raw_ps is Dictionary:
				path_entry["shops"].append({
					"after_order": raw_ps.get("AfterOrder", raw_ps.get("after_order", 0)),
					"title":       raw_ps.get("Title",      raw_ps.get("title",       "")),
				})
			else:
				path_entry["shops"].append({"after_order": int(raw_ps), "title": ""})
		var raw_pr_sbs: Array = raw_path.get("Storyboards", raw_path.get("storyboards", []))
		for raw_psb in raw_pr_sbs:
			if not raw_psb is Dictionary:
				continue
			var psb_img_file: String = raw_psb.get("Image", raw_psb.get("image", ""))
			var psb_lines_raw: Array = raw_psb.get("Lines", raw_psb.get("lines", []))
			var psb_lines: Array = []
			for raw_pl in psb_lines_raw:
				if not raw_pl is Dictionary:
					continue
				var pl_img_file: String = raw_pl.get("Image", raw_pl.get("image", ""))
				psb_lines.append({
					"speaker": raw_pl.get("Speaker", raw_pl.get("speaker", "")),
					"text":    raw_pl.get("Text",    raw_pl.get("text",    "")),
					"image":   (journey_path + "/" + pl_img_file) if pl_img_file != "" else "",
				})
			path_entry["storyboards"].append({
				"order":  raw_psb.get("Order",        raw_psb.get("order",        0)),
				"coins":  raw_psb.get("CoinsAwarded", raw_psb.get("coins",        0)),
				"image":  (journey_path + "/" + psb_img_file) if psb_img_file != "" else "",
				"lines":  psb_lines,
			})
		# Nested forks — recurse.
		var raw_pr_forks: Array = raw_path.get("Forks", raw_path.get("forks", []))
		for raw_nf in raw_pr_forks:
			if not raw_nf is Dictionary:
				continue
			path_entry["forks"].append(parse_fork(raw_nf, journey_path))
		fork_entry["paths"].append(path_entry)
	return fork_entry


# Converts a boss-modifier entry from journey.json (PascalCase) into the
# lowercase internal effect form. Only the keys relevant to the kind are kept.
static func _parse_boss_modifier(raw_mod: Dictionary) -> Dictionary:
	var mod: Dictionary = {"kind": raw_mod.get("Kind", raw_mod.get("kind", ""))}
	if raw_mod.has("Factor") or raw_mod.has("factor"):
		mod["factor"] = raw_mod.get("Factor", raw_mod.get("factor", 1.0))
	if raw_mod.has("Min") or raw_mod.has("min"):
		mod["min"] = raw_mod.get("Min", raw_mod.get("min", 0))
	if raw_mod.has("Max") or raw_mod.has("max"):
		mod["max"] = raw_mod.get("Max", raw_mod.get("max", 100))
	return mod


# Finds the journey cover image. New journeys keep all images in a media/
# subfolder; old journeys stored the cover at the journey root.
static func find_cover_image(path: String) -> String:
	var media_path: String = path + "/media"
	var media_dir: DirAccess = DirAccess.open(media_path)
	if media_dir != null:
		media_dir.list_dir_begin()
		var mfname: String = media_dir.get_next()
		while mfname != "":
			if not media_dir.current_is_dir() and mfname.get_extension().to_lower() in IMAGE_EXTS:
				media_dir.list_dir_end()
				return media_path + "/" + mfname
			mfname = media_dir.get_next()
		media_dir.list_dir_end()

	# Fallback: old journeys stored the cover at the journey root.
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension().to_lower() in IMAGE_EXTS:
			dir.list_dir_end()
			return path + "/" + fname
		fname = dir.get_next()
	dir.list_dir_end()
	return ""


# Resolves a round's funscript stats as {count, length_ms, path}.
# Fast path: when journey.json carries cached ActionCount/LengthMs (written by
# JourneyBuilder at save time), no funscript is parsed at all. Otherwise it
# parses the file directly, or — for pre-cache journeys with no FunscriptPath —
# scans the round folder.
static func _resolve_round_stats(raw: Dictionary, base_path: String, scan_folder: String) -> Dictionary:
	var explicit_rel: String = raw.get("FunscriptPath", raw.get("funscript_path", ""))
	if explicit_rel != "":
		var full_path: String = base_path + "/" + explicit_rel
		if raw.has("ActionCount") and raw.has("LengthMs"):
			return {
				"count":     int(raw["ActionCount"]),
				"length_ms": int(raw["LengthMs"]),
				"path":      full_path,
			}
		var st: Dictionary = JourneyData.read_funscript_stats(full_path)
		st["path"] = full_path if st["count"] > 0 else ""
		return st
	return _read_funscript_stats(scan_folder)


# Pre-cache fallback: scan a round folder for the L0 funscript and parse it.
# Used only for journeys saved before FunscriptPath/ActionCount were stored.
static func _read_funscript_stats(folder: String) -> Dictionary:
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return {"count": 0, "length_ms": 0, "path": ""}
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension() in ["funscript", "json"]:
			# Skip secondary-axis scripts (e.g. "Name_L1.funscript") — not the L0 main script.
			var stem: String = fname.get_basename()
			var is_axis: bool = false
			for ax: String in EXTRA_AXIS_SUFFIXES:
				if stem.ends_with(ax):
					is_axis = true
					break
			if not is_axis:
				var full_path: String = folder + "/" + fname
				dir.list_dir_end()
				var st: Dictionary = JourneyData.read_funscript_stats(full_path)
				st["path"] = full_path
				return st
		fname = dir.get_next()
	dir.list_dir_end()
	return {"count": 0, "length_ms": 0, "path": ""}
