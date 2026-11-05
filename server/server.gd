extends Node
## Headless Mafia server: accepts WebSocket clients, routes their messages to rooms, ticks room clocks.
## Run:  Godot_v4.7.2-stable_win64_console.exe --headless --path server   (optional: -- --port=8080)
## Online it runs from the Dockerfile in this folder; the host's PORT variable picks the port.

const Room := preload("res://room.gd")
const Store := preload("res://store.gd")
const Social := preload("res://social.gd")
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ"
const MAX_VOICE_BYTES := 4096
const DEFAULT_NAMES := {"ar": "لاعب", "ru": "Игрок", "en": "Player", "tr": "Oyuncu", "de": "Spieler"}


class Client:
	var id: String
	var token: String
	var ws: WebSocketPeer
	var room_code: String = ""
	var welcomed: bool = false
	var account: String = ""  # permanent account id once signed in ("auth")
	var photo: String = ""  # version of the account's profile photo ("" = none)
	var show_online: bool = true  # privacy: friends see this player as online (false = appear offline)
	var allow_join: bool = true  # privacy: friends may join this player's room without asking
	var profile: Dictionary = {}  # name / gender / country / avatar from the last sign-in


var _tcp := TCPServer.new()
var _social: Social
var _crypto := Crypto.new()
var _clients: Dictionary = {}  # id -> Client
var _rooms: Dictionary = {}  # code -> Room
var _parked: Dictionary = {}  # token -> Client whose socket closed while in a room


func _ready() -> void:
	var port := 8080
	if OS.has_environment("PORT"):  # set by hosts such as Render
		port = int(OS.get_environment("PORT"))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			port = int(arg.get_slice("=", 1))
		elif arg.begins_with("--grace="):
			Room.grace_ms = int(arg.get_slice("=", 1))
	var store := Store.new()
	add_child(store)
	_social = Social.new()
	_social.store = store
	_social.server = self
	add_child(_social)
	if _tcp.listen(port) != OK:
		push_error("Can't listen on port %d" % port)
		get_tree().quit(1)
		return
	print("Mafia server listening on port %d" % port)


func _process(_delta: float) -> void:
	while _tcp.is_connection_available():
		var c := Client.new()
		c.id = _crypto.generate_random_bytes(4).hex_encode()
		c.token = _crypto.generate_random_bytes(16).hex_encode()
		c.ws = WebSocketPeer.new()
		# room for chat images and profile photos (sent as base64 text)
		c.ws.inbound_buffer_size = 1 << 20
		c.ws.outbound_buffer_size = 1 << 21
		c.ws.accept_stream(_tcp.take_connection())
		_clients[c.id] = c

	for c: Client in _clients.values():
		c.ws.poll()
		match c.ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				if not c.welcomed:
					c.welcomed = true
					_send(c.id, {"t": "welcome", "id": c.id, "token": c.token})
				while c.ws.get_available_packet_count() > 0:
					var pkt := c.ws.get_packet()
					if c.ws.was_string_packet():
						_handle(c, pkt.get_string_from_utf8())
					else:
						_relay_voice(c, pkt)
			WebSocketPeer.STATE_CLOSED:
				_clients.erase(c.id)
				_social.signed_out(c)
				var room: Room = _rooms.get(c.room_code)
				if room != null:
					room.disconnect_player(c.id)
					_parked[c.token] = c

	var now := Room.now_ms()
	for room: Room in _rooms.values():
		room.tick(now)
		if room.is_empty():
			_rooms.erase(room.code)

	# Forget parked sessions whose seat is gone (grace ran out, room closed).
	for token: String in _parked.keys():
		var c: Client = _parked[token]
		var room: Room = _rooms.get(c.room_code)
		if room == null or room.find(c.id).is_empty() or room.find(c.id).gone:
			_parked.erase(token)


func _send(id: String, data: Dictionary) -> void:
	var c: Client = _clients.get(id)
	if c != null and c.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		c.ws.send_text(JSON.stringify(data))


func _handle(c: Client, text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var m: Dictionary = parsed
	if _social.handles(str(m.get("t", ""))):
		_social.handle(c, m)
		return
	var room: Room = _rooms.get(c.room_code)
	var err := ""
	match str(m.get("t", "")):
		"create":
			_leave(c, false)
			var max_count := clampi(int(m.get("maxPlayers", Room.MAX_PLAYERS)), Room.MIN_PLAYERS, Room.MAX_PLAYERS)
			var player_name := _clean_name(m)
			var created := _new_room(player_name, bool(m.get("isPublic", false)), max_count)
			created.lang = str(m.get("lang", ""))
			created.pace = str(m.get("pace", "medium")) if Room.PACES.has(str(m.get("pace", ""))) else "medium"
			created.open_talk = bool(m.get("openTalk", false))
			err = _enter_room(c, created, player_name, m)
		"join":
			_leave(c, false)
			var target: Room = _rooms.get(str(m.get("code", "")).strip_edges().to_upper())
			err = "room_not_found" if target == null else _enter_room(c, target, _clean_name(m), m)
		"quick":
			_leave(c, false)
			var player_name := _clean_name(m)
			var target: Room = null
			for r: Room in _rooms.values():
				if r.is_public and r.is_open():
					target = r
					break
			if target == null:
				target = _new_room(player_name, true, Room.MAX_PLAYERS)
				target.lang = str(m.get("lang", ""))
				target.auto_start = true  # quick-play rooms start themselves; hosted rooms wait for the host
			err = _enter_room(c, target, player_name, m)
		"list":
			var listed := []
			for r: Room in _rooms.values():
				if r.is_public and r.is_open():
					listed.append(r.summary())
			_send(c.id, {"t": "rooms", "rooms": listed})
		"resume":
			_resume(c, str(m.get("token", "")))
		"leave":
			_leave(c, true)
		"ready":
			if room != null:
				room.set_ready(c.id, bool(m.get("value", true)))
		"start":
			err = "not_in_room" if room == null else room.start(c.id)
		"settings":
			if room == null:
				err = "not_in_room"
			elif m.has("pace"):
				err = room.set_pace(c.id, str(m.pace))
			elif m.has("mafia"):
				err = room.set_mafia(c.id, int(m.mafia))
			elif m.has("openTalk"):
				err = room.set_open_talk(c.id, bool(m.openTalk))
			elif m.has("maxPlayers"):
				err = room.set_max_players(c.id, int(m.maxPlayers))
		"turn":
			err = "not_in_room" if room == null else room.turn(c.id, str(m.get("action", "")), str(m.get("target", "")))
		"react":
			err = "not_in_room" if room == null else room.react(c.id, int(m.get("e", -1)))
		"chat":
			err = "not_in_room" if room == null else room.chat(c.id, str(m.get("text", "")))
		"mute":
			if room != null:
				room.set_muted(c.id, bool(m.get("on", false)))
		"act":
			err = "not_in_room" if room == null else room.act(c.id, str(m.get("target", "")))
		"skip":
			err = "not_in_room" if room == null else room.skip(c.id)
		"vote":
			var target_id: Variant = m.get("target")
			err = "not_in_room" if room == null else room.vote(c.id, "" if target_id == null else str(target_id))
		"ping":
			_send(c.id, {"t": "pong"})
	if err != "":
		_send(c.id, {"t": "error", "code": err})


## Binary packets are voice: forwarded as [8-byte speaker id][audio] to whoever may hear the speaker.
func _relay_voice(c: Client, audio: PackedByteArray) -> void:
	var room: Room = _rooms.get(c.room_code)
	if room == null or audio.is_empty() or audio.size() > MAX_VOICE_BYTES:
		return
	var out := c.id.to_ascii_buffer() + audio
	for id in room.voice_targets(c.id):
		var listener: Client = _clients.get(id)
		if listener != null and listener.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			listener.ws.send(out, WebSocketPeer.WRITE_MODE_BINARY)


## A new connection takes over an earlier session (same token): it gets back that player id and seat.
func _resume(c: Client, token: String) -> void:
	var old: Client = _parked.get(token)
	if old == null:
		# The old socket may not have noticed it is dead yet.
		for other: Client in _clients.values():
			if other != c and other.token == token and token != "":
				old = other
				_clients.erase(other.id)
				other.ws.close()
				break
	var room: Room = null if old == null else _rooms.get(old.room_code)
	if room == null or room.find(old.id).is_empty() or room.find(old.id).gone:
		_send(c.id, {"t": "resume_failed"})
		return
	_parked.erase(token)
	_leave(c, false)
	_clients.erase(c.id)
	c.id = old.id
	c.token = old.token
	c.room_code = old.room_code
	if c.account == "" and old.account != "":
		c.account = old.account
		c.photo = old.photo
		c.profile = old.profile
		c.show_online = old.show_online
		c.allow_join = old.allow_join
		_social.online[old.account] = c
	_clients[c.id] = c
	_send(c.id, {"t": "welcome", "id": c.id, "token": c.token, "resumed": true})
	room.reconnect_player(c.id)


func _new_room(room_name: String, public: bool, max_count: int) -> Room:
	var code := ""
	while code == "" or _rooms.has(code):
		code = ""
		for i in 4:
			code += CODE_CHARS[randi() % CODE_CHARS.length()]
	var room := Room.new(code, room_name, public, max_count, _send)
	_rooms[code] = room
	return room


## Joins `room` with the profile sent in the message: gender "m"/"f", country as a 2-letter code.
## Called by Social when a player changes their profile photo while in a room.
func photo_changed(c: Client) -> void:
	var room: Room = _rooms.get(c.room_code)
	if room != null:
		room.set_photo(c.account, c.photo)


func _enter_room(c: Client, room: Room, player_name: String, m: Dictionary) -> String:
	var gender := str(m.get("gender", ""))
	if gender not in ["m", "f"]:
		gender = ""
	var country := str(m.get("country", "")).strip_edges().to_lower()
	if country.length() != 2 or not country.is_valid_identifier():
		country = ""
	var avatar := clampi(int(m.get("avatar", 0)), 0, 15)
	var err := room.add_player(c.id, player_name, gender, country, c.account, avatar, c.photo)
	if err == "":
		c.room_code = room.code
		_social.room_changed(c)
		_social.block_alert(c, room)
	elif room.is_empty():
		_rooms.erase(room.code)
	return err


## Social puts a player into a room (join a friend, after any approvals); same checks as "join".
func join_room(c: Client, room: Room) -> void:
	if c.room_code == room.code:
		return
	_leave(c, false)
	var err := _enter_room(c, room, _clean_name(c.profile), c.profile)
	if err != "":
		_send(c.id, {"t": "error", "code": err})


func room_of(c: Client) -> Room:
	return _rooms.get(c.room_code)


func client(id: String) -> Client:
	return _clients.get(id)


func _leave(c: Client, notify: bool) -> void:
	if c.room_code == "":
		return
	var room: Room = _rooms.get(c.room_code)
	c.room_code = ""
	_social.room_changed(c)
	if room != null:
		room.remove_player(c.id)
		if room.is_empty():
			_rooms.erase(room.code)
	if notify:
		_send(c.id, {"t": "left"})


func _clean_name(m: Dictionary) -> String:
	var n := str(m.get("name", "")).strip_edges().left(20)
	if n == "":
		n = "%s %d" % [DEFAULT_NAMES.get(str(m.get("lang", "en")), "Player"), randi_range(10, 99)]
	return n
