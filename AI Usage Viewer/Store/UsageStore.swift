// UsageStore.swift
// AI Usage Viewer
//
// Owns the app's state and decides when to fetch. Claude has two sources:
//   1. The Claude Code status-line feed (a file, checked every 5 s): live
//      session/weekly numbers while you use Claude Code, at no API cost.
//   2. The usage API (scheduled by FetchScheduler): everything else, and
//      the session/weekly numbers when Claude Code is idle.
// Gemini comes from the running Antigravity app and OpenAI from Codex's
// session logs, each checked every minute.

import Foundation
import Observation
import os

@MainActor
@Observable
final class UsageStore {
    private(set) var apiSnapshot:  UsageSnapshot?
    private(set) var feedLimits:   [UsageLimit] = []
    private(set) var history       = UsageHistory()
    private(set) var planName:     String?
    private(set) var error:        UsageError?
    private(set) var isLoading     = false
    private(set) var fetchState    = FetchState()
    private(set) var feedState:    StatusLineInstaller.State = .notInstalled
    private(set) var antigravity:  AntigravitySnapshot?
    private(set) var antigravityRunning = false
    private(set) var antigravityError: UsageError?
    private(set) var codex:        CodexSnapshot?
    private(set) var codexInstalled = CodexClient.isInstalled
    // Advanced every 30 s so projections, countdowns and staleness move on
    // their own between data updates.
    private(set) var now = Date()

    @ObservationIgnored let prefs: Preferences
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private let system = SystemMonitor()
    @ObservationIgnored private let client = UsageClient()
    @ObservationIgnored private let cli = ClaudeCLI()
    @ObservationIgnored private let antigravityClient = AntigravityClient()
    @ObservationIgnored private let codexClient = CodexClient()
    @ObservationIgnored private let installer = AppPaths.statusLineInstaller
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var rejectedFingerprint: String?
    // Renewal pacing, persisted so relaunching can't bypass it: at most one
    // try every 10 min, and after a 429 the wait doubles up to 2 h.
    @ObservationIgnored private var renewalNotBefore: Date? {
        get { defaults.object(forKey: "renewalNotBefore") as? Date }
        set { defaults.set(newValue, forKey: "renewalNotBefore") }
    }
    @ObservationIgnored private var renewalBackoff: TimeInterval {
        get { max(Self.renewalMinInterval, defaults.double(forKey: "renewalBackoff")) }
        set { defaults.set(newValue, forKey: "renewalBackoff") }
    }
    private static let renewalMinInterval: TimeInterval = 10 * 60
    private static let renewalMaxBackoff:  TimeInterval = 2 * 3600
    @ObservationIgnored private var firedAlerts: Set<String> = []
    @ObservationIgnored private var feedModified: Date?
    @ObservationIgnored private var historyDirty = false
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    private static let snapshotKey = "snapshot.v2"
    private static let antigravityKey = "antigravity.v1"
    private static let codexKey = "codex.v1"
    private static let firedKey = "firedAlerts"
    static let staleAfter: TimeInterval = 30 * 60

    init(prefs: Preferences) {
        self.prefs = prefs
        if let data = defaults.data(forKey: Self.snapshotKey) {
            apiSnapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        }
        if let data = try? Data(contentsOf: AppPaths.historyFile) {
            history = (try? JSONDecoder().decode(UsageHistory.self, from: data)) ?? UsageHistory()
        }
        if let data = defaults.data(forKey: Self.antigravityKey) {
            antigravity = try? JSONDecoder().decode(AntigravitySnapshot.self, from: data)
        }
        if let data = defaults.data(forKey: Self.codexKey) {
            codex = try? JSONDecoder().decode(CodexSnapshot.self, from: data)
        }
        firedAlerts = Set(defaults.stringArray(forKey: Self.firedKey) ?? [])
        fetchState.lastSuccess = apiSnapshot?.fetchedAt
    }

    // MARK: Derived state

    var limits: [UsageLimit] { claudeLimits + geminiLimits + codexLimits }

    var claudeLimits: [UsageLimit] {
        UsageMerger.merge(api: apiSnapshot?.limits ?? [], feed: feedLimits, now: now)
    }

    var geminiLimits: [UsageLimit] {
        guard prefs.trackAntigravity, let antigravity else { return [] }
        return UsageMerger.merge(api: antigravity.limits, feed: [], now: now).filter(AntigravityParser.isShown)
    }

    var codexLimits: [UsageLimit] {
        guard prefs.trackCodex, let codex else { return [] }
        return UsageMerger.merge(api: codex.limits, feed: [], now: now)
    }

    // Shown once Codex is on this Mac, or once we've ever had a reading.
    var showsCodex: Bool { prefs.trackCodex && (codexInstalled || codex != nil) }

    var projections: [String: Projection] {
        Dictionary(limits.map { ($0.kind, Projector.project($0, samples: history.samples(for: $0), now: now)) },
                   uniquingKeysWith: { a, _ in a })
    }

    var lastUpdated: Date? { [apiSnapshot?.fetchedAt, fetchState.feedUpdatedAt].compactMap { $0 }.max() }
    var isFeedLive: Bool { FetchScheduler.isFeedActive(fetchState, now: now) }
    var isStale: Bool { lastUpdated.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true }
    var cooldownUntil: Date? { FetchScheduler.inCooldown(fetchState, now: now) ? fetchState.cooldownUntil : nil }
    var canRefresh: Bool { !isLoading && !FetchScheduler.inCooldown(fetchState, now: Date()) }

    // Gemini quota only moves while Antigravity runs, so a closed Antigravity
    // isn't stale data: it's the last reading, still true. Stale means
    // Antigravity is running and we've failed to read it for a while.
    var isGeminiStale: Bool {
        guard antigravityRunning, let fetched = antigravity?.fetchedAt else { return false }
        return now.timeIntervalSince(fetched) > 10 * 60
    }

    var staleProviders: Set<Provider> {
        var s: Set<Provider> = []
        if isStale { s.insert(.claude) }
        if isGeminiStale { s.insert(.antigravity) }
        return s
    }

    // Login problems always matter. Transient errors only matter once the
    // numbers on screen are getting old; a 429 while the feed is live is noise.
    var visibleError: UsageError? {
        switch error {
        case .noCredentials?, .loginExpired?, .loginRevoked?, .unauthorized?: return error
        case nil: return nil
        default: return isStale ? error : nil
        }
    }

    func menuBar(fmt: TimeFormatting = TimeFormatting()) -> MenuBarPresentation {
        MenuBarPresenter.present(limits: limits, projections: projections, mode: prefs.menuBarMode,
                                 staleProviders: staleProviders, now: now, fmt: fmt)
    }

    // MARK: Lifecycle

    func start() {
        feedState = installer.state()
        notifier.start()
        system.onActive = { [weak self] in self?.nudge() }
        system.start()
        pollFeed()

        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(30))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.pollFeed()
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAntigravity()
                await self?.refreshCodex()
                try? await Task.sleep(for: .seconds(60))
            }
        })
    }

    func saveNow() {
        saveHistoryIfNeeded()
    }

    // Opening the popover, waking, unlocking or reconnecting.
    func nudge() {
        now = Date()
        Task { await refreshAntigravity(); await refreshCodex() }
        guard FetchScheduler.shouldFetchOnNudge(fetchState, now: now) else { return }
        Task { await refresh() }
    }

    private func tick() async {
        now = Date()
        saveHistoryIfNeeded()
        guard !system.isIdle, now >= FetchScheduler.nextFetch(fetchState, now: now) else {
            evaluateAlerts()
            return
        }
        await refresh()
    }

    // MARK: Fetching

    func refresh() async {
        guard canRefresh else { Diagnostics.note("Claude refresh skipped (loading or cooldown)"); return }
        isLoading = true
        defer { isLoading = false }
        fetchState.lastAttempt = Date()

        var creds: ClaudeCredentials
        do {
            creds = try await CredentialReader.read()
            planName = creds.planName
            if creds.isExpired(now: Date()) || creds.fingerprint == rejectedFingerprint {
                creds = try await renewLogin()
            }
        } catch {
            fail(error as? UsageError ?? .noCredentials)
            return
        }

        do {
            let snapshot = try await client.fetch(token: creds.accessToken, userAgent: await cli.userAgent())
            apiSnapshot = snapshot
            error = nil
            rejectedFingerprint = nil
            Diagnostics.note("Claude refresh ok")
            fetchState.lastSuccess = snapshot.fetchedAt
            fetchState.consecutiveFailures = 0
            fetchState.cooldownUntil = nil
            if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.snapshotKey) }
            dataChanged()
        } catch UsageError.rateLimited(let retryAt) {
            error = .rateLimited(retryAt: retryAt)
            // Fix the jitter now so every reader agrees on one retry time.
            fetchState.cooldownUntil = retryAt.addingTimeInterval(.random(in: FetchScheduler.jitterRange))
        } catch UsageError.unauthorized {
            // Don't retry this token; wait for Claude Code to replace it.
            rejectedFingerprint = creds.fingerprint
            fail(.unauthorized)
        } catch {
            fail(error as? UsageError ?? .network(error.localizedDescription))
        }
    }

    // MARK: Gemini (Antigravity)

    func refreshAntigravity() async {
        guard prefs.trackAntigravity, !system.isIdle else { return }
        do {
            guard let data = try await antigravityClient.fetchStatus() else {
                antigravityRunning = false
                antigravityError = nil
                return
            }
            antigravityRunning = true
            let snapshot = try AntigravityParser.parse(data, now: Date(), previous: antigravity?.limits ?? [])
            antigravity = snapshot
            antigravityError = nil
            if let encoded = try? JSONEncoder().encode(snapshot) { defaults.set(encoded, forKey: Self.antigravityKey) }
            now = Date()
            dataChanged()
        } catch {
            antigravityError = error as? UsageError ?? .network(error.localizedDescription)
        }
    }

    // MARK: OpenAI (Codex)

    // Codex logs its plan limits as you use it, so the newest log entry is
    // the current reading; there's nothing to fetch and nothing goes stale.
    func refreshCodex() async {
        guard prefs.trackCodex, !system.isIdle else { return }
        codexInstalled = CodexClient.isInstalled
        guard codexInstalled, let snapshot = await codexClient.latest(), snapshot != codex else { return }
        codex = snapshot
        if let encoded = try? JSONEncoder().encode(snapshot) { defaults.set(encoded, forKey: Self.codexKey) }
        now = Date()
        dataChanged()
    }

    // Nobody renews Claude Code's keychain login while you work in the
    // desktop app, so we do — at most every 10 minutes, and never while a
    // terminal/IDE Claude Code is running (CredentialReader.renew checks).
    private func renewLogin() async throws -> ClaudeCredentials {
        if let notBefore = renewalNotBefore, Date() < notBefore { throw UsageError.loginExpired }
        renewalNotBefore = Date().addingTimeInterval(Self.renewalMinInterval)
        do {
            let renewed = try await CredentialReader.renew()
            rejectedFingerprint = nil
            renewalBackoff = Self.renewalMinInterval
            return renewed
        } catch UsageError.rateLimited(let retryAt) {
            let backoff = min(renewalBackoff * 2, Self.renewalMaxBackoff)
            renewalBackoff = backoff
            renewalNotBefore = max(retryAt, Date().addingTimeInterval(backoff))
            Diagnostics.note("login renewal rate-limited; next try after \(renewalNotBefore!)")
            throw UsageError.loginExpired
        }
    }

    private func fail(_ e: UsageError) {
        Diagnostics.note("Claude refresh failed: \(e)")
        error = e
        fetchState.consecutiveFailures += 1
    }

    // MARK: Status-line feed

    private func pollFeed() {
        let url = installer.feedURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date, modified != feedModified,
              let data = try? Data(contentsOf: url) else { return }
        feedModified = modified
        now = Date()
        let parsed = StatusLineFeed.parse(data, observedAt: modified, now: now)
        guard !parsed.isEmpty else { return }
        feedLimits = parsed
        fetchState.feedUpdatedAt = modified
        dataChanged()
    }

    func installFeed() throws {
        defer { feedState = installer.state() }
        try installer.install()
    }

    func uninstallFeed() throws {
        defer { feedState = installer.state() }
        try installer.uninstall()
        feedLimits = []
        fetchState.feedUpdatedAt = nil
        feedModified = nil
    }

    func refreshFeedState() { feedState = installer.state() }

    // MARK: History and alerts

    private func dataChanged() {
        if history.record(limits) { historyDirty = true }
        evaluateAlerts()
    }

    private func evaluateAlerts() {
        let actions = AlertPlanner.plan(limits: limits, projections: projections, settings: prefs.alertSettings,
                                        fired: firedAlerts, now: now, fmt: TimeFormatting())
        guard !actions.isEmpty else { return }
        notifier.perform(actions)
        firedAlerts = AlertPlanner.prune(firedAlerts.union(actions.map(\.id)), now: now)
        defaults.set(Array(firedAlerts), forKey: Self.firedKey)
    }

    private func saveHistoryIfNeeded() {
        guard historyDirty else { return }
        history.prune(now: Date())
        do {
            try FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: AppPaths.historyFile, options: .atomic)
            historyDirty = false
        } catch {
            // Non-fatal: history is a nicety; try again next tick.
        }
    }
}
