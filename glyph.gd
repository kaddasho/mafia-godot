class_name Glyph
extends Control
## Small gold symbols drawn from shapes: roles (mafia hat, detective lens, doctor cross,
## citizen house), phases (moon, sun, ballot, crown) and the mafia face emblem.

var kind: String = "":
	set(v):
		kind = v
		queue_redraw()
var color: Color = UI.ACCENT


func _init(glyph_kind: String = "", px: float = 40.0) -> void:
	kind = glyph_kind
	custom_minimum_size = Vector2(px, px)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


static func for_role(role: String) -> String:
	return {"mafia": "hat", "detective": "lens", "doctor": "cross", "citizen": "house"}.get(role, "")


static func for_phase(phase: String) -> String:
	return {"night": "moon", "day": "sun", "vote": "ballot", "ended": "crown", "roles": "hat"}.get(phase, "")


func _draw() -> void:
	var s := minf(size.x, size.y)
	var c := size / 2
	var dark := UI.BG
	match kind:
		"hat":
			_hat(c, s, dark)
		"face":
			_face(c, s, dark)
		"lens":
			draw_arc(c + Vector2(-0.08, -0.08) * s, 0.24 * s, 0, TAU, 40, color, 0.07 * s, true)
			draw_line(c + Vector2(0.1, 0.1) * s, c + Vector2(0.36, 0.36) * s, color, 0.11 * s, true)
		"cross":
			draw_rect(Rect2(c + Vector2(-0.1, -0.34) * s, Vector2(0.2, 0.68) * s), color)
			draw_rect(Rect2(c + Vector2(-0.34, -0.1) * s, Vector2(0.68, 0.2) * s), color)
		"house":
			draw_colored_polygon(_pts(c, s, [Vector2(-0.38, -0.02), Vector2(0, -0.36), Vector2(0.38, -0.02)]), color)
			draw_rect(Rect2(c + Vector2(-0.28, -0.04) * s, Vector2(0.56, 0.38) * s), color)
			draw_rect(Rect2(c + Vector2(-0.07, 0.12) * s, Vector2(0.14, 0.22) * s), dark)
		"moon":
			Deco.crescent(self, c, 0.34 * s, -0.5, color)
		"sun":
			draw_circle(c, 0.18 * s, color)
			for i in 12:
				var a := TAU * i / 12.0
				draw_line(c + Vector2.from_angle(a) * 0.25 * s, c + Vector2.from_angle(a) * (0.38 if i % 2 == 0 else 0.32) * s, color, 0.05 * s, true)
		"ballot":
			draw_rect(Rect2(c + Vector2(-0.18, -0.38) * s, Vector2(0.36, 0.34) * s), Color(color, 0.85))
			draw_rect(Rect2(c + Vector2(-0.36, -0.06) * s, Vector2(0.72, 0.42) * s), color)
			draw_rect(Rect2(c + Vector2(-0.22, -0.06) * s, Vector2(0.44, 0.06) * s), dark)
		"crown":
			draw_colored_polygon(_pts(c, s, [
				Vector2(-0.38, 0.24), Vector2(-0.38, -0.2), Vector2(-0.19, 0.02), Vector2(0, -0.32),
				Vector2(0.19, 0.02), Vector2(0.38, -0.2), Vector2(0.38, 0.24)]), color)
			draw_rect(Rect2(c + Vector2(-0.38, 0.28) * s, Vector2(0.76, 0.08) * s), color)


func _pts(c: Vector2, s: float, unit: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector2 in unit:
		out.append(c + p * s)
	return out


## Fedora: wide brim, pinched crown, dark band.
func _hat(c: Vector2, s: float, dark: Color) -> void:
	draw_colored_polygon(Deco.ellipse(c + Vector2(0, 0.17) * s, 0.47 * s, 0.1 * s), color)
	draw_colored_polygon(_pts(c, s, [
		Vector2(-0.28, 0.17), Vector2(-0.25, -0.2), Vector2(-0.11, -0.3), Vector2(0, -0.23),
		Vector2(0.11, -0.3), Vector2(0.25, -0.2), Vector2(0.28, 0.17)]), color)
	draw_colored_polygon(_pts(c, s, [
		Vector2(-0.275, 0.06), Vector2(0.275, 0.06), Vector2(0.28, 0.14), Vector2(-0.28, 0.14)]), dark)


## The emblem: hat over a face lost in shadow, two glowing eyes.
func _face(c: Vector2, s: float, dark: Color) -> void:
	draw_colored_polygon(Deco.ellipse(c + Vector2(0, 0.2) * s, 0.24 * s, 0.3 * s), Color(color, 0.18))
	draw_colored_polygon(Deco.ellipse(c + Vector2(0, 0.2) * s, 0.22 * s, 0.28 * s), dark)
	_hat(c + Vector2(0, -0.17) * s, s * 0.95, dark)
	for side in [-1.0, 1.0]:
		var eye := c + Vector2(0.09 * side, 0.12) * s
		draw_circle(eye, 0.045 * s, Color(color, 0.25))
		draw_colored_polygon(Deco.ellipse(eye, 0.035 * s, 0.014 * s, 16), UI.ACCENT_SOFT)
