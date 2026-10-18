// One puff of steam: a camera-facing card whose shape is animated noise (no texture), lit by
// the room's lights from the front and the back (thin vapour glows when a lamp is behind it),
// faded where it meets surfaces (soft particles) and near the camera. Particle colour alpha
// (from the process material's ramp) fades it over its life.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, diffuse_lambert_wrap, specular_disabled;

uniform vec4 tint : source_color = vec4(0.95, 0.94, 0.92, 1.0);
uniform float opacity = 0.32;
/// How far a puff fades into the surface behind it, and how close to the camera it fades (m).
uniform float softness = 0.35;
uniform float near = 0.6;
uniform sampler2D depth : hint_depth_texture, filter_nearest;

varying float seed;
varying float age;

void vertex() {
	// Billboard, keeping the particle's own scale and a spin about the view axis.
	float scale = length(MODEL_MATRIX[0].xyz);
	// (Particle data: x the rotation angle in radians, y the life fraction 0..1.)
	float spin = INSTANCE_CUSTOM.x;
	mat4 spin_m = mat4(vec4(cos(spin), sin(spin), 0.0, 0.0), vec4(-sin(spin), cos(spin), 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * scale, INV_VIEW_MATRIX[1] * scale, INV_VIEW_MATRIX[2] * scale, MODEL_MATRIX[3]) * spin_m;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	seed = fract(INSTANCE_CUSTOM.x * 0.1591 + 0.37);
	age = INSTANCE_CUSTOM.y;
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
		p = p * 2.07 + vec3(3.1, 1.7, 9.2);
		amp *= 0.5;
	}
	return sum;
}

void fragment() {
	vec2 c = UV * 2.0 - 1.0;
	float r = length(c);
	// Wispy, churning shape: noise that drifts and evolves over the puff's life, cut by a soft
	// round edge that the noise erodes.
	float n = fbm(vec3(c * 1.6 + seed * 17.0, age * 1.5 + seed * 5.0));
	float shape = 1.0 - smoothstep(0.15, 1.0, r + (n - 0.5) * 1.4);
	float wisps = smoothstep(0.4, 0.8, n);
	float a = shape * wisps;

	float scene = texture(depth, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene, 1.0);
	float behind = -view.z / view.w + VERTEX.z;
	a *= clamp(behind / softness, 0.0, 1.0) * smoothstep(near * 0.3, near, -VERTEX.z);

	ALBEDO = tint.rgb * COLOR.rgb;
	ALPHA = clamp(a * opacity * COLOR.a, 0.0, 1.0);
	ROUGHNESS = 1.0;
	// Thin vapour: light from behind comes through.
	BACKLIGHT = vec3(0.7);
}
