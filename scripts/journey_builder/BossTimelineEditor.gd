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
const INSPECTOR_WIDTH: int = 400

# Side of the subtitle colour swatch. Square reads as a colour chip; the default button shape stretched
# to the row height and read as an oddly thin control.
const SWATCH_SIZE: int = 34

const UNDO_DEPTH: int = 60

# Repeated edits of the same KIND within this window collapse into one undo step, so dragging a block
# or scrubbing a spin box is a single undo rather than a hundred.
const COALESCE_MS: int = 500

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
var _scrollbar: HScrollBar = null
var _inspector: VBoxContainer = null
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

	# Stage and inspector share a row: the preview wants the height, and a wide modal has the width to
	# spare — stacking them would push the timeline off the bottom.
	column.add_child(_build_stage_row())
	# Transport and the Boss Kit share the strip between the stage and the lanes: both are things you
	# reach for WHILE looking at the timeline, so they sit next to it rather than up at the title.
	column.add_child(_build_transport_row())
	_build_timeline_row(column)
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


# The preview stage beside the inspector. Everything about the picture — the video, the cue layer, the
# audio, the sensory engine, the health bar and the scheduler driving them — lives in BossPreviewStage.
# This only places it and listens for the two things the rest of the modal needs to know.
func _build_stage_row() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 12)

	_stage = BossPreviewStage.new()
	row.add_child(_stage)
	_stage.build(_characters)
	_stage.deselect_requested.connect(func() -> void: _select(""))
	_stage.advanced.connect(_on_stage_advanced)

	row.add_child(_build_inspector_row())
	return row


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
	phase_button.pressed.connect(func() -> void: _add_phase())
	_make_kit_draggable(phase_button, "phase", "")
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
		"phase":
			_add_phase(at_ms)


func _build_timeline_row(column: VBoxContainer) -> void:
	_timeline_view = BossTimeline.new()
	_timeline_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline_view.event_selected.connect(_on_event_selected)
	_timeline_view.event_moved.connect(_on_event_moved)
	_timeline_view.event_resized.connect(_on_event_resized)
	_timeline_view.playhead_scrubbed.connect(_on_playhead_scrubbed)
	_timeline_view.view_changed.connect(_on_view_changed)
	_timeline_view.kit_dropped.connect(_on_kit_dropped)
	_timeline_view.phase_moved.connect(_on_phase_moved)
	column.add_child(_timeline_view)

	# A sibling scrollbar pans the zoomed view — the same pairing the override editor uses, so the
	# wheel is free to zoom without stealing panning.
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
	_timeline_view.set_events(_timed_events(), _timeline["phases"])
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
	for event: Dictionary in _timeline["events"] as Array:
		var at: int = RoundTimeline.resolve_at_ms(event, _full_ms)
		if at == RoundTimeline.NO_TIME:
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
		if str(event.get("on", RoundTimeline.ON_ALWAYS)) != RoundTimeline.ON_DEFEAT:
			out.append(event)
	return out


func _defeat_events() -> Array:
	var out: Array = []
	for event: Dictionary in _timeline["events"] as Array:
		if str(event.get("on", RoundTimeline.ON_ALWAYS)) == RoundTimeline.ON_DEFEAT:
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
	# An effect is meaningless as an instant, so it arrives as a window; the rest default to one-shots.
	if track == RoundTimeline.TRACK_EFFECT:
		event["duration_ms"] = NEW_WINDOW_MS
	(_timeline["events"] as Array).append(event)
	_selected_id = str(event["id"])
	_timeline_view.set_selected(_selected_id)
	_refresh()


func _add_phase(at_ms: int = -1) -> void:
	_snapshot("add")
	var phases: Array = _timeline["phases"]
	(
		phases
		. append(
			{
				"id": RoundTimeline.new_event_id("phs"),
				"name": "PHASE %d" % (phases.size() + 1),
				"at_ms": _playhead_ms,
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


# A phase marker was dragged along its band.
func _on_phase_moved(id: String, at_ms: int) -> void:
	_snapshot("move:" + id)
	for phase: Dictionary in _timeline["phases"] as Array:
		if str(phase.get("id", "")) == id:
			phase["at_ms"] = maxi(0, at_ms)
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
	if str(event.get("on", RoundTimeline.ON_ALWAYS)) == RoundTimeline.ON_DEFEAT:
		title.text += "  ·  ON DEFEAT"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(title, BossTimeline.track_color(str(event.get("track", ""))), 14, true)
	header.add_child(title)
	var delete: Button = Button.new()
	delete.text = "✕ DELETE"
	UITheme.style_button_subtle(delete, UITheme.DANGER, 10, 6, 11)
	delete.pressed.connect(_delete_selected)
	header.add_child(delete)
	_inspector.add_child(header)

	if str(event.get("on", RoundTimeline.ON_ALWAYS)) == RoundTimeline.ON_DEFEAT:
		var note: Label = Label.new()
		note.text = "Plays when the player gives in — not at a time on the timeline."
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(note, UITheme.AMBER, 10)
		_inspector.add_child(note)
	else:
		_add_time_fields(event)
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
		RoundTimeline.TRACK_AUDIO:
			_add_file_field(
				event,
				"clip",
				"Audio clip",
				JourneyAudio.AUDIO_EXTENSIONS,
				func(path: String) -> void: _adopt_media_length(event, _audio_length_ms(path))
			)
			_add_fade_fields(event, "fade_in_ms", "fade_out_ms", "Audio ease in / out (ms)")
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

	var ticks: CheckButton = CheckButton.new()
	ticks.text = "SHOW PHASE MARKS ON THE BAR"
	ticks.tooltip_text = (
		UITheme
		. wrap_tip(
			"A division mark on the health bar for each phase, so the player can see another stage is coming."
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

	_build_outcomes_section()

	var hint: Label = Label.new()
	hint.text = "Select a block to edit it, or add one from the row above."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(hint, UITheme.DARK_TEXT, 11)
	_inspector.add_child(hint)


# The DEFEAT events. They live here rather than on a lane because they have no place on the clock: they
# play when the player gives in (the FINISH button), whenever that happens — so a position would be a lie.
# Everything else about it is an ordinary cast or audio event.
func _build_outcomes_section() -> void:
	var separator: HSeparator = HSeparator.new()
	_inspector.add_child(separator)

	var title: Label = Label.new()
	title.text = "IF THE PLAYER GIVES IN"
	UITheme.style_label(title, UITheme.AMBER, 12, true)
	_inspector.add_child(title)

	var blurb: Label = Label.new()
	blurb.text = (
		"Played when the player presses FINISH mid-round, instead of the ending you placed on the "
		+ "timeline."
	)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(blurb, UITheme.DARK_TEXT, 10)
	_inspector.add_child(blurb)

	if not _allow_finish:
		_inspector.add_child(_make_finish_warning())

	for defeat_event: Dictionary in _defeat_events():
		_inspector.add_child(_make_outcome_row(defeat_event))

	var hold: SpinBox = _make_ms_spin(
		int(_timeline.get("defeat_hold_ms", RoundTimeline.DEFAULT_DEFEAT_HOLD_MS))
	)
	hold.value_changed.connect(
		func(value: float) -> void:
			_snapshot("field:defeat_hold_ms")
			_timeline["defeat_hold_ms"] = int(value)
	)
	_inspector.add_child(_labeled("Hold before the round ends (ms)", hold))

	var add_row: HBoxContainer = HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 8)
	for track: String in [RoundTimeline.TRACK_CAST, RoundTimeline.TRACK_AUDIO]:
		var button: Button = Button.new()
		button.text = "＋ %s" % track.to_upper()
		UITheme.style_button_subtle(button, BossTimeline.track_color(track), 10, 6, 11)
		button.pressed.connect(func() -> void: _add_defeat_event(track))
		add_row.add_child(button)
	_inspector.add_child(add_row)


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
func _make_outcome_row(defeat_event: Dictionary) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var open: Button = Button.new()
	var label: String = str(defeat_event.get("text", ""))
	if label == "":
		label = str(defeat_event.get("clip", "")).get_file()
	if label == "":
		label = str(defeat_event.get("track", "")).to_upper()
	open.text = "✎  " + label
	open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open.alignment = HORIZONTAL_ALIGNMENT_LEFT
	UITheme.style_button_subtle(
		open, BossTimeline.track_color(str(defeat_event.get("track", ""))), 10, 6, 11
	)
	open.pressed.connect(func() -> void: _select(str(defeat_event.get("id", ""))))
	row.add_child(open)

	var remove: Button = Button.new()
	remove.text = "✕"
	UITheme.style_button_subtle(remove, UITheme.DANGER, 8, 4, 11)
	remove.pressed.connect(
		func() -> void:
			_snapshot("delete")
			var kept: Array = []
			for event: Dictionary in _timeline["events"] as Array:
				if str(event.get("id", "")) != str(defeat_event.get("id", "")):
					kept.append(event)
			_timeline["events"] = kept
			_refresh()
	)
	row.add_child(remove)
	return row


# Adds a defeat event. `at_ms` is fixed at 0 and never shown — it plays on the bail-out, so the
# number would only invite an author to tune something that has no effect.
func _add_defeat_event(track: String) -> void:
	_snapshot("add")
	var event: Dictionary = {
		"id": RoundTimeline.new_event_id(),
		"track": track,
		"at_ms": 0,
		"on": RoundTimeline.ON_DEFEAT,
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


# The phase marker editor: rename, retime, toggle its banner, delete.
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

	var at_spin: SpinBox = _make_ms_spin(int(phase.get("at_ms", 0)))
	at_spin.value_changed.connect(
		func(value: float) -> void:
			phase["at_ms"] = int(value)
			_refresh()
	)
	_inspector.add_child(_labeled("Starts (ms)", at_spin))

	var banner: CheckButton = CheckButton.new()
	banner.text = "SHOW BANNER"
	banner.button_pressed = bool(phase.get("banner", false))
	banner.toggled.connect(
		func(pressed: bool) -> void:
			phase["banner"] = pressed
			_refresh()
	)
	_inspector.add_child(banner)


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
	_timeline_view.set_events(_timed_events(), _timeline["phases"])
	_refresh_overlays()
	_refresh_issues()
	_rebuild_preview()


# Re-arms the preview against the edited timeline and lands it back on the playhead.
func _rebuild_preview() -> void:
	_stage.rebuild(_timeline, _full_ms, _playhead_ms)


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
