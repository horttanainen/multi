#include <metal_stdlib>
using namespace metal;

struct CrtVertexInput {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct CrtVertexOutput {
    float4 position [[position]];
    float2 texcoord;
};

struct CrtUniforms {
    float2 resolution;
};

vertex CrtVertexOutput crt_vert(
    CrtVertexInput in [[stage_in]]
) {
    CrtVertexOutput out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

// Barrel distortion - simulate CRT screen curvature
float2 barrel_distort(float2 uv, float strength) {
    float2 centered = uv - 0.5;
    float r2 = dot(centered, centered);
    float2 distorted = centered * (1.0 + strength * r2);
    return distorted + 0.5;
}

fragment float4 crt_frag(
    CrtVertexOutput in [[stage_in]],
    texture2d<float> scene_tex [[texture(0)]],
    sampler smp [[sampler(0)]],
    constant CrtUniforms &uniforms [[buffer(0)]]
) {
    float2 uv = in.texcoord;

    // Barrel distortion
    float distortion_strength = 0.15;
    float2 distorted_uv = barrel_distort(uv, distortion_strength);

    // Discard pixels outside the screen after distortion
    if (distorted_uv.x < 0.0 || distorted_uv.x > 1.0 ||
        distorted_uv.y < 0.0 || distorted_uv.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // Chromatic aberration - offset R/G/B channels slightly
    float aberration = 0.002;
    float2 dir = distorted_uv - 0.5;
    float r = scene_tex.sample(smp, distorted_uv + dir * aberration).r;
    float g = scene_tex.sample(smp, distorted_uv).g;
    float b = scene_tex.sample(smp, distorted_uv - dir * aberration).b;
    float3 color = float3(r, g, b);

    // Scanlines - darken every other pixel row
    float scanline_freq = uniforms.resolution.y;
    float scanline = sin(distorted_uv.y * scanline_freq * 3.14159) * 0.5 + 0.5;
    scanline = mix(0.75, 1.0, scanline);
    color *= scanline;

    // Vignette - darken edges and corners
    float2 vig_uv = uv * (1.0 - uv);
    float vignette = vig_uv.x * vig_uv.y * 15.0;
    vignette = clamp(pow(vignette, 0.25), 0.0, 1.0);
    color *= vignette;

    return float4(color, 1.0);
}
