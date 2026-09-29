//! title: Distant Universe
//! order: 0
//! labels: true
//
// "Universe": a distant deep field.
//   bake  – nebula, galactic band with dust lanes, three star layers, faint background
//           galaxies. Rendered once per display (and on resize) into a texture.
//   frame – samples the bake with a slow drift, twinkles stars, and adds the live
//           layer: project galaxies and token flares. Cheap enough for 20–30 fps.

constant float FLARE_LIFE = 4.0;

fragment float4 scene_bake(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 pt = globalPoint(in.pos, U);
    float seed = U.misc.w;
    float2 p = pt / 1000.0;
    float2 center = (U.desk.xy + U.desk.zw * 0.5) / 1000.0;

    // --- the galactic band: a gently curving river of light across the desktop
    float2 bdir = normalize(float2(1.0, 0.34));
    float2 rel = p - center - float2(0.0, 0.12);
    float along = dot(rel, bdir);
    float d = dot(rel, float2(-bdir.y, bdir.x))
            + 0.07 * sin(along * 1.6 + 0.8)                 // slow meander
            + 0.12 * (fbm(p * 0.9 + 1.3, 3) - 0.5);          // ragged edges
    float glow = exp(-d * d * 8.0);   // broad diffuse light
    float core = exp(-d * d * 34.0);  // brighter, warmer spine

    // unresolved star clouds: mottled at two scales
    float mott = smoothstep(0.30, 0.78, fbm(p * 2.6 + 3.0, 6)) * (0.55 + 0.45 * fbm(p * 9.0 + 8.0, 4));

    // dust: dark filaments threaded along the spine, plus a few larger dark clouds
    float fil = pow(ridged(p * 3.0 + float2(7.0, 2.0), 6), 1.6);
    float blobs = smoothstep(0.58, 0.80, fbm(p * 1.9 + 11.0, 5));
    float dust = saturate(fil * 1.15 + blobs * 0.7) * exp(-d * d * 12.0);
    float clear = 1.0 - 0.9 * dust;

    float3 col = float3(0.0009, 0.0011, 0.0022); // deep space, very slightly blue
    float3 edgeCol = float3(0.013, 0.016, 0.034);
    float3 coreCol0 = float3(0.066, 0.056, 0.043);
    float3 coreCol = coreCol0;
    float grain = 0.8 + 0.4 * gnoise(p * 55.0); // sparkle of unresolved stars
    float warm = smoothstep(0.3, 0.7, fbm(float2(along * 1.3, 0.0) + 40.0, 3)); // golden stretches vs cooler ones
    coreCol = mix(coreCol * float3(0.86, 0.93, 1.12), coreCol * float3(1.08, 1.0, 0.86), warm);
    col += mix(edgeCol, coreCol, core) * glow * (0.12 + 1.55 * mott) * grain * clear;

    // emission nebulae: sparse hydrogen-pink knots along the band
    float em = smoothstep(0.58, 0.82, fbm(p * 2.3 + 21.0, 6)) * exp(-d * d * 10.0);
    float emTex = 0.25 + 1.1 * pow(ridged(p * 7.0 + 4.0, 5), 1.4);
    col += float3(0.085, 0.012, 0.034) * em * emTex * clear;

    // faint blue reflection clouds away from the band (domain-warped)
    float2 q = p * 1.1 + 3.7;
    float2 w = float2(fbm(q * 1.4, 4), fbm(q * 1.4 + 5.2, 4));
    float refl = pow(smoothstep(0.52, 0.80, fbm(q + w * 1.6, 6)), 2.2) * (1.0 - 0.7 * glow);
    col += float3(0.004, 0.011, 0.026) * refl;

    // --- stars: dense faint dust (thick in the band), mid field, rare bright ones
    float minSigma = 0.55 / U.view.z;
    float3 sc = float3(0.0);
    float stars = 0.0;
    // micro stars: only inside the band, so it looks made of stars rather than fog
    stars += starLayer(pt, 3.2, glow * (0.15 + 0.85 * mott) * clear * 0.9, 0.012, 0.07, 2.0, 0.40, minSigma, seed + 1.7, 0.0, sc);
    stars += starLayer(pt, 6.0, (0.10 + 0.75 * glow * (0.4 + 0.6 * mott)) * clear, 0.025, 0.18, 3.0, 0.42, minSigma, seed, 0.0, sc);
    stars += starLayer(pt, 19.0, 0.40, 0.05, 0.85, 5.0, 0.55, minSigma, seed + 3.0, 0.0, sc);
    stars += starLayer(pt, 72.0, 0.30, 0.30, 3.4, 5.0, 0.75, minSigma, seed + 9.0, 1.0, sc);
    col += sc * (1.0 - dust * 0.75);

    // faint distant galaxies (Hubble deep field smudges)
    float cell = 150.0;
    float2 id = floor(pt / cell);
    float2 h = hash22(id + seed + 41.0);
    if (h.x < 0.28) {
        float2 c = (id + 0.25 + 0.5 * hash22(id * 2.1 + seed)) * cell;
        float rad = 2.5 + 9.0 * pow(hash12(id + 5.0), 3.0);
        float ang = h.y * 6.2831;
        float2 dd = pt - c;
        float2 r = float2(cos(ang) * dd.x + sin(ang) * dd.y, -sin(ang) * dd.x + cos(ang) * dd.y) / rad;
        r.y /= 0.25 + 0.7 * hash12(id + 9.0);
        float g = exp(-dot(r, r) * 2.2) + 0.6 * exp(-dot(r, r) * 18.0);
        float3 gc = mix(float3(1.0, 0.85, 0.65), float3(0.7, 0.8, 1.0), hash12(id + 13.0));
        col += gc * g * (0.02 + 0.07 * hash12(id + 21.0));
    }

    return float4(col, saturate(stars));
}

fragment float4 scene_frame(VOut in [[stage_in]],
                               constant Uniforms& U [[buffer(0)]],
                               constant Galaxy* G [[buffer(1)]],
                               constant Flare* F [[buffer(2)]],
                               texture2d<float> bg [[texture(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float t = U.view.w;
    float act = U.motion.z;
    float2 pt = globalPoint(in.pos, U) + U.motion.xy;

    float2 uv = (pt - U.bake.xy) / U.bake.zw;
    uv.y = 1.0 - uv.y;
    float4 b = bg.sample(smp, uv);

    // twinkle: a slowly moving noise field dims star pixels a little
    // (only where the bake says there's a star; most pixels skip the noise)
    float3 col = b.rgb;
    if (b.a > 0.004) {
        float tw = vnoise(pt * 0.09 + float2(t * 0.4, -t * 0.27));
        float twAmt = 0.18 + 0.22 * act;
        col *= 1.0 - twAmt * (1.0 - tw) * saturate(b.a * 3.0);
    }

    // project galaxies
    int gc = int(U.misc.y);
    for (int i = 0; i < gc; i++) {
        Galaxy g = G[i];
        float2 d = pt - g.posSize.xy;
        float R = g.posSize.z;
        if (dot(d, d) > R * R * 2.6) continue;
        float2 p = d / R;
        float rot = g.posSize.w + t * 0.003;
        float c = cos(rot), s = sin(rot);
        p = float2(c * p.x - s * p.y, s * p.x + c * p.y);
        p.y /= max(g.look.y, 0.15);
        float r = length(p);
        if (r > 1.6) continue;
        float seed = g.look.z;
        float th = atan2(p.y, p.x + 1e-5);
        float wind = 3.2 + seed * 2.5;
        float arm = 0.5 + 0.5 * cos(2.0 * (th - wind * log(r + 0.06)) + seed * 40.0);
        arm = pow(saturate(arm), 2.5);
        float clumps = 0.55 + 0.9 * vnoise(p * 9.0 + seed * 17.0);
        float disk = exp(-r * 3.4);
        float spiral = disk * (0.18 + 1.3 * arm * clumps) * smoothstep(1.3, 0.2, r);
        float ellip = exp(-r * r * 5.0);
        float body = mix(spiral, ellip * 0.9, g.look.w);
        float core = exp(-r * r * 60.0) * (1.4 + 0.5 * g.tint.w * sin(t * 1.3 + seed * 20.0));
        float3 coreCol = float3(1.0, 0.86, 0.66);
        float3 gcol = mix(g.tint.rgb, coreCol, saturate(g.look.w + (1.0 - r) * 0.35)) * body + coreCol * core;
        col += gcol * g.look.x;
    }

    // token flares
    int fc = int(U.misc.z);
    for (int i = 0; i < fc; i++) {
        Flare f = F[i];
        float age = t - f.posStart.z;
        if (age < 0.0 || age > FLARE_LIFE) continue;
        float2 d = pt - f.posStart.xy;
        float sz = f.posStart.w;
        float r = length(d) / sz;
        if (r > 3.0) continue;
        float life = age / FLARE_LIFE;
        float env = smoothstep(0.0, 0.06, life) * pow(1.0 - life, 2.2);
        float2 ad = abs(d) / sz;
        float core = exp(-r * r * 60.0);
        float halo = exp(-r * 4.5) * 0.18;
        float spikes = (exp(-ad.x * 70.0) * exp(-ad.y * 1.2) + exp(-ad.y * 70.0) * exp(-ad.x * 1.2)) * 0.5;
        col += f.color.rgb * env * 3.0 * (core + halo + spikes);
    }

    col *= U.misc.x * (0.92 + 0.22 * act + 0.08 * U.motion.w);

    // gentle vignette over the whole desktop, not per display
    float2 dv = (globalPoint(in.pos, U) - (U.desk.xy + U.desk.zw * 0.5)) / U.desk.zw;
    col *= 1.0 - 0.35 * smoothstep(0.3, 0.75, length(dv * float2(1.0, 0.8)));

    return present(col, in.pos.xy);
}
