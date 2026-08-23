class_name FunscriptPreview
extends Control

# ---------------------------------------------------------------------------
# FunscriptPreview — THE in-builder clip editor: preview, cut and tune in one overlay.
#
# Plots the raw stroke curve plus (when the round has boss/curse/boon modifiers) the
# curve they produce, with tunable magnitudes draggable in the TUNE strip. Below that,
# the segment timeline that authors the round's cut.
#
# ONE VIEW, deliberately. Both BuilderSidePanel entry points route through
# _open_funscript_editor and pass every argument; a call site that omits half is how
# authors ended up cutting against a curve that wasn't the one that plays.
#
# Graph and modifier overlay work on any codec (funscripts are tiny JSON); the video
# pane only appears for H.264, EIRTeam's decode limit. Video clock ↔ playhead stay in
# lockstep both ways. The overlay frees itself on close.
# ---------------------------------------------------------------------------

var _graph: _Graph = null
var _modifiers: Array = []  # effect-shaped dicts (boss modifiers / curse / boon)
var _mod_label: String = "Boss Modifiers"  # what the modifiers are called for this round
var _show_modifiers: bool = true
var _caption: Label = null
# Live-tuning callback: func(ref_name, key, value) — set when the caller wants the preview's
# stroke-magnitude controls editable (effect rounds). Persists each change back to the round.
var _on_tune: Callable = Callable()

# Video preview (H.264 only — EIRTeam's decode limit). Stays hidden / graph-only
# when the source can't be decoded.
var _video: VideoStreamPlayer = null
var _video_pane: Control = null
# Draggable divider between the video pane and the curve graph. The split fraction persists
# (SettingsService.get/set_preview_video_split), so each author's preferred size sticks.
var _video_split: VSplitContainer = null
# Draggable divider between the left column (video + graph + playback controls) and the right
# column (the segment timeline). Built only when editing; persists its own fraction.
var _columns_split: HSplitContainer = null
var _video_aspect: AspectRatioContainer = null
var _aspect_set: bool = false
var _video_ok: bool = false
var _play_btn: Button = null
# Audio starts muted — every open is a full editor now, and surprise audio is a bad
# default for this app. One click to enable.
var _audio_btn: Button = null
var _audio_on: bool = false

# ── The segment timeline ────────────────────────────────────────────────────
# `_segments` is the live edit: ordered [{in_ms, out_ms}, …] played back to back. A repeat is
# a DUPLICATED ROW, not a count — that's what makes duplicate, reorder and loop one operation.
# A valid `_on_segments_applied` is what enables editing; without one this is a read-only look.
var _edit_mode: bool = false
var _segments: Array = []
var _on_segments_applied: Callable = Callable()
var _sel_row: int = -1  # selected row, -1 = none
var _rows_box: VBoxContainer = null
var _seg_label: Label = null
var _repeat_spin: SpinBox = null

# The ⟦IN / OUT⟧ marks, before + ADD commits them as a row. -1 = unset.
var _mark_in: int = -1
var _mark_out: int = -1

# Undo/redo, local to this overlay and dead when it closes — segments aren't committed until
# APPLY, so they don't belong on the builder's graph snapshot stack. Entries are tiny.
var _undo: Array = []
var _redo: Array = []

# EDL playback walks the segments in order, seeking at each join. _edl_idx = the segment on
# screen, -1 when not walking.
var _edl_btn: Button = null
var _edl_playing: bool = false
var _edl_idx: int = -1

# ── Live sensory preview ────────────────────────────────────────────────────
# The same SensoryFX the runtime uses, scoped to the video pane instead of the screen, so the
# author sees and hears what a sensory effect does while dragging its intensity. Rolls are the
# round's ticked SENSORY_CATALOG entries; `_on_sensory_tune(name, intensity)` persists.
# Applied UNSCALED by the player's comfort setting — see SensoryFX.apply.
var _sensory: SensoryFX = null
var _sensory_rolls: Array = []
var _sensory_intensity: Dictionary = {}  # catalog name → 0–1, the live edit
var _on_sensory_tune: Callable = Callable()


# Builds and shows the overlay over `parent`. `modifiers` are stroke-affecting effect dicts
# (each {kind, factor?/min?/max?}); [] for none. `mod_label` names them ("Boss Modifiers" /
# "Curse effects"). `video_path` may be "" or a non-decodable codec — both fall back to
# graph-only. A valid `on_segments_applied` enables timeline editing.
func open(
	parent: Control,
	funscript_path: String,
	video_path: String,
	modifiers: Array,
	round_name: String,
	mod_label: String = "Boss Modifiers",
	segments: Array = [],
	on_segments_applied: Callable = Callable(),
	on_tune: Callable = Callable(),
	sensory_rolls: Array = [],
	sensory_intensity: Dictionary = {},
	on_sensory_tune: Callable = Callable()
) -> void:
	_modifiers = modifiers
	_mod_label = mod_label
	_on_tune = on_tune
	_sensory_rolls = sensory_rolls
	_sensory_intensity = sensory_intensity.duplicate()
	_on_sensory_tune = on_sensory_tune
	_edit_mode = on_segments_applied.is_valid()
	_segments = segments.duplicate(true)  # edit a copy; APPLY is what commits
	_on_segments_applied = on_segments_applied
	_build_ui(round_name)
	parent.add_child(self)
	move_to_front()  # sit above the builder's graph / side panel siblings

	var raw: Array = JourneyData.read_funscript_actions(funscript_path)
	_graph.set_raw(raw)
	_refresh_modified()
	_setup_video(video_path)
	if _edit_mode:
		_rebuild_rows()
		_apply_saved_columns_split()  # place the column divider at the author's saved width


func _build_ui(round_name: String) -> void:
	# Fill the parent and capture input so the builder behind is inert.
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP

	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.72)
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var panel: PanelContainer = PanelContainer.new()
	# Near full-screen: this overlay carries the video, the graph, the TUNE strip, the sensory
	# sliders and the segment timeline. Tight top/bottom margins give the video pane more height.
	panel.anchor_left = 0.03
	panel.anchor_right = 0.97
	panel.anchor_top = 0.025
	panel.anchor_bottom = 0.975
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG_DEEP
	panel_style.border_color = UITheme.PURPLE_MID
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(6)
	panel_style.set_content_margin_all(18)
	panel_style.content_margin_bottom = 8  # keep the button bar flush with the bottom edge
	panel.add_theme_stylebox_override("panel", panel_style)
	add_child(panel)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	panel.add_child(col)

	# Header: title + close.
	var header: HBoxContainer = HBoxContainer.new()
	var title: Label = Label.new()
	title.text = (
		"▶  FUNSCRIPT PREVIEW" + ("  —  " + round_name.to_upper() if round_name != "" else "")
	)
	title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn: Button = UITheme.make_icon_btn("✕ CLOSE", false, UITheme.MAGENTA)
	close_btn.pressed.connect(_close)
	header.add_child(close_btn)
	col.add_child(header)

	# Body: the video, curve graph and playback controls fill the LEFT column; when editing, the
	# segment timeline gets its own tall column on the RIGHT, split by a draggable, remembered
	# divider. A view-only open has no timeline, so the left content takes the whole width instead.
	var left_col: VBoxContainer = _build_left_column()
	if not _edit_mode:
		left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
		col.add_child(left_col)
		return

	var right_col: Control = _build_timeline_column()
	_columns_split = HSplitContainer.new()
	_columns_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_columns_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left_frac: float = SettingsService.get_preview_columns_split()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_stretch_ratio = left_frac
	left_col.custom_minimum_size = Vector2(360, 0)  # keep the video/graph usable when dragged narrow
	right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_col.size_flags_stretch_ratio = 1.0 - left_frac
	right_col.custom_minimum_size = Vector2(240, 0)  # keep the timeline rows readable
	_columns_split.add_child(left_col)
	_columns_split.add_child(right_col)
	_columns_split.dragged.connect(_on_columns_split_dragged)
	col.add_child(_columns_split)


# The LEFT column: the video pane and the curve graph (a draggable divider between them), the
# optional TUNE / sensory strips, and the playback / zoom bar that drives them. The segment-editing
# controls live with the timeline in the right column instead.
func _build_left_column() -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)

	# Video pane — hidden until a decodable video confirms it can play (see _setup_video). When
	# hidden the split skips it and the graph gets the room. An AspectRatioContainer letterboxes the
	# video inside the black pane so it isn't stretched; its ratio is set from the real size once known.
	var video_pane: PanelContainer = PanelContainer.new()
	var vp_style: StyleBoxFlat = StyleBoxFlat.new()
	vp_style.bg_color = Color(0, 0, 0, 1)
	video_pane.add_theme_stylebox_override("panel", vp_style)
	video_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	video_pane.clip_contents = true
	video_pane.visible = false
	_video_aspect = AspectRatioContainer.new()
	_video_aspect.ratio = 16.0 / 9.0
	_video_aspect.stretch_mode = AspectRatioContainer.STRETCH_FIT
	video_pane.add_child(_video_aspect)
	_video = VideoStreamPlayer.new()
	_video.expand = true
	_video.volume_db = -80.0  # start silent; _apply_audio sets the real state once confirmed
	_video_aspect.add_child(_video)
	_video_pane = video_pane

	# The graph fills the remaining space and scrolls horizontally — the curve is drawn at a fixed
	# time scale (px/sec) rather than squashed to fit, so strokes stay legible on long scripts.
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph = _Graph.new()
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL  # fill the viewport height
	_graph.time_label_format = func(ms: float) -> String: return _format_time(ms)
	scroll.add_child(_graph)
	# Redraw on scroll so the floating Y-axis labels track the viewport's left edge.
	scroll.get_h_scroll_bar().value_changed.connect(func(_v: float) -> void: _graph.queue_redraw())

	# The video pane and the curve graph share the column's flexible height through a draggable
	# divider, so authors can size the video (or the curve) to taste. Seeded from the saved fraction
	# via the two children's stretch ratios (split_offset stays 0) and re-saved on drag; the graph
	# keeps its own 240px minimum, so the divider can never hide it entirely.
	_video_split = VSplitContainer.new()
	_video_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_video_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var video_frac: float = SettingsService.get_preview_video_split()
	video_pane.size_flags_stretch_ratio = video_frac
	scroll.size_flags_stretch_ratio = 1.0 - video_frac
	_video_split.add_child(video_pane)
	_video_split.add_child(scroll)
	_video_split.dragged.connect(_on_video_split_dragged)
	box.add_child(_video_split)

	# Scrubbing the graph seeks the video; playhead and video clock stay in lockstep (video →
	# playhead in _process, playhead → video here).
	_graph.scrubbed.connect(_on_scrubbed)

	# Live stroke-magnitude tuning (effect rounds): sliders that rewrite the modifier curve as you
	# drag and persist back to the round. Only when the caller opted in.
	if _on_tune.is_valid():
		var strip: Control = _build_tuning_strip()
		if strip != null:
			box.add_child(strip)

	var sensory_strip: Control = _build_sensory_strip()
	if sensory_strip != null:
		box.add_child(sensory_strip)

	box.add_child(_build_playback_bar())
	return box


# The playback / view controls under the graph: play/pause, audio, zoom, and (when the round has
# modifiers) the show-modifiers toggle plus the modifier caption. Segment editing lives with the
# timeline in the right column.
func _build_playback_bar() -> Control:
	var bar: HBoxContainer = HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)

	# Play / pause (disabled until a video confirms it can play).
	_play_btn = UITheme.make_icon_btn("▶ PLAY", true, UITheme.SUCCESS)
	_play_btn.pressed.connect(_toggle_play)
	bar.add_child(_play_btn)

	# Audio toggle (also disabled until a video confirms). Starts OFF regardless of mode: now that
	# every open is a full editor, defaulting it on would mean any preview click suddenly plays
	# audio — a bad surprise for this app's content. Cutting by ear is one click away.
	_audio_on = false
	_audio_btn = UITheme.make_icon_btn("🔊", true, UITheme.PURPLE_BRIGHT)
	_audio_btn.tooltip_text = UITheme.wrap_tip("Toggle preview audio")
	_audio_btn.pressed.connect(
		func() -> void:
			_audio_on = not _audio_on
			_apply_audio()
	)
	bar.add_child(_audio_btn)

	# Zoom — adjust the graph's horizontal time scale.
	var zoom_out: Button = UITheme.make_icon_btn("ZOOM −", false, UITheme.PURPLE_BRIGHT)
	zoom_out.tooltip_text = UITheme.wrap_tip("Zoom out (show more time)")
	zoom_out.pressed.connect(func() -> void: _graph.zoom_by(0.8))
	bar.add_child(zoom_out)
	var zoom_in: Button = UITheme.make_icon_btn("ZOOM +", false, UITheme.PURPLE_BRIGHT)
	zoom_in.tooltip_text = UITheme.wrap_tip("Zoom in (show less time, more detail)")
	zoom_in.pressed.connect(func() -> void: _graph.zoom_by(1.25))
	bar.add_child(zoom_in)

	if not _modifiers.is_empty():
		var toggle: CheckButton = CheckButton.new()
		toggle.text = "SHOW %s" % _mod_label.to_upper()
		toggle.button_pressed = true
		toggle.add_theme_font_size_override("font_size", 12)
		toggle.toggled.connect(
			func(on: bool) -> void:
				_show_modifiers = on
				_refresh_modified()
		)
		bar.add_child(toggle)

	_caption = Label.new()
	_caption.add_theme_font_size_override("font_size", 11)
	_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bar.add_child(_caption)
	return bar


# The RIGHT column (editing only): the segment timeline. A build toolbar (mark IN/OUT, add, repeat,
# clear) on top, the full-height scrolling list of segment rows in the middle, and PLAY TIMELINE +
# APPLY along the bottom. In its own tall column, a long cut list is easy to see and reorder — the
# whole point of the two-column layout.
func _build_timeline_column() -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var title: Label = Label.new()
	title.text = "TIMELINE"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var hint: Label = Label.new()
	hint.text = "Ctrl+Z / Ctrl+Y"
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	head.add_child(hint)
	box.add_child(head)

	box.add_child(_build_segment_toolbar())

	# The scrolling list of rows — expands to fill the column so long timelines stay visible.
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 2)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)
	box.add_child(scroll)

	# Bottom action row: play the assembled cut, and APPLY it to the round.
	var actions: HBoxContainer = HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	# Plays the assembled cut instead of the raw source. The bake concatenates pre-encoded segments
	# and is seamless, so a hitch seen HERE is a preview artifact the file won't have.
	_edl_btn = UITheme.make_icon_btn("▶ PLAY TIMELINE", false, UITheme.CYAN)
	_edl_btn.tooltip_text = UITheme.wrap_tip(
		"Play the segments in order (the preview seeks at each join)"
	)
	_edl_btn.pressed.connect(_toggle_edl_playback)
	actions.add_child(_edl_btn)
	_seg_label = Label.new()
	_seg_label.add_theme_font_size_override("font_size", 11)
	_seg_label.add_theme_color_override("font_color", UITheme.TOXIC_GREEN)
	_seg_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(_seg_label)
	var apply: Button = UITheme.make_icon_btn("✔ APPLY", false, UITheme.SUCCESS)
	apply.tooltip_text = UITheme.wrap_tip(
		"Write this timeline to the round (baked at the next save)"
	)
	apply.pressed.connect(
		func() -> void:
			_on_segments_applied.call(_segments.duplicate(true))  # hand over a copy, not our live list
			_close()
	)
	actions.add_child(apply)
	box.add_child(actions)
	return box


# The segment build toolbar: mark a window with the playhead, add it as a row, repeat or clear.
# These build the timeline, so they live in the timeline column. An HFlowContainer so the buttons
# wrap to a second line when the column is dragged narrow.
func _build_segment_toolbar() -> Control:
	var bar: HFlowContainer = HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 6)
	bar.add_theme_constant_override("v_separation", 4)

	var set_in: Button = UITheme.make_icon_btn("⟦ IN", false, UITheme.TOXIC_GREEN)
	set_in.tooltip_text = UITheme.wrap_tip("Mark the window start at the playhead")
	set_in.pressed.connect(func() -> void: _set_mark(true))
	bar.add_child(set_in)
	var set_out: Button = UITheme.make_icon_btn("OUT ⟧", false, UITheme.DANGER)
	set_out.tooltip_text = UITheme.wrap_tip("Mark the window end at the playhead")
	set_out.pressed.connect(func() -> void: _set_mark(false))
	bar.add_child(set_out)
	var add_btn: Button = UITheme.make_icon_btn("+ ADD", false, UITheme.CYAN)
	add_btn.tooltip_text = UITheme.wrap_tip("Add the marked window to the timeline as a new row")
	add_btn.pressed.connect(_add_pending_segment)
	bar.add_child(add_btn)
	var drop_marks: Button = UITheme.make_icon_btn("✕ MARKS", false, UITheme.AMBER)
	drop_marks.tooltip_text = UITheme.wrap_tip("Discard the ⟦IN/OUT⟧ marks (keeps the timeline)")
	drop_marks.pressed.connect(
		func() -> void:
			_mark_in = -1
			_mark_out = -1
			_rebuild_rows()
	)
	bar.add_child(drop_marks)

	# Repeat: inserts N copies of the selected row. Storage is expanded rows, but nobody clicks
	# duplicate thirty times — so the AFFORDANCE is a count even though the model has none.
	# Deliberately uncapped; a long bake is the author's call.
	_repeat_spin = SpinBox.new()
	_repeat_spin.min_value = 2
	_repeat_spin.max_value = 999
	_repeat_spin.value = 4
	_repeat_spin.tooltip_text = UITheme.wrap_tip("How many total passes the selected row becomes")
	UITheme.style_spin_box(_repeat_spin)
	bar.add_child(_repeat_spin)
	var rep_btn: Button = UITheme.make_icon_btn("⧉ REPEAT", false, UITheme.PURPLE_BRIGHT)
	rep_btn.tooltip_text = UITheme.wrap_tip("Repeat the selected row this many times (adds rows)")
	rep_btn.pressed.connect(_repeat_selected)
	bar.add_child(rep_btn)

	var clear_btn: Button = UITheme.make_icon_btn("✕ CLEAR ALL", false, UITheme.MAGENTA)
	clear_btn.tooltip_text = UITheme.wrap_tip(
		"Remove EVERY segment so the whole clip plays untouched (Ctrl+Z undoes it)"
	)
	clear_btn.pressed.connect(
		func() -> void:
			_push_undo()
			_segments.clear()
			_sel_row = -1
			_rebuild_rows()
	)
	bar.add_child(clear_btn)
	return bar


# Places the divider at the saved fraction once the video pane is visible and the split has a real
# height. The stretch ratios above are only a rough seed — the graph's minimum height skews the
# ratio→fraction mapping — so we correct with split_offset (a delta from wherever it sits now) to
# land the exact saved fraction. Clamped by the children's min sizes, same as a manual drag.
func _apply_saved_split() -> void:
	if _video_split == null or not _video_pane.visible:
		return
	await get_tree().process_frame  # let the split lay out with the video visible
	if not is_inside_tree() or _video_split.size.y <= 0.0:
		return
	var target_h: float = SettingsService.get_preview_video_split() * _video_split.size.y
	_video_split.split_offset += int(round(target_h - _video_pane.size.y))


# The author dragged the video/graph divider — persist the new split as a fraction of the
# splitter's height. A fraction (not the raw pixel offset the signal hands us) stays correct when
# the modal is later opened at a different window size.
func _on_video_split_dragged(_offset: int) -> void:
	if _video_split == null or _video_split.size.y <= 0.0:
		return
	SettingsService.set_preview_video_split(_video_pane.size.y / _video_split.size.y)
	SettingsService.save()


# Same persistence approach as the video/graph split, but horizontal: the saved fraction is the
# LEFT column's share of the width. Corrected with split_offset after layout so it lands exactly.
func _apply_saved_columns_split() -> void:
	if _columns_split == null:
		return
	await get_tree().process_frame  # let the columns lay out
	if not is_inside_tree() or _columns_split.size.x <= 0.0:
		return
	var left: Control = _columns_split.get_child(0)
	var target_w: float = SettingsService.get_preview_columns_split() * _columns_split.size.x
	_columns_split.split_offset += int(round(target_w - left.size.x))


func _on_columns_split_dragged(_offset: int) -> void:
	if _columns_split == null or _columns_split.size.x <= 0.0:
		return
	var left: Control = _columns_split.get_child(0)
	SettingsService.set_preview_columns_split(left.size.x / _columns_split.size.x)
	SettingsService.save()


# One slider per tunable sensory effect on this round, applied live to the video pane as you
# drag. Returns null when the round has no sensory effects (or none with an intensity — Blinded
# and Silence are binary, so they preview but can't be tuned).
func _build_sensory_strip() -> Control:
	var tunable: Array = []
	for roll: Dictionary in _sensory_rolls:
		if roll.has("imin") and roll.has("imax"):
			tunable.append(roll)
	if tunable.is_empty():
		return null

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var lead: Label = Label.new()
	lead.text = "SENSORY  —  previewed at author strength, before the player's comfort setting"
	lead.add_theme_font_size_override("font_size", 11)
	lead.add_theme_color_override("font_color", UITheme.SEPARATOR)
	box.add_child(lead)

	var rows: HBoxContainer = HBoxContainer.new()
	rows.add_theme_constant_override("separation", 16)
	for roll: Dictionary in tunable:
		rows.add_child(_sensory_slider_row(roll))
	box.add_child(rows)
	return box


func _sensory_slider_row(roll: Dictionary) -> Control:
	var nm: String = str(roll.get("name", ""))
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var lbl: Label = Label.new()
	lbl.text = nm.to_upper()
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", UITheme.CYAN)
	row.add_child(lbl)

	var pct: float = float(_sensory_intensity.get(nm, roll.get("idef", 0.5))) * 100.0
	var value_lbl: Label = Label.new()
	value_lbl.text = "%d%%" % roundi(pct)
	value_lbl.add_theme_font_size_override("font_size", 11)
	value_lbl.custom_minimum_size = Vector2(38, 0)

	var slider: HSlider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.custom_minimum_size = Vector2(120, 0)
	slider.set_value_no_signal(pct)
	slider.value_changed.connect(
		func(v: float) -> void:
			value_lbl.text = "%d%%" % roundi(v)
			_sensory_intensity[nm] = v / 100.0
			_refresh_sensory()
			if _on_sensory_tune.is_valid():
				_on_sensory_tune.call(nm, v / 100.0)
	)
	row.add_child(slider)
	row.add_child(value_lbl)
	return row


# Recomputes (or clears) the modifier-applied curve and updates the caption.
func _refresh_modified() -> void:
	if _modifiers.is_empty():
		_graph.set_modified([], false)
		_caption.text = "No %s on this round — showing the raw script." % _mod_label.to_lower()
		_caption.add_theme_color_override("font_color", UITheme.SEPARATOR)
		return
	if not _show_modifiers:
		_graph.set_modified([], false)
		_caption.text = "Modifiers hidden. " + _modifier_summary()
		_caption.add_theme_color_override("font_color", UITheme.SEPARATOR)
		return

	# `block` suppresses all device output — the script is ignored and the device
	# holds. Represent that as a flat neutral line rather than a transformed curve.
	if _has_block():
		_graph.set_modified(_flat_line(50.0), true)
		_caption.text = (
			"BLOCK active — the device ignores the script (holds position). " + _modifier_summary()
		)
		_caption.add_theme_color_override("font_color", UITheme.AMBER)
		return

	var raw: Array = _graph.get_raw()
	var modified: Array = []
	for i in raw.size():
		modified.append(Vector2((raw[i] as Vector2).x, _transform_pos_at(raw, i, _modifiers)))
	_graph.set_modified(modified, true)
	_caption.text = _modifier_summary()
	_caption.add_theme_color_override("font_color", UITheme.CYAN)


# A row of live-tuning controls, one group per stroke effect that has a magnitude (scale →
# stroke-length %, clamp → min/max). reverse/block carry no magnitude and are skipped.
# Returns null when nothing is tunable. Dragging a control rewrites the effect's params in
# `_modifiers` (redrawing the curve) and persists via `_on_tune`.
func _build_tuning_strip() -> Control:
	var strip: HBoxContainer = HBoxContainer.new()
	strip.add_theme_constant_override("separation", 16)
	var lead: Label = Label.new()
	lead.text = "TUNE"
	lead.add_theme_font_size_override("font_size", 11)
	lead.add_theme_color_override("font_color", UITheme.PURPLE_MID)
	strip.add_child(lead)

	var any: bool = false
	for m: Dictionary in _modifiers:
		var specs: Array = JourneyData.effect_param_specs(String(m.get("kind", "")))
		if specs.is_empty():
			continue
		any = true
		var group: VBoxContainer = VBoxContainer.new()
		group.add_theme_constant_override("separation", 1)
		var name_lbl: Label = Label.new()
		name_lbl.text = String(m.get("name", m.get("kind", ""))).to_upper()
		name_lbl.add_theme_font_size_override("font_size", 10)
		name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
		group.add_child(name_lbl)
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		if String(m.get("kind", "")) == "clamp":
			_fill_clamp_row(row, m)  # min/max cross-linked so the range can't invert
		else:
			for spec: Dictionary in specs:
				row.add_child(_make_tune_control(m, spec))
		group.add_child(row)
		strip.add_child(group)

	if not any:
		return null

	# Wrap the controls with a caption so the strip reads as interactive, not decorative.
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(strip)
	var caption: Label = Label.new()
	caption.text = "Drag to reshape the strokes — the curve updates live and saves to the round."
	caption.add_theme_font_size_override("font_size", 10)
	caption.add_theme_color_override("font_color", UITheme.SEPARATOR)
	box.add_child(caption)
	return box


# A labeled SpinBox, returned as {box, spin} so callers can wire the value_changed signal.
func _labeled_spin(
	label: String, mn: float, mx: float, step: float, suffix: String, value: float
) -> Dictionary:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var lab: Label = Label.new()
	lab.text = label
	lab.add_theme_font_size_override("font_size", 9)
	lab.add_theme_color_override("font_color", UITheme.SEPARATOR)
	box.add_child(lab)
	var spin: SpinBox = SpinBox.new()
	spin.min_value = mn
	spin.max_value = mx
	spin.step = step
	spin.suffix = suffix
	spin.custom_minimum_size = Vector2(84, 0)
	UITheme.style_spin_box(spin)
	spin.set_value_no_signal(value)
	box.add_child(spin)
	return {"box": box, "spin": spin}


# One SpinBox editing `m[spec.key]` in place: rewrites the modifier params, redraws the
# curve, and reports the change through _on_tune (which persists / prunes on the round).
func _make_tune_control(m: Dictionary, spec: Dictionary) -> Control:
	var key: String = String(spec.get("key", ""))
	var ctl: String = String(spec.get("ctl", ""))
	var ref: String = String(m.get("_ref", m.get("name", "")))
	var view_scale: float = 100.0 if ctl == "pct" else 1.0
	var ui: Dictionary = _labeled_spin(
		String(spec.get("label", key)),
		float(spec.get("min", 0)) * view_scale,
		float(spec.get("max", 1)) * view_scale,
		float(spec.get("step", 1)) * view_scale,
		"%" if ctl == "pct" else "",
		float(m.get(key, spec.get("min", 0))) * view_scale
	)
	var spin: SpinBox = ui["spin"]
	spin.value_changed.connect(
		func(v: float) -> void:
			var real: float = v / view_scale
			var store_val: Variant = int(round(real)) if ctl in ["pos", "coins"] else real
			m[key] = store_val
			_refresh_modified()
			_persist_tune(ref, key, store_val)
	)
	return ui["box"]


# Clamp's min + max, cross-linked: dragging min above max pushes max up (and vice versa) so
# the range can never invert — an inverted clamp maps strokes backwards, never what's wanted.
func _fill_clamp_row(row: HBoxContainer, m: Dictionary) -> void:
	var ref: String = String(m.get("_ref", m.get("name", "")))
	var mn_ui: Dictionary = _labeled_spin("Range min", 0, 100, 1, "", int(m.get("min", 0)))
	var mx_ui: Dictionary = _labeled_spin("Range max", 0, 100, 1, "", int(m.get("max", 100)))
	var min_spin: SpinBox = mn_ui["spin"]
	var max_spin: SpinBox = mx_ui["spin"]
	min_spin.value_changed.connect(
		func(v: float) -> void:
			var mn: int = int(round(v))
			m["min"] = mn
			_persist_tune(ref, "min", mn)
			if mn > int(max_spin.value):
				max_spin.set_value_no_signal(mn)
				m["max"] = mn
				_persist_tune(ref, "max", mn)
			_refresh_modified()
	)
	max_spin.value_changed.connect(
		func(v: float) -> void:
			var mx: int = int(round(v))
			m["max"] = mx
			_persist_tune(ref, "max", mx)
			if mx < int(min_spin.value):
				min_spin.set_value_no_signal(mx)
				m["min"] = mx
				_persist_tune(ref, "min", mx)
			_refresh_modified()
	)
	row.add_child(mn_ui["box"])
	row.add_child(mx_ui["box"])


func _persist_tune(ref: String, key: String, value: Variant) -> void:
	if _on_tune.is_valid():
		_on_tune.call(ref, key, value)


# ── Modifier math ────────────────────────────────────────────────────────────
#
# IMPORTANT: this MUST stay in lockstep with FunscriptPlayer.TransformPos (C#),
# which is the runtime source of truth. Same order — mirror → scale → clamp — and
# same formulas (scale uses each stroke's LOCAL centre = neighbour midpoint), so
# the preview shows exactly what the device will do. If you change the transform
# in one place, change it in both.
func _transform_pos_at(points: Array, i: int, effects: Array) -> float:
	# Mirror (reverse): an odd number of reverse effects flips the stroke; even
	# cancels. The runtime eases the flip over time — a static preview shows the
	# fully-settled result.
	var reverse_count: int = 0
	for e: Dictionary in effects:
		if String(e.get("kind", "")) == "reverse":
			reverse_count += 1
	var mirrored: bool = reverse_count % 2 == 1
	var pos: float = _mirror_one((points[i] as Vector2).y, mirrored)

	# Scale each stroke around its local centre (neighbour midpoint). All scale
	# effects multiply into one factor.
	var scale_factor: float = 1.0
	for e: Dictionary in effects:
		if String(e.get("kind", "")) == "scale" and e.has("factor"):
			scale_factor *= float(e["factor"])
	if not is_equal_approx(scale_factor, 1.0):
		var prev: float = _mirror_one((points[maxi(0, i - 1)] as Vector2).y, mirrored)
		var nxt: float = _mirror_one(
			(points[mini(points.size() - 1, i + 1)] as Vector2).y, mirrored
		)
		var center: float = (prev + nxt) * 0.5
		pos = center + (pos - center) * scale_factor

	# Clamp into a sub-range (stacks successively).
	for e: Dictionary in effects:
		if String(e.get("kind", "")) == "clamp":
			var mn: float = float(e.get("min", 0))
			var mx: float = float(e.get("max", 100))
			pos = mn + clampf(pos, 0.0, 100.0) / 100.0 * (mx - mn)

	return clampf(pos, 0.0, 100.0)


func _mirror_one(v: float, mirrored: bool) -> float:
	return 100.0 - v if mirrored else v


func _has_block() -> bool:
	for e: Dictionary in _modifiers:
		if String(e.get("kind", "")) == "block":
			return true
	return false


# A flat curve at `pos` spanning the raw script's time range.
func _flat_line(pos: float) -> Array:
	var raw: Array = _graph.get_raw()
	if raw.is_empty():
		return []
	var first: float = (raw[0] as Vector2).x
	var last: float = (raw[-1] as Vector2).x
	return [Vector2(first, pos), Vector2(last, pos)]


# Human summary of the active modifiers, e.g. "Modifiers: Scale ×1.2 · Clamp 50–100".
func _modifier_summary() -> String:
	var parts: Array = []
	for e: Dictionary in _modifiers:
		match String(e.get("kind", "")):
			"scale":
				parts.append("Scale ×%s" % str(e.get("factor", 1.0)))
			"clamp":
				parts.append("Clamp %d–%d" % [int(e.get("min", 0)), int(e.get("max", 100))])
			"reverse":
				parts.append("Mirror")
			"block":
				parts.append("Block")
			"blackout":
				parts.append("Blackout (video only)")
			_:
				parts.append(String(e.get("kind", "")).capitalize())
	return "Modifiers: " + "  ·  ".join(parts) if not parts.is_empty() else ""


func _format_time(ms: float) -> String:
	var total_s: int = int(ms / 1000.0)
	return "%d:%02d" % [total_s / 60, total_s % 60]


func _close() -> void:
	if _video != null:
		_video.stop()
	queue_free()


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# Handled here in _input (before the GUI focus pass) and consumed, so the keys
	# can't reach the still-focused "Preview" button behind us — Space on that
	# button would otherwise open another preview.
	# Undo/redo is scoped to this overlay's timeline — see the _undo declaration. Checked before
	# the plain-key match so Ctrl+Z doesn't fall through to anything else.
	if _edit_mode and event.ctrl_pressed:
		match event.keycode:
			KEY_Z:
				_undo_step()
				get_viewport().set_input_as_handled()
				return
			KEY_Y:
				_redo_step()
				get_viewport().set_input_as_handled()
				return
	match event.keycode:
		KEY_ESCAPE:
			_close()
			get_viewport().set_input_as_handled()
		KEY_SPACE:
			_toggle_play()  # no-op without a playable video; stops an EDL walk first
			get_viewport().set_input_as_handled()


# ── Video ────────────────────────────────────────────────────────────────────


# Loads the round's video into the preview, mirroring GameLoop's runtime loader
# (ogv via ResourceLoader, mp4/mkv/webm via EIRTeam). EIRTeam only decodes H.264,
# so an undecodable source never starts playing — we then hide the pane and the
# preview stays graph-only, exactly the runtime's behaviour. The pane must be
# visible for the player to actually start, so we show it, then poll is_playing().
func _setup_video(path: String) -> void:
	if path == "":
		return
	var ext: String = path.get_extension().to_lower()
	if ext == "ogv":
		var stream: Resource = ResourceLoader.load(path)
		if stream is VideoStream:
			_video.stream = stream as VideoStream
		else:
			return
	elif ClassDB.class_exists("FFmpegVideoStream"):
		var stream: Resource = ClassDB.instantiate("FFmpegVideoStream")
		stream.set("file", ProjectSettings.globalize_path(path))
		_video.stream = stream as VideoStream
	else:
		return  # no decoder available

	# Must be visible to actually decode and report is_playing() — a hidden
	# VideoStreamPlayer won't start, so show the pane first, then confirm.
	_video_pane.visible = true
	_video.play()
	# EIRTeam opens the file asynchronously; poll up to ~1s for playback to start.
	var started: bool = false
	for _i in 60:
		await get_tree().process_frame
		if not is_inside_tree():
			return  # overlay closed during detection
		if _video.is_playing():
			started = true
			break
	if started:
		_video_ok = true
		_play_btn.disabled = false
		_audio_btn.disabled = false
		_apply_audio()
		_update_play_btn()
		_apply_aspect()
		_start_sensory()
		_apply_saved_split()  # size the video pane to the author's saved split, now that it's shown
		set_process(true)
	else:
		_video_pane.visible = false  # decode failed — stay graph-only
		_video.stream = null


# Stands the sensory engine up over the video pane (not the whole overlay, so murk/tunnel/strobe
# darken the clip rather than the editor around it). Only once a video is confirmed — every
# sensory effect acts on the video node or its audio bus, so there's nothing to show without one.
func _start_sensory() -> void:
	if _sensory_rolls.is_empty():
		return
	_sensory = SensoryFX.new()
	add_child(_sensory)
	_sensory.setup(_video, _video_pane)
	_refresh_sensory()


# Re-applies every sensory roll at its current intensity. clear_all() first because apply() is
# additive — without it, dragging a slider would stack effects instead of replacing them.
func _refresh_sensory() -> void:
	if _sensory == null:
		return
	_sensory.clear_all()
	for roll: Dictionary in _sensory_rolls:
		var nm: String = str(roll.get("name", ""))
		var intensity: float = float(_sensory_intensity.get(nm, roll.get("idef", 0.5)))
		_sensory.apply(roll, intensity, false)


# Sets the letterbox aspect from the real video dimensions once a frame exists.
func _apply_aspect() -> void:
	if _aspect_set:
		return
	var tex: Texture2D = _video.get_video_texture()
	if tex != null and tex.get_size().x > 0.0 and tex.get_size().y > 0.0:
		_video_aspect.ratio = tex.get_size().x / tex.get_size().y
		_aspect_set = true


func _process(_delta: float) -> void:
	if not _video_ok:
		return
	if not _aspect_set:
		_apply_aspect()  # the video texture can appear a frame or two after playback starts
	# Drive the playhead from the video clock only while actively advancing
	# (playing AND not paused), and never while the author is scrubbing.
	if _is_advancing() and not _graph.is_dragging():
		_graph.set_playhead(_video.stream_position * 1000.0)
		if _edl_playing:
			_advance_edl()
	_update_play_btn()  # keeps the label correct through pause / resume / natural end


# ── EDL playback ────────────────────────────────────────────────────────────


func _toggle_edl_playback() -> void:
	if _edl_playing:
		_stop_edl_playback()
		return
	if not _video_ok or _segments.is_empty():
		_flash_seg_label("Nothing to play — add a segment first")
		return
	_edl_playing = true
	_enter_edl_segment(0)
	_sync_edl_btn()


func _stop_edl_playback() -> void:
	_edl_playing = false
	_edl_idx = -1
	if _video_ok:
		_video.paused = true
	_sync_edl_btn()
	_update_play_btn()


func _sync_edl_btn() -> void:
	if _edl_btn != null:
		_edl_btn.text = "⏹ STOP TIMELINE" if _edl_playing else "▶ PLAY TIMELINE"


# Seeks to segment `i` and plays it. Seeking at every join is only viable because this
# decoder's seeks measured cheap; if that regresses, this is the one place to change.
func _enter_edl_segment(i: int) -> void:
	if i >= _segments.size():
		_stop_edl_playback()
		return
	_edl_idx = i
	if not _video.is_playing():
		_video.play()
	_video.paused = false
	_video.stream_position = float(int((_segments[i] as Dictionary).get("in_ms", 0))) / 1000.0
	_update_play_btn()


# Per frame while walking: hop to the next row once this window's out point passes.
func _advance_edl() -> void:
	if _edl_idx < 0 or _edl_idx >= _segments.size():
		return
	var out_ms: int = int((_segments[_edl_idx] as Dictionary).get("out_ms", 0))
	var end_ms: int = out_ms if out_ms > 0 else _source_len_ms()
	if _video.stream_position * 1000.0 >= float(end_ms):
		_enter_edl_segment(_edl_idx + 1)


# True while the video is actually advancing. is_playing() stays true while
# paused (it means "a stream is loaded"), so pause state must be checked too.
func _is_advancing() -> bool:
	return _video.is_playing() and not _video.paused


func _toggle_play() -> void:
	if not _video_ok:
		return
	# Plain playback and the EDL walk both drive stream_position, so only one runs at a time.
	if _edl_playing:
		_stop_edl_playback()
	if not _video.is_playing():
		# Finished (or stopped) — restart playback from the current playhead.
		_video.play()
		_video.stream_position = _graph.get_playhead() / 1000.0
		_video.paused = false
	else:
		_video.paused = not _video.paused
	_update_play_btn()


func _update_play_btn() -> void:
	_play_btn.text = "⏸ PAUSE" if _is_advancing() else "▶ PLAY"


func _apply_audio() -> void:
	_video.volume_db = 0.0 if _audio_on else -80.0
	_audio_btn.text = "🔊" if _audio_on else "🔇"


# Graph scrub → seek the video to that time.
func _on_scrubbed(ms: float) -> void:
	if _video_ok:
		_video.stream_position = ms / 1000.0


# ── Timeline editing ────────────────────────────────────────────────────────


# Always call before mutating `_segments`.
func _push_undo() -> void:
	_undo.append(_segments.duplicate(true))
	_redo.clear()  # a fresh edit invalidates the redo branch


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_redo.append(_segments.duplicate(true))
	_segments = _undo.pop_back()
	_sel_row = mini(_sel_row, _segments.size() - 1)
	_rebuild_rows()


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_segments.duplicate(true))
	_segments = _redo.pop_back()
	_sel_row = mini(_sel_row, _segments.size() - 1)
	_rebuild_rows()


# Falls back to the funscript's end when the decoder can't report a length.
func _source_len_ms() -> int:
	if _video_ok and _video.get_stream_length() > 0.0:
		return int(_video.get_stream_length() * 1000.0)
	var raw: Array = _graph.get_raw()
	return int((raw[-1] as Vector2).x) if not raw.is_empty() else 0


# Places a mark at the playhead. Dropping the row selection matters: + ADD leaves the new row
# selected (so ⧉ REPEAT can act on it immediately), and while a row is selected the graph shades
# THAT window — so without this, placing marks for a second segment showed no feedback at all
# and looked like the editor was refusing to let you build another one.
func _set_mark(is_in: bool) -> void:
	if is_in:
		_mark_in = int(_graph.get_playhead())
	else:
		_mark_out = int(_graph.get_playhead())
	_sel_row = -1
	_rebuild_rows()


# Commits the ⟦IN/OUT⟧ marks as a row. Unset IN = from the start; unset OUT = to the end,
# stored as 0 (the open-ended form the pure layer uses).
func _add_pending_segment() -> void:
	var start_ms: int = maxi(0, _mark_in)
	var end_ms: int = _mark_out
	if end_ms > 0 and end_ms <= start_ms:
		_flash_seg_label("OUT must be after IN")
		return
	_push_undo()
	_segments.append({"in_ms": start_ms, "out_ms": maxi(0, end_ms)})
	_sel_row = _segments.size() - 1
	_mark_in = -1
	_mark_out = -1
	_rebuild_rows()


# Grows the selected row to `_repeat_spin` total passes by inserting copies after it.
func _repeat_selected() -> void:
	if _sel_row < 0 or _sel_row >= _segments.size():
		_flash_seg_label("Select a row first")
		return
	var passes: int = int(_repeat_spin.value)
	if passes < 2:
		return
	_push_undo()
	var row: Dictionary = _segments[_sel_row]
	for _i: int in passes - 1:
		_segments.insert(_sel_row + 1, row.duplicate())
	_rebuild_rows()


func _move_row(i: int, delta: int) -> void:
	var j: int = i + delta
	if j < 0 or j >= _segments.size():
		return
	_push_undo()
	var row: Dictionary = _segments[i]
	_segments.remove_at(i)
	_segments.insert(j, row)
	_sel_row = j
	_rebuild_rows()


func _delete_row(i: int) -> void:
	if i < 0 or i >= _segments.size():
		return
	_push_undo()
	_segments.remove_at(i)
	_sel_row = mini(_sel_row, _segments.size() - 1)
	_rebuild_rows()


func _duplicate_row(i: int) -> void:
	if i < 0 or i >= _segments.size():
		return
	_push_undo()
	_segments.insert(i + 1, (_segments[i] as Dictionary).duplicate())
	_sel_row = i + 1
	_rebuild_rows()


# Rebuilds every row from `_segments`. The list is short and edits are user-paced, so a full
# rebuild is simpler (and less bug-prone) than surgical row patching.
func _rebuild_rows() -> void:
	if _rows_box == null:
		return
	for child: Node in _rows_box.get_children():
		child.queue_free()

	var src_len: int = _source_len_ms()
	for i: int in _segments.size():
		var seg: Dictionary = _segments[i]
		var start_ms: int = int(seg.get("in_ms", 0))
		var end_ms: int = int(seg.get("out_ms", 0))
		var idx: int = i  # captured by this row's button callbacks

		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

		var pick: Button = Button.new()
		pick.toggle_mode = true
		pick.button_pressed = (i == _sel_row)
		pick.text = (
			"%2d.   %s – %s   (%s)"
			% [
				i + 1,
				JourneyData.ms_to_mmss(start_ms),
				JourneyData.ms_to_mmss(end_ms) if end_ms > 0 else "END",
				JourneyData.ms_to_mmss(maxi(0, (end_ms if end_ms > 0 else src_len) - start_ms)),
			]
		)
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pick.add_theme_font_size_override("font_size", 11)
		pick.pressed.connect(
			func() -> void:
				_sel_row = idx
				_rebuild_rows()
		)
		row.add_child(pick)

		row.add_child(_row_btn("▲", "Move earlier", func() -> void: _move_row(idx, -1)))
		row.add_child(_row_btn("▼", "Move later", func() -> void: _move_row(idx, 1)))
		row.add_child(_row_btn("⧉", "Duplicate this row", func() -> void: _duplicate_row(idx)))
		row.add_child(_row_btn("✕", "Remove this row", func() -> void: _delete_row(idx)))
		_rows_box.add_child(row)

	_sync_markers()


func _row_btn(text: String, tip: String, cb: Callable) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.tooltip_text = UITheme.wrap_tip(tip)
	b.add_theme_font_size_override("font_size", 11)
	b.pressed.connect(cb)
	return b


# Pushes the graph's shaded window (the selected row, or the pending ⟦IN/OUT⟧ marks when
# nothing is selected) and refreshes the timeline readout.
func _sync_markers() -> void:
	var start_ms: float = -1.0
	var end_ms: float = -1.0
	# Pending marks win over the row selection — while you're placing a window, that's the one
	# you need to see.
	if _mark_in >= 0 or _mark_out > 0:
		start_ms = float(_mark_in) if _mark_in >= 0 else -1.0
		end_ms = float(_mark_out) if _mark_out > 0 else -1.0
	elif _sel_row >= 0 and _sel_row < _segments.size():
		var seg: Dictionary = _segments[_sel_row]
		var seg_out: int = int(seg.get("out_ms", 0))
		start_ms = float(int(seg.get("in_ms", 0)))
		end_ms = float(seg_out) if seg_out > 0 else -1.0
	_graph.set_trim(start_ms, end_ms)

	if _seg_label == null:
		return
	if _segments.is_empty():
		_seg_label.text = "NO SEGMENTS — full clip"
	else:
		var total: int = JourneyData.segments_total_ms(_segments, _source_len_ms())
		_seg_label.text = (
			"%d SEGMENT%s — %s"
			% [
				_segments.size(),
				"" if _segments.size() == 1 else "S",
				JourneyData.ms_to_mmss(total)
			]
		)


func _flash_seg_label(msg: String) -> void:
	if _seg_label != null:
		_seg_label.text = msg


# ===========================================================================
# Inner graph control — draws the curves + a draggable playhead.
# ===========================================================================
class _Graph:
	extends Control
	const PAD_LEFT: float = 34.0  # left gutter the floating Y labels sit over
	const PAD_RIGHT: float = 16.0
	const PAD_TOP: float = 10.0
	const PAD_BOTTOM: float = 22.0

	# Time scale: how many horizontal pixels represent one second. Adjustable via
	# the zoom buttons so strokes stay legible; the canvas grows wider than the
	# viewport and scrolls.
	const DEFAULT_PX_PER_SEC: float = 150.0
	const MIN_PX_PER_SEC: float = 20.0
	const MAX_PX_PER_SEC: float = 800.0
	const GRID_SECONDS: int = 5  # vertical gridline + time label every N seconds

	# Emitted while the author drags the playhead, so the preview can seek video.
	signal scrubbed(ms: float)

	var _px_per_sec: float = DEFAULT_PX_PER_SEC
	var _raw: Array = []  # Array[Vector2(at_ms, pos)]
	var _modified: Array = []  # Array[Vector2(at_ms, pos)], empty when hidden
	var _has_modified: bool = false
	var _length_ms: float = 1.0
	var _playhead_ms: float = 0.0
	var _dragging: bool = false
	# Trim markers (trim mode only): in >= 0 shows the IN line, out > 0 the OUT
	# line; the excluded regions outside the window are shaded. -1/-1 = off.
	var _trim_in_ms: float = -1.0
	var _trim_out_ms: float = -1.0
	var time_label_format: Callable = func(ms: float) -> String: return str(int(ms))

	func set_trim(in_ms: float, out_ms: float) -> void:
		_trim_in_ms = in_ms
		_trim_out_ms = out_ms
		queue_redraw()

	func set_raw(points: Array) -> void:
		_raw = points
		_length_ms = maxf(1.0, (points[-1] as Vector2).x) if not points.is_empty() else 1.0
		_playhead_ms = clampf(_playhead_ms, 0.0, _length_ms)
		_update_width()
		queue_redraw()

	func get_raw() -> Array:
		return _raw

	func is_dragging() -> bool:
		return _dragging

	func get_playhead() -> float:
		return _playhead_ms

	# Sets the playhead from an external clock (the video) and keeps it visible by
	# auto-scrolling. Distinct from a user scrub, which must NOT auto-scroll (the
	# author controls the scroll while dragging).
	func set_playhead(ms: float) -> void:
		_playhead_ms = clampf(ms, 0.0, _length_ms)
		_follow_playhead()
		queue_redraw()

	# Nudges the parent ScrollContainer so the playhead stays within the middle
	# band of the viewport during playback.
	func _follow_playhead() -> void:
		var p: Node = get_parent()
		if not (p is ScrollContainer):
			return
		var sc: ScrollContainer = p as ScrollContainer
		var view_w: float = sc.size.x
		var x: float = _time_to_x(_playhead_ms)
		var margin: float = view_w * 0.2
		if x < sc.scroll_horizontal + margin:
			sc.scroll_horizontal = int(x - margin)
		elif x > sc.scroll_horizontal + view_w - margin:
			sc.scroll_horizontal = int(x - view_w + margin)

	# Drive the scrollable width from the time scale. Min height is a floor; the
	# ScrollContainer stretches us to the viewport height via size flags.
	func _update_width() -> void:
		custom_minimum_size = Vector2(
			PAD_LEFT + PAD_RIGHT + (_length_ms / 1000.0) * _px_per_sec, 240.0
		)

	# Multiply the zoom by `factor`, keeping the playhead centred in the viewport.
	func zoom_by(factor: float) -> void:
		_px_per_sec = clampf(_px_per_sec * factor, MIN_PX_PER_SEC, MAX_PX_PER_SEC)
		_update_width()
		call_deferred("_center_on_playhead")  # after the container re-lays-out
		queue_redraw()

	func _center_on_playhead() -> void:
		var p: Node = get_parent()
		if p is ScrollContainer:
			(p as ScrollContainer).scroll_horizontal = int(
				_time_to_x(_playhead_ms) - (p as ScrollContainer).size.x / 2.0
			)
			queue_redraw()

	func set_modified(points: Array, has_modified: bool) -> void:
		_modified = points
		_has_modified = has_modified
		queue_redraw()

	func _plot_area() -> Rect2:
		return Rect2(
			PAD_LEFT, PAD_TOP, size.x - PAD_LEFT - PAD_RIGHT, size.y - PAD_TOP - PAD_BOTTOM
		)

	func _time_to_x(at_ms: float) -> float:
		return PAD_LEFT + (at_ms / 1000.0) * _px_per_sec

	func _to_px(p: Vector2, area: Rect2) -> Vector2:
		var y: float = area.position.y + (1.0 - clampf(p.y, 0.0, 100.0) / 100.0) * area.size.y
		return Vector2(_time_to_x(p.x), y)

	# Builds the polyline for the part of `points` inside the visible scroll
	# window (plus one point each side for edge continuity), so render cost stays
	# flat no matter how long the script is.
	func _curve_px(points: Array, area: Rect2) -> PackedVector2Array:
		var out: PackedVector2Array = PackedVector2Array()
		if points.is_empty():
			return out
		var sx: float = _scroll_x()
		var view_w: float = (
			(get_parent() as Control).size.x if get_parent() is ScrollContainer else size.x
		)
		var t_min: float = (sx - PAD_LEFT) / _px_per_sec * 1000.0
		var t_max: float = (sx + view_w - PAD_LEFT) / _px_per_sec * 1000.0
		var prev_in: bool = false
		for i in points.size():
			var p: Vector2 = points[i]
			if p.x >= t_min and p.x <= t_max:
				if not prev_in and i > 0:
					out.append(_to_px(points[i - 1], area))  # carry the off-screen left point
				out.append(_to_px(p, area))
				prev_in = true
			elif prev_in:
				out.append(_to_px(p, area))  # carry the first off-screen right point, then stop
				break
		return out

	# Horizontal scroll offset of our parent ScrollContainer (0 if none) — used to
	# pin the Y-axis labels to the left edge of the visible area as we scroll.
	func _scroll_x() -> float:
		var p: Node = get_parent()
		return float(p.scroll_horizontal) if p is ScrollContainer else 0.0

	func _draw() -> void:
		var area: Rect2 = _plot_area()
		var font: Font = ThemeDB.fallback_font

		# Plot background + frame.
		draw_rect(area, Color(0.04, 0.02, 0.06, 1.0), true)
		draw_rect(
			area,
			Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.5),
			false,
			1.0
		)

		# Vertical time gridlines + labels every GRID_SECONDS.
		var total_s: int = int(_length_ms / 1000.0)
		for s in range(0, total_s + 1, GRID_SECONDS):
			var gx: float = _time_to_x(s * 1000.0)
			draw_line(
				Vector2(gx, area.position.y),
				Vector2(gx, area.position.y + area.size.y),
				Color(1, 1, 1, 0.06),
				1.0
			)
			draw_string(
				font,
				Vector2(gx + 2, area.position.y + area.size.y + 14),
				time_label_format.call(s * 1000.0),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				9,
				Color(1, 1, 1, 0.4)
			)

		# Horizontal gridlines at 0 / 25 / 50 / 75 / 100.
		for pos in [0, 25, 50, 75, 100]:
			var y: float = _to_px(Vector2(0.0, float(pos)), area).y
			draw_line(
				Vector2(area.position.x, y),
				Vector2(area.position.x + area.size.x, y),
				Color(1, 1, 1, 0.16 if pos == 50 else 0.06),
				1.0
			)

		if _raw.size() >= 2:
			# Raw curve (dim when a modified curve is overlaid, so the modified pops).
			var raw_col: Color = Color(
				UITheme.WHITE_SOFT.r,
				UITheme.WHITE_SOFT.g,
				UITheme.WHITE_SOFT.b,
				0.35 if _has_modified else 0.9
			)
			_draw_curve(_curve_px(_raw, area), raw_col, 1.5)
		elif _raw.is_empty():
			draw_string(
				font,
				Vector2(_scroll_x() + PAD_LEFT + 20, area.position.y + area.size.y * 0.5),
				"No funscript to preview",
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				13,
				Color(1, 1, 1, 0.5)
			)

		# Modified curve on top.
		if _has_modified and _modified.size() >= 2:
			_draw_curve(_curve_px(_modified, area), UITheme.CYAN, 2.0)

		if _trim_in_ms >= 0.0 or _trim_out_ms > 0.0:
			_draw_trim(area, font)
		_draw_playhead(area, font)
		_draw_y_labels(area, font)

	# Shades everything outside the trim window and draws the IN / OUT marker
	# lines, so the author sees exactly what the bake will keep.
	func _draw_trim(area: Rect2, font: Font) -> void:
		var shade: Color = Color(0, 0, 0, 0.55)
		var right: float = area.position.x + area.size.x
		if _trim_in_ms > 0.0:
			var x_in: float = clampf(_time_to_x(_trim_in_ms), area.position.x, right)
			draw_rect(
				Rect2(area.position.x, area.position.y, x_in - area.position.x, area.size.y),
				shade,
				true
			)
		if _trim_out_ms > 0.0:
			var x_out: float = clampf(_time_to_x(_trim_out_ms), area.position.x, right)
			draw_rect(Rect2(x_out, area.position.y, right - x_out, area.size.y), shade, true)
		if _trim_in_ms >= 0.0:
			var xi: float = _time_to_x(maxf(_trim_in_ms, 0.0))
			draw_line(
				Vector2(xi, area.position.y),
				Vector2(xi, area.position.y + area.size.y),
				UITheme.TOXIC_GREEN,
				2.0
			)
			draw_string(
				font,
				Vector2(xi + 4, area.position.y + area.size.y - 6),
				"⟦ IN",
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				10,
				UITheme.TOXIC_GREEN
			)
		if _trim_out_ms > 0.0:
			var xo: float = _time_to_x(_trim_out_ms)
			draw_line(
				Vector2(xo, area.position.y),
				Vector2(xo, area.position.y + area.size.y),
				UITheme.DANGER,
				2.0
			)
			draw_string(
				font,
				Vector2(xo - 34, area.position.y + area.size.y - 6),
				"OUT ⟧",
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				10,
				UITheme.DANGER
			)

	# Position labels pinned to the left edge of the visible area (over a small
	# backing strip so curves don't run through the text) as the plot scrolls.
	func _draw_y_labels(area: Rect2, font: Font) -> void:
		var sx: float = _scroll_x()
		draw_rect(
			Rect2(sx, area.position.y, PAD_LEFT, area.size.y), Color(0.04, 0.02, 0.06, 0.85), true
		)
		for pos in [0, 25, 50, 75, 100]:
			var y: float = _to_px(Vector2(0.0, float(pos)), area).y
			draw_string(
				font,
				Vector2(sx + 4, y + 4),
				str(pos),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				9,
				Color(1, 1, 1, 0.45)
			)

	# Draws a curve as individual line segments. draw_polyline triangulates the
	# whole strip and breaks up (looks dashed) on the sharp V-turns a funscript is
	# full of; per-segment draw_line renders solid.
	func _draw_curve(pts: PackedVector2Array, color: Color, width: float) -> void:
		for i in range(1, pts.size()):
			draw_line(pts[i - 1], pts[i], color, width)

	func _draw_playhead(area: Rect2, font: Font) -> void:
		var x: float = _time_to_x(_playhead_ms)
		draw_line(
			Vector2(x, area.position.y),
			Vector2(x, area.position.y + area.size.y),
			UITheme.AMBER,
			1.0
		)
		var label: String = (
			time_label_format.call(_playhead_ms) + " / " + time_label_format.call(_length_ms)
		)
		draw_string(
			font,
			Vector2(x + 4, area.position.y + 12),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			10,
			UITheme.AMBER
		)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
			if event.pressed:
				_seek_to_x(event.position.x)
		elif event is InputEventMouseMotion and _dragging:
			_seek_to_x(event.position.x)

	func _seek_to_x(px: float) -> void:
		# px is in local (content) coordinates, so it maps straight through the scale.
		_playhead_ms = clampf((px - PAD_LEFT) / _px_per_sec * 1000.0, 0.0, _length_ms)
		scrubbed.emit(_playhead_ms)
		queue_redraw()
