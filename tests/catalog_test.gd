extends GdUnitTestSuite

# Catalog integrity — guards the single-source effect catalogs in JourneyData
# against the typo class the 6-file per-round-field plumbing invites. Pure const
# data; no nodes, autoloads, or C# needed.

const JD = preload("res://scripts/journey_builder/JourneyData.gd")

# Kinds that are all-or-nothing (no intensity slider, so no imin/imax/idef).
const BINARY_SENSORY := ["blackout", "mute"]


# Every adjustable sensory effect carries the intensity triple; binary ones don't.
func test_sensory_intensity_fields() -> void:
	for e: Dictionary in JD.SENSORY_CATALOG:
		var kind: String = String(e.get("kind", ""))
		var nm: String = String(e.get("name", "?"))
		if kind in BINARY_SENSORY:
			(
				assert_bool(e.has("idef"))
				. override_failure_message("%s is binary, should have no idef" % nm)
				. is_false()
			)
		else:
			(
				assert_bool(e.has("imin") and e.has("imax") and e.has("idef"))
				. override_failure_message("%s missing imin/imax/idef" % nm)
				. is_true()
			)


# Default intensity must be a normalized 0–1 value (it drives the % slider).
func test_idef_normalized() -> void:
	for e: Dictionary in JD.SENSORY_CATALOG:
		if e.has("idef"):
			(
				assert_float(float(e["idef"]))
				. override_failure_message("%s idef out of 0–1" % e.get("name", "?"))
				. is_between(0.0, 1.0)
			)


# Every kind flagged as audio must actually exist in the sensory catalog.
func test_audio_kinds_subset() -> void:
	var kinds := {}
	for e: Dictionary in JD.SENSORY_CATALOG:
		kinds[String(e.get("kind", ""))] = true
	for k: String in JD.AUDIO_SENSORY_KINDS:
		(
			assert_bool(kinds.has(k))
			. override_failure_message("audio kind '%s' not in SENSORY_CATALOG" % k)
			. is_true()
		)


# Effect names are the saved ids selected into an effect round's effects[] / sensory[]
# and resolved by name at runtime — a collision across catalogs would mis-resolve.
func test_names_unique_across_catalogs() -> void:
	var seen := {}
	for cat in [JD.CURSE_CATALOG, JD.SENSORY_CATALOG, JD.BLESSING_CATALOG]:
		for e: Dictionary in cat:
			var nm: String = String(e.get("name", ""))
			(
				assert_bool(seen.has(nm))
				. override_failure_message("duplicate effect name '%s'" % nm)
				. is_false()
			)
			seen[nm] = true


# Every entry needs a kind and a name (the two fields every consumer reads).
func test_entries_have_kind_and_name() -> void:
	for cat in [JD.CURSE_CATALOG, JD.SENSORY_CATALOG, JD.BLESSING_CATALOG]:
		for e: Dictionary in cat:
			assert_str(String(e.get("kind", ""))).is_not_empty()
			assert_str(String(e.get("name", ""))).is_not_empty()


# The effects with a beat of their own carry the rate triple in real units, and the default lands on
# exactly the cadence each had before rates existed — an untouched round must not change.
const RATED_SENSORY := {"bloodshot": 1.8, "flicker": 1.67, "tremor": 15.44}


func test_sensory_rate_fields_and_defaults() -> void:
	for e: Dictionary in JD.SENSORY_CATALOG:
		var kind: String = String(e.get("kind", ""))
		var nm: String = String(e.get("name", "?"))
		if not RATED_SENSORY.has(kind):
			(
				assert_bool(JD.sensory_has_rate(e))
				. override_failure_message("%s has no beat, should carry no rate" % nm)
				. is_false()
			)
			continue
		(
			assert_bool(
				(
					e.has("rmin")
					and e.has("rmax")
					and e.has("rdef")
					and e.has("runit")
					and e.has("rdesc")
				)
			)
			. override_failure_message("%s missing rmin/rmax/rdef/runit/rdesc" % nm)
			. is_true()
		)
		(
			assert_float(JD.sensory_rate_value(e, float(e["rdef"])))
			. override_failure_message("%s default rate is not its historical cadence" % nm)
			. is_equal_approx(float(RATED_SENSORY[kind]), 0.02)
		)


func test_sensory_rate_value_round_trips_and_reads() -> void:
	var e: Dictionary = JD.sensory_entry_by_kind("bloodshot")
	assert_float(JD.sensory_rate_value(e, 0.0)).is_equal_approx(0.6, 0.0001)
	assert_float(JD.sensory_rate_value(e, 1.0)).is_equal_approx(8.0, 0.0001)
	assert_float(JD.sensory_rate_from_value(e, JD.sensory_rate_value(e, 0.37))).is_equal_approx(
		0.37, 0.0001
	)
	assert_str(JD.sensory_rate_text(e, 1.0)).is_equal("8.0 s")
	assert_str(JD.sensory_rate_text(JD.sensory_entry_by_kind("tremor"), 1.0)).is_equal("25 Hz")
