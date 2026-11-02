// APIParser.swift
// AI Usage Viewer
//
// Parses https://api.anthropic.com/api/oauth/usage. The endpoint is
// undocumented and grows new fields often, so parsing is deliberately
// lenient: walk a JSON dictionary and skip anything that doesn't fit,
// rather than failing the whole response on one unexpected value.

import Foundation

nonisolated enum UsageAPIParser {
    static func parse(_ data: Data, now: Date) throws -> UsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.decoding
        }

        // Prefer the generic `limits` list; fall back to the older
        // five_hour / seven_day / seven_day_<model> objects.
        var limits = (root["limits"] as? [[String: Any]])?
            .compactMap { limit(from: $0, now: now) } ?? []
        if limits.isEmpty { limits = legacyLimits(root, now: now) }
        guard !limits.isEmpty else { throw UsageError.decoding }

        return UsageSnapshot(
            limits:          limits,
            extraUsage:      extraUsage(root),
            weeklyBreakdown: breakdown(root),
            fetchedAt:       now
        )
    }

    private static func limit(from d: [String: Any], now: Date) -> UsageLimit? {
        guard let kind = d["kind"] as? String, let percent = number(d["percent"]) else { return nil }
        let scope = d["scope"] as? String
        return UsageLimit(
            kind:           kind,
            group:          UsageLimit.group(kind: kind, serverGroup: d["group"] as? String),
            title:          UsageLimit.title(kind: kind, scope: scope),
            percent:        percent,
            resetsAt:       (d["resets_at"] as? String).flatMap(HTTPParsing.isoDate),
            serverSeverity: Severity(serverValue: d["severity"] as? String),
            observedAt:     now
        )
    }

    private static let legacyKeys: [(key: String, kind: String)] = [
        ("five_hour",        UsageLimit.sessionKind),
        ("seven_day",        UsageLimit.weeklyAllKind),
        ("seven_day_opus",   "weekly_opus"),
        ("seven_day_sonnet", "weekly_sonnet"),
    ]

    private static func legacyLimits(_ root: [String: Any], now: Date) -> [UsageLimit] {
        legacyKeys.compactMap { key, kind in
            guard let w = root[key] as? [String: Any], let pct = number(w["utilization"]) else { return nil }
            return UsageLimit(
                kind:       kind,
                group:      UsageLimit.group(kind: kind, serverGroup: nil),
                title:      UsageLimit.title(kind: kind, scope: nil),
                percent:    pct,
                resetsAt:   (w["resets_at"] as? String).flatMap(HTTPParsing.isoDate),
                observedAt: now
            )
        }
    }

    private static func extraUsage(_ root: [String: Any]) -> ExtraUsage? {
        if let spend = root["spend"] as? [String: Any] {
            guard spend["enabled"] as? Bool == true,
                  let used = money(spend["used"]) else { return nil }
            return ExtraUsage(used: used, limit: money(spend["limit"]))
        }
        if let extra = root["extra_usage"] as? [String: Any] {
            guard extra["is_enabled"] as? Bool == true else { return nil }
            let exp = Int(number(extra["decimal_places"]) ?? 2)
            let cur = extra["currency"] as? String ?? "USD"
            let used = Money(minorUnits: Int(number(extra["used_credits"]) ?? 0), exponent: exp, currency: cur)
            let limit = number(extra["monthly_limit"]).map {
                Money(minorUnits: Int($0), exponent: exp, currency: cur)
            }
            return ExtraUsage(used: used, limit: limit)
        }
        return nil
    }

    private static func money(_ any: Any?) -> Money? {
        guard let d = any as? [String: Any], let minor = number(d["amount_minor"]) else { return nil }
        return Money(
            minorUnits: Int(minor),
            exponent:   Int(number(d["exponent"]) ?? 2),
            currency:   d["currency"] as? String ?? "USD"
        )
    }

    private static func breakdown(_ root: [String: Any]) -> [BreakdownRow] {
        guard let b = root["seven_day_breakdown"] as? [String: Any],
              let rows = b["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let key = r["key"] as? String, let pct = number(r["percent"]), pct > 0 else { return nil }
            return BreakdownRow(key: key, name: r["display_name"] as? String ?? key, percent: pct)
        }
    }

    static func number(_ any: Any?) -> Double? {
        // JSONSerialization yields NSNumber; Bool also bridges to NSNumber, so exclude it.
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}
