class_name Guard
extends Node
## An armed character (soldiers, bodyguards, agents, snipers): walks its patrol route if it has
## one, watches and listens for 47, grows suspicious, and catches him.
##
## Numbers are the Bevy project's (`game/ai.rs`, AGENTS.md "Sight"), themselves partly
## assumptions until the script VM can confirm them:
## - sight 30 m when 47 is lit, 9 m in the dark; outdoors the blizzard caps it at 22 m, 6 m in
##   a full squall; indoors no cap. Field of view ±60° (assumption); behind them only hearing counts.
## - hearing: running carries 14 m, walking 4 m, sneaking nothing; snow halves it outdoors and
##   a squall cuts it by up to 60%.
## - suspicion fills faster the closer and better lit 47 is (a few tenths of a second up
##   close, a couple of seconds at the edge of sight); at 0.35 the guard stops and turns to
##   look, at 1 he raises the alarm.

signal spotted(guard: Guard)
signal killed(guard: Guard)

## Combat (the Bevy project's `ai.rs` / `weapons.rs`): 20 hitpoints (`m_iHitpoints`); an alarm
## spreads to guards within 35 m; each takes 0.8–1.4 s to react, then fires AK-47 bursts of 3–6
## rounds at 600 a minute, 18 hitpoints a round at combat range, out to 22 m; between bursts
## 1–2 s. Hit chance falls with distance and with 47 moving (assumption: tuned by feel).
const HITPOINTS := 20.0
## Guards react to 47 (sight, hearing, bodies, alarms, combat) only with `HITMAN_GUARDS=on`;
## off for now (the maintainer's call), they just patrol and can be killed.
static var respond := OS.get_environment("HITMAN_GUARDS") == "on"
const ALARM_SPREAD := 35.0
const RIFLE_RANGE := 22.0
const RUN_SPEED := 4.0
const ROUND_DAMAGE := 18.0
## The bones `UB_Aim_Rifle` animates (anims_Reg_Male.json).
const RIFLE_AIM_BONES := ["SPINE", "SPINE_1", "NECK", "HEAD", "LEFT_CLAVICLE", "LEFT_UPPER_ARM", "LEFT_FOREARM", "LEFT_HAND", "LEFT_FINGER_0", "LEFT_FINGER_0_1", "LEFT_FINGER_0_2", "LEFT_FINGER_1", "LEFT_FINGER_1_1", "LEFT_FINGER_1_2", "LEFT_FINGER_2", "LEFT_FINGER_2_1", "LEFT_FINGER_2_2", "LEFT_FINGER_3", "LEFT_FINGER_3_1", "LEFT_FINGER_3_2", "LEFT_FINGER_4", "LEFT_FINGER_4_1", "LEFT_FINGER_4_2", "RIGHT_CLAVICLE", "RIGHT_UPPER_ARM", "RIGHT_FOREARM", "RIGHT_HAND"]

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
var run_clip := ""
var die_clip := ""
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
var alive := true
var health := HITPOINTS
var react := 0.0
var burst := 0
var fire_cd := 0.0
var aim: AimPose
var gun_sound: AudioStreamPlayer3D
var last_seen := Vector3.INF
var ragdoll: PhysicalBoneSimulator3D
## Taken by 47 (his uniform) or found by another guard.
var stripped := false
var found := false
## Bodies within this are noticed (the Bevy project's `BODY_SPOT_RANGE`).
const BODY_SPOT := 18.0
## In a guard's uniform 47 passes unless he comes this close, runs, or shows a gun; then
## suspicion builds slowly (Blood Money's scrutiny, filling the original's gap; assumption).
const SCRUTINY := 2.5


func setup(b: Node3D, a: AnimationPlayer, r: Array, clips: Dictionary) -> void:
	body = b
	anim = a
	route = r
	walk_clip = clips.get("walk", "")
	idle_clip = clips.get("idle", "")
	alert_clip = clips.get("alert", "")
	run_clip = clips.get("run", "")
	die_clip = clips.get("die", "")
	add_to_group("guards")


func _physics_process(dt: float) -> void:
	if player == null:
		player = body.get_tree().current_scene.get_node_or_null("Player") as Player
		game = body.get_tree().current_scene
		if player == null:
			return
	if not alive:
		return
	if alarmed:
		_combat(dt)
		return
	if not respond:
		suspicion = 0.0
		_patrol(dt)
		return
	think -= dt
	if think <= 0.0:
		think = 0.1
		sees = _perceive()
	var gain := _disguised_gain() if sees else 0.0
	if not sees:
		_look_for_bodies()
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
	if fwd.angle_to(flat) > FOV:
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


## In disguise: only close scrutiny, running or a drawn gun give him away.
func _disguised_gain() -> float:
	if player.outfit == "suit":
		return _gain()
	var d := body.global_position.distance_to(player.global_position)
	var running := Vector2(player.velocity.x, player.velocity.z).length() > 3.0
	if player.aiming or player.gun_drawn:
		return _gain()
	if running:
		return _gain() * 0.5
	return 0.25 if d < SCRUTINY else 0.0


## A body in view raises the alarm.
func _look_for_bodies() -> void:
	if think > 0.05:
		return
	for g in get_tree().get_nodes_in_group("guards"):
		var other := g as Guard
		if other.alive or other.found or other == self:
			continue
		var at := other.body_position()
		var to := at - (body.global_position + Vector3.UP * EYE)
		if to.length() > BODY_SPOT:
			continue
		if _forward().angle_to(Vector3(to.x, 0.0, to.z).normalized()) > FOV:
			continue
		var ray := PhysicalRayQueryParameters(body.global_position + Vector3.UP * EYE, at + Vector3.UP * 0.2)
		if body.get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			other.found = true
			print("%s found the body of %s" % [body.name, other.body.name])
			last_seen = at
			_alarm()
			return


func PhysicalRayQueryParameters(a: Vector3, b: Vector3) -> PhysicsRayQueryParameters3D:
	var excl: Array[RID] = [player.get_rid()]
	return PhysicsRayQueryParameters3D.create(a, b, 1 | 2, excl)


## Where the body lies: its pelvis (the death clips carry it away from the node's origin).
func body_position() -> Vector3:
	var skel := body.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel:
		var b := skel.find_bone("PELVIS")
		if b >= 0:
			return skel.global_transform * skel.get_bone_global_pose(b).origin
	return body.global_position


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
	raise_alarm()
	spotted.emit(self)
	# Word spreads.
	for g in get_tree().get_nodes_in_group("guards"):
		var other := g as Guard
		if other != self and other.alive and other.body.global_position.distance_to(body.global_position) < ALARM_SPREAD:
			other.raise_alarm()


## Into combat: after a moment's reaction, aim and fire.
func raise_alarm() -> void:
	if alarmed or not alive or not respond:
		return
	alarmed = true
	suspicion = 1.0
	react = randf_range(0.8, 1.4)
	last_seen = player.global_position if player else body.global_position


func _combat(dt: float) -> void:
	think -= dt
	if think <= 0.0:
		think = 0.15
		sees = _line_of_sight()
		if sees:
			last_seen = player.global_position
	if player.health <= 0.0:
		_play(idle_clip)
		_aim(false)
		return
	var d := body.global_position.distance_to(player.global_position)
	if not sees or d > RIFLE_RANGE:
		# Close in on where he was last seen.
		_aim(false)
		_go(last_seen, RUN_SPEED, dt)
		return
	_face(player.global_position, dt)
	_play(idle_clip)
	_aim(true)
	react -= dt
	if react > 0.0:
		return
	fire_cd -= dt
	if fire_cd > 0.0:
		return
	if burst <= 0:
		burst = randi_range(3, 6)
	_shoot(d)
	burst -= 1
	fire_cd = 0.1 if burst > 0 else randf_range(1.0, 2.0)


func _line_of_sight() -> bool:
	var eye := body.global_position + Vector3.UP * EYE
	var target := player.global_position + Vector3.UP * 1.3
	var q := PhysicsRayQueryParameters3D.create(eye, target, 1 | 2, [player.get_rid()])
	return body.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _shoot(d: float) -> void:
	if gun_sound == null:
		gun_sound = AudioStreamPlayer3D.new()
		gun_sound.stream = load("res://imported/sounds/W_AK47_Shot_01.wav")
		gun_sound.max_polyphony = 4
		gun_sound.position = Vector3.UP * 1.4
		body.add_child(gun_sound)
	gun_sound.play()
	var moving := Vector2(player.velocity.x, player.velocity.z).length()
	var chance := clampf(0.55 - d * 0.018, 0.12, 0.55) * (0.6 if moving > 3.0 else 1.0)
	if randf() < chance:
		player.hurt(ROUND_DAMAGE)


## The guard's upper body in the rifle aim (the Bevy project holds `UB_Aim_Rifle` at 0.6 s).
func _aim(on: bool) -> void:
	if aim == null:
		var skel := body.find_child("Skeleton3D", true, false) as Skeleton3D
		var clip := anim.get_animation("reg/UB_Aim_Rifle") if anim.has_animation("reg/UB_Aim_Rifle") else anim.get_animation("UB_Aim_Rifle")
		if skel == null or clip == null:
			return
		aim = AimPose.new()
		skel.add_child(aim)
		aim.set_clip(clip, 0.6, RIFLE_AIM_BONES)
		aim.influence = 0.0
	aim.influence = move_toward(aim.influence, 1.0 if on else 0.0, 0.1)


## Walks or runs towards `goal` on the ground, stopping at walls.
func _go(goal: Vector3, speed: float, dt: float) -> void:
	var p := body.global_position
	var flat := Vector3(goal.x - p.x, 0.0, goal.z - p.z)
	if flat.length() < 0.5:
		_play(idle_clip)
		return
	_face(goal, dt)
	var step := flat.normalized() * speed * dt
	var space := body.get_world_3d().direct_space_state
	var ahead := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.8, p + Vector3.UP * 0.8 + flat.normalized() * 0.5, 1 | 2)
	if not space.intersect_ray(ahead).is_empty():
		_play(idle_clip)
		return
	var next := p + step
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(next + Vector3.UP, next + Vector3.DOWN * 1.5, 1))
	if not hit.is_empty():
		next.y = (hit["position"] as Vector3).y
	body.global_position = next
	_play(run_clip if speed > 2.0 and not run_clip.is_empty() else walk_clip)


## A bullet: hitpoints off; any hit puts him on alert; at 0 he falls.
func hurt(amount: float, from: Vector3) -> void:
	if not alive:
		return
	health -= amount
	var s := AudioStreamPlayer3D.new()
	s.stream = load("res://imported/sounds/Impact_Flesh_0%d.wav" % (randi() % 5 + 1))
	s.position = Vector3.UP * 1.2
	s.autoplay = true
	s.finished.connect(s.queue_free)
	body.add_child(s)
	if health > 0.0:
		last_seen = from
		raise_alarm()
		return
	var push := (body.global_position - from).normalized() * 40.0
	push.y = 10.0
	die(push)
	print("guard down: %s" % body.name)


## Dead: the ragdoll takes over (pushed by the shot, if any).
func die(push: Vector3 = Vector3.ZERO) -> void:
	if not alive:
		return
	alive = false
	if aim:
		aim.influence = 0.0
	for c in body.find_children("*", "CollisionShape3D", true, false):
		if not (c.get_parent() is PhysicalBone3D):
			(c as CollisionShape3D).set_deferred("disabled", true)
	go_limp(push)
	killed.emit(self)


## Down for good. (Physics ragdolls (`Ragdoll`) fell through the floor under the skeleton's
## centimetre scale; until that's solved the original death clips play and the body stays put.)
func go_limp(_push: Vector3 = Vector3.ZERO) -> void:
	if anim.current_animation.contains("Die_Carrot"):
		return
	var clip := die_clip
	if clip.is_empty() or not anim.has_animation(clip):
		return
	anim.get_animation(clip).loop_mode = Animation.LOOP_NONE
	anim.play(clip, 0.1)


## The fiber wire: no sound, no struggle the others can see from afar; `Die_Carrot`, then limp.
func strangled(clip_seconds: float) -> void:
	alive = false
	if aim:
		aim.influence = 0.0
	for c in body.find_children("*", "CollisionShape3D", true, false):
		(c as CollisionShape3D).set_deferred("disabled", true)
	var clip := "reg/Die_Carrot" if anim.has_animation("reg/Die_Carrot") else "Die_Carrot"
	if anim.has_animation(clip):
		anim.get_animation(clip).loop_mode = Animation.LOOP_NONE
		anim.play(clip, 0.1)
	killed.emit(self)
