class_name LobbyScreen
extends Control
## Waiting room: room code, player list, ready / start / leave.

var _code_label: Label
var _name_label: Label
var _count_label: Label
var _list: VBoxContainer
var _status: Label
var _ready_btn: Button
var _start_btn: Button
var _is_ready: bool = false
var _pace_row: HBoxContainer
var _mic_btn: Button
var _rows: Dictionary = {}  # player id -> avatar (its ring lights up while they talk)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(PhaseSky.new())

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	margin.add_theme_constant_override("margin_top", 28)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	margin.add_child(col)

	var head_frame := DecoFrame.new(16)
	col.add_child(head_frame)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	head_frame.add_child(head)
	var head_text := VBoxContainer.new()
	head_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(head_text)
	head_text.add_child(UI.label(Loc.t("room_code"), 13, UI.MUTED))
	_code_label = UI.label("----", 40, UI.ACCENT)
	head_text.add_child(_code_label)
	var copy := UI.button(Loc.t("copy_code"), "ghost")
	copy.custom_minimum_size = Vector2(120, 44)
	copy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	copy.add_theme_font_size_override("font_size", 15)
	copy.pressed.connect(_on_copy)
	head.add_child(copy)

	_name_label = UI.label("", 15, UI.SILVER)
	col.add_child(_name_label)

	col.add_child(UI.label(Loc.t("round_length"), 14, UI.MUTED))
	_pace_row = HBoxContainer.new()
	_pace_row.add_theme_constant_override("separation", 8)
	col.add_child(_pace_row)

	_mic_btn = UI.button("", "ghost")
	_mic_btn.custom_minimum_size = Vector2(0, 44)
	_mic_btn.add_theme_font_size_override("font_size", 15)
	_mic_btn.pressed.connect(Voice.toggle_mute)
	col.add_child(_mic_btn)

	var title_row := HBoxContainer.new()
	col.add_child(title_row)
	var players_title := UI.label(Loc.t("players"), 18, UI.ACCENT)
	players_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(players_title)
	_count_label = UI.label("", 14, UI.MUTED)
	_count_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	title_row.add_child(_count_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)

	_status = UI.label("", 15, UI.SILVER, true)
	col.add_child(_status)

	_ready_btn = UI.button(Loc.t("ready"))
	_ready_btn.pressed.connect(_on_ready)
	col.add_child(_ready_btn)
	_start_btn = UI.button(Loc.t("start"))
	_start_btn.pressed.connect(func() -> void: Net.send({"t": "start"}))
	col.add_child(_start_btn)
	var leave := UI.button(Loc.t("leave"), "ghost")
	leave.pressed.connect(Net.leave_room)
	col.add_child(leave)

	update_room(Net.room)


func _process(_delta: float) -> void:
	_mic_btn.text = Voice.mic_text()
	for id: String in _rows:
		UI.set_talking(_rows[id], Voice.is_speaking(id))


func update_room(room: Dictionary) -> void:
	if room.is_empty():
		return
	_code_label.text = str(room.get("code", ""))
	_name_label.text = str(room.get("name", ""))
	var players: Array = room.get("players", [])
	_count_label.text = "%d / %d" % [players.size(), int(room.get("max", 0))]

	for child in _list.get_children():
		child.queue_free()
	_rows.clear()
	var am_host := false
	for p: Dictionary in players:
		var row := _player_row(p)
		_rows[str(p.get("id", ""))] = row.get_meta("avatar")
		_list.add_child(row)
		if str(p.get("id", "")) == Net.my_id:
			_is_ready = bool(p.get("ready", false))
			am_host = bool(p.get("host", false))

	for child in _pace_row.get_children():
		child.queue_free()
	var pace := str(room.get("pace", "medium"))
	for option in ["short", "medium", "long"]:
		var b := UI.button(Loc.t("pace_" + option), "primary" if option == pace else "ghost")
		b.custom_minimum_size = Vector2(0, 44)
		b.add_theme_font_size_override("font_size", 15)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = not am_host and option != pace
		if am_host:
			b.pressed.connect(func() -> void: Net.send({"t": "settings", "pace": option}))
		_pace_row.add_child(b)

	var phase := str(room.get("phase", "lobby"))
	var in_lobby := phase == "lobby"
	_ready_btn.visible = in_lobby and not am_host
	_start_btn.visible = in_lobby and am_host
	_ready_btn.text = Loc.t("cancel_ready" if _is_ready else "ready")

	if in_lobby:
		var auto_at: float = float(room.get("autoStartAt", 0))
		if auto_at > 0.0:
			_status.text = Loc.t("auto_start")
		elif am_host:
			_status.text = Loc.t("waiting_ready")
		else:
			_status.text = ""
	else:
		var text := Loc.t("phase_" + phase)
		if Net.my_role != "":
			text += "\n" + Loc.t("your_role") + ": " + Loc.t("role_" + Net.my_role)
		_status.text = text


func _player_row(p: Dictionary) -> Control:
	var panel := DecoFrame.new(10, 0.3)
	panel.cut = 8
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var player_name := str(p.get("name", ""))
	var avatar := UI.avatar(player_name)
	panel.set_meta("avatar", avatar)
	row.add_child(avatar)

	var is_me := str(p.get("id", "")) == Net.my_id
	var shown := player_name + ("  (" + Loc.t("you") + ")" if is_me else "")
	var name_label := UI.label(shown, 16, UI.TEXT if bool(p.get("connected", true)) else UI.MUTED)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)

	if bool(p.get("host", false)):
		row.add_child(UI.chip(Loc.t("host"), UI.CRIMSON))
	elif bool(p.get("ready", false)):
		row.add_child(UI.chip(Loc.t("ready"), Color(UI.ACCENT, 0.18)))
	return panel


func _on_ready() -> void:
	_is_ready = not _is_ready
	Net.send({"t": "ready", "value": _is_ready})


func _on_copy() -> void:
	DisplayServer.clipboard_set(_code_label.text)
	var main := get_parent()
	if main != null and main.has_method("toast"):
		main.call("toast", Loc.t("copied"))
