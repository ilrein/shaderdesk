//! title: Icon
//! bloom: 0
//
// The app icon artwork. Not a wallpaper scene (it lives outside Scenes/), rendered by
// scripts/make-icon.sh via `Shaderdesk --snapshot --scene-file Art/Icon.metal`.
// One hero spiral galaxy over a faint galactic band, built to read at 16 px.

// p in icon units: (0,0) centre, x in -1..1
inline float3 spiralGalaxy(float2 p) {
    // tilt and incline the disk
    float rot = -0.52;
    float c = cos(rot), s = sin(rot);
    p = float2(c * p.x - s * p.y, s * p.x + c * p.y);
    p.y /= 0.56;
    p /= 0.72; // galaxy radius in icon units

    float r = length(p);
    float th = atan2(p.y, p.x + 1e-5);
    float lr = log(r + 0.04);

    // two logarithmic arms, plus a fainter pair between them
    float phase = 2.0 * (th - 3.1 * lr);
    float arm = pow(saturate(0.5 + 0.5 * cos(phase)), 3.0);
    float arm2 = pow(saturate(0.5 + 0.5 * cos(phase + 3.14159)), 6.0) * 0.35;
    // dust lanes hug the inner edge of each arm
    float lane = pow(saturate(0.5 + 0.5 * cos(phase - 0.75)), 8.0) * smoothstep(0.05, 0.35, r) * smoothstep(1.1, 0.4, r);

    float clump = 0.6 + 0.8 * fbm(p * 6.0 + 3.0, 4);
    float disk = exp(-r * 2.6) * smoothstep(1.35, 0.35, r);
    float armLight = disk * (0.10 + 2.2 * (arm + arm2) * clump);

    // star-forming knots along the arms
    float knots = smoothstep(0.66, 0.86, fbm(p * 10.0 + 7.0, 3)) * arm * smoothstep(0.2, 0.5, r) * smoothstep(1.2, 0.6, r);

    float bulge = exp(-r * r * 9.0);
    float core = exp(-r * r * 90.0);

    float3 armCol = mix(float3(0.36, 0.56, 1.00), float3(0.80, 0.84, 1.0), exp(-r * 3.0));
    float3 col = armCol * armLight * 0.55;
    col += float3(1.00, 0.50, 0.72) * knots * 0.9;
    col += float3(1.00, 0.76, 0.48) * bulge * 0.8;
    col += float3(1.00, 0.93, 0.82) * core * 2.4;
    col *= 1.0 - 0.7 * lane;
    return col;
}

fragment float4 scene_frame(VOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            constant Galaxy* G [[buffer(1)]],
                            constant Flare* F [[buffer(2)]],
                            texture2d<float> bg [[texture(0)]]) {
    float2 pt = globalPoint(in.pos, U);
    float2 ctr = U.display.xy + U.display.zw * 0.5;
    float2 p = (pt - ctr) / (U.display.z * 0.5); // -1..1

    // deep space: indigo near the middle falling to near black at the corners
    float rr = length(p);
    float3 col = mix(float3(0.013, 0.011, 0.036), float3(0.0015, 0.0018, 0.005), smoothstep(0.0, 1.35, rr));

    // faint galactic band behind, running the other diagonal, with dust
    float d = dot(p, normalize(float2(0.55, 1.0))) + 0.08 * (fbm(p * 1.6 + 2.0, 4) - 0.5);
    float band = exp(-d * d * 6.0);
    float mott = 0.4 + 0.9 * fbm(p * 3.5 + 5.0, 5);
    float dust = pow(ridged(p * 2.4 + 9.0, 5), 1.5) * exp(-d * d * 14.0);
    col += float3(0.024, 0.022, 0.034) * band * mott * (1.0 - 0.8 * dust);
    col += float3(0.035, 0.006, 0.020) * smoothstep(0.6, 0.85, fbm(p * 2.2 + 13.0, 5)) * band;

    // stars, a few with spikes; sparse so the galaxy stays the subject
    float2 sp = p * 420.0;
    float3 sc = float3(0.0);
    starLayer(sp, 7.0, 0.30 + 0.4 * band, 0.03, 0.22, 3.0, 0.55, 0.5, 2.0, 0.0, sc);
    starLayer(sp, 26.0, 0.30, 0.06, 0.7, 4.0, 0.8, 0.5, 5.0, 0.0, sc);
    starLayer(sp, 150.0, 0.22, 0.9, 2.6, 2.0, 1.3, 0.5, 11.0, 1.0, sc);
    col += sc * (1.0 - 0.6 * dust);

    col += spiralGalaxy(p - float2(0.02, 0.0));
    return present(col, in.pos.xy);
}
