class_name RoundTemplates
extends RefCounted
## Named, reusable round definitions ("My 3-clip encounter", "Greed boss", …) so an author
## doesn't re-enter the same round from scratch — especially pool rounds with several
## entries. A template is the round's `data` blob (media paths + type config + pool_entries)
## minus node-level keys; applying one overwrites a round node's data while the graph keeps
## the node's id and edges. Persisted as a small JSON list; the list logic is pure (unit-
## tested), load/save wrap it with disk I/O — same shape as RandomizerPresets.
##
## Media paths inside a template are absolute source paths; applying + saving copies those
## files into the target journey's content/ pool (like any imported round). Within one
## journey (the common "reuse this definition" case) the paths point at the journey's own
## pooled files, so it just works; across journeys the source must still exist on disk.

const PATH: String = "user://round_templates.json"

# Node-level keys that must NOT ride along in a template: the id + edges belong to the graph
# node, and "type" is re-stamped on apply. (Pending segments are an editor-only op describing
# one specific clip, never part of a reusable definition — the legacy trim / section-loop keys
# they replaced are stripped too, so pre-segments templates stay clean on apply.)
const _STRIP_KEYS: Array = [
	"node_id",
	"type",
	"segments",
	"trim_start_ms",
	"trim_end_ms",
	"loop_in_ms",
	"loop_out_ms",
	"loop_count",
]

# ── Persistence ──────────────────────────────────────────────────────────────


static func load_all() -> Array:
	if not FileAccess.file_exists(PATH):
		return []
	var f: FileAccess = FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return []
	var parser := JSON.new()
	var ok: bool = parser.parse(f.get_as_text()) == OK
	f.close()
	if not ok or not (parser.data is Dictionary):
		return []
	var out: Array = []
	for t: Variant in (parser.data as Dictionary).get("templates", []):
		if t is Dictionary and str((t as Dictionary).get("name", "")) != "":
			(
				out
				. append(
					{
						"name": str((t as Dictionary)["name"]),
						"data": ((t as Dictionary).get("data", {}) as Dictionary).duplicate(true),
					}
				)
			)
	return out


static func save_all(templates: Array) -> bool:
	var f: FileAccess = FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_error("RoundTemplates: cannot write %s" % PATH)
		return false
	f.store_string(JSON.stringify({"version": 1, "templates": templates}, "\t"))
	f.close()
	return true


# Saves `round_data` under `name` (upsert), stripping node-level keys first.
static func add(name: String, round_data: Dictionary) -> void:
	if name.strip_edges() == "":
		return
	save_all(upsert(load_all(), name.strip_edges(), strip_for_template(round_data)))


static func remove(name: String) -> void:
	save_all(without(load_all(), name))


# The stored definition for `name`, deep-copied and ready to apply, or {} if absent.
static func get_data(name: String) -> Dictionary:
	for t: Dictionary in load_all():
		if str(t.get("name", "")) == name:
			return (t.get("data", {}) as Dictionary).duplicate(true)
	return {}


static func names() -> Array:
	var out: Array = []
	for t: Dictionary in load_all():
		out.append(str(t.get("name", "")))
	return out


# ── Pure logic (unit-tested) ──────────────────────────────────────────────────


# A deep copy of `round_data` with node-level keys removed — the form stored as a template.
static func strip_for_template(round_data: Dictionary) -> Dictionary:
	var out: Dictionary = round_data.duplicate(true)
	for k: String in _STRIP_KEYS:
		out.erase(k)
	return out


# Overlays `template_data` onto a round node's live `data` dict in place: clears the round's
# fields and copies the template's, then restores the node's own id (edges key off the graph
# node, not this, so wiring is unaffected) and re-stamps type "round". Mutates `data`.
static func apply_to(data: Dictionary, template_data: Dictionary) -> void:
	var keep_id: Variant = data.get("node_id", null)
	data.clear()
	data.merge(template_data.duplicate(true), true)
	data["type"] = "round"
	if keep_id != null:
		data["node_id"] = keep_id


# Replaces the template named `name` in place (preserving order), or appends if new.
static func upsert(templates: Array, name: String, data: Dictionary) -> Array:
	var out: Array = []
	var replaced: bool = false
	for t: Dictionary in templates:
		if str(t.get("name", "")) == name:
			out.append({"name": name, "data": data.duplicate(true)})
			replaced = true
		else:
			out.append(t)
	if not replaced:
		out.append({"name": name, "data": data.duplicate(true)})
	return out


static func without(templates: Array, name: String) -> Array:
	return templates.filter(func(t: Dictionary) -> bool: return str(t.get("name", "")) != name)
