extends Node
## Graph-agnostic media operations shared by the journey builder's save pipeline
## and the randomizer library. Resolves the ffmpeg / ffprobe binaries, probes a
## source video (codec / pixel format / duration), decides whether a source needs
## re-encoding for the runtime decoder (see PLAYABLE_VIDEO_CODECS — the vendored
## avcodec is a trimmed build, NOT the full ffmpeg CLI beside it), and runs the
## actual transcode.
##
## Pure I/O + process control: it owns no journey / graph / UI state. Progress and
## cancellation are injected as Callables, so any caller wires its own modal — the
## builder feeds its save-progress modal, the randomizer its library-add modal.
## Extracted from JourneyBuilder so both paths share one implementation.

# Codecs the runtime decoder treats as H.264 (ffprobe codec_name variants). Kept separate from
# PLAYABLE_VIDEO_CODECS because one caller still needs the narrow question rather than "can this play":
# JourneyBuilder decides whether a KEPT video raises a journey's MinVersion floor, and only H.264 is
# playable by every older build.
const H264_NAMES: Array[String] = ["h264", "avc1", "avc"]

# Everything THE RUNTIME can decode without a re-encode — EIRTeam.FFmpeg's vendored avcodec, which is a
# deliberately trimmed build (`--disable-decoders`, then a short re-enable list). NOT the ffmpeg CLI
# sitting beside it: that one is a full build that decodes nearly everything, and confusing the two is
# exactly how an unplayable file would clear the save gate and then fail at a round's first frame.
#
# This list mirrors the addon build's own `--enable-decoder=` set. Widen it only alongside the binaries.
#
# AV1 joined it once the binaries could actually play it — the vendored avcodec is now built with
# `--enable-decoder=libdav1d --enable-parser=av1`, verified by the decoder name appearing in the DLL
# rather than only in its configure string. An AV1 source is therefore KEPT AS IT IS: no re-encode, no
# generation loss, and a journey a third smaller than the H.264 copy it used to be turned into.
#
# `av01` and `hvc1`/`hev1` are MP4 fourccs rather than codec_names ffprobe emits, listed for the same
# defensive reason `avc1` sits beside `h264`.
#
# HEVC rides along on the same build (`--enable-decoder=hevc --enable-parser=hevc`). It is commonly
# 10-bit, as is much AV1 — and 10-bit now costs the same as 8-bit, because both go to the GPU. See the
# measurements under SAFE_PIX_FMTS below.
const PLAYABLE_VIDEO_CODECS: Array[String] = [
	"h264", "avc1", "avc", "vp8", "vp9", "av1", "av01", "hevc", "h265", "hvc1", "hev1"
]

# Containers the runtime can DEMUX. The addon build enables mov, matroska, avi and flv only, so a file
# outside this list needs remuxing even when its codec is perfectly playable — an H.264 .ts clears every
# codec check today, pools verbatim, and then cannot be opened at play time.
const PLAYABLE_CONTAINERS: Array[String] = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv"]

# Pixel formats the runtime plays without re-encoding: 8-bit 4:2:0 (standard and full-range JPEG), plus
# 10-bit 4:2:0, which most AV1 and HEVC in the wild actually uses.
#
# BOTH GO STRAIGHT TO THE GPU. The planes are uploaded as textures and converted by a compute shader —
# R8 for 8-bit, R16 for 10-bit — so bit depth costs almost nothing. That was not free: 10-bit originally
# fell back to a per-frame swscale conversion to RGBA on the CPU, and a 10-bit path was built in the
# EIRTeam.FFmpeg fork to remove it. Measured on the same clip, same round (Ryzen 7 9850X3D):
#
#                     before the GPU path      after
#     4K   8-bit           74.5%                74.6%     (unchanged, as it should be)
#     4K  10-bit          125.4%                77.3%     — 1.68x down to 1.04x
#
# So the split that used to matter — 8-bit kept, 10-bit re-encoded — is gone, and both are simply kept.
#
# 4:2:2 and 4:4:4 stay out. Not because they are known to be slow: they have never been measured and
# have no GPU path, so they would take the RGBA fallback this work exists to avoid. Adding one means
# adding its shader variant first (see yuv_to_rgb_10bit.glsl for the pattern) and then measuring.
const SAFE_PIX_FMTS: Array[String] = ["yuv420p", "yuvj420p", "yuv420p10le"]

# Scratch file ffmpeg writes -progress lines to; polled to drive the progress bar.
const PROGRESS_FILE: String = "user://transcode_progress.txt"

# PID of the in-flight ffmpeg encode (-1 when idle). Owned here so a caller's
# cancel callback only needs to flip a bool — transcode_video does the kill.
var _pid: int = -1

# Flipped the moment shutdown kills the encode, and never cleared. A polling loop can still
# get one more tick in that same frame; with _pid already back to -1 it leaves the loop through
# the NORMAL exit and would publish the truncated .part as a finished file. Nothing may be
# published once this is true.
var _shutting_down: bool = false

# Serialises EVERY encode entry point. Because only one ever runs at a time, _pid,
# PROGRESS_FILE and SEGMENT_BAKE_DIR stay single-use BY CONSTRUCTION — no per-call
# contexts, no PID ownership checks, no scoped scratch dirs.
var _gate: EncodeGate = EncodeGate.new()

# Cap for background encodes: without it libx264 grabs every core while EIRTeam.FFmpeg
# decodes 1080p for the running session beside it. Deliberately not a user setting.
const BACKGROUND_ENCODE_THREADS: int = 2

# Monotonic: +1 for every job aborted because a higher-priority ticket was waiting (at
# most once per ticket). Background callers snapshot it before a job and compare after —
# a rise means "pre-empted", not "failed".
var _preempt_count: int = 0
var _preempted_ticket: int = 0

# ── Encode gate ──────────────────────────────────────────────────────────────


func preempt_count() -> int:
	return _preempt_count


# Wraps the caller's should_cancel with the gate condition, so the existing
# OS.kill(_pid) path of every polling loop applies unchanged — including the cleanup
# already hanging off it. Counts pre-emption at most ONCE per ticket.
func _effective_cancel(should_cancel: Callable, ticket: int) -> Callable:
	return func() -> bool:
		if should_cancel.is_valid() and should_cancel.call():
			return true
		if not _gate.should_yield(ticket):
			return false
		if _preempted_ticket != ticket:
			_preempted_ticket = ticket
			_preempt_count += 1
		return true


# Scratch name ffmpeg encodes to before publication, e.g. clip.mkv → clip.mkv.part.mkv.
#
# The target extension is REPEATED on the end on purpose: ffmpeg picks its muxer from the
# output extension, and a bare "<out>.part" aborts with "Unable to choose an output
# format" — every encode would fail. Repeating it keeps today's muxer choice EXACTLY
# (bake_edl's output is not always .mp4: RandomizerLibrary keeps the source container
# when the clip needs no re-encode, so a part-cut .mkv still muxes as matroska).
# Appended after the full target name rather than infixed, so a scratch name can never
# collide with some other target's final name.
func _part_path(out_abs: String) -> String:
	var ext: String = out_abs.get_extension()
	if ext == "":
		return out_abs + ".part"
	return out_abs + ".part." + ext


# Publishes a finished encode: the .part scratch → <out_abs>. Same pattern as
# RandomizerLibrary._pool_script with its .tmp file — the rename is the ONLY publishing
# step, so a crash mid-encode can never leave a truncated file at the final name that a
# later file_exists() guard would wave through as "already pooled".
func _publish_part(out_abs: String) -> bool:
	# First, before any file test: after a shutdown kill the .part is truncated by definition,
	# and a loop that ticks once more in that frame would otherwise publish it (see _shutting_down).
	if _shutting_down:
		return false
	var part_abs: String = _part_path(out_abs)
	if not FileAccess.file_exists(part_abs):
		return false
	if FileAccess.file_exists(out_abs):
		DirAccess.remove_absolute(out_abs)  # keeps ffmpeg's old "-y" overwrite semantics
	if DirAccess.rename_absolute(part_abs, out_abs) != OK:
		return false
	return FileAccess.file_exists(out_abs)


# Drops a leftover .part scratch for `output`. Called by the gate wrapper while it still
# HOLDS its ticket — after the release a pre-empting foreground job may already own the
# name. One short retry, because a just-killed ffmpeg can still hold the handle on
# Windows (same reasoning as RandomizerLibrary._remove_if_exists).
func _discard_part(output: String) -> void:
	var part_abs: String = _part_path(ProjectSettings.globalize_path(output))
	if not FileAccess.file_exists(part_abs):
		return
	if DirAccess.remove_absolute(part_abs) == OK:
		return
	# A scene-tree timer, not OS.delay_msec: this retry runs on practically every pre-emption, and
	# blocking the main thread 200 ms there is an audible hitch in the session playing beside the
	# encode. Still under our own ticket, so the extra suspension hands the name to nobody.
	await get_tree().create_timer(0.2).timeout
	if DirAccess.remove_absolute(part_abs) != OK:
		push_warning("MediaPoolService: could not delete partial encode %s" % part_abs)


# OS.create_process spawns a DETACHED process, so a background ffmpeg would otherwise
# outlive the app and keep writing. With .part+rename that is harmless (an orphan
# publishes nothing), but clean only with this. NOTIFICATION_WM_CLOSE_REQUEST covers the
# window close / Alt+F4, NOTIFICATION_EXIT_TREE the get_tree().quit() route.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		# Set BEFORE the kill, not after: the polling loop can be resumed in this very frame, and
		# from _pid = -1 alone it cannot tell a finished encode from a killed one (see _publish_part).
		_shutting_down = true
		if _pid > 0 and OS.is_process_running(_pid):
			OS.kill(_pid)
		_pid = -1


# ── Binary resolution ────────────────────────────────────────────────────────


func resolve_binary(name: String) -> String:
	# Resolution order (custom folder → bundled → PATH) lives in
	# SettingsService.resolve_ffmpeg_binary so the Options "Test" button shares it.
	# The one export concern: in an exported build res://bin/ is inside the PCK and
	# can't be executed, so extract to user://bin/ on first use. Only bother when
	# resolution otherwise falls through to a bare PATH name (i.e. no custom folder
	# and nothing extracted yet).
	var path: String = SettingsService.resolve_ffmpeg_binary(name)
	if path == name and not OS.has_feature("editor"):
		var exe: String = name + ".exe" if OS.get_name() == "Windows" else name
		var user_abs: String = ProjectSettings.globalize_path("user://bin/" + exe)
		if not FileAccess.file_exists(user_abs):
			_extract_binary("res://bin/" + exe, user_abs)
		path = SettingsService.resolve_ffmpeg_binary(name)
	return path


# Copies a binary from the PCK (res://) to an absolute filesystem path so it can
# be executed. Called once per binary per user data directory.
func _extract_binary(src_res: String, dst_abs: String) -> void:
	if not FileAccess.file_exists(src_res):
		return
	DirAccess.make_dir_recursive_absolute(dst_abs.get_base_dir())
	var f_in: FileAccess = FileAccess.open(src_res, FileAccess.READ)
	if f_in == null:
		return
	var bytes: PackedByteArray = f_in.get_buffer(f_in.get_length())
	f_in.close()
	var f_out: FileAccess = FileAccess.open(dst_abs, FileAccess.WRITE)
	if f_out == null:
		return
	f_out.store_buffer(bytes)
	f_out.close()
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", dst_abs], [], true)


var _avail_key: String = ""  # resolved ffprobe path _avail_ok belongs to
var _avail_ok: bool = false


# Memoised per RESOLVED binary path. The call used to cost a process spawn per part
# (RandomizerLibrary._pool_video probes it in both branches) — on the background path an
# audible hitch in the running session. Keying on the resolved path is what invalidates
# the memo: the ffmpeg folder in the options is the only input that redirects
# resolve_ffmpeg_binary, so changing it changes this key by itself.
#
# Accepted gap: ffmpeg installed later into the SAME folder stays unnoticed until the
# app restarts. The price for having no coupling to Options at all.
func is_available() -> bool:
	var bin: String = resolve_binary("ffprobe")
	if bin != _avail_key:
		var out: Array = []
		_avail_ok = OS.execute(bin, ["-version"], out, true, false) == 0
		_avail_key = bin
	return _avail_ok


# ── Pooled-file reuse (incremental save) ─────────────────────────────────────


# True when `path` is a journey's pooled content file (basename m_<hash>.<ext> inside a content/
# folder). Only these are safe to hardlink on a re-save: they're media the journey already owns.
# An author's ORIGINAL source is never this, so it always gets an independent byte copy — the
# journey never shares storage with a file the author might move or edit.
func is_pooled_content_file(path: String) -> bool:
	return JourneyData.is_pooled_content_path(path)


# Attempts an OS hardlink src→dst — instant, no disk, since the two names share one inode. Returns
# true only when the link file actually appears; a cross-volume refusal or any error returns false
# so the caller falls back to a byte copy. Windows: mklink /H (no admin). Unix: ln.
#
# Safe under the save's atomic swap: the link and the byte copy it replaces are identical content,
# and deleting the old journey folder just drops one link name — the staging link keeps the data
# alive until it becomes the new folder. Never overwrites an existing dst.
func try_hardlink(src: String, dst: String) -> bool:
	var src_abs: String = ProjectSettings.globalize_path(src)
	var dst_abs: String = ProjectSettings.globalize_path(dst)
	if FileAccess.file_exists(dst_abs):
		return false
	DirAccess.make_dir_recursive_absolute(dst_abs.get_base_dir())
	var out: Array = []
	if OS.get_name() == "Windows":
		OS.execute("cmd", ["/c", "mklink", "/H", dst_abs, src_abs], out, true, false)
	else:
		OS.execute("ln", [src_abs, dst_abs], out, true, false)
	return FileAccess.file_exists(dst_abs)


# ── Probing ──────────────────────────────────────────────────────────────────


# Probes a video's primary stream for both codec name and pixel format in one
# ffprobe call. Returns {"codec": String, "pix_fmt": String} (lowercased; empty
# strings when the probe fails).
func probe_stream_info(path: String) -> Dictionary:
	var out: Array = []
	var args: PackedStringArray = [
		"-v",
		"error",
		"-select_streams",
		"v:0",
		"-show_entries",
		"stream=codec_name,pix_fmt,width,height",
		"-of",
		# key=value, NOT csv: ffprobe emits fields in its own canonical order, so this request
		# returns "h264,1920,1080,yuv420p". Positional parsing read the width as the pix_fmt,
		# failed every SAFE_PIX_FMTS check, and re-encoded every video on every save.
		"default=noprint_wrappers=1",
		ProjectSettings.globalize_path(path),
	]
	var empty: Dictionary = {"codec": "", "pix_fmt": "", "width": 0, "height": 0}
	if OS.execute(resolve_binary("ffprobe"), args, out, true, false) != 0 or out.is_empty():
		return empty
	var info: Dictionary = empty.duplicate()
	for raw_line: String in (out[0] as String).split("\n"):
		var line: String = raw_line.strip_edges().to_lower()
		var eq: int = line.find("=")
		if eq <= 0:
			continue
		var key: String = line.substr(0, eq)
		var value: String = line.substr(eq + 1).strip_edges()
		match key:
			"codec_name":
				info["codec"] = value
			"pix_fmt":
				info["pix_fmt"] = value
			"width":
				info["width"] = int(value)
			"height":
				info["height"] = int(value)
	return info


# True when `path` carries an audio stream. Fails SAFE — a probe that can't run reports true,
# costing one unnecessary encode rather than shipping a soundtrack that shouldn't be there.
# (No audio stream isn't a failure: ffprobe exits 0 with empty output.)
func probe_has_audio(path: String) -> bool:
	var out: Array = []
	var args: PackedStringArray = [
		"-v",
		"error",
		"-select_streams",
		"a:0",
		"-show_entries",
		"stream=codec_type",
		"-of",
		"csv=p=0",
		ProjectSettings.globalize_path(path),
	]
	if OS.execute(resolve_binary("ffprobe"), args, out, true, false) != 0:
		return true  # couldn't tell → assume the worst and let the bake strip it
	if out.is_empty():
		return false
	return (out[0] as String).strip_edges() != ""


# True when `path` is already exactly what bake_animation would produce for `cap`, so pooling
# it verbatim is safe. A baked file satisfies all four clauses by construction — that's what
# keeps the convert-once optimisation firing on a re-save.
#
# STRICT ON PURPOSE. This was once just "is it H.264 8-bit?", which is also true of any clip an
# author drops in as an animated image — and those copied through with their audio and their
# untruncated length. Don't loosen it back to a codec check.
#
# The CODEC clause is the one that widened: it accepts anything the runtime plays, not H.264 alone. The
# strictness that note is really about lives in the other clauses — pixel format, the size cap, the
# duration cap and the no-audio rule — and those are untouched, so an author's clip still cannot slip
# through with its audio and its full length.
#
# Why widen it: a journey whose videos are re-encoded to AV1 or HEVC for distribution would otherwise
# fail here on its animated images and re-bake them back to H.264 on the next save, quietly undoing part
# of the conversion. bake_animation still PRODUCES H.264; this only stops already-converted files being
# needlessly re-encoded.
func is_baked_animation(path: String, cap: Vector2i) -> bool:
	var info: Dictionary = probe_stream_info(path)
	if not (str(info.get("codec", "")) in PLAYABLE_VIDEO_CODECS):
		return false
	if not (str(info.get("pix_fmt", "")) in SAFE_PIX_FMTS):
		return false
	var w: int = int(info.get("width", 0))
	var h: int = int(info.get("height", 0))
	if w <= 0 or h <= 0 or w > cap.x or h > cap.y:
		return false
	# Tolerance: a truncated bake lands on a frame boundary, so it can measure a hair over 60s.
	if probe_duration_seconds(path) > ANIM_MAX_SECS + 0.5:
		return false
	return not probe_has_audio(path)


func probe_duration_seconds(path: String) -> float:
	var out: Array = []
	var args: PackedStringArray = [
		"-v",
		"error",
		"-show_entries",
		"format=duration",
		"-of",
		"csv=p=0",
		ProjectSettings.globalize_path(path),
	]
	if OS.execute(resolve_binary("ffprobe"), args, out, true, false) != 0 or out.is_empty():
		return 0.0
	return (out[0] as String).strip_edges().to_float()


# The pure decision behind classify_transcode, split out so the gate can be unit-tested without an
# autoload, a probe or a settings file — the ForkResolver / DeviceRouting pattern. `playable` is the
# caller's codec set, which is the only part that varies by build or setting.
#
# Order matters: the reason string is shown to the author, and the FIRST true thing about a file is the
# most useful one to tell them. An unplayable codec makes its pixel format irrelevant.
static func transcode_reason(
	codec: String, pix_fmt: String, is_trim: bool, container: String, playable: Array
) -> String:
	var reason: String = ""
	if codec == "":
		reason = "unverifiable"  # couldn't read — re-encode to be safe
	elif not (codec in playable):
		reason = codec  # nothing in this build decodes it
	elif pix_fmt != "" and not (pix_fmt in SAFE_PIX_FMTS):
		reason = "%s %s" % [codec, pix_fmt]  # decodes, but only down the per-frame CPU path
	elif container != "" and not (container.to_lower() in PLAYABLE_CONTAINERS):
		reason = "%s in .%s" % [codec, container.to_lower()]  # playable stream, unreadable wrapper
	if is_trim and reason == "":
		reason = "trim"  # fine source, but the cut itself demands the encode
	return reason


# Decides whether a probed source needs re-encoding, and why. Returns the reason string used for the plan
# key / modal ("" = no encode needed). A source is planned when its codec can't be read (re-encode to be
# safe), when nothing in this build decodes it, when its pixel format would cost a per-frame CPU
# conversion, or when its container can't be demuxed. `is_trim` forces an encode even on a clean source —
# a frame-accurate cut can't ship as a copy.
#
# `container` is the source's extension. It defaults to unchecked so a caller that only has a codec (the
# builder's preview probe) keeps working; the save paths pass it, because they are the ones whose output
# has to survive being opened again later.
func classify_transcode(
	codec: String, pix_fmt: String, is_trim: bool, container: String = ""
) -> String:
	return transcode_reason(codec, pix_fmt, is_trim, container, PLAYABLE_VIDEO_CODECS)


# ── Trim / transcode output codec ────────────────────────────────────────────
# A trim always re-encodes (a stream copy can only cut on keyframes, and an author's cut point is
# wherever they put it), and the output codec has to match the source's FAMILY.
#
# The reason is the compatibility contract, not quality. A journey's MinVersion floor is derived from
# the codecs its content actually uses, so re-encoding an AV1 source down to H.264 would silently
# discard the floor that source earned, and re-encoding an H.264 source up to AV1 would silently
# raise it and lock out players on older builds for a change their author never asked for. Matching
# the family keeps the floor exactly where the author's own sources put it.
#
# VP8/VP9 map to AV1 rather than back to themselves: libvpx is by a wide margin the slowest encoder
# available, and VP8, VP9 and AV1 all became playable in the same release — so the floor is identical
# either way and the slow arm buys nothing.
const CODEC_FAMILIES: Dictionary = {
	"h264": "h264",
	"avc1": "h264",
	"avc": "h264",
	"hevc": "hevc",
	"h265": "hevc",
	"hvc1": "hevc",
	"hev1": "hevc",
	"av1": "av1",
	"av01": "av1",
	"vp9": "av1",
	"vp8": "av1",
}

# Encoder + quality args per family. CRF does NOT transfer across encoders — crf 22 on x264 is a
# very different target from crf 22 on SVT-AV1 — so each family carries its own, measured rather
# than guessed.
#
# Calibrated with libvmaf against the H.264 baseline (libx264 -preset fast -crf 22) on three real
# journey clips — a 1080p24 PMV, a 1080p60 animation, and a high-bitrate 1080p24 source — by
# scoring each candidate encode against the same window of the untouched source.
#
# The CRF that MATCHES the baseline turned out to vary by content (AV1 crf 18-31 across the three),
# because x264 crf 22 is itself not a constant quality: it scored 99.2 on the lightest source and
# 97.9 on the heaviest. These values therefore target the CONSERVATIVE end of that range, so a
# re-cut round is never perceptibly worse than the same cut used to be on H.264.
#
# The cost is accepted deliberately and is not uniform: across the calibration clips an AV1
# re-cut came out between 65% and 125% of the H.264 file it replaces (about parity on average).
# It grows on sources where x264 crf 22 was itself the weaker encode, because matching quality
# there means overshooting it. The size win from AV1 was never meant to come from this path —
# it comes from authors supplying AV1 sources, which are pooled untouched and never reach this
# table at all.
const ENCODE_PROFILES: Dictionary = {
	"h264": {"encoder": "libx264", "args": ["-preset", "fast", "-crf", "22"]},
	"hevc": {"encoder": "libx265", "args": ["-preset", "fast", "-crf", "20"]},
	"av1": {"encoder": "libsvtav1", "args": ["-preset", "8", "-crf", "22"]},
}

# Where a family lands when its own encoder isn't in the resolved ffmpeg. H.264 is the one encoder
# every build has.
const FALLBACK_FAMILY: String = "h264"


# The family a probed codec name belongs to. Unknown or unreadable codecs fall back to H.264: an
# unverifiable source is being re-encoded precisely because we can't tell what it is, so the widest
# compatible output is the right guess.
static func codec_family(codec: String) -> String:
	return str(CODEC_FAMILIES.get(codec.strip_edges().to_lower(), FALLBACK_FAMILY))


# The pixel format a re-encode should write. 10-bit survives a trim — it costs nothing on the GPU
# path and flattening it would undo the reason the source was 10-bit — and everything else
# normalises to 8-bit 4:2:0.
#
# yuvj420p is deliberately NOT passed through even though it's in SAFE_PIX_FMTS. It's the deprecated
# full-range JPEG variant: fine to decode, rejected by modern encoders as an output format.
static func output_pix_fmt(src_pix_fmt: String) -> String:
	return "yuv420p10le" if src_pix_fmt.strip_edges().to_lower() == "yuv420p10le" else "yuv420p"


# Resolves the encoder args for a source codec, given the set of encoder names the resolved ffmpeg
# actually offers. Pure, so the fallback rule is unit-testable without probing a binary.
#
# Returns {family, encoder, args, fell_back_from}. `fell_back_from` is "" on the normal path and
# names the family we WANTED when the encoder for it was missing — the caller surfaces that to the
# author, because a silent downgrade is the exact bug this table exists to prevent.
static func resolve_encode_profile(codec: String, available: Array) -> Dictionary:
	var family: String = codec_family(codec)
	var profile: Dictionary = ENCODE_PROFILES[family]
	if str(profile["encoder"]) in available:
		return {
			"family": family,
			"encoder": str(profile["encoder"]),
			"args": (profile["args"] as Array).duplicate(),
			"fell_back_from": "",
		}
	var fallback: Dictionary = ENCODE_PROFILES[FALLBACK_FAMILY]
	return {
		"family": FALLBACK_FAMILY,
		"encoder": str(fallback["encoder"]),
		"args": (fallback["args"] as Array).duplicate(),
		"fell_back_from": family if family != FALLBACK_FAMILY else "",
	}


# Encoder names the resolved ffmpeg offers, probed once and cached for the session. Left empty by a
# failed probe, which makes resolve_encode_profile fall every family back to H.264 — the safe
# direction when we can't tell what the binary is capable of.
var _available_encoders: PackedStringArray = []
var _encoders_probed: bool = false


func available_encoders() -> PackedStringArray:
	if _encoders_probed:
		return _available_encoders
	var out: Array = []
	var rc: int = OS.execute(
		resolve_binary("ffmpeg"), ["-hide_banner", "-encoders"], out, true, false
	)
	if rc != 0 or out.is_empty():
		# Deliberately NOT cached: a failed probe silently downgrades every trim to H.264 for the
		# rest of the session, so a transient failure should be retried rather than remembered.
		push_warning(
			(
				"MediaPoolService: ffmpeg -encoders failed (rc=%d, %d output chunks) — trims fall back to H.264."
				% [rc, out.size()]
			)
		)
		return _available_encoders
	_encoders_probed = true
	# EVERY element, not just out[0]. OS.execute can split a large capture across several array
	# entries, and this output is ~15 KB where the probes elsewhere in this file are a few dozen
	# bytes — reading only the first chunk truncated the list mid-alphabet and lost libsvtav1.
	var listing: String = ""
	for chunk: Variant in out:
		listing += str(chunk)
	for raw_line: String in listing.split("\n"):
		# " V....D libx264   libx264 H.264 / AVC ..." — flags first, encoder name second. The header
		# legend uses the same shape (" V..... = Video"), so the "=" rows are skipped explicitly.
		var parts: PackedStringArray = raw_line.strip_edges().split(" ", false)
		if parts.size() >= 2 and parts[0].begins_with("V") and parts[1] != "=":
			_available_encoders.append(parts[1])
	return _available_encoders


# Encoder profile for a source codec, resolved against what this build's ffmpeg actually offers.
func video_encode_profile(codec: String) -> Dictionary:
	return resolve_encode_profile(codec, available_encoders())


# The video codec args for re-encoding `input`: encoder, quality, and pixel format, matching the
# source's family so the output doesn't move the journey's MinVersion floor.
#
# The source is probed here rather than threaded in from the caller — every call site would otherwise
# have to carry it, and one ffprobe is nothing beside the encode it precedes.
func video_encode_args(input: String) -> PackedStringArray:
	var src: Dictionary = probe_stream_info(input)
	var profile: Dictionary = video_encode_profile(str(src["codec"]))
	var out: PackedStringArray = PackedStringArray(["-c:v", str(profile["encoder"])])
	for arg: String in profile["args"] as Array:
		out.append(arg)
	out.append("-pix_fmt")
	out.append(output_pix_fmt(str(src["pix_fmt"])))
	return out


# ── Animated images ──────────────────────────────────────────────────────────
#
# Godot cannot decode GIF at all (Image has no GIF loader), so an animated source can ONLY reach
# the runtime by being baked to H.264 here — which is why a GIF with no usable ffmpeg is a hard
# presave error rather than a soft fallback: there is no frame to fall back to either.
#
# Animated WebP is deliberately NOT supported: ffmpeg can *encode* it (libwebp_anim) but has never
# implemented *decoding* it — its only webp decoder is still-image, and that is not a build flag.
# Decoding it would mean bundling libwebp's anim_dump or hand-parsing the ANIM/ANMF container.
# Don't re-investigate this without reading HISTORY first.

# Sources an image surface can only show once baked. Extension-keyed: a still GIF is just as
# unreadable to Godot as an animated one, so the question this answers is "does this need a bake",
# not "does this move".
#
# Video containers are here because, past the input filter, there is no difference — bake_animation
# is `ffmpeg -i <anything>` and the runtime plays the H.264 result either way. It also picks up the
# AV1 / VP9 / WebM the bundled ffmpeg decodes, which is the workflow animated WebP could not serve.
# Safe to widen: this is only consulted for IMAGE fields (boss / storyboard / fork card) — round
# video never routes through it, so the overlap with JourneyData.VIDEO_EXTENSIONS is not a conflict.
const ANIMATED_EXTENSIONS: Array[String] = ["gif", "apng", "mp4", "m4v", "webm", "mkv", "mov"]

# Length short loops are repeated up to, and the repeat ceiling.
#
# Looping is a RESTART: `loop` lives on VideoStreamPlayer, not on VideoStreamPlayback (the engine
# re-plays the stream when it ends), so a short loop can hitch at the seam. Repeating a 2s loop out
# to ~40s means a card on screen for a few seconds never reaches it. The size cost is roughly
# LINEAR — x264's reference window is a few frames, so it cannot exploit the repetition, and
# disabling scenecut changes almost nothing (measured: 1%) — but it is trivial in absolute terms
# (a 380x240 loop is ~250 KB at 40s, noise beside the journey's videos).
const ANIM_TARGET_SECS: float = 40.0
const ANIM_MAX_REPEATS: int = 30

# Hard ceiling on a baked animation; anything longer is TRUNCATED (with the caller warning).
# These are decorations on a 380x240 card — nobody needs a 2-hour "boss image", and without a cap
# one would bake in full: a slow save and a huge pooled file. A GIF is self-limiting in practice
# (the format is too fat to be long), so this only started mattering once video sources were
# accepted. Sits above ANIM_TARGET_SECS so a repeated short loop never trips it.
const ANIM_MAX_SECS: float = 60.0

# Fit inside the box, preserving aspect and NEVER upscaling (min(iw,W) caps rather than stretches a
# small source), then force even dimensions — yuv420p demands them, and a source whose aspect lands
# on an odd height would otherwise fail the encode. %d placeholders are max width / max height.
const ANIM_SCALE_VF: String = "scale=w='min(iw,%d)':h='min(ih,%d)':force_original_aspect_ratio=decrease:flags=lanczos,scale=trunc(iw/2)*2:trunc(ih/2)*2"


# True when `path` needs baking before the runtime can display it.
func is_animated_source(path: String) -> bool:
	return path.get_extension().to_lower() in ANIMATED_EXTENSIONS


# Formats where a SINGLE-frame file is plausible, so the frame count has to decide still-vs-moving.
# Video containers are excluded deliberately: counting their frames means decoding the whole file
# (-count_frames), which blocks for seconds on a 60s source — and a one-frame .mp4 isn't a thing
# anyone ships.
const FRAME_COUNTED_EXTENSIONS: Array[String] = ["gif", "apng"]


# True when `path` actually moves, and so should be baked to video rather than stored as a still.
# Only GIF/APNG pay for a frame count; everything else is taken at face value (see above).
func probe_is_animated(path: String) -> bool:
	if not is_animated_source(path):
		return false
	if path.get_extension().to_lower() in FRAME_COUNTED_EXTENSIONS:
		return probe_frame_count(path) > 1
	return true


# Frames in the source's first video stream; 0 when unreadable. Uses -count_frames (an actual
# decode), so only call it for FRAME_COUNTED_EXTENSIONS — on a long video it is very slow.
func probe_frame_count(path: String) -> int:
	var out: Array = []
	var args: PackedStringArray = [
		"-v",
		"error",
		"-select_streams",
		"v:0",
		"-count_frames",
		"-show_entries",
		"stream=nb_read_frames",
		"-of",
		"csv=p=0",
		ProjectSettings.globalize_path(path),
	]
	if OS.execute(resolve_binary("ffprobe"), args, out, true, false) != 0 or out.is_empty():
		return 0
	return int((out[0] as String).strip_edges())


# Bakes an animated source into a looping H.264 .mp4 that fits `max_w` x `max_h`.
#
# ASYNC, like transcode_video, and for the same reason: this is a real encode (up to ANIM_MAX_SECS
# of video, at storyboard sizes), so running it through a blocking OS.execute freezes the whole app
# with no redraw and no way out. `on_progress` / `should_cancel` behave exactly as they do for
# transcode_video, so the save modal drives them identically.
#
# Returns {ok, truncated}: `truncated` means the source was longer than ANIM_MAX_SECS and only its
# first ANIM_MAX_SECS were baked — reported rather than silently swallowed, so the caller can tell
# the author which file got cut.
func bake_animation(
	input: String,
	output: String,
	max_w: int,
	max_h: int,
	on_progress: Callable = Callable(),
	should_cancel: Callable = Callable(),
	priority: int = EncodeGate.Priority.FOREGROUND
) -> Dictionary:
	var ticket: int = _gate.acquire(priority)
	while not _gate.granted(ticket):
		await _gate.turn_granted
	# Contract §2.7: at least one suspension between grant and release, so release never runs
	# synchronously out of the predecessor's turn_granted emission (nested emission, and the
	# waiter that resumes from it is not awaiting yet). The bodies cannot supply it — every one
	# of them has paths that return without ever awaiting (process start fails, cancel on the
	# very first poll), so the guarantee has to sit here, in the wrapper.
	await get_tree().process_frame
	var res: Dictionary = await _bake_animation_gated(
		input, output, max_w, max_h, on_progress, _effective_cancel(should_cancel, ticket), priority
	)
	await _discard_part(output)  # no-op after a successful rename
	_gate.release(ticket)
	return res


# The bake itself. Holds no ticket of its own and never touches _gate — every return
# path here is covered by the single release in the wrapper above.
func _bake_animation_gated(
	input: String,
	output: String,
	max_w: int,
	max_h: int,
	on_progress: Callable,
	should_cancel: Callable,
	priority: int
) -> Dictionary:
	var out_abs: String = ProjectSettings.globalize_path(output)
	var progress_abs: String = ProjectSettings.globalize_path(PROGRESS_FILE)
	var pf: FileAccess = FileAccess.open(progress_abs, FileAccess.WRITE)
	if pf:
		pf.close()

	var dur: float = probe_duration_seconds(input)
	var truncated: bool = dur > ANIM_MAX_SECS
	# A source long enough to truncate is self-evidently long enough not to need repeating.
	var repeats: int = 1
	if dur > 0.0 and not truncated:
		repeats = clampi(int(ceil(ANIM_TARGET_SECS / dur)), 1, ANIM_MAX_REPEATS)
	# What the OUTPUT will be — the progress bar reads ffmpeg's out_time against it.
	var out_secs: float = ANIM_MAX_SECS if truncated else dur * repeats

	var args: PackedStringArray = ["-y", "-hide_banner", "-loglevel", "error"]
	if repeats > 1:
		args.append_array(["-stream_loop", str(repeats - 1)])  # -stream_loop N = N EXTRA plays
	args.append_array(["-i", ProjectSettings.globalize_path(input)])
	if truncated:
		args.append_array(["-t", "%.3f" % ANIM_MAX_SECS])  # after -i: limits the OUTPUT length
	if priority == EncodeGate.Priority.BACKGROUND:
		args.append_array(["-threads", str(BACKGROUND_ENCODE_THREADS)])
	(
		args
		. append_array(
			[
				"-vf",
				ANIM_SCALE_VF % [max_w, max_h],
				# Audio is dropped deliberately, not incidentally: these are decorative loops behind
				# a round's own video and music, and a source's soundtrack has no business there.
				"-an",
				"-c:v",
				"libx264",
				"-preset",
				"fast",
				"-crf",
				"23",
				"-pix_fmt",
				"yuv420p",
				"-movflags",
				"+faststart",
				"-progress",
				progress_abs,
				_part_path(out_abs),
			]
		)
	)

	_pid = OS.create_process(resolve_binary("ffmpeg"), args)
	if _pid <= 0:
		# The binary the memo says works is gone (uninstalled, drive unplugged) or unspawnable.
		# Drop the memo so the next is_available() probes for real — otherwise the caller keeps
		# reporting "bake failed" for what is really "ffmpeg unavailable", for the whole session.
		_avail_key = ""
		return {"ok": false, "truncated": false}

	while OS.is_process_running(_pid):
		if should_cancel.is_valid() and should_cancel.call():
			OS.kill(_pid)
			_pid = -1
			return {"ok": false, "truncated": false}
		_poll_progress(progress_abs, out_secs, on_progress)
		await get_tree().create_timer(0.4).timeout

	_poll_progress(progress_abs, out_secs, on_progress)  # flush "progress=end"
	# ffmpeg can end ITSELF with an error (disk full, broken source) after already writing frames.
	# The loop above exits normally in that case too, so without this check _publish_part would
	# rename a partial file into place as a finished bake. Only self-terminated processes reach
	# here — every kill path returns above — so a non-zero code always means a real ffmpeg error.
	var finished_pid: int = _pid
	_pid = -1
	if OS.get_process_exit_code(finished_pid) != 0:
		return {"ok": false, "truncated": false}
	var ok: bool = _publish_part(out_abs)
	return {"ok": ok, "truncated": truncated and ok}


# Writes the source's FIRST frame as a PNG, scaled by the same rules. Used both for a single-frame
# GIF and as the fallback when a bake fails — Godot can't read GIF, so even a still one must be
# converted to something it can load.
func extract_first_frame(input: String, output: String, max_w: int, max_h: int) -> bool:
	var args: PackedStringArray = [
		"-y",
		"-hide_banner",
		"-loglevel",
		"error",
		"-i",
		ProjectSettings.globalize_path(input),
		"-vf",
		ANIM_SCALE_VF % [max_w, max_h],
		"-frames:v",
		"1",
		ProjectSettings.globalize_path(output),
	]
	var out: Array = []
	if OS.execute(resolve_binary("ffmpeg"), args, out, true, false) != 0:
		return false
	return FileAccess.file_exists(ProjectSettings.globalize_path(output))


# ── Transcode ────────────────────────────────────────────────────────────────


# Re-encodes `input` to H.264 .mp4 at `output`, optionally baking a trim window.
# `duration` is the (trimmed) output length in seconds — drives the progress bar.
# `on_progress`, when valid, is called as on_progress.call(fraction, current_s,
# total_s, speed) each poll. `should_cancel`, when valid, is polled each loop; a
# true return kills ffmpeg and returns false. Returns true only when the output
# file exists at the end.
func transcode_video(
	input: String,
	output: String,
	duration: float,
	trim_in_ms: int = 0,
	trim_out_ms: int = 0,
	on_progress: Callable = Callable(),
	should_cancel: Callable = Callable(),
	priority: int = EncodeGate.Priority.FOREGROUND
) -> bool:
	var ticket: int = _gate.acquire(priority)
	while not _gate.granted(ticket):
		await _gate.turn_granted
	# Contract §2.7: guarantees a suspension between grant and release (see bake_animation).
	await get_tree().process_frame
	var ok: bool = await _transcode_video_gated(
		input,
		output,
		duration,
		trim_in_ms,
		trim_out_ms,
		on_progress,
		_effective_cancel(should_cancel, ticket),
		priority
	)
	await _discard_part(output)  # no-op after a successful rename
	_gate.release(ticket)
	return ok


# The encode itself. Holds no ticket of its own and never touches _gate — every return
# path here is covered by the single release in the wrapper above.
func _transcode_video_gated(
	input: String,
	output: String,
	duration: float,
	trim_in_ms: int,
	trim_out_ms: int,
	on_progress: Callable,
	should_cancel: Callable,
	priority: int
) -> bool:
	var out_abs: String = ProjectSettings.globalize_path(output)
	var progress_abs: String = ProjectSettings.globalize_path(PROGRESS_FILE)
	# Truncate any prior progress file so old data doesn't mislead the parser.
	var pf: FileAccess = FileAccess.open(progress_abs, FileAccess.WRITE)
	if pf:
		pf.close()

	var args: PackedStringArray = []
	args.append_array(["-y", "-hide_banner", "-loglevel", "error"])
	# Trim bake: -ss before -i (fast input seek; frame-accurate because we always
	# re-encode) + an explicit -t duration after it. `duration` is already the
	# trimmed length, so the progress bar stays honest.
	if trim_in_ms > 0:
		args.append_array(["-ss", "%.3f" % (trim_in_ms / 1000.0)])
	args.append_array(["-i", ProjectSettings.globalize_path(input)])
	if trim_out_ms > 0 or trim_in_ms > 0:
		var trim_len: float = duration
		if trim_len > 0.0:
			args.append_array(["-t", "%.3f" % trim_len])
	if priority == EncodeGate.Priority.BACKGROUND:
		args.append_array(["-threads", str(BACKGROUND_ENCODE_THREADS)])
	# The output codec matches the source family so a trim never moves this journey's MinVersion
	# floor — see CODEC_FAMILIES. Also carries a 10-bit source through instead of flattening it.
	args.append_array(video_encode_args(input))
	(
		args
		. append_array(
			[
				"-c:a",
				"aac",
				"-b:a",
				"192k",
				"-progress",
				progress_abs,
				_part_path(out_abs),
			]
		)
	)

	_pid = OS.create_process(resolve_binary("ffmpeg"), args)
	if _pid <= 0:
		_avail_key = ""  # spawn failed: re-probe availability (see _bake_animation_gated)
		return false

	while OS.is_process_running(_pid):
		if should_cancel.is_valid() and should_cancel.call():
			OS.kill(_pid)
			_pid = -1
			return false
		_poll_progress(progress_abs, duration, on_progress)
		await get_tree().create_timer(0.4).timeout

	# Final poll to flush "progress=end".
	_poll_progress(progress_abs, duration, on_progress)
	# A self-terminated ffmpeg error must not publish its partial file (see _bake_animation_gated).
	var finished_pid: int = _pid
	_pid = -1
	if OS.get_process_exit_code(finished_pid) != 0:
		return false
	return _publish_part(out_abs)


# ── Segment baking (trim / looping / cuts / rearrangement) ───────────────────
# Scratch space for the per-segment encodes + the concat list. Wiped before and after every
# bake, so a crashed save never leaves a partial segment to be concatenated into a later one.
const SEGMENT_BAKE_DIR: String = "user://segment_bake"


# Bakes a segment list into one clip: each [in_ms, out_ms] window of the source, concatenated in
# list order. Timestamps are SOURCE ms, `out_ms` 0 means "to the end", audio is preserved. Trim,
# looping, cuts and rearrangement all come through here — they differ only in the list.
#
# Encodes each DISTINCT window once and names it per row in the concat file, so N repeats cost
# one encode. Concat with -c copy needs identical codec params across segments, which holds
# because every segment shares the same encode settings.
# Async + cancel + progress like transcode_video; `on_progress` spans all encodes.
func bake_edl(
	input: String,
	output: String,
	segments: Array,
	on_progress: Callable = Callable(),
	should_cancel: Callable = Callable(),
	priority: int = EncodeGate.Priority.FOREGROUND
) -> bool:
	# Both validation returns stay OUTSIDE the gate: they precede every process start, so
	# taking a ticket for them would pre-empt a running background job for a call that
	# encodes nothing at all.
	if segments.is_empty():
		return false

	# Open ends (out_ms <= 0) are the ONLY thing src_end_ms is needed for, and part windows
	# are closed by construction — so the blocking probe is skipped for them. Without this
	# the running session stalls at every part start, twenty times a session.
	var needs_probe: bool = false
	for seg: Dictionary in segments:
		if int(seg.get("out_ms", 0)) <= 0:
			needs_probe = true
			break
	# Resolve open ends against the real duration (a pure caller can't probe).
	var src_end_ms: int = 0
	if needs_probe:
		src_end_ms = roundi(probe_duration_seconds(input) * 1000.0)

	var playback: Array = []  # closed windows, in playback order
	for seg: Dictionary in segments:
		var start_ms: int = maxi(0, int(seg.get("in_ms", 0)))
		var end_ms: int = int(seg.get("out_ms", 0))
		if end_ms <= 0:
			end_ms = src_end_ms
		if end_ms > start_ms:
			playback.append({"start_ms": start_ms, "end_ms": end_ms})
	if playback.is_empty():
		return false

	var ticket: int = _gate.acquire(priority)
	while not _gate.granted(ticket):
		await _gate.turn_granted
	# Contract §2.7: guarantees a suspension between grant and release (see bake_animation). Needed
	# here too: if the very first _encode_segment fails at process start, the body returns unawaited.
	await get_tree().process_frame
	var ok: bool = await _bake_edl_gated(
		input, output, playback, on_progress, _effective_cancel(should_cancel, ticket), priority
	)
	await _discard_part(output)  # no-op after a successful rename
	_gate.release(ticket)
	return ok


# The bake itself: one ticket covers ALL segment encodes plus the concat. Holds no ticket
# of its own and never touches _gate — every return path here is covered by the single
# release in the wrapper above.
func _bake_edl_gated(
	input: String,
	output: String,
	playback: Array,
	on_progress: Callable,
	should_cancel: Callable,
	priority: int
) -> bool:
	var out_abs: String = ProjectSettings.globalize_path(output)

	# Distinct windows, keyed by span — repeats collapse to one encode.
	var distinct: Dictionary = {}  # key → {start_ms, end_ms, name}
	for win: Dictionary in playback:
		var key: String = _window_key(win)
		if not distinct.has(key):
			distinct[key] = {
				"start_ms": int(win["start_ms"]),
				"end_ms": int(win["end_ms"]),
				"name": "seg%d" % distinct.size(),
			}

	var dir_abs: String = ProjectSettings.globalize_path(SEGMENT_BAKE_DIR)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	_clear_segment_bake_dir()

	# One continuous progress bar spanning the distinct encodes.
	var total_dur: float = 0.0
	for key: String in distinct:
		total_dur += _window_secs(distinct[key])
	total_dur = maxf(0.001, total_dur)

	var encoded: Dictionary = {}  # key → encoded file path
	var done: float = 0.0
	for key: String in distinct:
		var win: Dictionary = distinct[key]
		var seg_dur: float = _window_secs(win)
		var seg_out: String = dir_abs + "/" + str(win["name"]) + ".mp4"
		# Map this window's local progress into the overall [done, done+seg_dur] range. Routed
		# through a helper so the lambda stays one line.
		var base: float = done
		var wrapped: Callable = func(f: float, _c: float, _t: float, spd: String) -> void:
			_forward_segment_progress(on_progress, base, f, seg_dur, total_dur, spd)
		var ok: bool = await _encode_segment(
			input,
			seg_out,
			float(int(win["start_ms"])) / 1000.0,
			seg_dur,
			wrapped,
			should_cancel,
			priority
		)
		if not ok:
			_clear_segment_bake_dir()
			return false
		encoded[key] = seg_out
		done += seg_dur

	# Concat list in playback order — a repeated window just names its file again.
	# Forward slashes + single quotes for the demuxer.
	var list_abs: String = dir_abs + "/list.txt"
	var lf: FileAccess = FileAccess.open(SEGMENT_BAKE_DIR + "/list.txt", FileAccess.WRITE)
	if lf == null:
		_clear_segment_bake_dir()
		return false
	for win: Dictionary in playback:
		lf.store_line("file '%s'" % str(encoded[_window_key(win)]).replace("\\", "/"))
	lf.close()

	# Stream-copy concat (no re-encode) — fast, and the segments already share codec params.
	var cat_args: PackedStringArray = [
		"-y",
		"-hide_banner",
		"-loglevel",
		"error",
		"-f",
		"concat",
		"-safe",
		"0",
		"-i",
		list_abs,
		"-c",
		"copy",
		_part_path(out_abs),
	]
	_pid = OS.create_process(resolve_binary("ffmpeg"), cat_args)
	if _pid <= 0:
		_avail_key = ""  # spawn failed: re-probe availability (see _bake_animation_gated)
		_clear_segment_bake_dir()
		return false
	while OS.is_process_running(_pid):
		if should_cancel.is_valid() and should_cancel.call():
			OS.kill(_pid)
			_pid = -1
			_clear_segment_bake_dir()
			return false
		await get_tree().create_timer(0.2).timeout
	# A self-terminated ffmpeg error must not publish its partial file (see _bake_animation_gated).
	var finished_pid: int = _pid
	_pid = -1
	if OS.get_process_exit_code(finished_pid) != 0:
		_clear_segment_bake_dir()
		return false

	var ok_final: bool = _publish_part(out_abs)
	_clear_segment_bake_dir()
	return ok_final


# Forwards a segment's local progress fraction `f` to the caller's `cb`, remapped into the overall
# bake by the segment's `base` offset / `total`. Skips an invalid caller callback.
# Dedup key for a window. Used to build the encode map AND to look files back up for the
# concat list — one function so the two can't drift into a missing-key crash.
func _window_key(win: Dictionary) -> String:
	return "%d-%d" % [int(win["start_ms"]), int(win["end_ms"])]


func _window_secs(win: Dictionary) -> float:
	return float(int(win["end_ms"]) - int(win["start_ms"])) / 1000.0


func _forward_segment_progress(
	cb: Callable, base: float, f: float, seg_dur: float, total: float, spd: String
) -> void:
	if cb.is_valid():
		cb.call((base + f * seg_dur) / total, base + f * seg_dur, total, spd)


# Re-encodes one [start_s, start_s+dur_s] window of `input` to `output` with the shared segment
# settings (so every segment concats cleanly). Async + cancel + progress, like transcode_video.
#
# NOT gated: it always runs under bake_edl's ticket, so it must never take one of its own.
# `priority` is here purely for the -threads decision.
func _encode_segment(
	input: String,
	output: String,
	start_s: float,
	dur_s: float,
	on_progress: Callable,
	should_cancel: Callable,
	priority: int = EncodeGate.Priority.FOREGROUND
) -> bool:
	var progress_abs: String = ProjectSettings.globalize_path(PROGRESS_FILE)
	var pf: FileAccess = FileAccess.open(progress_abs, FileAccess.WRITE)
	if pf:
		pf.close()

	# -ss before -i (fast seek) + -t duration — same frame-accurate-on-re-encode approach as trim.
	var args: PackedStringArray = ["-y", "-hide_banner", "-loglevel", "error"]
	if start_s > 0.0:
		args.append_array(["-ss", "%.3f" % start_s])
	args.append_array(["-i", ProjectSettings.globalize_path(input)])
	if priority == EncodeGate.Priority.BACKGROUND:
		args.append_array(["-threads", str(BACKGROUND_ENCODE_THREADS)])
	# Same family-matching rule as the trim path above.
	args.append_array(video_encode_args(input))
	(
		args
		. append_array(
			[
				"-t",
				"%.3f" % dur_s,
				"-c:a",
				"aac",
				"-b:a",
				"192k",
				"-progress",
				progress_abs,
				ProjectSettings.globalize_path(output),
			]
		)
	)
	_pid = OS.create_process(resolve_binary("ffmpeg"), args)
	if _pid <= 0:
		_avail_key = ""  # spawn failed: re-probe availability (see _bake_animation_gated)
		return false
	while OS.is_process_running(_pid):
		if should_cancel.is_valid() and should_cancel.call():
			OS.kill(_pid)
			_pid = -1
			return false
		_poll_progress(progress_abs, dur_s, on_progress)
		await get_tree().create_timer(0.4).timeout
	_poll_progress(progress_abs, dur_s, on_progress)
	# A self-terminated ffmpeg error must not yield a usable segment (see _bake_animation_gated):
	# a partial segN.mp4 passes the file_exists check below and would be concat'd into the clip.
	var finished_pid: int = _pid
	_pid = -1
	if OS.get_process_exit_code(finished_pid) != 0:
		return false
	return FileAccess.file_exists(ProjectSettings.globalize_path(output))


# Wipes the loop-bake scratch dir (temp segments + concat list).
func _clear_segment_bake_dir() -> void:
	var d: DirAccess = DirAccess.open(SEGMENT_BAKE_DIR)
	if d == null:
		return
	d.list_dir_begin()
	var fn: String = d.get_next()
	while fn != "":
		if not d.current_is_dir():
			d.remove(fn)
		fn = d.get_next()
	d.list_dir_end()


func _poll_progress(progress_path: String, duration: float, on_progress: Callable) -> void:
	if not on_progress.is_valid():
		return
	var f: FileAccess = FileAccess.open(progress_path, FileAccess.READ)
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	var out_time_us: int = 0
	var speed: String = ""
	for raw_line: String in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("out_time_us="):
			out_time_us = line.substr(12).to_int()
		elif line.begins_with("out_time_ms="):
			out_time_us = line.substr(12).to_int()
		elif line.begins_with("speed="):
			speed = line.substr(6)
	var current_seconds: float = out_time_us / 1_000_000.0
	var progress: float = 0.0
	if duration > 0.0:
		progress = clampf(current_seconds / duration, 0.0, 1.0)
	on_progress.call(progress, current_seconds, duration, speed)
