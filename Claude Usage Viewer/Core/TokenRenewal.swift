// TokenRenewal.swift
// Claude Usage Viewer
//
// Keeps Claude Code's keychain login fresh when nothing else will. The
// desktop app's Code tab signs in on its own and never renews the
// "Claude Code-credentials" item, so once you stop using `claude` in a
// terminal that token expires within hours. We renew it the way Claude
// Code does (same endpoint, client and scopes) and write the result back
// to the same item in the same format, so the terminal CLI stays signed
// in too.
//
// Refresh tokens rotate: if a terminal/IDE `claude` renewed at the same
// moment, one side would be signed out. So we only renew while no such
// process is running (see `keychainClientRunning`).
//
// TODO(security review): this handles OAuth refresh/access tokens. Values
// must never be logged, put in argv, or leave the machine except to the
// token endpoint below.

import Foundation

nonisolated enum TokenRenewal {
    // From Claude Code's production OAuth config (verified against CLI 2.1.309).
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let keychainService = "Claude Code-credentials"

    static func requestBody(refreshToken: String, scopes: [String]) throws -> Data {
        var body: [String: Any] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     clientID,
        ]
        if !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // Applies a token response to the keychain JSON, keeping every field we
    // don't own (subscription, tier, scopes, any other top-level keys).
    static func merge(keychainJSON: Data, response: Data, now: Date) throws -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: keychainJSON)) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let res = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
              let access = res["access_token"] as? String, !access.isEmpty,
              let expiresIn = UsageAPIParser.number(res["expires_in"])
        else { throw UsageError.decoding }

        oauth["accessToken"] = access
        oauth["expiresAt"] = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        if let refresh = res["refresh_token"] as? String, !refresh.isEmpty {
            oauth["refreshToken"] = refresh
        }
        if let refreshIn = UsageAPIParser.number(res["refresh_token_expires_in"]) {
            oauth["refreshTokenExpiresAt"] = Int((now.timeIntervalSince1970 + refreshIn) * 1000)
        }
        if let scope = res["scope"] as? String, !scope.isEmpty {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        root["claudeAiOauth"] = oauth
        return try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }

    // The line Claude Code itself feeds to `security -i`: hex-encoded so the
    // JSON needs no quoting, and on stdin so the token never appears in argv.
    static func securityCommand(account: String, json: Data) -> String? {
        guard isSafeAccount(account) else { return nil }
        let hex = json.map { String(format: "%02x", $0) }.joined()
        return "add-generic-password -U -a \"\(account)\" -s \"\(keychainService)\" -X \"\(hex)\"\n"
    }

    static func isSafeAccount(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "._-@".contains($0) }
    }

    // From `security find-generic-password -s …` (metadata only, no -w).
    static func account(fromSecurityMetadata output: String) -> String? {
        guard let r = output.range(of: #""acct"<blob>="([^"]*)""#, options: .regularExpression) else { return nil }
        let line = output[r]
        guard let start = line.range(of: "=\"")?.upperBound else { return nil }
        return String(line[start...].dropLast())
    }

    // True if a Claude Code process that manages the keychain login itself
    // (terminal, IDE) is running. Desktop-app sessions sign in through the
    // app and the Chrome bridge holds no login, so neither counts.
    static func keychainClientRunning(psOutput: String) -> Bool {
        psOutput.split(separator: "\n").contains { line in
            let args = line.trimmingCharacters(in: .whitespaces)
            guard let exe = args.split(separator: " ").dropFirst().first.map(String.init) else { return false }
            let isClaude = exe == "claude" || exe.hasSuffix("/claude") || exe.contains("/claude/versions/")
            guard isClaude else { return false }
            if args.contains("/Application Support/Claude/claude-code/") { return false }
            if args.contains("--chrome-native-host") { return false }
            return true
        }
    }
}
