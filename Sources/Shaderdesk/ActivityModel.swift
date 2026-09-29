import CoreGraphics
import Foundation
import simd

/// Everything a renderer needs for one frame. Positions are global desktop points.
struct World {
    var time: Double = 0
    var drift = SIMD2<Float>()
    var clock: Double = 0   // scene clock: seconds scaled by the Motion speed setting
    var act: Float = 0
    var pulse: Float = 0
    var brightness: Float = 1
    var galaxies: [GalaxyGPU] = []
    var flares: [FlareGPU] = Array(repeating: FlareGPU(), count: GPU.maxFlares)
    var desk = CGRect(x: 0, y: 0, width: 1, height: 1)
}

struct GalaxyInfo {
    let key: String
    let name: String
    let center: CGPoint
    let radius: CGFloat
    let opacity: Double
    let provider: String
}

// Deterministic PRNG so a project's galaxy always lands in the same place.
struct Mulberry32 {
    var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> Double {
        state &+= 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (1 | t)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}

func fnv1a(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
    return h
}

/// Shared across displays; advanced once per frame on the main thread.
final class ActivityModel {
    static let shared = ActivityModel()

    var dataEnabled = true
    var brightness: Float = 1
    var speed: Double = 1
    /// fixes activity for testing / snapshots
    var forcedLevel: Float?
    private(set) var snapshot: StatsSnapshot?

    /// display frames in global points; set by the wallpaper controller
    var screens: [CGRect] = [] { didSet { relayout() } }
    /// region the counters occupy (global points), galaxies avoid it
    var hudRect: CGRect = .zero

    private(set) var world = World()
    private var lastTime: Double = -1
    private var camT: Double = 0
    private var pulse: Float = 0
    private var burst = false
    private var lastTokens = -1
    private var act: Float = 0

    private struct Proj { var name: String; var value: Double; var target: Double; var working: Int; var gpt: Bool }
    private var projects: [String: Proj] = [:]
    private struct Slot {
        let key: String
        let center: CGPoint
        let radius: CGFloat
        let rotation: Float
        let inclination: Float
        let seed: Float
        let elliptical: Float
        let hue: Double
    }
    private var slots: [Slot?] = Array(repeating: nil, count: GPU.maxGalaxies)
    private var flareCursor = 0
    private var flareAcc = 0.0
    private var rng = Mulberry32(seed: 99)

    var desk: CGRect {
        screens.reduce(CGRect.null) { $0.union($1) }.nonEmpty ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func ingest(_ s: StatsSnapshot) {
        if lastTokens >= 0, s.tokensToday > lastTokens {
            pulse = min(1, pulse + min(0.6, Float(s.tokensToday - lastTokens) / 250_000))
            burst = true
        }
        lastTokens = s.tokensToday
        snapshot = s
    }

    func clearData() {
        snapshot = nil
        lastTokens = -1
    }

    private func targetActivity() -> Float {
        if let f = forcedLevel { return f }
        guard dataEnabled, let s = snapshot else { return 0.18 }
        let drive = Double(s.working) * 0.42 + Double(s.idle) * 0.05 + min(1, Double(s.tokensPerMin) / 2_000_000)
        return Float(1 - exp(-drive))
    }

    /// Advance to `time` (seconds). Safe to call from every display each frame.
    @discardableResult
    func advance(to time: Double) -> World {
        if time == lastTime { return world }
        let dt = lastTime < 0 ? 0 : min(0.25, max(0, time - lastTime))
        lastTime = time
        let k = 1 - exp(-dt / 2.5)

        act += (targetActivity() - act) * Float(k)
        pulse *= Float(exp(-dt / 0.8))
        let tokenBurst = burst
        burst = false

        // projects -> smoothed intensity
        var live = Set<String>()
        if dataEnabled, let s = snapshot {
            for p in s.projects {
                live.insert(p.path)
                var h = projects[p.path] ?? Proj(name: p.name, value: 0, target: 0, working: 0, gpt: false)
                h.target = p.working > 0 ? 0.35 + 0.18 * Double(min(p.working, 4)) : 0.1
                h.working = p.working
                h.gpt = !p.sources.isEmpty && p.sources.allSatisfy { $0 == "codex" }
                projects[p.path] = h
            }
        }
        for (key, var h) in projects {
            if !live.contains(key) { h.target = 0; h.working = 0 }
            h.value += (h.target - h.value) * k
            if h.value < 0.005 && h.target == 0 { projects[key] = nil } else { projects[key] = h }
        }
        let ranked = projects.sorted { $0.value.value > $1.value.value }.prefix(GPU.maxGalaxies)
        assignSlots(Set(ranked.map { $0.key }))

        // galaxies for the GPU
        var galaxies: [GalaxyGPU] = []
        var working: [Slot] = []
        for slot in slots.compactMap({ $0 }) {
            guard let p = projects[slot.key] else { continue }
            let tint: SIMD3<Float> = p.gpt
                ? SIMD3(0.42, 0.90, 0.80)
                : simd_mix(SIMD3(0.55, 0.68, 1.0), SIMD3(0.85, 0.60, 1.0), SIMD3(repeating: Float(slot.hue)))
            galaxies.append(GalaxyGPU(
                posSize: SIMD4(Float(slot.center.x), Float(slot.center.y), Float(slot.radius), slot.rotation),
                look: SIMD4(Float(0.12 + p.value * 0.95) * brightness, slot.inclination, slot.seed, slot.elliptical),
                tint: SIMD4(tint, p.working > 0 ? 1 : 0)))
            if p.working > 0 { working.append(slot) }
        }

        // flares: rare when idle, more with throughput; many land in busy galaxies
        let tpm = Double(snapshot?.tokensPerMin ?? 0)
        let perMin = 0.6 + Double(act) * 6 + (dataEnabled ? min(8, tpm / 250_000) : 0)
        flareAcc += dt * perMin / 60
        if tokenBurst && !working.isEmpty && rng.next() < 0.35 { flareAcc += 1 }
        while flareAcc >= 1 {
            flareAcc -= 1
            let home = !working.isEmpty && rng.next() < 0.6 ? working[Int(rng.next() * Double(working.count))] : nil
            spawnFlare(at: time, near: home)
        }

        camT += dt * speed
        world.time = time
        world.clock = camT
        world.drift = SIMD2(Float(sin(camT * 0.013) * 30), Float(sin(camT * 0.009 + 1.3) * 20))
        world.act = act
        world.pulse = pulse
        world.brightness = brightness
        world.galaxies = galaxies
        world.desk = desk
        return world
    }

    /// Galaxy label data for the overlay.
    func galaxyInfos() -> [GalaxyInfo] {
        slots.compactMap { slot in
            guard let slot, let p = projects[slot.key] else { return nil }
            return GalaxyInfo(key: slot.key, name: p.name, center: slot.center, radius: slot.radius,
                              opacity: 0.22 + min(1, p.value) * 0.45, provider: p.gpt ? "gpt" : "claude")
        }
    }

    // MARK: - placement

    private func relayout() {
        slots = Array(repeating: nil, count: GPU.maxGalaxies)
    }

    private func assignSlots(_ wanted: Set<String>) {
        for i in slots.indices where slots[i].map({ !wanted.contains($0.key) }) ?? false { slots[i] = nil }
        for key in wanted where !slots.contains(where: { $0?.key == key }) {
            guard let free = slots.firstIndex(where: { $0 == nil }) else { break }
            slots[free] = place(key)
        }
    }

    private func place(_ key: String) -> Slot {
        var r = Mulberry32(seed: fnv1a(key))
        let radius = CGFloat(36 + r.next() * 20)
        let screens = self.screens.isEmpty ? [desk] : self.screens
        let others = slots.compactMap { $0?.center }
        var best = CGPoint(x: desk.midX, y: desk.midY)
        var bestScore = -Double.infinity
        for _ in 0..<24 {
            let s = screens[Int(r.next() * Double(screens.count)) % screens.count]
            let c = CGPoint(x: s.minX + s.width * (0.08 + r.next() * 0.84),
                            y: s.minY + s.height * (0.22 + r.next() * 0.64))
            let pad = radius * 1.6
            guard s.insetBy(dx: pad, dy: pad).contains(c) else { continue }
            if hudRect.insetBy(dx: -pad, dy: -pad).contains(c) { continue }
            let sep = others.map { hypot($0.x - c.x, $0.y - c.y) }.min() ?? 10_000
            let score = Double(min(sep, 320))
            if score > bestScore { bestScore = score; best = c }
            if sep > 320 { break }
        }
        return Slot(key: key, center: best, radius: radius,
                    rotation: Float(r.next() * .pi), inclination: Float(0.25 + r.next() * 0.7),
                    seed: Float(r.next()), elliptical: r.next() < 0.2 ? 0.7 : 0, hue: r.next())
    }

    private func spawnFlare(at time: Double, near slot: Slot?) {
        let pos: CGPoint
        if let slot {
            pos = CGPoint(x: slot.center.x + CGFloat(rng.next() - 0.5) * slot.radius * 1.2,
                          y: slot.center.y + CGFloat(rng.next() - 0.5) * slot.radius * 1.2)
        } else {
            let screens = self.screens.isEmpty ? [desk] : self.screens
            let s = screens[Int(rng.next() * Double(screens.count)) % screens.count]
            pos = CGPoint(x: s.minX + s.width * (0.05 + rng.next() * 0.9),
                          y: s.minY + s.height * (0.3 + rng.next() * 0.65))
        }
        let t = rng.next() < 0.6 ? 0.85 + rng.next() * 0.15 : 0.4 + rng.next() * 0.3
        let c = Self.starColor(t)
        world.flares[flareCursor % GPU.maxFlares] = FlareGPU(
            posStart: SIMD4(Float(pos.x), Float(pos.y), Float(time), Float(14 + rng.next() * 14)),
            color: SIMD4(c, 1))
        flareCursor += 1
    }

    static func starColor(_ t: Double) -> SIMD3<Float> {
        let stops: [(Double, SIMD3<Float>)] = [
            (0.0, SIMD3(1.0, 0.62, 0.38)), (0.3, SIMD3(1.0, 0.86, 0.70)), (0.55, SIMD3(1.0, 0.97, 0.94)),
            (0.8, SIMD3(0.80, 0.87, 1.0)), (1.0, SIMD3(0.62, 0.74, 1.0)),
        ]
        for i in 1..<stops.count where t <= stops[i].0 {
            let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
            return simd_mix(c0, c1, SIMD3(repeating: Float((t - t0) / (t1 - t0))))
        }
        return stops.last!.1
    }
}

extension CGRect {
    var nonEmpty: CGRect? { isNull || isEmpty ? nil : self }
}
