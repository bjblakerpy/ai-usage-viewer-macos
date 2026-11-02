// HTTPParsing.swift
// AI Usage Viewer

import Foundation

nonisolated enum HTTPParsing {
    // The API returns microsecond timestamps ("2026-10-17T03:20:00.437869+00:00").
    static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // Retry-After can be either an integer (seconds) or an HTTP-date.
    static func retryAfter(_ raw: String?, now: Date) -> Date? {
        guard let val = raw?.trimmingCharacters(in: .whitespaces), !val.isEmpty else { return nil }
        if let secs = TimeInterval(val) {
            return now.addingTimeInterval(max(0, secs))
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: val)
    }
}
