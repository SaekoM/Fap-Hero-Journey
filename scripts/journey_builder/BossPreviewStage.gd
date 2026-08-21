class_name BossPreviewStage
extends Control
## The encounter editor's picture: the round's video with the round's OWN cue layer, audio, sensory
## engine, health bar and scheduler running over it.
##
## Extracted from BossTimelineEditor because "the preview matches the round" is a contract, not a
## coincidence, and it kept quietly breaking while the wiring for it was scattered through a 2200-line
## modal. Every part here is the same class the GameLoop drives — BossCueLayer, BossAudioCues,
## SensoryFX, EffectWindowFades, BossHud, RoundTimelineScheduler — so an author tuning a fade, a
## placement or a line's position is tuning the thing that will actually play. Anything that has to be
## reimplemented here rather than reused is a bug waiting to happen; there is deliberately none of it.
##
## Attacks are the one exception and are skipped on purpose: the device is driven solely by
## ▶ TEST ON DEVICE, so scrubbing the timeline can never jerk it.
##
## Knows nothing about the timeline document, selection, undo or the inspector. It is handed a timeline
## to rebuild against, told to seek, and reports where the playhead reached.

## The author clicked the picture, which is how they get back to the encounter's own settings.
signal deselect_requested

## Playback reached `position_ms` this frame. Only while actually playing — a paused stage is silent.
signal advanced(position_ms: int)

var _video: VideoStreamPlayer = null
var _video_rect: TextureRect = null  # draws the hidden player's frames at their native aspect
var _cues: BossCueLayer = null
var _hud: BossHud = null
var _audio: BossAudioCues = null
var _fx: SensoryFX = null
var _message: Label = null

var _scheduler: RoundTimelineScheduler = null
var _fades: EffectWindowFades = EffectWindowFades.new()
# id → the effect event, for every window currently open. Held so a fade tick can re-push them.
var _open_effects: Dictionary = {}

var _characters: Array = []  # the journey's cast, so a cue can resolve a character's portrait
var _timeline: Dictionary = {}
var _full_ms: int = 1
var _muted: bool = false

# ── Building ─────────────────────────────────────────────────────────────────


## Builds the stage. `characters` is the journey's cast, used to resolve a cue's portrait exactly as
## the GameLoop resolves it from the journey.
func build(characters: Array) -> void:
	_characters = characters
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip_contents = true

	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = UITheme.BG
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	# VideoStreamPlayer has NO aspect-preserving stretch — only `expand`, which distorts. So it runs
	# HIDDEN as a decoder and a TextureRect draws its frames letterboxed at their native aspect, the same
	# arrangement JourneyImage uses for animated art. The player still owns the clock, so seeking and
	# pausing are unaffected.
	_video = VideoStreamPlayer.new()
	_video.expand = true
	_video.visible = false
	_video.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_video.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_video)

	_video_rect = TextureRect.new()
	_video_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_video_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_video_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_video_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_video_rect)

	# The SAME renderer the round uses, so a cue previews exactly as it will play.
	_cues = BossCueLayer.new()
	_cues.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_cues)

	# Added AFTER the cue layer, because the round parents this above the cues too — an author checking
	# whether a line clears the bar has to see them stack in the same order.
	_hud = BossHud.new()
	add_child(_hud)

	# Shown instead of the picture when there is nothing to show — and, importantly, WHY (see
	# load_video). A silently black stage reads as a bug.
	_message = Label.new()
	_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.style_label(_message, UITheme.AMBER, 13)
	add_child(_message)

	_audio = BossAudioCues.new()
	# Ducking previews too: a narration cue pulls the round's video down under it, so an author can hear
	# whether the line actually lands. The stage owns its video's volume, exactly as the GameLoop owns
	# the round's.
	_audio.duck_changed.connect(
		func(factor: float) -> void: _video.volume_db = BossAudioCues.duck_db(factor)
	)
	add_child(_audio)

	# The round's own sensory engine, so blackout / murk / tunnel / strobe preview exactly as they play.
	_fx = SensoryFX.new()
	add_child(_fx)
	# The audio lives on the hidden player, the picture on the TextureRect that draws it — so the shader
	# material has to land on the latter or the visual effects would be applied to a node nobody sees.
	_fx.setup(_video, self, _video_rect)

	# Clicking the picture deselects, which is how you get back to the encounter's settings. This is a
	# catcher ADDED LAST rather than a handler on the stage itself: the backdrop and every SensoryFX
	# overlay default to MOUSE_FILTER_STOP, so a stage-level handler never saw the click.
	var click_catcher: Control = Control.new()
	click_catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	click_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	click_catcher.gui_input.connect(
		func(event: InputEvent) -> void:
			if (
				event is InputEventMouseButton
				and (event as InputEventMouseButton).pressed
				and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
			):
				deselect_requested.emit()
	)
	add_child(click_catcher)


## Opens the round's video, or explains on the stage why it cannot. Safe to call with an empty path.
func load_video(video_path: String) -> void:
	if video_path == "":
		_set_message("This round has no video — the encounter is still authored against its clock.")
		return
	if not ClassDB.class_exists("FFmpegVideoStream"):
		_set_message(
			"Video preview needs the FFmpeg extension; the timeline still works without it."
		)
		return
	# The decoder handles 8-bit 4:2:0 H.264 only. An author's own source is frequently something else
	# (HEVC, 10-bit, AV1), and it is the SAVE that transcodes it into the pooled copy the round plays.
	# Rather than trying to transcode here — the editor is not the place for a multi-minute encode — say
	# so, so a black stage reads as "save first", not as a broken preview.
	var info: Dictionary = MediaPoolService.probe_stream_info(video_path)
	if MediaPoolService.classify_transcode(str(info["codec"]), str(info["pix_fmt"]), false) != "":
		_set_message(
			(
				"Save the journey to prepare this round's video, then reopen the encounter — "
				+ "preview needs the saved copy.\nEverything else here works now, and your events are kept."
			)
		)
		return

	# Same decode path (and same H.264-only limit) as the round player and the clip editor.
	var stream: Resource = ClassDB.instantiate("FFmpegVideoStream")
	stream.set("file", ProjectSettings.globalize_path(video_path))
	_video.stream = stream as VideoStream
	_video.play()
	_video.paused = true  # parked on the first frame until the author presses play
	_set_message("")


## False while the stage is showing a reason it cannot play, so the transport can disable itself.
func has_media() -> bool:
	return _video != null and _video.stream != null


# ── Driving ──────────────────────────────────────────────────────────────────


## Re-arms everything against a changed timeline and lands on `playhead_ms`. Called whenever an event
## is added, moved or edited — the scheduler is rebuilt rather than patched, which is cheap and cannot
## drift from the document.
func rebuild(timeline: Dictionary, full_ms: int, playhead_ms: int) -> void:
	_timeline = timeline
	_full_ms = maxi(1, full_ms)
	_rebuild_hud()
	_scheduler = RoundTimelineScheduler.new(_timeline, _full_ms)
	_cues.clear_all()
	_open_effects.clear()
	_fades.clear()  # a jump lands where it lands; ramps do not carry across a scrub
	_apply(_scheduler.seek(playhead_ms))


## Jumps to `ms`. seek() (rather than tick()) is deliberate: it reconciles windows and re-arms one-shots
## for the new position instead of firing everything in between — exactly what a scrub should do, and
## exactly what the runtime does on a device re-anchor.
func seek(ms: int) -> void:
	if _video != null and _video.stream != null:
		_video.stream_position = ms / 1000.0
	if _scheduler == null:
		return
	_cues.clear_all()  # cues from the old position are not ours any more
	_hud.kill_phase_tween()  # nor is a banner announcing a phase we just scrubbed past
	_open_effects.clear()
	_fades.clear()
	_apply(_scheduler.seek(ms))


## Starts or stops playback, returning whether it is now playing.
func toggle_play() -> bool:
	if not has_media():
		return false
	_video.paused = not _video.paused
	if _video.paused:
		# Leave the stage as it is, but stop any sound that was mid-cue.
		_audio.stop_all()
	return not _video.paused


func is_playing() -> bool:
	return has_media() and not _video.paused


func set_muted(muted: bool) -> void:
	_muted = muted
	if muted:
		_audio.stop_all()


## Silences everything. The modal is closing, or the author left the encounter.
func shutdown() -> void:
	if is_instance_valid(_audio):
		_audio.stop_all()
	if is_instance_valid(_video):
		_video.stop()


func _process(delta: float) -> void:
	if _video == null or _video.stream == null:
		return
	# Re-read the frame every tick INCLUDING while paused: the stage is parked paused on open and after
	# every scrub, and only refreshing during playback would leave it black exactly when the author is
	# lining an event up against a still.
	_video_rect.texture = _video.get_video_texture()
	# "Tremor" is COMPUTED by SensoryFX but applied by whoever owns the picture — the round does the
	# same thing to its video node. Assigned (not accumulated) so the shake stays centred on the
	# anchored position instead of drifting off screen.
	if _fx != null:
		_video_rect.position = _fx.tremor_offset()
	if _video.paused:
		return
	_tick_fades(delta)
	var position_ms: int = int(_video.stream_position * 1000.0)
	_hud.set_round_progress(float(position_ms) / float(_full_ms))
	if _scheduler != null:
		_apply(_scheduler.tick(position_ms))
	advanced.emit(position_ms)


# ── Applying the scheduler's decisions ───────────────────────────────────────


# Applies one tick's decisions to the STAGE only. Attacks are skipped on purpose — the device is driven
# solely by ▶ TEST ON DEVICE, so scrubbing cannot jerk it.
func _apply(decisions: Dictionary) -> void:
	for event: Dictionary in decisions["stop"] as Array:
		if str(event.get("track", "")) == RoundTimeline.TRACK_CAST:
			_cues.clear(str(event.get("id", "")))
		elif str(event.get("track", "")) == RoundTimeline.TRACK_EFFECT:
			var closing: String = str(event.get("id", ""))
			# Held open while it eases out, exactly as the round holds it — the ramp reports when it is
			# finally done and _tick_fades drops it then.
			if not _fades.end(closing, event):
				_open_effects.erase(closing)
	for event: Dictionary in decisions["start"] as Array:
		if str(event.get("track", "")) == RoundTimeline.TRACK_CAST:
			_cues.show_cue(event, _image_path(event), false)
		elif str(event.get("track", "")) == RoundTimeline.TRACK_EFFECT:
			var opening: String = str(event.get("id", ""))
			_open_effects[opening] = event
			_fades.begin(opening, event)
	_reconcile_fx()
	if bool(decisions.get("phase_changed", false)):
		var phase: Dictionary = decisions.get("phase", {})
		if bool(phase.get("banner", false)):
			_hud.show_phase(str(phase.get("name", "")).strip_edges())
	for event: Dictionary in decisions["fire"] as Array:
		match str(event.get("track", "")):
			RoundTimeline.TRACK_CAST:
				_cues.show_cue(event, _image_path(event), true)
			RoundTimeline.TRACK_AUDIO:
				if not _muted:
					_audio.play_cue(event)


# Advances the ease ramps and re-pushes what moved, dropping any window that has finished fading out.
# Mirrors GameLoop._tick_window_fades — same object, same rules.
func _tick_fades(delta: float) -> void:
	if not _fades.is_active():
		return
	var result: Dictionary = _fades.tick(delta)
	for id: String in result["finished"] as Array:
		_open_effects.erase(id)
	if not (result["changed"] as Array).is_empty() or not (result["finished"] as Array).is_empty():
		_reconcile_fx()


# Pushes every open window's effects at the sensory engine as one set, which is how the round does it —
# reconciling rather than toggling means overlapping windows compose instead of fighting.
func _reconcile_fx() -> void:
	if _fx == null:
		return
	var requests: Array = []
	# "Blinded" (blackout) is NOT a sensory-layer effect: the round applies it by hiding the video
	# outright, so the preview has to do the same or the one effect an author most expects to see would
	# silently do nothing.
	var blackout: bool = false
	for id: Variant in _open_effects:
		for raw: Variant in (_open_effects[id] as Dictionary).get("effects", []):
			if not (raw is Dictionary):
				continue
			var kind: String = str((raw as Dictionary).get("kind", ""))
			if kind == "blackout":
				blackout = true
				continue
			if JourneyData.is_sensory_kind(kind):
				(
					requests
					. append(
						{
							"roll": JourneyData.sensory_entry_by_kind(kind),
							# Scaled by this window's ease factor — the same ramp the round uses, so a
							# fade previews as it will play instead of snapping on.
							"intensity":
							(
								float((raw as Dictionary).get("intensity", 1.0))
								* _fades.factor(str(id))
							),
						}
					)
				)
	_fx.reconcile(requests)
	# Only the picture goes dark — cues and subtitles keep drawing over it, exactly as they do in a
	# blinded round.
	_video_rect.visible = not blackout


# Re-dresses the encounter chrome from the timeline's own settings. Torn down and rebuilt rather than
# mutated, because the phase ticks are children of the bar and the marks move whenever a phase does.
func _rebuild_hud() -> void:
	# Removed from the tree at once, not merely queued: a queued child is still laid out for the rest of
	# the frame, so the old bar would appear stacked under the new one on every rebuild.
	_hud.kill_phase_tween()
	for child: Node in _hud.get_children():
		_hud.remove_child(child)
		child.queue_free()
	_hud.visible = bool(_timeline.get("hp_bar", true))
	if not _hud.visible:
		return
	var marks: Array = []
	if bool(_timeline.get("phase_ticks", true)):
		for phase: Dictionary in RoundTimeline.resolved_phases(_timeline, _full_ms):
			marks.append(float(phase["resolved_at_ms"]) / float(_full_ms))
	_hud.setup(str(_timeline.get("boss_name", "")), marks)


# A cue's art: the named character's portrait when it has one, otherwise the cue's own image. The same
# resolution GameLoop._cue_image_path performs against the saved journey.
func _image_path(cue: Dictionary) -> String:
	var character_id: String = str(cue.get("character_id", ""))
	if character_id != "":
		for raw: Variant in _characters:
			if raw is Dictionary and str((raw as Dictionary).get("id", "")) == character_id:
				var portrait: String = JourneyData.character_portrait_path(
					raw as Dictionary, str(cue.get("portrait", ""))
				)
				if portrait != "":
					return portrait
	return str(cue.get("image", ""))


# Puts a reason on the stage, or clears it.
func _set_message(text: String) -> void:
	_message.text = text
	_message.visible = text != ""
