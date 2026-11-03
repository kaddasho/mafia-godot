class_name GameScreen
extends Control
## In-game screen: phase + timer, your role, what happened, and the player list you tap to act or vote.
## The sky behind it cross-fades between night, day and vote; the role card flips in when roles are dealt.

const ROUND_PHASES: Array[String] = ["night", "day", "vote"]

var _room: Dictionary = {}
var _clock_offset: int = 0
var _sky: PhaseSky
var _phase_glyph: Glyph
var _phase_label: Label
var _round_label: Label
var _timer_label: Label
var _role_card: DecoFrame
var _role_glyph: Glyph
var _role_label: Label
var _role_hint: Label
var _revealed: bool = false
var _news: VBoxContainer
var _hint: Label
var _list: VBoxContainer
var _action_btn: Button
var _mic_btn: Button
var _avatars: Dictionary = {}  # player id -> avatar (its ring lights up while they talk)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_sky = PhaseSky.new(str(Net.room.get("phase", "")))
	add_child(_sky)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	margin.add_theme_constant_override("margin_top", 28)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)

	var head_frame := DecoFrame.new(12)
	head_frame.fill = Color(UI.CARD2, 0.85)
	col.add_child(head_frame)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head_frame.add_child(head)
	_phase_glyph = Glyph.new("", 34)
	head.add_child(_phase_glyph)
	var phase_col := VBoxContainer.new()
	phase_col.add_theme_constant_override("separation", 0)
	phase_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	phase_col.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_child(phase_col)
	_phase_label = UI.label("", 22, UI.ACCENT)
	phase_col.add_child(_phase_label)
	_round_label = UI.label("", 13, UI.MUTED)
	phase_col.add_child(_round_label)
	_timer_label = UI.label("", 24, UI.TEXT)
	_timer_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(_timer_label)

	_role_card = DecoFrame.new(14)
	_role_card.fill = Color(UI.CARD, 0.92)
	col.add_child(_role_card)
	var role_row := HBoxContainer.new()
	role_row.add_theme_constant_override("separation", 14)
	_role_card.add_child(role_row)
	_role_glyph = Glyph.new("", 44)
	role_row.add_child(_role_glyph)
	var role_col := VBoxContainer.new()
	role_col.add_theme_constant_override("separation", 2)
	role_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	role_row.add_child(role_col)
	_role_label = UI.label("", 20, UI.ACCENT_SOFT)
	role_col.add_child(_role_label)
	_role_hint = UI.label("", 14, UI.SILVER)
	role_col.add_child(_role_hint)

	_news = VBoxContainer.new()
	_news.add_theme_constant_override("separation", 6)
	col.add_child(_news)

	_hint = UI.label("", 15, UI.SILVER, true)
	col.add_child(_hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)

	_mic_btn = UI.button("", "ghost")
	_mic_btn.custom_minimum_size = Vector2(0, 44)
	_mic_btn.add_theme_font_size_override("font_size", 15)
	_mic_btn.pressed.connect(Voice.toggle_mute)
	col.add_child(_mic_btn)

	_action_btn = UI.button("")
	_action_btn.pressed.connect(_on_action)
	col.add_child(_action_btn)
	var leave := UI.button(Loc.t("leave"), "ghost")
	leave.pressed.connect(Net.leave_room)
	col.add_child(leave)

	update_room(Net.room)


func _process(_delta: float) -> void:
	_mic_btn.text = Voice.mic_text()
	for id: String in _avatars:
		UI.set_talking(_avatars[id], Voice.is_speaking(id))
	var deadline := int(_room.get("deadline", 0))
	if deadline <= 0:
		_timer_label.text = ""
		return
	var left := ceili(maxi(0, deadline - (_local_ms() + _clock_offset)) / 1000.0)
	_timer_label.text = "%d:%02d" % [left / 60, left % 60]
	_timer_label.add_theme_color_override("font_color", Color("#E0566B") if left <= 10 else UI.TEXT)


static func _local_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


func update_room(room: Dictionary) -> void:
	if room.is_empty():
		return
	_room = room
	_clock_offset = int(room.get("now", 0)) - _local_ms()
	var phase := str(room.get("phase", ""))
	var round_no := int(room.get("round", 0))
	var me: Dictionary = room.get("you", {})
	var my_role := Net.my_role
	var alive := bool(me.get("alive", true))

	_set_sky(phase)
	_phase_glyph.kind = Glyph.for_phase(phase)
	_phase_label.text = Loc.t("phase_" + phase)
	_round_label.text = Loc.t("round") % round_no if ROUND_PHASES.has(phase) and round_no > 0 else ""
	_round_label.visible = _round_label.text != ""

	_update_role_card(phase, my_role)
	_fill_news(room, phase, round_no, me)

	# What can I do right now? "act" / "vote" make player rows tappable.
	var mode := ""
	var hint := ""
	_action_btn.visible = false
	match phase:
		"roles":
			hint = Loc.t("roles_hint")
		"night":
			var night_hints := {"mafia": "do_kill", "doctor": "do_heal", "detective": "do_check"}
			if night_hints.has(my_role):
				mode = "act"
				hint = Loc.t(night_hints[my_role])
				if me.get("target") != null:
					hint += "\n" + Loc.t("acted")
			else:
				hint = Loc.t("night_sleep")
		"day":
			if bool(me.get("skipped", false)):
				hint = Loc.t("skipped_wait")
			else:
				hint = Loc.t("day_hint")
				_action_btn.text = Loc.t("end_discussion")
				_action_btn.visible = true
		"vote":
			mode = "vote"
			hint = Loc.t("vote_hint")
			if me.get("vote") == "":
				hint = Loc.t("voted_skip")
			else:
				_action_btn.text = Loc.t("skip_vote")
				_action_btn.visible = true
	if not alive and phase != "ended":
		mode = ""
		hint = Loc.t("dead_hint")
		_action_btn.visible = false
	_hint.text = hint

	var vote_counts := {}
	var votes: Dictionary = room.get("votes", {})
	for voter: String in votes:
		var target := str(votes[voter])
		if target != "":
			vote_counts[target] = int(vote_counts.get(target, 0)) + 1
	var team_targets: Array = (me.get("mafiaTargets", {}) as Dictionary).values()
	var skips: Array = room.get("skips", [])

	for child in _list.get_children():
		child.queue_free()
	_avatars.clear()
	for p: Dictionary in room.get("players", []):
		var id := str(p.get("id", ""))
		var extra := ""
		if not bool(p.get("alive", true)):
			extra = Loc.t("dead")
		elif not bool(p.get("connected", true)):
			extra = Loc.t("offline")
		elif phase == "vote" and vote_counts.has(id):
			extra = str(vote_counts[id])
		elif phase == "night" and team_targets.has(id):
			extra = Loc.t("team_target")
		elif phase == "day" and skips.has(id):
			extra = Loc.t("ready")
		var selected: bool = me.get("target") == id or me.get("vote") == id
		_list.add_child(_player_row(p, extra, selected, _can_pick(mode, p, my_role)))


## New sky fades in over the old one when the phase changes.
func _set_sky(phase: String) -> void:
	if _sky.phase == phase:
		return
	var old := _sky
	_sky = PhaseSky.new(phase)
	_sky.modulate.a = 0.0
	add_child(_sky)
	move_child(_sky, old.get_index() + 1)
	var tw := create_tween()
	tw.tween_property(_sky, "modulate:a", 1.0, 0.9)
	tw.tween_callback(old.queue_free)


## Big card while roles are dealt (flips in once), compact card for the rest of the game.
func _update_role_card(phase: String, my_role: String) -> void:
	_role_card.visible = my_role != ""
	if my_role == "":
		return
	var big := phase == "roles"
	_role_glyph.kind = Glyph.for_role(my_role)
	_role_glyph.custom_minimum_size = Vector2(76, 76) if big else Vector2(44, 44)
	_role_glyph.color = Color("#D8475E") if my_role == "mafia" else UI.ACCENT
	_role_label.text = Loc.t("your_role") + ": " + Loc.t("role_" + my_role)
	_role_label.add_theme_font_size_override("font_size", 26 if big else 20)
	_role_hint.text = Loc.t("role_hint_" + my_role)
	if not _revealed:
		_revealed = true
		await get_tree().process_frame
		_role_card.pivot_offset = _role_card.size / 2
		_role_card.scale = Vector2(0, 1)
		var tw := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(_role_card, "scale", Vector2.ONE, 0.6)


func _fill_news(room: Dictionary, phase: String, round_no: int, me: Dictionary) -> void:
	for child in _news.get_children():
		child.queue_free()
	if phase == "ended":
		var winner := str(room.get("winner", ""))
		_news.add_child(UI.ornament_title(Loc.t("win_" + winner), 24, Color("#E0566B") if winner == "mafia" else UI.ACCENT))
		_add_news(Loc.t("back_soon"), 14, UI.MUTED)

	var night: Dictionary = room.get("lastNight", {})
	if not night.is_empty() and int(night.get("round", 0)) == round_no and phase != "night":
		var killed := str(night.get("killed", ""))
		if killed != "":
			_add_news(Loc.t("night_killed") % _name_of(killed))
		elif bool(night.get("saved", false)):
			_add_news(Loc.t("night_saved"))
		else:
			_add_news(Loc.t("night_quiet"))

	var vote: Dictionary = room.get("lastVote", {})
	var vote_round := int(vote.get("round", -1))
	if not vote.is_empty() and ((phase == "night" and vote_round == round_no - 1) or (phase == "ended" and vote_round == round_no)):
		var out := str(vote.get("out", ""))
		if out != "":
			_add_news(Loc.t("vote_out") % _name_of(out) + " (" + Loc.t("role_" + _role_of(out)) + ")")
		else:
			_add_news(Loc.t("vote_none"))

	for check: Dictionary in me.get("checks", []):
		var key := "check_mafia" if bool(check.get("mafia", false)) else "check_clean"
		_add_news(Loc.t(key) % _name_of(str(check.get("target", ""))), 14, UI.SILVER)


func _add_news(text: String, size: int = 16, color: Color = UI.TEXT) -> void:
	_news.add_child(UI.label(text, size, color, true))


func _name_of(id: String) -> String:
	for p: Dictionary in _room.get("players", []):
		if str(p.get("id", "")) == id:
			return str(p.get("name", ""))
	return "?"


func _role_of(id: String) -> String:
	for p: Dictionary in _room.get("players", []):
		if str(p.get("id", "")) == id and p.get("role") != null:
			return str(p.get("role"))
	return ""


func _can_pick(mode: String, p: Dictionary, my_role: String) -> bool:
	if mode == "" or not bool(p.get("alive", true)):
		return false
	var is_me := str(p.get("id", "")) == Net.my_id
	if mode == "vote":
		return not is_me
	if my_role == "mafia":
		return p.get("role") != "mafia"
	if my_role == "detective":
		return not is_me
	return true


func _player_row(p: Dictionary, extra: String, selected: bool, pickable: bool) -> Control:
	var panel := DecoFrame.new(10, 1.0 if selected else 0.3)
	panel.cut = 8
	panel.fill = Color(UI.ACCENT, 0.22) if selected else Color(UI.CARD, 0.72)
	var alive := bool(p.get("alive", true))
	if not alive:
		panel.modulate = Color(1, 1, 1, 0.55)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(row)

	var player_name := str(p.get("name", ""))
	var avatar := UI.avatar(player_name, not alive)
	_avatars[str(p.get("id", ""))] = avatar
	row.add_child(avatar)

	var is_me := str(p.get("id", "")) == Net.my_id
	var shown := player_name + ("  (" + Loc.t("you") + ")" if is_me else "")
	var name_label := UI.label(shown, 16, UI.TEXT if bool(p.get("connected", true)) else UI.MUTED)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)

	var role: Variant = p.get("role")
	if role != null and not is_me:
		row.add_child(Glyph.new(Glyph.for_role(str(role)), 22))
		row.add_child(UI.chip(Loc.t("role_" + str(role)), UI.CRIMSON if role == "mafia" else UI.AVATAR))

	if extra != "":
		var extra_label := UI.label(extra, 15, UI.ACCENT if extra.is_valid_int() else UI.SILVER)
		extra_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		extra_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(extra_label)

	for child in row.get_children():
		(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	if pickable:
		panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var id := str(p.get("id", ""))
		panel.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
				_pick(id))
	return panel


func _pick(id: String) -> void:
	var t := "vote" if str(_room.get("phase", "")) == "vote" else "act"
	Net.send({"t": t, "target": id})


func _on_action() -> void:
	match str(_room.get("phase", "")):
		"day":
			Net.send({"t": "skip"})
		"vote":
			Net.send({"t": "vote", "target": null})
