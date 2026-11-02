// StatusLineFeed.swift
// AI Usage Viewer
//
// Claude Code passes `rate_limits` to status-line scripts on every update:
//   { "five_hour": { "used_percentage": 65, "resets_at": 1792206000 },
//     "seven_day": { "used_percentage": 11, "resets_at": 1792753200 } }
// (resets_at is Unix epoch seconds). Our status-line script saves that
// object to a file; this parses it. Accepts either the bare object or a
// full status-line payload that contains it.

import Foundation

nonisolated enum StatusLineFeed {
    static func parse(_ data: Data, observedAt: Date, now: Date) -> [UsageLimit] {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        if let nested = root["rate_limits"] as? [String: Any] { root = nested }

        let windows: [(key: String, kind: String)] = [
            ("five_hour", UsageLimit.sessionKind),
            ("seven_day", UsageLimit.weeklyAllKind),
        ]
        return windows.compactMap { key, kind in
            guard let w = root[key] as? [String: Any],
                  let pct = UsageAPIParser.number(w["used_percentage"]),
                  let epoch = UsageAPIParser.number(w["resets_at"]) else { return nil }
            let resetsAt = Date(timeIntervalSince1970: epoch)
            guard resetsAt > now else { return nil }
            return UsageLimit(
                kind:       kind,
                group:      UsageLimit.group(kind: kind, serverGroup: nil),
                title:      UsageLimit.title(kind: kind, scope: nil),
                percent:    pct,
                resetsAt:   resetsAt,
                observedAt: observedAt
            )
        }
    }
}
