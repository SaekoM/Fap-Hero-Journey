class_name JourneyBuilder
extends Control

# ---------------------------------------------------------------------------
# JourneyBuilder.gd  –  Create and save custom journeys
# Users fill out journey metadata, add rounds by picking funscript + video
# files via OS file dialog or drag-and-drop. The folder structure is built
# automatically under user://journeys/ and all files are copied in.
# ---------------------------------------------------------------------------

# All shared colors and style helpers live in `UITheme` (autoload). See
# Globals/UITheme.gd. Local references use UITheme.<COLOR_NAME> / UITheme.style_*.

const TOP_BAR_HEIGHT: int = 64

# Journeys root is configurable via Options → Journey Storage Location.
# Always read via SettingsService.get_journeys_dir() so a path change takes
# effect on the next save without restarting the scene.

# Difficulty list and file-extension sets live in JourneyData (canonical schema).
# Referenced here as JourneyData.DIFFICULTIES / JourneyData.IMAGE_EXTENSIONS etc.

# Codec/pixel-format probing, the transcode-need decision, and the actual ffmpeg
# encode live in MediaPoolService (shared with the randomizer library). This file
# owns only the graph walk that builds the plan and the save-progress modal.

# ── Save error / copy result cause codes ────────────────────────────────────
# Every SaveError flowing through _show_save_error_modal carries one of these
# in its `cause` field, and every _copy_file_chunked result carries one in
# its `reason` field. Centralised as constants so typos surface at parse time
# (string-literal mismatches in match statements silently fall through to the
# default arm otherwise) and the full taxonomy is easy to grep.
const CAUSE_BAD_NAME: String = "bad_name"
const CAUSE_NAME_COLLISION: String = "name_collision"
const CAUSE_MISSING_SOURCE: String = "missing_source"
const CAUSE_NO_ROUNDS: String = "no_rounds"
const CAUSE_STORYBOARD_EMPTY: String = "storyboard_empty"
const CAUSE_ITEM_INVALID: String = "item_invalid"
const CAUSE_FORK_UNDERFILLED: String = "fork_underfilled"
const CAUSE_FFMPEG_MISSING: String = "ffmpeg_missing"
const CAUSE_CANCELLED: String = "cancelled"
const CAUSE_SRC_UNREADABLE: String = "src_unreadable"
const CAUSE_DST_UNWRITABLE: String = "dst_unwritable"
const CAUSE_TRANSCODE_FAILED: String = "transcode_failed"
const CAUSE_TRIM_INVALID: String = "trim_invalid"
const CAUSE_ENCOUNTER_INVALID: String = "encounter_invalid"
const CAUSE_UNKNOWN_COPY_ERROR: String = "unknown_copy_error"
# Graph-editor structural causes (L4 validation).
const CAUSE_NO_START: String = "no_start"
const CAUSE_DANGLING_EDGE: String = "dangling_edge"
const CAUSE_CYCLE: String = "cycle"
const CAUSE_UNREACHABLE: String = "unreachable"
const CAUSE_LOOP_UNSATISFIABLE: String = "loop_unsatisfiable"
const CAUSE_LOOP_UNPAIRED: String = "loop_unpaired"

const GraphViewScene = preload("res://scenes/graph_view/GraphView.tscn")

@onready var _bg: ColorRect = $Background
@onready var _top_bar: HBoxContainer = $TopBar
@onready var _back_btn: Button = $TopBar/BackButton
@onready var _title_lbl: Label = $TopBar/TitleLabel
@onready var _status_lbl: Label = $TopBar/StatusLabel
@onready var _save_btn: Button = $TopBar/SaveButton
@onready var _main_layout: HBoxContainer = $MainLayout
@onready var _graph_host: Control = $MainLayout/GraphHost
@onready var _side_panel: PanelContainer = $MainLayout/SidePanel
@onready var _side_scroll: ScrollContainer = $MainLayout/SidePanel/SideScroll
@onready var _side_vbox: VBoxContainer = $MainLayout/SidePanel/SideScroll/SideVBox

static var edit_journey: Dictionary = {}

# When set before opening the builder, it starts in RENDITION mode: it loads this base journey with its
# nodes ghosted/read-only and a save produces an overlay delta rather than a journey (base untouched).
static var rendition_parent: Dictionary = {}

# Set ALONGSIDE rendition_parent to EDIT an existing rendition (its summary dict) rather than author a
# fresh one — the builder re-injects its saved delta on top of the ghosted base and re-saves in place.
static var edit_rendition: Dictionary = {}

# Set ALONGSIDE edit_journey by "merge into base": after the builder loads the base, it injects this node
# (with a real edge from its former anchor) so the author lands on the base with the node re-added, unsaved.
# {node_id, node, anchor, edge}
static var merge_inject: Dictionary = {}

# Set ALONGSIDE rendition_parent to author an overlay over ANOTHER rendition (sibling-dependency), not the
# base: the ghosted parent becomes base ⊕ the ancestor chain, and the new overlay targets `parent_id`.
# {start, nodes, parent_id, parent_name}. Empty = overlay the base directly.
static var rendition_over: Dictionary = {}

const SIDE_PANEL_WIDTH: int = 480

# Journey metadata: stored as member vars since the side-panel editor widgets
# are created and destroyed dynamically when the user navigates the graph.
# What _dirty_signature() returned when this journey was last loaded or saved. Anything else means
# there is work on screen that is not on disk. Empty until the first baseline is taken.
var _saved_signature: String = ""
var _journey_name: String = ""
# The journey's stable id (JourneyData.stamp_journey_identity). Empty for a new journey - minted
# on first save. Loaded from disk when editing, so a re-save or rename never re-mints it.
var _journey_id: String = ""
var _journey_author: String = ""
var _journey_desc: String = ""
var _journey_difficulty_idx: int = 0
var _journey_tags: Array = []  # Array[String] of tag ids (see TagRegistry)
var _journey_map_enabled: bool = true  # author allows the in-play journey map (off = enforce surprise)
var _journey_show_fork_counts: bool = true  # show the "N ROUNDS" tag on fork choices (off = hide for mystery)
var _journey_show_loops_on_map: bool = false  # show Loop markers on the player's map (off = hide, the default)
# Map backdrops: a STACK of location images drawn behind the graph (editor + in-game map) so nodes align
# to places. Each entry is {path, offset, scale, opacity}; offset/scale are canvas-local (node) space, so
# the same values drive both views. `_map_backdrops` are THIS journey's own (editable) layers.
var _map_backdrops: Array = []
# When editing a rendition, the base's backdrops load here as LOCKED context (drawn beneath the editable
# ones, never re-saved). Empty for a normal base journey.
var _base_backdrops: Array = []
var _backdrop_reposition_idx: int = -1  # editable-layer index currently in drag-to-move mode (-1 = none)
var _backdrop_tex_cache: Dictionary = {}  # path -> ImageTexture, shared by the graph push + panel thumbs
var _journey_map_fog: bool = false  # fog of war: reveal the map as the player discovers it (map must be enabled)
var _journey_map_fog_reveal: int = 1  # fog reveal depth: ghost levels ahead of the trail (< 0 = whole structure)
var _journey_mystery_preview: bool = false  # blur the previewer's totals + flow until nodes are discovered
var _journey_auto_advance_enabled: bool = false  # countdown on storyboards / interactive forks (off = players self-pace)
var _journey_auto_advance_storyboard_secs: int = 20  # per-line storyboard countdown when enabled
var _journey_auto_advance_fork_secs: int = 45  # fork-decision countdown when enabled
var _journey_shown_counters: Array = []  # Array[String] of counter names surfaced to the player (HUD + inventory)
var _journey_allow_finish: bool = false  # author opt-in: the player "I came" / FINISH button ends the run early
var _journey_finish_node: String = ""  # entry node of the off-graph aftercare sequence played on FINISH (round/storyboard; optional)
var _journey_items: Array = []  # author-defined journey-scoped items (runtime snake-case dicts)
var _journey_characters: Array = []  # storyboard cast (runtime dicts: id/name/portraits[]/placements[])

# Folder the journey was loaded from when editing. If the journey is renamed,
# the save writes a new folder; this lets us delete the stale original.
var _original_journey_folder: String = ""

var _cover_path: String = ""
var _cover_texture: ImageTexture = null  # cached so the journey-info view can re-show the preview without re-reading from disk

var _graph: Control = null  # GraphView instance, host inside _graph_host

# The free-form GRAPH editor model (GRAPH_EDITOR_OVERHAUL.md) — the journey as nodes + edges.
var _graph_model: Dictionary = {}  # {start, nodes:{id:{type,data,pos,out}}}

# Rendition (overlay) authoring. True when editing an overlay of a base journey. `_rendition_parent_ids`
# are the GHOSTED (read-only) base node ids; anything the author adds afterward is new/editable.
var _rendition_mode: bool = false
var _rendition_parent_id: String = ""  # the base's JourneyId → the overlay's ParentId
var _rendition_parent_folder: String = ""
var _rendition_parent_journey: Dictionary = {}  # the base's scanner dict — reloaded by "merge into base"
var _rendition_parent_ids: Dictionary = {}  # base node id -> true
var _rendition_slot_fills: Array = []  # [{node, field, channel, path}] — axis/vibe overlays on base rounds

var _selected_graph_node_id: String = ""  # the lone selected node id, or "" when 0 or 2+ are selected
var _selected_graph_node_ids: Array = []  # the full selection set (mirrors GraphView; drives group ops)
var _connecting_from: String = ""  # source node while wiring an edge (click-to-connect), else ""
var _connecting_edge_idx: int = -1  # while wiring: the fork choice index to wire, or -1 for a regular node's single out-edge

# Undo / redo of the graph STRUCTURE (not in-field text edits). Each entry is a deep _graph_model
# snapshot taken just before a structural mutation; recent last.
var _undo_stack: Array = []
var _redo_stack: Array = []
const UNDO_LIMIT: int = 50

# Clipboard (copy / cut / paste / duplicate). One clipboard, type-tagged by `_clip_kind`, since the
# selection is exclusive (nodes XOR a note). Nodes are deep [{id, node}] copies so paste can remap the
# edges between them; a note is a plain comment dict. _paste_count cascades the offset on repeat paste.
var _node_clipboard: Array = []
var _clip_comments: Array = []  # sticky notes pinned to the copied nodes — travel with them on paste
var _clip_comment: Dictionary = {}
var _clip_kind: String = ""  # "" | "nodes" | "comment"
var _paste_count: int = 0
const PASTE_OFFSET: Vector2 = Vector2(48, 48)

# Side panel renderer — owns no state of its own; reads/mutates this controller.
var _side_renderer: BuilderSidePanel = null

var _transcode_cancel: bool = false

# Set true when a media copy/transcode fails or is cancelled mid-save (by _copy_file or
# _save_round_node_media), so the _save_graph_nodes walk can stop and _on_save_pressed
# aborts the whole save cleanly.
var _save_aborted: bool = false

# Detailed failure info captured during a fork-path copy so the top-level
# handler can produce a specific error message instead of a generic "save
# cancelled". Shape: {"reason": String, "item": String, "detail": String}.
# Reset to {} at the start of every save.
var _save_abort_error: Dictionary = {}

# Save-wide counter that yields short, unique, filesystem-safe folder names
# for every round (top-level + every fork path at every nesting depth). Bounds
# the on-disk path length regardless of how long the user's round names are,
# and eliminates the round-name-collision bug where two rounds in different
# fork paths sharing a name landed in the same folder. The human-readable
# round name is preserved in journey.json's "Name" field; the slug ends up in
# the new "FolderName" field and is what the catalogue reads on load.
var _round_folder_counter: int = 0

# Save-wide map of non-H.264 video source paths → {codec, duration}. Built once by
# _build_transcode_plan (walking the graph's round nodes), then consulted per round in
# _save_round_node_media.
var _transcode_plan: Dictionary = {}

# Shared content-pool state for the current save. Reset at the start of
# _save_graph_nodes. `_pooled_media` maps a source fingerprint → its journey-root-
# relative pooled path (content/m_<fp>.<ext>); the second+ round to reference a
# source reuses the path and skips the transcode/copy. `_pooled_fs_stats` caches
# funscript {count,length_ms} per fingerprint so a reused script isn't re-parsed.
var _pooled_media: Dictionary = {}
var _pooled_fs_stats: Dictionary = {}

# Filenames of animated images clipped to MediaPoolService.ANIM_MAX_SECS during the current save.
# Collected rather than raised: an over-long decoration is trimmed, not an error — but the author
# is told, so a silently shortened image can't be mistaken for a bug.
var _anim_truncated: Array = []

# Count of player run-saves invalidated by this builder save (typically 0 or
# 1, possibly 2 if both the renamed-from and renamed-to folders had saves).
# Drives the contextual "Existing run reset" message in the success status
# so the author isn't surprised that the Resume button disappeared from the
# catalogue. Reset in _reset_save_state.
var _invalidated_save_count: int = 0

# The node to test-play from after this save: {"node_id": <id>}, or {} for a normal
# save (which returns to the catalogue instead of launching a preview). The id is the
# selected node's stable node_id; the save persists it as NodeId, parse_graph keys the
# runtime graph by it, and _launch_test_play seeks GameState there.
# Set by _save_and_test_from, reset in _reset_save_state.
var _pending_test_location: Dictionary = {}

# Starting score / coin balance for a test play, applied by GameLoop before the
# first node loads. Lets the author exercise Conditional / Sacrifice forks (which
# read last-round score and coin balance) from a chosen node. Persist across
# selections so they aren't re-entered every time; edited via the test controls
# in the node editor side panel.
var _test_seed_score: int = 0
var _test_seed_coins: int = 0
var _test_seed_flags: Array = []  # flag names to pre-set for a Test-From-Here run (exercise flag forks)
var _test_seed_items: Array = []  # item ids to grant for a Test-From-Here run (exercise item forks / shops)
var _test_seed_counters: Dictionary = {}  # counter name->value to pre-set (exercise counter forks)
var _test_panel_expanded: bool = false  # side-panel "Test From Here" group open/closed, persisted across node selections (panel rebuilds)

# Streaming-copy tuning. Chunks are read/written 1 MB at a time; the main thread
# yields one frame only after COPY_FRAME_BUDGET_MS of accumulated work — frequent
# enough that the window stays responsive, rare enough that the frame-wait tax
# stays under ~1 s even on multi-GB videos.
const COPY_CHUNK_SIZE: int = 1024 * 1024
const COPY_FRAME_BUDGET_MS: int = 100


func _ready() -> void:
	MusicService.play()
	_side_renderer = BuilderSidePanel.new(self)
	_apply_layout()
	_apply_theme()
	_setup_toolbar_buttons()
	_connect_signals()
	_setup_graph_view()
	if not rendition_parent.is_empty():
		_enter_rendition_mode(rendition_parent)
		if not edit_rendition.is_empty():
			_load_rendition_delta(edit_rendition)
			edit_rendition = {}
		rendition_parent = {}
		rendition_over = {}
	elif not edit_journey.is_empty():
		_original_journey_folder = edit_journey.get("folder", "")
		_load_graph(edit_journey)
		edit_journey = {}
		if not merge_inject.is_empty():
			_apply_merge_inject(merge_inject)
			merge_inject = {}
	_side_renderer.show_journey_info_panel()
	# Check for leftover staging folders from interrupted saves (crash, force-
	# kill, power loss). They take disk space and the user has no way to know
	# they exist otherwise — the dot prefix hides them from the catalogue.
	# Deferred so the dialog appears over the fully-rendered builder.
	call_deferred("_check_for_stale_staging_folders")


# Builds the GraphView inside the GraphHost slot and wires its node-selected
# signal to the side panel.
func _setup_graph_view() -> void:
	_graph = GraphViewScene.instantiate()
	_graph.anchor_right = 1.0
	_graph.anchor_bottom = 1.0
	_graph.keyboard_pan_enabled = true  # arrows / WASD scroll the canvas (builder only)
	_graph_host.add_child(_graph)
	# Rendered from _graph_model, populated IN PLACE by _load_graph (existing journey) before this
	# deferred call fires; empty for a new journey. Selection drives the side panel; a click while
	# wiring picks the edge target; a drag-start snapshots for undo.
	_graph.graph_selection_changed.connect(_on_graph_selection_changed)
	_graph.connect_target_picked.connect(_on_connect_target_picked)
	_graph.nodes_drag_started.connect(_push_undo)
	_graph.edge_drawn.connect(_on_edge_drawn)
	_graph.comment_clicked.connect(_on_comment_clicked)
	_graph.frame_clicked.connect(_on_frame_clicked)
	_graph.frame_toggle_collapse.connect(_on_frame_toggle_collapse)
	_graph.canvas_context_menu_requested.connect(_on_canvas_context_menu_requested)
	_graph.node_context_menu_requested.connect(_on_node_context_menu_requested)
	_graph.warning_provider = _compute_node_warnings  # GraphView pulls soft-validation badges each layout
	_graph.finish_id_provider = func() -> String: return _journey_finish_node  # badges the FINISH node
	# Drag-to-reposition a backdrop layer writes its new offset back (mapping the combined-stack index to
	# this journey's editable list) so the placement persists.
	_graph.backdrop_moved.connect(
		func(idx: int, off: Vector2) -> void:
			var ei: int = idx - _base_backdrops.size()
			if ei >= 0 and ei < _map_backdrops.size():
				(_map_backdrops[ei] as Dictionary)["offset"] = off
	)
	_graph.call_deferred("set_graph", _graph_model)
	call_deferred("_push_backdrops")  # push any loaded backdrops once the graph exists


# Rebuilds the graph view from _graph_model. Called after a structural change.
func _refresh_graph() -> void:
	if not _graph:
		return
	_graph.set_graph(_graph_model)


# Per-node soft validation for the live editor badge (restores the tree builder's node alerts):
# content problems (a round with no funscript, a moved source file, an unnamed fork choice, …) plus
# structural ones (an unreachable island, a dangling edge). Reuses the exact presave checkers, so a
# node badges for precisely what would block a save — but soft: it never blocks editing. Returns
# {node_id: summary}; the summary is the node's ⚠ hover tooltip.
func _compute_node_warnings() -> Dictionary:
	var warnings: Dictionary = {}
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var known_flags: Dictionary = _all_set_flags()  # every flag any node/choice sets (for dead-flag detection)
	for id: String in nodes:
		var n: Dictionary = nodes[id]
		var issues: Array = []
		match str(n.get("type", "")):
			"round":
				_save_check_round(n.get("data", {}), "Round", issues)
			"storyboard":
				_save_check_storyboard(n.get("data", {}), "Storyboard", issues)
			"fork":
				_save_check_fork_graph(n, "Fork", issues)
				_check_dead_flag_paths(n, known_flags, issues)
		if not issues.is_empty():
			var details: Array = []
			for it: Dictionary in issues:
				details.append(str(it.get("detail", "Problem")))
			warnings[id] = "\n".join(details)
	# Structural (whole-graph) problems, attached to the offending node.
	for gi: Dictionary in JourneyGraph.validate_graph(_graph_model, _journey_finish_node):
		var sid: String = str(gi.get("id", ""))
		if sid == "" or not nodes.has(sid):
			continue  # journey-level (e.g. no_start) — surfaced at save, not per node
		var msg: String = _structural_warning_text(str(gi.get("kind", "")))
		if msg != "":
			warnings[sid] = (str(warnings[sid]) + "\n" + msg) if warnings.has(sid) else msg
	_check_norepeat_pool_exhaustion(warnings)
	return warnings


# Advisory ⚠: flags no-repeat pool COPIES that are used more times on a single run-path than the pool
# has distinct clips — past that, the run-wide dedup is exhausted and a clip repeats. Copies are pools
# that share a clip set (so copy/paste groups them; editing one copy's clips de-groups it). Path-aware
# (max_nodes_on_path) so copies on exclusive fork branches, which never co-occur in one run, don't
# false-alarm. Doesn't block save — the runtime degrades gracefully to repeating.
func _check_norepeat_pool_exhaustion(warnings: Dictionary) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var groups: Dictionary = {}  # clip-set signature -> {ids: Array[node_id], clips: int}
	for id: String in nodes:
		var n: Dictionary = nodes[id]
		if str(n.get("type", "")) != "round":
			continue
		var data: Dictionary = n.get("data", {})
		if str(data.get("round_type", "")) != "pool" or not bool(data.get("no_repeat", false)):
			continue
		var clips: Array = _distinct_pool_clip_paths(data.get("pool_entries", []))
		var sig: String = "\n".join(clips)
		if not groups.has(sig):
			groups[sig] = {"ids": [], "clips": clips.size()}
		(groups[sig]["ids"] as Array).append(id)
	var start_id: String = str(_graph_model.get("start", ""))
	for sig: String in groups:
		var group: Dictionary = groups[sig]
		var ids: Array = group["ids"]
		var clip_count: int = int(group["clips"])
		# One copy never exhausts (single draw); zero clips is a separate missing-source issue.
		if ids.size() < 2 or clip_count <= 0:
			continue
		var targets: Dictionary = {}
		for gid: String in ids:
			targets[gid] = true
		var on_path: int = JourneyGraph.max_nodes_on_path(_graph_model, start_id, targets)
		if on_path <= clip_count:
			continue
		var msg: String = (
			"No-repeat pool used %d× on one run but has only %d clip%s — some plays will repeat."
			% [on_path, clip_count, "" if clip_count == 1 else "s"]
		)
		for gid: String in ids:
			warnings[gid] = (str(warnings[gid]) + "\n" + msg) if warnings.has(gid) else msg


# Sorted, distinct, non-empty video_paths of a pool's entries — its clip set, used to group copies
# and to count the no-repeat clip budget (dedup is by video_path, so distinct paths = unique clips).
func _distinct_pool_clip_paths(entries: Array) -> Array:
	var seen: Dictionary = {}
	for e: Variant in entries:
		var vp: String = str((e as Dictionary).get("video_path", ""))
		if vp != "":
			seen[vp] = true
	var paths: Array = seen.keys()
	paths.sort()
	return paths


# Every flag name any node's data or fork choice sets in this journey (for dead-flag detection).
func _all_set_flags() -> Dictionary:
	var flags: Dictionary = {}
	for id: String in _graph_model.get("nodes", {}):
		var n: Dictionary = _graph_model["nodes"][id]
		var d: Dictionary = n.get("data", {})
		for f: Variant in d.get("set_flags", []):
			flags[str(f)] = true
		for f: Variant in d.get("clear_flags", []):  # a cleared flag is part of the flag universe too
			flags[str(f)] = true
		# A boss encounter raises its own flags on the way out, and they live inside the round's timeline
		# rather than in the node's set_flags — a fork asking "did they beat her?" is asking about one of
		# these, so leaving them out made every such fork look like a typo and offered the author nothing
		# to type.
		for flag: String in JourneyData.boss_outcome_flags(d):
			flags[flag] = true
		for e: Dictionary in n.get("out", []):
			for f2: Variant in e.get("set_flags", []):
				flags[str(f2)] = true
			for f2: Variant in e.get("clear_flags", []):
				flags[str(f2)] = true
	return flags


# Soft badge: a conditional-flag choice requiring a flag nothing in the journey sets (a dead branch,
# usually a typo). Detail-only — doesn't block save.
func _check_dead_flag_paths(node: Dictionary, known_flags: Dictionary, issues: Array) -> void:
	var data: Dictionary = node.get("data", {})
	if (
		str(data.get("resolution", "")) != "conditional"
		or str(data.get("cond_metric", "")) != "flag"
	):
		return
	for ei in (node.get("out", []) as Array).size():
		var rf: String = (
			str(((node["out"][ei]) as Dictionary).get("required_flag", "")).strip_edges()
		)
		if rf != "" and not known_flags.has(rf):
			issues.append(
				{
					"detail":
					(
						'Choice %d requires flag "%s", which nothing in this journey sets (typo?).'
						% [ei + 1, rf]
					)
				}
			)


# Short per-node text for a structural validation issue (JourneyGraph.validate_graph kind).
func _structural_warning_text(kind: String) -> String:
	match kind:
		"unreachable":
			return "Unreachable — nothing leads here, so this node would never play."
		"dangling":
			return "A connection points to a node that no longer exists."
		"cycle":
			return "Part of a loop — a journey must flow forward (no cycles)."
	return ""


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------


func _apply_layout() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = 0
	_bg.offset_top = 0
	_bg.offset_right = 0
	_bg.offset_bottom = 0

	var animated_bg: Control = $AnimatedBackground
	animated_bg.anchor_right = 1.0
	animated_bg.anchor_bottom = 1.0
	# Optional plain-black canvas: hide the animated layer (the black Background ColorRect shows through) and
	# stop its per-frame processing — a hidden node still runs _process, so this makes "off" truly idle.
	var bg_on: bool = SettingsService.get_builder_animated_bg_enabled()
	animated_bg.visible = bg_on
	animated_bg.set_process(bg_on)

	_top_bar.anchor_right = 1.0
	_top_bar.offset_left = 16
	_top_bar.offset_right = -16
	_top_bar.offset_top = 12
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_top_bar.add_theme_constant_override("separation", 12)

	# Title expands to fill space between Back (left) and Status/Save (right).
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_main_layout.anchor_right = 1.0
	_main_layout.anchor_bottom = 1.0
	_main_layout.offset_left = 16
	_main_layout.offset_right = -16
	_main_layout.offset_top = TOP_BAR_HEIGHT + 8
	_main_layout.offset_bottom = -16
	_main_layout.add_theme_constant_override("separation", 12)

	_graph_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph_host.clip_contents = true

	_side_panel.custom_minimum_size = Vector2(SIDE_PANEL_WIDTH, 0)
	_side_panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	_side_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_side_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_side_vbox.add_theme_constant_override("separation", 10)
	_side_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------


func _apply_theme() -> void:
	_bg.color = UITheme.BG

	UITheme.style_label(_title_lbl, UITheme.PURPLE_BRIGHT, 18, true)
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_lbl.clip_text = true  # never let the title (long in rendition mode) overflow into the buttons

	UITheme.style_button(_back_btn, UITheme.MAGENTA)
	UITheme.style_button(_save_btn, UITheme.PURPLE_BRIGHT)
	_save_btn.custom_minimum_size = Vector2(180, 0)

	_status_lbl.add_theme_font_size_override("font_size", 13)
	_status_lbl.visible = false
	# The status toast FLOATS as a centered banner at the top of the GRAPH area (reparented into the graph
	# host) rather than living in the top-bar HBox. That keeps it clear of the toolbar buttons AND confined
	# to the canvas, so it never overlaps the side-panel editor on the right.
	if _status_lbl.get_parent() != _graph_host:
		_status_lbl.reparent(_graph_host)
	_status_lbl.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_status_lbl.offset_top = 8
	_status_lbl.offset_bottom = 36
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_lbl.z_index = 10
	var toast_bg: StyleBoxFlat = StyleBoxFlat.new()
	toast_bg.bg_color = Color(UITheme.PANEL_BG.r, UITheme.PANEL_BG.g, UITheme.PANEL_BG.b, 0.92)
	toast_bg.border_color = UITheme.PURPLE_MID
	toast_bg.set_border_width_all(1)
	toast_bg.set_content_margin_all(6)
	_status_lbl.add_theme_stylebox_override("normal", toast_bg)

	# Side panel background
	var sp_style: StyleBoxFlat = StyleBoxFlat.new()
	sp_style.bg_color = UITheme.PANEL_BG
	sp_style.border_color = UITheme.PURPLE_MID
	sp_style.border_width_left = 1
	sp_style.border_width_right = 1
	sp_style.border_width_top = 1
	sp_style.border_width_bottom = 1
	sp_style.content_margin_left = 14
	sp_style.content_margin_right = 14
	sp_style.content_margin_top = 14
	sp_style.content_margin_bottom = 14
	_side_panel.add_theme_stylebox_override("panel", sp_style)


# ---------------------------------------------------------------------------
# Toolbar (top bar) — Fit + Shortcuts buttons inserted before Save
# ---------------------------------------------------------------------------


# Adds the "Fit" (frame the whole graph) and "Shortcuts" (keybinding reference)
# buttons to the top bar, just left of Save. Created in code so the .tscn stays
# untouched.
func _setup_toolbar_buttons() -> void:
	var fit_btn: Button = Button.new()
	fit_btn.text = "⊡ FIT"
	fit_btn.focus_mode = Control.FOCUS_NONE
	fit_btn.tooltip_text = UITheme.wrap_tip("Frame the whole journey in view")
	UITheme.style_button(fit_btn, UITheme.PURPLE_MID)
	fit_btn.pressed.connect(
		func() -> void:
			if _graph:
				_graph.fit_to_view()
	)
	_top_bar.add_child(fit_btn)
	_top_bar.move_child(fit_btn, _save_btn.get_index())

	var arrange_btn: Button = Button.new()
	arrange_btn.text = "⊞ ARRANGE"
	arrange_btn.focus_mode = Control.FOCUS_NONE
	arrange_btn.tooltip_text = UITheme.wrap_tip(
		"Auto-arrange the graph into tidy layers (Sugiyama). Undoable with Ctrl+Z."
	)
	UITheme.style_button(arrange_btn, UITheme.PURPLE_MID)
	arrange_btn.pressed.connect(_on_arrange_pressed)
	_top_bar.add_child(arrange_btn)
	_top_bar.move_child(arrange_btn, _save_btn.get_index())

	var img_btn: Button = Button.new()
	img_btn.text = "📷 IMAGE"
	img_btn.focus_mode = Control.FOCUS_NONE
	img_btn.tooltip_text = UITheme.wrap_tip(
		"Export a high-res PNG of the whole journey layout (to share)"
	)
	UITheme.style_button(img_btn, UITheme.PURPLE_MID)
	img_btn.pressed.connect(_on_export_image_pressed)
	_top_bar.add_child(img_btn)
	_top_bar.move_child(img_btn, _save_btn.get_index())

	var audit_btn: Button = Button.new()
	audit_btn.text = "⚖ AUDIT"
	audit_btn.focus_mode = Control.FOCUS_NONE
	audit_btn.tooltip_text = UITheme.wrap_tip(
		(
			"Balance report: dead fork paths, unaffordable costs, unobtainable items,"
			+ " unset flags, and rarely-visited content"
		)
	)
	UITheme.style_button(audit_btn, UITheme.PURPLE_MID)
	audit_btn.pressed.connect(_on_audit_pressed)
	_top_bar.add_child(audit_btn)
	_top_bar.move_child(audit_btn, _save_btn.get_index())

	_traffic_btn = Button.new()
	_traffic_btn.text = "🔥 TRAFFIC"
	_traffic_btn.toggle_mode = true
	_traffic_btn.focus_mode = Control.FOCUS_NONE
	_traffic_btn.tooltip_text = UITheme.wrap_tip(
		(
			"Heatmap: tint the graph by how often simulated runs travel each path"
			+ " (red/thick = extremely common, light green/thin = extremely rare)."
			+ " Turns off on a structural edit."
		)
	)
	UITheme.style_button(_traffic_btn, UITheme.PURPLE_MID)
	_traffic_btn.toggled.connect(_on_traffic_toggled)
	_top_bar.add_child(_traffic_btn)
	_top_bar.move_child(_traffic_btn, _save_btn.get_index())

	# 🗒 NOTE, ▭ GROUP and ⌨ SHORTCUTS moved off the toolbar into the canvas right-click context menu
	# (_show_canvas_context_menu) to cut top-bar clutter — they drop at the cursor instead of the view
	# centre. ⊡ FIT, ⊞ ARRANGE and 📷 IMAGE stay here as the frequent / global actions.


# Toggles the audit traffic heatmap overlay. Enabling computes (or reuses) the
# cached audit and paints the Monte-Carlo traffic onto the canvas; a structural
# edit turns it back off (_push_undo) since the percentages no longer match.
func _on_traffic_toggled(on: bool) -> void:
	if not _graph:
		return
	if not on:
		_graph.set_traffic({})
		return
	if (_graph_model.get("nodes", {}) as Dictionary).is_empty():
		_traffic_btn.set_pressed_no_signal(false)
		_show_status("Nothing to map — the journey is empty.", true)
		return
	if _audit_result.is_empty():
		_run_audit()
	var visits: Dictionary = _audit_result.get("visits", {})
	var runs: int = maxi(1, int(visits.get("runs", 1)))
	var traffic: Dictionary = {"nodes": {}, "edges": {}}
	for id: String in visits.get("nodes", {}):
		(traffic["nodes"] as Dictionary)[id] = (
			int((visits["nodes"] as Dictionary)[id]) * 100.0 / runs
		)
	for key: String in visits.get("edges", {}):
		(traffic["edges"] as Dictionary)[key] = (
			int((visits["edges"] as Dictionary)[key]) * 100.0 / runs
		)
	_graph.set_traffic(traffic)


# Auto-arranges the whole graph into tidy Sugiyama layers (rows by depth, crossings reduced, x
# aligned to neighbours). One undo step; frames the result. Manual positions are replaced — Ctrl+Z
# restores them.
func _on_arrange_pressed() -> void:
	if not _graph or (_graph_model.get("nodes", {}) as Dictionary).is_empty():
		return
	_push_undo()
	# Capture each frame's current members BEFORE the relayout, so the frame can re-wrap them after.
	var groups: Array = _graph_model.get("groups", [])
	var members: Array = []
	var frame_comments: Array = []  # note indices inside each frame — so the re-fit wraps them too
	for g: Dictionary in groups:
		# A collapsed frame's members are frozen; an expanded one wraps whatever's currently inside.
		if g.get("collapsed", false):
			members.append((g.get("members", []) as Array).duplicate())
		else:
			members.append(_nodes_in_rect(g.get("rect", Rect2())))
		frame_comments.append(_comments_in_rect(g.get("rect", Rect2())))
	# Snapshot node positions so pinned notes can follow their node through the relayout.
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var old_pos: Dictionary = {}
	for id: String in nodes:
		old_pos[id] = (nodes[id] as Dictionary).get("pos", Vector2.ZERO)
	GraphLayout.auto_layout(_graph_model)
	# Pinned notes travel with their node: shift each by the delta its node moved.
	for c: Dictionary in _graph_model.get("comments", []):
		var nid: String = str(c.get("node_id", ""))
		if nid != "" and old_pos.has(nid) and nodes.has(nid):
			var moved: Vector2 = (nodes[nid] as Dictionary).get("pos", Vector2.ZERO) - old_pos[nid]
			c["pos"] = (c.get("pos", Vector2.ZERO) as Vector2) + moved
	# Re-fit each (non-empty) frame around its members' new positions — plus any notes inside it — so
	# nothing ends up outside the frame.
	for gi: int in groups.size():
		var ids: Array = members[gi]
		var cidx: Array = frame_comments[gi]
		if not (ids.is_empty() and cidx.is_empty()):
			(groups[gi] as Dictionary)["rect"] = _frame_rect_for(_content_bounds(ids, cidx))
	# Collapsed frames: re-apply their space-reclaim reflow against the fresh layout (nodes AND the other
	# frames below), so a later expand reverses against the arranged positions, not stale ones.
	for gi: int in groups.size():
		var g2: Dictionary = groups[gi]
		if g2.get("collapsed", false):
			g2["members"] = members[gi]
			_apply_frame_reflow(g2)
			_apply_frame_shift(g2, gi)
	_refresh_graph()
	_graph.call_deferred("fit_to_view")
	_show_status("Arranged the graph into layers. Ctrl+Z to undo.", false)


# ---------------------------------------------------------------------------
# Journey audit (⚖) — balance report
# ---------------------------------------------------------------------------

# The last audit result, reused by the side panel's ⚖ ON ARRIVAL block.
# Cleared on every structural mutation (_push_undo) — {} means "stale/none".
var _audit_result: Dictionary = {}
var _traffic_btn: Button = null  # 🔥 heatmap toggle; forced off when the cache invalidates


func _on_audit_pressed() -> void:
	if not _graph or (_graph_model.get("nodes", {}) as Dictionary).is_empty():
		_show_status("Nothing to audit — the journey is empty.", true)
		return
	_show_audit_modal(_run_audit())


# Runs JourneyAudit over the live graph model and caches the result. Baseline
# round scores/lengths are computed here (file I/O stays out of the pure core):
# each round's funscript is parsed once.
func _run_audit() -> Dictionary:
	var items: Dictionary = {}
	for item_id: String in InventoryService.GetAllItemIds():
		var item_data: Dictionary = InventoryService.GetItemData(item_id)
		items[item_id] = {
			"price": int(item_data.get("price", 0)),
			"kind": str(item_data.get("kind", "")),
		}

	var round_scores: Dictionary = {}
	var round_lengths: Dictionary = {}
	var round_score_bounds: Dictionary = {}
	var round_length_bounds: Dictionary = {}
	for nid: String in _graph_model.get("nodes", {}):
		var node: Dictionary = _graph_model["nodes"][nid]
		if str(node.get("type", "")) != "round":
			continue
		var data: Dictionary = node.get("data", {})
		# A pool ("encounter") round has no funscript of its own — the runtime rolls one of its
		# entries — so scoring it off the round's (empty) funscript_path would count it as a
		# zero-score, zero-length round. Derive both from the entries instead.
		if str(data.get("round_type", "normal")) == "pool":
			var pstats: Dictionary = _pool_round_stats(data)
			if not pstats.is_empty():
				round_scores[nid] = int(pstats["score_avg"])
				round_lengths[nid] = int(pstats["len_avg"])
				round_score_bounds[nid] = {"lo": pstats["score_lo"], "hi": pstats["score_hi"]}
				round_length_bounds[nid] = {"lo": pstats["len_lo"], "hi": pstats["len_hi"]}
			continue
		var fs_path: String = str(data.get("funscript_path", ""))
		if fs_path != "" and FileAccess.file_exists(fs_path):
			var actions: Array = JourneyData.read_funscript_actions(fs_path)
			# Pending segments ship baked — score and time what will actually play.
			actions = JourneyData.build_edl_action_points(
				actions, JourneyData.normalize_segments(data)
			)
			round_scores[nid] = JourneyAudit.baseline_score(actions)
			if not actions.is_empty():
				round_lengths[nid] = int((actions[-1] as Vector2).x)

	_audit_result = (
		JourneyAudit
		. audit(
			_graph_model,
			{
				"items": items,
				"round_scores": round_scores,
				"round_lengths": round_lengths,
				"round_score_bounds": round_score_bounds,
				"round_length_bounds": round_length_bounds,
			}
		)
	)
	return _audit_result


# Baseline score + funscript length across a pool round's entries. The runtime rolls ONE entry
# by weight, so the audit models the weighted MEAN (the expected value the Monte-Carlo pass
# uses) plus the min/max an actual run can hit (the interval walk's real bounds). An entry with
# a missing/unreadable funscript contributes 0, exactly as a round with no script would.
# Entries never carry a trim (the save bakes them untrimmed). Returns {} for an empty pool.
func _pool_round_stats(data: Dictionary) -> Dictionary:
	var entries: Array = data.get("pool_entries", [])
	if entries.is_empty():
		return {}
	var score_lo: int = -1
	var score_hi: int = 0
	var len_lo: int = -1
	var len_hi: int = 0
	var score_wsum: float = 0.0
	var len_wsum: float = 0.0
	var wtotal: float = 0.0
	for e: Dictionary in entries:
		var s: int = 0
		var ms: int = 0
		var p: String = str(e.get("funscript_path", ""))
		if p != "" and FileAccess.file_exists(p):
			var actions: Array = JourneyData.read_funscript_actions(p)
			s = JourneyAudit.baseline_score(actions)
			if not actions.is_empty():
				ms = int((actions[-1] as Vector2).x)
		var w: float = float(maxi(1, int(e.get("weight", 1))))
		score_wsum += s * w
		len_wsum += ms * w
		wtotal += w
		score_lo = s if score_lo < 0 else mini(score_lo, s)
		score_hi = maxi(score_hi, s)
		len_lo = ms if len_lo < 0 else mini(len_lo, ms)
		len_hi = maxi(len_hi, ms)
	if wtotal <= 0.0:
		return {}
	return {
		"score_avg": roundi(score_wsum / wtotal),
		"len_avg": roundi(len_wsum / wtotal),
		"score_lo": maxi(0, score_lo),
		"score_hi": score_hi,
		"len_lo": maxi(0, len_lo),
		"len_hi": len_hi,
	}


# Arrival-state summary at a node for the side panel: coins/score bounds from
# the interval walk, averages + reach share from the Monte-Carlo pass. Returns
# {} when no audit is cached (never run, or invalidated by a structural edit)
# or the node wasn't reachable in the analysis.
func audit_arrival_info(node_id: String) -> Dictionary:
	if _audit_result.is_empty():
		return {}
	var coins: Dictionary = (_audit_result.get("coins", {}) as Dictionary).get(node_id, {})
	if coins.is_empty():
		return {}
	var score: Dictionary = (_audit_result.get("last_score", {}) as Dictionary).get(node_id, {})
	var visits: Dictionary = _audit_result.get("visits", {})
	var runs: int = maxi(1, int(visits.get("runs", 1)))
	return {
		"coins_lo": int(coins["lo"]),
		"coins_hi": int(coins["hi"]),
		"coins_avg": float((visits.get("avg_arrival_coins", {}) as Dictionary).get(node_id, 0.0)),
		"score_lo": int(score.get("lo", 0)),
		"score_hi": int(score.get("hi", 0)),
		"score_avg": float((visits.get("avg_arrival_score", {}) as Dictionary).get(node_id, 0.0)),
		"seen_pct": int((visits.get("nodes", {}) as Dictionary).get(node_id, 0)) * 100.0 / runs,
	}


# Side-panel refresh button: recompute the audit, then rebuild the panel so
# the ⚖ ON ARRIVAL block shows the fresh numbers.
func refresh_arrival_audit(node_id: String) -> void:
	_run_audit()
	_side_renderer.show_graph_node_editor(node_id)


# The audit report: findings grouped worst-first, each anchored to its node by
# display name. Advisory only — nothing here blocks saving.
func _show_audit_modal(result: Dictionary) -> void:
	var parts: Dictionary = UITheme.build_centered_modal(
		"JOURNEY AUDIT", UITheme.PURPLE_BRIGHT, Vector2i(760, 560)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]

	var findings: Array = result.get("findings", [])
	var runs: int = int((result.get("visits", {}) as Dictionary).get("runs", 0))

	var stats: Dictionary = result.get("stats", {})
	if not stats.is_empty():
		vbox.add_child(_audit_stats_strip(stats))
		var sep: HSeparator = HSeparator.new()
		sep.add_theme_color_override("separator", UITheme.SEPARATOR)
		vbox.add_child(sep)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	var list: VBoxContainer = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)

	# Clicking a finding closes the report and locates its node on the canvas.
	var jump := func(node_id: String) -> void:
		if node_id == "" or not (_graph_model.get("nodes", {}) as Dictionary).has(node_id):
			return
		modal.queue_free()
		if _graph:
			_graph.select_graph_node(node_id)
			_graph.center_on(node_id)

	if findings.is_empty():
		var ok_lbl: Label = Label.new()
		ok_lbl.text = "NO ISSUES FOUND — every gate is reachable and affordable."
		UITheme.style_label(ok_lbl, UITheme.OK, 13, true)
		ok_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		list.add_child(ok_lbl)
	else:
		# Worst first: dead content, then per-route warnings, then info.
		for severity: String in [
			JourneyAudit.SEV_DEAD, JourneyAudit.SEV_WARN, JourneyAudit.SEV_INFO
		]:
			for f: Dictionary in findings:
				if str(f.get("severity", "")) == severity:
					list.add_child(_audit_finding_row(f, jump))

	var foot: Label = Label.new()
	foot.text = (
		"Baseline model: completes every round, endures curses, buys only what locked paths ahead require."
		+ (" Traffic from %d simulated runs." % runs if runs > 0 else "")
	)
	UITheme.style_label(foot, UITheme.DARK_TEXT, 10, false)
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(foot)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	var close_btn: Button = Button.new()
	close_btn.text = "CLOSE"
	close_btn.custom_minimum_size = Vector2(120, 0)
	UITheme.style_button(close_btn, UITheme.PURPLE_MID)
	close_btn.pressed.connect(modal.queue_free)
	btn_row.add_child(close_btn)
	vbox.add_child(btn_row)

	add_child(modal)


func _audit_finding_row(f: Dictionary, jump: Callable) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var sev: String = str(f.get("severity", ""))
	var tag: Label = Label.new()
	var tag_color: Color = UITheme.CYAN
	var tag_text: String = "INFO"
	if sev == JourneyAudit.SEV_DEAD:
		tag_color = UITheme.ERROR_SOFT
		tag_text = "DEAD"
	elif sev == JourneyAudit.SEV_WARN:
		tag_color = UITheme.AMBER
		tag_text = "WARN"
	tag.text = tag_text
	tag.custom_minimum_size = Vector2(52, 0)
	UITheme.style_label(tag, tag_color, 11, true)
	row.add_child(tag)

	var body: Label = Label.new()
	body.text = "%s — %s" % [_audit_node_label(str(f.get("node_id", ""))), str(f.get("msg", ""))]
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(body, UITheme.WHITE_SOFT, 12, false)
	row.add_child(body)

	# Whole-row click → jump to the node (labels ignore mouse, so the row gets it).
	var node_id: String = str(f.get("node_id", ""))
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.tooltip_text = UITheme.wrap_tip("Click to locate this node on the canvas")
	row.gui_input.connect(
		func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed:
				jump.call(node_id)
	)
	return row


# A node's display name for the report: its authored name/title, else its type.
func _audit_node_label(node_id: String) -> String:
	var node: Dictionary = (_graph_model.get("nodes", {}) as Dictionary).get(node_id, {})
	var data: Dictionary = node.get("data", {})
	var name: String = str(data.get("name", data.get("title", ""))).strip_edges()
	var type: String = str(node.get("type", "?")).to_upper()
	return '%s "%s"' % [type, name] if name != "" else type


# The journey-wide summary above the findings: a 2×2 grid of stat cards (big
# average, small range detail), an endings ratio bar, and the save-spacing bar.
# Route bounds come from the interval walk, averages from the simulated runs.
func _audit_stats_strip(stats: Dictionary) -> Control:
	var strip: VBoxContainer = VBoxContainer.new()
	strip.add_theme_constant_override("separation", 8)

	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	strip.add_child(grid)

	var coins: Dictionary = stats.get("end_coins", {})
	if coins.has("lo"):
		grid.add_child(
			_audit_stat_card(
				"COINS AT END",
				"♦ %d" % roundi(coins["avg"]),
				"range ♦ %d – %d" % [coins["lo"], coins["hi"]]
			)
		)

	var score: Dictionary = stats.get("total_score", {})
	var best: Dictionary = stats.get("best_round", {})
	if score.has("lo"):
		var best_line: String = ""
		if str(best.get("node_id", "")) != "":
			best_line = (
				"best: %s (%d)" % [_audit_node_label(str(best["node_id"])), int(best["score"])]
			)
		grid.add_child(
			_audit_stat_card(
				"TOTAL SCORE",
				"%d" % roundi(score["avg"]),
				"range %d – %d" % [score["lo"], score["hi"]],
				best_line
			)
		)

	var rounds: Dictionary = stats.get("rounds", {})
	var dur: Dictionary = stats.get("duration_ms", {})
	if rounds.has("lo"):
		var sub: String = "%d – %d rounds" % [rounds["lo"], rounds["hi"]]
		if dur.has("lo") and int(dur["hi"]) > 0:
			sub += "  ·  %s – %s" % [_audit_mmss(int(dur["lo"])), _audit_mmss(int(dur["hi"]))]
		grid.add_child(_audit_stat_card("RUN LENGTH", "≈ %.1f rounds" % float(rounds["avg"]), sub))

	var cp: Dictionary = stats.get("checkpoints", {})
	if not cp.is_empty():
		var count: int = int(cp.get("count", 0))
		var value: String = "%d saves" % count if count > 0 else "none"
		var sub: String = ""
		if int(cp.get("longest_ms", 0)) > 0:
			sub = (
				"stretch %s – %s  ·  avg %s"
				% [
					_audit_mmss(int(cp.get("shortest_ms", 0))),
					_audit_mmss(int(cp.get("longest_ms", 0))),
					_audit_mmss(roundi(float(cp.get("avg_ms", 0.0)))),
				]
			)
		grid.add_child(_audit_stat_card("CHECKPOINTS", value, sub))

	var endings: Array = stats.get("endings", [])
	if endings.size() > 1:
		strip.add_child(_audit_endings_bar(endings))

	var cp_bar: Dictionary = stats.get("cp_bar", {})
	if int(cp_bar.get("total_ms", 0)) > 0 and (cp_bar.get("segments", []) as Array).size() > 0:
		strip.add_child(_audit_checkpoint_bar(cp_bar))

	return strip


# One stat card: dim caption, big value, small detail line(s). `sub2_text`
# adds a second detail line when non-empty (long details bleed off one line).
func _audit_stat_card(
	caption_text: String, value_text: String, sub_text: String, sub2_text: String = ""
) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = UITheme.CARD_BG
	style.border_color = UITheme.PURPLE_DARK
	style.set_border_width_all(1)
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	panel.add_child(col)

	var caption: Label = Label.new()
	caption.text = caption_text
	UITheme.style_label(caption, UITheme.PURPLE_MID, 10, true)
	col.add_child(caption)

	var value: Label = Label.new()
	value.text = value_text
	UITheme.style_label(value, UITheme.WHITE_SOFT, 18, true)
	col.add_child(value)

	var sub: Label = Label.new()
	sub.text = sub_text
	sub.clip_text = true
	UITheme.style_label(sub, UITheme.DARK_TEXT, 10, false)
	col.add_child(sub)

	if sub2_text != "":
		var sub2: Label = Label.new()
		sub2.text = sub2_text
		sub2.clip_text = true
		UITheme.style_label(sub2, UITheme.DARK_TEXT, 10, false)
		col.add_child(sub2)
	return panel


# Endings as a stacked ratio bar: one tinted segment per ending, width by its
# share of simulated runs, labelled inline (name + %).
func _audit_endings_bar(endings: Array) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var caption: Label = Label.new()
	caption.text = "ENDINGS  (SHARE OF SIMULATED RUNS)"
	UITheme.style_label(caption, UITheme.PURPLE_MID, 10, true)
	box.add_child(caption)

	var bar: HBoxContainer = HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	bar.custom_minimum_size = Vector2(0, 24)
	var palette: Array = [
		UITheme.PURPLE_BRIGHT, UITheme.CYAN, UITheme.MAGENTA, UITheme.AMBER, UITheme.TOXIC_GREEN
	]
	for i: int in endings.size():
		var e: Dictionary = endings[i]
		var seg: PanelContainer = PanelContainer.new()
		var seg_style: StyleBoxFlat = StyleBoxFlat.new()
		seg_style.bg_color = (palette[i % palette.size()] as Color).darkened(0.45)
		seg_style.set_corner_radius_all(UITheme.CORNER_RADIUS)
		seg.add_theme_stylebox_override("panel", seg_style)
		seg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		seg.size_flags_stretch_ratio = maxf(0.02, float(e["pct"]))
		seg.tooltip_text = UITheme.wrap_tip(
			"%s — %.1f%%" % [_audit_node_label(str(e["node_id"])), float(e["pct"])]
		)
		var lbl: Label = Label.new()
		lbl.text = "%s  %.0f%%" % [_audit_node_label(str(e["node_id"])), float(e["pct"])]
		lbl.clip_text = true
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UITheme.style_label(lbl, UITheme.WHITE_SOFT, 10, false)
		seg.add_child(lbl)
		bar.add_child(seg)
	box.add_child(bar)
	return box


# Save spacing along the worst-case (longest-playtime) route: one segment per
# checkpoint stretch, width by playtime, tinted by how close the stretch runs
# to the 30-minute finding threshold; ◆ ticks mark the checkpoints between.
func _audit_checkpoint_bar(cp_bar: Dictionary) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var caption: Label = Label.new()
	caption.text = "CHECKPOINT SPACING  (WORST-CASE ROUTE)"
	UITheme.style_label(caption, UITheme.PURPLE_MID, 10, true)
	box.add_child(caption)

	var bar: HBoxContainer = HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	bar.custom_minimum_size = Vector2(0, 14)
	var segments: Array = cp_bar.get("segments", [])
	for i: int in segments.size():
		if i > 0:
			var tick: Label = Label.new()
			tick.text = "◆"
			tick.tooltip_text = UITheme.wrap_tip("Checkpoint")
			UITheme.style_label(tick, UITheme.CYAN, 11, false)
			bar.add_child(tick)
		var seg: Dictionary = segments[i]
		var ms: int = int(seg["ms"])
		var tint: Color = UITheme.TOXIC_GREEN
		if ms > JourneyAudit.CHECKPOINT_GAP_MS:
			tint = UITheme.ERROR_SOFT
		elif ms > JourneyAudit.CHECKPOINT_GAP_MS * 2 / 3:
			tint = UITheme.AMBER
		var block: PanelContainer = PanelContainer.new()
		var seg_style: StyleBoxFlat = StyleBoxFlat.new()
		seg_style.bg_color = tint.darkened(0.5)
		seg_style.set_corner_radius_all(UITheme.CORNER_RADIUS)
		block.add_theme_stylebox_override("panel", seg_style)
		block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		block.size_flags_stretch_ratio = maxf(0.02, float(ms))
		block.tooltip_text = UITheme.wrap_tip(
			"%d rounds · %s" % [int(seg["rounds"]), _audit_mmss(ms)]
		)
		bar.add_child(block)
	box.add_child(bar)
	return box


func _audit_mmss(ms: int) -> String:
	var total_s: int = ms / 1000
	return "%d:%02d" % [total_s / 60, total_s % 60]


# ── Canvas right-click context menu ──────────────────────────────────────────


# GraphView reports a right-click on empty canvas with the world position under the cursor; open the
# menu there. Houses the old 🗒 NOTE / ▭ GROUP / ⌨ SHORTCUTS toolbar actions plus node creation, all
# dropping at the click position.
func _on_canvas_context_menu_requested(world_pos: Vector2) -> void:
	_show_canvas_context_menu(world_pos)


# A small styled popup at the mouse: add a round / shop / storyboard / fork, a note or a group at the
# cursor, or open the shortcuts overlay. The PopupPanel closes itself on an outside click.
func _show_canvas_context_menu(world_pos: Vector2) -> void:
	if not _graph:
		return
	var popup: PopupPanel = PopupPanel.new()
	popup.wrap_controls = true
	add_child(popup)

	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG
	panel_style.border_color = UITheme.PURPLE_BRIGHT
	panel_style.border_width_left = 2
	panel_style.border_width_right = 2
	panel_style.border_width_top = 2
	panel_style.border_width_bottom = 2
	panel_style.content_margin_left = 8
	panel_style.content_margin_right = 8
	panel_style.content_margin_top = 8
	panel_style.content_margin_bottom = 8
	popup.add_theme_stylebox_override("panel", panel_style)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.custom_minimum_size = Vector2(190, 0)
	popup.add_child(vbox)

	# Add-node actions — each drops a fresh node centred on the click.
	for spec: Array in [
		["＋ ROUND", "round"],
		["＋ SHOP", "shop"],
		["＋ STORYBOARD", "storyboard"],
		["＋ FORK", "fork"],
		["＋ CHECKPOINT", "checkpoint"],
		["＋ LOOP", "loop"],
	]:
		var t: String = spec[1]
		var node_b: Button = _ctx_menu_button(
			spec[0],
			UITheme.PURPLE_BRIGHT,
			func() -> void:
				popup.queue_free()
				if t == "loop":
					_create_loop_pair(world_pos)  # a linked Loop Start + Loop End
				else:
					_create_graph_node(t, world_pos)
		)
		vbox.add_child(node_b)

	vbox.add_child(_ctx_menu_separator())
	var note_b: Button = _ctx_menu_button(
		"🗒 NOTE",
		UITheme.AMBER,
		func() -> void:
			popup.queue_free()
			_add_comment(world_pos)
	)
	vbox.add_child(note_b)
	var group_b: Button = _ctx_menu_button(
		"▭ GROUP",
		UITheme.PURPLE_MID,
		func() -> void:
			popup.queue_free()
			_add_frame(world_pos)
	)
	vbox.add_child(group_b)

	vbox.add_child(_ctx_menu_separator())
	var keys_b: Button = _ctx_menu_button(
		"⌨ SHORTCUTS",
		UITheme.PURPLE_MID,
		func() -> void:
			popup.queue_free()
			_show_shortcuts_overlay()
	)
	vbox.add_child(keys_b)

	popup.reset_size()
	popup.position = Vector2i(get_global_mouse_position())
	popup.popup()


# Right-click on a node → a small popup to make it the journey's start. The "start" is the single
# entry point the runtime plays from and the save-time reachability check walks out from; every node
# not reachable from it is flagged as an unplayable island. Mirrors the canvas menu's styling.
func _on_node_context_menu_requested(node_id: String) -> void:
	_show_node_context_menu(node_id)


func _show_node_context_menu(node_id: String) -> void:
	if not _graph or not (_graph_model.get("nodes", {}) as Dictionary).has(node_id):
		return
	var popup: PopupPanel = PopupPanel.new()
	popup.wrap_controls = true
	add_child(popup)

	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG
	panel_style.border_color = UITheme.PURPLE_BRIGHT
	panel_style.border_width_left = 2
	panel_style.border_width_right = 2
	panel_style.border_width_top = 2
	panel_style.border_width_bottom = 2
	panel_style.content_margin_left = 8
	panel_style.content_margin_right = 8
	panel_style.content_margin_top = 8
	panel_style.content_margin_bottom = 8
	popup.add_theme_stylebox_override("panel", panel_style)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.custom_minimum_size = Vector2(190, 0)
	popup.add_child(vbox)

	var already_start: bool = str(_graph_model.get("start", "")) == node_id
	var start_b: Button = _ctx_menu_button(
		"✓ START NODE" if already_start else "★ SET AS START",
		UITheme.CYAN,
		func() -> void:
			popup.queue_free()
			_set_node_as_start(node_id)
	)
	vbox.add_child(start_b)

	# FINISH (aftercare-sequence entry) — only a round or storyboard can be the entry.
	var node_type: String = str((_graph_model["nodes"][node_id] as Dictionary).get("type", ""))
	if node_type == "round" or node_type == "storyboard":
		var already_finish: bool = _journey_finish_node == node_id
		var finish_b: Button = _ctx_menu_button(
			"✓ FINISH NODE  (clear)" if already_finish else "🏁 SET AS FINISH",
			UITheme.MAGENTA,
			func() -> void:
				popup.queue_free()
				_toggle_node_as_finish(node_id)
		)
		vbox.add_child(finish_b)

	# Extract → rendition (base journeys, non-start node); Merge → base (an overlay node in rendition mode).
	if not _rendition_mode and not already_start:
		var extract_b: Button = _ctx_menu_button(
			"⑂ EXTRACT TO RENDITION",
			UITheme.CYAN,
			func() -> void:
				popup.queue_free()
				if not _selected_graph_node_ids.has(node_id):
					_graph.select_graph_node(node_id)
				_begin_extract_to_rendition()
		)
		vbox.add_child(extract_b)
	elif _rendition_mode and not _rendition_parent_ids.has(node_id):
		var merge_b: Button = _ctx_menu_button(
			"⤺ MERGE INTO BASE",
			UITheme.CYAN,
			func() -> void:
				popup.queue_free()
				_begin_merge_to_base(node_id)
		)
		vbox.add_child(merge_b)

	popup.reset_size()
	popup.position = Vector2i(get_global_mouse_position())
	popup.popup()


# Designates `node_id` as the start node. Undoable; refreshes so the START badge moves and the
# reachability ("unreachable island") badges re-evaluate against the new entry point.
func _set_node_as_start(node_id: String) -> void:
	if str(_graph_model.get("start", "")) == node_id:
		return
	_push_undo()
	_graph_model["start"] = node_id
	_refresh_graph()
	_show_status("Start set — the journey now begins at this node.", false)


# Sets (or clears, if already set) `node_id` as the FINISH aftercare-sequence entry. Setting also flips
# on the journey's "allow finish" so a right-click is all it takes for the button to appear. Not undoable
# — it's a journey setting (like the map toggle / the finish dropdown), not a graph-structure change. The
# refresh re-badges the node and re-evaluates reachability (the finish subtree is exempt from unreachable).
func _toggle_node_as_finish(node_id: String) -> void:
	if _journey_finish_node == node_id:
		_journey_finish_node = ""
		_refresh_graph()
		_show_status("Finish node cleared.", false)
	else:
		_journey_finish_node = node_id
		_journey_allow_finish = true
		_refresh_graph()
		_show_status(
			"Finish set — the FINISH button plays the aftercare sequence from here.", false
		)


# One left-aligned, full-width button for the canvas context menu.
func _ctx_menu_button(text: String, accent: Color, on_press: Callable) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(b, accent)
	b.pressed.connect(on_press)
	return b


# A thin divider between context-menu groups.
func _ctx_menu_separator() -> HSeparator:
	var line: HSeparator = HSeparator.new()
	var sb: StyleBoxLine = StyleBoxLine.new()
	sb.color = UITheme.SEPARATOR
	sb.thickness = 1
	line.add_theme_stylebox_override("separator", sb)
	return line


# ── Canvas comments (sticky notes) ───────────────────────────────────────────

var _selected_comment_idx: int = -1  # the note whose editor is open; Delete/Backspace targets it
var _selected_frame_idx: int = -1  # the group frame whose editor is open; Delete/Backspace targets it


# Canvas-menu 🗒 NOTE — drops a new empty sticky note (at the right-click cursor, else the view centre)
# and opens it.
func _add_comment(at_world: Variant = null) -> void:
	if not _graph:
		return
	_push_undo()
	if not _graph_model.has("comments"):
		_graph_model["comments"] = []
	var comments: Array = _graph_model["comments"]
	var pos: Vector2 = at_world if at_world is Vector2 else _graph.view_center_world()
	comments.append({"pos": GraphLayout.snap(pos), "text": ""})
	_selected_comment_idx = comments.size() - 1
	_refresh_graph()
	_side_renderer.show_comment_editor(_selected_comment_idx)


# A sticky note was clicked (or dragged) — show its editor and make it the active selection (so node
# selection is dropped and Delete/Backspace removes the note).
func _on_comment_clicked(idx: int) -> void:
	_selected_graph_node_ids = []
	_selected_graph_node_id = ""
	_selected_comment_idx = idx
	_selected_frame_idx = -1
	_side_renderer.show_comment_editor(idx)


# Side-panel 🗑 DELETE NOTE, or Delete/Backspace while a note is selected.
func _delete_comment(idx: int) -> void:
	var comments: Array = _graph_model.get("comments", [])
	if idx < 0 or idx >= comments.size():
		return
	_push_undo()
	comments.remove_at(idx)
	_selected_comment_idx = -1
	_refresh_graph()
	_side_renderer.show_journey_info_panel()


# Unpin a note from its node — it stops following the node and stays where it is.
func _unpin_comment(idx: int) -> void:
	var comments: Array = _graph_model.get("comments", [])
	if idx < 0 or idx >= comments.size():
		return
	_push_undo()
	(comments[idx] as Dictionary).erase("node_id")
	_refresh_graph()
	_side_renderer.show_comment_editor(idx)  # re-render the editor (now with the pin hint)


# ── Group frames ─────────────────────────────────────────────────────────────


# Canvas-menu ▭ GROUP — wraps the current selection, else drops a labelled group frame (at the
# right-click cursor, else the view centre) and opens it.
func _add_frame(at_world: Variant = null) -> void:
	if not _graph:
		return
	_push_undo()
	if not _graph_model.has("groups"):
		_graph_model["groups"] = []
	var groups: Array = _graph_model["groups"]
	var rect: Rect2
	if not _selected_graph_node_ids.is_empty():
		# Wrap the selected nodes: their bounding box + padding (extra at the top for the header bar).
		rect = _frame_rect_for(_selected_nodes_bounds())
		_graph.deselect_nodes_silent()
		_selected_graph_node_ids = []
		_selected_graph_node_id = ""
	else:
		var fsize: Vector2 = Vector2(360, 240)
		var centre: Vector2 = at_world if at_world is Vector2 else _graph.view_center_world()
		rect = Rect2(GraphLayout.snap(centre - fsize * 0.5), fsize)
	groups.append({"rect": rect, "label": ""})
	_selected_comment_idx = -1
	_selected_frame_idx = groups.size() - 1
	_refresh_graph()
	_side_renderer.show_frame_editor(_selected_frame_idx)


# A group frame was clicked or dragged — show its editor and make it the active selection.
func _on_frame_clicked(idx: int) -> void:
	_selected_graph_node_ids = []
	_selected_graph_node_id = ""
	_selected_comment_idx = -1
	_selected_frame_idx = idx
	_side_renderer.show_frame_editor(idx)


# Side-panel 🗑 DELETE GROUP, or Delete/Backspace while a frame is selected. Removes the frame only —
# the nodes inside it are untouched.
func _delete_frame(idx: int) -> void:
	var groups: Array = _graph_model.get("groups", [])
	if idx < 0 or idx >= groups.size():
		return
	_push_undo()
	groups.remove_at(idx)
	_selected_frame_idx = -1
	_refresh_graph()
	_side_renderer.show_journey_info_panel()


# Bounding box of the currently-selected nodes (to auto-size a frame around them).
func _selected_nodes_bounds() -> Rect2:
	return _nodes_bounds(_selected_graph_node_ids)


# Bounding box of a set of node ids.
func _nodes_bounds(ids: Array) -> Rect2:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var rect: Rect2 = Rect2()
	var first: bool = true
	for id: String in ids:
		if nodes.has(id):
			var nr: Rect2 = Rect2(
				(nodes[id] as Dictionary).get("pos", Vector2.ZERO),
				Vector2(GraphView.NODE_WIDTH, GraphView.NODE_HEIGHT)
			)
			rect = nr if first else rect.merge(nr)
			first = false
	return rect


# Sticky-note indices whose position is inside `rect` — a group's note membership.
func _comments_in_rect(rect: Rect2) -> Array:
	var indices: Array = []
	var comments: Array = _graph_model.get("comments", [])
	for ci: int in comments.size():
		if rect.has_point((comments[ci] as Dictionary).get("pos", Vector2.ZERO)):
			indices.append(ci)
	return indices


# Bounding box over a set of nodes AND a set of sticky-notes, so a group frame can wrap the notes inside it
# too. A note uses its position + a nominal card size (width is fixed; height varies, so the approximate
# height keeps the frame from clipping the note).
func _content_bounds(node_ids: Array, comment_indices: Array) -> Rect2:
	var rect: Rect2 = _nodes_bounds(node_ids)
	var first: bool = node_ids.is_empty() or rect.size == Vector2.ZERO
	var comments: Array = _graph_model.get("comments", [])
	var note_size: Vector2 = Vector2(GraphView.COMMENT_WIDTH, 72.0)
	for ci: int in comment_indices:
		if ci >= 0 and ci < comments.size():
			var cr: Rect2 = Rect2((comments[ci] as Dictionary).get("pos", Vector2.ZERO), note_size)
			rect = cr if first else rect.merge(cr)
			first = false
	return rect


# Node ids whose centre is inside `rect` — frame membership (mirrors GraphView._nodes_in_frame_rect).
func _nodes_in_rect(rect: Rect2) -> Array:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var ids: Array = []
	var half: Vector2 = Vector2(GraphView.NODE_WIDTH, GraphView.NODE_HEIGHT) * 0.5
	for id: String in nodes:
		if rect.has_point(((nodes[id] as Dictionary).get("pos", Vector2.ZERO) as Vector2) + half):
			ids.append(id)
	return ids


# A frame rect wrapping a node bounding box: padding all round + extra room at the top for the header.
func _frame_rect_for(bb: Rect2) -> Rect2:
	var pad: float = 30.0
	var r: Rect2 = Rect2(
		bb.position - Vector2(pad, pad + GraphView.FRAME_HEADER_H),
		bb.size + Vector2(pad * 2.0, pad * 2.0 + GraphView.FRAME_HEADER_H)
	)
	r.position = GraphLayout.snap(r.position)
	r.size = GraphLayout.snap(r.size)
	return r


# Header chevron / side-panel button — collapse or expand a group (hides or shows its nodes).
func _on_frame_toggle_collapse(idx: int) -> void:
	var groups: Array = _graph_model.get("groups", [])
	if idx < 0 or idx >= groups.size():
		return
	_push_undo()
	var g: Dictionary = groups[idx]
	var now_collapsed: bool = not bool(g.get("collapsed", false))
	g["collapsed"] = now_collapsed
	# Freeze the membership when collapsing so the hidden set can't change as the bar is moved; drop it
	# on expand.
	if now_collapsed:
		# Freeze membership FIRST: a node parked in the freed space was shoved clear of the frame by the
		# last expand's make-room, so it sits below the frame here and is excluded — never re-absorbed.
		g["members"] = _nodes_in_rect(g.get("rect", Rect2()))
		_undo_expand_pushout(g)  # parked node(s) back to the freed space; nudged-aside nodes back up
		_apply_frame_reflow(g)  # pull the nodes below up to the collapsed bar…
		_apply_frame_shift(g, idx)  # …and the OTHER group frames below, so they ride along with their nodes
	else:
		_undo_frame_reflow(g)  # push the nodes back down to make room for the revealed body…
		_undo_frame_shift(g)  # …and the group frames below back down (reverses the collapse shift)
		_push_parked_nodes_out(g)  # shove any node parked in the footprint clear of the frame (make room)
		g.erase("members")
	_selected_frame_idx = idx
	_refresh_graph()
	_side_renderer.show_frame_editor(idx)


# Shifts every non-excluded node at or below `threshold_y` by `dy` on the y axis.
func _shift_nodes_below(threshold_y: float, dy: float, exclude_ids: Array) -> Array:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var excl: Dictionary = {}
	for id: String in exclude_ids:
		excl[id] = true
	var moved: Array = []
	for id: String in nodes:
		if excl.has(id):
			continue
		var p: Vector2 = (nodes[id] as Dictionary).get("pos", Vector2.ZERO)
		if p.y >= threshold_y:
			(nodes[id] as Dictionary)["pos"] = Vector2(p.x, p.y + dy)
			moved.append(id)
	return moved


# Collapse reflow: slide everything below the frame up so it sits just under the collapsed bar. The
# frozen members stay put (they're hidden under the bar). Reversed by _undo_frame_reflow on expand.
func _apply_frame_reflow(g: Dictionary) -> void:
	var rect: Rect2 = g.get("rect", Rect2())
	var delta: float = rect.size.y - GraphView.FRAME_HEADER_H
	if delta <= 0.0:
		g["shift_ids"] = []
		g["shift_amt"] = 0.0
		return
	# Record exactly which nodes moved and by how much, so expand reverses it even if the bar gets
	# dragged elsewhere in the meantime.
	g["shift_ids"] = _shift_nodes_below(rect.position.y + rect.size.y, -delta, g.get("members", []))
	g["shift_amt"] = delta


# Expand reflow: push the nodes that were pulled up under the bar back down to clear the body again.
func _undo_frame_reflow(g: Dictionary) -> void:
	var amt: float = float(g.get("shift_amt", 0.0))
	if amt > 0.0:
		var nodes: Dictionary = _graph_model.get("nodes", {})
		for id: String in g.get("shift_ids", []):
			if nodes.has(id):
				var p: Vector2 = (nodes[id] as Dictionary).get("pos", Vector2.ZERO)
				(nodes[id] as Dictionary)["pos"] = Vector2(p.x, p.y + amt)
	g.erase("shift_ids")
	g.erase("shift_amt")


# Collapse companion to _apply_frame_reflow, for the OTHER group frames: slide every frame below the bar
# up by the same delta the nodes moved, so each frame keeps wrapping its (also-shifted) members instead
# of being left behind to overlap the revealed content. Records the moved frame indices + amount so
# _undo_frame_shift reverses it on expand. (Frame indices, not ids — frames have none; adding/removing a
# frame while another is collapsed is the only thing that can desync this, and only cosmetically.)
func _apply_frame_shift(g: Dictionary, idx: int) -> void:
	var rect: Rect2 = g.get("rect", Rect2())
	var delta: float = rect.size.y - GraphView.FRAME_HEADER_H
	if delta <= 0.0:
		g["frame_shift_idxs"] = []
		g["frame_shift_amt"] = 0.0
		return
	g["frame_shift_idxs"] = _shift_frames_below(rect.position.y + rect.size.y, -delta, idx)
	g["frame_shift_amt"] = delta


# Expand companion: push the frames that slid up under the bar back down. Mirrors _undo_frame_reflow.
func _undo_frame_shift(g: Dictionary) -> void:
	var amt: float = float(g.get("frame_shift_amt", 0.0))
	if amt > 0.0:
		var groups: Array = _graph_model.get("groups", [])
		for raw in g.get("frame_shift_idxs", []):
			var i: int = int(raw)  # JSON round-trips the indices as floats; coerce back
			if i >= 0 and i < groups.size():
				var fr: Dictionary = groups[i]
				var r: Rect2 = fr.get("rect", Rect2())
				fr["rect"] = Rect2(Vector2(r.position.x, r.position.y + amt), r.size)
	g.erase("frame_shift_idxs")
	g.erase("frame_shift_amt")


# Shifts every group frame except `exclude_idx` whose top is at/below `threshold_y` by `dy` on the y
# axis. Returns the indices moved so the collapse↔expand pair can reverse it.
func _shift_frames_below(threshold_y: float, dy: float, exclude_idx: int) -> Array:
	var groups: Array = _graph_model.get("groups", [])
	var moved: Array = []
	for i: int in groups.size():
		if i == exclude_idx:
			continue
		var fr: Dictionary = groups[i]
		var r: Rect2 = fr.get("rect", Rect2())
		if r.position.y >= threshold_y:
			fr["rect"] = Rect2(Vector2(r.position.x, r.position.y + dy), r.size)
			moved.append(i)
	return moved


# Expand make-room: a node "parked" in the freed space under a collapsed bar (centre inside the frame
# rect, but not a frozen member) would be overlapped — then absorbed — by the body that reappears on
# expand. Drop it just below the frame, then shove down ONLY the contiguous run of nodes it actually
# lands on, stopping at the first vertical gap big enough to swallow the shift — a node with clearance
# (however far below) is never touched. Members and the parked node(s) never move. The run shifts by a
# single amount so side-by-side layouts survive. Exact moves are recorded for _undo_expand_pushout.
func _push_parked_nodes_out(g: Dictionary) -> void:
	var rect: Rect2 = g.get("rect", Rect2())
	var skip: Dictionary = {}  # nodes that must never be shoved: frozen members + the parked node(s)
	for id: String in g.get("members", []):
		skip[id] = true
	var parked: Array = []
	for id: String in _nodes_in_rect(rect):
		if not skip.has(id):
			parked.append(id)
	if parked.is_empty():
		return
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var frame_bottom: float = rect.position.y + rect.size.y
	var gap: float = GraphLayout.GRID
	# Drop the parked node(s) to just below the frame, preserving their relative layout.
	var parked_top: float = INF
	var parked_bottom: float = -INF
	for id: String in parked:
		var p: Vector2 = (nodes[id] as Dictionary).get("pos", Vector2.ZERO)
		parked_top = minf(parked_top, p.y)
		parked_bottom = maxf(parked_bottom, p.y + GraphView.NODE_HEIGHT)
		skip[id] = true
	var park_amt: float = (frame_bottom + gap) - parked_top
	for id: String in parked:
		var p: Vector2 = (nodes[id] as Dictionary).get("pos", Vector2.ZERO)
		(nodes[id] as Dictionary)["pos"] = Vector2(p.x, p.y + park_amt)
	var parked_new_bottom: float = parked_bottom + park_amt

	# Candidates that could be in the way: non-skip nodes whose body reaches past the frame bottom, top-down.
	var below: Array = []
	for id: String in nodes:
		if skip.has(id):
			continue
		if (
			(
				((nodes[id] as Dictionary).get("pos", Vector2.ZERO) as Vector2).y
				+ GraphView.NODE_HEIGHT
			)
			> frame_bottom
		):
			below.append(id)
	below.sort_custom(
		func(a: String, b: String) -> bool:
			return (
				((nodes[a] as Dictionary).get("pos", Vector2.ZERO) as Vector2).y
				< ((nodes[b] as Dictionary).get("pos", Vector2.ZERO) as Vector2).y
			)
	)

	var block_ids: Array = []
	var shift: float = 0.0
	if not below.is_empty():
		var first_y: float = ((nodes[below[0]] as Dictionary).get("pos", Vector2.ZERO) as Vector2).y
		if first_y < parked_new_bottom + gap:  # the parked node lands on the first node → make room
			shift = (parked_new_bottom + gap) - first_y
			var block_bottom: float = -INF
			for id: String in below:
				var y: float = ((nodes[id] as Dictionary).get("pos", Vector2.ZERO) as Vector2).y
				if not block_ids.is_empty() and (y - block_bottom) >= shift:
					break  # a gap wide enough to absorb the shift — everything from here down is clear
				block_ids.append(id)
				block_bottom = maxf(block_bottom, y + GraphView.NODE_HEIGHT)
			for id: String in block_ids:
				var p: Vector2 = (nodes[id] as Dictionary).get("pos", Vector2.ZERO)
				(nodes[id] as Dictionary)["pos"] = Vector2(p.x, p.y + shift)

	g["park_ids"] = parked
	g["park_amt"] = park_amt
	g["park_below_ids"] = block_ids
	g["park_below_amt"] = shift


# Collapse counterpart to _push_parked_nodes_out: reverse the exact moves recorded on expand, so a parked
# node returns to the freed space and the nudged-aside nodes come back up. Runs after membership is frozen
# (the parked node is still below the frame then, so it isn't captured as a member). A parked node the
# author dragged back into the frame while expanded is now a member — left in place, not un-shifted.
func _undo_expand_pushout(g: Dictionary) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var member_set: Dictionary = {}
	for id: String in g.get("members", []):
		member_set[id] = true
	var park_amt: float = float(g.get("park_amt", 0.0))
	for id: String in g.get("park_ids", []):
		if nodes.has(id) and not member_set.has(id):
			var p: Vector2 = (nodes[id] as Dictionary).get("pos", Vector2.ZERO)
			(nodes[id] as Dictionary)["pos"] = Vector2(p.x, p.y - park_amt)
	var below_amt: float = float(g.get("park_below_amt", 0.0))
	for id: String in g.get("park_below_ids", []):
		if nodes.has(id):
			var p: Vector2 = (nodes[id] as Dictionary).get("pos", Vector2.ZERO)
			(nodes[id] as Dictionary)["pos"] = Vector2(p.x, p.y - below_amt)
	g.erase("park_ids")
	g.erase("park_amt")
	g.erase("park_below_ids")
	g.erase("park_below_amt")


# ---------------------------------------------------------------------------
# Export image — high-res PNG of the whole journey layout (for sharing)
# ---------------------------------------------------------------------------

const CAPTURE_SCALE: float = 1.0  # render multiplier (native = crisp text; >1 = more pixels but softer)
const CAPTURE_MARGIN: float = 48.0  # px padding around the graph
const CAPTURE_MAX_DIM: int = 12000  # cap longest side
const CAPTURE_MAX_MEGAPIXELS: float = 48.0  # cap total area (bounds the render target's GPU/RAM)
const CAPTURE_MAX_BYTES: int = 8 * 1024 * 1024  # 8 MB site upload limit
const CAPTURE_JPEG_QUALITY: float = 0.9  # used when a PNG would blow the 8 MB budget


func _on_export_image_pressed() -> void:
	if (_graph_model.get("nodes", {}) as Dictionary).is_empty():
		_show_status("Nothing to capture — add a round first.", true)
		return
	_show_status("Rendering layout image…", false)
	var img: Image = await _render_graph_image()
	if img == null:
		_show_status("Couldn't render the layout image.", true)
		return
	_save_capture_with_dialog(_encode_for_sharing(img))


# Renders a FRESH GraphView of the current graph into an offscreen SubViewport at
# full content size (× CAPTURE_SCALE) on a dark background, and reads it back as an
# Image. The live builder graph is a separate instance and stays untouched.
# Returns null on an empty graph / failure.
func _render_graph_image() -> Image:
	var svp: SubViewport = SubViewport.new()
	svp.transparent_bg = false
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svp.size = Vector2i(64, 64)

	var bg: ColorRect = ColorRect.new()
	bg.color = UITheme.BG
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	svp.add_child(bg)

	var g: GraphView = GraphViewScene.instantiate()
	g.anchor_right = 1.0
	g.anchor_bottom = 1.0
	g.map_mode = true  # render the journey clean — no editor chrome (out-handles, selection wiring)
	svp.add_child(g)
	add_child(svp)  # offscreen — a bare SubViewport still renders to its texture

	g.set_graph(_graph_model)
	# Wait for the deferred layout chain (refresh → _do_layout → centre) to settle.
	var tries: int = 0
	while g.content_bounds().is_empty() and tries < 30:
		await get_tree().process_frame
		tries += 1

	var scale: float = CAPTURE_SCALE
	var img_size: Vector2 = g.frame_for_capture(scale, CAPTURE_MARGIN)
	if img_size == Vector2.ZERO:
		svp.queue_free()
		return null

	# Bound BOTH the longest side and the total area so a huge journey never
	# allocates an enormous render target. We shrink as little as possible — the
	# JPEG encoder (below) carries the rest of the size budget so text stays large.
	var dim_factor: float = 1.0
	var longest: float = maxf(img_size.x, img_size.y)
	if longest > float(CAPTURE_MAX_DIM):
		dim_factor = float(CAPTURE_MAX_DIM) / longest
	var area_factor: float = 1.0
	var megapixels: float = (img_size.x * img_size.y) / 1_000_000.0
	if megapixels > CAPTURE_MAX_MEGAPIXELS:
		area_factor = sqrt(CAPTURE_MAX_MEGAPIXELS / megapixels)
	var factor: float = minf(dim_factor, area_factor)
	if factor < 1.0:
		scale *= factor
		img_size = g.frame_for_capture(scale, CAPTURE_MARGIN)

	svp.size = Vector2i(ceili(img_size.x), ceili(img_size.y))
	# Let it render at the final size before the CPU read-back.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img: Image = svp.get_texture().get_image()
	svp.queue_free()
	return img


# Encodes the image for sharing under the upload budget, returning {data, ext}.
# Prefers lossless PNG (crispest for graph text/edges). When a PNG would exceed
# 8 MB — the usual case for big journeys — it switches to high-quality JPEG, which
# holds ~3–5× more pixels per byte, so the layout keeps its resolution (and the
# text stays readable) instead of being downscaled to a blur. Downscaling is the
# last resort, only if even the JPEG is over budget.
func _encode_for_sharing(img: Image) -> Dictionary:
	var png: PackedByteArray = img.save_png_to_buffer()
	if png.size() <= CAPTURE_MAX_BYTES:
		return {"data": png, "ext": "png"}

	var jpg: PackedByteArray = img.save_jpg_to_buffer(CAPTURE_JPEG_QUALITY)
	while jpg.size() > CAPTURE_MAX_BYTES and img.get_width() > 200:
		var ratio: float = sqrt(float(CAPTURE_MAX_BYTES) / float(jpg.size())) * 0.95
		var nw: int = maxi(200, int(img.get_width() * ratio))
		var nh: int = maxi(200, int(img.get_height() * ratio))
		if nw >= img.get_width():
			break
		img.resize(nw, nh, Image.INTERPOLATE_LANCZOS)
		jpg = img.save_jpg_to_buffer(CAPTURE_JPEG_QUALITY)
	return {"data": jpg, "ext": "jpg"}


# Native save dialog → writes the pre-encoded bytes (PNG or JPEG, per the encoder)
# to the chosen path and opens the containing folder.
func _save_capture_with_dialog(result: Dictionary) -> void:
	var data: PackedByteArray = result["data"]
	var ext: String = result["ext"]
	var base: String = JourneyData.sanitize_folder_name(_journey_name.strip_edges())
	if base == "":
		base = "journey"

	var dlg: FileDialog = FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.add_filter("*." + ext, ext.to_upper() + " image")
	dlg.current_file = "%s_layout.%s" % [base, ext]
	SettingsService.remember_browse_dir(dlg)  # reopen where the last picker left off (keeps current_file)
	add_child(dlg)
	dlg.file_selected.connect(
		func(path: String) -> void:
			if not path.to_lower().ends_with("." + ext):
				path += "." + ext
			var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
			if f == null:
				_show_status("Couldn't write %s." % path.get_file(), true)
			else:
				f.store_buffer(data)
				f.close()
				_show_status(
					(
						"Saved layout image (%.1f MB) — %s"
						% [data.size() / 1048576.0, path.get_file()]
					),
					false
				)
				OS.shell_show_in_file_manager(ProjectSettings.globalize_path(path))
			dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)
	dlg.popup_centered_ratio(0.6)


# Centered modal listing every builder keyboard / mouse shortcut. Closeable via
# the Close button or the backdrop.
func _show_shortcuts_overlay() -> void:
	var parts: Dictionary = UITheme.build_centered_modal(
		"⌨  SHORTCUTS", UITheme.PURPLE_BRIGHT, Vector2i(580, 740)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	add_child(modal)

	# Rows live in a scroll region so the reference can grow without overflowing
	# the panel; the Close button stays pinned below it.
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var list: VBoxContainer = VBoxContainer.new()
	list.add_theme_constant_override("separation", 5)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var groups: Array = [
		[
			"EDIT",
			[
				["Ctrl + S", "Save journey"],
				["Ctrl + Z", "Undo"],
				["Ctrl + Y  /  Ctrl + Shift + Z", "Redo"],
				["Delete  /  Backspace", "Delete the selected node(s)"],
			]
		],
		[
			"CLIPBOARD",
			[
				["Ctrl + C", "Copy the selection — node(s) or a note"],
				["Ctrl + X", "Cut (copy + delete)"],
				["Ctrl + V", "Paste (fresh ids, offset on repeat)"],
				["Ctrl + D", "Duplicate the selection in place"],
			]
		],
		[
			"ADD NODE  (near the selection)",
			[
				["Ctrl + 1", "Add a round"],
				["Ctrl + 2", "Add a shop"],
				["Ctrl + 3", "Add a storyboard"],
				["Ctrl + 4", "Add a fork"],
			]
		],
		[
			"RIGHT-CLICK",
			[
				["Right-click empty space", "Menu: add a node / note / group at the cursor"],
				["Right-click a node", "Menu: set it as the journey's start / FINISH node"],
			]
		],
		[
			"SELECT & MOVE",
			[
				["Click a node", "Select it (edit it in the side panel)"],
				["Ctrl + click", "Add / remove a node from the selection"],
				["Shift + click", "Add a node to the selection"],
				["Drag a box on empty space", "Marquee-select nodes"],
				["Drag a node", "Move it — or the whole selection"],
				["Escape", "Cancel a wire in progress, or clear the selection"],
			]
		],
		[
			"WIRE EDGES",
			[
				[
					"Drag a node's bottom handle → a node",
					"Connect them (line turns red if it would loop)"
				],
				["Select  →  🔗 Connect  →  click", "Same, button-driven (the accessible fallback)"],
			]
		],
		[
			"NAVIGATE",
			[
				["Arrow keys / WASD", "Pan the graph"],
				["Middle-drag  or  Space + drag", "Pan the graph"],
				["Mouse wheel", "Zoom in / out"],
				["⊡ Fit button", "Frame the whole journey"],
			]
		],
		[
			"IMPORT",
			[
				[
					"Drop videos / a folder on the canvas",
					"Auto-create chained round nodes (matched by name)"
				],
			]
		],
	]

	for group: Array in groups:
		var section_lbl: Label = Label.new()
		section_lbl.text = group[0]
		section_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
		section_lbl.add_theme_font_size_override("font_size", 11)
		section_lbl.uppercase = true
		list.add_child(section_lbl)
		for row_spec: Array in group[1]:
			var row: HBoxContainer = HBoxContainer.new()
			row.add_theme_constant_override("separation", 14)
			var key_lbl: Label = Label.new()
			key_lbl.text = row_spec[0]
			key_lbl.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
			key_lbl.add_theme_font_size_override("font_size", 12)
			key_lbl.custom_minimum_size = Vector2(240, 0)
			row.add_child(key_lbl)
			var desc_lbl: Label = Label.new()
			desc_lbl.text = row_spec[1]
			desc_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
			desc_lbl.add_theme_font_size_override("font_size", 12)
			desc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(desc_lbl)
			list.add_child(row)
		var spacer: Control = Control.new()
		spacer.custom_minimum_size = Vector2(0, 6)
		list.add_child(spacer)

	var close_btn: Button = Button.new()
	close_btn.text = "CLOSE"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(close_btn, UITheme.PURPLE_BRIGHT)
	close_btn.pressed.connect(func() -> void: modal.queue_free())
	vbox.add_child(close_btn)

	# Backdrop click also dismisses (the backdrop is the modal's first child).
	var backdrop: Control = modal.get_child(0) as Control
	if backdrop:
		backdrop.gui_input.connect(
			func(event: InputEvent) -> void:
				if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
					modal.queue_free()
		)


# ---------------------------------------------------------------------------
# Style helpers
# ---------------------------------------------------------------------------

# Style helpers moved to UITheme (autoload). Callers use UITheme.style_*(...).

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------


func _connect_signals() -> void:
	_back_btn.pressed.connect(_on_back_pressed)
	_save_btn.pressed.connect(_on_save_pressed)
	# Bulk import: files / a folder dropped on the canvas → auto-create chained round nodes.
	get_viewport().files_dropped.connect(_on_viewport_files_dropped)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	# Only fresh key-down events; ignore key-up and auto-repeat (echo). The echo guard also stops a
	# held Delete from chain-deleting nodes.
	if not k.pressed or k.echo:
		return
	# A modal owns the keyboard while it is up. _input runs BEFORE the modal's own
	# _unhandled_key_input, so without this the canvas would act on Ctrl+C / Delete / Ctrl+Z aimed at
	# the encounter editor — copying graph nodes while the author thought they were copying events.
	# Same shield the OS-file-drop handler uses.
	if _modal_shield_open():
		return

	if k.ctrl_pressed:
		match k.keycode:
			KEY_S:
				# Save is global — fires even from inside a text field.
				if not _save_btn.disabled:
					_on_save_pressed()
				get_viewport().set_input_as_handled()
			KEY_1, KEY_2, KEY_3, KEY_4:
				# Quick-create a node by type, placed near the current selection. Stand down inside a
				# text field (the author may be typing, and Ctrl+digit can be a native shortcut).
				if _focus_is_text_field():
					return
				_create_graph_node(
					{KEY_1: "round", KEY_2: "shop", KEY_3: "storyboard", KEY_4: "fork"}[k.keycode]
				)
				get_viewport().set_input_as_handled()
			KEY_Z:
				# Ctrl+Shift+Z = redo (common alias); plain Ctrl+Z = undo. Defer to native text undo
				# inside a focused field.
				if _focus_is_text_field():
					return
				if k.shift_pressed:
					_redo()
				else:
					_undo()
				get_viewport().set_input_as_handled()
			KEY_Y:
				if _focus_is_text_field():
					return
				_redo()
				get_viewport().set_input_as_handled()
			KEY_C:
				if _focus_is_text_field():
					return
				_copy_selection()
				get_viewport().set_input_as_handled()
			KEY_X:
				if _focus_is_text_field():
					return
				_cut_selection()
				get_viewport().set_input_as_handled()
			KEY_V:
				if _focus_is_text_field():
					return
				_paste_clipboard()
				get_viewport().set_input_as_handled()
			KEY_D:
				if _focus_is_text_field():
					return
				_duplicate_selection()
				get_viewport().set_input_as_handled()
		return

	match k.keycode:
		KEY_BACKSPACE, KEY_DELETE:
			# Delete the selected note, else the selected node(s). Must yield to text editing —
			# Backspace/Delete still edit characters inside a focused LineEdit/TextEdit.
			if _focus_is_text_field():
				return
			if _selected_comment_idx >= 0:
				_delete_comment(_selected_comment_idx)
				get_viewport().set_input_as_handled()
			elif _selected_frame_idx >= 0:
				_delete_frame(_selected_frame_idx)
				get_viewport().set_input_as_handled()
			elif not _selected_graph_node_ids.is_empty():
				_delete_selected_nodes()
				get_viewport().set_input_as_handled()
			elif not _graph.get_selected_comments().is_empty():
				_delete_marquee_comments()  # a notes-only marquee selection
				get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			# Cancel an in-progress edge wire, else drop the node selection. Only consume the event
			# when there was actually something to cancel/clear.
			if _focus_is_text_field():
				return
			if _connecting_from != "":
				_cancel_connect()
				get_viewport().set_input_as_handled()
			elif not _selected_graph_node_ids.is_empty():
				_deselect_node()
				get_viewport().set_input_as_handled()


# True when the keyboard focus is inside a text-entry control, so the node shortcuts (create /
# delete / deselect) stand down and let normal text editing happen.
func _focus_is_text_field() -> bool:
	var f: Control = get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit


func _on_back_pressed() -> void:
	if not _has_unsaved_changes():
		_leave_builder()
		return
	_show_unsaved_prompt()


func _leave_builder() -> void:
	Transition.change_scene("res://scenes/main/Main.tscn")


# Three ways out rather than two. An author who reached for BACK with an hour of work on screen should
# not have to choose between losing it and cancelling to go and find the save button — so saving is one
# of the answers, not a thing you must go back and do first.
#
# Not the shared _show_builder_confirm: that one is Cancel + a single action, and widening it would put
# a third button on every other confirmation in this file.
func _show_unsaved_prompt() -> void:
	var parts: Dictionary = UITheme.build_centered_modal(
		"UNSAVED CHANGES", UITheme.AMBER, Vector2i(620, 300)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]

	var lbl: Label = Label.new()
	lbl.text = ("This journey has changes that aren't on disk yet. Leaving now discards them.")
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(lbl, UITheme.WHITE_SOFT, 13, false)
	vbox.add_child(lbl)

	var row: HBoxContainer = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(150, 0)
	UITheme.style_button(cancel_btn, UITheme.PURPLE_MID)
	cancel_btn.pressed.connect(func() -> void: modal.queue_free())
	row.add_child(cancel_btn)

	var discard_btn: Button = Button.new()
	discard_btn.text = "DISCARD & LEAVE"
	discard_btn.custom_minimum_size = Vector2(190, 0)
	UITheme.style_button(discard_btn, UITheme.DANGER)
	discard_btn.pressed.connect(
		func() -> void:
			modal.queue_free()
			_leave_builder()
	)
	row.add_child(discard_btn)

	var save_btn: Button = Button.new()
	save_btn.text = "SAVE & LEAVE"
	save_btn.custom_minimum_size = Vector2(190, 0)
	UITheme.style_button(save_btn, UITheme.CYAN)
	# A save that succeeds returns to the catalogue on its own; one that fails shows its own error and
	# leaves the author in the builder with their work, which is the right outcome either way.
	save_btn.pressed.connect(
		func() -> void:
			modal.queue_free()
			_on_save_pressed()
	)
	row.add_child(save_btn)

	add_child(modal)


# Absolute path of this journey's folder on disk, or "" if it hasn't been saved
# yet. Prefers the folder for the current (possibly renamed) name; falls back to
# the folder it was loaded from.
func _saved_journey_folder_abs() -> String:
	var name: String = _journey_name.strip_edges()
	if name != "":
		var folder: String = (
			SettingsService.get_journeys_dir() + "/" + JourneyData.sanitize_folder_name(name)
		)
		var abs: String = ProjectSettings.globalize_path(folder)
		if DirAccess.dir_exists_absolute(abs):
			return abs
	if _original_journey_folder != "":
		var orig_abs: String = ProjectSettings.globalize_path(_original_journey_folder)
		if DirAccess.dir_exists_absolute(orig_abs):
			return orig_abs
	return ""


# Opens this journey's media/ folder in the OS file browser. Requires a prior
# save so the folder exists; otherwise nudges the user to save first. Falls back
# to the journey root on the off chance media/ isn't there.
func _open_journey_folder() -> void:
	var abs: String = _saved_journey_folder_abs()
	if abs == "":
		_show_status("Save the journey first — its folder doesn't exist yet.", true)
		return
	var media_abs: String = abs + "/media"
	OS.shell_open(media_abs if DirAccess.dir_exists_absolute(media_abs) else abs)


# ── Bulk import (drop videos / a folder on the canvas → chained round nodes) ──

const BULK_IMPORT_ROW: float = 140.0  # vertical spacing between imported round nodes
const BULK_IMPORT_COL_GAP: float = 360.0  # gap to the right of existing content for the new column


# Viewport file-drop router. A folder always bulk-imports (expanded recursively). A file drop over
# the side panel is left to the per-field DropZones; over the canvas it bulk-imports rounds, falling
# back to accepting a lone image as the journey cover.
func _on_viewport_files_dropped(files: PackedStringArray) -> void:
	# With a modal open over the canvas (the custom-item editor, its list, …), the ONLY valid drop target
	# is a per-field DropZone — and those handle themselves via their own viewport hook. So swallow the drop
	# here: a funscript that missed the override drop zone must not fall through to bulk-import rounds (or
	# hijack the cover) hidden behind the modal.
	if _modal_shield_open():
		return

	# A drop onto the selected pool round's encounter drop zone wins outright — it must be
	# offered BEFORE the folder branch below, which would otherwise bulk-import the folder as
	# new round nodes onto the canvas. No live zone under the cursor → falls through.
	if _side_renderer != null and _side_renderer.try_handle_pool_drop(files):
		return

	var has_folder: bool = false
	for f: String in files:
		if DirAccess.dir_exists_absolute(f):
			has_folder = true
			break
	if has_folder:
		var expanded: PackedStringArray = ImportScanner.expand_dropped_paths(files)
		if _bulk_import_graph_rounds(expanded):
			return
		if expanded.is_empty():
			_show_status("No videos or funscripts found in the dropped folder(s).", true)
		return

	# A drop landing on the side panel: the per-field DropZones handle a single-file drop; this routes
	# a multi-funscript drop into the selected round's axis/vib slots, or an image → the cover.
	if _side_panel.get_global_rect().has_point(get_viewport().get_mouse_position()):
		_handle_side_panel_drop(files)
		return

	# A per-field DropZone under the cursor (e.g. a custom-item image zone in a modal over the canvas)
	# owns the drop — it sets its own value, so the builder stays out of it rather than bulk-importing
	# or hijacking the journey cover.
	if _drop_zone_under_cursor():
		return

	# Canvas drop: bulk round import, else accept an image as the journey cover.
	if not _bulk_import_graph_rounds(files):
		for f: String in files:
			if f.get_extension().to_lower() in JourneyData.IMAGE_EXTENSIONS:
				_cover_path = f
				_update_cover_preview()
				return


# Side-panel drop: when a round node is selected and MORE THAN ONE funscript is dropped, auto-route
# them into the node's funscript / axis / vib slots by suffix (the per-field DropZones only take one
# file each). Otherwise, with nothing selected, accept a dropped image as the journey cover.
func _handle_side_panel_drop(files: PackedStringArray) -> void:
	# A ghosted base round is NEVER modified — its channel-overlay editor's own drop zone already routed
	# this drop to slot-fills. Writing the scripts into the base node here would make its channels wrongly
	# read as "in base" (and, worse, alter the locked base in memory).
	if _rendition_parent_ids.has(_selected_graph_node_id):
		return
	var node: Dictionary = (_graph_model.get("nodes", {}) as Dictionary).get(
		_selected_graph_node_id, {}
	)
	if _selected_graph_node_id != "" and node.get("type", "") == "round":
		var fs_files: Array = []
		for f: String in files:
			if f.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS:
				fs_files.append(f)
		if fs_files.size() > 1:
			var data: Dictionary = node.get("data", {})
			if not data.has("axis_scripts"):
				data["axis_scripts"] = {}
			if not data.has("vib_scripts"):
				data["vib_scripts"] = {}
			if not data.has("estim_scripts"):
				data["estim_scripts"] = {}
			for f: String in fs_files:
				var vib_ch: String = ImportScanner.detect_vib_channel(f)
				var estim_ax: String = ImportScanner.detect_estim_axis(f)
				if vib_ch != "":
					data["vib_scripts"][vib_ch] = f
				elif estim_ax != "":
					data["estim_scripts"][estim_ax] = f
				else:
					var axis: String = ImportScanner.detect_funscript_axis(f)
					if axis == "L0":
						data["funscript_path"] = f
						if str(data.get("name", "")).strip_edges() == "":
							data["name"] = f.get_file().get_basename()
					else:
						data["axis_scripts"][axis] = f
			# Rebuild the canvas + side panel (deferred, so it lands after the per-field DropZones have
			# also processed this same drop) to show the routed paths.
			_graph.call_deferred("select_graph_node", _selected_graph_node_id)
			return

	# Nothing selected → a dropped image becomes the journey cover, unless a per-field DropZone under
	# the cursor owns the drop (it sets its own value; don't also hijack the cover).
	if _selected_graph_node_id == "" and not _drop_zone_under_cursor():
		for f: String in files:
			if f.get_extension().to_lower() in JourneyData.IMAGE_EXTENSIONS:
				_cover_path = f
				_update_cover_preview()
				return


# True when a centered modal is open (build_centered_modal joins every modal to "ui_modal"). While one is
# up it covers the canvas, so an OS file drop that isn't caught by a per-field DropZone must be ignored
# rather than bulk-imported / treated as a cover behind the modal.
func _modal_shield_open() -> bool:
	for m: Node in get_tree().get_nodes_in_group("ui_modal"):
		var c: Control = m as Control
		if c != null and c.is_visible_in_tree():
			return true
	return false


# True when a visible per-field DropZone sits under the cursor. Those zones set their own value from
# an OS file drop (DropZone._on_viewport_files_dropped), so the builder must not also treat the same
# drop as a canvas / journey-cover action. Zones join the "file_drop_zone" group in DropZone._ready.
func _drop_zone_under_cursor() -> bool:
	var mouse: Vector2 = get_viewport().get_mouse_position()
	for z: Node in get_tree().get_nodes_in_group("file_drop_zone"):
		var ctrl: Control = z as Control
		if ctrl != null and ctrl.is_visible_in_tree() and ctrl.get_global_rect().has_point(mouse):
			return true
	return false


# Bulk-imports rounds from dropped files: ImportScanner groups them into round data (a video + its
# matched scripts → one round; funscript-only groups are skipped), then this creates a chained column
# of round nodes to the right of the existing graph. One undo step. Returns true if it created a round.
func _bulk_import_graph_rounds(files: PackedStringArray) -> bool:
	var result: Dictionary = ImportScanner.build_rounds(files)
	var rounds: Array = result["rounds"]
	var skipped_no_video: int = result["skipped_no_video"]

	if rounds.is_empty():
		if skipped_no_video > 0:
			_show_status(
				(
					"No rounds created — found %d funscript%s with no matching video."
					% [skipped_no_video, "s" if skipped_no_video != 1 else ""]
				),
				true
			)
		return false

	_push_undo()
	if not _graph_model.has("nodes"):
		_graph_model["nodes"] = {}
	var nodes: Dictionary = _graph_model["nodes"]
	var origin: Vector2 = _bulk_import_origin()
	var prev_id: String = ""
	var created: Array = []
	for i in rounds.size():
		var node_id: String = JourneyData.new_node_id()
		nodes[node_id] = {
			"type": "round",
			"data": rounds[i],
			"pos": GraphLayout.snap(origin + Vector2(0.0, float(i) * BULK_IMPORT_ROW)),
			"out": [],
		}
		if prev_id != "":
			(nodes[prev_id] as Dictionary)["out"] = [{"to": node_id}]
		if str(_graph_model.get("start", "")) == "":
			_graph_model["start"] = node_id
		prev_id = node_id
		created.append(node_id)
	_graph.set_selection(created)
	var msg: String = (
		"Imported %d round%s (chained)." % [created.size(), "" if created.size() == 1 else "s"]
	)
	if skipped_no_video > 0:
		msg += (
			" Skipped %d funscript%s with no video."
			% [skipped_no_video, "s" if skipped_no_video != 1 else ""]
		)
	msg += " Ctrl+Z to undo."
	_show_status(msg, false)
	return true


# Top-left for the imported round column: near the CENTRE OF THE CURRENT VIEW, so a new import
# lands where the author is looking instead of at the far edge of the whole graph (which meant
# zooming out to find it every time). Offset up-left so the chain grows down into view. An empty
# graph starts at the origin for a tidy first layout.
func _bulk_import_origin() -> Vector2:
	if _graph_model.get("nodes", {}).is_empty():
		return Vector2.ZERO
	return GraphLayout.snap(_graph.view_center_world() + Vector2(-160.0, -80.0))


# ---------------------------------------------------------------------------
# Cover image
# ---------------------------------------------------------------------------


func _on_cover_pressed() -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	dialog.title = "Select Cover Image"
	SettingsService.remember_browse_dir(dialog)  # reopen where the last picker left off
	add_child(dialog)
	dialog.popup_centered(Vector2i(900, 600))
	dialog.file_selected.connect(
		func(path: String) -> void:
			_cover_path = path
			_update_cover_preview()
			dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())


# Deep-copies a backdrop list, normalizing each entry to {path, offset:Vector2, scale, opacity} so the
# editor can mutate it without aliasing the scanner's dict.
func _dup_backdrops(src: Array) -> Array:
	var out: Array = []
	for e: Variant in src:
		var d: Dictionary = e
		(
			out
			. append(
				{
					"path": str(d.get("path", "")),
					"offset": d.get("offset", Vector2.ZERO),
					"scale": float(d.get("scale", 1.0)),
					"opacity": float(d.get("opacity", 0.6)),
					"rotation": float(d.get("rotation", 0.0)),
				}
			)
		)
	return out


# Builds the combined backdrop stack — locked base context first (bottom), then this journey's own editable
# layers on top — with textures loaded, and pushes it to the graph. Called on load and on any set change.
func _push_backdrops() -> void:
	if not is_instance_valid(_graph):
		return
	var combined: Array = []
	for b: Dictionary in _base_backdrops:
		combined.append(_backdrop_render_entry(b))
	for b: Dictionary in _map_backdrops:
		combined.append(_backdrop_render_entry(b))
	_graph.set_backdrops(combined)


# One {texture, offset, scale, opacity} render entry for a stored {path, …} backdrop (texture loaded).
func _backdrop_render_entry(b: Dictionary) -> Dictionary:
	return {
		"texture": _backdrop_texture(str(b.get("path", ""))),
		"offset": b.get("offset", Vector2.ZERO),
		"scale": float(b.get("scale", 1.0)),
		"opacity": float(b.get("opacity", 0.6)),
		"rotation": float(b.get("rotation", 0.0)),
	}


# Loads (and caches by path) a backdrop image as a texture — shared by the graph render and the side-panel
# thumbnails so a big image is decoded once. Returns null for a blank/unreadable path.
func _backdrop_texture(path: String) -> Texture2D:
	if path == "":
		return null
	if _backdrop_tex_cache.has(path):
		return _backdrop_tex_cache[path]
	var img: Image = JourneyData.load_image_smart(path)
	if img == null:
		return null
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_backdrop_tex_cache[path] = tex
	return tex


# Reorders an editable backdrop layer in the z-stack: swaps layer `i` with its neighbour `i + dir` (+1 =
# toward the front / drawn later, -1 = toward the back). Clears any active reposition (indices shift) and
# re-pushes so the draw order updates. The side panel rebuilds after to refresh the cards.
func _move_backdrop(i: int, dir: int) -> void:
	var j: int = i + dir
	if i < 0 or i >= _map_backdrops.size() or j < 0 or j >= _map_backdrops.size():
		return
	var tmp: Variant = _map_backdrops[i]
	_map_backdrops[i] = _map_backdrops[j]
	_map_backdrops[j] = tmp
	_backdrop_reposition_idx = -1
	if is_instance_valid(_graph):
		_graph.set_backdrop_reposition(-1)
	_push_backdrops()


# Live placement push for editable layer `i` (slider edits) — maps to its index in the combined stack
# (base layers sit before it), reusing the loaded texture so a big image isn't reloaded each tick.
func _push_backdrop_transform(i: int) -> void:
	if is_instance_valid(_graph) and i >= 0 and i < _map_backdrops.size():
		var b: Dictionary = _map_backdrops[i]
		_graph.set_backdrop_transform(
			_base_backdrops.size() + i,
			b["offset"],
			float(b["scale"]),
			float(b["opacity"]),
			float(b.get("rotation", 0.0))
		)


# Loads the cover image from _cover_path into _cover_texture. The journey-info
# side-panel view reads _cover_texture when building its preview widget.
func _update_cover_preview() -> void:
	if _cover_path == "":
		_cover_texture = null
	else:
		var img: Image = JourneyData.load_image_smart(_cover_path)
		if img != null:
			_cover_texture = ImageTexture.create_from_image(img)
	# Rebuild journey-info panel so the preview widget picks up the new texture
	# (only if no node is currently selected).
	if _selected_graph_node_ids.is_empty():
		_side_renderer.show_journey_info_panel()


# ---------------------------------------------------------------------------
# Load existing journey for editing
# ---------------------------------------------------------------------------


# Graph-editor load (L1): journey-level meta (same source as the tree loader) + the composed
# graph with positions (Format 2 read, or legacy migrated + seeded). Mutates _graph_model IN
# PLACE so the deferred set_graph from _setup_graph_view renders the populated graph.
func _load_graph(journey: Dictionary) -> void:
	var parsed: Dictionary = JourneyData.parse_journey(journey)
	_journey_name = parsed["name"]
	# Carry the existing id forward so saving an edited journey keeps its identity. Blank for a
	# journey written before ids existed - it gets one on this save.
	_journey_id = str(journey.get("journey_id", ""))
	_journey_author = parsed["author"]
	_journey_desc = parsed["description"]
	_journey_difficulty_idx = parsed["difficulty_idx"]
	_journey_tags = (parsed.get("tags", []) as Array).duplicate()
	_journey_map_enabled = bool(parsed.get("map_enabled", true))
	_journey_show_fork_counts = bool(parsed.get("show_fork_counts", true))
	_journey_show_loops_on_map = bool(parsed.get("show_loops_on_map", false))
	# Map backdrops: the scanner resolved each layer's image (media/<file>) + placement into map_backdrops.
	_backdrop_tex_cache.clear()
	_map_backdrops = _dup_backdrops(journey.get("map_backdrops", []))
	_base_backdrops = []  # a base journey has no locked context; renditions set this in their start hook
	_push_backdrops()  # no-op until the graph exists; _setup_graph_view re-pushes on first load
	_journey_shown_counters = (parsed.get("shown_counters", []) as Array).duplicate()
	# Custom journey items come from the scanner's resolved `items` on the raw journey dict —
	# NOT from `parsed`, whose "items" key is JourneyData.parse_journey's NODE SEQUENCE (a name
	# collision). Reading `parsed["items"]` here loaded the round/shop nodes as blank custom items.
	_journey_items = (journey.get("items", []) as Array).duplicate(true)
	# Cast roster — from the scanner's resolved `characters` (absolute portrait paths for display), same
	# reasoning as items above (`parsed["characters"]` would be the raw pass-through, unresolved).
	_journey_characters = (journey.get("characters", []) as Array).duplicate(true)
	_journey_map_fog = bool(parsed.get("map_fog", false))
	_journey_map_fog_reveal = int(parsed.get("map_fog_reveal", 1))
	_journey_mystery_preview = bool(parsed.get("mystery_preview", false))
	_journey_auto_advance_enabled = bool(parsed.get("auto_advance_enabled", false))
	_journey_auto_advance_storyboard_secs = int(parsed.get("auto_advance_storyboard_secs", 20))
	_journey_auto_advance_fork_secs = int(parsed.get("auto_advance_fork_secs", 45))
	_journey_allow_finish = bool(parsed.get("allow_finish", false))
	_journey_finish_node = str(parsed.get("finish_node", ""))
	if (parsed["cover_path"] as String) != "":
		_cover_path = parsed["cover_path"]
		_update_cover_preview()
	var folder: String = journey.get("folder", "")
	var loaded: Dictionary = JourneyScanner.parse_graph_for_editor(
		folder, journey.get("folder_name", (folder as String).get_file())
	)
	# Seed positions from the TREE layout (compact + centered on x=0, the layout the author knows),
	# keyed by node_id. For a saved Format-2 journey parse_journey yields no items, so tree_pos is
	# empty and the positions read from disk are kept.
	var tree_pos: Dictionary = _graph.tree_positions(parsed.get("items", []))
	for id: String in loaded.get("nodes", {}):
		if tree_pos.has(id):
			(loaded["nodes"][id] as Dictionary)["pos"] = tree_pos[id]
	_graph_model.clear()
	_graph_model.merge(loaded, true)
	_mark_clean()


# Enters rendition (overlay) mode: loads the base graph with all of its nodes GHOSTED (read-only), then
# resets the journey-level identity so the overlay is its own artifact (its own name/id/folder). A save
# produces an overlay delta — not a re-save of the base — and the base's files are never touched.
# `rendition_over` (set when overlaying ANOTHER rendition) swaps the ghosted graph for base ⊕ the ancestor
# chain and re-targets the ParentId, enabling sibling-dependency stacks; empty = overlay the base directly.
func _enter_rendition_mode(base: Dictionary) -> void:
	_rendition_mode = true
	_load_graph(base)  # base graph + meta (identity/graph overridden below as needed)
	var parent_title: String = str(base.get("title", "the base"))
	if not rendition_over.is_empty():
		# Ghost the COMPOSED base ⊕ ancestor-chain graph, and target that ancestor rendition's id. Mutate
		# _graph_model IN PLACE — the deferred set_graph already captured this dict's reference, so a
		# reassignment here would leave the canvas rendering the pre-composed base.
		_graph_model.clear()
		_graph_model["start"] = str(rendition_over.get("start", ""))
		_graph_model["nodes"] = (rendition_over.get("nodes", {}) as Dictionary).duplicate(true)
		_rendition_parent_id = str(rendition_over.get("parent_id", ""))
		parent_title = str(rendition_over.get("parent_name", parent_title))
	else:
		_rendition_parent_id = _journey_id  # the base's id becomes the overlay's ParentId
	_rendition_parent_folder = str(base.get("folder", ""))
	_rendition_parent_journey = base.duplicate(true)  # kept so "merge into base" can reload it
	_rendition_parent_ids = {}
	_rendition_slot_fills = []
	for id: String in _graph_model.get("nodes", {}):
		_rendition_parent_ids[id] = true
	# The overlay is a NEW artifact — never adopt the base's identity, description, cover, or save location.
	_journey_id = ""
	_journey_name = ""
	_journey_desc = ""
	_cover_path = ""
	# A rendition starts with NO editable backdrops of its own; the base's load as LOCKED context (drawn
	# beneath, view-only, never re-saved). A rendition-on-rendition uses the composed ancestor chain's set.
	_map_backdrops = []
	var base_bd: Array = base.get("map_backdrops", [])
	if not rendition_over.is_empty():
		base_bd = rendition_over.get("map_backdrops", base_bd)
	_base_backdrops = _dup_backdrops(base_bd)
	_original_journey_folder = ""
	_graph.set_ghost_nodes(_rendition_parent_ids)  # the deferred set_graph reads this
	_push_backdrops()
	_show_rendition_banner(parent_title)
	# A fresh overlay starts clean: _load_graph above took its baseline from the BASE, and resetting the
	# identity here would otherwise read as unsaved work before the author had touched anything.
	# _load_rendition_delta re-takes it when an existing delta is loaded on top.
	_mark_clean()


# Loads an existing rendition's delta ON TOP of the just-ghosted base (call right after
# _enter_rendition_mode) so it can be edited and re-saved in place: injects its new nodes, rebuilds its
# anchor edges (marked `_anchor` on the base nodes), repopulates its slot-fills, and adopts its identity
# + folder so a save OVERWRITES it rather than minting a new overlay.
func _load_rendition_delta(summary: Dictionary) -> void:
	var folder: String = str(summary.get("folder", ""))
	var delta: Dictionary = JourneyScanner.load_rendition_delta(folder)  # paths resolved to the rendition folder
	var nodes: Dictionary = _graph_model.get("nodes", {})
	# New overlay nodes (their canvas positions were saved in the Nodes block).
	for id: String in delta.get("nodes", {}):
		nodes[id] = delta["nodes"][id]
	# Anchors → `_anchor`-marked edges on the ghosted base nodes (re-extracted on save). An ending-extend
	# is appended; a fork open-slot fill (has `slot`) re-fills that exact base choice in place so it lines
	# up with the still-blank slot loaded from the base.
	for a: Dictionary in delta.get("anchors", []):
		var anchor_id: String = str(a.get("anchor", ""))
		if not nodes.has(anchor_id):
			continue
		var anchor_node: Dictionary = nodes[anchor_id]
		if not anchor_node.has("out"):
			anchor_node["out"] = []
		var anchor_out: Array = anchor_node["out"]
		var edge: Dictionary = (a.get("edge", {}) as Dictionary).duplicate(true)
		edge["_anchor"] = true
		if a.has("slot") and int(a["slot"]) < anchor_out.size():
			var slot: int = int(a["slot"])
			var choice: Dictionary = anchor_out[slot]  # the base's own blank choice — keep its label/art
			choice["to"] = str(edge.get("to", ""))
			choice["_anchor"] = true
			choice["_slot"] = slot
		else:
			anchor_out.append(edge)
	# Channel overlays — paths are absolute after the resolve; the dialog edits them, save re-pools them.
	_rendition_slot_fills = (delta.get("slot_fills", []) as Array).duplicate(true)
	# Adopt the rendition's own identity + folder so a re-save overwrites it in place.
	_journey_id = str(summary.get("journey_id", ""))
	_journey_name = str(summary.get("name", ""))
	_journey_author = str(summary.get("author", ""))
	_journey_desc = str(summary.get("description", ""))
	_original_journey_folder = folder
	# Load the rendition's own cover (if it has one) so a re-save preserves it.
	var rc: String = str(summary.get("cover_path", ""))
	if rc != "":
		_cover_path = rc
		_update_cover_preview()
	# The rendition's OWN backdrop layers (base layers stay in _base_backdrops as locked context).
	_map_backdrops = _dup_backdrops(delta.get("map_backdrops", []))
	_push_backdrops()
	_refresh_graph()
	_mark_clean()


# Marks rendition mode in the existing TopBar (rather than a floating banner, which overlapped the
# toolbar): retints the title. Channel overlays are now added inline — click a ghosted base round to open
# its channel-overlay editor and drop axis/vibe scripts — so there's no separate toolbar button.
func _show_rendition_banner(base_title: String) -> void:
	_title_lbl.text = "◆ RENDITION — overlaying %s   (dim = locked base)" % base_title
	_title_lbl.add_theme_color_override("font_color", UITheme.CYAN)


# Temporary guard while overlay authoring is built up in steps: block the normal save so it can never
# re-write the base as a journey. Replaced by the real delta save in a later slice.
func _show_rendition_save_todo() -> void:
	var d: AcceptDialog = AcceptDialog.new()
	d.title = "Rendition Saving — Coming Soon"
	d.dialog_text = "Overlay authoring is being built in steps. Saving a rendition isn't wired up yet, so nothing was written — your base journey is untouched."
	d.confirmed.connect(d.queue_free)
	d.canceled.connect(d.queue_free)
	add_child(d)
	d.popup_centered()


# Graph editor: the selection set changed (click / ctrl/shift-click / marquee / clear / programmatic).
# Mirror it and show the matching side panel — journey info (0), the node editor (1), or the
# multi-select panel (2+).
func _on_graph_selection_changed(ids: Array) -> void:
	_selected_comment_idx = -1  # selecting a node (or clearing) takes over from any open note/frame
	_selected_frame_idx = -1
	_selected_graph_node_ids = ids.duplicate()
	_selected_graph_node_id = str(ids[0]) if ids.size() == 1 else ""
	match ids.size():
		0:
			_side_renderer.show_journey_info_panel()
		1:
			_side_renderer.show_graph_node_editor(str(ids[0]))
		_:
			_side_renderer.show_graph_multi_select_panel(ids)


# Graph editor: a node was clicked while wiring an edge — it's the connect target.
func _on_connect_target_picked(node_id: String) -> void:
	if _connecting_from != "":
		_finish_connect(node_id)


# Graph editor: an out-handle was dragged onto a target node — wire source→target through the same
# validation + undo as the button-driven connect.
func _on_edge_drawn(source_id: String, edge_idx: int, target_id: String) -> void:
	_connecting_from = source_id
	_connecting_edge_idx = edge_idx
	_finish_connect(target_id)


# Graph editor: create a fresh node of `type`, placed near the selection (grid-snapped) and
# unconnected — the author wires it with edges (slice 3c). Becomes the start if it's the first node.
func _create_graph_node(type: String, at_world: Variant = null) -> void:
	_push_undo()
	if not _graph_model.has("nodes"):
		_graph_model["nodes"] = {}
	var nodes: Dictionary = _graph_model["nodes"]
	var template: Dictionary = JourneyData.new_item(type)
	var node_id: String = str(template.get("node_id", JourneyData.new_node_id()))
	var data: Dictionary = template.duplicate(true)
	data.erase("type")
	data.erase("node_id")
	data.erase("paths")  # node-level / edge-level keys
	var out: Array = []
	if type == "fork":
		for p: Dictionary in template.get("paths", []):
			out.append(
				{
					"to": "",
					"name": p.get("name", ""),
					"description": p.get("description", ""),
					"image_path": "",
					"weight": int(p.get("weight", 1)),
					"threshold": int(p.get("threshold", 0)),
					"required_item": str(p.get("required_item", "")),
					"cost": int(p.get("cost", 0))
				}
			)
	# Cursor placement (right-click menu) centres the node on the click; otherwise drop it just right of
	# the selected node, else at the origin.
	var pos: Vector2 = Vector2.ZERO
	if at_world is Vector2:
		pos = (at_world as Vector2) - Vector2(GraphView.NODE_WIDTH, GraphView.NODE_HEIGHT) * 0.5
	elif _selected_graph_node_id != "" and nodes.has(_selected_graph_node_id):
		pos = (
			(nodes[_selected_graph_node_id] as Dictionary).get("pos", Vector2.ZERO)
			+ Vector2(240.0, 0.0)
		)
	nodes[node_id] = {"type": type, "data": data, "pos": GraphLayout.snap(pos), "out": out}
	if str(_graph_model.get("start", "")) == "":
		_graph_model["start"] = node_id
	_graph.select_graph_node(node_id)


# Graph editor: drop a linked Loop pair — a Loop Start marker with a Loop End below it, pre-wired
# start → end and with the End's back-jump (loop_to) auto-set to the Start (that pairing IS the loop, so
# there's no "loop back to…" picker). The End seeds one "after 3 loops" exit so the loop is valid and
# legible immediately; the author then inserts body nodes between the two markers.
func _create_loop_pair(at_world: Variant = null) -> void:
	_push_undo()
	if not _graph_model.has("nodes"):
		_graph_model["nodes"] = {}
	var nodes: Dictionary = _graph_model["nodes"]

	var start_tpl: Dictionary = JourneyData.new_item("loop_start")
	var end_tpl: Dictionary = JourneyData.new_item("loop_end")
	var start_id: String = str(start_tpl["node_id"])
	var end_id: String = str(end_tpl["node_id"])

	var start_data: Dictionary = start_tpl.duplicate(true)
	start_data.erase("type")
	start_data.erase("node_id")
	var end_data: Dictionary = end_tpl.duplicate(true)
	end_data.erase("type")
	end_data.erase("node_id")
	end_data["loop_to"] = start_id  # the pairing — the End replays back to this Start
	end_data["loop_conditions"] = [{"kind": "repeats", "count": 3}]  # a valid, legible default exit

	# Placement: Start at the click (or right of the selection), End one node-drop below it.
	var start_pos: Vector2 = Vector2.ZERO
	if at_world is Vector2:
		start_pos = (
			(at_world as Vector2) - Vector2(GraphView.NODE_WIDTH, GraphView.NODE_HEIGHT) * 0.5
		)
	elif _selected_graph_node_id != "" and nodes.has(_selected_graph_node_id):
		start_pos = (
			(nodes[_selected_graph_node_id] as Dictionary).get("pos", Vector2.ZERO)
			+ Vector2(240.0, 0.0)
		)
	var end_pos: Vector2 = start_pos + Vector2(0.0, 200.0)

	nodes[start_id] = {
		"type": "loop_start",
		"data": start_data,
		"pos": GraphLayout.snap(start_pos),
		"out": [{"to": end_id}],
	}
	nodes[end_id] = {
		"type": "loop_end",
		"data": end_data,
		"pos": GraphLayout.snap(end_pos),
		"out": [],
	}
	if str(_graph_model.get("start", "")) == "":
		_graph_model["start"] = start_id
	_graph.select_graph_node(end_id)  # open the End's editor — its exit rules live there


# The other half of a Loop pair for a Loop Start / Loop End (or "" for any other node). Deleting one
# marker takes its partner with it — a lone marker is invalid (a Start with no End, or an End with no
# Start), so the two always live and die together.
func _loop_pair_partner(node_id: String) -> String:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var node: Dictionary = nodes.get(node_id, {})
	match str(node.get("type", "")):
		"loop_end":
			var start: String = str((node.get("data", {}) as Dictionary).get("loop_to", ""))
			return start if nodes.has(start) else ""
		"loop_start":
			for nid: String in nodes:
				var n: Dictionary = nodes[nid]
				if (
					str(n.get("type", "")) == "loop_end"
					and str((n.get("data", {}) as Dictionary).get("loop_to", "")) == node_id
				):
					return str(nid)
	return ""


# Graph editor: delete a node and every edge pointing at it. Re-homes the start if needed. A Loop marker
# takes its paired marker with it (a lone Loop Start / End is invalid).
func _delete_graph_node(node_id: String) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(node_id):
		return
	_push_undo()
	var doomed: Dictionary = {node_id: true}
	var partner: String = _loop_pair_partner(node_id)
	if partner != "":
		doomed[partner] = true
	for id: String in doomed:
		nodes.erase(id)
	for id: String in nodes:
		var kept: Array = []
		for e: Dictionary in (nodes[id] as Dictionary).get("out", []):
			if not doomed.has(str(e.get("to", ""))):
				kept.append(e)
		(nodes[id] as Dictionary)["out"] = kept
	if doomed.has(str(_graph_model.get("start", ""))):
		_graph_model["start"] = (nodes.keys()[0] as String) if not nodes.is_empty() else ""
	_deselect_node()


# Drops the current node selection. clear_graph_selection emits graph_selection_changed([]), which
# (via _on_graph_selection_changed) clears the mirror and returns the side panel to journey info.
func _deselect_node() -> void:
	_graph.clear_graph_selection()


# Deletes every node in the current selection — the Delete shortcut and the multi-select panel — as
# one undoable action. (Single-node delete from the node editor's button stays on _delete_graph_node.)
func _delete_selected_nodes() -> void:
	if _selected_graph_node_ids.is_empty():
		return
	_push_undo()
	var nodes: Dictionary = _graph_model.get("nodes", {})
	# Never delete a ghosted base node in rendition mode (they can't be selected either — belt-and-braces).
	var doomed: Array = _selected_graph_node_ids.filter(
		func(nid: String) -> bool: return not _rendition_parent_ids.has(nid)
	)
	# A Loop marker can't survive without its partner — pull the other half in too (dedup against the
	# selection, e.g. when both halves were already marquee-selected).
	for nid: String in doomed.duplicate():
		var partner: String = _loop_pair_partner(nid)
		if partner != "" and partner not in doomed:
			doomed.append(partner)
	for nid: String in doomed:
		nodes.erase(nid)
	# Strip every edge that pointed at a deleted node.
	for id: String in nodes:
		var kept: Array = []
		for e: Dictionary in (nodes[id] as Dictionary).get("out", []):
			if str(e.get("to", "")) not in doomed:
				kept.append(e)
		(nodes[id] as Dictionary)["out"] = kept
	if str(_graph_model.get("start", "")) in doomed:
		_graph_model["start"] = (nodes.keys()[0] as String) if not nodes.is_empty() else ""
	_remove_comments_by_index(_graph.get_selected_comments())  # marquee-selected notes go with the nodes
	_deselect_node()


# Removes the comments at the given indices (a marquee's multi-note delete). Rebuilds the array so shifting
# indices can't corrupt the removal. No undo of its own — the caller already snapshotted.
func _remove_comments_by_index(idxs: Array) -> void:
	if idxs.is_empty():
		return
	var drop: Dictionary = {}
	for i: Variant in idxs:
		drop[int(i)] = true
	var kept: Array = []
	var comments: Array = _graph_model.get("comments", [])
	for ci: int in comments.size():
		if not drop.has(ci):
			kept.append(comments[ci])
	_graph_model["comments"] = kept


# Delete the notes a marquee selected when the selection is notes-only (no nodes). One undo step.
func _delete_marquee_comments() -> void:
	var idxs: Array = _graph.get_selected_comments()
	if idxs.is_empty():
		return
	_push_undo()
	_remove_comments_by_index(idxs)
	_graph.clear_selected_comments()
	_refresh_graph()


# ── Clipboard (copy / cut / paste / duplicate) ───────────────────────────────


# Builds a clipboard-shaped list ([{id, node}] deep copies) from the current selection.
func _snapshot_selection() -> Array:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var entries: Array = []
	for id: String in _selected_graph_node_ids:
		# Never copy/duplicate a ghosted base node (a fork can now be selected to add overlay choices, but
		# it's still the locked base — copying it would spawn a rogue clone in the overlay).
		if nodes.has(id) and not _rendition_parent_ids.has(id):
			entries.append({"id": id, "node": (nodes[id] as Dictionary).duplicate(true)})
	return entries


# Deep copies of every sticky note pinned to a node in the current selection — captured alongside the nodes
# so copy/cut/paste/duplicate carries a pinned note with its node (paste remaps node_id, see _paste_nodes).
func _snapshot_pinned_comments() -> Array:
	var out: Array = []
	for c: Dictionary in _graph_model.get("comments", []):
		if _selected_graph_node_ids.has(str(c.get("node_id", ""))):
			out.append((c as Dictionary).duplicate(true))
	return out


# Removes every note pinned to one of `node_ids` (used on CUT so the notes travel with the cut nodes rather
# than dangling). No undo push of its own — the caller's node delete already snapshotted the notes.
func _remove_pinned_comments(node_ids: Array) -> void:
	var kept: Array = []
	for c: Dictionary in _graph_model.get("comments", []):
		if not node_ids.has(str(c.get("node_id", ""))):
			kept.append(c)
	_graph_model["comments"] = kept


# Ctrl+C — copy the active selection (a note or the node[s]). Mirrors the Delete priority:
# note → nodes (the selection is exclusive, so at most one applies).
func _copy_selection() -> void:
	if _selected_comment_idx >= 0:
		var comments: Array = _graph_model.get("comments", [])
		if _selected_comment_idx >= comments.size():
			return
		_clip_comment = (comments[_selected_comment_idx] as Dictionary).duplicate(true)
		_clip_kind = "comment"
		_paste_count = 0
		_show_status("Copied note — Ctrl+V to paste.", false)
	elif not _selected_graph_node_ids.is_empty():
		_node_clipboard = _snapshot_selection()
		_clip_comments = _snapshot_pinned_comments()
		_clip_kind = "nodes"
		_paste_count = 0
		_show_status(
			(
				"Copied %d node%s — Ctrl+V to paste."
				% [_node_clipboard.size(), "" if _node_clipboard.size() == 1 else "s"]
			),
			false
		)


# Ctrl+X — copy the active selection, then delete it (one undo step).
func _cut_selection() -> void:
	if _selected_comment_idx >= 0:
		var comments: Array = _graph_model.get("comments", [])
		if _selected_comment_idx >= comments.size():
			return
		_clip_comment = (comments[_selected_comment_idx] as Dictionary).duplicate(true)
		_clip_kind = "comment"
		_paste_count = 0
		_delete_comment(_selected_comment_idx)
	elif not _selected_graph_node_ids.is_empty():
		var sel_ids: Array = _selected_graph_node_ids.duplicate()
		_node_clipboard = _snapshot_selection()
		_clip_comments = _snapshot_pinned_comments()
		_clip_kind = "nodes"
		_paste_count = 0
		_delete_selected_nodes()  # pushes ONE undo snapshotting the nodes AND their pinned notes
		_remove_pinned_comments(sel_ids)  # the notes leave with the cut nodes (same undo step)
		_refresh_graph()


# Ctrl+V — paste the clipboard into the CENTRE OF THE CURRENT VIEW (not back at the copied nodes'
# original spot, which is often scrolled off-screen), cascading down-right on repeated pastes.
func _paste_clipboard() -> void:
	if _clip_kind == "":
		return
	_paste_count += 1
	match _clip_kind:
		"nodes":
			_paste_nodes(
				_node_clipboard,
				_view_paste_offset(_clip_positions(_node_clipboard)),
				_clip_comments
			)
		"comment":
			var cpos: Vector2 = _clip_comment.get("pos", Vector2.ZERO)
			_paste_comment(_clip_comment, _view_paste_offset([cpos]))


# Ctrl+D — duplicate the active selection in place (a small nudge off the original, so the copy is
# visible right where the author is working — deliberately NOT recentred on the view like paste).
func _duplicate_selection() -> void:
	if _selected_comment_idx >= 0:
		var comments: Array = _graph_model.get("comments", [])
		if _selected_comment_idx < comments.size():
			_paste_comment(
				(comments[_selected_comment_idx] as Dictionary).duplicate(true), PASTE_OFFSET
			)
	elif not _selected_graph_node_ids.is_empty():
		_paste_nodes(_snapshot_selection(), PASTE_OFFSET, _snapshot_pinned_comments())


# Top-left positions of a clipboard-shaped node list, used to find the group's bounds for centering.
func _clip_positions(entries: Array) -> Array:
	var out: Array = []
	for entry: Dictionary in entries:
		out.append((entry.get("node", {}) as Dictionary).get("pos", Vector2.ZERO) as Vector2)
	return out


# Offset that lands the pasted group's centre on the current view centre, then cascades down-right on
# repeat pastes so successive Ctrl+V don't stack exactly. `positions` are the source top-left corners;
# adding half a node recentres the group on its middle rather than its top-left corner.
func _view_paste_offset(positions: Array) -> Vector2:
	if positions.is_empty():
		return Vector2.ZERO
	var top_left: Vector2 = positions[0]
	var bottom_right: Vector2 = positions[0]
	for p: Vector2 in positions:
		top_left = top_left.min(p)
		bottom_right = bottom_right.max(p)
	var half_node: Vector2 = Vector2(GraphView.NODE_WIDTH, GraphView.NODE_HEIGHT) * 0.5
	var group_centre: Vector2 = (top_left + bottom_right) * 0.5 + half_node
	var cascade: Vector2 = PASTE_OFFSET * float(_paste_count - 1)
	return _graph.view_center_world() - group_centre + cascade


# Creates fresh nodes from a clipboard-shaped list, translated by `offset` (view-centred on paste, a
# small nudge on duplicate). Edges between copied nodes are remapped to the new ids; an edge leaving
# the copied set is dropped (regular node) or unwired (fork choice, so the fork keeps all its slots).
# Pushes undo and selects the new nodes.
func _paste_nodes(entries: Array, offset: Vector2, pinned_comments: Array = []) -> void:
	if entries.is_empty():
		return
	_push_undo()
	if not _graph_model.has("nodes"):
		_graph_model["nodes"] = {}
	var nodes: Dictionary = _graph_model["nodes"]
	# Fresh id per copied node, so internal edges can be remapped from old id -> new id.
	var old_to_new_id: Dictionary = {}
	for entry: Dictionary in entries:
		old_to_new_id[str(entry["id"])] = JourneyData.new_node_id()
	var pasted_ids: Array = []
	for entry: Dictionary in entries:
		var src: Dictionary = entry["node"]
		var new_id: String = str(old_to_new_id[str(entry["id"])])
		var src_type: String = str(src.get("type", "round"))
		var out_edges: Array = []
		if src_type == "fork":
			# A fork keeps every slot: an edge to a node outside the copied set is unwired (to = "").
			for edge: Dictionary in src.get("out", []):
				var new_edge: Dictionary = (edge as Dictionary).duplicate(true)
				var target_id: String = str(edge.get("to", ""))
				new_edge["to"] = (
					str(old_to_new_id[target_id]) if old_to_new_id.has(target_id) else ""
				)
				out_edges.append(new_edge)
		else:
			# A regular node just drops any edge leaving the copied set.
			for edge: Dictionary in src.get("out", []):
				var target_id: String = str(edge.get("to", ""))
				if old_to_new_id.has(target_id):
					var new_edge: Dictionary = (edge as Dictionary).duplicate(true)
					new_edge["to"] = str(old_to_new_id[target_id])
					out_edges.append(new_edge)
		var data: Dictionary = (src.get("data", {}) as Dictionary).duplicate(true)
		data.erase("type")
		data.erase("node_id")
		data.erase("paths")  # node/edge-level keys never live in data
		nodes[new_id] = {
			"type": src_type,
			"data": data,
			"pos": GraphLayout.snap((src.get("pos", Vector2.ZERO) as Vector2) + offset),
			"out": out_edges,
		}
		if str(_graph_model.get("start", "")) == "":
			_graph_model["start"] = new_id
		pasted_ids.append(new_id)

	# Re-create the notes that were pinned to the copied nodes, re-pinned to the new node ids and offset by
	# the same amount so each note lands in the same spot beside its (pasted) node.
	if not pinned_comments.is_empty():
		if not _graph_model.has("comments"):
			_graph_model["comments"] = []
		var comments: Array = _graph_model["comments"]
		for pc: Dictionary in pinned_comments:
			var old_nid: String = str(pc.get("node_id", ""))
			if not old_to_new_id.has(old_nid):
				continue  # its node wasn't in the pasted set — skip rather than leave a dangling pin
			var nc: Dictionary = (pc as Dictionary).duplicate(true)
			nc["node_id"] = str(old_to_new_id[old_nid])
			nc["pos"] = GraphLayout.snap((pc.get("pos", Vector2.ZERO) as Vector2) + offset)
			comments.append(nc)

	_graph.set_selection(pasted_ids)
	_show_status(
		"Pasted %d node%s." % [pasted_ids.size(), "" if pasted_ids.size() == 1 else "s"], false
	)


# Paste a sticky note from the clipboard, translated by `offset` (view-centred on paste, a small
# nudge on duplicate); selects it. One undo step.
func _paste_comment(comment: Dictionary, offset: Vector2) -> void:
	if comment.is_empty():
		return
	_push_undo()
	if not _graph_model.has("comments"):
		_graph_model["comments"] = []
	var comments: Array = _graph_model["comments"]
	var nc: Dictionary = comment.duplicate(true)
	nc["pos"] = GraphLayout.snap((comment.get("pos", Vector2.ZERO) as Vector2) + offset)
	comments.append(nc)
	_graph.deselect_nodes_silent()
	_selected_graph_node_ids = []
	_selected_graph_node_id = ""
	_selected_frame_idx = -1
	_selected_comment_idx = comments.size() - 1
	_refresh_graph()
	_side_renderer.show_comment_editor(_selected_comment_idx)
	_show_status("Pasted note.", false)


# Graph editor click-to-connect: arm/cancel connect mode from `source_id` (a regular node's
# single out-edge). While armed, the next node click on the canvas is the target (see
# _on_connect_target_picked → _finish_connect).
func _begin_connect(source_id: String) -> void:
	if _connecting_from == source_id and _connecting_edge_idx == -1:
		_connecting_from = ""
		_graph.set_connect_mode(false)
		_show_status("Connect cancelled.", false)
	else:
		_connecting_from = source_id
		_connecting_edge_idx = -1
		_graph.set_connect_mode(true)
		_show_status("Connect: click the target node on the graph (or press Cancel).", false)
	_side_renderer.show_graph_node_editor(source_id)


# Graph editor (fork out-edges): arm/cancel connect mode for a specific fork CHOICE (out-edge
# index) rather than a regular node's single edge. The next node click wires that choice's target.
func _begin_connect_fork_edge(fork_id: String, edge_idx: int) -> void:
	if _connecting_from == fork_id and _connecting_edge_idx == edge_idx:
		_connecting_from = ""
		_connecting_edge_idx = -1
		_graph.set_connect_mode(false)
		_show_status("Connect cancelled.", false)
	else:
		_connecting_from = fork_id
		_connecting_edge_idx = edge_idx
		_graph.set_connect_mode(true)
		_show_status("Connect: click the target node for this choice (or press Cancel).", false)
	_side_renderer.show_graph_node_editor(fork_id)


# Rendition authoring: appends an OVERLAY choice to a ghosted base fork — an extra option shown only when
# this rendition is installed. It's an append-anchor ({_anchor}, no `_slot`), unconnected until the author
# wires it. Capped at the 4-choice ForkScreen layout (base slots + overlay choices).
func _add_overlay_fork_choice(fork_id: String) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(fork_id):
		return
	var out: Array = (nodes[fork_id] as Dictionary).get("out", [])
	if out.size() >= 4:
		_show_status("This fork is full — 4 choices max.", true)
		return
	_push_undo()
	out.append({"to": "", "name": "", "image_path": "", "_anchor": true})
	(nodes[fork_id] as Dictionary)["out"] = out
	_refresh_graph()
	_side_renderer.show_graph_node_editor(fork_id)
	_show_status("Overlay choice added — name it, then connect it to a node.", false)


# Removes an OVERLAY choice (an append-anchor) from a ghosted base fork. Never touches a base choice or a
# filled base slot — those are base-owned. Overlay choices always sit AFTER the base's, so removing one
# can't shift a filled slot's recorded index.
func _remove_overlay_fork_choice(fork_id: String, edge_idx: int) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(fork_id):
		return
	var out: Array = (nodes[fork_id] as Dictionary).get("out", [])
	if edge_idx < 0 or edge_idx >= out.size():
		return
	var edge: Dictionary = out[edge_idx]
	if not bool(edge.get("_anchor", false)) or edge.has("_slot"):
		return  # a base choice or a filled base slot — not an overlay choice
	_push_undo()
	_side_renderer._delete_saved_image(str(edge.get("image_path", "")))
	out.remove_at(edge_idx)
	_refresh_graph()
	_side_renderer.show_graph_node_editor(fork_id)
	_show_status("Overlay choice removed.", false)


# Completes a click-to-connect: wires the armed source to `target_id` — either a fork choice's
# out-edge (when _connecting_edge_idx >= 0) or a regular node's single out-edge. Rejects a
# self-link or anything that would form a cycle (the runtime is a DAG). Re-selects the source.
func _finish_connect(target_id: String) -> void:
	var source: String = _connecting_from
	var edge_idx: int = _connecting_edge_idx
	_connecting_from = ""
	_connecting_edge_idx = -1
	_graph.set_connect_mode(false)
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if source == "" or not nodes.has(source):
		return
	# Rendition ANCHOR: dragging from a ghosted base node attaches a new overlay path here. It's ADDITIVE
	# (appended, never replacing the base's own edges) and the base is never re-saved, so it can't be
	# corrupted. The delta save extracts these `_anchor` edges (later slice).
	if _rendition_parent_ids.has(source):
		_finish_anchor(source, target_id, edge_idx)
		return
	if target_id == source or not nodes.has(target_id):
		_show_status("Connect cancelled (can't link a node to itself).", true)
		_graph.select_graph_node(source)
		return
	if JourneyGraph.reachable_ids(_graph_model, target_id).has(source):
		_show_status("Can't connect — that would create a loop.", true)
		_graph.select_graph_node(source)
		return
	# A fork can't point two of its choices at the same node — one choice per target.
	if edge_idx >= 0:
		var src_out: Array = (nodes[source] as Dictionary).get("out", [])
		for j in src_out.size():
			if j != edge_idx and str((src_out[j] as Dictionary).get("to", "")) == target_id:
				_show_status("That fork already has a choice leading to this node.", true)
				_graph.select_graph_node(source)
				return
	_push_undo()
	if edge_idx >= 0:
		# Fork choice — wire just this out-edge, leaving the fork's other choices untouched.
		var edges: Array = (nodes[source] as Dictionary).get("out", [])
		if edge_idx < edges.size():
			(edges[edge_idx] as Dictionary)["to"] = target_id
	else:
		(nodes[source] as Dictionary)["out"] = [{"to": target_id}]
	_graph.select_graph_node(source)


# Attaches a rendition ANCHOR from a ghosted base node to a NEW overlay node. Additive — the base's own
# structure is never rewritten on disk. Forms, by where the connect started (`edge_idx`):
#  • edge_idx < 0 (a node's single out-handle): only a base ENDING may be anchored — a rendition EXTENDS
#    an ending, never splices into mid-flow. One overlay path per ending, and re-dragging re-points it.
#  • edge_idx ≥ 0 (a fork choice): if that out-edge is a VIRGIN base slot, FILL it in place (marked `_slot`
#    so compose fills that reserved choice); if it's already an overlay anchor (an appended overlay choice
#    or a re-point), just (re)point `to` — it stays an APPEND with no `_slot`, so compose adds an extra
#    choice. A base-wired choice is off limits.
# Refuses to anchor onto another base node (you attach overlay content, not re-wire the base) or to loop.
func _finish_anchor(source: String, target_id: String, edge_idx: int = -1) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(target_id) or _rendition_parent_ids.has(target_id):
		_show_status("Anchor to a NEW node — not the locked base.", true)
		return
	if target_id == source:
		return
	if JourneyGraph.reachable_ids(_graph_model, target_id).has(source):
		_show_status("Can't anchor — that would create a loop.", true)
		return
	var out: Array = (nodes[source] as Dictionary).get("out", [])
	# A fork choice handle. Two cases, distinguished by whether this out-edge is already an overlay anchor:
	#  • a VIRGIN base open slot (not yet an anchor) → fill it IN PLACE and record `_slot` so compose fills
	#    that exact reserved choice (keeps the fork's choice count).
	#  • an OVERLAY choice (already `_anchor`: an appended option, or one re-pointed) → just (re)point `to`;
	#    it stays an APPEND with no `_slot`, so compose adds it as an extra choice.
	if edge_idx >= 0:
		if edge_idx >= out.size():
			return
		var choice: Dictionary = out[edge_idx]
		var was_anchor: bool = bool(choice.get("_anchor", false))
		if str(choice.get("to", "")) != "" and not was_anchor:
			_show_status("That fork choice is set by the base — pick an open slot.", true)
			return
		_push_undo()
		choice["to"] = target_id
		choice["_anchor"] = true
		if not was_anchor:
			choice["_slot"] = edge_idx  # first-time fill of a base open slot
		_refresh_graph()
		_show_status(
			(
				"Fork slot filled — this overlay path fills the open choice."
				if choice.has("_slot")
				else "Overlay choice connected."
			),
			false
		)
		return
	# One overlay path per ending, but reassignable: a drag from an already-anchored ending RE-POINTS its
	# existing anchor rather than adding a second. A non-anchor (base) edge means it isn't an ending.
	var anchor_edge: Dictionary = {}
	for e: Dictionary in out:
		if bool(e.get("_anchor", false)):
			anchor_edge = e
		else:
			_show_status(
				"Anchor a base ENDING only — that node already continues in the base.", true
			)
			return
	_push_undo()
	if anchor_edge.is_empty():
		out.append({"to": target_id, "_anchor": true})
		(nodes[source] as Dictionary)["out"] = out
		_refresh_graph()
		_show_status("Anchor added — this overlay path attaches after the base node.", false)
	else:
		anchor_edge["to"] = target_id  # re-point the existing anchor to the new target
		_refresh_graph()
		_show_status("Anchor re-pointed to the new node.", false)


# Drops an armed click-to-connect (the Escape shortcut), restoring the source node's editor.
func _cancel_connect() -> void:
	var src: String = _connecting_from
	_connecting_from = ""
	_connecting_edge_idx = -1
	_graph.set_connect_mode(false)
	_show_status("Connect cancelled.", false)
	if src != "" and (_graph_model.get("nodes", {}) as Dictionary).has(src):
		_side_renderer.show_graph_node_editor(src)
	else:
		_deselect_node()


# Graph editor: clear a regular node's out-edge so it ends the run here.
func _disconnect_graph_node(node_id: String) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(node_id):
		return
	_push_undo()
	(nodes[node_id] as Dictionary)["out"] = []
	_graph.select_graph_node(node_id)


# Graph editor: clear a single fork CHOICE's target (the choice still exists but ends the run
# when taken). Distinct from _remove_fork_edge, which deletes the choice entirely.
func _clear_fork_edge(fork_id: String, edge_idx: int) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(fork_id):
		return
	var edges: Array = (nodes[fork_id] as Dictionary).get("out", [])
	if edge_idx >= 0 and edge_idx < edges.size():
		_push_undo()
		(edges[edge_idx] as Dictionary)["to"] = ""
	_graph.select_graph_node(fork_id)


# Graph editor: append a new unconnected choice (out-edge) to a fork — the author then wires its
# target. Mirrors the tree fork's "+ ADD PATH" default fields.
func _add_fork_edge(fork_id: String) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(fork_id):
		return
	_push_undo()
	var edges: Array = (nodes[fork_id] as Dictionary).get("out", [])
	(
		edges
		. append(
			{
				"to": "",
				"name": "Path %s" % char(65 + edges.size()),
				"description": "",
				"image_path": "",
				"weight": 1,
				"threshold": 0,
				"required_item": "",
				"cost": 0,
			}
		)
	)
	(nodes[fork_id] as Dictionary)["out"] = edges
	_graph.select_graph_node(fork_id)


# Graph editor: delete a fork choice (out-edge) entirely. Keeps the conditional fallback index
# (default_path) in range after the removal. Re-renders.
func _remove_fork_edge(fork_id: String, edge_idx: int) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(fork_id):
		return
	var node: Dictionary = nodes[fork_id]
	var edges: Array = node.get("out", [])
	if edge_idx < 0 or edge_idx >= edges.size():
		return
	_push_undo()
	edges.remove_at(edge_idx)
	var data: Dictionary = node.get("data", {})
	if int(data.get("default_path", 0)) >= edges.size():
		data["default_path"] = max(0, edges.size() - 1)
	# timeout_path may be -1 (random); only clamp a real index that now points past the end.
	if int(data.get("timeout_path", -1)) >= edges.size():
		data["timeout_path"] = -1
	_graph.select_graph_node(fork_id)


# ── Undo / redo (graph structure) ───────────────────────────────────────────
# Snapshot-based undo of the GRAPH STRUCTURE — node create / delete, edge wire / clear, fork-choice
# add / remove. Each entry is a deep copy of _graph_model (start + nodes) taken just before a
# structural mutation. In-field text edits (names, coins, …) are deliberately NOT snapshotted —
# they keep their own native LineEdit/TextEdit undo. Drag-reposition isn't covered yet.


# Deep snapshot of the graph model for the undo stack.
func _graph_snapshot() -> Dictionary:
	return {
		"start": str(_graph_model.get("start", "")),
		"nodes": (_graph_model.get("nodes", {}) as Dictionary).duplicate(true),
		"comments": (_graph_model.get("comments", []) as Array).duplicate(true),
		"groups": (_graph_model.get("groups", []) as Array).duplicate(true),
	}


# Everything the author can change, as one comparable string.
#
# The _journey_* fields are collected by REFLECTION rather than a hand-written list. There are two
# dozen of them and every release adds more, and a field left off such a list would make this answer
# "nothing changed" for an edit that really happened — the one failure here that silently destroys
# work. The graph comes from the same snapshot the undo stack already trusts.
func _dirty_signature() -> String:
	var state: Dictionary = {"graph": _graph_snapshot()}
	for prop: Dictionary in get_property_list():
		var prop_name: String = str(prop.get("name", ""))
		if not prop_name.begins_with("_journey_"):
			continue
		var value: Variant = get(prop_name)
		# A node or resource reference has no stable text form; none of these fields should hold one,
		# but a future one might, and JSON.stringify would quietly emit null for every such field and
		# make them all compare equal.
		if not (value is Object):
			state[prop_name] = value
	return JSON.stringify(state)


# This is now the state on disk — take it as the baseline the back button compares against.
func _mark_clean() -> void:
	_saved_signature = _dirty_signature()


func _has_unsaved_changes() -> bool:
	# No baseline means nothing was ever loaded or saved, so there is nothing to have diverged from.
	return _saved_signature != "" and _dirty_signature() != _saved_signature


# Records the current graph state so the next mutation can be undone. A fresh action invalidates the
# redo future; the stack is bounded so a long session can't grow it without limit.
func _push_undo() -> void:
	_undo_stack.append(_graph_snapshot())
	if _undo_stack.size() > UNDO_LIMIT:
		_undo_stack.pop_front()
	_redo_stack.clear()
	_audit_result = {}  # structural change → the cached audit no longer matches
	# The heatmap percentages reference the pre-edit structure — turn it off
	# quietly (the mutation's own _refresh_graph re-renders without the overlay).
	if _traffic_btn and _traffic_btn.button_pressed:
		_traffic_btn.set_pressed_no_signal(false)
		if _graph:
			_graph.set_traffic({})


# Ctrl+Z — reverts to the structure captured by the last _push_undo().
func _undo() -> void:
	if _undo_stack.is_empty():
		return
	var snap: Dictionary = _undo_stack.pop_back()
	_redo_stack.append(_graph_snapshot())
	_restore_graph_snapshot(snap)
	# Reversing an EXTRACTION: the extracted nodes are now back in the base, so the rendition written at
	# extract time is a duplicate — delete it (and its isolated saves). Redo can't recreate that file, so
	# drop the redo future to avoid a broken re-apply that would lose the nodes.
	if snap.has("_extract_folder"):
		_delete_rendition_artifacts(str(snap["_extract_folder"]))
		_redo_stack.clear()
		_show_status("Undo — extracted rendition removed.", false)
	else:
		_show_status("Undo.", false)


# Deletes a rendition's journey folder (by folder name) plus any isolated run-saves/scoreboard it spawned.
# Used by extract-undo and could back a catalogue delete. Idempotent.
func _delete_rendition_artifacts(rend_name: String) -> void:
	var folder_name: String = JourneyData.sanitize_folder_name(rend_name)
	if folder_name == "":
		return
	JourneyData.delete_dir_recursive(SettingsService.get_journeys_dir() + "/" + folder_name)
	# A composed run keys its save/scoreboard under "<base>__rend_<rendition>"; a just-extracted rendition
	# has never been played, but clean defensively in case it was.
	var run_key: String = JourneyData.sanitize_folder_name(
		JourneyData.sanitize_folder_name(str(_journey_name)) + "__rend_" + folder_name
	)
	JourneySaveService.delete_save(run_key)
	ScoreboardService.clear(run_key)


# Ctrl+Y / Ctrl+Shift+Z — reapplies the most recently undone structure.
func _redo() -> void:
	if _redo_stack.is_empty():
		return
	_undo_stack.append(_graph_snapshot())
	_restore_graph_snapshot(_redo_stack.pop_back())
	_show_status("Redo.", false)


# Restores a snapshot IN PLACE (clear + repopulate with a fresh deep copy, so the entry left on the
# other stack stays independent) — the deferred set_graph + GraphView keep sharing the _graph_model
# reference (see GOTCHAS). Cancels any armed wire; re-selects the previously-selected node if it
# survived, else returns to the journey-info panel.
func _restore_graph_snapshot(snap: Dictionary) -> void:
	_connecting_from = ""
	_connecting_edge_idx = -1
	_graph.set_connect_mode(false)
	_graph_model.clear()
	_graph_model["start"] = str(snap.get("start", ""))
	_graph_model["nodes"] = (snap.get("nodes", {}) as Dictionary).duplicate(true)
	_graph_model["comments"] = (snap.get("comments", []) as Array).duplicate(true)
	_graph_model["groups"] = (snap.get("groups", []) as Array).duplicate(true)
	# Re-apply the selection, dropping any node the restore removed.
	var survivors: Array = []
	for id: String in _selected_graph_node_ids:
		if (_graph_model["nodes"] as Dictionary).has(id):
			survivors.append(id)
	if survivors.is_empty():
		_deselect_node()
	else:
		_graph.set_selection(survivors)


# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------


func _show_status(msg: String, is_error: bool) -> void:
	_status_lbl.text = msg
	_status_lbl.add_theme_color_override(
		"font_color", UITheme.ERROR_SOFT if is_error else UITheme.SUCCESS
	)
	_status_lbl.visible = true


func _on_save_pressed() -> void:
	# Top-level orchestrator. Each phase is a named helper returning a clear
	# success/failure signal so the flow reads as a sequence of steps rather
	# than 250 lines of nested branches. Helpers that fail are responsible for
	# their own user-facing error modal and any staging cleanup.
	_commit_focused_field()
	_save_btn.disabled = true
	_reset_save_state()
	if not await _do_save():
		_save_btn.disabled = false


# Drops focus from whatever side-panel field holds it so its pending edit commits before the
# save reads the round data. Clicking Save straight from a field would otherwise write the
# value the field had when it was last committed, not what's on screen.
func _commit_focused_field() -> void:
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused != null:
		focused.release_focus()


# "Save & Test from here" entry point. Runs the exact same save pipeline as a
# normal save (so the preview plays the real, transcoded on-disk journey), then
# — instead of returning to the catalogue — launches GameLoop in test mode at
# the selected node, identified by its stable node_id. We backfill ids across the
# tree first (so a never-saved item still has one), capture the selected node's,
# persist it in the save, and seek to it after reload (see _launch_test_play).
# `_arr` (the node's containing array) is no longer needed to locate it.
# _reset_save_state clears the pending location, so it's set *after* the reset.
func _save_and_test_from(item: Dictionary, _arr: Array) -> void:
	var node_id: String = str(item.get("node_id", ""))
	if node_id == "":
		_show_status("Test play: couldn't identify that node.", true)
		return
	_save_btn.disabled = true
	_reset_save_state()
	_pending_test_location = {"node_id": node_id}
	if not await _do_save():
		_save_btn.disabled = false
		_pending_test_location = {}


# Parses the just-saved journey into the runtime GRAPH, starts it in GameState, and
# hands off to GameLoop in test mode. Called from _do_save after the staging swap, so
# the on-disk journey is final and complete.
#
# Test "from here": _save_and_test_from stashed the selected node's stable id in
# _pending_test_location. Now that the journey is on disk with persistent NodeIds,
# parse_graph keys the runtime graph by those ids, so we seek straight to it.
func _launch_test_play(paths: Dictionary) -> void:
	var seek_node: String = str(_pending_test_location.get("node_id", ""))
	_pending_test_location = {}

	var folder_name: String = (paths["final_abs_dir"] as String).get_file()
	var journey_path: String = SettingsService.get_journeys_dir() + "/" + folder_name
	var journey: Dictionary = JourneyScanner.parse_graph(journey_path, folder_name)
	if journey.is_empty():
		_show_status("Test play failed: could not read the saved journey.", true)
		_save_btn.disabled = false
		return

	GameState.StartJourney(journey)
	# Seek the walker to the selected node (no-op fallback to the start if its id
	# isn't in the graph). The DAG lets us jump without replaying fork decisions.
	if seek_node != "":
		GameState.SeekToNode(seek_node)

	# Handshake metas read (and cleared) by GameLoop._ready. The return journey is the
	# combined dict the builder reloads when the test exits — it still carries the nested
	# catalogue model for legacy journeys, which _load_graph migrates on reload.
	GameState.set_meta("_test_mode", true)
	GameState.set_meta("_test_return_journey", journey)
	GameState.set_meta("_test_seed_score", _test_seed_score)
	GameState.set_meta("_test_seed_coins", _test_seed_coins)
	GameState.set_meta("_test_seed_flags", _test_seed_flags)
	GameState.set_meta("_test_seed_items", _test_seed_items)
	GameState.set_meta("_test_seed_counters", _test_seed_counters)
	Transition.change_scene("res://scenes/game_loop/GameLoop.tscn")


# Returns true on a fully successful save (which transitions the user away
# from the editor), false on any failure or cancellation. Each helper that
# returns false has already shown the user a specific error modal. Staging-
# folder cleanup is centralised here so the per-phase code stays focused on
# its own responsibility.
func _do_save() -> bool:
	# Rendition mode saves an overlay delta to its own folder — never the base — via a separate path.
	if _rendition_mode:
		return await _save_rendition()
	if not _validate_presave():
		return false
	if not _check_animated_images():
		return false
	if not _build_transcode_plan():
		return false

	var paths: Dictionary = _setup_save_folders()
	var modal: Control = _create_save_progress_modal_if_needed()

	var data: Dictionary = await _save_graph_nodes(paths, modal)
	if modal:
		modal.queue_free()

	# Any failure past this point (including an empty data return from
	# _save_all_items) requires wiping the staging folder. Each helper
	# already showed its own error modal; we just handle the disk cleanup.
	if data.is_empty():
		JourneyData.delete_dir_recursive(paths["abs_dir"])
		return false

	if not _write_journey_json(paths, data):
		JourneyData.delete_dir_recursive(paths["abs_dir"])
		return false

	_swap_staging_into_place(paths)
	_invalidate_existing_run_saves(paths)
	if not _pending_test_location.is_empty():
		_launch_test_play(paths)
	else:
		_finalize_save_success()
	return true


# ── Extract to rendition (feature #3) ─────────────────────────────────────────


# Feature #3 entry (from the selection panels): validate the current node selection, then confirm the
# split. Extraction only makes sense on a SAVED base journey — the overlay needs the base's JourneyId as
# its parent, and the base folder on disk to pool the extracted media from.
func _begin_extract_to_rendition() -> void:
	if _rendition_mode:
		_show_status("You're editing a rendition — extraction works on a base journey.", true)
		return
	if _journey_id.strip_edges() == "" or _original_journey_folder.strip_edges() == "":
		_show_builder_message(
			"SAVE FIRST",
			"Extraction pulls the selected nodes into a SEPARATE rendition that overlays this journey — so the journey must be saved first (it becomes the rendition's parent). Save, then extract."
		)
		return
	var result: Dictionary = JourneyExtract.extract_rendition(
		_graph_model, _selected_graph_node_ids
	)
	var errors: Array = result.get("errors", [])
	if not errors.is_empty():
		_show_builder_message("CAN'T EXTRACT", _extract_error_text(errors))
		return
	_show_extract_confirm(result, _unique_extract_name())


# Names the extracted overlay so its folder can't collide with the base's: "<base> — extract", bumped to
# "…2", "…3" if that folder already exists.
func _unique_extract_name() -> String:
	var base_name: String = _journey_name.strip_edges()
	if base_name == "":
		base_name = "Journey"
	var root: String = SettingsService.get_journeys_dir()
	var stem: String = base_name + " — extract"
	var candidate: String = stem
	var n: int = 2
	while DirAccess.dir_exists_absolute(
		ProjectSettings.globalize_path(root + "/" + JourneyData.sanitize_folder_name(candidate))
	):
		candidate = "%s %d" % [stem, n]
		n += 1
	return candidate


# A human message for an extraction JourneyExtract refused.
func _extract_error_text(errors: Array) -> String:
	match str((errors[0] as Dictionary).get("kind", "")):
		"empty_selection":
			return "Select the nodes you want to pull into a rendition first."
		"selects_start":
			return "The selection includes the journey's START node, which can't move to an overlay. Leave the start in the base."
		"fork_underflow":
			return "A fork would be left with fewer than 2 choices. Extract the whole fork, or leave it enough choices to stand on its own."
		"no_anchor":
			return "Nothing in the rest of the journey leads into the selection, so the rendition would have no attachment point. Select a branch that hangs off the base — not a disconnected island."
		"missing_node":
			return "The selection referenced a node that no longer exists. Reselect and try again."
	return "This selection can't be extracted into a clean rendition."


func _show_extract_confirm(result: Dictionary, rend_name: String) -> void:
	var count: int = (result["rendition"]["nodes"] as Dictionary).size()
	var parts: Dictionary = UITheme.build_centered_modal(
		"EXTRACT TO RENDITION", UITheme.CYAN, Vector2i(560, 300)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	var lbl: Label = Label.new()
	lbl.text = (
		'Move %d selected node%s into a new rendition:\n\n"%s"\n\nThe rendition is saved now. This journey keeps the rest — Save it afterwards to finalize the base.'
		% [count, "s" if count != 1 else "", rend_name]
	)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(lbl, UITheme.WHITE_SOFT, 13, false)
	vbox.add_child(lbl)
	var row: HBoxContainer = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)
	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(140, 0)
	UITheme.style_button(cancel_btn, UITheme.PURPLE_MID)
	cancel_btn.pressed.connect(func() -> void: modal.queue_free())
	row.add_child(cancel_btn)
	var go_btn: Button = Button.new()
	go_btn.text = "⑂ EXTRACT"
	go_btn.custom_minimum_size = Vector2(180, 0)
	UITheme.style_button(go_btn, UITheme.CYAN)
	go_btn.pressed.connect(
		func() -> void:
			modal.queue_free()
			_do_extract(result, rend_name)
	)
	row.add_child(go_btn)
	add_child(modal)


# A plain message + OK modal, built dynamically like the other builder dialogs.
func _show_builder_message(title: String, body: String) -> void:
	var parts: Dictionary = UITheme.build_centered_modal(
		title, UITheme.PURPLE_BRIGHT, Vector2i(560, 260)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	var lbl: Label = Label.new()
	lbl.text = body
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(lbl, UITheme.WHITE_SOFT, 13, false)
	vbox.add_child(lbl)
	var row: HBoxContainer = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(row)
	var ok_btn: Button = Button.new()
	ok_btn.text = "OK"
	ok_btn.custom_minimum_size = Vector2(140, 0)
	UITheme.style_button(ok_btn, UITheme.PURPLE_MID)
	ok_btn.pressed.connect(func() -> void: modal.queue_free())
	row.add_child(ok_btn)
	add_child(modal)


# Writes the extracted rendition to disk, then removes the extracted nodes from the base IN MEMORY (the
# author Saves to finalize). Temporarily borrows the rendition-authoring state — the FINAL base as the
# ghosted parent + the extracted nodes + the anchors injected onto the base — to drive _write_rendition_pack,
# then restores base editing. On failure the base is left exactly as it was.
func _do_extract(result: Dictionary, rend_name: String) -> void:
	var base_graph: Dictionary = result["base"]
	var delta: Dictionary = result["rendition"]
	var extracted_count: int = (delta["nodes"] as Dictionary).size()

	# The pristine base graph (JourneyExtract deep-copies, so _graph_model is untouched) — for undo + the
	# state we restore afterwards.
	var snap_graph: Dictionary = _graph_model
	var snap_id: String = _journey_id
	var snap_name: String = _journey_name
	var snap_folder: String = _original_journey_folder

	# Transient rendition-authoring graph: the final base (ghosted parent) + extracted nodes, with the
	# anchors injected onto the base nodes so _extract_anchors picks them up.
	var authoring: Dictionary = {}
	for id: String in base_graph["nodes"] as Dictionary:
		authoring[id] = (base_graph["nodes"][id] as Dictionary).duplicate(true)
	for id: String in delta["nodes"] as Dictionary:
		authoring[id] = (delta["nodes"][id] as Dictionary).duplicate(true)
	for a: Dictionary in delta["anchors"] as Array:
		var aid: String = str(a.get("anchor", ""))
		if not authoring.has(aid):
			continue
		var an: Dictionary = authoring[aid]
		if not an.has("out"):
			an["out"] = []
		var edge: Dictionary = (a.get("edge", {}) as Dictionary).duplicate(true)
		edge["_anchor"] = true
		(an["out"] as Array).append(edge)

	_reset_save_state()
	_graph_model = {"start": str(base_graph.get("start", "")), "nodes": authoring}
	_rendition_mode = true
	_rendition_parent_id = snap_id
	_rendition_parent_folder = snap_folder
	_rendition_parent_ids = {}
	for id: String in base_graph["nodes"] as Dictionary:
		_rendition_parent_ids[id] = true
	_rendition_slot_fills = []
	_journey_id = ""
	_journey_name = rend_name
	_original_journey_folder = ""

	var ok: bool = await _write_rendition_pack()

	# Restore base editing regardless of outcome.
	_rendition_mode = false
	_rendition_parent_ids = {}
	_rendition_parent_id = ""
	_rendition_parent_folder = ""
	_rendition_slot_fills = []
	_journey_id = snap_id
	_journey_name = snap_name
	_original_journey_folder = snap_folder
	if not ok:
		_graph_model = snap_graph  # write failed / cancelled — base untouched
		_refresh_graph()
		return
	# Apply the base-node removal as an undoable step. Stamp the undo entry with the written rendition's
	# folder so undoing the extraction also deletes it (the nodes come back to the base, so the rendition
	# would otherwise be a duplicate) — see _undo.
	_graph_model = snap_graph
	_push_undo()
	if not _undo_stack.is_empty():
		(_undo_stack[-1] as Dictionary)["_extract_folder"] = rend_name
	# Reduced base — keep the base's comments/groups (only its nodes/start changed).
	_graph_model = {
		"start": str(base_graph.get("start", "")),
		"nodes": base_graph["nodes"],
		"comments": snap_graph.get("comments", []),
		"groups": snap_graph.get("groups", []),
	}
	_graph.clear_graph_selection()
	_refresh_graph()
	_show_status(
		(
			'Extracted %d node%s into rendition "%s". Save this journey to finalize the base.'
			% [extracted_count, "s" if extracted_count != 1 else "", rend_name]
		),
		false
	)


# ── Merge an overlay node back into the base (extract recovery) ───────────────


# Right-click "Merge into Base" on an overlay node while authoring a rendition: move that node AND its whole
# overlay branch (every rendition node reachable from it) out of the rendition and into the base in one go.
# The node must be a BOUNDARY node — one attached directly to the base — so its branch re-attaches to the
# base through a real anchor edge. Every node keeps its edges intact, so fork default/timeout indices survive
# the move untouched. Confirms, then hands off to _do_merge_to_base.
func _begin_merge_to_base(node_id: String) -> void:
	if not _rendition_mode or _rendition_parent_ids.has(node_id):
		return
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(node_id):
		return
	if _original_journey_folder.strip_edges() == "":
		_show_builder_message(
			"SAVE FIRST",
			"Save this rendition before merging a branch back — the merge rewrites the rendition on disk."
		)
		return
	# The node must be anchored directly to a base node, so its branch has a clean base attachment point.
	if not _has_base_anchor(node_id):
		_show_builder_message(
			"CAN'T MERGE",
			"This node isn't attached directly to the base. Merge from the node that hangs off the base — it brings this whole branch with it."
		)
		return
	var branch: Dictionary = _collect_overlay_subtree(node_id)
	var count: int = branch.size()
	var body: String = (
		"Move this node back into the base?"
		if count <= 1
		else "Move this node and its whole branch (%d nodes) back into the base?" % count
	)
	_show_builder_confirm(
		"MERGE INTO BASE",
		(
			body
			+ "\n\nThe rendition is re-saved without them, then the base opens with the branch re-added for you to Save."
		),
		"⤺ MERGE",
		func() -> void: _do_merge_to_base(node_id)
	)


# True if a base node anchors `node_id` directly (a base node with an `_anchor` edge pointing at it).
func _has_base_anchor(node_id: String) -> bool:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	for bid: String in _rendition_parent_ids:
		if not nodes.has(bid):
			continue
		for e: Variant in (nodes[bid] as Dictionary).get("out", []):
			if (
				e is Dictionary
				and bool((e as Dictionary).get("_anchor", false))
				and str((e as Dictionary).get("to", "")) == node_id
			):
				return true
	return false


# Every overlay node reachable from `root` (root included), stopping at base nodes. Cycle-safe. These are the
# rendition nodes that move to the base together as one branch.
func _collect_overlay_subtree(root: String) -> Dictionary:
	var seen: Dictionary = {}
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var stack: Array = [root]
	while not stack.is_empty():
		var cur: String = str(stack.pop_back())
		if seen.has(cur) or not nodes.has(cur) or _rendition_parent_ids.has(cur):
			continue
		seen[cur] = true
		for e: Variant in (nodes[cur] as Dictionary).get("out", []):
			if e is Dictionary:
				var to: String = str((e as Dictionary).get("to", ""))
				if to != "" and not seen.has(to) and not _rendition_parent_ids.has(to):
					stack.append(to)
	return seen


func _do_merge_to_base(node_id: String) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(node_id):
		return
	# 1) The whole overlay branch moves to the base. Each node keeps ALL its edges as-is — edges to base
	#    nodes and edges to other branch nodes are all valid base edges now, so nothing is stripped and fork
	#    default/timeout indices stay correct.
	var branch: Dictionary = _collect_overlay_subtree(node_id)
	var node_injections: Array = []
	for sid: String in branch:
		node_injections.append({"id": sid, "node": (nodes[sid] as Dictionary).duplicate(true)})

	# 2) Every base→branch anchor becomes a real base edge that reattaches the branch. A slot anchor fills the
	#    base fork's open slot in place; everything else appends.
	var edge_injections: Array = []
	for bid: String in _rendition_parent_ids:
		if not nodes.has(bid):
			continue
		for e: Variant in (nodes[bid] as Dictionary).get("out", []):
			if (
				e is Dictionary
				and bool((e as Dictionary).get("_anchor", false))
				and branch.has(str((e as Dictionary).get("to", "")))
			):
				var be: Dictionary = (e as Dictionary).duplicate(true)
				var slot: int = int(be.get("_slot", -1))
				be.erase("_anchor")
				be.erase("_slot")
				edge_injections.append({"anchor": bid, "edge": be, "slot": slot})

	# 3) Rewrite the rendition on disk WITHOUT the branch — in-place JSON surgery, no re-pool, so the nodes'
	#    media stays in the rendition folder for the base Save to pool from.
	if not _rewrite_rendition_without_subtree(branch):
		_show_builder_message(
			"MERGE FAILED", "Couldn't update the rendition on disk. Nothing was changed."
		)
		return

	# 4) Reload the builder editing the BASE, injecting the branch + its now-real edges (fresh scene, so all
	#    rendition chrome resets cleanly). The author lands on the base, branch re-added, ready to Save.
	edit_journey = _rendition_parent_journey
	merge_inject = {"nodes": node_injections, "edges": edge_injections}
	Transition.change_scene("res://scenes/journey_builder/JourneyBuilder.tscn")


# Injects a merged-back branch into the freshly-loaded base graph (consumed by _ready when merge_inject is
# set): adds every branch node, then reattaches it by writing each base edge onto its source node — a slot
# edge fills the base fork's open slot in place, others append. The nodes' media paths still point at the
# rendition folder, so the base Save pools them across.
func _apply_merge_inject(inj: Dictionary) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	for entry: Variant in inj.get("nodes", []):
		if not (entry is Dictionary):
			continue
		var nid: String = str((entry as Dictionary).get("id", ""))
		if nid == "" or nodes.has(nid):
			continue
		nodes[nid] = ((entry as Dictionary).get("node", {}) as Dictionary).duplicate(true)
	for attach: Variant in inj.get("edges", []):
		if not (attach is Dictionary):
			continue
		var src: String = str((attach as Dictionary).get("anchor", ""))
		if not nodes.has(src):
			continue
		var b: Dictionary = nodes[src]
		if not b.has("out"):
			b["out"] = []
		var out_arr: Array = b["out"]
		var edge: Dictionary = ((attach as Dictionary).get("edge", {}) as Dictionary).duplicate(
			true
		)
		var slot: int = int((attach as Dictionary).get("slot", -1))
		if slot >= 0 and slot < out_arr.size():
			out_arr[slot] = edge  # fill the base fork's open slot in place
		else:
			out_arr.append(edge)
	_show_status("Merged from rendition — Save this journey to finalize.", false)


# Rewrites the rendition's journey.json (at its own folder) without the merged branch — a structural edit
# only, so no media is re-pooled (the nodes' files linger for the base Save). Removes every branch node and
# every anchor that attached one; nothing needs re-anchoring because the whole branch moves together. Never
# deletes the folder even if it empties, so those files survive; an empty rendition can be removed from the
# catalogue. Returns false on read/parse/write failure (caller leaves everything unchanged).
func _rewrite_rendition_without_subtree(branch: Dictionary) -> bool:
	var folder: String = _original_journey_folder  # the rendition's own folder while editing it
	if folder == "":
		return false
	var json_path: String = folder + "/journey.json"
	if not FileAccess.file_exists(json_path):
		return false
	var rf: FileAccess = FileAccess.open(json_path, FileAccess.READ)
	if rf == null:
		return false
	var parser: JSON = JSON.new()
	var ok: int = parser.parse(rf.get_as_text())
	rf.close()
	if ok != OK or not (parser.data is Dictionary):
		return false
	var data: Dictionary = parser.data
	var new_nodes: Array = []
	for n: Variant in data.get("Nodes", []):
		if n is Dictionary and branch.has(str((n as Dictionary).get("id", ""))):
			continue
		new_nodes.append(n)
	data["Nodes"] = new_nodes
	# Drop every anchor that attached a branch node (each becomes a real base edge on the injection side).
	var new_anchors: Array = []
	for a: Variant in data.get("Anchors", []):
		var drop: bool = false
		if a is Dictionary:
			var edge: Dictionary = (a as Dictionary).get("Edge", {})
			drop = branch.has(str(edge.get("to", "")))
		if not drop:
			new_anchors.append(a)
	data["Anchors"] = new_anchors
	var wf: FileAccess = FileAccess.open(json_path, FileAccess.WRITE)
	if wf == null:
		return false
	wf.store_string(JSON.stringify(data, "\t"))
	wf.close()
	return true


# A plain confirm modal (OK / Cancel), built dynamically like the other builder dialogs.
func _show_builder_confirm(title: String, body: String, ok_text: String, on_ok: Callable) -> void:
	var parts: Dictionary = UITheme.build_centered_modal(title, UITheme.CYAN, Vector2i(560, 280))
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	var lbl: Label = Label.new()
	lbl.text = body
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(lbl, UITheme.WHITE_SOFT, 13, false)
	vbox.add_child(lbl)
	var row: HBoxContainer = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)
	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(140, 0)
	UITheme.style_button(cancel_btn, UITheme.PURPLE_MID)
	cancel_btn.pressed.connect(func() -> void: modal.queue_free())
	row.add_child(cancel_btn)
	var ok_btn: Button = Button.new()
	ok_btn.text = ok_text
	ok_btn.custom_minimum_size = Vector2(180, 0)
	UITheme.style_button(ok_btn, UITheme.CYAN)
	ok_btn.pressed.connect(
		func() -> void:
			modal.queue_free()
			on_ok.call()
	)
	row.add_child(ok_btn)
	add_child(modal)


# A manual rendition Save: write the overlay to disk, then finalize (return to the catalogue) like any
# other save. Extraction instead calls _write_rendition_pack directly and STAYS in the builder.
func _save_rendition() -> bool:
	var ok: bool = await _write_rendition_pack()
	if ok:
		_finalize_save_success()
	return ok


# Writes the rendition overlay to disk: pools ONLY the new nodes' media into a fresh rendition folder,
# extracts the anchor edges from the ghosted base nodes, pools their card images, and writes a
# Type:"rendition" journey.json (the delta). The base is never touched — its nodes are skipped in pooling
# and it's never re-written. Mirrors _do_save's staging → write → swap, but assembles a rendition. Does
# NOT navigate away, so both the manual Save and the extract flow can reuse it.
func _write_rendition_pack() -> bool:
	if not _validate_rendition_presave():
		return false
	var paths: Dictionary = _setup_save_folders()  # folder named after the rendition (_journey_name)
	var modal: Control = _create_save_progress_modal_if_needed()
	var pooled: Dictionary = await _pool_graph_nodes(paths, modal, _rendition_parent_ids)  # skip the base
	if not bool(pooled["ok"]):
		if modal:
			modal.queue_free()
		JourneyData.delete_dir_recursive(paths["abs_dir"])
		return false
	# Overlay anchors: extract them off the ghosted base nodes, then pool any fork-choice card image they
	# carry — the base fork is skipped by the pool above, so its overlay edges' images are pooled here.
	var anchors: Array = await _pool_anchor_images(_extract_anchors(), paths, modal)
	if modal:
		modal.queue_free()
	if _save_aborted:
		JourneyData.delete_dir_recursive(paths["abs_dir"])
		return false

	var rendition: Dictionary = {
		"journey_id": _journey_id,  # "" → coerce_rendition mints the overlay's own id
		"name": paths["journey_name"],
		"author": _journey_author.strip_edges(),
		"description": _journey_desc.strip_edges(),
		"parent_id": _rendition_parent_id,
		"parent_min_version": "",
		"nodes": pooled["nodes"],
		"anchors": anchors,
		"slot_fills": _pool_slot_fills(paths["abs_dir"]),  # channel scripts pooled after the nodes above
	}
	var data: Dictionary = JourneyRendition.coerce_rendition(rendition)
	# The rendition's OWN backdrop layers (pooled into its media/) — the base's stay in the base and are
	# NOT re-saved here; compose stacks them at play time.
	data["MapBackdrops"] = _save_map_backdrops(paths["abs_media_dir"], paths["copied_images"])
	_journey_id = str(data.get("JourneyId", ""))  # remember the minted id for a re-save
	if not _write_journey_json(paths, data):
		JourneyData.delete_dir_recursive(paths["abs_dir"])
		return false
	_swap_staging_into_place(paths)
	return true


# The anchors an overlay adds: every `_anchor`-marked out-edge on a ghosted base node, as
# {anchor: <base id>, edge: {to, …}} with the authoring marker stripped.
func _extract_anchors() -> Array:
	var anchors: Array = []
	var nodes: Dictionary = _graph_model.get("nodes", {})
	for id: String in _rendition_parent_ids:
		if not nodes.has(id):
			continue
		for e: Variant in (nodes[id] as Dictionary).get("out", []):
			if not (e is Dictionary and bool((e as Dictionary).get("_anchor", false))):
				continue
			var ed: Dictionary = e
			if ed.has("_slot"):
				# Fork open-slot fill: needs a real target (an unfilled slot isn't a real anchor). Carries
				# only the destination + slot index; the base owns the choice's label/image.
				if str(ed.get("to", "")) == "":
					continue
				anchors.append(
					{"anchor": id, "edge": {"to": str(ed.get("to", ""))}, "slot": int(ed["_slot"])}
				)
			else:
				# Ending-extend or an overlay fork choice: the full edge travels (its name/image_path are
				# the rendition's own; the card image is pooled by _pool_anchor_images before writing). An
				# empty `to` on an overlay fork choice is a valid "ends the run" choice, exactly as in the
				# base editor — kept, not dropped.
				var edge: Dictionary = ed.duplicate(true)
				edge.erase("_anchor")
				anchors.append({"anchor": id, "edge": edge})
	return anchors


# Pools the card image on any overlay fork-choice anchor edge into the rendition's media folder, then
# rewrites that edge's absolute image_path to the pooled rel. The base fork these choices attach to is
# skipped by _pool_graph_nodes, so — unlike a native fork's choices — their images are pooled here.
# Anchors without an image (ending-extends, slot fills) pass through untouched. Sets _save_aborted on a
# copy failure (the caller wipes staging), mirroring the node pooling.
func _pool_anchor_images(anchors: Array, paths: Dictionary, modal: Control) -> Array:
	var abs_dir: String = paths["abs_dir"]
	var abs_media_dir: String = paths["abs_media_dir"]
	var copied_images: Dictionary = paths["copied_images"]
	for ai in anchors.size():
		var edge: Dictionary = (anchors[ai] as Dictionary).get("edge", {})
		if str(edge.get("image_path", "")) == "":
			continue
		var rel: String = await _store_journey_image(
			str(edge["image_path"]),
			abs_dir,
			abs_media_dir,
			"anchor_%d_cover" % ai,
			copied_images,
			JourneyData.ANIM_CAP_FORK,
			modal
		)
		edge["image_path"] = rel
		if _save_aborted:
			break
	return anchors


# Presave for renditions. Requires a name + at least one new node/overlay so an empty rendition can't be
# saved, then INHERITS the base editor's validation (per-node content + structural checks) via
# _collect_rendition_presave_issues — a rendition is a distributable journey, so it's held to the same bar.
func _validate_rendition_presave() -> bool:
	if _journey_name.strip_edges() == "":
		_show_status("Name the rendition in the Journey Info panel before saving.", true)
		return false
	var new_nodes: int = 0
	for id: String in _graph_model.get("nodes", {}):
		if not _rendition_parent_ids.has(id):
			new_nodes += 1
	if new_nodes == 0 and _rendition_slot_fills.is_empty():
		_show_status("Add a new node or a channel overlay before saving.", true)
		return false
	var issues: Array = _collect_rendition_presave_issues()
	if issues.is_empty():
		return true
	_show_save_error_modal(
		"CANNOT SAVE RENDITION",
		(
			"Found %d issue%s in this rendition. Fix the items below and try again."
			% [issues.size(), "s" if issues.size() != 1 else ""]
		),
		issues
	)
	return false


# Inherits the base editor's validation, but SCOPED to the overlay. Per-node content checks run on the
# rendition's OWN nodes only — the base's media was validated when the base was saved, and re-checking it
# here is both wrong (they're the base author's files) and fragile: a channel-only overlay adds no nodes,
# so re-checking the base would block it for a base clip that isn't the rendition's problem. Structural
# checks run on the whole composed graph, but since the base is a valid DAG, only overlay-introduced
# problems (unreachable overlay node, dangling/cyclic overlay edge) can surface; no_start is inherited.
func _collect_rendition_presave_issues() -> Array:
	var issues: Array = []
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var ordinals: Dictionary = JourneyGraph.type_ordinals(nodes)
	for id: String in nodes:
		if _rendition_parent_ids.has(id):
			continue  # ghosted base node — already validated at base save
		var n: Dictionary = nodes[id]
		var data: Dictionary = n.get("data", {})
		var ordinal: int = int(ordinals.get(id, 0))
		match str(n.get("type", "")):
			"round":
				_save_check_round(data, "Round %d" % ordinal, issues)
				_save_check_encounter(data, "Round %d" % ordinal, issues)
			"storyboard":
				_save_check_storyboard(data, "Storyboard %d" % ordinal, issues)
			"fork":
				_save_check_fork_graph(n, "Fork %d" % ordinal, issues)
	for gi: Dictionary in JourneyGraph.validate_graph(_graph_model, _journey_finish_node):
		if str(gi.get("kind", "")) == "no_start":
			continue  # the rendition inherits the base's start through its anchors
		var m: Dictionary = _structural_issue_to_presave(gi)
		if not m.is_empty():
			issues.append(m)
	return issues


# ── Channel overlays (slot-fills on base rounds) ─────────────────────────────


# Routes a batch of dropped funscripts onto a ghosted base ROUND's EMPTY channels (the inline replacement
# for the old CHANNEL OVERLAYS modal — called from the channel-overlay side-panel editor). Each script's
# axis/vibe is inferred from its filename suffix; an empty slot gets a slot_fill; a slot the base or the
# rendition already fills is skipped. Refreshes the editor and reports what landed.
func _route_channel_scripts(round_id: String, paths: PackedStringArray) -> void:
	var added: Array = []
	var skipped: int = 0
	for path: String in paths:
		var field: String
		var channel: String
		var vib: String = ImportScanner.detect_vib_channel(path)
		if vib != "":
			field = "vib_scripts"
			channel = vib
		else:
			var axis: String = ImportScanner.detect_funscript_axis(path)
			if axis == "L0":  # main stroke — the base owns it; not an overlay channel
				skipped += 1
				continue
			field = "axis_scripts"
			channel = axis
		if _channel_slot_occupied(round_id, field, channel):
			skipped += 1
			continue
		_rendition_slot_fills.append(
			{"node": round_id, "field": field, "channel": channel, "path": path}
		)
		added.append(channel)
	_side_renderer.show_graph_node_editor(round_id)
	if added.is_empty() and skipped == 0:
		_show_status(
			"No axis/vibe scripts recognised — check filename suffixes (_L1, _R1, _vib1…).", true
		)
	elif added.is_empty():
		_show_status("Nothing added — those channels are already filled (base or overlay).", true)
	else:
		var msg: String = (
			"Overlaid %d channel%s: %s"
			% [added.size(), "s" if added.size() != 1 else "", ", ".join(added)]
		)
		if skipped > 0:
			msg += "  ·  %d skipped" % skipped
		_show_status(msg, false)


# True when a base round's channel slot can't take an overlay — the base already fills it, or the rendition
# already slot-filled it this session.
func _channel_slot_occupied(round_id: String, field: String, channel: String) -> bool:
	var data: Dictionary = (_graph_model.get("nodes", {}).get(round_id, {}) as Dictionary).get(
		"data", {}
	)
	if (data.get(field, {}) as Dictionary).has(channel):
		return true
	return _find_slot_fill(round_id, field, channel) >= 0


# Removes a channel overlay (slot-fill) from a base round and refreshes its editor.
func _remove_slot_fill(round_id: String, field: String, channel: String) -> void:
	var idx: int = _find_slot_fill(round_id, field, channel)
	if idx >= 0:
		_rendition_slot_fills.remove_at(idx)
		_side_renderer.show_graph_node_editor(round_id)


# Removes ALL channel overlays this rendition added to `round_id` (the "wrong scripts" bulk escape hatch).
func _clear_round_slot_fills(round_id: String) -> void:
	var kept: Array = []
	for sf: Dictionary in _rendition_slot_fills:
		if str(sf.get("node", "")) != round_id:
			kept.append(sf)
	_rendition_slot_fills = kept
	_side_renderer.show_graph_node_editor(round_id)
	_show_status("Cleared this round's channel overlays.", false)


func _find_slot_fill(round_id: String, field: String, channel: String) -> int:
	for i: int in _rendition_slot_fills.size():
		var sf: Dictionary = _rendition_slot_fills[i]
		if (
			str(sf.get("node", "")) == round_id
			and str(sf.get("field", "")) == field
			and str(sf.get("channel", "")) == channel
		):
			return i
	return -1


# Precise single-channel attach (the ＋ on a channel row): a file picker whose result fills that exact
# channel regardless of the file's name. Refreshes the round's channel-overlay editor.
func _pick_slot_fill_script(round_id: String, field: String, channel: String) -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.title = "Attach %s Script" % channel
	dialog.add_filter("*.funscript", "Funscript")
	SettingsService.remember_browse_dir(dialog)
	dialog.file_selected.connect(
		func(path: String) -> void:
			dialog.queue_free()
			if not _channel_slot_occupied(round_id, field, channel):
				_rendition_slot_fills.append(
					{"node": round_id, "field": field, "channel": channel, "path": path}
				)
			_side_renderer.show_graph_node_editor(round_id)
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


# Pools each channel-overlay script into the rendition's content/ (deduped against the nodes already
# pooled this save) and returns the slot_fills with pooled rel paths for the delta. Call AFTER
# _pool_graph_nodes so the pool map is live.
func _pool_slot_fills(abs_dir: String) -> Array:
	var out: Array = []
	for sf: Dictionary in _rendition_slot_fills:
		var src: String = str(sf.get("path", ""))
		if src == "":
			continue
		var rel: String = str(_pool_funscript(src, abs_dir).get("rel", ""))
		if rel == "":
			continue
		(
			out
			. append(
				{
					"node": str(sf.get("node", "")),
					"field": str(sf.get("field", "")),
					"channel": str(sf.get("channel", "")),
					"path": rel,
				}
			)
		)
	return out


# Clears all in-flight save state so a previous failed save can't bleed into
# this one (stale _save_aborted flag, leftover error stash, round counter
# from a partial walk).
func _reset_save_state() -> void:
	_status_lbl.visible = false
	_transcode_cancel = false
	_save_aborted = false
	_save_abort_error = {}
	_anim_truncated.clear()
	_round_folder_counter = 0
	_invalidated_save_count = 0
	_pending_test_location = {}


# Runs the whole-tree presave validation pass. Returns false (and shows the
# multi-issue modal) when any problems exist.
func _validate_presave() -> bool:
	var issues: Array = _collect_presave_issues()
	if issues.is_empty():
		return true
	var headline: String = (
		"Found %d issue%s that prevent saving. Fix the items below and try again."
		% [
			issues.size(),
			"s" if issues.size() != 1 else "",
		]
	)
	_show_save_error_modal("CANNOT SAVE JOURNEY", headline, issues)
	return false


# The _transcode_plan key for a (source, segments) combo. An uncut source keeps the bare
# source path (legacy shape); a segment list gets its own entry so the same source can be
# cut differently — or not at all — by different rounds. Shares JourneyData's identity
# spelling so the key and the pooled fingerprint always agree on what "the same cut" means.
func _transcode_plan_key(src: String, segments: Array) -> String:
	var id: String = JourneyData.segments_identity(segments)
	return src if id == "" else "%s|%s" % [src, id]


# Populates _transcode_plan by probing every (video source, pending trim) combo
# in the graph. A combo is planned for encoding when its codec isn't H.264, its
# pixel format is undecodable (10-bit, 4:2:2, …) — or it carries a TRIM, which
# always re-encodes for a frame-accurate cut (a keyframe-snapped copy could land
# seconds off and silently desync the rebased funscript). Trims are baked even
# with auto-transcode OFF, so ffmpeg is required whenever any trim is pending.
# Returns false — with an actionable modal — when ffmpeg is needed but can't run.
# Blocks the save when the journey uses animated images but ffmpeg can't run.
#
# Deliberately separate from _build_transcode_plan's gate, which can't cover this: that one returns
# early when the journey has no video at all (a storyboard-only journey can still use a GIF), and
# again when Auto-Transcode is off. Baking a GIF is NOT optional the way transcoding a video is —
# Godot has no GIF decoder, so an unbaked GIF is simply an invisible image. There's no soft
# fallback either: extracting even its first frame needs ffmpeg.
func _check_animated_images() -> bool:
	var sources: Array = JourneyData.graph_animated_image_sources(
		_graph_model, MediaPoolService.ANIMATED_EXTENSIONS
	)
	if _cover_path != "" and MediaPoolService.is_animated_source(_cover_path):
		sources.append(_cover_path)
	# Character portraits are journey-level (not in the graph), so scan them here too — an animated
	# portrait needs the same bake as any other animated image.
	for c: Variant in _journey_characters:
		if c is Dictionary:
			for por: Variant in (c as Dictionary).get("portraits", []):
				var p: String = str((por as Dictionary).get("path", ""))
				if p != "" and MediaPoolService.is_animated_source(p):
					sources.append(p)
	if sources.is_empty() or MediaPoolService.is_available():
		return true

	var names: PackedStringArray = []
	for s: String in sources:
		names.append((s as String).get_file())
	_show_save_error_single(
		"CANNOT SAVE JOURNEY",
		CAUSE_FFMPEG_MISSING,
		"Journey",
		(
			"This journey uses animated images (%s), but ffmpeg / ffprobe could not be run. Animated images must be converted before the game can show them — unlike video transcoding, this can't be skipped."
			% ", ".join(names)
		),
		"Set a custom ffmpeg location in Options → Transcoding (a folder containing ffmpeg and ffprobe), or install ffmpeg on your PATH. Alternatively, replace the animated images with still ones (PNG / JPG / WebP)."
	)
	return false


func _build_transcode_plan() -> bool:
	_transcode_plan = {}
	if not JourneyData.graph_has_any_video(_graph_model):
		return true

	# Every round's (source, segments) combo; identical combos plan (and pool) once.
	var combos: Dictionary = {}  # plan key → {src, segments}
	var any_cut: bool = false
	for nid: String in _graph_model.get("nodes", {}):
		var node: Dictionary = _graph_model["nodes"][nid]
		if str(node.get("type", "")) != "round":
			continue
		var data: Dictionary = node.get("data", {})
		var src: String = str(data.get("video_path", ""))
		if src != "":
			# A multi-segment round bakes outside this plan (see _pool_video_into) because it
			# always re-encodes; it still needs to flip any_cut so the ffmpeg gate below fires
			# even with Auto-Transcode off. A single segment is a plain trim and plans normally.
			var segs: Array = JourneyData.normalize_segments(data)
			any_cut = any_cut or not segs.is_empty()
			if segs.size() <= 1:
				combos[_transcode_plan_key(src, segs)] = {"src": src, "segments": segs}
		# Pool round: each encounter entry's video is its own source (never cut).
		for pe: Variant in data.get("pool_entries", []):
			var pv: String = str((pe as Dictionary).get("video_path", ""))
			if pv != "":
				combos[_transcode_plan_key(pv, [])] = {"src": pv, "segments": []}

	# Auto-transcode disabled: copy videos verbatim and require nothing of
	# ffmpeg (the escape hatch for setups where ffmpeg can't run, e.g. some
	# Wine) — UNLESS a cut is pending, which can only ship as a re-encode.
	if not SettingsService.get_auto_transcode() and not any_cut:
		return true

	# Honest fallback: without ffprobe/ffmpeg we can neither verify, convert,
	# nor cut videos. Stop with guidance rather than silently copy and hope.
	if not MediaPoolService.is_available():
		_show_save_error_single(
			"CANNOT SAVE JOURNEY",
			CAUSE_FFMPEG_MISSING,
			"Journey",
			"ffmpeg / ffprobe could not be run, so videos can't be verified, converted, or trimmed.",
			"Set a custom ffmpeg location in Options → Transcoding (a folder containing ffmpeg and ffprobe), or install ffmpeg on your PATH. If your videos are already H.264 and untrimmed, you can instead turn off Auto-Transcode in Options → Transcoding to use them as-is. (Under Wine, the bundled Windows ffmpeg may not launch — a system ffmpeg path usually fixes this.)"
		)
		return false

	var auto_transcode: bool = SettingsService.get_auto_transcode()
	var src_info: Dictionary = {}  # src → {codec, pix_fmt}; probed once per source
	var src_duration: Dictionary = {}  # src → full duration (s); probed once
	for key: String in combos:
		var combo: Dictionary = combos[key]
		var src: String = str(combo["src"])
		var segs: Array = combo["segments"]
		var is_trim: bool = not segs.is_empty()
		if not auto_transcode and not is_trim:
			continue  # transcode off: only pending cuts are baked

		if not src_info.has(src):
			src_info[src] = MediaPoolService.probe_stream_info(src)
		var info: Dictionary = src_info[src]
		var reason: String = MediaPoolService.classify_transcode(
			str(info["codec"]), str(info["pix_fmt"]), is_trim
		)
		if reason == "":
			continue

		if not src_duration.has(src):
			src_duration[src] = MediaPoolService.probe_duration_seconds(src)
		var duration: float = float(src_duration[src])
		if is_trim:
			# Progress-bar duration = the baked length (only single-segment combos reach here;
			# multi-segment rounds bake through _pool_video_into with their own progress).
			duration = JourneyData.segments_total_ms(segs, roundi(duration * 1000.0)) / 1000.0
		_transcode_plan[key] = {"codec": reason, "duration": duration, "segments": segs}

	return true


# Computes both staging and final folder paths, creates the staging tree
# (wiping any leftover from a previous interrupted save), and pre-copies the
# cover image so the loop has its dedup entry primed.
#
# Returns a Dictionary holding everything downstream phases need:
#   {
#     journey_name:        String  - sanitized + edge-stripped journey name
#     staging_journey_dir: String  - user://... path for journey.json writes
#     abs_dir:             String  - OS-absolute staging root (for file ops)
#     abs_media_dir:       String  - OS-absolute media/ subfolder
#     final_abs_dir:       String  - OS-absolute final target for the swap
#     copied_images:       Dict    - dedup map shared with _save_all_items
#   }
func _setup_save_folders() -> Dictionary:
	var journey_name: String = _journey_name.strip_edges()
	var journeys_root: String = SettingsService.get_journeys_dir()
	var folder_name: String = JourneyData.sanitize_folder_name(journey_name)
	var final_journey_dir: String = journeys_root + "/" + folder_name
	var final_abs_dir: String = ProjectSettings.globalize_path(final_journey_dir)

	# Stage to a sibling temp folder so a mid-save failure or user cancel can
	# roll back cleanly — the existing journey on disk is never touched until
	# the swap at the end. The dot prefix makes JourneyScanner skip leftover
	# staging folders if the app crashes before the swap.
	var staging_journey_dir: String = journeys_root + "/.~save_" + folder_name
	var abs_dir: String = ProjectSettings.globalize_path(staging_journey_dir)
	if DirAccess.dir_exists_absolute(abs_dir):
		JourneyData.delete_dir_recursive(abs_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)

	# All images (cover + storyboard backgrounds + line images + fork path
	# illustrations) live in media/ so the journey root only holds journey.json
	# and per-round subdirectories.
	var abs_media_dir: String = abs_dir + "/media"
	DirAccess.make_dir_recursive_absolute(abs_media_dir)

	# Pooled per-round playback content (video/funscript/axis/vib/boss image),
	# hashed and deduped, lives here — separate from media/ (journey images).
	DirAccess.make_dir_recursive_absolute(abs_dir + "/content")

	# Dedup map: source_path → dest_filename (relative to abs_media_dir).
	# Primed with the cover image when present so the same image dropped into
	# the cover slot AND a storyboard wouldn't get copied twice.
	var copied_images: Dictionary = {}
	if _cover_path != "":
		if MediaPoolService.is_animated_source(_cover_path):
			# The cover deliberately never animates — it sits in the catalogue grid, where N moving
			# cards would cost real frames for no gain. But Godot can't read a GIF at all, so bake
			# its first frame to a PNG. Unlike the in-game surfaces this does NOT go to the content
			# pool: it has to land in media/ named "cover.*", which is where
			# JourneyScanner.find_cover_image looks for it.
			MediaPoolService.extract_first_frame(
				_cover_path,
				abs_media_dir + "/cover.png",
				JourneyData.ANIM_CAP_COVER.x,
				JourneyData.ANIM_CAP_COVER.y
			)
		else:
			var ext: String = _cover_path.get_extension().to_lower()
			_copy_image_deduped(_cover_path, abs_media_dir, "cover." + ext, copied_images)

	return {
		"journey_name": journey_name,
		"staging_journey_dir": staging_journey_dir,
		"abs_dir": abs_dir,
		"abs_media_dir": abs_media_dir,
		"final_abs_dir": final_abs_dir,
		"copied_images": copied_images,
	}


# Creates and parents the streaming progress modal IF the save will actually
# transfer video bytes. Returns null when there are no videos to save (no
# point in flashing a modal that immediately dismisses).
func _create_save_progress_modal_if_needed() -> Control:
	# Animated images are encodes too, and a journey can have them with no video at all (a
	# storyboard-only journey) — without this it would bake with no modal and look frozen.
	var has_anim: bool = not (
		JourneyData
		. graph_animated_image_sources(_graph_model, MediaPoolService.ANIMATED_EXTENSIONS)
		. is_empty()
	)
	if not JourneyData.graph_has_any_video(_graph_model) and not has_anim:
		return null
	var modal: Control = _create_transcode_modal()
	add_child(modal)
	return modal


# Copies this journey's OWN backdrop layers into media/map_<n>.<ext> (static images, deduped) and returns
# their on-disk meta [{Image, X, Y, Scale, Opacity}]. Base context layers (_base_backdrops) are NOT saved —
# they live in the base journey. Used by both the base save and the rendition delta save.
func _save_map_backdrops(abs_media_dir: String, copied_images: Dictionary) -> Array:
	var meta: Array = []
	for i: int in _map_backdrops.size():
		var b: Dictionary = _map_backdrops[i]
		var src: String = str(b.get("path", ""))
		if src == "" or MediaPoolService.is_animated_source(src):
			continue
		var ext: String = src.get_extension().to_lower()
		var fname: String = "map_%d.%s" % [i + 1, ext]
		_copy_image_deduped(src, abs_media_dir, fname, copied_images)
		var off: Vector2 = b.get("offset", Vector2.ZERO)
		(
			meta
			. append(
				{
					"Image": fname,
					"X": off.x,
					"Y": off.y,
					"Scale": float(b.get("scale", 1.0)),
					"Opacity": float(b.get("opacity", 0.6)),
					"Rot": float(b.get("rotation", 0.0)),
				}
			)
		)
	return meta


# Graph-editor save: walks _graph_model into the Format-2 journey.json shape
# ({…meta…, Format, Start, Nodes:[{id,type,data,pos,out}]}) node-by-node — REUSING the shared
# media copy/pool/transcode primitives, emitting lowercase node.data + out-edges. Returns the
# journey.json dict, or {} on cancel/I-O failure (the error modal + staging cleanup happen in
# _do_save).
func _save_graph_nodes(paths: Dictionary, modal: Control) -> Dictionary:
	var abs_dir: String = paths["abs_dir"]
	var abs_media_dir: String = paths["abs_media_dir"]
	var copied_images: Dictionary = paths["copied_images"]

	var pooled: Dictionary = await _pool_graph_nodes(paths, modal)
	if not bool(pooled["ok"]):
		return {}
	var out_nodes: Dictionary = pooled["nodes"]

	# Assemble the Format-2 node block (Format/Start/Nodes) + journey meta around it.
	# Redirects are intentionally gone — in a free-form graph, skip/converge/end are just
	# edges (GRAPH_EDITOR_OVERHAUL.md §7).
	var node_block: Dictionary = JourneyGraph.to_json(
		{"start": _graph_model.get("start", ""), "nodes": out_nodes}
	)

	# Pool custom-item icons into content/ (small stills, hash-deduped) so the saved Items block
	# carries a relative pooled path rather than the author's absolute source path.
	var items_for_save: Array = []
	for it: Dictionary in _journey_items:
		var saved_item: Dictionary = (it as Dictionary).duplicate(true)
		var img_src: String = str(saved_item.get("image", ""))
		if img_src != "":
			saved_item["image"] = _pool_small_file(img_src, abs_dir)
		if str(saved_item.get("category", "")) == "override":
			saved_item["scripts"] = _pool_override_scripts(saved_item.get("scripts", {}), abs_dir)
		items_for_save.append(saved_item)

	# Store each cast portrait through the same image path as boss/storyboard art — a still is deduped
	# into media/, an animated source (gif/apng/mp4/…) is baked to looping H.264 in content/ and played
	# by JourneyImage at runtime. Keyed by character id + portrait id so nothing collides. A character's
	# placements are pure fraction boxes, so they persist verbatim (no media).
	var characters_for_save: Array = []
	for c: Dictionary in _journey_characters:
		var saved_char: Dictionary = (c as Dictionary).duplicate(true)
		var portraits_out: Array = []
		for por: Variant in saved_char.get("portraits", []):
			var por_copy: Dictionary = (por as Dictionary).duplicate(true)
			var src: String = str(por_copy.get("path", ""))
			if src != "":
				por_copy["path"] = await _store_journey_image(
					src,
					abs_dir,
					abs_media_dir,
					"char_%s_%s" % [str(saved_char.get("id", "x")), str(por_copy.get("id", "p"))],
					copied_images,
					JourneyData.ANIM_CAP_PORTRAIT,
					modal
				)
			portraits_out.append(por_copy)
		saved_char["portraits"] = portraits_out
		characters_for_save.append(saved_char)

	var result: Dictionary = {
		"Name": paths["journey_name"],
		"Author": _journey_author.strip_edges(),
		"Description": _journey_desc.strip_edges(),
		"Difficulty": JourneyData.DIFFICULTIES[_journey_difficulty_idx],
		"Tags": TagRegistry.sanitize(_journey_tags),
		"MapEnabled": _journey_map_enabled,
		"ShowForkCounts": _journey_show_fork_counts,
		"ShowLoopsOnMap": _journey_show_loops_on_map,
		"MapBackdrops": _save_map_backdrops(abs_media_dir, copied_images),
		"MapFog": _journey_map_fog,
		"MapFogReveal": _journey_map_fog_reveal,
		"MysteryPreview": _journey_mystery_preview,
		"AutoAdvanceEnabled": _journey_auto_advance_enabled,
		"AutoAdvanceStoryboardSecs": _journey_auto_advance_storyboard_secs,
		"AutoAdvanceForkSecs": _journey_auto_advance_fork_secs,
		"ShownCounters": JourneyData.clean_flag_list(_journey_shown_counters),
		"AllowFinish": _journey_allow_finish,
		"FinishNode": _journey_finish_node,
		"Items": JourneyData.coerce_journey_items(items_for_save),
		"Characters": JourneyData.coerce_journey_characters(characters_for_save),
	}
	# Identity + version stamps. _journey_id is empty for a new journey (minted here) and carries
	# the loaded id for an existing one, so re-saving — or renaming — never changes it.
	JourneyData.stamp_journey_identity(result, _journey_id)
	_journey_id = str(result["JourneyId"])
	result.merge(node_block)  # adds Format, Start, Nodes
	result["Comments"] = _serialize_comments(_graph_model.get("comments", []))
	result["Groups"] = _serialize_groups(_graph_model.get("groups", []))
	# Expected single-playthrough runtime — the balance audit's Monte-Carlo resolves loops (repeat counts),
	# forks (path selection) and pools (weighted pick) into one number, so the journey previewer can show
	# "how long it'll take" without re-auditing on the select screen. 0 (→ scanner falls back to the sum)
	# for an empty/unauditable graph.
	var audit: Dictionary = _run_audit()
	var audit_dur: Dictionary = (audit.get("stats", {}) as Dictionary).get("duration_ms", {})
	result["EstimatedDurationMs"] = int(audit_dur.get("avg", 0))
	return result


# Pools every non-skipped node's media into the staging content/media dirs, returning
# {"ok": bool, "nodes": {id:{type,data,out,pos?}}}. Shared by the journey save and the rendition save
# (which passes the ghosted base node ids as skip_ids). ok=false ⇒ a transcode/copy failed and the error
# modal was already shown.
func _pool_graph_nodes(paths: Dictionary, modal: Control, skip_ids: Dictionary = {}) -> Dictionary:
	var abs_dir: String = paths["abs_dir"]
	var abs_media_dir: String = paths["abs_media_dir"]
	var copied_images: Dictionary = paths["copied_images"]

	# Fresh content pool for this save (staging is rebuilt from scratch — no cross-save state).
	_pooled_media = {}
	_pooled_fs_stats = {}

	var nodes_in: Dictionary = _graph_model.get("nodes", {})
	var out_nodes: Dictionary = {}

	# Round count drives the transcode modal's "Round x / N" label.
	var total_rounds: int = 0
	for id: String in nodes_in:
		if not skip_ids.has(id) and str((nodes_in[id] as Dictionary).get("type", "")) == "round":
			total_rounds += 1
	var round_seen: int = 0

	for id: String in nodes_in:
		if skip_ids.has(id):
			continue
		if _save_aborted:
			break
		var node: Dictionary = nodes_in[id]
		var node_type: String = str(node.get("type", "round"))
		var data_in: Dictionary = node.get("data", {})
		var saved_data: Dictionary = JourneyData.coerce_node_save_data(node_type, data_in)
		var saved_out: Array = _clean_regular_out(node.get("out", []))

		match node_type:
			"round":
				round_seen += 1
				saved_data = await _save_round_node_media(
					saved_data, data_in, abs_dir, modal, round_seen, total_rounds
				)
				if saved_data.is_empty():
					return {"ok": false, "nodes": {}}  # transcode/copy failure: modal already shown
			"storyboard":
				saved_data = await _save_storyboard_node_media(
					saved_data, data_in, abs_dir, abs_media_dir, id, copied_images, modal
				)
			"fork":
				saved_out = await _save_fork_node_edges(
					node.get("out", []), abs_dir, abs_media_dir, id, copied_images, modal
				)
				# Optional fork audio accent — pooled like the storyboard's, replacing the author's
				# absolute source path (carried in by coerce's data.duplicate) with the pooled rel.
				var fork_audio: String = _pool_small_file(str(data_in.get("audio", "")), abs_dir)
				if fork_audio != "":
					saved_data["audio"] = fork_audio
					saved_data["audio_loop"] = bool(data_in.get("audio_loop", false))
					saved_data["audio_volume"] = clampf(
						float(data_in.get("audio_volume", 1.0)), 0.0, 1.0
					)
				else:
					saved_data.erase("audio")
					saved_data.erase("audio_loop")
					saved_data.erase("audio_volume")
			"shop", "checkpoint":
				pass  # no media

		# A non-video copy (funscript / axis / vib / boss / image) failed somewhere above.
		if _save_aborted:
			var sr: Dictionary = _save_abort_error.get(
				"result", {"reason": CAUSE_UNKNOWN_COPY_ERROR}
			)
			var si: String = _save_abort_error.get("item", "File copy")
			_show_copy_failure_modal(sr, si)
			return {"ok": false, "nodes": {}}

		var saved_node: Dictionary = {"type": node_type, "data": saved_data, "out": saved_out}
		if node.has("pos"):
			saved_node["pos"] = node["pos"]
		out_nodes[id] = saved_node

	return {"ok": true, "nodes": out_nodes}


# Serializes the editor's sticky-note comments to the journey.json `Comments` overlay (runtime ignores it).
func _serialize_comments(comments: Array) -> Array:
	var out: Array = []
	for c: Dictionary in comments:
		var p: Vector2 = c.get("pos", Vector2.ZERO)
		var entry: Dictionary = {"Pos": [p.x, p.y], "Text": str(c.get("text", ""))}
		if c.has("color"):
			entry["Color"] = (c["color"] as Color).to_html()
		if str(c.get("node_id", "")) != "":
			entry["NodeId"] = str(c["node_id"])  # pinned note — follows this node in the builder
		out.append(entry)
	return out


# Serializes the editor's group frames to the journey.json `Groups` overlay (runtime ignores it).
func _serialize_groups(groups: Array) -> Array:
	var out: Array = []
	for g: Dictionary in groups:
		var r: Rect2 = g.get("rect", Rect2())
		var entry: Dictionary = {
			"Pos": [r.position.x, r.position.y],
			"Size": [r.size.x, r.size.y],
			"Label": str(g.get("label", ""))
		}
		if g.has("color"):
			entry["Color"] = (g["color"] as Color).to_html()
		if g.get("collapsed", false):
			entry["Collapsed"] = true
			entry["Members"] = (g.get("members", []) as Array).duplicate()
			entry["ShiftIds"] = (g.get("shift_ids", []) as Array).duplicate()
			entry["Shift"] = float(g.get("shift_amt", 0.0))
			entry["FrameShiftIdxs"] = (g.get("frame_shift_idxs", []) as Array).duplicate()
			entry["FrameShift"] = float(g.get("frame_shift_amt", 0.0))
		out.append(entry)
	return out


# Pools a round node's playback media (funscript / axis / vib / boss image / video) into
# content/, rewriting saved_data's media fields to journey-root-relative pooled paths and
# refreshing the funscript stats. Reads SOURCE paths from data_in (absolute). Returns the
# updated saved_data, or {} when a video transcode/copy fails (error modal already shown).
# A small-file copy failure sets _save_aborted instead (surfaced by the caller's checkpoint).
func _save_round_node_media(
	saved_data: Dictionary,
	data_in: Dictionary,
	abs_dir: String,
	modal: Control,
	rorder: int,
	total: int
) -> Dictionary:
	var round_name: String = str(saved_data.get("name", "")).strip_edges()
	# FolderName slug — a stable logical round id + the legacy folder-scan fallback key.
	# No per-round folder is created; all playback assets pool into content/ by hash.
	saved_data["folder"] = _next_round_folder_slug()

	# Pending segments, consumed by this save: the video is cut to them and every script rebased
	# to match. Empty for an uncut round (the common case). normalize_segments migrates the
	# legacy trim / section-loop fields, so an older round bakes identically.
	var segments: Array = JourneyData.normalize_segments(data_in)

	# The round's OWN media (funscript / axis / vib / boss image / video). All empty
	# for a pool round — its media lives in the entries, pooled below.
	var fs: Dictionary = _pool_funscript(str(data_in.get("funscript_path", "")), abs_dir, segments)
	saved_data["funscript_path"] = fs["rel"]
	saved_data["action_count"] = fs["count"]
	saved_data["length_ms"] = fs["length_ms"]

	# Secondary-axis + vib scripts — pooled, keyed by channel (suffix preserved), cut
	# identically to the main funscript.
	saved_data["axis_scripts"] = _pool_channels(
		data_in.get("axis_scripts", {}), abs_dir, JourneyData.AXIS_SUFFIXES, segments
	)
	saved_data["vib_scripts"] = _pool_channels(
		data_in.get("vib_scripts", {}), abs_dir, JourneyData.VIB_SUFFIXES, segments
	)

	# restim (E-Stim Full) parameter scripts — pooled, keyed by restim axis; trimmed identically.
	saved_data["estim_scripts"] = _pool_channels(
		data_in.get("estim_scripts", {}), abs_dir, JourneyData.ESTIM_SUFFIXES, segments
	)

	# Boss intro image (boss rounds only) → content pool. A GIF is baked to a looping H.264 (or a
	# PNG if it's single-frame) — Godot can't decode GIF, so it can never ship verbatim.
	var boss_rel: String = ""
	if str(saved_data.get("round_type", "normal")) == "boss":
		var boss_src: String = str(data_in.get("boss_image", ""))
		var gif: Dictionary = await _store_gif_source(
			boss_src, abs_dir, JourneyData.ANIM_CAP_BOSS, false, modal
		)
		boss_rel = str(gif["rel"]) if gif["handled"] else _pool_small_file(boss_src, abs_dir)
	saved_data["boss_image"] = boss_rel

	# Boss timeline (the authored encounter): its attack funscripts, cast art and audio cues are the
	# author's own files, so they pool into content/ like every other round asset and the saved
	# timeline carries rels — which is what lets an encounter travel in the .fhj.
	if saved_data.has("timeline"):
		saved_data["timeline"] = await _pool_timeline_media(
			saved_data["timeline"] as Dictionary, abs_dir, modal
		)

	# Video → content pool. Legacy fallback: a pre-VideoPath round carries its video
	# only on disk; a re-save must never drop it (the swap deletes the old folder).
	var vid_src: String = str(data_in.get("video_path", ""))
	if vid_src == "":
		vid_src = JourneyData.find_video_in_round(str(data_in.get("folder", "")))
	var vres: Dictionary = await _pool_video_into(
		vid_src, abs_dir, modal, round_name, 'Round "%s"' % round_name, rorder, total, segments
	)
	if not vres["ok"]:
		return {}
	saved_data["video_path"] = vres["rel"]

	# Pool round: pool each encounter entry's media (video + funscript + axis/vib),
	# rewriting each entry's paths to content/ rels. Entries are never cut.
	if str(saved_data.get("round_type", "normal")) == "pool":
		var entries_out: Array = []
		for pe: Variant in data_in.get("pool_entries", []):
			var entry_in: Dictionary = pe
			var ename: String = str(entry_in.get("name", "")).strip_edges()
			var e_fs: Dictionary = _pool_funscript(str(entry_in.get("funscript_path", "")), abs_dir)
			var e_vid: Dictionary = await _pool_video_into(
				str(entry_in.get("video_path", "")),
				abs_dir,
				modal,
				ename,
				'Encounter "%s"' % ename,
				rorder,
				total
			)
			if not e_vid["ok"]:
				return {}
			var entry_out: Dictionary = {
				"name": ename,
				"video_path": e_vid["rel"],
				"funscript_path": e_fs["rel"],
				"action_count": e_fs["count"],
				"length_ms": e_fs["length_ms"],
				"axis_scripts":
				_pool_channels(
					entry_in.get("axis_scripts", {}), abs_dir, JourneyData.AXIS_SUFFIXES
				),
				"vib_scripts":
				_pool_channels(entry_in.get("vib_scripts", {}), abs_dir, JourneyData.VIB_SUFFIXES),
				"weight": maxi(1, int(entry_in.get("weight", 1))),
				# Per-entry type (a rolled encounter can be a boss). Boss config rides along;
				# its intro image is pooled like a boss round's.
				"round_type": str(entry_in.get("round_type", "normal")),
			}
			if str(entry_out["round_type"]) == "boss":
				entry_out["boss_modifiers"] = (
					(entry_in.get("boss_modifiers", []) as Array).duplicate(true)
				)
				entry_out["boss_tagline"] = str(entry_in.get("boss_tagline", ""))
				# Same GIF-bake rule as a round-level boss image (Godot can't show a GIF).
				var e_boss_src: String = str(entry_in.get("boss_image", ""))
				var e_gif: Dictionary = await _store_gif_source(
					e_boss_src, abs_dir, JourneyData.ANIM_CAP_BOSS, false, modal
				)
				entry_out["boss_image"] = (
					str(e_gif["rel"]) if e_gif["handled"] else _pool_small_file(e_boss_src, abs_dir)
				)
				entry_out["sensory"] = (entry_in.get("sensory", []) as Array).duplicate(true)
			entries_out.append(entry_out)
		saved_data["pool_entries"] = entries_out

	return saved_data


# Pools a funscript source into content/ (rebased to the round's segments when it has any),
# caching stats by fingerprint so a reused source is parsed once. Returns {rel, count,
# length_ms}; empty source → empty rel + zero stats.
func _pool_funscript(fs_src: String, abs_dir: String, segments: Array = []) -> Dictionary:
	if fs_src == "":
		return {"rel": "", "count": 0, "length_ms": 0}
	var pool: Dictionary = _assign_pooled_media(fs_src, fs_src.get_extension(), segments)
	var rel: String = pool["rel"]
	var stats: Dictionary = {"count": 0, "length_ms": 0}
	if pool["copy"]:
		var dst: String = abs_dir + "/" + rel
		if segments.is_empty():
			_copy_file(fs_src, dst)
		else:
			_write_edl_funscript(fs_src, dst, segments)
		stats = JourneyData.read_funscript_stats(dst)
		_pooled_fs_stats[pool["fingerprint"]] = stats
	else:
		stats = _pooled_fs_stats.get(pool["fingerprint"], stats)
	return {"rel": rel, "count": stats["count"], "length_ms": stats["length_ms"]}


# Pools a {channel: source} map (secondary-axis or vib scripts) into content/, keyed
# by channel with the suffix preserved. Returns {channel: rel} (skips empty sources).
func _pool_channels(
	channels_in: Dictionary, abs_dir: String, suffixes: Dictionary, segments: Array = []
) -> Dictionary:
	var out: Dictionary = {}
	for ch: String in channels_in:
		var src: String = str(channels_in[ch])
		var rel: String = _pool_small_file(
			src, abs_dir, _channel_pool_ext(suffixes.get(ch, ""), src), segments
		)
		if rel != "":
			out[ch] = rel
	return out


# Pools a video source into content/: transcodes (when the plan flags it) or copies,
# with modal progress + cancel. `display` names it in the progress modal, `subject`
# in error modals (e.g. 'Round "X"' / 'Encounter "Y"'). Returns {rel, ok}; ok=false
# (after showing an error modal) means the caller must abort the save. Empty src is a
# no-op success.
func _pool_video_into(
	vid_src: String,
	abs_dir: String,
	modal: Control,
	display: String,
	subject: String,
	rorder: int,
	total: int,
	segments: Array = []
) -> Dictionary:
	if vid_src == "":
		return {"rel": "", "ok": true}
	# One segment is a plain trim and rides the transcode plan as a single ffmpeg cut; two or
	# more can only be a concat, so they always re-encode and bypass the plan entirely.
	var is_edl: bool = segments.size() >= 2
	var trim_in: int = 0
	var trim_out: int = 0
	if segments.size() == 1:
		var only: Dictionary = segments[0]
		trim_in = int(only.get("in_ms", 0))
		trim_out = int(only.get("out_ms", 0))
	var plan_key: String = _transcode_plan_key(vid_src, segments)
	var is_transcode: bool = (not is_edl) and _transcode_plan.has(plan_key)
	var vid_ext: String = "mp4" if (is_transcode or is_edl) else vid_src.get_extension()
	var pool: Dictionary = _assign_pooled_media(vid_src, vid_ext, segments)
	var rel: String = pool["rel"]
	if not pool["copy"]:
		return {"rel": rel, "ok": true}
	var vid_dst: String = abs_dir + "/" + rel
	if is_edl:
		_update_modal_label(
			modal, "Round %d / %d — %s  (building segments)" % [rorder, total, display]
		)
		_transcode_cancel = false
		var lok: bool = await MediaPoolService.bake_edl(
			vid_src,
			vid_dst,
			segments,
			func(frac: float, cur: float, tot: float, spd: String) -> void:
				_update_modal_progress(modal, frac, cur, tot, spd),
			func() -> bool: return _transcode_cancel
		)
		if not lok:
			var reason: String = CAUSE_CANCELLED if _transcode_cancel else CAUSE_TRANSCODE_FAILED
			var headline: String = "SAVE CANCELLED" if _transcode_cancel else "SAVE FAILED"
			var detail: String = "ffmpeg failed to build the segmented clip for %s." % subject
			if _transcode_cancel:
				detail = "You cancelled the segment bake while %s was being processed." % subject
			_show_save_error_single(
				headline,
				reason,
				subject,
				detail,
				"Press Save again to retry. Nothing on disk was changed."
			)
			return {"rel": rel, "ok": false}
	elif is_transcode:
		var info: Dictionary = _transcode_plan[plan_key]
		_update_modal_round(modal, rorder, total, display, info["codec"])
		_transcode_cancel = false
		var ok: bool = await MediaPoolService.transcode_video(
			vid_src,
			vid_dst,
			info["duration"],
			trim_in,
			trim_out,
			func(frac: float, cur: float, tot: float, spd: String) -> void:
				_update_modal_progress(modal, frac, cur, tot, spd),
			func() -> bool: return _transcode_cancel
		)
		if not ok:
			if _transcode_cancel:
				_show_save_error_single(
					"SAVE CANCELLED",
					CAUSE_CANCELLED,
					subject,
					"You cancelled the transcode while %s was being processed." % subject,
					"Press Save again to retry. Nothing on disk was changed."
				)
			else:
				_show_save_error_single(
					"SAVE FAILED",
					CAUSE_TRANSCODE_FAILED,
					subject,
					(
						'ffmpeg failed to transcode video "%s" (codec %s → h264).'
						% [vid_src.get_file(), info["codec"]]
					),
					"The source video may be corrupt or use an unsupported variant. Try re-encoding it to H.264 .mp4 outside the editor, then re-drag it into this round."
				)
			return {"rel": rel, "ok": false}
	# Unchanged video: on a re-save the source is this journey's own pooled file, so hardlink it
	# into staging instead of byte-copying it (linear in journey size, every save — the real cost
	# on a large project). An author's original source isn't a pooled file, so it still copies.
	elif (
		MediaPoolService.is_pooled_content_file(vid_src)
		and MediaPoolService.try_hardlink(vid_src, vid_dst)
	):
		pass  # reused via hardlink — no copy needed
	else:
		_update_modal_label(modal, "Round %d / %d — %s  (copying video)" % [rorder, total, display])
		var copy_result: Dictionary = await _copy_file_chunked(
			vid_src,
			vid_dst,
			func(done: int, tot: int) -> void: _update_modal_copy(modal, done, tot)
		)
		if not copy_result["ok"]:
			_show_copy_failure_modal(copy_result, subject)
			return {"rel": rel, "ok": false}
	return {"rel": rel, "ok": true}


# Copies a storyboard node's images (background + per-line) into media/ (source-path dedup),
# rewriting saved_data's image fields to journey-root-relative paths. Filenames are keyed by
# the node id so two storyboards can't collide. Sync (small files); a copy failure sets
# _save_aborted, surfaced by the caller's checkpoint.
func _save_storyboard_node_media(
	saved_data: Dictionary,
	data_in: Dictionary,
	abs_dir: String,
	abs_media_dir: String,
	node_id: String,
	copied_images: Dictionary,
	modal: Control
) -> Dictionary:
	saved_data["image"] = await _store_journey_image(
		str(data_in.get("image", "")),
		abs_dir,
		abs_media_dir,
		node_id,
		copied_images,
		JourneyData.ANIM_CAP_STORYBOARD,
		modal
	)

	var lines_out: Array = []
	var lines_in: Array = data_in.get("lines", [])
	for li in lines_in.size():
		var line: Dictionary = lines_in[li]
		var li_rel: String = await _store_journey_image(
			str(line.get("image", "")),
			abs_dir,
			abs_media_dir,
			"%s_line_%d" % [node_id, li],
			copied_images,
			JourneyData.ANIM_CAP_STORYBOARD,
			modal
		)
		var line_out: Dictionary = {
			"speaker": str(line.get("speaker", "")),
			"text": str(line.get("text", "")),
			"image": li_rel,
		}
		# Persistent-stage portraits: a list of {character, portrait?, placement?} (ids only — the media
		# is pooled once per character). Carries through verbatim; omitted when empty to keep the schema
		# lean (mirrors set_counters / audio).
		var stage: Array = JourneyData.clean_stage(line.get("stage", []))
		if not stage.is_empty():
			line_out["stage"] = stage
		# Optional per-line audio accent — hash-pooled like any small file (no transcode; Godot
		# decodes ogg/mp3/wav natively). Only stored when set, to keep the schema lean.
		var audio_rel: String = _pool_small_file(str(line.get("audio", "")), abs_dir)
		if audio_rel != "":
			line_out["audio"] = audio_rel
			line_out["audio_loop"] = bool(line.get("audio_loop", false))
			line_out["audio_volume"] = clampf(float(line.get("audio_volume", 1.0)), 0.0, 1.0)
		lines_out.append(line_out)
	saved_data["lines"] = lines_out
	# Optional overarching BGM — one looping track under every line, pooled like the line accents.
	var bgm_rel: String = _pool_small_file(str(data_in.get("bgm", "")), abs_dir)
	if bgm_rel != "":
		saved_data["bgm"] = bgm_rel
		saved_data["bgm_volume"] = clampf(float(data_in.get("bgm_volume", 0.6)), 0.0, 1.0)
	return saved_data


# Builds a fork node's out-edges for save: one entry per choice, with the per-choice config
# coerced (weights/threshold/cost → int) and the choice's card image copied into media/
# (keyed by node id + choice index so paths sharing a name can't collide). The `to` target
# id is preserved verbatim (it's a node reference, not a path).
func _save_fork_node_edges(
	edges: Array,
	abs_dir: String,
	abs_media_dir: String,
	node_id: String,
	copied_images: Dictionary,
	modal: Control
) -> Array:
	var out: Array = []
	for ei in edges.size():
		var e: Dictionary = edges[ei]
		var img_rel: String = await _store_journey_image(
			str(e.get("image_path", "")),
			abs_dir,
			abs_media_dir,
			"%s_e%d_cover" % [node_id, ei],
			copied_images,
			JourneyData.ANIM_CAP_FORK,
			modal
		)
		(
			out
			. append(
				{
					"to": str(e.get("to", "")),
					"name": str(e.get("name", "")),
					"description": str(e.get("description", "")),
					"image_path": img_rel,
					"image_fit": str(e.get("image_fit", "")),
					"weight": int(e.get("weight", 1)),
					"threshold": int(e.get("threshold", 0)),
					"required_item": str(e.get("required_item", "")),
					"cost": int(e.get("cost", 0)),
					"required_flag": str(e.get("required_flag", "")),
					"cond_counter": str(e.get("cond_counter", "")),  # per-choice counter override (blank = fork default)
					"set_flags": JourneyData.clean_flag_list(e.get("set_flags", [])),
					"clear_flags": JourneyData.clean_flag_list(e.get("clear_flags", [])),
					"set_counters": JourneyData.clean_counter_deltas(e.get("set_counters", {})),
					"remove_items": JourneyData.clean_flag_list(e.get("remove_items", [])),
				}
			)
		)
	return out


# Normalizes a regular (non-fork) node's out list to its single forward edge: {to:<id>} when
# it has a target, or [] when it ends the run. Strips any stray edge config a regular node
# shouldn't carry, and enforces the ≤1-out-edge invariant (GRAPH_EDITOR_OVERHAUL.md §4).
func _clean_regular_out(edges: Array) -> Array:
	for e: Dictionary in edges:
		var to: String = str(e.get("to", ""))
		if to != "":
			return [{"to": to}]
	return []


# Writes journey.json into the staging folder. Returns false (showing the
# dst_unwritable modal) on I/O failure; the caller is responsible for
# subsequent cleanup of staging in that case.
func _write_journey_json(paths: Dictionary, data: Dictionary) -> bool:
	var json_path: String = paths["staging_journey_dir"] + "/journey.json"
	var f: FileAccess = FileAccess.open(json_path, FileAccess.WRITE)
	if f == null:
		_show_save_error_single(
			"SAVE FAILED",
			CAUSE_DST_UNWRITABLE,
			"journey.json",
			"Could not create %s." % json_path,
			"Check that the journeys folder drive isn't full or write-protected, and that no antivirus is blocking the editor. You can change the journeys folder in Options → Storage Location."
		)
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true


# Atomic-ish swap of the staging folder into its final location. The save
# wrote everything under a hidden sibling folder so the existing journey was
# untouched; now we clear the destination (in-place edit) and the old-name
# folder (journey rename), then rename staging into place. Per-round renames
# vanish implicitly along with the old folder.
func _swap_staging_into_place(paths: Dictionary) -> void:
	var abs_dir: String = paths["abs_dir"]
	var final_abs_dir: String = paths["final_abs_dir"]
	if DirAccess.dir_exists_absolute(final_abs_dir):
		JourneyData.delete_dir_recursive(final_abs_dir)
	if _original_journey_folder != "":
		var old_abs: String = ProjectSettings.globalize_path(_original_journey_folder)
		if old_abs != final_abs_dir and DirAccess.dir_exists_absolute(old_abs):
			JourneyData.delete_dir_recursive(old_abs)
	DirAccess.rename_absolute(abs_dir, final_abs_dir)


# Player run-saves point at a specific sequence snapshot of this journey. As
# soon as the author re-saves with any structural changes (rounds added /
# removed / reordered / forks reshaped), that snapshot can reference items
# that no longer exist or skip new ones. Rather than try to detect "did the
# structure actually change" — which is brittle and hard to be sure about —
# treat every successful builder save as a write barrier and wipe the run
# save. The author can always edit content (descriptions, coin values, etc.)
# without breaking the player's run, but to be safe we invalidate anyway.
#
# Covers two cases:
#   • In-place edit: same folder name → delete that folder's save.
#   • Rename: old folder name had the save → delete it. New folder name
#     wouldn't have one unless the user authored a duplicate elsewhere; we
#     attempt the delete defensively (no-op when nothing's there).
func _invalidate_existing_run_saves(paths: Dictionary) -> void:
	var final_abs: String = paths["final_abs_dir"]
	var new_folder_name: String = final_abs.get_file()
	# The run-save snapshot can reference rounds that no longer exist after an
	# edit, and recorded scores are no longer comparable — so a rebuild clears
	# both the resume save and the journey's scoreboard.
	if JourneySaveService.has_save(new_folder_name):
		JourneySaveService.delete_save(new_folder_name)
		_invalidated_save_count += 1
	ScoreboardService.clear(new_folder_name)
	if _original_journey_folder != "":
		var old_folder_name: String = (_original_journey_folder as String).get_file()
		if old_folder_name != "" and old_folder_name != new_folder_name:
			if JourneySaveService.has_save(old_folder_name):
				JourneySaveService.delete_save(old_folder_name)
				_invalidated_save_count += 1
			ScoreboardService.clear(old_folder_name)


# Final UX after a clean save: brief success message, then transition back
# to the journey catalogue. The 1.5s delay gives the user a moment to see
# the confirmation before the scene changes.
func _finalize_save_success() -> void:
	_mark_clean()
	var message: String = "Journey saved! Returning to catalogue..."
	if _invalidated_save_count > 0:
		message = "Journey saved! Existing player save reset. Returning to catalogue..."

	# An animation clipped to the length cap is named rather than silently shortened — otherwise the
	# author just finds their image mysteriously ending early and assumes it's a bug. Held longer
	# than the plain confirmation so there's time to actually read it.
	var hold: float = 1.5
	if not _anim_truncated.is_empty():
		message = (
			"Journey saved — trimmed %d animated image%s to %ds: %s"
			% [
				_anim_truncated.size(),
				"s" if _anim_truncated.size() != 1 else "",
				int(MediaPoolService.ANIM_MAX_SECS),
				", ".join(_anim_truncated),
			]
		)
		hold = 4.0

	_show_status(message, false)
	await get_tree().create_timer(hold).timeout
	Transition.change_scene("res://scenes/journey_select/JourneySelect.tscn")


# ---------------------------------------------------------------------------
# Transcode modal UI
# ---------------------------------------------------------------------------


func _create_transcode_modal() -> Control:
	var parts: Dictionary = UITheme.build_centered_modal(
		"SAVING JOURNEY", UITheme.PURPLE_BRIGHT, Vector2i(520, 240)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	modal.name = "TranscodeModal"
	parts["title"].name = "Title"
	# Override the default 12-separation with the transcode modal's looser 14
	# spacing — the progress bar reads more cleanly with extra breathing room.
	vbox.add_theme_constant_override("separation", 14)

	var round_lbl: Label = Label.new()
	round_lbl.name = "RoundLabel"
	round_lbl.text = ""
	UITheme.style_label(round_lbl, UITheme.WHITE_SOFT, 13, false)
	round_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(round_lbl)

	var bar: ProgressBar = ProgressBar.new()
	bar.name = "Bar"
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 14)
	var bar_bg: StyleBoxFlat = StyleBoxFlat.new()
	bar_bg.bg_color = UITheme.PURPLE_DARK
	bar.add_theme_stylebox_override("background", bar_bg)
	var bar_fill: StyleBoxFlat = StyleBoxFlat.new()
	bar_fill.bg_color = UITheme.PURPLE_BRIGHT
	bar.add_theme_stylebox_override("fill", bar_fill)
	vbox.add_child(bar)

	var status_lbl: Label = Label.new()
	status_lbl.name = "Status"
	status_lbl.text = "Starting..."
	UITheme.style_label(status_lbl, UITheme.PURPLE_MID, 12, false)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(status_lbl)

	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(120, 0)
	UITheme.style_button(cancel_btn, UITheme.MAGENTA)
	cancel_btn.pressed.connect(func() -> void: _transcode_cancel = true)
	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_child(cancel_btn)
	vbox.add_child(btn_row)

	return modal


func _update_modal_round(
	modal: Control, round_num: int, total: int, round_name: String, codec: String
) -> void:
	if modal == null:
		return
	var lbl: Label = modal.get_node("PanelContainer/VBoxContainer/RoundLabel") as Label
	if lbl == null:
		# Fallback: walk children since we didn't name the intermediate panel/vbox.
		lbl = modal.find_child("RoundLabel", true, false) as Label
	if lbl:
		lbl.text = (
			"Round %d / %d — %s  (%s → h264)" % [round_num, total, round_name, codec.to_upper()]
		)


# Sets the modal's headline to an arbitrary string. _update_modal_round formats a round-specific
# line ("Round 2 / 5 — …"); an image bake isn't a round, so it needs its own label rather than
# faking round numbers.
func _update_modal_label(modal: Control, text: String) -> void:
	if modal == null:
		return
	var lbl: Label = modal.find_child("RoundLabel", true, false) as Label
	if lbl:
		lbl.text = text


func _update_modal_progress(
	modal: Control, progress: float, current_s: float, total_s: float, speed: String
) -> void:
	if modal == null:
		return
	var bar: ProgressBar = modal.find_child("Bar", true, false) as ProgressBar
	if bar:
		bar.value = progress
	var status: Label = modal.find_child("Status", true, false) as Label
	if status:
		var pct: int = int(round(progress * 100.0))
		var cur: String = _format_time(current_s)
		var tot: String = _format_time(total_s) if total_s > 0.0 else "?"
		var spd: String = ("  •  " + speed) if speed != "" else ""
		status.text = "%s / %s  •  %d%%%s" % [cur, tot, pct, spd]


func _format_time(seconds: float) -> String:
	var s: int = int(seconds)
	return "%02d:%02d" % [s / 60, s % 60]


# Updates the modal bar + status line for a byte-based file copy.
func _update_modal_copy(modal: Control, copied: int, total: int) -> void:
	if modal == null:
		return
	var frac: float = (float(copied) / float(total)) if total > 0 else 0.0
	var bar: ProgressBar = modal.find_child("Bar", true, false) as ProgressBar
	if bar:
		bar.value = frac
	var status: Label = modal.find_child("Status", true, false) as Label
	if status:
		status.text = (
			"Copying… %d%%  (%s / %s)"
			% [int(round(frac * 100.0)), _format_size(copied), _format_size(total)]
		)


func _format_size(bytes: int) -> String:
	var mb: float = bytes / (1024.0 * 1024.0)
	if mb >= 1024.0:
		return "%.1f GB" % (mb / 1024.0)
	return "%.0f MB" % mb


# Returns the destination filename (relative to abs_dir) for an image. If the
# same source path was already copied during this save, reuses the existing
# destination file rather than copying again. `copied` maps src_path → fname.
func _copy_image_deduped(
	src: String, abs_dir: String, candidate_fname: String, copied: Dictionary
) -> String:
	if src == "":
		return ""
	if copied.has(src):
		return copied[src]
	_copy_file(src, abs_dir + "/" + candidate_fname)
	copied[src] = candidate_fname
	return candidate_fname


# Assigns a source file to the shared content pool for this save. Returns
# {rel, copy, fingerprint}: `rel` is the journey-root-relative pooled path
# (content/m_<fp>.<ext>), `copy` is true only the FIRST time this source is seen —
# the caller does the actual transcode/copy then and skips it on repeats. `ext`
# is the destination extension (mp4 for transcoded video, else the source ext).
# The pending segments join the fingerprint, so the same source cut differently
# by two rounds pools to two files while identical cuts still share one.
# Mirrors JourneyData.plan_media_pool's first-sighting logic with a live map.
func _assign_pooled_media(
	src: String, ext: String, segments: Array = [], variant: String = ""
) -> Dictionary:
	var fp: String = JourneyData.media_fingerprint(src, segments, variant)
	var rel: String = JourneyData.pooled_media_rel(fp, ext, src)
	var is_new: bool = not _pooled_media.has(fp)
	if is_new:
		_pooled_media[fp] = rel
	return {"rel": _pooled_media[fp], "copy": is_new, "fingerprint": fp}


# ── Animated images (GIF) ────────────────────────────────────────────────────


# Converts a GIF into something the runtime can actually display and pools it into content/,
# beside the journey's other A/V. Returns {handled, rel}: handled=false means `src` isn't a GIF and
# the caller should store it its normal way; rel is journey-root-relative, or "" if conversion
# failed outright.
#
# Godot has NO GIF decoder, so a GIF can never ship as-is — an animated one becomes a looping
# H.264, a single-frame one a PNG. `force_static` is for surfaces that accept GIFs but must not
# animate (the journey cover: it sits in the catalogue grid, where N animating cards would cost
# real frames for no gain).
func _store_gif_source(
	src: String, abs_dir: String, cap: Vector2i, force_static: bool = false, modal: Control = null
) -> Dictionary:
	if src == "" or not MediaPoolService.is_animated_source(src):
		return {"handled": false, "rel": ""}

	# Already exactly what the bake would produce (a baked image from a PRIOR save — a baked GIF is
	# now an .mp4)? Pool it verbatim instead of re-encoding. This is the fix for "converts every
	# save": once baked, the source qualifies, so a re-save is a fast copy like the content pool's
	# other .mp4s. force_static wants a still, so it skips this and extracts a frame.
	#
	# The test is is_baked_animation, NOT "is it H.264?" — ordinary clips are H.264 too, and
	# copying those through shipped their audio and their untruncated length.
	if not force_static and MediaPoolService.is_baked_animation(src, cap):
		return {"handled": true, "rel": _pool_small_file(src, abs_dir, "mp4")}

	var animated: bool = not force_static and MediaPoolService.probe_is_animated(src)
	if animated:
		var rel: String = await _bake_gif_pooled(src, abs_dir, cap, true, modal)
		if rel != "":
			return {"handled": true, "rel": rel}
		# A CANCELLED bake is not a failed one: falling back to a still here would quietly hand the
		# author a static image instead of honouring the cancel. Abort the save the same way a
		# failed copy does — surfaced at the caller's next checkpoint.
		if _transcode_cancel:
			_save_aborted = true
			_save_abort_error = {
				"result": {"ok": false, "reason": CAUSE_CANCELLED, "detail": src},
				"item": src.get_file(),
			}
			return {"handled": true, "rel": ""}
		# Genuine failure — fall back to the first frame rather than dropping the image entirely.
		push_warning(
			"JourneyBuilder: animation bake failed for '%s' — using its first frame." % src
		)
	return {"handled": true, "rel": await _bake_gif_pooled(src, abs_dir, cap, false, modal)}


# Stores a journey IMAGE (storyboard background / dialogue line, fork card, cover) and returns its
# journey-root-relative path, or "" when the source is empty or conversion failed.
#
# Two stores, by design: an ordinary image is copied verbatim into media/ (journey images), while a
# GIF is baked into content/ beside the journey's other A/V — it becomes video, and Godot could
# never display it as a GIF anyway. `cap` bounds the bake; `force_static` forbids animating.
func _store_journey_image(
	src: String,
	abs_dir: String,
	abs_media_dir: String,
	file_base: String,
	copied_images: Dictionary,
	cap: Vector2i,
	modal: Control = null,
	force_static: bool = false
) -> String:
	if src == "":
		return ""
	var gif: Dictionary = await _store_gif_source(src, abs_dir, cap, force_static, modal)
	if gif["handled"]:
		return str(gif["rel"])  # already journey-root-relative ("content/…"), or "" if it failed
	var ext: String = src.get_extension().to_lower()
	var f: String = _copy_image_deduped(
		src, abs_media_dir, "%s.%s" % [file_base, ext], copied_images
	)
	return ("media/" + f) if f != "" else ""


# One pooled bake. The size cap joins the fingerprint (see JourneyData.media_fingerprint): the same
# GIF at the same cap pools to one file, at different caps to different files. Returns "" on
# failure, without caching the fingerprint — a retry must not inherit a missing file.
func _bake_gif_pooled(
	src: String, abs_dir: String, cap: Vector2i, animated: bool, modal: Control = null
) -> String:
	var kind: String = "anim" if animated else "still"
	# No segments: an image is never cut — the size cap is what discriminates the pooled file.
	var pool: Dictionary = _assign_pooled_media(
		src, "mp4" if animated else "png", [], "%s:%dx%d" % [kind, cap.x, cap.y]
	)
	if not pool["copy"]:
		return pool["rel"]  # already baked this source+cap during this save

	var dst: String = abs_dir + "/" + str(pool["rel"])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst).get_base_dir())

	var ok: bool
	if animated:
		# A real encode — drive the same modal the round transcodes use, and honour the same
		# cancel flag, so a long bake shows progress instead of looking like a freeze.
		_update_modal_label(modal, "Converting image: %s" % src.get_file())
		var res: Dictionary = await MediaPoolService.bake_animation(
			src,
			dst,
			cap.x,
			cap.y,
			func(frac: float, cur: float, tot: float, spd: String) -> void:
				_update_modal_progress(modal, frac, cur, tot, spd),
			func() -> bool: return _transcode_cancel
		)
		ok = bool(res["ok"])
		if bool(res["truncated"]):
			_anim_truncated.append(src.get_file())
	else:
		ok = MediaPoolService.extract_first_frame(src, dst, cap.x, cap.y)  # one frame: instant

	if not ok:
		_pooled_media.erase(pool["fingerprint"])
		return ""
	return str(pool["rel"])


# Pools a small file (funscript / axis / vib / boss image) into content/ via the
# synchronous _copy_file, copying only on the first sighting of its source so
# reused assets are stored once. Returns the journey-root-relative pooled path
# ("" for an empty source). `ext_override` sets the pooled file's extension —
# used to keep the channel suffix on axis/vib scripts (e.g. "pitch.funscript");
# falls back to the source's extension when empty. A pending trim writes the
# rebased funscript instead of a verbatim copy (funscript-family files only —
# callers never pass trim for images). A copy failure sets _save_aborted
# (surfaced at the next checkpoint), like the other _copy_file sites.
func _pool_small_file(
	src: String, abs_dir: String, ext_override: String = "", segments: Array = []
) -> String:
	if src == "":
		return ""
	var ext: String = ext_override if ext_override != "" else src.get_extension()
	var pool: Dictionary = _assign_pooled_media(src, ext, segments)
	if pool["copy"]:
		if segments.is_empty():
			_copy_file(src, abs_dir + "/" + pool["rel"])
		else:
			_write_edl_funscript(src, abs_dir + "/" + pool["rel"], segments)
	return pool["rel"]


# Pools a boss timeline's media into content/ and returns the timeline with its paths rewritten to
# pooled rels. Each file is pooled the way its family expects: attack scripts as funscripts, audio
# verbatim, and cue art through the GIF/animation bake — a cue image may be an ANIMATION (the Tier-1
# attack-animation layer), and Godot can't decode GIF, so it can never ship verbatim. The enumeration
# and the rewrite both live in RoundTimeline, so this only has to know how to pool a file.
func _pool_timeline_media(timeline: Dictionary, abs_dir: String, modal: Control) -> Dictionary:
	var mapping: Dictionary = {}
	for entry: Dictionary in RoundTimeline.media_entries(timeline):
		var src: String = str(entry["path"])
		var kind: String = str(entry["kind"])
		if kind == RoundTimeline.MEDIA_FUNSCRIPT:
			mapping[src] = _pool_small_file(src, abs_dir, "funscript")
		elif kind == RoundTimeline.MEDIA_IMAGE:
			var gif: Dictionary = await _store_gif_source(
				src, abs_dir, JourneyData.ANIM_CAP_STORYBOARD, false, modal
			)
			mapping[src] = str(gif["rel"]) if gif["handled"] else _pool_small_file(src, abs_dir)
		else:
			mapping[src] = _pool_small_file(src, abs_dir)
	return RoundTimeline.remap_media(timeline, mapping)


# Pools an override item's funscript bundle into content/ (hash-deduped, funscript-family), rewriting the
# author's source paths to journey-root-relative pooled rels so the saved item — and the .fhj — carry the
# files. Empty channels are dropped. Mirrors the round's per-channel pooling, minus segments (never cut).
func _pool_override_scripts(scripts: Dictionary, abs_dir: String) -> Dictionary:
	var out: Dictionary = {}
	var main_src: String = str(scripts.get("main", ""))
	if main_src != "":
		out["main"] = _pool_small_file(main_src, abs_dir, "funscript")
	var axes_out: Dictionary = {}
	for axis_name: Variant in scripts.get("axes", {}):
		var axis_src: String = str(scripts["axes"][axis_name])
		if axis_src != "":
			axes_out[str(axis_name)] = _pool_small_file(axis_src, abs_dir, "funscript")
	if not axes_out.is_empty():
		out["axes"] = axes_out
	var vibes_out: Dictionary = {}
	for channel: Variant in scripts.get("vibes", {}):
		var vib_src: String = str(scripts["vibes"][channel])
		if vib_src != "":
			vibes_out[str(channel)] = _pool_small_file(vib_src, abs_dir, "funscript")
	if not vibes_out.is_empty():
		out["vibes"] = vibes_out
	return out


# Writes `src` to `dst` with its actions rebuilt from the round's segments — each window cut,
# rebased and laid end to end (JourneyData.edl_funscript_json; other metadata preserved). This
# is the one funscript writer: a trim is a single segment, a loop is a repeated one.
# An unparseable source is copied verbatim instead — storing the full script beats losing it,
# and the video bake proceeds regardless. Failure semantics match _copy_file (sets
# _save_aborted for the next checkpoint).
func _write_edl_funscript(src: String, dst: String, segments: Array) -> void:
	var f: FileAccess = FileAccess.open(src, FileAccess.READ)
	if f == null:
		printerr("JourneyBuilder: cannot read: " + src)
		_save_aborted = true
		_save_abort_error = {
			"result": {"ok": false, "reason": CAUSE_SRC_UNREADABLE, "detail": src},
			"item": src.get_file(),
		}
		return
	var text: String = f.get_as_text()
	f.close()
	var parser: JSON = JSON.new()
	if parser.parse(text) != OK or not (parser.data is Dictionary):
		printerr("JourneyBuilder: funscript unparseable, copying uncut: " + src)
		_copy_file(src, dst)
		return
	var built: Dictionary = JourneyData.edl_funscript_json(parser.data as Dictionary, segments)
	var out_f: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if out_f == null:
		printerr("JourneyBuilder: cannot write: " + dst)
		_save_aborted = true
		_save_abort_error = {
			"result": {"ok": false, "reason": CAUSE_DST_UNWRITABLE, "detail": dst},
			"item": dst.get_file(),
		}
		return
	out_f.store_string(JSON.stringify(built))
	out_f.close()


# Builds the pooled extension for a channel script so it keeps the standard
# funscript suffix (content/m_<fp>.<suffix>.<ext>, e.g. ...pitch.funscript).
# `suffix` is the channel's funscript suffix (surge/sway/…/vibe1); falls back to
# the bare source extension when the channel id isn't recognised.
func _channel_pool_ext(suffix: String, src: String) -> String:
	var src_ext: String = src.get_extension()
	if suffix == "" or src_ext == "":
		return src_ext
	return suffix + "." + src_ext


# Synchronous whole-file copy. Use only for small files (funscripts, images) —
# for video use _copy_file_chunked so the main thread doesn't freeze.
#
# On failure (source unreadable or destination unwritable), sets _save_aborted
# and _save_abort_error so the next `if _save_aborted:` checkpoint in the save
# loop can surface a specific error modal. This matches the existing fork-path
# unwind pattern, so callers don't need to inspect the result individually.
func _copy_file(src: String, dst: String) -> void:
	var src_file: FileAccess = FileAccess.open(src, FileAccess.READ)
	if src_file == null:
		printerr("JourneyBuilder: cannot read: " + src)
		_save_aborted = true
		_save_abort_error = {
			"result": {"ok": false, "reason": CAUSE_SRC_UNREADABLE, "detail": src},
			"item": "File copy",
		}
		return
	var bytes: PackedByteArray = src_file.get_buffer(src_file.get_length())
	src_file.close()
	var dst_file: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if dst_file == null:
		printerr("JourneyBuilder: cannot write: " + dst)
		_save_aborted = true
		_save_abort_error = {
			"result": {"ok": false, "reason": CAUSE_DST_UNWRITABLE, "detail": dst},
			"item": "File copy",
		}
		return
	dst_file.store_buffer(bytes)
	dst_file.close()


# Returns the next short folder slug for a round and bumps the counter.
# Format: "r" + zero-padded 3-digit index ("r001", "r002", …). Three digits
# comfortably fits any journey (max real-world rounds is well under 1000;
# the format gracefully handles overflow by growing to 4+ digits).
func _next_round_folder_slug() -> String:
	_round_folder_counter += 1
	return "r%03d" % _round_folder_counter


# Streaming file copy for large files (video). Reads/writes in COPY_CHUNK_SIZE
# blocks and yields one frame whenever COPY_FRAME_BUDGET_MS of work has piled
# up — so the window stays responsive and the modal can repaint, without paying
# a full frame-wait per chunk. `progress` (optional) is called as
# progress.call(copied_bytes, total_bytes). Honours the modal's cancel button
# via _transcode_cancel.
#
# Returns a Dictionary describing the outcome:
#   {"ok": true,  "reason": "ok"}
#   {"ok": false, "reason": "src_unreadable", "detail": <path>}
#   {"ok": false, "reason": "dst_unwritable", "detail": <path>}
#   {"ok": false, "reason": "cancelled",      "detail": ""}
# Callers use `reason` to pick a specific error message + remediation hint.
func _copy_file_chunked(src: String, dst: String, progress: Callable = Callable()) -> Dictionary:
	var src_file: FileAccess = FileAccess.open(src, FileAccess.READ)
	if src_file == null:
		printerr("JourneyBuilder: cannot read: " + src)
		return {"ok": false, "reason": CAUSE_SRC_UNREADABLE, "detail": src}
	var dst_file: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if dst_file == null:
		printerr("JourneyBuilder: cannot write: " + dst)
		src_file.close()
		return {"ok": false, "reason": CAUSE_DST_UNWRITABLE, "detail": dst}

	var total: int = src_file.get_length()
	var copied: int = 0
	var budget_start: int = Time.get_ticks_msec()

	while copied < total:
		if _transcode_cancel:
			src_file.close()
			dst_file.close()
			return {"ok": false, "reason": CAUSE_CANCELLED, "detail": ""}
		var chunk: PackedByteArray = src_file.get_buffer(COPY_CHUNK_SIZE)
		if chunk.is_empty():
			break
		dst_file.store_buffer(chunk)
		copied += chunk.size()
		if progress.is_valid():
			progress.call(copied, total)
		if Time.get_ticks_msec() - budget_start >= COPY_FRAME_BUDGET_MS:
			await get_tree().process_frame
			budget_start = Time.get_ticks_msec()

	src_file.close()
	dst_file.close()
	return {"ok": true, "reason": "ok"}


# Removes files inside `dir_path` whose extension is in `extensions` but whose
# filename is NOT `keep_filename`. Called after writing a replacement video
# (for funscripts use _delete_stale_l0_files / _delete_stale_axis_files instead).
func _delete_stale_files(dir_path: String, keep_filename: String, extensions: Array) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var to_delete: PackedStringArray = []
	var fname: String = da.get_next()
	while fname != "":
		if (
			not da.current_is_dir()
			and fname.get_extension().to_lower() in extensions
			and fname != keep_filename
		):
			to_delete.append(dir_path + "/" + fname)
		fname = da.get_next()
	da.list_dir_end()
	for p: String in to_delete:
		DirAccess.remove_absolute(p)


# Like _delete_stale_files but specifically for the L0 (main stroke) funscript.
# Skips files that look like secondary-axis scripts (`*_L1.*`, `*_R0.*`, etc.) or
# vibrator-channel scripts (`*_vib1.*`, `*_vib2.*`) so they are never accidentally
# deleted when the L0 name changes.
func _delete_stale_l0_files(dir_path: String, keep_filename: String) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var to_delete: PackedStringArray = []
	var fname: String = da.get_next()
	while fname != "":
		if (
			not da.current_is_dir()
			and fname != keep_filename
			and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS
		):
			var stem: String = fname.get_basename()
			var is_secondary: bool = false
			for ax: String in JourneyData.EXTRA_AXES:
				if stem.ends_with("_" + ax):
					is_secondary = true
					break
			if not is_secondary:
				for vk: String in ["_vib1", "_vib2", "_vibe1", "_vibe2"]:
					if stem.ends_with(vk):
						is_secondary = true
						break
			if not is_secondary:
				to_delete.append(dir_path + "/" + fname)
		fname = da.get_next()
	da.list_dir_end()
	for p: String in to_delete:
		DirAccess.remove_absolute(p)


# Removes stale funscript files that belong to a specific secondary axis
# (i.e. `*_AXIS.funscript`) but are not the newly written `keep_filename`.
func _delete_stale_axis_files(dir_path: String, axis: String, keep_filename: String) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var to_delete: PackedStringArray = []
	var fname: String = da.get_next()
	while fname != "":
		if (
			not da.current_is_dir()
			and fname != keep_filename
			and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS
			and fname.get_basename().ends_with("_" + axis)
		):
			to_delete.append(dir_path + "/" + fname)
		fname = da.get_next()
	da.list_dir_end()
	for p: String in to_delete:
		DirAccess.remove_absolute(p)


# Converts the internal boss-modifier model ({kind, factor, min, max}) into the
# PascalCase form written to journey.json, keeping only the keys each kind uses.
# Removes stale vibrator-channel funscript files for a specific channel key
# (i.e. `*_vib1.funscript`) but are not the newly written `keep_filename`.
func _delete_stale_vib_files(dir_path: String, ch_key: String, keep_filename: String) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var to_delete: PackedStringArray = []
	var fname: String = da.get_next()
	while fname != "":
		if (
			not da.current_is_dir()
			and fname != keep_filename
			and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS
			and fname.get_basename().ends_with("_" + ch_key)
		):
			to_delete.append(dir_path + "/" + fname)
		fname = da.get_next()
	da.list_dir_end()
	for p: String in to_delete:
		DirAccess.remove_absolute(p)


# ---------------------------------------------------------------------------
# Save error reporting
# ---------------------------------------------------------------------------
#
# Every save problem flows through a "SaveError" Dictionary with this shape:
#   {
#     "cause":  String   – short machine code, see SAVE_ERROR_CAUSES below
#     "item":   String   – user-facing label, e.g. 'Round 3 "Boss Fight"'
#                          or 'Fork 1 → Path "Adventure" → Round 2'
#     "detail": String   – the specific failure (path, error, etc.)
#     "hint":   String   – one-line remediation suggestion
#   }
#
# Pre-save validation collects ALL problems before any file is touched so the
# user sees them in one pass. Mid-save failures (cancel, copy error, transcode
# error) build one SaveError and route through the same modal.


# Returns true if the given source-file path exists on disk. Used by validation
# instead of FileAccess.file_exists so user:// paths and absolute paths both work.
func _save_source_exists(path: String) -> bool:
	if path == "":
		return false
	return FileAccess.file_exists(ProjectSettings.globalize_path(path))


# Returns an Array of SaveError dicts for all problems found in the graph. An empty array
# means the journey is safe to save.
func _collect_presave_issues() -> Array:
	return _collect_presave_issues_graph()


# Journey-level presave checks shared by the tree + graph paths: name present, no rename
# collision with another journey on disk, and the cover image (if any) still exists.
func _collect_journey_meta_issues(issues: Array) -> void:
	var jn: String = _journey_name.strip_edges()
	if jn == "":
		(
			issues
			. append(
				{
					"cause": CAUSE_BAD_NAME,
					"item": "Journey",
					"detail": "Journey name is required.",
					"hint":
					"Enter a name in the Journey Info panel (right-side, no node selected).",
				}
			)
		)
	else:
		# Rename-collision guard. If the sanitized name maps to a folder that
		# already exists AND it's not the journey we're editing, the swap at
		# the end of save would wipe that other journey's data. Refuse here.
		var sanitized_jn: String = JourneyData.sanitize_folder_name(jn)
		var target_journey_dir: String = SettingsService.get_journeys_dir() + "/" + sanitized_jn
		var target_abs: String = ProjectSettings.globalize_path(target_journey_dir)
		var original_abs: String = ""
		if _original_journey_folder != "":
			original_abs = ProjectSettings.globalize_path(_original_journey_folder)
		if target_abs != original_abs and DirAccess.dir_exists_absolute(target_abs):
			(
				issues
				. append(
					{
						"cause": CAUSE_NAME_COLLISION,
						"item": "Journey",
						"detail": "A journey already exists at: %s" % target_abs,
						"hint":
						"Saving with this name would replace that other journey. Pick a different name, or delete the existing journey from the catalogue first.",
					}
				)
			)
	if _cover_path != "" and not _save_source_exists(_cover_path):
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": "Journey cover image",
					"detail": "Cover image no longer exists at: %s" % _cover_path,
					"hint": "Re-drag the cover image into the Journey Info panel, or remove it.",
				}
			)
		)
	_collect_custom_item_issues(issues)


# Custom items must have a name; a modifier must carry at least one effect (a key needs none); an
# item image, if set, must still exist. Blocks save — a nameless/effectless item is unusable.
func _collect_custom_item_issues(issues: Array) -> void:
	for it: Dictionary in _journey_items:
		var iname: String = str(it.get("name", "")).strip_edges()
		var label: String = "Custom item '%s'" % iname if iname != "" else "Custom item"
		if iname == "":
			(
				issues
				. append(
					{
						"cause": CAUSE_ITEM_INVALID,
						"item": "Custom item",
						"detail": "A custom item has no name.",
						"hint": "Give every custom item a name in the Custom Items panel.",
					}
				)
			)
		if (
			str(it.get("category", "modifier")) == "modifier"
			and (it.get("effects", []) as Array).is_empty()
		):
			(
				issues
				. append(
					{
						"cause": CAUSE_ITEM_INVALID,
						"item": label,
						"detail": "This modifier item has no effects — using it would do nothing.",
						"hint": "Add at least one effect, or switch its type to Key.",
					}
				)
			)
		if str(it.get("category", "modifier")) == "override":
			var main_src: String = str((it.get("scripts", {}) as Dictionary).get("main", ""))
			if main_src == "":
				(
					issues
					. append(
						{
							"cause": CAUSE_ITEM_INVALID,
							"item": label,
							"detail":
							"This override item has no main funscript — using it would do nothing.",
							"hint": "Drop a main .funscript into the item editor.",
						}
					)
				)
			elif not _save_source_exists(main_src):
				(
					issues
					. append(
						{
							"cause": CAUSE_MISSING_SOURCE,
							"item": label,
							"detail": "Override funscript no longer exists at: %s" % main_src,
							"hint": "Re-drop the override's main funscript in the item editor.",
						}
					)
				)
		var img: String = str(it.get("image", ""))
		if img != "" and not _save_source_exists(img):
			(
				issues
				. append(
					{
						"cause": CAUSE_MISSING_SOURCE,
						"item": label,
						"detail": "Item image no longer exists at: %s" % img,
						"hint": "Re-add the item image, or remove it.",
					}
				)
			)


# Graph-editor presave validation. Per GRAPH_EDITOR_OVERHAUL.md §10/§12, deep structural
# checks (cycles, unreachable, dangling edges) are deferred to L4 — migrated journeys are
# always valid and full free-form authoring isn't reachable yet. For now: journey meta, at
# least one round node, and the per-round / per-storyboard source checks (reused as-is —
# they read a node's lowercase data dict directly, identical to a tree item).
func _collect_presave_issues_graph() -> Array:
	var issues: Array = []
	_collect_journey_meta_issues(issues)

	var nodes: Dictionary = _graph_model.get("nodes", {})
	var has_round: bool = false
	for id: String in nodes:
		if str((nodes[id] as Dictionary).get("type", "")) == "round":
			has_round = true
			break
	if not has_round:
		(
			issues
			. append(
				{
					"cause": CAUSE_NO_ROUNDS,
					"item": "Journey",
					"detail": "A journey needs at least one round node.",
					"hint": "Add a round from the side panel's ADD NODE row.",
				}
			)
		)

	# Per-type ordinals (shared with GraphView) so "Storyboard 4" in an error points at the node the
	# graph also labels 4.
	var ordinals: Dictionary = JourneyGraph.type_ordinals(nodes)
	for id: String in nodes:
		var n: Dictionary = nodes[id]
		var data: Dictionary = n.get("data", {})
		var ordinal: int = int(ordinals.get(id, 0))
		var before: int = issues.size()
		match str(n.get("type", "")):
			"round":
				_save_check_round(data, "Round %d" % ordinal, issues)
			"storyboard":
				_save_check_storyboard(data, "Storyboard %d" % ordinal, issues)
			"fork":
				_save_check_fork_graph(n, "Fork %d" % ordinal, issues)
			"loop_end":
				_save_check_loop(id, data, "Loop %d" % ordinal, issues)
			"loop_start":
				_save_check_loop_start(id, "Loop %d" % ordinal, issues)
		# Stamp the source node onto everything this node's checks just produced, so its error
		# row in the modal can navigate straight to it on the canvas.
		for k: int in range(before, issues.size()):
			(issues[k] as Dictionary)["node_id"] = id

	# Structural graph validation (L4): block on graphs the runtime can't cleanly play — a missing
	# start, an edge to a deleted node, a cycle (the DAG walk would loop forever), or an unreachable
	# node. Unreachable nodes block so a saved journey never carries media that's never played (a
	# storage concern): the author must wire the orphan into the flow or delete it before saving.
	for gi: Dictionary in JourneyGraph.validate_graph(_graph_model, _journey_finish_node):
		var m: Dictionary = _structural_issue_to_presave(gi)
		if not m.is_empty():
			# validate_graph carries the offending node's id (empty for no_start) — thread it
			# through so the row is clickable, same as the per-node checks above.
			var nid: String = str(gi.get("id", ""))
			if nid != "":
				m["node_id"] = nid
			issues.append(m)
	return issues


# Maps one JourneyGraph.validate_graph issue to a presave-issue dict (shared by the base + rendition
# collectors). Returns {} for an unknown kind.
func _structural_issue_to_presave(gi: Dictionary) -> Dictionary:
	match str(gi.get("kind", "")):
		"no_start":
			return {
				"cause": CAUSE_NO_START,
				"item": "Journey",
				"detail": "The journey has no valid start node.",
				"hint": "Reopen the journey, or add a node — the first node becomes the start.",
			}
		"dangling":
			return {
				"cause": CAUSE_DANGLING_EDGE,
				"item": _graph_issue_label(str(gi.get("id", ""))),
				"detail": "A connection points to a node that no longer exists.",
				"hint":
				"Re-wire that connection to a current node — its target may have been deleted.",
			}
		"cycle":
			return {
				"cause": CAUSE_CYCLE,
				"item": _graph_issue_label(str(gi.get("id", ""))),
				"detail": "This node is part of a loop — a journey must flow forward (no cycles).",
				"hint": "Remove the connection that loops back to an earlier node.",
			}
		"unreachable":
			return {
				"cause": CAUSE_UNREACHABLE,
				"item": _graph_issue_label(str(gi.get("id", ""))),
				"detail":
				"This node can't be reached from the start, so it would never play — and its media would bloat the saved journey.",
				"hint": "Connect it into the flow (wire an earlier node to it), or delete it.",
			}
	return {}


# Readable label for a node id, used by the structural validation messages.
func _graph_issue_label(node_id: String) -> String:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	if not nodes.has(node_id):
		return "A node"
	var n: Dictionary = nodes[node_id]
	var d: Dictionary = n.get("data", {})
	match str(n.get("type", "")):
		"round":
			var rn: String = str(d.get("name", "")).strip_edges()
			return 'Round "%s"' % rn if rn != "" else "A round"
		"shop":
			var sn: String = str(d.get("title", "")).strip_edges()
			return 'Shop "%s"' % sn if sn != "" else "A shop"
		"storyboard":
			return "A storyboard"
		"fork":
			var fn: String = str(d.get("title", "")).strip_edges()
			return 'Fork "%s"' % fn if fn != "" else "A fork"
		"loop_start":
			return "A Loop Start"
		"loop_end":
			return "A Loop End"
	return "A node"


# Boss ENCOUNTER validation, run through the timeline's own validate() — the same call that drives the
# encounter editor's warnings, so what the editor flags is exactly what blocks the save rather than two
# rules drifting apart.
#
# The round's LENGTH is passed when known. An unsaved round has none, and validate() then skips the
# checks that need it (overlapping attacks, events past the end) while still catching the content
# problems — an attack with no funscript, an empty cue, an effect window applying nothing. Guessing a
# length would produce confident, wrong complaints.
func _save_check_encounter(data: Dictionary, ctx: String, issues: Array) -> void:
	# Only a BOSS round plays its encounter (GameLoop._load_round_timeline), so a timeline left behind on
	# a round switched back to normal/effect is dormant data — it must not block the save.
	if str(data.get("round_type", "normal")) != "boss":
		return
	var raw: Variant = data.get("timeline", {})
	if not (raw is Dictionary) or (raw as Dictionary).is_empty():
		return
	for issue: Dictionary in RoundTimeline.validate(
		raw as Dictionary, int(data.get("length_ms", 0))
	):
		(
			issues
			. append(
				{
					"cause": CAUSE_ENCOUNTER_INVALID,
					"item": "%s — encounter" % ctx,
					"detail": str(issue.get("message", "")),
					"hint":
					"Open the round's BUILD ENCOUNTER editor; the block is highlighted there.",
				}
			)
		)


# Graph fork authoring checks (3c-ii): a fork's choices are its out-edges. Mirrors the tree's
# _save_check_fork — ≥2 choices, a Sacrifice fork needs ≥1 free choice, and each choice needs a
# name (the player sees it on the choice screen). Structural edge validity (cycles / dangling) is
# handled separately by JourneyGraph.validate_graph; cycles are also prevented at wire time.
# Loop End validation (L4). First the PAIRING: the End's loop_to must point at its Loop Start, or it
# can't replay (a broken pair — e.g. the Start was deleted). Then SATISFIABILITY: a loop that jumps back
# must have at least one exit condition its BODY can satisfy, or the player loops forever (a soft-lock).
# Body = nodes on a path from the Start back to the End. Per condition: a fixed "after N loops" always
# exits; counter ≥ N needs a net-positive body bump; flag needs a body set_flags; item needs a body award.
# ANY → block when none can be met; ALL → block when any can't. No conditions ⇒ the body plays once and
# continues (harmless), so it isn't checked.
func _save_check_loop(loop_id: String, data: Dictionary, ctx: String, issues: Array) -> void:
	var loop_to: String = str(data.get("loop_to", "")).strip_edges()
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var paired: bool = (
		loop_to != ""
		and nodes.has(loop_to)
		and str((nodes[loop_to] as Dictionary).get("type", "")) == "loop_start"
	)
	if not paired:
		(
			issues
			. append(
				{
					"cause": CAUSE_LOOP_UNPAIRED,
					"item": ctx,
					"detail":
					"This Loop End isn't paired with a Loop Start, so it has nothing to replay.",
					"hint":
					"Delete it and drop a fresh Loop from the canvas menu — the pair is created linked.",
				}
			)
		)
		return
	var conds: Array = data.get("loop_conditions", [])
	if conds.is_empty():
		return
	var body: Dictionary = _loop_body_effects(loop_to, loop_id)
	var combine_all: bool = str(data.get("loop_combine", "any")) == "all"
	var unsatisfiable: Array = []  # labels of conditions the body can never satisfy
	var any_satisfiable: bool = false
	for cv: Dictionary in conds:
		if _loop_condition_satisfiable(cv, body):
			any_satisfiable = true
		else:
			unsatisfiable.append(_loop_condition_label(cv))
	var blocked: bool = (not unsatisfiable.is_empty()) if combine_all else (not any_satisfiable)
	if not blocked:
		return
	var detail: String
	if combine_all:
		detail = (
			"This loop exits only when ALL conditions are met, but its body can never satisfy: %s. The player would loop forever."
			% ", ".join(PackedStringArray(unsatisfiable))
		)
	else:
		detail = "None of this loop's exit conditions can be satisfied by its body, so the player would loop forever."
	(
		issues
		. append(
			{
				"cause": CAUSE_LOOP_UNSATISFIABLE,
				"item": ctx,
				"detail": detail,
				"hint":
				"Add a fixed 'after N loops' exit, or make a body node set the flag / grant the item / raise the counter the exit needs.",
			}
		)
	)


# Loop Start validation: a Start with no Loop End looping back to it is an orphan — it plays as a
# do-nothing passthrough and only clutters the graph. Require a matching End (the pair is created linked,
# so this only trips when the End was deleted).
func _save_check_loop_start(start_id: String, ctx: String, issues: Array) -> void:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	for nid: String in nodes.keys():
		var n: Dictionary = nodes[nid]
		if (
			str(n.get("type", "")) == "loop_end"
			and str((n.get("data", {}) as Dictionary).get("loop_to", "")) == start_id
		):
			return  # paired
	(
		issues
		. append(
			{
				"cause": CAUSE_LOOP_UNPAIRED,
				"item": ctx,
				"detail": "This Loop Start has no Loop End looping back to it.",
				"hint":
				"Delete it, or drop a fresh Loop from the canvas menu for a linked Start + End pair.",
			}
		)
	)


# The cumulative effects the loop body can produce: net counter deltas, flags it can set, items it can
# award. Body = nodes reachable from loop_to that can also reach the loop (the replayed stretch). Fork
# choice effects (on the out-edges) are folded in optimistically — the player may take the best choice.
func _loop_body_effects(loop_to: String, loop_id: String) -> Dictionary:
	var nodes: Dictionary = _graph_model.get("nodes", {})
	var forward: Dictionary = JourneyGraph.reachable_ids(_graph_model, loop_to)
	var counters: Dictionary = {}
	var flags: Dictionary = {}
	var items: Dictionary = {}
	for nid: String in forward.keys():
		if not JourneyGraph.reachable_ids(_graph_model, str(nid)).has(loop_id):
			continue  # not on a path back to the loop → not part of the replayed body
		var n: Dictionary = nodes.get(nid, {})
		_accumulate_loop_effects(n.get("data", {}), counters, flags, items)
		if str(n.get("type", "")) == "fork":
			for e: Dictionary in n.get("out", []):
				_accumulate_loop_effects(e, counters, flags, items)
	return {"counters": counters, "flags": flags, "items": items}


# Folds one effect-bearing dict (a node's data, or a fork choice edge) into the running body totals:
# set_counters summed, set_flags / award_item unioned.
func _accumulate_loop_effects(
	d: Dictionary, counters: Dictionary, flags: Dictionary, items: Dictionary
) -> void:
	var sc: Dictionary = JourneyData.clean_counter_deltas(d.get("set_counters", {}))
	for k: String in sc.keys():
		counters[k] = int(counters.get(k, 0)) + int(sc[k])
	for f: Variant in JourneyData.clean_flag_list(d.get("set_flags", [])):
		flags[str(f)] = true
	var aw: String = str(d.get("award_item", "")).strip_edges()
	if aw != "":
		items[aw] = true


# Whether the loop body can ever satisfy one exit condition. repeats always exits; a ≥ counter needs a
# threshold ≤ 0 (met on arrival) or a net-positive body bump; a ≤ counter (count-down) needs a
# net-negative body bump to drive it down (counters aren't floored, so a downward trend reaches any
# threshold); flag / item need a body that sets / grants it.
func _loop_condition_satisfiable(c: Dictionary, body: Dictionary) -> bool:
	match str(c.get("kind", "repeats")):
		"repeats":
			return true
		"counter":
			var thr: int = int(c.get("threshold", 0))
			var delta: int = int((body["counters"] as Dictionary).get(str(c.get("counter", "")), 0))
			if str(c.get("cmp", "gte")) == "lte":
				return delta < 0
			return thr <= 0 or delta > 0
		"flag":
			return (body["flags"] as Dictionary).has(str(c.get("flag", "")))
		"item":
			return (body["items"] as Dictionary).has(str(c.get("item", "")))
	return true  # unknown kind → don't block


func _loop_condition_label(c: Dictionary) -> String:
	match str(c.get("kind", "repeats")):
		"counter":
			var op: String = "≤" if str(c.get("cmp", "gte")) == "lte" else "≥"
			return (
				"counter '%s' %s %d" % [str(c.get("counter", "?")), op, int(c.get("threshold", 0))]
			)
		"flag":
			return "flag '%s' set" % str(c.get("flag", "?"))
		"item":
			return "has item '%s'" % str(c.get("item", "?"))
		"repeats":
			return "after %d loops" % int(c.get("count", 1))
	return "condition"


func _save_check_fork_graph(node: Dictionary, ctx: String, issues: Array) -> void:
	var edges: Array = node.get("out", [])
	var fork_audio: String = str((node.get("data", {}) as Dictionary).get("audio", ""))
	if fork_audio != "" and not _save_source_exists(fork_audio):
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": ctx,
					"detail": "Fork audio clip no longer exists at: %s" % fork_audio,
					"hint": "Re-add the fork audio, or remove it.",
				}
			)
		)
	if edges.size() < 2:
		(
			issues
			. append(
				{
					"cause": CAUSE_FORK_UNDERFILLED,
					"item": ctx,
					"detail": "Fork has only %d choice(s); needs at least 2." % edges.size(),
					"hint": "Add a second choice in the fork editor.",
				}
			)
		)
	if (
		str((node.get("data", {}) as Dictionary).get("resolution", "choice")) == "sacrifice"
		and not edges.is_empty()
	):
		var has_free: bool = false
		for e: Dictionary in edges:
			if int(e.get("cost", 0)) <= 0 and str(e.get("required_item", "")).strip_edges() == "":
				has_free = true
				break
		if not has_free:
			(
				issues
				. append(
					{
						"cause": CAUSE_FORK_UNDERFILLED,
						"item": ctx,
						"detail":
						"This Sacrifice fork has no free choice — the player could be stuck with no affordable option.",
						"hint":
						"Make at least one choice free: Coin Cost 0 and Required Item None.",
					}
				)
			)
	for ei in edges.size():
		if str((edges[ei] as Dictionary).get("name", "")).strip_edges() == "":
			(
				issues
				. append(
					{
						"cause": CAUSE_BAD_NAME,
						"item": "%s → Choice %d" % [ctx, ei + 1],
						"detail": "Choice name is empty.",
						"hint":
						"Give the choice a name in the fork editor (the player sees it on the choice screen).",
					}
				)
			)


func _save_check_round(round_data: Dictionary, ctx: String, issues: Array) -> void:
	var name: String = (round_data.get("name", "") as String).strip_edges()
	var label: String = '%s "%s"' % [ctx, name] if name != "" else ctx

	# Every segment must be a real window starting inside the content — a start past the end
	# bakes a near-empty video with an empty funscript. The funscript's length is the cheap
	# duration proxy; an out-point past the end is fine (ffmpeg stops at the end). Only the
	# first offender is reported — a ×30 repeat of a bad window would emit thirty copies.
	var segments: Array = JourneyData.normalize_segments(round_data)
	var fs_len: int = int(
		JourneyData.read_funscript_stats(str(round_data.get("funscript_path", ""))).get(
			"length_ms", 0
		)
	)
	for i: int in segments.size():
		var seg: Dictionary = segments[i]
		var s_in: int = int(seg.get("in_ms", 0))
		var s_out: int = int(seg.get("out_ms", 0))
		var pos: String = "Segment %d" % (i + 1) if segments.size() > 1 else "The trim"
		if s_out > 0 and s_in >= s_out:
			(
				issues
				. append(
					{
						"cause": CAUSE_TRIM_INVALID,
						"item": label,
						"detail":
						(
							"%s starts (%s) at or past its end (%s)."
							% [pos, _audit_mmss(s_in), _audit_mmss(s_out)]
						),
						"hint": "Fix the segment in the round editor, or remove it.",
					}
				)
			)
			break
		if s_in > 0 and fs_len > 0 and s_in >= fs_len:
			(
				issues
				. append(
					{
						"cause": CAUSE_TRIM_INVALID,
						"item": label,
						"detail":
						(
							"%s starts (%s) past the end of the content (%s)."
							% [pos, _audit_mmss(s_in), _audit_mmss(fs_len)]
						),
						"hint": "Lower the segment's start in the round editor, or remove it.",
					}
				)
			)
			break

	# Names are display-only now (see short-folder slug scheme). Any character
	# is fine — only empty names need to be flagged, since the name is the
	# user's identifier for the round in journey.json and the editor.
	if name == "":
		(
			issues
			. append(
				{
					"cause": CAUSE_BAD_NAME,
					"item": ctx,
					"detail": "Round name is empty.",
					"hint": "Give the round a name in the side-panel editor.",
				}
			)
		)

	# Pool round: validate the encounter entries instead of the round's own media
	# (empty by design). The own-media checks below don't apply.
	if str(round_data.get("round_type", "normal")) == "pool":
		_save_check_pool_entries(round_data, label, issues)
		return

	# Required: funscript.
	var fs: String = round_data.get("funscript_path", "")
	if fs == "":
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": label,
					"detail": "No funscript file selected.",
					"hint":
					"Drag a .funscript or .json file into the Funscript field for this round.",
				}
			)
		)
	elif not _save_source_exists(fs):
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": label,
					"detail": "Funscript file no longer exists at: %s" % fs,
					"hint":
					"The source file may have been moved or deleted. Re-drag it into the editor.",
				}
			)
		)

	# Optional: video.
	var vid: String = round_data.get("video_path", "")
	if vid != "" and not _save_source_exists(vid):
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": label,
					"detail": "Video file no longer exists at: %s" % vid,
					"hint":
					"The source file may have been moved or deleted. Re-drag it into the editor or remove the video.",
				}
			)
		)

	# Secondary axis scripts.
	var axis_scripts: Dictionary = round_data.get("axis_scripts", {})
	for axis: String in axis_scripts:
		var p: String = axis_scripts[axis]
		if p != "" and not _save_source_exists(p):
			(
				issues
				. append(
					{
						"cause": CAUSE_MISSING_SOURCE,
						"item": label,
						"detail": "%s axis funscript no longer exists at: %s" % [axis, p],
						"hint": "Re-drag the %s funscript in the Extra Axes section." % axis,
					}
				)
			)

	# Vibrator-channel scripts.
	var vib_scripts: Dictionary = round_data.get("vib_scripts", {})
	for ch_key: String in vib_scripts:
		var p: String = vib_scripts[ch_key]
		if p != "" and not _save_source_exists(p):
			(
				issues
				. append(
					{
						"cause": CAUSE_MISSING_SOURCE,
						"item": label,
						"detail": "%s vibrator funscript no longer exists at: %s" % [ch_key, p],
						"hint":
						"Re-drag the %s funscript in the Vibrator Scripts section." % ch_key,
					}
				)
			)

	# Boss intro image.
	var boss_image: String = round_data.get("boss_image", "")
	if boss_image != "" and not _save_source_exists(boss_image):
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": label,
					"detail": "Boss intro image no longer exists at: %s" % boss_image,
					"hint":
					"Re-drag the boss image in the Boss Round section, or disable boss mode.",
				}
			)
		)

	# (Path-length check used to live here. Removed once round folder names
	# became fixed-length slugs — a round folder is always exactly 4 chars
	# (`rNNN`) and the longest filename inside is `axis_<XY>.funscript` (~22
	# chars), so the only path-length lever left is the journey name itself,
	# which would need to be hundreds of characters to come close to MAX_PATH.)


# Presave validation for a pool round: it needs ≥1 encounter, and each encounter
# needs a video + funscript that still exist on disk (same requirements as a normal
# round, per entry).
func _save_check_pool_entries(round_data: Dictionary, label: String, issues: Array) -> void:
	var entries: Array = round_data.get("pool_entries", [])
	if entries.is_empty():
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": label,
					"detail": "Pool round has no encounters.",
					"hint": "Add at least one encounter (video + funscript) in the round editor.",
				}
			)
		)
		return
	for i: int in entries.size():
		var e: Dictionary = entries[i]
		var ename: String = str(e.get("name", "")).strip_edges()
		var elabel: String = (
			'%s — encounter "%s"' % [label, ename]
			if ename != ""
			else "%s — encounter %d" % [label, i + 1]
		)
		_save_check_pool_source(str(e.get("video_path", "")), "video", elabel, issues)
		_save_check_pool_source(str(e.get("funscript_path", "")), "funscript", elabel, issues)


# Flags a single required encounter source (video / funscript): absent, or set but
# missing on disk.
func _save_check_pool_source(path: String, kind: String, elabel: String, issues: Array) -> void:
	if path == "":
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": elabel,
					"detail": "No %s selected." % kind,
					"hint": "Drag a %s into this encounter, or remove it." % kind,
				}
			)
		)
	elif not _save_source_exists(path):
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": elabel,
					"detail": "Encounter %s no longer exists at: %s" % [kind, path],
					"hint": "Re-drag the %s or remove this encounter." % kind,
				}
			)
		)


func _save_check_storyboard(sb_data: Dictionary, ctx: String, issues: Array) -> void:
	# A storyboard must have at least one dialogue line — an empty one has nothing to show or advance
	# through (and would hang under auto-advance). Blocks save; also drives the ⚠ node badge.
	var lines: Array = sb_data.get("lines", [])
	if lines.is_empty():
		(
			issues
			. append(
				{
					"cause": CAUSE_STORYBOARD_EMPTY,
					"item": ctx,
					"detail": "This storyboard has no dialogue lines.",
					"hint": "Add at least one line, or delete the storyboard node.",
				}
			)
		)
	var default_img: String = sb_data.get("image", "")
	if default_img != "" and not _save_source_exists(default_img):
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": ctx,
					"detail": "Default image no longer exists at: %s" % default_img,
					"hint": "Re-drag the default image into the storyboard, or remove it.",
				}
			)
		)
	var bgm: String = str(sb_data.get("bgm", ""))
	if bgm != "" and not _save_source_exists(bgm):
		(
			issues
			. append(
				{
					"cause": CAUSE_MISSING_SOURCE,
					"item": ctx,
					"detail": "Background music no longer exists at: %s" % bgm,
					"hint": "Re-add the background music, or remove it.",
				}
			)
		)
	for li in lines.size():
		var line: Dictionary = lines[li]
		var img: String = line.get("image", "")
		if img != "" and not _save_source_exists(img):
			(
				issues
				. append(
					{
						"cause": CAUSE_MISSING_SOURCE,
						"item": "%s, Line %d" % [ctx, li + 1],
						"detail": "Speaker image no longer exists at: %s" % img,
						"hint": "Re-drag the speaker image into this line, or remove it.",
					}
				)
			)
		var aud: String = str(line.get("audio", ""))
		if aud != "" and not _save_source_exists(aud):
			(
				issues
				. append(
					{
						"cause": CAUSE_MISSING_SOURCE,
						"item": "%s, Line %d" % [ctx, li + 1],
						"detail": "Audio clip no longer exists at: %s" % aud,
						"hint": "Re-add the audio for this line, or remove it.",
					}
				)
			)


# ---------------------------------------------------------------------------
# Error modal
# ---------------------------------------------------------------------------


# Shows a centred modal listing one or more SaveError dicts. Closeable via the
# OK button or backdrop. "Copy details" copies a plain-text version of every
# issue to the clipboard so users can paste it into a bug report.
func _show_save_error_modal(title: String, headline: String, errors: Array) -> void:
	if errors.is_empty():
		return

	var parts: Dictionary = UITheme.build_centered_modal(
		title, UITheme.ERROR_SOFT, Vector2i(720, 520)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	modal.name = "SaveErrorModal"

	var headline_lbl: Label = Label.new()
	headline_lbl.text = headline
	UITheme.style_label(headline_lbl, UITheme.WHITE_SOFT, 13, false)
	headline_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	headline_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(headline_lbl)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var list: VBoxContainer = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)

	# Clicking a node-specific error closes the modal and locates that node on the canvas —
	# the same affordance the audit report offers. Meta issues carry no node_id and stay static.
	var jump := func(node_id: String) -> void:
		if node_id == "" or not (_graph_model.get("nodes", {}) as Dictionary).has(node_id):
			return
		modal.queue_free()
		if _graph:
			_graph.select_graph_node(node_id)
			_graph.center_on(node_id)

	for err: Dictionary in errors:
		list.add_child(_make_save_error_row(err, jump))

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)

	var copy_btn: Button = Button.new()
	copy_btn.text = "⎘  COPY DETAILS"
	copy_btn.custom_minimum_size = Vector2(160, 0)
	UITheme.style_button(copy_btn, UITheme.PURPLE_MID)
	copy_btn.pressed.connect(
		func() -> void:
			DisplayServer.clipboard_set(_save_errors_to_text(title, errors))
			copy_btn.text = "✓  COPIED"
	)
	btn_row.add_child(copy_btn)

	var ok_btn: Button = Button.new()
	ok_btn.text = "OK"
	ok_btn.custom_minimum_size = Vector2(120, 0)
	UITheme.style_button(ok_btn, UITheme.PURPLE_BRIGHT)
	ok_btn.pressed.connect(func() -> void: modal.queue_free())
	btn_row.add_child(ok_btn)

	add_child(modal)


# Builds one row for a single SaveError dict. The item label is the most
# prominent line; cause+detail explain what; hint suggests a fix.
func _make_save_error_row(err: Dictionary, jump: Callable = Callable()) -> Control:
	var row: PanelContainer = PanelContainer.new()
	var rs: StyleBoxFlat = StyleBoxFlat.new()
	rs.bg_color = UITheme.CARD_BG
	rs.border_color = Color(UITheme.ERROR_SOFT.r, UITheme.ERROR_SOFT.g, UITheme.ERROR_SOFT.b, 0.45)
	rs.border_width_left = 1
	rs.border_width_right = 1
	rs.border_width_top = 1
	rs.border_width_bottom = 1
	rs.content_margin_left = 10
	rs.content_margin_right = 10
	rs.content_margin_top = 8
	rs.content_margin_bottom = 8
	row.add_theme_stylebox_override("panel", rs)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	row.add_child(col)

	var item_lbl: Label = Label.new()
	item_lbl.text = (err.get("item", "") as String).to_upper()
	UITheme.style_label(item_lbl, UITheme.PURPLE_BRIGHT, 12, true)
	col.add_child(item_lbl)

	var detail_lbl: Label = Label.new()
	detail_lbl.text = err.get("detail", "")
	detail_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(detail_lbl, UITheme.WHITE_SOFT, 12, false)
	col.add_child(detail_lbl)

	var hint_text: String = err.get("hint", "")
	if hint_text != "":
		var hint_lbl: Label = Label.new()
		hint_lbl.text = "→  " + hint_text
		hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(hint_lbl, UITheme.SEPARATOR, 11, false)
		col.add_child(hint_lbl)

	# A node-specific error becomes a clickable row that locates its node on the canvas (mirrors
	# _audit_finding_row). Journey-meta issues — name, cover, custom items — carry no node_id and
	# stay static. col is IGNORE so the click falls through to the PanelContainer, whose gui_input
	# fires; the child Labels ignore mouse by default.
	var node_id: String = str(err.get("node_id", ""))
	if (
		node_id != ""
		and jump.is_valid()
		and (_graph_model.get("nodes", {}) as Dictionary).has(node_id)
	):
		var locate_lbl: Label = Label.new()
		locate_lbl.text = "↪  Click to locate this node"
		UITheme.style_label(locate_lbl, UITheme.CYAN, 11, false)
		col.add_child(locate_lbl)
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		row.tooltip_text = UITheme.wrap_tip("Click to locate this node on the canvas")
		row.gui_input.connect(
			func(ev: InputEvent) -> void:
				if (
					ev is InputEventMouseButton
					and ev.button_index == MOUSE_BUTTON_LEFT
					and ev.pressed
				):
					jump.call(node_id)
		)

	return row


# Serialises a list of SaveErrors into a plain-text block users can paste
# into a bug report. Format mirrors what the modal displays.
func _save_errors_to_text(title: String, errors: Array) -> String:
	var out: String = title + "\n" + "=".repeat(title.length()) + "\n\n"
	for i in errors.size():
		var err: Dictionary = errors[i]
		out += "%d. %s\n" % [i + 1, err.get("item", "")]
		out += "   Cause:  %s — %s\n" % [err.get("cause", ""), err.get("detail", "")]
		var hint: String = err.get("hint", "")
		if hint != "":
			out += "   Hint:   %s\n" % hint
		out += "\n"
	return out


# Builds a one-off SaveError list and shows the modal. Used by mid-save
# failures that produce a single specific error (copy failed, transcode
# failed, journey.json write failed, etc.).
func _show_save_error_single(
	title: String, cause: String, item: String, detail: String, hint: String
) -> void:
	_show_save_error_modal(
		title,
		"Save failed.",
		[
			{
				"cause": cause,
				"item": item,
				"detail": detail,
				"hint": hint,
			}
		]
	)


# Maps a _copy_file_chunked result dict to the right save-error modal call.
# `item` is the user-facing label (e.g. 'Round 4 "Boss Fight"' or
# 'Fork → Path A → Round 2 "Reward"'). Files the modal and is otherwise silent
# on success.
func _show_copy_failure_modal(copy_result: Dictionary, item: String) -> void:
	match copy_result.get("reason", ""):
		CAUSE_CANCELLED:
			_show_save_error_single(
				"SAVE CANCELLED",
				CAUSE_CANCELLED,
				item,
				"You cancelled the copy while %s was being processed." % item,
				"Press Save again to retry. Nothing on disk was changed."
			)
		CAUSE_SRC_UNREADABLE:
			_show_save_error_single(
				"SAVE FAILED",
				CAUSE_SRC_UNREADABLE,
				item,
				"Source file became unreadable: %s" % copy_result.get("detail", "?"),
				"The file may have been moved, deleted, or its drive disconnected since you opened the editor. Re-drag it into this round and try again."
			)
		CAUSE_DST_UNWRITABLE:
			_show_save_error_single(
				"SAVE FAILED",
				CAUSE_DST_UNWRITABLE,
				item,
				"Could not create the destination file: %s" % copy_result.get("detail", "?"),
				"Check that the journeys folder drive isn't full or write-protected, and that no antivirus is blocking the editor. You can change the journeys folder in Options → Storage Location."
			)
		_:
			_show_save_error_single(
				"SAVE FAILED",
				CAUSE_UNKNOWN_COPY_ERROR,
				item,
				"An unexpected copy failure occurred while processing %s." % item,
				"Try saving again. If the problem persists, check the Godot debug output for details."
			)


# ---------------------------------------------------------------------------
# Stale staging folder recovery
# ---------------------------------------------------------------------------
#
# Save uses a `.~save_<journey_name>` sibling folder for staging (so a mid-save
# failure can be rolled back atomically — see `_on_save_pressed`). On a clean
# save the staging folder is renamed into place; on a clean cancel/failure it
# is deleted. But an unclean exit (app crash, power loss, force-kill) leaves
# the staging folder behind. The catalogue scanner hides it (dot prefix) so
# the user has no in-app way to discover or remove it.
#
# On builder startup we scan for these and offer to clean them up. We show
# the dialog only when there's something to act on — first-time users with
# no leftovers see nothing.


# Returns absolute paths to every `.~save_*` folder currently sitting in the
# journeys root. Empty if nothing to recover.
func _find_stale_staging_folders() -> Array:
	var result: Array = []
	var journeys_abs: String = ProjectSettings.globalize_path(SettingsService.get_journeys_dir())
	var dir: DirAccess = DirAccess.open(journeys_abs)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if dir.current_is_dir() and entry.begins_with(".~save_"):
			result.append(journeys_abs + "/" + entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return result


# Called once per builder launch via call_deferred. Shows a non-blocking
# dialog when any staging folders are found, with options to delete them or
# leave them in place.
func _check_for_stale_staging_folders() -> void:
	var stale: Array = _find_stale_staging_folders()
	if stale.is_empty():
		return
	_show_stale_staging_dialog(stale)


# Built dynamically (rather than as a static .tscn) since this is a once-in-
# a-blue-moon flow and doesn't justify a scene file. Mirrors the SaveError
# modal style so it feels native.
func _show_stale_staging_dialog(stale: Array) -> void:
	var parts: Dictionary = UITheme.build_centered_modal(
		"UNFINISHED SAVES FOUND", UITheme.AMBER, Vector2i(680, 440)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]

	var headline: Label = Label.new()
	headline.text = (
		"Found %d leftover save folder%s from a previous session that didn't finish (crash, power loss, or force-quit). They take disk space and are normally safe to delete."
		% [
			stale.size(),
			"s" if stale.size() != 1 else "",
		]
	)
	headline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(headline, UITheme.WHITE_SOFT, 13, false)
	vbox.add_child(headline)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var list: VBoxContainer = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)

	for path: String in stale:
		# Strip the .~save_ prefix to give the user the human-readable name
		# (it's the journey-folder name that would have resulted).
		var journey_name: String = (path.get_file() as String).substr(len(".~save_"))
		var row: Label = Label.new()
		row.text = "•  %s\n   %s" % [journey_name, path]
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(row, UITheme.PURPLE_BRIGHT, 12, false)
		list.add_child(row)

	var recover_hint: Label = Label.new()
	recover_hint.text = "Advanced: to recover one manually, rename its folder to remove the `.~save_` prefix using your file manager. The journey will reappear in the catalogue. Most of the time, just deleting them is fine."
	recover_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(recover_hint, UITheme.SEPARATOR, 11, false)
	vbox.add_child(recover_hint)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)

	var keep_btn: Button = Button.new()
	keep_btn.text = "KEEP"
	keep_btn.custom_minimum_size = Vector2(140, 0)
	UITheme.style_button(keep_btn, UITheme.PURPLE_MID)
	keep_btn.pressed.connect(func() -> void: modal.queue_free())
	btn_row.add_child(keep_btn)

	var delete_btn: Button = Button.new()
	delete_btn.text = "✕  DELETE ALL"
	delete_btn.custom_minimum_size = Vector2(180, 0)
	UITheme.style_button(delete_btn, UITheme.MAGENTA)
	delete_btn.pressed.connect(
		func() -> void:
			for path: String in stale:
				JourneyData.delete_dir_recursive(path)
			modal.queue_free()
	)
	btn_row.add_child(delete_btn)

	add_child(modal)
