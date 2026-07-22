extends GdUnitTestSuite

# Slice-4 (Format-2 graph save) pure helpers in JourneyData: node-data normalization
# (coerce_node_save_data — the "coins lesson" + baseline-field guarantees + node-key
# stripping) and the save's video planning (graph_has_any_video / graph_video_sources).
# These are the testable core of the save rewrite; the file-I/O assembly (_save_graph_nodes
# and its media helpers) stays manual/integration, like the rest of the copy/transcode path.

# ── coerce_node_save_data: numeric coercion (the "coins lesson") ──────────────


# JSON loads every number as float; the integer round fields must persist as int.
func test_coerce_round_coerces_int_fields() -> void:
	var out := (
		JourneyData
		. coerce_node_save_data(
			"round",
			{
				"name": "A",
				"coins": 5.0,
				"round_type": "effect",
				"endure_reward": 10.0,
				"cleanse_cost": 25.0,
			}
		)
	)
	assert_int(typeof(out["coins"])).is_equal(TYPE_INT)
	assert_int(out["coins"]).is_equal(5)
	assert_int(typeof(out["endure_reward"])).is_equal(TYPE_INT)
	assert_int(out["endure_reward"]).is_equal(10)
	assert_int(typeof(out["cleanse_cost"])).is_equal(TYPE_INT)
	assert_int(out["cleanse_cost"]).is_equal(25)


func test_coerce_shop_fields() -> void:
	var out := JourneyData.coerce_node_save_data(
		"shop", {"title": "S", "count": 3.0, "price_multiplier": 1.5}
	)
	assert_int(typeof(out["count"])).is_equal(TYPE_INT)
	assert_int(out["count"]).is_equal(3)
	assert_float(out["price_multiplier"]).is_equal(1.5)  # float stays float
	assert_str(out["mode"]).is_equal("pool")  # default filled


func test_coerce_storyboard_fields() -> void:
	var out := JourneyData.coerce_node_save_data("storyboard", {"coins": 7.0})
	assert_int(typeof(out["coins"])).is_equal(TYPE_INT)
	assert_int(out["coins"]).is_equal(7)
	assert_str(out["item"]).is_equal("")  # default filled


func test_coerce_fork_fields() -> void:
	var out := JourneyData.coerce_node_save_data(
		"fork", {"title": "F", "default_path": 1.0, "after_order": 2.0}
	)
	assert_int(typeof(out["default_path"])).is_equal(TYPE_INT)
	assert_int(out["default_path"]).is_equal(1)
	assert_int(typeof(out["after_order"])).is_equal(TYPE_INT)
	assert_int(out["after_order"]).is_equal(2)
	assert_str(out["resolution"]).is_equal("choice")  # default filled


# ── coerce_node_save_data: baseline fields, key stripping, pass-through ───────


# A never-edited new round (only a name) still gets the full baseline field set with the
# documented defaults — parity with what the tree save's round_to_json always wrote, so a
# new node's on-disk record is complete instead of relying on read-time defaults.
func test_coerce_round_fills_baseline_defaults() -> void:
	var out := JourneyData.coerce_node_save_data("round", {"name": "A"})
	assert_str(out["round_type"]).is_equal("normal")
	assert_str(out["award_item"]).is_equal("")  # no reward by default
	assert_bool(out["effect_random"]).is_true()
	assert_bool(out["resolvable"]).is_false()
	assert_int(out["cleanse_cost"]).is_equal(50)
	assert_str(out["card_header"]).is_equal("EFFECT")  # concrete visual default (no theme)
	assert_str(out["card_icon"]).is_equal("✦")
	assert_str(out["frame_color"]).is_equal(JourneyData.EFFECT_COLOR_NEUTRAL)
	assert_array(out["effects"]).is_empty()
	assert_array(out["sensory"]).is_empty()
	assert_bool(out["show_reveal"]).is_true()
	# Retired legacy keys are dropped on save (migrate-on-save).
	assert_bool(out.has("curses")).is_false()
	assert_bool(out.has("boons")).is_false()


# ── Animated images ──────────────────────────────────────────────────────────
# Drives the presave gate: a GIF MUST be baked (Godot has no GIF decoder), so the save is blocked
# when ffmpeg can't run and any of these exist. Missing one here = a silently blank image in game.


func test_graph_animated_image_sources_finds_every_surface() -> void:
	var graph := {
		"nodes":
		{
			"r1": {"type": "round", "data": {"boss_image": "a.gif"}, "out": []},
			"r2":
			{
				"type": "round",
				"data": {"pool_entries": [{"boss_image": "b.gif"}, {"boss_image": "still.png"}]},
				"out": []
			},
			"s1":
			{
				"type": "storyboard",
				"data": {"image": "c.gif", "lines": [{"image": "d.gif"}, {"image": "no.jpg"}]},
				"out": []
			},
			"f1":
			{"type": "fork", "data": {}, "out": [{"image_path": "e.gif"}, {"image_path": ""}]},
		}
	}
	var found: Array = JourneyData.graph_animated_image_sources(graph, ["gif"])
	found.sort()
	assert_array(found).is_equal(["a.gif", "b.gif", "c.gif", "d.gif", "e.gif"])


func test_graph_animated_image_sources_dedupes_and_ignores_stills() -> void:
	var graph := {
		"nodes":
		{
			"r1": {"type": "round", "data": {"boss_image": "same.gif"}, "out": []},
			"s1": {"type": "storyboard", "data": {"image": "same.gif", "lines": []}, "out": []},
			"s2": {"type": "storyboard", "data": {"image": "plain.png", "lines": []}, "out": []},
		}
	}
	# One source used twice is one entry; stills never appear.
	assert_array(JourneyData.graph_animated_image_sources(graph, ["gif"])).is_equal(["same.gif"])


func test_graph_animated_image_sources_empty_when_no_gifs() -> void:
	var graph := {"nodes": {"r1": {"type": "round", "data": {"boss_image": "x.png"}, "out": []}}}
	assert_array(JourneyData.graph_animated_image_sources(graph, ["gif"])).is_empty()


# ── Journey identity ─────────────────────────────────────────────────────────
# The id must be STABLE for the life of a journey: renditions/modules bind to it, and Name /
# FolderName are both user-renameable, so neither can anchor anything.


func test_new_journey_id_shape_and_uniqueness() -> void:
	var a: String = JourneyData.new_journey_id()
	assert_str(a).starts_with("j_")
	assert_int(a.length()).is_equal(34)  # "j_" + 32 hex chars (128 bits)
	# Ids cross machines, so collisions must be vanishingly unlikely, not merely rare.
	var seen: Dictionary = {}
	for _i in 200:
		seen[JourneyData.new_journey_id()] = true
	assert_int(seen.size()).is_equal(200)


func test_stamp_identity_mints_when_absent() -> void:
	var meta: Dictionary = {"Name": "J"}
	JourneyData.stamp_journey_identity(meta)
	assert_str(str(meta["JourneyId"])).starts_with("j_")
	assert_str(str(meta["MinVersion"])).is_equal(JourneyData.JOURNEY_MIN_APP_VERSION)
	assert_bool(meta.has("CreatedWith")).is_true()


# The guarantee everything else rests on: re-saving must never re-mint the id.
func test_stamp_identity_preserves_existing() -> void:
	var meta: Dictionary = {"Name": "J"}
	JourneyData.stamp_journey_identity(meta, "j_deadbeefdeadbeefdeadbeefdeadbeef")
	assert_str(str(meta["JourneyId"])).is_equal("j_deadbeefdeadbeefdeadbeefdeadbeef")
	# ... and again, simulating a second save.
	JourneyData.stamp_journey_identity(meta, str(meta["JourneyId"]))
	assert_str(str(meta["JourneyId"])).is_equal("j_deadbeefdeadbeefdeadbeefdeadbeef")


# A blank/whitespace id is treated as absent rather than written through as "".
func test_stamp_identity_mints_when_blank() -> void:
	var meta: Dictionary = {}
	JourneyData.stamp_journey_identity(meta, "   ")
	assert_str(str(meta["JourneyId"])).starts_with("j_")


# A round's optional item reward (award_item) is preserved and stringified on save, so the
# runtime can grant it at round end (parity with the storyboard reward).
func test_coerce_round_preserves_award_item() -> void:
	var out := JourneyData.coerce_node_save_data("round", {"name": "A", "award_item": "cleanse"})
	assert_str(out["award_item"]).is_equal("cleanse")


# Node-level keys (type / node_id / paths) never belong inside on-disk node.data.
func test_coerce_strips_node_level_keys() -> void:
	var out := (
		JourneyData
		. coerce_node_save_data(
			"round",
			{
				"name": "A",
				"type": "round",
				"node_id": "n_x",
				"paths": [{}],
			}
		)
	)
	assert_bool(out.has("type")).is_false()
	assert_bool(out.has("node_id")).is_false()
	assert_bool(out.has("paths")).is_false()


# Extra / future keys and genuine float fields pass through via the deep-copy base.
func test_coerce_passes_through_extras_and_floats() -> void:
	var out := (
		JourneyData
		. coerce_node_save_data(
			"round",
			{
				"name": "A",
				"sensory_intensity": {"Strobe": 0.5},
				"future_key": "keep",
			}
		)
	)
	assert_float((out["sensory_intensity"] as Dictionary)["Strobe"]).is_equal(0.5)
	assert_str(out["future_key"]).is_equal("keep")


# The copy is deep — mutating the result can't bleed back into the editor's live node data.
func test_coerce_deep_copies_source() -> void:
	var src := {"name": "A", "round_type": "effect", "effects": ["Greed"]}
	var out := JourneyData.coerce_node_save_data("round", src)
	(out["effects"] as Array).append("Pauper")
	assert_int((src["effects"] as Array).size()).is_equal(1)


# On save, overrides for effects the round no longer selects (in effects[] or sensory[]) are
# pruned; overrides for ticked effects survive.
func test_coerce_prunes_orphan_overrides() -> void:
	var out := (
		JourneyData
		. coerce_node_save_data(
			"round",
			{
				"name": "A",
				"round_type": "effect",
				"effects": ["Greed"],
				"sensory": ["Murk"],
				"effect_overrides":
				{
					"Greed": {"factor": 0.25},  # ticked gameplay — kept
					"Murk": {"name": "The Haze"},  # ticked sensory — kept
					"Choked": {"min": 10},  # not selected — pruned
				},
			}
		)
	)
	var ov := out["effect_overrides"] as Dictionary
	assert_bool(ov.has("Greed")).is_true()
	assert_bool(ov.has("Murk")).is_true()
	assert_bool(ov.has("Choked")).is_false()


# ── video planning (transcode plan + progress modal) ─────────────────────────


func _graph(nodes: Dictionary) -> Dictionary:
	return {"start": "", "nodes": nodes}


func test_graph_has_any_video_false_without_video() -> void:
	(
		assert_bool(
			(
				JourneyData
				. graph_has_any_video(
					_graph(
						{
							"a": {"type": "round", "data": {"video_path": ""}},
							"b": {"type": "shop", "data": {}},
						}
					)
				)
			)
		)
		. is_false()
	)


func test_graph_has_any_video_true_with_video() -> void:
	(
		assert_bool(
			(
				JourneyData
				. graph_has_any_video(
					_graph(
						{
							"a": {"type": "round", "data": {"video_path": "/x/v.mp4"}},
						}
					)
				)
			)
		)
		. is_true()
	)


# Sources are deduped (a clip reused across rounds is probed once) and only rounds count.
func test_graph_video_sources_dedups_rounds_only() -> void:
	var srcs := (
		JourneyData
		. graph_video_sources(
			_graph(
				{
					"a": {"type": "round", "data": {"video_path": "/x/v.mp4"}},
					"b": {"type": "round", "data": {"video_path": "/x/v.mp4"}},  # reused → once
					"c": {"type": "round", "data": {"video_path": "/y/w.mp4"}},
					"d": {"type": "round", "data": {"video_path": ""}},  # no video
					"e": {"type": "storyboard", "data": {"image": "/z/i.png"}},  # not a round
				}
			)
		)
	)
	assert_int(srcs.size()).is_equal(2)
	assert_bool(srcs.has("/x/v.mp4")).is_true()
	assert_bool(srcs.has("/y/w.mp4")).is_true()


# Warmup survives coercion as a real bool (default false). is_checkpoint is RETIRED — coercion
# must NOT write it back, since the flag is converted to a checkpoint node on load.
func test_round_flags_coerce_to_bools() -> void:
	var on: Dictionary = JourneyData.coerce_node_save_data(
		"round", {"name": "A", "is_checkpoint": true, "is_warmup": true}
	)
	assert_int(typeof(on["is_warmup"])).is_equal(TYPE_BOOL)
	assert_bool(on["is_warmup"]).is_true()
	assert_bool(on.has("is_checkpoint")).is_false()  # retired — not persisted

	var off: Dictionary = JourneyData.coerce_node_save_data("round", {"name": "B"})
	assert_bool(off["is_warmup"]).is_false()


# A checkpoint node coerces to just its label.
func test_coerce_checkpoint_node() -> void:
	var out: Dictionary = JourneyData.coerce_node_save_data("checkpoint", {"name": "Act 1"})
	assert_str(out["name"]).is_equal("Act 1")
