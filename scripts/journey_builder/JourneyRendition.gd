class_name JourneyRendition
extends RefCounted

## Rendition data model (0.7.2): the on-disk journey.json shape for an OVERLAY, and the two conversions
## around it — coerce (authoring model → journey.json) and parse (journey.json → the runtime delta that
## JourneyCompose.compose_graph consumes). Pure, no autoloads/IO — the JourneyData pattern.
##
## A rendition folder looks like any journey folder (journey.json + content/ + media/), but its
## journey.json is marked `Type: "rendition"` and carries the DELTA instead of a full playable graph:
##   {
##     "Type": "rendition", "JourneyId": "j_…" (the rendition's OWN id),
##     "ParentId": "j_…", "ParentMinVersion": "",   # which base it overlays
##     "Name", "Author", "Description", + the usual identity stamps,
##     "Format": 2, "Start": "", "Nodes": [ …new nodes… ],   # reuses the journey Nodes format
##     "Anchors": [ {"Anchor": <existing node id>, "Edge": {to, …}, "Slot"?: <fork choice idx>} ],
##     "SlotFills": [ {"Node", "Field", "Channel"?, "Path"} ],
##     "AftercareLinks": [ {"Node": <existing round id>, "To": <node id>, "Text"?: <hold text>} ],
##     "Settings": [ …the rendition's OWN places… ], "Characters": [ …its OWN cast… ],
##     "Counters": [ …its OWN declared counters… ], "Flags": [ …its OWN declared flags… ],
##     "Items": [ …its OWN custom items… ],
##     "ItemImages": [ {"Item": <a base item id>, "Path"} ],   # art for a base item that has none
##   }
## Envelope keys are PascalCase (journey.json convention); node data + out-edges stay lowercase, exactly
## as a normal journey stores them — so Anchors' `Edge` is a plain out-edge dict.
##
## Items are additive too (0.9.2), and a rendition may also give a base item that has NO image one of
## its own (ItemImages) — filling a gap, never replacing art the base chose, the same rule as SlotFills.
## Settings, Characters, Counters and Flags are ADDITIVE (0.8.6): a rendition brings its own places,
## people, counters and flags, pooled
## in its own folder, and the composed journey is the base's list followed by each rendition's, first
## id wins (JourneyData.merge_by_id). A rendition never edits or removes the base's — the same contract
## as nodes — so it can be discarded, merged or stacked without the base changing underneath another
## rendition. The builder writes three more editor-only overlay keys beside this envelope, parsed by
## the scanner rather than here: MapBackdrops, Comments and Groups (its own map art, notes and frames).

const RENDITION_TYPE: String = "rendition"


# True when a parsed journey.json is a rendition overlay rather than a full journey. Lets the scanner
# and loader route the two differently.
static func is_rendition(data: Dictionary) -> bool:
	return str(data.get("Type", "")) == RENDITION_TYPE


# journey.json dict → the runtime delta for JourneyCompose. Reuses JourneyGraph.from_json for the Nodes
# block (id-keyed {type, data, out}); paths stay as stored (the loader resolves them against the
# rendition's own base before composing).
static func parse_rendition(data: Dictionary) -> Dictionary:
	var graph: Dictionary = JourneyGraph.from_json(data)  # {start, nodes} — we only want the new nodes
	return {
		"journey_id": str(data.get("JourneyId", "")),
		"name": str(data.get("Name", "")),
		"author": str(data.get("Author", "")),
		"description": str(data.get("Description", "")),
		"parent_id": str(data.get("ParentId", "")),
		"parent_min_version": str(data.get("ParentMinVersion", "")),
		"nodes": graph["nodes"],
		"anchors": _parse_anchors(data.get("Anchors", [])),
		"slot_fills": _parse_slot_fills(data.get("SlotFills", [])),
		"aftercare_links": _parse_aftercare_links(data.get("AftercareLinks", [])),
		"settings": JourneyData.parse_journey_settings(data.get("Settings", [])),
		"counters": JourneyData.parse_counter_defs(data.get("Counters", [])),
		"flags": JourneyData.parse_flag_defs(data.get("Flags", [])),
		"characters": JourneyData.parse_journey_characters(data.get("Characters", [])),
		"items": JourneyData.parse_journey_items(data.get("Items", [])),
		"minigames": MiniGameLibrary.parse_library(data.get("MiniGames", [])),
		"item_images": _parse_item_images(data.get("ItemImages", [])),
	}


# Authoring/runtime rendition → journey.json dict (PascalCase envelope). Reuses JourneyGraph.to_json for
# the Nodes block and stamps the rendition's OWN identity (its JourneyId, distinct from ParentId), so a
# rendition is itself dedupe-able and distributable.
#   rendition: {journey_id?, name, author, description, parent_id, parent_min_version,
#               nodes:{id:node}, anchors:[{anchor, edge}], slot_fills:[{node, field, channel, path}],
#               aftercare_links?:[{node, to}],
#               settings?:[…runtime settings…], characters?:[…runtime characters…]}
static func coerce_rendition(rendition: Dictionary) -> Dictionary:
	var node_block: Dictionary = JourneyGraph.to_json(
		{"start": "", "nodes": rendition.get("nodes", {})}
	)
	var out: Dictionary = {
		"Type": RENDITION_TYPE,
		"Name": str(rendition.get("name", "")),
		"Author": str(rendition.get("author", "")),
		"Description": str(rendition.get("description", "")),
		"ParentId": str(rendition.get("parent_id", "")),
		"ParentMinVersion": str(rendition.get("parent_min_version", "")),
		"Format": node_block["Format"],
		"Start": "",
		"Nodes": node_block["Nodes"],
		"Anchors": _coerce_anchors(rendition.get("anchors", [])),
		"SlotFills": _coerce_slot_fills(rendition.get("slot_fills", [])),
		"AftercareLinks": _coerce_aftercare_links(rendition.get("aftercare_links", [])),
		"Settings": JourneyData.coerce_journey_settings(rendition.get("settings", [])),
		"Counters": JourneyData.coerce_counter_defs(rendition.get("counters", [])),
		"Flags": JourneyData.coerce_flag_defs(rendition.get("flags", [])),
		"Characters": JourneyData.coerce_journey_characters(rendition.get("characters", [])),
		"Items": JourneyData.coerce_journey_items(rendition.get("items", [])),
		"MiniGames": MiniGameLibrary.parse_library(rendition.get("minigames", [])),
		"ItemImages": _coerce_item_images(rendition.get("item_images", [])),
	}
	# A rendition that places a mini-game needs the build that plays them, like a base journey does.
	var places_minigames: bool = JourneyData.graph_has_minigames(
		{"nodes": rendition.get("nodes", {})}
	)
	JourneyData.stamp_journey_identity(
		out,
		str(rendition.get("journey_id", "")),
		JourneyData.content_min_version(
			false,
			places_minigames,
			JourneyData.graph_needs_newer_build(
				{"nodes": rendition.get("nodes", {})}, out["MiniGames"]
			)
		)
	)
	return out


# Resolves a parsed delta's relative media paths to absolute, against the RENDITION's OWN base folder —
# its new nodes' media, any anchor-edge (fork choice) images, the slot-fill script/video paths, and its
# own settings' backgrounds / music and characters' portraits. This is the per-origin half of the
# two-origin resolution: the base graph is resolved against ITS folder separately, and only then are
# the two composed. Mutates `delta` in place.
static func resolve_delta_paths(delta: Dictionary, base: String) -> void:
	JourneyGraph.resolve_paths({"start": "", "nodes": delta.get("nodes", {})}, base)
	for a: Variant in delta.get("anchors", []):
		if a is Dictionary:
			var edge: Variant = (a as Dictionary).get("edge", {})
			if edge is Dictionary and str((edge as Dictionary).get("image_path", "")) != "":
				var ed: Dictionary = edge
				ed["image_path"] = base + "/" + str(ed["image_path"])
	for sf: Variant in delta.get("slot_fills", []):
		if sf is Dictionary and str((sf as Dictionary).get("path", "")) != "":
			var f: Dictionary = sf
			f["path"] = base + "/" + str(f["path"])
	for s: Variant in delta.get("settings", []):
		if not (s is Dictionary):
			continue
		for bg: Variant in (s as Dictionary).get("backgrounds", []):
			if bg is Dictionary:
				(bg as Dictionary)["path"] = _resolved_media(
					str((bg as Dictionary).get("path", "")), base
				)
		(s as Dictionary)["bgm"] = _resolved_media(str((s as Dictionary).get("bgm", "")), base)
	for c: Variant in delta.get("characters", []):
		if not (c is Dictionary):
			continue
		for por: Variant in (c as Dictionary).get("portraits", []):
			if por is Dictionary:
				(por as Dictionary)["path"] = _resolved_media(
					str((por as Dictionary).get("path", "")), base
				)
	for it: Variant in delta.get("items", []):
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		item["image"] = _resolved_media(str(item.get("image", "")), base)
		if item.get("scripts", null) is Dictionary:
			var scripts: Dictionary = item["scripts"]
			scripts["main"] = _resolved_media(str(scripts.get("main", "")), base)
			for group: String in ["axes", "vibes"]:
				if scripts.get(group, null) is Dictionary:
					var channels: Dictionary = scripts[group]
					for channel: Variant in channels:
						channels[channel] = _resolved_media(str(channels[channel]), base)
	for fill: Variant in delta.get("item_images", []):
		if fill is Dictionary:
			(fill as Dictionary)["path"] = _resolved_media(
				str((fill as Dictionary).get("path", "")), base
			)


# A pooled relative path made absolute against the rendition folder; blank stays blank and an
# already-absolute or engine path is left alone (JourneyScanner._resolved_media's rule).
static func _resolved_media(path: String, base: String) -> String:
	if path == "":
		return ""
	if path.begins_with("res://") or path.begins_with("user://") or path.is_absolute_path():
		return path
	return base.path_join(path)


# Part-1 → Part-2 resume (feature #5): the rendition entry node a completed base run jumps INTO, given the
# ending the player finished on (`reached_node`). It's the `to` of an ending-extend anchor attached to that
# exact ending, or "" when this rendition doesn't extend that ending (so no resume is offered). Slot-fill
# anchors (a fork's reserved choice) aren't endings, so they never match a reached terminal. `anchors` is a
# parsed delta's anchor list ([{anchor, edge:{to}, slot?}]).
static func resume_entry(anchors: Array, reached_node: String) -> String:
	if reached_node == "":
		return ""
	for a: Variant in anchors:
		if not (a is Dictionary) or str((a as Dictionary).get("anchor", "")) != reached_node:
			continue
		if (a as Dictionary).has("slot"):
			continue  # a fork slot-fill isn't an ending continuation
		var edge: Variant = (a as Dictionary).get("edge", {})
		if edge is Dictionary and str((edge as Dictionary).get("to", "")) != "":
			return str((edge as Dictionary).get("to", ""))
	return ""


# ── Anchors / slot-fills (envelope PascalCase ↔ runtime snake_case) ──────────


static func _parse_anchors(raw: Array) -> Array:
	var out: Array = []
	for a: Variant in raw:
		if a is Dictionary:
			var d: Dictionary = a
			var rec: Dictionary = {"anchor": str(d.get("Anchor", "")), "edge": d.get("Edge", {})}
			if d.has("Slot"):  # fork open-slot fill — the base choice index it populates
				rec["slot"] = int(d["Slot"])
			out.append(rec)
	return out


static func _coerce_anchors(anchors: Array) -> Array:
	var out: Array = []
	for a: Variant in anchors:
		if a is Dictionary:
			var d: Dictionary = a
			var rec: Dictionary = {"Anchor": str(d.get("anchor", "")), "Edge": d.get("edge", {})}
			if d.has("slot"):
				rec["Slot"] = int(d["slot"])
			out.append(rec)
	return out


# Gives each base item named in `fills` ([{item, path}]) that image — but only an item that has none,
# and only the first fill for it, the way SlotFills treat a slot. Mutates `items` in place.
static func apply_item_images(items: Array, fills: Array) -> void:
	for fill: Variant in fills:
		if not (fill is Dictionary):
			continue
		var item_id: String = str((fill as Dictionary).get("item", ""))
		var path: String = str((fill as Dictionary).get("path", ""))
		if item_id == "" or path == "":
			continue
		for it: Variant in items:
			if it is Dictionary and str((it as Dictionary).get("id", "")) == item_id:
				if str((it as Dictionary).get("image", "")) == "":
					(it as Dictionary)["image"] = path
				break


static func _parse_item_images(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for f: Variant in raw:
		if f is Dictionary:
			var item_id: String = str((f as Dictionary).get("Item", ""))
			var path: String = str((f as Dictionary).get("Path", ""))
			if item_id != "" and path != "":
				out.append({"item": item_id, "path": path})
	return out


static func _coerce_item_images(fills: Array) -> Array:
	var out: Array = []
	for f: Variant in fills:
		if f is Dictionary:
			var item_id: String = str((f as Dictionary).get("item", ""))
			var path: String = str((f as Dictionary).get("path", ""))
			if item_id != "" and path != "":
				out.append({"Item": item_id, "Path": path})
	return out


static func _parse_slot_fills(raw: Array) -> Array:
	var out: Array = []
	for s: Variant in raw:
		if s is Dictionary:
			var sf: Dictionary = s
			(
				out
				. append(
					{
						"node": str(sf.get("Node", "")),
						"field": str(sf.get("Field", "")),
						"channel": str(sf.get("Channel", "")),
						"path": str(sf.get("Path", "")),
					}
				)
			)
	return out


static func _coerce_slot_fills(slot_fills: Array) -> Array:
	var out: Array = []
	for s: Variant in slot_fills:
		if s is Dictionary:
			var sf: Dictionary = s
			(
				out
				. append(
					{
						"Node": str(sf.get("node", "")),
						"Field": str(sf.get("field", "")),
						"Channel": str(sf.get("channel", "")),
						"Path": str(sf.get("path", "")),
					}
				)
			)
	return out


static func _parse_aftercare_links(raw: Array) -> Array:
	var out: Array = []
	for l: Variant in raw:
		if l is Dictionary:
			var d: Dictionary = l
			(
				out
				. append(
					{
						"node": str(d.get("Node", "")),
						"to": str(d.get("To", "")),
						"text": str(d.get("Text", "")),
					}
				)
			)
	return out


static func _coerce_aftercare_links(links: Array) -> Array:
	var out: Array = []
	for l: Variant in links:
		if l is Dictionary:
			var d: Dictionary = l
			var rec: Dictionary = {"Node": str(d.get("node", "")), "To": str(d.get("to", ""))}
			if str(d.get("text", "")) != "":
				rec["Text"] = str(d["text"])
			out.append(rec)
	return out
