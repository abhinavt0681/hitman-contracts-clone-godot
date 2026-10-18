// Blowing snow (the original's additive `HMC_FX_Clouds` sheets and "Blowing Fog" entities,
// redone as in the Bevy project's `veil.wesl`): big upright sheets of noise riding the wind,
// either billowing across open ground at eye height or skimming it as drifting powder.
// Same wrap-around-the-camera scheme and height map as `snow_streak.gdshader`.
//
// Mesh: one quad per sheet; CUSTOM0 = (seed x, seed z, size, pace) in 0..1, UV = corner.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform, shadows_disabled;

uniform vec3 travel;
uniform float clock;
/// The area of sheets around the camera (m, x and z).
uniform vec2 area = vec2(120.0, 120.0);
/// Sheet height (m).
uniform float tall = 7.0;
/// Width range (m).
uniform vec2 widths = vec2(10.0, 24.0);
/// True: powder hugging the ground. False: sheets standing at eye height.
uniform bool ground = false;
/// Noise scale (per m) along x/z and y.
uniform vec2 grain = vec2(0.09, 0.22);
/// The ground under the camera (m), eased.
uniform float floor_y = 0.0;
uniform vec4 tint : source_color = vec4(0.36, 0.45, 0.48, 1.0);
uniform float opacity = 0.12;

uniform sampler2D heights : filter_nearest;
uniform vec3 map;
uniform int lamp_count = 0;
uniform vec4 lamp_pos[16];
uniform vec4 lamp_col[16];

varying vec4 colour;
varying vec3 world;
varying float pace;

float top_at(vec2 p) {
	ivec2 dims = textureSize(heights, 0);
	ivec2 c = ivec2(floor((p - map.xy) / map.z));
	if (c.x < 0 || c.y < 0 || c.x >= dims.x || c.y >= dims.y) {
		return -1e9;
	}
	return texelFetch(heights, c, 0).g;
}

vec3 lamp_light(vec3 p) {
	vec3 light = vec3(0.0);
	for (int i = 0; i < lamp_count; i++) {
		vec4 l = lamp_pos[i];
		float f = clamp(1.0 - distance(l.xyz, p) / (l.w * 1.4), 0.0, 1.0);
		light += lamp_col[i].rgb * f * f;
	}
	return light;
}

void vertex() {
	vec4 r = CUSTOM0;
	pace = mix(0.85, 1.15, r.w);
	vec3 cam = CAMERA_POSITION_WORLD;
	vec2 local = fract((r.xy * area + travel.xz * pace - cam.xz) / area) * area - area * 0.5;
	vec2 centre = cam.xz + local;
	// Every card stands on the ground under the camera (kept smooth by `Blizzard`), not on
	// whatever is under its own centre: that made cards jump onto roofs as they drifted.
	float base = ground ? floor_y - 0.1 : max(floor_y, cam.y - 3.0) - 0.5;
	float wide = mix(widths.x, widths.y, r.z);
	float high = tall * mix(0.6, 1.3, fract(r.z * 7.31));
	vec2 to_cam = cam.xz - centre;
	vec2 right = normalize(vec2(-to_cam.y, to_cam.x) + vec2(1e-4, 0.0));
	world = vec3(centre.x, base, centre.y) + vec3(right.x, 0.0, right.y) * (UV.x - 0.5) * wide + vec3(0.0, (1.0 - UV.y) * high, 0.0);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	// Fade close up (no wall of noise in the face) and at the edge of the area.
	float fade = smoothstep(2.0, 9.0, length(to_cam)) * (1.0 - smoothstep(area.x * 0.3, area.x * 0.5, length(local)));
	colour = vec4(tint.rgb + lamp_light(world) * 0.6, opacity * fade);
}

float hash(vec3 p) {
	vec3 q = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	vec3 r = q * 17.0;
	return fract(r.x * r.y * r.z * (r.x + r.y + r.z));
}

float noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(i), hash(i + vec3(1, 0, 0)), u.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), u.x), u.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), u.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), u.x), u.y),
		u.z);
}

float fbm(vec3 p) {
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		sum += amp * noise(p);
		p = p * 2.03 + vec3(1.7, 9.2, 3.1);
		amp *= 0.5;
	}
	return sum;
}

void fragment() {
	// Clipped where it would stand inside a building, pixel by pixel (hiding a whole card by
	// what's under its centre made 20 m sheets pop).
	if (world.y < top_at(world.xz)) {
		discard;
	}
	// Noise that moves with the air, stretched along the wind and churning as it goes.
	vec3 air = world - travel * pace;
	float n = fbm(air * vec3(grain.x, grain.y, grain.x) + vec3(0.0, clock * 0.15, 0.0));
	float density = smoothstep(0.38, 0.75, n);
	float across = sin(UV.x * 3.14159);
	float v = 1.0 - UV.y;
	float updown = ground
		? 1.0 - smoothstep(0.15, 1.0, v)
		: smoothstep(0.0, 0.25, v) * (1.0 - smoothstep(0.5, 1.0, v));
	ALBEDO = colour.rgb;
	ALPHA = clamp(colour.a * density * max(across, 0.0) * updown, 0.0, 1.0);
}
