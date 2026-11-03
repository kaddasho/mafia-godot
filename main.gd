extends Control
## Root: applies theme + text direction, switches between screens, shows messages from the server.

var _current: Control
var _toast_panel: PanelContainer
var _toast_label: Label
var _toast_id: int = 0
var _banner: PanelContainer


func _ready() -> void:
	Net.load_settings()
	Loc.lang = Net.saved_lang if Loc.LANGS.has(Net.saved_lang) else "ar"

	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Cairo", "Noto Sans Arabic", "Segoe UI", "Tahoma", "Arial", "sans-serif"])
	var th := Theme.new()
	th.default_font = font
	th.default_font_size = 16
	theme = th

	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_apply_direction()
	_make_toast()
	Loc.language_changed.connect(_on_language_changed)
	Net.message.connect(_on_message)
	Net.connection_changed.connect(_on_connection)
	_show_home()
	Net.connect_to_server()


func _apply_direction() -> void:
	layout_direction = Control.LAYOUT_DIRECTION_RTL if Loc.lang == "ar" else Control.LAYOUT_DIRECTION_LTR


func _set_screen(screen: Control) -> void:
	if _current != null:
		_current.queue_free()
	_current = screen
	add_child(screen)
	move_child(_banner, get_child_count() - 1)
	move_child(_toast_panel, get_child_count() - 1)


func _show_home() -> void:
	_set_screen(HomeScreen.new())


## Lobby while the room waits, game screen once it starts; reuses the current screen when it fits.
func _show_room(rebuild: bool = false) -> void:
	var in_game := str(Net.room.get("phase", "lobby")) != "lobby"
	if in_game:
		if _current is GameScreen and not rebuild:
			(_current as GameScreen).update_room(Net.room)
		else:
			_set_screen(GameScreen.new())
	else:
		if _current is LobbyScreen and not rebuild:
			(_current as LobbyScreen).update_room(Net.room)
		else:
			_set_screen(LobbyScreen.new())


func _in_room() -> bool:
	return _current is LobbyScreen or _current is GameScreen


func _on_language_changed() -> void:
	Net.save_settings()
	_apply_direction()
	(_banner.get_child(0) as Label).text = Loc.t("reconnecting")
	if _in_room() and not Net.room.is_empty():
		_show_room(true)
	else:
		_show_home()


func _on_message(m: Dictionary) -> void:
	_banner.visible = Net.reconnecting
	match str(m.get("t", "")):
		"room", "role":
			if Net.room.is_empty():
				return
			_show_room()
		"left":
			if bool(m.get("lost", false)):
				toast(Loc.t("connection_lost"))
			_show_home()
		"error":
			toast(Loc.t("err_" + str(m.get("code", ""))))


## While Net is reconnecting the room stays on screen under a banner; otherwise a lost room means home.
func _on_connection(ok: bool) -> void:
	_banner.visible = Net.reconnecting
	if not ok and not Net.reconnecting and _in_room():
		toast(Loc.t("connection_lost"))
		_show_home()


func _make_toast() -> void:
	_toast_panel = PanelContainer.new()
	_toast_panel.visible = false
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.add_theme_stylebox_override("panel", UI.box(UI.CRIMSON, 6, UI.ACCENT, 1, 12))
	_toast_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toast_panel.offset_top = -110
	_toast_label = UI.label("", 15, UI.ACCENT_SOFT, true)
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_toast_panel.add_child(_toast_label)
	add_child(_toast_panel)

	_banner = PanelContainer.new()
	_banner.visible = false
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_theme_stylebox_override("panel", UI.box(UI.CRIMSON, 0, UI.CLEAR, 0, 10))
	_banner.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_banner.add_child(UI.label(Loc.t("reconnecting"), 15, UI.ACCENT_SOFT, true))
	add_child(_banner)


func toast(text: String) -> void:
	_toast_id += 1
	var my_id := _toast_id
	_toast_label.text = text
	_toast_panel.visible = true
	await get_tree().create_timer(2.5).timeout
	if my_id == _toast_id:
		_toast_panel.visible = false
