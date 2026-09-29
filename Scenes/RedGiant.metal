//! title: Red Giant
//! order: 3
//
// "Red Giant": a stylised, glowing red/orange star, one per display.
//   bake  – rgb: three channels of seamlessly tiling fBm (read by the frame as a texture);
//           a: a sparse, faint starfield.
//   frame – • the star, a slowly rotating sphere whose surface boils: warped granulation
//             with dark lanes, hot faculae and a few sunspots, mapped through a
//             black-body-ish ramp (deep crimson at the limb, white-hot at the core)
//           • a glossy highlight and a thin chromosphere rim so it reads "shiny"
//           • a corona of streamers flowing outward, and a wide soft halo
//           • prominence loops that rise off the limb, flicker and fade
//           • one dark planet transiting, backlit with a red rim, occluding the glow
//           • a faint anamorphic streak and lens ghosts
// Motion uses the scene clock (U.target.z). All periods divide a day evenly, so the
// clock's daily wrap is seamless. Surface motion is translation through tiling noise,
// never accumulated shear, so it looks the same after hours as after seconds.

constant float SPI = 3.14159265;
constant float NOISE_CELLS = 24.0;

inline float2 noiseTile(constant Uniforms& U) {
    return float2(NOISE_CELLS, max(1.0, round(NOISE_CELLS * U.bake.w / U.bake.z)));
}

inline float pgnoise(float2 p, float2 P) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 i0 = i - P * floor(i / P), i1 = i0 + 1.0;
    i1 -= P * floor(i1 / P);
    float2 ga = hash22(i0) * 2.0 - 1.0;
    float2 gb = hash22(float2(i1.x, i0.y)) * 2.0 - 1.0;
    float2 gc = hash22(float2(i0.x, i1.y)) * 2.0 - 1.0;
    float2 gd = hash22(i1) * 2.0 - 1.0;
    float n = mix(mix(dot(ga, f), dot(gb, f - float2(1, 0)), u.x),
                  mix(dot(gc, f - float2(0, 1)), dot(gd, f - float2(1, 1)), u.x), u.y);
    return 0.5 + 0.85 * n;
}

inline float pfbm(float2 p, float2 P, int octaves) {
    float s = 0.0, a = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        s += a * pgnoise(p, P);
        norm += a;
        p *= 2.0; P *= 2.0;
        a *= 0.5;
    }
    return s / norm;
}

struct StarFrame { float2 c; float R; };

inline StarFrame starFor(constant Uniforms& U) {
    StarFrame S;
    S.R = U.display.w * 0.30;
    S.c = U.display.xy + float2(U.display.z * 0.64, U.display.w * 0.50);
    return S;
}

fragment float4 scene_bake(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 C = noiseTile(U);
    float2 np = in.pos.xy / U.view.xy * C;
    float3 n = float3(pfbm(np, C, 5), pfbm(np + 17.3, C, 5), pfbm(np + 41.9, C, 5));

    float2 pt = globalPoint(in.pos, U);
    float seed = U.misc.w;
    float minSigma = 0.55 / U.view.z;
    float3 sc = float3(0.0);
    float stars = 0.0;
    stars += starLayer(pt, 7.0, 0.10, 0.02, 0.10, 3.0, 0.42, minSigma, seed + 3.0, 0.0, sc);
    stars += starLayer(pt, 22.0, 0.28, 0.04, 0.50, 5.0, 0.55, minSigma, seed + 5.0, 0.0, sc);
    stars += starLayer(pt, 90.0, 0.25, 0.25, 2.0, 5.0, 0.75, minSigma, seed + 9.0, 1.0, sc);
    return float4(n, stars);
}

// temperature -> emitted colour (HDR). ~0.3 deep crimson, ~0.8 orange, >1.1 yellow-white
inline float3 ember(float h) {
    h = max(h, 0.0);
    return float3(3.2 * h, 0.80 * pow(h, 2.8), 0.34 * pow(h, 5.5));
}

// ---- star surface ------------------------------------------------------------

inline float surfaceHeat(float3 n, float t, texture2d<float> nt, float2 C) {
    constexpr sampler rep(filter::linear, address::repeat);
    float lat = asin(clamp(n.y, -1.0, 1.0));
    float lon = atan2(n.x, n.z) + t * (2.0 * SPI / 1440.0);    // one turn per 24 min
    float ky = C.x / (2.0 * C.y);                                // isotropic cells
    float2 uv = float2(lon / (2.0 * SPI) * 2.0, lat / SPI * 2.0 * ky);

    // big, slow convection cells warp the finer granulation
    float3 big = nt.sample(rep, uv * 0.5 + t * float2(0.0011, 0.0007)).rgb;
    float2 warp = big.rg - 0.5;
    float g = nt.sample(rep, uv * 2.0 + warp * 0.45 + t * float2(-0.0021, 0.0033)).b;
    float g2 = nt.sample(rep, uv * 5.0 + warp * 0.7 + float2(g * 0.25, 0.0) + t * float2(0.0040, -0.0027)).r;

    // molten look: bright, thin veins of hot plasma over a darker red body
    float v1 = pow(1.0 - abs(2.0 * g - 1.0), 7.0);
    float v2 = pow(1.0 - abs(2.0 * g2 - 1.0), 9.0);
    float h = 0.50 + 0.40 * (big.b - 0.5);                       // supergranule brightness
    h += 0.42 * v1 * (0.6 + 0.8 * big.b) + 0.18 * v2;
    h += 0.16 * smoothstep(0.58, 0.78, big.b);                   // hot regions

    // sunspots in the active latitudes
    float act = smoothstep(0.05, 0.25, abs(n.y)) * smoothstep(0.55, 0.35, abs(n.y));
    float sp = big.g + (g - 0.5) * 0.06;
    float umbra = smoothstep(0.24, 0.19, sp) * act;
    float pen = smoothstep(0.29, 0.23, sp) * act;
    h *= 1.0 - 0.35 * pen - 0.45 * umbra;
    return h;
}

// ---- transiting planet -------------------------------------------------------

inline float3 planetPos(float t) {
    float a = t * (2.0 * SPI / 480.0) + 1.1;       // 8 minute orbit
    return float3(2.35 * cos(a), -0.28 * sin(a) + 0.06, sin(a));
}
constant float PLANET_R = 0.075;

// ---- frame -------------------------------------------------------------------

fragment float4 scene_frame(VOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            constant Galaxy* G [[buffer(1)]],
                            constant Flare* F [[buffer(2)]],
                            texture2d<float> bg [[texture(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    constexpr sampler rep(filter::linear, address::repeat);
    float t = U.target.z;
    float2 C = noiseTile(U);
    float2 pt = globalPoint(in.pos, U);
    StarFrame S = starFor(U);
    float aaW = 1.0 / (S.R * U.view.z);

    float2 q = (pt - S.c) / S.R;
    float r = length(q);
    float ang = atan2(q.y, q.x);
    float d = max(r - 1.0, 0.0);

    // sky: stars, washed out by the glare near the star
    float2 uv = (pt - U.bake.xy) / U.bake.zw;
    uv.y = 1.0 - uv.y;
    float4 b = bg.sample(smp, uv);
    float3 col = float3(0.0016, 0.0008, 0.0011);
    float glare = exp(-d * 0.9);
    float starA = b.a * (1.0 - 0.85 * glare);
    if (starA > 0.004) {
        float tw = vnoise(pt * 0.09 + float2(U.view.w * 0.4, -U.view.w * 0.27));
        starA *= 1.0 - 0.25 * (1.0 - tw);
    }
    col += float3(0.95, 0.93, 1.0) * starA;

    // planet (needed early: it occludes the glow when in front)
    float3 pp = planetPos(t);
    float pr = PLANET_R * (1.0 + 0.12 * pp.z);
    float2 pd = (q - pp.xy) / pr;
    float prr = length(pd);
    float pCov = saturate((1.0 - prr) * pr / aaW);

    // corona: streamers flowing outward, plus a wide halo
    {
        float a01 = ang / (2.0 * SPI);
        float s1 = bg.sample(rep, float2(a01 * 9.0, d * 0.10 - t * 0.0016)).r;
        float s2 = bg.sample(rep, float2(a01 * 21.0 + 0.3, d * 0.16 - t * 0.0026)).g;
        float streak = pow(smoothstep(0.30, 0.80, s1), 2.0) * 0.8 + pow(smoothstep(0.35, 0.85, s2), 2.0) * 0.6;
        float3 glow = float3(0.0);
        glow += float3(1.00, 0.34, 0.08) * exp(-d * 9.0) * 1.00;
        glow += float3(1.00, 0.22, 0.05) * exp(-d * 3.2) * (0.05 + 0.70 * streak) * 0.60;
        glow += float3(0.80, 0.09, 0.05) * exp(-d * 1.2) * 0.050;
        glow += float3(0.50, 0.05, 0.08) * exp(-d * 0.35) * 0.012;
        glow += float3(1.00, 0.45, 0.30) * exp(-d * 70.0) * 1.3;           // chromosphere rim
        float outside = smoothstep(1.0 - aaW, 1.0 + aaW, r);
        col += glow * outside * (1.0 - (pp.z > 0.0 ? pCov : 0.0));
    }

    // prominences: loops rising off the limb
    if (r > 0.98 && r < 1.6) {
        for (int i = 0; i < 5; i++) {
            float P = (i == 0) ? 96.0 : (i == 1) ? 120.0 : (i == 2) ? 144.0 : (i == 3) ? 160.0 : 180.0;
            float tt = t + float(i) * 37.0;
            float k = floor(tt / P), f = fract(tt / P);
            float3 h = float3(hash12(float2(k, float(i) * 7.1)), hash12(float2(k + 3.3, float(i))),
                              hash12(float2(float(i), k * 1.7)));
            float th = h.x * 2.0 * SPI;
            float2 Nn = float2(cos(th), sin(th)), T = float2(-Nn.y, Nn.x);
            float x = dot(q, T), y = dot(q, Nn) - 0.995;
            float life = pow(sin(SPI * f), 1.5);
            float wdt = 0.05 + 0.09 * h.y;
            float hgt = (0.04 + 0.16 * h.z) * (0.55 + 0.45 * f);
            float e = length(float2(x / wdt, y / hgt));
            float dist = abs(e - 1.0) * min(wdt, hgt);
            float along = atan2(y / hgt, x / wdt);
            float fil = bg.sample(rep, float2(along * 0.4 + h.x * 5.0, t * 0.01 + h.y)).b;
            float w = (0.014 + 0.026 * fil) * (0.7 + 0.3 * sin(along * 3.0 + h.y * 9.0));
            float core = exp(-dist * dist / (w * w));
            float halo = exp(-dist / (w * 3.0)) * 0.25;
            float loop = (core + halo) * smoothstep(-0.01, 0.02, y);
            float3 pc = mix(float3(0.9, 0.12, 0.05), float3(1.0, 0.36, 0.12), core) * loop * life * (0.4 + 1.2 * fil) * 0.8;
            col += pc * (1.0 - (pp.z > 0.0 ? pCov : 0.0));
        }
    }

    // planet behind the star: only its lit face, and only outside the disc
    if (pp.z <= 0.0 && pCov > 0.0) {
        float pz = sqrt(max(0.0, 1.0 - prr * prr));
        float3 pc = float3(0.20, 0.06, 0.04) * (0.3 + 0.7 * pz);
        col = mix(col, pc, pCov * smoothstep(1.0, 1.0 + aaW, r));
    }

    // the star
    float cover = saturate((1.0 - r) / aaW);
    if (cover > 0.0) {
        float z = sqrt(max(0.0, 1.0 - r * r));
        float3 n = float3(q, z);
        const float tilt = 0.0;   // poles on the limb, so the longitude pinch never shows
        float3 bn = float3(n.x, cos(tilt) * n.y - sin(tilt) * n.z, sin(tilt) * n.y + cos(tilt) * n.z);
        float h = surfaceHeat(bn, t, bg, C);
        h *= 0.32 + 0.78 * pow(z, 0.6);                        // limb darkening (redder edge)
        h *= 1.0 + 0.06 * sin(t * (2.0 * SPI / 20.0));          // slow breathing
        float3 sc = ember(h);
        // glossy highlight, upper left, and a hot fresnel rim
        float3 H = normalize(float3(-0.45, 0.50, 0.74));
        float hd = saturate(dot(n, H));
        sc += float3(1.0, 0.90, 0.75) * pow(hd, 220.0) * 0.8;
        sc += float3(1.0, 0.60, 0.30) * pow(hd, 14.0) * 0.12;
        sc += float3(1.0, 0.40, 0.18) * pow(1.0 - z, 5.0) * 0.9;
        col = mix(col, sc, cover);
    }

    // planet in front: a silhouette with a backlit red rim
    if (pp.z > 0.0 && pCov > 0.0) {
        float pz = sqrt(max(0.0, 1.0 - prr * prr));
        float2 toStar = normalize(-pp.xy + 1e-4);
        float back = saturate(dot(normalize(pd + 1e-4), toStar) * 0.5 + 0.5);
        float rim = pow(1.0 - pz, 4.0) * (0.25 + 0.75 * back);
        float nearStar = exp(-max(length(pp.xy) - 1.0, 0.0) * 1.5);
        float3 pc = float3(0.010, 0.004, 0.004) + float3(1.0, 0.30, 0.10) * rim * (0.35 + 1.2 * nearStar);
        col = mix(col, pc, pCov);
    }

    // lens: anamorphic streak and a few ghosts
    {
        float2 dq = q;
        col += float3(1.0, 0.40, 0.16) * exp(-abs(dq.y) * 40.0) * exp(-abs(dq.x) * 0.45) * 0.06;
        float2 dispC = (U.display.xy + U.display.zw * 0.5 - S.c) / S.R;
        for (int i = 0; i < 3; i++) {
            float kk = (i == 0) ? 1.35 : (i == 1) ? 1.85 : 2.6;
            float gr = (i == 0) ? 0.10 : (i == 1) ? 0.22 : 0.06;
            float gd = length(q - dispC * kk) / gr;
            float ring = smoothstep(1.0, 0.85, gd) * (0.35 + 0.65 * smoothstep(0.4, 1.0, gd));
            float3 gc = (i == 1) ? float3(0.40, 0.18, 0.10) : float3(0.55, 0.30, 0.12);
            col += gc * ring * 0.035;
        }
    }

    return present(col * U.misc.x, in.pos.xy);
}
