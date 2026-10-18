class_name Soundscape
extends Node
## The level's constant sound: the blizzard's wind and Jesper Kyd's score ("Winter & Night"
## while all is calm), both from the original bank.

const SOUNDS := "res://imported/sounds/"
const WIND_DB := -8.0

## The wind loop and its resting level; squalls raise it (`Blizzard`).
var wind: AudioStreamPlayer
var wind_db := WIND_DB


## The wind's own bus, with a low-pass filter that closes indoors.
var wind_filter: AudioEffectLowPassFilter


func _ready() -> void:
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "Wind")
	wind_filter = AudioEffectLowPassFilter.new()
	wind_filter.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(bus, wind_filter)
	wind = _loop("Wind_Snow_01.wav", WIND_DB)
	wind.bus = "Wind"
	_loop("Music_Winter_and_Night.ogg", -10.0)


## 0 outdoors … 1 deep indoors: the wind loses its hiss behind walls.
func muffle(amount: float) -> void:
	wind_filter.cutoff_hz = lerpf(20000.0, 450.0, pow(clampf(amount, 0.0, 1.0), 0.5))


func _loop(file: String, db: float) -> AudioStreamPlayer:
	var stream := load(SOUNDS + file) as AudioStream
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() / (2 if wav.format == AudioStreamWAV.FORMAT_16_BITS else 1) / (2 if wav.stereo else 1)
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = db
	player.autoplay = true
	add_child(player)
	return player
