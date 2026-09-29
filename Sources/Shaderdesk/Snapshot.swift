import AppKit
import ImageIO
import Metal
import SwiftUI
import UniformTypeIdentifiers

/// Fake agents for demos: ramps from a sleeping to a busy sky every ~90 s.
enum DemoStats {
    static let names = ["lisp-interpreter", "drum-machine", "pixel-editor", "tiny-db", "chess-engine", "synth", "raytracer"]

    static func snapshot(at t: Double, level: Double? = nil) -> StatsSnapshot {
        let wave = level ?? (0.5 - 0.5 * cos(t / 90 * 2 * .pi))
        let working = Int((wave * 7).rounded())
        let tokens = 180_000_000 + Int(t * Double(working) * 1_500)
        let tpm = working * 90_000
        var s = StatsSnapshot()
        s.projects = names.prefix(max(1, working)).enumerated().map { i, n in
            .init(path: "/tmp/demo/\(n)", name: n, working: i < working ? 1 : 0, sessions: 1,
                  sources: [i % 3 == 2 ? "codex" : "claude"])
        }
        s.agents = max(1, working)
        s.working = working
        s.workingSubagents = max(0, working - 1)
        s.idle = working == 0 ? 1 : 0
        s.tokensToday = tokens
        s.tokensPerMin = tpm
        s.providers = ["claude": .init(tokens: tokens * 76 / 100, perMin: tpm * 7 / 10),
                       "gpt": .init(tokens: tokens * 24 / 100, perMin: tpm * 3 / 10)]
        return s
    }
}

enum Snapshot {
    static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func run(_ args: [String]) -> Bool {
        guard let out = value(args, "--snapshot") else { return false }
        let scenes = SceneCatalog.load()
        let sceneID = value(args, "--scene") ?? "universe"
        // --scene-file renders a .metal file outside the catalog (e.g. Art/Icon.metal)
        let adHoc = value(args, "--scene-file").map { path -> Scene in
            let url = URL(fileURLWithPath: path)
            return Scene(id: url.deletingPathExtension().lastPathComponent.lowercased(), title: "adhoc",
                         order: 0, showsLabels: false, url: url, builtIn: false)
        }
        guard let scene = adHoc ?? scenes.first(where: { $0.id == sceneID }) else {
            print("unknown scene \(sceneID); have: \(scenes.map(\.id).joined(separator: ", "))")
            return false
        }
        if case .failure(let e) = GPU.shared.pipelines(for: scene) {
            print("scene \(scene.id) failed to compile:\n\(e)")
            return false
        }
        let size = (value(args, "--size") ?? "1512x945").split(separator: "x").compactMap { Double($0) }
        let w = CGFloat(size.first ?? 1512), h = CGFloat(size.count > 1 ? size[1] : 945)
        let scale = CGFloat(Double(value(args, "--scale") ?? "2") ?? 2)
        let time = Double(value(args, "--time") ?? "30") ?? 30
        let demo = args.contains("--demo")
        let level = value(args, "--level").flatMap(Double.init)
        let noData = args.contains("--no-data")

        let display = CGRect(x: 0, y: 0, width: w, height: h)
        let model = ActivityModel.shared
        model.screens = [display]
        model.hudRect = CGRect(x: 0, y: 0, width: 560, height: OverlayView.hudInset.height + 140)
        model.dataEnabled = !noData
        model.forcedLevel = level.map(Float.init)

        var real: StatsSnapshot?
        if !demo && !noData {
            let since = value(args, "--since").flatMap { ISO8601DateFormatter().date(from: $0 + "T00:00:00Z") }
            real = StatsEngine(since: since).tickNow()
        }

        // simulate up to `time` so smoothing, galaxies and flares settle naturally
        var t = 0.0
        var nextPoll = 0.0
        while t <= time {
            if !noData, t >= nextPoll {
                model.ingest(real ?? DemoStats.snapshot(at: t, level: level))
                nextPoll += 2
            }
            model.advance(to: t)
            t += 1.0 / 30
        }

        // render
        let pw = Int(w * scale), ph = Int(h * scale)
        let gpu = GPU.shared
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GPU.frameFormat, width: pw, height: ph, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = gpu.device.makeTexture(descriptor: d), let cb = gpu.queue.makeCommandBuffer() else { return false }
        let renderer = Renderer(display: display, scene: scene, seed: 0)
        renderer.encode(cb, target: tex, world: model.world)
        let started = CACurrentMediaTime()
        cb.commit()
        cb.waitUntilCompleted()
        let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000

        // frame-only timing (bake is cached now); --bench N renders N frames and
        // reports the median so the GPU has time to clock up
        let n = max(1, Int(value(args, "--bench") ?? "1") ?? 1)
        var times: [Double] = []
        for _ in 0..<n {
            let cb2 = gpu.queue.makeCommandBuffer()!
            renderer.encode(cb2, target: tex, world: model.world)
            cb2.commit()
            cb2.waitUntilCompleted()
            times.append((cb2.gpuEndTime - cb2.gpuStartTime) * 1000)
        }
        let frameMs = times.sorted()[times.count / 2]
        _ = started

        var bytes = [UInt8](repeating: 0, count: pw * ph * 4)
        tex.getBytes(&bytes, bytesPerRow: pw * 4, from: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: &bytes, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: cs, bitmapInfo: info) else { return false }

        // overlay (counters + labels) rendered with the same SwiftUI views
        let om = OverlayModel()
        let (labels, hud) = overlayState(model: model, display: display, primary: true,
                                         scene: scene, showLabels: true, showCounters: true)
        om.labels = labels
        om.hud = hud
        let r = ImageRenderer(content: OverlayView(model: om).frame(width: w, height: h))
        r.scale = scale
        if let overlay = r.cgImage {
            ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        }

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return false }
        print(String(format: "saved %@ (%dx%d) · first frame incl. bake %.1f ms · frame %.2f ms GPU", out, pw, ph, gpuMs, frameMs))
        if let s = model.snapshot {
            print("stats: \(s.tokensToday) tokens, \(s.projects.count) projects, \(s.working) working, providers \(s.providers.mapValues(\.tokens))")
        }
        return true
    }
}
