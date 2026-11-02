// Credentials.swift
// Claude Usage Viewer
//
// Parses the JSON Claude Code keeps in the "Claude Code-credentials"
// keychain item. It's renewed here only when it has expired and no
// terminal/IDE Claude Code is running to renew it (see TokenRenewal).

import Foundation
import CryptoKit

nonisolated struct ClaudeCredentials: Equatable, Sendable, CustomStringConvertible {
    var accessToken:      String
    var expiresAt:        Date?
    var subscriptionType: String?
    var rateLimitTier:    String?
    var refreshToken:     String?
    var scopes:           [String] = []

    // Keep the token out of logs and debugger output.
    var description: String { "ClaudeCredentials(token: <redacted>, expiresAt: \(String(describing: expiresAt)))" }

    // Identifies a token without holding onto it, to tell when Claude Code
    // has replaced a token we already know is expired or rejected.
    var fingerprint: String {
        SHA256.hash(data: Data(accessToken.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func isExpired(now: Date, margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < margin
    }

    // "default_claude_max_20x" → "Max 20x"; "pro" → "Pro".
    var planName: String? {
        if let tier = rateLimitTier,
           let range = tier.range(of: #"max_(\d+)x"#, options: .regularExpression) {
            let n = tier[range].dropFirst(4).dropLast()
            return "Max \(n)x"
        }
        return subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw UsageError.noCredentials }
        return ClaudeCredentials(
            accessToken:      token,
            expiresAt:        UsageAPIParser.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier:    oauth["rateLimitTier"] as? String,
            refreshToken:     oauth["refreshToken"] as? String,
            scopes:           oauth["scopes"] as? [String] ?? []
        )
    }
}

nonisolated enum CLIVersion {
    // Last version verified against the usage endpoint; used only if the
    // installed CLI can't be found.
    static let fallback = "2.1.302"

    static func parse(_ text: String) -> String? {
        guard let r = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    static func userAgent(_ version: String?) -> String { "claude-code/\(version ?? fallback)" }
}
