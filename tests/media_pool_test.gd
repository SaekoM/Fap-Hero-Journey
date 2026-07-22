extends GdUnitTestSuite

# Shared content pool. Unit-tests the pure dedup planner and the fingerprint/
# naming primitives that the save flow uses to store each per-round asset (video /
# funscript / axis / vib / boss image) once under content/m_<fingerprint>.<ext>.
# The file-I/O path (transcode/copy + skip-on-reuse) stays manual/integration —
# here we pin the decision logic that decides which sources get written vs reused.

const TEST_DIR := "user://test_media_pool"


func after() -> void:
	JourneyData.delete_dir_recursive(TEST_DIR)


# pooled_media_rel composes the journey-root-relative pool path.
func test_pooled_media_rel_shape() -> void:
	assert_str(JourneyData.pooled_media_rel("abc123", "mp4")).is_equal("content/m_abc123.mp4")
	assert_str(JourneyData.pooled_media_rel("def456", "funscript")).is_equal(
		"content/m_def456.funscript"
	)


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


# is_pooled_content_file recognises a journey's own pooled files (m_<hash> under content/) and
# nothing else — that's the gate that keeps hardlinks off an author's original source.
func test_is_pooled_content_file() -> void:
	assert_bool(MediaPoolService.is_pooled_content_file("user://j/content/m_abc123.mp4")).is_true()
	assert_bool(MediaPoolService.is_pooled_content_file("user://j/content/m_x.funscript")).is_true()
	# An original source (any folder, non-pool name) must NOT qualify.
	assert_bool(MediaPoolService.is_pooled_content_file("/Videos/myclip.mp4")).is_false()
	assert_bool(MediaPoolService.is_pooled_content_file("user://j/media/cover.png")).is_false()
	assert_bool(MediaPoolService.is_pooled_content_file("user://j/content/other.mp4")).is_false()


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
