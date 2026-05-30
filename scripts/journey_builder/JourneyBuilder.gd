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

const TOP_BAR_HEIGHT:  int = 64

# Journeys root is configurable via Options → Journey Storage Location.
# Always read via SettingsService.get_journeys_dir() so a path change takes
# effect on the next save without restarting the scene.

# Difficulty list and file-extension sets live in JourneyData (canonical schema).
# Referenced here as JourneyData.DIFFICULTIES / JourneyData.IMAGE_EXTENSIONS etc.

# EIRTeam.FFmpeg only decodes H.264; everything else gets transcoded on save.
const H264_NAMES: Array[String] = ["h264", "avc1", "avc"]
const TRANSCODE_PROGRESS_FILE: String = "user://transcode_progress.txt"

# ── Save error / copy result cause codes ────────────────────────────────────
# Every SaveError flowing through _show_save_error_modal carries one of these
# in its `cause` field, and every _copy_file_chunked result carries one in
# its `reason` field. Centralised as constants so typos surface at parse time
# (string-literal mismatches in match statements silently fall through to the
# default arm otherwise) and the full taxonomy is easy to grep.
const CAUSE_BAD_NAME:           String = "bad_name"
const CAUSE_NAME_COLLISION:     String = "name_collision"
const CAUSE_MISSING_SOURCE:     String = "missing_source"
const CAUSE_NO_ROUNDS:          String = "no_rounds"
const CAUSE_FORK_UNDERFILLED:   String = "fork_underfilled"
const CAUSE_FFMPEG_MISSING:     String = "ffmpeg_missing"
const CAUSE_CANCELLED:          String = "cancelled"
const CAUSE_SRC_UNREADABLE:     String = "src_unreadable"
const CAUSE_DST_UNWRITABLE:     String = "dst_unwritable"
const CAUSE_TRANSCODE_FAILED:   String = "transcode_failed"
const CAUSE_UNKNOWN_COPY_ERROR: String = "unknown_copy_error"

const GraphViewScene = preload("res://scenes/graph_view/GraphView.tscn")

@onready var _bg:          ColorRect       = $Background
@onready var _top_bar:     HBoxContainer   = $TopBar
@onready var _back_btn:    Button          = $TopBar/BackButton
@onready var _title_lbl:   Label           = $TopBar/TitleLabel
@onready var _status_lbl:  Label           = $TopBar/StatusLabel
@onready var _save_btn:    Button          = $TopBar/SaveButton
@onready var _main_layout: HBoxContainer   = $MainLayout
@onready var _graph_host:  Control         = $MainLayout/GraphHost
@onready var _side_panel:  PanelContainer  = $MainLayout/SidePanel
@onready var _side_scroll: ScrollContainer = $MainLayout/SidePanel/SideScroll
@onready var _side_vbox:   VBoxContainer   = $MainLayout/SidePanel/SideScroll/SideVBox

static var edit_journey: Dictionary = {}

const SIDE_PANEL_WIDTH: int = 480

# Journey metadata: stored as member vars since the side-panel editor widgets
# are created and destroyed dynamically when the user navigates the graph.
var _journey_name:           String = ""
var _journey_author:         String = ""
var _journey_desc:           String = ""
var _journey_difficulty_idx: int    = 0
var _journey_tags:           Array  = []  # Array[String] of tag ids (see TagRegistry)

# Folder the journey was loaded from when editing. If the journey is renamed,
# the save writes a new folder; this lets us delete the stale original.
var _original_journey_folder: String = ""

var _cover_path:    String       = ""
var _cover_texture: ImageTexture = null  # cached so the journey-info view can re-show the preview without re-reading from disk

var _items:      Array  = []  # Array[Dictionary] — {type:"round"|"fork"|"shop"|"storyboard", ...}

var _graph: Control = null  # GraphView instance, host inside _graph_host
var _selected_item: Dictionary = {}  # Mirror of GraphView's current selection.
var _selected_arr:  Array      = []  # The array the selected item lives in.
var _selected_idx:  int        = -1  # Index within that array.

# Side panel renderer — owns no state of its own; reads/mutates this controller.
var _side_renderer: BuilderSidePanel = null

var _transcode_cancel: bool = false
var _transcode_pid:    int  = -1

# Set true when a video copy/transcode is cancelled mid-save inside a fork path,
# so the recursive _save_fork/_save_path chain can unwind and _on_save_pressed
# can abort the whole save cleanly.
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

# Save-wide map of non-H.264 video source paths → {codec, duration}. Built
# once at the start of _on_save_pressed by walking the whole journey tree,
# then consulted in both the top-level round save AND the recursive
# _save_path so that videos inside fork paths get transcoded too.
var _transcode_plan: Dictionary = {}

# Streaming-copy tuning. Chunks are read/written 1 MB at a time; the main thread
# yields one frame only after COPY_FRAME_BUDGET_MS of accumulated work — frequent
# enough that the window stays responsive, rare enough that the frame-wait tax
# stays under ~1 s even on multi-GB videos.
const COPY_CHUNK_SIZE:       int = 1024 * 1024
const COPY_FRAME_BUDGET_MS:  int = 100


func _ready() -> void:
	MusicService.play()
	_side_renderer = BuilderSidePanel.new(self)
	_apply_layout()
	_apply_theme()
	_connect_signals()
	_setup_graph_view()
	if not edit_journey.is_empty():
		_original_journey_folder = edit_journey.get("folder", "")
		_load_journey(edit_journey)
		edit_journey = {}
	_side_renderer.show_journey_info_panel()
	# Check for leftover staging folders from interrupted saves (crash, force-
	# kill, power loss). They take disk space and the user has no way to know
	# they exist otherwise — the dot prefix hides them from the catalogue.
	# Deferred so the dialog appears over the fully-rendered builder.
	call_deferred("_check_for_stale_staging_folders")


# Builds the GraphView inside the GraphHost slot, wires its selection / insert
# signals to the side panel.
func _setup_graph_view() -> void:
	_graph = GraphViewScene.instantiate()
	_graph.anchor_right  = 1.0
	_graph.anchor_bottom = 1.0
	_graph_host.add_child(_graph)
	_graph.node_selected.connect(_on_graph_node_selected)
	_graph.insert_requested.connect(_on_graph_insert_requested)
	# Initial state: render current _items (empty for a new journey).
	_graph.call_deferred("set_items", _items)


func _on_graph_node_selected(item: Dictionary, arr: Array, idx: int) -> void:
	_selected_item = item
	_selected_arr  = arr
	_selected_idx  = idx
	if item.is_empty():
		_side_renderer.show_journey_info_panel()
	else:
		_side_renderer.show_node_editor(item, arr, idx)


func _on_graph_insert_requested(arr: Array, idx: int, screen_pos: Vector2) -> void:
	_side_renderer.show_insert_popup(self, _graph, arr, idx, screen_pos)


# Replaces _refresh_items()'s former role: rebuild the graph from _items.
# Called after structural changes (load, drop import, etc).
func _refresh_graph() -> void:
	if _graph:
		_graph.set_items(_items)


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right  = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = 0; _bg.offset_top = 0; _bg.offset_right = 0; _bg.offset_bottom = 0

	var animated_bg: Control = $AnimatedBackground
	animated_bg.anchor_right  = 1.0
	animated_bg.anchor_bottom = 1.0

	_top_bar.anchor_right  = 1.0
	_top_bar.offset_left   = 16
	_top_bar.offset_right  = -16
	_top_bar.offset_top    = 12
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_top_bar.add_theme_constant_override("separation", 12)

	# Title expands to fill space between Back (left) and Status/Save (right).
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_main_layout.anchor_right  = 1.0
	_main_layout.anchor_bottom = 1.0
	_main_layout.offset_left   = 16
	_main_layout.offset_right  = -16
	_main_layout.offset_top    = TOP_BAR_HEIGHT + 8
	_main_layout.offset_bottom = -16
	_main_layout.add_theme_constant_override("separation", 12)

	_graph_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_host.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_graph_host.clip_contents         = true

	_side_panel.custom_minimum_size = Vector2(SIDE_PANEL_WIDTH, 0)
	_side_panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	_side_panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	_side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_side_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	_side_vbox.add_theme_constant_override("separation", 10)
	_side_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = UITheme.BG

	UITheme.style_label(_title_lbl, UITheme.PURPLE_BRIGHT, 18, true)
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	UITheme.style_button(_back_btn, UITheme.MAGENTA)
	UITheme.style_button(_save_btn, UITheme.PURPLE_BRIGHT)
	_save_btn.custom_minimum_size = Vector2(180, 0)

	_status_lbl.add_theme_font_size_override("font_size", 13)
	_status_lbl.visible = false

	# Side panel background
	var sp_style: StyleBoxFlat = StyleBoxFlat.new()
	sp_style.bg_color           = UITheme.PANEL_BG
	sp_style.border_color       = UITheme.PURPLE_MID
	sp_style.border_width_left  = 1; sp_style.border_width_right  = 1
	sp_style.border_width_top   = 1; sp_style.border_width_bottom = 1
	sp_style.content_margin_left   = 14; sp_style.content_margin_right  = 14
	sp_style.content_margin_top    = 14; sp_style.content_margin_bottom = 14
	_side_panel.add_theme_stylebox_override("panel", sp_style)


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
	get_viewport().files_dropped.connect(_on_viewport_files_dropped)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.ctrl_pressed and k.keycode == KEY_S:
			if not _save_btn.disabled:
				_on_save_pressed()
			get_viewport().set_input_as_handled()


func _on_back_pressed() -> void:
	Transition.change_scene("res://scenes/main/Main.tscn")


func _on_viewport_files_dropped(files: PackedStringArray) -> void:
	# Multi-axis bulk drop: when a round is selected and multiple funscript files
	# are dropped at once, auto-route each one by its filename suffix rather than
	# requiring the user to drop them onto individual DropZones.
	# Single-file drops still fall through to the DropZone controls as before.
	if _selected_item.get("type", "") == "round" and _selected_idx >= 0:
		var fs_files: Array = []
		for f: String in files:
			if f.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS:
				fs_files.append(f)

		if fs_files.size() > 1:
			if not _selected_arr[_selected_idx].has("axis_scripts"):
				_selected_arr[_selected_idx]["axis_scripts"] = {}
			if not _selected_arr[_selected_idx].has("vib_scripts"):
				_selected_arr[_selected_idx]["vib_scripts"] = {}
			for f: String in fs_files:
				var vib_ch: String = _detect_vib_channel(f)
				if vib_ch != "":
					_selected_arr[_selected_idx]["vib_scripts"][vib_ch] = f
				else:
					var axis: String = _detect_funscript_axis(f)
					if axis == "L0":
						_selected_arr[_selected_idx]["funscript_path"] = f
						if (_selected_arr[_selected_idx].get("name", "") as String).strip_edges() == "":
							_selected_arr[_selected_idx]["name"] = f.get_file().get_basename()
					else:
						_selected_arr[_selected_idx]["axis_scripts"][axis] = f
			# Refresh the side panel so the new paths show up in the DropZones.
			_graph.call_deferred("select_item", _selected_arr, _selected_idx)
			return

	# No round selected (or single-file drop) — fall through to cover-image handling.
	# DropZone controls on the side panel handle single-file drops themselves.
	if not _selected_item.is_empty():
		return
	for f: String in files:
		if f.get_extension().to_lower() in JourneyData.IMAGE_EXTENSIONS:
			_cover_path = f
			_update_cover_preview()
			return


# Infers the T-code axis from a funscript filename. Checks T-code axis-code
# suffixes first (_L1, .L1) then human-readable names (_surge, .pitch, etc.).
# Returns "L0" if no axis marker is found (main stroke script).
func _detect_funscript_axis(path: String) -> String:
	var stem: String = path.get_file().get_basename().to_lower()
	# T-code axis code suffixes (underscore or dot separator).
	var axis_codes: Dictionary = {
		"_l1": "L1", ".l1": "L1",
		"_l2": "L2", ".l2": "L2",
		"_r0": "R0", ".r0": "R0",
		"_r1": "R1", ".r1": "R1",
		"_r2": "R2", ".r2": "R2",
	}
	for suffix: String in axis_codes:
		if stem.ends_with(suffix):
			return axis_codes[suffix]
	# Human-readable axis name suffixes used by common multi-axis script authors.
	var name_codes: Dictionary = {
		"_surge": "L1", ".surge": "L1",
		"_sway":  "L2", ".sway":  "L2",
		"_twist": "R0", ".twist": "R0",
		"_roll":  "R1", ".roll":  "R1",
		"_pitch": "R2", ".pitch": "R2",
	}
	for suffix: String in name_codes:
		if stem.ends_with(suffix):
			return name_codes[suffix]
	return "L0"


# Returns "vib1" or "vib2" when the filename carries a recognised vibrator-script
# suffix (.vib1, _vib1, .vibe1, _vibe1 → "vib1"; .vib2 variants → "vib2").
# Returns "" for any other filename (not a vib script).
func _detect_vib_channel(path: String) -> String:
	var stem: String = path.get_file().get_basename().to_lower()
	for s: String in [".vib1", "_vib1", ".vibe1", "_vibe1"]:
		if stem.ends_with(s):
			return "vib1"
	for s: String in [".vib2", "_vib2", ".vibe2", "_vibe2"]:
		if stem.ends_with(s):
			return "vib2"
	return ""


# ---------------------------------------------------------------------------
# Cover image
# ---------------------------------------------------------------------------

func _on_cover_pressed() -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.access    = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.filters   = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	dialog.title     = "Select Cover Image"
	add_child(dialog)
	dialog.popup_centered(Vector2i(900, 600))
	dialog.file_selected.connect(func(path: String) -> void:
		_cover_path = path
		_update_cover_preview()
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())


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
	if _selected_item.is_empty():
		_side_renderer.show_journey_info_panel()


# ---------------------------------------------------------------------------
# Load existing journey for editing
# ---------------------------------------------------------------------------

func _load_journey(journey: Dictionary) -> void:
	# Parse all data via JourneyData; copy fields into our member vars so the
	# existing UI handlers can continue to read/write them directly.
	var parsed: Dictionary = JourneyData.parse_journey(journey)
	_journey_name           = parsed["name"]
	_journey_author         = parsed["author"]
	_journey_desc           = parsed["description"]
	_journey_difficulty_idx = parsed["difficulty_idx"]
	_journey_tags           = (parsed.get("tags", []) as Array).duplicate()
	if (parsed["cover_path"] as String) != "":
		_cover_path = parsed["cover_path"]
		_update_cover_preview()
	# Mutate in place rather than replacing the reference — _setup_graph_view
	# has already done call_deferred("set_items", _items), which captures the
	# array reference. If we reassign _items here, that deferred call fires
	# after _load_journey with the stale (empty) reference and clears the graph.
	_items.clear()
	for item in parsed["items"]:
		_items.append(item)
	_refresh_items()


# ---------------------------------------------------------------------------
# Round list
# ---------------------------------------------------------------------------

func _refresh_items() -> void:
	# Now an alias for the graph-rebuild path. The function name is kept
	# because many internal handlers still call it after mutating _items.
	_refresh_graph()


# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------

func _show_status(msg: String, is_error: bool) -> void:
	_status_lbl.text = msg
	_status_lbl.add_theme_color_override("font_color", UITheme.ERROR_SOFT if is_error else UITheme.SUCCESS)
	_status_lbl.visible = true


func _on_save_pressed() -> void:
	# Top-level orchestrator. Each phase is a named helper returning a clear
	# success/failure signal so the flow reads as a sequence of steps rather
	# than 250 lines of nested branches. Helpers that fail are responsible for
	# their own user-facing error modal and any staging cleanup.
	_save_btn.disabled = true
	_reset_save_state()
	if not await _do_save():
		_save_btn.disabled = false


# Returns true on a fully successful save (which transitions the user away
# from the editor), false on any failure or cancellation. Each helper that
# returns false has already shown the user a specific error modal. Staging-
# folder cleanup is centralised here so the per-phase code stays focused on
# its own responsibility.
func _do_save() -> bool:
	if not _validate_presave():
		return false
	if not _build_transcode_plan():
		return false

	var paths: Dictionary = _setup_save_folders()
	var modal: Control    = _create_save_progress_modal_if_needed()

	var data: Dictionary = await _save_all_items(paths, modal)
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
	_finalize_save_success()
	return true


# Clears all in-flight save state so a previous failed save can't bleed into
# this one (stale _save_aborted flag, leftover error stash, round counter
# from a partial walk).
func _reset_save_state() -> void:
	_status_lbl.visible   = false
	_transcode_cancel     = false
	_save_aborted         = false
	_save_abort_error     = {}
	_round_folder_counter = 0


# Runs the whole-tree presave validation pass. Returns false (and shows the
# multi-issue modal) when any problems exist.
func _validate_presave() -> bool:
	var issues: Array = _collect_presave_issues()
	if issues.is_empty():
		return true
	var headline: String = "Found %d issue%s that prevent saving. Fix the items below and try again." % [
		issues.size(),
		"s" if issues.size() != 1 else "",
	]
	_show_save_error_modal("CANNOT SAVE JOURNEY", headline, issues)
	return false


# Populates _transcode_plan by walking every video source in the tree. Returns
# false (and shows the ffmpeg_missing modal) when ffmpeg is unavailable AND
# the tree contains videos that probably need transcoding (non-.mp4).
func _build_transcode_plan() -> bool:
	_transcode_plan = {}
	var any_video: bool = JourneyData.items_have_any_video(_items)
	var ffmpeg_ok: bool = _ffmpeg_available() if any_video else false

	var all_video_sources: Array = []
	_collect_video_sources(_items, all_video_sources)

	if ffmpeg_ok:
		# Probe every unique source. Same source dragged into multiple rounds
		# is identity-by-path so the transcode runs once and the result is
		# reused at both top-level and fork-path save sites.
		for src: String in all_video_sources:
			if _transcode_plan.has(src):
				continue
			var codec: String = _get_video_codec(src)
			if codec != "" and not (codec in H264_NAMES):
				_transcode_plan[src] = {"codec": codec, "duration": _video_duration_seconds(src)}
		return true

	# No ffprobe → can't verify codecs. Be conservative: any non-.mp4
	# extension is treated as "needs transcoding". .mp4 files are trusted to
	# be H.264 (the common case); a .mp4 with a non-H.264 codec will fail at
	# runtime but we have no way to detect that here.
	var non_mp4_sources: Array = []
	for src: String in all_video_sources:
		if src.get_extension().to_lower() != "mp4" and not (src in non_mp4_sources):
			non_mp4_sources.append(src)
	if non_mp4_sources.is_empty():
		return true
	_show_save_error_single(
		"CANNOT SAVE JOURNEY",
		CAUSE_FFMPEG_MISSING,
		"Journey",
		"%d video(s) use a non-.mp4 container that likely needs transcoding to H.264, but ffmpeg is not available." % non_mp4_sources.size(),
		"Install ffmpeg into the project's bin/ folder (or onto your system PATH) and restart the editor. Alternatively, transcode the offending video(s) to H.264 .mp4 outside the editor and re-drag them.")
	return false


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
	var journey_name: String      = _journey_name.strip_edges()
	var journeys_root: String     = SettingsService.get_journeys_dir()
	var folder_name: String       = JourneyData.sanitize_folder_name(journey_name)
	var final_journey_dir: String = journeys_root + "/" + folder_name
	var final_abs_dir: String     = ProjectSettings.globalize_path(final_journey_dir)

	# Stage to a sibling temp folder so a mid-save failure or user cancel can
	# roll back cleanly — the existing journey on disk is never touched until
	# the swap at the end. The dot prefix makes JourneyScanner skip leftover
	# staging folders if the app crashes before the swap.
	var staging_journey_dir: String = journeys_root + "/.~save_" + folder_name
	var abs_dir: String             = ProjectSettings.globalize_path(staging_journey_dir)
	if DirAccess.dir_exists_absolute(abs_dir):
		JourneyData.delete_dir_recursive(abs_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)

	# All images (cover + storyboard backgrounds + line images + fork path
	# illustrations) live in media/ so the journey root only holds journey.json
	# and per-round subdirectories.
	var abs_media_dir: String = abs_dir + "/media"
	DirAccess.make_dir_recursive_absolute(abs_media_dir)

	# Dedup map: source_path → dest_filename (relative to abs_media_dir).
	# Primed with the cover image when present so the same image dropped into
	# the cover slot AND a storyboard wouldn't get copied twice.
	var copied_images: Dictionary = {}
	if _cover_path != "":
		var ext: String = _cover_path.get_extension().to_lower()
		_copy_image_deduped(_cover_path, abs_media_dir, "cover." + ext, copied_images)

	return {
		"journey_name":        journey_name,
		"staging_journey_dir": staging_journey_dir,
		"abs_dir":             abs_dir,
		"abs_media_dir":       abs_media_dir,
		"final_abs_dir":       final_abs_dir,
		"copied_images":       copied_images,
	}


# Creates and parents the streaming progress modal IF the save will actually
# transfer video bytes. Returns null when there are no videos to save (no
# point in flashing a modal that immediately dismisses).
func _create_save_progress_modal_if_needed() -> Control:
	if not JourneyData.items_have_any_video(_items):
		return null
	var modal: Control = _create_transcode_modal()
	add_child(modal)
	return modal


# Walks _items, dispatching each to its per-type handler and accumulating the
# four output arrays (rounds, forks, shops, storyboards). Returns the
# journey.json data on success or an empty Dictionary on cancel/I-O failure;
# in the latter case the user-facing error modal is already shown and the
# staging folder is already cleaned up.
func _save_all_items(paths: Dictionary, modal: Control) -> Dictionary:
	# Pull the paths-dict entries into the locals the loop body already uses,
	# so the legacy code below doesn't have to be reflowed to dict access.
	var abs_dir: String       = paths["abs_dir"]
	var abs_media_dir: String = paths["abs_media_dir"]
	var copied_images: Dictionary = paths["copied_images"]

	var rounds_json:      Array = []
	var forks_json:       Array = []
	var shops_json:       Array = []
	var storyboards_json: Array = []
	var rorder: int = 0
	var last_rorder: int = 0
	var total_main_rounds: int = _items.filter(func(item: Dictionary) -> bool: return item.get("type","round") == "round").size()

	for i in _items.size():
		# Early bail: a previous iteration's _copy_file (funscript / axis /
		# vib / boss image / storyboard image) may have failed and set
		# _save_aborted. The error is surfaced after the loop.
		if _save_aborted:
			break
		var item: Dictionary = _items[i]
		var item_type: String = item.get("type","round")
		if item_type == "shop":
			shops_json.append({
				"AfterOrder":      last_rorder,
				"Title":           item.get("title",""),
				"Mode":            item.get("mode", "pool"),
				"Count":           item.get("count", 3),
				"Items":           item.get("items", []),
				"PriceMultiplier": item.get("price_multiplier", 1.0),
			})
			continue
		if item_type == "storyboard":
			rorder += 1
			last_rorder = rorder
			var sb_slug: String = "storyboard_%d" % rorder
			var sb_img_src: String = item.get("image", "")
			var sb_img_fname: String = ""
			if sb_img_src != "":
				var sb_ext: String = sb_img_src.get_extension().to_lower()
				var sb_f: String = _copy_image_deduped(sb_img_src, abs_media_dir, sb_slug + "." + sb_ext, copied_images)
				sb_img_fname = "media/" + sb_f if sb_f != "" else ""
			var sb_lines_json: Array = []
			for sb_li_idx in (item.get("lines", []) as Array).size():
				var sb_li: Dictionary = item["lines"][sb_li_idx]
				var li_img_src: String = sb_li.get("image", "")
				var li_img_fname: String = ""
				if li_img_src != "":
					var li_ext: String = li_img_src.get_extension().to_lower()
					var li_f: String = _copy_image_deduped(li_img_src, abs_media_dir, sb_slug + "_line_%d.%s" % [sb_li_idx, li_ext], copied_images)
					li_img_fname = "media/" + li_f if li_f != "" else ""
				sb_lines_json.append({
					"Speaker": sb_li.get("speaker", ""),
					"Text":    sb_li.get("text",    ""),
					"Image":   li_img_fname,
				})
			storyboards_json.append({
				"Order":        rorder,
				"CoinsAwarded": item.get("coins", 0) as int,
				"Image":        sb_img_fname,
				"Lines":        sb_lines_json,
			})
			continue
		if item_type == "round":
			rorder += 1
			last_rorder = rorder

			# Human-readable name kept in journey.json's "Name" for display.
			# Short slug (r001, r002, …) is the actual on-disk folder. This
			# bounds path length and prevents same-name fork rounds from
			# colliding into one folder.
			var round_name: String = (item.get("name","") as String).strip_edges()
			var round_slug: String = _next_round_folder_slug()
			var round_dir: String  = abs_dir + "/" + round_slug
			DirAccess.make_dir_recursive_absolute(round_dir)

			var fs_src: String = item.get("funscript_path","")
			var fs_dst_name: String = "script." + fs_src.get_extension()
			_copy_file(fs_src, round_dir + "/" + fs_dst_name)
			var fs_stats: Dictionary = JourneyData.read_funscript_stats(round_dir + "/" + fs_dst_name)

			# Copy secondary-axis scripts and collect relative paths for the JSON.
			var axis_scripts_in: Dictionary = item.get("axis_scripts", {})
			var axis_scripts_rel: Dictionary = {}
			for axis: String in axis_scripts_in:
				var ax_src: String = axis_scripts_in[axis]
				if ax_src == "":
					continue
				var ax_dst_name: String = "axis_" + axis + "." + ax_src.get_extension()
				_copy_file(ax_src, round_dir + "/" + ax_dst_name)
				axis_scripts_rel[axis] = round_slug + "/" + ax_dst_name

			# Copy vibrator-channel scripts and collect relative paths for the JSON.
			var vib_scripts_in: Dictionary = item.get("vib_scripts", {})
			var vib_scripts_rel: Dictionary = {}
			for ch_key: String in vib_scripts_in:
				var vib_src: String = vib_scripts_in[ch_key]
				if vib_src == "":
					continue
				var vib_dst_name: String = "vib_" + ch_key + "." + vib_src.get_extension()
				_copy_file(vib_src, round_dir + "/" + vib_dst_name)
				vib_scripts_rel[ch_key] = round_slug + "/" + vib_dst_name

			# Boss-round config — copy the optional intro image into the round folder.
			var round_type: String = item.get("round_type", "normal")
			var boss_image_rel: String = ""
			if round_type == "boss":
				var boss_src: String = item.get("boss_image", "")
				if boss_src != "":
					var boss_dst_name: String = "boss." + boss_src.get_extension()
					_copy_file(boss_src, round_dir + "/" + boss_dst_name)
					boss_image_rel = round_slug + "/" + boss_dst_name

			var vid_src: String = item.get("video_path","")
			if vid_src != "":
				if _transcode_plan.has(vid_src):
					var info: Dictionary = _transcode_plan[vid_src]
					# Fixed short name regardless of the source — transcoded videos
					# are always h264 .mp4, and the original filename is irrelevant
					# (the round is addressed by folder slug).
					var vid_dst_name: String = "video.mp4"
					var vid_dst: String      = round_dir + "/" + vid_dst_name
					_update_modal_round(modal, rorder, total_main_rounds, round_name, info["codec"])
					var ok: bool = await _transcode_video(vid_src, vid_dst, info["duration"], modal)
					if not ok:
						# _transcode_cancel distinguishes user cancel from ffmpeg
						# failure (e.g. bad input file). Same return-value path,
						# different remediation. Modal + staging cleanup happen
						# in _do_save when we return {}.
						if _transcode_cancel:
							_show_save_error_single(
								"SAVE CANCELLED",
								CAUSE_CANCELLED,
								"Round %d \"%s\"" % [rorder, round_name],
								"You cancelled the transcode while round \"%s\" was being processed." % round_name,
								"Press Save again to retry. Nothing on disk was changed.")
						else:
							_show_save_error_single(
								"SAVE FAILED",
								CAUSE_TRANSCODE_FAILED,
								"Round %d \"%s\"" % [rorder, round_name],
								"ffmpeg failed to transcode video \"%s\" (codec %s → h264)." % [vid_src.get_file(), info["codec"]],
								"The source video may be corrupt or use an unsupported variant. Try re-encoding it to H.264 .mp4 outside the editor, then re-drag it into this round.")
						return {}
				else:
					# Short standard filename keyed off the source extension.
					var vid_dst_name: String = "video." + vid_src.get_extension()
					var vid_dst_path: String = round_dir + "/" + vid_dst_name
					# Source-equals-destination guard is now impossible (staging
					# writes to a fresh sibling folder) but harmless to keep as
					# defense-in-depth.
					var vid_src_abs: String = ProjectSettings.globalize_path(vid_src)
					if vid_src_abs != vid_dst_path:
						_update_modal_label(modal, "Round %d / %d — %s  (copying video)" % [rorder, total_main_rounds, round_name])
						var copy_result: Dictionary = await _copy_file_chunked(
							vid_src, vid_dst_path,
							func(done: int, tot: int) -> void: _update_modal_copy(modal, done, tot))
						if not copy_result["ok"]:
							_show_copy_failure_modal(copy_result, "Round %d \"%s\"" % [rorder, round_name])
							return {}

			# (Renamed-round cleanup happens implicitly at swap time: the old
			# journey folder is deleted wholesale, taking any stale round
			# subfolders with it. Touching the live folder mid-save would break
			# the staging rollback on a later failure.)

			rounds_json.append({
				"Name":           round_name,
				"FolderName":     round_slug,
				"Order":          rorder,
				"CoinsAwarded":   item.get("coins",0) as int,
				"RoundType":      "Boss" if round_type == "boss" else "Normal",
				"BossImage":      boss_image_rel,
				"BossTagline":    item.get("boss_tagline", ""),
				"BossModifiers":  _boss_modifiers_json(item.get("boss_modifiers", [])),
				"FunscriptPath":  round_slug + "/" + fs_dst_name,
				"AxisScripts":    axis_scripts_rel,
				"VibScripts":     vib_scripts_rel,
				"ActionCount":    fs_stats["count"],
				"LengthMs":       fs_stats["length_ms"],
			})
		else:
			# Fork — recursively save the fork and all nested forks.
			var slug_prefix: String = "fork%d" % forks_json.size()
			forks_json.append(await _save_fork(item, abs_dir, abs_media_dir, last_rorder, slug_prefix, copied_images, modal))
			# A failed video copy deep inside a fork path unwinds to here. Use
			# the stashed failure info so the modal shows the actual cause
			# (cancel vs source unreadable vs destination unwritable) and the
			# specific fork-path round that failed.
			if _save_aborted:
				var stashed_result: Dictionary = _save_abort_error.get("result", {"reason": CAUSE_UNKNOWN_COPY_ERROR})
				var stashed_item: String       = _save_abort_error.get("item",   "Fork path video")
				_show_copy_failure_modal(stashed_result, stashed_item)
				return {}

	# Catches _save_aborted set by a non-video _copy_file (funscript / axis /
	# vib / boss / storyboard image) during top-level iteration. Fork-path
	# failures already returned via the inline `if _save_aborted:` block above.
	if _save_aborted:
		var stashed_result: Dictionary = _save_abort_error.get("result", {"reason": CAUSE_UNKNOWN_COPY_ERROR})
		var stashed_item: String       = _save_abort_error.get("item",   "File copy")
		_show_copy_failure_modal(stashed_result, stashed_item)
		return {}

	return {
		"Name":        paths["journey_name"],
		"Author":      _journey_author.strip_edges(),
		"Description": _journey_desc.strip_edges(),
		"Difficulty":  JourneyData.DIFFICULTIES[_journey_difficulty_idx],
		"Tags":        TagRegistry.sanitize(_journey_tags),
		"Rounds":      rounds_json,
		"Forks":       forks_json,
		"Shops":       shops_json,
		"Storyboards": storyboards_json,
	}


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
			"Check that the journeys folder drive isn't full or write-protected, and that no antivirus is blocking the editor. You can change the journeys folder in Options → Storage Location.")
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
	var abs_dir: String       = paths["abs_dir"]
	var final_abs_dir: String = paths["final_abs_dir"]
	if DirAccess.dir_exists_absolute(final_abs_dir):
		JourneyData.delete_dir_recursive(final_abs_dir)
	if _original_journey_folder != "":
		var old_abs: String = ProjectSettings.globalize_path(_original_journey_folder)
		if old_abs != final_abs_dir and DirAccess.dir_exists_absolute(old_abs):
			JourneyData.delete_dir_recursive(old_abs)
	DirAccess.rename_absolute(abs_dir, final_abs_dir)


# Final UX after a clean save: brief success message, then transition back
# to the journey catalogue. The 1.5s delay gives the user a moment to see
# the confirmation before the scene changes.
func _finalize_save_success() -> void:
	_show_status("Journey saved! Returning to catalogue...", false)
	await get_tree().create_timer(1.5).timeout
	Transition.change_scene("res://scenes/journey_select/JourneySelect.tscn")


# Recursively serializes a fork item to JSON. Calls _save_path for each path.
# `slug_prefix` makes nested-storyboard filenames unique across the journey.
func _save_fork(fork_item: Dictionary, abs_dir: String, abs_media_dir: String, after_order: int, slug_prefix: String, copied_images: Dictionary, modal: Control) -> Dictionary:
	var fork_entry: Dictionary = {
		"AfterOrder":  after_order,
		"Title":       fork_item.get("title",""),
		"Description": fork_item.get("description",""),
		"Paths":       [],
	}
	for pi in (fork_item.get("paths", []) as Array).size():
		var path_data: Dictionary = fork_item["paths"][pi]
		var path_slug: String = "%s_p%d" % [slug_prefix, pi]
		fork_entry["Paths"].append(await _save_path(path_data, abs_dir, abs_media_dir, path_slug, copied_images, modal))
		if _save_aborted:
			return fork_entry
	return fork_entry


# Recursively serializes a single fork path to JSON, splitting its items into
# Rounds, Shops, Storyboards, and (nested) Forks arrays.
func _save_path(path_data: Dictionary, abs_dir: String, abs_media_dir: String, slug_prefix: String, copied_images: Dictionary, modal: Control) -> Dictionary:
	var img_src: String  = path_data.get("image_path", "")
	var img_fname: String = ""
	if img_src != "":
		# Use slug_prefix ("fork0_p0", "fork0_p1_f0_p0", …) for the filename so
		# two paths sharing a name (e.g. "Yes" / "No" branches across multiple
		# nested forks) can't overwrite each other's card image. The human-
		# readable Name lives in journey.json's Image field via the resolved
		# media/<slug>_cover.<ext> path, but the filename itself is collision-
		# free regardless of what the user calls each path.
		var img_f: String = _copy_image_deduped(img_src, abs_media_dir, slug_prefix + "_cover." + img_src.get_extension().to_lower(), copied_images)
		img_fname = "media/" + img_f if img_f != "" else ""

	var path_entry: Dictionary = {
		"Name":        path_data.get("name", ""),
		"Description": path_data.get("description", ""),
		"Image":       img_fname,
		"Rounds":      [],
		"Shops":       [],
		"Storyboards": [],
		"Forks":       [],
	}

	var pr_order: int = 0
	var pr_last_order: int = 0
	var nested_fork_count: int = 0

	for pi_item: Dictionary in path_data.get("items", []):
		var pi_type: String = pi_item.get("type","round")
		match pi_type:
			"shop":
				path_entry["Shops"].append({
					"AfterOrder":      pr_last_order,
					"Title":           pi_item.get("title",""),
					"Mode":            pi_item.get("mode", "pool"),
					"Count":           pi_item.get("count", 3),
					"Items":           pi_item.get("items", []),
					"PriceMultiplier": pi_item.get("price_multiplier", 1.0),
				})
			"storyboard":
				pr_order += 1
				pr_last_order = pr_order
				var psb_slug: String = "%s_storyboard_%d" % [slug_prefix, pr_order]
				var psb_img_src: String = pi_item.get("image", "")
				var psb_img_fname: String = ""
				if psb_img_src != "":
					var psb_ext: String = psb_img_src.get_extension().to_lower()
					var psb_f: String = _copy_image_deduped(psb_img_src, abs_media_dir, psb_slug + "." + psb_ext, copied_images)
					psb_img_fname = "media/" + psb_f if psb_f != "" else ""
				var psb_lines_json: Array = []
				for psb_li_idx in (pi_item.get("lines",[]) as Array).size():
					var psb_li: Dictionary = pi_item["lines"][psb_li_idx]
					var psb_li_img_src: String = psb_li.get("image","")
					var psb_li_img_fname: String = ""
					if psb_li_img_src != "":
						var psb_li_ext: String = psb_li_img_src.get_extension().to_lower()
						var psb_li_f: String = _copy_image_deduped(psb_li_img_src, abs_media_dir, psb_slug + "_line_%d.%s" % [psb_li_idx, psb_li_ext], copied_images)
						psb_li_img_fname = "media/" + psb_li_f if psb_li_f != "" else ""
					psb_lines_json.append({
						"Speaker": psb_li.get("speaker",""),
						"Text":    psb_li.get("text",""),
						"Image":   psb_li_img_fname,
					})
				path_entry["Storyboards"].append({
					"Order":        pr_order,
					"CoinsAwarded": pi_item.get("coins",0) as int,
					"Image":        psb_img_fname,
					"Lines":        psb_lines_json,
				})
			"fork":
				# Nested fork — recurse. Sort key uses pr_last_order so it lands
				# after the last round/storyboard authored before it in this path.
				var nested_slug: String = "%s_f%d" % [slug_prefix, nested_fork_count]
				nested_fork_count += 1
				path_entry["Forks"].append(await _save_fork(pi_item, abs_dir, abs_media_dir, pr_last_order, nested_slug, copied_images, modal))
				if _save_aborted:
					return path_entry
			_:
				# Round (inside a fork path). Same scheme as top-level rounds:
				# short slug for the folder, short standard filenames inside,
				# human-readable name kept only in journey.json.
				pr_order += 1
				pr_last_order = pr_order
				var pr_name: String = (pi_item.get("name","") as String).strip_edges()
				var pr_slug: String = _next_round_folder_slug()
				var pr_dir: String  = abs_dir + "/" + pr_slug
				DirAccess.make_dir_recursive_absolute(pr_dir)
				var pr_fs: String = pi_item.get("funscript_path","")
				var pr_fs_dst_name: String = ""
				var pr_fs_stats: Dictionary = {"count": 0, "length_ms": 0}
				if pr_fs != "":
					pr_fs_dst_name = "script." + pr_fs.get_extension()
					_copy_file(pr_fs, pr_dir + "/" + pr_fs_dst_name)
					pr_fs_stats = JourneyData.read_funscript_stats(pr_dir + "/" + pr_fs_dst_name)
				var pr_vid: String = pi_item.get("video_path","")
				if pr_vid != "":
					# Fork-path videos go through the same transcode-or-copy fork as
					# top-level rounds. The plan (_transcode_plan) is built from a
					# tree-wide walk in _on_save_pressed and keyed by source path so
					# this lookup works the same regardless of nesting depth.
					if _transcode_plan.has(pr_vid):
						var pr_info: Dictionary = _transcode_plan[pr_vid]
						var pr_vid_dst_path: String = pr_dir + "/video.mp4"
						_update_modal_label(modal, "Fork round — %s  (transcoding %s → h264)" % [pr_name, pr_info["codec"]])
						var pr_transcode_ok: bool = await _transcode_video(pr_vid, pr_vid_dst_path, pr_info["duration"], modal)
						if not pr_transcode_ok:
							_save_aborted = true
							_save_abort_error = {
								"result": {"ok": false, "reason": (CAUSE_CANCELLED if _transcode_cancel else CAUSE_TRANSCODE_FAILED), "detail": pr_vid},
								"item":   "%s → Round \"%s\"" % [slug_prefix, pr_name],
							}
							return path_entry
					else:
						var pr_vid_dst_name: String = "video." + pr_vid.get_extension()
						var pr_vid_dst_path: String = pr_dir + "/" + pr_vid_dst_name
						# Same src==dst guard as the top-level round copy: skip when the
						# video is already at its destination to avoid a 0 KB truncation.
						var pr_vid_src_abs: String = ProjectSettings.globalize_path(pr_vid)
						if pr_vid_src_abs != pr_vid_dst_path:
							_update_modal_label(modal, "Fork round — %s  (copying video)" % pr_name)
							var pr_copy_result: Dictionary = await _copy_file_chunked(
								pr_vid, pr_vid_dst_path,
								func(done: int, tot: int) -> void: _update_modal_copy(modal, done, tot))
							if not pr_copy_result["ok"]:
								# Cancelled / failed — unwind the recursive save and stash
								# the detailed failure so the top-level handler can show
								# a specific error instead of a generic message.
								_save_aborted = true
								_save_abort_error = {
								"result": pr_copy_result,
								"item":   "%s → Round \"%s\"" % [slug_prefix, pr_name],
								}
								return path_entry
				var pr_axis_in: Dictionary = pi_item.get("axis_scripts", {})
				var pr_axis_rel: Dictionary = {}
				for axis: String in pr_axis_in:
					var ax_src: String = pr_axis_in[axis]
					if ax_src == "":
						continue
					var ax_dst_name: String = "axis_" + axis + "." + ax_src.get_extension()
					_copy_file(ax_src, pr_dir + "/" + ax_dst_name)
					pr_axis_rel[axis] = pr_slug + "/" + ax_dst_name
				var pr_vib_in: Dictionary = pi_item.get("vib_scripts", {})
				var pr_vib_rel: Dictionary = {}
				for ch_key: String in pr_vib_in:
					var vib_src: String = pr_vib_in[ch_key]
					if vib_src == "":
						continue
					var vib_dst_name: String = "vib_" + ch_key + "." + vib_src.get_extension()
					_copy_file(vib_src, pr_dir + "/" + vib_dst_name)
					pr_vib_rel[ch_key] = pr_slug + "/" + vib_dst_name
				var pr_round_type: String = pi_item.get("round_type", "normal")
				var pr_boss_image_rel: String = ""
				if pr_round_type == "boss":
					var pr_boss_src: String = pi_item.get("boss_image", "")
					if pr_boss_src != "":
						var pr_boss_dst_name: String = "boss." + pr_boss_src.get_extension()
						_copy_file(pr_boss_src, pr_dir + "/" + pr_boss_dst_name)
						pr_boss_image_rel = pr_slug + "/" + pr_boss_dst_name
				# (Renamed-round cleanup is implicit at swap time — see the
				# top-level round save above. Deleting the live original mid-
				# save would break the staging rollback if a later step fails.)
				path_entry["Rounds"].append({
					"Name":          pr_name,
					"FolderName":    pr_slug,
					"Order":         pr_order,
					"CoinsAwarded":  pi_item.get("coins",0) as int,
					"RoundType":     "Boss" if pr_round_type == "boss" else "Normal",
					"BossImage":     pr_boss_image_rel,
					"BossTagline":   pi_item.get("boss_tagline", ""),
					"BossModifiers": _boss_modifiers_json(pi_item.get("boss_modifiers", [])),
					"FunscriptPath": pr_slug + "/" + pr_fs_dst_name if pr_fs_dst_name != "" else "",
					"AxisScripts":   pr_axis_rel,
					"VibScripts":    pr_vib_rel,
					"ActionCount":   pr_fs_stats["count"],
					"LengthMs":      pr_fs_stats["length_ms"],
				})

	return path_entry


# ---------------------------------------------------------------------------
# Transcoding
# ---------------------------------------------------------------------------

# Recursively walks the journey items tree and appends every non-empty
# video_path it finds (top-level rounds + every round in every fork path at
# every depth) into `sources`. Duplicates may appear if the same source video
# is used in multiple rounds; callers dedupe by checking has() on the plan
# dictionary before probing the codec a second time.
func _collect_video_sources(items: Array, sources: Array) -> void:
	for item: Dictionary in items:
		var item_type: String = item.get("type", "round")
		match item_type:
			"round":
				var vid: String = item.get("video_path", "")
				if vid != "":
					sources.append(vid)
			"fork":
				for p: Dictionary in item.get("paths", []):
					_collect_video_sources(p.get("items", []) as Array, sources)


func _ffmpeg_binary(name: String) -> String:
	var exe: String = name + ".exe" if OS.get_name() == "Windows" else name

	if OS.has_feature("editor"):
		# Editor: res://bin/ is a real filesystem directory — execute directly.
		var bundled: String = ProjectSettings.globalize_path("res://bin/" + exe)
		if FileAccess.file_exists(bundled):
			return bundled
	else:
		# Exported build: res://bin/ is inside the PCK and cannot be executed
		# directly. Extract to user://bin/ on first use, then run from there.
		var user_abs: String = ProjectSettings.globalize_path("user://bin/" + exe)
		if not FileAccess.file_exists(user_abs):
			_extract_ffmpeg_binary("res://bin/" + exe, user_abs)
		if FileAccess.file_exists(user_abs):
			return user_abs
		# Fallback: bin/ folder placed alongside the exported executable.
		var next_to_app: String = OS.get_executable_path().get_base_dir() + "/bin/" + exe
		if FileAccess.file_exists(next_to_app):
			return next_to_app

	return name  # last resort: PATH lookup


# Copies a binary from the PCK (res://) to an absolute filesystem path so it
# can be executed. Called once per binary per user data directory.
func _extract_ffmpeg_binary(src_res: String, dst_abs: String) -> void:
	if not FileAccess.file_exists(src_res):
		return
	DirAccess.make_dir_recursive_absolute(dst_abs.get_base_dir())
	var f_in: FileAccess = FileAccess.open(src_res, FileAccess.READ)
	if f_in == null:
		return
	var bytes: PackedByteArray = f_in.get_buffer(f_in.get_length())
	f_in.close()
	var f_out: FileAccess = FileAccess.open(dst_abs, FileAccess.WRITE)
	if f_out == null:
		return
	f_out.store_buffer(bytes)
	f_out.close()
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", dst_abs], [], true)


func _ffmpeg_available() -> bool:
	var out: Array = []
	return OS.execute(_ffmpeg_binary("ffprobe"), ["-version"], out, true, false) == 0


func _get_video_codec(path: String) -> String:
	var out: Array = []
	var args: PackedStringArray = [
		"-v", "error",
		"-select_streams", "v:0",
		"-show_entries", "stream=codec_name",
		"-of", "csv=p=0",
		ProjectSettings.globalize_path(path),
	]
	if OS.execute(_ffmpeg_binary("ffprobe"), args, out, true, false) != 0 or out.is_empty():
		return ""
	# out[0] may contain multiple lines (stderr is merged in with read_stderr=true,
	# and some ffprobe versions emit extra lines). Take only the first non-empty
	# line so "h264\n..." doesn't fail the H264_NAMES membership check.
	for raw_line: String in (out[0] as String).split("\n"):
		var line: String = raw_line.strip_edges().to_lower()
		if line != "":
			return line
	return ""


func _video_duration_seconds(path: String) -> float:
	var out: Array = []
	var args: PackedStringArray = [
		"-v", "error",
		"-show_entries", "format=duration",
		"-of", "csv=p=0",
		ProjectSettings.globalize_path(path),
	]
	if OS.execute(_ffmpeg_binary("ffprobe"), args, out, true, false) != 0 or out.is_empty():
		return 0.0
	return (out[0] as String).strip_edges().to_float()


func _transcode_video(input: String, output: String, duration: float, modal: Control) -> bool:
	_transcode_cancel = false

	var progress_abs: String = ProjectSettings.globalize_path(TRANSCODE_PROGRESS_FILE)
	# Truncate any prior progress file so old data doesn't mislead the parser.
	var pf: FileAccess = FileAccess.open(progress_abs, FileAccess.WRITE)
	if pf:
		pf.close()

	var args: PackedStringArray = [
		"-y",
		"-hide_banner",
		"-loglevel", "error",
		"-i", ProjectSettings.globalize_path(input),
		"-c:v", "libx264",
		"-preset", "fast",
		"-crf", "22",
		"-pix_fmt", "yuv420p",
		"-c:a", "aac",
		"-b:a", "192k",
		"-progress", progress_abs,
		ProjectSettings.globalize_path(output),
	]

	_transcode_pid = OS.create_process(_ffmpeg_binary("ffmpeg"), args)
	if _transcode_pid <= 0:
		return false

	while OS.is_process_running(_transcode_pid):
		if _transcode_cancel:
			OS.kill(_transcode_pid)
			_transcode_pid = -1
			return false
		_poll_progress(progress_abs, duration, modal)
		await get_tree().create_timer(0.4).timeout

	# Final poll to flush "progress=end".
	_poll_progress(progress_abs, duration, modal)
	_transcode_pid = -1
	return FileAccess.file_exists(output)


func _poll_progress(progress_path: String, duration: float, modal: Control) -> void:
	if modal == null:
		return
	var f: FileAccess = FileAccess.open(progress_path, FileAccess.READ)
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	var out_time_us: int = 0
	var speed: String = ""
	for raw_line: String in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("out_time_us="):
			out_time_us = line.substr(12).to_int()
		elif line.begins_with("out_time_ms="):
			out_time_us = line.substr(12).to_int()
		elif line.begins_with("speed="):
			speed = line.substr(6)
	var current_seconds: float = out_time_us / 1_000_000.0
	var progress: float = 0.0
	if duration > 0.0:
		progress = clampf(current_seconds / duration, 0.0, 1.0)
	_update_modal_progress(modal, progress, current_seconds, duration, speed)


# ---------------------------------------------------------------------------
# Transcode modal UI
# ---------------------------------------------------------------------------

func _create_transcode_modal() -> Control:
	var parts: Dictionary    = UITheme.build_centered_modal("SAVING JOURNEY", UITheme.PURPLE_BRIGHT, Vector2i(520, 240))
	var modal: Control       = parts["modal"]
	var vbox:  VBoxContainer = parts["vbox"]
	modal.name           = "TranscodeModal"
	parts["title"].name  = "Title"
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


func _update_modal_round(modal: Control, round_num: int, total: int, round_name: String, codec: String) -> void:
	if modal == null:
		return
	var lbl: Label = modal.get_node("PanelContainer/VBoxContainer/RoundLabel") as Label
	if lbl == null:
		# Fallback: walk children since we didn't name the intermediate panel/vbox.
		lbl = modal.find_child("RoundLabel", true, false) as Label
	if lbl:
		lbl.text = "Round %d / %d — %s  (%s → h264)" % [round_num, total, round_name, codec.to_upper()]


func _update_modal_progress(modal: Control, progress: float, current_s: float, total_s: float, speed: String) -> void:
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


# Sets the modal's secondary label to a plain message (no codec suffix).
func _update_modal_label(modal: Control, text: String) -> void:
	if modal == null:
		return
	var lbl: Label = modal.find_child("RoundLabel", true, false) as Label
	if lbl:
		lbl.text = text


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
		status.text = "Copying… %d%%  (%s / %s)" % [
			int(round(frac * 100.0)), _format_size(copied), _format_size(total)]


func _format_size(bytes: int) -> String:
	var mb: float = bytes / (1024.0 * 1024.0)
	if mb >= 1024.0:
		return "%.1f GB" % (mb / 1024.0)
	return "%.0f MB" % mb


# Returns the destination filename (relative to abs_dir) for an image. If the
# same source path was already copied during this save, reuses the existing
# destination file rather than copying again. `copied` maps src_path → fname.
func _copy_image_deduped(src: String, abs_dir: String, candidate_fname: String, copied: Dictionary) -> String:
	if src == "":
		return ""
	if copied.has(src):
		return copied[src]
	_copy_file(src, abs_dir + "/" + candidate_fname)
	copied[src] = candidate_fname
	return candidate_fname


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
			"item":   "File copy",
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
			"item":   "File copy",
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
		if not da.current_is_dir() \
				and fname.get_extension().to_lower() in extensions \
				and fname != keep_filename:
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
		if not da.current_is_dir() and fname != keep_filename \
				and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS:
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
		if not da.current_is_dir() and fname != keep_filename \
				and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS \
				and fname.get_basename().ends_with("_" + axis):
			to_delete.append(dir_path + "/" + fname)
		fname = da.get_next()
	da.list_dir_end()
	for p: String in to_delete:
		DirAccess.remove_absolute(p)


# Converts the internal boss-modifier model ({kind, factor, min, max}) into the
# PascalCase form written to journey.json, keeping only the keys each kind uses.
func _boss_modifiers_json(modifiers: Array) -> Array:
	var out: Array = []
	for mod in modifiers:
		if not mod is Dictionary:
			continue
		var entry: Dictionary = {"Kind": mod.get("kind", "")}
		if mod.has("factor"):
			entry["Factor"] = mod["factor"]
		if mod.has("min"):
			entry["Min"] = mod["min"]
		if mod.has("max"):
			entry["Max"] = mod["max"]
		out.append(entry)
	return out


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
		if not da.current_is_dir() and fname != keep_filename \
				and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS \
				and fname.get_basename().ends_with("_" + ch_key):
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


# Recursively walks an items[] tree (top-level + every fork path at every
# nesting depth) and returns true if any round exists anywhere. Used by the
# journey-level "needs at least one round somewhere" check so authors can
# gate their gameplay behind a fork (e.g. "Cutscene → Choose difficulty fork
# → each path has its own boss") and still pass validation.
func _has_any_round_in_tree(items: Array) -> bool:
	for item: Dictionary in items:
		var item_type: String = item.get("type", "round")
		if item_type == "round":
			return true
		if item_type == "fork":
			for p: Dictionary in item.get("paths", []):
				if _has_any_round_in_tree(p.get("items", []) as Array):
					return true
	return false


# Walks the entire journey tree (top-level + every fork path recursively) and
# returns an Array of SaveError dicts for all problems found. An empty array
# means the journey is safe to save.
func _collect_presave_issues() -> Array:
	var issues: Array = []

	# Journey-level checks.
	var jn: String = _journey_name.strip_edges()
	if jn == "":
		issues.append({
			"cause":  CAUSE_BAD_NAME,
			"item":   "Journey",
			"detail": "Journey name is required.",
			"hint":   "Enter a name in the Journey Info panel (right-side, no node selected).",
		})
	else:
		# Rename-collision guard. If the sanitized name maps to a folder that
		# already exists AND it's not the journey we're editing, the swap at
		# the end of save would wipe that other journey's data. Refuse here.
		var sanitized_jn: String      = JourneyData.sanitize_folder_name(jn)
		var target_journey_dir: String = SettingsService.get_journeys_dir() + "/" + sanitized_jn
		var target_abs: String        = ProjectSettings.globalize_path(target_journey_dir)
		var original_abs: String      = ""
		if _original_journey_folder != "":
			original_abs = ProjectSettings.globalize_path(_original_journey_folder)
		if target_abs != original_abs and DirAccess.dir_exists_absolute(target_abs):
			issues.append({
				"cause":  CAUSE_NAME_COLLISION,
				"item":   "Journey",
				"detail": "A journey already exists at: %s" % target_abs,
				"hint":   "Saving with this name would replace that other journey. Pick a different name, or delete the existing journey from the catalogue first.",
			})
	if _cover_path != "" and not _save_source_exists(_cover_path):
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   "Journey cover image",
			"detail": "Cover image no longer exists at: %s" % _cover_path,
			"hint":   "Re-drag the cover image into the Journey Info panel, or remove it.",
		})

	# "Journey" is loosely defined as "has gameplay somewhere." A round inside
	# a fork path still counts — e.g. a cutscene-intro storyboard followed by
	# a "choose your difficulty" fork whose paths all contain rounds. Only
	# truly round-less journeys (slideshows of storyboards / shops) are blocked.
	if not _has_any_round_in_tree(_items):
		issues.append({
			"cause":  CAUSE_NO_ROUNDS,
			"item":   "Journey",
			"detail": "A journey needs at least one round somewhere — top-level or inside any fork path.",
			"hint":   "Add a round from the side panel, or add a round inside one of your fork paths.",
		})

	_save_collect_items_issues(_items, "Top level", issues)
	return issues


# Recursively scans an items[] array (used at both top level and inside fork
# paths). `context` is a human-readable trail like
# 'Fork 1 → Path "Adventure"' so issue messages can pinpoint the location.
func _save_collect_items_issues(items: Array, context: String, issues: Array) -> void:
	var round_num: int = 0
	var sb_num:    int = 0
	var fork_num:  int = 0
	for item: Dictionary in items:
		var item_type: String = item.get("type", "round")
		match item_type:
			"round":
				round_num += 1
				_save_check_round(item, "%s, Round %d" % [context, round_num], issues)
			"storyboard":
				sb_num += 1
				_save_check_storyboard(item, "%s, Storyboard %d" % [context, sb_num], issues)
			"fork":
				fork_num += 1
				_save_check_fork(item, "%s, Fork %d" % [context, fork_num], issues)
			"shop":
				# Shops write no filesystem paths and have no source files.
				pass


func _save_check_round(round_data: Dictionary, ctx: String, issues: Array) -> void:
	var name: String = (round_data.get("name", "") as String).strip_edges()
	var label: String = "%s \"%s\"" % [ctx, name] if name != "" else ctx

	# Names are display-only now (see short-folder slug scheme). Any character
	# is fine — only empty names need to be flagged, since the name is the
	# user's identifier for the round in journey.json and the editor.
	if name == "":
		issues.append({
			"cause":  CAUSE_BAD_NAME,
			"item":   ctx,
			"detail": "Round name is empty.",
			"hint":   "Give the round a name in the side-panel editor.",
		})

	# Required: funscript.
	var fs: String = round_data.get("funscript_path", "")
	if fs == "":
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   label,
			"detail": "No funscript file selected.",
			"hint":   "Drag a .funscript or .json file into the Funscript field for this round.",
		})
	elif not _save_source_exists(fs):
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   label,
			"detail": "Funscript file no longer exists at: %s" % fs,
			"hint":   "The source file may have been moved or deleted. Re-drag it into the editor.",
		})

	# Optional: video.
	var vid: String = round_data.get("video_path", "")
	if vid != "" and not _save_source_exists(vid):
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   label,
			"detail": "Video file no longer exists at: %s" % vid,
			"hint":   "The source file may have been moved or deleted. Re-drag it into the editor or remove the video.",
		})

	# Secondary axis scripts.
	var axis_scripts: Dictionary = round_data.get("axis_scripts", {})
	for axis: String in axis_scripts:
		var p: String = axis_scripts[axis]
		if p != "" and not _save_source_exists(p):
			issues.append({
				"cause":  CAUSE_MISSING_SOURCE,
				"item":   label,
				"detail": "%s axis funscript no longer exists at: %s" % [axis, p],
				"hint":   "Re-drag the %s funscript in the Extra Axes section." % axis,
			})

	# Vibrator-channel scripts.
	var vib_scripts: Dictionary = round_data.get("vib_scripts", {})
	for ch_key: String in vib_scripts:
		var p: String = vib_scripts[ch_key]
		if p != "" and not _save_source_exists(p):
			issues.append({
				"cause":  CAUSE_MISSING_SOURCE,
				"item":   label,
				"detail": "%s vibrator funscript no longer exists at: %s" % [ch_key, p],
				"hint":   "Re-drag the %s funscript in the Vibrator Scripts section." % ch_key,
			})

	# Boss intro image.
	var boss_image: String = round_data.get("boss_image", "")
	if boss_image != "" and not _save_source_exists(boss_image):
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   label,
			"detail": "Boss intro image no longer exists at: %s" % boss_image,
			"hint":   "Re-drag the boss image in the Boss Round section, or disable boss mode.",
		})

	# (Path-length check used to live here. Removed once round folder names
	# became fixed-length slugs — a round folder is always exactly 4 chars
	# (`rNNN`) and the longest filename inside is `axis_<XY>.funscript` (~22
	# chars), so the only path-length lever left is the journey name itself,
	# which would need to be hundreds of characters to come close to MAX_PATH.)


func _save_check_storyboard(sb_data: Dictionary, ctx: String, issues: Array) -> void:
	var default_img: String = sb_data.get("image", "")
	if default_img != "" and not _save_source_exists(default_img):
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   ctx,
			"detail": "Default image no longer exists at: %s" % default_img,
			"hint":   "Re-drag the default image into the storyboard, or remove it.",
		})
	var lines: Array = sb_data.get("lines", [])
	for li in lines.size():
		var line: Dictionary = lines[li]
		var img: String = line.get("image", "")
		if img != "" and not _save_source_exists(img):
			issues.append({
				"cause":  CAUSE_MISSING_SOURCE,
				"item":   "%s, Line %d" % [ctx, li + 1],
				"detail": "Speaker image no longer exists at: %s" % img,
				"hint":   "Re-drag the speaker image into this line, or remove it.",
			})


func _save_check_fork(fork_data: Dictionary, ctx: String, issues: Array) -> void:
	var paths: Array = fork_data.get("paths", [])
	if paths.size() < 2:
		issues.append({
			"cause":  CAUSE_FORK_UNDERFILLED,
			"item":   ctx,
			"detail": "Fork has only %d path(s); needs at least 2." % paths.size(),
			"hint":   "Add a second path in the fork editor.",
		})
	for pi in paths.size():
		var p: Dictionary = paths[pi]
		var pname: String = (p.get("name", "") as String).strip_edges()
		var path_ctx: String = "%s → Path %d \"%s\"" % [ctx, pi + 1, pname] if pname != "" \
			else "%s → Path %d" % [ctx, pi + 1]

		# Names are display-only now (see fork-path slug scheme for the card
		# image filename and round-folder slugs for rounds inside the path).
		# Any character is fine — only empty names need to be flagged, since
		# the name is what the player sees on the fork choice screen.
		if pname == "":
			issues.append({
				"cause":  CAUSE_BAD_NAME,
				"item":   path_ctx,
				"detail": "Path name is empty.",
				"hint":   "Give the path a name (e.g. \"Adventure\" or \"Reward\", or even \"What's next?\").",
			})

		var img: String = p.get("image_path", "")
		if img != "" and not _save_source_exists(img):
			issues.append({
				"cause":  CAUSE_MISSING_SOURCE,
				"item":   path_ctx,
				"detail": "Card image no longer exists at: %s" % img,
				"hint":   "Re-drag the card image for this path, or remove it.",
			})

		# A fork path must contain at least one item of any kind — round,
		# storyboard, shop, or nested fork. The "narrative-only" path
		# (storyboards as the consequence of a choice) and "skip-this-section"
		# patterns are explicit author intents we want to support, so we
		# don't require a round here. A completely empty path is still
		# rejected because it would be a button-that-does-nothing UX trap.
		var sub_items: Array = p.get("items", [])
		if sub_items.is_empty():
			issues.append({
				"cause":  CAUSE_NO_ROUNDS,
				"item":   path_ctx,
				"detail": "This fork path is empty.",
				"hint":   "Add at least one round, storyboard, shop, or nested fork to the path.",
			})
		_save_collect_items_issues(sub_items, path_ctx, issues)




# ---------------------------------------------------------------------------
# Error modal
# ---------------------------------------------------------------------------

# Shows a centred modal listing one or more SaveError dicts. Closeable via the
# OK button or backdrop. "Copy details" copies a plain-text version of every
# issue to the clipboard so users can paste it into a bug report.
func _show_save_error_modal(title: String, headline: String, errors: Array) -> void:
	if errors.is_empty():
		return

	var parts: Dictionary    = UITheme.build_centered_modal(title, UITheme.ERROR_SOFT, Vector2i(720, 520))
	var modal: Control       = parts["modal"]
	var vbox:  VBoxContainer = parts["vbox"]
	modal.name = "SaveErrorModal"

	var headline_lbl: Label = Label.new()
	headline_lbl.text = headline
	UITheme.style_label(headline_lbl, UITheme.WHITE_SOFT, 13, false)
	headline_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	headline_lbl.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(headline_lbl)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var list: VBoxContainer = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)

	for err: Dictionary in errors:
		list.add_child(_make_save_error_row(err))

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)

	var copy_btn: Button = Button.new()
	copy_btn.text = "⎘  COPY DETAILS"
	copy_btn.custom_minimum_size = Vector2(160, 0)
	UITheme.style_button(copy_btn, UITheme.PURPLE_MID)
	copy_btn.pressed.connect(func() -> void:
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
func _make_save_error_row(err: Dictionary) -> Control:
	var row: PanelContainer = PanelContainer.new()
	var rs: StyleBoxFlat = StyleBoxFlat.new()
	rs.bg_color              = UITheme.CARD_BG
	rs.border_color          = Color(UITheme.ERROR_SOFT.r, UITheme.ERROR_SOFT.g, UITheme.ERROR_SOFT.b, 0.45)
	rs.border_width_left     = 1; rs.border_width_right  = 1
	rs.border_width_top      = 1; rs.border_width_bottom = 1
	rs.content_margin_left   = 10; rs.content_margin_right  = 10
	rs.content_margin_top    = 8;  rs.content_margin_bottom = 8
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
func _show_save_error_single(title: String, cause: String, item: String, detail: String, hint: String) -> void:
	_show_save_error_modal(title, "Save failed.", [{
		"cause":  cause,
		"item":   item,
		"detail": detail,
		"hint":   hint,
	}])


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
				"Press Save again to retry. Nothing on disk was changed.")
		CAUSE_SRC_UNREADABLE:
			_show_save_error_single(
				"SAVE FAILED",
				CAUSE_SRC_UNREADABLE,
				item,
				"Source file became unreadable: %s" % copy_result.get("detail", "?"),
				"The file may have been moved, deleted, or its drive disconnected since you opened the editor. Re-drag it into this round and try again.")
		CAUSE_DST_UNWRITABLE:
			_show_save_error_single(
				"SAVE FAILED",
				CAUSE_DST_UNWRITABLE,
				item,
				"Could not create the destination file: %s" % copy_result.get("detail", "?"),
				"Check that the journeys folder drive isn't full or write-protected, and that no antivirus is blocking the editor. You can change the journeys folder in Options → Storage Location.")
		_:
			_show_save_error_single(
				"SAVE FAILED",
				CAUSE_UNKNOWN_COPY_ERROR,
				item,
				"An unexpected copy failure occurred while processing %s." % item,
				"Try saving again. If the problem persists, check the Godot debug output for details.")


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
	var parts: Dictionary    = UITheme.build_centered_modal("UNFINISHED SAVES FOUND", UITheme.AMBER, Vector2i(680, 440))
	var modal: Control       = parts["modal"]
	var vbox:  VBoxContainer = parts["vbox"]

	var headline: Label = Label.new()
	headline.text = ("Found %d leftover save folder%s from a previous session that didn't finish (crash, power loss, or force-quit). They take disk space and are normally safe to delete." % [
		stale.size(), "s" if stale.size() != 1 else "",
	])
	headline.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(headline, UITheme.WHITE_SOFT, 13, false)
	vbox.add_child(headline)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
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
	delete_btn.pressed.connect(func() -> void:
		for path: String in stale:
			JourneyData.delete_dir_recursive(path)
		modal.queue_free()
	)
	btn_row.add_child(delete_btn)

	add_child(modal)
