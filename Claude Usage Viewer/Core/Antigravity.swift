// Antigravity.swift
// Claude Usage Viewer
//
// Gemini usage comes from Google Antigravity, the only Gemini tool here
// that reports quota. Its local language server answers GetUserStatus
// with a per-model `quotaInfo { remainingFraction, resetTime }`. It is an
// undocumented local API, reachable only while Antigravity is running, so
// parsing is lenient and the app falls back to the last reading.
//
// Two quirks shape the parser:
// * It's protobuf JSON, which omits zero values: an exhausted model has a
//   resetTime but no remainingFraction. Missing means 0 left.
// * An unused model's resetTime sits a full window ahead (now + 5h or
//   now + 7d), which is how we tell weekly quotas from 5-hour ones.

import Foundation

nonisolated struct AntigravitySnapshot: Codable, Equatable, Sendable {
    var limits:    [UsageLimit]
    var planName:  String?
    var fetchedAt: Date
}

nonisolated enum AntigravityParser {
    static let kindPrefix = "antigravity:"
    // A lead longer than this can only be a weekly window.
    static let weeklyThreshold: TimeInterval = 5.5 * 3600

    static func parse(_ data: Data, now: Date, previous: [UsageLimit]) throws -> AntigravitySnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.decoding
        }
        let status = root["userStatus"] as? [String: Any] ?? root
        let configs = (status["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? []

        // Variants of one model ("(Low)", "(High)") are folded into a family;
        // the family shows its most-used variant.
        var families: [String: (title: String, remaining: Double, resetsAt: Date, order: Int)] = [:]
        for (i, config) in configs.enumerated() {
            guard let label = config["label"] as? String,
                  let quota = config["quotaInfo"] as? [String: Any],
                  let resetsAt = (quota["resetTime"] as? String).flatMap(HTTPParsing.isoDate) else { continue }
            let remaining = min(1, max(0, UsageAPIParser.number(quota["remainingFraction"]) ?? 0))
            let family = familyName(label)
            let kind = kindPrefix + slug(family)
            // Say where non-Gemini models live so they aren't mistaken for your Claude plan.
            let title = family.hasPrefix("Gemini") ? family : "\(family) in Antigravity"
            if let existing = families[kind], existing.remaining <= remaining { continue }
            families[kind] = (title, remaining, resetsAt, families[kind]?.order ?? i)
        }

        let limits = families.sorted { $0.value.order < $1.value.order }.map { kind, f in
            UsageLimit(
                kind:       kind,
                group:      group(kind: kind, resetsAt: f.resetsAt, now: now, previous: previous),
                title:      f.title,
                percent:    ((1 - f.remaining) * 1000).rounded() / 10,
                resetsAt:   f.resetsAt,
                observedAt: now,
                provider:   .antigravity
            )
        }
        guard !limits.isEmpty else { throw UsageError.decoding }
        return AntigravitySnapshot(limits: limits, planName: planName(status), fetchedAt: now)
    }

    static func group(kind: String, resetsAt: Date, now: Date, previous: [UsageLimit]) -> LimitGroup {
        if resetsAt.timeIntervalSince(now) > weeklyThreshold { return .weekly }
        // Inside its last few hours a weekly window looks like a 5-hour one;
        // keep what we learned when its reset was further away.
        return previous.first { $0.kind == kind }?.group ?? .session
    }

    // "Gemini 3.8 Flash (High)" → "Gemini 3.8 Flash"
    static func familyName(_ label: String) -> String {
        label.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
    }

    static func slug(_ s: String) -> String {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
    }

    static func planName(_ status: [String: Any]) -> String? {
        if let tier = status["userTier"] as? [String: Any], let name = tier["name"] as? String, !name.isEmpty {
            return name
        }
        return ((status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
    }

    // Gemini models are what this feature is for; Antigravity's other
    // models (Claude, GPT-OSS) draw on Antigravity quota, not your Claude
    // plan, so they're only worth a row once you've actually used them.
    static func isShown(_ limit: UsageLimit) -> Bool {
        limit.title.hasPrefix("Gemini") || limit.percent > 0
    }
}

// Finding the running language server and how to talk to it.
nonisolated enum AntigravityDiscovery {
    struct Server: Equatable, Sendable {
        var pid:  Int32
        var csrf: String
    }

    // From `ps -axo pid=,args=`.
    static func server(fromPS output: String) -> Server? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("Antigravity.app/"), trimmed.contains("/language_server") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let pid = parts.first.flatMap({ Int32($0) }), let csrf = flag("--csrf_token", in: parts) else { continue }
            return Server(pid: pid, csrf: csrf)
        }
        return nil
    }

    static func flag(_ name: String, in parts: [String]) -> String? {
        for (i, p) in parts.enumerated() {
            if p.hasPrefix(name + "=") { return String(p.dropFirst(name.count + 1)) }
            if p == name, i + 1 < parts.count { return parts[i + 1] }
        }
        return nil
    }

    // From `lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN -Fn`: lines like "n127.0.0.1:50543".
    static func loopbackPorts(fromLsof output: String) -> [Int] {
        var ports: [Int] = []
        for line in output.split(separator: "\n") where line.hasPrefix("n127.0.0.1:") || line.hasPrefix("n[::1]:") {
            if let port = line.split(separator: ":").last.flatMap({ Int($0) }), !ports.contains(port) {
                ports.append(port)
            }
        }
        return ports
    }
}
