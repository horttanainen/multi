#include <metal_stdlib>
using namespace metal;

struct ColorVertexInput {
    float2 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct ColorVertexOutput {
    float4 position [[position]];
    float4 color;
};

struct ViewportUniforms {
    float2 viewport_size;
};

vertex ColorVertexOutput colored_vert(
    ColorVertexInput in [[stage_in]],
    constant ViewportUniforms &uniforms [[buffer(0)]]
) {
    ColorVertexOutput out;
    float2 ndc;
    ndc.x = (in.position.x / uniforms.viewport_size.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (in.position.y / uniforms.viewport_size.y) * 2.0;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 colored_frag(
    ColorVertexOutput in [[stage_in]]
) {
    return in.color;
}
