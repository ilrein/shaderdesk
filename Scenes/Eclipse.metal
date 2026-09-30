//! title: Eclipse
//! order: 2
//! bloom: 0.06
//! tags: Stars
//
// "Eclipse": a total solar eclipse over a dark ridge line, one sun per display.
//   bake  – rgb: three channels of seamlessly tiling fBm; a: a sparse starfield.
//   frame – • the corona: pearly white, falling off steeply from the limb, with fine
//             radial rays that bend toward the equator the way the field lines do,
//             big helmet streamers that taper to points, polar plumes over dim holes
//           • the pink chromosphere and prominences at the edge of the Moon
//           • the Moon itself, faintly lit by earthshine, with darker maria
//           • the Moon rocks slowly along its path (a stylised, seamless loop). At each
//             end of the swing its rough limb uncovers the Sun: first Baily's beads
//             through the valleys, then the diamond ring, with a glare that briefly
//             lights up the sky and drowns the corona
//           • a deep twilight sky with the 360° sunset glow along the horizon, Venus,
//             a few stars, and two layers of mountain silhouettes
// Motion uses the scene clock (U.target.z); every period divides a day evenly.

constant float EPI = 3.14159265;
constant float MOON_K = 1.032;      // Moon radius / Sun radius
constant float SWING_T = 360.0;     // seconds per full rock of the Moon (two diamond rings)
constant float SWING_A = 0.046;     // quick excursion at each end of the rock (sun radii)
constant float DRIFT_A = 0.012;     // slow part of the rock (sun radii)
constant float EQ = 0.38;           // tilt of the solar equator (radians)

struct SunFrame { float2 c; float R; };

inline SunFrame sunFor(constant Uniforms& U) {
    SunFrame S;
    S.R = U.display.w * 0.19;
    S.c = U.display.xy + float2(U.display.z * 0.58, U.display.w * 0.56);
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
    stars += starLayer(pt, 26.0, 0.22, 0.02, 0.18, 4.0, 0.50, minSigma, seed + 3.0, 0.0, sc);
    stars += starLayer(pt, 120.0, 0.30, 0.20, 1.2, 4.0, 0.70, minSigma, seed + 9.0, 1.0, sc);
    return float4(n, stars);
}

// Moon centre relative to the Sun (sun radii). A slow sinusoidal drift, plus a sharp
// |s|^41 excursion at each end: long totality, then ~10 s of beads and diamond ring.
inline float2 moonOffset(float t, thread float2& dir) {
    dir = normalize(float2(1.0, 0.32));
    float s = sin(2.0 * EPI * (t - 47.0) / SWING_T);
    return dir * (DRIFT_A * s + SWING_A * sign(s) * pow(abs(s), 41.0));
}

// lunar limb: radius as a function of angle; mountains and valleys a few ‰ high.
// The angle's seam sits 90° from the contact points, where it's always covered.
inline float moonLimb(float phi) {
    float x = phi * 45.0 + 40.0;
    return MOON_K + 0.008 * (fbm1(x, 3) - 0.44);
}

inline float wrapAngle(float a) { return atan2(sin(a), cos(a)); }

fragment float4 scene_frame(VOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            constant Galaxy* G [[buffer(1)]],
                            constant Flare* F [[buffer(2)]],
                            texture2d<float> bg [[texture(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    constexpr sampler rep(filter::linear, address::repeat);
    float t = U.target.z;
    float2 pt = globalPoint(in.pos, U);
    SunFrame S = sunFor(U);
    float pxR = S.R * U.view.z;                 // pixels per sun radius

    float2 q = (pt - S.c) / S.R;
    float r = length(q);
    float a = atan2(q.y, q.x);
    float d = max(r - 1.0, 0.0);

    // ---- Moon and how much Sun it lets through --------------------------------
    float2 dir;
    float2 mo = moonOffset(t, dir);
    float2 perp = float2(-dir.y, dir.x);
    float2 qm = q - mo;
    float rm = length(qm);
    float Rm = moonLimb(atan2(dot(qm, dir), dot(qm, perp)));
    float moonCover = saturate(0.5 - (rm - Rm) * pxR);

    // diamond-ring strength from the deepest uncovered sliver at the contact point
    float mol = length(mo);
    float2 cdir = mol > 1e-5 ? -mo / mol : -dir;
    float2 cp = cdir;                                           // contact point on the limb
    float cphi = atan2(dot(cp - mo, dir), dot(cp - mo, perp));
    float depth = length(cp - mo) - moonLimb(cphi);             // >0: sunlight gets through
    float E = smoothstep(0.0, 0.016, depth);
    float E2 = E * E;

    // ---- sky ----------------------------------------------------------------------
    float h = (pt.y - U.display.y) / U.display.w;               // 0 at the bottom, 1 top
    float3 col = mix(float3(0.010, 0.010, 0.022), float3(0.0020, 0.0032, 0.0090), smoothstep(0.0, 0.9, h));
    col += float3(0.70, 0.30, 0.080) * exp(-h * 14.0) * 0.16;   // sunset glow all around
    col += float3(0.60, 0.18, 0.060) * exp(-h * 6.0) * 0.04;
    col += float3(0.30, 0.10, 0.120) * exp(-h * 4.0) * 0.020;
    col += float3(0.50, 0.58, 0.80) * exp(-d * 0.55) * 0.010;   // scattered coronal light
    col *= 1.0 + 1.6 * E2;                                      // the sky brightens at the ring
    col += float3(0.20, 0.30, 0.55) * E2 * 0.02 * smoothstep(0.1, 1.0, h);

    // stars and Venus, lost in the glare near the Sun and at the diamond ring
    float2 uv = (pt - U.bake.xy) / U.bake.zw;
    uv.y = 1.0 - uv.y;
    float4 b = bg.sample(smp, uv);
    float starA = b.a * smoothstep(1.6, 4.5, r) * (1.0 - 0.9 * E) * smoothstep(0.08, 0.3, h);
    if (starA > 0.004) {
        float tw = vnoise(pt * 0.09 + float2(U.view.w * 0.4, -U.view.w * 0.27));
        starA *= 1.0 - 0.3 * (1.0 - tw);
    }
    col += float3(0.92, 0.94, 1.0) * starA;
    {
        float2 dv = (q - float2(-3.6, -0.9)) * S.R;            // points
        float vr2 = dot(dv, dv);
        col += float3(1.0, 0.96, 0.88) * (3.0 * exp(-vr2 / 1.6) + 0.03 * exp(-sqrt(vr2) * 0.22)) * (1.0 - 0.6 * E);
        float2 dj = (q - float2(3.3, 1.35)) * S.R;
        col += float3(1.0, 0.93, 0.82) * (0.9 * exp(-dot(dj, dj) / 1.2)) * (1.0 - 0.8 * E);
    }

    // ---- corona -------------------------------------------------------------------
    if (r > 0.99) {
        float da = a - EQ;
        float eqness = abs(cos(da));
        // follow a ray back to its footpoint: mid-latitude field lines lean equatorward
        float a0 = a + 0.30 * sin(2.0 * da) * (1.0 - 1.0 / r);
        float u = a0 / (2.0 * EPI);
        float lr = log(r);
        // three octaves of hair-fine rays, streaming outward (integer angular
        // frequencies so the texture wraps round the circle; every rate * 86400 is whole)
        float f0 = bg.sample(rep, float2(u * 3.0, lr * 0.05 - t / 2400.0)).b;
        float f1 = bg.sample(rep, float2(u * 9.0 + 0.17, lr * 0.14 - t * 0.00125)).r;
        float f2 = bg.sample(rep, float2(u * 20.0 + 0.31, lr * 0.22 - t * 0.0025)).g;
        float f3 = bg.sample(rep, float2(u * 34.0 + 0.63, lr * 0.30 - t * 0.0025)).b;
        float fineIn = smoothstep(1.02, 1.5, r);
        float rays = 0.30 + 0.9 * pow(smoothstep(0.30, 0.80, f0), 2.0)
                          + 1.1 * pow(smoothstep(0.32, 0.80, f1), 2.0)
                          + 0.8 * pow(smoothstep(0.36, 0.84, f2), 2.0)
                          + 0.6 * pow(smoothstep(0.40, 0.86, f3), 2.0) * (0.4 + 0.6 * fineIn);

        // helmet streamers: bulbous at the base, narrowing to long stalks
        float st = 0.0;
        for (int i = 0; i < 5; i++) {
            float th = EQ + ((i == 0) ? 0.06 : (i == 1) ? EPI - 0.12 : (i == 2) ? 0.62 : (i == 3) ? EPI + 0.55 : -0.72);
            float w  = (i == 0) ? 0.24 : (i == 1) ? 0.27 : (i == 2) ? 0.13 : (i == 3) ? 0.16 : 0.10;
            float bi = (i == 0) ? 1.00 : (i == 1) ? 0.85 : (i == 2) ? 0.55 : (i == 3) ? 0.50 : 0.40;
            th += 0.05 * sin(t * (2.0 * EPI / 1800.0) + float(i) * 2.1);  // slow sway
            float dd = wrapAngle(a0 - th);
            float wr = w * (0.30 + 0.70 * exp(-d * 1.2));
            st += bi * exp(-dd * dd / (wr * wr));
        }

        float holes = mix(0.22, 1.0, smoothstep(0.15, 0.80, eqness));
        float plumes = pow(smoothstep(0.50, 0.85, f2), 3.0) * pow(1.0 - eqness, 2.0);

        float I = 0.0;
        I += 1.30 * pow(r, -7.0) * holes * (0.45 + 0.55 * rays);      // bright inner K-corona
        I += 0.45 * exp(-d * 18.0);                                   // the ring right at the limb
        I += 0.09 * pow(r, -2.4) * holes * rays;                     // extended rays
        I += st * 1.00 * pow(r, -2.6) * (0.35 + 0.75 * rays);        // streamers
        I += plumes * 1.3 * pow(r, -3.6);                            // polar plumes
        // colour: gold at the limb, pearl in the middle, cold violet-blue far out
        float3 cc = mix(float3(1.00, 0.74, 0.42), float3(1.00, 0.93, 0.86), smoothstep(0.0, 0.30, d));
        cc = mix(cc, float3(0.55, 0.68, 1.00), smoothstep(0.35, 1.8, d));
        cc = mix(cc, float3(0.62, 0.45, 1.00), smoothstep(1.6, 4.0, d) * 0.7);
        col += cc * I * (1.0 - 0.55 * E);
        // a wide scattered glow that tints the whole sky
        col += float3(0.30, 0.38, 0.85) * exp(-d * 0.8) * 0.030 * (0.6 + 0.4 * rays) * (1.0 - 0.5 * E);

        // chromosphere: a thin pink shell of spicules
        // (stylised: thick enough to peek out past the Moon's slightly larger disc)
        float sp = bg.sample(rep, float2(a / (2.0 * EPI) * 40.0, d * 2.0 - t * 0.0025)).r;
        float sp2 = bg.sample(rep, float2(a / (2.0 * EPI) * 13.0 + 0.4, 0.37)).g;
        float shell = exp(-d / (0.012 + 0.030 * sp * sp2));
        col += float3(1.0, 0.08, 0.26) * shell * 3.0;

        // prominences: pink loops and hedgerows standing off the limb
        if (r < 1.45) {
            for (int i = 0; i < 8; i++) {
                float P = (i == 0) ? 144.0 : (i == 1) ? 180.0 : (i == 2) ? 160.0 : (i == 3) ? 240.0 : (i == 4) ? 120.0 : (i == 5) ? 200.0 : (i == 6) ? 150.0 : 216.0;
                float tt = t + float(i) * 41.0;
                float k = floor(tt / P), f = fract(tt / P);
                float3 hh = float3(hash12(float2(k, float(i) * 7.1)), hash12(float2(k + 3.3, float(i))),
                                   hash12(float2(float(i), k * 1.7)));
                float th = hh.x * 2.0 * EPI;
                float2 Nn = float2(cos(th), sin(th)), T = float2(-Nn.y, Nn.x);
                float y = dot(q, Nn) - 0.998;
                float x = dot(q, T) - y * (hh.z - 0.5) * 1.6;              // leaning arches
                float life = pow(sin(EPI * f), 2.2);
                float wdt = 0.05 + 0.10 * hh.y;
                float hgt = (0.10 + 0.22 * hh.z) * (0.6 + 0.4 * f);
                float yc = (y + 0.4 * hgt) / (1.4 * hgt);                 // arch centre below the limb
                float e = length(float2(x / wdt, yc));
                float along = atan2(yc, x / wdt);
                float fil = bg.sample(rep, float2(along * 0.35 + hh.x * 5.0, t * 0.008 + hh.y)).b;
                float3 pc;
                if (hh.y > 0.62) {
                    // loop
                    float dist = abs(e - 1.0) * min(wdt, hgt);
                    float w = (0.010 + 0.022 * fil);
                    float core = exp(-dist * dist / (w * w));
                    float strands = bg.sample(rep, float2(along * 1.3 + hh.z * 3.0, e * 0.8 - t * 0.003)).g;
                    float loop = core * (0.4 + 1.2 * smoothstep(0.35, 0.75, strands))
                               + exp(-dist / (w * 2.0)) * 0.14 * exp(-max(e - 1.0, 0.0) * 3.0);
                    loop *= smoothstep(-0.004, 0.012, y);
                    pc = mix(float3(1.0, 0.03, 0.14), float3(1.0, 0.22, 0.34), core) * loop * (0.5 + 1.2 * fil);
                } else {
                    // hedgerow: a flame-like sheet, ragged along the top
                    float fx = bg.sample(rep, float2(x * 1.8 + hh.z * 7.0, y * 0.6 + t * 0.004)).r;
                    float top = hgt * (0.55 + 0.9 * fx);
                    float body = smoothstep(wdt, wdt * 0.5, abs(x)) * smoothstep(top, top * 0.6, y) * smoothstep(-0.004, 0.006, y);
                    pc = mix(float3(0.9, 0.02, 0.12), float3(1.0, 0.20, 0.32), fx) * body * (0.35 + 0.9 * fil) * 0.9;
                }
                col += pc * life * 5.0 * smoothstep(1.45, 1.28, r);
            }
        }
    }

    // ---- photosphere, where the Moon's valleys let it through ------------------------
    float sunIn = saturate(0.5 + (1.0 - r) * pxR);
    if (sunIn > 0.0) {
        float z = sqrt(max(0.0, 1.0 - r * r));
        float3 ph = float3(1.0, 0.94, 0.84) * 60.0 * (0.35 + 0.65 * pow(z, 0.5));
        col = mix(col, ph, sunIn);
    }

    // ---- the Moon: black, with the faintest earthshine ----------------------------------
    if (moonCover > 0.0) {
        float2 C = noiseTile(U);
        float2 mq = qm / MOON_K;
        float mz = sqrt(max(0.0, 1.0 - dot(mq, mq)));
        // squash the texture toward the limb so it reads as a sphere
        float2 muv = mq / (0.45 + 0.55 * mz);
        muv.y *= C.x / C.y;
        float m1 = bg.sample(rep, muv * 0.11 + float2(0.13, 0.71)).r;
        float m2 = bg.sample(rep, muv * 0.45 + float2(0.37, 0.19)).g;
        float m3 = bg.sample(rep, muv * 1.6 + float2(0.71, 0.53)).b;
        float mare = smoothstep(0.56, 0.42, m1 + (m2 - 0.5) * 0.20);
        float alb = mix(1.0, 0.55, mare) * (0.85 + 0.30 * m3);
        alb += 0.35 * pow(smoothstep(0.62, 0.80, m2), 2.0) * (1.0 - mare);   // bright highlands
        // earthshine: lit from the front, slightly from the lower left
        float lit = 0.25 + 0.75 * saturate(dot(float3(mq, mz), normalize(float3(-0.35, -0.25, 0.9))));
        float3 mc = float3(0.45, 0.55, 0.95) * 0.0055 * alb * lit;
        mc *= 1.0 + 1.0 * E2;
        col = mix(col, mc, moonCover);
    }

    // ---- mountains --------------------------------------------------------------------
    {
        float gx = pt.x;
        float far = U.display.y + U.display.w * (0.105 + 0.070 * (fbm1(gx / 260.0 + 3.0, 6) - 0.45));
        float nearR = U.display.y + U.display.w * (0.050 + 0.075 * (fbm1(gx / 420.0 + 11.0, 6) - 0.40));
        float aa = 1.0 / U.view.z;
        float farC = saturate((far - pt.y) / aa + 0.5);
        float nearC = saturate((nearR - pt.y) / aa + 0.5);
        float hf = (far - U.display.y) / U.display.w;
        float3 farCol = (float3(0.70, 0.28, 0.07) * exp(-hf * 14.0) * 0.05 + float3(0.004, 0.005, 0.010)) * (1.0 + 5.0 * E2);
        // thin rim where the glow behind catches the far crest
        farCol += float3(0.6, 0.25, 0.08) * 0.02 * exp(-max(far - pt.y, 0.0) * 1.2);
        col = mix(col, farCol, farC);
        float3 nearCol = float3(0.0012, 0.0012, 0.0018) * (1.0 + 4.0 * E2);
        col = mix(col, nearCol, nearC);
    }

    // ---- diamond-ring glare and lens ghosts (in the lens, so over everything) -------------------------------------------
    if (E > 0.0) {
        float2 g = q - cp;
        float gd = length(g);
        float3 gc = float3(1.0, 0.95, 0.86);
        // the broad glare is held back over the Moon so its disc stays dark
        float onMoon = mix(1.0, 0.3, moonCover);
        float glare = 40.0 * exp(-gd * 90.0)
                    + (7.0 * exp(-gd * 20.0) + 1.2 * exp(-gd * 5.0) + 0.06 * exp(-gd * 1.4) + 0.015 * exp(-gd * 0.5)) * onMoon;
        float2 gs = g * S.R;                                      // points
        float spikes = exp(-abs(gs.y) * 0.9) * exp(-abs(gs.x) * 0.012) + exp(-abs(gs.x) * 0.9) * exp(-abs(gs.y) * 0.02);
        float streak = exp(-abs(g.y) * 70.0) * exp(-abs(g.x) * 2.0);
        col += gc * (glare + (spikes * 0.25 + streak * 0.12) * onMoon) * E2;

        float2 dispC = (U.display.xy + U.display.zw * 0.5 - S.c) / S.R;
        for (int i = 0; i < 4; i++) {
            float kk = (i == 0) ? 0.6 : (i == 1) ? 1.4 : (i == 2) ? 2.1 : 3.2;
            float gr = (i == 0) ? 0.12 : (i == 1) ? 0.35 : (i == 2) ? 0.08 : 0.55;
            float2 gpos = cp + (dispC - cp) * kk;
            float gdd = length(q - gpos) / gr;
            float ring = smoothstep(1.0, 0.8, gdd) * (0.3 + 0.7 * smoothstep(0.3, 1.0, gdd));
            float3 ghc = (i == 1) ? float3(0.25, 0.55, 0.40) : (i == 3) ? float3(0.45, 0.30, 0.60) : float3(0.60, 0.45, 0.25);
            col += ghc * ring * 0.05 * E2;
        }
    }

    return present(col * U.misc.x, in.pos.xy);
}
