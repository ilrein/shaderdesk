//! title: Aurora
//! order: 1
//
// "Aurora": northern lights over a dark mountain ridge.
//   bake  – night-sky gradient, airglow and stars.
//   frame – animated aurora curtains (one per active project, min 2), meteors for
//           token flares, and two mountain silhouettes. Activity speeds up and
//           brightens the curtains.

constant float METEOR_LIFE = 1.6;

fragment float4 scene_bake(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    float2 pt = globalPoint(in.pos, U);
    float seed = U.misc.w;
    float h = saturate((pt.y - U.display.y) / U.display.w);

    float3 col = mix(float3(0.010, 0.020, 0.032), float3(0.0018, 0.0022, 0.0050), pow(h, 0.55));
    col += float3(0.004, 0.014, 0.012) * exp(-h * 6.0);

    float minSigma = 0.55 / U.view.z;
    float3 sc = float3(0.0);
    float stars = 0.0;
    stars += starLayer(pt, 8.0, 0.22, 0.02, 0.16, 3.0, 0.42, minSigma, seed, 0.0, sc);
    stars += starLayer(pt, 22.0, 0.38, 0.05, 0.70, 5.0, 0.55, minSigma, seed + 3.0, 0.0, sc);
    stars += starLayer(pt, 80.0, 0.25, 0.25, 2.4, 5.0, 0.7, minSigma, seed + 9.0, 1.0, sc);
    float fade = smoothstep(0.08, 0.45, h);
    col += sc * fade;
    return float4(col, saturate(stars * fade));
}

constant int RIBBONS = 5;
constant int ROW_RIDGE = 5;

// Everything about the curtains and mountains depends only on x, so it's computed
// once per column here (row k = ribbon k, row 5 = ridgelines) and read per pixel.
fragment float4 scene_lut(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    int row = int(in.pos.y);
    float t = U.view.w;
    float act = U.motion.z;
    float gx = globalX(in.pos, U);

    if (row == ROW_RIDGE) {
        float far = U.display.w * (0.11 + 0.10 * fbm1(gx / 420.0 + 3.0, 5));
        float near = U.display.w * (0.04 + 0.09 * fbm1(gx / 230.0 + 11.0, 5));
        return float4(far, near, 0.0, 0.0);
    }
    if (row >= RIBBONS) return float4(0.0);

    float x = gx / 1000.0;
    float speed = 0.35 + 1.4 * act;
    float fk = float(row);
    float tk = t * 0.02 * speed;
    float base = 0.52 + 0.08 * fk + 0.05 * sin(x * 0.9 + fk * 2.1 + tk * 2.0);
    float wave = base + 0.16 * (fbm1(x * 1.6 + fk * 7.3 + tk, 4) - 0.5);
    float rays = 0.45 + 0.55 * pow(noise1(x * 60.0 + fk * 13.0 + t * 0.15 * speed), 2.0);
    float fold = 0.55 + 0.45 * sin(x * 7.0 + fk * 1.7 + tk * 9.0);
    float along = smoothstep(0.12, 0.62, fbm1(x * 0.7 + fk * 3.0 + tk * 0.5, 3));
    return float4(wave, rays * fold * along * (1.0 - fk * 0.12), 0.0, 0.0);
}

fragment float4 scene_frame(VOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            constant Galaxy* G [[buffer(1)]],
                            constant Flare* F [[buffer(2)]],
                            texture2d<float> bg [[texture(0)]],
                            texture2d<float> lut [[texture(1)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float t = U.view.w;
    float act = U.motion.z;
    float2 gp = globalPoint(in.pos, U);
    uint col_x = uint(in.pos.x);
    float strength = 0.35 + 1.1 * act + 0.4 * U.motion.w;

    // mountains: a hazy far ridge lit by the aurora, and a black near ridge
    float yl = gp.y - U.display.y;
    float2 ridge = lut.read(uint2(col_x, ROW_RIDGE)).xy;
    if (yl < ridge.y) return present(float3(0.0012, 0.0016, 0.0024) * U.misc.x, in.pos.xy);

    float h = yl / U.display.w;
    float3 aur = float3(0.0);
    int ribbons = clamp(int(U.misc.y) + 2, 2, RIBBONS);
    for (int k = 0; k < RIBBONS; k++) {
        if (k >= ribbons) break;
        float2 L = lut.read(uint2(col_x, uint(k))).xy;
        float dy = h - L.x;
        float lower = exp(-dy * dy * 1400.0);
        float upper = dy > 0.0 ? exp(-dy * (5.0 + float(k))) : 0.0;
        float I = max(lower, upper * 0.85) * L.y;
        aur += mix(float3(0.12, 1.0, 0.48), float3(0.55, 0.18, 0.85), saturate(dy * 4.0)) * I;
    }
    aur *= strength * 0.30;

    float3 col;
    if (yl < ridge.x) {
        float rim = exp(-(ridge.x - yl) * 0.25);
        col = float3(0.004, 0.006, 0.010) + aur * 0.05 + float3(0.02, 0.07, 0.04) * rim * strength * 0.25;
    } else {
        float2 pt = gp + U.motion.xy * 0.3;
        float2 uv = (pt - U.bake.xy) / U.bake.zw;
        uv.y = 1.0 - uv.y;
        float4 b = bg.sample(smp, uv);
        float tw = vnoise(pt * 0.09 + float2(t * 0.4, -t * 0.27));
        col = b.rgb * (1.0 - 0.25 * (1.0 - tw) * saturate(b.a * 3.0));
        col += aur;
        // faint sky glow from the curtains
        col += float3(0.002, 0.008, 0.005) * strength * smoothstep(0.9, 0.3, h);

        // meteors (token flares)
        float2 dir = normalize(float2(-1.0, -0.42));
        for (int i = 0; i < int(U.misc.z); i++) {
            Flare f = F[i];
            float age = t - f.posStart.z;
            if (age < 0.0 || age > METEOR_LIFE) continue;
            float life = age / METEOR_LIFE;
            float2 head = f.posStart.xy + dir * 420.0 * age;
            float tail = 4.5 * f.posStart.w;
            float2 d = gp - head;
            float along = dot(d, -dir);
            float across = dot(d, float2(-dir.y, dir.x));
            if (along < -3.0 || along > tail || abs(across) > 3.0) continue;
            float fade = exp(-max(along, 0.0) / tail * 3.0) * exp(-across * across * 1.6);
            float env = smoothstep(0.0, 0.1, life) * (1.0 - life);
            col += f.color.rgb * fade * env * 1.8;
        }
    }

    col *= U.misc.x;
    return present(col, in.pos.xy);
}
