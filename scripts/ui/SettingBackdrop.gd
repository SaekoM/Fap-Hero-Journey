class_name SettingBackdrop
extends RefCounted

# Draws a setting's background behind a screen's own UI.
#
# Shops, forks and checkpoints each own a full-screen dimming ColorRect ($Backdrop) that the rest of
# their layout sits on top of. A setting's art goes UNDER that rect rather than replacing it: the dim
# is what keeps white text legible over an arbitrary photograph, and a backdrop that made its own
# screen unreadable would be a worse default than no backdrop at all.
#
# The storyboard does not use this — its background IS the screen, drawn edge to edge with the VN bar
# over it, so it owns its own JourneyImage and its own framing.

# How much dim stays over a setting's art. One constant for every screen, so a journey does not change
# legibility depending on which surface it is looking at. Once the per-screen layout work lands and a
# shop can be arranged around its art, this is the first thing that should become authorable.
const SCRIM_ALPHA: float = 0.5


# Puts a JourneyImage behind `backdrop` and shows the setting's background, if the node names one.
# Returns the view when something was drawn, so a caller can fade or reposition it later; null when
# there was nothing to draw, which is the normal case for a journey that uses no settings.
static func attach(host: Control, backdrop: Control, node: Dictionary) -> JourneyImage:
	return attach_view(host, backdrop, JourneyData.resolved_background_view(_settings(), node))


# The background a node's setting resolves to, or "". Split from attach so a caller that needs the
# answer before it has a backdrop to hang art behind can ask for it on its own.
static func background_for(node: Dictionary) -> String:
	return JourneyData.resolved_background(_settings(), node)


static func _settings() -> Array:
	return GameState.Journey.get("settings", [])


# Draws an already-resolved path. Separate from attach so a screen that builds its dim from the answer
# can resolve once rather than twice.
static func attach_view(host: Control, backdrop: Control, view: Dictionary) -> JourneyImage:
	if str(view.get("path", "")) == "":
		return null  # nothing authored: the screen keeps the dim it shipped with

	var image: JourneyImage = JourneyImage.new()
	# NOT set_anchors_preset: that sets anchors alone and re-derives offsets from the node's CURRENT
	# rect, which is 0x0 for one that has never been laid out — so the image silently never draws.
	image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE  # never eats a click meant for the UI above it
	host.add_child(image)
	host.move_child(image, backdrop.get_index())  # under the dim, under everything else
	# Covered is the right default here: these screens are full-bleed, and letterboxing a backdrop
	# behind a UI panel reads as a mistake. An author who wants the whole image says so per background.
	image.show_background(view, TextureRect.STRETCH_KEEP_ASPECT_COVERED)

	# These screens dim heavily (a fork at 0.92 is all but opaque) because behind them sits a paused
	# video frame that must not read as part of the UI. The backdrop art does that covering job now, so
	# the dim becomes a scrim: enough that white text stays legible over an arbitrary photograph, little
	# enough that the art was worth authoring.
	if backdrop is ColorRect:
		var rect: ColorRect = backdrop
		rect.color = Color(rect.color.r, rect.color.g, rect.color.b, SCRIM_ALPHA)
	return image
