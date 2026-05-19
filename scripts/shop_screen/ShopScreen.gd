extends Control

signal closed

const COLOR_PANEL_BG:      Color = Color(0.035, 0.005, 0.055, 0.96)
const COLOR_PURPLE_BRIGHT: Color = Color(0.698, 0.118, 1.0,   1.0)
const COLOR_PURPLE_MID:    Color = Color(0.408, 0.063, 0.627, 1.0)
const COLOR_MAGENTA:       Color = Color(0.878, 0.0,   0.878, 1.0)
const COLOR_WHITE_SOFT:    Color = Color(0.878, 0.780, 1.0,   1.0)
const COLOR_DARK_TEXT:     Color = Color(0.55,  0.47,  0.72,  1.0)
const COLOR_AMBER:         Color = Color(1.0,   0.65,  0.15,  1.0)
const COLOR_TOXIC_GREEN:   Color = Color(0.45,  1.0,   0.35,  1.0)
const COLOR_DANGER:        Color = Color(0.95,  0.18,  0.18,  1.0)
const COLOR_CARD_BG:       Color = Color(0.02,  0.0,   0.04,  1.0)
const COLOR_CARD_BG_DIM:   Color = Color(0.01,  0.0,   0.02,  1.0)

const CARDS_PER_VISIT: int = 3

@onready var _backdrop:   ColorRect      = $Backdrop
@onready var _panel:      PanelContainer = $Panel
@onready var _vbox:       VBoxContainer  = $Panel/VBox
@onready var _header:     HBoxContainer  = $Panel/VBox/HeaderRow
@onready var _title:      Label          = $Panel/VBox/HeaderRow/Title
@onready var _coin_badge: PanelContainer = $Panel/VBox/HeaderRow/CoinBadge
@onready var _coin_lbl:   Label          = $Panel/VBox/HeaderRow/CoinBadge/CoinLabel
@onready var _subtitle:   Label          = $Panel/VBox/Subtitle
@onready var _cards_row:  HBoxContainer  = $Panel/VBox/CardsRow
@onready var _continue:   Button         = $Panel/VBox/FooterRow/ContinueButton

var _offered_ids: Array = []
var _purchased:   Dictionary = {}  # id -> true


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_continue.pressed.connect(_on_continue_pressed)
	CoinService.BalanceChanged.connect(_on_balance_changed)
	_refresh_coins()
	_animate_in()


func _animate_in() -> void:
	_backdrop.modulate.a = 0.0
	_panel.modulate.a    = 0.0
	_panel.scale         = Vector2(0.88, 0.88)
	# Wait one frame so the panel has a real size before we set pivot_offset.
	await get_tree().process_frame
	_panel.pivot_offset = _panel.size / 2.0

	var tween: Tween = create_tween().set_parallel(true)
	tween.tween_property(_backdrop, "modulate:a", 1.0, 0.20).set_ease(Tween.EASE_OUT)
	tween.tween_property(_panel,    "modulate:a", 1.0, 0.22).set_ease(Tween.EASE_OUT)
	tween.tween_property(_panel,    "scale",      Vector2.ONE, 0.32) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)


# Called by GameLoop after add_child. The shop_data dict comes from
# GameState.CurrentShop() — currently only carries an optional title.
func setup(shop_data: Dictionary) -> void:
	var title: String = shop_data.get("title", "")
	if title != "":
		_title.text = "// %s //" % title.to_upper()

	_offered_ids = _roll_offer(CARDS_PER_VISIT)
	for id: String in _offered_ids:
		var data: Dictionary = InventoryService.GetItemData(id)
		if data.is_empty():
			continue
		_cards_row.add_child(_make_card(id, data))


func _roll_offer(count: int) -> Array:
	var pool: Array = InventoryService.GetAllItemIds().duplicate()
	pool.shuffle()
	return pool.slice(0, min(count, pool.size()))


# --------------------------------------------------------------------------
# Item cards
# --------------------------------------------------------------------------

func _make_card(id: String, data: Dictionary) -> Control:
	var card: PanelContainer = PanelContainer.new()
	card.custom_minimum_size = Vector2(240, 340)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _card_stylebox(false))

	var inner: MarginContainer = MarginContainer.new()
	inner.add_theme_constant_override("margin_left",   16)
	inner.add_theme_constant_override("margin_right",  16)
	inner.add_theme_constant_override("margin_top",    14)
	inner.add_theme_constant_override("margin_bottom", 14)
	card.add_child(inner)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.add_child(col)

	# Category badge
	var category: String = data.get("category", "modifier")
	var badge: Label = Label.new()
	badge.text = "[ %s ]" % category.to_upper()
	badge.add_theme_color_override("font_color", COLOR_AMBER)
	badge.add_theme_font_size_override("font_size", 10)
	col.add_child(badge)

	# Name
	var name_lbl: Label = Label.new()
	name_lbl.text = (data.get("name", "?") as String).to_upper()
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.add_theme_color_override("font_color", COLOR_WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", 18)
	col.add_child(name_lbl)

	# Description
	var desc_lbl: Label = Label.new()
	desc_lbl.text = data.get("description", "")
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc_lbl.add_theme_color_override("font_color", COLOR_DARK_TEXT)
	desc_lbl.add_theme_font_size_override("font_size", 12)
	col.add_child(desc_lbl)

	# Stats row: duration
	var dur_ms: int = data.get("duration_ms", 0)
	var dur_lbl: Label = Label.new()
	dur_lbl.text = "DURATION: %ds" % int(dur_ms / 1000.0)
	dur_lbl.add_theme_color_override("font_color", COLOR_TOXIC_GREEN)
	dur_lbl.add_theme_font_size_override("font_size", 11)
	col.add_child(dur_lbl)

	# Price row
	var price: int = data.get("price", 0)
	var price_row: HBoxContainer = HBoxContainer.new()
	price_row.add_theme_constant_override("separation", 6)
	col.add_child(price_row)

	var price_lbl: Label = Label.new()
	price_lbl.text = "♦ %d" % price
	price_lbl.add_theme_color_override("font_color", COLOR_MAGENTA)
	price_lbl.add_theme_font_size_override("font_size", 22)
	price_row.add_child(price_lbl)

	# BUY button
	var buy: Button = Button.new()
	buy.text = "> BUY"
	buy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button(buy, COLOR_PURPLE_BRIGHT)
	buy.pressed.connect(_on_buy_pressed.bind(id, buy, card))
	col.add_child(buy)

	_update_buy_button(id, buy, card)
	return card


func _on_buy_pressed(id: String, buy: Button, card: PanelContainer) -> void:
	if _purchased.get(id, false):
		return
	var data: Dictionary = InventoryService.GetItemData(id)
	var price: int = data.get("price", 0)
	if not CoinService.SpendCoins(price):
		return
	InventoryService.AddItem(id)
	_purchased[id] = true
	_update_buy_button(id, buy, card)


func _on_balance_changed(_balance: int) -> void:
	_refresh_coins()
	# Re-evaluate every offered card's affordability.
	for child: Control in _cards_row.get_children():
		var buy: Button = child.find_child("*", true, false) as Button
		# Fallback: find by walking children (only one Button per card).
		buy = _first_button(child)
		if buy == null:
			continue
		var id: String = buy.get_meta("item_id", "")
		if id != "":
			_update_buy_button(id, buy, child as PanelContainer)


func _first_button(node: Node) -> Button:
	for child in node.get_children():
		if child is Button:
			return child
		var found: Button = _first_button(child)
		if found != null:
			return found
	return null


func _update_buy_button(id: String, buy: Button, card: PanelContainer) -> void:
	buy.set_meta("item_id", id)
	var data: Dictionary = InventoryService.GetItemData(id)
	var price: int = data.get("price", 0)

	if _purchased.get(id, false):
		buy.text = "✓ OWNED"
		buy.disabled = true
		card.add_theme_stylebox_override("panel", _card_stylebox(true))
		buy.add_theme_color_override("font_color", COLOR_TOXIC_GREEN)
		buy.add_theme_color_override("font_disabled_color", COLOR_TOXIC_GREEN)
		return

	if CoinService.CanAfford(price):
		buy.text = "> BUY  ♦ %d" % price
		buy.disabled = false
	else:
		buy.text = "✕ INSUFFICIENT  ♦ %d" % price
		buy.disabled = true
		buy.add_theme_color_override("font_disabled_color", COLOR_DANGER)


func _refresh_coins() -> void:
	_coin_lbl.text = "♦ %d" % CoinService.Balance


func _on_continue_pressed() -> void:
	_continue.disabled = true
	_panel.pivot_offset = _panel.size / 2.0
	var tween: Tween = create_tween().set_parallel(true)
	tween.tween_property(_panel,    "scale",      Vector2(0.92, 0.92), 0.16).set_ease(Tween.EASE_IN)
	tween.tween_property(_panel,    "modulate:a", 0.0, 0.16).set_ease(Tween.EASE_IN)
	tween.tween_property(_backdrop, "modulate:a", 0.0, 0.16).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(func() -> void:
		emit_signal("closed")
		queue_free()
	)


# --------------------------------------------------------------------------
# Layout
# --------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_backdrop.anchor_right  = 1.0
	_backdrop.anchor_bottom = 1.0

	_panel.anchor_left   = 0.07
	_panel.anchor_right  = 0.93
	_panel.anchor_top    = 0.08
	_panel.anchor_bottom = 0.92

	_vbox.add_theme_constant_override("separation", 18)
	_header.add_theme_constant_override("separation", 12)
	_cards_row.add_theme_constant_override("separation", 16)
	_cards_row.size_flags_vertical = Control.SIZE_EXPAND_FILL


# --------------------------------------------------------------------------
# Theme
# --------------------------------------------------------------------------

func _apply_theme() -> void:
	# Panel: cyberpunk-rundown — magenta border with amber accent edges.
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = COLOR_PANEL_BG
	panel_style.border_color        = COLOR_MAGENTA
	panel_style.border_width_left   = 1
	panel_style.border_width_right  = 1
	panel_style.border_width_top    = 3
	panel_style.border_width_bottom = 3
	panel_style.shadow_color = Color(COLOR_MAGENTA.r, COLOR_MAGENTA.g, COLOR_MAGENTA.b, 0.45)
	panel_style.shadow_size  = 24
	panel_style.content_margin_left   = 28
	panel_style.content_margin_right  = 28
	panel_style.content_margin_top    = 22
	panel_style.content_margin_bottom = 22
	_panel.add_theme_stylebox_override("panel", panel_style)

	_title.add_theme_color_override("font_color", COLOR_MAGENTA)
	_title.add_theme_font_size_override("font_size", 30)
	_title.uppercase = true

	# Coin badge
	var coin_style: StyleBoxFlat = StyleBoxFlat.new()
	coin_style.bg_color            = Color(COLOR_AMBER.r, COLOR_AMBER.g, COLOR_AMBER.b, 0.10)
	coin_style.border_color        = COLOR_AMBER
	coin_style.border_width_left   = 1
	coin_style.border_width_right  = 1
	coin_style.border_width_top    = 1
	coin_style.border_width_bottom = 1
	coin_style.content_margin_left   = 14
	coin_style.content_margin_right  = 14
	coin_style.content_margin_top    = 6
	coin_style.content_margin_bottom = 6
	_coin_badge.add_theme_stylebox_override("panel", coin_style)
	_coin_lbl.add_theme_color_override("font_color", COLOR_AMBER)
	_coin_lbl.add_theme_font_size_override("font_size", 18)

	_subtitle.add_theme_color_override("font_color", COLOR_DARK_TEXT)
	_subtitle.add_theme_font_size_override("font_size", 12)
	_subtitle.uppercase = true

	_style_button(_continue, COLOR_AMBER)


func _card_stylebox(owned: bool) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = COLOR_CARD_BG_DIM if owned else COLOR_CARD_BG
	s.border_color        = COLOR_TOXIC_GREEN if owned else COLOR_PURPLE_MID
	s.border_width_left   = 1
	s.border_width_right  = 1
	s.border_width_top    = 1
	s.border_width_bottom = 2
	s.content_margin_left   = 0
	s.content_margin_right  = 0
	s.content_margin_top    = 0
	s.content_margin_bottom = 0
	return s


func _style_button(btn: Button, accent: Color) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   COLOR_WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", Color.BLACK)
	btn.add_theme_font_size_override("font_size", 13)

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color              = Color(accent.r, accent.g, accent.b, 0.10)
	s.border_color          = accent
	s.border_width_left     = 1
	s.border_width_right    = 1
	s.border_width_top      = 1
	s.border_width_bottom   = 1
	s.content_margin_left   = 14
	s.content_margin_right  = 14
	s.content_margin_top    = 10
	s.content_margin_bottom = 10
	btn.add_theme_stylebox_override("normal", s)

	var s_hover: StyleBoxFlat = s.duplicate()
	s_hover.bg_color = Color(accent.r, accent.g, accent.b, 0.30)
	btn.add_theme_stylebox_override("hover", s_hover)

	var s_pressed: StyleBoxFlat = s.duplicate()
	s_pressed.bg_color = accent
	btn.add_theme_stylebox_override("pressed", s_pressed)

	var s_disabled: StyleBoxFlat = s.duplicate()
	s_disabled.bg_color = Color(accent.r, accent.g, accent.b, 0.04)
	s_disabled.border_color = Color(accent.r, accent.g, accent.b, 0.4)
	btn.add_theme_stylebox_override("disabled", s_disabled)

	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
