class_name Actors
extends Node3D
## The level's characters (`imported/characters/actors.json`): each placed and facing as the
## level has them, in their own model, playing an idle from their animation set (the
## character-specific set if it has one, else the regular male set) — chosen as the Bevy
## project does (`main.rs::idle_for`).

const DIR := "res://imported/characters/"
const IDLES := ["Stand_Freezing", "Stand_Relaxed", "Stand_Do_Nothing", "Stand_Tense", "Stand"]

var libraries: Dictionary = {}


func _ready() -> void:
	var list: Array = JSON.parse_string(FileAccess.get_file_as_string(DIR + "actors.json"))
	for a: Dictionary in list:
		var body := Node3D.new()
		body.name = a["name"]
		var q: Array = a["rot"]
		body.transform = Transform3D(Basis(Quaternion(q[0], q[1], q[2], q[3])), Vector3(a["pos"][0], a["pos"][1], a["pos"][2]))
		var model: Node3D = (load(DIR + a["model"]) as PackedScene).instantiate()
		body.add_child(model)
		var player := AnimationPlayer.new()
		model.add_child(player)
		var own := _library(a["set"])
		var regular := _library("Reg_Male.anm")
		player.add_animation_library("", own)
		if own != regular:
			player.add_animation_library("reg", regular)
		var idle := _idle(own, "")
		if idle.is_empty():
			idle = _idle(regular, "reg/")
		if not idle.is_empty():
			player.get_animation(idle).loop_mode = Animation.LOOP_LINEAR
			player.play(idle)
			player.seek(randf() * player.current_animation_length)
		# Something solid to bump into.
		var solid := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.3
		capsule.height = 1.8
		shape.shape = capsule
		shape.position.y = 0.9
		solid.add_child(shape)
		body.add_child(solid)
		add_child(body)
	print("actors: %d" % list.size())


## A set's clips, loaded once and shared by everyone who uses it.
func _library(set_file: String) -> AnimationLibrary:
	if not libraries.has(set_file):
		var stem := set_file.trim_suffix(".anm")
		var scene: Node = (load(DIR + "anims_%s.glb" % stem) as PackedScene).instantiate()
		var source := scene.find_child("AnimationPlayer", true, false) as AnimationPlayer
		libraries[set_file] = source.get_animation_library("")
		scene.queue_free()
	return libraries[set_file]


func _idle(library: AnimationLibrary, prefix: String) -> String:
	for name in IDLES:
		if library.has_animation(name):
			return prefix + name
	return ""
