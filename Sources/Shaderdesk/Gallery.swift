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

/// Bridges the scene catalog and the selected scene into SwiftUI.
final class GalleryModel: ObservableObject {
    struct Item: Identifiable {
        let scene: Scene
        var id: String { scene.id }
        let thumbnail: NSImage?
        let error: String?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var current: String = ""
    let settings = Settings.shared
    private let controller: WallpaperController
    private var thumbs: [String: (Date, NSImage)] = [:] // path -> (mtime, image)
    private var observers: [NSObjectProtocol] = []

    init(controller: WallpaperController) {
        self.controller = controller
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.current = self.controller.scene.id
        })
        observers.append(nc.addObserver(forName: WallpaperController.scenesDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        refresh()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Rebuilds the list; thumbnails are re-rendered only for files that changed.
    func refresh() {
        let fm = FileManager.default
        items = controller.scenes.map { s in
            let mtime = (try? fm.attributesOfItem(atPath: s.url.path)[.modificationDate] as? Date) ?? .distantPast
            var thumb = thumbs[s.url.path].flatMap { $0.0 == mtime ? $0.1 : nil }
            if thumb == nil, let cg = Preview.image(s, pixelWidth: 720) {
                thumb = NSImage(cgImage: cg, size: NSSize(width: 360, height: 225))
                thumbs[s.url.path] = (mtime, thumb!)
            }
            return Item(scene: s, thumbnail: thumb, error: GPU.shared.error(for: s).map { ($0 as NSError).localizedDescription })
        }
        current = controller.scene.id
    }

    func select(_ s: Scene) { settings.scene = s.id }
}

enum AppActions {
    static func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func alert(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "\(error.localizedDescription)\n\nMove Shaderdesk to /Applications and try again."
        a.runModal()
    }
}

// MARK: - Views

/// The whole UI: every scene as a big thumbnail. Click one and it's the wallpaper.
struct PickerView: View {
    @ObservedObject var model: GalleryModel
    private let columns = [GridItem(.fixed(CardSize.width), spacing: 14), GridItem(.fixed(CardSize.width), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: model.items.count > 1 ? columns : [columns[0]], spacing: 14) {
            ForEach(model.items) { item in
                SceneCard(item: item, selected: item.id == model.current) {
                    if item.error == nil { model.select(item.scene) }
                }
            }
        }
        .padding(16)
        .fixedSize()
    }
}

enum CardSize {
    static let width: CGFloat = 300
    static let height: CGFloat = width * 900 / 1440
}

struct SceneCard: View {
    let item: GalleryModel.Item
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                HStack(spacing: 6) {
                    Text(item.scene.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 14)) }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(width: CardSize.width, height: CardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.white.opacity(hovering ? 0.35 : 0.1),
                                  lineWidth: selected ? 2.5 : 1)
            )
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.error ?? item.scene.title)
    }
}

// MARK: - Popover

/// Shown from the menu bar icon. Live previews only run for the hovered card.
final class PickerPopover: NSObject {
    private let popover = NSPopover()
    private let model: GalleryModel

    init(controller: WallpaperController) {
        model = GalleryModel(controller: controller)
        super.init()
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: PickerView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    var isShown: Bool { popover.isShown }

    func show(from button: NSStatusBarButton) {
        model.refresh()
        // size up front, so the popover is placed for its final size under the icon
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() { popover.performClose(nil) }
}
