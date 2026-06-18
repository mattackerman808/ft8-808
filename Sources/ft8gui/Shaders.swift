import Foundation

/// Metal Shading Language source, compiled at runtime via
/// `device.makeLibrary(source:)`. Kept as a Swift string rather than a `.metal`
/// resource so the SwiftPM executable needs no bundle/metallib plumbing.
///
/// Both render paths read the SAME ring height-texture (`heightTex`): a
/// `binCount × historyRows` R32Float image of normalised magnitudes in [0,1].
/// New rows are written at an advancing `head`; `headF` (fractional head) lets
/// the display scroll smoothly between data rows at full refresh rate.
let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;        // projection * view (3D only)
    float    headF;      // newest row position (fractional) in ring coords
    float    rows;       // historyRows
    float    heightScale;// 3D vertical exaggeration
    float    xExtent;    // 3D world width of the surface
    float    zDepth;     // 3D world depth of the surface
};

// Classic waterfall ramp: dark blue -> cyan -> green -> yellow -> red -> white.
static float3 colormap(float t) {
    t = clamp(t, 0.0, 1.0);
    const float3 c0 = float3(0.02, 0.02, 0.10); // near-black blue (noise floor)
    const float3 c1 = float3(0.05, 0.15, 0.55); // blue
    const float3 c2 = float3(0.00, 0.65, 0.70); // cyan
    const float3 c3 = float3(0.10, 0.80, 0.20); // green
    const float3 c4 = float3(0.95, 0.85, 0.10); // yellow
    const float3 c5 = float3(0.95, 0.20, 0.05); // red
    const float3 c6 = float3(1.00, 0.95, 0.90); // white-hot
    float x = t * 6.0;
    if (x < 1.0) return mix(c0, c1, x);
    if (x < 2.0) return mix(c1, c2, x - 1.0);
    if (x < 3.0) return mix(c2, c3, x - 2.0);
    if (x < 4.0) return mix(c3, c4, x - 3.0);
    if (x < 5.0) return mix(c4, c5, x - 4.0);
    return mix(c5, c6, x - 5.0);
}

// Ring-buffer time coordinate -> normalised texture v. `depth` is 0 at the
// newest row (front) and 1 at the oldest (back).
static float ringV(float depth, constant Uniforms& u) {
    float texRow = u.headF - depth * (u.rows - 1.0);
    return fract(texRow / u.rows);
}

constexpr sampler heightSamp(coord::normalized, address::clamp_to_edge, filter::linear);

// ---------------------------------------------------------------- 3D surface

struct V3DOut {
    float4 position [[position]];
    float  height;
    float  depth;
    float3 normal;
};

vertex V3DOut vertex3d(uint vid [[vertex_id]],
                       const device float2* grid [[buffer(0)]],
                       constant Uniforms& u [[buffer(1)]],
                       texture2d<float> heightTex [[texture(0)]]) {
    float2 g = grid[vid];           // g.x = frequency 0..1, g.y = time depth 0..1
    float v = ringV(g.y, u);
    float h = heightTex.sample(heightSamp, float2(g.x, v), level(0)).r;

    // Finite-difference normal from neighbouring texels for lighting.
    float du = 1.0 / 512.0;
    float dv = 1.0 / max(u.rows, 1.0);
    float hL = heightTex.sample(heightSamp, float2(g.x - du, v), level(0)).r;
    float hR = heightTex.sample(heightSamp, float2(g.x + du, v), level(0)).r;
    float hB = heightTex.sample(heightSamp, float2(g.x, fract(v - dv)), level(0)).r;
    float hF = heightTex.sample(heightSamp, float2(g.x, fract(v + dv)), level(0)).r;
    float hs = u.heightScale;
    float3 n = normalize(float3((hL - hR) * hs, 0.10, (hB - hF) * hs));

    float3 world = float3((g.x - 0.5) * u.xExtent, h * hs, -g.y * u.zDepth);

    V3DOut out;
    out.position = u.mvp * float4(world, 1.0);
    out.height = h;
    out.depth = g.y;
    out.normal = n;
    return out;
}

fragment float4 fragment3d(V3DOut in [[stage_in]]) {
    float3 base = colormap(in.height);
    float3 lightDir = normalize(float3(0.35, 0.85, 0.40));
    float diff = max(dot(normalize(in.normal), lightDir), 0.0);
    float3 lit = base * (0.45 + 0.65 * diff);
    // Subtle depth fade so the far ridges recede.
    float fog = mix(1.0, 0.55, in.depth);
    return float4(lit * fog, 1.0);
}

// ---------------------------------------------------------------- 2D spectrogram

struct V2DOut {
    float4 position [[position]];
    float2 uv;       // uv.x = frequency 0..1, uv.y = time depth 0..1 (0 = newest)
};

vertex V2DOut vertex2d(uint vid [[vertex_id]]) {
    // Full-screen triangle strip (4 verts).
    float2 p = float2((vid == 1 || vid == 3) ? 1.0 : -1.0,
                      (vid >= 2) ? 1.0 : -1.0);
    V2DOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5); // top = newest
    return out;
}

fragment float4 fragment2d(V2DOut in [[stage_in]],
                           constant Uniforms& u [[buffer(0)]],
                           texture2d<float> heightTex [[texture(0)]]) {
    float v = ringV(in.uv.y, u);
    float h = heightTex.sample(heightSamp, float2(in.uv.x, v), level(0)).r;
    return float4(colormap(h), 1.0);
}

// ---------------------------------------------------------------- decode labels

// Pre-rendered text+pill bitmaps drawn as scrolling quads IN the same pass as
// the waterfall, so they are locked to its exact frame clock and scroll rate.
struct LabelUniforms {
    float2 center;     // clip-space center
    float2 halfSize;   // clip-space half extent
    float  alpha;      // fade in/out
};

struct LabelOut {
    float4 position [[position]];
    float2 uv;
};

vertex LabelOut labelVertex(uint vid [[vertex_id]],
                            constant LabelUniforms& u [[buffer(0)]]) {
    float2 corner = float2((vid == 1 || vid == 3) ? 1.0 : -1.0,
                           (vid >= 2) ? 1.0 : -1.0);
    LabelOut out;
    out.position = float4(u.center + corner * u.halfSize, 0.0, 1.0);
    // Flip V: the CoreGraphics bitmap is bottom-up vs Metal's top-left origin.
    out.uv = float2((corner.x + 1.0) * 0.5, 1.0 - (corner.y + 1.0) * 0.5);
    return out;
}

fragment float4 labelFragment(LabelOut in [[stage_in]],
                              constant LabelUniforms& u [[buffer(0)]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return tex.sample(s, in.uv) * u.alpha;   // bitmap is premultiplied
}

// Solid-color primitives in clip space (leader lines from surface to flag).
vertex float4 solidVertex(uint vid [[vertex_id]],
                          const device float2* pts [[buffer(0)]]) {
    return float4(pts[vid], 0.0, 1.0);
}

fragment float4 solidFragment(constant float4& color [[buffer(0)]]) {
    return color;   // premultiplied
}

// ---------------------------------------------------------------- graph-paper floor

static float gridLine(float2 coord, float spacing) {
    float2 g = coord / spacing;
    float2 d = abs(fract(g) - 0.5) / fwidth(g);
    return 1.0 - clamp(min(d.x, d.y), 0.0, 1.0);
}

// Full-viewport graph-paper background, drawn edge-to-edge behind everything.
// Grid is computed in screen pixels so it always fills the whole window.
vertex float4 bgVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid == 1 || vid == 3) ? 1.0 : -1.0, (vid >= 2) ? 1.0 : -1.0);
    return float4(p, 0.0, 1.0);
}

fragment float4 bgFragment(float4 pos [[position]]) {
    float2 px = pos.xy;
    float minorL = gridLine(px, 40.0);
    float majorL = gridLine(px, 200.0);
    float3 col = mix(float3(0.10, 0.18, 0.27) * minorL, float3(0.20, 0.40, 0.58), majorL);
    float a = max(minorL * 0.45, majorL * 0.85);
    return float4(col * a, a);                        // premultiplied
}
"""
