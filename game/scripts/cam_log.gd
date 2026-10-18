## Debug (`HITMAN_CAMLOG=1`): logs the camera for the first seconds (jitter hunting).
extends Node
var t := 0.0
func _process(dt: float) -> void:
	t += dt
	var cam := get_viewport().get_camera_3d()
	var p := get_parent().get_node_or_null("Player") as Player
	if cam and p and t < 4.0 and Engine.get_process_frames() % 6 == 0:
		print("t=%.2f cam=%s arm=%.2f fov=%.1f camx=%.2f yaw=%.3f" % [t, cam.global_position.snapped(Vector3.ONE * 0.01), p.arm.get_hit_length(), cam.fov, p.arm.position.x, p.yaw])
