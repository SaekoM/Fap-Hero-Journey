extends Control

# ---------------------------------------------------------------------------
# EndScreen.gd  –  Journey completion screen
# Reads stats from GameState.journey and displays a summary before returning
# the player to the Journey Select catalogue.
# ---------------------------------------------------------------------------

const COLOR_BG:           Color = Color(0.0,   0.0,   0.0,   1.0)
const COLOR_PANEL_BG:     Color = Color(0.055, 0.008, 0.086, 1.0)
const COLOR_PURPLE_BRIGHT:Color = Color(0.698, 0.118, 1.0,   1.0)
const COLOR_PURPLE_MID:   Color = Color(0.408, 0.063, 0.627, 1.0)
const COLOR_PURPLE_DARK:  Color = Color(0.176, 0.024, 0.259, 1.0)
const COLOR_MAGENTA:      Color = Color(0.878, 0.0,   0.878, 1.0)
const COLOR_WHITE_SOFT:   Color = Color(0.878, 0.780, 1.0,   1.0)
const COLOR_SEPARATOR:    Color = Color(0.698, 0.118, 1.0,   0.5)

const PANEL_HALF_W: int = 440
const BORDER_WIDTH: int = 3

@onready var _bg:           ColorRect     = $Background
@onready var _panel:        PanelContainer = $Panel
@onready var _vbox:         VBoxContainer  = $Panel/VBox
@onready var _title_lbl:    Label          = $Panel/VBox/TitleLabel
@onready var _journey_lbl:  Label          = $Panel/VBox/JourneyLabel
@onready var _divider:      HSeparator     = $Panel/VBox/StatsDivider
@onready var _stats_row:    HBoxContainer  = $Panel/VBox/StatsRow
@onready var _stat_rounds:  Label          = $Panel/VBox/StatsRow/StatRounds
@onready var _stat_actions: Label          = $Panel/VBox/StatsRow/StatActions
@onready var _stat_time:    Label          = $Panel/VBox/StatsRow/StatTime
@onready var _score_divider:    HSeparator    = $Panel/VBox/ScoreDivider
@onready var _score_title:      Label         = $Panel/VBox/ScoreSection/ScoreTitle
@onready var _round_breakdown:  VBoxContainer = $Panel/VBox/ScoreSection/RoundBreakdownContainer
@onready var _total_score_lbl: Label         = $Panel/VBox/ScoreSection/TotalScoreRow/TotalScoreLabel
@onready var _total_score_val: Label         = $Panel/VBox/ScoreSection/TotalScoreRow/TotalScoreValue
@onready var _back_btn:        Button        = $Panel/VBox/BackButton


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_populate()
	_back_btn.pressed.connect(_on_back_pressed)


func _populate() -> void:
	var j: Dictionary = GameState.Journey
	_journey_lbl.text  = (j.get("title", "Journey") as String).to_upper()
	_stat_rounds.text  = str(j.get("rounds", []).size()) + " ROUNDS"
	_stat_actions.text = str(j.get("total_actions", 0)) + " ACTIONS"
	var secs: int = (j.get("total_length_ms", 0) as int) / 1000
	_stat_time.text = _fmt(secs)
	_populate_score()


func _populate_score() -> void:
	var breakdowns: Array = ScoreService.GetRoundBreakdowns()
	var rounds: Array = GameState.Journey.get("rounds", [])
	_total_score_val.text = str(ScoreService.TotalScore) + " PTS"

	for i: int in breakdowns.size():
		var r: Dictionary = breakdowns[i]
		var rd: Dictionary = rounds[i] if i < rounds.size() else {}
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)

		var name_lbl: Label = Label.new()
		var rname: String = (rd.get("name", "Round %d" % (i + 1)) as String).to_upper()
		name_lbl.text = "R%d  %s" % [i + 1, rname]
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_lbl.add_theme_color_override("font_color", COLOR_WHITE_SOFT)
		name_lbl.add_theme_font_size_override("font_size", 13)

		var time_lbl: Label = Label.new()
		var secs: int = (rd.get("length_ms", 0) as int) / 1000
		time_lbl.text = _fmt(secs)
		time_lbl.add_theme_color_override("font_color", COLOR_PURPLE_MID)
		time_lbl.add_theme_font_size_override("font_size", 12)

		var act_lbl: Label = Label.new()
		act_lbl.text = "%d ACTIONS" % r["actions"]
		act_lbl.add_theme_color_override("font_color", COLOR_PURPLE_MID)
		act_lbl.add_theme_font_size_override("font_size", 12)

		var detail_lbl: Label = Label.new()
		detail_lbl.text = "%dS %dM %dL" % [r["small"], r["medium"], r["large"]]
		detail_lbl.add_theme_color_override("font_color", COLOR_PURPLE_MID)
		detail_lbl.add_theme_font_size_override("font_size", 12)

		var pts_lbl: Label = Label.new()
		pts_lbl.text = str(r["score"]) + " PTS"
		pts_lbl.add_theme_color_override("font_color", COLOR_MAGENTA)
		pts_lbl.add_theme_font_size_override("font_size", 13)

		row.add_child(name_lbl)
		row.add_child(time_lbl)
		row.add_child(act_lbl)
		row.add_child(detail_lbl)
		row.add_child(pts_lbl)
		_round_breakdown.add_child(row)


func _fmt(total_seconds: int) -> String:
	var h: int = total_seconds / 3600
	var m: int = (total_seconds % 3600) / 60
	var s: int = total_seconds % 60
	return "%d:%02d:%02d" % [h, m, s] if h > 0 else "%d:%02d" % [m, s]


func _on_back_pressed() -> void:
	Transition.change_scene("res://scenes/journey_select/JourneySelect.tscn")


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right  = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left   = 0
	_bg.offset_top    = 0
	_bg.offset_right  = 0
	_bg.offset_bottom = 0

	var animated_bg: Control = $AnimatedBackground
	animated_bg.anchor_right  = 1.0
	animated_bg.anchor_bottom = 1.0

	_panel.anchor_left   = 0.5
	_panel.anchor_right  = 0.5
	_panel.anchor_top    = 0.5
	_panel.anchor_bottom = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical   = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(PANEL_HALF_W * 2, 0)

	_vbox.add_theme_constant_override("separation", 20)
	_stats_row.add_theme_constant_override("separation", 0)
	$Panel/VBox/ScoreSection.add_theme_constant_override("separation", 12)
	$Panel/VBox/ScoreSection/TotalScoreRow.add_theme_constant_override("separation", 16)
	_round_breakdown.add_theme_constant_override("separation", 6)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = COLOR_BG

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color                   = COLOR_PANEL_BG
	s.border_color               = COLOR_PURPLE_BRIGHT
	s.border_width_left          = BORDER_WIDTH
	s.border_width_right         = BORDER_WIDTH
	s.border_width_top           = BORDER_WIDTH
	s.border_width_bottom        = BORDER_WIDTH
	s.corner_radius_top_left     = 4
	s.corner_radius_top_right    = 4
	s.corner_radius_bottom_left  = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color               = Color(COLOR_MAGENTA.r, COLOR_MAGENTA.g, COLOR_MAGENTA.b, 0.5)
	s.shadow_size                = 16
	s.content_margin_left        = 48
	s.content_margin_right       = 48
	s.content_margin_top         = 48
	s.content_margin_bottom      = 48
	_panel.add_theme_stylebox_override("panel", s)

	_title_lbl.add_theme_color_override("font_color",    COLOR_PURPLE_BRIGHT)
	_title_lbl.add_theme_font_size_override("font_size", 36)
	_title_lbl.uppercase = true

	_journey_lbl.add_theme_color_override("font_color",    COLOR_MAGENTA)
	_journey_lbl.add_theme_font_size_override("font_size", 18)
	_journey_lbl.uppercase = true

	var sep: StyleBoxFlat = StyleBoxFlat.new()
	sep.bg_color           = COLOR_SEPARATOR
	sep.content_margin_top    = 1
	sep.content_margin_bottom = 1
	_divider.add_theme_stylebox_override("separator", sep)

	for lbl: Label in [_stat_rounds, _stat_actions, _stat_time]:
		lbl.add_theme_color_override("font_color",    COLOR_WHITE_SOFT)
		lbl.add_theme_font_size_override("font_size", 15)
		lbl.uppercase = true

	var score_sep: StyleBoxFlat = StyleBoxFlat.new()
	score_sep.bg_color           = COLOR_SEPARATOR
	score_sep.content_margin_top    = 1
	score_sep.content_margin_bottom = 1
	_score_divider.add_theme_stylebox_override("separator", score_sep)

	_score_title.add_theme_color_override("font_color",    COLOR_PURPLE_BRIGHT)
	_score_title.add_theme_font_size_override("font_size", 18)
	_score_title.uppercase = true

	_total_score_lbl.add_theme_color_override("font_color",    COLOR_WHITE_SOFT)
	_total_score_lbl.add_theme_font_size_override("font_size", 15)
	_total_score_lbl.uppercase = true

	_total_score_val.add_theme_color_override("font_color",    COLOR_MAGENTA)
	_total_score_val.add_theme_font_size_override("font_size", 15)
	_total_score_val.uppercase = true

	_style_button(_back_btn, COLOR_PURPLE_BRIGHT)


func _style_button(btn: Button, accent: Color) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   COLOR_WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", COLOR_BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.text = btn.text.to_upper()

	var bs: StyleBoxFlat = StyleBoxFlat.new()
	bs.bg_color            = COLOR_PURPLE_DARK
	bs.border_color        = accent
	bs.border_width_left   = 2
	bs.border_width_right  = 2
	bs.border_width_top    = 2
	bs.border_width_bottom = 2
	bs.content_margin_left   = 20
	bs.content_margin_right  = 20
	bs.content_margin_top    = 14
	bs.content_margin_bottom = 14
	btn.add_theme_stylebox_override("normal", bs)

	var bs_hover: StyleBoxFlat = bs.duplicate()
	bs_hover.bg_color = COLOR_PURPLE_MID
	btn.add_theme_stylebox_override("hover", bs_hover)

	var bs_pressed: StyleBoxFlat = bs.duplicate()
	bs_pressed.bg_color = accent
	btn.add_theme_stylebox_override("pressed", bs_pressed)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
