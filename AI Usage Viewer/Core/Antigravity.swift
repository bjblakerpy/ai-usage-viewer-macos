// Antigravity.swift
// AI Usage Viewer
//
// Google usage comes from Antigravity, the only Gemini tool here that
// reports quota. It reports quota per model (Gemini, plus Claude and
// GPT-OSS on Antigravity's own quota); the app keeps every model and shows
// a session and a weekly row, like Claude and Codex (see summarize). Its local language server answers GetUserStatus
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
            let title = family
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

    // One session row and one weekly row, each the most-used model in that
    // window, named after a "·" so it's clear whose number it is. Models
    // are kept underneath because their reset times are how windows are told
    // apart (see group).
    static func summarize(_ models: [UsageLimit]) -> [UsageLimit] {
        [(LimitGroup.session, "session", "Session (5-hour)"), (.weekly, "weekly", "Weekly")].compactMap { group, key, title in
            guard var top = models.filter({ $0.group == group }).max(by: { $0.percent < $1.percent }) else { return nil }
            if top.percent > 0 { top.title = "\(title) · \(top.title)" } else { top.title = title }
            top.kind = kindPrefix + key
            return top
        }
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
}

// Finding the running language server and how to talk to it.
//
// Antigravity 2.34 (Nov 2026) stopped passing the CSRF token on the
// server's command line. Instead, while it runs it writes a discovery file
// for local clients, ~/.gemini/antigravity/daemon/hub_<port>.json:
//   {"pid":…, "httpsPort":…, "httpPort":…, "lsVersion":"2.34.0", "csrfToken":"…"}
// That file is tried first; the command-line flags still cover older versions.
nonisolated enum AntigravityDiscovery {
    struct Server: Equatable, Sendable {
        var pid:   Int32
        var csrf:  String
        // From the discovery file; empty means "ask lsof".
        var ports: [Int] = []
    }

    static func server(fromDiscoveryFile data: Data) -> Server? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0,
              let csrf = o["csrfToken"] as? String, isPlausibleToken(csrf) else { return nil }
        let ports = ["httpPort", "httpsPort"].compactMap { (o[$0] as? NSNumber)?.intValue }
            .filter { (1...65535).contains($0) }
        return ports.isEmpty ? nil : Server(pid: pid, csrf: csrf, ports: ports)
    }

    // The token goes into a request header, so accept only what a token
    // looks like (Antigravity's are UUIDs).
    static func isPlausibleToken(_ s: String) -> Bool {
        (8...256).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // PIDs of running Antigravity language servers, from `ps -axo pid=,args=`.
    static func languageServerPIDs(fromPS output: String) -> Set<Int32> {
        Set(output.split(separator: "\n").compactMap { line -> Int32? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("Antigravity.app/"), trimmed.contains("/language_server") else { return nil }
            return trimmed.split(separator: " ").first.flatMap { Int32($0) }
        })
    }

    // Older versions: the token is a command-line flag. From `ps -axo pid=,args=`.
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
