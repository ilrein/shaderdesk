import AppKit
import ServiceManagement

/// Menu-bar-only app. Clicking the icon opens the scene picker; right-clicking offers
/// Launch at Login and Quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = WallpaperController()
    private lazy var picker = PickerPopover(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.image
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        controller.start()

        // first launch: open the picker so people see what's there
        if !UserDefaults.standard.bool(forKey: "didShowGallery") {
            UserDefaults.standard.set(true, forKey: "didShowGallery")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPicker() }
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the picker.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPicker()
        return true
    }

    private func showPicker() {
        guard let button = statusItem.button else { return }
        picker.show(from: button)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if picker.isShown {
            picker.close()
        } else {
            showPicker()
        }
    }

    private func showMenu() {
        picker.close()
        let menu = NSMenu()
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Shaderdesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // show once, then detach so left clicks go back to the picker
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLogin() {
        do { try AppActions.setLaunchAtLogin(SMAppService.mainApp.status != .enabled) }
        catch { AppActions.alert("Couldn't change the login item", error) }
    }
}
