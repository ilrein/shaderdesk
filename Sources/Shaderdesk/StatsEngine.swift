import Darwin
import Foundation

struct ProviderTotals: Equatable {
    var tokens = 0
    var perMin = 0
}

struct StatsSnapshot {
    struct Project {
        let path: String
        let name: String
        let working: Int
        let sessions: Int
        let sources: Set<String>
    }
    var projects: [Project] = []
    var agents = 0
    var working = 0
    var workingSubagents = 0
    var idle = 0
    var processes = 0
    var tokensToday = 0
    var tokensPerMin = 0
    /// "claude", "gpt", "other"
    var providers: [String: ProviderTotals] = [:]
    var models: [String: Int] = [:]
}

/// Reads agent activity from local logs, incrementally (only new bytes each tick).
///
///  - Claude Code: ~/.claude/projects/**/*.jsonl — assistant `message.usage`, deduped by message id
///  - Codex:       ~/.codex/{sessions,archived_sessions}/**/*.jsonl — `token_usage_record` per
///                 response (deduped by response_id); older logs fall back to `token_count`
///  - running agent CLIs by process name
///
/// Nothing leaves the machine; this only reads files.
final class StatsEngine {
    var onSnapshot: ((StatsSnapshot) -> Void)?

    private enum Kind { case claude, codex }
    private struct FileState {
        let kind: Kind
        var offset: UInt64 = 0
        var mtime: Date = .distantPast
        var cwd: String?
        let subagent: Bool
        var ignored: Bool
        var model: String?
        var hasRecords = false
        var lastTotal = 0
    }

    private let claudeRoot: URL
    private let codexRoots: [URL]
    private let workingWindow: TimeInterval = 25
    private let projectWindow: TimeInterval = 15 * 60
    private let ignore = try! NSRegularExpression(pattern: "codenotch-usage", options: .caseInsensitive)
    private let agentNames: Set<String> = ["claude", "codex", "aider", "cursor-agent", "gemini", "opencode", "amp"]

    private let queue = DispatchQueue(label: "shaderdesk.stats", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var files: [String: FileState] = [:]
    private var seen = Set<String>()
    private var recent: [(t: TimeInterval, n: Int, p: String)] = []
    private var dayStart: Date
    private var tokensToday = 0
    private var providers: [String: Int] = [:]
    private var models: [String: Int] = [:]
    private var lastScan = Date.distantPast
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoNoFrac = ISO8601DateFormatter()

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, since: Date? = nil) {
        claudeRoot = home.appendingPathComponent(".claude/projects")
        let codex = home.appendingPathComponent(".codex")
        codexRoots = [codex.appendingPathComponent("sessions"), codex.appendingPathComponent("archived_sessions")]
        fixedStart = since
        dayStart = since ?? Calendar.current.startOfDay(for: Date())
    }
    private let fixedStart: Date?

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.tickAndPublish() }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// Synchronous single tick (used by --snapshot).
    func tickNow() -> StatsSnapshot { queue.sync { tick() } }

    private func tickAndPublish() {
        let s = tick()
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(s) }
    }

    // MARK: - tick

    private func tick() -> StatsSnapshot {
        let now = Date()
        let today = fixedStart ?? Calendar.current.startOfDay(for: now)
        if today != dayStart { resetDay(today) }
        if now.timeIntervalSince(lastScan) > 20 {
            lastScan = now
            discover()
        }
        for path in Array(files.keys) { ingest(path) }

        let nowT = now.timeIntervalSince1970
        recent.removeAll { $0.t < nowT - 300 }
        var perMin: [String: Int] = [:]
        for r in recent where r.t >= nowT - 60 { perMin[r.p, default: 0] += r.n }

        var working = 0, workingSub = 0
        var projects: [String: (name: String, working: Int, sessions: Int, sources: Set<String>)] = [:]
        for (path, s) in files where !s.ignored {
            let age = now.timeIntervalSince(s.mtime)
            let isWorking = age < workingWindow
            if isWorking {
                working += 1
                if s.subagent { workingSub += 1 }
            }
            guard age < projectWindow else { continue }
            let key = s.cwd ?? (path as NSString).deletingLastPathComponent
            var p = projects[key] ?? (name: (key as NSString).lastPathComponent, working: 0, sessions: 0, sources: [])
            if isWorking { p.working += 1 }
            if !s.subagent { p.sessions += 1 }
            p.sources.insert(s.kind == .claude ? "claude" : "codex")
            projects[key] = p
        }
        let processes = countAgentProcesses()
        let agents = max(processes, working)

        var snap = StatsSnapshot()
        snap.projects = projects.map { .init(path: $0.key, name: $0.value.name, working: $0.value.working,
                                             sessions: $0.value.sessions, sources: $0.value.sources) }
        snap.agents = agents
        snap.working = working
        snap.workingSubagents = workingSub
        snap.idle = max(0, agents - working)
        snap.processes = processes
        snap.tokensToday = tokensToday
        snap.tokensPerMin = perMin.values.reduce(0, +)
        for key in Set(providers.keys).union(perMin.keys) {
            snap.providers[key] = ProviderTotals(tokens: providers[key] ?? 0, perMin: perMin[key] ?? 0)
        }
        snap.models = models
        return snap
    }

    private func resetDay(_ start: Date) {
        dayStart = start
        tokensToday = 0
        providers = [:]
        models = [:]
        seen.removeAll()
        recent.removeAll()
        for k in files.keys {
            files[k]?.offset = 0
            files[k]?.lastTotal = 0
        }
    }

    // MARK: - discovery

    private func discover() {
        scan(root: claudeRoot, kind: .claude)
        for r in codexRoots { scan(root: r, kind: .codex) }
    }

    private func isIgnored(_ s: String) -> Bool {
        ignore.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private func scan(root: URL, kind: Kind) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in e {
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if name == "tool-results" || name == "memory" || isIgnored(name) { e.skipDescendants() }
                continue
            }
            guard name.hasSuffix(".jsonl"), name != "journal.jsonl" else { continue }
            let path = url.path
            if files[path] != nil { continue }
            guard let m = v?.contentModificationDate, m >= dayStart else { continue }
            files[path] = FileState(kind: kind, subagent: path.contains("/subagents/"), ignored: isIgnored(path))
        }
    }

    // MARK: - ingest

    private static let nl = UInt8(ascii: "\n")
    private static let chunk = 16 << 20

    private func ingest(_ path: String) {
        guard var s = files[path] else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            files[path] = nil
            return
        }
        s.mtime = (attrs[.modificationDate] as? Date) ?? s.mtime
        if size < s.offset { s.offset = 0 }
        defer { files[path] = s }
        guard size > s.offset, !s.ignored, let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }

        while s.offset < size, !s.ignored {
            try? fh.seek(toOffset: s.offset)
            let want = Int(min(UInt64(Self.chunk), size - s.offset))
            guard let data = try? fh.read(upToCount: want), !data.isEmpty else { break }
            guard let last = data.lastIndex(of: Self.nl) else {
                if data.count >= Self.chunk { s.offset += UInt64(data.count) } // absurdly long line: skip
                break
            }
            let body = data[data.startIndex..<last]
            s.offset += UInt64(last - data.startIndex + 1)
            for line in body.split(separator: Self.nl, omittingEmptySubsequences: true) {
                if s.kind == .claude { parseClaude(Data(line), &s) } else { parseCodex(Data(line), &s) }
                if s.ignored { break }
            }
        }
    }

    private static let kUsage = Data("\"usage\"".utf8)
    private static let kCwd = Data("\"cwd\"".utf8)
    private static let kRecord = Data("\"token_usage_record\"".utf8)
    private static let kCount = Data("\"token_count\"".utf8)
    private static let kMeta = Data("\"session_meta\"".utf8)
    private static let kTurn = Data("\"turn_context\"".utf8)

    private func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    private func parseClaude(_ line: Data, _ s: inout FileState) {
        let hasCwd = s.cwd == nil && line.range(of: Self.kCwd) != nil
        let hasUsage = line.range(of: Self.kUsage) != nil
        guard hasCwd || hasUsage,
              let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if hasCwd, let cwd = row["cwd"] as? String {
            s.cwd = cwd
            if isIgnored(cwd) { s.ignored = true; return }
        }
        guard hasUsage, let msg = row["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
              let ts = date(row["timestamp"]), ts >= dayStart else { return }
        if let id = (msg["id"] ?? row["requestId"] ?? row["uuid"]) as? String {
            if seen.contains(id) { return }
            seen.insert(id)
        }
        var model = msg["model"] as? String
        if model == "<synthetic>" { model = nil }
        record(ts, model: model, claude: true,
               input: int(u["input_tokens"]), output: int(u["output_tokens"]),
               cacheWrite: int(u["cache_creation_input_tokens"]), cacheRead: int(u["cache_read_input_tokens"]))
    }

    private func parseCodex(_ line: Data, _ s: inout FileState) {
        let isMeta = line.range(of: Self.kMeta) != nil || line.range(of: Self.kTurn) != nil
        let isRecord = line.range(of: Self.kRecord) != nil
        let isCount = !isRecord && line.range(of: Self.kCount) != nil
        guard isMeta || isRecord || isCount,
              let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let type = row["type"] as? String
        let p = row["payload"] as? [String: Any] ?? [:]
        if type == "session_meta" || type == "turn_context" {
            if s.cwd == nil, let cwd = p["cwd"] as? String {
                s.cwd = cwd
                if isIgnored(cwd) { s.ignored = true }
            }
            if let m = p["model"] as? String { s.model = m }
            return
        }
        let ts = date(row["timestamp"])
        if type == "token_usage_record", let u = p["usage"] as? [String: Any] {
            s.hasRecords = true
            guard let ts, ts >= dayStart else { return }
            if let rid = p["response_id"] as? String {
                let id = "codex:" + rid
                if seen.contains(id) { return }
                seen.insert(id)
            }
            recordCodex(ts, model: (p["model"] as? String) ?? s.model, u)
            return
        }
        // older rollouts: token_count events (cumulative + last), sometimes repeated
        if (p["type"] as? String) == "token_count", !s.hasRecords, let info = p["info"] as? [String: Any] {
            let cumulative = int((info["total_token_usage"] as? [String: Any])?["total_tokens"])
            if cumulative == s.lastTotal { return }
            s.lastTotal = cumulative
            guard let ts, ts >= dayStart, let last = info["last_token_usage"] as? [String: Any] else { return }
            recordCodex(ts, model: s.model, last)
        }
    }

    /// OpenAI usage: input includes cached input; reasoning is included in output.
    private func recordCodex(_ ts: Date, model: String?, _ u: [String: Any]) {
        let cached = int(u["cached_input_tokens"])
        record(ts, model: model, claude: false,
               input: max(0, int(u["input_tokens"]) - cached), output: int(u["output_tokens"]),
               cacheWrite: int(u["cache_write_input_tokens"]), cacheRead: cached)
    }

    private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    private func provider(_ model: String?, claude: Bool) -> String {
        let m = (model ?? "").lowercased()
        if m.contains("claude") || m.contains("opus") || m.contains("sonnet") || m.contains("haiku") { return "claude" }
        if m.contains("gpt") || m.hasPrefix("codex") || m.range(of: "^o[0-9]", options: .regularExpression) != nil { return "gpt" }
        if !m.isEmpty { return "other" }
        return claude ? "claude" : "gpt"
    }

    private func record(_ ts: Date, model: String?, claude: Bool, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        let total = input + output + cacheWrite + cacheRead
        guard total > 0 else { return }
        let p = provider(model, claude: claude)
        tokensToday += total
        providers[p, default: 0] += total
        models[model ?? "\(p) (unknown)", default: 0] += total
        recent.append((ts.timeIntervalSince1970, total, p))
    }

    // MARK: - processes

    private func countAgentProcesses() -> Int {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard got > 0 else { return 0 }
        var count = 0
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0, agentNames.contains(String(cString: name)) { count += 1 }
        }
        return count
    }
}
