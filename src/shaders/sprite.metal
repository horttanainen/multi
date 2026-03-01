#include <metal_stdlib>
using namespace metal;

struct SpriteVertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
    float4 color    [[attribute(2)]];
};

struct SpriteVertexOutput {
    float4 position [[position]];
    float2 texcoord;
    float4 color;
};

struct ViewportUniforms {
    float2 viewport_size;
};

vertex SpriteVertexOutput sprite_vert(
    SpriteVertexInput in [[stage_in]],
    constant ViewportUniforms &uniforms [[buffer(0)]]
) {
    SpriteVertexOutput out;
    // Convert pixel coords to NDC: x: [0, w] -> [-1, 1], y: [0, h] -> [1, -1]
    float2 ndc;
    ndc.x = (in.position.x / uniforms.viewport_size.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (in.position.y / uniforms.viewport_size.y) * 2.0;
    out.position = float4(ndc, 0.0, 1.0);
    out.texcoord = in.texcoord;
    out.color = in.color;
    return out;
}

fragment float4 sprite_frag(
    SpriteVertexOutput in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    float4 texColor = tex.sample(smp, in.texcoord);
    return texColor * in.color;
}
