extends Control
## The randomizer entry point: manage the clip library, tune generation settings,
## then Generate & Play — which builds a temp journey and launches it through the
## normal GameLoop path. UI is built programmatically (like Options) so the scene
## is just a root Control + this script.
##
## First-pass UI: functional loop (add clips → tune → play). Visual polish + the
## preview-map / re-roll / presets adds are follow-ups.

const VIDEO_EXTS: Array[String] = [
	"mp4", "mkv", "mov", "avi", "webm", "m4v", "wmv", "flv", "ts", "mpg", "mpeg"
]

# Reused for the per-card "attach a funscript" affordance (drop + browse).
const DropZoneScript := preload("res://scripts/journey_builder/DropZone.gd")

# Read-only map render for the pre-launch preview (same view the player map uses).
const GraphViewScene := preload("res://scenes/graph_view/GraphView.tscn")

var _lib_list: VBoxContainer
var _lib_count: Label
var _status: Label
var _generate_btn: Button
var _cancel_btn: Button
var _busy: bool = false
var _cancel_requested: bool = false

# The most recently generated run, held while the preview overlay is up (Play uses
# it; Re-roll replaces it). Empty when no preview is open.
var _pending_run: Dictionary = {}
var _preview_overlay: Control = null

# Settings controls (read at generate time).
var _preset_opt: OptionButton
var _mode_opt: OptionButton
var _count_spin: SpinBox
var _time_spin: SpinBox
var _effect_slider: HSlider
var _effect_val: Label
var _boss_check: CheckButton
var _intensity_check: CheckButton
var _shop_spin: SpinBox
var _seed_field: LineEdit


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	_build_ui()
	RandomizerLibrary.library_changed.connect(_refresh_library)
	# OS file drag-and-drop (videos or whole folders) — same signal DropZone uses.
	get_viewport().files_dropped.connect(_on_files_dropped)
	_refresh_library()


func _exit_tree() -> void:
	var vp: Viewport = get_viewport()
	if vp and vp.files_dropped.is_connected(_on_files_dropped):
		vp.files_dropped.disconnect(_on_files_dropped)


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel") or _busy:
		return
	get_viewport().set_input_as_handled()
	# Esc closes the preview first; otherwise leaves the screen.
	if _preview_overlay != null:
		_close_preview()
	else:
		Transition.change_scene("res://scenes/main/Main.tscn")


# ── Layout ───────────────────────────────────────────────────────────────────


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = UITheme.BG
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	add_child(bg)

	var margin := MarginContainer.new()
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	margin.add_child(root)

	# Header row: title + back.
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "🎲 RANDOMIZER"
	UITheme.style_label(title, UITheme.PURPLE_BRIGHT, 28, true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var back_btn := Button.new()
	back_btn.text = "← BACK"
	UITheme.style_button(back_btn, UITheme.PURPLE_MID)
	back_btn.pressed.connect(func() -> void: Transition.change_scene("res://scenes/main/Main.tscn"))
	header.add_child(back_btn)
	root.add_child(header)

	# Two columns: library (left, wider) + settings (right).
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 24)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(cols)
	cols.add_child(_build_library_column())
	cols.add_child(_build_settings_column())

	# Footer: generate + status.
	_generate_btn = Button.new()
	_generate_btn.text = "⚡ GENERATE"
	UITheme.style_button(_generate_btn, UITheme.PURPLE_BRIGHT, 24, 14, 18)
	_generate_btn.pressed.connect(_on_generate_pressed)
	root.add_child(_generate_btn)

	# Shown only while a run is transcoding its clips (see _prepare_used_media).
	_cancel_btn = Button.new()
	_cancel_btn.text = "✕ CANCEL"
	UITheme.style_button(_cancel_btn, UITheme.MAGENTA)
	_cancel_btn.visible = false
	_cancel_btn.pressed.connect(func() -> void: _cancel_requested = true)
	root.add_child(_cancel_btn)

	_status = Label.new()
	UITheme.style_label(_status, UITheme.DARK_TEXT, 13)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_status)


func _build_library_column() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 2.0
	col.add_theme_constant_override("separation", 10)

	var bar := HBoxContainer.new()
	_lib_count = Label.new()
	UITheme.style_label(_lib_count, UITheme.WHITE_SOFT, 15, true)
	_lib_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_lib_count)
	var folder_btn := Button.new()
	folder_btn.text = "+ FOLDER"
	UITheme.style_button(folder_btn, UITheme.CYAN)
	folder_btn.pressed.connect(_on_folder_pressed)
	bar.add_child(folder_btn)
	var add_btn := Button.new()
	add_btn.text = "+ FILES"
	UITheme.style_button(add_btn, UITheme.CYAN)
	add_btn.pressed.connect(_on_add_pressed)
	bar.add_child(add_btn)
	var clear_btn := Button.new()
	clear_btn.text = "CLEAR ALL"
	UITheme.style_button(clear_btn, UITheme.DANGER)
	clear_btn.pressed.connect(_on_clear_all_pressed)
	bar.add_child(clear_btn)
	col.add_child(bar)

	var hint := Label.new()
	hint.text = "Drag videos or folders anywhere to import (funscripts pair by filename)."
	UITheme.style_label(hint, UITheme.DARK_TEXT, 11)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_lib_list = VBoxContainer.new()
	_lib_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lib_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_lib_list)
	col.add_child(scroll)
	return col


func _build_settings_column() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 1.0
	col.add_theme_constant_override("separation", 12)

	var heading := Label.new()
	heading.text = "SETTINGS"
	UITheme.style_label(heading, UITheme.WHITE_SOFT, 15, true)
	col.add_child(heading)

	# Presets row: load a saved combo, or save/delete the current one.
	_preset_opt = OptionButton.new()
	_preset_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_opt.item_selected.connect(_on_preset_selected)
	var save_preset_btn := Button.new()
	save_preset_btn.text = "SAVE"
	UITheme.style_button(save_preset_btn, UITheme.CYAN, 12, 8, 12)
	save_preset_btn.pressed.connect(_on_save_preset_pressed)
	var del_preset_btn := Button.new()
	del_preset_btn.text = "DEL"
	UITheme.style_button(del_preset_btn, UITheme.PURPLE_MID, 12, 8, 12)
	del_preset_btn.pressed.connect(_on_delete_preset_pressed)
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 6)
	preset_row.add_child(_preset_opt)
	preset_row.add_child(save_preset_btn)
	preset_row.add_child(del_preset_btn)
	col.add_child(_labeled("Presets", preset_row))

	# Length mode + values.
	_mode_opt = OptionButton.new()
	_mode_opt.add_item("By round count")
	_mode_opt.add_item("By session time")
	_mode_opt.item_selected.connect(func(_i: int) -> void: _sync_mode_rows())
	col.add_child(_labeled("Length mode", _mode_opt))

	_count_spin = _make_spin(1, 100, 10, 1)
	col.add_child(_labeled("Round count", _count_spin))

	_time_spin = _make_spin(1, 240, 20, 1)
	col.add_child(_labeled("Target minutes", _time_spin))

	# Effect chance slider.
	_effect_slider = HSlider.new()
	_effect_slider.min_value = 0
	_effect_slider.max_value = 100
	_effect_slider.step = 5
	_effect_slider.value = 0
	_effect_slider.custom_minimum_size = Vector2(140, 0)
	_effect_val = Label.new()
	UITheme.style_label(_effect_val, UITheme.DARK_TEXT, 13)
	_effect_slider.value_changed.connect(func(v: float) -> void: _effect_val.text = "%d%%" % int(v))
	_effect_val.text = "0%"
	var eff_row := HBoxContainer.new()
	_effect_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	eff_row.add_child(_effect_slider)
	eff_row.add_child(_effect_val)
	col.add_child(_labeled("Effect-round chance", eff_row))

	_shop_spin = _make_spin(0, 20, 0, 1)
	col.add_child(_labeled("Shop every N rounds (0=off)", _shop_spin))

	_boss_check = CheckButton.new()
	_boss_check.text = "Boss finale"
	col.add_child(_boss_check)

	_intensity_check = CheckButton.new()
	_intensity_check.text = "Intensity build-up"
	col.add_child(_intensity_check)

	_seed_field = LineEdit.new()
	_seed_field.placeholder_text = "random"
	col.add_child(_labeled("Seed (blank = random)", _seed_field))

	_sync_mode_rows()
	_refresh_presets()
	return col


# ── Presets ──────────────────────────────────────────────────────────────────


# Rebuilds the dropdown from disk. Item 0 is a non-preset placeholder.
func _refresh_presets() -> void:
	_preset_opt.clear()
	_preset_opt.add_item("— Load preset —")
	for p: Dictionary in RandomizerPresets.load_all():
		_preset_opt.add_item(str(p.get("name", "")))


func _on_preset_selected(idx: int) -> void:
	if idx <= 0:
		return  # the placeholder
	var presets: Array = RandomizerPresets.load_all()
	if idx - 1 < presets.size():
		_apply_settings((presets[idx - 1] as Dictionary).get("settings", {}))


func _on_save_preset_pressed() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Save Preset"
	dialog.ok_button_text = "SAVE"
	var field := LineEdit.new()
	field.placeholder_text = "Preset name"
	field.custom_minimum_size = Vector2(260, 0)
	# Prefill with the current preset's name if one is selected (overwrite it).
	if _preset_opt.selected > 0:
		field.text = _preset_opt.get_item_text(_preset_opt.selected)
	dialog.add_child(field)
	dialog.register_text_enter(field)
	dialog.confirmed.connect(
		func() -> void:
			var name: String = field.text.strip_edges()
			if name != "":
				RandomizerPresets.add(name, _preset_settings())
				_refresh_presets()
				_select_preset(name)
			dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()
	field.grab_focus()


func _on_delete_preset_pressed() -> void:
	var idx: int = _preset_opt.selected
	if idx <= 0:
		return
	RandomizerPresets.remove(_preset_opt.get_item_text(idx))
	_refresh_presets()


# Selects the dropdown item matching `name` (no-op if not present).
func _select_preset(name: String) -> void:
	for i: int in _preset_opt.item_count:
		if _preset_opt.get_item_text(i) == name:
			_preset_opt.selected = i
			return


# Current settings minus the seed — a preset is a style, not a specific roll.
func _preset_settings() -> Dictionary:
	var s: Dictionary = _read_settings()
	s.erase("seed")
	return s


# Applies a stored preset to the controls (leaves the seed field untouched).
func _apply_settings(s: Dictionary) -> void:
	_mode_opt.selected = 1 if str(s.get("length_mode", "count")) == "time" else 0
	_count_spin.value = int(s.get("round_count", 10))
	_time_spin.value = float(s.get("target_minutes", 20.0))
	_effect_slider.value = float(s.get("effect_pct", 0.0)) * 100.0
	_boss_check.button_pressed = bool(s.get("boss_finale", false))
	_intensity_check.button_pressed = bool(s.get("intensity_order", false))
	_shop_spin.value = int(s.get("shop_every", 0))
	_sync_mode_rows()


# A label above a control, returned as a small VBox.
func _labeled(text: String, control: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var lbl := Label.new()
	lbl.text = text
	UITheme.style_label(lbl, UITheme.DARK_TEXT, 12)
	box.add_child(lbl)
	box.add_child(control)
	return box


func _make_spin(lo: float, hi: float, val: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = val
	return s


# Show only the value control relevant to the chosen length mode.
func _sync_mode_rows() -> void:
	var by_time: bool = _mode_opt.selected == 1
	_count_spin.get_parent().visible = not by_time
	_time_spin.get_parent().visible = by_time


# ── Library list ─────────────────────────────────────────────────────────────


func _refresh_library() -> void:
	if _lib_list == null:
		return
	for c: Node in _lib_list.get_children():
		c.queue_free()
	var entries: Array = RandomizerLibrary.get_all()
	_lib_count.text = "CLIP LIBRARY  (%d)" % entries.size()
	if entries.is_empty():
		var empty := Label.new()
		empty.text = "No clips yet — add videos (their .funscript is paired automatically)."
		UITheme.style_label(empty, UITheme.DARK_TEXT, 13)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_lib_list.add_child(empty)
		return
	for entry: Dictionary in entries:
		_lib_list.add_child(_make_row(entry))


func _make_row(entry: Dictionary) -> Control:
	var id: String = str(entry["id"])
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = UITheme.CARD_BG
	style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)

	var name_box := VBoxContainer.new()
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_lbl := Label.new()
	name_lbl.text = str(entry["name"])
	UITheme.style_label(name_lbl, UITheme.WHITE_SOFT, 14)
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_box.add_child(name_lbl)
	var has_fs: bool = str(entry.get("funscript_src", "")) != ""
	var meta_lbl := Label.new()
	var secs: int = int(entry.get("duration_ms", 0)) / 1000
	var fs_note: String = "⚠ needs funscript"
	if has_fs:
		fs_note = "%d acts" % int(entry.get("action_count", 0))
	meta_lbl.text = "%d:%02d  •  %s" % [secs / 60, secs % 60, fs_note]
	UITheme.style_label(meta_lbl, UITheme.DARK_TEXT if has_fs else UITheme.AMBER, 11)
	name_box.add_child(meta_lbl)
	row.add_child(name_box)

	# No funscript yet → let the user attach one (drop the file here, or browse via
	# the "..." button). Reuses the builder's DropZone.
	if not has_fs:
		var dz := DropZoneScript.new()
		dz.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS
		dz.picker_title = "Select Funscript"
		dz.picker_filters = ["*.funscript ; Funscripts"]
		dz.custom_minimum_size = Vector2(160, 0)
		dz.file_dropped.connect(
			func(path: String) -> void: RandomizerLibrary.set_funscript(id, path)
		)
		row.add_child(_labeled("add funscript", dz))

	# Tags.
	var tags_field := LineEdit.new()
	tags_field.placeholder_text = "tags,comma"
	tags_field.text = ", ".join(PackedStringArray(entry.get("tags", [])))
	tags_field.custom_minimum_size = Vector2(140, 0)
	tags_field.text_submitted.connect(
		func(t: String) -> void: RandomizerLibrary.update_entry(id, {"tags": _parse_tags(t)})
	)
	row.add_child(_labeled("tags", tags_field))

	# Intensity 1-5.
	var inten := _make_spin(1, 5, int(entry.get("intensity", 3)), 1)
	inten.value_changed.connect(
		func(v: float) -> void: RandomizerLibrary.update_entry(id, {"intensity": int(v)})
	)
	row.add_child(_labeled("intensity", inten))

	# Weight.
	var weight := _make_spin(0.1, 10.0, float(entry.get("weight", 1.0)), 0.1)
	weight.value_changed.connect(
		func(v: float) -> void: RandomizerLibrary.update_entry(id, {"weight": v})
	)
	row.add_child(_labeled("weight", weight))

	var del := UITheme.make_icon_btn("✕", false, UITheme.DANGER)
	del.pressed.connect(func() -> void: RandomizerLibrary.remove_entry(id))
	row.add_child(del)
	return panel


func _parse_tags(text: String) -> Array:
	var out: Array = []
	for raw: String in text.split(","):
		var t: String = raw.strip_edges().to_lower()
		if t != "" and not (t in out):
			out.append(t)
	return out


# ── Add clips ────────────────────────────────────────────────────────────────


func _on_add_pressed() -> void:
	if _busy:
		return
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.filters = _video_filters()
	SettingsService.remember_browse_dir(dialog)  # reopen where the last picker left off
	dialog.files_selected.connect(
		func(paths: PackedStringArray) -> void:
			dialog.queue_free()
			_import_paths(paths)
	)
	dialog.close_requested.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.7)


func _on_folder_pressed() -> void:
	if _busy:
		return
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	SettingsService.remember_browse_dir(dialog)  # reopen where the last picker left off
	dialog.dir_selected.connect(
		func(dir: String) -> void:
			dialog.queue_free()
			_import_paths(PackedStringArray([dir]))
	)
	dialog.close_requested.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.7)


func _on_files_dropped(files: PackedStringArray) -> void:
	if _busy or not is_visible_in_tree():
		return
	_import_paths(files)


func _on_clear_all_pressed() -> void:
	if _busy or RandomizerLibrary.size() == 0:
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Clear Library"
	dialog.dialog_text = (
		(
			"Remove all %d clips from the randomizer library?\n\nThis also deletes their pooled / "
			% RandomizerLibrary.size()
		)
		+ "transcoded files. Your original video files are NOT touched."
	)
	dialog.ok_button_text = "CLEAR ALL"
	dialog.get_ok_button().add_theme_color_override("font_color", UITheme.DANGER)
	dialog.confirmed.connect(
		func() -> void:
			RandomizerLibrary.clear_all()
			_status.text = "Library cleared."
			dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


# Shared import for files, folders, and drops. Expands folders, groups each video
# with its paired funscript + axis/vib scripts (ImportScanner), and pools each into
# the library. Video-less groups are reported as skipped.
func _import_paths(paths: PackedStringArray) -> void:
	if _busy:
		return
	var files: PackedStringArray = ImportScanner.expand_dropped_paths(paths)
	# A drop with no video at all is almost certainly a funscript aimed at a card's
	# drop zone (which handles it separately) — stay silent rather than error.
	if not _has_video(files):
		return
	var res: Dictionary = ImportScanner.build_rounds(files)
	var rounds: Array = res["rounds"]
	if rounds.is_empty():
		_status.text = "No videos found to import."
		return

	_set_busy(true)
	var added: int = 0
	var failed: int = 0
	for r: Dictionary in rounds:
		var nm: String = str(r.get("name", ""))
		_status.text = "Adding %s…" % nm
		# Import is fast now — probe only; transcoding is deferred to Generate.
		var add_res: Dictionary = await RandomizerLibrary.add_clip(
			str(r.get("video_path", "")),
			str(r.get("funscript_path", "")),
			r.get("axis_scripts", {}),
			r.get("vib_scripts", {}),
			[],
			1.0,
			3,
			nm
		)
		if bool(add_res["ok"]):
			added += 1
		else:
			failed += 1
			push_warning("RandomizerScreen: add failed (%s): %s" % [nm, add_res["reason"]])

	_set_busy(false)
	var msg: String = "Added %d clip%s" % [added, "" if added == 1 else "s"]
	if failed > 0:
		msg += ", %d failed" % failed
	var skipped: int = int(res["skipped_no_video"])
	if skipped > 0:
		msg += ", %d skipped (no video)" % skipped
	_status.text = msg + "."


func _video_filters() -> PackedStringArray:
	var globs: String = ""
	for ext: String in VIDEO_EXTS:
		globs += "*." + ext + ","
	return PackedStringArray([globs.trim_suffix(",") + " ; Video files"])


# ── Generate & play ──────────────────────────────────────────────────────────


func _on_generate_pressed() -> void:
	if _busy or _preview_overlay != null:
		return
	if RandomizerLibrary.size() == 0:
		_status.text = "Add at least one clip first."
		return
	_generate_and_preview(false)


# Generates a run (nothing on disk yet — no transcode) and shows the preview
# overlay. `force_random` ignores the seed field so Re-roll always differs.
func _generate_and_preview(force_random: bool) -> void:
	var settings: Dictionary = _read_settings()
	if force_random:
		settings["seed"] = 0
	var res: Dictionary = RandomizerGenerator.generate(RandomizerLibrary.get_all(), settings)
	if not bool(res["ok"]):
		_close_preview()
		_status.text = _reason_text(str(res["reason"]))
		return
	_show_preview(res)


# Plays the previewed run: transcodes only the used clips (deferred from import;
# cached, so a re-rolled repeat skips it), materializes the temp journey, and
# launches it through the normal GameLoop path.
func _play_pending() -> void:
	if _pending_run.is_empty() or _busy:
		return
	var res: Dictionary = _pending_run
	_close_preview()
	_set_busy(true)
	var mat: Dictionary = await _prepare_and_materialize(res)
	if mat.is_empty():
		return  # helper set the status + cleared busy

	var play: Dictionary = JourneyScanner.parse_graph(mat["folder"], mat["folder_name"])
	if play.is_empty():
		_set_busy(false)
		_status.text = "Generated run failed to load."
		return

	GameState.StartJourney(play)
	UISound.start_journey()
	Transition.change_scene("res://scenes/game_loop/GameLoop.tscn")


# Keeps the previewed run as a permanent, self-contained catalogue journey (via
# RandomizerRun.keep) without launching it. Still transcodes the used clips (needed
# to materialize), then copies the run into the journeys folder.
func _keep_pending() -> void:
	if _pending_run.is_empty() or _busy:
		return
	var res: Dictionary = _pending_run
	# Same identity the end-screen Save uses — read straight off the journey Name.
	var run_name: String = str((res["journey"] as Dictionary).get("Name", "Random Run"))
	_close_preview()
	_set_busy(true)
	var mat: Dictionary = await _prepare_and_materialize(res)
	if mat.is_empty():
		return

	var kept: Dictionary = RandomizerRun.keep(mat["folder"], run_name)
	_set_busy(false)
	if bool(kept["ok"]):
		_status.text = 'Saved to your library as "%s".' % run_name
	else:
		_status.text = "Could not save the run (%s)." % str(kept["reason"])


# Transcodes the run's used clips (deferred; cached) and materializes the temp
# journey. Returns the materialize dict on success, or {} on failure/cancel (status
# + busy already handled). Shared by Play and Keep.
func _prepare_and_materialize(res: Dictionary) -> Dictionary:
	if not await _prepare_used_media(res["used_ids"]):
		return {}  # _prepare_used_media set the status + cleared busy
	RandomizerRun.clear_all()  # wipe prior temp runs
	var mat: Dictionary = RandomizerRun.materialize(
		res["journey"], res["content_rels"], RandomizerLibrary.STORE_DIR
	)
	if not bool(mat["ok"]):
		_set_busy(false)
		_status.text = "Could not prepare the run (%s)." % str(mat["reason"])
		return {}
	RandomizerLibrary.mark_used(res["used_ids"])
	return mat


# ── Preview overlay ──────────────────────────────────────────────────────────


# Full-screen preview of a generated run: a read-only map of the journey + a
# summary line, with Play / Re-roll / Back. Rebuilt on each Re-roll.
func _show_preview(res: Dictionary) -> void:
	_close_preview()  # clears _pending_run — reassign it below for Play
	_pending_run = res
	_preview_overlay = Control.new()
	_preview_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_preview_overlay)

	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.0, 0.0, 0.92)
	_preview_overlay.add_child(backdrop)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	_preview_overlay.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "◇ RUN PREVIEW"
	UITheme.style_label(title, UITheme.PURPLE_BRIGHT, 22, true)
	vbox.add_child(title)

	# Map — a Control holder that expands; GraphView fills it via full-rect anchors.
	var holder := Control.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.custom_minimum_size = Vector2(0, 300)
	holder.clip_contents = true
	vbox.add_child(holder)

	var gv: GraphView = GraphViewScene.instantiate()
	gv.map_mode = true
	gv.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(gv)
	gv.set_marker_color(UITheme.PURPLE_BRIGHT)
	gv.set_graph(JourneyGraph.from_json(res["journey"]))

	var summary := Label.new()
	summary.text = _summary_text(res["summary"])
	UITheme.style_label(summary, UITheme.WHITE_SOFT, 14)
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(summary)

	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 14)
	vbox.add_child(btns)

	var play_btn := Button.new()
	play_btn.text = "▶ PLAY"
	UITheme.style_button(play_btn, UITheme.PURPLE_BRIGHT, 24, 12, 16)
	play_btn.pressed.connect(_play_pending)
	btns.add_child(play_btn)

	var keep_btn := Button.new()
	keep_btn.text = "★ KEEP"
	keep_btn.tooltip_text = "Save this run to your journey library to replay later"
	UITheme.style_button(keep_btn, UITheme.AMBER, 20, 12, 16)
	keep_btn.pressed.connect(_keep_pending)
	btns.add_child(keep_btn)

	var reroll_btn := Button.new()
	reroll_btn.text = "🎲 RE-ROLL"
	UITheme.style_button(reroll_btn, UITheme.CYAN, 20, 12, 16)
	reroll_btn.pressed.connect(func() -> void: _generate_and_preview(true))
	btns.add_child(reroll_btn)

	var back_btn := Button.new()
	back_btn.text = "✕ BACK"
	UITheme.style_button(back_btn, UITheme.PURPLE_MID, 20, 12, 16)
	back_btn.pressed.connect(_close_preview)
	btns.add_child(back_btn)

	# Frame the whole graph once the holder has its real size (after layout).
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(gv):
		gv.fit_to_view()


func _close_preview() -> void:
	_pending_run = {}
	if _preview_overlay != null:
		_preview_overlay.queue_free()
		_preview_overlay = null


func _summary_text(s: Dictionary) -> String:
	var total_s: int = int(s.get("est_length_ms", 0)) / 1000
	var parts: Array = ["%d rounds" % int(s.get("rounds", 0))]
	if int(s.get("effects", 0)) > 0:
		parts.append("%d effect" % int(s["effects"]))
	if int(s.get("bosses", 0)) > 0:
		parts.append("boss finale")
	if int(s.get("shops", 0)) > 0:
		parts.append("%d shop" % int(s["shops"]))
	parts.append("~%d:%02d of video" % [total_s / 60, total_s % 60])
	return "%s     •     seed %d" % [" · ".join(parts), int(s.get("seed", 0))]


# Pools (transcoding as needed) every clip the generated run uses. On any failure,
# aborts with a message naming the offenders (usually a moved/deleted source, since
# pooling is deferred to now). Returns true when all are ready. Keeps _busy set on
# success (the caller proceeds to launch); clears it on failure.
func _prepare_used_media(used_ids: Array) -> bool:
	_cancel_requested = false
	_cancel_btn.visible = true
	var failures: Array = []
	for uid: Variant in used_ids:
		if _cancel_requested:
			return _abort_prepare("Cancelled.")
		var entry: Dictionary = RandomizerLibrary.get_entry(str(uid))
		if entry.is_empty():
			continue
		var nm: String = str(entry.get("name", ""))
		_status.text = "Preparing %s…" % nm
		var pr: Dictionary = await RandomizerLibrary.prepare_entry_media(
			entry,
			func(frac: float, _cur: float, _tot: float, _spd: String) -> void:
				_status.text = "Transcoding %s… %d%%" % [nm, int(frac * 100.0)],
			func() -> bool: return _cancel_requested
		)
		if _cancel_requested:
			return _abort_prepare("Cancelled.")
		if not bool(pr["ok"]):
			failures.append("%s (%s)" % [nm, str(pr["reason"])])
	_cancel_btn.visible = false
	if not failures.is_empty():
		_set_busy(false)
		_status.text = (
			"Couldn't prepare: %s. Remove or re-import those clips." % ", ".join(failures)
		)
		return false
	return true


# Common exit when preparation is cancelled: hide the cancel button, clear busy,
# and show `msg`. Returns false so the caller bails out of the run.
func _abort_prepare(msg: String) -> bool:
	_cancel_btn.visible = false
	_set_busy(false)
	_status.text = msg
	return false


func _has_video(files: PackedStringArray) -> bool:
	for f: String in files:
		if f.get_extension().to_lower() in VIDEO_EXTS:
			return true
	return false


func _read_settings() -> Dictionary:
	var seed_val: int = 0
	var seed_txt: String = _seed_field.text.strip_edges()
	if seed_txt != "" and seed_txt.is_valid_int():
		seed_val = seed_txt.to_int()
	return {
		"seed": seed_val,
		"length_mode": "time" if _mode_opt.selected == 1 else "count",
		"round_count": int(_count_spin.value),
		"target_minutes": float(_time_spin.value),
		"effect_pct": _effect_slider.value / 100.0,
		"boss_finale": _boss_check.button_pressed,
		"intensity_order": _intensity_check.button_pressed,
		"shop_every": int(_shop_spin.value),
	}


func _reason_text(reason: String) -> String:
	match reason:
		"empty_library":
			return "The library is empty."
		"no_matches":
			return "No clips match the current tag filter."
		_:
			return "Could not generate a run (%s)." % reason


func _set_busy(busy: bool) -> void:
	_busy = busy
	_generate_btn.disabled = busy
