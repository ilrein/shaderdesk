// Shared types and helpers, prepended to every scene file. Each scene is compiled
// on its own at runtime, so no Metal toolchain is needed to build the app, and a
// broken scene can't take the others down.
//
// A scene defines:
//   fragment float4 scene_frame(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]],
//                               constant Galaxy* G [[buffer(1)]], constant Flare* F [[buffer(2)]],
//                               texture2d<float> bg [[texture(0)]])     (required, every frame)
//   fragment float4 scene_bake(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]])
//                               (optional; rendered once into `bg`, rgba16Float)
//   fragment float4 scene_lut(...same arguments as scene_frame minus the lut...)
//                               (optional; every frame into a (width x 8) rgba16Float
//                                texture bound to scene_frame as texture(1): put
//                                anything that only depends on x here)
//
// Coordinates: scenes work in *global desktop points* (Cocoa, y up), so a sky
// spanning several displays is one continuous image.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 target;   // global point (x, y) at the bottom-left of the render target;
                     // z = scene clock (seconds, scaled by the Motion speed setting, wraps daily); w unused
    float4 view;     // target size in px (x, y), px per point, time in seconds
    float4 bake;     // baked-background rect in global points: x, y, w, h
    float4 motion;   // sky drift x, y (points), activity 0..1, token pulse 0..1
    float4 misc;     // brightness, galaxy count, flare count, per-display seed
    float4 desk;     // union of all displays: x, y, w, h (points)
    float4 display;  // this display: x, y, w, h (points)
};

struct Galaxy {
    float4 posSize;  // centre x, y (points), radius (points), rotation
    float4 look;     // brightness, inclination, seed, ellipticity 0..1
    float4 tint;     // arm colour rgb, breathe 0/1
};

struct Flare {
    float4 posStart; // x, y (points), start time, size (points)
    float4 color;    // rgb, unused
};

struct VOut { float4 pos [[position]]; };

vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

/// fragment position (px, y down) -> global desktop point (y up)
inline float2 globalPoint(float4 fragPos, constant Uniforms& U) {
    float2 local = float2(fragPos.x, U.view.y - fragPos.y) / U.view.z;
    return U.target.xy + local;
}

/// global x (points) of a column; use in scene_lut, where y is the LUT row
inline float globalX(float4 fragPos, constant Uniforms& U) {
    return U.target.x + fragPos.x / U.view.z;
}

// ---- hashing / noise ----------------------------------------------------------
inline float hash11(float x) {
    x = fract(x * 0.1031);
    x *= x + 33.33;
    x *= x + x;
    return fract(x);
}

inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash12(i), hash12(i + float2(1, 0)), u.x),
               mix(hash12(i + float2(0, 1)), hash12(i + float2(1, 1)), u.x), u.y);
}

/// Gradient noise, roughly 0..1 around 0.5. Smoother than value noise and free of
/// its blocky, grid-aligned features.
inline float gnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 ga = hash22(i) * 2.0 - 1.0;
    float2 gb = hash22(i + float2(1, 0)) * 2.0 - 1.0;
    float2 gc = hash22(i + float2(0, 1)) * 2.0 - 1.0;
    float2 gd = hash22(i + float2(1, 1)) * 2.0 - 1.0;
    float n = mix(mix(dot(ga, f), dot(gb, f - float2(1, 0)), u.x),
                  mix(dot(gc, f - float2(0, 1)), dot(gd, f - float2(1, 1)), u.x), u.y);
    return 0.5 + 0.85 * n;
}

/// fBm of gradient noise; each octave is rotated so no grid direction survives.
inline float fbm(float2 p, int octaves) {
    const float2x2 rot = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
    float s = 0.0, a = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        s += a * gnoise(p);
        norm += a;
        p = rot * p * 2.03 + float2(11.7, 5.3);
        a *= 0.5;
    }
    return s / norm;
}

/// Ridged fBm: thin bright creases where the noise crosses its midpoint, which
/// makes filaments (dust lanes, gas) instead of blobs.
inline float ridged(float2 p, int octaves) {
    const float2x2 rot = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
    float s = 0.0, a = 0.5, norm = 0.0, w = 1.0;
    for (int i = 0; i < octaves; i++) {
        float r = 1.0 - abs(gnoise(p) * 2.0 - 1.0);
        r *= r * w;
        w = saturate(r * 1.6); // later octaves follow the ridges of earlier ones
        s += a * r;
        norm += a;
        p = rot * p * 2.07 + float2(3.1, 17.9);
        a *= 0.5;
    }
    return s / norm;
}

inline float noise1(float x) {
    float i = floor(x), f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i), hash11(i + 1.0), u);
}

inline float fbm1(float x, int octaves) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < octaves; i++) {
        s += a * noise1(x);
        x = x * 2.07 + 13.1;
        a *= 0.5;
    }
    return s;
}

// ---- colour ---------------------------------------------------------------------
/// rough black-body tint: 0 = red dwarf ... 1 = blue giant
inline float3 starColor(float t) {
    const float3 a = float3(1.00, 0.62, 0.38);
    const float3 b = float3(1.00, 0.86, 0.70);
    const float3 c = float3(1.00, 0.97, 0.94);
    const float3 d = float3(0.80, 0.87, 1.00);
    const float3 e = float3(0.62, 0.74, 1.00);
    if (t < 0.30) return mix(a, b, t / 0.30);
    if (t < 0.55) return mix(b, c, (t - 0.30) / 0.25);
    if (t < 0.80) return mix(c, d, (t - 0.55) / 0.25);
    return mix(d, e, saturate((t - 0.80) / 0.20));
}

/// soft filmic curve that keeps the darks dark but not crushed
inline float3 tonemap(float3 x) {
    return 1.0 - exp(-x * 1.15);
}

inline float3 srgbEncode(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

inline float3 srgbDecode(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

/// Final colour for the display: tone-maps `hdr` (linear), then dithers by half a
/// step of the 8-bit output *in display space*, so dark gradients don't band.
/// (Dithering in linear space would be amplified ~10x near black by the sRGB curve,
/// which shows up as static.) The pattern is fixed per pixel, so it never shimmers.
inline float4 present(float3 hdr, float2 px) {
    float3 s = srgbEncode(tonemap(hdr));
    float n = fract(52.9829189 * fract(dot(floor(px), float2(0.06711056, 0.00583715)))) - 0.5; // interleaved gradient noise
    s = saturate(s + n / 255.0);
    return float4(srgbDecode(s), 1.0); // the sRGB target re-encodes this exactly
}

// ---- stars ------------------------------------------------------------------------
/// One layer of randomly placed stars on a jittered grid (cell size in points).
/// Adds colour into `col`, returns summed intensity (used as a twinkle mask).
inline float starLayer(float2 pt, float cell, float prob, float bMin, float bMax, float bPow,
                       float sizePt, float minSigma, float seed, float spikes, thread float3& col) {
    float2 c = floor(pt / cell);
    float total = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 id = c + float2(i, j);
            if (hash12(id + seed * 1.13) > prob) continue;
            float2 sp = (id + 0.1 + 0.8 * hash22(id * 1.37 + seed + 17.0)) * cell;
            float2 d = pt - sp;
            float b = bMin + (bMax - bMin) * pow(hash12(id + seed * 3.1 + 5.0), bPow);
            float sigma = max(sizePt * (0.6 + 0.8 * sqrt(b / bMax)), minSigma);
            float I = b * exp(-dot(d, d) / (2.0 * sigma * sigma));
            if (spikes > 0.0 && b > bMax * 0.35) {
                float k = 1.0 / sigma;
                float2 ad = abs(d) * k;
                float s = exp(-ad.x * 1.4) * exp(-ad.y * 0.13) + exp(-ad.y * 1.4) * exp(-ad.x * 0.13);
                I += b * 0.10 * spikes * s;
                // soft photographic halo, like light scattering in the optics
                I += b * 0.045 * spikes * exp(-length(d) * k * 0.22);
            }
            col += starColor(hash12(id + seed * 7.7 + 11.0)) * I;
            total += I;
        }
    }
    return total;
}
