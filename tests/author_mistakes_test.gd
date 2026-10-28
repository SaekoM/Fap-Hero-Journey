extends GdUnitTestSuite

# Two authoring mistakes from 0.9.1 bug reports that look like engine bugs in play:
#  - a counter spelt two ways ("Hangun Ammo" spends, "Handgun Ammo" gates), so a fork never opens;
#  - a requirement on a fork's DEFAULT choice, which never applies because the default is the fallback.
# The audit and the builder now name both.

const DECLARED: Array = ["Stress", "Arousal", "Handgun Ammo"]

# ── Counter names ────────────────────────────────────────────────────────────


func test_a_differently_capitalised_counter_is_matched() -> void:
	assert_str(JourneyData.likely_counter_match("stress", DECLARED)).is_equal("Stress")
	assert_str(JourneyData.likely_counter_match("arousal", DECLARED)).is_equal("Arousal")


func test_a_misspelt_counter_is_matched() -> void:
	assert_str(JourneyData.likely_counter_match("Hangun Ammo", DECLARED)).is_equal("Handgun Ammo")
	assert_str(JourneyData.likely_counter_match("Atress", DECLARED)).is_equal("Stress")


func test_a_declared_or_unrelated_counter_is_left_alone() -> void:
	assert_str(JourneyData.likely_counter_match("Stress", DECLARED)).is_empty()
	assert_str(JourneyData.likely_counter_match("Loot", DECLARED)).is_empty()


func _graph(nodes: Dictionary) -> Dictionary:
	return {"start": "", "nodes": nodes}


func test_counter_uses_list_every_node_that_sets_or_reads() -> void:
	var graph: Dictionary = _graph(
		{
			"a": {"type": "round", "data": {"set_counters": {"Hangun Ammo": -7}}, "out": []},
			"b":
			{
				"type": "fork",
				"data": {"cond_counter": "Handgun Ammo"},
				"out": [{"set_counters": {"stress": 10}, "cond_counter": "Handgun Ammo"}],
			},
		}
	)
	var uses: Dictionary = JourneyData.counter_uses_in_graph(graph)
	assert_array(uses["Hangun Ammo"]).is_equal(["a"])
	assert_array(uses["Handgun Ammo"]).is_equal(["b"])
	assert_array(uses["stress"]).is_equal(["b"])


func test_the_audit_names_the_mismatch_and_its_match() -> void:
	var graph: Dictionary = _graph(
		{"a": {"type": "round", "data": {"set_counters": {"Hangun Ammo": -7}}, "out": []}}
	)
	var ctx: Dictionary = {"counters": [{"name": "Handgun Ammo"}]}
	var findings: Array = JourneyAudit._counter_name_findings(graph, ctx)
	assert_int(findings.size()).is_equal(1)
	assert_str(findings[0]["kind"]).is_equal("counter_name_mismatch")
	assert_str(findings[0]["node_id"]).is_equal("a")
	assert_str(findings[0]["msg"]).contains('"Handgun Ammo"')


# ── The default choice ───────────────────────────────────────────────────────


func _fork(metric: String, default_path: int, out: Array) -> Dictionary:
	return {
		"data": {"resolution": "conditional", "cond_metric": metric, "default_path": default_path},
		"out": out,
	}


func test_a_requirement_on_the_default_is_flagged() -> void:
	var fork: Dictionary = _fork(
		"counter", 0, [{"threshold": 7, "cond_counter": "Handgun Ammo"}, {"threshold": 0}]
	)
	assert_bool(JourneyData.fork_default_ignores_requirement(fork["data"], fork["out"])).is_true()


func test_a_default_without_a_requirement_is_fine() -> void:
	var fork: Dictionary = _fork("counter", 1, [{"threshold": 7}, {"threshold": 0}])
	assert_bool(JourneyData.fork_default_ignores_requirement(fork["data"], fork["out"])).is_false()


func test_item_and_flag_requirements_count() -> void:
	var items: Dictionary = _fork("item", 0, [{"required_item": "gun"}, {}])
	assert_bool(JourneyData.fork_default_ignores_requirement(items["data"], items["out"])).is_true()
	var flags: Dictionary = _fork("flag", 1, [{}, {"required_flag": "armed"}])
	assert_bool(JourneyData.fork_default_ignores_requirement(flags["data"], flags["out"])).is_true()


func test_only_conditional_forks_have_a_default() -> void:
	var fork: Dictionary = _fork("counter", 0, [{"threshold": 7}])
	fork["data"]["resolution"] = "choice"
	assert_bool(JourneyData.fork_default_ignores_requirement(fork["data"], fork["out"])).is_false()


func test_an_undeclared_counter_with_no_near_match_is_noted() -> void:
	var graph: Dictionary = _graph(
		{"a": {"type": "round", "data": {"set_counters": {"Loot": 1}}, "out": []}}
	)
	var ctx: Dictionary = {"counters": [{"name": "Handgun Ammo"}]}
	var findings: Array = JourneyAudit._counter_name_findings(graph, ctx)
	assert_int(findings.size()).is_equal(1)
	assert_str(findings[0]["kind"]).is_equal("counter_undeclared")
	assert_str(findings[0]["severity"]).is_equal(JourneyAudit.SEV_INFO)


func test_undeclared_counters_are_noted_when_none_are_declared() -> void:
	var graph: Dictionary = _graph(
		{"a": {"type": "round", "data": {"set_counters": {"Loot": 1}}, "out": []}}
	)
	var findings: Array = JourneyAudit._counter_name_findings(graph, {})
	assert_int(findings.size()).is_equal(1)
	assert_str(findings[0]["kind"]).is_equal("counter_undeclared")
