class_name Avatar
extends Control
## Round player token: initial on a dark disc with a gold ring. A green halo shows while the
## player talks; the dead get a crimson cross.

var player_name: String = ""
var dead: bool = false
var talking: bool = false:
	set(v):
		if v != talking:
			talking = v
			queue_redraw()


func _init(n: String = "", is_dead: bool = false) -> void:
	player_name = n
	dead = is_dead
	custom_minimum_size = Vector2(42, 42)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var c := size / 2
	var r := minf(size.x, size.y) / 2 - 3
	if talking:
		draw_arc(c, r + 2, 0, TAU, 48, UI.TALKING, 3.0, true)
	draw_circle(c, r, UI.AVATAR)
	draw_arc(c, r - 1, 0, TAU, 48, Color(UI.ACCENT, 0.35 if dead else 0.9), 1.5, true)
	var font := get_theme_default_font()
	var fs := int(r * 0.95)
	var initial := player_name.substr(0, 1).to_upper()
	var text_size := font.get_string_size(initial, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var base := c + Vector2(-text_size.x / 2, font.get_ascent(fs) - text_size.y / 2)
	draw_string(font, base, initial, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(UI.TEXT, 0.4 if dead else 1.0))
	if dead:
		var d := r * 0.55
		draw_line(c + Vector2(-d, -d), c + Vector2(d, d), UI.CRIMSON, 3.0, true)
		draw_line(c + Vector2(d, -d), c + Vector2(-d, d), UI.CRIMSON, 3.0, true)
