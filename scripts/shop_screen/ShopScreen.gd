extends Control

signal closed

const DEFAULT_COUNT: int = 3

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
var _price_mult:  float = 1.0      # per-shop price multiplier from journey config

# Wrapping grid that replaces the scene's fixed 3-wide CardsRow at runtime so a
# shop can offer any number of items (built in _apply_layout).
var _cards_flow:  HFlowContainer = null


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
# GameState.CurrentShop() and carries the journey-authored shop config:
# title, mode ("pool"/"fixed"), count, items[], price_multiplier.
func setup(shop_data: Dictionary) -> void:
	var title: String = shop_data.get("title", "")
	if title != "":
		_title.text = "// %s //" % title.to_upper()

	_price_mult = float(shop_data.get("price_multiplier", 1.0))

	_offered_ids = _resolve_offer(shop_data)
	var stagger: int = 0
	for id: String in _offered_ids:
		var data: Dictionary = InventoryService.GetItemData(id)
		if data.is_empty():
			continue
		var card: PanelContainer = _make_card(id, data)
		_cards_flow.add_child(card)
		# Staggered fade/scale-in; the per-card delay is capped so a large shop
		# still finishes building in quickly.
		_animate_card_in(card, min(stagger, 12) * 0.04)
		stagger += 1


# Fades + scales a freshly-added card in. Waits one frame so the flow container
# has assigned the card its size before the pivot is computed.
func _animate_card_in(card: Control, delay: float) -> void:
	card.modulate.a = 0.0
	await get_tree().process_frame
	if not is_instance_valid(card) or not card.is_inside_tree():
		return
	card.pivot_offset = card.size / 2.0
	card.scale = Vector2(0.92, 0.92)
	var t: Tween = create_tween().set_parallel(true)
	t.tween_property(card, "modulate:a", 1.0, 0.22).set_delay(delay)
	t.tween_property(card, "scale", Vector2.ONE, 0.30) \
		.set_delay(delay).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)


# Quick scale "pop" used as purchase feedback.
func _pulse_card(card: Control) -> void:
	card.pivot_offset = card.size / 2.0
	var t: Tween = create_tween()
	t.tween_property(card, "scale", Vector2(1.06, 1.06), 0.10).set_ease(Tween.EASE_OUT)
	t.tween_property(card, "scale", Vector2.ONE, 0.16) \
		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)


# Brief scale tick on the coin badge whenever the balance changes.
func _pulse_coin_badge() -> void:
	_coin_badge.pivot_offset = _coin_badge.size / 2.0
	var t: Tween = create_tween()
	t.tween_property(_coin_badge, "scale", Vector2(1.12, 1.12), 0.09).set_ease(Tween.EASE_OUT)
	t.tween_property(_coin_badge, "scale", Vector2.ONE, 0.14) \
		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)


# Resolves which item ids to display from the shop's authored config.
# "fixed" mode shows exactly the authored list (in registry order for a stable
# lineup); "pool" mode draws `count` random items from the authored pool, or
# from all items when no pool was specified. Stale ids are dropped.
func _resolve_offer(shop_data: Dictionary) -> Array:
	var all_ids: Array = InventoryService.GetAllItemIds()
	var configured: Array = shop_data.get("items", [])
	var valid: Array = configured.filter(func(id: String) -> bool: return id in all_ids)

	if shop_data.get("mode", "pool") == "fixed":
		return all_ids.filter(func(id: String) -> bool: return id in valid)

	var pool: Array = valid if not valid.is_empty() else all_ids.duplicate()
	pool.shuffle()
	var count: int = int(shop_data.get("count", DEFAULT_COUNT))
	return pool.slice(0, min(count, pool.size()))


# Item price after the per-shop multiplier, rounded to a whole coin.
func _price_of(data: Dictionary) -> int:
	return int(round(float(data.get("price", 0)) * _price_mult))


# --------------------------------------------------------------------------
# Item cards
# --------------------------------------------------------------------------

func _make_card(id: String, data: Dictionary) -> Control:
	# Fixed card size — the HFlowContainer wraps cards into rows at this size.
	var card: PanelContainer = PanelContainer.new()
	card.custom_minimum_size = Vector2(240, 340)
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
	badge.add_theme_color_override("font_color", UITheme.AMBER)
	badge.add_theme_font_size_override("font_size", 10)
	col.add_child(badge)

	# Name
	var name_lbl: Label = Label.new()
	name_lbl.text = (data.get("name", "?") as String).to_upper()
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", 18)
	col.add_child(name_lbl)

	# Description
	var desc_lbl: Label = Label.new()
	desc_lbl.text = data.get("description", "")
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	desc_lbl.add_theme_font_size_override("font_size", 12)
	col.add_child(desc_lbl)

	# Stats row: duration
	var dur_ms: int = data.get("duration_ms", 0)
	var dur_lbl: Label = Label.new()
	dur_lbl.text = "DURATION: %ds" % int(dur_ms / 1000.0)
	dur_lbl.add_theme_color_override("font_color", UITheme.TOXIC_GREEN)
	dur_lbl.add_theme_font_size_override("font_size", 11)
	col.add_child(dur_lbl)

	# Price row
	var price: int = _price_of(data)
	var price_row: HBoxContainer = HBoxContainer.new()
	price_row.add_theme_constant_override("separation", 6)
	col.add_child(price_row)

	var price_lbl: Label = Label.new()
	price_lbl.text = "♦ %d" % price
	price_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	price_lbl.add_theme_font_size_override("font_size", 22)
	price_row.add_child(price_lbl)

	# BUY button
	var buy: Button = Button.new()
	buy.text = "> BUY"
	buy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button(buy, UITheme.PURPLE_BRIGHT)
	buy.pressed.connect(_on_buy_pressed.bind(id, buy, card))
	col.add_child(buy)

	_update_buy_button(id, buy, card)
	return card


func _on_buy_pressed(id: String, buy: Button, card: PanelContainer) -> void:
	if _purchased.get(id, false):
		return
	var data: Dictionary = InventoryService.GetItemData(id)
	var price: int = _price_of(data)
	if not CoinService.SpendCoins(price):
		return
	InventoryService.AddItem(id)
	_purchased[id] = true
	_update_buy_button(id, buy, card)
	_pulse_card(card)


func _on_balance_changed(_balance: int) -> void:
	_refresh_coins()
	_pulse_coin_badge()
	# Re-evaluate every offered card's affordability.
	for child: Control in _cards_flow.get_children():
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
	var price: int = _price_of(data)

	if _purchased.get(id, false):
		buy.text = "✓ OWNED"
		buy.disabled = true
		card.add_theme_stylebox_override("panel", _card_stylebox(true))
		buy.add_theme_color_override("font_color", UITheme.TOXIC_GREEN)
		buy.add_theme_color_override("font_disabled_color", UITheme.TOXIC_GREEN)
		return

	if CoinService.CanAfford(price):
		buy.text = "> BUY  ♦ %d" % price
		buy.disabled = false
	else:
		buy.text = "✕ INSUFFICIENT  ♦ %d" % price
		buy.disabled = true
		buy.add_theme_color_override("font_disabled_color", UITheme.DANGER)


func _refresh_coins() -> void:
	_coin_lbl.text = "♦ %d" % CoinService.Balance


func _input(event: InputEvent) -> void:
	# Esc: dismiss the shop (same as pressing the Continue button).
	if event.is_action_pressed("ui_cancel") and not _continue.disabled:
		_on_continue_pressed()
		get_viewport().set_input_as_handled()


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

	# Replace the scene's fixed 3-wide CardsRow with a vertically-scrolling
	# wrapping grid so the shop can present any number of item cards.
	var cards_scroll: ScrollContainer = ScrollContainer.new()
	cards_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cards_scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	cards_scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL

	_cards_flow = HFlowContainer.new()
	_cards_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_flow.alignment = FlowContainer.ALIGNMENT_CENTER
	_cards_flow.add_theme_constant_override("h_separation", 16)
	_cards_flow.add_theme_constant_override("v_separation", 16)
	cards_scroll.add_child(_cards_flow)

	var row_idx: int = _cards_row.get_index()
	_vbox.add_child(cards_scroll)
	_vbox.move_child(cards_scroll, row_idx)
	_cards_row.queue_free()


# --------------------------------------------------------------------------
# Theme
# --------------------------------------------------------------------------

func _apply_theme() -> void:
	# Panel: cyberpunk-rundown — magenta border with amber accent edges.
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG_SHOP
	panel_style.border_color        = UITheme.MAGENTA
	panel_style.border_width_left   = 1
	panel_style.border_width_right  = 1
	panel_style.border_width_top    = 3
	panel_style.border_width_bottom = 3
	panel_style.shadow_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.45)
	panel_style.shadow_size  = 24
	panel_style.content_margin_left   = 28
	panel_style.content_margin_right  = 28
	panel_style.content_margin_top    = 22
	panel_style.content_margin_bottom = 22
	_panel.add_theme_stylebox_override("panel", panel_style)

	_title.add_theme_color_override("font_color", UITheme.MAGENTA)
	_title.add_theme_font_size_override("font_size", 30)
	_title.uppercase = true

	# Coin badge
	var coin_style: StyleBoxFlat = StyleBoxFlat.new()
	coin_style.bg_color            = Color(UITheme.AMBER.r, UITheme.AMBER.g, UITheme.AMBER.b, 0.10)
	coin_style.border_color        = UITheme.AMBER
	coin_style.border_width_left   = 1
	coin_style.border_width_right  = 1
	coin_style.border_width_top    = 1
	coin_style.border_width_bottom = 1
	coin_style.content_margin_left   = 14
	coin_style.content_margin_right  = 14
	coin_style.content_margin_top    = 6
	coin_style.content_margin_bottom = 6
	_coin_badge.add_theme_stylebox_override("panel", coin_style)
	_coin_lbl.add_theme_color_override("font_color", UITheme.AMBER)
	_coin_lbl.add_theme_font_size_override("font_size", 18)

	_subtitle.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	_subtitle.add_theme_font_size_override("font_size", 12)
	_subtitle.uppercase = true

	_style_button(_continue, UITheme.AMBER)


func _card_stylebox(owned: bool) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.CARD_BG_DIM if owned else UITheme.CARD_BG
	s.border_color        = UITheme.TOXIC_GREEN if owned else UITheme.PURPLE_MID
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
	btn.add_theme_color_override("font_hover_color",   UITheme.WHITE_SOFT)
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
