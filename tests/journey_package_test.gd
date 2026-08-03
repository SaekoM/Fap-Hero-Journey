extends GdUnitTestSuite

# JourneyPackage: the pure .fhj model — manifest build/parse, the portable content hash, per-asset
# free/paid routing (roles drawn from how journey.json REFERENCES a file), the split partition, and the
# import dedupe. No autoloads / I/O beyond the portable-hash temp file. The zip/install driver
# (JourneyPackager) is exercised manually.

const TEST_DIR := "user://test_journey_package"

# Two valid 16-hex pooled fingerprints for slot ids (JourneyData.is_pooled_content_path wants exactly 16).
const FP_A := "aaaaaaaaaaaaaaaa"
const FP_B := "bbbbbbbbbbbbbbbb"


func after() -> void:
	JourneyData.delete_dir_recursive(TEST_DIR)


# A synthetic Format-2 journey.json covering every media-bearing surface, so enumerate/route is pinned
# against the real on-disk schema (lowercase node.data keys; PascalCase meta).
func _demo_journey() -> Dictionary:
	return {
		"Name": "Demo",
		"Author": "Me",
		"JourneyId": "j_demo",
		"MinVersion": "0.6.0",
		"CreatedWith": "0.7.1",
		"Nodes":
		[
			{
				"id": "n1",
				"type": "round",
				"data":
				{
					"video_path": "content/clip__%s.mp4" % FP_A,
					"funscript_path": "content/clip__%s.funscript" % FP_B,
					"axis_scripts": {"L0": "content/x__cccccccccccccccc.funscript"},
					"boss_image": "content/boss__dddddddddddddddd.mp4",
				},
			},
			{
				"id": "n2",
				"type": "storyboard",
				"data":
				{
					"image": "media/bg1.png",
					"bgm": "content/song__eeeeeeeeeeeeeeee.ogg",
					"lines":
					[{"image": "media/l1.png", "audio": "content/a__ffffffffffffffff.ogg"}],
				},
			},
			{
				"id": "n3",
				"type": "fork",
				"data": {"audio": "content/fk__1111111111111111.ogg"},
				"out": [{"to": "n1", "image_path": "media/fork1.png"}],
			},
			{"id": "n4", "type": "shop", "data": {}},
		],
		"Items": [{"Image": "content/icon__2222222222222222.png"}],
		"Characters": [{"Portraits": [{"Path": "content/por__3333333333333333.png"}]}],
	}


# ── Manifest round-trip ──────────────────────────────────────────────────────


func test_manifest_round_trip() -> void:
	var journey := _demo_journey()
	var assets := JourneyPackage.enumerate_assets(journey, "media/cover.png")
	var raw := JourneyPackage.build_manifest(journey, assets, "media/cover.png")
	var m := JourneyPackage.parse_manifest(raw)
	assert_bool(m["ok"]).is_true()
	assert_str(str(m["journey_id"])).is_equal("j_demo")
	assert_str(str(m["name"])).is_equal("Demo")
	assert_str(str(m["mode"])).is_equal("embedded")
	assert_str(str(m["min_version"])).is_equal("0.6.0")
	assert_str(str(m["cover"])).is_equal("media/cover.png")
	assert_int(int((m["counts"] as Dictionary)["rounds"])).is_equal(1)
	assert_int((m["assets"] as Array).size()).is_equal(assets.size())


func test_manifest_rejects_newer_format() -> void:
	var m := JourneyPackage.parse_manifest({"PackageFormat": JourneyPackage.PACKAGE_FORMAT + 1})
	assert_bool(m["ok"]).is_false()
	assert_str(str(m["error"])).is_equal("newer_format")


func test_manifest_rejects_non_package() -> void:
	# A bare journey.json (no PackageFormat) is not an .fhj manifest.
	assert_bool(JourneyPackage.parse_manifest({"Name": "x"})["ok"]).is_false()


func test_node_counts() -> void:
	var c := JourneyPackage.node_counts(_demo_journey())
	assert_int(int(c["rounds"])).is_equal(1)
	assert_int(int(c["storyboards"])).is_equal(1)
	assert_int(int(c["forks"])).is_equal(1)
	assert_int(int(c["shops"])).is_equal(1)


# A rendition journey.json packages with Type "rendition" and carries its ParentId through the manifest.
func test_rendition_manifest_carries_parent() -> void:
	var rend := {
		"Type": "rendition",
		"JourneyId": "j_r",
		"ParentId": "j_base",
		"Name": "Overlay",
		"Nodes": []
	}
	var m := JourneyPackage.parse_manifest(JourneyPackage.build_manifest(rend, [], ""))
	assert_str(str(m["type"])).is_equal("rendition")
	assert_str(str(m["parent_id"])).is_equal("j_base")
	# A plain journey manifest reports the default type and a blank parent.
	var mj := JourneyPackage.parse_manifest(JourneyPackage.build_manifest(_demo_journey(), [], ""))
	assert_str(str(mj["type"])).is_equal("journey")
	assert_str(str(mj["parent_id"])).is_equal("")


# ── Slot id ──────────────────────────────────────────────────────────────────


func test_slot_id_is_pooled_rel() -> void:
	assert_str(JourneyPackage.slot_id_for("content/clip__%s.mp4" % FP_A)).is_equal(
		"content/clip__%s.mp4" % FP_A
	)
	# A journey image (media/) or any non-pooled path has no slot.
	assert_str(JourneyPackage.slot_id_for("media/cover.png")).is_equal("")
	assert_str(JourneyPackage.slot_id_for("/Videos/original.mp4")).is_equal("")


# ── Portable hash ────────────────────────────────────────────────────────────


func test_portable_hash_stable_and_size_sensitive() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	var path := TEST_DIR + "/clip.bin"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("the same bytes every time")
	f.close()
	var abs := ProjectSettings.globalize_path(path)
	var h1 := JourneyPackage.portable_hash(abs)
	assert_str(h1).is_not_equal("")
	assert_str(JourneyPackage.portable_hash(abs)).is_equal(h1)  # deterministic

	# Different size → different hash (size is folded into the digest).
	var g := FileAccess.open(path, FileAccess.WRITE)
	g.store_string("a noticeably longer body of bytes than before")
	g.close()
	assert_str(JourneyPackage.portable_hash(abs)).is_not_equal(h1)


func test_portable_hash_missing_file() -> void:
	assert_str(JourneyPackage.portable_hash("/does/not/exist.mp4")).is_equal("")


# ── Asset routing ────────────────────────────────────────────────────────────


func test_enumerate_roles_and_packs() -> void:
	var assets := JourneyPackage.enumerate_assets(_demo_journey())
	var pack_of: Dictionary = {}
	var role_of: Dictionary = {}
	for a: Dictionary in assets:
		pack_of[a["rel"]] = a["pack"]
		role_of[a["rel"]] = a["role"]

	# The scene video is the only free asset (no cover passed).
	assert_str(str(role_of["content/clip__%s.mp4" % FP_A])).is_equal("scene")
	assert_str(str(pack_of["content/clip__%s.mp4" % FP_A])).is_equal("free")
	# Author work defaults to paid: funscript, axis, boss image, storyboard art/audio, fork art/audio,
	# item icon, character portrait.
	assert_str(str(pack_of["content/clip__%s.funscript" % FP_B])).is_equal("paid")
	assert_str(str(role_of["content/x__cccccccccccccccc.funscript"])).is_equal("axis")
	assert_str(str(pack_of["content/boss__dddddddddddddddd.mp4"])).is_equal("paid")
	assert_str(str(pack_of["media/bg1.png"])).is_equal("paid")
	assert_str(str(role_of["content/song__eeeeeeeeeeeeeeee.ogg"])).is_equal("audio")
	assert_str(str(pack_of["media/fork1.png"])).is_equal("paid")
	assert_str(str(pack_of["content/icon__2222222222222222.png"])).is_equal("paid")
	assert_str(str(pack_of["content/por__3333333333333333.png"])).is_equal("paid")

	var free_only := assets.filter(func(a: Dictionary) -> bool: return a["pack"] == "free")
	assert_int(free_only.size()).is_equal(1)


# A rendition's overlay media lives outside Nodes — an anchor-edge fork-choice image and slot-fill media —
# and must be enumerated + routed just like a base journey's, so a split export doesn't drop them.
func test_enumerate_rendition_overlay_assets() -> void:
	var rend := {
		"Type": "rendition",
		"JourneyId": "j_r",
		"ParentId": "j_base",
		"Nodes":
		[{"id": "n1", "type": "round", "data": {"video_path": "content/new__%s.mp4" % FP_A}}],
		"Anchors":
		[
			{
				"Anchor": "fork",
				"Edge": {"to": "n1", "image_path": "content/choice__cccccccccccccccc.png"}
			}
		],
		"SlotFills":
		[
			{
				"Node": "base_r",
				"Field": "axis_scripts",
				"Channel": "L0",
				"Path": "content/x__dddddddddddddddd.funscript"
			},
			{
				"Node": "base_r2",
				"Field": "video_path",
				"Path": "content/fill__eeeeeeeeeeeeeeee.mp4"
			},
		],
	}
	var assets := JourneyPackage.enumerate_assets(rend)
	var pack_of: Dictionary = {}
	var role_of: Dictionary = {}
	for a: Dictionary in assets:
		pack_of[a["rel"]] = a["pack"]
		role_of[a["rel"]] = a["role"]
	# Overlay fork-choice card image → paid author art.
	assert_str(str(pack_of["content/choice__cccccccccccccccc.png"])).is_equal("paid")
	# Slot-fill axis script → paid; a filled VIDEO slot → free (scene footage is never sold).
	assert_str(str(role_of["content/x__dddddddddddddddd.funscript"])).is_equal("axis")
	assert_str(str(pack_of["content/x__dddddddddddddddd.funscript"])).is_equal("paid")
	assert_str(str(role_of["content/fill__eeeeeeeeeeeeeeee.mp4"])).is_equal("scene")
	assert_str(str(pack_of["content/fill__eeeeeeeeeeeeeeee.mp4"])).is_equal("free")


func test_cover_is_free() -> void:
	var assets := JourneyPackage.enumerate_assets(_demo_journey(), "media/cover.png")
	var found := assets.filter(func(a: Dictionary) -> bool: return a["rel"] == "media/cover.png")
	assert_int(found.size()).is_equal(1)
	assert_str(str((found[0] as Dictionary)["role"])).is_equal("cover")
	assert_str(str((found[0] as Dictionary)["pack"])).is_equal("free")


# A pooled file referenced as BOTH presentation art and scene footage must end up free — even when the
# paid reference is seen first (the storyboard image before the round's video, here).
func test_scene_role_wins_regardless_of_order() -> void:
	var shared := "content/shared__%s.mp4" % FP_A
	var journey := {
		"Nodes":
		[
			{"id": "s", "type": "storyboard", "data": {"image": shared}},  # seen first as image
			{"id": "r", "type": "round", "data": {"video_path": shared}},  # then as scene
		]
	}
	var assets := JourneyPackage.enumerate_assets(journey)
	assert_int(assets.size()).is_equal(1)  # deduped to one entry
	assert_str(str((assets[0] as Dictionary)["role"])).is_equal("scene")
	assert_str(str((assets[0] as Dictionary)["pack"])).is_equal("free")


func test_override_can_free_a_paid_asset_but_never_paywall_scene() -> void:
	var assets := JourneyPackage.enumerate_assets(_demo_journey())
	(
		JourneyPackage
		. apply_overrides(
			assets,
			{
				"content/boss__dddddddddddddddd.mp4": "free",  # author gives away their boss art
				"content/clip__%s.mp4" % FP_A: "paid",  # attempt to paywall the footage — must be ignored
			}
		)
	)
	var pack_of: Dictionary = {}
	for a: Dictionary in assets:
		pack_of[a["rel"]] = a["pack"]
	assert_str(str(pack_of["content/boss__dddddddddddddddd.mp4"])).is_equal("free")
	assert_str(str(pack_of["content/clip__%s.mp4" % FP_A])).is_equal("free")  # scene stays free


func test_partition_and_paid_pack_clean() -> void:
	var assets := JourneyPackage.enumerate_assets(_demo_journey(), "media/cover.png")
	var split := JourneyPackage.partition_assets(assets)
	assert_array(split["free"] as Array).contains(
		["content/clip__%s.mp4" % FP_A, "media/cover.png"]
	)
	assert_array(split["paid"] as Array).contains(["content/clip__%s.funscript" % FP_B])
	assert_bool(JourneyPackage.paid_pack_is_clean(assets)).is_true()

	# Force a scene into the paid half → the guard trips.
	for a: Dictionary in assets:
		if a["role"] == "scene":
			a["pack"] = "paid"
	assert_bool(JourneyPackage.paid_pack_is_clean(assets)).is_false()


# ── Import dedupe ────────────────────────────────────────────────────────────


func test_find_id_collision() -> void:
	var existing := [
		{"journey_id": "j_one", "title": "One"}, {"journey_id": "j_two", "title": "Two"}
	]
	assert_str(str(JourneyPackage.find_id_collision("j_two", existing)["title"])).is_equal("Two")
	assert_bool(JourneyPackage.find_id_collision("j_new", existing).is_empty()).is_true()
	# A blank id never collides (pre-id journeys can't anchor anything).
	assert_bool(JourneyPackage.find_id_collision("", existing).is_empty()).is_true()
