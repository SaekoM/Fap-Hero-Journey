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
#
# Uses parse_graph so the catalogue is graph-aware: legacy journeys come back with the
# same meta + totals (plus the migrated graph under start/nodes, which the cards ignore),
# and new graph-format journeys will scan correctly once the builder writes them. Cost is
# one in-memory tree→graph migration per journey, which is negligible.
static func scan_all(journeys_dir: String) -> Array:
	var result: Array = []
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(journeys_dir)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(journeys_dir))
		return result
	var dir: DirAccess = DirAccess.open(journeys_dir)
	if dir == null:
		return result
	# Rendition folders (Type: "rendition") are collected separately and attached to their parent
	# journey by ParentId — an overlay never shows as its own catalogue card.
	var renditions: Array = []
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			var folder_path: String = journeys_dir + "/" + entry
			var raw: Dictionary = _read_raw_json(folder_path)
			if not raw.is_empty():
				if JourneyRendition.is_rendition(raw):
					renditions.append(_rendition_summary(raw, folder_path, entry))
				else:
					var journey: Dictionary = parse_graph(folder_path, entry)
					if not journey.is_empty():
						result.append(journey)
		entry = dir.get_next()
	dir.list_dir_end()
	group_renditions(result, renditions)
	return result


# Reads a folder's journey.json into its raw dict (or {} when missing/malformed). Used to peek at Type
# before deciding whether to parse a full journey or collect a rendition summary.
static func _read_raw_json(folder_path: String) -> Dictionary:
	var json_path: String = folder_path + "/journey.json"
	if not FileAccess.file_exists(json_path):
		return {}
	var file: FileAccess = FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		return {}
	var parser: JSON = JSON.new()
	var err: int = parser.parse(file.get_as_text())
	file.close()
	if err != OK or not (parser.data is Dictionary):
		return {}
	return parser.data


# The lightweight catalogue entry for a rendition (it's not a playable card on its own — it's listed
# under its parent's detail modal as a selectable variant).
static func _rendition_summary(
	data: Dictionary, folder_path: String, folder_name: String
) -> Dictionary:
	return {
		"folder": folder_path,
		"folder_name": folder_name,
		"journey_id": str(data.get("JourneyId", "")),
		"name": str(data.get("Name", folder_name)),
		"author": str(data.get("Author", "")),
		"description": str(data.get("Description", "")),
		"parent_id": str(data.get("ParentId", "")),
		"parent_min_version": str(data.get("ParentMinVersion", "")),
		# Soft edit-lock: true on a rendition installed from a paid pack (see the journey summary above).
		"locked": bool(data.get("Locked", false)),
		"cover_path": find_cover_image(folder_path),  # its own media/cover.* if the author set one, else ""
	}


# Attaches each rendition to its ultimate base journey's `renditions` list. A rendition's ParentId may be
# a base journey OR ANOTHER rendition (sibling-dependency: e.g. a free-video overlay filling a paid-script
# overlay's slots), so each rendition's parent chain is walked to the base. Every journey gets a
# `renditions` array (all descendants, flattened). Each rendition gets `chain_folders` — the ordered list
# of rendition folders to compose base-ward (…ancestors…, self) — which the loader/selector use to compose
# the whole stack. An orphan (chain doesn't reach an installed base, or loops) is left out.
static func group_renditions(journeys: Array, renditions: Array) -> void:
	var base_by_id: Dictionary = {}
	for j: Dictionary in journeys:
		j["renditions"] = []
		var jid: String = str(j.get("journey_id", ""))
		if jid != "":
			base_by_id[jid] = j
	var rend_by_id: Dictionary = {}
	for r: Dictionary in renditions:
		var rid: String = str(r.get("journey_id", ""))
		if rid != "":
			rend_by_id[rid] = r
	for rend: Dictionary in renditions:
		var resolved: Dictionary = _resolve_rendition_chain(rend, base_by_id, rend_by_id)
		if resolved.is_empty():
			continue
		rend["chain_folders"] = resolved["chain"]
		((resolved["base"] as Dictionary)["renditions"] as Array).append(rend)


# Walks a rendition's ParentId chain to its ultimate base journey. Returns {base, chain} where `chain` is
# the ordered list of rendition FOLDERS to compose (base-ward first, ending with this rendition), or {} when
# the chain doesn't reach an installed base (orphan) or loops.
static func _resolve_rendition_chain(
	r: Dictionary, base_by_id: Dictionary, rend_by_id: Dictionary
) -> Dictionary:
	var chain: Array = []  # self-ward; reversed to base-ward before returning
	var seen: Dictionary = {}
	var cur: Dictionary = r
	while not seen.has(str(cur.get("journey_id", ""))):
		seen[str(cur.get("journey_id", ""))] = true
		chain.append(str(cur.get("folder", "")))
		var pid: String = str(cur.get("parent_id", ""))
		if base_by_id.has(pid):
			chain.reverse()
			return {"base": base_by_id[pid], "chain": chain}
		if not rend_by_id.has(pid):
			return {}  # parent (base or ancestor rendition) isn't installed
		cur = rend_by_id[pid]
	return {}  # the loop exited via `seen` → a cyclic dependency, so drop it


# Reads a rendition folder's delta, with its media paths resolved against the RENDITION's own base
# (per-origin). Returns the runtime delta JourneyCompose consumes, or {} when unreadable.
static func load_rendition_delta(rendition_folder: String) -> Dictionary:
	var data: Dictionary = _read_raw_json(rendition_folder)
	if data.is_empty():
		return {}
	var delta: Dictionary = JourneyRendition.parse_rendition(data)
	JourneyRendition.resolve_delta_paths(delta, rendition_folder)
	delta["map_backdrops"] = _parse_map_backdrops(data.get("MapBackdrops", []), rendition_folder)
	return delta


# Produces a play-ready journey dict = the BASE journey (its meta, paths resolved against the base folder)
# with its graph replaced by base ⊕ the whole rendition CHAIN. `chain_folders` is the ordered list of
# rendition folders to compose base-ward (a single-rendition chain is just [that folder]); each is resolved
# against its OWN folder before composing, so the merged graph carries correct absolute paths from every
# origin. The runtime consumes it exactly like a normal journey (GameState.StartJourney); `compose_errors`
# collects break-loudly reports from every layer for the caller to surface.
static func compose_play_journey(
	base_folder: String, base_folder_name: String, chain_folders: Array
) -> Dictionary:
	var base: Dictionary = parse_graph(base_folder, base_folder_name)
	if base.is_empty():
		return {}
	var graph: Dictionary = {"start": base.get("start", ""), "nodes": base.get("nodes", {})}
	var errors: Array = []
	for rf: Variant in chain_folders:
		var delta: Dictionary = load_rendition_delta(str(rf))
		var composed: Dictionary = JourneyCompose.compose_graph(graph, delta)
		graph = composed["graph"]
		errors.append_array(composed["errors"] as Array)
	base["start"] = graph["start"]
	base["nodes"] = graph["nodes"]
	base["compose_errors"] = errors
	base["active_rendition"] = str(chain_folders[-1]) if not chain_folders.is_empty() else ""
	# Rebuild the catalogue preview (round/fork/shop/storyboard lists + totals) from the MERGED graph so
	# the detail modal and stats reflect base ⊕ rendition, not just the base.
	var mgraph: Dictionary = {"start": base["start"], "nodes": base["nodes"]}
	var seq: Dictionary = _graph_catalogue_sequence(mgraph)
	base["rounds"] = seq["rounds"]
	base["shops"] = seq["shops"]
	base["storyboards"] = seq["storyboards"]
	base["forks"] = seq["forks"]
	base["total_rounds"] = JourneyGraph.longest_round_path(mgraph, str(mgraph["start"]))
	var totals: Dictionary = _graph_node_totals(mgraph)
	base["total_actions"] = totals["actions"]
	base["total_length_ms"] = totals["length_ms"]
	# Backdrops STACK through the chain: the base's layers (bottom, resolved against the base folder) plus
	# each rendition's own (resolved against ITS folder), so a composed rendition's map shows them all.
	var backdrops: Array = (base.get("map_backdrops", []) as Array).duplicate(true)
	for rf: Variant in chain_folders:
		backdrops.append_array(
			_parse_map_backdrops(_read_raw_json(str(rf)).get("MapBackdrops", []), str(rf))
		)
	base["map_backdrops"] = backdrops
	return base


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
		"folder": path,
		"folder_name": folder,
		"title": data.get("Name", folder),
		"description": data.get("Description", ""),
		"difficulty": data.get("Difficulty", "Unknown"),
		"author": data.get("Author", "Unknown"),
		# Journey-level: author can disable the player map to enforce surprise.
		# Absent → true so the whole pre-existing catalogue keeps the map.
		"map_enabled": bool(data.get("MapEnabled", true)),
		"show_fork_counts": bool(data.get("ShowForkCounts", true)),
		"show_loops_on_map": bool(data.get("ShowLoopsOnMap", false)),
		"map_backdrops": _parse_map_backdrops(data.get("MapBackdrops", []), path),
		# Fog of war on the player map: reveal nodes as they're discovered (off → whole map shown).
		"map_fog": bool(data.get("MapFog", false)),
		# Fog reveal depth: ghost levels shown ahead of the visited trail (< 0 = whole structure ghosted).
		"map_fog_reveal": int(data.get("MapFogReveal", 1)),
		# Mystery preview: blur the previewer's totals + flow until the player discovers nodes.
		"mystery_preview": bool(data.get("MysteryPreview", false)),
		# Auto-advance countdown on storyboards / interactive forks (journey opt-in; absent → off).
		# Separate durations; the fork field falls back to the earlier single AutoAdvanceSecs key.
		"auto_advance_enabled": bool(data.get("AutoAdvanceEnabled", false)),
		"auto_advance_storyboard_secs": int(data.get("AutoAdvanceStoryboardSecs", 20)),
		"auto_advance_fork_secs":
		# Finish / "I came" button: author opt-in to end the run early, optionally into a designated
		int(data.get("AutoAdvanceForkSecs", data.get("AutoAdvanceSecs", 45))),
		# aftercare node (any type — a gentle round or a storyboard; off the main graph) before the end.
		"allow_finish": bool(data.get("AllowFinish", false)),
		"finish_node": str(data.get("FinishNode", "")),
		# Version stamps (absent on pre-0.6.0 journeys → blank, which always passes the gate).
		"min_version": str(data.get("MinVersion", "")),
		"created_with": str(data.get("CreatedWith", "")),
		# Counter names surfaced to the player (see _graph_meta).
		"shown_counters": JourneyData.clean_flag_list(data.get("ShownCounters", [])),
		# Stable journey id; blank on journeys written before ids existed (see _graph_meta).
		"journey_id": str(data.get("JourneyId", "")),
		# Soft edit-lock: true on a journey installed from a paid pack, so the buyer can't open it in the
		# builder. A courtesy lock (journey.json is plaintext) — see JourneySelect._on_edit_pressed.
		"locked": bool(data.get("Locked", false)),
		# Redirect overlay (skip/converge/end), composed onto the graph in parse_graph.
		"redirects": data.get("Redirects", {}),
		"rounds": [],
		"forks": [],
		"shops": [],
		"storyboards": [],
		"cover_path": "",
		"tags": TagRegistry.sanitize(data.get("Tags", [])),
		"total_actions": 0,
		"total_length_ms": 0,
		"total_rounds": 0,
		"modified_time": FileAccess.get_modified_time(json_path),
	}

	var raw_shops: Array = data.get("Shops", [])
	for raw_shop in raw_shops:
		if raw_shop is Dictionary:
			journey["shops"].append(_parse_shop(raw_shop))
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
			(
				sb_lines
				. append(
					{
						"speaker": raw_line.get("Speaker", raw_line.get("speaker", "")),
						"text": raw_line.get("Text", raw_line.get("text", "")),
						"image": (path + "/" + line_img_file) if line_img_file != "" else "",
					}
				)
			)
		(
			journey["storyboards"]
			. append(
				{
					"order": raw_sb.get("Order", raw_sb.get("order", 0)),
					"node_id": raw_sb.get("NodeId", raw_sb.get("node_id", "")),
					"coins": raw_sb.get("CoinsAwarded", raw_sb.get("coins", 0)),
					"item": raw_sb.get("Item", raw_sb.get("item", "")),
					"image": (path + "/" + sb_img_file) if sb_img_file != "" else "",
					"lines": sb_lines,
				}
			)
		)

	journey["cover_path"] = find_cover_image(path)

	var raw_rounds: Array = data.get("Rounds", [])
	# Filter out any legacy Shop-type rounds — shops are now declared via "Shops": [...]
	raw_rounds = raw_rounds.filter(
		func(r: Dictionary) -> bool: return r.get("RoundType", "Normal") != "Shop"
	)
	raw_rounds.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return (a.get("Order", 0) as int) < (b.get("Order", 0) as int)
	)

	for raw: Dictionary in raw_rounds:
		var round_name: String = raw.get("Name", "Round")
		# New journeys persist the on-disk folder slug (short, collision-free)
		# in "FolderName". Old journeys used the human-readable Name as the
		# folder, so fall back to that when FolderName is absent — keeps the
		# entire pre-rXXX catalogue loading without migration.
		var folder_slug: String = raw.get("FolderName", round_name)
		var round_folder: String = path + "/" + folder_slug

		var funscript_stats: Dictionary = _resolve_round_stats(raw, path, round_folder)

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
		# Explicit video path (new). Falls back to "" so the consumer can folder-
		# scan for pre-VideoPath journeys (JourneyData._round_video).
		var raw_video: String = raw.get("VideoPath", raw.get("video_path", ""))
		var video_path: String = (path + "/" + raw_video) if raw_video != "" else ""
		var boss_image: String = raw.get("BossImage", "")
		if boss_image != "":
			boss_image = path + "/" + boss_image
		var boss_modifiers: Array = []
		for raw_mod in raw.get("BossModifiers", []):
			if raw_mod is Dictionary:
				boss_modifiers.append(_parse_boss_modifier(raw_mod))

		var round_data: Dictionary = {
			"name": round_name,
			"folder": round_folder,
			"node_id": raw.get("NodeId", raw.get("node_id", "")),
			"video_path": video_path,
			"funscript_path": funscript_stats["path"],
			"axis_scripts": axis_scripts,
			"vib_scripts": vib_scripts,
			"is_checkpoint": bool(raw.get("IsCheckpoint", raw.get("is_checkpoint", false))),
			"is_warmup": bool(raw.get("IsWarmup", raw.get("is_warmup", false))),
			"boss_image": boss_image,
			"boss_tagline": raw.get("BossTagline", ""),
			"boss_modifiers": boss_modifiers,
			"coins": raw.get("CoinsAwarded", 0),
			"order": raw.get("Order", 0),
			"action_count": funscript_stats["count"],
			"length_ms": funscript_stats["length_ms"],
		}
		# Effect-round + sensory fields — read both the generic ("effect") and retired
		# cursed/blessed schemas (Pascal + lowercase), then normalize to the canonical
		# generic set so legacy journeys still play (migrate-on-load).
		round_data.merge(
			JourneyData.normalize_effect_round(_read_effect_fields(raw, round_type)), true
		)
		journey["total_actions"] = (
			(journey["total_actions"] as int) + (funscript_stats["count"] as int)
		)
		journey["total_length_ms"] = (
			(journey["total_length_ms"] as int) + (funscript_stats["length_ms"] as int)
		)
		journey["rounds"].append(round_data)

	journey["total_rounds"] = (journey["rounds"] as Array).size()

	var raw_forks: Array = data.get("Forks", [])
	var parsed_forks: Array = []
	for raw_fork: Dictionary in raw_forks:
		parsed_forks.append(parse_fork(raw_fork, path))
	journey["forks"] = parsed_forks

	# Accumulate the longest-path contribution from each fork.
	for fork: Dictionary in journey["forks"]:
		var lps: Dictionary = _longest_path_stats(fork)
		journey["total_actions"] = (journey["total_actions"] as int) + (lps["count"] as int)
		journey["total_length_ms"] = (journey["total_length_ms"] as int) + (lps["length_ms"] as int)
		journey["total_rounds"] = (journey["total_rounds"] as int) + (lps["round_count"] as int)

	return journey


# Reads a journey folder into the runtime GRAPH model ({start, nodes}, absolute paths).
# New journeys store the graph directly (Format 2 / "Nodes"); legacy tree journeys are
# parsed the old way (which resolves paths) and migrated via JourneyGraph.build_graph.
# Returns {} when journey.json is missing or malformed.
#
# Additive: parse_journey still serves the catalogue/builder/map consumers until the
# graph cutover wires them over to this. No path resolution duplication — the new-format
# branch resolves via JourneyGraph.resolve_paths, the legacy branch inherits parse_journey's.
static func parse_graph(path: String, folder: String) -> Dictionary:
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
	if JourneyGraph.is_graph_json(data):
		# New graph format: read the graph + journey meta straight from journey.json.
		var graph: Dictionary = JourneyGraph.from_json(data)
		JourneyGraph.resolve_paths(graph, path)
		var result: Dictionary = _graph_meta(data, path, folder)
		result["start"] = graph["start"]
		result["nodes"] = graph["nodes"]
		# Detail-modal preview: reconstruct an approximate nested tree (rounds / shops / storyboards /
		# forks-with-paths) from the graph — Format-2 journeys carry their structure in nodes (the
		# nested arrays _graph_meta leaves empty). Each fork's branches are walked up to their rejoin,
		# so the modal shows the real fork structure (see _graph_catalogue_sequence).
		var seq_lists: Dictionary = _graph_catalogue_sequence(graph)
		result["rounds"] = seq_lists["rounds"]
		result["shops"] = seq_lists["shops"]
		result["storyboards"] = seq_lists["storyboards"]
		result["forks"] = seq_lists["forks"]
		# DAG totals: the longest round path is the most a player can hit; node sums
		# feed the catalogue (see _graph_node_totals for the Phase-3 refinement note).
		result["total_rounds"] = JourneyGraph.longest_round_path(graph, str(graph["start"]))
		var totals: Dictionary = _graph_node_totals(graph)
		result["total_actions"] = totals["actions"]
		# Prefer the saved EXPECTED single-playthrough runtime — the builder's balance audit resolves loop
		# repeats, fork path-selection and pool picks into one number. Fall back to the node-length sum for
		# journeys saved before it existed (0 = not stored).
		var est_ms: int = int(data.get("EstimatedDurationMs", 0))
		result["total_length_ms"] = est_ms if est_ms > 0 else int(totals["length_ms"])
		result["comments"] = _parse_comments(data)  # editor-only sticky notes; runtime ignores them
		result["groups"] = _parse_groups(data)  # editor-only group frames; runtime ignores them
		return result

	# Legacy tree format → parse the old way (full nested model + meta + totals), then
	# migrate and attach the graph under start/nodes. Existing nested-model consumers
	# (map / catalogue) keep working off the same dict until the Phase 3 cutover.
	var tree: Dictionary = parse_journey(path, folder)
	if tree.is_empty():
		return {}
	var g: Dictionary = JourneyGraph.build_graph(tree)
	# Compose author redirects (skip / converge / end early) onto the migrated graph —
	# the hybrid's overlay half. A no-op for journeys with no Redirects map.
	JourneyGraph.apply_redirects(g, tree.get("redirects", {}))
	tree["start"] = g["start"]
	tree["nodes"] = g["nodes"]
	return tree


# Editor entry point (graph builder): the composed graph from parse_graph with a position
# guaranteed on every node — read from disk for a saved Format-2 graph, or seeded via GraphLayout
# for a freshly migrated legacy journey. The runtime keeps using parse_graph (positions unused
# there); only the builder needs the layout.
static func parse_graph_for_editor(path: String, folder: String) -> Dictionary:
	var graph: Dictionary = parse_graph(path, folder)
	if graph.is_empty():
		return {}
	# Legacy journeys (pre-VideoPath, with rNNN/ round folders) store the video only on disk, not in
	# journey.json — the runtime folder-scans for it at play time, but the EDITOR needs an explicit
	# video_path so the round shows its video and a re-save preserves it (the graph save reads
	# video_path directly, with no folder-scan fallback — without this it would silently drop the
	# video). The funscript is already resolved by the scanner (_resolve_round_stats); this closes the
	# matching gap for video. Round nodes carry an absolute `folder` (the rNNN path) to scan.
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		if n.get("type", "") == "round":
			var d: Dictionary = n.get("data", {})
			if str(d.get("video_path", "")) == "":
				var vid: String = JourneyData.find_video_in_round(str(d.get("folder", "")))
				if vid != "":
					d["video_path"] = vid
	for id: String in graph.get("nodes", {}):
		if not (graph["nodes"][id] as Dictionary).has("pos"):
			GraphLayout.seed_positions(graph)  # any node missing a pos → (re)seed the whole graph
			break
	return graph


# Journey-level meta for a new (graph-format) journey.json — mirrors parse_journey's
# meta block. The nested rounds/forks/shops/storyboards arrays are intentionally empty
# (graph journeys carry structure in start/nodes); the map/catalogue switch to the graph
# in Phase 3, at which point those consumers stop reading the nested arrays.
# Parses the journey's custom items and resolves each item's icon path (relative pooled path →
# absolute), so the runtime (inventory / shop) can load it directly.
static func _journey_items_resolved(data: Dictionary, base: String) -> Array:
	var items: Array = JourneyData.parse_journey_items(data.get("Items", []))
	for it: Dictionary in items:
		var img: String = str(it.get("image", ""))
		if img != "" and not _is_resolved_path(img):
			it["image"] = base.path_join(img)
		if str(it.get("category", "")) == "override":
			_resolve_override_scripts(it.get("scripts", {}), base)
	return items


# True when a path is already absolute (res:// / user:// / OS-absolute) and must NOT be joined onto the
# journey base — only pooled content/ rels are relative.
static func _is_resolved_path(p: String) -> bool:
	return p.begins_with("res://") or p.begins_with("user://") or p.is_absolute_path()


# Resolves an override item's funscript bundle (main + axes + vibes) from pooled content/ rels to
# absolute paths, in place, so GameLoop's bundle loader can read them directly. Mirrors the item-icon
# and cast-portrait resolution.
static func _resolve_override_scripts(scripts: Dictionary, base: String) -> void:
	var main_path: String = str(scripts.get("main", ""))
	if main_path != "" and not _is_resolved_path(main_path):
		scripts["main"] = base.path_join(main_path)
	for axis_name: Variant in scripts.get("axes", {}):
		var axis_path: String = str(scripts["axes"][axis_name])
		if axis_path != "" and not _is_resolved_path(axis_path):
			scripts["axes"][axis_name] = base.path_join(axis_path)
	for channel: Variant in scripts.get("vibes", {}):
		var vib_path: String = str(scripts["vibes"][channel])
		if vib_path != "" and not _is_resolved_path(vib_path):
			scripts["vibes"][channel] = base.path_join(vib_path)


# Storyboard cast — parsed to runtime (snake-case) with every portrait's relative pooled path resolved
# to absolute, so StoryboardScreen can load it directly. Placements are pure fractions (nothing to
# resolve). Mirrors _journey_items_resolved.
static func _journey_characters_resolved(data: Dictionary, base: String) -> Array:
	var characters: Array = JourneyData.parse_journey_characters(data.get("Characters", []))
	for c: Dictionary in characters:
		for por: Variant in c.get("portraits", []):
			var path: String = str((por as Dictionary).get("path", ""))
			if (
				path != ""
				and not (
					path.begins_with("res://")
					or path.begins_with("user://")
					or path.is_absolute_path()
				)
			):
				(por as Dictionary)["path"] = base.path_join(path)
	return characters


# Settings — parsed to runtime with every background and theme's pooled relative path resolved to
# absolute, so the storyboard screen and SettingMusic can use them directly. Mirrors
# _journey_characters_resolved.
static func _journey_settings_resolved(data: Dictionary, base: String) -> Array:
	var settings: Array = JourneyData.parse_journey_settings(data.get("Settings", []))
	for c: Dictionary in settings:
		for bg: Variant in c.get("backgrounds", []):
			(bg as Dictionary)["path"] = _resolved_media(
				str((bg as Dictionary).get("path", "")), base
			)
		c["bgm"] = _resolved_media(str(c.get("bgm", "")), base)
	return settings


# The journey's own score, each track resolved the same way.
static func _journey_bgm_resolved(data: Dictionary, base: String) -> Array:
	var out: Array = []
	var raw: Variant = data.get("Bgm", [])
	var tracks: Array = raw if raw is Array else [str(raw)]
	for t: Variant in tracks:
		var resolved: String = _resolved_media(str(t), base)
		if resolved != "":
			out.append(resolved)
	return out


# A pooled relative path made absolute against the journey folder. Already-absolute paths and engine
# paths are left alone, so a hand-edited journey.json pointing somewhere real still works.
static func _resolved_media(path: String, base: String) -> String:
	if path == "":
		return ""
	if path.begins_with("res://") or path.begins_with("user://") or path.is_absolute_path():
		return path
	return base.path_join(path)


static func _graph_meta(data: Dictionary, path: String, folder: String) -> Dictionary:
	return {
		"folder": path,
		"folder_name": folder,
		"title": data.get("Name", folder),
		"description": data.get("Description", ""),
		"difficulty": data.get("Difficulty", "Unknown"),
		"author": data.get("Author", "Unknown"),
		"tags": TagRegistry.sanitize(data.get("Tags", [])),
		"map_enabled": bool(data.get("MapEnabled", true)),
		"show_fork_counts": bool(data.get("ShowForkCounts", true)),
		"show_loops_on_map": bool(data.get("ShowLoopsOnMap", false)),
		"map_backdrops": _parse_map_backdrops(data.get("MapBackdrops", []), path),
		"map_fog": bool(data.get("MapFog", false)),
		"map_fog_reveal": int(data.get("MapFogReveal", 1)),
		# Mystery preview: blur the previewer's totals + flow until the player discovers nodes.
		"mystery_preview": bool(data.get("MysteryPreview", false)),
		"auto_advance_enabled": bool(data.get("AutoAdvanceEnabled", false)),
		"auto_advance_storyboard_secs": int(data.get("AutoAdvanceStoryboardSecs", 20)),
		"auto_advance_fork_secs":
		# Finish / "I came" button: author opt-in to end the run early, optionally into a designated
		int(data.get("AutoAdvanceForkSecs", data.get("AutoAdvanceSecs", 45))),
		# aftercare node (any type — a gentle round or a storyboard; off the main graph) before the end.
		"allow_finish": bool(data.get("AllowFinish", false)),
		"finish_node": str(data.get("FinishNode", "")),
		# Version stamps (absent on pre-0.6.0 journeys → blank, which always passes the gate).
		"min_version": str(data.get("MinVersion", "")),
		"created_with": str(data.get("CreatedWith", "")),
		# Stable journey id. Blank for journeys written before ids existed; the builder mints one
		# on the next save. Carried here so a re-save preserves it rather than re-minting.
		"journey_id": str(data.get("JourneyId", "")),
		# Soft edit-lock: true on a journey installed from a paid pack, so the buyer can't open it in the
		# builder. A courtesy lock (journey.json is plaintext) — see JourneySelect._on_edit_pressed.
		"locked": bool(data.get("Locked", false)),
		# Counter names the author chose to surface to the player (HUD pop + inventory list). The
		# runtime reads this off GameState.Journey; other counters stay hidden, gating only.
		"shown_counters": JourneyData.clean_flag_list(data.get("ShownCounters", [])),
		# Author-defined journey-scoped items — loaded into InventoryService at play and listed in the
		# builder's item dropdowns. Parsed to the runtime (snake-case) shape, image paths resolved.
		"items": _journey_items_resolved(data, path),
		# Storyboard cast — referenced by each storyboard line's `stage`. Each character carries its own
		# portraits (paths resolved) and placements (position/size boxes).
		"characters": _journey_characters_resolved(data, path),
		"settings": _journey_settings_resolved(data, path),
		"bgm": _journey_bgm_resolved(data, path),
		"bgm_volume": float(data.get("BgmVolume", JourneyData.DEFAULT_BGM_VOLUME)),
		"cover_path": find_cover_image(path),
		"modified_time": FileAccess.get_modified_time(path + "/journey.json"),
		"rounds": [],
		"forks": [],
		"shops": [],
		"storyboards": [],
	}


# Editor-only canvas annotations (sticky notes) — a journey-level overlay the runtime never reads.
static func _parse_comments(data: Dictionary) -> Array:
	var out: Array = []
	for c: Dictionary in data.get("Comments", []):
		var p: Array = c.get("Pos", [0, 0])
		var px: float = float(p[0]) if p.size() > 0 else 0.0
		var py: float = float(p[1]) if p.size() > 1 else 0.0
		var entry: Dictionary = {"pos": Vector2(px, py), "text": str(c.get("Text", ""))}
		var hex: String = str(c.get("Color", ""))
		if hex != "" and Color.html_is_valid(hex):
			entry["color"] = Color.html(hex)
		if str(c.get("NodeId", "")) != "":
			entry["node_id"] = str(c["NodeId"])
		out.append(entry)
	return out


# Editor-only group frames (labelled backdrop rectangles); the runtime never reads them.
static func _parse_groups(data: Dictionary) -> Array:
	var out: Array = []
	for g: Dictionary in data.get("Groups", []):
		var p: Array = g.get("Pos", [0, 0])
		var s: Array = g.get("Size", [360, 240])
		var px: float = float(p[0]) if p.size() > 0 else 0.0
		var py: float = float(p[1]) if p.size() > 1 else 0.0
		var sw: float = float(s[0]) if s.size() > 0 else 360.0
		var sh: float = float(s[1]) if s.size() > 1 else 240.0
		var entry: Dictionary = {"rect": Rect2(px, py, sw, sh), "label": str(g.get("Label", ""))}
		var hex: String = str(g.get("Color", ""))
		if hex != "" and Color.html_is_valid(hex):
			entry["color"] = Color.html(hex)
		if bool(g.get("Collapsed", false)):
			entry["collapsed"] = true
			entry["members"] = (g.get("Members", []) as Array).duplicate()
			entry["shift_ids"] = (g.get("ShiftIds", []) as Array).duplicate()
			entry["shift_amt"] = float(g.get("Shift", 0.0))
			entry["frame_shift_idxs"] = (g.get("FrameShiftIdxs", []) as Array).duplicate()
			entry["frame_shift_amt"] = float(g.get("FrameShift", 0.0))
		out.append(entry)
	return out


# Catalogue action/length totals for a graph journey. Phase-2 placeholder: sums EVERY
# round node (an overestimate vs. any single traversal). Phase 3 should swap this for the
# longest-by-length path once the catalogue reads the graph directly.
static func _graph_node_totals(graph: Dictionary) -> Dictionary:
	var actions: int = 0
	var length: int = 0
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		if n.get("type", "") != "round":
			continue
		var data: Dictionary = n.get("data", {})
		# A pool round has no funscript of its own — the runtime rolls one entry by weight — so it would
		# otherwise contribute 0. Count its weighted-AVERAGE entry instead, its expected length.
		if str(data.get("round_type", "normal")) == "pool":
			var pa: Dictionary = _pool_avg_totals(data.get("pool_entries", []))
			actions += int(pa["actions"])
			length += int(pa["length_ms"])
		else:
			actions += int(data.get("action_count", 0))
			length += int(data.get("length_ms", 0))
	return {"actions": actions, "length_ms": length}


# Weighted-average action count + length across a pool round's entries (the expected value, since the
# runtime rolls ONE by weight). Entries carry their own action_count / length_ms from save time.
static func _pool_avg_totals(entries: Array) -> Dictionary:
	var act_wsum: float = 0.0
	var len_wsum: float = 0.0
	var wtotal: float = 0.0
	for e: Dictionary in entries:
		var w: float = float(maxi(1, int(e.get("weight", 1))))
		var ms: int = int(e.get("length_ms", 0))
		var cnt: int = int(e.get("action_count", 0))
		# Pool entries don't store their stats in journey.json — read them from the funscript (already
		# resolved to an absolute path by from_json/resolve_paths before this runs).
		if ms <= 0:
			var st: Dictionary = JourneyData.read_funscript_stats(str(e.get("funscript_path", "")))
			ms = int(st.get("length_ms", 0))
			cnt = int(st.get("count", 0))
		act_wsum += cnt * w
		len_wsum += ms * w
		wtotal += w
	if wtotal <= 0.0:
		return {"actions": 0, "length_ms": 0}
	return {"actions": int(act_wsum / wtotal), "length_ms": int(len_wsum / wtotal)}


# Catalogue sequence for a Format-2 (graph) journey's detail modal — reconstructs an approximate
# nested tree (rounds / shops / storyboards / forks-with-paths) from the graph by walking from start,
# so the preview shows the real fork structure. Each fork's branches are walked up to their rejoin
# (the earliest node ≥2 branches reach), which becomes the post-fork continuation. graph→tree is
# lossy where branches share nodes, so this is best-effort: every node is placed exactly once.
static func _graph_catalogue_sequence(graph: Dictionary) -> Dictionary:
	var depth: Dictionary = _longest_depths(graph)
	var visited: Dictionary = {}
	var lists: Dictionary = _walk_level(graph, str(graph.get("start", "")), {}, visited, depth)
	# Defensive: append any node the walk never reached (a disconnected island) flat at the end so
	# nothing vanishes from the preview.
	var nodes: Dictionary = graph.get("nodes", {})
	var leftover: Array = nodes.keys()
	leftover.sort()
	var extra: int = 100000
	for id: String in leftover:
		if not visited.has(id):
			visited[id] = true
			_append_node(id, nodes[id], lists, extra)
			extra += 1
	return lists


# Builds one level's {rounds, shops, storyboards, forks} by walking the linear chain from `start_id`
# until it hits `stop`, an already-placed node, or the end. A fork recurses each branch (stopping at
# the fork's rejoin) and continues the level from that rejoin. order/after_order = position in the
# level, so _add_seq_to_list sorts the level back into walk order.
static func _walk_level(
	graph: Dictionary, start_id: String, stop: Dictionary, visited: Dictionary, depth: Dictionary
) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var lists: Dictionary = {"rounds": [], "shops": [], "storyboards": [], "forks": []}
	# `pos` indexes the next NUMBERED item (round / storyboard) in this level. Shops and forks are
	# between-item markers anchored to `pos - 1` (the preceding numbered item), so the renderer
	# (_add_seq_to_list) slots them just after it without consuming a number — round numbers stay
	# contiguous, matching the legacy nested preview.
	var pos: int = 0
	var id: String = start_id
	while id != "" and nodes.has(id) and not stop.has(id) and not visited.has(id):
		visited[id] = true
		var n: Dictionary = nodes[id]
		var out: Array = n.get("out", [])
		var ntype: String = str(n.get("type", ""))
		if ntype == "fork":
			var merge: String = _fork_merge(graph, id, stop, depth)
			var branch_stop: Dictionary = stop.duplicate()
			if merge != "":
				branch_stop[merge] = true
			var paths: Array = []
			for e: Dictionary in out:
				var branch: Dictionary = _walk_level(
					graph, str(e.get("to", "")), branch_stop, visited, depth
				)
				(
					paths
					. append(
						{
							"name": str(e.get("name", "")),
							"rounds": branch["rounds"],
							"shops": branch["shops"],
							"storyboards": branch["storyboards"],
							"forks": branch["forks"],
						}
					)
				)
			(lists["forks"] as Array).append(
				{
					"id": id,
					"title": (n.get("data", {}) as Dictionary).get("title", ""),
					"paths": paths,
					"after_order": pos - 1
				}
			)
			id = merge
		else:
			_append_node(id, n, lists, pos)
			if ntype == "round" or ntype == "storyboard":
				pos += 1
			id = str((out[0] as Dictionary).get("to", "")) if not out.is_empty() else ""
	return lists


# Appends a round / shop / storyboard node to a level's lists. `pos` is this numbered item's index:
# rounds/storyboards use it as their `order`; a shop (a between-item marker) anchors to `pos - 1` so
# it renders just after the preceding numbered item without consuming a number.
static func _append_node(node_id: String, n: Dictionary, lists: Dictionary, pos: int) -> void:
	var d: Dictionary = n.get("data", {})
	match str(n.get("type", "")):
		"round":
			# A pool round's own funscript is empty (the runtime rolls an entry) — show the weighted-average
			# entry so its per-round row reflects its expected length/actions instead of 0.
			var acts: int = int(d.get("action_count", 0))
			var ms: int = int(d.get("length_ms", 0))
			if str(d.get("round_type", "normal")) == "pool":
				var pa: Dictionary = _pool_avg_totals(d.get("pool_entries", []))
				acts = int(pa["actions"])
				ms = int(pa["length_ms"])
			(
				(lists["rounds"] as Array)
				. append(
					{
						"id": node_id,
						"name": d.get("name", ""),
						"round_type": d.get("round_type", "normal"),
						"coins": int(d.get("coins", 0)),
						"action_count": acts,
						"length_ms": ms,
						"order": pos,
					}
				)
			)
		"shop":
			(lists["shops"] as Array).append(
				{"id": node_id, "title": d.get("title", ""), "after_order": pos - 1}
			)
		"storyboard":
			(lists["storyboards"] as Array).append(
				{
					"id": node_id,
					"lines": d.get("lines", []),
					"coins": int(d.get("coins", 0)),
					"order": pos
				}
			)


# The rejoin node for a fork: the earliest (min longest-path depth) node reachable from ≥2 of the
# fork's branches and outside `stop`, or "" when the branches don't reconverge.
static func _fork_merge(
	graph: Dictionary, fork_id: String, stop: Dictionary, depth: Dictionary
) -> String:
	var out: Array = (graph["nodes"][fork_id] as Dictionary).get("out", [])
	var reach_count: Dictionary = {}
	for edge: Dictionary in out:
		for nid: String in _reachable(graph, str(edge.get("to", ""))):
			reach_count[nid] = int(reach_count.get(nid, 0)) + 1
	var best: String = ""
	var best_depth: int = 0x7fffffff
	for nid: String in reach_count:
		if int(reach_count[nid]) >= 2 and nid != fork_id and not stop.has(nid):
			var node_depth: int = int(depth.get(nid, 0))
			if node_depth < best_depth:
				best_depth = node_depth
				best = nid
	return best


# Forward-reachable node-id set from `from_id` (inclusive).
static func _reachable(graph: Dictionary, from_id: String) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var seen: Dictionary = {}
	var stack: Array = [from_id]
	while not stack.is_empty():
		var id: String = stack.pop_back()
		if id == "" or not nodes.has(id) or seen.has(id):
			continue
		seen[id] = true
		for edge: Dictionary in (nodes[id] as Dictionary).get("out", []):
			stack.append(str(edge.get("to", "")))
	return seen


# Longest-path depth from start per node (Kahn topological order); a node not reached defaults to 0.
static func _longest_depths(graph: Dictionary) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var indeg: Dictionary = {}
	var succ: Dictionary = {}
	for id: String in nodes:
		indeg[id] = 0
		succ[id] = []
	for id: String in nodes:
		for edge: Dictionary in (nodes[id] as Dictionary).get("out", []):
			var to: String = str(edge.get("to", ""))
			if to != "" and nodes.has(to):
				(succ[id] as Array).append(to)
				indeg[to] = int(indeg[to]) + 1
	var depth: Dictionary = {}
	var queue: Array = []
	for id: String in nodes:
		if int(indeg[id]) == 0:
			depth[id] = 0
			queue.append(id)
	var head: int = 0  # index of the next node to pop (queue is never shrunk, just walked)
	while head < queue.size():
		var cur: String = queue[head]
		head += 1
		for to: String in succ[cur] as Array:
			depth[to] = maxi(int(depth.get(to, 0)), int(depth[cur]) + 1)
			indeg[to] = int(indeg[to]) - 1
			if int(indeg[to]) == 0:
				queue.append(to)
	for id: String in nodes:
		if not depth.has(id):
			depth[id] = 0
	return depth


# Recursively parses a fork's JSON dict. Each path can contain nested forks
# in its "Forks" array.
static func parse_fork(raw_fork: Dictionary, journey_path: String) -> Dictionary:
	var fork_entry: Dictionary = {
		"after_order": raw_fork.get("AfterOrder", raw_fork.get("after_order", 0)),
		"node_id": raw_fork.get("NodeId", raw_fork.get("node_id", "")),
		"title": raw_fork.get("Title", raw_fork.get("title", "")),
		"description": raw_fork.get("Description", raw_fork.get("description", "")),
		# Fork resolution config (defaults keep legacy journeys as player-choice).
		"resolution": raw_fork.get("Resolution", raw_fork.get("resolution", "choice")),
		"cond_metric": raw_fork.get("CondMetric", raw_fork.get("cond_metric", "score")),
		"default_path": int(raw_fork.get("DefaultPath", raw_fork.get("default_path", 0))),
		"timeout_path": int(raw_fork.get("TimeoutPath", raw_fork.get("timeout_path", -1))),
		"paths": [],
	}
	var raw_paths: Array = raw_fork.get("Paths", raw_fork.get("paths", []))
	for raw_path: Dictionary in raw_paths:
		var img_file: String = raw_path.get("Image", raw_path.get("image", ""))
		var path_entry: Dictionary = {
			"name": raw_path.get("Name", raw_path.get("name", "Path")),
			"description": raw_path.get("Description", raw_path.get("description", "")),
			"image_path": (journey_path + "/" + img_file) if img_file != "" else "",
			"weight": int(raw_path.get("Weight", raw_path.get("weight", 1))),
			"threshold": int(raw_path.get("Threshold", raw_path.get("threshold", 0))),
			"required_item": raw_path.get("RequiredItem", raw_path.get("required_item", "")),
			"cost": int(raw_path.get("Cost", raw_path.get("cost", 0))),
			"rounds": [],
			"shops": [],
			"storyboards": [],
			"forks": [],
		}
		var raw_pr_rounds: Array = raw_path.get("Rounds", raw_path.get("rounds", []))
		for raw_pr: Dictionary in raw_pr_rounds:
			var pr_name: String = raw_pr.get("Name", raw_pr.get("name", "Round"))
			# Fall back to Name for pre-rXXX journeys; new journeys persist the
			# short folder slug in FolderName.
			var pr_slug: String = raw_pr.get("FolderName", raw_pr.get("folder_name", pr_name))
			var pr_folder: String = journey_path + "/" + pr_slug

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
			var pr_raw_video: String = raw_pr.get("VideoPath", raw_pr.get("video_path", ""))
			var pr_video_path: String = (
				(journey_path + "/" + pr_raw_video) if pr_raw_video != "" else ""
			)
			var pr_boss_image: String = raw_pr.get("BossImage", "")
			if pr_boss_image != "":
				pr_boss_image = journey_path + "/" + pr_boss_image
			var pr_boss_modifiers: Array = []
			for raw_mod in raw_pr.get("BossModifiers", []):
				if raw_mod is Dictionary:
					pr_boss_modifiers.append(_parse_boss_modifier(raw_mod))

			var pr_data: Dictionary = {
				"name": pr_name,
				"folder": pr_folder,
				"node_id": raw_pr.get("NodeId", raw_pr.get("node_id", "")),
				"video_path": pr_video_path,
				"funscript_path": pr_fs["path"],
				"axis_scripts": pr_axis_scripts,
				"vib_scripts": pr_vib_scripts,
				"is_checkpoint":
				bool(raw_pr.get("IsCheckpoint", raw_pr.get("is_checkpoint", false))),
				"boss_image": pr_boss_image,
				"boss_tagline": raw_pr.get("BossTagline", ""),
				"boss_modifiers": pr_boss_modifiers,
				"coins": raw_pr.get("CoinsAwarded", raw_pr.get("coins", 0)),
				"order": raw_pr.get("Order", raw_pr.get("order", 0)),
				"action_count": pr_fs["count"],
				"length_ms": pr_fs["length_ms"],
			}
			pr_data.merge(
				JourneyData.normalize_effect_round(_read_effect_fields(raw_pr, pr_round_type)), true
			)
			path_entry["rounds"].append(pr_data)
		var raw_pr_shops: Array = raw_path.get("Shops", raw_path.get("shops", []))
		for raw_ps in raw_pr_shops:
			if raw_ps is Dictionary:
				path_entry["shops"].append(_parse_shop(raw_ps))
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
				(
					psb_lines
					. append(
						{
							"speaker": raw_pl.get("Speaker", raw_pl.get("speaker", "")),
							"text": raw_pl.get("Text", raw_pl.get("text", "")),
							"image":
							(journey_path + "/" + pl_img_file) if pl_img_file != "" else "",
						}
					)
				)
			(
				path_entry["storyboards"]
				. append(
					{
						"order": raw_psb.get("Order", raw_psb.get("order", 0)),
						"node_id": raw_psb.get("NodeId", raw_psb.get("node_id", "")),
						"coins": raw_psb.get("CoinsAwarded", raw_psb.get("coins", 0)),
						"item": raw_psb.get("Item", raw_psb.get("item", "")),
						"image": (journey_path + "/" + psb_img_file) if psb_img_file != "" else "",
						"lines": psb_lines,
					}
				)
			)
		# Nested forks — recurse.
		var raw_pr_forks: Array = raw_path.get("Forks", raw_path.get("forks", []))
		for raw_nf in raw_pr_forks:
			if not raw_nf is Dictionary:
				continue
			path_entry["forks"].append(parse_fork(raw_nf, journey_path))
		fork_entry["paths"].append(path_entry)
	return fork_entry


# Parses a shop entry from journey.json (PascalCase) into the catalogue model.
# Accepts the legacy lowercase keys as a fallback so old journeys still load.
#   mode: "pool" — draw `count` random items from `items` (or all items if empty)
#         "fixed" — show exactly `items`
static func _parse_shop(raw: Dictionary) -> Dictionary:
	var items: Array = []
	for it in raw.get("Items", raw.get("items", [])):
		items.append(str(it))
	var guaranteed: Array = []
	for it in raw.get("Guaranteed", raw.get("guaranteed", [])):
		guaranteed.append(str(it))
	return {
		"after_order": raw.get("AfterOrder", raw.get("after_order", 0)),
		"node_id": raw.get("NodeId", raw.get("node_id", "")),
		"title": raw.get("Title", raw.get("title", "")),
		"mode": raw.get("Mode", raw.get("mode", "pool")),
		"count": int(raw.get("Count", raw.get("count", 3))),
		"items": items,
		"guaranteed": guaranteed,
		"price_multiplier": float(raw.get("PriceMultiplier", raw.get("price_multiplier", 1.0))),
	}


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


# Collects a round's effect-related fields from disk (both the generic "effect" schema and the
# retired cursed/blessed one, Pascal + lowercase) into a lowercase source dict for
# JourneyData.normalize_effect_round. `rtype` is the already-lowercased round_type; normalize
# keys off it to decide which schema to read.
static func _read_effect_fields(raw: Dictionary, rtype: String) -> Dictionary:
	return {
		"round_type": rtype,
		# Retired cursed/blessed schema.
		"curses": raw.get("Curses", raw.get("curses", [])),
		"curse_random": bool(raw.get("CurseRandom", raw.get("curse_random", true))),
		"curse_reward": int(raw.get("CurseReward", raw.get("curse_reward", 0))),
		"boons": raw.get("Boons", raw.get("boons", [])),
		"boon_random": bool(raw.get("BoonRandom", raw.get("boon_random", true))),
		# Generic effect schema.
		"effects": raw.get("Effects", raw.get("effects", [])),
		"effect_random": bool(raw.get("EffectRandom", raw.get("effect_random", true))),
		"resolvable": bool(raw.get("Resolvable", raw.get("resolvable", false))),
		"endure_reward": int(raw.get("EndureReward", raw.get("endure_reward", 0))),
		"frame_color": raw.get("FrameColor", raw.get("frame_color", "")),
		"card_accent": raw.get("CardAccent", raw.get("card_accent", "")),
		"card_header": raw.get("CardHeader", raw.get("card_header", "")),
		"card_icon": raw.get("CardIcon", raw.get("card_icon", "")),
		"show_border": bool(raw.get("ShowBorder", raw.get("show_border", false))),
		"effect_overrides": raw.get("EffectOverrides", raw.get("effect_overrides", {})),
		# Shared fields.
		"cleanse_cost": int(raw.get("CleanseCost", raw.get("cleanse_cost", 50))),
		"gift_item": raw.get("GiftItem", raw.get("gift_item", "")),
		"sensory": raw.get("Sensory", raw.get("BossHexes", raw.get("sensory", []))),
		"sensory_in_pool": bool(raw.get("SensoryInPool", raw.get("sensory_in_pool", false))),
		"sensory_intensity": raw.get("SensoryIntensity", raw.get("sensory_intensity", {})),
		"show_reveal": bool(raw.get("ShowReveal", raw.get("show_reveal", true))),
	}


# Returns {count, length_ms, round_count} for the longest path through a fork.
# "Longest" is determined by total length_ms; ties broken by action count.
# Recurses into nested forks within each path.
static func _longest_path_stats(fork: Dictionary) -> Dictionary:
	var best_count: int = 0
	var best_ms: int = 0
	var best_rounds: int = 0
	for path: Dictionary in fork.get("paths", []):
		var path_count: int = 0
		var path_ms: int = 0
		var path_rounds: int = (path.get("rounds", []) as Array).size()
		for r: Dictionary in path.get("rounds", []):
			path_count += (r.get("action_count", 0) as int)
			path_ms += (r.get("length_ms", 0) as int)
		for nested_fork: Dictionary in path.get("forks", []):
			var nested: Dictionary = _longest_path_stats(nested_fork)
			path_count += (nested["count"] as int)
			path_ms += (nested["length_ms"] as int)
			path_rounds += (nested["round_count"] as int)
		if path_ms > best_ms or (path_ms == best_ms and path_count > best_count):
			best_ms = path_ms
			best_count = path_count
			best_rounds = path_rounds
	return {"count": best_count, "length_ms": best_ms, "round_count": best_rounds}


# Finds the journey cover image. New journeys keep all images in a media/
# subfolder; old journeys stored the cover at the journey root.
static func find_cover_image(path: String) -> String:
	# A journey's cover is EXPLICIT: a file literally named cover.* (in media/, or at the journey root
	# for old journeys). No cover set → no cover. We deliberately do NOT fall back to "the first image
	# we find" — media/ also holds fork / storyboard / boss / portrait art, and borrowing one of those
	# as the cover is exactly the surprise we're removing.
	var media_cover: String = _find_named_image(path + "/media", "cover")
	if media_cover != "":
		return media_cover
	return _find_named_image(path, "cover")


# Resolves a journey's MapBackdrops meta into [{path, offset, scale, opacity}], each image made absolute
# against the journey's media/ folder. Skips entries with no image. Shared by the editor + the in-game map.
static func _parse_map_backdrops(raw: Array, path: String) -> Array:
	var out: Array = []
	for e: Variant in raw:
		var d: Dictionary = e
		var img: String = str(d.get("Image", ""))
		if img == "":
			continue
		(
			out
			. append(
				{
					"path": path + "/media/" + img,
					"offset": Vector2(float(d.get("X", 0.0)), float(d.get("Y", 0.0))),
					"scale": float(d.get("Scale", 1.0)),
					"opacity": float(d.get("Opacity", 0.6)),
					"rotation": float(d.get("Rot", 0.0)),
				}
			)
		)
	return out


# Returns the path to a file named <base_name>.<image-ext> in `dir_path`, or "" if there isn't one.
static func _find_named_image(dir_path: String, base_name: String) -> String:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if (
			not dir.current_is_dir()
			and fname.get_basename().to_lower() == base_name
			and fname.get_extension().to_lower() in IMAGE_EXTS
		):
			dir.list_dir_end()
			return dir_path + "/" + fname
		fname = dir.get_next()
	dir.list_dir_end()
	return ""


# Resolves a round's funscript stats as {count, length_ms, path}.
# Fast path: when journey.json carries cached ActionCount/LengthMs (written by
# JourneyBuilder at save time), no funscript is parsed at all. Otherwise it
# parses the file directly, or — for pre-cache journeys with no FunscriptPath —
# scans the round folder.
static func _resolve_round_stats(
	raw: Dictionary, base_path: String, scan_folder: String
) -> Dictionary:
	var explicit_rel: String = raw.get("FunscriptPath", raw.get("funscript_path", ""))
	if explicit_rel != "":
		var full_path: String = base_path + "/" + explicit_rel
		if raw.has("ActionCount") and raw.has("LengthMs"):
			return {
				"count": int(raw["ActionCount"]),
				"length_ms": int(raw["LengthMs"]),
				"path": full_path,
			}
		var stats: Dictionary = JourneyData.read_funscript_stats(full_path)
		stats["path"] = full_path if stats["count"] > 0 else ""
		return stats
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
				var stats: Dictionary = JourneyData.read_funscript_stats(full_path)
				stats["path"] = full_path
				return stats
		fname = dir.get_next()
	dir.list_dir_end()
	return {"count": 0, "length_ms": 0, "path": ""}
