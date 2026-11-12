class_name StackArt
extends RefCounted

# What one kind of Push Your Luck stack looks like, and how it falls. PushStackStage owns where the pieces are; an art
# draws one piece at a time, with the origin at the middle of its top edge. The look never changes the rules. So a new
# stack is one small subclass, an entry in STYLES and STYLE_NAMES, and a line in art_for.

const STYLE_CHIPS: String = "chips"
const STYLE_COINS: String = "coins"
const STYLE_BLOCKS: String = "blocks"
const STYLES: Array[String] = [STYLE_CHIPS, STYLE_COINS, STYLE_BLOCKS]
const STYLE_NAMES: Dictionary = {
	STYLE_CHIPS: "Casino chips",
	STYLE_COINS: "Gold coins",
	STYLE_BLOCKS: "Wooden blocks",
}
const DEFAULT_STYLE: String = STYLE_CHIPS

const GOLD: Color = Color(1.0, 0.8, 0.25)

# Shield and doubler pieces are their own colour in every look, with an emblem on the front, so they stand out from
# the value pieces round them. The emblem is there for colour-blind players as much as anyone.
const SHIELD_COLOUR: Color = Color(0.10, 0.85, 0.90)  # UITheme.CYAN
const DOUBLER_COLOUR: Color = Color(0.45, 1.0, 0.35)  # UITheme.TOXIC_GREEN
# A shield piece whose shield has taken a trap: greyed, with a crack across it. Not a token, only a look.
const KIND_SPENT_SHIELD: String = "spent_shield"
const SPENT_SHIELD_COLOUR: Color = Color(0.42, 0.5, 0.52)
const CRACK_COLOUR: Color = Color(0.0, 0.0, 0.0, 0.85)
const CRACK_WIDTH: float = 1.5
const CRACK_STEPS: int = 7
const EMBLEM_WIDTH: float = 30.0
const EMBLEM_INSET: float = 2.0
const EMBLEM_BACK_ALPHA: float = 0.75
const EMBLEM_FONT_SIZE: int = 11
const SHIELD_HALF_WIDTH: float = 4.0
const SHIELD_SHOULDER: float = 0.45  # how far down the shield's sides run straight before they meet at the point


static func art_for(style: String) -> StackArt:
	match style:
		STYLE_COINS:
			return CoinsStackArt.new()
		STYLE_BLOCKS:
			return BlocksStackArt.new()
	return ChipsStackArt.new()


# One piece of the stack. `kind` is the token it came from, so a shield or doubler can look like one. `gold` (0–1) is
# how far a maxed-out stack has turned gold.
func draw_piece(
	_stage: PushStackStage,
	_index: int,
	_kind: String,
	_accent: Color,
	_gold: float,
	_opacity: float
) -> void:
	pass


# The body colour for a piece of `kind`: `plain` for a value piece, its own colour for a shield or doubler.
static func kind_colour(kind: String, plain: Color) -> Color:
	match kind:
		PushYourLuckGame.TOKEN_SHIELD:
			return SHIELD_COLOUR
		PushYourLuckGame.TOKEN_DOUBLER:
			return DOUBLER_COLOUR
		KIND_SPENT_SHIELD:
			return SPENT_SHIELD_COLOUR
	return plain


# A dark plate across the middle of a shield or doubler piece, with a little shield or "×2" on it, and a crack
# across a spent shield. Nothing on a value piece.
func draw_emblem(stage: PushStackStage, kind: String, opacity: float) -> void:
	var is_shield: bool = kind == PushYourLuckGame.TOKEN_SHIELD or kind == KIND_SPENT_SHIELD
	if not is_shield and kind != PushYourLuckGame.TOKEN_DOUBLER:
		return
	var plate_height: float = piece_height() - EMBLEM_INSET * 2.0
	var plate: Rect2 = Rect2(-EMBLEM_WIDTH / 2.0, EMBLEM_INSET, EMBLEM_WIDTH, plate_height)
	stage.draw_rect(plate, Color(UITheme.BG, EMBLEM_BACK_ALPHA * opacity))
	var ink: Color = Color(kind_colour(kind, Color.WHITE), opacity)
	var middle_y: float = piece_height() / 2.0
	if is_shield:
		var top: float = EMBLEM_INSET + 1.0
		var bottom: float = piece_height() - EMBLEM_INSET - 1.0
		var shoulder: float = lerpf(top, bottom, SHIELD_SHOULDER)
		(
			stage
			. draw_colored_polygon(
				PackedVector2Array(
					[
						Vector2(-SHIELD_HALF_WIDTH, top),
						Vector2(SHIELD_HALF_WIDTH, top),
						Vector2(SHIELD_HALF_WIDTH, shoulder),
						Vector2(0.0, bottom),
						Vector2(-SHIELD_HALF_WIDTH, shoulder),
					]
				),
				ink
			)
		)
		if kind == KIND_SPENT_SHIELD:
			_draw_crack(stage, opacity)
		return
	var font: Font = ThemeDB.fallback_font
	var baseline: float = (
		middle_y + (font.get_ascent(EMBLEM_FONT_SIZE) - font.get_descent(EMBLEM_FONT_SIZE)) / 2.0
	)
	stage.draw_string(
		font,
		Vector2(-EMBLEM_WIDTH / 2.0, baseline),
		"×2",
		HORIZONTAL_ALIGNMENT_CENTER,
		EMBLEM_WIDTH,
		EMBLEM_FONT_SIZE,
		ink
	)


func piece_width() -> float:
	return 96.0


func piece_height() -> float:
	return 14.0


# How far off-centre a piece can land, either way, before the risk adds to it.
func misalignment() -> float:
	return 2.0


# How far a piece has come when the stack falls, `progress` (0–1) of the way through it: (across, down, spin).
func fall(_index: int, _count: int, _progress: float) -> Vector3:
	return Vector3.ZERO


func play_fall_sound() -> void:
	pass


# A jagged crack right across the piece, zigzagging between its top and bottom edges.
func _draw_crack(stage: PushStackStage, opacity: float) -> void:
	var half: float = piece_width() / 2.0 * 0.85
	var points: PackedVector2Array = []
	for step: int in CRACK_STEPS + 1:
		var x: float = lerpf(-half, half, float(step) / CRACK_STEPS)
		var y: float = piece_height() * (0.2 if step % 2 == 0 else 0.8)
		points.append(Vector2(x, y))
	stage.draw_polyline(points, Color(CRACK_COLOUR, CRACK_COLOUR.a * opacity), CRACK_WIDTH, true)
