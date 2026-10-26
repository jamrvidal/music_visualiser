// Compiled at runtime with MTLDevice.makeLibrary(source:) so no Xcode Metal toolchain is needed.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FSOut {
    float4 position [[position]];
    float2 uv;
    float2 ndc;
};

vertex FSOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut out;
    out.ndc = p * 2.0 - 1.0;
    out.position = float4(out.ndc, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// Blended as dest * (1 - alpha): fades the persistence buffer towards black.
fragment float4 fade_fragment(FSOut in [[stage_in]], constant float &keep [[buffer(0)]]) {
    return float4(0.0, 0.0, 0.0, 1.0 - keep);
}

// MARK: Beam segments (scope traces and spectrum lines)

struct Segment { float2 a; float2 b; float4 color; float intensity; };
struct SegmentUniforms { float2 viewport; float width; float energy; };

struct SegmentOut {
    float4 position [[position]];
    float2 px;
    float2 a [[flat]];
    float2 b [[flat]];
    float3 color [[flat]];
};

vertex SegmentOut segment_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device Segment *segments [[buffer(0)]],
                                 constant SegmentUniforms &u [[buffer(1)]]) {
    Segment s = segments[iid];
    float2 a = (s.a * 0.5 + 0.5) * u.viewport;
    float2 b = (s.b * 0.5 + 0.5) * u.viewport;
    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 1e-3 ? d / len : float2(1.0, 0.0);
    float2 n = float2(-dir.y, dir.x);
    float r = u.width * 4.0;
    float2 p = ((vid & 1) ? b + dir * r : a - dir * r) + n * ((vid & 2) ? r : -r);

    SegmentOut out;
    out.position = float4(p / u.viewport * 2.0 - 1.0, 0.0, 1.0);
    out.px = p;
    out.a = a;
    out.b = b;
    // energy 1: equal energy per sample, so a fast beam spreads thin and a slow one burns (CRT).
    // energy 0: equal energy per unit length, so a drawn curve has even brightness.
    float weight = mix(len, u.width, u.energy) / (len + u.width);
    out.color = s.color.rgb * s.intensity * weight;
    return out;
}

fragment float4 segment_fragment(SegmentOut in [[stage_in]], constant SegmentUniforms &u [[buffer(0)]]) {
    float2 pa = in.px - in.a;
    float2 ba = in.b - in.a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    float d = length(pa - ba * h) / u.width;
    float glow = exp(-d * d) + 0.15 * exp(-d);
    return float4(in.color * glow, 1.0);
}

// MARK: Rectangles (spectrum bars)

// color.w is the axis the bar grows along: 0 = up (shade by y), 1 = right (shade by x).
struct Rect { float4 bounds; float4 color; };

struct RectOut {
    float4 position [[position]];
    float2 uv;
    float4 color [[flat]];
};

vertex RectOut rect_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device Rect *rects [[buffer(0)]]) {
    Rect r = rects[iid];
    float2 uv = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
    RectOut out;
    out.position = float4(mix(r.bounds.xy, r.bounds.zw, uv), 0.0, 1.0);
    out.uv = uv;
    out.color = r.color;
    return out;
}

fragment float4 rect_fragment(RectOut in [[stage_in]]) {
    float shade = 0.35 + 0.65 * (in.color.w > 0.5 ? in.uv.x : in.uv.y);
    // Fade the outermost pixel by how much of it the bar covers, so thin bars glide instead of
    // snapping a whole pixel at a time.
    float2 edge = min(in.uv, 1.0 - in.uv) / max(fwidth(in.uv), float2(1e-5));
    float coverage = saturate(min(edge.x, edge.y) + 0.5);
    return float4(in.color.rgb * shade * coverage, 1.0);
}

// MARK: Occlusion masks (terrain)

// Solid black drawn (without blending) under each terrain ridge, back to front, so nearer ridges
// hide the ones behind them.
struct MaskOut { float4 position [[position]]; };

vertex MaskOut mask_vertex(uint vid [[vertex_id]], const device float2 *points [[buffer(0)]]) {
    MaskOut out;
    out.position = float4(points[vid], 0.0, 1.0);
    return out;
}

fragment float4 mask_fragment(MaskOut in [[stage_in]]) {
    return float4(0.0, 0.0, 0.0, 1.0);
}

// MARK: Present (bloom, tone map, CRT dressing) on plain black

struct PresentUniforms {
    float4 gridTint;
    float2 viewport;
    float exposure;
    float bloom;
    float grid;
    float scanlines;
};

// One bloom layer from a downscaled mip. Four bilinear taps a texel apart form a tent filter, which hides
// the blocky look a single stretched low-res sample has.
float3 bloomLayer(texture2d<float> accum, sampler s, float2 uv, float lod, float2 viewport) {
    float2 texel = exp2(lod) / viewport;
    return 0.25 * (accum.sample(s, uv + texel * float2( 1,  1), level(lod)).rgb
                 + accum.sample(s, uv + texel * float2(-1,  1), level(lod)).rgb
                 + accum.sample(s, uv + texel * float2( 1, -1), level(lod)).rgb
                 + accum.sample(s, uv + texel * float2(-1, -1), level(lod)).rgb);
}

fragment float4 present_fragment(FSOut in [[stage_in]],
                                 texture2d<float> accum [[texture(0)]],
                                 constant PresentUniforms &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 light = accum.sample(s, in.uv, level(0.0)).rgb;
    float3 bloom = bloomLayer(accum, s, in.uv, 1.5, p.viewport) * 0.5
                 + bloomLayer(accum, s, in.uv, 3.5, p.viewport) * 0.3
                 + bloomLayer(accum, s, in.uv, 5.5, p.viewport) * 0.2;
    light += bloom * p.bloom;
    float3 c = 1.0 - exp(-light * p.exposure);

    if (p.grid > 0.0) {
        float2 div = float2(10.0, 8.0);
        float2 dist = abs(fract(in.uv * div + 0.5) - 0.5) / div * p.viewport;
        float line = 1.0 - smoothstep(0.5, 1.5, min(dist.x, dist.y));
        float2 axis = abs(in.ndc) * 0.5 * p.viewport;
        float centre = 1.0 - smoothstep(0.5, 1.5, min(axis.x, axis.y));
        c += p.gridTint.rgb * max(line, centre * 1.6) * p.grid * (1.0 - c);
    }
    if (p.scanlines > 0.0) {
        float sl = 0.5 + 0.5 * cos(in.position.y * 3.14159265);
        c *= 1.0 - p.scanlines * (1.0 - sl);
    }
    return float4(c, 1.0);
}
"""
