class_name Ragdoll
extends RefCounted
## Builds a ragdoll on a character's skeleton out of Godot's own physical bones (a
## `PhysicalBoneSimulator3D` with a `PhysicalBone3D` per body part, simulated by Jolt), as the
## Bevy project's `ragdoll.rs` does with Rapier: capsules from each bone to the next, joints
## that bend within human limits. The dead go limp; a limb can be pulled to drag the body.
##
## (The skeleton is in centimetres under the model's 0.01 scale; the shapes are sized to match.)

## Body part: bone, the bone it reaches towards, capsule radius (cm).
const PARTS := [
	["PELVIS", "SPINE_1", 15.0],
	["SPINE_1", "NECK", 16.0],
	["HEAD", "", 11.0],
	["LEFT_UPPER_ARM", "LEFT_FOREARM", 5.5],
	["LEFT_FOREARM", "LEFT_HAND", 4.5],
	["RIGHT_UPPER_ARM", "RIGHT_FOREARM", 5.5],
	["RIGHT_FOREARM", "RIGHT_HAND", 4.5],
	["LEFT_THIGH", "LEFT_CALF", 8.0],
	["LEFT_CALF", "LEFT_FOOT", 6.0],
	["RIGHT_THIGH", "RIGHT_CALF", 8.0],
	["RIGHT_CALF", "RIGHT_FOOT", 6.0],
]
const LAYER := 8


## Adds the ragdoll (inactive) and returns its simulator.
static func build(skel: Skeleton3D) -> PhysicalBoneSimulator3D:
	var sim := PhysicalBoneSimulator3D.new()
	skel.add_child(sim)
	for part: Array in PARTS:
		var bone := skel.find_bone(part[0])
		if bone < 0:
			continue
		var pose := skel.get_bone_global_rest(bone)
		var to := Vector3(0.0, 20.0, 0.0)
		if part[1] != "":
			var child := skel.find_bone(part[1])
			if child >= 0:
				to = pose.affine_inverse() * skel.get_bone_global_rest(child).origin
		var length := maxf(to.length(), 1.0)
		var y := to.normalized()
		var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
		var offset := Transform3D(Basis(x, y, x.cross(y)), to * 0.5)
		var pb := PhysicalBone3D.new()
		pb.name = "Phys_" + part[0]
		pb.bone_name = part[0]
		pb.body_offset = offset
		pb.joint_offset = offset.affine_inverse()
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE if part[0] != "PELVIS" else PhysicalBone3D.JOINT_TYPE_NONE
		pb.set("joint_constraints/swing_span", 50.0)
		pb.set("joint_constraints/twist_span", 25.0)
		pb.mass = 8.0 if part[0] in ["PELVIS", "SPINE_1"] else 3.0
		pb.collision_layer = LAYER
		pb.collision_mask = 1
		pb.linear_damp = 0.2
		pb.angular_damp = 1.5
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = part[2]
		capsule.height = maxf(length + part[2], part[2] * 2.0 + 0.1)
		shape.shape = capsule
		pb.add_child(shape)
		sim.add_child(pb)
	return sim


static func go_limp(sim: PhysicalBoneSimulator3D, push: Vector3 = Vector3.ZERO) -> void:
	sim.active = true
	sim.physical_bones_start_simulation()
	if push != Vector3.ZERO:
		for pb in sim.get_children():
			if pb is PhysicalBone3D and String(pb.name) in ["Phys_SPINE_1", "Phys_HEAD"]:
				(pb as PhysicalBone3D).apply_central_impulse(push)


static func part(sim: PhysicalBoneSimulator3D, bone: String) -> PhysicalBone3D:
	return sim.get_node_or_null("Phys_" + bone) as PhysicalBone3D
