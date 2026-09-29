import Metal

/// Bloom and final output, shared by every scene.
///
/// Scenes render linear HDR into `hdr` (rg11b10Float). The post chain then
///   1. downsamples it into a mip-like pyramid (13-tap filter; the first step uses a
///      Karis average so single bright pixels, i.e. stars, don't flicker),
///   2. upsamples back with a 3x3 tent, summing every level (wide, soft, energy-
///      preserving glow, like light scattering in a real lens),
///   3. composites `hdr + bloom * strength`, tone-maps, sRGB-encodes and dithers into
///      the display target. `strength` is per scene (`//! bloom:` metadata).
enum Post {
    static let hdrFormat: MTLPixelFormat = .rg11b10Float
    static let levels = 6

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; };

    vertex VOut post_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    inline float3 karis(float3 c) { return c / (1.0 + luma(c)); }

    // 13-tap downsample (Jimenez 2014). `first` applies a per-group Karis average.
    fragment float4 post_down(VOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                              constant float4& P [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.pos.xy * P.xy;            // P.xy = 1 / dst size
        float2 t = P.zw;                          // P.zw = 1 / src size
        float3 a = src.sample(s, uv + t * float2(-2, -2)).rgb;
        float3 b = src.sample(s, uv + t * float2( 0, -2)).rgb;
        float3 c = src.sample(s, uv + t * float2( 2, -2)).rgb;
        float3 d = src.sample(s, uv + t * float2(-2,  0)).rgb;
        float3 e = src.sample(s, uv).rgb;
        float3 f = src.sample(s, uv + t * float2( 2,  0)).rgb;
        float3 g = src.sample(s, uv + t * float2(-2,  2)).rgb;
        float3 h = src.sample(s, uv + t * float2( 0,  2)).rgb;
        float3 i = src.sample(s, uv + t * float2( 2,  2)).rgb;
        float3 j = src.sample(s, uv + t * float2(-1, -1)).rgb;
        float3 k = src.sample(s, uv + t * float2( 1, -1)).rgb;
        float3 l = src.sample(s, uv + t * float2(-1,  1)).rgb;
        float3 m = src.sample(s, uv + t * float2( 1,  1)).rgb;
        float3 g0 = (j + k + l + m) * 0.25;
        float3 g1 = (a + b + d + e) * 0.25, g2 = (b + c + e + f) * 0.25;
        float3 g3 = (d + e + g + h) * 0.25, g4 = (e + f + h + i) * 0.25;
        float3 o = g0 * 0.5 + (g1 + g2 + g3 + g4) * 0.125;
        return float4(max(o, 0.0), 1.0);
    }

    fragment float4 post_down_first(VOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                                    constant float4& P [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.pos.xy * P.xy;
        float2 t = P.zw;
        float3 a = src.sample(s, uv + t * float2(-2, -2)).rgb;
        float3 b = src.sample(s, uv + t * float2( 0, -2)).rgb;
        float3 c = src.sample(s, uv + t * float2( 2, -2)).rgb;
        float3 d = src.sample(s, uv + t * float2(-2,  0)).rgb;
        float3 e = src.sample(s, uv).rgb;
        float3 f = src.sample(s, uv + t * float2( 2,  0)).rgb;
        float3 g = src.sample(s, uv + t * float2(-2,  2)).rgb;
        float3 h = src.sample(s, uv + t * float2( 0,  2)).rgb;
        float3 i = src.sample(s, uv + t * float2( 2,  2)).rgb;
        float3 j = src.sample(s, uv + t * float2(-1, -1)).rgb;
        float3 k = src.sample(s, uv + t * float2( 1, -1)).rgb;
        float3 l = src.sample(s, uv + t * float2(-1,  1)).rgb;
        float3 m = src.sample(s, uv + t * float2( 1,  1)).rgb;
        float3 g0 = karis((j + k + l + m) * 0.25);
        float3 g1 = karis((a + b + d + e) * 0.25), g2 = karis((b + c + e + f) * 0.25);
        float3 g3 = karis((d + e + g + h) * 0.25), g4 = karis((e + f + h + i) * 0.25);
        float3 o = g0 * 0.5 + (g1 + g2 + g3 + g4) * 0.125;
        o = o / max(1.0 - luma(o), 1e-3);   // undo the Karis weighting
        return float4(max(o, 0.0), 1.0);
    }

    // up[i] = down[i] + tent(up[i+1])
    fragment float4 post_up(VOut in [[stage_in]], texture2d<float> low [[texture(0)]],
                            texture2d<float> cur [[texture(1)]], constant float4& P [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.pos.xy * P.xy;
        float2 t = P.zw;                          // 1 / low size
        float3 u = low.sample(s, uv + t * float2(-1, -1)).rgb
                 + low.sample(s, uv + t * float2( 1, -1)).rgb
                 + low.sample(s, uv + t * float2(-1,  1)).rgb
                 + low.sample(s, uv + t * float2( 1,  1)).rgb
                 + 2.0 * (low.sample(s, uv + t * float2( 0, -1)).rgb
                        + low.sample(s, uv + t * float2( 0,  1)).rgb
                        + low.sample(s, uv + t * float2(-1,  0)).rgb
                        + low.sample(s, uv + t * float2( 1,  0)).rgb)
                 + 4.0 * low.sample(s, uv).rgb;
        return float4(cur.sample(s, uv).rgb + u / 16.0, 1.0);
    }

    inline float3 tonemap(float3 x) { return 1.0 - exp(-x * 1.15); }
    inline float3 srgbEncode(float3 c) {
        c = max(c, 0.0);
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    }
    inline float3 srgbDecode(float3 c) {
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }

    // P.xy = 1 / target size, P.z = bloom strength, P.w = number of summed levels
    fragment float4 post_composite(VOut in [[stage_in]], texture2d<float> hdr [[texture(0)]],
                                   texture2d<float> bloom [[texture(1)]], constant float4& P [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.pos.xy * P.xy;
        float3 c = hdr.read(uint2(in.pos.xy)).rgb;
        float3 b = bloom.sample(s, uv).rgb / P.w;
        c += b * P.z;
        float3 o = srgbEncode(tonemap(c));
        float n = fract(52.9829189 * fract(dot(floor(in.pos.xy), float2(0.06711056, 0.00583715)))) - 0.5;
        o = saturate(o + n / 255.0);
        return float4(srgbDecode(o), 1.0);
    }
    """

    struct Pipelines {
        let downFirst, down, up, composite: MTLRenderPipelineState
    }

    static let pipelines: Pipelines = {
        let dev = GPU.shared.device
        let lib = try! dev.makeLibrary(source: source, options: nil)
        func make(_ name: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = name
            d.vertexFunction = lib.makeFunction(name: "post_vertex")
            d.fragmentFunction = lib.makeFunction(name: name)
            d.colorAttachments[0].pixelFormat = fmt
            return try! dev.makeRenderPipelineState(descriptor: d)
        }
        return Pipelines(downFirst: make("post_down_first", hdrFormat), down: make("post_down", hdrFormat),
                         up: make("post_up", hdrFormat), composite: make("post_composite", GPU.frameFormat))
    }()
}

/// Per-display post-processing textures.
final class PostChain {
    private var hdr: MTLTexture?
    private var down: [MTLTexture] = []
    private var up: [MTLTexture] = []

    /// The HDR texture a scene should render into for a target of this size.
    func hdrTexture(width: Int, height: Int) -> MTLTexture? {
        if hdr?.width != width || hdr?.height != height {
            let dev = GPU.shared.device
            func tex(_ w: Int, _ h: Int) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Post.hdrFormat, width: max(1, w),
                                                                 height: max(1, h), mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                return dev.makeTexture(descriptor: d)
            }
            hdr = tex(width, height)
            down = []; up = []
            var w = width, h = height
            for _ in 0..<Post.levels {
                w = max(1, (w + 1) / 2); h = max(1, (h + 1) / 2)
                if let d = tex(w, h), let u = tex(w, h) { down.append(d); up.append(u) }
            }
        }
        return hdr
    }

    private func pass(_ cb: MTLCommandBuffer, _ dst: MTLTexture, _ p: MTLRenderPipelineState,
                      _ textures: [MTLTexture], _ params: SIMD4<Float>) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = dst
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = p.label
        enc.setRenderPipelineState(p)
        for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
        var P = params
        enc.setFragmentBytes(&P, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func inv(_ t: MTLTexture) -> SIMD2<Float> { SIMD2(1 / Float(t.width), 1 / Float(t.height)) }

    /// Bloom + tonemap `hdr` into `target`.
    func resolve(_ cb: MTLCommandBuffer, target: MTLTexture, strength: Float) {
        guard let hdr, down.count == Post.levels else { return }
        let P = Post.pipelines
        var src = hdr
        for (i, d) in down.enumerated() {
            let a = inv(d), b = inv(src)
            pass(cb, d, i == 0 ? P.downFirst : P.down, [src], SIMD4(a.x, a.y, b.x, b.y))
            src = d
        }
        // the coarsest up level is just the coarsest down level
        var low = down[Post.levels - 1]
        for i in stride(from: Post.levels - 2, through: 0, by: -1) {
            let a = inv(up[i]), b = inv(low)
            pass(cb, up[i], P.up, [low, down[i]], SIMD4(a.x, a.y, b.x, b.y))
            low = up[i]
        }
        let t = inv(target)
        pass(cb, target, P.composite, [hdr, up[0]], SIMD4(t.x, t.y, strength, Float(Post.levels)))
    }
}
