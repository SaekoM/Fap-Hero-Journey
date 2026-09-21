extends GdUnitTestSuite

# SensoryFX intensity math — the mapping that turns a normalized 0–1 slider value
# into a real effect value, and the per-round override lookup. Pure logic: _ival
# only reads the roll dict, intensity_for is static, so neither needs setup().
# SensoryFX is reached via its global class_name.

const EPS := 0.0001


# _ival lerps imin→imax across 0–1.
func test_ival_normal_range() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	var roll := {"imin": 1.0, "imax": 6.0}  # e.g. blur radius
	assert_float(fx._ival(roll, 0.0)).is_equal_approx(1.0, EPS)
	assert_float(fx._ival(roll, 1.0)).is_equal_approx(6.0, EPS)
	assert_float(fx._ival(roll, 0.5)).is_equal_approx(3.5, EPS)


# Inverted ranges (imin > imax) — "stronger" maps to a lower number, e.g.
# pixelate blocks, strobe interval, low-pass cutoff, tunnel ramp.
func test_ival_inverted_range() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	var roll := {"imin": 160.0, "imax": 30.0}  # pixelate: fewer blocks = stronger
	assert_float(fx._ival(roll, 0.0)).is_equal_approx(160.0, EPS)
	assert_float(fx._ival(roll, 1.0)).is_equal_approx(30.0, EPS)
	(
		assert_bool(fx._ival(roll, 1.0) < fx._ival(roll, 0.0))
		. override_failure_message("higher intensity should map to lower value")
		. is_true()
	)


# Intensity is clamped to 0–1 before mapping.
func test_ival_clamps_intensity() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	var roll := {"imin": 0.0, "imax": 1.0}
	assert_float(fx._ival(roll, 2.0)).is_equal_approx(1.0, EPS)
	assert_float(fx._ival(roll, -1.0)).is_equal_approx(0.0, EPS)


# Missing imin/imax fall back to a 0–1 identity (defensive default).
func test_ival_missing_fields() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	assert_float(fx._ival({}, 0.5)).is_equal_approx(0.5, EPS)


# intensity_for: author override on the round wins; otherwise the catalog default.
func test_intensity_for_override_and_default() -> void:
	var entry := {"name": "Bleary", "idef": 0.3}
	(
		assert_float(SensoryFX.intensity_for({"sensory_intensity": {"Bleary": 0.8}}, entry))
		. is_equal_approx(0.8, EPS)
	)
	assert_float(SensoryFX.intensity_for({}, entry)).is_equal_approx(0.3, EPS)
	(
		assert_float(SensoryFX.intensity_for({"sensory_intensity": {"Other": 0.9}}, entry))
		. is_equal_approx(0.3, EPS)
	)


# A stored override outside 0–1 is clamped.
func test_intensity_for_clamps_override() -> void:
	var entry := {"name": "Murk", "idef": 0.5}
	(
		assert_float(SensoryFX.intensity_for({"sensory_intensity": {"Murk": 5.0}}, entry))
		. is_equal_approx(1.0, EPS)
	)
	(
		assert_float(SensoryFX.intensity_for({"sensory_intensity": {"Murk": -2.0}}, entry))
		. is_equal_approx(0.0, EPS)
	)


# ── Rate (the beat of Bloodshot / Flicker / Tremor) ──────────────────────────


# rate_for mirrors intensity_for: the round's override when set, else the catalog default.
func test_rate_for_override_and_default() -> void:
	var entry := {"name": "Bloodshot", "rdef": 0.162}
	assert_float(SensoryFX.rate_for({}, entry)).is_equal_approx(0.162, EPS)
	assert_float(SensoryFX.rate_for({"sensory_rate": {"Bloodshot": 0.9}}, entry)).is_equal_approx(
		0.9, EPS
	)
	assert_float(SensoryFX.rate_for({"sensory_rate": {"Bloodshot": 3.0}}, entry)).is_equal_approx(
		1.0, EPS
	)


# _rval maps 0–1 through rmin/rmax in real units.
func test_rval_maps_through_the_rate_range() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	var roll := {"rmin": 0.6, "rmax": 8.0}
	assert_float(fx._rval(roll, 0.0)).is_equal_approx(0.6, EPS)
	assert_float(fx._rval(roll, 1.0)).is_equal_approx(8.0, EPS)


# A window (or item) that says nothing about rate gets the catalog default, so nothing authored
# before rates existed changes cadence.
func test_reconcile_defaults_a_missing_rate_and_reapplies_on_change() -> void:
	var fx: SensoryFX = _engine_in_tree()
	var roll: Dictionary = JourneyData.sensory_entry_by_kind("tremor")
	fx.reconcile([{"roll": roll, "intensity": 1.0}])
	assert_float(fx._tremor_hz).is_equal_approx(SensoryFX.TREMOR_BASE_HZ, 0.02)
	fx.reconcile([{"roll": roll, "intensity": 1.0, "rate": 0.0}])
	assert_float(fx._tremor_hz).is_equal_approx(2.0, EPS)  # rmin — re-applied although intensity held


# Stands the engine up over a throwaway player + parent inside the tree, as the runtime does.
func _engine_in_tree() -> SensoryFX:
	var parent: Control = auto_free(Control.new())
	add_child(parent)
	var video: VideoStreamPlayer = auto_free(VideoStreamPlayer.new())
	parent.add_child(video)
	var fx: SensoryFX = auto_free(SensoryFX.new())
	add_child(fx)
	fx.setup(video, parent)
	return fx


# ── Tunnel darkness curve ────────────────────────────────────────────────────
# Anchored at the catalog default: an untouched round looks exactly as it did, while the top of the
# slider now closes to a real tunnel instead of a slightly darker vignette.


func test_tunnel_ramp_is_unchanged_at_and_below_the_default() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	var at_default: Dictionary = fx._tunnel_ramp(SensoryFX.TUNNEL_DEFAULT_INTENSITY)
	assert_float(float(at_default["mid_alpha"])).is_equal_approx(lerpf(0.12, 0.40, 0.38), EPS)
	assert_float(float(at_default["edge_alpha"])).is_equal_approx(lerpf(0.30, 0.99, 0.38), EPS)
	assert_float(float(at_default["edge_offset"])).is_equal_approx(1.0, EPS)
	var low: Dictionary = fx._tunnel_ramp(0.1)
	assert_float(float(low["mid_alpha"])).is_equal_approx(lerpf(0.12, 0.40, 0.1), EPS)
	assert_float(float(low["edge_offset"])).is_equal_approx(1.0, EPS)


func test_tunnel_ramp_closes_to_a_real_tunnel_at_full() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	var top: Dictionary = fx._tunnel_ramp(1.0)
	assert_float(float(top["mid_alpha"])).is_equal_approx(SensoryFX.TUNNEL_MAX_MID_ALPHA, EPS)
	assert_float(float(top["edge_alpha"])).is_equal_approx(1.0, EPS)
	assert_float(float(top["edge_offset"])).is_equal_approx(SensoryFX.TUNNEL_MAX_EDGE_OFFSET, EPS)


func test_tunnel_ramp_is_monotonic_and_continuous_at_the_join() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	var prev: Dictionary = fx._tunnel_ramp(0.0)
	for i: int in range(1, 101):
		var cur: Dictionary = fx._tunnel_ramp(i / 100.0)
		assert_bool(float(cur["mid_alpha"]) >= float(prev["mid_alpha"]) - EPS).is_true()
		assert_bool(float(cur["edge_alpha"]) >= float(prev["edge_alpha"]) - EPS).is_true()
		assert_bool(float(cur["edge_offset"]) <= float(prev["edge_offset"]) + EPS).is_true()
		# No visible step where the two pieces meet.
		assert_float(absf(float(cur["mid_alpha"]) - float(prev["mid_alpha"]))).is_less(0.02)
		prev = cur
