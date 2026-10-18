class_name CloseCombat
extends Node
## What 47 does up close, ported from the Bevy project (`game/weapons.rs::strangle`,
## `ragdoll.rs::drag_by_limb`, `game/actions.rs`):
## - **F, the fiber wire**, from behind a guard who hasn't raised the alarm: 47 plays `Carrot`,
##   the victim `Die_Carrot`, standing just in front of him facing the same way, for the 4.7 s
##   the clips last; silent. Then the body goes limp.
## - **E on a body: drag** it (`Drag_Backward` while moving); E again lets go.
## - **G on a body: take his uniform** (`Change_Clothes`): 47 wears the guard's model from then
##   on; guards let him pass unless he comes close, runs or shows a gun (`Guard`).

const WIRE_REACH := 1.4
const WIRE_SECONDS := 4.7
const BODY_REACH := 2.2
const DRAG_SPEED := 1.2

var player: Player
var actors: Actors
var busy := 0.0
var dragging: Guard
var wire_sound: AudioStreamPlayer3D
var keys := {}


func _ready() -> void:
	await get_tree().process_frame
	player = get_parent().get_node("Player") as Player
	actors = get_parent().find_child("Actors", false, false) as Actors
	wire_sound = AudioStreamPlayer3D.new()
	wire_sound.stream = load("res://imported/sounds/W_FiberWire_Tighten_01.wav")
	player.add_child(wire_sound)
	# Test hooks: `HITMAN_KEYS="F@2,G@9"` (as E in `Player`).
	for tap in OS.get_environment("HITMAN_KEYS").split(",", false):
		var parts := tap.split("@")
		if parts.size() == 2:
			keys[parts[0].to_upper()] = parts[1].to_float()


func _pressed(code: Key, letter: String) -> bool:
	if Input.is_physical_key_pressed(code) and not keys.get("_held_" + letter, false):
		keys["_held_" + letter] = true
		return true
	if not Input.is_physical_key_pressed(code):
		keys["_held_" + letter] = false
	var t: float = keys.get(letter, -1.0)
	if t >= 0.0 and player.clock >= t:
		keys.erase(letter)
		return true
	return false


func _physics_process(dt: float) -> void:
	if player == null or actors == null or player.health <= 0.0:
		return
	if busy > 0.0:
		busy -= dt
		if busy <= 0.0:
			player.held = false
			player.anim.speed_scale = 1.0
		return
	if dragging:
		_drag(dt)
		return
	if OS.get_environment("HITMAN_TRACE") != "" and int(player.clock * 10) % 10 == 0:
		for g: Guard in actors.guards:
			if not g.alive:
				print("body %s at %.2f m" % [g.body.name, g.body_position().distance_to(player.global_position)])
	var wire_target := _wire_target()
	var body := _nearest_body()
	if wire_target:
		player.prompt = "[F]  Fiber wire"
		if _pressed(KEY_F, "F"):
			_strangle(wire_target)
	elif body:
		player.prompt = "[E]  Drag body" + ("" if body.stripped else "     [G]  Take uniform")
		if player.interact_pressed():
			dragging = body
		elif not body.stripped and _pressed(KEY_G, "G"):
			_take_uniform(body)


## A living guard, not on alert, with his back to 47 within reach.
func _wire_target() -> Guard:
	for g: Guard in actors.guards:
		if not g.alive or g.alarmed:
			continue
		var to := player.global_position - g.body.global_position
		to.y = 0.0
		if to.length() > WIRE_REACH:
			continue
		# 47 is behind him: more than 110° off where he faces.
		if g._forward().angle_to(to.normalized()) > deg_to_rad(110.0):
			return g
	return null


func _nearest_body() -> Guard:
	var best: Guard = null
	var best_d := BODY_REACH
	for g: Guard in actors.guards:
		if g.alive:
			continue
		var d := g.body_position().distance_to(player.global_position)
		if d < best_d:
			best_d = d
			best = g
	return best


func _strangle(g: Guard) -> void:
	print("fiber wire: %s" % g.body.name)
	var fwd := -player.model.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	# The victim just in front of him, facing the same way (both models face their −Z).
	g.body.global_position = player.global_position + fwd * 0.45
	g.body.rotation.y = player.model.global_rotation.y
	g.strangled(WIRE_SECONDS)
	wire_sound.play()
	player.held = true
	player.anim.speed_scale = 1.0
	player.anim.play("Carrot", 0.1)
	busy = WIRE_SECONDS


## Drags the body along behind 47 (W/S move him, slowly): it follows at arm's length.
func _drag(dt: float) -> void:
	player.prompt = "[E]  Let go"
	if player.interact_pressed():
		dragging = null
		return
	var fwd := -player.model.global_basis.z
	fwd.y = 0.0
	var target := player.global_position + fwd.normalized() * 1.0
	var at := dragging.body_position()
	var move := Vector3(target.x - at.x, 0.0, target.z - at.z)
	if move.length() > 0.05:
		dragging.body.global_position += move.limit_length(DRAG_SPEED * 2.0 * dt)
	player.dragging = true


func _take_uniform(g: Guard) -> void:
	player.held = true
	player.anim.speed_scale = 1.0
	player.anim.play("Change_Clothes", 0.15)
	var seconds: float = player.clips.get("Change_Clothes", {}).get("seconds", 3.0)
	busy = seconds
	get_tree().create_timer(seconds * 0.6).timeout.connect(func() -> void: player.wear(g.body))
	g.stripped = true
