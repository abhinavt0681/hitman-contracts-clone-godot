class_name Mission
extends Node
## The mission loop: plant explosives at the submarine's three bomb points (the level's own
## `Box_01..03` triggers on its deck), then return to the AN-124 (`Exitbox`, in its hold).
## Seen by a guard, the mission fails; R restarts.
##
## (A simplification of the original's objectives until weapons, disguises and Bjarkhov come.)

const MARKERS := "res://imported/level/C02-1_markers.json"
const BOMBS := ["Box_01", "Box_02", "Box_03"]
const PLANT_REACH := 2.2
const PLANT_SECONDS := 2.0
const EXIT_REACH := 3.5

var player: Player
var bombs: Array[Vector3] = []
var planted: Array[bool] = []
var exit_at := Vector3.ZERO
var planting := -1
var plant_t := 0.0
var over := false
var clock := 0.0
var objectives: Label
var meter: ProgressBar
var banner: Label
var guards: Array = []


func _ready() -> void:
	for m: Dictionary in JSON.parse_string(FileAccess.get_file_as_string(MARKERS)):
		if m.get("template", false) or m["type"] != "0x2000e1":
			continue
		var p := Vector3(m["pos"][0], m["pos"][1], m["pos"][2])
		if BOMBS.has(m["name"]):
			bombs.append(p)
			planted.append(false)
		elif m["name"] == "Exitbox":
			exit_at = p
	_ui()
	await get_tree().process_frame
	player = get_parent().get_node("Player") as Player
	var actors := get_parent().find_child("Actors", false, false) as Actors
	if actors:
		guards = actors.guards
		for g: Guard in guards:
			g.spotted.connect(_spotted)
	print("mission: %d bomb points, exit at %s" % [bombs.size(), exit_at])


func _ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var font := load("res://fonts/Michroma-Regular.ttf")
	objectives = Label.new()
	objectives.add_theme_font_override("font", font)
	objectives.add_theme_font_size_override("font_size", 15)
	objectives.add_theme_color_override("font_color", Color(0.85, 0.9, 0.92, 0.85))
	objectives.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	objectives.position = Vector2(28, 24)
	layer.add_child(objectives)
	# How close the most suspicious guard is to raising the alarm.
	meter = ProgressBar.new()
	meter.show_percentage = false
	meter.max_value = 1.0
	meter.custom_minimum_size = Vector2(220, 8)
	meter.position = Vector2(28, 130)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.85, 0.2, 0.15)
	meter.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.4)
	meter.add_theme_stylebox_override("background", bg)
	layer.add_child(meter)
	banner = Label.new()
	banner.add_theme_font_override("font", font)
	banner.add_theme_font_size_override("font_size", 34)
	banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	banner.offset_left = -600
	banner.offset_right = 600
	banner.visible = false
	layer.add_child(banner)


func _physics_process(dt: float) -> void:
	if player == null:
		return
	if over:
		if Input.is_physical_key_pressed(KEY_R):
			get_tree().reload_current_scene()
		return
	clock += dt
	var count := planted.count(true)
	var lines := "OBJECTIVES\n%s  Plant the explosives on the submarine (%d/3)\n%s  Escape on the AN-124" % ["■" if count == 3 else "□", count, "□"]
	objectives.text = lines
	var worst := 0.0
	for g: Guard in guards:
		worst = maxf(worst, g.suspicion)
	meter.value = worst
	meter.visible = worst > 0.01
	# Planting: E within reach of an unplanted bomb point, then hold still for a moment.
	if planting >= 0:
		plant_t += dt
		player.prompt = "Planting…  %d%%" % int(100.0 * plant_t / PLANT_SECONDS)
		if player.global_position.distance_to(bombs[planting]) > PLANT_REACH + 0.5:
			planting = -1
		elif plant_t >= PLANT_SECONDS:
			planted[planting] = true
			planting = -1
		return
	for i in bombs.size():
		if not planted[i] and player.global_position.distance_to(bombs[i]) < PLANT_REACH:
			player.prompt = "[E]  Plant explosives"
			if player.interact_pressed():
				planting = i
				plant_t = 0.0
			return
	if count == bombs.size() and player.global_position.distance_to(exit_at) < EXIT_REACH:
		_end(true)


func _spotted(g: Guard) -> void:
	if not over:
		print("spotted by %s at %.1f m" % [g.body.name, g.body.global_position.distance_to(player.global_position)])
		_end(false)


func _end(won: bool) -> void:
	over = true
	print("mission %s at %.1f s" % ["accomplished" if won else "failed: spotted", clock])
	player.held = true
	banner.visible = true
	if won:
		banner.add_theme_color_override("font_color", Color(0.85, 0.92, 0.9))
		banner.text = "MISSION ACCOMPLISHED\n%d:%02d\n\nR to play again" % [int(clock) / 60, int(clock) % 60]
	else:
		banner.add_theme_color_override("font_color", Color(0.95, 0.35, 0.3))
		banner.text = "YOU HAVE BEEN SPOTTED\nMISSION FAILED\n\nR to try again"
