class_name RoundTemplates
extends RefCounted
## Named, reusable round SETUPS ("Temptation", "Greed boss", …) so an author doesn't re-enter
## the same effects, modifiers, rewards, cards and type config on every round. A template is the
## round's `data` blob minus its node-level keys and minus its CONTENT — the clip (video, scripts,
## pending cuts), a pool's entry list, and the round's own name. Applying one replaces the target's
## setup and leaves its content exactly as it was, whether or not the round has any yet; the graph
## keeps the node's id and edges. Persisted as a small JSON list; the list logic is pure (unit-
## tested), load/save wrap it with disk I/O — same shape as RandomizerPresets.
##
## Templates used to carry the clip too, and applying one silently replaced a round's video and
## funscript — the opposite of what they were being used for ("this round's video, with the
## Temptation setup"). Authored ART (boss image, cards) is part of the look and does come across;
## those are the only paths a template holds, and saving pools them like any imported image.

const PATH: String = "user://round_templates.json"

# The round's CONTENT: what it plays and what it's called. Never stored in a template and never
# touched by applying one. The clip and everything derived from it (folder, length, action count),
# the pending cuts to THAT clip (and the legacy trim / section-loop keys they replaced), a pool's
# entry list, and the name the author gave the round.
const CONTENT_KEYS: Array = [
	"name",
	"video_path",
	"funscript_path",
	"axis_scripts",
	"vib_scripts",
	"folder",
	"length_ms",
	"actions",
	"pool_entries",
	"segments",
	"trim_start_ms",
	"trim_end_ms",
	"loop_in_ms",
	"loop_out_ms",
	"loop_count",
]
# Node-level keys that must NOT ride along either: the id + edges belong to the graph node, and
# "type" is re-stamped on apply.
const _NODE_KEYS: Array = ["node_id", "type"]

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


# A deep copy of `round_data` with node-level and content keys removed — the form stored as a
# template.
static func strip_for_template(round_data: Dictionary) -> Dictionary:
	var out: Dictionary = round_data.duplicate(true)
	for k: String in _NODE_KEYS + CONTENT_KEYS:
		out.erase(k)
	return out


# Replaces a round node's SETUP with `template_data`'s, in place: every non-content field is cleared
# and the template's copied, while the node's id (edges key off the graph node, not this, so wiring
# is unaffected) and its CONTENT_KEYS survive untouched. Type is re-stamped "round". Content keys
# in the template itself (one saved before content was excluded) are ignored. Mutates `data`.
#
# `round_type` is configuration — a "Temptation" template makes the round an effect round — except
# that "pool" names content (a list of clips), not behaviour: a pool target stays a pool, and a pool
# template can't turn a round into one, because the entries it would need don't come across.
static func apply_to(data: Dictionary, template_data: Dictionary) -> void:
	var kept: Dictionary = {}
	for k: String in ["node_id"] + CONTENT_KEYS:
		if data.has(k):
			kept[k] = data[k]
	var target_type: String = str(data.get("round_type", "normal"))
	var template_type: String = str(template_data.get("round_type", "normal"))
	data.clear()
	data.merge(template_data.duplicate(true), true)
	for k: String in CONTENT_KEYS:
		data.erase(k)
	data.merge(kept, true)
	if target_type == "pool" or template_type == "pool":
		data["round_type"] = target_type
	data["type"] = "round"


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
