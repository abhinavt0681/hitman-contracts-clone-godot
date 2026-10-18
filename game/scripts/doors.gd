class_name Doors
extends Node3D
## The level's doors: leaves that swing on their hinges, away from whoever opens them.
##
## The level has no door class. Doors are ordinary geometry (`Door_…`, `FenceDoor…`), double
## doors `DDoor…` groups of `D…` leaves; the exporter lists them in `C02-1_doors.json` and keeps
## them out of the static collision. Every leaf's origin is its hinge (a standard leaf is 1 m
## wide and 2.3 m tall, extending from it along one horizontal axis).
##
## Each leaf becomes an `AnimatableBody3D` at its hinge carrying the leaf mesh and a box shape:
## Godot's body for doors, moved in the physics step, pushing characters aside as it swings.
## (A body parented under a separately swinging node stays behind: only a body whose own
## transform changes is synced.) Doors sit on collision layer `LAYER`, which 47 collides with.
##
## The level places some doors open. A leaf's closed pose is found from the level around it:
## the direction (of its current one, ±90° and 180°) in which its tip meets the jamb a leaf's
## width away and the wall carries on behind the hinge. A leaf placed away from that starts
## open, at its authored angle.
##
## E within reach of the doorway opens or closes it, from either side. It swings away from the
## opener unless that way is blocked (a wall, furniture), then the other way. An open door left
## alone for `AUTO_CLOSE` seconds swings shut, never onto anyone. (Assumption: the original's
## timings aren't decoded yet.) Guards (to come) use `open(door, by)` too.

const DOORS := "res://imported/level/C02-1_doors.json"
## `Barracks_Dooor` is a 4 × 4 m block, not a hinged leaf.
const NOT_LEAVES := ["Barracks_Doo"]
const LAYER := 2
const OPEN_ANGLE := deg_to_rad(88.0)
const SWING_SECONDS := 0.9
## E uses a door within this of its doorway's middle (m, horizontally; 1.5 m vertically), or
## within `LEAF_REACH` of an open leaf's middle.
const REACH := 2.2
const LEAF_REACH := 1.5
const AUTO_CLOSE := 6.0

class Leaf:
	var body: AnimatableBody3D
	## The hinge's closed pose, and the leaf's half-width vector from the hinge when closed.
	var closed: Basis
	var reach: Vector3
	var box: BoxShape3D
	var box_at: Vector3

class Door:
	var name: String
	var leaves: Array[Leaf] = []
	## The doorway's middle, 1 m up.
	var centre: Vector3
	## 0 closed … 1 open, its target, and each leaf's swing direction for this opening.
	var progress := 0.0
	var target := 0.0
	var signs: Array[float] = []
	var idle := 0.0
	var metal := false
	var sound: AudioStreamPlayer3D

var doors: Array[Door] = []
var player: Player
var ready_done := false


func _ready() -> void:
	var level := get_parent().find_child("Level", true, false)
	var by_door := {}
	for d: Dictionary in JSON.parse_string(FileAccess.get_file_as_string(DOORS)):
		var node: String = d["node"]
		if NOT_LEAVES.any(func(n: String) -> bool: return node.begins_with(n)):
			continue
		var mi := level.find_child(node, true, false) as MeshInstance3D
		if mi == null:
			push_warning("door leaf %s not found" % node)
			continue
		var group: String = d["door"]
		if not by_door.has(group):
			var door := Door.new()
			door.name = group.get_slice("@", 0)
			door.metal = door.name.begins_with("Fence")
			by_door[group] = door
			doors.append(door)
		(by_door[group] as Door).leaves.append(_leaf(mi))
	# The closed poses come from the level's collision: wait for it.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var authored_open := 0
	for door in doors:
		door.signs.resize(door.leaves.size())
		var open_angle := 0.0
		var hung := door.leaves.size() == 2 and OS.get_environment("HITMAN_DOOR_ASIS") == "" and _hang_in_cavity(door)
		for i in door.leaves.size():
			var angle := 0.0 if hung else _find_closed(door.leaves[i])
			door.signs[i] = signf(angle) if absf(angle) > 0.01 else 1.0
			open_angle = maxf(open_angle, absf(angle))
		var c := Vector3.ZERO
		for leaf in door.leaves:
			c += leaf.body.global_position + leaf.reach
		door.centre = c / door.leaves.size() + Vector3.UP * 1.0
		if open_angle > deg_to_rad(20.0):
			# Placed open: it stays as the level has it until someone closes it.
			door.progress = minf(open_angle / OPEN_ANGLE, 1.0)
			door.target = door.progress
			authored_open += 1
		_pose(door)
		door.sound = AudioStreamPlayer3D.new()
		door.sound.position = door.centre
		door.sound.unit_size = 4.0
		add_child(door.sound)
	ready_done = true
	if OS.get_environment("HITMAN_DOOR_LIST") != "":
		for door in doors:
			print("door %s at %s progress %.2f" % [door.name, door.centre.snapped(Vector3.ONE * 0.1), door.progress])
			for leaf in door.leaves:
				print("   leaf hinge %s reach %s" % [leaf.body.global_position.snapped(Vector3.ONE * 0.01), leaf.reach.snapped(Vector3.ONE * 0.01)])
	print("doors: %d (%d leaves), %d placed open" % [doors.size(), doors.reduce(func(n: int, d: Door) -> int: return n + d.leaves.size(), 0), authored_open])


## A clean (unscaled, unmirrored) body at the leaf's hinge, carrying the mesh and a box shape.
func _leaf(mi: MeshInstance3D) -> Leaf:
	var t := mi.global_transform
	var aabb := mi.get_aabb()
	var corners: Array[Vector3] = []
	for k in 8:
		corners.append(t * (aabb.position + aabb.size * Vector3(k & 1, (k >> 1) & 1, (k >> 2) & 1)))
	var lo := corners[0]
	var hi := corners[0]
	for c in corners:
		lo = lo.min(c)
		hi = hi.max(c)
	var middle := (lo + hi) * 0.5
	if OS.get_environment("HITMAN_DOOR_LIST") != "" and String(mi.name).begins_with("D"):
		print("  %s origin %s aabb %s world lo %s hi %s basis x %s z %s" % [mi.name, t.origin.snapped(Vector3.ONE * 0.01), aabb, lo.snapped(Vector3.ONE * 0.01), hi.snapped(Vector3.ONE * 0.01), t.basis.x.snapped(Vector3.ONE * 0.001), t.basis.z.snapped(Vector3.ONE * 0.001)])
	var out := Vector3(middle.x - t.origin.x, 0.0, middle.z - t.origin.z)
	var body := AnimatableBody3D.new()
	# Not synced to physics: a synced body snaps back when moved outside its own motion, which
	# put doors at the origin and kept re-hung leaves where they were.
	body.sync_to_physics = false
	body.collision_layer = LAYER
	body.collision_mask = 0
	# Placed before it enters the tree: an `AnimatableBody3D` (synced to physics) moved just
	# after entering it snaps back to where it entered, which put every door at the origin.
	body.transform = Transform3D(Basis.looking_at(out.normalized() if out.length() > 0.05 else Vector3.FORWARD, Vector3.UP), t.origin)
	add_child(body)
	mi.reparent(body, true)
	var plo := Vector3.INF
	var phi := -Vector3.INF
	for c in corners:
		var p := body.global_transform.affine_inverse() * c
		plo = plo.min(p)
		phi = phi.max(p)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = (phi - plo).max(Vector3(0.05, 0.05, 0.05))
	shape.shape = box
	shape.position = (plo + phi) * 0.5
	body.add_child(shape)
	var leaf := Leaf.new()
	leaf.body = body
	leaf.closed = body.basis
	leaf.reach = out
	leaf.box = box
	leaf.box_at = shape.position
	return leaf


## Works out the leaf's closed pose; returns the angle it's placed open by (0 if closed).
func _find_closed(leaf: Leaf) -> float:
	var space := get_world_3d().direct_space_state
	var hinge := leaf.body.global_position + Vector3.UP * 1.2
	var width := leaf.reach.length() * 2.0
	var best_angle := 0.0
	var best_score := INF
	for angle: float in [0.0, PI * 0.5, -PI * 0.5, PI]:
		var dir := leaf.reach.normalized().rotated(Vector3.UP, angle)
		var tip := _ray(space, hinge + dir * 0.1, dir, width + 0.5)
		var back := _ray(space, hinge + dir * 0.05, -dir, 0.6)
		if tip < 0.0 or back < 0.0:
			continue
		var score := absf(tip + 0.1 - width) + back * 0.5
		if score < best_score and absf(tip + 0.1 - width) < 0.35:
			best_score = score
			best_angle = angle
	if best_angle != 0.0:
		# The leaf was placed open by −best_angle from its closed pose.
		leaf.closed = leaf.closed.rotated(Vector3.UP, best_angle)
		leaf.reach = leaf.reach.rotated(Vector3.UP, best_angle)
	return -best_angle


## Double doors: the level's own placement of their leaves can't be trusted (in some groups the
## leaves stand across the opening rather than in it). The opening is found from the wall
## instead: from the doorway's middle, the horizontal direction in which both jambs are met,
## between them as wide as the two leaves. Each leaf is then hung from the jamb nearer it,
## closed into the opening. Returns false (leaving the leaves as placed) if no opening is found.
func _hang_in_cavity(door: Door) -> bool:
	var space := get_world_3d().direct_space_state
	var a := door.leaves[0]
	var b := door.leaves[1]
	var centre := (a.body.global_position + b.body.global_position) * 0.5 + Vector3.UP * 1.2
	var span := (a.reach.length() + b.reach.length()) * 2.0
	var best := INF
	var wall := Vector3.ZERO
	var half := Vector2.ZERO
	for k in 24:
		var d := Vector3.FORWARD.rotated(Vector3.UP, k * PI / 24.0)
		var one := _ray(space, centre, d, span)
		var two := _ray(space, centre, -d, span)
		if one < 0.0 or two < 0.0:
			continue
		var error := absf(one + two - span)
		if error < best and error < 0.5:
			best = error
			wall = d
			half = Vector2(one, two)
	if wall == Vector3.ZERO:
		push_warning("double door %s: no opening found around it" % door.name)
		return false
	var floor_y := a.body.global_position.y
	if OS.get_environment("HITMAN_DOOR_LIST") != "":
		var n := wall.cross(Vector3.UP)
		print("cavity %s centre %s wall %s jambs %.2f %.2f normal %s" % [door.name, centre.snapped(Vector3.ONE * 0.01), wall.snapped(Vector3.ONE * 0.01), half.x, half.y, n.snapped(Vector3.ONE * 0.01)])
	var jambs := [centre + wall * half.x, centre - wall * half.y]
	var first_near_a: bool = a.body.global_position.distance_to(Vector3(jambs[0].x, floor_y, jambs[0].z)) <= a.body.global_position.distance_to(Vector3(jambs[1].x, floor_y, jambs[1].z))
	for i in 2:
		var leaf := door.leaves[i]
		var near_first := (i == 0) == first_near_a
		var jamb: Vector3 = jambs[0] if near_first else jambs[1]
		var half_width: float = half.x if near_first else half.y
		var inward := Vector3(centre.x - jamb.x, 0.0, centre.z - jamb.z).normalized()
		# Hung at its jamb and stretched along its width to half the opening (a few per cent:
		# the leaves are ~0.97 m, the openings 2 m), so it's flush at the jamb and meets its
		# partner in the middle (1 cm overlap).
		var tip := -(leaf.box_at.z - leaf.box.size.z * 0.5)
		var stretch := (half_width + 0.01) / tip
		var mesh := leaf.body.get_child(0) as Node3D
		mesh.transform = Transform3D(Basis.from_scale(Vector3(1.0, 1.0, stretch)), Vector3.ZERO) * mesh.transform
		leaf.box.size.z *= stretch
		leaf.box_at.z *= stretch
		(leaf.body.get_child(1) as CollisionShape3D).position = leaf.box_at
		leaf.body.global_position = Vector3(jamb.x, floor_y, jamb.z)
		leaf.closed = Basis.looking_at(inward, Vector3.UP)
		leaf.body.basis = leaf.closed
		leaf.reach = inward * (half_width * 0.5)
	return true


## Distance to the level's static collision along a ray, or −1.
func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3, length: float) -> float:
	var me := get_parent().get_node_or_null("Player") as CollisionObject3D
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * length, 1, [me.get_rid()] if me else [])
	var hit := space.intersect_ray(q)
	return -1.0 if hit.is_empty() else from.distance_to(hit["position"])


func _pose(door: Door) -> void:
	var k := door.progress * door.progress * (3.0 - 2.0 * door.progress)
	for i in door.leaves.size():
		var leaf := door.leaves[i]
		leaf.body.basis = leaf.closed.rotated(Vector3.UP, door.signs[i] * OPEN_ANGLE * k)


## Whether a leaf's box swung by `angle` from closed would overlap the level (walls, furniture).
func _blocked(leaf: Leaf, angle: float) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var shrunk := BoxShape3D.new()
	# A little smaller, so the jamb and floor it already touches don't count.
	shrunk.size = leaf.box.size - Vector3(0.04, 0.15, 0.12)
	q.shape = shrunk
	q.collision_mask = 1
	for k: float in [0.5, 1.0]:
		var basis := leaf.closed.rotated(Vector3.UP, angle * k)
		var at := leaf.body.global_position + Vector3.UP * 0.05
		q.transform = Transform3D(basis, at + basis * leaf.box_at)
		if not space.intersect_shape(q, 1).is_empty():
			return true
	return false


## Opens a door away from `by` (where the opener stands), or the other way if that's blocked.
func open(door: Door, by: Vector3) -> void:
	if door.target > 0.5:
		return
	# Each leaf's swing away from the opener; the whole door turns back (every leaf together,
	# so double doors never split) only if that way is blocked for a leaf and the other way is
	# clear for all of them.
	var away: Array[float] = []
	var blocked := false
	var other_clear := true
	for leaf in door.leaves:
		var hinge := leaf.body.global_position
		var a := hinge + leaf.reach.rotated(Vector3.UP, OPEN_ANGLE)
		var b := hinge + leaf.reach.rotated(Vector3.UP, -OPEN_ANGLE)
		var sign := 1.0 if a.distance_to(by) > b.distance_to(by) else -1.0
		away.append(sign)
		blocked = blocked or _blocked(leaf, sign * OPEN_ANGLE)
		other_clear = other_clear and not _blocked(leaf, -sign * OPEN_ANGLE)
	var flip := -1.0 if blocked and other_clear else 1.0
	# Only a fully closed door may change its swing direction.
	if door.progress < 0.01:
		for i in door.leaves.size():
			door.signs[i] = away[i] * flip
	door.target = 1.0
	door.idle = 0.0
	_sound(door, true)


func close(door: Door) -> void:
	if door.target < 0.5:
		return
	door.target = 0.0
	_sound(door, false)


func _sound(door: Door, opening: bool) -> void:
	var file := ("Door_MetalOpen_01" if opening else "Door_MetalClosed_01") if door.metal else ("Door_WoodOpen_01" if opening else "Door_WoodClosed_01")
	var stream := load("res://imported/sounds/%s.wav" % file) as AudioStream
	if stream:
		door.sound.stream = stream
		door.sound.play()


## Whether 47 stands where a leaf sweeps (within its width of the hinge).
func _occupied(door: Door) -> bool:
	for leaf in door.leaves:
		var r := leaf.reach.length() * 2.0 + 0.4
		if Vector2(player.global_position.x - leaf.body.global_position.x, player.global_position.z - leaf.body.global_position.z).length() < r:
			return true
	return false


func _physics_process(dt: float) -> void:
	if not ready_done:
		return
	if player == null:
		player = get_parent().get_node_or_null("Player") as Player
		if player == null:
			return
		player.collision_mask |= LAYER
	var me := player.global_position + Vector3.UP * 1.0
	var nearest: Door = null
	var best := REACH
	for door in doors:
		var d := Vector2(door.centre.x - me.x, door.centre.z - me.z).length()
		var reach := d
		if door.progress > 0.5:
			for leaf in door.leaves:
				var mid := leaf.body.global_position + leaf.body.basis * Vector3(0.0, 0.0, -leaf.reach.length())
				reach = minf(reach, Vector2(mid.x - me.x, mid.z - me.z).length() * REACH / LEAF_REACH)
		if reach < best and absf(door.centre.y - me.y) < 1.5:
			best = reach
			nearest = door
		if not is_equal_approx(door.progress, door.target):
			door.progress = move_toward(door.progress, door.target, dt / SWING_SECONDS)
			_pose(door)
		if door.target > 0.5:
			door.idle = 0.0 if _occupied(door) or d < 3.0 else door.idle + dt
			if door.idle > AUTO_CLOSE:
				close(door)
	if OS.get_environment("HITMAN_DOOR_PROBE") != "" and nearest and player.clock > 2.0 and player.clock < 2.05:
		_probe(nearest)
	if nearest and not player.held:
		var shut := nearest.target < 0.5
		player.prompt = "[E]  Open door" if shut else "[E]  Close door"
		if player.interact_pressed():
			if shut:
				open(nearest, player.global_position)
			else:
				close(nearest)


## Debug (`HITMAN_DOOR_PROBE=1`): rays across a door's opening, logging what they hit.
func _probe(door: Door) -> void:
	var space := get_world_3d().direct_space_state
	for leaf in door.leaves:
		var mid: Vector3 = leaf.body.global_position + leaf.reach
		var across: Vector3 = leaf.reach.normalized().cross(Vector3.UP)
		for h: float in [0.3, 1.0, 1.7]:
			var a: Vector3 = mid + Vector3.UP * h + across * 1.5
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(a, mid + Vector3.UP * h - across * 1.5))
			print("probe h=%.1f hit=%s at %s" % [h, str((hit["collider"] as Node).name) if hit else "-", str(hit["position"]) if hit else ""])
		print("door %s hinge %s reach %s progress %.2f" % [door.name, leaf.body.global_position, leaf.reach, door.progress])
