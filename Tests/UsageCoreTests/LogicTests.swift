import Foundation
import Testing
@testable import UsageCore

let t0 = Date(timeIntervalSince1970: 1_792_200_000)

func limit(_ kind: String = UsageLimit.sessionKind, percent: Double, resetsIn: TimeInterval?,
           now: Date = t0, observedAt: Date? = nil) -> UsageLimit {
    UsageLimit(kind: kind, group: UsageLimit.group(kind: kind, serverGroup: nil),
               title: UsageLimit.title(kind: kind, scope: nil), percent: percent,
               resetsAt: resetsIn.map { now.addingTimeInterval($0) }, observedAt: observedAt ?? now)
}

@Suite struct ProjectionTests {
    // The screenshot case: 48% used, 4h18m left in a 5h window (42m elapsed).
    @Test func fastBurnEarlyInWindowIsAtRisk() {
        let l = limit(percent: 48, resetsIn: 4 * 3600 + 18 * 60)
        let p = Projector.project(l, samples: [], now: t0)
        guard case .atRisk(let hit) = p.status else { Issue.record("expected atRisk, got \(p.status)"); return }
        #expect(abs(hit.timeIntervalSince(t0) - 45.5 * 60) < 60)   // ~45 min to go
        #expect(p.severity == .warning)
        #expect(abs(p.expectedPercent! - 14) < 0.1)                 // 42 of 300 minutes
    }

    @Test func slowWeeklyBurnIsOnPace() {
        let l = limit(UsageLimit.weeklyAllKind, percent: 6, resetsIn: 155 * 3600 + 58 * 60)
        let p = Projector.project(l, samples: [], now: t0)
        #expect(p.status == .onPace)
        #expect(p.severity == .normal)
    }

    // The screenshot's 8% after 12h does project past 100% — ~6 days out,
    // which is reported but must not turn the menu bar amber.
    @Test func distantProjectedLimitStaysNormal() {
        let l = limit(UsageLimit.weeklyAllKind, percent: 8, resetsIn: 155 * 3600 + 58 * 60)
        let p = Projector.project(l, samples: [], now: t0)
        #expect(p.hitAt != nil)
        #expect(p.severity == .normal)
        #expect(MenuBarPresenter.alertCaption(l, p, now: t0) == nil)
    }

    @Test func recentSlopeBeatsWindowAverage() {
        // 70% used early on, but nothing in the last 30 minutes: on pace.
        let l = limit(percent: 70, resetsIn: 3 * 3600)
        let key = l.windowKey!
        let samples = [
            UsageSample(date: t0.addingTimeInterval(-25 * 60), percent: 70, windowKey: key),
            UsageSample(date: t0.addingTimeInterval(-5 * 60), percent: 70, windowKey: key),
        ]
        #expect(Projector.project(l, samples: samples, now: t0).status == .onPace)
    }

    @Test func steepRecentSlopeIsCriticalWhenUnder30Minutes() {
        let l = limit(percent: 80, resetsIn: 3 * 3600)
        let key = l.windowKey!
        let samples = [UsageSample(date: t0.addingTimeInterval(-10 * 60), percent: 60, windowKey: key)]
        let p = Projector.project(l, samples: samples, now: t0)   // 2%/min → 10 min left
        #expect(p.severity == .critical)
        #expect(abs(p.hitAt!.timeIntervalSince(t0) - 600) < 1)
    }

    @Test func limitedAtOrAbove100() {
        let p = Projector.project(limit(percent: 100, resetsIn: 3600), samples: [], now: t0)
        #expect(p.status == .limited)
        #expect(p.severity == .critical)
    }

    @Test func highUsageIsAtLeastWarningEvenIdle() {
        let l = limit(percent: 92, resetsIn: 600)
        let key = l.windowKey!
        let samples = [UsageSample(date: t0.addingTimeInterval(-20 * 60), percent: 92, windowKey: key)]
        let p = Projector.project(l, samples: samples, now: t0)
        #expect(p.status == .onPace)
        #expect(p.severity == .warning)
    }

    @Test func tooEarlyToTellIsUnknown() {
        let p = Projector.project(limit(percent: 5, resetsIn: 5 * 3600 - 120), samples: [], now: t0)
        #expect(p.status == .unknown)
    }

    @Test func serverSeverityRaisesTheFloor() {
        var l = limit(UsageLimit.weeklyAllKind, percent: 8, resetsIn: 150 * 3600)
        l.serverSeverity = .warning
        #expect(Projector.project(l, samples: [], now: t0).severity == .warning)
    }
}

@Suite struct MergeTests {
    @Test func newerFeedOverridesAPIAndKeepsOtherLimits() {
        let api = [limit(percent: 20, resetsIn: 3600),
                   limit(UsageLimit.weeklyAllKind, percent: 5, resetsIn: 86400),
                   limit("weekly_opus", percent: 30, resetsIn: 86400)]
        let feed = [limit(percent: 35, resetsIn: 3600, observedAt: t0.addingTimeInterval(60))]
        let merged = UsageMerger.merge(api: api, feed: feed, now: t0)
        #expect(merged.map(\.percent) == [35, 5, 30])
    }

    @Test func olderFeedIsIgnored() {
        let api = [limit(percent: 20, resetsIn: 3600)]
        let feed = [limit(percent: 10, resetsIn: 3600, observedAt: t0.addingTimeInterval(-60))]
        #expect(UsageMerger.merge(api: api, feed: feed, now: t0)[0].percent == 20)
    }

    @Test func passedResetShowsAsReset() {
        let api = [limit(percent: 97, resetsIn: -60)]
        let merged = UsageMerger.merge(api: api, feed: [], now: t0)
        #expect(merged[0].percent == 0)
        #expect(merged[0].resetsAt == nil)
    }

    @Test func sessionAndWeeklyComeFirst() {
        let api = [limit("weekly_opus", percent: 1, resetsIn: 60),
                   limit(UsageLimit.weeklyAllKind, percent: 1, resetsIn: 60),
                   limit(percent: 1, resetsIn: 60)]
        #expect(UsageMerger.merge(api: api, feed: [], now: t0).map(\.kind) == ["session", "weekly_all", "weekly_opus"])
    }
}

@Suite struct HistoryTests {
    @Test func recordsChangesAndHeartbeatsOnly() {
        var h = UsageHistory()
        let r1 = h.record([limit(percent: 10, resetsIn: 3600, observedAt: t0)])
        let r2 = h.record([limit(percent: 10.2, resetsIn: 3600, observedAt: t0.addingTimeInterval(60))])
        let r3 = h.record([limit(percent: 12, resetsIn: 3600, observedAt: t0.addingTimeInterval(120))])
        let r4 = h.record([limit(percent: 12, resetsIn: 3600, observedAt: t0.addingTimeInterval(120 + 301))])
        let r5 = h.record([limit(percent: 50, resetsIn: 3600, observedAt: t0)])   // not newer
        #expect([r1, r2, r3, r4, r5] == [true, false, true, true, false])
        #expect(h.samples["session"]?.count == 3)
    }

    @Test func samplesAreScopedToCurrentWindow() {
        var h = UsageHistory()
        h.record([limit(percent: 90, resetsIn: 60, observedAt: t0)])
        let next = limit(percent: 3, resetsIn: 5 * 3600, observedAt: t0.addingTimeInterval(120))
        h.record([next])
        #expect(h.samples(for: next).map(\.percent) == [3])
    }

    @Test func pruneDropsOldSamples() {
        var h = UsageHistory()
        h.record([limit(percent: 1, resetsIn: 60, observedAt: t0)])
        h.prune(now: t0.addingTimeInterval(9 * 86400))
        #expect(h.samples.isEmpty)
    }
}

@Suite struct SchedulerTests {
    @Test func firstFetchIsImmediate() {
        #expect(FetchScheduler.nextFetch(FetchState(), now: t0) == t0)
    }

    @Test func normalAndFeedActiveIntervals() {
        var s = FetchState(lastSuccess: t0)
        #expect(FetchScheduler.nextFetch(s, now: t0) == t0.addingTimeInterval(15 * 60))
        s.feedUpdatedAt = t0
        #expect(FetchScheduler.nextFetch(s, now: t0.addingTimeInterval(60)) == t0.addingTimeInterval(30 * 60))
        // Feed went quiet: back to 15 minutes.
        #expect(FetchScheduler.nextFetch(s, now: t0.addingTimeInterval(11 * 60)) == t0.addingTimeInterval(15 * 60))
    }

    @Test func cooldownWins() {
        let s = FetchState(lastSuccess: t0, cooldownUntil: t0.addingTimeInterval(300))
        #expect(FetchScheduler.nextFetch(s, now: t0) == t0.addingTimeInterval(300))
        #expect(FetchScheduler.inCooldown(s, now: t0))
        #expect(!FetchScheduler.shouldFetchOnNudge(s, now: t0.addingTimeInterval(200)))
    }

    @Test func failuresBackOffExponentiallyToFifteenMinutes() {
        var s = FetchState(lastSuccess: t0, lastAttempt: t0, consecutiveFailures: 1)
        #expect(FetchScheduler.nextFetch(s, now: t0) == t0.addingTimeInterval(60))
        s.consecutiveFailures = 3
        #expect(FetchScheduler.nextFetch(s, now: t0) == t0.addingTimeInterval(240))
        s.consecutiveFailures = 10
        #expect(FetchScheduler.nextFetch(s, now: t0) == t0.addingTimeInterval(900))
    }

    @Test func nudgeOnlyWhenEverythingIsStale() {
        var s = FetchState(lastSuccess: t0.addingTimeInterval(-600))
        #expect(FetchScheduler.shouldFetchOnNudge(s, now: t0))
        s.feedUpdatedAt = t0.addingTimeInterval(-60)
        #expect(!FetchScheduler.shouldFetchOnNudge(s, now: t0))
        #expect(FetchScheduler.shouldFetchOnNudge(FetchState(), now: t0))
    }
}

@Suite struct FormattingTests {
    @Test func durations() {
        #expect(TimeFormatting.duration(20) == "<1m")
        #expect(TimeFormatting.duration(45 * 60) == "45m")
        #expect(TimeFormatting.duration(4 * 3600 + 18 * 60) == "4h 18m")
        #expect(TimeFormatting.duration(3 * 3600) == "3h")
        #expect(TimeFormatting.duration(155 * 3600 + 58 * 60) == "6d 11h")
        #expect(TimeFormatting.duration(3 * 3600 + 37 * 60, compact: true) == "3h37m")
    }

    @Test func clockTimes() {
        let fmt = TimeFormatting(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/New_York")!)
        let now = Date(timeIntervalSince1970: 1_792_195_200)   // Fri Oct 16 2026 20:00 EDT
        #expect(fmt.clock(now.addingTimeInterval(28 * 60), now: now) == "8:28\u{202F}PM")
        #expect(fmt.clock(now.addingTimeInterval(5 * 86400 + 11 * 3600), now: now) == "Thu 7:00\u{202F}AM")
        #expect(fmt.clock(now.addingTimeInterval(20 * 86400), now: now) == "Nov 5")
    }
}

@Suite struct AlertTests {
    let fmt = TimeFormatting(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)

    func plan(_ l: UsageLimit, fired: Set<String> = [], settings: AlertSettings = AlertSettings()) -> [AlertAction] {
        let p = Projector.project(l, samples: [], now: t0)
        return AlertPlanner.plan(limits: [l], projections: [l.kind: p], settings: settings,
                                 fired: fired, now: t0, fmt: fmt)
    }

    @Test func thresholdFiresOncePerWindowAndCollapsesSkippedOnes() {
        let l = limit(UsageLimit.weeklyAllKind, percent: 96, resetsIn: 6 * 86400)
        let actions = plan(l)
        let ids = actions.map(\.id)
        #expect(ids.contains { $0.hasPrefix("threshold95|") })
        #expect(actions.contains(.markFired(id: "threshold80|weekly_all@\(l.windowKey!)")))
        #expect(!actions.contains { if case .deliver(let id, _, _) = $0 { id.hasPrefix("threshold80") } else { false } })
        #expect(plan(l, fired: Set(ids)).isEmpty)
    }

    @Test func paceAlertWithinLeadTime() {
        let l = limit(percent: 48, resetsIn: 4 * 3600 + 18 * 60)   // ~45 min to limit
        let actions = plan(l)
        #expect(actions.contains { $0.id.hasPrefix("pace|session@") })
        var s = AlertSettings(); s.projectionLeadTime = 30 * 60
        #expect(!plan(l, settings: s).contains { $0.id.hasPrefix("pace|") })
    }

    @Test func limitedAlertAndResetSchedule() {
        let l = limit(percent: 100, resetsIn: 3600)
        let actions = plan(l)
        #expect(actions.contains { $0.id.hasPrefix("limited|") })
        #expect(actions.contains(.schedule(id: "reset|session@\(l.windowKey!)", at: l.resetsAt!,
                                           title: "Claude session (5-hour) limit has reset",
                                           body: "You're back to full capacity.")))
        // No threshold alerts once limited.
        #expect(!actions.contains { $0.id.hasPrefix("threshold") })
    }

    @Test func respectsDisabledSettings() {
        let l = limit(percent: 100, resetsIn: 3600)
        let s = AlertSettings(projection: false, thresholds: false, resets: false)
        #expect(plan(l, settings: s).map(\.id).allSatisfy { $0.hasPrefix("limited|") })
    }

    @Test func pruneKeepsRecentWindows() {
        let nowMin = Int(t0.timeIntervalSince1970 / 60)
        let fired: Set = ["pace|session@\(nowMin + 60)", "pace|session@\(nowMin - 2000)", "junk"]
        #expect(AlertPlanner.prune(fired, now: t0) == ["pace|session@\(nowMin + 60)"])
    }
}

@Suite struct MenuBarPresenterTests {
    let fmt = TimeFormatting(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)

    func present(_ limits: [UsageLimit], mode: MenuBarMode = .auto, stale: Bool = false) -> MenuBarPresentation {
        let p = Dictionary(uniqueKeysWithValues: limits.map { ($0.kind, Projector.project($0, samples: [], now: t0)) })
        return MenuBarPresenter.present(limits: limits, projections: p, mode: mode,
                                        staleProviders: stale ? [.claude] : [], now: t0, fmt: fmt)
    }

    @Test func autoPicksAtRiskSessionAndShowsTimeToLimit() {
        let p = present([limit(percent: 48, resetsIn: 4 * 3600 + 18 * 60),
                         limit(UsageLimit.weeklyAllKind, percent: 60, resetsIn: 6 * 86400)])
        #expect(p.text == "48%")
        #expect(p.caption == "~45m")
        #expect(p.severity == .warning)
        #expect(p.sessionFraction == 0.48)
    }

    @Test func autoPicksHigherPercentWhenAllOnPace() {
        let p = present([limit(percent: 10, resetsIn: 3600),
                         limit(UsageLimit.weeklyAllKind, percent: 30, resetsIn: 3 * 86400)])
        #expect(p.text == "30%")
        #expect(p.caption == "7d")
        #expect(p.severity == .normal)
    }

    @Test func limitedShowsTimeToReset() {
        let p = present([limit(percent: 100, resetsIn: 3 * 3600 + 37 * 60)])
        #expect(p.caption == "↻3h37m")
        #expect(p.severity == .critical)
    }

    @Test func bothMode() {
        let p = present([limit(percent: 10, resetsIn: 3600),
                         limit(UsageLimit.weeklyAllKind, percent: 30, resetsIn: 3 * 86400)], mode: .both)
        #expect(p.text == "10% · 30%")
        #expect(p.caption == nil)
    }

    @Test func noDataAndStale() {
        let p = present([], stale: true)
        #expect(p.text == "—")
        #expect(p.isStale)
        #expect(p.tooltip.contains("out of date"))
    }
}
