import AppKit
import MetalKit
import ServiceManagement
import SwiftUI

// MARK: - Previews

/// Scenes render in desktop points, so a preview renders a whole virtual display
/// (1440x900 pt) into a small texture: a true miniature of the wallpaper.
enum Preview {
    static let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// A calm, data-free world for previews (no galaxies or flares), with some activity
    /// so reactive scenes don't look asleep.
    static func world(time: Double) -> World {
        var w = World()
        w.time = time
        w.clock = time
        w.drift = SIMD2(Float(sin(time * 0.013) * 30), Float(sin(time * 0.009 + 1.3) * 20))
        w.act = 0.35
        w.brightness = Float(Settings.shared.brightness)
        w.desk = display
        return w
    }

    /// Renders one frame of `scene` offscreen. Nil if the scene doesn't compile.
    static func image(_ scene: Scene, pixelWidth: Int, time: Double = 30) -> CGImage? {
        guard case .success = GPU.shared.pipelines(for: scene) else { return nil }
        let gpu = GPU.shared
        let w = pixelWidth, h = Int(Double(pixelWidth) * display.height / display.width)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GPU.frameFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = gpu.device.makeTexture(descriptor: d), let cb = gpu.queue.makeCommandBuffer() else { return nil }
        Renderer(display: display, scene: scene, seed: 0).encode(cb, target: tex, world: world(time: time))
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return bytes.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)?.makeImage()
        }
    }
}

/// Live, animated preview used while hovering a card. Only exists while hovered.
struct LivePreview: NSViewRepresentable {
    let scene: Scene

    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: Renderer
        let start = CACurrentMediaTime()
        init(scene: Scene) { renderer = Renderer(display: Preview.display, scene: scene, seed: 0) }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { renderer.needsBake = true }
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable, let cb = GPU.shared.queue.makeCommandBuffer() else { return }
            // start at 30 s so it matches the thumbnail, then play sped up so motion is visible
            let t = 30 + (CACurrentMediaTime() - start) * 3
            renderer.encode(cb, target: drawable.texture, world: Preview.world(time: t))
            cb.present(drawable)
            cb.commit()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(scene: scene) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: GPU.shared.device)
        v.colorPixelFormat = GPU.frameFormat
        v.framebufferOnly = true
        v.preferredFramesPerSecond = 30
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        if context.coordinator.renderer.scene != scene { context.coordinator.renderer.scene = scene }
    }

    static func dismantleNSView(_ v: MTKView, coordinator: Coordinator) {
        v.isPaused = true
        v.delegate = nil
    }
}

// MARK: - Model

/// Bridges Settings + the scene catalog into SwiftUI.
final class GalleryModel: ObservableObject {
    struct Item: Identifiable {
        let scene: Scene
        var id: String { scene.id }
        let thumbnail: NSImage?
        let error: String?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var current: String = ""
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    let settings = Settings.shared
    private let controller: WallpaperController
    private var thumbs: [String: (Date, NSImage)] = [:] // path -> (mtime, image)
    private var observers: [NSObjectProtocol] = []

    init(controller: WallpaperController) {
        self.controller = controller
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncSettings()
        })
        observers.append(nc.addObserver(forName: WallpaperController.scenesDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        refresh()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func syncSettings() {
        objectWillChange.send()
        current = controller.scene.id
    }

    /// Rebuilds the list; thumbnails are re-rendered only for files that changed.
    func refresh() {
        let fm = FileManager.default
        items = controller.scenes.map { s in
            let mtime = (try? fm.attributesOfItem(atPath: s.url.path)[.modificationDate] as? Date) ?? .distantPast
            var thumb = thumbs[s.url.path].flatMap { $0.0 == mtime ? $0.1 : nil }
            if thumb == nil, let cg = Preview.image(s, pixelWidth: 640) {
                thumb = NSImage(cgImage: cg, size: NSSize(width: 320, height: 200))
                thumbs[s.url.path] = (mtime, thumb!)
            }
            return Item(scene: s, thumbnail: thumb, error: GPU.shared.error(for: s).map { ($0 as NSError).localizedDescription })
        }
        current = controller.scene.id
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func select(_ s: Scene) { settings.scene = s.id }
    func reload() { controller.reloadScenes() }
    var screenNames: [String] { controller.screenNames }

    func setLaunchAtLogin(_ on: Bool) {
        do { try AppActions.setLaunchAtLogin(on) } catch { AppActions.alert("Couldn't change the login item", error) }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Two-way binding to a Settings property.
    func binding<T>(_ key: ReferenceWritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: key] }, set: { self.settings[keyPath: key] = $0 })
    }
}

enum AppActions {
    static func openScenesFolder() {
        let dir = SceneCatalog.userDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // seed the folder with the built-in scenes as examples to copy from
        if let builtIn = SceneCatalog.builtInDirectory {
            let examples = dir.appendingPathComponent("Examples")
            try? FileManager.default.removeItem(at: examples)
            try? FileManager.default.copyItem(at: builtIn, to: examples)
        }
        NSWorkspace.shared.open(dir)
    }

    static func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func showError(_ sceneTitle: String, _ message: String) {
        let a = NSAlert()
        a.messageText = "\(sceneTitle) doesn't compile"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Open Scenes Folder")
        if a.runModal() == .alertSecondButtonReturn { openScenesFolder() }
    }

    static func alert(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "\(error.localizedDescription)\n\nMove Shaderdesk to /Applications and try again."
        a.runModal()
    }
}

// MARK: - Views

struct GalleryView: View {
    @ObservedObject var model: GalleryModel
    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(model.items) { item in
                        SceneCard(item: item, selected: item.id == model.current) {
                            if let err = item.error { AppActions.showError(item.scene.title, err) } else { model.select(item.scene) }
                        }
                    }
                    AddSceneCard()
                }
                .padding(20)
            }
            Divider()
            SettingsBar(model: model)
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}

struct SceneCard: View {
    let item: GalleryModel.Item
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Color.black
                    if hovering && item.error == nil {
                        LivePreview(scene: item.scene)
                    } else if let t = item.thumbnail {
                        Image(nsImage: t).resizable().interpolation(.high)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").font(.title2)
                            Text("Doesn't compile").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(1440.0 / 900.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(8)
                    }
                }

                HStack(spacing: 6) {
                    Text(item.scene.title).font(.headline)
                    if !item.scene.builtIn {
                        Text("Custom")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                    Spacer()
                    if item.scene.showsLabels {
                        Image(systemName: "chart.dots.scatter").foregroundStyle(.secondary)
                            .help("Shows project galaxies and names from agent activity")
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.error ?? "Use \(item.scene.title) as the wallpaper")
    }
}

/// Last card: where to put your own scenes.
struct AddSceneCard: View {
    var body: some View {
        Button(action: AppActions.openScenesFolder) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .aspectRatio(1440.0 / 900.0, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.title2)
                            Text("Add a .metal scene").font(.callout)
                        }
                        .foregroundStyle(.secondary)
                    }
                Text("Your Scenes Folder").font(.headline).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Opens ~/Library/Application Support/Shaderdesk/Scenes. Files you save there show up here.")
    }
}

struct SettingsBar: View {
    @ObservedObject var model: GalleryModel

    var body: some View {
        let s = model.settings
        HStack(alignment: .center, spacing: 18) {
            Toggle("Agent activity", isOn: model.binding(\.dataLayer))
            Toggle("Counters", isOn: model.binding(\.showCounters)).disabled(!s.dataLayer)
            Toggle("Project names", isOn: model.binding(\.showLabels)).disabled(!s.dataLayer)
            if model.screenNames.count > 1 {
                Picker("Counters on", selection: model.binding(\.countersDisplay)) {
                    Text("Main Display").tag("")
                    ForEach(model.screenNames, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                .disabled(!s.dataLayer || !s.showCounters)
            }
            Spacer(minLength: 0)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 20).padding(.top, 12)

        HStack(spacing: 18) {
            Picker("Frame rate", selection: model.binding(\.fps)) {
                ForEach([15, 20, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            .fixedSize()
            Picker("Brightness", selection: model.binding(\.brightness)) {
                Text("Dim").tag(0.7); Text("Normal").tag(1.0); Text("Bright").tag(1.35)
            }
            .fixedSize()
            Picker("Motion", selection: model.binding(\.driftSpeed)) {
                Text("Still").tag(0.0); Text("Slow").tag(1.0); Text("Faster").tag(3.0)
            }
            .fixedSize()
            Spacer(minLength: 0)
            Toggle("Pause", isOn: model.binding(\.paused)).toggleStyle(.checkbox)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

// MARK: - Window

/// The app's window. Opening it makes Shaderdesk a regular app (Dock icon, menu bar,
/// Cmd-Tab); closing it goes back to living only in the menu bar.
final class GalleryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let controller: WallpaperController
    private var model: GalleryModel?

    init(controller: WallpaperController) { self.controller = controller }

    func show() {
        if window == nil {
            let model = GalleryModel(controller: controller)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Shaderdesk"
            w.contentView = NSHostingView(rootView: GalleryView(model: model))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("ShaderdeskGallery")
            if !w.setFrameUsingName("ShaderdeskGallery") { w.center() }
            window = w
            self.model = model
        } else {
            model?.refresh()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // drop the window (and its live previews); back to a menu-bar-only app
        window = nil
        model = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
