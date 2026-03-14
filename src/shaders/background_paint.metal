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
    float2 resolution;
    float  spin_rotation;
    float  spin_speed;
    float2 offset;
    float  contrast;
    float  spin_amount;
    float  pixel_filter;
    float  time;
    float3 colour_1;
    float  _pad1;
    float3 colour_2;
    float  _pad2;
    float3 colour_3;
    float  _pad3;
};

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

    // Centre swirl
    float speed = u.spin_rotation * 0.2 + 302.2;
    float new_angle = atan2(uv.y, uv.x) + speed - 20.0 * (u.spin_amount * uv_len + (1.0 - u.spin_amount));
    float2 mid = (screen_size / screen_len) / 2.0;
    uv = float2(uv_len * cos(new_angle) + mid.x, uv_len * sin(new_angle) + mid.y) - mid;

    // Paint distortion loop
    uv *= 30.0;
    float anim_speed = u.time * u.spin_speed;
    float2 uv2 = float2(uv.x + uv.y);

    for (int i = 0; i < 5; i++) {
        uv2 += sin(max(uv.x, uv.y)) + uv;
        uv  += 0.5 * float2(cos(5.1123314 + 0.353 * uv2.y + anim_speed * 0.131121),
                             sin(uv2.x - 0.113 * anim_speed));
        uv  -= cos(uv.x + uv.y) - sin(uv.x * 0.711 - uv.y);
    }

    // Three-colour blend
    float contrast_mod = 0.25 * u.contrast + 0.5 * u.spin_amount + 1.2;
    float paint_res = clamp(length(uv) * 0.035 * contrast_mod, 0.0, 2.0);
    float c1p = max(0.0, 1.0 - contrast_mod * abs(1.0 - paint_res));
    float c2p = max(0.0, 1.0 - contrast_mod * abs(paint_res));
    float c3p = 1.0 - min(1.0, c1p + c2p);

    float inv = 0.3 / u.contrast;
    float3 col = inv * u.colour_1 + (1.0 - inv) * (u.colour_1 * c1p + u.colour_2 * c2p + u.colour_3 * c3p);
    return float4(max(col, 0.0), 1.0);
}
