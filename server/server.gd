extends Node
## Headless Mafia server: accepts WebSocket clients, routes their messages to rooms, ticks room clocks.
## Run:  Godot_v4.7.2-stable_win64_console.exe --headless --path server   (optional: -- --port=8080)
## Online it runs from the Dockerfile in this folder; the host's PORT variable picks the port.

const Room := preload("res://room.gd")
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ"
const MAX_VOICE_BYTES := 4096
const DEFAULT_NAMES := {"ar": "لاعب", "ru": "Игрок", "en": "Player"}


class Client:
	var id: String
	var token: String
	var ws: WebSocketPeer
	var room_code: String = ""
	var welcomed: bool = false


var _tcp := TCPServer.new()
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
	var room: Room = _rooms.get(c.room_code)
	var err := ""
	match str(m.get("t", "")):
		"create":
			_leave(c, false)
			var max_count := clampi(int(m.get("maxPlayers", 8)), Room.MIN_PLAYERS, 12)
			var player_name := _clean_name(m)
			err = _enter_room(c, _new_room(player_name, bool(m.get("isPublic", false)), max_count), player_name)
		"join":
			_leave(c, false)
			var target: Room = _rooms.get(str(m.get("code", "")).strip_edges().to_upper())
			err = "room_not_found" if target == null else _enter_room(c, target, _clean_name(m))
		"quick":
			_leave(c, false)
			var player_name := _clean_name(m)
			var target: Room = null
			for r: Room in _rooms.values():
				if r.is_public and r.is_open():
					target = r
					break
			if target == null:
				target = _new_room(player_name, true, 8)
			err = _enter_room(c, target, player_name)
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
			err = "not_in_room" if room == null else room.set_pace(c.id, str(m.get("pace", "")))
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


func _enter_room(c: Client, room: Room, player_name: String) -> String:
	var err := room.add_player(c.id, player_name)
	if err == "":
		c.room_code = room.code
	elif room.is_empty():
		_rooms.erase(room.code)
	return err


func _leave(c: Client, notify: bool) -> void:
	if c.room_code == "":
		return
	var room: Room = _rooms.get(c.room_code)
	c.room_code = ""
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
