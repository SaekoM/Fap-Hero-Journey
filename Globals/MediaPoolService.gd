extends Node
## Graph-agnostic media operations shared by the journey builder's save pipeline
## and the randomizer library. Resolves the ffmpeg / ffprobe binaries, probes a
## source video (codec / pixel format / duration), decides whether a source needs
## re-encoding for the runtime decoder (EIRTeam.FFmpeg decodes H.264 only), and
## runs the actual transcode.
##
## Pure I/O + process control: it owns no journey / graph / UI state. Progress and
## cancellation are injected as Callables, so any caller wires its own modal — the
## builder feeds its save-progress modal, the randomizer its library-add modal.
## Extracted from JourneyBuilder so both paths share one implementation.

# Codecs the runtime decoder treats as H.264 (ffprobe codec_name variants).
const H264_NAMES: Array[String] = ["h264", "avc1", "avc"]

# Pixel formats EIRTeam.FFmpeg handles: 8-bit 4:2:0, both the standard (yuv420p)
# and full-range JPEG (yuvj420p) variants. Anything else (10-bit, 4:2:2, 4:4:4) is
# re-encoded even when the codec is already H.264 — the "it's h264 but still won't
# play" cases. Kept broad to avoid needless re-encodes.
const SAFE_PIX_FMTS: Array[String] = ["yuv420p", "yuvj420p"]

# Scratch file ffmpeg writes -progress lines to; polled to drive the progress bar.
const PROGRESS_FILE: String = "user://transcode_progress.txt"

# PID of the in-flight ffmpeg encode (-1 when idle). Owned here so a caller's
# cancel callback only needs to flip a bool — transcode_video does the kill.
var _pid: int = -1

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


func is_available() -> bool:
	var out: Array = []
	return OS.execute(resolve_binary("ffprobe"), ["-version"], out, true, false) == 0


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
func is_baked_animation(path: String, cap: Vector2i) -> bool:
	var info: Dictionary = probe_stream_info(path)
	if not (str(info.get("codec", "")) in H264_NAMES):
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


# Decides whether a probed source needs re-encoding, and why. Returns the reason
# string used for the plan key / modal ("" = no encode needed). A source is
# planned when its codec can't be read (re-encode to be safe), isn't H.264, or is
# H.264 with an undecodable pixel format (10-bit, 4:2:2, …). `is_trim` forces an
# encode even on a clean source — a frame-accurate cut can't ship as a copy.
func classify_transcode(codec: String, pix_fmt: String, is_trim: bool) -> String:
	var reason: String = ""
	if codec == "":
		reason = "unverifiable"  # couldn't read — re-encode to be safe
	elif not (codec in H264_NAMES):
		reason = codec  # wrong codec (HEVC/AV1/VP9/…)
	elif pix_fmt != "" and not (pix_fmt in SAFE_PIX_FMTS):
		reason = "%s %s" % [codec, pix_fmt]  # h264 but undecodable profile
	if is_trim and reason == "":
		reason = "trim"  # fine codec, but the cut itself demands the encode
	return reason


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
	should_cancel: Callable = Callable()
) -> Dictionary:
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
				ProjectSettings.globalize_path(output),
			]
		)
	)

	_pid = OS.create_process(resolve_binary("ffmpeg"), args)
	if _pid <= 0:
		return {"ok": false, "truncated": false}

	while OS.is_process_running(_pid):
		if should_cancel.is_valid() and should_cancel.call():
			OS.kill(_pid)
			_pid = -1
			return {"ok": false, "truncated": false}
		_poll_progress(progress_abs, out_secs, on_progress)
		await get_tree().create_timer(0.4).timeout

	_poll_progress(progress_abs, out_secs, on_progress)  # flush "progress=end"
	_pid = -1
	var ok: bool = FileAccess.file_exists(ProjectSettings.globalize_path(output))
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
	should_cancel: Callable = Callable()
) -> bool:
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
	(
		args
		. append_array(
			[
				"-c:v",
				"libx264",
				"-preset",
				"fast",
				"-crf",
				"22",
				"-pix_fmt",
				"yuv420p",
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
	_pid = -1
	return FileAccess.file_exists(output)


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
	should_cancel: Callable = Callable()
) -> bool:
	if segments.is_empty():
		return false

	# Resolve open ends against the real duration (a pure caller can't probe).
	var src_end_ms: int = roundi(probe_duration_seconds(input) * 1000.0)
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
			input, seg_out, float(int(win["start_ms"])) / 1000.0, seg_dur, wrapped, should_cancel
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
		ProjectSettings.globalize_path(output),
	]
	_pid = OS.create_process(resolve_binary("ffmpeg"), cat_args)
	if _pid <= 0:
		_clear_segment_bake_dir()
		return false
	while OS.is_process_running(_pid):
		if should_cancel.is_valid() and should_cancel.call():
			OS.kill(_pid)
			_pid = -1
			_clear_segment_bake_dir()
			return false
		await get_tree().create_timer(0.2).timeout
	_pid = -1

	var ok_final: bool = FileAccess.file_exists(ProjectSettings.globalize_path(output))
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
func _encode_segment(
	input: String,
	output: String,
	start_s: float,
	dur_s: float,
	on_progress: Callable,
	should_cancel: Callable
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
	(
		args
		. append_array(
			[
				"-t",
				"%.3f" % dur_s,
				"-c:v",
				"libx264",
				"-preset",
				"fast",
				"-crf",
				"22",
				"-pix_fmt",
				"yuv420p",
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
		return false
	while OS.is_process_running(_pid):
		if should_cancel.is_valid() and should_cancel.call():
			OS.kill(_pid)
			_pid = -1
			return false
		_poll_progress(progress_abs, dur_s, on_progress)
		await get_tree().create_timer(0.4).timeout
	_poll_progress(progress_abs, dur_s, on_progress)
	_pid = -1
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
