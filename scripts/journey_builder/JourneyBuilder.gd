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

# Used by save logic for the journey.json "Difficulty" field — also declared
# in BuilderSidePanel.gd for the difficulty dropdown.
const DIFFICULTIES: Array = ["Easy", "Medium", "Hard", "Very Hard", "Extreme", "Insane"]

# Used by _on_viewport_files_dropped to detect cover-image drops.
const IMAGE_EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "webp"]

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

var _cover_path:    String       = ""
var _cover_texture: ImageTexture = null  # cached so the journey-info view can re-show the preview without re-reading from disk

var _items:      Array  = []  # Array[Dictionary] — {type:"round"|"fork"|"shop"|"storyboard", ...}

var _graph: Control = null  # GraphView instance, host inside _graph_host
var _selected_item: Dictionary = {}  # Mirror of GraphView's current selection.

# Side panel renderer — owns no state of its own; reads/mutates this controller.
var _side_renderer: BuilderSidePanel = null

var _transcode_cancel: bool = false
var _transcode_pid:    int  = -1


func _ready() -> void:
	_side_renderer = BuilderSidePanel.new(self)
	_apply_layout()
	_apply_theme()
	_connect_signals()
	_setup_graph_view()
	if not edit_journey.is_empty():
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
	# Only treat a viewport-level image drop as the journey cover when the
	# journey-info panel is visible (no node selected). When a node IS selected
	# its own DropZone controls are connected to the same signal and handle the
	# drop themselves — without this guard their drop would also overwrite the
	# cover path.
	if not _selected_item.is_empty():
		return
	for f: String in files:
		if f.get_extension().to_lower() in IMAGE_EXTENSIONS:
			_cover_path = f
			_update_cover_preview()
			return


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
		_side_renderer.show_journey_info_panel()  # refresh visible widgets
		return
	var f: FileAccess = FileAccess.open(_cover_path, FileAccess.READ)
	if f == null:
		return
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	var img: Image = Image.new()
	var err: Error
	if bytes.size() >= 4 and bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	else:
		err = img.load_webp_from_buffer(bytes)
		if err != OK:
			err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			err = img.load_png_from_buffer(bytes)
	if err == OK:
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

	var modal: Control = null
	if not transcode_plan.is_empty():
		modal = _create_transcode_modal()
		add_child(modal)

	var rounds_json:      Array = []
	var forks_json:       Array = []
	var shops_json:       Array = []
	var storyboards_json: Array = []
	var rorder: int = 0
	var last_rorder: int = 0
	var total_main_rounds: int = _items.count(func(it: Dictionary) -> bool: return it.get("type","round") == "round")

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
			_delete_stale_files(round_dir, fs_dst_name, JourneyData.FUNSCRIPT_EXTENSIONS)

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
					_copy_file(vid_src, round_dir + "/" + vid_dst_name)
					_delete_stale_files(round_dir, vid_dst_name, JourneyData.VIDEO_EXTENSIONS)

			# If this round was renamed, remove the old folder now that all files
			# have been written to the new one.
			var orig_folder: String = it.get("original_folder", "")
			if orig_folder != "":
				var orig_abs: String = ProjectSettings.globalize_path(orig_folder)
				if orig_abs != round_dir and DirAccess.dir_exists_absolute(orig_abs):
					_delete_dir_recursive(orig_abs)

			rounds_json.append({
				"Name":         round_name,
				"Order":        rorder,
				"CoinsAwarded": it.get("coins",0) as int,
				"RoundType":    "Normal",
			})
		else:
			# Fork — recursively save the fork and all nested forks.
			var slug_prefix: String = "fork%d" % forks_json.size()
			forks_json.append(_save_fork(it, abs_dir, abs_media_dir, last_rorder, slug_prefix, copied_images))

	if modal:
		modal.queue_free()

	var data: Dictionary = {
		"Name":        journey_name,
		"Author":      _journey_author.strip_edges(),
		"Description": _journey_desc.strip_edges(),
		"Difficulty":  DIFFICULTIES[_journey_difficulty_idx],
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

	_show_status("Journey saved! Returning to catalogue...", false)
	await get_tree().create_timer(1.5).timeout
	Transition.change_scene("res://scenes/journey_select/JourneySelect.tscn")


# Recursively serializes a fork item to JSON. Calls _save_path for each path.
# `slug_prefix` makes nested-storyboard filenames unique across the journey.
func _save_fork(fork_item: Dictionary, abs_dir: String, abs_media_dir: String, after_order: int, slug_prefix: String, copied_images: Dictionary) -> Dictionary:
	var fork_entry: Dictionary = {
		"AfterOrder":  after_order,
		"Title":       fork_item.get("title",""),
		"Description": fork_item.get("description",""),
		"Paths":       [],
	}
	for pi in (fork_item.get("paths", []) as Array).size():
		var path_data: Dictionary = fork_item["paths"][pi]
		var path_slug: String = "%s_p%d" % [slug_prefix, pi]
		fork_entry["Paths"].append(_save_path(path_data, abs_dir, abs_media_dir, path_slug, copied_images))
	return fork_entry


# Recursively serializes a single fork path to JSON, splitting its items into
# Rounds, Shops, Storyboards, and (nested) Forks arrays.
func _save_path(path_data: Dictionary, abs_dir: String, abs_media_dir: String, slug_prefix: String, copied_images: Dictionary) -> Dictionary:
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
				path_entry["Forks"].append(_save_fork(pi_item, abs_dir, abs_media_dir, pr_last_order, nested_slug, copied_images))
			_:
				# Round
				pr_order += 1
				pr_last_order = pr_order
				var pr_name: String = (pi_item.get("name","") as String).strip_edges()
				var pr_dir: String  = abs_dir + "/" + pr_name
				DirAccess.make_dir_recursive_absolute(pr_dir)
				var pr_fs: String = pi_item.get("funscript_path","")
				if pr_fs != "":
					var pr_fs_dst_name: String = pr_name + "." + pr_fs.get_extension()
					_copy_file(pr_fs, pr_dir + "/" + pr_fs_dst_name)
					_delete_stale_files(pr_dir, pr_fs_dst_name, JourneyData.FUNSCRIPT_EXTENSIONS)
				var pr_vid: String = pi_item.get("video_path","")
				if pr_vid != "":
					var pr_vid_dst_name: String = pr_vid.get_file()
					_copy_file(pr_vid, pr_dir + "/" + pr_vid_dst_name)
					_delete_stale_files(pr_dir, pr_vid_dst_name, JourneyData.VIDEO_EXTENSIONS)
				var pr_orig_folder: String = pi_item.get("original_folder", "")
				if pr_orig_folder != "":
					var pr_orig_abs: String = ProjectSettings.globalize_path(pr_orig_folder)
					if pr_orig_abs != pr_dir and DirAccess.dir_exists_absolute(pr_orig_abs):
						_delete_dir_recursive(pr_orig_abs)
				path_entry["Rounds"].append({
					"Name":         pr_name,
					"Order":        pr_order,
					"CoinsAwarded": pi_item.get("coins",0) as int,
				})

	return path_entry


# ---------------------------------------------------------------------------
# Transcoding
# ---------------------------------------------------------------------------

func _ffmpeg_binary(name: String) -> String:
	# Try bundled binary first (works in both editor and exported builds), then PATH.
	var exe: String = name + ".exe" if OS.get_name() == "Windows" else name
	var bundled: String = ProjectSettings.globalize_path("res://bin/" + exe)
	if FileAccess.file_exists(bundled):
		return bundled
	var next_to_app: String = OS.get_executable_path().get_base_dir() + "/bin/" + exe
	if FileAccess.file_exists(next_to_app):
		return next_to_app
	return name  # fall back to PATH lookup


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
	title.text = "TRANSCODING VIDEO"
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


# Recursively deletes a directory and all its contents. Used to remove a round
# folder after the round has been renamed and its files written to the new one.
func _delete_dir_recursive(path: String) -> void:
	var da: DirAccess = DirAccess.open(path)
	if da == null:
		return
	da.list_dir_begin()
	var fname: String = da.get_next()
	while fname != "":
		var child: String = path + "/" + fname
		if da.current_is_dir():
			_delete_dir_recursive(child)
		else:
			DirAccess.remove_absolute(child)
		fname = da.get_next()
	da.list_dir_end()
	DirAccess.remove_absolute(path)


# Removes files inside `dir_path` whose extension is in `extensions` but whose
# filename is NOT `keep_filename`. Called after writing a replacement funscript
# or video so the old file doesn't linger as a duplicate.
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
