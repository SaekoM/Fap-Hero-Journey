class_name NodeLayout
extends RefCounted

# Draws a node's controls ONTO its backdrop, where the author arranged them — a checkpoint's SAVE on a
# campfire, a fork's choices on painted doors.
#
# Shared by every screen that can be arranged, because the rule that matters is easy to get wrong in
# one of them and not the others: AN ESSENTIAL CONTROL IS ALWAYS DRAWN. Arranging a node hides its
# usual card, so anything that only existed on that card is gone — and an author who placed SAVE but
# not CONTINUE would strand the player on a screen with no way forward. Essential elements the author
# never placed fall back to a default position instead of vanishing.
#
# Optional elements — a title, a description — are the opposite: absent unless placed, because they are
# decoration and an author arranging a picture may deliberately want neither.
#
# Every position is in the BACKDROP IMAGE's coordinates, so a control stays on the thing it was placed
# on when the window changes shape (see JourneyImage.image_to_screen).

# Where an essential-but-unplaced element goes, and how far each subsequent one is nudged so two of
# them do not land on top of each other.
const FALLBACK_STEP: float = 0.14


# `elements` is [{key, label, accent, run, optional}]. Returns the controls it drew, keyed by element —
# empty when nothing was, which is the caller's signal to keep its own card.
#
# Handing the controls back rather than a bare yes/no because a shop has to keep hold of them: a slot's
# price changes when coins are spent and its state changes when the item is bought, so something has to
# be able to find that slot again afterwards.
static func apply(backdrop: JourneyImage, node: Dictionary, elements: Array) -> Dictionary:
	var drawn: Dictionary = {}
	if backdrop == null or not JourneyData.has_layout(node):
		return drawn

	var fallbacks: int = 0
	for element: Dictionary in elements:
		var key: String = str(element["key"])
		var slot: Dictionary = JourneyData.layout_slot(node, key)
		if slot.is_empty():
			if bool(element.get("optional", false)):
				continue  # decoration the author chose not to place
			slot = _fallback_slot(fallbacks)
			fallbacks += 1
		var control: Button = _make_hotspot(backdrop, slot, element)
		backdrop.add_child(control)
		drawn[key] = control
	return drawn


# Replaces what is inside an already-placed control — for a slot whose contents change while the screen
# is open, like a shop item that has just been bought. The control keeps its position and its style;
# only what it says changes.
static func refill(control: Button, element: Dictionary, color: Color) -> void:
	for child: Node in control.get_children():
		control.remove_child(child)
		child.queue_free()
	control.add_child(make_hotspot_content(element, color))


# Hides the card behind an arranged node and lets clicks through to the art.
#
# The dim over the backdrop drops too: that heavy scrim exists to keep a CARD's text readable, and
# there is no longer a card. Left alone, an author would arrange against a bright picture in the editor
# and meet a murky one in play.
static func hide_card(host: Control) -> void:
	for child: Node in host.get_children():
		if child is PanelContainer:
			(child as Control).visible = false
		elif child is ColorRect:
			SettingBackdrop.lift_scrim(child as Control)
			# A Control stops mouse events by default, and this one covers the whole screen ABOVE the
			# backdrop — so it swallows every click meant for the controls placed underneath it.
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE


static func _fallback_slot(index: int) -> Dictionary:
	var slot: Dictionary = JourneyData.LAYOUT_SLOT_DEFAULT.duplicate()
	slot["y"] = clampf(float(slot["y"]) + FALLBACK_STEP * index, 0.0, 0.92)
	slot["backing"] = true  # unplaced means unconsidered, so give it the readable default
	return slot


# One placed control: sized and positioned from its image-space slot, following the art as the window
# changes shape. Its plate and outline colours are the author's, falling back to the element's accent.
static func _make_hotspot(backdrop: JourneyImage, slot: Dictionary, element: Dictionary) -> Button:
	var area: Rect2 = Rect2(
		float(slot.get("x", 0.0)),
		float(slot.get("y", 0.0)),
		float(slot.get("w", 0.1)),
		float(slot.get("h", 0.1))
	)
	var accent: Color = element.get("accent", UITheme.CYAN) as Color

	var text_color: Color = JourneyData.slot_color(slot, "text", UITheme.WHITE_SOFT)
	var button: Button = Button.new()
	UITheme.style_layout_hotspot(
		button,
		JourneyData.slot_color(slot, "plate", accent),
		JourneyData.slot_color(slot, "outline", accent),
		text_color,
		bool(slot.get("backing", true))
	)
	# A slot may draw its art and nothing else. The label is dropped HERE rather than by the caller, so
	# every screen gets the behaviour without each one remembering to ask.
	var content: Dictionary = element
	if not bool(slot.get("show_label", true)):
		content = element.duplicate()
		content["label"] = ""
		content["sub"] = ""
	button.add_child(make_hotspot_content(content, text_color))
	if element.get("run", null) is Callable:
		button.pressed.connect(element["run"] as Callable)
	else:
		button.disabled = true  # a label placed for information rather than to be pressed
	button.tooltip_text = str(element.get("tooltip", ""))

	var place: Callable = func() -> void:
		var screen: Rect2 = backdrop.image_to_screen(area)
		button.position = screen.position
		button.size = screen.size
	backdrop.resized.connect(place)
	place.call()
	return button


# What goes INSIDE a placed control: the choice's own art, then its name over its description.
#
# The label is built as child Labels rather than the Button's `text`, because a choice carries a name
# AND a description and those want different sizes — which one text property cannot give them.
#
# Public because the builder's arrangement editor draws its boxes with it too. The preview and the
# played control being built by ONE function is what stops them drifting apart: an author arranging
# against a plain box and meeting a picture in play would be arranging blind.
static func make_hotspot_content(element: Dictionary, color: Color) -> Control:
	var holder: Control = Control.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.clip_contents = true

	var image_path: String = str(element.get("image", ""))
	if image_path != "":
		var art: JourneyImage = JourneyImage.new()
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(art)
		# The choice's OWN fit, the same one its card would have used — covered by default, because a
		# slot placed over a painted door wants filling rather than letterboxing inside itself.
		art.show_path(
			image_path,
			TextureRect.EXPAND_IGNORE_SIZE,
			JourneyImage.stretch_for_fit(
				str(element.get("image_fit", "")), TextureRect.STRETCH_KEEP_ASPECT_COVERED
			)
		)

	var box: VBoxContainer = VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	holder.add_child(box)

	var label: String = str(element.get("label", ""))
	if label != "":
		box.add_child(_hotspot_line(label, color, 15, 4))
	var sub: String = str(element.get("sub", ""))
	if sub != "":
		# Dimmed rather than a different colour: it is the same voice, said quieter.
		box.add_child(_hotspot_line(sub, Color(color.r, color.g, color.b, 0.78), 11, 3))
	return holder


static func _hotspot_line(text: String, color: Color, size: int, outline: int) -> Label:
	var line: Label = Label.new()
	line.text = text
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_color_override("font_color", color)
	line.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	line.add_theme_constant_override("outline_size", outline)
	line.add_theme_font_size_override("font_size", size)
	return line
