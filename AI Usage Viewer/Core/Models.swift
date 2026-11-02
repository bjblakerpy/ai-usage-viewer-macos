// Models.swift
// AI Usage Viewer
//
// Pure value types shared by the app and the UsageCore test package.
// Everything in Core/ imports Foundation only and is `nonisolated`, so it
// compiles both in the MainActor-default app target and in SwiftPM.

import Foundation

nonisolated enum Severity: Int, Codable, Comparable, Sendable {
    case normal, warning, critical

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    // The API's `severity` vocabulary isn't documented. Map the words we can
    // reasonably interpret and treat anything else as normal; our own
    // projection is what drives warnings.
    init(serverValue: String?) {
        switch serverValue?.lowercased() {
        case "warning", "elevated", "high", "approaching": self = .warning
        case "critical", "exceeded", "limited", "blocked": self = .critical
        default:                                         self = .normal
        }
    }
}

nonisolated enum LimitGroup: String, Codable, Sendable {
    case session, weekly, other

    var windowLength: TimeInterval? {
        switch self {
        case .session: 5 * 3600
        case .weekly:  7 * 86400
        case .other:   nil
        }
    }
}

nonisolated enum Provider: String, Codable, Sendable {
    case claude, antigravity, codex

    var displayName: String {
        switch self {
        case .claude:      "Claude"
        case .antigravity: "Gemini · Antigravity"
        case .codex:       "OpenAI · Codex"
        }
    }
}

nonisolated struct UsageLimit: Codable, Equatable, Sendable, Identifiable {
    static let sessionKind = "session"
    static let weeklyAllKind = "weekly_all"

    var kind:           String   // "session", "weekly_all", "weekly_opus", …
    var group:          LimitGroup
    var title:          String
    var percent:        Double
    var resetsAt:       Date?
    var serverSeverity: Severity = .normal
    var observedAt:     Date
    var provider:       Provider = .claude

    var id: String { kind }

    // resets_at carries sub-second jitter between calls, so identify a
    // window by its reset time rounded to the minute.
    var windowKey: Int? {
        resetsAt.map { Int(($0.timeIntervalSince1970 / 60).rounded()) }
    }

    var windowStart: Date? {
        guard let resetsAt, let length = group.windowLength else { return nil }
        return resetsAt.addingTimeInterval(-length)
    }

    // The title with its service named, for places that mix services
    // (notifications, the menu-bar tooltip): "Claude session (5-hour)".
    // Antigravity titles already say what they are.
    var fullTitle: String {
        let name: String
        switch provider {
        case .claude:      name = "Claude"
        case .codex:       name = "Codex"
        case .antigravity: return title
        }
        return title.hasPrefix(name) ? title : "\(name) \(title.prefix(1).lowercased())\(title.dropFirst())"
    }

    var shortLabel: String {
        switch group {
        case .session: "5h"
        case .weekly:  "7d"
        case .other:   ""
        }
    }

    static func title(kind: String, scope: String?) -> String {
        if let scope, !scope.isEmpty { return "Weekly (\(scope))" }
        switch kind {
        case sessionKind:   return "Session (5-hour)"
        case weeklyAllKind: return "Weekly (all models)"
        default:
            let words = kind.split(separator: "_").map { $0.capitalized }
            if words.first == "Weekly", words.count > 1 {
                return "Weekly (\(words.dropFirst().joined(separator: " ")))"
            }
            return words.joined(separator: " ")
        }
    }

    static func group(kind: String, serverGroup: String?) -> LimitGroup {
        if let g = serverGroup.flatMap(LimitGroup.init(rawValue:)), g != .other { return g }
        if kind == sessionKind { return .session }
        if kind.hasPrefix("weekly") || kind.hasPrefix("seven_day") { return .weekly }
        return .other
    }
}

// Snapshots saved before `provider` existed must still decode (as Claude).
// Declared in an extension so the memberwise initializer survives.
nonisolated extension UsageLimit {
    private enum CodingKeys: String, CodingKey {
        case kind, group, title, percent, resetsAt, serverSeverity, observedAt, provider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind           = try c.decode(String.self, forKey: .kind)
        group          = try c.decode(LimitGroup.self, forKey: .group)
        title          = try c.decode(String.self, forKey: .title)
        percent        = try c.decode(Double.self, forKey: .percent)
        resetsAt       = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        serverSeverity = try c.decodeIfPresent(Severity.self, forKey: .serverSeverity) ?? .normal
        observedAt     = try c.decode(Date.self, forKey: .observedAt)
        provider       = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude
    }
}

nonisolated struct Money: Codable, Equatable, Sendable {
    var minorUnits: Int
    var exponent:   Int
    var currency:   String

    var amount: Double { Double(minorUnits) / pow(10, Double(exponent)) }

    var formatted: String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(exponent)))
    }
}

nonisolated struct ExtraUsage: Codable, Equatable, Sendable {
    var used:  Money
    var limit: Money?
}

nonisolated struct BreakdownRow: Codable, Equatable, Sendable, Identifiable {
    var key:     String
    var name:    String
    var percent: Double
    var id: String { key }
}

nonisolated struct UsageSnapshot: Codable, Equatable, Sendable {
    var limits:          [UsageLimit]
    var extraUsage:      ExtraUsage?
    var weeklyBreakdown: [BreakdownRow]
    var fetchedAt:       Date
}

nonisolated enum UsageError: LocalizedError, Equatable, Sendable {
    case noCredentials
    case loginExpired
    case loginRevoked
    case unauthorized
    case rateLimited(retryAt: Date)
    case network(String)
    case http(Int)
    case decoding

    var errorDescription: String? { message(now: Date()) }

    func message(now: Date) -> String {
        switch self {
        case .noCredentials:
            return "No Claude Code login found. Run `claude` and sign in."
        case .loginExpired:
            return "Claude Code's login has expired. It will be renewed automatically."
        case .loginRevoked:
            return "Claude Code's login can't be renewed. Run `claude` in a terminal and use /login."
        case .unauthorized:
            return "Anthropic rejected Claude Code's login. Run `claude` and use /login."
        case .rateLimited(let at):
            let mins = max(1, Int((at.timeIntervalSince(now) / 60).rounded(.up)))
            return "Anthropic is rate-limiting usage checks. Retrying in \(mins) min."
        case .network(let m):
            return "Can't reach Anthropic: \(m)"
        case .http(let code):
            return "Usage check failed (HTTP \(code))."
        case .decoding:
            return "Unexpected response from Anthropic."
        }
    }
}

nonisolated enum UsageMerger {
    // Combines the last API snapshot with the Claude Code status-line feed.
    // For each limit the newer observation wins. A window whose reset time
    // has passed is shown as reset (0%) rather than its stale percentage.
    static func merge(api: [UsageLimit], feed: [UsageLimit], now: Date) -> [UsageLimit] {
        var result = api
        for f in feed {
            if let i = result.firstIndex(where: { $0.kind == f.kind }) {
                guard f.observedAt > result[i].observedAt else { continue }
                if result[i].windowKey != f.windowKey { result[i].serverSeverity = .normal }
                result[i].percent    = f.percent
                result[i].resetsAt   = f.resetsAt
                result[i].observedAt = f.observedAt
            } else {
                result.append(f)
            }
        }
        for i in result.indices {
            if let r = result[i].resetsAt, r <= now {
                result[i].percent = 0
                result[i].resetsAt = nil
                result[i].serverSeverity = .normal
            }
        }
        let order = [UsageLimit.sessionKind, UsageLimit.weeklyAllKind]
        return result.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.kind) ?? order.count + a.offset
            let ib = order.firstIndex(of: b.element.kind) ?? order.count + b.offset
            return ia < ib
        }.map(\.element)
    }
}
