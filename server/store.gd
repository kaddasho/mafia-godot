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
var _blocks: Dictionary = {}  # "blocker>blocked" -> true
var _reports: Array = []
var _files: Dictionary = {}  # storage path -> bytes


func _ready() -> void:
	# Keys pasted into a dashboard sometimes pick up line breaks or spaces; none are valid inside a URL or key.
	_url = _no_spaces(OS.get_environment("SUPABASE_URL")).trim_suffix("/")
	_key = _no_spaces(OS.get_environment("SUPABASE_KEY"))
	print("storage: ", "Supabase" if persistent() else "memory (set SUPABASE_URL / SUPABASE_KEY to keep data)")


static func _no_spaces(s: String) -> String:
	return "".join(s.split(" ", false)).replace("\n", "").replace("\r", "").replace("\t", "")


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
	return await _rest(HTTPClient.METHOD_GET, "players?id=in.(%s)&select=id,name,gender,country,tag,photo" % ",".join(ids))


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
	return await _rest(HTTPClient.METHOD_GET, "players?%s&select=id,name,gender,country,tag,photo&limit=20" % filter)


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

func add_message(sender: String, receiver: String, body: String, image: String = "") -> Dictionary:
	var row := {"sender": sender, "receiver": receiver, "body": body}
	if image != "":
		row["image"] = image
	if not persistent():
		row.merge({"id": _next_message_id, "read": false, "created_at": Time.get_datetime_string_from_system(true) + "Z"})
		_next_message_id += 1
		_messages.append(row)
		return row
	var rows: Array = await _rest(HTTPClient.METHOD_POST, "messages", row)
	return rows[0] if not rows.is_empty() else row


## The latest `limit` messages between two players (older than id `before` when given), oldest first.
func get_messages(x: String, y: String, limit: int = 50, before: int = 0) -> Array:
	if not persistent():
		var both := _messages.filter(func(m: Dictionary) -> bool:
			return ((m.sender == x and m.receiver == y) or (m.sender == y and m.receiver == x)) and (before <= 0 or int(m.id) < before))
		return both.slice(maxi(0, both.size() - limit))
	var rows: Array = await _rest(HTTPClient.METHOD_GET,
		"messages?or=(and(sender.eq.%s,receiver.eq.%s),and(sender.eq.%s,receiver.eq.%s))%s&order=id.desc&limit=%d" % [x, y, y, x, "&id=lt.%d" % before if before > 0 else "", limit])
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


func get_message(id: int) -> Dictionary:
	if not persistent():
		for m: Dictionary in _messages:
			if int(m.id) == id:
				return m
		return {}
	var rows: Array = await _rest(HTTPClient.METHOD_GET, "messages?id=eq.%d&select=*" % id)
	return rows[0] if not rows.is_empty() else {}


# --- blocking and reports ---

## True if either player blocked the other.
func is_blocked(x: String, y: String) -> bool:
	if not persistent():
		return _blocks.has(x + ">" + y) or _blocks.has(y + ">" + x)
	var rows: Array = await _rest(HTTPClient.METHOD_GET,
		"blocks?or=(and(blocker.eq.%s,blocked.eq.%s),and(blocker.eq.%s,blocked.eq.%s))&select=blocker" % [x, y, y, x])
	return not rows.is_empty()


func set_block(blocker: String, blocked: String, on: bool) -> void:
	if not persistent():
		if on:
			_blocks[blocker + ">" + blocked] = true
		else:
			_blocks.erase(blocker + ">" + blocked)
		return
	if on:
		await _rest(HTTPClient.METHOD_POST, "blocks?on_conflict=blocker,blocked", {"blocker": blocker, "blocked": blocked},
			["Prefer: resolution=ignore-duplicates,return=minimal"])
	else:
		await _rest(HTTPClient.METHOD_DELETE, "blocks?blocker=eq.%s&blocked=eq.%s" % [blocker, blocked])


## Players who blocked `me`.
func blockers_of(me: String) -> Array:
	if not persistent():
		var out := []
		for k: String in _blocks:
			if k.ends_with(">" + me):
				out.append(k.get_slice(">", 0))
		return out
	var rows: Array = await _rest(HTTPClient.METHOD_GET, "blocks?blocked=eq.%s&select=blocker" % me)
	return rows.map(func(r: Dictionary) -> String: return str(r.blocker))


## Players `me` has blocked.
func blocked_by(me: String) -> Array:
	if not persistent():
		var out := []
		for k: String in _blocks:
			if k.begins_with(me + ">"):
				out.append(k.get_slice(">", 1))
		return out
	var rows: Array = await _rest(HTTPClient.METHOD_GET, "blocks?blocker=eq.%s&select=blocked" % me)
	return rows.map(func(r: Dictionary) -> String: return str(r.blocked))


## A report about a player, or about one message / image of theirs (message_id > 0). The moderator
## reviews these in Supabase (table "reports", newest open ones first).
func add_report(reporter: String, target: String, reason: String, message_id: int = 0, image: String = "") -> void:
	var row := {"reporter": reporter, "target": target, "reason": reason}
	if message_id > 0:
		row["message_id"] = message_id
		row["kind"] = "image" if image != "" else "message"
		if image != "":
			row["image"] = image
	if not persistent():
		_reports.append(row)
		return
	await _rest(HTTPClient.METHOD_POST, "reports", row, ["Prefer: return=minimal"])


## Reported message: hidden from both people until a moderator looks at it.
func hide_message(id: int) -> void:
	if not persistent():
		for m: Dictionary in _messages:
			if int(m.id) == id:
				m.hidden = true
		return
	await _rest(HTTPClient.METHOD_PATCH, "messages?id=eq.%d" % id, {"hidden": true}, ["Prefer: return=minimal"])


# --- Google sign-in link and account deletion ---

func find_player_by_google(google_id: String) -> Dictionary:
	if not persistent():
		for p: Dictionary in _players.values():
			if str(p.get("google_id", "")) == google_id:
				return p
		return {}
	var rows: Array = await _rest(HTTPClient.METHOD_GET, "players?google_id=eq.%s&select=*" % google_id.uri_encode())
	return rows[0] if not rows.is_empty() else {}


## The Supabase Auth user behind an access token (Google sign-in on the website), or {} if the
## token is not valid. Only the user id is used; nothing else from the Google profile is stored.
## Local tests (no Supabase) accept "test:<id>" tokens, and only when MAFIA_TEST_AUTH=1 is set.
func auth_user(access_token: String) -> Dictionary:
	if not persistent():
		if OS.get_environment("MAFIA_TEST_AUTH") == "1" and access_token.begins_with("test:"):
			return {"id": access_token.trim_prefix("test:")}
		return {}
	var res := await _raw(HTTPClient.METHOD_GET, "/auth/v1/user", PackedByteArray(), ["Authorization: Bearer " + access_token], false)
	if res[0] != 200:
		return {}
	var parsed: Variant = JSON.parse_string((res[1] as PackedByteArray).get_string_from_utf8())
	return parsed if parsed is Dictionary and str(parsed.get("id", "")) != "" else {}


## Removes the Supabase Auth user (the Google sign-in record with the e-mail address).
func delete_auth_user(google_id: String) -> void:
	if not persistent() or google_id == "":
		return
	await _raw(HTTPClient.METHOD_DELETE, "/auth/v1/admin/users/%s" % google_id.uri_encode())


## Paths of the chat images this player sent (stored in the private bucket).
func images_sent_by(id: String) -> Array:
	if not persistent():
		return _messages.filter(func(m: Dictionary) -> bool: return m.sender == id and str(m.get("image", "")) != "").map(func(m: Dictionary) -> String: return str(m.image))
	var rows: Array = await _rest(HTTPClient.METHOD_GET, "messages?sender=eq.%s&image=not.is.null&select=image" % id)
	return rows.map(func(r: Dictionary) -> String: return str(r.image))


## Every file under a folder of the bucket (profile photos of one account).
func list_files(prefix: String) -> Array:
	if not persistent():
		return _files.keys().filter(func(k: String) -> bool: return k.begins_with(prefix))
	var res := await _raw(HTTPClient.METHOD_POST, "/storage/v1/object/list/%s" % BUCKET,
		JSON.stringify({"prefix": prefix, "limit": 1000}).to_utf8_buffer(), ["Content-Type: application/json"])
	var parsed: Variant = JSON.parse_string((res[1] as PackedByteArray).get_string_from_utf8()) if res[0] == 200 else []
	var out := []
	if parsed is Array:
		for f: Variant in parsed:
			if f is Dictionary and str(f.get("name", "")) != "":
				out.append(prefix.trim_suffix("/") + "/" + str(f.name))
	return out


## Deletes the account row; friendships, messages (both directions), blocks and reports made by the
## player go with it (foreign keys "on delete cascade"). Files are removed by the caller first.
func delete_player(id: String) -> bool:
	if not persistent():
		_players.erase(id)
		for k: String in _friendships.keys():
			if k.contains(id):
				_friendships.erase(k)
		_messages = _messages.filter(func(m: Dictionary) -> bool: return m.sender != id and m.receiver != id)
		for k: String in _blocks.keys():
			if k.contains(id):
				_blocks.erase(k)
		_reports = _reports.filter(func(r: Dictionary) -> bool: return r.reporter != id)
		return true
	var res := await _raw(HTTPClient.METHOD_DELETE, "/rest/v1/players?id=eq.%s" % id)
	return res[0] >= 200 and res[0] < 300


# --- files (profile photos, chat images) in the private Supabase Storage bucket ---

const BUCKET := "media"


func put_file(path: String, data: PackedByteArray, mime: String = "image/jpeg") -> bool:
	if not persistent():
		_files[path] = data
		return true
	var res := await _raw(HTTPClient.METHOD_POST, "/storage/v1/object/%s/%s" % [BUCKET, path], data,
		["Content-Type: " + mime, "x-upsert: true"])
	return res[0] >= 200 and res[0] < 300


func get_file(path: String) -> PackedByteArray:
	if not persistent():
		return _files.get(path, PackedByteArray())
	var res := await _raw(HTTPClient.METHOD_GET, "/storage/v1/object/%s/%s" % [BUCKET, path])
	return res[1] if res[0] == 200 else PackedByteArray()


func delete_file(path: String) -> void:
	if not persistent():
		_files.erase(path)
		return
	await _raw(HTTPClient.METHOD_DELETE, "/storage/v1/object/%s/%s" % [BUCKET, path])


## Binary request to Supabase (storage); returns [status code, body bytes].
func _raw(method: int, path: String, body: PackedByteArray = PackedByteArray(), extra: Array = [], service_auth: bool = true) -> Array:
	var http := HTTPRequest.new()
	http.timeout = 30.0
	http.body_size_limit = 2 * 1024 * 1024
	add_child(http)
	var headers := PackedStringArray(["apikey: " + _key])
	if service_auth and _key.begins_with("eyJ"):
		headers.append("Authorization: Bearer " + _key)
	for h: String in extra:
		headers.append(h)
	var err := http.request_raw(_url + path, headers, method, body)
	if err != OK:
		http.queue_free()
		return [0, PackedByteArray()]
	var res: Array = await http.request_completed
	http.queue_free()
	if res[1] < 200 or res[1] >= 300:
		push_error("storage file %s -> %d %s" % [path, res[1], (res[3] as PackedByteArray).get_string_from_utf8().left(200)])
	return [res[1], res[3]]


# --- Supabase REST ---

## One PostgREST call; returns the decoded rows (empty array on error or no content).
func _rest(method: int, path: String, body: Variant = null, extra: Array = []) -> Array:
	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	var headers := PackedStringArray(["apikey: " + _key, "Content-Type: application/json"])
	if _key.begins_with("eyJ"):  # legacy service_role JWT; new sb_secret_ keys go in apikey only
		headers.append("Authorization: Bearer " + _key)
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
