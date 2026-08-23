class_name BuilderSidePanel
extends RefCounted

# ---------------------------------------------------------------------------
# BuilderSidePanel
# Renders the journey-builder's right-hand editor panel. Owns no state of its
# own — reads from and mutates the JourneyBuilder it was constructed with.
#
# Public entry points:
#   show_journey_info_panel()                 – default view, journey metadata
#   show_graph_node_editor(node_id)           – per-node editor for the selected graph node
#
# Everything else is internal. The owner (JourneyBuilder) is accessed via
# `_owner.<field>` / `_owner.<method>()`.
# ---------------------------------------------------------------------------

const COVER_HEIGHT: int = 280
const ROW_SEP: int = 8

# Difficulty list and file-extension sets are owned by JourneyData — the single
# canonical schema. Referenced here as JourneyData.<NAME>.

const DropZoneScript = preload("res://scripts/journey_builder/DropZone.gd")

# T-code secondary axes shown in the collapsible expander for each round.
const EXTRA_AXES_INFO: Array = [
	{"axis": "L1", "label": "L1  —  SURGE  (in / out)"},
	{"axis": "L2", "label": "L2  —  SWAY  (left / right)"},
	{"axis": "R0", "label": "R0  —  TWIST  (rotate)"},
	{"axis": "R1", "label": "R1  —  ROLL  (tilt side)"},
	{"axis": "R2", "label": "R2  —  PITCH  (tilt fwd / back)"},
]

# Vibrator channel drop zones shown in the collapsible expander for each round.
# key matches the vib_scripts dict key used by JourneyBuilder and GameLoop.
const VIB_CHANNELS_INFO: Array = [
	{"key": "vib1", "label": "VIB1  —  CHANNEL 0  (primary motor)"},
	{"key": "vib2", "label": "VIB2  —  CHANNEL 1  (secondary motor)"},
]

# Forced-modifier kinds a boss round can impose. Parallel arrays: KINDS feeds the
# saved data, LABELS feeds the editor dropdown.
# Gameplay forced-modifier kinds a boss round can impose. Visual/audio effects
# (incl. the old BLACKOUT) now live in the "Non-gameplay modifiers" picker.
const BOSS_MODIFIER_KINDS: Array = ["scale", "clamp", "reverse", "score_multiplier"]

# A list modal sized to its contents: chrome (title, footer buttons, padding) plus a row each, clamped so
# a long list still scrolls and a short one does not open onto a void.
const ITEMS_MODAL_CHROME: int = 260
const ITEMS_MODAL_ROW: int = 64
const ITEMS_MODAL_MIN: int = 340
const ITEMS_MODAL_MAX: int = 640

# The audition button beside an audio field. Wide enough to read, narrow enough to stay a utility.
const AUDIO_TEST_BTN_WIDTH: int = 84
const BOSS_MODIFIER_LABELS: Array = [
	"SCALE  —  STROKE LENGTH",
	"CLAMP  —  POSITION RANGE",
	"REVERSE  —  MIRROR",
	"SCORE MULTIPLIER",
]

var _owner: JourneyBuilder

# The selected pool round's bulk drop target: {zone, arr, idx, list, reselect}. Registered by
# _make_pool_expander and consumed by try_handle_pool_drop (JourneyBuilder routes OS drops to
# it). Cleared whenever the panel is rebuilt, so it never points at a freed control.
var _pool_drop: Dictionary = {}

# The custom-items list container, tracked so the editor modal can refresh it after the
# side panel is rebuilt underneath it (e.g. a save mid-edit frees the old container). The
# modal never holds a direct reference; it rebuilds through this, guarded by validity.
var _custom_items_list: VBoxContainer = null
# The side panel shows only a "Manage Items (N)" button; the list itself lives in a modal. Kept so the
# count stays live as items are added/removed. _custom_items_list points at the open modal's container.
var _manage_items_btn: Button = null
var _characters_list: VBoxContainer = null  # same live-container pattern as _custom_items_list


func _init(owner: JourneyBuilder) -> void:
	_owner = owner


# ── Public API ──────────────────────────────────────────────────────────────


# Default side-panel view (no node selected). Shows journey metadata + quick-add.
func show_journey_info_panel() -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	if side_vbox == null:
		return
	_pool_drop = {}  # the panel is being rebuilt — drop the stale pool drop-zone registration
	for c in side_vbox.get_children():
		c.queue_free()

	var hdr: Label = Label.new()
	hdr.text = "// JOURNEY INFO //"
	hdr.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_vbox.add_child(hdr)

	# Open-folder shortcut — jumps to this journey's media/ folder on disk (only
	# once it has been saved, since the folder won't exist before then).
	var open_folder_btn: Button = Button.new()
	open_folder_btn.text = "📁 OPEN MEDIA FOLDER"
	open_folder_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(open_folder_btn, UITheme.PURPLE_MID)
	open_folder_btn.pressed.connect(_owner._open_journey_folder)
	side_vbox.add_child(open_folder_btn)

	# Cover preview + button
	side_vbox.add_child(_side_field_label("COVER IMAGE"))
	var cover_border: PanelContainer = PanelContainer.new()
	cover_border.custom_minimum_size = Vector2(0, COVER_HEIGHT * 0.9)
	var cb_style: StyleBoxFlat = StyleBoxFlat.new()
	cb_style.bg_color = UITheme.PURPLE_DARK
	cb_style.border_color = UITheme.PURPLE_MID
	cb_style.border_width_left = 2
	cb_style.border_width_right = 2
	cb_style.border_width_top = 2
	cb_style.border_width_bottom = 2
	cover_border.add_theme_stylebox_override("panel", cb_style)
	side_vbox.add_child(cover_border)

	var cover_preview: TextureRect = TextureRect.new()
	cover_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cover_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	cover_preview.clip_contents = true
	if _owner._cover_texture != null:
		cover_preview.texture = _owner._cover_texture
	cover_border.add_child(cover_preview)

	if _owner._cover_path != "":
		var cover_row: HBoxContainer = HBoxContainer.new()
		cover_row.add_theme_constant_override("separation", 6)
		var change_btn: Button = Button.new()
		change_btn.text = "CHANGE COVER"
		change_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(change_btn, UITheme.PURPLE_MID)
		change_btn.pressed.connect(_owner._on_cover_pressed)
		cover_row.add_child(change_btn)
		var cover_rm_btn: Button = Button.new()
		cover_rm_btn.text = "✕ REMOVE"
		cover_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(cover_rm_btn, UITheme.MAGENTA)
		cover_rm_btn.pressed.connect(
			func() -> void:
				_delete_saved_image(_owner._cover_path)
				_owner._cover_path = ""
				_owner._cover_texture = null
				show_journey_info_panel()
		)
		cover_row.add_child(cover_rm_btn)
		side_vbox.add_child(cover_row)
	else:
		var cover_btn: Button = Button.new()
		cover_btn.text = "DROP IMAGE OR CLICK TO BROWSE"
		UITheme.style_button(cover_btn, UITheme.PURPLE_MID)
		cover_btn.pressed.connect(_owner._on_cover_pressed)
		side_vbox.add_child(cover_btn)

	side_vbox.add_child(_side_section_separator())

	# Name
	side_vbox.add_child(_side_field_label("JOURNEY NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Journey name..."
	name_edit.text = _owner._journey_name
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(val: String) -> void: _owner._journey_name = val)
	side_vbox.add_child(name_edit)

	# Author
	side_vbox.add_child(_side_field_label("AUTHOR"))
	var author_edit: LineEdit = LineEdit.new()
	author_edit.placeholder_text = "Author name..."
	author_edit.text = _owner._journey_author
	UITheme.style_line_edit(author_edit)
	author_edit.text_changed.connect(func(val: String) -> void: _owner._journey_author = val)
	side_vbox.add_child(author_edit)

	# Difficulty
	side_vbox.add_child(_side_field_label("DIFFICULTY"))
	var diff_btn: OptionButton = OptionButton.new()
	for diff: String in JourneyData.DIFFICULTIES:
		diff_btn.add_item(diff)
	diff_btn.selected = _owner._journey_difficulty_idx
	UITheme.style_option_button(diff_btn)
	diff_btn.item_selected.connect(func(idx: int) -> void: _owner._journey_difficulty_idx = idx)
	side_vbox.add_child(diff_btn)

	# Description
	side_vbox.add_child(_side_field_label("DESCRIPTION"))
	var desc_edit: TextEdit = TextEdit.new()
	desc_edit.placeholder_text = "Optional description..."
	desc_edit.text = _owner._journey_desc
	desc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_edit.custom_minimum_size = Vector2(0, 90)
	desc_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(desc_edit)
	desc_edit.text_changed.connect(func() -> void: _owner._journey_desc = desc_edit.text)
	side_vbox.add_child(desc_edit)

	# Tags — toggle chips, one per definition in tags.json.
	side_vbox.add_child(_side_field_label("TAGS"))
	var tag_flow: HFlowContainer = HFlowContainer.new()
	tag_flow.add_theme_constant_override("h_separation", 6)
	tag_flow.add_theme_constant_override("v_separation", 6)
	side_vbox.add_child(tag_flow)
	for tag_def: Dictionary in TagRegistry.all():
		tag_flow.add_child(_make_tag_toggle(tag_def))

	side_vbox.add_child(_side_section_separator())

	# Shown counters — journey-level. Counters listed here are surfaced to the player (a transient
	# top-right pop when they change + a list in the inventory panel); every other counter stays
	# hidden and gating-only. Names must match what nodes/choices set via "SETS COUNTERS".
	side_vbox.add_child(_side_field_label("SHOWN COUNTERS  (comma-separated, player-visible)"))
	var sc_edit: LineEdit = LineEdit.new()
	sc_edit.placeholder_text = "e.g. belt, satisfied_partners"
	sc_edit.text = ", ".join(
		PackedStringArray(JourneyData.clean_flag_list(_owner._journey_shown_counters))
	)
	UITheme.style_line_edit(sc_edit)
	sc_edit.text_changed.connect(
		func(v: String) -> void:
			_owner._journey_shown_counters = JourneyData.clean_flag_list(Array(v.split(",")))
	)
	side_vbox.add_child(sc_edit)

	side_vbox.add_child(_side_section_separator())

	# Player map — author switch. Off enforces "surprise": the player can't open
	# the in-play journey map (◇ MAP / M) for this journey.
	side_vbox.add_child(_side_field_label("PLAYER MAP"))
	var map_toggle: CheckButton = CheckButton.new()
	map_toggle.text = "ALLOW JOURNEY MAP"
	map_toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			"Let the player open the read-only journey map during play (◇ MAP button / M key). Turn off to keep the journey's layout a surprise."
		)
	)
	map_toggle.add_theme_font_size_override("font_size", 12)
	map_toggle.button_pressed = _owner._journey_map_enabled
	side_vbox.add_child(map_toggle)

	# Sub-options: fog of war + how far ahead it reveals. All grey out when the map is off; the step
	# count additionally greys out under "whole structure". Declared before the wiring so the shared
	# refresh closure can reach them all.
	var fog_toggle: CheckButton = CheckButton.new()
	fog_toggle.text = "FOG OF WAR  (REVEAL ON DISCOVERY)"
	fog_toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			"Reveal the map as the player plays: visited nodes shown in full, the steps ahead ghosted as '?', everything beyond hidden. Discovery resets each run."
		)
	)
	fog_toggle.add_theme_font_size_override("font_size", 12)
	fog_toggle.button_pressed = _owner._journey_map_fog
	side_vbox.add_child(fog_toggle)

	var reveal_row: HBoxContainer = HBoxContainer.new()
	reveal_row.add_theme_constant_override("separation", 8)
	var reveal_lbl: Label = Label.new()
	reveal_lbl.text = "STEPS REVEALED AHEAD"
	reveal_lbl.add_theme_font_size_override("font_size", 11)
	reveal_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	reveal_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reveal_row.add_child(reveal_lbl)
	var reveal_spin: SpinBox = SpinBox.new()
	reveal_spin.min_value = 0
	reveal_spin.max_value = 20
	reveal_spin.step = 1
	reveal_spin.value = maxi(0, _owner._journey_map_fog_reveal)
	reveal_spin.tooltip_text = UITheme.wrap_tip(
		"How many steps of '?' ghosts to show beyond the visited trail. 0 = trail only."
	)
	UITheme.style_spin_box(reveal_spin)
	reveal_row.add_child(reveal_spin)
	side_vbox.add_child(reveal_row)

	var whole_toggle: CheckButton = CheckButton.new()
	whole_toggle.text = "REVEAL WHOLE STRUCTURE"
	whole_toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			"Show EVERY node as a '?' ghost so the player sees the journey's shape without learning what each node is. Overrides the step count."
		)
	)
	whole_toggle.add_theme_font_size_override("font_size", 12)
	whole_toggle.button_pressed = _owner._journey_map_fog_reveal < 0
	side_vbox.add_child(whole_toggle)

	# Loops on the map: hidden by default (the markers are spliced out so the flow reads as a clean run);
	# the author opts in to reveal them. Only offered when the journey actually has a loop.
	var loops_toggle: CheckButton = null
	if _journey_has_loops():
		loops_toggle = CheckButton.new()
		loops_toggle.text = "SHOW LOOPS ON MAP"
		loops_toggle.tooltip_text = (
			UITheme
			. wrap_tip(
				"Show Loop Start / Loop End markers on the player's map. Off (the default) hides them, so the map shows the looped rounds as one straight run."
			)
		)
		loops_toggle.add_theme_font_size_override("font_size", 12)
		loops_toggle.button_pressed = _owner._journey_show_loops_on_map
		side_vbox.add_child(loops_toggle)
		loops_toggle.toggled.connect(func(on: bool) -> void: _owner._journey_show_loops_on_map = on)

	# Shared enable-state refresh: reveal controls need the map AND fog on; the step spin also greys out
	# under "whole structure"; the loops toggle needs the map on.
	var refresh_fog: Callable = func() -> void:
		var fog_on: bool = _owner._journey_map_enabled and _owner._journey_map_fog
		fog_toggle.disabled = not _owner._journey_map_enabled
		whole_toggle.disabled = not fog_on
		reveal_spin.editable = fog_on and not whole_toggle.button_pressed
		if loops_toggle != null:
			loops_toggle.disabled = not _owner._journey_map_enabled
	refresh_fog.call()

	reveal_spin.value_changed.connect(
		func(v: float) -> void:
			if not whole_toggle.button_pressed:
				_owner._journey_map_fog_reveal = int(v)
	)
	whole_toggle.toggled.connect(
		func(on: bool) -> void:
			_owner._journey_map_fog_reveal = -1 if on else int(reveal_spin.value)
			refresh_fog.call()
	)
	fog_toggle.toggled.connect(
		func(on: bool) -> void:
			_owner._journey_map_fog = on
			refresh_fog.call()
	)
	map_toggle.toggled.connect(
		func(on: bool) -> void:
			_owner._journey_map_enabled = on
			refresh_fog.call()
	)

	# Map backdrop — an image behind the graph (editor + in-game map) to align nodes to locations.
	side_vbox.add_child(_side_section_separator())
	_build_map_backdrop_section(side_vbox)

	# Fork choices: show or hide the "N ROUNDS" tag on each choice (rounds distinct to that path).
	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_side_field_label("FORK CHOICES"))
	var fork_counts_toggle: CheckButton = CheckButton.new()
	fork_counts_toggle.text = "SHOW ROUND COUNTS"
	fork_counts_toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			'Show the "N ROUNDS" tag on each fork choice — how many rounds are down that path before it rejoins another. Turn off to hide it and keep each choice a mystery.'
		)
	)
	fork_counts_toggle.add_theme_font_size_override("font_size", 12)
	fork_counts_toggle.button_pressed = _owner._journey_show_fork_counts
	side_vbox.add_child(fork_counts_toggle)
	fork_counts_toggle.toggled.connect(
		func(on: bool) -> void: _owner._journey_show_fork_counts = on
	)

	# Mystery preview: blur the journey-select preview's totals + round flow until the player has
	# DISCOVERED nodes (persistent across playthroughs), keeping length/structure a surprise.
	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_side_field_label("JOURNEY PREVIEW"))
	var mystery_toggle: CheckButton = CheckButton.new()
	mystery_toggle.text = "MYSTERY PREVIEW  (BLUR UNTIL DISCOVERED)"
	mystery_toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			"On the journey-select screen, blur the totals (rounds · duration · actions) and the round-by-round flow. Each un-blurs once the player has ever reached that node, so length and structure stay a surprise until explored."
		)
	)
	mystery_toggle.add_theme_font_size_override("font_size", 12)
	mystery_toggle.button_pressed = _owner._journey_mystery_preview
	side_vbox.add_child(mystery_toggle)
	mystery_toggle.toggled.connect(func(on: bool) -> void: _owner._journey_mystery_preview = on)

	# Auto-advance: a countdown on storyboards (per line) and interactive forks so a player can't
	# park there to "rest". The seconds spin greys out until it's enabled.
	side_vbox.add_child(_side_section_separator())
	var aa_toggle: CheckButton = CheckButton.new()
	aa_toggle.text = "AUTO-ADVANCE STORYBOARDS & FORKS"
	aa_toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			"Show a countdown on storyboards (per dialogue line) and interactive forks so players can't linger to rest. When a fork's timer runs out it takes the author's timeout choice (set per fork), or a random affordable path if none is set."
		)
	)
	aa_toggle.add_theme_font_size_override("font_size", 12)
	aa_toggle.button_pressed = _owner._journey_auto_advance_enabled
	side_vbox.add_child(aa_toggle)

	# Separate durations: a dialogue line is quick to read; a fork can need longer to decide.
	var sb_spin: SpinBox = _make_seconds_row(
		side_vbox,
		"STORYBOARD LINE SECONDS",
		_owner._journey_auto_advance_storyboard_secs,
		"How long each storyboard dialogue line shows before it auto-advances."
	)
	var fork_spin: SpinBox = _make_seconds_row(
		side_vbox,
		"FORK / SHOP SECONDS",
		_owner._journey_auto_advance_fork_secs,
		"How long an interactive fork waits before it auto-resolves, and how long a shop stays open before it auto-continues."
	)
	sb_spin.editable = _owner._journey_auto_advance_enabled
	fork_spin.editable = _owner._journey_auto_advance_enabled

	aa_toggle.toggled.connect(
		func(on: bool) -> void:
			_owner._journey_auto_advance_enabled = on
			sb_spin.editable = on
			fork_spin.editable = on
	)
	sb_spin.value_changed.connect(
		func(v: float) -> void: _owner._journey_auto_advance_storyboard_secs = int(v)
	)
	fork_spin.value_changed.connect(
		func(v: float) -> void: _owner._journey_auto_advance_fork_secs = int(v)
	)

	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_make_finish_section())

	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_make_custom_items_section())

	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_make_characters_section())

	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_make_graph_add_buttons())


# The MAP BACKDROPS section of the journey-info panel: a stack of location images. Locked base layers show
# first (rendition context), then this journey's own editable layers (opacity/scale/reposition/remove each),
# then an "add" drop-zone. Live edits push straight to the graph view.
func _build_map_backdrop_section(side_vbox: VBoxContainer) -> void:
	side_vbox.add_child(_side_field_label("MAP BACKDROPS"))
	var hint: Label = Label.new()
	hint.text = "Images drawn behind the graph — and behind the in-game map — so you can align nodes to places. Stack several; each has its own placement + rotation. Top of the list is in FRONT. Static images only."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side_vbox.add_child(hint)

	# Front layer at the TOP of the list (image-editor convention). Editable layers first (they sit in
	# front of the base), then the locked base context beneath — each group front-most first.
	for i: int in range(_owner._map_backdrops.size() - 1, -1, -1):
		side_vbox.add_child(_make_backdrop_row(i))
	for i: int in range(_owner._base_backdrops.size() - 1, -1, -1):
		side_vbox.add_child(_make_locked_backdrop_row(_owner._base_backdrops[i], i))

	var add_zone: PanelContainer = DropZoneScript.new()
	add_zone.accepted_extensions = ["png", "jpg", "jpeg", "webp", "bmp"]
	add_zone.picker_title = "Add Map Backdrop"
	add_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp,*.bmp ; Image Files"]
	add_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_vbox.add_child(add_zone)
	add_zone.file_dropped.connect(
		func(p: String) -> void:
			_owner._map_backdrops.append(
				{"path": p, "offset": Vector2.ZERO, "scale": 1.0, "opacity": 0.6}
			)
			_owner._push_backdrops()
			show_journey_info_panel()  # rebuild so the new layer's controls appear
	)


# A card StyleBoxFlat for a backdrop layer: dark fill + a tinted accent border (cyan = editable, dim =
# locked base), rounded, padded — so each layer reads as its own item in the list.
func _backdrop_card_style(accent: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.05, 0.11, 0.85)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 9
	sb.content_margin_bottom = 9
	return sb


# A small square image preview for a backdrop layer, so cards are told apart at a glance.
func _backdrop_thumb(path: String) -> Control:
	var frame: PanelContainer = PanelContainer.new()
	var fs: StyleBoxFlat = StyleBoxFlat.new()
	fs.bg_color = Color(0, 0, 0, 0.45)
	fs.set_corner_radius_all(5)
	frame.add_theme_stylebox_override("panel", fs)
	frame.custom_minimum_size = Vector2(46, 46)
	var tr: TextureRect = TextureRect.new()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.clip_contents = true
	tr.custom_minimum_size = Vector2(46, 46)
	tr.texture = _owner._backdrop_texture(path)
	frame.add_child(tr)
	return frame


# A read-only CARD for a base backdrop shown as locked context while editing a rendition: thumbnail +
# "🔒 base layer N" + filename, dimmed to read as untouchable.
func _make_locked_backdrop_row(b: Dictionary, i: int) -> Control:
	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", _backdrop_card_style(UITheme.SEPARATOR))
	card.modulate = Color(1, 1, 1, 0.75)
	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(_backdrop_thumb(str(b.get("path", ""))))
	var titles: VBoxContainer = VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var t1: Label = Label.new()
	t1.text = "🔒 BASE LAYER %d" % (i + 1)
	t1.add_theme_color_override("font_color", UITheme.SEPARATOR)
	t1.add_theme_font_size_override("font_size", 11)
	t1.uppercase = true
	titles.add_child(t1)
	titles.add_child(_backdrop_filename_label(str(b.get("path", ""))))
	head.add_child(titles)
	card.add_child(head)
	return card


# An editable CARD for this journey's own backdrop layer `i`: header (thumbnail + label + remove), then
# opacity + scale sliders and a reposition toggle (only one layer repositions at a time).
func _make_backdrop_row(i: int) -> Control:
	var b: Dictionary = _owner._map_backdrops[i]
	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", _backdrop_card_style(UITheme.CYAN))
	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	card.add_child(body)

	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(_backdrop_thumb(str(b.get("path", ""))))
	var titles: VBoxContainer = VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var t1: Label = Label.new()
	t1.text = "LAYER %d" % (i + 1)
	t1.add_theme_color_override("font_color", UITheme.CYAN)
	t1.add_theme_font_size_override("font_size", 12)
	t1.uppercase = true
	titles.add_child(t1)
	titles.add_child(_backdrop_filename_label(str(b.get("path", ""))))
	head.add_child(titles)
	# Z-order: ▲ brings this layer toward the FRONT (drawn on top), ▼ sends it toward the back.
	var last: int = _owner._map_backdrops.size() - 1
	var up: Button = UITheme.make_icon_btn("▲", i >= last, UITheme.CYAN)
	up.tooltip_text = UITheme.wrap_tip("Bring forward (overlay the layer in front of it)")
	up.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	up.pressed.connect(
		func() -> void:
			_owner._move_backdrop(i, 1)
			show_journey_info_panel()
	)
	head.add_child(up)
	var down: Button = UITheme.make_icon_btn("▼", i <= 0, UITheme.CYAN)
	down.tooltip_text = UITheme.wrap_tip("Send back (behind the next layer)")
	down.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	down.pressed.connect(
		func() -> void:
			_owner._move_backdrop(i, -1)
			show_journey_info_panel()
	)
	head.add_child(down)
	var rm: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	rm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rm.pressed.connect(
		func() -> void:
			_delete_saved_image(str((_owner._map_backdrops[i] as Dictionary).get("path", "")))
			_owner._map_backdrops.remove_at(i)
			_owner._backdrop_reposition_idx = -1
			if is_instance_valid(_owner._graph):
				_owner._graph.set_backdrop_reposition(-1)
			_owner._push_backdrops()
			show_journey_info_panel()
	)
	head.add_child(rm)
	body.add_child(head)

	body.add_child(_side_field_label("OPACITY"))
	var op: HSlider = HSlider.new()
	op.min_value = 0.05
	op.max_value = 1.0
	op.step = 0.05
	op.value = float(b.get("opacity", 0.6))
	op.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(op)
	op.value_changed.connect(
		func(v: float) -> void:
			b["opacity"] = v
			_owner._push_backdrop_transform(i)
	)

	body.add_child(_side_field_label("SCALE"))
	var sc: HSlider = HSlider.new()
	sc.min_value = 0.1
	sc.max_value = 4.0
	sc.step = 0.05
	sc.value = float(b.get("scale", 1.0))
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(sc)
	sc.value_changed.connect(
		func(v: float) -> void:
			b["scale"] = v
			_owner._push_backdrop_transform(i)
	)

	body.add_child(_side_field_label("ROTATION"))
	var ro: HSlider = HSlider.new()
	ro.min_value = -180.0
	ro.max_value = 180.0
	ro.step = 1.0
	ro.value = float(b.get("rotation", 0.0))
	ro.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(ro)
	ro.value_changed.connect(
		func(v: float) -> void:
			b["rotation"] = v
			_owner._push_backdrop_transform(i)
	)

	var repos: CheckButton = CheckButton.new()
	repos.text = "REPOSITION  (DRAG ON CANVAS)"
	repos.tooltip_text = (
		UITheme
		. wrap_tip(
			"Turn on, then drag on the canvas to slide THIS layer under your nodes (scroll still zooms)."
		)
	)
	repos.add_theme_font_size_override("font_size", 11)
	repos.button_pressed = _owner._backdrop_reposition_idx == i
	repos.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	repos.toggled.connect(
		func(on: bool) -> void:
			_owner._backdrop_reposition_idx = i if on else -1
			if is_instance_valid(_owner._graph):
				_owner._graph.set_backdrop_reposition(
					(_owner._base_backdrops.size() + i) if on else -1
				)
			show_journey_info_panel()  # rebuild so only the active layer's toggle reads on
	)
	body.add_child(repos)
	return card


# A small muted filename label (ellipsised) for a backdrop card.
func _backdrop_filename_label(path: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = path.get_file() if path != "" else "—"
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.clip_text = true
	return lbl


# A labelled seconds SpinBox row (5–600, step 1) added to `parent`; returns the spin so the caller
# wires editability + value_changed. Used for the two auto-advance durations.
func _make_seconds_row(
	parent: VBoxContainer, label_text: String, value: int, tip: String
) -> SpinBox:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl: Label = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var spin: SpinBox = SpinBox.new()
	spin.min_value = 5
	spin.max_value = 600
	spin.step = 1
	spin.value = clampi(value, 5, 600)
	spin.tooltip_text = UITheme.wrap_tip(tip)
	UITheme.style_spin_box(spin)
	row.add_child(spin)
	parent.add_child(row)
	return spin


# Gameplay effect kinds an item can bundle. Timed: stroke modifiers + blackout + score + coin. One-shot
# (fire once on use, then consumed): toll / interest / flag / counter. Timed HUD hide: hud_hide (Fog).
# Sensory (visual/audio) kinds are ALSO offered — appended from SENSORY_CATALOG in the effect dropdown,
# applied for the item's duration via SensoryFX.reconcile. Still NOT offered: gift / lingering / no_pause.
const _ITEM_EFFECT_KINDS: Array = [
	"scale",
	"clamp",
	"reverse",
	"block",
	"blackout",
	"score_multiplier",
	"score_add",
	"coin_jackpot",
	"coin_penalty",
	"toll",
	"interest",
	"hud_hide",
	"flag",
	"counter"
]


# FINISH ("I came") — a journey opt-in for an always-available hold-to-confirm button that ends the run
# early, optionally into a designated aftercare storyboard (off-graph) before the end screen.
func _make_finish_section() -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var header: Label = Label.new()
	header.text = 'FINISH  ( "I CAME" )'
	header.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	header.add_theme_font_size_override("font_size", 13)
	box.add_child(header)
	var hint: Label = Label.new()
	hint.text = (
		"An always-available hold-to-confirm button that ends the run early — optionally into an "
		+ 'aftercare SEQUENCE (e.g. a "you lose" storyboard → an aftercare round) before the end screen. '
		+ "Pick the FIRST node; wire the rest off the main graph, ending in a node with no exit."
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 11)
	box.add_child(hint)

	var toggle: CheckButton = CheckButton.new()
	toggle.text = "ALLOW FINISH BUTTON"
	toggle.add_theme_font_size_override("font_size", 12)
	toggle.button_pressed = _owner._journey_allow_finish
	box.add_child(toggle)

	box.add_child(_side_field_label("AFTERCARE — FIRST NODE  (OPTIONAL)"))
	var dd: OptionButton = OptionButton.new()
	var node_ids: Array = [""]  # index 0 = None
	dd.add_item("None — straight to end screen")
	# The ENTRY to the aftercare sequence — a round or storyboard. Whatever the author wires off it (a
	# chain of rounds/storyboards, off the main graph) plays in turn until a node with no exit → the end
	# screen. Numbered per type in insertion order, with an identifying stub to spot the node.
	var nodes: Dictionary = _owner._graph_model.get("nodes", {})
	var counts: Dictionary = {"round": 0, "storyboard": 0}
	for id: String in nodes:
		var node: Dictionary = nodes[id]
		var ntype: String = str(node.get("type", ""))
		if not counts.has(ntype):
			continue  # only round + storyboard can be a finish node
		counts[ntype] += 1
		var stub: String = _finish_node_hint(ntype, node.get("data", {}))
		var label: String = "Round" if ntype == "round" else "Storyboard"
		dd.add_item("%s %d%s" % [label, counts[ntype], (" — " + stub) if stub != "" else ""])
		node_ids.append(id)
	dd.selected = maxi(0, node_ids.find(_owner._journey_finish_node))
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(dd)
	dd.disabled = not _owner._journey_allow_finish
	dd.item_selected.connect(
		func(i: int) -> void:
			_owner._journey_finish_node = str(node_ids[i])
			_owner._refresh_graph()  # move the 🏁 FINISH badge to the new node live
	)
	box.add_child(dd)

	toggle.toggled.connect(
		func(on: bool) -> void:
			_owner._journey_allow_finish = on
			dd.disabled = not on
	)
	return box


# A short identifying stub for a finish-node dropdown entry: a round's name, or a storyboard's first
# speaker / start of its first line. "" when there's nothing to show.
func _finish_node_hint(ntype: String, data: Dictionary) -> String:
	if ntype == "round":
		return str(data.get("name", "")).strip_edges()
	var lines: Array = data.get("lines", [])
	if lines.size() > 0 and lines[0] is Dictionary:
		var l: Dictionary = lines[0]
		var speaker: String = str(l.get("speaker", "")).strip_edges()
		if speaker != "":
			return speaker
		var text: String = str(l.get("text", "")).strip_edges()
		if text != "":
			return text.substr(0, 24)
	return ""


# Journey-scoped custom item manager (Slice 1: name/description/type/price + a stroke-effect bundle
# for modifiers). Items mutate _owner._journey_items in place; the list re-renders on structural change.
func _make_custom_items_section() -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var header: Label = Label.new()
	header.text = "CUSTOM ITEMS"
	header.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	header.add_theme_font_size_override("font_size", 13)
	box.add_child(header)
	var hint: Label = Label.new()
	hint.text = "Journey-specific items that bundle tuned effects or an override stroke. They appear in the item dropdowns."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 11)
	box.add_child(hint)

	# The list itself opens in a modal (it can get long); the side panel keeps only this entry point.
	var manage_btn: Button = Button.new()
	manage_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(manage_btn, UITheme.PURPLE_MID)
	manage_btn.pressed.connect(_open_items_manager_modal)
	_manage_items_btn = manage_btn
	_update_manage_items_label()
	box.add_child(manage_btn)
	return box


# The custom-item LIST lives in its own modal (not the cramped side panel) so a journey can define many
# items without crowding the builder. Rows edit/delete; ＋ ADD appends and opens the editor on top.
# _custom_items_list points at this modal's container while it's open, so any edit refreshes the list.
# Tall enough for what is actually in the list, capped so a long one still scrolls rather than running
# off the screen.
func _items_modal_height() -> int:
	var rows: int = (_owner._journey_items as Array).size()
	return clampi(ITEMS_MODAL_CHROME + rows * ITEMS_MODAL_ROW, ITEMS_MODAL_MIN, ITEMS_MODAL_MAX)


func _open_items_manager_modal() -> void:
	# Height follows the list instead of always reserving room for ten items. A journey with one item
	# used to open a 640px panel with a single row at the top and a void beneath it.
	var parts: Dictionary = UITheme.build_centered_modal(
		"CUSTOM ITEMS", UITheme.PURPLE_BRIGHT, Vector2i(560, _items_modal_height())
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	_owner.add_child(modal)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var list: VBoxContainer = VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	_custom_items_list = list
	_rebuild_custom_items_list()

	var add_btn: Button = Button.new()
	add_btn.text = "＋ ADD ITEM"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(
		func() -> void:
			_owner._journey_items.append(_default_custom_item())
			_rebuild_custom_items_list()
			_open_item_editor_modal(_owner._journey_items.size() - 1, true)
	)
	vbox.add_child(add_btn)

	var close_btn: Button = Button.new()
	close_btn.text = "DONE"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(close_btn, UITheme.PURPLE_BRIGHT)
	# Drop the container reference so a stray rebuild after close no-ops (the guard checks validity).
	var on_close: Callable = func() -> void:
		_custom_items_list = null
		_update_manage_items_label()
		modal.queue_free()
	close_btn.pressed.connect(on_close)
	vbox.add_child(close_btn)

	var backdrop: Control = modal.get_child(0) as Control
	if backdrop:
		backdrop.gui_input.connect(
			func(event: InputEvent) -> void:
				if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
					on_close.call()
		)


func _update_manage_items_label() -> void:
	if is_instance_valid(_manage_items_btn):
		_manage_items_btn.text = "⚙ MANAGE ITEMS (%d)" % _owner._journey_items.size()


# Re-renders the custom-items rows into the tracked list container (the open modal's). No-op if no modal
# is up (the container is null/freed); always refreshes the side button's count.
func _rebuild_custom_items_list() -> void:
	_update_manage_items_label()
	if not is_instance_valid(_custom_items_list):
		return
	for c: Node in _custom_items_list.get_children():
		c.queue_free()
	if _owner._journey_items.is_empty():
		var empty: Label = Label.new()
		empty.text = "No custom items yet — add one below."
		empty.add_theme_color_override("font_color", UITheme.SEPARATOR)
		empty.add_theme_font_size_override("font_size", 11)
		_custom_items_list.add_child(empty)
		return
	for i: int in _owner._journey_items.size():
		_custom_items_list.add_child(_make_custom_item_row(i))


# A volume control and its audition button on one line, which is how they are used: set a level, hear
# it, adjust. They were stacked, and the button spanned the panel — the utility outweighing the setting.
#
# Volume reads as a PERCENTAGE everywhere now. The three storyboard/fork fields showed a raw "vol 0.60"
# while the item editor showed "VOLUME 60%", which is one idea wearing two faces.
func _make_volume_row(
	host: Node, target: Dictionary, key: String, default: float, read_path: Callable
) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var spin: SpinBox = SpinBox.new()
	spin.min_value = 0
	spin.max_value = 100
	spin.step = 1
	spin.suffix = "%"
	spin.value = 100.0 * float(target.get(key, default))
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(func(v: float) -> void: target[key] = v / 100.0)
	row.add_child(spin)

	row.add_child(
		_make_audio_test_button(
			host, read_path, func() -> float: return float(target.get(key, default))
		)
	)
	return row


# An audition button for an audio drop zone: press to hear the clip at the volume set beside it, press
# again to stop. Every audio field in the builder had a drop zone and no way to hear what landed in it,
# so a level was something an author set by eye and found out about in a round.
#
# Reads through CALLABLES rather than being handed values, because both the path and the volume change
# after this is built — dropping a different file or nudging the level has to affect the next press.
#
# The player is parented to the caller's container, so it is freed with the panel and nothing is left
# playing over a screen that has gone.
func _make_audio_test_button(host: Node, read_path: Callable, read_volume: Callable) -> Button:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	host.add_child(player)

	var button: Button = Button.new()
	button.text = "▶ TEST"
	# Compact and shrink-to-fit rather than full width: it is a utility beside the thing it tests, and at
	# panel width in the brightest colour on screen it read as the section's primary action.
	button.size_flags_horizontal = Control.SIZE_SHRINK_END
	button.custom_minimum_size.x = AUDIO_TEST_BTN_WIDTH
	UITheme.style_button_subtle(button, UITheme.TOXIC_GREEN, 9, 4, 10)
	button.pressed.connect(
		func() -> void:
			if player.playing:
				player.stop()
				button.text = "▶ TEST"
				return
			var path: String = str(read_path.call()).strip_edges()
			if path == "":
				_owner._show_status("Drop an audio file first.", true)
				return
			var stream: AudioStream = JourneyAudio.load_from_file(path)
			if stream == null:
				_owner._show_status("Could not read that audio file.", true)
				return
			player.stream = stream
			player.volume_db = linear_to_db(maxf(0.0001, float(read_volume.call())))
			player.play()
			button.text = "■ STOP"
	)
	# A clip that runs out on its own puts the label back without anyone pressing anything.
	player.finished.connect(func() -> void: button.text = "▶ TEST")
	return button


# The sound this item makes when it is used, INSTEAD of the standard click. A gunshot on a bullet or a
# thud on a punch is most of what makes an authored item feel like the thing it is named after, and the
# click is generic by design — layering both would only muddy it.
#
# Optional: an item without one keeps the click. Volume is stored alongside because an author's clip is
# whatever level it was recorded at, and the game cannot normalise it for them — which is also why it
# can be auditioned here. Setting a level by eye and finding out in a round is not a workflow.
func _add_item_sound_fields(body: VBoxContainer, item: Dictionary) -> void:
	body.add_child(_side_field_label("USE SOUND  (OPTIONAL)"))

	var zone: Control = load("res://scripts/journey_builder/DropZone.gd").new()
	zone.accepted_extensions = JourneyAudio.AUDIO_EXTENSIONS
	zone.picker_title = "Item use sound"
	if str(item.get("sound", "")) != "":
		zone.call_deferred("set_file", str(item["sound"]), false)
	zone.file_dropped.connect(func(path: String) -> void: item["sound"] = path)
	body.add_child(zone)

	var readout: Label = _side_field_label(
		"VOLUME  %d%%" % roundi(float(item.get("sound_volume", 1.0)) * 100.0)
	)
	body.add_child(readout)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var volume: HSlider = HSlider.new()
	volume.min_value = 0.0
	volume.max_value = 1.0
	volume.step = 0.05
	volume.value = float(item.get("sound_volume", 1.0))
	volume.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	volume.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	volume.value_changed.connect(
		func(v: float) -> void:
			item["sound_volume"] = v
			readout.text = "VOLUME  %d%%" % roundi(v * 100.0)
	)
	row.add_child(volume)
	row.add_child(
		_make_audio_test_button(
			row,
			func() -> String: return str(item.get("sound", "")),
			func() -> float: return float(item.get("sound_volume", 1.0))
		)
	)
	body.add_child(row)


func _default_custom_item() -> Dictionary:
	# Name starts blank so an untouched item reads as incomplete and cancels silently when the author
	# adds one and immediately dismisses the modal (see _close_item_editor).
	return {
		"id": JourneyData.new_item_id(),
		"name": "",
		"description": "",
		"category": "modifier",
		"price": 30,
		"duration_ms": JourneyData.ITEM_DEFAULT_DURATION_MS,
		"effects": [],
		"sound": "",
		"sound_volume": 1.0,
	}


func _default_item_effect(kind: String) -> Dictionary:
	match kind:
		"scale":
			return {"kind": "scale", "factor": 1.0}
		"clamp":
			return {"kind": "clamp", "min": 0, "max": 100}
		"score_multiplier":
			return {"kind": "score_multiplier", "factor": 2.0}
		"score_add":
			return {"kind": "score_add", "amount": 250}  # points awarded the instant it is used
		"coin_jackpot":
			return {"kind": "coin_jackpot", "factor": 2.0}
		"coin_penalty":
			return {"kind": "coin_penalty", "factor": 0.5}  # fraction of the round's coins KEPT
		"toll":
			return {"kind": "toll", "amount": 40}  # coins deducted on use
		"interest":
			return {"kind": "interest", "pct": 0.25}  # fraction of balance granted on use
		"flag":
			return {"kind": "flag", "flag": ""}  # run flag set on use (gates forks)
		"counter":
			return {"kind": "counter", "counter": "", "delta": 1}  # counter change on use
		"hud_hide":
			return {"kind": "hud_hide"}  # timed Fog — no tuning
		_:
			# Sensory (visual/audio) effects carry a 0.1–1.0 intensity (mapped through the catalog's
			# imin/imax at runtime); a few are binary (Blinded/Silence) and carry no tuning.
			var sensory: Dictionary = JourneyData.sensory_entry_by_kind(kind)
			if not sensory.is_empty() and sensory.has("idef"):
				return {"kind": kind, "intensity": float(sensory["idef"])}
			return {"kind": kind}  # reverse / block / blackout / binary sensory — no tuning


# One-line description of a gameplay item-effect kind, shown as the dropdown tooltip. Sensory kinds
# use their SENSORY_CATALOG `desc` instead (set where the dropdown is built).
func _effect_kind_desc(kind: String) -> String:
	match kind:
		"scale":
			return "Scales stroke depth by a factor (×0.5 = shallower, ×2 = deeper)."
		"clamp":
			return "Restricts strokes to a min/max position range."
		"reverse":
			return "Inverts stroke direction (top ↔ bottom)."
		"block":
			return "Blocks output — the device holds position."
		"blackout":
			return "Hides the video; the device keeps playing in the dark."
		"score_multiplier":
			return "Multiplies the round's score."
		"score_add":
			return (
				"Adds score the instant it is used. In a boss round with a SCORE health bar that is "
				+ "damage — scaled by her stance, so it glances off a guard and does nothing through "
				+ "an attack. Elsewhere it is simply points."
			)
		"coin_jackpot":
			return "Multiplies the round's coin payout. Settled at the next round end."
		"coin_penalty":
			return "Reduces the round's coin payout (fraction kept). Settled at the next round end."
		"toll":
			return "Deducts coins from the balance immediately when used (capped at the balance)."
		"interest":
			return "Grants coins equal to a fraction of the current balance, immediately when used."
		"flag":
			return "Sets a run flag when used — a later fork can branch on it (Conditional / required)."
		"counter":
			return "Changes a run counter when used (± delta) — feeds counter-gated forks and the HUD."
		"hud_hide":
			return "Fog — hides the HUD for the item's duration."
	return ""


# Short display label for a gameplay item-effect kind (dropdown option + row tag). Defaults to the
# kind capitalized; a few read better with a custom label.
func _item_effect_label(kind: String) -> String:
	match kind:
		"hud_hide":
			return "Fog (hide HUD)"
		"flag":
			return "Set flag"
		"counter":
			return "Change counter"
		"toll":
			return "Toll (lose coins)"
		"interest":
			return "Interest (gain coins)"
	return kind.capitalize()


# Compact list row for one custom item: name + type badge, with EDIT (opens the editor
# modal) and DELETE. The full field set lives in _open_item_editor_modal so the journey
# panel stays short no matter how many items a journey defines.
func _make_custom_item_row(item_idx: int) -> Control:
	var item: Dictionary = _owner._journey_items[item_idx]
	var category: String = str(item.get("category", "modifier"))

	var card: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL_BG
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	card.add_theme_stylebox_override("panel", style)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	card.add_child(row)

	var info: VBoxContainer = VBoxContainer.new()
	info.add_theme_constant_override("separation", 1)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	var name_lbl: Label = Label.new()
	var item_name: String = str(item.get("name", "")).strip_edges()
	name_lbl.text = item_name if item_name != "" else "(unnamed)"
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", 12)
	info.add_child(name_lbl)

	var badge: Label = Label.new()
	var fx_count: int = (item.get("effects", []) as Array).size()
	var fx_suffix: String = (
		(" · %d effect%s" % [fx_count, "" if fx_count == 1 else "s"]) if fx_count > 0 else ""
	)
	var badge_color: Color = UITheme.PURPLE_BRIGHT
	match category:
		"key":
			badge.text = "KEY"
			badge_color = UITheme.CYAN
		"override":
			badge.text = "OVERRIDE" + fx_suffix
			badge_color = UITheme.TOXIC_GREEN
		_:
			badge.text = "MODIFIER · %d effect%s" % [fx_count, "" if fx_count == 1 else "s"]
	badge.add_theme_color_override("font_color", badge_color)
	badge.add_theme_font_size_override("font_size", 10)
	info.add_child(badge)

	var edit_btn: Button = Button.new()
	edit_btn.text = "✎ EDIT"
	UITheme.style_button(edit_btn, UITheme.PURPLE_MID)
	edit_btn.pressed.connect(func() -> void: _open_item_editor_modal(item_idx))
	row.add_child(edit_btn)

	var del_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	del_btn.pressed.connect(
		func() -> void:
			_owner._journey_items.remove_at(item_idx)
			_rebuild_custom_items_list()
	)
	row.add_child(del_btn)
	return card


# Full editor for one custom item, in a centered modal. Everything mutates the live item
# dict in _owner._journey_items (mutate-in-place, like the rest of the builder — there is
# no cancel path). Closing re-renders the side list so the row's name/badge reflect edits.
func _open_item_editor_modal(item_idx: int, is_new: bool = false) -> void:
	if item_idx < 0 or item_idx >= _owner._journey_items.size():
		return
	var item: Dictionary = _owner._journey_items[item_idx]

	# Fill most of the window so the override timeline has room to show real script detail; a modifier/key
	# just leaves the extra space unused. Capped so it doesn't get absurd on very large monitors.
	var vp: Vector2 = _owner.get_viewport_rect().size
	var modal_size: Vector2i = Vector2i(mini(1400, int(vp.x * 0.94)), mini(980, int(vp.y * 0.92)))
	var parts: Dictionary = UITheme.build_centered_modal(
		"CUSTOM ITEM", UITheme.PURPLE_BRIGHT, modal_size
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	_owner.add_child(modal)

	# Fields scroll so a long effect bundle can't push DONE off the panel.
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	_fill_item_editor_body(body, item)

	var close_btn: Button = Button.new()
	close_btn.text = "DONE"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(close_btn, UITheme.PURPLE_BRIGHT)
	close_btn.pressed.connect(func() -> void: _close_item_editor(modal, item_idx, item, is_new))
	vbox.add_child(close_btn)

	# Backdrop click also dismisses (the backdrop is the modal's first child).
	var backdrop: Control = modal.get_child(0) as Control
	if backdrop:
		backdrop.gui_input.connect(
			func(event: InputEvent) -> void:
				if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
					_close_item_editor(modal, item_idx, item, is_new)
		)


# Closes the item editor, then frees the modal and re-renders the list. A NEWLY-ADDED item that is
# still incomplete is discarded — so clicking ＋ ADD ITEM and then dismissing an untouched item leaves
# nothing behind. Editing an EXISTING item never deletes it, even if edited to be incomplete. Complete
# = has a name, and (unless it is a key, which needs none) at least one effect.
func _close_item_editor(modal: Control, item_idx: int, item: Dictionary, is_new: bool) -> void:
	if is_new and not _journey_item_complete(item):
		var nm: String = str(item.get("name", "")).strip_edges()
		var is_override: bool = str(item.get("category", "modifier")) == "override"
		var has_effects: bool = not (item.get("effects", []) as Array).is_empty()
		var has_script: bool = str((item.get("scripts", {}) as Dictionary).get("main", "")) != ""
		_discard_journey_item(item_idx, item)
		# A bare Add-then-dismiss (nothing filled in) is a silent cancel. If the author put in SOME
		# content but it's still not keepable, say why it vanished rather than dropping it silently.
		if nm != "" or has_effects or has_script:
			var reason: String
			if nm == "":
				reason = "items need a name"
			elif is_override:
				reason = "an override needs a main funscript"
			else:
				reason = "a modifier needs at least one effect"
			_owner._show_status("Discarded incomplete item — %s." % reason, true)
	modal.queue_free()
	_rebuild_custom_items_list()


# An item is complete enough to keep: it has a name, plus whatever its type needs to function — a key
# needs nothing more, an override needs a main funscript, a modifier needs at least one effect.
func _journey_item_complete(item: Dictionary) -> bool:
	if str(item.get("name", "")).strip_edges() == "":
		return false
	match str(item.get("category", "modifier")):
		"key":
			return true
		"override":
			return str((item.get("scripts", {}) as Dictionary).get("main", "")) != ""
		_:
			return not (item.get("effects", []) as Array).is_empty()


# Removes an item from the journey list, preferring the captured index but verifying identity (the
# array can't shift while the modal is up, but be safe), falling back to an identity search.
func _discard_journey_item(item_idx: int, item: Dictionary) -> void:
	var items: Array = _owner._journey_items
	if item_idx >= 0 and item_idx < items.size() and is_same(items[item_idx], item):
		items.remove_at(item_idx)
		return
	for i: int in items.size():
		if is_same(items[i], item):
			items.remove_at(i)
			return


# ── Cast roster (journey-level storyboard characters) ───────────────────────
# Same shape as the custom-items section: a short list of rows in the journey panel, each character's
# full field set (name / portrait / default side) living in a modal. Characters mutate
# _owner._journey_characters in place; a storyboard line's stage references them by id.
func _make_characters_section() -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var header: Label = Label.new()
	header.text = "CAST"
	header.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	header.add_theme_font_size_override("font_size", 13)
	box.add_child(header)
	var hint: Label = Label.new()
	hint.text = (
		"Characters for storyboards: define a portrait once, then pick it per line. "
		+ "Portraits show ~half-screen over the background; two can share the stage (left + right)."
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 11)
	box.add_child(hint)

	var list: VBoxContainer = VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	box.add_child(list)
	_characters_list = list
	_rebuild_characters_list()

	var add_btn: Button = Button.new()
	add_btn.text = "＋ ADD CHARACTER"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(
		func() -> void:
			_owner._journey_characters.append(_default_character())
			_rebuild_characters_list()
			_open_character_editor_modal(_owner._journey_characters.size() - 1, true)
	)
	box.add_child(add_btn)
	return box


func _rebuild_characters_list() -> void:
	if not is_instance_valid(_characters_list):
		return
	for c: Node in _characters_list.get_children():
		c.queue_free()
	for i: int in _owner._journey_characters.size():
		_characters_list.add_child(_make_character_row(i))


func _default_character() -> Dictionary:
	# Blank name → reads as incomplete, cancels silently on dismiss. Starts with the three seeded
	# positions (draggable per character) and no portraits yet.
	return {
		"id": JourneyData.new_character_id(),
		"name": "",
		"portraits": [],
		"placements": JourneyData.default_character_placements(),
	}


# Compact row: name + default-side badge, with EDIT (opens the modal) and DELETE.
func _make_character_row(char_idx: int) -> Control:
	var chr: Dictionary = _owner._journey_characters[char_idx]

	var card: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL_BG
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	card.add_theme_stylebox_override("panel", style)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	card.add_child(row)

	var info: VBoxContainer = VBoxContainer.new()
	info.add_theme_constant_override("separation", 1)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	var name_lbl: Label = Label.new()
	var cname: String = str(chr.get("name", "")).strip_edges()
	name_lbl.text = cname if cname != "" else "(unnamed)"
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", 12)
	info.add_child(name_lbl)

	var badge: Label = Label.new()
	var n_portraits: int = (chr.get("portraits", []) as Array).size()
	badge.text = "%d portrait%s" % [n_portraits, "" if n_portraits == 1 else "s"]
	badge.add_theme_color_override(
		"font_color", UITheme.PURPLE_BRIGHT if n_portraits > 0 else UITheme.SEPARATOR
	)
	badge.add_theme_font_size_override("font_size", 10)
	info.add_child(badge)

	var edit_btn: Button = Button.new()
	edit_btn.text = "✎ EDIT"
	UITheme.style_button(edit_btn, UITheme.PURPLE_MID)
	edit_btn.pressed.connect(func() -> void: _open_character_editor_modal(char_idx))
	row.add_child(edit_btn)

	var del_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	del_btn.pressed.connect(
		func() -> void:
			_owner._journey_characters.remove_at(char_idx)
			_rebuild_characters_list()
	)
	row.add_child(del_btn)
	return card


# Full editor for one character in a centered modal: name, their POSITIONS (opens the drag/resize
# preview), and their PORTRAITS (expressions; first = default). Mutates the live dict in place; the
# body refills on a structural change (add/remove portrait). Closing re-renders the row.
func _open_character_editor_modal(char_idx: int, is_new: bool = false) -> void:
	if char_idx < 0 or char_idx >= _owner._journey_characters.size():
		return
	var chr: Dictionary = _owner._journey_characters[char_idx]

	var portraits: int = (chr.get("portraits", []) as Array).size()
	var parts: Dictionary = UITheme.build_centered_modal(
		"CHARACTER",
		UITheme.PURPLE_BRIGHT,
		Vector2i(
			520, clampi(ITEMS_MODAL_CHROME + portraits * ITEMS_MODAL_ROW, 380, ITEMS_MODAL_MAX)
		)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	_owner.add_child(modal)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	_fill_character_editor_body(body, chr)

	var close_btn: Button = Button.new()
	close_btn.text = "DONE"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(close_btn, UITheme.PURPLE_BRIGHT)
	close_btn.pressed.connect(func() -> void: _close_character_editor(modal, char_idx, chr, is_new))
	vbox.add_child(close_btn)

	var backdrop: Control = modal.get_child(0) as Control
	if backdrop:
		backdrop.gui_input.connect(
			func(event: InputEvent) -> void:
				if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
					_close_character_editor(modal, char_idx, chr, is_new)
		)


func _fill_character_editor_body(body: VBoxContainer, chr: Dictionary) -> void:
	var rebuild: Callable = func() -> void: _fill_character_editor_body(body, chr)
	for c: Node in body.get_children():
		c.queue_free()

	body.add_child(_side_field_label("NAME  (match a line's speaker to light this character)"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(chr.get("name", ""))
	name_edit.placeholder_text = "Character name..."
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: chr["name"] = v)
	body.add_child(name_edit)

	body.add_child(_side_divider_line())
	body.add_child(
		_side_field_label("POSITIONS  (where this character can stand, tuned to their art)")
	)
	var pos_btn: Button = Button.new()
	pos_btn.text = "✎ EDIT POSITIONS ON A PREVIEW"
	pos_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(pos_btn, UITheme.PURPLE_MID)
	pos_btn.pressed.connect(func() -> void: _open_character_placement_editor(chr))
	body.add_child(pos_btn)

	body.add_child(_side_divider_line())
	body.add_child(_side_field_label("PORTRAITS  (expressions; first is the default)"))
	var portraits: Array = chr.get("portraits", [])
	for i: int in portraits.size():
		body.add_child(_make_portrait_row(chr, i, rebuild))
	var add_btn: Button = Button.new()
	add_btn.text = "＋ ADD PORTRAIT"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(
		func() -> void:
			(chr["portraits"] as Array).append(
				{"id": JourneyData.new_portrait_id(), "name": "", "path": ""}
			)
			rebuild.call()
	)
	body.add_child(add_btn)


# One portrait (expression) row: a name, a drop-zone for the image (still or animated), and remove.
func _make_portrait_row(chr: Dictionary, idx: int, rebuild: Callable) -> Control:
	var por: Dictionary = (chr["portraits"] as Array)[idx]
	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.set_corner_radius_all(UITheme.CORNER_RADIUS)
	ps.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", ps)
	var col: VBoxContainer = panel_col(panel)

	var hdr: HBoxContainer = HBoxContainer.new()
	var tag: Label = Label.new()
	tag.text = "PORTRAIT %d%s" % [idx + 1, "  ·  DEFAULT" if idx == 0 else ""]
	tag.add_theme_color_override("font_color", UITheme.STORYBOARD)
	tag.add_theme_font_size_override("font_size", 10)
	tag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(tag)
	var rm: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	rm.pressed.connect(
		func() -> void:
			_delete_saved_image(str((chr["portraits"] as Array)[idx].get("path", "")))
			(chr["portraits"] as Array).remove_at(idx)
			rebuild.call()
	)
	hdr.add_child(rm)
	col.add_child(hdr)

	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(por.get("name", ""))
	name_edit.placeholder_text = "Expression name (e.g. Happy)..."
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: por["name"] = v)
	col.add_child(name_edit)

	var zone: PanelContainer = DropZoneScript.new()
	zone.accepted_extensions = JourneyData.ANIMATED_IMAGE_EXTENSIONS.duplicate()
	zone.picker_title = "Select Portrait Image"
	zone.picker_filters = [
		"*.png,*.jpg,*.jpeg,*.webp,*.gif,*.apng,*.mp4,*.m4v,*.webm,*.mkv,*.mov ; Portrait (image or animation)"
	]
	zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(zone)
	if str(por.get("path", "")) != "":
		zone.call_deferred("set_file", str(por.get("path", "")))
	zone.file_dropped.connect(func(p: String) -> void: por["path"] = p)
	return panel


# Opens the visual placement editor scoped to ONE character — editing THEIR positions against THEIR
# own portraits, so the boxes are sized to that character's art.
func _open_character_placement_editor(chr: Dictionary) -> void:
	var samples: Array = []
	for por: Variant in chr.get("portraits", []):
		if por is Dictionary and str((por as Dictionary).get("path", "")) != "":
			samples.append(str((por as Dictionary).get("path", "")))
	var editor: PlacementEditor = PlacementEditor.new()
	_owner.add_child(editor)
	editor.setup(chr.get("placements", []), samples)
	editor.done.connect(func(placements: Array) -> void: chr["placements"] = placements)


# A NEWLY-ADDED character with no name is discarded on close (Add-then-dismiss = silent cancel), same
# as the item editor. A named character is kept even without portraits — the author clearly meant it.
func _close_character_editor(modal: Control, char_idx: int, chr: Dictionary, is_new: bool) -> void:
	if is_new and str(chr.get("name", "")).strip_edges() == "":
		var chars: Array = _owner._journey_characters
		if char_idx >= 0 and char_idx < chars.size() and is_same(chars[char_idx], chr):
			chars.remove_at(char_idx)
		else:
			for i: int in chars.size():
				if is_same(chars[i], chr):
					chars.remove_at(i)
					break
	modal.queue_free()
	_rebuild_characters_list()


# A VBox filling a PanelContainer (helper for the compact card rows above).
func panel_col(panel: PanelContainer) -> VBoxContainer:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	panel.add_child(col)
	return col


# Fills the item-editor modal body with the item's fields. Structural changes (type
# switch, add/remove effect) refill the body in place via a fresh `rebuild` Callable —
# built here rather than passed in so it can't capture a not-yet-assigned local.
func _fill_item_editor_body(body: VBoxContainer, item: Dictionary) -> void:
	var rebuild: Callable = func() -> void: _fill_item_editor_body(body, item)
	for c: Node in body.get_children():
		c.queue_free()

	body.add_child(_side_field_label("NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(item.get("name", ""))
	name_edit.placeholder_text = "Item name..."
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: item["name"] = v)
	body.add_child(name_edit)

	body.add_child(_side_field_label("DESCRIPTION"))
	var desc_edit: LineEdit = LineEdit.new()
	desc_edit.text = str(item.get("description", ""))
	UITheme.style_line_edit(desc_edit)
	desc_edit.text_changed.connect(func(v: String) -> void: item["description"] = v)
	body.add_child(desc_edit)

	_add_item_sound_fields(body, item)

	body.add_child(_side_field_label("TYPE"))
	var type_dd: OptionButton = OptionButton.new()
	type_dd.add_item("Modifier (effect bundle)")  # 0
	type_dd.add_item("Key (fork gate)")  # 1
	type_dd.add_item("Override (funscript takeover)")  # 2
	type_dd.selected = ({"modifier": 0, "key": 1, "override": 2}).get(
		str(item.get("category", "modifier")), 0
	)
	type_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(type_dd)
	type_dd.item_selected.connect(
		func(i: int) -> void:
			item["category"] = ["modifier", "key", "override"][clampi(i, 0, 2)]
			if item["category"] == "modifier":
				if not item.has("effects"):
					item["effects"] = []
				if not item.has("duration_ms"):
					item["duration_ms"] = JourneyData.ITEM_DEFAULT_DURATION_MS
			elif item["category"] == "override":
				if not item.has("scripts"):
					item["scripts"] = {"main": "", "axes": {}, "vibes": {}}
				if not item.has("immune_to_effects"):
					item["immune_to_effects"] = true
			rebuild.call()
	)
	body.add_child(type_dd)

	body.add_child(_side_field_label("PRICE (♦)"))
	var price_spin: SpinBox = SpinBox.new()
	price_spin.min_value = 0
	price_spin.max_value = 9999
	price_spin.value = int(item.get("price", 0))
	UITheme.style_spin_box(price_spin)
	price_spin.value_changed.connect(func(v: float) -> void: item["price"] = int(v))
	body.add_child(price_spin)

	if str(item.get("category", "modifier")) == "modifier":
		body.add_child(_side_field_label("DURATION (SECONDS)"))
		var dur_spin: SpinBox = SpinBox.new()
		dur_spin.min_value = 1
		dur_spin.max_value = 600
		dur_spin.value = maxi(
			1, int(item.get("duration_ms", JourneyData.ITEM_DEFAULT_DURATION_MS)) / 1000
		)
		UITheme.style_spin_box(dur_spin)
		dur_spin.value_changed.connect(func(v: float) -> void: item["duration_ms"] = int(v) * 1000)
		body.add_child(dur_spin)

		_fill_item_effects_editor(body, item, rebuild, "EFFECTS")

	if str(item.get("category", "modifier")) == "override":
		_fill_item_override_section(body, item, rebuild)

	body.add_child(_side_field_label("ITEM IMAGE (OPTIONAL)"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions = ["png", "jpg", "jpeg", "webp"]
	img_zone.picker_title = "Select Item Image"
	img_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(img_zone)
	if str(item.get("image", "")) != "":
		img_zone.call_deferred("set_file", item["image"])
	var img_rm: Button = Button.new()
	img_rm.text = "✕ REMOVE IMAGE"
	img_rm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	img_rm.visible = str(item.get("image", "")) != ""
	UITheme.style_button(img_rm, UITheme.MAGENTA)
	img_rm.pressed.connect(
		func() -> void:
			item["image"] = ""
			img_zone.call_deferred("set_file", "")
			img_rm.visible = false
	)
	img_zone.file_dropped.connect(
		func(p: String) -> void:
			item["image"] = p
			img_rm.visible = p != ""
	)
	body.add_child(img_rm)


# The shared EFFECTS bundle editor (existing rows + an add dropdown). Used by modifier items and — so a
# custom override can pack a punch beyond the stroke — by override items too. `label` heads the section.
func _fill_item_effects_editor(
	body: VBoxContainer,
	item: Dictionary,
	rebuild: Callable,
	label: String,
	on_tune: Callable = Callable()
) -> void:
	if not item.has("effects"):
		item["effects"] = []
	body.add_child(_side_field_label(label))
	var effects: Array = item.get("effects", [])
	for ei: int in effects.size():
		body.add_child(_make_item_effect_row(item, ei, rebuild, on_tune))
	# The dropdown lists gameplay/stroke/coin kinds, then a separator, then the full sensory (visual/audio)
	# catalog by display name. `fx_kinds` is kept parallel to every row (including the placeholder and
	# separator, which occupy indices) so item_selected maps back to a kind.
	var add_fx: OptionButton = OptionButton.new()
	var fx_kinds: Array = [""]  # index 0 = placeholder
	add_fx.add_item("＋ Add effect…")
	for kind: String in _ITEM_EFFECT_KINDS:
		add_fx.add_item(_item_effect_label(kind))
		add_fx.set_item_tooltip(
			add_fx.get_item_count() - 1, UITheme.wrap_tip(_effect_kind_desc(kind))
		)
		fx_kinds.append(kind)
	add_fx.add_separator("SENSORY (VISUAL / AUDIO)")
	fx_kinds.append("")  # the separator occupies an index but isn't selectable
	for e: Dictionary in JourneyData.SENSORY_CATALOG:
		var skind: String = str(e.get("kind", ""))
		if skind in _ITEM_EFFECT_KINDS:
			continue  # "blackout" (Blinded) is already offered as a gameplay kind — no duplicate
		add_fx.add_item(str(e.get("name", skind)))
		add_fx.set_item_tooltip(
			add_fx.get_item_count() - 1, UITheme.wrap_tip(str(e.get("desc", "")))
		)
		fx_kinds.append(skind)
	add_fx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(add_fx)
	add_fx.item_selected.connect(
		func(i: int) -> void:
			if i <= 0 or i >= fx_kinds.size() or str(fx_kinds[i]) == "":
				return
			(item["effects"] as Array).append(_default_item_effect(str(fx_kinds[i])))
			rebuild.call()
	)
	body.add_child(add_fx)


# ── Override item authoring (see OVERRIDE_ITEMS_DESIGN.md §7) ─────────────────
# An override item plays a bundled funscript over the round when used. The author drops a MAIN stroke
# funscript; sibling axis (.L1/.R1/…) and vib (.vib1/.vib2) files next to it are paired automatically,
# mirroring the round importer. A small curve preview + a read-back (duration + channels) shows what
# was imported, and a toggle sets whether it plays raw (immune to active effects/curses) or not.
func _fill_item_override_section(body: VBoxContainer, item: Dictionary, rebuild: Callable) -> void:
	var scripts: Dictionary = item.get("scripts", {})
	var main_path: String = str(scripts.get("main", ""))

	body.add_child(_side_field_label("MAIN FUNSCRIPT"))
	var main_zone: PanelContainer = DropZoneScript.new()
	main_zone.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
	main_zone.picker_title = "Select Override Funscript"
	main_zone.picker_filters = ["*.funscript ; Funscript"]
	main_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(main_zone)
	if main_path != "":
		# Display only — pass emit=false so restoring the path on a rebuild doesn't re-fire file_dropped,
		# which would call rebuild again → set_file → file_dropped → … an infinite loop that crashes.
		main_zone.call_deferred("set_file", main_path, false)
	main_zone.file_dropped.connect(
		func(p: String) -> void:
			_set_override_main(item, p)
			rebuild.call()
	)

	var refresh_preview: Callable = Callable()  # re-applies the effect preview to the stroke, view-preserving
	if main_path != "":
		refresh_preview = _fill_override_timeline(body, item, scripts)
		var clear_btn: Button = Button.new()
		clear_btn.text = "✕ CLEAR BUNDLE"
		clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(clear_btn, UITheme.MAGENTA)
		clear_btn.pressed.connect(
			func() -> void:
				item["scripts"] = {"main": "", "axes": {}, "vibes": {}}
				item["duration_ms"] = 0
				item.erase("trim")
				rebuild.call()
		)
		body.add_child(clear_btn)
	else:
		(
			body
			. add_child(
				_side_hint(
					"Drop a .funscript. Sibling axis (.L1/.R1/…) and vib (.vib1/.vib2) files next to it are added automatically."
				)
			)
		)

	body.add_child(_side_section_separator())
	var immune_chk: CheckBox = CheckBox.new()
	immune_chk.text = "Ignore active effects / curses (play raw)"
	immune_chk.button_pressed = bool(item.get("immune_to_effects", true))
	immune_chk.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	# Refresh the preview on toggle — a stroke effect only shows on the stroke when it won't play raw.
	immune_chk.toggled.connect(
		func(on: bool) -> void:
			item["immune_to_effects"] = on
			if refresh_preview.is_valid():
				refresh_preview.call()
	)
	body.add_child(immune_chk)

	# An override can ALSO carry an effects bundle (score / sensory / modifier), applied while it plays.
	# `refresh_preview` (on_tune) repaints the stroke preview live as a stroke effect is tuned.
	body.add_child(_side_section_separator())
	_fill_item_effects_editor(
		body, item, rebuild, "EFFECTS  (OPTIONAL — APPLIED WHILE IT PLAYS)", refresh_preview
	)


# Sets the override's MAIN funscript and auto-pairs sibling axis/vib scripts by filename (like the round
# importer). Stores the derived bundle duration for shop display (the runtime recomputes it exactly).
func _set_override_main(item: Dictionary, path: String) -> void:
	var scripts: Dictionary = {"main": path, "axes": {}, "vibes": {}}
	var siblings: Dictionary = ImportScanner.find_sibling_scripts(
		path.get_base_dir(), ImportScanner.strip_script_suffix(path)
	)
	for axis_name: Variant in siblings.get("axis", {}):
		scripts["axes"][str(axis_name)] = str(siblings["axis"][axis_name])
	for vib_name: Variant in siblings.get("vib", {}):
		scripts["vibes"][0 if str(vib_name) == "vib1" else 1] = str(siblings["vib"][vib_name])
	item["scripts"] = scripts
	item.erase("trim")  # a freshly dropped script starts untrimmed
	item["duration_ms"] = _override_bundle_duration_ms(scripts)


# The override authoring timeline: a wide, seekable curve of every channel with draggable IN/OUT handles
# and exact Start/End fields (two-way synced), so a favourite script can be sliced to a section by feel or
# by number. Edits write the window straight onto the item — no panel rebuild, so focus/scroll hold.
# Returns a `refresh_preview` Callable: the effects editor / immune toggle call it to re-apply the effect
# preview to the main stroke in place (no panel rebuild, so zoom/window hold). Empty Callable if no script.
func _fill_override_timeline(
	body: VBoxContainer, item: Dictionary, scripts: Dictionary
) -> Callable:
	var full_ms: int = _override_bundle_duration_ms(scripts)  # untrimmed length bounds the window
	if full_ms <= 0:
		body.add_child(_side_hint("Couldn't read the funscript."))
		return Callable()
	var trim: Dictionary = item.get("trim", {})
	var in_ms0: int = clampi(int(trim.get("in_ms", 0)), 0, full_ms)
	var out_raw: int = int(trim.get("out_ms", 0))
	var out_ms0: int = out_raw if out_raw > 0 else full_ms

	var timeline: OverrideTimeline = OverrideTimeline.new()
	# A comfortable slice of the window height — tall enough to read, not so tall the stroke looks stretched.
	timeline.custom_minimum_size = Vector2(
		0, clampi(int(_owner.get_viewport_rect().size.y * 0.36), 240, 460)
	)
	var main_raw: Array = JourneyData.read_funscript_actions(str(scripts.get("main", "")))
	# When it won't play raw AND carries a stroke effect (scale/clamp/reverse/block), preview the TRANSFORMED
	# stroke — the same transform the device runs — with the raw stroke ghosted under it, so the author sees
	# what it will actually feel like. Reads item state live so tuning/immune changes refresh it.
	var refresh_preview: Callable = func() -> void:
		var immune: bool = bool(item.get("immune_to_effects", true))
		if not immune and _has_stroke_effect(item.get("effects", [])):
			timeline.set_main(
				_apply_stroke_effects_preview(main_raw, item.get("effects", [])),
				"MAIN + EFFECTS",
				main_raw
			)
		else:
			timeline.set_main(main_raw, "MAIN", [])
	timeline.setup(main_raw, _override_lane_data(scripts), full_ms, in_ms0, out_ms0)
	refresh_preview.call()  # apply the effect preview to the main stroke if applicable
	body.add_child(timeline)

	# A pan scrollbar under the timeline, two-way synced with its zoom/pan view. `page` = the visible span,
	# so its thumb shows how much of the clip is on screen; it fills (no scroll) at full zoom.
	var hscroll: HScrollBar = HScrollBar.new()
	hscroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hscroll.min_value = 0
	hscroll.max_value = full_ms
	hscroll.page = full_ms
	hscroll.value = 0
	body.add_child(hscroll)
	var view_syncing: Array = [false]
	timeline.view_changed.connect(
		func(start_ms: int, span_ms: int) -> void:
			view_syncing[0] = true
			hscroll.page = span_ms
			hscroll.value = start_ms
			view_syncing[0] = false
	)
	hscroll.value_changed.connect(
		func(v: float) -> void:
			if not view_syncing[0]:
				timeline.set_view_start(int(v))
	)

	var summary: Label = _side_hint(_override_window_summary(scripts, in_ms0, out_ms0))

	body.add_child(_side_field_label("TRIM  (SECONDS — DRAG THE HANDLES OR TYPE)"))
	var full_s: float = full_ms / 1000.0
	var start_spin: SpinBox = _make_trim_spin("Start ", full_s, in_ms0 / 1000.0)
	var end_spin: SpinBox = _make_trim_spin("End ", full_s, out_ms0 / 1000.0)
	# Guards the field↔handle mirror so a programmatic value set doesn't loop back into the timeline.
	var syncing: Array = [false]
	var refresh_summary: Callable = func() -> void:
		summary.text = _override_window_summary(
			scripts, timeline.get_in_ms(), timeline.get_out_ms()
		)

	timeline.trim_changed.connect(
		func(in_ms: int, out_ms: int) -> void:
			_set_override_trim_ms(item, in_ms, out_ms, full_ms)
			syncing[0] = true
			start_spin.value = in_ms / 1000.0
			end_spin.value = out_ms / 1000.0
			syncing[0] = false
			refresh_summary.call()
	)
	var on_field: Callable = func(_v: float) -> void:
		if syncing[0]:
			return
		var typed_in: int = clampi(roundi(start_spin.value * 1000.0), 0, full_ms)
		var typed_out: int = clampi(roundi(end_spin.value * 1000.0), 0, full_ms)
		if typed_out <= typed_in:
			typed_out = full_ms
		timeline.set_window(typed_in, typed_out)
		_set_override_trim_ms(item, timeline.get_in_ms(), timeline.get_out_ms(), full_ms)
		refresh_summary.call()
	start_spin.value_changed.connect(on_field)
	end_spin.value_changed.connect(on_field)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(start_spin)
	row.add_child(end_spin)
	body.add_child(row)
	body.add_child(summary)

	# Test on device: play the current slice on the connected device (serial / Buttplug / Handy) so the
	# author can feel it. The player lives under the timeline, so closing the editor or rebuilding it stops
	# the device automatically. The playhead sweeps the lit window while it plays.
	var test_player: OverrideTestPlayer = OverrideTestPlayer.new()
	timeline.add_child(test_player)
	var test_btn: Button = Button.new()
	test_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(test_btn, UITheme.CYAN)
	var set_test_label: Callable = func(playing: bool) -> void:
		test_btn.text = "■ STOP TEST" if playing else "▶ TEST ON DEVICE"
	set_test_label.call(false)
	test_player.state_changed.connect(set_test_label)
	test_btn.pressed.connect(
		func() -> void:
			if test_player.is_playing():
				test_player.stop()
			else:
				test_player.start(
					_build_override_test_bundle(item, scripts),
					timeline,
					int((item.get("trim", {}) as Dictionary).get("in_ms", 0))
				)
	)
	body.add_child(test_btn)
	return refresh_preview


# True if the bundle carries an effect that reshapes the stroke (vs. score / sensory / coin, which don't).
func _has_stroke_effect(effects: Array) -> bool:
	for e: Variant in effects:
		if str((e as Dictionary).get("kind", "")) in ["scale", "clamp", "reverse", "block"]:
			return true
	return false


# The main stroke with its stroke effects baked in, for the editor preview. Reuses HandyPoints.apply_effects
# (the exact transform the device runs), so the preview matches playback; non-stroke kinds are ignored there.
func _apply_stroke_effects_preview(actions: Array, effects: Array) -> Array:
	var transformed: Array = HandyPoints.apply_effects(
		HandyPoints.actions_to_points(actions), effects
	)
	var out: Array = []
	for p: Dictionary in transformed:
		out.append(Vector2(int(p["t"]), int(p["x"])))
	return out


# Builds the bundle the device test-play streams: the trimmed slice on every channel, with stroke effects
# baked into the main (when not immune) so the device matches the on-screen preview. Play-time immunity is
# therefore always "raw" — the effects are already in the points.
func _build_override_test_bundle(item: Dictionary, scripts: Dictionary) -> OverrideBundle:
	var trim: Dictionary = item.get("trim", {})
	var main: Array = JourneyData.apply_override_trim(
		JourneyData.read_funscript_actions(str(scripts.get("main", ""))), trim
	)
	if (
		not bool(item.get("immune_to_effects", true))
		and _has_stroke_effect(item.get("effects", []))
	):
		main = _apply_stroke_effects_preview(main, item.get("effects", []))
	var axes: Dictionary = {}
	for axis_name: Variant in scripts.get("axes", {}):
		var a: Array = JourneyData.apply_override_trim(
			JourneyData.read_funscript_actions(str(scripts["axes"][axis_name])), trim
		)
		if not a.is_empty():
			axes[str(axis_name)] = a
	var vibes: Dictionary = {}
	for channel: Variant in scripts.get("vibes", {}):
		var v: Array = JourneyData.apply_override_trim(
			JourneyData.read_funscript_actions(str(scripts["vibes"][channel])), trim
		)
		if not v.is_empty():
			vibes[int(channel)] = v
	return OverrideBundle.from_channels(main, axes, vibes)


# Axis + vib channels as timeline lanes (name + points + colour). Empty channels are skipped.
func _override_lane_data(scripts: Dictionary) -> Array:
	var lanes: Array = []
	for axis_name: Variant in scripts.get("axes", {}):
		var apts: Array = JourneyData.read_funscript_actions(str(scripts["axes"][axis_name]))
		if not apts.is_empty():
			lanes.append({"name": str(axis_name), "points": apts, "color": UITheme.CYAN})
	for channel: Variant in scripts.get("vibes", {}):
		var vpts: Array = JourneyData.read_funscript_actions(str(scripts["vibes"][channel]))
		if not vpts.is_empty():
			lanes.append(
				{"name": "vib%d" % (int(channel) + 1), "points": vpts, "color": UITheme.MAGENTA}
			)
	return lanes


func _make_trim_spin(prefix: String, max_s: float, value_s: float) -> SpinBox:
	var s: SpinBox = SpinBox.new()
	s.min_value = 0.0
	s.max_value = max_s
	s.step = 0.1
	s.prefix = prefix
	s.suffix = "s"
	s.value = clampf(value_s, 0.0, max_s)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(s)
	return s


# Writes the trim window (ms) onto the item. Inverted/empty picks fall back to "to end"; a full-range pick
# clears the trim (an untrimmed override carries no window). duration_ms tracks the section length for shop
# display; the runtime recomputes it exactly from the trimmed bundle.
func _set_override_trim_ms(item: Dictionary, in_ms: int, out_ms: int, full_ms: int) -> void:
	in_ms = clampi(in_ms, 0, full_ms)
	out_ms = clampi(out_ms, 0, full_ms)
	if out_ms <= in_ms:
		out_ms = full_ms
	if in_ms <= 0 and out_ms >= full_ms:
		item.erase("trim")
		item["duration_ms"] = full_ms
		return
	item["trim"] = {"in_ms": in_ms, "out_ms": out_ms}
	item["duration_ms"] = maxi(0, out_ms - in_ms)


# Exact bundle length (ms) across every channel — reuses the runtime OverrideBundle so the editor and
# the device agree. Reads the files fresh and applies the trim window; 0 when the main is missing/empty.
func _override_bundle_duration_ms(scripts: Dictionary, trim: Dictionary = {}) -> int:
	var main: Array = JourneyData.apply_override_trim(
		JourneyData.read_funscript_actions(str(scripts.get("main", ""))), trim
	)
	var axes: Dictionary = {}
	for axis_name: Variant in scripts.get("axes", {}):
		axes[str(axis_name)] = JourneyData.apply_override_trim(
			JourneyData.read_funscript_actions(str(scripts["axes"][axis_name])), trim
		)
	var vibes: Dictionary = {}
	for channel: Variant in scripts.get("vibes", {}):
		vibes[int(channel)] = JourneyData.apply_override_trim(
			JourneyData.read_funscript_actions(str(scripts["vibes"][channel])), trim
		)
	return OverrideBundle.from_channels(main, axes, vibes).duration_ms


# Read-back for the override editor: window duration + which axis/vib channels it carries. Uses the window
# LENGTH rather than re-reading every funscript, so it's cheap to refresh live while a handle is dragged.
func _override_window_summary(scripts: Dictionary, in_ms: int, out_ms: int) -> String:
	var parts: Array = ["Duration ~%.1fs" % ((out_ms - in_ms) / 1000.0)]
	var axes: Dictionary = scripts.get("axes", {})
	if not axes.is_empty():
		parts.append("Axes: " + ", ".join(axes.keys()))
	var vibes: Dictionary = scripts.get("vibes", {})
	if not vibes.is_empty():
		var labels: Array = []
		for channel: Variant in vibes:
			labels.append("vib%d" % (int(channel) + 1))
		parts.append("Vibes: " + ", ".join(labels))
	return "  ·  ".join(parts)


# A small wrapped hint label under a field (dimmer + smaller than a section label).
func _side_hint(text: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return lbl


# One effect row in an item's bundle: kind label + magnitude field(s) + remove.
# `rebuild` refills the editor body after a removal; `on_tune` (optional) fires when a STROKE effect's
# magnitude changes, so the override editor can repaint its live stroke preview.
func _make_item_effect_row(
	item: Dictionary, fx_idx: int, rebuild: Callable, on_tune: Callable = Callable()
) -> Control:
	var fx: Dictionary = (item["effects"] as Array)[fx_idx]
	var kind: String = str(fx.get("kind", ""))
	var sensory: Dictionary = JourneyData.sensory_entry_by_kind(kind)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl: Label = Label.new()
	# Sensory effects show their catalog display name (Bleary, Muffled, …); gameplay kinds a short label.
	lbl.text = (
		str(sensory.get("name", kind)).to_upper()
		if not sensory.is_empty()
		else _item_effect_label(kind).to_upper()
	)
	lbl.custom_minimum_size = Vector2(64, 0)
	lbl.add_theme_color_override("font_color", UITheme.CYAN)
	lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(lbl)

	match kind:
		"scale":
			row.add_child(_make_factor_spin(fx, "factor", 0.1, 3.0, 0.05, "×", 1.0, on_tune))
		"score_multiplier":
			row.add_child(_make_factor_spin(fx, "factor", 1.0, 10.0, 0.25, "score ×", 2.0))
		"score_add":
			row.add_child(_make_int_spin(fx, "amount", 0, 1000000, "+", 250))
		"coin_jackpot":
			row.add_child(_make_factor_spin(fx, "factor", 1.0, 10.0, 0.25, "coin ×", 2.0))
		"coin_penalty":
			row.add_child(_make_factor_spin(fx, "factor", 0.0, 1.0, 0.05, "keep ", 0.5))
		"clamp":
			var mn: SpinBox = SpinBox.new()
			mn.min_value = 0
			mn.max_value = 100
			mn.prefix = "min "
			mn.value = int(fx.get("min", 0))
			mn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			UITheme.style_spin_box(mn)
			mn.value_changed.connect(
				func(v: float) -> void:
					fx["min"] = int(v)
					if on_tune.is_valid():
						on_tune.call()
			)
			row.add_child(mn)
			var mx: SpinBox = SpinBox.new()
			mx.min_value = 0
			mx.max_value = 100
			mx.prefix = "max "
			mx.value = int(fx.get("max", 100))
			mx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			UITheme.style_spin_box(mx)
			mx.value_changed.connect(
				func(v: float) -> void:
					fx["max"] = int(v)
					if on_tune.is_valid():
						on_tune.call()
			)
			row.add_child(mx)
		"toll":
			row.add_child(_make_int_spin(fx, "amount", 0, 9999, "lose ♦", 40))
		"interest":
			row.add_child(_make_factor_spin(fx, "pct", 0.0, 1.0, 0.05, "gain ", 0.25))
		"flag":
			row.add_child(_make_effect_line_edit(fx, "flag", "flag name…"))
		"counter":
			row.add_child(_make_effect_line_edit(fx, "counter", "counter name…"))
			row.add_child(_make_int_spin(fx, "delta", -999, 999, "Δ ", 1))
		_:
			if not sensory.is_empty() and sensory.has("idef"):
				# Sensory intensity 0.1–1.0 — mapped through the catalog's imin/imax at runtime.
				row.add_child(
					_make_factor_spin(
						fx,
						"intensity",
						0.1,
						1.0,
						0.05,
						"intensity ",
						float(sensory.get("idef", 0.5))
					)
				)
			else:
				var none: Label = Label.new()
				none.text = "(no tuning)"
				none.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				none.add_theme_color_override("font_color", UITheme.SEPARATOR)
				none.add_theme_font_size_override("font_size", 10)
				row.add_child(none)

	var rm: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	rm.pressed.connect(
		func() -> void:
			(item["effects"] as Array).remove_at(fx_idx)
			rebuild.call()
	)
	row.add_child(rm)
	return row


# Item ids offered in the journey's item dropdowns: BUILT-IN items + this journey's LIVE custom items.
# Uses GetBuiltinItemIds (not GetAllItemIds) so a test-play's leftover journey items in InventoryService
# don't get counted a second time on top of _owner._journey_items (the duplicate-in-dropdowns bug).
func _all_item_ids() -> Array:
	var ids: Array = []
	for k: String in InventoryService.GetBuiltinItemIds():
		ids.append(str(k))
	for it: Dictionary in _owner._journey_items:
		ids.append(str(it.get("id", "")))
	return ids


# Display name for an item id — this journey's LIVE custom items first (authoritative while editing),
# else the built-in registry. Journey items check first so a test-play's stale InventoryService copy
# never shadows the live name / "(custom)" tag.
func _item_display_name(id: String) -> String:
	for it: Dictionary in _owner._journey_items:
		if str(it.get("id", "")) == id:
			return "%s  (custom)" % str(it.get("name", id))
	var d: Dictionary = InventoryService.GetItemData(id)
	if not d.is_empty():
		return str(d.get("name", id))
	return id


# One float-parameter SpinBox for an effect (e.g. scale/score/coin factor), writing fx[key] live.
func _make_factor_spin(
	fx: Dictionary,
	key: String,
	lo: float,
	hi: float,
	step: float,
	prefix: String,
	default: float,
	on_change: Callable = Callable()
) -> SpinBox:
	var s: SpinBox = SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.prefix = prefix
	s.value = float(fx.get(key, default))
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(s)
	s.value_changed.connect(
		func(v: float) -> void:
			fx[key] = v
			if on_change.is_valid():
				on_change.call()
	)
	return s


# Whole-number SpinBox for an effect param (toll amount, counter delta), writing fx[key] live as int.
func _make_int_spin(
	fx: Dictionary, key: String, lo: int, hi: int, prefix: String, default: int
) -> SpinBox:
	var s: SpinBox = SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	s.prefix = prefix
	s.value = int(fx.get(key, default))
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(s)
	s.value_changed.connect(func(v: float) -> void: fx[key] = int(v))
	return s


# Text field for an effect param (flag / counter name), writing fx[key] live.
func _make_effect_line_edit(fx: Dictionary, key: String, placeholder: String) -> LineEdit:
	var le: LineEdit = LineEdit.new()
	le.placeholder_text = placeholder
	le.text = str(fx.get(key, ""))
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(le)
	le.text_changed.connect(func(v: String) -> void: fx[key] = v)
	return le


# Toggle chip for one journey tag. Filled with the tag's colour when on,
# faintly tinted when off. Mutates _owner._journey_tags directly.
func _make_tag_toggle(tag_def: Dictionary) -> Button:
	var id: String = tag_def["id"]
	var color: Color = tag_def["color"]

	var btn: Button = Button.new()
	btn.text = tag_def["label"]
	btn.toggle_mode = true
	btn.button_pressed = id in _owner._journey_tags
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 11)

	var off_style: StyleBoxFlat = StyleBoxFlat.new()
	off_style.bg_color = Color(color.r, color.g, color.b, 0.06)
	off_style.border_color = Color(color.r, color.g, color.b, 0.45)
	off_style.border_width_left = 1
	off_style.border_width_right = 1
	off_style.border_width_top = 1
	off_style.border_width_bottom = 1
	off_style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	off_style.content_margin_left = 11
	off_style.content_margin_right = 11
	off_style.content_margin_top = 5
	off_style.content_margin_bottom = 5

	var on_style: StyleBoxFlat = off_style.duplicate()
	on_style.bg_color = color
	on_style.border_color = color

	btn.add_theme_stylebox_override("normal", off_style)
	btn.add_theme_stylebox_override("hover", off_style)
	btn.add_theme_stylebox_override("pressed", on_style)
	btn.add_theme_stylebox_override("hover_pressed", on_style)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color", color)
	btn.add_theme_color_override("font_hover_color", color)
	btn.add_theme_color_override("font_pressed_color", UITheme.BG)
	btn.add_theme_color_override("font_hover_pressed_color", UITheme.BG)

	btn.toggled.connect(
		func(on_state: bool) -> void:
			if on_state:
				if id not in _owner._journey_tags:
					_owner._journey_tags.append(id)
			else:
				_owner._journey_tags.erase(id)
	)
	return btn


# Graph-editor: the "ADD NODE" button row (round/shop/storyboard/fork → _create_graph_node). Shown
# in both the journey-info panel and the node editor so creating a node is always reachable.
func _make_graph_add_buttons() -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_side_field_label("ADD NODE"))
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for spec: Array in [
		["▶ ROUND", "round", UITheme.PURPLE_MID],
		["◆ SHOP", "shop", UITheme.PURPLE_BRIGHT],
		["◈ STORY", "storyboard", UITheme.STORYBOARD],
		["⑂ FORK", "fork", UITheme.MAGENTA]
	]:
		var btn: Button = UITheme.make_icon_btn(spec[0], false, spec[2])
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var t: String = spec[1]
		btn.pressed.connect(func() -> void: _owner._create_graph_node(t))
		row.add_child(btn)
	box.add_child(row)
	return box


# Graph-editor (L1 slice 2b/3b): the editor for a selected GRAPH node. Reuses the per-type field
# editors by pointing them at node.data (arr = [node.data], idx = 0), so edits mutate the node in
# place. Forks edit their out-edges (slice 3c), so they show a placeholder for now. Topped with the
# add-node row and tailed with a delete button. Field edits reflect on the canvas on the next
# refresh (re-selecting a node, or a structural change).
func show_graph_node_editor(node_id: String) -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	# Leaving the journey-info panel to edit a node exits backdrop-reposition mode, so its drag-catcher
	# can never linger and block node editing (the toggles only live in the journey-info panel).
	if _owner._backdrop_reposition_idx >= 0:
		_owner._backdrop_reposition_idx = -1
		if is_instance_valid(_owner._graph):
			_owner._graph.set_backdrop_reposition(-1)
	_pool_drop = {}  # the panel is being rebuilt — drop the stale pool drop-zone registration
	for c in side_vbox.get_children():
		c.queue_free()
	var node: Dictionary = (_owner._graph_model.get("nodes", {}) as Dictionary).get(node_id, {})
	if node.is_empty():
		show_journey_info_panel()
		return
	# A ghosted base node during rendition authoring: the locked base can't be edited/tested/deleted, but a
	# FORK can take overlay choices and a ROUND can take channel overlays. Each opens its own limited editor
	# in place of the full node editor.
	if _owner._rendition_parent_ids.has(node_id):
		match str(node.get("type", "")):
			"fork":
				side_vbox.add_child(_make_rendition_fork_editor(node_id, node))
				return
			"round":
				side_vbox.add_child(_make_rendition_round_editor(node_id, node))
				return
	# Test From Here at the top — save + play the journey starting at this node (a synthetic
	# {node_id} item is all _save_and_test_from needs; the graph is node-id native).
	side_vbox.add_child(_make_test_controls({"node_id": node_id}, []))
	side_vbox.add_child(_side_divider_line())
	# ⚖ ON ARRIVAL — what the audit says the player has when reaching this node.
	side_vbox.add_child(_make_arrival_audit_block(node_id))
	side_vbox.add_child(_side_divider_line())
	var node_type: String = node.get("type", "round")
	if node_type == "fork":
		# Fork editing = out-edges as choices (3c-ii). reselect rebuilds the side panel after a
		# structural change (resolution toggle, add/remove choice) so per-choice fields match.
		var fork_reselect: Callable = func(_i: int) -> void:
			_owner._refresh_graph()
			show_graph_node_editor(node_id)
		side_vbox.add_child(_make_graph_fork_editor(node_id, node, fork_reselect))
	else:
		var data: Dictionary = node.get("data", {})
		var display: Dictionary = data.duplicate()  # gives _build_side_panel_editor a "type" to dispatch on
		display["type"] = node_type
		var arr: Array = [data]  # arr[0] IS node.data — editors mutate the node
		var reselect: Callable = func(_new_idx: int) -> void:
			_owner._refresh_graph()  # structural change → re-render the canvas
			show_graph_node_editor(node_id)
		_build_side_panel_editor(side_vbox, display, arr, 0, reselect)
		# Round nodes group SETS FLAGS / COUNTERS with Coins inside their editor (Rewards group); shop /
		# storyboard editors aren't grouped, so both are appended here. Loop markers are pure control nodes
		# (no rewards) and checkpoints carry their rewards in the ON-CONTINUE block instead — so only shop /
		# storyboard get the generic fields (elsewhere they'd be dead or duplicate the on-continue ones).
		if node_type == "shop" or node_type == "storyboard":
			side_vbox.add_child(_make_set_flags_field(data))
			side_vbox.add_child(_make_set_counters_field(data))
			side_vbox.add_child(_make_remove_items_field(data))
		# Divider between the content editor (round types / fields) and the node-operations block
		# (connect / duplicate / delete / add) below.
		side_vbox.add_child(_side_divider_line())
		# Edge wiring (slice 3c): connect this node's flow to a target, or disconnect (end here).
		var connecting: bool = _owner._connecting_from == node_id
		var conn_btn: Button = UITheme.make_icon_btn(
			"✕ CANCEL CONNECT" if connecting else "🔗 CONNECT TO…", false, UITheme.AMBER
		)
		conn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		conn_btn.pressed.connect(func() -> void: _owner._begin_connect(node_id))
		side_vbox.add_child(conn_btn)
		var node_out: Array = node.get("out", [])
		if not node_out.is_empty() and str((node_out[0] as Dictionary).get("to", "")) != "":
			var disc_btn: Button = UITheme.make_icon_btn(
				"✂ DISCONNECT (END HERE)", false, UITheme.PURPLE_MID
			)
			disc_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			disc_btn.pressed.connect(func() -> void: _owner._disconnect_graph_node(node_id))
			side_vbox.add_child(disc_btn)
	side_vbox.add_child(_side_section_separator())
	var dup_btn: Button = UITheme.make_icon_btn("⎘ DUPLICATE", false, UITheme.PURPLE_MID)
	dup_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dup_btn.pressed.connect(func() -> void: _owner._duplicate_selection())
	side_vbox.add_child(dup_btn)
	var del_btn: Button = UITheme.make_icon_btn("🗑 DELETE NODE", false, UITheme.ERROR_SOFT)
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(func() -> void: _owner._delete_graph_node(node_id))
	side_vbox.add_child(del_btn)

	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_make_graph_add_buttons())


# Graph editor: the side panel for a selected sticky-note comment — edit its text or delete it.
func show_comment_editor(idx: int) -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	for c in side_vbox.get_children():
		c.queue_free()
	var comments: Array = _owner._graph_model.get("comments", [])
	if idx < 0 or idx >= comments.size():
		show_journey_info_panel()
		return
	var hdr: Label = Label.new()
	hdr.text = "// NOTE //"
	hdr.add_theme_color_override("font_color", UITheme.AMBER)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_vbox.add_child(hdr)
	side_vbox.add_child(_side_field_label("TEXT"))
	var edit: TextEdit = TextEdit.new()
	edit.text = str((comments[idx] as Dictionary).get("text", ""))
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 140)
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(edit)
	edit.text_changed.connect(
		func() -> void:
			var cs: Array = _owner._graph_model.get("comments", [])
			if idx < cs.size():
				(cs[idx] as Dictionary)["text"] = edit.text
	)
	edit.focus_exited.connect(func() -> void: _owner._refresh_graph())
	side_vbox.add_child(edit)
	side_vbox.add_child(_side_field_label("COLOUR"))
	var swatch_row: HBoxContainer = HBoxContainer.new()
	swatch_row.add_theme_constant_override("separation", 6)
	for col: Color in [
		UITheme.AMBER, UITheme.CYAN, Color(0.45, 0.95, 0.30), UITheme.MAGENTA, UITheme.PURPLE_BRIGHT
	]:
		var sw: Button = Button.new()
		sw.custom_minimum_size = Vector2(30, 26)
		sw.focus_mode = Control.FOCUS_NONE
		sw.tooltip_text = UITheme.wrap_tip("Set note colour")
		var sb: StyleBoxFlat = StyleBoxFlat.new()
		sb.bg_color = col
		sb.corner_radius_top_left = 4
		sb.corner_radius_top_right = 4
		sb.corner_radius_bottom_left = 4
		sb.corner_radius_bottom_right = 4
		sw.add_theme_stylebox_override("normal", sb)
		sw.add_theme_stylebox_override("hover", sb)
		sw.add_theme_stylebox_override("pressed", sb)
		sw.pressed.connect(
			func() -> void:
				var cs: Array = _owner._graph_model.get("comments", [])
				if idx < cs.size():
					_owner._push_undo()
					(cs[idx] as Dictionary)["color"] = col
					_owner._refresh_graph()
		)
		swatch_row.add_child(sw)
	side_vbox.add_child(swatch_row)
	side_vbox.add_child(_side_section_separator())

	# Pin status. A pinned note follows its node when the node is moved; pin by dragging the note onto a node.
	if str((comments[idx] as Dictionary).get("node_id", "")) != "":
		var unpin_btn: Button = UITheme.make_icon_btn("📌 UNPIN FROM NODE", false, UITheme.CYAN)
		unpin_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		unpin_btn.pressed.connect(func() -> void: _owner._unpin_comment(idx))
		side_vbox.add_child(unpin_btn)
	else:
		var pin_hint: Label = Label.new()
		pin_hint.text = "Drag this note onto a node to pin it — it then moves with that node."
		pin_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		pin_hint.add_theme_font_size_override("font_size", 11)
		pin_hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
		side_vbox.add_child(pin_hint)

	side_vbox.add_child(_side_section_separator())
	var del_btn: Button = UITheme.make_icon_btn("🗑 DELETE NOTE", false, UITheme.ERROR_SOFT)
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(func() -> void: _owner._delete_comment(idx))
	side_vbox.add_child(del_btn)


# Graph editor: the side panel for a selected group frame — rename it, recolour it, or delete it.
func show_frame_editor(idx: int) -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	for c in side_vbox.get_children():
		c.queue_free()
	var groups: Array = _owner._graph_model.get("groups", [])
	if idx < 0 or idx >= groups.size():
		show_journey_info_panel()
		return
	var hdr: Label = Label.new()
	hdr.text = "// GROUP //"
	hdr.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_vbox.add_child(hdr)
	side_vbox.add_child(_side_field_label("LABEL"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str((groups[idx] as Dictionary).get("label", ""))
	name_edit.placeholder_text = "Group label..."
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(
		func(val: String) -> void:
			var gs: Array = _owner._graph_model.get("groups", [])
			if idx < gs.size():
				(gs[idx] as Dictionary)["label"] = val
	)
	name_edit.focus_exited.connect(func() -> void: _owner._refresh_graph())
	side_vbox.add_child(name_edit)
	side_vbox.add_child(_side_field_label("COLOUR"))
	var swatch_row: HBoxContainer = HBoxContainer.new()
	swatch_row.add_theme_constant_override("separation", 6)
	for col: Color in [
		UITheme.PURPLE_BRIGHT, UITheme.AMBER, UITheme.CYAN, Color(0.45, 0.95, 0.30), UITheme.MAGENTA
	]:
		var sw: Button = Button.new()
		sw.custom_minimum_size = Vector2(30, 26)
		sw.focus_mode = Control.FOCUS_NONE
		sw.tooltip_text = UITheme.wrap_tip("Set frame colour")
		var sb: StyleBoxFlat = StyleBoxFlat.new()
		sb.bg_color = col
		sb.corner_radius_top_left = 4
		sb.corner_radius_top_right = 4
		sb.corner_radius_bottom_left = 4
		sb.corner_radius_bottom_right = 4
		sw.add_theme_stylebox_override("normal", sb)
		sw.add_theme_stylebox_override("hover", sb)
		sw.add_theme_stylebox_override("pressed", sb)
		sw.pressed.connect(
			func() -> void:
				var gs: Array = _owner._graph_model.get("groups", [])
				if idx < gs.size():
					_owner._push_undo()
					(gs[idx] as Dictionary)["color"] = col
					_owner._refresh_graph()
		)
		swatch_row.add_child(sw)
	side_vbox.add_child(swatch_row)
	side_vbox.add_child(_side_section_separator())
	var collapsed: bool = bool((groups[idx] as Dictionary).get("collapsed", false))
	var collapse_btn: Button = UITheme.make_icon_btn(
		"▸ EXPAND" if collapsed else "▾ COLLAPSE", false, UITheme.PURPLE_MID
	)
	collapse_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	collapse_btn.pressed.connect(func() -> void: _owner._on_frame_toggle_collapse(idx))
	side_vbox.add_child(collapse_btn)
	var del_btn: Button = UITheme.make_icon_btn("🗑 DELETE GROUP", false, UITheme.ERROR_SOFT)
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(func() -> void: _owner._delete_frame(idx))
	side_vbox.add_child(del_btn)


# Graph editor: the side panel shown when 2+ nodes are selected. Group actions only (per-node field
# editing needs a single selection); the ADD NODE row stays so creating is always reachable.
func show_graph_multi_select_panel(ids: Array) -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	if side_vbox == null:
		return
	for c in side_vbox.get_children():
		c.queue_free()

	var hdr: Label = Label.new()
	hdr.text = "// %d NODES SELECTED //" % ids.size()
	hdr.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_vbox.add_child(hdr)

	var hint: Label = Label.new()
	hint.text = "Drag any selected node to move the group. Ctrl/Shift-click a node to adjust the selection; click empty space to clear."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 11)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side_vbox.add_child(hint)

	side_vbox.add_child(_side_section_separator())
	var copy_btn: Button = UITheme.make_icon_btn(
		"⧉ COPY (%d)" % ids.size(), false, UITheme.PURPLE_BRIGHT
	)
	copy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_btn.pressed.connect(func() -> void: _owner._copy_selection())
	side_vbox.add_child(copy_btn)
	var dup_btn: Button = UITheme.make_icon_btn(
		"⎘ DUPLICATE (%d)" % ids.size(), false, UITheme.PURPLE_MID
	)
	dup_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dup_btn.pressed.connect(func() -> void: _owner._duplicate_selection())
	side_vbox.add_child(dup_btn)
	var del_btn: Button = UITheme.make_icon_btn(
		"🗑 DELETE SELECTED (%d)" % ids.size(), false, UITheme.ERROR_SOFT
	)
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(func() -> void: _owner._delete_selected_nodes())
	side_vbox.add_child(del_btn)

	# Extraction lives on the node right-click menu (see JourneyBuilder._show_node_context_menu).

	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_make_graph_add_buttons())


# Graph-editor fork editor (3c-ii): edits the fork's meta (title/description/resolution + the
# conditional sub-config) and its CHOICES — one per out-edge. Unlike the tree fork editor, a
# choice holds no nested items; it just carries its config and a `to` target wired by connect
# mode. Mutates node.data + node.out in place; structural changes go through `reselect`.
# A "SETS FLAGS" comma-separated field writing a cleaned string array to target["set_flags"] — shared
# by a playable node's data and a fork choice's edge. Flags are set when the node plays or the choice
# is taken, and read by flag-conditional forks downstream.
# A small label listing the flags already used in the journey, so authors reuse consistent names (a
# lightweight stand-in for autocomplete). "No flags used yet." when there are none.
func _known_flags_hint() -> Label:
	var known: Array = (_owner._all_set_flags() as Dictionary).keys()
	known.sort()
	var lbl: Label = Label.new()
	lbl.text = (
		("Known: " + ", ".join(PackedStringArray(known)))
		if not known.is_empty()
		else "No flags used yet."
	)
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return lbl


# An "image fit" dropdown → target["image_fit"] (fit / crop / stretch) — how a fork-choice or boss image
# fills its frame. `default_fit` is the surface's historical default (fork = stretch, boss = fit), shown when
# the author hasn't set one so existing journeys read unchanged.
func _make_image_fit_field(target: Dictionary, default_fit: String) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.add_child(_side_field_label("IMAGE FIT"))
	var values: Array = ["fit", "crop", "stretch"]
	var labels: Array = [
		"Fit — whole image (letterbox)", "Crop — fill & crop", "Stretch — fill (distort)"
	]
	var dd: OptionButton = OptionButton.new()
	for i: int in values.size():
		dd.add_item(str(labels[i]), i)
	var cur: String = str(target.get("image_fit", ""))
	if cur == "":
		cur = default_fit
	dd.selected = maxi(0, values.find(cur))
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(dd)
	dd.item_selected.connect(func(i: int) -> void: target["image_fit"] = str(values[i]))
	col.add_child(dd)
	return col


func _make_set_flags_field(target: Dictionary) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.add_child(_side_field_label("SETS FLAGS  (COMMA-SEPARATED · PREFIX - TO CLEAR)"))
	var edit: LineEdit = LineEdit.new()
	edit.placeholder_text = "e.g. found_key, -spared_boss"
	edit.text = _join_flag_field(target)
	UITheme.style_line_edit(edit)
	edit.text_changed.connect(func(v: String) -> void: _parse_flag_field(v, target))
	col.add_child(edit)
	col.add_child(_known_flags_hint())
	return col


# Splits the SETS FLAGS text into set_flags (plain names) and clear_flags (names written with a leading "-").
# So "found_key, -spared_boss" sets found_key and clears spared_boss on the run's flag set.
func _parse_flag_field(text: String, target: Dictionary) -> void:
	var sets: Array = []
	var clears: Array = []
	for part: String in text.split(","):
		var s: String = part.strip_edges()
		if s.begins_with("-"):
			var name: String = s.substr(1).strip_edges()
			if name != "" and not (name in clears):
				clears.append(name)
		elif s != "" and not (s in sets):
			sets.append(s)
	target["set_flags"] = sets
	target["clear_flags"] = clears


# Rebuilds the field text from set_flags + clear_flags (each cleared flag shown with a leading "-").
func _join_flag_field(target: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for f: Variant in JourneyData.clean_flag_list(target.get("set_flags", [])):
		parts.append(str(f))
	for f: Variant in JourneyData.clean_flag_list(target.get("clear_flags", [])):
		parts.append("-" + str(f))
	return ", ".join(parts)


# A multi-select dropdown (built-in + journey custom items) → target["remove_items"] (array of ids). Each
# checked item has one held copy consumed when the node completes / the choice is taken. The item set mirrors
# the give-item picker; MultiSelectDropdown keeps the list open for picking several.
func _make_remove_items_field(target: Dictionary) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.add_child(_side_field_label("REMOVES ITEMS"))

	var entries: Array = []  # [{id, label}] — built-ins then journey custom items
	for k: String in InventoryService.GetBuiltinItemIds():
		entries.append({"id": k, "label": str(InventoryService.GetItemData(k).get("name", k))})
	for it: Dictionary in _owner._journey_items:
		var iid: String = str(it.get("id", ""))
		if iid != "":
			entries.append({"id": iid, "label": "%s  (custom)" % str(it.get("name", ""))})

	var dd: MultiSelectDropdown = MultiSelectDropdown.new()
	dd.empty_text = "None"
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(dd)  # add first so _ready wires the popup, then populate
	dd.set_options(entries)
	dd.set_selected(target.get("remove_items", []))
	UITheme.style_menu_button(dd)
	dd.selection_changed.connect(func(ids: Array) -> void: target["remove_items"] = ids)
	return col


# The numeric sibling of _make_set_flags_field: a "belt:1, arousal:2, stress:-1" field writing a
# {name: delta} map to target["set_counters"]. A bare name means +1 (the "notch on the belt" case).
# Applied when the node plays / the choice is taken (GameState.ApplyCounters); read by counter forks.
func _make_set_counters_field(target: Dictionary) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.add_child(_side_field_label("SETS COUNTERS  (name:delta, comma-separated)"))
	var edit: LineEdit = LineEdit.new()
	edit.placeholder_text = "e.g. belt:1, arousal:2, stress:-1"
	edit.text = JourneyData.counter_deltas_to_text(
		JourneyData.clean_counter_deltas(target.get("set_counters", {}))
	)
	UITheme.style_line_edit(edit)
	edit.text_changed.connect(
		func(v: String) -> void: target["set_counters"] = JourneyData.parse_counter_deltas(v)
	)
	col.add_child(edit)
	return col


# The side-panel channel-overlay editor for a ghosted base ROUND during rendition authoring (replaces the
# old CHANNEL OVERLAYS modal). The base round is locked; drop axis/vibe funscripts onto its EMPTY channels
# — routed by filename suffix — and each becomes a slot_fill. Base-owned channels are shown but locked.
func _make_rendition_round_editor(node_id: String, node: Dictionary) -> Control:
	var data: Dictionary = node.get("data", {})

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)

	var hdr: Label = Label.new()
	hdr.text = "⊕ CHANNEL OVERLAY"
	hdr.add_theme_color_override("font_color", UITheme.CYAN)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hdr)

	var rname: String = str(data.get("name", "")).strip_edges()
	var subl: Label = Label.new()
	subl.text = ("Round: %s" % rname) if rname != "" else "Round (unnamed)"
	subl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	subl.add_theme_font_size_override("font_size", 11)
	subl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(subl)

	var note: Label = Label.new()
	note.text = "The base round is locked. Drop axis / vibe funscripts to overlay them onto its EMPTY channels — routed by filename suffix (_L1, _R1, _vib1…). The base's own channels stay untouched."
	note.add_theme_color_override("font_color", UITheme.SEPARATOR)
	note.add_theme_font_size_override("font_size", 10)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(note)

	# Bulk drop — every dropped funscript routes to its channel by suffix (see _route_channel_scripts).
	var zone: PanelContainer = DropZoneScript.new()
	zone.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
	zone.multi = true
	zone.picker_title = "Attach Channel Scripts"
	zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zone.files_dropped.connect(
		func(paths: PackedStringArray) -> void: _owner._route_channel_scripts(node_id, paths)
	)
	col.add_child(zone)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("CHANNELS"))
	var overlay_count: int = 0
	for channel: String in JourneyData.AXIS_SUFFIXES:
		if _owner._find_slot_fill(node_id, "axis_scripts", channel) >= 0:
			overlay_count += 1
		col.add_child(
			_channel_overlay_row(
				node_id, data, "axis_scripts", channel, str(JourneyData.AXIS_SUFFIXES[channel])
			)
		)
	for channel: String in JourneyData.VIB_SUFFIXES:
		if _owner._find_slot_fill(node_id, "vib_scripts", channel) >= 0:
			overlay_count += 1
		col.add_child(
			_channel_overlay_row(
				node_id, data, "vib_scripts", channel, str(JourneyData.VIB_SUFFIXES[channel])
			)
		)

	# Remove everything this round overlaid — the quick "I picked the wrong scripts" escape hatch, on top
	# of the per-channel ✕.
	if overlay_count > 0:
		col.add_child(_side_section_separator())
		var clear_btn: Button = UITheme.make_icon_btn(
			"✕ CLEAR OVERLAYS (%d)" % overlay_count, false, UITheme.MAGENTA
		)
		clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		clear_btn.pressed.connect(func() -> void: _owner._clear_round_slot_fills(node_id))
		col.add_child(clear_btn)
	return col


# One channel status row: locked ("in base"), an overlay slot-fill (filename + ✕), or empty (＋ picker).
func _channel_overlay_row(
	node_id: String, data: Dictionary, field: String, channel: String, human: String
) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl: Label = Label.new()
	lbl.text = "%s  (%s)" % [channel, human]
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(lbl)

	if (data.get(field, {}) as Dictionary).has(channel):
		lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
		var s: Label = Label.new()
		s.text = "in base"
		s.add_theme_color_override("font_color", UITheme.SEPARATOR)
		s.add_theme_font_size_override("font_size", 10)
		row.add_child(s)
		return row

	lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	var idx: int = _owner._find_slot_fill(node_id, field, channel)
	if idx >= 0:
		var fname: Label = Label.new()
		fname.text = (
			str((_owner._rendition_slot_fills[idx] as Dictionary).get("path", "")).get_file()
		)
		fname.add_theme_color_override("font_color", UITheme.CYAN)
		fname.add_theme_font_size_override("font_size", 10)
		fname.clip_text = true
		fname.custom_minimum_size = Vector2(120, 0)
		row.add_child(fname)
		var rm: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
		rm.tooltip_text = UITheme.wrap_tip("Remove this channel overlay")
		rm.pressed.connect(func() -> void: _owner._remove_slot_fill(node_id, field, channel))
		row.add_child(rm)
	else:
		var add: Button = Button.new()
		add.text = "＋"
		add.tooltip_text = UITheme.wrap_tip("Attach a script to this channel")
		UITheme.style_button(add, UITheme.PURPLE_MID, 12, 6)
		add.pressed.connect(func() -> void: _owner._pick_slot_fill_script(node_id, field, channel))
		row.add_child(add)
	return row


# The side-panel editor for a ghosted base FORK during rendition authoring. The base's prompt and its own
# choices are shown read-only for context (they render identically when the base is played standalone);
# below them the rendition can ADD overlay choices — append-anchors, each with its OWN name + card image +
# target — up to the 4-choice ForkScreen cap. Base-owned config (prompt/resolution/base labels) is never
# editable here; the base fork is never re-saved.
func _make_rendition_fork_editor(node_id: String, node: Dictionary) -> Control:
	var data: Dictionary = node.get("data", {})
	var out: Array = node.get("out", [])

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)

	var hdr: Label = Label.new()
	hdr.text = "⑂ OVERLAY FORK"
	hdr.add_theme_color_override("font_color", UITheme.CYAN)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hdr)

	var note: Label = Label.new()
	note.text = "The base fork is locked. Add choices that appear only when this rendition is installed."
	note.add_theme_color_override("font_color", UITheme.SEPARATOR)
	note.add_theme_font_size_override("font_size", 10)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(note)

	var title: String = str(data.get("title", "")).strip_edges()
	if title != "":
		col.add_child(_side_field_label("BASE PROMPT"))
		var pl: Label = Label.new()
		pl.text = title
		pl.add_theme_color_override("font_color", UITheme.SEPARATOR)
		pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(pl)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("CHOICES"))

	# The fork's resolution + metric are base-owned; overlay choices gate/act by the same rules, so the
	# overlay editor exposes the matching per-resolution fields (weight / cost / threshold / requirement).
	var resolution: String = str(data.get("resolution", "choice"))
	var metric: String = str(data.get("cond_metric", "score"))

	# Base choices (and any base open slot) read-only; overlay choices — an anchor edge with no `_slot` —
	# fully editable. A filled base slot (anchor + `_slot`) is base-owned, so it stays a read-only summary.
	for ei in out.size():
		var edge: Dictionary = out[ei]
		if bool(edge.get("_anchor", false)) and not edge.has("_slot"):
			col.add_child(_make_overlay_choice_block(node_id, out, ei, resolution, metric))
		else:
			col.add_child(_make_base_choice_summary(out, ei))

	# ForkScreen shows at most 4 choices — cap on the total (base slots + overlay choices).
	if out.size() < 4:
		var add_btn: Button = Button.new()
		add_btn.text = "+ ADD OVERLAY CHOICE"
		add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(add_btn, UITheme.CYAN)
		add_btn.pressed.connect(func() -> void: _owner._add_overlay_fork_choice(node_id))
		col.add_child(add_btn)
	else:
		var capped: Label = Label.new()
		capped.text = "Fork is full — 4 choices max."
		capped.add_theme_color_override("font_color", UITheme.SEPARATOR)
		capped.add_theme_font_size_override("font_size", 10)
		col.add_child(capped)

	return col


# A read-only summary row for a BASE fork choice (or an open/filled base slot) inside the rendition fork
# editor: its label + where it leads, dimmed to signal it's locked. Context only — no edit controls.
func _make_base_choice_summary(out: Array, ei: int) -> Control:
	var edge: Dictionary = out[ei]
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", ROW_SEP)
	var lbl: Label = Label.new()
	var nm: String = str(edge.get("name", "")).strip_edges()
	var to: String = str(edge.get("to", "")).strip_edges()
	var dest: String = _graph_node_label(to) if to != "" else "(open)"
	lbl.text = "%d. %s → %s" % [ei + 1, nm if nm != "" else "Choice", dest]
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(lbl)
	return row


# An editable card for one OVERLAY fork choice (an append-anchor the rendition added): NAME, CARD IMAGE,
# LEADS TO (connect), and REMOVE. Styled in the rendition accent (cyan) so it reads as the overlay's own.
# Edits write straight into out[ei]; structural actions route through the owner and re-render.
func _make_overlay_choice_block(
	node_id: String, out: Array, ei: int, resolution: String, metric: String
) -> Control:
	var edge: Dictionary = out[ei]

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = Color(UITheme.CYAN.r, UITheme.CYAN.g, UITheme.CYAN.b, 0.08)
	ps.border_color = UITheme.CYAN
	ps.border_width_left = 1
	ps.border_width_right = 1
	ps.border_width_top = 1
	ps.border_width_bottom = 1
	ps.content_margin_left = 10
	ps.content_margin_right = 10
	ps.content_margin_top = 8
	ps.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", ps)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sub: VBoxContainer = VBoxContainer.new()
	sub.add_theme_constant_override("separation", 4)
	panel.add_child(sub)

	var top: HBoxContainer = HBoxContainer.new()
	top.add_theme_constant_override("separation", ROW_SEP)
	sub.add_child(top)
	var choice_lbl: Label = Label.new()
	choice_lbl.text = "OVERLAY CHOICE %d" % (ei + 1)
	choice_lbl.add_theme_color_override("font_color", UITheme.CYAN)
	choice_lbl.add_theme_font_size_override("font_size", 11)
	choice_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(choice_lbl)
	var rm_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.CYAN)
	rm_btn.tooltip_text = UITheme.wrap_tip("Remove this overlay choice")
	rm_btn.pressed.connect(func() -> void: _owner._remove_overlay_fork_choice(node_id, ei))
	top.add_child(rm_btn)

	sub.add_child(_side_field_label("NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Choice name..."
	name_edit.text = str(edge.get("name", ""))
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: out[ei]["name"] = v)
	sub.add_child(name_edit)

	sub.add_child(_side_field_label("DESCRIPTION"))
	var desc_edit: LineEdit = LineEdit.new()
	desc_edit.placeholder_text = "Description (optional)..."
	desc_edit.text = str(edge.get("description", ""))
	UITheme.style_line_edit(desc_edit)
	desc_edit.text_changed.connect(func(v: String) -> void: out[ei]["description"] = v)
	sub.add_child(desc_edit)

	sub.add_child(_side_field_label("CARD IMAGE"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions = JourneyData.ANIMATED_IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title = "Select Card Image for Overlay Choice %d" % (ei + 1)
	img_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub.add_child(img_zone)
	if str(edge.get("image_path", "")) != "":
		img_zone.call_deferred("set_file", edge["image_path"])
	var img_rm_btn: Button = Button.new()
	img_rm_btn.text = "✕ REMOVE IMAGE"
	img_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	img_rm_btn.visible = str(edge.get("image_path", "")) != ""
	UITheme.style_button(img_rm_btn, UITheme.CYAN)
	img_rm_btn.pressed.connect(
		func() -> void:
			_delete_saved_image(str(out[ei].get("image_path", "")))
			out[ei]["image_path"] = ""
			img_zone.call_deferred("set_file", "")
			img_rm_btn.visible = false
	)
	img_zone.file_dropped.connect(
		func(p: String) -> void:
			out[ei]["image_path"] = p
			img_rm_btn.visible = true
	)
	sub.add_child(img_rm_btn)
	sub.add_child(_make_image_fit_field(out[ei], "stretch"))

	# Full parity with a native choice: the fork's per-resolution gate (weight / cost / threshold /
	# requirement) + on-take flags/counters, so an overlay option behaves exactly like a base one.
	_add_choice_resolution_and_effects(sub, out, ei, resolution, metric)

	# LEADS TO — connect this choice to a target node (routes through the anchor connect, which appends
	# it as an extra choice at compose). Shows the current destination or an unconnected warning.
	sub.add_child(_side_section_separator())
	sub.add_child(_side_field_label("LEADS TO"))
	var to_id: String = str(edge.get("to", "")).strip_edges()
	var connecting: bool = _owner._connecting_from == node_id and _owner._connecting_edge_idx == ei
	var conn_btn: Button = UITheme.make_icon_btn(
		(
			"✕ CANCEL CONNECT"
			if connecting
			else ("🔗 " + _graph_node_label(to_id) if to_id != "" else "🔗 CONNECT TO…")
		),
		false,
		UITheme.AMBER
	)
	conn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	conn_btn.pressed.connect(func() -> void: _owner._begin_connect_fork_edge(node_id, ei))
	sub.add_child(conn_btn)
	if to_id == "" and not connecting:
		var warn: Label = Label.new()
		warn.text = "Not connected — this choice is dropped on save until you wire it."
		warn.add_theme_color_override("font_color", UITheme.AMBER)
		warn.add_theme_font_size_override("font_size", 10)
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.add_child(warn)

	return panel


func _make_graph_fork_editor(node_id: String, node: Dictionary, reselect: Callable) -> Control:
	var data: Dictionary = node.get("data", {})
	var out: Array = node.get("out", [])

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)

	col.add_child(_side_field_label("TITLE"))
	var title_edit: LineEdit = LineEdit.new()
	title_edit.placeholder_text = "Fork title (optional)..."
	title_edit.text = data.get("title", "")
	UITheme.style_line_edit(title_edit)
	title_edit.text_changed.connect(func(v: String) -> void: data["title"] = v)
	col.add_child(title_edit)

	col.add_child(_side_field_label("DESCRIPTION"))
	var desc_edit: LineEdit = LineEdit.new()
	desc_edit.placeholder_text = "Fork description (optional)..."
	desc_edit.text = data.get("description", "")
	UITheme.style_line_edit(desc_edit)
	desc_edit.text_changed.connect(func(v: String) -> void: data["description"] = v)
	col.add_child(desc_edit)

	# Resolution: how the journey picks a choice.
	col.add_child(_side_field_label("RESOLUTION"))
	var res_values: Array = ["choice", "random", "conditional", "sacrifice"]
	var res_dd: OptionButton = OptionButton.new()
	res_dd.add_item("Player Choice")
	res_dd.add_item("Random")
	res_dd.add_item("Conditional")
	res_dd.add_item("Sacrifice")
	res_dd.selected = max(0, res_values.find(data.get("resolution", "choice")))
	res_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(res_dd)
	res_dd.item_selected.connect(
		func(i: int) -> void:
			data["resolution"] = res_values[i]
			reselect.call(0)  # rebuild so per-choice fields match the new type
	)
	col.add_child(res_dd)

	var resolution: String = data.get("resolution", "choice")
	var metric: String = data.get("cond_metric", "score")

	# Conditional sub-config: which metric + the fallback choice.
	if resolution == "conditional":
		col.add_child(_side_field_label("CONDITION"))
		var metric_values: Array = ["score", "coins", "item", "flag", "counter"]
		var metric_dd: OptionButton = OptionButton.new()
		metric_dd.add_item("Last Round Score")
		metric_dd.add_item("Coin Balance")
		metric_dd.add_item("Item Owned")
		metric_dd.add_item("Flag Set")
		metric_dd.add_item("Counter Value")
		metric_dd.selected = max(0, metric_values.find(metric))
		metric_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_option_button(metric_dd)
		metric_dd.item_selected.connect(
			func(i: int) -> void:
				data["cond_metric"] = metric_values[i]
				reselect.call(0)
		)
		col.add_child(metric_dd)

		# A counter fork's DEFAULT counter — each choice's threshold compares against it, exactly like
		# score/coins. A choice can override this with its own counter (see the per-choice COUNTER field),
		# so one fork can gate different choices on different counters (e.g. prod ≥ 2 vs test ≥ 3).
		if metric == "counter":
			col.add_child(_side_field_label("DEFAULT COUNTER  (per-choice can override)"))
			var cn_edit: LineEdit = LineEdit.new()
			cn_edit.placeholder_text = "e.g. belt, arousal, satisfied_partners"
			cn_edit.text = str(data.get("cond_counter", ""))
			UITheme.style_line_edit(cn_edit)
			cn_edit.text_changed.connect(
				func(v: String) -> void: data["cond_counter"] = v.strip_edges()
			)
			col.add_child(cn_edit)

		# Who resolves it: the game auto-spins to the best match, or the player picks among the paths
		# they've unlocked (the condition gates which choices are selectable).
		col.add_child(_side_field_label("RESOLVED BY"))
		var decider_values: Array = ["game", "player"]
		var decider_dd: OptionButton = OptionButton.new()
		decider_dd.add_item("Game (auto-spin)")
		decider_dd.add_item("Player (picks unlocked)")
		decider_dd.selected = max(0, decider_values.find(data.get("cond_decider", "game")))
		decider_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_option_button(decider_dd)
		decider_dd.item_selected.connect(
			func(i: int) -> void:
				data["cond_decider"] = decider_values[i]
				reselect.call(0)
		)
		col.add_child(decider_dd)

		col.add_child(_side_field_label("DEFAULT CHOICE (FALLBACK / ALWAYS AVAILABLE)"))
		var def_dd: OptionButton = OptionButton.new()
		for ej in out.size():
			var en: String = str((out[ej] as Dictionary).get("name", "")).strip_edges()
			def_dd.add_item("Choice %d%s" % [ej + 1, ("  " + en) if en != "" else ""])
		def_dd.selected = clampi(int(data.get("default_path", 0)), 0, max(0, out.size() - 1))
		def_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_option_button(def_dd)
		def_dd.item_selected.connect(func(i: int) -> void: data["default_path"] = i)
		col.add_child(def_dd)

	var res_hint: Label = Label.new()
	res_hint.text = _fork_resolution_hint(resolution, metric, data.get("cond_decider", "game"))
	res_hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	res_hint.add_theme_font_size_override("font_size", 10)
	res_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(res_hint)

	# Auto-advance timeout choice (used only when the journey enables auto-advance). Conditional forks
	# fall back to their DEFAULT CHOICE above, so this is offered only for choice / sacrifice forks.
	if resolution == "choice" or resolution == "sacrifice":
		col.add_child(_side_field_label("ON AUTO-ADVANCE TIMEOUT"))
		var to_dd: OptionButton = OptionButton.new()
		to_dd.add_item("Random affordable path")  # dropdown index 0 → timeout_path -1
		for ei in out.size():
			var en: String = str((out[ei] as Dictionary).get("name", "")).strip_edges()
			to_dd.add_item("Choice %d%s" % [ei + 1, ("  " + en) if en != "" else ""])
		var cur_to: int = int(data.get("timeout_path", -1))
		to_dd.selected = (cur_to + 1) if (cur_to >= 0 and cur_to < out.size()) else 0
		to_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		to_dd.tooltip_text = (
			UITheme
			. wrap_tip(
				"If the journey's auto-advance timer runs out on this fork, take this path. 'Random affordable path' picks one the player could afford."
			)
		)
		UITheme.style_option_button(to_dd)
		to_dd.item_selected.connect(func(i: int) -> void: data["timeout_path"] = i - 1)
		col.add_child(to_dd)

	col.add_child(_side_field_label("FORK AUDIO (OPTIONAL)"))
	var fork_audio_zone: PanelContainer = DropZoneScript.new()
	fork_audio_zone.accepted_extensions = JourneyAudio.AUDIO_EXTENSIONS.duplicate()
	fork_audio_zone.picker_title = "Select Fork Audio"
	fork_audio_zone.picker_filters = ["*.ogg,*.mp3,*.wav ; Audio Files"]
	fork_audio_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(fork_audio_zone)
	if str(data.get("audio", "")) != "":
		fork_audio_zone.call_deferred("set_file", data["audio"])
	var fork_loop_toggle: CheckButton = CheckButton.new()
	fork_loop_toggle.text = "LOOP THIS AUDIO"
	fork_loop_toggle.add_theme_font_size_override("font_size", 11)
	fork_loop_toggle.button_pressed = bool(data.get("audio_loop", false))
	fork_loop_toggle.visible = str(data.get("audio", "")) != ""
	fork_loop_toggle.toggled.connect(func(on: bool) -> void: data["audio_loop"] = on)
	col.add_child(fork_loop_toggle)
	var fork_audio_vol: Control = _make_volume_row(
		col, data, "audio_volume", 1.0, func() -> String: return str(data.get("audio", ""))
	)
	fork_audio_vol.visible = str(data.get("audio", "")) != ""
	col.add_child(fork_audio_vol)
	var fork_audio_rm: Button = Button.new()
	fork_audio_rm.text = "✕ REMOVE AUDIO"
	fork_audio_rm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fork_audio_rm.visible = str(data.get("audio", "")) != ""
	UITheme.style_button(fork_audio_rm, UITheme.MAGENTA)
	fork_audio_rm.pressed.connect(
		func() -> void:
			data["audio"] = ""
			fork_audio_zone.call_deferred("set_file", "")
			fork_audio_rm.visible = false
			fork_loop_toggle.visible = false
			fork_audio_vol.visible = false
	)
	fork_audio_zone.file_dropped.connect(
		func(p: String) -> void:
			data["audio"] = p
			fork_audio_rm.visible = p != ""
			fork_loop_toggle.visible = p != ""
			fork_audio_vol.visible = p != ""
	)
	col.add_child(fork_audio_rm)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("CHOICES"))

	for ei in out.size():
		col.add_child(_make_graph_choice_block(node_id, out, ei, resolution, metric, reselect))

	# Cap at 4 to match the proven ForkScreen choice layout.
	if out.size() < 4:
		var add_btn: Button = Button.new()
		add_btn.text = "+ ADD CHOICE"
		add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(add_btn, UITheme.PURPLE_MID)
		add_btn.pressed.connect(func() -> void: _owner._add_fork_edge(node_id))
		col.add_child(add_btn)

	return col


# The per-resolution gate field(s) + on-take effects (set flags / bump counters) for one fork choice.
# Shared verbatim by native fork choices and rendition OVERLAY choices, so an overlay option gates and
# acts exactly like a base one. `resolution`/`metric` come from the (base-owned) fork; edits write into
# out[ei]. The gate fields reuse the tree path helpers, which index out[ei] just like a tree path.
func _add_choice_resolution_and_effects(
	sub: VBoxContainer, out: Array, ei: int, resolution: String, metric: String
) -> void:
	var edge: Dictionary = out[ei]
	if resolution == "random":
		_add_path_int_field(sub, out, ei, "weight", "WEIGHT (RELATIVE ODDS)", 1000)
	elif resolution == "sacrifice":
		_add_path_int_field(sub, out, ei, "cost", "COIN COST", 999999)
		_add_required_item_field(sub, out, ei, edge, "REQUIRED ITEM (CONSUMED)")
	elif resolution == "conditional" and metric == "item":
		_add_required_item_field(sub, out, ei, edge, "REQUIRED ITEM")
	elif resolution == "conditional" and metric == "flag":
		sub.add_child(_side_field_label("REQUIRED FLAG"))
		var rf_edit: LineEdit = LineEdit.new()
		rf_edit.placeholder_text = "Flag name (e.g. spared_boss)..."
		rf_edit.text = str(edge.get("required_flag", ""))
		UITheme.style_line_edit(rf_edit)
		rf_edit.text_changed.connect(
			func(v: String) -> void: out[ei]["required_flag"] = v.strip_edges()
		)
		sub.add_child(rf_edit)
		sub.add_child(_known_flags_hint())
	elif resolution == "conditional":
		var metric_word: String = "SCORE"
		if metric == "coins":
			metric_word = "COINS"
		elif metric == "counter":
			metric_word = "COUNTER"
			# Each choice can gate on its own counter (e.g. one on "prod", another on "test"); blank
			# falls back to the fork's default counter. This is the per-choice sibling of the threshold.
			sub.add_child(_side_field_label("COUNTER  (blank = fork default)"))
			var pc_edit: LineEdit = LineEdit.new()
			pc_edit.placeholder_text = "Counter name (e.g. prod)…"
			pc_edit.text = str(edge.get("cond_counter", ""))
			UITheme.style_line_edit(pc_edit)
			pc_edit.text_changed.connect(
				func(v: String) -> void: out[ei]["cond_counter"] = v.strip_edges()
			)
			sub.add_child(pc_edit)
		var thr_label: String = "ACTIVATES AT ≥  (%s)" % metric_word
		_add_path_int_field(sub, out, ei, "threshold", thr_label, 999999)

	# A choice can set/clear flags, bump counters, and remove items when it's taken ("you chose mercy" /
	# "+1 resolve" / "hands over the key").
	sub.add_child(_make_set_flags_field(edge))
	sub.add_child(_make_set_counters_field(edge))
	sub.add_child(_make_remove_items_field(edge))


# One choice card inside the graph fork editor: name / description / card image, the per-
# resolution field (weight / threshold / cost / required item — reusing the tree helpers, which
# write to out[ei] just as they do for a tree path), and the "LEADS TO" wiring (connect / clear).
func _make_graph_choice_block(
	node_id: String, out: Array, ei: int, resolution: String, metric: String, reselect: Callable
) -> Control:
	var edge: Dictionary = out[ei]

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.08)
	ps.border_color = UITheme.MAGENTA
	ps.border_width_left = 1
	ps.border_width_right = 1
	ps.border_width_top = 1
	ps.border_width_bottom = 1
	ps.content_margin_left = 10
	ps.content_margin_right = 10
	ps.content_margin_top = 8
	ps.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", ps)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sub: VBoxContainer = VBoxContainer.new()
	sub.add_theme_constant_override("separation", 4)
	panel.add_child(sub)

	var hdr: HBoxContainer = HBoxContainer.new()
	hdr.add_theme_constant_override("separation", ROW_SEP)
	sub.add_child(hdr)
	var choice_lbl: Label = Label.new()
	choice_lbl.text = "CHOICE %d" % (ei + 1)
	choice_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	choice_lbl.add_theme_font_size_override("font_size", 11)
	choice_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(choice_lbl)
	# A fork needs ≥2 choices (matches the tree's path minimum + ForkScreen).
	if out.size() > 2:
		var rm_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
		rm_btn.tooltip_text = UITheme.wrap_tip("Delete this choice")
		rm_btn.pressed.connect(func() -> void: _owner._remove_fork_edge(node_id, ei))
		hdr.add_child(rm_btn)

	sub.add_child(_side_field_label("NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Choice name..."
	name_edit.text = edge.get("name", "")
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: out[ei]["name"] = v)
	sub.add_child(name_edit)

	sub.add_child(_side_field_label("DESCRIPTION"))
	var cdesc_edit: LineEdit = LineEdit.new()
	cdesc_edit.placeholder_text = "Description (optional)..."
	cdesc_edit.text = edge.get("description", "")
	UITheme.style_line_edit(cdesc_edit)
	cdesc_edit.text_changed.connect(func(v: String) -> void: out[ei]["description"] = v)
	sub.add_child(cdesc_edit)

	sub.add_child(_side_field_label("CARD IMAGE"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions = JourneyData.ANIMATED_IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title = "Select Card Image for Choice %d" % (ei + 1)
	img_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub.add_child(img_zone)
	if edge.get("image_path", "") != "":
		img_zone.call_deferred("set_file", edge["image_path"])
	var img_rm_btn: Button = Button.new()
	img_rm_btn.text = "✕ REMOVE IMAGE"
	img_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	img_rm_btn.visible = edge.get("image_path", "") != ""
	UITheme.style_button(img_rm_btn, UITheme.MAGENTA)
	img_rm_btn.pressed.connect(
		func() -> void:
			_delete_saved_image(out[ei].get("image_path", ""))
			out[ei]["image_path"] = ""
			img_zone.call_deferred("set_file", "")
			img_rm_btn.visible = false
	)
	img_zone.file_dropped.connect(
		func(p: String) -> void:
			out[ei]["image_path"] = p
			img_rm_btn.visible = true
	)
	sub.add_child(img_rm_btn)
	sub.add_child(_make_image_fit_field(out[ei], "stretch"))

	# Per-resolution gate field(s) + on-take effects (flags/counters). Shared with rendition overlay
	# choices so an overlay option behaves exactly like a native one.
	_add_choice_resolution_and_effects(sub, out, ei, resolution, metric)
	# LEADS TO — the choice's target node, wired via connect mode.
	sub.add_child(_side_section_separator())
	sub.add_child(_side_field_label("LEADS TO"))
	var to_id: String = str(edge.get("to", ""))
	var target_lbl: Label = Label.new()
	target_lbl.text = (
		_graph_node_label(to_id) if to_id != "" else "(not set — ends the run on this choice)"
	)
	target_lbl.add_theme_color_override(
		"font_color", UITheme.SUCCESS if to_id != "" else UITheme.DARK_TEXT
	)
	target_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_child(target_lbl)

	var connecting: bool = _owner._connecting_from == node_id and _owner._connecting_edge_idx == ei
	var conn_btn: Button = UITheme.make_icon_btn(
		"✕ CANCEL CONNECT" if connecting else "🔗 CONNECT TO…", false, UITheme.AMBER
	)
	conn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	conn_btn.pressed.connect(func() -> void: _owner._begin_connect_fork_edge(node_id, ei))
	sub.add_child(conn_btn)
	if to_id != "":
		var clear_btn: Button = UITheme.make_icon_btn(
			"✂ CLEAR (END ON THIS CHOICE)", false, UITheme.PURPLE_MID
		)
		clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		clear_btn.pressed.connect(func() -> void: _owner._clear_fork_edge(node_id, ei))
		sub.add_child(clear_btn)

	return panel


# Short readable label for a graph node (used by the fork choice "LEADS TO" line).
func _graph_node_label(node_id: String) -> String:
	var nodes: Dictionary = _owner._graph_model.get("nodes", {})
	if not nodes.has(node_id):
		return "(missing node)"
	var n: Dictionary = nodes[node_id]
	var d: Dictionary = n.get("data", {})
	match str(n.get("type", "")):
		"round":
			var rn: String = str(d.get("name", "")).strip_edges()
			return "Round — %s" % (rn if rn != "" else "(unnamed)")
		"shop":
			var sn: String = str(d.get("title", "")).strip_edges()
			return "Shop — %s" % (sn if sn != "" else "(unnamed)")
		"storyboard":
			var sbn: String = str(d.get("name", "")).strip_edges()
			return "Storyboard — %s" % (sbn if sbn != "" else "(unnamed)")
		"fork":
			var fn: String = str(d.get("title", "")).strip_edges()
			return "Fork — %s" % (fn if fn != "" else "(unnamed)")
	return node_id


# Test-play controls block: the "Test From Here" button plus the seed inputs.
# `item` carries the node_id to launch from; `arr` is vestigial (graph mode passes []),
# kept only for the shared _save_and_test_from signature.
func _make_test_controls(item: Dictionary, arr: Array) -> Control:
	# Collapsible "Test From Here" group: the play action plus its score / coin / flag seeds. Collapsed
	# by default to cut side-panel clutter; the open/closed state is persisted on the owner so it
	# survives the panel rebuild that fires on every node selection.
	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var expanded: bool = bool(_owner._test_panel_expanded)
	var toggle_btn: Button = Button.new()
	toggle_btn.text = ("▾  TEST FROM HERE" if expanded else "▸  TEST FROM HERE")
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = expanded
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toggle_btn.tooltip_text = UITheme.wrap_tip(
		"Save the journey and play it from this node, with optional starting score / coins / flags."
	)
	UITheme.style_button(toggle_btn, UITheme.PURPLE_MID)
	wrapper.add_child(toggle_btn)

	var panel: VBoxContainer = VBoxContainer.new()
	panel.add_theme_constant_override("separation", 4)
	panel.visible = expanded
	wrapper.add_child(panel)

	# Primary action: save the journey and play the real runtime starting at this node.
	var btn: Button = UITheme.make_icon_btn("▶  PLAY FROM HERE", false, UITheme.SUCCESS)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.tooltip_text = UITheme.wrap_tip(
		"Save the journey and play it in the real runtime starting at this node."
	)
	btn.pressed.connect(func() -> void: _owner._save_and_test_from(item, arr))
	panel.add_child(btn)

	# Starting score / coins for the preview. Mainly for Conditional / Sacrifice
	# forks, which read last-round score and coin balance to resolve. Persist on
	# the owner so they survive selection changes.
	panel.add_child(_side_field_label("TEST SEEDS  (SCORE / COINS)"))
	var seed_row: HBoxContainer = HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 6)
	seed_row.add_child(
		_make_seed_spin(_owner._test_seed_score, func(v: int) -> void: _owner._test_seed_score = v)
	)
	seed_row.add_child(
		_make_seed_spin(_owner._test_seed_coins, func(v: int) -> void: _owner._test_seed_coins = v)
	)
	panel.add_child(seed_row)

	# Pre-set flags for the test run, so flag-gated forks can be exercised from a mid-journey node.
	panel.add_child(_side_field_label("SEED FLAGS  (COMMA-SEPARATED)"))
	var flag_edit: LineEdit = LineEdit.new()
	flag_edit.placeholder_text = "e.g. spared_boss"
	flag_edit.text = ", ".join(
		PackedStringArray(JourneyData.clean_flag_list(_owner._test_seed_flags))
	)
	UITheme.style_line_edit(flag_edit)
	flag_edit.text_changed.connect(
		func(v: String) -> void:
			_owner._test_seed_flags = JourneyData.clean_flag_list(Array(v.split(",")))
	)
	panel.add_child(flag_edit)

	# Pre-grant items for the run, so item-gated forks / shops can be exercised from a mid-journey node.
	panel.add_child(_side_field_label("SEED ITEMS"))
	var seed_item_entries: Array = []  # [{id, label}] — built-ins then journey custom items
	for k: String in _all_item_ids():
		seed_item_entries.append(
			{"id": k, "label": str(InventoryService.GetItemData(k).get("name", k))}
		)
	for it: Dictionary in _owner._journey_items:
		var iid: String = str(it.get("id", ""))
		if iid != "":
			seed_item_entries.append({"id": iid, "label": "%s  (custom)" % str(it.get("name", ""))})
	var seed_items_dd: MultiSelectDropdown = MultiSelectDropdown.new()
	seed_items_dd.empty_text = "None"
	seed_items_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(seed_items_dd)  # add first so _ready wires the popup, then populate
	seed_items_dd.set_options(seed_item_entries)
	seed_items_dd.set_selected(_owner._test_seed_items)
	UITheme.style_menu_button(seed_items_dd)
	seed_items_dd.selection_changed.connect(func(ids: Array) -> void: _owner._test_seed_items = ids)

	# Pre-set counters for the run (name:value), so counter-gated forks can be exercised.
	panel.add_child(_side_field_label("SEED COUNTERS  (name:value, comma-separated)"))
	var counter_edit: LineEdit = LineEdit.new()
	counter_edit.placeholder_text = "e.g. belt:2, arousal:3"
	counter_edit.text = JourneyData.counter_deltas_to_text(
		JourneyData.clean_counter_deltas(_owner._test_seed_counters)
	)
	UITheme.style_line_edit(counter_edit)
	counter_edit.text_changed.connect(
		func(v: String) -> void: _owner._test_seed_counters = JourneyData.parse_counter_deltas(v)
	)
	panel.add_child(counter_edit)

	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			toggle_btn.text = ("▾  TEST FROM HERE" if pressed else "▸  TEST FROM HERE")
			panel.visible = pressed
			_owner._test_panel_expanded = pressed
	)
	return wrapper


# One expanding integer SpinBox for the test-seed row, writing through `setter`.
func _make_seed_spin(value: int, setter: Callable) -> SpinBox:
	var spin: SpinBox = SpinBox.new()
	spin.min_value = 0
	spin.max_value = 9999999
	spin.step = 1
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(func(v: float) -> void: setter.call(int(v)))
	return spin


# Group-action panel shown when 2+ nodes are selected. Lists the selection and
# offers Copy / Cut / Delete and block Move Up / Down — all routed to the owner's
# set-based operations. No per-field editing while multiple are selected.

# ── Internal: per-type editors ──────────────────────────────────────────────


# Dispatches to the right inline editor based on item type. The editors work directly
# on the passed array reference (arr = [node.data]), so field edits persist into the
# graph node in place.
func _build_side_panel_editor(
	container: VBoxContainer,
	item: Dictionary,
	arr: Array,
	idx: int,
	reselect_override: Callable = Callable()
) -> void:
	var item_type: String = item.get("type", "round")

	var hdr: Label = Label.new()
	var accent: Color
	match item_type:
		"round":
			hdr.text = "// ROUND //"
			accent = UITheme.PURPLE_BRIGHT
		"shop":
			hdr.text = "// SHOP //"
			accent = UITheme.PURPLE_BRIGHT
		"storyboard":
			hdr.text = "// STORYBOARD //"
			accent = UITheme.STORYBOARD
		"checkpoint":
			hdr.text = "// CHECKPOINT //"
			accent = UITheme.AMBER
		"loop_start":
			hdr.text = "// LOOP START //"
			accent = UITheme.TOXIC_GREEN
		"loop_end":
			hdr.text = "// LOOP END //"
			accent = UITheme.TOXIC_GREEN
		_:
			hdr.text = "// ITEM //"
			accent = UITheme.PURPLE_MID
	hdr.add_theme_color_override("font_color", accent)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	container.add_child(hdr)

	# Called by the editors after a structural change (move / delete / add line) to re-show the
	# node (the graph editor passes a re-show-by-node-id callback).
	var reselect: Callable = reselect_override

	match item_type:
		"round":
			container.add_child(_make_side_round_editor(arr, idx, reselect))
		"shop":
			container.add_child(_make_side_shop_editor(arr, idx))
		"storyboard":
			container.add_child(_make_side_storyboard_editor(arr, idx, reselect))
		"checkpoint":
			container.add_child(_make_side_checkpoint_editor(arr, idx))
		"loop_start":
			container.add_child(_make_side_loop_start_editor())
		"loop_end":
			container.add_child(_make_side_loop_editor(arr, idx, reselect))


# A checkpoint node's editor: just an optional banner label. The save point itself needs no
# config — reaching the node offers Save & Quit / Continue at runtime.
func _make_side_checkpoint_editor(arr: Array, idx: int) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)

	var hint: Label = Label.new()
	hint.text = "A SAVE POINT BETWEEN ROUNDS. PLAYERS REACHING IT CAN SAVE & QUIT TO RESUME FROM HERE LATER, OR CONTINUE. PLACE IT BEFORE A ROUND YOU WANT TO ACT AS A CHECKPOINT."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(hint)

	col.add_child(_side_field_label("LABEL  (OPTIONAL)"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "e.g. End of Act 1"
	name_edit.text = str(arr[idx].get("name", ""))
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(val: String) -> void: arr[idx]["name"] = val)
	col.add_child(name_edit)

	return col


# A Loop Start marker's editor: nothing to configure — it just names where its pair's replay begins.
# The exit rules live on the paired Loop End.
func _make_side_loop_start_editor() -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	var hint: Label = Label.new()
	hint.text = "MARKS THE TOP OF A LOOPED STRETCH. EVERYTHING WIRED FROM HERE DOWN TO ITS LOOP END PLAYS AGAIN EACH TIME. THE EXIT RULES LIVE ON THE LOOP END."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(hint)
	return col


# The Loop End editor. The End replays the body from its paired Loop Start (loop_to) until an exit
# condition is met, then continues down its out-edge. The pairing is automatic (created with the Start),
# so there's no back-target picker — just the exit rules, a plain-English read-back of the whole loop, and
# the wired REPLAY FROM / CONTINUES TO targets surfaced so nothing about the flow stays hidden.
func _make_side_loop_editor(arr: Array, idx: int, reselect: Callable) -> Control:
	var data: Dictionary = arr[idx]
	var loop_id: String = _find_node_id_for_data(data)
	var conds: Array = data.get("loop_conditions", [])
	var combine_all: bool = str(data.get("loop_combine", "any")) == "all"
	var exit_label: String = _loop_exit_target_label(loop_id)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)

	# Plain-English read-back of the whole loop, so the author can see what they built at a glance.
	col.add_child(_loop_readback_card(data, conds, combine_all, exit_label))

	# EXIT WHEN — the condition list. The ANY/ALL combine only means something with 2+ conditions, so it's
	# hidden until then (with 0–1 conditions it's just noise).
	col.add_child(_side_field_label("EXIT WHEN"))
	if conds.size() >= 2:
		var combine_dd: OptionButton = OptionButton.new()
		combine_dd.add_item("ANY condition is met", 0)
		combine_dd.add_item("ALL conditions are met", 1)
		combine_dd.selected = 1 if combine_all else 0
		combine_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_option_button(combine_dd)
		combine_dd.item_selected.connect(
			func(i: int) -> void:
				data["loop_combine"] = "all" if i == 1 else "any"
				reselect.call(0)
		)
		col.add_child(combine_dd)

	if conds.is_empty():
		var empty: Label = Label.new()
		empty.text = "No exit rule — the body plays once, then continues. Add a rule to loop it."
		empty.add_theme_color_override("font_color", UITheme.SEPARATOR)
		empty.add_theme_font_size_override("font_size", 10)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(empty)
	for ci: int in conds.size():
		col.add_child(_make_loop_condition_row(data, ci, reselect))

	var add_btn: Button = UITheme.make_icon_btn("＋ ADD CONDITION", false, UITheme.TOXIC_GREEN)
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(
		func() -> void:
			var list: Array = data.get("loop_conditions", [])
			list.append(_default_loop_condition("repeats"))
			data["loop_conditions"] = list
			reselect.call(0)
	)
	col.add_child(add_btn)

	col.add_child(_side_section_separator())

	# REPLAY FROM — the paired Start, read-only (the pairing is automatic).
	col.add_child(_side_field_label("REPLAY FROM"))
	col.add_child(UITheme.make_tag_chip("▸ " + _loop_paired_start_label(data), UITheme.TOXIC_GREEN))

	# CONTINUES TO — the wired exit, surfaced so it's never invisible. Warns when nothing is wired yet.
	col.add_child(_side_field_label("CONTINUES TO"))
	if exit_label == "":
		col.add_child(UITheme.make_tag_chip("⚠ not wired — journey ends here", UITheme.AMBER))
	else:
		col.add_child(UITheme.make_tag_chip("▷ " + exit_label, UITheme.PURPLE_BRIGHT))
	return col


# A green-tinted card holding the plain-English read-back sentence for a Loop End.
func _loop_readback_card(
	data: Dictionary, conds: Array, combine_all: bool, exit_label: String
) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.TOXIC_GREEN.r, UITheme.TOXIC_GREEN.g, UITheme.TOXIC_GREEN.b, 0.08)
	sb.border_color = Color(
		UITheme.TOXIC_GREEN.r, UITheme.TOXIC_GREEN.g, UITheme.TOXIC_GREEN.b, 0.4
	)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 9
	sb.content_margin_bottom = 9
	panel.add_theme_stylebox_override("panel", sb)
	var lbl: Label = Label.new()
	lbl.text = _loop_readback_text(data, conds, combine_all, exit_label)
	lbl.add_theme_color_override("font_color", Color(0.85, 1.0, 0.8))
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(lbl)
	return panel


# The read-back sentence: "Replays from Loop Start until <conditions>, then continues to <exit>."
func _loop_readback_text(
	data: Dictionary, conds: Array, combine_all: bool, exit_label: String
) -> String:
	var start: String = _loop_paired_start_label(data)
	var cont: String = ("continues to %s" % exit_label) if exit_label != "" else "the journey ends"
	if conds.is_empty():
		return "Plays the stretch from %s once, then %s." % [start, cont]
	return (
		"Replays from %s until %s, then %s."
		% [start, _loop_conditions_phrase(conds, combine_all), cont]
	)


# A natural-language phrase for the exit conditions, joined by "and" (ALL) or "or" (ANY).
func _loop_conditions_phrase(conds: Array, combine_all: bool) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for c: Dictionary in conds:
		parts.append(_loop_condition_phrase(c))
	return (" and " if combine_all else " or ").join(parts)


func _loop_condition_phrase(c: Dictionary) -> String:
	match str(c.get("kind", "repeats")):
		"repeats":
			var n: int = int(c.get("count", 1))
			return "the player has looped %d %s" % [n, "time" if n == 1 else "times"]
		"counter":
			var cn: String = str(c.get("counter", "")).strip_edges()
			var name: String = cn if cn != "" else "a counter"
			var verb: String = "drops to" if str(c.get("cmp", "gte")) == "lte" else "reaches"
			return "%s %s %d" % [name, verb, int(c.get("threshold", 0))]
		"flag":
			var fn: String = str(c.get("flag", "")).strip_edges()
			return "%s is set" % [fn if fn != "" else "a flag"]
		"item":
			return "the player has %s" % _loop_item_name(str(c.get("item", "")))
	return "its rule is met"


# The paired Loop Start's label (it carries no name, so just the marker name — or a note if unpaired).
func _loop_paired_start_label(data: Dictionary) -> String:
	var to: String = str(data.get("loop_to", ""))
	var nodes: Dictionary = _owner._graph_model.get("nodes", {})
	if to == "" or not nodes.has(to):
		return "Loop Start (unpaired)"
	return "Loop Start"


# The label of the End's wired exit target (its single out-edge), or "" when nothing is wired.
func _loop_exit_target_label(loop_id: String) -> String:
	var nodes: Dictionary = _owner._graph_model.get("nodes", {})
	var out: Array = (nodes.get(loop_id, {}) as Dictionary).get("out", [])
	if out.is_empty():
		return ""
	var to: String = str((out[0] as Dictionary).get("to", ""))
	if to == "" or not nodes.has(to):
		return ""
	return _loop_node_label(to)


# A readable item name (built-in or journey custom) for an item id, for the read-back phrasing.
func _loop_item_name(item_id: String) -> String:
	if item_id == "":
		return "an item"
	if item_id in InventoryService.GetBuiltinItemIds():
		return str(InventoryService.GetItemData(item_id).get("name", item_id))
	for it: Dictionary in _owner._journey_items:
		if str(it.get("id", "")) == item_id:
			return str(it.get("name", item_id))
	return item_id


# One row in a loop's exit-condition list: a KIND picker, the params that kind needs, and a ✕ to remove
# it. Switching kind swaps in that kind's default params. Edits write straight into conds[ci].
func _make_loop_condition_row(data: Dictionary, ci: int, reselect: Callable) -> Control:
	var conds: Array = data.get("loop_conditions", [])
	var cond: Dictionary = conds[ci]

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var kinds: Array = ["repeats", "counter", "flag", "item"]
	var kind_labels: Array = ["After N loops", "Counter ≥ value", "Flag is set", "Has item"]
	var kind_dd: OptionButton = OptionButton.new()
	for i: int in kinds.size():
		kind_dd.add_item(str(kind_labels[i]), i)
	kind_dd.selected = maxi(0, kinds.find(str(cond.get("kind", "repeats"))))
	kind_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(kind_dd)
	kind_dd.item_selected.connect(
		func(i: int) -> void:
			conds[ci] = _default_loop_condition(str(kinds[i]))
			reselect.call(0)
	)
	head.add_child(kind_dd)
	var rm: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	rm.pressed.connect(
		func() -> void:
			conds.remove_at(ci)
			reselect.call(0)
	)
	head.add_child(rm)
	box.add_child(head)

	match str(cond.get("kind", "repeats")):
		"repeats":
			box.add_child(_loop_int_field("LOOP COUNT", cond, "count", 1))
		"counter":
			box.add_child(_loop_text_field("COUNTER NAME", cond, "counter", "e.g. belt"))
			box.add_child(_loop_cmp_field(cond, reselect))
			box.add_child(_loop_int_field("VALUE", cond, "threshold", 0))
		"flag":
			box.add_child(_loop_text_field("FLAG NAME", cond, "flag", "e.g. found_key"))
		"item":
			box.add_child(_loop_item_field(cond))
	return box


# A fresh condition dict for `kind`, pre-filled so a just-added row is already save-valid.
func _default_loop_condition(kind: String) -> Dictionary:
	match kind:
		"counter":
			return {"kind": "counter", "counter": "", "threshold": 1}
		"flag":
			return {"kind": "flag", "flag": ""}
		"item":
			return {"kind": "item", "item": ""}
		_:
			return {"kind": "repeats", "count": 3}


# The ≥ / ≤ picker for a counter condition. "gte" (default) exits when the counter climbs to the value;
# "lte" is a count-down — exit when it drops to the value. Reselects so the read-back re-renders.
func _loop_cmp_field(target: Dictionary, reselect: Callable) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.add_child(_side_field_label("COMPARISON"))
	var values: Array = ["gte", "lte"]
	var dd: OptionButton = OptionButton.new()
	dd.add_item("Reaches (≥) the value", 0)
	dd.add_item("Drops to (≤) the value", 1)
	dd.selected = maxi(0, values.find(str(target.get("cmp", "gte"))))
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(dd)
	dd.item_selected.connect(
		func(i: int) -> void:
			target["cmp"] = str(values[i])
			reselect.call(0)
	)
	col.add_child(dd)
	return col


func _loop_int_field(label: String, target: Dictionary, key: String, min_v: int) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.add_child(_side_field_label(label))
	var spin: SpinBox = SpinBox.new()
	spin.min_value = min_v
	spin.max_value = 9999
	spin.step = 1
	spin.value = float(int(target.get(key, min_v)))
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(func(v: float) -> void: target[key] = int(v))
	col.add_child(spin)
	return col


func _loop_text_field(
	label: String, target: Dictionary, key: String, placeholder: String
) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.add_child(_side_field_label(label))
	var edit: LineEdit = LineEdit.new()
	edit.placeholder_text = placeholder
	edit.text = str(target.get(key, ""))
	UITheme.style_line_edit(edit)
	edit.text_changed.connect(func(v: String) -> void: target[key] = v.strip_edges())
	col.add_child(edit)
	return col


# The item picker for a "has item" loop condition — built-ins then journey custom items, same set as
# the give / remove pickers. Selecting writes the item id to cond["item"].
func _loop_item_field(target: Dictionary) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.add_child(_side_field_label("ITEM"))
	var entries: Array = []
	for k: String in InventoryService.GetBuiltinItemIds():
		entries.append({"id": k, "label": str(InventoryService.GetItemData(k).get("name", k))})
	for it: Dictionary in _owner._journey_items:
		var iid: String = str(it.get("id", ""))
		if iid != "":
			entries.append({"id": iid, "label": "%s  (custom)" % str(it.get("name", ""))})
	var dd: OptionButton = OptionButton.new()
	var cur: String = str(target.get("item", ""))
	var sel: int = 0
	for i: int in entries.size():
		var e: Dictionary = entries[i]
		dd.add_item(str(e["label"]), i)
		dd.set_item_metadata(i, str(e["id"]))
		if str(e["id"]) == cur:
			sel = i
	dd.selected = sel
	if cur == "" and not entries.is_empty():
		target["item"] = str((entries[0] as Dictionary)["id"])  # default to first so save is valid
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(dd)
	dd.item_selected.connect(func(i: int) -> void: target["item"] = str(dd.get_item_metadata(i)))
	col.add_child(dd)
	return col


# A short "Type — Name" label for a node id (used for the End's CONTINUES-TO target).
func _loop_node_label(nid: String) -> String:
	var node: Dictionary = (_owner._graph_model.get("nodes", {}) as Dictionary).get(nid, {})
	var t: String = str(node.get("type", ""))
	var nm: String = str((node.get("data", {}) as Dictionary).get("name", "")).strip_edges()
	var pretty: String = t.capitalize() if t != "" else "Node"
	return "%s — %s" % [pretty, nm] if nm != "" else pretty


# The graph node id whose live data dict IS `data` (reference identity — arr[0] IS node.data, so two
# loop nodes with identical values never collide the way value-equality would).
func _find_node_id_for_data(data: Dictionary) -> String:
	var nodes: Dictionary = _owner._graph_model.get("nodes", {})
	for nid: String in nodes.keys():
		if is_same((nodes[nid] as Dictionary).get("data"), data):
			return str(nid)
	return ""


# Whether the journey has at least one Loop (a Loop End node) — gates the "show loops on map" toggle.
func _journey_has_loops() -> bool:
	for n: Dictionary in (_owner._graph_model.get("nodes", {}) as Dictionary).values():
		if str(n.get("type", "")) == "loop_end":
			return true
	return false


# ── Internal: small helpers ─────────────────────────────────────────────────


func _side_field_label(text: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.uppercase = true
	return lbl


func _side_section_separator() -> Control:
	var spacer: Control = Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	return spacer


# A visible horizontal divider line (thin, in the separator colour) marking a major break between
# side-panel groups — heavier than the subtle _side_section_separator spacer. Used between a node's
# content editor and its operations block (connect / duplicate / delete / add).
func _side_divider_line() -> HSeparator:
	var line: HSeparator = HSeparator.new()
	line.add_theme_constant_override("separation", 13)
	var sb: StyleBoxLine = StyleBoxLine.new()
	sb.color = UITheme.SEPARATOR
	sb.thickness = 1
	line.add_theme_stylebox_override("separator", sb)
	return line


# Fills `lbl` with a round's PLAYED funscript length + action count (e.g. "4:32 · 812 actions"), or flags
# an empty/missing script. Any pending segments — trims and section LOOPS — are baked in, so the readout is
# what will actually play (a looped section shows its repeated length, with the raw length for reference).
# Cleared when no funscript is set. Takes the round data so it can read those segments.
func _update_funscript_readout(lbl: Label, round_data: Dictionary) -> void:
	var path: String = str(round_data.get("funscript_path", ""))
	if path == "":
		lbl.text = ""
		return
	var stats: Dictionary = JourneyData.read_funscript_stats(path)
	if int(stats.get("count", 0)) <= 0:
		lbl.add_theme_color_override("font_color", UITheme.ERROR_SOFT)
		lbl.text = "⚠ funscript has no actions"
		return
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	var raw_ms: int = int(stats.get("length_ms", 0))
	var segments: Array = JourneyData.normalize_segments(round_data)
	if segments.is_empty():
		lbl.text = "%s  ·  %d actions" % [_format_duration(raw_ms), int(stats.get("count", 0))]
		return
	var played: Array = JourneyData.build_edl_action_points(
		JourneyData.read_funscript_actions(path), segments
	)
	var played_ms: int = int((played[-1] as Vector2).x) if not played.is_empty() else 0
	lbl.text = (
		"%s  ·  %d actions  (from %s raw)"
		% [_format_duration(played_ms), played.size(), _format_duration(raw_ms)]
	)


# Formats milliseconds as m:ss for the funscript readout.
func _format_duration(ms: int) -> String:
	var total_s: int = int(round(ms / 1000.0))
	return "%d:%02d" % [total_s / 60, total_s % 60]


# ── Internal: round / shop / storyboard / fork inline editors ──────────────


func _make_side_round_editor(arr: Array, idx: int, reselect: Callable) -> Control:
	var round_data: Dictionary = arr[idx]
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	# Multi-drop hint — shown at the top so it's the first thing the user sees.
	var drop_hint: Label = Label.new()
	drop_hint.text = "TIP: DROP ALL SCRIPTS AT ONCE TO AUTO-ROUTE BY AXIS"
	drop_hint.add_theme_color_override(
		"font_color", Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.7)
	)
	drop_hint.add_theme_font_size_override("font_size", 10)
	drop_hint.uppercase = true
	drop_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	drop_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(drop_hint)

	col.add_child(_side_field_label("ROUND NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Round name..."
	name_edit.text = round_data.get("name", "")
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(val: String) -> void: arr[idx]["name"] = val)
	col.add_child(name_edit)

	# A pool round's media lives in its encounter entries; skip the round's own media
	# section (video / funscript / preview / trim / axis / vib) when it's a pool round.
	if str(arr[idx].get("round_type", "normal")) != "pool":
		# ── Media & scripts ─────────────────────────────────────────────────────────
		col.add_child(_side_divider_line())
		col.add_child(_side_field_label("VIDEO FILE"))
		var video_zone: PanelContainer = DropZoneScript.new()
		video_zone.accepted_extensions = JourneyData.VIDEO_EXTENSIONS.duplicate()
		video_zone.picker_title = "Select Video"
		video_zone.picker_filters = [
			"*.mp4,*.m4v,*.mkv,*.avi,*.mov,*.wmv,*.webm ; Video Files", "*.* ; All Files"
		]
		video_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(video_zone)
		if round_data.get("video_path", "") != "":
			video_zone.call_deferred("set_file", round_data["video_path"], false)
		video_zone.file_dropped.connect(
			func(p: String) -> void:
				arr[idx]["video_path"] = p
				if (arr[idx].get("name", "") as String).strip_edges() == "":
					arr[idx]["name"] = p.get_file().get_basename()
				# Auto-fill the funscript + any secondary axis / vib scripts from same-
				# named siblings on disk, then rebuild so the DropZones show them.
				if ImportScanner.autofill_round_siblings(arr[idx], p):
					_owner._show_status("Auto-filled matching scripts from file names.", false)
					reselect.call(idx)
					return
				name_edit.text = arr[idx].get("name", "")
				_owner._refresh_graph()  # update the node's validation badge live
		)

		col.add_child(_side_section_separator())
		col.add_child(_side_field_label("FUNSCRIPT"))
		# Declared before the drop handler so the closure can refresh it in place.
		var fs_stats_lbl: Label = Label.new()
		fs_stats_lbl.add_theme_font_size_override("font_size", 11)
		fs_stats_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
		var fs_zone: PanelContainer = DropZoneScript.new()
		fs_zone.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
		fs_zone.picker_title = "Select Funscript"
		fs_zone.picker_filters = ["*.funscript,*.json ; Funscript Files", "*.* ; All Files"]
		fs_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Zone + inline ✕ remove (disabled until a funscript is set).
		var fs_rm: Button = UITheme.make_icon_btn(
			"✕", round_data.get("funscript_path", "") == "", UITheme.MAGENTA
		)
		fs_rm.tooltip_text = UITheme.wrap_tip("Remove funscript")
		fs_rm.pressed.connect(func() -> void: fs_zone.set_file(""))
		var fs_row: HBoxContainer = HBoxContainer.new()
		fs_row.add_theme_constant_override("separation", 6)
		fs_row.add_child(fs_zone)
		fs_row.add_child(fs_rm)
		col.add_child(fs_row)
		if round_data.get("funscript_path", "") != "":
			fs_zone.call_deferred("set_file", round_data["funscript_path"], false)
		fs_zone.file_dropped.connect(
			func(p: String) -> void:
				arr[idx]["funscript_path"] = p
				_update_funscript_readout(fs_stats_lbl, arr[idx])
				fs_rm.disabled = (p == "")
				# Removal (cleared zone): nothing to auto-fill or rename — just refresh.
				if p == "":
					_owner._refresh_graph()
					return
				if (arr[idx].get("name", "") as String).strip_edges() == "":
					arr[idx]["name"] = p.get_file().get_basename()
				# Auto-fill the video + any secondary axis / vib scripts from same-named
				# siblings on disk, then rebuild so the DropZones show them.
				if ImportScanner.autofill_round_siblings(arr[idx], p):
					_owner._show_status("Auto-filled matching scripts from file names.", false)
					reselect.call(idx)
					return
				name_edit.text = arr[idx].get("name", "")
				_owner._refresh_graph()  # update the node's validation badge live
		)
		# Length / action-count readout (sits just under the funscript zone).
		_update_funscript_readout(fs_stats_lbl, round_data)
		col.add_child(fs_stats_lbl)

		# Opens the round's clip editor: the funscript curve, any stroke modifiers the round
		# applies to it, the synced video, and the cut controls — one overlay
		# (_open_funscript_editor). Effect rounds also tune scale/clamp magnitudes live in
		# there, so the button advertises it. Enabled once a funscript is attached.
		var is_effect_round: bool = (
			JourneyData.normalize_effect_round(arr[idx]).get("round_type", "") == "effect"
		)
		var preview_btn: Button = UITheme.make_icon_btn(
			"📈 PREVIEW, CUT & TUNE" if is_effect_round else "📈 PREVIEW & CUT",
			round_data.get("funscript_path", "") == "",
			UITheme.CYAN
		)
		preview_btn.tooltip_text = (
			UITheme
			. wrap_tip(
				(
					"Preview the strokes against the video, set the cut window, and drag scale/clamp effects to tune them live."
					if is_effect_round
					else "Preview the strokes against the video and set the cut window."
				)
			)
		)
		preview_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		preview_btn.pressed.connect(func() -> void: _open_funscript_editor(arr, idx, reselect))
		col.add_child(preview_btn)

		# ── Segments (pending; baked at save) ───────────────────────────────────────
		# One section where trim and section-loop used to be two: both are segment lists now.
		col.add_child(_side_section_separator())
		col.add_child(_make_segments_section(arr[idx]))

		# Secondary device scripts (optional, collapsed) — they round out the media group.
		col.add_child(_side_section_separator())
		col.add_child(_make_axis_expander(arr, idx))

		col.add_child(_side_section_separator())
		col.add_child(_make_vib_expander(arr, idx))

	# ── Rewards & state ─────────────────────────────────────────────────────────
	col.add_child(_side_divider_line())
	col.add_child(_side_field_label("COINS AWARDED"))
	var coins_spin: SpinBox = SpinBox.new()
	coins_spin.min_value = 0
	coins_spin.max_value = 999999
	coins_spin.step = 1
	coins_spin.value = round_data.get("coins", 0)
	coins_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(coins_spin)
	coins_spin.value_changed.connect(func(v: float) -> void: arr[idx]["coins"] = int(v))
	col.add_child(coins_spin)

	# Optional item reward — granted (alongside coins) when the round ends. Same picker as the
	# storyboard reward; "None" clears it.
	col.add_child(_side_field_label("ITEM REWARD  (OPTIONAL)"))
	var item_values: Array = [""]
	var item_dd: OptionButton = OptionButton.new()
	item_dd.add_item("None")
	# Built-in items only (see _all_item_ids) so a test-play's leftover journey items don't duplicate.
	for k: String in InventoryService.GetBuiltinItemIds():
		item_values.append(k)
		item_dd.add_item(str(InventoryService.GetItemData(k).get("name", k)))
	# Journey-scoped custom items — the live edit model is authoritative.
	for it: Dictionary in _owner._journey_items:
		item_values.append(str(it.get("id", "")))
		item_dd.add_item("%s  (custom)" % str(it.get("name", "")))
	item_dd.selected = max(0, item_values.find(str(round_data.get("award_item", ""))))
	item_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(item_dd)
	_apply_item_tooltips(item_dd, item_values)
	item_dd.item_selected.connect(func(i: int) -> void: arr[idx]["award_item"] = item_values[i])
	col.add_child(item_dd)

	# Flags + counters this round sets when it plays (read by conditional forks downstream — e.g.
	# "+1 belt" after each encounter).
	col.add_child(_side_section_separator())
	col.add_child(_make_set_flags_field(arr[idx]))
	col.add_child(_make_set_counters_field(arr[idx]))
	col.add_child(_make_remove_items_field(arr[idx]))

	# ── Round behavior ───────────────────────────────────────────────────────────
	# (Checkpoints are their own node type now — added from the canvas, not a round flag.)
	col.add_child(_side_divider_line())
	col.add_child(_make_warmup_toggle(arr, idx))

	# Boss / Effect are the round's own twist and are mutually exclusive with each other. A POOL
	# round carries its type PER ENTRY instead (a rolled encounter can itself be a boss), so the
	# round-level Boss/Effect toggles are hidden for pool rounds — only the pool list is shown.
	if str(arr[idx].get("round_type", "normal")) != "pool":
		col.add_child(_side_section_separator())
		col.add_child(_make_boss_expander(arr, idx, reselect))

		col.add_child(_side_section_separator())
		col.add_child(_make_effect_expander(arr, idx, reselect))

	col.add_child(_side_section_separator())
	col.add_child(_make_pool_expander(arr, idx, reselect))

	# ── Templates (save this round's definition for reuse; apply a saved one) ─────
	col.add_child(_side_divider_line())
	col.add_child(_side_field_label("TEMPLATES"))
	col.add_child(_make_round_templates_section(arr, idx, reselect))
	return col


# Save-as-template + apply/delete for the current round. A template captures the whole round
# definition (media, type config, pool entries), so authors can reuse it instead of rebuilding
# — especially multi-entry pool rounds. See RoundTemplates.
func _make_round_templates_section(arr: Array, idx: int, reselect: Callable) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var hint: Label = Label.new()
	hint.text = "Save this round's full definition (media, type, pool entries) to reuse on other rounds. Applying overwrites this round. Media files must still exist on disk when you save the journey."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)

	var save_btn: Button = Button.new()
	save_btn.text = "★ SAVE ROUND AS TEMPLATE"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(save_btn, UITheme.PURPLE_MID)
	save_btn.pressed.connect(func() -> void: _prompt_save_round_template(arr, idx, reselect))
	box.add_child(save_btn)

	var tmpl_names: Array = RoundTemplates.names()
	if tmpl_names.is_empty():
		return box

	# Selector + explicit Apply / Delete (the dropdown only picks a target — selecting it must
	# not apply, or you couldn't delete without first overwriting the round).
	var dd: OptionButton = OptionButton.new()
	dd.add_item("Select a template…")
	dd.set_item_disabled(0, true)
	for n: String in tmpl_names:
		dd.add_item(str(n))
	dd.selected = 0
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(dd)
	box.add_child(dd)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	var apply_btn: Button = Button.new()
	apply_btn.text = "⧉ APPLY"
	apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(apply_btn, UITheme.PURPLE_MID)
	apply_btn.pressed.connect(
		func() -> void:
			if dd.selected <= 0:
				return
			var tname: String = str(tmpl_names[dd.selected - 1])
			RoundTemplates.apply_to(arr[idx], RoundTemplates.get_data(tname))
			_owner._show_status('Applied template "%s".' % tname, false)
			reselect.call(idx)
	)
	btn_row.add_child(apply_btn)
	var del_btn: Button = Button.new()
	del_btn.text = "🗑 DELETE"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(del_btn, UITheme.MAGENTA)
	del_btn.pressed.connect(
		func() -> void:
			if dd.selected <= 0:
				return
			var tname: String = str(tmpl_names[dd.selected - 1])
			RoundTemplates.remove(tname)
			_owner._show_status('Deleted template "%s".' % tname, false)
			reselect.call(idx)
	)
	btn_row.add_child(del_btn)
	box.add_child(btn_row)

	return box


# Small name-entry dialog for saving the current round as a template; rebuilds the panel on
# success so the new template shows in the apply selector.
func _prompt_save_round_template(arr: Array, idx: int, reselect: Callable) -> void:
	var dialog: ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Save Round Template"
	dialog.ok_button_text = "SAVE"
	var vb: VBoxContainer = VBoxContainer.new()
	var lbl: Label = Label.new()
	lbl.text = "Template name:"
	vb.add_child(lbl)
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "e.g. 3-clip encounter"
	name_edit.custom_minimum_size = Vector2(320, 0)
	name_edit.text = str(arr[idx].get("name", ""))
	vb.add_child(name_edit)
	dialog.add_child(vb)
	dialog.register_text_enter(name_edit)
	dialog.confirmed.connect(
		func() -> void:
			var nm: String = name_edit.text.strip_edges()
			if nm != "":
				RoundTemplates.add(nm, arr[idx])
				_owner._show_status('Saved template "%s".' % nm, false)
				reselect.call(idx)
			dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	_owner.add_child(dialog)
	dialog.popup_centered()
	name_edit.grab_focus()


func _make_side_shop_editor(arr: Array, idx: int) -> Control:
	var shop_data: Dictionary = arr[idx]
	# Backfill config defaults so first-time edits have keys to write to.
	if not shop_data.has("mode"):
		shop_data["mode"] = "pool"
	if not shop_data.has("count"):
		shop_data["count"] = 3
	if not shop_data.has("items"):
		shop_data["items"] = []
	if not shop_data.has("guaranteed"):
		shop_data["guaranteed"] = []
	if not shop_data.has("excluded"):
		shop_data["excluded"] = []
	if not shop_data.has("price_multiplier"):
		shop_data["price_multiplier"] = 1.0

	# Item registry — also bounds the pool-draw count, since a draw can never
	# yield more distinct items than exist. Clamp any stale/out-of-range count.
	var all_item_ids: Array = _all_item_ids()
	var item_count: int = all_item_ids.size()
	shop_data["count"] = clampi(int(shop_data.get("count", 3)), 1, max(1, item_count))

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	col.add_child(_side_field_label("SHOP TITLE"))
	var title_edit: LineEdit = LineEdit.new()
	title_edit.placeholder_text = "Shop title (optional)..."
	title_edit.text = shop_data.get("title", "")
	UITheme.style_line_edit(title_edit)
	title_edit.text_changed.connect(func(val: String) -> void: arr[idx]["title"] = val)
	col.add_child(title_edit)

	# Selection mode — random pool draw vs. a fixed authored lineup.
	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("ITEM SELECTION"))
	var mode_dd: OptionButton = OptionButton.new()
	mode_dd.add_item("RANDOM FROM POOL")  # index 0 → "pool"
	mode_dd.add_item("FIXED LINEUP")  # index 1 → "fixed"
	mode_dd.selected = 1 if shop_data.get("mode", "pool") == "fixed" else 0
	mode_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(mode_dd)
	col.add_child(mode_dd)

	# Item count — only consulted in pool mode; disabled in fixed mode where the
	# lineup length is the checklist itself. Clamped to [1, item registry size].
	col.add_child(_side_field_label("ITEMS SHOWN (POOL MODE)"))
	var count_spin: SpinBox = SpinBox.new()
	count_spin.min_value = 1
	count_spin.max_value = max(1, item_count)
	count_spin.step = 1
	count_spin.value = clampi(int(shop_data.get("count", 3)), 1, max(1, item_count))
	count_spin.editable = shop_data.get("mode", "pool") == "pool"
	count_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(count_spin)
	count_spin.value_changed.connect(func(v: float) -> void: arr[idx]["count"] = int(v))
	col.add_child(count_spin)

	# Two per-mode checklists over the same registry: fixed mode picks the exact
	# lineup ("items"); pool mode picks the always-included subset ("guaranteed" —
	# the rest of the lineup is drawn randomly). Both lists persist across mode
	# switches so toggling the dropdown is non-destructive.
	var fixed_section: VBoxContainer = _shop_item_multiselect(
		arr, idx, "items", "ITEMS", "PICK THE EXACT ITEMS THIS SHOP SELLS.", all_item_ids
	)
	fixed_section.visible = shop_data.get("mode", "pool") == "fixed"
	col.add_child(fixed_section)

	var pool_section: VBoxContainer = _shop_item_multiselect(
		arr,
		idx,
		"guaranteed",
		"GUARANTEED IN LINEUP",
		"CHECKED ITEMS ALWAYS APPEAR; THE REST OF THE LINEUP IS DRAWN RANDOMLY.",
		all_item_ids
	)
	pool_section.visible = shop_data.get("mode", "pool") == "pool"
	col.add_child(pool_section)

	# Exclusions bar items from the random draw. Pool mode only — in fixed mode the lineup IS
	# the authored list, so "never draw this" has nothing to act on.
	var excluded_section: VBoxContainer = _shop_item_multiselect(
		arr,
		idx,
		"excluded",
		"NEVER DRAWN",
		"CHECKED ITEMS ARE KEPT OUT OF THE RANDOM DRAW. AN ITEM THAT IS ALSO GUARANTEED STILL APPEARS.",
		all_item_ids
	)
	excluded_section.visible = shop_data.get("mode", "pool") == "pool"
	col.add_child(excluded_section)

	mode_dd.item_selected.connect(
		func(sel: int) -> void:
			arr[idx]["mode"] = "fixed" if sel == 1 else "pool"
			fixed_section.visible = sel == 1
			pool_section.visible = sel == 0
			excluded_section.visible = sel == 0
			count_spin.editable = sel == 0
	)

	# Price multiplier — applied on top of each item's base price.
	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("PRICE MULTIPLIER"))
	var mult_spin: SpinBox = SpinBox.new()
	mult_spin.min_value = 0.1
	mult_spin.max_value = 100.0
	mult_spin.step = 0.1
	mult_spin.value = float(shop_data.get("price_multiplier", 1.0))
	mult_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(mult_spin)
	mult_spin.value_changed.connect(func(v: float) -> void: arr[idx]["price_multiplier"] = v)
	col.add_child(mult_spin)
	return col


# ✂ SEGMENTS — read-only summary of the round's cut plus the way into the editor. Consumed by
# the next save: the video is cut to the list and every funscript rebased to match, so
# journey.json never carries segments. After a save the cut copy is the round's new baseline
# (tighter re-cuts possible, widening is not).
#
# No numeric fields here on purpose. The old ✂ TRIM / 🔁 LOOP SECTION blocks could express one
# window and one loop; a segment list can't be typed into two text boxes, and keeping partial
# fields beside the timeline would be two competing spellings of the same cut.
func _make_segments_section(round_data: Dictionary) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_side_field_label("✂ SEGMENTS  (BAKED AT SAVE)"))

	var segs: Array = JourneyData.normalize_segments(round_data)
	var readout: Label = Label.new()
	readout.add_theme_font_size_override("font_size", 11)
	readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if segs.is_empty():
		readout.text = "NO CUT — THE FULL CLIP PLAYS."
		readout.add_theme_color_override("font_color", UITheme.SEPARATOR)
	else:
		var total: int = JourneyData.segments_total_ms(segs, int(round_data.get("length_ms", 0)))
		var first: Dictionary = segs[0]
		var f_out: int = int(first.get("out_ms", 0))
		if segs.size() == 1:
			readout.text = (
				"CUT %s – %s"
				% [
					JourneyData.ms_to_mmss(int(first.get("in_ms", 0))),
					JourneyData.ms_to_mmss(f_out) if f_out > 0 else "END",
				]
			)
		else:
			readout.text = (
				"%d SEGMENTS%s"
				% [segs.size(), ("  —  %s" % JourneyData.ms_to_mmss(total)) if total > 0 else ""]
			)
		readout.add_theme_color_override("font_color", UITheme.TOXIC_GREEN)
	box.add_child(readout)

	# No button here on purpose: the clip editor opens from 📈 PREVIEW & CUT directly above, and
	# a second button beside this summary was the same action under a different name.
	var hint: Label = Label.new()
	hint.text = "EDIT IN 📈 PREVIEW & CUT ABOVE."
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	box.add_child(hint)
	return box


# Opens the round's clip editor — preview, cut and tune. ONE button opens it (📈 PREVIEW & CUT);
# the ✂ SEGMENTS block below is a read-only summary. There were briefly two buttons calling this
# with identical arguments under different names, which read as two different features.
#
# `reselect` rebuilds the side panel after the overlay writes back (the summary and the node
# badge both read the round's data).
func _open_funscript_editor(arr: Array, idx: int, reselect: Callable) -> void:
	# Effect rounds get live stroke tuning; the callback persists (and prunes to the catalog
	# default) as the author drags a magnitude in the preview.
	var on_tune: Callable = Callable()
	if JourneyData.normalize_effect_round(arr[idx]).get("round_type", "") == "effect":
		on_tune = func(ref_name: String, key: String, value: Variant) -> void:
			var def: Variant = JourneyData.effect_entry(ref_name).get(key, null)
			if def != null and is_equal_approx(float(value), float(def)):
				_set_effect_override(arr, idx, ref_name, key, null)
			else:
				_set_effect_override(arr, idx, ref_name, key, value)
	FunscriptPreview.new().open(
		_owner,
		str(arr[idx].get("funscript_path", "")),
		str(arr[idx].get("video_path", "")),
		_round_preview_modifiers(arr[idx]),
		str(arr[idx].get("name", "")),
		_round_preview_label(arr[idx]),
		# normalize_segments migrates a round still carrying the legacy trim / section-loop
		# fields, so opening the editor on an old round shows its cut as segments.
		JourneyData.normalize_segments(arr[idx]),
		func(segs: Array) -> void:
			arr[idx]["segments"] = segs
			# normalize_segments prefers `segments`, so leaving the legacy keys would leave
			# stale fields that silently do nothing.
			arr[idx].erase("trim_start_ms")
			arr[idx].erase("trim_end_ms")
			arr[idx].erase("loop_in_ms")
			arr[idx].erase("loop_out_ms")
			arr[idx].erase("loop_count")
			reselect.call(idx),
		on_tune,
		# Live sensory preview: the round's ticked sensory effects, their current intensities,
		# and a writer. The side panel keeps its own sliders — the editor needs a funscript to
		# open, so it can't be the only way in.
		JourneyData.catalog_subset(
			JourneyData.SENSORY_CATALOG,
			JourneyData.normalize_effect_round(arr[idx]).get("sensory", [])
		),
		arr[idx].get("sensory_intensity", {}),
		func(sname: String, value: float) -> void: _set_sensory_intensity(arr, idx, sname, value)
	)


# ⚖ ON ARRIVAL — the audit's view of the player state reaching this node:
# coins/last-round-score bounds (interval walk) + averages and reach share
# (Monte-Carlo). Reads the owner's cached audit; a structural edit invalidates
# it, so the block offers COMPUTE (no cache) or ⟳ REFRESH (stale-able cache).
func _make_arrival_audit_block(node_id: String) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_side_field_label("⚖ ON ARRIVAL"))

	var info: Dictionary = _owner.audit_arrival_info(node_id)
	if info.is_empty():
		var hint: Label = Label.new()
		hint.text = "COMPUTE THE AUDIT TO SEE COINS / SCORE ARRIVING AT THIS NODE."
		hint.add_theme_color_override(
			"font_color",
			Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.7)
		)
		hint.add_theme_font_size_override("font_size", 10)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(hint)
	else:
		box.add_child(
			_arrival_stat_row(
				"COINS",
				(
					"♦ %d – %d   (avg ≈ %d)"
					% [info["coins_lo"], info["coins_hi"], roundi(info["coins_avg"])]
				)
			)
		)
		box.add_child(
			_arrival_stat_row(
				"LAST SCORE",
				(
					"%d – %d   (avg ≈ %d)"
					% [info["score_lo"], info["score_hi"], roundi(info["score_avg"])]
				)
			)
		)
		box.add_child(
			_arrival_stat_row("REACHED IN", "%.0f%% OF SIMULATED RUNS" % float(info["seen_pct"]))
		)

	var btn: Button = UITheme.make_icon_btn(
		"⚖ COMPUTE" if info.is_empty() else "⟳ REFRESH", false, UITheme.PURPLE_MID
	)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func() -> void: _owner.refresh_arrival_audit(node_id))
	box.add_child(btn)
	return box


func _arrival_stat_row(key_text: String, value_text: String) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var key: Label = Label.new()
	key.text = key_text
	key.custom_minimum_size = Vector2(84, 0)
	key.add_theme_color_override("font_color", UITheme.PURPLE_MID)
	key.add_theme_font_size_override("font_size", 10)
	row.add_child(key)
	var value: Label = Label.new()
	value.text = value_text
	value.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	value.add_theme_font_size_override("font_size", 11)
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.clip_text = true
	row.add_child(value)
	return row


# A labelled item-registry checklist section whose checked ids are written to
# shop_data[key]. Used twice by the shop editor: the fixed lineup ("items") and
# the pool-mode guaranteed subset ("guaranteed").
# Hover text for an item: what it does, what it costs, how long it lasts. Every item picker in
# the builder uses this — the registry has carried a `description` all along and none of them
# showed it, so authors were picking from names alone.
func _item_tooltip(item_id: String) -> String:
	var data: Dictionary = InventoryService.GetItemData(item_id)
	if data.is_empty():
		return ""
	var lines: Array = [str(data.get("name", item_id))]
	var desc: String = str(data.get("description", ""))
	if desc != "":
		lines.append(desc)
	var facts: Array = ["♦%d" % int(data.get("price", 0))]
	var ms: int = int(data.get("duration_ms", 0))
	if ms > 0:
		facts.append("lasts %ss" % String.num(ms / 1000.0, 1).trim_suffix(".0"))
	var cat: String = str(data.get("category", ""))
	if cat != "":
		facts.append(cat)
	lines.append("  ·  ".join(facts))
	return "\n".join(lines)


# Fills an item OptionButton's per-entry tooltips. `values` is the parallel id list the dropdown
# was built from, where index 0 is the "None" entry.
func _apply_item_tooltips(dd: OptionButton, values: Array) -> void:
	for i: int in values.size():
		var id: String = str(values[i])
		if id != "":
			dd.set_item_tooltip(i, _item_tooltip(id))


func _shop_item_multiselect(
	arr: Array, idx: int, key: String, label: String, hint_text: String, all_item_ids: Array
) -> VBoxContainer:
	var section: VBoxContainer = VBoxContainer.new()
	section.add_theme_constant_override("separation", 6)

	section.add_child(_side_section_separator())
	section.add_child(_side_field_label(label))
	var hint: Label = Label.new()
	hint.text = hint_text
	hint.add_theme_color_override(
		"font_color", Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.7)
	)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	section.add_child(hint)

	# One MultiSelectDropdown over the registry (built-ins + this journey's custom items), name + price
	# per row — a compact picker in place of the old long checkbox column.
	var entries: Array = []  # [{id, label, tooltip}]
	for item_id: String in all_item_ids:
		(
			entries
			. append(
				{
					"id": item_id,
					"label": "%s  (♦%d)" % [_item_display_name(item_id), _shop_item_price(item_id)],
					"tooltip": UITheme.wrap_tip(_item_tooltip(item_id)),  # what it does / costs / lasts, on hover
				}
			)
		)
	var dd: MultiSelectDropdown = MultiSelectDropdown.new()
	dd.empty_text = "None"
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_child(dd)  # add first so _ready wires the popup, then populate
	dd.set_options(entries)
	dd.set_selected(arr[idx].get(key, []))
	UITheme.style_menu_button(dd)
	dd.selection_changed.connect(func(ids: Array) -> void: arr[idx][key] = ids)
	return section


# Price for a shop-picker row: built-in items from the registry, custom items from the journey's list.
func _shop_item_price(item_id: String) -> int:
	var data: Dictionary = InventoryService.GetItemData(item_id)
	if not data.is_empty():
		return int(data.get("price", 0))
	for it: Dictionary in _owner._journey_items:
		if str(it.get("id", "")) == item_id:
			return int(it.get("price", 0))
	return 0


func _make_side_storyboard_editor(arr: Array, idx: int, reselect: Callable) -> Control:
	var sb_data: Dictionary = arr[idx]
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	# First, because it is what the author looks for when they come back to this node. Builder-only: a
	# storyboard's on-screen content is its lines, and this never reaches a player.
	col.add_child(_side_field_label("NAME  (FOR YOUR MAP — PLAYERS NEVER SEE IT)"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str(sb_data.get("name", ""))
	name_edit.placeholder_text = "e.g. Intro, She finds out, Bad end"
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(
		func(v: String) -> void:
			arr[idx]["name"] = v
			# The graph caption reads this, so the node relabels as it is typed rather than on reselect.
			_owner._refresh_graph()
	)
	col.add_child(name_edit)

	col.add_child(_side_field_label("COINS AWARDED"))
	var coins_spin: SpinBox = SpinBox.new()
	coins_spin.min_value = 0
	coins_spin.max_value = 999999
	coins_spin.step = 1
	coins_spin.value = sb_data.get("coins", 0)
	coins_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(coins_spin)
	coins_spin.value_changed.connect(func(v: float) -> void: arr[idx]["coins"] = int(v))
	col.add_child(coins_spin)

	# Optional item reward — granted (alongside coins) when the storyboard ends.
	col.add_child(_side_field_label("ITEM REWARD  (OPTIONAL)"))
	var item_values: Array = [""]
	var item_dd: OptionButton = OptionButton.new()
	item_dd.add_item("None")
	for k: String in _all_item_ids():
		item_values.append(k)
		item_dd.add_item(_item_display_name(k))
	item_dd.selected = max(0, item_values.find(str(sb_data.get("item", ""))))
	item_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(item_dd)
	_apply_item_tooltips(item_dd, item_values)
	item_dd.item_selected.connect(func(i: int) -> void: arr[idx]["item"] = item_values[i])
	col.add_child(item_dd)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("DEFAULT IMAGE"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions = JourneyData.ANIMATED_IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title = "Select Default Image"
	img_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(img_zone)
	if sb_data.get("image", "") != "":
		img_zone.call_deferred("set_file", sb_data["image"])
	var sb_rm_btn: Button = Button.new()
	sb_rm_btn.text = "✕ REMOVE DEFAULT IMAGE"
	sb_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb_rm_btn.visible = sb_data.get("image", "") != ""
	UITheme.style_button(sb_rm_btn, UITheme.MAGENTA)
	sb_rm_btn.pressed.connect(
		func() -> void:
			_delete_saved_image(arr[idx].get("image", ""))
			arr[idx]["image"] = ""
			img_zone.call_deferred("set_file", "")
			sb_rm_btn.visible = false
	)
	img_zone.file_dropped.connect(
		func(p: String) -> void:
			arr[idx]["image"] = p
			sb_rm_btn.visible = true
	)
	col.add_child(sb_rm_btn)

	# Overarching BGM — one looping track under EVERY line (its own volume, separate from line accents).
	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("BACKGROUND MUSIC  (OPTIONAL — LOOPS UNDER ALL LINES)"))
	var bgm_zone: PanelContainer = DropZoneScript.new()
	bgm_zone.accepted_extensions = JourneyAudio.AUDIO_EXTENSIONS.duplicate()
	bgm_zone.picker_title = "Select Background Music"
	bgm_zone.picker_filters = ["*.ogg,*.mp3,*.wav ; Audio Files"]
	bgm_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(bgm_zone)
	if str(sb_data.get("bgm", "")) != "":
		bgm_zone.call_deferred("set_file", sb_data["bgm"])
	var bgm_vol: Control = _make_volume_row(
		col, arr[idx], "bgm_volume", 0.6, func() -> String: return str(arr[idx].get("bgm", ""))
	)
	bgm_vol.visible = str(sb_data.get("bgm", "")) != ""
	col.add_child(bgm_vol)
	var bgm_rm_btn: Button = Button.new()
	bgm_rm_btn.text = "✕ REMOVE MUSIC"
	bgm_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bgm_rm_btn.visible = str(sb_data.get("bgm", "")) != ""
	UITheme.style_button(bgm_rm_btn, UITheme.MAGENTA)
	bgm_rm_btn.pressed.connect(
		func() -> void:
			arr[idx]["bgm"] = ""
			bgm_zone.call_deferred("set_file", "")
			bgm_rm_btn.visible = false
			bgm_vol.visible = false
	)
	bgm_zone.file_dropped.connect(
		func(p: String) -> void:
			arr[idx]["bgm"] = p
			bgm_rm_btn.visible = p != ""
			bgm_vol.visible = p != ""
	)
	col.add_child(bgm_rm_btn)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("DIALOGUE LINES"))

	var lines_arr: Array = sb_data.get("lines", [])
	if not sb_data.has("lines"):
		arr[idx]["lines"] = lines_arr

	var lines_col: VBoxContainer = VBoxContainer.new()
	lines_col.add_theme_constant_override("separation", 6)
	col.add_child(lines_col)

	var refresh_self: Callable = func() -> void: reselect.call(idx)

	# Opening slot — insert before the first line (also serves as "add first line").
	lines_col.add_child(_make_insert_line_btn(lines_arr, 0, refresh_self))

	for li in lines_arr.size():
		lines_col.add_child(_make_side_storyboard_line_block(lines_arr, li, refresh_self))
		# Slot after each line; the last one doubles as "append at end".
		lines_col.add_child(_make_insert_line_btn(lines_arr, li + 1, refresh_self))

	var paste_btn: Button = Button.new()
	paste_btn.text = "⎘ PASTE LINES"
	paste_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(paste_btn, UITheme.PURPLE_MID)
	paste_btn.pressed.connect(func() -> void: _show_paste_lines_popup(lines_arr, refresh_self))
	col.add_child(paste_btn)
	return col


# Opens a popup with a large TextEdit. Each non-empty line of the pasted text
# becomes a new dialogue line. Format: "SPEAKER: text" splits on the first
# colon; lines without a colon become narration (no speaker).
func _show_paste_lines_popup(lines_arr: Array, refresh_storyboard: Callable) -> void:
	var popup: PopupPanel = PopupPanel.new()
	_owner.add_child(popup)

	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG
	panel_style.border_color = UITheme.STORYBOARD
	panel_style.border_width_left = 2
	panel_style.border_width_right = 2
	panel_style.border_width_top = 2
	panel_style.border_width_bottom = 2
	panel_style.content_margin_left = 16
	panel_style.content_margin_right = 16
	panel_style.content_margin_top = 16
	panel_style.content_margin_bottom = 16
	popup.add_theme_stylebox_override("panel", panel_style)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	popup.add_child(vbox)

	var hdr: Label = Label.new()
	hdr.text = "// PASTE DIALOGUE LINES //"
	hdr.add_theme_color_override("font_color", UITheme.STORYBOARD)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hdr)

	var hint: Label = Label.new()
	hint.text = "ONE LINE PER DIALOGUE.  FORMAT:  SPEAKER: text  (LINES WITHOUT A COLON BECOME NARRATION.)"
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)

	var text_edit: TextEdit = TextEdit.new()
	text_edit.placeholder_text = "ARIA: Hello there.\nThe wind howled outside.\nKAI: It's getting cold."
	text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_edit.size_flags_vertical = Control.SIZE_FILL
	text_edit.custom_minimum_size = Vector2(0, 200)
	text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(text_edit)
	vbox.add_child(text_edit)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(cancel_btn, UITheme.PURPLE_MID)
	cancel_btn.pressed.connect(func() -> void: popup.queue_free())
	btn_row.add_child(cancel_btn)

	var apply_btn: Button = Button.new()
	apply_btn.text = "+ APPEND LINES"
	apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(apply_btn, UITheme.STORYBOARD)
	apply_btn.pressed.connect(
		func() -> void:
			var parsed: Array = _parse_pasted_lines(text_edit.text)
			for line: Dictionary in parsed:
				lines_arr.append(line)
			popup.queue_free()
			refresh_storyboard.call()
	)
	btn_row.add_child(apply_btn)

	popup.popup_centered_clamped(Vector2i(720, 560), 0.9)
	text_edit.grab_focus()


# Parses a pasted multi-line block into dialogue-line dicts.
# Format: "SPEAKER: text" → {speaker: "SPEAKER", text: "text"}.
# Lines without a colon become narration: {speaker: "", text: "<line>"}.
# Blank lines are skipped.
func _parse_pasted_lines(raw: String) -> Array:
	var result: Array = []
	for raw_line in raw.split("\n"):
		var line: String = (raw_line as String).strip_edges()
		if line == "":
			continue
		var colon_idx: int = line.find(":")
		if colon_idx > 0:
			var speaker: String = line.substr(0, colon_idx).strip_edges()
			var text: String = line.substr(colon_idx + 1).strip_edges()
			result.append({"speaker": speaker, "text": text, "image": ""})
		else:
			result.append({"speaker": "", "text": line, "image": ""})
	return result


# Per-line sub-block for the storyboard side editor: speaker, text (multi-line),
# optional per-line image override, and line move/remove buttons.
func _make_side_storyboard_line_block(
	lines_arr: Array, line_idx: int, refresh_storyboard: Callable
) -> Control:
	var line_data: Dictionary = lines_arr[line_idx]

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.border_color = Color(UITheme.STORYBOARD.r, UITheme.STORYBOARD.g, UITheme.STORYBOARD.b, 0.35)
	ps.border_width_left = 1
	ps.border_width_right = 1
	ps.border_width_top = 1
	ps.border_width_bottom = 1
	ps.content_margin_left = 10
	ps.content_margin_right = 10
	ps.content_margin_top = 8
	ps.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", ps)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	panel.add_child(col)

	var hdr_lbl: Label = Label.new()
	hdr_lbl.text = "LINE %d" % (line_idx + 1)
	hdr_lbl.add_theme_color_override("font_color", UITheme.STORYBOARD)
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr_lbl.uppercase = true
	col.add_child(hdr_lbl)

	col.add_child(_side_field_label("SPEAKER"))
	var speaker_edit: LineEdit = LineEdit.new()
	speaker_edit.placeholder_text = "Speaker (optional)..."
	speaker_edit.text = line_data.get("speaker", "")
	UITheme.style_line_edit(speaker_edit)
	speaker_edit.text_changed.connect(
		func(val: String) -> void: lines_arr[line_idx]["speaker"] = val
	)
	col.add_child(speaker_edit)
	# Cast quick-pick: one chip per character sets the speaker in a click — so a back-and-forth doesn't
	# mean retyping names each line (the "use line above" button never helped there). It also stages the
	# character on their home side the first time they speak. The lit character at runtime is whichever
	# on-stage portrait's name matches this speaker.
	_add_speaker_chips(col, lines_arr, line_idx, speaker_edit, refresh_storyboard)

	col.add_child(_side_field_label("DIALOGUE"))
	var text_edit: TextEdit = TextEdit.new()
	text_edit.placeholder_text = "Dialogue text..."
	text_edit.text = line_data.get("text", "")
	text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_edit.custom_minimum_size = Vector2(0, 90)
	text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(text_edit)
	text_edit.text_changed.connect(func() -> void: lines_arr[line_idx]["text"] = text_edit.text)
	col.add_child(text_edit)

	# Persistent stage: the list of characters on screen this line, each with a chosen portrait +
	# position. Carries forward from the line above (set when a line is inserted), so a back-and-forth
	# only changes the speaker chip. Shown only when the journey has a cast.
	_add_stage_editor(col, lines_arr, line_idx, refresh_storyboard)

	col.add_child(_side_field_label("BACKGROUND (THIS LINE, OPTIONAL)"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions = JourneyData.ANIMATED_IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title = "Select Background for Line %d" % (line_idx + 1)
	img_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(img_zone)
	if line_data.get("image", "") != "":
		img_zone.call_deferred("set_file", line_data["image"])
	var line_rm_btn: Button = Button.new()
	line_rm_btn.text = "✕ REMOVE BACKGROUND"
	line_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line_rm_btn.visible = line_data.get("image", "") != ""
	UITheme.style_button(line_rm_btn, UITheme.MAGENTA)
	line_rm_btn.pressed.connect(
		func() -> void:
			_delete_saved_image(lines_arr[line_idx].get("image", ""))
			lines_arr[line_idx]["image"] = ""
			img_zone.call_deferred("set_file", "")
			line_rm_btn.visible = false
	)
	img_zone.file_dropped.connect(
		func(p: String) -> void:
			lines_arr[line_idx]["image"] = p
			line_rm_btn.visible = p != ""
	)
	col.add_child(line_rm_btn)

	# "Use background from line above" — shown for every line except the first.
	if line_idx > 0:
		var ref_btn: Button = Button.new()
		ref_btn.text = "↑  USE BACKGROUND FROM LINE ABOVE"
		ref_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(ref_btn, UITheme.STORYBOARD)
		ref_btn.pressed.connect(
			func() -> void:
				var prev_image: String = lines_arr[line_idx - 1].get("image", "")
				if prev_image == "":
					return
				img_zone.set_file(prev_image)  # emits file_dropped → updates dict + rm btn
		)
		col.add_child(ref_btn)

	col.add_child(_side_field_label("LINE AUDIO (OPTIONAL)"))
	var audio_zone: PanelContainer = DropZoneScript.new()
	audio_zone.accepted_extensions = JourneyAudio.AUDIO_EXTENSIONS.duplicate()
	audio_zone.picker_title = "Select Audio for Line %d" % (line_idx + 1)
	audio_zone.picker_filters = ["*.ogg,*.mp3,*.wav ; Audio Files"]
	audio_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(audio_zone)
	if line_data.get("audio", "") != "":
		audio_zone.call_deferred("set_file", line_data["audio"])
	var audio_loop_toggle: CheckButton = CheckButton.new()
	audio_loop_toggle.text = "LOOP THIS AUDIO"
	audio_loop_toggle.add_theme_font_size_override("font_size", 11)
	audio_loop_toggle.button_pressed = bool(line_data.get("audio_loop", false))
	audio_loop_toggle.visible = line_data.get("audio", "") != ""
	audio_loop_toggle.toggled.connect(
		func(on: bool) -> void: lines_arr[line_idx]["audio_loop"] = on
	)
	col.add_child(audio_loop_toggle)
	var audio_vol: Control = _make_volume_row(
		col,
		lines_arr[line_idx],
		"audio_volume",
		1.0,
		func() -> String: return str(lines_arr[line_idx].get("audio", ""))
	)
	audio_vol.visible = line_data.get("audio", "") != ""
	col.add_child(audio_vol)
	var audio_rm_btn: Button = Button.new()
	audio_rm_btn.text = "✕ REMOVE AUDIO"
	audio_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	audio_rm_btn.visible = line_data.get("audio", "") != ""
	UITheme.style_button(audio_rm_btn, UITheme.MAGENTA)
	audio_rm_btn.pressed.connect(
		func() -> void:
			lines_arr[line_idx]["audio"] = ""
			audio_zone.call_deferred("set_file", "")
			audio_rm_btn.visible = false
			audio_loop_toggle.visible = false
			audio_vol.visible = false
	)
	audio_zone.file_dropped.connect(
		func(p: String) -> void:
			lines_arr[line_idx]["audio"] = p
			audio_rm_btn.visible = p != ""
			audio_loop_toggle.visible = p != ""
			audio_vol.visible = p != ""
	)
	col.add_child(audio_rm_btn)

	# Line action row (move + delete).
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var up_btn: Button = UITheme.make_icon_btn("↑", line_idx == 0, UITheme.STORYBOARD)
	up_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	up_btn.pressed.connect(
		func() -> void:
			if line_idx <= 0:
				return
			var tmp: Dictionary = lines_arr[line_idx]
			lines_arr[line_idx] = lines_arr[line_idx - 1]
			lines_arr[line_idx - 1] = tmp
			refresh_storyboard.call()
	)
	row.add_child(up_btn)
	var dn_btn: Button = UITheme.make_icon_btn(
		"↓", line_idx == lines_arr.size() - 1, UITheme.STORYBOARD
	)
	dn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dn_btn.pressed.connect(
		func() -> void:
			if line_idx >= lines_arr.size() - 1:
				return
			var tmp: Dictionary = lines_arr[line_idx]
			lines_arr[line_idx] = lines_arr[line_idx + 1]
			lines_arr[line_idx + 1] = tmp
			refresh_storyboard.call()
	)
	row.add_child(dn_btn)
	var rm_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rm_btn.pressed.connect(
		func() -> void:
			lines_arr.remove_at(line_idx)
			refresh_storyboard.call()
	)
	row.add_child(rm_btn)
	col.add_child(row)

	return panel


# Cast quick-pick chips: one button per named character. A click sets this line's speaker AND, the
# first time they speak, adds them to the stage at their default position + portrait (non-destructive —
# see JourneyData.stage_with_speaker). Already-staged characters just get set as the speaker. No cast →
# nothing added. `refresh` re-renders the line block when a chip changes the stage.
func _add_speaker_chips(
	col: VBoxContainer, lines_arr: Array, line_idx: int, speaker_edit: LineEdit, refresh: Callable
) -> void:
	var named: Array = []
	for c: Variant in _owner._journey_characters:
		if c is Dictionary and str((c as Dictionary).get("name", "")).strip_edges() != "":
			named.append(c)
	if named.is_empty():
		return
	var flow: HFlowContainer = HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	for c: Dictionary in named:
		var cname: String = str(c.get("name", "")).strip_edges()
		var cid: String = str(c.get("id", ""))
		var chip: Button = Button.new()
		chip.text = cname
		chip.focus_mode = Control.FOCUS_NONE
		chip.add_theme_font_size_override("font_size", 10)
		UITheme.style_button_subtle(chip, UITheme.STORYBOARD)
		chip.pressed.connect(
			func() -> void:
				lines_arr[line_idx]["speaker"] = cname
				speaker_edit.text = cname
				# Bring them on stage on their first line; re-render so the STAGE rows reflect it. A
				# no-op (already staged) skips the rebuild — the back-and-forth case just sets speaker.
				if _auto_stage_speaker(lines_arr, line_idx, cid):
					refresh.call()
		)
		flow.add_child(chip)
	col.add_child(flow)


# Non-destructive first-entrance staging (JourneyData.stage_with_speaker) using the character's default
# position + portrait. Returns true only when a character was actually added (so the caller re-renders).
func _auto_stage_speaker(lines_arr: Array, line_idx: int, cid: String) -> bool:
	var chr: Dictionary = _character_by_id(cid)
	var cur: Array = lines_arr[line_idx].get("stage", [])
	if not (cur is Array):
		cur = []
	var updated: Array = JourneyData.stage_with_speaker(
		cur,
		cid,
		JourneyData.character_default_placement(chr),
		JourneyData.character_default_portrait(chr)
	)
	lines_arr[line_idx]["stage"] = updated
	return updated.size() > cur.size()


func _character_by_id(id: String) -> Dictionary:
	for c: Variant in _owner._journey_characters:
		if c is Dictionary and str((c as Dictionary).get("id", "")) == id:
			return c
	return {}


# Per-line STAGE editor: a list of on-stage entries (character + portrait + position), plus an add
# button. Carries forward from the previous line (done at insert time). No cast + no stage → skipped.
func _add_stage_editor(
	col: VBoxContainer, lines_arr: Array, line_idx: int, refresh: Callable
) -> void:
	var cast: Array = _owner._journey_characters
	if not (lines_arr[line_idx].get("stage", null) is Array):
		lines_arr[line_idx]["stage"] = []
	var stage: Array = lines_arr[line_idx]["stage"]
	if cast.is_empty() and stage.is_empty():
		return
	col.add_child(_side_field_label("STAGE  (characters over the background)"))
	for i: int in stage.size():
		col.add_child(_make_stage_entry_row(lines_arr, line_idx, i, refresh))
	if not cast.is_empty():
		var add_btn: Button = Button.new()
		add_btn.text = "＋ ADD TO STAGE"
		add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button_subtle(add_btn, UITheme.STORYBOARD)
		add_btn.pressed.connect(
			func() -> void:
				stage.append({"character": str((cast[0] as Dictionary).get("id", ""))})
				refresh.call()
		)
		col.add_child(add_btn)


# One stage entry: pick the character, then their portrait (expression) and position — both drawn from
# that character's own lists, with "(default)" = their first. Changing the character refills the row.
func _make_stage_entry_row(
	lines_arr: Array, line_idx: int, entry_idx: int, refresh: Callable
) -> Control:
	var entry: Dictionary = (lines_arr[line_idx]["stage"] as Array)[entry_idx]
	var chr: Dictionary = _character_by_id(str(entry.get("character", "")))

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.set_corner_radius_all(UITheme.CORNER_RADIUS)
	ps.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", ps)
	var box: VBoxContainer = panel_col(panel)

	# Character + remove.
	var top: HBoxContainer = HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	var char_dd: OptionButton = OptionButton.new()
	char_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var char_vals: Array = []
	for c: Variant in _owner._journey_characters:
		if c is Dictionary:
			char_vals.append(str((c as Dictionary).get("id", "")))
			var nm: String = str((c as Dictionary).get("name", "")).strip_edges()
			char_dd.add_item(nm if nm != "" else "(unnamed)")
	var csel: int = char_vals.find(str(entry.get("character", "")))
	if csel < 0:
		char_vals.append(str(entry.get("character", "")))
		char_dd.add_item("⚠ (missing)")
		csel = char_vals.size() - 1
	char_dd.selected = maxi(0, csel)
	UITheme.style_option_button(char_dd)
	char_dd.item_selected.connect(
		func(i: int) -> void:
			entry["character"] = str(char_vals[i])
			entry.erase("portrait")  # the new character's options differ — reset to defaults
			entry.erase("placement")
			refresh.call()
	)
	top.add_child(char_dd)
	var rm: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	rm.pressed.connect(
		func() -> void:
			(lines_arr[line_idx]["stage"] as Array).remove_at(entry_idx)
			refresh.call()
	)
	top.add_child(rm)
	box.add_child(top)

	# Portrait + position, from the chosen character's own lists ("(default)" = first).
	box.add_child(
		_stage_entry_dropdown(
			entry, "portrait", chr.get("portraits", []), "Expression", "default (first)"
		)
	)
	box.add_child(
		_stage_entry_dropdown(
			entry, "placement", chr.get("placements", []), "Position", "default (first)"
		)
	)
	return panel


# A labelled dropdown over a character's portraits/placements, writing the picked id to entry[key]
# ("" / omitted = the default first). `options` are {id, name} dicts.
func _stage_entry_dropdown(
	entry: Dictionary, key: String, options: Array, label: String, default_label: String
) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl: Label = Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(72, 0)
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(lbl)

	var dd: OptionButton = OptionButton.new()
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var values: Array = [""]  # index → id ("" = default)
	dd.add_item("(%s)" % default_label)
	for o: Variant in options:
		if o is Dictionary:
			values.append(str((o as Dictionary).get("id", "")))
			var nm: String = str((o as Dictionary).get("name", "")).strip_edges()
			dd.add_item(nm if nm != "" else "(unnamed)")
	dd.selected = maxi(0, values.find(str(entry.get(key, ""))))
	UITheme.style_option_button(dd)
	dd.item_selected.connect(
		func(i: int) -> void:
			var id: String = str(values[i])
			if id == "":
				entry.erase(key)
			else:
				entry[key] = id
	)
	row.add_child(dd)
	return row


# Thin "insert a new line here" button placed between line blocks in the
# storyboard editor.  Subtle by default, highlights on hover so it doesn't
# compete visually with the line content above/below it.
func _make_insert_line_btn(lines_arr: Array, insert_at: int, refresh: Callable) -> Control:
	var btn: Button = Button.new()
	btn.text = "╋  INSERT LINE"
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0, 24)
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 10)

	var c: Color = UITheme.STORYBOARD

	var s_n: StyleBoxFlat = StyleBoxFlat.new()
	s_n.bg_color = Color(c.r, c.g, c.b, 0.04)
	s_n.border_color = Color(c.r, c.g, c.b, 0.22)
	s_n.border_width_left = 1
	s_n.border_width_right = 1
	s_n.border_width_top = 1
	s_n.border_width_bottom = 1
	s_n.content_margin_top = 2
	s_n.content_margin_bottom = 2
	s_n.set_corner_radius_all(UITheme.CORNER_RADIUS)
	btn.add_theme_stylebox_override("normal", s_n)

	var s_h: StyleBoxFlat = s_n.duplicate()
	s_h.bg_color = Color(c.r, c.g, c.b, 0.15)
	s_h.border_color = c
	btn.add_theme_stylebox_override("hover", s_h)

	var s_p: StyleBoxFlat = s_n.duplicate()
	s_p.bg_color = Color(c.r, c.g, c.b, 0.28)
	btn.add_theme_stylebox_override("pressed", s_p)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	btn.add_theme_color_override("font_color", Color(c.r, c.g, c.b, 0.45))
	btn.add_theme_color_override("font_hover_color", c)
	btn.add_theme_color_override("font_pressed_color", c)

	btn.pressed.connect(
		func() -> void:
			# Carry the stage forward from the line above (persistent-stage default), so a new line in a
			# back-and-forth keeps the same characters and the author only sets who's now speaking.
			var carried: Array = []
			if insert_at > 0 and insert_at - 1 < lines_arr.size():
				var prev: Variant = lines_arr[insert_at - 1].get("stage", [])
				if prev is Array:
					carried = (prev as Array).duplicate(true)
			var new_line: Dictionary = {"speaker": "", "text": "", "image": ""}
			if not carried.is_empty():
				new_line["stage"] = carried
			lines_arr.insert(insert_at, new_line)
			refresh.call()
	)
	return btn


# Adds a labeled integer SpinBox to `container` that writes its value back to
# paths_arr[pi][key]. Shared by the per-path weight / cost / threshold fields.
func _add_path_int_field(
	container: VBoxContainer, paths_arr: Array, pi: int, key: String, label: String, max_value: int
) -> void:
	container.add_child(_side_field_label(label))
	var spin: SpinBox = SpinBox.new()
	spin.min_value = 0
	spin.max_value = max_value
	spin.step = 1
	spin.value = int(paths_arr[pi].get(key, 0))
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(func(v: float) -> void: paths_arr[pi][key] = int(v))
	container.add_child(spin)


# Adds a "required item" label + dropdown (with a None/free option) to `container`,
# writing the chosen item id (or "" for none) to paths_arr[pi].required_item.
# Shared by Sacrifice (consumed) and item-Conditional (checked).
func _add_required_item_field(
	container: VBoxContainer, paths_arr: Array, pi: int, path: Dictionary, label: String
) -> void:
	container.add_child(_side_field_label(label))
	var values: Array = [""]
	var item_ids: Array = _all_item_ids()
	var dd: OptionButton = OptionButton.new()
	dd.add_item("None (free)")
	for k: String in item_ids:
		values.append(k)
		dd.add_item(_item_display_name(k))
	dd.selected = max(0, values.find(str(path.get("required_item", ""))))
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(dd)
	_apply_item_tooltips(dd, values)
	dd.item_selected.connect(func(i: int) -> void: paths_arr[pi]["required_item"] = values[i])
	container.add_child(dd)


# Short human description of a fork resolution type for the editor.
func _fork_resolution_hint(resolution: String, metric: String, decider: String) -> String:
	match resolution:
		"choice":
			return "The player picks a path."
		"random":
			return "The game picks a path at random, weighted by each path's weight (reveal shown)."
		"conditional":
			if decider == "player":
				match metric:
					"score":
						return "The player picks — but only paths whose score threshold the last round met are selectable (plus the default, always available)."
					"coins":
						return "The player picks — but only paths whose coin threshold the balance meets are selectable (plus the default). Coins are NOT spent."
					"item":
						return "The player picks — but only paths whose required item the player owns are selectable (plus the default). The item is NOT consumed."
					"flag":
						return "The player picks — but only paths whose required flag is set are selectable (plus the default)."
				return "The player picks among the paths they qualify for (plus the default)."
			match metric:
				"score":
					return "The game auto-picks the highest path whose score threshold the last round met, else the default path."
				"coins":
					return "The game auto-picks the highest path whose coin threshold the player's balance meets, else the default path. Coins are NOT spent."
				"item":
					return "The game auto-picks the first path whose required item the player owns (a pure check — the item is NOT consumed), else the default path."
				"flag":
					return "The game auto-picks the first path whose required flag is set (by a node played or a choice taken earlier), else the default path."
		"sacrifice":
			return "The player picks a path and spends its cost — coins and/or an item (e.g. a Key), both consumed. Paths they can't afford are disabled, so include at least one free (0 coins, item None) path."
	return ""


# ── Extra axes expander ──────────────────────────────────────────────────────


# Collapsed "▶ EXTRA AXES (SERIAL ONLY)" expander with one DropZone per axis.
# Serial-only: Buttplug devices ignore all secondary axes.
func _make_axis_expander(arr: Array, idx: int) -> Control:
	# Ensure the dict key exists.
	if not arr[idx].has("axis_scripts"):
		arr[idx]["axis_scripts"] = {}

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = "▶  EXTRA AXES  (SERIAL ONLY)"
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = false
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.PURPLE_MID)
	wrapper.add_child(toggle_btn)

	var axes_panel: VBoxContainer = VBoxContainer.new()
	axes_panel.add_theme_constant_override("separation", 6)
	axes_panel.visible = false
	wrapper.add_child(axes_panel)

	var hint: Label = Label.new()
	hint.text = "SECONDARY-AXIS .FUNSCRIPT FILES FOR T-CODE SR6 / OSR2+ DEVICES.  SERIAL OUTPUT ONLY — IGNORED FOR BUTTPLUG."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	axes_panel.add_child(hint)

	for info: Dictionary in EXTRA_AXES_INFO:
		var axis: String = info["axis"]
		axes_panel.add_child(_side_field_label(info["label"]))
		var zone: PanelContainer = DropZoneScript.new()
		zone.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
		zone.picker_title = "Select %s Funscript" % axis
		zone.picker_filters = ["*.funscript,*.json ; Funscript Files", "*.* ; All Files"]
		zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var current_path: String = (arr[idx]["axis_scripts"] as Dictionary).get(axis, "")
		# Zone + inline ✕ remove (disabled until this axis is set).
		var rm: Button = UITheme.make_icon_btn("✕", current_path == "", UITheme.MAGENTA)
		rm.tooltip_text = UITheme.wrap_tip("Remove %s funscript" % axis)
		rm.pressed.connect(func() -> void: zone.set_file(""))
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(zone)
		row.add_child(rm)
		axes_panel.add_child(row)
		if current_path != "":
			zone.call_deferred("set_file", current_path, false)
		# Capture axis in closure.
		var captured_axis: String = axis
		zone.file_dropped.connect(
			func(p: String) -> void:
				rm.disabled = (p == "")
				if p == "":
					(arr[idx]["axis_scripts"] as Dictionary).erase(captured_axis)
				else:
					arr[idx]["axis_scripts"][captured_axis] = p
		)

	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			toggle_btn.text = (
				"▼  EXTRA AXES  (SERIAL ONLY)" if pressed else "▶  EXTRA AXES  (SERIAL ONLY)"
			)
			axes_panel.visible = pressed
	)

	return wrapper


# ── Vibrator channel expander ────────────────────────────────────────────────


# Collapsed "▶ VIBRATOR SCRIPTS (BUTTPLUG ONLY)" expander with one DropZone per
# vibration channel. Accepts .vib1 / .vib2 funscripts for multi-motor devices.
# When only vib1 is provided and the device has 2+ channels, FunscriptPlayer
# mirrors it automatically — no need to fill both unless you want distinct patterns.
func _make_vib_expander(arr: Array, idx: int) -> Control:
	# Ensure the dict key exists.
	if not arr[idx].has("vib_scripts"):
		arr[idx]["vib_scripts"] = {}

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = "▶  VIBRATOR SCRIPTS  (BUTTPLUG ONLY)"
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = false
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.PURPLE_MID)
	wrapper.add_child(toggle_btn)

	var vib_panel: VBoxContainer = VBoxContainer.new()
	vib_panel.add_theme_constant_override("separation", 6)
	vib_panel.visible = false
	wrapper.add_child(vib_panel)

	var hint: Label = Label.new()
	hint.text = "PER-CHANNEL FUNSCRIPTS FOR MULTI-MOTOR VIBRATORS (E.G. WE-VIBE, LOVENSE NORA).  LEAVE EMPTY TO USE THE MAIN FUNSCRIPT FOR ALL CHANNELS."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vib_panel.add_child(hint)

	for info: Dictionary in VIB_CHANNELS_INFO:
		var ch_key: String = info["key"]
		vib_panel.add_child(_side_field_label(info["label"]))
		var zone: PanelContainer = DropZoneScript.new()
		zone.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
		zone.picker_title = "Select %s Funscript" % ch_key.to_upper()
		zone.picker_filters = ["*.funscript,*.json ; Funscript Files", "*.* ; All Files"]
		zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var current_path: String = (arr[idx]["vib_scripts"] as Dictionary).get(ch_key, "")
		# Zone + inline ✕ remove (disabled until this channel is set).
		var rm: Button = UITheme.make_icon_btn("✕", current_path == "", UITheme.MAGENTA)
		rm.tooltip_text = UITheme.wrap_tip("Remove %s funscript" % ch_key.to_upper())
		rm.pressed.connect(func() -> void: zone.set_file(""))
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(zone)
		row.add_child(rm)
		vib_panel.add_child(row)
		if current_path != "":
			zone.call_deferred("set_file", current_path, false)
		# Capture key in closure.
		var captured_key: String = ch_key
		zone.file_dropped.connect(
			func(p: String) -> void:
				rm.disabled = (p == "")
				if p == "":
					(arr[idx]["vib_scripts"] as Dictionary).erase(captured_key)
				else:
					arr[idx]["vib_scripts"][captured_key] = p
		)

	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			toggle_btn.text = (
				"▼  VIBRATOR SCRIPTS  (BUTTPLUG ONLY)"
				if pressed
				else "▶  VIBRATOR SCRIPTS  (BUTTPLUG ONLY)"
			)
			vib_panel.visible = pressed
	)

	return wrapper


# ── Checkpoint toggle ───────────────────────────────────────────────────────


# Author-marked save point. When this round starts during play, the game shows
# a CHECKPOINT REACHED banner offering Save & Quit so the player can resume the
# run later. Works on any round type, including bosses — the banner is shown
# before the boss intro card, so the player can save out before committing.
# A "WARMUP ROUND" toggle. A warmup plays like any other round — full payout if completed — but
# offers the player a free ⏭ SKIP button. Use for opening/easing rounds a returning player may
# not want again.
func _make_warmup_toggle(arr: Array, idx: int) -> Control:
	if not arr[idx].has("is_warmup"):
		arr[idx]["is_warmup"] = false

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", ROW_SEP)
	wrapper.add_child(row)

	var label: Label = Label.new()
	label.text = "WARMUP ROUND"
	label.add_theme_color_override("font_color", UITheme.CYAN)
	label.add_theme_font_size_override("font_size", 12)
	label.uppercase = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var toggle: Button = Button.new()
	toggle.toggle_mode = true
	toggle.button_pressed = arr[idx]["is_warmup"]
	toggle.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(toggle, UITheme.CYAN)
	toggle.text = "✓ ON" if arr[idx]["is_warmup"] else "OFF"
	toggle.toggled.connect(
		func(pressed: bool) -> void:
			arr[idx]["is_warmup"] = pressed
			toggle.text = "✓ ON" if pressed else "OFF"
	)
	row.add_child(toggle)

	var hint: Label = Label.new()
	hint.text = "PLAYERS GET A FREE SKIP BUTTON ON THIS ROUND. COMPLETING IT PAYS OUT NORMALLY; SKIPPING PAYS NOTHING AND IS MARKED ON THE END-SCREEN ROUTE."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wrapper.add_child(hint)

	return wrapper


# ── Boss round expander ──────────────────────────────────────────────────────

# Probed video durations, keyed by source path. ffprobe is a subprocess, and the side panel rebuilds on
# every selection — without this the encounter button would shell out each time.
var _clock_probe_cache: Dictionary = {}


# The round's length in ms — the clock the encounter's events are placed against. Tried in the order
# that matches what actually plays: the VIDEO first (the runtime scheduler measures against
# `_video.get_stream_length()`), then the saved `length_ms`, then the funscript's own span.
#
# `length_ms` alone is not enough: the save WRITES it, so an unsaved round has none, and gating on it
# left the button greyed out for every round the author had not saved yet.
func _round_clock_ms(data: Dictionary) -> int:
	var video: String = str(data.get("video_path", ""))
	if video != "":
		if _clock_probe_cache.has(video):
			return int(_clock_probe_cache[video])
		var seconds: float = MediaPoolService.probe_duration_seconds(video)
		var ms: int = int(round(seconds * 1000.0))
		_clock_probe_cache[video] = ms
		if ms > 0:
			return ms
	var saved: int = int(data.get("length_ms", 0))
	if saved > 0:
		return saved
	return int(
		JourneyData.read_funscript_stats(str(data.get("funscript_path", ""))).get("length_ms", 0)
	)


# Opens the encounter editor for this round, and reports what it already holds so the author can see at
# a glance whether one is authored. The round's VIDEO LENGTH is the clock the editor places events
# against; without one, end-anchored events could not be resolved, so the button says so rather than
# opening an editor that would quietly mis-place them.
# One boss-chrome switch. Absent means ON, matching the runtime's own default, so an existing journey
# keeps its chrome without needing a re-save to write the key.
func _make_chrome_toggle(arr: Array, idx: int, key: String, label: String, tip: String) -> Control:
	var toggle: CheckButton = CheckButton.new()
	toggle.text = label
	toggle.tooltip_text = UITheme.wrap_tip(tip)
	toggle.button_pressed = bool(arr[idx].get(key, true))
	toggle.toggled.connect(func(pressed: bool) -> void: arr[idx][key] = pressed)
	return toggle


# The round's authored encounter, type-checked. Read fresh every time it is needed.
func _round_timeline(data: Dictionary) -> Dictionary:
	var raw: Variant = data.get("timeline", {})
	return raw if raw is Dictionary else {}


func _make_encounter_button(arr: Array, idx: int) -> Control:
	var button: Button = Button.new()
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var count: int = (_round_timeline(arr[idx]).get("events", []) as Array).size()
	button.text = "◆ EDIT ENCOUNTER  (%d)" % count if count > 0 else "◆ BUILD ENCOUNTER"
	UITheme.style_button(button, UITheme.DANGER)

	var length_ms: int = _round_clock_ms(arr[idx])
	if length_ms <= 0:
		button.disabled = true
		button.tooltip_text = (
			UITheme
			. wrap_tip(
				"Add this round's video (or its funscript) first — the encounter is placed against the round's length."
			)
		)
		return button

	button.pressed.connect(
		func() -> void:
			# A Node, so the tree owns it: open() parents it to the builder and closing frees it along
			# with its modal, preview stage and any running device test.
			var editor: BossTimelineEditor = BossTimelineEditor.new()
			editor.saved.connect(
				func(edited: Dictionary) -> void:
					# Dropped entirely when it would do nothing, matching what the save does, so an
					# emptied encounter leaves no dead block behind on the round.
					if RoundTimeline.is_empty(edited):
						arr[idx].erase("timeline")
					else:
						arr[idx]["timeline"] = edited
					# Relabel BEFORE refreshing: _refresh_graph can rebuild this panel, which frees the
					# very button being captured here — writing to it afterwards is a use-after-free.
					# Guarded as well, since a rebuild can also be triggered from elsewhere while the
					# encounter modal is open.
					if is_instance_valid(button):
						button.text = (
							"◆ EDIT ENCOUNTER  (%d)" % (edited.get("events", []) as Array).size()
						)
					_owner._refresh_graph()
			)
			# The video and funscript drive the preview stage and the timeline's sync reference.
			(
				editor
				. open(
					_owner,
					# Re-read at CLICK time, not when the button was built: saving an encounter replaces the
					# round's timeline dict, and a value captured at build time would reopen the old one —
					# which looked exactly like the edits had been lost.
					_round_timeline(arr[idx]),
					length_ms,
					str(arr[idx].get("video_path", "")),
					str(arr[idx].get("funscript_path", "")),
					_owner._journey_characters,
					_owner._journey_items,
					_owner._journey_allow_finish
				)
			)
	)
	return button


# A "BOSS ROUND" toggle that, when on, marks the round as a boss and reveals its
# config: an optional intro image, an optional tagline, and a list of forced
# modifiers the player cannot remove. Toggling off reverts it to a normal round.
func _make_boss_expander(arr: Array, idx: int, reselect: Callable) -> Control:
	if not arr[idx].has("round_type"):
		arr[idx]["round_type"] = "normal"
	if not arr[idx].has("boss_modifiers"):
		arr[idx]["boss_modifiers"] = []
	_migrate_sensory_boss_modifiers(arr, idx)

	var is_boss: bool = arr[idx]["round_type"] == "boss"

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 6)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = ("▼  BOSS ROUND" if is_boss else "▶  BOSS ROUND")
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = is_boss
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.MAGENTA)
	wrapper.add_child(toggle_btn)

	var boss_panel: VBoxContainer = VBoxContainer.new()
	boss_panel.add_theme_constant_override("separation", 8)
	boss_panel.visible = is_boss
	wrapper.add_child(boss_panel)

	var hint: Label = Label.new()
	hint.text = "BOSS ROUNDS APPLY FORCED MODIFIERS THE PLAYER CANNOT REMOVE AND OPEN WITH A TELEGRAPHED INTRO CARD. ITEMS ARE LOCKED OUT UNLESS AN ENCOUNTER ALLOWS THEM."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	boss_panel.add_child(hint)

	# Intro image (optional).
	boss_panel.add_child(_side_field_label("BOSS IMAGE  (OPTIONAL)"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions = JourneyData.ANIMATED_IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title = "Select Boss Image"
	img_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	boss_panel.add_child(img_zone)
	if arr[idx].get("boss_image", "") != "":
		img_zone.call_deferred("set_file", arr[idx]["boss_image"])
	img_zone.file_dropped.connect(func(p: String) -> void: arr[idx]["boss_image"] = p)
	boss_panel.add_child(_make_image_fit_field(arr[idx], "fit"))

	# Intro tagline (optional).
	boss_panel.add_child(_side_field_label("INTRO TAGLINE  (OPTIONAL)"))
	var tagline: LineEdit = LineEdit.new()
	tagline.placeholder_text = "A threat, a theme line..."
	tagline.text = arr[idx].get("boss_tagline", "")
	UITheme.style_line_edit(tagline)
	tagline.text_changed.connect(func(val: String) -> void: arr[idx]["boss_tagline"] = val)
	boss_panel.add_child(tagline)

	# The authored ENCOUNTER — attacks, cast cues, audio and windowed effects placed on this round's
	# video clock (BOSS_ROUND_DESIGN). Optional: a boss with no timeline plays exactly as it always has,
	# driven by the forced modifiers below.
	boss_panel.add_child(_side_field_label("ENCOUNTER TIMELINE  (OPTIONAL)"))
	boss_panel.add_child(_make_encounter_button(arr, idx))

	# Boss CHROME. Both default ON, so a boss authored before these existed is untouched; an author who
	# builds their own opener and atmosphere out of the encounter turns them off for a clean canvas.
	(
		boss_panel
		. add_child(
			_make_chrome_toggle(
				arr,
				idx,
				"show_intro_card",
				"SHOW INTRO CARD",
				"The '⚔ BOSS ROUND' telegraph card, with its BEGIN gate. Off opens straight into the round."
			)
		)
	)
	boss_panel.add_child(
		_make_chrome_toggle(
			arr,
			idx,
			"show_boss_frame",
			"SHOW BOSS VIGNETTE",
			"The red border held over the video for the whole round."
		)
	)

	# Forced modifiers list.
	boss_panel.add_child(_side_field_label("FORCED MODIFIERS"))
	var mods_list: VBoxContainer = VBoxContainer.new()
	mods_list.add_theme_constant_override("separation", 6)
	boss_panel.add_child(mods_list)
	_rebuild_boss_modifiers(arr, idx, mods_list)

	var add_btn: Button = Button.new()
	add_btn.text = "+ ADD MODIFIER"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(
		func() -> void:
			(arr[idx]["boss_modifiers"] as Array).append(_default_boss_modifier("scale"))
			_rebuild_boss_modifiers(arr, idx, mods_list)
	)
	boss_panel.add_child(add_btn)

	# Gameplay effects (hindrances/boons) the boss forces on top of its raw modifiers. Same
	# catalog and per-effect tuning as an effect round — but forced (all ticked apply, no roll,
	# no cleanse), consistent with a boss.
	boss_panel.add_child(HSeparator.new())
	boss_panel.add_child(_side_field_label("FORCED EFFECTS  (OPTIONAL)"))
	boss_panel.add_child(_build_effect_catalog_picker(arr, idx))

	# Optional non-gameplay (visual/audio) modifiers the boss imposes alongside its
	# forced modifiers. Explicit-pick only for boss rounds — no random pool.
	boss_panel.add_child(HSeparator.new())
	boss_panel.add_child(_build_sensory_picker(arr, idx))

	# Rebuild on toggle so the round-type stays consistent with the Cursed toggle
	# (turning boss on clears cursed, and vice versa — they share round_type).
	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			arr[idx]["round_type"] = "boss" if pressed else "normal"
			reselect.call(idx)
	)

	return wrapper


# Pool-round expander. A round type (mutually exclusive with Boss/Effect) holding a
# list of encounter entries; the runtime weighted-picks one each play behind a
# mystery "ENCOUNTER!" card. Each entry is its own media set (video + funscript +
# name + weight); the round's own Video/Funscript fields are ignored for pool rounds.
func _make_pool_expander(arr: Array, idx: int, reselect: Callable) -> Control:
	if not arr[idx].has("round_type"):
		arr[idx]["round_type"] = "normal"
	var is_pool: bool = arr[idx]["round_type"] == "pool"

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 6)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = "🎲  POOL (RANDOM ENCOUNTER)  ✓" if is_pool else "🎲  POOL (RANDOM ENCOUNTER)"
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = is_pool
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.CYAN)
	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			arr[idx]["round_type"] = "pool" if pressed else "normal"
			if pressed and not arr[idx].has("pool_entries"):
				arr[idx]["pool_entries"] = []
			reselect.call(idx)
	)
	wrapper.add_child(toggle_btn)

	if not is_pool:
		return wrapper

	if not arr[idx].has("pool_entries"):
		arr[idx]["pool_entries"] = []

	var hint: Label = Label.new()
	hint.text = "One encounter is picked at random (by weight) each play, behind a mystery card. Each encounter carries its own video + funscript — the round's own Video/Funscript fields above are ignored."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wrapper.add_child(hint)

	var card_toggle: CheckButton = CheckButton.new()
	card_toggle.text = 'SHOW "ENCOUNTER!" CARD'
	card_toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			"Play the animated ENCOUNTER card before the round starts. Off = the chosen encounter just begins, no reveal."
		)
	)
	card_toggle.add_theme_font_size_override("font_size", 12)
	card_toggle.button_pressed = bool(arr[idx].get("show_encounter", true))
	card_toggle.toggled.connect(func(on: bool) -> void: arr[idx]["show_encounter"] = on)
	wrapper.add_child(card_toggle)

	var norepeat_toggle: CheckButton = CheckButton.new()
	norepeat_toggle.text = "DON'T REPEAT CLIPS ACROSS COPIES"
	norepeat_toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			"If you copy this pool and it plays more than once in a run, skip clips it already showed. Once every clip has been shown it starts repeating again."
		)
	)
	norepeat_toggle.add_theme_font_size_override("font_size", 12)
	norepeat_toggle.button_pressed = bool(arr[idx].get("no_repeat", false))
	norepeat_toggle.toggled.connect(func(on: bool) -> void: arr[idx]["no_repeat"] = on)
	wrapper.add_child(norepeat_toggle)

	var list: VBoxContainer = VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	wrapper.add_child(list)
	_rebuild_pool_entries(arr, idx, list, reselect)

	var add_btn: Button = Button.new()
	add_btn.text = "+ ADD ENCOUNTER"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(
		func() -> void:
			(arr[idx]["pool_entries"] as Array).append(_default_pool_entry())
			_rebuild_pool_entries(arr, idx, list, reselect)
	)
	wrapper.add_child(add_btn)

	# Bulk add: drop videos and/or whole folders here — one encounter per video, funscript /
	# axis / vib siblings matched by file name (the same importer the canvas uses). Registered
	# so JourneyBuilder can route the OS drop here first; see try_handle_pool_drop.
	var drop: PanelContainer = _make_pool_drop_zone()
	wrapper.add_child(drop)
	_pool_drop = {"zone": drop, "arr": arr, "idx": idx, "list": list, "reselect": reselect}

	return wrapper


# The pool round's bulk drop target: a passive visual + hit-test rect. It deliberately does NOT
# listen for files_dropped itself — JourneyBuilder owns OS-drop routing (a folder drop would
# otherwise be claimed by the canvas bulk-importer before any side-panel handler ran).
func _make_pool_drop_zone() -> PanelContainer:
	var zone: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.PANEL_BG
	s.border_color = UITheme.PURPLE_MID
	s.set_border_width_all(2)
	s.set_corner_radius_all(UITheme.CORNER_RADIUS)
	s.set_content_margin_all(12)
	zone.add_theme_stylebox_override("panel", s)
	zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zone.mouse_filter = Control.MOUSE_FILTER_STOP

	var lbl: Label = Label.new()
	lbl.text = "⧉  DROP VIDEOS OR FOLDERS HERE\nOne encounter per video · scripts matched by name"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
	lbl.add_theme_font_size_override("font_size", 10)
	zone.add_child(lbl)
	return zone


# Consumes an OS file drop that landed on the pool round's drop zone, turning it into encounter
# entries; returns false when there's no live zone under the cursor (so the caller falls through
# to its normal routing). JourneyBuilder calls this FIRST — otherwise a dropped folder would be
# bulk-imported as new round nodes onto the canvas instead.
func try_handle_pool_drop(files: PackedStringArray) -> bool:
	if _pool_drop.is_empty():
		return false
	var zone: Control = _pool_drop.get("zone", null)
	if not is_instance_valid(zone) or not zone.is_visible_in_tree():
		return false
	if not zone.get_global_rect().has_point(zone.get_viewport().get_mouse_position()):
		return false
	# Claim the drop now, but add deferred: this runs inside the files_dropped emission, and the
	# add rebuilds the entry rows — whose per-field DropZones are listening to that same signal.
	_bulk_add_pool_entries.call_deferred(
		_pool_drop["arr"], _pool_drop["idx"], _pool_drop["list"], _pool_drop["reselect"], files
	)
	return true


# Expands the raw selection (recursing into folders), groups it into video+scripts sets via
# the shared importer, and appends one pool entry per video. Reports how many were added and
# how many funscripts were skipped for lacking a matching video.
func _bulk_add_pool_entries(
	arr: Array, idx: int, list: VBoxContainer, reselect: Callable, files: PackedStringArray
) -> void:
	var expanded: PackedStringArray = ImportScanner.expand_dropped_paths(files)
	var result: Dictionary = ImportScanner.build_rounds(expanded)
	var rounds: Array = result["rounds"]
	var skipped: int = int(result["skipped_no_video"])

	if rounds.is_empty():
		var msg: String = "No encounters added — no videos found in the selection."
		if skipped > 0:
			msg = (
				"No encounters added — found %d funscript%s with no matching video."
				% [skipped, "s" if skipped != 1 else ""]
			)
		_owner._show_status(msg, true)
		return

	var entries: Array = arr[idx]["pool_entries"]
	for r: Dictionary in rounds:
		(
			entries
			. append(
				{
					"name": str(r.get("name", "")),
					"video_path": str(r.get("video_path", "")),
					"funscript_path": str(r.get("funscript_path", "")),
					"axis_scripts": (r.get("axis_scripts", {}) as Dictionary).duplicate(),
					"vib_scripts": (r.get("vib_scripts", {}) as Dictionary).duplicate(),
					"weight": 1,
				}
			)
		)
	_rebuild_pool_entries(arr, idx, list, reselect)

	var note: String = "Added %d encounter%s." % [rounds.size(), "s" if rounds.size() != 1 else ""]
	if skipped > 0:
		note += (
			" Skipped %d funscript%s with no matching video."
			% [skipped, "s" if skipped != 1 else ""]
		)
	_owner._show_status(note, false)


func _default_pool_entry() -> Dictionary:
	return {
		"name": "",
		"video_path": "",
		"funscript_path": "",
		"axis_scripts": {},
		"vib_scripts": {},
		"weight": 1,
		"round_type": "normal",  # per-entry type: a rolled encounter can be normal or boss
	}


# Reorders (swaps) a pool entry by `delta` (±1); no-op at the ends.
func _move_pool_entry(arr: Array, idx: int, e_idx: int, delta: int) -> void:
	var entries: Array = arr[idx].get("pool_entries", [])
	var j: int = e_idx + delta
	if j < 0 or j >= entries.size():
		return
	var tmp: Variant = entries[e_idx]
	entries[e_idx] = entries[j]
	entries[j] = tmp


func _rebuild_pool_entries(arr: Array, idx: int, list: VBoxContainer, reselect: Callable) -> void:
	for c: Node in list.get_children():
		c.queue_free()
	var entries: Array = arr[idx].get("pool_entries", [])
	if entries.is_empty():
		var empty: Label = Label.new()
		empty.text = "No encounters yet — add at least one."
		empty.add_theme_color_override("font_color", UITheme.SEPARATOR)
		empty.add_theme_font_size_override("font_size", 10)
		list.add_child(empty)
		return
	# Aggregate readout: the runtime rolls ONE encounter by weight, so show the weighted average + the
	# min–max range across entries (mirrors the balance audit's pool bounds).
	var summary_text: String = _pool_entries_summary(entries)
	if summary_text != "":
		var summary: Label = Label.new()
		summary.text = summary_text
		summary.add_theme_color_override("font_color", UITheme.SEPARATOR)
		summary.add_theme_font_size_override("font_size", 10)
		summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(summary)
	for i: int in entries.size():
		list.add_child(_make_pool_entry_row(arr, idx, list, i, reselect))


# Aggregate readout for a pool round: the weighted-AVERAGE runtime + action count (the expected value), plus
# the min–max RANGE an actual roll can hit. Skips entries with no readable funscript; "" when none read yet.
func _pool_entries_summary(entries: Array) -> String:
	var len_lo: int = -1
	var len_hi: int = 0
	var cnt_lo: int = -1
	var cnt_hi: int = 0
	var len_wsum: float = 0.0
	var cnt_wsum: float = 0.0
	var wtotal: float = 0.0
	for e: Variant in entries:
		var p: String = str((e as Dictionary).get("funscript_path", ""))
		if p == "" or not FileAccess.file_exists(p):
			continue
		var st: Dictionary = JourneyData.read_funscript_stats(p)
		var ms: int = int(st.get("length_ms", 0))
		var c: int = int(st.get("count", 0))
		var w: float = float(maxi(1, int((e as Dictionary).get("weight", 1))))
		len_wsum += ms * w
		cnt_wsum += c * w
		wtotal += w
		len_lo = ms if len_lo < 0 else mini(len_lo, ms)
		len_hi = maxi(len_hi, ms)
		cnt_lo = c if cnt_lo < 0 else mini(cnt_lo, c)
		cnt_hi = maxi(cnt_hi, c)
	if wtotal <= 0.0:
		return ""
	var len_avg: int = int(len_wsum / wtotal)
	var cnt_avg: int = int(cnt_wsum / wtotal)
	if len_lo == len_hi and cnt_lo == cnt_hi:  # every encounter is the same size — no range to show
		return "Runtime %s  ·  %d actions" % [_format_duration(len_avg), cnt_avg]
	return (
		"Runtime %s–%s (avg %s)  ·  %d–%d actions (avg %d)"
		% [
			_format_duration(len_lo),
			_format_duration(len_hi),
			_format_duration(len_avg),
			cnt_lo,
			cnt_hi,
			cnt_avg,
		]
	)


func _make_pool_entry_row(
	arr: Array, idx: int, list: VBoxContainer, e_idx: int, reselect: Callable
) -> Control:
	var entries: Array = arr[idx]["pool_entries"]
	var entry: Dictionary = entries[e_idx]

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.CARD_BG
	ps.set_corner_radius_all(UITheme.CORNER_RADIUS)
	ps.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", ps)

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	panel.add_child(box)

	# Header: label + reorder + remove.
	var header: HBoxContainer = HBoxContainer.new()
	var title: Label = Label.new()
	title.text = "ENCOUNTER %d" % (e_idx + 1)
	title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	title.add_theme_font_size_override("font_size", 11)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var up: Button = UITheme.make_icon_btn("↑", e_idx == 0, UITheme.PURPLE_MID)
	up.pressed.connect(
		func() -> void:
			_move_pool_entry(arr, idx, e_idx, -1)
			_rebuild_pool_entries(arr, idx, list, reselect)
	)
	header.add_child(up)
	var down: Button = UITheme.make_icon_btn("↓", e_idx >= entries.size() - 1, UITheme.PURPLE_MID)
	down.pressed.connect(
		func() -> void:
			_move_pool_entry(arr, idx, e_idx, 1)
			_rebuild_pool_entries(arr, idx, list, reselect)
	)
	header.add_child(down)
	var rm: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	rm.tooltip_text = UITheme.wrap_tip("Remove this encounter")
	rm.pressed.connect(
		func() -> void:
			(arr[idx]["pool_entries"] as Array).remove_at(e_idx)
			_rebuild_pool_entries(arr, idx, list, reselect)
	)
	header.add_child(rm)
	box.add_child(header)

	# Name.
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Encounter name (optional)"
	name_edit.text = str(entry.get("name", ""))
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: entry["name"] = v)
	box.add_child(name_edit)

	# Video (drop or browse). Auto-fills the funscript + axis/vib from same-named
	# siblings on disk (reuses the round importer), then rebuilds to show them.
	var vzone: PanelContainer = DropZoneScript.new()
	vzone.accepted_extensions = JourneyData.VIDEO_EXTENSIONS.duplicate()
	vzone.picker_title = "Select Encounter Video"
	vzone.picker_filters = [
		"*.mp4,*.m4v,*.mkv,*.avi,*.mov,*.wmv,*.webm ; Video Files", "*.* ; All Files"
	]
	vzone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(vzone)
	if str(entry.get("video_path", "")) != "":
		vzone.call_deferred("set_file", entry["video_path"], false)
	vzone.file_dropped.connect(
		func(p: String) -> void:
			entry["video_path"] = p
			if str(entry.get("name", "")).strip_edges() == "":
				entry["name"] = p.get_file().get_basename()
			ImportScanner.autofill_round_siblings(entry, p)
			_rebuild_pool_entries(arr, idx, list, reselect)
	)

	# Funscript (drop or browse).
	box.add_child(_side_field_label("FUNSCRIPT"))
	var fzone: PanelContainer = DropZoneScript.new()
	fzone.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
	fzone.picker_title = "Select Encounter Funscript"
	fzone.picker_filters = ["*.funscript,*.json ; Funscript Files", "*.* ; All Files"]
	fzone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(fzone)
	if str(entry.get("funscript_path", "")) != "":
		fzone.call_deferred("set_file", entry["funscript_path"], false)
	fzone.file_dropped.connect(func(p: String) -> void: entry["funscript_path"] = p)

	# Secondary device scripts — the round editor's own expanders, bound to THIS entry, so a
	# pooled encounter carries the same multi-axis / vibrator setup a normal round can. (The data
	# already round-tripped: dropping a video autofills these from same-named siblings, and
	# save/scan/runtime have always carried an entry's axis_scripts / vib_scripts — until now
	# there was just no way to see or edit them.)
	var entry_arr: Array = [entry]
	box.add_child(_make_axis_expander(entry_arr, 0))
	box.add_child(_make_vib_expander(entry_arr, 0))

	# Weight (spawn rarity).
	var wrow: HBoxContainer = HBoxContainer.new()
	wrow.add_theme_constant_override("separation", 6)
	var wlbl: Label = Label.new()
	wlbl.text = "WEIGHT"
	wlbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	wlbl.add_theme_font_size_override("font_size", 10)
	wlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrow.add_child(wlbl)
	var wspin: SpinBox = SpinBox.new()
	wspin.min_value = 1
	wspin.max_value = 100
	wspin.step = 1
	wspin.value = maxi(1, int(entry.get("weight", 1)))
	UITheme.style_spin_box(wspin)
	wspin.value_changed.connect(func(v: float) -> void: entry["weight"] = int(v))
	wrow.add_child(wspin)
	box.add_child(wrow)

	# Per-entry type — reuse the round's Boss expander, bound to THIS entry. Toggling it sets the
	# entry's round_type; when this encounter is the one rolled at runtime, the round plays as a
	# boss (its own modifiers / tagline / image). Left off, the entry plays as a normal round.
	box.add_child(HSeparator.new())
	var rebuild_entries: Callable = func(_i: int) -> void:
		_rebuild_pool_entries(arr, idx, list, reselect)
	box.add_child(_make_boss_expander(entry_arr, 0, rebuild_entries))

	return panel


# Effect-round expander. One round type (mutually exclusive with Boss) that applies a
# mix of gameplay hindrances and/or boons plus an optional sensory layer, framed by
# author-set visuals (border/accent colour pickers + header/icon), with an optional
# resolvable (cleanse/endure) layer. Replaces the
# retired cursed/blessed toggles; a legacy cursed/blessed node is migrated in place the
# first time it's edited so it shows — and next saves — as a generic effect round.
func _make_effect_expander(arr: Array, idx: int, reselect: Callable) -> Control:
	if not arr[idx].has("round_type"):
		arr[idx]["round_type"] = "normal"
	var rt: String = str(arr[idx]["round_type"])
	if rt == "cursed" or rt == "blessed":
		var norm: Dictionary = JourneyData.normalize_effect_round(arr[idx])
		for k: String in norm:
			arr[idx][k] = norm[k]
		for legacy: String in [
			"curses", "boons", "curse_random", "boon_random", "curse_reward", "theme"
		]:
			arr[idx].erase(legacy)
	var is_effect: bool = arr[idx]["round_type"] == "effect"

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 6)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = "✦  EFFECT ROUND  ✓" if is_effect else "✦  EFFECT ROUND"
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = is_effect
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.PURPLE_MID)
	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			arr[idx]["round_type"] = "effect" if pressed else "normal"
			reselect.call(idx)
	)
	wrapper.add_child(toggle_btn)

	if not is_effect:
		return wrapper

	var hint: Label = Label.new()
	hint.text = "Applies a mix of gameplay effects (hindrances and/or boons) plus optional sensory modifiers at the start. Items stay usable. Tick nothing for a pure visual round (intro card + border only)."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wrapper.add_child(hint)

	wrapper.add_child(_make_reveal_toggle(arr, idx))

	# ── Framing (border on/off + colours + card header) ──
	wrapper.add_child(HSeparator.new())
	wrapper.add_child(_side_field_label("APPEARANCE"))

	# Screen border — an edge frame drawn around the play area for the round. Off by
	# default; the colour picker below only matters when it's on.
	var show_border: bool = bool(arr[idx].get("show_border", false))
	var border_toggle: CheckButton = CheckButton.new()
	border_toggle.text = "SHOW SCREEN BORDER"
	border_toggle.tooltip_text = UITheme.wrap_tip(
		"Draws a coloured edge frame around the play area for this round (no screen tint)."
	)
	border_toggle.add_theme_font_size_override("font_size", 12)
	border_toggle.button_pressed = show_border
	border_toggle.toggled.connect(
		func(on: bool) -> void:
			arr[idx]["show_border"] = on
			reselect.call(idx)
	)
	wrapper.add_child(border_toggle)
	if show_border:
		wrapper.add_child(
			_make_effect_color_field(
				arr, idx, "frame_color", "BORDER COLOUR", JourneyData.EFFECT_COLOR_NEUTRAL
			)
		)

	wrapper.add_child(
		_make_effect_color_field(
			arr, idx, "card_accent", "INTRO CARD ACCENT", JourneyData.EFFECT_COLOR_NEUTRAL
		)
	)
	wrapper.add_child(
		_make_effect_text_field(arr, idx, "card_header", "INTRO CARD HEADER", "EFFECT")
	)

	# ── Resolvable (cleanse / endure) layer — optional on any effect round ──
	wrapper.add_child(HSeparator.new())
	var resolvable: bool = bool(arr[idx].get("resolvable", false))
	var res_toggle: CheckButton = CheckButton.new()
	res_toggle.text = "RESOLVABLE (pay to cleanse / endure for a reward)"
	res_toggle.add_theme_font_size_override("font_size", 12)
	res_toggle.button_pressed = resolvable
	res_toggle.toggled.connect(
		func(on: bool) -> void:
			arr[idx]["resolvable"] = on
			reselect.call(idx)
	)
	wrapper.add_child(res_toggle)
	if resolvable:
		wrapper.add_child(
			_make_effect_int_field(arr, idx, "cleanse_cost", "CLEANSE COST (COINS)", 50)
		)
		wrapper.add_child(
			_make_effect_int_field(arr, idx, "endure_reward", "ENDURE REWARD (COINS)", 0)
		)

	# ── Effect selection (hindrances + boons in one list) ──
	wrapper.add_child(HSeparator.new())
	var rand_toggle: CheckButton = CheckButton.new()
	rand_toggle.text = "RANDOM (roll the effect)"
	rand_toggle.add_theme_font_size_override("font_size", 12)
	rand_toggle.button_pressed = bool(arr[idx].get("effect_random", true))
	rand_toggle.toggled.connect(func(on: bool) -> void: arr[idx]["effect_random"] = on)
	wrapper.add_child(rand_toggle)

	wrapper.add_child(_build_effect_catalog_picker(arr, idx))

	# ── Sensory layer (always-apply modifiers + optional random pool) ──
	wrapper.add_child(HSeparator.new())
	var pool_toggle: CheckButton = CheckButton.new()
	pool_toggle.text = "INCLUDE SENSORY IN RANDOM POOL"
	pool_toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			"When on, the random roll can also surface non-gameplay modifiers from the full sensory set (not just ticked ones)."
		)
	)
	pool_toggle.add_theme_font_size_override("font_size", 12)
	pool_toggle.button_pressed = bool(arr[idx].get("sensory_in_pool", false))
	pool_toggle.toggled.connect(func(on: bool) -> void: arr[idx]["sensory_in_pool"] = on)
	wrapper.add_child(pool_toggle)
	wrapper.add_child(_build_sensory_picker(arr, idx, true))  # effect rounds can rename sensory

	return wrapper


# The gameplay-effect selection list: hindrances + boons, each tickable (and, once ticked,
# renamable / reflavorable / tunable via _make_effect_row), plus the Gift-boon item picker.
# Shared by the effect expander and the boss expander — a boss now carries the full catalog on
# top of its raw modifiers. Reads/writes arr[idx]["effects"] (+ effect_overrides / gift_item).
func _build_effect_catalog_picker(arr: Array, idx: int) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var selected: Array = arr[idx].get("effects", [])
	var custom_hint: Label = Label.new()
	custom_hint.text = "Tick an effect to rename it, reflavor it, or tune its strength."
	custom_hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	custom_hint.add_theme_font_size_override("font_size", 10)
	custom_hint.uppercase = true
	custom_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(custom_hint)
	box.add_child(_side_field_label("HINDRANCES  (NONE TICKED = NO EFFECT)"))
	for entry: Dictionary in JourneyData.CURSE_CATALOG:
		box.add_child(_make_effect_row(arr, idx, entry, selected))
	box.add_child(_side_field_label("BOONS"))
	for entry: Dictionary in JourneyData.BLESSING_CATALOG:
		box.add_child(_make_effect_row(arr, idx, entry, selected))

	box.add_child(_side_field_label("GIFT ITEM  (FOR THE GIFT BOON)"))
	var values: Array = [""]
	var gift_dd: OptionButton = OptionButton.new()
	gift_dd.add_item("None")
	for k: String in _all_item_ids():
		values.append(k)
		gift_dd.add_item(_item_display_name(k))
	gift_dd.selected = max(0, values.find(str(arr[idx].get("gift_item", ""))))
	gift_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(gift_dd)
	_apply_item_tooltips(gift_dd, values)
	gift_dd.item_selected.connect(func(i: int) -> void: arr[idx]["gift_item"] = values[i])
	box.add_child(gift_dd)
	return box


# Labeled int SpinBox bound to arr[idx][key]. Used by the effect-round fields.
func _make_effect_int_field(arr: Array, idx: int, key: String, label: String, def: int) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_side_field_label(label))
	var spin: SpinBox = SpinBox.new()
	spin.min_value = 0
	spin.max_value = 999999
	spin.step = 1
	spin.value = int(arr[idx].get(key, def))
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(func(v: float) -> void: arr[idx][key] = int(v))
	box.add_child(spin)
	return box


# Labeled free-text LineEdit bound to arr[idx][key] (blank falls back to `placeholder`,
# baked in at save). Used by the effect-round card header / icon fields.
func _make_effect_text_field(
	arr: Array, idx: int, key: String, label: String, placeholder: String
) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_side_field_label(label))
	var edit: LineEdit = LineEdit.new()
	edit.text = str(arr[idx].get(key, ""))
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(edit)
	edit.text_changed.connect(func(val: String) -> void: arr[idx][key] = val)
	box.add_child(edit)
	return box


# Labeled colour picker bound to arr[idx][key] as an "#rrggbb" string. Falls back to
# `default_hex` when the round has no stored colour yet (new round).
func _make_effect_color_field(
	arr: Array, idx: int, key: String, label: String, default_hex: String
) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_side_field_label(label))
	var stored: String = str(arr[idx].get(key, ""))
	var picker: ColorPickerButton = ColorPickerButton.new()
	picker.edit_alpha = false
	picker.color = (
		Color.html(stored)
		if (stored != "" and Color.html_is_valid(stored))
		else Color.html(default_hex)
	)
	picker.custom_minimum_size = Vector2(0, 28)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.color_changed.connect(func(c: Color) -> void: arr[idx][key] = "#" + c.to_html(false))
	box.add_child(picker)
	return box


# One effect row: a tick bound to the round's effects list and, while ticked, an indented
# sub-editor to customize it — a name + flavor override (all kinds) and a magnitude control
# for the non-stroke numeric kinds (coin/score/toll/interest). STROKE kinds (scale/clamp)
# show a hint pointing to the funscript preview, where their magnitude is tuned live.
func _make_effect_row(arr: Array, idx: int, entry: Dictionary, selected: Array) -> Control:
	var nm: String = str(entry.get("name", ""))
	var kind: String = str(entry.get("kind", ""))
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)

	var cb: CheckButton = CheckButton.new()
	cb.text = nm
	cb.tooltip_text = UITheme.wrap_tip(str(entry.get("desc", "")))
	cb.add_theme_font_size_override("font_size", 11)
	cb.button_pressed = nm in selected
	col.add_child(cb)

	# Indented sub-editor, shown only while the effect is ticked.
	var indent: MarginContainer = MarginContainer.new()
	indent.add_theme_constant_override("margin_left", 28)
	indent.visible = cb.button_pressed
	col.add_child(indent)
	var editor: VBoxContainer = VBoxContainer.new()
	editor.add_theme_constant_override("separation", 3)
	indent.add_child(editor)

	editor.add_child(_effect_override_text(arr, idx, nm, "name", "NAME", nm))
	editor.add_child(
		_effect_override_text(arr, idx, nm, "desc", "FLAVOR", str(entry.get("desc", "")))
	)
	if JourneyData.is_stroke_effect(kind):
		if not JourneyData.effect_param_specs(kind).is_empty():
			var h: Label = _side_field_label("↳ tune magnitude in the funscript preview")
			h.add_theme_color_override("font_color", UITheme.PURPLE_MID)
			editor.add_child(h)
	else:
		for spec: Dictionary in JourneyData.effect_param_specs(kind):
			editor.add_child(_effect_override_number(arr, idx, nm, spec, entry))

	cb.toggled.connect(
		func(on: bool) -> void:
			_toggle_effect(arr, idx, nm, on)
			indent.visible = on
	)
	return col


# Free-text override (name / flavor) for one effect. Blank clears the override (the catalog
# default, shown as placeholder, is used). Kept as a diff in effect_overrides[name].
func _effect_override_text(
	arr: Array, idx: int, effect_name: String, key: String, label: String, placeholder: String
) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(_side_field_label(label))
	var edit: LineEdit = LineEdit.new()
	edit.text = str(_stored_override(arr, idx, effect_name, key, ""))
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(edit)
	edit.text_changed.connect(
		func(val: String) -> void:
			_set_effect_override(arr, idx, effect_name, key, null if val == "" else val)
	)
	box.add_child(edit)
	return box


# Magnitude override for a non-stroke numeric effect (coin_penalty/coin_jackpot/
# score_multiplier/toll/interest). Shows the current value (override or catalog default);
# returning it to the default clears the override so the diff stays minimal.
func _effect_override_number(
	arr: Array, idx: int, effect_name: String, spec: Dictionary, entry: Dictionary
) -> Control:
	var key: String = str(spec.get("key", ""))
	var ctl: String = str(spec.get("ctl", ""))
	var view_scale: float = 100.0 if ctl == "pct" else 1.0  # store 0–1, show as %
	var default_val: float = float(entry.get(key, spec.get("min", 0)))

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(_side_field_label(str(spec.get("label", key))))
	var spin: SpinBox = SpinBox.new()
	spin.min_value = float(spec.get("min", 0)) * view_scale
	spin.max_value = float(spec.get("max", 1)) * view_scale
	spin.step = float(spec.get("step", 1)) * view_scale
	spin.suffix = "%" if ctl == "pct" else ("×" if ctl == "mult" else "")
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(spin)
	var stored: Variant = _stored_override(arr, idx, effect_name, key, null)
	var current: float = float(stored) if stored != null else default_val
	spin.set_value_no_signal(current * view_scale)
	spin.value_changed.connect(
		func(v: float) -> void:
			var real: float = v / view_scale
			var store_val: Variant = int(round(real)) if ctl == "coins" else real
			if is_equal_approx(float(store_val), default_val):
				_set_effect_override(arr, idx, effect_name, key, null)  # back to default → drop
			else:
				_set_effect_override(arr, idx, effect_name, key, store_val)
	)
	box.add_child(spin)
	return box


# The stored override value for effect_overrides[effect_name][key], or `default` if unset.
func _stored_override(
	arr: Array, idx: int, effect_name: String, key: String, default: Variant
) -> Variant:
	var ovs: Dictionary = arr[idx].get("effect_overrides", {})
	return (ovs.get(effect_name, {}) as Dictionary).get(key, default)


# Writes (or, when `value` is null, clears) one override key, pruning empty maps so the diff
# stays minimal (matching the runtime's "absent = catalog default" contract).
func _set_effect_override(
	arr: Array, idx: int, effect_name: String, key: String, value: Variant
) -> void:
	if not arr[idx].has("effect_overrides"):
		if value == null:
			return
		arr[idx]["effect_overrides"] = {}
	var ovs: Dictionary = arr[idx]["effect_overrides"]
	if not ovs.has(effect_name):
		if value == null:
			return
		ovs[effect_name] = {}
	var eff: Dictionary = ovs[effect_name]
	if value == null:
		eff.erase(key)
	else:
		eff[key] = value
	if eff.is_empty():
		ovs.erase(effect_name)
	if ovs.is_empty():
		arr[idx].erase("effect_overrides")


# Adds/removes an effect name from an effect round's selected-effects list.
func _toggle_effect(arr: Array, idx: int, effect_name: String, on: bool) -> void:
	if not arr[idx].has("effects"):
		arr[idx]["effects"] = []
	var list: Array = arr[idx]["effects"]
	if on:
		if effect_name not in list:
			list.append(effect_name)
	else:
		list.erase(effect_name)


# A "Non-gameplay modifiers" checklist bound to arr[idx]["sensory"], split into
# Visual and Audio subsections. Shared by the boss and cursed editors.
func _build_sensory_picker(arr: Array, idx: int, allow_rename: bool = false) -> Control:
	if not arr[idx].has("sensory"):
		arr[idx]["sensory"] = []
	var selected: Array = arr[idx]["sensory"]

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	# Collapsed by default to keep the panel tidy; auto-expanded when the round
	# already has modifiers so its setup is visible at a glance.
	var open: bool = not selected.is_empty()
	var header: Button = Button.new()
	header.toggle_mode = true
	header.button_pressed = open
	header.text = (
		("▼  NON-GAMEPLAY MODIFIERS  (%d)" % selected.size())
		if open
		else "▶  NON-GAMEPLAY MODIFIERS"
	)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(header, UITheme.PURPLE_MID)
	wrapper.add_child(header)

	var content: VBoxContainer = VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	content.visible = open
	wrapper.add_child(content)

	content.add_child(_side_field_label("VISUAL"))
	for entry: Dictionary in JourneyData.SENSORY_CATALOG:
		if str(entry.get("kind", "")) not in JourneyData.AUDIO_SENSORY_KINDS:
			content.add_child(_make_sensory_row(arr, idx, entry, selected, allow_rename))

	content.add_child(HSeparator.new())
	content.add_child(_side_field_label("AUDIO"))
	for entry: Dictionary in JourneyData.SENSORY_CATALOG:
		if str(entry.get("kind", "")) in JourneyData.AUDIO_SENSORY_KINDS:
			content.add_child(_make_sensory_row(arr, idx, entry, selected, allow_rename))

	header.toggled.connect(
		func(on: bool) -> void:
			content.visible = on
			header.text = (
				("▼  NON-GAMEPLAY MODIFIERS  (%d)" % (arr[idx].get("sensory", []) as Array).size())
				if on
				else "▶  NON-GAMEPLAY MODIFIERS"
			)
	)
	return wrapper


# One non-gameplay-modifier row: a tick (bound to the round's sensory list) and,
# for effects with an adjustable strength, an intensity control on its own
# indented line below — a slider plus a synced % spin box for precise entry. The
# control is only editable while the modifier is ticked; binary effects
# (Blinded/Silence) show no control.
func _make_sensory_row(
	arr: Array, idx: int, entry: Dictionary, selected: Array, allow_rename: bool = false
) -> Control:
	var sname: String = str(entry.get("name", ""))
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)

	var cb: CheckButton = CheckButton.new()
	cb.text = sname
	cb.tooltip_text = UITheme.wrap_tip(str(entry.get("desc", "")))
	cb.add_theme_font_size_override("font_size", 11)
	cb.button_pressed = sname in selected
	col.add_child(cb)

	# Rename / reflavor editor (effect rounds only), indented, shown while ticked. Shares the
	# effect_overrides map with gameplay effects — sensory keeps its own intensity control below.
	var rename_indent: MarginContainer = null
	if allow_rename:
		rename_indent = MarginContainer.new()
		rename_indent.add_theme_constant_override("margin_left", 28)
		rename_indent.visible = cb.button_pressed
		var ed: VBoxContainer = VBoxContainer.new()
		ed.add_theme_constant_override("separation", 3)
		ed.add_child(_effect_override_text(arr, idx, sname, "name", "NAME", sname))
		ed.add_child(
			_effect_override_text(arr, idx, sname, "desc", "FLAVOR", str(entry.get("desc", "")))
		)
		rename_indent.add_child(ed)
		col.add_child(rename_indent)

	if not entry.has("idef"):
		cb.toggled.connect(
			func(on: bool) -> void:
				_toggle_sensory(arr, idx, sname, on)
				if rename_indent != null:
					rename_indent.visible = on
		)
		return col

	# Intensity line, indented under the checkbox: slider (drag) + spin box (exact).
	var indent: MarginContainer = MarginContainer.new()
	indent.add_theme_constant_override("margin_left", 28)
	col.add_child(indent)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	indent.add_child(row)

	var slider: HSlider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.tooltip_text = UITheme.wrap_tip("Intensity")
	row.add_child(slider)

	var spin: SpinBox = SpinBox.new()
	spin.min_value = 0.0
	spin.max_value = 100.0
	spin.step = 1.0
	spin.suffix = "%"
	spin.custom_minimum_size = Vector2(68, 0)
	UITheme.style_spin_box(spin)
	row.add_child(spin)

	var pct: float = _sensory_intensity_pct(arr, idx, entry)
	slider.set_value_no_signal(pct)
	spin.set_value_no_signal(pct)
	slider.editable = cb.button_pressed
	spin.editable = cb.button_pressed

	# Keep the two in sync without re-triggering each other, and persist the value.
	slider.value_changed.connect(
		func(v: float) -> void:
			spin.set_value_no_signal(v)
			_set_sensory_intensity(arr, idx, sname, v / 100.0)
	)
	spin.value_changed.connect(
		func(v: float) -> void:
			slider.set_value_no_signal(v)
			_set_sensory_intensity(arr, idx, sname, v / 100.0)
	)
	cb.toggled.connect(
		func(on: bool) -> void:
			_toggle_sensory(arr, idx, sname, on)
			slider.editable = on
			spin.editable = on
			if rename_indent != null:
				rename_indent.visible = on
	)
	return col


# The stored intensity for a modifier as a 0–100 percentage (author override, or
# the catalog default when unset).
func _sensory_intensity_pct(arr: Array, idx: int, entry: Dictionary) -> float:
	var nm: String = str(entry.get("name", ""))
	var overrides: Dictionary = arr[idx].get("sensory_intensity", {})
	var v: float = float(overrides[nm]) if overrides.has(nm) else float(entry.get("idef", 0.5))
	return v * 100.0


# Stores a modifier's intensity override (normalized 0–1) on the round.
func _set_sensory_intensity(arr: Array, idx: int, sensory_name: String, value: float) -> void:
	if not arr[idx].has("sensory_intensity"):
		arr[idx]["sensory_intensity"] = {}
	(arr[idx]["sensory_intensity"] as Dictionary)[sensory_name] = clampf(value, 0.0, 1.0)


# Back-compat: older journeys could carry visual/audio kinds (e.g. BLACKOUT) as
# boss FORCED modifiers. Those kinds are now non-gameplay, so on load we move them
# into the round's sensory list and drop them from boss_modifiers. Idempotent.
func _migrate_sensory_boss_modifiers(arr: Array, idx: int) -> void:
	var mods: Array = arr[idx].get("boss_modifiers", [])
	if mods.is_empty():
		return
	var kept: Array = []
	for mod: Dictionary in mods:
		var mname: String = _sensory_name_for_kind(str(mod.get("kind", "")))
		if mname == "":
			kept.append(mod)  # genuine gameplay modifier — leave it
			continue
		if not arr[idx].has("sensory"):
			arr[idx]["sensory"] = []
		if mname not in (arr[idx]["sensory"] as Array):
			(arr[idx]["sensory"] as Array).append(mname)
	if kept.size() != mods.size():
		arr[idx]["boss_modifiers"] = kept


# The SENSORY_CATALOG display name for a kind, or "" if the kind isn't sensory.
func _sensory_name_for_kind(kind: String) -> String:
	for entry: Dictionary in JourneyData.SENSORY_CATALOG:
		if str(entry.get("kind", "")) == kind:
			return str(entry.get("name", ""))
	return ""


# Adds/removes a non-gameplay modifier name from a round's sensory list.
func _toggle_sensory(arr: Array, idx: int, sensory_name: String, on: bool) -> void:
	if not arr[idx].has("sensory"):
		arr[idx]["sensory"] = []
	var list: Array = arr[idx]["sensory"]
	if on:
		if sensory_name not in list:
			list.append(sensory_name)
	else:
		list.erase(sensory_name)


# A "Show intro card" toggle (default on) — whether an effect round plays its animated
# reveal card naming the effect(s) before the video starts. Off = surprise the player.
func _make_reveal_toggle(arr: Array, idx: int) -> CheckButton:
	var t: CheckButton = CheckButton.new()
	t.text = "SHOW INTRO CARD"
	t.tooltip_text = (
		UITheme
		. wrap_tip(
			"Play the animated card naming the effect(s) before the round starts. Off = no telegraph; the effect just hits."
		)
	)
	t.add_theme_font_size_override("font_size", 12)
	t.button_pressed = bool(arr[idx].get("show_reveal", true))
	t.toggled.connect(func(on: bool) -> void: arr[idx]["show_reveal"] = on)
	return t


# Stroke-affecting modifiers to preview for this round, by type: boss modifiers
# directly, or the round's selected effect catalog entries — filtered to the
# kinds that actually change the funscript curve (others don't show in a preview).
func _round_preview_modifiers(item: Dictionary) -> Array:
	if item.get("round_type", "normal") == "boss":
		return _stroke_only(item.get("boss_modifiers", []))
	# Effect rounds (incl. un-migrated legacy cursed/blessed): resolve each selected gameplay
	# effect against the round's overrides so the curve reflects current tuning, keep only the
	# stroke kinds, and carry `_ref` so the preview's live tuner can write overrides back.
	var nr: Dictionary = JourneyData.normalize_effect_round(item)
	if nr.get("round_type", "normal") != "effect":
		return []
	var overrides: Dictionary = nr.get("effect_overrides", {})
	var out: Array = []
	for nm: Variant in nr.get("effects", []):
		var e: Dictionary = JourneyData.resolved_effect(str(nm), overrides)
		if not e.is_empty() and JourneyData.is_stroke_effect(str(e.get("kind", ""))):
			out.append(e)
	return out


func _round_preview_label(item: Dictionary) -> String:
	if JourneyData.normalize_effect_round(item).get("round_type", "normal") == "effect":
		return "Effect modifiers"
	return "Boss modifiers"


# Keeps only modifiers whose kind changes the stroke curve.
func _stroke_only(mods: Array) -> Array:
	var out: Array = []
	for m: Dictionary in mods:
		if String(m.get("kind", "")) in ["scale", "clamp", "reverse", "block"]:
			out.append(m)
	return out


# Returns a fresh modifier dict for `kind` seeded with sensible default params.
func _default_boss_modifier(kind: String) -> Dictionary:
	match kind:
		"scale":
			return {"kind": "scale", "factor": 1.2}
		"clamp":
			return {"kind": "clamp", "min": 0, "max": 50}
		"score_multiplier":
			return {"kind": "score_multiplier", "factor": 2.0}
		_:
			return {"kind": kind}


# Rebuilds the forced-modifier rows from scratch — called on add / remove / kind
# change so each row's parameter fields always match its kind.
func _rebuild_boss_modifiers(arr: Array, idx: int, list: VBoxContainer) -> void:
	for child in list.get_children():
		child.queue_free()
	var mods: Array = arr[idx].get("boss_modifiers", [])
	if mods.is_empty():
		var empty: Label = Label.new()
		empty.text = "NO MODIFIERS — THE BOSS PLAYS ITS SCRIPT AS-IS."
		empty.add_theme_color_override("font_color", UITheme.SEPARATOR)
		empty.add_theme_font_size_override("font_size", 10)
		empty.uppercase = true
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(empty)
		return
	for m_idx: int in mods.size():
		list.add_child(_make_boss_modifier_row(arr, idx, list, m_idx))


# Builds one forced-modifier row: a kind dropdown, kind-specific parameter
# fields, and a remove button.
func _make_boss_modifier_row(arr: Array, idx: int, list: VBoxContainer, m_idx: int) -> Control:
	var mod: Dictionary = arr[idx]["boss_modifiers"][m_idx]
	var kind: String = mod.get("kind", "scale")

	var panel: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.CARD_BG
	s.border_color = UITheme.PURPLE_MID
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", s)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	# Row 1 — kind dropdown + remove button.
	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	col.add_child(head)

	var kind_dd: OptionButton = OptionButton.new()
	for label: String in BOSS_MODIFIER_LABELS:
		kind_dd.add_item(label)
	kind_dd.selected = BOSS_MODIFIER_KINDS.find(kind)
	kind_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(kind_dd)
	head.add_child(kind_dd)
	kind_dd.item_selected.connect(
		func(sel: int) -> void:
			arr[idx]["boss_modifiers"][m_idx] = _default_boss_modifier(BOSS_MODIFIER_KINDS[sel])
			_rebuild_boss_modifiers(arr, idx, list)
	)

	var remove_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.DANGER)
	remove_btn.pressed.connect(
		func() -> void:
			(arr[idx]["boss_modifiers"] as Array).remove_at(m_idx)
			_rebuild_boss_modifiers(arr, idx, list)
	)
	head.add_child(remove_btn)

	# Row 2 — kind-specific parameters.
	match kind:
		"scale", "score_multiplier":
			var prow: HBoxContainer = HBoxContainer.new()
			prow.add_theme_constant_override("separation", 6)
			var plbl: Label = _side_field_label("FACTOR")
			plbl.custom_minimum_size = Vector2(60, 0)
			prow.add_child(plbl)
			var pedit: LineEdit = LineEdit.new()
			pedit.text = str(mod.get("factor", 1.0))
			pedit.custom_minimum_size = Vector2(70, 0)
			UITheme.style_line_edit(pedit)
			pedit.text_changed.connect(
				func(val: String) -> void:
					arr[idx]["boss_modifiers"][m_idx]["factor"] = maxf(0.0, val.to_float())
			)
			prow.add_child(pedit)
			col.add_child(prow)
		"clamp":
			var crow: HBoxContainer = HBoxContainer.new()
			crow.add_theme_constant_override("separation", 6)
			crow.add_child(_side_field_label("MIN"))
			var min_edit: LineEdit = LineEdit.new()
			min_edit.text = str(mod.get("min", 0))
			min_edit.custom_minimum_size = Vector2(56, 0)
			UITheme.style_line_edit(min_edit)
			min_edit.text_changed.connect(
				func(val: String) -> void:
					arr[idx]["boss_modifiers"][m_idx]["min"] = clampi(val.to_int(), 0, 100)
			)
			crow.add_child(min_edit)
			crow.add_child(_side_field_label("MAX"))
			var max_edit: LineEdit = LineEdit.new()
			max_edit.text = str(mod.get("max", 100))
			max_edit.custom_minimum_size = Vector2(56, 0)
			UITheme.style_line_edit(max_edit)
			max_edit.text_changed.connect(
				func(val: String) -> void:
					arr[idx]["boss_modifiers"][m_idx]["max"] = clampi(val.to_int(), 0, 100)
			)
			crow.add_child(max_edit)
			col.add_child(crow)
		_:
			var none_lbl: Label = Label.new()
			none_lbl.text = "NO PARAMETERS"
			none_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
			none_lbl.add_theme_font_size_override("font_size", 10)
			col.add_child(none_lbl)

	return panel


# Deletes an image file only if it lives inside the app's user data directory
# (i.e. it has already been saved into a journey folder). Staging paths that
# point to the user's own filesystem are left untouched — only the reference
# in the data dict is cleared by the caller.
func _delete_saved_image(path: String) -> void:
	if path == "":
		return
	var abs_path: String = ProjectSettings.globalize_path(path)
	var user_data: String = ProjectSettings.globalize_path("user://")
	if abs_path.begins_with(user_data) and FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)
