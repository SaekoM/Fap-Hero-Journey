class_name GameCharacterView
extends Control

# A cast character standing beside a mini-game, reacting to it. Shared by every game: a game only names
# its moments (MiniGameLibrary.GAME_CHARACTER_MOMENTS) and calls show_moment. Where the character stands is
# one of their own positions from CAST, the same boxes a storyboard stage uses. Each moment has its own
# portrait and its own transition into that portrait, from the cast's shared set (CastMotion).
#
# It sits behind the game's panel, so the game always stays readable and on top.

const DEFAULT_TRANSITION: String = CastMotion.FLIP

# The moment every game has: at rest, waiting on the player.
const REST_MOMENT: String = "idle"

var _character: Dictionary = {}
var _moments: Dictionary = {}
var _image: JourneyImage
var _shown_path: String = ""
var _moment: String = ""
var _generation: int = 0  # bumped by every change, so a pending return-to-rest knows it was overtaken


# Adds the game's character to `host`, just behind `in_front` (the game's panel), or returns null when the
# game has none or its character has since been deleted. The game plays on without one.
static func attach(host: Control, in_front: Control, definition: Dictionary) -> GameCharacterView:
	var block: Dictionary = definition.get("game_character", {})
	if block.is_empty():
		return null
	var character: Dictionary = {}
	for candidate: Variant in GameState.Journey.get("characters", []):
		if (
			candidate is Dictionary
			and str((candidate as Dictionary).get("id", "")) == str(block["character"])
		):
			character = candidate
	if character.is_empty() or (character.get("portraits", []) as Array).is_empty():
		return null
	var view: GameCharacterView = GameCharacterView.new()
	view._setup(character, block)
	host.add_child(view)
	host.move_child(view, in_front.get_index())
	view.show_moment(REST_MOMENT)
	return view


func _setup(character: Dictionary, block: Dictionary) -> void:
	_character = character
	_moments = block.get("moments", {})
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box: Dictionary = JourneyData.resolve_placement(
		str(block.get("placement", "")), character.get("placements", [])
	)
	anchor_left = clampf(float(box["x"]), 0.0, 1.0)
	anchor_top = clampf(float(box["y"]), 0.0, 1.0)
	anchor_right = clampf(float(box["x"]) + float(box["w"]), 0.0, 1.0)
	anchor_bottom = clampf(float(box["y"]) + float(box["h"]), 0.0, 1.0)
	_clear_offsets()
	_image = JourneyImage.new()
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_image)


# Changes to `moment`'s portrait through its transition. With `return_after` above 0, goes back to the rest
# moment after that many seconds, unless something else has happened by then. A moment the game doesn't
# have does nothing.
func show_moment(moment: String, return_after: float = 0.0) -> void:
	if not _moments.has(moment) or (moment == _moment and moment == REST_MOMENT):
		return
	_generation += 1
	var this_change: int = _generation
	var first_appearance: bool = _moment == ""
	_moment = moment
	var entry: Dictionary = _moments[moment]
	var path: String = JourneyData.character_portrait_path(
		_character, str(entry.get("portrait", ""))
	)
	if first_appearance:
		_swap_to(path)  # already there when the screen opens, not transitioning in
	else:
		_play_transition(str(entry.get("transition", DEFAULT_TRANSITION)), path)
	if return_after > 0.0:
		await get_tree().create_timer(return_after).timeout
		if is_inside_tree() and this_change == _generation:
			show_moment(REST_MOMENT)


func _play_transition(transition: String, path: String) -> void:
	CastMotion.change(self, transition, get_viewport_rect().size, _swap_to.bind(path))


func _clear_offsets() -> void:
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0


# Only reloads for a different portrait, so an animated one keeps running through a same-portrait reaction.
func _swap_to(path: String) -> void:
	if path != _shown_path:
		_shown_path = path
		_image.show_path(path, TextureRect.EXPAND_IGNORE_SIZE, JourneyImage.STRETCH_FIT_HEIGHT)
