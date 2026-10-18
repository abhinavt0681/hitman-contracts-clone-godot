class_name Guard
extends Node
## An armed character (soldiers, bodyguards, agents, snipers): walks its patrol route if it has
## one, watches and listens for 47, grows suspicious, and catches him.
##
## Numbers are the Bevy project's (`game/ai.rs`, AGENTS.md "Sight"), themselves partly
## assumptions until the script VM can confirm them:
## - sight 30 m when 47 is lit, 9 m in the dark; outdoors the blizzard caps it at 22 m, 6 m in
##   a full squall; indoors no cap. Field of view ±60° (assumption), all round within 2 m.
## - hearing: running carries 14 m, walking 4 m, sneaking nothing; snow halves it outdoors and
##   a squall cuts it by up to 60%.
## - suspicion fills faster the closer and better lit 47 is (a few tenths of a second up
##   close, a couple of seconds at the edge of sight); at 0.35 the guard stops and turns to
##   look, at 1 he raises the alarm.

signal spotted(guard: Guard)

const WALK_SPEED := 1.48  # the `Walk` clip's own root speed (anims_Reg_Male.json)
const TURN_RATE := 4.0
const EYE := 1.6
const FOV := deg_to_rad(60.0)
const SIGHT_LIT := 30.0
const SIGHT_DARK := 9.0
const WHITEOUT := 22.0
const SQUALL_WHITEOUT := 6.0
const HEAR := {"run": 14.0, "walk": 4.0, "sneak": 0.0}
const LOOK_AT := 0.35
const DECAY := 0.25

var body: Node3D
var anim: AnimationPlayer
var walk_clip := ""
var idle_clip := ""
var alert_clip := ""
var route: Array = []
var leg := 0
var wait := 0.0
var suspicion := 0.0
var alarmed := false
## The models face their local −Z (seen from +Z, guards show their backs).
var forward_sign := -1.0
var player: Player
var game: Node
var think := 0.0
var sees := false


func setup(b: Node3D, a: AnimationPlayer, r: Array, clips: Dictionary) -> void:
	body = b
	anim = a
	route = r
	walk_clip = clips.get("walk", "")
	idle_clip = clips.get("idle", "")
	alert_clip = clips.get("alert", "")


func _physics_process(dt: float) -> void:
	if player == null:
		player = body.get_tree().current_scene.get_node_or_null("Player") as Player
		game = body.get_tree().current_scene
		if player == null:
			return
	if alarmed:
		_face(player.global_position, dt)
		return
	think -= dt
	if think <= 0.0:
		think = 0.1
		sees = _perceive()
	var gain := _gain() if sees else 0.0
	gain += _hearing()
	suspicion = clampf(suspicion + gain * dt - (DECAY * dt if gain <= 0.0 else 0.0), 0.0, 1.0)
	if suspicion >= 1.0:
		_alarm()
		return
	if suspicion >= LOOK_AT:
		# Stop and look.
		_face(player.global_position, dt)
		_play(idle_clip)
		return
	_patrol(dt)


## Line of sight to 47 within range and view.
func _perceive() -> bool:
	var eye := body.global_position + Vector3.UP * EYE
	var target := player.global_position + Vector3.UP * (1.1 if player.sneaking else 1.5)
	var to := target - eye
	var d := to.length()
	if d > _range():
		return false
	var fwd := _forward()
	var flat := Vector3(to.x, 0.0, to.z).normalized()
	if d > 2.0 and fwd.angle_to(flat) > FOV:
		return false
	var q := PhysicsRayQueryParameters3D.create(eye, target, 1 | 2, [player.get_rid()])
	return body.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## How far a guard sees 47 now: lit or dark, through the blizzard or indoors.
func _range() -> float:
	var r := lerpf(SIGHT_DARK, SIGHT_LIT, _light())
	if not _indoors(player.global_position):
		var gust := 0.0
		var blizzard := game.find_child("Blizzard", false, false)
		if blizzard:
			gust = blizzard.get("gust")
		r = minf(r, lerpf(WHITEOUT, SQUALL_WHITEOUT, gust))
	return r


## How lit 47 is, 0 (dark) … 1 (under a lamp): the nearest lamps' reach at his position.
func _light() -> float:
	var p := player.global_position + Vector3.UP
	var best := 0.0
	for l in body.get_tree().get_nodes_in_group("lamps"):
		var lamp := l as Light3D
		var reach: float = lamp.omni_range if lamp is OmniLight3D else (lamp as SpotLight3D).spot_range
		var d := lamp.global_position.distance_to(p)
		if d < reach:
			best = maxf(best, (1.0 - d / reach) * minf(lamp.light_energy / 2.0, 1.0))
	return clampf(best * 1.5, 0.0, 1.0)


func _indoors(p: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 2.0, p + Vector3.UP * 14.0, 1, [player.get_rid()])
	return not body.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## Suspicion per second while 47 is in sight: faster up close and in light.
func _gain() -> float:
	var d := body.global_position.distance_to(player.global_position)
	var near := clampf(1.0 - d / maxf(_range(), 0.1), 0.0, 1.0)
	# About a second (the Bevy project's 0.8–1.4 s reaction) right up close and lit, several
	# at the edge of sight.
	return 0.2 + 0.7 * near * near + 0.25 * _light()


## Suspicion per second from what 47's feet make heard.
func _hearing() -> float:
	var speed := Vector2(player.velocity.x, player.velocity.z).length()
	if speed < 0.2 or not player.is_on_floor():
		return 0.0
	var kind := "sneak" if player.sneaking else ("run" if speed > 3.0 else "walk")
	var reach: float = HEAR[kind]
	if not _indoors(player.global_position):
		reach *= 0.5
		var blizzard := game.find_child("Blizzard", false, false)
		if blizzard:
			reach *= 1.0 - 0.6 * float(blizzard.get("gust"))
	var d := body.global_position.distance_to(player.global_position)
	return 0.0 if d > reach else 0.6 * (1.0 - d / reach) + 0.15


func _patrol(dt: float) -> void:
	if route.size() < 2:
		_play(idle_clip)
		return
	if wait > 0.0:
		wait -= dt
		_play(idle_clip)
		return
	var node: Dictionary = route[leg]
	var goal := Vector3(node["pos"][0], node["pos"][1], node["pos"][2])
	var p := body.global_position
	var flat := Vector3(goal.x - p.x, 0.0, goal.z - p.z)
	if flat.length() < 0.3:
		wait = node["wait"]
		leg = (leg + 1) % route.size()
		return
	_face(goal, dt)
	var step := flat.normalized() * WALK_SPEED * dt
	var next := p + step
	# Keep to the ground (routes are authored on it; this follows steps and slopes).
	var q := PhysicsRayQueryParameters3D.create(next + Vector3.UP * 1.0, next + Vector3.DOWN * 1.5, 1)
	var hit := body.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		next.y = (hit["position"] as Vector3).y
	body.global_position = next
	_play(walk_clip)


func _forward() -> Vector3:
	var f := body.global_basis.z * forward_sign
	return Vector3(f.x, 0.0, f.z).normalized()


func _face(at: Vector3, dt: float) -> void:
	var d := Vector3(at.x - body.global_position.x, 0.0, at.z - body.global_position.z)
	if d.length() < 0.05:
		return
	var want := atan2(d.x, d.z) if forward_sign > 0.0 else atan2(-d.x, -d.z)
	body.rotation.y = lerp_angle(body.rotation.y, want, minf(TURN_RATE * dt, 1.0))


func _play(clip: String) -> void:
	if clip.is_empty() or anim.current_animation == clip:
		return
	anim.play(clip, 0.25)


func _alarm() -> void:
	alarmed = true
	_play(alert_clip if not alert_clip.is_empty() else idle_clip)
	spotted.emit(self)
