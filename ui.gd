class_name UI
extends RefCounted
## Shared colours and small helpers that build styled controls from code.
## Look: 1920s art deco - charcoal black, gold lines, a touch of crimson.

const BG := Color("#0D0C0A")
const CARD := Color("#191612")
const CARD2 := Color("#12100D")
const AVATAR := Color("#2A241A")
const TEXT := Color("#F3EBD9")
const MUTED := Color("#8E8470")
const SILVER := Color("#CDBF9E")
const ACCENT := Color("#C9A44C")  # gold
const ACCENT_SOFT := Color("#EAD7A0")
const INK := Color("#17130C")  # text on gold
const CRIMSON := Color("#8E1B2C")
const CLEAR := Color(0, 0, 0, 0)
const TALKING := Color("#5FD39A")


static func box(color: Color, radius: int = 16, border: Color = CLEAR, border_w: int = 0, margin: int = 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	if border_w > 0:
		s.border_color = border
		s.set_border_width_all(border_w)
	s.set_content_margin_all(margin)
	return s


static func label(text: String, size: int = 16, color: Color = TEXT, center: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


## "primary" = solid gold with dark text; "ghost" = gold outline.
static func button(text: String, kind: String = "primary") -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 52)
	b.add_theme_font_size_override("font_size", 18)
	var font := INK if kind == "primary" else TEXT
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, font)
	b.add_theme_color_override("font_disabled_color", Color(TEXT, 0.4))
	var normal: StyleBoxFlat
	var pressed: StyleBoxFlat
	if kind == "ghost":
		normal = box(Color(CARD2, 0.6), 6, Color(ACCENT, 0.55), 1, 8)
		pressed = box(Color(ACCENT, 0.16), 6, ACCENT, 1, 8)
	else:
		normal = box(ACCENT, 6, ACCENT_SOFT, 1, 8)
		pressed = box(ACCENT_SOFT, 6, ACCENT_SOFT, 1, 8)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("disabled", box(Color(MUTED, 0.12), 6, Color(MUTED, 0.25), 1, 8))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


static func field(placeholder: String, text: String = "") -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.alignment = HORIZONTAL_ALIGNMENT_CENTER
	e.custom_minimum_size = Vector2(0, 52)
	e.add_theme_font_size_override("font_size", 18)
	e.add_theme_color_override("font_color", TEXT)
	e.add_theme_color_override("font_placeholder_color", MUTED)
	e.add_theme_color_override("caret_color", ACCENT)
	e.add_theme_stylebox_override("normal", box(CARD2, 6, Color(ACCENT, 0.3), 1, 12))
	e.add_theme_stylebox_override("focus", box(CARD2, 6, ACCENT, 1, 12))
	return e


## Title between two gold rules:  ◆──── text ────◆
static func ornament_title(text: String, size: int, color: Color = ACCENT) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(Deco.Rule.new(false))
	var l := label(text, size, color, true)
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	row.add_child(l)
	row.add_child(Deco.Rule.new(true))
	return row


## Small pill-shaped tag (role, host, ...).
static func chip(text: String, bg: Color, fg: Color = ACCENT_SOFT) -> PanelContainer:
	var chip_box := PanelContainer.new()
	chip_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip_box.add_theme_stylebox_override("panel", box(bg, 4, Color(ACCENT, 0.4), 1, 5))
	var l := label(text, 12, fg)
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip_box.add_child(l)
	return chip_box


static func avatar(player_name: String, dead: bool = false) -> Avatar:
	return Avatar.new(player_name, dead)


static func set_talking(a: Avatar, talking: bool) -> void:
	a.talking = talking
