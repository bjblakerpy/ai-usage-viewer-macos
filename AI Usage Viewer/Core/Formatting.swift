// Formatting.swift
// AI Usage Viewer

import Foundation

nonisolated struct TimeFormatting: Sendable {
    var locale:   Locale   = .current
    var timeZone: TimeZone = .current

    // "<1m", "45m", "4h 18m", "6d 12h". `compact` drops the space for the menu bar.
    static func duration(_ seconds: TimeInterval, compact: Bool = false) -> String {
        let total = Int(max(0, seconds) / 60)
        let sep = compact ? "" : " "
        if total < 1 { return "<1m" }
        let d = total / 1440, h = (total % 1440) / 60, m = total % 60
        if d > 0 { return h > 0 ? "\(d)d\(sep)\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(sep)\(m)m" : "\(h)h" }
        return "\(m)m"
    }

    // "8:28 PM" today, "Thu 7:00 AM" within the week, "Oct 23" beyond.
    func clock(_ date: Date, now: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        if cal.isDate(date, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("jmm")
        } else if abs(date.timeIntervalSince(now)) < 6.5 * 86400 {
            f.setLocalizedDateFormatFromTemplate("EEEjmm")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return f.string(from: date)
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}

nonisolated enum Describe {
    // One-line projection, e.g. "Limit in ~45m · 8:28 PM" or "On pace".
    static func projection(_ p: Projection, now: Date, fmt: TimeFormatting) -> String {
        switch p.status {
        case .limited:          return "Limit reached"
        case .atRisk(let hit):  return "Limit in ~\(TimeFormatting.duration(hit.timeIntervalSince(now))) · \(fmt.clock(hit, now: now))"
        case .onPace:           return "On pace"
        case .unknown:          return ""
        }
    }

    static func reset(_ limit: UsageLimit, now: Date, fmt: TimeFormatting) -> String {
        guard let r = limit.resetsAt else { return "Window reset" }
        return "Resets in \(TimeFormatting.duration(r.timeIntervalSince(now))) · \(fmt.clock(r, now: now))"
    }
}
