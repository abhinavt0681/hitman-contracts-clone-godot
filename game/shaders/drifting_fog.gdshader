// Banks of fog drifting through the base on the wind: the original's "Blowing Fog" cards and
// `Snow_Fog_Emitter`, done as real volumetric fog (lit by every lamp, shadowed by the level).
// 3D noise carried by the same accumulated wind as the snow, thickest near the ground, absent
// wherever the snow can't reach (indoors, tunnels: the height map's shelter channel).
shader_type fog;

/// How far the air has moved (m), from `Blizzard`.
uniform vec3 travel;
uniform float density = 0.05;
/// Size of the banks (m): across the ground and in height.
uniform vec2 scale = vec2(28.0, 9.0);
/// How fast the banks thin with height above the ground (m).
uniform float falloff = 9.0;
uniform vec4 tint : source_color = vec4(0.36, 0.45, 0.5, 1.0);
/// The banks' own faint light, like the original's additive cloud cards (they read as pale
/// teal clouds against the dark even where no lamp reaches).
uniform float glow = 2.0;
uniform sampler3D noise : repeat_enable, filter_linear;
uniform sampler2D heights : filter_nearest;
uniform vec3 map;

float shelter_at(vec2 p) {
	ivec2 dims = textureSize(heights, 0);
	ivec2 c = ivec2(floor((p - map.xy) / map.z));
	if (c.x < 0 || c.y < 0 || c.x >= dims.x || c.y >= dims.y) {
		return -1e9;
	}
	return texelFetch(heights, c, 0).g;
}

void fog() {
	vec3 p = WORLD_POSITION;
	float ground = shelter_at(p.xz);
	float above = p.y - ground;
	if (above < -0.2) {
		DENSITY = 0.0;
	} else {
		// Two octaves moving at slightly different paces, so the banks churn as they go.
		vec3 q = (p - travel * 0.9) / vec3(scale.x, scale.y, scale.x);
		float n = texture(noise, q).r * 0.65 + texture(noise, (p - travel * 1.15) / vec3(scale.x, scale.y, scale.x) * 2.7 + vec3(0.3, 0.7, 0.1)).r * 0.35;
		float banks = smoothstep(0.45, 0.72, n);
		DENSITY = density * banks * exp(-max(above, 0.0) / falloff);
		ALBEDO = tint.rgb;
		EMISSION = tint.rgb * glow * banks;
	}
}
