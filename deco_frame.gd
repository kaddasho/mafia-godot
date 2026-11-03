class_name DecoFrame
extends PanelContainer
## Art deco card: dark fill with cut corners, a gold outline, a faint inner line and a diamond on top.
## `strength` 0..1 sets how bright the gold is (rows use a soft frame, the selected row a full one).

var fill: Color = UI.CARD:
	set(v):
		fill = v
		queue_redraw()
var line: Color = UI.ACCENT:
	set(v):
		line = v
		queue_redraw()
var strength: float = 1.0:
	set(v):
		strength = v
		queue_redraw()
var cut: float = 10.0


func _init(margin: int = 14, frame_strength: float = 1.0) -> void:
	strength = frame_strength
	var sb := StyleBoxEmpty.new()
	sb.set_content_margin_all(margin)
	add_theme_stylebox_override("panel", sb)
	resized.connect(queue_redraw)


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_colored_polygon(Deco.octagon(r, cut), fill)
	var outer := Deco.octagon(r.grow(-1), cut)
	outer.append(outer[0])
	draw_polyline(outer, Color(line, 0.25 + 0.75 * strength), 1.5, true)
	if strength >= 0.5:
		var inner := Deco.octagon(r.grow(-5), cut - 3)
		inner.append(inner[0])
		draw_polyline(inner, Color(line, 0.3 * strength), 1.0, true)
		Deco.diamond(self, Vector2(size.x / 2, 1), 4, line)
