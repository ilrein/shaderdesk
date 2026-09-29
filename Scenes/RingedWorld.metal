//! title: Ringed World
//! order: 5
//! bloom: 0.08
//! tags: Planets
//
// "Ringed World": a banded gas giant with a broad ring system, lit from the side by
// a star just off-screen. Everything is solved per pixel with exact geometry:
//   • planet: a sphere with zonal bands that flow at latitude-dependent speeds, soft
//     terminator, limb darkening and a thin scattering atmosphere at the rim
//   • rings: a plane through the planet's equator with a hand-built radial profile
//     (faint inner ring, dense bright ring, a dark division, an outer ring with a
//     gap, a thin braided outer ringlet) plus fine ringlets and slowly orbiting clumps.
//     Lit side and unlit side are shaded differently: from the unlit side light only
//     leaks through the thin parts
//   • shadows both ways: the rings cast banded shadows onto the planet, the planet
//     casts its shadow across the rings
//   • a small moon on an 18-minute orbit that passes in front and behind, and goes
//     dark when it enters the planet's shadow
//   • glints: ice in the lit rings sparkles faintly
//   bake – rgb: seamlessly tiling fBm (bands, moon), a: starfield.
// Motion uses the scene clock (U.target.z); every period divides a day evenly.

constant float WPI = 3.14159265;
constant float FLOW_T = 300.0;      // seconds per band-flow phase

struct World3 {
    float2 c;       // planet centre (points)
    float R;        // planet radius (points)
    float3 n;       // ring-plane normal = rotation axis (camera looks down -z)
    float3 b1, b2;  // ring-plane basis
    float3 L;       // direction to the star
};

inline World3 worldFor(constant Uniforms& U) {
    World3 w;
    w.R = U.display.w * 0.25;
    w.c = U.display.xy + float2(U.display.z * 0.42, U.display.w * 0.47);
    const float e = 0.40, roll = -0.30;          // ring opening and roll (radians)
    float3 n0 = float3(0.0, cos(e), sin(e));
    float3 b10 = float3(1.0, 0.0, 0.0);
    float cr = cos(roll), sr = sin(roll);
    w.n = float3(cr * n0.x - sr * n0.y, sr * n0.x + cr * n0.y, n0.z);
    w.b1 = float3(cr * b10.x - sr * b10.y, sr * b10.x + cr * b10.y, b10.z);
    w.b2 = cross(w.n, w.b1);
    w.L = normalize(float3(0.78, 0.38, -0.42));
    return w;
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
    stars += starLayer(pt, 6.0, 0.14, 0.02, 0.12, 3.0, 0.42, minSigma, seed + 2.0, 0.0, sc);
    stars += starLayer(pt, 20.0, 0.30, 0.04, 0.55, 5.0, 0.55, minSigma, seed + 7.0, 0.0, sc);
    stars += starLayer(pt, 85.0, 0.25, 0.25, 2.0, 5.0, 0.75, minSigma, seed + 13.0, 1.0, sc);
    return float4(n, stars);
}

// ---- rings ------------------------------------------------------------------------

constant float RING_IN = 1.24;
constant float RING_OUT = 2.36;

// optical depth of the rings at radius r (planet radii); `fine` is 0..1 ringlet noise
inline float ringTau(float r, float fine) {
    float t = 0.0;
    t += 0.10 * smoothstep(1.24, 1.30, r) * smoothstep(1.53, 1.50, r);            // faint inner ring
    t += 1.35 * smoothstep(1.50, 1.58, r) * smoothstep(1.97, 1.93, r)             // dense main ring
         * (0.75 + 0.25 * smoothstep(1.62, 1.80, r));
    t += 0.05 * smoothstep(1.97, 1.99, r) * smoothstep(2.05, 2.03, r);            // division (nearly empty)
    t += 0.55 * smoothstep(2.04, 2.07, r) * smoothstep(2.27, 2.24, r)             // outer ring
         * (1.0 - 0.95 * smoothstep(0.006, 0.0, abs(r - 2.205)));                 // with a narrow gap
    t += 0.35 * exp(-pow((r - 2.33) / 0.006, 2.0));                               // thin outer ringlet
    return t * (0.30 + 1.4 * fine);
}

// ring particle colour by radius: dusty grey inside, bright cream mid, cooler grey outside
inline float3 ringAlbedo(float r) {
    float3 inner = float3(0.55, 0.44, 0.42);
    float3 main_ = float3(1.00, 0.86, 0.68);
    float3 outer = float3(0.80, 0.83, 0.88);
    float3 c = mix(inner, main_, smoothstep(1.48, 1.62, r));
    return mix(c, outer, smoothstep(1.96, 2.08, r));
}

inline float ringFine(float r, texture2d<float> nt) {
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float a = nt.sample(rep, float2(r * 1.7, 0.31)).r;
    float b = nt.sample(rep, float2(r * 6.3, 0.63)).g;
    float c = nt.sample(rep, float2(r * 19.0, 0.12)).b;
    return saturate(0.5 + (a - 0.5) * 1.3 + (b - 0.5) * 1.0 + (c - 0.5) * 0.8);
}

// ---- planet -------------------------------------------------------------------------

// latitude bands: soft cream/gold/teal palette
inline float3 bandColor(float lat, float n) {
    float x = lat + (n - 0.5) * 0.16;
    float s = sin(x * 11.0) * 0.5 + sin(x * 23.0 + 1.3) * 0.3 + sin(x * 5.0 + 0.4) * 0.2;
    float3 cream = float3(1.00, 0.88, 0.66);
    float3 amber = float3(0.96, 0.62, 0.30);
    float3 rust = float3(0.66, 0.34, 0.20);
    float3 c = mix(cream, amber, smoothstep(-0.35, 0.45, s));
    c = mix(c, rust, smoothstep(0.50, 0.95, s) * 0.75);
    // teal towards the poles
    float pole = smoothstep(0.70, 1.20, abs(lat));
    c = mix(c, float3(0.26, 0.58, 0.68), pole * 0.9);
    // bright equatorial zone
    c = mix(c, float3(1.0, 0.93, 0.78), exp(-lat * lat * 90.0) * 0.6);
    return c;
}

// zonal flow speed (radians/second) by latitude
inline float zonal(float lat) {
    return (2.0 * WPI / 1440.0) * (1.0 + 0.10 * cos(lat * 9.0) + 0.14 * exp(-lat * lat * 30.0));
}

inline float bandNoise(float lat, float lon, float t, texture2d<float> nt, float2 C) {
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float ph = fract(t / FLOW_T), phB = fract(ph + 0.5);
    float wA = 1.0 - abs(2.0 * ph - 1.0), wB = 1.0 - wA;
    float v = lat / WPI * (C.y / C.x) * 16.0;                  // stretched: zonal streaks
    float dA = zonal(lat) * ph * FLOW_T, dB = zonal(lat) * phB * FLOW_T;
    float2 oA = hash22(float2(floor(t / FLOW_T), 3.0));
    float2 oB = hash22(float2(floor(t / FLOW_T + 0.5), 9.0));
    float uA = (lon + dA) / (2.0 * WPI), uB = (lon + dB) / (2.0 * WPI);
    float wA2 = nt.sample(rep, float2(uA * 2.0, v * 0.5) + oA * 1.3).b - 0.5;
    float wB2 = nt.sample(rep, float2(uB * 2.0, v * 0.5) + oB * 1.3).b - 0.5;
    float nA = nt.sample(rep, float2(uA * 3.0 + wA2 * 0.3, v + wA2 * 0.8) + oA).r * 0.65
             + nt.sample(rep, float2(uA * 8.0, v * 2.5 + wA2) + oA).g * 0.35;
    float nB = nt.sample(rep, float2(uB * 3.0 + wB2 * 0.3, v + wB2 * 0.8) + oB).r * 0.65
             + nt.sample(rep, float2(uB * 8.0, v * 2.5 + wB2) + oB).g * 0.35;
    return 0.5 + ((nA - 0.5) * wA + (nB - 0.5) * wB) * rsqrt(wA * wA + wB * wB);
}

// ---- frame ----------------------------------------------------------------------------

fragment float4 scene_frame(VOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            constant Galaxy* G [[buffer(1)]],
                            constant Flare* F [[buffer(2)]],
                            texture2d<float> bg [[texture(0)]]) {
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float t = U.target.z;
    float2 C = noiseTile(U);
    float2 pt = globalPoint(in.pos, U);
    World3 W = worldFor(U);
    float2 p = (pt - W.c) / W.R;
    float aa = 1.2 / (W.R * U.view.z);                         // one pixel in planet radii
    const float3 sunCol = float3(1.0, 0.95, 0.88) * 2.2;

    // ---- sky
    float2 uv = (pt - U.bake.xy) / U.bake.zw;
    uv.y = 1.0 - uv.y;
    float4 bk = bg.sample(rep, uv);
    float4 bn = bg.sample(rep, uv * 0.4 + 0.21);
    float3 col = float3(0.0010, 0.0013, 0.0024);
    col += float3(0.004, 0.005, 0.012) * smoothstep(0.55, 0.9, bn.r);
    float tw = vnoise(pt * 0.09 + float2(U.view.w * 0.4, -U.view.w * 0.27));
    col += float3(0.92, 0.95, 1.0) * bk.a * (0.8 + 0.2 * tw);
    // the star is off to the upper right: a wide soft glow from that corner
    float2 sunPt = W.c + normalize(W.L.xy) * W.R * 4.2;
    float ds = length(pt - sunPt) / U.display.w;
    col += float3(1.0, 0.78, 0.52) * (0.05 * exp(-ds * 2.4) + 0.22 * exp(-ds * 7.0) + 1.5 * exp(-ds * 30.0));
    float2 dsv = (pt - sunPt) / U.display.w;
    col += float3(1.0, 0.75, 0.5) * 0.03 * exp(-abs(dsv.y) * 60.0) * exp(-abs(dsv.x) * 1.2);   // anamorphic streak

    float fwd = pow(saturate(-W.L.z), 1.5);                    // how backlit the scene is
    {
        float d = length(p);
        float toward = saturate(dot(p / max(d, 1e-4), normalize(W.L.xy)) * 0.5 + 0.5);
        float halo = exp(-max(d - 1.0, 0.0) * 28.0) * step(1.0, d);
        col += (float3(0.35, 0.65, 1.0) * 0.5 + float3(1.0, 0.75, 0.45) * 0.6 * toward * toward) * halo
               * (0.25 + 2.8 * fwd * pow(toward, 3.0));
    }

    // ---- geometry: planet hit, ring-plane hit (orthographic camera looking down -z)
    float rr = dot(p, p);
    bool hitP = rr < 1.0;
    float3 S = float3(p, sqrt(max(1.0 - rr, 0.0)));
    float tr = dot(W.n, float3(p, 0.0)) / W.n.z;               // ring plane at z = -tr
    float3 P = float3(p, -tr);
    float r = length(P);
    bool ringFront = !hitP || P.z > S.z;

    // ---- moon (in the ring plane, slightly inclined)
    float ma = t * (2.0 * WPI / 1080.0) + 1.1;
    float3 M = 3.05 * (cos(ma) * W.b1 + sin(ma) * W.b2) + W.n * 0.20 * sin(ma + 0.7);
    const float MR = 0.075;
    float2 dm = (p - M.xy) / MR;
    float mrr = dot(dm, dm);
    float mz = M.z + MR * sqrt(max(1.0 - mrr, 0.0));

    // ---- planet shading
    float3 planet = float3(0.0);
    float planetA = 0.0;
    if (rr < 1.0 + 2.0 * aa) {
        float3 N = normalize(S);
        float lat = asin(clamp(dot(N, W.n), -1.0, 1.0));
        float lon = atan2(dot(N, W.b2), dot(N, W.b1));
        float nz = bandNoise(lat, lon, t, bg, C);
        float3 alb = bandColor(lat, nz) * (0.85 + 0.5 * (nz - 0.5) * (1.0 - smoothstep(0.9, 1.3, abs(lat))));
        float ndl = dot(N, W.L);
        float lit = smoothstep(-0.10, 0.35, ndl) * (0.25 + 0.75 * saturate(ndl));
        float mu = N.z;
        lit *= mix(0.55, 1.0, pow(saturate(mu), 0.45));        // limb darkening
        // ring shadow: march toward the star to the ring plane
        float sN = -dot(W.n, S) / dot(W.n, W.L);
        if (sN > 0.0) {
            float3 Q = S + sN * W.L;
            float rq = length(Q);
            if (rq > RING_IN && rq < RING_OUT) {
                float tau = ringTau(rq, ringFine(rq, bg));
                lit *= mix(1.0, exp(-tau * 1.6 / abs(dot(W.n, W.L))), 0.92);
            }
        }
        planet = alb * sunCol * lit * 0.46;
        // atmosphere: blue rim scattering on the day side, thin haze past the terminator
        float rim = pow(1.0 - saturate(mu), 3.0);
        planet += float3(0.30, 0.62, 0.95) * rim * smoothstep(-0.25, 0.4, ndl) * 0.9;
        // backlit limb: sunlight forward-scattered through the upper atmosphere
        float toward = saturate(dot(normalize(p), normalize(W.L.xy)) * 0.5 + 0.5);
        planet += float3(1.0, 0.78, 0.5) * pow(1.0 - saturate(mu), 4.0) * fwd * pow(toward, 3.0) * 2.6;
        planet += float3(0.9, 0.55, 0.3) * pow(1.0 - saturate(mu), 8.0) * smoothstep(-0.25, 0.05, ndl)
                  * smoothstep(0.3, 0.0, ndl) * 0.5;
        // faint ringshine on the night side (rings lit above the plane reflect onto it)
        planet += float3(0.95, 0.86, 0.72) * 0.03 * saturate(-ndl) * saturate(dot(N, W.n) * sign(dot(W.n, W.L)) + 0.3);
        planetA = saturate((1.0 - sqrt(rr)) / aa + 0.5);
        col = mix(col, planet, planetA);
    }

    // ---- rings
    if (r > RING_IN - 0.02 && r < RING_OUT + 0.02) {
        float fine = ringFine(r, bg);
        // orbiting clumps (azimuthal structure), Keplerian speed, in two cross-faded phases
        float az = atan2(dot(P, W.b2), dot(P, W.b1));
        float om = (2.0 * WPI / 720.0) * pow(r / 1.6, -1.5);
        float ph = fract(t / 240.0);
        float wA = 1.0 - abs(2.0 * ph - 1.0), wB = 1.0 - wA;
        float kA = bg.sample(rep, float2((az + om * ph * 240.0) / (2.0 * WPI) * 4.0, r * 2.3)).b;
        float kB = bg.sample(rep, float2((az + om * fract(ph + 0.5) * 240.0) / (2.0 * WPI) * 4.0 + 0.5, r * 2.3 + 0.37)).b;
        float clump = 0.5 + ((kA - 0.5) * wA + (kB - 0.5) * wB) * rsqrt(wA * wA + wB * wB);
        float tau = ringTau(r, fine) * (0.8 + 0.4 * clump);
        float mv = abs(W.n.z);                                    // cos of view angle to the plane normal
        float ml = dot(W.n, W.L);
        float alpha = 1.0 - exp(-tau / mv);
        float3 alb = ringAlbedo(r) * (0.75 + 0.5 * fine);
        float3 rc;
        if (ml * W.n.z > 0.0) {
            // we see the lit face
            rc = alb * sunCol * (0.35 + 0.65 * saturate(abs(ml) * 1.6)) * 0.55;
        } else {
            // unlit face: only light scattered through thin parts
            rc = alb * sunCol * 0.35 * (1.0 - exp(-tau)) * exp(-tau * 0.8);
        }
        // forward scattering: thin rings glow when the star is behind them
        rc += alb * float3(1.0, 0.85, 0.65) * sunCol * fwd * 0.9 * exp(-tau * 1.2) / max(alpha, 0.05) * (1.0 - exp(-tau / mv)) * 0.5;
        // planet's shadow on the rings
        float bL = dot(P, W.L);
        float dmin = sqrt(max(dot(P, P) - bL * bL, 0.0));
        float shadow = bL < 0.0 ? smoothstep(0.985, 1.02, dmin) : 1.0;
        rc *= mix(0.03, 1.0, shadow);
        // ice glints
        float2 gp = float2(dot(P, W.b1), dot(P, W.b2)) * W.R * 0.9;
        float2 gi = floor(gp);
        float gh = hash12(gi + floor(t * 0.5) * 0.0);
        float2 gf = fract(gp) - (0.2 + 0.6 * hash22(gi + 3.1));
        float tw2 = 0.5 + 0.5 * sin(t * (1.5 + 2.0 * hash12(gi + 7.7)) + gh * 30.0);
        float glint = step(0.985, gh) * exp(-dot(gf, gf) * 60.0) * tw2 * tw2;
        rc += sunCol * glint * 0.8 * shadow * step(0.0, ml * W.n.z) * saturate(tau * 2.0);
        // edges of the ring system antialiased
        float edge = smoothstep(RING_IN - 0.01, RING_IN + 0.01, r) * smoothstep(RING_OUT + 0.01, RING_OUT - 0.01, r);
        alpha *= edge;
        if (ringFront) {
            col = mix(col, rc, alpha);
        } else {
            // behind the planet: only visible outside the disc's antialiased edge
            col = mix(col, mix(rc, planet, planetA), alpha * (1.0 - planetA));
        }
    }

    // ---- moon
    if (mrr < 1.0 + 3.0 * aa / MR) {
        bool front = (!hitP || mz > S.z) && (!(r > RING_IN && r < RING_OUT) || mz > P.z || !ringFront);
        if (front) {
            float3 N = float3(dm, sqrt(max(1.0 - mrr, 0.0)));
            float ndl = dot(N, W.L);
            float2 muv = float2(atan2(N.x, N.z) / (2.0 * WPI), N.y * 0.5) * 3.0 + 0.2;
            float cr = bg.sample(rep, muv).g;
            float3 alb = float3(0.62, 0.60, 0.58) * (0.7 + 0.6 * cr);
            float lit = smoothstep(-0.05, 0.3, ndl) * saturate(ndl + 0.1);
            // eclipse: in the planet's shadow
            float bL = dot(M, W.L);
            float dmin = sqrt(max(dot(M, M) - bL * bL, 0.0));
            lit *= bL < 0.0 ? smoothstep(0.96, 1.04, dmin) : 1.0;
            float3 mc = alb * sunCol * lit * 0.6;
            float a = saturate((1.0 - sqrt(mrr)) * MR / aa + 0.5);
            col = mix(col, mc, a);
        }
    }

    return present(col * U.misc.x, in.pos.xy);
}
