extends GdUnitTestSuite

# RoundTemplates — the pure logic (upsert / without / strip_for_template / apply_to). No disk.


func _tmpl(name: String, tag: String) -> Dictionary:
	return {"name": name, "data": {"name": tag}}


func test_upsert_appends_new() -> void:
	var out: Array = RoundTemplates.upsert([], "Enc", {"round_type": "pool"})
	assert_int(out.size()).is_equal(1)
	assert_str(str((out[0] as Dictionary)["name"])).is_equal("Enc")
	assert_str(str(((out[0] as Dictionary)["data"] as Dictionary)["round_type"])).is_equal("pool")


func test_upsert_replaces_in_place() -> void:
	var start: Array = [_tmpl("A", "a"), _tmpl("B", "b"), _tmpl("C", "c")]
	var out: Array = RoundTemplates.upsert(start, "B", {"name": "b2"})
	assert_int(out.size()).is_equal(3)
	assert_str(str(((out[1] as Dictionary)["data"] as Dictionary)["name"])).is_equal("b2")
	assert_str(str((out[0] as Dictionary)["name"])).is_equal("A")
	assert_str(str((out[2] as Dictionary)["name"])).is_equal("C")


func test_upsert_deep_copies_data() -> void:
	var data: Dictionary = {"name": "orig"}
	var out: Array = RoundTemplates.upsert([], "X", data)
	data["name"] = "mutated"  # mutate source afterward
	assert_str(str(((out[0] as Dictionary)["data"] as Dictionary)["name"])).is_equal("orig")


func test_without_removes_by_name() -> void:
	var out: Array = RoundTemplates.without([_tmpl("A", "a"), _tmpl("B", "b")], "A")
	assert_int(out.size()).is_equal(1)
	assert_str(str((out[0] as Dictionary)["name"])).is_equal("B")


# Node-level keys and the round's content never ride along in a template — the id + edges belong
# to the graph node; the clip, a pool's entries and the name belong to the round.
func test_strip_for_template_drops_node_and_content_keys() -> void:
	var out: Dictionary = (
		RoundTemplates
		. strip_for_template(
			{
				"type": "round",
				"node_id": "n_1",
				"name": "R",
				"coins": 5,
				"trim_start_ms": 10,
				"video_path": "G:/a.mp4",
				"funscript_path": "G:/a.funscript",
				"pool_entries": [{"name": "e1"}],
				"boss_image": "G:/boss.png",
				"effects": ["Murk"],
			}
		)
	)
	for k: String in [
		"node_id", "type", "trim_start_ms", "name", "video_path", "funscript_path", "pool_entries"
	]:
		assert_bool(out.has(k)).override_failure_message("%s should be stripped" % k).is_false()
	assert_int(int(out["coins"])).is_equal(5)
	assert_str(str(out["boss_image"])).is_equal("G:/boss.png")  # authored art is part of the setup
	assert_int((out["effects"] as Array).size()).is_equal(1)


# apply_to replaces the round's setup but keeps its own node id (so graph edges survive) and name.
func test_apply_to_replaces_setup_but_keeps_node_id_and_name() -> void:
	var data: Dictionary = {"node_id": "n_keep", "name": "Old", "coins": 1, "gift_item": "x"}
	RoundTemplates.apply_to(data, {"round_type": "effect", "coins": 9})
	assert_str(str(data["node_id"])).is_equal("n_keep")  # id preserved
	assert_str(str(data["type"])).is_equal("round")  # re-stamped
	assert_str(str(data["name"])).is_equal("Old")  # the author's name stays
	assert_int(int(data["coins"])).is_equal(9)
	assert_bool(data.has("gift_item")).is_false()  # setup not in the template is cleared
	assert_str(str(data["round_type"])).is_equal("effect")  # type is configuration


func test_apply_to_is_deep_copy() -> void:
	var tmpl: Dictionary = {"effects": ["Murk"]}
	var data: Dictionary = {"node_id": "n1"}
	RoundTemplates.apply_to(data, tmpl)
	(tmpl["effects"] as Array).append("Strobe")  # mutate source after apply
	assert_int((data["effects"] as Array).size()).is_equal(1)


# ── Content is never overwritten ─────────────────────────────────────────────
# Templates were being used as "the same effects, intro card and rewards on a variety of videos",
# and applying one wiped the round's own video and funscript.

const CLIP := {
	"node_id": "n1",
	"name": "Old",
	"round_type": "normal",
	"video_path": "G:/clips/a.mp4",
	"funscript_path": "G:/clips/a.funscript",
	"axis_scripts": {"R0": "G:/clips/a_R0.funscript"},
	"segments": [{"in_ms": 1000, "out_ms": 5000}],
	"coins": 1,
}
# A template saved before content was excluded still carries a clip; it must be ignored.
const OLD_TEMPLATE := {
	"name": "Temptation",
	"round_type": "effect",
	"coins": 9,
	"effects": ["Murk"],
	"video_path": "G:/other/b.mp4",
	"funscript_path": "G:/other/b.funscript",
}


func test_apply_keeps_the_rounds_clip_and_takes_only_the_setup() -> void:
	var data: Dictionary = CLIP.duplicate(true)
	RoundTemplates.apply_to(data, OLD_TEMPLATE)
	assert_str(str(data["video_path"])).is_equal("G:/clips/a.mp4")
	assert_str(str(data["funscript_path"])).is_equal("G:/clips/a.funscript")
	assert_str(str((data["axis_scripts"] as Dictionary)["R0"])).is_equal("G:/clips/a_R0.funscript")
	assert_int((data["segments"] as Array).size()).is_equal(1)  # pending cuts belong to THIS clip
	assert_str(str(data["name"])).is_equal("Old")
	assert_int(int(data["coins"])).is_equal(9)
	assert_str(str(data["round_type"])).is_equal("effect")


func test_apply_to_an_empty_round_brings_no_clip() -> void:
	var data: Dictionary = {"node_id": "n1", "name": "Blank"}
	RoundTemplates.apply_to(data, OLD_TEMPLATE)
	assert_bool(data.has("video_path")).is_false()
	assert_bool(data.has("funscript_path")).is_false()
	assert_str(str(data["name"])).is_equal("Blank")
	assert_int(int(data["coins"])).is_equal(9)


func test_pool_template_never_makes_a_pool_and_brings_no_entries() -> void:
	var data: Dictionary = CLIP.duplicate(true)
	var pool_tmpl := {
		"round_type": "pool",
		"pool_entries": [{"name": "e1"}, {"name": "e2"}],
		"show_encounter": true,
		"coins": 3,
	}
	RoundTemplates.apply_to(data, pool_tmpl)
	assert_str(str(data["video_path"])).is_equal("G:/clips/a.mp4")
	assert_bool(data.has("pool_entries")).is_false()
	assert_str(str(data["round_type"])).is_equal("normal")
	assert_int(int(data["coins"])).is_equal(3)


func test_template_on_a_pool_round_keeps_its_entries_and_stays_a_pool() -> void:
	var data := {
		"node_id": "n1",
		"round_type": "pool",
		"pool_entries": [{"name": "mine"}],
		"coins": 1,
	}
	RoundTemplates.apply_to(data, OLD_TEMPLATE)
	assert_str(str(data["round_type"])).is_equal("pool")
	assert_int((data["pool_entries"] as Array).size()).is_equal(1)
	assert_bool(data.has("video_path")).is_false()
	assert_int(int(data["coins"])).is_equal(9)
