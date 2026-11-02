// Projection.swift
// AI Usage Viewer
//
// Answers "will I run out before this window resets?" Raw percentage
// alone can't: 48% with 4h left is fine if it took 4 hours to get there,
// and not fine if it took 40 minutes.

import Foundation

nonisolated struct Projection: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case onPace
        case atRisk(hitAt: Date)
        case limited
        case unknown
    }

    var status:   Status
    var severity: Severity
    // Where usage would be now if spread evenly across the window (the pace
    // marker on the bar). Nil when the window length or reset is unknown.
    var expectedPercent: Double?

    var hitAt: Date? {
        if case .atRisk(let d) = status { return d }
        return nil
    }
}

nonisolated enum Projector {
    static let criticalLeadTime: TimeInterval = 30 * 60
    static let warningLeadFraction = 0.4
    static let highUsageWarning: Double = 90
    static let minimumRateSpan: TimeInterval = 5 * 60
    static let minimumElapsed: TimeInterval = 10 * 60

    static func project(_ limit: UsageLimit, samples: [UsageSample], now: Date) -> Projection {
        let floor = max(limit.serverSeverity, limit.percent >= highUsageWarning ? .warning : .normal)

        if limit.percent >= 100 {
            return Projection(status: .limited, severity: .critical, expectedPercent: expected(limit, now))
        }
        guard let resetsAt = limit.resetsAt, let length = limit.group.windowLength else {
            return Projection(status: .unknown, severity: floor, expectedPercent: nil)
        }

        let elapsed = min(max(0, now.timeIntervalSince(resetsAt) + length), length)
        guard let rate = burnRate(limit, samples: samples, now: now, elapsed: elapsed, length: length) else {
            return Projection(status: .unknown, severity: floor, expectedPercent: expected(limit, now))
        }
        guard rate > 0 else {
            return Projection(status: .onPace, severity: floor, expectedPercent: expected(limit, now))
        }

        let hitAt = now.addingTimeInterval((100 - limit.percent) / rate)
        guard hitAt < resetsAt else {
            return Projection(status: .onPace, severity: floor, expectedPercent: expected(limit, now))
        }
        // A limit projected days away is worth a line in the popover, not an
        // amber menu bar; escalate only once it's within 40% of the window.
        let lead = hitAt.timeIntervalSince(now)
        let projected: Severity = lead <= criticalLeadTime ? .critical
            : lead <= length * warningLeadFraction ? .warning : .normal
        return Projection(status: .atRisk(hitAt: hitAt), severity: max(floor, projected),
                          expectedPercent: expected(limit, now))
    }

    static func expected(_ limit: UsageLimit, _ now: Date) -> Double? {
        guard let resetsAt = limit.resetsAt, let length = limit.group.windowLength else { return nil }
        let elapsed = min(max(0, now.timeIntervalSince(resetsAt) + length), length)
        return elapsed / length * 100
    }

    // Percent per second. Prefers the slope over a recent lookback (what
    // you're doing now; drops to zero when you stop), falling back to the
    // average since the window opened.
    static func burnRate(_ limit: UsageLimit, samples: [UsageSample], now: Date,
                         elapsed: TimeInterval, length: TimeInterval) -> Double? {
        let lookback = max(30 * 60, length * 0.1)
        var recent = samples.filter { $0.date <= now && now.timeIntervalSince($0.date) <= lookback }
        if let last = recent.last, limit.observedAt > last.date {
            recent.append(UsageSample(date: limit.observedAt, percent: limit.percent, windowKey: last.windowKey))
        }
        if let first = recent.first, let last = recent.last,
           last.date.timeIntervalSince(first.date) >= minimumRateSpan {
            return max(0, (last.percent - first.percent) / last.date.timeIntervalSince(first.date))
        }
        guard elapsed >= minimumElapsed else { return nil }
        return limit.percent / elapsed
    }
}
