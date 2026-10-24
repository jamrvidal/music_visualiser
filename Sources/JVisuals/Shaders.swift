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
    float shade = 0.35 + 0.65 * in.uv.y;
    return float4(in.color.rgb * shade, 1.0);
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

fragment float4 present_fragment(FSOut in [[stage_in]],
                                 texture2d<float> accum [[texture(0)]],
                                 constant PresentUniforms &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 light = accum.sample(s, in.uv, level(0.0)).rgb;
    float3 bloom = accum.sample(s, in.uv, level(2.0)).rgb * 0.5
                 + accum.sample(s, in.uv, level(4.0)).rgb * 0.3
                 + accum.sample(s, in.uv, level(6.0)).rgb * 0.2;
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
