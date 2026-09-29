//! title: Jupiter
//! order: 2
//
// "Jupiter": the gas giant hanging in space beside you, one per display.
//   bake  – rgb: three channels of seamlessly tiling fBm, so the frame can read
//           cloud noise with a texture fetch instead of computing it;
//           a: a sparse, faint starfield.
//   frame – the planet, ray-cast as a sphere every frame:
//           • zonal jets: each latitude drifts at its own speed, alternating east/west,
//             so bands slide past each other and shear their eddies into streaks
//           • wavy belt edges, festoons off the equator, fine turbulent detail
//           • the Great Red Spot turning slowly in its pale collar, white ovals
//             drifting along their belt
//           • Io, Europa and Ganymede orbiting, with their shadows crossing the clouds
//           • soft terminator, strong limb darkening, blue-white limb haze
// Motion uses the scene clock (U.target.z), so the Motion setting scales it. Moon and
// spot periods divide a day evenly, so the clock's daily wrap doesn't make them jump.
// The jets would shear the clouds without limit (streaks, then moiré), so the flow
// runs in two phases that each reset every FLOW_T seconds, cross-faded half a cycle
// apart (the classic flow-map trick); shear never exceeds FLOW_T seconds' worth.

constant float JPI = 3.14159265;

struct PlanetFrame {
    float2 c;   // centre, global points
    float R;    // radius, points
};

inline PlanetFrame planetFor(constant Uniforms& U) {
    PlanetFrame P;
    P.R = U.display.w * 0.40;
    P.c = U.display.xy + float2(U.display.z * 0.63, U.display.w * 0.48);
    return P;
}

// light: from the upper left and a little in front, so a slice of night shows on the right
constant float3 LIGHT = float3(-0.80, 0.24, 0.52);

constant float FLOW_T = 360.0;
constant float NOISE_CELLS = 24.0; // noise lattice cells across the tile

// tile size in noise cells; both passes derive it from the bake rect
inline float2 noiseTile(constant Uniforms& U) {
    return float2(NOISE_CELLS, max(1.0, round(NOISE_CELLS * U.bake.w / U.bake.z)));
}

// gradient noise whose lattice repeats every P cells
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

fragment float4 scene_bake(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 C = noiseTile(U);
    float2 np = in.pos.xy / U.view.xy * C;
    float3 n = float3(pfbm(np, C, 5), pfbm(np + 17.3, C, 5), pfbm(np + 41.9, C, 5));

    float2 pt = globalPoint(in.pos, U);
    float seed = U.misc.w;
    float minSigma = 0.55 / U.view.z;
    float3 sc = float3(0.0);
    float stars = 0.0;
    stars += starLayer(pt, 7.0, 0.12, 0.02, 0.12, 3.0, 0.42, minSigma, seed + 2.0, 0.0, sc);
    stars += starLayer(pt, 22.0, 0.30, 0.04, 0.55, 5.0, 0.55, minSigma, seed + 4.0, 0.0, sc);
    stars += starLayer(pt, 90.0, 0.25, 0.25, 2.2, 5.0, 0.75, minSigma, seed + 8.0, 1.0, sc);
    return float4(n, stars);
}

// ---- cloud deck ------------------------------------------------------------

// soft-edged plateau around latitude c (degrees), half-width w
inline float bandMask(float L, float c, float w) {
    return smoothstep(w, w * 0.4, abs(L - c));
}

// 0 = pale zone, 1 = dark belt
inline float beltness(float L) {
    float b = 0.0;
    b += 1.00 * bandMask(L, 13.0, 6.0);   // North Equatorial Belt
    b += 0.95 * bandMask(L, -13.5, 6.5);  // South Equatorial Belt
    b += 0.55 * bandMask(L, 27.5, 2.8);   // North Temperate Belt
    b += 0.60 * bandMask(L, -29.5, 3.0);  // South Temperate Belt
    b += 0.40 * bandMask(L, 36.5, 2.4);
    b += 0.40 * bandMask(L, -38.5, 2.6);
    b += 0.30 * bandMask(L, 44.0, 2.0);
    b += 0.20 * bandMask(L, 0.5, 1.4);    // faint equatorial band
    return saturate(b);
}

// zonal wind (radians of longitude per second), alternating jets
inline float zonal(float L) {
    return 0.0022 * cos(L * 0.40)
         + 0.0040 * exp(-pow((L - 23.0) / 2.5, 2.0))     // the strong 23°N jet
         - 0.0022 * exp(-pow((L + 18.0) / 3.0, 2.0))
         + 0.0012 * exp(-pow(L / 6.0, 2.0));
}

struct CloudNoise {
    float2 q;     // large-scale warp, zero mean
    float w;      // swirled detail, zero mean
    float fest;   // festoon field, zero mean
    float spot;   // Great Red Spot swirl, zero mean
};

// one flow phase: the clouds advected by `disp` seconds of jet flow
inline CloudNoise cloudPhase(float u, float L, float disp, float cycle, texture2d<float> nt, float2 C) {
    constexpr sampler rep(filter::linear, address::repeat);
    float lat = L * (JPI / 180.0);
    float2 off = hash22(float2(cycle, 3.7)) * C;   // fresh pattern every cycle
    float X = u - disp * zonal(L);
    float2 N = float2(X * 5.0, lat * 15.0) + off;

    CloudNoise o;
    float3 a = nt.sample(rep, (N * 0.8) / C).rgb;
    o.q = a.rg - 0.5;
    float2 N2 = N + o.q * 2.4;
    float3 d = nt.sample(rep, (N2 * float2(1.7, 1.4)) / C).rgb;
    o.w = d.b - 0.5;
    o.fest = d.r - 0.5;

    // the spot turns rigidly inside and shears only through its collar
    float2 e = float2((u + 0.22) / 0.30, (L + 22.5) / 7.5);
    float r = length(e);
    o.spot = 0.0;
    if (r < 1.6) {
        float ang = disp * (2.0 * JPI / 240.0) * (1.0 - smoothstep(0.65, 1.2, r)) + r * 2.4;
        float c = cos(ang), s = sin(ang);
        float2 er = float2(c * e.x - s * e.y, s * e.x + c * e.y);
        o.spot = nt.sample(rep, (er * 2.2 + off + 5.0) / C).g - 0.5;
    }
    return o;
}

inline float3 cloudColor(float u, float L, float t, texture2d<float> nt, float2 C) {
    float lat = L * (JPI / 180.0);

    // two flow phases half a cycle apart; blend preserving variance so the
    // cross-fade doesn't visibly soften the clouds
    float ph = fract(t / FLOW_T);
    float cyc = floor(t / FLOW_T);
    float phB = fract(ph + 0.5);
    float cycB = floor(t / FLOW_T + 0.5) + 1000.0;
    float wA = 1.0 - abs(2.0 * ph - 1.0), wB = 1.0 - wA;
    CloudNoise A = cloudPhase(u, L, ph * FLOW_T, cyc, nt, C);
    CloudNoise B = cloudPhase(u, L, phB * FLOW_T, cycB, nt, C);
    float k = rsqrt(wA * wA + wB * wB);
    float2 q = (A.q * wA + B.q * wB) * k;
    float w = (A.w * wA + B.w * wB) * k;
    float festN = (A.fest * wA + B.fest * wB) * k;
    float spotN = (A.spot * wA + B.spot * wB) * k;
    float w2 = w + 0.5;

    float Lp = L + q.x * 5.5 + w * 3.2;   // wavy belt edges
    float b = beltness(Lp);

    float3 zone = float3(0.88, 0.80, 0.66);
    float3 belt = mix(float3(0.50, 0.28, 0.15), float3(0.60, 0.32, 0.17), smoothstep(5.0, -5.0, L));
    zone = mix(zone, float3(0.92, 0.74, 0.48), bandMask(L, 0.0, 7.0) * 0.5); // ochre equatorial zone
    float3 col = mix(zone, belt, b);
    // belts are full of lighter rifts and darker knots; zones are calmer
    col *= mix(0.88 + 0.24 * w2, 0.62 + 0.76 * w2, b);

    // festoons: blue-grey plumes trailing off the north edge of the equatorial zone
    float fest = bandMask(Lp, 6.5, 2.4) * smoothstep(0.08, 0.26, festN);
    col = mix(col, float3(0.36, 0.39, 0.44), fest * 0.65);

    // polar regions: cooler, greyer, mottled
    float polar = smoothstep(40.0, 64.0, abs(L));
    col = mix(col, float3(0.46, 0.45, 0.46) * (0.75 + 0.5 * w2), polar * 0.85);

    // fine horizontal streaks (single octave, so it can't alias)
    col *= 1.0 + 0.14 * (gnoise(float2(u * 3.0, lat * 110.0 + w * 6.0)) - 0.5);

    // white ovals drifting along the south temperate belt
    for (int i = 0; i < 3; i++) {
        float Lo = -33.5 + float(i) * 0.6;
        float uo = fract((float(i) * 0.37 + 0.12 + t * zonal(Lo) / (2.0 * JPI))) * 2.0 * JPI - JPI;
        float2 e = float2((u - uo) / 0.075, (L - Lo) / 2.2);
        float d = length(e);
        col = mix(col, float3(0.99, 0.96, 0.90) * (0.92 + 0.16 * w2), smoothstep(1.0, 0.35, d) * 0.95);
        col *= 1.0 - 0.25 * smoothstep(1.0, 0.9, d) * smoothstep(1.35, 1.0, d);
    }

    // the Great Red Spot: fixed in view longitude, the jets flow past it
    {
        float2 e = float2((u + 0.22) / 0.30, (L + 22.5) / 7.5);
        float d = length(e);
        if (d < 1.6) {
            float sw = spotN + 0.5;
            float3 spot = mix(float3(0.66, 0.22, 0.11), float3(0.90, 0.50, 0.30), smoothstep(0.3, 0.75, sw));
            spot = mix(float3(0.60, 0.24, 0.15), spot, smoothstep(0.0, 0.55, d)); // darker heart
            float inside = smoothstep(1.0, 0.82, d);
            float collar = smoothstep(0.80, 1.0, d) * smoothstep(1.45, 1.02, d);
            col = mix(col, float3(0.95, 0.90, 0.80) * (0.9 + 0.2 * sw), collar * 0.75);
            col = mix(col, spot, inside);
        }
    }
    return col;
}

// ---- moons -----------------------------------------------------------------

struct Moon {
    float3 p;    // position in planet radii (view space, z toward the viewer)
    float r;     // radius in planet radii
    float3 c1, c2;
    float kind;  // 0 Io, 1 Europa, 2 Ganymede
};

inline Moon moon(int i, float t) {
    Moon m;
    float A, period, ph;
    if (i == 0)      { A = 1.55; period = 144.0; ph = 0.3; m.r = 0.034; m.c1 = float3(0.95, 0.80, 0.35); m.c2 = float3(0.70, 0.35, 0.15); m.kind = 0.0; }
    else if (i == 1) { A = 2.25; period = 288.0; ph = 2.1; m.r = 0.030; m.c1 = float3(0.92, 0.88, 0.80); m.c2 = float3(0.62, 0.44, 0.30); m.kind = 1.0; }
    else             { A = 3.20; period = 576.0; ph = 4.4; m.r = 0.046; m.c1 = float3(0.62, 0.58, 0.52); m.c2 = float3(0.34, 0.31, 0.28); m.kind = 2.0; }
    float a = t * (2.0 * JPI / period) + ph;
    m.p = float3(A * cos(a), 0.0, A * sin(a));
    m.p.y = m.p.z * -0.07 + 0.02; // orbits seen nearly edge-on
    return m;
}

// colour (rgb) and coverage (a) of moon m at planet-space point q
inline float4 drawMoon(Moon m, float2 q, float aaW, float3 L) {
    float2 d = (q - m.p.xy) / m.r;
    float rr = length(d);
    float cov = saturate((1.0 - rr) * m.r / aaW);
    if (cov <= 0.0) return float4(0.0);
    float z = sqrt(max(0.0, 1.0 - rr * rr));
    float3 n = float3(d, z);
    float tex = fbm(d * 3.0 + m.kind * 7.0, 4);
    float3 alb = mix(m.c2, m.c1, smoothstep(0.35, 0.65, tex));
    if (m.kind == 1.0) alb *= 1.0 - 0.35 * pow(ridged(d * 2.5 + 3.0, 3), 3.0); // Europa's lineae
    float lit = saturate(dot(n, L) * 1.05 + 0.02);
    return float4(alb * lit * (0.75 + 0.25 * z), cov);
}

// ---- frame -----------------------------------------------------------------

fragment float4 scene_frame(VOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            constant Galaxy* G [[buffer(1)]],
                            constant Flare* F [[buffer(2)]],
                            texture2d<float> bg [[texture(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float t = U.target.z;
    float2 pt = globalPoint(in.pos, U);
    PlanetFrame P = planetFor(U);
    float3 L = normalize(LIGHT);
    float aaW = 1.0 / (P.R * U.view.z); // one pixel in planet radii

    // sky
    float2 uv = (pt - U.bake.xy) / U.bake.zw;
    uv.y = 1.0 - uv.y;
    float4 b = bg.sample(smp, uv);
    float3 col = float3(0.0010, 0.0011, 0.0020) + float3(0.93, 0.96, 1.0) * b.a;
    if (b.a > 0.004) {
        float tw = vnoise(pt * 0.09 + float2(U.view.w * 0.4, -U.view.w * 0.27));
        col *= 1.0 - 0.22 * (1.0 - tw) * saturate(b.a * 3.0);
    }

    // planet, slightly rolled
    float2 q = (pt - P.c) / P.R;
    const float roll = 0.05;
    q = float2(cos(roll) * q.x - sin(roll) * q.y, sin(roll) * q.x + cos(roll) * q.y);
    float rr = length(q);

    Moon ms[3] = { moon(0, t), moon(1, t), moon(2, t) };

    // moons behind the planet
    for (int i = 0; i < 3; i++) {
        if (ms[i].p.z >= 0.0) continue;
        float4 mc = drawMoon(ms[i], q, aaW, L);
        col = mix(col, mc.rgb, mc.a * saturate((rr - 1.0) / aaW)); // hidden behind the disc
    }

    // atmospheric glow just outside the lit limb
    if (rr > 0.98 && rr < 1.12) {
        float side = saturate(dot(q / max(rr, 1e-4), normalize(L.xy)) * 0.7 + 0.35);
        col += float3(0.28, 0.36, 0.55) * 0.10 * exp(-(rr - 1.0) * 55.0) * side * step(1.0, rr);
    }

    float cover = saturate((1.0 - rr) / aaW);
    if (cover > 0.0) {
        float z = sqrt(max(0.0, 1.0 - rr * rr));
        float3 n = float3(q, z);
        // tip the view so a little more of the south (and the Red Spot) faces us
        const float tilt = -0.14;
        float3 bn = float3(n.x, cos(tilt) * n.y - sin(tilt) * n.z, sin(tilt) * n.y + cos(tilt) * n.z);
        float Ldeg = asin(clamp(bn.y, -1.0, 1.0)) * (180.0 / JPI);
        float u = atan2(bn.x, bn.z + 1e-5);

        float3 alb = cloudColor(u, Ldeg, t, bg, noiseTile(U));

        float ndl = dot(n, L);
        float lit = smoothstep(-0.12, 0.50, ndl) * (0.25 + 0.75 * saturate(ndl));
        float limb = 0.45 + 0.55 * pow(z, 0.55);
        float3 pc = alb * lit * limb * 0.95;
        pc += float3(0.50, 0.60, 0.80) * pow(1.0 - z, 3.0) * 0.30 * saturate(ndl + 0.2); // limb haze
        pc += alb * 0.004;                                                                   // earthshine-dim night side

        // moon shadows: cast along the light onto the sphere
        for (int i = 0; i < 3; i++) {
            float3 mp = ms[i].p;
            float bq = dot(mp, L);
            float disc = bq * bq - (dot(mp, mp) - 1.0);
            if (disc <= 0.0) continue;
            float s = bq - sqrt(disc);
            if (s <= 0.0) continue;
            float3 sp = mp - L * s;
            float dd = length(n - sp) / ms[i].r;
            pc *= mix(0.04, 1.0, smoothstep(0.85, 1.15, dd)); // umbra with a soft penumbra
        }
        col = mix(col, pc, cover);
    }

    // moons in front
    for (int i = 0; i < 3; i++) {
        if (ms[i].p.z < 0.0) continue;
        float4 mc = drawMoon(ms[i], q, aaW, L);
        col = mix(col, mc.rgb, mc.a);
    }

    return present(col * U.misc.x, in.pos.xy);
}
