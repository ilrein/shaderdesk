//! title: Neon Horizon
//! order: 7
//! bloom: 0.14
//! tags: Neon
//
// "Neon Horizon": synthwave at night, in hot pink, teal and cyan.
//   • sky: indigo overhead fading to magenta at the horizon, a few stars, slow thin
//     cloud streaks drifting across
//   • a huge striped sun, pink-white to hot pink, its gaps sliding slowly downward
//   • two mountain ridges framing a valley, dark, edged with glowing cyan / pink rim light
//   • a wet black floor with a perspective neon grid scrolling toward the viewer
//     (analytically antialiased, fading into haze before it can moire), mirroring the
//     sun, mountains and sky with rippled, fresnel-weighted reflections
//   • a hot horizon line and a haze band where the floor meets the sky
//   bake – rgb: seamlessly tiling fBm (ripples, clouds), a: starfield.
// Everything is laid out per display (units of display height, y up).
// Motion uses the scene clock (U.target.z); every period divides a day evenly.

constant float HORIZON = 0.40;     // horizon height (display heights from the bottom)
constant float GRID_SPEED = 0.5;   // grid cells per second toward the viewer

constant float3 PINK = float3(1.00, 0.10, 0.55);
constant float3 CYAN = float3(0.05, 0.85, 1.00);
constant float3 TEAL = float3(0.00, 0.55, 0.55);

fragment float4 scene_bake(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 C = noiseTile(U);
    float2 np = in.pos.xy / U.view.xy * C;
    float3 n = float3(pfbm(np, C, 5), pfbm(np + 17.3, C, 5), pfbm(np + 41.9, C, 4));
    float2 pt = globalPoint(in.pos, U);
    float seed = U.misc.w;
    float minSigma = 0.55 / U.view.z;
    float3 sc = float3(0.0);
    float stars = 0.0;
    stars += starLayer(pt, 9.0, 0.10, 0.02, 0.10, 3.0, 0.42, minSigma, seed + 6.0, 0.0, sc);
    stars += starLayer(pt, 30.0, 0.30, 0.04, 0.45, 5.0, 0.55, minSigma, seed + 3.0, 0.0, sc);
    return float4(n, stars);
}

// mountain ridge height at x (display heights), with a valley around the sun
inline float ridgeH(float x, float cx, float seed, float base, float amp, float valley) {
    float h = 0.0, a = 0.5, f = 1.0;
    for (int i = 0; i < 6; i++) {
        float n = noise1(x * f * 4.0 + seed * 13.1);
        h += a * (1.0 - abs(2.0 * n - 1.0));          // ridged: sharp peaks
        a *= 0.5; f *= 2.1;
    }
    float v = smoothstep(valley * 0.35, valley, abs(x - cx));
    return base + amp * h * (0.15 + 0.85 * v);
}

// everything above the horizon, at (x, y) in display heights. `blurry` softens the
// thin details (used for the reflection).
inline float3 skyColor(float x, float y, float cx, float aspect, float t, float blurry,
                       texture2d<float> bg, float2 uv, float px) {
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat);
    float hy = y - HORIZON;                                   // height above horizon
    float s = saturate(hy / (1.0 - HORIZON));
    float3 col = mix(float3(0.42, 0.04, 0.34), float3(0.10, 0.02, 0.20), pow(s, 0.45));
    col = mix(col, float3(0.012, 0.006, 0.035), smoothstep(0.35, 1.0, s));
    // stars (not reflected)
    if (blurry < 0.5) {
        float4 bk = bg.sample(rep, uv);
        col += float3(0.9, 0.85, 1.0) * bk.a * smoothstep(0.12, 0.45, s);
    }

    // thin cloud streaks drifting right, silhouetted against the sun
    {
        float cy = hy;
        float drift = t / 1200.0;                             // 1200 s per wrap
        float c1 = bg.sample(rep, float2(x / aspect * 0.8 + drift, cy * 9.0)).b;
        float band = exp(-pow((cy - 0.13) / 0.035, 2.0)) + 0.7 * exp(-pow((cy - 0.24) / 0.022, 2.0));
        float cl = smoothstep(0.52, 0.72, c1) * band;
        col = mix(col, float3(0.05, 0.01, 0.10) + PINK * 0.06, saturate(cl * 0.7));
    }

    // sun
    float2 sc = float2(cx, HORIZON + 0.16);
    const float SR = 0.24;
    float2 d = float2(x, y) - sc;
    float dr = length(d) / SR;
    float glow = exp(-max(dr - 1.0, 0.0) * 3.5) * 0.35 + exp(-max(dr - 1.0, 0.0) * 12.0) * 0.4;
    col += PINK * glow * 0.8;
    if (dr < 1.02) {
        float v = saturate((d.y / SR) * 0.5 + 0.5);           // 0 bottom, 1 top
        float3 sun = mix(float3(0.95, 0.02, 0.45), float3(1.0, 0.30, 0.45), smoothstep(0.1, 0.75, v));
        sun = mix(sun, float3(1.0, 0.62, 0.42), smoothstep(0.7, 1.0, v)) * 1.05;
        // stripes over the lower half, gaps widening toward the bottom, sliding down
        // (7 stripes per sun radius, 16 s per stripe)
        float band = saturate((0.55 - v) / 0.55);             // 0 at 55% height, 1 at bottom
        float f = fract(d.y / SR * 7.0 + t / 16.0);
        float gap = 0.06 + 0.55 * band;
        float aaS = px / SR * 7.0 * 1.2 + blurry * 0.08;
        float cut = band > 0.0 ? smoothstep(gap - aaS, gap + aaS, f) : 1.0;
        float a = saturate((1.0 - dr) * SR / (px * 1.2 + blurry * 0.003) + 0.5) * cut;
        col = mix(col, sun, a);
    }

    // mountains: far ridge (teal rim), near ridge (pink rim)
    float hf = ridgeH(x, cx, 1.7, HORIZON + 0.015, 0.20, 0.36);
    float hn = ridgeH(x * 0.8 + 3.0, cx * 0.8 + 3.0, 4.3, HORIZON, 0.13, 0.52 * 0.8);
    float aaM = px * 1.2 + blurry * 0.004;
    if (y < hf + 0.12) {
        float inside = smoothstep(hf + aaM, hf - aaM, y);
        float3 m = float3(0.010, 0.012, 0.035) + TEAL * 0.05 * saturate((y - HORIZON) / max(hf - HORIZON, 0.03));
        col = mix(col, m, inside);
        float rim = exp(-abs(y - hf) / (px * 1.4 + blurry * 0.003));
        col += CYAN * rim * 1.6 + CYAN * exp(-max(y - hf, 0.0) / 0.01) * step(hf, y) * 0.12;
    }
    if (y < hn + 0.12) {
        float inside = smoothstep(hn + aaM, hn - aaM, y);
        float3 m = float3(0.008, 0.004, 0.02) + PINK * 0.03 * saturate((y - HORIZON) / max(hn - HORIZON, 0.03));
        col = mix(col, m, inside);
        float rim = exp(-abs(y - hn) / (px * 1.4 + blurry * 0.003));
        col += PINK * rim * 1.8 + PINK * exp(-max(y - hn, 0.0) / 0.012) * step(hn, y) * 0.10;
    }
    // haze just above the horizon
    col += float3(0.9, 0.2, 0.7) * 0.18 * exp(-max(hy, 0.0) / 0.03);
    return col;
}

fragment float4 scene_frame(VOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            constant Galaxy* G [[buffer(1)]],
                            constant Flare* F [[buffer(2)]],
                            texture2d<float> bg [[texture(0)]]) {
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat);
    float t = U.target.z;
    float2 pt = globalPoint(in.pos, U);
    float H = U.display.w;
    float aspect = U.display.z / H;
    float2 q = (pt - U.display.xy) / H;                      // display heights, y up
    float cx = aspect * 0.5;
    float px = 1.0 / (H * U.view.z);                          // one pixel
    float2 uv = (pt - U.bake.xy) / U.bake.zw;
    uv.y = 1.0 - uv.y;

    float3 col;
    if (q.y >= HORIZON) {
        col = skyColor(q.x, q.y, cx, aspect, t, 0.0, bg, uv, px);
    } else {
        // ---- floor: perspective ground plane
        float dy = HORIZON - q.y;                             // below horizon
        const float CAM = 0.09;                               // camera height
        float z = CAM / max(dy, 1e-4);                        // depth
        float X = (q.x - cx) * z;                             // lateral world position
        float2 gw = float2(X * 22.0, z * 22.0 * 0.5 + t * GRID_SPEED);
        float2 fw = fwidth(gw);
        float2 gd = abs(fract(gw + 0.5) - 0.5);               // distance to nearest line (cells)
        float2 lw = float2(0.035, 0.05);
        float2 core = 1.0 - smoothstep(lw - fw, lw + fw, gd);
        float2 halo = exp(-gd / max(fw * 2.5 + 0.04, 1e-4));
        float fadeX = saturate(1.0 - fw.x * 1.6), fadeZ = saturate(1.0 - fw.y * 1.3);
        float near = smoothstep(0.0, 0.5, dy / HORIZON);      // 0 at horizon, 1 at bottom
        float3 lineC = mix(PINK, CYAN, smoothstep(0.05, 0.9, near));
        float3 grid = lineC * ((core.x + halo.x * 0.35) * fadeX + (core.y + halo.y * 0.35) * fadeZ) * 1.6;
        // intersections glow a little brighter
        grid += lineC * core.x * core.y * 1.5 * fadeX * fadeZ;

        // wet reflection: mirror the sky about the horizon, rippled, fresnel-weighted
        float2 rq = float2(q.x, HORIZON + dy);
        float rip = bg.sample(rep, float2(X * 0.6, z * 0.4 + t / 600.0)).r - 0.5;
        float rip2 = bg.sample(rep, float2(X * 2.3 + 0.3, z * 1.3 - t / 400.0)).g - 0.5;
        rq.x += (rip * 0.02 + rip2 * 0.008) * (0.3 + near);
        rq.y += abs(rip2) * 0.004 * near;
        float3 refl = skyColor(rq.x, min(rq.y, 0.999), cx, aspect, t, 1.0, bg, uv, px);
        float fres = mix(0.40, 0.07, smoothstep(0.0, 0.7, near));
        float3 floorC = float3(0.006, 0.004, 0.016) + refl * fres;
        col = floorC + grid * mix(0.5, 1.0, near);
        // haze band where floor meets sky
        col += float3(0.9, 0.2, 0.7) * 0.25 * exp(-dy / 0.012);
    }
    // the horizon line itself
    col += float3(1.0, 0.55, 0.85) * 2.0 * exp(-abs(q.y - HORIZON) / (px * 1.5));

    // gentle vignette
    float2 vc = (q - float2(cx, 0.5)) / float2(aspect, 1.0);
    col *= 1.0 - 0.35 * dot(vc, vc);

    return present(col * U.misc.x, in.pos.xy);
}
