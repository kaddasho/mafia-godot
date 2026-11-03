extends SceneTree
## End-to-end check against a running server started with a short reconnect window:
##   Godot_v4.7.2-stable_win64_console.exe --headless --path server -- --grace=3000
##   Godot_v4.7.2-stable_win64_console.exe --headless --path server --script res://tests/test_game.gd   (optional: -- --port=8080)
## Five bots create/join a room, get ready, start and play; the town votes out the mafia and must win.
## On the first night bot 1 drops and resumes its seat, bot 2 drops for good and must die after the grace time.
## Voice: lobby audio reaches everyone, a non-mafia speaking at night reaches nobody, day audio reaches all.


class Bot:
	var ws := WebSocketPeer.new()
	var id := ""
	var token := ""
	var resumed := false
	var room := {}
	var errors: Array = []
	var done := {}
	var heard: Array = []  # [speaker id, first audio byte]

	func send(d: Dictionary) -> void:
		ws.send_text(JSON.stringify(d))

	func say(tag: int) -> void:
		ws.send(PackedByteArray([tag, tag, tag]), WebSocketPeer.WRITE_MODE_BINARY)

	func heard_from(speaker: String, tag: int) -> bool:
		return heard.has([speaker, tag])

	func poll() -> void:
		ws.poll()
		if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
			return
		while ws.get_available_packet_count() > 0:
			var pkt := ws.get_packet()
			if not ws.was_string_packet():
				heard.append([pkt.slice(0, 8).get_string_from_ascii(), pkt[8]])
				continue
			var m: Dictionary = JSON.parse_string(pkt.get_string_from_utf8())
			match str(m.t):
				"welcome":
					id = m.id
					token = m.token
					resumed = bool(m.get("resumed", false))
				"room":
					room = m
				"error":
					errors.append(m.code)

	func role() -> String:
		var r: Variant = room.get("you", {}).get("role")
		return "" if r == null else r


var url := "ws://127.0.0.1:8080"
var bots: Array[Bot] = []
var step := 0
var elapsed := 0.0
var roles := {}  # bot id -> role
var drop_step := 0
var old_id := ""
var old_token := ""
var saw_offline_seat := false
var night_speaker: Bot
var day_speaker: Bot


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			url = "ws://127.0.0.1:%s" % arg.get_slice("=", 1)
	for i in 5:
		var b := Bot.new()
		b.ws.connect_to_url(url)
		bots.append(b)


func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > 60.0:
		return _fail("timeout at step %d" % step)
	for b in bots:
		b.poll()
	var host := bots[0]
	match step:
		0:
			if bots.all(func(b: Bot) -> bool: return b.id != ""):
				host.send({"t": "join", "code": "ZZZZ", "name": "Host"})
				host.send({"t": "create", "name": "Host", "maxPlayers": 8})
				step = 1
		1:
			if host.room.has("code"):
				_expect(host.errors.has("room_not_found"), "joining a missing room is refused")
				for i in range(1, 5):
					bots[i].send({"t": "join", "code": host.room.code, "name": "Bot %d" % i})
				step = 2
		2:
			if bots.all(func(b: Bot) -> bool: return b.room.get("players", []).size() == 5):
				host.say(1)
				bots[1].send({"t": "settings", "pace": "short"})
				host.send({"t": "settings", "pace": "long"})
				host.send({"t": "start"})
				step = 3
		3:
			if host.errors.has("not_everyone_ready"):
				print("ok: start refused until everyone is ready")
				for i in range(1, 5):
					bots[i].send({"t": "ready", "value": true})
				step = 4
		4:
			var others: Array = host.room.players.filter(func(p: Dictionary) -> bool: return not p.host)
			if others.all(func(p: Dictionary) -> bool: return p.ready):
				_expect(host.room.pace == "long" and bots[1].errors.has("not_host"), "only the host can change the round length")
				host.send({"t": "start"})
				step = 5
		5:
			for b in bots:
				if b.role() != "":
					roles[b.id] = b.role()
			if host.room.phase == "ended":
				return _finish()
			_drop_and_resume()
			_talk()
			for b in bots:
				if b == bots[2] or (b == bots[1] and drop_step < 4):
					continue
				_play(b)
	return false


func _drop_and_resume() -> void:
	var host := bots[0]
	var b := bots[1]
	if drop_step >= 1 and drop_step < 4:
		var seat: Dictionary = _player(host.room, old_id)
		if not seat.connected and seat.alive:
			saw_offline_seat = true
	match drop_step:
		0:
			if host.room.phase == "night":
				old_id = b.id
				old_token = b.token
				b.ws.close()
				bots[2].ws.close()
				drop_step = 1
		1:
			if b.ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
				b.ws = WebSocketPeer.new()
				b.id = ""
				b.room = {}
				b.ws.connect_to_url(url)
				drop_step = 2
		2:
			if b.id != "":
				_expect(b.id != old_id, "a new connection first gets a fresh id")
				b.send({"t": "resume", "token": old_token})
				drop_step = 3
		3:
			if b.resumed and b.room.has("phase"):
				_expect(b.id == old_id and b.token == old_token, "resume gives back the same id and token")
				_expect(b.role() == roles[old_id] and b.room.phase != "lobby", "resumed player is back in the game with the same role")
				drop_step = 4


## Bots 0, 3, 4 stay connected the whole game; pick speakers among them.
func _talk() -> void:
	var steady: Array[Bot] = [bots[0], bots[3], bots[4]]
	var phase: String = bots[0].room.phase
	if phase == "night" and night_speaker == null:
		for b in steady:
			if roles.get(b.id) != "mafia":
				night_speaker = b
				b.say(9)
				break
	elif phase == "day" and day_speaker == null:
		for b in steady:
			if b.room.you.alive:
				day_speaker = b
				b.say(5)
				break


func _player(room: Dictionary, id: String) -> Dictionary:
	for p: Dictionary in room.get("players", []):
		if p.id == id:
			return p
	return {}


func _play(b: Bot) -> void:
	var r := b.room
	var key := "%s%d" % [r.phase, r.round]
	if b.done.has(key) or not r.you.alive or roles.size() < 5:
		return
	var me := b.role()
	var alive: Array = r.players.filter(func(p: Dictionary) -> bool: return p.alive and p.id != b.id)
	var town: Array = alive.filter(func(p: Dictionary) -> bool: return roles[p.id] != "mafia")
	var mafia: Array = alive.filter(func(p: Dictionary) -> bool: return roles[p.id] == "mafia")
	match r.phase:
		"night":
			match me:
				"mafia":
					b.send({"t": "act", "target": town[0].id})
				"doctor":
					b.send({"t": "act", "target": b.id})
				"detective":
					b.send({"t": "act", "target": alive[0].id})
		"day":
			b.send({"t": "skip"})
		"vote":
			var target: Dictionary = town[0] if me == "mafia" else mafia[0]
			b.send({"t": "vote", "target": target.id})
		_:
			return
	b.done[key] = true


func _finish() -> bool:
	var r := bots[0].room
	print("game ended after round %d, winner: %s" % [r.round, r.winner])
	print("last night: %s" % JSON.stringify(r.lastNight))
	print("last vote: %s" % JSON.stringify(r.lastVote))
	_expect(r.winner == "town", "town wins after voting out the mafia")
	_expect(r.players.all(func(p: Dictionary) -> bool: return p.role != null), "all roles revealed at the end")
	var counts := {}
	for role: String in roles.values():
		counts[role] = int(counts.get(role, 0)) + 1
	_expect(counts == {"mafia": 1, "detective": 1, "doctor": 1, "citizen": 2}, "5 players get 1 mafia, detective, doctor, 2 citizens")
	var steady: Array[Bot] = [bots[0], bots[3], bots[4]]
	_expect(range(1, 5).all(func(i: int) -> bool: return bots[i].heard_from(bots[0].id, 1)), "lobby voice reaches everyone")
	_expect(night_speaker != null and bots.all(func(b: Bot) -> bool: return not b.heard_from(night_speaker.id, 9)), "a non-mafia talking at night is heard by nobody")
	if day_speaker != null:
		_expect(steady.all(func(b: Bot) -> bool: return b == day_speaker or b.heard_from(day_speaker.id, 5)), "day voice reaches everyone")
	_expect(drop_step == 4, "dropped bot resumed its seat")
	_expect(saw_offline_seat, "seat was kept (alive, offline) while disconnected")
	var lost: Dictionary = _player(r, bots[2].id)
	_expect(not lost.connected and not lost.alive, "player who never came back is out after the grace time")
	for b in bots:
		if b == bots[2]:
			continue
		if b.role() == "detective" and b.room.you.alive:
			var c: Array = b.room.you.checks
			_expect(c.size() >= 1 and c[0].mafia == (roles[c[0].target] == "mafia"), "detective check is correct")
		_expect(b.errors.filter(func(e: String) -> bool: return e not in ["room_not_found", "not_everyone_ready", "not_host"]).is_empty(), "no unexpected errors for bot " + b.id)
	print("ALL CHECKS PASSED" if _ok else "SOME CHECKS FAILED")
	quit(0 if _ok else 1)
	return true


var _ok := true


func _expect(cond: bool, what: String) -> void:
	print(("ok: " if cond else "FAIL: ") + what)
	_ok = _ok and cond


func _fail(why: String) -> bool:
	print("FAIL: " + why)
	quit(1)
	return true
