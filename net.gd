extends Node
## Autoload "Net": WebSocket connection to the Mafia server.
## Everything the server sends arrives through the `message` signal as a Dictionary.
## If the connection drops while in a room, it reconnects on its own and resumes the same seat;
## the session token is also saved so a restarted app can return to its room.

signal message(msg: Dictionary)
signal connection_changed(ok: bool)
signal voice(speaker_id: String, audio: PackedByteArray)

const SETTINGS_PATH := "user://settings.cfg"
const RETRY_EVERY := 2.0
const RETRY_FOR := 55.0  # a bit less than the server keeps the seat
const PING_EVERY := 20.0  # keeps hosting proxies from closing a quiet connection

var url: String = "ws://127.0.0.1:8080"
var player_name: String = ""
var saved_lang: String = "ar"

var connected: bool = false
var reconnecting: bool = false
var my_id: String = ""
var token: String = ""
var my_role: String = ""
var room: Dictionary = {}

var _ws := WebSocketPeer.new()
var _active: bool = false
var _pending: Callable = Callable()
var _resume_token: String = ""
var _saved_session: String = ""
var _retry_at: float = 0.0
var _retry_until: float = 0.0
var _ping_at: float = 0.0


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	url = str(cfg.get_value("net", "url", url))
	player_name = str(cfg.get_value("player", "name", ""))
	saved_lang = str(cfg.get_value("player", "lang", "ar"))
	_saved_session = str(cfg.get_value("net", "session", ""))
	_resume_token = _saved_session


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "url", url)
	cfg.set_value("net", "session", _saved_session)
	cfg.set_value("player", "name", player_name)
	cfg.set_value("player", "lang", Loc.lang)
	cfg.save(SETTINGS_PATH)


func connect_to_server() -> void:
	if _active:
		_ws.close()
	_ws = WebSocketPeer.new()
	connected = false
	var err := _ws.connect_to_url(url)
	if err != OK:
		_active = false
		connection_changed.emit(false)
		return
	_active = true


## Runs `cb` as soon as the connection is open (immediately if it already is).
func when_connected(cb: Callable) -> void:
	if connected:
		cb.call()
	else:
		_pending = cb
		connect_to_server()


func send(data: Dictionary) -> void:
	if connected and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(data))


## Voice audio goes as binary packets; the server forwards them as [8-byte speaker id][audio].
func send_voice(audio: PackedByteArray) -> void:
	if connected and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send(audio, WebSocketPeer.WRITE_MODE_BINARY)


## Leave the room; works offline too (stops reconnecting and drops the seat locally).
func leave_room() -> void:
	if connected:
		send({"t": "leave"})
	else:
		_give_up()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	if not _active:
		if reconnecting:
			if _now() >= _retry_until:
				_give_up()
			elif _now() >= _retry_at:
				_retry_at = _now() + RETRY_EVERY
				connect_to_server()
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not connected:
				connected = true
				_ping_at = _now() + PING_EVERY
				connection_changed.emit(true)
				if _pending.is_valid():
					var cb: Callable = _pending
					_pending = Callable()
					cb.call()
			while _ws.get_available_packet_count() > 0:
				var pkt := _ws.get_packet()
				if _ws.was_string_packet():
					_handle(pkt.get_string_from_utf8())
				elif pkt.size() > 8:
					voice.emit(pkt.slice(0, 8).get_string_from_ascii(), pkt.slice(8))
			if _now() >= _ping_at:
				_ping_at = _now() + PING_EVERY
				send({"t": "ping"})
		WebSocketPeer.STATE_CLOSED:
			connected = false
			_active = false
			_pending = Callable()
			if not room.is_empty() and not reconnecting:
				# Keep the room on screen and try to get the seat back.
				reconnecting = true
				_resume_token = token
				_retry_at = _now() + 1.0
				_retry_until = _now() + RETRY_FOR
			elif not reconnecting:
				room = {}
				my_role = ""
			connection_changed.emit(false)


func _give_up() -> void:
	reconnecting = false
	_resume_token = ""
	_forget_session()
	room = {}
	my_role = ""
	message.emit({"t": "left", "lost": true})


func _forget_session() -> void:
	if _saved_session != "":
		_saved_session = ""
		save_settings()


func _handle(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var d: Dictionary = parsed
	match str(d.get("t", "")):
		"welcome":
			my_id = str(d.get("id", ""))
			token = str(d.get("token", ""))
			if bool(d.get("resumed", false)):
				reconnecting = false
				_resume_token = ""
			elif _resume_token != "":
				send({"t": "resume", "token": _resume_token})
		"resume_failed":
			_resume_token = ""
			_forget_session()
			if reconnecting or not room.is_empty():
				reconnecting = false
				room = {}
				my_role = ""
				d = {"t": "left", "lost": true}
		"room":
			room = d
			var you: Dictionary = d.get("you", {})
			var r: Variant = you.get("role")
			my_role = "" if r == null else str(r)
			if _saved_session != token:
				_saved_session = token
				save_settings()
		"left":
			room = {}
			my_role = ""
			_forget_session()
	message.emit(d)
