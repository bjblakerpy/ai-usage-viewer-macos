// FetchScheduler.swift
// AI Usage Viewer
//
// Decides when to call the usage API. Its rate limit (~3 calls per 5 min)
// is shared with every Claude Code session, Claude Desktop and the VS Code
// usage meter on the same login, so we call as rarely as possible: every
// 15 minutes, or every 30 while the Claude Code status-line feed is
// already delivering fresh numbers for free.

import Foundation

nonisolated struct FetchState: Equatable, Sendable {
    var lastSuccess:         Date?
    var lastAttempt:         Date?
    var consecutiveFailures: Int = 0
    // Retry-After deadline plus jitter, fixed when the 429 arrives.
    var cooldownUntil:       Date?
    var feedUpdatedAt:       Date?
}

nonisolated enum FetchScheduler {
    static let normalInterval:     TimeInterval = 15 * 60
    static let feedActiveInterval: TimeInterval = 30 * 60
    static let feedFreshness:      TimeInterval = 10 * 60
    static let nudgeStaleness:     TimeInterval = 5 * 60
    static let maxBackoff:         TimeInterval = 15 * 60
    static let jitterRange:        ClosedRange<TimeInterval> = 5...45

    static func nextFetch(_ s: FetchState, now: Date) -> Date {
        if let c = s.cooldownUntil, c > now { return c }
        if s.consecutiveFailures > 0, let attempt = s.lastAttempt {
            let backoff = min(maxBackoff, 60 * pow(2, Double(s.consecutiveFailures - 1)))
            return attempt.addingTimeInterval(backoff)
        }
        guard let last = s.lastSuccess else { return now }
        return last.addingTimeInterval(isFeedActive(s, now: now) ? feedActiveInterval : normalInterval)
    }

    static func isFeedActive(_ s: FetchState, now: Date) -> Bool {
        guard let f = s.feedUpdatedAt else { return false }
        return now.timeIntervalSince(f) < feedFreshness
    }

    static func inCooldown(_ s: FetchState, now: Date) -> Bool {
        (s.cooldownUntil ?? .distantPast) > now
    }

    // Wake, unlock, network restored or popover opened: fetch only if the
    // freshest data we have (API or feed) is more than 5 minutes old.
    static func shouldFetchOnNudge(_ s: FetchState, now: Date) -> Bool {
        if inCooldown(s, now: now) { return false }
        let freshest = [s.lastSuccess, s.feedUpdatedAt].compactMap { $0 }.max()
        guard let freshest else { return true }
        return now.timeIntervalSince(freshest) > nudgeStaleness
    }
}
