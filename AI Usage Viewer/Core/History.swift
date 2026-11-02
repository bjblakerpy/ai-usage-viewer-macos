// History.swift
// AI Usage Viewer
//
// Local samples of each limit's percentage, used for the sparklines and to
// measure the recent burn rate. Kept for 8 days (one weekly window plus a
// day of slack).

import Foundation

nonisolated struct UsageSample: Codable, Equatable, Sendable {
    var date:      Date
    var percent:   Double
    var windowKey: Int
}

nonisolated struct UsageHistory: Codable, Equatable, Sendable {
    static let retention: TimeInterval = 8 * 86400
    static let maxSamplesPerKind = 5000
    static let heartbeat: TimeInterval = 5 * 60

    var samples: [String: [UsageSample]] = [:]

    // Records each limit's current value. Skips unchanged values unless the
    // last sample is older than `heartbeat`, so idle periods still draw a
    // flat line instead of a long interpolated slope. Returns true if
    // anything was added.
    @discardableResult
    mutating func record(_ limits: [UsageLimit]) -> Bool {
        var changed = false
        for limit in limits {
            guard let key = limit.windowKey else { continue }
            var list = samples[limit.kind] ?? []
            if let last = list.last {
                guard limit.observedAt > last.date else { continue }
                let same = last.windowKey == key && abs(last.percent - limit.percent) < 0.5
                if same && limit.observedAt.timeIntervalSince(last.date) < Self.heartbeat { continue }
            }
            list.append(UsageSample(date: limit.observedAt, percent: limit.percent, windowKey: key))
            if list.count > Self.maxSamplesPerKind { list.removeFirst(list.count - Self.maxSamplesPerKind) }
            samples[limit.kind] = list
            changed = true
        }
        return changed
    }

    // Samples for the limit's current window only, oldest first.
    func samples(for limit: UsageLimit) -> [UsageSample] {
        guard let key = limit.windowKey else { return [] }
        return (samples[limit.kind] ?? []).filter { $0.windowKey == key }
    }

    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        for (kind, list) in samples {
            let kept = list.filter { $0.date >= cutoff }
            samples[kind] = kept.isEmpty ? nil : kept
        }
    }
}
