extends GdUnitTestSuite

# RandomizerRun — the progressive-baking half: materialize a run folder while its
# parts are still encoding (materialize_partial), link parts in as they finish
# (link_part), drop the unfinished marker once the bake completed (finish), and
# discard marked leftovers on app start (sweep_unfinished).
#
# Tested against the REAL filesystem, exactly like randomizer_run_test.gd: an own
# pool store under user://, run folders under the real RandomizerRun.RUNS_DIR, and
# every test wiping its own folders in after_test. RandomizerRun.clear_all() is
# never called here — it would take the user's own runs with it.
#
# NOTE: sweep_unfinished() walks the REAL user://randomizer_runs. A marked leftover
# of the user's own interrupted session is swept away by this test too. That is
# precisely what happens on every app start, so it is harmless — but it should not
# read as a test bug when someone looks into user:// afterwards.

const STORE: String = "user://test_rand_partial_store"

# Its own throwaway catalogue dir for the keep() tests, so they never touch the
# real configured journeys dir.
const JOURNEYS: String = "user://test_rand_partial_journeys"

# The two hand-built folders of the sweep test. Named distinctively so they can
# never collide with a generated "run_<hex>_<hex>" folder.
const SWEEP_MARKED: String = "test_sweep_marked"
const SWEEP_CLEAN: String = "test_sweep_clean"

var _run_folder: String = ""


func before_test() -> void:
	JourneyData.delete_dir_recursive(STORE)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STORE + "/content"))


func after_test() -> void:
	JourneyData.delete_dir_recursive(STORE)
	JourneyData.delete_dir_recursive(JOURNEYS)
	if _run_folder != "":
		JourneyData.delete_dir_recursive(_run_folder)
		_run_folder = ""
	# The sweep test's hand-built folders plus their service files (cheap and
	# unconditional — a missing folder / board / save is a no-op everywhere).
	for name: String in [SWEEP_MARKED, SWEEP_CLEAN]:
		JourneyData.delete_dir_recursive(RandomizerRun.RUNS_DIR + "/" + name)
		ScoreboardService.clear(name)
		JourneySaveService.delete_save(name)


# ── Fixtures ─────────────────────────────────────────────────────────────────


# Builds `n` library entries AND writes their dummy pooled files into the test
# store, so the pooled sources really exist (tests un-pool selectively).
func _make_library(n: int) -> Array:
	var out: Array = []
	for i in n:
		var id: String = "c%02d" % i
		var vrel: String = "content/m_%s.mp4" % id
		var frel: String = "content/m_%s.funscript" % id
		_write(STORE + "/" + vrel, "fake-video-bytes-%s" % id)
		_write(STORE + "/" + frel, '{"actions":[]}')
		(
			out
			. append(
				{
					"id": id,
					"name": id,
					"video_rel": vrel,
					"funscript_rel": frel,
					"axis_rel": {},
					"vib_rel": {},
					"boss_image_rel": "",
					"action_count": 50,
					"length_ms": 60000,
					"duration_ms": 60000,
					"tags": [],
					"weight": 1.0,
					"intensity": 3,
					"last_used": 0,
				}
			)
		)
	return out


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text: String = f.get_as_text()
	f.close()
	return text


func _unpool(rel: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STORE + "/" + rel))


func _content_file_count(folder: String) -> int:
	var dir: DirAccess = DirAccess.open(folder + "/content")
	if dir == null:
		return -1
	return dir.get_files().size()


# A run folder the way a materialized run looks on disk, built by hand so the
# sweep test doesn't depend on materialize_partial.
func _make_run_folder(folder_name: String, marked: bool) -> void:
	var folder: String = RandomizerRun.RUNS_DIR + "/" + folder_name
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder + "/content"))
	_write(folder + "/journey.json", '{"Name":"sweep"}')
	if marked:
		_write(folder + "/" + RandomizerRun.UNFINISHED_MARKER, "")


func _run_dir_exists(folder_name: String) -> bool:
	return DirAccess.dir_exists_absolute(
		ProjectSettings.globalize_path(RandomizerRun.RUNS_DIR + "/" + folder_name)
	)


# ── materialize_partial ──────────────────────────────────────────────────────


func test_materialize_partial_links_only_what_is_pooled() -> void:
	var lib: Array = _make_library(3)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 1, "round_count": 3})
	var rels: Array = res["content_rels"]
	# Un-pool one rel: its part is still encoding at play time — the normal case.
	var missing: String = str(rels[0])
	_unpool(missing)

	var mat: Dictionary = RandomizerRun.materialize_partial(res["journey"], rels, STORE)
	_run_folder = str(mat["folder"])

	assert_bool(mat["ok"]).is_true()
	assert_str(str(mat["reason"])).is_equal("")
	assert_bool(FileAccess.file_exists(_run_folder + "/journey.json")).is_true()
	assert_bool(FileAccess.file_exists(_run_folder + "/" + missing)).is_false()
	for rel: String in rels:
		if rel == missing:
			continue
		assert_bool(FileAccess.file_exists(_run_folder + "/" + rel)).is_true()


func test_materialize_partial_writes_the_unfinished_marker() -> void:
	var lib: Array = _make_library(2)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 2, "round_count": 2})

	var mat: Dictionary = RandomizerRun.materialize_partial(
		res["journey"], res["content_rels"], STORE
	)
	_run_folder = str(mat["folder"])

	assert_bool(mat["ok"]).is_true()
	var marker: String = _run_folder + "/" + RandomizerRun.UNFINISHED_MARKER
	assert_bool(FileAccess.file_exists(marker)).is_true()
	# Existence IS the information — the file carries no payload.
	var f: FileAccess = FileAccess.open(marker, FileAccess.READ)
	assert_object(f).is_not_null()
	assert_int(f.get_length()).is_equal(0)
	f.close()


func test_materialize_partial_with_nothing_pooled_is_not_an_error() -> void:
	var lib: Array = _make_library(3)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 3, "round_count": 3})
	# Nothing baked yet at all — the baker will link every part in later.
	JourneyData.delete_dir_recursive(STORE)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STORE + "/content"))

	var mat: Dictionary = RandomizerRun.materialize_partial(
		res["journey"], res["content_rels"], STORE
	)
	_run_folder = str(mat["folder"])

	assert_bool(mat["ok"]).is_true()
	assert_str(str(mat["reason"])).is_equal("")
	assert_bool(FileAccess.file_exists(_run_folder + "/journey.json")).is_true()
	(
		assert_bool(FileAccess.file_exists(_run_folder + "/" + RandomizerRun.UNFINISHED_MARKER))
		. is_true()
	)
	assert_int(_content_file_count(_run_folder)).is_equal(0)


# ── link_part ────────────────────────────────────────────────────────────────


func test_link_part_links_a_pooled_file_afterwards() -> void:
	var lib: Array = _make_library(2)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 4, "round_count": 2})
	var late: String = str(res["content_rels"][0])
	_unpool(late)

	var mat: Dictionary = RandomizerRun.materialize_partial(
		res["journey"], res["content_rels"], STORE
	)
	_run_folder = str(mat["folder"])
	assert_bool(FileAccess.file_exists(_run_folder + "/" + late)).is_false()

	# The baker finished that part: it lands in the pool and gets linked in.
	_write(STORE + "/" + late, "late-baked-bytes")

	assert_bool(RandomizerRun.link_part(_run_folder, late, STORE)).is_true()
	assert_bool(FileAccess.file_exists(_run_folder + "/" + late)).is_true()
	assert_str(_read(_run_folder + "/" + late)).is_equal("late-baked-bytes")


func test_link_part_reports_false_for_a_source_that_is_not_pooled() -> void:
	var lib: Array = _make_library(2)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 5, "round_count": 2})
	var mat: Dictionary = RandomizerRun.materialize_partial(
		res["journey"], res["content_rels"], STORE
	)
	_run_folder = str(mat["folder"])

	var ghost: String = "content/m_never_baked.mp4"
	assert_bool(RandomizerRun.link_part(_run_folder, ghost, STORE)).is_false()
	assert_bool(FileAccess.file_exists(_run_folder + "/" + ghost)).is_false()


func test_link_part_is_idempotent() -> void:
	var lib: Array = _make_library(2)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 6, "round_count": 2})
	var late: String = str(res["content_rels"][0])
	_unpool(late)
	var mat: Dictionary = RandomizerRun.materialize_partial(
		res["journey"], res["content_rels"], STORE
	)
	_run_folder = str(mat["folder"])
	_write(STORE + "/" + late, "late-baked-bytes")

	assert_bool(RandomizerRun.link_part(_run_folder, late, STORE)).is_true()
	assert_bool(RandomizerRun.link_part(_run_folder, late, STORE)).is_true()
	assert_str(_read(_run_folder + "/" + late)).is_equal("late-baked-bytes")


# ── keep ─────────────────────────────────────────────────────────────────────


func test_keep_refuses_an_unfinished_run() -> void:
	var lib: Array = _make_library(2)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 8, "round_count": 2})
	var mat: Dictionary = RandomizerRun.materialize_partial(
		res["journey"], res["content_rels"], STORE
	)
	_run_folder = str(mat["folder"])
	(
		assert_bool(FileAccess.file_exists(_run_folder + "/" + RandomizerRun.UNFINISHED_MARKER))
		. is_true()
	)

	# Still marked unfinished: keep must refuse, and touch nothing in the catalogue.
	var kept: Dictionary = RandomizerRun.keep(_run_folder, "X", JOURNEYS)
	assert_bool(kept["ok"]).is_false()
	assert_str(str(kept["reason"])).is_equal("run_unfinished")
	assert_bool(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(JOURNEYS))).is_false()

	# Counter-proof: once the bake is finished (marker gone), the same keep() succeeds.
	RandomizerRun.finish(_run_folder)
	(
		assert_bool(FileAccess.file_exists(_run_folder + "/" + RandomizerRun.UNFINISHED_MARKER))
		. is_false()
	)

	var kept2: Dictionary = RandomizerRun.keep(_run_folder, "X", JOURNEYS)
	assert_bool(kept2["ok"]).is_true()
	JourneyData.delete_dir_recursive(str(kept2["folder"]))


# ── finish ───────────────────────────────────────────────────────────────────


func test_finish_removes_the_marker_and_is_idempotent() -> void:
	var lib: Array = _make_library(2)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 7, "round_count": 2})
	var rels: Array = res["content_rels"]
	var mat: Dictionary = RandomizerRun.materialize_partial(res["journey"], rels, STORE)
	_run_folder = str(mat["folder"])
	var marker: String = _run_folder + "/" + RandomizerRun.UNFINISHED_MARKER
	assert_bool(FileAccess.file_exists(marker)).is_true()

	RandomizerRun.finish(_run_folder)

	assert_bool(FileAccess.file_exists(marker)).is_false()
	assert_bool(FileAccess.file_exists(_run_folder + "/journey.json")).is_true()
	assert_int(_content_file_count(_run_folder)).is_equal(rels.size())

	# A second finish is silent and changes nothing; a folder that never existed
	# is a no-op too (the baker calls it on runs it never materialized).
	RandomizerRun.finish(_run_folder)
	RandomizerRun.finish("user://test_rand_partial_no_such_run")

	assert_bool(FileAccess.file_exists(marker)).is_false()
	assert_bool(FileAccess.file_exists(_run_folder + "/journey.json")).is_true()
	assert_int(_content_file_count(_run_folder)).is_equal(rels.size())


# ── sweep_unfinished ─────────────────────────────────────────────────────────


func test_sweep_removes_marked_runs_with_their_save_and_scoreboard() -> void:
	_make_run_folder(SWEEP_MARKED, true)
	_make_run_folder(SWEEP_CLEAN, false)
	for name: String in [SWEEP_MARKED, SWEEP_CLEAN]:
		ScoreboardService.add_run(
			name, {"score": 10, "completed": true, "rounds_done": 2, "rounds_total": 2}
		)
		JourneySaveService.write_save(name, {"current_node": "n1", "rounds_entered": 1})

	RandomizerRun.sweep_unfinished()

	# The interrupted run is gone, and so are its resume save and scoreboard —
	# resuming into a half-baked run would be a journey with holes.
	assert_bool(_run_dir_exists(SWEEP_MARKED)).is_false()
	assert_array(ScoreboardService.read_runs(SWEEP_MARKED)).is_empty()
	assert_bool(JourneySaveService.has_save(SWEEP_MARKED)).is_false()

	# The finished run is untouched, down to its files.
	assert_bool(_run_dir_exists(SWEEP_CLEAN)).is_true()
	(
		assert_bool(
			FileAccess.file_exists(RandomizerRun.RUNS_DIR + "/" + SWEEP_CLEAN + "/journey.json")
		)
		. is_true()
	)
	assert_int(ScoreboardService.read_runs(SWEEP_CLEAN).size()).is_equal(1)
	assert_bool(JourneySaveService.has_save(SWEEP_CLEAN)).is_true()

	# Unlike clear_all, the sweep never removes the runs dir itself.
	(
		assert_bool(
			DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(RandomizerRun.RUNS_DIR))
		)
		. is_true()
	)
