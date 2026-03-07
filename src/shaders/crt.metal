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
    float distortion_strength;
    float aberration;
    float zoom;
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

    // Barrel distortion + zoom to crop out black borders
    float2 distorted_uv = barrel_distort(uv, uniforms.distortion_strength);
    distorted_uv = (distorted_uv - 0.5) / uniforms.zoom + 0.5;

    // Discard pixels outside the screen after distortion
    if (distorted_uv.x < 0.0 || distorted_uv.x > 1.0 ||
        distorted_uv.y < 0.0 || distorted_uv.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // Downsample to virtual CRT resolution by snapping UVs to pixel grid
    float2 pixel = floor(distorted_uv * uniforms.resolution) + 0.5;
    float2 snapped_uv = pixel / uniforms.resolution;

    // Chromatic aberration - offset R/G/B channels slightly
    float2 dir = snapped_uv - 0.5;
    float r = scene_tex.sample(smp, snapped_uv + dir * uniforms.aberration).r;
    float g = scene_tex.sample(smp, snapped_uv).g;
    float b = scene_tex.sample(smp, snapped_uv - dir * uniforms.aberration).b;
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
