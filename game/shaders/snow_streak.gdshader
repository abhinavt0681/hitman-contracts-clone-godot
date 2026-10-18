// Snow streaks the way the original drew them (ZParticleBox, `vssnow.vsh`): flakes at fixed
// random spots in a box around the camera, carried by the wind and wrapped around the box's
// edges, so the blizzard never thins or pops. Each flake is a thin streak from where it is
// back to where it was a moment ago (its motion blur), turned to face the camera, at least
// `min_px` pixels wide (thinner ones fade instead, so distance doesn't fatten them).
//
// Flakes below the height map's shelter height are hidden: it never snows in enclosed spaces,
// yet it does under the plane's wing. Lamps light the flakes near them, as sodium pools do in the original's haze.
//
// Mesh: one quad per flake; CUSTOM0 = random (x, y, z, w) in 0..1, UV = the quad's corner.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform, shadows_disabled;

/// How far the air has moved so far (m), accumulated on the CPU so gusts never make it jump.
uniform vec3 travel;
/// The wind now (m/s): the streaks' direction and length.
uniform vec3 wind;
/// Each flake's own drift on top of the wind (m/s, ±), from the original's `vSpawnMul`.
uniform vec3 spread;
uniform float clock;
/// The box of flakes kept around the camera (m).
uniform vec3 box = vec3(30.0, 16.0, 30.0);
/// The "exposure" of the eye: streak length = speed × shutter (s).
uniform float shutter = 0.045;
/// Streak width (m) and the fewest pixels it may cover.
uniform float width = 0.006;
uniform float min_px = 1.2;
/// Flakes nearer than `inner` belong to the next layer in; `near` fades streaks right at the lens.
uniform float inner = 0.0;
uniform float near = 0.5;
uniform vec4 tint : source_color = vec4(0.42, 0.5, 0.53, 1.0);
uniform float opacity = 0.5;
/// Debug (`HITMAN_SNOW_DEBUG`): flakes the shelter test would hide are drawn red instead.
uniform bool debug_hidden = false;

uniform sampler2D heights : filter_nearest;
/// Height map: origin x, z; cell size (m).
uniform vec3 map;
uniform int lamp_count = 0;
/// xyz position, w range (m); rgb colour × energy.
uniform vec4 lamp_pos[16];
uniform vec4 lamp_col[16];

varying vec4 colour;

float shelter_at(vec2 p) {
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
		float f = clamp(1.0 - distance(l.xyz, p) / (l.w * 1.2), 0.0, 1.0);
		light += lamp_col[i].rgb * f * f;
	}
	return light;
}

vec3 hash3(float n) {
	return fract(sin(vec3(n, n + 1.37, n + 2.71) * vec3(43758.5453, 22578.1459, 19642.3490)));
}

void vertex() {
	vec4 r = CUSTOM0;
	vec3 h = hash3(r.w * 97.13 + r.x * 13.7);
	vec3 drift = spread * (h * 2.0 - 1.0);
	float pace = 0.85 + 0.3 * h.x;
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 lo = cam - box * 0.5;
	vec3 p = r.xyz * box + travel * pace + drift * clock;
	p = lo + mod(p - lo, box);
	vec3 vel = wind * pace + drift;
	float dist = distance(p, cam);

	vec3 a = (VIEW_MATRIX * vec4(p, 1.0)).xyz;
	vec3 b = (VIEW_MATRIX * vec4(p - vel * shutter * (0.6 + 0.8 * r.w), 1.0)).xyz;
	float depth = max(-a.z, 0.05);
	float pixel = 2.0 * depth / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float w = width * (0.6 + 0.8 * h.y);
	float wide = max(w, pixel * min_px);
	vec3 axis = b - a;
	vec3 side = normalize(cross(axis, a) + vec3(1e-6)) * wide * 0.5;
	VERTEX = mix(a, b, UV.y) + side * (UV.x * 2.0 - 1.0);

	// Soft at every edge of the box, so it never shows: out to the sides by distance (the fog
	// has most of it by then), and at its top and bottom.
	float edge_y = min(p.y - lo.y, lo.y + box.y - p.y);
	float fade = smoothstep(near * 0.4, near, depth)
		* (inner > 0.0 ? smoothstep(inner * 0.75, inner, dist) : 1.0)
		* (1.0 - smoothstep(box.x * 0.25, box.x * 0.5, distance(p.xz, cam.xz)))
		* smoothstep(0.0, box.y * 0.2, edge_y)
		* (w / wide);
	colour = vec4(tint.rgb + lamp_light(p), opacity * (0.45 + 0.55 * h.z) * fade);
	bool sheltered = p.y < shelter_at(p.xz) + 0.05;
	if (debug_hidden && sheltered) {
		colour = vec4(1.0, 0.0, 0.0, 1.0);
	} else if (sheltered || fade < 0.002) {
		VERTEX = vec3(0.0, 0.0, 10.0);
	}
}

void fragment() {
	// Soft across, tapering at the tail, brightest at the head (the flake itself).
	// (MSAA can shade a thin streak just outside its quad: keep the falloff from going negative,
	// which would darken the pixel.)
	float across = max(1.0 - pow(abs(UV.x * 2.0 - 1.0), 2.0), 0.0);
	float along = (1.0 - smoothstep(0.55, 1.0, UV.y)) *smoothstep(0.0, 0.12, UV.y) * mix(1.0, 0.55, UV.y);
	ALBEDO = colour.rgb;
	ALPHA = clamp(colour.a * across * along, 0.0, 1.0);
}
