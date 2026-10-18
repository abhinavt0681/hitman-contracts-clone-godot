// The original's glow sprites (`GlowVol`, `GlowRain`, `Glow`, lamp and beacon glows): one
// additive quad each, which the engine turns to face the camera. A lamp's light cone is a
// stack of six `GlowVol` sprites growing towards the floor; drawn as fixed flat quads they
// showed as a hard fan face-on and a thin line edge-on.
//
// Here each quad becomes a camera-facing sprite of the same size about its centre, and fades
// where it meets a surface (soft particles: no hard seam where a cone touches the floor) and
// close to the camera. Fog fades it toward black, as `additive.gdshader`.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, skip_vertex_transform;

uniform sampler2D tex : source_color, filter_linear_mipmap;
uniform vec4 albedo : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
/// Brightness: the lamp-cone sprites (`GlowVol`) are dimmed, the real light's shaft in the
/// volumetric fog now carries the cone.
uniform float strength = 1.0;
/// Distance over which a sprite fades into the surface behind it (m).
uniform float softness = 0.6;
uniform sampler2D depth : hint_depth_texture, filter_nearest;
global uniform float scene_fog;

void vertex() {
	// The quad's corners sit symmetrically about its origin: keep its world size, turn it to
	// the camera.
	vec3 centre = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float radius = length((MODEL_MATRIX * vec4(VERTEX, 0.0)).xyz);
	vec2 corner = normalize(vec2(UV.x - 0.5, 0.5 - UV.y)) * radius;
	VERTEX = centre + vec3(corner, 0.0);
}

void fragment() {
	vec4 c = texture(tex, UV) * albedo;
	if (use_vertex_color) {
		c *= COLOR;
	}
	float scene = texture(depth, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene, 1.0);
	float behind = -view.z / view.w - (-VERTEX.z);
	float fade = clamp(behind / softness, 0.0, 1.0) * smoothstep(0.3, 1.5, -VERTEX.z);
	ALBEDO = c.rgb * fade * strength;
	ALPHA = c.a;
	FOG = vec4(0.0, 0.0, 0.0, 1.0 - exp(-scene_fog * length(VERTEX)));
}
