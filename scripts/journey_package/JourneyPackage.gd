class_name JourneyPackage
extends RefCounted

## Pure model for the .fhj distribution package (0.7.1 packaging & distribution). No autoloads, no
## node/UI state — the JourneyData / ForkResolver pattern — so every decision here is unit-testable.
## The I/O driver that zips/unzips and installs lives in JourneyPackager; this file owns the manifest
## shape, the per-asset free/paid routing, the slot id, and the portable content hash.
##
## An .fhj is a flat zip: manifest.json (root) + journey.json + the pooled media (content/ + media/).
## See STATE.md "## Packaging & distribution — design" for the multi-release picture.

# Bumped only on a breaking manifest change. parse_manifest refuses a package stamped NEWER than this
# (an older app can't be trusted to read it), so the field is the format's own version gate — distinct
# from a journey's MinVersion, which gates the CONTENT against the app.
const PACKAGE_FORMAT: int = 1

# Per-asset role → which pack half it belongs in. "scene" (the round footage) and "cover" ride the
# FREE pack — the community's "video is free" norm, plus a cover a buyer must see before purchase.
# Everything the author made (scripts, presentation art, audio) defaults to the PAID pack.
const FREE_ROLES: Array[String] = ["scene", "cover"]

# Asset roles, assigned by how journey.json REFERENCES a file — never by its extension or folder, so a
# baked-animation boss image (an .mp4 in content/) is classed "image", not "scene". That distinction is
# the whole reason routing walks the graph instead of listing the content/ folder.
const ROLE_SCENE: String = "scene"
const ROLE_FUNSCRIPT: String = "funscript"
const ROLE_AXIS: String = "axis"
const ROLE_VIBE: String = "vibe"
const ROLE_IMAGE: String = "image"
const ROLE_AUDIO: String = "audio"
const ROLE_COVER: String = "cover"

# ── Slot id ──────────────────────────────────────────────────────────────────


# The pooled content path (content/<name>__<fp>.<ext>) doubles as a stable slot id — it's identical
# across the author's script pack and a matching video pack, which is what makes recombination a
# deterministic slot-for-slot merge (no fuzzy matching). Non-pooled paths have no slot.
static func slot_id_for(rel: String) -> String:
	return rel if JourneyData.is_pooled_content_path(rel) else ""


# ── Portable content hash ─────────────────────────────────────────────────────

# A MACHINE-INDEPENDENT id for a video's bytes: sha256(first 8 MB + last 8 MB + exact size). Robust to
# path/mtime (unlike JourneyData.media_fingerprint, which is deliberately machine-local and left
# untouched), collision-safe for distinct clips, and cheap — it never reads the whole file. Used by
# 0.7.2 lean re-link + video-identity pinning; computed here now so the format is complete on day one.
const HASH_CHUNK: int = 8 * 1024 * 1024


static func portable_hash(abs_path: String) -> String:
	var f: FileAccess = FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return ""
	var size: int = f.get_length()
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if size <= HASH_CHUNK * 2:
		ctx.update(f.get_buffer(size))  # small file: the ends overlap, so hash it whole
	else:
		f.seek(0)
		ctx.update(f.get_buffer(HASH_CHUNK))
		f.seek(size - HASH_CHUNK)
		ctx.update(f.get_buffer(HASH_CHUNK))
	ctx.update(("|%d" % size).to_utf8_buffer())  # size guards against two files sharing both ends
	f.close()
	return ctx.finish().hex_encode()


# ── Manifest ───────────────────────────────────────────────────────────────────


# Builds the manifest.json dict (PascalCase, mirroring journey.json's meta convention). `journey_data`
# is the parsed journey.json; `assets` is enumerate_assets' output ([{rel, role, pack}]); `cover_rel`
# is the on-disk cover path ("" when the journey has none — cover isn't stored in journey.json).
# `Type`/`ParentId`/etc. rendition fields are reserved for 0.7.2 and deliberately absent (or default)
# here so adding them later needs no format bump.
static func build_manifest(
	journey_data: Dictionary,
	assets: Array,
	cover_rel: String,
	mode: String = "embedded",
	pack: String = "full"
) -> Dictionary:
	# Type mirrors journey.json: "journey" or "rendition" (an overlay). A rendition also carries ParentId
	# so the importer can check the base is installed and group it under the right parent.
	var type: String = str(journey_data.get("Type", "journey"))
	var manifest: Dictionary = {
		"PackageFormat": PACKAGE_FORMAT,
		"Type": type,
		"Mode": mode,
		# Which half of a split this is: "full" (self-contained), "scripts" (journey.json + paid assets,
		# video slots empty), or "video" (free media only, no journey.json). Import routes on it.
		"Pack": pack,
		"JourneyId": str(journey_data.get("JourneyId", "")),
		"Name": str(journey_data.get("Name", "")),
		"Author": str(journey_data.get("Author", "")),
		"SupportLinks": [],
		"CreatedWith": str(journey_data.get("CreatedWith", "")),
		"MinVersion": str(journey_data.get("MinVersion", "")),
		"Counts": node_counts(journey_data),
		"Cover": cover_rel,
		"Assets": assets,
	}
	if type == "rendition":
		manifest["ParentId"] = str(journey_data.get("ParentId", ""))
		manifest["ParentMinVersion"] = str(journey_data.get("ParentMinVersion", ""))
	return manifest


# Parses a raw manifest dict into the runtime (snake_case) shape, or {"ok": false, "error": …} when
# it isn't a package (no PackageFormat) or was written by a newer app (format ahead of ours). Mirrors
# JourneyScanner.parse_journey's PascalCase→snake_case convention.
static func parse_manifest(raw: Dictionary) -> Dictionary:
	var fmt: int = int(raw.get("PackageFormat", 0))
	if fmt <= 0:
		return {"ok": false, "error": "not_a_package"}
	if fmt > PACKAGE_FORMAT:
		return {"ok": false, "error": "newer_format", "format": fmt}
	return {
		"ok": true,
		"package_format": fmt,
		"type": str(raw.get("Type", "journey")),
		"mode": str(raw.get("Mode", "embedded")),
		"pack": str(raw.get("Pack", "full")),
		"parent_id": str(raw.get("ParentId", "")),
		"parent_min_version": str(raw.get("ParentMinVersion", "")),
		"journey_id": str(raw.get("JourneyId", "")),
		"name": str(raw.get("Name", "")),
		"author": str(raw.get("Author", "")),
		"support_links": raw.get("SupportLinks", []),
		"created_with": str(raw.get("CreatedWith", "")),
		"min_version": str(raw.get("MinVersion", "")),
		"counts": raw.get("Counts", {}),
		"cover": str(raw.get("Cover", "")),
		"assets": raw.get("Assets", []),
	}


# Counts each node type in a Format-2 journey.json (for the manifest + import preview). An absent
# Nodes block (malformed / legacy-tree) yields zeros rather than erroring.
static func node_counts(journey_data: Dictionary) -> Dictionary:
	var counts: Dictionary = {"rounds": 0, "forks": 0, "shops": 0, "storyboards": 0}
	var key_of: Dictionary = {
		"round": "rounds", "fork": "forks", "shop": "shops", "storyboard": "storyboards"
	}
	for raw: Variant in journey_data.get("Nodes", []):
		if raw is Dictionary:
			var key: String = key_of.get(str((raw as Dictionary).get("type", "")), "")
			if key != "":
				counts[key] += 1
	return counts


# ── Asset routing ──────────────────────────────────────────────────────────────


# free/paid for a role. The only hard rule: scene footage and the cover are always free; everything
# the author authored defaults to paid (the author can opt an individual paid asset to free later, but
# never the reverse for a scene — see apply_overrides).
static func classify_asset(role: String) -> String:
	return "free" if role in FREE_ROLES else "paid"


# A node's own backdrop and music, when it overrides its setting's. Shared by the three surfaces that
# can carry one.
static func _note_scene_override(roles: Dictionary, data: Dictionary) -> void:
	_note(roles, str(data.get("image", "")), ROLE_IMAGE)
	_note(roles, str(data.get("bgm", "")), ROLE_AUDIO)


# Walks journey.json — every node's media plus the journey-level Items/Characters art — into a deduped
# [{rel, role, pack}] list. Roles come from the REFERENCE (video_path → scene, boss_image → image, …),
# so the free/paid line is drawn by intent, not by file type. When one pooled file is referenced under
# two roles, "scene" wins (a clip used as footage can never be sold, whatever else points at it).
static func enumerate_assets(journey_data: Dictionary, cover_rel: String = "") -> Array:
	var roles: Dictionary = {}  # rel → role (deduped)
	if cover_rel != "":
		_note(roles, cover_rel, ROLE_COVER)

	for raw: Variant in journey_data.get("Nodes", []):
		if not (raw is Dictionary):
			continue
		var node: Dictionary = raw
		var data: Dictionary = node.get("data", {})
		match str(node.get("type", "")):
			"round":
				_note_round(roles, data)
			"storyboard":
				_note_storyboard(roles, data)
			"fork":
				_note(roles, str(data.get("audio", "")), ROLE_AUDIO)
				for edge: Variant in node.get("out", []):
					if edge is Dictionary:
						_note(roles, str((edge as Dictionary).get("image_path", "")), ROLE_IMAGE)
				_note_scene_override(roles, data)
			"shop", "checkpoint":
				# Neither carried media until per-node backdrops existed, which is why neither had a
				# case here at all — an export would have shipped the journey without them.
				_note_scene_override(roles, data)

	for item: Variant in journey_data.get("Items", []):
		if item is Dictionary:
			_note(roles, str((item as Dictionary).get("Image", "")), ROLE_IMAGE)
	for chr: Variant in journey_data.get("Characters", []):
		if chr is Dictionary:
			for por: Variant in (chr as Dictionary).get("Portraits", []):
				if por is Dictionary:
					_note(roles, str((por as Dictionary).get("Path", "")), ROLE_IMAGE)

	# Settings are journey-level like the cast: each background is an image, each theme an audio track,
	# and the journey's own score is a list of them. A setting referenced by several nodes still notes
	# its media once — _note dedupes by relative path.
	for st: Variant in journey_data.get("Settings", []):
		if st is Dictionary:
			for bg: Variant in (st as Dictionary).get("Backgrounds", []):
				if bg is Dictionary:
					_note(roles, str((bg as Dictionary).get("Path", "")), ROLE_IMAGE)
			_note(roles, str((st as Dictionary).get("Bgm", "")), ROLE_AUDIO)
	var journey_bgm: Variant = journey_data.get("Bgm", [])
	for track: Variant in journey_bgm if journey_bgm is Array else [journey_bgm]:
		_note(roles, str(track), ROLE_AUDIO)

	# Rendition overlay media lives OUTSIDE the Nodes block: overlay fork-choice card images on anchor
	# edges (author art → paid), and slot-fill media routed by the slot's field exactly like a round's own
	# (a filled video slot is scene → free; scripts/boss art → paid). A base journey has neither key.
	for anchor: Variant in journey_data.get("Anchors", []):
		if anchor is Dictionary:
			var edge: Variant = (anchor as Dictionary).get("Edge", {})
			if edge is Dictionary:
				_note(roles, str((edge as Dictionary).get("image_path", "")), ROLE_IMAGE)
	for sf: Variant in journey_data.get("SlotFills", []):
		if sf is Dictionary:
			var f: Dictionary = sf
			_note(roles, str(f.get("Path", "")), _slot_fill_role(str(f.get("Field", ""))))

	var assets: Array = []
	for rel: String in roles:
		assets.append({"rel": rel, "role": roles[rel], "pack": classify_asset(roles[rel])})
	return assets


# A round's own media + each encounter entry's (a pool round carries no round-level media; its clips
# live in the entries). Boss images are "image" (paid presentation), NOT scene footage.
static func _note_round(roles: Dictionary, data: Dictionary) -> void:
	_note(roles, str(data.get("video_path", "")), ROLE_SCENE)
	_note(roles, str(data.get("funscript_path", "")), ROLE_FUNSCRIPT)
	_note(roles, str(data.get("boss_image", "")), ROLE_IMAGE)
	_note_channels(roles, data.get("axis_scripts", {}), ROLE_AXIS)
	_note_channels(roles, data.get("vib_scripts", {}), ROLE_VIBE)
	for entry: Variant in data.get("pool_entries", []):
		if entry is Dictionary:
			var e: Dictionary = entry
			_note(roles, str(e.get("video_path", "")), ROLE_SCENE)
			_note(roles, str(e.get("funscript_path", "")), ROLE_FUNSCRIPT)
			_note(roles, str(e.get("boss_image", "")), ROLE_IMAGE)
			_note_channels(roles, e.get("axis_scripts", {}), ROLE_AXIS)
			_note_channels(roles, e.get("vib_scripts", {}), ROLE_VIBE)


static func _note_storyboard(roles: Dictionary, data: Dictionary) -> void:
	_note(roles, str(data.get("image", "")), ROLE_IMAGE)
	_note(roles, str(data.get("bgm", "")), ROLE_AUDIO)
	for line: Variant in data.get("lines", []):
		if line is Dictionary:
			_note(roles, str((line as Dictionary).get("image", "")), ROLE_IMAGE)
			_note(roles, str((line as Dictionary).get("audio", "")), ROLE_AUDIO)


static func _note_channels(roles: Dictionary, channels: Dictionary, role: String) -> void:
	for ch: Variant in channels:
		_note(roles, str(channels[ch]), role)


# The asset role for a rendition slot-fill's Field — the same routing a round's own media gets, so a
# filled video slot rides in the free pack while a filled script/boss slot is paid.
static func _slot_fill_role(field: String) -> String:
	match field:
		"video_path":
			return ROLE_SCENE
		"funscript_path":
			return ROLE_FUNSCRIPT
		"boss_image":
			return ROLE_IMAGE
		"axis_scripts":
			return ROLE_AXIS
		"vib_scripts":
			return ROLE_VIBE
	return ROLE_IMAGE


# Records rel→role, deduping. "scene" always wins a conflict — footage can never be sold, so nothing
# demotes it out of the free pack.
static func _note(roles: Dictionary, rel: String, role: String) -> void:
	if rel == "":
		return
	if not roles.has(rel):
		roles[rel] = role
	elif role == ROLE_SCENE:
		roles[rel] = ROLE_SCENE


# Applies author per-asset overrides (rel → "free"/"paid") to an enumerate_assets list, in place.
# A scene asset is immovable: an override can never push footage into the paid pack.
static func apply_overrides(assets: Array, overrides: Dictionary) -> void:
	for asset: Variant in assets:
		var a: Dictionary = asset
		var rel: String = str(a.get("rel", ""))
		if str(a.get("role", "")) == ROLE_SCENE:
			continue
		if overrides.has(rel):
			var pack: String = str(overrides[rel])
			if pack == "free" or pack == "paid":
				a["pack"] = pack


# Splits an asset list into {free: [rel…], paid: [rel…]} by each asset's pack, for the two-file
# split export. The free pack ships the video (+ cover); the paid pack ships journey.json + the rest.
static func partition_assets(assets: Array) -> Dictionary:
	var out: Dictionary = {"free": [], "paid": []}
	for asset: Variant in assets:
		var a: Dictionary = asset
		var half: String = "free" if str(a.get("pack", "paid")) == "free" else "paid"
		(out[half] as Array).append(str(a.get("rel", "")))
	return out


# True when the paid half contains no scene footage — the structural guarantee that the tool can't
# paywall video. Callers assert this before writing a paid pack.
static func paid_pack_is_clean(assets: Array) -> bool:
	for asset: Variant in assets:
		var a: Dictionary = asset
		if str(a.get("role", "")) == ROLE_SCENE and str(a.get("pack", "")) != "free":
			return false
	return true


# ── Import dedupe ──────────────────────────────────────────────────────────────


# Finds the already-installed journey that shares `incoming_id` (JourneyId), so import can offer
# Overwrite / Skip / Import-as-copy. `existing` is JourneyScanner.scan_all output (each has
# "journey_id"). Returns the matching journey dict, or {} when the id is new (or blank). A blank id
# never collides — pre-id journeys can't anchor anything.
static func find_id_collision(incoming_id: String, existing: Array) -> Dictionary:
	if incoming_id.strip_edges() == "":
		return {}
	for j: Variant in existing:
		if j is Dictionary and str((j as Dictionary).get("journey_id", "")) == incoming_id:
			return j
	return {}
