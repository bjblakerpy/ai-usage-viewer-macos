// AntigravityClient.swift
// AI Usage Viewer
//
// Reads model quota from Antigravity's local language server. The server
// picks random loopback ports at launch and guards its API with a CSRF
// token, so each time Antigravity restarts we rediscover both: from the
// discovery file it writes (2.34 and later) or, for older versions, from
// its command line via `ps` and `lsof` (see AntigravityDiscovery).
// Nothing leaves the machine: the server itself talks to Google with the
// session Antigravity owns.
// TODO(security review): reads Antigravity's local CSRF token; never log it.

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

    static var daemonDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
    }

    // The raw GetUserStatus response, or nil if Antigravity isn't running.
    func fetchStatus() async throws -> Data? {
        guard let out = try? await ProcessRunner.run("/bin/ps", ["-axo", "pid=,args="]), out.status == 0 else { return nil }
        let ps = String(decoding: out.stdout, as: UTF8.self)
        let running = AntigravityDiscovery.languageServerPIDs(fromPS: ps)
        guard !running.isEmpty else {
            server = nil; endpoint = nil
            return nil
        }
        guard let found = Self.fromDiscoveryFiles(alive: running) ?? AntigravityDiscovery.server(fromPS: ps) else {
            throw UsageError.network("Antigravity is running, but this version doesn't say how to reach its quota.")
        }
        if found != server { server = found; endpoint = nil }

        if let endpoint, let data = try? await request(endpoint, csrf: found.csrf) { return data }
        endpoint = nil

        let ports = found.ports.isEmpty ? await Self.ports(pid: found.pid) : found.ports
        for port in ports {
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

    // The newest discovery file whose server is one of the running ones
    // (a crash can leave a stale file behind).
    private static func fromDiscoveryFiles(alive: Set<Int32>) -> AntigravityDiscovery.Server? {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: daemonDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for url in files {
            guard let data = try? Data(contentsOf: url), data.count < 64 * 1024,
                  let server = AntigravityDiscovery.server(fromDiscoveryFile: data), alive.contains(server.pid) else { continue }
            return server
        }
        return nil
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
