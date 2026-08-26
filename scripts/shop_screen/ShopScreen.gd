extends Control

signal closed
signal map_requested  # player tapped the header "◇ MAP" button (GameLoop owns the map)

@onready var _backdrop: ColorRect = $Backdrop
@onready var _panel: PanelContainer = $Panel
@onready var _vbox: VBoxContainer = $Panel/VBox
@onready var _header: HBoxContainer = $Panel/VBox/HeaderRow
@onready var _title: Label = $Panel/VBox/HeaderRow/Title
@onready var _coin_badge: PanelContainer = $Panel/VBox/HeaderRow/CoinBadge
@onready var _coin_lbl: Label = $Panel/VBox/HeaderRow/CoinBadge/CoinLabel
@onready var _subtitle: Label = $Panel/VBox/Subtitle
@onready var _cards_row: HBoxContainer = $Panel/VBox/CardsRow
@onready var _continue: Button = $Panel/VBox/FooterRow/ContinueButton

var _offered_ids: Array = []
var _purchased: Dictionary = {}  # id -> true
var _purchase_toast: PanelContainer = null  # the transient "added to inventory" banner (latest only)
var _price_mult: float = 1.0  # per-shop price multiplier from journey config

# Wrapping grid that replaces the scene's fixed 3-wide CardsRow at runtime so a
# shop can offer any number of items (built in _apply_layout).
var _cards_flow: HFlowContainer = null

var show_map_button: bool = true  # GameLoop clears this when the journey hides the map

# Auto-advance countdown (journey opt-in). GameLoop sets auto_advance_secs before setup(); when >0 the
# shop auto-continues after that many seconds (so a player can't linger to "rest"). Mirrors ForkScreen.
var auto_advance_secs: int = 0
var _time_left: float = 0.0
var _timer_active: bool = false
var _countdown_lbl: Label = null


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_add_map_button()
	_continue.pressed.connect(_on_continue_pressed)
	CoinService.BalanceChanged.connect(_on_balance_changed)
	_refresh_coins()
	_animate_in()


# A "◇ MAP" button in the header (left of the coin badge) so the player can open
# the read-only journey map while shopping. GameLoop owns the map; we just emit a
# request and it opens the viewer over this screen.
func _add_map_button() -> void:
	if not show_map_button:
		return
	var btn: Button = Button.new()
	btn.text = "◇ MAP"
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = "View the journey map (M)"
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_button(btn, UITheme.PURPLE_BRIGHT)
	btn.pressed.connect(func() -> void: emit_signal("map_requested"))
	_header.add_child(btn)
	_header.move_child(btn, _coin_badge.get_index())  # Title | MAP | CoinBadge


func _animate_in() -> void:
	_backdrop.modulate.a = 0.0
	_panel.modulate.a = 0.0
	_panel.scale = Vector2(0.88, 0.88)
	# Wait one frame so the panel has a real size before we set pivot_offset.
	await get_tree().process_frame
	_panel.pivot_offset = _panel.size / 2.0

	var tween: Tween = create_tween().set_parallel(true)
	tween.tween_property(_backdrop, "modulate:a", 1.0, 0.20).set_ease(Tween.EASE_OUT)
	tween.tween_property(_panel, "modulate:a", 1.0, 0.22).set_ease(Tween.EASE_OUT)
	tween.tween_property(_panel, "scale", Vector2.ONE, 0.32).set_ease(Tween.EASE_OUT).set_trans(
		Tween.TRANS_BACK
	)


# Called by GameLoop after add_child. The shop_data dict comes from
# GameState.CurrentShop() and carries the journey-authored shop config:
# title, mode ("pool"/"fixed"), count, items[], price_multiplier.
func setup(shop_data: Dictionary) -> void:
	SettingBackdrop.attach(self, _backdrop, shop_data)
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

	if auto_advance_secs > 0:
		_start_countdown()


# Fades + scales a freshly-added card in. Waits one frame so the flow container
# has assigned the card its size before the pivot is computed.
func _animate_card_in(card: Control, delay: float) -> void:
	card.modulate.a = 0.0
	await get_tree().process_frame
	if not is_instance_valid(card) or not card.is_inside_tree():
		return
	card.pivot_offset = card.size / 2.0
	card.scale = Vector2(0.92, 0.92)
	var tween: Tween = create_tween().set_parallel(true)
	tween.tween_property(card, "modulate:a", 1.0, 0.22).set_delay(delay)
	(
		tween
		. tween_property(card, "scale", Vector2.ONE, 0.30)
		. set_delay(delay)
		. set_ease(Tween.EASE_OUT)
		. set_trans(Tween.TRANS_BACK)
	)


# Quick scale "pop" used as purchase feedback.
func _pulse_card(card: Control) -> void:
	card.pivot_offset = card.size / 2.0
	var tween: Tween = create_tween()
	tween.tween_property(card, "scale", Vector2(1.06, 1.06), 0.10).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", Vector2.ONE, 0.16).set_ease(Tween.EASE_IN_OUT).set_trans(
		Tween.TRANS_CUBIC
	)


# A clear, held confirmation banner when an item is bought — the card pulse + the button flip to
# "OWNED" are easy to miss, so this slides a green banner down from the top for ~2s. Only the latest
# shows (a fresh purchase replaces the previous banner).
func _show_purchase_toast(item_name: String) -> void:
	if is_instance_valid(_purchase_toast):
		_purchase_toast.queue_free()
	var toast: PanelContainer = PanelContainer.new()
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(
		UITheme.PANEL_BG_DEEP.r, UITheme.PANEL_BG_DEEP.g, UITheme.PANEL_BG_DEEP.b, 0.95
	)
	s.border_color = UITheme.SUCCESS
	s.set_border_width_all(2)
	s.set_corner_radius_all(8)
	s.set_content_margin_all(12)
	toast.add_theme_stylebox_override("panel", s)
	var lbl: Label = Label.new()
	lbl.text = "✓  %s  ADDED TO INVENTORY" % item_name.to_upper()
	lbl.add_theme_color_override("font_color", UITheme.SUCCESS)
	lbl.add_theme_font_size_override("font_size", 16)
	toast.add_child(lbl)
	_purchase_toast = toast
	add_child(toast)
	await get_tree().process_frame  # let it size before we place/animate it
	if not is_instance_valid(toast):
		return
	var rest_y: float = 24.0
	var hidden_y: float = -toast.size.y - 8.0
	toast.position = Vector2((size.x - toast.size.x) / 2.0, hidden_y)
	toast.modulate.a = 0.0
	var tin: Tween = create_tween().set_parallel(true)
	tin.tween_property(toast, "position:y", rest_y, 0.28).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	tin.tween_property(toast, "modulate:a", 1.0, 0.2)
	await tin.finished
	await get_tree().create_timer(2.0).timeout
	if not is_instance_valid(toast):
		return
	var tout: Tween = create_tween().set_parallel(true)
	tout.tween_property(toast, "position:y", hidden_y, 0.25).set_ease(Tween.EASE_IN)
	tout.tween_property(toast, "modulate:a", 0.0, 0.25)
	await tout.finished
	if is_instance_valid(toast):
		toast.queue_free()


# Brief scale tick on the coin badge whenever the balance changes.
func _pulse_coin_badge() -> void:
	_coin_badge.pivot_offset = _coin_badge.size / 2.0
	var tween: Tween = create_tween()
	tween.tween_property(_coin_badge, "scale", Vector2(1.12, 1.12), 0.09).set_ease(Tween.EASE_OUT)
	(
		tween
		. tween_property(_coin_badge, "scale", Vector2.ONE, 0.14)
		. set_ease(Tween.EASE_IN_OUT)
		. set_trans(Tween.TRANS_CUBIC)
	)


# Resolves which item ids to display from the shop's authored config.
# The logic lives in JourneyData.resolve_shop_offer (pure, shared with the
# journey auditor): "fixed" mode shows exactly the authored list; "pool" mode
# shows every guaranteed item plus random draws from the rest of the registry.
func _resolve_offer(shop_data: Dictionary) -> Array:
	return JourneyData.resolve_shop_offer(shop_data, InventoryService.GetAllItemIds())


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
	inner.add_theme_constant_override("margin_left", 16)
	inner.add_theme_constant_override("margin_right", 16)
	inner.add_theme_constant_override("margin_top", 14)
	inner.add_theme_constant_override("margin_bottom", 14)
	card.add_child(inner)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.add_child(col)

	# Optional custom-item icon at the top of the card (still image; absent for built-in items).
	var icon_path: String = str(data.get("image", ""))
	if icon_path != "":
		var icon: JourneyImage = JourneyImage.new()
		icon.custom_minimum_size = Vector2(0, 88)
		col.add_child(icon)
		if not icon.show_path(
			icon_path, TextureRect.EXPAND_IGNORE_SIZE, TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		):
			icon.queue_free()

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
	_show_purchase_toast(str(data.get("name", id)))


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
	# Pop the panel out but keep the backdrop covering the play area — GameLoop's
	# transition fades black over it next, and frees this screen once the black
	# is opaque (don't fade the backdrop out or self-free, or the play area
	# behind would flash before the fade covers it).
	var tween: Tween = create_tween().set_parallel(true)
	tween.tween_property(_panel, "scale", Vector2(0.92, 0.92), 0.16).set_ease(Tween.EASE_IN)
	tween.tween_property(_panel, "modulate:a", 0.0, 0.16).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(func() -> void: emit_signal("closed"))


# ── Auto-advance countdown (journey opt-in; mirrors ForkScreen) ──────────────
func _start_countdown() -> void:
	_add_countdown_label()
	_time_left = float(auto_advance_secs)
	_timer_active = true
	_update_countdown_label()


func _process(delta: float) -> void:
	# GameLoop toggles set_process() while the map viewer is open, so this pauses there.
	if not _timer_active:
		return
	_time_left -= delta
	if _time_left <= 0.0:
		_timer_active = false
		if not _continue.disabled:
			_on_continue_pressed()  # auto-continue — same exit as pressing Continue
		return
	_update_countdown_label()


# A small countdown pinned top-centre so the ticking clock is visible above the panel.
func _add_countdown_label() -> void:
	_countdown_lbl = Label.new()
	_countdown_lbl.anchor_left = 0.5
	_countdown_lbl.anchor_right = 0.5
	_countdown_lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_countdown_lbl.offset_top = 18
	_countdown_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_lbl.add_theme_font_size_override("font_size", 15)
	_countdown_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_countdown_lbl)


func _update_countdown_label() -> void:
	if _countdown_lbl == null:
		return
	var secs: int = int(ceil(_time_left))
	_countdown_lbl.text = "AUTO-CONTINUE IN %d" % secs
	_countdown_lbl.add_theme_color_override(
		"font_color", UITheme.ERROR_SOFT if secs <= 5 else UITheme.DARK_TEXT
	)


# --------------------------------------------------------------------------
# Layout
# --------------------------------------------------------------------------


func _apply_layout() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	_backdrop.anchor_right = 1.0
	_backdrop.anchor_bottom = 1.0
	# Opaque so the paused round's frozen last frame doesn't bleed through behind the shop.
	_backdrop.color = Color(0.0, 0.0, 0.0, 1.0)

	_panel.anchor_left = 0.07
	_panel.anchor_right = 0.93
	_panel.anchor_top = 0.08
	_panel.anchor_bottom = 0.92

	_vbox.add_theme_constant_override("separation", 18)
	_header.add_theme_constant_override("separation", 12)

	# Replace the scene's fixed 3-wide CardsRow with a vertically-scrolling
	# wrapping grid so the shop can present any number of item cards.
	var cards_scroll: ScrollContainer = ScrollContainer.new()
	cards_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cards_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_cards_flow = HFlowContainer.new()
	_cards_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_flow.alignment = FlowContainer.ALIGNMENT_CENTER
	_cards_flow.add_theme_constant_override("h_separation", 16)
	_cards_flow.add_theme_constant_override("v_separation", 16)
	# A small horizontal inset so a full row's rightmost card border isn't clipped by the scroll's edge
	# (or the vertical scrollbar when the grid overflows and needs to scroll).
	var cards_margin: MarginContainer = MarginContainer.new()
	cards_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cards_margin.add_theme_constant_override("margin_left", 14)
	cards_margin.add_theme_constant_override("margin_right", 14)
	cards_margin.add_child(_cards_flow)
	cards_scroll.add_child(cards_margin)

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
	panel_style.border_color = UITheme.MAGENTA
	panel_style.border_width_left = 1
	panel_style.border_width_right = 1
	panel_style.border_width_top = 3
	panel_style.border_width_bottom = 3
	panel_style.shadow_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.45)
	panel_style.shadow_size = 24
	panel_style.content_margin_left = 28
	panel_style.content_margin_right = 28
	panel_style.content_margin_top = 22
	panel_style.content_margin_bottom = 22
	_panel.add_theme_stylebox_override("panel", panel_style)

	_title.add_theme_color_override("font_color", UITheme.MAGENTA)
	_title.add_theme_font_size_override("font_size", 30)
	_title.uppercase = true

	# Coin badge
	var coin_style: StyleBoxFlat = StyleBoxFlat.new()
	coin_style.bg_color = Color(UITheme.AMBER.r, UITheme.AMBER.g, UITheme.AMBER.b, 0.10)
	coin_style.border_color = UITheme.AMBER
	coin_style.border_width_left = 1
	coin_style.border_width_right = 1
	coin_style.border_width_top = 1
	coin_style.border_width_bottom = 1
	coin_style.content_margin_left = 14
	coin_style.content_margin_right = 14
	coin_style.content_margin_top = 6
	coin_style.content_margin_bottom = 6
	_coin_badge.add_theme_stylebox_override("panel", coin_style)
	# Shrink-center like the MAP button (_add_map_button) instead of filling the header row: the
	# row is as tall as the 30 px Title, so a FILL badge stretched to that height and read as
	# bigger than the button beside it. Their content heights already match to within a pixel.
	_coin_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_coin_lbl.add_theme_color_override("font_color", UITheme.AMBER)
	_coin_lbl.add_theme_font_size_override("font_size", 18)

	_subtitle.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	_subtitle.add_theme_font_size_override("font_size", 12)
	_subtitle.uppercase = true

	_style_button(_continue, UITheme.AMBER)


func _card_stylebox(owned: bool) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.CARD_BG_DIM if owned else UITheme.CARD_BG
	s.border_color = UITheme.TOXIC_GREEN if owned else UITheme.PURPLE_MID
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 2
	s.content_margin_left = 0
	s.content_margin_right = 0
	s.content_margin_top = 0
	s.content_margin_bottom = 0
	return s


# Thin delegate to UITheme — the canonical styling lives there (incl. the disabled state).
func _style_button(btn: Button, accent: Color) -> void:
	UITheme.style_button_subtle(btn, accent)
