// Codex.swift
// AI Usage Viewer
//
// OpenAI usage comes from Codex, OpenAI's coding agent (CLI, IDE extension
// and desktop app), which is what ChatGPT plan limits apply to. Codex
// records every session as JSON lines under ~/.codex/sessions/YYYY/MM/DD/
// rollout-*.jsonl, and each `token_count` event carries the plan's
// `rate_limits`, the same numbers Codex's own /status shows. Reading those
// files needs no login and costs nothing: we never touch Codex's
// credentials or call OpenAI.
//
//   {"timestamp":"…","type":"event_msg","payload":{"type":"token_count",
//    "rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,
//    "resets_at":1790000000},"secondary":{…},"plan_type":"plus"}}}
//
// The format isn't a public API, so parsing is lenient: older Codex builds
// wrote `resets_in_seconds` (relative to the event) instead of `resets_at`,
// and the earliest wrote flat `primary_used_percent`-style keys.

import Foundation

nonisolated struct CodexSnapshot: Codable, Equatable, Sendable {
    var limits:    [UsageLimit]
    var planName:  String?
    // When Codex recorded these numbers, not when we read them.
    var fetchedAt: Date
}

nonisolated enum CodexParser {
    static let kindPrefix = "codex:"

    // The newest reading in one rollout file's text (or a tail of it).
    static func latest(inLog text: String) -> CodexSnapshot? {
        for line in text.split(separator: "\n").reversed() where line.contains("rate_limits") {
            if let s = parse(line: Data(line.utf8)) { return s }
        }
        return nil
    }

    static func parse(line: Data) -> CodexSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let rates = payload["rate_limits"] as? [String: Any],
              let at = (root["timestamp"] as? String).flatMap(HTTPParsing.isoDate) else { return nil }

        let windows = ["primary", "secondary"].compactMap { key -> [String: Any]? in
            if let w = rates[key] as? [String: Any] { return w }
            // Earliest format: primary_used_percent, primary_window_minutes, …
            let prefix = key + "_"
            let flat = rates.filter { $0.key.hasPrefix(prefix) }
            return flat.isEmpty ? nil : Dictionary(uniqueKeysWithValues: flat.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
        }
        let limits = windows.compactMap { limit(from: $0, observedAt: at) }
        guard !limits.isEmpty else { return nil }
        return CodexSnapshot(limits: limits, planName: planName(rates["plan_type"] as? String), fetchedAt: at)
    }

    static func limit(from w: [String: Any], observedAt at: Date) -> UsageLimit? {
        guard let used = UsageAPIParser.number(w["used_percent"]) else { return nil }
        let minutes = UsageAPIParser.number(w["window_minutes"])
        let resetsAt: Date? = if let epoch = UsageAPIParser.number(w["resets_at"]) {
            Date(timeIntervalSince1970: epoch)
        } else if let lead = UsageAPIParser.number(w["resets_in_seconds"]) {
            at.addingTimeInterval(lead)
        } else {
            nil
        }

        let (kind, group, title): (String, LimitGroup, String)
        switch minutes {
        case let m? where m <= 6 * 60:
            (kind, group, title) = ("session", .session, m == 300 ? "Session (5-hour)" : "Session (\(hours(m)))")
        case let m? where m >= 6 * 24 * 60:
            (kind, group, title) = ("weekly", .weekly, "Weekly")
        case let m?:
            (kind, group, title) = ("window-\(Int(m))", .other, "\(hours(m)) window")
        case nil:
            return nil
        }
        return UsageLimit(kind: kindPrefix + kind, group: group, title: title,
                          percent: min(100, max(0, used)), resetsAt: resetsAt,
                          observedAt: at, provider: .codex)
    }

    static func hours(_ minutes: Double) -> String {
        let h = minutes / 60
        return h == h.rounded() ? "\(Int(h))-hour" : "\(Int(minutes))-minute"
    }

    // "plus" → "Plus", "pro" → "Pro"; anything unfamiliar is shown as written.
    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "unknown" else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    // Where Codex keeps its sessions: $CODEX_HOME, else ~/.codex.
    static func home(environment: [String: String], userHome: URL) -> URL {
        if let dir = environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return userHome.appendingPathComponent(".codex", isDirectory: true)
    }

    // The newest rollout files under sessions/YYYY/MM/DD, newest day first.
    // Only walks as many day folders as it takes to find `limit` files.
    static func recentLogs(sessionsDir: URL, limit: Int = 6, fm: FileManager = .default) -> [URL] {
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var found: [URL] = []
        for year in children(sessionsDir) {
            for month in children(year) {
                for day in children(month) {
                    found += children(day).filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
                    if found.count >= limit { return Array(found.prefix(limit)) }
                }
            }
        }
        return found
    }
}
