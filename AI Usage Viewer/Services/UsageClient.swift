// UsageClient.swift
// AI Usage Viewer

import Foundation

actor UsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func fetch(token: String, userAgent: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: Self.endpoint)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent,          forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("No response from server.")
        }

        let now = Date()
        switch http.statusCode {
        case 200:
            return try UsageAPIParser.parse(data, now: now)
        case 401, 403:
            throw UsageError.unauthorized
        case 429:
            // Honour Retry-After; default to 5 minutes, the window we've observed.
            let retryAt = HTTPParsing.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now)
                ?? now.addingTimeInterval(5 * 60)
            throw UsageError.rateLimited(retryAt: retryAt)
        default:
            throw UsageError.http(http.statusCode)
        }
    }
}
