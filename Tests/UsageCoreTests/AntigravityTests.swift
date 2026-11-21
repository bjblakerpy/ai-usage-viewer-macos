import Foundation
import Testing
@testable import UsageCore

@Suite struct AntigravityParserTests {
    let now = HTTPParsing.isoDate("2030-01-01T00:00:00Z")!

    func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "antigravity-status", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func foldsVariantsIntoFamiliesUsingTheMostUsedVariant() throws {
        let s = try AntigravityParser.parse(fixture(), now: now, previous: [])
        #expect(s.planName == "Google AI Pro")
        #expect(s.limits.map(\.kind) == ["antigravity:gemini-4-argon", "antigravity:gemini-3-8-flash",
                                         "antigravity:claude-opus-5-5", "antigravity:gpt-oss-120b"])
        let argon = s.limits[0]
        #expect(argon.title == "Gemini 4 Argon")
        #expect(argon.percent == 60)             // High variant: 0.4 left
        #expect(argon.group == .weekly)          // reset 4.5 days out
        #expect(argon.provider == .antigravity)
        #expect(argon.observedAt == now)
    }

    @Test func missingFractionMeansExhausted() throws {
        let flash = try AntigravityParser.parse(fixture(), now: now, previous: []).limits[1]
        #expect(flash.percent == 100)
        #expect(flash.group == .session)
    }

    // Like Claude and Codex: one session row and one weekly row, each the
    // most-used model in that window. Every model is still kept underneath.
    @Test func summarizesToSessionAndWeeklyUsingTheMostUsedModel() throws {
        let s = try AntigravityParser.parse(fixture(), now: now, previous: [])
        #expect(s.limits.count == 4)
        let rows = AntigravityParser.summarize(s.limits)
        #expect(rows.map(\.kind) == ["antigravity:session", "antigravity:weekly"])
        #expect(rows[0].title == "Session (5-hour) · Gemini 3.8 Flash")   // 100% beats GPT-OSS at 20%
        #expect(rows[0].percent == 100)
        #expect(rows[0].group == .session)
        #expect(rows[1].title == "Weekly · Gemini 4 Argon")
        #expect(rows[1].percent == 60)
        #expect(rows[1].fullTitle == "Antigravity weekly · Gemini 4 Argon")
    }

    @Test func unusedWindowIsNamedPlainlyAndMissingWindowIsLeftOut() {
        let at = Date(timeIntervalSince1970: 0)
        let idle = UsageLimit(kind: "antigravity:x", group: .session, title: "Gemini 3.8 Flash", percent: 0,
                              resetsAt: nil, observedAt: at, provider: .antigravity)
        let rows = AntigravityParser.summarize([idle])
        #expect(rows.map(\.title) == ["Session (5-hour)"])
        #expect(AntigravityParser.summarize([]).isEmpty)
    }

    @Test func weeklyWindowNearItsEndKeepsItsLearnedGroup() {
        let kind = "antigravity:gemini-4-argon"
        let resetsSoon = now.addingTimeInterval(2 * 3600)
        let previous = [UsageLimit(kind: kind, group: .weekly, title: "Gemini 4 Argon", percent: 50,
                                   resetsAt: resetsSoon, observedAt: now, provider: .antigravity)]
        #expect(AntigravityParser.group(kind: kind, resetsAt: resetsSoon, now: now, previous: previous) == .weekly)
        #expect(AntigravityParser.group(kind: kind, resetsAt: resetsSoon, now: now, previous: []) == .session)
        #expect(AntigravityParser.group(kind: kind, resetsAt: now.addingTimeInterval(7 * 86400), now: now, previous: []) == .weekly)
    }

    @Test func rejectsResponsesWithoutQuota() {
        #expect(throws: UsageError.decoding) {
            try AntigravityParser.parse(Data(#"{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[]}}}"#.utf8), now: now, previous: [])
        }
        #expect(throws: UsageError.decoding) { try AntigravityParser.parse(Data("nope".utf8), now: now, previous: []) }
    }

    @Test func familyNamesAndSlugs() {
        #expect(AntigravityParser.familyName("Gemini 3.8 Flash (High)") == "Gemini 3.8 Flash")
        #expect(AntigravityParser.familyName("GPT-OSS 120B") == "GPT-OSS 120B")
        #expect(AntigravityParser.slug("Gemini 3.8 Flash") == "gemini-3-8-flash")
    }

    @Test func oldSnapshotsWithoutProviderDecodeAsClaude() throws {
        let json = #"{"kind":"session","group":"session","title":"Session (5-hour)","percent":12,"observedAt":0}"#
        let l = try JSONDecoder().decode(UsageLimit.self, from: Data(json.utf8))
        #expect(l.provider == .claude)
        #expect(l.serverSeverity == .normal)
        let roundTrip = try JSONDecoder().decode(UsageLimit.self, from: JSONEncoder().encode(
            UsageLimit(kind: "k", group: .weekly, title: "t", percent: 1, resetsAt: nil, observedAt: now, provider: .antigravity)))
        #expect(roundTrip.provider == .antigravity)
    }
}

@Suite struct AntigravityDiscoveryTests {
    @Test func findsLanguageServerAndToken() {
        let ps = """
          123 /usr/sbin/somethingelse --csrf_token nope
        11321 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --https_server_port 0 --csrf_token abc-123 --app_data_dir antigravity
        """
        #expect(AntigravityDiscovery.server(fromPS: ps) == .init(pid: 11321, csrf: "abc-123"))
        #expect(AntigravityDiscovery.server(fromPS: "1 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token=xyz")?.csrf == "xyz")
        #expect(AntigravityDiscovery.server(fromPS: "1 /Applications/Antigravity.app/Contents/MacOS/Antigravity") == nil)
    }

    // Antigravity 2.34+: the token comes from the daemon discovery file.
    @Test func readsTheDiscoveryFile() {
        let file = Data(#"{"pid":69298,"httpsPort":52400,"httpPort":52401,"lsVersion":"2.34.0","csrfToken":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}"#.utf8)
        let server = AntigravityDiscovery.server(fromDiscoveryFile: file)
        #expect(server == .init(pid: 69298, csrf: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", ports: [52401, 52400]))
    }

    @Test func rejectsBadDiscoveryFiles() {
        let bad = [
            #"{"pid":1,"httpPort":52401}"#,                                           // no token
            #"{"pid":1,"httpPort":52401,"csrfToken":"abc\r\nX-Evil: 1"}"#,           // header injection
            #"{"pid":1,"httpPort":70000,"csrfToken":"0f1e2d3c-4b5a-6978"}"#,          // no usable port
            #"{"pid":0,"httpPort":52401,"csrfToken":"0f1e2d3c-4b5a-6978"}"#,          // no process
            "not json",
        ]
        for b in bad { #expect(AntigravityDiscovery.server(fromDiscoveryFile: Data(b.utf8)) == nil) }
    }

    @Test func listsRunningLanguageServers() {
        let ps = """
        69282 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        69298 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --https_server_port 0
          500 /usr/bin/language_server
        """
        #expect(AntigravityDiscovery.languageServerPIDs(fromPS: ps) == [69298])
        #expect(AntigravityDiscovery.server(fromPS: ps) == nil)   // 2.34 has no token flag
    }

    @Test func parsesLoopbackPortsOnly() {
        let lsof = "p11321\nf12\nn127.0.0.1:50543\nf13\nn127.0.0.1:50544\nf14\nn*:9999\nf15\nn127.0.0.1:50543\n"
        #expect(AntigravityDiscovery.loopbackPorts(fromLsof: lsof) == [50543, 50544])
    }
}

@Suite struct CrossProviderMenuBarTests {
    let fmt = TimeFormatting(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)

    @Test func geminiWinsWhenMoreUrgentAndSwapsIcon() {
        let claude = limit(percent: 30, resetsIn: 4 * 3600)
        var gemini = limit("antigravity:gemini-3-8-flash", percent: 90, resetsIn: 600)
        gemini.provider = .antigravity
        let limits = [claude, gemini]
        let p = Dictionary(uniqueKeysWithValues: limits.map { ($0.kind, Projector.project($0, samples: [], now: t0)) })
        let shown = MenuBarPresenter.present(limits: limits, projections: p, mode: .auto,
                                             staleProviders: [.claude], now: t0, fmt: fmt)
        #expect(shown.provider == .antigravity)
        #expect(shown.text == "90%")
        #expect(!shown.isStale)   // only Claude's data is stale
        let sessionOnly = MenuBarPresenter.present(limits: limits, projections: p, mode: .session,
                                                   staleProviders: [], now: t0, fmt: fmt)
        #expect(sessionOnly.provider == .claude)
        #expect(sessionOnly.text == "30%")
    }
}
