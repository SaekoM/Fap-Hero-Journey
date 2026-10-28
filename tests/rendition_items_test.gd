extends GdUnitTestSuite

# Items in renditions (0.9.2): a rendition brings its own custom items, and may give a base item that
# has no image one. Before this, items weren't part of a rendition at all, so any added in one were
# dropped on save — the "handgun ammo image doesn't save" report.


func _rendition(items: Array, item_images: Array) -> Dictionary:
	return {
		"name": "Overlay",
		"parent_id": "j_base",
		"nodes": {},
		"items": items,
		"item_images": item_images,
	}


func test_items_and_image_fills_survive_a_save_and_load() -> void:
	var saved: Dictionary = JourneyRendition.coerce_rendition(
		_rendition(
			[{"id": "it_flare", "name": "Flare", "category": "key"}],
			[{"item": "it_ammo", "path": "content/ammo.png"}]
		)
	)
	assert_array(saved["ItemImages"]).is_equal([{"Item": "it_ammo", "Path": "content/ammo.png"}])
	var loaded: Dictionary = JourneyRendition.parse_rendition(saved)
	assert_int((loaded["items"] as Array).size()).is_equal(1)
	assert_str(str(loaded["items"][0]["name"])).is_equal("Flare")
	assert_array(loaded["item_images"]).is_equal([{"item": "it_ammo", "path": "content/ammo.png"}])


func test_a_rendition_without_items_loads_with_none() -> void:
	var loaded: Dictionary = JourneyRendition.parse_rendition({"Type": "rendition"})
	assert_array(loaded["items"]).is_empty()
	assert_array(loaded["item_images"]).is_empty()


func test_an_image_fills_a_base_item_that_has_none() -> void:
	var items: Array = [{"id": "it_ammo", "image": ""}]
	JourneyRendition.apply_item_images(items, [{"item": "it_ammo", "path": "/r/ammo.png"}])
	assert_str(str(items[0]["image"])).is_equal("/r/ammo.png")


# The base chose this art; a rendition fills gaps, it never replaces.
func test_an_image_never_replaces_the_bases_own() -> void:
	var items: Array = [{"id": "it_ammo", "image": "/base/ammo.png"}]
	JourneyRendition.apply_item_images(items, [{"item": "it_ammo", "path": "/r/ammo.png"}])
	assert_str(str(items[0]["image"])).is_equal("/base/ammo.png")


# Stacked renditions: the first to fill a gap keeps it.
func test_the_first_fill_wins() -> void:
	var items: Array = [{"id": "it_ammo", "image": ""}]
	JourneyRendition.apply_item_images(
		items, [{"item": "it_ammo", "path": "/a.png"}, {"item": "it_ammo", "path": "/b.png"}]
	)
	assert_str(str(items[0]["image"])).is_equal("/a.png")


func test_a_fill_for_an_unknown_item_does_nothing() -> void:
	var items: Array = [{"id": "it_ammo", "image": ""}]
	JourneyRendition.apply_item_images(items, [{"item": "it_gone", "path": "/a.png"}])
	assert_str(str(items[0]["image"])).is_empty()


func test_item_paths_resolve_against_the_rendition_folder() -> void:
	var delta: Dictionary = {
		"items": [{"id": "it_flare", "image": "content/flare.png"}],
		"item_images": [{"item": "it_ammo", "path": "content/ammo.png"}],
	}
	JourneyRendition.resolve_delta_paths(delta, "/journeys/overlay")
	assert_str(str(delta["items"][0]["image"])).is_equal("/journeys/overlay/content/flare.png")
	assert_str(str(delta["item_images"][0]["path"])).is_equal("/journeys/overlay/content/ammo.png")
