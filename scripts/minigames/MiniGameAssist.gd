class_name MiniGameAssist
extends RefCounted

# The player's accessibility assist for mini-games (Options → Accessibility): more time on anything timed. Authors
# set the difficulty everyone starts from, so a run that plays any game with this on is marked ASSISTED.

const ASSISTED_TIME_SCALE: float = 1.5


# What a game's timings are multiplied by.
static func time_scale() -> float:
	return ASSISTED_TIME_SCALE if SettingsService.get_minigame_assist() else 1.0


# Call as a game begins: the mark stays on the run even if the switch goes off later.
static func note_game_started() -> void:
	if SettingsService.get_minigame_assist():
		GameState.MarkMiniGameAssisted()
