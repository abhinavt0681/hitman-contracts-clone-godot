class_name Ladders
extends Node3D
## Ladders: 47 climbs up and down the level's ladders (E at either end). Ported from the Bevy
## project's `ladder.rs`, whose measurements this keeps.
##
## Each ladder comes from one of the level's guide entities (class `0x4000022`,
## `LadderSub_T1Guide`, `MountainLadder_T1Guide_01`…): an invisible box from the foot of the
## ladder to the top, exported to `C02-1_ladders.json` with the rungs' line from the ladder mesh
## standing in it. The guide doesn't say which side is climbed, so that comes from the level's
## collision: the side with ground at the bottom faces the side with a landing at the top.
##
## E at either end gets on; W climbs up and S down (let go and he hangs there); climbing past
## the top carries him over onto the landing, past the foot steps him off.
##
## The climb plays 47's original `Climb_Ladder`: frames 0–23 are the climbing stroke (frame 23
## matches frame 0, the root 50 cm higher), frames 23–57 the climb over the top (another
## 150.65 cm). Strokes loop on the way; the climb-over plays once at the top (backwards when
## getting on to climb down). The exporter drops the clip's root motion; this lifts him at the
## clip's own rate, so hands and feet stay on the rungs.

const LADDERS := "res://imported/level/C02-1_ladders.json"
const CLIP := "Climb_Ladder"
const FPS := 30.0
const STROKE := Vector2(0.0, 23.0)
const OVER := Vector2(23.0, 57.0)
const CLIMB_SPEED := 0.50 / (23.0 / 30.0)
const OVER_RISE := 1.5065
const OVER_SECONDS := 34.0 / 30.0
## How far from the ladder 47 hangs, and where he stands at either end (m).
const HANG := 0.32
const STAND := 0.6
## Within this of a ladder's end (m, horizontally; 1 m vertically), E climbs it.
const REACH := 1.2
## How far a guide's box sits above the floors it joins: measured on the submarine ladder
## (guide −2.6…0.9 m, ice −3.7, deck −0.2) and the tunnel shaft (−8.0…1.25, floors −9.1, 0.15).
const GUIDE_LIFT := 1.1
const STEP_ON := 0.35
const STEP_OFF := 0.5

enum Stage { ON, CLIMB, OVER, OFF }

class Ladder:
	var name: String
	## The rungs' line at the foot, its horizontal drift per metre up, and the way 47 faces.
	var centre: Vector3
	var lean: Vector3
	var face: Vector3
	var bottom: float
	var top: float

	func hang(y: float) -> Vector3:
		var p := centre + lean * (y - bottom) - face * HANG
		return Vector3(p.x, y, p.z)

	func foot() -> Vector3:
		var p := centre - face * STAND
		return Vector3(p.x, bottom, p.z)

	func landing() -> Vector3:
		var p := centre + lean * (top - bottom) + face * STAND
		return Vector3(p.x, top, p.z)

var ladders: Array[Ladder] = []
var player: Player
## The climb in progress (`ladder` < 0 when none).
var ladder := -1
var up := true
var stage := Stage.ON
var from := Vector3.ZERO
var t := 0.0
var clip_time := 0.0
var exclude: Array[RID] = []


func _ready() -> void:
	# The sides are found with the level's collision: wait for it.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	# The level only: 47 standing at a ladder must not count as a wall or a floor.
	var me := get_parent().get_node_or_null("Player") as CollisionObject3D
	if me:
		exclude.append(me.get_rid())
	for g: Dictionary in JSON.parse_string(FileAccess.get_file_as_string(LADDERS)):
		var lo := _v(g["min"])
		var hi := _v(g["max"])
		var name: String = g["name"]
		if not name.contains("Guide") or hi.y - lo.y < 1.0:
			continue
		var centre := Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.z + hi.z) * 0.5)
		var lean := Vector3.ZERO
		var sides: Array[Vector3] = []
		var rail = g["rail"]
		if rail != null and _v(rail["high"]).y - _v(rail["low"]).y > 0.3:
			var rl := _v(rail["low"])
			var rh := _v(rail["high"])
			lean = Vector3(rh.x - rl.x, 0.0, rh.z - rl.z) / (rh.y - rl.y)
			var normal := _v(rail["across"]).cross(Vector3.UP).normalized()
			var c := rl - lean * (rl.y - (lo.y - GUIDE_LIFT))
			centre = Vector3(c.x, 0.0, c.z)
			sides = [normal, -normal]
		else:
			for k in 16:
				var a := k * TAU / 16.0
				sides.append(Vector3(cos(a), 0.0, sin(a)))
		var bot := lo.y - GUIDE_LIFT
		var tip := hi.y - GUIDE_LIFT
		var best: Array = []
		for d in sides:
			var top = _floor_near(space, centre + lean * (tip - bot) + d * (STAND + 0.3), tip)
			var bottom = _floor_near(space, centre - d * (STAND + 0.1), bot)
			if top == null or bottom == null:
				continue
			# The climbing side must be open at chest height.
			var chest := centre - d * 0.1
			chest.y = bottom + 1.3
			if not space.intersect_ray(PhysicsRayQueryParameters3D.create(chest, chest - d * (STAND + 0.2), 1, exclude)).is_empty():
				continue
			var skew := 1.0 - maxf(absf(d.x), absf(d.z))
			var score: float = absf(top - tip) + absf(bottom - bot) + 0.05 * skew
			if best.is_empty() or score < best[3]:
				best = [d, bottom, top, score]
		if best.is_empty():
			push_warning("ladder %s: no foot and landing found; not climbable" % name)
			continue
		var l := Ladder.new()
		l.name = name
		l.centre = centre
		l.lean = lean
		l.face = best[0]
		l.bottom = best[1]
		l.top = best[2]
		ladders.append(l)
		print("ladder %s: %.1f m, foot %.2f top %.2f at %s facing %s" % [name, l.top - l.bottom, l.bottom, l.top, centre, l.face])


func _v(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


## Floor height near `y` under a point, if any.
func _floor_near(space: PhysicsDirectSpaceState3D, p: Vector3, y: float) -> Variant:
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p.x, y + 1.2, p.z), Vector3(p.x, y - 1.2, p.z), 1, exclude))
	if hit.is_empty() or (hit["normal"] as Vector3).y < 0.6:
		return null
	var f: float = (hit["position"] as Vector3).y
	return f if absf(f - y) < 0.4 else null


func _physics_process(dt: float) -> void:
	if player == null:
		player = get_parent().get_node_or_null("Player") as Player
		if player == null:
			return
	if ladder < 0:
		_offer()
	else:
		_climb(dt)


## E at either end of a ladder starts the climb.
func _offer() -> void:
	if player.held:
		return
	var me := player.global_position
	for i in ladders.size():
		var l := ladders[i]
		var going_up: bool
		if _near(me, l.foot()):
			going_up = true
		elif _near(me, l.landing()):
			going_up = false
		else:
			continue
		player.prompt = "[E]  Climb up the ladder" if going_up else "[E]  Climb down the ladder"
		if player.interact_pressed():
			ladder = i
			up = going_up
			stage = Stage.ON
			from = me
			t = 0.0
			player.held = true
			print("climbing %s %s" % ["up" if up else "down", l.name])
		return


func _near(me: Vector3, p: Vector3) -> bool:
	return Vector2(me.x - p.x, me.z - p.z).length() < REACH and absf(me.y - p.y) < 1.0


## Holds `Climb_Ladder` at `frame`. No cross-fade: Godot advances a blend with the playback
## speed, and at speed 0 (posing by hand) it never got past the standing pose.
func _pose(frame: float) -> void:
	if player.anim.current_animation != CLIP:
		player.anim.play(CLIP, 0.0)
	player.anim.speed_scale = 0.0
	player.anim.seek(frame / FPS, true)


func _climb(dt: float) -> void:
	var l := ladders[ladder]
	t += dt
	# Facing the ladder; the camera swings round behind him.
	player.model.rotation.y = atan2(-l.face.x, -l.face.z)
	player.yaw = lerp_angle(player.yaw, atan2(-l.face.x, -l.face.z), minf(4.0 * dt, 1.0))
	var over_low := maxf(l.top - OVER_RISE, l.bottom)
	match stage:
		Stage.ON:
			var start := l.hang(l.bottom) if up else l.hang(l.top)
			# Getting on from the top is the climb-over backwards, from its last frame.
			_pose(STROKE.x if up else OVER.y)
			var k := minf(t / STEP_ON, 1.0)
			player.global_position = from.lerp(start, k)
			if k >= 1.0:
				_next(Stage.CLIMB if up else Stage.OVER)
		Stage.CLIMB:
			# W climbs up, S down; let go and he hangs where he is.
			var rate := player.climb_input()
			clip_time = fposmod(clip_time + rate * dt * FPS, STROKE.y - STROKE.x)
			_pose(STROKE.x + clip_time)
			var y := clampf(player.global_position.y + rate * CLIMB_SPEED * dt, l.bottom, over_low)
			player.global_position = l.hang(y)
			if rate > 0.0 and y >= over_low:
				up = true
				_next(Stage.OVER)
			elif rate < 0.0 and y <= l.bottom:
				up = false
				_next(Stage.OFF)
		Stage.OVER:
			var k := minf(t / OVER_SECONDS, 1.0)
			_pose(lerpf(OVER.x, OVER.y, k if up else 1.0 - k))
			player.global_position = l.hang(lerpf(over_low, l.top, k) if up else lerpf(l.top, over_low, k))
			if k >= 1.0:
				if up or over_low <= l.bottom:
					_next(Stage.OFF)
				else:
					clip_time = 0.0
					_next(Stage.CLIMB)
		Stage.OFF:
			var end := l.landing() if up else l.foot()
			var k := minf(t / STEP_OFF, 1.0)
			player.global_position = from.lerp(end, k)
			if k >= 1.0:
				ladder = -1
				player.held = false
				player.anim.speed_scale = 1.0
				player.anim.play("Stand_Do_Nothing", 0.2)


func _next(s: Stage) -> void:
	stage = s
	from = player.global_position
	t = 0.0
