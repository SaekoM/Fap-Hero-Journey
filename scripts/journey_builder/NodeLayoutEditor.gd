class_name NodeLayoutEditor
extends Control

# Arranges a node's own controls ONTO its setting's backdrop: a checkpoint's SAVE and CONTINUE placed
# on a campfire and a doorway, rather than floating in a card over the middle of the picture.
#
# Drag to move, pull the corner to resize, a list beside the stage — the same handling CharacterEditor
# gives cast positions, but storing something different. A cast placement is a fraction of the SCREEN,
# because a portrait belongs to the viewport. A layout slot is a fraction of the IMAGE, because it
# belongs to something painted in the art. A background carries crop framing and zoom, so on a
# differently shaped window the picture shifts and rescales underneath: a slot stored against the screen
# would drift off the campfire it was placed on. JourneyImage owns that conversion; this asks it.
#
# The elements a node can place are passed in, so one editor serves the checkpoint now and the fork and
# shop later without learning what any of them mean.

signal done(layout: Dictionary)

const HANDLE_SIZE: int = 14
const PREVIEW_BG: Color = Color(0.06, 0.06, 0.09, 1.0)
# What a slot uses until an author picks something. Also what the pickers open on, so "reset" is simply
# choosing this again.
const DEFAULT_ACCENT: Color = Color(0.10, 0.85, 0.90, 1.0)

var _layout: Dictionary = {}
var _elements: Array = []  # [{key, label, sub?, image?, optional?}] — what this node can place
var _selected: String = ""

var _stage: Control = null
var _backdrop: JourneyImage = null
var _boxes: Dictionary = {}  # key → Control
var _list_col: VBoxContainer = null
var _hint: Label = null


# `elements` is what the node can place, in the shape NodeLayout.make_hotspot_content reads — the same
# dictionaries the game will draw from. `background` is a resolved background view, or {} when
# the node has no setting yet — the stage then shows the placeholder and slots are still placeable
# against it, so an author can arrange before choosing art.
func setup(layout: Dictionary, elements: Array, background: Dictionary) -> void:
	_layout = JourneyData.normalize_layout_slots(layout)
	_elements = elements
	_build_ui(background)
	_rebuild_boxes()
	_rebuild_list()
	_select(str(_elements[0]["key"]) if not _elements.is_empty() else "")


func _slot(key: String) -> Dictionary:
	if not _layout.has(key):
		_layout[key] = JourneyData.LAYOUT_SLOT_DEFAULT.duplicate()
		_layout[key]["backing"] = true
	return _layout[key]


# ── Layout ──────────────────────────────────────────────────────────────────


func _build_ui(background: Dictionary) -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	# The builder's own shortcuts stand down while anything in this group is visible — without it, ESC
	# and every other key reached the graph editor behind this instead of the editor in front of it.
	add_to_group("ui_modal")

	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel: PanelContainer = PanelContainer.new()
	panel.anchor_left = 0.03
	panel.anchor_right = 0.97
	panel.anchor_top = 0.025
	panel.anchor_bottom = 0.975
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.border_color = UITheme.CYAN
	ps.set_border_width_all(1)
	ps.set_corner_radius_all(UITheme.CORNER_RADIUS)
	ps.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", ps)
	add_child(panel)

	var root: VBoxContainer = VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	var header: Label = Label.new()
	header.text = "ARRANGE  —  drag onto the picture, pull the corner to resize"
	header.add_theme_color_override("font_color", UITheme.CYAN)
	header.add_theme_font_size_override("font_size", 14)
	root.add_child(header)

	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	# 16:9 like the player's window, so what is arranged here is what a player meets.
	var wrap: AspectRatioContainer = AspectRatioContainer.new()
	wrap.ratio = 16.0 / 9.0
	wrap.stretch_mode = AspectRatioContainer.STRETCH_FIT
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(wrap)

	var frame_style: StyleBoxFlat = StyleBoxFlat.new()
	frame_style.bg_color = PREVIEW_BG
	frame_style.border_color = UITheme.SEPARATOR
	frame_style.set_border_width_all(1)
	var frame: PanelContainer = PanelContainer.new()
	frame.add_theme_stylebox_override("panel", frame_style)
	frame.clip_contents = true
	wrap.add_child(frame)

	_stage = Control.new()
	_stage.clip_contents = true
	frame.add_child(_stage)

	_backdrop = JourneyImage.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_backdrop)
	if str(background.get("path", "")) != "":
		_backdrop.show_background(background, TextureRect.STRETCH_KEEP_ASPECT_COVERED)
	# Slots are stored against the ART, so they must follow it when the window changes shape.
	_stage.resized.connect(_reposition_boxes)

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.text = ("This node has no background yet — pick a setting first.\nYou can still arrange against the empty frame.")
	_hint.visible = str(background.get("path", "")) == ""
	_stage.add_child(_hint)

	body.add_child(_build_side())


func _build_side() -> Control:
	var side: VBoxContainer = VBoxContainer.new()
	side.add_theme_constant_override("separation", 6)
	side.custom_minimum_size = Vector2(260, 0)

	side.add_child(_side_label("ELEMENTS"))
	# Scrolled, because a shop can place twenty slots and every selected one grows three colour rows
	# and a picker beneath it. Expanding vertically so the buttons below stay pinned to the bottom.
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(scroll)
	_list_col = VBoxContainer.new()
	_list_col.add_theme_constant_override("separation", 3)
	_list_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_col)

	side.add_child(HSeparator.new())
	var reset: Button = Button.new()
	reset.text = "⟲ USE THE DEFAULT LAYOUT"
	reset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button_subtle(reset, UITheme.DARK_TEXT, 10, 6, 10)
	reset.tooltip_text = (
		UITheme
		. wrap_tip(
			"Throws the arrangement away. The node goes back to its normal card, which is what every node without a layout uses."
		)
	)
	reset.pressed.connect(
		func() -> void:
			_layout.clear()
			_rebuild_boxes()
			_rebuild_list()
	)
	side.add_child(reset)

	var ok: Button = Button.new()
	ok.text = "DONE"
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(ok, UITheme.CYAN)
	ok.pressed.connect(
		func() -> void:
			done.emit(_layout)
			queue_free()
	)
	side.add_child(ok)
	return side


# ESC closes, keeping the arrangement. There is no cancel here: the layout is edited on a copy and only
# handed back on the way out, so discarding on ESC would silently throw away everything just placed —
# and ⟲ USE THE DEFAULT LAYOUT is the deliberate way to abandon it.
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	if (event as InputEventKey).keycode != KEY_ESCAPE:
		return
	get_viewport().set_input_as_handled()
	done.emit(_layout)
	queue_free()


# ── Boxes ───────────────────────────────────────────────────────────────────


func _rebuild_boxes() -> void:
	for key: Variant in _boxes:
		var box: Variant = _boxes[key]
		if is_instance_valid(box):
			(box as Control).queue_free()
	_boxes.clear()
	for element: Dictionary in _elements:
		var key: String = str(element["key"])
		if _layout.has(key):
			_make_box(key)  # registers itself, so _restyle can find it
	_reposition_boxes()


# The label inside a box, rebuilt whenever a colour changes. Named so _restyle can find and replace it
# without tearing down the box (and losing the drag in progress).
const BOX_LABEL_NAME: String = "HotspotLabel"


func _element(key: String) -> Dictionary:
	for element: Dictionary in _elements:
		if str(element["key"]) == key:
			return element
	return {}


# The box's contents, through the SAME builder the game uses — the choice's art, its name and its
# description, in the author's own text colour. Arranging against a plain rectangle and meeting a
# picture in play would be arranging blind.
func _make_box_label(key: String) -> Control:
	var slot: Dictionary = _layout.get(key, {})
	# The stage draws exactly what the game will — including nothing, for a blank hotspot. The box's own
	# border is what keeps it grabbable here; in play there is no border and the art carries it.
	var element: Dictionary = _element(key)
	if not bool(slot.get("show_label", true)):
		# The stage shows exactly what play will: art and no words. The box's own border is what keeps
		# it grabbable here; in play there is no border and the picture carries it.
		element = element.duplicate()
		element["label"] = ""
		element["sub"] = ""
	var built: Control = NodeLayout.make_hotspot_content(
		element, JourneyData.slot_color(slot, "text", UITheme.WHITE_SOFT)
	)
	built.name = BOX_LABEL_NAME
	return built


func _make_box(key: String) -> Control:
	var box: Panel = Panel.new()
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.set_meta("slot_key", key)
	_stage.add_child(box)
	# Registered BEFORE styling: _restyle looks the box up by key, and during creation it is not in the
	# dictionary yet.
	_boxes[key] = box
	_restyle(key, key == _selected)  # this is what fills the box; adding again would double it

	var handle: Panel = Panel.new()
	handle.custom_minimum_size = Vector2(HANDLE_SIZE, HANDLE_SIZE)
	handle.anchor_left = 1.0
	handle.anchor_top = 1.0
	handle.anchor_right = 1.0
	handle.anchor_bottom = 1.0
	handle.offset_left = -HANDLE_SIZE
	handle.offset_top = -HANDLE_SIZE
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	var hs: StyleBoxFlat = StyleBoxFlat.new()
	hs.bg_color = UITheme.CYAN
	hs.set_corner_radius_all(3)
	handle.add_theme_stylebox_override("panel", hs)
	box.add_child(handle)

	box.mouse_entered.connect(func() -> void: _hover_box(key, true))
	box.mouse_exited.connect(func() -> void: _hover_box(key, false))
	box.gui_input.connect(func(e: InputEvent) -> void: _on_box_input(key, e))
	handle.gui_input.connect(func(e: InputEvent) -> void: _on_handle_input(key, e))
	return box


# Places every box from its IMAGE-space rect. Re-run on resize, because where the art sits inside the
# stage changes with the frame's shape — which is the whole reason slots are stored against the image.
func _reposition_boxes() -> void:
	for key: Variant in _boxes:
		var box: Variant = _boxes[key]
		if not is_instance_valid(box):
			continue
		var slot: Dictionary = _layout.get(key, {})
		var area: Rect2 = _backdrop.image_to_screen(
			Rect2(
				float(slot.get("x", 0.0)),
				float(slot.get("y", 0.0)),
				float(slot.get("w", 0.1)),
				float(slot.get("h", 0.1))
			)
		)
		(box as Control).position = area.position
		(box as Control).size = area.size


# Draws the box exactly as the game will draw the control — plate or no plate — so ticking Backing
# shows the author the answer rather than describing it. Selection is a brighter border on the same
# style rather than a different one, so the preview never lies about the look while it is selected.
func _style_box(box: Panel, selected: bool) -> void:
	_restyle(str(box.get_meta("slot_key", "")), selected)


# Draws one box as the game will draw the control — plate, outline and all. Called by selection, by
# hover and by the colour pickers, so an author never sees a state the runtime cannot produce.
func _restyle(key: String, lit: bool) -> void:
	var box: Variant = _boxes.get(key)
	if not is_instance_valid(box):
		return
	var slot: Dictionary = _layout.get(key, {})
	(box as Panel).add_theme_stylebox_override(
		"panel",
		UITheme.layout_hotspot_style(
			JourneyData.slot_color(slot, "plate", DEFAULT_ACCENT),
			JourneyData.slot_color(slot, "outline", DEFAULT_ACCENT),
			bool(slot.get("backing", true)),
			lit
		)
	)
	# The text colour lives on the label, so it is rebuilt rather than re-themed — cheaper than
	# threading a colour through two nested Labels, and the box keeps its position either way.
	var old: Node = (box as Node).get_node_or_null(BOX_LABEL_NAME)
	if old != null:
		(box as Node).remove_child(old)
		old.queue_free()
	var content: Control = _make_box_label(key)
	(box as Control).add_child(content)
	# BEHIND everything else in the box. Appended, the contents landed on top of the resize handle —
	# and a choice with art covered it completely, so the corner could not be grabbed at all.
	(box as Control).move_child(content, 0)


func _on_box_input(key: String, event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_select(key)
		return
	if not (event is InputEventMouseMotion):
		return
	var motion: InputEventMouseMotion = event
	if not (motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
		return
	# Pixels dragged → image space, via the drawn art's own size. A crop that zoomed in makes the same
	# drag cover less of the image, which is correct: the slot is pinned to what is painted there.
	var drawn: Rect2 = _backdrop.drawn_rect()
	if drawn.size.x <= 0.0 or drawn.size.y <= 0.0:
		return
	var slot: Dictionary = _slot(key)
	slot["x"] = clampf(float(slot["x"]) + motion.relative.x / drawn.size.x, -1.0, 2.0)
	slot["y"] = clampf(float(slot["y"]) + motion.relative.y / drawn.size.y, -1.0, 2.0)
	_reposition_boxes()


func _on_handle_input(key: String, event: InputEvent) -> void:
	if not (event is InputEventMouseMotion):
		return
	var motion: InputEventMouseMotion = event
	if not (motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
		return
	var drawn: Rect2 = _backdrop.drawn_rect()
	if drawn.size.x <= 0.0 or drawn.size.y <= 0.0:
		return
	var slot: Dictionary = _slot(key)
	slot["w"] = clampf(
		float(slot["w"]) + motion.relative.x / drawn.size.x, JourneyData.LAYOUT_SLOT_MIN, 2.0
	)
	slot["h"] = clampf(
		float(slot["h"]) + motion.relative.y / drawn.size.y, JourneyData.LAYOUT_SLOT_MIN, 2.0
	)
	_reposition_boxes()


# ── Element list ────────────────────────────────────────────────────────────


func _rebuild_list() -> void:
	for c: Node in _list_col.get_children():
		c.queue_free()
	for element: Dictionary in _elements:
		_list_col.add_child(_make_list_row(element))


func _make_list_row(element: Dictionary) -> Control:
	var key: String = str(element["key"])
	var placed: bool = _layout.has(key)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	col.add_child(row)

	var pick: Button = Button.new()
	# The list always names an element, even one whose label is hidden on the stage — two unlabelled
	# hotspots would otherwise be indistinguishable rectangles.
	pick.text = str(element.get("label", ""))
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick.clip_text = true
	UITheme.style_button(pick, UITheme.CYAN if key == _selected and placed else UITheme.PURPLE_MID)
	pick.pressed.connect(
		func() -> void:
			_slot(key)  # picking an unplaced element places it, so one click is enough to start
			_rebuild_boxes()
			_rebuild_list()
			_select(key)
	)
	row.add_child(pick)

	if placed:
		var drop: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
		drop.tooltip_text = UITheme.wrap_tip(
			"Unplace this element. It goes back to where the node's normal card puts it."
		)
		drop.pressed.connect(
			func() -> void:
				_layout.erase(key)
				_rebuild_boxes()
				_rebuild_list()
		)
		row.add_child(drop)

		var backing: CheckBox = CheckBox.new()
		backing.text = "Backing"
		backing.add_theme_font_size_override("font_size", 10)
		backing.button_pressed = bool((_layout[key] as Dictionary).get("backing", true))
		backing.tooltip_text = (
			UITheme
			. wrap_tip(
				"A soft plate behind this element so its text stays readable over the picture. Turn it off where the art is already dark enough."
			)
		)
		backing.toggled.connect(
			func(on: bool) -> void:
				(_layout[key] as Dictionary)["backing"] = on
				_restyle(key, key == _selected)
		)
		col.add_child(backing)

		var show_label: CheckBox = CheckBox.new()
		show_label.text = "Show label"
		show_label.add_theme_font_size_override("font_size", 10)
		show_label.button_pressed = bool((_layout[key] as Dictionary).get("show_label", true))
		show_label.tooltip_text = (
			UITheme
			. wrap_tip(
				"Draw this element's words on the picture. Turn it off for a hotspot over art that already says it — a painted door, a signposted counter. The name is kept either way; it just isn't shown."
			)
		)
		show_label.toggled.connect(
			func(on: bool) -> void:
				(_layout[key] as Dictionary)["show_label"] = on
				_restyle(key, key == _selected)
		)
		col.add_child(show_label)

		# Colours belong to the SELECTED element only. Two pickers on every row would be eight controls
		# on a fork with four choices, for something an author sets once and rarely returns to.
		if key == _selected:
			if (_element(key).get("items", []) as Array).size() > 0:
				col.add_child(_make_item_row(key))
			if str(_element(key).get("image", "")) != "":
				col.add_child(_make_fit_row(key))
			col.add_child(_make_color_row(key, "plate", "Plate"))
			col.add_child(_make_color_row(key, "outline", "Outline"))
			col.add_child(_make_color_row(key, "text", "Text"))

	return col


# Which item belongs in this slot, or "(any)" to take whatever the shop drew.
#
# Pinning is what makes a shelf meaningful rather than decorative: an author who painted a wall hook
# wants the sword on it, not whichever of twenty items the draw happened to put there. Left as "(any)"
# a slot behaves exactly as slots did before this existed.
func _make_item_row(key: String) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var caption: Label = Label.new()
	caption.text = "Item"
	caption.custom_minimum_size = Vector2(58, 0)
	caption.add_theme_color_override("font_color", UITheme.SEPARATOR)
	caption.add_theme_font_size_override("font_size", 10)
	row.add_child(caption)

	var current: String = str((_layout.get(key, {}) as Dictionary).get("item", ""))
	var dd: OptionButton = OptionButton.new()
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dd.clip_text = true
	dd.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"Reserves this spot for one item. Pinning does NOT make the shop stock it — the shop still "
				+ "decides that. In pool mode the shop draws its stock at random, so a pinned item only "
				+ "appears when that draw happens to include it; add it to the shop's Guaranteed list to "
				+ "make it certain. In fixed mode every listed item is always offered, so a pin always lands."
			)
		)
	)
	dd.add_item("(any)")
	dd.set_item_metadata(0, "")
	for option: Variant in _element(key).get("items", []) as Array:
		var entry: Dictionary = option if option is Dictionary else {}
		dd.add_item(str(entry.get("label", entry.get("value", ""))))
		dd.set_item_metadata(dd.item_count - 1, str(entry.get("value", "")))
		if str(entry.get("value", "")) == current:
			dd.selected = dd.item_count - 1
	dd.item_selected.connect(
		func(i: int) -> void:
			(_layout[key] as Dictionary)["item"] = str(dd.get_item_metadata(i))
			_rebuild_list()  # the note below changes with it
	)
	row.add_child(dd)
	col.add_child(row)

	# Said plainly, and only when it applies — the one way pinning can disappoint is a slot reserved for
	# something the shop never draws, and a warning shown on pins that ARE safe teaches people to
	# ignore it.
	if current != "":
		_add_pin_note(col, _element(key), current)
	return col


# Whether a pin can actually be honoured every visit. Read from the LIVE shop rather than a captured
# list, so making an item guaranteed updates this immediately.
func _pin_is_certain(element: Dictionary, item_id: String) -> bool:
	if not bool(element.get("pool_mode", true)):
		return true  # a fixed shop offers everything it lists
	var shop: Variant = element.get("shop_target", null)
	if not (shop is Dictionary):
		return false
	return ((shop as Dictionary).get("guaranteed", []) as Array).has(item_id)


func _add_pin_note(col: VBoxContainer, element: Dictionary, item_id: String) -> void:
	var note: Label = Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 9)

	if _pin_is_certain(element, item_id):
		note.text = "This shop always stocks it, so the spot is always filled."
		note.add_theme_color_override("font_color", UITheme.SEPARATOR)
		col.add_child(note)
		return

	note.text = (
		"This shop draws its stock at random — the spot sits empty on visits where this item "
		+ "isn't drawn."
	)
	note.add_theme_color_override("font_color", UITheme.AMBER)
	col.add_child(note)

	# The fix, next to the problem. Writing to the shop's Guaranteed list from here reaches outside this
	# editor, which is why it is a button that says what it does rather than something the pin implies:
	# an author may well want a spot that is sometimes empty.
	var fix: Button = Button.new()
	fix.text = "✔ ALWAYS STOCK THIS ITEM"
	fix.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fix.tooltip_text = (
		UITheme
		. wrap_tip(
			"Adds it to the shop's Guaranteed list, so every visit stocks it and this spot is always filled."
		)
	)
	UITheme.style_button_subtle(fix, UITheme.TOXIC_GREEN, 9, 4, 10)
	fix.pressed.connect(func() -> void: _guarantee_item(element, item_id))
	col.add_child(fix)


func _guarantee_item(element: Dictionary, item_id: String) -> void:
	var target: Variant = element.get("shop_target", null)
	if not (target is Dictionary):
		return
	var shop: Dictionary = target
	# The key is only filled in at save time, so a shop that never had one needs it created here —
	# appending to the array a defaulted `get` hands back would write into a throwaway.
	if not shop.has("guaranteed"):
		shop["guaranteed"] = []
	var guaranteed: Array = shop["guaranteed"]
	if not guaranteed.has(item_id):
		guaranteed.append(item_id)
	_rebuild_list()  # the warning becomes a confirmation


# How this element's art fills its slot. Lives here rather than only in the node's field list because
# framing is a judgement about the picture, and the picture is here — an author choosing between Crop
# and Fit wants to see the answer, not walk back to a dropdown and return.
#
# Writes to the element's own source dictionary, so it is the SAME property the choice's card uses.
# There is one image and one way it is framed; a second setting that applied only when arranged would
# be two answers to one question.
func _make_fit_row(key: String) -> Control:
	var element: Dictionary = _element(key)
	var target: Variant = element.get("fit_target", null)
	if not (target is Dictionary):
		return Control.new()  # nothing to write to; the element's art is fixed

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var caption: Label = Label.new()
	caption.text = "Fit"
	caption.custom_minimum_size = Vector2(58, 0)
	caption.add_theme_color_override("font_color", UITheme.SEPARATOR)
	caption.add_theme_font_size_override("font_size", 10)
	row.add_child(caption)

	var options: Array = [
		{"value": "crop", "label": "Crop — fills the slot"},
		{"value": "fit", "label": "Fit — whole image"},
		{"value": "stretch", "label": "Stretch"},
	]
	var current: String = str(element.get("image_fit", ""))
	var dd: OptionButton = OptionButton.new()
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dd.clip_text = true
	for i: int in options.size():
		var option: Dictionary = options[i]
		dd.add_item(str(option["label"]))
		dd.set_item_metadata(i, str(option["value"]))
		if str(option["value"]) == current:
			dd.selected = i
	dd.item_selected.connect(
		func(i: int) -> void:
			var chosen: String = str(dd.get_item_metadata(i))
			(target as Dictionary)["image_fit"] = chosen
			element["image_fit"] = chosen  # what the preview redraws from
			_restyle(key, true)
	)
	row.add_child(dd)
	return row


# Pulls a popup back inside the window when it would otherwise open past an edge. Deferred because the
# panel has not been sized at about_to_popup — asking before it has is asking about the last time it
# opened.
func _keep_popup_on_screen(popup: Popup) -> void:
	popup.call_deferred("set_position", _clamped_popup_origin(popup))


func _clamped_popup_origin(popup: Popup) -> Vector2i:
	var screen: Vector2i = DisplayServer.window_get_size()
	var panel: Vector2i = popup.size
	var origin: Vector2i = popup.position
	origin.x = clampi(origin.x, 0, maxi(0, screen.x - panel.x))
	origin.y = clampi(origin.y, 0, maxi(0, screen.y - panel.y))
	return origin


# One colour for the selected element, with a way back to the default. Stored as hex text and cleared
# to "" rather than to a colour, so "unset" stays distinguishable from "set to exactly the default" —
# an element that was never touched follows the theme if the theme ever changes.
func _make_color_row(key: String, field: String, label: String) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var caption: Label = Label.new()
	caption.text = label
	caption.custom_minimum_size = Vector2(58, 0)
	caption.add_theme_color_override("font_color", UITheme.SEPARATOR)
	caption.add_theme_font_size_override("font_size", 10)
	row.add_child(caption)

	var slot: Dictionary = _layout.get(key, {})
	var fallback: Color = UITheme.WHITE_SOFT if field == "text" else DEFAULT_ACCENT
	var picker: ColorPickerButton = ColorPickerButton.new()
	picker.color = JourneyData.slot_color(slot, field, fallback)
	picker.custom_minimum_size = Vector2(0, 24)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.edit_alpha = false  # the style decides opacity; a half-transparent border is just a faint one
	# A ColorPickerButton drops its panel straight down, so one near the bottom of a tall sidebar opens
	# mostly below the window and its swatches cannot be reached. Nudge it back inside as it opens.
	picker.get_popup().about_to_popup.connect(
		func() -> void: _keep_popup_on_screen(picker.get_popup())
	)
	picker.color_changed.connect(
		func(c: Color) -> void:
			(_layout[key] as Dictionary)[field] = "#%s" % c.to_html(false)
			_restyle(key, true)  # selected, so it stays lit while its colour is being chosen
	)
	row.add_child(picker)

	var reset: Button = UITheme.make_icon_btn("⟲", false, UITheme.DARK_TEXT)
	reset.tooltip_text = UITheme.wrap_tip("Back to the default colour for this element.")
	reset.pressed.connect(
		func() -> void:
			(_layout[key] as Dictionary)[field] = ""
			picker.color = fallback
			_restyle(key, true)
	)
	row.add_child(reset)
	return row


# Hovering shows the game's hover state, so an author can see what a player will get. A selected box is
# already drawn in the hovered style, so hovering it changes nothing.
func _hover_box(key: String, hovered: bool) -> void:
	_restyle(key, hovered or key == _selected)


func _select(key: String) -> void:
	_selected = key
	for k: Variant in _boxes:
		_restyle(str(k), str(k) == _selected)
	_rebuild_list()  # the colour pickers belong to whichever element is selected


func _side_label(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.SEPARATOR)
	l.add_theme_font_size_override("font_size", 11)
	return l
