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
		"invite", "photo_set", "photo_remove", "photo_get", "img_send", "img_get", "block", "unblock", "report",
		"report_msg", "link_start", "link_finish", "account_delete", "privacy", "join_friend", "join_answer", "host_answer", "invite_answer"]


func handle(c: Object, m: Dictionary) -> void:
	var t := str(m.get("t", ""))
	if t == "auth":
		await _auth(c, m)
		return
	if t == "link_finish":  # comes from the sign-in web page, not from the app
		await _link_finish(c, str(m.get("nonce", "")), str(m.get("access_token", "")))
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
		"report_msg":
			await _report_msg(c, int(m.get("id", 0)), str(m.get("reason", "")))
		"link_start":
			_link_start(c, str(m.get("nonce", "")))
		"account_delete":
			await _account_delete(c)
		"privacy":
			await _privacy(c, m)
		"join_friend":
			await _join_friend(c, str(m.get("id", "")))
		"join_answer":
			await _join_answer(c, str(m.get("from", "")), bool(m.get("accept", false)))
		"host_answer":
			_host_answer(c, str(m.get("from", "")), bool(m.get("accept", false)))
		"invite_answer":
			await _invite_answer(c, str(m.get("to", "")), bool(m.get("accept", false)))


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
	elif bool(p.get("banned", false)):
		_err(c, "banned")  # suspended by a moderator after reports
		return
	else:
		await store.update_player(id, profile.merged({"last_seen": Time.get_datetime_string_from_system(true) + "Z"}))
		p.merge(profile, true)
	if c.account != "" and c.account != id and online.get(c.account) == c:
		online.erase(c.account)  # this phone signed out and now uses another account
		await _tell_friends(c.account)
	c.show_online = bool(m.get("show_online", true))
	c.allow_join = bool(m.get("allow_join", true))
	c.profile = {"name": profile.name, "gender": profile.gender, "country": profile.country, "avatar": clampi(int(m.get("avatar", 0)), 0, 15)}
	c.account = id
	c.photo = str(p.get("photo", "")) if p.get("photo") != null else ""
	online[id] = c
	_send(c, {"t": "me", "id": id, "name": p.name, "tag": int(p.tag), "photo": c.photo, "persistent": store.persistent(),
		"google": str(p.get("google_id", "")) not in ["", "<null>"]})
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
		var status: String = others[p.id]
		var friend_client: Object = online.get(p.id) if status == "friend" else null
		if friend_client != null and not friend_client.show_online:
			friend_client = null  # appears offline (privacy); the room is never shown either
		var playing: bool = friend_client != null and friend_client.room_code != ""
		list.append({
			"id": p.id, "name": p.name, "gender": p.get("gender", ""), "country": p.get("country", ""), "tag": int(p.get("tag", 0)),
			"photo": _photo_of(p), "status": status,
			"online": friend_client != null,
			"state": "offline" if friend_client == null else ("playing" if playing else "available"),
			# how you can join them: "direct" (they allow it), "request" (they approve each time), "" = no
			"join": ("direct" if friend_client.allow_join else "request") if playing else "",
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
	if target == null or not target.show_online:
		_err(c, "friend_offline")
		return
	var room: Object = server.room_of(c)
	if room != null and not room.is_public and room.host_id != c.id:
		# private room: the host approves invitations sent by other players
		var host: Object = server.client(room.host_id)
		if host == null or host.account == "":
			_err(c, "need_host")
			return
		var tp: Dictionary = await store.get_player(to)
		_pending_invites[room.code + ":" + to] = c.account
		_send(host, {"t": "invite_ask", "from": _card(c), "to": {"id": to, "name": tp.get("name", "")}})
		_send(c, {"t": "invite_pending"})
		return
	_send(target, {"t": "invite", "code": c.room_code, "from": _card(c)})
	_send(c, {"t": "invite_sent"})


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
	if path == "" or bool(m.get("hidden", false)) or (m.get("sender") != c.account and m.get("receiver") != c.account):
		_send(c, {"t": "img", "id": id, "data": ""})
		return
	var bytes: PackedByteArray = await store.get_file(path)
	_send(c, {"t": "img", "id": id, "data": Marshalls.raw_to_base64(bytes) if not bytes.is_empty() else ""})


## Message as the app sees it: the storage path stays on the server, only "has an image" goes out.
static func _public_msg(row: Dictionary) -> Dictionary:
	var out := row.duplicate()
	out["image"] = row.get("image") != null and str(row.get("image", "")) != ""
	if bool(row.get("hidden", false)):  # reported: neither text nor picture is handed out any more
		out["body"] = ""
		out["image"] = false
		out["hidden"] = true
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

## Report one message or image you received: it is stored for the moderator together with the
## sender, and hidden for both of you at once (the image is no longer handed out to anyone).
func _report_msg(c: Object, id: int, reason: String) -> void:
	var m: Dictionary = await store.get_message(id) if id > 0 else {}
	if m.is_empty() or str(m.get("receiver", "")) != c.account:
		_err(c, "bad_target")
		return
	var image := str(m.get("image", "")) if m.get("image") != null else ""
	await store.add_report(c.account, str(m.sender), reason.strip_edges().left(REPORT_MAX), id, image)
	await store.hide_message(id)
	m["hidden"] = true
	var out := {"t": "msg_hidden", "id": id}
	_send(c, out)
	var sender: Object = online.get(str(m.sender))
	if sender != null:
		_send(sender, out)
	_send(c, {"t": "reported", "id": str(m.sender), "message": id})


# --- Google sign-in (links the device account to a Google account, or restores it on a new phone) ---
# 1. The app sends link_start with a random one-time code and opens the sign-in page in the browser.
# 2. The page signs in with Google through Supabase Auth and sends link_finish with that code and
#    its access token over its own WebSocket. 3. The server checks the token with Supabase.

const LINK_TTL_MS := 10 * 60 * 1000
var _links: Dictionary = {}  # one-time code -> {client, at}


func _link_start(c: Object, nonce: String) -> void:
	if nonce.length() < 32 or not nonce.is_valid_hex_number():
		_err(c, "bad_target")
		return
	var now := Time.get_ticks_msec()
	for k: String in _links.keys():  # forget old codes
		if now - int(_links[k].at) > LINK_TTL_MS:
			_links.erase(k)
	_links[nonce] = {"client": c, "at": now}


func _link_finish(page: Object, nonce: String, access_token: String) -> void:
	var link: Dictionary = _links.get(nonce, {})
	_links.erase(nonce)  # each code works once
	var app: Object = link.get("client")
	if link.is_empty() or Time.get_ticks_msec() - int(link.at) > LINK_TTL_MS or app == null or app.account == "":
		_send(page, {"t": "link_done", "ok": false, "code": "expired"})
		return
	var user: Dictionary = await store.auth_user(access_token)
	var gid := str(user.get("id", ""))
	if gid == "":
		_send(page, {"t": "link_done", "ok": false, "code": "auth_failed"})
		_send(app, {"t": "link_failed"})
		return
	var owner: Dictionary = await store.find_player_by_google(gid)
	if not owner.is_empty() and str(owner.id) != app.account:
		if bool(owner.get("banned", false)):
			_send(page, {"t": "link_done", "ok": false, "code": "banned"})
			_send(app, {"t": "link_failed", "code": "banned"})
			return
		# this Google account already has a game account: hand it to this phone with a new secret
		var secret := Crypto.new().generate_random_bytes(32).hex_encode()
		await store.update_player(str(owner.id), {"secret_hash": _hash(secret)})
		var old: Object = online.get(str(owner.id))
		if old != null and old != app:
			_err(old, "signed_in_elsewhere")
		_send(app, {"t": "account_restore", "account": str(owner.id), "secret": secret})
	else:
		await store.update_player(app.account, {"google_id": gid})
		_send(app, {"t": "linked"})
	_send(page, {"t": "link_done", "ok": true})


# --- account deletion (Google Play: in the app and on the website) ---

## Deletes the account for good: profile photos, the images this player sent, the account row with
## its friendships, messages, blocks and reports, and the Google sign-in record.
func _account_delete(c: Object) -> void:
	var id: String = c.account
	var p: Dictionary = await store.get_player(id)
	for path: String in await store.list_files("photos/%s/" % id):
		await store.delete_file(path)
	for path: String in await store.images_sent_by(id):
		await store.delete_file(path)
	var friends: Array = (await store.get_friendships(id)).map(func(f: Dictionary) -> String: return str(f.b if f.a == id else f.a))
	var ok: bool = await store.delete_player(id)
	if not ok:
		_err(c, "storage_error")
		return
	var gid := str(p.get("google_id", "")) if p.get("google_id") != null else ""
	await store.delete_auth_user(gid)
	online.erase(id)
	c.account = ""
	c.photo = ""
	_send(c, {"t": "account_deleted"})
	for other: String in friends:
		await _refresh(other)

# --- privacy, joining friends, approvals, blocked players in the same room ---

var _pending_invites: Dictionary = {}  # "<room code>:<invited account>" -> account of the friend who invited
var _join_requests: Dictionary = {}  # "<friend account>><requester account>" -> true (waiting for the friend)
var _host_requests: Dictionary = {}  # "<room code>:<requester account>" -> true (waiting for the host)


## Small public card of a signed-in player (invites, requests).
func _card(c: Object) -> Dictionary:
	return {"id": c.account, "name": c.profile.get("name", ""), "country": c.profile.get("country", ""), "gender": c.profile.get("gender", "")}


## "Show me as online" and "friends may join me" switches from the app.
func _privacy(c: Object, m: Dictionary) -> void:
	if m.has("show_online"):
		c.show_online = bool(m.show_online)
	if m.has("allow_join"):
		c.allow_join = bool(m.allow_join)
	await _tell_friends(c.account)


## "Join" next to a friend in the list. They must be a friend, online and visible, and in a room.
func _join_friend(c: Object, to: String) -> void:
	var friends: bool = await _are_friends(c.account, to)
	var target: Object = online.get(to)
	if not friends or target == null or not target.show_online or target.room_code == "":
		_err(c, "friend_unavailable")
		return
	if target.room_code == c.room_code:
		return
	if not target.allow_join:
		# they decide each time
		_join_requests[to + ">" + c.account] = true
		_send(target, {"t": "join_request", "from": _card(c)})
		_send(c, {"t": "join_requested"})
		return
	_try_join(c, target)


## The friend answers "X wants to join you".
func _join_answer(c: Object, from: String, accept: bool) -> void:
	var key: String = c.account + ">" + from
	if not _join_requests.has(key):
		return
	_join_requests.erase(key)
	var requester: Object = online.get(from)
	if requester == null:
		return
	if not accept:
		_err(requester, "join_declined")
		return
	_try_join(requester, c)


## Room checks shared by every way of joining a friend: full rooms say so, private rooms need their
## host (unless the friend is the host), a running game means waiting for the next round.
func _try_join(c: Object, friend: Object) -> void:
	var room: Object = server.room_of(friend)
	if room == null:
		_err(c, "friend_unavailable")
		return
	if room.seats_taken() >= room.max_players:
		_err(c, "room_full")
		return
	if not room.is_public and room.host_id != friend.id:
		var host: Object = server.client(room.host_id)
		if host == null:
			_err(c, "need_host")
			return
		_host_requests[room.code + ":" + c.account] = true
		_send(host, {"t": "join_ask_host", "from": _card(c), "via": friend.profile.get("name", "")})
		_send(c, {"t": "join_requested", "host": true})
		return
	server.join_room(c, room)


## The host of a private room answers "X (friend of Y) wants to join".
func _host_answer(c: Object, from: String, accept: bool) -> void:
	var room: Object = server.room_of(c)
	if room == null or room.host_id != c.id:
		return
	var key: String = room.code + ":" + from
	if not _host_requests.has(key):
		return
	_host_requests.erase(key)
	var requester: Object = online.get(from)
	if requester == null:
		return
	if not accept:
		_err(requester, "join_declined")
	elif room.seats_taken() >= room.max_players:
		_err(requester, "room_full")
	else:
		server.join_room(requester, room)


## The host of a private room answers "X wants to invite Y".
func _invite_answer(c: Object, to: String, accept: bool) -> void:
	var room: Object = server.room_of(c)
	if room == null or room.host_id != c.id:
		return
	var key: String = room.code + ":" + to
	var inviter_id: String = _pending_invites.get(key, "")
	if inviter_id == "":
		return
	_pending_invites.erase(key)
	var inviter: Object = online.get(inviter_id)
	if not accept:
		if inviter != null:
			_err(inviter, "invite_declined")
		return
	var target: Object = online.get(to)
	if target == null or not target.show_online:
		if inviter != null:
			_err(inviter, "friend_offline")
		return
	_send(target, {"t": "invite", "code": room.code, "from": _card(inviter) if inviter != null else _card(c)})
	if inviter != null:
		_send(inviter, {"t": "invite_sent"})


## Entering a room with someone you blocked (or who blocked you): only a notice to the one who
## blocked, who decides to stay or leave. Nothing is told to the blocked player.
func block_alert(c: Object, room: Object) -> void:
	if c.account == "":
		return
	var here := {}  # account -> [client, name]
	for p: Dictionary in room.players + room.waiting:
		var other: Object = server.client(str(p.id))
		if other != null and other != c and other.account != "":
			here[other.account] = [other, str(p.name)]
	if here.is_empty():
		return
	var mine: Array = await store.blocked_by(c.account)
	var names := []
	for acc: String in mine:
		if here.has(acc):
			names.append(here[acc][1])
	if not names.is_empty():
		_send(c, {"t": "blocked_here", "names": names})
	for acc: String in await store.blockers_of(c.account):
		if here.has(acc):
			_send(here[acc][0], {"t": "blocked_here", "names": [c.profile.get("name", "")]})