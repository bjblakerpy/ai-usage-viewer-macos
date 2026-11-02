// CodexClient.swift
// AI Usage Viewer
//
// Finds the newest OpenAI plan reading in Codex's session logs (see
// Core/Codex.swift). Only the last part of each recent log is read, and a
// file that hasn't changed since the last check isn't read again.

import Foundation

actor CodexClient {
    private struct Seen: Equatable {
        var modified: Date
        var size:     Int
    }
    private var cache: [URL: (seen: Seen, snapshot: CodexSnapshot?)] = [:]

    // Rate-limit events are small; this comfortably holds the last few.
    private static let tailBytes = 512 * 1024

    nonisolated static var home: URL {
        CodexParser.home(environment: ProcessInfo.processInfo.environment,
                         userHome: FileManager.default.homeDirectoryForCurrentUser)
    }

    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: home.path)
    }

    // The newest reading across recent sessions, or nil if there's none.
    func latest() -> CodexSnapshot? {
        let fm = FileManager.default
        let logs = CodexParser.recentLogs(sessionsDir: Self.home.appendingPathComponent("sessions", isDirectory: true))
        var next: [URL: (seen: Seen, snapshot: CodexSnapshot?)] = [:]
        for url in logs {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.intValue else { continue }
            let seen = Seen(modified: modified, size: size)
            if let cached = cache[url], cached.seen == seen {
                next[url] = cached
            } else {
                next[url] = (seen, Self.readTail(url, size: size).flatMap(CodexParser.latest(inLog:)))
            }
        }
        cache = next
        return next.values.compactMap(\.snapshot).max { $0.fetchedAt < $1.fetchedAt }
    }

    private static func readTail(_ url: URL, size: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let start = max(0, size - tailBytes)
        try? handle.seek(toOffset: UInt64(start))
        guard var data = try? handle.readToEnd() else { return nil }
        // Starting mid-file, the first line is partial: drop it.
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.index(after: newline)...]
        }
        return String(decoding: data, as: UTF8.self)
    }
}
