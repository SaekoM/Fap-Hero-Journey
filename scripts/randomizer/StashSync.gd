class_name StashSync
extends RefCounted
## The decisions SYNC makes about the randomizer's Stash clips (STASH_DESIGN.md), kept pure so they
## can be tested without a Stash: which tags a clip keeps, whether a clip needs importing again, and
## which clips to flag. RandomizerScreen does the requests and the importing.

# Why a clip's scene wasn't found (a library entry's `stash_flag`).
const FLAG_GONE: String = "gone"  # deleted from Stash, or no longer interactive
const FLAG_UNMATCHED: String = "unmatched"  # still in Stash, but outside the tags imported


# A clip's tags after Stash's change from `old_stash_tags` to `new_stash_tags`: a tag Stash dropped
# comes off, a tag Stash added goes on, and every other tag (the player's own) stays where it was.
static func merged_tags(tags: Array, old_stash_tags: Array, new_stash_tags: Array) -> Array:
	var old_stash: Array = RandomizerLibrary.normalize_tags(old_stash_tags)
	var new_stash: Array = RandomizerLibrary.normalize_tags(new_stash_tags)
	var merged: Array = []
	for tag: Variant in RandomizerLibrary.normalize_tags(tags):
		if not old_stash.has(tag) or new_stash.has(tag):
			merged.append(tag)
	for tag: Variant in new_stash:
		if not merged.has(tag):
			merged.append(tag)
	return merged


# Whether a clip already in the library has to be imported again rather than just retagged: its file
# moved (`local_path`), its content changed in Stash (`fingerprint`), or the scripts beside it changed
# (`siblings`, from ImportScanner.find_sibling_scripts). Re-importing means an ffprobe per clip over the
# network, so a SYNC that finds nothing changed should do none.
static func needs_reimport(
	entry: Dictionary, local_path: String, fingerprint: String, siblings: Dictionary
) -> bool:
	if str(entry.get("video_src", "")) != local_path:
		return true
	var known: String = str((entry.get("stash", {}) as Dictionary).get("fingerprint", ""))
	if fingerprint != "" and known != fingerprint:
		return true
	if str(entry.get("funscript_src", "")) != str(siblings.get("funscript", "")):
		return true
	var axes: Dictionary = entry.get("axis_src", {})
	var vibes: Dictionary = entry.get("vib_src", {})
	return (
		not axes.recursive_equal(siblings.get("axis", {}), 1)
		or not vibes.recursive_equal(siblings.get("vib", {}), 1)
	)


# The flag each linked scene gets after a SYNC, {scene_id: "" | FLAG_*}. `matched` holds the scenes
# SYNC fetched (interactive, under the tag filter); `still_present` the ones Stash still has as
# interactive scenes whatever their tags, which SYNC only needs to ask about when a tag filter is set.
static func flags(
	linked_scene_ids: Array, matched: Dictionary, still_present: Dictionary
) -> Dictionary:
	var out: Dictionary = {}
	for scene_id: Variant in linked_scene_ids:
		var id: String = str(scene_id)
		if matched.has(id):
			out[id] = ""
		elif still_present.has(id):
			out[id] = FLAG_UNMATCHED
		else:
			out[id] = FLAG_GONE
	return out


# What a flag means, for a row's badge.
static func flag_text(flag: String) -> String:
	match flag:
		FLAG_GONE:
			return "⚠ Gone from Stash. Generate skips it."
		FLAG_UNMATCHED:
			return "⚠ No longer has the Stash tags you import. Generate skips it."
	return ""
