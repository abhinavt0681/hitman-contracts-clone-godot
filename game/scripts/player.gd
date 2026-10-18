class_name Player
extends CharacterBody3D
## 47: third-person controller with the original model and animations.
##
## Speeds and camera framing are the Bevy project's (`src/player.rs`). Clips play at the rate
## that matches his speed to each clip's own root speed (exported to `hitman.json`), so his feet
## don't slide.
##
## Controls: mouse look (captured from the start and whenever the window regains focus; Esc
## releases it, a click takes it back), WASD, Shift run, Ctrl sneak. F11 toggles fullscreen.
##
## Test hooks: `HITMAN_YAW=radians` (0 faces −Z); `HITMAN_AUTOWALK=secs[@start]` holds W from
## `start` seconds for `secs` (`HITMAN_AUTORUN=1` adds Shift); `HITMAN_KEYS="E@2.5,E@9"` taps E
## (interact) at those times.

const WALK_SPEED := 1.6
const RUN_SPEED := 4.2
const SNEAK_SPEED := 0.95
const GRAVITY := 18.0
const TURN_RATE := 12.0
const EYE_HEIGHT := 1.65
const CROUCH_EYE_HEIGHT := 1.15
const CAMERA_DISTANCE := 3.2
const CAMERA_SHOULDER := 0.45
const MOUSE_SENSITIVITY := 0.0025
const BLEND := 0.2
## Highest ledge he walks up without a jump: stairs, kerbs, snow humps (the Bevy project's
## `STEP_HEIGHT`; assumption: the original's step is similar, its stairs rise ~0.2–0.3 m).
const STEP_HEIGHT := 0.45
## How fast the camera and model catch up after a step, so stairs don't jolt the view (1/s).
const STEP_SMOOTH := 12.0

## Footsteps: a foot within `PLANT` of its lowest point has landed; it must rise `LIFT` above
## it before the next step counts. Levels as measured from gameplay footage of the original
## (the Bevy project's `footsteps.rs`): quiet indoors, nearly buried by the wind outdoors.
const PLANT := 0.025
const LIFT := 0.06
const STEP_VOLUME := {"walk": 0.11, "run": 0.17, "sneak": 0.03}
const SNOW_GAIN := 0.25

const MODEL := "res://imported/characters/hitman.glb"
const TIE := "res://imported/characters/tie.glb"
const TIE_META := "res://imported/characters/tie.json"
## The tie's swing (the Bevy project's `tie.rs`): spring stiffness and damping, how far his
## acceleration tips it (rad per m/s²), and the most it swings (rad).
const TIE_STIFFNESS := 60.0
const TIE_DAMPING := 7.0
const TIE_TIP := 0.05
const TIE_MAX := 0.6
const CLIPS := "res://imported/characters/hitman.json"

var yaw := 0.0
var pitch := -0.25
var model: Node3D
var anim: AnimationPlayer
var clips: Dictionary = {}
var pivot: Node3D
var arm: SpringArm3D
var camera: Camera3D
var sneaking := false
var clock := 0.0
var autowalk := Vector2(-1.0, 0.0)
var skeleton: Skeleton3D
var feet: Array[int] = []
var foot_low := [1.0, 1.0]
var foot_lifted := [false, false]
var steps := {"snow": [], "concrete": []}
var step_player: AudioStreamPlayer3D
var step_variant := 0
## The height of the last steps still to be eased out of the model and camera (m).
var step_lag := 0.0
## Something else (a ladder) moves and animates him: no walking, no gravity.
var held := false
## What E would do here, shown at the bottom of the screen; set each frame by whoever offers it.
var prompt := ""
var prompt_label: Label
var key_taps: Array[float] = []
## The tie: its pivot at the knot (on his chest bone), its rest pose there, and its swing.
var tie: Node3D
var tie_rest: Basis
var tie_angle := Vector2.ZERO
var tie_rate := Vector2.ZERO
var tie_last_pos := Vector3.ZERO
var tie_last_vel := Vector3.ZERO
var capsule_radius := 0.3


func _ready() -> void:
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	shape.shape = capsule
	shape.position.y = 0.9
	add_child(shape)
	floor_snap_length = 0.45
	floor_max_angle = deg_to_rad(55.0)

	model = (load(MODEL) as PackedScene).instantiate()
	add_child(model)
	anim = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if not OS.get_environment("HITMAN_CULL_TEST").is_empty():
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			for s in (mi as MeshInstance3D).mesh.get_surface_count():
				var m := ((mi as MeshInstance3D).mesh.surface_get_material(s) as BaseMaterial3D).duplicate() as BaseMaterial3D
				m.cull_mode = BaseMaterial3D.CULL_BACK
				(mi as MeshInstance3D).set_surface_override_material(s, m)
	clips = JSON.parse_string(FileAccess.get_file_as_string(CLIPS))
	for name in ["Stand_Do_Nothing", "Walk_Forward", "Run", "Sneak_Forward", "Sneak_Ambient"]:
		var a := anim.get_animation(name)
		if a:
			a.loop_mode = Animation.LOOP_LINEAR
	anim.play("Stand_Do_Nothing")
	skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	feet = [skeleton.find_bone("LEFT_FOOT"), skeleton.find_bone("RIGHT_FOOT")]
	_hang_tie.call_deferred()
	for k in 6:
		steps["snow"].append(load("res://imported/sounds/Step_SnowNew_%02d.wav" % (k + 1)))
		steps["concrete"].append(load("res://imported/sounds/Step_Concrete_%02d.wav" % (k + 1)))
	step_player = AudioStreamPlayer3D.new()
	step_player.max_polyphony = 4
	add_child(step_player)
	yaw = OS.get_environment("HITMAN_YAW").to_float()
	var walk := OS.get_environment("HITMAN_AUTOWALK").split("@")
	if not walk[0].is_empty():
		autowalk = Vector2(walk[1].to_float() if walk.size() > 1 else 0.0, walk[0].to_float())

	if not InputMap.has_action("interact"):
		InputMap.add_action("interact")
		var e := InputEventKey.new()
		e.physical_keycode = KEY_E
		InputMap.action_add_event("interact", e)
	for tap in OS.get_environment("HITMAN_KEYS").split(",", false):
		var parts := tap.split("@")
		if parts.size() == 2 and parts[0].to_upper() == "E":
			key_taps.append(parts[1].to_float())
	_prompt_ui()

	pivot = Node3D.new()
	pivot.position.y = EYE_HEIGHT
	add_child(pivot)
	arm = SpringArm3D.new()
	arm.spring_length = CAMERA_DISTANCE
	var probe := SphereShape3D.new()
	probe.radius = 0.2
	arm.shape = probe
	arm.add_excluded_object(get_rid())
	pivot.add_child(arm)
	camera = Camera3D.new()
	camera.fov = 45.0
	camera.far = 2000.0
	camera.position.x = CAMERA_SHOULDER
	arm.add_child(camera)


## 47's tie, a separate object in the original (see the exporter's `tie`), hung from his chest
## bone at the knot, leaning forward over his shirt.
func _hang_tie() -> void:
	if not ResourceLoader.exists(TIE):
		return
	await get_tree().process_frame
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TIE_META))
	var chest := BoneAttachment3D.new()
	chest.bone_name = "SPINE_1"
	skeleton.add_child(chest)
	tie = Node3D.new()
	chest.add_child(tie)
	var lean := atan(float(meta["lean"]))
	tie.global_transform = model.global_transform * Transform3D(Basis(Vector3.RIGHT, lean), Vector3(0.0, meta["knot_height"], -float(meta["knot_front"])))
	tie_rest = tie.basis
	tie.add_child((load(TIE) as PackedScene).instantiate())
	tie_last_pos = global_position


## A damped spring tips the tie against his acceleration: it trails when he sets off and swings
## forward when he stops or turns.
func _swing_tie(dt: float) -> void:
	if tie == null or dt <= 0.0:
		return
	var vel := (global_position - tie_last_pos) / dt
	var accel := ((vel - tie_last_vel) / dt).limit_length(30.0)
	tie_last_pos = global_position
	tie_last_vel = vel
	var fwd := -model.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var target := Vector2(accel.dot(fwd), accel.dot(right)) * TIE_TIP
	tie_rate += ((target - tie_angle) * TIE_STIFFNESS - tie_rate * TIE_DAMPING) * dt
	tie_angle = (tie_angle + tie_rate * dt).clamp(Vector2(-TIE_MAX, -TIE_MAX), Vector2(TIE_MAX, TIE_MAX))
	var swing := Basis(right, tie_angle.x) * Basis(fwd, -tie_angle.y)
	var chest := (tie.get_parent() as Node3D).global_basis.orthonormalized()
	tie.basis = chest.inverse() * swing * chest * tie_rest


func _prompt_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	prompt_label = Label.new()
	prompt_label.add_theme_font_override("font", load("res://fonts/Michroma-Regular.ttf"))
	prompt_label.add_theme_font_size_override("font_size", 18)
	prompt_label.add_theme_color_override("font_color", Color(0.85, 0.9, 0.92, 0.9))
	prompt_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	prompt_label.offset_top = -90.0
	prompt_label.offset_bottom = -60.0
	prompt_label.offset_left = -400.0
	prompt_label.offset_right = 400.0
	layer.add_child(prompt_label)


## Whether E was tapped this frame (keyboard, or a scripted `HITMAN_KEYS` tap).
func interact_pressed() -> bool:
	if Input.is_action_just_pressed("interact"):
		return true
	for t in key_taps:
		if clock >= t and clock - get_physics_process_delta_time() < t:
			return true
	return false


## W (+1) or S (−1) held, for climbing (a scripted `HITMAN_AUTOWALK` counts as W).
func climb_input() -> float:
	var v := 0.0
	if Input.is_physical_key_pressed(KEY_W):
		v += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		v -= 1.0
	if autowalk.x >= 0.0 and clock >= autowalk.x and clock < autowalk.x + autowalk.y:
		v = 1.0
	return v


func make_current() -> void:
	camera.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _notification(what: int) -> void:
	# Back in the game window: take the mouse again.
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and camera and camera.current:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventKey and event.pressed and event.keycode == KEY_F11:
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * MOUSE_SENSITIVITY
		pitch = clampf(pitch - event.relative.y * MOUSE_SENSITIVITY, -1.3, 0.9)


func _physics_process(dt: float) -> void:
	var input := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		input.y += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		input.y -= 1.0
	if Input.is_physical_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		input.x += 1.0
	clock += dt
	# Offers (doors, ladders) run after 47 in the tree and set it again while they apply.
	prompt = ""
	if held:
		velocity = Vector3.ZERO
		return
	var scripted := autowalk.x >= 0.0 and clock >= autowalk.x and clock < autowalk.x + autowalk.y
	if scripted:
		input.y = 1.0
	sneaking = Input.is_physical_key_pressed(KEY_CTRL)
	var running := (Input.is_physical_key_pressed(KEY_SHIFT) or (scripted and not OS.get_environment("HITMAN_AUTORUN").is_empty())) and not sneaking
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(-forward.z, 0.0, forward.x)
	var wish := (forward * input.y + right * input.x).normalized()
	var speed := SNEAK_SPEED if sneaking else (RUN_SPEED if running else WALK_SPEED)

	velocity.x = wish.x * speed
	velocity.z = wish.z * speed
	velocity.y = 0.0 if is_on_floor() else velocity.y - GRAVITY * dt
	var was_on_floor := is_on_floor()
	var before := global_position
	move_and_slide()
	if was_on_floor and wish != Vector3.ZERO:
		_step_up(before, wish * speed * dt)

	if OS.get_environment("HITMAN_TRACE") != "" and int(clock * 60.0) % 60 == 0:
		print("trace t=%.1f pos=%s vel=%s floor=%s wish=%s" % [clock, position, velocity, is_on_floor(), wish])
	if wish != Vector3.ZERO:
		var target := atan2(-wish.x, -wish.z)
		model.rotation.y = lerp_angle(model.rotation.y, target, minf(TURN_RATE * dt, 1.0))
	var moving := Vector2(velocity.x, velocity.z).length() if wish != Vector3.ZERO else 0.0
	_animate(moving, running)
	_footsteps(dt, moving, running)


## Up a stair or over a hump: when the slide left him short of where he meant to go, try the
## same move from `STEP_HEIGHT` higher and settle onto what's there, if it's walkable floor.
## Only ledges: a wall or anything taller than a stair still stops him.
func _step_up(before: Vector3, motion: Vector3) -> void:
	var moved := global_position - before
	moved.y = 0.0
	if moved.length() > motion.length() * 0.7:
		return
	var from := global_transform
	from.origin = before
	var col := KinematicCollision3D.new()
	# Headroom first: no stepping into a ceiling.
	var rise := Vector3.UP * STEP_HEIGHT
	if test_move(from, rise, col):
		rise = col.get_travel()
	var up := from.translated(rise)
	if test_move(up, motion):
		return
	var over := up.translated(motion)
	if not test_move(over, -rise - Vector3.UP * 0.05, col):
		return
	# The capsule's round bottom meets a stair's lip at a steep angle, so judge the floor by
	# what's under the tread just ahead instead of by that contact.
	var ahead := before + motion.normalized() * (capsule_radius + 0.05)
	var top := before.y + rise.y + 0.05
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(ahead.x, top, ahead.z), Vector3(ahead.x, before.y - 0.05, ahead.z), 0xFFFFFFFF, [get_rid()]))
	if hit.is_empty() or hit["normal"].angle_to(Vector3.UP) > floor_max_angle:
		return
	var land := over.origin + col.get_travel()
	if land.y - before.y < 0.02:
		return
	step_lag += land.y - global_position.y
	global_position = land
	apply_floor_snap()


## A step sounds when a foot comes down to the lowest height it reaches (tracked per foot), so it
## lands with the foot at any speed.
func _footsteps(dt: float, speed: float, running: bool) -> void:
	for k in 2:
		var h := (skeleton.global_transform * skeleton.get_bone_global_pose(feet[k])).origin.y - global_position.y
		foot_low[k] = h if h < foot_low[k] else foot_low[k] + 0.05 * dt
		if h > foot_low[k] + LIFT:
			foot_lifted[k] = true
		if foot_lifted[k] and h < foot_low[k] + PLANT:
			foot_lifted[k] = false
			if speed > 0.2:
				_step(running)


func _step(running: bool) -> void:
	var space := get_world_3d().direct_space_state
	var roof := space.intersect_ray(PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 2.0, global_position + Vector3.UP * 14.0, 0xFFFFFFFF, [get_rid()]))
	var outdoors := roof.is_empty()
	var set: Array = steps["snow" if outdoors else "concrete"]
	step_variant = (step_variant * 7 + 3) % 997
	var volume: float = STEP_VOLUME["sneak" if sneaking else ("run" if running else "walk")] * (SNOW_GAIN if outdoors else 1.0)
	step_player.stream = set[step_variant % set.size()]
	step_player.volume_db = linear_to_db(volume) + 12.0
	step_player.play()
	if not OS.get_environment("HITMAN_TRACE").is_empty():
		print("step t=%.2f %s vol=%.3f" % [clock, "snow" if outdoors else "concrete", volume])


func _process(dt: float) -> void:
	prompt_label.text = prompt
	_swing_tie(dt)
	step_lag = move_toward(step_lag * exp(-STEP_SMOOTH * dt), 0.0, 0.0005)
	model.position.y = -step_lag
	pivot.position.y = lerpf(pivot.position.y + step_lag, CROUCH_EYE_HEIGHT if sneaking else EYE_HEIGHT, 0.1) - step_lag
	pivot.rotation = Vector3(pitch, yaw, 0.0)


## Picks the clip for how he moves, and plays it at the rate that matches its root speed.
func _animate(speed: float, running: bool) -> void:
	var clip := "Stand_Do_Nothing"
	if speed < 0.2:
		clip = "Sneak_Ambient" if sneaking else "Stand_Do_Nothing"
	elif sneaking:
		clip = "Sneak_Forward"
	elif running:
		clip = "Run"
	else:
		clip = "Walk_Forward"
	var root_speed: float = clips.get(clip, {}).get("root_speed", 0.0)
	var rate := speed / root_speed if root_speed > 0.01 else 1.0
	if anim.current_animation != clip:
		anim.play(clip, BLEND)
	anim.speed_scale = rate
