shader_type canvas_item;

// Frosted-glass cover for the mystery journey preview. Samples the screen behind this rect with a wide
// gaussian (no mipmaps — a mip filter reads as a blocky mosaic on small rects) and lifts it toward a cool
// frost, so even a row of sparse dark text becomes a clean, uniform "hidden but there" bar.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float radius : hint_range(0.0, 24.0) = 9.0;
uniform vec3 frost_tint : source_color = vec3(0.44, 0.40, 0.58);
uniform float frost_amount : hint_range(0.0, 1.0) = 0.22;

void fragment() {
	vec2 px = 1.0 / vec2(textureSize(screen_tex, 0));
	vec3 acc = vec3(0.0);
	float wsum = 0.0;
	for (int x = -4; x <= 4; x++) {
		for (int y = -4; y <= 4; y++) {
			float w = exp(-float(x * x + y * y) / 12.0);  // gaussian weights → smooth, no boxy edges
			acc += texture(screen_tex, SCREEN_UV + vec2(float(x), float(y)) * px * radius).rgb * w;
			wsum += w;
		}
	}
	COLOR = vec4(mix(acc / wsum, frost_tint, frost_amount), 1.0);
}
