extends GdUnitTestSuite

# The retired is_checkpoint flag → standalone checkpoint node migration
# (JourneyGraph._migrate_checkpoint_flags, run inside from_json / build_graph). The migration
# is the load-bearing part of the checkpoint rework: with the flag gone, a legacy round's save
# point survives ONLY if it converts to a checkpoint node inserted before it.


# Builds a Format-2 journey dict (the from_json input) from {id: {type, data, out}} nodes.
func _json(start: String, nodes: Dictionary) -> Dictionary:
	var arr: Array = []
	for id: String in nodes:
		var n: Dictionary = nodes[id]
		arr.append(
			{
				"id": id,
				"type": n.get("type", "round"),
				"data": n.get("data", {}),
				"out": n.get("out", [])
			}
		)
	return {"Format": 2, "Start": start, "Nodes": arr}


func _round_node(name: String, out_to: String, checkpoint: bool = false) -> Dictionary:
	var data: Dictionary = {"name": name}
	if checkpoint:
		data["is_checkpoint"] = true
	return {"type": "round", "data": data, "out": [] if out_to == "" else [{"to": out_to}]}


# The checkpoint node that now precedes a given round in a migrated graph, or {} if none.
func _checkpoint_before(graph: Dictionary, round_id: String) -> Dictionary:
	for id: String in graph["nodes"]:
		var n: Dictionary = graph["nodes"][id]
		if str(n.get("type", "")) == "checkpoint":
			for e: Dictionary in n.get("out", []):
				if str(e.get("to", "")) == round_id:
					return n
	return {}


# A mid-run flagged round gets a checkpoint node spliced in: its predecessor now points at the
# checkpoint, the checkpoint points at the round, and the flag is gone.
func test_flag_becomes_node_before_round() -> void:
	var graph: Dictionary = JourneyGraph.from_json(
		_json("r1", {"r1": _round_node("A", "r2"), "r2": _round_node("B", "", true)})
	)
	# The round keeps its identity + edges; the flag is stripped.
	assert_bool((graph["nodes"]["r2"]["data"] as Dictionary).has("is_checkpoint")).is_false()
	# A checkpoint node now feeds r2...
	assert_dict(_checkpoint_before(graph, "r2")).is_not_empty()
	# ...and r1 was rerouted to it (r1 no longer points straight at r2).
	assert_str(str(graph["nodes"]["r1"]["out"][0]["to"])).is_not_equal("r2")


# A flagged START round: the checkpoint becomes the new start so the save point still precedes it.
func test_flagged_start_round_moves_start() -> void:
	var graph: Dictionary = JourneyGraph.from_json(_json("r1", {"r1": _round_node("A", "", true)}))
	assert_str(str(graph["start"])).is_not_equal("r1")
	assert_str(str(graph["nodes"][graph["start"]]["type"])).is_equal("checkpoint")
	assert_str(str(graph["nodes"][graph["start"]]["out"][0]["to"])).is_equal("r1")


# Two edges into one flagged round (a fork rejoin) both reroute to the single checkpoint.
func test_multiple_inbound_edges_all_reroute() -> void:
	var nodes := {
		"a": {"type": "round", "data": {"name": "A"}, "out": [{"to": "j"}]},
		"b": {"type": "round", "data": {"name": "B"}, "out": [{"to": "j"}]},
		"j": _round_node("Join", "", true),
	}
	var graph: Dictionary = JourneyGraph.from_json(_json("a", nodes))
	var cp: Dictionary = _checkpoint_before(graph, "j")
	assert_dict(cp).is_not_empty()
	# Neither a nor b points at j directly any more; both land on the checkpoint.
	assert_str(str(graph["nodes"]["a"]["out"][0]["to"])).is_not_equal("j")
	assert_str(str(graph["nodes"]["b"]["out"][0]["to"])).is_not_equal("j")
	assert_str(str(graph["nodes"]["a"]["out"][0]["to"])).is_equal(
		str(graph["nodes"]["b"]["out"][0]["to"])
	)


# Idempotent: a graph that already has no flags (re-loaded after a prior migration) is unchanged.
func test_idempotent_without_flags() -> void:
	var graph: Dictionary = JourneyGraph.from_json(
		_json("r1", {"r1": _round_node("A", "r2"), "r2": _round_node("B", "")})
	)
	assert_int((graph["nodes"] as Dictionary).size()).is_equal(2)  # no checkpoint added


# Two flagged rounds in sequence each get their own checkpoint, and the chain stays intact.
func test_adjacent_flagged_rounds() -> void:
	var graph: Dictionary = JourneyGraph.from_json(
		_json("r1", {"r1": _round_node("A", "r2", true), "r2": _round_node("B", "", true)})
	)
	assert_dict(_checkpoint_before(graph, "r1")).is_not_empty()
	assert_dict(_checkpoint_before(graph, "r2")).is_not_empty()
	# 2 rounds + 2 checkpoints.
	assert_int((graph["nodes"] as Dictionary).size()).is_equal(4)


# The synthesized checkpoint id must be STABLE across loads (derived from the round, not random): a Save &
# Quit stores current_node = that id, and resume re-migrates the same journey — a fresh random id each load
# would never match on resume and reset the player to the start. Migrating the SAME json twice must yield the
# same checkpoint id.
func test_checkpoint_id_is_deterministic() -> void:
	var src: Dictionary = _json(
		"r1", {"r1": _round_node("A", "r2"), "r2": _round_node("B", "", true)}
	)
	var a: Dictionary = JourneyGraph.from_json(src.duplicate(true))
	var b: Dictionary = JourneyGraph.from_json(src.duplicate(true))
	var id_a: String = ""
	for id: String in a["nodes"]:
		if str((a["nodes"][id] as Dictionary).get("type", "")) == "checkpoint":
			id_a = id
	var id_b: String = ""
	for id: String in b["nodes"]:
		if str((b["nodes"][id] as Dictionary).get("type", "")) == "checkpoint":
			id_b = id
	assert_str(id_a).is_not_empty()
	assert_str(id_a).is_equal(id_b)  # same across loads → a checkpoint save can be resumed
