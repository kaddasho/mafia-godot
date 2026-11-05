extends RefCounted
## One room: its players, the lobby and the game itself
## (roles -> night -> day with speaking turns -> secret vote -> result -> night ...).
## Every change is pushed with broadcast(); each player gets their own view (hidden roles stay hidden).

const MIN_PLAYERS := 4
const MAX_PLAYERS := 15
const AUTO_START_MS := 15000
const ROLES_MS := 7000
const RESULT_MS := 7000
const ENDED_MS := 20000
const REACTIONS := 7  # emoji 0..6, drawn by the client
const REACT_GAP_MS := 400  # per player, to stop spam
const CHAT_GAP_MS := 600  # per player, to stop spam
const CHAT_MAX := 200  # characters per chat line
## Phase lengths (ms) the host picks in the lobby; "turn" is each speaker's time in the discussion.
const PACES := {
	"short": {"night": 30000, "day": 60000, "vote": 30000, "turn": 20000},
	"medium": {"night": 45000, "day": 180000, "vote": 45000, "turn": 30000},
	"long": {"night": 60000, "day": 300000, "vote": 60000, "turn": 45000},
}
const NIGHT_ROLES: Array[String] = ["mafia", "doctor", "detective"]
const TALK_PHASES: Array[String] = ["night", "day", "vote", "result"]

## How long a disconnected player keeps their seat before they count as having left.
static var grace_ms: int = 60000

var code: String
var name: String
var is_public: bool
var max_players: int

var lang: String = ""  # creator's language, shown in the public room list
var auto_start: bool = false  # quick-play rooms start on their own once enough players are in
var pace: String = "medium"
var mafia_count: int = 0  # 0 = automatic
var open_talk: bool = false  # discussion without a time limit; the host moves it on to the vote
var phase: String = "lobby"
var deadline: int = 0
var auto_start_at: int = 0
var round_no: int = 0
var host_id: String = ""
## {id, name, gender, country, ready, connected, alive, role, gone, drop_at}
var players: Array[Dictionary] = []
## Joined while a game was running (invite / join a friend): they wait in the lobby view and take a
## seat when the room goes back to the lobby. They see no roles and get no voice or chat.
var waiting: Array[Dictionary] = []

## Speaking turns in the discussion: everyone may talk, the turn just says whose floor it is.
var turn_order: Array[String] = []
var turn_idx: int = -1  # -1 = no current speaker (open floor after the last turn)
var turn_deadline: int = 0
var _last_react: Dictionary = {}  # player id -> ms
var _last_chat: Dictionary = {}  # player id -> ms

var night_actions: Dictionary = {}  # actor id -> target id
var day_skips: Dictionary = {}  # player id -> true
var votes: Dictionary = {}  # voter id -> target id ("" = skip)
var checks: Dictionary = {}  # detective id -> [{target, mafia}]
var last_night: Dictionary = {}
var last_vote: Dictionary = {}
var winner: String = ""

var _send: Callable


func _init(room_code: String, room_name: String, public: bool, max_count: int, send: Callable) -> void:
	code = room_code
	name = room_name
	is_public = public
	max_players = max_count
	_send = send


static func now_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


func find(id: String) -> Dictionary:
	for p in players:
		if p.id == id:
			return p
	return {}


## True when nobody is connected and nobody is still within their reconnect window.
func is_empty() -> bool:
	for p in players:
		if p.connected or p.drop_at > 0:
			return false
	return waiting.is_empty()


## Seats taken, counting the players waiting for the next round.
func seats_taken() -> int:
	return players.size() + waiting.size()


func is_waiting(id: String) -> bool:
	return waiting.any(func(w: Dictionary) -> bool: return w.id == id)


func is_open() -> bool:
	return phase == "lobby" and players.size() < max_players


## One line of the public room list.
func summary() -> Dictionary:
	return {"code": code, "name": name, "players": players.size(), "max": max_players,
		"lang": lang, "pace": pace, "mafia": mafia_count, "openTalk": open_talk}


# --- lobby ---

func add_player(id: String, player_name: String, gender: String = "", country: String = "", account: String = "", avatar: int = 0, photo: String = "") -> String:
	if seats_taken() >= max_players:
		return "room_full"
	var p := {"id": id, "name": player_name, "gender": gender, "country": country, "account": account, "avatar": avatar, "photo": photo,
		"ready": false, "connected": true, "alive": true, "role": "", "gone": false, "drop_at": 0}
	if phase != "lobby":
		# a game is running: wait for the next round instead of joining it
		waiting.append(p)
		_send.call(id, view_for(p))
		return ""
	players.append(p)
	if host_id == "":
		host_id = id
	_update_auto_start()
	broadcast()
	return ""


## Leaving (or disconnecting) in the lobby removes the player; during a game they die and stay listed.
func remove_player(id: String) -> void:
	if is_waiting(id):
		waiting = waiting.filter(func(w: Dictionary) -> bool: return w.id != id)
		return
	var p := find(id)
	if p.is_empty():
		return
	if phase == "lobby":
		players.remove_at(_index(id))
	else:
		p.connected = false
		p.drop_at = 0
		p.gone = true
		p.alive = false
		night_actions.erase(id)
		votes.erase(id)
		day_skips.erase(id)
	if host_id == id:
		_pick_host()
	if phase == "lobby":
		_update_auto_start()
	elif phase != "ended" and (_check_win() or _maybe_advance_early()):
		return
	elif phase == "day" and current_speaker() == id:
		_next_turn()
		return
	broadcast()


## Lost connection: keep the seat for grace_ms, then remove_player() runs from tick().
func disconnect_player(id: String) -> void:
	if is_waiting(id):  # nothing to keep for someone who was only waiting
		remove_player(id)
		return
	var p := find(id)
	if p.is_empty() or p.gone:
		return
	p.connected = false
	p.drop_at = now_ms() + grace_ms
	if host_id == id:
		_pick_host()
	broadcast()


func reconnect_player(id: String) -> bool:
	var p := find(id)
	if p.is_empty() or p.gone:
		return false
	p.connected = true
	p.drop_at = 0
	if host_id == "":
		host_id = id
	broadcast()
	return true


func set_pace(by: String, value: String) -> String:
	var err := _host_lobby(by)
	if err != "":
		return err
	if not PACES.has(value):
		return "bad_value"
	pace = value
	broadcast()
	return ""


## Host's mafia count: 0 = automatic, 1..4 = fixed (capped by max_mafia() when the game starts).
func set_mafia(by: String, value: int) -> String:
	var err := _host_lobby(by)
	if err != "":
		return err
	if value < 0 or value > 4:
		return "bad_value"
	mafia_count = value
	broadcast()
	return ""


func set_open_talk(by: String, value: bool) -> String:
	var err := _host_lobby(by)
	if err != "":
		return err
	open_talk = value
	broadcast()
	return ""


## Room size 4..15; never below the players already inside.
func set_max_players(by: String, value: int) -> String:
	var err := _host_lobby(by)
	if err != "":
		return err
	if value < maxi(MIN_PLAYERS, players.size()) or value > MAX_PLAYERS:
		return "bad_value"
	max_players = value
	broadcast()
	return ""


func _host_lobby(by: String) -> String:
	if phase != "lobby":
		return "room_in_progress"
	if by != host_id:
		return "not_host"
	return ""


## Mafia must start as a clear minority, otherwise they win at once.
static func max_mafia(n: int) -> int:
	return maxi(1, mini(4, (n - 1) / 2))


## Emoji reaction, sent to everyone in the room; doesn't touch the game state.
func react(id: String, emoji: int) -> String:
	var p := find(id)
	if p.is_empty() or emoji < 0 or emoji >= REACTIONS:
		return "bad_value"
	var now := now_ms()
	if now - int(_last_react.get(id, 0)) < REACT_GAP_MS:
		return ""  # too fast: silently dropped
	_last_react[id] = now
	for q in players:
		if q.connected:
			_send.call(q.id, {"t": "react", "from": id, "e": emoji})
	return ""


## Text chat in the room. Same rule as voice (who may talk now reaches whoever may hear them);
## the sender also gets their own line back. At night the mafia's lines are marked "team".
func chat(id: String, text: String) -> String:
	var p := find(id)
	if p.is_empty():
		return "not_in_room"
	text = text.strip_edges().replace("\n", " ").left(CHAT_MAX)
	if text == "":
		return ""
	var now := now_ms()
	if now - int(_last_chat.get(id, 0)) < CHAT_GAP_MS:
		return ""  # too fast: silently dropped
	var targets := voice_targets(id)
	if targets.is_empty() and TALK_PHASES.has(phase) and (not p.alive or (phase == "night" and p.role != "mafia")):
		return "cant_talk_now"
	_last_chat[id] = now
	var line := {"t": "chat", "from": id, "name": p.name, "text": text, "team": phase == "night"}
	_send.call(id, line)
	for t in targets:
		_send.call(t, line)
	return ""


## A player changed their profile photo: the room shows the new one.
func set_photo(account: String, ver: String) -> void:
	for p in players:
		if p.account == account and p.get("photo", "") != ver:
			p["photo"] = ver
			broadcast()
			return


## The player's own mute switch, shown to the others as a small red badge.
func set_muted(id: String, on: bool) -> void:
	var p := find(id)
	if p.is_empty() or bool(p.get("muted", false)) == on:
		return
	p["muted"] = on
	broadcast()


func _ms(phase_name: String) -> int:
	return PACES[pace][phase_name]


## Who hears this speaker right now. Lobby / roles / end: everyone. Day and vote: the living speak
## to all. Night: mafia speak only to living mafia. The dead never speak during a game.
func voice_targets(speaker_id: String) -> Array[String]:
	var out: Array[String] = []
	var s := find(speaker_id)
	if s.is_empty():
		return out
	var in_game := TALK_PHASES.has(phase)
	if in_game and not s.alive:
		return out
	if phase == "night" and s.role != "mafia":
		return out
	for p in players:
		if p.id == speaker_id or not p.connected:
			continue
		if phase == "night" and not (p.alive and p.role == "mafia"):
			continue
		out.append(p.id)
	return out


func set_ready(id: String, value: bool) -> void:
	var p := find(id)
	if phase != "lobby" or p.is_empty():
		return
	p.ready = value
	broadcast()


func start(by: String) -> String:
	if phase != "lobby":
		return "room_in_progress"
	if by != host_id:
		return "not_host"
	if players.size() < MIN_PLAYERS:
		return "not_enough_players"
	for p in players:
		if p.id != host_id and not p.ready:
			return "not_everyone_ready"
	_begin_game()
	return ""


# --- game actions ---

func act(id: String, target: String) -> String:
	if phase != "night":
		return "wrong_phase"
	var p := find(id)
	if p.is_empty() or not p.alive or not NIGHT_ROLES.has(p.role):
		return "not_allowed"
	var t := find(target)
	if t.is_empty() or not t.alive:
		return "bad_target"
	if (p.role == "mafia" and t.role == "mafia") or (p.role == "detective" and target == id):
		return "bad_target"
	night_actions[id] = target
	if not _maybe_advance_early():
		broadcast()
	return ""


func skip(id: String) -> String:
	if phase != "day":
		return "wrong_phase"
	var p := find(id)
	if p.is_empty() or not p.alive:
		return "not_allowed"
	day_skips[id] = true
	if not _maybe_advance_early():
		broadcast()
	return ""


func current_speaker() -> String:
	return turn_order[turn_idx] if turn_idx >= 0 and turn_idx < turn_order.size() else ""


## Discussion turns. The speaker can "pass"; the host can go "next" / "prev", "select" anyone alive,
## or "vote" to end the discussion.
func turn(by: String, action: String, target: String = "") -> String:
	if phase != "day":
		return "wrong_phase"
	match action:
		"pass":
			if by != current_speaker():
				return "not_allowed"
			_next_turn()
		"next", "prev", "select", "vote":
			if by != host_id:
				return "not_host"
			match action:
				"next":
					_next_turn()
				"prev":
					_set_turn(maxi(0, turn_idx - 1), -1)
				"select":
					var i := turn_order.find(target)
					var t := find(target)
					if i < 0 or t.is_empty() or not t.alive:
						return "bad_target"
					_set_turn(i, 1)
				"vote":
					_enter("vote", _ms("vote"))
		_:
			return "bad_value"
	return ""


func _next_turn() -> void:
	_set_turn(turn_idx + 1, 1)


## Moves the floor to index `i`, stepping in direction `dir` past anyone dead or offline.
## Past the last speaker: open floor if the discussion is unlimited, otherwise on to the vote.
func _set_turn(i: int, dir: int) -> void:
	while i >= 0 and i < turn_order.size():
		var p := find(turn_order[i])
		if not p.is_empty() and p.alive and p.connected:
			break
		i += dir
	if i < 0 or i >= turn_order.size():
		if not open_talk and dir > 0:
			_enter("vote", _ms("vote"))
			return
		i = -1 if dir > 0 else turn_idx
	turn_idx = i
	turn_deadline = now_ms() + _ms("turn") if turn_idx >= 0 and not open_talk else 0
	broadcast()


## target "" means "skip the vote".
func vote(id: String, target: String) -> String:
	if phase != "vote":
		return "wrong_phase"
	var p := find(id)
	if p.is_empty() or not p.alive:
		return "not_allowed"
	if target != "":
		var t := find(target)
		if t.is_empty() or not t.alive or target == id:
			return "bad_target"
	votes[id] = target
	if not _maybe_advance_early():
		broadcast()
	return ""


func tick(now: int) -> void:
	for p in players.duplicate():
		if p.drop_at > 0 and now >= p.drop_at:
			remove_player(p.id)
	if phase == "lobby":
		if auto_start_at > 0 and now >= auto_start_at:
			auto_start_at = 0
			if players.size() >= MIN_PLAYERS:
				_begin_game()
			else:
				broadcast()
		return
	if deadline > 0 and now >= deadline:
		_advance()
	elif phase == "day" and turn_deadline > 0 and now >= turn_deadline:
		_next_turn()


# --- game flow ---

func _begin_game() -> void:
	auto_start_at = 0
	round_no = 0
	winner = ""
	last_night = {}
	last_vote = {}
	checks = {}
	var roles := _role_list(players.size())
	roles.shuffle()
	for i in players.size():
		players[i].role = roles[i]
		players[i].alive = true
	_enter("roles", ROLES_MS)


func _role_list(n: int) -> Array[String]:
	var mafia := 1 if n < 6 else (2 if n < 9 else (3 if n < 13 else 4))
	if mafia_count > 0:
		mafia = mini(mafia_count, max_mafia(n))
	var roles: Array[String] = []
	for i in mafia:
		roles.append("mafia")
	roles.append("detective")
	roles.append("doctor")
	while roles.size() < n:
		roles.append("citizen")
	return roles


func _enter(new_phase: String, ms: int) -> void:
	phase = new_phase
	deadline = now_ms() + ms if ms > 0 else 0
	turn_deadline = 0
	match phase:
		"night":
			round_no += 1
			night_actions.clear()
		"day":
			day_skips.clear()
			if open_talk:
				deadline = 0
			# living players speak in seat order, starting one seat later each round
			var living: Array[String] = []
			for p in players:
				if p.alive:
					living.append(p.id)
			turn_order.clear()
			for k in living.size():
				turn_order.append(living[(k + round_no - 1) % living.size()])
			turn_idx = -1
			_set_turn(0, 1)
			return  # _set_turn broadcasts
		"vote":
			votes.clear()
			turn_idx = -1
	broadcast()


func _advance() -> void:
	match phase:
		"roles":
			_enter("night", _ms("night"))
		"night":
			_resolve_night()
		"day":
			_enter("vote", _ms("vote"))
		"vote":
			_resolve_vote()
		"result":
			_enter("night", _ms("night"))
		"ended":
			_back_to_lobby()


## Ends the current phase early once every living player who can act has acted.
func _maybe_advance_early() -> bool:
	for p in players:
		if not p.alive:
			continue
		match phase:
			"night":
				if NIGHT_ROLES.has(p.role) and not night_actions.has(p.id):
					return false
			"day":
				if not day_skips.has(p.id):
					return false
			"vote":
				if not votes.has(p.id):
					return false
			_:
				return false
	_advance()
	return true


func _resolve_night() -> void:
	var mafia_votes := {}
	var heal := ""
	for actor_id: String in night_actions:
		var actor := find(actor_id)
		if actor.is_empty() or not actor.alive:
			continue
		var target: String = night_actions[actor_id]
		match actor.role:
			"mafia":
				mafia_votes[target] = int(mafia_votes.get(target, 0)) + 1
			"doctor":
				heal = target
			"detective":
				if not checks.has(actor_id):
					checks[actor_id] = []
				checks[actor_id].append({"target": target, "round": round_no, "mafia": find(target).role == "mafia"})

	# Split mafia votes: pick one of the most-voted targets at random.
	var victim := ""
	var top: Array = _most_voted(mafia_votes)
	if not top.is_empty():
		victim = top.pick_random()
	last_night = {"round": round_no, "killed": "", "saved": false}
	if victim != "":
		if victim == heal:
			last_night.saved = true
		else:
			find(victim).alive = false
			last_night.killed = victim
	if not _check_win():
		_enter("day", _ms("day"))


func _resolve_vote() -> void:
	var tally := {}
	for voter: String in votes:
		var target: String = votes[voter]
		tally[target] = int(tally.get(target, 0)) + 1
	# Nobody leaves on a tie, or when "skip" wins.
	var out := ""
	var top: Array = _most_voted(tally)
	if top.size() == 1 and top[0] != "":
		out = top[0]
		find(out).alive = false
	tally.erase("")
	last_vote = {"round": round_no, "out": out, "votes": votes.duplicate(), "tally": tally,
		"abstained": votes.values().count("")}
	if not _check_win():
		_enter("result", RESULT_MS)


func _most_voted(tally: Dictionary) -> Array:
	var best := 0
	var top := []
	for key in tally:
		var n: int = tally[key]
		if n > best:
			best = n
			top = [key]
		elif n == best:
			top.append(key)
	return top


func _check_win() -> bool:
	var mafia := 0
	var town := 0
	for p in players:
		if p.alive:
			if p.role == "mafia":
				mafia += 1
			else:
				town += 1
	if mafia == 0:
		winner = "town"
	elif mafia >= town:
		winner = "mafia"
	else:
		return false
	_enter("ended", ENDED_MS)
	return true


func _back_to_lobby() -> void:
	for i in range(players.size() - 1, -1, -1):
		if players[i].gone:
			players.remove_at(i)
	for p in players:
		p.ready = false
		p.alive = true
		p.role = ""
	for w in waiting:  # the players who waited take their seats now
		if players.size() < max_players:
			players.append(w)
	waiting.clear()
	phase = "lobby"
	deadline = 0
	winner = ""
	_update_auto_start()
	broadcast()


func _update_auto_start() -> void:
	if auto_start and phase == "lobby" and players.size() >= MIN_PLAYERS:
		if auto_start_at == 0:
			auto_start_at = now_ms() + AUTO_START_MS
	else:
		auto_start_at = 0


func _pick_host() -> void:
	host_id = ""
	for p in players:
		if p.connected:
			host_id = p.id
			return


func _index(id: String) -> int:
	for i in players.size():
		if players[i].id == id:
			return i
	return -1


# --- what each player sees ---

func broadcast() -> void:
	for p in players:
		if p.connected:
			_send.call(p.id, view_for(p))
	for w in waiting:
		_send.call(w.id, view_for(w))


func view_for(me: Dictionary) -> Dictionary:
	var list := []
	for p in players:
		var visible: bool = phase == "ended" or p.id == me.id or not p.alive \
				or (me.role == "mafia" and p.role == "mafia")
		list.append({
			"id": p.id,
			"name": p.name,
			"gender": p.gender,
			"country": p.country,
			"avatar": p.get("avatar", 0),  # chosen portrait 1..15, 0 = none
			"photo": p.get("photo", ""),  # version of the uploaded profile photo, "" = none
			"account": p.account,  # public account id, so players can add each other as friends
			"ready": p.ready,
			"host": p.id == host_id,
			"connected": p.connected,
			"muted": bool(p.get("muted", false)),
			"alive": p.alive,
			"role": p.role if visible and p.role != "" else null,
		})

	var you := {
		"id": me.id,
		"role": me.role if me.role != "" else null,
		"alive": me.alive,
		"target": night_actions.get(me.id, null),
		"vote": votes.get(me.id, null),
		"skipped": day_skips.has(me.id),
		"checks": checks.get(me.id, []),
	}
	if me.role == "mafia" and phase == "night":
		var team := {}
		for actor_id: String in night_actions:
			if find(actor_id).role == "mafia":
				team[actor_id] = night_actions[actor_id]
		you["mafiaTargets"] = team

	var d := {
		"t": "room",
		"code": code,
		"name": name,
		"isPublic": is_public,
		"pace": pace,
		"mafia": mafia_count,
		"mafiaMax": max_mafia(players.size()),
		"openTalk": open_talk,
		"max": max_players,
		"phase": phase,
		"round": round_no,
		"now": now_ms(),
		"deadline": deadline,
		"autoStartAt": auto_start_at,
		"players": list,
		"you": you,
		"lastNight": last_night,
		"lastVote": last_vote,
		"winner": winner,
	}
	if is_waiting(str(me.id)):
		# lobby view with the game hidden: who is in the room, and "you join next round"
		d["phase"] = "lobby"
		d["waiting"] = true
		d["lastNight"] = {}
		d["lastVote"] = {}
		for p: Dictionary in list:
			p["role"] = null
			p["alive"] = true
		return d
	if phase == "day":
		d["skips"] = day_skips.keys()
		d["turn"] = {"speaker": current_speaker(), "idx": turn_idx, "total": turn_order.size(),
			"deadline": turn_deadline, "order": turn_order}
	if phase == "vote":
		# votes stay secret until the result: only progress is shared
		var alive := 0
		for p in players:
			if p.alive:
				alive += 1
		d["voted"] = votes.size()
		d["voters"] = alive
	return d
