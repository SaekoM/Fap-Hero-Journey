class_name JourneyCompose
extends RefCounted

## Pure renditions compose engine (0.7.2). A rendition is an OVERLAY: it never mutates its parent
## journey on disk — instead, at play time, this merges the parent graph and the rendition's delta into
## one in-memory graph. No autoloads, no file I/O — the JourneyData / ForkResolver pattern — so the merge
## rules and their break-loudly failures are unit-testable.
##
## PER-ORIGIN PATHS: a composed graph has nodes from two folders (the parent's content/ and the
## rendition's). This engine is path-AGNOSTIC — the caller resolves each source against its OWN base
## (JourneyGraph.resolve_paths(parent, parent_base); resolve the rendition delta against rendition_base)
## BEFORE composing. That per-source resolution is the fix for the old single-base resolve_paths, which
## couldn't express two origins.
##
## The rendition delta (runtime shape; the on-disk journey.json form is Slice 2's concern):
##   {
##     "parent_id": "j_…",            # which base this overlays (matched to an installed JourneyId by the loader)
##     "parent_min_version": "",       # reserved; the version gate needs a parent-revision scheme (later)
##     "nodes": { id: {type, data, out, pos?} },              # NEW nodes the rendition introduces
##     "anchors": [ {anchor: <existing node id>, edge: {to: <node id>, …}, slot?: <fork choice idx>} ],  # attach to the base
##     "slot_fills": [ {node: <id>, field: "video_path"|"axis_scripts"|…, channel?: "L0", path: "content/…"} ],
##   }
##
## Two overlay ops: anchors extend an ending / add a fork choice (an out-edge on an existing node);
## slot_fills populate an EMPTY slot (a round's video, main script, boss image, or an axis/vib channel) —
## how the free-video rendition and the paid multi-axis rendition attach without rewriting the parent.

# Scalar media slots on a round (a single path). CHANNEL slots are {channel: path} maps.
const SCALAR_SLOTS: Array[String] = ["video_path", "funscript_path", "boss_image"]
const CHANNEL_SLOTS: Array[String] = ["axis_scripts", "vib_scripts"]


# Merges `rendition` (a delta, see above) onto `parent` (a {start, nodes} graph), returning
# {graph, errors}. `parent` is NEVER mutated — the returned graph is a deep copy plus the overlay.
# `errors` is a list of {kind, …} break-loudly reports (empty = clean); the caller decides whether to
# refuse the compose or surface a warning. Both inputs are assumed already path-resolved per their own
# base (see the class note).
static func compose_graph(parent: Dictionary, rendition: Dictionary) -> Dictionary:
	var errors: Array = []
	var nodes: Dictionary = {}
	for id: String in parent.get("nodes", {}):
		nodes[id] = (parent["nodes"][id] as Dictionary).duplicate(true)  # deep copy — never touch the parent
	var merged: Dictionary = {"start": str(parent.get("start", "")), "nodes": nodes}

	_add_nodes(nodes, rendition.get("nodes", {}), errors)
	_apply_anchors(nodes, rendition.get("anchors", []), errors)
	_apply_slot_fills(nodes, rendition.get("slot_fills", []), errors)
	return {"graph": merged, "errors": errors}


# New nodes: ids must be disjoint from the parent (and each other). A collision breaks loudly rather than
# clobbering a parent node. (Authoring against the loaded parent makes collisions impossible in practice.)
static func _add_nodes(nodes: Dictionary, new_nodes: Dictionary, errors: Array) -> void:
	for id: String in new_nodes:
		if nodes.has(id):
			errors.append({"kind": "id_collision", "id": id})
			continue
		nodes[id] = (new_nodes[id] as Dictionary).duplicate(true)


# Anchor edges attach to an EXISTING node two ways:
#  • no `slot` → APPEND an out-edge: extend a terminal (a new chain past the old ending).
#  • `slot` ≥ 0 → FILL an OPEN fork choice IN PLACE (the base left choice[slot] blank as an extension
#    point). Never grows the fork; only the destination is set, so the base keeps that choice's label/art.
# Both the anchor node and the edge's target must exist post-merge; filling an already-set slot collides.
static func _apply_anchors(nodes: Dictionary, anchors: Array, errors: Array) -> void:
	for a: Dictionary in anchors:
		var anchor_id: String = str(a.get("anchor", ""))
		var edge: Dictionary = a.get("edge", {})
		if not nodes.has(anchor_id):
			errors.append({"kind": "missing_anchor", "id": anchor_id})
			continue
		var to_id: String = str(edge.get("to", ""))
		# An empty `to` is a valid fork choice that ENDS the run (base parity) — only a NON-empty target
		# that doesn't resolve is a broken edge.
		if to_id != "" and not nodes.has(to_id):
			errors.append({"kind": "missing_edge_target", "id": to_id})
			continue
		var node: Dictionary = nodes[anchor_id]
		if not node.has("out"):
			node["out"] = []
		var out: Array = node["out"]
		var slot: int = int(a.get("slot", -1))
		if slot < 0:
			out.append(edge.duplicate(true))
			continue
		if slot >= out.size():
			errors.append({"kind": "missing_slot_choice", "id": anchor_id, "slot": slot})
			continue
		var choice: Dictionary = out[slot]
		if str(choice.get("to", "")) != "":
			errors.append({"kind": "slot_collision", "node": anchor_id, "slot": slot})
			continue
		choice["to"] = to_id  # fill only the destination; the base owns this choice's label/image


# Slot fills: set a media path on an existing node — but only into an EMPTY slot. Filling an occupied
# slot is a collision (two layers claiming one slot) and breaks loudly rather than silently overwriting.
static func _apply_slot_fills(nodes: Dictionary, slot_fills: Array, errors: Array) -> void:
	for sf: Dictionary in slot_fills:
		var node_id: String = str(sf.get("node", ""))
		if not nodes.has(node_id):
			errors.append({"kind": "missing_slot_node", "id": node_id})
			continue
		var node: Dictionary = nodes[node_id]
		if not node.has("data"):
			node["data"] = {}
		var data: Dictionary = node["data"]
		var field: String = str(sf.get("field", ""))
		var path: String = str(sf.get("path", ""))

		if field in SCALAR_SLOTS:
			if str(data.get(field, "")) != "":
				errors.append({"kind": "slot_collision", "node": node_id, "field": field})
			else:
				data[field] = path
		elif field in CHANNEL_SLOTS:
			var channel: String = str(sf.get("channel", ""))
			if channel == "":
				errors.append({"kind": "missing_channel", "node": node_id, "field": field})
				continue
			var chans: Dictionary = data.get(field, {})
			if chans.has(channel) and str(chans[channel]) != "":
				errors.append(
					{"kind": "slot_collision", "node": node_id, "field": field, "channel": channel}
				)
			else:
				if not data.has(field):
					data[field] = {}
				(data[field] as Dictionary)[channel] = path
		else:
			errors.append({"kind": "unknown_slot_field", "field": field})
