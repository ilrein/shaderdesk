//! title: Black Hole
//! order: 4
//! bloom: 0.16
//! tags: Exotic
//
// "Black Hole": a Schwarzschild black hole with a glowing accretion disk, ray-traced
// per pixel. Nothing about the lensing is faked:
//   • each pixel's photon is traced backwards in its orbital plane by integrating the
//     orbit equation u'' = 3u^2 - u (u = M/r, M = 1) with RK4, and every crossing of the
//     disk plane is shaded and composited front to back. That produces the lensed far
//     side of the disk arching over the shadow, the image wrapped under it, and the thin
//     photon ring, for free
//   • rays that miss the disk entirely (b > B_STRONG, beyond its outer edge) only need
//     their deflection for the sky, from the weak-field expansion
//     alpha = 4/b + 15pi/(4 b^2)
//   • the disk: Keplerian differential rotation, relativistic Doppler beaming and
//     gravitational redshift (approaching side hotter and brighter), temperature falling
//     with radius, turbulent streaks. Flow runs in two cross-faded phases so the shear
//     never winds the streaks into moire
//   • escaping rays sample the background after their deflection, so the stars and
//     nebula form an Einstein ring and stretch into arcs near the shadow
//   bake – rgb: seamlessly tiling fBm (disk and nebula texture), a: faint starfield.
// Motion uses the scene clock (U.target.z); every period divides a day evenly.

constant float BPI = 3.14159265;
constant float R_IN = 6.0;          // ISCO
constant float R_OUT = 15.0;
constant float B_STRONG = R_OUT + 3.0; // impact parameter (M) below which rays are integrated
constant float FLOW_T = 24.0;       // seconds per flow phase
constant float K_T = 3.0;           // simulation time units (M) per second
constant float LENS_K = 22.0;       // lens-to-source distance for the sky (M)

fragment float4 scene_bake(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 C = noiseTile(U);
    float2 np = in.pos.xy / U.view.xy * C;
    float3 n = float3(pfbm(np, C, 5), pfbm(np + 17.3, C, 5), pfbm(np + 41.9, C, 5));

    float2 pt = globalPoint(in.pos, U);
    float seed = U.misc.w;
    float minSigma = 0.55 / U.view.z;
    float3 sc = float3(0.0);
    float stars = 0.0;
    stars += starLayer(pt, 6.0, 0.14, 0.02, 0.14, 3.0, 0.42, minSigma, seed + 1.0, 0.0, sc);
    stars += starLayer(pt, 20.0, 0.30, 0.05, 0.60, 5.0, 0.55, minSigma, seed + 6.0, 0.0, sc);
    stars += starLayer(pt, 80.0, 0.25, 0.30, 2.2, 5.0, 0.75, minSigma, seed + 11.0, 1.0, sc);
    return float4(n, stars);
}

// ---- disk ----------------------------------------------------------------------

// disk emission ramp: deep red -> amber -> gold -> white -> blue-white
inline float3 diskRamp(float h) {
    h = max(h, 0.0);
    return float3(2.6 * h, 1.05 * pow(h, 1.9), 0.55 * pow(h, 3.2));
}

// streak pattern at (r, psi) for one flow phase lasting tau seconds
inline float diskPhase(float r, float psi, float tau, float cycle, texture2d<float> nt, float2 C) {
    constexpr sampler rep(filter::linear, address::repeat);
    float omega = pow(r, -1.5) * K_T;                       // Kepler, rad per second
    float2 off = hash22(float2(cycle, 1.3));
    float rho = log(r);
    float a = (psi + omega * tau) / (2.0 * BPI);
    float warp = nt.sample(rep, float2(a * 2.0, rho * 6.0 / C.y) + off).g - 0.5;
    float n1 = nt.sample(rep, float2(a * 1.0, (rho + warp * 0.10) * 26.0 / C.y) + off).r;
    float n2 = nt.sample(rep, float2(a * 3.0, (rho + warp * 0.06) * 70.0 / C.y) + off * 1.7).b;
    return (n1 - 0.5) * 0.75 + (n2 - 0.5) * 0.45;
}

// emission (rgb) and opacity (a) where the ray crosses the disk at radius r
inline float4 diskAt(float r, float psi, float3 k, float kyAbs, float t, texture2d<float> nt, float2 C) {
    if (r < 4.6 || r > R_OUT) return float4(0.0);
    // two flow phases half a cycle apart, blended preserving variance
    float ph = fract(t / FLOW_T), phB = fract(ph + 0.5);
    float wA = 1.0 - abs(2.0 * ph - 1.0), wB = 1.0 - wA;
    float nA = diskPhase(r, psi, ph * FLOW_T, floor(t / FLOW_T), nt, C);
    float nB = diskPhase(r, psi, phB * FLOW_T, floor(t / FLOW_T + 0.5) + 500.0, nt, C);
    float n = (nA * wA + nB * wB) * rsqrt(wA * wA + wB * wB);

    // radial structure: bright inner edge, soft rings and gaps, fading outer edge
    float edge = smoothstep(4.6, 6.4, r) * smoothstep(R_OUT, R_OUT - 6.5, r);
    float rings = 0.88 + 0.12 * sin(log(r) * 38.0 + n * 3.0);
    float dens = saturate((0.55 + 1.3 * n) * rings) * edge;

    // relativistic factors: orbital speed seen by a static observer, Doppler, redshift
    float beta = min(rsqrt(max(r - 2.0, 0.1)), 0.7);
    float gam = rsqrt(1.0 - beta * beta);
    float3 vhat = float3(sin(psi), 0.0, -cos(psi));        // approaching on the left
    float D = 1.0 / (gam * (1.0 - beta * dot(vhat, k)));
    float g = D * sqrt(max(1.0 - 3.0 / r, 0.08));

    float T = pow(r / R_IN, -0.72) * (0.85 + 0.35 * smoothstep(7.5, 5.8, r));
    float3 e = diskRamp(T * g * 1.05) * pow(g, 2.4) * (0.45 + 1.1 * dens);
    // thin plane seen at a grazing angle is more opaque
    float alpha = 1.0 - pow(1.0 - saturate(dens * 0.85), 1.0 / max(kyAbs, 0.12));
    return float4(e * dens * 1.9, alpha);
}

struct RayCtx {
    float3 o, e;       // orbital-plane basis: toward the camera, and toward the pixel
    float t;
};

// shade a disk crossing at orbital angle phi with u = 1/r and du = du/dphi
inline void crossDisk(thread float3& acc, thread float& T, float phi, float u, float du,
                      RayCtx R, texture2d<float> nt, float2 C) {
    float r = 1.0 / max(u, 1e-5);
    if (r < 4.6 || r > R_OUT) return;
    float cp = cos(phi), sp = sin(phi);
    float3 radial = cp * R.o + sp * R.e;
    float3 P = r * radial;
    float dr = -du / (u * u);
    float3 k = -normalize(dr * radial + r * (-sp * R.o + cp * R.e));  // photon travel direction
    float psi = atan2(P.z, P.x);
    float4 d = diskAt(r, psi, k, abs(k.y), R.t, nt, C);
    acc += T * d.rgb * d.a;
    T *= 1.0 - d.a;
}

inline float2 orbitRHS(float2 y) { return float2(y.y, 3.0 * y.x * y.x - y.x); }

// ---- frame -----------------------------------------------------------------------

fragment float4 scene_frame(VOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            constant Galaxy* G [[buffer(1)]],
                            constant Flare* F [[buffer(2)]],
                            texture2d<float> bg [[texture(0)]]) {
    constexpr sampler rep(filter::linear, address::repeat);
    float t = U.target.z;
    float2 C = noiseTile(U);
    float2 pt = globalPoint(in.pos, U);

    float Mpt = U.display.w * 0.034;                               // one mass, in points
    float2 cen = U.display.xy + float2(U.display.z * 0.52, U.display.w * 0.53);
    float2 s = (pt - cen) / Mpt;
    const float roll = 0.10;
    s = float2(cos(roll) * s.x - sin(roll) * s.y, sin(roll) * s.x + cos(roll) * s.y);
    float b = max(length(s), 1e-4);

    // camera: a few degrees above the disk plane, slowly bobbing
    float th = (8.0 + 2.5 * sin(t * (2.0 * BPI / 600.0))) * (BPI / 180.0);
    RayCtx R;
    R.o = float3(0.0, sin(th), cos(th));
    float3 e2 = float3(0.0, cos(th), -sin(th));
    R.e = (s.x * float3(1.0, 0.0, 0.0) + s.y * e2) / b;
    R.t = t;

    // disk-plane crossings at phi_k = k*pi - delta
    // disk-plane crossings at phi = k*pi - delta (k = 1, 2, 3)
    float delta = atan2(R.o.y, R.e.y);

    float3 acc = float3(0.0);
    float T = 1.0;
    bool captured = false;
    float phiEsc = BPI;

    if (b < B_STRONG) {
        // start at r = R_START on the weak-field solution (the disk ends well inside it)
        const float R_START = 32.0;
        float ib = 1.0 / b;
        float phi = asin(min(b / R_START, 1.0));
        float cp = cos(phi), sp = sin(phi);
        float2 y = float2(sp * ib + (1.0 - cp) * (1.0 - cp) * ib * ib,
                          cp * ib + 2.0 * (1.0 - cp) * sp * ib * ib);
        float nextK = BPI - delta;
        if (nextK <= phi) nextK += BPI;
        // record up to three crossings (phi, u, du); shade them after the loop, which
        // keeps the loop small
        float3 c0 = float3(0.0), c1 = float3(0.0), c2 = float3(0.0);
        int n = 0;
        const float U_IN = 1.0 / R_OUT, U_MAX = 1.0 / 4.6;
        for (int i = 0; i < 300; i++) {
            float h = mix(0.24, 0.025, saturate(y.x * 3.2));
            float2 k1 = orbitRHS(y);
            float2 k2 = orbitRHS(y + 0.5 * h * k1);
            float2 k3 = orbitRHS(y + 0.5 * h * k2);
            float2 k4 = orbitRHS(y + h * k3);
            float2 yn = y + (h / 6.0) * (k1 + 2.0 * k2 + 2.0 * k3 + k4);
            float phin = phi + h;
            if (nextK <= phin) {  // h < pi, so at most one crossing per step
                float2 yc = mix(y, yn, (nextK - phi) / h);
                if (yc.x > U_IN && yc.x < U_MAX) {
                    float3 c = float3(nextK, yc);
                    if (n == 0) c0 = c; else if (n == 1) c1 = c; else c2 = c;
                    n++;
                }
                nextK += BPI;
            }
            if (yn.x > 0.5) { captured = true; break; }            // inside the horizon
            // periapsis: the orbit is symmetric about it, so the ray escapes at twice this angle
            if (y.y > 0.0 && yn.y <= 0.0) phiEsc = 2.0 * (phi + h * y.y / (y.y - yn.y));
            // outbound beyond the disk: no more crossings possible
            if (yn.y < 0.0 && yn.x < U_IN) break;
            if (n == 3) break;
            y = yn; phi = phin;
            if (i == 299) captured = true;
        }
        if (n == 3) captured = true;   // wound around more than once: sky contribution is negligible
        if (n > 0) crossDisk(acc, T, c0.x, c0.y, c0.z, R, bg, C);
        if (n > 1) crossDisk(acc, T, c1.x, c1.y, c1.z, R, bg, C);
        if (n > 2) crossDisk(acc, T, c2.x, c2.y, c2.z, R, bg, C);
    } else {
        float ib = 1.0 / b;
        phiEsc = BPI + 4.0 * ib + 3.75 * BPI * ib * ib;
    }

    // background: sampled where the escaping ray actually points
    float3 sky = float3(0.0);
    if (!captured && T > 0.01) {
        float alpha = clamp(phiEsc - BPI, -2.0 * BPI, 2.0 * BPI);
        float2 src = (s / b) * (b - LENS_K * alpha);
        float2 spt = cen + src * Mpt;
        float2 uv = (spt - U.bake.xy) / U.bake.zw;
        uv.y = 1.0 - uv.y;
        float4 bk = bg.sample(rep, uv);
        float4 bn = bg.sample(rep, uv * 0.31 + 0.37);
        float neb = smoothstep(0.45, 0.85, bn.r) * (0.6 + 0.4 * bn.g);
        float neb2 = smoothstep(0.50, 0.90, bn.b);
        sky = float3(0.0010, 0.0010, 0.0020);
        sky += float3(0.006, 0.010, 0.026) * neb + float3(0.020, 0.006, 0.014) * neb2 * neb;
        float tw = vnoise(spt * 0.09 + float2(U.view.w * 0.4, -U.view.w * 0.27));
        sky += float3(0.95, 0.95, 1.0) * bk.a * (0.8 + 0.2 * tw);
    }
    float3 col = acc + T * sky;

    // faint anamorphic streak through the bright inner disk (the glow itself is real bloom)
    col += float3(1.0, 0.50, 0.22) * 0.012 * exp(-abs(s.y) * 2.5) * exp(-abs(s.x) * 0.03);

    return present(col * U.misc.x, in.pos.xy);
}
