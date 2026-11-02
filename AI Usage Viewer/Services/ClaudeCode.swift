// ClaudeCode.swift
// AI Usage Viewer
//
// Everything we read from the local Claude Code install: its login (from
// the keychain) and its version (for the User-Agent).

import Foundation
import os

nonisolated let usageLog = Logger(subsystem: "model40.Claude-Usage-Viewer", category: "usage")

// A short plain-text trail in the support folder (last 200 lines), so
// problems can be diagnosed without Console. Callers must never pass
// token values: error types, HTTP codes and OAuth error codes only.
nonisolated enum Diagnostics {
    private static let queue = DispatchQueue(label: "Diagnostics")

    static func note(_ message: String) {
        usageLog.notice("\(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let url = AppPaths.supportDir.appendingPathComponent("diagnostics.log")
            try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lines = (old + line).split(separator: "\n", omittingEmptySubsequences: true).suffix(200)
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

nonisolated enum AppPaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var supportDir: URL {
        home.appendingPathComponent("Library/Application Support/AI Usage Viewer", isDirectory: true)
    }

    // The folder's name before the app was renamed (see SupportFolderMigration).
    static var legacySupportDir: URL {
        home.appendingPathComponent("Library/Application Support/Claude Usage Viewer", isDirectory: true)
    }

    static func migrateLegacySupportDir() {
        let outcome = SupportFolderMigration.run(from: legacySupportDir, to: supportDir,
                                                 settingsURL: statusLineInstaller.settingsURL)
        switch outcome {
        case .nothingToDo: break
        // Logged only: writing diagnostics.log would create the new folder
        // and stop the move from being retried.
        case .failed(let why): usageLog.error("support folder migration: \(why, privacy: .public)")
        case .moved(let updated):
            Diagnostics.note("moved support folder from \(legacySupportDir.lastPathComponent)" + (updated ? "; status line updated" : ""))
        }
    }

    static var historyFile: URL { supportDir.appendingPathComponent("history.json") }

    // Claude Code honours CLAUDE_CONFIG_DIR; default is ~/.claude.
    static var claudeConfigDir: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    static var statusLineInstaller: StatusLineInstaller {
        StatusLineInstaller(settingsURL: claudeConfigDir.appendingPathComponent("settings.json"),
                            supportDir: supportDir)
    }
}

nonisolated enum CredentialReader {
    // Reads through /usr/bin/security rather than SecItemCopyMatching.
    // Claude Code creates the item with that tool, so it's on the item's
    // access list: no keychain prompt, even after a rebuild changes our
    // code signature. (This is why the app is no longer sandboxed.)
    static func read() async throws -> ClaudeCredentials {
        try ClaudeCredentials.parse(try await readRaw())
    }

    private static func readRaw() async throws -> Data {
        let out = try await ProcessRunner.run(
            "/usr/bin/security", ["find-generic-password", "-s", TokenRenewal.keychainService, "-w"])
        guard out.status == 0 else { throw UsageError.noCredentials }
        return out.stdout
    }

    // Renews the keychain login (see TokenRenewal for why and when).
    // Sent under the app's own default User-Agent: the token endpoint
    // rate-limits requests that claim to be `claude-code/…`, and we don't
    // impersonate Claude Code's own client either.
    // TODO(security review): handles OAuth tokens; never log them.
    static func renew() async throws -> ClaudeCredentials {
        let ps = try await ProcessRunner.run("/bin/ps", ["-axo", "pid=,args="])
        if TokenRenewal.keychainClientRunning(psOutput: String(decoding: ps.stdout, as: UTF8.self)) {
            // A terminal/IDE Claude Code will renew it itself; renewing too would race it.
            Diagnostics.note("login renewal skipped: a terminal/IDE Claude Code is running")
            throw UsageError.loginExpired
        }

        let raw = try await readRaw()
        let current = try ClaudeCredentials.parse(raw)
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else { throw UsageError.loginRevoked }

        var req = URLRequest(url: TokenRenewal.tokenURL, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = try TokenRenewal.requestBody(refreshToken: refreshToken, scopes: current.scopes)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) } catch {
            throw UsageError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            // OAuth error bodies carry only a code and description, never tokens.
            let err = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            Diagnostics.note("login renewal HTTP \(status): \(err?["error"] ?? "-") \(err?["error_description"] ?? "")")
        }
        switch status {
        case 200: break
        case 400, 401, 403: throw UsageError.loginRevoked
        case 429:
            let retryAt = HTTPParsing.retryAfter((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), now: Date())
            throw UsageError.rateLimited(retryAt: retryAt ?? Date().addingTimeInterval(10 * 60))
        case let code: throw UsageError.http(code)
        }

        // From here the old refresh token is spent: the new one must reach the keychain.
        let merged = try TokenRenewal.merge(keychainJSON: raw, response: data, now: Date())
        let renewed = try ClaudeCredentials.parse(merged)
        try await write(merged)
        let readBack = try await read()
        guard readBack.accessToken == renewed.accessToken else { throw UsageError.loginRevoked }
        return readBack
    }

    // Same as Claude Code: `security -i` on stdin when the command fits its
    // 4032-character line limit, otherwise argv (what Claude Code does for a
    // large item too; visible to this user's `ps` only while it runs).
    private static func write(_ json: Data) async throws {
        let meta = try await ProcessRunner.run("/usr/bin/security", ["find-generic-password", "-s", TokenRenewal.keychainService])
        guard let account = TokenRenewal.account(fromSecurityMetadata: String(decoding: meta.stdout, as: UTF8.self)),
              let command = TokenRenewal.securityCommand(account: account, json: json) else {
            throw UsageError.loginRevoked
        }
        let out: ProcessRunner.Output
        if command.count <= 4032 {
            out = try await ProcessRunner.run("/usr/bin/security", ["-i"], input: Data(command.utf8))
        } else {
            let hex = json.map { String(format: "%02x", $0) }.joined()
            out = try await ProcessRunner.run("/usr/bin/security", ["add-generic-password", "-U", "-a", account,
                                                                     "-s", TokenRenewal.keychainService, "-X", hex])
        }
        guard out.status == 0 else {
            Diagnostics.note("keychain write failed: security exited \(out.status)")
            throw UsageError.loginRevoked
        }
        Diagnostics.note("renewed Claude Code login")
    }
}

actor ClaudeCLI {
    private var cached: (version: String?, at: Date)?

    private static let candidates = [
        "~/.local/bin/claude", "~/.claude/local/claude",
        "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
    ].map { ($0 as NSString).expandingTildeInPath }

    func userAgent() async -> String {
        if let cached, Date().timeIntervalSince(cached.at) < 6 * 3600 {
            return CLIVersion.userAgent(cached.version)
        }
        let version = await Self.installedVersion()
        cached = (version, Date())
        return CLIVersion.userAgent(version)
    }

    // The native installer symlinks to …/versions/<x.y.z>, so the version is
    // usually in the resolved path; otherwise ask the binary.
    private static func installedVersion() async -> String? {
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let v = CLIVersion.parse(resolved) { return v }
            if let out = try? await ProcessRunner.run(path, ["--version"]),
               out.status == 0, let v = CLIVersion.parse(String(decoding: out.stdout, as: UTF8.self)) {
                return v
            }
        }
        return nil
    }
}
