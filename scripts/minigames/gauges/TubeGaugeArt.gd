class_name TubeGaugeArt
extends VerticalGaugeArt

# A plain glass tube, the default. Overfilled, it cracks and the liquid runs down the outside.

const CRACKS: Array = [
	[Vector2(0.15, 0.0), Vector2(0.3, 0.1), Vector2(0.2, 0.2), Vector2(0.4, 0.3)],
	[Vector2(0.75, 0.0), Vector2(0.6, 0.12), Vector2(0.8, 0.22), Vector2(0.65, 0.34)],
]


func _draw_failure(stage: HoldGaugeStage, centre_x: float) -> void:
	super(stage, centre_x)
	_draw_cracks(stage, centre_x, CRACKS)
