// The original's additive surfaces (render-state bit 0x2: glows, light cones, flashes, fire,
// cloud cards): texture × vertex colour added to the scene, unlit. Fog fades them toward black,
// not toward the fog colour: fogging an additive quad the usual way adds haze over its whole
// square, which showed every lamp's glow card as a box in the blizzard.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
/// The scene's exponential fog density, kept current by `Blizzard`.
global uniform float scene_fog;

void fragment() {
	vec4 c = texture(tex, UV) * albedo;
	if (use_vertex_color) {
		c *= COLOR;
	}
	ALBEDO = c.rgb;
	ALPHA = c.a;
	FOG = vec4(0.0, 0.0, 0.0, 1.0 - exp(-scene_fog * length(VERTEX)));
}
