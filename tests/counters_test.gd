extends GdUnitTestSuite

# Named counters — the pure authoring/serialization layer: cleaning a {name: delta} map, coercing it
# onto a node, and the declared-counter registry (bounds, starts, labels). The runtime accumulation
# + fork gating lives in GameState (C#) and is covered in gamestate_fork_test.gd.


func test_clean_counter_deltas() -> void:
	var d: Dictionary = JourneyData.clean_counter_deltas({"belt": 2, " x ": 0, "": 4, "y": -3})
	assert_int(d.size()).is_equal(2)  # x dropped (0), "" dropped (blank)
	assert_int(int(d["belt"])).is_equal(2)
	assert_int(int(d["y"])).is_equal(-3)


# Coercion drops an empty/zero-only map so journey.json stays lean (mirrors set_flags), and keeps a
# real one.
func test_coerce_prunes_empty_counters() -> void:
	var out: Dictionary = JourneyData.coerce_node_save_data(
		"round", {"set_counters": {"belt": 0, "": 3}}
	)
	assert_bool(out.has("set_counters")).is_false()


func test_coerce_keeps_real_counters() -> void:
	var out: Dictionary = JourneyData.coerce_node_save_data(
		"storyboard", {"set_counters": {"arousal": 2}}
	)
	assert_int(int((out["set_counters"] as Dictionary)["arousal"])).is_equal(2)


# A conditional fork on a counter records which counter it gates on.
func test_coerce_fork_cond_counter() -> void:
	var out: Dictionary = JourneyData.coerce_node_save_data(
		"fork", {"cond_metric": "counter", "cond_counter": "satisfied_partners"}
	)
	assert_str(str(out["cond_metric"])).is_equal("counter")
	assert_str(str(out["cond_counter"])).is_equal("satisfied_partners")


# ── Declared counters (bounds, starts, labels) ──────────────────────
# The registry's whole job is that a counter cannot leave its range however it is written to. The
# runtime clamp lives in GameState (C#); these cover the pure model it reads.


func _def(name: String, lo: Variant, hi: Variant, start: int = 0) -> Dictionary:
	var d: Dictionary = JourneyData.new_counter_def(name)
	d["has_min"] = lo != null
	d["min"] = int(lo) if lo != null else 0
	d["has_max"] = hi != null
	d["max"] = int(hi) if hi != null else 0
	d["start"] = start
	return d


func test_clamp_holds_both_ends() -> void:
	var ammo: Dictionary = _def("ammo", 0, 12)
	assert_int(JourneyData.clamp_counter(ammo, -3)).is_equal(0)
	assert_int(JourneyData.clamp_counter(ammo, 40)).is_equal(12)
	assert_int(JourneyData.clamp_counter(ammo, 7)).is_equal(7)


# A floor with no ceiling is the "resource" case the feature exists for: ammo must never go negative,
# but nothing says how much of it a journey may hand out.
func test_one_sided_bounds_leave_the_other_end_alone() -> void:
	var floored: Dictionary = _def("ammo", 0, null)
	assert_int(JourneyData.clamp_counter(floored, -1)).is_equal(0)
	assert_int(JourneyData.clamp_counter(floored, 9999)).is_equal(9999)
	var capped: Dictionary = _def("arousal", null, 100)
	assert_int(JourneyData.clamp_counter(capped, 240)).is_equal(100)
	assert_int(JourneyData.clamp_counter(capped, -50)).is_equal(-50)


# The compatibility promise: a name no row covers behaves exactly as it did before the registry.
func test_an_undeclared_counter_is_never_clamped() -> void:
	var defs: Array = [_def("ammo", 0, 12)]
	assert_int(JourneyData.clamp_counter_by_name(defs, "stress", -80)).is_equal(-80)
	assert_int(JourneyData.clamp_counter_by_name(defs, "stress", 9001)).is_equal(9001)
	assert_int(JourneyData.clamp_counter_by_name(defs, "ammo", 9001)).is_equal(12)


func test_the_presets_are_the_ranges_they_claim() -> void:
	var percent: Dictionary = JourneyData.COUNTER_PRESETS["percent"]
	assert_int(JourneyData.clamp_counter(percent, 140)).is_equal(100)
	assert_int(JourneyData.clamp_counter(percent, -1)).is_equal(0)
	var resource: Dictionary = JourneyData.COUNTER_PRESETS["resource"]
	assert_int(JourneyData.clamp_counter(resource, -1)).is_equal(0)
	assert_int(JourneyData.clamp_counter(resource, 500)).is_equal(500)
	var free: Dictionary = JourneyData.COUNTER_PRESETS["free"]
	assert_int(JourneyData.clamp_counter(free, -500)).is_equal(-500)


# A ceiling under its floor would clamp everything to one number and kill every gate above it. Parsing
# widens the ceiling instead, so the counter still works and the mistake stays visible.
func test_a_ceiling_below_its_floor_is_widened_on_parse() -> void:
	var parsed: Dictionary = JourneyData.parse_counter_def(
		{"Name": "x", "HasMin": true, "Min": 10, "HasMax": true, "Max": 2}
	)
	assert_int(int(parsed["max"])).is_equal(10)
	assert_int(JourneyData.clamp_counter(parsed, 10)).is_equal(10)


func test_starting_values_skip_the_ones_that_start_at_zero() -> void:
	var starts: Dictionary = JourneyData.counter_start_values(
		[_def("ammo", 0, 12, 12), _def("kills", 0, null, 0)]
	)
	assert_int(int(starts["ammo"])).is_equal(12)
	assert_bool(starts.has("kills")).is_false()  # 0 is what a missing counter already reads as


# A start outside its own range would put the run somewhere no node could take it.
func test_a_start_outside_the_range_is_clamped() -> void:
	var starts: Dictionary = JourneyData.counter_start_values([_def("ammo", 0, 12, 99)])
	assert_int(int(starts["ammo"])).is_equal(12)


func test_round_trip_through_disk_keeps_every_field() -> void:
	var def: Dictionary = _def("ammo", 0, 12, 12)
	def["label"] = "Handgun Ammo"
	def["note"] = "spent by the pistol fork"
	def["shown"] = true
	var back: Array = JourneyData.parse_counter_defs(JourneyData.coerce_counter_defs([def]))
	assert_int(back.size()).is_equal(1)
	assert_dict(back[0]).is_equal(def)


func test_an_unnamed_row_never_reaches_disk() -> void:
	var out: Array = JourneyData.coerce_counter_defs(
		[JourneyData.new_counter_def(""), JourneyData.new_counter_def("ammo")]
	)
	assert_int(out.size()).is_equal(1)
	assert_str(str((out[0] as Dictionary)["Name"])).is_equal("ammo")


# Two rows for one name would make "the ammo ceiling" ambiguous. First wins — the same rule a
# rendition's additive merge follows.
func test_a_duplicate_name_is_dropped_on_parse() -> void:
	var defs: Array = (
		JourneyData
		. parse_counter_defs(
			[
				{"Name": "ammo", "HasMax": true, "Max": 12},
				{"Name": "ammo", "HasMax": true, "Max": 99},
			]
		)
	)
	assert_int(defs.size()).is_equal(1)
	assert_int(int((defs[0] as Dictionary)["max"])).is_equal(12)


# A journey written before the registry carries only ShownCounters. Those names become declared
# counters that are shown and unbounded — which is exactly how they behaved — so upgrading changes
# nothing about the run, only what the author can now edit.
func test_a_pre_registry_journey_migrates_from_shown_counters() -> void:
	var defs: Array = JourneyData.counter_defs_from_disk({"ShownCounters": ["belt", "arousal"]})
	assert_int(defs.size()).is_equal(2)
	var belt: Dictionary = JourneyData.counter_def(defs, "belt")
	assert_bool(bool(belt["shown"])).is_true()
	assert_bool(bool(belt["has_min"])).is_false()
	assert_bool(bool(belt["has_max"])).is_false()
	assert_int(JourneyData.clamp_counter(belt, -40)).is_equal(-40)


# Once a registry exists it is the only source: a stale ShownCounters beside it (written by an older
# build, or by this one for that build's benefit) must not resurrect a counter the author deleted.
func test_the_registry_wins_over_a_stale_shown_counters_list() -> void:
	var defs: Array = JourneyData.counter_defs_from_disk(
		{"Counters": [{"Name": "ammo", "Shown": true}], "ShownCounters": ["ammo", "deleted"]}
	)
	assert_int(defs.size()).is_equal(1)
	assert_array(JourneyData.shown_counter_names(defs)).is_equal(["ammo"])


func test_display_name_prefers_the_label() -> void:
	var defs: Array = [JourneyData.new_counter_def("ammo")]
	assert_str(JourneyData.counter_display_name(defs, "ammo")).is_equal("ammo")
	(defs[0] as Dictionary)["label"] = "Handgun Ammo"
	assert_str(JourneyData.counter_display_name(defs, "ammo")).is_equal("Handgun Ammo")
	# An undeclared counter still has a name to show.
	assert_str(JourneyData.counter_display_name(defs, "stress")).is_equal("stress")


func test_range_text_says_no_limits_rather_than_a_number() -> void:
	assert_str(JourneyData.counter_range_text(_def("a", 0, 12))).is_equal("0 – 12")
	assert_str(JourneyData.counter_range_text(_def("a", 0, null))).is_equal("0 and up")
	assert_str(JourneyData.counter_range_text(_def("a", null, 100))).is_equal("up to 100")
	assert_str(JourneyData.counter_range_text(_def("a", null, null))).is_equal("no limits")


# Everywhere a counter can be named, so the editor's "add the ones this journey already uses" offers
# all of them: node rewards, fork gates, loop conditions, and a fork choice's own reward.
func test_names_in_graph_finds_every_place_a_counter_is_used() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"a": {"type": "round", "data": {"set_counters": {"kills": 1}}, "out": []},
			"b":
			{
				"type": "fork",
				"data": {"cond_counter": "arousal", "loop_conditions": [{"counter": "laps"}]},
				"out": [{"to": "a", "set_counters": {"ammo": -1}, "cond_counter": "ammo"}],
			},
		}
	}
	assert_array(JourneyData.counter_names_in_graph(graph)).is_equal(
		["ammo", "arousal", "kills", "laps"]
	)


func test_names_in_graph_ignores_a_zero_delta() -> void:
	var graph: Dictionary = {
		"nodes": {"a": {"type": "round", "data": {"set_counters": {"noop": 0}}, "out": []}}
	}
	assert_array(JourneyData.counter_names_in_graph(graph)).is_empty()


# Renditions compose counters by NAME (settings and cast use ids). The base's entry always wins, so a
# rendition can add a counter but never re-bound one every other rendition shares.
func test_a_rendition_adds_counters_but_cannot_rebound_the_bases() -> void:
	var base: Array = [_def("ammo", 0, 12)]
	var overlay: Array = [_def("ammo", 0, 999), _def("charges", 0, 3)]
	var merged: Array = JourneyData.merge_by_id(base, overlay, "name")
	assert_int(merged.size()).is_equal(2)
	assert_int(int(JourneyData.counter_def(merged, "ammo")["max"])).is_equal(12)
	assert_int(int(JourneyData.counter_def(merged, "charges")["max"])).is_equal(3)


# ── The builder's counter-change rows ─────────────────────────────
# A node's counter changes are edited as rows and stored as a map. Rows can hold what a map cannot —
# a row with no counter picked yet, and two rows pointing at the same one.


func test_rows_become_the_map_the_runtime_reads() -> void:
	var map: Dictionary = JourneyData.counter_rows_to_map(
		[{"name": "ammo", "delta": -1}, {"name": "kills", "delta": 1}]
	)
	assert_int(map.size()).is_equal(2)
	assert_int(int(map["ammo"])).is_equal(-1)
	assert_int(int(map["kills"])).is_equal(1)


# A row that has just been added has no counter yet. It has to survive in the editor without reaching
# the node, or adding a row would write a nameless counter change.
func test_a_row_with_no_counter_chosen_writes_nothing() -> void:
	var map: Dictionary = JourneyData.counter_rows_to_map(
		[{"name": "", "delta": 3}, {"name": "  ", "delta": 5}, {"name": "ammo", "delta": -1}]
	)
	assert_int(map.size()).is_equal(1)
	assert_int(int(map["ammo"])).is_equal(-1)


# Two rows can name one counter — nothing stops picking the same one twice. A map holds one value, so
# they sum: the alternative is one row silently winning and the other's number vanishing.
func test_two_rows_on_one_counter_sum() -> void:
	var map: Dictionary = JourneyData.counter_rows_to_map(
		[{"name": "ammo", "delta": -1}, {"name": "ammo", "delta": -2}]
	)
	assert_int(int(map["ammo"])).is_equal(-3)


# Summing to zero is no change at all, and a +0 has never been written to journey.json.
func test_rows_that_cancel_out_leave_nothing_behind() -> void:
	var map: Dictionary = JourneyData.counter_rows_to_map(
		[{"name": "ammo", "delta": 2}, {"name": "ammo", "delta": -2}]
	)
	assert_bool(map.has("ammo")).is_false()


# ── Declared flags ────────────────────────────────────────────
# The counter registry's boolean twin. Nothing to bound, so the whole model is name/label/note — what
# it buys is the picker, and the audit's ability to tell a declared flag from a typo.


func test_flag_round_trip_through_disk() -> void:
	var def: Dictionary = JourneyData.new_flag_def("found_key")
	def["label"] = "Found the key"
	def["note"] = "set by the cellar fork"
	var back: Array = JourneyData.parse_flag_defs(JourneyData.coerce_flag_defs([def]))
	assert_int(back.size()).is_equal(1)
	assert_dict(back[0]).is_equal(def)


func test_an_unnamed_flag_row_never_reaches_disk() -> void:
	var out: Array = JourneyData.coerce_flag_defs(
		[JourneyData.new_flag_def(""), JourneyData.new_flag_def("found_key")]
	)
	assert_int(out.size()).is_equal(1)
	assert_str(str((out[0] as Dictionary)["Name"])).is_equal("found_key")


func test_a_duplicate_flag_name_is_dropped_on_parse() -> void:
	var defs: Array = JourneyData.parse_flag_defs(
		[{"Name": "found_key", "Label": "First"}, {"Name": "found_key", "Label": "Second"}]
	)
	assert_int(defs.size()).is_equal(1)
	assert_str(str((defs[0] as Dictionary)["label"])).is_equal("First")


func test_flag_display_name_prefers_the_label() -> void:
	var defs: Array = [JourneyData.new_flag_def("found_key")]
	assert_str(JourneyData.flag_display_name(defs, "found_key")).is_equal("found_key")
	(defs[0] as Dictionary)["label"] = "Found the key"
	assert_str(JourneyData.flag_display_name(defs, "found_key")).is_equal("Found the key")
	assert_str(JourneyData.flag_display_name(defs, "stranger")).is_equal("stranger")


# Every place a flag can be named, so the editor's "add the ones this journey already uses" offers all
# of them — including the boss outcome flags, which live inside a round's timeline rather than in its
# set_flags and so used to be invisible to anything looking for flag names.
func test_flag_names_in_graph_finds_every_place_a_flag_is_used() -> void:
	var graph: Dictionary = {
		"nodes":
		{
			"a":
			{
				"type": "round",
				"data": {"set_flags": ["lit_lamp"], "clear_flags": ["in_the_dark"]},
				"out": [],
			},
			"b":
			{
				"type": "fork",
				"data": {"loop_conditions": [{"kind": "flag", "flag": "had_enough"}]},
				"out": [{"to": "a", "required_flag": "lit_lamp", "set_flags": ["chose_mercy"]}],
			},
		}
	}
	assert_array(JourneyData.flag_names_in_graph(graph)).is_equal(
		["chose_mercy", "had_enough", "in_the_dark", "lit_lamp"]
	)


# ── The builder's flag-change rows ──────────────────────────────
# A node's flag changes are edited as rows and stored as two lists. Rows can hold what the lists
# cannot: one with no flag picked yet, and one moving between setting and clearing.


func test_rows_split_into_the_two_lists_a_node_stores() -> void:
	var lists: Dictionary = (
		JourneyData
		. flag_rows_to_lists(
			[
				{"name": "lit_lamp", "mode": "set"},
				{"name": "in_the_dark", "mode": "clear"},
				{"name": "chose_mercy", "mode": "set"},
			]
		)
	)
	assert_array(lists["set_flags"]).is_equal(["lit_lamp", "chose_mercy"])
	assert_array(lists["clear_flags"]).is_equal(["in_the_dark"])


func test_a_flag_row_with_nothing_picked_writes_nothing() -> void:
	var lists: Dictionary = JourneyData.flag_rows_to_lists(
		[{"name": "", "mode": "set"}, {"name": "  ", "mode": "clear"}]
	)
	assert_array(lists["set_flags"]).is_empty()
	assert_array(lists["clear_flags"]).is_empty()


# A flag cannot both set and clear on one node — the lists are sets. The later row wins, because it is
# the one the author just touched.
func test_a_flag_named_twice_keeps_its_last_row() -> void:
	var lists: Dictionary = JourneyData.flag_rows_to_lists(
		[{"name": "lit_lamp", "mode": "set"}, {"name": "lit_lamp", "mode": "clear"}]
	)
	assert_array(lists["set_flags"]).is_empty()
	assert_array(lists["clear_flags"]).is_equal(["lit_lamp"])


# A row with no mode is a set: that is what adding a row means, and what every flag field did before
# clearing existed.
func test_a_row_without_a_mode_sets() -> void:
	var lists: Dictionary = JourneyData.flag_rows_to_lists([{"name": "lit_lamp"}])
	assert_array(lists["set_flags"]).is_equal(["lit_lamp"])
