shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, unshaded;

// One lobe of a factory gas cloud: a large soft camera-facing card. The noise is read from a texture, not computed, because a
// cloud covers a lot of the screen and many overlap. Sinks softly into anything it touches.
uniform sampler2D noise_map : repeat_enable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;
uniform float light_level = 1.0;
uniform float soft_distance = 14.0;
varying float seed;
varying float age;

void vertex() {
	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	mat4 facing = mat4(INV_VIEW_MATRIX[0] * scale_x, INV_VIEW_MATRIX[1] * scale_y, INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * facing;
	seed = INSTANCE_CUSTOM.x;
	age = INSTANCE_CUSTOM.y;
}

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float radius = length(uv);
	vec2 flow = vec2(seed * 13.0, seed * 7.0) + vec2(TIME * 0.006, -TIME * 0.009);
	float wide = texture(noise_map, UV * 0.55 + flow).r;
	float fine = texture(noise_map, UV * 1.5 - flow * 1.7 + wide * 0.25).r;
	float cloud = wide * 0.65 + fine * 0.35;
	// Dense and billowing when young, wispy as it thins out.
	float edge = 1.0 - smoothstep(0.22 + cloud * 0.42, 1.0, radius);
	float body = smoothstep(0.26 + age * 0.14, 0.62, cloud);
	float scene_depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	scene_view.xyz /= scene_view.w;
	float soft = clamp((VERTEX.z - scene_view.z) / soft_distance, 0.0, 1.0);
	ALBEDO = COLOR.rgb * mix(0.78, 1.12, cloud) * light_level;
	ALPHA = clamp(edge * body * COLOR.a * soft, 0.0, 1.0);
}
