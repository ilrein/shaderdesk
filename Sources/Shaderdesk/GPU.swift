import Foundation
import Metal

// Swift mirrors of the structs in Shaders/Common.metal (all float4, so layouts match).
struct Uniforms {
    var target = SIMD4<Float>()
    var view = SIMD4<Float>()
    var bake = SIMD4<Float>()
    var motion = SIMD4<Float>()
    var misc = SIMD4<Float>()
    var desk = SIMD4<Float>()
    var display = SIMD4<Float>()
}

struct GalaxyGPU {
    var posSize = SIMD4<Float>()
    var look = SIMD4<Float>()
    var tint = SIMD4<Float>()
}

struct FlareGPU {
    var posStart = SIMD4<Float>(0, 0, -1000, 1)
    var color = SIMD4<Float>()
}

enum GPUError: Error, CustomStringConvertible {
    case noPrelude
    case noFunction(String)
    var description: String {
        switch self {
        case .noPrelude: return "\(SceneCatalog.preludeName) not found"
        case .noFunction(let n): return "shader function \(n) missing"
        }
    }
}

/// Compiled pipelines for one scene. `bake` is nil when the scene has no static layer,
/// `lut` when it has no per-frame lookup pass.
struct ScenePipelines {
    let frame: MTLRenderPipelineState
    let bake: MTLRenderPipelineState?
    let lut: MTLRenderPipelineState?
}

/// Device, queue and per-scene pipelines, shared by every display.
final class GPU {
    static let shared = GPU()
    static let frameFormat: MTLPixelFormat = .bgra8Unorm_srgb
    static let bakeFormat: MTLPixelFormat = .rgba16Float
    static let maxGalaxies = 8
    static let maxFlares = 16
    /// rows in the optional per-frame lookup texture (width = render target width)
    static let lutRows = 8

    let device: MTLDevice
    let queue: MTLCommandQueue
    /// bound in place of the bake texture for scenes without a bake pass
    let emptyTexture: MTLTexture
    private var cache: [String: Result<ScenePipelines, Error>] = [:]

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this Mac")
        }
        self.device = device
        self.queue = queue
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GPU.bakeFormat, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        emptyTexture = device.makeTexture(descriptor: d)!
    }

    /// Compiles (once) and returns the pipelines for `scene`. Failures are cached too,
    /// so a broken user scene doesn't recompile every frame.
    func pipelines(for scene: Scene) -> Result<ScenePipelines, Error> {
        let key = scene.url.path
        if let r = cache[key] { return r }
        let r = Result { try compile(scene) }
        if case .failure(let e) = r { NSLog("Shaderdesk: scene \(scene.id) failed to compile: \(e)") }
        cache[key] = r
        return r
    }

    func error(for scene: Scene) -> Error? {
        if case .failure(let e) = cache[scene.url.path] { return e }
        return nil
    }

    /// Drop compiled scenes so edited files are picked up.
    func invalidate() { cache.removeAll() }

    private func compile(_ scene: Scene) throws -> ScenePipelines {
        guard let prelude = SceneCatalog.preludeURL else { throw GPUError.noPrelude }
        let src = try String(contentsOf: prelude, encoding: .utf8) + "\n\n#line 1 \"\(scene.url.lastPathComponent)\"\n"
            + String(contentsOf: scene.url, encoding: .utf8)
        let lib = try device.makeLibrary(source: src, options: nil) // fast math is the default
        guard let vf = lib.makeFunction(name: "fullscreen_vertex") else { throw GPUError.noFunction("fullscreen_vertex") }
        guard let ff = lib.makeFunction(name: "scene_frame") else { throw GPUError.noFunction("scene_frame") }

        func make(_ f: MTLFunction, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "\(scene.id).\(f.name)"
            desc.vertexFunction = vf
            desc.fragmentFunction = f
            desc.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        return ScenePipelines(frame: try make(ff, GPU.frameFormat),
                              bake: try lib.makeFunction(name: "scene_bake").map { try make($0, GPU.bakeFormat) },
                              lut: try lib.makeFunction(name: "scene_lut").map { try make($0, GPU.bakeFormat) })
    }
}
