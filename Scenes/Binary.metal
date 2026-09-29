//! title: Binary
//! order: 6
//! bloom: 0.12
//! tags: Stars
//
// "Binary": an amber giant overflowing onto a white-hot compact companion.
//   • the giant is pulled into a teardrop toward its companion (it fills its Roche
//     lobe). Its surface boils, the limb darkens, and the side facing the companion
//     is lit hotter by it
//   • a stream of gas leaves the tip, curves (Coriolis) and falls onto the companion's
//     accretion disk, glowing hotter as it falls, with clumps flowing along it and a
//     flickering hot spot where it hits
//   • the disk: inclined, differentially rotating spiral structure, white-blue inside,
//     violet at the edge; the compact star in the centre; faint bipolar jets
//   bake – rgb: seamlessly tiling fBm, a: starfield.
// Motion uses the scene clock (U.target.z); every period divides a day evenly.

constant float XPI = 3.14159265;

struct Sys {
    float2 dc;  float dr;       // donor centre, radius (points)
    float2 cc;                  // companion centre
    float da, db, dtilt;        // disk semi-axes (points) and tilt (radians)
    float2 tip;                 // stream start (donor's tip)
    float2 hit;                 // stream end (on the disk rim)
    float2 ctrl;                // stream bezier control
};

inline Sys sysFor(constant Uniforms& U) {
    Sys s;
    float H = U.display.w, W = U.display.z;
    s.dr = H * 0.25;
    s.dc = U.display.xy + float2(W * 0.31, H * 0.50);
    s.cc = U.display.xy + float2(W * 0.73, H * 0.55);
    s.da = H * 0.17;
    s.db = s.da * 0.30;
    s.dtilt = -0.16;
    float2 dir = normalize(s.cc - s.dc);
    s.tip = s.dc + dir * s.dr * 1.24;
    float c = cos(s.dtilt), sn = sin(s.dtilt);
    // lands on the near-left rim of the disk
    float2 rim = float2(-0.80 * s.da, -0.62 * s.db);
    s.hit = s.cc + float2(c * rim.x - sn * rim.y, sn * rim.x + c * rim.y);
    float2 mid = (s.tip + s.hit) * 0.5;
    float2 perp = float2(-dir.y, dir.x);
    s.ctrl = mid - perp * H * 0.11;
    return s;
}

fragment float4 scene_bake(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 C = noiseTile(U);
    float2 np = in.pos.xy / U.view.xy * C;
    float3 n = float3(pfbm(np, C, 6), pfbm(np + 17.3, C, 5), pfbm(np + 41.9, C, 5));
    float2 pt = globalPoint(in.pos, U);
    float seed = U.misc.w;
    float minSigma = 0.55 / U.view.z;
    float3 sc = float3(0.0);
    float stars = 0.0;
    stars += starLayer(pt, 6.0, 0.14, 0.02, 0.12, 3.0, 0.42, minSigma, seed + 4.0, 0.0, sc);
    stars += starLayer(pt, 20.0, 0.30, 0.04, 0.55, 5.0, 0.55, minSigma, seed + 8.0, 0.0, sc);
    stars += starLayer(pt, 85.0, 0.25, 0.25, 2.0, 5.0, 0.75, minSigma, seed + 12.0, 1.0, sc);
    return float4(n, stars);
}

// giant's surface: deep red -> amber -> gold
inline float3 amberRamp(float h) {
    h = max(h, 0.0);
    return float3(2.4 * h, 1.05 * pow(h, 2.0), 0.32 * pow(h, 4.0));
}

// disk: violet edge -> cyan -> white-blue core
inline float3 diskRamp(float h) {
    h = max(h, 0.0);
    return float3(0.30 * h + 0.9 * pow(h, 2.4), 0.55 * h + 0.6 * pow(h, 1.8), 1.5 * h);
}

// two-phase flowing sample (so continuous motion never smears the texture)
inline float flow2(texture2d<float> nt, sampler s, float2 uv, float2 vel, float period, float t, int ch) {
    float ph = fract(t / period), phB = fract(ph + 0.5);
    float wA = 1.0 - abs(2.0 * ph - 1.0), wB = 1.0 - wA;
    float2 oA = hash22(float2(floor(t / period), 5.0));
    float2 oB = hash22(float2(floor(t / period + 0.5), 11.0));
    float4 a = nt.sample(s, uv + vel * ph * period + oA);
    float4 b = nt.sample(s, uv + vel * phB * period + oB);
    float va = ch == 0 ? a.r : (ch == 1 ? a.g : a.b);
    float vb = ch == 0 ? b.r : (ch == 1 ? b.g : b.b);
    return 0.5 + ((va - 0.5) * wA + (vb - 0.5) * wB) * rsqrt(wA * wA + wB * wB);
}

// distance from p to the quadratic bezier (a, c, b), and the curve parameter there
inline float2 bezierDist(float2 p, float2 a, float2 c, float2 b) {
    float best = 1e9, bs = 0.0;
    float2 prev = a;
    for (int i = 1; i <= 24; i++) {
        float s = float(i) / 24.0;
        float2 q = mix(mix(a, c, s), mix(c, b, s), s);
        float2 e = q - prev, w = p - prev;
        float h = saturate(dot(w, e) / dot(e, e));
        float d = length(w - e * h);
        if (d < best) { best = d; bs = (float(i - 1) + h) / 24.0; }
        prev = q;
    }
    return float2(best, bs);
}

fragment float4 scene_frame(VOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            constant Galaxy* G [[buffer(1)]],
                            constant Flare* F [[buffer(2)]],
                            texture2d<float> bg [[texture(0)]]) {
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float t = U.target.z;
    float2 pt = globalPoint(in.pos, U);
    Sys S = sysFor(U);
    float H = U.display.w;
    float px = 1.0 / U.view.z;                                   // one pixel in points

    // ---- sky
    float2 uv = (pt - U.bake.xy) / U.bake.zw;
    uv.y = 1.0 - uv.y;
    float4 bk = bg.sample(rep, uv);
    float4 bn = bg.sample(rep, uv * 0.35 + 0.61);
    float3 col = float3(0.0014, 0.0010, 0.0026);
    col += float3(0.014, 0.004, 0.020) * smoothstep(0.50, 0.90, bn.r) + float3(0.002, 0.006, 0.016) * smoothstep(0.55, 0.9, bn.b);
    float tw = vnoise(pt * 0.09 + float2(U.view.w * 0.4, -U.view.w * 0.27));
    col += float3(0.92, 0.95, 1.0) * bk.a * (0.8 + 0.2 * tw);

    // ---- giant (teardrop toward the companion)
    float2 dirC = normalize(S.cc - S.dc);
    float2 q = pt - S.dc;
    float dq = length(q);
    float ang = dot(q / max(dq, 1e-3), dirC);
    float Rth = S.dr * (1.0 + 0.22 * pow(saturate(ang), 12.0) + 0.03 * ang);   // pulled out toward the tip
    float x = dq / Rth;
    // glow around it
    col += float3(1.0, 0.45, 0.14) * 0.10 * exp(-max(x - 1.0, 0.0) * 5.0) * step(1.0, x);
    col += float3(1.0, 0.40, 0.12) * 0.04 * exp(-max(x - 1.0, 0.0) * 1.4) * step(1.0, x);
    if (x < 1.0 + 2.0 * px / S.dr) {
        float2 u2 = q / Rth;
        float z = sqrt(max(1.0 - dot(u2, u2), 0.0));
        float lon = atan2(u2.x, z) + t * (2.0 * XPI / 1800.0);
        float lat = asin(clamp(u2.y, -1.0, 1.0));
        float2 suv = float2(lon / (2.0 * XPI) * 3.0, lat / XPI * 1.8);
        float g1 = flow2(bg, rep, suv, float2(0.0009, 0.0003), 120.0, t, 0);
        float g2 = flow2(bg, rep, suv * 3.1, float2(-0.0016, 0.0008), 60.0, t, 1);
        float gran = g1 * 0.6 + g2 * 0.4;
        // molten veins: ridges of the flowing noise
        float v1 = 1.0 - abs(2.0 * g1 - 1.0), v2 = 1.0 - abs(2.0 * g2 - 1.0);
        float veins = pow(v1, 6.0) * 0.8 + pow(v2, 9.0) * 0.5;
        float heat = 0.52 + 0.6 * (gran - 0.5) + 0.32 * veins;
        float limb = pow(z, 0.55);
        // irradiated by the companion: the facing hemisphere is hotter
        float face = saturate(dot(float3(u2, z), normalize(float3(dirC, 0.35))));
        float h = heat * (0.52 + 0.48 * limb) * (1.0 + 0.35 * face * face);
        float3 surf = amberRamp(h) * 0.85;
        surf += float3(1.0, 0.55, 0.2) * pow(1.0 - z, 3.0) * 0.6;       // hot rim
        // glossy highlight, upper left
        float3 Nn = float3(u2, z);
        float3 Hh = normalize(float3(-0.45, 0.55, 1.0) + float3(0, 0, 1));
        surf += float3(1.0, 0.85, 0.6) * pow(saturate(dot(Nn, Hh)), 10.0) * 0.10;
        float a = saturate((1.0 - x) * S.dr / px + 0.5);
        col = mix(col, surf, a);
    }

    // ---- stream
    float2 bmin = min(min(S.tip, S.ctrl), S.hit) - H * 0.12, bmax = max(max(S.tip, S.ctrl), S.hit) + H * 0.12;
    if (all(pt > bmin) && all(pt < bmax)) {
        float2 bd = bezierDist(pt, S.tip, S.ctrl, S.hit);
        float s = bd.y;
        float w = H * mix(0.006, 0.020, s);
        float along = s * 3.0 - t * 0.035;                        // gas flows toward the disk
        float n1 = bg.sample(rep, float2(along, bd.x / H * 6.0 + 0.3)).r;
        float n2 = bg.sample(rep, float2(along * 2.3 + 0.4, bd.x / H * 9.0)).g;
        float clumps = saturate(0.35 + 1.4 * (n1 - 0.5) + 0.9 * (n2 - 0.5) + 0.5);
        float core = exp(-pow(bd.x / w, 2.0));
        float haze = exp(-bd.x / (w * 3.5)) * smoothstep(H * 0.11, H * 0.04, bd.x);   // zero before the bbox edge
        float3 hot = mix(float3(1.0, 0.42, 0.12), float3(1.0, 0.78, 0.40), smoothstep(0.1, 0.55, s));
        hot = mix(hot, float3(0.55, 0.80, 1.0), smoothstep(0.55, 1.0, s));
        float I = mix(0.8, 2.0, s) * smoothstep(0.0, 0.05, s);
        col += hot * (core * clumps * 1.0 + haze * 0.10) * I;
    }

    // ---- accretion disk (in its own plane coordinates)
    float c = cos(S.dtilt), sn = sin(S.dtilt);
    float2 d = pt - S.cc;
    float2 dl = float2(c * d.x + sn * d.y, -sn * d.x + c * d.y);   // un-tilt
    float2 dp = float2(dl.x / S.da, dl.y / S.db);                  // unit disk
    float rd = length(dp);
    float phi = atan2(dp.y, dp.x);
    bool front = dl.y < 0.0;                                       // near half (below centre)

    // compact star: glow behind everything else of the disk
    float dc = length(d) / H;
    float3 starGlow = float3(0.75, 0.85, 1.0) * (0.9 * exp(-dc * 70.0) + 0.10 * exp(-dc * 12.0) + 0.02 * exp(-dc * 3.5));
    float starCore = smoothstep(0.0060, 0.0045, dc);

    // jets: along the disk normal (screen-perpendicular to the major axis)
    {
        float2 ax = float2(-sn, c);                               // jet axis in screen space
        float along = dot(d, ax) / H, across = dot(d, float2(c, sn)) / H;
        float aAbs = abs(along);
        float width = 0.003 + aAbs * 0.035;
        float cone = exp(-pow(across / width, 2.0)) * exp(-aAbs * 16.0) * smoothstep(0.0, 0.015, aAbs);
        float knots = bg.sample(rep, float2(aAbs * 2.5 - t * 0.02, across * 0.8 + (along > 0.0 ? 0.3 : 0.7))).b;
        col += float3(0.45, 0.68, 1.0) * cone * (0.4 + 0.8 * smoothstep(0.4, 0.8, knots)) * 0.6;
    }

    col += starGlow;

    if (rd < 1.02) {
        float r = rd;
        float om = 2.0 * XPI / 90.0 * pow(max(r, 0.12), -1.5) * 0.35;
        float lr = log(max(r, 0.05));
        float spiral = flow2(bg, rep, float2(phi / (2.0 * XPI) * 2.0 - lr * 0.35, lr * 1.2),
                             float2(-om / (2.0 * XPI) * 2.0 * 0.2, 0.0), 30.0, t, 0);
        float fine = flow2(bg, rep, float2(phi / (2.0 * XPI) * 6.0, lr * 4.0), float2(-0.01, 0.0), 20.0, t, 2);
        float dens = saturate(0.45 + 1.2 * (spiral - 0.5) + 0.6 * (fine - 0.5));
        dens *= smoothstep(0.10, 0.20, r) * smoothstep(1.02, 0.80, r);
        float T = pow(max(r, 0.12) / 0.2, -1.1);
        float3 e = diskRamp(0.95 * T * (0.6 + 0.8 * dens)) * dens * 1.3;
        e += float3(0.6, 0.75, 1.0) * exp(-pow((r - 1.0) / 0.05, 2.0)) * 0.15;   // lit rim
        // hot spot where the stream lands, flickering
        float2 hp = float2(-0.80, -0.62 / 1.0);
        float hs = exp(-dot(dp - hp * float2(1.0, 1.0), dp - hp) * 30.0);
        float fl = 0.75 + 0.25 * sin(t * 7.0) * sin(t * 2.3 + 1.0);
        e += float3(1.0, 0.9, 0.8) * hs * 1.6 * fl;
        float alpha = saturate(dens * 1.4) * 0.85;
        // the near half of the disk passes in front of the star's glow
        float occl = front ? alpha : 0.0;
        col = (col - starGlow * occl * 0.6) * (1.0 - alpha * 0.6) + e;
    }
    col = mix(col, float3(3.0, 3.2, 3.6), starCore * (front && rd < 0.5 ? 0.4 : 1.0));

    return present(col * U.misc.x, in.pos.xy);
}
