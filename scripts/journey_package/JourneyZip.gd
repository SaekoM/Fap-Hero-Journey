class_name JourneyZip
extends RefCounted

## Reading plain ZIPs of a journey folder — how journeys were shared before `.fhj` packaging existed.
## Pure path logic only (no I/O, no autoloads), so the awkward part — deciding what inside an arbitrary
## archive is a journey, and which of its entries are safe to write — is unit-testable. `JourneyPackager`
## does the extracting.
##
## These archives have no manifest: they are somebody's journey folder, zipped. So the shape is
## discovered rather than declared — every `journey.json` in the archive marks a journey, and the folder
## it sits in is that journey's root. That forgives the three ways people actually zip a folder (flat,
## wrapped in one top folder, or buried deeper) without asking them to repack.

const JOURNEY_FILE: String = "journey.json"

## Archives at or above this warn before extracting. Godot's ZIPReader reads an entry whole into memory
## (there is no streaming API and no ZIP64), which is the very limitation `.fhj` exists to escape — so a
## big archive may fail on RAM. The archive's own size is a proxy: the reader cannot report entry sizes
## without reading them, and reading them is the thing we are trying to be careful about.
const LARGE_ARCHIVE_BYTES: int = 1024 * 1024 * 1024  # 1 GiB


# The root prefix of every journey in the archive — "" for one zipped flat, "My Journey/" for one
# wrapped in its folder, deeper for anything else. Sorted shallowest-first so the outermost journey of a
# nested pair is offered first, and deduped.
#
# A journey.json inside another journey's root is NOT a second journey: pooled content never contains
# one, so it is either a stray backup copy or a nesting nobody meant. Taking the outer one and ignoring
# what is beneath it is the reading that matches how these archives get made.
static func find_roots(files: PackedStringArray) -> Array:
	var roots: Array = []
	for f: String in files:
		var norm: String = f.replace("\\", "/")
		if not norm.ends_with(JOURNEY_FILE):
			continue
		var root: String = norm.substr(0, norm.length() - JOURNEY_FILE.length())
		if root != "" and not root.ends_with("/"):
			continue  # a file merely NAMED like it, e.g. "old_journey.json"
		if not roots.has(root):
			roots.append(root)
	roots.sort_custom(
		func(a: String, b: String) -> bool:
			var da: int = a.count("/")
			var db: int = b.count("/")
			return da < db if da != db else a < b
	)
	var outer: Array = []
	for r: String in roots:
		var nested: bool = false
		for o: String in outer:
			if r != o and r.begins_with(o):
				nested = true
				break
		if not nested:
			outer.append(r)
	return outer


# The archive entries belonging to `root`, as {zip_path, rel} — `rel` being where the entry lands inside
# the installed journey folder. Directory entries and anything unsafe are dropped.
static func entries_under(files: PackedStringArray, root: String) -> Array:
	var out: Array = []
	for f: String in files:
		var norm: String = f.replace("\\", "/")
		if not norm.begins_with(root) or norm.ends_with("/"):
			continue
		var rel: String = safe_rel(norm.substr(root.length()))
		if rel == "":
			continue
		out.append({"zip_path": f, "rel": rel})
	return out


# An archive-relative path made safe to write, or "" when it isn't.
#
# An archive is untrusted input: an entry named `../../config.cfg` or `C:/Windows/x.dll` would write
# outside the journey folder if joined naively (the "zip slip" bug). Rather than sanitising such a path
# into something plausible, refuse it — a journey has no reason to carry one, so the only archives this
# rejects are the ones that should be.
static func safe_rel(rel: String) -> String:
	var p: String = rel.replace("\\", "/").strip_edges()
	while p.begins_with("/"):
		p = p.substr(1)
	if p == "" or p.begins_with("~"):
		return ""
	if p.contains(":"):
		return ""  # drive letter or scheme — never relative
	for part: String in p.split("/"):
		if part == ".." or part == "." or part.strip_edges() == "":
			return ""
	return p


# True when this looks like a journey archive at all — used to tell "not a journey zip" from "a journey
# zip that failed", so the message can say which.
static func is_journey_archive(files: PackedStringArray) -> bool:
	return not find_roots(files).is_empty()
