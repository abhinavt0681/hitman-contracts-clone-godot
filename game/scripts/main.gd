extends Node3D
## The Bjarkhov Bomb (scene C02-1): the level as exported from the original data by
## `tools/glacier-export`, lit and fogged for a night blizzard.
##
## Test hooks (environment variables), like the Bevy project's:
## - `HITMAN_SCREENSHOT=out.png` saves a frame and quits; `HITMAN_SHOT_FRAME=n` picks the frame.
## - `HITMAN_CAM="x,y,z,tx,ty,tz"` places the camera at x,y,z looking at tx,ty,tz.

const LEVEL := "res://imported/level/C02-1.glb"
const MARKERS := "res://imported/level/C02-1_markers.json"
## Deep night teal: the sky behind the storm.
const NIGHT := Color(0.035, 0.065, 0.08)
## Lighting quality: `HITMAN_LIGHTS=ultra` turns on everything Godot's Forward+ renderer offers
## for this scene (real-time GI, SSAO/SSIL, shadows on every light: ~16–33 fps on an RX 580
## class card); the default is the cheaper standard setup.
var ultra := OS.get_environment("HITMAN_LIGHTS") == "ultra"
## Debug: `HITMAN_ULTRA_OFF=sdfgi,ssil,ssao,shadows` drops parts of the ultra setup (profiling).
var ultra_off := OS.get_environment("HITMAN_ULTRA_OFF").split(",", false)
## The blizzard's haze, what the distance dissolves into: the original's, measured from
## gameplay footage (≈ 0.16, 0.26, 0.29 sRGB at the horizon), a shade darker for our night.
const HAZE := Color(0.13, 0.21, 0.24)
## Lamp classes in the level (`ZOmniLight` and `ZSpotLight`-like entities).
const LIGHT_CLASSES := ["0x800023", "0x800024"]
const ADDITIVE := preload("res://shaders/additive.gdshader")
const ADDITIVE_GLOW := preload("res://shaders/additive_glow.gdshader")
## Names of the glow sprites the engine turns to the camera: lamp cones (`GlowVol`), lit snow
## around lamps (`GlowRain`), halos (`Glow`, `…_Glow`) and the plane's beacons.
const GLOW_SPRITES := ["GlowVol", "GlowRain", "Glow", "_Glow", "PosLight", "TailLight", "FrontLight", "StrobeLight"]
const SODIUM := Color(1.0, 0.78, 0.5)
const FLUORESCENT := Color(0.78, 1.0, 0.82)
const INCANDESCENT := Color(1.0, 0.8, 0.56)
const TURQUOISE := Color(0.35, 1.0, 0.85)

var markers: Array = []
var player: Player
var environment: Environment


func _ready() -> void:
	RenderingServer.global_shader_parameter_add("scene_fog", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.05)
	_environment()
	_moon()
	var level: Node3D = (load(LEVEL) as PackedScene).instantiate()
	add_child(level)
	_additive(level)
	markers = JSON.parse_string(FileAccess.get_file_as_string(MARKERS))
	var actors := Actors.new()
	actors.name = "Actors"
	add_child(actors)
	var sound := Soundscape.new()
	add_child(sound)
	_spawn_player()
	add_child(Doors.new())
	add_child(Ladders.new())
	add_child(Steam.new())
	var weapons := Weapons.new()
	weapons.name = "Weapons"
	add_child(weapons)
	add_child(CloseCombat.new())
	add_child(Mission.new())
	if OS.get_environment("HITMAN_CAMLOG") != "":
		add_child(load("res://scripts/cam_log.gd").new())
	_camera()
	if OS.get_environment("HITMAN_NO_SNOW").is_empty():
		var blizzard := Blizzard.new()
		blizzard.name = "Blizzard"
		blizzard.environment = environment
		blizzard.soundscape = sound
		add_child(blizzard)
	# Lamps need the collision to tell indoors from outdoors: wait for physics.
	await get_tree().physics_frame
	await get_tree().physics_frame
	_lamps()
	_screenshot()


func _environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = NIGHT
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.75, 0.85)
	# Snow ground in the original reads ≈ 0.13, 0.23, 0.27 (footage): dim, never white.
	env.ambient_light_energy = 0.1
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = HAZE
	# Outdoors the storm swallows the view past ~25 m (the Bevy project's `WHITEOUT` 22 m);
	# `Blizzard` thins it under a roof and thickens it in squalls.
	env.fog_density = 0.05
	env.fog_sky_affect = 1.0
	# Volumetric fog: the blizzard's haze, lit by every lamp (sodium halos in the snow).
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.022
	env.volumetric_fog_albedo = Color(0.32, 0.42, 0.46)
	env.volumetric_fog_emission = HAZE * 0.2
	env.volumetric_fog_length = 80.0
	env.volumetric_fog_anisotropy = 0.35
	# The haze and the drifting banks catch the night's ambient light, so they read as fog,
	# not just darkness, where no lamp reaches.
	env.volumetric_fog_ambient_inject = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	if ultra:
		# Real-time global illumination: lamp light bounces off snow, walls and floors (signed
		# distance field GI, which follows moving lights and doors; no bake step).
		env.sdfgi_enabled = not ultra_off.has("sdfgi")
		env.sdfgi_use_occlusion = true
		env.sdfgi_cascades = 4
		env.sdfgi_min_cell_size = 0.15
		env.sdfgi_bounce_feedback = 0.5
		env.sdfgi_energy = 1.0
		# Screen-space indirect light and ambient occlusion: contact darkening in corners and
		# under objects, colour bleeding at short range.
		env.ssao_enabled = not ultra_off.has("ssao")
		env.ssao_radius = 1.2
		env.ssao_intensity = 2.0
		env.ssil_enabled = not ultra_off.has("ssil")
		env.ssil_radius = 4.0
		# The fog takes in the bounced light too.
		env.volumetric_fog_gi_inject = 1.0
	environment = env
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


## The original's glows, flashes, fire, sparks and cloud sheets are additive (render-state bit
## `0x2`; the exporter names those materials `…_add`). Drawn as ordinary alpha blending, their
## dark texels became the black rectangles around every lamp. Additive and unshaded, only the
## light adds up, as in the original.
##
## Glow sprites (single centred quads under `GLOW_SPRITES` names) also turn to face the camera,
## as the engine draws them (`additive_glow.gdshader`).
func _additive(root: Node) -> void:
	var done := {}
	var counts := [0, 0]
	var vertex_colour := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var sprite := _is_glow_sprite(mi)
		for s in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(s) as StandardMaterial3D
			if mat and mat.resource_name.ends_with("_cutout"):
				# Cutouts (fences, grilles): smooth edges from MSAA instead of stair-steps.
				mat.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
				continue
			if mat == null or not mat.resource_name.ends_with("_add"):
				continue
			var key := [mat, sprite]
			if not done.has(key):
				var add := ShaderMaterial.new()
				add.shader = ADDITIVE_GLOW if sprite else ADDITIVE
				add.set_shader_parameter("tex", mat.albedo_texture)
				add.set_shader_parameter("albedo", mat.albedo_color)
				add.set_shader_parameter("use_vertex_color", mat.vertex_color_use_as_albedo)
				if sprite and mat.resource_name.begins_with("HMC_FX_Glow_05c"):
					add.set_shader_parameter("strength", 0.35)
				vertex_colour += int(mat.vertex_color_use_as_albedo)
				done[key] = add
				counts[int(sprite)] += 1
			mi.set_surface_override_material(s, done[key])
	print("additive materials: %d, glow sprite materials: %d (vertex colour on %d)" % [counts[0], counts[1], vertex_colour])


## Whether a mesh is one of the engine's camera-facing glow sprites: a lone quad centred on its
## origin, named like one.
func _is_glow_sprite(mi: MeshInstance3D) -> bool:
	var name := String(mi.name)
	if not GLOW_SPRITES.any(func(p: String) -> bool: return name.begins_with(p) or name.ends_with(p)):
		return false
	if mi.mesh.get_surface_count() != 1:
		return false
	var v: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if v.size() != 4:
		return false
	var centre := (v[0] + v[1] + v[2] + v[3]) / 4.0
	return centre.length() < v[0].length() * 0.05


## Faint cold moonlight through the overcast: it only shapes silhouettes.
func _moon() -> void:
	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.6, 0.75, 1.0)
	moon.light_energy = 0.15
	moon.rotation = Vector3(-0.9, 0.6, 0.0)
	add_child(moon)


## A lamp for every light entity. The level stores only position and orientation for them
## (their property blobs are empty), so the kind, colour and reach come from the class and name:
## - `0x800023` spots shine along their local X (down, for every ceiling lamp): `SpotLight3D`
##   with soft shadows, whose beams show as shafts in the volumetric fog. This replaces the
##   flat look of the original's sprite cones, which still glow around the bulbs.
## - `0x800024` omnis are fill: faint where a spot shares the spot (the tunnel lamps' pairs).
## - Explosion and sniper-reticle lights belong to effects and stay off.
## Colours: incandescent tunnel lamps, turquoise neons (by name), sodium outdoors, pale-green
## fluorescent under roofs. Assumption: cone angles and ranges are set by eye.
func _lamps() -> void:
	# Debug: `HITMAN_TEST_LIGHT="x,y,z"` adds one bright white lamp there; `HITMAN_NO_LAMPS`
	# leaves the level's own out (lighting checks in isolation).
	var test := OS.get_environment("HITMAN_TEST_LIGHT").split(",")
	if test.size() == 3:
		var t := OmniLight3D.new()
		t.position = Vector3(test[0].to_float(), test[1].to_float(), test[2].to_float())
		t.light_energy = 6.0
		t.omni_range = 8.0
		t.shadow_enabled = OS.get_environment("HITMAN_TEST_LIGHT_NOSHADOW").is_empty()
		add_child(t)
	if not OS.get_environment("HITMAN_NO_LAMPS").is_empty():
		return
	var space := get_world_3d().direct_space_state
	var spots := {}
	for m: Dictionary in markers:
		if m["type"] == "0x800023":
			spots[Vector3i(Vector3(m["pos"][0], m["pos"][1], m["pos"][2]).round())] = true
	var counts := {"spot": 0, "omni": 0}
	for m: Dictionary in markers:
		if not LIGHT_CLASSES.has(m["type"]) or m.get("template", false):
			continue
		var name: String = m["name"]
		if name.begins_with("Omni_Explosion") or name.begins_with("Omni_Reticle"):
			continue
		var p := Vector3(m["pos"][0], m["pos"][1], m["pos"][2])
		if p.length() < 0.01:
			continue
		var roof := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.3, p + Vector3.UP * 12.0))
		var inside := not roof.is_empty()
		var colour := FLUORESCENT if inside else SODIUM
		if name.contains("Tunnel"):
			colour = INCANDESCENT
		elif name.contains("Turquoise"):
			colour = TURQUOISE
		var lamp: Light3D
		if m["type"] == "0x800023":
			var spot := SpotLight3D.new()
			var q := Quaternion(m["rot"][0], m["rot"][1], m["rot"][2], m["rot"][3])
			var aim := q * Vector3.RIGHT
			spot.basis = Basis.looking_at(aim, Vector3.UP if absf(aim.y) < 0.99 else Vector3.FORWARD)
			var flood := name.begins_with("Fspot")
			spot.spot_angle = 32.0 if flood else (65.0 if name.contains("Turquoise") else 40.0)
			spot.spot_angle_attenuation = 1.2
			spot.spot_range = 28.0 if flood else 11.0
			spot.spot_attenuation = 1.2
			spot.light_energy = 6.0 if flood else 4.0
			spot.shadow_enabled = true
			# A physical lamp size: shadows soften with distance from what casts them.
			spot.light_size = 0.25 if ultra else 0.15
			spot.shadow_bias = 0.04
			spot.light_volumetric_fog_energy = 0.3
			lamp = spot
			counts["spot"] += 1
		else:
			var omni := OmniLight3D.new()
			var paired := spots.has(Vector3i(p.round()))
			omni.omni_range = 5.0 if paired else (8.0 if inside else 12.0)
			omni.omni_attenuation = 1.6
			# Every light casts soft shadows, fill lights included (cube-map shadows).
			# (Not one inside its own fixture, a lantern's glass or a lamp's shade: its shadow
			# would black out its own light.)
			omni.shadow_enabled = ultra and not ultra_off.has("shadows") and not _enclosed(space, p)
			omni.light_size = 0.2
			omni.shadow_bias = 0.05
			omni.light_energy = 0.35 if paired else (1.0 if inside else 2.0)
			omni.light_volumetric_fog_energy = 0.15 if paired else 0.5
			lamp = omni
			counts["omni"] += 1
		lamp.position = p
		lamp.light_color = colour
		lamp.distance_fade_enabled = true
		lamp.distance_fade_begin = 60.0 if ultra else 45.0
		lamp.distance_fade_shadow = 40.0 if ultra else 25.0
		lamp.distance_fade_length = 10.0
		lamp.add_to_group("lamps")
		add_child(lamp)
	print("lamps: %d spots, %d omnis" % [counts["spot"], counts["omni"]])


## Whether a light sits inside a fixture: solid within 0.6 m in most directions around it.
func _enclosed(space: PhysicsDirectSpaceState3D, p: Vector3) -> bool:
	var hits := 0
	for d: Vector3 in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(p, p + d * 0.6, 1)).is_empty():
			hits += 1
	return hits >= 2


## 47 at his template's spot (the first `Hitman2` placed in the level), or `HITMAN_START`.
func _spawn_player() -> void:
	player = Player.new()
	player.name = "Player"
	var start := Vector3.ZERO
	for m: Dictionary in markers:
		if m["name"] == "Hitman2" and Vector3(m["local"][0], m["local"][1], m["local"][2]).length() > 0.01:
			start = Vector3(m["local"][0], m["local"][1], m["local"][2])
			break
	var spec := OS.get_environment("HITMAN_START").split(",")
	if spec.size() == 3:
		start = Vector3(spec[0].to_float(), spec[1].to_float(), spec[2].to_float())
	player.position = start + Vector3.UP * 0.2
	add_child(player)


## A fixed camera for scripted shots (`HITMAN_CAM`); otherwise 47's.
func _camera() -> void:
	if OS.get_environment("HITMAN_CAM").is_empty():
		player.make_current()
		return
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.fov = 60.0
	cam.far = 2000.0
	var spec := OS.get_environment("HITMAN_CAM").split(",")
	if spec.size() == 6:
		var v := Array(spec).map(func(s: String) -> float: return s.to_float())
		cam.position = Vector3(v[0], v[1], v[2])
		add_child(cam)
		cam.look_at(Vector3(v[3], v[4], v[5]))
	else:
		cam.position = Vector3(46, 2.5, -18)
		add_child(cam)
		cam.look_at(Vector3(60, 3, 0))
	cam.current = true


func _screenshot() -> void:
	var path := OS.get_environment("HITMAN_SCREENSHOT")
	if path.is_empty():
		return
	var frames := OS.get_environment("HITMAN_SHOT_FRAME").to_int()
	for i in max(frames, 30):
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("screenshot: %s" % path)
	get_tree().quit()
