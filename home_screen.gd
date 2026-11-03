class_name HomeScreen
extends Control
## Start screen: quick play, public rooms (coming), private room (create / join by code).

var _name_edit: LineEdit
var _code_edit: LineEdit
var _url_edit: LineEdit
var _status: Label
var _private_panel: PanelContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var back := Backdrop.new()
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(back)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)

	var top := Control.new()
	top.custom_minimum_size = Vector2(0, 300)
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(top)

	col.add_child(UI.ornament_title(Loc.t("title"), 58))
	col.add_child(UI.label(Loc.t("tagline"), 17, UI.SILVER, true))

	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)

	_name_edit = UI.field(Loc.t("name_hint"), Net.player_name)
	_name_edit.max_length = 20
	col.add_child(_name_edit)

	var quick := UI.button(Loc.t("quick"))
	quick.pressed.connect(_on_quick)
	col.add_child(quick)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)
	var pub := UI.button(Loc.t("public_rooms"), "ghost")
	pub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pub.pressed.connect(func() -> void: _status.text = Loc.t("coming_soon"))
	row.add_child(pub)
	var priv := UI.button(Loc.t("private_room"), "ghost")
	priv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	priv.pressed.connect(func() -> void: _private_panel.visible = not _private_panel.visible)
	row.add_child(priv)

	_private_panel = DecoFrame.new(16)
	_private_panel.visible = false
	col.add_child(_private_panel)
	var pcol := VBoxContainer.new()
	pcol.add_theme_constant_override("separation", 10)
	_private_panel.add_child(pcol)
	_code_edit = UI.field(Loc.t("room_code"))
	_code_edit.max_length = 4
	pcol.add_child(_code_edit)
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 10)
	pcol.add_child(prow)
	var join := UI.button(Loc.t("join"))
	join.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join.pressed.connect(_on_join)
	prow.add_child(join)
	var create := UI.button(Loc.t("create_room"), "ghost")
	create.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create.pressed.connect(_on_create)
	prow.add_child(create)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	col.add_child(bottom)
	var lang_btn := UI.button(Loc.t("language"), "ghost")
	lang_btn.custom_minimum_size = Vector2(130, 44)
	lang_btn.add_theme_font_size_override("font_size", 15)
	lang_btn.pressed.connect(func() -> void: Loc.set_lang(Loc.next_lang()))
	bottom.add_child(lang_btn)
	_status = UI.label("", 14, UI.SILVER, true)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bottom.add_child(_status)

	_url_edit = UI.field(Loc.t("server_hint"), Net.url)
	_url_edit.custom_minimum_size = Vector2(0, 40)
	_url_edit.add_theme_font_size_override("font_size", 14)
	_url_edit.add_theme_color_override("font_color", UI.MUTED)
	_url_edit.text_submitted.connect(_on_url_submitted)
	_url_edit.focus_exited.connect(func() -> void: _apply_url())
	col.add_child(_url_edit)

	Net.connection_changed.connect(_on_connection)
	_status.text = "" if Net.connected else Loc.t("connecting")


func _remember_name() -> void:
	Net.player_name = _name_edit.text.strip_edges()
	Net.save_settings()


func _run(action: Callable) -> void:
	_remember_name()
	_apply_url()
	_status.text = Loc.t("connecting")
	Net.when_connected(func() -> void:
		_status.text = ""
		action.call())


func _on_quick() -> void:
	_run(func() -> void:
		Net.send({"t": "quick", "name": Net.player_name, "lang": Loc.lang}))


func _on_create() -> void:
	_run(func() -> void:
		Net.send({"t": "create", "name": Net.player_name, "lang": Loc.lang, "isPublic": false, "maxPlayers": 8}))


func _on_join() -> void:
	var code := _code_edit.text.strip_edges().to_upper()
	if code.length() != 4:
		return
	_run(func() -> void:
		Net.send({"t": "join", "name": Net.player_name, "code": code, "lang": Loc.lang}))


func _on_url_submitted(_text: String) -> void:
	_url_edit.release_focus()
	_apply_url()


## Takes the typed server address even without Enter (phone keyboards often don't send it).
func _apply_url() -> void:
	var typed := _url_edit.text.strip_edges()
	if typed == "" or typed == Net.url:
		return
	if not typed.contains("://"):
		typed = "ws://" + typed
	if typed.begins_with("ws://") and typed.count(":") < 2:
		typed += ":8080"  # our home server's port; wss:// hosts use the default port
	_url_edit.text = typed
	Net.url = typed
	Net.save_settings()
	_status.text = Loc.t("connecting")
	Net.connect_to_server()


func _on_connection(ok: bool) -> void:
	_status.text = "" if ok else Loc.t("connect_failed")
