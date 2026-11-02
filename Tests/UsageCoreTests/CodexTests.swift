import Foundation
import Testing
@testable import UsageCore

@Suite struct CodexParserTests {
    func fixture() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "codex-rollout", withExtension: "jsonl",
                                                 subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func takesTheNewestReadingAndSkipsOtherLines() throws {
        let s = try #require(CodexParser.latest(inLog: fixture()))
        #expect(s.fetchedAt == HTTPParsing.isoDate("2030-01-01T09:06:00Z"))
        #expect(s.planName == "Plus")
        #expect(s.limits.map(\.kind) == ["codex:session", "codex:weekly"])

        let session = s.limits[0]
        #expect(session.title == "Session (5-hour)")
        #expect(session.group == .session)
        #expect(session.percent == 12.5)
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1893502800))
        #expect(session.provider == .codex)
        #expect(session.observedAt == s.fetchedAt)
        #expect(session.fullTitle == "Codex session (5-hour)")

        #expect(s.limits[1].group == .weekly)
        #expect(s.limits[1].title == "Weekly")
    }

    @Test func olderBuildsGiveResetsRelativeToTheEvent() throws {
        let line = #"{"timestamp":"2030-01-01T09:01:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_in_seconds":3600}}}}"#
        let s = try #require(CodexParser.parse(line: Data(line.utf8)))
        #expect(s.limits.first?.resetsAt == HTTPParsing.isoDate("2030-01-01T10:01:00Z"))
        #expect(s.planName == nil)
    }

    @Test func earliestFlatFormat() throws {
        let line = #"{"timestamp":"2030-01-01T09:01:00Z","payload":{"type":"token_count","rate_limits":{"primary_used_percent":40,"primary_window_minutes":300,"primary_resets_in_seconds":60,"secondary_used_percent":5,"secondary_window_minutes":10080}}}"#
        let s = try #require(CodexParser.parse(line: Data(line.utf8)))
        #expect(s.limits.map(\.percent) == [40, 5])
        #expect(s.limits[1].resetsAt == nil)
    }

    @Test func unusualWindowsAndBadValues() {
        let at = Date(timeIntervalSince1970: 0)
        #expect(CodexParser.limit(from: ["used_percent": 150, "window_minutes": 300], observedAt: at)?.percent == 100)
        #expect(CodexParser.limit(from: ["used_percent": 5, "window_minutes": 1440], observedAt: at)?.title == "24-hour window")
        #expect(CodexParser.limit(from: ["used_percent": 5], observedAt: at) == nil)
        #expect(CodexParser.limit(from: ["window_minutes": 300], observedAt: at) == nil)
        #expect(CodexParser.latest(inLog: "not json\n{}") == nil)
    }

    @Test func homeHonoursCodexHome() {
        let user = URL(fileURLWithPath: "/Users/someone")
        #expect(CodexParser.home(environment: [:], userHome: user).path == "/Users/someone/.codex")
        #expect(CodexParser.home(environment: ["CODEX_HOME": "/opt/codex"], userHome: user).path == "/opt/codex")
    }

    @Test func findsTheNewestLogsFirst() throws {
        let fm = FileManager.default
        let sessions = fm.temporaryDirectory.appendingPathComponent("codex-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: sessions) }
        for (day, name) in [("2029/12/31", "rollout-2029-12-31T10-00-00-a.jsonl"),
                            ("2030/01/01", "rollout-2030-01-01T08-00-00-b.jsonl"),
                            ("2030/01/01", "rollout-2030-01-01T09-00-00-c.jsonl"),
                            ("2030/01/01", "notes.txt")] {
            let dir = sessions.appendingPathComponent(day)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let names = CodexParser.recentLogs(sessionsDir: sessions, limit: 2).map(\.lastPathComponent)
        #expect(names == ["rollout-2030-01-01T09-00-00-c.jsonl", "rollout-2030-01-01T08-00-00-b.jsonl"])
        #expect(CodexParser.recentLogs(sessionsDir: sessions).count == 3)
        #expect(CodexParser.recentLogs(sessionsDir: sessions.appendingPathComponent("missing")).isEmpty)
    }
}

@Suite struct ServiceNamingTests {
    func limit(_ title: String, _ provider: Provider) -> UsageLimit {
        UsageLimit(kind: "k", group: .session, title: title, percent: 1, resetsAt: nil,
                   observedAt: Date(timeIntervalSince1970: 0), provider: provider)
    }

    @Test func fullTitlesNameTheService() {
        #expect(limit("Session (5-hour)", .claude).fullTitle == "Claude session (5-hour)")
        #expect(limit("Weekly (all models)", .claude).fullTitle == "Claude weekly (all models)")
        #expect(limit("Gemini 4 Argon", .antigravity).fullTitle == "Gemini 4 Argon")
        #expect(limit("Weekly", .codex).fullTitle == "Codex weekly")
    }
}
