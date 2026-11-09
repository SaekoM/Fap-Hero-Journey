class_name MiniGameEditor
extends RefCounted

# The builder's mini-game authoring: the library in JOURNEY INFO (each game set up once), the editor for
# one game (its knobs, attempts, retry cost and tiers or ladder), and the side panel of a mini-game node
# (which game it plays, and what is behind it). MINIGAMES_DESIGN.md → "Reuse — a journey-level library".
#
# Edits go straight into the live definition in `_owner._journey_minigames`; structural edits (adding a
# tier, a rung) re-normalize it and rebuild the editor, so the fields always show the canonical shape.
# Reward fields reuse the side panel's own flag / counter / item pickers, so a tier's rewards read exactly
# like a round's.

const KIND_NAMES: Dictionary = {
	SafeCrackerGame.KIND: "Safe-Cracker",
	DoubleOrNothingGame.KIND: "Double or Nothing",
	QuickTimeEventGame.KIND: "Quick-Time Event",
	StopTheBarGame.KIND: "Stop the Bar",
	HoldReleaseGame.KIND: "Hold & Release",
	PushYourLuckGame.KIND: "Push Your Luck",
}
# The games a node can host, in the order the builder offers them. Quick-Time Event runs on a boss
# timeline instead (phase 3).
const NODE_KINDS: Array[String] = [
	SafeCrackerGame.KIND,
	DoubleOrNothingGame.KIND,
	StopTheBarGame.KIND,
	HoldReleaseGame.KIND,
	PushYourLuckGame.KIND,
]
const INTRO_FIELD_HEIGHT: float = 72.0
const QTE_KEY_COLUMNS: int = 11
const QTE_KEY_BUTTON_SIZE: float = 34.0
const LIBRARY_KINDS: Array[String] = [
	SafeCrackerGame.KIND,
	DoubleOrNothingGame.KIND,
	StopTheBarGame.KIND,
	HoldReleaseGame.KIND,
	PushYourLuckGame.KIND,
	QuickTimeEventGame.KIND,
]
# How far above the current top a new pot tier starts.
const POT_TIER_STEP: int = 20
# The ＋ buttons that add a game wrap into rows, so the list of games can grow without squeezing them.
const LIBRARY_ADD_COLUMNS: int = 2

# What each game-character moment is called in the editor.
const MOMENT_LABELS: Dictionary = {
	"idle": "AT REST",
	"opened": "NUMBER OPENED",
	"wrong": "WRONG TRY",
	"success": "LOCK OPENED",
	"failed": "FAILED",
	"win": "ON A WIN",
	"bust": "ON A BUST",
	"hit": "IN THE ZONE",
	"miss": "MISSED",
	"passed": "PASSED",
	"banked": "ON BANKING",
}

const LIBRARY_MODAL_SIZE: Vector2i = Vector2i(600, 560)
const COINS_LIMIT: int = 99999

var _owner: JourneyBuilder
var _panel: BuilderSidePanel
var _manage_btn: Button = null
var _library_list: VBoxContainer = null  # the open library modal's rows, else null


func _init(owner: JourneyBuilder, panel: BuilderSidePanel) -> void:
	_owner = owner
	_panel = panel


# ── JOURNEY INFO entry point ─────────────────────────────────────────────────


func make_library_section() -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var header: Label = Label.new()
	header.text = "MINI-GAMES"
	UITheme.style_label(header, UITheme.MINIGAME, 13)
	box.add_child(header)
	(
		box
		. add_child(
			(
				_panel
				. _side_hint(
					(
						"Games set up once and played by mini-game nodes, or by boss encounters for a QTE. Each "
						+ "ends in a tier, and each tier pays out like a round's rewards."
					)
				)
			)
		)
	)
	_manage_btn = Button.new()
	_manage_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(_manage_btn, UITheme.PURPLE_MID)
	_manage_btn.pressed.connect(open_library)
	_update_manage_label()
	box.add_child(_manage_btn)
	return box


func _update_manage_label() -> void:
	if is_instance_valid(_manage_btn):
		_manage_btn.text = "⚙ MANAGE MINI-GAMES (%d)" % (_owner._journey_minigames as Array).size()


# ── The library ──────────────────────────────────────────────────────────────


func open_library() -> void:
	var parts: Dictionary = UITheme.build_centered_modal(
		"MINI-GAMES", UITheme.MINIGAME, LIBRARY_MODAL_SIZE
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	_owner.add_child(modal)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_library_list = VBoxContainer.new()
	_library_list.add_theme_constant_override("separation", 8)
	_library_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_library_list)
	_rebuild_library_list()

	var add_row: GridContainer = GridContainer.new()
	add_row.columns = LIBRARY_ADD_COLUMNS
	add_row.add_theme_constant_override("h_separation", 8)
	add_row.add_theme_constant_override("v_separation", 8)
	for kind: String in LIBRARY_KINDS:
		var add_btn: Button = Button.new()
		add_btn.text = "＋ " + KIND_NAMES[kind]
		add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(add_btn, UITheme.PURPLE_MID)
		add_btn.pressed.connect(func() -> void: open_definition(add_definition(kind)))
		add_row.add_child(add_btn)
	vbox.add_child(add_row)

	var close_btn: Button = Button.new()
	close_btn.text = "DONE"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(close_btn, UITheme.PURPLE_BRIGHT)
	var on_close: Callable = func() -> void:
		_library_list = null
		_update_manage_label()
		modal.queue_free()
	close_btn.pressed.connect(on_close)
	vbox.add_child(close_btn)
	var backdrop: Control = modal.get_child(0) as Control
	if backdrop:
		backdrop.gui_input.connect(
			func(event: InputEvent) -> void:
				if UITheme.is_backdrop_click(event):
					on_close.call()
		)


# Adds a new game of `kind`, named after its kind, and returns its index in the library.
func add_definition(kind: String) -> int:
	var definition: Dictionary = MiniGameLibrary.new_definition(kind)
	definition["name"] = KIND_NAMES[kind]
	(_owner._journey_minigames as Array).append(definition)
	_rebuild_library_list()
	return (_owner._journey_minigames as Array).size() - 1


func _rebuild_library_list() -> void:
	_update_manage_label()
	if not is_instance_valid(_library_list):
		return
	for child: Node in _library_list.get_children():
		child.queue_free()
	var library: Array = _owner._journey_minigames
	if library.is_empty():
		_library_list.add_child(_panel._side_hint("No mini-games yet — add one below."))
		return
	for i: int in library.size():
		_library_list.add_child(_make_library_row(i))


func _make_library_row(index: int) -> Control:
	var definition: Dictionary = _owner._journey_minigames[index]
	var card: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL_BG
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.set_content_margin_all(8)
	card.add_theme_stylebox_override("panel", style)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	card.add_child(row)
	var info: VBoxContainer = VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)
	var name_lbl: Label = Label.new()
	name_lbl.text = str(definition.get("name", ""))
	UITheme.style_label(name_lbl, UITheme.WHITE_SOFT, 12)
	info.add_child(name_lbl)
	var uses: int = usage_count(str(definition["id"]))
	var badge: Label = Label.new()
	badge.text = (
		"%s · %d tiers · %s"
		% [
			KIND_NAMES.get(definition["kind"], "?").to_upper(),
			(definition["tiers"] as Array).size(),
			"unused" if uses == 0 else "used %d×" % uses,
		]
	)
	UITheme.style_label(badge, UITheme.MINIGAME, 10)
	info.add_child(badge)

	# A rendition shows the base's games so its nodes can play them, but only adds its own.
	if _owner._rendition_parent_minigame_ids.has(str(definition["id"])):
		var locked: Label = Label.new()
		locked.text = "🔒 BASE"
		UITheme.style_label(locked, UITheme.TEXT_HINT, 10)
		row.add_child(locked)
		return card

	var edit_btn: Button = Button.new()
	edit_btn.text = "✎ EDIT"
	UITheme.style_button(edit_btn, UITheme.PURPLE_BRIGHT, 10, 4, 11)
	edit_btn.pressed.connect(func() -> void: open_definition(index))
	row.add_child(edit_btn)
	var delete_btn: Button = Button.new()
	delete_btn.text = "🗑"
	delete_btn.tooltip_text = "Delete this mini-game"
	UITheme.style_button(delete_btn, UITheme.DANGER, 10, 4, 11)
	delete_btn.pressed.connect(func() -> void: _confirm_delete(index))
	row.add_child(delete_btn)
	return card


# How many mini-game nodes and boss encounter blocks play the game `game_id`.
func usage_count(game_id: String) -> int:
	var count: int = 0
	for node: Variant in (_owner._graph_model.get("nodes", {}) as Dictionary).values():
		if not (node is Dictionary):
			continue
		var data: Dictionary = (node as Dictionary).get("data", {})
		if str((node as Dictionary).get("type", "")) == "minigame":
			if str(data.get("game", "")) == game_id:
				count += 1
		count += RoundTimeline.qte_games_on_node(data).count(game_id)
	return count


func _confirm_delete(index: int) -> void:
	var definition: Dictionary = _owner._journey_minigames[index]
	var uses: int = usage_count(str(definition["id"]))
	var delete: Callable = func() -> void:
		(_owner._journey_minigames as Array).erase(definition)
		_rebuild_library_list()
		_owner._refresh_graph()
	if uses == 0:
		delete.call()
		return
	_owner._show_builder_confirm(
		"DELETE MINI-GAME",
		(
			(
				'"%s" is used in %d place%s. Deleting it leaves them with no game, and the '
				+ "journey can't be saved until each one picks another."
			)
			% [definition["name"], uses, "" if uses == 1 else "s"]
		),
		"DELETE ANYWAY",
		delete
	)


# ── One game's editor ────────────────────────────────────────────────────────


# Whether this journey can edit the game `game_id`: a rendition shows its base's games, but can't change them.
func can_edit(game_id: String) -> bool:
	return not _owner._rendition_parent_minigame_ids.has(game_id)


# Opens the game `game_id`, for anything that holds it by id rather than by its place in the library.
func open_game(game_id: String, on_closed: Callable = Callable()) -> void:
	var library: Array = _owner._journey_minigames
	open_definition(library.find(MiniGameLibrary.find(library, game_id)), on_closed)


func open_definition(index: int, on_closed: Callable = Callable()) -> void:
	var library: Array = _owner._journey_minigames
	if index < 0 or index >= library.size():
		return
	var definition: Dictionary = library[index]
	var vp: Vector2 = _owner.get_viewport_rect().size
	var parts: Dictionary = UITheme.build_centered_modal(
		"MINI-GAME — " + str(KIND_NAMES.get(definition["kind"], "")).to_upper(),
		UITheme.MINIGAME,
		Vector2i(mini(820, int(vp.x * 0.9)), mini(940, int(vp.y * 0.92)))
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	_owner.add_child(modal)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	var gutter: MarginContainer = MarginContainer.new()  # keeps the scrollbar clear of the fields
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.add_theme_constant_override("margin_right", 16)
	scroll.add_child(gutter)
	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.add_child(body)

	_fill_definition(body, definition, _rebuild_definition.bind(body, definition))

	var close_btn: Button = Button.new()
	close_btn.text = "DONE"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(close_btn, UITheme.PURPLE_BRIGHT)
	var on_close: Callable = func() -> void:
		if str(definition.get("name", "")).strip_edges() == "":
			definition["name"] = KIND_NAMES[definition["kind"]]
		_renormalize(definition)
		modal.queue_free()
		_rebuild_library_list()
		_owner._refresh_graph()
		if on_closed.is_valid():
			on_closed.call()
	close_btn.pressed.connect(on_close)
	vbox.add_child(close_btn)
	var backdrop: Control = modal.get_child(0) as Control
	if backdrop:
		backdrop.gui_input.connect(
			func(event: InputEvent) -> void:
				if UITheme.is_backdrop_click(event):
					on_close.call()
		)


# Re-normalizes the definition in place (so every field reads the canonical shape) and rebuilds the
# editor's fields. Called after any change that adds or removes something.
func _rebuild_definition(body: VBoxContainer, definition: Dictionary) -> void:
	_renormalize(definition)
	for child: Node in body.get_children():
		child.queue_free()
	_fill_definition(body, definition, _rebuild_definition.bind(body, definition))


# Replaces the definition's contents with their normalized form, keeping the same dictionary (the library
# and any open editor hold it by reference).
static func _renormalize(definition: Dictionary) -> void:
	var normalized: Dictionary = MiniGameLibrary.normalize_definition(definition)
	definition.clear()
	definition.merge(normalized)


func _fill_definition(body: VBoxContainer, definition: Dictionary, rebuild: Callable) -> void:
	body.add_child(_panel._side_field_label("NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(definition["name"])
	name_edit.placeholder_text = "e.g. The Vault, Containment Lock"
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: definition["name"] = v)
	body.add_child(name_edit)
	if MiniGameLibrary.HOST_NODE in MiniGameLibrary.KIND_HOSTS[definition["kind"]]:
		_add_framing(body, definition)

	body.add_child(_panel._side_divider_line())
	match str(definition["kind"]):
		SafeCrackerGame.KIND:
			_add_safe_cracker_knobs(body, definition)
		DoubleOrNothingGame.KIND:
			_add_double_or_nothing_knobs(body, definition)
		StopTheBarGame.KIND:
			_add_stop_the_bar_knobs(body, definition)
		HoldReleaseGame.KIND:
			_add_hold_release_knobs(body, definition)
		PushYourLuckGame.KIND:
			_add_push_your_luck_knobs(body, definition)
		QuickTimeEventGame.KIND:
			_add_quick_time_event_knobs(body, definition)

	# A game over a playing round has no screen for a character to stand beside, and no time for a retry.
	if MiniGameLibrary.HOST_NODE in MiniGameLibrary.KIND_HOSTS[definition["kind"]]:
		body.add_child(_panel._side_divider_line())
		_add_game_character(body, definition, rebuild)

		body.add_child(_panel._side_divider_line())
		_add_attempts(body, definition, rebuild)

	body.add_child(_panel._side_divider_line())
	if str(definition["kind"]) == PushYourLuckGame.KIND:
		_add_pot_tiers(body, definition, rebuild)
	elif MiniGameLibrary.is_chance(definition["kind"]):
		_add_ladder(body, definition, rebuild)
	else:
		_add_score_tiers(body, definition, rebuild)


# ── Framing ──────────────────────────────────────────────────────────────────


# The creator's own words and colour on the game's screen.
func _add_framing(body: VBoxContainer, definition: Dictionary) -> void:
	(
		body
		. add_child(
			(
				_panel
				. _side_field_label(
					"INTRO TEXT  (OPTIONAL)",
					"Shown above the game's rules when it opens. The rules are written for you from its settings."
				)
			)
		)
	)
	var intro: TextEdit = TextEdit.new()
	intro.text = str(definition.get("intro_text", ""))
	intro.placeholder_text = "e.g. The vault hums as you approach…"
	intro.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	intro.custom_minimum_size = Vector2(0.0, INTRO_FIELD_HEIGHT)
	intro.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_text_edit(intro)
	intro.text_changed.connect(func() -> void: definition["intro_text"] = intro.text)
	body.add_child(intro)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var custom: CheckButton = CheckButton.new()
	custom.text = "CUSTOM ACCENT COLOUR"
	custom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom.button_pressed = str(definition.get("accent_color", "")) != ""
	custom.tooltip_text = (
		UITheme
		. wrap_tip(
			"The title, border and main buttons of this game's screen. Off, it uses the app's own, which follows the player's colour mode."
		)
	)
	row.add_child(custom)
	var swatch: ColorPickerButton = ColorPickerButton.new()
	swatch.custom_minimum_size = Vector2(QTE_KEY_BUTTON_SIZE, QTE_KEY_BUTTON_SIZE)
	swatch.edit_alpha = false
	swatch.color = MiniGameLibrary.accent_color(definition)
	swatch.visible = custom.button_pressed
	swatch.color_changed.connect(
		func(value: Color) -> void: definition["accent_color"] = value.to_html(false)
	)
	row.add_child(swatch)
	custom.toggled.connect(
		func(on: bool) -> void:
			swatch.visible = on
			definition["accent_color"] = swatch.color.to_html(false) if on else ""
	)
	body.add_child(row)


# A one-line field for what the player reads when a game ends a given way, written straight into `target`.
func _make_result_text_field(target: Dictionary, key: String) -> LineEdit:
	var field: LineEdit = LineEdit.new()
	field.text = str(target.get(key, ""))
	field.placeholder_text = "Result text (optional), e.g. The door swings wide."
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(field)
	field.text_changed.connect(func(v: String) -> void: target[key] = v)
	return field


# ── Knobs ────────────────────────────────────────────────────────────────────


func _add_safe_cracker_knobs(body: VBoxContainer, definition: Dictionary) -> void:
	var knobs: Dictionary = definition["knobs"]
	(
		body
		. add_child(
			(
				_panel
				. _side_hint(
					(
						"Turn a dial to find hidden numbers, in order. A warmth meter (and the device) says how "
						+ "close the dial is. Each number is an equal share of the score; wrong tries cost part of it."
					)
				)
			)
		)
	)
	body.add_child(
		_panel._side_field_label(
			"LOCK", "What the player is cracking. It changes the look only, not the rules."
		)
	)
	var lock: OptionButton = OptionButton.new()
	for style: String in LockArt.STYLES:
		lock.add_item(str(LockArt.STYLE_NAMES[style]))
	lock.selected = maxi(0, LockArt.STYLES.find(str(definition["lock"])))
	UITheme.style_option_button(lock)
	lock.item_selected.connect(func(i: int) -> void: definition["lock"] = LockArt.STYLES[i])
	body.add_child(lock)
	var ranges: Dictionary = SafeCrackerGame.KNOB_RANGES
	body.add_child(_knob_row(knobs, "numbers", "NUMBERS TO FIND", ranges, ""))
	body.add_child(_knob_row(knobs, "dial_size", "DIAL SIZE", ranges, " positions"))
	body.add_child(
		_knob_row(
			knobs, "tolerance", "TOLERANCE", ranges, " either side", "How far off a try may be."
		)
	)
	body.add_child(_knob_row(knobs, "time_limit_s", "TIME LIMIT", ranges, " s", "0 = no limit."))
	body.add_child(
		_knob_row(
			knobs,
			"max_wrong",
			"WRONG TRIES ALLOWED",
			ranges,
			"",
			"0 = unlimited. At the limit the dial jams."
		)
	)
	body.add_child(_panel._side_field_label("WARMTH METER"))
	var warmth: OptionButton = OptionButton.new()
	warmth.add_item("Precise — a smooth meter")
	warmth.add_item("Coarse — cold / warm / hot")
	warmth.add_item("Off — only the dial's click (and the device) hint")
	warmth.selected = SafeCrackerGame.WARMTH_MODES.find(str(knobs["warmth"]))
	UITheme.style_option_button(warmth)
	warmth.item_selected.connect(
		func(i: int) -> void: knobs["warmth"] = SafeCrackerGame.WARMTH_MODES[i]
	)
	body.add_child(warmth)


func _add_stop_the_bar_knobs(body: VBoxContainer, definition: Dictionary) -> void:
	var knobs: Dictionary = definition["knobs"]
	(
		body
		. add_child(
			(
				_panel
				. _side_hint(
					(
						"A marker sweeps along a bar, and the player stops it in a zone. Dead centre scores 100%, "
						+ "falling to 0% at the zone's edge. The score is the average of every stop."
					)
				)
			)
		)
	)
	var ranges: Dictionary = StopTheBarGame.KNOB_RANGES
	body.add_child(_knob_row(knobs, "stops", "STOPS", ranges, ""))
	body.add_child(
		_knob_row(
			knobs,
			"sweep_ms",
			"SWEEP TIME",
			ranges,
			" ms",
			"How long the marker takes to cross the bar once. Lower is harder."
		)
	)
	body.add_child(
		_knob_row(
			knobs, "zone_pct", "ZONE SIZE", ranges, "%", "How much of the bar the zone covers."
		)
	)
	_add_move_zone_toggle(
		body,
		knobs,
		"On: the zone moves to a random place for each stop. Off: it stays in the middle of the bar."
	)
	_add_gets_harder(
		body,
		knobs,
		ranges,
		"By the last stop, the sweep time and the zone are this much smaller, shrinking evenly from the first stop. 0 = off."
	)
	_add_show_tiers_toggle(body, knobs)


func _add_hold_release_knobs(body: VBoxContainer, definition: Dictionary) -> void:
	var knobs: Dictionary = definition["knobs"]
	(
		body
		. add_child(
			(
				_panel
				. _side_hint(
					(
						"Holding fills a gauge, and the player lets go in a zone. The zone's top edge scores 100% and "
						+ "anything past it scores 0%. Below the zone earns up to 30%. The score is the average of every hold."
					)
				)
			)
		)
	)
	body.add_child(
		_panel._side_field_label(
			"CONTAINER", "What the player is filling. It changes the look only, not the rules."
		)
	)
	var container: OptionButton = OptionButton.new()
	for style: String in GaugeArt.STYLES:
		container.add_item(str(GaugeArt.STYLE_NAMES[style]))
	container.selected = maxi(0, GaugeArt.STYLES.find(str(definition["container"])))
	UITheme.style_option_button(container)
	container.item_selected.connect(
		func(i: int) -> void: definition["container"] = GaugeArt.STYLES[i]
	)
	body.add_child(container)
	var ranges: Dictionary = HoldReleaseGame.KNOB_RANGES
	body.add_child(_knob_row(knobs, "holds", "HOLDS", ranges, ""))
	body.add_child(
		_knob_row(
			knobs,
			"fill_ms",
			"FILL TIME",
			ranges,
			" ms",
			"How long holding takes to fill the gauge completely. Lower is harder."
		)
	)
	body.add_child(_panel._side_field_label("FILL"))
	var fill_curve: OptionButton = OptionButton.new()
	fill_curve.add_item("Speeds up — slow at first, faster as it rises")
	fill_curve.add_item("Steady — one rate all the way")
	fill_curve.selected = HoldReleaseGame.FILL_CURVES.find(str(knobs["fill_curve"]))
	UITheme.style_option_button(fill_curve)
	fill_curve.item_selected.connect(
		func(i: int) -> void: knobs["fill_curve"] = HoldReleaseGame.FILL_CURVES[i]
	)
	body.add_child(fill_curve)
	body.add_child(
		_knob_row(
			knobs, "zone_pct", "ZONE SIZE", ranges, "%", "How much of the gauge the zone covers."
		)
	)
	_add_move_zone_toggle(
		body,
		knobs,
		"On: the zone moves to a random place for each hold. Off: it stays in one place."
	)
	_add_gets_harder(
		body,
		knobs,
		ranges,
		"By the last hold, the fill time and the zone are this much smaller, shrinking evenly from the first hold. 0 = off."
	)
	_add_show_tiers_toggle(body, knobs)


func _add_move_zone_toggle(body: VBoxContainer, knobs: Dictionary, tip: String) -> void:
	var moving: CheckButton = CheckButton.new()
	moving.text = "MOVE THE ZONE"
	moving.button_pressed = bool(knobs["moving_zone"])
	moving.tooltip_text = UITheme.wrap_tip(tip)
	moving.toggled.connect(func(on: bool) -> void: knobs["moving_zone"] = on)
	body.add_child(moving)


func _add_gets_harder(
	body: VBoxContainer, knobs: Dictionary, ranges: Dictionary, tip: String
) -> void:
	body.add_child(_knob_row(knobs, "harder_pct", "GETS HARDER", ranges, "%", tip))


func _add_show_tiers_toggle(body: VBoxContainer, knobs: Dictionary) -> void:
	var show_tiers: CheckButton = CheckButton.new()
	show_tiers.text = "SHOW TIERS ON THE METER"
	show_tiers.button_pressed = bool(knobs["show_tiers"])
	show_tiers.tooltip_text = (
		UITheme
		. wrap_tip(
			"On: the score meter marks and names each tier, so the player can see what they're chasing. Off: it shows only the score, and the tier stays a surprise until the end."
		)
	)
	show_tiers.toggled.connect(func(on: bool) -> void: knobs["show_tiers"] = on)
	body.add_child(show_tiers)


func _add_quick_time_event_knobs(body: VBoxContainer, definition: Dictionary) -> void:
	var knobs: Dictionary = definition["knobs"]
	(
		body
		. add_child(
			(
				_panel
				. _side_hint(
					(
						"Rings close on targets at random places during a boss round; the player presses the key "
						+ "each one names, inside the window. Place it on a boss encounter: on an attack, to "
						+ "dodge it, or on the QTE lane."
					)
				)
			)
		)
	)
	var ranges: Dictionary = QuickTimeEventGame.KNOB_RANGES
	body.add_child(_knob_row(knobs, "prompts", "PROMPTS", ranges, ""))
	_add_qte_key_picker(body, knobs)
	_add_qte_pause_toggle(body, knobs)
	_add_qte_look(body, knobs)
	body.add_child(_knob_row(knobs, "size_pct", "SIZE", ranges, "%"))
	body.add_child(
		_knob_row(
			knobs,
			"lead_ms",
			"RING CLOSES OVER",
			ranges,
			" ms",
			"How long a ring takes to reach its target."
		)
	)
	body.add_child(
		_knob_row(
			knobs,
			"window_ms",
			"HIT WINDOW",
			ranges,
			" ms",
			"How long a press counts, centred on the ring meeting the target."
		)
	)


func _add_qte_pause_toggle(body: VBoxContainer, knobs: Dictionary) -> void:
	var toggle: CheckButton = CheckButton.new()
	toggle.text = "PAUSE THE VIDEO"
	toggle.button_pressed = bool(knobs["pause_video"])
	toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"On: the video pauses and dims where this event falls, and carries on when it's over, so the "
				+ "player misses none of it. An attack lands after it. Off: the rings play over the moving "
				+ "video, right before an attack."
			)
		)
	)
	toggle.toggled.connect(func(on: bool) -> void: knobs["pause_video"] = on)
	body.add_child(toggle)


# The colours of the rings. The hit window is drawn in the target's colour.
func _add_qte_look(body: VBoxContainer, knobs: Dictionary) -> void:
	body.add_child(_make_qte_colour_row(knobs, "ring_color", "CLOSING RING COLOUR"))
	body.add_child(_make_qte_colour_row(knobs, "target_color", "TARGET COLOUR"))


func _make_qte_colour_row(knobs: Dictionary, key: String, label: String) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var name_label: Label = _panel._side_field_label(label)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var swatch: ColorPickerButton = ColorPickerButton.new()
	swatch.custom_minimum_size = Vector2(QTE_KEY_BUTTON_SIZE, QTE_KEY_BUTTON_SIZE)
	swatch.edit_alpha = false
	swatch.color = Color.html(str(knobs[key]))
	swatch.color_changed.connect(func(value: Color) -> void: knobs[key] = value.to_html(false))
	row.add_child(swatch)
	return row


# One toggle per key a creator can ask for. Always at least one on: an event needs a key to press.
func _add_qte_key_picker(body: VBoxContainer, knobs: Dictionary) -> void:
	(
		body
		. add_child(
			(
				_panel
				. _side_field_label(
					"KEYS",
					(
						"Each ring asks for one of these at random. Pressing another of them during a ring is a miss. "
						+ "F, M and S aren't offered, because the round already uses them."
					)
				)
			)
		)
	)
	var grid: GridContainer = GridContainer.new()
	grid.columns = QTE_KEY_COLUMNS
	var keys: Array = knobs["keys"]
	for key: String in QuickTimeEventGame.ALLOWED_KEYS:
		var toggle: Button = Button.new()
		toggle.text = key
		toggle.toggle_mode = true
		toggle.button_pressed = keys.has(key)
		toggle.custom_minimum_size = Vector2(QTE_KEY_BUTTON_SIZE, QTE_KEY_BUTTON_SIZE)
		UITheme.style_button(toggle, UITheme.MINIGAME)
		toggle.toggled.connect(
			func(on: bool) -> void:
				if on:
					keys.append(key)
				elif keys.size() > 1:
					keys.erase(key)
				else:
					toggle.set_pressed_no_signal(true)
		)
		grid.add_child(toggle)
	body.add_child(grid)


func _add_double_or_nothing_knobs(body: VBoxContainer, definition: Dictionary) -> void:
	(
		body
		. add_child(
			(
				_panel
				. _side_hint(
					(
						"The player holds the first rung and chooses: cash out, or risk it to climb one rung. Losing "
						+ "a risk busts. Reaching the top rung cashes out by itself. A game of chance: it never "
						+ "awards journey score."
					)
				)
			)
		)
	)
	var ranges: Dictionary = {
		"odds":
		[
			DoubleOrNothingGame.ODDS_RANGE[0],
			DoubleOrNothingGame.ODDS_RANGE[1],
			DoubleOrNothingGame.DEFAULT_ODDS
		]
	}
	body.add_child(_knob_row(definition["knobs"], "odds", "CHANCE TO WIN EACH RISK", ranges, " %"))


# The optional game character: someone from CAST who stands beside the game and reacts to it, in one of
# their own positions, with a portrait and a transition for each moment.
func _add_game_character(body: VBoxContainer, definition: Dictionary, rebuild: Callable) -> void:
	body.add_child(
		_panel._side_field_label(
			"GAME CHARACTER  (OPTIONAL)",
			"A character from CAST who stands outside the game's panel and reacts as it plays."
		)
	)
	var characters: Array = _owner._journey_characters
	var ids: Array = [""]
	var dd: OptionButton = OptionButton.new()
	dd.add_item("None")
	for candidate: Dictionary in characters:
		ids.append(str(candidate.get("id", "")))
		dd.add_item(str(candidate.get("name", "")))
	var block: Dictionary = definition.get("game_character", {})
	dd.selected = maxi(0, ids.find(str(block.get("character", ""))))
	UITheme.style_option_button(dd)
	dd.item_selected.connect(
		func(i: int) -> void:
			definition["game_character"] = {"character": ids[i]} if ids[i] != "" else {}
			rebuild.call()
	)
	body.add_child(dd)
	if characters.is_empty():
		body.add_child(_panel._side_hint("Add characters in JOURNEY INFO → CAST to use one here."))
	if block.is_empty():
		return
	var character: Dictionary = {}
	for candidate: Dictionary in characters:
		if str(candidate.get("id", "")) == str(block["character"]):
			character = candidate

	body.add_child(
		_panel._side_field_label(
			"POSITION", "One of the character's positions from CAST. Custom ones are made there."
		)
	)
	var placement_ids: Array = []
	var position: OptionButton = OptionButton.new()
	for placement: Dictionary in character.get("placements", []):
		placement_ids.append(str(placement.get("id", "")))
		position.add_item(str(placement.get("name", "")))
	position.selected = maxi(0, placement_ids.find(str(block.get("placement", ""))))
	UITheme.style_option_button(position)
	position.item_selected.connect(func(i: int) -> void: block["placement"] = placement_ids[i])
	body.add_child(position)

	var moments: Dictionary = block["moments"]
	for moment: String in MiniGameLibrary.GAME_CHARACTER_MOMENTS[definition["kind"]]:
		body.add_child(
			_make_moment_row(MOMENT_LABELS[moment], moments[moment], character.get("portraits", []))
		)


# One moment of a game character: its label, which portrait, and the transition into it.
func _make_moment_row(label: String, entry: Dictionary, portraits: Array) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl: Label = _panel._side_field_label(label)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var portrait_ids: Array = [""]
	var pick: OptionButton = OptionButton.new()
	pick.add_item("Default portrait")
	for portrait: Dictionary in portraits:
		portrait_ids.append(str(portrait.get("id", "")))
		var portrait_name: String = str(portrait.get("name", ""))
		pick.add_item(portrait_name if portrait_name != "" else "(unnamed)")
	pick.selected = maxi(0, portrait_ids.find(str(entry.get("portrait", ""))))
	pick.custom_minimum_size = Vector2(190, 0)
	UITheme.style_option_button(pick)
	pick.item_selected.connect(func(i: int) -> void: entry["portrait"] = portrait_ids[i])
	row.add_child(pick)

	var transition: OptionButton = OptionButton.new()
	for name: String in GameCharacterView.TRANSITIONS:
		transition.add_item(name.capitalize())
	transition.selected = maxi(
		0, GameCharacterView.TRANSITIONS.find(str(entry.get("transition", "")))
	)
	transition.custom_minimum_size = Vector2(110, 0)
	UITheme.style_option_button(transition)
	transition.item_selected.connect(
		func(i: int) -> void: entry["transition"] = GameCharacterView.TRANSITIONS[i]
	)
	row.add_child(transition)
	return row


# One labelled number field for knob `key` of `knobs`, bounded by `ranges[key]` ([min, max, default]).
func _knob_row(
	knobs: Dictionary,
	key: String,
	label: String,
	ranges: Dictionary,
	suffix: String,
	tip: String = "",
	on_change: Callable = Callable()
) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl: Label = _panel._side_field_label(label, tip)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var spin: SpinBox = SpinBox.new()
	spin.min_value = int(ranges[key][0])
	spin.max_value = int(ranges[key][1])
	spin.step = 1
	spin.suffix = suffix
	spin.value = int(knobs[key])
	spin.custom_minimum_size = Vector2(150, 0)
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(
		func(v: float) -> void:
			knobs[key] = int(v)
			if on_change.is_valid():
				on_change.call(int(v))
	)
	row.add_child(spin)
	return row


# ── Attempts and retry cost ──────────────────────────────────────────────────


func _add_attempts(body: VBoxContainer, definition: Dictionary, rebuild: Callable) -> void:
	var ranges: Dictionary = {"attempts": [1, MiniGameLibrary.MAX_ATTEMPTS, 1]}
	body.add_child(
		_knob_row(
			definition,
			"attempts",
			"ATTEMPTS",
			ranges,
			"",
			"How many times the player may play it. After a try they may keep the result or retry.",
			func(_v: int) -> void: rebuild.call()
		)
	)
	if int(definition["attempts"]) <= 1:
		return
	body.add_child(_panel._side_field_label("A RETRY IS OFFERED"))
	var rule: OptionButton = OptionButton.new()
	rule.add_item("After any result")
	rule.add_item("Only after the lowest tier")
	rule.selected = maxi(0, MiniGameLibrary.RETRY_RULES.find(str(definition["retry_when"])))
	UITheme.style_option_button(rule)
	rule.item_selected.connect(
		func(i: int) -> void: definition["retry_when"] = MiniGameLibrary.RETRY_RULES[i]
	)
	body.add_child(rule)
	(
		body
		. add_child(
			(
				_panel
				. _side_field_label(
					"EACH RETRY COSTS",
					"Paid when the player chooses to retry. Without the coins, they keep the result they have."
				)
			)
		)
	)
	body.add_child(_make_changes_editor(definition["retry_cost"], "COINS SPENT", false, false))


# ── Tiers (skill games) ──────────────────────────────────────────────────────


func _add_score_tiers(body: VBoxContainer, definition: Dictionary, rebuild: Callable) -> void:
	(
		body
		. add_child(
			(
				_panel
				. _side_field_label(
					"TIERS",
					"The score reaches the highest tier whose FROM SCORE it meets. The lowest tier always starts at 0."
				)
			)
		)
	)
	var tiers: Array = definition["tiers"]
	for i: int in tiers.size():
		body.add_child(_make_score_tier_card(definition, i, rebuild))
	var add_btn: Button = Button.new()
	add_btn.text = "＋ ADD TIER"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(
		func() -> void:
			var top: int = int((tiers[-1] as Dictionary)["min_score"])
			tiers.append({"name": "Tier %d" % (tiers.size() + 1), "min_score": mini(100, top + 10)})
			rebuild.call()
	)
	body.add_child(add_btn)

	# Auto-advance only guards a game that waits on the player, which one over a playing round never does.
	if not MiniGameLibrary.HOST_NODE in MiniGameLibrary.KIND_HOSTS[definition["kind"]]:
		return
	body.add_child(_panel._side_field_label("IF AUTO-ADVANCE RUNS OUT"))
	var timeout: OptionButton = OptionButton.new()
	var tier_ids: Array = [""]
	timeout.add_item("The lowest tier")
	for tier: Dictionary in tiers:
		tier_ids.append(tier["id"])
		timeout.add_item(str(tier["name"]))
	timeout.selected = maxi(0, tier_ids.find(str(definition["timeout_tier"])))
	UITheme.style_option_button(timeout)
	timeout.item_selected.connect(func(i: int) -> void: definition["timeout_tier"] = tier_ids[i])
	body.add_child(timeout)


func _make_score_tier_card(definition: Dictionary, index: int, rebuild: Callable) -> Control:
	var tiers: Array = definition["tiers"]
	var tier: Dictionary = tiers[index]
	var card: VBoxContainer = _card()

	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(tier["name"])
	name_edit.placeholder_text = "Tier name, e.g. Perfect"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: tier["name"] = v)
	head.add_child(name_edit)
	if index == 0:
		var from_zero: Label = Label.new()
		from_zero.text = "FROM 0%"
		UITheme.style_label(from_zero, UITheme.TEXT_HINT, 11)
		head.add_child(from_zero)
	else:
		var from: SpinBox = SpinBox.new()
		from.min_value = 1
		from.max_value = 100
		from.prefix = "FROM"
		from.suffix = "%"
		from.value = int(tier["min_score"])
		UITheme.style_spin_box(from)
		# Re-sorted when the editor closes or something is added, so typing a score doesn't jump the
		# tier around mid-edit.
		from.value_changed.connect(func(v: float) -> void: tier["min_score"] = int(v))
		head.add_child(from)
	if tiers.size() > 1:
		var remove: Button = Button.new()
		remove.text = "✕"
		remove.tooltip_text = "Remove this tier"
		UITheme.style_button(remove, UITheme.DANGER, 8, 4, 11)
		remove.pressed.connect(
			func() -> void:
				tiers.remove_at(index)
				rebuild.call()
		)
		head.add_child(remove)
	card.add_child(head)
	card.add_child(_make_result_text_field(tier, "result_text"))
	card.add_child(_rewards_toggle(tier["rewards"], true))
	return card.get_parent() as Control


# ── The ladder (Double or Nothing) ───────────────────────────────────────────


func _add_ladder(body: VBoxContainer, definition: Dictionary, rebuild: Callable) -> void:
	body.add_child(
		_panel._side_field_label(
			"THE LADDER",
			"Rung 1 is what the player holds at the start. Cashing out pays the rung they hold."
		)
	)
	var rungs: Array = definition["rungs"]
	for i: int in rungs.size():
		var rung: Dictionary = rungs[i]
		var card: VBoxContainer = _card()
		var head: HBoxContainer = HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		var number: Label = Label.new()
		number.text = "RUNG %d%s" % [i + 1, "  (TOP)" if i == rungs.size() - 1 else ""]
		UITheme.style_label(number, UITheme.MINIGAME, 11)
		head.add_child(number)
		var label_edit: LineEdit = LineEdit.new()
		label_edit.text = str(rung["label"])
		label_edit.placeholder_text = "Label shown to the player (optional)"
		label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_line_edit(label_edit)
		label_edit.text_changed.connect(func(v: String) -> void: rung["label"] = v)
		head.add_child(label_edit)
		if rungs.size() > DoubleOrNothingGame.MIN_RUNGS:
			var remove: Button = Button.new()
			remove.text = "✕"
			remove.tooltip_text = "Remove this rung"
			UITheme.style_button(remove, UITheme.DANGER, 8, 4, 11)
			var at: int = i
			remove.pressed.connect(
				func() -> void:
					rungs.remove_at(at)
					rebuild.call()
			)
			head.add_child(remove)
		card.add_child(head)
		card.add_child(_make_result_text_field(rung, "result_text"))
		card.add_child(_rewards_toggle(rung["rewards"], false))
		body.add_child(card.get_parent())
	if rungs.size() < DoubleOrNothingGame.MAX_RUNGS:
		var add_btn: Button = Button.new()
		add_btn.text = "＋ ADD RUNG"
		add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(add_btn, UITheme.PURPLE_MID)
		add_btn.pressed.connect(
			func() -> void:
				rungs.append({"label": "", "rewards": {}})
				rebuild.call()
		)
		body.add_child(add_btn)

	_add_bust_card(body, definition)


func _add_bust_card(body: VBoxContainer, definition: Dictionary) -> void:
	var bust: VBoxContainer = _card()
	var bust_head: Label = Label.new()
	bust_head.text = "IF THEY BUST"
	UITheme.style_label(bust_head, UITheme.DANGER, 11)
	bust.add_child(bust_head)
	bust.add_child(_make_result_text_field(definition, "bust_result_text"))
	bust.add_child(_rewards_toggle(definition["bust_rewards"], false))
	body.add_child(bust.get_parent())


# ── The pot (Push Your Luck) ─────────────────────────────────────────────────


func _add_pot_tiers(body: VBoxContainer, definition: Dictionary, rebuild: Callable) -> void:
	(
		body
		. add_child(
			(
				_panel
				. _side_field_label(
					"POT TIERS",
					"Banking reaches the highest tier whose FROM POT the pot meets. The lowest tier always starts at 0."
				)
			)
		)
	)
	var tiers: Array = definition["pot_tiers"]
	for i: int in tiers.size():
		body.add_child(_make_pot_tier_card(tiers, i, rebuild))
	var add_btn: Button = Button.new()
	add_btn.text = "＋ ADD TIER"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(
		func() -> void:
			var top: int = int((tiers[-1] as Dictionary)["min_pot"])
			tiers.append({"name": "Tier %d" % (tiers.size() + 1), "min_pot": top + POT_TIER_STEP})
			rebuild.call()
	)
	body.add_child(add_btn)
	_add_bust_card(body, definition)


func _make_pot_tier_card(tiers: Array, index: int, rebuild: Callable) -> Control:
	var tier: Dictionary = tiers[index]
	var card: VBoxContainer = _card()
	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(tier["name"])
	name_edit.placeholder_text = "Tier name, e.g. Big Win"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: tier["name"] = v)
	head.add_child(name_edit)
	if index == 0:
		var from_zero: Label = Label.new()
		from_zero.text = "FROM 0"
		UITheme.style_label(from_zero, UITheme.TEXT_HINT, 11)
		head.add_child(from_zero)
	else:
		var from: SpinBox = SpinBox.new()
		from.min_value = 1
		from.max_value = PushYourLuckGame.MAX_POT
		from.prefix = "FROM"
		from.value = int(tier["min_pot"])
		UITheme.style_spin_box(from)
		# Re-sorted when the editor closes or something is added, so typing doesn't jump the tier around.
		from.value_changed.connect(func(v: float) -> void: tier["min_pot"] = int(v))
		head.add_child(from)
	if tiers.size() > 1:
		var remove: Button = Button.new()
		remove.text = "✕"
		remove.tooltip_text = "Remove this tier"
		UITheme.style_button(remove, UITheme.DANGER, 8, 4, 11)
		remove.pressed.connect(
			func() -> void:
				tiers.remove_at(index)
				rebuild.call()
		)
		head.add_child(remove)
	card.add_child(head)
	card.add_child(_make_result_text_field(tier, "result_text"))
	card.add_child(_rewards_toggle(tier["rewards"], false))
	return card.get_parent() as Control


func _add_push_your_luck_knobs(body: VBoxContainer, definition: Dictionary) -> void:
	var knobs: Dictionary = definition["knobs"]
	(
		body
		. add_child(
			(
				_panel
				. _side_hint(
					(
						"The player starts with a small pot and chooses: bank it, or draw a token from a bag whose "
						+ "contents are always shown. Drawn tokens stay out, so the risk follows from what's left. "
						+ "With nothing left but traps, it banks by itself. A game of chance: it never awards journey "
						+ "score."
					)
				)
			)
		)
	)
	body.add_child(
		_panel._side_field_label(
			"STACK", "What the player is piling up. It changes the look only, not the rules."
		)
	)
	var stack: OptionButton = OptionButton.new()
	for style: String in StackArt.STYLES:
		stack.add_item(str(StackArt.STYLE_NAMES[style]))
	stack.selected = maxi(0, StackArt.STYLES.find(str(definition["stack"])))
	UITheme.style_option_button(stack)
	stack.item_selected.connect(func(i: int) -> void: definition["stack"] = StackArt.STYLES[i])
	body.add_child(stack)

	var ranges: Dictionary = PushYourLuckGame.KNOB_RANGES
	var bag_hint: Label = _panel._side_hint("")
	var refresh_hint: Callable = func(_value: int = 0) -> void:
		var values: int = int(knobs["value_tokens"])
		var traps: int = int(knobs["traps"])
		var total: int = values + traps + int(knobs["shields"]) + int(knobs["doublers"])
		bag_hint.text = (
			"The first push's risk is %d in %d (%d%%). Typical pots: %d at the start, %d with half the value tokens, %d with them all. With doubling, the most a run can hold is %d."
			% [
				traps,
				total,
				roundi(100.0 * traps / total),
				PushYourLuckGame.typical_pot(knobs, 0),
				PushYourLuckGame.typical_pot(knobs, floori(values / 2.0)),
				PushYourLuckGame.typical_pot(knobs, values),
				PushYourLuckGame.highest_pot(knobs),
			]
		)
	body.add_child(
		_knob_row(
			knobs,
			"value_tokens",
			"VALUE TOKENS",
			ranges,
			"",
			"Each adds to the pot, and adds more than the one before.",
			refresh_hint
		)
	)
	body.add_child(
		_knob_row(
			knobs,
			"traps",
			"TRAPS",
			ranges,
			"",
			"Each busts the player, unless they hold a shield.",
			refresh_hint
		)
	)
	body.add_child(
		_knob_row(
			knobs,
			"shields",
			"SHIELDS",
			ranges,
			"",
			"Each saves the player from one trap.",
			refresh_hint
		)
	)
	body.add_child(
		_knob_row(
			knobs,
			"doublers",
			"DOUBLERS",
			ranges,
			"",
			"Each doubles the pot as it stands, so a late one is worth the most.",
			refresh_hint
		)
	)
	body.add_child(
		_knob_row(
			knobs,
			"base_gain",
			"AVERAGE VALUE",
			ranges,
			"",
			"What the starting pot averages. Each value lands up to half as much again either way.",
			refresh_hint
		)
	)
	body.add_child(
		_knob_row(
			knobs,
			"gain_growth",
			"VALUE GROWS BY",
			ranges,
			"",
			"Added to the average with each value token drawn.",
			refresh_hint
		)
	)
	refresh_hint.call()
	body.add_child(bag_hint)


# ── Rewards ──────────────────────────────────────────────────────────────────


# A collapsed "REWARDS …" button with a summary, opening the fields for `rewards` beneath it. Collapsed
# by default: a game with five tiers would otherwise be a wall of pickers.
func _rewards_toggle(rewards: Dictionary, allow_score: bool) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var toggle: Button = Button.new()
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	UITheme.style_button_subtle(toggle, UITheme.PURPLE_BRIGHT, 8, 4, 11)
	box.add_child(toggle)
	var fields: Control = _make_changes_editor(rewards, "COINS (− TAKES COINS)", true, allow_score)
	fields.visible = false
	box.add_child(fields)
	var refresh_label: Callable = func() -> void:
		toggle.text = "%s REWARDS:  %s" % ["▾" if fields.visible else "▸", rewards_summary(rewards)]
	refresh_label.call()
	toggle.pressed.connect(
		func() -> void:
			fields.visible = not fields.visible
			refresh_label.call()
	)
	return box


# The fields for a rewards (or retry-cost) block, writing into `target`. `gives` adds the item given;
# `allow_score` adds journey score (skill games only).
func _make_changes_editor(
	target: Dictionary, coins_label: String, gives: bool, allow_score: bool
) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.add_child(_panel._side_field_label(coins_label))
	var coins: SpinBox = SpinBox.new()
	coins.min_value = -COINS_LIMIT if gives else 0
	coins.max_value = COINS_LIMIT
	coins.value = int(target.get("coins", 0))
	UITheme.style_spin_box(coins)
	coins.value_changed.connect(func(v: float) -> void: target["coins"] = int(v))
	col.add_child(coins)
	if gives:
		col.add_child(_panel._side_field_label("ITEM GIVEN"))
		var values: Array = [""]
		var dd: OptionButton = OptionButton.new()
		dd.add_item("None")
		for id: String in _panel._all_item_ids():
			values.append(id)
			dd.add_item(_panel._item_display_name(id))
		dd.selected = maxi(0, values.find(str(target.get("item", ""))))
		UITheme.style_option_button(dd)
		_panel._apply_item_tooltips(dd, values)
		dd.item_selected.connect(func(i: int) -> void: target["item"] = values[i])
		col.add_child(dd)
	col.add_child(_panel._make_remove_items_field(target))
	col.add_child(_panel._make_set_flags_field(target))
	col.add_child(_panel._make_set_counters_field(target))
	if allow_score:
		col.add_child(
			_panel._side_field_label(
				"JOURNEY SCORE", "Added to the run's score — and so to the leaderboard. 0 = none."
			)
		)
		var score: SpinBox = SpinBox.new()
		score.max_value = COINS_LIMIT
		score.value = int(target.get("score", 0))
		UITheme.style_spin_box(score)
		score.value_changed.connect(func(v: float) -> void: target["score"] = int(v))
		col.add_child(score)
	return col


# One line saying what a rewards block does: "♦ +20 · Key · ⚑ 1 · 🔢 1", or "nothing".
static func rewards_summary(rewards: Dictionary) -> String:
	var parts: Array[String] = []
	var coins: int = int(rewards.get("coins", 0))
	if coins != 0:
		parts.append("♦ %+d" % coins)
	if str(rewards.get("item", "")) != "":
		parts.append("+ item")
	var taken: int = (rewards.get("remove_items", []) as Array).size()
	if taken > 0:
		parts.append("− %d item%s" % [taken, "" if taken == 1 else "s"])
	var flags: int = (
		(rewards.get("set_flags", []) as Array).size()
		+ (rewards.get("clear_flags", []) as Array).size()
	)
	if flags > 0:
		parts.append("⚑ %d" % flags)
	var counters: int = (rewards.get("set_counters", {}) as Dictionary).size()
	if counters > 0:
		parts.append("🔢 %d" % counters)
	if int(rewards.get("score", 0)) > 0:
		parts.append("score +%d" % int(rewards["score"]))
	return " · ".join(PackedStringArray(parts)) if not parts.is_empty() else "nothing"


# A bordered card; returns its content column (the card is its parent).
func _card() -> VBoxContainer:
	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL_BG
	style.border_color = Color(UITheme.MINIGAME, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)
	return col


# ── A mini-game node's side panel ────────────────────────────────────────────


func make_node_editor(data: Dictionary, reselect: Callable) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.add_child(_panel._side_field_label("GAME"))

	var library: Array = _owner._journey_minigames
	var ids: Array = [""]
	var dd: OptionButton = OptionButton.new()
	dd.add_item("(pick a game)")
	for definition: Dictionary in library:
		if str(definition["kind"]) in NODE_KINDS:
			ids.append(definition["id"])
			dd.add_item("%s  —  %s" % [definition["name"], KIND_NAMES[definition["kind"]]])
	dd.selected = maxi(0, ids.find(str(data.get("game", ""))))
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(dd)
	dd.item_selected.connect(
		func(i: int) -> void:
			data["game"] = ids[i]
			_owner._refresh_graph()
			reselect.call(0)
	)
	col.add_child(dd)

	var game_id: String = str(data.get("game", ""))
	var index: int = library.find(MiniGameLibrary.find(library, game_id))
	if index >= 0:
		var uses: int = usage_count(game_id)
		if uses > 1:
			col.add_child(
				_panel._side_hint(
					"Played by %d mini-game nodes — editing it changes all of them." % uses
				)
			)
		if not _owner._rendition_parent_minigame_ids.has(game_id):
			var edit_btn: Button = Button.new()
			edit_btn.text = "✎ EDIT THIS GAME"
			edit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			UITheme.style_button(edit_btn, UITheme.MINIGAME)
			edit_btn.pressed.connect(func() -> void: open_definition(index, reselect.bind(0)))
			col.add_child(edit_btn)

	var new_buttons: VBoxContainer = VBoxContainer.new()
	new_buttons.add_theme_constant_override("separation", 6)
	for kind: String in NODE_KINDS:
		var new_btn: Button = Button.new()
		new_btn.text = "＋ NEW " + KIND_NAMES[kind]
		new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(new_btn, UITheme.PURPLE_MID, 8, 6, 11)
		new_btn.pressed.connect(
			func() -> void:
				var new_index: int = add_definition(kind)
				data["game"] = library[new_index]["id"]
				_owner._refresh_graph()
				open_definition(new_index, reselect.bind(0))
		)
		new_buttons.add_child(new_btn)
	col.add_child(new_buttons)

	col.add_child(_panel._side_divider_line())
	col.add_child(_panel._make_setting_picker(data))
	col.add_child(_panel._make_scene_override_section(data))
	return col
