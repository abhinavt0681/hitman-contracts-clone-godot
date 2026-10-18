class_name Steam
extends Node3D
## Steam rising from the kitchen's pots and bowls.
##
## The original draws it as static crossed cards (`FC005_SteamA_…`, `FC005_SteamB_…`, texture
## `HMC_C2_effects_02a`) that never move. Each card is hidden and replaced, at its base and to
## its size, by a `Source`: a particle plume of soft, lit, churning puffs that rise, spread and
## fade, plus a small volume of fog over it that the room's lights shine through.
##
## A source is attached to whatever it rises from. Moved, its plume follows (puffs already
## released stay in the air, so a carried pot trails steam); `stop()` (a dish taken away or
## eaten) lets the last puffs rise and fade and the haze thin before it frees itself;
## `cool(seconds)` tapers it off like food going cold.

const STEAM_NAMES := ["Steam"]

## One steam source.
class Source:
	extends Node3D
	var particles: GPUParticles3D
	var haze: FogVolume
	var haze_material: ShaderMaterial
	var strength := 1.0
	var stopping := false
	var cooling := 0.0
	var cool_time := 0.0

	func _process(dt: float) -> void:
		if cooling > 0.0:
			cool_time += dt
			strength = maxf(1.0 - cool_time / cooling, 0.0)
			particles.amount_ratio = strength
			if strength <= 0.0:
				stop()
		if stopping:
			strength = move_toward(strength, 0.0, dt / particles.lifetime)
			if strength <= 0.0 and not particles.emitting:
				queue_free()
		haze_material.set_shader_parameter("strength", strength)

	## Stops making steam; what's in the air rises and fades, then the source frees itself.
	func stop() -> void:
		particles.emitting = false
		stopping = true

	## Fades the steam out over `seconds`, like food going cold.
	func cool(seconds: float) -> void:
		cooling = seconds
		cool_time = 0.0

var sources: Array[Source] = []


func _ready() -> void:
	var level := get_parent().find_child("Level", true, false)
	var noise := _noise()
	for node in level.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if not STEAM_NAMES.any(func(n: String) -> bool: return String(mi.name).contains(n)):
			continue
		var box := mi.global_transform * mi.get_aabb()
		mi.visible = false
		var source := _source(box, noise)
		# Riding on the card's own node: if the level moves the dish, the steam goes with it.
		mi.get_parent().add_child(source)
		source.global_position = Vector3(box.get_center().x, box.position.y, box.get_center().z)
		sources.append(source)
	print("steam: %d sources" % sources.size())


func _noise() -> NoiseTexture3D:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.06
	n.fractal_octaves = 3
	var tex := NoiseTexture3D.new()
	tex.width = 48
	tex.height = 48
	tex.depth = 48
	tex.seamless = true
	tex.normalize = true
	tex.noise = n
	return tex


## A plume sized to the original card: `box` is its world bounds (width, height).
func _source(box: AABB, noise: NoiseTexture3D) -> Source:
	var width := maxf(box.size.x, box.size.z)
	var height := box.size.y
	var source := Source.new()

	var p := GPUParticles3D.new()
	p.amount = int(clampf(width * 120.0, 24.0, 192.0))
	p.lifetime = clampf(height * 2.2, 1.8, 4.0)
	p.preprocess = p.lifetime
	# World space: released puffs don't follow the dish (a carried pot trails steam).
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-width, -0.2, -width), Vector3(width * 2.0, height * 2.0, width * 2.0))
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = width * 0.18
	pm.direction = Vector3.UP
	pm.spread = 12.0
	pm.initial_velocity_min = height * 0.3
	pm.initial_velocity_max = height * 0.45
	# Warm vapour rises, then slows and spreads as it cools.
	pm.gravity = Vector3(0.0, height * 0.06, 0.0)
	pm.damping_min = height * 0.08
	pm.damping_max = height * 0.14
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.2
	pm.turbulence_noise_scale = 1.6
	pm.turbulence_noise_speed = Vector3(0.0, 0.4, 0.0)
	pm.turbulence_noise_speed_random = 0.3
	pm.turbulence_influence_min = 0.015
	pm.turbulence_influence_max = 0.05
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -25.0
	pm.angular_velocity_max = 25.0
	pm.scale_min = width * 0.3
	pm.scale_max = width * 0.5
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.35))
	grow.add_point(Vector2(0.5, 0.9))
	grow.add_point(Vector2(1.0, 1.6))
	var grow_tex := CurveTexture.new()
	grow_tex.curve = grow
	pm.scale_curve = grow_tex
	var ramp := Gradient.new()
	ramp.set_offset(0, 0.0)
	ramp.set_color(0, Color(1, 1, 1, 0))
	ramp.set_offset(1, 1.0)
	ramp.set_color(1, Color(1, 1, 1, 0))
	ramp.add_point(0.12, Color(1, 1, 1, 0.9))
	ramp.add_point(0.45, Color(1, 1, 1, 0.55))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	pm.color_ramp = ramp_tex
	p.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/steam_puff.gdshader")
	quad.material = mat
	p.draw_pass_1 = quad
	source.particles = p
	source.add_child(p)

	# The haze: a small fog volume over the dish.
	var haze := FogVolume.new()
	haze.size = Vector3(width * 1.4, height * 1.3, width * 1.4)
	haze.position = Vector3(0.0, height * 0.6, 0.0)
	var hm := ShaderMaterial.new()
	hm.shader = load("res://shaders/steam_haze.gdshader")
	hm.set_shader_parameter("noise", noise)
	haze.material = hm
	source.haze = haze
	source.haze_material = hm
	source.add_child(haze)
	return source
