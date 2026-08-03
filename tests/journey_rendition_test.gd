extends GdUnitTestSuite

# JourneyRendition: the rendition journey.json data model — is_rendition detection, and the coerce/parse
# round-trip between the authoring/runtime shape and the on-disk PascalCase envelope. Also confirms a
# parsed rendition actually composes onto a parent via JourneyCompose. Pure schema mapping, no I/O.


func _runtime_rendition() -> Dictionary:
	return {
		"name": "Extra Ending",
		"author": "Me",
		"description": "Adds a secret ending",
		"parent_id": "j_parent",
		"parent_min_version": "",
		"nodes": {"r1": {"type": "round", "data": {"video_path": "content/x.mp4"}, "out": []}},
		"anchors": [{"anchor": "end", "edge": {"to": "r1", "name": "Continue"}}],
		"slot_fills":
		[{"node": "base", "field": "axis_scripts", "channel": "L0", "path": "content/a.funscript"}],
	}


# ── Detection ────────────────────────────────────────────────────────────────


func test_is_rendition() -> void:
	assert_bool(JourneyRendition.is_rendition({"Type": "rendition"})).is_true()
	assert_bool(JourneyRendition.is_rendition({"Name": "A normal journey"})).is_false()
	assert_bool(JourneyRendition.is_rendition({})).is_false()


# ── Coerce → parse round-trip ─────────────────────────────────────────────────


func test_coerce_stamps_the_envelope() -> void:
	var json := JourneyRendition.coerce_rendition(_runtime_rendition())
	assert_str(str(json["Type"])).is_equal("rendition")
	assert_str(str(json["ParentId"])).is_equal("j_parent")
	assert_str(str(json["JourneyId"])).starts_with("j_")  # the rendition's OWN id, minted on coerce
	assert_int((json["Nodes"] as Array).size()).is_equal(1)
	assert_int((json["Anchors"] as Array).size()).is_equal(1)
	assert_int((json["SlotFills"] as Array).size()).is_equal(1)


func test_round_trip_preserves_the_delta() -> void:
	var rt := JourneyRendition.parse_rendition(
		JourneyRendition.coerce_rendition(_runtime_rendition())
	)
	assert_str(str(rt["parent_id"])).is_equal("j_parent")
	assert_bool((rt["nodes"] as Dictionary).has("r1")).is_true()


# A rendition carries its own name/description (shown in Journey Select on VERSION select) through coerce/parse.
func test_round_trip_preserves_identity() -> void:
	var json := JourneyRendition.coerce_rendition(_runtime_rendition())
	assert_str(str(json["Name"])).is_equal("Extra Ending")
	assert_str(str(json["Description"])).is_equal("Adds a secret ending")
	var rt := JourneyRendition.parse_rendition(json)
	assert_str(str(rt["name"])).is_equal("Extra Ending")
	assert_str(str(rt["description"])).is_equal("Adds a secret ending")

	var anchors: Array = rt["anchors"]
	assert_int(anchors.size()).is_equal(1)
	assert_str(str((anchors[0] as Dictionary)["anchor"])).is_equal("end")
	assert_str(str(((anchors[0] as Dictionary)["edge"] as Dictionary)["to"])).is_equal("r1")
	# An ending-extend anchor carries no slot.
	assert_bool((anchors[0] as Dictionary).has("slot")).is_false()


# A fork open-slot fill carries its choice index through the coerce/parse round-trip (envelope key "Slot").
func test_round_trip_preserves_fork_slot_anchor() -> void:
	var rendition := _runtime_rendition()
	rendition["anchors"] = [{"anchor": "fork", "edge": {"to": "r1"}, "slot": 2}]
	var rt := JourneyRendition.parse_rendition(JourneyRendition.coerce_rendition(rendition))
	var anchor: Dictionary = rt["anchors"][0]
	assert_int(int(anchor["slot"])).is_equal(2)
	assert_str(str((anchor["edge"] as Dictionary)["to"])).is_equal("r1")


# An overlay fork choice (append-anchor, no slot) round-trips its label, card image, AND its full-parity
# gate/effect fields (weight, required item, threshold, set_counters, …) so it behaves like a base choice.
func test_round_trip_preserves_overlay_fork_choice_context() -> void:
	var rendition := _runtime_rendition()
	rendition["anchors"] = [
		{
			"anchor": "fork",
			"edge":
			{
				"to": "r1",
				"name": "Alt Path",
				"image_path": "content/alt.png",
				"weight": 3,
				"required_item": "key",
				"threshold": 50,
				"set_counters": {"resolve": 1},
			}
		}
	]
	var rt := JourneyRendition.parse_rendition(JourneyRendition.coerce_rendition(rendition))
	var edge: Dictionary = rt["anchors"][0]["edge"]
	assert_str(str(edge["name"])).is_equal("Alt Path")
	assert_str(str(edge["image_path"])).is_equal("content/alt.png")
	assert_int(int(edge["weight"])).is_equal(3)
	assert_str(str(edge["required_item"])).is_equal("key")
	assert_int(int(edge["threshold"])).is_equal(50)
	assert_int(int((edge["set_counters"] as Dictionary)["resolve"])).is_equal(1)
	assert_bool((rt["anchors"][0] as Dictionary).has("slot")).is_false()  # an append, not a slot fill

	var fills: Array = rt["slot_fills"]
	assert_int(fills.size()).is_equal(1)
	assert_str(str((fills[0] as Dictionary)["node"])).is_equal("base")
	assert_str(str((fills[0] as Dictionary)["field"])).is_equal("axis_scripts")
	assert_str(str((fills[0] as Dictionary)["channel"])).is_equal("L0")
	assert_str(str((fills[0] as Dictionary)["path"])).is_equal("content/a.funscript")


# ── A parsed rendition composes onto its parent ───────────────────────────────


func test_parsed_rendition_composes_cleanly() -> void:
	# A base with a terminal "end" and a base round "base" to receive the axis fill.
	var parent := {
		"start": "end",
		"nodes":
		{
			"end": {"type": "round", "data": {}, "out": []},
			"base": {"type": "round", "data": {}, "out": []},
		},
	}
	var rt := JourneyRendition.parse_rendition(
		JourneyRendition.coerce_rendition(_runtime_rendition())
	)
	var out := JourneyCompose.compose_graph(parent, rt)
	assert_array(out["errors"]).is_empty()
	# New node grafted on, the anchor extended "end", and the axis slot on "base" got filled.
	assert_bool((out["graph"]["nodes"] as Dictionary).has("r1")).is_true()
	assert_int((out["graph"]["nodes"]["end"]["out"] as Array).size()).is_equal(1)
	assert_str(str(out["graph"]["nodes"]["base"]["data"]["axis_scripts"]["L0"])).is_equal(
		"content/a.funscript"
	)


# ── Per-origin path resolution ────────────────────────────────────────────────


func test_resolve_delta_paths() -> void:
	var delta := {
		"nodes":
		{
			"r1":
			{
				"type": "round",
				"data": {"video_path": "content/x.mp4", "funscript_path": "content/x.funscript"},
				"out": [],
			}
		},
		"anchors": [{"anchor": "end", "edge": {"to": "r1", "image_path": "media/card.png"}}],
		"slot_fills":
		[{"node": "base", "field": "axis_scripts", "channel": "L0", "path": "content/a.funscript"}],
	}
	JourneyRendition.resolve_delta_paths(delta, "user://journeys/Rend")
	assert_str(str(delta["nodes"]["r1"]["data"]["video_path"])).is_equal(
		"user://journeys/Rend/content/x.mp4"
	)
	assert_str(str((delta["anchors"][0]["edge"] as Dictionary)["image_path"])).is_equal(
		"user://journeys/Rend/media/card.png"
	)
	assert_str(str((delta["slot_fills"][0] as Dictionary)["path"])).is_equal(
		"user://journeys/Rend/content/a.funscript"
	)


# ── Part-1 → Part-2 resume entry (feature #5) ─────────────────────────────────


func test_resume_entry_matches_the_reached_endings_anchor() -> void:
	# Two ending-extend anchors; a player who ended at "end_b" resumes into that ending's continuation.
	var anchors := [
		{"anchor": "end_a", "edge": {"to": "r_a"}},
		{"anchor": "end_b", "edge": {"to": "r_b"}},
	]
	assert_str(JourneyRendition.resume_entry(anchors, "end_b")).is_equal("r_b")
	assert_str(JourneyRendition.resume_entry(anchors, "end_a")).is_equal("r_a")


func test_resume_entry_none_when_reached_ending_isnt_extended() -> void:
	# Precise match: an ending this rendition doesn't attach to yields no resume (empty string).
	var anchors := [{"anchor": "end_a", "edge": {"to": "r_a"}}]
	assert_str(JourneyRendition.resume_entry(anchors, "end_z")).is_equal("")
	assert_str(JourneyRendition.resume_entry(anchors, "")).is_equal("")


func test_resume_entry_ignores_fork_slot_fills() -> void:
	# A fork slot-fill anchor is a mid-flow choice, not an ending continuation — never a resume target.
	var anchors := [{"anchor": "fork", "edge": {"to": "r_c"}, "slot": 1}]
	assert_str(JourneyRendition.resume_entry(anchors, "fork")).is_equal("")


# ── Scanner grouping ──────────────────────────────────────────────────────────


func test_group_renditions_attaches_and_drops_orphans() -> void:
	var journeys := [
		{"journey_id": "j_base", "title": "Base"}, {"journey_id": "j_other", "title": "Other"}
	]
	var renditions := [
		{"journey_id": "r_a", "parent_id": "j_base", "folder": "/A", "name": "Extra Ending"},
		{"journey_id": "r_x", "parent_id": "j_missing", "folder": "/X", "name": "Orphan"},  # parent absent
	]
	JourneyScanner.group_renditions(journeys, renditions)
	assert_int((journeys[0]["renditions"] as Array).size()).is_equal(1)
	var a: Dictionary = journeys[0]["renditions"][0]
	assert_str(str(a["name"])).is_equal("Extra Ending")
	assert_array(a["chain_folders"] as Array).is_equal(["/A"])  # direct child → chain is just itself
	assert_int((journeys[1]["renditions"] as Array).size()).is_equal(0)  # the orphan attached nowhere


# Sibling-dependency: a rendition whose ParentId is ANOTHER rendition attaches to the ULTIMATE base, and
# its chain composes the whole stack base-ward (…ancestors…, self).
func test_group_renditions_resolves_a_chain() -> void:
	var journeys := [{"journey_id": "j_base", "title": "Base"}]
	var renditions := [
		{"journey_id": "r_b", "parent_id": "r_a", "folder": "/B", "name": "Video Overlay"},
		{"journey_id": "r_a", "parent_id": "j_base", "folder": "/A", "name": "Script Overlay"},
	]
	JourneyScanner.group_renditions(journeys, renditions)
	assert_int((journeys[0]["renditions"] as Array).size()).is_equal(2)  # both flatten under the base
	var by_name: Dictionary = {}
	for r: Dictionary in journeys[0]["renditions"]:
		by_name[str(r["name"])] = r
	# B stacks on A: compose A THEN B; A is a lone layer.
	assert_array((by_name["Video Overlay"] as Dictionary)["chain_folders"] as Array).is_equal(
		["/A", "/B"]
	)
	assert_array((by_name["Script Overlay"] as Dictionary)["chain_folders"] as Array).is_equal(
		["/A"]
	)


func test_group_renditions_drops_a_cyclic_chain() -> void:
	var journeys := [{"journey_id": "j_base", "title": "Base"}]
	var renditions := [
		{"journey_id": "r_a", "parent_id": "r_b", "folder": "/A", "name": "A"},
		{"journey_id": "r_b", "parent_id": "r_a", "folder": "/B", "name": "B"},  # A↔B loop → both dropped
	]
	JourneyScanner.group_renditions(journeys, renditions)
	assert_int((journeys[0]["renditions"] as Array).size()).is_equal(0)
