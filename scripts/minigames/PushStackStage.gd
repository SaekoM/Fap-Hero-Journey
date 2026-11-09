class_name PushStackStage
extends Control

# Push Your Luck's stage: a stack on a table, in whichever look the creator picked, with a dotted outline of how tall it
# could get. The pieces sway harder and land less straight as the risk rises. A pushed piece hovers above the stack
# before it lands or the stack comes down. PushYourLuckView drives it; none of this affects the result.

const STAGE_HEIGHT: float = 300.0
const TABLE_HEIGHT: float = 14.0
const TABLE_INSET: float = 16.0
const TABLE_OVERHANG: float = 40.0
const SHADOW_SQUASH: float = 0.16
const SHADOW_ALPHA: float = 0.45
const PIECE_GAP: float = 2.0
const OUTLINE_ALPHA: float = 0.35
const OUTLINE_DASH: float = 5.0

const SWAY_MOST: float = 22.0
const SWAY_SPEED_CALM: float = 1.4
const SWAY_SPEED_RISKY: float = 4.0
const SWAY_FULL_HEIGHT: float = 15.0
const SETTLE_SECS: float = 0.5
# How far a piece can land off-centre at the highest risk, on top of its look's own looseness. The offsets add up, so
# a tall stack visibly leans.
const LEAN_RISK_EXTRA: float = 6.0
const LEAN_LIMIT: float = 34.0

const HOVER_ABOVE: float = 46.0
const HOVER_TREMBLE: float = 3.0
const BOUNCE_START: float = -12.0
const BOUNCE_SECS: float = 0.28
const SQUASH_PER_PIECE: float = 0.8
const SQUASH_SECS: float = 0.22
const DUST_SECS: float = 0.5
const DUST_PUFFS: int = 6
const DUST_REACH: float = 70.0
const DUST_RADIUS: float = 9.0
const DUST_ALPHA: float = 0.4

const TOPPLE_SECS: float = 1.2
const BOUNCE_HEIGHT: float = 34.0
const BOUNCES: float = 3.0
const SHAKE_STEP_SECS: float = 0.05
const SHAKE_OFFSETS: Array[float] = [-12.0, 10.0, -8.0, 6.0, -3.0, 0.0]
const FLASH_ALPHA: float = 0.35
const FLASH_SECS: float = 0.4

const SWEEP_SECS: float = 0.7
const SWEEP_STAGGER: float = 0.6
const SWEEP_END_SCALE: float = 0.3  # how small a banked piece has shrunk by the time it reaches the pot
const GOLD_SECS: float = 0.6
const NOT_STARTED: float = -1.0
const DOME_MARGIN: float = 26.0
const DOME_SMALLEST_RADIUS: float = 80.0
const DOME_ALPHA: float = 0.8
const DOME_WIDTH: float = 3.0
const DOME_GAP: float = 6.0
const DOME_POINTS: int = 48

var art: StackArt
var accent: Color = Color.WHITE
var pieces: int = 1
var most_pieces: int = 1
var sway_share: float = 0.0  # how risky the next push is, 0–1
var shields_up: int = 0  # how many shields the player holds; drawn as a dome over the stack
var clock: float = 0.0  # seconds, for the things that keep moving

var _leans: PackedFloat32Array = [0.0]  # how far off-centre each piece sits
# Which token each piece came from. The first is the free draw the game starts with.
var _kinds: PackedStringArray = [PushYourLuckGame.TOKEN_VALUE]
var _sway_scale: float = 1.0  # falls to 0 as the stack settles
var _hovering: bool = false
var _hover_height: float = 0.0
var _bounce: float = 0.0
var _squash: float = 0.0
var _dust: float = NOT_STARTED
var _topple: float = NOT_STARTED
var _sweep: float = NOT_STARTED
var _sweep_target: Vector2 = Vector2.ZERO
var _gold: float = 0.0
var _flash: float = 0.0
var _shake_x: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size.y = STAGE_HEIGHT


func _process(delta: float) -> void:
	clock += delta
	queue_redraw()


# ── What happens to it ───────────────────────────────────────────────────────


# A pushed piece appears above the stack and sinks towards it, slowing as the moment arrives. Where it would land is
# already drawn from how risky the push is.
func hover_piece(secs: float) -> void:
	_hovering = true
	_hover_height = HOVER_ABOVE
	var looseness: float = art.misalignment() + LEAN_RISK_EXTRA * sway_share
	_leans.append(clampf(_leans[-1] + randf_range(-looseness, looseness), -LEAN_LIMIT, LEAN_LIMIT))
	(
		create_tween()
		. tween_property(self, "_hover_height", PIECE_GAP, secs)
		. set_trans(Tween.TRANS_EXPO)
		. set_ease(Tween.EASE_OUT)
	)


# The piece drops the last of the way with a small bounce: the stack gives under it, and dust comes off the table.
# Only now does it show what it is: while it hovers, it looks like any other piece, so it can't give the draw away.
func land_piece(kind: String = PushYourLuckGame.TOKEN_VALUE) -> void:
	_hovering = false
	pieces += 1
	_kinds.append(kind)
	_bounce = BOUNCE_START
	(
		create_tween()
		. tween_property(self, "_bounce", 0.0, BOUNCE_SECS)
		. set_trans(Tween.TRANS_BOUNCE)
		. set_ease(Tween.EASE_OUT)
	)
	_squash = 1.0
	create_tween().tween_property(self, "_squash", 0.0, SQUASH_SECS).set_ease(Tween.EASE_OUT)
	_dust = 0.0
	create_tween().tween_property(self, "_dust", 1.0, DUST_SECS)


func settle() -> void:
	create_tween().tween_property(self, "_sway_scale", 0.0, SETTLE_SECS)


# Banked: the stack sweeps away to `target`, top first, in the stage's own coordinates.
func sweep_to(target: Vector2) -> void:
	_sweep_target = target
	_sweep = 0.0
	(
		create_tween()
		. tween_property(self, "_sweep", 1.0, SWEEP_SECS)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_IN)
	)


func topple() -> void:
	_hovering = false
	_topple = 0.0
	create_tween().tween_property(self, "_topple", 1.0, TOPPLE_SECS)
	_shake_and_flash()


func _shake_and_flash() -> void:
	var shake: Tween = create_tween()
	for offset: float in SHAKE_OFFSETS:
		shake.tween_property(self, "_shake_x", offset, SHAKE_STEP_SECS)
	if not SettingsService.get_reduce_flashing():
		_flash = 1.0
		create_tween().tween_property(self, "_flash", 0.0, FLASH_SECS)


# A shield took a trap: the pushed piece goes, the stack shudders but stands, and the highest shield still whole
# cracks.
func block_trap() -> void:
	_hovering = false
	_leans.remove_at(_leans.size() - 1)
	var shield_at: int = _kinds.rfind(PushYourLuckGame.TOKEN_SHIELD)
	if shield_at >= 0:
		_kinds[shield_at] = StackArt.KIND_SPENT_SHIELD
	_shake_and_flash()


func turn_gold() -> void:
	settle()
	create_tween().tween_property(self, "_gold", 1.0, GOLD_SECS)


# The top of the stack, for what comes out of it.
func top_point() -> Vector2:
	return Vector2(size.x / 2.0 + _offset_at(pieces - 1), _piece_y(pieces - 1))


func _table_y() -> float:
	return size.y - TABLE_HEIGHT


func _piece_y(index: int) -> float:
	var settled: float = _squash * SQUASH_PER_PIECE * index
	return _table_y() - (index + 1) * (art.piece_height() + PIECE_GAP) + settled


# How far piece `index` is off-centre right now: where it landed, plus the sway, which moves the top most.
func _offset_at(index: int) -> float:
	var lean: float = _leans[mini(index, _leans.size() - 1)]
	var height_share: float = index / SWAY_FULL_HEIGHT
	var speed: float = lerpf(SWAY_SPEED_CALM, SWAY_SPEED_RISKY, sway_share)
	var reach: float = SWAY_MOST * sway_share * pow(height_share, 1.5) * _sway_scale
	return lean + sin(clock * speed) * reach


# ── Drawing ──────────────────────────────────────────────────────────────────


func _draw() -> void:
	draw_set_transform(Vector2(_shake_x, 0.0))
	var centre_x: float = size.x / 2.0
	_draw_outline(centre_x)
	_draw_table(centre_x)
	if _dust >= 0.0 and _dust < 1.0:
		_draw_dust(centre_x)
	for index: int in pieces:
		_draw_stack_piece(index, centre_x)
	if _hovering:
		var trembling: float = randf_range(-HOVER_TREMBLE, HOVER_TREMBLE)
		var at: Vector2 = Vector2(
			centre_x + _offset_at(pieces) + trembling, _piece_y(pieces) - _hover_height
		)
		_draw_at(at, 0.0, pieces, PushYourLuckGame.TOKEN_VALUE, 1.0)
	draw_set_transform(Vector2(_shake_x, 0.0))
	if shields_up > 0 and _topple < 0.0 and _sweep < 0.0:
		_draw_shield_dome(centre_x)
	if _flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(UITheme.DANGER, _flash * FLASH_ALPHA))


# A dome over the stack for each shield held, so it can be seen as well as read. It's an oval that grows with the
# stack but stays inside the stage, outer domes and all.
func _draw_shield_dome(centre_x: float) -> void:
	var stack_height: float = pieces * (art.piece_height() + PIECE_GAP) + DOME_MARGIN
	var outer_domes: float = (shields_up - 1) * DOME_GAP + DOME_WIDTH
	var widest: float = maxf(size.x / 2.0 - outer_domes, art.piece_width() / 2.0)
	var tallest: float = maxf(_table_y() - outer_domes, DOME_SMALLEST_RADIUS)
	var across: float = minf(maxf(stack_height, DOME_SMALLEST_RADIUS), widest)
	var up: float = minf(maxf(stack_height, across), tallest)
	var colour: Color = Color(accent, DOME_ALPHA)
	for dome: int in shields_up:
		var grow: float = dome * DOME_GAP
		var points: PackedVector2Array = []
		for step: int in DOME_POINTS + 1:
			var angle: float = lerpf(PI, TAU, float(step) / DOME_POINTS)
			points.append(
				Vector2(
					centre_x + cos(angle) * (across + grow), _table_y() + sin(angle) * (up + grow)
				)
			)
		draw_polyline(points, colour, DOME_WIDTH, true)


# How tall the stack could get, so the empty space reads as somewhere to go.
func _draw_outline(centre_x: float) -> void:
	var half: float = art.piece_width() / 2.0
	var top: float = _table_y() - most_pieces * (art.piece_height() + PIECE_GAP)
	var colour: Color = Color(UITheme.TEXT_HINT, OUTLINE_ALPHA)
	var left: float = centre_x - half
	var right: float = centre_x + half
	var bottom: float = _table_y()
	draw_dashed_line(Vector2(left, bottom), Vector2(left, top), colour, 1.0, OUTLINE_DASH)
	draw_dashed_line(Vector2(right, bottom), Vector2(right, top), colour, 1.0, OUTLINE_DASH)
	draw_dashed_line(Vector2(left, top), Vector2(right, top), colour, 2.0, OUTLINE_DASH)


func _draw_table(centre_x: float) -> void:
	var top: float = _table_y()
	var half: float = art.piece_width() / 2.0 + TABLE_OVERHANG
	draw_colored_polygon(
		PackedVector2Array(
			[
				Vector2(centre_x - half, top),
				Vector2(centre_x + half, top),
				Vector2(centre_x + half + TABLE_INSET, top + TABLE_HEIGHT),
				Vector2(centre_x - half - TABLE_INSET, top + TABLE_HEIGHT),
			]
		),
		UITheme.BAR_BG
	)
	draw_line(Vector2(centre_x - half, top), Vector2(centre_x + half, top), UITheme.PURPLE_MID, 2.0)
	# A shadow under the stack, which goes when the stack does.
	if _topple < 0.0 and _sweep < 0.0:
		draw_set_transform(Vector2(centre_x + _shake_x, top), 0.0, Vector2(1.0, SHADOW_SQUASH))
		draw_circle(Vector2.ZERO, art.piece_width() / 2.0, Color(Color.BLACK, SHADOW_ALPHA))
		draw_set_transform(Vector2(_shake_x, 0.0))


func _draw_dust(centre_x: float) -> void:
	var colour: Color = Color(UITheme.WHITE_SOFT, DUST_ALPHA * (1.0 - _dust))
	for puff: int in DUST_PUFFS:
		var across: float = (float(puff) / (DUST_PUFFS - 1)) * 2.0 - 1.0
		var at: Vector2 = Vector2(
			centre_x + across * art.piece_width() / 2.0 + across * _dust * DUST_REACH,
			_table_y() - _dust * DUST_RADIUS
		)
		draw_circle(at, DUST_RADIUS * (0.4 + _dust), colour)


func _draw_stack_piece(index: int, centre_x: float) -> void:
	var at: Vector2 = Vector2(centre_x + _offset_at(index), _piece_y(index))
	var spin: float = 0.0
	var opacity: float = 1.0
	var shrink: float = 1.0
	if index == pieces - 1:
		at.y += _bounce
	if _topple >= 0.0:
		var fallen: Vector3 = art.fall(index, pieces, _topple)
		at.x += fallen.x
		spin = fallen.z
		# Down to the table, with bounces that die away.
		var bouncing: float = absf(sin(_topple * PI * BOUNCES)) * (1.0 - _topple) * BOUNCE_HEIGHT
		at.y = minf(at.y + fallen.y, _table_y() - art.piece_height()) - bouncing
		opacity = 1.0 - _topple * _topple
	elif _sweep >= 0.0:
		# The top pieces leave first.
		var wait: float = (1.0 - float(index + 1) / pieces) * SWEEP_STAGGER
		var going: float = clampf((_sweep - wait) / (1.0 - SWEEP_STAGGER), 0.0, 1.0)
		if going >= 1.0:
			return  # it's in the pot
		at = at.lerp(_sweep_target, going)
		opacity = 1.0 - going
		shrink = lerpf(1.0, SWEEP_END_SCALE, going)
	var kind: String = _kinds[index] if index < _kinds.size() else PushYourLuckGame.TOKEN_VALUE
	_draw_at(at, spin, index, kind, opacity, shrink)


func _draw_at(
	at: Vector2, spin: float, index: int, kind: String, opacity: float, shrink: float = 1.0
) -> void:
	draw_set_transform(at + Vector2(_shake_x, 0.0), spin, Vector2(shrink, shrink))
	art.draw_piece(self, index, kind, accent, _gold, opacity)
