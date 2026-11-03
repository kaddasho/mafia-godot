class_name Backdrop
extends Control
## The start-screen illustration, drawn from shapes: a gold deco sunburst behind a big moon,
## a skyline with lit windows, three hat silhouettes in front.

const FIG := Color("#050403")
const RED := Color("#8E1B2C")
const SKY := Color("#16130F")


func _ready() -> void:
	resized.connect(queue_redraw)


func _ellipse(c: Vector2, rx: float, ry: float) -> PackedVector2Array:
	return Deco.ellipse(c, rx, ry, 24)


## kind 0 = boss with red tie, 1 = lady with feather, 2 = capped man with scarf
func _figure(origin: Vector2, sc: float, mirror: bool, kind: int) -> void:
	var sx := -sc if mirror else sc
	draw_set_transform(origin, 0.0, Vector2(sx, sc))
	var body := PackedVector2Array([
		Vector2(10, 300), Vector2(20, 150), Vector2(48, 112), Vector2(70, 106),
		Vector2(92, 112), Vector2(120, 150), Vector2(130, 300)])
	draw_colored_polygon(body, FIG)
	draw_rect(Rect2(60, 92, 20, 22), FIG)
	draw_colored_polygon(_ellipse(Vector2(70, 78), 19.0, 23.0), FIG)
	draw_colored_polygon(_ellipse(Vector2(70, 56), 50.0, 9.0), FIG)
	var crown := PackedVector2Array([
		Vector2(36, 54), Vector2(40, 34), Vector2(56, 24), Vector2(84, 24),
		Vector2(100, 34), Vector2(104, 54)])
	draw_colored_polygon(crown, FIG)
	draw_rect(Rect2(38, 44, 64, 7), RED)
	if kind == 0:
		var tie := PackedVector2Array([Vector2(65, 118), Vector2(75, 118), Vector2(79, 168), Vector2(70, 182), Vector2(61, 168)])
		draw_colored_polygon(tie, RED)
	elif kind == 1:
		var feather := PackedVector2Array([Vector2(96, 48), Vector2(112, 34), Vector2(118, 20), Vector2(122, 8), Vector2(106, 24), Vector2(92, 42)])
		draw_colored_polygon(feather, RED)
	else:
		var scarf := PackedVector2Array([Vector2(52, 110), Vector2(70, 126), Vector2(88, 110), Vector2(88, 126), Vector2(70, 142), Vector2(52, 126)])
		draw_colored_polygon(scarf, RED)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw() -> void:
	var s := size.x / 390.0
	var bottom := size.y / s
	var c := Vector2(195, 175) * s
	Deco.sunburst(self, c, 520.0 * s, 18, Color(UI.ACCENT, 0.07))
	for i in 3:
		draw_arc(c, (118.0 + i * 22.0) * s, 0.0, TAU, 72, Color(UI.ACCENT, 0.35 - i * 0.1), 1.5, true)
	draw_circle(c, 98.0 * s, Color(UI.ACCENT, 0.18))
	draw_circle(c, 92.0 * s, Color("#E9D9AE"))
	var craters := [
		[Vector2(170, 150), 14.0], [Vector2(218, 198), 10.0],
		[Vector2(182, 206), 6.0], [Vector2(214, 140), 5.0]]
	for cr in craters:
		var p: Vector2 = cr[0]
		var r: float = cr[1]
		draw_circle(p * s, r * s, Color("#C9B47E", 0.55))
	var stars := PackedVector2Array([
		Vector2(34, 44), Vector2(88, 98), Vector2(330, 38), Vector2(362, 112),
		Vector2(58, 152), Vector2(346, 182), Vector2(130, 30), Vector2(268, 64)])
	for p in stars:
		Deco.diamond(self, p * s, 2.2 * s, Color(UI.ACCENT_SOFT, 0.8))
	var blocks := [
		Rect2(0, 330, 46, 0), Rect2(44, 290, 34, 0), Rect2(76, 345, 40, 0),
		Rect2(262, 350, 40, 0), Rect2(300, 300, 42, 0), Rect2(340, 335, 50, 0)]
	for b: Rect2 in blocks:
		var h := bottom - b.position.y
		draw_rect(Rect2(b.position * s, Vector2(b.size.x, h) * s), SKY)
		# stepped deco roof
		draw_rect(Rect2((b.position + Vector2(b.size.x * 0.25, -10)) * s, Vector2(b.size.x * 0.5, 10) * s), SKY)
		draw_line(b.position * s, (b.position + Vector2(b.size.x, 0)) * s, Color(UI.ACCENT, 0.35), 1.0)
	var lights := PackedVector2Array([
		Vector2(12, 352), Vector2(54, 314), Vector2(88, 372),
		Vector2(312, 326), Vector2(356, 362), Vector2(26, 380), Vector2(326, 362)])
	for p in lights:
		draw_rect(Rect2(p * s, Vector2(5, 7) * s), Color(UI.ACCENT, 0.55))
	_figure(Vector2(4, 216) * s, 0.78 * s, false, 1)
	_figure(Vector2(386, 216) * s, 0.78 * s, true, 2)
	_figure(Vector2(125, 150) * s, s, false, 0)
	# fade the bottom of the picture into the page so the buttons stay readable
	var fade_top := 330.0 * s
	draw_polygon(PackedVector2Array([
		Vector2(0, fade_top), Vector2(size.x, fade_top), Vector2(size.x, size.y), Vector2(0, size.y)]),
		PackedColorArray([Color(UI.BG, 0), Color(UI.BG, 0), Color(UI.BG, 0.97), Color(UI.BG, 0.97)]))
