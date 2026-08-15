#include <metal_stdlib>
using namespace metal;

struct PressureVertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct PressureVertexOutput {
    float4 position [[position]];
    float2 texcoord;
};

struct PressureDistortionUniforms {
    float2 resolution;
    float maximum_displacement_pixels;
    float padding;
};

vertex PressureVertexOutput pressure_distortion_vert(
    PressureVertexInput in [[stage_in]]
) {
    PressureVertexOutput out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

fragment float4 pressure_distortion_frag(
    PressureVertexOutput in [[stage_in]],
    texture2d<float> scene_texture [[texture(0)]],
    sampler scene_sampler [[sampler(0)]],
    texture2d<float> pressure_mask [[texture(1)]],
    sampler mask_sampler [[sampler(1)]],
    constant PressureDistortionUniforms &uniforms [[buffer(0)]]
) {
    float4 encoded_pressure = pressure_mask.sample(mask_sampler, in.texcoord);
    float2 pressure = float2(
        encoded_pressure.r - encoded_pressure.g,
        encoded_pressure.b - encoded_pressure.a
    );
    float2 displacement_uv = pressure * uniforms.maximum_displacement_pixels / uniforms.resolution;
    float2 sample_uv = clamp(in.texcoord - displacement_uv, float2(0.0), float2(1.0));
    float4 refracted = scene_texture.sample(scene_sampler, sample_uv);
    float lens_brightness = 1.0 + clamp(length(pressure), 0.0, 1.0) * 0.8;
    return float4(refracted.rgb * lens_brightness, refracted.a);
}
