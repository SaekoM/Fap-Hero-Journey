class_name JourneyData
extends RefCounted

# ---------------------------------------------------------------------------
# JourneyData
# Pure-data helpers for the journey-builder model. No UI. Stateless static-
# style methods that take and return plain Dictionaries / Arrays.
#
# The "model" is a flat Array of item dicts where each item is one of:
#   { type: "round",      name, funscript_path, video_path, coins }
#   { type: "shop",       title }
#   { type: "storyboard", coins, image, lines }
#   { type: "fork",       title, description, paths: [ {name, description, image_path, items: [...]} ] }
# Nested forks are stored inside a path's `items` array (recursive).
#
# Used by JourneyBuilder.gd via class-name calls:
#   JourneyData.parse_journey(j)            – inflate from saved JSON dict
#   JourneyData.validate(items, name)       – returns "" or first error
#   JourneyData.items_have_any_video(items) – any round in the tree has a video?
#   JourneyData.find_video_in_round(folder) – first video file in a folder
# ---------------------------------------------------------------------------

const DIFFICULTIES: Array = ["Easy", "Medium", "Hard", "Very Hard", "Extreme", "Insane"]

const VIDEO_EXTENSIONS:     Array[String] = ["mp4", "m4v", "mkv", "avi", "mov", "wmv", "webm"]
const FUNSCRIPT_EXTENSIONS: Array[String] = ["funscript", "json"]
const IMAGE_EXTENSIONS:     Array[String] = ["png", "jpg", "jpeg", "webp"]


# ── Parse ───────────────────────────────────────────────────────────────────

# Takes a journey dict as parsed by JourneySelect._parse_journey() and
# returns the builder model:
#   {
#     "name":           String,
#     "author":         String,
#     "description":    String,
#     "difficulty_idx": int,
#     "cover_path":     String,
#     "items":          Array[Dictionary],
#   }
static func parse_journey(journey: Dictionary) -> Dictionary:
	var name: String        = journey.get("title", "")
	var author: String      = journey.get("author", "")
	var description: String = journey.get("description", "")

	var diff: String  = journey.get("difficulty", "Easy")
	var diff_idx: int = DIFFICULTIES.find(diff)
	if diff_idx < 0:
		diff_idx = 0

	var cover_path: String = journey.get("cover_path", "")

	var rounds: Array = (journey.get("rounds", []) as Array).duplicate()
	rounds.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a.get("order", 0) as int) < (b.get("order", 0) as int)
	)
	var forks:       Array = (journey.get("forks",       []) as Array).duplicate()
	var shops:       Array = (journey.get("shops",       []) as Array).duplicate()
	var storyboards: Array = (journey.get("storyboards", []) as Array).duplicate()

	# Interleave by the same key scheme as GameState.BuildSequence so authoring
	# order is preserved after a round-trip through disk.
	var seq: Array = []
	for r: Dictionary in rounds:
		seq.append({
			"key":  (r.get("order", 0) as int) * 3,
			"data": {
				"type":           "round",
				"name":           r.get("name", ""),
				"funscript_path": r.get("funscript_path", ""),
				"video_path":     find_video_in_round(r.get("folder", "")),
				"coins":          r.get("coins", 0),
			},
		})
	for sb: Dictionary in storyboards:
		seq.append({
			"key":  (sb.get("order", 0) as int) * 3,
			"data": {
				"type":  "storyboard",
				"coins": sb.get("coins", 0),
				"image": sb.get("image", ""),
				"lines": sb.get("lines", []),
			},
		})
	for sh: Dictionary in shops:
		seq.append({
			"key":  (sh.get("after_order", 0) as int) * 3 + 1,
			"data": {
				"type":  "shop",
				"title": sh.get("title", ""),
			},
		})
	for f: Dictionary in forks:
		seq.append({
			"key":  (f.get("after_order", 0) as int) * 3 + 2,
			"data": _build_fork_item(f),
		})
	seq.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a["key"] as int) < (b["key"] as int))

	var items: Array = []
	for s in seq:
		items.append(s["data"])

	return {
		"name":           name,
		"author":         author,
		"description":    description,
		"difficulty_idx": diff_idx,
		"cover_path":     cover_path,
		"items":          items,
	}


# Recursively converts a parsed-journey fork dict into the builder _items model
# (which uses a single mixed items[] array per path rather than separate
# rounds/storyboards/shops/forks arrays).
static func _build_fork_item(f: Dictionary) -> Dictionary:
	var paths_out: Array = []
	for p: Dictionary in f.get("paths", []):
		paths_out.append({
			"name":        p.get("name", ""),
			"description": p.get("description", ""),
			"image_path":  p.get("image_path", ""),
			"items":       _build_path_items(p),
		})
	return {
		"type":        "fork",
		"title":       f.get("title", ""),
		"description": f.get("description", ""),
		"paths":       paths_out,
	}


# Recursively rebuilds a path's mixed items[] array from the parsed-journey
# separate rounds/storyboards/shops/forks arrays. Nested forks recurse.
static func _build_path_items(p: Dictionary) -> Array:
	var sub: Array = []
	for pr: Dictionary in p.get("rounds", []):
		sub.append({
			"key":  (pr.get("order", 0) as int) * 3,
			"data": {
				"type":           "round",
				"name":           pr.get("name", ""),
				"funscript_path": pr.get("funscript_path", ""),
				"video_path":     find_video_in_round(pr.get("folder", "")),
				"coins":          pr.get("coins", 0),
			},
		})
	for psb: Dictionary in p.get("storyboards", []):
		sub.append({
			"key":  (psb.get("order", 0) as int) * 3,
			"data": {
				"type":  "storyboard",
				"coins": psb.get("coins", 0),
				"image": psb.get("image", ""),
				"lines": psb.get("lines", []),
			},
		})
	for ps: Dictionary in p.get("shops", []):
		sub.append({
			"key":  (ps.get("after_order", 0) as int) * 3 + 1,
			"data": {
				"type":  "shop",
				"title": ps.get("title", ""),
			},
		})
	for nf: Dictionary in p.get("forks", []):
		sub.append({
			"key":  (nf.get("after_order", 0) as int) * 3 + 2,
			"data": _build_fork_item(nf),
		})
	sub.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a["key"] as int) < (b["key"] as int))
	var items: Array = []
	for s in sub:
		items.append(s["data"])
	return items


# ── Validate ────────────────────────────────────────────────────────────────

# Returns "" if the model is valid for saving, otherwise a user-facing message
# describing the first problem encountered.
static func validate(items: Array, journey_name: String) -> String:
	if journey_name.strip_edges() == "":
		return "Please enter a journey name."

	var top_round_count: int = items.reduce(
		func(acc: int, it: Dictionary) -> int:
			return acc + (1 if it.get("type", "round") == "round" else 0),
		0)
	if top_round_count == 0:
		return "Please add at least one round before saving."

	var round_idx_global: int = 0
	for it: Dictionary in items:
		var t: String = it.get("type", "round")
		match t:
			"round":
				round_idx_global += 1
				if (it.get("name", "") as String).strip_edges() == "":
					return "Round %d needs a name." % round_idx_global
				if it.get("funscript_path", "") == "":
					return "Round \"%s\" needs a funscript." % it.get("name", "?")
			"fork":
				var ctx: String = "fork after round %d" % round_idx_global
				var ferr: String = validate_fork(it, ctx)
				if ferr != "":
					return ferr
			"storyboard":
				var lines: Array = it.get("lines", [])
				if lines.is_empty():
					return "A storyboard needs at least one line."
	return ""


# Recursively validates a fork. Returns "" if OK, or an error message.
# `context_label` is used in messages so the user knows where the error is
# (e.g. "fork after round 3" or "nested fork in path \"Path A\"").
static func validate_fork(fork_item: Dictionary, context_label: String) -> String:
	var paths: Array = fork_item.get("paths", [])
	if paths.size() < 2:
		return "The %s needs at least 2 paths." % context_label
	for pi in paths.size():
		var ppath: Dictionary = paths[pi]
		var pname: String = ppath.get("name", "")
		if pname.strip_edges() == "":
			return "Path %d of %s needs a name." % [pi + 1, context_label]
		var pi_list: Array = ppath.get("items", [])
		var pr_count: int = pi_list.reduce(
			func(acc: int, x: Dictionary) -> int:
				return acc + (1 if x.get("type", "round") == "round" else 0),
			0)
		if pr_count == 0:
			return "Path \"%s\" (in %s) needs at least one round." % [pname, context_label]
		for pi_item: Dictionary in pi_list:
			var pi_t: String = pi_item.get("type", "round")
			match pi_t:
				"round":
					if (pi_item.get("name", "") as String).strip_edges() == "":
						return "A round in path \"%s\" needs a name." % pname
					if pi_item.get("funscript_path", "") == "":
						return "Round \"%s\" in path \"%s\" needs a funscript." % [pi_item.get("name", "?"), pname]
				"fork":
					var nested_err: String = validate_fork(pi_item, "nested fork in path \"%s\"" % pname)
					if nested_err != "":
						return nested_err
	return ""


# ── Filesystem helpers ──────────────────────────────────────────────────────

# Returns the path to the first video file in `folder`, or "" if none.
static func find_video_in_round(folder: String) -> String:
	if folder == "":
		return ""
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension().to_lower() in VIDEO_EXTENSIONS:
			dir.list_dir_end()
			return folder + "/" + fname
		fname = dir.get_next()
	dir.list_dir_end()
	return ""


# Recursively scans a items[] tree (including nested fork paths) for any
# round that has a video_path attached.
static func items_have_any_video(items: Array) -> bool:
	for it in items:
		match it.get("type", "round"):
			"round":
				if it.get("video_path", "") != "":
					return true
			"fork":
				for p in it.get("paths", []):
					if items_have_any_video(p.get("items", [])):
						return true
	return false


# Sanitize an arbitrary string into a filesystem-safe folder name.
# (Moved from JourneyBuilder.gd — used by the save flow.)
static func sanitize_folder_name(name: String) -> String:
	const INVALID: String = "\\/:*?\"<>|"
	var result: String = ""
	for ch: String in name:
		if ch in INVALID:
			continue
		result += "_" if ch == " " else ch
	return result if result != "" else "Journey"
