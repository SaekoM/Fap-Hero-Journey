extends GdUnitTestSuite

# Effect-round pure helpers in JourneyData: the cursed/blessed → generic migration
# (normalize_effect_round — including the baked-in visuals and roll-scope), the merged
# gameplay catalog, and the valence lookup. These back the runtime enter-mode, the builder
# editor, the scanner/serializer round-trip, and the auditor — all route through them.

const JD = preload("res://scripts/journey_builder/JourneyData.gd")

# ── normalize_effect_round: legacy migration ─────────────────────────────────


# A legacy cursed round becomes a resolvable effect round with the green/CURSED look:
# curses → effects, curse_random → effect_random, curse_reward → endure_reward.
func test_normalize_migrates_cursed() -> void:
	var out := (
		JD
		. normalize_effect_round(
			{
				"round_type": "cursed",
				"curses": ["Shrunken", "Greed"],
				"curse_random": false,
				"curse_reward": 40,
				"cleanse_cost": 30,
				"sensory": ["Murk"],
			}
		)
	)
	assert_str(out["round_type"]).is_equal("effect")
	assert_str(out["frame_color"]).is_equal(JD.EFFECT_COLOR_HINDER)  # green/CURSED baked in
	assert_str(out["card_header"]).is_equal("CURSED")
	assert_str(out["card_icon"]).is_equal("☠")
	assert_bool(out["show_border"]).is_true()  # legacy rounds keep their frame (tint-free)
	assert_bool(out["resolvable"]).is_true()
	assert_bool(out["effect_random"]).is_false()
	assert_int(out["endure_reward"]).is_equal(40)
	assert_int(out["cleanse_cost"]).is_equal(30)
	assert_array(out["effects"]).contains_exactly(["Shrunken", "Greed"])
	assert_array(out["sensory"]).contains_exactly(["Murk"])


# A legacy blessed round becomes a non-resolvable effect round with the gold/BLESSED
# look; the retired Ward boon is dropped on migration.
func test_normalize_migrates_blessed_and_drops_ward() -> void:
	var out := (
		JD
		. normalize_effect_round(
			{
				"round_type": "blessed",
				"boons": ["Fervor", "Ward", "Gift"],
				"boon_random": true,
				"gift_item": "key",
			}
		)
	)
	assert_str(out["round_type"]).is_equal("effect")
	assert_str(out["frame_color"]).is_equal(JD.EFFECT_COLOR_BOON)  # gold/BLESSED baked in
	assert_str(out["card_header"]).is_equal("BLESSED")
	assert_bool(out["resolvable"]).is_false()
	assert_array(out["effects"]).contains_exactly(["Fervor", "Gift"])  # Ward removed
	assert_str(out["gift_item"]).is_equal("key")


# An already-generic effect round passes through; missing fields get defaults.
func test_normalize_generic_defaults() -> void:
	var out := JD.normalize_effect_round({"round_type": "effect", "effects": ["Toll"]})
	assert_str(out["round_type"]).is_equal("effect")
	assert_str(out["frame_color"]).is_equal(JD.EFFECT_COLOR_NEUTRAL)  # neutral default
	assert_str(out["card_header"]).is_equal("EFFECT")
	assert_str(out["card_icon"]).is_equal("✦")
	assert_bool(out["show_border"]).is_false()  # new rounds: border off by default
	assert_bool(out["resolvable"]).is_false()
	assert_bool(out["effect_random"]).is_true()
	assert_int(out["cleanse_cost"]).is_equal(50)
	assert_array(out["effects"]).contains_exactly(["Toll"])


# Author-set visuals are preserved (not overwritten by defaults).
func test_normalize_keeps_author_visuals() -> void:
	var out := (
		JD
		. normalize_effect_round(
			{
				"round_type": "effect",
				"frame_color": "#ff0000",
				"card_accent": "#00ff00",
				"card_header": "DOOM",
				"card_icon": "🔥",
			}
		)
	)
	assert_str(out["frame_color"]).is_equal("#ff0000")
	assert_str(out["card_accent"]).is_equal("#00ff00")
	assert_str(out["card_header"]).is_equal("DOOM")
	assert_str(out["card_icon"]).is_equal("🔥")


# Non-effect rounds keep their type; effect fields are defaulted (and unused).
func test_normalize_leaves_normal_and_boss() -> void:
	assert_str(JD.normalize_effect_round({"round_type": "normal"})["round_type"]).is_equal("normal")
	assert_str(JD.normalize_effect_round({"round_type": "boss"})["round_type"]).is_equal("boss")


# A boss can now carry forced gameplay effects — normalize must KEEP them (the normal/boss
# branch used to drop `effects`, which would wipe the list on every save and load).
func test_normalize_keeps_boss_effects() -> void:
	var out := JD.normalize_effect_round({"round_type": "boss", "effects": ["Toll", "Fortune"]})
	assert_array(out["effects"]).contains(["Toll", "Fortune"])


# A normal round with no effects still normalizes to an empty list — the branch is shared.
func test_normalize_normal_has_no_effects() -> void:
	assert_array(JD.normalize_effect_round({"round_type": "normal"})["effects"]).is_empty()


# ── valence + merged catalog ─────────────────────────────────────────────────


# Benefit is true only for boon (BLESSING) entries — drives green vs red framing.
func test_effect_is_benefit() -> void:
	assert_bool(JD.effect_is_benefit("Fervor")).is_true()  # boon
	assert_bool(JD.effect_is_benefit("Shrunken")).is_false()  # hindrance
	assert_bool(JD.effect_is_benefit("Murk")).is_false()  # sensory
	assert_bool(JD.effect_is_benefit("Nonexistent")).is_false()


# The merged gameplay catalog is exactly the hindrance + boon catalogs.
func test_gameplay_effects_merges_both() -> void:
	assert_int(JD.gameplay_effects().size()).is_equal(
		JD.CURSE_CATALOG.size() + JD.BLESSING_CATALOG.size()
	)


# A legacy round with an EMPTY selection (old "roll the whole pool") migrates to an
# explicit full names list, so its roll scope survives the drop of the theme concept:
# cursed → every hindrance name, blessed → every boon name.
func test_normalize_bakes_empty_legacy_pool() -> void:
	var cursed := JD.normalize_effect_round({"round_type": "cursed", "curse_random": true})
	assert_int((cursed["effects"] as Array).size()).is_equal(JD.CURSE_CATALOG.size())
	var blessed := JD.normalize_effect_round({"round_type": "blessed"})
	assert_int((blessed["effects"] as Array).size()).is_equal(JD.BLESSING_CATALOG.size())


# Ward is gone from the boon catalog entirely.
func test_ward_removed_from_catalog() -> void:
	for e: Dictionary in JD.BLESSING_CATALOG:
		assert_str(String(e.get("name", ""))).is_not_equal("Ward")


# ── Per-effect tuning + custom name/flavor (resolved_effect) ─────────────────


# resolved_effect overlays the round's override diff onto the catalog entry and stamps _ref.
func test_resolved_effect_merges_override() -> void:
	var r := JD.resolved_effect("Choked", {"Choked": {"min": 20, "max": 80, "name": "The Grip"}})
	assert_int(int(r["min"])).is_equal(20)  # overridden
	assert_int(int(r["max"])).is_equal(80)  # overridden
	assert_str(str(r["name"])).is_equal("The Grip")  # custom name
	assert_str(str(r["kind"])).is_equal("clamp")  # untouched catalog field kept
	assert_str(str(r["_ref"])).is_equal("Choked")  # original name preserved


func test_resolved_effect_defaults_when_no_override() -> void:
	var r := JD.resolved_effect("Shrunken", {})
	assert_float(float(r["factor"])).is_equal_approx(0.6, 0.0001)  # catalog default
	assert_str(str(r["_ref"])).is_equal("Shrunken")


func test_resolved_effect_unknown_is_empty() -> void:
	assert_bool(JD.resolved_effect("Nope", {}).is_empty()).is_true()


# Valence follows the ORIGINAL catalog effect (via _ref), so a renamed boon still reads green.
func test_valence_survives_rename() -> void:
	var r := JD.resolved_effect("Fervor", {"Fervor": {"name": "Ascension"}})
	assert_str(str(r["name"])).is_equal("Ascension")
	assert_bool(JD.effect_is_benefit(str(r["_ref"]))).is_true()


# Migrated / new rounds start with an empty override map (catalog defaults everywhere).
func test_normalize_empty_overrides() -> void:
	var out := JD.normalize_effect_round({"round_type": "cursed"})
	assert_bool((out["effect_overrides"] as Dictionary).is_empty()).is_true()


# Stroke kinds tune in the preview (is_stroke_effect); param specs drive the controls.
func test_effect_param_routing() -> void:
	assert_bool(JD.is_stroke_effect("scale")).is_true()
	assert_bool(JD.is_stroke_effect("toll")).is_false()
	assert_int(JD.effect_param_specs("scale").size()).is_equal(1)  # factor
	assert_int(JD.effect_param_specs("clamp").size()).is_equal(2)  # min + max
	assert_int(JD.effect_param_specs("toll").size()).is_equal(1)  # amount
	assert_int(JD.effect_param_specs("reverse").size()).is_equal(0)  # binary — no magnitude


# The tunable defaults live in the catalog so the controls pre-fill and the merge carries them.
func test_toll_interest_catalog_defaults() -> void:
	assert_int(int(JD.effect_entry("Toll").get("amount", -1))).is_equal(40)
	assert_float(float(JD.effect_entry("Interest").get("pct", -1.0))).is_equal_approx(0.25, 0.0001)


# A renamed sensory effect keeps its intensity: intensity_for looks up by _ref (the original
# catalog name the sensory_intensity map is keyed on), not the custom display name.
func test_sensory_intensity_survives_rename() -> void:
	var round := {"sensory_intensity": {"Murk": 0.9}}
	var resolved := JD.resolved_effect("Murk", {"Murk": {"name": "The Haze"}})
	assert_str(str(resolved["name"])).is_equal("The Haze")  # renamed
	assert_float(SensoryFX.intensity_for(round, resolved)).is_equal_approx(0.9, 0.0001)
