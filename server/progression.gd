extends RefCounted
## Player progression rules, decided on the server only (the app just shows them): XP and levels,
## competitive rank points (RP) with monthly seasons, achievements (normal, legendary, secret),
## unlockable frames and titles with rarities. A player's progress is one JSON value in the
## players table ("progress"):
##   {xp, rp, season, best_rank, hist: {season: rp}, rg: [recent groups], s: {stat: n},
##    a: [achievement ids], f: equipped frame, t: equipped title, g: last game id}
## The same ids are described for display in the app's progression.gd.

const XP_MATCH := 20
const XP_WIN := 30
const XP_SURVIVE := 10
const XP_FRIENDS := 5

## Ranked games: at least this many signed-in players and this many rounds, so two friends alone
## (or a game abandoned at once) cannot farm points.
const RANKED_MIN_PLAYERS := 5
const RANKED_MIN_ROUNDS := 2
const SAME_GROUP_WINDOW := 2 * 3600  # seconds: the same group again soon earns less (half, then nothing)

## Competitive rating (RP): Elo. Everyone starts at 1000; a game moves your RP by
## K * (result - expected), where "expected" comes from your team's average RP against the other
## team's. Beating stronger teams earns more, losing to weaker ones costs more. XP is separate.
const START_RP := 1000
const RATING_VERSION := 2  # progress saved before Elo (0-based points) is moved onto the 1000 scale once
const SEASON_MIN_GAMES := 10  # ranked games in a season before its final rank counts for season rewards

## id, minimum RP. Index 8 and up are the legendary ranks. New players start in Bronze (1000).
const RANKS := [
	["rookie", 0], ["bronze", 1000], ["silver", 1100], ["gold", 1200], ["platinum", 1300], ["diamond", 1400],
	["master", 1500], ["grandmaster", 1600],
	["crime_lord", 1700], ["underworld_legend", 1800], ["godfather", 1900], ["immortal_legend", 2000],
]
const LEGENDARY_RANK := 8

## id -> [stat, target, bonus xp, rarity, secret]
const ACHIEVEMENTS := {
	"first_win": ["wins", 1, 30, "common", false],
	"wins_10": ["wins", 10, 60, "uncommon", false],
	"wins_50": ["wins", 50, 150, "rare", false],
	"wins_100": ["wins", 100, 300, "legendary", false],
	"perfect_win": ["perfect", 1, 80, "rare", false],
	"mafia_kill": ["mafia_kills", 1, 30, "common", false],
	"last_mafia": ["last_mafia", 1, 100, "rare", false],
	"master_deceiver": ["deceiver", 1, 120, "epic", false],
	"first_check": ["correct_checks", 1, 30, "common", false],
	"find_mafia": ["detective_wins", 1, 60, "uncommon", false],
	"master_detective": ["correct_checks", 10, 150, "epic", false],
	"play_10": ["matches", 10, 40, "common", false],
	"play_100": ["matches", 100, 200, "rare", false],
	"invite_friends": ["invites", 5, 40, "uncommon", false],
	"friend_games": ["friend_games", 1, 30, "common", false],
	# legendary
	"perfect_crime": ["mafia_wins", 20, 250, "legendary", false],
	"master_manipulator": ["deceiver", 10, 300, "legendary", false],
	"untouchable": ["last_mafia", 10, 300, "legendary", false],
	"king_of_deception": ["mafia_wins", 50, 400, "legendary", false],
	"sherlocks_legacy": ["correct_checks", 50, 300, "legendary", false],
	"master_investigator": ["det_role_wins", 20, 300, "legendary", false],
	"no_escape": ["all_mafia_found", 10, 300, "legendary", false],
	"truth_seeker": ["correct_checks", 100, 400, "legendary", false],
	"last_survivor": ["last_standing", 10, 300, "legendary", false],
	"unbreakable": ["best_streak", 5, 250, "legendary", false],
	# secret: the app shows "???" until earned
	"hidden_identity": ["mafia_healed_win", 1, 150, "epic", true],
	"the_shadow": ["shadow_win", 1, 150, "epic", true],
	"final_verdict": ["all_roles", 1, 200, "legendary", true],
}

## Unlock rules: ["level", n], ["ach", id], ["rank", index reached at least once], ["all", "secret"]
## or ["all", rarity] (every achievement of that kind). id -> [rule, rarity]
const FRAMES := {
	"bronze": [["level", 2], "common"],
	"silver": [["level", 5], "uncommon"],
	"gold": [["level", 10], "rare"],
	"blood_red": [["ach", "last_mafia"], "rare"],
	"detective": [["ach", "master_detective"], "epic"],
	"mafia_boss": [["ach", "master_deceiver"], "epic"],
	"noir": [["level", 25], "epic"],
	"elite": [["rank", 4], "epic"],
	"crimson_godfather": [["ach", "king_of_deception"], "legendary"],
	"golden_empire": [["rank", 5], "legendary"],
	"brass_detective": [["ach", "sherlocks_legacy"], "legendary"],
	"bloodline": [["ach", "untouchable"], "legendary"],
	"shadow_king": [["ach", "master_manipulator"], "legendary"],
	"immortal": [["ach", "wins_100"], "legendary"],
	"underworld_crown": [["rank", 9], "legendary"],
	"last_don": [["rank", 10], "legendary"],
	"eternal_godfather": [["rank", 11], "mythic"],
	# season rewards: the final rank of a finished season (with at least SEASON_MIN_GAMES ranked games)
	"season_laurel": [["season", 3], "rare"],
	"season_star": [["season", 5], "epic"],
	"season_crown": [["season", 7], "legendary"],
	"phantom_legend": [["all", "secret"], "mythic"],
	"emperor_of_crime": [["all", "legendary"], "mythic"],
	# premium layered frames (1.5)
	"knight_shield": [["level", 15], "rare"],
	"pink_diamond": [["level", 30], "epic"],
	"sapphire_angel": [["level", 40], "epic"],
	"casino_don": [["ach", "play_100"], "legendary"],
	"emerald_serpents": [["ach", "wins_50"], "legendary"],
	"ice_king": [["rank", 6], "epic"],
	"eternal_sun": [["level", 50], "legendary"],
	"crimson_devil": [["rank", 7], "legendary"],
	"royal_crown": [["rank", 8], "legendary"],
	"fire_throne": [["season", 9], "mythic"],
	"violet_galaxy": [["level", 75], "mythic"],
	"rainbow_legend": [["level", 100], "mythic"],
	# second premium set: one every few levels, rare first, mythic last
	"lightning": [["level", 8], "rare"],
	"violet_night": [["level", 12], "epic"],
	"royal_ice": [["level", 18], "epic"],
	"eye_of_truth": [["level", 22], "epic"],
	"rose_gold": [["level", 27], "epic"],
	"golden_don": [["level", 33], "legendary"],
	"black_emerald": [["level", 38], "legendary"],
	"black_rose": [["level", 44], "legendary"],
	"dark_knight": [["level", 55], "legendary"],
	"mafia_king": [["level", 60], "legendary"],
	"hellfire": [["level", 70], "mythic"],
	"eternal_legend": [["level", 90], "mythic"],
}

const TITLES := {
	"beginner": [["level", 1], "common"],
	"street_suspect": [["level", 3], "common"],
	"informant": [["ach", "first_check"], "uncommon"],
	"private_detective": [["ach", "find_mafia"], "uncommon"],
	"shadow_hunter": [["level", 12], "rare"],
	"mafia_associate": [["ach", "mafia_kill"], "uncommon"],
	"crime_lord": [["level", 20], "rare"],
	"godfather": [["ach", "wins_50"], "epic"],
	"mastermind": [["ach", "master_deceiver"], "epic"],
	"legendary_survivor": [["ach", "perfect_win"], "rare"],
	"king_of_shadows": [["ach", "master_manipulator"], "legendary"],
	"the_untouchable": [["ach", "untouchable"], "legendary"],
	"master_of_deception": [["ach", "king_of_deception"], "legendary"],
	"legendary_detective": [["ach", "sherlocks_legacy"], "legendary"],
	"the_last_don": [["rank", 10], "legendary"],
	"emperor_underworld": [["rank", 9], "legendary"],
	"eternal_godfather": [["rank", 11], "mythic"],
	"season_contender": [["season", 3], "rare"],
	"season_champion": [["season", 7], "legendary"],
	"the_immortal": [["ach", "wins_100"], "legendary"],
}


## XP needed to go from `level` to the next one: grows with every level.
static func xp_for(level: int) -> int:
	return 100 + 50 * (level - 1)


## [level, xp gathered inside this level, xp needed for the next level]
static func level_of(xp: int) -> Array:
	var level := 1
	var left := maxi(0, xp)
	while left >= xp_for(level):
		left -= xp_for(level)
		level += 1
	return [level, left, xp_for(level)]


static func rank_of(rp: int) -> int:
	var idx := 0
	for i in RANKS.size():
		if rp >= int(RANKS[i][1]):
			idx = i
	return idx


## Seasons run by calendar month (UTC): "2026-11".
static func season_now() -> String:
	var d := Time.get_datetime_dict_from_system(true)
	return "%04d-%02d" % [d.year, d.month]


static func clean(raw: Variant) -> Dictionary:
	var p: Dictionary = raw.duplicate(true) if raw is Dictionary else {}
	p["xp"] = int(p.get("xp", 0))
	var had_points := p.has("rp")
	p["rp"] = int(p.get("rp", START_RP))
	p["best_rank"] = int(p.get("best_rank", 0))
	if not p.get("s") is Dictionary:
		p["s"] = {}
	if not p.get("a") is Array:
		p["a"] = []
	if not p.get("hist") is Dictionary:
		p["hist"] = {}
	if not p.get("rg") is Array:
		p["rg"] = []
	p["f"] = str(p.get("f", ""))
	p["t"] = str(p.get("t", ""))
	p["g"] = str(p.get("g", ""))
	p["sg"] = int(p.get("sg", 0))  # ranked games this season
	p["rk"] = int(p.get("rk", 0))  # ranked games ever
	if int(p.get("rv", 0)) < RATING_VERSION:
		# saved before Elo: old points (from 0) become a head start on the 1000 scale, nothing is lost
		p.rp = START_RP + int(p.rp) if had_points else START_RP
		p["rv"] = RATING_VERSION
		p.best_rank = maxi(rank_of(p.rp), 0)
	# a new season: the old one is kept in the history (final RP and games played), the rating moves
	# halfway back to 1000 (soft reset)
	var now := season_now()
	var season := str(p.get("season", ""))
	if season != now:
		if season != "":
			p.hist[season] = {"rp": p.rp, "g": p.sg}
			p.rp = START_RP + int((p.rp - START_RP) / 2)
		p["season"] = now
		p.sg = 0
	return p


## Best final rank of a finished season the player really played (SEASON_MIN_GAMES ranked games).
static func best_season_rank(p: Dictionary) -> int:
	var best := -1
	for key: String in p.hist:
		var h: Variant = p.hist[key]
		if h is Dictionary and int(h.get("g", 0)) >= SEASON_MIN_GAMES:
			best = maxi(best, rank_of(int(h.get("rp", 0))))
	return best


static func _unlocked(rule: Array, p: Dictionary) -> bool:
	match str(rule[0]):
		"level":
			return int(level_of(p.xp)[0]) >= int(rule[1])
		"ach":
			return p.a.has(rule[1])
		"rank":
			return int(p.best_rank) >= int(rule[1])
		"season":
			return best_season_rank(p) >= int(rule[1])
		"all":
			for id: String in ACHIEVEMENTS:
				var def: Array = ACHIEVEMENTS[id]
				var in_group: bool = bool(def[4]) if rule[1] == "secret" else def[3] == rule[1]
				if in_group and not p.a.has(id):
					return false
			return true
	return false


static func frames_of(p: Dictionary) -> Array:
	return FRAMES.keys().filter(func(id: String) -> bool: return _unlocked(FRAMES[id][0], p))


static func titles_of(p: Dictionary) -> Array:
	return TITLES.keys().filter(func(id: String) -> bool: return _unlocked(TITLES[id][0], p))


## Adds the achievements whose stat reached its target (each only once) and their bonus XP.
## Returns the new ids.
static func check_achievements(p: Dictionary) -> Array:
	var new := []
	for id: String in ACHIEVEMENTS:
		if p.a.has(id):
			continue
		var rule: Array = ACHIEVEMENTS[id]
		if int(p.s.get(rule[0], 0)) >= int(rule[1]):
			p.a.append(id)
			p.xp += int(rule[2])
			new.append(id)
	return new


static func _inc(s: Dictionary, key: String, n: int = 1) -> void:
	s[key] = int(s.get(key, 0)) + n


## One finished game for one player. `r` = {role, won, survived, team_all_alive, kills,
## voted_against, correct_checks, all_mafia_found, last_mafia, last_standing, healed,
## big_game, friend_in_game}. Returns the XP earned for the game itself.
static func add_game(p: Dictionary, r: Dictionary) -> int:
	var s: Dictionary = p.s
	var won := bool(r.get("won", false))
	var role := str(r.get("role", ""))
	var mafia := role == "mafia"
	_inc(s, "matches")
	_inc(s, "wins" if won else "losses")
	s["streak"] = int(s.get("streak", 0)) + 1 if won else 0
	s["best_streak"] = maxi(int(s.get("best_streak", 0)), int(s.streak))
	if won:
		_inc(s, "won_as_" + role)
		if ["mafia", "detective", "doctor", "citizen"].all(func(x: String) -> bool: return int(s.get("won_as_" + x, 0)) > 0):
			s["all_roles"] = 1
		if bool(r.get("team_all_alive", false)):
			_inc(s, "perfect")
		if bool(r.get("last_standing", false)):
			_inc(s, "last_standing")
	if mafia:
		_inc(s, "mafia_kills", int(r.get("kills", 0)))
		if won:
			_inc(s, "mafia_wins")
			if bool(r.get("last_mafia", false)):
				_inc(s, "last_mafia")
			if bool(r.get("survived", false)) and int(r.get("voted_against", 0)) == 0:
				_inc(s, "deceiver")
			if bool(r.get("healed", false)):
				_inc(s, "mafia_healed_win")  # secret: the doctor protected you, the mafia, and you won
	if role == "detective" and won:
		_inc(s, "det_role_wins")
	var checks := int(r.get("correct_checks", 0))
	if checks > 0:
		_inc(s, "correct_checks", checks)
		if won:
			_inc(s, "detective_wins")
	if bool(r.get("all_mafia_found", false)):
		_inc(s, "all_mafia_found")
	if won and role == "citizen" and bool(r.get("survived", false)) and int(r.get("voted_against", 0)) == 0 \
			and bool(r.get("big_game", false)):
		_inc(s, "shadow_win")  # secret: a citizen nobody ever suspected, in a big game
	if bool(r.get("friend_in_game", false)):
		_inc(s, "friend_games")
	var xp := XP_MATCH + (XP_WIN if won else 0) + (XP_SURVIVE if bool(r.get("survived", false)) else 0) \
		+ (XP_FRIENDS if bool(r.get("friend_in_game", false)) else 0)
	p.xp += xp
	return xp


## Elo step size: bigger for the first games (finds your level quickly), smaller at the top.
static func k_factor(p: Dictionary) -> float:
	if int(p.rk) < 10:
		return 40.0
	if int(p.rp) >= int(RANKS[LEGENDARY_RANK][1]):
		return 20.0
	return 28.0


## Expected result (0..1) for a team with average rating `mine` against one with `theirs`.
static func expected(mine: float, theirs: float) -> float:
	return 1.0 / (1.0 + pow(10.0, (theirs - mine) / 400.0))


## Rating change for one ranked game: Elo against the other team's average RP (`team_rp` = your
## team's average, `opp_rp` = theirs, both measured before the game). Only the result counts - no
## points for kills, chat or anything else that could be farmed. Unranked when the game is too small
## or too short; the same group playing again within two hours gains half, then nothing (losses
## still count). Returns {delta, ranked, reason, before, after, rp}.
static func rank_game(p: Dictionary, r: Dictionary, group: Array, players: int, rounds: int, team_rp: float = -1.0, opp_rp: float = -1.0) -> Dictionary:
	var before := rank_of(p.rp)
	if players < RANKED_MIN_PLAYERS or rounds < RANKED_MIN_ROUNDS:
		return {"delta": 0, "ranked": false, "reason": "too_small" if players < RANKED_MIN_PLAYERS else "too_short", "before": before, "after": before, "rp": p.rp}
	if team_rp < 0.0:
		team_rp = p.rp
	if opp_rp < 0.0:
		opp_rp = p.rp
	var key := ",".join(group)
	var now := int(Time.get_unix_time_from_system())
	p.rg = p.rg.filter(func(g: Dictionary) -> bool: return now - int(g.get("t", 0)) < SAME_GROUP_WINDOW)
	var repeats: int = p.rg.filter(func(g: Dictionary) -> bool: return str(g.get("h", "")) == key.sha256_text()).size()
	p.rg.append({"h": key.sha256_text(), "t": now})
	while p.rg.size() > 8:
		p.rg.pop_front()
	var won := bool(r.get("won", false))
	var delta := int(round(k_factor(p) * ((1.0 if won else 0.0) - expected(team_rp, opp_rp))))
	if won:
		delta = maxi(delta, 1)  # a win never costs points
	var reason := ""
	if repeats == 1 and delta > 0:
		delta = int(delta / 2)
		reason = "same_group"
	elif repeats >= 2 and delta > 0:
		delta = 0
		reason = "same_group"
	p.rp = maxi(0, p.rp + delta)
	p.rk = int(p.rk) + 1
	p.sg = int(p.sg) + 1
	var after := rank_of(p.rp)
	p.best_rank = maxi(int(p.best_rank), after)
	return {"delta": delta, "ranked": true, "reason": reason, "before": before, "after": after, "rp": p.rp}

## What the app gets: level and XP bar, rank and RP bar, stats, achievements, unlocked / equipped.
static func summary(p: Dictionary) -> Dictionary:
	var lv := level_of(p.xp)
	var frame: String = p.f if frames_of(p).has(p.f) else ""
	var title: String = p.t if titles_of(p).has(p.t) else ""
	var rank := rank_of(p.rp)
	var next_rp: int = int(RANKS[rank + 1][1]) if rank + 1 < RANKS.size() else -1
	return {"xp": p.xp, "level": lv[0], "xp_in": lv[1], "xp_need": lv[2], "stats": p.s, "achievements": p.a,
		"frames": frames_of(p), "titles": titles_of(p), "frame": frame, "title": title,
		"rp": p.rp, "rank": rank, "rank_min": int(RANKS[rank][1]), "rank_next": next_rp, "best_rank": p.best_rank,
		"season": p.season, "hist": p.hist, "season_games": p.sg, "ranked_games": p.rk, "best_season": best_season_rank(p)}
