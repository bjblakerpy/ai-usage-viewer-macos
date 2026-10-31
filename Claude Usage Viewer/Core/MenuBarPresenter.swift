// MenuBarPresenter.swift
// Claude Usage Viewer
//
// What the menu bar shows. Kept separate from the AppKit drawing so the
// choice of limit and wording can be tested.

import Foundation

nonisolated enum MenuBarMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto, session, weekly, both
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:    "Most urgent limit (Claude or Gemini)"
        case .session: "Claude session (5-hour)"
        case .weekly:  "Claude weekly"
        case .both:    "Claude session and weekly"
        }
    }
}

nonisolated struct MenuBarPresentation: Equatable, Sendable {
    var sessionFraction: Double?
    var weeklyFraction:  Double?
    var text:            String
    var caption:         String?
    // Colours the percentage and caption; normal leaves them in the menu bar's own colour.
    var severity:        Severity
    var isStale:         Bool
    var tooltip:         String
    // Whose limit is shown: picks the bars icon (Claude) or sparkle (Gemini).
    var provider:        Provider = .claude
}

nonisolated enum MenuBarPresenter {
    // `staleProviders`: providers whose numbers are old enough to distrust;
    // the item dims when the limit it shows comes from one of them.
    static func present(limits: [UsageLimit], projections: [String: Projection], mode: MenuBarMode,
                        staleProviders: Set<Provider>, now: Date, fmt: TimeFormatting) -> MenuBarPresentation {
        let session = limits.first { $0.kind == UsageLimit.sessionKind }
        let weekly  = limits.first { $0.kind == UsageLimit.weeklyAllKind }
        let staleNote = staleProviders.isEmpty ? ""
            : "\n" + staleProviders.map(\.displayName).sorted().joined(separator: ", ") + " data may be out of date."
        let tooltip = limits.map { line($0, projections[$0.kind], now: now, fmt: fmt) }
            .joined(separator: "\n") + staleNote

        var p = MenuBarPresentation(
            sessionFraction: session.map { min(1, $0.percent / 100) },
            weeklyFraction:  weekly.map { min(1, $0.percent / 100) },
            text: "—", caption: nil, severity: .normal, isStale: staleProviders.contains(.claude),
            tooltip: tooltip.isEmpty ? "Usage: no data yet" : tooltip
        )

        if mode == .both {
            let shown = [session, weekly].compactMap { $0 }
            guard !shown.isEmpty else { return p }
            p.text = shown.map { TimeFormatting.percent($0.percent) }.joined(separator: " · ")
            if let urgent = mostUrgent(shown, projections) {
                p.severity = projections[urgent.kind]?.severity ?? .normal
                if p.severity > .normal { p.caption = alertCaption(urgent, projections[urgent.kind], now: now) }
            }
            return p
        }

        let chosen: UsageLimit? = switch mode {
        case .session: session
        case .weekly:  weekly
        default:       mostUrgent(limits, projections)
        }
        guard let chosen else { return p }
        let projection = projections[chosen.kind]
        p.provider = chosen.provider
        p.isStale = staleProviders.contains(chosen.provider)
        p.text = TimeFormatting.percent(chosen.percent)
        p.severity = projection?.severity ?? .normal
        p.caption = alertCaption(chosen, projection, now: now) ?? (chosen.shortLabel.isEmpty ? nil : chosen.shortLabel)
        return p
    }

    // Highest severity first; then earliest projected limit; then highest percentage.
    static func mostUrgent(_ limits: [UsageLimit], _ projections: [String: Projection]) -> UsageLimit? {
        limits.max { a, b in
            let pa = projections[a.kind], pb = projections[b.kind]
            let sa = pa?.severity ?? .normal, sb = pb?.severity ?? .normal
            if sa != sb { return sa < sb }
            switch (pa?.hitAt, pb?.hitAt) {
            case let (ha?, hb?): return ha > hb
            case (nil, _?):      return true
            case (_?, nil):      return false
            default:             return a.percent < b.percent
            }
        }
    }

    // "~45m" until the projected limit, or "↻3h37m" until a hit limit resets.
    static func alertCaption(_ limit: UsageLimit, _ p: Projection?, now: Date) -> String? {
        guard let p, p.severity > .normal else { return nil }
        switch p.status {
        case .limited:
            return limit.resetsAt.map { "↻" + TimeFormatting.duration($0.timeIntervalSince(now), compact: true) }
        case .atRisk(let hit):
            return "~" + TimeFormatting.duration(hit.timeIntervalSince(now), compact: true)
        default:
            return nil
        }
    }

    static func line(_ limit: UsageLimit, _ p: Projection?, now: Date, fmt: TimeFormatting) -> String {
        var parts = ["\(limit.title): \(TimeFormatting.percent(limit.percent))"]
        if let p {
            let d = Describe.projection(p, now: now, fmt: fmt)
            if !d.isEmpty { parts.append(d.lowercased().hasPrefix("on pace") ? "on pace" : d) }
        }
        if let r = limit.resetsAt { parts.append("resets \(fmt.clock(r, now: now))") }
        return parts.joined(separator: " · ")
    }
}
