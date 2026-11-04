extends Node
## Accounts, friends, private messages and room invites.
## A device keeps a permanent account id + secret; "auth" signs the connection in (creating the
## account the first time). Everything is stored through `store` (Supabase or memory).
##
## Client -> server: auth, friends, search, friend_request, friend_respond, friend_remove,
##                   msg_send, msg_history, invite
## Server -> client: me, friends, search, friend_req, friends_changed, msg, history, invite

const MSG_MAX := 500
const MSG_GAP_MS := 400

var store: Node
var server: Node  # for _send(id, data) and the room of a client
var online: Dictionary = {}  # account id -> Client
var _last_msg: Dictionary = {}  # account id -> ms


func handles(t: String) -> bool:
	return t in ["auth", "friends", "search", "friend_request", "friend_respond", "friend_remove", "msg_send", "msg_history", "invite"]


func handle(c: Object, m: Dictionary) -> void:
	var t := str(m.get("t", ""))
	if t == "auth":
		await _auth(c, m)
		return
	if c.account == "":
		_err(c, "not_signed_in")
		return
	match t:
		"friends":
			await send_friends(c)
		"search":
			await _search(c, str(m.get("q", "")).strip_edges().left(30))
		"friend_request":
			await _request(c, str(m.get("to", "")))
		"friend_respond":
			await _respond(c, str(m.get("from", "")), bool(m.get("accept", false)))
		"friend_remove":
			await _remove(c, str(m.get("id", "")))
		"msg_send":
			await _msg_send(c, str(m.get("to", "")), str(m.get("body", "")))
		"msg_history":
			await _history(c, str(m.get("with", "")))
		"invite":
			await _invite(c, str(m.get("to", "")))


## Called by the server when a connection closes.
func signed_out(c: Object) -> void:
	if c.account != "" and online.get(c.account) == c:
		online.erase(c.account)
		await _tell_friends(c.account)


func _send(c: Object, data: Dictionary) -> void:
	server._send(c.id, data)


func _err(c: Object, code: String) -> void:
	_send(c, {"t": "error", "code": code})


static func _valid_id(s: String) -> bool:
	return s.length() == 36 and s.count("-") == 4 and s.replace("-", "").is_valid_hex_number()


static func _hash(secret: String) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(secret.to_utf8_buffer())
	return h.finish().hex_encode()


# --- account ---

func _auth(c: Object, m: Dictionary) -> void:
	var id := str(m.get("account", "")).to_lower()
	var secret := str(m.get("secret", ""))
	if not _valid_id(id) or secret.length() < 32:
		_err(c, "auth_failed")
		return
	var profile := {
		"name": str(m.get("name", "")).strip_edges().left(20),
		"gender": str(m.get("gender", "")) if str(m.get("gender", "")) in ["m", "f"] else "",
		"country": str(m.get("country", "")).to_lower().left(2),
	}
	if profile.name == "":
		profile.name = "Player"
	var p: Dictionary = await store.get_player(id)
	if p.is_empty():
		p = profile.duplicate()
		p.merge({"id": id, "secret_hash": _hash(secret), "tag": randi_range(1000, 9999)})
		p = await store.create_player(p)
		if p.is_empty():
			_err(c, "storage_error")
			return
	elif p.secret_hash != _hash(secret):
		_err(c, "auth_failed")
		return
	else:
		await store.update_player(id, profile.merged({"last_seen": Time.get_datetime_string_from_system(true) + "Z"}))
		p.merge(profile, true)
	c.account = id
	online[id] = c
	_send(c, {"t": "me", "id": id, "name": p.name, "tag": int(p.tag), "persistent": store.persistent()})
	await send_friends(c)
	await _tell_friends(id)


# --- friends ---

## Friend list with requests both ways, online state, room and unread count.
func send_friends(c: Object) -> void:
	var me: String = c.account
	var links: Array = await store.get_friendships(me)
	var others := {}
	for f: Dictionary in links:
		var other: String = f.b if f.a == me else f.a
		var status := "friend" if f.status == "accepted" else ("outgoing" if f.requester == me else "incoming")
		others[other] = status
	var people: Array = await store.get_players(others.keys())
	var unread: Dictionary = await store.unread_counts(me)
	var list := []
	for p: Dictionary in people:
		var friend_client: Object = online.get(p.id)
		var status: String = others[p.id]
		list.append({
			"id": p.id, "name": p.name, "gender": p.get("gender", ""), "country": p.get("country", ""), "tag": int(p.get("tag", 0)),
			"status": status,
			"online": friend_client != null and status == "friend",
			"room": friend_client.room_code if friend_client != null and status == "friend" else "",
			"unread": int(unread.get(p.id, 0)),
		})
	_send(c, {"t": "friends", "list": list})


func _search(c: Object, q: String) -> void:
	if q.length() < 2:
		_send(c, {"t": "search", "results": []})
		return
	var found: Array = await store.search_players(q)
	var results := []
	for p: Dictionary in found:
		if p.id != c.account:
			results.append({"id": p.id, "name": p.name, "gender": p.get("gender", ""), "country": p.get("country", ""), "tag": int(p.get("tag", 0))})
	_send(c, {"t": "search", "results": results})


func _request(c: Object, to: String) -> void:
	var me: String = c.account
	var target_player: Dictionary = await store.get_player(to) if _valid_id(to) else {}
	if to == me or target_player.is_empty():
		_err(c, "bad_target")
		return
	var f: Dictionary = await store.get_friendship(me, to)
	if f.get("status", "") == "accepted":
		return
	if f.get("status", "") == "pending" and f.requester == to:
		await store.set_friendship(me, to, "accepted", to)  # they had asked us: that's a yes
	else:
		await store.set_friendship(me, to, "pending", me)
		var target: Object = online.get(to)
		if target != null:
			var p: Dictionary = await store.get_player(me)
			_send(target, {"t": "friend_req", "from": {"id": me, "name": p.get("name", ""), "country": p.get("country", ""), "gender": p.get("gender", "")}})
	await _refresh(me)
	await _refresh(to)


func _respond(c: Object, from: String, accept: bool) -> void:
	var me: String = c.account
	var f: Dictionary = await store.get_friendship(me, from)
	if f.get("status", "") != "pending" or f.requester != from:
		_err(c, "bad_target")
		return
	if accept:
		await store.set_friendship(me, from, "accepted", from)
	else:
		await store.delete_friendship(me, from)
	await _refresh(me)
	await _refresh(from)


func _remove(c: Object, other: String) -> void:
	await store.delete_friendship(c.account, other)
	await _refresh(c.account)
	await _refresh(other)


func _are_friends(x: String, y: String) -> bool:
	var f: Dictionary = await store.get_friendship(x, y)
	return f.get("status", "") == "accepted"


# --- messages ---

func _msg_send(c: Object, to: String, body: String) -> void:
	var me: String = c.account
	body = body.strip_edges().left(MSG_MAX)
	if body == "":
		return
	var friends: bool = await _are_friends(me, to)
	if not friends:
		_err(c, "not_friends")
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_msg.get(me, -100000)) < MSG_GAP_MS:
		return
	_last_msg[me] = now
	var row: Dictionary = await store.add_message(me, to, body)
	var out := {"t": "msg", "m": row}
	_send(c, out)
	var target: Object = online.get(to)
	if target != null:
		_send(target, out)


func _history(c: Object, other: String) -> void:
	var friends: bool = await _are_friends(c.account, other)
	if not friends:
		_err(c, "not_friends")
		return
	var msgs: Array = await store.get_messages(c.account, other)
	await store.mark_read(c.account, other)
	_send(c, {"t": "history", "with": other, "messages": msgs})


## Room invite to an online friend: they get the room code and can join with one tap.
func _invite(c: Object, to: String) -> void:
	if c.room_code == "":
		_err(c, "not_in_room")
		return
	var friends: bool = await _are_friends(c.account, to)
	if not friends:
		_err(c, "not_friends")
		return
	var target: Object = online.get(to)
	if target == null:
		_err(c, "friend_offline")
		return
	var p: Dictionary = await store.get_player(c.account)
	_send(target, {"t": "invite", "code": c.room_code,
		"from": {"id": c.account, "name": p.get("name", ""), "country": p.get("country", ""), "gender": p.get("gender", "")}})


# --- pushing changes ---

## Fresh friend list to this account if it is online.
func _refresh(account: String) -> void:
	var c: Object = online.get(account)
	if c != null:
		await send_friends(c)


## Online friends of `account` get a fresh list (someone came online / went offline).
func _tell_friends(account: String) -> void:
	var links: Array = await store.get_friendships(account)
	for f: Dictionary in links:
		if f.status == "accepted":
			await _refresh(f.b if f.a == account else f.a)


## A friend's room changed (joined / left a room): their friends' lists show it.
func room_changed(c: Object) -> void:
	if c.account != "":
		await _tell_friends(c.account)
