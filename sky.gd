class_name PhaseSky
extends Control
## Full-screen background that tells the phase at a glance:
## night = starry black with a gold crescent, day = warm amber with a sunburst,
## vote = deep crimson rays, anything else = charcoal with faint gold rays.

const LOOKS := {
	"night": [Color("#040406"), Color("#0D0C12")],
	"day": [Color("#2B2112"), Color("#100D09")],
	"vote": [Color("#2A0C12"), Color("#0D0A0A")],
}

var phase: String = ""
var _stars := PackedVector3Array()  # x, y (0..1), twinkle offset
var _t: float = 0.0


func _init(sky_phase: String = "") -> void:
	phase = sky_phase
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 46:
		_stars.append(Vector3(rng.randf(), rng.randf() * 0.65, rng.randf() * TAU))


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)
	set_process(phase == "night")


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var look: Array = LOOKS.get(phase, [Color("#14120E"), UI.BG])
	draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(size.x, 0), size, Vector2(0, size.y)]),
		PackedColorArray([look[0], look[0], look[1], look[1]]))
	var top := Vector2(size.x / 2, 0)
	match phase:
		"night":
			for s in _stars:
				var a := 0.35 + 0.35 * sin(_t * 1.6 + s.z)
				Deco.diamond(self, Vector2(s.x * size.x, s.y * size.y), 1.6, Color(UI.ACCENT_SOFT, a))
			var moon := Vector2(size.x * 0.22, size.y * 0.62)
			draw_circle(moon, 120, Color(UI.ACCENT, 0.05))
			draw_circle(moon, 80, Color(UI.ACCENT, 0.05))
			Deco.crescent(self, moon, 62, -0.4, Color(UI.ACCENT_SOFT, 0.5))
		"day":
			Deco.sunburst(self, top, size.y * 0.9, 16, Color(UI.ACCENT, 0.09))
			draw_circle(top, 90, Color(UI.ACCENT, 0.12))
			draw_circle(top, 54, Color(UI.ACCENT_SOFT, 0.22))
		"vote":
			Deco.sunburst(self, top, size.y * 0.9, 16, Color(UI.CRIMSON, 0.22))
		_:
			Deco.sunburst(self, top, size.y * 0.9, 16, Color(UI.ACCENT, 0.04))
