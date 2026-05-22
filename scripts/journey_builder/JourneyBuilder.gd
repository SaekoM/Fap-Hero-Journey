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
const JOURNEYS_DIR:    String = "user://journeys"

# Difficulty list and file-extension sets live in JourneyData (canonical schema).
# Referenced here as JourneyData.DIFFICULTIES / JourneyData.IMAGE_EXTENSIONS etc.

# EIRTeam.FFmpeg only decodes H.264; everything else gets transcoded on save.
const H264_NAMES: Array[String] = ["h264", "avc1", "avc"]
const TRANSCODE_PROGRESS_FILE: String = "user://transcode_progress.txt"

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
	var d: Dictionary = JourneyData.parse_journey(journey)
	_journey_name           = d["name"]
	_journey_author         = d["author"]
	_journey_desc           = d["description"]
	_journey_difficulty_idx = d["difficulty_idx"]
	_journey_tags           = (d.get("tags", []) as Array).duplicate()
	if (d["cover_path"] as String) != "":
		_cover_path = d["cover_path"]
		_update_cover_preview()
	# Mutate in place rather than replacing the reference — _setup_graph_view
	# has already done call_deferred("set_items", _items), which captures the
	# array reference. If we reassign _items here, that deferred call fires
	# after _load_journey with the stale (empty) reference and clears the graph.
	_items.clear()
	for it in d["items"]:
		_items.append(it)
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
	_save_btn.disabled  = true
	_status_lbl.visible = false
	_transcode_cancel   = false
	_save_aborted       = false

	var journey_name: String = _journey_name.strip_edges()
	if journey_name == "":
		_show_status("Journey name is required.", true)
		_save_btn.disabled = false
		return

	var has_any_round: bool = _items.any(func(it: Dictionary) -> bool: return it.get("type","round") == "round")
	if not has_any_round:
		_show_status("Add at least one round before saving.", true)
		_save_btn.disabled = false
		return

	var round_count: int = 0
	for i in _items.size():
		var it: Dictionary = _items[i]
		var t: String = it.get("type", "round")
		if t == "round":
			round_count += 1
			if (it.get("name","") as String).strip_edges() == "":
				_show_status("Round %d needs a name." % round_count, true)
				_save_btn.disabled = false
				return
			if it.get("funscript_path","") == "":
				_show_status("Round %d needs a funscript file." % round_count, true)
				_save_btn.disabled = false
				return
		elif t == "shop" or t == "storyboard":
			# Shops and storyboards have no required fields for save.
			pass
		else:
			# Fork (top-level or nested via recursion).
			var err: String = JourneyData.validate_fork(it, "fork after round %d" % round_count)
			if err != "":
				_show_status(err, true)
				_save_btn.disabled = false
				return

	# Walks items[] (and nested forks) looking for any round with a video.
	var any_video: bool = JourneyData.items_have_any_video(_items)
	var ffmpeg_ok: bool = _ffmpeg_available() if any_video else false

	# Transcode plan only for main rounds (fork path rounds are copied as-is)
	var transcode_plan: Dictionary = {}
	var main_round_idx: int = 0
	if ffmpeg_ok:
		for i in _items.size():
			if _items[i].get("type","round") != "round":
				continue
			var vid: String = _items[i].get("video_path", "")
			if vid != "":
				var codec: String = _get_video_codec(vid)
				if codec != "" and not (codec in H264_NAMES):
					transcode_plan[i] = {"codec": codec, "duration": _video_duration_seconds(vid)}
			main_round_idx += 1

	if not transcode_plan.is_empty() and not ffmpeg_ok:
		_show_status("Videos need transcoding (non-H.264) but ffmpeg is not on PATH. Install ffmpeg and restart Godot.", true)
		_save_btn.disabled = false
		return

	var folder_name: String = JourneyData.sanitize_folder_name(journey_name)
	var journey_dir: String = JOURNEYS_DIR + "/" + folder_name
	var abs_dir: String     = ProjectSettings.globalize_path(journey_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)

	# All images (cover + storyboard backgrounds + line images + fork path
	# illustrations) live in a dedicated media/ subfolder so the journey root
	# only contains journey.json and per-round subdirectories.
	var abs_media_dir: String = abs_dir + "/media"
	DirAccess.make_dir_recursive_absolute(abs_media_dir)

	# Tracks images already copied this save: source_path → dest_filename
	# (relative to abs_media_dir). Prevents duplicating a file when the same
	# image is referenced multiple times.
	var copied_images: Dictionary = {}

	if _cover_path != "":
		var ext: String = _cover_path.get_extension().to_lower()
		_copy_image_deduped(_cover_path, abs_media_dir, "cover." + ext, copied_images)

	# Show the progress modal whenever the save will copy or transcode video —
	# large video copies are streamed and take visible time.
	var modal: Control = null
	if any_video:
		modal = _create_transcode_modal()
		add_child(modal)

	var rounds_json:      Array = []
	var forks_json:       Array = []
	var shops_json:       Array = []
	var storyboards_json: Array = []
	var rorder: int = 0
	var last_rorder: int = 0
	var total_main_rounds: int = _items.filter(func(it: Dictionary) -> bool: return it.get("type","round") == "round").size()

	for i in _items.size():
		var it: Dictionary = _items[i]
		var it_type: String = it.get("type","round")
		if it_type == "shop":
			shops_json.append({
				"AfterOrder": last_rorder,
				"Title":      it.get("title",""),
			})
			continue
		if it_type == "storyboard":
			rorder += 1
			last_rorder = rorder
			var sb_slug: String = "storyboard_%d" % rorder
			var sb_img_src: String = it.get("image", "")
			var sb_img_fname: String = ""
			if sb_img_src != "":
				var sb_ext: String = sb_img_src.get_extension().to_lower()
				var sb_f: String = _copy_image_deduped(sb_img_src, abs_media_dir, sb_slug + "." + sb_ext, copied_images)
				sb_img_fname = "media/" + sb_f if sb_f != "" else ""
			var sb_lines_json: Array = []
			for sb_li_idx in (it.get("lines", []) as Array).size():
				var sb_li: Dictionary = it["lines"][sb_li_idx]
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
				"CoinsAwarded": it.get("coins", 0) as int,
				"Image":        sb_img_fname,
				"Lines":        sb_lines_json,
			})
			continue
		if it_type == "round":
			rorder += 1
			last_rorder = rorder

			var round_name: String = (it.get("name","") as String).strip_edges()
			var round_dir: String  = abs_dir + "/" + round_name
			DirAccess.make_dir_recursive_absolute(round_dir)

			var fs_src: String = it.get("funscript_path","")
			var fs_dst_name: String = round_name + "." + fs_src.get_extension()
			_copy_file(fs_src, round_dir + "/" + fs_dst_name)
			# L0-only stale cleanup: skips secondary-axis scripts in this folder.
			_delete_stale_l0_files(round_dir, fs_dst_name)
			# Cache action count + length so the catalogue scan never re-parses this.
			var fs_stats: Dictionary = JourneyData.read_funscript_stats(round_dir + "/" + fs_dst_name)

			# Copy secondary-axis scripts and collect relative paths for the JSON.
			var axis_scripts_in: Dictionary = it.get("axis_scripts", {})
			var axis_scripts_rel: Dictionary = {}
			for axis: String in axis_scripts_in:
				var ax_src: String = axis_scripts_in[axis]
				if ax_src == "":
					continue
				var ax_dst_name: String = round_name + "_" + axis + "." + ax_src.get_extension()
				_copy_file(ax_src, round_dir + "/" + ax_dst_name)
				_delete_stale_axis_files(round_dir, axis, ax_dst_name)
				axis_scripts_rel[axis] = round_name + "/" + ax_dst_name

			# Copy vibrator-channel scripts and collect relative paths for the JSON.
			var vib_scripts_in: Dictionary = it.get("vib_scripts", {})
			var vib_scripts_rel: Dictionary = {}
			for ch_key: String in vib_scripts_in:
				var vib_src: String = vib_scripts_in[ch_key]
				if vib_src == "":
					continue
				var vib_dst_name: String = round_name + "_" + ch_key + "." + vib_src.get_extension()
				_copy_file(vib_src, round_dir + "/" + vib_dst_name)
				_delete_stale_vib_files(round_dir, ch_key, vib_dst_name)
				vib_scripts_rel[ch_key] = round_name + "/" + vib_dst_name

			# Boss-round config — copy the optional intro image into the round folder.
			var round_type: String = it.get("round_type", "normal")
			var boss_image_rel: String = ""
			if round_type == "boss":
				var boss_src: String = it.get("boss_image", "")
				if boss_src != "":
					var boss_dst_name: String = round_name + "_boss." + boss_src.get_extension()
					_copy_file(boss_src, round_dir + "/" + boss_dst_name)
					boss_image_rel = round_name + "/" + boss_dst_name

			var vid_src: String = it.get("video_path","")
			if vid_src != "":
				if i in transcode_plan:
					var info: Dictionary = transcode_plan[i]
					var vid_dst_name: String = vid_src.get_file().get_basename() + ".mp4"
					var vid_dst: String      = round_dir + "/" + vid_dst_name
					_update_modal_round(modal, rorder, total_main_rounds, round_name, info["codec"])
					var ok: bool = await _transcode_video(vid_src, vid_dst, info["duration"], modal)
					if not ok:
						if modal: modal.queue_free()
						_show_status("Transcoding cancelled. Journey not saved.", true)
						_save_btn.disabled = false
						return
					_delete_stale_files(round_dir, vid_dst_name, JourneyData.VIDEO_EXTENSIONS)
				else:
					var vid_dst_name: String = vid_src.get_file()
					var vid_dst_path: String = round_dir + "/" + vid_dst_name
					# Guard: if the source already lives at the destination (the user
					# only changed the funscript and kept the same video), opening the
					# destination for WRITE would truncate it to 0 KB before the read
					# handle can consume it. Skip the copy entirely in that case.
					var vid_src_abs: String = ProjectSettings.globalize_path(vid_src)
					if vid_src_abs != vid_dst_path:
						_update_modal_label(modal, "Round %d / %d — %s  (copying video)" % [rorder, total_main_rounds, round_name])
						var copy_ok: bool = await _copy_file_chunked(
							vid_src, vid_dst_path,
							func(done: int, tot: int) -> void: _update_modal_copy(modal, done, tot))
						if not copy_ok:
							if modal: modal.queue_free()
							_show_status("Save cancelled. Journey not saved." if _transcode_cancel \
								else "Failed to copy video for round \"%s\"." % round_name, true)
							_save_btn.disabled = false
							return
						_delete_stale_files(round_dir, vid_dst_name, JourneyData.VIDEO_EXTENSIONS)

			# If this round was renamed, remove the old folder now that all files
			# have been written to the new one.
			var orig_folder: String = it.get("original_folder", "")
			if orig_folder != "":
				var orig_abs: String = ProjectSettings.globalize_path(orig_folder)
				if orig_abs != round_dir and DirAccess.dir_exists_absolute(orig_abs):
					JourneyData.delete_dir_recursive(orig_abs)

			rounds_json.append({
				"Name":           round_name,
				"Order":          rorder,
				"CoinsAwarded":   it.get("coins",0) as int,
				"RoundType":      "Boss" if round_type == "boss" else "Normal",
				"BossImage":      boss_image_rel,
				"BossTagline":    it.get("boss_tagline", ""),
				"BossModifiers":  _boss_modifiers_json(it.get("boss_modifiers", [])),
				"FunscriptPath":  round_name + "/" + fs_dst_name,
				"AxisScripts":    axis_scripts_rel,
				"VibScripts":     vib_scripts_rel,
				"ActionCount":    fs_stats["count"],
				"LengthMs":       fs_stats["length_ms"],
			})
		else:
			# Fork — recursively save the fork and all nested forks.
			var slug_prefix: String = "fork%d" % forks_json.size()
			forks_json.append(await _save_fork(it, abs_dir, abs_media_dir, last_rorder, slug_prefix, copied_images, modal))
			# A cancelled video copy deep inside a fork path unwinds to here.
			if _save_aborted:
				if modal: modal.queue_free()
				_show_status("Save cancelled. Journey not saved.", true)
				_save_btn.disabled = false
				return

	if modal:
		modal.queue_free()

	var data: Dictionary = {
		"Name":        journey_name,
		"Author":      _journey_author.strip_edges(),
		"Description": _journey_desc.strip_edges(),
		"Difficulty":  JourneyData.DIFFICULTIES[_journey_difficulty_idx],
		"Tags":        TagRegistry.sanitize(_journey_tags),
		"Rounds":      rounds_json,
		"Forks":       forks_json,
		"Shops":       shops_json,
		"Storyboards": storyboards_json,
	}

	var f: FileAccess = FileAccess.open(journey_dir + "/journey.json", FileAccess.WRITE)
	if f == null:
		_show_status("Failed to write journey.json — check folder permissions.", true)
		_save_btn.disabled = false
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

	# If editing renamed the journey, the save wrote a new folder — remove the
	# stale original (its old journey.json, media/, and any leftover subfolders).
	if _original_journey_folder != "":
		var old_abs: String = ProjectSettings.globalize_path(_original_journey_folder)
		if old_abs != abs_dir and DirAccess.dir_exists_absolute(old_abs):
			JourneyData.delete_dir_recursive(old_abs)

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
		var safe_name: String = JourneyData.sanitize_folder_name(path_data.get("name", slug_prefix))
		var img_f: String = _copy_image_deduped(img_src, abs_media_dir, safe_name + "_cover." + img_src.get_extension().to_lower(), copied_images)
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
					"AfterOrder": pr_last_order,
					"Title":      pi_item.get("title",""),
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
				# Round
				pr_order += 1
				pr_last_order = pr_order
				var pr_name: String = (pi_item.get("name","") as String).strip_edges()
				var pr_dir: String  = abs_dir + "/" + pr_name
				DirAccess.make_dir_recursive_absolute(pr_dir)
				var pr_fs: String = pi_item.get("funscript_path","")
				var pr_fs_dst_name: String = ""
				var pr_fs_stats: Dictionary = {"count": 0, "length_ms": 0}
				if pr_fs != "":
					pr_fs_dst_name = pr_name + "." + pr_fs.get_extension()
					_copy_file(pr_fs, pr_dir + "/" + pr_fs_dst_name)
					_delete_stale_l0_files(pr_dir, pr_fs_dst_name)
					pr_fs_stats = JourneyData.read_funscript_stats(pr_dir + "/" + pr_fs_dst_name)
				var pr_vid: String = pi_item.get("video_path","")
				if pr_vid != "":
					var pr_vid_dst_name: String = pr_vid.get_file()
					var pr_vid_dst_path: String = pr_dir + "/" + pr_vid_dst_name
					# Same src==dst guard as the top-level round copy: skip when the
					# video is already at its destination to avoid a 0 KB truncation.
					var pr_vid_src_abs: String = ProjectSettings.globalize_path(pr_vid)
					if pr_vid_src_abs != pr_vid_dst_path:
						_update_modal_label(modal, "Fork round — %s  (copying video)" % pr_name)
						var pr_copy_ok: bool = await _copy_file_chunked(
							pr_vid, pr_vid_dst_path,
							func(done: int, tot: int) -> void: _update_modal_copy(modal, done, tot))
						if not pr_copy_ok:
							# Cancelled / failed — unwind the recursive save.
							_save_aborted = true
							return path_entry
						_delete_stale_files(pr_dir, pr_vid_dst_name, JourneyData.VIDEO_EXTENSIONS)
				var pr_axis_in: Dictionary = pi_item.get("axis_scripts", {})
				var pr_axis_rel: Dictionary = {}
				for axis: String in pr_axis_in:
					var ax_src: String = pr_axis_in[axis]
					if ax_src == "":
						continue
					var ax_dst_name: String = pr_name + "_" + axis + "." + ax_src.get_extension()
					_copy_file(ax_src, pr_dir + "/" + ax_dst_name)
					_delete_stale_axis_files(pr_dir, axis, ax_dst_name)
					pr_axis_rel[axis] = pr_name + "/" + ax_dst_name
				var pr_vib_in: Dictionary = pi_item.get("vib_scripts", {})
				var pr_vib_rel: Dictionary = {}
				for ch_key: String in pr_vib_in:
					var vib_src: String = pr_vib_in[ch_key]
					if vib_src == "":
						continue
					var vib_dst_name: String = pr_name + "_" + ch_key + "." + vib_src.get_extension()
					_copy_file(vib_src, pr_dir + "/" + vib_dst_name)
					_delete_stale_vib_files(pr_dir, ch_key, vib_dst_name)
					pr_vib_rel[ch_key] = pr_name + "/" + vib_dst_name
				var pr_round_type: String = pi_item.get("round_type", "normal")
				var pr_boss_image_rel: String = ""
				if pr_round_type == "boss":
					var pr_boss_src: String = pi_item.get("boss_image", "")
					if pr_boss_src != "":
						var pr_boss_dst_name: String = pr_name + "_boss." + pr_boss_src.get_extension()
						_copy_file(pr_boss_src, pr_dir + "/" + pr_boss_dst_name)
						pr_boss_image_rel = pr_name + "/" + pr_boss_dst_name
				var pr_orig_folder: String = pi_item.get("original_folder", "")
				if pr_orig_folder != "":
					var pr_orig_abs: String = ProjectSettings.globalize_path(pr_orig_folder)
					if pr_orig_abs != pr_dir and DirAccess.dir_exists_absolute(pr_orig_abs):
						JourneyData.delete_dir_recursive(pr_orig_abs)
				path_entry["Rounds"].append({
					"Name":          pr_name,
					"Order":         pr_order,
					"CoinsAwarded":  pi_item.get("coins",0) as int,
					"RoundType":     "Boss" if pr_round_type == "boss" else "Normal",
					"BossImage":     pr_boss_image_rel,
					"BossTagline":   pi_item.get("boss_tagline", ""),
					"BossModifiers": _boss_modifiers_json(pi_item.get("boss_modifiers", [])),
					"FunscriptPath": pr_name + "/" + pr_fs_dst_name if pr_fs_dst_name != "" else "",
					"AxisScripts":   pr_axis_rel,
					"VibScripts":    pr_vib_rel,
					"ActionCount":   pr_fs_stats["count"],
					"LengthMs":      pr_fs_stats["length_ms"],
				})

	return path_entry


# ---------------------------------------------------------------------------
# Transcoding
# ---------------------------------------------------------------------------

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
	var us: int = 0
	var speed: String = ""
	for raw_line: String in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("out_time_us="):
			us = line.substr(12).to_int()
		elif line.begins_with("out_time_ms="):
			us = line.substr(12).to_int()
		elif line.begins_with("speed="):
			speed = line.substr(6)
	var current_s: float = us / 1_000_000.0
	var progress: float = 0.0
	if duration > 0.0:
		progress = clampf(current_s / duration, 0.0, 1.0)
	_update_modal_progress(modal, progress, current_s, duration, speed)


# ---------------------------------------------------------------------------
# Transcode modal UI
# ---------------------------------------------------------------------------

func _create_transcode_modal() -> Control:
	var modal: Control = Control.new()
	modal.name = "TranscodeModal"
	modal.anchor_right = 1.0
	modal.anchor_bottom = 1.0
	modal.mouse_filter = Control.MOUSE_FILTER_STOP

	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.85)
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	modal.add_child(backdrop)

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color            = UITheme.PANEL_BG
	ps.border_color        = UITheme.PURPLE_BRIGHT
	ps.border_width_left   = 2; ps.border_width_right  = 2
	ps.border_width_top    = 2; ps.border_width_bottom = 2
	ps.content_margin_left = 32; ps.content_margin_right  = 32
	ps.content_margin_top  = 24; ps.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel", ps)
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top = 0.5;  panel.anchor_bottom = 0.5
	panel.offset_left = -260; panel.offset_right = 260
	panel.offset_top = -120;  panel.offset_bottom = 120
	modal.add_child(panel)

	var vb: VBoxContainer = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)

	var title: Label = Label.new()
	title.name = "Title"
	title.text = "SAVING JOURNEY"
	UITheme.style_label(title, UITheme.PURPLE_BRIGHT, 16, true)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var round_lbl: Label = Label.new()
	round_lbl.name = "RoundLabel"
	round_lbl.text = ""
	UITheme.style_label(round_lbl, UITheme.WHITE_SOFT, 13, false)
	round_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(round_lbl)

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
	vb.add_child(bar)

	var status_lbl: Label = Label.new()
	status_lbl.name = "Status"
	status_lbl.text = "Starting..."
	UITheme.style_label(status_lbl, UITheme.PURPLE_MID, 12, false)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(status_lbl)

	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(120, 0)
	UITheme.style_button(cancel_btn, UITheme.MAGENTA)
	cancel_btn.pressed.connect(func() -> void: _transcode_cancel = true)
	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_child(cancel_btn)
	vb.add_child(btn_row)

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
func _copy_file(src: String, dst: String) -> void:
	var src_file: FileAccess = FileAccess.open(src, FileAccess.READ)
	if src_file == null:
		printerr("JourneyBuilder: cannot read: " + src)
		return
	var bytes: PackedByteArray = src_file.get_buffer(src_file.get_length())
	src_file.close()
	var dst_file: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if dst_file == null:
		printerr("JourneyBuilder: cannot write: " + dst)
		return
	dst_file.store_buffer(bytes)
	dst_file.close()


# Streaming file copy for large files (video). Reads/writes in COPY_CHUNK_SIZE
# blocks and yields one frame whenever COPY_FRAME_BUDGET_MS of work has piled
# up — so the window stays responsive and the modal can repaint, without paying
# a full frame-wait per chunk. `progress` (optional) is called as
# progress.call(copied_bytes, total_bytes). Honours the modal's cancel button
# via _transcode_cancel. Returns false on I/O error or cancellation.
func _copy_file_chunked(src: String, dst: String, progress: Callable = Callable()) -> bool:
	var src_file: FileAccess = FileAccess.open(src, FileAccess.READ)
	if src_file == null:
		printerr("JourneyBuilder: cannot read: " + src)
		return false
	var dst_file: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if dst_file == null:
		printerr("JourneyBuilder: cannot write: " + dst)
		src_file.close()
		return false

	var total: int = src_file.get_length()
	var copied: int = 0
	var budget_start: int = Time.get_ticks_msec()

	while copied < total:
		if _transcode_cancel:
			src_file.close()
			dst_file.close()
			return false
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
	return true


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
