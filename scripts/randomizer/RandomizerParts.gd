class_name RandomizerParts
extends RefCounted
## Expansion layer between the randomizer library and RandomizerGenerator: turns a
## video entry's funscript BEATS (FunscriptSegmenter output, persisted in the
## registry's `parts` field) into round-sized PARTS, each emitted as a pseudo-entry
## in the existing entry format. The generator therefore only ever sees "more
## clips" and stays untouched — that is the whole point of this file, and the
## reason the tiling below must be gapless and overlap-free: a generator that had
## to reject overlapping candidates would have to be rewritten.
##
## Pure and seeded, like RandomizerGenerator: the only entropy is the caller's rng
## (same seed → same cuts → reproducible run), and the only I/O is the stat-level
## read inside JourneyData.media_fingerprint, which is unavoidable because the
## generator needs the pooled rels already present on the entry. No file-existence
## gating, no writes — so this is fully testable headless.
##
## Emits pseudo-entries of the shape the generator + RandomizerLibrary consume:
##   { id, name, video_src, funscript_src, axis_src, vib_src, needs_transcode,
##     video_rel, funscript_rel, axis_rel, vib_rel, boss_image_rel,
##     action_count, length_ms, duration_ms, tags, weight, intensity, last_used,
##     added_at, segments:[{in_ms,out_ms}], source_id, part_index, part_count }
## Whole-clip entries pass through as the very same objects, without `segments`.

# Separates the video fingerprint from the segment identity in a part id (§3 of
# the interface contract). A media fingerprint is plain hex and never contains it,
# so the first occurrence always splits id → video.
const PART_ID_SEP: String = "#"

# cfg keys (all optional). Round lengths are SECONDS, matching target_minutes in
# the generator and what the UI slider / a saved preset actually shows.
#   cut_parts:bool             off = today's whole-clip behaviour, bit for bit
#   part_min_s / part_max_s    the round-length slider
#   jitter_pct:float           spread as a fraction of (max-min)
#   intensity_tolerance:int    coherence brake: a bigger step ends the part
#   max_merge_gap_ms:int       never merge across a hole wider than this
const DEFAULT_CFG: Dictionary = {
	"cut_parts": false,
	"part_min_s": 60,
	"part_max_s": 180,
	"jitter_pct": 0.15,
	"intensity_tolerance": 1,
	"max_merge_gap_ms": 5000,
}


# Library entries → generator entries. Videos with usable beats are replaced by
# their parts; everything else is passed through or dropped (see below). Takes the
# whole settings dict of the screen — unknown keys are inert, exactly as in
# RandomizerGenerator.generate.
static func expand(entries: Array, cfg: Dictionary, rng: RandomNumberGenerator) -> Array:
	var c: Dictionary = DEFAULT_CFG.duplicate(true)
	c.merge(cfg, true)
	if not bool(c["cut_parts"]):
		# Feature off: a shallow copy so the caller's array can't be aliased, but
		# the entries themselves are untouched originals.
		return entries.duplicate()

	# A degenerate slider range would make the bias curve divide by zero and the
	# tiling loop never terminate on its target, so clamp to a sane window first.
	var min_ms: int = maxi(1000, int(c["part_min_s"]) * 1000)
	var max_ms: int = maxi(min_ms + 1000, int(c["part_max_s"]) * 1000)

	var out: Array = []
	for entry: Dictionary in entries:
		# "No usable script" (never analysed) and "analysed, nothing survived" both
		# end in parts == []; only this predicate separates them. The former stays a
		# whole clip like today, the latter contributes no candidates at all.
		if str(entry.get("funscript_src", "")) == "" or int(entry.get("action_count", 0)) < 2:
			out.append(entry)
			continue
		var beats: Array = entry.get("parts", [])
		if beats.is_empty():
			continue
		var tiles: Array = _tile(beats, min_ms, max_ms, c, rng)
		for k: int in tiles.size():
			out.append(_make_pseudo_entry(entry, tiles[k], k, tiles.size()))
	return out


# ── Tiling ───────────────────────────────────────────────────────────────────


# Single pass over the beats: start a part, roll its target length, absorb
# following beats until something stops it, emit, repeat. Gapless and disjoint by
# construction — every beat lands in exactly one part, and no beat is ever split.
#
# The ORDER of the four break checks is normative; it decides which tile is cut.
# Exactly ONE rng.randf() is spent per part, drawn before any merging, so the
# draw count equals the part count and the rng stays predictable for the caller.
static func _tile(
	beats: Array, min_ms: int, max_ms: int, c: Dictionary, rng: RandomNumberGenerator
) -> Array:
	var jitter_pct: float = float(c["jitter_pct"])
	var tolerance: int = int(c["intensity_tolerance"])
	var max_gap: int = int(c["max_merge_gap_ms"])

	var parts: Array = []
	var i: int = 0
	while i < beats.size():
		var first: Dictionary = beats[i]
		var target: int = target_length_ms(int(first["intensity"]), min_ms, max_ms, jitter_pct, rng)
		var in_ms: int = int(first["in_ms"])
		var out_ms: int = int(first["out_ms"])
		var acts: int = int(first["action_count"])
		# Length-weighted speed accumulator: a 60s beat must count for more than a
		# 8s one when the running intensity is re-derived after each merge.
		var wsum: float = float(first["speed"]) * float(out_ms - in_ms)
		var wlen: float = float(out_ms - in_ms)

		var j: int = i
		while j + 1 < beats.size():
			var nxt: Dictionary = beats[j + 1]
			if out_ms - in_ms >= target:
				break  # rolled length reached
			var run_intensity: int = FunscriptIntensity.bucket(wsum / maxf(1.0, wlen))
			if absi(int(nxt["intensity"]) - run_intensity) > tolerance:
				break  # coherence brake: an intensity step is a round boundary
			if int(nxt["in_ms"]) - out_ms > max_gap:
				break  # a part is ONE window, so a big hole would be baked in
			if int(nxt["out_ms"]) - in_ms > max_ms:
				break  # slider ceiling
			j += 1
			out_ms = int(nxt["out_ms"])
			acts += int(nxt["action_count"])
			var beat_len: float = float(int(nxt["out_ms"]) - int(nxt["in_ms"]))
			wsum += float(nxt["speed"]) * beat_len
			wlen += beat_len

		# The first beat is always accepted, so a beat longer than max_ms becomes its
		# own oversized part — honest, and better than cutting mid-motion. Likewise
		# the tail of a video may fall short of min_ms; single-pass stays single-pass.
		var speed: float = wsum / maxf(1.0, wlen)
		var part: Dictionary = {
			"in_ms": in_ms,
			"out_ms": out_ms,
			"length_ms": out_ms - in_ms,
			"action_count": acts,
			"speed": speed,
			"intensity": FunscriptIntensity.bucket(speed),
			"beat_count": j - i + 1,
		}
		parts.append(part)
		i = j + 1
	return parts


# Rolled round length, biased by the intensity of the beat the tile starts on:
# intensity 5 sits at the bottom of the slider range, intensity 1 at the top, so
# hard passages become short rounds. Jitter is a fraction of the SPAN (±18s at the
# 60–180s default) — visibly irregular without drowning the bias. Exactly one
# randf(), which is what keeps the rng bookkeeping in _tile trivial.
static func target_length_ms(
	intensity: int, min_ms: int, max_ms: int, jitter_pct: float, rng: RandomNumberGenerator
) -> int:
	var t: float = clampf((float(intensity) - 1.0) / 4.0, 0.0, 1.0)
	var center: float = lerpf(float(max_ms), float(min_ms), t)
	var jitter: float = (rng.randf() * 2.0 - 1.0) * jitter_pct * float(max_ms - min_ms)
	return int(round(clampf(center + jitter, float(min_ms), float(max_ms))))


# ── Pseudo-entry ─────────────────────────────────────────────────────────────


# One tile → one entry in the generator's format. Every field the generator and
# prepare_entry_media read is set; the length fields carry the PART's numbers,
# never the video's, or the time budget would be off by orders of magnitude.
static func _make_pseudo_entry(video: Dictionary, part: Dictionary, k: int, n: int) -> Dictionary:
	var segments: Array = [{"in_ms": int(part["in_ms"]), "out_ms": int(part["out_ms"])}]
	var video_id: String = str(video.get("id", ""))
	var part_id: String = make_part_id(video_id, segments)
	var rels: Dictionary = predict_part_rels(video, segments)
	var part_used: Dictionary = video.get("part_used", {})
	var length: int = int(part["length_ms"])
	return {
		"id": part_id,
		"name": "%s · %d/%d" % [str(video.get("name", "")), k + 1, n],
		"video_src": str(video.get("video_src", "")),
		"funscript_src": str(video.get("funscript_src", "")),
		"axis_src": (video.get("axis_src", {}) as Dictionary).duplicate(true),
		"vib_src": (video.get("vib_src", {}) as Dictionary).duplicate(true),
		# A cut always re-encodes, so the flag is true and _pool_video ignores it
		# anyway once segments are present.
		"needs_transcode": true,
		"video_rel": str(rels["video_rel"]),
		"funscript_rel": str(rels["funscript_rel"]),
		"axis_rel": rels["axis_rel"],
		"vib_rel": rels["vib_rel"],
		"boss_image_rel": str(video.get("boss_image_rel", "")),
		"action_count": int(part["action_count"]),
		"length_ms": length,
		"duration_ms": length,
		"tags": (video.get("tags", []) as Array).duplicate(),
		"weight": float(video.get("weight", 1.0)),
		"intensity": int(part["intensity"]),
		# Freshness decays per PART: the video may come round again immediately, the
		# stretch just played may not.
		"last_used": int(part_used.get(part_id, 0)),
		"added_at": int(video.get("added_at", 0)),
		"segments": segments,
		"source_id": video_id,
		"part_index": k,
		"part_count": n,
	}


# ── Part ids ─────────────────────────────────────────────────────────────────


# "<video_fingerprint>#trim:<in>-<out>". Stable as long as the source file and the
# beat boundaries are — which is exactly the contract `part_used` needs, since it
# is keyed by this string across runs.
static func make_part_id(video_id: String, segments: Array) -> String:
	return video_id + PART_ID_SEP + JourneyData.segments_identity(segments)


# Everything before the FIRST separator. A plain video id (no separator) maps to
# itself, so callers can pass mixed id lists. Mirrored bit for bit by
# RandomizerLibrary._video_id_of, which stays free of a dependency on this class.
static func video_id_of(id: String) -> String:
	var sep: int = id.find(PART_ID_SEP)
	return id.substr(0, sep) if sep > 0 else id


static func is_part_id(id: String) -> bool:
	return id.find(PART_ID_SEP) > 0


# ── Pooled rel prediction ────────────────────────────────────────────────────


# The pooled paths a part's baked media will land on. Segments join the
# fingerprint, so two parts of one video never collide and an identical cut in a
# later run hits the cache. Identical maths to RandomizerLibrary's whole-clip
# prediction — same two JourneyData functions, just with a non-empty segment list.
static func predict_part_rels(entry: Dictionary, segments: Array) -> Dictionary:
	return {
		# Always mp4: bake_edl concatenates H.264/AAC into an MP4 container,
		# regardless of what the source container was.
		"video_rel": _predict_rel(str(entry.get("video_src", "")), segments, "mp4"),
		"funscript_rel": _predict_rel(str(entry.get("funscript_src", "")), segments, "funscript"),
		"axis_rel": _predict_channel_rels(entry.get("axis_src", {}), segments),
		"vib_rel": _predict_channel_rels(entry.get("vib_src", {}), segments),
	}


# Deliberately NO file_exists gate (unlike the library's whole-clip predictor):
# that would bind the pure expansion — and its tests — to real files on disk. A
# missing source still hashes deterministically over "<abs>|0|0|<segments>".
static func _predict_rel(src: String, segments: Array, ext: String) -> String:
	if src == "":
		return ""
	return JourneyData.pooled_media_rel(JourneyData.media_fingerprint(src, segments), ext, src)


# {channel: source} → {channel: predicted rel}, skipping empty sources.
static func _predict_channel_rels(srcs: Dictionary, segments: Array) -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in srcs:
		var rel: String = _predict_rel(str(srcs[key]), segments, "funscript")
		if rel != "":
			out[str(key)] = rel
	return out
