class_name AimPose
extends SkeletonModifier3D
## Holds an upper-body pose sampled from one frame of a clip (`UB_Aim_Gun`, `UB_Hold_Gun…`,
## `UB_Aim_Rifle`) over whatever the body's animation is doing, so the legs keep walking while
## the arms aim. Godot runs modifiers after the AnimationPlayer; `influence` fades it in and out.
## (As the Bevy project, the aim clips are held at the frame that points straight ahead:
## `WeaponDef::aim_frame`.)

var poses: Dictionary = {}
## Extra pitch for the spine (radians), so the gun follows the camera up and down.
var pitch := 0.0
var spine := -1


## Samples `clip` at `seconds` for the bones it really animates, `only` (from the exporter's
## clip list: Godot's importer fills every bone into every clip at rest, which would force the
## rest of the body into a T-pose).
func set_clip(anim: Animation, seconds: float, only: Array) -> void:
	poses.clear()
	var skel := get_skeleton()
	if skel == null or anim == null:
		return
	for t in anim.get_track_count():
		if anim.track_get_type(t) != Animation.TYPE_ROTATION_3D:
			continue
		var bone := skel.find_bone(String(anim.track_get_path(t).get_concatenated_subnames()))
		if bone < 0 or not only.has(skel.get_bone_name(bone)):
			continue
		poses[bone] = anim.rotation_track_interpolate(t, seconds)
	spine = skel.find_bone("SPINE_2")


func _process_modification() -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	for bone: int in poses:
		skel.set_bone_pose_rotation(bone, poses[bone])
	if spine >= 0 and absf(pitch) > 0.001:
		# Bend the chest about the character's sideways axis, in the bone's own frame.
		var rest := skel.get_bone_global_pose(spine).basis
		var side := rest.inverse() * (skel.global_basis.inverse() * skel.global_basis.x).normalized()
		skel.set_bone_pose_rotation(spine, skel.get_bone_pose_rotation(spine) * Quaternion(side.normalized(), pitch))
