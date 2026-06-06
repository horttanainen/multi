#include <metal_stdlib>
using namespace metal;

struct SelectionSpriteVertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
    float4 color    [[attribute(2)]];
};

struct SelectionSpriteVertexOutput {
    float4 position [[position]];
    float2 texcoord;
    float4 color;
};

struct SelectionFullscreenVertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct SelectionFullscreenVertexOutput {
    float4 position [[position]];
    float2 texcoord;
};

struct ViewportUniforms {
    float2 viewport_size;
};

struct SelectionOutlineUniforms {
    float2 resolution;
    float radius;
    float _pad0;
    float4 color;
};

vertex SelectionSpriteVertexOutput selection_mask_vert(
    SelectionSpriteVertexInput in [[stage_in]],
    constant ViewportUniforms &uniforms [[buffer(0)]]
) {
    SelectionSpriteVertexOutput out;
    float2 ndc;
    ndc.x = (in.position.x / uniforms.viewport_size.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (in.position.y / uniforms.viewport_size.y) * 2.0;
    out.position = float4(ndc, 0.0, 1.0);
    out.texcoord = in.texcoord;
    out.color = in.color;
    return out;
}

fragment float4 selection_mask_frag(
    SelectionSpriteVertexOutput in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    float alpha = tex.sample(smp, in.texcoord).a * in.color.a;
    return float4(alpha, alpha, alpha, alpha);
}

vertex SelectionFullscreenVertexOutput selection_outline_vert(
    SelectionFullscreenVertexInput in [[stage_in]]
) {
    SelectionFullscreenVertexOutput out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

fragment float4 selection_outline_frag(
    SelectionFullscreenVertexOutput in [[stage_in]],
    texture2d<float> mask_tex [[texture(0)]],
    sampler smp [[sampler(0)]],
    constant SelectionOutlineUniforms &uniforms [[buffer(0)]]
) {
    constexpr int MAX_RADIUS = 8;

    float2 texel = 1.0 / uniforms.resolution;
    float center = mask_tex.sample(smp, in.texcoord).a;
    float dilated = center;
    float tight = center;

    for (int y = -MAX_RADIUS; y <= MAX_RADIUS; y++) {
        for (int x = -MAX_RADIUS; x <= MAX_RADIUS; x++) {
            float2 offset = float2(float(x), float(y));
            float dist = length(offset);
            if (dist > uniforms.radius + 0.5) {
                continue;
            }

            float alpha = mask_tex.sample(smp, in.texcoord + offset * texel).a;
            float falloff_start = max(uniforms.radius - 2.0, 0.0);
            float falloff = 1.0 - smoothstep(falloff_start, uniforms.radius + 0.5, dist);
            dilated = max(dilated, alpha * falloff);

            if (dist <= 1.75) {
                tight = max(tight, alpha);
            }
        }
    }

    float soft_outline = max(dilated - center, 0.0);
    float hard_edge = max(tight - center, 0.0);
    float alpha = max(soft_outline * 0.9, hard_edge) * uniforms.color.a;
    return float4(uniforms.color.rgb, alpha);
}
