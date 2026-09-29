import CoreGraphics
import Metal

/// Renders one display. The expensive, static part of a scene is baked once into
/// a texture (with a margin so the sky can drift); each frame just samples it and
/// adds the live elements.
final class Renderer {
    static let margin: CGFloat = 56
    /// SHADERDESK_BLOOM=x overrides every scene's bloom strength (for tuning)
    static let bloomOverride = ProcessInfo.processInfo.environment["SHADERDESK_BLOOM"].flatMap(Float.init)

    let display: CGRect // global points
    let seed: Float
    var scene: Scene { didSet { if scene != oldValue { needsBake = true } } }
    var needsBake = true

    private let gpu = GPU.shared
    private var bakeTex: MTLTexture?
    private var bakeRect = CGRect.zero
    private var bakeScale: Float = 0
    private let post = PostChain()

    init(display: CGRect, scene: Scene, seed: Float) {
        self.display = display
        self.scene = scene
        self.seed = seed
    }

    func encode(_ cb: MTLCommandBuffer, target: MTLTexture, world: World) {
        let pxPerPt = Float(target.width) / Float(display.width)
        switch gpu.pipelines(for: scene) {
        case .success(let p):
            if let bake = p.bake {
                if needsBake || bakeTex == nil || bakeScale != pxPerPt {
                    self.bake(cb, pipeline: bake, pxPerPt: pxPerPt, world: world)
                }
            } else {
                bakeTex = nil
            }
            if let lut = p.lut {
                self.lut(cb, pipeline: lut, target: target, pxPerPt: pxPerPt, world: world)
            } else {
                lutTex = nil
            }
            guard let hdr = post.hdrTexture(width: target.width, height: target.height) else { return }
            frame(cb, pipeline: p.frame, target: hdr, pxPerPt: pxPerPt, world: world)
            post.resolve(cb, target: target, strength: Renderer.bloomOverride ?? scene.bloom)
        case .failure:
            clear(cb, target: target) // the menu shows the compile error
        }
    }

    private func baseUniforms(world: World) -> Uniforms {
        var u = Uniforms()
        u.bake = SIMD4(Float(bakeRect.minX), Float(bakeRect.minY), Float(bakeRect.width), Float(bakeRect.height))
        u.desk = SIMD4(Float(world.desk.minX), Float(world.desk.minY), Float(world.desk.width), Float(world.desk.height))
        u.display = SIMD4(Float(display.minX), Float(display.minY), Float(display.width), Float(display.height))
        u.motion = SIMD4(world.drift.x, world.drift.y, world.act, world.pulse)
        return u
    }

    private func bake(_ cb: MTLCommandBuffer, pipeline: MTLRenderPipelineState, pxPerPt: Float, world: World) {
        bakeRect = display.insetBy(dx: -Self.margin, dy: -Self.margin)
        let maxDim = 16384
        let w = min(maxDim, Int((bakeRect.width * CGFloat(pxPerPt)).rounded(.up)))
        let h = min(maxDim, Int((bakeRect.height * CGFloat(pxPerPt)).rounded(.up)))
        if bakeTex?.width != w || bakeTex?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GPU.bakeFormat, width: w, height: h, mipmapped: true)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            bakeTex = gpu.device.makeTexture(descriptor: d)
        }
        guard let tex = bakeTex else { return }

        var u = baseUniforms(world: world)
        u.target = SIMD4(Float(bakeRect.minX), Float(bakeRect.minY), 0, 0)
        u.view = SIMD4(Float(w), Float(h), Float(w) / Float(bakeRect.width), 0)
        u.misc = SIMD4(1, 0, 0, seed)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "bake \(scene.id)"
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        // mips, so scenes can sample the bake minified (e.g. noise wrapped round a
        // sphere) without aliasing: use a sampler with mip_filter::linear
        if tex.mipmapLevelCount > 1, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
        }
        needsBake = false
        bakeScale = pxPerPt
    }

    private var lutTex: MTLTexture?

    private func frameUniforms(target: MTLTexture, pxPerPt: Float, world: World) -> Uniforms {
        var u = baseUniforms(world: world)
        u.target = SIMD4(Float(display.minX), Float(display.minY), Float(world.clock.truncatingRemainder(dividingBy: 86_400)), 0)
        u.view = SIMD4(Float(target.width), Float(target.height), pxPerPt, Float(world.time))
        u.misc = SIMD4(world.brightness, Float(world.galaxies.count), Float(GPU.maxFlares), seed)
        return u
    }

    /// Frame and lookup passes see the same uniforms, galaxies, flares and bake.
    private func bindCommon(_ enc: MTLRenderCommandEncoder, _ u: inout Uniforms, world: World) {
        var galaxies = Array((world.galaxies + Array(repeating: GalaxyGPU(), count: GPU.maxGalaxies)).prefix(GPU.maxGalaxies))
        var flares = world.flares
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&galaxies, length: MemoryLayout<GalaxyGPU>.stride * galaxies.count, index: 1)
        enc.setFragmentBytes(&flares, length: MemoryLayout<FlareGPU>.stride * flares.count, index: 2)
        enc.setFragmentTexture(bakeTex ?? gpu.emptyTexture, index: 0)
    }

    /// Per-column lookup texture (target width x GPU.lutRows): values that only
    /// depend on x are computed once per column instead of once per pixel.
    private func lut(_ cb: MTLCommandBuffer, pipeline: MTLRenderPipelineState, target: MTLTexture, pxPerPt: Float, world: World) {
        if lutTex?.width != target.width {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GPU.bakeFormat, width: target.width,
                                                             height: GPU.lutRows, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            lutTex = gpu.device.makeTexture(descriptor: d)
        }
        guard let tex = lutTex else { return }
        var u = frameUniforms(target: target, pxPerPt: pxPerPt, world: world)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "lut \(scene.id)"
        enc.setRenderPipelineState(pipeline)
        bindCommon(enc, &u, world: world)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func frame(_ cb: MTLCommandBuffer, pipeline: MTLRenderPipelineState, target: MTLTexture, pxPerPt: Float, world: World) {
        var u = frameUniforms(target: target, pxPerPt: pxPerPt, world: world)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "frame \(scene.id)"
        enc.setRenderPipelineState(pipeline)
        bindCommon(enc, &u, world: world)
        enc.setFragmentTexture(lutTex ?? gpu.emptyTexture, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func clear(_ cb: MTLCommandBuffer, target: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
