import Foundation

/// UserDefaults-backed preferences. Posts `Settings.didChange` on any write.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("Shaderdesk.settingsDidChange")

    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "scene": "redgiant",
            "dataLayer": false,
            "showCounters": false,
            "showLabels": true,
            "fps": 30,
            "brightness": 1.0,
            "driftSpeed": 1.0,
            "paused": false,
        ])
    }

    /// scene id (file name without .metal); resolved against the catalog by the controller
    var scene: String {
        get { d.string(forKey: "scene") ?? "redgiant" }
        set { set(newValue, "scene") }
    }
    /// read agent activity from Claude Code / Codex logs
    var dataLayer: Bool { get { d.bool(forKey: "dataLayer") } set { set(newValue, "dataLayer") } }
    var showCounters: Bool { get { d.bool(forKey: "showCounters") } set { set(newValue, "showCounters") } }
    var showLabels: Bool { get { d.bool(forKey: "showLabels") } set { set(newValue, "showLabels") } }
    /// display (NSScreen.localizedName) that shows the counters; "" = main display
    var countersDisplay: String { get { d.string(forKey: "countersDisplay") ?? "" } set { set(newValue, "countersDisplay") } }
    var fps: Int { get { d.integer(forKey: "fps") } set { set(newValue, "fps") } }
    var brightness: Double { get { d.double(forKey: "brightness") } set { set(newValue, "brightness") } }
    var driftSpeed: Double { get { d.double(forKey: "driftSpeed") } set { set(newValue, "driftSpeed") } }
    var paused: Bool { get { d.bool(forKey: "paused") } set { set(newValue, "paused") } }

    private func set(_ value: Any, _ key: String) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
}
