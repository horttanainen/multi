#include <metal_stdlib>
using namespace metal;

struct PaintVertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct PaintVertexOutput {
    float4 position [[position]];
    float2 texcoord;
};

struct PaintUniforms {
    packed_float2 resolution;
    float  spin_rotation;
    float  spin_speed;
    packed_float2 offset;
    float  contrast;
    float  spin_amount;
    float  pixel_filter;
    float  time;
    packed_float3 colour_1;
    float  _pad1;
    packed_float3 colour_2;
    float  _pad2;
    packed_float3 colour_3;
    float  _pad3;
    float  swirl_type;
    float  noise_type;
    float  color_mode;
    float  _pad4;
};

float value_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = fract(sin(dot(i, float2(127.1, 311.7))) * 43758.5453);
    float b = fract(sin(dot(i + float2(1.0, 0.0), float2(127.1, 311.7))) * 43758.5453);
    float c = fract(sin(dot(i + float2(0.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
    float d = fract(sin(dot(i + float2(1.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(float2 p, int octaves) {
    float value = 0.0;
    float amp = 0.5;
    for (int i = 0; i < octaves; i++) {
        value += amp * value_noise(p);
        p *= 2.17;
        amp *= 0.5;
    }
    return value;
}

vertex PaintVertexOutput paint_vert(
    PaintVertexInput in [[stage_in]]
) {
    PaintVertexOutput out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

fragment float4 paint_frag(
    PaintVertexOutput in [[stage_in]],
    constant PaintUniforms &u [[buffer(0)]]
) {
    float2 screen_size = u.resolution;
    float screen_len = length(screen_size);

    // Pixelate UV
    float pixel_size = screen_len / u.pixel_filter;
    float2 uv = (floor(in.texcoord * screen_size / pixel_size) * pixel_size - 0.5 * screen_size) / screen_len - u.offset;
    float uv_len = length(uv);

    float orig_y = in.texcoord.y;
    float orig_x = in.texcoord.x;

    // ===== Swirl section (0=None, 1..7) =====
    int swirl = int(u.swirl_type);
    float2 mid = (screen_size / screen_len) / 2.0;

    if (swirl == 1) {
        // Paint Mix swirl
        float speed = u.spin_rotation * 0.2 + 302.2;
        float new_angle = atan2(uv.y, uv.x) + speed - 20.0 * (u.spin_amount * uv_len + (1.0 - u.spin_amount));
        uv = float2(uv_len * cos(new_angle) + mid.x, uv_len * sin(new_angle) + mid.y) - mid;
    } else if (swirl == 2) {
        // Kaleidoscope
        float angle = atan2(uv.y, uv.x);
        float segments = 6.0;
        float sector = 3.14159265 / segments;
        angle = fmod(abs(angle), 2.0 * sector);
        if (angle > sector) angle = 2.0 * sector - angle;
        angle += u.spin_rotation * 0.2 + u.time * u.spin_speed * 0.3;
        uv = float2(uv_len * cos(angle) + mid.x, uv_len * sin(angle) + mid.y) - mid;
    } else if (swirl == 3) {
        // Radial ripple
        float angle = atan2(uv.y, uv.x);
        float ripple = sin(uv_len * 40.0 + u.time * u.spin_speed * 2.0) * u.spin_amount * 0.15;
        float new_len = uv_len + ripple;
        angle += u.spin_rotation * 0.2 + 5.0 * u.spin_amount * sin(uv_len * 20.0 - u.time * u.spin_speed);
        uv = float2(new_len * cos(angle) + mid.x, new_len * sin(angle) + mid.y) - mid;
    } else if (swirl == 4) {
        // Double spiral
        float angle = atan2(uv.y, uv.x);
        float spiral1 = u.spin_rotation * 0.2 + 302.2 - 15.0 * (u.spin_amount * uv_len + (1.0 - u.spin_amount));
        float spiral2 = -u.spin_rotation * 0.15 + 150.0 + 12.0 * (u.spin_amount * uv_len);
        float blend = 0.5 + 0.5 * sin(angle * 3.0 + u.time * u.spin_speed);
        float new_angle = angle + mix(spiral1, spiral2, blend);
        uv = float2(uv_len * cos(new_angle) + mid.x, uv_len * sin(new_angle) + mid.y) - mid;
    } else if (swirl == 5) {
        // Diamond warp
        float2 abs_uv = abs(uv);
        float diamond_dist = abs_uv.x + abs_uv.y;
        float angle = atan2(uv.y, uv.x);
        angle += u.spin_rotation * 0.2 + 302.2 - 18.0 * (u.spin_amount * diamond_dist + (1.0 - u.spin_amount));
        float r = mix(uv_len, diamond_dist, 0.6 * u.spin_amount);
        uv = float2(r * cos(angle) + mid.x, r * sin(angle) + mid.y) - mid;
    } else if (swirl == 6) {
        // Tunnel: radial zoom effect pulling toward center
        float angle = atan2(uv.y, uv.x) + u.spin_rotation * 0.1;
        float tunnel_r = 0.1 / (uv_len + 0.05);
        tunnel_r += u.time * u.spin_speed * 0.5;
        uv = float2(tunnel_r * cos(angle), tunnel_r * sin(angle) + angle * u.spin_amount * 0.3);
    } else if (swirl == 7) {
        // Wobble: sinusoidal displacement on both axes
        float t = u.time * u.spin_speed;
        float2 wobble = float2(
            sin(uv.y * 15.0 + t * 1.3 + u.spin_rotation) * u.spin_amount * 0.08,
            sin(uv.x * 12.0 - t * 0.9 + u.spin_rotation * 0.7) * u.spin_amount * 0.08
        );
        uv += wobble;
    }
    // swirl == 0: None (no transformation)

    // ===== Noise section (0=None, 1..7) =====
    int noise = int(u.noise_type);
    float anim_speed = u.time * u.spin_speed;
    float contrast_mod = 0.25 * u.contrast + 0.5 * u.spin_amount + 1.2;
    float paint_val;
    float paint_angle;

    if (noise == 1) {
        // Sine turbulence (original Balatro)
        float2 tuv = uv * 30.0;
        float2 uv2 = float2(tuv.x + tuv.y);
        for (int i = 0; i < 5; i++) {
            uv2 += sin(max(tuv.x, tuv.y)) + tuv;
            tuv += 0.5 * float2(cos(5.1123314 + 0.353 * uv2.y + anim_speed * 0.131121),
                                sin(uv2.x - 0.113 * anim_speed));
            tuv -= cos(tuv.x + tuv.y) - sin(tuv.x * 0.711 - tuv.y);
        }
        paint_val = clamp(length(tuv) * 0.035 * contrast_mod, 0.0, 2.0);
        paint_angle = atan2(tuv.y, tuv.x);
    } else if (noise == 2) {
        // Domain warp
        float2 p = uv * 4.0;
        float2 t_offset = float2(anim_speed * 0.2, anim_speed * 0.15);
        float2 q = float2(
            fbm(p + t_offset, 5),
            fbm(p + float2(5.2, 1.3) + t_offset * 0.7, 5)
        );
        float2 r = float2(
            fbm(p + 4.0 * q + float2(1.7, 9.2) + t_offset * 0.4, 5),
            fbm(p + 4.0 * q + float2(8.3, 2.8) + t_offset * 0.3, 5)
        );
        float n = length(r - 0.5) * 2.0;
        paint_val = clamp(n * contrast_mod * 1.5, 0.0, 2.0);
        paint_angle = atan2(r.y - 0.5, r.x - 0.5);
    } else if (noise == 3) {
        // Cellular/Voronoi
        float2 p = uv * 6.0;
        float2 t_offset = float2(anim_speed * 0.15, -anim_speed * 0.1);
        float min_dist = 10.0;
        float second_dist = 10.0;
        float2 closest_cell = float2(0.0);
        for (int yi = -1; yi <= 1; yi++) {
            for (int xi = -1; xi <= 1; xi++) {
                float2 neighbor = float2(float(xi), float(yi));
                float2 cell_id = floor(p) + neighbor;
                float2 cell_point = cell_id + float2(
                    fract(sin(dot(cell_id, float2(127.1, 311.7))) * 43758.5453),
                    fract(sin(dot(cell_id, float2(269.5, 183.3))) * 43758.5453)
                );
                cell_point += 0.3 * sin(cell_point * 3.17 + t_offset.x);
                float d = length(fract(p) - (cell_point - floor(p)));
                if (d < min_dist) {
                    second_dist = min_dist;
                    min_dist = d;
                    closest_cell = cell_id;
                } else if (d < second_dist) {
                    second_dist = d;
                }
            }
        }
        float edge = second_dist - min_dist;
        paint_val = clamp(edge * contrast_mod * 3.0, 0.0, 2.0);
        paint_angle = fract(sin(dot(closest_cell, float2(127.1, 311.7))) * 43758.5453) * 6.28318 - 3.14159;
    } else if (noise == 4) {
        // Marble
        float2 p = uv * 5.0;
        float2 t_offset = float2(anim_speed * 0.12, anim_speed * 0.08);
        float n = fbm(p + t_offset, 5);
        float marble = sin((p.x + p.y) * 3.0 + n * 8.0 * u.spin_amount + anim_speed * 0.2);
        marble = marble * 0.5 + 0.5;
        paint_val = clamp(marble * contrast_mod, 0.0, 2.0);
        paint_angle = atan2(p.y + n * 2.0, p.x + n * 2.0);
    } else if (noise == 5) {
        // Plasma
        float2 p = uv * 10.0;
        float t = anim_speed * 0.5;
        float v1 = sin(p.x * 1.1 + t);
        float v2 = sin(p.y * 1.3 - t * 0.7);
        float v3 = sin((p.x * 0.7 + p.y * 1.1) + t * 0.5);
        float v4 = sin(length(p - float2(sin(t * 0.3) * 3.0, cos(t * 0.2) * 3.0)) * 1.5);
        float plasma = (v1 + v2 + v3 + v4) * 0.25 + 0.5;
        paint_val = clamp(plasma * contrast_mod, 0.0, 2.0);
        paint_angle = atan2(v1 + v3, v2 + v4);
    } else if (noise == 6) {
        // Ridged: absolute-value fBm creating sharp mountain ridges
        float2 p = uv * 5.0;
        float2 t_offset = float2(anim_speed * 0.15, anim_speed * 0.1);
        float value = 0.0;
        float amp = 1.0;
        float freq = 1.0;
        float2 ap = p + t_offset;
        for (int i = 0; i < 5; i++) {
            float n = 1.0 - abs(value_noise(ap * freq) * 2.0 - 1.0);
            n = n * n;
            value += n * amp;
            freq *= 2.2;
            amp *= 0.5;
        }
        paint_val = clamp(value * contrast_mod * 0.7, 0.0, 2.0);
        paint_angle = atan2(
            value_noise(ap * 1.3 + 50.0) - 0.5,
            value_noise(ap * 1.7 + 100.0) - 0.5
        );
    } else if (noise == 7) {
        // Wood grain: concentric rings displaced by noise
        float2 p = uv * 8.0;
        float2 t_offset = float2(anim_speed * 0.08, anim_speed * 0.06);
        float n = fbm(p * 0.5 + t_offset, 4);
        float grain = length(p + float2(n * 3.0, n * 2.5));
        grain = fract(grain * 0.5 + anim_speed * 0.05);
        paint_val = clamp(grain * contrast_mod, 0.0, 2.0);
        paint_angle = atan2(p.y + n, p.x + n);
    } else {
        // None: raw UV distance and angle (no distortion)
        paint_val = clamp(uv_len * contrast_mod * 4.0, 0.0, 2.0);
        paint_angle = atan2(uv.y, uv.x);
    }

    // ===== Color mapping section (0=None, 1..7) =====
    int cmode = int(u.color_mode);
    float3 col;

    if (cmode == 1) {
        // Distance blend (original Balatro)
        float c1p = max(0.0, 1.0 - contrast_mod * abs(1.0 - paint_val));
        float c2p = max(0.0, 1.0 - contrast_mod * abs(paint_val));
        float c3p = 1.0 - min(1.0, c1p + c2p);
        float inv = 0.3 / u.contrast;
        col = inv * u.colour_1 + (1.0 - inv) * (u.colour_1 * c1p + u.colour_2 * c2p + u.colour_3 * c3p);
    } else if (cmode == 2) {
        // Angle-based
        float t = (paint_angle + 3.14159265) / (2.0 * 3.14159265);
        t = fract(t * (1.0 + u.contrast) + paint_val * 0.3);
        float w1 = max(0.0, 1.0 - 3.0 * min(t, 1.0 - t));
        float w2 = max(0.0, 1.0 - 3.0 * abs(t - 0.333));
        float w3 = max(0.0, 1.0 - 3.0 * abs(t - 0.666));
        col = (u.colour_1 * w1 + u.colour_2 * w2 + u.colour_3 * w3) * 2.0;
    } else if (cmode == 3) {
        // Gradient
        float grad = orig_y * 0.7 + orig_x * 0.3;
        grad = grad + (paint_val - 1.0) * 0.3 * u.spin_amount;
        grad = clamp(grad, 0.0, 1.0);
        if (grad < 0.4) {
            col = mix(u.colour_1, u.colour_2, grad / 0.4);
        } else if (grad < 0.7) {
            col = mix(u.colour_2, u.colour_3, (grad - 0.4) / 0.3);
        } else {
            col = u.colour_3;
        }
        col *= 0.5 + 0.8 * clamp(paint_val * 0.7, 0.0, 1.0);
    } else if (cmode == 4) {
        // Rings
        float ring = fract(paint_val * 1.5);
        float band = floor(fmod(paint_val * 1.5, 3.0));
        if (band < 1.0) {
            col = mix(u.colour_1, u.colour_2, ring);
        } else if (band < 2.0) {
            col = mix(u.colour_2, u.colour_3, ring);
        } else {
            col = mix(u.colour_3, u.colour_1, ring);
        }
        float edge = 1.0 - smoothstep(0.0, 0.08, min(ring, 1.0 - ring));
        col += edge * 0.3;
    } else if (cmode == 5) {
        // Duotone
        float threshold = 0.5 + 0.3 * sin(paint_angle * 2.0);
        float t = smoothstep(threshold - 0.15 / u.contrast, threshold + 0.15 / u.contrast, paint_val * 0.5);
        col = mix(u.colour_1, u.colour_2, t);
        float edge_glow = 1.0 - smoothstep(0.0, 0.3 / u.contrast, abs(paint_val * 0.5 - threshold));
        col += u.colour_3 * edge_glow * 0.5;
    } else if (cmode == 6) {
        // Neon: dark background with bright color outlines
        float edge1 = 1.0 - smoothstep(0.0, 0.15 / u.contrast, abs(paint_val - 0.5));
        float edge2 = 1.0 - smoothstep(0.0, 0.15 / u.contrast, abs(paint_val - 1.2));
        float edge3 = 1.0 - smoothstep(0.0, 0.15 / u.contrast, abs(paint_val - 1.8));
        col = u.colour_1 * edge1 * 2.5 + u.colour_2 * edge2 * 2.5 + u.colour_3 * edge3 * 2.5;
        // Dark base
        col += (u.colour_1 + u.colour_2 + u.colour_3) * 0.03;
    } else if (cmode == 7) {
        // Posterize: stepped discrete color bands
        float steps = 2.0 + u.contrast * 1.5;
        float stepped = floor(paint_val * steps) / steps;
        float t = clamp(stepped, 0.0, 1.0);
        if (t < 0.33) {
            col = mix(u.colour_1, u.colour_2, t / 0.33);
        } else if (t < 0.66) {
            col = mix(u.colour_2, u.colour_3, (t - 0.33) / 0.33);
        } else {
            col = mix(u.colour_3, u.colour_1, (t - 0.66) / 0.34);
        }
    } else {
        // None: flat blend of all three colours weighted by paint_val
        float t = clamp(paint_val * 0.5, 0.0, 1.0);
        col = mix(u.colour_1, mix(u.colour_2, u.colour_3, t), t);
    }

    return float4(max(col, 0.0), 1.0);
}
