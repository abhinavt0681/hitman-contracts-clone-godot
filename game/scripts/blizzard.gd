class_name Blizzard
extends Node3D
## The blizzard that never stops, rebuilt from the original's snow (see `docs/BLIZZARD.md`).
##
## Three layers ride one wind:
## - **streaks**, as the original's `ZParticleBox`: flakes wrapped around the camera, grey,
##   driven almost flat by the wind (`Snow_Flakes_Base`: vSpawnAdd (5, −1, 0), spread
##   vSpawnMul (0.7, 0.6, 0.8)), out to 20 m where the original stopped at 10;
## - **sheets** of blowing snow billowing across open ground (the original's additive
##   `HMC_FX_Clouds` / "Blowing Fog" cards, redone as moving noise);
## - **powder** skimming the ground.
## Squalls come every half minute or so: the wind picks up by `GUST_WIND`, the fog closes in
## and the wind howls louder (the Bevy project's `Gust`).
##
## A top-down height map of the level (`C02-1_heights.bin`, from the exporter) keeps snow out
## of enclosed spaces (hangars, the plane's hold, tunnels); under the wing it still snows. Test hooks: `HITMAN_NO_SNOW=1` (in `main.gd`);
## `HITMAN_GUST=0..1` holds a squall at that strength.

## The wind between squalls (m/s). Direction and the 5 : 1 sideways-to-down ratio are the
## level's `Snow_Flakes_Base` vSpawnAdd (5, −1, 0) (Glacier X is ours, Z mirrored);
## assumption: the speed, 12 m/s, is set by eye against gameplay footage, where streaks lie
## within ~10° of horizontal.
const WIND := Vector3(12.0, -2.4, 0.0)
## Each flake's own drift (±m/s): vSpawnMul (0.7, 0.6, 0.8) on the same scale as the wind.
const SPREAD := Vector3(1.68, 1.44, 1.92)
## How much faster a full squall blows (Bevy's `GUST_WIND`).
const GUST_WIND := 1.6
const GUST_RISE := 1.5
const GUST_FALL := 2.5
const HEIGHTS := "res://imported/level/C02-1_heights.bin"
const MAX_LAMPS := 16
## The drifting fog's volume around the camera (m); it reaches past the fog's own horizon.
const FOG_BOX := Vector3(140.0, 40.0, 140.0)
## Drifting fog density between squalls and at a squall's height.
const DRIFT := Vector2(0.08, 0.16)

## The fog to thicken in squalls, and the soundscape whose wind to raise.
var environment: Environment
var soundscape: Soundscape
## Squall strength now, 0..1.
var gust := 0.0

var materials: Array[ShaderMaterial] = []
var fog_material: ShaderMaterial
var fog_volume: FogVolume
## Per material: opacity between squalls and its rise in a full squall.
var squall_opacity: Dictionary = {}
var travel := Vector3.ZERO
var clock := 0.0
var gust_t := 0.0
var gust_calm := 20.0
var gust_hold := 5.0
var gust_seed := 0
var gust_fixed := -1.0
var fog_base := Vector2.ZERO
## Fog under a roof, as a fraction of outdoors (the Bevy project: no whiteout indoors).
const INDOOR_FOG := 0.25
## 0 outdoors … 1 under a roof, eased so doorways don't snap.
var indoors := 0.0
var height_image: Image
## The ground under the camera, eased (the sheets and powder stand on it).
var floor_y := 0.0
var floor_known := false
var height_map := Vector3.ZERO
var lamps: Array[Light3D] = []
## `HITMAN_SNOW_LAYERS=streaks,sheets,powder` draws only those layers (for inspection).
var only := OS.get_environment("HITMAN_SNOW_LAYERS").split(",", false)


func _ready() -> void:
	var heights := _heights()
	var rng := RandomNumberGenerator.new()
	rng.seed = 47
	# One layer of streaks, even density out to 20 m, fading into the fog. (Two layers of
	# different density, near and far, showed a hard ring where they met.) The original drew
	# 1,000 flakes per box in a 3×3×3 block to 10 m; this is denser and reaches twice as far.
	# The tint is the controller's flat grey `Color` 0xA0A0A0, cooled a touch by the night.
	_layer("streaks", _streaks(200000, rng), "res://shaders/snow_streak.gdshader", heights, {
		"box": Vector3(40.0, 16.0, 40.0), "width": 0.008, "opacity": Vector2(0.7, 0.2), "near": 0.5,
		"tint": Color(0.6, 0.66, 0.68)})
	_layer("sheets", _cards(70, rng), "res://shaders/snow_veil.gdshader", heights, {
		"area": Vector2(90.0, 90.0), "tall": 8.0, "widths": Vector2(10.0, 24.0), "ground": false,
		"grain": Vector2(0.09, 0.22), "opacity": Vector2(0.12, 0.2)})
	_layer("powder", _cards(110, rng), "res://shaders/snow_veil.gdshader", heights, {
		"area": Vector2(60.0, 60.0), "tall": 1.3, "widths": Vector2(5.0, 12.0), "ground": true,
		"grain": Vector2(0.16, 0.9), "opacity": Vector2(0.2, 0.2)})
	_drifting_fog(heights)
	var fixed := OS.get_environment("HITMAN_GUST")
	if not fixed.is_empty():
		gust_fixed = clampf(fixed.to_float(), 0.0, 1.0)
	if environment:
		fog_base = Vector2(environment.fog_density, environment.volumetric_fog_density)


## Fog banks rolling through on the wind (`drifting_fog.gdshader`), in a volume that follows
## the camera.
func _drifting_fog(heights: Dictionary) -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.02
	noise.fractal_octaves = 3
	var tex := NoiseTexture3D.new()
	tex.width = 64
	tex.height = 64
	tex.depth = 64
	tex.seamless = true
	tex.normalize = true
	tex.noise = noise
	fog_material = ShaderMaterial.new()
	fog_material.shader = load("res://shaders/drifting_fog.gdshader")
	fog_material.set_shader_parameter("noise", tex)
	fog_material.set_shader_parameter("heights", heights["texture"])
	fog_material.set_shader_parameter("map", heights["map"])
	fog_volume = FogVolume.new()
	fog_volume.size = FOG_BOX
	fog_volume.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	fog_volume.material = fog_material
	add_child(fog_volume)


## The level's height maps (r: top surface, g: lowest height the wind carries snow to; see
## the exporter's `export_heights`) as a float texture, and where they lie (origin x, z; cell).
func _heights() -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(HEIGHTS)
	var head := bytes.slice(0, 24).to_float32_array()
	var image := Image.create_from_data(int(head[3]), int(head[4]), false, Image.FORMAT_RGF, bytes.slice(24))
	height_image = image
	height_map = Vector3(head[0], head[1], head[2])
	return {"texture": ImageTexture.create_from_image(image), "map": Vector3(head[0], head[1], head[2])}


## One quad per flake, each vertex carrying the flake's four random numbers.
func _streaks(count: int, rng: RandomNumberGenerator) -> ArrayMesh:
	return _quads(count, func() -> Color: return Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))


func _cards(count: int, rng: RandomNumberGenerator) -> ArrayMesh:
	return _streaks(count, rng)


func _quads(count: int, rand: Callable) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var custom := PackedFloat32Array()
	var index := PackedInt32Array()
	verts.resize(count * 4)
	uvs.resize(count * 4)
	custom.resize(count * 16)
	index.resize(count * 6)
	var corners := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for i in count:
		var r: Color = rand.call()
		for k in 4:
			var v := i * 4 + k
			uvs[v] = corners[k]
			custom[v * 4] = r.r
			custom[v * 4 + 1] = r.g
			custom[v * 4 + 2] = r.b
			custom[v * 4 + 3] = r.a
		var q := i * 6
		var b := i * 4
		index[q] = b
		index[q + 1] = b + 1
		index[q + 2] = b + 2
		index[q + 3] = b
		index[q + 4] = b + 2
		index[q + 5] = b + 3
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_INDEX] = index
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return mesh


func _layer(layer: String, mesh: ArrayMesh, shader: String, heights: Dictionary, params: Dictionary) -> void:
	if not only.is_empty() and not only.has(layer):
		return
	var mat := ShaderMaterial.new()
	mat.shader = load(shader)
	mat.set_shader_parameter("heights", heights["texture"])
	mat.set_shader_parameter("map", heights["map"])
	if not OS.get_environment("HITMAN_SNOW_DEBUG").is_empty() and shader.ends_with("snow_streak.gdshader"):
		mat.set_shader_parameter("debug_hidden", true)
	for key: String in params:
		if key == "opacity":
			squall_opacity[mat] = params[key]
		else:
			mat.set_shader_parameter(key, params[key])
	# Drawn after every other transparent surface. Godot sorts transparents by distance, and
	# these meshes' centres mean nothing (the shader places the flakes), so without this the
	# level's alpha-blended snow layers on the ground drew over the streaks and wiped them out
	# in straight-edged patches.
	mat.render_priority = Material.RENDER_PRIORITY_MAX
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	# The shader places every flake around the camera: never cull.
	mi.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	materials.append(mat)


func _process(dt: float) -> void:
	clock += dt
	_gust(dt)
	var wind := WIND * (1.0 + (GUST_WIND - 1.0) * gust)
	travel += wind * dt
	var cam := get_viewport().get_camera_3d()
	var lamp_pos := PackedVector4Array()
	var lamp_col := PackedVector4Array()
	if cam:
		_nearest_lamps(cam.global_position, lamp_pos, lamp_col)
	if cam:
		var g := _ground(cam.global_position)
		if not is_nan(g):
			floor_y = g if not floor_known else lerpf(floor_y, g, minf(dt * 2.0, 1.0))
			floor_known = true
	for mat in materials:
		mat.set_shader_parameter("floor_y", floor_y)
		mat.set_shader_parameter("travel", travel)
		mat.set_shader_parameter("wind", wind)
		mat.set_shader_parameter("spread", SPREAD)
		mat.set_shader_parameter("clock", clock)
		mat.set_shader_parameter("lamp_count", lamp_pos.size())
		mat.set_shader_parameter("lamp_pos", lamp_pos)
		mat.set_shader_parameter("lamp_col", lamp_col)
		var o: Vector2 = squall_opacity[mat]
		mat.set_shader_parameter("opacity", o.x + o.y * gust)
	if fog_volume and cam:
		fog_volume.global_position = cam.global_position
		fog_material.set_shader_parameter("travel", travel)
		fog_material.set_shader_parameter("density", DRIFT.x + (DRIFT.y - DRIFT.x) * gust)
	if environment and cam:
		var inside := 1.0 if _sheltered(cam.global_position) else 0.0
		indoors = move_toward(indoors, inside, dt * 1.5)
		# A squall closes the view in (the Bevy project: whiteout from 22 m to 6 m).
		var outdoor := lerpf(1.0, INDOOR_FOG, indoors)
		environment.fog_density = fog_base.x * outdoor * (1.0 + 1.2 * gust * (1.0 - indoors))
		environment.volumetric_fog_density = fog_base.y * outdoor * (1.0 + 2.0 * gust * (1.0 - indoors))
		# Additive glows fade with the fog and the volumetric haze together (`additive.gdshader`).
		RenderingServer.global_shader_parameter_set("scene_fog", environment.fog_density + environment.volumetric_fog_density)
	if soundscape and soundscape.wind:
		# Indoors and in the tunnels the storm is a muffled roar through the walls.
		soundscape.wind.volume_db = soundscape.wind_db + 6.0 * gust * (1.0 - indoors) - 14.0 * indoors
		soundscape.muffle(indoors)


## Whether the wind-borne snow can't reach `p`: under a roof, in a tunnel.
func _sheltered(p: Vector3) -> bool:
	var c := Vector2i(floori((p.x - height_map.x) / height_map.z), floori((p.z - height_map.y) / height_map.z))
	if c.x < 0 or c.y < 0 or c.x >= height_image.get_width() or c.y >= height_image.get_height():
		return false
	return p.y < height_image.get_pixelv(c).g - 0.2


## The open ground under `p` (NAN under a roof or off the map).
func _ground(p: Vector3) -> float:
	var c := Vector2i(floori((p.x - height_map.x) / height_map.z), floori((p.z - height_map.y) / height_map.z))
	if c.x < 0 or c.y < 0 or c.x >= height_image.get_width() or c.y >= height_image.get_height():
		return NAN
	var g := height_image.get_pixelv(c).g
	return g if g < p.y + 0.5 else NAN


## The squall cycle: 18–40 s of calm, a 1.5 s rise, a 3–8 s hold, a 2.5 s fall (Bevy's `Gust`).
func _gust(dt: float) -> void:
	if gust_fixed >= 0.0:
		gust = gust_fixed
		return
	gust_t += dt
	var s := gust_t - gust_calm
	if s < 0.0:
		gust = 0.0
	elif s < GUST_RISE:
		gust = s / GUST_RISE
	elif s < GUST_RISE + gust_hold:
		gust = 1.0
	elif s < GUST_RISE + gust_hold + GUST_FALL:
		gust = 1.0 - (s - GUST_RISE - gust_hold) / GUST_FALL
	else:
		gust = 0.0
		gust_t = 0.0
		gust_seed += 1
		var r := fposmod(sin(gust_seed * 12.9898) * 43758.5453, 1.0)
		gust_calm = 18.0 + 22.0 * r
		gust_hold = 3.0 + 5.0 * fposmod(r * 7.0, 1.0)


## The lamps nearest the camera, to light the snow around them.
func _nearest_lamps(from: Vector3, pos: PackedVector4Array, col: PackedVector4Array) -> void:
	if lamps.is_empty():
		for n in get_tree().get_nodes_in_group("lamps"):
			lamps.append(n as Light3D)
	var sorted := lamps.duplicate()
	sorted.sort_custom(func(a: Light3D, b: Light3D) -> bool: return a.global_position.distance_squared_to(from) < b.global_position.distance_squared_to(from))
	for l: Light3D in sorted.slice(0, MAX_LAMPS):
		var p := l.global_position
		var reach: float = l.omni_range if l is OmniLight3D else (l as SpotLight3D).spot_range * 0.5
		pos.append(Vector4(p.x, p.y, p.z, reach))
		var c := l.light_color.srgb_to_linear() * l.light_energy * 0.12
		col.append(Vector4(c.r, c.g, c.b, 0.0))
