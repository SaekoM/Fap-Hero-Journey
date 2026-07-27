extends GdUnitTestSuite

# JourneyGraph serialization (Phase 1b). Proves the graph round-trips through journey.json
# and that JourneyScanner.parse_graph reads BOTH the new node format and (by migrating via
# build_graph) the legacy tree format. Locks the on-disk schema before the runtime cutover.
# No media files: rounds carry cached ActionCount/LengthMs so the legacy parse never hits disk.

const TEST_DIR := "user://test_graph_serialize"
const JOURNEY := "g"


func after() -> void:
	var base := ProjectSettings.globalize_path(TEST_DIR)
	DirAccess.remove_absolute(base + "/" + JOURNEY + "/journey.json")
	DirAccess.remove_absolute(base + "/" + JOURNEY)
	DirAccess.remove_absolute(base)


func _jdir() -> String:
	return TEST_DIR + "/" + JOURNEY


func _write_journey(data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_jdir()))
	var f := FileAccess.open(_jdir() + "/journey.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()


# ── Scanner-style fixtures (what build_graph consumes) ──────────────────────


func _round(order: int, name: String) -> Dictionary:
	return {"order": order, "name": name}


func _fork(after: int, title: String, paths: Array) -> Dictionary:
	return {"after_order": after, "title": title, "resolution": "choice", "paths": paths}


func _path(name: String, rounds: Array) -> Dictionary:
	return {"name": name, "rounds": rounds, "shops": [], "storyboards": [], "forks": []}


# A, FORK(P0=[X,Y], P1=[Z]), B — both paths rejoin at B.
func _fork_journey() -> Dictionary:
	return {
		"rounds": [_round(0, "A"), _round(1, "B")],
		"shops": [],
		"storyboards": [],
		"forks":
		[
			_fork(
				0,
				"F",
				[_path("P0", [_round(0, "X"), _round(1, "Y")]), _path("P1", [_round(0, "Z")])]
			)
		],
	}


func _walk(graph: Dictionary, fork_choices: Array) -> Array:
	var seq: Array = []
	var id: String = graph["start"]
	var bi: int = 0
	var guard: int = 0
	while id != "" and guard < 200:
		guard += 1
		var n: Dictionary = JourneyGraph.node(graph, id)
		if n.is_empty():
			break
		if n["type"] == JourneyGraph.FORK_TYPE:
			seq.append("fork:%s" % n["data"].get("title", ""))
			var edges: Array = n["out"]
			var idx: int = int(fork_choices[bi]) if bi < fork_choices.size() else 0
			bi += 1
			id = str(edges[idx]["to"]) if idx < edges.size() else ""
		else:
			seq.append("%s:%s" % [n["type"], n["data"].get("name", n["data"].get("title", ""))])
			var out: Array = n["out"]
			id = str(out[0]["to"]) if not out.is_empty() else ""
	return seq


func _first_fork(graph: Dictionary) -> Dictionary:
	for id: String in graph["nodes"]:
		if (graph["nodes"][id] as Dictionary)["type"] == JourneyGraph.FORK_TYPE:
			return graph["nodes"][id]
	return {}


func _first_round_data(graph: Dictionary) -> Dictionary:
	for id: String in graph["nodes"]:
		if (graph["nodes"][id] as Dictionary)["type"] == "round":
			return graph["nodes"][id]["data"]
	return {}


# ── Tests ────────────────────────────────────────────────────────────────


# In-memory: to_json → from_json restores the same graph (walks + fork edges intact).
func test_to_json_from_json_round_trip() -> void:
	var g := JourneyGraph.build_graph(_fork_journey())
	var restored := JourneyGraph.from_json(JourneyGraph.to_json(g))
	assert_array(_walk(restored, [0])).is_equal(
		["round:A", "fork:F", "round:X", "round:Y", "round:B"]
	)
	assert_array(_walk(restored, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:B"])
	var b := _first_fork(restored)
	assert_int((b["out"] as Array).size()).is_equal(2)
	assert_str(b["out"][0]["name"]).is_equal("P0")


# Node positions (pos) survive to_json → from_json — the editor's saved layout round-trips.
func test_node_positions_round_trip() -> void:
	var g := JourneyGraph.build_graph(_fork_journey())
	GraphLayout.seed_positions(g)
	for id in g["nodes"]:
		assert_bool((g["nodes"][id] as Dictionary).has("pos")).is_true()  # every node seeded
	var restored := JourneyGraph.from_json(JourneyGraph.to_json(g))
	for id in g["nodes"]:
		assert_vector(restored["nodes"][id]["pos"]).is_equal(g["nodes"][id]["pos"])


# The editor save↔load contract end-to-end: a graph with round data + positions + journey meta,
# assembled the way the builder save will (meta + to_json) and read back via parse_graph_for_editor,
# preserves structure, resolved paths, node data, layout, and meta.
func test_editor_save_load_round_trip() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds":
				[
					{
						"order": 0,
						"name": "A",
						"node_id": "a",
						"funscript_path": "content/a.funscript",
						"coins": 5,
						"round_type": "normal",
						"action_count": 3,
						"length_ms": 1000
					},
					{
						"order": 1,
						"name": "B",
						"node_id": "b",
						"funscript_path": "content/b.funscript",
						"coins": 0,
						"round_type": "boss",
						"action_count": 2,
						"length_ms": 500
					},
				],
				"shops": [],
				"storyboards": [],
				"forks": [],
			}
		)
	)
	GraphLayout.seed_positions(g)
	var jj := JourneyGraph.to_json(g)  # node block …
	jj["Name"] = "RT"
	jj["Author"] = "Mara"
	jj["MapEnabled"] = false  # … + journey meta
	_write_journey(jj)

	var loaded := JourneyScanner.parse_graph_for_editor(_jdir(), JOURNEY)
	assert_array(_walk(loaded, [])).is_equal(["round:A", "round:B"])  # structure
	assert_str(loaded["title"]).is_equal("RT")  # meta
	assert_bool(loaded["map_enabled"]).is_false()
	var a: Dictionary = loaded["nodes"]["a"]
	assert_str(a["data"]["funscript_path"]).is_equal(_jdir() + "/content/a.funscript")  # path resolved
	assert_int(int(a["data"]["coins"])).is_equal(5)  # data preserved (JSON loads numbers as float; consumers coerce)
	assert_vector(a["pos"]).is_equal(g["nodes"]["a"]["pos"])  # layout preserved
	assert_str((loaded["nodes"]["b"] as Dictionary)["data"]["round_type"]).is_equal("boss")


# JourneyData.parse_journey (the builder's meta extractor) must forward shown_counters like its
# sibling meta fields. It once dropped the key, so the builder reloaded an empty list and the next
# save wiped the author's ShownCounters off disk — a silent round-trip data loss. Guards the whole
# forwarding pattern: input is the scanner's snake-case shape.
func test_parse_journey_forwards_shown_counters() -> void:
	var parsed := JourneyData.parse_journey({"shown_counters": ["belt_notches", "arousal"]})
	assert_array(parsed.get("shown_counters", [])).is_equal(["belt_notches", "arousal"])
	# Omitted → empty list, never absent (callers do .get with a [] default, but be explicit).
	assert_array(JourneyData.parse_journey({}).get("shown_counters", [])).is_empty()


# A legacy tree journey (no Nodes, no pos) loads through the editor entry with positions seeded,
# so a migrated journey opens laid-out and editable.
func test_editor_load_seeds_legacy_positions() -> void:
	_write_journey(
		{
			"Name": "Legacy",
			"Rounds":
			[
				{"Name": "A", "FolderName": "r1", "ActionCount": 1, "LengthMs": 100, "Order": 0},
				{"Name": "B", "FolderName": "r2", "ActionCount": 1, "LengthMs": 100, "Order": 1},
			],
			"Forks": [],
			"Shops": [],
			"Storyboards": [],
		}
	)
	var g := JourneyScanner.parse_graph_for_editor(_jdir(), JOURNEY)
	assert_array(_walk(g, [])).is_equal(["round:A", "round:B"])
	for id in g["nodes"]:
		assert_bool((g["nodes"][id] as Dictionary).has("pos")).is_true()  # seeded on migrate


# Through disk: a fork + its edges survive JSON.stringify → file → parse_graph.
func test_disk_round_trip_preserves_fork() -> void:
	_write_journey(JourneyGraph.to_json(JourneyGraph.build_graph(_fork_journey())))
	var graph := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_array(_walk(graph, [0])).is_equal(["round:A", "fork:F", "round:X", "round:Y", "round:B"])
	assert_array(_walk(graph, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:B"])


# parse_graph resolves a node's stored-relative media paths to absolute (base = folder).
func test_disk_round_trip_resolves_paths() -> void:
	var g := (
		JourneyGraph
		. build_graph(
			{
				"rounds":
				[
					{
						"order": 0,
						"name": "A",
						"funscript_path": "r001/s.funscript",
						"video_path": "content/v.mp4"
					}
				],
				"shops": [],
				"storyboards": [],
				"forks": [],
			}
		)
	)
	var journey_json := JourneyGraph.to_json(g)
	journey_json["Name"] = "Disk RT"  # journey-level meta sits alongside, harmlessly
	_write_journey(journey_json)
	var graph := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_array(_walk(graph, [])).is_equal(["round:A"])
	var rd := _first_round_data(graph)
	assert_str(rd["funscript_path"]).is_equal(_jdir() + "/r001/s.funscript")
	assert_str(rd["video_path"]).is_equal(_jdir() + "/content/v.mp4")


# parse_graph migrates a LEGACY (tree) journey.json — no "Nodes" key — via build_graph,
# producing the same walk as the graph format. Cached stats keep the parse off disk.
func test_parse_graph_migrates_legacy() -> void:
	_write_journey(
		{
			"Name": "Legacy",
			"Rounds":
			[
				{
					"Name": "A",
					"FolderName": "r001",
					"FunscriptPath": "r001/s.funscript",
					"ActionCount": 3,
					"LengthMs": 1000,
					"Order": 0
				},
				{
					"Name": "B",
					"FolderName": "r002",
					"FunscriptPath": "r002/s.funscript",
					"ActionCount": 3,
					"LengthMs": 1000,
					"Order": 1
				},
			],
			"Forks":
			[
				{
					"AfterOrder": 0,
					"Title": "F",
					"Resolution": "choice",
					"Paths":
					[
						{
							"Name": "P0",
							"Rounds":
							[
								{
									"Name": "X",
									"FolderName": "fork0_p0_r001",
									"FunscriptPath": "fork0_p0_r001/s.funscript",
									"ActionCount": 1,
									"LengthMs": 100,
									"Order": 0
								}
							],
							"Shops": [],
							"Storyboards": [],
							"Forks": []
						},
						{
							"Name": "P1",
							"Rounds":
							[
								{
									"Name": "Z",
									"FolderName": "fork0_p1_r001",
									"FunscriptPath": "fork0_p1_r001/s.funscript",
									"ActionCount": 1,
									"LengthMs": 100,
									"Order": 0
								}
							],
							"Shops": [],
							"Storyboards": [],
							"Forks": []
						},
					]
				}
			],
			"Shops": [],
			"Storyboards": [],
		}
	)
	var graph := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_array(_walk(graph, [0])).is_equal(["round:A", "fork:F", "round:X", "round:B"])
	assert_array(_walk(graph, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:B"])


# A NodeId in a (legacy) journey.json survives the scanner → build_graph migration as
# the graph node key — the full read path for stable ids. Rounds, the fork, and the
# fork's path rounds all keep their authored ids, and edges wire by them.
func test_parse_graph_preserves_node_ids() -> void:
	_write_journey(
		{
			"Name": "Ids",
			"Rounds":
			[
				{
					"Name": "A",
					"NodeId": "n_a",
					"FolderName": "r001",
					"ActionCount": 1,
					"LengthMs": 100,
					"Order": 0
				},
				{
					"Name": "B",
					"NodeId": "n_b",
					"FolderName": "r002",
					"ActionCount": 1,
					"LengthMs": 100,
					"Order": 1
				},
			],
			"Forks":
			[
				{
					"AfterOrder": 0,
					"Title": "F",
					"NodeId": "n_f",
					"Resolution": "choice",
					"Paths":
					[
						{
							"Name": "P0",
							"Rounds":
							[
								{
									"Name": "X",
									"NodeId": "n_x",
									"FolderName": "fx",
									"ActionCount": 1,
									"LengthMs": 100,
									"Order": 0
								}
							],
							"Shops": [],
							"Storyboards": [],
							"Forks": []
						},
					]
				}
			],
			"Shops": [],
			"Storyboards": [],
		}
	)
	var graph := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	var nodes: Dictionary = graph["nodes"]
	assert_bool(nodes.has("n_a")).is_true()
	assert_bool(nodes.has("n_b")).is_true()
	assert_bool(nodes.has("n_f")).is_true()
	assert_bool(nodes.has("n_x")).is_true()
	assert_str(graph["start"]).is_equal("n_a")
	assert_str(nodes["n_f"]["type"]).is_equal(JourneyGraph.FORK_TYPE)
	# Edges wire by the stable ids: A → F (interleaved after A), F's lone path → X.
	assert_str(nodes["n_a"]["out"][0]["to"]).is_equal("n_f")
	assert_str(nodes["n_f"]["out"][0]["to"]).is_equal("n_x")


# ── Redirect overlay (Phase 3 step 2) ───────────────────────────────────────
# parse_graph composes the journey.json "Redirects" map onto the migrated graph via
# apply_redirects, keyed by the stable node ids — the skip / converge / end authoring.


# A redirect makes a node continue to a later node, skipping its default next.
func test_parse_graph_applies_redirect_skip() -> void:
	_write_journey(
		{
			"Name": "Redir",
			"Rounds":
			[
				{
					"Name": "A",
					"NodeId": "n_a",
					"FolderName": "r1",
					"ActionCount": 1,
					"LengthMs": 100,
					"Order": 0
				},
				{
					"Name": "B",
					"NodeId": "n_b",
					"FolderName": "r2",
					"ActionCount": 1,
					"LengthMs": 100,
					"Order": 1
				},
				{
					"Name": "C",
					"NodeId": "n_c",
					"FolderName": "r3",
					"ActionCount": 1,
					"LengthMs": 100,
					"Order": 2
				},
			],
			"Forks": [],
			"Shops": [],
			"Storyboards": [],
			"Redirects": {"n_a": "n_c"},  # A skips B → C
		}
	)
	assert_array(_walk(JourneyScanner.parse_graph(_jdir(), JOURNEY), [])).is_equal(
		["round:A", "round:C"]
	)


# A redirect to "" ends the journey early through the full scan path.
func test_parse_graph_applies_redirect_to_end() -> void:
	_write_journey(
		{
			"Name": "RedirEnd",
			"Rounds":
			[
				{
					"Name": "A",
					"NodeId": "n_a",
					"FolderName": "r1",
					"ActionCount": 1,
					"LengthMs": 100,
					"Order": 0
				},
				{
					"Name": "B",
					"NodeId": "n_b",
					"FolderName": "r2",
					"ActionCount": 1,
					"LengthMs": 100,
					"Order": 1
				},
			],
			"Forks": [],
			"Shops": [],
			"Storyboards": [],
			"Redirects": {"n_a": ""},  # end after A
		}
	)
	assert_array(_walk(JourneyScanner.parse_graph(_jdir(), JOURNEY), [])).is_equal(["round:A"])


# Both fork-path tails redirect onto a later node, skipping the default rejoin (B) and
# converging on C — the headline "join anywhere" capability, end-to-end through the scan.
func test_parse_graph_redirect_converges_fork_paths() -> void:
	_write_journey(
		{
			"Name": "Converge",
			"Rounds":
			[
				{
					"Name": "A",
					"NodeId": "n_a",
					"FolderName": "r1",
					"ActionCount": 1,
					"LengthMs": 100,
					"Order": 0
				},
				{
					"Name": "B",
					"NodeId": "n_b",
					"FolderName": "r2",
					"ActionCount": 1,
					"LengthMs": 100,
					"Order": 1
				},
				{
					"Name": "C",
					"NodeId": "n_c",
					"FolderName": "r3",
					"ActionCount": 1,
					"LengthMs": 100,
					"Order": 2
				},
			],
			"Forks":
			[
				{
					"AfterOrder": 0,
					"Title": "F",
					"NodeId": "n_f",
					"Resolution": "choice",
					"Paths":
					[
						{
							"Name": "P0",
							"Rounds":
							[
								{
									"Name": "X",
									"NodeId": "n_x",
									"FolderName": "fx",
									"ActionCount": 1,
									"LengthMs": 100,
									"Order": 0
								}
							],
							"Shops": [],
							"Storyboards": [],
							"Forks": []
						},
						{
							"Name": "P1",
							"Rounds":
							[
								{
									"Name": "Z",
									"NodeId": "n_z",
									"FolderName": "fz",
									"ActionCount": 1,
									"LengthMs": 100,
									"Order": 0
								}
							],
							"Shops": [],
							"Storyboards": [],
							"Forks": []
						},
					]
				}
			],
			"Shops": [],
			"Storyboards": [],
			"Redirects": {"n_x": "n_c", "n_z": "n_c"},  # both tails skip default rejoin B → converge on C
		}
	)
	var graph := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_array(_walk(graph, [0])).is_equal(["round:A", "fork:F", "round:X", "round:C"])
	assert_array(_walk(graph, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:C"])


# New-format parse_graph carries journey meta + a DAG total alongside the graph.
func test_parse_graph_carries_meta_new_format() -> void:
	var jj := JourneyGraph.to_json(JourneyGraph.build_graph(_fork_journey()))
	jj["Name"] = "Graphy"
	jj["Author"] = "Mara"
	jj["MapEnabled"] = false
	jj["AllowFinish"] = true  # FINISH ("I came") journey meta
	jj["FinishNode"] = "n_aftercare"
	_write_journey(jj)
	var g := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_str(g["title"]).is_equal("Graphy")
	assert_str(g["author"]).is_equal("Mara")
	assert_bool(g["map_enabled"]).is_false()
	assert_bool(g["allow_finish"]).is_true()
	assert_str(g["finish_node"]).is_equal("n_aftercare")
	assert_int(g["total_rounds"]).is_equal(4)  # longest round path A → X → Y → B
	assert_str(g["start"]).is_not_equal("")  # graph still attached


# Legacy parse_graph keeps the nested model (map/catalogue still work) AND attaches the
# migrated graph under start/nodes.
func test_parse_graph_legacy_keeps_nested_and_adds_graph() -> void:
	_write_journey(
		{
			"Name": "Legacy2",
			"Author": "T",
			"Rounds":
			[
				{
					"Name": "A",
					"FolderName": "r001",
					"FunscriptPath": "r001/s.funscript",
					"ActionCount": 2,
					"LengthMs": 500,
					"Order": 0
				}
			],
			"Forks": [],
			"Shops": [],
			"Storyboards": [],
		}
	)
	var g := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_str(g["title"]).is_equal("Legacy2")
	assert_int((g["rounds"] as Array).size()).is_equal(1)  # nested model still present
	assert_str(g["start"]).is_not_equal("")  # graph attached
	assert_array(_walk(g, [])).is_equal(["round:A"])


# An empty / missing journey returns {} rather than erroring.
func test_missing_returns_empty() -> void:
	assert_dict(JourneyScanner.parse_graph(TEST_DIR + "/nope", "nope")).is_empty()
