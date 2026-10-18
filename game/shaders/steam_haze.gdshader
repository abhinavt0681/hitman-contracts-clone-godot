// The haze over a steaming pot: a small volume of fog whose density is noise rising and
// churning, thickest just above the source and thinning upwards and outwards. As real fog, the
// room's lights shine through it and cast shadows into it. `strength` fades it in and out.
shader_type fog;

uniform float density = 0.18;
uniform float strength = 1.0;
uniform float rise = 0.35;
uniform vec4 tint : source_color = vec4(0.8, 0.82, 0.84, 1.0);
uniform sampler3D noise : repeat_enable, filter_linear;

void fog() {
	// UVW: 0..1 across the volume; the source is at the bottom middle.
	vec3 p = UVW;
	float up = p.y;
	float out_r = length(p.xz - 0.5) * 2.0;
	float shape = (1.0 - smoothstep(0.35 + up * 0.5, 1.0, out_r)) * smoothstep(0.0, 0.12, up) * (1.0 - smoothstep(0.55, 1.0, up));
	vec3 q = WORLD_POSITION * vec3(1.8, 1.1, 1.8) - vec3(0.0, TIME * rise, 0.0);
	float n = texture(noise, q * 0.35).r;
	DENSITY = density * strength * shape * smoothstep(0.3, 0.75, n);
	ALBEDO = tint.rgb;
}
