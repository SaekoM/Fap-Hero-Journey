class_name CatalogPicker
extends RefCounted

# The builder's "add from a catalog" menu, shared by every editor that builds a bundle of effects — effect
# rounds, custom items, boss forced modifiers and boss timeline windows — so all four look and behave the
# same: a search box, the choices in named groups, each with a one-line description, opened under the
# button that asked for it. Picking one closes the menu and hands its id to `on_pick`.
#
# `groups` is [{title: String, entries: [{id: Variant, label: String, desc: String}]}]. An empty group is
# left out; `empty_text` is what shows when there is nothing to offer at all.

const LIST_SIZE: Vector2 = Vector2(340, 380)


static func open(
	anchor: Control,
	groups: Array,
	on_pick: Callable,
	search_hint: String = "Search…",
	empty_text: String = "Nothing left to add."
) -> void:
	var popup: PopupPanel = PopupPanel.new()
	anchor.get_viewport().add_child(popup)
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG
	panel_style.border_color = UITheme.PURPLE_BRIGHT
	panel_style.set_border_width_all(2)
	panel_style.set_content_margin_all(10)
	popup.add_theme_stylebox_override("panel", panel_style)
	popup.popup_hide.connect(popup.queue_free)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	popup.add_child(column)

	var search: LineEdit = LineEdit.new()
	search.placeholder_text = search_hint
	search.clear_button_enabled = true
	UITheme.style_line_edit(search)
	column.add_child(search)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size = LIST_SIZE
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var list: VBoxContainer = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)

	var pick: Callable = func(id: Variant) -> void:
		popup.hide()
		on_pick.call(id)
	var fill: Callable = func(query: String) -> void:
		_fill(list, groups, query.strip_edges().to_lower(), pick, empty_text)
	search.text_changed.connect(fill)
	fill.call("")

	# Under the button, kept on screen: a picker low in a long panel would otherwise open off the bottom.
	var view: Vector2 = anchor.get_viewport_rect().size
	popup.reset_size()
	var pos: Vector2 = anchor.global_position + Vector2(0, anchor.size.y + 4)
	pos.x = clampf(pos.x, 0.0, maxf(0.0, view.x - popup.size.x))
	if pos.y + popup.size.y > view.y:
		pos.y = maxf(0.0, anchor.global_position.y - popup.size.y - 4)  # flip above the button
	popup.position = Vector2i(pos)
	popup.popup()
	search.grab_focus()


# The groups' entries matching `query` (lower-cased; "" = all) by name or description, under their titles.
static func _fill(
	list: VBoxContainer, groups: Array, query: String, pick: Callable, empty_text: String
) -> void:
	for child: Node in list.get_children():
		child.queue_free()
	var shown: int = 0
	var any: bool = false
	for group: Dictionary in groups:
		var matches: Array = []
		for entry: Dictionary in group.get("entries", []):
			any = true
			var haystack: String = (
				(str(entry.get("label", "")) + " " + str(entry.get("desc", ""))).to_lower()
			)
			if query == "" or haystack.contains(query):
				matches.append(entry)
		if matches.is_empty():
			continue
		var heading: Label = Label.new()
		heading.text = str(group.get("title", "")).to_upper()
		UITheme.style_label(heading, UITheme.PURPLE_MID, 10, true)
		list.add_child(heading)
		for entry: Dictionary in matches:
			list.add_child(_make_entry(entry, pick))
			shown += 1
	if shown == 0:
		var none: Label = Label.new()
		none.text = empty_text if not any else "No matches."
		none.add_theme_color_override("font_color", UITheme.DARK_TEXT)
		none.add_theme_font_size_override("font_size", 11)
		list.add_child(none)


# One choice: its name as the button, its description underneath.
static func _make_entry(entry: Dictionary, pick: Callable) -> Control:
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	var button: Button = Button.new()
	button.text = str(entry.get("label", ""))
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button_subtle(button, UITheme.PURPLE_MID, 8, 6, 12)
	var id: Variant = entry.get("id")
	button.pressed.connect(func() -> void: pick.call(id))
	column.add_child(button)
	var desc_text: String = str(entry.get("desc", ""))
	if desc_text != "":
		var desc: Label = Label.new()
		desc.text = desc_text
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.add_theme_color_override("font_color", UITheme.DARK_TEXT)
		desc.add_theme_font_size_override("font_size", 10)
		var indent: MarginContainer = MarginContainer.new()
		indent.add_theme_constant_override("margin_left", 8)
		indent.add_theme_constant_override("margin_bottom", 4)
		indent.add_child(desc)
		column.add_child(indent)
	return column
