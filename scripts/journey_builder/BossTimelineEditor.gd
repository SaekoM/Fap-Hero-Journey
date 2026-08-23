class_name BossTimelineEditor
extends Node
## The boss-encounter editor: a near-fullscreen modal pairing a live PREVIEW STAGE (the round's video
## with cast cues, subtitles and animations drawn over it) with the BossTimeline lanes, a Boss Kit to
## add events from, an inspector for the selected one, and live validation (BOSS_ROUND_DESIGN §6).
##
## The preview is driven by the REAL RoundTimelineScheduler — the same object the GameLoop ticks — so
## what an author sees is the runtime's own decisions rather than a second implementation that could
## drift from it. Playing seeks the video and ticks the scheduler; scrubbing seeks it, which reconciles
## windows and re-arms one-shots exactly as a device re-anchor would mid-round.
##
## The device is deliberately NOT driven while previewing: scrubbing back and forth would jerk it
## repeatedly. Attacks are felt through the explicit ▶ TEST ON DEVICE on a selected attack instead.
##
## A Node (not a RefCounted) because playback needs a per-frame tick, and because being in the tree
## means the modal it owns is freed with it — the caller does not have to keep it alive.
##
## The timeline it edits is always kept in RoundTimeline's canonical shape: every mutation runs back
## through normalize(), so the editor cannot invent a shape the runtime would not accept, and the
## validation shown here is literally the validation the presave gate will run.

## The author pressed SAVE. Carries the edited timeline, already normalized.
signal saved(timeline: Dictionary)

# Default length for a newly-added window, long enough to be visible and grabbable at full zoom.
const NEW_WINDOW_MS: int = 5000

# How many undo steps are kept. Snapshots are whole timelines, but a timeline is a handful of small
# dictionaries — cheaper to copy wholesale than to model every edit as a reversible command.
# Fixed width of the right-hand inspector. Wide enough that the busiest panel (an effect's kind, its
# intensity and its two fade fields) reads without wrapping, and held constant so selecting a different
# event never resizes it — see _build_inspector_row.
const INSPECTOR_WIDTH: int = 520

# How far a branch sits inside the segment that owns it, and how wide its tag field is. A tag is a
# handful of characters; the indent is what makes the ownership visible at a glance.
const BRANCH_INDENT: int = 18
const BRANCH_TAG_WIDTH: int = 120

# How the left column's height is divided between the picture and the lanes, and the floor below which
# the lanes stop giving ground however tall the preview would like to be.
const STAGE_STRETCH: float = 1.5
const LANES_STRETCH: float = 1.0
const LANES_MIN_H: int = 180

# Side of the subtitle colour swatch. Square reads as a colour chip; the default button shape stretched
# to the row height and read as an oddly thin control.
const SWATCH_SIZE: int = 34

const UNDO_DEPTH: int = 60

# Repeated edits of the same KIND within this window collapse into one undo step, so dragging a block
# or scrubbing a spin box is a single undo rather than a hundred.
const COALESCE_MS: int = 500

# Entries in the track's right-click menu.
const CONTEXT_SET_WIN_POINT: int = 0
const CONTEXT_CLEAR_WIN_POINT: int = 1

var _timeline: Dictionary = {}
var _full_ms: int = 1
var _selected_id: String = ""
var _playhead_ms: int = 0
var _video_path: String = ""
var _funscript_path: String = ""
var _characters: Array = []  # the journey's cast, so a cue can name a character and preview their art
var _items: Array = []  # the journey's custom items — an override among them can seed an attack
# Whether the journey lets the player press FINISH. Defeat events are the response to that press, so
# with it off they are authorable but unreachable — worth saying plainly rather than letting someone
# build an ending that silently never plays.
var _allow_finish: bool = false
var _reference_points: Array = []  # the round's stroke as (t_ms, pos), reused by the effect overlays

var _modal: Control = null
var _timeline_view: BossTimeline = null
var _context_menu: PopupMenu = null
var _scrollbar: HScrollBar = null
var _inspector: VBoxContainer = null
# Which inspector sections are folded open. Held on the EDITOR rather than rebuilt with the panel: the
# inspector is torn down and rebuilt on every keystroke, so state living in it would fold everything
# closed while an author typed.
var _open_sections: Dictionary = {}
# event id → the problems validate() found with it. Marked on the block and spelled out in the
# inspector, so a warning never reflows the layout the way a growing footer label did.
var _issues: Dictionary = {}

# setup() resets zoom/pan, so it is a one-time call — see _refresh().
var _view_ready: bool = false

# Device test-play, created on first use and parented to the timeline so closing the modal stops it.
var _test_player: OverrideTestPlayer = null

# ── Preview stage ────────────────────────────────────────────────────────────

# The picture and everything that draws on it. The modal owns the document, the selection and the undo
# stack; the stage owns the video, the cue layer, the audio, the sensory engine, the health bar and the
# scheduler running them — because keeping the preview honest to the round is a job in its own right.
var _stage: BossPreviewStage = null

# The transport that drives it, which stays here: it is modal chrome, not part of the picture.
var _play_button: Button = null
var _time_label: Label = null
var _cycle_button: Button = null

# The pretend player the preview judges rules against, and the row of controls that sets it. Shown only
# once the encounter actually has a rule, because until then there is nothing for it to change.
var _sim_state: Dictionary = RoundTimeline.empty_state()
var _sim_row: Control = null

# ── Undo / clipboard ─────────────────────────────────────────────────────────

var _undo_stack: Array = []
var _redo_stack: Array = []
var _last_snapshot_tag: String = ""
var _last_snapshot_ms: int = 0
var _clipboard: Dictionary = {}

# The encounter exactly as it was opened, serialized — the baseline the dirty check compares against.
# Comparing the normalized JSON rather than tracking an "edited" flag means an edit that is undone back
# to the original correctly counts as clean again.
var _opened_json: String = ""

# True while the discard confirmation is up, so its own keystrokes are not read as editor shortcuts.
var _confirming: bool = false


## Opens the editor over `parent`. `timeline` is the round's current block ({} for a fresh encounter),
## `full_ms` the round video's length (the clock everything is placed against), and the two paths feed
## the preview stage and the timeline's sync reference.
func open(
	parent: Node,
	timeline: Dictionary,
	full_ms: int,
	video_path: String = "",
	funscript_path: String = "",
	characters: Array = [],
	items: Array = [],
	allow_finish: bool = false
) -> void:
	_timeline = RoundTimeline.normalize(timeline)
	_full_ms = maxi(1, full_ms)
	_video_path = video_path
	_funscript_path = funscript_path
	_characters = characters
	_items = items
	_allow_finish = allow_finish
	parent.add_child(self)  # in the tree, so the modal below is freed with this node

	var parts: Dictionary = UITheme.build_centered_modal(
		"◆ BOSS ENCOUNTER", UITheme.DANGER, _modal_size()
	)
	_modal = parts["modal"]
	var column: VBoxContainer = parts["vbox"]

	# The modal is two columns, not a stack. Everything that is about the ROUND — the picture, the
	# transport, the lanes — shares the left one and therefore shares a width; the inspector owns the
	# right one for the modal's whole height.
	#
	# It used to be a stack, with the timeline spanning the full width underneath both. That gave the
	# timeline width it did not need and cost the inspector the height it did: segments made the lanes
	# tall enough to squeeze everything above them, while the inspector — which is the thing with real
	# vertical content — was cut off at the stage's bottom edge and scrolled constantly.
	var body: HBoxContainer = HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)

	var work: VBoxContainer = VBoxContainer.new()
	work.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	work.size_flags_vertical = Control.SIZE_EXPAND_FILL
	work.add_theme_constant_override("separation", 6)
	work.add_child(_build_stage())
	# Transport and the Boss Kit share the strip between the stage and the lanes: both are things you
	# reach for WHILE looking at the timeline, so they sit next to it rather than up at the title.
	work.add_child(_build_transport_row())
	work.add_child(_build_sim_row())
	_build_timeline_row(work)
	body.add_child(work)

	body.add_child(_build_inspector_row())
	column.add_child(body)
	column.add_child(_build_footer())

	add_child(_modal)
	# No button in the editor takes keyboard focus: a focused Button activates on SPACE and ENTER, which
	# would fight the transport shortcut and re-trigger whatever was last clicked. Text fields and spin
	# boxes are unaffected, so typing still works.
	_disable_button_focus(_modal)
	_opened_json = JSON.stringify(_timeline)
	_load_preview_media()
	_refresh()


func _disable_button_focus(node: Node) -> void:
	if node is Button:
		(node as Button).focus_mode = Control.FOCUS_NONE
	for child: Node in node.get_children():
		_disable_button_focus(child)


# Near-fullscreen, sized off the viewport rather than fixed: the stage, four lanes, the inspector and
# the transport do not fit in a dialog-sized panel, and a hard-coded size would overflow small screens.
func _modal_size() -> Vector2i:
	var viewport: Vector2 = Vector2(1600, 900)
	if is_inside_tree():
		viewport = get_viewport().get_visible_rect().size
	return Vector2i(int(viewport.x * 0.94), int(viewport.y * 0.94))


# ── Preview stage ────────────────────────────────────────────────────────────


# The preview stage at the top of the working column. Everything about the picture — the video, the cue
# layer, the audio, the sensory engine, the health bar and the scheduler driving them — lives in
# BossPreviewStage. This only places it and listens for the two things the rest of the modal needs.
func _build_stage() -> Control:
	_stage = BossPreviewStage.new()
	_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The picture gets the larger share of the column, but the lanes below keep a real amount of it —
	# they are the thing being edited, and a preview nobody is looking at should not crowd them out.
	_stage.size_flags_stretch_ratio = STAGE_STRETCH
	_stage.build(_characters)
	_stage.deselect_requested.connect(func() -> void: _select(""))
	_stage.advanced.connect(_on_stage_advanced)
	return _stage


# Playback moved. The picture is the stage's; the playhead, the ruler and the clock are the modal's.
func _on_stage_advanced(position_ms: int) -> void:
	_playhead_ms = position_ms
	_timeline_view.set_playhead(position_ms)
	_update_time_label(position_ms)


func _build_transport_row() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	_play_button = Button.new()
	_play_button.text = "▶ PLAY"
	# Space is the play shortcut, and a FOCUSED button also activates on Space — which toggled playback
	# twice in one frame, so it looked like nothing happened. No editor button takes focus.
	_play_button.focus_mode = Control.FOCUS_NONE
	UITheme.style_button_subtle(_play_button, UITheme.TOXIC_GREEN, 12, 8, 12)
	_play_button.pressed.connect(_toggle_play)
	row.add_child(_play_button)

	var mute: CheckButton = CheckButton.new()
	mute.text = "MUTE"
	mute.tooltip_text = UITheme.wrap_tip("Silence the preview's audio cues and music.")
	mute.toggled.connect(_on_mute_toggled)
	row.add_child(mute)

	_time_label = Label.new()
	UITheme.style_label(_time_label, UITheme.DARK_TEXT, 12)
	row.add_child(_time_label)

	# Without this an author can only ever see whichever alternative happened to come up, which makes
	# the other versions they wrote unreviewable.
	_cycle_button = Button.new()
	_cycle_button.text = "⟳ CYCLE BRANCHES"
	_cycle_button.focus_mode = Control.FOCUS_NONE
	_cycle_button.tooltip_text = UITheme.wrap_tip(
		(
			"Step to the next branch, and to the next alternative line where a cue has them. Keep "
			+ "pressing to walk every combination and come back round. Only affects the preview."
		)
	)
	UITheme.style_button_subtle(_cycle_button, UITheme.CYAN, 10, 6, 11)
	_cycle_button.pressed.connect(
		func() -> void:
			_stage.cycle()
			# Read back AFTER the step, so the rows and the curves match what the stage just chose.
			_sync_branch_view()
	)
	row.add_child(_cycle_button)

	var gap: Control = Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)

	row.add_child(VSeparator.new())
	row.add_child(_build_kit_row())
	return row


# Loads the round's video into the stage and its funscript into the timeline's reference strip. Both
# are optional: an encounter can be authored against the clock alone, just with less to aim at.
func _load_preview_media() -> void:
	if _funscript_path != "":
		_reference_points = JourneyData.read_funscript_actions(_funscript_path)
		_timeline_view.set_reference(_reference_points)
	_stage.load_video(_video_path)
	# The stage explains on itself why it cannot play; the transport just has to stop offering to.
	_play_button.disabled = not _stage.has_media()


func _toggle_play() -> void:
	_play_button.text = "❚❚ PAUSE" if _stage.toggle_play() else "▶ PLAY"


func _on_mute_toggled(pressed: bool) -> void:
	_stage.set_muted(pressed)


# Jumps the preview to `ms`, keeping the modal's own clock in step with the stage's.
func _seek_preview(ms: int) -> void:
	_stage.seek(ms)
	_update_time_label(ms)


func _update_time_label(position_ms: int) -> void:
	_time_label.text = (
		"%s / %s" % [JourneyData.ms_to_mmss(position_ms), JourneyData.ms_to_mmss(_full_ms)]
	)


# ── Layout ───────────────────────────────────────────────────────────────────


# The Boss Kit: one button per track, plus the canned presets an author would otherwise rebuild by
# hand every time (BOSS_ROUND_DESIGN §6).
func _build_kit_row() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var label: Label = Label.new()
	label.text = "ADD"
	UITheme.style_label(label, UITheme.DARK_TEXT, 11, true)
	row.add_child(label)

	for track: String in BossTimeline.LANES:
		var button: Button = Button.new()
		button.text = track.to_upper()
		button.tooltip_text = UITheme.wrap_tip(
			"Click to add at the playhead, or drag onto the track."
		)
		UITheme.style_button_subtle(button, BossTimeline.track_color(track), 10, 6, 11)
		button.pressed.connect(func() -> void: _add_event(track))
		_make_kit_draggable(button, "track", track)
		row.add_child(button)

	var separator: VSeparator = VSeparator.new()
	row.add_child(separator)

	var encounter_button: Button = Button.new()
	encounter_button.text = "⚙ ENCOUNTER"
	encounter_button.tooltip_text = (
		UITheme
		. wrap_tip(
			"The encounter's own settings — boss name, health bar. Also reached by clicking empty track."
		)
	)
	UITheme.style_button_subtle(encounter_button, UITheme.DANGER, 10, 6, 11)
	encounter_button.pressed.connect(func() -> void: _select(""))
	row.add_child(encounter_button)

	var phase_button: Button = Button.new()
	phase_button.text = "＋ PHASE"
	UITheme.style_button_subtle(phase_button, UITheme.PURPLE_MID, 10, 6, 11)
	phase_button.tooltip_text = (
		UITheme
		. wrap_tip(
			"A new stage of the fight, placed on the HEALTH STRIP above the tracks. Drag it there to say how far down the bar she changes."
		)
	)
	phase_button.pressed.connect(func() -> void: _add_phase())
	row.add_child(phase_button)

	return row


# Makes a kit button draggable onto the track, so an author can place an event exactly where they want
# it instead of adding at the playhead and dragging the block afterwards. The payload is namespaced
# under one key so the timeline can tell a kit drag from any other drag it might receive.
func _make_kit_draggable(button: Button, kind: String, value: String) -> void:
	button.set_drag_forwarding(
		func(_at: Vector2) -> Variant:
			var preview: Label = Label.new()
			preview.text = button.text
			UITheme.style_label(preview, UITheme.WHITE_SOFT, 11, true)
			button.set_drag_preview(preview)
			return {"boss_kit": {"type": kind, "value": value}},
		Callable(),
		Callable()
	)


# A kit item was dropped on the track at `at_ms` — the same adds the buttons perform, but placed where
# the author let go rather than at the playhead.
func _on_kit_dropped(kind: String, value: String, at_ms: int) -> void:
	match kind:
		"track":
			_add_event(value, at_ms)


func _build_timeline_row(column: VBoxContainer) -> void:
	_timeline_view = BossTimeline.new()
	_timeline_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline_view.event_selected.connect(_on_event_selected)
	_timeline_view.event_moved.connect(_on_event_moved)
	_timeline_view.event_resized.connect(_on_event_resized)
	_timeline_view.event_head_dragged.connect(_on_event_head_dragged)
	_timeline_view.playhead_scrubbed.connect(_on_playhead_scrubbed)
	_timeline_view.view_changed.connect(_on_view_changed)
	_timeline_view.kit_dropped.connect(_on_kit_dropped)
	_timeline_view.phase_moved.connect(_on_phase_moved)
	_timeline_view.context_menu_requested.connect(_on_timeline_context_menu)
	# The wheel used to zoom, which authors found by accident. Scrolling took it over, so the gesture
	# that replaced it has to be stated — CTRL+wheel is not something anyone discovers.
	_timeline_view.tooltip_text = (UITheme.wrap_tip(
		(
			"CTRL+wheel zooms · wheel scrolls the lanes · middle-drag pans · right-click for the "
			+ "win-skip point. Drag a block to move it, or its right edge to resize."
		)
	))

	# Segments stack downwards without limit — a strip per branch, per segment — so the lanes cannot be
	# given whatever height they ask for. Inside a scroll they take the room the column can spare and
	# the rest is reachable, instead of the encounter squeezing everything above it off the top.
	#
	# Horizontal scrolling stays OFF: the lanes already own that axis, where CTRL+wheel zooms and the
	# scrollbar below pans. A second horizontal scroll would fight both. The plain wheel belongs to THIS
	# container — the lanes leave it unhandled so it arrives here.
	var lanes: ScrollContainer = ScrollContainer.new()
	lanes.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	lanes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lanes.size_flags_stretch_ratio = LANES_STRETCH
	lanes.custom_minimum_size.y = LANES_MIN_H
	lanes.add_child(_timeline_view)
	column.add_child(lanes)

	# A sibling scrollbar pans the zoomed view — the same pairing the override editor uses, so the
	# wheel is free for scrolling and CTRL+wheel for zoom, without either stealing panning.
	_scrollbar = HScrollBar.new()
	_scrollbar.value_changed.connect(
		func(value: float) -> void: _timeline_view.set_view_start(int(value))
	)
	column.add_child(_scrollbar)


func _build_inspector_row() -> Control:
	# Held by a plain Control, NOT a container. A container adopts its child's minimum width, so the
	# inspector used to be as wide as whatever happened to be selected — a long label or a row of spin
	# boxes widened it, and the stage jumped sideways to make room, which moved the picture the author
	# was framing against. A Control reports only the width it is handed, so the panel is fixed and the
	# stage never moves; anything genuinely too wide is clipped rather than allowed to push.
	var holder: Control = Control.new()
	holder.custom_minimum_size.x = INSPECTOR_WIDTH
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.clip_contents = true

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	holder.add_child(scroll)

	_inspector = VBoxContainer.new()
	_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector.add_theme_constant_override("separation", 6)
	scroll.add_child(_inspector)
	return holder


# PREVIEW AS IF: the player the rules are judged against. Without this an author can write a condition
# and have no way to watch it fire — they would have to play the round and physically produce the state,
# which for "they have stopped moving" means sitting still through it to check one line.
#
# It drives the SAME calls the round makes (matched_branch, evaluate_condition), so a branch winning here
# is the branch that will win there. It is a lens on the encounter, never part of it: nothing here is
# saved, and the round builds its own state from the real player.
func _build_sim_row() -> Control:
	_sim_row = HBoxContainer.new()
	_sim_row.add_theme_constant_override("separation", 10)
	_rebuild_sim_fields()
	return _sim_row


# The controls themselves, rebuilt rather than mutated so AT REST can put every field back at once. They
# live in the transport, NOT the inspector, so rebuilding the inspector would not have touched them.
func _rebuild_sim_fields() -> void:
	for child: Node in _sim_row.get_children():
		_sim_row.remove_child(child)
		child.queue_free()
	var row: HBoxContainer = _sim_row

	var title: Label = Label.new()
	title.text = "PREVIEW AS IF"
	UITheme.style_label(title, UITheme.TOXIC_GREEN, 10, true)
	row.add_child(title)

	for signal_name: String in RoundTimeline.SIGNALS:
		# Boss health is DERIVED — the score and the playhead read back out — so the preview computes it
		# and the bar above shows it. A dial here would let an author set a health the bar disagreed with,
		# and phases key off health, so the two would have shown different stages of the same fight.
		if signal_name == RoundTimeline.SIGNAL_BOSS_HP:
			continue
		row.add_child(
			_labeled(RoundTimeline.signal_label(signal_name), _make_sim_field(signal_name))
		)

	var reset: Button = Button.new()
	reset.text = "⟲ AT REST"
	reset.focus_mode = Control.FOCUS_NONE
	# Everything else in this row is a _labeled() pair — caption stacked over control — so a bare button
	# centres against the whole pair and sits above their baseline. Bottom-aligning lines it up.
	reset.size_flags_vertical = Control.SIZE_SHRINK_END
	reset.tooltip_text = UITheme.wrap_tip(
		"Back to a player who has done nothing yet — how every round actually starts."
	)
	UITheme.style_button_subtle(reset, UITheme.DARK_TEXT, 10, 6, 10)
	reset.pressed.connect(
		func() -> void:
			_sim_state = RoundTimeline.empty_state()
			_rebuild_sim_fields()  # the controls must show the values they were just reset to
			_push_sim_state()
	)
	row.add_child(reset)


# One control per signal, matching the kind of value it holds — the same split the clause editor makes,
# so a number is a number and an item is picked from a list rather than typed.
func _make_sim_field(signal_name: String) -> Control:
	if RoundTimeline.is_text_signal(signal_name):
		var by_id: bool = signal_name == RoundTimeline.SIGNAL_LAST_ITEM_ID
		var options: Array = [{"value": "", "label": "(nothing used)"}]
		options.append_array(_known_item_ids() if by_id else _known_item_kinds())
		var picker: OptionButton = OptionButton.new()
		picker.clip_text = true
		picker.custom_minimum_size = Vector2(130, 0)
		for option: Dictionary in options:
			picker.add_item(str(option["label"]))
		picker.selected = maxi(
			0, _option_values(options).find(str(_sim_state.get(signal_name, "")))
		)
		picker.item_selected.connect(
			func(i: int) -> void:
				_sim_state[signal_name] = str((options[i] as Dictionary)["value"])
				_push_sim_state()
		)
		return picker

	var number: SpinBox = SpinBox.new()
	number.min_value = 0
	number.max_value = 100000
	number.step = 1
	number.custom_minimum_size = Vector2(80, 0)
	number.value = float(_sim_state.get(signal_name, 0))
	UITheme.style_spin_box(number)
	number.value_changed.connect(
		func(value: float) -> void:
			_sim_state[signal_name] = value
			_push_sim_state()
	)
	return number


# Hands the pretend player to the stage and re-reads what it decided, so the lit branch row and the
# reference curves move the instant a value changes.
func _push_sim_state() -> void:
	_stage.set_sim_state(_sim_state)
	_sync_branch_view()


# The row is only meaningful once something in the encounter actually reads a player.
func _encounter_has_rules() -> bool:
	for segment: Dictionary in _segments():
		for branch: Dictionary in segment.get("branches", []) as Array:
			if not RoundTimeline.condition_clauses(branch.get("condition", {})).is_empty():
				return true
	for event: Dictionary in _timeline["events"] as Array:
		if not RoundTimeline.condition_clauses(event.get("condition", {})).is_empty():
			return true
	return false


func _build_footer() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	# Shortcuts are invisible unless they are written down somewhere.
	var hint: Label = Label.new()
	hint.text = "SPACE play · CTRL+Z/Y undo · CTRL+C/V copy · CTRL+D duplicate · DEL remove"
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(hint, UITheme.DARK_TEXT, 10, true)
	row.add_child(hint)

	var save: Button = Button.new()
	save.text = "SAVE ENCOUNTER"
	UITheme.style_button(save, UITheme.DANGER)
	save.pressed.connect(
		func() -> void:
			var normalized: Dictionary = RoundTimeline.normalize(_timeline)
			_opened_json = JSON.stringify(normalized)  # saved == clean
			saved.emit(normalized)
			_close()
	)
	row.add_child(save)

	var cancel: Button = Button.new()
	cancel.text = "CANCEL"
	UITheme.style_button(cancel, UITheme.PURPLE_MID)
	cancel.pressed.connect(_request_close)
	row.add_child(cancel)
	return row


## True when the encounter differs from how it was opened.
func _is_dirty() -> bool:
	return JSON.stringify(RoundTimeline.normalize(_timeline)) != _opened_json


# Cancel / Esc. Closing outright would throw away a whole authoring session in one click, and undo is
# no help once the modal is gone — so a changed encounter asks first.
func _request_close() -> void:
	if not _is_dirty():
		_close()
		return
	_confirming = true
	var parts: Dictionary = UITheme.build_centered_modal(
		"DISCARD ENCOUNTER CHANGES?", UITheme.DANGER, Vector2i(520, 240)
	)
	var confirm: Control = parts["modal"]
	var column: VBoxContainer = parts["vbox"]

	var message: Label = Label.new()
	message.text = "This encounter has unsaved changes. Discard them?"
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.size_flags_vertical = Control.SIZE_EXPAND_FILL
	UITheme.style_label(message, UITheme.WHITE_SOFT, 13)
	column.add_child(message)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)

	# Keep-editing leads, and is what Esc falls back to: the safe option should be the easy one.
	var keep: Button = Button.new()
	keep.text = "KEEP EDITING"
	UITheme.style_button(keep, UITheme.PURPLE_BRIGHT)
	keep.pressed.connect(
		func() -> void:
			_confirming = false
			confirm.queue_free()
	)
	buttons.add_child(keep)

	var discard: Button = Button.new()
	discard.text = "DISCARD"
	UITheme.style_button(discard, UITheme.DANGER)
	discard.pressed.connect(
		func() -> void:
			_confirming = false
			confirm.queue_free()
			_close()
	)
	buttons.add_child(discard)
	column.add_child(buttons)
	add_child(confirm)


func _close() -> void:
	# queue_free()ing this node takes the modal, the preview stage and the test player with it — and
	# their own _exit_tree handlers stop the video, the audio and the device.
	if is_instance_valid(_stage):
		_stage.shutdown()
	queue_free()


# ── Undo / redo / clipboard ──────────────────────────────────────────────────


## Records the timeline as it is NOW, before a change. `tag` names the kind of edit: two edits sharing a
## tag in quick succession collapse into one step, which is what makes a drag or a spin-box scrub undo
## as a single gesture instead of frame by frame.
func _snapshot(tag: String = "") -> void:
	var now: int = Time.get_ticks_msec()
	if tag != "" and tag == _last_snapshot_tag and now - _last_snapshot_ms < COALESCE_MS:
		_last_snapshot_ms = now
		return
	_last_snapshot_tag = tag
	_last_snapshot_ms = now
	_undo_stack.append(_timeline.duplicate(true))
	if _undo_stack.size() > UNDO_DEPTH:
		_undo_stack.remove_at(0)
	_redo_stack.clear()  # a fresh edit abandons the redo branch


func _undo() -> void:
	if _undo_stack.is_empty():
		return
	_redo_stack.append(_timeline.duplicate(true))
	_timeline = (_undo_stack.pop_back() as Dictionary)
	_after_history_move()


func _redo() -> void:
	if _redo_stack.is_empty():
		return
	_undo_stack.append(_timeline.duplicate(true))
	_timeline = (_redo_stack.pop_back() as Dictionary)
	_after_history_move()


# Shared tail of undo/redo: the restored timeline may no longer contain what was selected, and the next
# edit must not coalesce onto the step that was just undone.
func _after_history_move() -> void:
	_last_snapshot_tag = ""
	if _find(_selected_id).is_empty() and _find_phase(_selected_id).is_empty():
		_selected_id = ""
		_timeline_view.set_selected("")
	_refresh()


func _copy_selected() -> void:
	var event: Dictionary = _find(_selected_id)
	if not event.is_empty():
		_clipboard = event.duplicate(true)


# Pastes the clipboard at the playhead with a fresh id, so the copy is a new event rather than a second
# reference to the same one. END-anchored events keep their anchor but take the playhead's offset from
# whichever end they measure against.
func _paste(at_ms: int = -1) -> void:
	if _clipboard.is_empty():
		return
	_snapshot("paste")
	var event: Dictionary = _clipboard.duplicate(true)
	event["id"] = RoundTimeline.new_event_id()
	var start: int = at_ms if at_ms >= 0 else _playhead_ms
	if str(event.get("anchor", RoundTimeline.ANCHOR_START)) == RoundTimeline.ANCHOR_END:
		start = maxi(0, _full_ms - start)
	event["at_ms"] = start
	(_timeline["events"] as Array).append(event)
	_selected_id = str(event["id"])
	_timeline_view.set_selected(_selected_id)
	_refresh()


func _duplicate_selected() -> void:
	var event: Dictionary = _find(_selected_id)
	if event.is_empty():
		return
	var keep: Dictionary = _clipboard
	_clipboard = event.duplicate(true)
	# Offset slightly so the copy is visibly its own block rather than hidden under the original.
	_paste(RoundTimeline.resolve_at_ms(event, _full_ms) + 500)
	_clipboard = keep


# Editor shortcuts. _unhandled_key_input only sees keys no focused control consumed, so typing in a text
# field (including its own Ctrl+C/V) is never stolen by these.
func _unhandled_key_input(event: InputEvent) -> void:
	if _confirming or not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	var key: InputEventKey = event
	if key.ctrl_pressed:
		match key.keycode:
			KEY_Z:
				if key.shift_pressed:
					_redo()
				else:
					_undo()
			KEY_Y:
				_redo()
			KEY_C:
				_copy_selected()
			KEY_V:
				_paste()
			KEY_D:
				_duplicate_selected()
			_:
				return
		get_viewport().set_input_as_handled()
		return
	match key.keycode:
		KEY_DELETE:
			_delete_selected()
		KEY_SPACE:
			_toggle_play()
		KEY_ESCAPE:
			_request_close()
		_:
			return
	get_viewport().set_input_as_handled()


# ── Editing ──────────────────────────────────────────────────────────────────


# Everything funnels through here: mutate `_timeline`, re-normalize so the shape can never drift, then
# push the result to the view, the inspector and the validation line in one place.
func _refresh() -> void:
	_timeline = RoundTimeline.normalize(_timeline)
	if not _view_ready:
		# setup() resets zoom and pan, so it runs exactly once. Every later edit goes through
		# set_events(), which leaves the view the author arranged alone.
		_view_ready = true
		_timeline_view.setup(_timeline, _full_ms)
	_timeline_view.set_value_labels(_value_labels())
	_timeline_view.set_events(_timed_events(), _timeline["phases"], _segments())
	# The preview runs the REAL scheduler, so it has to be rebuilt whenever the timeline changes.
	_rebuild_preview()
	_refresh_scrollbar()
	_refresh_issues()
	_refresh_overlays()
	_rebuild_inspector()


# The curves drawn over the round's own stroke: every attack's script where it will play, and the
# TRANSFORMED stroke inside each effect window. Both answer the same authoring question — "what will the
# device actually be doing here?" — which the raw reference curve alone cannot.
func _refresh_overlays() -> void:
	var overlays: Array = []
	var dormant: Array = _stage.dormant_tags() if is_instance_valid(_stage) else []
	for event: Dictionary in _timeline["events"] as Array:
		var at: int = RoundTimeline.resolve_at_ms(event, _full_ms)
		if at == RoundTimeline.NO_TIME:
			continue
		# A branch that is not the live one contributes NO curve. Drawing every branch stacked the
		# alternatives on one graph, which reads as a single round doing all of them at once — the exact
		# confusion the strip rows were built to remove, reappearing on the reference strip.
		if dormant.has(str(event.get("variant_tag", ""))):
			continue
		match str(event.get("track", "")):
			RoundTimeline.TRACK_ATTACK:
				var points: Array = _attack_effect_points(event, at)
				if not points.is_empty():
					overlays.append({"points": points, "color": UITheme.DANGER})
			RoundTimeline.TRACK_EFFECT:
				var transformed: Array = _effect_window_points(event, at)
				if not transformed.is_empty():
					overlays.append({"points": transformed, "color": UITheme.PURPLE_BRIGHT})
	_timeline_view.set_overlays(overlays)


# An attack's own stroke, trimmed, rebased to 0 — offset to its place on the round's clock by the
# caller. This is the curve that gets CUT when the block is resized (see _on_event_resized).
func _attack_points(event: Dictionary) -> Array:
	var main: String = str((event.get("scripts", {}) as Dictionary).get("main", ""))
	if main == "":
		return []
	return JourneyData.apply_override_trim(
		JourneyData.read_funscript_actions(main), event.get("trim", {})
	)


# An attack's stroke as it will actually be FELT: its own curve, put through any effect window it
# overlaps — the same rule an override item follows, where active effects transform the takeover unless
# the item is marked immune ("play raw"). Already placed on the round's clock.
func _attack_effect_points(event: Dictionary, at_ms: int) -> Array:
	var points: Array = _shift(_attack_points(event), at_ms)
	if points.is_empty() or bool(event.get("immune_to_effects", false)):
		return points
	var effects: Array = _stroke_effects_over(at_ms, at_ms + int(event.get("duration_ms", 0)))
	if effects.is_empty():
		return points
	return _to_vectors(HandyPoints.apply_effects(HandyPoints.actions_to_points(points), effects))


# Every STROKE effect from windows overlapping [from_ms, to_ms) — what a takeover starting in that
# stretch would be transformed by.
func _stroke_effects_over(from_ms: int, to_ms: int) -> Array:
	var out: Array = []
	for other: Dictionary in _timeline["events"] as Array:
		if str(other.get("track", "")) != RoundTimeline.TRACK_EFFECT:
			continue
		var start: int = RoundTimeline.resolve_at_ms(other, _full_ms)
		if start == RoundTimeline.NO_TIME:
			continue
		var end: int = start + int(other.get("duration_ms", 0))
		if to_ms <= start or from_ms >= end:
			continue
		for raw: Variant in other.get("effects", []):
			if (
				raw is Dictionary
				and not JourneyData.is_sensory_kind(str((raw as Dictionary)["kind"]))
			):
				out.append(raw)
	return out


# The round's own stroke inside an effect window, put through that window's STROKE effects — the same
# transform the device applies, so the drawn curve is what will be felt.
func _effect_window_points(event: Dictionary, at_ms: int) -> Array:
	var duration: int = int(event.get("duration_ms", 0))
	if duration <= 0 or _reference_points.is_empty():
		return []
	var stroke_effects: Array = []
	for raw: Variant in event.get("effects", []):
		if raw is Dictionary and not JourneyData.is_sensory_kind(str((raw as Dictionary)["kind"])):
			stroke_effects.append(raw)
	if stroke_effects.is_empty():
		return []
	var window: Array = []
	for point: Vector2 in _reference_points:
		if point.x >= at_ms and point.x <= at_ms + duration:
			window.append(point)
	if window.size() < 2:
		return []
	# HandyPoints works in the device's own {t, x} form, so the window is converted across and back.
	# Reusing its transform rather than re-deriving one is the point: the drawn curve is then literally
	# what the device will be told to do.
	return _to_vectors(
		HandyPoints.apply_effects(HandyPoints.actions_to_points(window), stroke_effects)
	)


# Vector2 (t_ms, pos) is what the funscript layer and the timeline widget both speak; HandyPoints
# speaks {t, x}. These two convert between them at the boundary.
func _to_vectors(points: Array) -> Array:
	var out: Array = []
	for point: Dictionary in points:
		out.append(Vector2(float(point["t"]), float(point["x"])))
	return out


# Moves a curve along the round's clock, so an attack's stroke is drawn where it will actually play.
func _shift(points: Array, offset_ms: int) -> Array:
	var out: Array = []
	for point: Vector2 in points:
		out.append(Vector2(point.x + offset_ms, point.y))
	return out


# Everything that actually sits on the clock. DEFEAT events are excluded: they fire when the player
# gives in, not at a time, so drawing them at a position would state something untrue about them —
# they live in the encounter panel instead (BOSS_ROUND_DESIGN §3.3).
func _timed_events() -> Array:
	var out: Array = []
	for event: Dictionary in _timeline["events"] as Array:
		if not RoundTimeline.is_outcome_event(event):
			out.append(event)
	return out


func _outcome_events(on_mode: String) -> Array:
	var out: Array = []
	for event: Dictionary in _timeline["events"] as Array:
		if str(event.get("on", RoundTimeline.ON_ALWAYS)) == on_mode:
			out.append(event)
	return out


func _refresh_scrollbar() -> void:
	_scrollbar.min_value = 0
	_scrollbar.max_value = _full_ms
	_scrollbar.step = 1


# Validation is grouped BY EVENT: the block gets a ⚠ and the inspector spells the problem out when it
# is selected. The old footer label listed everything at once and grew the layout as it did, pushing the
# timeline around exactly while the author was trying to work on it.
func _refresh_issues() -> void:
	_issues = {}
	for issue: Dictionary in RoundTimeline.validate(_timeline, _full_ms):
		var id: String = str(issue["event_id"])
		if not _issues.has(id):
			_issues[id] = []
		(_issues[id] as Array).append(str(issue["message"]))
	_timeline_view.set_issues(_issues)


# Adds a bare event of `track` at the playhead. It starts empty on purpose — the inspector is where it
# gets its content, and validation names exactly what is still missing.
func _add_event(track: String, at_ms: int = -1) -> void:
	_snapshot("add")
	var event: Dictionary = {
		"id": RoundTimeline.new_event_id(),
		"track": track,
		"at_ms": at_ms if at_ms >= 0 else _playhead_ms,
		"anchor": RoundTimeline.ANCHOR_START,
	}
	# An effect and a stance are both meaningless as instants, so they arrive as windows; the rest
	# default to one-shots.
	if track == RoundTimeline.TRACK_EFFECT or track == RoundTimeline.TRACK_STANCE:
		event["duration_ms"] = NEW_WINDOW_MS
	# GUARDED rather than NORMAL: a stance window that changes nothing is a block an author placed for no
	# reason, and guarding is the commonest thing they came here to do.
	if track == RoundTimeline.TRACK_STANCE:
		event["stance"] = RoundTimeline.STANCE_GUARDED
	(_timeline["events"] as Array).append(event)
	_selected_id = str(event["id"])
	_timeline_view.set_selected(_selected_id)
	_refresh()


# A new stage of the fight, placed on the HEALTH BAR rather than the clock. Each one starts a third of a
# bar further down than the last, which is a reasonable opening guess for the usual two- or three-stage
# boss and saves the author from typing a number before they know what they want.
func _add_phase() -> void:
	_snapshot("add")
	var phases: Array = _timeline["phases"]
	var next_hp: float = clampf(1.0 - float(phases.size()) / 3.0, 0.0, 1.0)
	(
		phases
		. append(
			{
				"id": RoundTimeline.new_event_id("phs"),
				"name": "PHASE %d" % (phases.size() + 1),
				RoundTimeline.PHASE_HP_KEY: next_hp,
				"banner": true,
			}
		)
	)
	_refresh()


func _delete_selected() -> void:
	if _selected_id == "":
		return
	_snapshot("delete")
	var kept: Array = []
	for event: Dictionary in _timeline["events"] as Array:
		if str(event.get("id", "")) != _selected_id:
			kept.append(event)
	_timeline["events"] = kept
	var kept_phases: Array = []
	for phase: Dictionary in _timeline["phases"] as Array:
		if str(phase.get("id", "")) != _selected_id:
			kept_phases.append(phase)
	_timeline["phases"] = kept_phases
	_selected_id = ""
	_timeline_view.set_selected("")
	_refresh()


# ── Signals from the timeline view ───────────────────────────────────────────


func _on_event_selected(id: String) -> void:
	_selected_id = id
	_rebuild_inspector()


# Selects an event (or "" for the encounter itself) from the editor side, keeping the timeline's own
# highlight in step.
func _select(id: String) -> void:
	_selected_id = id
	_timeline_view.set_selected(id)
	_rebuild_inspector()


func _on_event_moved(id: String, at_ms: int) -> void:
	var event: Dictionary = _find(id)
	if event.is_empty():
		return
	# Tagged per event, so one drag gesture collapses into a single undo step.
	_snapshot("move:" + id)
	event["at_ms"] = maxi(0, at_ms)
	_refresh()


func _on_event_resized(id: String, duration_ms: int) -> void:
	var event: Dictionary = _find(id)
	if event.is_empty():
		return
	_snapshot("resize:" + id)
	var length: int = maxi(0, duration_ms)
	event["duration_ms"] = length
	# For a media event the block's length IS the slice: dragging its edge cuts the funscript or the clip
	# rather than just changing how wide the block looks, so what is drawn is what plays. The in-point is
	# kept — only the out-point follows the drag.
	var track: String = str(event.get("track", ""))
	if track == RoundTimeline.TRACK_ATTACK or track == RoundTimeline.TRACK_AUDIO:
		var trim: Dictionary = event.get("trim", {})
		var in_ms: int = int(trim.get("in_ms", 0))
		event["trim"] = {"in_ms": in_ms, "out_ms": in_ms + length}
	_refresh()


# The LEFT edge was dragged: the block starts later and ends where it did. For a media block that also
# cuts the same amount off the FRONT of the source, which is the whole point of the gesture — an attack
# could otherwise only ever begin at its funscript's first stroke, and an author wanting the middle of a
# script had no way to ask for it.
#
# The out-point is deliberately left alone. Both edges cut into the source, and each one should only
# move the end it is being dragged from.
func _on_event_head_dragged(id: String, at_ms: int) -> void:
	var event: Dictionary = _find(id)
	if event.is_empty():
		return
	_snapshot("resize:" + id)  # same tag as the other edge, so one gesture is one undo step
	var track: String = str(event.get("track", ""))
	var media: bool = track == RoundTimeline.TRACK_ATTACK or track == RoundTimeline.TRACK_AUDIO
	var trim: Dictionary = event.get("trim", {})
	var in_ms: int = int(trim.get("in_ms", 0))
	var was_at: int = RoundTimeline.resolve_at_ms(event, _full_ms)
	var was_long: int = maxi(0, int(event.get("duration_ms", 0)))

	# Worked out on the ROUND's clock and converted back once at the end, so an END-anchored block trims
	# the same way a START-anchored one does instead of backwards.
	var from_end: bool = (
		str(event.get("anchor", RoundTimeline.ANCHOR_START)) == RoundTimeline.ANCHOR_END
	)
	var wanted: int = _full_ms - at_ms if from_end else at_ms
	var moved: int = wanted - was_at
	# Dragging the head back can only give back what was already cut. Past that there is no more source
	# to reveal, and letting it keep going would make the block claim a length its media cannot fill.
	if media and moved < -in_ms:
		moved = -in_ms
	var new_at: int = maxi(0, was_at + moved)
	event["at_ms"] = maxi(0, _full_ms - new_at) if from_end else new_at
	event["duration_ms"] = maxi(0, was_long - moved)

	if not media:
		_refresh()  # nothing to cut into: a cast or effect window simply starts later
		return
	# No trim yet means the block plays the whole source, so the length it had IS that source's length —
	# which is what the out-point has to become, or the tail would be lost the moment the head moved.
	var out_ms: int = int(trim.get("out_ms", in_ms + was_long))
	event["trim"] = {"in_ms": maxi(0, in_ms + moved), "out_ms": out_ms}
	_refresh()


# The track was right-clicked. Built fresh each time rather than kept around: the entries depend on what
# is currently set, and a menu that has to be re-synced is a menu that will eventually be out of date.
func _on_timeline_context_menu(at_ms: int, at_global: Vector2) -> void:
	if is_instance_valid(_context_menu):
		_context_menu.queue_free()
	_context_menu = PopupMenu.new()
	_context_menu.add_item("⚑ Skip ahead to here on win", CONTEXT_SET_WIN_POINT)
	_context_menu.add_item("Clear the win skip", CONTEXT_CLEAR_WIN_POINT)
	# Nothing to clear yet, so the entry stays visible — saying what exists — but cannot be chosen.
	_context_menu.set_item_disabled(
		_context_menu.get_item_index(CONTEXT_CLEAR_WIN_POINT),
		int(_timeline.get("win_jump_ms", RoundTimeline.NO_TIME)) == RoundTimeline.NO_TIME
	)
	_context_menu.id_pressed.connect(func(id: int) -> void: _run_context_action(id, at_ms))
	add_child(_context_menu)
	_context_menu.popup(Rect2i(Vector2i(at_global), Vector2i.ZERO))


# Setting where a win skips to by pointing at it. The number alone was unusable — an author had no way
# to see what "10000ms from the end" actually landed on.
#
# Placing the flag turns the skip ON, because placing it IS asking for it. Stored against whichever
# anchor the encounter already uses, so the flag stays on the frame that was pointed at either way.
func _run_context_action(id: int, at_ms: int) -> void:
	match id:
		CONTEXT_SET_WIN_POINT:
			_snapshot("field:win_jump_ms")
			var from_end: bool = (
				str(_timeline.get("win_jump_anchor", RoundTimeline.ANCHOR_END))
				== RoundTimeline.ANCHOR_END
			)
			_timeline["win_jump_ms"] = maxi(0, _full_ms - at_ms) if from_end else maxi(0, at_ms)
			_refresh()
		CONTEXT_CLEAR_WIN_POINT:
			_snapshot("field:win_jump_ms")
			_timeline["win_jump_ms"] = RoundTimeline.NO_TIME
			_refresh()


# A phase marker was dragged along the health strip, setting the health it takes over at.
func _on_phase_moved(id: String, hp_at: float) -> void:
	_snapshot("move:" + id)
	for phase: Dictionary in _timeline["phases"] as Array:
		if str(phase.get("id", "")) == id:
			phase[RoundTimeline.PHASE_HP_KEY] = clampf(hp_at, 0.0, 1.0)
			_refresh()
			return


func _on_playhead_scrubbed(ms: int) -> void:
	_playhead_ms = ms
	_seek_preview(ms)


func _on_view_changed(start_ms: int, span_ms: int) -> void:
	# page mirrors the visible span so the scrollbar's thumb reads as the portion of the round on screen.
	_scrollbar.page = span_ms
	_scrollbar.set_value_no_signal(start_ms)


func _find(id: String) -> Dictionary:
	for event: Dictionary in _timeline["events"] as Array:
		if str(event.get("id", "")) == id:
			return event
	return {}


# ── Inspector ────────────────────────────────────────────────────────────────


# Rebuilt wholesale on every selection or edit. The event set is small and the fields differ per track,
# so rebuilding is simpler — and less bug-prone — than diffing a live form.
func _rebuild_inspector() -> void:
	for child: Node in _inspector.get_children():
		child.queue_free()
	var event: Dictionary = _find(_selected_id)
	if event.is_empty():
		# A phase marker is selectable too, and edits the same way — name, time, banner, delete.
		var phase: Dictionary = _find_phase(_selected_id)
		if not phase.is_empty():
			_build_phase_inspector(phase)
			return
		# Nothing selected → the ENCOUNTER'S own settings. They belong somewhere, and this is the panel
		# that is otherwise empty exactly when the author is thinking about the encounter as a whole.
		_build_encounter_inspector()
		return
	_add_issue_panel(_selected_id)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	var title: Label = Label.new()
	title.text = str(event.get("track", "")).to_upper()
	if RoundTimeline.is_outcome_event(event):
		title.text += "  ·  %s" % RoundTimeline.outcome_label(str(event["on"]))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(title, BossTimeline.track_color(str(event.get("track", ""))), 14, true)
	header.add_child(title)
	var delete: Button = Button.new()
	delete.text = "✕ DELETE"
	UITheme.style_button_subtle(delete, UITheme.DANGER, 10, 6, 11)
	delete.pressed.connect(_delete_selected)
	header.add_child(delete)
	_inspector.add_child(header)

	if RoundTimeline.is_outcome_event(event):
		var note: Label = Label.new()
		note.text = "Plays on the way out of the round — not at a time on the timeline."
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(note, UITheme.AMBER, 10)
		_inspector.add_child(note)
	else:
		_add_time_fields(event)
		_add_branch_field(event)
		_add_condition_rows(_inspector, event, "Only if…")
	match str(event.get("track", "")):
		RoundTimeline.TRACK_ATTACK:
			_add_line_edit(event, "name", "Attack name (shown on the HUD chip)")
			_add_override_reuse(event)
			_add_script_field(event)
			_add_immunity_toggle(event)
		RoundTimeline.TRACK_CAST:
			_add_character_fields(event)
			_add_line_edit(event, "text", "Subtitle (optional)")
			_add_subtitle_fields(event)
			_add_file_field(event, "image", "Image / animation", JourneyData.IMAGE_EXTENSIONS)
			_add_placement_fields(event)
			_add_transition_field(event)
			_add_fade_fields(event, "in_ms", "out_ms", "Cue fade in / out (ms)")
			_add_alts_list(event)
		RoundTimeline.TRACK_AUDIO:
			_add_file_field(
				event,
				"clip",
				"Audio clip",
				JourneyAudio.AUDIO_EXTENSIONS,
				func(path: String) -> void: _adopt_media_length(event, _audio_length_ms(path))
			)
			_add_fade_fields(event, "fade_in_ms", "fade_out_ms", "Audio ease in / out (ms)")
			_add_alts_list(event)
		RoundTimeline.TRACK_STANCE:
			_add_stance_field(event)
		RoundTimeline.TRACK_EFFECT:
			_add_effects_picker(event)
			_add_fade_fields(event, "fade_in_ms", "fade_out_ms", "Effect ease in / out (ms)")


# Start time + duration + which end the start is measured from. Editing any of them re-normalizes, so
# the numbers here and the block on the timeline can never disagree.
# Encounter-level settings: what the health bar is called and whether it shows at all.
func _build_encounter_inspector() -> void:
	var title: Label = Label.new()
	title.text = "ENCOUNTER"
	UITheme.style_label(title, UITheme.DANGER, 14, true)
	_inspector.add_child(title)

	var name_field: LineEdit = LineEdit.new()
	name_field.text = str(_timeline.get("boss_name", ""))
	name_field.placeholder_text = "Falls back to the round's name"
	UITheme.style_line_edit(name_field)
	name_field.text_changed.connect(
		func(value: String) -> void:
			_snapshot("field:boss_name")
			_timeline["boss_name"] = value
			_rebuild_preview()
	)
	_inspector.add_child(_labeled("Boss name (shown on the health bar)", name_field))

	# The ITEMS toggle stays out here rather than in a fold of its own: it is one switch, and a header
	# that hides a single checkbox costs more than it saves.
	var items: CheckButton = CheckButton.new()
	items.text = "PLAYER MAY USE ITEMS"
	items.tooltip_text = (
		UITheme
		. wrap_tip(
			"Lets the player open their inventory during this encounter. Turn it off for a sealed-room fight. An authored ATTACK always outranks an override item — one used mid-attack is refused rather than consumed."
		)
	)
	items.button_pressed = bool(_timeline.get("items_allowed", true))
	items.toggled.connect(
		func(pressed: bool) -> void:
			_snapshot("field:items_allowed")
			_timeline["items_allowed"] = pressed
	)
	_inspector.add_child(items)

	_add_section("health", "HEALTH BAR", UITheme.DANGER, _build_health_section)
	_add_section("segments", "SEGMENTS", UITheme.CYAN, _build_segments_section)
	_add_section("outcomes", "HOW THE ROUND CAN END", UITheme.AMBER, _build_outcomes_section)

	var hint: Label = Label.new()
	hint.text = "Select a block to edit it, or add one from the row above."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(hint, UITheme.DARK_TEXT, 11)
	_inspector.add_child(hint)


# The health bar and everything that decides what drains it: whether it shows at all, where it sits,
# whether phases cut it into stages, what fills it, and how she recovers.
#
# Split out of _build_encounter_inspector, which had grown past 190 lines. That mattered more than
# tidiness: an early return added midway through it once silently removed the items toggle, the
# segments list and every outcome block, because nothing about a single long function says which
# sections come after the line you are editing.
func _build_health_section() -> void:
	var hp: CheckButton = CheckButton.new()
	hp.text = "SHOW HEALTH BAR"
	hp.tooltip_text = (
		UITheme
		. wrap_tip(
			"A draining bar under the HUD, with the phase line beneath it. It shows the round's own progress read backwards — no separate tracking."
		)
	)
	hp.button_pressed = bool(_timeline.get("hp_bar", true))
	hp.toggled.connect(
		func(pressed: bool) -> void:
			_snapshot("field:hp_bar")
			_timeline["hp_bar"] = pressed
			_rebuild_preview()
	)
	_inspector.add_child(hp)

	# Only worth showing while there is a bar to move.
	if bool(_timeline.get("hp_bar", true)):
		# Percent, like the phase thresholds beside it. A raw 0.02 is the only placement in the editor
		# expressed as a fraction, and it reads as a tuning constant rather than a position.
		var bar_y: SpinBox = SpinBox.new()
		bar_y.min_value = 0
		bar_y.max_value = 100
		bar_y.step = 1
		bar_y.suffix = "%"
		bar_y.value = 100.0 * float(_timeline.get("hp_bar_y", RoundTimeline.DEFAULT_HP_BAR_Y))
		bar_y.tooltip_text = (
			UITheme
			. wrap_tip(
				(
					"Where the name and bar sit down the screen: 0 is the top edge, 1 the bottom. The whole "
					+ "block moves together, and it never runs off either end — so cast art can have the "
					+ "top of the frame if that is where it wants to be."
				)
			)
		)
		UITheme.style_spin_box(bar_y)
		bar_y.value_changed.connect(
			func(value: float) -> void:
				_snapshot("field:hp_bar_y")
				_timeline["hp_bar_y"] = value / 100.0
				_rebuild_preview()
		)
		_inspector.add_child(_labeled("Health bar Y (down the screen)", bar_y))

	var ticks: CheckButton = CheckButton.new()
	ticks.text = "SPLIT THE BAR BY PHASE"
	ticks.tooltip_text = (
		UITheme
		. wrap_tip(
			"Cuts the health bar into one stage per phase, so the player can see there is more of this fight coming without being told. The divisions follow the phases you placed, so they cannot disagree with the banners."
		)
	)
	ticks.button_pressed = bool(_timeline.get("phase_ticks", true))
	ticks.toggled.connect(
		func(pressed: bool) -> void:
			_snapshot("field:phase_ticks")
			_timeline["phase_ticks"] = pressed
			_rebuild_preview()
	)
	_inspector.add_child(ticks)

	var hp_row: HBoxContainer = HBoxContainer.new()
	hp_row.add_theme_constant_override("separation", 8)

	var source: OptionButton = OptionButton.new()
	source.add_item("TIME — round progress")
	source.add_item("SCORE — what they earn")
	source.selected = (1 if _health_follows_score() else 0)
	source.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"What drains the bar. TIME is the clock read backwards — the same number the ordinary "
				+ "progress bar shows. SCORE points it at the player, so it empties as they earn. Emptying "
				+ "it does nothing by itself: hang a rule on Score to decide what happens."
			)
		)
	)
	source.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:hp_source")
			_timeline["hp_source"] = (
				RoundTimeline.HP_SCORE if index == 1 else RoundTimeline.HP_TIME
			)
			_refresh()
	)
	hp_row.add_child(_labeled("Health bar follows", source))

	if _health_follows_score():
		var target: SpinBox = SpinBox.new()
		# Zero, not one: a SpinBox snaps to min + n*step, so a minimum of 1 with a step of 50 could only
		# land on 1, 51, 101 … and a typed 1000 became 1001. The model floors it at 1 regardless.
		target.min_value = 0
		target.max_value = 1000000
		target.step = 50
		target.value = float(_timeline.get("damage_target", RoundTimeline.DEFAULT_DAMAGE_TARGET))
		target.tooltip_text = (
			UITheme
			. wrap_tip(
				(
					"Score that empties the bar. What is achievable depends entirely on the round, so tune "
					+ "it against what you actually see yourself score playing this one."
				)
			)
		)
		UITheme.style_spin_box(target)
		target.value_changed.connect(
			func(value: float) -> void:
				_snapshot("field:damage_target")
				_timeline["damage_target"] = int(value)
				_refresh_derived()
		)
		hp_row.add_child(_labeled("Score to defeat", target))

		var attempts: SpinBox = SpinBox.new()
		attempts.min_value = 1
		attempts.max_value = 20
		attempts.step = 1
		attempts.value = float(_timeline.get("max_attempts", RoundTimeline.DEFAULT_MAX_ATTEMPTS))
		attempts.tooltip_text = (
			UITheme
			. wrap_tip(
				(
					"How many passes the player gets. ONE plays the round once and moves on, whatever the "
					+ "bar reached. More turns it into a fight: a pass that ends with the boss still "
					+ "standing replays this round, carrying the damage already done."
				)
			)
		)
		UITheme.style_spin_box(attempts)
		attempts.value_changed.connect(
			func(value: float) -> void:
				_snapshot("field:max_attempts")
				_timeline["max_attempts"] = int(value)
				_refresh()
		)
		hp_row.add_child(_labeled("Attempts", attempts))
	_inspector.add_child(hp_row)
	# Sits under the row it explains, and only when the bar actually reads a score.
	if _health_follows_score():
		_add_target_recommendation()
		_add_regen_fields()


# The DEFEAT events. They live here rather than on a lane because they have no place on the clock: they
# play when the player gives in (the FINISH button), whenever that happens — so a position would be a lie.
# Everything else about it is an ordinary cast or audio event.
# The three ways out of the round, each with its own list. Separate sections rather than one list with a
# mode dropdown: an author needs to see at a glance which endings they have NOT written, and a single
# list hides that behind reading every row.
func _build_outcomes_section() -> void:
	var hold: SpinBox = _make_ms_spin(
		int(_timeline.get("outcome_hold_ms", RoundTimeline.DEFAULT_OUTCOME_HOLD_MS))
	)
	hold.tooltip_text = UITheme.wrap_tip(
		"How long any of these endings is held before the round tears down. Shared by all three."
	)
	hold.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:outcome_hold_ms")
			_timeline["outcome_hold_ms"] = int(value)
	)
	_inspector.add_child(_labeled("Hold before the round ends (ms)", hold))

	_build_outcome_block(
		RoundTimeline.ON_WON,
		"IF THEY WIN",
		(
			"Played the moment the health bar empties. The round then plays out as aftermath — it does "
			+ "not cut short."
		),
		"won_flag"
	)
	_build_outcome_block(
		RoundTimeline.ON_GAVE_IN,
		"IF SHE WINS",
		(
			"Played when the player presses FINISH mid-round, and when the last attempt ends with the "
			+ "boss still standing. Both are the same defeat as far as this ending is concerned."
		),
		"lost_flag"
	)


# A folding section of the inspector: a header that opens and closes a body of controls.
#
# The encounter settings run to about forty controls, and an author works one of these at a time — as one
# scroll they read as a wall, with a segment list and three endings all carrying the same visual weight
# as a checkbox. `builder` fills the body.
#
# The swap around `builder.call()` is what keeps this cheap: every section builder already writes to
# `_inspector`, so pointing that at the body for the duration puts their output inside the fold without
# any of them needing to know a fold exists.
func _add_section(key: String, title: String, accent: Color, builder: Callable) -> void:
	var open: bool = bool(_open_sections.get(key, false))

	var header: Button = Button.new()
	header.text = ("▾  " if open else "▸  ") + title
	header.toggle_mode = true
	header.button_pressed = open
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.focus_mode = Control.FOCUS_NONE
	UITheme.style_button_subtle(header, accent, 11, 6, 12)
	header.pressed.connect(
		func() -> void:
			_open_sections[key] = not bool(_open_sections.get(key, false))
			_refresh()
	)
	_inspector.add_child(header)

	if not open:
		return
	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	_inspector.add_child(body)
	var outer: VBoxContainer = _inspector
	_inspector = body
	builder.call()
	_inspector = outer


# Segment problems are keyed to the SEGMENT rather than to an event, so the per-event issue panel never
# shows them — without this they would be the one class of warning an author could not see anywhere.
func _segment_issues_for(segment_id: String) -> Array:
	if segment_id == "":
		return []
	var out: Array = []
	for issue: Dictionary in RoundTimeline.validate(_timeline, _full_ms):
		if str(issue.get("event_id", "")) != segment_id:
			continue
		if (
			str(issue["code"])
			in [
				RoundTimeline.ISSUE_SEGMENT_THIN,
				RoundTimeline.ISSUE_SEGMENT_DEAD_TAG,
				RoundTimeline.ISSUE_SEGMENT_TAG_CLASH,
			]
		):
			out.append(issue)
	return out


# Whether the bar is counting the player down rather than the clock. Winning, replays, damage windows and
# phase thresholds all only mean anything in that mode.
func _health_follows_score() -> bool:
	return str(_timeline.get("hp_source", RoundTimeline.HP_TIME)) == RoundTimeline.HP_SCORE


# One ending: what it is, the beats it plays, an optional flag it raises, and the buttons to add to it.
func _build_outcome_block(
	on_mode: String, heading: String, blurb_text: String, flag_key: String
) -> void:
	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var title: Label = Label.new()
	title.text = heading
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(title, UITheme.CYAN, 10, true)
	header.add_child(title)

	# An ending fires on the way OUT of a round, so the preview's timed pass never reaches one. Without
	# this an author could write a whole defeat sequence and only find out what it looked like by
	# losing a fight for real.
	if not _outcome_events(on_mode).is_empty():
		var play: Button = Button.new()
		play.text = "▶ PLAY"
		play.tooltip_text = UITheme.wrap_tip(
			"Plays this ending over the preview, held for the same time the round holds it."
		)
		UITheme.style_button_subtle(play, UITheme.TOXIC_GREEN, 9, 4, 10)
		play.pressed.connect(func() -> void: _stage.play_outcome(on_mode))
		header.add_child(play)
	_inspector.add_child(header)

	var blurb: Label = Label.new()
	blurb.text = blurb_text
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(blurb, UITheme.DARK_TEXT, 9)
	_inspector.add_child(blurb)

	# Only a win can skip the clip — the other two endings are already at the end of the round.
	if on_mode == RoundTimeline.ON_WON:
		_add_win_jump_fields()

	# The FINISH warning belongs only to the ending FINISH triggers — and only once there are cues for it
	# to strand. On an empty section there is nothing dead yet, so it is a note about a setting rather
	# than a fault, and firing amber before an author has written anything is how amber stops meaning
	# something.
	if on_mode == RoundTimeline.ON_GAVE_IN and not _allow_finish:
		if _outcome_events(on_mode).is_empty():
			(
				_inspector
				. add_child(
					_make_quiet_note(
						(
							"This journey's FINISH button is off, so a player can never give in. Turn on "
							+ "ALLOW FINISH BUTTON in the journey settings before writing this ending."
						),
						9
					)
				)
			)
		else:
			_inspector.add_child(_make_finish_warning())

	# There is nothing to win against a bar that is only counting the clock down.
	if on_mode == RoundTimeline.ON_WON and not _health_follows_score():
		(
			_inspector
			. add_child(
				_make_quiet_note(
					(
						"Reachable only when the health bar follows SCORE — against the clock the round "
						+ "simply plays through and this never fires."
					),
					9
				)
			)
		)

	for event: Dictionary in _outcome_events(on_mode):
		_inspector.add_child(_make_outcome_row(event))

	if flag_key != "":
		var flag: LineEdit = LineEdit.new()
		flag.text = str(_timeline.get(flag_key, ""))
		flag.placeholder_text = "Flag to raise (optional)"
		flag.tooltip_text = (
			UITheme
			. wrap_tip(
				(
					"Raises this run flag when the round ends this way, so a later fork or round can ask "
					+ "how the fight went. Advancing past the boss no longer means they beat it."
				)
			)
		)
		UITheme.style_line_edit(flag)
		flag.text_changed.connect(
			func(value: String) -> void:
				_snapshot("field:" + flag_key)
				_timeline[flag_key] = value
		)
		_inspector.add_child(flag)

	var add_row: HBoxContainer = HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 8)
	for track: String in [RoundTimeline.TRACK_CAST, RoundTimeline.TRACK_AUDIO]:
		var button: Button = Button.new()
		button.text = "＋ %s" % track.to_upper()
		UITheme.style_button_subtle(button, BossTimeline.track_color(track), 10, 6, 11)
		button.pressed.connect(func() -> void: _add_outcome_event(on_mode, track))
		add_row.add_child(button)
	_inspector.add_child(add_row)


# SEGMENTS. A segment names a set of branches and plays exactly one of them, so a whole move — its
# telegraph, its attack, its impact sound — varies together instead of each part rolling on its own and
# producing combinations nobody wrote.
func _build_segments_section() -> void:
	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	var add: Button = Button.new()
	add.text = "＋ SEGMENT"
	UITheme.style_button_subtle(add, UITheme.CYAN, 10, 6, 11)
	add.pressed.connect(
		func() -> void:
			_snapshot("add-segment")
			(
				(_segments() as Array)
				. append(
					{
						"id": RoundTimeline.new_event_id("seg"),
						"name": "Move %d" % ((_segments() as Array).size() + 1),
						"branches": _fresh_branches(2),
					}
				)
			)
			_refresh()
	)
	header.add_child(add)
	_inspector.add_child(header)

	var blurb: Label = Label.new()
	blurb.text = (
		"One branch of each segment plays per round. Tag an event with a branch below to put it on that "
		+ "branch; untagged events always play."
	)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(blurb, UITheme.DARK_TEXT, 10)
	_inspector.add_child(blurb)

	for i: int in (_segments() as Array).size():
		_inspector.add_child(_make_segment_row(i))


# One segment: its name, then a row per branch. Branches are listed individually rather than typed as a
# comma-separated string, because each one now carries the RULE that selects it — and a rule needs
# somewhere to live that a text field cannot give it.
func _make_segment_row(index: int) -> Control:
	var segments: Array = _segments()
	var segment: Dictionary = segments[index]
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	# The segment's own problems, on the segment. They used to be listed together under the section
	# heading, which put "Branch D has no events" several rows above the segment that owns D — the
	# author had to work out which one it meant.
	for issue: Dictionary in _segment_issues_for(str(segment.get("id", ""))):
		box.add_child(_make_amber_callout("⚠  " + str(issue["message"]), 10))

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var name_field: LineEdit = LineEdit.new()
	name_field.text = str(segment.get("name", ""))
	name_field.placeholder_text = "Move name — e.g. Opener, Punish"
	name_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(name_field)
	name_field.text_changed.connect(
		func(value: String) -> void:
			_snapshot("field:segment_name")
			segment["name"] = value
			_refresh_derived()
	)
	row.add_child(name_field)

	var remove: Button = Button.new()
	remove.text = "✕"
	UITheme.style_button_subtle(remove, UITheme.DANGER, 8, 4, 11)
	remove.pressed.connect(
		func() -> void:
			_snapshot("delete-segment")
			segments.remove_at(index)
			_refresh()
	)
	row.add_child(remove)
	box.add_child(row)

	var branches: Array = segment.get("branches", [])
	if not (segment.get("branches", null) is Array):
		branches = []
		segment["branches"] = branches
	for i: int in branches.size():
		box.add_child(_make_branch_row(branches, i))

	var add: Button = Button.new()
	add.text = "＋ BRANCH"
	UITheme.style_button_subtle(add, UITheme.CYAN, 10, 6, 10)
	add.pressed.connect(
		func() -> void:
			_snapshot("add-branch")
			branches.append({"tag": _next_free_tag(_all_tags()), "condition": {}})
			_refresh()
	)
	box.add_child(add)
	return box


# One branch: its name, the rule that picks it, and a remove button. The rule reads as a sentence in the
# same words the timeline gutter uses, so an author meets the identical phrasing in both places.
func _make_branch_row(branches: Array, index: int) -> Control:
	var branch: Dictionary = branches[index]
	var box: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(UITheme.CYAN.r, UITheme.CYAN.g, UITheme.CYAN.b, 0.06)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(6)
	# Indented, with a rail down the left edge. A branch and the segment that owns it were drawn as
	# identical full-width fields, so a list of two segments read as four peers and nothing said which
	# ones belonged together.
	style.content_margin_left = BRANCH_INDENT
	style.border_width_left = 2
	style.border_color = Color(UITheme.CYAN, 0.55)
	box.add_theme_stylebox_override("panel", style)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)

	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var tag: LineEdit = LineEdit.new()
	tag.text = str(branch.get("tag", ""))
	tag.placeholder_text = "Branch"
	# Sized for a tag rather than a sentence — these are "A", "B", "GENTLE". At full width it read as a
	# second name field competing with the segment's own.
	tag.custom_minimum_size.x = BRANCH_TAG_WIDTH
	tag.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tag.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"Renaming a branch does NOT retag the events already on it — they fall off and start always "
				+ "playing, so retag them from each event's Branch field."
			)
		)
	)
	UITheme.style_line_edit(tag)
	tag.text_changed.connect(
		func(value: String) -> void:
			_snapshot("field:branch_tag")
			branch["tag"] = value
			_refresh_derived()
	)
	head.add_child(tag)

	var drop: Button = Button.new()
	drop.text = "✕"
	UITheme.style_button_subtle(drop, UITheme.DANGER, 8, 4, 10)
	drop.pressed.connect(
		func() -> void:
			_snapshot("delete-branch")
			branches.remove_at(index)
			_refresh()
	)
	head.add_child(drop)
	column.add_child(head)

	_add_condition_rows(column, branch, "Plays when…")
	box.add_child(column)
	return box


# The clause editor, shared by a segment's branches and by an event's own gate. `owner` is whatever dict
# holds the `condition` key, so both callers get identical behaviour from one implementation.
func _add_condition_rows(parent: Control, owner: Dictionary, label: String) -> void:
	var condition: Dictionary = owner.get("condition", {})
	if not (owner.get("condition", null) is Dictionary):
		condition = {"match": RoundTimeline.MATCH_ALL, "clauses": []}
		owner["condition"] = condition
	var clauses: Array = condition.get("clauses", [])
	if not (condition.get("clauses", null) is Array):
		clauses = []
		condition["clauses"] = clauses

	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var caption: Label = Label.new()
	# An empty rule reads as the dice roll it actually is, rather than as a blank the author has to
	# interpret — the same word the timeline gutter prints.
	caption.text = "%s  %s" % [label, RoundTimeline.condition_text(condition, _value_labels())]
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(caption, UITheme.DARK_TEXT, 9)
	head.add_child(caption)

	var add: Button = Button.new()
	add.text = "＋ RULE"
	UITheme.style_button_subtle(add, UITheme.TOXIC_GREEN, 8, 4, 9)
	add.pressed.connect(
		func() -> void:
			_snapshot("add-rule")
			clauses.append(
				{"signal": RoundTimeline.SIGNAL_SCORE, "op": RoundTimeline.OP_LT, "value": 100}
			)
			_refresh()
	)
	head.add_child(add)
	parent.add_child(head)

	# The joiner only appears once there are two clauses to join — offered earlier it is a control with
	# nothing to do, and a decision an author has no reason to have made yet.
	if clauses.size() > 1:
		var mode: OptionButton = OptionButton.new()
		mode.add_item("ALL must hold")
		mode.add_item("ANY may hold")
		mode.selected = (
			1 if RoundTimeline.condition_match(condition) == RoundTimeline.MATCH_ANY else 0
		)
		mode.item_selected.connect(
			func(i: int) -> void:
				_snapshot("field:condition_match")
				condition["match"] = RoundTimeline.MATCHES[i]
				_refresh()
		)
		parent.add_child(mode)

	for i: int in clauses.size():
		parent.add_child(_make_clause_row(clauses, i))


# One clause: signal, comparison, value. Every clause must hold for the rule to pass (or any one of them
# under ANY), which is why they stack rather than nesting — an author who needs alternatives writes
# another branch.
func _make_clause_row(clauses: Array, index: int) -> Control:
	var clause: Dictionary = clauses[index]
	# Two lines rather than one: the signal on its own, then the comparison. Once signals read as words
	# — "Medium Strokes (21-70)" — a single row could not hold one beside an operator, a value and a
	# remove button, and the panel simply clipped whatever fell off the end.
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var signal_pick: OptionButton = OptionButton.new()
	for name: String in RoundTimeline.SIGNALS:
		signal_pick.add_item(RoundTimeline.signal_label(name))
	signal_pick.selected = maxi(0, RoundTimeline.SIGNALS.find(str(clause.get("signal", ""))))
	signal_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	signal_pick.item_selected.connect(
		func(i: int) -> void:
			_snapshot("field:clause_signal")
			var chosen: String = RoundTimeline.SIGNALS[i]
			var previous: String = str(clause.get("signal", ""))
			var was_text: bool = RoundTimeline.is_text_signal(previous)
			var now_text: bool = RoundTimeline.is_text_signal(chosen)
			clause["signal"] = chosen
			# The value is reset whenever it stops meaning anything: crossing between a number and a
			# name, or swapping one name signal for the other, since an item KIND is not a valid item
			# ID. Two numeric signals keep the value, which is usually what an author wants.
			if previous != chosen and (was_text or now_text):
				clause["value"] = "" if now_text else 0
			# ...and an operator the new signal has no use for. Left alone, switching to an item signal
			# kept "<", which _clause_holds silently reads as equality — so the rule would have worked
			# while reading as something else entirely.
			if not RoundTimeline.ops_for(chosen).has(str(clause.get("op", ""))):
				clause["op"] = RoundTimeline.OP_EQ
			# The value editor differs for a name signal, so the row is rebuilt rather than left showing
			# a spin box for something that is not a number.
			_refresh()
	)
	# Clipped rather than allowed to grow: an OptionButton sizes itself to its longest entry, so one
	# long custom item name would otherwise widen the row past the panel however wide the panel is.
	signal_pick.clip_text = true
	box.add_child(signal_pick)

	# Only the comparisons that mean something for this signal — an item name has no ordering, so
	# offering "<" would let an author write a rule that cannot say what it appears to say.
	var signal_name: String = str(clause.get("signal", ""))
	var ops: Array = RoundTimeline.ops_for(signal_name)
	var op_pick: OptionButton = OptionButton.new()
	for op: String in ops:
		op_pick.add_item(RoundTimeline.op_label(op, signal_name))
	op_pick.selected = maxi(0, ops.find(str(clause.get("op", ""))))
	op_pick.item_selected.connect(
		func(i: int) -> void:
			_snapshot("field:clause_op")
			clause["op"] = str(ops[i])
			_refresh_derived()
	)
	row.add_child(op_pick)

	if RoundTimeline.is_text_signal(str(clause.get("signal", ""))):
		row.add_child(_make_name_value_picker(clause))
	else:
		var number: SpinBox = SpinBox.new()
		number.min_value = 0
		number.max_value = 100000
		number.step = 1
		number.value = float(clause.get("value", 0))
		number.custom_minimum_size = Vector2(90, 0)
		UITheme.style_spin_box(number)
		number.value_changed.connect(
			func(value: float) -> void:
				_snapshot("field:clause_value")
				clause["value"] = value
				_refresh_derived()
		)
		row.add_child(number)

	var drop: Button = Button.new()
	drop.text = "✕"
	UITheme.style_button_subtle(drop, UITheme.DANGER, 6, 4, 9)
	drop.pressed.connect(
		func() -> void:
			_snapshot("delete-rule")
			clauses.remove_at(index)
			_refresh()
	)
	row.add_child(drop)
	box.add_child(row)
	return box


# A picker for the clause's value when the signal names something rather than counting it. A DROPDOWN
# rather than a text field for the same reason branch tags are: a name that matches nothing simply never
# fires, so a typo would read as "the boss ignored my rule" with nothing on screen to explain why.
func _make_name_value_picker(clause: Dictionary) -> Control:
	var by_id: bool = str(clause.get("signal", "")) == RoundTimeline.SIGNAL_LAST_ITEM_ID
	var options: Array = _known_item_ids() if by_id else _known_item_kinds()
	var current: String = str(clause.get("value", ""))
	# An item the journey no longer has still has to round-trip. Dropping it from the list would quietly
	# rewrite the author's rule to whatever happened to sit at index 0.
	if current != "" and not _option_values(options).has(current):
		options.append({"value": current, "label": "%s  (missing)" % current})

	var picker: OptionButton = OptionButton.new()
	picker.custom_minimum_size = Vector2(120, 0)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Same reason as the signal picker: a long item name truncates instead of pushing the row wider.
	picker.clip_text = true
	for option: Dictionary in options:
		picker.add_item(str(option["label"]))
	picker.selected = maxi(0, _option_values(options).find(current))
	picker.item_selected.connect(
		func(i: int) -> void:
			_snapshot("field:clause_value")
			clause["value"] = str((options[i] as Dictionary)["value"])
			_refresh_derived()
	)
	return picker


# value → the name an author would recognise, for every item and kind a rule can name. Handed to
# condition_text so a printed rule says "Silver Key" rather than the id it is stored under.
func _value_labels() -> Dictionary:
	var out: Dictionary = {}
	for source: Array in [_known_item_ids(), _known_item_kinds()]:
		for option: Dictionary in source:
			out[str(option["value"])] = str(option["label"])
	return out


static func _option_values(options: Array) -> Array:
	var out: Array = []
	for option: Dictionary in options:
		out.append(str(option["value"]))
	return out


# Every item an author could reach: the built-in shop items plus THIS journey's custom ones. Built-ins
# come from GetBuiltinItemIds rather than GetAllItemIds on purpose — the latter also carries journey
# items left in play-state from a test-play, which would double this journey's entries and leak the
# previous journey's into the list.
func _known_item_ids() -> Array:
	var out: Array = []
	for id: Variant in InventoryService.GetBuiltinItemIds():
		var data: Dictionary = InventoryService.GetItemData(str(id))
		out.append({"value": str(id), "label": str(data.get("name", id))})
	for raw: Variant in _items:
		if not (raw is Dictionary):
			continue
		var item: Dictionary = raw
		var name: String = str(item.get("name", "")).strip_edges()
		(
			out
			. append(
				{
					"value": str(item.get("id", "")),
					"label":
					"%s  (this journey)" % (name if name != "" else str(item.get("id", ""))),
				}
			)
		)
	return out


# The item KINDS in play, derived from the same two sources rather than hard-coded — a kind added to the
# registry later should appear here without anyone remembering to update a list.
func _known_item_kinds() -> Array:
	var seen: Dictionary = {}
	for id: Variant in InventoryService.GetBuiltinItemIds():
		var kind: String = str(InventoryService.GetItemData(str(id)).get("kind", ""))
		if kind != "":
			seen[kind] = true
	for raw: Variant in _items:
		if not (raw is Dictionary):
			continue
		for effect: Variant in (raw as Dictionary).get("effects", []) as Array:
			if effect is Dictionary:
				var effect_kind: String = str((effect as Dictionary).get("kind", ""))
				if effect_kind != "":
					seen[effect_kind] = true
	var out: Array = []
	for kind: Variant in seen:
		out.append({"value": str(kind), "label": str(kind)})
	return out


# Which branch this event belongs to. A DROPDOWN rather than a text field on purpose: a tag no segment
# claims is treated as "always plays", so a typo would silently put the event on every branch at once —
# a failure that looks like nothing at all until an encounter plays two moves on top of each other.
func _add_branch_field(event: Dictionary) -> void:
	var tags: Array = _all_tags()
	if tags.is_empty():
		return  # nothing to belong to yet; the section above is where branches are created

	var picker: OptionButton = OptionButton.new()
	picker.add_item("ALWAYS PLAYS")
	for tag: String in tags:
		picker.add_item(tag)
	picker.selected = maxi(0, tags.find(str(event.get("variant_tag", ""))) + 1)
	picker.tooltip_text = UITheme.wrap_tip(
		"Put this event on one branch of a segment, or leave it playing every time."
	)
	picker.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:variant_tag")
			event["variant_tag"] = "" if index == 0 else str(tags[index - 1])
			_refresh_derived()
	)
	_inspector.add_child(_labeled("Branch", picker))


# The timeline's segments list, created on demand so an encounter that never uses one carries no key.
func _segments() -> Array:
	if not (_timeline.get("segments", null) is Array):
		_timeline["segments"] = []
	return _timeline["segments"]


# Every branch name any segment declares, in declaration order.
# A pair of branches nothing else has claimed. Tags are namespaced across the WHOLE encounter, not per
# segment — apply_segments() maps a tag to exactly one owning segment — so two segments both offering
# "A" and "B" meant the second one's choice quietly did nothing and cycling appeared to skip it.
func _fresh_branches(count: int) -> Array:
	var taken: Array = _all_tags()
	var out: Array = []
	for _i: int in count:
		var tag: String = _next_free_tag(taken)
		taken.append(tag)
		out.append({"tag": tag, "condition": {}})
	return out


# The first spreadsheet-style name not already in use: A … Z, then AA, AB and so on.
func _next_free_tag(taken: Array) -> String:
	var n: int = 0
	while true:
		var tag: String = ""
		var i: int = n
		while true:
			tag = String.chr(65 + i % 26) + tag
			i = i / 26 - 1
			if i < 0:
				break
		if not taken.has(tag):
			return tag
		n += 1
	return "A"  # unreachable; GDScript wants a terminal return


func _all_tags() -> Array:
	var out: Array = []
	for segment: Dictionary in _segments():
		for tag: String in RoundTimeline.segment_tags(segment):
			if not out.has(tag):
				out.append(tag)
	return out


# Says why this whole section is inert. The controls stay editable rather than being disabled: an author
# may well be building the giving-in ending BEFORE turning the button on, and greying out the controls
# would leave them unable to do that with no explanation of why. Naming the exact setting to flip is
# the part that turns a dead end into a next step.
func _make_finish_warning() -> Control:
	return _make_amber_callout(
		(
			"⚠  This journey's FINISH button is off, so the player can never give in — nothing in this "
			+ 'section can play. Turn on "ALLOW FINISH BUTTON" in the journey settings to use it.'
		),
		10
	)


# One defeat event in the list: what it is, click to edit, and a remove button.
func _make_outcome_row(gave_in_event: Dictionary) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var open: Button = Button.new()
	var label: String = str(gave_in_event.get("text", ""))
	if label == "":
		label = str(gave_in_event.get("clip", "")).get_file()
	if label == "":
		label = str(gave_in_event.get("track", "")).to_upper()
	open.text = "✎  " + label
	open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open.alignment = HORIZONTAL_ALIGNMENT_LEFT
	UITheme.style_button_subtle(
		open, BossTimeline.track_color(str(gave_in_event.get("track", ""))), 10, 6, 11
	)
	open.pressed.connect(func() -> void: _select(str(gave_in_event.get("id", ""))))
	row.add_child(open)

	var remove: Button = Button.new()
	remove.text = "✕"
	UITheme.style_button_subtle(remove, UITheme.DANGER, 8, 4, 11)
	remove.pressed.connect(
		func() -> void:
			_snapshot("delete")
			var kept: Array = []
			for event: Dictionary in _timeline["events"] as Array:
				if str(event.get("id", "")) != str(gave_in_event.get("id", "")):
					kept.append(event)
			_timeline["events"] = kept
			_refresh()
	)
	row.add_child(remove)
	return row


# Adds a defeat event. `at_ms` is fixed at 0 and never shown — it plays on the bail-out, so the
# number would only invite an author to tune something that has no effect.
func _add_outcome_event(on_mode: String, track: String) -> void:
	_snapshot("add")
	var event: Dictionary = {
		"id": RoundTimeline.new_event_id(),
		"track": track,
		"at_ms": 0,
		"on": on_mode,
	}
	(_timeline["events"] as Array).append(event)
	_select(str(event["id"]))
	_refresh()


# What validate() said about this event, shown where the author is already looking instead of in a
# footer that pushed the rest of the layout around as it grew.
func _add_issue_panel(id: String) -> void:
	if not _issues.has(id):
		return
	var lines: Array = []
	for message: String in _issues[id] as Array:
		lines.append("⚠  " + message)
	_inspector.add_child(_make_amber_callout("\n".join(PackedStringArray(lines)), 11))


# The editor's one "read this" box: an amber wash used for anything the author has to act on.
# The quiet sibling of _make_amber_callout, for telling an author something TRUE rather than something
# WRONG. A fresh encounter used to open with two amber callouts before anything was authored — neither a
# mistake, both just settings that had not been turned on — and a warning colour that fires on an empty
# document is one an author learns to scroll past. Amber is now reserved for validate()'s findings.
func _make_quiet_note(text: String, font_size: int) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(label, UITheme.DARK_TEXT, font_size)
	return label


func _make_amber_callout(text: String, font_size: int) -> PanelContainer:
	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(UITheme.AMBER.r, UITheme.AMBER.g, UITheme.AMBER.b, 0.12)
	style.border_color = UITheme.AMBER
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)

	var label: Label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(label, UITheme.AMBER, font_size)
	panel.add_child(label)
	return panel


func _find_phase(id: String) -> Dictionary:
	for phase: Dictionary in _timeline["phases"] as Array:
		if str(phase.get("id", "")) == id:
			return phase
	return {}


# The phase marker editor: rename, set the health it takes over at, toggle its banner, delete.
func _build_phase_inspector(phase: Dictionary) -> void:
	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	var title: Label = Label.new()
	title.text = "PHASE"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(title, UITheme.PURPLE_BRIGHT, 14, true)
	header.add_child(title)
	var delete: Button = Button.new()
	delete.text = "✕ DELETE"
	UITheme.style_button_subtle(delete, UITheme.DANGER, 10, 6, 11)
	delete.pressed.connect(_delete_selected)
	header.add_child(delete)
	_inspector.add_child(header)

	var name_field: LineEdit = LineEdit.new()
	name_field.text = str(phase.get("name", ""))
	UITheme.style_line_edit(name_field)
	name_field.text_changed.connect(func(value: String) -> void: phase["name"] = value)
	_inspector.add_child(_labeled("Name", name_field))

	var hp_spin: SpinBox = SpinBox.new()
	hp_spin.min_value = 0
	hp_spin.max_value = 100
	hp_spin.step = 1
	hp_spin.suffix = "%"
	hp_spin.value = 100.0 * RoundTimeline.phase_hp_at(phase, _full_ms)
	hp_spin.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"She enters this stage the moment the bar drops to here. 100% is the opening stage. "
				+ "Phases follow the BAR, not the clock — so a division on it always means what it says."
			)
		)
	)
	UITheme.style_spin_box(hp_spin)
	hp_spin.value_changed.connect(
		func(value: float) -> void:
			phase[RoundTimeline.PHASE_HP_KEY] = clampf(value / 100.0, 0.0, 1.0)
			_refresh()
	)
	_inspector.add_child(_labeled("Starts at health", hp_spin))

	# Against the clock the bar is round progress read backwards, so a health point is still a time — but
	# an author pointing the bar at SCORE is the case this was built for, and it is worth saying so.
	if not _health_follows_score():
		var note: Label = Label.new()
		note.text = "Health follows the CLOCK, so this is %s into the round." % _hp_as_time(phase)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(note, UITheme.DARK_TEXT, 9)
		_inspector.add_child(note)

	var banner: CheckButton = CheckButton.new()
	banner.text = "SHOW BANNER"
	banner.button_pressed = bool(phase.get("banner", false))
	banner.toggled.connect(
		func(pressed: bool) -> void:
			phase["banner"] = pressed
			_refresh()
	)
	_inspector.add_child(banner)


# Where a health point lands on the clock, for the note above — only meaningful while the bar is being
# driven by time, which is exactly when it is shown.
func _hp_as_time(phase: Dictionary) -> String:
	var full_ms: int = _full_ms
	if full_ms <= 0:
		return "an unknown point"
	var at_ms: int = int((1.0 - RoundTimeline.phase_hp_at(phase, full_ms)) * float(full_ms))
	return "%d:%02d" % [at_ms / 60000, (at_ms / 1000) % 60]


func _add_time_fields(event: Dictionary) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var at_spin: SpinBox = _make_ms_spin(int(event.get("at_ms", 0)))
	at_spin.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:at_ms")
			event["at_ms"] = int(value)
			_refresh()
	)
	row.add_child(_labeled("Start (ms)", at_spin))

	var anchor: OptionButton = OptionButton.new()
	anchor.add_item("from start")
	anchor.add_item("from end")
	anchor.selected = (
		1 if str(event.get("anchor", RoundTimeline.ANCHOR_START)) == RoundTimeline.ANCHOR_END else 0
	)
	anchor.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:anchor")
			event["anchor"] = (
				RoundTimeline.ANCHOR_END if index == 1 else RoundTimeline.ANCHOR_START
			)
			_refresh()
	)
	row.add_child(_labeled("Anchor", anchor))

	var duration_spin: SpinBox = _make_ms_spin(int(event.get("duration_ms", 0)))
	duration_spin.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:duration_ms")
			event["duration_ms"] = int(value)
			_refresh()
	)
	row.add_child(_labeled("Duration (0 = one-shot)", duration_spin))
	_inspector.add_child(row)


func _add_line_edit(event: Dictionary, key: String, label: String) -> void:
	var field: LineEdit = LineEdit.new()
	field.text = str(event.get(key, ""))
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_line_edit(field)
	field.text_changed.connect(
		func(value: String) -> void:
			_snapshot("field:" + key)
			event[key] = value
			_refresh_derived()
	)
	_inspector.add_child(_labeled(label, field))


# A drop zone for one media file. The path is stored as the author's own source; the save pools it.
func _add_file_field(
	event: Dictionary, key: String, label: String, extensions: Array, on_set: Callable = Callable()
) -> void:
	var zone: Control = load("res://scripts/journey_builder/DropZone.gd").new()
	zone.accepted_extensions = extensions
	zone.picker_title = label
	if str(event.get(key, "")) != "":
		zone.call_deferred("set_file", str(event[key]), false)
	zone.file_dropped.connect(
		func(path: String) -> void:
			_snapshot("field:" + key)
			event[key] = path
			if on_set.is_valid():
				on_set.call(path)
			_refresh()
	)
	_inspector.add_child(_labeled(label, zone))


# Where a cue sits and how big it is. The renderer has always honoured these — they simply had no way
# to be set, so every cue drew centred at 1×. Matters most for a LOOSE image, which has no character
# placement to fall back on.
func _add_placement_fields(event: Dictionary) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var anchor: OptionButton = OptionButton.new()
	for name: String in RoundTimeline.CAST_ANCHORS:
		anchor.add_item(name.to_upper())
	anchor.selected = maxi(
		0,
		RoundTimeline.CAST_ANCHORS.find(str(event.get("anchor_pos", RoundTimeline.ANCHOR_CENTER)))
	)
	anchor.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:anchor_pos")
			event["anchor_pos"] = RoundTimeline.CAST_ANCHORS[index]
			_refresh_derived()
	)
	row.add_child(_labeled("Position", anchor))

	var scale: SpinBox = SpinBox.new()
	scale.min_value = 0.05
	scale.max_value = 4.0
	scale.step = 0.05
	scale.value = float(event.get("scale", 1.0))
	UITheme.style_spin_box(scale)
	scale.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:scale")
			event["scale"] = value
			_refresh_derived()
	)
	row.add_child(_labeled("Size", scale))

	# Offset is stored as {x, y} (the shape has to survive JSON), so the two axes are edited separately.
	var offset: Dictionary = event.get("offset", {"x": 0.0, "y": 0.0})
	event["offset"] = offset
	row.add_child(_labeled("Nudge X", _make_float_spin(offset, "x", -2000.0, 2000.0, 5.0)))
	row.add_child(_labeled("Nudge Y", _make_float_spin(offset, "y", -2000.0, 2000.0, 5.0)))
	_inspector.add_child(row)

	# Its own row: five controls do not fit the inspector's width. Blend was previously reachable ONLY by
	# stamping it from the telegraph preset, so a cue could composite differently from every other cue
	# with no control on screen to explain why — the author could see the effect but not its cause.
	var blend: OptionButton = OptionButton.new()
	for mode: String in RoundTimeline.BLENDS:
		blend.add_item(mode.to_upper())
	blend.selected = maxi(
		0, RoundTimeline.BLENDS.find(str(event.get("blend", RoundTimeline.BLEND_NORMAL)))
	)
	blend.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"How an ANIMATED cue composites. NORMAL draws the clip as it is. ADD and SCREEN drop black "
				+ "out, which is what lets a flash or a glow sit on the picture instead of showing as a "
				+ "rectangle — use them for art on a black background. SCREEN currently renders the same as "
				+ "ADD. Still images ignore this."
			)
		)
	)
	blend.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:blend")
			event["blend"] = RoundTimeline.BLENDS[index]
			_refresh_derived()
	)
	_inspector.add_child(_labeled("Blend (animated art only)", blend))


# How the cue's subtitle LOOKS. It has no timing of its own — the line shares the cue's fades and its
# lifetime, and a line that needs different timing is simply a separate text-only cast cue.
func _add_subtitle_fields(event: Dictionary) -> void:
	var style_row: HBoxContainer = HBoxContainer.new()
	style_row.add_theme_constant_override("separation", 8)

	var size: SpinBox = SpinBox.new()
	size.min_value = RoundTimeline.MIN_TEXT_SIZE
	size.max_value = RoundTimeline.MAX_TEXT_SIZE
	size.step = 1
	size.value = int(event.get("text_size", RoundTimeline.DEFAULT_TEXT_SIZE))
	size.tooltip_text = UITheme.wrap_tip(
		"Type size for this line, as it will look on a 1080p screen."
	)
	UITheme.style_spin_box(size)
	size.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:text_size")
			event["text_size"] = int(value)
			_refresh_derived()
	)
	style_row.add_child(_labeled("Text size", size))

	var colour: ColorPickerButton = ColorPickerButton.new()
	colour.custom_minimum_size = Vector2(SWATCH_SIZE, SWATCH_SIZE)
	colour.edit_alpha = false
	colour.color = RoundTimeline.cue_text_color(event, UITheme.WHITE_SOFT)
	colour.tooltip_text = UITheme.wrap_tip(
		"Colour for this line — give a speaker their own and dialogue reads without a name tag."
	)
	colour.color_changed.connect(
		func(value: Color) -> void:
			_snapshot("field:text_color")
			event["text_color"] = {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
			_refresh_derived()
	)
	style_row.add_child(_labeled("Text colour", colour))

	var line_y: SpinBox = SpinBox.new()
	line_y.min_value = 0.0
	line_y.max_value = 1.0
	line_y.step = 0.01
	line_y.value = float(event.get("text_y", RoundTimeline.DEFAULT_TEXT_Y))
	line_y.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"Where the line sits down the screen: 0 is the top edge, 1 the bottom. Tuck it under a "
				+ "portrait, lift it clear of the health bar, or centre it — the preview shows the bar, so "
				+ "you can place it against the real thing."
			)
		)
	)
	UITheme.style_spin_box(line_y)
	line_y.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:text_y")
			event["text_y"] = value
			_refresh_derived()
	)
	style_row.add_child(_labeled("Line Y", line_y))
	_inspector.add_child(style_row)


# ALTERNATIVES. One of these plays instead of the base each time the round is entered, so a boss met
# twice does not repeat itself word for word. The base counts as a candidate — two alternatives means
# three possible lines — which is what an author means by the word and what roll_variants implements.
#
# Only content is swappable (RoundTimeline.ALT_FIELDS). Timing, placement and fades stay on the parent,
# because an alternative that could move itself would let one candidate reorder against its siblings.
func _add_alts_list(event: Dictionary) -> void:
	var track: String = str(event.get("track", ""))
	var alts: Array = event.get("alts", [])
	if not (event.get("alts", null) is Array):
		alts = []
		event["alts"] = alts

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var title: Label = Label.new()
	title.text = "ALTERNATIVES (%d)" % alts.size()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(title, UITheme.CYAN, 10, true)
	header.add_child(title)

	var add: Button = Button.new()
	add.text = "＋ ALTERNATIVE"
	add.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"Another version of this one, picked at random when the round starts. The original stays in "
				+ "the running — two alternatives means three possible outcomes."
			)
		)
	)
	UITheme.style_button_subtle(add, UITheme.CYAN, 10, 6, 11)
	add.pressed.connect(
		func() -> void:
			_snapshot("add-alt")
			alts.append(_blank_alt(track))
			_refresh()
	)
	header.add_child(add)
	_inspector.add_child(header)

	# The BASE counts as a candidate — two alternatives means three possible outcomes — so it needs its
	# own way back into the preview once one of the others has been pinned.
	if not alts.is_empty():
		var base: Button = Button.new()
		var on_base: bool = _stage.variant_of(str(event["id"])) == 0
		base.text = ("◉ " if on_base else "◎ ") + "SHOW THE ORIGINAL"
		UITheme.style_button_subtle(
			base, UITheme.TOXIC_GREEN if on_base else UITheme.DARK_TEXT, 9, 4, 10
		)
		base.pressed.connect(
			func() -> void:
				_stage.set_variant(str(event["id"]), 0)
				_refresh()  # the ◉/◎ marks live in the inspector, so it has to be rebuilt
		)
		_inspector.add_child(base)

	for i: int in alts.size():
		_inspector.add_child(_make_alt_row(alts, i, track, event))


# One alternative: the handful of fields it may overlay, and a remove button. Deliberately a SUBSET of
# the base cue's controls — showing all of them would imply an alternative can change timing, which it
# cannot.
# What an empty alternative looks like on each track — the one field it exists to swap.
func _blank_alt(track: String) -> Dictionary:
	return {"text": ""} if track == RoundTimeline.TRACK_CAST else {"clip": ""}


func _make_alt_row(alts: Array, index: int, track: String, alt_of: Dictionary) -> Control:
	var alt: Dictionary = alts[index]
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label: Label = Label.new()
	label.text = "#%d" % (index + 1)
	UITheme.style_label(label, UITheme.DARK_TEXT, 10, true)
	row.add_child(label)

	if track == RoundTimeline.TRACK_CAST:
		var line: LineEdit = LineEdit.new()
		line.text = str(alt.get("text", ""))
		line.placeholder_text = "Subtitle for this version"
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_line_edit(line)
		line.text_changed.connect(
			func(value: String) -> void:
				_snapshot("field:alt_text")
				alt["text"] = value
				_refresh_derived()
		)
		row.add_child(line)
	else:
		var name_label: Label = Label.new()
		name_label.text = (
			str(alt.get("clip", "")).get_file() if str(alt.get("clip", "")) != "" else "(no clip)"
		)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		UITheme.style_label(name_label, UITheme.WHITE_SOFT, 10)
		row.add_child(name_label)

	# Pins the preview to THIS candidate. CYCLE walks every combination in the encounter, which is the
	# wrong tool when an author is editing one line and wants to look at it — they had to keep pressing
	# until it came round again.
	var showing: bool = _stage.variant_of(str(alt_of["id"])) == index + 1
	var pin: Button = Button.new()
	pin.text = "◉" if showing else "◎"
	pin.tooltip_text = UITheme.wrap_tip("Show this version in the preview.")
	UITheme.style_button_subtle(
		pin, UITheme.TOXIC_GREEN if showing else UITheme.DARK_TEXT, 8, 4, 11
	)
	pin.pressed.connect(
		func() -> void:
			_stage.set_variant(str(alt_of["id"]), index + 1)
			_refresh()  # the ◉/◎ marks live in the inspector, so it has to be rebuilt
	)
	row.add_child(pin)

	var remove: Button = Button.new()
	remove.text = "✕"
	UITheme.style_button_subtle(remove, UITheme.DANGER, 8, 4, 11)
	remove.pressed.connect(
		func() -> void:
			_snapshot("delete-alt")
			alts.remove_at(index)
			_refresh()
	)
	row.add_child(remove)
	box.add_child(row)

	# The swappable media sits on its own line: a drop zone needs the width.
	var media_key: String = "image" if track == RoundTimeline.TRACK_CAST else "clip"
	var extensions: Array = (
		JourneyData.IMAGE_EXTENSIONS
		if track == RoundTimeline.TRACK_CAST
		else JourneyAudio.AUDIO_EXTENSIONS
	)
	var zone: Control = load("res://scripts/journey_builder/DropZone.gd").new()
	zone.accepted_extensions = extensions
	zone.picker_title = "Alternative media"
	if str(alt.get(media_key, "")) != "":
		zone.call_deferred("set_file", str(alt[media_key]), false)
	zone.file_dropped.connect(
		func(path: String) -> void:
			_snapshot("field:alt_media")
			alt[media_key] = path
			_refresh()
	)
	box.add_child(zone)
	if track == RoundTimeline.TRACK_CAST:
		var expression: Control = _make_alt_expression_picker(alt, alt_of)
		if expression != null:
			box.add_child(expression)
		box.add_child(_make_alt_framing_row(alt))
	return box


# A different EXPRESSION of the same character — the natural way to vary a character's cue, and cheaper
# than dropping a loose image, which severs the character link entirely. Only offered when the parent
# names a character that actually has more than one expression to choose between.
func _make_alt_expression_picker(alt: Dictionary, alt_of: Dictionary) -> Control:
	var chosen: Dictionary = _character_by_id(str(alt_of.get("character_id", "")))
	if chosen.is_empty():
		return null
	var portraits: Array = chosen.get("portraits", [])
	if portraits.size() < 2:
		return null
	var picker: OptionButton = OptionButton.new()
	picker.clip_text = true
	picker.add_item("SAME AS BASE")
	var selected: int = 0
	for i: int in portraits.size():
		var portrait: Dictionary = portraits[i]
		picker.add_item(str(portrait.get("name", "Expression %d" % (i + 1))))
		if alt.has("portrait") and str(portrait.get("id", "")) == str(alt["portrait"]):
			selected = i + 1
	picker.selected = selected
	picker.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:alt_portrait")
			if index == 0:
				alt.erase("portrait")  # back to inheriting rather than pinned to whatever showed
			else:
				alt["portrait"] = str((portraits[index - 1] as Dictionary).get("id", ""))
			_refresh()
	)
	return _labeled("Expression", picker)


# Per-alternative FRAMING. A portrait and a wide shot want different placement, and an alt that leaves
# these alone still inherits the parent's — each control writes only when it is touched, so a blank
# alternative stays a pure content swap.
func _make_alt_framing_row(alt: Dictionary) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var anchor: OptionButton = OptionButton.new()
	anchor.clip_text = true
	anchor.add_item("SAME AS BASE")
	for name: String in RoundTimeline.CAST_ANCHORS:
		anchor.add_item(name.to_upper())
	anchor.selected = (
		0
		if not alt.has("anchor_pos")
		else 1 + maxi(0, RoundTimeline.CAST_ANCHORS.find(str(alt["anchor_pos"])))
	)
	anchor.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:alt_anchor_pos")
			if index == 0:
				alt.erase("anchor_pos")  # back to inheriting, not pinned to whatever was showing
			else:
				alt["anchor_pos"] = RoundTimeline.CAST_ANCHORS[index - 1]
			_refresh_derived()
	)
	row.add_child(_labeled("Position", anchor))

	var scale: SpinBox = SpinBox.new()
	scale.min_value = 0.05
	scale.max_value = 4.0
	scale.step = 0.05
	scale.value = float(alt.get("scale", 1.0))
	UITheme.style_spin_box(scale)
	scale.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:alt_scale")
			alt["scale"] = value
			_refresh_derived()
	)
	row.add_child(_labeled("Size", scale))

	# Attached to the alternative only once it is actually nudged. Writing it up front would overlay a
	# {0,0} offset onto the parent's own, silently un-nudging every alternative of a cue that had one.
	var offset: Dictionary = (alt.get("offset", {"x": 0.0, "y": 0.0}) as Dictionary).duplicate()
	var nudge_x: SpinBox = _make_float_spin(offset, "x", -2000.0, 2000.0, 5.0)
	var nudge_y: SpinBox = _make_float_spin(offset, "y", -2000.0, 2000.0, 5.0)
	var attach: Callable = func(_value: float) -> void: alt["offset"] = offset
	nudge_x.value_changed.connect(attach)
	nudge_y.value_changed.connect(attach)
	row.add_child(_labeled("X", nudge_x))
	row.add_child(_labeled("Y", nudge_y))
	return row


# Where a win skips the clip to. Optional: left off, the round simply plays out as aftermath.
func _add_win_jump_fields() -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var enabled: CheckButton = CheckButton.new()
	enabled.text = "SKIP AHEAD ON WIN"
	enabled.button_pressed = (
		int(_timeline.get("win_jump_ms", RoundTimeline.NO_TIME)) != RoundTimeline.NO_TIME
	)
	enabled.tooltip_text = UITheme.wrap_tip(
		(
			"Jumps the clip forward the moment she goes down, so a win reaches the ending sooner. "
			+ "Forward only — a backward jump would replay events the encounter has already fired."
		)
	)
	enabled.toggled.connect(
		func(pressed: bool) -> void:
			_snapshot("field:win_jump_ms")
			_timeline["win_jump_ms"] = 10000 if pressed else RoundTimeline.NO_TIME
			_refresh()
	)
	row.add_child(enabled)
	_inspector.add_child(row)

	if int(_timeline.get("win_jump_ms", RoundTimeline.NO_TIME)) == RoundTimeline.NO_TIME:
		return

	var where: HBoxContainer = HBoxContainer.new()
	where.add_theme_constant_override("separation", 8)

	var anchor: OptionButton = OptionButton.new()
	anchor.add_item("FROM THE END")
	anchor.add_item("FROM THE START")
	anchor.selected = (
		1
		if (
			str(_timeline.get("win_jump_anchor", RoundTimeline.ANCHOR_END))
			== RoundTimeline.ANCHOR_START
		)
		else 0
	)
	anchor.tooltip_text = UITheme.wrap_tip(
		(
			"FROM THE END is usually what you want: skip to the last 10 seconds survives you "
			+ "re-cutting the clip, where a position measured from the start does not."
		)
	)
	anchor.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:win_jump_anchor")
			_timeline["win_jump_anchor"] = (
				RoundTimeline.ANCHOR_START if index == 1 else RoundTimeline.ANCHOR_END
			)
			_refresh_derived()
	)
	where.add_child(_labeled("Measured", anchor))

	var at: SpinBox = _make_ms_spin(maxi(0, int(_timeline.get("win_jump_ms", 0))))
	at.tooltip_text = UITheme.wrap_tip(
		"Right-click the timeline to put this on a frame you can actually see, marked ⚑ WIN."
	)
	at.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:win_jump_ms")
			_timeline["win_jump_ms"] = int(value)
			_refresh()
	)
	where.add_child(_labeled("Jump to (ms)", at))
	_inspector.add_child(where)

	var hint: Label = Label.new()
	hint.text = "Right-click the timeline → Skip ahead to here on win, to place the ⚑ WIN flag."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(hint, UITheme.DARK_TEXT, 9)
	_inspector.add_child(hint)


# The two ways she claws health back. Both default to OFF, so no existing encounter gains a mechanic it
# was not authored with, and both live here rather than on the timeline because they are properties of
# the FIGHT rather than moments in it. The third way — a RECOVERING stance — is a window on the track.
func _add_regen_fields() -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var pause: SpinBox = SpinBox.new()
	pause.min_value = 0
	pause.max_value = 100000
	pause.step = 1  # a step above 1 would make "1 per second" unreachable — see damage_target
	pause.value = float(_timeline.get("pause_regen_per_sec", 0))
	pause.tooltip_text = (UITheme.wrap_tip(
		(
			"Health she wins back for every second the game is PAUSED. Zero is off. Pausing is the "
			+ "only slowdown a player can actually perform — the score comes from the script, not "
			+ "from them — so this is what makes stepping away from a fight cost something."
		)
	))
	UITheme.style_spin_box(pause)
	pause.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:pause_regen_per_sec")
			_timeline["pause_regen_per_sec"] = int(value)
			_refresh_derived()
	)
	row.add_child(_labeled("Heals while paused (per sec)", pause))

	var attempt: SpinBox = SpinBox.new()
	attempt.min_value = 0
	attempt.max_value = 100
	attempt.step = 1
	attempt.suffix = "%"
	attempt.value = 100.0 * float(_timeline.get("attempt_regen_pct", 0.0))
	attempt.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"How much of the bar she recovers before each replay. Zero is off, and the fight is pure "
				+ "attrition. Anything above it turns a replay into an escalation rather than a grind — "
				+ "at 100% every attempt starts her at full."
			)
		)
	)
	UITheme.style_spin_box(attempt)
	attempt.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:attempt_regen_pct")
			_timeline["attempt_regen_pct"] = value / 100.0
			_refresh_derived()
	)
	row.add_child(_labeled("Heals between attempts", attempt))
	_inspector.add_child(row)

	if not RoundTimeline.allows_replay(_timeline):
		var note: Label = Label.new()
		note.text = "Healing between attempts needs more than one attempt to matter."
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(note, UITheme.DARK_TEXT, 9)
		_inspector.add_child(note)


# What a full pass of this round deals, and a button to size the boss against it.
#
# Without this an author picks `damage_target` blind, and the number decides how long every fight lasts.
# It is computable exactly — scoring runs off the script, not the player — so there is no reason to make
# them guess it.
func _add_target_recommendation() -> void:
	var suggested: int = _full_pass_score()
	if suggested <= 0:
		var note: Label = Label.new()
		note.text = (
			"Add this round's funscript to see what a full pass is worth — without it the target is a "
			+ "guess."
		)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(note, UITheme.DARK_TEXT, 9)
		_inspector.add_child(note)
		return

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var note: Label = Label.new()
	note.text = "A full pass deals %d." % suggested
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(note, UITheme.TOXIC_GREEN, 9)
	row.add_child(note)

	var use: Button = Button.new()
	use.text = "USE"
	use.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"Sets the target to one full pass, so the fight is decided within the round. Set it HIGHER "
				+ "for a boss that takes more than one attempt, LOWER for one that goes down early and "
				+ "leaves the rest of the clip as aftermath."
			)
		)
	)
	UITheme.style_button_subtle(use, UITheme.TOXIC_GREEN, 10, 6, 10)
	use.pressed.connect(
		func() -> void:
			_snapshot("field:damage_target")
			_timeline["damage_target"] = suggested
			_refresh()
	)
	row.add_child(use)
	_inspector.add_child(row)


# The round's own funscript, scored the way the round will score it. Zero when there is no script to
# read — a video-only round has nothing to compute from.
func _full_pass_score() -> int:
	if _reference_points.is_empty():
		return 0
	return (
		RoundTimeline
		. expected_pass_score(
			_reference_points,
			{
				"small_max": ScoreService.SmallStrokeMax,
				"medium_max": ScoreService.MediumStrokeMax,
				"small_pts": ScoreService.SmallStrokePoints,
				"medium_pts": ScoreService.MediumStrokePoints,
				"large_pts": ScoreService.LargeStrokePoints,
			}
		)
	)


# How the boss takes damage while this window is open, as a NAME rather than a number — the bar shows
# one word, so the thing an author picks should be that word.
func _add_stance_field(event: Dictionary) -> void:
	var picker: OptionButton = OptionButton.new()
	picker.clip_text = true  # or it sizes to its longest entry and pushes the inspector wider
	for stance: String in RoundTimeline.STANCES:
		picker.add_item("%s   x%s" % [RoundTimeline.stance_label(stance), _mult_text(stance)])
	picker.selected = maxi(0, RoundTimeline.STANCES.find(RoundTimeline.event_stance(event)))
	picker.tooltip_text = (
		UITheme
		. wrap_tip(
			(
				"How much damage lands while this window is open, and the word the health bar shows. "
				+ "RECOVERING runs the bar backwards — she heals. ATTACKING is for a move written into the "
				+ "ROUND's own funscript rather than placed on the attack track: nothing can detect one, so "
				+ "mark it here: she takes no damage through it and override items cannot cut in, exactly "
				+ "as on the attack track. An attack there needs none, being both already. Only ONE "
				+ "stance can be in force, so these must not overlap."
			)
		)
	)
	UITheme.style_option_button(picker)
	picker.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:stance")
			event["stance"] = RoundTimeline.STANCES[index]
			_refresh()
	)
	_inspector.add_child(_labeled("Stance", picker))

	if not _health_follows_score():
		(
			_inspector
			. add_child(
				_make_amber_callout(
					(
						"⚠  The health bar follows the CLOCK here, so there is no damage for a stance to "
						+ "change. Point it at SCORE in the encounter settings to make this do anything."
					),
					9
				)
			)
		)


# The multiplier as it reads in a menu: whole where it is whole, so "x2" rather than "x2.0".
func _mult_text(stance: String) -> String:
	var mult: float = RoundTimeline.stance_mult(stance)
	return str(int(mult)) if is_equal_approx(mult, float(int(mult))) else str(mult)


# How a cast cue ENTERS. All three modes were implemented in BossCueLayer from the start but none had a
# control: `flash` could only be obtained by stamping the telegraph preset, and `slide` was unreachable
# altogether — an author could not have produced one however hard they tried.
func _add_transition_field(event: Dictionary) -> void:
	var transition: OptionButton = OptionButton.new()
	for mode: String in RoundTimeline.TRANSITIONS:
		transition.add_item(mode.to_upper().replace("_", " "))
	transition.selected = maxi(
		0,
		RoundTimeline.TRANSITIONS.find(str(event.get("transition", RoundTimeline.TRANSITION_FADE)))
	)
	transition.tooltip_text = (UITheme.wrap_tip(
		(
			"How the cue arrives, over the fade-in time below. FADE simply eases in. FLASH appears "
			+ "instantly and ignores that time — the telegraph look. POP punches in slightly "
			+ "oversized and settles. RISE drifts gently up, for dialogue. SLIDE travels in from "
			+ "the named edge — usually the edge the cue sits nearest, so it does not cross the "
			+ "whole picture on its way in."
		)
	))
	transition.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:transition")
			event["transition"] = RoundTimeline.TRANSITIONS[index]
			_refresh_derived()
	)
	_inspector.add_child(_labeled("Entrance", transition))


# Ease-in / ease-out, in ms. Without these a cue or an effect window snaps on and off, which reads as a
# glitch rather than a deliberate moment; the runtime already tweens on these numbers.
func _add_fade_fields(event: Dictionary, in_key: String, out_key: String, label: String) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var fade_in: SpinBox = _make_ms_spin(int(event.get(in_key, 0)))
	fade_in.value_changed.connect(
		func(value: float) -> void:
			event[in_key] = int(value)
			_refresh_derived()
	)
	row.add_child(_labeled("Ease in", fade_in))
	var fade_out: SpinBox = _make_ms_spin(int(event.get(out_key, 0)))
	fade_out.value_changed.connect(
		func(value: float) -> void:
			event[out_key] = int(value)
			_refresh_derived()
	)
	row.add_child(_labeled("Ease out", fade_out))
	_inspector.add_child(_labeled(label, row))


# "Play raw": the same per-item flag an override carries. Off (the default) means any effect window this
# attack overlaps transforms it, exactly as active curses transform an override item; on means it plays
# untouched. The curve above redraws either way, so the choice is visible rather than theoretical.
func _add_immunity_toggle(event: Dictionary) -> void:
	var toggle: CheckButton = CheckButton.new()
	toggle.text = "PLAY RAW (ignore effect windows)"
	toggle.button_pressed = bool(event.get("immune_to_effects", false))
	toggle.tooltip_text = (
		UITheme
		. wrap_tip(
			"Off: effect windows covering this attack transform it, like curses transform an override. On: it plays exactly as scripted."
		)
	)
	toggle.toggled.connect(
		func(pressed: bool) -> void:
			_snapshot("field:immune_to_effects")
			event["immune_to_effects"] = pressed
			_refresh_derived()
	)
	_inspector.add_child(toggle)


# An attack can be built from an OVERRIDE ITEM the journey already defines, instead of re-dropping its
# funscripts: the two carry the identical bundle shape, so this copies scripts + trim + immunity across.
# A copy rather than a reference — editing the item later should not silently rewrite an encounter.
func _add_override_reuse(event: Dictionary) -> void:
	var overrides: Array = _available_overrides()
	if overrides.is_empty():
		return

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var picker: OptionButton = OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for item: Dictionary in overrides:
		# Built-ins are marked: two overrides can share a name, and which one you are copying matters.
		var built_in: bool = str(item.get("scripts", {}).get("main", "")).begins_with("res://")
		picker.add_item(
			(
				("%s  (built-in)" % str(item.get("name", "Override")))
				if built_in
				else str(item.get("name", "Override"))
			)
		)
	row.add_child(picker)

	var use: Button = Button.new()
	use.text = "USE"
	UITheme.style_button_subtle(use, UITheme.CYAN, 10, 6, 11)
	use.pressed.connect(
		func() -> void:
			_snapshot("override-reuse")
			var item: Dictionary = overrides[clampi(picker.selected, 0, overrides.size() - 1)]
			var scripts: Dictionary = (item.get("scripts", {}) as Dictionary).duplicate(true)
			event["scripts"] = scripts
			event["immune_to_effects"] = bool(item.get("immune_to_effects", false))
			if str(item.get("name", "")) != "" and str(event.get("name", "")) == "":
				event["name"] = str(item["name"])
			var trim: Dictionary = item.get("trim", {})
			if trim is Dictionary and not (trim as Dictionary).is_empty():
				event["trim"] = (trim as Dictionary).duplicate(true)
			_adopt_media_length(event, _funscript_length_ms(str(scripts.get("main", ""))))
			_refresh()
	)
	row.add_child(use)
	_inspector.add_child(_labeled("Build from an existing override item", row))


# Every override an attack could be built from: the journey's own custom items PLUS the app's built-in
# overrides. The built-ins were the gap — a journey with no custom items offered nothing at all, which
# read as the feature being missing rather than empty. Journey items come first (an author's own work is
# what they are usually reaching for) and their scripts are already absolute; a built-in's live under
# res:// and pool into the journey on save like any other attack script.
func _available_overrides() -> Array:
	var out: Array = []
	for raw: Variant in _items:
		if raw is Dictionary and str((raw as Dictionary).get("category", "")) == "override":
			out.append(raw)
	for id: Variant in InventoryService.GetBuiltinItemIds():
		var item: Dictionary = InventoryService.GetItemData(str(id))
		if str(item.get("category", "")) == "override":
			out.append(item)
	return out


# A cue can name one of the JOURNEY'S CHARACTERS and show a chosen expression — the same cast the
# storyboards use, so a boss is defined once and reused (BOSS_ROUND_DESIGN §5). Falls back to the cue's
# own image when no character is named, and says so when the journey has no cast at all.
func _add_character_fields(event: Dictionary) -> void:
	if _characters.is_empty():
		var hint: Label = Label.new()
		hint.text = "No cast in this journey yet — drop an image below, or add characters in Journey settings."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(hint, UITheme.DARK_TEXT, 10)
		_inspector.add_child(hint)
		return

	var picker: OptionButton = OptionButton.new()
	picker.add_item("— none (use the image below) —")
	var selected_index: int = 0
	for i: int in _characters.size():
		var character: Dictionary = _characters[i]
		picker.add_item(str(character.get("name", "Character")))
		if str(character.get("id", "")) == str(event.get("character_id", "")):
			selected_index = i + 1
	picker.selected = selected_index
	picker.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:character_id")
			event["character_id"] = (
				"" if index == 0 else str((_characters[index - 1] as Dictionary).get("id", ""))
			)
			event["portrait"] = ""  # the old expression belongs to the old character
			_refresh()
	)
	_inspector.add_child(_labeled("Character", picker))

	# Expressions are per-character, so the list only appears once one is chosen.
	var chosen: Dictionary = _character_by_id(str(event.get("character_id", "")))
	if chosen.is_empty():
		return
	var portraits: Array = chosen.get("portraits", [])
	if portraits.size() < 2:
		return  # a single expression is the default; a one-item dropdown would be noise
	var expression: OptionButton = OptionButton.new()
	var expression_index: int = 0
	for i: int in portraits.size():
		var portrait: Dictionary = portraits[i]
		expression.add_item(str(portrait.get("name", "Expression %d" % (i + 1))))
		if str(portrait.get("id", "")) == str(event.get("portrait", "")):
			expression_index = i
	expression.selected = expression_index
	expression.item_selected.connect(
		func(index: int) -> void:
			_snapshot("field:portrait")
			event["portrait"] = str((portraits[index] as Dictionary).get("id", ""))
			_refresh()
	)
	_inspector.add_child(_labeled("Expression", expression))


func _character_by_id(id: String) -> Dictionary:
	for raw: Variant in _characters:
		if raw is Dictionary and str((raw as Dictionary).get("id", "")) == id:
			return raw
	return {}


# An attack's funscript BUNDLE — the same {main, axes, vibes} shape an override item carries, so the
# runtime loads it with no adapter. Dropping several files at once routes them to their channels by
# filename suffix (the bulk importer's rules), which is how a multi-axis attack gets authored in one go.
func _add_script_field(event: Dictionary) -> void:
	var scripts: Dictionary = event.get("scripts", {})
	if scripts.is_empty():
		scripts = {"main": "", "axes": {}, "vibes": {}}
		event["scripts"] = scripts

	var zone: Control = load("res://scripts/journey_builder/DropZone.gd").new()
	zone.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS
	zone.multi = true
	zone.picker_title = "Attack funscripts (main + axes + vibration)"
	zone.files_dropped.connect(
		func(paths: PackedStringArray) -> void:
			_snapshot("scripts-drop")
			var routed: Dictionary = ImportScanner.classify_script_paths(paths)
			if str(routed["funscript"]) != "":
				scripts["main"] = str(routed["funscript"])
				_adopt_media_length(event, _funscript_length_ms(str(routed["funscript"])))
			(scripts["axes"] as Dictionary).merge(routed["axis"] as Dictionary, true)
			(scripts["vibes"] as Dictionary).merge(routed["vib"] as Dictionary, true)
			_refresh()
	)
	_inspector.add_child(_labeled("Attack funscripts (drop main + axes together)", zone))

	# What the bundle currently holds, with a way to drop any one channel.
	_add_channel_row(scripts, "main", "MAIN", "")
	for axis: Variant in (scripts["axes"] as Dictionary).keys():
		_add_channel_row(scripts, "axes", "AXIS " + str(axis), str(axis))
	for channel: Variant in (scripts["vibes"] as Dictionary).keys():
		_add_channel_row(scripts, "vibes", "VIB " + str(channel), str(channel))

	_add_test_row(event)


# One line of the attack's bundle: which channel, the file on it, and a clear button.
func _add_channel_row(scripts: Dictionary, group: String, label: String, key: String) -> void:
	var path: String = (
		str(scripts.get("main", ""))
		if group == "main"
		else str((scripts[group] as Dictionary).get(key, ""))
	)
	if path == "":
		return
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var tag: Label = Label.new()
	tag.text = label
	tag.custom_minimum_size = Vector2(90, 0)
	UITheme.style_label(tag, UITheme.CYAN, 10, true)
	row.add_child(tag)

	var name_label: Label = Label.new()
	name_label.text = path.get_file()
	name_label.tooltip_text = UITheme.wrap_tip(path)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UITheme.style_label(name_label, UITheme.WHITE_SOFT, 10)
	row.add_child(name_label)

	var clear: Button = Button.new()
	clear.text = "✕"
	UITheme.style_button_subtle(clear, UITheme.DANGER, 8, 4, 10)
	clear.pressed.connect(
		func() -> void:
			_snapshot("clear-channel")
			if group == "main":
				scripts["main"] = ""
			else:
				(scripts[group] as Dictionary).erase(key)
			_refresh()
	)
	row.add_child(clear)
	_inspector.add_child(row)


# ▶ TEST ON DEVICE — plays this attack on the connected device straight from the editor, so an author
# can FEEL it without playing the round. Reuses OverrideTestPlayer, the same path the override item
# editor uses; the boss timeline's playhead sweeps along with it.
func _add_test_row(event: Dictionary) -> void:
	var button: Button = Button.new()
	button.text = (
		"■ STOP" if _test_player != null and _test_player.is_playing() else "▶ TEST ON DEVICE"
	)
	UITheme.style_button_subtle(button, UITheme.TOXIC_GREEN, 12, 8, 12)
	button.pressed.connect(func() -> void: _toggle_test(event))
	_inspector.add_child(button)


func _toggle_test(event: Dictionary) -> void:
	if _test_player == null:
		_test_player = OverrideTestPlayer.new()
		# Parented to the timeline view so closing the modal frees it — _exit_tree stops the device, so
		# an author who closes mid-test never leaves it running.
		_timeline_view.add_child(_test_player)
		_test_player.state_changed.connect(
			func(_playing: bool) -> void:
				_timeline_view.set_playhead(-1)
				_rebuild_inspector()
		)
	if _test_player.is_playing():
		_test_player.stop()
		return
	var bundle: OverrideBundle = _build_attack_bundle(event)
	if bundle == null or bundle.is_empty():
		return
	# The playhead sweeps from where the attack sits on the round's clock, so the test reads against the
	# encounter rather than from zero.
	_test_player.start(bundle, _timeline_view, RoundTimeline.resolve_at_ms(event, _full_ms))
	_rebuild_inspector()


# The attack's channels as a playable bundle. Trim is applied per channel, exactly as the runtime's
# loader does, so what the device plays here is what it will play in the round.
func _build_attack_bundle(event: Dictionary) -> OverrideBundle:
	var scripts: Dictionary = event.get("scripts", {})
	var trim: Dictionary = event.get("trim", {})
	var main: Array = JourneyData.apply_override_trim(
		JourneyData.read_funscript_actions(str(scripts.get("main", ""))), trim
	)
	var axes: Dictionary = {}
	for axis: Variant in scripts.get("axes", {}):
		var points: Array = JourneyData.apply_override_trim(
			JourneyData.read_funscript_actions(str(scripts["axes"][axis])), trim
		)
		if not points.is_empty():
			axes[str(axis)] = points
	var vibes: Dictionary = {}
	for channel: Variant in scripts.get("vibes", {}):
		var points: Array = JourneyData.apply_override_trim(
			JourneyData.read_funscript_actions(str(scripts["vibes"][channel])), trim
		)
		if not points.is_empty():
			vibes[int(channel)] = points
	return OverrideBundle.from_channels(main, axes, vibes)


# ── Effects picker ───────────────────────────────────────────────────────────

# What a windowed effect can apply. STROKE kinds are the same forced modifiers a boss round carries
# (they compose with the round's script exactly as a boss modifier does); SENSORY kinds come from the
# shared catalogue, so the encounter offers the same visual/audio palette the rest of the app does.
const STROKE_EFFECT_KINDS: Array[String] = [
	"scale", "clamp", "reverse", "block", "score_multiplier"
]


# The effect bundle this window applies: one row per effect, plus a kind dropdown to add another. Rows
# rebuild through _refresh(), so the validation line updates as the bundle is filled in.
func _add_effects_picker(event: Dictionary) -> void:
	var effects: Array = event.get("effects", [])
	if not (event.get("effects", null) is Array):
		effects = []
		event["effects"] = effects

	var add_row: HBoxContainer = HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 8)
	var picker: OptionButton = OptionButton.new()
	_fill_effect_picker(picker)
	add_row.add_child(picker)
	var add_button: Button = Button.new()
	add_button.text = "＋ ADD EFFECT"
	UITheme.style_button_subtle(add_button, UITheme.PURPLE_MID, 10, 6, 11)
	add_button.pressed.connect(
		func() -> void:
			# The kind rides on item metadata rather than an index, because separators occupy indices
			# too and an offset lookup would silently pick the wrong effect.
			var chosen: Variant = picker.get_selected_metadata()
			if chosen == null:
				return
			_snapshot("add-effect")
			(event["effects"] as Array).append(_default_effect(str(chosen)))
			_refresh()
	)
	add_row.add_child(add_button)
	_inspector.add_child(_labeled("Effects applied for this window", add_row))
	# The list sits UNDER its "add" row so a growing bundle pushes downwards into the inspector's own
	# scroll, instead of shoving the picker further from where the author is reading.
	for i: int in effects.size():
		_inspector.add_child(_make_effect_row(event, i))


# Grouped into the three things an effect can act on — the stroke, what you hear, what you see — so a
# long flat list of kinds becomes something an author can scan. Separators are labels only; the real
# selection travels as item METADATA, since separators take up indices of their own.
func _fill_effect_picker(picker: OptionButton) -> void:
	picker.add_separator("FUNSCRIPT")
	for kind: String in STROKE_EFFECT_KINDS:
		picker.add_item(_effect_label(kind))
		picker.set_item_metadata(picker.item_count - 1, kind)

	var audio: Array[String] = []
	var visual: Array[String] = []
	for entry: Dictionary in JourneyData.SENSORY_CATALOG:
		var kind: String = str(entry.get("kind", ""))
		if JourneyData.AUDIO_SENSORY_KINDS.has(kind):
			audio.append(kind)
		else:
			visual.append(kind)

	if not audio.is_empty():
		picker.add_separator("AUDIO")
		for kind: String in audio:
			picker.add_item(_effect_label(kind))
			picker.set_item_metadata(picker.item_count - 1, kind)
	if not visual.is_empty():
		picker.add_separator("VISUAL")
		for kind: String in visual:
			picker.add_item(_effect_label(kind))
			picker.set_item_metadata(picker.item_count - 1, kind)
	# A separator cannot be chosen, so start on the first real entry.
	picker.selected = 1


static func _effect_label(kind: String) -> String:
	for entry: Dictionary in JourneyData.SENSORY_CATALOG:
		if str(entry.get("kind", "")) == kind:
			return str(entry.get("name", kind)).to_upper()
	return kind.to_upper()


# A new effect's starting parameters. Mirrors the boss-modifier defaults so an effect authored here
# behaves like the same effect authored on the round itself.
static func _default_effect(kind: String) -> Dictionary:
	match kind:
		"scale":
			return {"kind": "scale", "factor": 1.2}
		"clamp":
			return {"kind": "clamp", "min": 0, "max": 50}
		"score_multiplier":
			return {"kind": "score_multiplier", "factor": 2.0}
	# Sensory kinds carry an intensity when their catalogue entry defines a default for one.
	for entry: Dictionary in JourneyData.SENSORY_CATALOG:
		if str(entry.get("kind", "")) == kind and entry.has("idef"):
			return {"kind": kind, "intensity": float(entry["idef"])}
	return {"kind": kind}


# One effect in the bundle: its name, whatever parameters that kind takes, and a remove button.
func _make_effect_row(event: Dictionary, index: int) -> Control:
	var effect: Dictionary = (event["effects"] as Array)[index]
	var kind: String = str(effect.get("kind", ""))

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_label: Label = Label.new()
	name_label.text = _effect_label(kind)
	name_label.custom_minimum_size = Vector2(120, 0)
	UITheme.style_label(name_label, UITheme.WHITE_SOFT, 11, true)
	row.add_child(name_label)

	# Parameter fields, by kind. Anything without parameters (reverse, block, blackout) shows none.
	if effect.has("factor"):
		row.add_child(_labeled("Factor", _make_float_spin(effect, "factor", 0.1, 5.0, 0.1)))
	if effect.has("min"):
		row.add_child(_labeled("Min", _make_float_spin(effect, "min", 0.0, 100.0, 1.0)))
	if effect.has("max"):
		row.add_child(_labeled("Max", _make_float_spin(effect, "max", 0.0, 100.0, 1.0)))
	if effect.has("intensity"):
		# Label beside the spin box rather than stacked above it: the row is already tight, and a
		# stacked caption made the whole strip twice as tall for one number.
		var intensity_label: Label = Label.new()
		intensity_label.text = "INTENSITY"
		UITheme.style_label(intensity_label, UITheme.DARK_TEXT, 10, true)
		row.add_child(intensity_label)
		row.add_child(_make_float_spin(effect, "intensity", 0.0, 1.0, 0.05))

	var remove: Button = Button.new()
	remove.text = "✕"
	UITheme.style_button_subtle(remove, UITheme.DANGER, 8, 4, 11)
	remove.pressed.connect(
		func() -> void:
			_snapshot("delete-effect")
			(event["effects"] as Array).remove_at(index)
			_refresh()
	)
	row.add_child(remove)
	return row


func _make_float_spin(
	target: Dictionary, key: String, low: float, high: float, step: float
) -> SpinBox:
	var spin: SpinBox = SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.value = float(target.get(key, low))
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:" + key)
			target[key] = value
			_refresh_derived()
	)
	return spin


# The light half of _refresh(): re-draw everything that DERIVES from the timeline, without
# re-normalizing or rebuilding the inspector. Tuning an effect's factor has to redraw its curve, but a
# full refresh would replace the dictionaries the open fields are bound to and yank focus out of the
# spin box being dragged.
func _refresh_derived() -> void:
	# The preview settles its branch picks FIRST. The lane rows and the reference overlays are both
	# derived from those picks, so deriving them beforehand would draw the previous roll.
	_rebuild_preview()
	_timeline_view.set_value_labels(_value_labels())
	_timeline_view.set_events(_timed_events(), _timeline["phases"], _segments())
	_refresh_issues()


# Re-arms the preview against the edited timeline and lands it back on the playhead.
func _rebuild_preview() -> void:
	_stage.rebuild(_timeline, _full_ms, _playhead_ms)
	if is_instance_valid(_cycle_button):
		_cycle_button.visible = _stage.has_choices()
	if is_instance_valid(_sim_row):
		_sim_row.visible = _encounter_has_rules()
	_sync_branch_view()


# Pushes the preview's branch picks at everything that shows them. Fed from the stage rather than
# recomputed here, so the faded rows and the reference curves are always the branches the preview
# actually chose — a second calculation could quietly disagree with the picture.
func _sync_branch_view() -> void:
	_timeline_view.set_dormant_tags(_stage.dormant_tags())
	_timeline_view.set_win_point(RoundTimeline.win_jump_at_ms(_timeline, _full_ms))
	_refresh_overlays()


# On import, a media event takes the source's OWN length: an attack block that has to be hand-matched to
# its funscript is busywork, and one that silently does not match is worse. The author can still trim it
# afterwards by dragging the block's edge.
func _adopt_media_length(event: Dictionary, length_ms: int) -> void:
	if length_ms <= 0:
		return
	event["duration_ms"] = length_ms
	event["trim"] = {"in_ms": 0, "out_ms": length_ms}


static func _funscript_length_ms(path: String) -> int:
	return int(JourneyData.read_funscript_stats(path).get("length_ms", 0))


# An audio clip's length, for the same auto-fit. Loaded rather than probed: Godot decodes ogg/mp3/wav
# natively, so this costs a file read and no subprocess.
static func _audio_length_ms(path: String) -> int:
	var stream: AudioStream = JourneyAudio.load_from_file(path)
	return 0 if stream == null else int(stream.get_length() * 1000.0)


func _make_ms_spin(value: int) -> SpinBox:
	var spin: SpinBox = SpinBox.new()
	spin.min_value = 0
	spin.max_value = 1000000
	spin.step = 100
	spin.value = value
	UITheme.style_spin_box(spin)
	return spin


func _labeled(text: String, control: Control) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var label: Label = Label.new()
	label.text = text
	UITheme.style_label(label, UITheme.DARK_TEXT, 10, true)
	box.add_child(label)
	box.add_child(control)
	return box
