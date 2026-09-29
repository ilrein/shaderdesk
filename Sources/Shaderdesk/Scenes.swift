import Foundation

/// A wallpaper scene: one `.metal` file compiled on its own, with `Common.metal`
/// prepended. It must define `fragment float4 scene_frame(...)` and may define
/// `fragment float4 scene_bake(...)` for the expensive static part.
///
/// Metadata lives in `//!` comment lines at the top of the file:
///
///     //! title: Distant Universe
///     //! order: 0
///     //! labels: true      (draws project galaxies, so show their names)
struct Scene: Equatable {
    let id: String
    let title: String
    let order: Int
    let showsLabels: Bool
    let url: URL
    let builtIn: Bool
}

enum SceneCatalog {
    static let preludeName = "Common.metal"

    /// ~/Library/Application Support/Shaderdesk/Scenes — drop .metal files here.
    static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shaderdesk/Scenes", isDirectory: true)
    }

    /// Built-in scenes ship in Contents/Resources/Scenes; under `swift run` they're
    /// read straight from the package's Scenes/ folder.
    static var builtInDirectory: URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Scenes"),
           fm.fileExists(atPath: res.appendingPathComponent(preludeName).path) { return res }
        let pkg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scenes")
        return fm.fileExists(atPath: pkg.appendingPathComponent(preludeName).path) ? pkg : nil
    }

    static var preludeURL: URL? { builtInDirectory?.appendingPathComponent(preludeName) }

    /// All scenes, built-in first; a user file with the same id replaces the built-in one.
    static func load() -> [Scene] {
        var byID: [String: Scene] = [:]
        if let dir = builtInDirectory { for s in scan(dir, builtIn: true) { byID[s.id] = s } }
        for s in scan(userDirectory, builtIn: false) { byID[s.id] = s }
        return byID.values.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }

    private static func scan(_ dir: URL, builtIn: Bool) -> [Scene] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".metal") && $0 != preludeName }.compactMap { name in
            let url = dir.appendingPathComponent(name)
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let meta = metadata(src)
            let id = (name as NSString).deletingPathExtension.lowercased()
            return Scene(id: id,
                         title: meta["title"] ?? (name as NSString).deletingPathExtension,
                         order: Int(meta["order"] ?? "") ?? 100,
                         showsLabels: meta["labels"] == "true",
                         url: url, builtIn: builtIn)
        }
    }

    static func metadata(_ src: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in src.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            guard line.hasPrefix("//!") else { continue }
            let body = line.dropFirst(3)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[key] = value
        }
        return out
    }
}
