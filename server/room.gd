extends RefCounted
## One room: its players, the lobby and the game itself (roles -> night -> day -> vote -> ...).
## Every change is pushed with broadcast(); each player gets their own view (hidden roles stay hidden).

const MIN_PLAYERS := 4
const AUTO_START_MS := 15000
const ROLES_MS := 6000
const ENDED_MS := 20000
## Phase lengths (ms) the host picks in the lobby.
const PACES := {
	"short": {"night": 30000, "day": 60000, "vote": 30000},
	"medium": {"night": 45000, "day": 180000, "vote": 45000},
	"long": {"night": 60000, "day": 300000, "vote": 60000},
}
const NIGHT_ROLES: Array[String] = ["mafia", "doctor", "detective"]

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
var phase: String = "lobby"
var deadline: int = 0
var auto_start_at: int = 0
var round_no: int = 0
var host_id: String = ""
## {id, name, ready, connected, alive, role, gone, drop_at}
var players: Array[Dictionary] = []

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
	return true


func is_open() -> bool:
	return phase == "lobby" and players.size() < max_players


## One line of the public room list.
func summary() -> Dictionary:
	return {"code": code, "name": name, "players": players.size(), "max": max_players,
		"lang": lang, "pace": pace, "mafia": mafia_count}


# --- lobby ---

func add_player(id: String, player_name: String) -> String:
	if phase != "lobby":
		return "room_in_progress"
	if players.size() >= max_players:
		return "room_full"
	players.append({"id": id, "name": player_name, "ready": false, "connected": true, "alive": true, "role": "", "gone": false, "drop_at": 0})
	if host_id == "":
		host_id = id
	_update_auto_start()
	broadcast()
	return ""


## Leaving (or disconnecting) in the lobby removes the player; during a game they die and stay listed.
func remove_player(id: String) -> void:
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
	broadcast()


## Lost connection: keep the seat for grace_ms, then remove_player() runs from tick().
func disconnect_player(id: String) -> void:
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
	if phase != "lobby":
		return "room_in_progress"
	if by != host_id:
		return "not_host"
	if not PACES.has(value):
		return "bad_value"
	pace = value
	broadcast()
	return ""


## Host's mafia count: 0 = automatic, 1..3 = fixed (capped by max_mafia() when the game starts).
func set_mafia(by: String, value: int) -> String:
	if phase != "lobby":
		return "room_in_progress"
	if by != host_id:
		return "not_host"
	if value < 0 or value > 3:
		return "bad_value"
	mafia_count = value
	broadcast()
	return ""


## Mafia must start as a clear minority, otherwise they win at once.
static func max_mafia(n: int) -> int:
	return maxi(1, mini(3, (n - 1) / 2))


func _ms(phase_name: String) -> int:
	return PACES[pace][phase_name]


## Who hears this speaker right now. Lobby / roles / end: everyone. Day and vote: the living speak
## to all. Night: mafia speak only to living mafia. The dead never speak during a game.
func voice_targets(speaker_id: String) -> Array[String]:
	var out: Array[String] = []
	var s := find(speaker_id)
	if s.is_empty():
		return out
	var in_game := phase in ["night", "day", "vote"]
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
	var mafia := 1 if n < 6 else (2 if n < 9 else 3)
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
	match phase:
		"night":
			round_no += 1
			night_actions.clear()
		"day":
			day_skips.clear()
		"vote":
			votes.clear()
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
	last_vote = {"round": round_no, "out": out, "votes": votes.duplicate()}
	if not _check_win():
		_enter("night", _ms("night"))


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


func view_for(me: Dictionary) -> Dictionary:
	var list := []
	for p in players:
		var visible: bool = phase == "ended" or p.id == me.id or not p.alive \
				or (me.role == "mafia" and p.role == "mafia")
		list.append({
			"id": p.id,
			"name": p.name,
			"ready": p.ready,
			"host": p.id == host_id,
			"connected": p.connected,
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
	if phase == "day":
		d["skips"] = day_skips.keys()
	if phase == "vote":
		d["votes"] = votes
	return d
