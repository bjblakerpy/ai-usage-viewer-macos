// Alerts.swift
// AI Usage Viewer
//
// Decides which notifications to send. Pure: takes the current limits and
// what has already fired, returns actions for the Notifier to perform.
// Each alert fires at most once per window (ids include the window key).

import Foundation

nonisolated struct AlertSettings: Equatable, Sendable {
    var projection: Bool = true
    var thresholds: Bool = true
    var thresholdValues: [Int] = [80, 95]
    var resets: Bool = true
    var projectionLeadTime: TimeInterval = 60 * 60
    // A reset is only worth announcing if you were close to the limit.
    var resetAlertMinimumPercent: Double = 80
}

nonisolated enum AlertAction: Equatable, Sendable {
    case deliver(id: String, title: String, body: String)
    case schedule(id: String, at: Date, title: String, body: String)
    case markFired(id: String)

    var id: String {
        switch self {
        case .deliver(let id, _, _), .schedule(let id, _, _, _), .markFired(let id): id
        }
    }
}

nonisolated enum AlertPlanner {
    static func plan(limits: [UsageLimit], projections: [String: Projection], settings: AlertSettings,
                     fired: Set<String>, now: Date, fmt: TimeFormatting) -> [AlertAction] {
        var actions: [AlertAction] = []
        for limit in limits {
            guard let resetsAt = limit.resetsAt, let key = limit.windowKey else { continue }
            let window = "\(limit.kind)@\(key)"
            let name = limit.fullTitle
            let resetText = "Resets \(fmt.clock(resetsAt, now: now)) (in \(TimeFormatting.duration(resetsAt.timeIntervalSince(now))))."
            let projection = projections[limit.kind]

            if limit.percent >= 100 {
                let id = "limited|\(window)"
                if !fired.contains(id) {
                    actions.append(.deliver(id: id, title: "\(name) limit reached", body: resetText))
                }
            } else {
                if settings.thresholds {
                    let crossed = settings.thresholdValues.sorted().filter { Double($0) <= limit.percent }
                    if let top = crossed.last, !fired.contains("threshold\(top)|\(window)") {
                        actions.append(.deliver(id: "threshold\(top)|\(window)",
                                                title: "\(name) at \(TimeFormatting.percent(limit.percent))",
                                                body: resetText))
                        // Jumping straight past several thresholds sends one alert, not a burst.
                        for t in crossed.dropLast() where !fired.contains("threshold\(t)|\(window)") {
                            actions.append(.markFired(id: "threshold\(t)|\(window)"))
                        }
                    }
                }
                if settings.projection, let hit = projection?.hitAt,
                   hit.timeIntervalSince(now) <= settings.projectionLeadTime {
                    let id = "pace|\(window)"
                    if !fired.contains(id) {
                        let lead = TimeFormatting.duration(resetsAt.timeIntervalSince(hit))
                        actions.append(.deliver(
                            id: id,
                            title: "\(name): limit in ~\(TimeFormatting.duration(hit.timeIntervalSince(now)))",
                            body: "At this pace you'll hit the limit around \(fmt.clock(hit, now: now)), \(lead) before it resets."
                        ))
                    }
                }
            }

            if settings.resets, limit.percent >= settings.resetAlertMinimumPercent {
                let id = "reset|\(window)"
                if !fired.contains(id) {
                    actions.append(.schedule(id: id, at: resetsAt,
                                             title: "\(name) limit has reset",
                                             body: "You're back to full capacity."))
                }
            }
        }
        return actions
    }

    // Drop ids for windows that ended more than a day ago.
    static func prune(_ fired: Set<String>, now: Date) -> Set<String> {
        let nowMinutes = Int(now.timeIntervalSince1970 / 60)
        return fired.filter { id in
            guard let at = id.split(separator: "@").last, let minutes = Int(at) else { return false }
            return minutes > nowMinutes - 1440
        }
    }
}
