extends GdUnitTestSuite

# JourneyZip — deciding what inside an arbitrary archive is a journey, and which of its entries are
# safe to write. Pure path logic: no zip, no disk.


func _files(paths: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for p: Variant in paths:
		out.append(str(p))
	return out


# ── Finding the journeys ─────────────────────────────────────────────────────
# People zip a folder three ways and none of them is wrong, so all three are accepted.


func test_a_flat_zip_has_its_journey_at_the_root() -> void:
	var roots: Array = JourneyZip.find_roots(
		_files(["journey.json", "content/m_a.mp4", "media/cover.png"])
	)
	assert_array(roots).contains_exactly([""])


func test_a_zip_wrapped_in_one_folder_is_found() -> void:
	var roots: Array = JourneyZip.find_roots(
		_files(["My Journey/journey.json", "My Journey/content/m_a.mp4"])
	)
	assert_array(roots).contains_exactly(["My Journey/"])


func test_a_journey_buried_deeper_is_still_found() -> void:
	var roots: Array = JourneyZip.find_roots(
		_files(["exports/2024/Deep One/journey.json", "exports/2024/Deep One/media/cover.png"])
	)
	assert_array(roots).contains_exactly(["exports/2024/Deep One/"])


func test_several_journeys_each_count_shallowest_first() -> void:
	var roots: Array = JourneyZip.find_roots(
		_files(["B/journey.json", "A/journey.json", "lib/C/journey.json"])
	)
	assert_array(roots).contains_exactly(["A/", "B/", "lib/C/"])


# A journey at the archive ROOT contains everything else in the archive, so by the containment rule it
# absorbs any deeper journey.json — those are its own files, not siblings. A zip of several journeys
# puts each in its own folder and has no journey.json at the root, which is the case above.
func test_a_root_journey_absorbs_the_whole_archive() -> void:
	var roots: Array = JourneyZip.find_roots(_files(["journey.json", "A/journey.json"]))
	assert_array(roots).contains_exactly([""])


# A journey.json under another journey's root is a stray copy, not a second journey — pooled content
# never contains one, so the outer journey wins and the inner is ignored.
func test_a_nested_journey_json_does_not_become_a_second_journey() -> void:
	var roots: Array = JourneyZip.find_roots(
		_files(["Outer/journey.json", "Outer/backup/journey.json"])
	)
	assert_array(roots).contains_exactly(["Outer/"])


func test_a_file_merely_named_like_it_is_not_a_journey() -> void:
	assert_array(JourneyZip.find_roots(_files(["old_journey.json", "notes.txt"]))).is_empty()
	assert_bool(JourneyZip.is_journey_archive(_files(["readme.md"]))).is_false()
	assert_bool(JourneyZip.is_journey_archive(_files(["journey.json"]))).is_true()


func test_backslash_paths_are_read_the_same_as_forward_ones() -> void:
	var roots: Array = JourneyZip.find_roots(_files(["My Journey\\journey.json"]))
	assert_array(roots).contains_exactly(["My Journey/"])


# ── Entries, and refusing the dangerous ones ─────────────────────────────────
# An archive is untrusted input: an entry can name a path outside the folder it is supposed to land in.


func test_entries_are_taken_from_the_right_journey_only() -> void:
	var entries: Array = JourneyZip.entries_under(
		_files(["A/journey.json", "A/content/x.mp4", "B/journey.json", "B/content/y.mp4"]), "A/"
	)
	var rels: Array = entries.map(func(e: Dictionary) -> String: return str(e["rel"]))
	assert_array(rels).contains_exactly_in_any_order(["journey.json", "content/x.mp4"])
	# The zip path is kept whole, because that is what the reader is asked for.
	assert_str(str((entries[0] as Dictionary)["zip_path"])).starts_with("A/")


func test_directory_entries_are_dropped() -> void:
	var entries: Array = JourneyZip.entries_under(
		_files(["A/", "A/content/", "A/journey.json"]), "A/"
	)
	assert_int(entries.size()).is_equal(1)


# Zip slip: an entry that would escape the journey folder is refused outright rather than sanitised
# into something plausible. A journey has no reason to carry one.
func test_paths_that_escape_the_folder_are_refused() -> void:
	for bad: String in [
		"../evil.cfg",
		"a/../../evil.cfg",
		"C:/Windows/system32/x.dll",
		"~/.bashrc",
		"res://overwrite.gd",
		"./x",
		"",
	]:
		(
			assert_str(JourneyZip.safe_rel(bad))
			. override_failure_message("'%s' should be refused" % bad)
			. is_equal("")
		)


# A leading slash is NOT treated as absolute, because in a zip it is not: some writers emit it and the
# spec calls entries relative. Stripping it keeps the entry inside the journey folder, which is the
# property that matters — "/etc/passwd" lands at <journey>/etc/passwd, clutter rather than an escape.
func test_a_leading_slash_is_stripped_not_treated_as_absolute() -> void:
	assert_str(JourneyZip.safe_rel("/media/cover.png")).is_equal("media/cover.png")
	assert_str(JourneyZip.safe_rel("/etc/passwd")).is_equal("etc/passwd")


func test_ordinary_paths_survive_unchanged() -> void:
	assert_str(JourneyZip.safe_rel("journey.json")).is_equal("journey.json")
	assert_str(JourneyZip.safe_rel("content/m_ab12.mp4")).is_equal("content/m_ab12.mp4")
	assert_str(JourneyZip.safe_rel("media\\cover.png")).is_equal("media/cover.png")


func test_an_unsafe_entry_is_dropped_rather_than_failing_the_whole_journey() -> void:
	var entries: Array = JourneyZip.entries_under(
		_files(["A/journey.json", "A/../../evil.cfg", "A/media/cover.png"]), "A/"
	)
	var rels: Array = entries.map(func(e: Dictionary) -> String: return str(e["rel"]))
	assert_array(rels).contains_exactly_in_any_order(["journey.json", "media/cover.png"])
