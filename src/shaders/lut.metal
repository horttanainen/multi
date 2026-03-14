#include <metal_stdlib>
using namespace metal;

struct LutVertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct LutVertexOutput {
    float4 position [[position]];
    float2 texcoord;
};

struct LutUniforms {
    float strength;
};

vertex LutVertexOutput lut_vert(
    LutVertexInput in [[stage_in]]
) {
    LutVertexOutput out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

fragment float4 lut_frag(
    LutVertexOutput in [[stage_in]],
    texture2d<float> scene_tex [[texture(0)]],
    sampler scene_smp [[sampler(0)]],
    texture2d<float> lut_tex [[texture(1)]],
    sampler lut_smp [[sampler(1)]],
    constant LutUniforms &uniforms [[buffer(0)]]
) {
    float4 original = scene_tex.sample(scene_smp, in.texcoord);
    float3 color = clamp(original.rgb, 0.0, 1.0);

    // LUT is 1024x32: 32 horizontal slices of 32x32, each slice = one blue level
    float blue_scaled = color.b * 31.0;
    float blue_low = floor(blue_scaled);
    float blue_high = min(blue_low + 1.0, 31.0);
    float blue_frac = blue_scaled - blue_low;

    // Half-pixel offset for accurate sampling
    float2 lut_size = float2(1024.0, 32.0);

    // Sample at blue_low slice
    float2 uv_low;
    uv_low.x = (blue_low * 32.0 + color.r * 31.0 + 0.5) / lut_size.x;
    uv_low.y = (color.g * 31.0 + 0.5) / lut_size.y;

    // Sample at blue_high slice
    float2 uv_high;
    uv_high.x = (blue_high * 32.0 + color.r * 31.0 + 0.5) / lut_size.x;
    uv_high.y = (color.g * 31.0 + 0.5) / lut_size.y;

    float3 graded_low = lut_tex.sample(lut_smp, uv_low).rgb;
    float3 graded_high = lut_tex.sample(lut_smp, uv_high).rgb;

    // Trilinear interpolation between blue slices
    float3 graded = mix(graded_low, graded_high, blue_frac);

    // Blend between original and graded based on strength
    float3 result = mix(original.rgb, graded, uniforms.strength);

    return float4(result, original.a);
}
