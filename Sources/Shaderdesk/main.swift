import AppKit
import ServiceManagement

let args = CommandLine.arguments
if args.contains("--snapshot") {
    // Offscreen render to a PNG, e.g.
    //   Shaderdesk --snapshot out.png --scene redgiant --size 1512x945 --scale 2 --time 40 --demo
    let ok = MainActor.assumeIsolated { Snapshot.run(args) }
    exit(ok ? 0 : 1)
}

if let i = args.firstIndex(of: "--login-item"), i + 1 < args.count {
    // Register/unregister this bundle as a login item: Shaderdesk --login-item on|off
    do {
        try AppActions.setLaunchAtLogin(args[i + 1] == "on")
        print("login item: \(SMAppService.mainApp.status == .enabled ? "enabled" : "disabled")")
        exit(0)
    } catch {
        FileHandle.standardError.write("login item: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
