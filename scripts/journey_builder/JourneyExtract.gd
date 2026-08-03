class_name JourneyExtract
extends RefCounted

## Pure "extract to rendition" (0.7.2, feature #3) — the inverse of JourneyCompose. Splits a selected set
## of nodes out of a base graph into a rendition OVERLAY: the base loses those nodes (its entry points turn
## back into anchors), and the rendition carries them as its new nodes plus the anchors that reattach them.
## No autoloads / IO — pure graph surgery, so the rules and their break-loudly failures are unit-testable.
## The caller (builder) moves the referenced media files and writes both journey.jsons.
##
## Entry edges (a KEPT base node u → a SELECTED node v) become anchors, and u is adjusted so the base plays
## cleanly on its own:
##   • u regular → u becomes an ENDING; the anchor is an ending-extend {anchor: u, edge: {to: v}}.
##   • u fork    → that choice is REMOVED from u; the anchor is an overlay choice {anchor: u, edge: {…the
##                 choice's full config}} that compose re-appends. The fork's default_path / timeout_path
##                 (indices into its choices) are remapped past the removed choices.
## Exit edges (selected → kept) stay on the rendition node — compose's merged graph has both ends. Internal
## edges (selected → selected) ride along inside the rendition unchanged.
##
## Returns {base: {start, nodes}, rendition: {nodes, anchors, slot_fills:[]}, errors: []}. `rendition` is the
## runtime delta shape JourneyRendition.coerce_rendition consumes; the caller stamps parent_id / name / author.


# Splits `selection` (node ids) out of `graph` ({start, nodes}). See the class note. A non-empty `errors`
# means the caller must refuse the extraction (nothing partial is returned in that case).
static func extract_rendition(graph: Dictionary, selection: Array) -> Dictionary:
	var nodes_in: Dictionary = graph.get("nodes", {})
	var start: String = str(graph.get("start", ""))
	var errors: Array = []

	# Validate the selection up front — a bad selection can't yield a coherent split.
	var sel: Dictionary = {}
	for raw: Variant in selection:
		var id: String = str(raw)
		if not nodes_in.has(id):
			errors.append({"kind": "missing_node", "id": id})
		else:
			sel[id] = true
	if sel.is_empty():
		errors.append({"kind": "empty_selection"})
	if sel.has(start):
		errors.append({"kind": "selects_start", "id": start})  # the journey's entry can't move to an overlay
	if not errors.is_empty():
		return _fail(errors)

	# Deep-copy every node, partitioned: kept nodes form the base, selected nodes form the rendition. The
	# selected nodes keep their out-edges verbatim (internal + exit edges), so the extracted structure and
	# its links back into the base survive intact.
	var base_nodes: Dictionary = {}
	var rend_nodes: Dictionary = {}
	for id: String in nodes_in:
		if sel.has(id):
			rend_nodes[id] = (nodes_in[id] as Dictionary).duplicate(true)
		else:
			base_nodes[id] = (nodes_in[id] as Dictionary).duplicate(true)

	# Entry edges (kept → selected) become anchors; the kept node is adjusted so it no longer dangles.
	var anchors: Array = []
	for u: String in base_nodes:
		var node: Dictionary = base_nodes[u]
		if str(node.get("type", "")) == "fork":
			_extract_fork_entries(u, node, sel, anchors, errors)
		else:
			_extract_regular_entry(u, node, sel, anchors)

	if anchors.is_empty():
		errors.append({"kind": "no_anchor"})  # nothing in the base reaches the selection — it can't attach
	if not errors.is_empty():
		return _fail(errors)

	return {
		"base": {"start": start, "nodes": base_nodes},
		"rendition": {"nodes": rend_nodes, "anchors": anchors, "slot_fills": []},
		"errors": [],
	}


# A regular node has at most one forward edge. If it points into the selection, drop it (the node becomes
# an ending) and record an ending-extend anchor that reattaches the selected node on compose.
static func _extract_regular_entry(
	u: String, node: Dictionary, sel: Dictionary, anchors: Array
) -> void:
	var kept: Array = []
	for e: Variant in node.get("out", []):
		var to: String = str((e as Dictionary).get("to", ""))
		if to != "" and sel.has(to):
			anchors.append({"anchor": u, "edge": {"to": to}})
		else:
			kept.append(e)
	node["out"] = kept


# A fork's choices that lead into the selection are removed and re-expressed as overlay-choice anchors (the
# choice's full config travels, so it composes back identically). Removing choices shifts the remaining
# indices, so the fork's default_path / timeout_path are remapped; dropping below 2 choices breaks loudly.
static func _extract_fork_entries(
	u: String, node: Dictionary, sel: Dictionary, anchors: Array, errors: Array
) -> void:
	var kept: Array = []
	var removed_idxs: Array = []
	var out: Array = node.get("out", [])
	for i: int in out.size():
		var e: Dictionary = out[i]
		if sel.has(str(e.get("to", ""))):
			anchors.append({"anchor": u, "edge": e.duplicate(true)})
			removed_idxs.append(i)
		else:
			kept.append(e)
	if removed_idxs.is_empty():
		return
	if kept.size() < 2:
		errors.append({"kind": "fork_underflow", "id": u})  # a fork needs ≥ 2 choices to remain valid
	node["out"] = kept
	_remap_fork_indices(node, removed_idxs)


# After choices are pulled out, the fork's index-valued config (default_path, timeout_path) must follow the
# survivors: an index that pointed at a removed choice resets to a safe default; a higher index decrements
# by however many removed choices sat below it. Negative sentinels (e.g. timeout_path -1 = random) are left.
static func _remap_fork_indices(node: Dictionary, removed_idxs: Array) -> void:
	var data: Dictionary = node.get("data", {})
	for key: String in ["default_path", "timeout_path"]:
		if not data.has(key):
			continue
		var idx: int = int(data[key])
		if idx < 0:
			continue
		if idx in removed_idxs:
			data[key] = 0 if key == "default_path" else -1
			continue
		var below: int = 0
		for r: Variant in removed_idxs:
			if int(r) < idx:
				below += 1
		data[key] = idx - below


static func _fail(errors: Array) -> Dictionary:
	return {"base": {}, "rendition": {}, "errors": errors}
