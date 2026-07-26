extends Control

signal path_chosen(index: int)
signal map_requested  # player tapped the in-fork "◇ MAP" button (GameLoop owns the map)

@onready var _backdrop: ColorRect = $Backdrop
@onready var _center_box: VBoxContainer = $CenterBox
@onready var _fork_title: Label = $CenterBox/ForkTitle
@onready var _fork_sub: Label = $CenterBox/ForkSubtitle
@onready var _cards_row: HBoxContainer = $CenterBox/CardsRow

# Tracked for the auto-resolve reveal animation (random / conditional forks).
var _cards: Array = []  # Array[Control] — one per path, in order
var _choose_buttons: Array = []  # Array[Button]  — the "> CHOOSE" buttons
var _paths: Array = []  # the fork's path data dicts
var _resolution: String = "choice"  # how this fork resolves
var _cond_metric: String = "score"  # conditional metric (score/coins/item)
var _default_path: int = 0  # conditional fallback path index
var show_map_button: bool = true  # GameLoop clears this when the journey hides the map

var _cond_decider: String = "game"  # conditional: "game" (auto-spin) or "player" (gated pick)

# Auto-advance countdown (journey opt-in). GameLoop sets auto_advance_secs before setup(); when >0 it
# arms a visible timer on INTERACTIVE forks (the ones that wait for the player). On expiry it picks
# the author's timeout path (or the conditional default), else a random affordable path. 0 = off.
var auto_advance_secs: int = 0
var _timeout_path: int = -1  # author's on-timeout path for choice/sacrifice forks; -1 = random
var _time_left: float = 0.0
var _timer_active: bool = false
var _resolved: bool = false  # guards a manual pick and the timeout firing together
var _countdown_lbl: Label = null

# Optional audio accent, played on open over the BGM (Master bus). Loops until the fork resolves.
var _audio: AudioStreamPlayer = null


func _ready() -> void:
	_apply_layout()
	_apply_base_theme()
	_audio = AudioStreamPlayer.new()
	_audio.bus = "Master"
	add_child(_audio)


func setup(fork_data: Dictionary) -> void:
	var title: String = fork_data.get("title", "")
	if title != "":
		_fork_title.text = title.to_upper()

	var desc: String = fork_data.get("description", "")
	_fork_sub.text = desc if desc != "" else "Choose your path"
	_fork_sub.visible = true

	_resolution = fork_data.get("resolution", "choice")
	_cond_metric = fork_data.get("cond_metric", "score")
	_cond_decider = fork_data.get("cond_decider", "game")
	_default_path = int(fork_data.get("default_path", 0))
	_paths = fork_data.get("paths", [])
	for i in _paths.size():
		var path_data: Dictionary = _paths[i]
		var card: Control = _make_card(i, path_data)
		_cards.append(card)
		_cards_row.add_child(card)

	# Interactive forks (player choice / sacrifice / conditional-player) let the player consult the
	# journey map before committing. Auto-resolving forks play a reveal on timers instead, so the
	# button is omitted there (GameLoop also blocks the M key).
	if not _is_auto_resolved():
		_add_map_button()
		# Auto-advance countdown — only interactive forks can be "rested" on.
		_timeout_path = int(fork_data.get("timeout_path", -1))
		if auto_advance_secs > 0:
			_start_countdown()

	# Optional audio accent — plays over the BGM the moment the fork opens.
	var audio_path: String = str(fork_data.get("audio", ""))
	if audio_path != "":
		var stream: AudioStream = JourneyAudio.load_from_file(audio_path)
		if stream != null:
			JourneyAudio.set_loop(stream, bool(fork_data.get("audio_loop", false)))
			_audio.stream = stream
			var vol: float = float(fork_data.get("audio_volume", 1.0))
			_audio.volume_db = linear_to_db(vol) if vol > 0.0 else -80.0
			_audio.play()


func _make_card(index: int, path_data: Dictionary) -> Control:
	var card: Control = Control.new()
	card.custom_minimum_size = Vector2(220, 360)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.clip_contents = true

	# Layer 1 — solid bg (always present; shows through when no image)
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.055, 0.008, 0.086, 1.0)
	_fill(bg)
	card.add_child(bg)

	# Layer 2 — poster image (only when available). May be a still or a baked animation; JourneyImage
	# picks from the path and keeps the same STRETCH_SCALE fill either way.
	var image_path: String = path_data.get("image_path", "")
	if image_path != "":
		var img_ctl: JourneyImage = JourneyImage.new()
		_fill(img_ctl)
		card.add_child(img_ctl)
		if not img_ctl.show_path(
			image_path, TextureRect.EXPAND_IGNORE_SIZE, TextureRect.STRETCH_SCALE
		):
			img_ctl.queue_free()  # falls through to the solid bg layer beneath

	# Layer 3 — gradient: transparent at top, dark at bottom (always, for readability)
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0.0, 0.0, 0.0, 0.0))
	grad.set_color(1, Color(0.0, 0.0, 0.0, 0.90))
	var grad_tex: GradientTexture2D = GradientTexture2D.new()
	grad_tex.gradient = grad
	grad_tex.fill_from = Vector2(0.0, 0.0)
	grad_tex.fill_to = Vector2(0.0, 1.0)
	var grad_rect: TextureRect = TextureRect.new()
	grad_rect.texture = grad_tex
	grad_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fill(grad_rect)
	card.add_child(grad_rect)

	# Layer 4 — border (transparent fill, just the outline on top of everything)
	var border: Panel = Panel.new()
	var border_style: StyleBoxFlat = StyleBoxFlat.new()
	border_style.bg_color = Color(0, 0, 0, 0)
	border_style.border_color = UITheme.PURPLE_MID
	border_style.border_width_left = 1
	border_style.border_width_right = 1
	border_style.border_width_top = 1
	border_style.border_width_bottom = 1
	border.add_theme_stylebox_override("panel", border_style)
	_fill(border)
	card.add_child(border)

	# Layer 5 — content pinned to the bottom
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	_fill(margin)
	card.add_child(margin)

	var col: VBoxContainer = VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)

	# Spacer pushes all content to the bottom
	var spacer: Control = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)

	var path_name: String = path_data.get("name", "PATH %d" % (index + 1))
	var name_lbl: Label = Label.new()
	name_lbl.text = path_name.to_upper()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(22))
	col.add_child(name_lbl)

	var desc: String = path_data.get("description", "")
	if desc != "":
		var desc_lbl: Label = Label.new()
		desc_lbl.text = desc
		desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
		desc_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(13))
		col.add_child(desc_lbl)

	# round_count = rounds reachable down this branch (GameState.CurrentFork fills it from
	# LongestRoundPath). Fall back to a legacy "rounds" array if ever present.
	var round_count: int = int(
		path_data.get("round_count", (path_data.get("rounds", []) as Array).size())
	)
	var rounds_lbl: Label = Label.new()
	rounds_lbl.text = "%d ROUND%s" % [round_count, "S" if round_count != 1 else ""]
	rounds_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rounds_lbl.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	rounds_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(13))
	col.add_child(rounds_lbl)

	# Conditional: show each path's requirement so an auto-pick reads as earned,
	# not random.
	if _resolution == "conditional":
		var req_text: String = _conditional_req_text(index, path_data)
		if req_text != "":
			var req_lbl: Label = Label.new()
			req_lbl.text = req_text
			req_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			req_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			req_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(14))
			req_lbl.add_theme_color_override("font_color", UITheme.CYAN)
			col.add_child(req_lbl)

	# Sacrifice: show the path's cost and gate it by affordability.
	var sac_cost: int = int(path_data.get("cost", 0))
	var sac_req: String = str(path_data.get("required_item", ""))
	var sac_affordable: bool = (_resolution != "sacrifice") or _can_afford(sac_cost, sac_req)
	if _resolution == "sacrifice":
		var cost_lbl: Label = Label.new()
		cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost_lbl.add_theme_font_size_override("font_size", UITheme.story_font_size(14))
		if sac_cost <= 0 and sac_req == "":
			cost_lbl.text = "FREE"
			cost_lbl.add_theme_color_override("font_color", UITheme.SUCCESS)
		else:
			cost_lbl.text = _cost_text(sac_cost, sac_req)
			cost_lbl.add_theme_color_override(
				"font_color", UITheme.AMBER if sac_affordable else UITheme.ERROR_SOFT
			)
		col.add_child(cost_lbl)

	var btn: Button = Button.new()
	var cond_locked: bool = (
		_resolution == "conditional"
		and _cond_decider == "player"
		and not _qualifies(index, path_data)
	)
	if _resolution == "sacrifice" and not sac_affordable:
		btn.text = "✕ CAN'T AFFORD"
		btn.disabled = true
	elif cond_locked:
		btn.text = "✕ LOCKED"
		btn.disabled = true
	else:
		btn.text = "> CHOOSE"
	_style_button(btn, UITheme.PURPLE_BRIGHT)
	btn.pressed.connect(_on_path_chosen.bind(index))
	col.add_child(btn)
	_choose_buttons.append(btn)

	return card


# Anchors a control to fill its parent completely.
func _fill(c: Control) -> void:
	c.anchor_right = 1.0
	c.anchor_bottom = 1.0
	c.offset_left = 0
	c.offset_top = 0
	c.offset_right = 0
	c.offset_bottom = 0


static func _load_image(path: String) -> Image:
	if path == "":
		return null
	var abs_path: String = (
		ProjectSettings.globalize_path(path)
		if (path.begins_with("user://") or path.begins_with("res://"))
		else path
	)
	if not FileAccess.file_exists(abs_path):
		return null
	var f: FileAccess = FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return null
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	if bytes.is_empty():
		return null
	var img: Image = Image.new()
	var err: Error
	if bytes.size() >= 4 and bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	elif (
		bytes.size() >= 12
		and bytes[8] == 0x57
		and bytes[9] == 0x45
		and bytes[10] == 0x42
		and bytes[11] == 0x50
	):
		err = img.load_webp_from_buffer(bytes)
	else:
		err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			err = img.load_png_from_buffer(bytes)
		if err != OK:
			err = img.load_webp_from_buffer(bytes)
	return img if err == OK else null


func _on_path_chosen(index: int) -> void:
	# One resolution only — a manual pick and the countdown expiring can race.
	if _resolved:
		return
	_resolved = true
	_timer_active = false
	if _audio != null:
		_audio.stop()
	# Sacrifice: spend the path's cost (coins and/or item) before proceeding.
	# Affordability was already gated, so these should succeed.
	if _resolution == "sacrifice" and index >= 0 and index < _paths.size():
		var p: Dictionary = _paths[index]
		var cost: int = int(p.get("cost", 0))
		var req: String = str(p.get("required_item", ""))
		if cost > 0:
			CoinService.SpendCoins(cost)
		if req != "":
			InventoryService.ConsumeItem(req)
	# Note: GameLoop frees this screen during the transition (after the black
	# covers it), so it dims into the fade rather than vanishing first.
	emit_signal("path_chosen", index)


# ── Auto-advance countdown ───────────────────────────────────────────────────


func _start_countdown() -> void:
	_add_countdown_label()
	_time_left = float(auto_advance_secs)
	_timer_active = true
	_update_countdown_label()


func _process(delta: float) -> void:
	# Pausing is handled by GameLoop toggling set_process() while the map viewer is open.
	if not _timer_active:
		return
	_time_left -= delta
	if _time_left <= 0.0:
		_timer_active = false
		var idx: int = _resolve_timeout_index()
		# -1 = nothing selectable (a sacrifice with no affordable path): don't force an invalid spend,
		# just leave the player where they are.
		if idx < 0:
			return
		_on_path_chosen(idx)
		return
	_update_countdown_label()


# The path taken when the countdown expires — the pure pick in ForkResolver, fed this fork's live
# affordability mask (sacrifice paths gate on coins/items; every other path is always selectable).
func _resolve_timeout_index() -> int:
	var selectable: Array = []
	for i in _paths.size():
		selectable.append(_is_selectable(i))
	return ForkResolver.timeout_pick(_resolution, selectable, _timeout_path, _default_path, randi())


# A path the auto-pick may land on: a sacrifice path must be affordable; others are always fair game.
func _is_selectable(index: int) -> bool:
	if index < 0 or index >= _paths.size():
		return false
	if _resolution == "sacrifice":
		var p: Dictionary = _paths[index]
		return _can_afford(int(p.get("cost", 0)), str(p.get("required_item", "")))
	return true


# A small countdown pinned top-centre so the ticking clock is visible above the cards.
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
	_countdown_lbl.text = "AUTO-ADVANCE IN %d" % secs
	# Calm until the final few seconds, then flag it red.
	_countdown_lbl.add_theme_color_override(
		"font_color", UITheme.ERROR_SOFT if secs <= 5 else UITheme.DARK_TEXT
	)


# True if the player can pay this path's coin cost and owns its required item.
# Gating logic is shared with the resolver (pure, tested); here we feed it the
# live coin balance and ownership.
func _can_afford(cost: int, required_item: String) -> bool:
	return ForkResolver.path_affordable(
		cost, required_item, CoinService.Balance, Callable(InventoryService, "OwnsItem")
	)


# Whether a conditional fork auto-resolves (the game spins) vs. waits for the player to pick.
func _is_auto_resolved() -> bool:
	return _resolution == "random" or (_resolution == "conditional" and _cond_decider != "player")


# Conditional-player gating: a path is unlocked if its metric requirement is met, OR it's the default
# path (always available, so the player is never left with no selectable option).
func _qualifies(index: int, path_data: Dictionary) -> bool:
	if index == _default_path:
		return true
	match _cond_metric:
		"score":
			return ScoreService.LastRoundScore >= int(path_data.get("threshold", 0))
		"coins":
			return CoinService.Balance >= int(path_data.get("threshold", 0))
		"item":
			var req: String = str(path_data.get("required_item", ""))
			return req != "" and InventoryService.OwnsItem(req)
		"flag":
			var rf: String = str(path_data.get("required_flag", ""))
			return rf != "" and GameState.HasFlag(rf)
	return true


# Requirement text for a conditional path's card, e.g. "SCORE ≥ 100" or
# "REQUIRES KEY", with a "DEFAULT" tag on the fallback path.
func _conditional_req_text(index: int, path_data: Dictionary) -> String:
	var parts: Array = []
	var threshold: int = int(path_data.get("threshold", 0))
	match _cond_metric:
		"score":
			parts.append("SCORE ≥ %d" % threshold if threshold > 0 else "ANY SCORE")
		"coins":
			parts.append("COINS ≥ %d" % threshold if threshold > 0 else "ANY BALANCE")
		"item":
			var req: String = str(path_data.get("required_item", ""))
			if req != "":
				parts.append(
					(
						"REQUIRES %s"
						% str(InventoryService.GetItemData(req).get("name", req)).to_upper()
					)
				)
		"flag":
			var rf: String = str(path_data.get("required_flag", ""))
			if rf != "":
				parts.append("REQUIRES: %s" % rf.to_upper().replace("_", " "))
	if index == _default_path:
		parts.append("DEFAULT")
	return "   ·   ".join(parts)


# Human-readable cost, e.g. "♦ 50  +  Key".
func _cost_text(cost: int, required_item: String) -> String:
	var parts: Array = []
	if cost > 0:
		parts.append("♦ %d" % cost)
	if required_item != "":
		parts.append(str(InventoryService.GetItemData(required_item).get("name", required_item)))
	return "  +  ".join(parts) if not parts.is_empty() else "FREE"


# Auto-resolve presentation: the GAME has chosen `index`. Locks out manual picks
# and plays a roulette-style highlight that decelerates onto the winning card,
# then dims the rest and continues. Used by random and conditional forks.
func reveal(index: int, caption: String = "FATE DECIDES…") -> void:
	# Lock out manual choice.
	for b: Button in _choose_buttons:
		b.disabled = true
		b.visible = false
	_fork_sub.text = caption

	var n: int = _cards.size()
	if n == 0 or index < 0 or index >= n:
		emit_signal("path_chosen", clampi(index, 0, max(0, n - 1)))
		return

	# Let the container lay the cards out so scale pivots are centered.
	await get_tree().process_frame
	for c: Control in _cards:
		c.pivot_offset = c.size / 2.0

	# Beat so the player can actually read the options before the roll starts.
	await get_tree().create_timer(1.0).timeout

	# Roulette: cycle the highlight, decelerating, ending exactly on `index`.
	var steps: int = n * 3 + index
	var delay: float = 0.05
	for s in steps + 1:
		_set_card_state(s % n, "active")
		if s > 0:
			_set_card_state((s - 1) % n, "idle")
		await get_tree().create_timer(delay).timeout
		delay = min(delay * 1.13, 0.32)

	# Settle: winner stays lit, losers dim.
	for j in n:
		_set_card_state(j, "active" if j == index else "dim")
	_fork_sub.text = _path_display_name(index).to_upper()

	await get_tree().create_timer(1.0).timeout
	emit_signal("path_chosen", index)


func _set_card_state(j: int, state: String) -> void:
	if j < 0 or j >= _cards.size():
		return
	var c: Control = _cards[j]
	match state:
		"active":
			c.modulate = Color(1, 1, 1, 1)
			c.scale = Vector2(1.06, 1.06)
		"dim":
			c.modulate = Color(1, 1, 1, 0.35)
			c.scale = Vector2(1, 1)
		_:
			c.modulate = Color(1, 1, 1, 1)
			c.scale = Vector2(1, 1)


func _path_display_name(index: int) -> String:
	if index >= 0 and index < _paths.size():
		var n: String = (_paths[index].get("name", "") as String).strip_edges()
		if n != "":
			return n
	return "Path %d" % (index + 1)


# A small top-right "◇ MAP" button so the player can open the read-only journey
# map while deciding which path to take. GameLoop owns the map, so we just emit a
# request and let it open the viewer over this screen.
func _add_map_button() -> void:
	if not show_map_button:
		return
	var btn: Button = Button.new()
	btn.text = "◇ MAP"
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = "View the journey map (M)"
	_style_button(btn, UITheme.PURPLE_BRIGHT)
	btn.anchor_left = 1.0
	btn.anchor_right = 1.0
	btn.offset_left = -132
	btn.offset_right = -16
	btn.offset_top = 16
	btn.offset_bottom = 50
	btn.pressed.connect(func() -> void: emit_signal("map_requested"))
	add_child(btn)


func _apply_layout() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	_backdrop.anchor_right = 1.0
	_backdrop.anchor_bottom = 1.0
	_backdrop.offset_left = 0
	_backdrop.offset_top = 0
	_backdrop.offset_right = 0
	_backdrop.offset_bottom = 0

	_center_box.anchor_left = 0.1
	_center_box.anchor_right = 0.9
	_center_box.anchor_top = 0.1
	_center_box.anchor_bottom = 0.9
	_center_box.offset_left = 0
	_center_box.offset_top = 0
	_center_box.offset_right = 0
	_center_box.offset_bottom = 0
	_center_box.add_theme_constant_override("separation", 24)

	_cards_row.add_theme_constant_override("separation", 20)
	_cards_row.size_flags_vertical = Control.SIZE_EXPAND_FILL


func _apply_base_theme() -> void:
	_fork_title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	_fork_title.add_theme_font_size_override("font_size", UITheme.story_font_size(32))
	_fork_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fork_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fork_title.uppercase = true

	_fork_sub.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	_fork_sub.add_theme_font_size_override("font_size", UITheme.story_font_size(15))
	_fork_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fork_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


# Thin delegate to UITheme — the canonical styling lives there.
func _style_button(btn: Button, accent: Color) -> void:
	UITheme.style_button_subtle(btn, accent, 14, 10, 14)
