import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = WallpaperController()
    private let settings = Settings.shared
    private lazy var gallery = GalleryWindowController(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        NSApp.mainMenu = Self.mainMenu()
        controller.start()

        // first launch: show the gallery so people find their way around
        if !UserDefaults.standard.bool(forKey: "didShowGallery") {
            UserDefaults.standard.set(true, forKey: "didShowGallery")
            gallery.show()
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad, `open`) shows the gallery.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        gallery.show()
        return true
    }

    /// Closing the gallery keeps the wallpaper running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// App menu shown while the gallery is open (the app is menu-bar-only otherwise).
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "About Shaderdesk", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Shaderdesk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Shaderdesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)
        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win
        return main
    }

    @objc private func openGallery() { gallery.show() }

    // Rebuilt each time it opens so checkmarks are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "Open Shaderdesk…", action: #selector(openGallery), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let scenes = NSMenuItem(title: "Scene", action: nil, keyEquivalent: "")
        let sceneMenu = NSMenu()
        let current = controller.scene
        for s in controller.scenes {
            let item = NSMenuItem(title: s.title, action: #selector(pickScene(_:)), keyEquivalent: "")
            item.representedObject = s.id
            item.state = current == s ? .on : .off
            item.target = self
            if let err = GPU.shared.error(for: s) {
                item.title = "\(s.title) (doesn't compile)"
                item.toolTip = (err as NSError).localizedDescription
                item.action = #selector(showCompileError(_:))
            }
            sceneMenu.addItem(item)
        }
        sceneMenu.addItem(.separator())
        let folder = NSMenuItem(title: "Open Scenes Folder", action: #selector(openScenesFolder), keyEquivalent: "")
        folder.target = self
        sceneMenu.addItem(folder)
        let reload = NSMenuItem(title: "Reload Scenes", action: #selector(reloadScenes), keyEquivalent: "r")
        reload.target = self
        sceneMenu.addItem(reload)
        scenes.submenu = sceneMenu
        menu.addItem(scenes)
        menu.addItem(.separator())

        menu.addItem(toggle("Agent Activity", settings.dataLayer, #selector(toggleData)))
        let counters = toggle("Show Counters", settings.showCounters, #selector(toggleCounters))
        counters.isEnabled = settings.dataLayer
        counters.indentationLevel = 1
        menu.addItem(counters)
        let names = controller.screenNames
        if names.count > 1 {
            let current = names.contains(settings.countersDisplay) ? settings.countersDisplay : ""
            let where_ = submenu("Counters On", options: [("Main Display", "")] + names.map { ($0, $0) },
                                 current: current, action: #selector(pickCountersDisplay(_:)))
            where_.isEnabled = settings.dataLayer && settings.showCounters
            where_.indentationLevel = 1
            menu.addItem(where_)
        }
        let labels = toggle("Show Project Names", settings.showLabels, #selector(toggleLabels))
        labels.isEnabled = settings.dataLayer
        labels.indentationLevel = 1
        menu.addItem(labels)
        menu.addItem(.separator())

        menu.addItem(submenu("Frame Rate", options: [15, 20, 30, 60].map { ("\($0) fps", $0) },
                             current: settings.fps, action: #selector(pickFPS(_:))))
        menu.addItem(submenu("Brightness", options: [("Dim", 0.7), ("Normal", 1.0), ("Bright", 1.35)],
                             current: settings.brightness, action: #selector(pickBrightness(_:))))
        menu.addItem(submenu("Drift", options: [("Still", 0.0), ("Slow", 1.0), ("Faster", 3.0)],
                             current: settings.driftSpeed, action: #selector(pickDrift(_:))))
        menu.addItem(toggle("Pause", settings.paused, #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(.separator())
        for line in controller.statusLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let quit = NSMenuItem(title: "Quit Shaderdesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = on ? .on : .off
        item.target = self
        return item
    }

    private func submenu<T: Equatable>(_ title: String, options: [(String, T)], current: T, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, value) in options {
            let o = NSMenuItem(title: label, action: action, keyEquivalent: "")
            o.representedObject = value
            o.state = value == current ? .on : .off
            o.target = self
            sub.addItem(o)
        }
        item.submenu = sub
        return item
    }

    @objc private func pickScene(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { settings.scene = id }
    }

    @objc private func showCompileError(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "\(sender.title)"
        alert.informativeText = sender.toolTip ?? ""
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reload Scenes")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { controller.reloadScenes() }
    }

    @objc private func openScenesFolder() { AppActions.openScenesFolder() }

    @objc private func reloadScenes() { controller.reloadScenes() }
    @objc private func pickFPS(_ sender: NSMenuItem) { if let v = sender.representedObject as? Int { settings.fps = v } }
    @objc private func pickBrightness(_ sender: NSMenuItem) { if let v = sender.representedObject as? Double { settings.brightness = v } }
    @objc private func pickDrift(_ sender: NSMenuItem) { if let v = sender.representedObject as? Double { settings.driftSpeed = v } }
    @objc private func pickCountersDisplay(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? String { settings.countersDisplay = v }
    }
    @objc private func toggleData() { settings.dataLayer.toggle() }
    @objc private func toggleCounters() { settings.showCounters.toggle() }
    @objc private func toggleLabels() { settings.showLabels.toggle() }
    @objc private func togglePause() { settings.paused.toggle() }

    @objc private func toggleLogin() {
        do { try AppActions.setLaunchAtLogin(SMAppService.mainApp.status != .enabled) }
        catch { AppActions.alert("Couldn't change the login item", error) }
    }
}
