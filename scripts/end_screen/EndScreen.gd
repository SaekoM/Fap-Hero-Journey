extends Control

# ---------------------------------------------------------------------------
# EndScreen.gd  –  Journey completion celebration
# Reads stats from GameState / ScoreService and reveals them as a staged
# celebration: the title pops in, a hero score counts up (with a confetti
# burst), stats tally, and the per-round breakdown cascades in.
# ---------------------------------------------------------------------------

const PANEL_HALF_W: int = 440
const BORDER_WIDTH: int = 3
const LOG_INDENT_PX: int = 14  # pixels of left indent per fork-nesting depth
const ROUTE_PANE_HEIGHT: int = 220

const GraphViewScene: PackedScene = preload("res://scenes/graph_view/GraphView.tscn")

@onready var _bg: ColorRect = $Background
@onready var _panel: PanelContainer = $Panel
@onready var _vbox: VBoxContainer = $Panel/VBox
@onready var _title_lbl: Label = $Panel/VBox/TitleLabel
@onready var _journey_lbl: Label = $Panel/VBox/JourneyLabel
@onready var _divider: HSeparator = $Panel/VBox/StatsDivider
@onready var _stats_row: HBoxContainer = $Panel/VBox/StatsRow
@onready var _stat_rounds: Label = $Panel/VBox/StatsRow/StatRounds
@onready var _stat_actions: Label = $Panel/VBox/StatsRow/StatActions
@onready var _stat_time: Label = $Panel/VBox/StatsRow/StatTime
@onready var _score_divider: HSeparator = $Panel/VBox/ScoreDivider
@onready var _score_title: Label = $Panel/VBox/ScoreSection/ScoreTitle
@onready var _round_breakdown: VBoxContainer = $Panel/VBox/ScoreSection/RoundBreakdownContainer
@onready var _total_score_val: Label = $Panel/VBox/ScoreSection/TotalScoreRow/TotalScoreValue
@onready var _back_btn: Button = $Panel/VBox/BackButton

# Built in code: the hero score block + the confetti burst.
var _hero_box: VBoxContainer = null
var _hero_score: Label = null
var _confetti: CPUParticles2D = null

# Route recap (the run's path on the journey map) + high-score flash.
var _split: HBoxContainer = null  # two-column layout: details left, route right
var _route_box: VBoxContainer = null
var _route_view: Control = null  # GraphView in map_mode
var _hs_label: Label = null
var _run_rank: int = 0  # 1-based scoreboard rank of this run (0 = off-board)

# Reveal targets — the final values the count-up animations climb to.
var _score_target: int = 0
var _rounds_target: int = 0
var _actions_target: int = 0
var _time_target: int = 0  # seconds


func _ready() -> void:
	UISound.game_complete()
	_apply_layout()
	_apply_theme()
	_build_confetti()
	_populate()
	_back_btn.pressed.connect(_on_back_pressed)
	_maybe_add_save_run_button()
	_play_reveal()


func _populate() -> void:
	var journey: Dictionary = GameState.Journey
	_title_lbl.text = "JOURNEY COMPLETE"
	_journey_lbl.text = (journey.get("title", "Journey") as String).to_upper()

	# Use the actual played rounds from the log (fork paths may differ from
	# the catalogue's top-level round list).
	var log: Array = GameState.GetPlayLog()
	var played_rounds: Array = log.filter(
		func(e: Dictionary) -> bool: return e.get("type", "") == "round"
	)
	var total_actions: int = ScoreService.GetRoundBreakdowns().reduce(
		func(acc: int, b: Dictionary) -> int: return acc + b.get("actions", 0), 0
	)
	var total_ms: int = played_rounds.reduce(
		func(acc: int, e: Dictionary) -> int: return acc + e.get("length_ms", 0) as int, 0
	)

	# Store reveal targets — the labels start at zero and count up to these.
	_score_target = ScoreService.TotalScore
	_rounds_target = played_rounds.size()
	_actions_target = total_actions
	_time_target = total_ms / 1000

	_hero_score.text = "0 PTS"
	_stat_rounds.text = "0 ROUNDS"
	_stat_actions.text = "0 ACTIONS"
	_stat_time.text = "0:00"

	# Scoreboard rank of this run, stashed by GameLoop._record_run. Read once.
	_run_rank = int(GameState.get_meta("_run_rank", 0))
	if GameState.has_meta("_run_rank"):
		GameState.remove_meta("_run_rank")
	if _run_rank == 1:
		_hs_label.text = "★  NEW HIGH SCORE  ★"
	elif _run_rank > 1:
		_hs_label.text = "★  HIGH SCORE #%d" % _run_rank

	_populate_route()
	_populate_score()


# Renders the journey graph with this run's path glowing (roads not taken
# ghosted) and the ending marked. FULL reveal by design — the run is over, so
# map-disabled / fogged journeys show their whole structure here and nowhere
# else. Hides the section for empty trails (defensive) or single-node journeys.
func _populate_route() -> void:
	var trail: Array = GameState.get_meta("_route_trail", [])
	var nodes: Dictionary = GameState.Journey.get("nodes", {}) as Dictionary
	if trail.is_empty() or nodes.size() < 2:
		_route_box.visible = false
		return
	# Same graph prep as GameLoop's map viewer: copy the nodes, seed positions
	# for legacy (migrated) journeys that lack them.
	var map_graph: Dictionary = {
		"start": str(GameState.Journey.get("start", "")),
		"nodes": nodes.duplicate(true),
	}
	for nid: String in map_graph["nodes"]:
		if not (map_graph["nodes"][nid] as Dictionary).has("pos"):
			GraphLayout.seed_positions(map_graph)
			break
	_route_view.set_graph(map_graph)
	_route_view.set_route(trail)
	_route_view.set_marker_at(str(trail[-1]))
	# Frame the whole structure once the pane has its size.
	_route_view.call_deferred("fit_to_view")


# Wraps `row` in a MarginContainer with `depth * LOG_INDENT_PX` of left padding.
# Returns `row` unchanged when depth is 0 to avoid an extra node allocation.
func _indent_row(row: Control, depth: int) -> Control:
	if depth == 0:
		return row
	var mc: MarginContainer = MarginContainer.new()
	mc.add_theme_constant_override("margin_left", depth * LOG_INDENT_PX)
	mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.add_child(row)
	return mc


func _populate_score() -> void:
	var breakdowns: Array = ScoreService.GetRoundBreakdowns()
	var play_log: Array = GameState.GetPlayLog()
	# GDScript-side round names, populated by GameLoop._on_round_ended.
	var round_names: PackedStringArray = (
		GameState.get_meta("_round_names", PackedStringArray()) as PackedStringArray
	)
	_total_score_val.text = str(ScoreService.TotalScore) + " PTS"

	var round_num: int = 0  # 1-based counter across all played rounds
	var bd_idx: int = 0  # index into breakdowns (one per round in log order)

	for entry: Dictionary in play_log:
		match entry.get("type", ""):
			# ── Fork-choice header ────────────────────────────────────────────
			"fork_choice":
				var depth: int = entry.get("depth", 0) as int
				var fork_title: String = entry.get("fork_title", "")
				var path_name: String = entry.get("path_name", "")

				var sep: HSeparator = HSeparator.new()
				var sep_s: StyleBoxFlat = StyleBoxFlat.new()
				sep_s.bg_color = Color(
					UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.35
				)
				sep_s.content_margin_top = 1
				sep_s.content_margin_bottom = 1
				sep.add_theme_stylebox_override("separator", sep_s)
				_round_breakdown.add_child(_indent_row(sep, depth))

				var hdr: HBoxContainer = HBoxContainer.new()
				hdr.add_theme_constant_override("separation", 8)
				hdr.alignment = BoxContainer.ALIGNMENT_CENTER
				var icon_lbl: Label = Label.new()
				icon_lbl.text = "⑂"
				icon_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
				icon_lbl.add_theme_font_size_override("font_size", 16)
				hdr.add_child(icon_lbl)
				var hdr_lbl: Label = Label.new()
				if fork_title != "":
					hdr_lbl.text = "%s  →  %s" % [fork_title.to_upper(), path_name.to_upper()]
				else:
					hdr_lbl.text = "FORK  →  %s" % path_name.to_upper()
				hdr_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
				hdr_lbl.add_theme_font_size_override("font_size", 13)
				hdr_lbl.uppercase = true
				hdr.add_child(hdr_lbl)
				_round_breakdown.add_child(_indent_row(hdr, depth))

			# ── Round row ─────────────────────────────────────────────────────
			"round":
				var depth: int = entry.get("depth", 0) as int
				round_num += 1
				var breakdown: Dictionary = breakdowns[bd_idx] if bd_idx < breakdowns.size() else {}
				bd_idx += 1

				var row: HBoxContainer = HBoxContainer.new()
				row.add_theme_constant_override("separation", 20)
				# Centre the row's content as a cluster rather than spreading the
				# name hard-left and the stats hard-right across the panel width.
				row.alignment = BoxContainer.ALIGNMENT_CENTER

				var name_lbl: Label = Label.new()
				# Round name comes from the GDScript-side log (set in GameLoop). Falls back
				# to the C# play-log entry, then to a numeric placeholder.
				var rname: String = ""
				if (round_num - 1) < round_names.size():
					rname = round_names[round_num - 1]
				if rname == "":
					rname = entry.get("name", "") as String
				if rname == "":
					rname = "Round %d" % round_num
				# A skipped round keeps its place in the route and says so, rather than being
				# hidden — the run should stay honest about what was actually played.
				var was_skipped: bool = bool(entry.get("skipped", false))
				name_lbl.text = (
					"R%d  %s%s"
					% [round_num, rname.to_upper(), "   ⏭ SKIPPED" if was_skipped else ""]
				)
				name_lbl.add_theme_color_override(
					"font_color", UITheme.SEPARATOR if was_skipped else UITheme.WHITE_SOFT
				)
				name_lbl.add_theme_font_size_override("font_size", 17)

				var time_lbl: Label = Label.new()
				var secs: int = (entry.get("length_ms", 0) as int) / 1000
				time_lbl.text = _fmt(secs)
				time_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
				time_lbl.add_theme_font_size_override("font_size", 15)

				var act_lbl: Label = Label.new()
				act_lbl.text = "%d ACTIONS" % breakdown.get("actions", 0)
				act_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
				act_lbl.add_theme_font_size_override("font_size", 15)

				var detail_lbl: Label = Label.new()
				detail_lbl.text = (
					"%dS %dM %dL"
					% [
						breakdown.get("small", 0),
						breakdown.get("medium", 0),
						breakdown.get("large", 0)
					]
				)
				detail_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
				detail_lbl.add_theme_font_size_override("font_size", 15)

				var pts_lbl: Label = Label.new()
				pts_lbl.text = str(breakdown.get("score", 0)) + " PTS"
				pts_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
				pts_lbl.add_theme_font_size_override("font_size", 17)

				row.add_child(name_lbl)
				row.add_child(time_lbl)
				row.add_child(act_lbl)
				row.add_child(detail_lbl)
				row.add_child(pts_lbl)
				_round_breakdown.add_child(_indent_row(row, depth))


# ---------------------------------------------------------------------------
# Reveal — the staged celebration
# ---------------------------------------------------------------------------


# Hides every revealable element, then animates them in one stage at a time.
func _play_reveal() -> void:
	# Start everything hidden.
	for node: CanvasItem in [
		_title_lbl,
		_journey_lbl,
		_hero_box,
		_divider,
		_stats_row,
		_route_box,
		_score_divider,
		_score_title,
		_back_btn,
	]:
		node.modulate.a = 0.0
	for row: Node in _round_breakdown.get_children():
		(row as CanvasItem).modulate.a = 0.0
	_back_btn.disabled = true  # not clickable until the reveal finishes

	# Let the container layout settle (so scale pivots are correct) and give the
	# scene-transition fade a moment to clear before the celebration begins.
	await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout
	_title_lbl.pivot_offset = _title_lbl.size / 2.0

	# 1. Title — fade + pop.
	_title_lbl.scale = Vector2(0.8, 0.8)
	var t1: Tween = create_tween().set_parallel()
	t1.tween_property(_title_lbl, "modulate:a", 1.0, 0.35)
	t1.tween_property(_title_lbl, "scale", Vector2.ONE, 0.45).set_ease(Tween.EASE_OUT).set_trans(
		Tween.TRANS_BACK
	)
	await t1.finished

	# 2. Journey name.
	var t2: Tween = create_tween()
	t2.tween_property(_journey_lbl, "modulate:a", 1.0, 0.25)
	await t2.finished

	# 3. Hero score — fade the block in while the number counts up.
	var t3: Tween = create_tween().set_parallel()
	t3.tween_property(_hero_box, "modulate:a", 1.0, 0.2)
	(
		t3
		. tween_method(
			func(v: float) -> void: _hero_score.text = "%d PTS" % int(v),
			0.0,
			float(_score_target),
			1.1
		)
		. set_ease(Tween.EASE_OUT)
		. set_trans(Tween.TRANS_CUBIC)
	)
	await t3.finished
	_hero_score.text = "%d PTS" % _score_target

	# Confetti + a punchy pop on the final number.
	_confetti.restart()
	_hero_score.pivot_offset = _hero_score.size / 2.0
	var t3b: Tween = create_tween()
	t3b.tween_property(_hero_score, "scale", Vector2(1.12, 1.12), 0.12)
	t3b.tween_property(_hero_score, "scale", Vector2.ONE, 0.20).set_ease(Tween.EASE_OUT).set_trans(
		Tween.TRANS_BACK
	)

	# 3b. High-score flash — pops in under the hero score when the run ranked,
	# with a second confetti burst for a new best.
	if _run_rank > 0:
		_hs_label.modulate.a = 0.0
		_hs_label.visible = true
		await get_tree().process_frame  # let it get a size for the pivot
		_hs_label.pivot_offset = _hs_label.size / 2.0
		_hs_label.scale = Vector2(0.6, 0.6)
		if _run_rank == 1:
			_confetti.restart()
		UISound.game_complete()
		var t_hs: Tween = create_tween().set_parallel()
		t_hs.tween_property(_hs_label, "modulate:a", 1.0, 0.2)
		(
			t_hs
			. tween_property(_hs_label, "scale", Vector2.ONE, 0.35)
			. set_ease(Tween.EASE_OUT)
			. set_trans(Tween.TRANS_BACK)
		)
		await t_hs.finished

	# 4. Stats — fade in, then tally each value up.
	var t4: Tween = create_tween().set_parallel()
	t4.tween_property(_divider, "modulate:a", 1.0, 0.25)
	t4.tween_property(_stats_row, "modulate:a", 1.0, 0.25)
	await t4.finished
	var t5: Tween = create_tween().set_parallel()
	t5.tween_method(
		func(v: float) -> void: _stat_rounds.text = "%d ROUNDS" % int(v),
		0.0,
		float(_rounds_target),
		0.5
	)
	t5.tween_method(
		func(v: float) -> void: _stat_actions.text = "%d ACTIONS" % int(v),
		0.0,
		float(_actions_target),
		0.6
	)
	t5.tween_method(
		func(v: float) -> void: _stat_time.text = _fmt(int(v)), 0.0, float(_time_target), 0.6
	)
	await t5.finished

	# 4b. Route recap — the map fades in framed on the whole journey, the
	# taken path glowing and the roads not taken ghosted.
	if _route_box.visible:
		_route_view.fit_to_view()
		var t_route: Tween = create_tween()
		t_route.tween_property(_route_box, "modulate:a", 1.0, 0.35)
		await t_route.finished

	# 5. Score section header, then cascade the breakdown rows.
	var t6: Tween = create_tween().set_parallel()
	t6.tween_property(_score_divider, "modulate:a", 1.0, 0.25)
	t6.tween_property(_score_title, "modulate:a", 1.0, 0.25)
	await t6.finished
	var rows: Array = _round_breakdown.get_children()
	for i: int in rows.size():
		create_tween().tween_property(rows[i], "modulate:a", 1.0, 0.22).set_delay(i * 0.05)
	if not rows.is_empty():
		await get_tree().create_timer(0.22 + rows.size() * 0.05).timeout

	# 6. Back button.
	_back_btn.disabled = false
	create_tween().tween_property(_back_btn, "modulate:a", 1.0, 0.25)


# Builds the confetti burst — a one-shot rain of theme-coloured squares fired
# from above the screen when the hero score lands.
func _build_confetti() -> void:
	_confetti = CPUParticles2D.new()
	_confetti.emitting = false
	_confetti.one_shot = true
	_confetti.amount = 90
	_confetti.lifetime = 2.6
	_confetti.explosiveness = 0.35
	_confetti.direction = Vector2(0, 1)
	_confetti.spread = 35.0
	_confetti.gravity = Vector2(0, 430)
	_confetti.initial_velocity_min = 140.0
	_confetti.initial_velocity_max = 280.0
	_confetti.angular_velocity_min = -260.0
	_confetti.angular_velocity_max = 260.0
	_confetti.scale_amount_min = 5.0
	_confetti.scale_amount_max = 11.0
	_confetti.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE

	# Distinct theme colours — constant interpolation gives crisp confetti hues.
	var grad: Gradient = Gradient.new()
	grad.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	grad.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75])
	grad.colors = PackedColorArray(
		[
			UITheme.PURPLE_BRIGHT,
			UITheme.MAGENTA,
			UITheme.CYAN,
			UITheme.AMBER,
		]
	)
	_confetti.color_initial_ramp = grad

	add_child(_confetti)

	# Emit along a wide strip just above the top edge so confetti rains down.
	var vp: Vector2 = get_viewport_rect().size
	_confetti.position = Vector2(vp.x * 0.5, -20.0)
	_confetti.emission_rect_extents = Vector2(vp.x * 0.5, 8.0)


func _fmt(total_seconds: int) -> String:
	var h: int = total_seconds / 3600
	var m: int = (total_seconds % 3600) / 60
	var s: int = total_seconds % 60
	return "%d:%02d:%02d" % [h, m, s] if h > 0 else "%d:%02d" % [m, s]


func _on_back_pressed() -> void:
	Transition.change_scene("res://scenes/journey_select/JourneySelect.tscn")


# Randomized runs are ephemeral (their temp folder is wiped on the next generate),
# so offer to keep the one just finished as a permanent catalogue journey. Only
# shown when this journey is a live randomizer run — detected by its folder living
# under RandomizerRun.RUNS_DIR — and only while that temp folder still exists.
func _maybe_add_save_run_button() -> void:
	var folder: String = str(GameState.Journey.get("folder", ""))
	if not folder.begins_with(RandomizerRun.RUNS_DIR):
		return
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)):
		return
	# Still baking (or never finished): the sweep discards this run on the next app
	# start anyway, so don't offer a button whose keep() would just refuse it.
	if FileAccess.file_exists(
		ProjectSettings.globalize_path(folder + "/" + RandomizerRun.UNFINISHED_MARKER)
	):
		return
	var save_btn := Button.new()
	save_btn.text = "★ SAVE THIS RUN"
	save_btn.tooltip_text = "Add this randomized run to your journey library to replay later"
	UITheme.style_button(save_btn, UITheme.AMBER, 20, 14)
	var parent: Node = _back_btn.get_parent()
	parent.add_child(save_btn)
	parent.move_child(save_btn, _back_btn.get_index())  # sit just above Back to Menu
	save_btn.pressed.connect(_on_save_run_pressed.bind(save_btn, folder))


func _on_save_run_pressed(btn: Button, folder: String) -> void:
	btn.disabled = true
	btn.text = "SAVING…"
	await get_tree().process_frame  # let the label repaint before the blocking copy
	# Match the preview's Keep: use the run's own journey Name (carries the seed).
	var run_name: String = str(GameState.Journey.get("title", "Random Run"))
	var res: Dictionary = RandomizerRun.keep(folder, run_name)
	if bool(res["ok"]):
		btn.text = "SAVED ✓"
	else:
		btn.text = "SAVE FAILED — TRY AGAIN"
		btn.disabled = false


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

	# Viewport-bounded panel so it never overflows regardless of journey length.
	# Wider than the old single-column layout — it now hosts the two-column split.
	_panel.anchor_left = 0.05
	_panel.anchor_right = 0.95
	_panel.anchor_top = 0.04
	_panel.anchor_bottom = 0.96
	_panel.offset_left = 0.0
	_panel.offset_right = 0.0
	_panel.offset_top = 0.0
	_panel.offset_bottom = 0.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(PANEL_HALF_W * 2, 0)

	# ── Two-column split: score/details on the left, the route map on the
	# right at full height. The scene-defined VBox becomes the left column;
	# when the route section hides (no trail), the left column takes it all.
	_split = HBoxContainer.new()
	_split.add_theme_constant_override("separation", 28)
	_panel.remove_child(_vbox)
	_split.add_child(_vbox)
	_panel.add_child(_split)
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.size_flags_stretch_ratio = 1.15

	_vbox.add_theme_constant_override("separation", 16)
	_stats_row.add_theme_constant_override("separation", 0)

	# ── Hero score block — caption + huge total, inserted under the journey name.
	_hero_box = VBoxContainer.new()
	_hero_box.add_theme_constant_override("separation", 2)

	var hero_caption: Label = Label.new()
	hero_caption.text = "FINAL SCORE"
	hero_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hero_caption.add_theme_color_override("font_color", UITheme.PURPLE_MID)
	hero_caption.add_theme_font_size_override("font_size", 13)
	hero_caption.uppercase = true
	_hero_box.add_child(hero_caption)

	_hero_score = Label.new()
	_hero_score.text = "0 PTS"
	_hero_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hero_score.add_theme_color_override("font_color", UITheme.MAGENTA)
	_hero_score.add_theme_font_size_override("font_size", 64)
	_hero_score.uppercase = true
	_hero_box.add_child(_hero_score)

	# High-score flash — revealed with a pop after the hero score lands, only
	# when the run ranked on the journey's scoreboard.
	_hs_label = Label.new()
	_hs_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hs_label.add_theme_color_override("font_color", UITheme.AMBER)
	_hs_label.add_theme_font_size_override("font_size", 20)
	_hs_label.uppercase = true
	_hs_label.visible = false
	_hero_box.add_child(_hs_label)

	_vbox.add_child(_hero_box)
	_vbox.move_child(_hero_box, _journey_lbl.get_index() + 1)

	# ── Route recap — the journey map with this run's path glowing, filling
	# the split's right column top to bottom.
	_route_box = VBoxContainer.new()
	_route_box.add_theme_constant_override("separation", 6)
	_route_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_route_box.size_flags_stretch_ratio = 0.85
	var route_caption: Label = Label.new()
	route_caption.text = "YOUR ROUTE"
	route_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	route_caption.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	route_caption.add_theme_font_size_override("font_size", 15)
	route_caption.uppercase = true
	_route_box.add_child(route_caption)

	var route_pane: PanelContainer = PanelContainer.new()
	var rp_style: StyleBoxFlat = StyleBoxFlat.new()
	rp_style.bg_color = UITheme.CARD_BG
	rp_style.border_color = UITheme.PURPLE_DARK
	rp_style.set_border_width_all(1)
	rp_style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	route_pane.add_theme_stylebox_override("panel", rp_style)
	route_pane.custom_minimum_size = Vector2(320, ROUTE_PANE_HEIGHT)
	route_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	route_pane.clip_contents = true
	_route_box.add_child(route_pane)

	_route_view = GraphViewScene.instantiate()
	_route_view.map_mode = true
	route_pane.add_child(_route_view)
	_split.add_child(_route_box)

	# NOTE: _vbox was reparented into the split above, so $Panel/VBox/... paths
	# no longer resolve — look up relative to the moved node instead.
	var score_section: VBoxContainer = _vbox.get_node("ScoreSection")
	score_section.add_theme_constant_override("separation", 12)
	score_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_round_breakdown.add_theme_constant_override("separation", 6)

	# The hero block is now the headline total — hide the small footer row.
	score_section.get_node("TotalScoreRow").visible = false

	# Wrap the breakdown in a ScrollContainer so a long journey scrolls rather
	# than growing the panel off screen.
	var breakdown_scroll: ScrollContainer = ScrollContainer.new()
	breakdown_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	breakdown_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	breakdown_scroll.custom_minimum_size = Vector2(0, 220)
	score_section.remove_child(_round_breakdown)
	breakdown_scroll.add_child(_round_breakdown)
	score_section.add_child(breakdown_scroll)
	# Re-order: ScoreTitle(0), ScrollContainer(1), TotalScoreRow(2)
	score_section.move_child(breakdown_scroll, 1)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------


func _apply_theme() -> void:
	_bg.color = UITheme.BG

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.PANEL_BG
	s.border_color = UITheme.PURPLE_BRIGHT
	s.border_width_left = BORDER_WIDTH
	s.border_width_right = BORDER_WIDTH
	s.border_width_top = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left = 4
	s.corner_radius_top_right = 4
	s.corner_radius_bottom_left = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.5)
	s.shadow_size = 16
	s.content_margin_left = 48
	s.content_margin_right = 48
	s.content_margin_top = 48
	s.content_margin_bottom = 48
	_panel.add_theme_stylebox_override("panel", s)

	_title_lbl.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	_title_lbl.add_theme_font_size_override("font_size", 36)
	_title_lbl.uppercase = true

	_journey_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	_journey_lbl.add_theme_font_size_override("font_size", 18)
	_journey_lbl.uppercase = true

	var sep: StyleBoxFlat = StyleBoxFlat.new()
	sep.bg_color = UITheme.SEPARATOR
	sep.content_margin_top = 1
	sep.content_margin_bottom = 1
	_divider.add_theme_stylebox_override("separator", sep)

	for lbl: Label in [_stat_rounds, _stat_actions, _stat_time]:
		lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
		lbl.add_theme_font_size_override("font_size", 15)
		lbl.uppercase = true

	var score_sep: StyleBoxFlat = StyleBoxFlat.new()
	score_sep.bg_color = UITheme.SEPARATOR
	score_sep.content_margin_top = 1
	score_sep.content_margin_bottom = 1
	_score_divider.add_theme_stylebox_override("separator", score_sep)

	_score_title.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	_score_title.add_theme_font_size_override("font_size", 18)
	_score_title.uppercase = true
	_score_title.text = "ROUND BREAKDOWN"

	UITheme.style_button(_back_btn, UITheme.PURPLE_BRIGHT, 20, 14)
