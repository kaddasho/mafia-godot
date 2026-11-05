extends Node
## Accounts, friends, private messages and room invites.
## A device keeps a permanent account id + secret; "auth" signs the connection in (creating the
## account the first time). Everything is stored through `store` (Supabase or memory).
##
## Client -> server: auth, friends, search, friend_request, friend_respond, friend_remove,
##                   msg_send, msg_history, invite, photo_set, photo_remove, photo_get,
##                   img_send, img_get, block, unblock, report
## Server -> client: me, friends, search, friend_req, friends_changed, msg, history, invite, photo, img
## Pictures (profile photos, chat images) live in the private storage bucket; the server checks who
## may see them and hands them over itself, so no picture is ever publicly reachable.

const MSG_MAX := 500
const MSG_GAP_MS := 400
const PHOTO_MAX := 200 * 1024  # bytes after decoding (the app sends ~256 px JPEGs)
const IMAGE_MAX := 600 * 1024  # bytes after decoding (the app sends <= 1024 px JPEGs)
const REPORT_MAX := 300
const HISTORY_PAGE := 30

var store: Node
var server: Node  # for _send(id, data) and the room of a client
var online: Dictionary = {}  # account id -> Client
var _last_msg: Dictionary = {}  # account id -> ms


func handles(t: String) -> bool:
	return t in ["auth", "friends", "search", "friend_request", "friend_respond", "friend_remove", "msg_send", "msg_history",
		"invite", "photo_set", "photo_remove", "photo_get", "img_send", "img_get", "block", "unblock", "report"]


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
			await _msg_send(c, str(m.get("to", "")), str(m.get("body", "")), str(m.get("ref", "")))
		"msg_history":
			await _history(c, str(m.get("with", "")), int(m.get("before", 0)))
		"photo_set":
			await _photo_set(c, str(m.get("data", "")))
		"photo_remove":
			await _photo_remove(c)
		"photo_get":
			await _photo_get(c, str(m.get("account", "")))
		"img_send":
			await _img_send(c, str(m.get("to", "")), str(m.get("data", "")), str(m.get("body", "")), str(m.get("ref", "")))
		"img_get":
			await _img_get(c, int(m.get("id", 0)))
		"block":
			await _block(c, str(m.get("id", "")), true)
		"unblock":
			await _block(c, str(m.get("id", "")), false)
		"report":
			await _report(c, str(m.get("id", "")), str(m.get("reason", "")))
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
	c.photo = str(p.get("photo", "")) if p.get("photo") != null else ""
	online[id] = c
	_send(c, {"t": "me", "id": id, "name": p.name, "tag": int(p.tag), "photo": c.photo, "persistent": store.persistent()})
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
			"photo": _photo_of(p), "status": status,
			"online": friend_client != null and status == "friend",
			"room": friend_client.room_code if friend_client != null and status == "friend" else "",
			"unread": int(unread.get(p.id, 0)),
		})
	# people you blocked, so you can unblock them
	var blocked_ids: Array = await store.blocked_by(me)
	var blocked := []
	for p: Dictionary in await store.get_players(blocked_ids):
		blocked.append({"id": p.id, "name": p.name, "gender": p.get("gender", ""), "country": p.get("country", ""), "tag": int(p.get("tag", 0))})
	_send(c, {"t": "friends", "list": list, "blocked": blocked})


func _search(c: Object, q: String) -> void:
	if q.length() < 2:
		_send(c, {"t": "search", "results": []})
		return
	var found: Array = await store.search_players(q)
	var mine: Array = await store.blocked_by(c.account)
	var results := []
	for p: Dictionary in found:
		if p.id != c.account and not mine.has(p.id):
			results.append({"id": p.id, "name": p.name, "gender": p.get("gender", ""), "country": p.get("country", ""), "tag": int(p.get("tag", 0)), "photo": _photo_of(p)})
	_send(c, {"t": "search", "results": results})


func _request(c: Object, to: String) -> void:
	var me: String = c.account
	var target_player: Dictionary = await store.get_player(to) if _valid_id(to) else {}
	if to == me or target_player.is_empty():
		_err(c, "bad_target")
		return
	var blocked: bool = await store.is_blocked(me, to)
	if blocked:
		_err(c, "blocked")
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


## Accepted friends who have not blocked each other: the only pairs that may message and share images.
func _are_friends(x: String, y: String) -> bool:
	var f: Dictionary = await store.get_friendship(x, y)
	if f.get("status", "") != "accepted":
		return false
	var blocked: bool = await store.is_blocked(x, y)
	return not blocked


# --- messages ---

func _msg_send(c: Object, to: String, body: String, ref: String = "") -> void:
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
	var out := {"t": "msg", "m": _public_msg(row)}
	_send(c, out.merged({"ref": ref}))  # the ref lets the app swap its "sending" copy for this one
	var target: Object = online.get(to)
	if target != null:
		_send(target, out)


## A page of the conversation: the latest messages, or the ones older than `before` (scrolling up).
func _history(c: Object, other: String, before: int = 0) -> void:
	var friends: bool = await _are_friends(c.account, other)
	if not friends:
		_err(c, "not_friends")
		return
	var msgs: Array = await store.get_messages(c.account, other, HISTORY_PAGE, before)
	if before <= 0:
		await store.mark_read(c.account, other)
		var them: Object = online.get(other)
		if them != null:
			_send(them, {"t": "msg_read", "by": c.account})  # their ticks turn to "read"
	_send(c, {"t": "history", "with": other, "messages": msgs.map(func(r: Dictionary) -> Dictionary: return _public_msg(r)), "before": before, "more": msgs.size() >= HISTORY_PAGE})


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


# --- pictures ---

static func _photo_of(p: Dictionary) -> String:
	return str(p.get("photo", "")) if p.get("photo") != null else ""


## Base64 text from the app -> image bytes, or empty if it is not a JPEG/PNG of acceptable size.
static func _decode_image(data: String, max_bytes: int) -> PackedByteArray:
	if data.length() > max_bytes * 4 / 3 + 8:
		return PackedByteArray()
	var bytes := Marshalls.base64_to_raw(data)
	if bytes.size() < 64 or bytes.size() > max_bytes:
		return PackedByteArray()
	var jpeg := bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF
	var png := bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47
	return bytes if jpeg or png else PackedByteArray()


static func _random_name() -> String:
	return Crypto.new().generate_random_bytes(8).hex_encode()


## Your own profile photo (only ever your own account: the path comes from the signed-in connection).
func _photo_set(c: Object, data: String) -> void:
	var bytes := _decode_image(data, PHOTO_MAX)
	if bytes.is_empty():
		_err(c, "bad_image")
		return
	var ver := _random_name()
	var ok: bool = await store.put_file("photos/%s/%s.jpg" % [c.account, ver], bytes)
	if not ok:
		_err(c, "upload_failed")
		return
	var old: String = c.photo
	await store.update_player(c.account, {"photo": ver})
	c.photo = ver
	if old != "":
		await store.delete_file("photos/%s/%s.jpg" % [c.account, old])
	await _photo_changed(c)


func _photo_remove(c: Object) -> void:
	if c.photo == "":
		return
	var old: String = c.photo
	await store.update_player(c.account, {"photo": ""})
	c.photo = ""
	await store.delete_file("photos/%s/%s.jpg" % [c.account, old])
	await _photo_changed(c)


func _photo_changed(c: Object) -> void:
	_send(c, {"t": "me_photo", "photo": c.photo})
	server.photo_changed(c)
	await _tell_friends(c.account)


## Profile photos are shown to everyone a player meets (rooms, search), so any signed-in player may
## fetch one - but only through the server, never by a public link.
func _photo_get(c: Object, account: String) -> void:
	if not _valid_id(account):
		return
	var p: Dictionary = await store.get_player(account)
	var ver := _photo_of(p)
	if ver == "":
		_send(c, {"t": "photo", "account": account, "ver": "", "data": ""})
		return
	var bytes: PackedByteArray = await store.get_file("photos/%s/%s.jpg" % [account, ver])
	_send(c, {"t": "photo", "account": account, "ver": ver, "data": Marshalls.raw_to_base64(bytes) if not bytes.is_empty() else ""})


## Image in a private chat: only between accepted friends (checked here, not only in the app).
## `ref` comes back with the result so the app can match it to its pending upload.
func _img_send(c: Object, to: String, data: String, body: String, ref: String) -> void:
	var me: String = c.account
	var friends: bool = await _are_friends(me, to)
	if not friends:
		_send(c, {"t": "img_failed", "ref": ref, "code": "not_friends"})
		return
	var bytes := _decode_image(data, IMAGE_MAX)
	if bytes.is_empty():
		_send(c, {"t": "img_failed", "ref": ref, "code": "bad_image"})
		return
	var ab: Array = store.pair(me, to)
	var path := "chat/%s_%s/%s.jpg" % [ab[0], ab[1], _random_name()]
	var ok: bool = await store.put_file(path, bytes)
	if not ok:
		_send(c, {"t": "img_failed", "ref": ref, "code": "upload_failed"})
		return
	var row: Dictionary = await store.add_message(me, to, body.strip_edges().left(MSG_MAX), path)
	var out := {"t": "msg", "m": _public_msg(row), "ref": ref}
	_send(c, out)
	var target: Object = online.get(to)
	if target != null:
		_send(target, {"t": "msg", "m": _public_msg(row)})


## Only the two people in that conversation can open its images.
func _img_get(c: Object, id: int) -> void:
	var m: Dictionary = await store.get_message(id)
	var path := str(m.get("image", "")) if m.get("image") != null else ""
	if path == "" or (m.get("sender") != c.account and m.get("receiver") != c.account):
		_send(c, {"t": "img", "id": id, "data": ""})
		return
	var bytes: PackedByteArray = await store.get_file(path)
	_send(c, {"t": "img", "id": id, "data": Marshalls.raw_to_base64(bytes) if not bytes.is_empty() else ""})


## Message as the app sees it: the storage path stays on the server, only "has an image" goes out.
static func _public_msg(row: Dictionary) -> Dictionary:
	var out := row.duplicate()
	out["image"] = row.get("image") != null and str(row.get("image", "")) != ""
	return out


# --- blocking and reports ---

## Blocking ends the friendship and stops requests, messages and images both ways.
func _block(c: Object, other: String, on: bool) -> void:
	if not _valid_id(other) or other == c.account:
		_err(c, "bad_target")
		return
	await store.set_block(c.account, other, on)
	if on:
		await store.delete_friendship(c.account, other)
	await _refresh(c.account)
	await _refresh(other)


func _report(c: Object, other: String, reason: String) -> void:
	if not _valid_id(other) or other == c.account:
		_err(c, "bad_target")
		return
	await store.add_report(c.account, other, reason.strip_edges().left(REPORT_MAX))
	_send(c, {"t": "reported", "id": other})