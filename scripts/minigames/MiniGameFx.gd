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
