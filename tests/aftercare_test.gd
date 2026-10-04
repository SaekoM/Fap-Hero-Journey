extends GdUnitTestSuite

# Per-round aftercare: a round's own "I came" target (JourneyGraph.AFTERCARE_KEY), beside the journey's
# default aftercare. Covers the validation that keeps aftercare off the main journey, the journey.json
# round-trip, and how a rendition carries the link (compose, envelope, extraction). Pure graph rules.


func _n(type: String, outs: Array, aftercare: String = "") -> Dictionary:
	var out: Array = []
	for t: String in outs:
		out.append({"to": t})
	var n: Dictionary = {"type": type, "data": {}, "out": out}
	if aftercare != "":
		n[JourneyGraph.AFTERCARE_KEY] = aftercare
	return n


# start → a → boss → b (end). The boss links its own aftercare chain care1 → care2; "soft" is an
# unlinked aftercare storyboard used as the journey default in some tests.
func _journey() -> Dictionary:
	return {
		"start": "a",
		"nodes":
		{
			"a": _n("round", ["boss"]),
			"boss": _n("round", ["b"], "care1"),
			"b": _n("round", []),
			"care1": _n("storyboard", ["care2"]),
			"care2": _n("round", []),
			"soft": _n("storyboard", []),
		},
	}


func _kinds(graph: Dictionary, finish_id: String = "") -> Array:
	var kinds: Array = []
	for i: Dictionary in JourneyGraph.validate_graph(graph, finish_id):
		kinds.append(str(i["kind"]))
	return kinds


func _issues_of(graph: Dictionary, kind: String, finish_id: String = "") -> Array:
	return JourneyGraph.validate_graph(graph, finish_id).filter(
		func(i: Dictionary) -> bool: return str(i["kind"]) == kind
	)


# ── Queries ──────────────────────────────────────────────────────────────────


func test_aftercare_of_reads_rounds_only() -> void:
	var g := _journey()
	assert_str(JourneyGraph.aftercare_of(g, "boss")).is_equal("care1")
	assert_str(JourneyGraph.aftercare_of(g, "a")).is_equal("")
	# A link left on a non-round is ignored — the button only exists during rounds.
	g["nodes"]["soft"][JourneyGraph.AFTERCARE_KEY] = "care2"
	assert_str(JourneyGraph.aftercare_of(g, "soft")).is_equal("")


func test_aftercare_ids_cover_every_sequence_and_the_default() -> void:
	var ids := JourneyGraph.aftercare_ids(_journey(), "soft")
	assert_bool(ids.has("care1")).is_true()
	assert_bool(ids.has("care2")).is_true()  # reached through the sequence's out-edge
	assert_bool(ids.has("soft")).is_true()  # the default entry
	assert_bool(ids.has("boss")).is_false()


func test_drop_aftercare_link_restores_a_parent_value() -> void:
	var plain := _n("round", [], "care1")
	JourneyGraph.drop_aftercare_link(plain)
	assert_bool(plain.has(JourneyGraph.AFTERCARE_KEY)).is_false()
	# A rendition's overlay link on a parent round gives the parent's own link back.
	var marked := _n("round", [], "overlay_care")
	marked[JourneyGraph.AFTERCARE_PARENT_MARK] = {"to": "care1", "text": "SUBMIT"}
	JourneyGraph.drop_aftercare_link(marked)
	assert_str(str(marked[JourneyGraph.AFTERCARE_KEY])).is_equal("care1")
	assert_str(str(marked[JourneyGraph.AFTERCARE_TEXT_KEY])).is_equal("SUBMIT")  # the parent's words too
	assert_bool(marked.has(JourneyGraph.AFTERCARE_PARENT_MARK)).is_false()


# ── Validation ───────────────────────────────────────────────────────────────


func test_a_rounds_own_aftercare_is_not_unreachable() -> void:
	var kinds := _kinds(_journey(), "soft")
	assert_bool(kinds.has("unreachable")).is_false()  # care1, care2 (link) and soft (default) are exempt
	assert_bool(kinds.has("aftercare_in_journey")).is_false()
	assert_bool(kinds.has("aftercare_rejoins")).is_false()


func test_unlinked_aftercare_island_is_still_unreachable() -> void:
	var issues := _issues_of(_journey(), "unreachable")  # no default given → "soft" is just an island
	assert_int(issues.size()).is_equal(1)
	assert_str(str(issues[0]["id"])).is_equal("soft")


func test_link_into_the_journey_is_flagged_at_the_round() -> void:
	var g := _journey()
	g["nodes"]["boss"][JourneyGraph.AFTERCARE_KEY] = "b"  # b is a journey node
	var issues := _issues_of(g, "aftercare_in_journey")
	assert_int(issues.size()).is_equal(1)
	assert_str(str(issues[0]["id"])).is_equal("boss")
	assert_str(str(issues[0]["to"])).is_equal("b")


func test_default_aftercare_in_the_journey_is_flagged() -> void:
	var issues := _issues_of(_journey(), "default_aftercare_in_journey", "b")
	assert_int(issues.size()).is_equal(1)
	assert_str(str(issues[0]["id"])).is_equal("b")


func test_aftercare_leading_back_into_the_journey_is_flagged() -> void:
	var g := _journey()
	g["nodes"]["care2"]["out"] = [{"to": "b"}]  # the aftercare chain rejoins the journey
	var issues := _issues_of(g, "aftercare_rejoins")
	assert_int(issues.size()).is_equal(1)
	assert_str(str(issues[0]["id"])).is_equal("care2")
	assert_str(str(issues[0]["to"])).is_equal("b")


func test_shared_aftercare_is_fine() -> void:
	var g := _journey()
	g["nodes"]["a"][JourneyGraph.AFTERCARE_KEY] = "care1"  # two rounds share one sequence
	assert_array(JourneyGraph.validate_graph(g, "soft")).is_empty()


func test_dangling_aftercare_link_is_flagged() -> void:
	var g := _journey()
	g["nodes"]["boss"][JourneyGraph.AFTERCARE_KEY] = "gone"
	var issues := _issues_of(g, "dangling")
	assert_int(issues.size()).is_equal(1)
	assert_str(str(issues[0]["to"])).is_equal("gone")


# ── journey.json round-trip ──────────────────────────────────────────────────


func test_link_survives_to_json_and_back() -> void:
	var json := JourneyGraph.to_json(_journey())
	var back := JourneyGraph.from_json(json)
	assert_str(JourneyGraph.aftercare_of(back, "boss")).is_equal("care1")
	assert_bool((back["nodes"]["a"] as Dictionary).has(JourneyGraph.AFTERCARE_KEY)).is_false()


func test_builder_mark_is_never_serialized() -> void:
	var g := _journey()
	g["nodes"]["boss"][JourneyGraph.AFTERCARE_PARENT_MARK] = ""
	for entry: Dictionary in JourneyGraph.to_json(g)["Nodes"] as Array:
		assert_bool(entry.has(JourneyGraph.AFTERCARE_PARENT_MARK)).is_false()


# ── Renditions ───────────────────────────────────────────────────────────────


func test_compose_sets_a_parent_rounds_link() -> void:
	var delta := {
		"nodes": {"r_care": _n("storyboard", [])},
		"aftercare_links": [{"node": "a", "to": "r_care"}],
	}
	var out := JourneyCompose.compose_graph(_journey(), delta)
	assert_array(out["errors"]).is_empty()
	assert_str(JourneyGraph.aftercare_of(out["graph"], "a")).is_equal("r_care")


func test_compose_replaces_the_parents_link_without_touching_the_parent() -> void:
	var parent := _journey()
	var delta := {
		"nodes": {"r_care": _n("storyboard", [])},
		"aftercare_links": [{"node": "boss", "to": "r_care"}],
	}
	var out := JourneyCompose.compose_graph(parent, delta)
	assert_str(JourneyGraph.aftercare_of(out["graph"], "boss")).is_equal("r_care")
	assert_str(JourneyGraph.aftercare_of(parent, "boss")).is_equal("care1")  # parent unchanged


func test_compose_breaks_loudly_on_a_bad_link() -> void:
	var delta := {
		"aftercare_links":
		[
			{"node": "nope", "to": "care1"},
			{"node": "care1", "to": "care2"},  # a storyboard, not a round
			{"node": "a", "to": "nope"},
		]
	}
	var kinds: Array = []
	for e: Dictionary in JourneyCompose.compose_graph(_journey(), delta)["errors"]:
		kinds.append(str(e["kind"]))
	assert_array(kinds).contains_exactly(
		["missing_aftercare_node", "aftercare_not_round", "missing_aftercare_target"]
	)


func test_rendition_envelope_round_trips_links() -> void:
	var rendition := {
		"name": "Boss Aftercare",
		"parent_id": "j_parent",
		"nodes": {},
		"aftercare_links": [{"node": "boss", "to": "r_care", "text": "Submit to Mira"}],
	}
	var json := JourneyRendition.coerce_rendition(rendition)
	assert_array(json["AftercareLinks"]).is_equal(
		[{"Node": "boss", "To": "r_care", "Text": "Submit to Mira"}]
	)
	var parsed := JourneyRendition.parse_rendition(json)
	assert_array(parsed["aftercare_links"]).is_equal(
		[{"node": "boss", "to": "r_care", "text": "Submit to Mira"}]
	)


func test_extracting_an_aftercare_sequence_carries_the_link() -> void:
	# Pull the boss's aftercare chain into a rendition: the base round loses the link, the rendition
	# carries it, and the link alone is enough to attach (no ordinary anchor exists).
	var out := JourneyExtract.extract_rendition(_journey(), ["care1", "care2"])
	assert_array(out["errors"]).is_empty()
	var base_boss: Dictionary = out["base"]["nodes"]["boss"]
	assert_bool(base_boss.has(JourneyGraph.AFTERCARE_KEY)).is_false()
	assert_array(out["rendition"]["aftercare_links"]).is_equal(
		[{"node": "boss", "to": "care1", "text": ""}]
	)
	# And composing it back restores the original link.
	var back := JourneyCompose.compose_graph(out["base"], out["rendition"])
	assert_str(JourneyGraph.aftercare_of(back["graph"], "boss")).is_equal("care1")


# The hold text travels with the link: through journey.json, and when a rendition overlays a parent round.
func test_hold_text_round_trips_and_composes() -> void:
	var g := _journey()
	JourneyGraph.set_aftercare_link(g["nodes"]["boss"], "care1", "Submit to Mira")
	var back := JourneyGraph.from_json(JourneyGraph.to_json(g))
	assert_str(JourneyGraph.aftercare_text_of(back, "boss")).is_equal("Submit to Mira")
	var delta := {
		"nodes": {"r_care": _n("storyboard", [])},
		"aftercare_links": [{"node": "a", "to": "r_care", "text": "Kneel"}],
	}
	var out := JourneyCompose.compose_graph(_journey(), delta)
	assert_str(JourneyGraph.aftercare_text_of(out["graph"], "a")).is_equal("Kneel")


# Dropping a link drops its text with it.
func test_drop_aftercare_link_drops_its_text() -> void:
	var n := _n("round", [])
	JourneyGraph.set_aftercare_link(n, "care1", "Submit")
	JourneyGraph.drop_aftercare_link(n)
	assert_bool(n.has(JourneyGraph.AFTERCARE_TEXT_KEY)).is_false()
