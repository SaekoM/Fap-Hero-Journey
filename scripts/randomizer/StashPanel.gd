class_name StashPanel
extends Control
## The randomizer's STASH panel (STASH_DESIGN.md): where the player connects to a Stash instance, maps
## its folders to this PC, narrows the import by tag, and starts it. The import itself runs on the
## randomizer screen, which owns the progress card and the library; this panel only hands over the
## chosen tag ids through `import_requested` and closes.
##
## Everything typed here is saved as it's used (TEST CONNECTION, IMPORT, CLOSE), so the next import and
## SYNC start from it.

signal import_requested(tag_ids: Array)

const PANEL_SIZE: Vector2i = Vector2i(800, 700)
# Scenes fetched to show the path mappings working, or not.
const SAMPLE_SIZE: int = 3
const TAG_LIST_HEIGHT: int = 170
# Tags listed at once. An instance can have thousands; past this the search narrows them.
const TAG_LIST_LIMIT: int = 200

var _address: LineEdit
var _api_key: LineEdit
var _test_btn: Button
var _connection_status: Label
var _mapping_rows: VBoxContainer
var _samples_box: VBoxContainer
var _tag_search: LineEdit
var _tag_list: VBoxContainer
var _tag_summary: Label
var _count_lbl: Label
var _import_btn: Button

var _mappings: Array = []  # [{from, to}] as edited; blank rows are dropped on save
var _tags: Array = []  # [{id, name}] from the instance, by name
var _picked: Dictionary = {}  # tag id → true
var _samples: Array = []  # parsed scenes (StashClient.parse_scene) to check the mappings against
var _connected: bool = false
var _testing: bool = false
# Only the newest count is shown: ticking three tags quickly sends three requests, and they may come
# back in any order.
var _count_request: int = 0


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	var parts: Dictionary = UITheme.build_centered_modal(
		"IMPORT FROM STASH", UITheme.CYAN, PANEL_SIZE
	)
	add_child(parts["modal"])
	var column: VBoxContainer = parts["vbox"]

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	# Right-hand gutter so the scrollbar sits clear of the fields, as on the settings column.
	var gutter: MarginContainer = MarginContainer.new()
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.add_theme_constant_override("margin_right", 16)
	scroll.add_child(gutter)
	var body: VBoxContainer = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	gutter.add_child(body)

	_build_connection(body)
	_build_mappings(body)
	_build_tags(body)
	column.add_child(_build_footer())

	_mappings = SettingsService.get_stash_path_mappings()
	for tag_id: Variant in SettingsService.get_stash_tag_filter():
		_picked[str(tag_id)] = true
	_rebuild_tag_list()
	_rebuild_mapping_rows()
	_refresh_samples()
	_refresh_footer()
	# A saved connection is tried straight away, so a returning player sees their tags and count
	# without pressing anything.
	if _address.text != "":
		_on_test_pressed()
	else:
		_address.grab_focus.call_deferred()


# Esc, CLOSE: keep what was typed, then go.
func close() -> void:
	_save()
	queue_free()


# ── Connection ───────────────────────────────────────────────────────────────


func _build_connection(body: VBoxContainer) -> void:
	body.add_child(_heading("Connection"))
	_address = LineEdit.new()
	_address.placeholder_text = "e.g. 192.168.1.10:9999"
	_address.text = SettingsService.get_stash_address()
	UITheme.style_line_edit(_address)
	_address.text_submitted.connect(func(_text: String) -> void: _on_test_pressed())
	body.add_child(_field("Stash address", _address))

	_api_key = LineEdit.new()
	_api_key.secret = true
	_api_key.placeholder_text = "Leave blank if your Stash has no login"
	_api_key.text = SettingsService.get_stash_api_key()
	UITheme.style_line_edit(_api_key)
	_api_key.text_submitted.connect(func(_text: String) -> void: _on_test_pressed())
	body.add_child(_field("API key", _api_key))
	body.add_child(_hint("In Stash: Settings → Security → API Key → Generate."))

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_test_btn = Button.new()
	_test_btn.text = "TEST CONNECTION"
	UITheme.style_button(_test_btn, UITheme.CYAN, 12, 8, 12)
	_test_btn.pressed.connect(_on_test_pressed)
	row.add_child(_test_btn)
	_connection_status = Label.new()
	_connection_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_connection_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(_connection_status, UITheme.DARK_TEXT, 12)
	row.add_child(_connection_status)
	body.add_child(row)


func _on_test_pressed() -> void:
	if _testing:
		return
	_save()
	_testing = true
	_connected = false
	_test_btn.disabled = true
	_set_connection_status("Connecting…", UITheme.DARK_TEXT)
	_refresh_footer()
	var client: StashClient = _client()
	var result: Dictionary = await client.test_connection()
	_testing = false
	_test_btn.disabled = false
	if not result["ok"]:
		_set_connection_status(StashClient.error_text(result), UITheme.ERROR_SOFT)
		return
	_connected = true
	var version: String = str(result["version"])
	_set_connection_status(
		(
			"Connected%s. %d interactive scenes."
			% [" to Stash " + version if version != "" else "", int(result["interactive_count"])]
		),
		UITheme.OK
	)
	var tags: Dictionary = await client.fetch_tags()
	_tags = tags["tags"] if tags["ok"] else []
	_rebuild_tag_list()
	var sample: Dictionary = await client.fetch_sample(SAMPLE_SIZE)
	_samples = sample["scenes"] if sample["ok"] else []
	_refresh_samples()
	_refresh_count()


func _set_connection_status(text: String, color: Color) -> void:
	_connection_status.text = text
	_connection_status.add_theme_color_override("font_color", color)


func _client() -> StashClient:
	return StashClient.new(self, _address.text, _api_key.text)


# ── Path mappings ────────────────────────────────────────────────────────────


func _build_mappings(body: VBoxContainer) -> void:
	body.add_child(_heading("Where this PC finds Stash's files"))
	(
		body
		. add_child(
			_hint(
				(
					"Stash names each file the way its own machine sees it. Tell the randomizer where this "
					+ "PC reaches the same folder: a mapped drive (Z:\\videos) or a network share "
					+ "(\\\\nas\\videos). Not needed when Stash runs on this PC."
				)
			)
		)
	)
	_mapping_rows = VBoxContainer.new()
	_mapping_rows.add_theme_constant_override("separation", 6)
	body.add_child(_mapping_rows)

	var add_btn: Button = Button.new()
	add_btn.text = "+ ADD FOLDER"
	UITheme.style_button(add_btn, UITheme.PURPLE_MID, 12, 6, 12)
	add_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add_btn.pressed.connect(_on_add_mapping)
	body.add_child(add_btn)

	_samples_box = VBoxContainer.new()
	_samples_box.add_theme_constant_override("separation", 2)
	body.add_child(_samples_box)


func _on_add_mapping() -> void:
	_mappings.append({"from": "", "to": ""})
	_rebuild_mapping_rows()


func _rebuild_mapping_rows() -> void:
	for child: Node in _mapping_rows.get_children():
		child.queue_free()
	for index: int in _mappings.size():
		_mapping_rows.add_child(_make_mapping_row(index))


func _make_mapping_row(index: int) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var mapping: Dictionary = _mappings[index]

	var from: LineEdit = LineEdit.new()
	from.placeholder_text = "Stash's folder, e.g. /data/videos"
	from.text = str(mapping["from"])
	from.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(from)
	from.text_changed.connect(
		func(text: String) -> void:
			mapping["from"] = text
			_refresh_samples()
	)
	row.add_child(from)

	var arrow: Label = Label.new()
	arrow.text = "→"
	UITheme.style_label(arrow, UITheme.PURPLE_TEXT, 14)
	row.add_child(arrow)

	var to: LineEdit = LineEdit.new()
	to.placeholder_text = "This PC's folder, e.g. Z:\\videos"
	to.text = str(mapping["to"])
	to.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(to)
	to.text_changed.connect(
		func(text: String) -> void:
			mapping["to"] = text
			_refresh_samples()
	)
	row.add_child(to)

	var browse: Button = Button.new()
	browse.text = "…"
	browse.tooltip_text = UITheme.wrap_tip("Pick this PC's folder.")
	UITheme.style_button(browse, UITheme.PURPLE_MID, 10, 6, 12)
	browse.pressed.connect(func() -> void: _browse_for(to))
	row.add_child(browse)

	var remove: Button = Button.new()
	remove.text = "✕"
	UITheme.style_button(remove, UITheme.DANGER, 10, 6, 12)
	remove.pressed.connect(
		func() -> void:
			_mappings.remove_at(index)
			_rebuild_mapping_rows()
			_refresh_samples()
	)
	row.add_child(remove)
	return row


func _browse_for(field: LineEdit) -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	if field.text != "" and DirAccess.dir_exists_absolute(field.text):
		dialog.current_dir = field.text
	else:
		SettingsService.remember_browse_dir(dialog)
	dialog.dir_selected.connect(
		func(dir: String) -> void:
			dialog.queue_free()
			field.text = dir
			field.text_changed.emit(dir)
	)
	dialog.close_requested.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.7)


# A few of Stash's real file paths, each with where the mappings send it and whether this PC can see
# it there: the quickest way to get a mapping right.
func _refresh_samples() -> void:
	for child: Node in _samples_box.get_children():
		child.queue_free()
	if _samples.is_empty():
		return
	_samples_box.add_child(_hint("Some of Stash's files, and where this PC finds them:"))
	for scene: Dictionary in _samples:
		var stash_path: String = str(scene["path"])
		var path_lbl: Label = Label.new()
		path_lbl.text = stash_path
		path_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		UITheme.style_label(path_lbl, UITheme.WHITE_SOFT, 11)
		_samples_box.add_child(path_lbl)

		var result_lbl: Label = Label.new()
		result_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		# The same rule the import follows, so ✓ here means the import will find it.
		var found: String = StashClient.local_path(stash_path, _mappings)
		var mapped: String = StashClient.map_path(stash_path, _mappings)
		if found != "":
			result_lbl.text = "    ✓ %s" % found
			UITheme.style_label(result_lbl, UITheme.OK, 11)
		elif mapped == "":
			result_lbl.text = "    ✗ no folder above covers this"
			UITheme.style_label(result_lbl, UITheme.AMBER, 11)
		else:
			result_lbl.text = "    ✗ %s — not found from this PC" % mapped
			UITheme.style_label(result_lbl, UITheme.AMBER, 11)
		_samples_box.add_child(result_lbl)


# ── Tags ─────────────────────────────────────────────────────────────────────


func _build_tags(body: VBoxContainer) -> void:
	body.add_child(_heading("Which scenes"))
	(
		body
		. add_child(
			_hint(
				(
					"Only interactive scenes (ones with a funscript) are imported. Tick tags to import just "
					+ "the scenes carrying any of them, or none for all. Stash's tags come along as clip tags."
				)
			)
		)
	)
	_tag_search = LineEdit.new()
	_tag_search.placeholder_text = "Search tags…"
	_tag_search.clear_button_enabled = true
	UITheme.style_line_edit(_tag_search)
	_tag_search.text_changed.connect(func(_text: String) -> void: _rebuild_tag_list())
	body.add_child(_tag_search)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, TAG_LIST_HEIGHT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var gutter: MarginContainer = MarginContainer.new()
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.add_theme_constant_override("margin_right", 16)
	scroll.add_child(gutter)
	_tag_list = VBoxContainer.new()
	_tag_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.add_child(_tag_list)
	body.add_child(scroll)

	_tag_summary = Label.new()
	_tag_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(_tag_summary, UITheme.CYAN, 12)
	body.add_child(_tag_summary)
	_rebuild_tag_list()


# The instance's tags matching the search, ticked ones first, then by name.
func _rebuild_tag_list() -> void:
	for child: Node in _tag_list.get_children():
		child.queue_free()
	_refresh_tag_summary()
	if _tags.is_empty():
		_tag_list.add_child(
			_hint("Connect to list Stash's tags." if not _connected else "Stash has no tags.")
		)
		return
	var query: String = _tag_search.text.strip_edges().to_lower()
	var shown: Array = []
	for tag: Dictionary in _tags:
		if query == "" or str(tag["name"]).to_lower().contains(query):
			shown.append(tag)
	shown.sort_custom(_tag_before)
	for i: int in mini(shown.size(), TAG_LIST_LIMIT):
		_tag_list.add_child(_make_tag_check(shown[i]))
	if shown.size() > TAG_LIST_LIMIT:
		_tag_list.add_child(
			_hint("…and %d more. Search to find them." % (shown.size() - TAG_LIST_LIMIT))
		)


func _tag_before(a: Dictionary, b: Dictionary) -> bool:
	var a_picked: bool = _picked.has(str(a["id"]))
	var b_picked: bool = _picked.has(str(b["id"]))
	if a_picked != b_picked:
		return a_picked
	return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0


func _make_tag_check(tag: Dictionary) -> CheckBox:
	var check: CheckBox = CheckBox.new()
	var tag_id: String = str(tag["id"])
	check.text = str(tag["name"])
	check.button_pressed = _picked.has(tag_id)
	check.add_theme_font_size_override("font_size", 12)
	check.toggled.connect(
		func(on: bool) -> void:
			if on:
				_picked[tag_id] = true
			else:
				_picked.erase(tag_id)
			_refresh_tag_summary()
			_refresh_count()
	)
	return check


func _refresh_tag_summary() -> void:
	if _picked.is_empty():
		_tag_summary.text = "Importing every interactive scene."
		return
	var names: Array = []
	for tag: Dictionary in _tags:
		if _picked.has(str(tag["id"])):
			names.append(str(tag["name"]))
	# Ids saved from an earlier session whose tag is gone (or not loaded yet) still narrow the import.
	var unnamed: int = _picked.size() - names.size()
	if unnamed > 0:
		names.append("%d more" % unnamed)
	_tag_summary.text = "Only scenes tagged: " + ", ".join(names)


# ── Footer ───────────────────────────────────────────────────────────────────


func _build_footer() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_count_lbl = Label.new()
	_count_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(_count_lbl, UITheme.WHITE_SOFT, 13, true)
	row.add_child(_count_lbl)
	var close_btn: Button = Button.new()
	close_btn.text = "CLOSE"
	UITheme.style_button(close_btn, UITheme.PURPLE_MID)
	close_btn.pressed.connect(close)
	row.add_child(close_btn)
	_import_btn = Button.new()
	_import_btn.text = "IMPORT"
	UITheme.style_button(_import_btn, UITheme.CYAN)
	_import_btn.pressed.connect(_on_import_pressed)
	row.add_child(_import_btn)
	return row


func _refresh_footer() -> void:
	_import_btn.disabled = not _connected
	if not _connected:
		_count_lbl.text = ""


func _refresh_count() -> void:
	if not _connected:
		return
	_count_request += 1
	var request: int = _count_request
	_count_lbl.text = "Counting…"
	_import_btn.disabled = true
	var result: Dictionary = await _client().count_scenes(_picked.keys())
	if request != _count_request:
		return  # a newer count is on its way
	if not result["ok"]:
		_count_lbl.text = ""
		_set_connection_status(StashClient.error_text(result), UITheme.ERROR_SOFT)
		return
	var count: int = int(result["count"])
	_count_lbl.text = "%d scene%s to import" % [count, "" if count == 1 else "s"]
	_import_btn.disabled = count == 0


func _on_import_pressed() -> void:
	_save()
	import_requested.emit(_picked.keys())
	queue_free()


# ── Shared ───────────────────────────────────────────────────────────────────


func _save() -> void:
	SettingsService.set_stash_address(_address.text)
	SettingsService.set_stash_api_key(_api_key.text)
	var kept: Array = []
	for mapping: Dictionary in _mappings:
		if str(mapping["from"]).strip_edges() != "" or str(mapping["to"]).strip_edges() != "":
			kept.append(
				{"from": str(mapping["from"]).strip_edges(), "to": str(mapping["to"]).strip_edges()}
			)
	SettingsService.set_stash_path_mappings(kept)
	SettingsService.set_stash_tag_filter(_picked.keys())
	SettingsService.save()


func _heading(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	UITheme.style_label(label, UITheme.PURPLE_BRIGHT, 13, true)
	return label


func _hint(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(label, UITheme.DARK_TEXT, 11)
	return label


func _field(label_text: String, control: Control) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var label: Label = Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(130, 0)
	UITheme.style_label(label, UITheme.WHITE_SOFT, 13)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row
