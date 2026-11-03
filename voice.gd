extends Node
## Autoload "Voice": open-mic voice chat over the game connection.
## The mic is cut down to 12 kHz mono and sent as 8-bit mu-law, but only while you are actually
## talking (a simple level gate), so silence costs nothing. The server decides who hears whom;
## each speaker plays through their own audio generator.

signal mute_changed

const RATE := 12000
const CHUNK := 720  # samples per packet (60 ms)
const GATE_LEVEL := 0.015  # loudness (RMS) that counts as talking
const HANGOVER := 0.4  # keep sending this long after you go quiet, so word endings aren't cut
const SPEAKING_FOR := 0.3  # someone shows as talking this long after their last packet
const MIX_RATE_CUSTOM := 2  # AudioStreamGenerator.mix_rate_mode

var muted: bool = false

var _mic: AudioStreamPlayer
var _capture: AudioEffectCapture
var _step: float = 1.0
var _phase: float = 0.0
var _acc: float = 0.0
var _acc_n: int = 0
var _pending := PackedFloat32Array()
var _open_until: float = 0.0
var _self_heard: float = -10.0
var _speakers: Dictionary = {}  # id -> {player, playback, heard}
var _decode := PackedFloat32Array()


func _ready() -> void:
	for u in 256:
		_decode.append(_mulaw_decode(u))
	Net.voice.connect(_on_voice)
	Net.message.connect(_on_message)
	if OS.get_name() == "Android":
		get_tree().on_request_permissions_result.connect(_on_permission)
		OS.request_permissions()


## Android asks for the mic at runtime; restart a mic that started before it was allowed.
func _on_permission(permission: String, granted: bool) -> void:
	if granted and permission.ends_with("RECORD_AUDIO") and _mic != null and _mic.playing:
		_mic.stop()
		_mic.play()


func toggle_mute() -> void:
	muted = not muted
	mute_changed.emit()


## Mirrors the server's rule: in lobby / end anyone talks; in a game only the living,
## and at night only the mafia (to each other).
func can_talk() -> bool:
	var phase := str(Net.room.get("phase", "lobby"))
	if phase in ["night", "day", "vote"]:
		var me: Dictionary = Net.room.get("you", {})
		if not bool(me.get("alive", true)):
			return false
		if phase == "night":
			return Net.my_role == "mafia"
	return true


func mic_text() -> String:
	if muted:
		return Loc.t("mic_off")
	if not can_talk():
		return Loc.t("mic_not_now")
	if str(Net.room.get("phase", "")) == "night":
		return Loc.t("mic_mafia")
	return Loc.t("mic_on")


func is_speaking(id: String) -> bool:
	if id == Net.my_id:
		return _now() - _self_heard < SPEAKING_FOR
	var s: Dictionary = _speakers.get(id, {})
	return not s.is_empty() and _now() - float(s.heard) < SPEAKING_FOR


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


# --- capture & send ---

func _make_mic() -> void:
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "VoiceMic")
	AudioServer.set_bus_mute(bus, true)  # captured, never played back locally
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = 0.5
	AudioServer.add_bus_effect(bus, _capture)
	_mic = AudioStreamPlayer.new()
	_mic.stream = AudioStreamMicrophone.new()
	_mic.bus = "VoiceMic"
	add_child(_mic)
	_step = AudioServer.get_mix_rate() / RATE


func _process(_delta: float) -> void:
	# The mic only runs while you are in a room and not muted.
	var want_mic := not Net.room.is_empty() and not muted
	if want_mic and _mic == null:
		_make_mic()
	if _mic == null:
		return
	if want_mic != _mic.playing:
		if want_mic:
			_capture.clear_buffer()
			_mic.play()
		else:
			_mic.stop()
	var frames := _capture.get_frames_available()
	if frames <= 0:
		return
	var buf := _capture.get_buffer(frames)
	if not want_mic or not Net.connected or not can_talk():
		_pending.clear()
		return
	for f in buf:
		_acc += (f.x + f.y) * 0.5
		_acc_n += 1
		_phase += 1.0
		if _phase >= _step:
			_phase -= _step
			_pending.append(_acc / _acc_n)
			_acc = 0.0
			_acc_n = 0
	while _pending.size() >= CHUNK:
		_send_chunk(_pending.slice(0, CHUNK))
		_pending = _pending.slice(CHUNK)


func _send_chunk(chunk: PackedFloat32Array) -> void:
	var sum := 0.0
	for s in chunk:
		sum += s * s
	var now := _now()
	if sqrt(sum / chunk.size()) >= GATE_LEVEL:
		_open_until = now + HANGOVER
	if now > _open_until:
		return
	var bytes := PackedByteArray()
	bytes.resize(chunk.size())
	for i in chunk.size():
		bytes[i] = _mulaw_encode(chunk[i])
	Net.send_voice(bytes)
	_self_heard = now


# --- receive & play ---

func _on_voice(speaker: String, audio: PackedByteArray) -> void:
	var s: Dictionary = _speakers.get(speaker, {})
	if s.is_empty():
		var gen := AudioStreamGenerator.new()
		if "mix_rate_mode" in gen:
			gen.set("mix_rate_mode", MIX_RATE_CUSTOM)
		gen.mix_rate = RATE
		gen.buffer_length = 0.5
		var player := AudioStreamPlayer.new()
		player.stream = gen
		add_child(player)
		player.play()
		s = {"player": player, "playback": player.get_stream_playback(), "heard": 0.0}
		_speakers[speaker] = s
	var frames := PackedVector2Array()
	frames.resize(audio.size())
	for i in audio.size():
		var v := _decode[audio[i]]
		frames[i] = Vector2(v, v)
	var playback: AudioStreamGeneratorPlayback = s.playback
	if playback.can_push_buffer(frames.size()):
		playback.push_buffer(frames)
	s.heard = _now()


func _on_message(m: Dictionary) -> void:
	if str(m.get("t", "")) == "left":
		for s: Dictionary in _speakers.values():
			(s.player as Node).queue_free()
		_speakers.clear()


# --- G.711 mu-law (8 bits per sample) ---

static func _mulaw_encode(sample: float) -> int:
	var s := clampi(int(sample * 32767.0), -32767, 32767)
	var sgn := 0
	if s < 0:
		s = -s
		sgn = 0x80
	s = mini(s, 32635) + 0x84
	var exponent := 7
	var mask := 0x4000
	while exponent > 0 and (s & mask) == 0:
		exponent -= 1
		mask >>= 1
	var mantissa := (s >> (exponent + 3)) & 0x0F
	return ~(sgn | (exponent << 4) | mantissa) & 0xFF


static func _mulaw_decode(u: int) -> float:
	u = ~u & 0xFF
	var exponent := (u >> 4) & 0x07
	var sample := (((u & 0x0F) << 3) + 0x84) << exponent
	sample -= 0x84
	return (-sample if u & 0x80 else sample) / 32768.0
