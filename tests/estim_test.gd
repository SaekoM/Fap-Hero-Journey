extends GdUnitTestSuite

# Tests for the restim (E-Stim Full) import path: parameter-axis detection from
# filenames, alpha/beta position aliases, suffix stripping so e-stim scripts group
# with their round, and estim_scripts wiring through sibling autofill / build_rounds.
#
# Pure functions are tested directly; the disk-touching ones run against a
# throwaway temp dir, mirroring import_scanner_test.gd.

var _tmp: String = ""


func before_test() -> void:
	_tmp = "user://estim_test_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(_tmp)


func after_test() -> void:
	_rm_rf(_tmp)


func _rm_rf(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var f: String = d.get_next()
	while f != "":
		var full: String = "%s/%s" % [path, f]
		if d.current_is_dir():
			_rm_rf(full)
		else:
			DirAccess.remove_absolute(full)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


func _touch(name: String) -> String:
	var p: String = "%s/%s" % [_tmp, name]
	var fa: FileAccess = FileAccess.open(p, FileAccess.ModeFlags.WRITE)
	fa.store_string("{}")
	fa.close()
	return p


# The group shape ImportScanner.group_anchor_path() consumes, with an estim bucket.
func _group_with_estim(video: String, estim: Dictionary) -> Dictionary:
	return {"video": video, "funscript": "", "axis": {}, "vib": {}, "estim": estim}


# ── detect_estim_axis ────────────────────────────────────────────────────────


func test_detect_estim_axis_dot_and_underscore_forms() -> void:
	assert_str(ImportScanner.detect_estim_axis("clip.volume.funscript")).is_equal("V0")
	assert_str(ImportScanner.detect_estim_axis("clip_volume.funscript")).is_equal("V0")
	assert_str(ImportScanner.detect_estim_axis("clip.carrier_frequency.funscript")).is_equal("C0")
	assert_str(ImportScanner.detect_estim_axis("clip_pulse_rise_time.funscript")).is_equal("P3")


func test_detect_estim_axis_is_case_insensitive() -> void:
	assert_str(ImportScanner.detect_estim_axis("Clip.VOLUME.funscript")).is_equal("V0")
	assert_str(ImportScanner.detect_estim_axis("Clip.Carrier_Frequency.funscript")).is_equal("C0")


func test_detect_estim_axis_empty_for_non_estim_names() -> void:
	assert_str(ImportScanner.detect_estim_axis("clip.funscript")).is_equal("")
	assert_str(ImportScanner.detect_estim_axis("clip.surge.funscript")).is_equal("")
	assert_str(ImportScanner.detect_estim_axis("clip.alpha.funscript")).is_equal("")


# The e-stim names are longer tails that overlap the vib channel suffixes
# (".vib1" vs ".vib1_frequency"). Detection must not truncate to the shorter one.
func test_detect_estim_axis_beats_overlapping_vib_suffix() -> void:
	assert_str(ImportScanner.detect_estim_axis("clip.vib1_frequency.funscript")).is_equal("V1")
	assert_str(ImportScanner.detect_estim_axis("clip.vib1_strength.funscript")).is_equal("V2")
	assert_str(ImportScanner.detect_estim_axis("clip.vib2_frequency.funscript")).is_equal("V4")
	# …while a plain vib channel is still a vib channel, not an e-stim axis.
	assert_str(ImportScanner.detect_estim_axis("clip.vib1.funscript")).is_equal("")


# Guards future additions: every axis declared in JourneyData must be reachable
# from its own suffix, so adding one to the map without teaching the detector fails here.
func test_every_declared_estim_axis_is_detectable() -> void:
	for axis: String in JourneyData.ESTIM_SUFFIXES:
		var suffix: String = JourneyData.ESTIM_SUFFIXES[axis]
		var detected: String = ImportScanner.detect_estim_axis("clip.%s.funscript" % suffix)
		var args: Array = [axis, suffix, detected]
		var msg: String = "axis %s (suffix '%s') was not detected, got '%s'" % args
		assert_str(detected).override_failure_message(msg).is_equal(axis)


# ── alpha / beta position aliases ────────────────────────────────────────────


func test_alpha_and_beta_map_to_stroke_and_surge() -> void:
	assert_str(ImportScanner.detect_funscript_axis("clip.alpha.funscript")).is_equal("L0")
	assert_str(ImportScanner.detect_funscript_axis("clip_alpha.funscript")).is_equal("L0")
	assert_str(ImportScanner.detect_funscript_axis("clip.beta.funscript")).is_equal("L1")
	assert_str(ImportScanner.detect_funscript_axis("clip_beta.funscript")).is_equal("L1")


# ── grouping ─────────────────────────────────────────────────────────────────


func test_estim_suffix_is_stripped_so_scripts_group_with_their_round() -> void:
	assert_str(ImportScanner.strip_script_suffix("a/b/clip.volume.funscript")).is_equal("clip")
	assert_str(ImportScanner.strip_script_suffix("a/b/clip.pulse_width.funscript")).is_equal("clip")
	assert_str(ImportScanner.round_group_key("a/b/clip.volume.funscript")).is_equal(
		ImportScanner.round_group_key("a/b/clip.mp4")
	)


# Regression: group_anchor_path must tolerate groups built before "estim" existed
# (upstream's own tests pass such literals) rather than throwing on a missing key.
func test_group_anchor_path_tolerates_missing_estim_key() -> void:
	var legacy: Dictionary = {"video": "", "funscript": "f.funscript", "axis": {}, "vib": {}}
	assert_str(ImportScanner.group_anchor_path(legacy)).is_equal("f.funscript")
	var bare: Dictionary = {"video": "", "funscript": "", "axis": {}, "vib": {}}
	assert_str(ImportScanner.group_anchor_path(bare)).is_equal("")


func test_group_anchor_path_falls_back_to_an_estim_script() -> void:
	var group: Dictionary = _group_with_estim("", {"V0": "v.funscript"})
	assert_str(ImportScanner.group_anchor_path(group)).is_equal("v.funscript")


# Video still wins over an e-stim script when both are present.
func test_group_anchor_path_prefers_video() -> void:
	var group: Dictionary = _group_with_estim("clip.mp4", {"V0": "v.funscript"})
	assert_str(ImportScanner.group_anchor_path(group)).is_equal("clip.mp4")


func test_ensure_import_group_seeds_an_estim_bucket() -> void:
	var groups: Dictionary = {}
	var order: Array = []
	ImportScanner.ensure_import_group(groups, order, "k")
	assert_bool((groups["k"] as Dictionary).has("estim")).is_true()
	assert_dict(groups["k"]["estim"]).is_empty()


# ── disk: sibling scan + build_rounds ────────────────────────────────────────


func test_find_sibling_scripts_picks_up_estim_parameters() -> void:
	_touch("clip.funscript")
	_touch("clip.volume.funscript")
	_touch("clip.pulse_width.funscript")
	var scan: Dictionary = ImportScanner.find_sibling_scripts(_tmp, "clip")
	assert_dict(scan["estim"]).contains_key_value("V0", "%s/clip.volume.funscript" % _tmp)
	assert_dict(scan["estim"]).contains_key_value("P1", "%s/clip.pulse_width.funscript" % _tmp)


func test_autofill_populates_estim_scripts_without_clobbering_existing() -> void:
	_touch("clip.funscript")
	_touch("clip.volume.funscript")
	var round_data: Dictionary = {"estim_scripts": {"V0": "already/set.funscript"}}
	ImportScanner.autofill_round_siblings(round_data, "%s/clip.funscript" % _tmp)
	# An explicit entry wins; the scan only fills gaps.
	assert_str(round_data["estim_scripts"]["V0"]).is_equal("already/set.funscript")


func test_build_rounds_routes_estim_scripts_onto_the_round() -> void:
	var video: String = _touch("clip.mp4")
	var main: String = _touch("clip.funscript")
	var vol: String = _touch("clip.volume.funscript")
	var result: Dictionary = ImportScanner.build_rounds(PackedStringArray([video, main, vol]))
	var rounds: Array = result["rounds"]
	assert_int(rounds.size()).is_equal(1)
	assert_dict(rounds[0]["estim_scripts"]).contains_key_value("V0", vol)
	# The e-stim script must not have been mistaken for the main funscript.
	assert_str(rounds[0]["funscript_path"]).is_equal(main)
