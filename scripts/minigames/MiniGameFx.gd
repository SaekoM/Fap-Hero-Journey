class_name MiniGameFx
extends RefCounted

# Celebration effects the mini-games share.


# A burst of coins and sparks from `at` in `host`, cleaning up after itself. `strength` (0–1) is how big the
# moment is: at 0 it pops, at 1 it showers.
static func burst(host: Control, at: Vector2, strength: float) -> void:
	var sparks: CPUParticles2D = CPUParticles2D.new()
	sparks.position = at
	sparks.amount = roundi(lerpf(24.0, 96.0, strength))
	sparks.one_shot = true
	sparks.explosiveness = 0.9
	sparks.lifetime = 1.1
	sparks.direction = Vector2(0.0, -1.0)
	sparks.spread = 75.0
	sparks.initial_velocity_min = 160.0
	sparks.initial_velocity_max = lerpf(260.0, 420.0, strength)
	sparks.gravity = Vector2(0.0, 620.0)
	sparks.scale_amount_min = 3.0
	sparks.scale_amount_max = 7.0
	var colours: Gradient = Gradient.new()
	colours.set_color(0, UITheme.AMBER)
	colours.set_color(1, Color(UITheme.MINIGAME, 0.0))
	sparks.color_ramp = colours
	host.add_child(sparks)
	sparks.emitting = true
	host.get_tree().create_timer(sparks.lifetime + 0.3).timeout.connect(sparks.queue_free)


# Something other than coins flying out from `at` in `host`, cleaning up after itself: liquid, foam, steam.
static func spray(host: Control, at: Vector2, colour: Color, gravity: Vector2) -> void:
	var drops: CPUParticles2D = CPUParticles2D.new()
	drops.position = at
	drops.amount = 70
	drops.one_shot = true
	drops.explosiveness = 0.85
	drops.lifetime = 1.0
	drops.direction = Vector2(0.0, -1.0)
	drops.spread = 60.0
	drops.initial_velocity_min = 120.0
	drops.initial_velocity_max = 340.0
	drops.gravity = gravity
	drops.scale_amount_min = 2.0
	drops.scale_amount_max = 6.0
	var fade: Gradient = Gradient.new()
	fade.set_color(0, colour)
	fade.set_color(1, Color(colour, 0.0))
	drops.color_ramp = fade
	host.add_child(drops)
	drops.emitting = true
	host.get_tree().create_timer(drops.lifetime + 0.3).timeout.connect(drops.queue_free)


# A big banner across the screen for `hold_secs`, for a game's best moment, above the screen's own UI. It sweeps in
# from the side, or only fades in with REDUCE FLASHING on, and it goes when `host` does.
static func show_banner(host: Control, text: String, hold_secs: float) -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 10
	host.add_child(layer)
	var banner: Label = Label.new()
	banner.text = text
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner.set_anchors_and_offsets_preset(Control.PRESET_HCENTER_WIDE)
	banner.offset_top = -70.0
	banner.offset_bottom = 70.0
	UITheme.style_label(banner, UITheme.AMBER, 96)
	var backing: StyleBoxFlat = StyleBoxFlat.new()
	backing.bg_color = Color(0, 0, 0, 0.6)
	banner.add_theme_stylebox_override("normal", backing)
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(banner)
	banner.modulate.a = 0.0
	var arrive: Tween = banner.create_tween().set_parallel(true)
	arrive.tween_property(banner, "modulate:a", 1.0, 0.5)
	if not SettingsService.get_reduce_flashing():
		banner.position.x = -host.get_viewport_rect().size.x
		arrive.tween_property(banner, "position:x", 0.0, 0.5).set_trans(Tween.TRANS_BACK).set_ease(
			Tween.EASE_OUT
		)
	var leave: Tween = banner.create_tween()
	leave.tween_interval(hold_secs - 0.5)
	leave.tween_property(banner, "modulate:a", 0.0, 0.4)
	leave.tween_callback(layer.queue_free)
