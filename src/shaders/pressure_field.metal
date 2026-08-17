#include <metal_stdlib>
using namespace metal;

struct PressureFieldVertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct PressureFieldVertexOutput {
    float4 position [[position]];
    float2 texcoord;
};

struct PressureFieldUniforms {
    float2 viewport_size;
    float2 rectangle_origin;
    float2 rectangle_size;
    float elapsed_seconds;
    float propagation_seconds;
    float trail_duration_seconds;
    float rise_seconds;
    float displacement_ratio;
    float padding;
};

vertex PressureFieldVertexOutput pressure_field_vert(
    PressureFieldVertexInput in [[stage_in]],
    constant PressureFieldUniforms &uniforms [[buffer(0)]]
) {
    PressureFieldVertexOutput out;
    float2 pixel_position = uniforms.rectangle_origin + in.texcoord * uniforms.rectangle_size;
    float2 ndc;
    ndc.x = pixel_position.x / uniforms.viewport_size.x * 2.0 - 1.0;
    ndc.y = 1.0 - pixel_position.y / uniforms.viewport_size.y * 2.0;
    out.position = float4(ndc, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

fragment float4 pressure_field_frag(
    PressureFieldVertexOutput in [[stage_in]],
    texture2d<float> pressure_field [[texture(0)]],
    sampler field_sampler [[sampler(0)]],
    constant PressureFieldUniforms &uniforms [[buffer(0)]]
) {
    float4 packed_field = pressure_field.sample(field_sampler, in.texcoord);
    float strength = packed_field.a;
    if (strength <= 0.0001) {
        return float4(0.0);
    }

    float2 direction = packed_field.rg / strength;
    float direction_length = length(direction);
    if (direction_length <= 0.0001) {
        return float4(0.0);
    }
    direction /= direction_length;

    float arrival_fraction = clamp(packed_field.b / strength, 0.0, 1.0);
    float trail_age = uniforms.elapsed_seconds - arrival_fraction * uniforms.propagation_seconds;
    if (trail_age <= 0.0 || trail_age >= uniforms.trail_duration_seconds) {
        return float4(0.0);
    }

    float attack = smoothstep(0.0, uniforms.rise_seconds, trail_age);
    float decay = 1.0 - smoothstep(uniforms.rise_seconds, uniforms.trail_duration_seconds, trail_age);
    float2 pressure = direction * strength * attack * decay * uniforms.displacement_ratio;
    return float4(pressure, 0.0, 0.0);
}
