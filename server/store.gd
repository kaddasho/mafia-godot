extends Node
## Permanent storage for accounts, friendships and messages.
## Uses Supabase (Postgres REST API) when SUPABASE_URL and SUPABASE_KEY are set in the environment;
## otherwise keeps everything in memory (local testing - lost on restart).
## Every method is a coroutine: call it with `await`.

var _url: String = ""
var _key: String = ""

# in-memory backend
var _players: Dictionary = {}  # id -> player
var _friendships: Dictionary = {}  # "a|b" -> {a, b, status, requester}
var _messages: Array = []
var _next_message_id: int = 1


func _ready() -> void:
	_url = OS.get_environment("SUPABASE_URL").strip_edges().trim_suffix("/")
	_key = OS.get_environment("SUPABASE_KEY").strip_edges()
	print("storage: ", "Supabase" if persistent() else "memory (set SUPABASE_URL / SUPABASE_KEY to keep data)")


func persistent() -> bool:
	return _url != "" and _key != ""


# --- players ---

func get_player(id: String) -> Dictionary:
	if not persistent():
		return _players.get(id, {})
	var rows: Array = await _rest(HTTPClient.METHOD_GET, "players?id=eq.%s&select=*" % id)
	return rows[0] if not rows.is_empty() else {}


func create_player(p: Dictionary) -> Dictionary:
	if not persistent():
		_players[p.id] = p.duplicate()
		return p
	var rows: Array = await _rest(HTTPClient.METHOD_POST, "players", p)
	return rows[0] if not rows.is_empty() else {}


func update_player(id: String, fields: Dictionary) -> void:
	if not persistent():
		if _players.has(id):
			_players[id].merge(fields, true)
		return
	await _rest(HTTPClient.METHOD_PATCH, "players?id=eq.%s" % id, fields)


func get_players(ids: Array) -> Array:
	if ids.is_empty():
		return []
	if not persistent():
		return ids.filter(func(i: String) -> bool: return _players.has(i)).map(func(i: String) -> Dictionary: return _players[i])
	return await _rest(HTTPClient.METHOD_GET, "players?id=in.(%s)&select=id,name,gender,country,tag" % ",".join(ids))


## By name (part of it) or by exact "name#1234".
func search_players(q: String) -> Array:
	var name := q
	var tag := -1
	if q.contains("#"):
		name = q.get_slice("#", 0).strip_edges()
		tag = int(q.get_slice("#", 1))
	if not persistent():
		var low := name.to_lower()
		var out := []
		for p: Dictionary in _players.values():
			if (tag >= 0 and p.name == name and int(p.tag) == tag) or (tag < 0 and str(p.name).to_lower().contains(low)):
				out.append(p)
		return out.slice(0, 20)
	var filter := "name=eq.%s&tag=eq.%d" % [name.uri_encode(), tag] if tag >= 0 else "name=ilike.*%s*" % name.uri_encode()
	return await _rest(HTTPClient.METHOD_GET, "players?%s&select=id,name,gender,country,tag&limit=20" % filter)


# --- friendships (stored once per pair, a < b) ---

static func pair(x: String, y: String) -> Array:
	return [x, y] if x < y else [y, x]


func get_friendships(id: String) -> Array:
	if not persistent():
		return _friendships.values().filter(func(f: Dictionary) -> bool: return f.a == id or f.b == id)
	return await _rest(HTTPClient.METHOD_GET, "friendships?or=(a.eq.%s,b.eq.%s)&select=a,b,status,requester" % [id, id])


func get_friendship(x: String, y: String) -> Dictionary:
	var ab := pair(x, y)
	if not persistent():
		return _friendships.get(ab[0] + "|" + ab[1], {})
	var rows: Array = await _rest(HTTPClient.METHOD_GET, "friendships?a=eq.%s&b=eq.%s&select=a,b,status,requester" % ab)
	return rows[0] if not rows.is_empty() else {}


func set_friendship(x: String, y: String, status: String, requester: String) -> void:
	var ab := pair(x, y)
	var row := {"a": ab[0], "b": ab[1], "status": status, "requester": requester}
	if not persistent():
		_friendships[ab[0] + "|" + ab[1]] = row
		return
	await _rest(HTTPClient.METHOD_POST, "friendships?on_conflict=a,b", row, ["Prefer: resolution=merge-duplicates,return=representation"])


func delete_friendship(x: String, y: String) -> void:
	var ab := pair(x, y)
	if not persistent():
		_friendships.erase(ab[0] + "|" + ab[1])
		return
	await _rest(HTTPClient.METHOD_DELETE, "friendships?a=eq.%s&b=eq.%s" % ab)


# --- messages ---

func add_message(sender: String, receiver: String, body: String) -> Dictionary:
	var row := {"sender": sender, "receiver": receiver, "body": body}
	if not persistent():
		row.merge({"id": _next_message_id, "read": false, "created_at": Time.get_datetime_string_from_system(true) + "Z"})
		_next_message_id += 1
		_messages.append(row)
		return row
	var rows: Array = await _rest(HTTPClient.METHOD_POST, "messages", row)
	return rows[0] if not rows.is_empty() else row


## The latest `limit` messages between two players, oldest first.
func get_messages(x: String, y: String, limit: int = 50) -> Array:
	if not persistent():
		var both := _messages.filter(func(m: Dictionary) -> bool:
			return (m.sender == x and m.receiver == y) or (m.sender == y and m.receiver == x))
		return both.slice(maxi(0, both.size() - limit))
	var rows: Array = await _rest(HTTPClient.METHOD_GET,
		"messages?or=(and(sender.eq.%s,receiver.eq.%s),and(sender.eq.%s,receiver.eq.%s))&order=id.desc&limit=%d" % [x, y, y, x, limit])
	rows.reverse()
	return rows


func mark_read(me: String, other: String) -> void:
	if not persistent():
		for m: Dictionary in _messages:
			if m.receiver == me and m.sender == other:
				m.read = true
		return
	await _rest(HTTPClient.METHOD_PATCH, "messages?receiver=eq.%s&sender=eq.%s&read=eq.false" % [me, other], {"read": true})


## sender id -> number of unread messages for `me`.
func unread_counts(me: String) -> Dictionary:
	var rows: Array
	if not persistent():
		rows = _messages.filter(func(m: Dictionary) -> bool: return m.receiver == me and not m.read)
	else:
		rows = await _rest(HTTPClient.METHOD_GET, "messages?receiver=eq.%s&read=eq.false&select=sender" % me)
	var out := {}
	for m: Dictionary in rows:
		out[m.sender] = int(out.get(m.sender, 0)) + 1
	return out


# --- Supabase REST ---

## One PostgREST call; returns the decoded rows (empty array on error or no content).
func _rest(method: int, path: String, body: Variant = null, extra: Array = []) -> Array:
	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	var headers := PackedStringArray([
		"apikey: " + _key, "Authorization: Bearer " + _key, "Content-Type: application/json"])
	if extra.is_empty():
		headers.append("Prefer: return=representation")
	for h: String in extra:
		headers.append(h)
	var err := http.request(_url + "/rest/v1/" + path, headers, method, "" if body == null else JSON.stringify(body))
	if err != OK:
		http.queue_free()
		push_error("storage request failed to start: %d" % err)
		return []
	var res: Array = await http.request_completed
	http.queue_free()
	var code: int = res[1]
	var text: String = (res[3] as PackedByteArray).get_string_from_utf8()
	if code < 200 or code >= 300:
		push_error("storage %s -> %d %s" % [path.get_slice("?", 0), code, text.left(200)])
		return []
	var parsed: Variant = JSON.parse_string(text) if text != "" else []
	return parsed if parsed is Array else ([parsed] if parsed is Dictionary else [])
