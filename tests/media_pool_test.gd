extends GdUnitTestSuite

# Shared content pool. Unit-tests the pure dedup planner and the fingerprint/
# naming primitives that the save flow uses to store each per-round asset (video /
# funscript / axis / vib / boss image) once under content/m_<fingerprint>.<ext>.
# The file-I/O path (transcode/copy + skip-on-reuse) stays manual/integration —
# here we pin the decision logic that decides which sources get written vs reused.

const TEST_DIR := "user://test_media_pool"


func after() -> void:
	JourneyData.delete_dir_recursive(TEST_DIR)


# pooled_media_rel composes the journey-root-relative pool path. Source-less → legacy m_ spelling.
func test_pooled_media_rel_shape() -> void:
	assert_str(JourneyData.pooled_media_rel("abc123", "mp4")).is_equal("content/m_abc123.mp4")
	assert_str(JourneyData.pooled_media_rel("def456", "funscript")).is_equal(
		"content/m_def456.funscript"
	)


# With a source, the pooled name gains a readable prefix (browsable) while the fingerprint still tails it.
func test_pooled_media_rel_readable_prefix() -> void:
	assert_str(JourneyData.pooled_media_rel("abc123", "mp4", "G:/vids/SmugBlueFaun.mp4")).is_equal(
		"content/SmugBlueFaun__abc123.mp4"
	)


# Odd characters/spaces are sanitized to single underscores; extensions are dropped from the prefix.
func test_pooled_media_rel_sanitizes_prefix() -> void:
	(
		assert_str(
			JourneyData.pooled_media_rel("f0", "funscript", "/x/My Clip (v2)!.pitch.funscript")
		)
		. is_equal("content/My_Clip_v2__f0.funscript")
	)


# Re-pooling an already-pooled file recovers the readable stem instead of growing it (name__fp__fp2…).
# A real fingerprint is 16 hex chars — only that exact suffix is stripped.
func test_pooled_media_rel_repool_does_not_grow() -> void:
	# the "source" is itself a previously-pooled file
	(
		assert_str(
			JourneyData.pooled_media_rel(
				"1111222233334444", "mp4", "content/Clip__abc1230000000000.mp4"
			)
		)
		. is_equal("content/Clip__1111222233334444.mp4")
	)
	# a legacy m_<hex> source has no recoverable name → the "media" fallback
	(
		assert_str(
			JourneyData.pooled_media_rel(
				"1111222233334444", "mp4", "content/m_abc1230000000000.mp4"
			)
		)
		. is_equal("content/media__1111222233334444.mp4")
	)


# The same fingerprint always yields the same source ⇒ same prefix, so dedup is unaffected: plan_media_pool
# still writes once per fingerprint even with readable prefixes.
func test_plan_media_pool_readable_prefix_still_dedups() -> void:
	var sources := [
		{"fingerprint": "aaa", "ext": "mp4", "src": "/v/intro.mp4"},
		{"fingerprint": "aaa", "ext": "mp4", "src": "/v/intro.mp4"},  # same clip reused
	]
	var plan := JourneyData.plan_media_pool(sources)
	assert_str(plan[0]["rel"]).is_equal("content/intro__aaa.mp4")
	assert_bool(plan[1]["copy"]).is_false()  # dedup: skipped
	assert_str(plan[1]["rel"]).is_equal("content/intro__aaa.mp4")


# plan_media_pool: the first sighting of a (fingerprint,ext) pool path is a copy;
# every repeat references the same rel and is skipped.
func test_plan_media_pool_dedups_repeats() -> void:
	var sources := [
		{"fingerprint": "aaa", "ext": "mp4"},  # round 1 video
		{"fingerprint": "bbb", "ext": "funscript"},  # round 1 script
		{"fingerprint": "aaa", "ext": "mp4"},  # round 2 reuses the SAME video
		{"fingerprint": "ccc", "ext": "mp4"},  # round 2 distinct video
		{"fingerprint": "bbb", "ext": "funscript"},  # round 2 reuses round 1's script
	]
	var plan := JourneyData.plan_media_pool(sources)
	assert_int(plan.size()).is_equal(5)

	# First video + script are copied.
	assert_bool(plan[0]["copy"]).is_true()
	assert_str(plan[0]["rel"]).is_equal("content/m_aaa.mp4")
	assert_bool(plan[1]["copy"]).is_true()
	assert_str(plan[1]["rel"]).is_equal("content/m_bbb.funscript")

	# Reused video → same rel, skipped.
	assert_bool(plan[2]["copy"]).is_false()
	assert_str(plan[2]["rel"]).is_equal("content/m_aaa.mp4")

	# Distinct video → copied.
	assert_bool(plan[3]["copy"]).is_true()
	assert_str(plan[3]["rel"]).is_equal("content/m_ccc.mp4")

	# Reused script → skipped.
	assert_bool(plan[4]["copy"]).is_false()
	assert_str(plan[4]["rel"]).is_equal("content/m_bbb.funscript")

	# Exactly 3 physical writes for 5 references — the disk-savings win.
	var copies := plan.filter(func(e: Dictionary) -> bool: return e["copy"])
	assert_int(copies.size()).is_equal(3)


# An empty source list plans nothing.
func test_plan_media_pool_empty() -> void:
	assert_array(JourneyData.plan_media_pool([])).is_empty()


# media_fingerprint is stable for the same bytes and changes when the file does.
# (Identity = path + size + mtime, not a content hash — so a different size is
# enough to diverge.)
func test_media_fingerprint_stability() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	var path := TEST_DIR + "/clip.bin"

	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("hello")
	f.close()
	var fp1 := JourneyData.media_fingerprint(path)
	var fp2 := JourneyData.media_fingerprint(path)
	assert_str(fp1).is_equal(fp2)  # same file → same fingerprint
	assert_int(fp1.length()).is_equal(16)  # short hex, not a full sha256

	# Rewrite with a different size → different fingerprint.
	var g := FileAccess.open(path, FileAccess.WRITE)
	g.store_string("a much longer body of bytes")
	g.close()
	assert_str(JourneyData.media_fingerprint(path)).is_not_equal(fp1)


# Two different source paths fingerprint differently (so a video and its
# funscript never collide into one pool entry).
func test_media_fingerprint_distinct_paths() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	var a := TEST_DIR + "/a.bin"
	var b := TEST_DIR + "/b.bin"
	for p: String in [a, b]:
		var f := FileAccess.open(p, FileAccess.WRITE)
		f.store_string("same bytes")
		f.close()
	assert_str(JourneyData.media_fingerprint(a)).is_not_equal(JourneyData.media_fingerprint(b))


# ── Incremental save: pooled-file reuse ──────────────────────────────────────


# is_pooled_content_path recognises a journey's own pooled files (legacy m_<16 hex> and the readable
# <name>__<16 hex> under content/) and nothing else — the gate that keeps hardlinks off an author's
# original source. Real fingerprints are 16 hex chars. MediaPoolService.is_pooled_content_file
# delegates here; testing the pure static avoids autoload-reload flakiness.
func test_is_pooled_content_file() -> void:
	(
		assert_bool(JourneyData.is_pooled_content_path("user://j/content/m_abc1230000000000.mp4"))
		. is_true()
	)
	(
		assert_bool(
			JourneyData.is_pooled_content_path("user://j/content/Clip__abc1230000000000.mp4")
		)
		. is_true()
	)
	(
		assert_bool(
			JourneyData.is_pooled_content_path(
				"user://j/content/Clip__abc1230000000000.pitch.funscript"
			)
		)
		. is_true()
	)
	# An original source (any folder, non-pool name) must NOT qualify.
	assert_bool(JourneyData.is_pooled_content_path("/Videos/myclip.mp4")).is_false()
	assert_bool(JourneyData.is_pooled_content_path("user://j/media/cover.png")).is_false()
	assert_bool(JourneyData.is_pooled_content_path("user://j/content/other.mp4")).is_false()
	# A short/non-16-hex tail is not a real fingerprint → not treated as pooled.
	assert_bool(JourneyData.is_pooled_content_path("user://j/content/m_abc123.mp4")).is_false()


# try_hardlink makes a second name for the same bytes; editing one is visible through the other
# (same inode), and it never clobbers an existing destination.
func test_try_hardlink_shares_data() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR + "/content"))
	var src := TEST_DIR + "/content/m_src.txt"
	var f := FileAccess.open(src, FileAccess.WRITE)
	f.store_string("pooled-bytes")
	f.close()

	var dst := TEST_DIR + "/staging/m_dst.txt"
	var linked: bool = MediaPoolService.try_hardlink(src, dst)
	# Hardlinks need same-volume support; skip the assertion if the platform/test dir can't (the
	# save path falls back to copy there anyway). When it DID link, the data must be shared.
	if linked:
		assert_str(FileAccess.get_file_as_string(dst)).is_equal("pooled-bytes")
		# Won't overwrite an existing destination.
		assert_bool(MediaPoolService.try_hardlink(src, dst)).is_false()


# ── The transcode gate ───────────────────────────────────────────────────────
#
# transcode_reason is the pure half of classify_transcode: given what a probe found and what this build
# can play, does the file need re-encoding and why. The reason string is shown to the author, so the
# cases below pin the wording as much as the yes/no.

# The real set the gate uses, so these cases move if the shipped decoders ever do.
const PLAYABLE: Array[String] = MediaPoolService.PLAYABLE_VIDEO_CODECS


func test_a_playable_source_needs_no_encode() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("h264", "yuv420p", false, "mp4", PLAYABLE))
		. is_equal("")
	)


# VP9 decodes in the shipped build, so a webm is kept rather than re-encoded. This is the case the
# old H.264-only gate got wrong — it re-encoded every VP9 file for nothing.
func test_vp9_is_kept() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("vp9", "yuv420p", false, "webm", PLAYABLE))
		. is_equal("")
	)


func test_an_undecodable_codec_is_named_as_the_reason() -> void:
	(
		assert_str(
			MediaPoolService.transcode_reason("mpeg2video", "yuv420p", false, "mp4", PLAYABLE)
		)
		. is_equal("mpeg2video")
	)


# AV1 is kept, not re-encoded — the decoders now ship with it. This is the case the whole FFmpeg
# rebuild existed to change, so it is worth asserting against the REAL codec list rather than a literal.
func test_av1_is_kept() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("av1", "yuv420p", false, "mp4", PLAYABLE))
		. is_equal("")
	)


# 8-bit HEVC is kept — the build that gained dav1d also enabled the hevc decoder.
func test_hevc_is_kept_when_8_bit() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("hevc", "yuv420p", false, "mp4", PLAYABLE))
		. is_equal("")
	)


# ...and 10-bit is kept too. HEVC and AV1 are commonly 10-bit, so this is the case that decides whether
# most real files are copied or converted. It costs ~1.7x the CPU of 8-bit (measured; see SAFE_PIX_FMTS)
# and was judged affordable — this test is what will fail if somebody narrows that list again.
func test_hevc_10_bit_is_kept() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("hevc", "yuv420p10le", false, "mp4", PLAYABLE))
		. is_equal("")
	)


func test_av1_10_bit_is_kept() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("av1", "yuv420p10le", false, "mp4", PLAYABLE))
		. is_equal("")
	)


# 4:2:2 stays out: it is not in SAFE_PIX_FMTS and was never measured, so it still re-encodes.
func test_an_unmeasured_pixel_format_still_re_encodes() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("h264", "yuv422p", false, "mp4", PLAYABLE))
		. is_equal("h264 yuv422p")
	)


# 10-bit H.264 is kept for the same reason 10-bit AV1 is: the cost was measured and accepted.
func test_10_bit_h264_is_kept() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("h264", "yuv420p10le", false, "mp4", PLAYABLE))
		. is_equal("")
	)


# The bug the container gate exists for: a perfectly playable H.264 stream in a container the runtime
# has no demuxer for. Before the gate this passed and pooled verbatim, then failed to open at play time.
func test_an_undemuxable_container_is_remuxed() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("h264", "yuv420p", false, "ts", PLAYABLE))
		. is_equal("h264 in .ts")
	)


func test_the_container_check_is_case_insensitive() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("h264", "yuv420p", false, "MP4", PLAYABLE))
		. is_equal("")
	)


# A caller with no container to offer (the builder's preview probe) must not be told to re-encode.
func test_an_unknown_container_is_not_a_reason() -> void:
	assert_str(MediaPoolService.transcode_reason("h264", "yuv420p", false, "", PLAYABLE)).is_equal(
		""
	)


# An unreadable probe re-encodes rather than gambling.
func test_an_unreadable_codec_re_encodes() -> void:
	assert_str(MediaPoolService.transcode_reason("", "", false, "mp4", PLAYABLE)).is_equal(
		"unverifiable"
	)


# The codec is reported ahead of the pixel format and the container: the first true thing about a file
# is the useful one, and an undecodable codec makes the rest moot.
func test_the_codec_reason_wins_over_the_others() -> void:
	(
		assert_str(
			MediaPoolService.transcode_reason("mpeg2video", "yuv422p", false, "ts", PLAYABLE)
		)
		. is_equal("mpeg2video")
	)


# A cut forces an encode even on a source that needed nothing — a frame-accurate trim can't be a copy.
func test_a_trim_forces_an_encode_on_a_clean_source() -> void:
	(
		assert_str(MediaPoolService.transcode_reason("h264", "yuv420p", true, "mp4", PLAYABLE))
		. is_equal("trim")
	)


# ...but a real problem still outranks it, so the modal names the actual fault.
func test_a_real_reason_outranks_trim() -> void:
	(
		assert_str(
			MediaPoolService.transcode_reason("mpeg2video", "yuv420p", true, "mp4", PLAYABLE)
		)
		. is_equal("mpeg2video")
	)
