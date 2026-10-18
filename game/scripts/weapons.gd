class_name Weapons
extends Node
## 47's Silverballer, ported from the Bevy project's `game/weapons.rs` with its numbers (from
## the GMS weapon and ammo templates): semi-automatic, 14 rounds, 300 rounds a minute, 0.35°
## spread, 2.1 → 0.7 damage from 30 to 80 m, × `DAMAGE_SCALE` 10, head × 5, limbs × 0.5
## (assumptions, as there). Silenced: guards within 5 m know it for a shot, out to 15 m it's a
## noise.
##
## Q draws or holsters it; right mouse aims (over the shoulder, closer in), left mouse fires
## at the crosshair, R reloads (`UB_Reload_Hardballer`, 2.2 s).

const DAMAGE_SCALE := 10.0
const MAGAZINE := 14
const START_AMMO := 14 + 28
const SHOT_INTERVAL := 60.0 / 300.0
const SPREAD := deg_to_rad(0.35)
const NEAR := 30.0
const FAR := 80.0
const NEAR_DAMAGE := 2.1
const FAR_DAMAGE := 0.7
const RELOAD_SECONDS := 2.2
const SILENCED_ALARM := 5.0
const SILENCED_HEARD := 15.0
const AIM_FOV := 32.0
const AIM_DISTANCE := 2.2
## Where in `UB_Aim_Gun`'s sweep of directions (left, ahead, right, up…, down) the gun points
## straight ahead: 1.8 s, found by sampling the sweep;
## `HITMAN_AIM_T` overrides it (tuning).
var AIM_FRAME := OS.get_environment("HITMAN_AIM_T").to_float() if OS.get_environment("HITMAN_AIM_T") != "" else 1.8

var player: Player
var gun: Node3D
var hold: AimPose
var drawn := false
var aiming := false
var in_clip := MAGAZINE
var spare := START_AMMO - MAGAZINE
var cooldown := 0.0
var reloading := 0.0
var flash: OmniLight3D
var shot_sound: AudioStreamPlayer3D
var crosshair: Label
var hold_clip: Animation
var aim_clip: Animation
## Test hook: `HITMAN_SHOOT="2,2.5,3"` draws, aims at the nearest living guard and fires at
## those times (seconds).
var shots: Array[float] = []
## Tuning the grip live: `HITMAN_AIM_HOLD=1` keeps the gun drawn and aimed, `=hold` drawn and
## lowered (as he stands with it).
var aim_hold := OS.get_environment("HITMAN_AIM_HOLD") not in ["", "hold"]
var hold_only := OS.get_environment("HITMAN_AIM_HOLD") == "hold"
var clock := 0.0


func _ready() -> void:
	await get_tree().process_frame
	player = get_parent().get_node("Player") as Player
	var skel := player.skeleton
	var hand := BoneAttachment3D.new()
	hand.name = "RightHand"
	hand.bone_name = "RIGHT_HAND"
	skel.add_child(hand)
	gun = (load("res://imported/characters/weapon_silverballer.glb") as PackedScene).instantiate()
	gun.name = "Silverballer"
	hand.add_child(gun)
	# A 2° turn about the barrel, tuned live in the editor.
	gun.transform = Transform3D(Basis(Vector3.BACK, deg_to_rad(-2.0)), Vector3.ZERO)
	gun.visible = false
	hold = AimPose.new()
	skel.add_child(hold)
	hold.influence = 0.0
	hold_clip = player.anim.get_animation("UB_Hold_Gun_RightHand")
	aim_clip = player.anim.get_animation("UB_Aim_Gun")
	flash = OmniLight3D.new()
	flash.light_color = Color(1.0, 0.8, 0.5)
	flash.omni_range = 4.0
	flash.light_energy = 0.0
	gun.add_child(flash)
	shot_sound = AudioStreamPlayer3D.new()
	shot_sound.stream = load("res://imported/sounds/W_HardballerSD_Shot_01.wav")
	shot_sound.max_polyphony = 3
	gun.add_child(shot_sound)
	var layer := CanvasLayer.new()
	add_child(layer)
	crosshair = Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 22)
	crosshair.add_theme_color_override("font_color", Color(0.9, 0.95, 0.95, 0.8))
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	crosshair.visible = false
	layer.add_child(crosshair)
	for t in OS.get_environment("HITMAN_SHOOT").split(",", false):
		shots.append(t.to_float())


func _unhandled_input(event: InputEvent) -> void:
	if player == null or player.held or player.health <= 0.0:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_Q:
			drawn = not drawn
		elif event.physical_keycode == KEY_R and drawn:
			_reload()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and drawn and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_fire()


func _process(dt: float) -> void:
	if player == null:
		return
	cooldown = maxf(cooldown - dt, 0.0)
	flash.light_energy = maxf(flash.light_energy - dt * 60.0, 0.0)
	if player.held or player.health <= 0.0:
		drawn = false
	if aim_hold or hold_only:
		drawn = true
	aiming = drawn and (Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or aim_hold) and reloading <= 0.0
	clock += dt
	if not shots.is_empty() and player.health > 0.0:
		drawn = true
		aiming = clock > shots[0] - 1.0
		var target := _nearest_guard()
		if target and aiming:
			var to := target.body.global_position + Vector3.UP * 1.3 - player.camera.global_position
			player.yaw = atan2(-to.x, -to.z)
			player.pitch = atan2(to.y, Vector2(to.x, to.z).length())
		if clock >= shots[0]:
			shots.pop_front()
			_fire()
	gun.visible = drawn
	if reloading > 0.0:
		reloading -= dt
		if reloading <= 0.0:
			var take := mini(MAGAZINE - in_clip, spare)
			in_clip += take
			spare -= take
	# The arms: aiming holds the aim clip's straight-ahead frame, else the gun-in-hand pose.
	var want := hold_clip if not aiming else aim_clip
	if not hold.has_meta("clip") or hold.get_meta("clip") != want:
		hold.set_clip(want, (AIM_FRAME if want == aim_clip else 0.0), player.clips[want.resource_name if want.resource_name != "" else ("UB_Aim_Gun" if want == aim_clip else "UB_Hold_Gun_RightHand")]["bones"])
		hold.set_meta("clip", want)
	hold.influence = move_toward(hold.influence, 1.0 if drawn and reloading <= 0.0 else 0.0, dt * 6.0)
	hold.pitch = -player.pitch * 0.8 if aiming else 0.0
	player.aiming = aiming
	player.camera.fov = lerpf(player.camera.fov, AIM_FOV if aiming else 45.0, minf(dt * 10.0, 1.0))
	player.arm.spring_length = lerpf(player.arm.spring_length, AIM_DISTANCE if aiming else Player.CAMERA_DISTANCE, minf(dt * 10.0, 1.0))
	crosshair.visible = aiming
	player.camera.position.x = lerpf(player.camera.position.x, 0.75 if aiming else Player.CAMERA_SHOULDER, minf(dt * 10.0, 1.0))


func _fire() -> void:
	if cooldown > 0.0 or reloading > 0.0:
		return
	if in_clip <= 0:
		shot_sound.stream = load("res://imported/sounds/W_Empty_01.wav")
		shot_sound.play()
		shot_sound.stream = load("res://imported/sounds/W_HardballerSD_Shot_01.wav")
		return
	in_clip -= 1
	cooldown = SHOT_INTERVAL
	flash.light_energy = 6.0
	shot_sound.play()
	# From the camera through the crosshair (with the gun's spread; worse from the hip).
	var cam := player.camera
	var spread := SPREAD * (1.0 if aiming else 6.0)
	var dir := -cam.global_basis.z
	dir = dir.rotated(cam.global_basis.x, randf_range(-spread, spread)).rotated(cam.global_basis.y, randf_range(-spread, spread))
	# Along the crosshair's line, but starting level with 47 (the camera may sit against a wall).
	var from := cam.global_position + dir * maxf((player.global_position + Vector3.UP * 1.5 - cam.global_position).dot(dir), 0.0)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * FAR, 1 | 2 | 4, [player.get_rid()])
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	_alert(player.global_position)
	if not OS.get_environment("HITMAN_SHOOT").is_empty():
		print("shot: %s" % (str((hit["collider"] as Node).get_path()) + " at " + str(hit["position"]) if not hit.is_empty() else "miss"))
	if hit.is_empty():
		return
	var guard := _guard_of(hit["collider"])
	if guard:
		var d := player.global_position.distance_to(hit["position"])
		var t := clampf((d - NEAR) / (FAR - NEAR), 0.0, 1.0)
		var height: float = (hit["position"] as Vector3).y - guard.body.global_position.y
		var zone := 5.0 if height > 1.5 else (1.0 if height > 0.95 else 0.5)
		guard.hurt(lerpf(NEAR_DAMAGE, FAR_DAMAGE, t) * DAMAGE_SCALE * zone, player.global_position)
	else:
		_impact(hit["position"])


func _nearest_guard() -> Guard:
	var actors := get_parent().find_child("Actors", false, false) as Actors
	var best: Guard = null
	for g: Guard in actors.guards:
		if g.alive and (best == null or g.body.global_position.distance_to(player.global_position) < best.body.global_position.distance_to(player.global_position)):
			best = g
	return best


func _guard_of(collider: Object) -> Guard:
	var n := collider as Node
	while n:
		var g := n.get_node_or_null("Guard")
		if g is Guard:
			return g
		n = n.get_parent()
	return null


## A silenced shot: guards right by it know it for one; further off, a noise to look into.
func _alert(at: Vector3) -> void:
	var actors := get_parent().find_child("Actors", false, false) as Actors
	if actors == null:
		return
	for g: Guard in actors.guards:
		if not g.alive:
			continue
		var d := g.body.global_position.distance_to(at)
		if d < SILENCED_ALARM:
			g.raise_alarm()
		elif d < SILENCED_HEARD:
			g.suspicion = maxf(g.suspicion, 0.5)


func _impact(at: Vector3) -> void:
	var s := AudioStreamPlayer3D.new()
	s.stream = load("res://imported/sounds/Impact_Cloth_0%d.wav" % (randi() % 3 + 1))
	s.position = at
	s.autoplay = true
	s.finished.connect(s.queue_free)
	get_parent().add_child(s)


func _reload() -> void:
	if reloading > 0.0 or in_clip == MAGAZINE or spare <= 0:
		return
	reloading = RELOAD_SECONDS
	shot_sound.stream = load("res://imported/sounds/W_HardBaller_ClipOut_01.wav")
	shot_sound.play()
	get_tree().create_timer(1.2).timeout.connect(func() -> void:
		shot_sound.stream = load("res://imported/sounds/W_HardBaller_ClipIn_01.wav")
		shot_sound.play()
		get_tree().create_timer(0.8).timeout.connect(func() -> void: shot_sound.stream = load("res://imported/sounds/W_HardballerSD_Shot_01.wav")))
