class_name Deco
extends RefCounted
## Art deco drawing helpers shared by the custom-drawn controls (call them from inside _draw()).


static func ellipse(c: Vector2, rx: float, ry: float, n: int = 32) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / n
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts


## Fan of thin triangles from `center`, alternating strong/weak like a deco sunburst.
static func sunburst(ci: CanvasItem, center: Vector2, radius: float, rays: int, color: Color) -> void:
	var half := PI / rays * 0.5
	for i in rays * 2:
		var a := TAU * float(i) / (rays * 2)
		var c := color if i % 2 == 0 else Color(color, color.a * 0.45)
		ci.draw_colored_polygon(PackedVector2Array([
			center,
			center + Vector2.from_angle(a - half) * radius,
			center + Vector2.from_angle(a + half) * radius]), c)


## Crescent moon, horns pointing to the side `angle` points away from.
static func crescent(ci: CanvasItem, center: Vector2, r: float, angle: float, color: Color) -> void:
	var pts := PackedVector2Array()
	var steps := 24
	for i in steps + 1:
		var t := -PI / 2 + PI * i / steps
		pts.append(Vector2(-cos(t) * r, sin(t) * r))
	for i in range(steps, -1, -1):
		var t := -PI / 2 + PI * i / steps
		pts.append(Vector2(-cos(t) * r * 0.35, sin(t) * r))
	var xf := Transform2D(angle, center)
	ci.draw_colored_polygon(xf * pts, color)


## Rectangle with cut (chamfered) corners.
static func octagon(r: Rect2, cut: float) -> PackedVector2Array:
	var p := r.position
	var e := r.end
	return PackedVector2Array([
		Vector2(p.x + cut, p.y), Vector2(e.x - cut, p.y), Vector2(e.x, p.y + cut),
		Vector2(e.x, e.y - cut), Vector2(e.x - cut, e.y), Vector2(p.x + cut, e.y),
		Vector2(p.x, e.y - cut), Vector2(p.x, p.y + cut)])


static func diamond(ci: CanvasItem, c: Vector2, r: float, color: Color) -> void:
	ci.draw_colored_polygon(PackedVector2Array([
		c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)]), color)


## Horizontal gold rule with a diamond at the end that faces the title next to it.
class Rule:
	extends Control

	var flip := false

	func _init(flipped: bool = false) -> void:
		flip = flipped
		custom_minimum_size = Vector2(24, 12)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var y := size.y / 2
		var diamond_right := (not flip) != is_layout_rtl()
		var tip := size.x - 6 if diamond_right else 6.0
		var far := 0.0 if diamond_right else size.x
		draw_line(Vector2(far, y), Vector2(tip, y), Color(UI.ACCENT, 0.7), 1.5, true)
		Deco.diamond(self, Vector2(tip, y), 5, UI.ACCENT)
