import Foundation
import Testing
@testable import UsageCore

@Suite struct TokenRenewalTests {
    let keychain = Data("""
    {"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":1,
      "refreshTokenExpiresAt":2,"scopes":["user:inference","user:profile"],
      "subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},
     "mcpOAuth":{"some-server":{"token":"keep-me"}}}
    """.utf8)

    @Test func requestBodyMatchesClaudeCode() throws {
        let body = try TokenRenewal.requestBody(refreshToken: "r", scopes: ["user:inference", "user:profile"])
        let obj = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(obj == ["grant_type": "refresh_token", "refresh_token": "r",
                        "client_id": TokenRenewal.clientID, "scope": "user:inference user:profile"])
    }

    @Test func mergeUpdatesTokensAndKeepsEverythingElse() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = Data(#"{"token_type":"Bearer","access_token":"new-access","refresh_token":"new-refresh","expires_in":28800}"#.utf8)
        let merged = try TokenRenewal.merge(keychainJSON: keychain, response: response, now: now)

        let creds = try ClaudeCredentials.parse(merged)
        #expect(creds.accessToken == "new-access")
        #expect(creds.refreshToken == "new-refresh")
        #expect(creds.expiresAt == now.addingTimeInterval(28800))
        #expect(creds.planName == "Max 20x")
        #expect(creds.scopes == ["user:inference", "user:profile"])

        let root = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let mcp = root["mcpOAuth"] as? [String: [String: String]]
        #expect(mcp?["some-server"]?["token"] == "keep-me")
        let oauth = root["claudeAiOauth"] as? [String: Any]
        #expect(oauth?["refreshTokenExpiresAt"] as? Int == 2)       // untouched when not returned
        #expect(oauth?["expiresAt"] as? Int == 1_800_028_800_000)   // milliseconds, like Claude Code
    }

    @Test func mergeKeepsOldRefreshTokenWhenNoneReturned() throws {
        let response = Data(#"{"access_token":"a","expires_in":60,"refresh_token_expires_in":100}"#.utf8)
        let merged = try TokenRenewal.merge(keychainJSON: keychain, response: response, now: Date(timeIntervalSince1970: 0))
        let oauth = try #require((JSONSerialization.jsonObject(with: merged) as? [String: Any])?["claudeAiOauth"] as? [String: Any])
        #expect(oauth["refreshToken"] as? String == "old-refresh")
        #expect(oauth["refreshTokenExpiresAt"] as? Int == 100_000)
    }

    @Test func mergeRejectsBadResponses() {
        #expect(throws: UsageError.decoding) {
            try TokenRenewal.merge(keychainJSON: keychain, response: Data(#"{"error":"invalid_grant"}"#.utf8), now: Date())
        }
        #expect(throws: UsageError.decoding) {
            try TokenRenewal.merge(keychainJSON: Data("{}".utf8), response: Data(#"{"access_token":"a","expires_in":1}"#.utf8), now: Date())
        }
    }

    @Test func securityCommandIsHexOnStdinFormat() throws {
        let cmd = try #require(TokenRenewal.securityCommand(account: "bj", json: Data(#"{"a":"b"}"#.utf8)))
        #expect(cmd == "add-generic-password -U -a \"bj\" -s \"Claude Code-credentials\" -X \"7b2261223a2262227d\"\n")
        #expect(TokenRenewal.securityCommand(account: "bj\" -s evil", json: Data()) == nil)
        #expect(TokenRenewal.securityCommand(account: "", json: Data()) == nil)
    }

    @Test func accountFromMetadata() {
        let meta = """
        keychain: "/Users/bj/Library/Keychains/login.keychain-db"
            "acct"<blob>="bj"
            "svce"<blob>="Claude Code-credentials"
        """
        #expect(TokenRenewal.account(fromSecurityMetadata: meta) == "bj")
        #expect(TokenRenewal.account(fromSecurityMetadata: "nothing") == nil)
    }

    @Test func detectsOnlyClaudeProcessesThatOwnTheKeychainLogin() {
        let desktopOnly = """
        10797 /Users/bj/Library/Application Support/Claude/claude-code/2.1.309/5af865b9901c/claude.app/Contents/MacOS/claude --output-format stream-json
        11036 /Users/bj/.local/bin/claude --chrome-native-host
          900 /bin/zsh -c echo claude
          901 /Applications/Claude.app/Contents/MacOS/Claude
        """
        #expect(!TokenRenewal.keychainClientRunning(psOutput: desktopOnly))
        #expect(TokenRenewal.keychainClientRunning(psOutput: desktopOnly + "\n 1234 claude"))
        #expect(TokenRenewal.keychainClientRunning(psOutput: " 1234 /Users/bj/.local/share/claude/versions/2.1.309 --resume"))
        #expect(TokenRenewal.keychainClientRunning(psOutput: " 1234 /opt/homebrew/bin/claude"))
    }

    @Test func refreshTokenParsedButNotInDescription() throws {
        let c = try ClaudeCredentials.parse(keychain)
        #expect(c.refreshToken == "old-refresh")
        #expect(!c.description.contains("old-refresh"))
    }
}
