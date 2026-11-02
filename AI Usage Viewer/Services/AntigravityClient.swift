// AntigravityClient.swift
// AI Usage Viewer
//
// Reads Gemini quota from Antigravity's local language server. The server
// picks a random loopback port at launch and guards its API with a CSRF
// token passed on its command line, so each time Antigravity restarts we
// rediscover both from `ps` and `lsof`. Nothing leaves the machine: the
// server itself talks to Google with the session Antigravity owns.

import Foundation

actor AntigravityClient {
    private var server:   AntigravityDiscovery.Server?
    private var endpoint: URL?

    private static let path = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let body = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#.utf8)

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config, delegate: LoopbackTrust(), delegateQueue: nil)
    }()

    // The raw GetUserStatus response, or nil if Antigravity isn't running.
    func fetchStatus() async throws -> Data? {
        guard let found = await Self.findServer() else {
            server = nil; endpoint = nil
            return nil
        }
        if found != server { server = found; endpoint = nil }

        if let endpoint, let data = try? await request(endpoint, csrf: found.csrf) { return data }
        endpoint = nil

        for port in await Self.ports(pid: found.pid) {
            for scheme in ["https", "http"] {
                guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(Self.path)") else { continue }
                if let data = try? await request(url, csrf: found.csrf) {
                    endpoint = url
                    return data
                }
            }
        }
        throw UsageError.network("Antigravity is running but its language server didn't answer.")
    }

    private func request(_ url: URL, csrf: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Self.body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1",                forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(csrf,               forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UsageError.decoding }
        return data
    }

    private static func findServer() async -> AntigravityDiscovery.Server? {
        guard let out = try? await ProcessRunner.run("/bin/ps", ["-axo", "pid=,args="]), out.status == 0 else { return nil }
        return AntigravityDiscovery.server(fromPS: String(decoding: out.stdout, as: UTF8.self))
    }

    private static func ports(pid: Int32) async -> [Int] {
        guard let out = try? await ProcessRunner.run(
            "/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]) else { return [] }
        return AntigravityDiscovery.loopbackPorts(fromLsof: String(decoding: out.stdout, as: UTF8.self))
    }
}

// Antigravity's server uses a self-signed certificate. Trust it only for
// the loopback address; every other host gets normal validation.
nonisolated final class LoopbackTrust: NSObject, URLSessionDelegate, Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == "127.0.0.1", let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
