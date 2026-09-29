import AppKit
import MetalKit
import SwiftUI

/// Borderless window pinned to the desktop layer (below icons), on every Space.
final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        // stationary: doesn't slide during Space switches; canJoinAllSpaces: one window for all Spaces
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Overlay state (labels + counters) for one display. Shared with --snapshot.
func overlayState(model: ActivityModel, display: CGRect, primary: Bool,
                  scene: Scene, showLabels: Bool, showCounters: Bool) -> ([GalaxyLabel], HUDData?) {
    guard model.dataEnabled else { return ([], nil) }
    var labels: [GalaxyLabel] = []
    if showLabels && scene.showsLabels {
        let drift = model.world.drift
        for g in model.galaxyInfos() {
            let lx = g.center.x - display.minX - CGFloat(drift.x)
            let ly = g.center.y - display.minY - CGFloat(drift.y)
            guard lx > -60, lx < display.width + 60, ly > -60, ly < display.height + 60 else { continue }
            labels.append(GalaxyLabel(id: g.key, name: g.name,
                                      point: CGPoint(x: lx, y: display.height - ly + g.radius * 1.35 + 8),
                                      opacity: g.opacity))
        }
    }
    let hud = primary && showCounters ? model.snapshot.map(HUDData.init) : nil
    return (labels, hud)
}

/// One display: window + Metal view + renderer + overlay.
final class DisplayWallpaper: NSObject, MTKViewDelegate {
    let screen: NSScreen
    let isPrimary: Bool
    let window: WallpaperWindow
    let renderer: Renderer
    let overlay = OverlayModel()
    private let view: MTKView
    private let hosting: NSHostingView<OverlayView>
    private var occluded = false
    var userPaused = false { didSet { updatePaused() } }
    var systemPaused = false { didSet { updatePaused() } }

    init(screen: NSScreen, index: Int, primary: Bool, scene: Scene, fps: Int) {
        self.screen = screen
        self.isPrimary = primary
        window = WallpaperWindow(screen: screen)
        renderer = Renderer(display: screen.frame, scene: scene, seed: Float(index) * 17.31)

        view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: GPU.shared.device)
        view.colorPixelFormat = GPU.frameFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = fps
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.layer?.isOpaque = true
        // double buffering is plenty at <=60 fps and saves a full-screen drawable per display
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        view.autoresizingMask = [.width, .height]

        hosting = NSHostingView(rootView: OverlayView(model: overlay))
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        super.init()

        view.delegate = self
        let root = NSView(frame: view.frame)
        root.addSubview(view)
        root.addSubview(hosting)
        window.contentView = root
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        view.isPaused = true
        view.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    var fps: Int {
        get { view.preferredFramesPerSecond }
        set { view.preferredFramesPerSecond = newValue }
    }

    func setScene(_ scene: Scene) {
        renderer.scene = scene
        if view.isPaused { view.draw() } // show the new scene even while paused
    }

    /// Covered (fullscreen app, other Space's windows, ...) → stop drawing but keep
    /// everything alive, so uncovering is instant and nothing flickers.
    @objc private func occlusionChanged() {
        occluded = !window.occlusionState.contains(.visible)
        debugLog("\(screen.localizedName): \(occluded ? "covered, pausing" : "visible, resuming")")
        updatePaused()
    }

    private func updatePaused() {
        let paused = occluded || userPaused || systemPaused
        if view.isPaused && !paused {
            frameCount = 0
            fpsWindowStart = CACurrentMediaTime()
        }
        view.isPaused = paused
    }

    func refreshOverlay(model: ActivityModel, settings: Settings, animated: Bool) {
        let (labels, hud) = overlayState(model: model, display: screen.frame, primary: isPrimary, scene: renderer.scene,
                                         showLabels: settings.showLabels, showCounters: settings.showCounters)
        if overlay.labels != labels { overlay.labels = labels }
        if overlay.hud != hud {
            if animated { withAnimation(.easeOut(duration: 0.9)) { overlay.hud = hud } } else { overlay.hud = hud }
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.needsBake = true
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cb = GPU.shared.queue.makeCommandBuffer() else { return }
        let world = ActivityModel.shared.advance(to: Clock.now)
        renderer.encode(cb, target: drawable.texture, world: world)
        cb.addCompletedHandler { [weak self] cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.recordFrame(gpuMs: ms) }
        }
        cb.present(drawable)
        cb.commit()
    }

    // MARK: stats (shown in the menu)

    /// smoothed GPU time per frame (ms) and frames drawn per second
    private(set) var gpuMs: Double = 0
    private(set) var drawnFPS: Double = 0
    private var frameCount = 0
    private var fpsWindowStart = CACurrentMediaTime()

    private func recordFrame(gpuMs ms: Double) {
        gpuMs = gpuMs == 0 ? ms : gpuMs * 0.95 + ms * 0.05
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 2 {
            drawnFPS = Double(frameCount) / (now - fpsWindowStart)
            frameCount = 0
            fpsWindowStart = now
        }
    }

    var statusLine: String {
        let name = screen.localizedName
        let px = "\(Int(view.drawableSize.width))×\(Int(view.drawableSize.height))"
        if view.isPaused { return "\(name): paused (\(occluded ? "covered" : "off"))" }
        return String(format: "%@: %@ · %.0f fps · %.1f ms GPU", name, px, drawnFPS, gpuMs)
    }
}

/// SHADERDESK_DEBUG=1 prints pause/resume events and per-display stats to stderr.
let debugEnabled = ProcessInfo.processInfo.environment["SHADERDESK_DEBUG"] == "1"
func debugLog(_ s: @autoclosure () -> String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data("[shaderdesk \(Date().formatted(date: .omitted, time: .standard))] \(s())\n".utf8))
}

enum Clock {
    private static let start = CACurrentMediaTime()
    static var now: Double { CACurrentMediaTime() - start }
}

/// Owns one DisplayWallpaper per screen, the stats engine, and the overlay refresh.
final class WallpaperController {
    private var displays: [DisplayWallpaper] = []
    private let model = ActivityModel.shared
    private let settings = Settings.shared
    private let stats = StatsEngine()
    private var overlayTimer: Timer?
    private var systemPaused = false
    private var userDirWatch: DispatchSourceFileSystemObject?

    private(set) var scenes: [Scene] = SceneCatalog.load()

    var statusLines: [String] { displays.map(\.statusLine) }

    /// The selected scene, or the first one that compiles.
    var scene: Scene {
        let wanted = scenes.first { $0.id == settings.scene }
        if let wanted, case .success = GPU.shared.pipelines(for: wanted) { return wanted }
        return scenes.first { $0.id == "universe" } ?? scenes[0]
    }

    /// Re-read scene files (built-in and user) and recompile on next frame.
    func reloadScenes() {
        GPU.shared.invalidate()
        scenes = SceneCatalog.load()
        if scenes.isEmpty { fatalError("Shaderdesk: no scenes found") }
        for d in displays { d.renderer.needsBake = true }
        applySettings()
        NotificationCenter.default.post(name: Self.scenesDidChange, object: nil)
    }

    static let scenesDidChange = Notification.Name("Shaderdesk.scenesDidChange")

    /// Editors save by replacing the file, which shows up as a directory write.
    private func watchUserScenes() {
        let dir = SceneCatalog.userDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        var pending: DispatchWorkItem?
        src.setEventHandler { [weak self] in
            pending?.cancel()
            let work = DispatchWorkItem { self?.reloadScenes() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        userDirWatch = src
    }

    func start() {
        if scenes.isEmpty { fatalError("Shaderdesk: no scenes found") }
        watchUserScenes()
        stats.onSnapshot = { [weak self] s in
            guard let self, self.settings.dataLayer else { return }
            self.model.ingest(s)
            self.refreshOverlays(animated: true)
        }
        applySettings()
        rebuild()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        nc.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }
        let ws = NSWorkspace.shared.notificationCenter
        for (name, paused) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                               (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(paused) }
        }

        // labels drift very slowly (<0.5 pt/s), so 2 Hz is plenty
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshOverlays(animated: false)
        }
        if debugEnabled {
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.statusLines.forEach { debugLog($0) }
            }
        }
    }

    private func setSystemPaused(_ paused: Bool) {
        systemPaused = paused
        displays.forEach { $0.systemPaused = paused }
    }

    func rebuild() {
        displays.forEach { $0.close() }
        displays = []
        let screens = NSScreen.screens
        builtForCountersDisplay = settings.countersDisplay
        // counters go on the chosen display (by name), else the main one
        let hudScreen = screens.firstIndex { $0.localizedName == settings.countersDisplay } ?? 0
        if screens.indices.contains(hudScreen) {
            let f = screens[hudScreen].frame
            model.hudRect = CGRect(x: f.minX, y: f.minY, width: 560, height: OverlayView.hudInset.height + 140)
        }
        model.screens = screens.map(\.frame) // also re-places galaxies around the new hudRect
        for (i, screen) in screens.enumerated() {
            let d = DisplayWallpaper(screen: screen, index: i, primary: i == hudScreen, scene: scene, fps: settings.fps)
            d.userPaused = settings.paused
            d.systemPaused = systemPaused
            displays.append(d)
        }
        refreshOverlays(animated: false)
    }

    private var builtForCountersDisplay: String?

    var screenNames: [String] { NSScreen.screens.map(\.localizedName) }

    private func applySettings() {
        if !displays.isEmpty && builtForCountersDisplay != settings.countersDisplay {
            rebuild()
        }
        model.brightness = Float(settings.brightness)
        model.speed = settings.driftSpeed
        if settings.dataLayer != model.dataEnabled || displays.isEmpty {
            model.dataEnabled = settings.dataLayer
            if settings.dataLayer { stats.start() } else { stats.stop(); model.clearData() }
        }
        let current = scene
        for d in displays {
            d.setScene(current)
            d.fps = settings.fps
            d.userPaused = settings.paused
        }
        refreshOverlays(animated: false)
    }

    private func refreshOverlays(animated: Bool) {
        displays.forEach { $0.refreshOverlay(model: model, settings: settings, animated: animated) }
    }
}
