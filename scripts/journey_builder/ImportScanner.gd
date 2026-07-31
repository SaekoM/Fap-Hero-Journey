class_name ImportScanner
extends RefCounted

## Pure file/path logic for bulk-importing rounds from dropped files: filename → axis/vib detection,
## sibling matching on disk, and grouping a folder of files into round data. No UI, no builder state —
## so it's unit-tested directly (tests/import_scanner_test.gd). JourneyBuilder owns the graph-node
## creation that consumes build_rounds(); BuilderSidePanel uses autofill_round_siblings for single drops.

# Funscript filename suffixes that mark a secondary axis or a vibrator channel. Kept in sync with
# detect_funscript_axis / detect_vib_channel — used to strip the suffix so "scene1", "scene1_L1",
# "scene1.vib1" all share a round key during bulk import.
const SCRIPT_SUFFIXES: Array[String] = [
	"_l1",
	".l1",
	"_l2",
	".l2",
	"_r0",
	".r0",
	"_r1",
	".r1",
	"_r2",
	".r2",
	"_surge",
	".surge",
	"_sway",
	".sway",
	"_twist",
	".twist",
	"_roll",
	".roll",
	"_pitch",
	".pitch",
	".vib1",
	"_vib1",
	".vibe1",
	"_vibe1",
	".vib2",
	"_vib2",
	".vibe2",
	"_vibe2",
	# restim / E-Stim Full position aliases (alpha→L0 main, beta→L1) …
	".alpha",
	"_alpha",
	".beta",
	"_beta",
	# … and the e-stim parameter scripts (restim-only). Longer names listed before the plain
	# vib1/vib2 endings above are safe: strip/detect use exact-tail ends_with, no prefix overlap.
	".volume",
	"_volume",
	".carrier_frequency",
	"_carrier_frequency",
	".pulse_frequency",
	"_pulse_frequency",
	".pulse_width",
	"_pulse_width",
	".pulse_interval_random",
	"_pulse_interval_random",
	".pulse_rise_time",
	"_pulse_rise_time",
	".vib1_frequency",
	"_vib1_frequency",
	".vib1_strength",
	"_vib1_strength",
	".vib1_random",
	"_vib1_random",
	".vib2_frequency",
	"_vib2_frequency",
	".vib2_strength",
	"_vib2_strength",
	".vib1_left_right_bias",
	"_vib1_left_right_bias",
	".vib1_up_down_bias",
	"_vib1_up_down_bias",
	".vib2_left_right_bias",
	"_vib2_left_right_bias",
	".vib2_up_down_bias",
	"_vib2_up_down_bias",
	".vib2_random",
	"_vib2_random",
]


# Infers the T-code axis from a funscript filename. Checks T-code axis-code suffixes first (_L1, .L1)
# then human-readable names (_surge, .pitch, …). Returns "L0" if no axis marker (main stroke script).
static func detect_funscript_axis(path: String) -> String:
	var stem: String = path.get_file().get_basename().to_lower()
	var axis_codes: Dictionary = {
		"_l1": "L1",
		".l1": "L1",
		"_l2": "L2",
		".l2": "L2",
		"_r0": "R0",
		".r0": "R0",
		"_r1": "R1",
		".r1": "R1",
		"_r2": "R2",
		".r2": "R2",
	}
	for suffix: String in axis_codes:
		if stem.ends_with(suffix):
			return axis_codes[suffix]
	var name_codes: Dictionary = {
		"_surge": "L1",
		".surge": "L1",
		"_sway": "L2",
		".sway": "L2",
		"_twist": "R0",
		".twist": "R0",
		"_roll": "R1",
		".roll": "R1",
		"_pitch": "R2",
		".pitch": "R2",
		# restim position aliases: alpha = main stroke (L0), beta = the L1 axis.
		"_alpha": "L0",
		".alpha": "L0",
		"_beta": "L1",
		".beta": "L1",
	}
	for suffix: String in name_codes:
		if stem.ends_with(suffix):
			return name_codes[suffix]
	return "L0"


# Infers a restim (E-Stim Full) parameter axis from a funscript filename, e.g. "scene.volume" → "V0",
# "scene.carrier_frequency" → "C0". These have no serial/motion equivalent and stream to restim only.
# Returns "" when the filename carries no e-stim parameter suffix. Checked BEFORE detect_funscript_axis
# during import (those names would otherwise fall through to the L0 main-script default).
static func detect_estim_axis(path: String) -> String:
	var stem: String = path.get_file().get_basename().to_lower()
	var codes: Dictionary = {
		"volume": "V0",
		"carrier_frequency": "C0",
		"pulse_frequency": "P0",
		"pulse_width": "P1",
		"pulse_interval_random": "P2",
		"pulse_rise_time": "P3",
		"vib1_frequency": "V1",
		"vib1_strength": "V2",
		"vib1_random": "V3",
		"vib2_frequency": "V4",
		"vib2_strength": "V5",
		"vib1_left_right_bias": "V6",
		"vib1_up_down_bias": "V7",
		"vib2_left_right_bias": "V8",
		"vib2_up_down_bias": "V9",
		"vib2_random": "W1",
	}
	for name: String in codes:
		if stem.ends_with("." + name) or stem.ends_with("_" + name):
			return codes[name]
	return ""


# Returns "vib1" or "vib2" when the filename carries a recognised vibrator-script suffix
# (.vib1, _vib1, .vibe1, _vibe1 → "vib1"; .vib2 variants → "vib2"). Returns "" for any other filename.
static func detect_vib_channel(path: String) -> String:
	var stem: String = path.get_file().get_basename().to_lower()
	for s: String in [".vib1", "_vib1", ".vibe1", "_vibe1"]:
		if stem.ends_with(s):
			return "vib1"
	for s: String in [".vib2", "_vib2", ".vibe2", "_vibe2"]:
		if stem.ends_with(s):
			return "vib2"
	return ""


# The file's basename with any recognised axis/vib suffix removed, so a secondary-axis or vib script
# groups with its main round during bulk import. Preserves the original casing of the stem.
static func strip_script_suffix(path: String) -> String:
	var stem: String = path.get_file().get_basename()
	var low: String = stem.to_lower()
	for s: String in SCRIPT_SUFFIXES:
		if low.ends_with(s):
			return stem.substr(0, stem.length() - s.length())
	return stem


# Round grouping key: directory + base name (suffix stripped), lowercased — so a video and its scripts
# in one folder pair up, while same-named files in different folders stay separate rounds.
static func round_group_key(path: String) -> String:
	return ("%s/%s" % [path.get_base_dir(), strip_script_suffix(path)]).to_lower()


# Any one real path from an import group (video, then funscript, then an axis, then a vib), or "".
# Anchors the disk scan for sibling autofill.
static func group_anchor_path(g: Dictionary) -> String:
	if g["video"] != "":
		return g["video"]
	if g["funscript"] != "":
		return g["funscript"]
	for a: String in (g["axis"] as Dictionary).values():
		return a
	for v: String in (g["vib"] as Dictionary).values():
		return v
	# .get(): "estim" is a later addition, so callers built before it (and the pure unit tests)
	# legitimately pass groups without the key.
	for e: String in (g.get("estim", {}) as Dictionary).values():
		return e
	return ""


# Creates an empty import group for `key` (preserving first-seen order) if absent.
static func ensure_import_group(groups: Dictionary, order: Array, key: String) -> void:
	if not groups.has(key):
		groups[key] = {"video": "", "funscript": "", "axis": {}, "vib": {}, "estim": {}, "name": ""}
		order.append(key)


# Expands a dropped path list: directories are walked recursively and replaced by the video/funscript
# files inside; plain files pass through. Sorted for a stable round order.
static func expand_dropped_paths(files: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = []
	for f: String in files:
		if DirAccess.dir_exists_absolute(f):
			collect_files_recursive(f, out)
		else:
			out.append(f)
	out.sort()
	return out


# Recursively appends every video/funscript file under `dir` into `out`.
static func collect_files_recursive(dir: String, out: PackedStringArray) -> void:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var fname: String = d.get_next()
	while fname != "":
		if fname != "." and fname != "..":
			var full: String = "%s/%s" % [dir, fname]
			if d.current_is_dir():
				collect_files_recursive(full, out)
			else:
				var ext: String = fname.get_extension().to_lower()
				if ext in JourneyData.VIDEO_EXTENSIONS or ext in JourneyData.FUNSCRIPT_EXTENSIONS:
					out.append(full)
		fname = d.get_next()
	d.list_dir_end()


# Scans `dir` for every funscript whose base name (suffix stripped) matches `base`, classifying each
# into the main stroke script, a secondary axis, or a vib channel — reusing the same suffix detection
# as drag-routing. Returns {"funscript": String, "axis": Dictionary, "vib": Dictionary}; first match
# wins per slot.
static func find_sibling_scripts(dir: String, base: String) -> Dictionary:
	var result: Dictionary = {"funscript": "", "axis": {}, "vib": {}, "estim": {}}
	var base_low: String = base.to_lower()
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return result
	d.list_dir_begin()
	var fname: String = d.get_next()
	while fname != "":
		if (
			not d.current_is_dir()
			and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS
		):
			var full: String = "%s/%s" % [dir, fname]
			if strip_script_suffix(full).to_lower() == base_low:
				var vib_ch: String = detect_vib_channel(full)
				var estim_ax: String = detect_estim_axis(full)
				if vib_ch != "":
					if not result["vib"].has(vib_ch):
						result["vib"][vib_ch] = full
				elif estim_ax != "":
					if not result["estim"].has(estim_ax):
						result["estim"][estim_ax] = full
				else:
					var axis: String = detect_funscript_axis(full)
					if axis == "L0":
						if result["funscript"] == "":
							result["funscript"] = full
					elif not result["axis"].has(axis):
						result["axis"][axis] = full
		fname = d.get_next()
	d.list_dir_end()
	return result


# Finds a video next to a funscript/round by base name. Returns its path, or "" if none exists.
static func find_sibling_video(dir: String, base: String) -> String:
	for ext: String in JourneyData.VIDEO_EXTENSIONS:
		var cand: String = "%s/%s.%s" % [dir, base, ext]
		if FileAccess.file_exists(cand):
			return cand
	return ""


# Fills any EMPTY slots of `round_data` (main funscript, video, secondary axes, vib channels) from
# same-named files sitting next to `anchor_path` on disk. Never overwrites a slot the author already
# set. Returns true if anything was filled. Used by the bulk importer and the single-round drop.
static func autofill_round_siblings(round_data: Dictionary, anchor_path: String) -> bool:
	var dir: String = anchor_path.get_base_dir()
	var base: String = strip_script_suffix(anchor_path)
	var changed: bool = false

	var scan: Dictionary = find_sibling_scripts(dir, base)

	if (round_data.get("funscript_path", "") as String) == "" and scan["funscript"] != "":
		round_data["funscript_path"] = scan["funscript"]
		changed = true
	if (round_data.get("video_path", "") as String) == "":
		var sv: String = find_sibling_video(dir, base)
		if sv != "":
			round_data["video_path"] = sv
			changed = true

	if not round_data.has("axis_scripts"):
		round_data["axis_scripts"] = {}
	for axis: String in scan["axis"]:
		if not (round_data["axis_scripts"] as Dictionary).has(axis):
			round_data["axis_scripts"][axis] = scan["axis"][axis]
			changed = true

	if not round_data.has("vib_scripts"):
		round_data["vib_scripts"] = {}
	for ch: String in scan["vib"]:
		if not (round_data["vib_scripts"] as Dictionary).has(ch):
			round_data["vib_scripts"][ch] = scan["vib"][ch]
			changed = true

	if not round_data.has("estim_scripts"):
		round_data["estim_scripts"] = {}
	for eax: String in scan["estim"]:
		if not (round_data["estim_scripts"] as Dictionary).has(eax):
			round_data["estim_scripts"][eax] = scan["estim"][eax]
			changed = true

	return changed


# Groups dropped files by folder + base name (a video + its matched scripts → one round) and builds
# each group's round data: the round template + the group's media, then any missing siblings autofilled
# from disk. A group needs a video to become a round; funscript-only groups are counted in
# skipped_no_video. Returns { "rounds": Array[Dictionary], "skipped_no_video": int } in first-seen order.
static func build_rounds(files: PackedStringArray) -> Dictionary:
	var groups: Dictionary = {}  # round_key -> {video, funscript, axis:{}, vib:{}, name}
	var order: Array = []  # round_keys in first-seen order
	for f: String in files:
		var ext: String = f.get_extension().to_lower()
		var key: String = round_group_key(f)
		if ext in JourneyData.VIDEO_EXTENSIONS:
			ensure_import_group(groups, order, key)
			groups[key]["video"] = f
			if groups[key]["name"] == "":
				groups[key]["name"] = f.get_file().get_basename()
		elif ext in JourneyData.FUNSCRIPT_EXTENSIONS:
			ensure_import_group(groups, order, key)
			var vib_ch: String = detect_vib_channel(f)
			var estim_ax: String = detect_estim_axis(f)
			if vib_ch != "":
				groups[key]["vib"][vib_ch] = f
			elif estim_ax != "":
				groups[key]["estim"][estim_ax] = f
			else:
				var axis: String = detect_funscript_axis(f)
				if axis == "L0":
					groups[key]["funscript"] = f
					if groups[key]["name"] == "":
						groups[key]["name"] = f.get_file().get_basename()
				else:
					groups[key]["axis"][axis] = f

	var rounds: Array = []
	var skipped_no_video: int = 0
	for key: String in order:
		var g: Dictionary = groups[key]
		var data: Dictionary = JourneyData.new_item("round").duplicate(true)
		data.erase("type")
		data.erase("node_id")
		data.erase("paths")
		data["name"] = (g["name"] as String) if (g["name"] as String) != "" else key
		data["funscript_path"] = g["funscript"]
		data["video_path"] = g["video"]
		data["axis_scripts"] = g["axis"]
		data["vib_scripts"] = g["vib"]
		data["estim_scripts"] = g["estim"]
		var anchor: String = group_anchor_path(g)
		if anchor != "":
			autofill_round_siblings(data, anchor)
		if str(data.get("video_path", "")) == "":
			skipped_no_video += 1
			continue
		rounds.append(data)
	return {"rounds": rounds, "skipped_no_video": skipped_no_video}
